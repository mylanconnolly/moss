//! Phase 2 exit-criterion test (-Dsched-test): threads pinned and migrating
//! across all cores, under load.
//!
//! - One "pin" thread per core busy-loops forever, asserting it only ever
//!   runs on its pinned core and logging roughly once per second of its own
//!   CPU time (which also exercises the budget-stub accounting).
//! - Three "migrant" threads sleep/wake in a loop; every wakeup re-enters a
//!   round-robin queue, so the cores they report should vary.
//! - One "mortal" thread exits immediately, exercising reaping.
//!
//! Preemption keeps the migrants and logging alive even though the pins
//! never yield.

const std = @import("std");
const log = @import("log.zig");
const arch = @import("arch.zig");
const sched = @import("sched.zig");
const timer = @import("timer.zig");

var migrant_wakes = std.atomic.Value(u64).init(0);

/// Everything happens from a driver thread, not from kmain's idle context:
/// since wakeup kicks (Phase 8), spawning a busy pinned thread onto your
/// own core preempts you immediately — and the idle thread, once displaced
/// by threads that never yield, does not come back.
pub fn start() void {
    _ = sched.spawn("sched-driver", driver, 0, .{}) catch |e| {
        std.debug.panic("spawn sched-driver: {t}", .{e});
    };
}

fn driver(_: u64) void {
    startWorkers();
    watcher();
}

fn startWorkers() void {
    for (0..sched.onlineCount()) |cpu| {
        _ = sched.spawn("pin", pinWorker, cpu, .{ .affinity = @intCast(cpu) }) catch |e| {
            std.debug.panic("spawn pin{d}: {t}", .{ cpu, e });
        };
    }
    for (0..3) |i| {
        _ = sched.spawn("migrant", migrantWorker, i, .{}) catch |e| {
            std.debug.panic("spawn migrant{d}: {t}", .{ i, e });
        };
    }
    _ = sched.spawn("mortal", mortalWorker, 0, .{}) catch |e| {
        std.debug.panic("spawn mortal: {t}", .{e});
    };
    log.info("sched-test: {d} pins, 3 migrants, 1 mortal started", .{sched.onlineCount()});
}

fn pinWorker(pin: u64) void {
    var reported: u64 = 0;
    while (true) {
        const here = sched.thisCpu().id;
        if (here != pin) {
            log.err("pin{d} found itself on core {d}", .{ pin, here });
            @panic("pin thread on wrong core");
        }
        const secs = sched.ticksOfCurrent() / timer.ticks_per_second;
        if (secs > reported) {
            reported = secs;
            log.info("pin{d}: on core {d}, {d}s cpu consumed", .{ pin, here, secs });
        }
    }
}

fn migrantWorker(id: u64) void {
    var wakes: u64 = 0;
    while (true) {
        sched.sleep(3 + id); // 300-500ms, staggered
        wakes += 1;
        _ = migrant_wakes.fetchAdd(1, .monotonic);
        log.info("migrant{d}: wake {d} on core {d}", .{ id, wakes, sched.thisCpu().id });
    }
}

/// Bounded verdict: pins under load and migrants making progress for ~10s
/// (a wrong-core pin would have panicked long before), then report and
/// power off so automation gets a clean exit.
fn watcher() void {
    sched.sleep(100);
    const wakes = migrant_wakes.load(.monotonic);
    if (wakes < 20) {
        std.debug.panic("sched-test: FAIL — migrants stalled ({d} wakes)", .{wakes});
    }
    log.info("sched-test: PASS — pins stayed pinned under load, {d} migrant wakes across cores", .{wakes});
    arch.power.systemOff();
}

fn mortalWorker(_: u64) void {
    log.info("mortal: ran on core {d}, exiting", .{sched.thisCpu().id});
}
