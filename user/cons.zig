//! The console driver: virtio-console (device id 3) as a userspace
//! process — moss's third virtio device class through the same driver
//! interface (device cap, IRQ-as-notification, DMA grant). No MULTIPORT:
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
const virtio = @import("virtio.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("cons"));
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// The device arrives over the boot channel (BootReq cap{device}); the
// same channel then serves the console client.
var dev_h: u64 = 0;

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    dev_h = setup.device(.console);
    if (dev_h == 0) usys.exit(169);
    consdrv(log_h, chan_h);
}

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

var dev: virtio.Dev = undefined;
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

fn consdrv(log_h: u64, chan_h: u64) noreturn {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(160);
    irq_notif = n.data[0];

    dev = virtio.Dev.open(dev_h, .console) orelse {
        _ = usys.log(log_h, "consdrv: the device handed to us is not a virtio-console");
        usys.exit(172);
    };
    if (usys.irqBind(dev_h, irq_notif, 0) != .ok) usys.exit(163);
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
                        if (shm_va != 0) _ = usys.shmUnmap(shm_va); // a new client's buffer replaces the last one's
                        shm_va = m.data[0];
                        shm_len = m.data[1] * 4096;
                    }
                    _ = usys.capDrop(r.cap);
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
    // VERSION_1 only; no console features needed (no MULTIPORT).
    _ = dev.negotiate(0, 0) orelse usys.exit(166);
    setupQueue(0, rxq_dev);
    setupQueue(1, txq_dev);
    dev.driverOk();
}

fn setupQueue(qi: u16, vq_dev: u64) void {
    if (!dev.queueSetup(qi, q_num, vq_dev, vq_dev + 512, vq_dev + 1024)) usys.exit(167);
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
    usys.barrier();
    avail_idx.* = shadow;
    usys.barrier();
    dev.notify(@intCast(queue));
}

fn ackIrq() void {
    _ = dev.isrRead();
    _ = usys.irqAck(dev_h, 0);
}

/// Pull completed RX buffers into the fifo and repost them.
fn drainRx() void {
    const used_idx: *volatile u16 = @ptrFromInt(rxq_va + 1024 + 2);
    const avail_ring: [*]volatile u16 = @ptrFromInt(rxq_va + 512 + 4);
    var reposted = false;
    while (rx_used_seen != used_idx.*) {
        usys.barrier();
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
