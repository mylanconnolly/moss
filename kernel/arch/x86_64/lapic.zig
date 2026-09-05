//! The local APIC in x2APIC mode: every register an MSR (0x800 + the
//! xAPIC offset >> 4), no MMIO, 32-bit ids, one instruction per IPI.
//! The loader enables x2APIC on every core (the MP request asks); a core
//! that arrives without it is switched here. The tick is the APIC timer
//! in TSC-deadline mode: one MSR write per period, the TSC as the clock —
//! or, where the CPU lacks that mode (QEMU's TCG does), the same timer
//! in one-shot mode counting the APIC's own clock, calibrated against
//! the TSC once at boot.

const std = @import("std");
const cpu = @import("cpu.zig");

const msr_x2apic_base: u32 = 0x800;
const r_id = 0x02;
const r_tpr = 0x08;
const r_eoi = 0x0b;
const r_svr = 0x0f;
const r_icr = 0x30;
const r_lvt_timer = 0x32;
const r_timer_init = 0x38;
const r_timer_cur = 0x39;
const r_timer_div = 0x3e;
const r_lvt_lint0 = 0x35;
const r_lvt_lint1 = 0x36;
const r_lvt_error = 0x37;
const msr_tsc_deadline: u32 = 0x6e0;

pub const vector_timer: u32 = 0xf0;
pub const vector_resched: u32 = 0xf1;
pub const vector_tlb: u32 = 0xf2;
pub const vector_spurious: u32 = 0xff;

const lvt_masked: u64 = 1 << 16;
const lvt_tsc_deadline: u64 = 2 << 17;
const div_by_1: u64 = 0b1011;

/// The timer has TSC-deadline mode (CPUID.1:ECX[24]); else one-shot.
pub var tsc_deadline: bool = false;

fn read(reg: u32) u64 {
    return cpu.rdmsr(msr_x2apic_base + reg);
}

fn write(reg: u32, v: u64) void {
    cpu.wrmsr(msr_x2apic_base + reg, v);
}

/// Per core, by that core, before its timer and before IRQs are enabled.
pub fn initCore() void {
    const base = cpu.rdmsr(cpu.msr_apic_base);
    if (base & (1 << 10) == 0) cpu.wrmsr(cpu.msr_apic_base, base | (1 << 11) | (1 << 10));
    cpu.x2apic = true;
    tsc_deadline = cpu.cpuid(1, 0).ecx & (1 << 24) != 0;
    write(r_tpr, 0);
    write(r_lvt_lint0, lvt_masked);
    write(r_lvt_lint1, lvt_masked);
    write(r_lvt_error, lvt_masked);
    if (tsc_deadline) {
        write(r_lvt_timer, vector_timer | lvt_tsc_deadline);
    } else {
        write(r_timer_div, div_by_1);
        write(r_lvt_timer, vector_timer); // one-shot, unmasked
    }
    write(r_svr, 0x100 | vector_spurious); // software enable, spurious vector
}

pub fn id() u32 {
    return @truncate(read(r_id));
}

pub fn eoi() void {
    write(r_eoi, 0);
}

/// Fixed-delivery IPI to one core by APIC id.
pub fn sendIpi(apic_id: u32, vector: u32) void {
    write(r_icr, (@as(u64, apic_id) << 32) | vector);
}

pub fn armDeadline(tsc: u64) void {
    cpu.wrmsr(msr_tsc_deadline, tsc);
}

/// One-shot: fire `count` APIC clocks from now.
pub fn armCount(count: u32) void {
    write(r_timer_init, count);
}

/// The APIC timer's clock rate, measured against the TSC over 20 ms:
/// the one-shot period is expressed in it. Once, on the boot core.
pub fn calibrateTimer() u64 {
    write(r_timer_div, div_by_1);
    write(r_timer_init, 0xffff_ffff);
    const t0 = cpu.cycles();
    const window = cpu.cycleHz() / 50;
    while (cpu.cycles() - t0 < window) std.atomic.spinLoopHint();
    const elapsed = 0xffff_ffff - read(r_timer_cur);
    write(r_timer_init, 0); // stop
    return elapsed * 50;
}
