//! Shared, allocation-free rounded window geometry. Coverage is independent
//! of client pixels: transparent corners reveal the next compositor layer.
const std = @import("std");
pub const default_radius: usize = 12;

pub fn radius(w: usize, h: usize) usize {
    return @min(default_radius, w / 2, h / 2);
}

/// Pixel area coverage, with 4x4 subpixel samples. Clamp the requested radius
/// to the window and the supported maximum to keep all integer math bounded.
pub fn coverage(x: usize, y: usize, w: usize, h: usize, requested_radius: usize) u8 {
    if (x >= w or y >= h) return 0;
    const r = @min(requested_radius, radius(w, h));
    if (r == 0) return 255;
    const cx = @min(x, w - 1 - x);
    const cy = @min(y, h - 1 - y);
    if (cx >= r or cy >= r) return 255;
    var inside: u16 = 0;
    for (0..4) |sy| {
        for (0..4) |sx| {
            const dx = r * 8 - (cx * 8 + sx * 2 + 1);
            const dy = r * 8 - (cy * 8 + sy * 2 + 1);
            if (dx * dx + dy * dy <= r * r * 64) inside += 1;
        }
    }
    return @intCast((inside * 255 + 8) / 16);
}

/// Blend an opaque RGB surface over the already composed pixel. The fourth
/// scanout byte is not alpha; it remains the source's reserved byte.
pub fn blend(source: u32, behind: u32, alpha: u8) u32 {
    var result = source & 0xff000000;
    inline for (.{ 0, 8, 16 }) |shift| {
        const s = (source >> shift) & 255;
        const b = (behind >> shift) & 255;
        result |= ((s * alpha + b * (255 - @as(u32, alpha)) + 127) / 255) << shift;
    }
    return result;
}

test "rounded shape symmetry, bounds, and antialiased edge" {
    var partial = false;
    for (0..50) |y| {
        for (0..80) |x| {
            const a = coverage(x, y, 80, 50, 12);
            try std.testing.expectEqual(a, coverage(79 - x, y, 80, 50, 12));
            try std.testing.expectEqual(a, coverage(x, 49 - y, 80, 50, 12));
            if (a > 0 and a < 255) partial = true;
        }
    }
    try std.testing.expect(partial);
    try std.testing.expectEqual(@as(u8, 0), coverage(0, 0, 80, 50, 12));
    try std.testing.expectEqual(@as(u8, 255), coverage(12, 0, 80, 50, 12));
    try std.testing.expectEqual(@as(u8, 0), coverage(80, 0, 80, 50, 12));
}

test "degenerate dimensions and inset radius" {
    try std.testing.expectEqual(@as(u8, 0), coverage(0, 0, 0, 0, 12));
    try std.testing.expectEqual(@as(u8, 255), coverage(0, 0, 1, 1, 12));
    try std.testing.expectEqual(@as(usize, 2), radius(4, 100));
    try std.testing.expectEqual(@as(u8, 255), coverage(0, 0, 40, 40, 0));
    try std.testing.expectEqual(coverage(2, 3, 40, 40, 12), coverage(2, 3, 40, 40, std.math.maxInt(usize)));
}

test "corner blend preserves underlying layer and intermediate coverage" {
    try std.testing.expectEqual(@as(u32, 0x123456), blend(0xffffff, 0x123456, 0));
    try std.testing.expectEqual(@as(u32, 0xffffff), blend(0xffffff, 0x123456, 255));
    try std.testing.expectEqual(@as(u32, 0x808080), blend(0xffffff, 0, 128));
}
