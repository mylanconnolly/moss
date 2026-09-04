//! Networking, by x2:
//!   1 "netsvc"  — virtio-net driver + a deliberately tiny dual-stack
//!                 TCP/IP in one userspace process. The ABI is IPv6-native
//!                 (every address is 128 bits; IPv4 rides v4-mapped), and
//!                 the wire speaks both families: ARP for v4, NDP/ICMPv6
//!                 for v6. TCP is stop-and-wait (one unacked segment per
//!                 socket), in-order receive only, fixed windows, no
//!                 options — enough for the fabric protocol and a demo,
//!                 not an RFC museum. Network access is a badged view;
//!                 filtered views hold a one-destination outbound allowlist
//!                 and may not listen or derive. Local destinations (own
//!                 addresses, ::1, 127/8) short-circuit through the stack.
//!   2 "echosrv" — listens on :7777 (family-agnostic), serves two
//!                 connections, echoing until each close.
//!   3 "echocli" — loopback TCP over v4-mapped AND over IPv6, wire TCP to
//!                 the slirp guestfwd echo, and an ICMPv6 ping of the v6
//!                 gateway as the v6 wire proof.
//!   4 "boxed"   — filtered view allowing only the wire echo destination:
//!                 that works; v4 gateway, v6 gateway, loopback, listen,
//!                 and derive are all refused.

const shared = @import("shared");
const usys = @import("usys.zig");
const virtio = @import("virtio.zig");
const boot = @import("boot.zig");

comptime {
    asm (
        \\.section .text.uhdr, "ax"
        \\.global __uhdr
        \\__uhdr:
        \\        .ascii  "MOSS"
        \\        .word   0
        \\        .quad   __utext_size
        \\        .quad   __uload_size
        \\        .quad   __umem_size
        \\        .ascii  "net"
        \\        .space  13
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// The device arrives over the boot channel (BootReq cap{device}).
var dev_h: u64 = 0;

export fn umain(log_h: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    // arg: low byte = role; byte 1 = cluster node id (0 = slirp mode).
    switch (arg & 0xff) {
        1 => {
            takeDevice(chan_h);
            netsvc(log_h, chan_h, (arg >> 8) & 0xff);
        },
        2 => echosrv(log_h, boot.take(chan_h).cap(.net)),
        3 => echocli(log_h, boot.take(chan_h).cap(.net)),
        4 => boxed(log_h, boot.take(chan_h).cap(.net)),
        else => usys.exit(250),
    }
}

/// The boot handshake: whoever spawned us hands over the device.
fn takeDevice(chan_h: u64) void {
    const setup = boot.take(chan_h);
    dev_h = setup.device(.net);
    if (dev_h == 0) usys.exit(169);
}

// ------------------------------------------------------------- addresses

const Addr = [16]u8;

fn addrFromWords(hi: u64, lo: u64) Addr {
    var a: Addr = undefined;
    for (0..8) |i| a[i] = @truncate(hi >> @intCast(56 - i * 8));
    for (0..8) |i| a[8 + i] = @truncate(lo >> @intCast(56 - i * 8));
    return a;
}

fn addrEq(a: Addr, b: Addr) bool {
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn isV4Mapped(a: Addr) bool {
    for (0..10) |i| {
        if (a[i] != 0) return false;
    }
    return a[10] == 0xff and a[11] == 0xff;
}

fn v4Of(a: Addr) u32 {
    return be32(a[12..16]);
}

fn v4Addr(ip: u32) Addr {
    var a: Addr = @splat(0);
    a[10] = 0xff;
    a[11] = 0xff;
    pbe32(a[12..16], ip);
    return a;
}

// Slirp mode (node 0) or cluster mode (node N: static 10.77.0.N / fdcc::N,
// everything on-link, broadcast MAC delivery — no gateways to resolve).
var own_ip4: u32 = shared.net_own_ip4;
var gw_ip4: u32 = shared.net_gw_ip4;
var own_ip6: Addr = undefined;
var gw_ip6: Addr = undefined;
var loop6: Addr = undefined; // ::1
var cluster_node: u64 = 0;

fn isLocalAddr(a: Addr) bool {
    if (isV4Mapped(a)) {
        const ip = v4Of(a);
        return ip == own_ip4 or (ip >> 24) == 127;
    }
    return addrEq(a, own_ip6) or addrEq(a, loop6);
}

// ---------------------------------------------------------------- virtio

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };
const desc_f_write = 2;
const qn = 8;
const vnet_hdr = 12;
const frame_cap = 2048;
const n_rx = 8;
const n_tx = 4;

var dev: virtio.Dev = undefined;
var vq_va: u64 = 0;
var vq_dev: u64 = 0;
var rx_va: u64 = 0;
var rx_dev: u64 = 0;
var tx_va: u64 = 0;
var tx_dev: u64 = 0;
var irq_notif: u64 = 0;

const Q = struct { desc: u64, avail: u64, used: u64, idx: u32 };
const rxq: Q = .{ .desc = 0, .avail = 128, .used = 256, .idx = 0 };
const txq: Q = .{ .desc = 512, .avail = 640, .used = 768, .idx = 1 };
var rx_shadow: u16 = 0;
var rx_seen: u16 = 0;
var tx_shadow: u16 = 0;
var tx_seen: u16 = 0;
var tx_free: u8 = (1 << n_tx) - 1;

var mac: [6]u8 = undefined;
var gw_mac: [6]u8 = undefined;
var have_gw4 = false;
var gw6_mac: [6]u8 = undefined;
var have_gw6 = false;

fn qDescs(q: Q) [*]volatile Desc {
    return @ptrFromInt(vq_va + q.desc);
}

fn qAvailIdx(q: Q) *volatile u16 {
    return @ptrFromInt(vq_va + q.avail + 2);
}

fn qAvailRing(q: Q) [*]volatile u16 {
    return @ptrFromInt(vq_va + q.avail + 4);
}

fn qUsedIdx(q: Q) *volatile u16 {
    return @ptrFromInt(vq_va + q.used + 2);
}

fn qUsedElem(q: Q, i: u16) *volatile extern struct { id: u32, len: u32 } {
    return @ptrFromInt(vq_va + q.used + 4 + @as(u64, i % qn) * 8);
}

fn netInit() void {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(170);
    irq_notif = n.data[0];

    dev = virtio.Dev.open(dev_h, .net) orelse {
        usys.exit(172);
    };
    if (usys.irqBind(dev_h, irq_notif, 0) != .ok) usys.exit(173);

    const dma = usys.dmaAlloc(7);
    if (dma.err != .ok) usys.exit(174);
    vq_va = dma.data[0];
    vq_dev = dma.data[1];
    rx_va = vq_va + 4096;
    rx_dev = vq_dev + 4096;
    tx_va = vq_va + 5 * 4096;
    tx_dev = vq_dev + 5 * 4096;

    _ = dev.negotiate(1 << 5, 0) orelse usys.exit(175); // MAC
    for ([_]Q{ rxq, txq }) |q| {
        if (!dev.queueSetup(@intCast(q.idx), qn, vq_dev + q.desc, vq_dev + q.avail, vq_dev + q.used)) usys.exit(176);
    }
    dev.driverOk();

    // Config space is read in aligned words (unaligned MMIO faults).
    const m0 = dev.devRead32(0);
    const m1 = dev.devRead32(4);
    mac = .{
        @truncate(m0),       @truncate(m0 >> 8),
        @truncate(m0 >> 16), @truncate(m0 >> 24),
        @truncate(m1),       @truncate(m1 >> 8),
    };

    for (0..n_rx) |i| {
        qDescs(rxq)[i] = .{
            .addr = rx_dev + i * frame_cap,
            .len = frame_cap,
            .flags = desc_f_write,
            .next = 0,
        };
        qAvailRing(rxq)[rx_shadow % qn] = @intCast(i);
        rx_shadow +%= 1;
    }
    asm volatile ("dmb ish");
    qAvailIdx(rxq).* = rx_shadow;
    asm volatile ("dmb ish");
    dev.notify(@intCast(rxq.idx));
}

fn wireTx(frame: []const u8) void {
    if (tx_free == 0) drainTxUsed();
    if (tx_free == 0) return; // drop; stop-and-wait retransmits recover
    var slot: u3 = 0;
    while (tx_free & (@as(u8, 1) << slot) == 0) slot += 1;
    tx_free &= ~(@as(u8, 1) << slot);

    const buf: [*]u8 = @ptrFromInt(tx_va + @as(u64, slot) * frame_cap);
    @memset(buf[0..vnet_hdr], 0);
    @memcpy(buf[vnet_hdr .. vnet_hdr + frame.len], frame);
    qDescs(txq)[slot] = .{
        .addr = tx_dev + @as(u64, slot) * frame_cap,
        .len = @intCast(vnet_hdr + frame.len),
        .flags = 0,
        .next = 0,
    };
    qAvailRing(txq)[tx_shadow % qn] = slot;
    tx_shadow +%= 1;
    asm volatile ("dmb ish");
    qAvailIdx(txq).* = tx_shadow;
    asm volatile ("dmb ish");
    dev.notify(@intCast(txq.idx));
}

fn drainTxUsed() void {
    while (tx_seen != qUsedIdx(txq).*) {
        const e = qUsedElem(txq, tx_seen);
        tx_free |= @as(u8, 1) << @intCast(e.id);
        tx_seen +%= 1;
    }
}

fn drainRxUsed() void {
    while (rx_seen != qUsedIdx(rxq).*) {
        asm volatile ("dmb ish");
        const e = qUsedElem(rxq, rx_seen);
        const buf: [*]const u8 = @ptrFromInt(rx_va + @as(u64, e.id) * frame_cap);
        if (e.len > vnet_hdr) etherInput(buf[vnet_hdr..e.len]);
        qAvailRing(rxq)[rx_shadow % qn] = @intCast(e.id);
        rx_shadow +%= 1;
        asm volatile ("dmb ish");
        qAvailIdx(rxq).* = rx_shadow;
        rx_seen +%= 1;
    }
    dev.notify(@intCast(rxq.idx));
}

fn netTick() void {
    drainRxUsed();
    drainTxUsed();
    retransmitScan();
}

fn irqDrain() void {
    _ = dev.isrRead();
    _ = usys.irqAck(dev_h, 0);
    netTick();
}

// ----------------------------------------------------------- link layer

fn etherInput(frame: []const u8) void {
    if (frame.len < 14) return;
    const ethertype = (@as(u16, frame[12]) << 8) | frame[13];
    switch (ethertype) {
        0x0806 => arpInput(frame[14..]),
        0x0800 => ip4Input(frame[14..]),
        0x86dd => ip6Input(frame[14..]),
        else => {},
    }
}

fn ethSend(dst_mac: []const u8, ethertype: u16, payload: []const u8) void {
    var frame: [14 + 40 + seg_max + 4]u8 = undefined;
    @memcpy(frame[0..6], dst_mac);
    @memcpy(frame[6..12], &mac);
    frame[12] = @truncate(ethertype >> 8);
    frame[13] = @truncate(ethertype);
    @memcpy(frame[14 .. 14 + payload.len], payload);
    wireTx(frame[0 .. 14 + payload.len]);
}

// -------------------------------------------------------------- ARP (v4)

fn arpInput(p: []const u8) void {
    if (p.len < 28) return;
    const op = (@as(u16, p[6]) << 8) | p[7];
    const spa = be32(p[14..18]);
    if (op == 2 and spa == gw_ip4) {
        @memcpy(&gw_mac, p[8..14]);
        have_gw4 = true;
    } else if (op == 1 and be32(p[24..28]) == own_ip4) {
        var reply: [28]u8 = undefined;
        arpFill(&reply, 2, p[8..14], spa);
        ethSend(p[8..14], 0x0806, &reply);
    }
}

fn arpFill(p: *[28]u8, op: u16, target_mac: []const u8, target_ip: u32) void {
    p[0] = 0;
    p[1] = 1;
    p[2] = 0x08;
    p[3] = 0;
    p[4] = 6;
    p[5] = 4;
    p[6] = @truncate(op >> 8);
    p[7] = @truncate(op);
    @memcpy(p[8..14], &mac);
    pbe32(p[14..18], own_ip4);
    @memcpy(p[18..24], target_mac);
    pbe32(p[24..28], target_ip);
}

fn arpRequestGw() void {
    var req: [28]u8 = undefined;
    const zero_mac = [_]u8{0} ** 6;
    arpFill(&req, 1, &zero_mac, gw_ip4);
    const bcast = [_]u8{0xff} ** 6;
    ethSend(&bcast, 0x0806, &req);
}

// ------------------------------------------------------------- NDP (v6)

/// Emit an ICMPv6 packet (checksummed here) from own_ip6 to dst.
fn icmp6Send(dst: Addr, dst_mac: []const u8, body: []const u8) void {
    var pkt: [40 + 64]u8 = undefined;
    pkt[0] = 0x60;
    pkt[1] = 0;
    pkt[2] = 0;
    pkt[3] = 0;
    pbe16(pkt[4..6], @intCast(body.len));
    pkt[6] = 58; // ICMPv6
    pkt[7] = 255; // hop limit (NDP requires 255)
    @memcpy(pkt[8..24], &own_ip6);
    @memcpy(pkt[24..40], &dst);
    @memcpy(pkt[40 .. 40 + body.len], body);
    // Checksum over pseudo-header + body.
    var sum: u32 = partial(pkt[8..40], 0); // src+dst
    var lenw: [4]u8 = undefined;
    pbe32(&lenw, @intCast(body.len));
    sum = partial(&lenw, sum);
    sum += 58;
    sum = partial(pkt[40 .. 40 + body.len], sum);
    const c = fold(sum);
    pkt[42] = @truncate(c >> 8);
    pkt[43] = @truncate(c);
    ethSend(dst_mac, 0x86dd, pkt[0 .. 40 + body.len]);
}

fn ndpSolicitGw() void {
    // NS to the solicited-node multicast of fec0::2.
    var body: [32]u8 = @splat(0);
    body[0] = 135; // neighbor solicitation
    @memcpy(body[8..24], &gw_ip6);
    body[24] = 1; // option: source link-layer address
    body[25] = 1;
    @memcpy(body[26..32], &mac);
    var dst: Addr = @splat(0);
    dst[0] = 0xff;
    dst[1] = 0x02;
    dst[11] = 0x01;
    dst[12] = 0xff;
    @memcpy(dst[13..16], gw_ip6[13..16]);
    var dmac: [6]u8 = .{ 0x33, 0x33, 0xff, gw_ip6[13], gw_ip6[14], gw_ip6[15] };
    icmp6Send(dst, &dmac, &body);
}

var ping_replies: u64 = 0;
var ping_seq: u16 = 0;

fn icmp6Input(src: Addr, body: []const u8) void {
    if (body.len < 8) return;
    switch (body[0]) {
        136 => { // neighbor advertisement
            if (body.len < 24) return;
            var target: Addr = undefined;
            @memcpy(&target, body[8..24]);
            if (addrEq(target, gw_ip6)) {
                // Find the target link-layer option (type 2).
                var off: usize = 24;
                while (off + 8 <= body.len) {
                    if (body[off] == 2 and body[off + 1] == 1) {
                        @memcpy(&gw6_mac, body[off + 2 .. off + 8]);
                        have_gw6 = true;
                        return;
                    }
                    off += @as(usize, body[off + 1]) * 8;
                    if (body[off - 8 + 1] == 0) return;
                }
            }
        },
        135 => { // neighbor solicitation for us -> advertise
            if (body.len < 24) return;
            var target: Addr = undefined;
            @memcpy(&target, body[8..24]);
            if (!addrEq(target, own_ip6)) return;
            var na: [32]u8 = @splat(0);
            na[0] = 136;
            na[4] = 0x60; // solicited + override
            @memcpy(na[8..24], &own_ip6);
            na[24] = 2; // option: target link-layer address
            na[25] = 1;
            @memcpy(na[26..32], &mac);
            if (have_gw6) {
                icmp6Send(src, &gw6_mac, &na);
            }
        },
        129 => ping_replies += 1, // echo reply
        128 => { // echo request -> reply
            var rep: [64]u8 = undefined;
            const n = @min(body.len, 64);
            @memcpy(rep[0..n], body[0..n]);
            rep[0] = 129;
            rep[2] = 0;
            rep[3] = 0;
            if (have_gw6) icmp6Send(src, &gw6_mac, rep[0..n]);
        },
        else => {},
    }
}

fn ping6(dst: Addr) void {
    var body: [16]u8 = @splat(0);
    body[0] = 128;
    pbe16(body[4..6], 0x6d73); // id "ms"
    ping_seq +%= 1;
    pbe16(body[6..8], ping_seq);
    @memcpy(body[8..16], "mossping");
    if (isLocalAddr(dst)) {
        ping_replies += 1; // pinging yourself always works
        return;
    }
    if (have_gw6) icmp6Send(dst, &gw6_mac, &body);
}

fn ping4(ip: u32) void {
    // v4 ICMP echo via the gateway.
    var pkt: [20 + 16]u8 = undefined;
    pkt[0] = 0x45;
    pkt[1] = 0;
    pbe16(pkt[2..4], 36);
    pkt[4] = 0;
    pkt[5] = 0;
    pkt[6] = 0x40;
    pkt[7] = 0;
    pkt[8] = 64;
    pkt[9] = 1; // ICMP
    pkt[10] = 0;
    pkt[11] = 0;
    pbe32(pkt[12..16], own_ip4);
    pbe32(pkt[16..20], ip);
    const ipsum = csum(pkt[0..20], 0);
    pkt[10] = @truncate(ipsum >> 8);
    pkt[11] = @truncate(ipsum);
    var b = pkt[20..];
    b[0] = 8;
    b[1] = 0;
    b[2] = 0;
    b[3] = 0;
    pbe16(b[4..6], 0x6d73);
    ping_seq +%= 1;
    pbe16(b[6..8], ping_seq);
    @memcpy(b[8..16], "mossping");
    const ic = csum(b[0..16], 0);
    b[2] = @truncate(ic >> 8);
    b[3] = @truncate(ic);
    if (have_gw4) ethSend(&gw_mac, 0x0800, &pkt);
}

// ------------------------------------------------------------- IP input

fn ip4Input(p: []const u8) void {
    if (p.len < 20 or p[0] >> 4 != 4) return;
    const ihl: usize = @as(usize, p[0] & 0xf) * 4;
    const total = (@as(usize, p[2]) << 8) | p[3];
    if (total > p.len or ihl < 20) return;
    if (be32(p[16..20]) != own_ip4) return;
    const src = v4Addr(be32(p[12..16]));
    switch (p[9]) {
        6 => tcpInput(src, p[ihl..total]),
        1 => { // ICMP
            const b = p[ihl..total];
            if (b.len >= 8 and b[0] == 0) ping_replies += 1;
        },
        else => {},
    }
}

fn ip6Input(p: []const u8) void {
    if (p.len < 40 or p[0] >> 4 != 6) return;
    const plen = (@as(usize, p[4]) << 8) | p[5];
    if (40 + plen > p.len) return;
    var dst: Addr = undefined;
    @memcpy(&dst, p[24..40]);
    // Accept our unicast plus solicited-node/all-nodes multicast.
    if (!addrEq(dst, own_ip6) and dst[0] != 0xff) return;
    var src: Addr = undefined;
    @memcpy(&src, p[8..24]);
    switch (p[6]) {
        6 => tcpInput(src, p[40 .. 40 + plen]),
        58 => icmp6Input(src, p[40 .. 40 + plen]),
        else => {},
    }
}

// ------------------------------------------------------------------- TCP

const F_FIN: u8 = 1;
const F_SYN: u8 = 2;
const F_RST: u8 = 4;
const F_PSH: u8 = 8;
const F_ACK: u8 = 16;

const max_socks = 32;
const backlog_len = 8;
/// Receive buffer: also the window we advertise (free space in it).
const rx_cap = 8192;
/// Send buffer: unacknowledged and not-yet-sent bytes, in order.
const snd_cap = 4096;
/// The largest segment we send or accept (1500 MTU minus v6 + TCP
/// headers, and what we announce in the SYN's MSS option).
const mss_max = 1440;
const mss_default = 536;
const seg_max = 20 + mss_max;
const max_rexmits = 8;

const Sock = struct {
    used: bool = false,
    /// The stack keeps a socket after its client closed it (FIN sent)
    /// until the FIN is acknowledged or retransmission gives up; the
    /// client's number is gone the moment it closed.
    lingering: bool = false,
    badge: u64 = 0,
    state: shared.TcpState = .closed,
    lport: u16 = 0,
    raddr: Addr = @splat(0),
    rport: u16 = 0,
    /// Send side. Bytes [snd_una, snd_end) live in snd_buf (a ring at
    /// snd_head); [snd_una, snd_nxt) are in flight, [snd_nxt, snd_end)
    /// wait for the window.
    snd_buf: [snd_cap]u8 = undefined,
    snd_head: usize = 0,
    snd_una: u32 = 0,
    snd_nxt: u32 = 0,
    snd_end: u32 = 0,
    /// The peer's advertised window (no scaling), and its MSS. Zero
    /// defaults keep the table in .bss (sockAlloc sets them).
    snd_wnd: u32 = 0,
    mss: u32 = 0,
    /// Control segments in flight: the SYN (syn_sent, syn_rcvd) and the
    /// FIN, which take one sequence number each.
    fin_sent: bool = false,
    fin_seq: u32 = 0,
    /// The oldest unacknowledged thing was (re)sent at `sent_at`;
    /// `rexmits` retries so far, `rto` the current timeout.
    sent_at: u64 = 0,
    rexmits: u32 = 0,
    rto: u64 = 0,
    in_output: bool = false,
    /// Receive side: in-order bytes the client has not taken yet.
    rcv_nxt: u32 = 0,
    rx: [rx_cap]u8 = undefined,
    rx_len: usize = 0,
    /// Listener backlog: accepted-but-not-yet-taken connections, FIFO.
    /// One slot was a bug: a second SYN overwrote the first, orphaning an
    /// established socket whose data nobody would ever read.
    backlog: [backlog_len]u8 = @splat(0),
    backlog_n: u8 = 0,
    peer_closed: bool = false,
    /// Doorbell: a client's notification, rung on every change.
    bell: u64 = 0,

    fn inFlight(s: *const Sock) u32 {
        return s.snd_nxt -% s.snd_una;
    }

    fn queued(s: *const Sock) u32 {
        return s.snd_end -% s.snd_una;
    }

    fn unsent(s: *const Sock) u32 {
        return s.snd_end -% s.snd_nxt;
    }

    /// Anything the peer has yet to acknowledge, control included.
    fn unacked(s: *const Sock) bool {
        return s.state == .syn_sent or s.state == .syn_rcvd or s.inFlight() != 0 or (s.fin_sent and s.snd_una != s.fin_seq +% 1);
    }
};

fn ring(s: *Sock) void {
    if (s.bell != 0) _ = usys.notifySignal(s.bell, 1);
}

var socks: [max_socks]Sock = @splat(.{});
var next_eph: u16 = 40000;

fn sockAlloc() ?usize {
    for (&socks, 0..) |*s, i| {
        if (!s.used) {
            s.* = .{ .used = true, .snd_wnd = mss_default, .mss = mss_default };
            return i;
        }
    }
    return null;
}

/// Sequence-number order, modulo 2^32.
fn seqLt(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) < 0;
}

fn seqLe(a: u32, b: u32) bool {
    return @as(i32, @bitCast(a -% b)) <= 0;
}

fn rtoInitial() u64 {
    return usys.cycleHz() / 5; // 200 ms
}

fn armTimer(s: *Sock) void {
    s.sent_at = usys.cycles();
    if (s.rto == 0) s.rto = rtoInitial();
}

/// Build one TCP segment for either family; loopback feeds the stack.
/// `opts` are TCP options (the SYN's MSS), already padded to 4 bytes.
fn tcpEmit(s: *Sock, seq: u32, flags: u8, opts: []const u8, payload: []const u8) void {
    var t: [seg_max + 4]u8 = undefined;
    const doff = 20 + opts.len;
    const tcp_len = doff + payload.len;
    pbe16(t[0..2], s.lport);
    pbe16(t[2..4], s.rport);
    pbe32(t[4..8], seq);
    pbe32(t[8..12], if (flags & F_ACK != 0) s.rcv_nxt else 0);
    t[12] = @intCast((doff / 4) << 4);
    t[13] = flags;
    pbe16(t[14..16], @intCast(rx_cap - s.rx_len));
    t[16] = 0;
    t[17] = 0;
    pbe16(t[18..20], 0);
    @memcpy(t[20..doff], opts);
    @memcpy(t[doff .. doff + payload.len], payload);

    const v4 = isV4Mapped(s.raddr);
    const local = isLocalAddr(s.raddr);
    const src_addr: Addr = if (local) s.raddr else if (v4) v4Addr(own_ip4) else own_ip6;

    // Checksum: v4 and v6 pseudo-headers differ only in shape.
    var sum: u32 = 0;
    if (v4) {
        var ph: [12]u8 = undefined;
        pbe32(ph[0..4], v4Of(src_addr));
        pbe32(ph[4..8], v4Of(s.raddr));
        ph[8] = 0;
        ph[9] = 6;
        pbe16(ph[10..12], @intCast(tcp_len));
        sum = partial(&ph, 0);
    } else {
        sum = partial(&src_addr, 0);
        sum = partial(&s.raddr, sum);
        var lenw: [4]u8 = undefined;
        pbe32(&lenw, @intCast(tcp_len));
        sum = partial(&lenw, sum);
        sum += 6;
    }
    const tsum = fold(partial(t[0..tcp_len], sum));
    t[16] = @truncate(tsum >> 8);
    t[17] = @truncate(tsum);

    if (local) {
        tcpInput(src_addr, t[0..tcp_len]);
        return;
    }
    if (v4) {
        var pkt: [20 + seg_max + 4]u8 = undefined;
        const total = 20 + tcp_len;
        pkt[0] = 0x45;
        pkt[1] = 0;
        pbe16(pkt[2..4], @intCast(total));
        pkt[4] = 0;
        pkt[5] = 0;
        pkt[6] = 0x40;
        pkt[7] = 0;
        pkt[8] = 64;
        pkt[9] = 6;
        pkt[10] = 0;
        pkt[11] = 0;
        pbe32(pkt[12..16], own_ip4);
        pbe32(pkt[16..20], v4Of(s.raddr));
        const ipsum = csum(pkt[0..20], 0);
        pkt[10] = @truncate(ipsum >> 8);
        pkt[11] = @truncate(ipsum);
        @memcpy(pkt[20 .. 20 + tcp_len], t[0..tcp_len]);
        if (have_gw4) ethSend(&gw_mac, 0x0800, pkt[0..total]);
    } else {
        var pkt: [40 + seg_max + 4]u8 = undefined;
        pkt[0] = 0x60;
        pkt[1] = 0;
        pkt[2] = 0;
        pkt[3] = 0;
        pbe16(pkt[4..6], @intCast(tcp_len));
        pkt[6] = 6;
        pkt[7] = 64;
        @memcpy(pkt[8..24], &own_ip6);
        @memcpy(pkt[24..40], &s.raddr);
        @memcpy(pkt[40 .. 40 + tcp_len], t[0..tcp_len]);
        if (have_gw6) ethSend(&gw6_mac, 0x86dd, pkt[0 .. 40 + tcp_len]);
    }
}

/// The MSS option we announce.
fn mssOption() [4]u8 {
    return .{ 2, 4, mss_max >> 8, mss_max & 0xff };
}

/// Send the SYN (or SYN+ACK): tracked by state, retransmitted by the
/// scan. ALL bookkeeping before emitting: on loopback, tcpEmit
/// synchronously runs the peer's processing — including the reply
/// that moves this socket along — so anything written after emit would
/// clobber a completed exchange.
fn tcpSendSyn(s: *Sock, flags: u8) void {
    const seq = s.snd_nxt;
    s.snd_una = seq;
    s.snd_nxt = seq +% 1;
    s.snd_end = s.snd_nxt;
    s.rexmits = 0;
    s.rto = 0;
    armTimer(s);
    tcpEmit(s, seq, flags, &mssOption(), "");
}

/// Send the FIN once everything queued has gone out.
fn tcpSendFin(s: *Sock) void {
    if (s.fin_sent) return;
    s.fin_sent = true;
    s.fin_seq = s.snd_nxt;
    s.snd_nxt +%= 1;
    s.snd_end = s.snd_nxt;
    if (s.inFlight() == 1) {
        s.rexmits = 0;
        s.rto = 0;
        armTimer(s);
    }
    tcpEmit(s, s.fin_seq, F_FIN | F_ACK, "", "");
}

/// A slice of the send ring starting at sequence `seq`, at most `len`
/// bytes, copied out (the ring may wrap).
fn sndSlice(s: *Sock, seq: u32, len: usize, out: []u8) []const u8 {
    const off: usize = @intCast(seq -% s.snd_una);
    const n = @min(len, out.len);
    for (0..n) |i| out[i] = s.snd_buf[(s.snd_head + off + i) % snd_cap];
    return out[0..n];
}

/// Send what the window allows: segments of at most `mss` while the
/// peer's window has room. Reentrant-safe: on loopback an emit runs
/// the peer, whose ACK can call back in here; the inner call returns
/// and the outer loop re-reads the state it changed.
fn tcpOutput(s: *Sock) void {
    if (s.in_output) return;
    if (s.state != .established and s.state != .close_wait) return;
    s.in_output = true;
    defer s.in_output = false;
    var scratch: [mss_max]u8 = undefined;
    while (true) {
        const pending = s.unsent();
        if (pending == 0) break;
        if (s.fin_sent and s.snd_nxt == s.fin_seq) break; // only the FIN is left
        const window = @max(s.snd_wnd, 1);
        const flight = s.inFlight();
        if (flight >= window) break;
        var len: u32 = @min(pending, window - flight);
        len = @min(len, s.mss);
        if (s.fin_sent) len = @min(len, s.fin_seq -% s.snd_nxt);
        if (len == 0) break;
        const seq = s.snd_nxt;
        const data = sndSlice(s, seq, len, &scratch);
        s.snd_nxt +%= len;
        if (flight == 0) {
            s.rexmits = 0;
            s.rto = 0;
            armTimer(s);
        }
        tcpEmit(s, seq, F_PSH | F_ACK, "", data);
    }
}

/// Retransmit the oldest unacknowledged thing on every socket whose
/// timer expired, doubling the timeout each time; give up after
/// max_rexmits and close (the doorbell rings).
fn retransmitScan() void {
    const now = usys.cycles();
    for (&socks) |*s| {
        if (!s.used or !s.unacked()) continue;
        if (now - s.sent_at < s.rto) continue;
        if (s.rexmits >= max_rexmits) {
            sockDead(s);
            continue;
        }
        s.rexmits += 1;
        s.rto = @min(s.rto * 2, rtoInitial() * 16);
        s.sent_at = now;
        switch (s.state) {
            .syn_sent => tcpEmit(s, s.snd_una, F_SYN, &mssOption(), ""),
            .syn_rcvd => tcpEmit(s, s.snd_una, F_SYN | F_ACK, &mssOption(), ""),
            else => {
                if (s.inFlight() != 0 and !(s.fin_sent and s.snd_una == s.fin_seq)) {
                    var scratch: [mss_max]u8 = undefined;
                    const len: u32 = @min(@min(s.inFlight(), s.mss), if (s.fin_sent) s.fin_seq -% s.snd_una else s.mss);
                    const data = sndSlice(s, s.snd_una, len, &scratch);
                    tcpEmit(s, s.snd_una, F_PSH | F_ACK, "", data);
                } else if (s.fin_sent) {
                    tcpEmit(s, s.fin_seq, F_FIN | F_ACK, "", "");
                }
            },
        }
    }
}

/// The connection is gone (RST, or retransmission gave up): the client
/// learns `closed`; a lingering socket is simply freed.
fn sockDead(s: *Sock) void {
    if (s.lingering) {
        s.* = .{};
        return;
    }
    s.state = .closed;
    s.snd_nxt = s.snd_una;
    s.snd_end = s.snd_una;
    s.fin_sent = false;
    ring(s);
}

fn tcpInput(src: Addr, seg: []const u8) void {
    if (seg.len < 20) return;
    const sport = be16(seg[0..2]);
    const dport = be16(seg[2..4]);
    const seq = be32(seg[4..8]);
    const ack = be32(seg[8..12]);
    const doff: usize = @as(usize, seg[12] >> 4) * 4;
    const flags = seg[13];
    const wnd = be16(seg[14..16]);
    if (doff < 20 or doff > seg.len) return;
    const payload = seg[doff..];

    for (&socks) |*s| {
        if (!s.used or s.state == .listen or s.state == .closed) continue;
        if (s.lport != dport or s.rport != sport or !addrEq(s.raddr, src)) continue;
        sockInput(s, seq, ack, flags, wnd, seg[20..doff], payload);
        return;
    }
    if (flags & F_SYN != 0 and flags & F_ACK == 0) {
        for (&socks) |*l| {
            if (!l.used or l.state != .listen or l.lport != dport) continue;
            // Backlog full: drop the SYN; the client's SYN retransmit retries.
            if (l.backlog_n == backlog_len) return;
            const ci = sockAlloc() orelse return;
            const c = &socks[ci];
            c.badge = l.badge;
            c.state = .syn_rcvd;
            c.lport = dport;
            c.raddr = src;
            c.rport = sport;
            c.rcv_nxt = seq +% 1;
            c.snd_wnd = wnd;
            c.mss = peerMss(seg[20..doff]);
            c.snd_nxt = @truncate(usys.cycles());
            l.backlog[l.backlog_n] = @intCast(ci);
            l.backlog_n += 1;
            tcpSendSyn(c, F_SYN | F_ACK);
            ring(l);
            return;
        }
    }
}

/// The peer's MSS option, if it sent one; capped at what we send.
fn peerMss(opts: []const u8) u32 {
    var i: usize = 0;
    while (i < opts.len) {
        const kind = opts[i];
        if (kind == 0) break;
        if (kind == 1) {
            i += 1;
            continue;
        }
        if (i + 1 >= opts.len) break;
        const len = opts[i + 1];
        if (len < 2 or i + len > opts.len) break;
        if (kind == 2 and len == 4) {
            const m = be16(opts[i + 2 .. i + 4]);
            return @min(@max(m, 64), mss_max);
        }
        i += len;
    }
    return mss_default;
}

fn sockInput(s: *Sock, seq: u32, ack: u32, flags: u8, wnd: u16, opts: []const u8, payload: []const u8) void {
    defer if (!s.lingering) ring(s);
    if (flags & F_RST != 0) {
        sockDead(s);
        return;
    }
    if (flags & F_ACK != 0) {
        // A cumulative ACK: drop what it covers from the send ring.
        if (seqLt(s.snd_una, ack) and seqLe(ack, s.snd_nxt)) {
            var covered: u32 = ack -% s.snd_una;
            if (s.state == .syn_sent or s.state == .syn_rcvd) covered -= 1; // the SYN
            if (s.fin_sent and ack == s.fin_seq +% 1) covered -= 1; // the FIN
            s.snd_head = (s.snd_head + covered) % snd_cap;
            s.snd_una = ack;
            s.rexmits = 0;
            s.rto = 0;
            if (s.unacked()) armTimer(s);
            if (s.state == .syn_rcvd) {
                s.state = .established;
                // The listener's client waits on accept; the newly
                // established socket is what it will take.
                for (&socks) |*l| {
                    if (l.used and l.state == .listen and l.lport == s.lport) ring(l);
                }
            }
        }
        s.snd_wnd = wnd;
    }
    switch (s.state) {
        .syn_sent => {
            if (flags & F_SYN != 0 and flags & F_ACK != 0 and ack == s.snd_nxt) {
                s.rcv_nxt = seq +% 1;
                s.mss = peerMss(opts);
                s.state = .established;
                tcpEmit(s, s.snd_nxt, F_ACK, "", "");
            }
            return;
        },
        .established, .close_wait => {},
        else => return,
    }
    var advance = false;
    if (payload.len > 0 and seq == s.rcv_nxt) {
        const room = rx_cap - s.rx_len;
        if (s.lingering) {
            // Nobody will read it; acknowledge and drop.
            s.rcv_nxt +%= @intCast(payload.len);
            advance = true;
        } else if (payload.len <= room) {
            @memcpy(s.rx[s.rx_len .. s.rx_len + payload.len], payload);
            s.rx_len += payload.len;
            s.rcv_nxt +%= @intCast(payload.len);
            advance = true;
        }
    }
    if (flags & F_FIN != 0 and seq +% @as(u32, @intCast(payload.len)) == s.rcv_nxt) {
        s.rcv_nxt +%= 1;
        s.peer_closed = true;
        s.state = .close_wait;
        advance = true;
    }
    if (advance or payload.len > 0) {
        tcpEmit(s, s.snd_nxt, F_ACK, "", "");
    }
    // A lingering socket is done once its FIN is acknowledged and the
    // peer has closed too (or just acknowledged: a half-open peer may
    // never close, and the socket is not worth keeping for it).
    if (s.lingering and s.fin_sent and s.snd_una == s.fin_seq +% 1) {
        s.* = .{};
        return;
    }
    // The ACK may have opened the window.
    tcpOutput(s);
}

// ---------------------------------------------------------- serving views

const max_views = 16;
const NetView = struct {
    used: bool = false,
    filtered: bool = false,
    allow: Addr = @splat(0),
    allow_port: u16 = 0,
    buf: u64 = 0,
};

var views: [max_views]NetView = @splat(.{});
var serve_a: u64 = 0;

fn netsvc(log_h: u64, chan_h: u64, node: u64) noreturn {
    cluster_node = node;
    loop6 = @splat(0);
    loop6[15] = 1;
    if (node == 0) {
        own_ip6 = addrFromWords(shared.net_own_ip6[0], shared.net_own_ip6[1]);
        gw_ip6 = addrFromWords(shared.net_gw_ip6[0], shared.net_gw_ip6[1]);
    } else {
        own_ip4 = shared.nodeIp4(node);
        own_ip6 = addrFromWords(0xfdcc_0000_0000_0000, node);
        gw_ip6 = @splat(0);
    }

    serve_a = chan_h;
    netInit();
    _ = usys.log(log_h, "netsvc: nic up, resolving gateways");

    if (node == 0) {
        // Slirp: resolve both gateways before serving anyone.
        var tries: u32 = 0;
        while (!have_gw4 or !have_gw6) {
            if (!have_gw4) arpRequestGw();
            if (!have_gw6) ndpSolicitGw();
            _ = usys.notifyWait(irq_notif);
            irqDrain();
            tries += 1;
            if (tries > 50) usys.exit(177);
        }
    } else {
        // Cluster: a private segment of known peers; broadcast delivery
        // stands in for neighbor discovery (peers filter by IP).
        gw_mac = @splat(0xff);
        gw6_mac = @splat(0xff);
        have_gw4 = true;
        have_gw6 = true;
    }
    if (usys.notifyBind(irq_notif) != .ok) usys.exit(178);
    _ = usys.log(log_h, "netsvc: virtio-net up, serving");

    views[0] = .{ .used = true }; // badge 0: unrestricted root view

    while (true) {
        const r = usys.recvMsg(serve_a);
        if (r.err == .interrupted) {
            _ = usys.notifyWait(irq_notif);
            irqDrain();
            continue;
        }
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err == .client_dead) {
            releaseView(r.badge);
            continue;
        }
        if (r.err != .ok) usys.exit(179);
        netTick();
        const req = shared.decodeMsg(shared.NetReq, r.data) orelse {
            nreply(nerr(.bad));
            continue;
        };
        const v = if (r.badge < max_views and views[r.badge].used) &views[r.badge] else {
            nreply(nerr(.bad));
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        if (v.buf != 0) _ = usys.shmUnmap(v.buf);
                        v.buf = m.data[0];
                    }
                    _ = usys.capDrop(r.cap); // the mapping keeps its own ref
                }
                nreply(.ok);
            },
            .tcp_listen => |q| nreply(opListen(v, r.badge, q.port)),
            .tcp_connect => |q| nreply(opConnect(v, r.badge, q.ip_hi, q.ip_lo, q.port)),
            .tcp_status => |q| nreply(opStatus(r.badge, q.sock)),
            .tcp_accept => |q| nreply(opAccept(r.badge, q.sock)),
            .tcp_send => |q| nreply(opSend(v, r.badge, q.sock, q.len)),
            .tcp_recv => |q| nreply(opRecv(v, r.badge, q.sock, q.len)),
            .tcp_close => |q| nreply(opClose(r.badge, q.sock)),
            .ping => |q| nreply(opPing(v, q.ip_hi, q.ip_lo)),
            .ping_check => nreply(.{ .num = .{ .n = ping_replies } }),
            .derive => |q| opDerive(v, q.ip_hi, q.ip_lo, q.port),
            .watch => |q| nreply(opWatch(r.badge, q.sock, r.cap)),
        }
    }
}

fn nreply(resp: shared.NetResp) void {
    _ = usys.replyTyped(shared.NetResp, serve_a, resp, 0);
}

fn nerr(code: shared.NetErr) shared.NetResp {
    return .{ .net_err = .{ .code = @intFromEnum(code) } };
}

fn sockOf(badge: u64, idx: u64) ?*Sock {
    if (idx >= max_socks) return null;
    const s = &socks[idx];
    if (!s.used or s.lingering or s.badge != badge) return null;
    return s;
}

fn opListen(v: *NetView, badge: u64, port: u64) shared.NetResp {
    if (v.filtered) return nerr(.denied);
    if (port == 0 or port > 65535) return nerr(.bad);
    const i = sockAlloc() orelse return nerr(.no_space);
    socks[i].badge = badge;
    socks[i].state = .listen;
    socks[i].lport = @intCast(port);
    return .{ .num = .{ .n = i } };
}

fn opConnect(v: *NetView, badge: u64, hi: u64, lo: u64, port: u64) shared.NetResp {
    if (port == 0 or port > 65535) return nerr(.bad);
    const dst = addrFromWords(hi, lo);
    if (v.filtered) {
        if (!addrEq(dst, v.allow) or port != v.allow_port) return nerr(.denied);
    }
    const i = sockAlloc() orelse return nerr(.no_space);
    const s = &socks[i];
    s.badge = badge;
    s.state = .syn_sent;
    s.lport = next_eph;
    next_eph +%= 1;
    if (next_eph < 40000) next_eph = 40000;
    s.raddr = dst;
    s.rport = @intCast(port);
    s.snd_nxt = @truncate(usys.cycles());
    tcpSendSyn(s, F_SYN);
    return .{ .num = .{ .n = i } };
}

fn opStatus(badge: u64, idx: u64) shared.NetResp {
    const s = sockOf(badge, idx) orelse return nerr(.bad);
    return .{ .num = .{ .n = @intFromEnum(s.state) } };
}

fn opAccept(badge: u64, idx: u64) shared.NetResp {
    const l = sockOf(badge, idx) orelse return nerr(.bad);
    if (l.state != .listen) return nerr(.bad);
    // Heads that never completed (SYN|ACK retransmits exhausted) are
    // discarded so they cannot block the queue behind them.
    while (l.backlog_n > 0 and socks[l.backlog[0]].state == .closed) {
        socks[l.backlog[0]] = .{};
        backlogPop(l);
    }
    if (l.backlog_n == 0) return nerr(.would_block);
    const ci: u64 = l.backlog[0];
    if (socks[ci].state != .established) return nerr(.would_block);
    backlogPop(l);
    return .{ .num = .{ .n = ci } };
}

fn backlogPop(l: *Sock) void {
    for (1..l.backlog_n) |i| l.backlog[i - 1] = l.backlog[i];
    l.backlog_n -= 1;
}

/// Queue the payload whole (or would_block: a partial send would leave
/// a client that assumes all-or-nothing with a torn message) and send
/// what the window allows.
fn opSend(v: *NetView, badge: u64, idx: u64, len: u64) shared.NetResp {
    const s = sockOf(badge, idx) orelse return nerr(.bad);
    if (s.state != .established and s.state != .close_wait) return nerr(.closed);
    if (v.buf == 0 or len == 0 or len > shared.net_max_send) return nerr(.bad);
    if (s.fin_sent) return nerr(.closed);
    const free = snd_cap - s.queued();
    if (len > free) return nerr(.would_block);
    const src = @as([*]const u8, @ptrFromInt(v.buf))[0..len];
    const tail = (s.snd_head + s.queued()) % snd_cap;
    for (src, 0..) |c, i| s.snd_buf[(tail + i) % snd_cap] = c;
    s.snd_end +%= @intCast(len);
    tcpOutput(s);
    return .{ .num = .{ .n = len } };
}

fn opRecv(v: *NetView, badge: u64, idx: u64, len: u64) shared.NetResp {
    const s = sockOf(badge, idx) orelse return nerr(.bad);
    if (v.buf == 0 or len == 0 or len > shared.net_max_recv) return nerr(.bad);
    if (s.rx_len == 0) {
        if (s.peer_closed or s.state == .closed) return nerr(.closed);
        return nerr(.would_block);
    }
    const n = @min(len, s.rx_len);
    const dst = @as([*]u8, @ptrFromInt(v.buf))[0..n];
    @memcpy(dst, s.rx[0..n]);
    if (n < s.rx_len) {
        for (0..s.rx_len - n) |i| s.rx[i] = s.rx[n + i];
    }
    s.rx_len -= n;
    return .{ .num = .{ .n = n } };
}

fn opWatch(badge: u64, idx: u64, bell: u64) shared.NetResp {
    const s = sockOf(badge, idx) orelse return nerr(.bad);
    if (bell == 0) return nerr(.bad);
    if (s.bell != 0) _ = usys.capDrop(s.bell);
    s.bell = bell;
    // Anything already waiting is news the client has not heard yet.
    if (s.rx_len > 0 or s.backlog_n > 0 or s.peer_closed) ring(s);
    return .ok;
}

/// The client is done with the socket. A connection sends its FIN and
/// lingers in the stack, unaddressable, until the FIN is acknowledged
/// (queued data goes first, the FIN after it) or retransmission gives
/// up; anything else is freed on the spot.
fn opClose(badge: u64, idx: u64) shared.NetResp {
    const s = sockOf(badge, idx) orelse return nerr(.bad);
    if (s.bell != 0) _ = usys.capDrop(s.bell);
    s.bell = 0;
    if (s.state == .established or s.state == .close_wait) {
        s.lingering = true;
        s.badge = 0;
        s.rx_len = 0;
        tcpSendFin(s);
        return .ok;
    }
    s.* = .{};
    return .ok;
}

fn opPing(v: *NetView, hi: u64, lo: u64) shared.NetResp {
    if (v.filtered) return nerr(.denied);
    const dst = addrFromWords(hi, lo);
    if (isV4Mapped(dst)) ping4(v4Of(dst)) else ping6(dst);
    return .ok;
}

/// A client identity died: its sockets close as if it had asked (a FIN
/// where a connection stands), its buffer is unmapped, its slot freed.
fn releaseView(badge: u64) void {
    if (badge == 0 or badge >= max_views or !views[badge].used) return;
    for (&socks, 0..) |*s, i| {
        if (s.used and !s.lingering and s.badge == badge) _ = opClose(badge, i);
    }
    if (views[badge].buf != 0) _ = usys.shmUnmap(views[badge].buf);
    views[badge] = .{};
}

fn opDerive(v: *NetView, hi: u64, lo: u64, port: u64) void {
    if (v.filtered) {
        nreply(nerr(.denied));
        return;
    }
    var slot: usize = 0;
    while (slot < max_views and views[slot].used) slot += 1;
    if (slot == max_views) {
        nreply(nerr(.no_space));
        return;
    }
    // derive(::, 0) clones unrestricted; anything else is an allowlist.
    views[slot] = .{
        .used = true,
        .filtered = !(hi == 0 and lo == 0 and port == 0),
        .allow = addrFromWords(hi, lo),
        .allow_port = @intCast(port),
    };
    const minted = usys.chanMint(serve_a, slot);
    if (minted.err != .ok) {
        views[slot].used = false;
        nreply(nerr(.no_space));
        return;
    }
    _ = usys.replyTyped(shared.NetResp, serve_a, .ok, minted.data[1]);
    _ = usys.capDrop(minted.data[1]);
}

// -------------------------------------------------------------- clients

fn nattach(chan: u64) u64 {
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(220);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(221);
    switch (usys.callTyped(shared.NetReq, shared.NetResp, chan, .attach_buf, s.data[0])) {
        .ok => {},
        .err => usys.exit(222),
    }
    return m.data[0];
}

fn ncall(chan: u64, req: shared.NetReq) shared.NetResp {
    switch (usys.callTyped(shared.NetReq, shared.NetResp, chan, req, 0)) {
        .ok => |rep| return rep,
        .err => usys.exit(223),
    }
}

fn nnum(resp: shared.NetResp) ?u64 {
    return switch (resp) {
        .num => |x| x.n,
        else => null,
    };
}

fn ncode(resp: shared.NetResp) ?shared.NetErr {
    return switch (resp) {
        .net_err => |e| @enumFromInt(e.code),
        else => null,
    };
}

fn connectTo(chan: u64, words: [2]u64, port: u64) ?u64 {
    return nnum(ncall(chan, .{ .tcp_connect = .{
        .ip_hi = words[0],
        .ip_lo = words[1],
        .port = port,
    } }));
}

fn waitEstablished(chan: u64, sock: u64) bool {
    for (0..100) |_| {
        const st = nnum(ncall(chan, .{ .tcp_status = .{ .sock = sock } })) orelse return false;
        if (st == @intFromEnum(shared.TcpState.established)) return true;
        if (st == @intFromEnum(shared.TcpState.closed)) return false;
        usys.sleep(1);
    }
    return false;
}

fn echoRoundTrip(chan: u64, buf: [*]u8, sock: u64, msg: []const u8) bool {
    @memcpy(buf[0..msg.len], msg);
    if (nnum(ncall(chan, .{ .tcp_send = .{ .sock = sock, .len = msg.len } })) == null) usys.exit(150);
    var got: usize = 0;
    var keep: [512]u8 = undefined;
    for (0..200) |_| {
        const resp = ncall(chan, .{ .tcp_recv = .{ .sock = sock, .len = 512 } });
        if (nnum(resp)) |n| {
            @memcpy(keep[got .. got + n], buf[0..n]);
            got += n;
            if (got >= msg.len) break;
            continue;
        }
        if (ncode(resp)) |c| {
            if (c != .would_block) usys.exit(151);
        }
        usys.sleep(1);
    }
    if (got != msg.len) usys.exit(152);
    for (msg, 0..) |c, i| {
        if (keep[i] != c) usys.exit(153);
    }
    return true;
}

fn echosrv(log_h: u64, chan_h: u64) noreturn {
    // The buffer is attached for the view; echoing reuses it server-side
    // (recv lands data exactly where send reads it), so no local access.
    _ = nattach(chan_h);
    const lsock = nnum(ncall(chan_h, .{ .tcp_listen = .{ .port = 7777 } })) orelse usys.exit(230);
    _ = usys.log(log_h, "echosrv: listening on :7777 (any family)");

    for (0..2) |_| { // one v4-mapped guest, one v6 guest
        var child: u64 = 0;
        while (true) {
            const resp = ncall(chan_h, .{ .tcp_accept = .{ .sock = lsock } });
            if (nnum(resp)) |c| {
                child = c;
                break;
            }
            usys.sleep(1);
        }
        while (true) {
            const resp = ncall(chan_h, .{ .tcp_recv = .{ .sock = child, .len = 512 } });
            if (nnum(resp)) |n| {
                _ = ncall(chan_h, .{ .tcp_send = .{ .sock = child, .len = n } });
                continue;
            }
            if (ncode(resp)) |c| {
                if (c == .closed) break;
                if (c != .would_block) usys.exit(231);
            }
            usys.sleep(1);
        }
        _ = ncall(chan_h, .{ .tcp_close = .{ .sock = child } });
    }
    _ = ncall(chan_h, .{ .tcp_close = .{ .sock = lsock } });
    _ = usys.log(log_h, "echosrv: served both families; done");
    usys.exit(0);
}

fn echocli(log_h: u64, chan_h: u64) noreturn {
    const buf: [*]u8 = @ptrFromInt(nattach(chan_h));

    // Leg 1: loopback TCP over v4-mapped addressing.
    const s1 = connectTo(chan_h, shared.v4Words(shared.net_own_ip4), 7777) orelse usys.exit(240);
    if (!waitEstablished(chan_h, s1)) usys.exit(241);
    if (!echoRoundTrip(chan_h, buf, s1, "moss loopback tcp/v4")) usys.exit(242);
    _ = ncall(chan_h, .{ .tcp_close = .{ .sock = s1 } });
    _ = usys.log(log_h, "echocli: loopback echo over v4-mapped verified");

    // Leg 2: loopback TCP over IPv6.
    const s2 = connectTo(chan_h, shared.net_own_ip6, 7777) orelse usys.exit(243);
    if (!waitEstablished(chan_h, s2)) usys.exit(244);
    if (!echoRoundTrip(chan_h, buf, s2, "moss loopback tcp/v6")) usys.exit(245);
    _ = ncall(chan_h, .{ .tcp_close = .{ .sock = s2 } });
    _ = usys.log(log_h, "echocli: loopback echo over IPv6 verified");

    // Leg 3: the v4 wire — virtio-net + slirp to guestfwd cat.
    const s3 = connectTo(chan_h, shared.v4Words(shared.net_echo_ip4), shared.net_echo_port) orelse usys.exit(246);
    if (!waitEstablished(chan_h, s3)) usys.exit(247);
    if (!echoRoundTrip(chan_h, buf, s3, "moss wire tcp")) usys.exit(248);
    _ = ncall(chan_h, .{ .tcp_close = .{ .sock = s3 } });
    _ = usys.log(log_h, "echocli: wire echo via 10.0.2.100:9000 verified");

    // Leg 4: the v6 wire — ICMPv6 echo to the slirp v6 gateway (NDP
    // already proved neighbor discovery; this proves a full round trip).
    const before = nnum(ncall(chan_h, .ping_check)) orelse usys.exit(249);
    _ = ncall(chan_h, .{ .ping = .{ .ip_hi = shared.net_gw_ip6[0], .ip_lo = shared.net_gw_ip6[1] } });
    var ok = false;
    for (0..100) |_| {
        const now = nnum(ncall(chan_h, .ping_check)) orelse usys.exit(249);
        if (now > before) {
            ok = true;
            break;
        }
        usys.sleep(1);
    }
    if (!ok) usys.exit(251);
    _ = usys.log(log_h, "echocli: IPv6 wire round trip (ping fec0::2) verified");
    usys.exit(0);
}

fn boxed(log_h: u64, chan_h: u64) noreturn {
    const buf: [*]u8 = @ptrFromInt(nattach(chan_h));

    const s = connectTo(chan_h, shared.v4Words(shared.net_echo_ip4), shared.net_echo_port) orelse usys.exit(260);
    if (!waitEstablished(chan_h, s)) usys.exit(261);
    if (!echoRoundTrip(chan_h, buf, s, "boxed but allowed")) usys.exit(262);
    _ = ncall(chan_h, .{ .tcp_close = .{ .sock = s } });

    // Everything else is refused, in both families.
    if (ncode(ncall(chan_h, .{ .tcp_connect = .{
        .ip_hi = shared.v4Words(shared.net_gw_ip4)[0],
        .ip_lo = shared.v4Words(shared.net_gw_ip4)[1],
        .port = 9,
    } })) != .denied) usys.exit(263);
    if (ncode(ncall(chan_h, .{ .tcp_connect = .{
        .ip_hi = shared.net_gw_ip6[0],
        .ip_lo = shared.net_gw_ip6[1],
        .port = 9,
    } })) != .denied) usys.exit(264);
    if (ncode(ncall(chan_h, .{ .tcp_connect = .{
        .ip_hi = shared.net_own_ip6[0],
        .ip_lo = shared.net_own_ip6[1],
        .port = 7777,
    } })) != .denied) usys.exit(265);
    if (ncode(ncall(chan_h, .{ .tcp_listen = .{ .port = 8888 } })) != .denied) usys.exit(266);
    if (ncode(ncall(chan_h, .{ .ping = .{ .ip_hi = 0, .ip_lo = 1 } })) != .denied) usys.exit(267);
    if (ncode(ncall(chan_h, .{ .derive = .{ .ip_hi = 0, .ip_lo = 0, .port = 0 } })) != .denied) usys.exit(268);
    _ = usys.log(log_h, "boxed: allowlisted echo worked; v4+v6 gateways, loopback, listen, ping, derive all refused");
    usys.exit(0);
}

// ------------------------------------------------------------- utilities

fn be16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

fn be32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn pbe16(b: []u8, v: u16) void {
    b[0] = @truncate(v >> 8);
    b[1] = @truncate(v);
}

fn pbe32(b: []u8, v: u32) void {
    b[0] = @truncate(v >> 24);
    b[1] = @truncate(v >> 16);
    b[2] = @truncate(v >> 8);
    b[3] = @truncate(v);
}

fn partial(data: []const u8, initial: u32) u32 {
    var sum = initial;
    var i: usize = 0;
    while (i + 1 < data.len) : (i += 2) {
        sum += (@as(u32, data[i]) << 8) | data[i + 1];
    }
    if (i < data.len) sum += @as(u32, data[i]) << 8;
    return sum;
}

fn fold(sum_in: u32) u16 {
    var sum = sum_in;
    while (sum >> 16 != 0) sum = (sum & 0xffff) + (sum >> 16);
    return @intCast(~sum & 0xffff);
}

fn csum(data: []const u8, initial: u32) u16 {
    return fold(partial(data, initial));
}
