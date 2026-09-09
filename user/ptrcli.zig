//! The pointer drill's client: it opens one window and then reads input
//! through the compositor. The host moves the absolute cursor over the
//! window and clicks; the compositor hit-tests the surface under the
//! cursor and routes a pointer event (kind 1) with surface-local
//! coordinates and the button bitmask. The client waits for the left
//! click on its surface and logs the verdict — proving the whole chain
//! tablet → inputsvc → compositor → hit-test → routed to the right client.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("ptrcli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// A distinct fill so the black-and-white cursor stands out over it in a
// screendump.
const fill: u32 = 0x0000_4488;

const win_x = 200;
const win_y = 150;
const win_w = 300;
const win_h = 200;

var disp: u64 = 0;

const Input = struct { surface: u64, kind: u64, x: u64, y: u64, btn: u64 };
fn nextInput() Input {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .next_input, 0)) {
        .ok => |rep| switch (rep) {
            .input => |v| .{ .surface = v.surface, .kind = v.kind, .x = shared.ptrX(v.arg), .y = shared.ptrY(v.arg), .btn = shared.ptrBtn(v.arg) },
            else => .{ .surface = 0, .kind = 0, .x = 0, .y = 0, .btn = 0 },
        },
        .err => .{ .surface = 0, .kind = 0, .x = 0, .y = 0, .btn = 0 },
    };
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "ptrcli: no display channel");
        usys.exit(169);
    }
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = shared.packPair(win_x, win_y), .wh = shared.packPair(win_w, win_h) } }, 0)) {
        .ok => |ok| ok,
        .err => usys.exit(170),
    };
    const surface = switch (cs.rep) {
        .created => |c| c.surface,
        else => usys.exit(171),
    };
    if (cs.cap == 0) usys.exit(172);
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) usys.exit(173);
    const px: [*]volatile u32 = @ptrFromInt(m.data[0]);
    for (0..@as(usize, win_w) * win_h) |i| px[i] = fill;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{ .surface = surface, .xy = 0, .wh = shared.packPair(win_w, win_h) } }, 0);
    _ = usys.log(log_h, "pointer: ready");

    // Read input until a left-button press lands on our surface.
    var tries: u64 = 0;
    while (tries < 64) : (tries += 1) {
        const in = nextInput();
        if (in.surface == 0 and in.kind == 0 and in.btn == 0) {
            // A closed channel (all-zero) — give up.
            usys.exit(180);
        }
        if (in.kind == 1 and in.btn & 1 != 0) {
            var l: [96]u8 = undefined;
            const ok = in.surface == surface;
            const s = std.fmt.bufPrint(&l, "pointer: {s} sid={d} x={d} y={d}", .{ if (ok) "click" else "wrong-surface", in.surface, in.x, in.y }) catch "pointer: click";
            _ = usys.log(log_h, s);
            if (ok) break;
        }
    }
    usys.sleepMs(2000);
    usys.exit(0);
}
