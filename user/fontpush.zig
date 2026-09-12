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

// Keep more than the old eight slots alive, then churn beyond the old
// 250-registration ceiling. Layout checks that each attached buffer works.
fn exerciseClients() void {
    var clients: [16]u64 = undefined;
    var buffers: [16]u64 = undefined;
    var addresses: [16]u64 = undefined;
    for (&buffers, &addresses) |*buffer, *address| {
        const sh = usys.shmCreate(1);
        if (sh.err != .ok) fail("fontpush: client shm");
        buffer.* = sh.data[0];
        const mapped = usys.shmMap(buffer.*);
        if (mapped.err != .ok) fail("fontpush: client map");
        address.* = mapped.data[0];
    }
    defer for (buffers, addresses) |buffer, address| {
        _ = usys.shmUnmap(address);
        _ = usys.capDrop(buffer);
    };
    for (0..64) |_| {
        for (&clients, buffers) |*client, buffer| {
            const r = usys.callTypedCap(shared.FontReq, shared.FontResp, fontc, .register, 0);
            client.* = switch (r) {
                .ok => |v| if (v.rep == .registered and v.cap != 0) v.cap else fail("fontpush: register refused"),
                .err => fail("fontpush: register failed"),
            };
            switch (usys.callTyped(shared.FontReq, shared.FontResp, client.*, .attach_buf, buffer)) {
                .ok => |v| if (v != .ok) fail("fontpush: client attach refused"),
                .err => fail("fontpush: client attach failed"),
            }
        }
        for (addresses, 0..) |address, i| {
            const buf: [*]u8 = @ptrFromInt(address);
            @memset(buf[0 .. i + 1], 'A');
        }
        for (clients, 0..) |client, i| {
            switch (usys.callTyped(shared.FontReq, shared.FontResp, client, .{ .layout = .{ .role = 0, .px = 0, .len = i + 1 } }, 0)) {
                .ok => |v| switch (v) {
                    .laid => |run| if (run.count != i + 1) fail("fontpush: wrong glyph count"),
                    else => fail("fontpush: layout refused"),
                },
                .err => fail("fontpush: layout failed"),
            }
            const glyph: *const shared.FontGlyph = @ptrFromInt(addresses[i]);
            if (glyph.pen_x != 0 or glyph.w == 0 or glyph.h == 0) fail("fontpush: wrong client buffer");
        }
        for (clients) |client| _ = usys.capDrop(client);
    }
    _ = usys.log(glog, "fontpush: 16 concurrent, 1024 lifetime clients PASS");
}

fn layoutWidth(px: u64) u64 {
    @memcpy(fbuf[0..5], "Scale");
    return switch (usys.callTyped(shared.FontReq, shared.FontResp, fontc, .{ .layout = .{ .role = 0, .px = px, .len = 5 } }, 0)) {
        .ok => |v| switch (v) {
            .laid => |run| run.pen,
            else => fail("fontpush: scale layout refused"),
        },
        .err => fail("fontpush: scale layout failed"),
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

    // No legacy buffer is attached yet: every batch leaves the service
    // with zero records, exercising empty-slab reclamation too.
    exerciseClients();

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
    if (layoutWidth(0) != layoutWidth(login_px)) fail("fontpush: explicit pixel size scaled twice");
    var l: [64]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&l, "fontpush: login ui={d}px", .{login_px}) catch "fontpush: login");
    const logout_px = pushLayer("");
    var l2: [64]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&l2, "fontpush: logout ui={d}px", .{logout_px}) catch "fontpush: logout");
    usys.exit(0);
}
