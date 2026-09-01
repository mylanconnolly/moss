//! Syscall dispatch. Numbers and errnos live in shared/ (the IDL); the ABI
//! is x8 = number, x0..x5 = arguments, x0 = result.
//!
//! Authority comes from capabilities, not from being a process: sys_log
//! demands a debug_log cap from the caller's table, validated by slot,
//! generation, and type. A domain spawned without the grant cannot log,
//! full stop.

const std = @import("std");
const domain = @import("domain.zig");
const log = @import("log.zig");
const sched = @import("sched.zig");
const shared = @import("shared");
const trap = @import("trap.zig");

pub fn dispatch(frame: *trap.TrapFrame) void {
    const t = sched.thisCpu().current;
    const d: *domain.Domain = @ptrCast(@alignCast(t.user_ctx orelse {
        frame.regs[0] = errno(.nosys);
        return;
    }));
    const nr: shared.Syscall = @enumFromInt(frame.regs[8]);
    frame.regs[0] = switch (nr) {
        .log => sysLog(d, frame.regs[0], frame.regs[1], frame.regs[2]),
        .yield => blk: {
            sched.yield();
            break :blk errno(.ok);
        },
        .sleep => blk: {
            sched.sleep(@min(frame.regs[0], 60 * 10));
            break :blk errno(.ok);
        },
        .exit => sysExit(d, frame.regs[0]),
        _ => errno(.nosys),
    };
}

fn sysLog(d: *domain.Domain, handle_bits: u64, ptr: u64, len: u64) u64 {
    const handle: shared.Handle = @bitCast(handle_bits);
    _ = d.captable.?.lookup(handle, .debug_log) orelse return errno(.bad_handle);
    if (len == 0 or len > 256) return errno(.bad_arg);
    if (!userRangeOk(d, ptr, len)) return errno(.fault);
    // No PAN on ARMv8.0 (and TTBR0 is live during this exception), so the
    // kernel can read the buffer through the user mapping directly.
    const bytes = @as([*]const u8, @ptrFromInt(ptr))[0..len];
    log.print("[{s}] {s}\n", .{ d.name, bytes });
    return errno(.ok);
}

fn sysExit(d: *domain.Domain, code: u64) noreturn {
    d.exit_code = code;
    domain.destroy(d); // marks this very thread exited
    sched.exit();
}

fn userRangeOk(d: *domain.Domain, ptr: u64, len: u64) bool {
    const end = ptr +% len;
    if (end < ptr) return false;
    const in_image = ptr >= shared.user_image_base and end <= d.image_end_va;
    const in_stack = ptr >= d.stack_base and end <= d.stack_top;
    return in_image or in_stack;
}

fn errno(e: shared.Errno) u64 {
    return @intFromEnum(e);
}
