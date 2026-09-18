//! The Encoding Standard (https://encoding.spec.whatwg.org/), the part a
//! fetcher and a parser need: labels to encodings, the byte-order mark,
//! the charset of a Content-Type, the HTML prescan for `<meta charset>`,
//! and decoding to UTF-8 — the language's strings are UTF-8 by
//! guarantee, so every byte stream is decoded at the boundary. The
//! encodings are UTF-8, windows-1252 (the web's "latin1", and what an
//! unknown label falls back to), and UTF-16 both ways; the other legacy
//! single-byte and CJK encodings are not built, and their labels answer
//! `null` so a caller can say so rather than guess.
const std = @import("std");

pub const Encoding = enum { utf8, windows1252, utf16le, utf16be };

pub const Error = error{OutOfMemory};

/// A label (a Content-Type charset, a `<meta>` value) to its encoding:
/// trimmed of ASCII whitespace, case-insensitive; null for a label the
/// standard knows but this file does not decode, and for an unknown one.
pub fn fromLabel(raw: []const u8) ?Encoding {
    const label = std.mem.trim(u8, raw, " \t\n\r\x0c");
    const eq = std.ascii.eqlIgnoreCase;
    const utf8_labels = [_][]const u8{ "unicode-1-1-utf-8", "unicode11utf8", "unicode20utf8", "utf-8", "utf8", "x-unicode20utf8" };
    for (utf8_labels) |l| if (eq(label, l)) return .utf8;
    const w1252 = [_][]const u8{ "ansi_x3.4-1968", "ascii", "cp1252", "cp819", "csisolatin1", "ibm819", "iso-8859-1", "iso-ir-100", "iso8859-1", "iso88591", "iso_8859-1", "iso_8859-1:1987", "l1", "latin1", "us-ascii", "windows-1252", "x-cp1252", "x-user-defined" };
    for (w1252) |l| if (eq(label, l)) return .windows1252;
    const le = [_][]const u8{ "csunicode", "iso-10646-ucs-2", "ucs-2", "unicode", "unicodefeff", "utf-16", "utf-16le" };
    for (le) |l| if (eq(label, l)) return .utf16le;
    const be = [_][]const u8{ "unicodefffe", "utf-16be" };
    for (be) |l| if (eq(label, l)) return .utf16be;
    return null;
}

pub fn name(e: Encoding) []const u8 {
    return switch (e) {
        .utf8 => "UTF-8",
        .windows1252 => "windows-1252",
        .utf16le => "UTF-16LE",
        .utf16be => "UTF-16BE",
    };
}

/// The byte-order mark, and how many bytes it takes.
pub fn sniffBom(bytes: []const u8) ?struct { encoding: Encoding, len: usize } {
    if (bytes.len >= 3 and bytes[0] == 0xef and bytes[1] == 0xbb and bytes[2] == 0xbf) return .{ .encoding = .utf8, .len = 3 };
    if (bytes.len >= 2 and bytes[0] == 0xfe and bytes[1] == 0xff) return .{ .encoding = .utf16be, .len = 2 };
    if (bytes.len >= 2 and bytes[0] == 0xff and bytes[1] == 0xfe) return .{ .encoding = .utf16le, .len = 2 };
    return null;
}

/// The `charset` parameter of a Content-Type value, as a label.
pub fn charsetOfContentType(ct: []const u8) ?[]const u8 {
    var it = std.mem.splitScalar(u8, ct, ';');
    _ = it.next(); // the type
    while (it.next()) |param| {
        const eqi = std.mem.indexOfScalar(u8, param, '=') orelse continue;
        const key = std.mem.trim(u8, param[0..eqi], " \t");
        if (!std.ascii.eqlIgnoreCase(key, "charset")) continue;
        var v = std.mem.trim(u8, param[eqi + 1 ..], " \t");
        if (v.len >= 2 and v[0] == '"' and v[v.len - 1] == '"') v = v[1 .. v.len - 1];
        return v;
    }
    return null;
}

/// The "algorithm for extracting a character encoding from a meta
/// element": the label after `charset=` in a `content` value.
pub fn charsetOfMetaContent(content: []const u8) ?[]const u8 {
    var pos: usize = 0;
    while (std.ascii.indexOfIgnoreCasePos(content, pos, "charset")) |i| {
        pos = i + "charset".len;
        while (pos < content.len and isSpace(content[pos])) pos += 1;
        if (pos >= content.len or content[pos] != '=') continue;
        pos += 1;
        while (pos < content.len and isSpace(content[pos])) pos += 1;
        if (pos >= content.len) return null;
        if (content[pos] == '"' or content[pos] == '\'') {
            const q = content[pos];
            const end = std.mem.indexOfScalarPos(u8, content, pos + 1, q) orelse return null;
            return content[pos + 1 .. end];
        }
        var end = pos;
        while (end < content.len and !isSpace(content[end]) and content[end] != ';') end += 1;
        return content[pos..end];
    }
    return null;
}

fn isSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

/// The HTML Standard's "prescan a byte stream to determine its
/// encoding", over at most the first 1024 bytes: the encoding a
/// `<meta charset>` or `<meta http-equiv=content-type>` declares, or
/// null. A UTF-16 label found here means UTF-8 (a document readable
/// enough to prescan is not UTF-16), and `x-user-defined` windows-1252,
/// as the standard says.
pub fn prescan(input: []const u8) ?Encoding {
    const bytes = input[0..@min(input.len, 1024)];
    var pos: usize = 0;
    while (pos < bytes.len) {
        if (std.mem.startsWith(u8, bytes[pos..], "<!--")) {
            pos = (std.mem.indexOfPos(u8, bytes, pos + 2, "-->") orelse return null) + 3;
            continue;
        }
        if (std.ascii.startsWithIgnoreCase(bytes[pos..], "<meta") and pos + 5 < bytes.len and (isSpace(bytes[pos + 5]) or bytes[pos + 5] == '/')) {
            pos += 5;
            var got_pragma = false;
            var need_pragma: ?bool = null;
            var charset: ?Encoding = null;
            var seen: [8][]const u8 = undefined;
            var seen_n: usize = 0;
            var scratch: [32]u8 = undefined;
            while (getAttribute(bytes, &pos, &scratch)) |attr| {
                var dup = false;
                for (seen[0..seen_n]) |sn| if (std.mem.eql(u8, sn, attr.name)) {
                    dup = true;
                };
                if (dup) continue;
                if (seen_n < seen.len) {
                    seen[seen_n] = attr.name;
                    seen_n += 1;
                }
                if (std.mem.eql(u8, attr.name, "http-equiv")) {
                    if (std.ascii.eqlIgnoreCase(attr.value, "content-type")) got_pragma = true;
                } else if (std.mem.eql(u8, attr.name, "content")) {
                    if (charset == null) if (charsetOfMetaContent(attr.value)) |label| if (fromLabel(label)) |e| {
                        charset = e;
                        need_pragma = true;
                    };
                } else if (std.mem.eql(u8, attr.name, "charset")) {
                    charset = fromLabel(attr.value);
                    need_pragma = false;
                }
            }
            if (need_pragma == null) continue;
            if (need_pragma.? and !got_pragma) continue;
            const e = charset orelse continue;
            return switch (e) {
                .utf16le, .utf16be => .utf8,
                else => e,
            };
        }
        if (pos + 1 < bytes.len and bytes[pos] == '<' and (std.ascii.isAlphabetic(bytes[pos + 1]) or (bytes[pos + 1] == '/' and pos + 2 < bytes.len and std.ascii.isAlphabetic(bytes[pos + 2])))) {
            // A tag: skip its name, then its attributes.
            pos += 1;
            while (pos < bytes.len and !isSpace(bytes[pos]) and bytes[pos] != '>') pos += 1;
            var scratch: [32]u8 = undefined;
            while (getAttribute(bytes, &pos, &scratch)) |_| {}
            continue;
        }
        if (pos + 1 < bytes.len and bytes[pos] == '<' and (bytes[pos + 1] == '!' or bytes[pos + 1] == '/' or bytes[pos + 1] == '?')) {
            pos = (std.mem.indexOfScalarPos(u8, bytes, pos, '>') orelse return null) + 1;
            continue;
        }
        pos += 1;
    }
    return null;
}

const Attr = struct { name: []const u8, value: []const u8 };

/// The prescan's "get an attribute": names and values lowercased in
/// place is not possible over a const slice, so names are compared
/// lowercased through a small buffer; values come back as written
/// (labels are matched case-insensitively anyway).
fn getAttribute(bytes: []const u8, pos: *usize, scratch: *[32]u8) ?Attr {
    while (pos.* < bytes.len and (isSpace(bytes[pos.*]) or bytes[pos.*] == '/')) pos.* += 1;
    if (pos.* >= bytes.len or bytes[pos.*] == '>') return null;
    const name_start = pos.*;
    while (pos.* < bytes.len) {
        const c = bytes[pos.*];
        if (c == '=' and pos.* > name_start) break;
        if (isSpace(c) or c == '/' or c == '>') break;
        pos.* += 1;
    }
    const attr_name = lowerAscii(scratch, bytes[name_start..pos.*]);
    while (pos.* < bytes.len and isSpace(bytes[pos.*])) pos.* += 1;
    if (pos.* >= bytes.len or bytes[pos.*] != '=') return .{ .name = attr_name, .value = "" };
    pos.* += 1;
    while (pos.* < bytes.len and isSpace(bytes[pos.*])) pos.* += 1;
    if (pos.* >= bytes.len) return .{ .name = attr_name, .value = "" };
    if (bytes[pos.*] == '"' or bytes[pos.*] == '\'') {
        const q = bytes[pos.*];
        const start = pos.* + 1;
        const end = std.mem.indexOfScalarPos(u8, bytes, start, q) orelse {
            pos.* = bytes.len;
            return .{ .name = attr_name, .value = "" };
        };
        pos.* = end + 1;
        return .{ .name = attr_name, .value = bytes[start..end] };
    }
    const start = pos.*;
    while (pos.* < bytes.len and !isSpace(bytes[pos.*]) and bytes[pos.*] != '>') pos.* += 1;
    return .{ .name = attr_name, .value = bytes[start..pos.*] };
}

// Attribute names the prescan cares about are ASCII; a name longer than
// the caller's scratch cannot match and is returned as-is. (The scratch
// was a `threadlocal` once: a user program has no thread-local storage,
// so the first real page's prescan died of a data abort at a null TLS
// base — nothing a user program links may be `threadlocal`.)
fn lowerAscii(scratch: *[32]u8, s: []const u8) []const u8 {
    if (s.len > scratch.len) return s;
    for (s, 0..) |c, i| scratch[i] = std.ascii.toLower(c);
    return scratch[0..s.len];
}

/// What a document is in: the BOM first, then the transport's charset,
/// then the prescan, then UTF-8 — the order the HTML Standard gives.
pub fn detect(bytes: []const u8, content_type: ?[]const u8) Encoding {
    if (sniffBom(bytes)) |b| return b.encoding;
    if (content_type) |ct| if (charsetOfContentType(ct)) |label| if (fromLabel(label)) |e| return e;
    if (prescan(bytes)) |e| return e;
    return .utf8;
}

const w1252_high = [32]u21{ 0x20ac, 0x81, 0x201a, 0x0192, 0x201e, 0x2026, 0x2020, 0x2021, 0x02c6, 0x2030, 0x0160, 0x2039, 0x0152, 0x8d, 0x017d, 0x8f, 0x90, 0x2018, 0x2019, 0x201c, 0x201d, 0x2022, 0x2013, 0x2014, 0x02dc, 0x2122, 0x0161, 0x203a, 0x0153, 0x9d, 0x017e, 0x0178 };

/// Decode to UTF-8, a BOM of the same encoding dropped, malformed input
/// replaced by U+FFFD; UTF-8 input that is already valid is returned as
/// given (no copy).
pub fn decode(a: std.mem.Allocator, e: Encoding, input: []const u8) Error![]const u8 {
    var bytes = input;
    if (sniffBom(bytes)) |b| if (b.encoding == e) {
        bytes = bytes[b.len..];
    };
    switch (e) {
        .utf8 => {
            if (std.unicode.utf8ValidateSlice(bytes)) return bytes;
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i < bytes.len) {
                const n = std.unicode.utf8ByteSequenceLength(bytes[i]) catch {
                    try out.appendSlice(a, "\u{fffd}");
                    i += 1;
                    continue;
                };
                if (i + n > bytes.len or !std.unicode.utf8ValidateSlice(bytes[i .. i + n])) {
                    try out.appendSlice(a, "\u{fffd}");
                    i += 1;
                    continue;
                }
                try out.appendSlice(a, bytes[i .. i + n]);
                i += n;
            }
            return out.items;
        },
        .windows1252 => {
            var out: std.ArrayList(u8) = .empty;
            for (bytes) |c| {
                const cp: u21 = if (c < 0x80) c else if (c < 0xa0) w1252_high[c - 0x80] else c;
                try appendCp(a, &out, cp);
            }
            return out.items;
        },
        .utf16le, .utf16be => {
            var out: std.ArrayList(u8) = .empty;
            var i: usize = 0;
            while (i + 1 < bytes.len) : (i += 2) {
                const unit: u16 = if (e == .utf16le) (@as(u16, bytes[i + 1]) << 8) | bytes[i] else (@as(u16, bytes[i]) << 8) | bytes[i + 1];
                if (unit >= 0xd800 and unit < 0xdc00 and i + 3 < bytes.len) {
                    const low: u16 = if (e == .utf16le) (@as(u16, bytes[i + 3]) << 8) | bytes[i + 2] else (@as(u16, bytes[i + 2]) << 8) | bytes[i + 3];
                    if (low >= 0xdc00 and low < 0xe000) {
                        try appendCp(a, &out, 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (low - 0xdc00));
                        i += 2;
                        continue;
                    }
                }
                if (unit >= 0xd800 and unit < 0xe000) try out.appendSlice(a, "\u{fffd}") else try appendCp(a, &out, unit);
            }
            if (i < bytes.len) try out.appendSlice(a, "\u{fffd}"); // a dangling byte
            return out.items;
        },
    }
}

fn appendCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buf: [4]u8 = undefined;
    const n = std.unicode.utf8Encode(cp, &buf) catch {
        try out.appendSlice(a, "\u{fffd}");
        return;
    };
    try out.appendSlice(a, buf[0..n]);
}

test "encoding: labels, BOMs and content types" {
    try std.testing.expectEqual(Encoding.utf8, fromLabel("  UTF-8 ").?);
    try std.testing.expectEqual(Encoding.windows1252, fromLabel("latin1").?);
    try std.testing.expectEqual(Encoding.windows1252, fromLabel("ISO-8859-1").?);
    try std.testing.expectEqual(Encoding.utf16le, fromLabel("utf-16").?);
    try std.testing.expect(fromLabel("shift_jis") == null);
    try std.testing.expectEqual(Encoding.utf16be, sniffBom("\xfe\xff\x00a").?.encoding);
    try std.testing.expectEqualStrings("iso-8859-1", charsetOfContentType("text/html; charset=iso-8859-1").?);
    try std.testing.expectEqualStrings("utf-8", charsetOfContentType("text/html;charset=\"utf-8\"").?);
    try std.testing.expect(charsetOfContentType("text/plain") == null);
}

test "encoding: the meta prescan" {
    try std.testing.expectEqual(Encoding.windows1252, prescan("<!DOCTYPE html><html><head><META Charset='latin1'>").?);
    try std.testing.expectEqual(Encoding.utf8, prescan("<head><meta http-equiv=\"Content-Type\" content=\"text/html; charset=utf-16\">").?);
    try std.testing.expect(prescan("<head><meta content=\"text/html; charset=latin1\">") == null); // no pragma
    try std.testing.expect(prescan("<!-- <meta charset=latin1> --><p>hi") == null);
    try std.testing.expectEqual(Encoding.windows1252, prescan("<p class=x data-a=\"<meta charset=utf-8>\"><meta charset=windows-1252>").?);
    try std.testing.expectEqual(Encoding.windows1252, detect("<meta charset=latin1>", "text/html"));
    try std.testing.expectEqual(Encoding.utf8, detect("<meta charset=latin1>", "text/html; charset=utf-8"));
    try std.testing.expectEqual(Encoding.utf16be, detect("\xfe\xff<meta charset=latin1>", "text/html; charset=utf-8"));
}

test "encoding: decoding to UTF-8" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectEqualStrings("caf\u{e9} \u{20ac}", try decode(a, .windows1252, "caf\xe9 \x80"));
    try std.testing.expectEqualStrings("hi", try decode(a, .utf8, "\xef\xbb\xbfhi"));
    try std.testing.expectEqualStrings("a\u{fffd}b", try decode(a, .utf8, "a\xffb"));
    try std.testing.expectEqualStrings("A\u{1f600}", try decode(a, .utf16le, "A\x00\x3d\xd8\x00\xde"));
    try std.testing.expectEqualStrings("A", try decode(a, .utf16be, "\xfe\xff\x00A"));
}
