//! The terminal: a surface client that renders a character grid onto the
//! display server's scanout — the userspace analog of the kernel's
//! framebuffer console, but a normal program drawing into a surface it
//! got from gpusvc, so it coexists with any other graphical client.
//!
//! It keeps a real text MODEL, not just pixels: a ring of logical lines
//! (the text between hard newlines) plus the line currently being built.
//! A small VT parser folds the escape sequences a shell's line editor and
//! `msh` emit (CR, LF, cursor left/right, erase-to-EOL, erase-screen,
//! home) into edits of that model, and a renderer soft-wraps the model to
//! the current column count and paints the visible viewport. Because the
//! model is width-independent, SCROLLBACK is just keeping old lines and a
//! view offset (page up/down), and REFLOW on resize is a re-render at the
//! new width — no pixels are ever reflowed.
//!
//! Modes (the low byte of the role arg): 0 = the console seat (a
//! full-scanout surface the terminal owns, serving a shell); 1 = a demo
//! that renders enough to scroll and holds for a screendump; 2 = a
//! windowed terminal (the shared frame's chrome + a shell behind it),
//! launched from the desktop dock.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const wf = @import("windowframe.zig");
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

// Private control bytes inputsvc sends for page up / down: the terminal
// intercepts them for scrollback and never forwards them to the shell.
const pg_up: u8 = 0x1e;
const pg_dn: u8 = 0x1f;

var px: [*]volatile u32 = undefined;
var stride: usize = 0; // pixels per scanline
var cols: usize = 0;
var rows: usize = 0;
var pxw: usize = 0;
var pxh: usize = 0;
// The grid occupies a RECTANGLE of the surface: [gox, gox+grid_w) x
// [goy, goy+grid_h), in surface pixels (stride = surface width). Full
// screen (the console seat) sets it to the whole surface; a windowed
// terminal sets it to the frame's content area, below the titlebar.
var gox: usize = 0;
var goy: usize = 0;
var grid_w: usize = 0;
var grid_h: usize = 0;

// The cell size: the bitmap 8x16 by default, or the system mono font's
// advance and line height once fontsvc is attached.
var cellw: usize = gw;
var cellh: usize = gh;

var windowed = false; // mode 2: commit through the frame, not the raw surface

// ------------------------------------------------------------ text model
//
// Logical lines are stored in a fixed ring; `total` counts every line ever
// committed (monotonic), and the ring holds the last min(total, scrollback)
// of them. The active line is the one being built — a shell's line editor
// rewrites it in place (CR + overwrite + erase-to-EOL), so it is mutable
// until a '\n' commits it.

const scrollback = 1000; // logical lines kept
const line_cap = 640; // bytes per logical line (msh's 512 edit line + a prompt, or a soft break)

var lines: [scrollback][line_cap]u8 = undefined;
var line_len: [scrollback]u16 = @splat(0);
var total: usize = 0; // logical lines committed ever

var act: [line_cap]u8 = @splat(' ');
var act_len: usize = 0; // written extent of the active line
var act_cur: usize = 0; // cursor column within the active line

var clear_base: usize = 0; // logical-line index the last screen-clear (2J) put at the viewport top
var scroll_off: usize = 0; // display rows scrolled up from the live bottom (0 = following)

// VT parser state.
var esc: enum { none, esc, csi } = .none;
var csi_n: usize = 0;

fn firstVisible() usize {
    return total - @min(total, scrollback);
}

fn lenAt(li: usize) usize {
    return line_len[li % scrollback];
}

fn bytesAt(li: usize) []const u8 {
    return lines[li % scrollback][0..lenAt(li)];
}

/// Display rows a logical line of `len` bytes occupies at the current
/// width — at least one (an empty line still shows as a blank row).
fn wrapRows(len: usize) usize {
    if (cols == 0) return 1;
    if (len == 0) return 1;
    return (len + cols - 1) / cols;
}

/// Commit the active line into the ring and start a fresh active line.
fn commitLine() void {
    const slot = total % scrollback;
    const n: u16 = @intCast(@min(act_len, line_cap));
    @memcpy(lines[slot][0..n], act[0..n]);
    line_len[slot] = n;
    total += 1;
    act_len = 0;
    act_cur = 0;
}

/// A printable byte at the cursor: overwrite (and extend) the active line.
fn putActive(b: u8) void {
    if (act_cur >= line_cap) {
        // A logical line longer than the buffer: soft-break so nothing is
        // lost, then keep going on a fresh line.
        commitLine();
    }
    act[act_cur] = b;
    act_cur += 1;
    if (act_cur > act_len) act_len = act_cur;
}

fn writeByte(b: u8) void {
    switch (esc) {
        .esc => {
            esc = if (b == '[') .csi else .none;
            csi_n = 0;
            return;
        },
        .csi => {
            if (b >= '0' and b <= '9') {
                csi_n = csi_n * 10 + (b - '0');
                return;
            }
            esc = .none;
            const n = if (csi_n == 0) 1 else csi_n;
            switch (b) {
                'C' => act_cur = @min(act_cur + n, line_cap - 1), // cursor right
                'D' => act_cur -= @min(n, act_cur), // cursor left
                'K' => act_len = act_cur, // erase to end of line
                'J' => clear_base = total, // erase screen: frame the viewport below all prior lines
                'H' => act_cur = 0, // cursor home (paired with 2J; the redraw follows)
                else => {},
            }
            return;
        },
        .none => {},
    }
    switch (b) {
        '\n' => commitLine(),
        '\r' => act_cur = 0,
        0x1b => esc = .esc,
        0x08 => act_cur -= @min(@as(usize, 1), act_cur), // backspace: move left
        '\t' => {
            var next = (act_cur / 8 + 1) * 8;
            if (next <= act_cur) next = act_cur + 1;
            while (act_cur < next) putActive(' ');
        },
        else => if ((b >= 0x20 and b < 0x7f) or b >= 0x80) putActive(b),
    }
}

fn writeText(s: []const u8) void {
    for (s) |b| writeByte(b);
}

// -------------------------------------------------------- system font (fontsvc)
// When the terminal is given a `font` cap it renders in the real mono
// family at the effective scale: each byte's glyph is fetched from fontsvc
// once and cached locally by codepoint, then blitted from the shared atlas
// at fixed monospace cells.
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

// ------------------------------------------------------------- rendering
//
// Cell (col, row) is grid-relative: pixel origin (gox + col*cellw,
// goy + row*cellh). Everything clips to the grid rectangle.

/// Fill the whole grid rectangle with the background.
fn clearRect() void {
    var y: usize = 0;
    while (y < grid_h) : (y += 1) {
        const base = (goy + y) * stride + gox;
        var x: usize = 0;
        while (x < grid_w) : (x += 1) px[base + x] = bg;
    }
}

/// Blit one glyph into cell (col, row). The rectangle is assumed already
/// cleared, so this only lays down coverage.
fn drawGlyphAt(col: usize, row: usize, b: u8) void {
    if (font_ok) {
        const g = glyphOf(b) orelse return;
        const baseline = goy + row * cellh + ascent;
        var r: usize = 0;
        while (r < g.h) : (r += 1) {
            const arow = (@as(usize, g.ay) + r) * fatlas_w + g.ax;
            var c: usize = 0;
            while (c < g.w) : (c += 1) {
                const cov: u32 = fatlas[arow + c];
                if (cov == 0) continue;
                const dx = @as(i64, @intCast(gox + col * cellw)) + g.left + @as(i64, @intCast(c));
                const dy = @as(i64, @intCast(baseline)) + g.top + @as(i64, @intCast(r));
                if (dx < @as(i64, @intCast(gox)) or dy < @as(i64, @intCast(goy))) continue;
                const ux: usize = @intCast(dx);
                const uy: usize = @intCast(dy);
                if (ux >= gox + grid_w or uy >= goy + grid_h) continue;
                px[uy * stride + ux] = cov << 16 | cov << 8 | cov;
            }
        }
        return;
    }
    const gi: usize = if (b < font.first or b > font.last) 0 else b - font.first;
    const bitmap = font.glyphs[gi];
    for (0..gh) |gy| {
        if (row * cellh + gy >= grid_h) break;
        const bits = bitmap[gy];
        const base = (goy + row * cellh + gy) * stride + gox + col * cellw;
        inline for (0..gw) |gx| {
            if (col * cellw + gx < grid_w and (bits & (@as(u8, 0x80) >> gx) != 0)) px[base + gx] = fg;
        }
    }
}

/// A solid block where the cursor rests.
fn drawCursorAt(col: usize, row: usize) void {
    var y: usize = 0;
    while (y < cellh and row * cellh + y < grid_h) : (y += 1) {
        const base = (goy + row * cellh + y) * stride + gox + col * cellw;
        var x: usize = 0;
        while (x < cellw and col * cellw + x < grid_w) : (x += 1) px[base + x] = fg;
    }
}

/// Draw the sub-rows of one logical line that fall inside the viewport
/// [top, top+rows); returns the display row after this line.
fn drawLogical(dr0: usize, top: usize, bytes: []const u8) usize {
    const nsub = wrapRows(bytes.len);
    var s: usize = 0;
    while (s < nsub) : (s += 1) {
        const dr = dr0 + s;
        if (dr >= top and dr < top + rows) {
            const vr = dr - top;
            const from = s * cols;
            const to = @min(from + cols, bytes.len);
            var c: usize = from;
            while (c < to) : (c += 1) drawGlyphAt(c - from, vr, bytes[c]);
        }
    }
    return dr0 + nsub;
}

var last_top: usize = 0; // for logging
var last_w: usize = 0;

/// Repaint the visible viewport from the model. Does not touch the chrome
/// (that lives outside the grid rectangle).
fn render() void {
    clearRect();
    if (cols == 0 or rows == 0) return;

    // Pass 1: total display rows and the display row the last clear framed.
    var w: usize = 0;
    var clear_dr: usize = 0;
    const vis0 = firstVisible();
    var li = vis0;
    while (li < total) : (li += 1) {
        if (li == clear_base) clear_dr = w;
        w += wrapRows(lenAt(li));
    }
    const committed_dr = w;
    if (clear_base >= total) clear_dr = committed_dr;
    if (clear_base < vis0) clear_dr = 0; // the clear point scrolled out of the ring
    const cursor_sub = if (cols == 0) 0 else act_cur / cols;
    const act_rows = @max(wrapRows(act_len), cursor_sub + 1);
    w += act_rows;

    // The live top follows the bottom, but right after a clear it frames
    // the cleared point at the top until enough new content overflows.
    const live_top = if (w - clear_dr <= rows) clear_dr else w - rows;
    if (scroll_off > live_top) scroll_off = live_top;
    const top = live_top - scroll_off;
    last_top = top;
    last_w = w;

    // Pass 2: draw the committed lines, then the active line, then the cursor.
    var dr: usize = 0;
    li = vis0;
    while (li < total) : (li += 1) dr = drawLogical(dr, top, bytesAt(li));
    _ = drawLogical(committed_dr, top, act[0..act_len]);

    const cursor_dr = committed_dr + cursor_sub;
    if (cursor_dr >= top and cursor_dr < top + rows) {
        drawCursorAt(if (cols == 0) 0 else act_cur % cols, cursor_dr - top);
    }
}

/// Push the rendered surface to the compositor (through the frame when
/// windowed, else the raw surface commit).
fn push() void {
    if (windowed) _ = wf.commitSurface() else _ = commit(pxw, pxh);
}

/// Scroll the viewport a page. Returns true (the caller re-renders).
fn scrollBy(up: bool, log_h: u64) void {
    const step = if (rows > 1) rows - 1 else 1;
    if (up) scroll_off += step else scroll_off -= @min(step, scroll_off);
    render();
    push();
    const state = if (scroll_off == 0) "following" else if (last_top == 0) "at-top" else "mid";
    var l: [72]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&l, "term: scroll {s} top={d} of {d}", .{ state, last_top, last_w }) catch "term: scroll");
}

// -------------------------------------------------------------- geometry

/// Recompute the columns and rows for the current grid rectangle.
fn fitGrid() void {
    cols = if (cellw > 0) grid_w / cellw else 0;
    rows = if (cellh > 0) grid_h / cellh else 0;
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

    // Mode 2: a WINDOWED terminal — a desktop window (shared frame chrome)
    // serving a shell, launched from the dock. Modes 0/1 are the console
    // seat: a full-scanout surface term owns directly.
    if (role & 0xff == 2) windowedMain(log_h, chan_h);

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
    // The grid fills the whole surface in the console seat.
    gox = 0;
    goy = 0;
    grid_w = pxw;
    grid_h = pxh;
    fitGrid();
    clearRect();

    // Mode 1: the demo (render + hold for a screendump, then end the boot).
    // Mode 0: serve the console — a client writes bytes we render and reads
    // keystrokes we fetch from the compositor (the seat).
    if (role & 0xff == 1) demo(log_h) else serveConsole(log_h, chan_h, false);
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
    render();
    if (!commit(pxw, pxh)) usys.exit(184);
    _ = usys.log(log_h, "term: rendered");
    usys.sleepMs(4000);
    usys.exit(0);
}

/// The keyboard, from the compositor: kind 0 is a keystroke to the focused
/// surface. Returns {kind, ch}; kind 0xff on channel error.
const Raw = struct { kind: u64, ch: u8 };
fn nextRaw() Raw {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .next_input, 0)) {
        .ok => |rep| switch (rep) {
            .input => |x| .{ .kind = x.kind, .ch = @intCast(x.arg & 0xff) },
            else => .{ .kind = 0xff, .ch = 0 },
        },
        .err => .{ .kind = 0xff, .ch = 0 },
    };
}

/// A shell's console over a surface. `windowed_mode` selects how input is
/// pumped (the raw surface vs the frame) and how output is committed. The
/// client (a shell) sees exactly the ConsReq interface the virtio-console
/// driver gives, so it runs here unchanged.
fn serveConsole(log_h: u64, chan_h: u64, windowed_mode: bool) noreturn {
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
                render();
                push();
                _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .n = .{ .n = w.len } }, 0);
            },
            .read => |q| {
                // One keystroke, handed to the client's buffer. A shell
                // reads a character at a time, so one per read is its rhythm.
                if (out_va == 0 or (windowed_mode == false and q.max == 0)) {
                    _ = usys.replyTyped(shared.ConsResp, chan_h, .{ .cons_err = .{ .code = 3 } }, 0);
                    continue;
                }
                const ch = if (windowed_mode) pumpKey(log_h) else readSeatKey(log_h);
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

/// Block for one keystroke on the full-screen seat, intercepting the
/// scrollback keys (page up/down) and ignoring non-key events. Snaps the
/// view back to the bottom when a real key is typed. 0 on channel error.
fn readSeatKey(log_h: u64) u8 {
    while (true) {
        const e = nextRaw();
        if (e.kind == 0xff) return 0;
        if (e.kind != 0) continue; // pointer / tick / restore: not a keystroke
        if (e.ch == pg_up) {
            scrollBy(true, log_h);
            continue;
        }
        if (e.ch == pg_dn) {
            scrollBy(false, log_h);
            continue;
        }
        if (scroll_off != 0) {
            scroll_off = 0;
            render();
            push();
        }
        return e.ch;
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

// ------------------------------------------- windowed terminal (desktop)
//
// A desktop terminal: term inside the shared window frame (`wf`), with a
// full `msh` behind it. The frame owns the titlebar / dragging / snapping /
// close; term draws the glyph grid into the frame's content area and serves
// the same ConsReq the console seat does. Launched from the dock.

/// Fit the grid to the frame's content area (below the titlebar).
fn layoutGrid() void {
    const cr = wf.contentRect();
    gox = cr.x;
    goy = cr.y;
    grid_w = cr.w;
    grid_h = cr.h;
    fitGrid();
}

/// The traffic-light dot centres in scanout coordinates — the same line the
/// mshl runtime logs, so a host (a drill) can click close/minimize/maximize.
fn logDots(log_h: u64) void {
    var l: [96]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: dots close={d},{d} min={d},{d} max={d},{d}", .{
        wf.win_x + wf.dots_cx[0], wf.win_y + wf.dots_cy,
        wf.win_x + wf.dots_cx[1], wf.win_y + wf.dots_cy,
        wf.win_x + wf.dots_cx[2], wf.win_y + wf.dots_cy,
    }) catch "gui: dots");
}

/// Repaint the titlebar + the grid and push the whole window.
fn repaintWin() void {
    wf.drawChrome("Terminal");
    render();
    _ = wf.commitSurface();
}

fn windowedMain(log_h: u64, chan_h: u64) noreturn {
    windowed = true;
    wf.setup(disp, log_h, "", font_chan);
    wf.useOrdinaryChannel(); // a badged compositor channel, like any window
    wf.win_w = 760;
    wf.win_h = 520;
    wf.win_x = (wf.scanout_w - wf.win_w) / 2;
    wf.win_y = (wf.scanout_h - wf.win_h) / 2;
    if (!wf.openSurface(true)) usys.exit(185);
    px = wf.px;
    stride = wf.win_w;
    pxw = wf.win_w;
    pxh = wf.win_h;
    fontReady(); // term's own mono font (the frame's title font is separate)
    // drawChrome sets title_h, which contentRect() (hence layoutGrid's grid
    // origin) depends on — so paint the titlebar BEFORE laying out the grid,
    // or the grid starts at y=0 and overwrites the titlebar.
    wf.drawChrome("Terminal");
    layoutGrid();
    render();
    if (!wf.commitSurface()) usys.exit(186);
    logDots(log_h);
    _ = usys.log(log_h, "gui: ready");
    serveConsole(log_h, chan_h, true);
}

/// Pump frame input until a keystroke arrives, handling the titlebar (drag /
/// snap / close), focus, restore and scrollback (page up/down) along the
/// way. Returns the key byte, or 0 if the display channel died.
fn pumpKey(log_h: u64) u8 {
    while (true) {
        const ev = wf.nextInput() orelse return 0;
        switch (ev.kind) {
            0 => { // a keystroke: scrollback keys are ours, the rest go to the shell
                if (ev.ch == pg_up) {
                    scrollBy(true, log_h);
                    continue;
                }
                if (ev.ch == pg_dn) {
                    scrollBy(false, log_h);
                    continue;
                }
                if (scroll_off != 0) {
                    scroll_off = 0;
                    render();
                    _ = wf.commitSurface();
                }
                return ev.ch;
            },
            1 => switch (wf.onPointer(ev, "Terminal")) {
                .close, .resize_failed => usys.exit(0), // red dot, or a fatal resize: end (the shell follows)
                .resized => {
                    // The frame recreated the surface at a new size: re-point
                    // at its buffer, refit the grid, REFLOW (re-render the
                    // model at the new width) and repaint the chrome.
                    px = wf.px;
                    stride = wf.win_w;
                    pxw = wf.win_w;
                    pxh = wf.win_h;
                    layoutGrid();
                    repaintWin();
                    logDots(log_h); // the dots moved with the window
                    var l: [56]u8 = undefined;
                    _ = usys.log(log_h, std.fmt.bufPrint(&l, "term: reflow cols={d} rows={d}", .{ cols, rows }) catch "term: reflow");
                },
                else => {}, // none / moved / minimized (frame hid it) / content — keep pumping
            },
            3 => repaintWin(), // restored from the dock: repaint (the compositor unhid us)
            4 => { // focus changed: dim / brighten the chrome
                wf.win_focused = ev.ch != 0;
                repaintWin();
            },
            else => {},
        }
    }
}
