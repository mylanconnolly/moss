//! virtio-blk, in userspace, by x2:
//!   1 "blkdrv"  — the driver: probes the virtio-mmio slots its MMIO cap
//!                 covers, brings up the block device (modern interface,
//!                 split virtqueue, up to 8 requests in flight), and serves
//!                 the block protocol over BOTH transports: sync channel
//!                 call/reply, and an io_uring-style SQ/CQ ring in shared
//!                 memory with notification doorbells. The ring's SQ bell
//!                 is bound to the driver thread, so it interrupts a
//!                 blocked recv — one thread, both transports.
//!   2 "blkuser" — the client: verifies the protocol over both transports,
//!                 then races them: N sequential sync reads vs N ring reads
//!                 at queue depth 8.
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

const q_num = 32; // virtqueue descriptors
const slots = 8; // concurrent requests, 3 descriptors + one 544B buffer each
const slot_bytes = 544; // 16B header + 512B data + 1B status, padded

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const InFlight = struct {
    id: u64, // ring correlation id, or sync_id for channel requests
    write: bool,
    shm_off: u64,
};

const sync_id: u64 = 0xffff_ffff_ffff_ffff;

var dev_base: u64 = 0;
var vq_va: u64 = 0;
var vq_dev: u64 = 0;
var buf_va: u64 = 0;
var buf_dev: u64 = 0;
var irq_notif: u64 = 0;
var slot_idx: u64 = 0; // this device's virtio-mmio slot (for irq offset)
var used_seen: u16 = 0;
var avail_shadow: u16 = 0;
var inflight: [slots]?InFlight = @splat(null);
var inflight_count: u64 = 0;
var shm_va: u64 = 0;
var ring: ?*shared.RingBuf = null;
var sq_bell_h: u64 = 0;
var cq_bell: u64 = 0;
var sync_done: bool = false;
var sync_status: u64 = 0;

fn reg(off: u64) *volatile u32 {
    return @ptrFromInt(dev_base + off);
}

fn blkdrv(log_h: u64, chan_h: u64) noreturn {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(170);
    irq_notif = n.data[0];

    const mm = usys.mmioMap(mmio_h);
    if (mm.err != .ok) usys.exit(171);
    const mmio_base = mm.data[0];
    const nslots = mm.data[1] / 0x200;

    var found = false;
    var s: u64 = 0;
    while (s < nslots) : (s += 1) {
        dev_base = mmio_base + s * 0x200;
        if (reg(R.magic).* == 0x74726976 and
            reg(R.version).* == 2 and
            reg(R.device_id).* == 2)
        {
            found = true;
            slot_idx = s;
            break;
        }
    }
    if (!found) {
        _ = usys.log(log_h, "blkdrv: no virtio-blk device found");
        usys.exit(172);
    }
    if (usys.irqBind(irq_h, irq_notif, slot_idx) != .ok) usys.exit(173);

    // DMA: page 0 = virtqueue, pages 1-2 = 8 request buffers.
    const dma = usys.dmaAlloc(3);
    if (dma.err != .ok) usys.exit(174);
    vq_va = dma.data[0];
    vq_dev = dma.data[1];
    buf_va = dma.data[0] + 4096;
    buf_dev = dma.data[1] + 4096;

    initDevice();
    const capacity = readCap();
    _ = usys.log(log_h, "blkdrv: virtio-blk up (8 deep), serving both transports");

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .interrupted) {
            // Submission doorbell: clear the latched bits (or recv will
            // report interrupted forever), then drain the ring until quiet.
            if (sq_bell_h != 0) _ = usys.notifyWait(sq_bell_h);
            serveRing();
            continue;
        }
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
            .ring_setup => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) ring = @ptrFromInt(m.data[0]);
                }
                _ = usys.replyTyped(shared.BlkResp, chan_h, .ok, 0);
            },
            .ring_sq_bell => {
                if (r.cap != 0) {
                    sq_bell_h = r.cap;
                    _ = usys.notifyBind(r.cap);
                }
                _ = usys.replyTyped(shared.BlkResp, chan_h, .ok, 0);
            },
            .ring_cq_bell => {
                if (r.cap != 0) cq_bell = r.cap;
                _ = usys.replyTyped(shared.BlkResp, chan_h, .ok, 0);
            },
            .capacity => {
                _ = usys.replyTyped(shared.BlkResp, chan_h, .{
                    .capacity = .{ .sectors = capacity },
                }, 0);
            },
            .read => |io| _ = usys.replyTyped(shared.BlkResp, chan_h, syncIo(false, io.sector, io.off), 0),
            .write => |io| _ = usys.replyTyped(shared.BlkResp, chan_h, syncIo(true, io.sector, io.off), 0),
        }
    }
}

fn initDevice() void {
    reg(R.status).* = 0;
    reg(R.status).* = status_ack;
    reg(R.status).* = status_ack | status_driver;

    // Accept only VIRTIO_F_VERSION_1 (feature bit 32).
    reg(R.driver_features_sel).* = 1;
    reg(R.driver_features).* = 1;
    reg(R.driver_features_sel).* = 0;
    reg(R.driver_features).* = 0;

    reg(R.status).* = status_ack | status_driver | status_features_ok;
    if (reg(R.status).* & status_features_ok == 0) usys.exit(176);

    reg(R.queue_sel).* = 0;
    if (reg(R.queue_num_max).* < q_num) usys.exit(177);
    reg(R.queue_num).* = q_num;

    // Virtqueue layout in the DMA page: descs @0, avail @512, used @1024.
    const desc = vq_dev;
    const avail = vq_dev + 512;
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

/// Queue one request into a free slot (descriptor chain 3s..3s+2, buffer
/// slot s). Caller publishes avail.idx and rings the device afterwards.
fn submitSlot(s: usize, fl: InFlight, sector: u64) void {
    const bva = buf_va + s * slot_bytes;
    const bdev = buf_dev + s * slot_bytes;
    const hdr: [*]volatile u32 = @ptrFromInt(bva);
    hdr[0] = if (fl.write) 1 else 0; // VIRTIO_BLK_T_OUT / T_IN
    hdr[1] = 0;
    @as(*volatile u64, @ptrFromInt(bva + 8)).* = sector;
    @as(*volatile u8, @ptrFromInt(bva + 528)).* = 0xff;
    if (fl.write) copy(@ptrFromInt(bva + 16), @ptrFromInt(shm_va + fl.shm_off), 512);

    const descs: [*]volatile Desc = @ptrFromInt(vq_va);
    const d0: u16 = @intCast(3 * s);
    descs[d0] = .{ .addr = bdev, .len = 16, .flags = desc_f_next, .next = d0 + 1 };
    descs[d0 + 1] = .{
        .addr = bdev + 16,
        .len = 512,
        .flags = if (fl.write) desc_f_next else desc_f_next | desc_f_write,
        .next = d0 + 2,
    };
    descs[d0 + 2] = .{ .addr = bdev + 528, .len = 1, .flags = desc_f_write, .next = 0 };

    const avail_ring: [*]volatile u16 = @ptrFromInt(vq_va + 512 + 4);
    avail_ring[avail_shadow % q_num] = d0;
    avail_shadow +%= 1;

    inflight[s] = fl;
    inflight_count += 1;
}

/// Publish queued submissions and ring the device once.
fn kick() void {
    const avail_idx: *volatile u16 = @ptrFromInt(vq_va + 512 + 2);
    asm volatile ("dmb ish");
    avail_idx.* = avail_shadow;
    asm volatile ("dmb ish");
    reg(R.queue_notify).* = 0;
}

fn freeSlot() ?usize {
    for (&inflight, 0..) |fl, i| {
        if (fl == null) return i;
    }
    return null;
}

/// Reap the device's used ring: copy read data out, complete ring entries
/// (CQ + one doorbell per batch) or the sync waiter.
fn drainUsed() void {
    const used_idx: *volatile u16 = @ptrFromInt(vq_va + 1024 + 2);
    var completed_ring = false;
    while (used_seen != used_idx.*) {
        asm volatile ("dmb ish");
        const elem: *volatile extern struct { id: u32, len: u32 } =
            @ptrFromInt(vq_va + 1024 + 4 + (used_seen % q_num) * 8);
        const s = elem.id / 3;
        const fl = inflight[s].?;
        const bva = buf_va + s * slot_bytes;
        const status: u64 = @as(*volatile u8, @ptrFromInt(bva + 528)).*;
        if (!fl.write and status == 0) {
            copy(@ptrFromInt(shm_va + fl.shm_off), @ptrFromInt(bva + 16), 512);
        }
        const resp: shared.BlkResp = if (status == 0) .ok else .{ .io_err = .{ .code = status } };
        if (fl.id == sync_id) {
            sync_done = true;
            sync_status = status;
        } else if (ring) |rb| {
            _ = rb.cqPush(.{ .id = fl.id, .words = shared.encodeMsg(shared.BlkResp, resp) });
            completed_ring = true;
        }
        inflight[s] = null;
        inflight_count -= 1;
        used_seen +%= 1;
    }
    if (completed_ring and cq_bell != 0) _ = usys.notifySignal(cq_bell, 1);
}

fn waitIrqAndDrain() void {
    _ = usys.notifyWait(irq_notif);
    const isr = reg(R.interrupt_status).*;
    reg(R.interrupt_ack).* = isr;
    _ = usys.irqAck(irq_h, slot_idx);
    drainUsed();
}

/// One request over the sync transport: submit alone, wait it out.
fn syncIo(write: bool, sector: u64, off: u64) shared.BlkResp {
    if (shm_va == 0) return .{ .io_err = .{ .code = 1 } };
    const s = freeSlot() orelse return .{ .io_err = .{ .code = 2 } };
    sync_done = false;
    submitSlot(s, .{ .id = sync_id, .write = write, .shm_off = off }, sector);
    kick();
    while (!sync_done) waitIrqAndDrain();
    return if (sync_status == 0) .ok else .{ .io_err = .{ .code = sync_status } };
}

/// The async transport: drain SQ entries into free slots (batched kicks),
/// reap completions, repeat until the ring is quiet.
fn serveRing() void {
    const rb = ring orelse return;
    while (true) {
        var queued: u64 = 0;
        while (freeSlot()) |s| {
            var e: shared.RingEntry = undefined;
            if (!rb.sqPop(&e)) break;
            const req = shared.decodeMsg(shared.BlkReq, e.words) orelse continue;
            switch (req) {
                .read => |io| submitSlot(s, .{ .id = e.id, .write = false, .shm_off = io.off }, io.sector),
                .write => |io| submitSlot(s, .{ .id = e.id, .write = true, .shm_off = io.off }, io.sector),
                else => continue,
            }
            queued += 1;
        }
        if (queued > 0) kick();
        if (inflight_count == 0) return; // SQ quiet, nothing pending
        waitIrqAndDrain();
    }
}

fn copy(dst: [*]u8, src: [*]const u8, n: usize) void {
    for (0..n) |i| dst[i] = src[i];
}

// ------------------------------------------------------------- the client

const bench_ops = 128;
const bench_depth = 8;

fn blkuser(log_h: u64, chan_h: u64) noreturn {
    var line: [64]u8 = undefined;

    // Data buffer.
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(180);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(181);
    const buf: [*]volatile u8 = @ptrFromInt(m.data[0]);
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(182),
    }

    // Protocol test, sync transport.
    verifyRoundTrip(chan_h, buf, 3, null);
    _ = usys.log(log_h, "blkuser: sync transport verified (sector 3)");

    // Ring transport setup: ring page + two doorbells.
    const rs = usys.shmCreate(1);
    if (rs.err != .ok) usys.exit(183);
    const rm = usys.shmMap(rs.data[0]);
    if (rm.err != .ok) usys.exit(184);
    const rb: *shared.RingBuf = @ptrFromInt(rm.data[0]);
    rb.init();
    const sq_bell = usys.notifyCreate();
    const cq_bell_n = usys.notifyCreate();
    if (sq_bell.err != .ok or cq_bell_n.err != .ok) usys.exit(185);
    ringSetupCall(chan_h, .ring_setup, rs.data[0]);
    ringSetupCall(chan_h, .ring_sq_bell, sq_bell.data[0]);
    ringSetupCall(chan_h, .ring_cq_bell, cq_bell_n.data[0]);

    // Protocol test, ring transport.
    verifyRoundTrip(chan_h, buf, 5, .{ .rb = rb, .sq = sq_bell.data[0], .cq = cq_bell_n.data[0] });
    _ = usys.log(log_h, "blkuser: ring transport verified (sector 5)");

    // The race: N sequential sync reads vs N ring reads at depth 8.
    const hz = usys.cycleHz();
    const t0 = usys.cycles();
    for (0..bench_ops) |i| {
        switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, .{
            .read = .{ .sector = i % 8, .off = 0 },
        }, 0)) {
            .ok => {},
            .err => usys.exit(186),
        }
    }
    const sync_us = (usys.cycles() - t0) * 1_000_000 / hz;

    const t1 = usys.cycles();
    var submitted: u64 = 0;
    var completed: u64 = 0;
    while (completed < bench_ops) {
        var pushed = false;
        while (submitted - completed < bench_depth and submitted < bench_ops) {
            const req: shared.BlkReq = .{ .read = .{
                .sector = submitted % 8,
                .off = (submitted % 8) * 512,
            } };
            if (!rb.sqPush(.{ .id = submitted, .words = shared.encodeMsg(shared.BlkReq, req) })) break;
            submitted += 1;
            pushed = true;
        }
        if (pushed) _ = usys.notifySignal(sq_bell.data[0], 1);
        var e: shared.RingEntry = undefined;
        while (rb.cqPop(&e)) completed += 1;
        if (completed < bench_ops and submitted > completed) {
            _ = usys.notifyWait(cq_bell_n.data[0]);
            while (rb.cqPop(&e)) completed += 1;
        }
    }
    const ring_us = (usys.cycles() - t1) * 1_000_000 / hz;

    _ = usys.log(log_h, numLine(&line, "blkuser: sync  128 reads: us=", sync_us));
    _ = usys.log(log_h, numLine(&line, "blkuser: ring  128 reads: us=", ring_us));
    if (ring_us >= sync_us) {
        _ = usys.log(log_h, "blkuser: RING DID NOT WIN");
        usys.exit(99);
    }
    _ = usys.log(log_h, numLine(&line, "blkuser: ring speedup, percent faster: ", (sync_us - ring_us) * 100 / sync_us));
    usys.exit(0);
}

const RingCtx = struct { rb: *shared.RingBuf, sq: u64, cq: u64 };

/// Write a sector-specific pattern, wipe, read back, verify — over the
/// sync channel or over the ring, same protocol either way.
fn verifyRoundTrip(chan_h: u64, buf: [*]volatile u8, sector: u64, ring_ctx: ?RingCtx) void {
    for (0..512) |i| buf[i] = @truncate(i *% 7 +% sector);
    doOp(chan_h, .{ .write = .{ .sector = sector, .off = 0 } }, ring_ctx);
    for (0..512) |i| buf[i] = 0;
    doOp(chan_h, .{ .read = .{ .sector = sector, .off = 0 } }, ring_ctx);
    for (0..512) |i| {
        if (buf[i] != @as(u8, @truncate(i *% 7 +% sector))) usys.exit(190);
    }
}

fn doOp(chan_h: u64, req: shared.BlkReq, ring_ctx: ?RingCtx) void {
    if (ring_ctx) |rc| {
        if (!rc.rb.sqPush(.{ .id = 1, .words = shared.encodeMsg(shared.BlkReq, req) })) usys.exit(191);
        _ = usys.notifySignal(rc.sq, 1);
        var e: shared.RingEntry = undefined;
        while (!rc.rb.cqPop(&e)) _ = usys.notifyWait(rc.cq);
        const resp = shared.decodeMsg(shared.BlkResp, e.words) orelse usys.exit(192);
        if (resp != .ok) usys.exit(193);
    } else {
        switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, req, 0)) {
            .ok => |rep| if (rep != .ok) usys.exit(194),
            .err => usys.exit(195),
        }
    }
}

fn ringSetupCall(chan_h: u64, comptime which: shared.BlkReq, cap: u64) void {
    switch (usys.callTyped(shared.BlkReq, shared.BlkResp, chan_h, which, cap)) {
        .ok => {},
        .err => usys.exit(196),
    }
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
