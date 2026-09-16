//! A canvas: XRGB pixels with a clip rectangle and a vertical scroll
//! translation, and the primitives every widget is painted with. It owns
//! no memory — a program points it at its mapped surface, a test at an
//! array — and it is the one thing painters write to, so a painter is a
//! host-testable function.
//!
//! Coordinates given to the primitives are *logical*: nonnegative layout
//! positions. `offset_y` translates them to screen rows at the raster
//! boundary (a scrolled viewport paints rows at their logical y and lets
//! the canvas shift and clip them), so a partially visible glyph or row
//! is cut, never spilled. Colours are 0x00RRGGBB, read straight by a
//! screendump; the top byte is preserved by blends and ignored otherwise.
const std = @import("std");

pub const Canvas = struct {
    px: [*]u32 = undefined,
    w: usize = 0,
    h: usize = 0,
    /// Added to every logical y before clipping (a scrolled viewport).
    offset_y: isize = 0,
    // The clip rectangle, in screen coordinates, half-open.
    clip_x0: usize = 0,
    clip_y0: usize = 0,
    clip_x1: usize = 0,
    clip_y1: usize = 0,

    /// Paints nothing: the measuring pass, or a window with no surface.
    pub const empty: Canvas = .{};

    pub fn init(px: [*]u32, w: usize, h: usize) Canvas {
        var c: Canvas = .{ .px = px, .w = w, .h = h };
        c.clipReset();
        return c;
    }

    pub fn screenY(self: *const Canvas, y: usize) isize {
        return @as(isize, @intCast(y)) + self.offset_y;
    }
    pub fn clipY(self: *const Canvas, y: usize) usize {
        return @intCast(@max(0, self.screenY(y)));
    }
    /// Whole canvas, no translation.
    pub fn clipReset(self: *Canvas) void {
        self.offset_y = 0;
        self.clip_x0 = 0;
        self.clip_y0 = 0;
        self.clip_x1 = self.w;
        self.clip_y1 = self.h;
    }
    fn inClip(self: *const Canvas, x: usize, y: usize) bool {
        return x >= self.clip_x0 and x < self.clip_x1 and y >= self.clip_y0 and y < self.clip_y1;
    }

    pub fn fillAll(self: *const Canvas, word: u32) void {
        for (0..self.w * self.h) |i| self.px[i] = word;
    }

    pub fn put(self: *const Canvas, x: usize, logical_y: usize, word: u32) void {
        const sy = self.screenY(logical_y);
        if (sy < 0) return;
        const y: usize = @intCast(sy);
        if (x < self.w and y < self.h and self.inClip(x, y)) self.px[y * self.w + x] = word;
    }

    pub fn fillRect(self: *const Canvas, x: usize, y: usize, w: usize, h: usize, word: u32) void {
        const top = @max(@as(isize, @intCast(self.clip_y0)), self.screenY(y));
        const bottom = @min(@as(isize, @intCast(@min(self.h, self.clip_y1))), self.screenY(y + h));
        if (top >= bottom) return;
        const left = @max(x, self.clip_x0);
        const right = @min(x + w, @min(self.w, self.clip_x1));
        if (left >= right) return;
        for (@as(usize, @intCast(top))..@as(usize, @intCast(bottom))) |yy| {
            @memset(self.px[yy * self.w + left .. yy * self.w + right], word);
        }
    }

    /// A `thick`-pixel outline around the rect (x, y, w, h).
    pub fn strokeRect(self: *const Canvas, x: usize, y: usize, w: usize, h: usize, word: u32, thick: usize) void {
        self.fillRect(x, y, w, thick, word); // top
        if (h > thick) self.fillRect(x, y + h - thick, w, thick, word); // bottom
        self.fillRect(x, y, thick, h, word); // left
        if (w > thick) self.fillRect(x + w - thick, y, thick, h, word); // right
    }

    /// One rounded corner: the quarter-disc of radius `r` centred at
    /// (cx, cy), filling the r×r box that extends in the (qx, qy)
    /// direction. Each pixel is coverage-blended (a ~1px feather at the
    /// arc), so the curve reads smooth against whatever is already there.
    fn roundCorner(self: *const Canvas, cx: usize, cy: usize, r: usize, word: u32, qx: i2, qy: i2) void {
        const cxf: f32 = @floatFromInt(cx);
        const cyf: f32 = @floatFromInt(cy);
        const rf: f32 = @floatFromInt(r);
        var iy: usize = 0;
        while (iy < r) : (iy += 1) {
            var ix: usize = 0;
            while (ix < r) : (ix += 1) {
                const pxu = if (qx < 0) cx - r + ix else cx + ix;
                const pyu = if (qy < 0) cy - r + iy else cy + iy;
                const dx = (@as(f32, @floatFromInt(pxu)) + 0.5) - cxf;
                const dy = (@as(f32, @floatFromInt(pyu)) + 0.5) - cyf;
                const cov = rf + 0.5 - @sqrt(dx * dx + dy * dy); // 1px feather
                if (cov <= 0) continue;
                self.blend(pxu, pyu, word, if (cov >= 1) 255 else @intFromFloat(cov * 255));
            }
        }
    }

    /// A filled rectangle with rounded, anti-aliased corners. `r` is
    /// clamped to half the shorter side (r == 0 is a plain fill).
    pub fn fillRoundRect(self: *const Canvas, x: usize, y: usize, w: usize, h: usize, r_in: usize, word: u32) void {
        if (w == 0 or h == 0) return;
        var r = r_in;
        if (r > w / 2) r = w / 2;
        if (r > h / 2) r = h / 2;
        if (r == 0) return self.fillRect(x, y, w, h, word);
        self.fillRect(x, y + r, w, h - 2 * r, word); // the full-width middle band
        self.fillRect(x + r, y, w - 2 * r, r, word); // top edge between corners
        self.fillRect(x + r, y + h - r, w - 2 * r, r, word); // bottom edge
        self.roundCorner(x + r, y + r, r, word, -1, -1); // TL
        self.roundCorner(x + w - r, y + r, r, word, 1, -1); // TR
        self.roundCorner(x + r, y + h - r, r, word, -1, 1); // BL
        self.roundCorner(x + w - r, y + h - r, r, word, 1, 1); // BR
    }

    /// A filled, anti-aliased disc.
    pub fn fillDot(self: *const Canvas, cx: usize, cy: usize, r: usize, word: u32) void {
        const cxf: f32 = @floatFromInt(cx);
        const cyf: f32 = @floatFromInt(cy);
        const rf: f32 = @floatFromInt(r);
        var y = if (cy > r) cy - r else 0;
        while (y <= cy + r) : (y += 1) {
            var x = if (cx > r) cx - r else 0;
            while (x <= cx + r and x < self.w) : (x += 1) {
                const dx = (@as(f32, @floatFromInt(x)) + 0.5) - cxf;
                const dy = (@as(f32, @floatFromInt(y)) + 0.5) - cyf;
                const cov = rf + 0.5 - @sqrt(dx * dx + dy * dy);
                if (cov <= 0) continue;
                self.blend(x, y, word, if (cov >= 1) 255 else @intFromFloat(cov * 255));
            }
        }
    }

    /// A rounded panel with a rounded border of thickness `bw`: the border
    /// colour as the outer shape, the fill inset by `bw`.
    pub fn panel(self: *const Canvas, x: usize, y: usize, w: usize, h: usize, r: usize, fill: u32, border: u32, bw: usize) void {
        self.fillRoundRect(x, y, w, h, r, border);
        if (w > 2 * bw and h > 2 * bw) {
            const ir = if (r > bw) r - bw else 0;
            self.fillRoundRect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, ir, fill);
        }
    }

    /// Blend `fg` over the pixel at (x, y) by coverage `cov` (0..255).
    pub fn blend(self: *const Canvas, x: usize, logical_y: usize, fg: u32, cov: u32) void {
        const sy = self.screenY(logical_y);
        if (sy < 0) return;
        const y: usize = @intCast(sy);
        if (x >= self.w or y >= self.h or cov == 0) return;
        if (!self.inClip(x, y)) return;
        const i = y * self.w + x;
        if (cov >= 255) {
            self.px[i] = fg;
            return;
        }
        const dst = self.px[i];
        var out: u32 = 0;
        inline for (.{ 0, 8, 16 }) |shf| {
            const f = (fg >> shf) & 0xff;
            const d = (dst >> shf) & 0xff;
            out |= (((f * cov + d * (255 - cov)) / 255) & 0xff) << shf;
        }
        self.px[i] = out;
    }

    /// Test helper: the pixel at screen (x, y).
    pub fn at(self: *const Canvas, x: usize, y: usize) u32 {
        return self.px[y * self.w + x];
    }
};

test "fills honour the clip rectangle and the scroll offset" {
    var buf: [20 * 10]u32 = @splat(0);
    var c = Canvas.init(&buf, 20, 10);
    c.fillRect(2, 2, 5, 3, 0xff);
    try std.testing.expectEqual(@as(u32, 0xff), c.at(2, 2));
    try std.testing.expectEqual(@as(u32, 0xff), c.at(6, 4));
    try std.testing.expectEqual(@as(u32, 0), c.at(7, 4));
    try std.testing.expectEqual(@as(u32, 0), c.at(6, 5));
    // A clip cuts, never spills.
    c.clip_x0 = 4;
    c.clip_y1 = 3;
    c.fillRect(0, 0, 20, 10, 0xaa);
    try std.testing.expectEqual(@as(u32, 0xff), c.at(3, 2)); // left of the clip: untouched
    try std.testing.expectEqual(@as(u32, 0xaa), c.at(4, 2));
    try std.testing.expectEqual(@as(u32, 0xff), c.at(4, 3)); // below the clip: untouched
    // A scrolled viewport: logical row 5 lands on screen row 1.
    c.clipReset();
    c.offset_y = -4;
    c.fillRect(0, 5, 20, 1, 0x11);
    try std.testing.expectEqual(@as(u32, 0x11), c.at(0, 1));
    try std.testing.expectEqual(@as(u32, 0xaa), c.at(5, 2)); // the earlier clipped fill, untouched
    c.put(6, 2, 0x22); // logical 2 -> screen -2: gone, nothing in that column changes
    for (0..10) |y| try std.testing.expect(c.at(6, y) != 0x22);
    // Out of bounds is a no-op, including on the empty canvas.
    c.fillRect(100, 100, 5, 5, 0x33);
    Canvas.empty.fillRect(0, 0, 5, 5, 0x33);
    Canvas.empty.blend(0, 0, 0x33, 255);
}

test "rounded rectangles leave their corners and blend their arcs" {
    var buf: [40 * 30]u32 = @splat(0);
    const c = Canvas.init(&buf, 40, 30);
    c.fillRoundRect(0, 0, 40, 30, 8, 0xffffff);
    try std.testing.expectEqual(@as(u32, 0), c.at(0, 0)); // the corner pixel is outside the arc
    try std.testing.expectEqual(@as(u32, 0xffffff), c.at(20, 15));
    try std.testing.expectEqual(@as(u32, 0xffffff), c.at(0, 15)); // the middle band reaches the edge
    var partial = false;
    for (0..8) |y| for (0..8) |x| {
        const v = c.at(x, y);
        if (v != 0 and v != 0xffffff) partial = true;
    };
    try std.testing.expect(partial); // an antialiased arc, not a staircase
    try std.testing.expectEqual(c.at(0, 0), c.at(39, 29)); // symmetric corners
}

test "blend is exact at the ends and preserves the reserved byte" {
    var buf: [1]u32 = .{0xaa123456};
    const c = Canvas.init(&buf, 1, 1);
    c.blend(0, 0, 0xffffff, 0);
    try std.testing.expectEqual(@as(u32, 0xaa123456), c.at(0, 0));
    c.blend(0, 0, 0x00ffffff, 128);
    try std.testing.expect((c.at(0, 0) & 0xff) > 0x56 and (c.at(0, 0) & 0xff) < 0xff);
    c.blend(0, 0, 0x00ffffff, 255);
    try std.testing.expectEqual(@as(u32, 0x00ffffff), c.at(0, 0));
}

test "panel insets its fill by the border width" {
    var buf: [30 * 20]u32 = @splat(0);
    const c = Canvas.init(&buf, 30, 20);
    c.panel(0, 0, 30, 20, 0, 0x00ff00, 0xff0000, 2);
    try std.testing.expectEqual(@as(u32, 0xff0000), c.at(0, 10));
    try std.testing.expectEqual(@as(u32, 0xff0000), c.at(1, 10));
    try std.testing.expectEqual(@as(u32, 0x00ff00), c.at(2, 10));
    try std.testing.expectEqual(@as(u32, 0xff0000), c.at(29, 10));
}
