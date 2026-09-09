//! Locale-aware formatting from CLDR data — numbers, dates, and money.
//!
//! The system ships one compact binary, `assets/locale/cldr.db`, distilled
//! from Unicode CLDR by `tools/cldrgen`; a running node can swap it live
//! (the locale service reloads it the way dotd reloads trust roots) and an
//! updater can fetch a fresher one. This module is the pure, freestanding,
//! host-tested half: it PARSES that blob (borrowing its bytes, no
//! allocator) and FORMATS values against a locale — the same code in a
//! userspace service, a command, or a test. The English tables that used
//! to be hardcoded per call site (a GUI clock's month names, say) become a
//! `Locale` looked up by tag.
//!
//! The blob is little-endian:
//!   magic "MCLD", u16 format-version (= fmt_version), str16 CLDR release,
//!   u16 locale-count, then that many records. A string is a length
//!   (u8 for str8, u16 for str16) then its UTF-8 bytes. A record:
//!     tag str8, decimal str8, group str8, minus str8,
//!     group_size u8, dec_min_frac u8, dec_max_frac u8,
//!     cur_sym_before u8, cur_spacing u8, am str8, pm str8,
//!     12×str8 months-abbreviated, 12×str8 months-wide,
//!     7×str8 days-abbreviated (index 0 = Sunday),
//!     date_medium str8, date_long str8, time_medium str8 (raw CLDR
//!       patterns — parsed when rendered, see renderPattern),
//!     default_currency str8, currency-count u8,
//!     then that many: code str8, symbol str8, frac u8.
//! Currency spacing, when present, is always U+00A0 (CLDR's currency
//! patterns use it); the grouping separator can be anything (fr uses the
//! narrow no-break space U+202F), so it is stored, not assumed.

const std = @import("std");

pub const fmt_version: u16 = 1;
const magic = "MCLD";
pub const max_locales = 8;
pub const max_currencies = 8;
/// U+00A0 no-break space — the gap CLDR currency patterns put between the
/// amount and the symbol.
pub const nbsp = "\u{00a0}";

pub const Width = enum { medium, long };

/// The broken-down instant a date pattern renders. Caller fills it (e.g.
/// from `shared.civil.fromUnix`); this module never imports civil, so it
/// stays dependency-free and host-testable. `weekday` is 1=Mon..7=Sun.
pub const DateTime = struct {
    year: i64,
    month: u8, // 1..12
    day: u8, // 1..31
    hour: u8 = 0, // 0..23
    minute: u8 = 0,
    second: u8 = 0,
    weekday: u8 = 1, // 1=Mon .. 7=Sun
};

pub const Currency = struct { code: []const u8, symbol: []const u8, frac: u8 };

/// One locale's rules, its strings borrowed from the blob. Alloc-free.
pub const Locale = struct {
    tag: []const u8 = "",
    decimal: []const u8 = ".",
    group: []const u8 = ",",
    minus: []const u8 = "-",
    group_size: u8 = 3,
    dec_min_frac: u8 = 0,
    dec_max_frac: u8 = 3,
    cur_sym_before: bool = true,
    cur_spacing: bool = false,
    am: []const u8 = "AM",
    pm: []const u8 = "PM",
    months_abbr: [12][]const u8 = @splat(""),
    months_wide: [12][]const u8 = @splat(""),
    days_abbr: [7][]const u8 = @splat(""), // index 0 = Sunday
    date_medium: []const u8 = "",
    date_long: []const u8 = "",
    time_medium: []const u8 = "",
    default_currency: []const u8 = "",
    currencies: [max_currencies]Currency = @splat(.{ .code = "", .symbol = "", .frac = 2 }),
    n_curr: usize = 0,

    /// CLDR keys weekdays Sunday-first; DateTime is Monday=1..Sunday=7.
    fn dayIndex(dt: DateTime) usize {
        return @as(usize, dt.weekday) % 7; // Mon(1)->1 .. Sat(6)->6, Sun(7)->0
    }

    fn currencyByCode(self: *const Locale, code: []const u8) ?Currency {
        for (self.currencies[0..self.n_curr]) |c| {
            if (std.mem.eql(u8, c.code, code)) return c;
        }
        return null;
    }

    /// A decimal number, grouped and with `min_frac`..`max_frac` fraction
    /// digits (trailing zeros trimmed down to `min_frac`), into `out`.
    pub fn formatNumber(self: *const Locale, out: []u8, value: f64, min_frac: u8, max_frac: u8) []const u8 {
        var w = Buf{ .buf = out };
        const neg = value < 0;
        const av = if (neg) -value else value;
        const scale = pow10(max_frac);
        const scaled: u64 = @intFromFloat(@round(av * @as(f64, @floatFromInt(scale))));
        const ip = scaled / scale;
        const fp = scaled % scale;
        if (neg and scaled != 0) w.str(self.minus);
        var digs: [24]u8 = undefined;
        self.groupInto(&w, digitsOf(ip, &digs));
        // Fraction: render max_frac digits, then trim trailing zeros to min_frac.
        var frac_buf: [24]u8 = undefined;
        var i: u8 = max_frac;
        var x = fp;
        while (i > 0) : (i -= 1) {
            frac_buf[i - 1] = '0' + @as(u8, @intCast(x % 10));
            x /= 10;
        }
        var flen: u8 = max_frac;
        while (flen > min_frac and frac_buf[flen - 1] == '0') flen -= 1;
        if (flen > 0) {
            w.str(self.decimal);
            w.str(frac_buf[0..flen]);
        }
        return w.out();
    }

    /// An integer, grouped, with a locale minus sign.
    pub fn formatInt(self: *const Locale, out: []u8, value: i64) []const u8 {
        var w = Buf{ .buf = out };
        const neg = value < 0;
        const mag: u64 = if (neg) @intCast(-value) else @intCast(value);
        if (neg and mag != 0) w.str(self.minus);
        var digs: [24]u8 = undefined;
        self.groupInto(&w, digitsOf(mag, &digs));
        return w.out();
    }

    /// A money amount in `code` (e.g. "USD"): the amount at the currency's
    /// fraction digits, the symbol placed and spaced per the locale.
    pub fn formatMoney(self: *const Locale, out: []u8, value: f64, code: []const u8) []const u8 {
        const cur = self.currencyByCode(code) orelse
            (self.currencyByCode(self.default_currency) orelse
            Currency{ .code = code, .symbol = code, .frac = 2 });
        var nb: [48]u8 = undefined;
        const num = self.formatNumber(&nb, value, cur.frac, cur.frac);
        var w = Buf{ .buf = out };
        if (self.cur_sym_before) {
            w.str(cur.symbol);
            if (self.cur_spacing) w.str(nbsp);
            w.str(num);
        } else {
            w.str(num);
            if (self.cur_spacing) w.str(nbsp);
            w.str(cur.symbol);
        }
        return w.out();
    }

    /// A date at the given width (medium/long CLDR pattern).
    pub fn formatDate(self: *const Locale, out: []u8, dt: DateTime, width: Width) []const u8 {
        const pat = switch (width) {
            .medium => self.date_medium,
            .long => self.date_long,
        };
        var w = Buf{ .buf = out };
        self.renderPattern(&w, pat, dt);
        return w.out();
    }

    /// A time at the medium CLDR pattern (12h + am/pm or 24h per locale).
    pub fn formatTime(self: *const Locale, out: []u8, dt: DateTime) []const u8 {
        var w = Buf{ .buf = out };
        self.renderPattern(&w, self.time_medium, dt);
        return w.out();
    }

    fn groupInto(self: *const Locale, w: *Buf, digs: []const u8) void {
        const n = digs.len;
        const gs: usize = if (self.group_size == 0) 255 else self.group_size;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            if (i > 0 and (n - i) % gs == 0) w.str(self.group);
            w.byte(digs[i]);
        }
    }

    /// Walk a CLDR date/time pattern: a run of the same letter is a field
    /// of that width, `'...'` is a quoted literal (`''` a literal quote),
    /// and everything else (punctuation, spaces, non-ASCII bytes like ja's
    /// 年月日) passes through verbatim.
    fn renderPattern(self: *const Locale, w: *Buf, pat: []const u8, dt: DateTime) void {
        var i: usize = 0;
        while (i < pat.len) {
            const c = pat[i];
            if (c == '\'') {
                i += 1;
                if (i < pat.len and pat[i] == '\'') {
                    w.byte('\'');
                    i += 1;
                    continue;
                }
                while (i < pat.len and pat[i] != '\'') : (i += 1) w.byte(pat[i]);
                if (i < pat.len) i += 1; // closing quote
                continue;
            }
            if (isLetter(c)) {
                var j = i + 1;
                while (j < pat.len and pat[j] == c) j += 1;
                self.renderField(w, c, j - i, dt);
                i = j;
                continue;
            }
            w.byte(c);
            i += 1;
        }
    }

    fn renderField(self: *const Locale, w: *Buf, c: u8, width: usize, dt: DateTime) void {
        switch (c) {
            'y' => if (width == 2) w.pad2(@intCast(@mod(dt.year, 100))) else w.num(@intCast(@max(dt.year, 0))),
            'M' => switch (width) {
                1 => w.num(dt.month),
                2 => w.pad2(dt.month),
                3 => w.str(self.months_abbr[dt.month - 1]),
                else => w.str(self.months_wide[dt.month - 1]),
            },
            'd' => if (width >= 2) w.pad2(dt.day) else w.num(dt.day),
            'E' => w.str(self.days_abbr[dayIndex(dt)]),
            'H' => if (width >= 2) w.pad2(dt.hour) else w.num(dt.hour),
            'h' => {
                var h: u8 = dt.hour % 12;
                if (h == 0) h = 12;
                if (width >= 2) w.pad2(h) else w.num(h);
            },
            'm' => if (width >= 2) w.pad2(dt.minute) else w.num(dt.minute),
            's' => if (width >= 2) w.pad2(dt.second) else w.num(dt.second),
            'a' => w.str(if (dt.hour < 12) self.am else self.pm),
            else => {}, // fields we do not carry (era, zone, …) are dropped
        }
    }
};

/// The whole database: the CLDR release it came from and its locales.
pub const Db = struct {
    rel: []const u8 = "",
    locales: [max_locales]Locale = @splat(.{}),
    n: usize = 0,

    pub const Error = error{ BadMagic, BadVersion, Truncated, TooMany };

    pub fn parse(bytes: []const u8) Error!Db {
        var r = Reader{ .b = bytes };
        if (!std.mem.eql(u8, try r.take(4), magic)) return error.BadMagic;
        if (try r.rd16() != fmt_version) return error.BadVersion;
        var db = Db{};
        db.rel = try r.str16();
        const n = try r.rd16();
        if (n > max_locales) return error.TooMany;
        var li: usize = 0;
        while (li < n) : (li += 1) {
            var loc = Locale{};
            loc.tag = try r.str8();
            loc.decimal = try r.str8();
            loc.group = try r.str8();
            loc.minus = try r.str8();
            loc.group_size = try r.rd8();
            loc.dec_min_frac = try r.rd8();
            loc.dec_max_frac = try r.rd8();
            loc.cur_sym_before = (try r.rd8()) != 0;
            loc.cur_spacing = (try r.rd8()) != 0;
            loc.am = try r.str8();
            loc.pm = try r.str8();
            for (&loc.months_abbr) |*m| m.* = try r.str8();
            for (&loc.months_wide) |*m| m.* = try r.str8();
            for (&loc.days_abbr) |*d| d.* = try r.str8();
            loc.date_medium = try r.str8();
            loc.date_long = try r.str8();
            loc.time_medium = try r.str8();
            loc.default_currency = try r.str8();
            const nc = try r.rd8();
            if (nc > max_currencies) return error.TooMany;
            var ci: usize = 0;
            while (ci < nc) : (ci += 1) {
                const code = try r.str8();
                const sym = try r.str8();
                const frac = try r.rd8();
                loc.currencies[ci] = .{ .code = code, .symbol = sym, .frac = frac };
            }
            loc.n_curr = nc;
            db.locales[li] = loc;
        }
        db.n = n;
        return db;
    }

    /// Exact tag ("en-US"), else the language prefix ("en" matches
    /// "en-US"), else null.
    pub fn find(self: *const Db, tag: []const u8) ?*const Locale {
        for (self.locales[0..self.n]) |*l| {
            if (std.mem.eql(u8, l.tag, tag)) return l;
        }
        const lang = tag[0 .. std.mem.indexOfScalar(u8, tag, '-') orelse tag.len];
        for (self.locales[0..self.n]) |*l| {
            const ltag = l.tag;
            const llang = ltag[0 .. std.mem.indexOfScalar(u8, ltag, '-') orelse ltag.len];
            if (std.mem.eql(u8, llang, lang)) return l;
        }
        return null;
    }
};

// ------------------------------------------------------------- serializer
//
// The writer half — used by `tools/cldrgen` (and the tests) to build a
// blob from structured data. It takes an allocator, so it never runs on
// the freestanding consumers; they only `parse` and format.

pub const LocaleData = struct {
    tag: []const u8,
    decimal: []const u8,
    group: []const u8,
    minus: []const u8,
    group_size: u8,
    dec_min_frac: u8,
    dec_max_frac: u8,
    cur_sym_before: bool,
    cur_spacing: bool,
    am: []const u8,
    pm: []const u8,
    months_abbr: [12][]const u8,
    months_wide: [12][]const u8,
    days_abbr: [7][]const u8,
    date_medium: []const u8,
    date_long: []const u8,
    time_medium: []const u8,
    default_currency: []const u8,
    currencies: []const Currency,
};

pub fn writeDb(a: std.mem.Allocator, rel: []const u8, locales: []const LocaleData) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(a);
    try out.appendSlice(a, magic);
    try appendU16(a, &out, fmt_version);
    try appendStr16(a, &out, rel);
    try appendU16(a, &out, @intCast(locales.len));
    for (locales) |l| {
        try appendStr8(a, &out, l.tag);
        try appendStr8(a, &out, l.decimal);
        try appendStr8(a, &out, l.group);
        try appendStr8(a, &out, l.minus);
        try out.append(a, l.group_size);
        try out.append(a, l.dec_min_frac);
        try out.append(a, l.dec_max_frac);
        try out.append(a, @intFromBool(l.cur_sym_before));
        try out.append(a, @intFromBool(l.cur_spacing));
        try appendStr8(a, &out, l.am);
        try appendStr8(a, &out, l.pm);
        for (l.months_abbr) |m| try appendStr8(a, &out, m);
        for (l.months_wide) |m| try appendStr8(a, &out, m);
        for (l.days_abbr) |d| try appendStr8(a, &out, d);
        try appendStr8(a, &out, l.date_medium);
        try appendStr8(a, &out, l.date_long);
        try appendStr8(a, &out, l.time_medium);
        try appendStr8(a, &out, l.default_currency);
        try out.append(a, @intCast(l.currencies.len));
        for (l.currencies) |c| {
            try appendStr8(a, &out, c.code);
            try appendStr8(a, &out, c.symbol);
            try out.append(a, c.frac);
        }
    }
    return out.toOwnedSlice(a);
}

fn appendU16(a: std.mem.Allocator, out: *std.ArrayList(u8), v: u16) !void {
    try out.append(a, @intCast(v & 0xff));
    try out.append(a, @intCast((v >> 8) & 0xff));
}
fn appendStr8(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    std.debug.assert(s.len <= 255);
    try out.append(a, @intCast(s.len));
    try out.appendSlice(a, s);
}
fn appendStr16(a: std.mem.Allocator, out: *std.ArrayList(u8), s: []const u8) !void {
    try appendU16(a, out, @intCast(s.len));
    try out.appendSlice(a, s);
}

// --------------------------------------------------------------- helpers

const Reader = struct {
    b: []const u8,
    i: usize = 0,
    fn take(r: *Reader, n: usize) Db.Error![]const u8 {
        if (r.i + n > r.b.len) return error.Truncated;
        const s = r.b[r.i .. r.i + n];
        r.i += n;
        return s;
    }
    fn rd8(r: *Reader) Db.Error!u8 {
        return (try r.take(1))[0];
    }
    fn rd16(r: *Reader) Db.Error!u16 {
        const s = try r.take(2);
        return @as(u16, s[0]) | (@as(u16, s[1]) << 8);
    }
    fn str8(r: *Reader) Db.Error![]const u8 {
        const n = try r.rd8();
        return r.take(n);
    }
    fn str16(r: *Reader) Db.Error![]const u8 {
        const n = try r.rd16();
        return r.take(n);
    }
};

/// A bounds-checked byte sink into a caller buffer (silently drops on
/// overflow — every caller passes a generous buffer).
const Buf = struct {
    buf: []u8,
    len: usize = 0,
    fn str(self: *Buf, bytes: []const u8) void {
        const n = @min(bytes.len, self.buf.len - self.len);
        @memcpy(self.buf[self.len .. self.len + n], bytes[0..n]);
        self.len += n;
    }
    fn byte(self: *Buf, c: u8) void {
        if (self.len < self.buf.len) {
            self.buf[self.len] = c;
            self.len += 1;
        }
    }
    fn num(self: *Buf, v: u64) void {
        var tmp: [24]u8 = undefined;
        self.str(digitsOf(v, &tmp));
    }
    fn pad2(self: *Buf, v: u64) void {
        self.byte('0' + @as(u8, @intCast((v / 10) % 10)));
        self.byte('0' + @as(u8, @intCast(v % 10)));
    }
    fn out(self: *Buf) []const u8 {
        return self.buf[0..self.len];
    }
};

fn digitsOf(v: u64, buf: []u8) []const u8 {
    if (v == 0) {
        buf[0] = '0';
        return buf[0..1];
    }
    var i = buf.len;
    var x = v;
    while (x > 0) {
        i -= 1;
        buf[i] = '0' + @as(u8, @intCast(x % 10));
        x /= 10;
    }
    return buf[i..];
}

fn pow10(n: u8) u64 {
    var r: u64 = 1;
    var i: u8 = 0;
    while (i < n) : (i += 1) r *= 10;
    return r;
}

fn isLetter(c: u8) bool {
    return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z');
}

// ------------------------------------------------------------------ tests
//
// The four launch locales, with values verbatim from CLDR 48.2.0 (the same
// the projections carry), round-tripped write → parse → format. This tests
// the formatter and the blob codec; the CLDR→blob pipeline (cldrgen) and
// the live reload are covered by the locale drill.

const testing = std.testing;

fn testDb() ![]u8 {
    const en = LocaleData{
        .tag = "en-US", .decimal = ".", .group = ",", .minus = "-",
        .group_size = 3, .dec_min_frac = 0, .dec_max_frac = 3,
        .cur_sym_before = true, .cur_spacing = false, .am = "AM", .pm = "PM",
        .months_abbr = .{ "Jan", "Feb", "Mar", "Apr", "May", "Jun", "Jul", "Aug", "Sep", "Oct", "Nov", "Dec" },
        .months_wide = .{ "January", "February", "March", "April", "May", "June", "July", "August", "September", "October", "November", "December" },
        .days_abbr = .{ "Sun", "Mon", "Tue", "Wed", "Thu", "Fri", "Sat" },
        .date_medium = "MMM d, y", .date_long = "MMMM d, y", .time_medium = "h:mm:ss a",
        .default_currency = "USD",
        .currencies = &.{ .{ .code = "USD", .symbol = "$", .frac = 2 }, .{ .code = "JPY", .symbol = "¥", .frac = 0 } },
    };
    const de = LocaleData{
        .tag = "de-DE", .decimal = ",", .group = ".", .minus = "-",
        .group_size = 3, .dec_min_frac = 0, .dec_max_frac = 3,
        .cur_sym_before = false, .cur_spacing = true, .am = "AM", .pm = "PM",
        .months_abbr = .{ "Jan.", "Feb.", "März", "Apr.", "Mai", "Juni", "Juli", "Aug.", "Sept.", "Okt.", "Nov.", "Dez." },
        .months_wide = .{ "Januar", "Februar", "März", "April", "Mai", "Juni", "Juli", "August", "September", "Oktober", "November", "Dezember" },
        .days_abbr = .{ "So.", "Mo.", "Di.", "Mi.", "Do.", "Fr.", "Sa." },
        .date_medium = "dd.MM.y", .date_long = "d. MMMM y", .time_medium = "HH:mm:ss",
        .default_currency = "EUR",
        .currencies = &.{.{ .code = "EUR", .symbol = "€", .frac = 2 }},
    };
    const fr = LocaleData{
        .tag = "fr-FR", .decimal = ",", .group = "\u{202f}", .minus = "-",
        .group_size = 3, .dec_min_frac = 0, .dec_max_frac = 3,
        .cur_sym_before = false, .cur_spacing = true, .am = "AM", .pm = "PM",
        .months_abbr = .{ "janv.", "févr.", "mars", "avr.", "mai", "juin", "juil.", "août", "sept.", "oct.", "nov.", "déc." },
        .months_wide = .{ "janvier", "février", "mars", "avril", "mai", "juin", "juillet", "août", "septembre", "octobre", "novembre", "décembre" },
        .days_abbr = .{ "dim.", "lun.", "mar.", "mer.", "jeu.", "ven.", "sam." },
        .date_medium = "d MMM y", .date_long = "d MMMM y", .time_medium = "HH:mm:ss",
        .default_currency = "EUR",
        .currencies = &.{.{ .code = "EUR", .symbol = "€", .frac = 2 }},
    };
    const ja = LocaleData{
        .tag = "ja-JP", .decimal = ".", .group = ",", .minus = "-",
        .group_size = 3, .dec_min_frac = 0, .dec_max_frac = 3,
        .cur_sym_before = true, .cur_spacing = false, .am = "午前", .pm = "午後",
        .months_abbr = .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .months_wide = .{ "1月", "2月", "3月", "4月", "5月", "6月", "7月", "8月", "9月", "10月", "11月", "12月" },
        .days_abbr = .{ "日", "月", "火", "水", "木", "金", "土" },
        .date_medium = "y/MM/dd", .date_long = "y年M月d日", .time_medium = "H:mm:ss",
        .default_currency = "JPY",
        .currencies = &.{.{ .code = "JPY", .symbol = "￥", .frac = 0 }},
    };
    return writeDb(testing.allocator, "48.2.0", &.{ en, de, fr, ja });
}

test "numbers group and separate per locale" {
    const bytes = try testDb();
    defer testing.allocator.free(bytes);
    const db = try Db.parse(bytes);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("1,234.56", db.find("en-US").?.formatNumber(&buf, 1234.56, 0, 3));
    try testing.expectEqualStrings("1.234,56", db.find("de-DE").?.formatNumber(&buf, 1234.56, 0, 3));
    try testing.expectEqualStrings("1\u{202f}234,56", db.find("fr-FR").?.formatNumber(&buf, 1234.56, 0, 3));
    try testing.expectEqualStrings("1,234.56", db.find("ja-JP").?.formatNumber(&buf, 1234.56, 0, 3));
    // trailing-zero trim and a bigger group
    try testing.expectEqualStrings("1,234,567", db.find("en-US").?.formatInt(&buf, 1234567));
    try testing.expectEqualStrings("-9,999", db.find("en-US").?.formatInt(&buf, -9999));
}

test "money places the symbol and rounds to the currency's digits" {
    const bytes = try testDb();
    defer testing.allocator.free(bytes);
    const db = try Db.parse(bytes);
    var buf: [64]u8 = undefined;
    try testing.expectEqualStrings("$1,234.56", db.find("en-US").?.formatMoney(&buf, 1234.56, "USD"));
    try testing.expectEqualStrings("1.234,56\u{00a0}€", db.find("de-DE").?.formatMoney(&buf, 1234.56, "EUR"));
    try testing.expectEqualStrings("1\u{202f}234,56\u{00a0}€", db.find("fr-FR").?.formatMoney(&buf, 1234.56, "EUR"));
    // JPY has zero fraction digits: rounds, no decimal part.
    try testing.expectEqualStrings("￥1,235", db.find("ja-JP").?.formatMoney(&buf, 1234.56, "JPY"));
}

test "dates render the locale pattern, names, and 12/24h clock" {
    const bytes = try testDb();
    defer testing.allocator.free(bytes);
    const db = try Db.parse(bytes);
    var buf: [64]u8 = undefined;
    // 2026-09-09 (a Wednesday), 21:04:26.
    const dt = DateTime{ .year = 2026, .month = 9, .day = 9, .hour = 21, .minute = 4, .second = 26, .weekday = 3 };
    try testing.expectEqualStrings("Sep 9, 2026", db.find("en-US").?.formatDate(&buf, dt, .medium));
    try testing.expectEqualStrings("09.09.2026", db.find("de-DE").?.formatDate(&buf, dt, .medium));
    try testing.expectEqualStrings("9 sept. 2026", db.find("fr-FR").?.formatDate(&buf, dt, .medium));
    try testing.expectEqualStrings("2026年9月9日", db.find("ja-JP").?.formatDate(&buf, dt, .long));
    // Medium time: en is 12-hour with a marker, de/ja are 24-hour.
    try testing.expectEqualStrings("9:04:26 PM", db.find("en-US").?.formatTime(&buf, dt));
    try testing.expectEqualStrings("21:04:26", db.find("de-DE").?.formatTime(&buf, dt));
    try testing.expectEqualStrings("21:04:26", db.find("ja-JP").?.formatTime(&buf, dt));
}

test "find falls back from region to language" {
    const bytes = try testDb();
    defer testing.allocator.free(bytes);
    const db = try Db.parse(bytes);
    try testing.expect(db.find("en") != null);
    try testing.expect(db.find("de-AT") != null); // no de-AT → de-DE
    try testing.expect(db.find("zz-ZZ") == null);
}
