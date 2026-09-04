//! Traps, the syscall door, and what each core keeps at its GS base.
//!
//! Every core owns a `CpuLocal`: the scheduler's per-core pointer at
//! offset 0 (`mov %gs:0` is `thisCpu`), the current thread's kernel
//! stack top and a scratch slot the syscall entry uses to swap stacks,
//! its TSS (rsp0 = the same kernel stack, for interrupts from ring 3)
//! and its GDT. The GS base is that block in the kernel and 0 in user
//! mode; `swapgs` at every crossing, both ways.
//!
//! 256 stubs push a vector (and a zero where the CPU pushed no error
//! code), save the registers and call `trapHandler`: an interrupt (the
//! vector ≥ 32), a fault in user mode (reported to the domain's
//! supervisor, else the domain dies), or a kernel fault (a dump and a
//! panic). `syscall` lands in `__syscall_entry`, which builds the same
//! frame on the thread's kernel stack so `syscall.dispatch` sees one
//! shape from both ports, and leaves by `sysretq`.
//!
//! Syscall argument and result slots (this port's ABI): 0 rdi, 1 rsi,
//! 2 rdx, 3 r10, 4 r8, 5 r9, 6 r12, 7 r13; the number in rax; rcx and
//! r11 are the instruction's own (rip and rflags).

const std = @import("std");
const cpu = @import("cpu.zig");
const domain = @import("../../domain.zig");
const irq = @import("../../irq.zig");
const ktimer = @import("../../timer.zig");
const lapic = @import("lapic.zig");
const log = @import("../../log.zig");
const mmu = @import("mmu.zig");
const sched = @import("../../sched.zig");
const smp = @import("smp.zig");
const syscall = @import("../../syscall.zig");
const uaccess = @import("uaccess.zig");

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

    /// The syscall number: rax.
    pub inline fn syscallNumber(f: *const TrapFrame) u64 {
        return f.rax;
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

    fn fromUser(f: *const TrapFrame) bool {
        return f.cs & 3 != 0;
    }
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) == 22 * 8);
    std.debug.assert(@offsetOf(TrapFrame, "cs") == 144);
}

// ------------------------------------------------------------- per core

pub const sel_kernel_code: u16 = 0x08;
pub const sel_kernel_data: u16 = 0x10;
pub const sel_user_data: u16 = 0x18 | 3;
pub const sel_user_code: u16 = 0x20 | 3;
const sel_tss: u16 = 0x28;

/// What a core keeps at its GS base. The asm below indexes the first
/// three fields by offset.
pub const CpuLocal = extern struct {
    sched: u64 = 0, // 0: the scheduler's PerCpu
    kernel_stack: u64 = 0, // 8: the current thread's kernel stack top
    user_rsp: u64 = 0, // 16: the user stack across a syscall entry
    /// The 64-bit TSS as 32-bit words: rsp0 at words 1..2, the I/O map
    /// base (past the end: no map) in the top half of word 25.
    tss: [26]u32 align(16) = @splat(0),
    gdt: [7]u64 align(16) = @splat(0),
};

pub var locals: [8]CpuLocal = @splat(.{});

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
        \\        testb $3, 144(%rsp)
        \\        jz 1f
        \\        swapgs
        \\1:      mov %rsp, %rdi
        \\        cld
        \\        call trapHandler
        \\        testb $3, 144(%rsp)
        \\        jz 2f
        \\        swapgs
        \\2:      pop %r15
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
        \\
        \\// syscall: rcx = user rip, r11 = user rflags, IF masked (SFMASK).
        \\// The frame is the trap frame's shape, vector 0x80, on the
        \\// thread's kernel stack from the per-core block.
        \\.global __syscall_entry
        \\__syscall_entry:
        \\        swapgs
        \\        mov %rsp, %gs:16
        \\        mov %gs:8, %rsp
        \\        pushq $0x1b
        \\        pushq %gs:16
        \\        push %r11
        \\        pushq $0x23
        \\        push %rcx
        \\        pushq $0
        \\        pushq $0x80
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
        \\        call syscallHandler
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
        \\        pop %rcx
        \\        add $8, %rsp
        \\        pop %r11
        \\        mov (%rsp), %rsp
        \\        swapgs
        \\        sysretq
    );
}

extern const __trap_stubs: anyopaque;
extern const __syscall_entry: anyopaque;

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

const msr_efer: u32 = 0xc000_0080;
const msr_star: u32 = 0xc000_0081;
const msr_lstar: u32 = 0xc000_0082;
const msr_sfmask: u32 = 0xc000_0084;

/// Per core: its GDT with its TSS, the IDT, the control-register bits
/// (SMEP, SMAP, global pages, SSE for user mode), the syscall MSRs,
/// the GS bases, the user-memory door.
pub fn init() void {
    if (!idt_built) {
        buildIdt();
        idt_built = true;
    }
    const l = &locals[smp.currentIndex()];
    const tss_base = @intFromPtr(&l.tss);
    const tss_limit: u64 = @sizeOf(@TypeOf(l.tss)) - 1;
    l.tss[25] = @as(u32, @sizeOf(@TypeOf(l.tss))) << 16; // I/O map: none
    l.gdt = .{
        0,
        0x00af_9a00_0000_ffff, // kernel code: present, DPL0, long
        0x00cf_9200_0000_ffff, // kernel data
        0x00cf_f200_0000_ffff, // user data, DPL3
        0x00af_fa00_0000_ffff, // user code, DPL3, long
        (tss_limit & 0xffff) | ((tss_base & 0xff_ffff) << 16) | (0x89 << 40) | (((tss_limit >> 16) & 0xf) << 48) | (((tss_base >> 24) & 0xff) << 56),
        tss_base >> 32,
    };
    const gdtr = Descriptor{ .limit = @sizeOf(@TypeOf(l.gdt)) - 1, .base = @intFromPtr(&l.gdt) };
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
        \\mov %[tr], %%ax
        \\ltr %%ax
        :
        : [g] "r" (&gdtr),
          [cs] "i" (@as(u64, sel_kernel_code)),
          [ds] "i" (@as(u32, sel_kernel_data)),
          [tr] "i" (@as(u16, sel_tss)),
        : .{ .rax = true, .memory = true });
    const idtr = Descriptor{ .limit = @sizeOf(@TypeOf(idt)) - 1, .base = @intFromPtr(&idt) };
    asm volatile ("lidt (%[i])"
        :
        : [i] "r" (&idtr),
        : .{ .memory = true });
    // CR4: PGE (kernel pages survive CR3 loads), OSFXSR|OSXMMEXCPT (SSE
    // in user mode and FXSAVE), SMEP (the kernel never executes user
    // pages), SMAP where the CPU has it (uaccess arms the door).
    const f7 = cpu.cpuid(7, 0).ebx;
    var cr4 = cpu.readCr4() | (1 << 7) | (1 << 9) | (1 << 10);
    if (f7 & (1 << 7) != 0) cr4 |= 1 << 20;
    if (f7 & (1 << 20) != 0) cr4 |= 1 << 21;
    cpu.writeCr4(cr4);
    // CR0: MP on, EM/TS off — the vector unit is live for user threads.
    cpu.writeCr0((cpu.readCr0() | (1 << 1)) & ~@as(u64, (1 << 2) | (1 << 3)));
    // syscall/sysret: kernel CS 0x08 (SS 0x10); sysret CS = base + 16,
    // SS = base + 8 — the user descriptors' order — with the base
    // carrying RPL 3 already (0x13): Intel ORs the 3 in, AMD does not,
    // and an SS of 0x18 returned to ring 3 is refused by the next iretq.
    // IF, TF, DF, AC masked at entry.
    cpu.wrmsr(msr_efer, cpu.rdmsr(msr_efer) | 1);
    cpu.wrmsr(msr_star, (@as(u64, sel_kernel_code) << 32) | (@as(u64, 0x13) << 48));
    cpu.wrmsr(msr_lstar, @intFromPtr(&__syscall_entry));
    cpu.wrmsr(msr_sfmask, (1 << 9) | (1 << 8) | (1 << 10) | (1 << 18));
    // GS: this block in the kernel, nothing in user mode.
    cpu.wrmsr(cpu.msr_gs_base, @intFromPtr(l));
    cpu.wrmsr(cpu.msr_kernel_gs_base, 0);
    uaccess.enable();
}

/// The current thread's kernel stack, for the syscall entry and the TSS
/// (interrupts from ring 3): set at every switch to a user thread.
pub fn setKernelStack(top: u64) void {
    const l: *CpuLocal = @ptrFromInt(cpu.rdmsr(cpu.msr_gs_base));
    l.kernel_stack = top;
    l.tss[1] = @truncate(top);
    l.tss[2] = @truncate(top >> 32);
}

// ------------------------------------------------------------ handlers

export fn trapHandler(frame: *TrapFrame) callconv(.c) void {
    if (frame.vector >= 32) return handleIrq(@intCast(frame.vector));
    if (frame.fromUser()) return handleUserFault(frame);
    reportFault(frame);
}

/// A syscall: the frame from __syscall_entry. Like aarch64's SVC path,
/// with the safe point for a kill and the preempt on the way out.
export fn syscallHandler(frame: *TrapFrame) callconv(.c) void {
    const t = sched.thisCpu().current;
    t.in_syscall = true;
    syscall.dispatch(frame);
    t.in_syscall = false;
    sched.preemptIfNeeded();
}

/// An interrupt: the vector is the interrupt id. The tick, the kick (only
/// here for the preempt below), a TLB shootdown, a bound line or message;
/// end-of-interrupt before any context switch, as on aarch64.
fn handleIrq(vector: u32) void {
    if (vector == lapic.vector_spurious) return; // no EOI for a spurious one
    if (vector == lapic.vector_timer) {
        ktimer.handleIrq();
    } else if (vector == lapic.vector_resched) {
        // just here for the preempt below
    } else if (vector == lapic.vector_tlb) {
        mmu.onShootdown();
    } else if (!irq.deliver(vector)) {
        log.warn("unexpected interrupt {d}", .{vector});
    }
    lapic.eoi();
    sched.preemptIfNeeded();
}

/// A fault in user mode: fault-as-message to the domain's supervisor,
/// which decides its fate; an unsupervised domain is killed here. The
/// words a supervisor sees: the vector and error code, the address, pc.
fn handleUserFault(frame: *TrapFrame) void {
    const v = frame.vector;
    const addr = if (v == 14) cpu.readCr2() else 0;
    const code = v | (frame.error_code << 8);
    const t = sched.thisCpu().current;
    const d: *domain.Domain = @ptrCast(@alignCast(t.user_ctx.?));
    d.exit_code = 0xdead;
    if (domain.reportFaultToSupervisor(d, code, addr, frame.rip)) unreachable;
    log.warn("domain {s}: fault in user mode — {s} (vector={d} error=0x{x} addr=0x{x} rip=0x{x}); killing it", .{
        d.name, vectorName(v), v, frame.error_code, addr, frame.rip,
    });
    domain.destroy(d);
    sched.exit();
}

fn reportFault(frame: *TrapFrame) noreturn {
    const v = frame.vector;
    log.print("\n!! EXCEPTION: vector {d} — {s}\n", .{ v, vectorName(v) });
    log.print("!! error=0x{x} rip=0x{x:0>16} cs=0x{x} rflags=0x{x} rsp=0x{x:0>16}\n", .{ frame.error_code, frame.rip, frame.cs, frame.rflags, frame.rsp });
    if (v == 14) {
        const cr2 = cpu.readCr2();
        log.print("!! cr2=0x{x:0>16} ({s}, {s}, {s})\n", .{
            cr2,
            if (frame.error_code & 1 != 0) "protection" else "not present",
            if (frame.error_code & 2 != 0) "write" else "read",
            if (frame.error_code & 4 != 0) "user" else "kernel",
        });
        // A protection fault on a present user page from the kernel with
        // AC clear: SMAP refused a privileged touch outside uaccess.
        if (frame.error_code & 5 == 1 and cr2 < @import("boot.zig").kvirt_offset and frame.rflags & (1 << 18) == 0 and uaccess.available) {
            log.print("!! privileged access to user memory refused (SMAP): a kernel path touched a user page outside a uaccess window\n", .{});
        }
    }
    log.print("!! rax=0x{x:0>16} rbx=0x{x:0>16} rcx=0x{x:0>16} rdx=0x{x:0>16}\n", .{ frame.rax, frame.rbx, frame.rcx, frame.rdx });
    log.print("!! rsi=0x{x:0>16} rdi=0x{x:0>16} rbp=0x{x:0>16} r8 =0x{x:0>16}\n", .{ frame.rsi, frame.rdi, frame.rbp, frame.r8 });
    log.print("!! r9 =0x{x:0>16} r10=0x{x:0>16} r11=0x{x:0>16} r12=0x{x:0>16}\n", .{ frame.r9, frame.r10, frame.r11, frame.r12 });
    log.print("!! r13=0x{x:0>16} r14=0x{x:0>16} r15=0x{x:0>16}\n", .{ frame.r13, frame.r14, frame.r15 });
    // A kernel fault's stack top: an iretq or sysret frame there names
    // the return the CPU refused.
    if (frame.rsp >= @import("boot.zig").kvirt_offset) {
        const words: [*]const u64 = @ptrFromInt(frame.rsp);
        log.print("!! at rsp:", .{});
        for (0..6) |i| log.print(" {x:0>16}", .{words[i]});
        log.print("\n", .{});
    }
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
