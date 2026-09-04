//! Kernel thread context and the drop to user mode. The callee-saved
//! registers (x19..x28, fp, lr) and sp are what a switch keeps; a new
//! thread starts in the trampoline, which calls the scheduler's C-ABI
//! entry points (`schedThreadStart`, `schedThreadRun` in sched.zig) with
//! the entry and argument it parked in x19/x20.
//!
//! EL0 FP/SIMD state (v0-v31 + fpsr/fpcr) is saved EAGERLY at context
//! switch for user threads only — kernel threads are FP-free by
//! construction (the kernel is built without FP/NEON features), so their
//! switches skip this entirely and user FP registers survive syscalls
//! untouched in hardware. Zero-initialized at spawn: a fresh thread
//! restores zeros and can never observe another domain's vector
//! registers.

pub const Context = extern struct {
    // x19..x28, x29 (fp), x30 (lr), then sp.
    regs: [12]u64 = @splat(0),
    sp: u64 = 0,
};

pub const FpState = extern struct {
    v: [32][16]u8 align(16) = @splat(@splat(0)),
    fpsr: u64 = 0,
    fpcr: u64 = 0,
};

/// A fresh context that runs `entry(arg)` on the stack whose top is `sp`.
pub fn initContext(ctx: *Context, sp: u64, entry: u64, arg: u64) void {
    ctx.* = .{ .sp = sp };
    ctx.regs[0] = entry; // x19
    ctx.regs[1] = arg; // x20
    ctx.regs[11] = @intFromPtr(&__thread_trampoline); // x30
}

/// The kernel stack of the thread being switched to: SP_EL1 is that
/// stack already on this port (the switch restores it), nothing to set.
pub fn setKernelStack(top: u64) void {
    _ = top;
}

pub fn switchContext(prev: *Context, next: *Context) void {
    __context_switch(prev, next);
}

pub fn fpSave(st: *FpState) void {
    __fp_save(st);
}

pub fn fpRestore(st: *const FpState) void {
    __fp_restore(st);
}

/// Drop to EL0 at `entry` with `sp` and the five entry arguments in
/// x0..x4; interrupts are re-enabled by the eret (SPSR = 0).
pub fn enterUser(entry: u64, sp: u64, args: [5]u64) noreturn {
    asm volatile (
        \\msr daifset, #0xf
        \\msr elr_el1, %[e]
        \\msr sp_el0, %[s]
        \\msr spsr_el1, xzr
        \\mov x0, %[a0]
        \\mov x1, %[a1]
        \\mov x2, %[a2]
        \\mov x3, %[a3]
        \\mov x4, %[a4]
        \\eret
        :
        : [e] "r" (entry),
          [s] "r" (sp),
          [a0] "r" (args[0]),
          [a1] "r" (args[1]),
          [a2] "r" (args[2]),
          [a3] "r" (args[3]),
          [a4] "r" (args[4]),
        : .{ .x0 = true, .x1 = true, .x2 = true, .x3 = true, .x4 = true, .memory = true });
    unreachable;
}

extern fn __context_switch(prev: *Context, next: *Context) void;
extern fn __fp_save(st: *FpState) void;
extern fn __fp_restore(st: *const FpState) void;
extern const __thread_trampoline: anyopaque;

comptime {
    asm (
        \\.section .text, "ax"
        \\.global __context_switch
        \\__context_switch:
        \\        stp     x19, x20, [x0]
        \\        stp     x21, x22, [x0, #16]
        \\        stp     x23, x24, [x0, #32]
        \\        stp     x25, x26, [x0, #48]
        \\        stp     x27, x28, [x0, #64]
        \\        stp     x29, x30, [x0, #80]
        \\        mov     x2, sp
        \\        str     x2, [x0, #96]
        \\        ldp     x19, x20, [x1]
        \\        ldp     x21, x22, [x1, #16]
        \\        ldp     x23, x24, [x1, #32]
        \\        ldp     x25, x26, [x1, #48]
        \\        ldp     x27, x28, [x1, #64]
        \\        ldp     x29, x30, [x1, #80]
        \\        ldr     x2, [x1, #96]
        \\        mov     sp, x2
        \\        ret
        \\
        \\.global __thread_trampoline
        \\__thread_trampoline:
        \\        bl      schedThreadStart
        \\        mov     x0, x19
        \\        mov     x1, x20
        \\        bl      schedThreadRun
        \\
        \\// FP/SIMD save/restore for user threads. The kernel target is
        \\// built without FP features, so these are the only vector
        \\// instructions in kernel text; the directive admits them.
        \\.arch_extension fp
        \\.arch_extension simd
        \\.global __fp_save
        \\__fp_save:
        \\        stp     q0, q1, [x0, #0]
        \\        stp     q2, q3, [x0, #32]
        \\        stp     q4, q5, [x0, #64]
        \\        stp     q6, q7, [x0, #96]
        \\        stp     q8, q9, [x0, #128]
        \\        stp     q10, q11, [x0, #160]
        \\        stp     q12, q13, [x0, #192]
        \\        stp     q14, q15, [x0, #224]
        \\        stp     q16, q17, [x0, #256]
        \\        stp     q18, q19, [x0, #288]
        \\        stp     q20, q21, [x0, #320]
        \\        stp     q22, q23, [x0, #352]
        \\        stp     q24, q25, [x0, #384]
        \\        stp     q26, q27, [x0, #416]
        \\        stp     q28, q29, [x0, #448]
        \\        stp     q30, q31, [x0, #480]
        \\        mrs     x1, fpsr
        \\        mrs     x2, fpcr
        \\        str     x1, [x0, #512]
        \\        str     x2, [x0, #520]
        \\        ret
        \\.global __fp_restore
        \\__fp_restore:
        \\        ldr     x1, [x0, #512]
        \\        ldr     x2, [x0, #520]
        \\        msr     fpsr, x1
        \\        msr     fpcr, x2
        \\        ldp     q0, q1, [x0, #0]
        \\        ldp     q2, q3, [x0, #32]
        \\        ldp     q4, q5, [x0, #64]
        \\        ldp     q6, q7, [x0, #96]
        \\        ldp     q8, q9, [x0, #128]
        \\        ldp     q10, q11, [x0, #160]
        \\        ldp     q12, q13, [x0, #192]
        \\        ldp     q14, q15, [x0, #224]
        \\        ldp     q16, q17, [x0, #256]
        \\        ldp     q18, q19, [x0, #288]
        \\        ldp     q20, q21, [x0, #320]
        \\        ldp     q22, q23, [x0, #352]
        \\        ldp     q24, q25, [x0, #384]
        \\        ldp     q26, q27, [x0, #416]
        \\        ldp     q28, q29, [x0, #448]
        \\        ldp     q30, q31, [x0, #480]
        \\        ret
    );
}
