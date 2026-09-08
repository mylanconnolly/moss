//! fontsvc — the system font service. It loads the font families from the
//! assets tier, owns the effective font settings (family-per-role and the
//! accessibility scale), and rasterizes glyphs on demand into a shared
//! coverage atlas. A client attaches a request/response buffer and maps
//! the atlas once, then `layout`s each string: fontsvc shapes it, ensures
//! every glyph is rasterized into the atlas (cached across calls), and
//! writes the glyph run back into the buffer. Rendering stays client-side
//! — the client blits coverage from the atlas into its own surface with
//! its own colour — so fontsvc never draws and never sees anyone's pixels.
//! It is the single place fonts are parsed, rasterized, cached, and scaled,
//! which is what makes type consistent and the accessibility scale global.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const mosslib = @import("mosslib");
const font = mosslib.font;

comptime {
    asm (usys.imageHeader("fontsvc"));
}

pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;

// The parsed families. A Font borrows its .ttf bytes from the boot
// archive (mapped read-only, lives for the program), so no copy is kept.
var sans: ?font.Font = null;
var mono: ?font.Font = null;

// The effective font settings. A role maps to a family and a base size in
// logical pixels; every size is multiplied by `scale` (the accessibility
// knob) to reach device pixels. Stage 1 defaults; conf/font.msh overrides
// come next.
var scale: f32 = 1.0;
const RoleCfg = struct { mono: bool, base: f32 };
fn roleCfg(role: u64) RoleCfg {
    return switch (role) {
        @intFromEnum(shared.FontRole.ui) => .{ .mono = false, .base = 16 },
        @intFromEnum(shared.FontRole.title) => .{ .mono = false, .base = 22 },
        @intFromEnum(shared.FontRole.mono) => .{ .mono = true, .base = 15 },
        else => .{ .mono = false, .base = 16 },
    };
}
fn roleFont(role: u64) ?*font.Font {
    const c = roleCfg(role);
    if (c.mono) return if (mono) |*m| m else null;
    return if (sans) |*s| s else null;
}
fn rolePx(role: u64, req_px: u64) f32 {
    const base: f32 = if (req_px != 0) @floatFromInt(req_px) else roleCfg(role).base;
    return base * scale;
}

// The shared glyph atlas: an 8-bit coverage bitmap, packed by shelves.
const atlas_w = 512;
const atlas_h = 512;
const atlas_pages = (atlas_w * atlas_h + 4095) / 4096;
var atlas: [*]u8 = undefined;
var atlas_shm: u64 = 0;
var at_x: usize = 0;
var at_y: usize = 0;
var shelf_h: usize = 0;

fn packRect(w: usize, h: usize) ?struct { x: usize, y: usize } {
    if (w == 0 or h == 0) return .{ .x = 0, .y = 0 };
    if (at_x + w > atlas_w) {
        at_x = 0;
        at_y += shelf_h;
        shelf_h = 0;
    }
    if (at_y + h > atlas_h) return null; // full (the GUI never fills 512×512)
    const x = at_x;
    const y = at_y;
    at_x += w + 1;
    if (h > shelf_h) shelf_h = h;
    return .{ .x = x, .y = y };
}

// The glyph cache: (role-family, px, codepoint) → its atlas rect + metrics.
const Cached = struct {
    used: bool = false,
    is_mono: bool = false,
    px: u16 = 0,
    cp: u21 = 0,
    ax: u16 = 0,
    ay: u16 = 0,
    w: u16 = 0,
    h: u16 = 0,
    left: i16 = 0,
    top: i16 = 0,
    adv: i32 = 0,
};
var cache: [1024]Cached = @splat(.{});

// Rasterization scratch: a fixed arena reset per glyph (a glyph's coverage
// is copied into the atlas immediately, so nothing needs to persist).
var raster_heap: [1 << 20]u8 = undefined;

fn ensureGlyph(role: u64, px_dev: u16, cp: u21) ?*Cached {
    const is_mono = roleCfg(role).mono;
    for (&cache) |*c| {
        if (c.used and c.is_mono == is_mono and c.px == px_dev and c.cp == cp) return c;
    }
    const f = roleFont(role) orelse return null;
    var fba = std.heap.FixedBufferAllocator.init(&raster_heap);
    const gid = f.glyphIndex(cp);
    const g = font.rasterize(f, fba.allocator(), gid, @floatFromInt(px_dev)) catch return null;
    const pos = packRect(g.w, g.h) orelse return null;
    // Copy the coverage into the atlas.
    var r: usize = 0;
    while (r < g.h) : (r += 1) {
        const dst = (pos.y + r) * atlas_w + pos.x;
        @memcpy(atlas[dst .. dst + g.w], g.cov[r * g.w .. r * g.w + g.w]);
    }
    // Store in a free (or reused) cache slot.
    var slot: ?*Cached = null;
    for (&cache) |*c| {
        if (!c.used) {
            slot = c;
            break;
        }
    }
    const c = slot orelse &cache[0]; // full: clobber slot 0 (rare at these sizes)
    c.* = .{
        .used = true,
        .is_mono = is_mono,
        .px = px_dev,
        .cp = cp,
        .ax = @intCast(pos.x),
        .ay = @intCast(pos.y),
        .w = @intCast(g.w),
        .h = @intCast(g.h),
        .left = @intCast(g.left),
        .top = @intCast(g.top),
        .adv = @intFromFloat(@round(g.advance)),
    };
    return c;
}

/// The line height and ascent of a role at its effective size (device px).
fn roleMetrics(role: u64, px_dev: f32) struct { line: i32, ascent: i32 } {
    const f = roleFont(role) orelse return .{ .line = @intFromFloat(px_dev), .ascent = @intFromFloat(px_dev) };
    const s = px_dev / @as(f32, @floatFromInt(f.units_per_em));
    const asc = @as(f32, @floatFromInt(f.ascent)) * s;
    const desc = @as(f32, @floatFromInt(f.descent)) * s;
    return .{ .line = @intFromFloat(@round(asc - desc)), .ascent = @intFromFloat(@round(asc)) };
}

fn loadFonts(blob: []const u8) void {
    // The bundled families are seeded into the assets tier, so the archive
    // holds them at assets/fonts/… — read them straight from the boot
    // archive (a Font borrows the mapped bytes), no filesystem needed.
    if (shared.marcFind(blob, "assets/fonts/IBMPlexSans.ttf")) |bytes| {
        sans = font.Font.parse(bytes) catch null;
    }
    if (shared.marcFind(blob, "assets/fonts/IBMPlexMono-Regular.ttf")) |bytes| {
        mono = font.Font.parse(bytes) catch null;
    }
    if (sans == null and mono == null) {
        _ = usys.log(glog, "fontsvc: no fonts loaded");
        usys.exit(161);
    }
    // If one family is missing, fall back to whichever loaded.
    if (sans == null) sans = mono;
    if (mono == null) mono = sans;
}

export fn umain(log_h: u64, chan_h: u64, _: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    // Consume init's boot handshake on the serve channel (no caps needed —
    // the fonts come from the archive blob — but init's `go` must be
    // answered or it deems the unit unwired). Then serve FontReq on it.
    _ = boot.take(chan_h);
    if (blob_va == 0) {
        _ = usys.log(glog, "fontsvc: no boot archive");
        usys.exit(162);
    }
    loadFonts(@as([*]const u8, @ptrFromInt(blob_va))[0..blob_len]);

    const sh = usys.shmCreate(atlas_pages);
    if (sh.err != .ok) usys.exit(163);
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) usys.exit(164);
    atlas = @ptrFromInt(m.data[0]);
    atlas_shm = sh.data[0];
    @memset(atlas[0 .. atlas_w * atlas_h], 0);
    _ = usys.log(glog, "fontsvc: up");

    // One client's request/response buffer (the GUI runtime). A second
    // client replaces it — per-client buffers come with multi-app use.
    var req_va: u64 = 0;
    var req_len: usize = 0;

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(shared.FontReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.FontResp, chan_h, .{ .font_err = .{ .code = 1 } }, 0);
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap == 0) {
                    _ = usys.replyTyped(shared.FontResp, chan_h, .{ .font_err = .{ .code = 2 } }, 0);
                    continue;
                }
                const cm = usys.shmMap(r.cap);
                _ = usys.capDrop(r.cap);
                if (cm.err != .ok) {
                    _ = usys.replyTyped(shared.FontResp, chan_h, .{ .font_err = .{ .code = 3 } }, 0);
                    continue;
                }
                if (req_va != 0) _ = usys.shmUnmap(req_va);
                req_va = cm.data[0];
                req_len = cm.data[1] * 4096;
                _ = usys.replyTyped(shared.FontResp, chan_h, .ok, 0);
            },
            .atlas => {
                // Hand back a copy of the atlas cap for the client to map.
                _ = usys.replyTyped(shared.FontResp, chan_h, .{ .atlas = .{ .wh = shared.packPair(atlas_w, atlas_h) } }, atlas_shm);
            },
            .metrics => |q| {
                const px_dev = rolePx(q.role, 0);
                const mm = roleMetrics(q.role, px_dev);
                _ = usys.replyTyped(shared.FontResp, chan_h, .{ .metrics = .{
                    .px = @intFromFloat(@round(px_dev)),
                    .line = @intCast(mm.line),
                    .ascent = @intCast(mm.ascent),
                } }, 0);
            },
            .layout => |q| {
                if (req_va == 0 or q.len > req_len) {
                    _ = usys.replyTyped(shared.FontResp, chan_h, .{ .font_err = .{ .code = 4 } }, 0);
                    continue;
                }
                const buf: [*]u8 = @ptrFromInt(req_va);
                const px_f = rolePx(q.role, q.px);
                const px_dev: u16 = @intFromFloat(@round(px_f));
                // Decode the UTF-8 input first (the output overwrites it).
                var cps: [512]u21 = undefined;
                var ncp: usize = 0;
                var it = std.unicode.Utf8Iterator{ .bytes = buf[0..@intCast(q.len)], .i = 0 };
                while (it.nextCodepoint()) |cp| {
                    if (ncp >= cps.len) break;
                    cps[ncp] = cp;
                    ncp += 1;
                }
                // Lay them out, writing a FontGlyph run into the buffer.
                const run: [*]shared.FontGlyph = @ptrFromInt(req_va);
                var pen: i32 = 0;
                var count: usize = 0;
                for (cps[0..ncp]) |cp| {
                    if ((count + 1) * @sizeOf(shared.FontGlyph) > req_len) break;
                    const c = ensureGlyph(q.role, px_dev, cp) orelse continue;
                    run[count] = .{
                        .pen_x = pen,
                        .atlas_x = c.ax,
                        .atlas_y = c.ay,
                        .w = c.w,
                        .h = c.h,
                        .left = c.left,
                        .top = c.top,
                    };
                    pen += c.adv;
                    count += 1;
                }
                const mm = roleMetrics(q.role, px_f);
                _ = usys.replyTyped(shared.FontResp, chan_h, .{ .laid = .{
                    .count = count,
                    .pen = shared.packPair(@intCast(pen), @intCast(mm.line)),
                } }, 0);
            },
        }
    }
}
