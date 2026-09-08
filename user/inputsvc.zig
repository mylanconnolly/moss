//! virtio-input (device type 18), in userspace — the keyboard driver. It
//! posts device-writable buffers on the event queue and reads back
//! `virtio_input_event`s (type, code, value); key presses are what a
//! terminal wants. Same driver interface as the other virtio devices:
//! device cap over the boot channel, IRQ-as-notification, DMA grant.
//!
//! Two modes (arg): mode 1 is the stage-3 drill — decode a fixed number
//! of presses, logging each keycode, then end the boot. Mode 0 is the
//! real service — it maps keycodes to characters and serves them over the
//! console protocol (`ConsReq.read`), so a terminal reads the keyboard
//! the same way it reads any byte source (the graphical seat, stage 4).

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

export fn umain(log_h: u64, chan_h: u64, role: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    dev_h = setup.device(.input);
    if (dev_h == 0) usys.exit(169);
    bringUp(log_h);
    if (role & 0xff == 1) drillLoop(log_h) else serveLoop(chan_h);
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

/// How many key presses the drill (mode 1) waits for.
const want_presses = 2;

fn availRing() [*]volatile u16 {
    return @ptrFromInt(vq_va + 512 + 4);
}

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

/// Unshifted US-QWERTY: evdev keycode -> ASCII, 0 for keys we don't map.
fn keymap(code: u16) u8 {
    return switch (code) {
        2...11 => "1234567890"[code - 2],
        16 => 'q',
        17 => 'w',
        18 => 'e',
        19 => 'r',
        20 => 't',
        21 => 'y',
        22 => 'u',
        23 => 'i',
        24 => 'o',
        25 => 'p',
        30 => 'a',
        31 => 's',
        32 => 'd',
        33 => 'f',
        34 => 'g',
        35 => 'h',
        36 => 'j',
        37 => 'k',
        38 => 'l',
        44 => 'z',
        45 => 'x',
        46 => 'c',
        47 => 'v',
        48 => 'b',
        49 => 'n',
        50 => 'm',
        57 => ' ',
        28 => '\n', // enter
        15 => '\t', // tab (the compositor's focus-switch key)
        12 => '-', // minus/hyphen
        14 => 8, // backspace (ASCII BS)
        else => 0,
    };
}

fn bringUp(log_h: u64) void {
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

    const descs: [*]volatile Desc = @ptrFromInt(vq_va);
    for (0..q_num) |i| {
        descs[i] = .{ .addr = buf_dev + i * ev_bytes, .len = ev_bytes, .flags = desc_f_write, .next = 0 };
        postBuf(@intCast(i));
    }
    kick();
    _ = usys.log(log_h, "input: ready");
}

/// One event at used-ring slot `used_seen`: returns its {type, code,
/// value} and recycles the buffer.
const Event = struct { etype: u16, code: u16, value: u32 };
fn nextEvent() Event {
    usys.barrier();
    const elem: *volatile extern struct { id: u32, len: u32 } =
        @ptrFromInt(vq_va + 1024 + 4 + (used_seen % q_num) * 8);
    const id: u16 = @intCast(elem.id);
    const base = buf_va + @as(u64, id) * ev_bytes;
    const ev: [*]volatile u16 = @ptrFromInt(base);
    const e = Event{ .etype = ev[0], .code = ev[1], .value = @as(*volatile u32, @ptrFromInt(base + 4)).* };
    postBuf(id);
    used_seen +%= 1;
    return e;
}

fn usedIdx() u16 {
    return @as(*volatile u16, @ptrFromInt(vq_va + 1024 + 2)).*;
}

// -------------------------------------------------------- mode 1: drill

fn logKey(log_h: u64, code: u16) void {
    var line: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&line, "input: key {d}", .{code}) catch return;
    _ = usys.log(log_h, s);
}

fn drillLoop(log_h: u64) noreturn {
    var presses: u64 = 0;
    while (presses < want_presses) {
        while (used_seen == usedIdx()) {
            _ = usys.notifyWait(irq_notif);
            _ = dev.isrRead();
        }
        while (used_seen != usedIdx()) {
            const e = nextEvent();
            if (e.etype == ev_key and e.value == 1) {
                logKey(log_h, e.code);
                presses += 1;
            }
        }
        kick();
    }
    _ = usys.log(log_h, "input: done");
    usys.exit(0);
}

// -------------------------------------------------------- mode 0: serve

var shm_va: u64 = 0;
var shm_len: u64 = 0;
var fifo: [256]u8 = undefined;
var fifo_head: usize = 0;
var fifo_tail: usize = 0;

fn fifoPush(c: u8) void {
    const next = (fifo_tail + 1) % fifo.len;
    if (next == fifo_head) return; // full: drop
    fifo[fifo_tail] = c;
    fifo_tail = next;
}

/// Decode every event the device has queued into typed characters.
fn drainEvents() void {
    while (used_seen != usedIdx()) {
        const e = nextEvent();
        if (e.etype == ev_key and e.value == 1) {
            const c = keymap(e.code);
            if (c != 0) fifoPush(c);
        }
    }
    kick();
}

/// Serve the console protocol's read side: a terminal reads keystrokes as
/// bytes, blocking until at least one is available (single client, like
/// the virtio-console driver). Writes are meaningless to a keyboard.
fn serveLoop(chan_h: u64) noreturn {
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .interrupted) {
            _ = usys.notifyWait(irq_notif);
            _ = dev.isrRead();
            drainEvents();
            continue;
        }
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(175);
        const req = shared.decodeMsg(shared.ConsReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 1 } }, 0);
            continue;
        };
        switch (req) {
            .setup => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        if (shm_va != 0) _ = usys.shmUnmap(shm_va);
                        shm_va = m.data[0];
                        shm_len = m.data[1] * 4096;
                    }
                    _ = usys.capDrop(r.cap);
                }
                _ = usys.replyTyped(shared.ConsResp, chan_h, .ok, 0);
            },
            .read => |q| {
                drainEvents();
                while (fifo_head == fifo_tail) {
                    _ = usys.notifyWait(irq_notif);
                    _ = dev.isrRead();
                    drainEvents();
                }
                if (shm_va == 0) {
                    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 3 } }, 0);
                    continue;
                }
                const dst: [*]volatile u8 = @ptrFromInt(shm_va);
                var nread: u64 = 0;
                const limit = @min(q.max, shm_len);
                while (nread < limit and fifo_head != fifo_tail) {
                    dst[nread] = fifo[fifo_head];
                    fifo_head = (fifo_head + 1) % fifo.len;
                    nread += 1;
                }
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = nread } }, 0);
            },
            .write => {
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 2 } }, 0);
            },
        }
    }
}
