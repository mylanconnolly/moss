//! PSCI (Power State Coordination Interface) via HVC — the conduit QEMU
//! virt advertises when the kernel runs at EL1.

pub const Error = error{
    NotSupported,
    InvalidParameters,
    Denied,
    AlreadyOn,
    OnPending,
    InternalFailure,
    NotPresent,
    Disabled,
    InvalidAddress,
    Unknown,
};

const fid_cpu_on: u64 = 0xc400_0003; // SMC64 CPU_ON

pub fn cpuOn(target_mpidr: u64, entry_pa: u64, context_id: u64) Error!void {
    const ret = call(fid_cpu_on, target_mpidr, entry_pa, context_id);
    const code: i64 = @bitCast(ret);
    return switch (code) {
        0 => {},
        -1 => Error.NotSupported,
        -2 => Error.InvalidParameters,
        -3 => Error.Denied,
        -4 => Error.AlreadyOn,
        -5 => Error.OnPending,
        -6 => Error.InternalFailure,
        -7 => Error.NotPresent,
        -8 => Error.Disabled,
        -9 => Error.InvalidAddress,
        else => Error.Unknown,
    };
}

fn call(fid: u64, a1: u64, a2: u64, a3: u64) u64 {
    return asm volatile ("hvc #0"
        : [ret] "={x0}" (-> u64),
        : [fid] "{x0}" (fid),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}
