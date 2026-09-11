//! clipsvc — the system clipboard service. It holds one shared text value;
//! a client copies a selection into it (`set`) and another pastes it out
//! (`get`), so text crosses between apps — a selection made in the terminal
//! pastes into the file explorer's path field, and so on. It is reached as
//! a capability (the `clip` give), lazy and init-supervised, exactly like
//! the font and locale services.
//!
//! Like fontsvc and localesvc, a client `register`s for a badged channel
//! and attaches its own byte buffer, so concurrent clients never trample
//! one transfer buffer. The clipboard itself is a single fixed buffer here;
//! it holds bytes with no interpretation and truncates rather than failing
//! when a copy is larger than the cap.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("clipsvc"));
}

pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;

// The one clipboard value.
const clip_cap = 64 << 10; // 64 KB is plenty for a selection; larger copies truncate
var clip: [clip_cap]u8 = undefined;
var clip_len: usize = 0;

// Per-client transfer buffers, keyed by the invoking badge — the same
// model fontsvc/localesvc use. A client registers for a fresh badge (2..);
// an unregistered client keeps badge 0 and cannot transfer.
const CClient = struct { used: bool = false, badge: u64 = 0, va: u64 = 0, len: usize = 0 };
var clients: [64]CClient = @splat(.{});
var next_badge: u64 = 2;
const max_badge: u64 = 250;

fn clientFor(badge: u64) ?*CClient {
    for (&clients) |*c| if (c.used and c.badge == badge) return c;
    return null;
}

fn clientAlloc(badge: u64) ?*CClient {
    if (clientFor(badge)) |c| return c;
    for (&clients) |*c| if (!c.used) {
        c.* = .{ .used = true, .badge = badge };
        return c;
    };
    return null;
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    _ = arg;
    _ = blob_va;
    _ = blob_len;
    glog = log_h;
    _ = boot.take(chan_h); // no caps needed — the clipboard is pure state
    _ = usys.log(glog, "clipsvc: up");

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(shared.ClipReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 1 } }, 0);
            continue;
        };
        switch (req) {
            .register => {
                if (next_badge > max_badge) {
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 2 } }, 0);
                    continue;
                }
                const minted = usys.chanMint(chan_h, next_badge);
                if (minted.err != .ok) {
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 3 } }, 0);
                    continue;
                }
                next_badge += 1;
                _ = usys.replyTyped(shared.ClipResp, chan_h, .registered, minted.data[1]);
            },
            .attach_buf => {
                if (r.cap == 0) {
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 4 } }, 0);
                    continue;
                }
                const cm = usys.shmMap(r.cap);
                _ = usys.capDrop(r.cap);
                if (cm.err != .ok) {
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 5 } }, 0);
                    continue;
                }
                const c = clientAlloc(r.badge) orelse {
                    _ = usys.shmUnmap(cm.data[0]);
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 6 } }, 0);
                    continue;
                };
                if (c.va != 0) _ = usys.shmUnmap(c.va);
                c.va = cm.data[0];
                c.len = cm.data[1] * 4096;
                _ = usys.replyTyped(shared.ClipResp, chan_h, .ok, 0);
            },
            .set => |q| {
                const c = clientFor(r.badge);
                if (c == null or c.?.va == 0) {
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 7 } }, 0);
                    continue;
                }
                const src: [*]const u8 = @ptrFromInt(c.?.va);
                const n = @min(@min(q.len, c.?.len), clip_cap);
                @memcpy(clip[0..n], src[0..n]);
                clip_len = n;
                _ = usys.replyTyped(shared.ClipResp, chan_h, .ok, 0);
            },
            .get => {
                const c = clientFor(r.badge);
                if (c == null or c.?.va == 0) {
                    _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .clip_err = .{ .code = 8 } }, 0);
                    continue;
                }
                const dst: [*]u8 = @ptrFromInt(c.?.va);
                const n = @min(clip_len, c.?.len);
                @memcpy(dst[0..n], clip[0..n]);
                _ = usys.replyTyped(shared.ClipResp, chan_h, .{ .data = .{ .len = n } }, 0);
            },
        }
    }
}
