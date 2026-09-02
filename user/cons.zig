//! The console driver: virtio-console (device id 3) as a userspace
//! process — moss's third virtio device class through the same driver
//! interface (mmio grant, IRQ-as-notification, DMA grant). No MULTIPORT:
//! port 0 is the console, queue 0 = receiveq, queue 1 = transmitq.
//!
//! Serves one client (msh) over its channel: setup grants the byte
//! buffer, read blocks the driver on the RX interrupt until at least one
//! byte is available (single client, so blocking the serve loop is
//! correct — the kernel channel does not allow recv while a reply is
//! pending), write is synchronous. Raw byte pipe; echo and line
//! discipline belong to the client.

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
        \\        .ascii  "cons"
        \\        .space  12
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

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    consdrv(log_h, chan_h);
}

// virtio-mmio registers (modern, version 2) — same map as blk/net.
const R = struct {
    const magic = 0x00;
    const version = 0x04;
    const device_id = 0x08;
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
};

const status_ack = 1;
const status_driver = 2;
const status_driver_ok = 4;
const status_features_ok = 8;
const desc_f_write = 2;

const Desc = extern struct {
    addr: u64,
    len: u32,
    flags: u16,
    next: u16,
};

const q_num = 8; // per queue; console traffic is tiny
const rx_bufs = 8;
const rx_buf_len = 64;
const tx_buf_len = 2048;

var dev_base: u64 = 0;
var slot_idx: u64 = 0;
var irq_notif: u64 = 0;
// DMA: page 0 = rx virtqueue, page 1 = tx virtqueue,
// page 2 = rx buffers (8 x 64B) then the tx buffer.
var rxq_va: u64 = 0;
var rxq_dev: u64 = 0;
var txq_va: u64 = 0;
var txq_dev: u64 = 0;
var buf_va: u64 = 0;
var buf_dev: u64 = 0;
var rx_used_seen: u16 = 0;
var rx_avail_shadow: u16 = 0;
var tx_used_seen: u16 = 0;
var tx_avail_shadow: u16 = 0;

var shm_va: u64 = 0;
var shm_len: u64 = 0;

// Software RX fifo between the interrupt path and the (single) reader.
var fifo: [1024]u8 = undefined;
var fifo_head: usize = 0; // read position
var fifo_tail: usize = 0; // write position

fn reg(off: u64) *volatile u32 {
    return @ptrFromInt(dev_base + off);
}

fn consdrv(log_h: u64, chan_h: u64) noreturn {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(160);
    irq_notif = n.data[0];

    const mm = usys.mmioMap(mmio_h);
    if (mm.err != .ok) usys.exit(161);
    const mmio_base = mm.data[0];
    const nslots = mm.data[1] / 0x200;

    var found = false;
    var s: u64 = 0;
    while (s < nslots) : (s += 1) {
        dev_base = mmio_base + s * 0x200;
        if (reg(R.magic).* == 0x74726976 and
            reg(R.version).* == 2 and
            reg(R.device_id).* == 3)
        {
            found = true;
            slot_idx = s;
            break;
        }
    }
    if (!found) {
        _ = usys.log(log_h, "consdrv: no virtio-console device found");
        usys.exit(162);
    }
    if (usys.irqBind(irq_h, irq_notif, slot_idx) != .ok) usys.exit(163);
    // RX interrupts must break the blocked recv (the sharp-edge list:
    // drain with notifyWait after every interrupted, or spin forever).
    if (usys.notifyBind(irq_notif) != .ok) usys.exit(168);

    const dma = usys.dmaAlloc(3);
    if (dma.err != .ok) usys.exit(164);
    rxq_va = dma.data[0];
    rxq_dev = dma.data[1];
    txq_va = dma.data[0] + 4096;
    txq_dev = dma.data[1] + 4096;
    buf_va = dma.data[0] + 2 * 4096;
    buf_dev = dma.data[1] + 2 * 4096;

    initDevice();
    postAllRx();
    _ = usys.log(log_h, "consdrv: virtio-console up");

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .interrupted) {
            _ = usys.notifyWait(irq_notif); // drain the latched doorbell
            ackIrq();
            drainRx(); // input with no reader waiting buffers into the fifo
            continue;
        }
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(165);
        const req = shared.decodeMsg(shared.ConsReq, r.data) orelse {
            _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 1 } }, 0);
            continue;
        };
        switch (req) {
            .setup => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        shm_va = m.data[0];
                        shm_len = m.data[1] * 4096;
                    }
                }
                _ = usys.replyTyped(shared.ConsResp, chan_h, .ok, 0);
            },
            .read => |q| {
                // Single client: block right here until bytes arrive (the
                // channel keeps the caller parked; recv-with-reply-pending
                // is not a thing — the kernel would return busy).
                drainRx();
                while (fifo_head == fifo_tail) {
                    _ = usys.notifyWait(irq_notif);
                    ackIrq();
                    drainRx();
                }
                replyRead(chan_h, q.max);
            },
            .write => |w| {
                if (shm_va == 0 or w.len == 0 or w.len > @min(tx_buf_len, shm_len)) {
                    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 2 } }, 0);
                    continue;
                }
                txWrite(w.len);
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = w.len } }, 0);
            },
        }
    }
}

fn replyRead(chan_h: u64, max: u64) void {
    if (shm_va == 0) {
        _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 3 } }, 0);
        return;
    }
    const dst: [*]volatile u8 = @ptrFromInt(shm_va);
    var n: u64 = 0;
    const limit = @min(max, shm_len);
    while (n < limit and fifo_head != fifo_tail) {
        dst[n] = fifo[fifo_head];
        fifo_head = (fifo_head + 1) % fifo.len;
        n += 1;
    }
    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = n } }, 0);
}

// ------------------------------------------------------------ virtio glue

fn initDevice() void {
    reg(R.status).* = 0;
    reg(R.status).* = status_ack;
    reg(R.status).* = status_ack | status_driver;

    // VERSION_1 only; no console features needed (no MULTIPORT).
    reg(R.driver_features_sel).* = 1;
    reg(R.driver_features).* = 1;
    reg(R.driver_features_sel).* = 0;
    reg(R.driver_features).* = 0;

    reg(R.status).* = status_ack | status_driver | status_features_ok;
    if (reg(R.status).* & status_features_ok == 0) usys.exit(166);

    setupQueue(0, rxq_dev);
    setupQueue(1, txq_dev);

    reg(R.status).* = status_ack | status_driver | status_features_ok | status_driver_ok;
}

fn setupQueue(qi: u32, vq_dev: u64) void {
    reg(R.queue_sel).* = qi;
    if (reg(R.queue_num_max).* < q_num) usys.exit(167);
    reg(R.queue_num).* = q_num;
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
}

/// Post every RX buffer as a device-writable descriptor.
fn postAllRx() void {
    const descs: [*]volatile Desc = @ptrFromInt(rxq_va);
    const avail_ring: [*]volatile u16 = @ptrFromInt(rxq_va + 512 + 4);
    for (0..rx_bufs) |i| {
        descs[i] = .{
            .addr = buf_dev + i * rx_buf_len,
            .len = rx_buf_len,
            .flags = desc_f_write,
            .next = 0,
        };
        avail_ring[rx_avail_shadow % q_num] = @intCast(i);
        rx_avail_shadow +%= 1;
    }
    publish(rxq_va, rx_avail_shadow, 0);
}

fn publish(vq_va: u64, shadow: u16, queue: u32) void {
    const avail_idx: *volatile u16 = @ptrFromInt(vq_va + 512 + 2);
    asm volatile ("dmb ish");
    avail_idx.* = shadow;
    asm volatile ("dmb ish");
    reg(R.queue_notify).* = queue;
}

fn ackIrq() void {
    const isr = reg(R.interrupt_status).*;
    reg(R.interrupt_ack).* = isr;
    _ = usys.irqAck(irq_h, slot_idx);
}

/// Pull completed RX buffers into the fifo and repost them.
fn drainRx() void {
    const used_idx: *volatile u16 = @ptrFromInt(rxq_va + 1024 + 2);
    const avail_ring: [*]volatile u16 = @ptrFromInt(rxq_va + 512 + 4);
    var reposted = false;
    while (rx_used_seen != used_idx.*) {
        asm volatile ("dmb ish");
        const elem: *volatile extern struct { id: u32, len: u32 } =
            @ptrFromInt(rxq_va + 1024 + 4 + (rx_used_seen % q_num) * 8);
        const i = elem.id;
        const len = @min(elem.len, rx_buf_len);
        const src: [*]const volatile u8 = @ptrFromInt(buf_va + i * rx_buf_len);
        for (0..len) |k| {
            const next = (fifo_tail + 1) % fifo.len;
            if (next == fifo_head) break; // fifo full: drop input
            fifo[fifo_tail] = src[k];
            fifo_tail = next;
        }
        // Repost the buffer.
        avail_ring[rx_avail_shadow % q_num] = @intCast(i);
        rx_avail_shadow +%= 1;
        reposted = true;
        rx_used_seen +%= 1;
    }
    if (reposted) publish(rxq_va, rx_avail_shadow, 0);
}

/// Synchronous TX: one descriptor, wait for the device to consume it.
fn txWrite(len: u64) void {
    const tx_va = buf_va + rx_bufs * rx_buf_len;
    const tx_dev = buf_dev + rx_bufs * rx_buf_len;
    const dst: [*]volatile u8 = @ptrFromInt(tx_va);
    const src: [*]const volatile u8 = @ptrFromInt(shm_va);
    for (0..len) |i| dst[i] = src[i];

    const descs: [*]volatile Desc = @ptrFromInt(txq_va);
    descs[0] = .{ .addr = tx_dev, .len = @intCast(len), .flags = 0, .next = 0 };
    const avail_ring: [*]volatile u16 = @ptrFromInt(txq_va + 512 + 4);
    avail_ring[tx_avail_shadow % q_num] = 0;
    tx_avail_shadow +%= 1;
    publish(txq_va, tx_avail_shadow, 1);

    const used_idx: *volatile u16 = @ptrFromInt(txq_va + 1024 + 2);
    while (tx_used_seen == used_idx.*) {
        _ = usys.notifyWait(irq_notif);
        ackIrq();
        drainRx(); // RX may complete while we wait on TX
    }
    tx_used_seen = used_idx.*;
}
