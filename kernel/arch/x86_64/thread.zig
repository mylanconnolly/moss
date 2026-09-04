//! Kernel thread context: the callee-saved registers (rbx, rbp, r12-r15)
//! and rsp; a switch pushes them, swaps stacks, pops the other's and
//! returns into it. A new thread's stack holds one return address, the
//! trampoline, which calls the scheduler's C-ABI entry points with the
//! entry and argument parked in r12/r13. Vector state is the 512-byte
//! FXSAVE area (SSE; XSAVE for wider state comes with an AVX userspace).

const trap = @import("trap.zig");

pub const Context = extern struct {
    // rbx, rbp, r12, r13, r14, r15, then rsp.
    regs: [6]u64 = @splat(0),
    sp: u64 = 0,
};

pub const FpState = extern struct {
    area: [512]u8 align(16) = @splat(0),
};

pub fn initContext(ctx: *Context, sp: u64, entry: u64, arg: u64) void {
    // The trampoline's return address sits at the top; rsp is 16-aligned
    // above it, as the SysV ABI wants at a call.
    const top = sp - 8;
    @as(*u64, @ptrFromInt(top)).* = @intFromPtr(&__thread_trampoline);
    ctx.* = .{ .sp = top };
    ctx.regs[2] = entry; // r12
    ctx.regs[3] = arg; // r13
}

pub fn switchContext(prev: *Context, next: *Context) void {
    __context_switch(prev, next);
}

pub fn fpSave(st: *FpState) void {
    asm volatile ("fxsave64 (%[p])"
        :
        : [p] "r" (&st.area),
        : .{ .memory = true });
}

pub fn fpRestore(st: *const FpState) void {
    asm volatile ("fxrstor64 (%[p])"
        :
        : [p] "r" (&st.area),
        : .{ .memory = true });
}

/// The current thread's kernel stack top, for the syscall entry and the
/// TSS: the scheduler says so at every switch to a user thread.
pub const setKernelStack = trap.setKernelStack;

/// Drop to ring 3 at `entry` with the five entry arguments in rdi, rsi,
/// rdx, rcx, r8 (the SysV order, so `umain` is a plain C function), on a
/// stack aligned as the ABI wants at a function's first instruction.
/// `iretq` with IF set; `swapgs` hands the GS base to user mode (0).
pub fn enterUser(entry: u64, sp: u64, args: [5]u64) noreturn {
    const user_sp = (sp & ~@as(u64, 15)) - 8;
    asm volatile (
        \\cli
        \\pushq $0x1b
        \\push %[sp]
        \\pushq $0x202
        \\pushq $0x23
        \\push %[entry]
        \\xor %%eax, %%eax
        \\xor %%ebx, %%ebx
        \\xor %%ebp, %%ebp
        \\xor %%r9d, %%r9d
        \\xor %%r10d, %%r10d
        \\xor %%r11d, %%r11d
        \\xor %%r12d, %%r12d
        \\xor %%r13d, %%r13d
        \\xor %%r14d, %%r14d
        \\xor %%r15d, %%r15d
        \\swapgs
        \\iretq
        :
        : [entry] "r" (entry),
          [sp] "r" (user_sp),
          [a0] "{rdi}" (args[0]),
          [a1] "{rsi}" (args[1]),
          [a2] "{rdx}" (args[2]),
          [a3] "{rcx}" (args[3]),
          [a4] "{r8}" (args[4]),
        : .{ .memory = true });
    unreachable;
}

extern fn __context_switch(prev: *Context, next: *Context) void;
extern const __thread_trampoline: anyopaque;

comptime {
    asm (
        \\.section .text, "ax"
        \\.global __context_switch
        \\__context_switch:
        \\        mov %rbx, 0(%rdi)
        \\        mov %rbp, 8(%rdi)
        \\        mov %r12, 16(%rdi)
        \\        mov %r13, 24(%rdi)
        \\        mov %r14, 32(%rdi)
        \\        mov %r15, 40(%rdi)
        \\        mov %rsp, 48(%rdi)
        \\        mov 0(%rsi), %rbx
        \\        mov 8(%rsi), %rbp
        \\        mov 16(%rsi), %r12
        \\        mov 24(%rsi), %r13
        \\        mov 32(%rsi), %r14
        \\        mov 40(%rsi), %r15
        \\        mov 48(%rsi), %rsp
        \\        ret
        \\
        \\.global __thread_trampoline
        \\__thread_trampoline:
        \\        call schedThreadStart
        \\        mov %r12, %rdi
        \\        mov %r13, %rsi
        \\        call schedThreadRun
    );
}
