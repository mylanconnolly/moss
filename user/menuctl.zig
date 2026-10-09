//! The desktop chrome's side of the application-menu protocol: what the
//! top bar and the launcher ask the compositor about the active
//! application's menu, and how they invoke an item or hand focus back.
//! An application's own half — declaring its profile and enabled mask
//! for its window — stays in the window frame (`wf.setMenuProfile`);
//! nothing here is for an ordinary window, and the invoke/restore calls
//! need the `display_control` grant only resident chrome holds.
const shared = @import("shared");
const usys = @import("usys.zig");
const wf = @import("windowframe.zig");

/// The seat's output-control endpoint: every read of another window's
/// menus goes through it (the compositor serves them to nothing else),
/// set by the chrome that holds it before its first read.
pub var control_chan: u64 = 0;

pub const ActiveMenu = struct {
    token: u64 = 0,
    profile: shared.menus.Profile = .generic,
    enabled: u64 = 0,
};

fn call(channel: u64, req: shared.GpuReq) ?shared.GpuResp {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, channel, req, 0)) {
        .ok => |rep| rep,
        .err => null,
    };
}

/// The focused application's menu snapshot: a token that expires when
/// focus, incarnation, title or availability change, plus its profile
/// and enabled mask. Zero token: no application menu (trusted focus,
/// a titleless surface, nothing focused).
pub fn activeMenu() ActiveMenu {
    const rep = call(control_chan, .menu_info) orelse return .{};
    return switch (rep) {
        .menu => |m| .{ .token = m.token, .profile = shared.menus.profileFromInt(m.profile) orelse .generic, .enabled = m.enabled },
        else => .{},
    };
}

/// The application's title for the bar's app-name slot (NUL-padded).
pub fn menuTitle(token: u64) [shared.window_title_bytes]u8 {
    var result: [shared.window_title_bytes]u8 = @splat(0);
    const rep = call(control_chan, .{ .menu_title = .{ .token = token } }) orelse return result;
    switch (rep) {
        .menu_title => |t| {
            var buf: [24]u8 = undefined;
            const title = shared.wordsToStr(&buf, .{ t.a, t.b, 0 });
            const n = @min(title.len, result.len);
            @memcpy(result[0..n], title[0..n]);
        },
        else => {},
    }
    return result;
}

/// A custom menu's slot title (NUL-padded; empty for an unused slot).
pub fn menuSlot(token: u64, slot: u8) [shared.menus.title_bytes]u8 {
    var result: [shared.menus.title_bytes]u8 = @splat(0);
    const rep = call(control_chan, .{ .menu_slot = .{ .meta = shared.menus.packSlot(token, slot) } }) orelse return result;
    switch (rep) {
        .menu_title => |t| {
            var buf: [24]u8 = undefined;
            const title = shared.wordsToStr(&buf, .{ t.a, t.b, 0 });
            const n = @min(title.len, result.len);
            @memcpy(result[0..n], title[0..n]);
        },
        else => {},
    }
    return result;
}
pub const CustomItem = struct {
    used: bool = false,
    menu: u8 = 0,
    key: u8 = 0,
    sub: u8 = 0,
    label: [shared.menus.label_bytes]u8 = @splat(0),
    label_len: u8 = 0,
    shortcut: [shared.menus.shortcut_bytes]u8 = @splat(0),
    shortcut_len: u8 = 0,
};
/// A custom menu's item by index: its label read in two parts, then its
/// shortcut hint (empty for none).
pub fn menuItem(token: u64, index: u8) CustomItem {
    var item: CustomItem = .{};
    if (menuItemParts(token, index, &item)) {
        const rep = call(control_chan, .{ .menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(token & shared.menus.token_bits), .index = index, .part = shared.menus.part_shortcut, .menu = 0, .key = 0, .sub = 0 }) } }) orelse return item;
        if (rep == .menu_item) {
            var buf: [24]u8 = undefined;
            const text = shared.wordsToStr(&buf, .{ rep.menu_item.a, rep.menu_item.b, 0 });
            const n = @min(text.len, item.shortcut.len);
            @memcpy(item.shortcut[0..n], text[0..n]);
            item.shortcut_len = @intCast(n);
        }
    }
    return item;
}
/// The label parts; true when the item is in use.
fn menuItemParts(token: u64, index: u8, item: *CustomItem) bool {
    for ([_]u2{ 0, 1 }) |part| {
        const rep = call(control_chan, .{ .menu_item = .{ .meta = shared.menus.packItemMeta(.{ .surface = @intCast(token & shared.menus.token_bits), .index = index, .part = part, .menu = 0, .key = 0, .sub = 0 }) } }) orelse return item.used;
        switch (rep) {
            .menu_item => |it| {
                const meta = shared.menus.unpackItemMeta(it.meta);
                if (meta.surface == 0) return false; // unused
                item.used = true;
                item.menu = meta.menu;
                item.key = meta.key;
                item.sub = meta.sub;
                var buf: [24]u8 = undefined;
                const text = shared.wordsToStr(&buf, .{ it.a, it.b, 0 });
                const n = @min(text.len, item.label.len - item.label_len);
                @memcpy(item.label[item.label_len .. item.label_len + n], text[0..n]);
                item.label_len += @intCast(n);
                if (text.len < shared.menus.label_bytes / 2) return true; // no second part
            },
            else => return item.used,
        }
    }
    return true;
}

/// Invoke a menu item on the application the token names. The
/// compositor validates the key against the profile and mask it holds.
pub fn invokeMenu(control: u64, token: u64, key: u8) bool {
    if (control == 0) return false;
    const rep = call(control, .{ .menu_invoke = .{ .token = token, .key = key } }) orelse return false;
    return rep == .ok;
}

/// Hand focus back to the application after a popup or the launcher
/// dismisses; refused when the token has expired.
pub fn restoreMenuFocus(control: u64, token: u64) bool {
    if (control == 0) return false;
    const rep = call(control, .{ .menu_restore = .{ .token = token } }) orelse return false;
    return rep == .ok;
}
