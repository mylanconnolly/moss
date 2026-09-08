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
//! The framebuffer (640x480x4 = 300 pages) is larger than dma_alloc's
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
    gpudrv(log_h, chan_h);
}

// ------------------------------------------------------------ constants

const desc_f_next = 1;
const desc_f_write = 2;

const fb_w = 640;
const fb_h = 480;
const fb_bpp = 4;
const fb_stride = fb_w * fb_bpp;
const fb_bytes = fb_stride * fb_h; // 1,228,800
const fb_pages = fb_bytes / 4096; // 300
const chunk_pages = 16; // dma_alloc's per-call cap
const n_chunks = (fb_pages + chunk_pages - 1) / chunk_pages; // 19

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
};
var surfaces: [max_surfaces]Surface = @splat(.{});
var next_z: u32 = 1;
/// The compositor's ground, seen wherever no surface covers the scanout.
const bg_word: u32 = 0x0020_2830; // a dark slate

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
fn cmdTransfer() usize {
    hdr(cmd_transfer_to_host_2d);
    rect(24, 0, 0, fb_w, fb_h);
    wr64(40, 0); // offset into the resource
    wr32(48, res_id);
    wr32(52, 0); // padding
    return 56;
}
fn cmdFlush() usize {
    hdr(cmd_resource_flush);
    rect(24, 0, 0, fb_w, fb_h);
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
fn transferAndFlush() bool {
    if (submitCmd(cmdTransfer(), 64) != resp_ok_nodata) return false;
    if (submitCmd(cmdFlush(), 64) != resp_ok_nodata) return false;
    return true;
}

// -------------------------------------------------------- surfaces

fn findSurface(id: u64) ?*Surface {
    if (id == 0 or id > max_surfaces) return null;
    const sf = &surfaces[id - 1];
    return if (sf.used) sf else null;
}

/// A surface at (x, y) of size w x h: a fresh shm both we and the client
/// map — the client draws into it, we read it when compositing. It stacks
/// above every existing surface. Returns the surface id and the cap.
fn createSurface(x: u32, y: u32, w: u32, h: u32) ?struct { id: u64, shm: u64 } {
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
    surfaces[idx] = .{ .used = true, .shm = s.data[0], .va = m.data[0], .len = m.data[1] * 4096, .x = x, .y = y, .w = w, .h = h, .z = next_z };
    next_z += 1;
    return .{ .id = idx + 1, .shm = s.data[0] };
}

fn destroySurface(sf: *Surface) void {
    if (sf.va != 0) _ = usys.shmUnmap(sf.va);
    if (sf.shm != 0) _ = usys.capDrop(sf.shm);
    sf.* = .{};
}

/// Blit one surface onto the framebuffer at its position, clipped to the
/// scanout. The surface is contiguous (w*bpp per row); the framebuffer is
/// the scatter-gather chunks, so each row goes through fbWrite.
fn blit(sf: *const Surface) void {
    const src: [*]const u8 = @ptrFromInt(sf.va);
    var ry: usize = 0;
    while (ry < sf.h) : (ry += 1) {
        const sy = @as(usize, sf.y) + ry;
        if (sy >= fb_h) break;
        var cols: usize = sf.w;
        if (@as(usize, sf.x) + cols > fb_w) cols = fb_w - @as(usize, sf.x);
        const dst_off = sy * fb_stride + @as(usize, sf.x) * fb_bpp;
        const src_off = ry * @as(usize, sf.w) * fb_bpp;
        fbWrite(dst_off, src + src_off, cols * fb_bpp);
    }
}

/// Recompose the scanout: paint the ground, then every surface bottom to
/// top, then ship it to the host. Full recompose per commit — simple and
/// correct; per-rect composition is a later optimisation.
fn composite() bool {
    // Ground.
    for (0..n_chunks) |i| {
        const words = fb_chunk_pages[i] * 4096 / 4;
        const p: [*]volatile u32 = @ptrFromInt(fb_va[i]);
        var j: usize = 0;
        while (j < words) : (j += 1) p[j] = bg_word;
    }
    // Surfaces, painters' order (lowest z first).
    var painted: u32 = 0;
    while (true) {
        var next: ?*Surface = null;
        for (&surfaces) |*sf| {
            if (!sf.used or sf.z <= painted) continue;
            if (next == null or sf.z < next.?.z) next = sf;
        }
        const sf = next orelse break;
        blit(sf);
        painted = sf.z;
    }
    return transferAndFlush();
}

/// Serve the surface protocol on the boot channel (which is also the
/// service channel, like the console driver): create_surface hands back
/// a pixel buffer, commit copies its damage rect into the scanout and
/// flushes. Runs until the last client end closes.
fn serveSurfaces(chan_h: u64) noreturn {
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(shared.GpuReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 1 } }, 0);
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
                    _ = usys.replyTyped(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 6 } }, 0);
                    continue;
                }
                if (createSurface(px_x, px_y, w, h)) |cs| {
                    _ = usys.replyTyped(shared.GpuResp, chan_h, .{ .created = .{ .surface = cs.id, .wh = shared.packPair(w, h) } }, cs.shm);
                } else {
                    _ = usys.replyTyped(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 2 } }, 0);
                }
            },
            .commit => |q| {
                _ = findSurface(q.surface) orelse {
                    _ = usys.replyTyped(shared.GpuResp, chan_h, .{ .gpu_err = .{ .code = 3 } }, 0);
                    continue;
                };
                // The damage rect (q.xy/q.wh) is advisory for now; recompose
                // the whole scanout so overlapping surfaces stay correct.
                const ok = composite();
                _ = usys.replyTyped(shared.GpuResp, chan_h, if (ok) .ok else .{ .gpu_err = .{ .code = 5 } }, 0);
            },
            .destroy_surface => |q| {
                if (findSurface(q.surface)) |sf| {
                    destroySurface(sf);
                    _ = composite(); // its space returns to the ground
                }
                _ = usys.replyTyped(shared.GpuResp, chan_h, .ok, 0);
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
    if (submitCmd(cmdTransfer(), 64) != resp_ok_nodata) usys.exit(184);
    if (submitCmd(cmdFlush(), 64) != resp_ok_nodata) usys.exit(185);

    if (!readbackOk()) {
        _ = usys.log(log_h, "gpusvc: framebuffer readback mismatch");
        usys.exit(186);
    }
    _ = usys.log(log_h, "gpu: scanout up");

    // Now serve the surface protocol: clients create a surface and commit
    // damage rects, and we copy each into the scanout and flush it.
    serveSurfaces(chan_h);
}
