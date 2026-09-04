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
//! Waiting is polling with a tick's sleep between tries (netsvc never
//! blocks; doorbells are the fabric's way and a later step here).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;

pub const Net = struct {
    chan: u64,
    buf: [*]u8 = undefined,
    attached: bool = false,

    pub fn init(chan: u64) Net {
        return .{ .chan = chan };
    }

    fn attach(n: *Net) bool {
        if (n.attached) return true;
        const s = usys.shmCreate(1);
        if (s.err != .ok) return false;
        const m = usys.shmMap(s.data[0]);
        if (m.err != .ok) return false;
        n.buf = @ptrFromInt(m.data[0]);
        switch (usys.callTyped(shared.NetReq, shared.NetResp, n.chan, .attach_buf, s.data[0])) {
            .ok => |rep| if (rep != .ok) return false,
            .err => return false,
        }
        n.attached = true;
        return true;
    }
};

const max_wait_ticks = 3000; // ~30 s at 100 Hz
const piece = 512; // netsvc's tcp_send limit

fn ncall(n: *Net, req: shared.NetReq) ?shared.NetResp {
    return switch (usys.callTyped(shared.NetReq, shared.NetResp, n.chan, req, 0)) {
        .ok => |rep| rep,
        .err => null,
    };
}

fn errName(code: u64) []const u8 {
    return switch (code) {
        @intFromEnum(shared.NetErr.would_block) => "would block",
        @intFromEnum(shared.NetErr.denied) => "denied by the view",
        @intFromEnum(shared.NetErr.refused) => "refused",
        @intFromEnum(shared.NetErr.closed) => "closed",
        @intFromEnum(shared.NetErr.bad) => "bad socket or argument",
        @intFromEnum(shared.NetErr.no_space) => "no socket left",
        else => "network error",
    };
}

fn stateName(st: u64) []const u8 {
    return switch (st) {
        @intFromEnum(shared.TcpState.closed) => "closed",
        @intFromEnum(shared.TcpState.listen) => "listening",
        @intFromEnum(shared.TcpState.syn_sent) => "connecting",
        @intFromEnum(shared.TcpState.syn_rcvd) => "handshaking",
        @intFromEnum(shared.TcpState.established) => "established",
        @intFromEnum(shared.TcpState.close_wait) => "peer closed",
        else => "?",
    };
}

fn dropSock(ctx: *anyopaque, _: []const u8, id: u64) void {
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

fn sockArg(it: *mshl.Interp, v: Value, cmd: []const u8, kind: []const u8) mshl.Error!u64 {
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
        // The handshake: established, or closed (refused, or gave up).
        var waited: usize = 0;
        while (waited < max_wait_ticks) : (waited += 1) {
            const st = ncall(n, .{ .tcp_status = .{ .sock = sock } }) orelse break;
            const code = switch (st) {
                .num => |x| x.n,
                else => break,
            };
            if (code == @intFromEnum(shared.TcpState.established)) return try okResult(it, try it.newHandle("socket", sock, n, dropSock));
            if (code == @intFromEnum(shared.TcpState.closed)) break;
            usys.sleep(1);
        }
        _ = ncall(n, .{ .tcp_close = .{ .sock = sock } });
        return try errResult(it, if (waited == max_wait_ticks) "timed out" else "refused");
    }
    if (is(u8, name, "listen")) {
        if (args.len != 1) return it.fail("listen: PORT expected", .{});
        const port = try portArg(it, args[0], "listen");
        if (!n.attach()) return it.fail("listen: cannot attach a buffer to the network view", .{});
        const rep = ncall(n, .{ .tcp_listen = .{ .port = port } }) orelse return it.fail("listen: the network service did not answer", .{});
        return switch (rep) {
            .num => |x| try okResult(it, try it.newHandle("listener", x.n, n, dropSock)),
            .net_err => |e| try errResult(it, errName(e.code)),
            .ok => it.fail("listen: unexpected reply", .{}),
        };
    }
    if (is(u8, name, "accept")) {
        const lv = input orelse (if (args.len > 0) args[0] else return it.fail("accept: a listener expected", .{}));
        const l = try sockArg(it, lv, "accept", "listener");
        var waited: usize = 0;
        while (waited < max_wait_ticks) : (waited += 1) {
            const rep = ncall(n, .{ .tcp_accept = .{ .sock = l } }) orelse return it.fail("accept: the network service did not answer", .{});
            switch (rep) {
                .num => |x| return try okResult(it, try it.newHandle("socket", x.n, n, dropSock)),
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return try errResult(it, errName(e.code)),
                .ok => {},
            }
            usys.sleep(1);
        }
        return try errResult(it, "timed out");
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
        var waited: usize = 0;
        while (off < data.len) {
            const len = @min(piece, data.len - off);
            @memcpy(n.buf[0..len], data[off .. off + len]);
            const rep = ncall(n, .{ .tcp_send = .{ .sock = s, .len = len } }) orelse return it.fail("send: the network service did not answer", .{});
            switch (rep) {
                .num => |x| {
                    off += x.n;
                    waited = 0;
                },
                .net_err => |e| {
                    if (e.code != @intFromEnum(shared.NetErr.would_block)) return try errResult(it, errName(e.code));
                    if (waited == max_wait_ticks) return try errResult(it, "timed out");
                    waited += 1;
                    usys.sleep(1);
                },
                .ok => {},
            }
        }
        return try okResult(it, .{ .int = @intCast(off) });
    }
    if (is(u8, name, "recv")) {
        const sv = input orelse (if (args.len > 0) args[0] else return it.fail("recv: a socket expected", .{}));
        const s = try sockArg(it, sv, "recv", "socket");
        const max: u64 = if (args.len > 1 and args[1] == .int and args[1].int > 0) @min(@as(u64, @intCast(args[1].int)), 2048) else 2048;
        var waited: usize = 0;
        while (waited < max_wait_ticks) : (waited += 1) {
            const rep = ncall(n, .{ .tcp_recv = .{ .sock = s, .len = max } }) orelse return it.fail("recv: the network service did not answer", .{});
            switch (rep) {
                .num => |x| return try okResult(it, .{ .bytes = try it.arena.dupe(u8, n.buf[0..x.n]) }),
                .net_err => |e| if (e.code != @intFromEnum(shared.NetErr.would_block)) return try errResult(it, errName(e.code)),
                .ok => {},
            }
            usys.sleep(1);
        }
        return try errResult(it, "timed out");
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
