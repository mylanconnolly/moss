//! The WHATWG URL Standard (https://url.spec.whatwg.org/): the basic URL
//! parser as a state machine over the input's bytes, hosts (domains
//! lowercased and punycoded, IPv4 with its numeric quirks, IPv6 with
//! compression), the percent-encode sets, the serializer and the getters
//! a browser shows. Everything here allocates from the caller's
//! allocator and nothing else; a `Url` owns nothing but slices of it.
//!
//! What is not here yet: the setters (`setters_tests.json`), the UTS46
//! mapping table for non-ASCII domains (labels are lowercased where
//! ASCII and punycoded as given, so a domain that needs case folding or
//! normalization of non-Latin letters serializes differently from a
//! browser), and `blob:` origins. The host test runs the WPT corpus and
//! prints how many of its entries agree.
const std = @import("std");

pub const Error = error{ OutOfMemory, Invalid };
/// What serializing can fail with: only the allocator.
pub const AllocError = error{OutOfMemory};

pub const Host = union(enum) {
    domain: []const u8,
    opaque_host: []const u8,
    ipv4: u32,
    ipv6: [8]u16,
    empty,

    pub fn serialize(h: Host, a: std.mem.Allocator) AllocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try writeHost(h, a, &out);
        return out.items;
    }

    fn writeHost(h: Host, a: std.mem.Allocator, out: *std.ArrayList(u8)) AllocError!void {
        switch (h) {
            .domain, .opaque_host => |s| try out.appendSlice(a, s),
            .empty => {},
            .ipv4 => |v| try out.print(a, "{d}.{d}.{d}.{d}", .{ v >> 24, (v >> 16) & 0xff, (v >> 8) & 0xff, v & 0xff }),
            .ipv6 => |pieces| {
                try out.append(a, '[');
                try writeIpv6(pieces, a, out);
                try out.append(a, ']');
            },
        }
    }
};

pub const Path = union(enum) {
    list: []const []const u8,
    opaque_path: []const u8,
};

pub const Url = struct {
    scheme: []const u8,
    username: []const u8 = "",
    password: []const u8 = "",
    host: ?Host = null,
    port: ?u16 = null,
    path: Path = .{ .list = &.{} },
    query: ?[]const u8 = null,
    fragment: ?[]const u8 = null,

    pub fn isSpecial(u: *const Url) bool {
        return defaultPort(u.scheme) != null or std.mem.eql(u8, u.scheme, "file");
    }

    pub fn hasOpaquePath(u: *const Url) bool {
        return u.path == .opaque_path;
    }

    /// The URL serializer.
    pub fn serialize(u: *const Url, a: std.mem.Allocator, exclude_fragment: bool) AllocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, u.scheme);
        try out.append(a, ':');
        if (u.host) |h| {
            try out.appendSlice(a, "//");
            if (u.username.len > 0 or u.password.len > 0) {
                try out.appendSlice(a, u.username);
                if (u.password.len > 0) {
                    try out.append(a, ':');
                    try out.appendSlice(a, u.password);
                }
                try out.append(a, '@');
            }
            try h.writeHost(a, &out);
            if (u.port) |p| try out.print(a, ":{d}", .{p});
        } else if (u.path == .list and u.path.list.len > 1 and u.path.list[0].len == 0) {
            try out.appendSlice(a, "/.");
        }
        try writePath(u, a, &out);
        if (u.query) |q| {
            try out.append(a, '?');
            try out.appendSlice(a, q);
        }
        if (!exclude_fragment) if (u.fragment) |f| {
            try out.append(a, '#');
            try out.appendSlice(a, f);
        };
        return out.items;
    }

    pub fn href(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        return u.serialize(a, false);
    }

    /// The origin, serialized: `scheme://host[:port]` for the schemes
    /// that have one, `null` for the rest (file, opaque schemes; blob is
    /// not parsed through yet).
    pub fn origin(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        if (defaultPort(u.scheme) == null) return try a.dupe(u8, "null");
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, u.scheme);
        try out.appendSlice(a, "://");
        if (u.host) |h| try h.writeHost(a, &out);
        if (u.port) |p| try out.print(a, ":{d}", .{p});
        return out.items;
    }

    pub fn protocol(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, u.scheme);
        try out.append(a, ':');
        return out.items;
    }

    /// The `host` getter: the host with its port, or "" without a host.
    pub fn hostString(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        if (u.host) |h| try h.writeHost(a, &out);
        if (u.port) |p| try out.print(a, ":{d}", .{p});
        return out.items;
    }

    pub fn hostname(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        if (u.host) |h| return h.serialize(a);
        return try a.dupe(u8, "");
    }

    pub fn portString(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        if (u.port) |p| return try std.fmt.allocPrint(a, "{d}", .{p});
        return try a.dupe(u8, "");
    }

    pub fn pathname(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try writePath(u, a, &out);
        return out.items;
    }

    pub fn search(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        const q = u.query orelse return try a.dupe(u8, "");
        if (q.len == 0) return try a.dupe(u8, "");
        return try std.mem.concat(a, u8, &.{ "?", q });
    }

    pub fn hash(u: *const Url, a: std.mem.Allocator) AllocError![]u8 {
        const f = u.fragment orelse return try a.dupe(u8, "");
        if (f.len == 0) return try a.dupe(u8, "");
        return try std.mem.concat(a, u8, &.{ "#", f });
    }

    fn writePath(u: *const Url, a: std.mem.Allocator, out: *std.ArrayList(u8)) AllocError!void {
        switch (u.path) {
            .opaque_path => |s| try out.appendSlice(a, s),
            .list => |segs| for (segs) |s| {
                try out.append(a, '/');
                try out.appendSlice(a, s);
            },
        }
    }
};

/// The default port of a special scheme (null for file, which is special
/// without one, and for every non-special scheme).
pub fn defaultPort(scheme: []const u8) ?u16 {
    const eq = std.mem.eql;
    if (eq(u8, scheme, "http") or eq(u8, scheme, "ws")) return 80;
    if (eq(u8, scheme, "https") or eq(u8, scheme, "wss")) return 443;
    if (eq(u8, scheme, "ftp")) return 21;
    return null;
}

fn isSpecialScheme(scheme: []const u8) bool {
    return defaultPort(scheme) != null or std.mem.eql(u8, scheme, "file");
}

// ------------------------------------------------------------ encode sets

const Set = enum { c0, fragment, query, special_query, path, userinfo };

fn inSet(set: Set, c: u8) bool {
    if (c < 0x20 or c > 0x7e) return true; // the C0 control set is in every set
    return switch (set) {
        .c0 => false,
        .fragment => c == ' ' or c == '"' or c == '<' or c == '>' or c == '`',
        .query => c == ' ' or c == '"' or c == '#' or c == '<' or c == '>',
        .special_query => c == ' ' or c == '"' or c == '#' or c == '<' or c == '>' or c == '\'',
        .path => inSet(.query, c) or c == '?' or c == '^' or c == '`' or c == '{' or c == '}',
        .userinfo => inSet(.path, c) or c == '/' or c == ':' or c == ';' or c == '=' or c == '@' or (c >= '[' and c <= ']') or c == '|',
    };
}

fn encodeByte(set: Set, c: u8, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    if (!inSet(set, c)) return out.append(a, c);
    const hex = "0123456789ABCDEF";
    try out.appendSlice(a, &.{ '%', hex[c >> 4], hex[c & 15] });
}

fn encodeSlice(set: Set, s: []const u8, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    for (s) |c| try encodeByte(set, c, a, out);
}

/// Percent-decode into fresh bytes.
pub fn percentDecode(a: std.mem.Allocator, s: []const u8) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        if (s[i] == '%' and i + 2 < s.len) {
            const hi = hexVal(s[i + 1]);
            const lo = hexVal(s[i + 2]);
            if (hi != null and lo != null) {
                try out.append(a, (hi.? << 4) | lo.?);
                i += 2;
                continue;
            }
        }
        try out.append(a, s[i]);
    }
    return out.items;
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ------------------------------------------------------------------ hosts

fn forbiddenHost(c: u8) bool {
    return switch (c) {
        0, '\t', '\n', '\r', ' ', '#', '/', ':', '<', '>', '?', '@', '[', '\\', ']', '^', '|' => true,
        else => false,
    };
}

fn forbiddenDomain(c: u8) bool {
    return forbiddenHost(c) or c < 0x20 or c == '%' or c == 0x7f;
}

/// The host parser.
/// A `data:` URL's payload (the Fetch Standard's data: URL processor,
/// without MIME parameters): its media type as written and its bytes,
/// percent-decoded and, with `;base64`, base64-decoded. Null when the
/// URL is not one or its base64 is bad.
pub const Data = struct { mime: []const u8, bytes: []const u8 };

pub fn decodeData(a: std.mem.Allocator, href: []const u8) Error!?Data {
    if (href.len < 5 or !std.ascii.eqlIgnoreCase(href[0..5], "data:")) return null;
    const rest = href[5..];
    const comma = std.mem.indexOfScalar(u8, rest, ',') orelse return null;
    var mime = std.mem.trim(u8, rest[0..comma], " \t\r\n");
    const body = try percentDecode(a, rest[comma + 1 ..]);
    var base64 = false;
    if (mime.len >= 7 and std.ascii.eqlIgnoreCase(std.mem.trimEnd(u8, mime, " ")[@max(7, mime.len) - 7 ..], ";base64")) {
        base64 = true;
        mime = mime[0 .. mime.len - 7];
    }
    if (!base64) return .{ .mime = mime, .bytes = body };
    // Forgiving base64: whitespace dropped, padding optional.
    var clean: std.ArrayList(u8) = .empty;
    for (body) |c| if (!std.ascii.isWhitespace(c)) try clean.append(a, c);
    var text = clean.items;
    while (text.len > 0 and text[text.len - 1] == '=') text.len -= 1;
    const dec = std.base64.standard_no_pad.Decoder;
    const n = dec.calcSizeForSlice(text) catch return null;
    const out = try a.alloc(u8, n);
    dec.decode(out, text) catch return null;
    return .{ .mime = mime, .bytes = out };
}

pub fn parseHost(a: std.mem.Allocator, input: []const u8, is_opaque: bool) Error!Host {
    if (input.len > 0 and input[0] == '[') {
        if (input[input.len - 1] != ']') return error.Invalid;
        return .{ .ipv6 = try parseIpv6(input[1 .. input.len - 1]) };
    }
    if (is_opaque) {
        for (input) |c| if (forbiddenHost(c)) return error.Invalid;
        var out: std.ArrayList(u8) = .empty;
        try encodeSlice(.c0, input, a, &out);
        return .{ .opaque_host = out.items };
    }
    const decoded = try percentDecode(a, input);
    if (!std.unicode.utf8ValidateSlice(decoded)) return error.Invalid;
    const ascii = try domainToAscii(a, decoded);
    if (ascii.len == 0) return error.Invalid;
    for (ascii) |c| if (forbiddenDomain(c)) return error.Invalid;
    if (endsInANumber(ascii)) return .{ .ipv4 = try parseIpv4(ascii) };
    return .{ .domain = ascii };
}

/// Domain to ASCII: labels split on the IDNA dots, ASCII lowercased,
/// a label with non-ASCII in it punycoded under `xn--`. Without the
/// UTS46 mapping table, non-Latin case folding and normalization are
/// not applied — the corpus counts those against us.
fn domainToAscii(a: std.mem.Allocator, domain: []const u8) Error![]u8 {
    var cps: std.ArrayList(u21) = .empty;
    var it = std.unicode.Utf8View.initUnchecked(domain).iterator();
    while (it.nextCodepoint()) |cp| {
        switch (cp) {
            0x3002, 0xff0e, 0xff61 => try cps.append(a, '.'),
            0xad, 0x200b, 0x200c, 0x200d, 0x2060, 0xfeff => {}, // mapped to nothing
            'A'...'Z' => try cps.append(a, cp + 32),
            else => try cps.append(a, cp),
        }
    }
    var out: std.ArrayList(u8) = .empty;
    var start: usize = 0;
    var i: usize = 0;
    while (i <= cps.items.len) : (i += 1) {
        if (i == cps.items.len or cps.items[i] == '.') {
            const label = cps.items[start..i];
            var all_ascii = true;
            for (label) |cp| if (cp > 0x7f) {
                all_ascii = false;
            };
            if (all_ascii) {
                for (label) |cp| try out.append(a, @intCast(cp));
            } else {
                try out.appendSlice(a, "xn--");
                try punycodeEncode(a, label, &out);
            }
            if (i < cps.items.len) try out.append(a, '.');
            start = i + 1;
        }
    }
    return out.items;
}

/// RFC 3492 punycode of one label.
fn punycodeEncode(a: std.mem.Allocator, input: []const u21, out: *std.ArrayList(u8)) Error!void {
    const base: u32 = 36;
    const tmin: u32 = 1;
    const tmax: u32 = 26;
    const skew: u32 = 38;
    const damp: u32 = 700;
    var n: u32 = 128;
    var delta: u32 = 0;
    var bias: u32 = 72;
    var basic: u32 = 0;
    for (input) |cp| if (cp < 0x80) {
        try out.append(a, @intCast(cp));
        basic += 1;
    };
    var h = basic;
    if (basic > 0) try out.append(a, '-');
    while (h < input.len) {
        var m: u32 = 0x10ffff;
        for (input) |cp| if (cp >= n and cp < m) {
            m = cp;
        };
        delta = std.math.add(u32, delta, std.math.mul(u32, m - n, h + 1) catch return error.Invalid) catch return error.Invalid;
        n = m;
        for (input) |cp| {
            if (cp < n) delta = std.math.add(u32, delta, 1) catch return error.Invalid;
            if (cp == n) {
                var q = delta;
                var k: u32 = base;
                while (true) : (k += base) {
                    const t: u32 = if (k <= bias) tmin else if (k >= bias + tmax) tmax else k - bias;
                    if (q < t) break;
                    const digit = t + (q - t) % (base - t);
                    try out.append(a, digitChar(digit));
                    q = (q - t) / (base - t);
                }
                try out.append(a, digitChar(q));
                bias = adapt(delta, h + 1, h == basic);
                delta = 0;
                h += 1;
            }
        }
        delta += 1;
        n += 1;
    }
    _ = skew;
    _ = damp;
}

fn digitChar(d: u32) u8 {
    return if (d < 26) @intCast('a' + d) else @intCast('0' + d - 26);
}

fn adapt(delta_in: u32, numpoints: u32, first: bool) u32 {
    var delta = if (first) delta_in / 700 else delta_in / 2;
    delta += delta / numpoints;
    var k: u32 = 0;
    while (delta > ((36 - 1) * 26) / 2) : (k += 36) delta /= 36 - 1;
    return k + (36 * delta) / (delta + 38);
}

fn endsInANumber(s: []const u8) bool {
    var parts = std.mem.splitScalar(u8, s, '.');
    var last: []const u8 = "";
    var count: usize = 0;
    var prev: []const u8 = "";
    while (parts.next()) |p| {
        prev = last;
        last = p;
        count += 1;
    }
    if (last.len == 0) {
        if (count == 1) return false;
        last = prev;
    }
    if (last.len > 0) {
        var digits = true;
        for (last) |c| if (!std.ascii.isDigit(c)) {
            digits = false;
        };
        if (digits) return true;
    }
    return ipv4Number(last) != null;
}

/// The IPv4 number parser: null on failure; saturates past u64 (a part
/// that large fails the range checks anyway).
fn ipv4Number(in: []const u8) ?u64 {
    if (in.len == 0) return null;
    var s = in;
    var radix: u8 = 10;
    if (s.len >= 2 and s[0] == '0' and (s[1] == 'x' or s[1] == 'X')) {
        s = s[2..];
        radix = 16;
    } else if (s.len >= 2 and s[0] == '0') {
        s = s[1..];
        radix = 8;
    }
    if (s.len == 0) return 0;
    var v: u64 = 0;
    for (s) |c| {
        const d = hexVal(c) orelse return null;
        if (d >= radix) return null;
        v = std.math.mul(u64, v, radix) catch std.math.maxInt(u64);
        v = std.math.add(u64, v, d) catch std.math.maxInt(u64);
    }
    return v;
}

fn parseIpv4(s: []const u8) Error!u32 {
    var parts: [6][]const u8 = undefined;
    var n: usize = 0;
    var it = std.mem.splitScalar(u8, s, '.');
    while (it.next()) |p| {
        if (n == parts.len) return error.Invalid;
        parts[n] = p;
        n += 1;
    }
    if (n > 1 and parts[n - 1].len == 0) n -= 1;
    if (n > 4) return error.Invalid;
    var nums: [4]u64 = undefined;
    for (parts[0..n], 0..) |p, i| nums[i] = ipv4Number(p) orelse return error.Invalid;
    for (nums[0 .. n - 1]) |v| if (v > 255) return error.Invalid;
    const limit = std.math.pow(u64, 256, 5 - n);
    if (nums[n - 1] >= limit) return error.Invalid;
    var v: u64 = nums[n - 1];
    for (nums[0 .. n - 1], 0..) |x, i| v += x * std.math.pow(u64, 256, 3 - i);
    return @intCast(v);
}

fn parseIpv6(s: []const u8) Error![8]u16 {
    var addr: [8]u16 = @splat(0);
    var piece: usize = 0;
    var compress: ?usize = null;
    var p: usize = 0;
    const at = struct {
        fn f(str: []const u8, i: usize) ?u8 {
            return if (i < str.len) str[i] else null;
        }
    }.f;
    if (at(s, p) == ':') {
        if (at(s, p + 1) != ':') return error.Invalid;
        p += 2;
        piece += 1;
        compress = piece;
    }
    while (at(s, p) != null) {
        if (piece == 8) return error.Invalid;
        if (at(s, p) == ':') {
            if (compress != null) return error.Invalid;
            p += 1;
            piece += 1;
            compress = piece;
            continue;
        }
        var value: u32 = 0;
        var length: usize = 0;
        while (length < 4) : (length += 1) {
            const c = at(s, p) orelse break;
            const d = hexVal(c) orelse break;
            value = value * 16 + d;
            p += 1;
        }
        if (at(s, p) == '.') {
            if (length == 0) return error.Invalid;
            p -= length;
            if (piece > 6) return error.Invalid;
            var seen: usize = 0;
            while (at(s, p) != null) {
                var v4: ?u32 = null;
                if (seen > 0) {
                    if (at(s, p) == '.' and seen < 4) p += 1 else return error.Invalid;
                }
                const first = at(s, p) orelse return error.Invalid;
                if (!std.ascii.isDigit(first)) return error.Invalid;
                while (at(s, p)) |c| {
                    if (!std.ascii.isDigit(c)) break;
                    const number: u32 = c - '0';
                    if (v4 == null) v4 = number else if (v4.? == 0) return error.Invalid else v4 = v4.? * 10 + number;
                    if (v4.? > 255) return error.Invalid;
                    p += 1;
                }
                addr[piece] = @intCast(@as(u32, addr[piece]) * 0x100 + v4.?);
                seen += 1;
                if (seen == 2 or seen == 4) piece += 1;
            }
            if (seen != 4) return error.Invalid;
            break;
        } else if (at(s, p) == ':') {
            p += 1;
            if (at(s, p) == null) return error.Invalid;
        } else if (at(s, p) != null) return error.Invalid;
        addr[piece] = @intCast(value);
        piece += 1;
    }
    if (compress) |c| {
        var swaps = piece - c;
        piece = 7;
        while (piece != 0 and swaps > 0) {
            const tmp = addr[piece];
            addr[piece] = addr[c + swaps - 1];
            addr[c + swaps - 1] = tmp;
            piece -= 1;
            swaps -= 1;
        }
    } else if (piece != 8) return error.Invalid;
    return addr;
}

fn writeIpv6(pieces: [8]u16, a: std.mem.Allocator, out: *std.ArrayList(u8)) AllocError!void {
    // The longest run of zero pieces (two or more) is compressed.
    var best: ?usize = null;
    var best_len: usize = 0;
    var i: usize = 0;
    while (i < 8) {
        if (pieces[i] != 0) {
            i += 1;
            continue;
        }
        var j = i;
        while (j < 8 and pieces[j] == 0) j += 1;
        if (j - i > best_len and j - i >= 2) {
            best = i;
            best_len = j - i;
        }
        i = j;
    }
    var ignore0 = false;
    for (pieces, 0..) |piece, idx| {
        if (ignore0 and piece == 0) continue;
        if (ignore0) ignore0 = false;
        if (best == idx) {
            try out.appendSlice(a, if (idx == 0) "::" else ":");
            ignore0 = true;
            continue;
        }
        try out.print(a, "{x}", .{piece});
        if (idx != 7) try out.append(a, ':');
    }
}

// ----------------------------------------------------------------- parser

const State = enum { scheme_start, scheme, no_scheme, special_relative_or_authority, path_or_authority, relative, relative_slash, special_authority_slashes, special_authority_ignore_slashes, authority, host, port, file, file_slash, file_host, path_start, path, opaque_path, query, fragment };

fn isWindowsDriveLetter(s: []const u8) bool {
    return s.len == 2 and std.ascii.isAlphabetic(s[0]) and (s[1] == ':' or s[1] == '|');
}

fn isNormalizedWindowsDriveLetter(s: []const u8) bool {
    return isWindowsDriveLetter(s) and s[1] == ':';
}

fn startsWithWindowsDriveLetter(s: []const u8) bool {
    if (s.len < 2 or !isWindowsDriveLetter(s[0..2])) return false;
    if (s.len == 2) return true;
    return switch (s[2]) {
        '/', '\\', '?', '#' => true,
        else => false,
    };
}

fn isSingleDot(s: []const u8) bool {
    return std.mem.eql(u8, s, ".") or std.ascii.eqlIgnoreCase(s, "%2e");
}

fn isDoubleDot(s: []const u8) bool {
    return std.mem.eql(u8, s, "..") or std.ascii.eqlIgnoreCase(s, ".%2e") or std.ascii.eqlIgnoreCase(s, "%2e.") or std.ascii.eqlIgnoreCase(s, "%2e%2e");
}

const Segments = std.ArrayList([]const u8);

fn shortenPath(url_scheme: []const u8, path: *Segments) void {
    if (std.mem.eql(u8, url_scheme, "file") and path.items.len == 1 and isNormalizedWindowsDriveLetter(path.items[0])) return;
    if (path.items.len > 0) path.items.len -= 1;
}

fn clonePath(a: std.mem.Allocator, p: Path) Error!Segments {
    var segs: Segments = .empty;
    if (p == .list) try segs.appendSlice(a, p.list);
    return segs;
}

/// The basic URL parser: `input` against an optional `base`. Failure is
/// `error.Invalid`; the result's slices live in `a`.
pub fn parse(a: std.mem.Allocator, raw: []const u8, base: ?*const Url) Error!Url {
    // Strip leading and trailing C0 controls and spaces; drop tabs and
    // newlines anywhere.
    var trimmed = raw;
    while (trimmed.len > 0 and trimmed[0] <= 0x20) trimmed = trimmed[1..];
    while (trimmed.len > 0 and trimmed[trimmed.len - 1] <= 0x20) trimmed = trimmed[0 .. trimmed.len - 1];
    var cleaned: std.ArrayList(u8) = .empty;
    for (trimmed) |c| if (c != '\t' and c != '\n' and c != '\r') try cleaned.append(a, c);
    const input = cleaned.items;

    var url: Url = .{ .scheme = "" };
    var path: Segments = .empty;
    var opaque_path: std.ArrayList(u8) = .empty;
    var is_opaque_path = false;
    var query: std.ArrayList(u8) = .empty;
    var has_query = false;
    var fragment: std.ArrayList(u8) = .empty;
    var has_fragment = false;
    var buffer: std.ArrayList(u8) = .empty;
    var username: std.ArrayList(u8) = .empty;
    var password: std.ArrayList(u8) = .empty;
    var at_sign_seen = false;
    var inside_brackets = false;
    var password_token_seen = false;

    // The spec's pointer: a state may step it back (reprocess in a new
    // state, EOF included), forward one, or to -1 to start over; after a
    // run, EOF ends the loop and anything else advances by one.
    var state: State = .scheme_start;
    var p: isize = 0;
    const len: isize = @intCast(input.len);
    while (true) {
        const c: ?u8 = if (p >= 0 and p < len) input[@intCast(p)] else null;
        const remaining: []const u8 = if (p + 1 <= len) input[@intCast(p + 1)..] else "";
        switch (state) {
            .scheme_start => {
                if (c != null and std.ascii.isAlphabetic(c.?)) {
                    try buffer.append(a, std.ascii.toLower(c.?));
                    state = .scheme;
                } else {
                    state = .no_scheme;
                    p -= 1;
                }
            },
            .scheme => {
                if (c != null and (std.ascii.isAlphanumeric(c.?) or c.? == '+' or c.? == '-' or c.? == '.')) {
                    try buffer.append(a, std.ascii.toLower(c.?));
                } else if (c == ':') {
                    url.scheme = try a.dupe(u8, buffer.items);
                    buffer.clearRetainingCapacity();
                    if (std.mem.eql(u8, url.scheme, "file")) {
                        state = .file;
                    } else if (isSpecialScheme(url.scheme) and base != null and std.mem.eql(u8, base.?.scheme, url.scheme)) {
                        state = .special_relative_or_authority;
                    } else if (isSpecialScheme(url.scheme)) {
                        state = .special_authority_slashes;
                    } else if (remaining.len > 0 and remaining[0] == '/') {
                        state = .path_or_authority;
                        p += 1;
                    } else {
                        is_opaque_path = true;
                        state = .opaque_path;
                    }
                } else {
                    buffer.clearRetainingCapacity();
                    state = .no_scheme;
                    p = -1;
                }
            },
            .no_scheme => {
                const b = base orelse return error.Invalid;
                if (b.hasOpaquePath() and c != '#') return error.Invalid;
                if (b.hasOpaquePath()) {
                    url.scheme = b.scheme;
                    is_opaque_path = true;
                    try opaque_path.appendSlice(a, b.path.opaque_path);
                    url.query = b.query;
                    has_fragment = true;
                    state = .fragment;
                } else if (!std.mem.eql(u8, b.scheme, "file")) {
                    state = .relative;
                    p -= 1;
                } else {
                    state = .file;
                    p -= 1;
                }
            },
            .special_relative_or_authority => {
                if (c == '/' and remaining.len > 0 and remaining[0] == '/') {
                    state = .special_authority_ignore_slashes;
                    p += 1;
                } else {
                    state = .relative;
                    p -= 1;
                }
            },
            .path_or_authority => {
                if (c == '/') {
                    state = .authority;
                } else {
                    state = .path;
                    p -= 1;
                }
            },
            .relative => {
                const b = base.?;
                url.scheme = b.scheme;
                if (c == '/') {
                    state = .relative_slash;
                } else if (url.isSpecial() and c == '\\') {
                    state = .relative_slash;
                } else {
                    url.username = b.username;
                    url.password = b.password;
                    url.host = b.host;
                    url.port = b.port;
                    path = try clonePath(a, b.path);
                    url.query = b.query;
                    if (c == '?') {
                        has_query = true;
                        url.query = null;
                        state = .query;
                    } else if (c == '#') {
                        has_fragment = true;
                        state = .fragment;
                    } else if (c != null) {
                        url.query = null;
                        shortenPath(url.scheme, &path);
                        state = .path;
                        p -= 1;
                    }
                }
            },
            .relative_slash => {
                if (url.isSpecial() and (c == '/' or c == '\\')) {
                    state = .special_authority_ignore_slashes;
                } else if (c == '/') {
                    state = .authority;
                } else {
                    const b = base.?;
                    url.username = b.username;
                    url.password = b.password;
                    url.host = b.host;
                    url.port = b.port;
                    state = .path;
                    p -= 1;
                }
            },
            .special_authority_slashes => {
                if (c == '/' and remaining.len > 0 and remaining[0] == '/') {
                    state = .special_authority_ignore_slashes;
                    p += 1;
                } else {
                    state = .special_authority_ignore_slashes;
                    p -= 1;
                }
            },
            .special_authority_ignore_slashes => {
                if (c != '/' and c != '\\') {
                    state = .authority;
                    p -= 1;
                }
            },
            .authority => {
                if (c == '@') {
                    if (at_sign_seen) {
                        var prefixed: std.ArrayList(u8) = .empty;
                        try prefixed.appendSlice(a, "%40");
                        try prefixed.appendSlice(a, buffer.items);
                        buffer = prefixed;
                    }
                    at_sign_seen = true;
                    for (buffer.items) |bc| {
                        if (bc == ':' and !password_token_seen) {
                            password_token_seen = true;
                            continue;
                        }
                        if (password_token_seen) try encodeByte(.userinfo, bc, a, &password) else try encodeByte(.userinfo, bc, a, &username);
                    }
                    buffer.clearRetainingCapacity();
                } else if (c == null or c == '/' or c == '?' or c == '#' or (url.isSpecial() and c == '\\')) {
                    if (at_sign_seen and buffer.items.len == 0) return error.Invalid;
                    p -= @as(isize, @intCast(buffer.items.len)) + 1;
                    buffer.clearRetainingCapacity();
                    state = .host;
                } else {
                    try buffer.append(a, c.?);
                }
            },
            .host => {
                if (c == ':' and !inside_brackets) {
                    if (buffer.items.len == 0) return error.Invalid;
                    url.host = try parseHost(a, buffer.items, !url.isSpecial());
                    buffer.clearRetainingCapacity();
                    state = .port;
                } else if (c == null or c == '/' or c == '?' or c == '#' or (url.isSpecial() and c == '\\')) {
                    p -= 1;
                    if (url.isSpecial() and buffer.items.len == 0) return error.Invalid;
                    url.host = try parseHost(a, buffer.items, !url.isSpecial());
                    buffer.clearRetainingCapacity();
                    state = .path_start;
                } else {
                    if (c == '[') inside_brackets = true;
                    if (c == ']') inside_brackets = false;
                    try buffer.append(a, c.?);
                }
            },
            .port => {
                if (c != null and std.ascii.isDigit(c.?)) {
                    try buffer.append(a, c.?);
                } else if (c == null or c == '/' or c == '?' or c == '#' or (url.isSpecial() and c == '\\')) {
                    if (buffer.items.len > 0) {
                        var port: u32 = 0;
                        for (buffer.items) |d| {
                            port = port * 10 + (d - '0');
                            if (port > 65535) return error.Invalid;
                        }
                        url.port = if (defaultPort(url.scheme) == @as(u16, @intCast(port))) null else @intCast(port);
                        buffer.clearRetainingCapacity();
                    }
                    state = .path_start;
                    p -= 1;
                } else return error.Invalid;
            },
            .file => {
                url.scheme = "file";
                url.host = .empty;
                if (c == '/' or c == '\\') {
                    state = .file_slash;
                } else if (base != null and std.mem.eql(u8, base.?.scheme, "file")) {
                    const b = base.?;
                    url.host = b.host;
                    path = try clonePath(a, b.path);
                    url.query = b.query;
                    if (c == '?') {
                        has_query = true;
                        url.query = null;
                        state = .query;
                    } else if (c == '#') {
                        has_fragment = true;
                        state = .fragment;
                    } else if (c != null) {
                        url.query = null;
                        if (!startsWithWindowsDriveLetter(input[@intCast(p)..])) shortenPath(url.scheme, &path) else path.clearRetainingCapacity();
                        state = .path;
                        p -= 1;
                    }
                } else {
                    state = .path;
                    p -= 1;
                }
            },
            .file_slash => {
                if (c == '/' or c == '\\') {
                    state = .file_host;
                } else {
                    if (base != null and std.mem.eql(u8, base.?.scheme, "file")) {
                        const b = base.?;
                        url.host = b.host;
                        if (!startsWithWindowsDriveLetter(input[@intCast(p)..]) and b.path == .list and b.path.list.len > 0 and isNormalizedWindowsDriveLetter(b.path.list[0])) {
                            try path.append(a, b.path.list[0]);
                        }
                    }
                    state = .path;
                    p -= 1;
                }
            },
            .file_host => {
                if (c == null or c == '/' or c == '\\' or c == '?' or c == '#') {
                    p -= 1;
                    if (isWindowsDriveLetter(buffer.items)) {
                        state = .path; // the buffer carries into the path state
                    } else if (buffer.items.len == 0) {
                        url.host = .empty;
                        state = .path_start;
                    } else {
                        var h = try parseHost(a, buffer.items, !url.isSpecial());
                        if (h == .domain and std.mem.eql(u8, h.domain, "localhost")) h = .empty;
                        url.host = h;
                        buffer.clearRetainingCapacity();
                        state = .path_start;
                    }
                } else {
                    try buffer.append(a, c.?);
                }
            },
            .path_start => {
                if (url.isSpecial()) {
                    state = .path;
                    if (c != '/' and c != '\\') p -= 1;
                } else if (c == '?') {
                    has_query = true;
                    state = .query;
                } else if (c == '#') {
                    has_fragment = true;
                    state = .fragment;
                } else if (c != null) {
                    state = .path;
                    if (c != '/') p -= 1;
                }
            },
            .path => {
                const ends = c == null or c == '/' or (url.isSpecial() and c == '\\') or c == '?' or c == '#';
                if (ends) {
                    const slash = c == '/' or (url.isSpecial() and c == '\\');
                    if (isDoubleDot(buffer.items)) {
                        shortenPath(url.scheme, &path);
                        if (!slash) try path.append(a, "");
                    } else if (isSingleDot(buffer.items) and !slash) {
                        try path.append(a, "");
                    } else if (!isSingleDot(buffer.items)) {
                        if (std.mem.eql(u8, url.scheme, "file") and path.items.len == 0 and isWindowsDriveLetter(buffer.items)) {
                            buffer.items[1] = ':';
                        }
                        try path.append(a, try a.dupe(u8, buffer.items));
                    }
                    buffer.clearRetainingCapacity();
                    if (c == '?') {
                        has_query = true;
                        state = .query;
                    }
                    if (c == '#') {
                        has_fragment = true;
                        state = .fragment;
                    }
                } else {
                    try encodeByte(.path, c.?, a, &buffer);
                }
            },
            .opaque_path => {
                if (c == '?') {
                    has_query = true;
                    state = .query;
                } else if (c == '#') {
                    has_fragment = true;
                    state = .fragment;
                } else if (c == ' ') {
                    if (remaining.len > 0 and (remaining[0] == '?' or remaining[0] == '#')) try opaque_path.appendSlice(a, "%20") else try opaque_path.append(a, ' ');
                } else if (c != null) {
                    try encodeByte(.c0, c.?, a, &opaque_path);
                }
            },
            .query => {
                if (c == '#' or c == null) {
                    try encodeSlice(if (url.isSpecial()) .special_query else .query, buffer.items, a, &query);
                    buffer.clearRetainingCapacity();
                    if (c == '#') {
                        has_fragment = true;
                        state = .fragment;
                    }
                } else {
                    try buffer.append(a, c.?);
                }
            },
            .fragment => {
                if (c != null) try encodeByte(.fragment, c.?, a, &fragment);
            },
        }
        if (p >= len) break;
        p += 1;
    }
    url.username = username.items;
    url.password = password.items;
    url.path = if (is_opaque_path) .{ .opaque_path = opaque_path.items } else .{ .list = path.items };
    if (has_query) url.query = query.items;
    if (has_fragment) url.fragment = fragment.items;
    return url;
}

/// Resolve `input` against `base` — the common case of a link on a page.
pub fn resolve(a: std.mem.Allocator, input: []const u8, base: *const Url) Error!Url {
    return parse(a, input, base);
}

// ------------------------------------------------------------------ tests

test "url: the basics parse and serialize" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const u = try parse(a, "HTTPS://Example.COM:443/a/./b/../c?q=1#frag", null);
    try std.testing.expectEqualStrings("https://example.com/a/c?q=1#frag", try u.href(a));
    try std.testing.expectEqualStrings("https://example.com", try u.origin(a));
    try std.testing.expect(u.port == null);
    const rel = try resolve(a, "../d?x", &u);
    try std.testing.expectEqualStrings("https://example.com/d?x", try rel.href(a));
    const v4 = try parse(a, "http://0x7f.1/", null);
    try std.testing.expectEqualStrings("http://127.0.0.1/", try v4.href(a));
    const v6 = try parse(a, "http://[2001:DB8:0:0:0:0:0:1]:8080/p", null);
    try std.testing.expectEqualStrings("http://[2001:db8::1]:8080/p", try v6.href(a));
    const idn = try parse(a, "http://bücher.example/", null);
    try std.testing.expectEqualStrings("http://xn--bcher-kva.example/", try idn.href(a));
    const op = try parse(a, "mailto:someone@example.com", null);
    try std.testing.expect(op.hasOpaquePath());
    try std.testing.expectEqualStrings("null", try op.origin(a));
    try std.testing.expectError(error.Invalid, parse(a, "http://", null));
    try std.testing.expectError(error.Invalid, parse(a, "nope", null));
}

// Flip to list the corpus entries that disagree.
const verbose = false;

test "url: the WPT corpus, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = std.Io.Dir.cwd().readFileAlloc(io, "tools/testdata/web/wpt/url/urltestdata.json", a, .limited(8 << 20)) catch return error.SkipZigTest;
    const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
    var total: usize = 0;
    var passed: usize = 0;
    for (parsed.array.items) |entry| {
        if (entry != .object) continue; // section comments
        const obj = entry.object;
        total += 1;
        const input = obj.get("input").?.string;
        var base_url: ?Url = null;
        if (obj.get("base")) |b| if (b == .string) {
            base_url = parse(a, b.string, null) catch null;
            if (base_url == null) continue; // a base that must parse
        };
        const want_failure = if (obj.get("failure")) |f| f == .bool and f.bool else false;
        const got = parse(a, input, if (base_url) |*b| b else null) catch {
            if (want_failure) passed += 1 else if (verbose) std.debug.print("  refused: {s}\n", .{input});
            continue;
        };
        if (want_failure) {
            if (verbose) std.debug.print("  accepted: {s} -> {s}\n", .{ input, try got.href(a) });
            continue;
        }
        var ok = std.mem.eql(u8, obj.get("href").?.string, try got.href(a));
        if (!ok and verbose) std.debug.print("  href: {s} -> {s} (want {s})\n", .{ input, try got.href(a), obj.get("href").?.string });
        const Getter = struct { key: []const u8, f: *const fn (*const Url, std.mem.Allocator) AllocError![]u8 };
        const getters = [_]Getter{
            .{ .key = "origin", .f = Url.origin },
            .{ .key = "protocol", .f = Url.protocol },
            .{ .key = "host", .f = Url.hostString },
            .{ .key = "hostname", .f = Url.hostname },
            .{ .key = "port", .f = Url.portString },
            .{ .key = "pathname", .f = Url.pathname },
            .{ .key = "search", .f = Url.search },
            .{ .key = "hash", .f = Url.hash },
        };
        for (getters) |g| if (obj.get(g.key)) |v| if (v == .string) {
            if (!std.mem.eql(u8, v.string, try g.f(&got, a))) ok = false;
        };
        if (obj.get("username")) |v| if (!std.mem.eql(u8, v.string, got.username)) {
            ok = false;
        };
        if (obj.get("password")) |v| if (!std.mem.eql(u8, v.string, got.password)) {
            ok = false;
        };
        if (ok) passed += 1;
    }
    std.debug.print("url: {d}/{d} of urltestdata.json agree\n", .{ passed, total });
    // The floor is the count as of 2026-09-18 (`verbose` lists the rest):
    // a change that loses an entry fails here.
    try std.testing.expect(passed >= 875);
}

test "url: data: URLs decode, plain and base64" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const plain = (try decodeData(a, "data:image/svg+xml;utf8,<svg fill=%22%23000%22/>")).?;
    try std.testing.expectEqualStrings("image/svg+xml;utf8", plain.mime);
    try std.testing.expectEqualStrings("<svg fill=\"#000\"/>", plain.bytes);
    const b64 = (try decodeData(a, "data:text/plain;base64,aGVsbG8=")).?;
    try std.testing.expectEqualStrings("text/plain", b64.mime);
    try std.testing.expectEqualStrings("hello", b64.bytes);
    try std.testing.expect((try decodeData(a, "https://x/")) == null);
}
