//! Symbolic icons compiled from SVGs: Phosphor Regular plus the original Moss mark.
//! See lib/ui/phosphor/README.md and lib/ui/branding/README.md for provenance.
//! `coverage` is the rasterizer: distance to the nearest stroke segment,
//! antialiased; the frame caches its masks per size.
const std = @import("std");
const path = @import("iconpath.zig");
const Segment = path.Segment;
pub const Icon = enum { folder, file, home, settings, terminal, grid, up, refresh, lock, back, network, close, activity, moss };
pub fn parse(name: []const u8) ?Icon {
    if (std.mem.eql(u8, name, "file-text")) return .file;
    if (std.mem.eql(u8, name, "house")) return .home;
    if (std.mem.eql(u8, name, "gear-six")) return .settings;
    if (std.mem.eql(u8, name, "terminal-window")) return .terminal;
    if (std.mem.eql(u8, name, "squares-four")) return .grid;
    if (std.mem.eql(u8, name, "arrow-up")) return .up;
    if (std.mem.eql(u8, name, "arrow-clockwise")) return .refresh;
    if (std.mem.eql(u8, name, "lock-simple")) return .lock;
    if (std.mem.eql(u8, name, "arrow-left")) return .back;
    if (std.mem.eql(u8, name, "tree-structure")) return .network;
    if (std.mem.eql(u8, name, "x")) return .close;
    if (std.mem.eql(u8, name, "pulse")) return .activity;
    return std.meta.stringToEnum(Icon, name);
}
fn segments(icon: Icon) []const Segment {
    return switch (icon) {
        .folder => path.fromSvg(@embedFile("phosphor/regular/folder.svg")),
        .file => path.fromSvg(@embedFile("phosphor/regular/file-text.svg")),
        .home => path.fromSvg(@embedFile("phosphor/regular/house.svg")),
        .settings => path.fromSvg(@embedFile("phosphor/regular/gear-six.svg")),
        .terminal => path.fromSvg(@embedFile("phosphor/regular/terminal-window.svg")),
        .grid => path.fromSvg(@embedFile("phosphor/regular/squares-four.svg")),
        .up => path.fromSvg(@embedFile("phosphor/regular/arrow-up.svg")),
        .refresh => path.fromSvg(@embedFile("phosphor/regular/arrow-clockwise.svg")),
        .lock => path.fromSvg(@embedFile("phosphor/regular/lock-simple.svg")),
        .back => path.fromSvg(@embedFile("phosphor/regular/arrow-left.svg")),
        .network => path.fromSvg(@embedFile("phosphor/regular/tree-structure.svg")),
        .close => path.fromSvg(@embedFile("phosphor/regular/x.svg")),
        .activity => path.fromSvg(@embedFile("phosphor/regular/pulse.svg")),
        .moss => path.fromSvg(@embedFile("branding/moss.svg")),
    };
}
/// Base sizes are logical pixels at the 16px UI font size. Icons follow the
/// same rounded font-size snapshot as labels, without the old 28px ceiling.
pub fn scaledSize(base: usize, ui_px: usize) usize {
    return @max(1, (base * ui_px + 8) / 16);
}
/// Pixel coverage for symbolic icons: rounded 16-unit strokes on a 256 grid.
pub fn coverage(icon: Icon, size: usize, x: usize, y: usize) u32 {
    if (size == 0 or x >= size or y >= size) return 0;
    const scale = @as(f32, @floatFromInt(size)) / 256;
    const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
    const py = (@as(f32, @floatFromInt(y)) + 0.5) / scale;
    var distance_squared: f32 = std.math.inf(f32);
    for (segments(icon)) |s| {
        const dx = s[2] - s[0];
        const dy = s[3] - s[1];
        const t = std.math.clamp(((px - s[0]) * dx + (py - s[1]) * dy) / (dx * dx + dy * dy), 0, 1);
        const ex = px - s[0] - t * dx;
        const ey = py - s[1] - t * dy;
        distance_squared = @min(distance_squared, ex * ex + ey * ey);
    }
    return @intFromFloat(std.math.clamp((8 - @sqrt(distance_squared)) * scale + 0.5, 0, 1) * 255);
}
/// Coverage is independent of theme and position, so a program caches
/// each icon's mask at its last size: focus, hover and ticking bars must
/// not re-rasterize. Sizes above `max_px` rasterize on the fly.
pub const Cache = struct {
    pub const max_px = 64;
    const Mask = struct { size: usize = 0, pixels: [max_px * max_px]u8 = undefined };
    masks: [@typeInfo(Icon).@"enum".fields.len]Mask = @splat(.{}),

    pub fn draw(self: *Cache, canvas: *const Canvas, icon: Icon, size: usize, x: usize, y: usize, ink: u32) void {
        if (size <= max_px) {
            const mask = &self.masks[@intFromEnum(icon)];
            if (mask.size != size) {
                for (0..size) |iy| for (0..size) |ix| {
                    mask.pixels[iy * size + ix] = @intCast(coverage(icon, size, ix, iy));
                };
                mask.size = size;
            }
            for (0..size) |iy| for (0..size) |ix| canvas.blend(x + ix, y + iy, ink, mask.pixels[iy * size + ix]);
        } else {
            for (0..size) |iy| for (0..size) |ix| canvas.blend(x + ix, y + iy, ink, coverage(icon, size, ix, iy));
        }
    }
};
const Canvas = @import("canvas.zig").Canvas;

test "the cache paints an icon once per size and leaves the ground outside it" {
    var cache: Cache = .{};
    var buf: [40 * 40]u32 = @splat(0);
    const c = Canvas.init(&buf, 40, 40);
    cache.draw(&c, .close, 20, 10, 10, 0xffffff);
    try std.testing.expectEqual(@as(usize, 20), cache.masks[@intFromEnum(Icon.close)].size);
    var ink: usize = 0;
    for (0..40) |y| for (0..40) |x| {
        if (c.at(x, y) != 0) {
            ink += 1;
            try std.testing.expect(x >= 10 and x < 30 and y >= 10 and y < 30);
        }
    };
    try std.testing.expect(ink > 0);
}

test "every named icon renders bounded nonempty coverage at supported UI scales" {
    inline for (std.meta.fields(Icon)) |field| {
        const icon = parse(field.name).?;
        for ([_]usize{ 20, 30, 40, 60, 96 }) |size| {
            var ink: usize = 0;
            for (0..size) |y| for (0..size) |x| {
                const cov = coverage(icon, size, x, y);
                try std.testing.expect(cov <= 255);
                ink += cov;
            };
            try std.testing.expect(ink > 0 and ink < size * size * 255);
        }
    }
    try std.testing.expect(parse("unknown") == null);
}

test "icons scale proportionally with text, including explicit base sizes" {
    try std.testing.expectEqual(@as(usize, 20), scaledSize(20, 16));
    try std.testing.expectEqual(@as(usize, 30), scaledSize(20, 24));
    try std.testing.expectEqual(@as(usize, 60), scaledSize(20, 48));
    try std.testing.expectEqual(@as(usize, 96), scaledSize(32, 48));
    try std.testing.expectEqual(@as(u32, 0), coverage(.settings, 0, 0, 0));
    try std.testing.expectEqual(@as(u32, 0), coverage(.settings, 60, 60, 0));
}
