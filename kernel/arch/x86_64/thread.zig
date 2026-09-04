//! Kernel thread context: the callee-saved registers (rbx, rbp, r12-r15)
//! and rsp; a switch pushes them, swaps stacks, pops the other's and
//! returns into it. A new thread's stack holds one return address, the
//! trampoline, which calls the scheduler's C-ABI entry points with the
//! entry and argument parked in r12/r13. Vector state is the 512-byte
//! FXSAVE area (SSE; XSAVE for wider state comes with an AVX userspace).

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

pub fn enterUser(entry: u64, sp: u64, args: [5]u64) noreturn {
    _ = entry;
    _ = sp;
    _ = args;
    @panic("x86_64: user mode is a later stage of the port");
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
