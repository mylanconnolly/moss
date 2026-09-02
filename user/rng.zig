//! Entropy: the virtio-rng driver and its probe, by x2 (low byte = role,
//! bits 8..23 = reseed interval in ticks for the driver, 0 = default):
//!   1 "rngd"     — virtio-rng (device id 4) as a userspace process:
//!                  moss's fourth virtio device class through the same
//!                  driver interface (device cap, IRQ-as-notification, DMA
//!                  grant) plus one more cap, `entropy`, which is the only
//!                  way bytes enter the kernel pool. It harvests 64 bytes
//!                  at boot to key the pool, then reseeds on its own sleep
//!                  clock. It serves no channel: consumers use getrandom,
//!                  which is fail-closed until the boot seed lands.
//!   2 "rngprobe" — exercises getrandom/rng_seed after seeding: bytes
//!                  differ call to call and look random, every bad
//!                  argument is refused, and seeding without the entropy
//!                  cap is bad_handle. Exit 0 = all verified.
//!   3 "rngprobe" — before seeding: getrandom must refuse (bad_state).

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
        \\        .ascii  "rng"
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

// rngd receives its caps over its boot channel (shared.BootReq): the
// virtio-rng device and the entropy cap — whoever spawned it decided it
// gets a device; it only learns what each is for.
var dev_h: u64 = 0;
var entropy_h: u64 = 0;

const default_reseed_ticks: u64 = 300; // 30s on the 100ms tick

export fn umain(log_h: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    switch (arg & 0xff) {
        1 => {
            const setup = boot.take(chan_h);
            dev_h = setup.device(.rng);
            entropy_h = setup.cap(.entropy);
            if (dev_h == 0 or entropy_h == 0) {
                _ = usys.log(log_h, "rngd: not handed a device (rng device, entropy); exiting");
                usys.exit(169);
            }
            rngd(log_h, (arg >> 8) & 0xffff);
        },
        2 => probeSeeded(log_h),
        3 => probeUnseeded(log_h),
        else => usys.exit(250),
    }
}

// ------------------------------------------------------------------ rngd

const desc_f_write = 2;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const q_num = 8;
const boot_seed_len: u64 = 64;
const reseed_len: u64 = 32;

var dev: virtio.Dev = undefined;
var irq_notif: u64 = 0;
// DMA: page 0 = the request virtqueue, page 1 = the entropy landing buffer.
var vq_va: u64 = 0;
var vq_dev: u64 = 0;
var buf_va: u64 = 0;
var buf_dev: u64 = 0;
var used_seen: u16 = 0;
var avail_shadow: u16 = 0;

fn rngd(log_h: u64, reseed_arg: u64) noreturn {
    const reseed_ticks = if (reseed_arg == 0) default_reseed_ticks else reseed_arg;

    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(170);
    irq_notif = n.data[0];

    dev = virtio.Dev.open(dev_h, .rng) orelse {
        _ = usys.log(log_h, "rngd: the device handed to us is not a virtio-rng");
        usys.exit(172);
    };
    if (usys.irqBind(dev_h, irq_notif, 0) != .ok) usys.exit(173);

    const dma = usys.dmaAlloc(2);
    if (dma.err != .ok) usys.exit(174);
    vq_va = dma.data[0];
    vq_dev = dma.data[1];
    buf_va = dma.data[0] + 4096;
    buf_dev = dma.data[1] + 4096;

    initDevice();

    // The boot seed keys the pool; getrandom is refused until it lands.
    var seed: [boot_seed_len]u8 = undefined;
    harvest(&seed);
    if (usys.rngSeed(entropy_h, &seed) != .ok) usys.exit(175);
    @memset(&seed, 0);
    _ = usys.log(log_h, "rngd: virtio-rng up; kernel pool seeded (64 bytes)");

    // Reseed on our own clock — the pool's key erasure covers the gaps.
    var reseeds: u64 = 0;
    while (true) {
        usys.sleep(reseed_ticks);
        var more: [reseed_len]u8 = undefined;
        harvest(&more);
        if (usys.rngSeed(entropy_h, &more) != .ok) usys.exit(176);
        @memset(&more, 0);
        reseeds += 1;
        if (reseeds == 1) _ = usys.log(log_h, "rngd: first reseed delivered");
    }
}

fn initDevice() void {
    // VERSION_1 only; virtio-rng defines no device features.
    _ = dev.negotiate(0, 0) orelse usys.exit(177);
    if (!dev.queueSetup(0, q_num, vq_dev, vq_dev + 512, vq_dev + 1024)) usys.exit(178);
    dev.driverOk();
}

/// Fill `out` with device entropy: post one device-writable buffer per
/// round and wait on the IRQ; the device may return fewer bytes than
/// asked, so rounds repeat until the request is complete. The landing
/// buffer is wiped after every copy.
fn harvest(out: []u8) void {
    var got: usize = 0;
    while (got < out.len) {
        const want: u32 = @intCast(out.len - got);
        const descs: [*]volatile Desc = @ptrFromInt(vq_va);
        descs[0] = .{ .addr = buf_dev, .len = want, .flags = desc_f_write, .next = 0 };
        const avail_ring: [*]volatile u16 = @ptrFromInt(vq_va + 512 + 4);
        avail_ring[avail_shadow % q_num] = 0;
        avail_shadow +%= 1;
        const avail_idx: *volatile u16 = @ptrFromInt(vq_va + 512 + 2);
        asm volatile ("dmb ish");
        avail_idx.* = avail_shadow;
        asm volatile ("dmb ish");
        dev.notify(0);

        const used_idx: *volatile u16 = @ptrFromInt(vq_va + 1024 + 2);
        while (used_seen == used_idx.*) {
            _ = usys.notifyWait(irq_notif);
            _ = dev.isrRead();
            _ = usys.irqAck(dev_h, 0);
        }
        asm volatile ("dmb ish");
        const elem: *volatile extern struct { id: u32, len: u32 } =
            @ptrFromInt(vq_va + 1024 + 4 + (used_seen % q_num) * 8);
        const len = @min(elem.len, want);
        used_seen +%= 1;
        const src: [*]volatile u8 = @ptrFromInt(buf_va);
        for (0..len) |k| {
            out[got + k] = src[k];
            src[k] = 0;
        }
        got += len;
    }
}

// ----------------------------------------------------------------- probes

fn probeUnseeded(log_h: u64) noreturn {
    var a: [32]u8 = undefined;
    const e = usys.getrandom(&a);
    if (e != .bad_state) {
        _ = usys.log(log_h, "rngprobe: FAIL — getrandom answered before any seed");
        usys.exit(180);
    }
    _ = usys.log(log_h, "rngprobe: unseeded pool refuses getrandom (bad_state, fail-closed)");
    usys.exit(0);
}

fn probeSeeded(log_h: u64) noreturn {
    var line: [96]u8 = undefined;

    // Two draws: both served, different, not degenerate.
    var a: [32]u8 = @splat(0);
    var b: [32]u8 = @splat(0);
    if (usys.getrandom(&a) != .ok) usys.exit(181);
    if (usys.getrandom(&b) != .ok) usys.exit(182);
    var same = true;
    var zero = true;
    for (a, b) |x, y| {
        if (x != y) same = false;
        if (x != 0) zero = false;
    }
    if (same or zero) usys.exit(183);

    // Argument policing: empty, oversized, unmapped, and read-only targets.
    if (usys.getrandom(a[0..0]) != .bad_arg) usys.exit(184);
    var big: [shared.rng_max_request + 1]u8 = undefined;
    if (usys.getrandom(&big) != .bad_arg) usys.exit(185);
    const unmapped: [*]u8 = @ptrFromInt(0x10);
    if (usys.getrandom(unmapped[0..16]) != .fault) usys.exit(186);
    const text: [*]u8 = @ptrFromInt(shared.user_image_base);
    if (usys.getrandom(text[0..16]) != .fault) usys.exit(187);

    // Seeding needs the entropy cap; this domain holds only a log cap
    // (slot 3 is what a driver's table would hold — empty here).
    const bogus_h: u64 = @bitCast(shared.Handle{ .slot = 3, .generation = 1 });
    if (usys.rngSeed(bogus_h, &a) != .bad_handle) usys.exit(188);
    if (usys.rngSeed(0, &a) != .bad_handle) usys.exit(189);

    // A full-size draw looks like noise: distinct byte values and a
    // balanced bit count (both bounds are many sigmas out).
    if (usys.getrandom(&big[0..shared.rng_max_request].*) != .ok) usys.exit(190);
    var seen: [256]bool = @splat(false);
    var distinct: u64 = 0;
    var ones: u64 = 0;
    for (big[0..shared.rng_max_request]) |x| {
        if (!seen[x]) {
            seen[x] = true;
            distinct += 1;
        }
        ones += @popCount(x);
    }
    if (distinct < 100 or ones < 900 or ones > 1148) {
        _ = usys.log(log_h, numLine(&line, "rngprobe: FAIL — degenerate output, distinct=", distinct));
        usys.exit(191);
    }
    var n = numLine(&line, "rngprobe: getrandom verified — 256B draw: distinct=", distinct).len;
    n += numLine(line[n..], " ones=", ones).len;
    _ = usys.log(log_h, line[0..n]);
    usys.exit(0);
}

fn numLine(buf: []u8, prefix: []const u8, n: u64) []const u8 {
    var i: usize = 0;
    for (prefix) |c| {
        buf[i] = c;
        i += 1;
    }
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v = n;
    while (true) {
        digits[d] = '0' + @as(u8, @intCast(v % 10));
        d += 1;
        v /= 10;
        if (v == 0) break;
    }
    while (d > 0) {
        d -= 1;
        buf[i] = digits[d];
        i += 1;
    }
    return buf[0..i];
}
