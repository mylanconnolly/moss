//! Phase 5 service crowd, personality by x2:
//!   1 "logsvc"  — relays LogMsg text to the debug log; deliberately
//!                 crashes after every 4th message (crash-only discipline:
//!                 recovery is init's restart, not defensive coding here).
//!   2 "greeter" — serves CalcRequest.add (a stand-in for a real service).
//!   3 "worker"  — the dependent: connects to both services through init
//!                 (triggering lazy activation), works, survives logsvc's
//!                 crashes by observing peer_dead and re-wiring through
//!                 init, then exits 0.

const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (
        \\.section .text.uhdr, "ax"
        \\.global __uhdr
        \\__uhdr:
        \\        .ascii  "MOSS"
        \\        .word   0
        \\        .quad   __utext_size
        \\        .quad   __uload_size
        \\        .quad   __umem_size
        \\        .ascii  "services"
        \\        .space  8
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

export fn umain(log_h: u64, chan_h: u64, role: u64) callconv(.c) noreturn {
    switch (role) {
        1 => logsvc(log_h, chan_h),
        2 => greeter(log_h, chan_h),
        3 => worker(log_h, chan_h),
        4 => flapper(log_h),
        5 => guestHello(log_h, chan_h),
        else => usys.exit(250),
    }
}

/// The guest profile's one program: proof that a whole moss userspace —
/// root, init, unit files, capabilities — runs inside a VM.
fn guestHello(log_h: u64, chan_h: u64) noreturn {
    _ = boot.take(chan_h);
    _ = usys.log(log_h, "guest-hello: hello from EL0, inside a moss guest of moss");
    usys.exit(0);
}

/// The drill's subject: dies on arrival, every single time.
fn flapper(log_h: u64) noreturn {
    _ = usys.log(log_h, "flapper: born; crashing immediately");
    usys.exit(1);
}

const crash_every = 4;

fn logsvc(log_h: u64, chan_h: u64) noreturn {
    _ = boot.take(chan_h); // a unit: init hands us nothing, but says go
    _ = usys.log(log_h, "logsvc: serving");
    var relayed: u64 = 0;
    var buf: [24]u8 = undefined;
    var line: [64]u8 = undefined;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(120);
        const msg = shared.decodeMsg(shared.LogMsg, r.data) orelse continue;
        switch (msg) {
            .text => |t| {
                relayed += 1;
                if (relayed % crash_every == 0) {
                    // Crash mid-request, before replying: the client's
                    // in-flight call must observe peer_dead.
                    _ = usys.log(log_h, "logsvc: simulating a crash (no reply sent)");
                    @as(*volatile u64, @ptrFromInt(0x10)).* = 1;
                }
                const text = shared.wordsToStr(&buf, .{ t.a, t.b, t.c });
                _ = usys.log(log_h, cat(&line, "logsvc relay: ", text));
                _ = usys.replyTyped(shared.LogReply, chan_h, .ok, 0);
            },
        }
    }
}

fn greeter(log_h: u64, chan_h: u64) noreturn {
    _ = boot.take(chan_h);
    _ = usys.log(log_h, "greeter: serving");
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(121);
        const req = shared.decodeMsg(shared.CalcRequest, r.data) orelse continue;
        switch (req) {
            .add => |a| _ = usys.replyTyped(shared.CalcReply, chan_h, .{
                .sum = .{ .value = a.a + a.b },
            }, 0),
            .greet => _ = usys.replyTyped(shared.CalcReply, chan_h, .hi, 0),
        }
    }
}

fn worker(log_h: u64, init_b: u64) noreturn {
    var line: [64]u8 = undefined;

    var log_chan = connect(log_h, init_b, .logsvc); // lazy start #1
    const greet_chan = connect(log_h, init_b, .greeter); // lazy start #2

    var sent: u64 = 0;
    var rewires: u64 = 0;
    while (sent < 10) {
        const text = numLine(&line, "worker msg ", sent);
        const w = shared.strToWords(text);
        switch (usys.callTyped(shared.LogMsg, shared.LogReply, log_chan, .{
            .text = .{ .a = w[0], .b = w[1], .c = w[2] },
        }, 0)) {
            .ok => {
                sent += 1;
                usys.sleep(1);
            },
            .err => |e| {
                if (e != .peer_dead) usys.exit(130);
                rewires += 1;
                _ = usys.log(log_h, "worker: logsvc died mid-call; re-wiring through init");
                _ = usys.capDrop(log_chan);
                log_chan = connect(log_h, init_b, .logsvc);
                // The message never got its reply; send it again.
            },
        }
    }

    // The other dependency kept working throughout.
    switch (usys.callTyped(shared.CalcRequest, shared.CalcReply, greet_chan, .{
        .add = .{ .a = sent, .b = rewires },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .sum => |v| _ = usys.log(log_h, numLine(&line, "worker: greeter sums msgs+rewires to ", v.value)),
            .hi => {},
        },
        .err => usys.exit(131),
    }

    if (rewires < 2) usys.exit(132); // the demo demands at least two crashes
    _ = usys.log(log_h, "worker: all messages delivered despite crashes; done");
    usys.exit(0);
}

fn connect(log_h: u64, init_b: u64, service: shared.ServiceId) u64 {
    switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_b, .{
        .connect = .{ .service = @intFromEnum(service) },
    }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .connected => {
                if (ok.cap == 0) usys.exit(133);
                return ok.cap;
            },
            else => usys.exit(134),
        },
        .err => usys.exit(135),
    }
    _ = log_h;
    unreachable;
}

fn cat(buf: []u8, prefix: []const u8, s: []const u8) []const u8 {
    var i: usize = 0;
    for (prefix) |c| {
        buf[i] = c;
        i += 1;
    }
    for (s) |c| {
        if (i == buf.len) break;
        buf[i] = c;
        i += 1;
    }
    return buf[0..i];
}

fn numLine(buf: []u8, prefix: []const u8, n: u64) []const u8 {
    var i: usize = 0;
    for (prefix) |c| {
        buf[i] = c;
        i += 1;
    }
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var v = n;
    while (true) {
        digits[d] = '0' + @as(u8, @intCast(v % 10));
        d += 1;
        v /= 10;
        if (v == 0) break;
    }
    while (d > 0) {
        d -= 1;
        buf[i] = digits[d];
        i += 1;
    }
    return buf[0..i];
}
