//! Small symbolic icons on a 24-unit grid. No font or image-service dependency.
const std = @import("std");
const Segment = [4]f32;
pub const Icon = enum { folder, file, home, settings, terminal, grid, up, refresh, lock, back, network, close };
pub fn parse(name: []const u8) ?Icon {
    return std.meta.stringToEnum(Icon, name);
}
fn segments(icon: Icon) []const Segment {
    return switch (icon) {
        .folder => &.{ .{ 3, 7, 3, 20 }, .{ 3, 20, 21, 20 }, .{ 21, 20, 21, 7 }, .{ 21, 7, 11, 7 }, .{ 11, 7, 9, 4 }, .{ 9, 4, 3, 4 }, .{ 3, 4, 3, 7 }, .{ 3, 10, 21, 10 } },
        .file => &.{ .{ 5, 3, 5, 21 }, .{ 5, 21, 19, 21 }, .{ 19, 21, 19, 8 }, .{ 19, 8, 14, 3 }, .{ 14, 3, 5, 3 }, .{ 14, 3, 14, 8 }, .{ 14, 8, 19, 8 }, .{ 8, 13, 16, 13 }, .{ 8, 17, 14, 17 } },
        .home => &.{ .{ 2, 11, 12, 3 }, .{ 12, 3, 22, 11 }, .{ 5, 9, 5, 21 }, .{ 5, 21, 19, 21 }, .{ 19, 21, 19, 9 }, .{ 10, 21, 10, 14 }, .{ 10, 14, 14, 14 }, .{ 14, 14, 14, 21 } },
        .settings => &.{ .{ 4, 3, 4, 7 }, .{ 4, 11, 4, 21 }, .{ 2, 7, 6, 7 }, .{ 6, 7, 6, 11 }, .{ 6, 11, 2, 11 }, .{ 2, 11, 2, 7 }, .{ 12, 3, 12, 14 }, .{ 12, 18, 12, 21 }, .{ 10, 14, 14, 14 }, .{ 14, 14, 14, 18 }, .{ 14, 18, 10, 18 }, .{ 10, 18, 10, 14 }, .{ 20, 3, 20, 7 }, .{ 20, 11, 20, 21 }, .{ 18, 7, 22, 7 }, .{ 22, 7, 22, 11 }, .{ 22, 11, 18, 11 }, .{ 18, 11, 18, 7 } },
        .terminal => &.{ .{ 3, 4, 21, 4 }, .{ 21, 4, 21, 20 }, .{ 21, 20, 3, 20 }, .{ 3, 20, 3, 4 }, .{ 7, 9, 10, 12 }, .{ 10, 12, 7, 15 }, .{ 13, 15, 17, 15 } },
        .grid => &.{ .{ 3, 3, 9, 3 }, .{ 9, 3, 9, 9 }, .{ 9, 9, 3, 9 }, .{ 3, 9, 3, 3 }, .{ 15, 3, 21, 3 }, .{ 21, 3, 21, 9 }, .{ 21, 9, 15, 9 }, .{ 15, 9, 15, 3 }, .{ 3, 15, 9, 15 }, .{ 9, 15, 9, 21 }, .{ 9, 21, 3, 21 }, .{ 3, 21, 3, 15 }, .{ 15, 15, 21, 15 }, .{ 21, 15, 21, 21 }, .{ 21, 21, 15, 21 }, .{ 15, 21, 15, 15 } },
        .up => &.{ .{ 5, 11, 12, 4 }, .{ 12, 4, 19, 11 }, .{ 12, 4, 12, 21 } },
        .back => &.{ .{ 11, 5, 4, 12 }, .{ 4, 12, 11, 19 }, .{ 4, 12, 21, 12 } },
        .refresh => &.{ .{ 20, 8, 17.5, 5 }, .{ 17.5, 5, 14, 3.5 }, .{ 14, 3.5, 10, 3.5 }, .{ 10, 3.5, 6.5, 5 }, .{ 6.5, 5, 4, 8 }, .{ 4, 8, 3, 12 }, .{ 3, 12, 4, 16 }, .{ 4, 16, 6.5, 19 }, .{ 6.5, 19, 10, 20.5 }, .{ 10, 20.5, 14, 20.5 }, .{ 14, 20.5, 17.5, 19 }, .{ 17.5, 19, 20, 16 }, .{ 20, 3, 20, 8 }, .{ 20, 8, 15, 8 } },
        .lock => &.{ .{ 5, 10, 19, 10 }, .{ 19, 10, 19, 21 }, .{ 19, 21, 5, 21 }, .{ 5, 21, 5, 10 }, .{ 8, 10, 8, 5 }, .{ 8, 5, 10, 3 }, .{ 10, 3, 14, 3 }, .{ 14, 3, 16, 5 }, .{ 16, 5, 16, 10 }, .{ 12, 14, 12, 17 } },
        .network => &.{ .{ 8, 3, 16, 3 }, .{ 16, 3, 16, 9 }, .{ 16, 9, 8, 9 }, .{ 8, 9, 8, 3 }, .{ 12, 9, 12, 13 }, .{ 4, 13, 20, 13 }, .{ 4, 13, 4, 17 }, .{ 20, 13, 20, 17 }, .{ 1, 17, 7, 17 }, .{ 7, 17, 7, 21 }, .{ 7, 21, 1, 21 }, .{ 1, 21, 1, 17 }, .{ 17, 17, 23, 17 }, .{ 23, 17, 23, 21 }, .{ 23, 21, 17, 21 }, .{ 17, 21, 17, 17 } },
        .close => &.{ .{ 5, 5, 19, 19 }, .{ 19, 5, 5, 19 } },
    };
}
/// Pixel coverage for rounded 1.8-unit strokes at an arbitrary output size.
pub fn coverage(icon: Icon, size: usize, x: usize, y: usize) u32 {
    if (size == 0) return 0;
    const scale = @as(f32, @floatFromInt(size)) / 24;
    const px = (@as(f32, @floatFromInt(x)) + 0.5) / scale;
    const py = (@as(f32, @floatFromInt(y)) + 0.5) / scale;
    var distance: f32 = 1000;
    for (segments(icon)) |s| {
        const dx = s[2] - s[0];
        const dy = s[3] - s[1];
        const t = std.math.clamp(((px - s[0]) * dx + (py - s[1]) * dy) / (dx * dx + dy * dy), 0, 1);
        const ex = px - s[0] - t * dx;
        const ey = py - s[1] - t * dy;
        distance = @min(distance, @sqrt(ex * ex + ey * ey));
    }
    return @intFromFloat(std.math.clamp((0.9 - distance) * scale + 0.5, 0, 1) * 255);
}
test "every named icon renders bounded nonempty coverage at both UI scales" {
    inline for (std.meta.fields(Icon)) |field| {
        const icon = parse(field.name).?;
        for ([_]usize{ 20, 28 }) |size| {
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
