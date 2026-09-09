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
const fsc = @import("fsclient.zig");
const mosslib = @import("mosslib");
const font = mosslib.font;
const mshl = mosslib.mshl;
const settings = mosslib.settings;

comptime {
    asm (usys.imageHeader("fontsvc"));
}

pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;

// The font registry: every .ttf found (the bundled families in the boot
// archive's assets/fonts, and any a user installs there) parsed and keyed
// by family name, so conf/font.msh can pick a family per role by name — a
// custom font is "install the .ttf, name it in the settings". A Font
// borrows its bytes from the archive (mapped read-only, lives for the
// program), so nothing is copied.
const max_families = 12;
const Family = struct {
    name: [64]u8 = undefined,
    name_len: usize = 0,
    font: font.Font = undefined,
};
var families: [max_families]Family = @splat(.{});
var nfamilies: usize = 0;

// A WOFF/WOFF2 font is decompressed here into a full SFNT (a Font borrows
// the result, so it must persist); TTF/OTF pass through untouched.
var decomp_heap: [4 << 20]u8 = undefined;
var decomp_used: usize = 0;
// Transient scratch for the WOFF2 path (Brotli arena + glyf reconstruction);
// reset per font, since only the produced SFNT is kept.
var woff2_scratch: [2 << 20]u8 = undefined;

fn registerFont(bytes: []const u8, from_fs: bool) void {
    if (nfamilies >= max_families) return;
    // Normalise any container (WOFF/WOFF2) to SFNT; SFNT input is returned
    // as-is, so only a compressed font consumes the decompress heap. WOFF2
    // also needs a working allocator (reset each call).
    var fba = std.heap.FixedBufferAllocator.init(&woff2_scratch);
    const sfnt = font.toSfnt(fba.allocator(), bytes, decomp_heap[decomp_used..]) catch return;
    const parsed = font.Font.parse(sfnt) catch return;
    var fam = &families[nfamilies];
    fam.font = parsed;
    const nm = fam.font.familyName(&fam.name);
    if (nm.len == 0) return; // unnamed: cannot be selected, skip
    fam.name_len = nm.len;
    if (familyIndex(nm) != null) return; // already have this family
    // The font is kept: if it was decompressed, commit its heap so a later
    // font does not overwrite the bytes this Font borrows.
    if (sfnt.ptr != bytes.ptr) decomp_used += sfnt.len;
    nfamilies += 1;
    var b: [96]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&b, "fontsvc: family '{s}'{s}", .{ nm, if (from_fs) " (fs)" else "" }) catch "fontsvc: family");
}

// Fonts read from a filesystem view are copied here (a Font borrows its
// bytes, and fs files are not in the mapped archive), so a user can
// install a font by dropping the .ttf in the fonts directory.
var fs_heap: [3 << 20]u8 = undefined;
var fs_used: usize = 0;
var g_view: u64 = 0; // the fonts-directory view, kept for `rescan`

// Filenames already read from the view, so a re-scan reads only the new
// ones (and never the same file twice into the heap).
var seen: [max_families][64]u8 = undefined;
var seen_len: [max_families]usize = @splat(0);
var n_seen: usize = 0;
fn alreadySeen(name: []const u8) bool {
    for (0..n_seen) |i| {
        if (std.mem.eql(u8, seen[i][0..seen_len[i]], name)) return true;
    }
    return false;
}

/// A font file we try to load (by extension). All four are supported:
/// TTF/OTF (SFNT), WOFF (zlib), WOFF2 (Brotli); toSfnt/parse reject any file
/// that does not actually decode.
fn isFontFile(name: []const u8) bool {
    return std.mem.endsWith(u8, name, ".ttf") or std.mem.endsWith(u8, name, ".otf") or
        std.mem.endsWith(u8, name, ".woff") or std.mem.endsWith(u8, name, ".woff2");
}

/// Scan a filesystem fonts directory (`view`) and register every new .ttf
/// in it — the runtime install path, also the `rescan` handler. Best
/// effort: a bad file is skipped.
fn scanView(view: u64) void {
    const ab = fsc.attachBuf(view);
    if (ab.va == 0) return;
    const buf: [*]u8 = @ptrFromInt(ab.va);
    const n = fsc.fsList(view, buf, "") orelse return;
    // The listing (\n-separated names) lives in `buf`, which readWhole
    // reuses — copy it out first.
    var names: [4096]u8 = undefined;
    const m = @min(n, names.len);
    @memcpy(names[0..m], buf[0..m]);
    var it = std.mem.splitScalar(u8, names[0..m], '\n');
    while (it.next()) |name| {
        if (name.len == 0 or name.len > 64 or !isFontFile(name)) continue;
        if (alreadySeen(name)) continue;
        if (n_seen < seen.len) {
            @memcpy(seen[n_seen][0..name.len], name);
            seen_len[n_seen] = name.len;
            n_seen += 1;
        }
        if (fs_used >= fs_heap.len) break;
        const bytes = fsc.readWhole(view, buf, name, fs_heap[fs_used..]) orelse continue;
        fs_used += bytes.len;
        registerFont(bytes, true);
    }
}

fn familyIndex(name: []const u8) ?u8 {
    for (families[0..nfamilies], 0..) |*fam, i| {
        if (std.mem.eql(u8, fam.name[0..fam.name_len], name)) return @intCast(i);
    }
    return null;
}

// The effective font settings: the scale, and per-role base sizes and
// family names (conf/font.msh, the system settings layer). Every size is
// multiplied by `scale` (the accessibility knob) to reach device pixels.
var scale: f32 = 1.0;
var ui_base: f32 = 16;
var title_base: f32 = 22;
var mono_base: f32 = 15;
const NameBuf = struct {
    buf: [64]u8 = undefined,
    len: usize = 0,
    fn set(nb: *NameBuf, s: []const u8) void {
        const n = @min(s.len, nb.buf.len);
        @memcpy(nb.buf[0..n], s[0..n]);
        nb.len = n;
    }
    fn get(nb: *const NameBuf) []const u8 {
        return nb.buf[0..nb.len];
    }
};
var ui_fam: NameBuf = .{};
var title_fam: NameBuf = .{};
var mono_fam: NameBuf = .{};

fn roleFamilyName(role: u64) []const u8 {
    return switch (role) {
        @intFromEnum(shared.FontRole.title) => title_fam.get(),
        @intFromEnum(shared.FontRole.mono) => mono_fam.get(),
        else => ui_fam.get(),
    };
}
fn roleBase(role: u64) f32 {
    return switch (role) {
        @intFromEnum(shared.FontRole.title) => title_base,
        @intFromEnum(shared.FontRole.mono) => mono_base,
        else => ui_base,
    };
}
/// The registry index of a role's family (its configured name, else the
/// first registered family as a fallback).
fn roleFontIndex(role: u64) u8 {
    return familyIndex(roleFamilyName(role)) orelse 0;
}
fn roleFont(role: u64) ?*font.Font {
    if (nfamilies == 0) return null;
    return &families[roleFontIndex(role)].font;
}
fn rolePx(role: u64, req_px: u64) f32 {
    const base: f32 = if (req_px != 0) @floatFromInt(req_px) else roleBase(role);
    return base * scale;
}

// Reading the settings file: a small mshl interp parses the data literal,
// lib/settings merges the (future) user layer over it.
var settings_mem: [64 << 10]u8 = undefined;
fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const mshl.Value, _: ?mshl.Value) mshl.Error!?mshl.Value {
    return null;
}
fn numF(v: mshl.Value) ?f32 {
    return switch (v) {
        .int => |i| @floatFromInt(i),
        .float => |f| @floatCast(f),
        else => null,
    };
}
fn strOf(v: mshl.Value) ?[]const u8 {
    return if (v == .str) v.str else null;
}

// The system settings layer (conf/font.msh), kept so a pushed per-user
// layer can be merged over it (lib/settings) whenever a session applies
// one — and dropped back to the system layer alone on logout.
var system_text: [4 << 10]u8 = undefined;
var system_len: usize = 0;

/// Remember the system layer's text (from the boot archive).
fn setSystemLayer(text: []const u8) void {
    const n = @min(text.len, system_text.len);
    @memcpy(system_text[0..n], text[0..n]);
    system_len = n;
}

/// Apply the effective settings for a merge of the system layer with an
/// optional per-user layer (`user_text`, empty = system layer alone):
/// re-derive scale, per-role sizes and per-role family names. New sizes
/// simply produce new atlas entries on the next layout, so a client sees
/// the change when it next renders; the old cached glyphs are harmless.
fn applyLayers(user_text: []const u8) void {
    if (system_len == 0) return;
    var fba = std.heap.FixedBufferAllocator.init(&settings_mem);
    const a = fba.allocator();
    var ctx: u8 = 0;
    var it = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&ctx), .call = noHost });
    const sv = it.parseData(system_text[0..system_len]) catch return;
    if (sv != .record) return;
    var user: ?mshl.Record = null;
    if (user_text.len > 0) {
        const uv = it.parseData(user_text) catch return;
        if (uv == .record) user = uv.record;
    }
    const eff = settings.merge(a, sv.record, user, &.{}) catch return;
    // Reset to system defaults first, so a user layer that drops a key
    // reverts it (merge already handles present keys; this covers the
    // logout case, applyLayers("")).
    scale = 1.0;
    ui_base = 16;
    title_base = 22;
    mono_base = 15;
    if (eff.get("scale")) |x| if (numF(x)) |f| {
        if (f >= 0.5 and f <= 6.0) scale = f;
    };
    if (eff.get("ui")) |x| if (numF(x)) |f| {
        ui_base = f;
    };
    if (eff.get("title")) |x| if (numF(x)) |f| {
        title_base = f;
    };
    if (eff.get("mono")) |x| if (numF(x)) |f| {
        mono_base = f;
    };
    if (eff.get("ui_family")) |x| if (strOf(x)) |s| ui_fam.set(s);
    if (eff.get("title_family")) |x| if (strOf(x)) |s| title_fam.set(s);
    if (eff.get("mono_family")) |x| if (strOf(x)) |s| mono_fam.set(s);
}

/// Log the effective UI size and scale (at boot, and after a reconfigure).
fn logEffective(label: []const u8) void {
    var b: [96]u8 = undefined;
    const ui_eff: u32 = @intFromFloat(@round(ui_base * scale));
    _ = usys.log(glog, std.fmt.bufPrint(&b, "fontsvc: {s} (ui {d}px, scale {d}.{d:0>2})", .{
        label,
        ui_eff,
        @as(u32, @intFromFloat(scale)),
        @as(u32, @intFromFloat(@round(scale * 100))) % 100,
    }) catch "fontsvc: reconfigured");
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

// The glyph cache: (family, px, codepoint) → its atlas rect + metrics.
const Cached = struct {
    used: bool = false,
    fam: u8 = 0,
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
    if (nfamilies == 0) return null;
    const fam = roleFontIndex(role);
    for (&cache) |*c| {
        if (c.used and c.fam == fam and c.px == px_dev and c.cp == cp) return c;
    }
    const f = &families[fam].font;
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
        .fam = fam,
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

fn loadArchiveFonts(blob: []const u8) void {
    // Register every .ttf under assets/fonts/ in the boot archive — the
    // bundled families. A Font borrows the mapped archive bytes.
    var it = shared.marcIter(blob);
    while (it.next()) |e| {
        if (std.mem.startsWith(u8, e.path, "assets/fonts/") and isFontFile(e.path)) {
            registerFont(e.data, false);
        }
    }
}

/// `fs_only`: read fonts from the filesystem view alone (a real system's
/// installable fonts directory), skipping the archive; otherwise the
/// archive's bundled families (the diskless default), plus the view if one
/// is given. Then default the roles and apply the settings layer.
fn loadFonts(blob: []const u8, fs_only: bool, view: u64) void {
    g_view = view;
    if (fs_only) {
        if (view != 0) scanView(view);
    } else {
        loadArchiveFonts(blob);
        if (view != 0) scanView(view);
    }
    if (nfamilies == 0) {
        _ = usys.log(glog, "fontsvc: no fonts loaded");
        usys.exit(161);
    }
    ui_fam.set("IBM Plex Sans");
    title_fam.set("IBM Plex Sans");
    mono_fam.set("IBM Plex Mono");
    if (shared.marcFind(blob, "conf/font.msh")) |cfg| {
        setSystemLayer(cfg);
        applyLayers(""); // the system layer alone until a session pushes one
    }
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    // Consume init's boot handshake on the serve channel (the fonts come
    // from the archive and/or a fonts view, but init's `go` must be
    // answered or it deems the unit unwired). Then serve FontReq on it.
    const setup = boot.take(chan_h);
    if (blob_va == 0) {
        _ = usys.log(glog, "fontsvc: no boot archive");
        usys.exit(162);
    }
    // arg 1 = read fonts from the filesystem view only (installable fonts).
    const view: u64 = if (setup.has(.view)) setup.cap(.view) else 0;
    loadFonts(@as([*]const u8, @ptrFromInt(blob_va))[0..blob_len], arg == 1, view);

    const sh = usys.shmCreate(atlas_pages);
    if (sh.err != .ok) usys.exit(163);
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) usys.exit(164);
    atlas = @ptrFromInt(m.data[0]);
    atlas_shm = sh.data[0];
    @memset(atlas[0 .. atlas_w * atlas_h], 0);
    {
        logEffective("up");
    }

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
            .rescan => {
                // Pick up a font dropped into the view since startup.
                if (g_view != 0) scanView(g_view);
                _ = usys.replyTyped(shared.FontResp, chan_h, .ok, 0);
            },
            .reconfigure => |q| {
                // A session pushes the logged-in user's font.msh (in the
                // request buffer); merge it over the system layer and
                // re-apply. len 0 reverts to the system layer (logout).
                if (q.len > req_len or (q.len > 0 and req_va == 0)) {
                    _ = usys.replyTyped(shared.FontResp, chan_h, .{ .font_err = .{ .code = 5 } }, 0);
                    continue;
                }
                const user_text: []const u8 = if (q.len > 0) @as([*]const u8, @ptrFromInt(req_va))[0..@intCast(q.len)] else "";
                applyLayers(user_text);
                logEffective("reconfigured");
                _ = usys.replyTyped(shared.FontResp, chan_h, .ok, 0);
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
