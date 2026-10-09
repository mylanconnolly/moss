//! The tick: a fixed 10ms period on every core, driving preemption;
//! core 0 is the timekeeper (uptime, sleeper wakeups, timers). The
//! source is the port's (`arch.timer`: the generic timer here); this
//! is what happens when it fires.

const arch = @import("arch.zig");
const log = @import("log.zig");
const sched = @import("sched.zig");
const domain = @import("domain.zig");
const ipc = @import("ipc.zig");
const trace = @import("trace.zig");

/// 100 Hz since 2026-10-08 (10 Hz before): every sleep and timeout in
/// the system rounds up to a tick, so a 10 ms poll slept 100 ms and a
/// page's respawn waited 200 ms for a teardown that took 50.
pub const ticks_per_second = 100;

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
    watchCores(cpu);
    arch.timer.rearm();
}

// Core 0 keeps time: if its tick stops — a spin with interrupts masked,
// a lock it will never get — every sleep and timer in the system stops
// with it, and so does the hang deadline, which is a sleeping thread.
// So each core watches the others from its own tick: a core whose count
// has not moved for `stall_seconds` is named, with the thread it was
// running, and the dumps are printed by the core that noticed. Two GUI
// drills went silent with no dump before this (2026-10-09).
const stall_seconds = 3;
const stall_ticks = stall_seconds * ticks_per_second;
var seen: [sched.max_cpus][sched.max_cpus]u64 = @splat(@splat(0)); // [watcher][watched]
var still: [sched.max_cpus][sched.max_cpus]u32 = @splat(@splat(0));
var reported = false;

fn watchCores(me: u32) void {
    if (reported) return;
    var c: u32 = 0;
    while (c < sched.max_cpus) : (c += 1) {
        if (c == me) continue;
        const now = sched.coreTicks(c) orelse continue;
        if (now != seen[me][c]) {
            seen[me][c] = now;
            still[me][c] = 0;
            continue;
        }
        still[me][c] += 1;
        if (still[me][c] < stall_ticks) continue;
        reported = true;
        log.err("timer: core {d} has not ticked for {d}s (seen by core {d}); it was running {s}", .{ c, stall_seconds, me, sched.coreCurrentName(c) });
        sched.debugDump();
        domain.debugDump();
        ipc.debugDumpNotifications();
        trace.dump();
        @panic("a core stalled with interrupts masked");
    }
}
