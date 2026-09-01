//! EL1 physical generic timer (CNTP, PPI 30), per core: fixed 100ms tick
//! driving preemption everywhere; core 0 is the timekeeper (uptime, sleeper
//! wakeups).

const log = @import("log.zig");
const gic = @import("gic.zig");
const sched = @import("sched.zig");

pub const intid: u32 = 30;
pub const ticks_per_second = 10;

var interval: u64 = 0;

pub fn initCore(cpu: u32) void {
    if (cpu == 0) {
        const freq = asm ("mrs %[v], cntfrq_el0"
            : [v] "=r" (-> u64),
        );
        interval = freq / ticks_per_second;
        log.info("timer: {d} Hz counter, {d}ms tick on every core", .{
            freq, 1000 / ticks_per_second,
        });
    }
    gic.enableLocalInterrupt(cpu, intid);
    rearm();
    asm volatile (
        \\msr cntp_ctl_el0, %[one]
        \\isb
        :
        : [one] "r" (@as(u64, 1)),
    );
}

var uptime_ticks: u64 = 0;

pub fn handleIrq() void {
    const cpu = sched.thisCpu().id;
    if (cpu == 0) {
        uptime_ticks += 1;
        if (uptime_ticks % (60 * ticks_per_second) == 0) {
            log.info("timer: {d}min uptime", .{uptime_ticks / ticks_per_second / 60});
        }
    }
    sched.onTick(cpu == 0);
    rearm();
}

fn rearm() void {
    asm volatile ("msr cntp_tval_el0, %[v]"
        :
        : [v] "r" (interval),
    );
}
