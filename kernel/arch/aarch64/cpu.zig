//! The CPU as the generic kernel sees it: interrupt masking (DAIF), the
//! per-core pointer (TPIDR_EL1 at EL1, TPIDR_EL2 as the VHE host —
//! TPIDR_EL1 is one of the few registers VHE does not redirect, and a
//! guest at EL1 owns it), the cycle counter (CNTPCT), halting (WFI).
//! Every read of mutable CPU state is `asm volatile` (HACKING.md).

/// Saved interrupt state (DAIF), for irqRestore.
pub const IrqState = u64;

/// Mask IRQs on this core; returns the state to restore.
pub fn irqSave() IrqState {
    const daif = asm volatile ("mrs %[v], daif"
        : [v] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2");
    return daif;
}

pub fn irqRestore(s: IrqState) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (s),
    );
}

pub fn irqEnable() void {
    asm volatile ("msr daifclr, #2");
}

/// Mask every interrupt class (the panic path).
pub fn irqMaskAll() void {
    asm volatile ("msr daifset, #0xf");
}

/// Wait for an interrupt, once; idle loops call it repeatedly.
pub fn halt() void {
    asm volatile ("wfi");
}

/// The cycle counter (the physical counter, CNTPCT).
pub fn cycles() u64 {
    return asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (-> u64),
    );
}

/// The counter's frequency (a constant).
pub fn cycleHz() u64 {
    return asm ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
}

pub fn currentEl() u64 {
    const el = asm ("mrs %[el], CurrentEL"
        : [el] "=r" (-> u64),
    );
    return el >> 2;
}

/// Whether the kernel is the EL2 (VHE) host; set by the first setThisCpu.
pub var host_el2: bool = false;

/// A word describing the privilege level, for the boot banner.
pub fn describe() []const u8 {
    return if (currentEl() == 2) "EL2 (VHE host)" else "EL1";
}

/// The per-core pointer the scheduler stores (a *PerCpu as an integer).
pub fn thisCpu() usize {
    if (host_el2) {
        return asm volatile ("mrs %[v], tpidr_el2"
            : [v] "=r" (-> u64),
        );
    }
    return asm volatile ("mrs %[v], tpidr_el1"
        : [v] "=r" (-> u64),
    );
}

pub fn setThisCpu(p: usize) void {
    if (currentEl() == 2) {
        host_el2 = true;
        asm volatile ("msr tpidr_el2, %[v]"
            :
            : [v] "r" (p),
        );
    }
    asm volatile ("msr tpidr_el1, %[v]"
        :
        : [v] "r" (p),
    );
}

/// This core's index (MPIDR Aff0 — QEMU virt numbers cores linearly).
pub fn id() u32 {
    const mpidr = asm volatile ("mrs %[v], mpidr_el1"
        : [v] "=r" (-> u64),
    );
    return @intCast(mpidr & 0xff);
}
