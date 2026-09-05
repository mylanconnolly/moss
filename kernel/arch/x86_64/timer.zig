//! The tick source: the local APIC timer in TSC-deadline mode, one MSR
//! write per period, the period the TSC frequency the loader measured
//! over the generic tick rate; or, on a CPU without that mode (QEMU's
//! TCG), the same timer in one-shot mode with the period in APIC clocks,
//! the rate calibrated against the TSC at boot.

const cpu = @import("cpu.zig");
const lapic = @import("lapic.zig");
const log = @import("../../log.zig");
const ticks_per_second = @import("../../timer.zig").ticks_per_second;

pub var intid: u32 = lapic.vector_timer;
/// The period: TSC cycles (deadline mode) or APIC clocks (one-shot).
var interval: u64 = 0;

pub fn initCore(core: u32) void {
    if (core == 0) {
        if (lapic.tsc_deadline) {
            interval = cpu.cycleHz() / ticks_per_second;
            log.info("timer: TSC-deadline, {d} MHz, {d}ms tick on every core", .{ cpu.cycleHz() / 1_000_000, 1000 / ticks_per_second });
        } else {
            const apic_hz = lapic.calibrateTimer();
            interval = apic_hz / ticks_per_second;
            log.info("timer: APIC one-shot (no TSC-deadline mode), {d} MHz APIC clock, {d}ms tick on every core", .{ apic_hz / 1_000_000, 1000 / ticks_per_second });
        }
    }
    rearm();
}

pub fn rearm() void {
    if (lapic.tsc_deadline) lapic.armDeadline(cpu.cycles() + interval) else lapic.armCount(@intCast(@min(interval, 0xffff_ffff)));
}
