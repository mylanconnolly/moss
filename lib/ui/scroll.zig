//! Pixel scroll state, independent of rendering and window size.
const std = @import("std");

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
    /// Bring [start, start+size) into view, moving as little as possible.
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
test "a reveal larger than the viewport aligns its start" {
    var s: Scroll = .{};
    s.fit(1000, 100);
    try std.testing.expect(s.reveal(300, 250));
    try std.testing.expectEqual(@as(usize, 300), s.offset);
    try std.testing.expect(!s.reveal(300, 250));
}
