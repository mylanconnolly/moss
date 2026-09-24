//! Pointer gestures that are timing, not pixels.
const std = @import("std");

pub const double_click_ms: u64 = 500;

/// Two presses on one row within the window activate it (a list's
/// double-click); the pair then resets, so a third press selects again.
pub const DoubleClick = struct {
    clicks: MultiClick = .{},
    /// The row and time of the pending first click (for a caller's log).
    pub fn row(self: *const DoubleClick) ?usize {
        return self.clicks.target;
    }
    pub fn atMs(self: *const DoubleClick) u64 {
        return self.clicks.at_ms;
    }
    pub fn press(self: *DoubleClick, row_: usize, now_ms: u64) bool {
        const activate = self.clicks.press(row_, now_ms) == 2;
        if (activate) self.clicks = .{};
        return activate;
    }
};
/// Presses on one target in quick succession count up — two select a
/// word, three a line, four everything — and a press elsewhere, or
/// after the window, starts over at one.
pub const MultiClick = struct {
    target: ?usize = null,
    at_ms: u64 = 0,
    count: u8 = 0,
    pub fn press(self: *MultiClick, target: usize, now_ms: u64) u8 {
        const again = self.target == target and now_ms >= self.at_ms and now_ms - self.at_ms <= double_click_ms;
        self.count = if (again) @min(self.count + 1, 4) else 1;
        self.target = target;
        self.at_ms = now_ms;
        return self.count;
    }
};
test "multi-clicks count up on one target within the window and start over elsewhere" {
    var m: MultiClick = .{};
    try std.testing.expectEqual(@as(u8, 1), m.press(7, 100));
    try std.testing.expectEqual(@as(u8, 2), m.press(7, 300));
    try std.testing.expectEqual(@as(u8, 3), m.press(7, 500));
    try std.testing.expectEqual(@as(u8, 4), m.press(7, 700));
    try std.testing.expectEqual(@as(u8, 4), m.press(7, 900));
    try std.testing.expectEqual(@as(u8, 1), m.press(8, 1000));
    try std.testing.expectEqual(@as(u8, 1), m.press(8, 1600));
}
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
