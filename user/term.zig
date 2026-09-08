//! The terminal: a surface client that renders a character grid onto the
//! display server's scanout — the userspace analog of the kernel's
//! framebuffer console, but a normal program drawing into a surface it
//! got from gpusvc, so it coexists with any other graphical client. It
//! keeps a cursor, wraps at the right edge, and scrolls when it reaches
//! the bottom; text is the shared 8x16 font (printable ASCII).
//!
//! Stage 2 renders a demo (enough lines to scroll) and leaves the cursor
//! at the bottom, then commits and holds it up for the host's screendump.
//! Wiring a console channel + keyboard so the shell runs here is the
//! graphical seat (stage 4); the grid state is already a writeText() so
//! that step only feeds it bytes.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const font = shared.font8x16;

comptime {
    asm (usys.imageHeader("term"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// XRGB / B8G8R8X8 words: white text on a black ground.
const fg: u32 = 0x00FF_FFFF;
const bg: u32 = 0x0000_0000;

const gw = font.width; // 8
const gh = font.height; // 16

var px: [*]volatile u32 = undefined;
var stride: usize = 0; // pixels per scanline
var cols: usize = 0;
var rows: usize = 0;
var cur_c: usize = 0;
var cur_r: usize = 0;
var pxw: usize = 0;
var pxh: usize = 0;

fn cell(col: usize, row: usize, ch: u8) void {
    const g: usize = if (ch < font.first or ch > font.last) 0 else ch - font.first;
    const bitmap = font.glyphs[g];
    for (0..gh) |gy| {
        const bits = bitmap[gy];
        const base = (row * gh + gy) * stride + col * gw;
        inline for (0..gw) |gx| {
            px[base + gx] = if (bits & (@as(u8, 0x80) >> gx) != 0) fg else bg;
        }
    }
}

/// Solid block, drawn where the cursor rests.
fn cursorBlock(col: usize, row: usize) void {
    for (0..gh) |gy| {
        const base = (row * gh + gy) * stride + col * gw;
        for (0..gw) |gx| px[base + gx] = fg;
    }
}

fn clear() void {
    for (0..pxw * pxh) |i| px[i] = bg;
}

/// Shift the grid up one text row and clear the bottom row.
fn scroll() void {
    const shift = gh * stride;
    const total = pxh * stride;
    var i: usize = 0;
    while (i + shift < total) : (i += 1) px[i] = px[i + shift];
    while (i < total) : (i += 1) px[i] = bg;
}

fn newline() void {
    cur_c = 0;
    cur_r += 1;
    if (cur_r >= rows) {
        scroll();
        cur_r = rows - 1;
    }
}

fn writeByte(b: u8) void {
    if (b == '\n') {
        newline();
        return;
    }
    if (cur_c >= cols) newline();
    cell(cur_c, cur_r, b);
    cur_c += 1;
}

fn writeText(s: []const u8) void {
    for (s) |b| writeByte(b);
}

var disp: u64 = 0;
var surface: u64 = 0;

export fn umain(log_h: u64, chan_h: u64, role: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "term: no display channel");
        usys.exit(169);
    }

    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = 0, .wh = 0 } }, 0)) {
        .ok => |ok| ok,
        .err => usys.exit(180),
    };
    surface = switch (cs.rep) {
        .created => |c| c.surface,
        else => usys.exit(181),
    };
    pxw = shared.unpackHi(cs.rep.created.wh);
    pxh = shared.unpackLo(cs.rep.created.wh);
    if (cs.cap == 0) usys.exit(182);
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) usys.exit(183);
    px = @ptrFromInt(m.data[0]);
    stride = pxw;
    cols = pxw / gw;
    rows = pxh / gh;
    clear();

    // Mode 1: the stage-2 demo (render + hold for a screendump, then end
    // the boot). Mode 0: serve the console — a client writes bytes we
    // render and reads keystrokes we fetch from inputsvc (the seat).
    if (role & 0xff == 1) demo(log_h) else serveConsole(log_h, chan_h, setup.cap(.keys));
}

fn demo(log_h: u64) noreturn {
    _ = usys.log(log_h, "term: rendering");
    writeText("moss graphical console\n");
    var i: usize = 0;
    var line: [8]u8 = undefined;
    while (i < 33) : (i += 1) {
        line = .{ 'r', 'o', 'w', ' ', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)), '\n', 0 };
        writeText(line[0..7]);
    }
    cursorBlock(cur_c, cur_r);
    if (!commit(pxw, pxh)) usys.exit(184);
    _ = usys.log(log_h, "term: rendered");
    usys.sleepMs(4000);
    usys.exit(0);
}

/// Serve the console protocol to a client while reading the keyboard from
/// inputsvc: writes render as glyphs, reads return keystrokes. The client
/// (a shell) sees exactly the ConsReq interface the virtio-console driver
/// gives, so it runs here unchanged.
fn serveConsole(log_h: u64, chan_h: u64, keys: u64) noreturn {
    if (keys == 0) {
        _ = usys.log(log_h, "term: no keyboard channel");
        usys.exit(170);
    }
    // Our own buffer shared with inputsvc, for its read replies.
    const ks = usys.shmCreate(1);
    if (ks.err != .ok) usys.exit(171);
    const km = usys.shmMap(ks.data[0]);
    if (km.err != .ok) usys.exit(172);
    const kbuf: [*]volatile u8 = @ptrFromInt(km.data[0]);
    switch (usys.callTyped(shared.ConsReq, shared.ConsResp, keys, .setup, ks.data[0])) {
        .ok => {},
        .err => usys.exit(173),
    }

    var out_va: u64 = 0; // the client's console buffer (write source / read sink)
    var out_len: u64 = 0;
    _ = usys.log(log_h, "term: console up");
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(shared.ConsReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 1 } }, 0);
            continue;
        };
        switch (req) {
            .setup => {
                if (r.cap != 0) {
                    const cm = usys.shmMap(r.cap);
                    if (cm.err == .ok) {
                        if (out_va != 0) _ = usys.shmUnmap(out_va);
                        out_va = cm.data[0];
                        out_len = cm.data[1] * 4096;
                    }
                    _ = usys.capDrop(r.cap);
                }
                _ = usys.replyTyped(shared.ConsResp, chan_h, .ok, 0);
            },
            .write => |w| {
                if (out_va == 0 or w.len > out_len) {
                    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 2 } }, 0);
                    continue;
                }
                const src: [*]const u8 = @ptrFromInt(out_va);
                writeText(src[0..w.len]);
                cursorBlock(cur_c, cur_r);
                _ = commit(pxw, pxh);
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = w.len } }, 0);
            },
            .read => |q| {
                // Fetch keystrokes from inputsvc (blocks until one), then
                // hand them to the client through its buffer.
                const got = switch (usys.callTyped(shared.ConsReq, shared.ConsResp, keys, .{ .read = .{ .max = @min(q.max, 4096) } }, 0)) {
                    .ok => |rep| switch (rep) {
                        .n => |x| x.n,
                        else => 0,
                    },
                    .err => 0,
                };
                if (out_va == 0) {
                    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 3 } }, 0);
                    continue;
                }
                const dst: [*]volatile u8 = @ptrFromInt(out_va);
                var i: u64 = 0;
                while (i < got and i < out_len) : (i += 1) dst[i] = kbuf[i];
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = i } }, 0);
            },
        }
    }
}

fn commit(w: usize, h: usize) bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{
        .surface = surface,
        .xy = shared.packPair(0, 0),
        .wh = shared.packPair(@intCast(w), @intCast(h)),
    } }, 0)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}
