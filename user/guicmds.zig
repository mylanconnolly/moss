//! gui — the mshl GUI runtime, a hosted command family (like net/fs/http)
//! wired into a host that holds a `display` cap. A GUI is a *service*
//! written as two pure mshl functions and a declarative view:
//!
//!   gui {
//!     init:   { count: 0 }
//!     view:   (fn [state] { { kind: column, children: [
//!               { kind: label,  text: $"count ($state.count)" }
//!               { kind: button, id: "inc",  label: "increment" }
//!               { kind: button, id: "quit", label: "quit" }
//!             ] } })
//!     update: (fn [state, ev] { match $ev.id {
//!               "inc"  => { $state | merge { count: ($state.count + 1) } }
//!               "quit" => { $state | merge { done: true } }
//!               _      => $state
//!             } })
//!   }
//!
//! The runtime owns the surface: it renders `view state`, routes input
//! (the keyboard — Tab moves focus between the focusable widgets, Enter
//! fires the focused one — and the pointer — a click focuses the widget
//! under it and fires a button), and on each fire calls `update state {id}`, threads
//! the returned state forward, and re-renders. The app never loops and
//! never blocks — it is a pure function of state and event, so it is a
//! supervised, crash-only, fabric-shippable service in the making (only
//! data — the view, the event id, the state — ever crosses). `update`
//! returning a state with `done: true` closes the window; `gui` answers
//! with the final state. Keyboard-only for now (no pointer yet).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const workcmds = @import("workcmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const font = shared.font8x16;

var display: u64 = 0; // the compositor channel (surface protocol + input)
var chan: u64 = 0; // the channel a session drives: `display`, or a trusted one
var log_h: u64 = 0;
var trust_token: u64 = 0; // the trusted-path token, if the host was given one

// Crash-isolation of `update` (opt-in `gui { isolate: true }`): the app's
// `update` runs in a worker domain, so a fault or panic in it kills only
// that domain — the runtime detects the dead worker, re-spawns it, drops
// the offending event, and carries on. `iso_src` is the reconstructed
// worker script (kept for re-spawn); `iso_conn` the live worker, if any.
var iso_conn: ?workcmds.Conn = null;
var iso_src: []const u8 = "";

// The system font service, when the host holds one: text is laid out and
// rasterized there (a shared coverage atlas), so the GUI renders in the
// real family at the accessibility scale. Without it we fall back to the
// built-in bitmap font — see `haveFont`/`drawStr`.
var font_chan: u64 = 0;
var font_buf: [*]u8 = undefined; // our request/response buffer (shm)
var font_buf_len: usize = 0;
var atlas: [*]const u8 = undefined; // fontsvc's coverage atlas (mapped ro)
var atlas_w: usize = 0;
var font_ok = false; // fontsvc is attached and usable
const n_roles = 3;
var role_line: [n_roles]usize = @splat(0);
var role_asc: [n_roles]usize = @splat(0);

pub fn setup(display_cap: u64, log: u64, secret: []const u8, font_cap: u64) void {
    display = display_cap;
    log_h = log;
    font_chan = font_cap;
    if (secret.len >= 8) trust_token = std.mem.readInt(u64, secret[0..8], .little);
}

/// Whether the host holds a display — `gui` is offered only then.
pub fn on() bool {
    return display != 0;
}

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "gui")) {
        return .{ .params = &.{.{ .name = "spec", .shape = .record }}, .input = .{ .optional = .record }, .ret = .any };
    }
    // `sessionfont TEXT` pushes a user font layer (the text of a font.msh)
    // to the shared font service for this session; no arg / "" reverts.
    if (std.mem.eql(u8, name, "sessionfont")) {
        return .{ .params = &.{.{ .name = "layer", .shape = .string, .optional = true }}, .input = .{ .optional = .string }, .ret = .any };
    }
    return null;
}

// ------------------------------------------------------------ rendering

// Text is drawn through the system font service when the host has one
// (real vector families, scaled centrally); the built-in 8x16 bitmap,
// drawn 2x crisp (`drawGlyph`), is the fallback. `drawStr`/`strW` pick.
const fsw = font.width; //  8, source
const fsh = font.height; // 16, source
const gw = fsw * 2; // 16, the bitmap cell width
const gh = fsh * 2; // 32, the bitmap cell height

// A centred window on the 1024x768 scanout, with room to breathe.
const win_w = 680;
const win_h = 460;
const win_x = (1024 - win_w) / 2; // 172
const win_y = (768 - win_h) / 2; // 154

const pad = 24; // window inset for content

// Colours as X<<24 | R<<16 | G<<8 | B, so a screendump reads them as RGB.
const c_bg: u32 = 0x0016_1a2e; // a deep slate window ground
const c_fg: u32 = 0x00E0_E0E0; // label text
const c_title: u32 = 0x0066_99FF; // the title line
const c_rule: u32 = 0x0033_3d55; // the rule under the title
const c_btn: u32 = 0x0088_BBFF; // an unfocused button's label + outline
const c_btn_bg: u32 = 0x001e_2740; // an unfocused button's fill
const c_focus_bg: u32 = 0x0022_66CC; // the focused widget's highlight
const c_focus_fg: u32 = 0x00FF_FFFF;
const c_field_bg: u32 = 0x0022_2838; // an unfocused field's value box
const c_field_edge: u32 = 0x003a_445e; // a field/button box outline

var px: [*]volatile u32 = undefined; // the mapped surface, win_w*win_h
var surf: u64 = 0;

// A focusable widget: its id, whether it is a text field (which eats
// typing) or a button (which fires on Enter), and its clickable box on
// the surface (so a pointer press can hit-test which widget it landed on).
const Focus = struct { id: []const u8, is_field: bool, bx: usize = 0, by: usize = 0, bw: usize = 0, bh: usize = 0 };
var focusables: [16]Focus = undefined;

/// The focusable whose box contains (x, y) — surface-local, the pointer's
/// coordinates — or null. Topmost-last wins (widgets do not overlap).
fn hitWidget(n: usize, x: usize, y: usize) ?usize {
    var i: usize = 0;
    while (i < n and i < focusables.len) : (i += 1) {
        const f = focusables[i];
        if (x >= f.bx and x < f.bx + f.bw and y >= f.by and y < f.by + f.bh) return i;
    }
    return null;
}

// The runtime owns the live text of each field (keyed by id), seeded from
// the view's `value` when the field first appears. The app's `update`
// sees the committed text only when a button fires (in the event's
// `fields`), so it stays a pure function of coarse events, not keystrokes.
const max_fields = 8;
const FieldBuf = struct {
    used: bool = false,
    id: [32]u8 = undefined,
    id_len: usize = 0,
    buf: [64]u8 = undefined,
    len: usize = 0,
};
var field_bufs: [max_fields]FieldBuf = @splat(.{});

fn resetFields() void {
    field_bufs = @splat(.{});
}

/// The edit buffer for a field id, created (seeded from `seed`) on first sight.
fn fieldFor(id: []const u8, seed: []const u8) *FieldBuf {
    for (&field_bufs) |*f| {
        if (f.used and std.mem.eql(u8, f.id[0..f.id_len], id)) return f;
    }
    for (&field_bufs) |*f| {
        if (!f.used) {
            f.used = true;
            f.id_len = @min(id.len, f.id.len);
            @memcpy(f.id[0..f.id_len], id[0..f.id_len]);
            f.len = @min(seed.len, f.buf.len);
            @memcpy(f.buf[0..f.len], seed[0..f.len]);
            return f;
        }
    }
    return &field_bufs[0]; // more than max_fields: reuse the first slot
}

fn fieldAppend(id: []const u8, ch: u8) void {
    const f = fieldFor(id, "");
    if (f.len < f.buf.len) {
        f.buf[f.len] = ch;
        f.len += 1;
    }
}

fn fieldBackspace(id: []const u8) void {
    const f = fieldFor(id, "");
    if (f.len > 0) f.len -= 1;
}

fn fillAll(word: u32) void {
    for (0..win_w * win_h) |i| px[i] = word;
}

fn putPx(x: usize, y: usize, word: u32) void {
    if (x < win_w and y < win_h) px[y * win_w + x] = word;
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, word: u32) void {
    var yy = y;
    while (yy < y + h and yy < win_h) : (yy += 1) {
        var xx = x;
        while (xx < x + w and xx < win_w) : (xx += 1) px[yy * win_w + xx] = word;
    }
}

/// A `thick`-pixel outline around the rect (x, y, w, h).
fn strokeRect(x: usize, y: usize, w: usize, h: usize, word: u32, thick: usize) void {
    fillRect(x, y, w, thick, word); // top
    if (h > thick) fillRect(x, y + h - thick, w, thick, word); // bottom
    fillRect(x, y, thick, h, word); // left
    if (w > thick) fillRect(x + w - thick, y, thick, h, word); // right
}

/// Draw one glyph at (cx, cy), scaled 2x crisp: each source pixel becomes
/// a solid 2x2 block — no smoothing, so the letterforms stay sharp (a
/// clean pixel font, not blurred or rounded). The whole 16x32 cell is
/// painted, `on` pixels `fg` and the rest `bg` (no stale pixels behind).
fn drawGlyph(cx: usize, cy: usize, ch: u8, fg: u32, bg: u32) void {
    const g: usize = if (ch < font.first or ch > font.last) 0 else ch - font.first;
    const bmp = font.glyphs[g];
    var sy: usize = 0;
    while (sy < fsh) : (sy += 1) {
        const bits = bmp[sy];
        var sx: usize = 0;
        while (sx < fsw) : (sx += 1) {
            const word = if (bits & (@as(u8, 0x80) >> @intCast(sx)) != 0) fg else bg;
            const ox = cx + sx * 2;
            const oy = cy + sy * 2;
            putPx(ox, oy, word);
            putPx(ox + 1, oy, word);
            putPx(ox, oy + 1, word);
            putPx(ox + 1, oy + 1, word);
        }
    }
}

/// Draw a string at (x, y) with a foreground and background colour, one
/// 16x32 glyph cell per character, clipped to the window (bitmap fallback).
fn drawText(x: usize, y: usize, s: []const u8, fg: u32, bg: u32) void {
    for (s, 0..) |ch, i| {
        const cx = x + i * gw;
        if (cx + gw > win_w or y + gh > win_h) break;
        drawGlyph(cx, y, ch, fg, bg);
    }
}

// ------------------------------------------------ system font (fontsvc)

const R_UI: u64 = @intFromEnum(shared.FontRole.ui);
const R_TITLE: u64 = @intFromEnum(shared.FontRole.title);

/// Attach to the font service once: our request/response buffer, the
/// shared atlas (mapped read-only), and each role's metrics. Sets
/// `font_ok`; on any failure we keep the bitmap fallback.
/// Attach our request/response buffer to fontsvc, once. Both rendering
/// (glyph runs) and the per-user layer push (`applyUserLayer`) stage
/// through it, so either path may bring it up first.
fn ensureFontBuf() bool {
    if (font_chan == 0) return false;
    if (font_buf_len != 0) return true;
    const sh = usys.shmCreate(2); // room for the glyph run of a line
    if (sh.err != .ok) return false;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) return false;
    font_buf = @ptrFromInt(m.data[0]);
    font_buf_len = m.data[1] * 4096;
    return switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .attach_buf, sh.data[0])) {
        .ok => |ok| ok.rep == .ok,
        .err => false,
    };
}

/// Push the logged-in user's font layer to the shared font service for the
/// life of this session — the per-user accessibility scale, merged over
/// the system layer centrally so every text client (this GUI, a terminal)
/// follows it. An empty layer reverts to the system default (logout). We
/// do NOT read metrics here: `fontReady` (lazy, on the first render) reads
/// the post-push metrics, so a push before the GUI opens is reflected.
pub fn applyUserLayer(text: []const u8) void {
    if (!ensureFontBuf()) return;
    const n = @min(text.len, font_buf_len);
    if (n > 0) @memcpy(font_buf[0..n], text[0..n]);
    _ = usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .reconfigure = .{ .len = n } }, 0);
}

fn fontReady() void {
    if (font_chan == 0) return;
    if (!ensureFontBuf()) return;
    const at = switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .atlas, 0)) {
        .ok => |ok| ok,
        .err => return,
    };
    if (at.cap == 0 or at.rep != .atlas) return;
    const am = usys.shmMap(at.cap);
    if (am.err != .ok) return;
    atlas = @ptrFromInt(am.data[0]);
    atlas_w = shared.unpackHi(at.rep.atlas.wh);
    for (0..n_roles) |role| {
        switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .metrics = .{ .role = role } }, 0)) {
            .ok => |rep| switch (rep) {
                .metrics => |mm| {
                    role_line[role] = @intCast(mm.line);
                    role_asc[role] = @intCast(mm.ascent);
                },
                else => {},
            },
            .err => return,
        }
    }
    font_ok = true;
}

/// Lay out `s` in `role` through fontsvc: the glyph run lands in `font_buf`
/// and the pen width is returned (0 on failure). Leaves the run in the
/// buffer for a following `blitRun` — no `layout` may intervene.
fn fontLayout(role: u64, s: []const u8) struct { w: usize, count: usize } {
    const len = @min(s.len, font_buf_len);
    @memcpy(font_buf[0..len], s[0..len]);
    return switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .layout = .{ .role = role, .px = 0, .len = len } }, 0)) {
        .ok => |rep| switch (rep) {
            .laid => |l| .{ .w = shared.unpackHi(l.pen), .count = @intCast(l.count) },
            else => .{ .w = 0, .count = 0 },
        },
        .err => .{ .w = 0, .count = 0 },
    };
}

/// Blend `fg` over the pixel at (x, y) by coverage `cov` (0..255).
fn blendPx(x: usize, y: usize, fg: u32, cov: u32) void {
    if (x >= win_w or y >= win_h or cov == 0) return;
    const i = y * win_w + x;
    if (cov >= 255) {
        px[i] = fg;
        return;
    }
    const dst = px[i];
    var out: u32 = 0;
    inline for (.{ 0, 8, 16 }) |shf| {
        const f = (fg >> shf) & 0xff;
        const d = (dst >> shf) & 0xff;
        out |= (((f * cov + d * (255 - cov)) / 255) & 0xff) << shf;
    }
    px[i] = out;
}

/// Blit the glyph run currently in `font_buf` (from `fontLayout`) at pen
/// origin `x0` and baseline `by`, blending each glyph's coverage as `fg`.
fn blitRun(x0: usize, by: usize, count: usize, fg: u32) void {
    const run: [*]const shared.FontGlyph = @ptrCast(@alignCast(font_buf));
    for (0..count) |i| {
        const g = run[i];
        var r: usize = 0;
        while (r < g.h) : (r += 1) {
            const arow = (@as(usize, g.atlas_y) + r) * atlas_w + g.atlas_x;
            var c: usize = 0;
            while (c < g.w) : (c += 1) {
                const cov = atlas[arow + c];
                if (cov == 0) continue;
                const dx = @as(i64, @intCast(x0)) + g.pen_x + g.left + @as(i64, @intCast(c));
                const dy = @as(i64, @intCast(by)) + g.top + @as(i64, @intCast(r));
                if (dx < 0 or dy < 0) continue;
                blendPx(@intCast(dx), @intCast(dy), fg, cov);
            }
        }
    }
}

/// The pixel width of `s` in `role`.
fn strW(role: u64, s: []const u8) usize {
    if (font_ok) return fontLayout(role, s).w;
    return s.len * gw;
}

/// The line height of `role` (row-to-row advance).
fn lineOf(role: u64) usize {
    return if (font_ok) role_line[role] else gh;
}

/// Draw `s` at content position (x, y_top) in `role`. Over the font path
/// text blends over the already-painted background (`bg` ignored); the
/// bitmap fallback paints `bg` behind each cell.
fn drawStr(x: usize, y_top: usize, role: u64, s: []const u8, fg: u32, bg: u32) void {
    if (font_ok) {
        const l = fontLayout(role, s);
        blitRun(x, y_top + role_asc[role], l.count, fg);
    } else {
        drawText(x, y_top, s, fg, bg);
    }
}

/// Render one view tree. Fills the window, draws the title and each child
/// of the (single, column) layout, highlighting the focused button, and
/// returns the focusable widgets' ids in order (into `ids_buf`).
fn strField(rec: mshl.Record, key: []const u8) []const u8 {
    return if (rec.get(key)) |v| (if (v == .str) v.str else "") else "";
}

/// Render one view tree into `focusables`, highlight the focused widget,
/// and return the number of focusable widgets.
fn renderTree(tree: Value, title: []const u8, focus: usize) usize {
    fillAll(c_bg);
    var y: usize = pad;
    if (title.len > 0) {
        drawStr(pad, y, R_TITLE, title, c_title, c_bg);
        y += lineOf(R_TITLE) + 10;
        fillRect(pad, y, win_w - 2 * pad, 2, c_rule); // a rule under the title
        y += 20;
    }
    var n: usize = 0;
    const children: []const Value = kids: {
        if (tree != .record) break :kids &.{};
        const c = tree.record.get("children") orelse break :kids &.{};
        break :kids if (c == .list) c.list else &.{};
    };
    for (children) |child| {
        if (child != .record) continue;
        const rec = child.record;
        const kind = strField(rec, "kind");
        const focused = n < focusables.len and n == focus;
        if (std.mem.eql(u8, kind, "label")) {
            drawStr(pad, y, R_UI, strField(rec, "text"), c_fg, c_bg);
            y += lineOf(R_UI) + 8;
        } else if (std.mem.eql(u8, kind, "button")) {
            // A padded, outlined box; filled and brightly outlined when
            // focused, a quiet fill otherwise — a button that reads as one.
            const label = strField(rec, "label");
            const bpx = 18; // horizontal padding inside the button
            const bpy = 8; // vertical padding
            const bw = strW(R_UI, label) + 2 * bpx;
            const bh = lineOf(R_UI) + 2 * bpy;
            const fill = if (focused) c_focus_bg else c_btn_bg;
            const edge = if (focused) c_focus_fg else c_field_edge;
            const ink = if (focused) c_focus_fg else c_btn;
            fillRect(pad, y, bw, bh, fill);
            strokeRect(pad, y, bw, bh, edge, 2);
            drawStr(pad + bpx, y + bpy, R_UI, label, ink, fill);
            if (n < focusables.len) {
                focusables[n] = .{ .id = strField(rec, "id"), .is_field = false, .bx = pad, .by = y, .bw = bw, .bh = bh };
                n += 1;
            }
            y += bh + 16;
        } else if (std.mem.eql(u8, kind, "field")) {
            // A label over a full-width, outlined value box holding the
            // live text (a caret when focused). Password fields show dots.
            const label = strField(rec, "label");
            const id = strField(rec, "id");
            const fb = fieldFor(id, strField(rec, "value"));
            drawStr(pad, y, R_UI, label, c_fg, c_bg);
            y += lineOf(R_UI) + 6;
            const fpy = 8; // vertical padding inside the box
            const bh = lineOf(R_UI) + 2 * fpy;
            const bw = win_w - 2 * pad;
            const box_bg = if (focused) c_focus_bg else c_field_bg;
            fillRect(pad, y, bw, bh, box_bg);
            strokeRect(pad, y, bw, bh, if (focused) c_focus_fg else c_field_edge, 2);
            const tx = pad + 12;
            const ty = y + fpy;
            const secret = rec.get("secret") != null and (rec.get("secret").?).asBool();
            var dots: [64]u8 = undefined;
            const shown: []const u8 = if (secret) blk: {
                const mlen = @min(fb.len, dots.len);
                for (0..mlen) |i| dots[i] = '*';
                break :blk dots[0..mlen];
            } else fb.buf[0..fb.len];
            drawStr(tx, ty, R_UI, shown, c_fg, box_bg);
            // A caret: a thin bar just past the text (cleaner than a glyph).
            if (focused) fillRect(tx + strW(R_UI, shown) + 1, ty, 2, lineOf(R_UI), c_focus_fg);
            if (n < focusables.len) {
                focusables[n] = .{ .id = id, .is_field = true, .bx = pad, .by = y, .bw = bw, .bh = bh };
                n += 1;
            }
            y += bh + 16;
        }
    }
    return n;
}

// ---------------------------------------------------- surface + input

/// Claim the trusted path: present the token and switch `chan` to the
/// badged channel the compositor mints, so surfaces made over it are the
/// login surface. False if there is no token or the compositor refuses.
fn attachTrusted() bool {
    if (trust_token == 0) return false;
    switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, display, .{ .attach_trusted = .{ .token = trust_token } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .trusted => {
                if (ok.cap == 0) return false;
                chan = ok.cap;
                return true;
            },
            else => return false,
        },
        .err => return false,
    }
}

fn openSurface() bool {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, chan, .{ .create_surface = .{ .xy = shared.packPair(win_x, win_y), .wh = shared.packPair(win_w, win_h) } }, 0)) {
        .ok => |ok| ok,
        .err => return false,
    };
    surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return false,
    };
    if (cs.cap == 0) return false;
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) return false;
    px = @ptrFromInt(m.data[0]);
    return true;
}

fn commitSurface() bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .commit = .{ .surface = surf, .xy = 0, .wh = shared.packPair(win_w, win_h) } }, 0)) {
        .ok => true,
        .err => false,
    };
}

fn closeSurface() void {
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .destroy_surface = .{ .surface = surf } }, 0);
}

/// An input event routed to our surface: a key (kind 0, `ch`) or a pointer
/// event (kind 1, surface-local `x`/`y` and button bitmask `btn`).
const Event = struct { kind: u64, ch: u8 = 0, x: usize = 0, y: usize = 0, btn: u64 = 0 };

/// The next input event routed to our surface, or null if the channel died.
fn nextInput() ?Event {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .next_input, 0)) {
        .ok => |rep| switch (rep) {
            .input => |v| .{ .kind = v.kind, .ch = @intCast(v.arg & 0xff), .x = shared.ptrX(v.arg), .y = shared.ptrY(v.arg), .btn = shared.ptrBtn(v.arg) },
            else => .{ .kind = 0, .ch = 0 },
        },
        .err => null,
    };
}

// ------------------------------------------------------------ the app

/// The event for a fired button: `{ id, fields: { <field id>: <text> } }`.
/// The field values are the runtime's live buffers — this is where the
/// text a user typed reaches the app, and the only place it does.
fn mkEvent(it: *mshl.Interp, id: []const u8) mshl.Error!Value {
    var nf: usize = 0;
    for (field_bufs) |f| {
        if (f.used) nf += 1;
    }
    const fkeys = try it.arena.alloc([]const u8, nf);
    const fvals = try it.arena.alloc(Value, nf);
    var i: usize = 0;
    for (field_bufs) |f| {
        if (!f.used) continue;
        fkeys[i] = try it.arena.dupe(u8, f.id[0..f.id_len]);
        fvals[i] = .{ .str = try it.arena.dupe(u8, f.buf[0..f.len]) };
        i += 1;
    }
    const fields = Value{ .record = .{ .keys = fkeys, .vals = fvals } };

    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "id";
    keys[1] = "fields";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = .{ .str = try it.arena.dupe(u8, id) };
    vals[1] = fields;
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

fn isDone(state: Value) bool {
    if (state != .record) return false;
    const d = state.record.get("done") orelse return false;
    return d.asBool();
}

// ------------------------------------------------- crash-isolated update

/// Reconstruct `update` (a `fn [stateParam, evParam] body`) as a worker
/// script that reads `$in`: bind each param, by position, from the
/// `{ state, ev }` record the runtime sends, then run the body verbatim.
/// Only data crosses — no captures — so the worker is a pure function of
/// the pair, exactly the GUI-as-a-service contract. The two params are
/// bound from the input's fixed `state`/`ev` fields regardless of how the
/// app named them. Returns null if `update` is not the expected 2-arg
/// shape (then the caller runs it in-process, unisolated). Arena-held, so
/// it survives across re-spawns within this `gui` call.
fn buildUpdateSrc(it: *mshl.Interp, cl: *const mshl.Closure) mshl.Error!?[]const u8 {
    if (cl.params.len != 2) return null;
    const in_keys = [_][]const u8{ "state", "ev" };
    var s: std.ArrayList(u8) = .empty;
    for (cl.params, in_keys) |p, key| {
        try s.appendSlice(it.arena, "let ");
        try s.appendSlice(it.arena, p);
        try s.appendSlice(it.arena, " = $in.");
        try s.appendSlice(it.arena, key);
        try s.append(it.arena, '\n');
    }
    try s.appendSlice(it.arena, cl.src);
    return s.items;
}

/// The `{ state, ev }` record a worker update reads as `$in`.
fn wrapStateEv(it: *mshl.Interp, state: Value, ev: Value) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "state";
    keys[1] = "ev";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = state;
    vals[1] = ev;
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// Run `update state ev`. Isolated in a worker when one is live: a clean
/// reply is the new state; if the app's update misbehaves — raises an
/// error, or faults its whole domain — the runtime logs it, drops the
/// offending event, keeps the state as it was, and (on a dead domain)
/// re-spawns a fresh worker, so it survives and keeps rendering. That is
/// the let-it-crash contract: an app bug takes down only the worker.
/// With no worker (isolation off, or a re-spawn that failed) it runs
/// `update` in-process, the old behaviour.
fn callUpdate(it: *mshl.Interp, update: Value, state: Value, ev: Value) mshl.Error!Value {
    if (iso_conn) |c| {
        const in = try wrapStateEv(it, state, ev);
        const good: ?Value = switch (try workcmds.callConn(it, c, in)) {
            .value => |v| v,
            .raised, .crashed => null,
        };
        if (good) |v| return v;
        // The update misbehaved (raised, or faulted its domain). Tear the
        // worker down and start a fresh one — a runaway leaves the old
        // worker's heap spent, so we never reuse it — drop the offending
        // event, and keep the last good state. The runtime lives on.
        _ = usys.log(log_h, "gui: update crashed — recovering");
        workcmds.close(c);
        iso_conn = workcmds.spawnBlock(it, iso_src);
        if (iso_conn == null) _ = usys.log(log_h, "gui: could not re-spawn the update worker; running in-process");
        return state;
    }
    return it.callValue(update, &.{ state, ev }, null, null);
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (std.mem.eql(u8, name, "sessionfont")) {
        const text: []const u8 = if (args.len > 0 and args[0] == .str)
            args[0].str
        else if (input != null and input.? == .str)
            input.?.str
        else
            "";
        applyUserLayer(text);
        return Value.nothing;
    }
    if (!std.mem.eql(u8, name, "gui")) return null;
    const spec: mshl.Record = if (args.len > 0 and args[0] == .record)
        args[0].record
    else if (input != null and input.? == .record)
        input.?.record
    else
        return it.fail("gui: a record {{ init, update, view }} expected", .{});

    const view = spec.get("view") orelse return it.fail("gui: `view` (a fn) is required", .{});
    const update = spec.get("update") orelse return it.fail("gui: `update` (a fn) is required", .{});
    if (view != .func or update != .func) return it.fail("gui: `view` and `update` must be functions", .{});
    var state = spec.get("init") orelse Value.nothing;
    const title = if (spec.get("title")) |t| (if (t == .str) t.str else "") else "";
    const want_trusted = spec.get("trusted") != null and (spec.get("trusted").?).asBool();
    const want_isolate = spec.get("isolate") != null and (spec.get("isolate").?).asBool();

    // Crash-isolate `update` in a worker domain when asked and able: an
    // app fault then kills only the worker, not the display runtime. The
    // worker lives for the whole session; `callUpdate` re-spawns it if it
    // dies. Best-effort — no spawner, or a 2-arg `update` we cannot
    // reconstruct, and we run `update` in-process as before.
    iso_conn = null;
    if (want_isolate and workcmds.canSpawn()) {
        if (try buildUpdateSrc(it, update.func)) |src| {
            iso_src = src;
            iso_conn = workcmds.spawnBlock(it, iso_src);
            if (iso_conn == null) _ = usys.log(log_h, "gui: could not spawn the update worker; running in-process");
        }
    }
    defer if (iso_conn) |c| workcmds.close(c);

    // A `trusted: true` GUI is a login greeter: claim the trusted path so
    // the compositor makes this the login surface — the secure strip is
    // shown while it holds focus and its keystrokes reach nobody else. It
    // needs the boot-provisioned token (a `secret` give); without it the
    // compositor refuses, and so do we.
    chan = display;
    if (want_trusted) {
        if (!attachTrusted()) return it.fail("gui: the trusted path was refused (no token, or the wrong one)", .{});
    }

    if (!openSurface()) return it.fail("gui: cannot open a surface", .{});
    defer closeSurface();
    resetFields();
    if (!font_ok) fontReady(); // attach the system font once (bitmap fallback if absent)

    var focus: usize = 0;
    var announced = false;
    while (true) {
        const tree = try it.callValue(view, &.{state}, null, null);
        const nfocus = renderTree(tree, title, focus);
        if (nfocus > 0 and focus >= nfocus) focus = nfocus - 1;
        if (!commitSurface()) return it.fail("gui: commit failed", .{});
        if (!announced) {
            _ = usys.log(log_h, "gui: ready");
            // Log each focusable widget's clickable centre in scanout
            // coordinates, so a host driving the pointer can click it.
            for (0..nfocus) |i| {
                const f = focusables[i];
                var l: [96]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: widget {s} at {d},{d}", .{ f.id, win_x + f.bx + f.bw / 2, win_y + f.by + f.bh / 2 }) catch continue);
            }
            announced = true;
        }

        // Wait for a key. Tab moves focus; a printable key or backspace
        // edits the focused field; Enter fires a focused button (with the
        // fields' text) or advances past a focused field. Each break
        // re-renders — the buffer, the focus, or the new state.
        var fired: ?[]const u8 = null;
        input: while (true) {
            const ev = nextInput() orelse return it.fail("gui: the display channel closed", .{});
            // A pointer press: hit-test the widget under it. Clicking a
            // button focuses and fires it; clicking a field focuses it.
            // A release or a click on no widget just keeps waiting.
            if (ev.kind == 1) {
                if (ev.btn & 1 != 0) {
                    if (hitWidget(nfocus, ev.x, ev.y)) |wi| {
                        focus = wi;
                        if (!focusables[wi].is_field) fired = focusables[wi].id;
                        break :input;
                    }
                }
                continue :input;
            }
            const ch = ev.ch;
            const cur: ?Focus = if (nfocus > 0) focusables[focus] else null;
            switch (ch) {
                '\t' => {
                    if (nfocus > 0) focus = (focus + 1) % nfocus;
                    break :input;
                },
                '\n' => {
                    if (cur) |c| {
                        if (c.is_field) {
                            focus = (focus + 1) % nfocus; // advance past a field
                        } else {
                            fired = c.id; // a button submits
                        }
                        break :input;
                    }
                },
                8 => { // backspace
                    if (cur) |c| if (c.is_field) {
                        fieldBackspace(c.id);
                        break :input;
                    };
                },
                else => {
                    if (ch >= 32 and ch < 127) {
                        if (cur) |c| if (c.is_field) {
                            fieldAppend(c.id, ch);
                            break :input;
                        };
                    }
                },
            }
        }
        if (fired) |id| {
            const ev = try mkEvent(it, id);
            state = try callUpdate(it, update, state, ev);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "gui: closed");
    return state;
}
