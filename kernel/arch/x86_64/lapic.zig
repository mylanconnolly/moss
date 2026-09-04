//! The local APIC in x2APIC mode: every register an MSR (0x800 + the
//! xAPIC offset >> 4), no MMIO, 32-bit ids, one instruction per IPI.
//! The loader enables x2APIC on every core (the MP request asks); a core
//! that arrives without it is switched here. The tick is the APIC timer
//! in TSC-deadline mode: one MSR write per period, the TSC as the clock.

const cpu = @import("cpu.zig");

const msr_x2apic_base: u32 = 0x800;
const r_id = 0x02;
const r_tpr = 0x08;
const r_eoi = 0x0b;
const r_svr = 0x0f;
const r_icr = 0x30;
const r_lvt_timer = 0x32;
const r_lvt_lint0 = 0x35;
const r_lvt_lint1 = 0x36;
const r_lvt_error = 0x37;
const msr_tsc_deadline: u32 = 0x6e0;

pub const vector_timer: u32 = 0xf0;
pub const vector_resched: u32 = 0xf1;
pub const vector_spurious: u32 = 0xff;

const lvt_masked: u64 = 1 << 16;
const lvt_tsc_deadline: u64 = 2 << 17;

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
    if (cpu.cpuid(1, 0).ecx & (1 << 24) == 0) @panic("x86_64: no TSC-deadline timer on this CPU");
    write(r_tpr, 0);
    write(r_lvt_lint0, lvt_masked);
    write(r_lvt_lint1, lvt_masked);
    write(r_lvt_error, lvt_masked);
    write(r_lvt_timer, vector_timer | lvt_tsc_deadline);
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
