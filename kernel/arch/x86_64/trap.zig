//! The IDT and the trap frame. 256 stubs push a vector (and a zero where
//! the CPU pushed no error code), save the registers and call
//! `trapHandler`; exceptions are dumped and the kernel panics — the
//! interrupt and syscall paths are the port's later stages. The GDT is
//! this port's own (the loader's lives in memory it reclaims): kernel
//! code/data, user data/code in the order `sysret` wants, a TSS slot per
//! core for later.

const std = @import("std");
const cpu = @import("cpu.zig");
const irq = @import("../../irq.zig");
const ktimer = @import("../../timer.zig");
const lapic = @import("lapic.zig");
const log = @import("../../log.zig");
const sched = @import("../../sched.zig");
const uaccess = @import("uaccess.zig");

/// Registers as the common stub pushes them, then the vector and error
/// code, then what the CPU pushed. Syscall argument and result slots
/// (this port's ABI, chosen once): 0 rdi, 1 rsi, 2 rdx, 3 r10, 4 r8,
/// 5 r9, 6 r12, 7 r13; the number in rax.
pub const TrapFrame = extern struct {
    r15: u64,
    r14: u64,
    r13: u64,
    r12: u64,
    r11: u64,
    r10: u64,
    r9: u64,
    r8: u64,
    rbp: u64,
    rdi: u64,
    rsi: u64,
    rdx: u64,
    rcx: u64,
    rbx: u64,
    rax: u64,
    vector: u64,
    error_code: u64,
    rip: u64,
    cs: u64,
    rflags: u64,
    rsp: u64,
    ss: u64,

    pub inline fn arg(f: *const TrapFrame, i: usize) u64 {
        return switch (i) {
            0 => f.rdi,
            1 => f.rsi,
            2 => f.rdx,
            3 => f.r10,
            4 => f.r8,
            5 => f.r9,
            6 => f.r12,
            7 => f.r13,
            else => unreachable,
        };
    }

    pub inline fn set(f: *TrapFrame, i: usize, v: u64) void {
        switch (i) {
            0 => f.rdi = v,
            1 => f.rsi = v,
            2 => f.rdx = v,
            3 => f.r10 = v,
            4 => f.r8 = v,
            5 => f.r9 = v,
            6 => f.r12 = v,
            7 => f.r13 = v,
            else => unreachable,
        }
    }

    pub inline fn pc(f: *const TrapFrame) u64 {
        return f.rip;
    }

    pub inline fn msgWords(f: *const TrapFrame) [4]u64 {
        return .{ f.rsi, f.rdx, f.r10, f.r8 };
    }

    pub inline fn setMsgWords(f: *TrapFrame, w: [4]u64) void {
        f.rsi = w[0];
        f.rdx = w[1];
        f.r10 = w[2];
        f.r8 = w[3];
    }
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) == 22 * 8);
}

// ------------------------------------------------------------------- GDT

pub const sel_kernel_code: u16 = 0x08;
pub const sel_kernel_data: u16 = 0x10;
pub const sel_user_data: u16 = 0x18 | 3;
pub const sel_user_code: u16 = 0x20 | 3;

var gdt: [7]u64 align(16) = .{
    0,
    0x00af_9a00_0000_ffff, // kernel code: present, DPL0, code, long
    0x00cf_9200_0000_ffff, // kernel data
    0x00cf_f200_0000_ffff, // user data, DPL3
    0x00af_fa00_0000_ffff, // user code, DPL3, long
    0, // TSS, low (per core, later)
    0, // TSS, high
};

const Descriptor = extern struct { limit: u16 align(1), base: u64 align(1) };

// ------------------------------------------------------------------- IDT

const Gate = extern struct {
    off_lo: u16,
    sel: u16,
    ist: u8,
    flags: u8,
    off_mid: u16,
    off_hi: u32,
    zero: u32,
};

var idt: [256]Gate align(16) = undefined;

fn hasErrorCode(v: usize) bool {
    return switch (v) {
        8, 10, 11, 12, 13, 14, 17, 21, 29, 30 => true,
        else => false,
    };
}

fn stubs() []const u8 {
    @setEvalBranchQuota(200_000);
    var out: []const u8 = "";
    for (0..256) |v| {
        out = out ++ std.fmt.comptimePrint(
            \\.balign 16
            \\__trap_stub_{d}:
            \\
        , .{v});
        if (!hasErrorCode(v)) out = out ++ "        pushq $0\n";
        out = out ++ std.fmt.comptimePrint(
            \\        pushq ${d}
            \\        jmp __trap_common
            \\
        , .{v});
    }
    return out;
}

comptime {
    asm (
        \\.section .text, "ax"
        \\.balign 16
        \\.global __trap_stubs
        \\__trap_stubs:
        \\
    ++ stubs() ++
        \\__trap_common:
        \\        push %rax
        \\        push %rbx
        \\        push %rcx
        \\        push %rdx
        \\        push %rsi
        \\        push %rdi
        \\        push %rbp
        \\        push %r8
        \\        push %r9
        \\        push %r10
        \\        push %r11
        \\        push %r12
        \\        push %r13
        \\        push %r14
        \\        push %r15
        \\        mov %rsp, %rdi
        \\        cld
        \\        call trapHandler
        \\        pop %r15
        \\        pop %r14
        \\        pop %r13
        \\        pop %r12
        \\        pop %r11
        \\        pop %r10
        \\        pop %r9
        \\        pop %r8
        \\        pop %rbp
        \\        pop %rdi
        \\        pop %rsi
        \\        pop %rdx
        \\        pop %rcx
        \\        pop %rbx
        \\        pop %rax
        \\        add $16, %rsp
        \\        iretq
    );
}

extern const __trap_stubs: anyopaque;

/// Once, from the boot core: the gates. Every stub is 16 bytes apart —
/// the label before the first is aligned too, or the arithmetic points
/// into the middle of the stubs (the first bug this port found).
fn buildIdt() void {
    const base = @intFromPtr(&__trap_stubs);
    for (&idt, 0..) |*g, v| {
        const off = base + v * 16;
        g.* = .{
            .off_lo = @truncate(off),
            .sel = sel_kernel_code,
            .ist = 0,
            .flags = 0x8e, // present, DPL0, interrupt gate
            .off_mid = @truncate(off >> 16),
            .off_hi = @truncate(off >> 32),
            .zero = 0,
        };
    }
}

var idt_built = false;

/// Per core: this port's GDT and IDT, CR4 features, the user-memory door.
pub fn init() void {
    if (!idt_built) {
        buildIdt();
        idt_built = true;
    }
    const gdtr = Descriptor{ .limit = @sizeOf(@TypeOf(gdt)) - 1, .base = @intFromPtr(&gdt) };
    asm volatile (
        \\lgdt (%[g])
        \\push %[cs]
        \\lea 1f(%%rip), %%rax
        \\push %%rax
        \\lretq
        \\1:
        \\mov %[ds], %%eax
        \\mov %%eax, %%ds
        \\mov %%eax, %%es
        \\mov %%eax, %%ss
        \\xor %%eax, %%eax
        \\mov %%eax, %%fs
        \\mov %%eax, %%gs
        :
        : [g] "r" (&gdtr),
          [cs] "i" (@as(u64, sel_kernel_code)),
          [ds] "i" (@as(u32, sel_kernel_data)),
        : .{ .rax = true, .memory = true });
    const idtr = Descriptor{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[i])"
        :
        : [i] "r" (&idtr),
        : .{ .memory = true });
    // SMEP: the kernel never executes user pages. FSGSBASE for the
    // per-core pointer. (SMAP arrives with uaccess.)
    cpu.enableFsgsbase();
    if (cpu.cpuid(7, 0).ebx & (1 << 7) != 0) cpu.writeCr4(cpu.readCr4() | (1 << 20));
    uaccess.enable();
}

export fn trapHandler(frame: *TrapFrame) callconv(.c) void {
    if (frame.vector >= 32) return handleIrq(@intCast(frame.vector));
    reportFault(frame);
}

/// An interrupt: the vector is the interrupt id. The tick, the kick (only
/// here for the preempt below), a bound line or message; end-of-interrupt
/// before any context switch, as on aarch64, so a preempted-away thread
/// never holds this core's in-service state hostage.
fn handleIrq(vector: u32) void {
    if (vector == lapic.vector_spurious) return; // no EOI for a spurious one
    if (vector == lapic.vector_timer) {
        ktimer.handleIrq();
    } else if (vector == lapic.vector_resched) {
        // just here for the preempt below
    } else if (!irq.deliver(vector)) {
        log.warn("unexpected interrupt {d}", .{vector});
    }
    lapic.eoi();
    sched.preemptIfNeeded();
}

fn reportFault(frame: *TrapFrame) noreturn {
    const v = frame.vector;
    log.print("\n!! EXCEPTION: vector {d} — {s}\n", .{ v, vectorName(v) });
    log.print("!! error=0x{x} rip=0x{x:0>16} cs=0x{x} rflags=0x{x} rsp=0x{x:0>16}\n", .{ frame.error_code, frame.rip, frame.cs, frame.rflags, frame.rsp });
    if (v == 14) log.print("!! cr2=0x{x:0>16} ({s}, {s}, {s})\n", .{
        cpu.readCr2(),
        if (frame.error_code & 1 != 0) "protection" else "not present",
        if (frame.error_code & 2 != 0) "write" else "read",
        if (frame.error_code & 4 != 0) "user" else "kernel",
    });
    log.print("!! rax=0x{x:0>16} rbx=0x{x:0>16} rcx=0x{x:0>16} rdx=0x{x:0>16}\n", .{ frame.rax, frame.rbx, frame.rcx, frame.rdx });
    log.print("!! rsi=0x{x:0>16} rdi=0x{x:0>16} rbp=0x{x:0>16} r8 =0x{x:0>16}\n", .{ frame.rsi, frame.rdi, frame.rbp, frame.r8 });
    log.print("!! r9 =0x{x:0>16} r10=0x{x:0>16} r11=0x{x:0>16} r12=0x{x:0>16}\n", .{ frame.r9, frame.r10, frame.r11, frame.r12 });
    log.print("!! r13=0x{x:0>16} r14=0x{x:0>16} r15=0x{x:0>16}\n", .{ frame.r13, frame.r14, frame.r15 });
    @panic("unhandled kernel exception");
}

fn vectorName(v: u64) []const u8 {
    return switch (v) {
        0 => "divide error",
        1 => "debug",
        2 => "NMI",
        3 => "breakpoint",
        6 => "invalid opcode",
        7 => "device not available (FP use in the kernel?)",
        8 => "double fault",
        10 => "invalid TSS",
        11 => "segment not present",
        12 => "stack fault",
        13 => "general protection fault",
        14 => "page fault",
        17 => "alignment check",
        18 => "machine check",
        19 => "SIMD exception",
        else => if (v >= 32) "interrupt (no handler yet)" else "reserved exception",
    };
}
