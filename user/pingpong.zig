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
        \\        .ascii  "pingpong"
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
        1 => calc(log_h, chan_h),
        2 => askr(log_h, chan_h),
        3 => crasher(log_h),
        else => usys.exit(250),
    }
}

fn calc(log_h: u64, chan_h: u64) noreturn {
    var served: u64 = 0;
    var buf: [96]u8 = undefined;
    // Adversarial vector state: calc stamps ITS pattern into v0-v31
    // before every blocking recv, so a missing FP restore on askr's side
    // would hand askr these bytes instead of its own.
    var stamp: [512]u8 align(16) = undefined;
    for (&stamp, 0..) |*c, k| c.* = @truncate(k *% 0x3D +% 0x5C);
    while (true) {
        fpLoad(&stamp);
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

    // RPC until the peer dies under us. Each round also proves the
    // kernel's FP/SIMD context switching: fill all 32 vector registers
    // with a per-process pattern, sleep through a context switch (calc —
    // another FP-dirtying user thread — runs meanwhile), and verify every
    // register survived bit-exact.
    var pattern: [512]u8 align(16) = undefined;
    var readback: [512]u8 align(16) = undefined;
    for (&pattern, 0..) |*c, k| c.* = @truncate(k *% 0xA5 +% 7);
    var fp_rounds: u64 = 0;

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
                    _ = usys.log(log_h, lineNum(&buf, "askr: fp/simd state survived switches: ", fp_rounds));
                    if (fp_rounds == 0) usys.exit(41);
                    usys.exit(7);
                }
                usys.exit(8);
            },
        }
        fpLoad(&pattern);
        usys.sleep(3);
        fpStore(&readback);
        for (pattern, readback) |a, b| {
            if (a != b) usys.exit(40); // vector state corrupted across a switch
        }
        fp_rounds += 1;
    }
}

/// Load v0-v31 from a 512-byte buffer / store them back — the probe for
/// eager FP context switching. No Zig code runs between load, syscall,
/// and store, so the registers' only guardian is the kernel.
inline fn fpLoad(p: *const [512]u8) void {
    asm volatile (
        \\ldp q0, q1, [%[p], #0]
        \\ldp q2, q3, [%[p], #32]
        \\ldp q4, q5, [%[p], #64]
        \\ldp q6, q7, [%[p], #96]
        \\ldp q8, q9, [%[p], #128]
        \\ldp q10, q11, [%[p], #160]
        \\ldp q12, q13, [%[p], #192]
        \\ldp q14, q15, [%[p], #224]
        \\ldp q16, q17, [%[p], #256]
        \\ldp q18, q19, [%[p], #288]
        \\ldp q20, q21, [%[p], #320]
        \\ldp q22, q23, [%[p], #352]
        \\ldp q24, q25, [%[p], #384]
        \\ldp q26, q27, [%[p], #416]
        \\ldp q28, q29, [%[p], #448]
        \\ldp q30, q31, [%[p], #480]
        :
        : [p] "r" (p),
        : .{ .v0 = true, .v1 = true, .v2 = true, .v3 = true, .v4 = true, .v5 = true, .v6 = true, .v7 = true, .v8 = true, .v9 = true, .v10 = true, .v11 = true, .v12 = true, .v13 = true, .v14 = true, .v15 = true, .v16 = true, .v17 = true, .v18 = true, .v19 = true, .v20 = true, .v21 = true, .v22 = true, .v23 = true, .v24 = true, .v25 = true, .v26 = true, .v27 = true, .v28 = true, .v29 = true, .v30 = true, .v31 = true });
}

inline fn fpStore(p: *[512]u8) void {
    asm volatile (
        \\stp q0, q1, [%[p], #0]
        \\stp q2, q3, [%[p], #32]
        \\stp q4, q5, [%[p], #64]
        \\stp q6, q7, [%[p], #96]
        \\stp q8, q9, [%[p], #128]
        \\stp q10, q11, [%[p], #160]
        \\stp q12, q13, [%[p], #192]
        \\stp q14, q15, [%[p], #224]
        \\stp q16, q17, [%[p], #256]
        \\stp q18, q19, [%[p], #288]
        \\stp q20, q21, [%[p], #320]
        \\stp q22, q23, [%[p], #352]
        \\stp q24, q25, [%[p], #384]
        \\stp q26, q27, [%[p], #416]
        \\stp q28, q29, [%[p], #448]
        \\stp q30, q31, [%[p], #480]
        :
        : [p] "r" (p),
        : .{ .memory = true });
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
