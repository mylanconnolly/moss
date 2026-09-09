//! fontpush — the per-user font-scale drill's client. It plays a session
//! applying the logged-in user's font settings: it reads a user's
//! `font.msh` (a per-user layer, here staged in the archive as
//! conf/userscale.msh — in a real system it is home/<user>/conf/font.msh)
//! and pushes it to the shared fontsvc, which merges it over the system
//! layer and re-applies. It confirms the pushed scale is effective by
//! reading back the ui role's size, then reverts on "logout" (an empty
//! reconfigure) and confirms the size returns to the system default.
//!
//! fontsvc is a singleton — one atlas, one effective scale — so per-user
//! scale means the logged-in user's scale is pushed to the global service
//! for the life of their session; this is the mechanism a post-login GUI
//! session will drive automatically once one exists.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("fontpush"));
}

pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;
fn fail(msg: []const u8) noreturn {
    _ = usys.log(glog, msg);
    usys.exit(1);
}

var fontc: u64 = 0;
var fbuf: [*]u8 = undefined;

/// Push a user layer (empty = revert to the system layer) and return the
/// resulting effective ui-role size in device pixels.
fn pushLayer(user_text: []const u8) u64 {
    if (user_text.len > 0) {
        if (user_text.len > 8192) fail("fontpush: config too large");
        @memcpy(fbuf[0..user_text.len], user_text);
    }
    switch (usys.callTyped(shared.FontReq, shared.FontResp, fontc, .{ .reconfigure = .{ .len = user_text.len } }, 0)) {
        .ok => |r| if (r != .ok) fail("fontpush: reconfigure refused"),
        .err => fail("fontpush: reconfigure did not answer"),
    }
    return switch (usys.callTyped(shared.FontReq, shared.FontResp, fontc, .{ .metrics = .{ .role = 0 } }, 0)) {
        .ok => |r| switch (r) {
            .metrics => |m| m.px,
            else => 0,
        },
        .err => 0,
    };
}

export fn umain(log_h: u64, chan_h: u64, _: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.font)) fail("fontpush: no font cap");
    fontc = setup.cap(.font);
    if (blob_va == 0) fail("fontpush: no boot archive");
    const blob = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    const cfg = shared.marcFind(blob, "conf/userscale.msh") orelse fail("fontpush: no user font config");

    // Attach a request buffer to fontsvc; the user layer is staged there.
    const sh = usys.shmCreate(2);
    if (sh.err != .ok) fail("fontpush: shm");
    const sm = usys.shmMap(sh.data[0]);
    if (sm.err != .ok) fail("fontpush: map");
    fbuf = @ptrFromInt(sm.data[0]);
    switch (usys.callTyped(shared.FontReq, shared.FontResp, fontc, .attach_buf, sh.data[0])) {
        .ok => {},
        .err => fail("fontpush: attach_buf failed"),
    }

    // Login: apply the user's layer; logout: revert to the system layer.
    const login_px = pushLayer(cfg);
    var l: [64]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&l, "fontpush: login ui={d}px", .{login_px}) catch "fontpush: login");
    const logout_px = pushLayer("");
    var l2: [64]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&l2, "fontpush: logout ui={d}px", .{logout_px}) catch "fontpush: logout");
    usys.exit(0);
}
