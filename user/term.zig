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

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    const disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "term: no display channel");
        usys.exit(169);
    }

    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .create_surface, 0)) {
        .ok => |ok| ok,
        .err => usys.exit(180),
    };
    const surface = switch (cs.rep) {
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
    // A demo with more lines than fit, so the grid scrolls; the last line
    // that stays visible is a known one, and the cursor ends bottom-left.
    _ = usys.log(log_h, "term: rendering");
    writeText("moss graphical console\n");
    var i: usize = 0;
    var line: [8]u8 = undefined;
    while (i < 33) : (i += 1) {
        line = .{ 'r', 'o', 'w', ' ', '0' + @as(u8, @intCast(i / 10)), '0' + @as(u8, @intCast(i % 10)), '\n', 0 };
        writeText(line[0..7]);
    }
    cursorBlock(cur_c, cur_r);

    if (!commit(disp, surface, pxw, pxh)) usys.exit(184);
    _ = usys.log(log_h, "term: rendered");
    // Hold it up for the host's screendump, then exit — the drill's
    // essential unit, so this ends the boot.
    usys.sleepMs(4000);
    usys.exit(0);
}

fn commit(disp: u64, surface: u64, w: usize, h: usize) bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{
        .surface = surface,
        .xy = shared.packPair(0, 0),
        .wh = shared.packPair(@intCast(w), @intCast(h)),
    } }, 0)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}
