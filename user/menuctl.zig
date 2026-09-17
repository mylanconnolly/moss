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
    const rep = call(wf.chan, .menu_info) orelse return .{};
    return switch (rep) {
        .menu => |m| .{ .token = m.token, .profile = shared.menus.profileFromInt(m.profile) orelse .generic, .enabled = m.enabled },
        else => .{},
    };
}

/// The application's title for the bar's app-name slot (NUL-padded).
pub fn menuTitle(token: u64) [16]u8 {
    var result: [16]u8 = @splat(0);
    const rep = call(wf.chan, .{ .menu_title = .{ .token = token } }) orelse return result;
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
