//! A guest: bare-metal 64-bit code running inside a moss VM on x86_64.
//! It has no kernel; it knows four things about its world: a serial port
//! at 0x3f8 whose bytes the VMM turns into log lines (every port access
//! is an exit), the local APIC as x2APIC MSRs (emulated by the
//! hypervisor) with a TSC-deadline timer, the TSC, and a hypercall
//! (`vmmcall`) the VMM answers — power-off is the same function id the
//! aarch64 guest asks PSCI for. It says hello, counts three ticks, and
//! powers off.

const timer_vector: u8 = 0x30;
const psci_system_off: u64 = 0x8400_0008;
const period: u64 = 400_000_000; // cycles: ~100 ms at 4 GHz

var ticks: u32 = 0;

// A GDT the interrupt path needs (the gate's code selector) and an IDT
// with one gate. Both in the image; the VMM handed us a stack.
var gdt: [3]u64 align(16) = .{ 0, 0x00af_9a00_0000_ffff, 0x00cf_9200_0000_ffff };
var idt: [64][2]u64 align(16) = @splat(.{ 0, 0 });
const Descriptor = extern struct { limit: u16 align(1), base: u64 align(1) };

comptime {
    asm (
        \\.section .text.boot, "ax"
        \\.global _start
        \\_start:
        \\        cld
        \\        call gmain
        \\1:      hlt
        \\        jmp 1b
        \\
        \\.global gtimer_entry
        \\gtimer_entry:
        \\        push %rax
        \\        push %rcx
        \\        push %rdx
        \\        push %rsi
        \\        push %rdi
        \\        push %r8
        \\        push %r9
        \\        push %r10
        \\        push %r11
        \\        call gtimer
        \\        pop %r11
        \\        pop %r10
        \\        pop %r9
        \\        pop %r8
        \\        pop %rdi
        \\        pop %rsi
        \\        pop %rdx
        \\        pop %rcx
        \\        pop %rax
        \\        iretq
    );
}

extern const gtimer_entry: anyopaque;

fn outb(port: u16, v: u8) void {
    asm volatile ("outb %[v], %[p]"
        :
        : [v] "{al}" (v),
          [p] "{dx}" (port),
    );
}

fn wrmsr(m: u32, v: u64) void {
    asm volatile ("wrmsr"
        :
        : [m] "{ecx}" (m),
          [lo] "{eax}" (@as(u32, @truncate(v))),
          [hi] "{edx}" (@as(u32, @truncate(v >> 32))),
    );
}

fn rdtsc() u64 {
    var lo: u32 = undefined;
    var hi: u32 = undefined;
    asm volatile ("rdtsc"
        : [lo] "={eax}" (lo),
          [hi] "={edx}" (hi),
    );
    return (@as(u64, hi) << 32) | lo;
}

fn puts(s: []const u8) void {
    for (s) |c| outb(0x3f8, c);
    outb(0x3f8, '\n');
}

fn putsNum(prefix: []const u8, n: u32) void {
    for (prefix) |c| outb(0x3f8, c);
    var digits: [10]u8 = undefined;
    var d: usize = 0;
    var v = n;
    while (true) {
        digits[d] = '0' + @as(u8, @intCast(v % 10));
        d += 1;
        v /= 10;
        if (v == 0) break;
    }
    while (d > 0) {
        d -= 1;
        outb(0x3f8, digits[d]);
    }
    outb(0x3f8, '\n');
}

fn armTimer() void {
    wrmsr(0x6e0, rdtsc() + period);
}

export fn gmain() callconv(.c) void {
    // Segments: our own GDT, CS reloaded through a far return.
    const gdtr = Descriptor{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile (
        \\lgdt (%[g])
        \\pushq $0x08
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        \\mov $0x10, %%eax
        \\mov %%eax, %%ds
        \\mov %%eax, %%es
        \\mov %%eax, %%ss
        :
        : [g] "r" (&gdtr),
        : .{ .rax = true, .memory = true });
    // One interrupt gate, present, DPL 0, the timer's vector.
    const off = @intFromPtr(&gtimer_entry);
    idt[timer_vector][0] = (off & 0xffff) | (0x08 << 16) | (@as(u64, 0x8e) << 40) | (((off >> 16) & 0xffff) << 48);
    idt[timer_vector][1] = off >> 32;
    const idtr = Descriptor{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[i])"
        :
        : [i] "r" (&idtr),
        : .{ .memory = true });
    // The local APIC: on, x2APIC, spurious vector, timer in TSC-deadline
    // mode on our vector.
    wrmsr(0x1b, 0xfee0_0d00);
    wrmsr(0x80f, 0x1ff);
    wrmsr(0x832, @as(u64, timer_vector) | (2 << 17));
    armTimer();
    asm volatile ("sti");

    puts("guest: hello from ring 0, inside a moss VM");
    while (ticks < 3) asm volatile ("hlt");
    puts("guest: three ticks; powering off");
    asm volatile ("vmmcall"
        :
        : [fid] "{rax}" (psci_system_off),
        : .{ .memory = true });
    while (true) asm volatile ("hlt");
}

export fn gtimer() callconv(.c) void {
    ticks += 1;
    putsNum("guest: tick ", ticks);
    armTimer();
    wrmsr(0x80b, 0); // EOI
}
