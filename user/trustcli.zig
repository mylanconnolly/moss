//! The trusted-path drill's two clients, chosen by arg.
//!
//! arg 0, the login greeter: it holds the boot-provisioned trust token,
//! so `attach_trusted` earns it a badged channel; a surface made over
//! that channel is the login surface. It takes and keeps focus (a
//! hostile client cannot steal it), the compositor paints the secure
//! strip along the top, and the keystroke the host types reaches the
//! greeter alone. It logs the verdict.
//!
//! arg 1, a hostile client: it has NO token, so its `attach_trusted` is
//! refused. It opens an ordinary window and repeatedly tries to read the
//! keyboard while the login surface is focused — every read is refused,
//! so the passphrase never leaks to it. If a keystroke ever did, it
//! shouts "trust: LEAK".

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("trustcli"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const login_colour: u32 = 0x00E0_E0E0; // a pale login field
const fake_colour: u32 = 0x00CC_2222; // the hostile window, red

var glog: u64 = 0;
var disp: u64 = 0; // the shared display channel

/// Open a window of size w×h at (x,y) over `chan`, fill it, commit it.
/// Returns the surface id, or 0 on any refusal.
fn window(chan: u64, x: u32, y: u32, w: u32, h: u32, colour: u32) u64 {
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, chan, .{ .create_surface = .{ .xy = shared.packPair(x, y), .wh = shared.packPair(w, h) } }, 0)) {
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
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .{ .commit = .{ .surface = surface, .xy = 0, .wh = shared.packPair(w, h) } }, 0);
    return surface;
}

/// One keystroke, or 0 if the compositor refused this reader (not the
/// owner of the focused surface). `leaked` is set true only if a real
/// character came back to a reader that should never have received one.
fn readKey(chan: u64, leaked: *bool) u8 {
    switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, .next_input, 0)) {
        .ok => |rep| switch (rep) {
            .input => |x| {
                // Only a keystroke (kind 0) counts; the compositor also
                // delivers focus changes (kind 4) on this channel, whose
                // arg must not be mistaken for a leaked character.
                if (x.kind != 0) return 0;
                const ch: u8 = @intCast(x.arg & 0xff);
                if (ch != 0) leaked.* = true;
                return ch;
            },
            else => return 0,
        },
        .err => return 0,
    }
}

fn greeter(log_h: u64) noreturn {
    // Prove the token (read from our boot secret in umain); earn the
    // badged channel that makes the login surface.
    const at = usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .attach_trusted = .{ .token = trust_tok } }, 0);
    const tchan = switch (at) {
        .ok => |ok| switch (ok.rep) {
            .trusted => ok.cap,
            else => {
                _ = usys.log(log_h, "trust: greeter attach refused");
                usys.exit(180);
            },
        },
        .err => {
            _ = usys.log(log_h, "trust: greeter attach error");
            usys.exit(181);
        },
    };
    if (tchan == 0) usys.exit(182);

    // The login surface, over the trusted channel: it takes focus, so the
    // secure strip lights up and the keyboard is routed here.
    const s = window(tchan, 170, 180, 300, 120, login_colour);
    if (s == 0) usys.exit(183);
    _ = usys.log(log_h, "trust: attached");

    // The passphrase key the host types must reach the greeter.
    var leaked = false;
    const ch = readKey(tchan, &leaked);
    if (ch == 0) {
        _ = usys.log(log_h, "trust: greeter got no key");
        usys.exit(184);
    }
    var l: [48]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&l, "trust: got {c}", .{ch}) catch "trust: got");
    _ = usys.log(log_h, "trust: ok");
    // Stay up while the hostile client finishes its refused reads (the
    // compositor serves them only after we stop blocking on the keyboard),
    // so the drill can confirm the refusals before the boot shuts down.
    usys.sleepMs(3000);
    usys.exit(0);
}

fn fake(log_h: u64) noreturn {
    // No token: the trusted path must refuse us.
    switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, disp, .{ .attach_trusted = .{ .token = 0xdead_beef } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .trusted => {
                _ = usys.log(log_h, "trust: FAKE ATTACHED");
                usys.exit(190);
            },
            else => _ = usys.log(log_h, "trust: fake refused"),
        },
        .err => _ = usys.log(log_h, "trust: fake refused"),
    }

    // An ordinary window (base channel): it cannot steal focus from the
    // login surface, and its reads of the keyboard are refused.
    _ = window(disp, 60, 180, 240, 120, fake_colour);

    var leaked = false;
    var tries: u64 = 0;
    while (tries < 20) : (tries += 1) {
        const ch = readKey(disp, &leaked);
        if (leaked) {
            var l: [48]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&l, "trust: LEAK {c}", .{ch}) catch "trust: LEAK");
            usys.exit(191);
        }
        usys.sleepMs(50);
    }
    _ = usys.log(log_h, "trust: fake blind");
    usys.sleepMs(5000);
    usys.exit(0);
}

var trust_tok: u64 = 0; // the greeter's boot-provisioned token, if any

export fn umain(log_h: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    disp = setup.cap(.display);
    glog = log_h;
    const sec = setup.secret();
    if (sec.len >= 8) trust_tok = std.mem.readInt(u64, sec[0..8], .little);
    if (disp == 0) {
        _ = usys.log(log_h, "trustcli: no display channel");
        usys.exit(169);
    }
    if (arg == 0) greeter(log_h) else fake(log_h);
}
