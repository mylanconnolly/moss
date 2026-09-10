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
//! with the final state.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const workcmds = @import("workcmds.zig");
const fabcmds = @import("fabcmds.zig");
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

// A `gui { node: N }` runs the whole app on node N: `remote_node` is N and
// `app_src` is the reconstructed worker (update+view over `$in`) shipped
// there each event. 0 = run in-process, as usual.
var remote_node: u64 = 0;
var app_src: []const u8 = "";
// The persistent remote stage: spawned once on node `remote_node` when the
// GUI opens, run per event, torn down when it closes — so the app's domain
// is spawned on the host once, not per event.
var remote_stage: ?fabcmds.Stage = null;

// The system font service, when the host holds one: text is laid out and
// rasterized there (a shared coverage atlas), so the GUI renders in the
// real family at the accessibility scale. Without it we fall back to the
// built-in bitmap font — see `haveFont`/`drawStr`.
var font_chan: u64 = 0;
// The fabric, when the host holds one: a `gui { node: N }` runs the app
// (its update+view) on node N — the fabric-transparent GUI. The runtime
// stays a pure viewer here: it renders the view tree the remote returns
// and ships each event, only data crossing.
var fab_chan: u64 = 0;
var font_buf: [*]u8 = undefined; // our request/response buffer (shm)
var font_buf_len: usize = 0;
var atlas: [*]const u8 = undefined; // fontsvc's coverage atlas (mapped ro)
var atlas_w: usize = 0;
var font_ok = false; // fontsvc is attached and usable
const n_roles = 3;
var role_line: [n_roles]usize = @splat(0);
var role_asc: [n_roles]usize = @splat(0);

pub fn setup(display_cap: u64, log: u64, secret: []const u8, font_cap: u64, fabric_cap: u64) void {
    display = display_cap;
    log_h = log;
    font_chan = font_cap;
    fab_chan = fabric_cap;
    if (secret.len >= 8) trust_token = std.mem.readInt(u64, secret[0..8], .little);
    // Register with the font service for a badged channel, so this process's
    // request buffer is its own — several GUI clients on one fontsvc (a
    // desktop's windows, the greeter + the session shell) no longer trample
    // a single shared buffer. Falls back to the unbadged channel (a shared
    // slot) if the service does not offer it.
    if (font_chan != 0) {
        const badged = registerFont();
        if (badged != 0) font_chan = badged;
    }
}

/// Ask the font service for a channel badged with a unique client id.
fn registerFont() u64 {
    return switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .register, 0)) {
        .ok => |ok| switch (ok.rep) {
            .registered => if (ok.cap != 0) ok.cap else 0,
            else => 0,
        },
        .err => 0,
    };
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
    // `appearance` reports the EFFECTIVE theme/contrast/colours the font
    // service is applying now (after locked keys), for a settings app to
    // display or a drill to check what a push actually took.
    if (std.mem.eql(u8, name, "appearance")) {
        return .{ .ret = .record };
    }
    // `restore-window TITLE` brings a running window with that title
    // forward (unhiding a minimized one) — the dock uses it so a pill for
    // an already-running app restores it instead of relaunching. `ok` when
    // one matched, an error otherwise (nothing by that title is up).
    if (std.mem.eql(u8, name, "restore-window")) {
        return .{ .params = &.{.{ .name = "title", .shape = .string }}, .ret = restore_result };
    }
    return null;
}

const restore_result = mshl.resultShape(.string, .string);

// ------------------------------------------------------------ rendering

// Text is drawn through the system font service when the host has one
// (real vector families, scaled centrally); the built-in 8x16 bitmap,
// drawn 2x crisp (`drawGlyph`), is the fallback. `drawStr`/`strW` pick.
const fsw = font.width; //  8, source
const fsh = font.height; // 16, source
const gw = fsw * 2; // 16, the bitmap cell width
const gh = fsh * 2; // 32, the bitmap cell height

// A centred window on the 1024x768 scanout, with room to breathe.
const win_w_default = 680;
const scanout_w = 1024;
var win_w: usize = win_w_default; // the app may narrow it (a desktop window)
var win_x: usize = (scanout_w - win_w_default) / 2; // centred unless placed

// A macOS-style titlebar: three traffic-light dots (close / minimize /
// maximize) at the left, the title centred, and the rest a drag handle.
const dot_r = 6; // dot radius
const dot_gap = 20; // spacing between dot centres
const tl_close: u32 = 0x00ff_5f57; // red
const tl_min: u32 = 0x00fe_bc2e; // amber
const tl_max: u32 = 0x0028_c840; // green
var title_h: usize = 0; // set each render; the drag-handle band height
var dots_cx: [3]usize = @splat(0);
var dots_cy: usize = 0;
// Whether this window holds focus (the compositor tells us with a `kind` 4
// event). An unfocused window dims its chrome — grey traffic lights, a
// muted title — the desktop's focus cue. A fresh window opens focused.
var win_focused = true;
// A drag in progress, and where in the window it was grabbed.
var dragging = false;
var drag_grab_x: usize = 0;
var drag_grab_y: usize = 0;
var ptr_down = false; // previous pointer button state (edge detection)
var pending_dot: ?usize = null; // a traffic-light pressed, awaiting release
const scanout_h = 768;
const win_h_min = 220;
const win_h_max = scanout_h - 48; // leave a margin top+bottom
// The window height is sized to its content when it opens (a settings
// panel is taller than a login form), then centred. Clamped to the
// scanout so it never renders off-screen.
var win_h: usize = 460;
var win_y: usize = (scanout_h - 460) / 2;

const pad = 24; // window inset for content

// Measuring pass: lay the tree out to find its height without drawing
// (the surface is sized from it before it is created). `measuring`
// suppresses the pixel-writing primitives; sizes still compute from the
// font metrics. `content_h` is the laid-out content height.
var measuring = false;
var content_h: usize = 0;

// ----------------------------------------------------------- the palette
//
// A GUI's look is a set of SEMANTIC tokens, not scattered literals, so the
// same widget code renders every theme. The tokens are resolved from three
// composable appearance axes (theme dark/light, contrast normal/high,
// colours default/colourblind-safe) served by fontsvc from the settings
// layer — so a user's choice (and the high-contrast / colourblind-safe
// accessibility switches) reaches every GUI system-wide. Colours are
// 0x00RRGGBB (XRGB, read straight by a screendump).

const Palette = struct {
    bg: u32, // the window ground
    surface: u32, // an elevated area (titlebar, cards)
    surface_hi: u32, // a raised element's fill (a default button)
    text: u32, // body text
    text_muted: u32, // secondary text (field labels, hints)
    title: u32, // the title / strong heading
    border: u32, // element outlines, the titlebar rule
    focus: u32, // the focus ring (never the only cue — focus also lifts)
    primary: u32, // the primary action's fill
    primary_ink: u32, // text on `primary`
    danger: u32, // a destructive action's fill
    danger_ink: u32, // text on `danger`
    field_bg: u32, // an inset text field
    border_w: usize, // outline thickness (thicker at high contrast)
    focus_w: usize, // focus-ring thickness
};

/// Scale each RGB channel of an XRGB colour by num/den (clamped) — for a
/// raised element's highlight (>1) and shade (<1) edges, so buttons read
/// with a little depth without a gradient.
fn shade(c: u32, num: u32, den: u32) u32 {
    const r: u32 = @min(((c >> 16) & 0xff) * num / den, 255);
    const g: u32 = @min(((c >> 8) & 0xff) * num / den, 255);
    const b: u32 = @min((c & 0xff) * num / den, 255);
    return (r << 16) | (g << 8) | b;
}

fn resolveTheme(theme: shared.Theme, contrast: shared.Contrast, cmode: shared.ColorMode) Palette {
    // Semantic accent/danger: a normal set, or the Okabe-Ito colourblind-
    // safe set (blue vs vermillion, distinguishable across common CVDs —
    // no red/green cue). Meaning is never carried by colour alone; the
    // labels and the raised shape say what a control is too.
    const cb = cmode == .cb_safe;
    var p: Palette = switch (theme) {
        .dark => .{
            .bg = 0x0f1420,
            .surface = 0x1a2133,
            .surface_hi = 0x2a3450,
            .text = 0xe6e9f0,
            .text_muted = 0x9aa4bd,
            .title = 0xf0f3fa,
            .border = 0x39435e,
            .focus = if (cb) 0x56b4e9 else 0x5aa2ff,
            .primary = if (cb) 0x0072b2 else 0x3d7dff,
            .primary_ink = 0xffffff,
            .danger = if (cb) 0xd55e00 else 0xe5484d,
            .danger_ink = 0xffffff,
            .field_bg = 0x121a2b,
            .border_w = 1,
            .focus_w = 3,
        },
        .light => .{
            .bg = 0xf2f4f8,
            .surface = 0xffffff,
            .surface_hi = 0xe7ebf2,
            .text = 0x1a1f2b,
            .text_muted = 0x5c6577,
            .title = 0x0f1420,
            .border = 0xc9d0dd,
            .focus = if (cb) 0x0072b2 else 0x2563eb,
            .primary = if (cb) 0x0072b2 else 0x2563eb,
            .primary_ink = 0xffffff,
            .danger = if (cb) 0xd55e00 else 0xdc2626,
            .danger_ink = 0xffffff,
            .field_bg = 0xffffff,
            .border_w = 1,
            .focus_w = 3,
        },
    };
    // High contrast: push ground and ink to the extremes, bolden the
    // outlines and the focus ring, and keep the accents bright and pure.
    if (contrast == .high) {
        const dark = theme == .dark;
        p.bg = if (dark) 0x000000 else 0xffffff;
        p.surface = p.bg;
        p.surface_hi = p.bg;
        p.field_bg = p.bg;
        p.text = if (dark) 0xffffff else 0x000000;
        p.text_muted = p.text;
        p.title = p.text;
        p.border = p.text;
        p.focus = if (dark) 0xffff00 else 0x0000ff;
        p.primary = if (cb) 0x009e73 else (if (dark) 0x2ea3ff else 0x0000cc);
        p.primary_ink = if (dark) 0x000000 else 0xffffff;
        p.danger = if (cb) 0xd55e00 else (if (dark) 0xff5b5b else 0xcc0000);
        p.danger_ink = if (dark) 0x000000 else 0xffffff;
        p.border_w = 2;
        p.focus_w = 5;
    }
    return p;
}

// The live palette, refreshed from fontsvc before each render.
var pal: Palette = resolveTheme(.dark, .normal, .default);

var px: [*]volatile u32 = undefined; // the mapped surface, win_w*win_h
var surf: u64 = 0;
var surf_cap: u64 = 0; // the surface buffer's shm cap (freed on close)
var surf_va: u64 = 0; // its mapped address (unmapped on close)

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
    if (measuring) return;
    for (0..win_w * win_h) |i| px[i] = word;
}

fn putPx(x: usize, y: usize, word: u32) void {
    if (measuring) return;
    if (x < win_w and y < win_h) px[y * win_w + x] = word;
}

fn fillRect(x: usize, y: usize, w: usize, h: usize, word: u32) void {
    if (measuring) return;
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

/// One rounded corner: the quarter-disc of radius `r` centred at (cx, cy),
/// filling the r×r box that extends in the (qx, qy) direction. Each pixel
/// is coverage-blended (a ~1px feather at the arc), so the curve reads
/// smooth against whatever is already painted there — no jaggies.
fn roundCorner(cx: usize, cy: usize, r: usize, word: u32, qx: i2, qy: i2) void {
    const cxf: f32 = @floatFromInt(cx);
    const cyf: f32 = @floatFromInt(cy);
    const rf: f32 = @floatFromInt(r);
    var iy: usize = 0;
    while (iy < r) : (iy += 1) {
        var ix: usize = 0;
        while (ix < r) : (ix += 1) {
            const pxu = if (qx < 0) cx - r + ix else cx + ix;
            const pyu = if (qy < 0) cy - r + iy else cy + iy;
            const dx = (@as(f32, @floatFromInt(pxu)) + 0.5) - cxf;
            const dy = (@as(f32, @floatFromInt(pyu)) + 0.5) - cyf;
            const cov = rf + 0.5 - @sqrt(dx * dx + dy * dy); // 1px feather
            if (cov <= 0) continue;
            blendPx(pxu, pyu, word, if (cov >= 1) 255 else @intFromFloat(cov * 255));
        }
    }
}

/// A filled rectangle with rounded, anti-aliased corners. Straight regions
/// are solid fills; the four corners are feathered discs. `r` is clamped
/// to half the shorter side (r == 0 degrades to a plain fill).
fn fillRoundRect(x: usize, y: usize, w: usize, h: usize, r_in: usize, word: u32) void {
    if (measuring or w == 0 or h == 0) return;
    var r = r_in;
    if (r > w / 2) r = w / 2;
    if (r > h / 2) r = h / 2;
    if (r == 0) return fillRect(x, y, w, h, word);
    fillRect(x, y + r, w, h - 2 * r, word); // the full-width middle band
    fillRect(x + r, y, w - 2 * r, r, word); // top edge between corners
    fillRect(x + r, y + h - r, w - 2 * r, r, word); // bottom edge
    roundCorner(x + r, y + r, r, word, -1, -1); // TL
    roundCorner(x + w - r, y + r, r, word, 1, -1); // TR
    roundCorner(x + r, y + h - r, r, word, -1, 1); // BL
    roundCorner(x + w - r, y + h - r, r, word, 1, 1); // BR
}

/// A rounded panel with a rounded border of thickness `bw`: the border
/// colour as the outer shape, the fill inset by `bw`. Both sets of corners
/// are AA — the outer against the ground, the inner against the border.
/// A filled, anti-aliased disc — a traffic-light dot.
fn fillDot(cx: usize, cy: usize, r: usize, word: u32) void {
    if (measuring) return;
    const cxf: f32 = @floatFromInt(cx);
    const cyf: f32 = @floatFromInt(cy);
    const rf: f32 = @floatFromInt(r);
    var y = if (cy > r) cy - r else 0;
    while (y <= cy + r and y < win_h) : (y += 1) {
        var x = if (cx > r) cx - r else 0;
        while (x <= cx + r and x < win_w) : (x += 1) {
            const dx = (@as(f32, @floatFromInt(x)) + 0.5) - cxf;
            const dy = (@as(f32, @floatFromInt(y)) + 0.5) - cyf;
            const cov = rf + 0.5 - @sqrt(dx * dx + dy * dy);
            if (cov <= 0) continue;
            blendPx(x, y, word, if (cov >= 1) 255 else @intFromFloat(cov * 255));
        }
    }
}

/// Which traffic-light dot (0 close, 1 min, 2 max) surface-local (lx, ly)
/// lands on, or null. A little slop makes the small targets forgiving.
fn hitDot(lx: usize, ly: usize) ?usize {
    for (dots_cx, 0..) |cx, i| {
        const dx = @abs(@as(i64, @intCast(lx)) - @as(i64, @intCast(cx)));
        const dy = @abs(@as(i64, @intCast(ly)) - @as(i64, @intCast(dots_cy)));
        if (dx <= dot_r + 3 and dy <= dot_r + 3) return i;
    }
    return null;
}

fn panel(x: usize, y: usize, w: usize, h: usize, r: usize, fill: u32, border: u32, bw: usize) void {
    fillRoundRect(x, y, w, h, r, border);
    if (w > 2 * bw and h > 2 * bw) {
        const ir = if (r > bw) r - bw else 0;
        fillRoundRect(x + bw, y + bw, w - 2 * bw, h - 2 * bw, ir, fill);
    }
}

/// Draw one glyph at (cx, cy), scaled 2x crisp: each source pixel becomes
/// a solid 2x2 block — no smoothing, so the letterforms stay sharp (a
/// clean pixel font, not blurred or rounded). The whole 16x32 cell is
/// painted, `on` pixels `fg` and the rest `bg` (no stale pixels behind).
fn drawGlyph(cx: usize, cy: usize, ch: u8, fg: u32, bg: u32) void {
    if (measuring) return;
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

/// Refresh the palette from fontsvc's effective appearance (theme +
/// accessibility), so a GUI follows the system/user settings and a live
/// change is picked up when the window next opens. A no-op without a font
/// service — the compiled-in dark default stands.
fn refreshAppearance() void {
    if (font_chan == 0) return;
    switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .appearance, 0)) {
        .ok => |rep| switch (rep) {
            .appearance => |ap| pal = resolveTheme(shared.apTheme(ap.flags), shared.apContrast(ap.flags), shared.apColors(ap.flags)),
            else => {},
        },
        .err => {},
    }
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
    if (measuring) return;
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
    if (measuring) return;
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
const Size = struct { w: usize, h: usize };

const gap = 16; // vertical/horizontal space between siblings
const bpx = 20; // button horizontal padding
const bpy = 11; // button vertical padding
const fpx = 14; // field horizontal padding
const fpy = 11; // field vertical padding
const r_btn = 10; // button corner radius
const r_field = 8; // field corner radius

// Focus recording during a layout pass (draw order over the tree).
var nfoc: usize = 0;
var sel_focus: usize = 0;

/// Draw the widget tree and return the number of focusable widgets. The
/// window is a titlebar over a content area laid out by `drawNode`
/// (columns stack, rows flow), everything coloured from `pal`.
fn renderTree(tree: Value, title: []const u8, focus: usize) usize {
    fillAll(pal.bg);
    sel_focus = focus;
    nfoc = 0;
    // Titlebar: a raised bar, three traffic-light dots at the left, the
    // title centred, a bottom rule. The bar (minus the dots) is a drag
    // handle; the dots are close / minimize / maximize.
    title_h = lineOf(R_TITLE) + 2 * 14;
    fillRect(0, 0, win_w, title_h, pal.surface);
    fillRect(0, title_h, win_w, pal.border_w, pal.border);
    dots_cy = title_h / 2;
    const first_cx = 16 + dot_r;
    for (0..3) |i| dots_cx[i] = first_cx + i * dot_gap;
    // Focused: the macOS red/amber/green. Unfocused: all three a uniform
    // grey, and the title muted — the window visibly does not hold the
    // keyboard, without a loud border.
    const c_close = if (win_focused) tl_close else pal.border;
    const c_min = if (win_focused) tl_min else pal.border;
    const c_max = if (win_focused) tl_max else pal.border;
    fillDot(dots_cx[0], dots_cy, dot_r, c_close);
    fillDot(dots_cx[1], dots_cy, dot_r, c_min);
    fillDot(dots_cx[2], dots_cy, dot_r, c_max);
    if (title.len > 0) {
        const tw = strW(R_TITLE, title);
        const after_dots = dots_cx[2] + dot_r + 12;
        const centered = if (win_w > tw) (win_w - tw) / 2 else 0;
        const tx = @max(centered, after_dots);
        const t_ink = if (win_focused) pal.title else pal.text_muted;
        drawStr(tx, (title_h - lineOf(R_TITLE)) / 2, R_TITLE, title, t_ink, pal.surface);
    }
    // Content area below the titlebar. Record the full height it wants so
    // the window can be sized to fit before its surface is created.
    const sz = drawNode(tree, pad, title_h + pad, win_w - 2 * pad);
    content_h = title_h + pad + sz.h + pad;
    return nfoc;
}

/// Lay the tree out without drawing, to find the window height its content
/// needs (clamped to the scanout), and centre the window at it.
fn sizeToContent(it: *mshl.Interp, view: Value, state: Value, title: []const u8) void {
    const tree = it.callValue(view, &.{state}, null, null) catch return;
    measuring = true;
    _ = renderTree(tree, title, 0);
    measuring = false;
    win_h = @max(win_h_min, @min(content_h, win_h_max));
    // Centre in the area below the top-bar strut, so a window never opens
    // under the menu bar.
    win_y = @max(top_strut + 8, top_strut + (scanout_h - top_strut - win_h) / 2);
}

/// Lay out and draw a node at (x, y) within `avail_w`, returning its size.
/// `column` stacks children, `row` flows them left-to-right; leaves are
/// label / button / field.
fn drawNode(node: Value, x: usize, y: usize, avail_w: usize) Size {
    if (node != .record) return .{ .w = 0, .h = 0 };
    const rec = node.record;
    const kind = strField(rec, "kind");
    const children: []const Value = kids: {
        const c = rec.get("children") orelse break :kids &.{};
        break :kids if (c == .list) c.list else &.{};
    };
    if (std.mem.eql(u8, kind, "row")) {
        var xx = x;
        var maxh: usize = 0;
        for (children) |child| {
            const sz = drawNode(child, xx, y, avail_w);
            xx += sz.w + gap;
            if (sz.h > maxh) maxh = sz.h;
        }
        return .{ .w = if (xx > x + gap) xx - x - gap else 0, .h = maxh };
    }
    if (std.mem.eql(u8, kind, "column") or children.len != 0) {
        var yy = y;
        for (children) |child| {
            const sz = drawNode(child, x, yy, avail_w);
            yy += sz.h + gap;
        }
        return .{ .w = avail_w, .h = if (yy > y + gap) yy - y - gap else 0 };
    }
    if (std.mem.eql(u8, kind, "label")) return drawLabel(rec, x, y);
    if (std.mem.eql(u8, kind, "button")) return drawButton(rec, x, y);
    if (std.mem.eql(u8, kind, "field")) return drawField(rec, x, y, avail_w);
    return .{ .w = 0, .h = 0 };
}

fn drawLabel(rec: mshl.Record, x: usize, y: usize) Size {
    const text = strField(rec, "text");
    const muted = rec.get("muted") != null and (rec.get("muted").?).asBool();
    const strong = std.mem.eql(u8, strField(rec, "role"), "title");
    const role: u64 = if (strong) R_TITLE else R_UI;
    const ink = if (strong) pal.title else if (muted) pal.text_muted else pal.text;
    drawStr(x, y, role, text, ink, pal.bg);
    return .{ .w = strW(role, text), .h = lineOf(role) };
}

/// A raised button: a filled box with a lighter top edge and a darker
/// bottom edge (a little depth, not flat), a border, and — when focused —
/// a bright ring plus a lift. `variant` gives it semantic colour: primary
/// (the accent), danger (destructive), or the neutral surface default.
fn drawButton(rec: mshl.Record, x: usize, y: usize) Size {
    const label = strField(rec, "label");
    const variant = strField(rec, "variant");
    const focused = nfoc == sel_focus;
    const w = strW(R_UI, label) + 2 * bpx;
    const h = lineOf(R_UI) + 2 * bpy;

    var fill: u32 = pal.surface_hi;
    var ink: u32 = pal.text;
    if (std.mem.eql(u8, variant, "primary")) {
        fill = pal.primary;
        ink = pal.primary_ink;
    } else if (std.mem.eql(u8, variant, "danger")) {
        fill = pal.danger;
        ink = pal.danger_ink;
    }
    // A rounded panel. Focus is a double cue (never colour alone): the
    // border becomes a bright, thicker ring AND the fill lifts a shade.
    const ring = if (focused) pal.focus else pal.border;
    const ring_w = if (focused) pal.focus_w else pal.border_w;
    if (focused) fill = shade(fill, 9, 8);
    panel(x, y, w, h, r_btn, fill, ring, ring_w);
    // A soft top highlight inside the rounded fill — a hint of depth, not
    // a hard bar (kept clear of the corners so it never pokes past them).
    fillRect(x + r_btn, y + ring_w, w - 2 * r_btn, 1, shade(fill, 6, 5));
    drawStr(x + bpx, y + bpy, R_UI, label, ink, fill);
    if (nfoc < focusables.len) {
        focusables[nfoc] = .{ .id = strField(rec, "id"), .is_field = false, .bx = x, .by = y, .bw = w, .bh = h };
        nfoc += 1;
    }
    return .{ .w = w, .h = h };
}

/// A text field: a muted label over an inset value box (a darker fill with
/// a bright caret when focused). A `secret` field shows dots.
fn drawField(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const label = strField(rec, "label");
    const id = strField(rec, "id");
    const fb = fieldFor(id, strField(rec, "value"));
    const focused = nfoc == sel_focus;
    var yy = y;
    if (label.len > 0) {
        drawStr(x, yy, R_UI, label, pal.text_muted, pal.bg);
        yy += lineOf(R_UI) + 6;
    }
    const bh = lineOf(R_UI) + 2 * fpy;
    const ring = if (focused) pal.focus else pal.border;
    const ring_w = if (focused) pal.focus_w else pal.border_w;
    panel(x, yy, avail_w, bh, r_field, pal.field_bg, ring, ring_w);
    const tx = x + fpx;
    const ty = yy + fpy;
    const secret = rec.get("secret") != null and (rec.get("secret").?).asBool();
    var dots: [64]u8 = undefined;
    const shown: []const u8 = if (secret) blk: {
        const mlen = @min(fb.len, dots.len);
        for (0..mlen) |i| dots[i] = '*';
        break :blk dots[0..mlen];
    } else fb.buf[0..fb.len];
    drawStr(tx, ty, R_UI, shown, pal.text, pal.field_bg);
    // The focus ring is already drawn by `panel`; add the caret.
    if (focused) fillRect(tx + strW(R_UI, shown) + 1, ty, 2, lineOf(R_UI), pal.focus);
    if (nfoc < focusables.len) {
        focusables[nfoc] = .{ .id = id, .is_field = true, .bx = x, .by = yy, .bw = avail_w, .bh = bh };
        nfoc += 1;
    }
    return .{ .w = avail_w, .h = (yy - y) + bh };
}

// ---------------------------------------------------- surface + input

/// Claim the trusted path: present the token and switch `chan` to the
/// badged channel the compositor mints, so surfaces made over it are the
/// login surface. False if there is no token or the compositor refuses.
// The badged channel earned from `register`, cached for the process's life.
var client_chan: u64 = 0;

/// Register with the compositor for a uniquely-badged channel; 0 if it does
/// not support it (then we stay badge 0, fine for a single window).
fn registerClient() u64 {
    return switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, display, .register, 0)) {
        .ok => |ok| switch (ok.rep) {
            .registered => if (ok.cap != 0) ok.cap else 0,
            else => 0,
        },
        .err => 0,
    };
}

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
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(win_x), @intCast(win_y)), .wh = shared.packPair(@intCast(win_w), @intCast(win_h)) } }, 0)) {
        .ok => |ok| ok,
        .err => return false,
    };
    surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return false,
    };
    if (cs.cap == 0) return false;
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) {
        _ = usys.capDrop(cs.cap);
        return false;
    }
    surf_cap = cs.cap;
    surf_va = m.data[0];
    px = @ptrFromInt(m.data[0]);
    return true;
}

fn commitSurface() bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .commit = .{ .surface = surf, .xy = 0, .wh = shared.packPair(@intCast(win_w), @intCast(win_h)) } }, 0)) {
        .ok => true,
        .err => false,
    };
}

fn closeSurface() void {
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .destroy_surface = .{ .surface = surf } }, 0);
    // Free the surface buffer's mapping and cap — a GUI that reopens (the
    // settings panel recurses on each apply) would otherwise leak a
    // ~win_w*win_h*4 mapping per open and soon exhaust its shm quota.
    if (surf_va != 0) {
        _ = usys.shmUnmap(surf_va);
        surf_va = 0;
    }
    if (surf_cap != 0) {
        _ = usys.capDrop(surf_cap);
        surf_cap = 0;
    }
}

/// An input event routed to our surface: a key (kind 0, `ch`) or a pointer
/// event (kind 1, surface-local `x`/`y` and button bitmask `btn`).
const Event = struct { kind: u64, surface: u64 = 0, ch: u8 = 0, x: usize = 0, y: usize = 0, btn: u64 = 0 };

/// The next input event routed to our surface, or null if the channel died.
// When > 0, the app asked for a live clock: read input with a tick so the
// loop wakes every `tick_ms` even with no input, and re-renders. Only for
// a local app (a remote view would need a round trip per tick).
var tick_ms: u64 = 0;

/// Ask the compositor to move this window's surface to (nx, ny).
fn moveSurface(nx: usize, ny: usize) void {
    if (surf == 0) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .move_surface = .{ .surface = surf, .xy = shared.packPair(@intCast(nx), @intCast(ny)) } }, 0);
}

/// Name this window's surface so the dock can restore it by title.
fn setSurfaceTitle(title: []const u8) void {
    if (surf == 0) return;
    const w = shared.strToWords(title);
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .set_title = .{ .surface = surf, .a = w[0], .b = w[1] } }, 0);
}

/// Minimize (hide) or restore (show) this window's surface. The amber
/// traffic-light hides it; the compositor drops focus to the window behind
/// and its buffer is kept, so a `restore_titled` from the dock brings it
/// straight back.
fn setSurfaceVisible(visible: bool) void {
    if (surf == 0) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .set_visible = .{ .surface = surf, .visible = @intFromBool(visible) } }, 0);
}

/// New window origin during a drag: `cur + (local - grab)`, clamped so the
/// window stays on the scanout. Signed math because a leftward/upward drag
/// makes the delta negative.
fn dragOrigin(cur: usize, local: usize, grab: usize, max_pos: usize) usize {
    const np = @as(i64, @intCast(cur)) + (@as(i64, @intCast(local)) - @as(i64, @intCast(grab)));
    if (np < 0) return 0;
    if (np > @as(i64, @intCast(max_pos))) return max_pos;
    return @intCast(np);
}

fn nextInput() ?Event {
    const rep = if (tick_ms > 0 and remote_node == 0)
        usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .next_input_tick = .{ .ms = tick_ms } }, 0)
    else
        usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .next_input, 0);
    return switch (rep) {
        .ok => |r| switch (r) {
            .input => |v| .{ .kind = v.kind, .surface = v.surface, .ch = @intCast(v.arg & 0xff), .x = shared.ptrX(v.arg), .y = shared.ptrY(v.arg), .btn = shared.ptrBtn(v.arg) },
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

// -------------------------------------------------------------- the top bar
//
// A resident menu bar pinned at the top of the scanout: menu titles at the
// left, right-aligned items (a live clock) at the right. A menu opens a
// DROPDOWN — a second, transient surface, because moss surfaces are opaque,
// so a menu overlaying windows must be its own surface; it is dismissed on a
// selection, a click elsewhere, or Escape. The bar's `view(state)` returns
// `{ left: [...], right: [...] }` of `{kind:menu,...}` / `{kind:label,...}`;
// a selected item fires `update(state, { menu, item })`. Windows open below
// the bar (a reserved strut), so it is never covered.
pub const top_strut = 34; // px reserved at the top for the bar

const bar_vpad = 8;
const menu_hpad = 12;
const item_vpad = 8;

const MenuHit = struct { id: []const u8, bx: usize, bw: usize, items: []const Value };
var bar_menus: [8]MenuHit = undefined;
var bar_nmenus: usize = 0;

// The dropdown popup — the bar process's second surface.
var pop_surf: u64 = 0;
var pop_px: [*]volatile u32 = undefined;
var pop_cap: u64 = 0;
var pop_va: u64 = 0;
var pop_x: usize = 0;
var pop_y: usize = 0;
var pop_w: usize = 0;
var pop_h: usize = 0;
var pop_open = false;
var pop_menu_id: []const u8 = "";
var pop_items: []const Value = &.{};
var pop_item_h: usize = 0;

fn barItemWidth(item: Value) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const kind = strField(rec, "kind");
    const text = if (std.mem.eql(u8, kind, "menu")) strField(rec, "title") else strField(rec, "text");
    return strW(R_UI, text) + 2 * menu_hpad;
}

/// Draw one bar item (a menu title or a label) at (x, cy_top); record a menu
/// title's hit box. Returns the advance width.
fn drawBarItem(item: Value, x: usize, cy: usize) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const kind = strField(rec, "kind");
    if (std.mem.eql(u8, kind, "menu")) {
        const title = strField(rec, "title");
        const w = strW(R_UI, title) + 2 * menu_hpad;
        const id = strField(rec, "id");
        if (pop_open and std.mem.eql(u8, pop_menu_id, id)) fillRect(x, 0, w, win_h - pal.border_w, pal.surface_hi);
        drawStr(x + menu_hpad, cy, R_UI, title, pal.title, pal.surface);
        if (bar_nmenus < bar_menus.len) {
            const items: []const Value = if (rec.get("items")) |iv| (if (iv == .list) iv.list else &.{}) else &.{};
            bar_menus[bar_nmenus] = .{ .id = id, .bx = x, .bw = w, .items = items };
            bar_nmenus += 1;
        }
        return w;
    }
    const text = strField(rec, "text");
    const muted = rec.get("muted") != null and (rec.get("muted").?).asBool();
    drawStr(x + menu_hpad, cy, R_UI, text, if (muted) pal.text_muted else pal.text, pal.surface);
    return strW(R_UI, text) + 2 * menu_hpad;
}

fn renderBar(tree: Value) void {
    bar_nmenus = 0;
    fillAll(pal.surface);
    fillRect(0, win_h - pal.border_w, win_w, pal.border_w, pal.border);
    const cy = if (win_h > lineOf(R_UI)) (win_h - lineOf(R_UI)) / 2 else 0;
    if (tree != .record) return;
    const rec = tree.record;
    var x: usize = menu_hpad / 2;
    if (rec.get("left")) |lv| if (lv == .list) for (lv.list) |item| {
        x += drawBarItem(item, x, cy);
    };
    if (rec.get("right")) |rv| if (rv == .list) {
        var tot: usize = 0;
        for (rv.list) |item| tot += barItemWidth(item);
        var rx = if (win_w > tot + menu_hpad) win_w - tot - menu_hpad else x;
        for (rv.list) |item| rx += drawBarItem(item, rx, cy);
    };
}

/// The menu title under a bar click (surface-local), or null.
fn menuAt(lx: usize) ?usize {
    for (bar_menus[0..bar_nmenus], 0..) |m, i| {
        if (lx >= m.bx and lx < m.bx + m.bw) return i;
    }
    return null;
}

/// The dropdown item under a popup click (surface-local), or null.
fn popItemAt(ly: usize) ?usize {
    if (pop_item_h == 0 or ly < 4) return null;
    const idx = (ly - 4) / pop_item_h;
    if (idx < pop_items.len) return idx;
    return null;
}

fn renderPopup() void {
    // Retarget the drawing primitives at the popup buffer for the duration.
    const save_px = px;
    const save_w = win_w;
    const save_h = win_h;
    px = pop_px;
    win_w = pop_w;
    win_h = pop_h;
    panel(0, 0, pop_w, pop_h, 8, pal.surface, pal.border, pal.border_w);
    const cyoff = (pop_item_h - lineOf(R_UI)) / 2;
    for (pop_items, 0..) |it, i| {
        if (it != .str) continue;
        drawStr(menu_hpad, 4 + i * pop_item_h + cyoff, R_UI, it.str, pal.text, pal.surface);
    }
    px = save_px;
    win_w = save_w;
    win_h = save_h;
}

fn openPopup(m: MenuHit) void {
    if (pop_open) closePopup();
    if (m.items.len == 0) return;
    pop_menu_id = m.id;
    pop_items = m.items;
    pop_item_h = lineOf(R_UI) + 2 * item_vpad;
    var maxw: usize = 80;
    for (pop_items) |it| if (it == .str) {
        const w = strW(R_UI, it.str);
        if (w > maxw) maxw = w;
    };
    pop_w = maxw + 2 * menu_hpad;
    pop_h = pop_items.len * pop_item_h + 8;
    pop_x = @min(win_x + m.bx, scanout_w - pop_w);
    pop_y = win_y + win_h;
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(pop_x), @intCast(pop_y)), .wh = shared.packPair(@intCast(pop_w), @intCast(pop_h)) } }, 0)) {
        .ok => |ok| ok,
        .err => return,
    };
    pop_surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return,
    };
    if (cs.cap == 0) return;
    const mp = usys.shmMap(cs.cap);
    if (mp.err != .ok) {
        _ = usys.capDrop(cs.cap);
        return;
    }
    pop_cap = cs.cap;
    pop_va = mp.data[0];
    pop_px = @ptrFromInt(mp.data[0]);
    pop_open = true;
    renderPopup();
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .commit = .{ .surface = pop_surf, .xy = 0, .wh = shared.packPair(@intCast(pop_w), @intCast(pop_h)) } }, 0);
    var lb: [96]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&lb, "topbar: popup at {d},{d} ih={d} n={d}", .{ pop_x, pop_y, pop_item_h, pop_items.len }) catch "topbar: popup");
}

fn closePopup() void {
    if (!pop_open) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .destroy_surface = .{ .surface = pop_surf } }, 0);
    if (pop_va != 0) _ = usys.shmUnmap(pop_va);
    if (pop_cap != 0) _ = usys.capDrop(pop_cap);
    pop_surf = 0;
    pop_cap = 0;
    pop_va = 0;
    pop_open = false;
    pop_menu_id = "";
}

fn mkMenuEvent(it: *mshl.Interp, menu: []const u8, item: []const u8) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "menu";
    keys[1] = "item";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = .{ .str = try it.arena.dupe(u8, menu) };
    vals[1] = .{ .str = try it.arena.dupe(u8, item) };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// The resident top-bar loop (`gui { bar: true, ... }`): render the bar,
/// tick the clock, open/close dropdowns, and fire the selected menu item.
fn runBar(it: *mshl.Interp, view: Value, update: Value, init_state: Value) mshl.Error!Value {
    if (!font_ok) fontReady();
    refreshAppearance();
    if (client_chan == 0) client_chan = registerClient();
    if (client_chan != 0) chan = client_chan;
    win_x = 0;
    win_y = 0;
    win_w = scanout_w;
    win_h = lineOf(R_UI) + 2 * bar_vpad + pal.border_w;
    dragging = false;
    ptr_down = false;
    pop_open = false;
    if (!openSurface()) return it.fail("gui: cannot open the bar surface", .{});
    defer closeSurface();
    defer closePopup();

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    while (true) {
        it.reclaim();
        renderBar(tree);
        if (!commitSurface()) return it.fail("gui: bar commit failed", .{});
        if (!announced) {
            _ = usys.log(log_h, "topbar: ready");
            // Log each menu title's hit-box centre so a drill can click it
            // precisely at any scale (the bar's size follows the font scale),
            // the way the dock logs its pills.
            for (bar_menus[0..bar_nmenus]) |m| {
                var mb: [64]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&mb, "topbar: menu {s} cx={d} cy={d}", .{ m.id, m.bx + m.bw / 2, win_h / 2 }) catch "topbar: menu");
            }
            announced = true;
        }
        var fired_menu: ?[]const u8 = null;
        var fired_item: ?[]const u8 = null;
        input: while (true) {
            const ev = nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2) {
                tree = try it.callValue(view, &.{state}, null, null); // refresh the clock
                break :input;
            }
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !ptr_down;
                ptr_down = down;
                if (press) {
                    if (pop_open and ev.surface == pop_surf) {
                        if (popItemAt(ev.y)) |idx| {
                            fired_menu = pop_menu_id;
                            fired_item = pop_items[idx].str;
                            closePopup();
                            break :input;
                        }
                    } else if (ev.surface == surf) {
                        if (menuAt(ev.x)) |mi| {
                            const was_this = pop_open and std.mem.eql(u8, pop_menu_id, bar_menus[mi].id);
                            closePopup();
                            if (!was_this) openPopup(bar_menus[mi]);
                            break :input; // re-render the highlight
                        } else if (pop_open) {
                            closePopup();
                            break :input;
                        }
                    }
                }
                continue :input;
            }
            if (ev.ch == 27 and pop_open) { // Escape
                closePopup();
                break :input;
            }
        }
        if (fired_item) |item| {
            const ev = try mkMenuEvent(it, fired_menu orelse "", item);
            state = try it.callValue(update, &.{ state, ev }, null, null);
            tree = try it.callValue(view, &.{state}, null, null);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "topbar: closed");
    return state;
}

// ----------------------------------------------------------- the dock

const dock_vpad = 8;
const dock_hpad = 16;
const dock_gap = 10;

const DockHit = struct { unit: []const u8, title: []const u8, running: bool = false, bx: usize, bw: usize };
var dock_items: [12]DockHit = undefined;
var dock_nitems: usize = 0;
var dock_running_known = false; // false until the first render logs a baseline

/// Draw the dock — a resident bottom bar of app buttons (rounded pills),
/// laid out centred across the width. An item is
/// `{ title, unit, running? }`; a running app gets the primary fill and a
/// dot below it. Each pill's hit box is recorded for the click router.
fn renderDock(tree: Value) void {
    dock_nitems = 0;
    fillAll(pal.surface);
    fillRect(0, 0, win_w, pal.border_w, pal.border); // the rule against the desktop
    if (tree != .record) return;
    const items: []const Value = if (tree.record.get("items")) |iv| (if (iv == .list) iv.list else &.{}) else &.{};
    var total: usize = 0;
    var n: usize = 0;
    for (items) |item| {
        if (item != .record) continue;
        total += strW(R_UI, strField(item.record, "title")) + 2 * dock_hpad;
        n += 1;
    }
    if (n > 1) total += (n - 1) * dock_gap;
    const pill_h = lineOf(R_UI) + 2 * item_vpad;
    const py = if (win_h > pill_h) (win_h - pill_h) / 2 else 0;
    var x: usize = if (win_w > total) (win_w - total) / 2 else dock_gap;
    for (items) |item| {
        if (item != .record) continue;
        const r = item.record;
        const title = strField(r, "title");
        const unit = strField(r, "unit");
        const running = r.get("running") != null and (r.get("running").?).asBool();
        const w = strW(R_UI, title) + 2 * dock_hpad;
        const fill = if (running) pal.primary else pal.surface_hi;
        const ink = if (running) pal.primary_ink else pal.text;
        fillRoundRect(x, py, w, pill_h, 10, fill);
        drawStr(x + dock_hpad, py + item_vpad, R_UI, title, ink, fill);
        if (running and win_h > 4) fillDot(x + w / 2, win_h - 4, 2, pal.primary);
        if (dock_nitems < dock_items.len) {
            // Log a pill's running state only when it flips (never the
            // first render's baseline), so a launch lights the dot and an
            // exit clears it observably (the view polls `unit-up` each tick)
            // without spamming every tick.
            if (dock_running_known and dock_items[dock_nitems].running != running) {
                var rb: [64]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&rb, "dock: running {s}={}", .{ unit, running }) catch "dock: running");
            }
            dock_items[dock_nitems] = .{ .unit = unit, .title = title, .running = running, .bx = x, .bw = w };
            dock_nitems += 1;
        }
        x += w + dock_gap;
    }
    dock_running_known = true;
}

/// The dock item under a click (surface-local x), or null.
fn dockItemAt(lx: usize) ?usize {
    for (dock_items[0..dock_nitems], 0..) |d, i| {
        if (lx >= d.bx and lx < d.bx + d.bw) return i;
    }
    return null;
}

/// The `{ item, unit, title }` event a dock click fires into `update`
/// (the app's update restores the window by `title` or launches `unit`).
fn mkDockEvent(it: *mshl.Interp, unit: []const u8, title: []const u8) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 3);
    keys[0] = "item";
    keys[1] = "unit";
    keys[2] = "title";
    const vals = try it.arena.alloc(Value, 3);
    vals[0] = .{ .str = try it.arena.dupe(u8, unit) };
    vals[1] = .{ .str = try it.arena.dupe(u8, unit) };
    vals[2] = .{ .str = try it.arena.dupe(u8, title) };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// The resident dock loop (`gui { dock: true, ... }`): a bottom bar of app
/// buttons, pinned full-width, chrome-less — not a window. view(state)
/// returns `{ items: [ { title, unit, running? } ] }`; clicking a pill
/// fires update(state, { item, unit, title }), whose update restores the
/// app if it is already up (`restore-window $ev.title`) or launches it
/// otherwise (`launch $ev.unit` reaches init through this process's init
/// front channel). `done: true` ends it.
fn runDock(it: *mshl.Interp, view: Value, update: Value, init_state: Value) mshl.Error!Value {
    if (!font_ok) fontReady();
    refreshAppearance();
    if (client_chan == 0) client_chan = registerClient();
    if (client_chan != 0) chan = client_chan;
    const pill_h = lineOf(R_UI) + 2 * item_vpad;
    win_w = scanout_w;
    win_h = pill_h + 2 * dock_vpad + pal.border_w;
    win_x = 0;
    win_y = if (scanout_h > win_h) scanout_h - win_h else 0;
    dragging = false;
    ptr_down = false;
    if (!openSurface()) return it.fail("gui: cannot open the dock surface", .{});
    defer closeSurface();

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    while (true) {
        it.reclaim();
        renderDock(tree);
        if (!commitSurface()) return it.fail("gui: dock commit failed", .{});
        if (!announced) {
            var lb: [64]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&lb, "dock: ready n={d}", .{dock_nitems}) catch "dock: ready n=0");
            // The click router needs each pill's centre; log them so a drill
            // can aim precisely (like the top bar's popup geometry).
            for (dock_items[0..dock_nitems], 0..) |d, i| {
                var ib: [64]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&ib, "dock: item {d} cx={d} cy={d}", .{ i, d.bx + d.bw / 2, win_y + win_h / 2 }) catch "dock: item");
            }
            announced = true;
        }
        var fired: ?usize = null;
        var quit = false;
        input: while (true) {
            const ev = nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2) {
                tree = try it.callValue(view, &.{state}, null, null); // tick refresh
                break :input;
            }
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !ptr_down;
                ptr_down = down;
                if (press and ev.surface == surf) {
                    if (dockItemAt(ev.x)) |idx| {
                        fired = idx;
                        break :input;
                    }
                }
                continue :input;
            }
            if (ev.ch == 27) { // Escape ends the dock (and the session)
                quit = true;
                break :input;
            }
        }
        if (quit) break;
        if (fired) |idx| {
            const unit = dock_items[idx].unit;
            var lb: [64]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&lb, "dock: activate {s}", .{unit}) catch "dock: activate");
            const ev = try mkDockEvent(it, unit, dock_items[idx].title);
            state = try it.callValue(update, &.{ state, ev }, null, null);
            tree = try it.callValue(view, &.{state}, null, null);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "dock: closed");
    return state;
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

/// Reconstruct the whole app — `update` and `view` — as one worker script
/// that reads `$in = { state, ev, apply }` and returns `{ state, tree }`:
/// apply the event (when `apply`), then render the new state. Only data
/// crosses, so this runs anywhere — the fabric-transparent GUI. Returns
/// null unless update is 2-arg and view is 1-arg (then the caller stays
/// in-process). Arena-held.
fn buildAppSrc(it: *mshl.Interp, update: *const mshl.Closure, view: *const mshl.Closure) mshl.Error!?[]const u8 {
    if (update.params.len != 2 or view.params.len != 1) return null;
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(it.arena, "let ");
    try s.appendSlice(it.arena, update.params[0]);
    try s.appendSlice(it.arena, " = $in.state\n");
    try s.appendSlice(it.arena, "let ");
    try s.appendSlice(it.arena, update.params[1]);
    try s.appendSlice(it.arena, " = $in.ev\n");
    try s.appendSlice(it.arena, "let __ns = match $in.apply {\n  true => ");
    try s.appendSlice(it.arena, update.src);
    try s.appendSlice(it.arena, "\n  _ => $in.state\n}\n");
    try s.appendSlice(it.arena, "let ");
    try s.appendSlice(it.arena, view.params[0]);
    try s.appendSlice(it.arena, " = $__ns\n");
    try s.appendSlice(it.arena, "{ state: $__ns, tree: ");
    try s.appendSlice(it.arena, view.src);
    try s.appendSlice(it.arena, " }\n");
    return s.items;
}

/// The `{ state, ev, apply }` record the remote app worker reads as `$in`.
fn wrapStep(it: *mshl.Interp, state: Value, ev: Value, apply: bool) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 3);
    keys[0] = "state";
    keys[1] = "ev";
    keys[2] = "apply";
    const vals = try it.arena.alloc(Value, 3);
    vals[0] = state;
    vals[1] = ev;
    vals[2] = .{ .bool = apply };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// One step of the remote app: ship `{ state, ev, apply }` to node
/// `remote_node`, which runs update+view and returns `{ state, tree }`.
/// Updates `state.*` and returns the view tree, or null on a fabric/app
/// failure (the caller keeps the last good tree). Only data crosses.
fn stepRemote(it: *mshl.Interp, state: *Value, ev: Value, apply: bool) mshl.Error!?Value {
    if (remote_stage == null) return null;
    const in = try wrapStep(it, state.*, ev, apply);
    const res = (try remote_stage.?.call(it, app_src, in)) orelse {
        _ = usys.log(log_h, "gui: the remote app failed");
        return null;
    };
    if (res != .record) return null;
    const rec = res.record;
    const ns = rec.get("state") orelse return null;
    const tree = rec.get("tree") orelse return null;
    state.* = ns;
    return tree;
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
    if (std.mem.eql(u8, name, "appearance")) {
        var theme: shared.Theme = .dark;
        var contrast: shared.Contrast = .normal;
        var colors: shared.ColorMode = .default;
        var locked: u64 = 0;
        if (font_chan != 0) switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .appearance, 0)) {
            .ok => |rep| switch (rep) {
                .appearance => |ap| {
                    theme = shared.apTheme(ap.flags);
                    contrast = shared.apContrast(ap.flags);
                    colors = shared.apColors(ap.flags);
                    locked = shared.apLocked(ap.flags);
                },
                else => {},
            },
            .err => {},
        };
        // { theme, contrast, colors, and a *_locked bool per axis the system
        // layer locks — so a settings UI renders that control non-editable }.
        const keys = try it.arena.alloc([]const u8, 6);
        keys[0] = "theme";
        keys[1] = "contrast";
        keys[2] = "colors";
        keys[3] = "theme_locked";
        keys[4] = "contrast_locked";
        keys[5] = "colors_locked";
        const vals = try it.arena.alloc(Value, 6);
        vals[0] = .{ .str = @tagName(theme) };
        vals[1] = .{ .str = @tagName(contrast) };
        vals[2] = .{ .str = if (colors == .cb_safe) "cb-safe" else "default" };
        vals[3] = .{ .bool = locked & 1 != 0 };
        vals[4] = .{ .bool = locked & 2 != 0 };
        vals[5] = .{ .bool = locked & 4 != 0 };
        return Value{ .record = .{ .keys = keys, .vals = vals } };
    }
    if (std.mem.eql(u8, name, "restore-window")) {
        if (display == 0) return it.fail("restore-window: no display", .{});
        if (args.len == 0 or args[0] != .str) return it.fail("restore-window: a window title expected", .{});
        const w = shared.strToWords(args[0].str);
        const ok = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, display, .{ .restore_titled = .{ .a = w[0], .b = w[1] } }, 0)) {
            .ok => |r| r == .ok,
            .err => false,
        };
        return if (ok)
            try it.mkResult(true, .{ .str = try it.arena.dupe(u8, args[0].str) })
        else
            try it.mkResult(false, .{ .str = "not running" });
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
    // `tick: <ms>` (or `tick: true` → 1s) asks the loop to re-render on a
    // timer so a `view` that reads the clock updates on its own.
    tick_ms = if (spec.get("tick")) |t| switch (t) {
        .int => if (t.int > 0) @intCast(t.int) else 0,
        .bool => if (t.bool) 1000 else 0,
        else => 0,
    } else 0;
    // `bar: true` is the resident top menu bar — a distinct render/loop
    // (pinned, chrome-less, with dropdown menus), not a window.
    if (spec.get("bar") != null and (spec.get("bar").?).asBool()) {
        return try runBar(it, view, update, state);
    }
    // `dock: true` is the resident bottom dock — a bar of app buttons that
    // launch their units on a click, pinned full-width, not a window.
    if (spec.get("dock") != null and (spec.get("dock").?).asBool()) {
        return try runDock(it, view, update, state);
    }

    // `node: N` runs the whole app on node N over the fabric — the runtime
    // becomes a pure viewer, shipping each event and rendering the view
    // tree that comes back. Needs a fabric cap and a 2-arg update / 1-arg
    // view (so we can reconstruct the worker); otherwise it runs locally.
    remote_node = 0;
    remote_stage = null;
    if (fab_chan != 0) {
        if (spec.get("node")) |n| if (n == .int and n.int > 0) {
            if (try buildAppSrc(it, update.func, view.func)) |src| {
                app_src = src;
                // Spawn the stage once; every event reuses it. If the node
                // is unreachable, fall back to running the app in-process
                // (its closures are here) — a graceful degradation.
                remote_stage = fabcmds.Stage.open(fab_chan, @intCast(n.int));
                if (remote_stage != null) {
                    remote_node = @intCast(n.int);
                    _ = usys.log(log_h, "gui: running the app on the fabric");
                } else {
                    _ = usys.log(log_h, "gui: the app's node is unreachable; running in-process");
                }
            }
        };
    }
    defer if (remote_stage) |*s| s.close();

    // Crash-isolate `update` in a worker domain when asked and able (and
    // not already remote): an app fault then kills only the worker, not
    // the display runtime. The worker lives for the whole session;
    // `callUpdate` re-spawns it if it dies. Best-effort — no spawner, or a
    // 2-arg `update` we cannot reconstruct, and we run it in-process.
    iso_conn = null;
    if (remote_node == 0 and want_isolate and workcmds.canSpawn()) {
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
    } else {
        // An ordinary window: register once for a unique badge so the
        // compositor tells this process's surfaces and input apart from
        // other windows'. Cached across `gui` calls (a reopening shell
        // keeps its badge). Falls back to badge 0 if the compositor is old.
        if (client_chan == 0) client_chan = registerClient();
        if (client_chan != 0) chan = client_chan;
    }

    resetFields();
    // A fresh window: no drag in flight (module state persists across
    // `gui` calls in one process), and it opens focused (the compositor
    // sets a new surface as focused; a later `kind` 4 corrects us if not).
    dragging = false;
    ptr_down = false;
    pending_dot = null;
    win_focused = true;
    // Width: `width: N` narrows the window (a desktop lays out several
    // smaller windows); default is the roomy single-window width.
    win_w = win_w_default;
    if (spec.get("width")) |wv| {
        if (wv == .int and wv.int >= 200) win_w = @min(@as(usize, @intCast(wv.int)), scanout_w);
    }
    win_x = (scanout_w - win_w) / 2;
    if (!font_ok) fontReady(); // attach the system font once (bitmap fallback if absent)
    refreshAppearance(); // resolve the palette from the system/user settings
    sizeToContent(it, view, state, title); // fit the window to its content
    // `at: { x, y }` places the window instead of centring it (a desktop
    // that lays several windows out uses this).
    if (spec.get("at")) |a| {
        if (a == .record) {
            if (a.record.get("x")) |xv| {
                if (xv == .int and xv.int >= 0) win_x = @min(@as(usize, @intCast(xv.int)), scanout_w - win_w);
            }
            if (a.record.get("y")) |yv| {
                if (yv == .int and yv.int >= 0) win_y = @min(@as(usize, @intCast(yv.int)), scanout_h - win_h);
            }
        }
    }

    if (!openSurface()) return it.fail("gui: cannot open a surface", .{});
    defer closeSurface();
    // Name the surface so the dock can restore this window by its title
    // after the amber traffic-light minimizes it.
    if (title.len > 0) setSurfaceTitle(title);

    var focus: usize = 0;
    var minimized = false; // the amber dot hid us; a restore event brings us back
    var announced = false;
    // The current view tree: the initial view of the initial state, then
    // recomputed after each fired event — locally (update then view) or,
    // for a `node: N` app, on that node in one round trip.
    var tree: Value = if (remote_node != 0)
        (try stepRemote(it, &state, Value.nothing, false)) orelse
            return it.fail("gui: the remote app did not answer", .{})
    else
        try it.callValue(view, &.{state}, null, null);
    while (true) {
        // Reclaim the previous render's dead boxes: a long-running GUI (or
        // one that reopens per apply, like the settings shell) would
        // otherwise pile up per-render trees until the interpreter runs
        // out of memory.
        it.reclaim();
        const nfocus = renderTree(tree, title, focus);
        if (nfocus > 0 and focus >= nfocus) focus = nfocus - 1;
        if (!commitSurface()) return it.fail("gui: commit failed", .{});
        if (!announced) {
            _ = usys.log(log_h, "gui: ready");
            // The traffic-light dot centres in scanout coordinates, so a
            // host can click close/minimize/maximize precisely.
            var dl: [96]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&dl, "gui: dots close={d},{d} min={d},{d} max={d},{d}", .{ win_x + dots_cx[0], win_y + dots_cy, win_x + dots_cx[1], win_y + dots_cy, win_x + dots_cx[2], win_y + dots_cy }) catch "gui: dots");
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
        var ticked = false;
        var closed = false;
        input: while (true) {
            const ev = nextInput() orelse return it.fail("gui: the display channel closed", .{});
            // A focus change: the compositor tells us we gained or lost the
            // keyboard (arg 1/0). Re-render so the chrome dims or brightens.
            if (ev.kind == 4) {
                const now = ev.ch != 0;
                if (now == win_focused) continue :input;
                win_focused = now;
                _ = usys.log(log_h, if (now) "gui: focused" else "gui: unfocused");
                if (minimized) continue :input; // nothing on screen to redraw
                break :input;
            }
            // A restore: the dock brought this minimized window back. Clear
            // the minimized state and re-render so its content repaints.
            if (ev.kind == 3) {
                minimized = false;
                _ = usys.log(log_h, "gui: restored");
                break :input;
            }
            // A timer tick: re-render so a `view` reading the time updates
            // — but never mid-drag (a ticking clock must not drop a drag),
            // and never while minimized (nothing is on screen to update).
            if (ev.kind == 2) {
                if (dragging or minimized) continue :input;
                ticked = true;
                break :input;
            }
            // Pointer. Edge-detect press vs release; the titlebar is a drag
            // handle with three traffic-light dots, the content area has the
            // widgets.
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !ptr_down;
                const release = !down and ptr_down;
                ptr_down = down;
                if (press) {
                    if (ev.y < title_h) {
                        if (hitDot(ev.x, ev.y)) |d| {
                            pending_dot = d; // fire on release if still on it
                        } else {
                            dragging = true; // grab the titlebar to move
                            drag_grab_x = ev.x;
                            drag_grab_y = ev.y;
                        }
                    } else if (hitWidget(nfocus, ev.x, ev.y)) |wi| {
                        focus = wi;
                        if (!focusables[wi].is_field) {
                            fired = focusables[wi].id;
                            break :input;
                        }
                    }
                    continue :input;
                }
                if (down and dragging) {
                    const nx = dragOrigin(win_x, ev.x, drag_grab_x, scanout_w - win_w);
                    const ny = dragOrigin(win_y, ev.y, drag_grab_y, scanout_h - win_h);
                    if (nx != win_x or ny != win_y) {
                        moveSurface(nx, ny);
                        win_x = nx;
                        win_y = ny;
                    }
                    continue :input;
                }
                if (release) {
                    if (dragging) {
                        dragging = false;
                        var lb: [96]u8 = undefined;
                        _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: {s} moved to {d},{d}", .{ title, win_x, win_y }) catch "gui: moved");
                    } else if (pending_dot) |d| {
                        pending_dot = null;
                        if (ev.y < title_h and hitDot(ev.x, ev.y) == d) {
                            switch (d) {
                                0 => closed = true, // red: close the window
                                1 => { // amber: minimize — hide, keep running
                                    setSurfaceVisible(false);
                                    minimized = true;
                                    pending_dot = null;
                                    _ = usys.log(log_h, "gui: minimized");
                                    continue :input; // stay parked until a restore
                                },
                                else => _ = usys.log(log_h, "gui: maximize (not yet)"),
                            }
                        }
                        if (closed) break :input;
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
        // The close box was clicked: end the app (its `gui` call returns
        // the last state, like a `done`).
        if (closed) break;
        if (ticked and remote_node == 0) {
            // Recompute the view from the unchanged state — no `update` on
            // a tick — so a clock or other time-driven view refreshes.
            tree = try it.callValue(view, &.{state}, null, null);
        }
        if (fired) |id| {
            const ev = try mkEvent(it, id);
            if (remote_node != 0) {
                // The app runs on the fabric: ship the event, render the
                // tree that comes back. A dropped round trip keeps the last
                // good tree and state (let-it-crash across the wire).
                if (try stepRemote(it, &state, ev, true)) |t| {
                    tree = t;
                    if (isDone(state)) break;
                }
            } else {
                state = try callUpdate(it, update, state, ev);
                tree = try it.callValue(view, &.{state}, null, null);
                if (isDone(state)) break;
            }
        }
    }
    _ = usys.log(log_h, "gui: closed");
    return state;
}
