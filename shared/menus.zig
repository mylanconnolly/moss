//! Fixed, allocation-free application menu vocabulary. Clients opt into a
//! profile and disable unavailable actions; the compositor validates every
//! invocation against this same catalog before routing it to the owner.
//!
//! The `custom` profile is an application's own menus: up to `max_menus`
//! titled menus (a nested one is a slot another item points at with
//! `sub`) of up to `max_app_items` items, each item an *application key*
//! (`appItemKey(i)`) the compositor routes like any catalog key — so the
//! validation is the same (a key the app did not publish, or disabled in
//! its mask, is refused) while the labels are the app's. Titles and
//! labels travel to the compositor packed in message words (16 bytes a
//! title, 32 a label in two parts) and the bar reads them back; the
//! Window menu of the generic catalog is appended after them.
const std = @import("std");
const k = @import("keyboard.zig");
pub const Profile = enum(u64) { generic, editor, terminal, files, picker, custom };
pub fn profileFromInt(value: u64) ?Profile {
    return if (value <= @intFromEnum(Profile.custom)) @enumFromInt(value) else null;
}
/// The application keys: `max_app_items` codes above the registry's own.
pub const app_item_base: u8 = 180;
pub const max_app_items: usize = 32;
pub const max_menus: usize = 8;
pub const title_bytes: usize = 16;
pub const label_bytes: usize = 32;
pub fn appItemKey(index: usize) u8 {
    return app_item_base + @as(u8, @intCast(index));
}
pub fn appItemIndex(key: u8) ?usize {
    return if (key >= app_item_base and key < app_item_base + max_app_items) key - app_item_base else null;
}
/// What `set_menu_item` and `menu_item` carry beside the text words: the
/// surface (or, in a reply, nothing), the item's index, which part the
/// words hold (0 and 1 the label's halves, 2 the shortcut hint), the menu
/// slot it sits in, its key (0 for a separator or a submenu header) and
/// the slot it opens (`sub`, 1-based, 0 for none).
pub const ItemMeta = struct { surface: u32 = 0, index: u8, part: u2 = 0, menu: u8, key: u8, sub: u8 };
pub const part_shortcut: u2 = 2;
pub const shortcut_bytes: usize = 16;
pub fn packItemMeta(m: ItemMeta) u64 {
    return @as(u64, m.surface) | (@as(u64, m.index) << 32) | (@as(u64, m.part) << 40) | (@as(u64, m.menu & 0xf) << 42) | (@as(u64, m.key) << 48) | (@as(u64, m.sub) << 56);
}
pub fn unpackItemMeta(w: u64) ItemMeta {
    return .{ .surface = @truncate(w), .index = @truncate(w >> 32), .part = @truncate(w >> 40), .menu = @truncate((w >> 42) & 0xf), .key = @truncate(w >> 48), .sub = @truncate(w >> 56) };
}
/// The chords a custom item's shortcut hint can name and have the window
/// act on: the registry's own (`k.save_document` for "Cmd S" …), so the
/// hint is the truth — pressing it fires the item. Null for a hint that
/// is only text (the app handles its own chord, or none does).
pub fn shortcutKey(hint: []const u8) ?u8 {
    const table = [_]struct { hint: []const u8, key: u8 }{
        .{ .hint = "Cmd S", .key = k.save_document },
        .{ .hint = "Shift Cmd S", .key = k.save_as },
        .{ .hint = "Cmd O", .key = k.open_document },
        .{ .hint = "Cmd N", .key = k.new_document },
        .{ .hint = "Cmd F", .key = k.find },
    };
    for (table) |row| if (std.mem.eql(u8, row.hint, hint)) return row.key;
    return null;
}
/// `set_menu_title` / `menu_slot`: the surface (or token) and the slot.
pub fn packSlot(surface_or_token: u64, slot: u8) u64 {
    return (surface_or_token & 0xffff_ffff_ffff) | (@as(u64, slot) << 56);
}
pub fn unpackSlot(w: u64) struct { id: u64, slot: u8 } {
    return .{ .id = w & 0xffff_ffff_ffff, .slot = @truncate(w >> 56) };
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
        .generic, .custom => &generic, // an app's own menus, then Window
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
const catalog_actions = [_]u8{
    k.select_all,  k.copy,         k.cut,           k.paste,            k.undo,
    k.redo,        k.new_document, k.open_document, k.save_document,    k.save_as,
    k.find,        k.close_window, k.minimize,      k.enclosing_folder, k.refresh,
    k.home_folder, k.next_tab,     k.previous_tab,  k.close_all,        k.readonly_view,
    k.leave_view,
};
/// The catalog's keys, then the application keys, in bit order.
const actions = catalog_actions ++ blk: {
    var app: [max_app_items]u8 = undefined;
    for (0..max_app_items) |i| app[i] = appItemKey(i);
    break :blk app;
};
comptime {
    std.debug.assert(actions.len <= 64);
}
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
    if (profile == .custom) for (0..max_app_items) |i| {
        mask |= bit(appItemKey(i));
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
    // Every table entry is a catalog key somewhere (the application keys
    // are the custom profile's), and every catalog key is in the table:
    // no dead bits, no unrouteable item.
    for (actions) |a| {
        var carried = appItemIndex(a) != null;
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
test "the custom profile offers its application keys and the Window menu, by the app's mask" {
    try std.testing.expect(allows(.custom, ~@as(u64, 0), appItemKey(0)));
    try std.testing.expect(allows(.custom, ~@as(u64, 0), appItemKey(max_app_items - 1)));
    try std.testing.expect(allows(.custom, ~@as(u64, 0), k.close_window));
    try std.testing.expect(!allows(.custom, ~@as(u64, 0), k.save_document));
    try std.testing.expect(!allows(.custom, ~bit(appItemKey(3)), appItemKey(3))); // disabled by the app
    try std.testing.expect(!allows(.editor, ~@as(u64, 0), appItemKey(0))); // no other profile routes them
    try std.testing.expect(appItemIndex(app_item_base + max_app_items) == null);
    try std.testing.expect(appItemIndex(k.leave_view) == null);
    try std.testing.expect(profileFromInt(@intFromEnum(Profile.custom)) == .custom);
}
test "item and slot metadata survive packing" {
    const m: ItemMeta = .{ .surface = 7, .index = 31, .part = part_shortcut, .menu = 5, .key = appItemKey(9), .sub = 3 };
    try std.testing.expectEqual(k.save_document, shortcutKey("Cmd S").?);
    try std.testing.expect(shortcutKey("Cmd C") == null); // a field's own, never claimed
    const back = unpackItemMeta(packItemMeta(m));
    try std.testing.expectEqual(m, back);
    const sl = unpackSlot(packSlot(0x1234_5678_9abc, 7));
    try std.testing.expectEqual(@as(u64, 0x1234_5678_9abc), sl.id);
    try std.testing.expectEqual(@as(u8, 7), sl.slot);
}
