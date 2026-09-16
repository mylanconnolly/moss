//! Text as the toolkit sees it: a `Typeface` measures and paints strings
//! in a role, and that is all a painter may ask of it. The frame
//! implements one over the font service's glyph runs and its shared
//! atlas; a test implements one over fixed cells (`Fixed`), so a painter
//! runs on the host and its pixels can be asserted.
const std = @import("std");
const Canvas = @import("canvas.zig").Canvas;

/// A text role: the system font's sizes. Values match the wire's
/// FontRole, which the frame maps at its boundary.
pub const Role = enum(u8) { ui = 0, title = 1, mono = 2 };

pub const Metrics = struct {
    /// Row-to-row advance.
    line: usize,
    /// Baseline below the row's top.
    ascent: usize,
};

pub const Typeface = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        measure: *const fn (ctx: *anyopaque, role: Role, s: []const u8) usize,
        metrics: *const fn (ctx: *anyopaque, role: Role) Metrics,
        /// Paint `s` with its row's top-left at (x, y_top), blending `fg`
        /// by glyph coverage over what is already on the canvas. `bg` is
        /// for a bitmap fallback that paints whole cells; a coverage
        /// renderer ignores it.
        draw: *const fn (ctx: *anyopaque, canvas: *const Canvas, x: usize, y_top: usize, role: Role, s: []const u8, fg: u32, bg: u32) void,
    };

    pub fn measure(self: Typeface, role: Role, s: []const u8) usize {
        return self.vtable.measure(self.ctx, role, s);
    }
    pub fn line(self: Typeface, role: Role) usize {
        return self.vtable.metrics(self.ctx, role).line;
    }
    pub fn ascent(self: Typeface, role: Role) usize {
        return self.vtable.metrics(self.ctx, role).ascent;
    }
    pub fn draw(self: Typeface, canvas: *const Canvas, x: usize, y_top: usize, role: Role, s: []const u8, fg: u32, bg: u32) void {
        self.vtable.draw(self.ctx, canvas, x, y_top, role, s, fg, bg);
    }

    /// Draw `s`, truncated with an ellipsis to fit `maxw` pixels, never
    /// splitting a UTF-8 character — a list cell in a fixed column.
    pub fn drawTrunc(self: Typeface, canvas: *const Canvas, x: usize, y_top: usize, role: Role, s: []const u8, maxw: usize, fg: u32, bg: u32) void {
        if (self.measure(role, s) <= maxw) return self.draw(canvas, x, y_top, role, s, fg, bg);
        const ell = "…";
        const ellw = self.measure(role, ell);
        var buf: [192]u8 = undefined;
        var i: usize = 0;
        while (i < s.len and i + 8 < buf.len) {
            const cl = utf8Len(s[i]);
            if (i + cl > s.len) break;
            if (self.measure(role, s[0 .. i + cl]) + ellw > maxw) break;
            i += cl;
        }
        @memcpy(buf[0..i], s[0..i]);
        @memcpy(buf[i .. i + ell.len], ell);
        self.draw(canvas, x, y_top, role, buf[0 .. i + ell.len], fg, bg);
    }
};

pub fn utf8Len(b: u8) usize {
    return if (b < 0x80) 1 else if (b >> 5 == 0b110) 2 else if (b >> 4 == 0b1110) 3 else if (b >> 3 == 0b11110) 4 else 1;
}

/// The test typeface: every code point is a `cell_w`×`cell_h` cell whose
/// glyph is a solid block inset by one pixel, so a test can find ink
/// where a label was painted and nothing where it was not. Roles differ
/// only in cell height, so a title measures taller than body text.
pub const Fixed = struct {
    cell_w: usize = 8,
    cell_h: usize = 16,

    pub fn face(self: *Fixed) Typeface {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
    const vtable: Typeface.VTable = .{ .measure = measure, .metrics = metrics, .draw = draw };

    fn count(s: []const u8) usize {
        var n: usize = 0;
        var i: usize = 0;
        while (i < s.len) : (i += utf8Len(s[i])) n += 1;
        return n;
    }
    fn cellH(self: *const Fixed, role: Role) usize {
        return if (role == .title) self.cell_h + self.cell_h / 2 else self.cell_h;
    }
    fn measure(ctx: *anyopaque, role: Role, s: []const u8) usize {
        const self: *Fixed = @ptrCast(@alignCast(ctx));
        _ = role;
        return count(s) * self.cell_w;
    }
    fn metrics(ctx: *anyopaque, role: Role) Metrics {
        const self: *Fixed = @ptrCast(@alignCast(ctx));
        const h = self.cellH(role);
        return .{ .line = h, .ascent = h * 3 / 4 };
    }
    fn draw(ctx: *anyopaque, canvas: *const Canvas, x: usize, y_top: usize, role: Role, s: []const u8, fg: u32, bg: u32) void {
        _ = bg;
        const self: *Fixed = @ptrCast(@alignCast(ctx));
        const h = self.cellH(role);
        var cx = x;
        var i: usize = 0;
        while (i < s.len) : (i += utf8Len(s[i])) {
            if (s[i] != ' ') canvas.fillRect(cx + 1, y_top + 1, self.cell_w -| 2, h -| 2, fg);
            cx += self.cell_w;
        }
    }
};

test "the fixed face measures code points, not bytes, and paints ink per glyph" {
    var fixed: Fixed = .{};
    const face = fixed.face();
    try std.testing.expectEqual(@as(usize, 24), face.measure(.ui, "héy"));
    try std.testing.expectEqual(@as(usize, 16), face.line(.ui));
    try std.testing.expect(face.line(.title) > face.line(.ui));
    var buf: [40 * 20]u32 = @splat(0);
    const c = Canvas.init(&buf, 40, 20);
    face.draw(&c, 0, 0, .ui, "a b", 0xff, 0);
    try std.testing.expectEqual(@as(u32, 0xff), c.at(3, 5)); // 'a'
    try std.testing.expectEqual(@as(u32, 0), c.at(11, 5)); // the space
    try std.testing.expectEqual(@as(u32, 0xff), c.at(19, 5)); // 'b'
    try std.testing.expectEqual(@as(u32, 0), c.at(0, 5)); // the inset edge
}

test "truncation keeps whole characters and always fits" {
    var fixed: Fixed = .{};
    const face = fixed.face();
    var buf: [64 * 16]u32 = @splat(0);
    const c = Canvas.init(&buf, 64, 16);
    // 6 cells fit in 48px; "abcdé" + "…" is 6 cells, so "abcdéfg" becomes "abcd…" or "abcdé…" but never a split é.
    face.drawTrunc(&c, 0, 0, .ui, "abcdéfg", 48, 0xff, 0);
    try std.testing.expectEqual(@as(u32, 0xff), c.at(3, 5)); // first glyph painted
    try std.testing.expectEqual(@as(u32, 0), c.at(51, 5)); // nothing past the limit
    face.drawTrunc(&c, 0, 0, .ui, "ab", 48, 0xff, 0); // fits: painted whole
    try std.testing.expectEqual(@as(u32, 0xff), c.at(11, 5));
}
