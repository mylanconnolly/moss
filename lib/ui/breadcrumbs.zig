//! Ancestors of a canonical path relative to one capability view. Root is
//! always the empty path; this model never synthesizes '..' or absolute paths.
const std = @import("std");
pub const Part = struct { label: []const u8, path: []const u8 };
pub const Model = struct {
    path: []const u8,
    count: usize,
    pub fn init(path: []const u8) ?Model {
        if (path.len > 256 or !std.unicode.utf8ValidateSlice(path)) return null;
        if (path.len == 0) return .{ .path = path, .count = 1 };
        var it = std.mem.splitScalar(u8, path, '/');
        var count: usize = 1;
        while (it.next()) |part| {
            if (part.len == 0 or std.mem.eql(u8, part, ".") or std.mem.eql(u8, part, "..")) return null;
            for (part) |byte| if (byte < 32 or byte == 127) return null;
            count += 1;
        }
        return .{ .path = path, .count = count };
    }
    pub fn at(self: Model, index: usize, root: []const u8) ?Part {
        if (index >= self.count) return null;
        if (index == 0) return .{ .label = root, .path = self.path[0..0] };
        var begin: usize = 0;
        var current: usize = 1;
        for (self.path, 0..) |byte, end| {
            if (byte != '/') continue;
            if (current == index) return .{ .label = self.path[begin..end], .path = self.path[0..end] };
            current += 1;
            begin = end + 1;
        }
        return .{ .label = self.path[begin..], .path = self.path };
    }
};
test "breadcrumbs stay inside their current view root" {
    const m = Model.init("documents/work/notes").?;
    try std.testing.expectEqual(@as(usize, 4), m.count);
    try std.testing.expectEqualStrings("", m.at(0, "Read-only view").?.path);
    try std.testing.expectEqualStrings("Read-only view", m.at(0, "Read-only view").?.label);
    try std.testing.expectEqualStrings("documents", m.at(1, "Home").?.path);
    try std.testing.expectEqualStrings("documents/work", m.at(2, "Home").?.path);
    try std.testing.expectEqualStrings("notes", m.at(3, "Home").?.label);
    try std.testing.expect(m.at(4, "Home") == null);
    try std.testing.expectEqual(@as(usize, 1), Model.init("").?.count);
    for ([_][]const u8{ "/etc", "../etc", "a/../b", "a//b", "a/", "a/./b", "a\x00b", "\xff" }) |bad| try std.testing.expect(Model.init(bad) == null);
}
