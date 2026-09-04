//! Generic timer, per core: fixed 100ms tick driving preemption
//! everywhere; core 0 is the timekeeper (uptime, sleeper wakeups). At EL1
//! it is the virtual timer, CNTV (PPI 27) — the one a hypervisor can
//! hand a guest without trapping, and identical to the physical one when
//! there is no hypervisor (offset zero). As the EL2 host it is CNTHP,
//! reached through the CNTP_* names under VHE, PPI 26.

const log = @import("../../log.zig");
const gic = @import("gic.zig");
const ticks_per_second = @import("../../timer.zig").ticks_per_second;

/// The per-core interrupt the tick arrives on (PPI 26 or 27, see above).
pub var intid: u32 = 30;

var interval: u64 = 0;

pub fn initCore(cpu: u32) void {
    if (cpu == 0) {
        const el = asm ("mrs %[el], CurrentEL"
            : [el] "=r" (-> u64),
        ) >> 2;
        intid = if (el == 2) 26 else 27;
        const freq = asm ("mrs %[v], cntfrq_el0"
            : [v] "=r" (-> u64),
        );
        interval = freq / ticks_per_second;
        log.info("timer: {d} Hz counter, {d}ms tick on every core", .{
            freq, 1000 / ticks_per_second,
        });
    }
    gic.enableLocalInterrupt(cpu, @intCast(intid));
    rearm();
    if (intid == 26) {
        asm volatile (
            \\msr cntp_ctl_el0, %[one]
            \\isb
            :
            : [one] "r" (@as(u64, 1)),
        );
    } else {
        asm volatile (
            \\msr cntv_ctl_el0, %[one]
            \\isb
            :
            : [one] "r" (@as(u64, 1)),
        );
    }
    // Let EL0 read the counters (cntvct/cntpct): userspace benchmarks and
    // timeouts need a clock that doesn't cost a syscall. As the EL2 host
    // this is CNTHCTL_EL2, where EL1PCTEN (bit 10) also lets a guest's
    // EL1/EL0 read the physical counter without a trap (its timer stays
    // the virtual one; the physical timer registers keep trapping).
    asm volatile (
        \\msr cntkctl_el1, %[v]
        \\isb
        :
        : [v] "r" (@as(u64, 0b11 | (1 << 10))),
    );
}

/// Program the next tick on this core.
pub fn rearm() void {
    if (intid == 26) {
        asm volatile ("msr cntp_tval_el0, %[v]"
            :
            : [v] "r" (interval),
        );
    } else {
        asm volatile ("msr cntv_tval_el0, %[v]"
            :
            : [v] "r" (interval),
        );
    }
}
