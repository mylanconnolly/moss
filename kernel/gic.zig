//! GICv3 on QEMU virt: distributor at 0x08000000, per-core redistributors
//! from 0x080a0000 with a 0x20000 stride (linear by core index on virt).
//! CPU interface via ICC system registers. Group 1 only.

const its = @import("its.zig");
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

pub fn redistributorBase(cpu: u32) u64 {
    return gicr_base + cpu * gicr_stride;
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
    its.initRedistributor(cpu);

    // SGIs/PPIs: group 1, highest priority.
    gicrSgi(cpu, 0x80).* = 0xffff_ffff; // IGROUPR0
    // The resched SGI must be enabled per-core or cross-core wakeup kicks
    // silently vanish (ISENABLER is set-bits, no RMW needed).
    gicrSgi(cpu, 0x100).* = @as(u32, 1) << @intCast(resched_sgi);

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

fn gicd64(offset: u64) *volatile u64 {
    return mem.physToPtr(*volatile u64, gicd_base + offset);
}

/// Enable a shared peripheral interrupt (intid >= 32), routed to core 0.
pub fn enableSpi(intid: u32) void {
    const reg = intid / 32;
    const bit = @as(u32, 1) << @intCast(intid % 32);
    gicd(0x80 + reg * 4).* = gicd(0x80 + reg * 4).* | bit; // IGROUPR: group 1
    gicd64(0x6000 + @as(u64, intid) * 8).* = 0; // IROUTER: affinity 0.0.0.0
    gicd(0x100 + reg * 4).* = bit; // ISENABLER
}

/// Make an SPI edge-triggered (GICD_ICFGR): pulsed sources — the SMMU's
/// event and error lines — are lost on a level-sensitive configuration.
pub fn configureEdge(intid: u32) void {
    const reg = intid / 16;
    const shift: u5 = @intCast((intid % 16) * 2 + 1);
    gicd(0xc00 + reg * 4).* = gicd(0xc00 + reg * 4).* | (@as(u32, 1) << shift);
}

pub fn gicdRead(offset: u64) u32 {
    return gicd(offset).*;
}

/// Mask an SPI (until the handler acks a level-triggered source).
pub fn disableSpi(intid: u32) void {
    const reg = intid / 32;
    const bit = @as(u32, 1) << @intCast(intid % 32);
    gicd(0x180 + reg * 4).* = bit; // ICENABLER
}

/// SGI used only to nudge a core into its preemption path.
pub const resched_sgi: u32 = 1;

/// Send the resched SGI to one core (affinity 0.0.0.cpu, as on QEMU virt).
pub fn sendSgi(cpu: u32) void {
    const val: u64 = (@as(u64, resched_sgi) << 24) | (@as(u64, 1) << @intCast(cpu));
    asm volatile (
        \\msr icc_sgi1r_el1, %[v]
        \\isb
        :
        : [v] "r" (val),
    );
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
