//! TLS for mshl hosts: `tls-connect HOST PORT [{ host: NAME }]` opens
//! a TCP connection and shakes hands over it (TLS 1.3, lib/tls.zig on
//! the standard library's client), verifying the server's certificate
//! against the trust roots the host was given (`{ tag: roots, file:
//! tls/roots.pem }` in its unit) for NAME — the host as written unless
//! the option says otherwise — and the wall clock. The value is a
//! `tls` handle that `send`, `recv`, `status` and `close` take like a
//! socket; `fetch https://…` opens one the same way. A handshake that
//! fails is a result by its word: `untrusted`, `host_mismatch`,
//! `expired`, `no_roots` (nothing given), `no_clock` (certificates
//! cannot be checked without the time), `too_many`, or the transport's.
//!
//! Sessions are a small table (each owns four record-sized buffers) and
//! the roots parse once, on first use, into an arena: together some
//! 600 KB, mapped on first use rather than carried in the image (an
//! image is staged in 512 KB).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const netcmds = @import("netcmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const tls = mosslib.tls;
const Value = mshl.Value;
const Shape = mshl.Shape;
const Net = netcmds.Net;

// ------------------------------------------------------------------ roots

var roots_pem: []const u8 = "";
var roots: tls.Roots = .{};
var roots_state: enum { unloaded, loaded, none } = .unloaded;
/// The Mozilla bundle is ~190 KB of PEM (~140 KB of DER) plus the map.
const roots_mem_len = 384 << 10;
var roots_fba: std.heap.FixedBufferAllocator = undefined;

/// Everything sized in records or roots lives here, mapped on first use.
const State = struct { roots_mem: [roots_mem_len]u8, slots: [max_sessions]Slot };
var state: ?*State = null;

fn stateNow() ?*State {
    if (state) |st| return st;
    const pages = (@sizeOf(State) + 4095) / 4096;
    const sh = usys.shmCreate(pages);
    if (sh.err != .ok) return null;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) return null;
    const st: *State = @ptrFromInt(m.data[0]);
    for (&st.slots) |*sl| sl.* = .{ .used = false, .gen = 0, .net = undefined, .sock = 0, .wait_ms = wire_wait_ms, .sess = .{}, .recv_buf = undefined };
    state = st;
    return st;
}

/// The host says what it was given (once, at start).
pub fn setRoots(pem: []const u8) void {
    roots_pem = pem;
}

const RootsOut = union(enum) { roots: *tls.Roots, failed: []const u8 };

fn rootsNow(st: *State, now_ms: u64) RootsOut {
    switch (roots_state) {
        .loaded => return .{ .roots = &roots },
        .none => return .{ .failed = "no_roots" },
        .unloaded => {},
    }
    if (roots_pem.len == 0) {
        roots_state = .none;
        return .{ .failed = "no_roots" };
    }
    roots_fba = std.heap.FixedBufferAllocator.init(&st.roots_mem);
    const n = roots.add(roots_fba.allocator(), roots_pem, @intCast(now_ms / 1000)) catch 0;
    if (n == 0) {
        roots_state = .none;
        return .{ .failed = "no_roots" };
    }
    roots_state = .loaded;
    return .{ .roots = &roots };
}

// --------------------------------------------------------------- sessions

const Slot = struct {
    used: bool,
    /// Bumped per open: a handle names slot and generation, so one
    /// dropped late cannot close the session that took its slot.
    gen: u32,
    net: *Net,
    sock: u64,
    wait_ms: u64,
    sess: tls.Session,
    recv_buf: [4096]u8,
};
const max_sessions = 4;
/// How long the wire is waited on under a handshake or a `recv`.
const wire_wait_ms: u64 = 30_000;

fn wireSend(ctx: *anyopaque, data: []const u8) ?[]const u8 {
    const sl: *Slot = @ptrCast(@alignCast(ctx));
    return sl.net.sendAll(sl.sock, data);
}

fn wireRecv(ctx: *anyopaque, buf: []u8) tls.RecvOut {
    const sl: *Slot = @ptrCast(@alignCast(ctx));
    switch (sl.net.recvUpToFor(sl.sock, buf.len, sl.wait_ms)) {
        .data => |d| {
            @memcpy(buf[0..d.len], d);
            return .{ .n = d.len };
        },
        .closed => return .closed,
        .failed => |m| return .{ .failed = m },
        .timeout => return .{ .failed = "timeout" },
    }
}

/// A connection by number: slot in the low byte, generation above.
pub const Conn = u64;

fn connOf(st: *State, idx: usize) Conn {
    return @as(u64, st.slots[idx].gen) << 8 | idx;
}

fn slotOf(c: Conn) ?*Slot {
    const st = state orelse return null;
    const idx: usize = @intCast(c & 0xff);
    if (idx >= max_sessions) return null;
    const sl = &st.slots[idx];
    if (!sl.used or sl.gen != c >> 8) return null;
    return sl;
}

pub const OpenOut = union(enum) { conn: Conn, failed: []const u8 };

/// Connect to `host`:`port` and shake hands as `name`, the name the
/// certificate must carry (and the server is told, SNI).
pub fn open(n: *Net, host: []const u8, port: u64, name: []const u8) OpenOut {
    const st = stateNow() orelse return .{ .failed = "no_memory" };
    const now = usys.wallMs() orelse return .{ .failed = "no_clock" };
    const rt = switch (rootsNow(st, now)) {
        .roots => |r| r,
        .failed => |m| return .{ .failed = m },
    };
    var idx: usize = 0;
    while (idx < max_sessions and st.slots[idx].used) idx += 1;
    if (idx == max_sessions) return .{ .failed = "too_many" };
    const sl = &st.slots[idx];
    sl.sock = switch (n.connectHost(host, port)) {
        .sock => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    sl.net = n;
    sl.used = true;
    sl.gen +%= 1;
    sl.wait_ms = wire_wait_ms;
    var entropy: [tls.entropy_len]u8 = undefined;
    if (usys.getrandom(&entropy) != .ok) {
        n.closeRaw(sl.sock);
        sl.used = false;
        return .{ .failed = "no_entropy" };
    }
    sl.sess.connect(.{ .ctx = @ptrCast(sl), .send = wireSend, .recv = wireRecv }, .{ .host = name, .roots = rt, .entropy = &entropy, .now_ms = now }) catch {
        const why = sl.sess.reason();
        n.closeRaw(sl.sock);
        sl.used = false;
        return .{ .failed = why };
    };
    return .{ .conn = connOf(st, idx) };
}

/// Every byte, encrypted; null when sent, else why not.
pub fn sendAll(c: Conn, data: []const u8) ?[]const u8 {
    const sl = slotOf(c) orelse return "closed";
    sl.sess.write(data) catch return sl.sess.reason();
    return null;
}

/// Some decrypted bytes (they live in the session until the next
/// receive), the peer's clean close, or a failure or timeout.
pub fn recvSomeFor(c: Conn, ms: u64) Net.RecvFor {
    const sl = slotOf(c) orelse return .closed;
    sl.wait_ms = ms;
    defer sl.wait_ms = wire_wait_ms;
    const n = sl.sess.read(&sl.recv_buf) catch |e| switch (e) {
        error.Closed => return .closed,
        error.Failed => {
            const why = sl.sess.reason();
            if (std.mem.eql(u8, why, "timeout")) return .timeout;
            return .{ .failed = why };
        },
    };
    if (n == 0) return .closed;
    return .{ .data = sl.recv_buf[0..n] };
}

/// Close notify, then the socket; the slot is free again.
pub fn close(c: Conn) void {
    const sl = slotOf(c) orelse return;
    sl.sess.close();
    sl.net.closeRaw(sl.sock);
    sl.used = false;
}

// --------------------------------------------------------------- commands

fn dropConn(_: *anyopaque, _: []const u8, id: u64) void {
    close(id);
}

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    return it.mkResult(false, .{ .str = msg });
}

fn okResult(it: *mshl.Interp, v: Value) mshl.Error!Value {
    return it.mkResult(true, v);
}

const tls_kind: Shape = .{ .kind = "tls" };
const tls_result = mshl.resultShape(tls_kind, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "tls-connect")) return .{ .params = &.{ .{ .name = "host", .shape = .string }, .{ .name = "port", .shape = .int }, .{ .name = "options", .shape = .record, .optional = true } }, .ret = tls_result };
    return null;
}

/// null = not for us: `tls-connect`, and `send`/`recv`/`status`/`close`
/// when the handle is a tls one (the socket commands otherwise).
pub fn call(n: *Net, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "tls-connect")) {
        if (args[1].int < 1 or args[1].int > 65535) return it.fail("tls-connect: a port (1-65535) expected", .{});
        var cert_name = args[0].str;
        if (args.len > 2) {
            if (args[2].record.get("host")) |h| {
                if (h != .str) return it.fail("tls-connect: host must be a string", .{});
                cert_name = h.str;
            }
        }
        if (!n.attach()) return it.fail("tls-connect: cannot attach a buffer to the network view", .{});
        return switch (open(n, args[0].str, @intCast(args[1].int), cert_name)) {
            .conn => |c| try okResult(it, try it.newHandle("tls", c, n, dropConn)),
            .failed => |m| try errResult(it, m),
        };
    }
    const hv = input orelse (if (args.len > 0) args[0] else return null);
    if (hv != .handle or !is(u8, hv.handle.kind, "tls")) return null;
    if (is(u8, name, "send")) {
        if (args.len != 2) return it.fail("send: SOCKET DATA expected", .{});
        if (hv.handle.closed) return it.fail("send: the tls connection is closed", .{});
        const data: []const u8 = switch (args[1]) {
            .str => |t| t,
            .bytes => |b| b,
            else => return it.fail("send: a string or bytes expected, got a {s}", .{args[1].typeName()}),
        };
        if (sendAll(hv.handle.id, data)) |m| return try errResult(it, m);
        return try okResult(it, .{ .int = @intCast(data.len) });
    }
    if (is(u8, name, "recv")) {
        if (hv.handle.closed) return it.fail("recv: the tls connection is closed", .{});
        return switch (recvSomeFor(hv.handle.id, wire_wait_ms)) {
            .data => |d| try okResult(it, .{ .bytes = try it.arena.dupe(u8, d) }),
            .closed => try errResult(it, "closed"),
            .failed => |m| try errResult(it, m),
            .timeout => try errResult(it, "timeout"),
        };
    }
    if (is(u8, name, "close")) {
        if (!hv.handle.closed) {
            close(hv.handle.id);
            it.closeHandle(hv);
        }
        return .nothing;
    }
    if (is(u8, name, "status")) {
        return .{ .str = if (hv.handle.closed or slotOf(hv.handle.id) == null) "closed" else "established" };
    }
    return null;
}

pub const command_names = [_][]const u8{"tls-connect"};
