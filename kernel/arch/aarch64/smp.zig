//! Secondary core bring-up over PSCI.
//!
//! Cores start one at a time: the boot core writes the next core's stack
//! into __secondary_stack, issues CPU_ON at _secondary_start (physical), and
//! waits for the core to check in. The secondary lands in secondaryEntry on
//! that stack with the coarse boot map active, switches to the real kernel
//! tables, and becomes its core's idle thread.

const std = @import("std");
const cpuinfo = @import("cpu.zig");
const gic = @import("gic.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const mmu = @import("mmu.zig");
const pmem = @import("../../pmem.zig");
const psci = @import("psci.zig");
const sched = @import("../../sched.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");

const stack_pages = 4;

export var __secondary_stack: u64 = 0;
var online = std.atomic.Value(u32).init(1);

extern const _secondary_start: anyopaque;

/// Bring up secondaries until PSCI reports no such core. QEMU virt numbers
/// cores linearly in MPIDR Aff0.
pub fn bringUp() void {
    var cpu: u64 = 1;
    while (cpu < sched.max_cpus) : (cpu += 1) {
        const stack_pa = pmem.allocContiguous(stack_pages) orelse {
            log.warn("smp: out of frames for core {d} stack", .{cpu});
            return;
        };
        __secondary_stack = mem.physToVirt(stack_pa) + stack_pages * mem.page_size;
        asm volatile ("dsb ish");

        const entry_pa = mem.virtToPhys(@intFromPtr(&_secondary_start));
        const expect = online.load(.acquire) + 1;
        psci.cpuOn(cpu, entry_pa, 0) catch |e| {
            pmem.freeContiguous(stack_pa, stack_pages);
            if (e != psci.Error.InvalidParameters) {
                log.warn("smp: CPU_ON core {d} failed: {t}", .{ cpu, e });
            }
            break;
        };
        while (online.load(.acquire) != expect) {
            std.atomic.spinLoopHint();
        }
    }
    log.info("smp: {d} cores online", .{online.load(.acquire)});
}

export fn secondaryEntry() callconv(.c) noreturn {
    // Still on the coarse boot map; adopt the real kernel tables.
    mmu.activate();
    trap.init();

    const cpu = cpuinfo.id();

    sched.registerCpu(cpu);
    gic.initCore(cpu);
    timer.initCore(cpu);

    _ = online.fetchAdd(1, .release);
    cpuinfo.irqEnable();

    // This context is now core `cpu`'s idle thread.
    while (true) cpuinfo.halt();
}
