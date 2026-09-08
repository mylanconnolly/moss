//! The display drill's client: it drives gpusvc's surface protocol to
//! prove the seam end to end. It creates a fullscreen surface, maps the
//! pixel buffer gpusvc hands back, fills it with one colour and commits
//! the whole rect, then paints a smaller centred rectangle in a second
//! colour and commits only that damage rect. The host screendumps the
//! result and checks a pixel inside the small rect is the second colour
//! and one outside it is the first — proving the surface path, a full
//! commit, and a partial damage-rect commit (whose copy walks the
//! framebuffer's scatter-gather chunks).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("gpucli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// B8G8R8X8 words (byte order B,G,R,X): a screendump reads them as RGB.
const colour_a: u32 = 0x0022_4466; // RGB(0x22,0x44,0x66)
const colour_b: u32 = 0x00CC_8822; // RGB(0xCC,0x88,0x22)

const bpp = 4;

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    const disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "gpucli: no display channel");
        usys.exit(169);
    }

    // Create a fullscreen surface; gpusvc replies with its size and a
    // cap to the pixel buffer we draw into.
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = 0, .wh = 0 } }, 0)) {
        .ok => |ok| ok,
        .err => {
            _ = usys.log(log_h, "gpucli: create_surface failed");
            usys.exit(180);
        },
    };
    const surface = switch (cs.rep) {
        .created => |c| c.surface,
        else => {
            _ = usys.log(log_h, "gpucli: create_surface refused");
            usys.exit(181);
        },
    };
    const w: usize = shared.unpackHi(cs.rep.created.wh);
    const h: usize = shared.unpackLo(cs.rep.created.wh);
    if (cs.cap == 0) {
        _ = usys.log(log_h, "gpucli: no surface buffer");
        usys.exit(182);
    }
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) {
        _ = usys.log(log_h, "gpucli: cannot map the surface");
        usys.exit(183);
    }
    const px: [*]volatile u32 = @ptrFromInt(m.data[0]);
    const stride = w; // pixels per row

    // Fill the whole surface with colour A and commit the full rect.
    for (0..w * h) |i| px[i] = colour_a;
    if (!commit(disp, surface, 0, 0, @intCast(w), @intCast(h))) {
        _ = usys.log(log_h, "gpucli: full commit failed");
        usys.exit(184);
    }

    // Paint a centred rectangle in colour B and commit only that rect.
    const rw: usize = 200;
    const rh: usize = 120;
    const rx: usize = (w - rw) / 2;
    const ry: usize = (h - rh) / 2;
    var yy: usize = 0;
    while (yy < rh) : (yy += 1) {
        var xx: usize = 0;
        while (xx < rw) : (xx += 1) px[(ry + yy) * stride + (rx + xx)] = colour_b;
    }
    if (!commit(disp, surface, @intCast(rx), @intCast(ry), @intCast(rw), @intCast(rh))) {
        _ = usys.log(log_h, "gpucli: rect commit failed");
        usys.exit(185);
    }

    _ = usys.log(log_h, "gpu: surface committed");
    // Hold the result up a moment for the host's screendump, then exit;
    // being the drill's essential unit, that ends the boot.
    usys.sleepMs(4000);
    usys.exit(0);
}

fn commit(disp: u64, surface: u64, x: u32, y: u32, w: u32, h: u32) bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{
        .surface = surface,
        .xy = shared.packPair(x, y),
        .wh = shared.packPair(w, h),
    } }, 0)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}
