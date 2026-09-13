//! Fixed, allocation-free application menu vocabulary. Clients opt into a
//! profile and disable unavailable actions; the compositor validates every
//! invocation against this same catalog before routing it to the owner.
const std = @import("std");
const k = @import("keyboard.zig");
pub const Profile = enum(u64) { generic, editor, terminal, files, picker };
pub fn profileFromInt(value: u64) ?Profile {
    return if (value <= @intFromEnum(Profile.picker)) @enumFromInt(value) else null;
}
pub const minimize: u8 = 164;
pub const up: u8 = 165;
pub const refresh: u8 = 166;
pub const home: u8 = 167;
pub const Item = struct { label: []const u8, shortcut: []const u8 = "", key: u8 = 0 };
pub const Menu = struct { title: []const u8, items: []const Item };
const close: Item = .{ .label = "Close Window", .shortcut = "Cmd W", .key = k.close_window };
const sep: Item = .{ .label = "" };
const window = [_]Item{ .{ .label = "Minimize", .key = minimize }, close };
const editor_file = [_]Item{
    .{ .label = "New", .shortcut = "Cmd N", .key = k.new_document },
    .{ .label = "Open…", .shortcut = "Cmd O", .key = k.open_document },
    sep,
    .{ .label = "Save", .shortcut = "Cmd S", .key = k.save_document },
    .{ .label = "Save As…", .shortcut = "Shift Cmd S", .key = k.save_as },
    sep,
    .{ .label = "Close Tab", .shortcut = "Cmd W", .key = k.close_document },
};
const editor_window = [_]Item{
    .{ .label = "Next Tab", .shortcut = "Ctrl Tab", .key = k.next_tab },
    .{ .label = "Previous Tab", .shortcut = "Shift Ctrl Tab", .key = k.previous_tab },
    sep,
    .{ .label = "Minimize", .key = minimize },
    .{ .label = "Close Window", .shortcut = "Shift Cmd W", .key = k.close_all },
};
const edit = [_]Item{
    .{ .label = "Undo", .shortcut = "Cmd Z", .key = k.undo },
    .{ .label = "Redo", .shortcut = "Shift Cmd Z", .key = k.redo },
    sep,
    .{ .label = "Cut", .shortcut = "Cmd X", .key = k.cut },
    .{ .label = "Copy", .shortcut = "Cmd C", .key = k.copy },
    .{ .label = "Paste", .shortcut = "Cmd V", .key = k.paste },
    sep,
    .{ .label = "Select All", .shortcut = "Cmd A", .key = k.select_all },
    .{ .label = "Find…", .shortcut = "Cmd F", .key = k.find },
};
const term_edit = [_]Item{
    .{ .label = "Select All", .shortcut = "Cmd A", .key = k.select_all },
    .{ .label = "Copy", .shortcut = "Cmd C", .key = k.copy },
    .{ .label = "Paste", .shortcut = "Cmd V", .key = k.paste },
};
const files_file = [_]Item{ .{ .label = "Open", .shortcut = "Cmd O", .key = k.open_document }, close };
const files_go = [_]Item{ .{ .label = "Enclosing Folder", .key = up }, .{ .label = "Home", .key = home }, .{ .label = "Refresh", .key = refresh } };
const generic = [_]Menu{.{ .title = "Window", .items = &window }};
const editor = [_]Menu{ .{ .title = "File", .items = &editor_file }, .{ .title = "Edit", .items = &edit }, .{ .title = "Window", .items = &editor_window } };
const terminal = [_]Menu{ .{ .title = "Edit", .items = &term_edit }, .{ .title = "Window", .items = &window } };
const files = [_]Menu{ .{ .title = "File", .items = &files_file }, .{ .title = "Go", .items = &files_go }, .{ .title = "Window", .items = &window } };
const picker = [_]Menu{.{ .title = "File", .items = &.{.{ .label = "Cancel", .shortcut = "Esc", .key = k.close_window }} }};
pub fn catalog(profile: Profile) []const Menu {
    return switch (profile) {
        .generic => &generic,
        .editor => &editor,
        .terminal => &terminal,
        .files => &files,
        .picker => &picker,
    };
}
/// Stable action bits, independent of menu placement or duplicated Close.
pub fn bit(key: u8) u64 {
    return switch (key) {
        8 => 1,
        13 => 2,
        27 => 4,
        k.select_all => 8,
        147...157 => @as(u64, 1) << @intCast(key - 143),
        164...167, 169...171 => @as(u64, 1) << @intCast(key - 149),
        else => 0,
    };
}
pub fn offered(profile: Profile) u64 {
    var mask: u64 = 0;
    for (catalog(profile)) |menu| for (menu.items) |item| {
        mask |= bit(item.key);
    };
    return mask;
}
pub fn allows(profile: Profile, enabled: u64, key: u8) bool {
    const b = bit(key);
    return b != 0 and (enabled & offered(profile) & b) != 0;
}
test "menu actions cannot invoke keys outside the selected profile" {
    try std.testing.expect(allows(.editor, ~@as(u64, 0), k.save_document));
    try std.testing.expect(!allows(.terminal, ~@as(u64, 0), k.save_document));
    try std.testing.expect(!allows(.editor, 0, k.save_document));
    try std.testing.expect(!allows(.editor, ~@as(u64, 0), 'x'));
    try std.testing.expect(allows(.picker, ~@as(u64, 0), k.close_window));
    try std.testing.expect(!allows(.picker, ~@as(u64, 0), 27));
}
test "catalog actions have distinct bits and invalid profiles are rejected" {
    var seen: u64 = 0;
    for (0..256) |raw| {
        const b = bit(@intCast(raw));
        try std.testing.expectEqual(@as(u64, 0), seen & b);
        seen |= b;
    }
    for (std.enums.values(Profile)) |profile| {
        for (catalog(profile)) |menu| {
            try std.testing.expect(menu.title.len != 0);
            for (menu.items) |item| {
                if (item.key == 0) {
                    try std.testing.expectEqualStrings("", item.label);
                } else {
                    try std.testing.expect(item.label.len != 0);
                    try std.testing.expect(allows(profile, offered(profile), item.key));
                }
            }
        }
    }
    try std.testing.expect(profileFromInt(100) == null);
}
