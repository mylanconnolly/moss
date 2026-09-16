//! Rectangles, sizes and the spacing/control tokens every widget shares.
const std = @import("std");

pub const Rect = struct { x: usize, y: usize, w: usize, h: usize };
pub const Size = struct { w: usize = 0, h: usize = 0 };
/// Where a flow placed a child: its top-left and the width it was given.
pub const Placement = struct { x: usize, y: usize, w: usize };

pub fn contains(r: Rect, x: usize, y: usize) bool {
    return x >= r.x and y >= r.y and x - r.x < r.w and y - r.y < r.h;
}

/// Spacing tokens (logical pixels at the 16 px UI font).
pub const space = struct {
    pub const small = 8;
    pub const medium = 12;
    pub const large = 20;
    pub const inset = 24;
};
/// Control padding and corner radius.
pub const control = struct {
    pub const button_x = 16;
    pub const button_y = 8;
    pub const field_x = 12;
    pub const field_y = 8;
    pub const radius = 6;
};

test "contains is half-open on both axes" {
    const r: Rect = .{ .x = 10, .y = 20, .w = 5, .h = 3 };
    try std.testing.expect(contains(r, 10, 20));
    try std.testing.expect(contains(r, 14, 22));
    try std.testing.expect(!contains(r, 15, 22));
    try std.testing.expect(!contains(r, 14, 23));
    try std.testing.expect(!contains(r, 9, 20));
    try std.testing.expect(!contains(.{ .x = 0, .y = 0, .w = 0, .h = 0 }, 0, 0));
}
