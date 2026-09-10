//! The focus drill's client: it opens two windows and then reads input
//! through the compositor, which routes each keystroke to the focused
//! window and cycles focus on Tab. The second window (green) is created
//! last, so it starts focused. The host types `a`, Tab, `b`: `a` should
//! reach the green window, then Tab moves focus to the red one, so `b`
//! reaches red. The client checks the routing and logs the verdict.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("focuscli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const red: u32 = 0x00CC_2222;
const green: u32 = 0x0022_CC22;

var disp: u64 = 0;

fn window(x: u32, y: u32, w: u32, h: u32, colour: u32) u64 {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .create_surface = .{ .xy = shared.packPair(x, y), .wh = shared.packPair(w, h) } }, 0)) {
        .ok => |ok| ok,
        .err => return 0,
    };
    const surface = switch (cs.rep) {
        .created => |c| c.surface,
        else => return 0,
    };
    if (cs.cap == 0) return 0;
    const m = usys.shmMap(cs.cap);
    if (m.err != .ok) return 0;
    const px: [*]volatile u32 = @ptrFromInt(m.data[0]);
    for (0..@as(usize, w) * h) |i| px[i] = colour;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{ .surface = surface, .xy = 0, .wh = shared.packPair(w, h) } }, 0);
    return surface;
}

const Input = struct { surface: u64, ch: u8 };
fn nextInput() Input {
    // Only keystrokes (kind 0) matter here; skip the non-key events the
    // compositor also delivers on this channel (a focus change is kind 4).
    while (true) {
        switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .next_input, 0)) {
            .ok => |rep| switch (rep) {
                .input => |x| if (x.kind == 0) return .{ .surface = x.surface, .ch = @intCast(x.arg & 0xff) },
                else => return .{ .surface = 0, .ch = 0 },
            },
            .err => return .{ .surface = 0, .ch = 0 },
        }
    }
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "focuscli: no display channel");
        usys.exit(169);
    }
    const a = window(40, 40, 300, 200, red); // red, left
    const b = window(200, 40, 300, 200, green); // green, right — created last, focused
    if (a == 0 or b == 0) usys.exit(180);
    _ = usys.log(log_h, "focus: ready");

    // The host types `a`, Tab, `b`. `a` -> focused (b); Tab cycles focus
    // to a; `b` -> a. (Tab is absorbed by the compositor, so two reads.)
    const in1 = nextInput();
    const in2 = nextInput();

    const ok = in1.surface == b and in1.ch == 'a' and in2.surface == a and in2.ch == 'b';
    if (ok) {
        _ = usys.log(log_h, "focus: ok");
    } else {
        var l: [96]u8 = undefined;
        _ = usys.log(log_h, std.fmt.bufPrint(&l, "focus: bad in1=(s{d},{c}) in2=(s{d},{c}) a={d} b={d}", .{ in1.surface, in1.ch, in2.surface, in2.ch, a, b }) catch "focus: bad");
    }
    usys.sleepMs(2000);
    usys.exit(0);
}
