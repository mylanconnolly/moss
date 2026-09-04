//! The tick source: the local APIC timer in TSC-deadline mode, one MSR
//! write per period; the period is the TSC frequency the loader measured
//! over the generic tick rate.

const cpu = @import("cpu.zig");
const lapic = @import("lapic.zig");
const log = @import("../../log.zig");
const ticks_per_second = @import("../../timer.zig").ticks_per_second;

pub var intid: u32 = lapic.vector_timer;
var interval: u64 = 0;

pub fn initCore(core: u32) void {
    if (core == 0) {
        interval = cpu.cycleHz() / ticks_per_second;
        log.info("timer: TSC-deadline, {d} MHz, {d}ms tick on every core", .{ cpu.cycleHz() / 1_000_000, 1000 / ticks_per_second });
    }
    rearm();
}

pub fn rearm() void {
    lapic.armDeadline(cpu.cycles() + interval);
}
