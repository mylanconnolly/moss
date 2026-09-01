//! EL1 physical generic timer (CNTP, PPI 30): fixed 100ms tick for now. A
//! real tickless scheduler clock arrives with Phase 2.

const log = @import("log.zig");
const gic = @import("gic.zig");

pub const intid: u32 = 30;

const ticks_per_second = 10;

var interval: u64 = 0;
var ticks: u64 = 0;

pub fn init() void {
    const freq = asm ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
    interval = freq / ticks_per_second;
    gic.enableLocalInterrupt(intid);
    rearm();
    asm volatile (
        \\msr cntp_ctl_el0, %[one]
        \\isb
        :
        : [one] "r" (@as(u64, 1)),
    );
    log.info("timer: {d} Hz counter, {d}ms tick", .{ freq, 1000 / ticks_per_second });
}

pub fn handleIrq() void {
    ticks += 1;
    if (ticks % ticks_per_second == 0) {
        log.info("timer: {d}s uptime ({d} ticks)", .{ ticks / ticks_per_second, ticks });
    }
    rearm();
}

fn rearm() void {
    asm volatile ("msr cntp_tval_el0, %[v]"
        :
        : [v] "r" (interval),
    );
}
