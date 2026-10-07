//! `webnode`: a node that hosts web pages for windows elsewhere (stage
//! 12 of the browser arc). A durable service unit reached by name over
//! the fabric (`dial NODE "webnode"`): a window on another node says
//! `hello`, this program spawns a page domain here — the `webpage`
//! image from the boot archive, the fonts from this node's assets — and
//! serves it in the host's relay mode. The window polls (`pump`): its
//! commands and the bytes its broker fetched come down in the session
//! buffer, and the page's events, its fetch and storage requests and
//! the viewport rows it repainted go back up. The page holds one
//! channel to this program and nothing else; this program holds no
//! network: what the page fetches is the window's broker's, on the
//! window's node — a heavy site rendered where the memory is, through
//! the network and the policy of the one who opened it.
//!
//! Three threads: the main one answers the windows (never parks: a
//! remote call held long drops the peer link), the serving one serves
//! the pages (`host.step`), and a clock destroys pages whose window
//! stopped polling.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");
const netcmds = @import("netcmds.zig");
const loader = @import("loader.zig");
const webhost = @import("webhost.zig");
const wire = shared.web;

comptime {
    asm (usys.imageHeader("webnode"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    webhost.logf(glog, "webnode: panic: {s}", .{msg});
    usys.exit(255);
}

var glog: u64 = 0;
/// No network here: the host's broker is never called in relay mode.
var net: netcmds.Net = undefined;
var host: webhost.Host = undefined;
var stage: loader.Stage = undefined;
var serve_stack: [256 << 10]u8 align(16) = undefined;
var clock_stack: [16 << 10]u8 align(16) = undefined;

fn fail(comptime why: []const u8, code: u64) noreturn {
    _ = usys.log(glog, "webnode: " ++ why);
    usys.exit(code);
}

/// The serving thread: every message a page sends, forever. Relay mode
/// records what the window must hear; a death is logged here.
fn serve(_: u64) callconv(.c) void {
    while (true) {
        switch (host.step()) {
            .idle, .failed => usys.sleepMs(20),
            .dead => |id| webhost.logf(glog, "webnode: page {d} died", .{id}),
            else => {},
        }
    }
}

/// The clock: a page whose window stopped polling is destroyed.
fn clock(_: u64) callconv(.c) void {
    while (true) {
        usys.sleepMs(1000);
        _ = host.relayStale();
    }
}

fn reply(chan: u64, rep: wire.RelayResp) void {
    _ = usys.replyTyped(wire.RelayResp, chan, rep, 0);
}

fn refuse(chan: u64, code: wire.RelayRefuse) void {
    reply(chan, .{ .refused = .{ .code = @intFromEnum(code) } });
}

export fn umain(log_h: u64, chan_h: u64, _: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    // The spawner is slot 2 (log, channel, then the grants in order).
    const slot2: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });
    if ((usys.capKind(slot2) orelse .none) != .spawner) fail("no spawner", 161);
    stage = loader.Stage.init(loader.Stage.default_pages) orelse fail("no stage", 162);
    if (!stage.load(blob_va, blob_len, .webpage)) {
        webhost.logf(glog, "webnode: webpage image: {s}", .{loader.Stage.last_refusal});
        fail("the page image did not stage", 163);
    }
    net = netcmds.Net.init(0);
    host.reset(glog, slot2, &net);
    host.relay = true;
    if (!host.init()) fail("no channel for the pages", 164);
    if (setup.has(.assets)) {
        const view = setup.cap(.assets);
        const buf: [*]u8 = @ptrFromInt(fsc.attachBuf(view).va);
        if (host.loadFontsFrom(view, buf, "")) _ = usys.log(glog, "webnode: fonts packed for the pages") else _ = usys.log(glog, "webnode: no fonts; pages lay out with cells");
    } else _ = usys.log(glog, "webnode: no assets view; pages lay out with cells");
    if (usys.threadCreate(serve, 0, &serve_stack) != .ok) fail("no serving thread", 165);
    if (usys.threadCreate(clock, 0, &clock_stack) != .ok) fail("no clock thread", 166);
    _ = usys.log(glog, "webnode: serving pages for windows on other nodes");

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(wire.RelayReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            refuse(chan_h, .unknown);
            continue;
        };
        switch (req) {
            .hello => |hl| {
                if (r.cap == 0) {
                    refuse(chan_h, .unknown);
                    continue;
                }
                const w: u32 = @intCast(@min(hl.w, 8192));
                const h: u32 = @intCast(@min(hl.h, 8192));
                const id = host.spawn(stage.handle, w, h) orelse {
                    _ = usys.capDrop(r.cap);
                    refuse(chan_h, .spawn);
                    continue;
                };
                const key = host.relayAttach(id, r.cap) orelse {
                    host.destroy(id);
                    refuse(chan_h, .memory);
                    continue;
                };
                webhost.logf(glog, "webnode: page {d} spawned for a window ({d}x{d})", .{ id, w, h });
                reply(chan_h, .{ .page = .{ .id = id, .key = key } });
            },
            .pump => |pm| {
                if (r.cap != 0) _ = usys.capDrop(r.cap);
                if (pm.page >= webhost.max_pages) {
                    refuse(chan_h, .unknown);
                    continue;
                }
                const out = host.relayPump(@intCast(pm.page), pm.key, pm.len) orelse {
                    refuse(chan_h, .unknown);
                    continue;
                };
                reply(chan_h, .{ .out = .{ .len = out.len, .more = if (out.more) 1 else 0 } });
            },
            .bye => |b| {
                if (r.cap != 0) _ = usys.capDrop(r.cap);
                if (b.page < webhost.max_pages and host.relayBye(@intCast(b.page), b.key)) webhost.logf(glog, "webnode: page {d} closed by its window", .{b.page});
                reply(chan_h, .{ .out = .{ .len = 0, .more = 0 } });
            },
        }
    }
}
