//! The network commands an mshl host offers when it holds a network
//! view: sockets as values. `connect ADDR PORT` and `listen PORT` make
//! handles; `accept`, `send`, `recv`, `close` and `status` take them.
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

    /// Connect and wait for the handshake.
    pub fn connectRaw(n: *Net, words: [2]u64, port: u64) Outcome {
        if (!n.attach()) return .{ .failed = "cannot attach a buffer to the network view" };
        const rep = ncall(n, .{ .tcp_connect = .{ .ip_hi = words[0], .ip_lo = words[1], .port = port } }) orelse return .{ .failed = "the network service did not answer" };
        const sock = switch (rep) {
            .num => |x| x.n,
            .net_err => |e| return .{ .failed = errName(e.code) },
            .ok => return .{ .failed = "unexpected reply" },
        };
        n.watch(sock);
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
            n.wait();
        }
        _ = ncall(n, .{ .tcp_close = .{ .sock = sock } });
        return .{ .failed = "refused" };
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
};

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
pub const SockState = enum { closed, listening, connecting, handshaking, established, peer_closed };

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

pub fn signature(name: []const u8) ?mshl.Signature {
    const is = std.mem.eql;
    if (is(u8, name, "connect")) return .{ .params = &.{ .{ .name = "addr", .shape = .string }, .{ .name = "port", .shape = .int } }, .ret = sock_result };
    if (is(u8, name, "listen")) return .{ .params = &.{.{ .name = "port", .shape = .int }}, .ret = listener_result };
    if (is(u8, name, "accept")) return .{ .params = &.{.{ .name = "listener", .shape = listener, .optional = true }}, .input = .{ .optional = listener }, .ret = sock_result };
    if (is(u8, name, "send")) return .{ .params = &.{ .{ .name = "socket", .shape = socket }, .{ .name = "data", .shape = data_shape } }, .ret = sent_result };
    if (is(u8, name, "recv")) return .{ .params = &.{ .{ .name = "socket", .shape = socket, .optional = true }, .{ .name = "max", .shape = .int, .optional = true } }, .input = .{ .optional = socket }, .ret = recv_result };
    if (is(u8, name, "close")) return .{ .params = &.{.{ .name = "handle", .shape = .handle, .optional = true }}, .input = .{ .optional = .handle }, .ret = .nothing };
    if (is(u8, name, "status")) return .{ .params = &.{.{ .name = "handle", .shape = .handle, .optional = true }}, .input = .{ .optional = .handle }, .ret = any_handle_state };
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
        if (args.len != 2 or args[0] != .str) return it.fail("connect: ADDR PORT expected", .{});
        const words = shared.parseAddr(args[0].str) orelse return it.fail("connect: not an address: {s}", .{args[0].str});
        const port = try portArg(it, args[1], "connect");
        if (!n.attach()) return it.fail("connect: cannot attach a buffer to the network view", .{});
        const rep = ncall(n, .{ .tcp_connect = .{ .ip_hi = words[0], .ip_lo = words[1], .port = port } }) orelse return it.fail("connect: the network service did not answer", .{});
        const sock = switch (rep) {
            .num => |x| x.n,
            .net_err => |e| return try errResult(it, errName(e.code)),
            .ok => return it.fail("connect: unexpected reply", .{}),
        };
        // The handshake: established, or closed (refused, or the SYN
        // retransmits gave up — netsvc rings the bell either way).
        n.watch(sock);
        while (true) {
            const st = ncall(n, .{ .tcp_status = .{ .sock = sock } }) orelse break;
            const code = switch (st) {
                .num => |x| x.n,
                else => break,
            };
            if (code == @intFromEnum(shared.TcpState.established) or code == @intFromEnum(shared.TcpState.close_wait)) return try okResult(it, try it.newHandle("socket", sock, n, dropSock));
            if (code == @intFromEnum(shared.TcpState.closed)) break;
            n.wait();
        }
        _ = ncall(n, .{ .tcp_close = .{ .sock = sock } });
        return try errResult(it, "refused");
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
        const rep = ncall(n, .{ .tcp_status = .{ .sock = sv.handle.id } }) orelse return it.fail("status: the network service did not answer", .{});
        return switch (rep) {
            .num => |x| .{ .str = stateName(x.n) },
            else => .{ .str = "closed" },
        };
    }
    return null;
}

pub const command_names = [_][]const u8{ "connect", "listen", "accept", "send", "recv", "close", "status" };
