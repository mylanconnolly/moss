//! Allocation-free tab-strip geometry. Content and ownership stay with clients.
const std = @import("std");
pub const State = struct {
    first: usize = 0,
    reveal_pending: bool = false,
    viewport_width: usize = 0,
    viewport_height: usize = 0,
    selection_visible: bool = false,
    /// Preserve a visible active tab when labels/dirty badges change widths.
    /// Arrow navigation clears the previous observation so it may deliberately
    /// scroll the active tab away; ordinary repaints do not undo that choice.
    pub fn preserveVisibility(self: *State, visible: bool, selected: usize) void {
        if (self.selection_visible and !visible) self.reveal(selected);
    }
    /// A display/font resize reveals the active tab again; ordinary paints
    /// preserve explicit arrow scrolling, even when selection is offscreen.
    pub fn resize(self: *State, width: usize, height: usize, selected: usize) void {
        if (width != self.viewport_width or height != self.viewport_height) self.reveal(selected);
        self.viewport_width = width;
        self.viewport_height = height;
    }
    pub fn reveal(self: *State, index: usize) void {
        self.first = index;
        self.reveal_pending = true;
    }
    pub fn previous(self: *State) void {
        self.reveal_pending = false;
        self.selection_visible = false;
        self.first -|= 1;
    }
    pub fn next(self: *State, count: usize) void {
        self.reveal_pending = false;
        self.selection_visible = false;
        self.first = @min(self.first +| 1, count -| 1);
    }
};
pub const Span = struct {
    x: usize = 0,
    w: usize = 0,
    pub fn contains(self: Span, x: usize) bool {
        return x >= self.x and x - self.x < self.w;
    }
};
pub const Hit = union(enum) { none, select: usize, close: usize, previous, next };
pub const Tab = struct {
    body: Span,
    close: Span,
    pub fn hit(self: Tab, index: usize, x: usize) Hit {
        if (self.close.contains(x)) return .{ .close = index };
        if (self.body.contains(x)) return .{ .select = index };
        return .none;
    }
};
pub const Layout = struct {
    previous: Span,
    next: Span,
    content: Span,
    cursor: usize,
    height: usize,
    pub fn init(width: usize, height: usize, overflow: bool) Layout {
        const nav = if (overflow) @min(height, width / 3) else 0;
        return .{ .previous = .{ .w = nav }, .next = .{ .x = width - nav, .w = nav }, .content = .{ .x = nav, .w = width - nav * 2 }, .cursor = nav, .height = height };
    }
    /// Only the first visible tab may be narrower than a normal control.
    /// Later tabs move offscreen intact instead of leaving tiny hit targets.
    pub fn put(self: *Layout, desired: usize, closable: bool) ?Tab {
        const remaining = self.content.x + self.content.w - self.cursor;
        if (remaining == 0 or (self.cursor != self.content.x and remaining < @min(desired, self.height * 2))) return null;
        const width = @min(@max(desired, 1), remaining);
        const close_width = if (closable and width >= self.height * 2) self.height else 0;
        const result = Tab{ .body = .{ .x = self.cursor, .w = width }, .close = .{ .x = self.cursor + width - close_width, .w = close_width } };
        self.cursor += width;
        return result;
    }
};
test "overflow geometry stays bounded and separates close from selection" {
    for ([_]usize{ 0, 1, 2, 20, 100, 1024 }) |width| {
        var layout = Layout.init(width, 72, true);
        try std.testing.expect(layout.previous.x + layout.previous.w <= width);
        try std.testing.expect(layout.next.x + layout.next.w <= width);
        if (layout.put(300, true)) |tab| {
            try std.testing.expect(tab.body.x + tab.body.w <= layout.next.x);
            try std.testing.expect(tab.close.x + tab.close.w <= tab.body.x + tab.body.w);
            try std.testing.expectEqual(Hit{ .select = 4 }, tab.hit(4, tab.body.x));
            if (tab.close.w != 0) try std.testing.expectEqual(Hit{ .close = 4 }, tab.hit(4, tab.close.x));
            try std.testing.expectEqual(Hit.none, tab.hit(4, tab.body.x + tab.body.w));
        }
    }
}
test "offscreen tabs have no geometry and scrolling reaches every document" {
    var layout = Layout.init(300, 40, true);
    _ = layout.put(180, true).?;
    try std.testing.expect(layout.put(180, true) == null);
    var state: State = .{};
    state.previous();
    try std.testing.expectEqual(@as(usize, 0), state.first);
    for (0..20) |_| state.next(10);
    try std.testing.expectEqual(@as(usize, 9), state.first);
    state.reveal(3);
    try std.testing.expectEqual(@as(usize, 3), state.first);
    state.next(0);
    try std.testing.expectEqual(@as(usize, 0), state.first);
}
test "resizing reveals selection without resetting manual tab scrolling" {
    var state: State = .{};
    state.resize(1000, 40, 7);
    try std.testing.expect(state.reveal_pending);
    try std.testing.expectEqual(@as(usize, 7), state.first);
    state.previous();
    state.resize(1000, 40, 7);
    try std.testing.expect(!state.reveal_pending);
    try std.testing.expectEqual(@as(usize, 6), state.first);
    state.resize(700, 72, 7);
    try std.testing.expect(state.reveal_pending);
    try std.testing.expectEqual(@as(usize, 7), state.first);
}
test "label growth preserves visible selection but explicit scrolling may hide it" {
    const Probe = struct {
        fn visible(widths: []const usize, first: usize, selected: usize) bool {
            var total: usize = 0;
            for (widths) |width| total += width;
            var row = Layout.init(300, 40, total > 300 or first > 0);
            for (widths[first..], first..) |width, index| {
                _ = row.put(width, true) orelse return false;
                if (index == selected) return true;
            }
            return false;
        }
    };
    var state: State = .{};
    state.selection_visible = Probe.visible(&.{ 100, 100, 100 }, 0, 2);
    try std.testing.expect(state.selection_visible);
    const changed = [_]usize{ 100, 100, 240 };
    try std.testing.expect(!Probe.visible(&changed, state.first, 2));
    state.preserveVisibility(Probe.visible(&changed, state.first, 2), 2);
    try std.testing.expect(state.reveal_pending);
    try std.testing.expectEqual(@as(usize, 2), state.first);
    try std.testing.expect(Probe.visible(&changed, state.first, 2));
    state.selection_visible = true;
    state.previous();
    const wide = [_]usize{ 240, 240, 240 };
    try std.testing.expect(!Probe.visible(&wide, state.first, 2));
    state.preserveVisibility(Probe.visible(&wide, state.first, 2), 2);
    try std.testing.expect(!state.reveal_pending);
    try std.testing.expectEqual(@as(usize, 1), state.first);
}
