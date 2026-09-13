//! Compile-time decoder for our pinned, round-stroked Phosphor SVG subset.
//! Unsupported geometry fails the build rather than silently losing artwork.
const std = @import("std");
pub const Segment = [4]f32;
const Point = struct { x: f32, y: f32 };
const tolerance = 0.125; // source units (256-unit viewBox), <0.1px at 192px
const Builder = struct {
    items: [512]Segment = undefined,
    len: usize = 0,
    current: Point = .{ .x = 0, .y = 0 },
    start: Point = .{ .x = 0, .y = 0 },
    fn move(b: *Builder, p: Point) void {
        b.current = p;
        b.start = p;
    }
    fn line(b: *Builder, p: Point) void {
        if (p.x != b.current.x or p.y != b.current.y) {
            std.debug.assert(b.len < b.items.len);
            b.items[b.len] = .{ b.current.x, b.current.y, p.x, p.y };
            b.len += 1;
        }
        b.current = p;
    }
    fn circular(b: *Builder, center: Point, r: f32, start: f32, angle: f32, end: Point) void {
        const steps: usize = @intFromFloat(@max(1, @ceil(@abs(angle) * @sqrt(r / (8 * tolerance)))));
        for (1..steps) |i| {
            const a = start + angle * @as(f32, @floatFromInt(i)) / @as(f32, @floatFromInt(steps));
            b.line(.{ .x = center.x + r * @cos(a), .y = center.y + r * @sin(a) });
        }
        b.line(end);
    }
    fn arc(b: *Builder, radius: f32, large: bool, sweep: bool, end: Point) void {
        const dx = end.x - b.current.x;
        const dy = end.y - b.current.y;
        const d = @sqrt(dx * dx + dy * dy);
        if (d == 0) return;
        const r = @max(@abs(radius), d / 2);
        const h = @sqrt(@max(0, r * r - d * d / 4)) * @as(f32, if (large == sweep) -1 else 1);
        const c = Point{ .x = (b.current.x + end.x) / 2 - dy * h / d, .y = (b.current.y + end.y) / 2 + dx * h / d };
        const a = std.math.atan2(b.current.y - c.y, b.current.x - c.x);
        var delta = std.math.atan2(end.y - c.y, end.x - c.x) - a;
        if (sweep and delta < 0) delta += 2 * std.math.pi;
        if (!sweep and delta > 0) delta -= 2 * std.math.pi;
        b.circular(c, r, a, delta, end);
    }
    fn cubic(b: *Builder, p0: Point, p1: Point, p2: Point, p3: Point, depth: usize) void {
        const dx = p3.x - p0.x;
        const dy = p3.y - p0.y;
        const length = @sqrt(dx * dx + dy * dy);
        const flat = @max(@abs(dy * (p1.x - p0.x) - dx * (p1.y - p0.y)), @abs(dy * (p2.x - p0.x) - dx * (p2.y - p0.y)));
        if (depth == 12 or (length > 0 and flat <= tolerance * length)) {
            b.line(p3);
            return;
        }
        const a = mid(p0, p1);
        const c = mid(p1, p2);
        const d = mid(p2, p3);
        const e = mid(a, c);
        const f = mid(c, d);
        const g = mid(e, f);
        b.cubic(p0, a, e, g, depth + 1);
        b.cubic(g, f, d, p3, depth + 1);
    }
};
fn mid(a: Point, b: Point) Point {
    return .{ .x = (a.x + b.x) / 2, .y = (a.y + b.y) / 2 };
}
const Numbers = struct {
    text: []const u8,
    pos: usize = 0,
    fn skip(n: *Numbers) void {
        while (n.pos < n.text.len and (std.ascii.isWhitespace(n.text[n.pos]) or n.text[n.pos] == ',')) n.pos += 1;
    }
    fn number(n: *Numbers) f32 {
        n.skip();
        const start = n.pos;
        if (n.pos < n.text.len and (n.text[n.pos] == '-' or n.text[n.pos] == '+')) n.pos += 1;
        while (n.pos < n.text.len and (std.ascii.isDigit(n.text[n.pos]) or n.text[n.pos] == '.')) n.pos += 1;
        return std.fmt.parseFloat(f32, n.text[start..n.pos]) catch @panic("unsupported SVG number");
    }
    fn point(n: *Numbers, origin: Point) Point {
        const x = n.number();
        const y = n.number();
        return .{ .x = x + origin.x, .y = y + origin.y };
    }
};
fn attr(tag: []const u8, name: []const u8) ?[]const u8 {
    var i: usize = 0;
    while (i + name.len + 2 < tag.len) : (i += 1) {
        if (i > 0 and !std.ascii.isWhitespace(tag[i - 1])) continue;
        if (!std.mem.startsWith(u8, tag[i..], name)) continue;
        const end = i + name.len;
        if (!std.mem.startsWith(u8, tag[end..], "=\"")) continue;
        const from = end + 2;
        const to = std.mem.indexOfScalarPos(u8, tag, from, '"') orelse @panic("unclosed SVG attribute");
        return tag[from..to];
    }
    return null;
}
fn value(tag: []const u8, name: []const u8, default: f32) f32 {
    return if (attr(tag, name)) |v| std.fmt.parseFloat(f32, v) catch @panic("invalid SVG attribute") else default;
}
fn path(b: *Builder, text: []const u8) void {
    var n = Numbers{ .text = text };
    var cmd: u8 = 0;
    while (true) {
        n.skip();
        if (n.pos == text.len) break;
        if (std.ascii.isAlphabetic(text[n.pos])) {
            cmd = text[n.pos];
            n.pos += 1;
        }
        const origin = if (std.ascii.isLower(cmd)) b.current else Point{ .x = 0, .y = 0 };
        switch (std.ascii.toUpper(cmd)) {
            'M' => {
                b.move(n.point(origin));
                cmd = if (cmd == 'm') 'l' else 'L';
            },
            'L' => b.line(n.point(origin)),
            'H' => b.line(.{ .x = origin.x + n.number(), .y = b.current.y }),
            'V' => b.line(.{ .x = b.current.x, .y = origin.y + n.number() }),
            'C' => {
                const p1 = n.point(origin);
                const p2 = n.point(origin);
                const end = n.point(origin);
                b.cubic(b.current, p1, p2, end, 0);
            },
            'A' => {
                const rx = n.number();
                const ry = n.number();
                const rotation = n.number();
                std.debug.assert(rx == ry and rotation == 0 and rx > 0);
                const large = n.number();
                const sweep = n.number();
                std.debug.assert((large == 0 or large == 1) and (sweep == 0 or sweep == 1));
                const end = n.point(origin);
                b.arc(rx, large == 1, sweep == 1, end);
            },
            'Z' => {
                b.line(b.start);
                cmd = 0;
            },
            else => @panic("unsupported SVG path command"),
        }
    }
}
fn decode(svg: []const u8) Builder {
    var b: Builder = .{};
    var pos: usize = 0;
    while (std.mem.indexOfScalarPos(u8, svg, pos, '<')) |start| {
        const end = std.mem.indexOfScalarPos(u8, svg, start, '>') orelse @panic("invalid SVG tag");
        const tag = svg[start + 1 .. end];
        pos = end + 1;
        if (std.mem.startsWith(u8, tag, "svg ")) {
            std.debug.assert(std.mem.eql(u8, attr(tag, "viewBox").?, "0 0 256 256"));
            continue;
        }
        if (std.mem.eql(u8, tag, "/svg")) continue;
        if (attr(tag, "stroke") == null) {
            std.debug.assert(std.mem.startsWith(u8, tag, "rect ") and value(tag, "width", 0) == 256 and value(tag, "height", 0) == 256 and std.mem.eql(u8, attr(tag, "fill").?, "none"));
            continue; // non-painting viewBox rectangle
        }
        std.debug.assert(value(tag, "stroke-width", 0) == 16 and attr(tag, "transform") == null);
        std.debug.assert(std.mem.eql(u8, attr(tag, "stroke-linecap").?, "round") and std.mem.eql(u8, attr(tag, "stroke-linejoin").?, "round"));
        if (std.mem.startsWith(u8, tag, "path ")) {
            path(&b, attr(tag, "d").?);
        } else if (std.mem.startsWith(u8, tag, "line ")) {
            b.move(.{ .x = value(tag, "x1", 0), .y = value(tag, "y1", 0) });
            b.line(.{ .x = value(tag, "x2", 0), .y = value(tag, "y2", 0) });
        } else if (std.mem.startsWith(u8, tag, "polyline ")) {
            var n = Numbers{ .text = attr(tag, "points").? };
            const zero = Point{ .x = 0, .y = 0 };
            b.move(n.point(zero));
            n.skip();
            while (n.pos < n.text.len) {
                b.line(n.point(zero));
                n.skip();
            }
        } else if (std.mem.startsWith(u8, tag, "circle ")) {
            const c = Point{ .x = value(tag, "cx", 0), .y = value(tag, "cy", 0) };
            const r = value(tag, "r", 0);
            b.move(.{ .x = c.x + r, .y = c.y });
            b.circular(c, r, 0, 2 * std.math.pi, b.current);
        } else if (std.mem.startsWith(u8, tag, "rect ")) {
            const x = value(tag, "x", 0);
            const y = value(tag, "y", 0);
            const w = value(tag, "width", 0);
            const h = value(tag, "height", 0);
            const r = value(tag, "rx", 0);
            std.debug.assert(r > 0 and r * 2 <= @min(w, h) and value(tag, "ry", r) == r);
            b.move(.{ .x = x + r, .y = y });
            b.line(.{ .x = x + w - r, .y = y });
            b.arc(r, false, true, .{ .x = x + w, .y = y + r });
            b.line(.{ .x = x + w, .y = y + h - r });
            b.arc(r, false, true, .{ .x = x + w - r, .y = y + h });
            b.line(.{ .x = x + r, .y = y + h });
            b.arc(r, false, true, .{ .x = x, .y = y + h - r });
            b.line(.{ .x = x, .y = y + r });
            b.arc(r, false, true, b.start);
        } else @panic("unsupported SVG element");
    }
    return b;
}
pub fn fromSvg(comptime svg: []const u8) []const Segment {
    return comptime blk: {
        @setEvalBranchQuota(2_000_000);
        const b = decode(svg);
        const result = b.items[0..b.len].*;
        break :blk &result;
    };
}
