//! virtio-blk, in userspace, by x2:
//!   1 "blkdrv"  — the driver: probes the virtio-mmio slots its MMIO cap
//!                 covers, brings up the block device (modern interface,
//!                 split virtqueue), and serves BlkReq on its channel. An
//!                 ordinary sandboxed process: its whole world is one MMIO
//!                 window, one IRQ range, DMA grants, a channel, and a log.
//!   2 "blkuser" — the client: grants a shared buffer, writes a pattern to
//!                 a sector, reads it back, verifies, reports.
//!
//! Handle layout for the driver (insert order log, chan, mmio, irq):
//! mmio = slot 2, irq = slot 3.

const shared = @import("shared");
const usys = @import("usys.zig");

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
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const mmio_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });
const irq_h: u64 = @bitCast(shared.Handle{ .slot = 3, .generation = 1 });

export fn umain(log_h: u64, chan_h: u64, role: u64) callconv(.c) noreturn {
    switch (role) {
        1 => blkdrv(log_h, chan_h),
        2 => blkuser(log_h, chan_h),
        else => usys.exit(250),
    }
}

// ------------------------------------------------------------- the driver

// virtio-mmio registers (modern, version 2).
const R = struct {
    const magic = 0x00;
    const version = 0x04;
    const device_id = 0x08;
    const device_features = 0x10;
    const device_features_sel = 0x14;
    const driver_features = 0x20;
    const driver_features_sel = 0x24;
    const queue_sel = 0x30;
    const queue_num_max = 0x34;
    const queue_num = 0x38;
    const queue_ready = 0x44;
    const queue_notify = 0x50;
    const interrupt_status = 0x60;
    const interrupt_ack = 0x64;
    const status = 0x70;
    const queue_desc_lo = 0x80;
    const queue_desc_hi = 0x84;
    const queue_driver_lo = 0x90;
    const queue_driver_hi = 0x94;
    const queue_device_lo = 0xa0;
    const queue_device_hi = 0xa4;
    const config = 0x100;
};

const status_ack = 1;
const status_driver = 2;
const status_driver_ok = 4;
const status_features_ok = 8;

const desc_f_next = 1;
const desc_f_write = 2;

const queue_size = 8;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

var dev_base: u64 = 0; // this device's register window (VA)
var vq_va: u64 = 0;
var vq_dev: u64 = 0;
var buf_va: u64 = 0;
var buf_dev: u64 = 0;
var notif_h: u64 = 0;
var slot: u64 = 0;
var used_seen: u16 = 0;

fn reg(off: u64) *volatile u32 {
    return @ptrFromInt(dev_base + off);
}

fn blkdrv(log_h: u64, chan_h: u64) noreturn {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(170);
    notif_h = n.data[0];

    const mm = usys.mmioMap(mmio_h);
    if (mm.err != .ok) usys.exit(171);
    const mmio_base = mm.data[0];
    const slots = mm.data[1] / 0x200;

    // Probe for a block device among our slots.
    var found = false;
    var s: u64 = 0;
    while (s < slots) : (s += 1) {
        dev_base = mmio_base + s * 0x200;
        if (reg(R.magic).* == 0x74726976 and
            reg(R.version).* == 2 and
            reg(R.device_id).* == 2)
        {
            found = true;
            slot = s;
            break;
        }
    }
    if (!found) {
        _ = usys.log(log_h, "blkdrv: no virtio-blk device found");
        usys.exit(172);
    }
    if (usys.irqBind(irq_h, notif_h, slot) != .ok) usys.exit(173);

    // DMA: page 0 = virtqueue (descs + avail + used), page 1 = request bufs.
    const dma = usys.dmaAlloc(2);
    if (dma.err != .ok) usys.exit(174);
    vq_va = dma.data[0];
    vq_dev = dma.data[1];
    buf_va = dma.data[0] + 4096;
    buf_dev = dma.data[1] + 4096;

    initDevice();
    const capacity = readCap();
    _ = usys.log(log_h, "blkdrv: virtio-blk up, capacity read, serving");

    var shm_va: u64 = 0;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(175);
        const req = shared.decodeMsg(shared.BlkReq, r.data) orelse continue;
        switch (req) {
            .setup => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) shm_va = m.data[0];
                }
                _ = usys.replyTyped(shared.BlkResp, chan_h, .ok, 0);
            },
            .capacity => {
                _ = usys.replyTyped(shared.BlkResp, chan_h, .{
                    .capacity = .{ .sectors = capacity },
                }, 0);
            },
            .read => |io| {
                if (shm_va == 0) {
                    _ = usys.replyTyped(shared.BlkResp, chan_h, .{ .io_err = .{ .code = 1 } }, 0);
                    continue;
                }
                const code = doIo(0, io.sector); // VIRTIO_BLK_T_IN
                if (code == 0) {
                    copy(@ptrFromInt(shm_va + io.off), @ptrFromInt(buf_va + 16), 512);
                    _ = usys.replyTyped(shared.BlkResp, chan_h, .ok, 0);
                } else {
                    _ = usys.replyTyped(shared.BlkResp, chan_h, .{ .io_err = .{ .code = code } }, 0);
                }
            },
            .write => |io| {
                if (shm_va == 0) {
                    _ = usys.replyTyped(shared.BlkResp, chan_h, .{ .io_err = .{ .code = 1 } }, 0);
                    continue;
                }
                copy(@ptrFromInt(buf_va + 16), @ptrFromInt(shm_va + io.off), 512);
                const code = doIo(1, io.sector); // VIRTIO_BLK_T_OUT
                if (code == 0) {
                    _ = usys.replyTyped(shared.BlkResp, chan_h, .ok, 0);
                } else {
                    _ = usys.replyTyped(shared.BlkResp, chan_h, .{ .io_err = .{ .code = code } }, 0);
                }
            },
        }
    }
}

fn initDevice() void {
    reg(R.status).* = 0;
    reg(R.status).* = status_ack;
    reg(R.status).* = status_ack | status_driver;

    // Accept only VIRTIO_F_VERSION_1 (feature bit 32).
    reg(R.driver_features_sel).* = 1;
    reg(R.driver_features).* = 1; // bit 32
    reg(R.driver_features_sel).* = 0;
    reg(R.driver_features).* = 0;

    reg(R.status).* = status_ack | status_driver | status_features_ok;
    if (reg(R.status).* & status_features_ok == 0) usys.exit(176);

    reg(R.queue_sel).* = 0;
    if (reg(R.queue_num_max).* < queue_size) usys.exit(177);
    reg(R.queue_num).* = queue_size;

    // Virtqueue layout in the DMA page: descs @0, avail @256, used @1024.
    const desc = vq_dev;
    const avail = vq_dev + 256;
    const used = vq_dev + 1024;
    reg(R.queue_desc_lo).* = @truncate(desc);
    reg(R.queue_desc_hi).* = @truncate(desc >> 32);
    reg(R.queue_driver_lo).* = @truncate(avail);
    reg(R.queue_driver_hi).* = @truncate(avail >> 32);
    reg(R.queue_device_lo).* = @truncate(used);
    reg(R.queue_device_hi).* = @truncate(used >> 32);
    reg(R.queue_ready).* = 1;

    reg(R.status).* = status_ack | status_driver | status_features_ok | status_driver_ok;
}

fn readCap() u64 {
    const lo: u64 = reg(R.config).*;
    const hi: u64 = reg(R.config + 4).*;
    return lo | (hi << 32);
}

/// One 512-byte request through the virtqueue; returns the device's status
/// byte (0 = OK).
fn doIo(op: u32, sector: u64) u64 {
    // Request buffer page: header @0 (16B), data @16 (512B), status @528.
    const hdr: [*]volatile u32 = @ptrFromInt(buf_va);
    hdr[0] = op;
    hdr[1] = 0;
    const sec: *volatile u64 = @ptrFromInt(buf_va + 8);
    sec.* = sector;
    const status_byte: *volatile u8 = @ptrFromInt(buf_va + 528);
    status_byte.* = 0xff;

    const descs: [*]volatile Desc = @ptrFromInt(vq_va);
    descs[0] = .{ .addr = buf_dev, .len = 16, .flags = desc_f_next, .next = 1 };
    descs[1] = .{
        .addr = buf_dev + 16,
        .len = 512,
        .flags = if (op == 0) desc_f_next | desc_f_write else desc_f_next,
        .next = 2,
    };
    descs[2] = .{ .addr = buf_dev + 528, .len = 1, .flags = desc_f_write, .next = 0 };

    const avail_idx: *volatile u16 = @ptrFromInt(vq_va + 256 + 2);
    const avail_ring: [*]volatile u16 = @ptrFromInt(vq_va + 256 + 4);
    avail_ring[avail_idx.* % queue_size] = 0;
    asm volatile ("dmb ish");
    avail_idx.* = avail_idx.* +% 1;
    asm volatile ("dmb ish");
    reg(R.queue_notify).* = 0;

    // Wait for the device: IRQ -> notification -> check used.idx.
    const used_idx: *volatile u16 = @ptrFromInt(vq_va + 1024 + 2);
    while (used_idx.* == used_seen) {
        _ = usys.notifyWait(notif_h);
        const isr = reg(R.interrupt_status).*;
        reg(R.interrupt_ack).* = isr;
        _ = usys.irqAck(irq_h, slot);
    }
    used_seen = used_idx.*;
    asm volatile ("dmb ish");
    return status_byte.*;
}

fn copy(dst: [*]u8, src: [*]const u8, n: usize) void {
    for (0..n) |i| dst[i] = src[i];
}

// ------------------------------------------------------------- the client

fn blkuser(log_h: u64, chan_h: u64) noreturn {
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(180);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(181);
    const buf: [*]volatile u8 = @ptrFromInt(m.data[0]);

    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(182),
    }

    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, .capacity, 0)) {
        .ok => |rep| switch (rep) {
            .capacity => |c| {
                var line: [48]u8 = undefined;
                _ = usys.log(log_h, numLine(&line, "blkuser: disk has sectors: ", c.sectors));
            },
            else => usys.exit(183),
        },
        .err => usys.exit(184),
    }

    // Pattern -> sector 3 -> wipe -> read back -> verify.
    for (0..512) |i| buf[i] = @truncate(i *% 7 +% 3);
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, .{
        .write = .{ .sector = 3, .off = 0 },
    }, 0)) {
        .ok => |rep| if (rep != .ok) usys.exit(185),
        .err => usys.exit(186),
    }
    _ = usys.log(log_h, "blkuser: wrote pattern to sector 3");

    for (0..512) |i| buf[i] = 0;
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, .{
        .read = .{ .sector = 3, .off = 0 },
    }, 0)) {
        .ok => |rep| if (rep != .ok) usys.exit(187),
        .err => usys.exit(188),
    }
    for (0..512) |i| {
        if (buf[i] != @as(u8, @truncate(i *% 7 +% 3))) {
            _ = usys.log(log_h, "blkuser: VERIFY FAILED");
            usys.exit(189);
        }
    }
    _ = usys.log(log_h, "blkuser: read sector 3 back, 512/512 bytes verified");
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
