//! GICv3 on QEMU virt: distributor at 0x08000000, core 0's redistributor at
//! 0x080a0000. CPU interface via ICC system registers. Group 1 only; core 0
//! only until Phase 2.

const log = @import("log.zig");
const mem = @import("mem.zig");

const gicd_base: u64 = 0x0800_0000;
const gicr_base: u64 = 0x080a_0000; // core 0 RD_base; SGI_base is +0x10000

const gicd_ctlr_are_ns: u32 = 1 << 4;
const gicd_ctlr_enable_g1ns: u32 = 1 << 1;
const gicr_waker_processor_sleep: u32 = 1 << 1;
const gicr_waker_children_asleep: u32 = 1 << 2;

pub const spurious_intid: u32 = 1023;

fn gicd(offset: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, gicd_base + offset);
}

fn gicrRd(offset: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, gicr_base + offset);
}

fn gicrSgi(offset: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, gicr_base + 0x1_0000 + offset);
}

pub fn init() void {
    // System-register CPU interface on, then unmask everything by priority.
    asm volatile (
        \\msr icc_sre_el1, %[one]
        \\isb
        :
        : [one] "r" (@as(u64, 1)),
    );

    gicd(0x0).* = gicd_ctlr_are_ns | gicd_ctlr_enable_g1ns;

    // Wake core 0's redistributor.
    gicrRd(0x14).* = gicrRd(0x14).* & ~gicr_waker_processor_sleep;
    while (gicrRd(0x14).* & gicr_waker_children_asleep != 0) {}

    // SGIs/PPIs: group 1, highest priority.
    gicrSgi(0x80).* = 0xffff_ffff; // IGROUPR0

    asm volatile (
        \\msr icc_pmr_el1, %[pmr]
        \\msr icc_igrpen1_el1, %[one]
        \\isb
        :
        : [pmr] "r" (@as(u64, 0xff)),
          [one] "r" (@as(u64, 1)),
    );

    log.info("gicv3: distributor + core 0 redistributor up", .{});
}

/// Enable a PPI/SGI (intid < 32) on core 0's redistributor.
pub fn enableLocalInterrupt(intid: u5) void {
    gicrSgi(0x100).* = @as(u32, 1) << intid; // ISENABLER0
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
