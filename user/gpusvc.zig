//! virtio-gpu (device type 16), in userspace — moss's display server.
//! Stage 1 brings up scanout 0 and proves the whole 2D path: negotiate
//! and set up the control queue, GET_DISPLAY_INFO, create a
//! host resource, attach a guest-memory backing for it, fill the
//! framebuffer with a known colour, set it as the scanout, transfer it to
//! the host and flush — then confirm the device accepted every command
//! and read its own backing back before logging "gpu: scanout up". The
//! host side of the drill screendumps the scanout over QMP and checks the
//! pixels are that colour.
//!
//! The framebuffer (1024x768x4 = 768 pages) is larger than dma_alloc's
//! 16-page cap, so its backing is a scatter-gather list of chunks —
//! exactly what RESOURCE_ATTACH_BACKING takes. A solid fill needs no
//! offset arithmetic across chunks (every chunk holds the same pattern);
//! glyph rendering, when the terminal (a surface client) arrives, will.
//!
//! Same driver interface as the other virtio drivers (device cap over the
//! boot channel, IRQ-as-notification, DMA grant); the surface protocol
//! that clients drive comes in the next stage.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const virtio = @import("virtio.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("gpusvc"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// The device arrives over the boot channel (BootReq cap{device}).
var dev_h: u64 = 0;

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    dev_h = setup.device(.gpu);
    if (dev_h == 0) usys.exit(169);
    keys_chan = setup.cap(.keys);
    ptr_chan = setup.cap(.ptr);
    // The trusted-path token: the seat gives it to the compositor and to
    // the login greeter alike. A client that presents it over
    // `attach_trusted` earns a badged channel whose surfaces are the
    // login surface. No token (the display-only drills) = no trusted path.
    const sec = setup.secret();
    if (sec.len >= 8) trust_token = std.mem.readInt(u64, sec[0..8], .little);
    gpudrv(log_h, chan_h);
}

// ------------------------------------------------------------ constants

const desc_f_next = 1;
const desc_f_write = 2;

const fb_w = 1024;
const fb_h = 768;
const fb_bpp = 4;
const fb_stride = fb_w * fb_bpp;
const fb_bytes = fb_stride * fb_h; // 3,145,728
const fb_pages = fb_bytes / 4096; // 768
const chunk_pages = 16; // dma_alloc's per-call cap
const n_chunks = (fb_pages + chunk_pages - 1) / chunk_pages; // 48

const q_ctl = 0;
const q_num = 16;

// virtio-gpu control commands (§5.7.6.7) and responses.
const cmd_get_display_info = 0x0100;
const cmd_resource_create_2d = 0x0101;
const cmd_set_scanout = 0x0103;
const cmd_resource_flush = 0x0104;
const cmd_transfer_to_host_2d = 0x0105;
const cmd_resource_attach_backing = 0x0106;
const resp_ok_nodata = 0x1100;
const resp_ok_display_info = 0x1101;

const format_b8g8r8x8 = 2; // VIRTIO_GPU_FORMAT_B8G8R8X8_UNORM
const res_id = 1;
const scanout_id = 0;

/// The fill: B=0xCC, G=0x99, R=0x33, X=0x00 — a blue, laid out for
/// B8G8R8X8 (byte order B,G,R,X), so as a little-endian word it is this.
/// A screendump reads it back as RGB (0x33, 0x99, 0xCC).
const fill_word: u32 = 0x0033_99CC;

const Desc = extern struct { addr: u64, len: u32, flags: u16, next: u16 };

var dev: virtio.Dev = undefined;
var irq_notif: u64 = 0;
var vq_va: u64 = 0;
var vq_dev: u64 = 0;
var cmd_va: u64 = 0; // the command buffer (device-readable)
var cmd_dev: u64 = 0;
var resp_va: u64 = 0; // the response buffer (device-writable)
var resp_dev: u64 = 0;
var used_seen: u16 = 0;
var avail_shadow: u16 = 0;
var fb_va: [n_chunks]u64 = @splat(0);
var fb_dev: [n_chunks]u64 = @splat(0);
var fb_chunk_pages: [n_chunks]u64 = @splat(0);
var fb_chunk_start: [n_chunks]u64 = @splat(0); // linear byte offset of each chunk

const max_surfaces = 4;
const Surface = struct {
    used: bool = false,
    shm: u64 = 0,
    va: u64 = 0,
    len: usize = 0,
    x: u32 = 0,
    y: u32 = 0,
    w: u32 = 0,
    h: u32 = 0,
    z: u32 = 0, // stacking order; higher is nearer the top
    owner: u64 = 0, // the badge that created it; keys route to the owner alone
    trusted: bool = false, // the login surface: wears the secure indicator
};
var surfaces: [max_surfaces]Surface = @splat(.{});
var next_z: u32 = 1;
/// The compositor's ground, seen wherever no surface covers the scanout.
const bg_word: u32 = 0x0020_2830; // a dark slate
/// The focus cue: a border drawn inside the focused surface's edges.
const focus_word: u32 = 0x00FF_FF00; // X<<24|R<<16|G<<8|B -> RGB(255,255,0), yellow
const focus_border = 4; // pixels

// The trusted path. The compositor holds a boot-provisioned token; a
// client that echoes it over `attach_trusted` gets a channel badged
// `trusted_badge`, and every surface it makes is the login surface. The
// secure indicator is a strip along the very top of the scanout, painted
// last (a client cannot draw over it) in `secure_word` whenever the
// focused surface is the trusted one — the user's cue that the keyboard
// truly reaches the login and nothing else.
const trusted_badge: u64 = 1;
const trust_strip = 8; // px, the reserved indicator band at the top
const secure_word: u32 = 0x0000_66CC; // X<<24|R<<16|G<<8|B -> RGB(0,0x66,0xCC), a deep blue
var trust_token: u64 = 0; // 0 = the trusted path is disabled (no token)

// Focus: the compositor reads the keyboard (if it holds one) and routes
// keystrokes to the focused surface; Tab cycles focus.
var keys_chan: u64 = 0; // inputsvc channel, 0 when the seat gives no keyboard
var keys_buf: [*]volatile u8 = undefined;
var focused: u64 = 0; // focused surface id, 0 = none
const key_switch_focus: u8 = '\t';

// ---------------------------------------------------- command building

fn wr32(off: usize, v: u32) void {
    @as(*volatile u32, @ptrFromInt(cmd_va + off)).* = v;
}
fn wr64(off: usize, v: u64) void {
    @as(*volatile u64, @ptrFromInt(cmd_va + off)).* = v;
}

/// The 24-byte control header at `off` of the command buffer.
fn hdr(cmd_type: u32) void {
    wr32(0, cmd_type);
    wr32(4, 0); // flags
    wr64(8, 0); // fence_id
    wr32(16, 0); // ctx_id
    wr32(20, 0); // padding
}

/// A rect {x, y, width, height} at `off`.
fn rect(off: usize, x: u32, y: u32, w: u32, h: u32) void {
    wr32(off, x);
    wr32(off + 4, y);
    wr32(off + 8, w);
    wr32(off + 12, h);
}

fn cmdDisplayInfo() usize {
    hdr(cmd_get_display_info);
    return 24;
}
fn cmdCreate2d() usize {
    hdr(cmd_resource_create_2d);
    wr32(24, res_id);
    wr32(28, format_b8g8r8x8);
    wr32(32, fb_w);
    wr32(36, fb_h);
    return 40;
}
fn cmdAttachBacking() usize {
    hdr(cmd_resource_attach_backing);
    wr32(24, res_id);
    wr32(28, n_chunks);
    var off: usize = 32;
    for (0..n_chunks) |i| {
        wr64(off, fb_dev[i]);
        wr32(off + 8, @intCast(fb_chunk_pages[i] * 4096));
        wr32(off + 12, 0); // padding
        off += 16;
    }
    return off;
}
fn cmdSetScanout() usize {
    hdr(cmd_set_scanout);
    rect(24, 0, 0, fb_w, fb_h);
    wr32(40, scanout_id);
    wr32(44, res_id);
    return 48;
}
fn cmdTransfer(x: u32, y: u32, w: u32, h: u32) usize {
    hdr(cmd_transfer_to_host_2d);
    rect(24, x, y, w, h);
    // The backing is laid out as the linear resource, so the offset of the
    // rect's top-left pixel is its scanline offset — the device walks the
    // scatter-gather list from there, one resource-stride row at a time.
    wr64(40, @as(u64, y) * fb_stride + @as(u64, x) * fb_bpp);
    wr32(48, res_id);
    wr32(52, 0); // padding
    return 56;
}
fn cmdFlush(x: u32, y: u32, w: u32, h: u32) usize {
    hdr(cmd_resource_flush);
    rect(24, x, y, w, h);
    wr32(40, res_id);
    wr32(44, 0); // padding
    return 48;
}

// ---------------------------------------------------- the control queue

/// Submit one command (cmd_len bytes, device-readable) with a writable
/// response of `resp_cap` bytes, wait for completion, and return the
/// response's control-header type. Commands are issued one at a time, so
/// descriptor 0 is reused every call.
fn submitCmd(cmd_len: usize, resp_cap: usize) u32 {
    const descs: [*]volatile Desc = @ptrFromInt(vq_va);
    descs[0] = .{ .addr = cmd_dev, .len = @intCast(cmd_len), .flags = desc_f_next, .next = 1 };
    descs[1] = .{ .addr = resp_dev, .len = @intCast(resp_cap), .flags = desc_f_write, .next = 0 };
    const avail_ring: [*]volatile u16 = @ptrFromInt(vq_va + 512 + 4);
    avail_ring[avail_shadow % q_num] = 0; // head descriptor index
    avail_shadow +%= 1;
    const avail_idx: *volatile u16 = @ptrFromInt(vq_va + 512 + 2);
    usys.barrier();
    avail_idx.* = avail_shadow;
    usys.barrier();
    dev.notify(q_ctl);

    const used_idx: *volatile u16 = @ptrFromInt(vq_va + 1024 + 2);
    while (used_seen == used_idx.*) {
        _ = usys.notifyWait(irq_notif);
        _ = dev.isrRead(); // deassert INTx (harmless under MSI-X)
    }
    used_seen +%= 1;
    usys.barrier();
    return @as(*volatile u32, @ptrFromInt(resp_va)).*;
}

// ------------------------------------------------------- framebuffer

fn fillFb() void {
    for (0..n_chunks) |i| {
        const words = fb_chunk_pages[i] * 4096 / 4;
        const p: [*]volatile u32 = @ptrFromInt(fb_va[i]);
        var j: usize = 0;
        while (j < words) : (j += 1) p[j] = fill_word;
    }
}

/// Read the backing back: the deterministic half of the proof. Sample the
/// ends and middle of every chunk (a full scan would be gratuitous).
fn readbackOk() bool {
    for (0..n_chunks) |i| {
        const words = fb_chunk_pages[i] * 4096 / 4;
        const p: [*]volatile u32 = @ptrFromInt(fb_va[i]);
        if (p[0] != fill_word or p[words / 2] != fill_word or p[words - 1] != fill_word) return false;
    }
    return true;
}

/// Write `len` bytes from `src` into the framebuffer backing at linear
/// byte offset `off`, walking the scatter-gather chunks. Offsets within
/// one call only increase, so the chunk cursor advances monotonically.
fn fbWrite(off: usize, src: [*]const u8, len: usize) void {
    var o = off;
    var s: usize = 0;
    var rem = len;
    var c: usize = 0;
    while (rem > 0) {
        while (c < n_chunks and o >= fb_chunk_start[c] + fb_chunk_pages[c] * 4096) c += 1;
        if (c >= n_chunks) return; // past the framebuffer: drop the rest
        const chunk_end = fb_chunk_start[c] + fb_chunk_pages[c] * 4096;
        const within = o - fb_chunk_start[c];
        const n = @min(rem, chunk_end - o);
        const dst: [*]u8 = @ptrFromInt(fb_va[c] + within);
        @memcpy(dst[0..n], src[s .. s + n]);
        o += n;
        s += n;
        rem -= n;
    }
}

/// Ship the whole framebuffer to the host resource and flush it. Called
/// at bring-up and after every commit (a per-rect transfer is a later
/// optimisation; correctness only needs the damage rect to bound the
/// copy into the backing, which commit does).
/// Ship one rectangle of the backing to the host resource and flush it to
/// the scanout — the per-rect path a commit takes, so only the damaged
/// region crosses the virtio boundary instead of the whole 640x480.
fn transferFlushRect(r: Rect) bool {
    const x: u32 = @intCast(r.x);
    const y: u32 = @intCast(r.y);
    const w: u32 = @intCast(r.w);
    const h: u32 = @intCast(r.h);
    if (submitCmd(cmdTransfer(x, y, w, h), 64) != resp_ok_nodata) return false;
    if (submitCmd(cmdFlush(x, y, w, h), 64) != resp_ok_nodata) return false;
    return true;
}

// -------------------------------------------------------- surfaces

/// Focus the topmost (highest-z) live surface, or none (0) — used when
/// the focused surface is destroyed (a GUI login closing leaves the
/// terminal beneath it focused, so keys reach the shell).
fn focusTopmost() void {
    var best_id: u64 = 0;
    var best_z: u32 = 0;
    for (&surfaces, 0..) |*sf, i| {
        if (!sf.used) continue;
        if (best_id == 0 or sf.z >= best_z) {
            best_id = i + 1;
            best_z = sf.z;
        }
    }
    focused = best_id;
}

fn anyTrusted() bool {
    for (&surfaces) |*sf| {
        if (sf.used and sf.trusted) return true;
    }
    return false;
}

fn findSurface(id: u64) ?*Surface {
    if (id == 0 or id > max_surfaces) return null;
    const sf = &surfaces[id - 1];
    return if (sf.used) sf else null;
}

/// A surface at (x, y) of size w x h owned by `owner` (the caller's
/// badge): a fresh shm both we and the client map — the client draws into
/// it, we read it when compositing. It stacks above every existing
/// surface. A surface owned by the trusted badge is the login surface.
/// Returns the surface id and the cap.
fn createSurface(owner: u64, x: u32, y: u32, w: u32, h: u32) ?struct { id: u64, shm: u64 } {
    var idx: usize = 0;
    while (idx < max_surfaces and surfaces[idx].used) idx += 1;
    if (idx == max_surfaces) return null;
    const pages = (@as(usize, w) * h * fb_bpp + 4095) / 4096;
    if (pages == 0 or pages > fb_pages) return null;
    const s = usys.shmCreate(pages);
    if (s.err != .ok) return null;
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) {
        _ = usys.capDrop(s.data[0]);
        return null;
    }
    surfaces[idx] = .{ .used = true, .shm = s.data[0], .va = m.data[0], .len = m.data[1] * 4096, .x = x, .y = y, .w = w, .h = h, .z = next_z, .owner = owner, .trusted = owner == trusted_badge };
    next_z += 1;
    // A new surface takes focus — but a non-trusted surface may not steal
    // focus from the login surface: a hostile client cannot pull the
    // keyboard away from a trusted prompt (a small secure-attention rule).
    const trusted_has_focus = if (findSurface(focused)) |f| f.trusted else false;
    if (!trusted_has_focus or owner == trusted_badge) focused = idx + 1;
    return .{ .id = idx + 1, .shm = s.data[0] };
}

fn destroySurface(sf: *Surface) void {
    if (sf.va != 0) _ = usys.shmUnmap(sf.va);
    if (sf.shm != 0) _ = usys.capDrop(sf.shm);
    sf.* = .{};
}

/// A scanout rectangle, in pixels. Compositing is expressed as rectangles
/// so a commit can recompose (and ship) just its damage instead of the
/// whole scanout.
const Rect = struct { x: usize, y: usize, w: usize, h: usize };

/// The overlap of two rects, or null when they are disjoint.
fn intersect(a: Rect, b: Rect) ?Rect {
    const x0 = @max(a.x, b.x);
    const y0 = @max(a.y, b.y);
    const x1 = @min(a.x + a.w, b.x + b.w);
    const y1 = @min(a.y + a.h, b.y + b.h);
    if (x1 <= x0 or y1 <= y0) return null;
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// A surface's footprint on the scanout, clipped to it.
fn surfaceRect(sf: *const Surface) Rect {
    var w: usize = sf.w;
    if (@as(usize, sf.x) + w > fb_w) w = fb_w - @as(usize, sf.x);
    var h: usize = sf.h;
    if (@as(usize, sf.y) + h > fb_h) h = fb_h - @as(usize, sf.y);
    return .{ .x = sf.x, .y = sf.y, .w = w, .h = h };
}

/// A commit's damage rect (surface-local `xy`/`wh`, a zero size meaning
/// the whole surface) translated to scanout coordinates and clipped to
/// the surface's footprint. A bogus rect falls back to the whole surface.
fn damageRect(sf: *const Surface, xy: u64, wh: u64) Rect {
    const sr = surfaceRect(sf);
    const dw = shared.unpackHi(wh);
    const dh = shared.unpackLo(wh);
    if (dw == 0 or dh == 0) return sr;
    const local: Rect = .{
        .x = @as(usize, sf.x) + shared.unpackHi(xy),
        .y = @as(usize, sf.y) + shared.unpackLo(xy),
        .w = dw,
        .h = dh,
    };
    return intersect(local, sr) orelse sr;
}

/// Fill a scanout rect (already clipped) with one colour word.
fn fillRect(r: Rect, word: u32) void {
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) fbSpan(y * fb_stride + r.x * fb_bpp, r.w, word);
}

/// Blit the part of a surface that falls in `r` (a rect within the
/// surface's scanout footprint) onto the framebuffer. The surface is
/// contiguous (w*bpp per row); the framebuffer is the scatter-gather
/// chunks, so each row goes through fbWrite.
fn blitRect(sf: *const Surface, r: Rect) void {
    const src: [*]const u8 = @ptrFromInt(sf.va);
    var y = r.y;
    while (y < r.y + r.h) : (y += 1) {
        const src_off = (y - @as(usize, sf.y)) * @as(usize, sf.w) * fb_bpp + (r.x - @as(usize, sf.x)) * fb_bpp;
        fbWrite(y * fb_stride + r.x * fb_bpp, src + src_off, r.w * fb_bpp);
    }
}

/// Fill `n` pixels of the framebuffer starting at byte offset `off` with
/// one colour word (through the scatter-gather chunks).
fn fbSpan(off: usize, n: usize, word: u32) void {
    var run: [256]u32 = undefined;
    for (&run) |*p| p.* = word;
    const src: [*]const u8 = @ptrCast(&run);
    var done: usize = 0;
    while (done < n) {
        // The `: usize` is load-bearing: @min against the comptime length
        // narrows its result type to fit 256, and `take * fb_bpp` would then
        // overflow that narrow type (256*4 > its max). Keep the width.
        const take: usize = @min(n - done, run.len);
        fbWrite(off + done * fb_bpp, src, take * fb_bpp);
        done += take;
    }
}

/// Draw the focus cue: a border just inside the focused surface's edges,
/// on top of everything, clipped to the scanout — so the window that has
/// the keyboard is visibly the one.
fn drawFocusBorder(sf: *const Surface, clip: Rect) void {
    const sr = surfaceRect(sf);
    if (sr.w == 0 or sr.h == 0) return;
    // `: usize` is load-bearing — @min against the comptime border width
    // narrows the result type to fit it, and `2 * bw` would overflow that.
    const bw: usize = @min(@as(usize, focus_border), @min(sr.w, sr.h));
    // Four bands: top, bottom, and the left/right columns between them.
    // Each is clipped to the recompose rect so a per-rect commit only
    // repaints the part of the border that its damage actually touches.
    var bands: [4]Rect = .{
        .{ .x = sr.x, .y = sr.y, .w = sr.w, .h = bw },
        .{ .x = sr.x, .y = sr.y + sr.h - bw, .w = sr.w, .h = bw },
        undefined,
        undefined,
    };
    var n: usize = 2;
    if (sr.h > 2 * bw) {
        const col_h = sr.h - 2 * bw;
        bands[2] = .{ .x = sr.x, .y = sr.y + bw, .w = bw, .h = col_h };
        bands[3] = .{ .x = sr.x + sr.w - bw, .y = sr.y + bw, .w = bw, .h = col_h };
        n = 4;
    }
    for (bands[0..n]) |b| {
        if (intersect(b, clip)) |ir| fillRect(ir, focus_word);
    }
}

/// Recompose the scanout: paint the ground, then every surface bottom to
/// top, then ship it to the host. Full recompose per commit — simple and
/// correct; per-rect composition is a later optimisation.
/// Recompose one scanout rectangle and ship just that rectangle to the
/// host. `clip` must already be within the scanout. The full-scanout
/// `composite()` is this over the whole framebuffer; a commit passes its
/// (translated, clipped) damage rect so only what changed is repainted
/// and transferred. Every step is clipped to `clip`, so pixels outside it
/// keep the value the host already holds.
fn compositeRect(clip: Rect) bool {
    // Ground.
    fillRect(clip, bg_word);
    // Surfaces, painters' order (lowest z first), each clipped to `clip`.
    var painted: u32 = 0;
    while (true) {
        var next: ?*Surface = null;
        for (&surfaces) |*sf| {
            if (!sf.used or sf.z <= painted) continue;
            if (next == null or sf.z < next.?.z) next = sf;
        }
        const sf = next orelse break;
        if (intersect(surfaceRect(sf), clip)) |ir| blitRect(sf, ir);
        painted = sf.z;
    }
    if (keys_chan != 0) {
        if (findSurface(focused)) |sf| drawFocusBorder(sf, clip);
    }
    // The trusted-path indicator: a strip across the very top of the
    // scanout, painted last of all so no client surface can forge it. It
    // is the secure colour only while the focused surface is the login
    // surface — the user's proof that the keyboard reaches login alone.
    // Only when a login surface actually exists: otherwise an ordinary
    // fullscreen client (a terminal) would have its top row overpainted.
    if (trust_token != 0 and anyTrusted()) {
        const secure = if (findSurface(focused)) |sf| sf.trusted else false;
        const word = if (secure) secure_word else bg_word;
        if (intersect(.{ .x = 0, .y = 0, .w = fb_w, .h = trust_strip }, clip)) |ir| fillRect(ir, word);
    }
    // The pointer cursor, last of all — the compositor draws it (trusted),
    // so it may sit over any surface and even the secure strip.
    drawCursor(clip);
    return transferFlushRect(clip);
}

/// Recompose and ship the whole scanout. Used at bring-up and whenever a
/// change is not confined to one damage rect (a focus switch moves the
/// cue and can flip the secure strip; a destroy uncovers whatever was
/// beneath). It also lays the ground across the scanout, which the
/// per-rect commits below then preserve outside their own rects.
fn composite() bool {
    laid_ground = true;
    return compositeRect(.{ .x = 0, .y = 0, .w = fb_w, .h = fb_h });
}
var laid_ground: bool = false;

// ------------------------------------------------------------- focus

/// Set up the keyboard the seat gave us: our own shm buffer for
/// inputsvc's read replies. Called once if we hold a keys channel.
fn setupKeyboard() void {
    const ks = usys.shmCreate(1);
    if (ks.err != .ok) usys.exit(171);
    const km = usys.shmMap(ks.data[0]);
    if (km.err != .ok) usys.exit(172);
    keys_buf = @ptrFromInt(km.data[0]);
    _ = usys.callTyped(shared.ConsReq, shared.ConsResp, keys_chan, .setup, ks.data[0]);
}

/// One keystroke from inputsvc (blocks until one), as a byte; 0 on error.
fn readKey() u8 {
    return switch (usys.callTyped(shared.ConsReq, shared.ConsResp, keys_chan, .{ .read = .{ .max = 1 } }, 0)) {
        .ok => |rep| switch (rep) {
            .n => |x| if (x.n >= 1) keys_buf[0] else 0,
            else => 0,
        },
        .err => 0,
    };
}

/// Move focus to the next surface (by id, wrapping) — Tab's job.
fn cycleFocus() void {
    // Focus never leaves a login surface: a trusted prompt keeps the
    // keyboard (secure attention), and its Tab is its own (field
    // navigation), not the compositor's to steal.
    if (findSurface(focused)) |sf| {
        if (sf.trusted) return;
    }
    var id: u64 = focused;
    var tries: u64 = 0;
    while (tries < max_surfaces) : (tries += 1) {
        id = (id % max_surfaces) + 1; // 1..max_surfaces, wrapping
        if (findSurface(id) != null) {
            focused = id;
            return;
        }
    }
}

/// The next keystroke for the focused surface: keys go to whoever has
/// focus, and Tab cycles focus here rather than reaching a client.
// Concurrent input readers. Reading the keyboard is a blocking call to
// inputsvc, so it cannot happen on the serve loop without stalling every
// other client. Instead a dedicated reader thread does the blocking read,
// pushes each key into a single-producer/single-consumer ring, and rings
// the doorbell; the serve loop parks each `next_input` (its reply token)
// and, woken by the doorbell, hands each key to the parked reader that
// owns the focused surface. So any number of clients can have a read
// pending at once and the compositor never blocks.
var key_bell: u64 = 0;
var key_reader_stack: [32 << 10]u8 align(16) = undefined;

const key_ring_cap = 64;
var key_ring: [key_ring_cap]u8 = undefined;
var key_head: usize = 0; // consumer (serve loop)
var key_tail: usize = 0; // producer (reader thread)

fn keyRingPush(c: u8) void {
    const t = @atomicLoad(usize, &key_tail, .monotonic);
    const nt = (t + 1) % key_ring_cap;
    if (nt == @atomicLoad(usize, &key_head, .acquire)) return; // full: drop
    key_ring[t] = c;
    @atomicStore(usize, &key_tail, nt, .release);
}
fn keyRingPeek() ?u8 {
    const h = @atomicLoad(usize, &key_head, .monotonic);
    if (h == @atomicLoad(usize, &key_tail, .acquire)) return null;
    return key_ring[h];
}
fn keyRingPop() void {
    const h = @atomicLoad(usize, &key_head, .monotonic);
    @atomicStore(usize, &key_head, (h + 1) % key_ring_cap, .release);
}

/// The reader thread: block on inputsvc for a key, buffer it, ring the
/// doorbell. On error (inputsvc gone, teardown) back off so we do not spin.
fn keyReader(_: u64) callconv(.c) void {
    while (true) {
        const c = readKey();
        if (c == 0) {
            usys.sleepMs(10);
            continue;
        }
        keyRingPush(c);
        _ = usys.notifySignal(key_bell, 1);
    }
}

// Parked readers: one outstanding `next_input` per client, named by the
// reply token so the serve loop can answer it later.
const max_readers = max_surfaces;
const Reader = struct { used: bool = false, badge: u64 = 0, token: u64 = 0 };
var readers: [max_readers]Reader = @splat(.{});

fn parkReader(badge: u64, token: u64) void {
    for (&readers) |*rd| if (rd.used and rd.badge == badge) {
        rd.token = token; // a client re-reads: replace its (already answered) token
        return;
    };
    for (&readers) |*rd| if (!rd.used) {
        rd.* = .{ .used = true, .badge = badge, .token = token };
        return;
    };
}
fn takeReader(badge: u64) ?u64 {
    for (&readers) |*rd| if (rd.used and rd.badge == badge) {
        const t = rd.token;
        rd.* = .{};
        return t;
    };
    return null;
}
fn dropReader(badge: u64) void {
    _ = takeReader(badge);
}

/// Hand buffered keys to the client that owns the focused surface. Tab is
/// absorbed here (it cycles focus, never reaches a client). A key with no
/// reader waiting on the focused surface stays in the ring until one
/// parks — buffered, like a terminal's own fifo, never delivered elsewhere.
fn dispatchKeys(chan_h: u64) void {
    while (keyRingPeek()) |c| {
        if (c == key_switch_focus) {
            const before = focused;
            cycleFocus();
            if (focused != before) {
                // Focus moved to another surface — Tab is the compositor's
                // here; absorb it and repaint the cue.
                keyRingPop();
                _ = composite();
                continue;
            }
            // Only one focusable surface: cycleFocus was a no-op, so Tab
            // belongs to the focused app (widget navigation) — fall through
            // and deliver it like any other key.
        }
        const owner = if (findSurface(focused)) |sf| sf.owner else {
            keyRingPop(); // nothing focused: the key has nowhere to go
            continue;
        };
        const token = takeReader(owner) orelse break; // hold until a reader parks
        keyRingPop();
        _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .input = .{ .surface = focused, .kind = 0, .arg = c } }, 0, token);
    }
}

// ----------------------------------------------------------- pointer
//
// A virtio tablet (inputsvc in pointer mode, reached over `ptr_chan`)
// gives the compositor an absolute cursor. A second reader thread does
// the blocking pointer reads and pushes frames into its own SPSC ring,
// ringing the same input doorbell the keyboard uses; the serve loop
// drains both. The cursor is compositor-drawn (trusted) on top of
// everything, so moving it recomposites only the small rectangle it
// vacates and the one it enters. A button change (or a move while a
// button is held — a drag) is routed to the surface under the cursor;
// a press also gives that surface focus (click-to-focus). Pure moves
// only slide the cursor — a hovering pointer never wakes a client.
var ptr_chan: u64 = 0;
var ptr_reader_stack: [32 << 10]u8 align(16) = undefined;

var cursor_x: usize = fb_w / 2;
var cursor_y: usize = fb_h / 2;
var cursor_shown: bool = false; // drawn once the first frame arrives
var prev_buttons: u32 = 0;

const cursor_w = 11;
const cursor_h = 16;
// A classic arrow: '.' = outline (black), '#' = fill (white), ' ' =
// transparent. The hotspot is the top-left tip at (cursor_x, cursor_y).
const cursor_rows = [cursor_h][]const u8{
    ".          ",
    "..         ",
    ".#.        ",
    ".##.       ",
    ".###.      ",
    ".####.     ",
    ".#####.    ",
    ".######.   ",
    ".#######.  ",
    ".########. ",
    ".#####.....",
    ".##.##.    ",
    ".#. .##.   ",
    "..  .##.   ",
    "     .##.  ",
    "      ..   ",
};
const cursor_fill: u32 = 0x00FF_FFFF; // white
const cursor_edge: u32 = 0x0000_0000; // black

const PtrEv = struct { x: u32, y: u32, buttons: u32 };
const ptr_ring_cap = 64;
var ptr_ring: [ptr_ring_cap]PtrEv = undefined;
var ptr_head: usize = 0; // consumer (serve loop)
var ptr_tail: usize = 0; // producer (reader thread)

fn ptrRingPush(e: PtrEv) void {
    const t = @atomicLoad(usize, &ptr_tail, .monotonic);
    const nt = (t + 1) % ptr_ring_cap;
    if (nt == @atomicLoad(usize, &ptr_head, .acquire)) return; // full: drop
    ptr_ring[t] = e;
    @atomicStore(usize, &ptr_tail, nt, .release);
}
fn ptrRingPop() ?PtrEv {
    const h = @atomicLoad(usize, &ptr_head, .monotonic);
    if (h == @atomicLoad(usize, &ptr_tail, .acquire)) return null;
    const e = ptr_ring[h];
    @atomicStore(usize, &ptr_head, (h + 1) % ptr_ring_cap, .release);
    return e;
}

/// One pointer frame from inputsvc (blocks until one), or null on error.
fn readPtr() ?PtrEv {
    return switch (usys.callTyped(shared.PtrReq, shared.PtrResp, ptr_chan, .read, 0)) {
        .ok => |rep| switch (rep) {
            .moved => |m| .{ .x = @intCast(m.x), .y = @intCast(m.y), .buttons = @intCast(m.buttons) },
            else => null,
        },
        .err => null,
    };
}

fn ptrReader(_: u64) callconv(.c) void {
    while (true) {
        const e = readPtr() orelse {
            usys.sleepMs(10);
            continue;
        };
        ptrRingPush(e);
        _ = usys.notifySignal(key_bell, 1);
    }
}

fn cursorRect() Rect {
    return .{ .x = cursor_x, .y = cursor_y, .w = cursor_w, .h = cursor_h };
}

/// The bounding box of two rects.
fn unionRect(a: Rect, b: Rect) Rect {
    const x0 = @min(a.x, b.x);
    const y0 = @min(a.y, b.y);
    const x1 = @max(a.x + a.w, b.x + b.w);
    const y1 = @max(a.y + a.h, b.y + b.h);
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// Move the cursor to (nx, ny): recomposite just the rectangle it leaves
/// and the one it enters (the cursor is redrawn in compositeRect's tail).
fn moveCursor(nx: usize, ny: usize) void {
    if (cursor_shown and nx == cursor_x and ny == cursor_y) return;
    const old = cursorRect();
    cursor_x = nx;
    cursor_y = ny;
    const shown_before = cursor_shown;
    cursor_shown = true;
    const dirty = if (shown_before) unionRect(old, cursorRect()) else cursorRect();
    _ = compositeRect(if (intersect(dirty, .{ .x = 0, .y = 0, .w = fb_w, .h = fb_h })) |r| r else return);
}

/// One pixel into the framebuffer backing (the cursor draws these).
fn fbPx(x: usize, y: usize, word: u32) void {
    var w = word;
    fbWrite((y * fb_w + x) * fb_bpp, @ptrCast(&w), fb_bpp);
}

/// Draw the cursor arrow, clipped to `clip` and the scanout — last in
/// compositeRect, so it sits over every surface and the secure strip.
fn drawCursor(clip: Rect) void {
    if (!cursor_shown) return;
    for (cursor_rows, 0..) |row, ry| {
        for (row, 0..) |ch, rx| {
            if (ch == ' ') continue;
            const px = cursor_x + rx;
            const py = cursor_y + ry;
            if (px >= fb_w or py >= fb_h) continue;
            if (px < clip.x or px >= clip.x + clip.w or py < clip.y or py >= clip.y + clip.h) continue;
            fbPx(px, py, if (ch == '#') cursor_fill else cursor_edge);
        }
    }
}

/// The id (1-based) of the topmost live surface under the cursor, or 0.
fn surfaceUnderCursor() u64 {
    var best_id: u64 = 0;
    var best_z: u32 = 0;
    for (&surfaces, 0..) |*sf, i| {
        if (!sf.used) continue;
        if (cursor_x < sf.x or cursor_x >= sf.x + sf.w) continue;
        if (cursor_y < sf.y or cursor_y >= sf.y + sf.h) continue;
        if (best_id == 0 or sf.z > best_z) {
            best_id = i + 1;
            best_z = sf.z;
        }
    }
    return best_id;
}

/// Give a surface focus on a click, honouring the same secure-attention
/// rule as createSurface: a non-trusted surface may not steal focus from
/// the login surface.
fn focusSurface(id: u64) void {
    if (id == focused) return;
    const target = findSurface(id) orelse return;
    const trusted_has_focus = if (findSurface(focused)) |f| f.trusted else false;
    if (trusted_has_focus and !target.trusted) return;
    focused = id;
    _ = composite(); // the focus cue (and maybe the secure strip) moved
}

/// Drain buffered pointer frames: slide the cursor, and on a button
/// change or a drag deliver a pointer event (surface-local) to the
/// surface under the cursor, giving it focus on a press.
fn dispatchPointer(chan_h: u64) void {
    while (ptrRingPop()) |e| {
        const nx = @min(@as(usize, e.x) * fb_w / 32768, fb_w - 1);
        const ny = @min(@as(usize, e.y) * fb_h / 32768, fb_h - 1);
        moveCursor(nx, ny);
        const buttons = e.buttons;
        const changed = buttons != prev_buttons;
        const press = (buttons & ~prev_buttons) != 0; // a newly-pressed button
        if (changed or buttons != 0) {
            const id = surfaceUnderCursor();
            if (id != 0) {
                if (press) focusSurface(id);
                const sf = findSurface(id).?;
                if (takeReader(sf.owner)) |token| {
                    const lx: u64 = cursor_x - sf.x;
                    const ly: u64 = cursor_y - sf.y;
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .input = .{ .surface = id, .kind = 1, .arg = shared.ptrArg(lx, ly, buttons) } }, 0, token);
                }
            }
        }
        prev_buttons = buttons;
    }
}

/// Serve the surface protocol on the boot channel (which is also the
/// service channel, like the console driver): create_surface hands back
/// a pixel buffer, commit copies its damage rect into the scanout and
/// flushes. Runs until the last client end closes.
fn serveSurfaces(chan_h: u64) noreturn {
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err == .interrupted) {
            // The input doorbell: buffered keys and/or pointer frames are
            // ready. Drain the latched bit, then hand each to its reader.
            _ = usys.notifyWait(key_bell);
            dispatchKeys(chan_h);
            dispatchPointer(chan_h);
            continue;
        }
        if (r.err == .client_dead) {
            // A reader's channel died: forget its parked read.
            dropReader(r.badge);
            continue;
        }
        if (r.err != .ok) continue;
        // The caller's identity: base clients invoke the shared display
        // channel (badge 0); the login greeter invokes the badged channel
        // it earned via `attach_trusted` (badge `trusted_badge`).
        const badge = r.badge;
        // Reply by token, never token 0: with `next_input` deferred there
        // can be several calls outstanding at once, and a token-0 reply
        // goes to the *oldest* pending one — it would answer a parked
        // reader with someone else's result.
        const token = r.token;
        const req = shared.decodeMsg(shared.GpuReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 1 } }, 0, token);
            continue;
        };
        switch (req) {
            .create_surface => |q| {
                const x = shared.unpackHi(q.xy);
                const y = shared.unpackLo(q.xy);
                // A zero size means the whole scanout at (0,0) — the
                // single-window case, so a client needn't know its size.
                const full = shared.unpackHi(q.wh) == 0 or shared.unpackLo(q.wh) == 0;
                const w: u32 = if (full) fb_w else shared.unpackHi(q.wh);
                const h: u32 = if (full) fb_h else shared.unpackLo(q.wh);
                const px_x: u32 = if (full) 0 else x;
                const px_y: u32 = if (full) 0 else y;
                if (@as(u64, px_x) + w > fb_w or @as(u64, px_y) + h > fb_h) {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 6 } }, 0, token);
                    continue;
                }
                if (createSurface(badge, px_x, px_y, w, h)) |cs| {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .created = .{ .surface = cs.id, .wh = shared.packPair(w, h) } }, cs.shm, token);
                } else {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 2 } }, 0, token);
                }
            },
            .commit => |q| {
                const sf = findSurface(q.surface) orelse {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 3 } }, 0, token);
                    continue;
                };
                // Only the owner touches its surface — a client cannot
                // commit (or destroy) another's, the login surface least of all.
                if (sf.owner != badge) {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 8 } }, 0, token);
                    continue;
                }
                // Recompose and ship only the damage rect (q.xy/q.wh, in
                // surface-local pixels; a zero size means the whole
                // surface). The very first commit lays the ground across
                // the whole scanout; later ones stay bounded to their
                // damage, which is the point.
                const ok = if (laid_ground) compositeRect(damageRect(sf, q.xy, q.wh)) else composite();
                _ = usys.replyTypedTo(shared.GpuResp, chan_h, if (ok) .ok else .{ .gpu_err = .{ .code = 5 } }, 0, token);
            },
            .destroy_surface => |q| {
                if (findSurface(q.surface)) |sf| {
                    if (sf.owner != badge) {
                        _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 8 } }, 0, token);
                        continue;
                    }
                    destroySurface(sf);
                    if (focused == q.surface) focusTopmost();
                    _ = composite(); // its space returns to the ground
                }
                _ = usys.replyTypedTo(shared.GpuResp, chan_h, .ok, 0, token);
            },
            .next_input => {
                if (keys_chan == 0 and ptr_chan == 0) {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 7 } }, 0, token);
                    continue;
                }
                // Park this read (deferred reply) and try to satisfy it
                // from the buffer — no reply now; it comes when a key for
                // the caller's focused surface arrives. The serve loop
                // stays free to handle every other client meanwhile.
                parkReader(badge, token);
                dispatchKeys(chan_h);
                dispatchPointer(chan_h);
            },
            .attach_trusted => |q| {
                // Prove the boot-provisioned token, earn a badged channel
                // whose surfaces are the login surface. A wrong or absent
                // token — or no trusted path at all — is refused.
                if (trust_token == 0 or q.token != trust_token) {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 10 } }, 0, token);
                    continue;
                }
                const minted = usys.chanMint(chan_h, trusted_badge);
                if (minted.err != .ok) {
                    _ = usys.replyTypedTo(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 11 } }, 0, token);
                    continue;
                }
                _ = usys.replyTypedTo(shared.GpuResp, chan_h, .trusted, minted.data[1], token);
            },
        }
    }
}

// ------------------------------------------------------------- driver

fn gpudrv(log_h: u64, chan_h: u64) noreturn {
    const n = usys.notifyCreate();
    if (n.err != .ok) usys.exit(170);
    irq_notif = n.data[0];

    dev = virtio.Dev.open(dev_h, .gpu) orelse {
        _ = usys.log(log_h, "gpusvc: the device handed to us is not a virtio-gpu");
        usys.exit(172);
    };
    if (usys.irqBind(dev_h, irq_notif, 0) != .ok) usys.exit(173);
    // NB: do NOT notifyBind the device IRQ to this thread's recv. gpusvc
    // waits on the IRQ directly (notifyWait in submitCmd); it never serves
    // the device from recv. Binding it would let a virtio-gpu interrupt
    // that arrives while we are blocked in recv (between surface requests)
    // wake recv with `interrupted` — and since the serve loop just retries,
    // a still-latched bit spins it forever (a livelock that starves the
    // core). irqBind alone routes the IRQ to the notification for notifyWait.

    // DMA: page 0 = control virtqueue; page 1 = command buffer (0..2048)
    // and response buffer (2048..4096).
    const dma = usys.dmaAlloc(2);
    if (dma.err != .ok) usys.exit(174);
    vq_va = dma.data[0];
    vq_dev = dma.data[1];
    cmd_va = dma.data[0] + 4096;
    cmd_dev = dma.data[1] + 4096;
    resp_va = cmd_va + 2048;
    resp_dev = cmd_dev + 2048;

    // The framebuffer backing, in dma_alloc-sized chunks.
    var remaining: u64 = fb_pages;
    var start: u64 = 0;
    for (0..n_chunks) |i| {
        const pages = @min(remaining, chunk_pages);
        const d = usys.dmaAlloc(pages);
        if (d.err != .ok) usys.exit(174);
        fb_va[i] = d.data[0];
        fb_dev[i] = d.data[1];
        fb_chunk_pages[i] = pages;
        fb_chunk_start[i] = start;
        start += @as(u64, pages) * 4096;
        remaining -= pages;
    }

    _ = dev.negotiate(0, 0) orelse usys.exit(176);
    if (!dev.queueSetup(q_ctl, q_num, vq_dev, vq_dev + 512, vq_dev + 1024)) usys.exit(177);
    dev.driverOk();

    if (submitCmd(cmdDisplayInfo(), 1024) != resp_ok_display_info) {
        _ = usys.log(log_h, "gpusvc: GET_DISPLAY_INFO refused");
        usys.exit(180);
    }
    if (submitCmd(cmdCreate2d(), 64) != resp_ok_nodata) usys.exit(181);
    if (submitCmd(cmdAttachBacking(), 64) != resp_ok_nodata) usys.exit(182);
    fillFb();
    if (submitCmd(cmdSetScanout(), 64) != resp_ok_nodata) usys.exit(183);
    if (submitCmd(cmdTransfer(0, 0, fb_w, fb_h), 64) != resp_ok_nodata) usys.exit(184);
    if (submitCmd(cmdFlush(0, 0, fb_w, fb_h), 64) != resp_ok_nodata) usys.exit(185);

    if (!readbackOk()) {
        _ = usys.log(log_h, "gpusvc: framebuffer readback mismatch");
        usys.exit(186);
    }
    _ = usys.log(log_h, "gpu: scanout up");

    // If the seat gave us a keyboard and/or a pointer, take them — input
    // routes to the surface with focus / under the cursor (the compositor
    // owns both). A reader thread per device does the blocking reads and
    // rings one shared doorbell bound to our recv, so the serve loop never
    // blocks on input and many clients can read at once.
    if (keys_chan != 0 or ptr_chan != 0) {
        const kb = usys.notifyCreate();
        if (kb.err != .ok) usys.exit(187);
        key_bell = kb.data[0];
        if (usys.notifyBind(key_bell) != .ok) usys.exit(189);
        if (keys_chan != 0) {
            setupKeyboard();
            if (usys.threadCreate(keyReader, 0, &key_reader_stack) != .ok) usys.exit(188);
        }
        if (ptr_chan != 0) {
            if (usys.threadCreate(ptrReader, 0, &ptr_reader_stack) != .ok) usys.exit(190);
        }
    }

    // Now serve the surface protocol: clients create a surface, commit
    // damage rects (we composite), and read input for the focused surface.
    serveSurfaces(chan_h);
}
