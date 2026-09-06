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

/// Everything sized in records or roots lives here, mapped on first
/// use: the roots' arena, the server identity's DER, and the slots.
const identity_mem_len = 8 << 10;
const State = struct {
    roots_mem: [roots_mem_len]u8,
    identity_mem: [identity_mem_len]u8,
    slots: [max_sessions]Slot,
};
var state: ?*State = null;

fn stateNow() ?*State {
    if (state) |st| return st;
    const pages = (@sizeOf(State) + 4095) / 4096;
    const sh = usys.shmCreate(pages);
    if (sh.err != .ok) return null;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) return null;
    const st: *State = @ptrFromInt(m.data[0]);
    for (&st.slots) |*sl| {
        sl.used = false;
        sl.gen = 0;
        sl.wait_ms = wire_wait_ms;
    }
    state = st;
    return st;
}

/// The host says what it was given (once, at start).
pub fn setRoots(pem: []const u8) void {
    roots_pem = pem;
}

// --------------------------------------------------------------- identity

var cert_pem: []const u8 = "";
var key_pem: []const u8 = "";
var identity: tls.Identity = .{};
var identity_state: enum { unloaded, loaded, none } = .unloaded;
var identity_fba: std.heap.FixedBufferAllocator = undefined;

/// The host says what server certificate and key it was given (once).
pub fn setIdentity(cert: []const u8, key: []const u8) void {
    cert_pem = cert;
    key_pem = key;
}

const IdentityOut = union(enum) { id: *const tls.Identity, failed: []const u8 };

fn identityNow() IdentityOut {
    switch (identity_state) {
        .loaded => return .{ .id = &identity },
        .none => return .{ .failed = "no_identity" },
        .unloaded => {},
    }
    if (cert_pem.len == 0 or key_pem.len == 0) {
        identity_state = .none;
        return .{ .failed = "no_identity" };
    }
    const st = state orelse {
        identity_state = .none;
        return .{ .failed = "no_memory" };
    };
    identity_fba = std.heap.FixedBufferAllocator.init(&st.identity_mem);
    identity.loadPem(identity_fba.allocator(), cert_pem, key_pem) catch {
        identity_state = .none;
        return .{ .failed = "bad_identity" };
    };
    identity_state = .loaded;
    return .{ .id = &identity };
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

// ------------------------------------------------------------ connections
//
// One slot holds either the client side (a `tls.Session`) or the server
// side (a `tls.Server`) of a connection; a handle names slot and
// generation so a late drop cannot close the connection that took its
// slot. Sessions and servers are the same pool — a program is usually
// one or the other.

const Slot = struct {
    used: bool,
    gen: u32,
    net: *Net,
    sock: u64,
    wait_ms: u64,
    role: enum { client, server },
    conn: union {
        client: tls.Session,
        server: tls.Server,
    },
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

fn freeSlot(st: *State) ?usize {
    var idx: usize = 0;
    while (idx < max_sessions and st.slots[idx].used) idx += 1;
    return if (idx == max_sessions) null else idx;
}

pub const OpenOut = union(enum) { conn: Conn, failed: []const u8 };

/// The client side: connect to `host`:`port` and shake hands as `name`,
/// the name the certificate must carry (and the server is told, SNI).
pub fn open(n: *Net, host: []const u8, port: u64, name: []const u8) OpenOut {
    const st = stateNow() orelse return .{ .failed = "no_memory" };
    const now = usys.wallMs() orelse return .{ .failed = "no_clock" };
    const rt = switch (rootsNow(st, now)) {
        .roots => |r| r,
        .failed => |m| return .{ .failed = m },
    };
    const idx = freeSlot(st) orelse return .{ .failed = "too_many" };
    const sl = &st.slots[idx];
    sl.sock = switch (n.connectHost(host, port)) {
        .sock => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    sl.net = n;
    sl.used = true;
    sl.gen +%= 1;
    sl.wait_ms = wire_wait_ms;
    sl.role = .client;
    sl.conn = .{ .client = .{} };
    var entropy: [tls.entropy_len]u8 = undefined;
    if (usys.getrandom(&entropy) != .ok) {
        n.closeRaw(sl.sock);
        sl.used = false;
        return .{ .failed = "no_entropy" };
    }
    sl.conn.client.connect(.{ .ctx = @ptrCast(sl), .send = wireSend, .recv = wireRecv }, .{ .host = name, .roots = rt, .entropy = &entropy, .now_ms = now }) catch {
        const why = sl.conn.client.reason();
        n.closeRaw(sl.sock);
        sl.used = false;
        return .{ .failed = why };
    };
    return .{ .conn = connOf(st, idx) };
}

/// The server side: TCP-accept a connection on `listener` and shake
/// hands as the server, presenting the identity the host was given.
pub fn accept(n: *Net, listener: u64) OpenOut {
    const st = stateNow() orelse return .{ .failed = "no_memory" };
    const now = usys.wallMs() orelse return .{ .failed = "no_clock" };
    const id = switch (identityNow()) {
        .id => |x| x,
        .failed => |m| return .{ .failed = m },
    };
    const idx = freeSlot(st) orelse return .{ .failed = "too_many" };
    const sl = &st.slots[idx];
    sl.sock = switch (n.acceptRaw(listener)) {
        .sock => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    sl.net = n;
    sl.used = true;
    sl.gen +%= 1;
    sl.wait_ms = wire_wait_ms;
    sl.role = .server;
    sl.conn = .{ .server = .{} };
    var entropy: [tls.server_entropy_len]u8 = undefined;
    if (usys.getrandom(&entropy) != .ok) {
        n.closeRaw(sl.sock);
        sl.used = false;
        return .{ .failed = "no_entropy" };
    }
    sl.conn.server.accept(.{ .ctx = @ptrCast(sl), .send = wireSend, .recv = wireRecv }, .{ .identity = id, .entropy = &entropy, .now_ms = now }) catch {
        const why = sl.conn.server.reason();
        n.closeRaw(sl.sock);
        sl.used = false;
        return .{ .failed = why };
    };
    return .{ .conn = connOf(st, idx) };
}

/// Every byte, encrypted; null when sent, else why not.
pub fn sendAll(c: Conn, data: []const u8) ?[]const u8 {
    const sl = slotOf(c) orelse return "closed";
    switch (sl.role) {
        .client => sl.conn.client.write(data) catch return sl.conn.client.reason(),
        .server => sl.conn.server.write(data) catch return sl.conn.server.reason(),
    }
    return null;
}

/// Some decrypted bytes (they live in the slot until the next receive),
/// the peer's clean close, or a failure or timeout.
pub fn recvSomeFor(c: Conn, ms: u64) Net.RecvFor {
    const sl = slotOf(c) orelse return .closed;
    sl.wait_ms = ms;
    defer sl.wait_ms = wire_wait_ms;
    const n = switch (sl.role) {
        .client => sl.conn.client.read(&sl.recv_buf) catch |e| return readErr(e, sl.conn.client.reason()),
        .server => sl.conn.server.read(&sl.recv_buf) catch |e| return readErr(e, sl.conn.server.reason()),
    };
    if (n == 0) return .closed;
    return .{ .data = sl.recv_buf[0..n] };
}

fn readErr(e: anyerror, why: []const u8) Net.RecvFor {
    if (e == error.Closed) return .closed;
    if (std.mem.eql(u8, why, "timeout")) return .timeout;
    return .{ .failed = why };
}

/// Close notify, then the socket; the slot is free again.
pub fn close(c: Conn) void {
    const sl = slotOf(c) orelse return;
    switch (sl.role) {
        .client => sl.conn.client.close(),
        .server => sl.conn.server.close(),
    }
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
const tls_listener: Shape = .{ .kind = "tls-listener" };
const tls_listener_result = mshl.resultShape(tls_listener, .string);
/// `accept` takes a plain listener or a tls-listener and yields a socket
/// or a tls connection; tlscmds owns the signature so both kinds pass the
/// type check (netcmds's `accept` would reject a tls-listener), and the
/// call dispatch hands a plain listener on to netcmds.
const listener_kind: Shape = .{ .kind = "listener" };
const any_listener = blk: {
    const alts = [_]Shape{ listener_kind, tls_listener };
    break :blk Shape{ .one_of = &alts };
};
const accepted = blk: {
    const alts = [_]Shape{ .{ .kind = "socket" }, tls_kind };
    break :blk Shape{ .one_of = &alts };
};
const accept_result = mshl.resultShape(accepted, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "tls-connect")) return .{ .params = &.{ .{ .name = "host", .shape = .string }, .{ .name = "port", .shape = .int }, .{ .name = "options", .shape = .record, .optional = true } }, .ret = tls_result };
    if (std.mem.eql(u8, name, "tls-listen")) return .{ .params = &.{.{ .name = "port", .shape = .int }}, .ret = tls_listener_result };
    if (std.mem.eql(u8, name, "accept")) return .{ .params = &.{.{ .name = "listener", .shape = any_listener, .optional = true }}, .input = .{ .optional = any_listener }, .ret = accept_result };
    return null;
}

/// null = not for us: `tls-connect`, `tls-listen`, and `accept` on a
/// tls-listener / `send`/`recv`/`status`/`close` on a tls handle (the
/// socket commands answer for their own handles).
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
    if (is(u8, name, "tls-listen")) {
        if (args[0].int < 1 or args[0].int > 65535) return it.fail("tls-listen: a port (1-65535) expected", .{});
        // Refuse to listen with no identity to present.
        if (stateNow() == null) return it.fail("tls-listen: no memory for tls", .{});
        switch (identityNow()) {
            .id => {},
            .failed => |m| return try errResult(it, m),
        }
        if (!n.attach()) return it.fail("tls-listen: cannot attach a buffer to the network view", .{});
        const rep = netcmds.ncallPub(n, .{ .tcp_listen = .{ .port = @intCast(args[0].int) } }) orelse return it.fail("tls-listen: the network service did not answer", .{});
        return switch (rep) {
            .num => |x| blk: {
                n.watch(x.n); // so accept wakes when a client connects
                break :blk try okResult(it, try it.newHandle("tls-listener", x.n, n, netcmds.dropSock));
            },
            .net_err => |e| try errResult(it, netcmds.errNamePub(e.code)),
            .ok => it.fail("tls-listen: unexpected reply", .{}),
        };
    }
    const hv = input orelse (if (args.len > 0) args[0] else return null);
    if (is(u8, name, "accept") and hv == .handle and is(u8, hv.handle.kind, "tls-listener")) {
        if (hv.handle.closed) return it.fail("accept: the tls-listener is closed", .{});
        return switch (accept(n, hv.handle.id)) {
            .conn => |c| try okResult(it, try it.newHandle("tls", c, n, dropConn)),
            .failed => |m| try errResult(it, m),
        };
    }
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

pub const command_names = [_][]const u8{ "tls-connect", "tls-listen" };
