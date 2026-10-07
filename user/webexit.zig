//! `webexit`: a broker on another node — the other half of stage 12.
//! A durable service unit reached by name over the fabric (`dial NODE
//! "webexit"`): a window elsewhere says `hello` and from then on asks
//! this program to open and read what its pages fetch, so a tab
//! browses through this node's network, trust roots and policy (an
//! exit node is a unit file here). The window's pages never see this
//! node: bytes come back through the window as ever.
//!
//! The fabric's call limit shapes it: a fetch can stall for seconds,
//! and a remote call held that long drops the peer link, so `open` and
//! `read` start the work on the client's own worker thread and answer
//! `pending`; the window polls. Each client has a worker (the broker's
//! TLS handshake needs a deep stack), and they broker one at a time
//! under the host's lock, which is where the broker's scratch lives.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");
const netcmds = @import("netcmds.zig");
const tlscmds = @import("tlscmds.zig");
const webhost = @import("webhost.zig");
const wire = shared.web;

comptime {
    asm (usys.imageHeader("webexit"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    webhost.logf(glog, "webexit: panic: {s}", .{msg});
    usys.exit(255);
}

const max_clients = 4;
/// A client whose window stopped asking for this long is dropped.
const stale_ms: u64 = 20_000;

const State = enum(u8) { idle, opening, opened, refused, reading, chunk };
const Job = enum(u8) { none, open, read };

const Client = struct {
    used: bool = false,
    key: u64 = 0,
    twin_va: u64 = 0,
    twin_len: usize = 0,
    bell: u64 = 0,
    state: std.atomic.Value(u8) = std.atomic.Value(u8).init(0),
    job: Job = .none,
    /// The open under way: its texts copied out of the twin (the twin
    /// carries the answer).
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    body: [8192]u8 = undefined,
    body_len: usize = 0,
    origin: [512]u8 = undefined,
    origin_len: usize = 0,
    post: bool = false,
    /// A read under way: how much; its outcome.
    max: usize = 0,
    status: u64 = 0,
    code: wire.RefuseCode = .connect,
    ans_url_len: usize = 0,
    ans_ct_len: usize = 0,
    chunk_len: usize = 0,
    chunk_end: wire.ChunkEnd = .failed,
    last_ms: u64 = 0,
    broker: webhost.Client = .{},

    fn twin(c: *const Client) []u8 {
        return @as([*]u8, @ptrFromInt(c.twin_va))[0..c.twin_len];
    }
};

var glog: u64 = 0;
var net: netcmds.Net = undefined;
var host: webhost.Host = undefined;
var clients: [max_clients]Client = @splat(.{});
var worker_stacks: [max_clients][256 << 10]u8 align(16) = undefined;
var clock_stack: [16 << 10]u8 align(16) = undefined;
var next_key: u64 = 0x0e11_0e11;

fn fail(comptime why: []const u8, code: u64) noreturn {
    _ = usys.log(glog, "webexit: " ++ why);
    usys.exit(code);
}

/// A client's worker: the open or read it was given, brokered under
/// the host's lock, its outcome left for the next poll.
fn worker(idx: u64) callconv(.c) void {
    const c = &clients[idx];
    var tag_buf: [24]u8 = undefined;
    const tag = std.fmt.bufPrint(&tag_buf, "client {d}", .{idx}) catch "client";
    while (true) {
        _ = usys.notifyWait(c.bell);
        const job = c.job;
        c.job = .none;
        if (!c.used) continue;
        switch (job) {
            .none => {},
            .open => {
                host.lock.acquire();
                const out = host.brokerOpenFrom(&c.broker, c.url[0..c.url_len], c.post, c.body[0..c.body_len], c.origin[0..c.origin_len], tag);
                switch (out) {
                    .refused => |code| {
                        c.code = code;
                        host.lock.release();
                        c.state.store(@intFromEnum(State.refused), .release);
                    },
                    .opened => |op| {
                        const t = c.twin();
                        c.ans_url_len = @min(op.url.len, t.len);
                        @memcpy(t[0..c.ans_url_len], op.url[0..c.ans_url_len]);
                        c.ans_ct_len = @min(op.ct.len, t.len - c.ans_url_len);
                        @memcpy(t[c.ans_url_len .. c.ans_url_len + c.ans_ct_len], op.ct[0..c.ans_ct_len]);
                        c.status = op.status;
                        host.lock.release();
                        webhost.logf(glog, "webexit: {s}: opened {s} ({d})", .{ tag, op.url, op.status });
                        c.state.store(@intFromEnum(State.opened), .release);
                    },
                }
            },
            .read => {
                host.lock.acquire();
                const t = c.twin();
                const r = host.brokerRead(&c.broker, t[0..@min(c.max, t.len)], tag);
                host.lock.release();
                c.chunk_len = r.len;
                c.chunk_end = r.end;
                c.state.store(@intFromEnum(State.chunk), .release);
            },
        }
    }
}

/// The clock: clients whose window stopped asking are dropped.
fn clock(_: u64) callconv(.c) void {
    while (true) {
        usys.sleepMs(1000);
        const now = usys.nowMs();
        for (&clients, 0..) |*c, i| {
            if (!c.used or now - c.last_ms < stale_ms) continue;
            if (c.state.load(.acquire) == @intFromEnum(State.opening) or c.state.load(.acquire) == @intFromEnum(State.reading)) continue; // its worker holds it
            webhost.logf(glog, "webexit: client {d}: its window stopped asking; dropped", .{i});
            dropClient(c);
        }
    }
}

fn dropClient(c: *Client) void {
    host.lock.acquire();
    host.brokerCancel(&c.broker);
    host.dropParked(&c.broker);
    host.lock.release();
    if (c.twin_va != 0) _ = usys.shmUnmap(c.twin_va);
    c.* = .{ .bell = c.bell };
}

fn reply(chan: u64, rep: wire.ExitResp) void {
    _ = usys.replyTyped(wire.ExitResp, chan, rep, 0);
}

fn refuse(chan: u64, code: wire.RefuseCode) void {
    reply(chan, .{ .refused = .{ .code = @intFromEnum(code) } });
}

fn clientOf(id: u64, key: u64) ?*Client {
    if (id >= max_clients) return null;
    const c = &clients[id];
    if (!c.used or c.key != key) return null;
    c.last_ms = usys.nowMs();
    return c;
}

export fn umain(log_h: u64, chan_h: u64, _: u64, _: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.net)) fail("no network view", 161);
    net = netcmds.Net.init(setup.cap(.net));
    if (setup.has(.assets)) {
        const view = setup.cap(.assets);
        tlscmds.setRootsAssetsView(view, @ptrFromInt(fsc.attachBuf(view).va));
        tlscmds.warmRoots();
    } else _ = usys.log(glog, "webexit: no assets view: no trust roots, https will fail");
    host.reset(glog, 0, &net);
    for (&clients, 0..) |*c, i| {
        const b = usys.notifyCreate();
        if (b.err != .ok) fail("no bell", 162);
        c.bell = b.data[0];
        if (usys.threadCreate(worker, i, &worker_stacks[i]) != .ok) fail("no worker thread", 163);
    }
    if (usys.threadCreate(clock, 0, &clock_stack) != .ok) fail("no clock thread", 164);
    _ = usys.log(glog, "webexit: serving fetches for windows on other nodes");

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(wire.ExitReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            refuse(chan_h, .policy);
            continue;
        };
        if (req != .hello and r.cap != 0) _ = usys.capDrop(r.cap);
        switch (req) {
            .hello => {
                if (r.cap == 0) {
                    refuse(chan_h, .policy);
                    continue;
                }
                var slot: ?*Client = null;
                var id: u64 = 0;
                for (&clients, 0..) |*c, i| if (!c.used and slot == null) {
                    slot = c;
                    id = i;
                };
                const c = slot orelse {
                    _ = usys.capDrop(r.cap);
                    refuse(chan_h, .busy);
                    continue;
                };
                const m = usys.shmMap(r.cap);
                _ = usys.capDrop(r.cap);
                if (m.err != .ok) {
                    refuse(chan_h, .memory);
                    continue;
                }
                next_key = (next_key ^ usys.nowMs()) *% 0x9E37_79B9_7F4A_7C15 +% id;
                c.* = .{ .bell = c.bell, .used = true, .key = next_key | 1, .twin_va = m.data[0], .twin_len = @intCast(m.data[1] * 4096), .last_ms = usys.nowMs() };
                webhost.logf(glog, "webexit: client {d}: a window's fetches come through here", .{id});
                reply(chan_h, .{ .client = .{ .id = id, .key = c.key } });
            },
            .open => |o| {
                const c = clientOf(o.client, o.key) orelse {
                    refuse(chan_h, .policy);
                    continue;
                };
                const st = c.state.load(.acquire);
                if (st == @intFromEnum(State.opening) or st == @intFromEnum(State.reading)) {
                    refuse(chan_h, .busy);
                    continue;
                }
                const t = c.twin();
                if (t.len < 6) {
                    refuse(chan_h, .bad_url);
                    continue;
                }
                const ul: usize = @intCast(wire.getU16(t[0..2]));
                const bl: usize = @intCast(wire.getU16(t[2..4]));
                const ol: usize = @intCast(wire.getU16(t[4..6]));
                if (ul == 0 or ul > c.url.len or bl > c.body.len or ol > c.origin.len or 6 + ul + bl + ol > t.len) {
                    refuse(chan_h, .bad_url);
                    continue;
                }
                @memcpy(c.url[0..ul], t[6 .. 6 + ul]);
                @memcpy(c.body[0..bl], t[6 + ul .. 6 + ul + bl]);
                @memcpy(c.origin[0..ol], t[6 + ul + bl .. 6 + ul + bl + ol]);
                c.url_len = ul;
                c.body_len = bl;
                c.origin_len = ol;
                c.post = o.flags & 1 != 0;
                c.job = .open;
                c.state.store(@intFromEnum(State.opening), .release);
                _ = usys.notifySignal(c.bell, 1);
                reply(chan_h, .pending);
            },
            .read => |rd| {
                const c = clientOf(rd.client, rd.key) orelse {
                    refuse(chan_h, .policy);
                    continue;
                };
                const st = c.state.load(.acquire);
                if (st == @intFromEnum(State.opening) or st == @intFromEnum(State.reading)) {
                    refuse(chan_h, .busy);
                    continue;
                }
                c.max = @intCast(@min(rd.max, c.twin_len));
                c.job = .read;
                c.state.store(@intFromEnum(State.reading), .release);
                _ = usys.notifySignal(c.bell, 1);
                reply(chan_h, .pending);
            },
            .poll => |pl| {
                const c = clientOf(pl.client, pl.key) orelse {
                    refuse(chan_h, .policy);
                    continue;
                };
                switch (std.enums.fromInt(State, c.state.load(.acquire)) orelse .idle) {
                    .idle => reply(chan_h, .ok),
                    .opening, .reading => reply(chan_h, .pending),
                    .opened => {
                        c.state.store(@intFromEnum(State.idle), .release);
                        reply(chan_h, .{ .opened = .{ .status = c.status, .url_len = c.ans_url_len, .type_len = c.ans_ct_len } });
                    },
                    .refused => {
                        c.state.store(@intFromEnum(State.idle), .release);
                        refuse(chan_h, c.code);
                    },
                    .chunk => {
                        c.state.store(@intFromEnum(State.idle), .release);
                        reply(chan_h, .{ .chunk = .{ .len = c.chunk_len, .done = @intFromEnum(c.chunk_end) } });
                    },
                }
            },
            .cancel => |cn| {
                const c = clientOf(cn.client, cn.key) orelse {
                    refuse(chan_h, .policy);
                    continue;
                };
                const st = c.state.load(.acquire);
                if (st != @intFromEnum(State.opening) and st != @intFromEnum(State.reading)) {
                    host.lock.acquire();
                    host.brokerCancel(&c.broker);
                    host.lock.release();
                    c.state.store(@intFromEnum(State.idle), .release);
                }
                reply(chan_h, .ok);
            },
            .bye => |b| {
                if (clientOf(b.client, b.key)) |c| {
                    const st = c.state.load(.acquire);
                    if (st != @intFromEnum(State.opening) and st != @intFromEnum(State.reading)) {
                        dropClient(c);
                        webhost.logf(glog, "webexit: client {d}: gone", .{b.client});
                    } else c.last_ms = 0; // the clock drops it once its worker is done
                }
                reply(chan_h, .ok);
            },
        }
    }
}
