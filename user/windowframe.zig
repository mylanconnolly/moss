//! The window frame: the chrome and the surface every graphical window
//! shares — a macOS-style titlebar (three traffic-light dots, a centred
//! title, the rest a drag handle), dragging, edge-snapping, minimize /
//! maximize, focus dimming — plus the drawing primitives and the system
//! font that paint it. It owns the compositor surface (create / commit /
//! move / resize / destroy), so a client only draws CONTENT into the area
//! below the titlebar (`contentRect`) and routes pointer events through
//! `onPointer`, which returns what the frame did (a drag, a snap, a close).
//!
//! Clients include the mshl widget runtime, terminal glyph grid, native text
//! editor, and capability document picker.
//! Because a process drives one window at a time (a transient popup swaps
//! the buffer in place), the frame is module state, not a struct — matching
//! how `guicmds` was written before the split.

const std = @import("std");
const shared = @import("shared");
const ui = @import("mosslib").ui;
const usys = @import("usys.zig");
const font = shared.font8x16;

// The channels a window drives. `display` is the compositor (surface
// protocol + input); `chan` is the channel a session actually drives — the
// display, or the badged/trusted channel earned from register/attach.
pub var display: u64 = 0;
pub var chan: u64 = 0;
pub var log_h: u64 = 0;
var trust_token: u64 = 0; // the trusted-path token, if the host was given one

// The system font service, when the host holds one: text is laid out and
// rasterized there (a shared coverage atlas), so text renders in the real
// family at the accessibility scale. Without it the built-in bitmap font
// (drawn 2x crisp) is the fallback — see `strW`/`drawStr`.
var font_chan: u64 = 0;
var font_buf: [*]u8 = undefined; // our request/response buffer (shm)
var font_buf_len: usize = 0;
var atlas: [*]const u8 = undefined; // fontsvc's coverage atlas (mapped ro)
var atlas_w: usize = 0;
var font_ok = false; // fontsvc is attached and usable
pub const n_roles = 3;
var role_line: [n_roles]usize = @splat(0);
var role_asc: [n_roles]usize = @splat(0);
var role_px: [n_roles]u64 = @splat(0);

/// Wire the frame to its caps once: the compositor, the log, the
/// trusted-path token (from a `secret` give, if any), and the font service.
/// Registers with fontsvc for a badged request buffer so several text
/// clients on one service do not trample a single shared slot.
pub fn setup(display_cap: u64, log: u64, secret: []const u8, font_cap: u64) void {
    title_click = null;
    display = display_cap;
    log_h = log;
    font_chan = font_cap;
    if (secret.len >= 8) trust_token = std.mem.readInt(u64, secret[0..8], .little);
    if (font_chan != 0) {
        // A refused registration must never attach to another client's
        // legacy badge-0 buffer.
        font_chan = registerFont();
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

// ------------------------------------------------------------ geometry

const fsw = font.width; //  8, source
const fsh = font.height; // 16, source
pub const gw = fsw * 2; // 16, the bitmap cell width
pub const gh = fsh * 2; // 32, the bitmap cell height

pub const win_w_default = 680;
pub var scanout_w: usize = 1280;
pub var scanout_h: usize = 1024;
pub const win_h_min = 220;
pub var win_h_max: usize = 976; // leave a margin top+bottom
pub const pad = ui.space.inset; // window inset for content

pub var win_w: usize = win_w_default;
pub var win_x: usize = (1280 - win_w_default) / 2;
pub var win_h: usize = 460;
pub var win_y: usize = (1024 - 460) / 2;

// A macOS-style titlebar: three traffic-light dots (close / minimize /
// maximize) at the left, the title centred, and the rest a drag handle.
var dot_r: usize = 9; // scales with the UI font snapshot
const tl_close: u32 = 0x00ff_5f57; // red
const tl_min: u32 = 0x00fe_bc2e; // amber
const tl_max: u32 = 0x0028_c840; // green
pub var title_h: usize = 0; // set each render; the drag-handle band height
pub var dots_cx: [3]usize = @splat(0);
pub var dots_cy: usize = 0;
// Whether this window holds focus (the compositor tells us with a `kind` 4
// event). An unfocused window dims its chrome — grey traffic lights, a
// muted title — the desktop's focus cue. A fresh window opens focused.
pub var win_focused = true;
// A trusted (login greeter) window: its traffic lights are drawn but
// disabled — a login must not be closed, minimized or maximized, because
// nothing could bring it back (there is no dock or task switcher at the
// login). The dots stay for visual consistency but read as inert (grey).
pub var win_trusted = false;
// Maximize (the green traffic-light) is a toggle: it fills the work area
// (below the top bar, above the dock) and remembers the window's previous
// geometry to restore on a second press. Surfaces are fixed-size, so the
// resize is a destroy + recreate of the surface at the new geometry.
pub var maximized = false;
var saved_x: usize = 0;
var saved_y: usize = 0;
var saved_w: usize = 0;
var saved_h: usize = 0;
// A drag in progress, and where in the window it was grabbed.
pub var dragging = false;
var drag_grab_x: usize = 0;
var drag_grab_y: usize = 0;
var drag_start_x: usize = 0;
var drag_start_y: usize = 0;
var drag_moved = false;
var title_click: ?struct { at: u64, x: usize, y: usize, surface: u64 } = null;
fn distance(a: usize, b: usize) usize {
    return @max(a, b) - @min(a, b);
}
pub var ptr_down = false; // previous pointer button state (edge detection)
pub var pending_dot: ?usize = null; // a traffic-light pressed, awaiting release

// Measuring pass: lay a client's content out to find its height without
// drawing (the surface is sized from it before it is created). `measuring`
// suppresses the pixel-writing primitives; sizes still compute from the
// font metrics.
pub var measuring = false;

// ----------------------------------------------------------- the palette
//
// A GUI's look is a set of SEMANTIC tokens, not scattered literals, so the
// same widget code renders every theme. The tokens are resolved from three
// composable appearance axes (theme dark/light, contrast normal/high,
// colours default/colourblind-safe) served by fontsvc from the settings
// layer — so a user's choice (and the high-contrast / colourblind-safe
// accessibility switches) reaches every GUI system-wide. Colours are
// 0x00RRGGBB (XRGB, read straight by a screendump).

pub const Palette = ui.Palette;
pub const shade = ui.palette.shade;
/// The wire's appearance enums (fontsvc's flags) to the toolkit's, by value.
pub fn resolveTheme(theme: shared.Theme, contrast: shared.Contrast, cmode: shared.ColorMode) Palette {
    return ui.palette.resolve(@enumFromInt(@intFromEnum(theme)), @enumFromInt(@intFromEnum(contrast)), @enumFromInt(@intFromEnum(cmode)));
}

// The live palette, refreshed from fontsvc before each render.
pub var pal: Palette = resolveTheme(.dark, .normal, .default);

pub var px: [*]volatile u32 = undefined; // the mapped surface, win_w*win_h
pub var surf: u64 = 0;
var surf_cap: u64 = 0; // the surface buffer's shm cap (freed on close)
var surf_va: u64 = 0; // its mapped address (unmapped on close)

// A clip rectangle the drawing primitives honour, so a scrollable list can
// paint rows into a viewport and have anything past its edges cut rather
// than spilling over the window. Reset to the whole window each render.
// Layout coordinates remain nonnegative; scrolling translates only at the
// raster boundary, before clipping. This handles partially visible glyphs.
pub var draw_offset_y: isize = 0;
pub fn screenY(y: usize) isize {
    return @as(isize, @intCast(y)) + draw_offset_y;
}
pub fn clipY(y: usize) usize {
    return @intCast(@max(0, screenY(y)));
}
pub var clip_x0: usize = 0;
pub var clip_y0: usize = 0;
pub var clip_x1: usize = 1280;
pub var clip_y1: usize = 1024;
pub fn clipReset() void {
    draw_offset_y = 0;
    clip_x0 = 0;
    clip_y0 = 0;
    clip_x1 = win_w;
    clip_y1 = win_h;
}
fn inClip(x: usize, y: usize) bool {
    return x >= clip_x0 and x < clip_x1 and y >= clip_y0 and y < clip_y1;
}

/// The toolkit canvas over the current surface and clip state. The
/// frame's pixel pointer, size, clip and scroll offset stay its own
/// variables (popups retarget them), so the canvas is built per use.
pub fn cv() ui.Canvas {
    if (measuring) return ui.Canvas.empty;
    return .{ .px = @volatileCast(px), .w = win_w, .h = win_h, .offset_y = draw_offset_y, .clip_x0 = clip_x0, .clip_y0 = clip_y0, .clip_x1 = clip_x1, .clip_y1 = clip_y1 };
}
var brush_canvas: ui.Canvas = .{};
var icon_cache: ui.icons.Cache = .{};
/// Everything a toolkit painter needs from this frame: the canvas, the
/// font service as a typeface, the live palette and the icon cache.
/// Valid until the next `brush()` (the canvas snapshot is shared).
pub fn brush() ui.Brush {
    brush_canvas = cv();
    return .{ .canvas = &brush_canvas, .face = face(), .pal = &pal, .icons = &icon_cache, .icon_px = iconSize() };
}

pub fn fillAll(word: u32) void {
    cv().fillAll(word);
}
pub fn putPx(x: usize, logical_y: usize, word: u32) void {
    cv().put(x, logical_y, word);
}
pub fn fillRect(x: usize, y: usize, w: usize, h: usize, word: u32) void {
    cv().fillRect(x, y, w, h, word);
}
/// A `thick`-pixel outline around the rect (x, y, w, h).
pub fn strokeRect(x: usize, y: usize, w: usize, h: usize, word: u32, thick: usize) void {
    cv().strokeRect(x, y, w, h, word, thick);
}
/// A filled rectangle with rounded, anti-aliased corners.
pub fn fillRoundRect(x: usize, y: usize, w: usize, h: usize, r_in: usize, word: u32) void {
    cv().fillRoundRect(x, y, w, h, r_in, word);
}
/// A filled, anti-aliased disc — a traffic-light dot.
pub fn fillDot(cx: usize, cy: usize, r: usize, word: u32) void {
    cv().fillDot(cx, cy, r, word);
}
/// A rounded panel with a rounded border of thickness `bw`.
pub fn panel(x: usize, y: usize, w: usize, h: usize, r: usize, fill: u32, border: u32, bw: usize) void {
    cv().panel(x, y, w, h, r, fill, border, bw);
}
/// Blend `fg` over the pixel at (x, y) by coverage `cov` (0..255).
pub fn blendPx(x: usize, logical_y: usize, fg: u32, cov: u32) void {
    cv().blend(x, logical_y, fg, cov);
}

/// Draw one glyph at (cx, cy), scaled 2x crisp: each source pixel becomes
/// a solid 2x2 block — no smoothing, so the letterforms stay sharp. The
/// whole 16x32 cell is painted, `on` pixels `fg` and the rest `bg`.
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
fn drawTextBitmap(x: usize, y: usize, s: []const u8, fg: u32, bg: u32) void {
    for (s, 0..) |ch, i| {
        const cx = x + i * gw;
        if (cx + gw > win_w or y + gh > win_h) break;
        drawGlyph(cx, y, ch, fg, bg);
    }
}

// ------------------------------------------------ system font (fontsvc)

pub const R_UI: u64 = @intFromEnum(shared.FontRole.ui);
pub const R_TITLE: u64 = @intFromEnum(shared.FontRole.title);

/// Attach our request/response buffer to fontsvc, once. Both rendering
/// (glyph runs) and the per-user layer push (`applyUserLayer`) stage
/// through it, so either path may bring it up first.
fn ensureFontBuf() bool {
    if (font_chan == 0) return false;
    if (font_buf_len != 0) return true;
    const sh = usys.shmCreate(2); // room for the glyph run of a line
    if (sh.err != .ok) return false;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) {
        _ = usys.capDrop(sh.data[0]);
        return false;
    }
    const attached = switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .attach_buf, sh.data[0])) {
        .ok => |ok| ok.rep == .ok,
        .err => false,
    };
    _ = usys.capDrop(sh.data[0]);
    if (!attached) {
        _ = usys.shmUnmap(m.data[0]);
        return false;
    }
    font_buf = @ptrFromInt(m.data[0]);
    font_buf_len = m.data[1] * 4096;
    return true;
}

/// Push the logged-in user's font layer to the shared font service for the
/// life of this session — the per-user accessibility scale, merged over
/// the system layer centrally so every text client follows it. An empty
/// layer reverts to the system default (logout). Metrics are read lazily
/// by `fontReady` (on the first render), so a push before a window opens
/// is reflected.
pub fn applyUserLayer(text: []const u8) void {
    if (!ensureFontBuf()) return;
    const n = @min(text.len, font_buf_len);
    if (n > 0) @memcpy(font_buf[0..n], text[0..n]);
    _ = usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .reconfigure = .{ .len = n } }, 0);
}

pub fn fontReady() void {
    if (font_chan == 0) return;
    if (!ensureFontBuf()) return;
    if (atlas_w == 0) {
        const at = switch (usys.callTypedCap(shared.FontReq, shared.FontResp, font_chan, .atlas, 0)) {
            .ok => |ok| ok,
            .err => return,
        };
        if (at.cap == 0 or at.rep != .atlas) return;
        const am = usys.shmMap(at.cap);
        _ = usys.capDrop(at.cap);
        if (am.err != .ok) return;
        atlas = @ptrFromInt(am.data[0]);
        atlas_w = shared.unpackHi(at.rep.atlas.wh);
    }
    _ = refreshFontMetrics();
}

/// Snapshot metrics together; layout uses these same pixel sizes until
/// the owner has an opportunity to lay out its controls again.
pub fn refreshFontMetrics() bool {
    if (font_chan == 0 or atlas_w == 0) return false;
    var lines = role_line;
    var ascents = role_asc;
    var sizes = role_px;
    for (0..n_roles) |role| {
        switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .metrics = .{ .role = role } }, 0)) {
            .ok => |rep| switch (rep) {
                .metrics => |mm| {
                    lines[role] = @intCast(mm.line);
                    ascents[role] = @intCast(mm.ascent);
                    sizes[role] = mm.px;
                },
                else => return false,
            },
            .err => return false,
        }
    }
    const changed = !font_ok or !std.mem.eql(usize, &lines, &role_line) or !std.mem.eql(usize, &ascents, &role_asc) or !std.mem.eql(u64, &sizes, &role_px);
    role_line = lines;
    role_asc = ascents;
    role_px = sizes;
    font_ok = true;
    return changed;
}

pub fn fontOk() bool {
    return font_ok;
}

/// Refresh the palette from fontsvc's effective appearance (theme +
/// accessibility), so a window follows the system/user settings and a live
/// change is picked up when it next opens. A no-op without a font service —
/// the compiled-in dark default stands.
pub fn refreshAppearance() void {
    if (font_chan == 0) return;
    switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .appearance, 0)) {
        .ok => |rep| switch (rep) {
            .appearance => |ap| pal = resolveTheme(shared.apTheme(ap.flags), shared.apContrast(ap.flags), shared.apColors(ap.flags)),
            else => {},
        },
        .err => {},
    }
}

/// Report the effective appearance flags fontsvc is applying (theme,
/// contrast, colours, and which axes the system layer locks), for a
/// settings app to display. 0 without a font service.
pub fn appearanceFlags() u64 {
    if (font_chan == 0) return 0;
    return switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .appearance, 0)) {
        .ok => |rep| switch (rep) {
            .appearance => |ap| ap.flags,
            else => 0,
        },
        .err => 0,
    };
}

/// Lay out `s` in `role` through fontsvc: the glyph run lands in `font_buf`
/// and the pen width is returned (0 on failure). Leaves the run in the
/// buffer for a following `blitRun` — no `layout` may intervene.
fn fontLayout(role: u64, s: []const u8) struct { w: usize, count: usize } {
    const len = @min(s.len, font_buf_len);
    @memcpy(font_buf[0..len], s[0..len]);
    return switch (usys.callTyped(shared.FontReq, shared.FontResp, font_chan, .{ .layout = .{ .role = role, .px = role_px[role], .len = len } }, 0)) {
        .ok => |rep| switch (rep) {
            .laid => |l| .{ .w = shared.unpackHi(l.pen), .count = @intCast(l.count) },
            else => .{ .w = 0, .count = 0 },
        },
        .err => .{ .w = 0, .count = 0 },
    };
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
pub fn strW(role: u64, s: []const u8) usize {
    if (font_ok) return fontLayout(role, s).w;
    return s.len * gw;
}

/// The line height of `role` (row-to-row advance).
pub fn lineOf(role: u64) usize {
    return if (font_ok) role_line[role] else gh;
}

/// Draw `s` at content position (x, y_top) in `role`. Over the font path
/// text blends over the already-painted background (`bg` ignored); the
/// bitmap fallback paints `bg` behind each cell.
pub fn drawStr(x: usize, y_top: usize, role: u64, s: []const u8, fg: u32, bg: u32) void {
    if (font_ok) {
        const l = fontLayout(role, s);
        blitRun(x, y_top + role_asc[role], l.count, fg);
    } else {
        drawTextBitmap(x, y_top, s, fg, bg);
    }
}

/// Draw `s` in `role`, truncated with an ellipsis to fit `maxw` pixels.
pub fn drawStrTrunc(x: usize, y: usize, role: u64, s: []const u8, maxw: usize, fg: u32, bg: u32) void {
    const c = cv();
    face().drawTrunc(&c, x, y, roleOf(role), s, maxw, fg, bg);
}

// The frame as a toolkit typeface: measurement and glyph runs from
// fontsvc (or the bitmap fallback), painted into whatever canvas the
// painter holds — for widgets, the one `brush()` built over the surface.
fn roleOf(role: u64) ui.typeface.Role {
    return @enumFromInt(@as(u8, @intCast(role)));
}
fn faceMeasure(_: *anyopaque, role: ui.typeface.Role, s: []const u8) usize {
    return strW(@intFromEnum(role), s);
}
fn faceMetrics(_: *anyopaque, role: ui.typeface.Role) ui.typeface.Metrics {
    const r: u64 = @intFromEnum(role);
    return .{ .line = lineOf(r), .ascent = if (font_ok) role_asc[r] else gh * 3 / 4 };
}
fn faceDraw(_: *anyopaque, canvas: *const ui.Canvas, x: usize, y_top: usize, role: ui.typeface.Role, s: []const u8, fg: u32, bg: u32) void {
    // Paint into the painter's canvas: swap it in as the frame's target
    // state for the duration, since glyph blits go through blendPx.
    const saved = .{ px, win_w, win_h, draw_offset_y, clip_x0, clip_y0, clip_x1, clip_y1, measuring };
    px = @ptrCast(canvas.px);
    win_w = canvas.w;
    win_h = canvas.h;
    draw_offset_y = canvas.offset_y;
    clip_x0 = canvas.clip_x0;
    clip_y0 = canvas.clip_y0;
    clip_x1 = canvas.clip_x1;
    clip_y1 = canvas.clip_y1;
    measuring = canvas.w == 0;
    defer {
        px = saved[0];
        win_w = saved[1];
        win_h = saved[2];
        draw_offset_y = saved[3];
        clip_x0 = saved[4];
        clip_y0 = saved[5];
        clip_x1 = saved[6];
        clip_y1 = saved[7];
        measuring = saved[8];
    }
    drawStr(x, y_top, @intFromEnum(role), s, fg, bg);
}
const face_vtable: ui.Typeface.VTable = .{ .measure = faceMeasure, .metrics = faceMetrics, .draw = faceDraw };
var face_ctx: u8 = 0;
pub fn face() ui.Typeface {
    return .{ .ctx = @ptrCast(&face_ctx), .vtable = &face_vtable };
}

// ------------------------------------------------------------ the chrome

/// The content area below the titlebar: what a client may draw into.
pub const Rect = ui.Rect;
pub fn contentRect() Rect {
    return .{ .x = 0, .y = title_h, .w = win_w, .h = if (win_h > title_h) win_h - title_h else 0 };
}

var chrome_surface: u64 = 0;

/// Draw the titlebar: a raised bar, three traffic-light dots at the left,
/// the title centred, a bottom rule. The bar (minus the dots) is a drag
/// handle; the dots are close / minimize / maximize. Sets `title_h`,
/// `dots_cx`/`dots_cy` for the input router and the geometry log.
pub fn drawChrome(title: []const u8) void {
    if (!measuring) chrome_surface = surf;
    title_h = lineOf(R_TITLE) + 2 * 14;
    fillRect(0, 0, win_w, title_h, pal.surface);
    fillRect(0, title_h, win_w, pal.border_w, pal.border);
    dots_cy = title_h / 2;
    dot_r = std.math.clamp(lineOf(R_UI), 20, 28) / 2 - 1;
    const dot_gap = 2 * (dot_r + 5) + 2;
    const first_cx = 16 + dot_r;
    for (0..3) |i| dots_cx[i] = first_cx + i * dot_gap;
    // Focused: the macOS red/amber/green. Unfocused: all three a uniform
    // grey, and the title muted — the window visibly does not hold the
    // keyboard, without a loud border. A trusted login window's controls
    // are disabled (it cannot be closed/minimized/maximized), so its dots
    // are always grey — visibly inert, like macOS's dimmed controls.
    const lit = win_focused and !win_trusted;
    const c_close = if (lit) tl_close else pal.border;
    const c_min = if (lit) tl_min else pal.border;
    const c_max = if (lit) tl_max else pal.border;
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
}

/// Which traffic-light dot (0 close, 1 min, 2 max) surface-local (lx, ly)
/// lands on, or null. A little slop makes the small targets forgiving.
fn hitDot(lx: usize, ly: usize) ?usize {
    for (dots_cx, 0..) |cx, i| {
        const dx = @abs(@as(i64, @intCast(lx)) - @as(i64, @intCast(cx)));
        const dy = @abs(@as(i64, @intCast(ly)) - @as(i64, @intCast(dots_cy)));
        if (dx <= dot_r + 5 and dy <= dot_r + 5) return i;
    }
    return null;
}

// ---------------------------------------------------- surface + input

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

/// Register for a badged channel and drive it — an ordinary window, so the
/// compositor tells this process's surfaces and input apart from other
/// windows'. Cached across opens. Falls back to badge 0 if unsupported.
pub fn useOrdinaryChannel() void {
    _ = refreshOutput();
    chan = display;
    if (client_chan == 0) client_chan = registerClient();
    if (client_chan != 0) chan = client_chan;
}

/// Claim the trusted path: present the token and switch `chan` to the badged
/// channel the compositor mints, so surfaces made over it are the login
/// surface. False if there is no token or the compositor refuses.
pub fn attachTrusted() bool {
    _ = refreshOutput();
    chan = display;
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

/// Open the window's surface at (win_x, win_y, win_w, win_h). `cascade` asks
/// the compositor to nudge the window off any it would land on — for the
/// FIRST open of a fresh window only; a resize re-open (snap, maximize)
/// wants exact placement, or the compositor could shift a snapped window
/// off its edge.
pub var pointer_tracking = false;
/// Desktop bars opt out; maximized/snapped windows meet their work-area edges.
pub var rounded = true;
/// A dialog window: created with gpu_dialog, so the compositor keeps it
/// above ordinary windows (the chooser sets this).
pub var dialog = false;
pub fn openSurface(cascade: bool) bool {
    return openSurfaceFocused(cascade, true);
}

pub fn openSurfaceFocused(cascade: bool, activate: bool) bool {
    menu_surface = 0;
    surface_visible = true;
    const flags: u64 = (if (rounded and !maximized) shared.gpu_rounded else @as(u64, 0)) | (if (cascade) shared.gpu_place_cascade else @as(u64, 0)) | (if (pointer_tracking) shared.gpu_pointer_tracking else @as(u64, 0)) | (if (activate) @as(u64, 0) else shared.gpu_no_activate) | (if (dialog) shared.gpu_dialog else @as(u64, 0));
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(win_x), @intCast(win_y)), .wh = shared.packPair(@intCast(win_w), @intCast(win_h)), .flags = flags } }, 0)) {
        .ok => |ok| ok,
        .err => return false,
    };
    surf = switch (cs.rep) {
        .created => |c| blk: {
            // The compositor may have nudged the window off another it would
            // have covered (cascade); adopt where it actually landed so
            // hit-testing, the logged dot/widget coordinates and later drags
            // all speak the same position.
            win_x = shared.unpackHi(c.xy);
            win_y = shared.unpackLo(c.xy);
            break :blk c.surface;
        },
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
    // A new surface is a whole-window clip. Clients that never call
    // clipReset (the terminal blits its grid straight into px) painted
    // their chrome through the boot-time 1280x1024 clip after a resize:
    // a maximized terminal at 1920x1200 had a title bar 1280 wide.
    clipReset();
    return true;
}

/// Draw after content so edge-aligned tabs, scrolling and partial terminal
/// paints cannot erase the outline. Surface identity excludes resident bars
/// and temporary titleless overlays that share this renderer.
fn drawWindowBorder() void {
    if (measuring or surf == 0 or chrome_surface != surf) return;
    const bw = @min(pal.border_w, @min(win_w / 2, win_h / 2));
    const ink = if (win_focused) pal.window_border else pal.border;
    // Surface-local coordinates deliberately bypass content clip/scroll state.
    const shape = ui.shape;
    const radius = if (rounded and !maximized) shape.radius(win_w, win_h) else 0;
    for (0..bw) |i| {
        @memset(px[i * win_w + radius .. (i + 1) * win_w - radius], ink);
        @memset(px[(win_h - 1 - i) * win_w + radius .. (win_h - i) * win_w - radius], ink);
    }
    for (radius..win_h - radius) |y| {
        @memset(px[y * win_w .. y * win_w + bw], ink);
        @memset(px[(y + 1) * win_w - bw .. (y + 1) * win_w], ink);
    }
    // The compositor anti-aliases the outer silhouette against the actual
    // windows behind us. Paint a matching inner arc, never fake a desktop
    // color into corner pixels. Repeated partial commits are idempotent.
    for (0..radius) |y| {
        for (0..radius) |x| {
            const inner = if (x >= bw and y >= bw)
                shape.coverage(x - bw, y - bw, win_w - 2 * bw, win_h - 2 * bw, radius -| bw)
            else
                0;
            if (inner >= 128) continue;
            px[y * win_w + x] = ink;
            px[y * win_w + win_w - 1 - x] = ink;
            px[(win_h - 1 - y) * win_w + x] = ink;
            px[(win_h - 1 - y) * win_w + win_w - 1 - x] = ink;
        }
    }
}

pub fn commitSurface() bool {
    drawWindowBorder();
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .commit = .{ .surface = surf, .xy = 0, .wh = shared.packPair(@intCast(win_w), @intCast(win_h)) } }, 0)) {
        .ok => true,
        .err => false,
    };
}

pub fn closeSurface() void {
    menu_surface = 0;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .destroy_surface = .{ .surface = surf } }, 0);
    // Free the surface buffer's mapping and cap — a window that reopens (the
    // settings panel recurses on each apply, a resize destroys + recreates)
    // would otherwise leak a ~win_w*win_h*4 mapping per open.
    if (surf_va != 0) {
        _ = usys.shmUnmap(surf_va);
        surf_va = 0;
    }
    if (surf_cap != 0) {
        _ = usys.capDrop(surf_cap);
        surf_cap = 0;
    }
}

/// Ask the compositor to move this window's surface to (nx, ny).
pub fn moveSurface(nx: usize, ny: usize) void {
    if (surf == 0) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .move_surface = .{ .surface = surf, .xy = shared.packPair(@intCast(nx), @intCast(ny)) } }, 0);
}

/// Name this window's surface so the dock can restore it by title.
pub fn setSurfaceTitle(title: []const u8) void {
    if (surf == 0) return;
    const w = shared.strToWords(title);
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .set_title = .{ .surface = surf, .a = w[0], .b = w[1] } }, 0);
}

pub const ActiveMenu = struct {
    token: u64 = 0,
    profile: shared.menus.Profile = .generic,
    enabled: u64 = 0,
};
var menu_surface: u64 = 0;
var menu_profile: shared.menus.Profile = .generic;
var menu_enabled: u64 = 0;
/// Publish current action availability. Re-created surfaces are republished.
fn menuCall(channel: u64, req: shared.GpuReq) ?shared.GpuResp {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, channel, req, 0)) {
        .ok => |rep| rep,
        .err => null,
    };
}
pub fn setMenuProfile(profile: shared.menus.Profile, enabled: u64) void {
    if (surf == 0) return;
    const mask = enabled & shared.menus.offered(profile);
    if (menu_surface == surf and menu_profile == profile and menu_enabled == mask) return;
    const rep = menuCall(chan, .{ .set_menu = .{ .surface = surf, .profile = @intFromEnum(profile), .enabled = mask } }) orelse return;
    if (rep == .ok) {
        menu_surface = surf;
        menu_profile = profile;
        menu_enabled = mask;
    }
}
pub fn activeMenu() ActiveMenu {
    const rep = menuCall(chan, .menu_info) orelse return .{};
    return switch (rep) {
        .menu => |m| .{ .token = m.token, .profile = shared.menus.profileFromInt(m.profile) orelse .generic, .enabled = m.enabled },
        else => .{},
    };
}
pub fn menuTitle(token: u64) [16]u8 {
    var result: [16]u8 = @splat(0);
    const rep = menuCall(chan, .{ .menu_title = .{ .token = token } }) orelse return result;
    switch (rep) {
        .menu_title => |t| {
            var buf: [24]u8 = undefined;
            const title = shared.wordsToStr(&buf, .{ t.a, t.b, 0 });
            const n = @min(title.len, result.len);
            @memcpy(result[0..n], title[0..n]);
        },
        else => {},
    }
    return result;
}
pub fn invokeMenu(control: u64, token: u64, key: u8) bool {
    if (control == 0) return false;
    const rep = menuCall(control, .{ .menu_invoke = .{ .token = token, .key = key } }) orelse return false;
    return rep == .ok;
}
pub fn restoreMenuFocus(control: u64, token: u64) bool {
    if (control == 0) return false;
    const rep = menuCall(control, .{ .menu_restore = .{ .token = token } }) orelse return false;
    return rep == .ok;
}

/// Minimize (hide) or restore (show) this window's surface. The amber
/// traffic-light hides it; the compositor drops focus to the window behind
/// and its buffer is kept, so a `restore_titled` from the dock brings it
/// straight back.
pub var surface_visible = true;
pub fn setSurfaceVisible(visible: bool) void {
    surface_visible = visible;
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

/// An input event routed to our surface: a key (kind 0, `ch`), a pointer
/// event (kind 1, surface-local `x`/`y` and button bitmask `btn`), a tick
/// (kind 2), a restore (kind 3), or a focus change (kind 4).
pub const Event = struct { kind: u64, surface: u64 = 0, ch: u8 = 0, x: usize = 0, y: usize = 0, btn: u64 = 0, screen_x: ?usize = null, screen_y: ?usize = null };

// When > 0, the client asked for a live clock: read input with a tick so
// the loop wakes every `tick_ms` even with no input, and re-renders.
pub var tick_ms: u64 = 0;

/// The next input event routed to our surface, or null if the channel died.
pub fn nextInput() ?Event {
    const rep = if (tick_ms > 0)
        usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .next_input_tick = .{ .ms = tick_ms } }, 0)
    else
        usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .next_input, 0);
    return switch (rep) {
        .ok => |r| switch (r) {
            .input => |v| .{
                .kind = if (v.kind == 6) 1 else v.kind,
                .surface = v.surface,
                .ch = @intCast(v.arg & 0xff),
                .x = if (v.kind == 7) shared.unpackHi(v.arg) else if (v.kind == 6) shared.ptrX(v.arg) -| win_x else shared.ptrX(v.arg),
                .y = if (v.kind == 7) shared.unpackLo(v.arg) else if (v.kind == 6) shared.ptrY(v.arg) -| win_y else shared.ptrY(v.arg),
                .screen_x = if (v.kind == 6) shared.ptrX(v.arg) else null,
                .screen_y = if (v.kind == 6) shared.ptrY(v.arg) else null,
                .btn = shared.ptrBtn(v.arg),
            },
            else => .{ .kind = 0, .ch = 0 },
        },
        .err => null,
    };
}

// ------------------------------------------------------------ snapping

/// The dock's height at the current scale — the same expression `runDock`
/// uses (same font service, same palette, so it matches the real dock), so
/// a maximized window can stop just above it.
/// The desktop work area a maximized window fills: between the struts the
/// top bar and the dock declared to the compositor (`work_area`), one
/// published fact rather than a guess rebuilt here from this process's
/// font snapshot — which drifted from the real bars after a scale change
/// and at large text. Without a compositor answer (no display): the
/// whole scanout.
pub const Geom = struct { x: usize, y: usize, w: usize, h: usize };
pub fn workArea() Geom {
    if (display != 0) {
        switch (usys.callTyped(shared.GpuReq, shared.GpuResp, display, .work_area, 0)) {
            .ok => |r| switch (r) {
                .work => |w| return .{ .x = shared.unpackHi(w.xy), .y = shared.unpackLo(w.xy), .w = shared.unpackHi(w.wh), .h = shared.unpackLo(w.wh) },
                else => {},
            },
            .err => {},
        }
    }
    return .{ .x = 0, .y = 0, .w = scanout_w, .h = scanout_h };
}

// Window snapping: dragging the cursor to a screen edge, then releasing,
// resizes the window to fill that half (left/right) or the whole work area
// (top) — the Aero-Snap / macOS-tile gesture.
pub const SnapZone = enum { none, left, right, max };
const snap_edge = 24;
fn snapZoneAt(cx: usize, cy: usize) SnapZone {
    if (cx < snap_edge) return .left;
    if (cx + snap_edge >= scanout_w) return .right;
    if (cy < workArea().y + snap_edge) return .max; // up to the top bar
    return .none;
}
fn snapRegion(zone: SnapZone) Geom {
    const wa = workArea();
    const half = wa.w / 2;
    return switch (zone) {
        .left => .{ .x = wa.x, .y = wa.y, .w = half, .h = wa.h },
        .right => .{ .x = wa.x + half, .y = wa.y, .w = wa.w - half, .h = wa.h },
        .max, .none => wa,
    };
}

// ---------------------------------------------------- pointer routing

/// What `onPointer` did with an event — the client re-renders or ends
/// accordingly and logs the matching `gui:` line (so the chrome logging
/// stays in one place, the client, exactly as before the split).
pub const Ptr = union(enum) {
    none, // nothing user-visible happened
    content: Event, // a press in the content area — client hit-tests widgets
    close, // the red dot: end the window
    minimized, // the amber dot: surface hidden, client stays parked
    moved, // a drag ended in place — client logs "gui: <title> moved to"
    resized: SnapZone, // snap/maximize done — client re-renders; .none = unmaximized (restored)
    resize_failed, // a resize's surface recreate failed — client ends (fatal)
};

/// Route a pointer event (kind 1). Owns the titlebar: dot press/release
/// (close / minimize / maximize), and the drag → move → edge-snap gesture,
/// doing the surface move / destroy+recreate itself. A press in the content
/// area returns `.content` (with the event) so the client hit-tests its own
/// widgets/grid; a snap or maximize returns `.resized` after the surface is
/// recreated, so the client re-renders into the new buffer. `title` is used
/// only to re-name the recreated surface.
pub fn onPointer(ev: Event, title: []const u8) Ptr {
    const down = ev.btn & 1 != 0;
    const press = down and !ptr_down;
    const release = !down and ptr_down;
    ptr_down = down;
    if (press) {
        if (ev.y < title_h) {
            if (hitDot(ev.x, ev.y)) |d| {
                title_click = null;
                // A login greeter's controls are inert: swallow the press so
                // it neither fires the dot nor drags.
                if (!win_trusted) pending_dot = d; // fire on release if still on it
            } else {
                dragging = true; // grab the titlebar to move
                drag_grab_x = ev.x;
                drag_grab_y = ev.y;
                drag_start_x = ev.screen_x orelse (win_x + ev.x);
                drag_start_y = ev.screen_y orelse (win_y + ev.y);
                drag_moved = false;
            }
            return .none;
        }
        title_click = null;
        return .{ .content = ev };
    }
    if (down and dragging) {
        const cx = ev.screen_x orelse (win_x + ev.x);
        const cy = ev.screen_y orelse (win_y + ev.y);
        if (distance(cx, drag_start_x) > 4 or distance(cy, drag_start_y) > 4) {
            drag_moved = true;
            title_click = null;
        }
        const nx = if (ev.screen_x) |sx| @min(sx -| drag_grab_x, scanout_w -| win_w) else dragOrigin(win_x, ev.x, drag_grab_x, scanout_w -| win_w);
        const ny = if (ev.screen_y) |sy| @min(sy -| drag_grab_y, scanout_h -| win_h) else dragOrigin(win_y, ev.y, drag_grab_y, scanout_h -| win_h);
        if (nx != win_x or ny != win_y) {
            moveSurface(nx, ny);
            win_x = nx;
            win_y = ny;
        }
        return .none;
    }
    if (release) {
        if (dragging) {
            dragging = false;
            // Snap if the cursor was flung to a screen edge. The cursor's
            // scanout position is the window origin plus the release point
            // within it (valid through a drag: the window brackets the
            // cursor even when clamped).
            const cx = @min(ev.screen_x orelse (win_x + ev.x), scanout_w);
            const cy = @min(ev.screen_y orelse (win_y + ev.y), scanout_h);
            if (!drag_moved and distance(cx, drag_start_x) <= 4 and distance(cy, drag_start_y) <= 4 and ev.y < title_h and hitDot(ev.x, ev.y) == null and !win_trusted) {
                const now = usys.cycles();
                if (title_click) |last| {
                    if (last.surface == surf and now -| last.at <= usys.cycleHz() * 400 / 1000 and distance(cx, last.x) <= 4 and distance(cy, last.y) <= 4) {
                        title_click = null;
                        return toggleMaximize(title);
                    }
                }
                title_click = .{ .at = now, .x = cx, .y = cy, .surface = surf };
                return .none;
            }
            title_click = null;
            const zone = snapZoneAt(cx, cy);
            if (zone != .none and !win_trusted) {
                // Remember the floating geometry to restore (the green dot
                // un-snaps), but only when coming from floating — re-snapping
                // keeps the original.
                if (!maximized) {
                    saved_x = win_x;
                    saved_y = win_y;
                    saved_w = win_w;
                    saved_h = win_h;
                }
                const g = snapRegion(zone);
                win_x = g.x;
                win_y = g.y;
                win_w = g.w;
                win_h = g.h;
                maximized = true; // a saved-geometry zoom state
                if (!recreate(title)) return .resize_failed;
                return .{ .resized = zone };
            }
            return .moved;
        } else if (pending_dot) |d| {
            pending_dot = null;
            if (ev.y < title_h and hitDot(ev.x, ev.y) == d) {
                switch (d) {
                    0 => return .close, // red: close the window
                    1 => { // amber: minimize — hide, keep running
                        setSurfaceVisible(false);
                        return .minimized;
                    },
                    else => return toggleMaximize(title),
                }
            }
            return .none;
        }
    }
    return .none;
}

/// Shared by the green control and a title-bar double click.
fn toggleMaximize(title: []const u8) Ptr {
    if (maximized) {
        win_x = saved_x;
        win_y = saved_y;
        win_w = saved_w;
        win_h = saved_h;
        maximized = false;
    } else {
        saved_x = win_x;
        saved_y = win_y;
        saved_w = win_w;
        saved_h = win_h;
        const wa = workArea();
        win_x = wa.x;
        win_y = wa.y;
        win_w = wa.w;
        win_h = wa.h;
        maximized = true;
    }
    if (!recreate(title)) return .resize_failed;
    return .{ .resized = if (maximized) .max else .none };
}

/// A resize is a destroy + recreate of the fixed-size surface at the new
/// geometry (exact placement — no cascade), re-taking focus and the front,
/// with the title re-set so the dock can still find it. False if the new
/// surface could not be opened; the old surface remains valid. The caller
/// restores its previous geometry before painting it again.
fn recreate(title: []const u8) bool {
    return recreateFocused(title, true);
}
fn recreateFocused(title: []const u8, activate: bool) bool {
    // Allocate the replacement before releasing the old backing store. A
    // failed resize must leave the client's document and drawable surface alive.
    const old_surf = surf;
    const old_cap = surf_cap;
    const old_va = surf_va;
    const old_px = px;
    surf = 0;
    surf_cap = 0;
    surf_va = 0;
    if (!openSurfaceFocused(false, activate)) {
        if (surf != 0) closeSurface();
        surf = old_surf;
        surf_cap = old_cap;
        surf_va = old_va;
        px = old_px;
        return false;
    }
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .destroy_surface = .{ .surface = old_surf } }, 0);
    if (old_va != 0) _ = usys.shmUnmap(old_va);
    if (old_cap != 0) _ = usys.capDrop(old_cap);
    if (title.len > 0) setSurfaceTitle(title);
    return true;
}

/// Symbolic icons follow the same font snapshot as labels and controls.
pub fn iconSize() usize {
    return scaledIconSize(20);
}
pub fn scaledIconSize(base: usize) usize {
    return ui.icons.scaledSize(base, if (font_ok) @intCast(role_px[R_UI]) else 16);
}
pub fn drawIcon(x: usize, y: usize, size: usize, name: []const u8, ink: u32) void {
    if (measuring) return;
    const icon = ui.icons.parse(name) orelse return;
    const c = cv();
    icon_cache.draw(&c, icon, size, x, y, ink);
}

pub fn refreshOutput() bool {
    const info = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, display, .output_info, 0)) {
        .ok => |r| switch (r) {
            .output => |v| v,
            else => return false,
        },
        .err => return false,
    };
    const w = shared.unpackHi(info.wh);
    const h = shared.unpackLo(info.wh);
    if (!shared.display.valid(w, h)) return false;
    const changed = w != scanout_w or h != scanout_h;
    scanout_w = w;
    scanout_h = h;
    win_h_max = h - 48;
    return changed;
}
/// Recreate a window after an output change, retaining title, focus and
/// visibility. Existing content remains the application's responsibility.
pub fn outputChanged(ev: Event, title: []const u8, hidden: bool) bool {
    _ = refreshOutput();
    title_click = null;
    dragging = false;
    ptr_down = false;
    pending_dot = null;
    const area = workArea();
    saved_w = @min(saved_w, area.w);
    saved_h = @min(saved_h, area.h);
    saved_x = @min(saved_x, scanout_w -| saved_w);
    saved_y = @min(saved_y, scanout_h -| saved_h);
    win_w = @min(win_w, area.w);
    win_h = @min(win_h, area.h);
    win_x = @min(ev.x, scanout_w -| win_w);
    win_y = std.math.clamp(ev.y, area.y, area.y + area.h - win_h);
    if (maximized) {
        win_x = area.x;
        win_y = area.y;
        win_w = area.w;
        win_h = area.h;
    }
    if (!recreateFocused(title, win_focused and !hidden)) return false;
    setSurfaceTitle(title);
    if (hidden) setSurfaceVisible(false);
    return true;
}
