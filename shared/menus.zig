//! Fixed, allocation-free application menu vocabulary. Clients opt into a
//! profile and disable unavailable actions; the compositor validates every
//! invocation against this same catalog before routing it to the owner.
const std = @import("std");
const k = @import("keyboard.zig");
pub const Profile = enum(u64) { generic, editor, terminal, files, picker };
pub fn profileFromInt(value: u64) ?Profile {
    return if (value <= @intFromEnum(Profile.picker)) @enumFromInt(value) else null;
}
// The menu-only actions, under the names the menus use; the codes are
// the keyboard registry's so they cannot collide with a chord.
pub const minimize: u8 = k.minimize;
pub const up: u8 = k.enclosing_folder;
pub const refresh: u8 = k.refresh;
pub const home: u8 = k.home_folder;
pub const readonly_view: u8 = k.readonly_view;
pub const leave_view: u8 = k.leave_view;
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
const files_go = [_]Item{ .{ .label = "Enclosing Folder", .key = up }, .{ .label = "Home", .key = home }, .{ .label = "Refresh", .key = refresh }, sep, .{ .label = "Read-only View", .shortcut = "Shift Cmd L", .key = readonly_view }, .{ .label = "Leave View", .shortcut = "Alt Cmd L", .key = leave_view } };
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
/// Every key a catalog item can carry, in bit order. A client's enabled
/// mask and the compositor's check are both built from this table, so the
/// order only has to agree within one build — but append rather than
/// reorder, so a mask logged by one binary reads the same in the next.
const actions = [_]u8{
    k.select_all,  k.copy,         k.cut,           k.paste,            k.undo,
    k.redo,        k.new_document, k.open_document, k.save_document,    k.save_as,
    k.find,        k.close_window, k.minimize,      k.enclosing_folder, k.refresh,
    k.home_folder, k.next_tab,     k.previous_tab,  k.close_all,        k.readonly_view,
    k.leave_view,
};
/// Stable action bits, independent of menu placement or duplicated Close;
/// zero for a key no menu carries.
pub fn bit(key: u8) u64 {
    for (actions, 0..) |a, i| if (a == key) return @as(u64, 1) << @intCast(i);
    return 0;
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
    // Every table entry is a catalog key somewhere, and every catalog key
    // is in the table: no dead bits, no unrouteable item.
    for (actions) |a| {
        var carried = false;
        for (std.enums.values(Profile)) |profile| {
            for (catalog(profile)) |menu| for (menu.items) |item| {
                if (item.key == a) carried = true;
            };
        }
        try std.testing.expect(carried);
    }
    for ([_]u8{ 8, 13, 27, k.menu_focus, k.launcher }) |dead| try std.testing.expectEqual(@as(u64, 0), bit(dead));
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
