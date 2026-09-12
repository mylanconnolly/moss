//! Shared, allocation-free GUI metrics and bounded row layout.
const std = @import("std");
pub const space = struct {
    pub const small = 8;
    pub const medium = 12;
    pub const large = 20;
    pub const inset = 24;
};
pub const control = struct {
    pub const button_x = 16;
    pub const button_y = 8;
    pub const field_x = 12;
    pub const field_y = 8;
    pub const radius = 6;
};
pub const Size = struct { w: usize = 0, h: usize = 0 };
pub const Placement = struct { x: usize, y: usize, w: usize };
/// Greedy rows wrap as a unit before placing a child. Oversized children
/// receive the available width; neither painting nor hit testing may exceed it.
pub const Flow = struct {
    width: usize,
    gap: usize,
    x: usize = 0,
    y: usize = 0,
    line_h: usize = 0,
    used: usize = 0,
    occupied: bool = false,
    pub fn put(self: *Flow, child: Size) Placement {
        const w = @min(child.w, self.width);
        if (self.occupied and (self.x > self.width or w > self.width - self.x)) {
            self.y += self.line_h + self.gap;
            self.x = 0;
            self.line_h = 0;
            self.occupied = false;
        }
        const p = Placement{ .x = self.x, .y = self.y, .w = w };
        self.used = @max(self.used, self.x + w);
        self.x += w + self.gap;
        self.line_h = @max(self.line_h, child.h);
        self.occupied = true;
        return p;
    }
    pub fn size(self: Flow) Size {
        return .{ .w = self.used, .h = self.y + self.line_h };
    }
};
test "rows wrap, preserve order, and bound oversized children" {
    var row = Flow{ .width = 100, .gap = 8 };
    try std.testing.expectEqual(Placement{ .x = 0, .y = 0, .w = 60 }, row.put(.{ .w = 60, .h = 20 }));
    try std.testing.expectEqual(Placement{ .x = 68, .y = 0, .w = 32 }, row.put(.{ .w = 32, .h = 30 }));
    try std.testing.expectEqual(Placement{ .x = 0, .y = 38, .w = 100 }, row.put(.{ .w = 500, .h = 10 }));
    try std.testing.expectEqual(Size{ .w = 100, .h = 48 }, row.size());
}
test "empty and zero-width rows are defined" {
    var row = Flow{ .width = 0, .gap = 8 };
    try std.testing.expectEqual(Size{}, row.size());
    try std.testing.expectEqual(@as(usize, 0), row.put(.{ .w = 100, .h = 20 }).w);
    try std.testing.expectEqual(@as(usize, 20), row.size().h);
}
