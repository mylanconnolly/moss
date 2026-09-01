//! Phase 4 IPC demo, three personalities picked by x2:
//!   1 "calc"    — serves CalcRequest on its channel end until the client
//!                 side dies (recv returns peer_dead), then exits 0.
//!   2 "askr"    — greets calc with a shared-memory buffer + notification
//!                 cap, then RPCs add-requests until calc dies mid-call;
//!                 handles peer_dead, proves it can carry on, exits 7.
//!   3 "crasher" — dereferences an unmapped address; the fault becomes a
//!                 message to the supervisor channel.
//!
//! Everything speaks through the typed stubs in usys/shared — the same
//! protocol types the kernel test driver decodes.

const shared = @import("shared");
const usys = @import("usys.zig");

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
        1 => calc(log_h, chan_h),
        2 => askr(log_h, chan_h),
        3 => crasher(log_h),
        else => usys.exit(250),
    }
}

fn calc(log_h: u64, chan_h: u64) noreturn {
    var served: u64 = 0;
    var buf: [96]u8 = undefined;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) {
            _ = usys.log(log_h, "calc: client side is gone; served enough, exiting");
            usys.exit(0);
        }
        if (r.err != .ok) usys.exit(3);
        const req = shared.decodeMsg(shared.CalcRequest, r.data) orelse {
            _ = usys.replyTyped(shared.CalcReply, chan_h, .hi, 0);
            continue;
        };
        switch (req) {
            .greet => {
                // The greeting carries an shm cap: map it and read the note.
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        const p: [*]const u8 = @ptrFromInt(m.data[0]);
                        var n: usize = 0;
                        while (n < 64 and p[n] != 0) n += 1;
                        _ = usys.log(log_h, lineCat(&buf, "calc: shared page says: ", p[0..n]));
                    }
                }
                _ = usys.replyTyped(shared.CalcReply, chan_h, .hi, 0);
            },
            .add => |a| {
                served += 1;
                _ = usys.replyTyped(shared.CalcReply, chan_h, .{
                    .sum = .{ .value = a.a + a.b },
                }, 0);
            },
        }
    }
}

fn askr(log_h: u64, chan_h: u64) noreturn {
    var buf: [96]u8 = undefined;

    // Out-of-line hello: write a note into shared memory and grant the cap.
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(4);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(5);
    const page: [*]u8 = @ptrFromInt(m.data[0]);
    const note = "hi calc, this buffer crossed a channel";
    for (note, 0..) |c, i| page[i] = c;
    page[note.len] = 0;

    switch (usys.callTyped(shared.CalcRequest, shared.CalcReply, chan_h, .greet, s.data[0])) {
        .ok => _ = usys.log(log_h, "askr: greeted calc, buffer granted"),
        .err => usys.exit(6),
    }

    // RPC until the peer dies under us.
    var i: u64 = 0;
    while (true) : (i += 1) {
        switch (usys.callTyped(shared.CalcRequest, shared.CalcReply, chan_h, .{
            .add = .{ .a = i, .b = 100 },
        }, 0)) {
            .ok => |rep| switch (rep) {
                .sum => |v| _ = usys.log(log_h, lineNum(&buf, "askr: calc says ", v.value)),
                .hi => {},
            },
            .err => |e| {
                if (e == .peer_dead) {
                    _ = usys.log(log_h, "askr: peer died mid-call (peer_dead); carrying on alone");
                    _ = usys.log(log_h, lineNum(&buf, "askr: local fallback 2+2=", 4));
                    usys.exit(7);
                }
                usys.exit(8);
            },
        }
        usys.sleep(3);
    }
}

fn crasher(log_h: u64) noreturn {
    _ = usys.log(log_h, "crasher: touching unmapped memory on purpose");
    @as(*volatile u64, @ptrFromInt(0x8)).* = 1;
    usys.exit(9); // never reached
}

fn lineNum(buf: []u8, prefix: []const u8, n: u64) []const u8 {
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

fn lineCat(buf: []u8, prefix: []const u8, s: []const u8) []const u8 {
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
