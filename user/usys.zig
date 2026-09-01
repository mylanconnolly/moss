//! Userspace syscall wrappers. ABI: x8 = number, x0..x5 args, x0 = result
//! (a shared.Errno value). This is the seed of the Phase 5 runtime library.

const shared = @import("shared");

pub fn log(handle: u64, msg: []const u8) shared.Errno {
    return @enumFromInt(syscall3(.log, handle, @intFromPtr(msg.ptr), msg.len));
}

pub fn sleep(ticks: u64) void {
    _ = syscall3(.sleep, ticks, 0, 0);
}

pub fn yield() void {
    _ = syscall3(.yield, 0, 0, 0);
}

pub fn exit(code: u64) noreturn {
    _ = syscall3(.exit, code, 0, 0);
    unreachable;
}

fn syscall3(nr: shared.Syscall, a0: u64, a1: u64, a2: u64) u64 {
    return asm volatile ("svc #0"
        : [ret] "={x0}" (-> u64),
        : [nr] "{x8}" (@intFromEnum(nr)),
          [a0] "{x0}" (a0),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
        : .{ .memory = true });
}
