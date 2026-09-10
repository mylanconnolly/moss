//! cldrgen — distill the vendored CLDR projections (third_party/cldr/*.json,
//! themselves faithful selections from Unicode CLDR) into the compact
//! `assets/locale/cldr.db` the system ships and reloads live. It parses the
//! CLDR number patterns (grouping size, fraction digits, currency symbol
//! placement/spacing) into the structured fields `lib/locale.zig` reads, so
//! the runtime never touches a CLDR pattern string it did not already know.
//!
//! Run offline of the hermetic build (like tools/mkfont), then commit the
//! blob:
//!   zig run tools/cldrgen.zig -- assets/locale/cldr.db third_party/cldr \
//!       en-US de-DE fr-FR ja-JP
//!
//! It reuses `lib/locale.zig`'s serializer, so the writer and the reader can
//! never drift.

const std = @import("std");
const locale = @import("mosslib").locale;

pub fn main(init: std.process.Init) !u8 {
    // A one-shot host tool: init.arena is freed wholesale at process exit,
    // so LocaleData can borrow the parsed JSON without per-item frees.
    const io = init.io;
    const gpa = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();

    var raw: std.ArrayList([]const u8) = .empty;
    var ait = std.process.Args.Iterator.init(init.minimal.args);
    while (ait.next()) |a| try raw.append(gpa, try gpa.dupe(u8, a));
    // Pull out an optional `--rel <string>` (override the release stamp, so
    // a test can build a distinguishable fixture blob); keep the rest.
    var rel_override: ?[]const u8 = null;
    var argv: std.ArrayList([]const u8) = .empty;
    var ai: usize = 0;
    while (ai < raw.items.len) : (ai += 1) {
        if (std.mem.eql(u8, raw.items[ai], "--rel") and ai + 1 < raw.items.len) {
            rel_override = raw.items[ai + 1];
            ai += 1;
        } else try argv.append(gpa, raw.items[ai]);
    }
    if (argv.items.len < 4) {
        std.debug.print("usage: cldrgen [--rel X] <out.db> <cldr-dir> <tag>...\n", .{});
        return 2;
    }
    const out_path = argv.items[1];
    const dir = argv.items[2];
    const tags = argv.items[3..];

    var rel_buf: [16]u8 = undefined;
    var rel: []const u8 = rel_override orelse "unknown";

    var locales: std.ArrayList(locale.LocaleData) = .empty;
    // Keep every parsed JSON alive until the blob is written (LocaleData
    // borrows its strings), so no per-locale free.
    var docs: std.ArrayList(std.json.Parsed(std.json.Value)) = .empty;

    for (tags) |tag| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}.json", .{ dir, tag });
        const bytes = try cwd.readFileAlloc(io, path, gpa, .limited(1 << 20));
        const parsed = try std.json.parseFromSlice(std.json.Value, gpa, bytes, .{});
        try docs.append(gpa, parsed);
        const o = parsed.value.object;

        if (rel_override == null) if (o.get("cldr")) |v| {
            const s = v.string;
            @memcpy(rel_buf[0..s.len], s);
            rel = rel_buf[0..s.len];
        };

        const dec = try parseDecimalPattern(strOf(o, "decimalPattern"));
        const cur = parseCurrencyPattern(strOf(o, "currencyPattern"));

        var months_abbr: [12][]const u8 = undefined;
        var months_wide: [12][]const u8 = undefined;
        const ma = o.get("monthsAbbr").?.array;
        const mw = o.get("monthsWide").?.array;
        for (0..12) |i| {
            months_abbr[i] = ma.items[i].string;
            months_wide[i] = mw.items[i].string;
        }
        var days_abbr: [7][]const u8 = undefined;
        const da = o.get("daysAbbr").?.array;
        for (0..7) |i| days_abbr[i] = da.items[i].string;

        // currencies: object code -> { symbol, frac }
        var curs: std.ArrayList(locale.Currency) = .empty;
        const cobj = o.get("currencies").?.object;
        var it = cobj.iterator();
        while (it.next()) |e| {
            const c = e.value_ptr.*.object;
            try curs.append(gpa, .{
                .code = e.key_ptr.*,
                .symbol = c.get("symbol").?.string,
                .frac = @intCast(c.get("frac").?.integer),
            });
        }

        try locales.append(gpa, .{
            .tag = strOf(o, "tag"),
            .decimal = strOf(o.get("symbols").?.object, "decimal"),
            .group = strOf(o.get("symbols").?.object, "group"),
            .minus = strOf(o.get("symbols").?.object, "minus"),
            .group_size = dec.group_size,
            .dec_min_frac = dec.min_frac,
            .dec_max_frac = dec.max_frac,
            .cur_sym_before = cur.symbol_before,
            .cur_spacing = cur.spacing,
            .am = strOf(o, "am"),
            .pm = strOf(o, "pm"),
            .months_abbr = months_abbr,
            .months_wide = months_wide,
            .days_abbr = days_abbr,
            .date_medium = strOf(o, "dateMedium"),
            .date_long = strOf(o, "dateLong"),
            .time_medium = strOf(o, "timeMedium"),
            .default_currency = strOf(o, "defaultCurrency"),
            .currencies = try curs.toOwnedSlice(gpa),
        });
    }

    const blob = try locale.writeDb(gpa, rel, locales.items);

    try cwd.writeFile(io, .{ .sub_path = out_path, .data = blob });
    std.debug.print("cldrgen: wrote {s} ({d} bytes, CLDR {s}, {d} locales)\n", .{ out_path, blob.len, rel, locales.items.len });
    return 0;
}

fn strOf(o: std.json.ObjectMap, key: []const u8) []const u8 {
    return o.get(key).?.string;
}

const DecInfo = struct { group_size: u8, min_frac: u8, max_frac: u8 };

/// Parse a CLDR decimal pattern like "#,##0.###": the primary grouping is
/// the run of digit slots after the last group comma in the integer part;
/// fraction digits are the '0' (min) and '0'+'#' (max) after the dot.
fn parseDecimalPattern(p: []const u8) !DecInfo {
    const dot = std.mem.indexOfScalar(u8, p, '.');
    const int_part = if (dot) |d| p[0..d] else p;
    const frac_part = if (dot) |d| p[d + 1 ..] else "";
    var group_size: u8 = 0;
    if (std.mem.lastIndexOfScalar(u8, int_part, ',')) |c| {
        group_size = @intCast(int_part.len - c - 1);
    }
    var min_frac: u8 = 0;
    var max_frac: u8 = 0;
    for (frac_part) |ch| {
        if (ch == '0') {
            min_frac += 1;
            max_frac += 1;
        } else if (ch == '#') max_frac += 1;
    }
    return .{ .group_size = group_size, .min_frac = min_frac, .max_frac = max_frac };
}

const CurInfo = struct { symbol_before: bool, spacing: bool };

/// A CLDR currency pattern like "¤#,##0.00" or "#,##0.00 ¤": is the
/// currency sign (¤, U+00A4) before the number, and is there a no-break
/// space (U+00A0) between them?
fn parseCurrencyPattern(p: []const u8) CurInfo {
    const sign = "\u{00a4}"; // ¤
    const sign_at = std.mem.indexOf(u8, p, sign) orelse 0;
    const digit_at = firstDigitSlot(p);
    return .{
        .symbol_before = sign_at < digit_at,
        .spacing = std.mem.indexOf(u8, p, locale.nbsp) != null,
    };
}

fn firstDigitSlot(p: []const u8) usize {
    for (p, 0..) |ch, i| {
        if (ch == '#' or ch == '0') return i;
    }
    return p.len;
}
