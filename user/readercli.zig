//! The concurrent-input drill's two clients, chosen by arg.
//!
//! arg 0, the reader: opens a window and blocks in `next_input`. On the
//! old synchronous compositor this single pending read froze the whole
//! display server; here it is a parked deferred reply that holds nothing
//! up.
//!
//! arg 1, the mover: opens a window and commits it in a loop, logging a
//! tick each time, then exits. Because it shares the compositor with the
//! reader, its commits only keep getting served if the reader's pending
//! read does NOT block the serve loop — so the mover reaching "done"
//! while the reader sits in next_input is the proof that reads are
//! concurrent. The mover is the essential unit: when it finishes, the
//! boot ends (on the old model it would instead hang, the reader having
//! wedged the compositor).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("readercli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const reader_colour: u32 = 0x00CC_2222; // red
const mover_colour: u32 = 0x0022_CC22; // green

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
    _ = commit(surface, w, h);
    return surface;
}

fn commit(surface: u64, w: u32, h: u32) bool {
    return switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .{ .commit = .{ .surface = surface, .xy = 0, .wh = shared.packPair(w, h) } }, 0)) {
        .ok => true,
        .err => false,
    };
}

fn reader(log_h: u64) noreturn {
    const s = window(300, 150, 200, 150, reader_colour);
    if (s == 0) usys.exit(180);
    _ = usys.log(log_h, "reader: ready");
    // Park a read. It may never be answered (nothing types a key to us) —
    // the point is only that waiting here holds nothing else up. Skip the
    // non-key events the compositor also delivers (a focus change is
    // kind 4): they must not be mistaken for the keystroke that never comes.
    while (true) {
        switch (usys.callTyped(shared.GpuReq, shared.GpuResp, disp, .next_input, 0)) {
            .ok => |rep| switch (rep) {
                .input => |x| if (x.kind == 0) {
                    _ = usys.log(log_h, "reader: got a key");
                    break;
                },
                else => break,
            },
            .err => break,
        }
    }
    usys.sleepMs(1000);
    usys.exit(0);
}

fn mover(log_h: u64) noreturn {
    const s = window(60, 150, 200, 150, mover_colour);
    if (s == 0) usys.exit(181);
    _ = usys.log(log_h, "mover: ready");
    // Commit in a loop. Each tick means the compositor served us — which,
    // while the reader sits in next_input, can only happen if that read
    // does not block the serve loop.
    var l: [32]u8 = undefined;
    var i: u64 = 1;
    while (i <= 20) : (i += 1) {
        _ = commit(s, 200, 150);
        _ = usys.log(log_h, std.fmt.bufPrint(&l, "mover: tick {d}", .{i}) catch "mover: tick");
        usys.sleepMs(60);
    }
    _ = usys.log(log_h, "mover: done");
    usys.exit(0);
}

export fn umain(log_h: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    if (disp == 0) {
        _ = usys.log(log_h, "readercli: no display channel");
        usys.exit(169);
    }
    if (arg == 0) reader(log_h) else mover(log_h);
}
