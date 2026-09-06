//! dotd — a DNS-over-TLS forwarder (RFC 7858). It binds UDP 53 on its
//! network view, so netsvc's resolver reaches it as an ordinary local
//! resolver (the same way it reaches dnsd); for each query it opens a
//! TLS 1.3 connection to the configured upstream resolver, sends the
//! query framed as DNS-over-TCP is (a two-byte length, then the
//! message), reads the reply the same way, and sends it back as UDP.
//! The upstream's certificate is verified for the configured name
//! against the trust roots read from the assets view the unit gave
//! (`assets/tls/roots.pem` by default), and against the wall clock — a
//! query fails closed if the time is unknown or no root vouches. The
//! roots are reloaded when the file's mtime advances, so updating the
//! bundle in the filesystem takes effect with no restart. Settings
//! (`conf/dot.msh`, a file): the upstream address, its port (853), the
//! name its certificate must carry, and the roots path in the view.
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
const fsc = @import("fsclient.zig");
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
var roots_path_buf: [128]u8 = undefined;
var roots_path: []const u8 = "assets/tls/roots.pem";
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
    // Where the trust roots live in the assets view (a path relative to
    // the view the unit gave), reloaded when the file changes.
    if (v.record.get("roots")) |rp| {
        if (rp == .str and rp.str.len <= roots_path_buf.len) {
            @memcpy(roots_path_buf[0..rp.str.len], rp.str);
            roots_path = roots_path_buf[0..rp.str.len];
        }
    }
}

// ------------------------------------------------------------- the wire

/// The trust roots, read from the assets view and reloaded when the
/// file's mtime advances — an update to the bundle takes effect without
/// a restart. All BSS, not image bytes: the parse arena (a real bundle
/// is ~140 KB of DER plus the map) and the PEM source buffer.
var roots: tls.Roots = .{};
var roots_mtime: u64 = 0;
var roots_size: u64 = 0;
var roots_ok = false;
var roots_mem: [384 << 10]u8 = undefined;
var roots_pem_buf: [256 << 10]u8 = undefined;
var roots_fba: std.heap.FixedBufferAllocator = undefined;
var view_chan: u64 = 0;
var view_buf: [*]u8 = undefined;

/// Ensure the roots are loaded and current: stat the file, and (re)read
/// and (re)parse it when its mtime has changed since the last load.
/// `now_ms` dates the certificates. Null with a reason on failure.
fn ensureRoots(now_ms: u64) ?[]const u8 {
    const st = fsc.fsStat(view_chan, view_buf, roots_path) orelse return "no roots file";
    // The change signal is mtime and size together: an update to the
    // bundle changes one or the other. (mtime alone is second-grained.)
    if (roots_ok and st.mtime == roots_mtime and st.size == roots_size) return null;
    const pem = fsc.readWhole(view_chan, view_buf, roots_path, &roots_pem_buf) orelse return "cannot read roots";
    roots = .{};
    roots_fba = std.heap.FixedBufferAllocator.init(&roots_mem);
    const n = roots.add(roots_fba.allocator(), pem, @intCast(now_ms / 1000)) catch 0;
    if (n == 0) {
        roots_ok = false;
        return "no roots";
    }
    roots_mtime = st.mtime;
    roots_size = st.size;
    roots_ok = true;
    return null;
}

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
    const now = usys.wallMs() orelse return .{ .failed = "no clock" };
    if (ensureRoots(now)) |m| return .{ .failed = m };
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

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.net)) fail("dotd: no network view");
    if (!setup.has(.view)) fail("dotd: no assets view (for the trust roots)");
    readSettings(setup.data());
    view_chan = setup.cap(.view);
    view_buf = @ptrFromInt(fsc.attachBuf(view_chan).va);
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
