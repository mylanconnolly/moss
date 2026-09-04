//! JSON for mshl values: the web's interchange form beside the
//! language's own data syntax. `encode` writes the data subset (a
//! table is an array of objects; nothing is null); `decode` reads
//! objects as records (keys in the order written), arrays as lists,
//! integers as ints, strings (with \u escapes, surrogate pairs joined)
//! as UTF-8 strings. Numbers with a fraction or exponent are refused:
//! the language has no floats yet, and a rounded number is a lie.

const std = @import("std");
const mshl = @import("mshl.zig");
const Value = mshl.Value;
const Error = mshl.Error;

pub fn encode(v: Value, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .nothing => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |i| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0");
        },
        .str => |s| try writeStr(s, a, out),
        .list => |l| {
            try out.append(a, '[');
            for (l, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try encode(item, a, out);
            }
            try out.append(a, ']');
        },
        .record => |r| try writeObject(r.keys, r.vals, a, out),
        .table => |t| {
            try out.append(a, '[');
            for (t.rows, 0..) |row, i| {
                if (i > 0) try out.append(a, ',');
                try writeObject(t.cols, row, a, out);
            }
            try out.append(a, ']');
        },
        .bytes, .func, .result, .handle => return Error.Runtime,
    }
}

fn writeObject(keys: []const []const u8, vals: []const Value, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    try out.append(a, '{');
    for (keys, vals, 0..) |k, val, i| {
        if (i > 0) try out.append(a, ',');
        try writeStr(k, a, out);
        try out.append(a, ':');
        try encode(val, a, out);
    }
    try out.append(a, '}');
}

fn writeStr(s: []const u8, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '\r' => try out.appendSlice(a, "\\r"),
        '\t' => try out.appendSlice(a, "\\t"),
        0...8, 11, 12, 14...31 => {
            var buf: [8]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch "?");
        },
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

pub const DecodeError = error{ OutOfMemory, BadJson, Float, Utf8 };

/// One JSON value; anything after it but whitespace is an error.
pub fn decode(a: std.mem.Allocator, text: []const u8) DecodeError!Value {
    var p = Parser{ .a = a, .src = text };
    p.ws();
    const v = try p.value();
    p.ws();
    if (p.pos != p.src.len) return error.BadJson;
    return v;
}

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    depth: usize = 0,

    fn ws(p: *Parser) void {
        while (p.pos < p.src.len and (p.src[p.pos] == ' ' or p.src[p.pos] == '\t' or p.src[p.pos] == '\n' or p.src[p.pos] == '\r')) p.pos += 1;
    }

    fn peek(p: *Parser) ?u8 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }

    fn expect(p: *Parser, word: []const u8) DecodeError!void {
        if (!std.mem.startsWith(u8, p.src[p.pos..], word)) return error.BadJson;
        p.pos += word.len;
    }

    fn value(p: *Parser) DecodeError!Value {
        const c = p.peek() orelse return error.BadJson;
        switch (c) {
            '{' => return p.object(),
            '[' => return p.array(),
            '"' => return .{ .str = try p.string() },
            't' => {
                try p.expect("true");
                return .{ .bool = true };
            },
            'f' => {
                try p.expect("false");
                return .{ .bool = false };
            },
            'n' => {
                try p.expect("null");
                return .nothing;
            },
            '-', '0'...'9' => return p.number(),
            else => return error.BadJson,
        }
    }

    fn nest(p: *Parser) DecodeError!void {
        p.depth += 1;
        if (p.depth > 64) return error.BadJson;
    }

    fn object(p: *Parser) DecodeError!Value {
        try p.nest();
        defer p.depth -= 1;
        p.pos += 1;
        var keys: std.ArrayList([]const u8) = .empty;
        var vals: std.ArrayList(Value) = .empty;
        p.ws();
        if (p.peek() == '}') {
            p.pos += 1;
            return .{ .record = .{ .keys = keys.items, .vals = vals.items } };
        }
        while (true) {
            p.ws();
            if (p.peek() != '"') return error.BadJson;
            const k = try p.string();
            p.ws();
            if (p.peek() != ':') return error.BadJson;
            p.pos += 1;
            p.ws();
            const v = try p.value();
            try keys.append(p.a, k);
            try vals.append(p.a, v);
            p.ws();
            const c = p.peek() orelse return error.BadJson;
            p.pos += 1;
            if (c == '}') break;
            if (c != ',') return error.BadJson;
        }
        return .{ .record = .{ .keys = keys.items, .vals = vals.items } };
    }

    fn array(p: *Parser) DecodeError!Value {
        try p.nest();
        defer p.depth -= 1;
        p.pos += 1;
        var items: std.ArrayList(Value) = .empty;
        p.ws();
        if (p.peek() == ']') {
            p.pos += 1;
            return .{ .list = items.items };
        }
        while (true) {
            p.ws();
            try items.append(p.a, try p.value());
            p.ws();
            const c = p.peek() orelse return error.BadJson;
            p.pos += 1;
            if (c == ']') break;
            if (c != ',') return error.BadJson;
        }
        return .{ .list = items.items };
    }

    fn number(p: *Parser) DecodeError!Value {
        const start = p.pos;
        if (p.peek() == '-') p.pos += 1;
        if (p.peek() == null or !std.ascii.isDigit(p.src[p.pos])) return error.BadJson;
        while (p.pos < p.src.len and std.ascii.isDigit(p.src[p.pos])) p.pos += 1;
        if (p.pos < p.src.len and (p.src[p.pos] == '.' or p.src[p.pos] == 'e' or p.src[p.pos] == 'E')) return error.Float;
        const n = std.fmt.parseInt(i64, p.src[start..p.pos], 10) catch return error.BadJson;
        return .{ .int = n };
    }

    fn hex4(p: *Parser) DecodeError!u16 {
        if (p.pos + 4 > p.src.len) return error.BadJson;
        const v = std.fmt.parseInt(u16, p.src[p.pos .. p.pos + 4], 16) catch return error.BadJson;
        p.pos += 4;
        return v;
    }

    fn string(p: *Parser) DecodeError![]const u8 {
        p.pos += 1; // the opening quote
        var out: std.ArrayList(u8) = .empty;
        while (true) {
            const c = p.peek() orelse return error.BadJson;
            p.pos += 1;
            switch (c) {
                '"' => break,
                '\\' => {
                    const e = p.peek() orelse return error.BadJson;
                    p.pos += 1;
                    switch (e) {
                        '"', '\\', '/' => try out.append(p.a, e),
                        'n' => try out.append(p.a, '\n'),
                        'r' => try out.append(p.a, '\r'),
                        't' => try out.append(p.a, '\t'),
                        'b' => try out.append(p.a, 8),
                        'f' => try out.append(p.a, 12),
                        'u' => {
                            var cp: u21 = try p.hex4();
                            if (cp >= 0xd800 and cp < 0xdc00) {
                                // A surrogate pair: the low half must follow.
                                try p.expect("\\u");
                                const lo = try p.hex4();
                                if (lo < 0xdc00 or lo >= 0xe000) return error.BadJson;
                                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                            } else if (cp >= 0xdc00 and cp < 0xe000) return error.BadJson;
                            var buf: [4]u8 = undefined;
                            const n = std.unicode.utf8Encode(cp, &buf) catch return error.BadJson;
                            try out.appendSlice(p.a, buf[0..n]);
                        },
                        else => return error.BadJson,
                    }
                },
                0...31 => return error.BadJson,
                else => try out.append(p.a, c),
            }
        }
        if (!std.unicode.utf8ValidateSlice(out.items)) return error.Utf8;
        return out.items;
    }
};

test "json: encode the data subset" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var out: std.ArrayList(u8) = .empty;
    const keys = [_][]const u8{ "name", "size", "ok", "tags", "none" };
    const tags = [_]Value{ .{ .str = "a\"b" }, .{ .str = "line\nbreak" } };
    const vals = [_]Value{ .{ .str = "hi.txt" }, .{ .int = -27 }, .{ .bool = true }, .{ .list = &tags }, .nothing };
    try encode(.{ .record = .{ .keys = &keys, .vals = &vals } }, a, &out);
    try std.testing.expectEqualStrings("{\"name\":\"hi.txt\",\"size\":-27,\"ok\":true,\"tags\":[\"a\\\"b\",\"line\\nbreak\"],\"none\":null}", out.items);
    out.clearRetainingCapacity();
    const cols = [_][]const u8{ "n", "s" };
    const rows = [_][]const Value{ &.{ .{ .int = 1 }, .{ .str = "x" } }, &.{ .{ .int = 2 }, .{ .str = "y" } } };
    try encode(.{ .table = .{ .cols = &cols, .rows = &rows } }, a, &out);
    try std.testing.expectEqualStrings("[{\"n\":1,\"s\":\"x\"},{\"n\":2,\"s\":\"y\"}]", out.items);
    try std.testing.expectError(Error.Runtime, encode(.{ .bytes = "x" }, a, &out));
}

test "json: decode objects, arrays, strings with escapes, and refuse floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const v = try decode(a, " {\"a\": [1, -2, {\"b\": null}], \"s\": \"caf\\u00e9 \\ud83d\\ude00 \\\"q\\\"\", \"t\": true} ");
    try std.testing.expect(v == .record);
    try std.testing.expectEqual(@as(i64, -2), v.record.get("a").?.list[1].int);
    try std.testing.expect(v.record.get("a").?.list[2].record.get("b").? == .nothing);
    try std.testing.expectEqualStrings("café 😀 \"q\"", v.record.get("s").?.str);
    try std.testing.expect(v.record.get("t").?.bool);
    try std.testing.expectError(error.Float, decode(a, "1.5"));
    try std.testing.expectError(error.Float, decode(a, "[1e3]"));
    try std.testing.expectError(error.BadJson, decode(a, "{\"a\":1,}"));
    try std.testing.expectError(error.BadJson, decode(a, "[1] x"));
    try std.testing.expectError(error.BadJson, decode(a, "\"\\ud83d\""));
    try std.testing.expectEqual(@as(usize, 0), (try decode(a, "[]")).list.len);
    try std.testing.expectEqual(@as(usize, 0), (try decode(a, "{}")).record.keys.len);
}

test "json: a round trip through both" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const text = "{\"k\":[1,\"two\",true,null,{\"x\":\"\\n\"}]}";
    var out: std.ArrayList(u8) = .empty;
    try encode(try decode(a, text), a, &out);
    try std.testing.expectEqualStrings(text, out.items);
}
