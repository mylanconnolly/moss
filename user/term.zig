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

const gw = font.width; // 8, the bitmap cell (fallback)
const gh = font.height; // 16

var px: [*]volatile u32 = undefined;
var stride: usize = 0; // pixels per scanline
var cols: usize = 0;
var rows: usize = 0;
var cur_c: usize = 0;
var cur_r: usize = 0;
var pxw: usize = 0;
var pxh: usize = 0;

// The cell size: the bitmap 8x16 by default, or the system mono font's
// advance and line height once fontsvc is attached.
var cellw: usize = gw;
var cellh: usize = gh;

// ---------------------------------------------- system font (fontsvc)
// When the terminal is given a `font` cap it renders in the real mono
// family at the effective scale, the same as every other program. It is a
// monospace grid, so it needs per-glyph coverage (not proportional
// layout): each byte's glyph is fetched from fontsvc once and cached
// locally by codepoint, then blitted from the shared atlas at fixed cells.
var font_chan: u64 = 0;
var font_buf: [*]u8 = undefined;
var font_buf_len: usize = 0;
var fatlas: [*]const u8 = undefined;
var fatlas_w: usize = 0;
var font_ok = false;
var ascent: usize = 0;
const mono_role: u64 = @intFromEnum(shared.FontRole.mono);
const Gc = struct { have: bool = false, ax: u16 = 0, ay: u16 = 0, w: u16 = 0, h: u16 = 0, left: i16 = 0, top: i16 = 0 };
var gcache: [128]Gc = @splat(.{});

fn fontReady() void {
    if (font_chan == 0) return;
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) return;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) return;
    font_buf = @ptrFromInt(m.data[0]);
    font_buf_len = m.data[1] * 4096;
    switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .attach_buf, sh.data[0])) {
        .ok => |ok| if (ok.rep != .ok) return,
        .err => return,
    }
    const at = switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .atlas, 0)) {
        .ok => |ok| ok,
        .err => return,
    };
    if (at.cap == 0 or at.rep != .atlas) return;
    const am = usys.shmMap(at.cap);
    if (am.err != .ok) return;
    fatlas = @ptrFromInt(am.data[0]);
    fatlas_w = shared.unpackHi(at.rep.atlas.wh);
    switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .metrics = .{ .role = mono_role } }, 0)) {
        .ok => |rep| switch (rep) {
            .metrics => |mm| {
                cellh = @intCast(mm.line);
                ascent = @intCast(mm.ascent);
            },
            else => return,
        },
        .err => return,
    }
    const w = layoutOne('0'); // a probe: the mono advance is the cell width
    if (w == 0 or cellh == 0) return;
    cellw = w;
    font_ok = true;
}

/// Lay one byte out in the mono role: cache its glyph in `gcache[b]` and
/// return its advance (the pen width of a one-glyph run).
fn layoutOne(b: u8) usize {
    if (font_buf_len == 0) return 0;
    font_buf[0] = b;
    return switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .layout = .{ .role = mono_role, .px = 0, .len = 1 } }, 0)) {
        .ok => |rep| switch (rep) {
            .laid => |l| blk: {
                if (l.count >= 1 and b < gcache.len) {
                    const run: [*]const shared.FontGlyph = @ptrCast(@alignCast(font_buf));
                    const g = run[0];
                    gcache[b] = .{ .have = true, .ax = g.atlas_x, .ay = g.atlas_y, .w = g.w, .h = g.h, .left = g.left, .top = g.top };
                }
                break :blk shared.unpackHi(l.pen);
            },
            else => 0,
        },
        .err => 0,
    };
}

fn glyphOf(b: u8) ?Gc {
    if (b >= gcache.len) return null;
    if (!gcache[b].have) _ = layoutOne(b);
    return if (gcache[b].have) gcache[b] else null;
}

fn clearCell(col: usize, row: usize) void {
    var y: usize = 0;
    while (y < cellh) : (y += 1) {
        const base = (row * cellh + y) * stride + col * cellw;
        var x: usize = 0;
        while (x < cellw and col * cellw + x < pxw) : (x += 1) px[base + x] = bg;
    }
}

fn cell(col: usize, row: usize, chr: u8) void {
    if (font_ok) {
        clearCell(col, row);
        const g = glyphOf(chr) orelse return;
        const baseline = row * cellh + ascent;
        var r: usize = 0;
        while (r < g.h) : (r += 1) {
            const arow = (@as(usize, g.ay) + r) * fatlas_w + g.ax;
            var c: usize = 0;
            while (c < g.w) : (c += 1) {
                const cov: u32 = fatlas[arow + c];
                if (cov == 0) continue;
                const dx = @as(i64, @intCast(col * cellw)) + g.left + @as(i64, @intCast(c));
                const dy = @as(i64, @intCast(baseline)) + g.top + @as(i64, @intCast(r));
                if (dx < 0 or dy < 0) continue;
                const ux: usize = @intCast(dx);
                const uy: usize = @intCast(dy);
                if (ux >= pxw or uy >= pxh) continue;
                // white text on black: coverage is the grey level directly.
                px[uy * stride + ux] = cov << 16 | cov << 8 | cov;
            }
        }
        return;
    }
    const g: usize = if (chr < font.first or chr > font.last) 0 else chr - font.first;
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
    var y: usize = 0;
    while (y < cellh) : (y += 1) {
        const base = (row * cellh + y) * stride + col * cellw;
        var x: usize = 0;
        while (x < cellw and col * cellw + x < pxw) : (x += 1) px[base + x] = fg;
    }
}

fn clear() void {
    for (0..pxw * pxh) |i| px[i] = bg;
}

/// Shift the grid up one text row and clear the bottom row.
fn scroll() void {
    const shift = cellh * stride;
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
    if (setup.has(.font)) font_chan = setup.cap(.font);

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
    fontReady(); // sets cellw/cellh (mono metrics) + font_ok; else the 8x16 bitmap
    cols = pxw / cellw;
    rows = pxh / cellh;
    clear();

    // Mode 1: the stage-2 demo (render + hold for a screendump, then end
    // the boot). Mode 0: serve the console — a client writes bytes we
    // render and reads keystrokes we fetch from inputsvc (the seat).
    if (role & 0xff == 1) demo(log_h) else serveConsole(log_h, chan_h);
}

fn demo(log_h: u64) noreturn {
    _ = usys.log(log_h, "term: rendering");
    writeText("moss graphical console\n");
    // Enough lines to scroll past the bottom whatever the scanout height,
    // so the cursor always ends on the last row (where the drill checks).
    var i: usize = 0;
    var line: [8]u8 = undefined;
    const n_lines = rows + 6;
    while (i < n_lines) : (i += 1) {
        line = .{ 'r', 'o', 'w', ' ', '0' + @as(u8, @intCast((i / 10) % 10)), '0' + @as(u8, @intCast(i % 10)), '\n', 0 };
        writeText(line[0..7]);
    }
    cursorBlock(cur_c, cur_r);
    if (!commit(pxw, pxh)) usys.exit(184);
    _ = usys.log(log_h, "term: rendered");
    usys.sleepMs(4000);
    usys.exit(0);
}

/// The keyboard, from the compositor: it routes a keystroke to the client
/// that owns the focused surface, so a terminal is an ordinary compositor
/// client and coexists with other windows (a GUI login, say) — focus
/// decides who types. Blocks until a key reaches our surface; 0 on error.
fn nextKey() u8 {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .next_input, 0)) {
        .ok => |rep| switch (rep) {
            .input => |x| @intCast(x.ch & 0xff),
            else => 0,
        },
        .err => 0,
    };
}

/// A shell's console over a surface: writes render as glyphs, reads
/// return keystrokes the compositor routes to us while we hold focus.
/// The client (a shell) sees exactly the ConsReq interface the
/// virtio-console driver gives, so it runs here unchanged.
fn serveConsole(log_h: u64, chan_h: u64) noreturn {
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
                // One keystroke from the compositor (blocks until one
                // reaches our surface), handed to the client's buffer. A
                // shell reads a character at a time, so one per read is
                // exactly its rhythm.
                if (out_va == 0 or q.max == 0) {
                    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 3 } }, 0);
                    continue;
                }
                const ch = nextKey();
                const dst: [*]volatile u8 = @ptrFromInt(out_va);
                var n: u64 = 0;
                if (ch != 0 and out_len >= 1) {
                    dst[0] = ch;
                    n = 1;
                }
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = n } }, 0);
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
