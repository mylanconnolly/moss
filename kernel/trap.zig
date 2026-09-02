//! EL1 exception vectors and fault reporting.
//!
//! The vector table has 16 slots of 128 bytes. We run with SPSel=1, so our
//! own exceptions arrive via the "current EL with SPx" slots (4..7); the
//! lower-EL slots matter from Phase 3. Each stub saves x0/x1, loads its slot
//! index, and branches to a common path that captures the rest of the frame
//! and calls trapHandler.

const std = @import("std");
const log = @import("log.zig");
const mem = @import("mem.zig");
const domain = @import("domain.zig");
const gic = @import("gic.zig");
const irq = @import("irq.zig");
const sched = @import("sched.zig");
const smmu = @import("smmu.zig");
const syscall = @import("syscall.zig");
const timer = @import("timer.zig");

pub const TrapFrame = extern struct {
    regs: [31]u64,
    elr: u64,
    spsr: u64,
    sp_el0: u64,
};

comptime {
    std.debug.assert(@sizeOf(TrapFrame) == 272);
}

const stub_template =
    \\.balign 128
    \\        sub     sp, sp, #272
    \\        stp     x0, x1, [sp]
    \\        mov     x0, #{d}
    \\        b       __trap_common
    \\
;

fn allStubs() []const u8 {
    var out: []const u8 = "";
    for (0..16) |kind| {
        out = out ++ std.fmt.comptimePrint(stub_template, .{kind});
    }
    return out;
}

comptime {
    asm (
        \\.section .text.vectors, "ax"
        \\.balign 2048
        \\.global __vectors
        \\__vectors:
        \\
    ++ allStubs() ++
        \\.section .text, "ax"
        \\__trap_common:
        \\        stp     x2, x3, [sp, #16]
        \\        stp     x4, x5, [sp, #32]
        \\        stp     x6, x7, [sp, #48]
        \\        stp     x8, x9, [sp, #64]
        \\        stp     x10, x11, [sp, #80]
        \\        stp     x12, x13, [sp, #96]
        \\        stp     x14, x15, [sp, #112]
        \\        stp     x16, x17, [sp, #128]
        \\        stp     x18, x19, [sp, #144]
        \\        stp     x20, x21, [sp, #160]
        \\        stp     x22, x23, [sp, #176]
        \\        stp     x24, x25, [sp, #192]
        \\        stp     x26, x27, [sp, #208]
        \\        stp     x28, x29, [sp, #224]
        \\        str     x30, [sp, #240]
        \\        mrs     x1, elr_el1
        \\        str     x1, [sp, #248]
        \\        mrs     x1, spsr_el1
        \\        str     x1, [sp, #256]
        \\        mrs     x1, sp_el0
        \\        str     x1, [sp, #264]
        \\        mov     x1, x0
        \\        mov     x0, sp
        \\        bl      trapHandler
        \\        ldr     x1, [sp, #248]
        \\        msr     elr_el1, x1
        \\        ldr     x1, [sp, #256]
        \\        msr     spsr_el1, x1
        \\        ldr     x1, [sp, #264]
        \\        msr     sp_el0, x1
        \\        ldp     x2, x3, [sp, #16]
        \\        ldp     x4, x5, [sp, #32]
        \\        ldp     x6, x7, [sp, #48]
        \\        ldp     x8, x9, [sp, #64]
        \\        ldp     x10, x11, [sp, #80]
        \\        ldp     x12, x13, [sp, #96]
        \\        ldp     x14, x15, [sp, #112]
        \\        ldp     x16, x17, [sp, #128]
        \\        ldp     x18, x19, [sp, #144]
        \\        ldp     x20, x21, [sp, #160]
        \\        ldp     x22, x23, [sp, #176]
        \\        ldp     x24, x25, [sp, #192]
        \\        ldp     x26, x27, [sp, #208]
        \\        ldp     x28, x29, [sp, #224]
        \\        ldr     x30, [sp, #240]
        \\        ldp     x0, x1, [sp]
        \\        add     sp, sp, #272
        \\        eret
    );
}

extern const __vectors: anyopaque;

pub fn init() void {
    asm volatile ("msr vbar_el1, %[addr]"
        :
        : [addr] "r" (@intFromPtr(&__vectors)),
    );
    // FPEN = 0b11: FP/SIMD untrapped at EL0 and EL1. Userspace owns the
    // vector unit (NEON + hardware AES); the kernel is compiled without
    // FP features and touches the registers only in the scheduler's
    // save/restore stubs (which need the EL1 permission this grants).
    asm volatile (
        \\mrs x8, cpacr_el1
        \\orr x8, x8, #(0x3 << 20)
        \\msr cpacr_el1, x8
        ::: .{ .x8 = true });
    asm volatile ("isb");
}

pub fn enableIrqs() void {
    asm volatile ("msr daifclr, #2");
}

const Kind = enum(u64) {
    cur_sp0_sync,
    cur_sp0_irq,
    cur_sp0_fiq,
    cur_sp0_serror,
    cur_spx_sync,
    cur_spx_irq,
    cur_spx_fiq,
    cur_spx_serror,
    lower64_sync,
    lower64_irq,
    lower64_fiq,
    lower64_serror,
    lower32_sync,
    lower32_irq,
    lower32_fiq,
    lower32_serror,
};

export fn trapHandler(frame: *TrapFrame, kind_raw: u64) callconv(.c) void {
    const kind: Kind = @enumFromInt(kind_raw);
    switch (kind) {
        .cur_spx_irq, .lower64_irq => handleIrq(),
        .lower64_sync => handleUserSync(frame),
        else => reportFault(frame, kind),
    }
}

fn handleIrq() void {
    const intid = gic.acknowledge();
    if (intid == gic.spurious_intid) return;
    if (intid == timer.intid) {
        timer.handleIrq();
    } else if (intid == gic.resched_sgi) {
        // just here for the preempt below
    } else if (!(intid >= 32 and (smmu.handleIrq(intid) or irq.deliver(intid)))) {
        log.warn("unexpected interrupt {d}", .{intid});
    }
    // EOI before any context switch: a preempted-away thread must not hold
    // this core's active-interrupt state hostage.
    gic.endOfInterrupt(intid);
    sched.preemptIfNeeded();
}

/// Synchronous exception from EL0: a syscall, or a fault that kills the
/// domain (fault-as-message to a supervisor arrives with IPC in Phase 4).
fn handleUserSync(frame: *TrapFrame) void {
    const esr = asm ("mrs %[v], esr_el1"
        : [v] "=r" (-> u64),
    );
    const ec: u8 = @truncate(esr >> 26);
    if (ec == 0x15) {
        syscall.dispatch(frame);
        // A syscall may have made someone runnable on this core (e.g. a
        // reply waking a caller): honor it before returning to EL0.
        sched.preemptIfNeeded();
        return;
    }
    const far = asm ("mrs %[v], far_el1"
        : [v] "=r" (-> u64),
    );
    const t = sched.thisCpu().current;
    const d: *domain.Domain = @ptrCast(@alignCast(t.user_ctx.?));
    d.exit_code = 0xdead;
    // Fault-as-message: a supervised domain's faults go to its supervisor,
    // which decides its fate; only unsupervised domains are killed here.
    if (domain.reportFaultToSupervisor(d, esr, far, frame.elr)) unreachable;
    log.warn("domain {s}: fault at EL0 — {s} (esr=0x{x} far=0x{x} elr=0x{x}); killing it", .{
        d.name, ecName(ec), esr, far, frame.elr,
    });
    domain.destroy(d);
    sched.exit();
}

fn reportFault(frame: *TrapFrame, kind: Kind) noreturn {
    const esr = asm ("mrs %[v], esr_el1"
        : [v] "=r" (-> u64),
    );
    const far = asm ("mrs %[v], far_el1"
        : [v] "=r" (-> u64),
    );
    const ec: u8 = @truncate(esr >> 26);

    log.print("\n!! EXCEPTION: {t} — {s}\n", .{ kind, ecName(ec) });
    log.print("!! esr=0x{x:0>16} (ec=0x{x}, iss=0x{x}) far=0x{x:0>16}\n", .{
        esr, ec, esr & 0x1ffffff, far,
    });
    log.print("!! elr=0x{x:0>16} spsr=0x{x:0>16}\n", .{ frame.elr, frame.spsr });
    // The top of the current thread's stack: a foreign exception frame
    // there (an SPSR-looking word, an ELR) names whoever ran on it.
    const cur = sched.thisCpu().current;
    if (cur.stack_pa != 0) {
        const top = mem.physToVirt(cur.stack_pa) + sched.stack_pages * mem.page_size;
        const words: [*]const u64 = @ptrFromInt(top - 0x120);
        log.print("!! thread {s} stack top 0x{x}:", .{ cur.name, top });
        for (0..36) |i| {
            if (i % 4 == 0) log.print("\n!!  -0x{x:0>3}:", .{0x120 - i * 8});
            log.print(" {x:0>16}", .{words[i]});
        }
        log.print("\n", .{});
    }
    var i: usize = 0;
    while (i < 31) : (i += 4) {
        log.print("!!", .{});
        var j: usize = i;
        while (j < @min(i + 4, 31)) : (j += 1) {
            log.print("  x{d:<2}=0x{x:0>16}", .{ j, frame.regs[j] });
        }
        log.print("\n", .{});
    }
    @panic("unhandled kernel exception");
}

fn ecName(ec: u8) []const u8 {
    return switch (ec) {
        0x00 => "unknown reason",
        0x07 => "FP/SIMD access trapped (kernel code must not use FP)",
        0x0e => "illegal execution state",
        0x15 => "SVC from AArch64",
        0x18 => "system register trap",
        0x20 => "instruction abort, lower EL",
        0x21 => "instruction abort, same EL",
        0x22 => "PC alignment fault",
        0x24 => "data abort, lower EL",
        0x25 => "data abort, same EL",
        0x26 => "SP alignment fault",
        0x2c => "FP exception",
        0x2f => "SError",
        0x30, 0x31 => "breakpoint",
        0x3c => "BRK instruction",
        else => "unrecognized exception class",
    };
}
