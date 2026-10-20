//! Shared build/run selection: a base name includes its ReleaseSafe row;
//! an explicit +rs name selects only that row.
const std = @import("std");

pub fn selected(only: ?[]const u8, label: []const u8) bool {
    const list = only orelse return true;
    const base = if (std.mem.endsWith(u8, label, "+rs")) label[0 .. label.len - 3] else label;
    var names = std.mem.splitScalar(u8, list, ',');
    while (names.next()) |entry| {
        const name = std.mem.trim(u8, entry, " ");
        if (std.mem.eql(u8, name, label) or std.mem.eql(u8, name, base)) return true;
    }
    return false;
}

test "base names include ReleaseSafe, explicit rows and prefixes stay exact" {
    try std.testing.expect(selected(null, "ipc+rs"));
    try std.testing.expect(selected("gui,ipc", "gui"));
    try std.testing.expect(selected("gui,ipc", "ipc+rs"));
    try std.testing.expect(selected("gui, ipc ", "ipc+rs"));
    try std.testing.expect(selected("fs+rs", "fs+rs"));
    try std.testing.expect(!selected("fs+rs", "fs"));
    try std.testing.expect(!selected("gui", "guilogin"));
    try std.testing.expect(!selected("ipc", "domain+rs"));
    try std.testing.expect(!selected("", "panic"));
}
