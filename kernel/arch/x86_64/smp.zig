//! The other cores: the loader parked them (Limine's MP response) and
//! releases one at a `goto_address` write. Cores come up one at a time on
//! stacks this port allocates: the trampoline loads the kernel's CR3 and
//! the new stack in one breath (the loader's stack is unmapped under our
//! tables) and lands in secondaryEntry, which makes the core a scheduler
//! core with its own APIC timer.

const std = @import("std");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");
const lapic = @import("lapic.zig");
const limine = @import("limine.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const pmem = @import("../../pmem.zig");
const sched = @import("../../sched.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");

const max = 8;
const stack_pages = 4;
var apic_ids: [max]u32 = @splat(0);
var infos: [max]?*limine.MpInfo = @splat(null);
var count: usize = 1;
var online = std.atomic.Value(u32).init(1);

export var __secondary_stack: u64 = 0;
export var __secondary_index: u64 = 0;
export var __kernel_cr3: u64 = 0;

pub fn note(mp: *limine.MpResponse) void {
    const cpus: [*]const u64 = @ptrFromInt(mem.physToVirt(@intFromPtr(mp.cpus) - boot.hhdm_offset));
    apic_ids[0] = mp.bsp_lapic_id;
    count = 1;
    for (0..mp.cpu_count) |i| {
        const info = mem.physToPtr(*limine.MpInfo, cpus[i] - boot.hhdm_offset);
        if (info.lapic_id == mp.bsp_lapic_id or count == max) continue;
        apic_ids[count] = info.lapic_id;
        infos[count] = info;
        count += 1;
    }
}

pub fn apicIdOf(index: u32) u32 {
    return apic_ids[index];
}

pub fn currentIndex() u32 {
    const me = lapic.id();
    for (apic_ids[0..count], 0..) |a, i| if (a == me) return @intCast(i);
    return 0;
}

pub fn bringUp() void {
    __kernel_cr3 = cpu.readCr3();
    var idx: usize = 1;
    while (idx < count and idx < sched.max_cpus) : (idx += 1) {
        const info = infos[idx] orelse break;
        const stack_pa = pmem.allocContiguous(stack_pages) orelse {
            log.warn("smp: out of frames for core {d} stack", .{idx});
            return;
        };
        __secondary_stack = mem.physToVirt(stack_pa) + stack_pages * mem.page_size;
        __secondary_index = idx;
        const expect = online.load(.acquire) + 1;
        @atomicStore(u64, &info.goto_address, @intFromPtr(&secondaryTrampoline), .seq_cst);
        while (online.load(.acquire) != expect) std.atomic.spinLoopHint();
    }
    log.info("smp: {d} cores online", .{online.load(.acquire)});
}

/// Entered by the loader on the new core, on its stack, under its page
/// tables, with rdi = the core's info (unused: the index is a global).
export fn secondaryTrampoline(_: u64) callconv(.c) noreturn {
    asm volatile (
        \\mov __kernel_cr3(%%rip), %%rax
        \\mov %%rax, %%cr3
        \\mov __secondary_stack(%%rip), %%rsp
        \\xor %%rbp, %%rbp
        \\call secondaryEntry
        ::: .{ .rax = true, .memory = true });
    unreachable;
}

export fn secondaryEntry() callconv(.c) noreturn {
    trap.init();
    const idx: u32 = @intCast(__secondary_index);
    sched.registerCpu(idx);
    log.info("smp: core {d} up (apic {d})", .{ idx, lapic.id() });
    lapic.initCore();
    timer.initCore(idx);
    _ = online.fetchAdd(1, .release);
    cpu.irqEnable();
    while (true) cpu.halt();
}
