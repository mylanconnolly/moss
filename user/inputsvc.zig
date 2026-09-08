//! virtio-input (device type 18), in userspace — the keyboard (and, in
//! time, pointer) driver. It posts device-writable buffers on the event
//! queue and reads back `virtio_input_event`s (type, code, value); key
//! presses are what a terminal wants. Same driver interface as the other
//! virtio devices: device cap over the boot channel, IRQ-as-notification,
//! DMA grant.
//!
//! Stage 3 proves the decode: the host injects key presses over QMP and
//! the driver logs each keycode, then ends the boot after it has seen the
//! expected number. Exposing events to the terminal over a channel — so
//! the shell reads the keyboard — is the graphical seat (stage 4).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const virtio = @import("virtio.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("inputsvc"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var dev_h: u64 = 0;

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    dev_h = setup.device(.input);
    if (dev_h == 0) usys.exit(169);
    inputdrv(log_h);
}

const desc_f_write = 2;

const q_event = 0;
const q_num = 32; // event buffers in flight

// virtio_input_event: { le16 type; le16 code; le32 value; } — 8 bytes.
const ev_key = 1; // EV_KEY
const ev_bytes = 8;

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };

var dev: virtio.Dev = undefined;
var irq_notif: u64 = 0;
var vq_va: u64 = 0;
var vq_dev: u64 = 0;
var buf_va: u64 = 0;
var buf_dev: u64 = 0;
var used_seen: u16 = 0;
var avail_shadow: u16 = 0;

/// How many key presses the drill waits for before ending the boot.
const want_presses = 2;

fn availRing() [*]volatile u16 {
    return @ptrFromInt(vq_va + 512 + 4);
}

/// Publish a buffer descriptor `id` on the event queue.
fn postBuf(id: u16) void {
    availRing()[avail_shadow % q_num] = id;
    avail_shadow +%= 1;
}

fn kick() void {
    const avail_idx: *volatile u16 = @ptrFromInt(vq_va + 512 + 2);
    usys.barrier();
    avail_idx.* = avail_shadow;
    usys.barrier();
    dev.notify(q_event);
}

fn logKey(log_h: u64, code: u16) void {
    var line: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "input: key {d}", .{code}) catch return;
    _ = usys.log(log_h, s);
}

fn inputdrv(log_h: u64) noreturn {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(170);
    irq_notif = n.data[0];

    dev = virtio.Dev.open(dev_h, .input) orelse {
        _ = usys.log(log_h, "inputsvc: the device handed to us is not a virtio-input");
        usys.exit(172);
    };
    if (usys.irqBind(dev_h, irq_notif, 0) != .ok) usys.exit(173);
    if (usys.notifyBind(irq_notif) != .ok) usys.exit(168);

    // DMA: page 0 = event virtqueue, page 1 = the event buffers.
    const dma = usys.dmaAlloc(2);
    if (dma.err != .ok) usys.exit(174);
    vq_va = dma.data[0];
    vq_dev = dma.data[1];
    buf_va = dma.data[0] + 4096;
    buf_dev = dma.data[1] + 4096;

    _ = dev.negotiate(0, 0) orelse usys.exit(176);
    if (!dev.queueSetup(q_event, q_num, vq_dev, vq_dev + 512, vq_dev + 1024)) usys.exit(177);
    dev.driverOk();

    // Post every event buffer: each is device-writable, one event's worth.
    const descs: [*]volatile Desc = @ptrFromInt(vq_va);
    for (0..q_num) |i| {
        descs[i] = .{ .addr = buf_dev + i * ev_bytes, .len = ev_bytes, .flags = desc_f_write, .next = 0 };
        postBuf(@intCast(i));
    }
    kick();
    _ = usys.log(log_h, "input: ready");

    var presses: u64 = 0;
    const used_idx: *volatile u16 = @ptrFromInt(vq_va + 1024 + 2);
    while (presses < want_presses) {
        while (used_seen == used_idx.*) {
            _ = usys.notifyWait(irq_notif);
            _ = dev.isrRead();
        }
        while (used_seen != used_idx.*) {
            usys.barrier();
            const elem: *volatile extern struct { id: u32, len: u32 } =
                @ptrFromInt(vq_va + 1024 + 4 + (used_seen % q_num) * 8);
            const id: u16 = @intCast(elem.id);
            const ev: [*]volatile u16 = @ptrFromInt(buf_va + @as(u64, id) * ev_bytes);
            const etype = ev[0];
            const code = ev[1];
            const value = @as(*volatile u32, @ptrFromInt(buf_va + @as(u64, id) * ev_bytes + 4)).*;
            if (etype == ev_key and value == 1) {
                logKey(log_h, code);
                presses += 1;
            }
            postBuf(id); // recycle the buffer
            used_seen +%= 1;
        }
        kick();
    }
    _ = usys.log(log_h, "input: done");
    usys.exit(0);
}
