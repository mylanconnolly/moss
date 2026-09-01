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
const sched = @import("sched.zig");
const timer = @import("timer.zig");

pub fn start() void {
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
        log.info("migrant{d}: wake {d} on core {d}", .{ id, wakes, sched.thisCpu().id });
    }
}

fn mortalWorker(_: u64) void {
    log.info("mortal: ran on core {d}, exiting", .{sched.thisCpu().id});
}
