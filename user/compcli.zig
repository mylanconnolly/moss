//! The compositor drill's client: it opens two windowed surfaces at
//! different positions in different colours, overlapping, so the display
//! server has to composite them — each in its place, the later (top) one
//! winning where they overlap, the ground showing between them. The host
//! screendumps and checks a pixel in each region.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("compcli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// B8G8R8X8 words (a screendump reads them back as RGB).
const red: u32 = 0x00CC_2222; // RGB(0xCC,0x22,0x22)
const green: u32 = 0x0022_CC22; // RGB(0x22,0xCC,0x22)

var disp: u64 = 0;

/// Create a w x h surface at (x,y), fill it with `colour`, and commit it.
fn window(x: u32, y: u32, w: u32, h: u32, colour: u32) bool {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = shared.packPair(x, y), .wh = shared.packPair(w, h) } }, 0)) {
        .ok => |ok| ok,
        .err => return false,
    };
    const surface = switch (cs.rep) {
        .created => |c| c.surface,
        else => return false,
    };
    if (cs.cap == 0) return false;
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) return false;
    const px: [*]volatile u32 = @ptrFromInt(m.data[0]);
    for (0..@as(usize, w) * h) |i| px[i] = colour;
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{ .surface = surface, .xy = 0, .wh = shared.packPair(w, h) } }, 0)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "compcli: no display channel");
        usys.exit(169);
    }
    // Two overlapping windows; the second (green) stacks over the first
    // (red) where they meet.
    if (!window(40, 40, 300, 200, red)) usys.exit(180);
    if (!window(200, 150, 300, 200, green)) usys.exit(181);
    _ = usys.log(log_h, "comp: surfaces up");
    usys.sleepMs(4000); // hold for the host's screendump
    usys.exit(0);
}
