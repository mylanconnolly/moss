//! The gate's DNS-over-TLS server: a host helper QEMU spawns per
//! connection (a slirp `guestfwd ... -cmd`), its stdin the bytes from
//! the guest and its stdout the bytes to it. It runs moss's own TLS 1.3
//! server (lib/tls.zig) over that stdio, then answers one length-prefixed
//! DNS query (RFC 7858 framing) from a fixed zone: any A question gets
//! 192.0.2.53, any AAAA question 2001:db8::53, so the drill can watch a
//! name resolve to those over the private path. It proves dotd's client
//! side against a DoT server built from our own library — and that the
//! library serves TLS over a plain byte stream, not just a socket.

const std = @import("std");
const Io = std.Io;
const mosslib = @import("mosslib");
const tls = mosslib.tls;
const dns = mosslib.dns;

var g_io: Io = undefined;
var g_in: Io.File.Reader = undefined;
var g_out: Io.File.Writer = undefined;

fn send(_: *anyopaque, data: []const u8) ?[]const u8 {
    g_out.interface.writeAll(data) catch return "write failed";
    g_out.interface.flush() catch return "flush failed";
    return null;
}
fn recv(_: *anyopaque, buf: []u8) tls.RecvOut {
    // readVec returning 0 is transient (not end of stream); only
    // error.EndOfStream is a close. Loop until some bytes or a close.
    while (true) {
        var bufs = [_][]u8{buf};
        const n = g_in.interface.readVec(&bufs) catch |e| switch (e) {
            error.EndOfStream => return .closed,
            else => return .{ .failed = "read failed" },
        };
        if (n > 0) return .{ .n = n };
    }
}

var server: tls.Server = .{};

pub fn main(init: std.process.Init) !void {
    const io = init.io;
    g_io = io;
    const gpa = init.arena.allocator();
    var inbuf: [4096]u8 = undefined;
    var outbuf: [4096]u8 = undefined;
    g_in = Io.File.stdin().reader(io, &inbuf);
    g_out = Io.File.stdout().writer(io, &outbuf);

    // Run from the repo root (QEMU's cwd), so the test material is here.
    const cwd = Io.Dir.cwd();
    const cert = cwd.readFileAlloc(io, "lib/tls/moss-test-server.pem", gpa, .limited(1 << 16)) catch return;
    const key = cwd.readFileAlloc(io, "lib/tls/moss-test-server.key", gpa, .limited(1 << 16)) catch return;
    var id: tls.Identity = .{};
    id.loadPem(gpa, cert, key) catch return;
    var entropy: [tls.server_entropy_len]u8 = undefined;
    io.random(&entropy);
    const now = Io.Clock.real.now(io);
    const now_ms: u64 = @intCast(@divTrunc(now.nanoseconds, std.time.ns_per_ms));
    server.accept(.{ .ctx = undefined, .send = send, .recv = recv }, .{ .identity = &id, .entropy = &entropy, .now_ms = now_ms }) catch return;

    // Read one length-prefixed DNS query.
    var hdr: [2]u8 = undefined;
    if (!readExact(&hdr)) return;
    const qlen: usize = @as(usize, hdr[0]) << 8 | hdr[1];
    if (qlen == 0 or qlen > 4096) return;
    var qbuf: [4096]u8 = undefined;
    if (!readExact(qbuf[0..qlen])) return;

    var scratch: [8 << 10]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&scratch);
    const q = dns.parse(fba.allocator(), qbuf[0..qlen]) catch return;

    // A fixed zone: A → 192.0.2.53, AAAA → 2001:db8::53.
    const a_addr = addr4(192, 0, 2, 53);
    const aaaa_addr = addr6(0x2001, 0x0db8, 0, 0, 0, 0, 0, 0x53);
    var out: [512]u8 = undefined;
    const n = switch (q.qtype) {
        .a => dns.buildResponse(&out, q.id, q.qname, .a, .ok, &.{a_addr}, 300) catch return,
        .aaaa => dns.buildResponse(&out, q.id, q.qname, .aaaa, .ok, &.{aaaa_addr}, 300) catch return,
        else => dns.buildResponse(&out, q.id, q.qname, q.qtype, .notimp, &.{}, 0) catch return,
    };
    var framed: [2 + 512]u8 = undefined;
    framed[0] = @intCast(n >> 8);
    framed[1] = @intCast(n & 0xff);
    @memcpy(framed[2 .. 2 + n], out[0..n]);
    server.write(framed[0 .. 2 + n]) catch {};
    server.close();
}

fn readExact(buf: []u8) bool {
    var off: usize = 0;
    while (off < buf.len) {
        const n = server.read(buf[off..]) catch return false;
        if (n == 0) return false;
        off += n;
    }
    return true;
}

/// An IPv4 address as the [2]u64 words moss uses (v4-mapped v6).
fn addr4(a: u8, b: u8, c: u8, d: u8) [2]u64 {
    const lo: u64 = (@as(u64, 0xffff) << 32) | (@as(u64, a) << 24) | (@as(u64, b) << 16) | (@as(u64, c) << 8) | d;
    return .{ 0, lo };
}

fn addr6(a: u16, b: u16, c: u16, d: u16, e: u16, f: u16, g: u16, h: u16) [2]u64 {
    const hi: u64 = (@as(u64, a) << 48) | (@as(u64, b) << 32) | (@as(u64, c) << 16) | d;
    const lo: u64 = (@as(u64, e) << 48) | (@as(u64, f) << 32) | (@as(u64, g) << 16) | h;
    return .{ hi, lo };
}
