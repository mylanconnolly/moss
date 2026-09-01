//! GICv3 on QEMU virt: distributor at 0x08000000, per-core redistributors
//! from 0x080a0000 with a 0x20000 stride (linear by core index on virt).
//! CPU interface via ICC system registers. Group 1 only.

const log = @import("log.zig");
const mem = @import("mem.zig");

const gicd_base: u64 = 0x0800_0000;
const gicr_base: u64 = 0x080a_0000;
const gicr_stride: u64 = 0x2_0000;

const gicd_ctlr_are_ns: u32 = 1 << 4;
const gicd_ctlr_enable_g1ns: u32 = 1 << 1;
const gicr_waker_processor_sleep: u32 = 1 << 1;
const gicr_waker_children_asleep: u32 = 1 << 2;

pub const spurious_intid: u32 = 1023;

fn gicd(offset: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, gicd_base + offset);
}

fn gicrRd(cpu: u32, offset: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, gicr_base + cpu * gicr_stride + offset);
}

fn gicrSgi(cpu: u32, offset: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, gicr_base + cpu * gicr_stride + 0x1_0000 + offset);
}

/// Once, from the boot core.
pub fn initDistributor() void {
    gicd(0x0).* = gicd_ctlr_are_ns | gicd_ctlr_enable_g1ns;
    log.info("gicv3: distributor up", .{});
}

/// On every core, by that core, before it enables IRQs.
pub fn initCore(cpu: u32) void {
    // Wake this core's redistributor.
    gicrRd(cpu, 0x14).* = gicrRd(cpu, 0x14).* & ~gicr_waker_processor_sleep;
    while (gicrRd(cpu, 0x14).* & gicr_waker_children_asleep != 0) {}

    // SGIs/PPIs: group 1, highest priority.
    gicrSgi(cpu, 0x80).* = 0xffff_ffff; // IGROUPR0

    // System-register CPU interface on, priority mask open, group 1 enabled.
    asm volatile (
        \\msr icc_sre_el1, %[one]
        \\isb
        \\msr icc_pmr_el1, %[pmr]
        \\msr icc_igrpen1_el1, %[one]
        \\isb
        :
        : [one] "r" (@as(u64, 1)),
          [pmr] "r" (@as(u64, 0xff)),
    );
}

/// Enable a PPI/SGI (intid < 32) on the given core's redistributor.
pub fn enableLocalInterrupt(cpu: u32, intid: u5) void {
    gicrSgi(cpu, 0x100).* = @as(u32, 1) << intid; // ISENABLER0
}

pub fn acknowledge() u32 {
    const intid = asm volatile ("mrs %[v], icc_iar1_el1"
        : [v] "=r" (-> u64),
    );
    return @truncate(intid);
}

pub fn endOfInterrupt(intid: u32) void {
    asm volatile ("msr icc_eoir1_el1, %[v]"
        :
        : [v] "r" (@as(u64, intid)),
    );
}
