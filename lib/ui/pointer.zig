//! Pointer gestures that are timing, not pixels.
const std = @import("std");

/// Two presses on one row within `window_ms` activate it; a later click selects.
pub const double_click_ms: u64 = 500;
pub const DoubleClick = struct {
    row: ?usize = null,
    at_ms: u64 = 0,
    pub fn press(self: *DoubleClick, row: usize, now_ms: u64) bool {
        const activate = self.row == row and now_ms >= self.at_ms and now_ms - self.at_ms <= double_click_ms;
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
