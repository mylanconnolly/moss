//! The tick: a fixed 100ms period on every core, driving preemption;
//! core 0 is the timekeeper (uptime, sleeper wakeups, timers). The
//! source is the port's (`arch.timer`: the generic timer here); this
//! is what happens when it fires.

const arch = @import("arch.zig");
const log = @import("log.zig");
const sched = @import("sched.zig");

pub const ticks_per_second = 10;

var uptime_ticks: u64 = 0;

/// From the port's interrupt path, on the core whose timer fired.
pub fn handleIrq() void {
    const cpu = sched.thisCpu().id;
    if (cpu == 0) {
        uptime_ticks += 1;
        if (uptime_ticks % (60 * ticks_per_second) == 0) {
            log.info("timer: {d}min uptime", .{uptime_ticks / ticks_per_second / 60});
        }
    }
    sched.onTick(cpu == 0);
    arch.timer.rearm();
}
