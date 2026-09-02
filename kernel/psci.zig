//! PSCI (Power State Coordination Interface): HVC when the kernel runs at
//! EL1, SMC when it is the EL2 host (an HVC would trap to ourselves) —
//! the conduits QEMU virt advertises for each.

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
const fid_system_off: u64 = 0x8400_0008;

/// Power the machine off (QEMU exits). The node-kill drill's exit door.
pub fn systemOff() noreturn {
    _ = call(fid_system_off, 0, 0, 0);
    while (true) {
        asm volatile ("wfi");
    }
}

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
    const el = asm ("mrs %[el], CurrentEL"
        : [el] "=r" (-> u64),
    ) >> 2;
    if (el == 2) {
        // `smc #0`, as an encoding: the assembler wants an EL3-enabled
        // target to spell it.
        return asm volatile (".inst 0xd4000003"
            : [ret] "={x0}" (-> u64),
            : [fid] "{x0}" (fid),
              [a1] "{x1}" (a1),
              [a2] "{x2}" (a2),
              [a3] "{x3}" (a3),
            : .{ .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
    }
    return asm volatile ("hvc #0"
        : [ret] "={x0}" (-> u64),
        : [fid] "{x0}" (fid),
          [a1] "{x1}" (a1),
          [a2] "{x2}" (a2),
          [a3] "{x3}" (a3),
        : .{ .x4 = true, .x5 = true, .x6 = true, .x7 = true, .x8 = true, .x9 = true, .x10 = true, .x11 = true, .x12 = true, .x13 = true, .x14 = true, .x15 = true, .x16 = true, .x17 = true, .memory = true });
}
