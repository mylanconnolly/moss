//! dotd — a DNS-over-TLS forwarder (RFC 7858). It binds UDP 53 on its
//! network view, so netsvc's resolver reaches it as an ordinary local
//! resolver (the same way it reaches dnsd); for each query it opens a
//! TLS 1.3 connection to the configured upstream resolver, sends the
//! query framed as DNS-over-TCP is (a two-byte length, then the
//! message), reads the reply the same way, and sends it back as UDP.
//! The upstream's certificate is verified for the configured name
//! against the trust roots the unit gave (`{ tag: roots, file: … }`),
//! and against the wall clock — a query fails closed if the time is
//! unknown or no root vouches for the server. Settings (`conf/dot.msh`,
//! given as a file): the upstream's address, its port (853), and the
//! name its certificate must carry.
//!
//! One thread, one query at a time, a fresh TLS connection each (a DoT
//! server keeps the connection alive; this first cut does not). The
//! forwarder never parses the DNS itself — it moves opaque messages —
//! so it is only the resolver's private path to the wider world.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const netcmds = @import("netcmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const tls = mosslib.tls;

comptime {
    asm (usys.imageHeader("dotd"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    var buf: [200]u8 = undefined;
    const pre = "dotd: panic: ";
    @memcpy(buf[0..pre.len], pre);
    const n = @min(msg.len, buf.len - pre.len);
    @memcpy(buf[pre.len .. pre.len + n], msg[0..n]);
    _ = usys.log(glog, buf[0 .. pre.len + n]);
    usys.exit(255);
}

var glog: u64 = 0;

fn fail(msg: []const u8) noreturn {
    _ = usys.log(glog, msg);
    usys.exit(1);
}

fn logLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&buf, fmt, args) catch "dotd: (a line too long to log)");
}

// -------------------------------------------------------------- settings

var upstream_text: [64]u8 = undefined;
var upstream: []const u8 = "";
var upstream_port: u64 = 853;
var cert_name_buf: [128]u8 = undefined;
var cert_name: []const u8 = "";
var settings_mem: [4 << 10]u8 = undefined;

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const mshl.Value, _: ?mshl.Value) mshl.Error!?mshl.Value {
    return null;
}

/// `{ upstream: 1.1.1.1, port: 853, name: cloudflare-dns.com }`
fn readSettings(text: []const u8) void {
    if (text.len == 0) fail("dotd: no settings (need an upstream)");
    var fba = std.heap.FixedBufferAllocator.init(&settings_mem);
    const a = fba.allocator();
    var ctx: u8 = 0;
    var it = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&ctx), .call = noHost });
    const v = it.parseData(text) catch fail("dotd: the settings file is not data");
    if (v != .record) fail("dotd: the settings file is not a record");
    const up = v.record.get("upstream") orelse fail("dotd: no upstream in the settings");
    if (up != .str or up.str.len > upstream_text.len) fail("dotd: upstream: an address expected");
    @memcpy(upstream_text[0..up.str.len], up.str);
    upstream = upstream_text[0..up.str.len];
    if (v.record.get("port")) |p| {
        if (p == .int and p.int >= 1 and p.int <= 65535) upstream_port = @intCast(p.int);
    }
    // The name the certificate must carry: the upstream text unless said.
    var name = upstream;
    if (v.record.get("name")) |nm| {
        if (nm == .str) name = nm.str;
    }
    if (name.len > cert_name_buf.len) fail("dotd: name: too long");
    @memcpy(cert_name_buf[0..name.len], name);
    cert_name = cert_name_buf[0..name.len];
}

// ------------------------------------------------------------- the wire

/// The trust roots live here for the life of the server (BSS, not image
/// bytes): the Mozilla bundle is ~140 KB of DER plus the map.
var roots: tls.Roots = .{};
var roots_loaded = false;
var roots_mem: [384 << 10]u8 = undefined;
var roots_fba: std.heap.FixedBufferAllocator = undefined;

var session: tls.Session = .{};

/// The transport under the TLS session: one TCP socket on the view.
const Wire = struct {
    net: *netcmds.Net,
    sock: u64,
    fn send(ctx: *anyopaque, data: []const u8) ?[]const u8 {
        const w: *Wire = @ptrCast(@alignCast(ctx));
        return w.net.sendAll(w.sock, data);
    }
    fn recv(ctx: *anyopaque, buf: []u8) tls.RecvOut {
        const w: *Wire = @ptrCast(@alignCast(ctx));
        return switch (w.net.recvUpToFor(w.sock, buf.len, wire_wait_ms)) {
            .data => |d| blk: {
                @memcpy(buf[0..d.len], d);
                break :blk .{ .n = d.len };
            },
            .closed => .closed,
            .failed => |m| .{ .failed = m },
            .timeout => .{ .failed = "timeout" },
        };
    }
};

const wire_wait_ms: u64 = 10_000;

const ForwardOut = union(enum) { reply: []const u8, failed: []const u8 };

/// One query out, its reply back: connect, handshake, frame, exchange.
/// `reply` points into `out`.
fn forward(net: *netcmds.Net, query: []const u8, out: []u8) ForwardOut {
    if (!roots_loaded) {
        const now = usys.wallMs() orelse return .{ .failed = "no clock" };
        roots_fba = std.heap.FixedBufferAllocator.init(&roots_mem);
        const n = roots.add(roots_fba.allocator(), roots_pem, @intCast(now / 1000)) catch 0;
        if (n == 0) return .{ .failed = "no roots" };
        roots_loaded = true;
    }
    const now = usys.wallMs() orelse return .{ .failed = "no clock" };
    const sock = switch (net.connectHost(upstream, upstream_port)) {
        .sock => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    defer net.closeRaw(sock);
    var wire = Wire{ .net = net, .sock = sock };
    var entropy: [tls.entropy_len]u8 = undefined;
    if (usys.getrandom(&entropy) != .ok) return .{ .failed = "no entropy" };
    session.connect(.{ .ctx = @ptrCast(&wire), .send = Wire.send, .recv = Wire.recv }, .{ .host = cert_name, .roots = &roots, .entropy = &entropy, .now_ms = now }) catch {
        return .{ .failed = session.reason() };
    };
    defer session.close();
    // Frame the query as DNS-over-TCP: a two-byte length, then the message.
    var framed: [2 + dns_max]u8 = undefined;
    framed[0] = @intCast(query.len >> 8);
    framed[1] = @intCast(query.len & 0xff);
    @memcpy(framed[2 .. 2 + query.len], query);
    session.write(framed[0 .. 2 + query.len]) catch return .{ .failed = session.reason() };
    // Read the two-byte length, then that many bytes.
    var hdr: [2]u8 = undefined;
    if (!readExact(&hdr)) return .{ .failed = "short reply" };
    const rlen: usize = @as(usize, hdr[0]) << 8 | hdr[1];
    if (rlen == 0 or rlen > out.len) return .{ .failed = "reply too large" };
    if (!readExact(out[0..rlen])) return .{ .failed = "short reply" };
    return .{ .reply = out[0..rlen] };
}

/// Fill `buf` exactly from the session, or false at a close or failure.
fn readExact(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = session.read(buf[off..]) catch return false;
        if (n == 0) return false;
        off += n;
    }
    return true;
}

const dns_max = 4096;

var roots_pem: []const u8 = "";

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.net)) fail("dotd: no network view");
    readSettings(setup.data());
    roots_pem = setup.file(.roots) orelse fail("dotd: no trust roots given");
    var net = netcmds.Net.init(setup.cap(.net));
    if (!net.attach()) fail("dotd: cannot attach a buffer to the network view");
    const sock = switch (net.udpBindRaw(53)) {
        .sock => |s| s,
        .failed => |m| fail(m),
    };
    logLine("dotd: forwarding udp 53 to {s}:{d} over tls (as {s})", .{ upstream, upstream_port, cert_name });

    while (true) {
        const d = switch (net.udpRecvRaw(sock)) {
            .datagram => |x| x,
            .failed => |m| fail(m),
        };
        // The query must be copied out: the view buffer is reused by the
        // TLS connection's own sends and receives.
        var query: [dns_max]u8 = undefined;
        if (d.data.len == 0 or d.data.len > query.len) continue;
        @memcpy(query[0..d.data.len], d.data);
        const from = d.from;
        const port = d.port;
        var out: [dns_max]u8 = undefined;
        switch (forward(&net, query[0..d.data.len], &out)) {
            .reply => |r| _ = net.udpSendRaw(sock, from, port, r),
            .failed => |m| logLine("dotd: {s}", .{m}),
        }
    }
}
