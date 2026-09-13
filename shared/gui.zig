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

/// Integer tracks share the entire available width without rounding drift.
pub fn trackWidth(available: usize, total: usize, before: usize, weight: usize) usize {
    if (total == 0) return 0;
    return available * (before + weight) / total - available * before / total;
}
test "proportional columns fit including rounding and narrow widths" {
    for ([_]usize{ 0, 1, 17, 701 }) |w| {
        const a = trackWidth(w, 6, 0, 3);
        const b = trackWidth(w, 6, 3, 2);
        const c = trackWidth(w, 6, 5, 1);
        try std.testing.expectEqual(w, a + b + c);
        try std.testing.expect(a >= b);
    }
}

/// Two presses on one row within 500 ms activate it; a later click selects.
pub const DoubleClick = struct {
    row: ?usize = null,
    at_ms: u64 = 0,
    pub fn press(self: *DoubleClick, row: usize, now_ms: u64) bool {
        const activate = self.row == row and now_ms >= self.at_ms and now_ms - self.at_ms <= 500;
        self.* = if (activate) .{} else .{ .row = row, .at_ms = now_ms };
        return activate;
    }
};
test "double clicks expire, stay on one row, and reset after activation" {
    var click: DoubleClick = .{};
    try std.testing.expect(!click.press(2, 100));
    try std.testing.expect(!click.press(2, 800));
    try std.testing.expect(click.press(2, 1000));
    try std.testing.expect(!click.press(2, 1100));
    try std.testing.expect(!click.press(3, 1200));
    try std.testing.expect(click.press(3, 1300));
    click = .{}; // a directory change forgets the previous row
    try std.testing.expect(!click.press(3, 1400));
}

pub const icons = @import("icons.zig");
pub const tabs = @import("tabs.zig");
test {
    _ = icons;
    _ = tabs;
    _ = @import("display.zig");
}

/// Pixel scroll state, independent of rendering and window size.
pub const Scroll = struct {
    offset: usize = 0,
    extent: usize = 0,
    viewport: usize = 0,
    pub fn limit(self: Scroll) usize {
        return self.extent -| self.viewport;
    }
    pub fn fit(self: *Scroll, extent: usize, viewport: usize) void {
        self.extent = extent;
        self.viewport = viewport;
        self.offset = @min(self.offset, self.limit());
    }
    pub fn step(self: *Scroll, delta: isize) bool {
        const old = self.offset;
        self.offset = @intCast(std.math.clamp(@as(isize, @intCast(old)) + delta, 0, @as(isize, @intCast(self.limit()))));
        return old != self.offset;
    }
    pub fn reveal(self: *Scroll, start: usize, size: usize) bool {
        const old = self.offset;
        if (start < self.offset) self.offset = start else if (start + size > self.offset + self.viewport)
            self.offset = if (size >= self.viewport) start else start + size - self.viewport;
        self.offset = @min(self.offset, self.limit());
        return old != self.offset;
    }
};
test "scroll clamps on resize and reveals focus without undoing free scrolling" {
    var s: Scroll = .{};
    s.fit(1000, 200);
    try std.testing.expect(s.step(300));
    s.fit(1000, 200);
    try std.testing.expectEqual(@as(usize, 300), s.offset);
    try std.testing.expect(s.reveal(800, 40));
    try std.testing.expectEqual(@as(usize, 640), s.offset);
    try std.testing.expect(s.reveal(20, 40));
    s.fit(100, 200);
    try std.testing.expectEqual(@as(usize, 0), s.offset);
    try std.testing.expect(!s.step(-100));
}
