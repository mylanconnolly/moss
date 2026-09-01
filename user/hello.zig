//! The first user program. Runs one of two personalities depending on what
//! its manifest granted (the kernel passes the debug-log handle in x0, or 0):
//!
//! - with the cap: greet, then log a tick forever — until revoked.
//! - without ("sneaky"): try to log anyway, then try a forged handle; both
//!   must fail, and the exit code reports what happened (42 = all denied).

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

export fn umain(log_handle: u64) callconv(.c) noreturn {
    if (log_handle == 0) {
        sneaky();
    }

    _ = usys.log(log_handle, "hello from EL0, capability in hand");
    var n: u64 = 0;
    var buf: [64]u8 = undefined;
    while (true) : (n += 1) {
        usys.sleep(5);
        _ = usys.log(log_handle, lineFmt(&buf, "tick ", n));
    }
}

/// No cap was granted: prove that no ambient authority exists. Exit code 42
/// means every attempt was properly denied.
fn sneaky() noreturn {
    if (usys.log(0, "sneaky: this must never print") == .ok) {
        usys.exit(1);
    }
    // Forge the handle a fresh table would hand out (slot 0, generation 1).
    const forged: shared.Handle = .{ .slot = 0, .generation = 1 };
    if (usys.log(@bitCast(forged), "sneaky: forged handle must not work") == .ok) {
        usys.exit(2);
    }
    usys.exit(42);
}

/// "<prefix><n>" — no std.fmt in user space yet.
fn lineFmt(buf: []u8, prefix: []const u8, n: u64) []const u8 {
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
