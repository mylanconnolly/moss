//! The network commands an mshl host offers when it holds a network
//! view: sockets as values. `connect ADDR PORT` and `listen PORT` make
//! handles; `accept`, `send`, `recv`, `close` and `status` take them.
//! Datagrams: `udp-bind PORT` (0: any) makes a `udp` handle,
//! `udp-send $u ADDR PORT DATA` sends one, `udp-recv $u` answers the
//! next as `{ from, port, data }`; `close` takes those too.
//! A handle nobody keeps is closed by the interpreter's reclaim, and a
//! bound one when its last binding goes — the capability drops at the
//! last use, and netsvc sees the close. Every command that can fail by
//! the network's doing answers a result (`ok v` / `err reason`) rather
//! than failing the line: the network is the first host surface built
//! the way the language decisions say.
//!
//! Waiting is by doorbell: one notification the host hands netsvc as
//! every socket's bell (`watch`), slept on between tries. netsvc rings
//! it on any change — data, a connection to accept, the peer closing,
//! a retransmission giving up — so a wait costs nothing while nothing
//! happens and ends the moment something does.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const syscmds = @import("syscmds.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;

pub const Net = struct {
    chan: u64,
    buf: [*]u8 = undefined,
    attached: bool = false,
    /// The doorbell every socket of this host rings.
    bell: u64 = 0,

    pub fn init(chan: u64) Net {
        return .{ .chan = chan };
    }

    pub fn attach(n: *Net) bool {
        if (n.attached) return true;
        const s = usys.shmCreate(shared.net_buf_pages);
        if (s.err != .ok) return false;
        const m = usys.shmMap(s.data[0]);
        if (m.err != .ok) return false;
        n.buf = @ptrFromInt(m.data[0]);
        switch (usys.callTyped(shared.NetReq, shared.NetResp, n.chan, .attach_buf, s.data[0])) {
            .ok => |rep| if (rep != .ok) return false,
            .err => return false,
        }
        const b = usys.notifyCreate();
        if (b.err != .ok) return false;
        n.bell = b.data[0];
        n.attached = true;
        return true;
    }

    /// Hang the bell on a socket, then sleep on it whenever an operation
    /// answers would_block.
    pub fn watch(n: *Net, sock: u64) void {
        _ = usys.callTyped(shared.NetReq, shared.NetResp, n.chan, .{ .watch = .{ .sock = sock } }, n.bell);
    }

    pub fn wait(n: *Net) void {
        _ = usys.notifyWait(n.bell);
    }

    // Raw operations for other host surfaces (HTTP): sockets by number,
    // waiting on the bell, outcomes as the protocol's errors.

    pub const Outcome = union(enum) { sock: u64, failed: []const u8 };

    /// Connect and wait for the handshake, as long as the stack tries.
    pub fn connectRaw(n: *Net, words: [2]u64, port: u64) Outcome {
        return n.connectRawFor(words, port, null);
    }

    /// Connect, waiting at most `ticks` for the handshake (null: until
    /// the stack gives up); a timeout answers "timed_out" and the
    /// attempt is closed.
    pub fn connectRawFor(n: *Net, words: [2]u64, port: u64, ticks: ?u64) Outcome {
        if (!n.attach()) return .{ .failed = "cannot attach a buffer to the network view" };
        const rep = ncall(n, .{ .tcp_connect = .{ .ip_hi = words[0], .ip_lo = words[1], .port = port } }) orelse return .{ .failed = "the network service did not answer" };
        const sock = switch (rep) {
            .num => |x| x.n,
            .net_err => |e| return .{ .failed = errName(e.code) },
            .ok => return .{ .failed = "unexpected reply" },
        };
        n.watch(sock);
        const bit_timeout: u64 = 2;
        const start = syscmds.nowMs();
        if (ticks) |t| _ = usys.timerArm(n.bell, t, bit_timeout);
        defer if (ticks != null) {
            _ = usys.timerArm(n.bell, 0, bit_timeout);
        };
        var why: []const u8 = "refused";
        while (true) {
            const st = ncall(n, .{ .tcp_status = .{ .sock = sock } }) orelse break;
            const code = switch (st) {
                .num => |x| x.n,
                else => break,
            };
            // Established, or already past it: a peer that answered and
            // closed before this poll (close_wait) is a connection too.
            if (code == @intFromEnum(shared.TcpState.established) or code == @intFromEnum(shared.TcpState.close_wait)) return .{ .sock = sock };
            if (code == @intFromEnum(shared.TcpState.closed)) break;
            const w = usys.notifyWait(n.bell);
            if (ticks) |t| {
                if (w.err == .ok and (w.data[0] & bit_timeout) != 0 and syscmds.nowMs() - start >= @as(i64, @intCast(t * 10))) {
                    why = "timed_out";
                    break;
                }
            }
        }
        _ = ncall(n, .{ .tcp_close = .{ .sock = sock } });
        return .{ .failed = why };
    }

    /// Wait for a connection on a listener.
    pub fn acceptRaw(n: *Net, l: u64) Outcome {
        while (true) {
            const rep = ncall(n, .{ .tcp_accept = .{ .sock = l } }) orelse return .{ .failed = "the network service did not answer" };
            switch (rep) {
                .num => |x| {
                    n.watch(x.n);
                    return .{ .sock = x.n };
                },
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return .{ .failed = errName(e.code) },
                .ok => {},
            }
            n.wait();
        }
    }

    /// Send everything, waiting for room; null on success.
    pub fn sendAll(n: *Net, s: u64, data: []const u8) ?[]const u8 {
        var off: usize = 0;
        while (off < data.len) {
            const len = @min(piece, data.len - off);
            @memcpy(n.buf[0..len], data[off .. off + len]);
            const rep = ncall(n, .{ .tcp_send = .{ .sock = s, .len = len } }) orelse return "the network service did not answer";
            switch (rep) {
                .num => |x| off += x.n,
                .net_err => |e| {
                    if (e.code != @intFromEnum(shared.NetErr.would_block)) return errName(e.code);
                    n.wait();
                },
                .ok => {},
            }
        }
        return null;
    }

    pub const Recv = union(enum) { data: []const u8, closed, failed: []const u8 };

    /// Wait for data; what arrives lives in the view buffer until the
    /// next operation, so copy it out.
    pub fn recvSome(n: *Net, s: u64) Recv {
        while (true) {
            const rep = ncall(n, .{ .tcp_recv = .{ .sock = s, .len = shared.net_max_recv } }) orelse return .{ .failed = "the network service did not answer" };
            switch (rep) {
                .num => |x| return .{ .data = n.buf[0..x.n] },
                .net_err => |e| {
                    if (e.code == @intFromEnum(shared.NetErr.closed)) return .closed;
                    if (e.code != @intFromEnum(shared.NetErr.would_block)) return .{ .failed = errName(e.code) };
                },
                .ok => {},
            }
            n.wait();
        }
    }

    pub const RecvFor = union(enum) { data: []const u8, closed, failed: []const u8, timeout };

    /// Like recvSome, giving up after `ticks` (10 ms each) with nothing
    /// received: a kernel timer rings the bell with a bit of its own.
    /// The bit may still be latched from an earlier arming, so a wake
    /// counts as the timeout only once the clock agrees.
    pub fn recvSomeFor(n: *Net, s: u64, ticks: u64) RecvFor {
        const bit_timeout: u64 = 2; // netsvc rings bit 1
        if (usys.timerArm(n.bell, ticks, bit_timeout) != .ok) return .{ .failed = "no timer for the network view" };
        defer _ = usys.timerArm(n.bell, 0, bit_timeout);
        const start = syscmds.nowMs();
        const limit_ms: i64 = @intCast(ticks * 10);
        while (true) {
            const rep = ncall(n, .{ .tcp_recv = .{ .sock = s, .len = shared.net_max_recv } }) orelse return .{ .failed = "the network service did not answer" };
            switch (rep) {
                .num => |x| return .{ .data = n.buf[0..x.n] },
                .net_err => |e| {
                    if (e.code == @intFromEnum(shared.NetErr.closed)) return .closed;
                    if (e.code != @intFromEnum(shared.NetErr.would_block)) return .{ .failed = errName(e.code) };
                },
                .ok => {},
            }
            const w = usys.notifyWait(n.bell);
            if (w.err == .ok and (w.data[0] & bit_timeout) != 0 and syscmds.nowMs() - start >= limit_ms) return .timeout;
        }
    }

    pub fn closeRaw(n: *Net, s: u64) void {
        _ = ncall(n, .{ .tcp_close = .{ .sock = s } });
    }

    // Datagrams, raw.

    pub fn udpBindRaw(n: *Net, port: u64) Outcome {
        if (!n.attach()) return .{ .failed = "cannot attach a buffer to the network view" };
        const rep = ncall(n, .{ .udp_bind = .{ .port = port } }) orelse return .{ .failed = "the network service did not answer" };
        return switch (rep) {
            .num => |x| blk: {
                n.watch(x.n);
                break :blk .{ .sock = x.n };
            },
            .net_err => |e| .{ .failed = errName(e.code) },
            .ok => .{ .failed = "unexpected reply" },
        };
    }

    /// Send one datagram; null on success, else the reason.
    pub fn udpSendRaw(n: *Net, s: u64, to: [2]u64, port: u64, data: []const u8) ?[]const u8 {
        if (data.len > shared.udp_max) return "a datagram is at most 1452 bytes";
        putWords(n.buf[0..16], to);
        @memcpy(n.buf[shared.udp_hdr .. shared.udp_hdr + data.len], data);
        const rep = ncall(n, .{ .udp_send = .{ .sock = s, .port = port, .len = data.len } }) orelse return "the network service did not answer";
        return switch (rep) {
            .num => null,
            .net_err => |e| errName(e.code),
            .ok => "unexpected reply",
        };
    }

    pub const Dgram = struct { from: [2]u64, port: u64, data: []const u8 };
    pub const RecvDgram = union(enum) { datagram: Dgram, failed: []const u8 };

    /// Wait for the next datagram; its bytes live in the view buffer
    /// until the next operation.
    pub fn udpRecvRaw(n: *Net, s: u64) RecvDgram {
        while (true) {
            const rep = ncall(n, .{ .udp_recv = .{ .sock = s, .len = shared.udp_max } }) orelse return .{ .failed = "the network service did not answer" };
            switch (rep) {
                .num => |x| return .{ .datagram = .{
                    .from = getWords(n.buf[0..16]),
                    .port = (@as(u64, n.buf[16]) << 8) | n.buf[17],
                    .data = n.buf[shared.udp_hdr .. shared.udp_hdr + x.n],
                } },
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return .{ .failed = errName(e.code) },
                .ok => {},
            }
            n.wait();
        }
    }

    // Names.

    pub const Resolved = struct { words: [shared.resolve_max][2]u64 = undefined, n: usize = 0, ttl: u32 = 0 };
    pub const ResolveOut = union(enum) { addresses: Resolved, failed: []const u8 };

    /// The addresses of a name, through the service's resolver.
    pub fn resolveRaw(n: *Net, name: []const u8) ResolveOut {
        if (!n.attach()) return .{ .failed = "cannot attach a buffer to the network view" };
        if (name.len == 0 or name.len > 255) return .{ .failed = "bad" };
        @memcpy(n.buf[0..name.len], name);
        const started = ncall(n, .{ .resolve = .{ .len = name.len } }) orelse return .{ .failed = "the network service did not answer" };
        const id = switch (started) {
            .num => |x| x.n,
            .net_err => |e| return .{ .failed = errName(e.code) },
            .ok => return .{ .failed = "unexpected reply" },
        };
        n.watch(id);
        while (true) {
            const rep = ncall(n, .{ .resolve_check = .{ .lookup = id } }) orelse return .{ .failed = "the network service did not answer" };
            switch (rep) {
                .num => |x| {
                    var out = Resolved{ .n = @min(x.n, shared.resolve_max) };
                    for (0..out.n) |i| out.words[i] = getWords(n.buf[i * 16 .. i * 16 + 16]);
                    const t = n.buf[x.n * 16 .. x.n * 16 + 4];
                    out.ttl = (@as(u32, t[0]) << 24) | (@as(u32, t[1]) << 16) | (@as(u32, t[2]) << 8) | t[3];
                    return .{ .addresses = out };
                },
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return .{ .failed = errName(e.code) },
                .ok => {},
            }
            n.wait();
        }
    }

    /// An address, or a name resolved to its addresses.
    pub fn addressesOf(n: *Net, text: []const u8) ResolveOut {
        if (shared.parseAddr(text)) |w| {
            var out = Resolved{ .n = 1 };
            out.words[0] = w;
            return .{ .addresses = out };
        }
        return n.resolveRaw(text);
    }

    /// How long one address of several gets before the next is tried
    /// (a route that is not there — IPv6 behind slirp — would otherwise
    /// cost the stack's whole retransmission run per address).
    pub const attempt_ticks: u64 = 150;

    /// Connect to a host given as an address or a name, trying each
    /// address in turn — a bounded attempt each while others remain,
    /// the last as long as the stack tries.
    pub fn connectHost(n: *Net, host: []const u8, port: u64) Outcome {
        const r = switch (n.addressesOf(host)) {
            .addresses => |x| x,
            .failed => |m| return .{ .failed = m },
        };
        var last: []const u8 = "refused";
        for (r.words[0..r.n], 0..) |w, i| {
            const bounded = i + 1 < r.n;
            switch (n.connectRawFor(w, port, if (bounded) attempt_ticks else null)) {
                .sock => |s| return .{ .sock = s },
                .failed => |m| last = m,
            }
        }
        return .{ .failed = last };
    }
};

fn putWords(out: []u8, w: [2]u64) void {
    for (0..8) |i| out[i] = @truncate(w[0] >> @intCast((7 - i) * 8));
    for (0..8) |i| out[8 + i] = @truncate(w[1] >> @intCast((7 - i) * 8));
}

fn getWords(b: []const u8) [2]u64 {
    var w: [2]u64 = .{ 0, 0 };
    for (0..8) |i| w[0] |= @as(u64, b[i]) << @intCast((7 - i) * 8);
    for (0..8) |i| w[1] |= @as(u64, b[8 + i]) << @intCast((7 - i) * 8);
    return w;
}

const piece = shared.net_max_send;

fn ncall(n: *Net, req: shared.NetReq) ?shared.NetResp {
    return switch (usys.callTyped(shared.NetReq, shared.NetResp, n.chan, req, 0)) {
        .ok => |rep| rep,
        .err => null,
    };
}

/// The protocol's error, as the word a script matches on.
fn errName(code: u64) []const u8 {
    const e = std.enums.fromInt(shared.NetErr, code) orelse return "error";
    return @tagName(e);
}

/// A socket's state, as `status` answers it.
pub const SockState = enum { closed, listening, connecting, handshaking, established, peer_closed, bound };

/// What `udp-recv` answers.
pub const Datagram = struct { from: []const u8, port: i64, data: mshl.Value };

fn stateName(st: u64) []const u8 {
    const state: SockState = switch (st) {
        @intFromEnum(shared.TcpState.closed) => .closed,
        @intFromEnum(shared.TcpState.listen) => .listening,
        @intFromEnum(shared.TcpState.syn_sent) => .connecting,
        @intFromEnum(shared.TcpState.syn_rcvd) => .handshaking,
        @intFromEnum(shared.TcpState.established) => .established,
        @intFromEnum(shared.TcpState.close_wait) => .peer_closed,
        else => .closed,
    };
    return @tagName(state);
}

// ---------------------------------------------------------- signatures

const Shape = mshl.Shape;
const net_err = blk: {
    const alts = [_]Shape{ mshl.shapeOf(shared.NetErr), .{ .word = "error" } };
    break :blk Shape{ .one_of = &alts };
};
const socket: Shape = .{ .kind = "socket" };
const listener: Shape = .{ .kind = "listener" };
const sock_result = mshl.resultShape(socket, net_err);
const listener_result = mshl.resultShape(listener, net_err);
const sent_result = mshl.resultShape(.int, net_err);
const recv_result = mshl.resultShape(.bytes, net_err);
const data_shape = blk: {
    const alts = [_]Shape{ .string, .bytes };
    break :blk Shape{ .one_of = &alts };
};
const any_handle_state = mshl.shapeOf(SockState);
const udp: Shape = .{ .kind = "udp" };
const udp_result = mshl.resultShape(udp, net_err);
const datagram_shape = blk: {
    const fields = [_]Shape.Field{ .{ .key = "from", .shape = .string }, .{ .key = "port", .shape = .int }, .{ .key = "data", .shape = .bytes } };
    break :blk Shape{ .record_of = &fields };
};
const datagram_result = mshl.resultShape(datagram_shape, net_err);
const addresses_result = mshl.resultShape(.{ .list_of = &.string }, net_err);

pub fn signature(name: []const u8) ?mshl.Signature {
    const is = std.mem.eql;
    if (is(u8, name, "connect")) return .{ .params = &.{ .{ .name = "host", .shape = .string }, .{ .name = "port", .shape = .int } }, .ret = sock_result };
    if (is(u8, name, "resolve")) return .{ .params = &.{.{ .name = "name", .shape = .string }}, .ret = addresses_result };
    if (is(u8, name, "listen")) return .{ .params = &.{.{ .name = "port", .shape = .int }}, .ret = listener_result };
    if (is(u8, name, "accept")) return .{ .params = &.{.{ .name = "listener", .shape = listener, .optional = true }}, .input = .{ .optional = listener }, .ret = sock_result };
    if (is(u8, name, "send")) return .{ .params = &.{ .{ .name = "socket", .shape = socket }, .{ .name = "data", .shape = data_shape } }, .ret = sent_result };
    if (is(u8, name, "recv")) return .{ .params = &.{ .{ .name = "socket", .shape = socket, .optional = true }, .{ .name = "max", .shape = .int, .optional = true } }, .input = .{ .optional = socket }, .ret = recv_result };
    if (is(u8, name, "close")) return .{ .params = &.{.{ .name = "handle", .shape = .handle, .optional = true }}, .input = .{ .optional = .handle }, .ret = .nothing };
    if (is(u8, name, "status")) return .{ .params = &.{.{ .name = "handle", .shape = .handle, .optional = true }}, .input = .{ .optional = .handle }, .ret = any_handle_state };
    if (is(u8, name, "udp-bind")) return .{ .params = &.{.{ .name = "port", .shape = .int }}, .ret = udp_result };
    if (is(u8, name, "udp-send")) return .{ .params = &.{ .{ .name = "socket", .shape = udp }, .{ .name = "addr", .shape = .string }, .{ .name = "port", .shape = .int }, .{ .name = "data", .shape = data_shape } }, .ret = sent_result };
    if (is(u8, name, "udp-recv")) return .{ .params = &.{.{ .name = "socket", .shape = udp, .optional = true }}, .input = .{ .optional = udp }, .ret = datagram_result };
    return null;
}

pub fn dropSock(ctx: *anyopaque, _: []const u8, id: u64) void {
    const n: *Net = @ptrCast(@alignCast(ctx));
    _ = ncall(n, .{ .tcp_close = .{ .sock = id } });
}

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = false, .val = .{ .str = msg } };
    return .{ .result = r };
}

fn okResult(it: *mshl.Interp, v: Value) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = true, .val = v };
    return .{ .result = r };
}

pub fn sockArg(it: *mshl.Interp, v: Value, cmd: []const u8, kind: []const u8) mshl.Error!u64 {
    if (v != .handle or !std.mem.eql(u8, v.handle.kind, kind)) return it.fail("{s}: a {s} expected, got a {s}", .{ cmd, kind, v.typeName() });
    if (v.handle.closed) return it.fail("{s}: the {s} is closed", .{ cmd, kind });
    return v.handle.id;
}

fn portArg(it: *mshl.Interp, v: Value, cmd: []const u8) mshl.Error!u64 {
    if (v != .int or v.int < 1 or v.int > 65535) return it.fail("{s}: a port (1-65535) expected", .{cmd});
    return @intCast(v.int);
}

/// null = not a network command.
pub fn call(n: *Net, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "connect")) {
        // An address, or a name the service resolves: each address is
        // tried in turn until one answers.
        const port = try portArg(it, args[1], "connect");
        if (!n.attach()) return it.fail("connect: cannot attach a buffer to the network view", .{});
        return switch (n.connectHost(args[0].str, port)) {
            .sock => |s| try okResult(it, try it.newHandle("socket", s, n, dropSock)),
            .failed => |m| try errResult(it, m),
        };
    }
    if (is(u8, name, "resolve")) {
        return switch (n.resolveRaw(args[0].str)) {
            .addresses => |r| blk: {
                const list = try it.arena.alloc(Value, r.n);
                for (r.words[0..r.n], 0..) |w, i| {
                    var text: [40]u8 = undefined;
                    list[i] = .{ .str = try it.arena.dupe(u8, shared.formatAddr(&text, w)) };
                }
                break :blk try okResult(it, .{ .list = list });
            },
            .failed => |m| try errResult(it, m),
        };
    }
    if (is(u8, name, "listen")) {
        if (args.len != 1) return it.fail("listen: PORT expected", .{});
        const port = try portArg(it, args[0], "listen");
        if (!n.attach()) return it.fail("listen: cannot attach a buffer to the network view", .{});
        const rep = ncall(n, .{ .tcp_listen = .{ .port = port } }) orelse return it.fail("listen: the network service did not answer", .{});
        return switch (rep) {
            .num => |x| blk: {
                n.watch(x.n);
                break :blk try okResult(it, try it.newHandle("listener", x.n, n, dropSock));
            },
            .net_err => |e| try errResult(it, errName(e.code)),
            .ok => it.fail("listen: unexpected reply", .{}),
        };
    }
    if (is(u8, name, "accept")) {
        const lv = input orelse (if (args.len > 0) args[0] else return it.fail("accept: a listener expected", .{}));
        const l = try sockArg(it, lv, "accept", "listener");
        while (true) {
            const rep = ncall(n, .{ .tcp_accept = .{ .sock = l } }) orelse return it.fail("accept: the network service did not answer", .{});
            switch (rep) {
                .num => |x| {
                    n.watch(x.n);
                    return try okResult(it, try it.newHandle("socket", x.n, n, dropSock));
                },
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return try errResult(it, errName(e.code)),
                .ok => {},
            }
            n.wait();
        }
    }
    if (is(u8, name, "send")) {
        if (args.len != 2) return it.fail("send: SOCKET DATA expected", .{});
        const s = try sockArg(it, args[0], "send", "socket");
        const data: []const u8 = switch (args[1]) {
            .str => |t| t,
            .bytes => |b| b,
            else => return it.fail("send: a string or bytes expected, got a {s}", .{args[1].typeName()}),
        };
        var off: usize = 0;
        while (off < data.len) {
            const len = @min(piece, data.len - off);
            @memcpy(n.buf[0..len], data[off .. off + len]);
            const rep = ncall(n, .{ .tcp_send = .{ .sock = s, .len = len } }) orelse return it.fail("send: the network service did not answer", .{});
            switch (rep) {
                .num => |x| off += x.n,
                .net_err => |e| {
                    if (e.code != @intFromEnum(shared.NetErr.would_block)) return try errResult(it, errName(e.code));
                    n.wait(); // the bell rings when an ACK frees room
                },
                .ok => {},
            }
        }
        return try okResult(it, .{ .int = @intCast(off) });
    }
    if (is(u8, name, "recv")) {
        const sv = input orelse (if (args.len > 0) args[0] else return it.fail("recv: a socket expected", .{}));
        const s = try sockArg(it, sv, "recv", "socket");
        const max: u64 = if (args.len > 1 and args[1] == .int and args[1].int > 0) @min(@as(u64, @intCast(args[1].int)), shared.net_max_recv) else shared.net_max_recv;
        while (true) {
            const rep = ncall(n, .{ .tcp_recv = .{ .sock = s, .len = max } }) orelse return it.fail("recv: the network service did not answer", .{});
            switch (rep) {
                .num => |x| return try okResult(it, .{ .bytes = try it.arena.dupe(u8, n.buf[0..x.n]) }),
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return try errResult(it, errName(e.code)),
                .ok => {},
            }
            n.wait();
        }
    }
    if (is(u8, name, "udp-bind")) {
        const port = args[0].int;
        if (port < 0 or port > 65535) return it.fail("udp-bind: a port (0-65535) expected", .{});
        return switch (n.udpBindRaw(@intCast(port))) {
            .sock => |u| try okResult(it, try it.newHandle("udp", u, n, dropSock)),
            .failed => |m| try errResult(it, m),
        };
    }
    if (is(u8, name, "udp-send")) {
        const u = try sockArg(it, args[0], "udp-send", "udp");
        const port = try portArg(it, args[2], "udp-send");
        const data: []const u8 = switch (args[3]) {
            .str => |t| t,
            .bytes => |b| b,
            else => unreachable,
        };
        if (data.len > shared.udp_max) return it.fail("udp-send: a datagram is at most {d} bytes", .{shared.udp_max});
        const to = switch (n.addressesOf(args[1].str)) {
            .addresses => |r| r.words[0],
            .failed => |m| return try errResult(it, m),
        };
        if (n.udpSendRaw(u, to, port, data)) |m| return try errResult(it, m);
        return try okResult(it, .{ .int = @intCast(data.len) });
    }
    if (is(u8, name, "udp-recv")) {
        const uv = input orelse (if (args.len > 0) args[0] else return it.fail("udp-recv: a udp socket expected", .{}));
        const u = try sockArg(it, uv, "udp-recv", "udp");
        return switch (n.udpRecvRaw(u)) {
            .datagram => |d| blk: {
                var text: [40]u8 = undefined;
                const from = try it.arena.dupe(u8, shared.formatAddr(&text, d.from));
                const data = try it.arena.dupe(u8, d.data);
                break :blk try okResult(it, try mshl.toValue(it.arena, Datagram{ .from = from, .port = @intCast(d.port), .data = .{ .bytes = data } }));
            },
            .failed => |m| try errResult(it, m),
        };
    }
    if (is(u8, name, "close")) {
        const sv = input orelse (if (args.len > 0) args[0] else return it.fail("close: a socket or listener expected", .{}));
        if (sv != .handle) return it.fail("close: a socket or listener expected, got a {s}", .{sv.typeName()});
        if (!sv.handle.closed) {
            _ = ncall(n, .{ .tcp_close = .{ .sock = sv.handle.id } });
            it.closeHandle(sv);
        }
        return .nothing;
    }
    if (is(u8, name, "status")) {
        const sv = input orelse (if (args.len > 0) args[0] else return it.fail("status: a socket expected", .{}));
        if (sv != .handle) return it.fail("status: a socket or listener expected, got a {s}", .{sv.typeName()});
        if (sv.handle.closed) return .{ .str = "closed" };
        if (std.mem.eql(u8, sv.handle.kind, "udp")) return .{ .str = "bound" };
        const rep = ncall(n, .{ .tcp_status = .{ .sock = sv.handle.id } }) orelse return it.fail("status: the network service did not answer", .{});
        return switch (rep) {
            .num => |x| .{ .str = stateName(x.n) },
            else => .{ .str = "closed" },
        };
    }
    return null;
}

pub const command_names = [_][]const u8{ "connect", "listen", "accept", "send", "recv", "close", "status", "udp-bind", "udp-send", "udp-recv", "resolve" };
