//! Informational application catalog. Stable IDs are unit names; metadata never
//! grants authority or changes the unit's ordinary lazy activation policy.
const std = @import("std");
const icons = @import("icons.zig");
pub const running: u32 = 1;
pub const dock: u32 = 2;
pub const metadata_keys = [_][]const u8{ "name", "description", "icon", "window", "dock", "order" };
pub fn knownKey(key: []const u8) bool {
    for (metadata_keys) |known| if (std.mem.eql(u8, key, known)) return true;
    return false;
}
pub const Record = struct {
    unit: [16]u8 = @splat(0),
    name: [48]u8 = @splat(0),
    description: [128]u8 = @splat(0),
    icon: [24]u8 = @splat(0),
    window: [16]u8 = @splat(0),
    flags: u32 = 0,
    order: u32 = 1000,
    pub const size = 240;
    pub fn init(unit: []const u8, name: []const u8, description: []const u8, icon: []const u8, window: []const u8, pinned: bool, order: u32) ?Record {
        if (!validUnit(unit) or !validText(name, 48) or !validText(description, 128) or !validText(icon, 24) or !validText(window, 16)) return null;
        if (icons.parse(icon) == null or order > 65535) return null;
        var r: Record = .{ .flags = if (pinned) dock else 0, .order = order };
        @memcpy(r.unit[0..unit.len], unit);
        @memcpy(r.name[0..name.len], name);
        @memcpy(r.description[0..description.len], description);
        @memcpy(r.icon[0..icon.len], icon);
        @memcpy(r.window[0..window.len], window);
        return r;
    }
    pub fn encode(r: *const Record, out: *[size]u8) void {
        @memcpy(out[0..16], &r.unit);
        @memcpy(out[16..64], &r.name);
        @memcpy(out[64..192], &r.description);
        @memcpy(out[192..216], &r.icon);
        @memcpy(out[216..232], &r.window);
        std.mem.writeInt(u32, out[232..236], r.flags, .little);
        std.mem.writeInt(u32, out[236..240], r.order, .little);
    }
    pub fn decode(bytes: *const [size]u8) Record {
        return .{ .unit = bytes[0..16].*, .name = bytes[16..64].*, .description = bytes[64..192].*, .icon = bytes[192..216].*, .window = bytes[216..232].*, .flags = std.mem.readInt(u32, bytes[232..236], .little), .order = std.mem.readInt(u32, bytes[236..240], .little) };
    }
    pub fn unitSlice(r: *const Record) []const u8 {
        return text(&r.unit);
    }
    pub fn nameSlice(r: *const Record) []const u8 {
        return text(&r.name);
    }
    pub fn descriptionSlice(r: *const Record) []const u8 {
        return text(&r.description);
    }
    pub fn iconSlice(r: *const Record) []const u8 {
        return text(&r.icon);
    }
    pub fn windowSlice(r: *const Record) []const u8 {
        return text(&r.window);
    }
};
pub fn text(bytes: []const u8) []const u8 {
    return bytes[0..(std.mem.indexOfScalar(u8, bytes, 0) orelse bytes.len)];
}
fn validUnit(unit: []const u8) bool {
    if (unit.len == 0 or unit.len > 16) return false;
    for (unit) |c| if (!std.ascii.isAlphanumeric(c) and c != '-' and c != '_') return false;
    return true;
}
fn validText(value: []const u8, max: usize) bool {
    if (value.len == 0 or value.len > max or !std.unicode.utf8ValidateSlice(value)) return false;
    if (value[0] == ' ' or value[value.len - 1] == ' ') return false;
    for (value) |c| if (c < 32 or c == 127) return false;
    return true;
}
test "application metadata owns bytes and has a stable roundtrip wire format" {
    var name = [_]u8{ 'E', 'd', 'i', 't', 'o', 'r' };
    var r = Record.init("medit", &name, "Edit text documents", "file-text", "Editor", true, 50).?;
    name[0] = 'X';
    r.flags |= running;
    var wire: [Record.size]u8 = undefined;
    r.encode(&wire);
    const copy = Record.decode(&wire);
    try std.testing.expectEqualStrings("Editor", copy.nameSlice());
    try std.testing.expectEqualStrings("medit", copy.unitSlice());
    try std.testing.expectEqualStrings("Edit text documents", copy.descriptionSlice());
    try std.testing.expectEqualStrings("file-text", copy.iconSlice());
    try std.testing.expectEqualStrings("Editor", copy.windowSlice());
    try std.testing.expectEqual(@as(u32, running | dock), copy.flags);
    try std.testing.expectEqual(@as(u32, 50), copy.order);
}
test "invalid application metadata is refused rather than truncated" {
    const overlong_description: [129]u8 = @splat('x');
    try std.testing.expect(Record.init("medit", "Editor", &overlong_description, "file", "Editor", false, 0) == null);
    try std.testing.expect(Record.init("overlong-unit-name", "Editor", "Edit", "file", "Editor", false, 0) == null);
    try std.testing.expect(Record.init("medit", "Bad\nName", "Edit", "file", "Editor", false, 0) == null);
    try std.testing.expect(Record.init("medit", "Editor", "", "file", "Editor", false, 0) == null);
    try std.testing.expect(Record.init("medit", "Editor", "Edit", "nonexistent", "Editor", false, 0) == null);
    try std.testing.expect(Record.init("medit", "Editor", "Edit", "file", "Too long window title", false, 0) == null);
    try std.testing.expect(Record.init("medit", "Editor", "Edit", "file", "Editor", false, 65536) == null);
    try std.testing.expect(knownKey("description"));
    try std.testing.expect(!knownKey("grant"));
}
