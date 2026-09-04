//! The CPU as the generic kernel sees it: interrupt masking (RFLAGS.IF),
//! the per-core pointer (the GS base, read with `rdgsbase` — FSGSBASE is
//! on every CPU this port targets and CR4 enables it at trap.init), the
//! cycle counter (the TSC, invariant on this class of hardware; its
//! frequency comes from the loader), halting (HLT). Port I/O and MSR
//! helpers live here for the rest of the port.

const std = @import("std");

pub const IrqState = u64;
const rflags_if: u64 = 1 << 9;

pub fn irqSave() IrqState {
    const f = asm volatile (
        \\pushfq
        \\pop %[f]
        \\cli
        : [f] "=r" (-> u64),
        :
        : .{ .memory = true });
    return f;
}

pub fn irqRestore(s: IrqState) void {
    if (s & rflags_if != 0) asm volatile ("sti" ::: .{ .memory = true });
}

pub fn irqEnable() void {
    asm volatile ("sti" ::: .{ .memory = true });
}

pub fn irqMaskAll() void {
    asm volatile ("cli" ::: .{ .memory = true });
}

/// Wait for an interrupt, once; idle loops call it repeatedly.
pub fn halt() void {
    asm volatile ("hlt");
}

pub fn cycles() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

/// The TSC frequency, from the loader (platform.discover stores it).
pub var tsc_hz: u64 = 0;

pub fn cycleHz() u64 {
    return tsc_hz;
}

pub var x2apic: bool = false;
var fsgsbase = false;

pub fn describe() []const u8 {
    // IA32_APIC_BASE.EXTD: the loader's doing (the MP request asks for it).
    x2apic = rdmsr(msr_apic_base) & (1 << 10) != 0;
    return if (x2apic) "ring 0 (x2APIC)" else "ring 0 (xAPIC)";
}

/// CR4.FSGSBASE, once per core, before setThisCpu: `rdgsbase` is the
/// one-instruction per-core pointer read. Without the feature the MSR is
/// used instead (slower, never on the hardware this port is for).
pub fn enableFsgsbase() void {
    const r = cpuid(7, 0);
    fsgsbase = r.ebx & (1 << 0) != 0;
    if (fsgsbase) writeCr4(readCr4() | (1 << 16));
}

pub fn thisCpu() usize {
    if (fsgsbase) {
        return asm volatile ("rdgsbase %[v]"
            : [v] "=r" (-> u64),
        );
    }
    return rdmsr(msr_gs_base);
}

pub fn setThisCpu(p: usize) void {
    if (fsgsbase) {
        asm volatile ("wrgsbase %[v]"
            :
            : [v] "r" (p),
        );
    } else {
        wrmsr(msr_gs_base, p);
    }
}

/// This core's index: its position among the CPUs the loader listed
/// (smp.zig fills the table; the boot core is 0 until then).
pub fn id() u32 {
    return @import("smp.zig").currentIndex();
}

/// The local APIC id of this core (x2APIC: MSR 0x802; else CPUID.1:EBX).
pub fn apicId() u32 {
    if (x2apic) return @truncate(rdmsr(0x802));
    return cpuid(1, 0).ebx >> 24;
}

// ---------------------------------------------------------------- helpers

pub const msr_gs_base: u32 = 0xc000_0101;
pub const msr_kernel_gs_base: u32 = 0xc000_0102;
pub const msr_apic_base: u32 = 0x1b;

pub fn rdmsr(m: u32) u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdmsr"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
        : [m] "{ecx}" (m),
    );
    return (@as(u64, hi) << 32) | lo;
}

pub fn wrmsr(m: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [m] "{ecx}" (m),
          [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
    );
}

pub const Cpuid = struct { eax: u32, ebx: u32, ecx: u32, edx: u32 };

pub fn cpuid(leaf: u32, sub: u32) Cpuid {
    var a: u32 = undefined;
    var b: u32 = undefined;
    var c: u32 = undefined;
    var d: u32 = undefined;
    asm volatile ("cpuid"
        : [a] "={eax}" (a),
          [b] "={ebx}" (b),
          [c] "={ecx}" (c),
          [d] "={edx}" (d),
        : [leaf] "{eax}" (leaf),
          [sub] "{ecx}" (sub),
    );
    return .{ .eax = a, .ebx = b, .ecx = c, .edx = d };
}

pub fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "{dx}" (port),
    );
}

pub fn outw(port: u16, v: u16) void {
    asm volatile ("outw %[v], %[p]"
        :
        : [v] "{ax}" (v),
          [p] "{dx}" (port),
    );
}

pub fn outl(port: u16, v: u32) void {
    asm volatile ("outl %[v], %[p]"
        :
        : [v] "{eax}" (v),
          [p] "{dx}" (port),
    );
}

pub fn inb(port: u16) u8 {
    return asm volatile ("inb %[p], %[v]"
        : [v] "={al}" (-> u8),
        : [p] "{dx}" (port),
    );
}

pub fn inl(port: u16) u32 {
    return asm volatile ("inl %[p], %[v]"
        : [v] "={eax}" (-> u32),
        : [p] "{dx}" (port),
    );
}

pub fn readCr2() u64 {
    return asm volatile ("mov %%cr2, %[v]"
        : [v] "=r" (-> u64),
    );
}

pub fn readCr3() u64 {
    return asm volatile ("mov %%cr3, %[v]"
        : [v] "=r" (-> u64),
    );
}

pub fn writeCr3(v: u64) void {
    asm volatile ("mov %[v], %%cr3"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub fn readCr4() u64 {
    return asm volatile ("mov %%cr4, %[v]"
        : [v] "=r" (-> u64),
    );
}

pub fn writeCr4(v: u64) void {
    asm volatile ("mov %[v], %%cr4"
        :
        : [v] "r" (v),
        : .{ .memory = true });
}

pub fn readCr0() u64 {
    return asm volatile ("mov %%cr0, %[v]"
        : [v] "=r" (-> u64),
    );
}

pub fn invlpg(va: u64) void {
    asm volatile ("invlpg (%[v])"
        :
        : [v] "r" (va),
        : .{ .memory = true });
}
