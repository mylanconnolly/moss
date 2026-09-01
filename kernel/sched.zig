//! Kernel threads and the per-core scheduler.
//!
//! Structurally SMP-honest: every core owns a run queue and an idle thread,
//! reachable through TPIDR_EL1, and nothing assumes a single core. The
//! *locking* is still a big kernel lock over all scheduler state — fine at
//! this scale, revisited when it shows up in measurements.
//!
//! Preemption: the timer tick sets need_resched; the trap handler calls
//! preempt() after EOI. Context switches happen inside the IRQ handler on
//! the interrupted thread's kernel stack, so its trap frame simply waits on
//! that stack until the thread is next scheduled and the handler unwinds.
//!
//! Threads may carry a user address space (TTBR0 root + ASID): switching to
//! such a thread programs TTBR0 and enables its walks; switching to a pure
//! kernel thread disables TTBR0 walks entirely (TCR.EPD0) so no stale user
//! mappings are ever reachable from kernel-only contexts.
//!
//! Rules for this module: schedule() is entered with the big lock held and
//! IRQs masked; every resume point after a context switch (schedule's return
//! or the new-thread trampoline) must reap any exited predecessor and
//! release the lock. No logging while holding the big lock.

const std = @import("std");
const cap = @import("cap.zig");
const gic = @import("gic.zig");
const kalloc = @import("kalloc.zig");
const lock = @import("lock.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");

pub const max_cpus = 8;
const max_threads = 64;
const stack_pages = 4;

pub const Error = error{
    NoThreadSlots,
    OutOfFrames,
    QuotaExceeded,
};

const Context = extern struct {
    // x19..x28, x29 (fp), x30 (lr), then sp.
    regs: [12]u64 = @splat(0),
    sp: u64 = 0,
};

/// EL0 FP/SIMD state (v0-v31 + fpsr/fpcr), saved EAGERLY at context switch
/// for user threads only — kernel threads are FP-free by construction (the
/// kernel is built without FP/NEON features), so their switches skip this
/// entirely and user FP registers survive syscalls untouched in hardware.
/// Zero-initialized at spawn: a fresh thread restores zeros and can never
/// observe another domain's vector registers.
const FpState = extern struct {
    v: [32][16]u8 align(16) = @splat(@splat(0)),
    fpsr: u64 = 0,
    fpcr: u64 = 0,
};

pub const State = enum {
    unused,
    ready,
    running,
    sleeping,
    /// Parked on an IPC object (channel queue, single waiter slot, ...).
    /// Exactly one of block_list/block_slot says where, so teardown can
    /// always unlink.
    blocked,
    exited,
};

pub const Thread = struct {
    ctx: Context = .{},
    fp: FpState = .{},
    id: u32 = 0,
    name: []const u8 = "",
    state: State = .unused,
    /// Pinned core, or null to balance round-robin on every enqueue —
    /// which also makes unpinned threads migrate, exercising SMP paths.
    affinity: ?u32 = null,
    stack_pa: u64 = 0,
    stack_account: *kalloc.Account = &kalloc.kernel_account,
    /// CPU budget accounting stub: consumed timer ticks. Domains attach
    /// real budgets here in Phase 3+.
    cpu_ticks: u64 = 0,
    wake_tick: u64 = 0,
    /// User address space, or 0 for kernel-only threads.
    user_ttbr0: u64 = 0,
    asid: u16 = 0,
    /// Owning domain (opaque here to avoid an import cycle).
    user_ctx: ?*anyopaque = null,
    /// The domain's capability table (same for all its threads); lets IPC
    /// translate caps without reaching into domain internals.
    captable: ?*cap.Table = null,
    /// Where the thread currently is; exactly one is non-null unless the
    /// thread is sleeping (then it sits in the sleepers list) or exited.
    on_cpu: ?u32 = null,
    queued_on: ?u32 = null,
    /// IPC mailbox: message words, an optional cap in transit, and the
    /// status the blocked operation completed with.
    ipc_data: [4]u64 = @splat(0),
    ipc_cap_type: u8 = 0,
    ipc_cap_obj: u64 = 0,
    ipc_cap_badge: u64 = 0,
    /// The badge of the channel_b cap the caller used (delivered to recv).
    ipc_badge: u64 = 0,
    ipc_status: u64 = 0,
    /// While .blocked: the queue or single-waiter slot holding this thread.
    block_list: ?*std.DoublyLinkedList = null,
    block_slot: ?*?*Thread = null,
    /// Blocked inside recv, interruptible by a bound notification.
    in_recv: bool = false,
    /// The notification bound to this thread (an *ipc.Notification; opaque
    /// to avoid an import cycle). recv checks its latched bits before
    /// blocking so a signal can never be lost between recvs.
    bound_notif: ?*anyopaque = null,
    node: std.DoublyLinkedList.Node = .{},
};

pub const SpawnOpts = struct {
    affinity: ?u32 = null,
    user_ttbr0: u64 = 0,
    asid: u16 = 0,
    user_ctx: ?*anyopaque = null,
    captable: ?*cap.Table = null,
    stack_account: *kalloc.Account = &kalloc.kernel_account,
};

pub const PerCpu = struct {
    id: u32,
    current: *Thread,
    idle: *Thread,
    queue: std.DoublyLinkedList = .{},
    reap: ?*Thread = null,
    need_resched: bool = false,
    online: bool = false,
    ticks: u64 = 0, // debug
};

var cpus: [max_cpus]PerCpu = undefined;
var threads: [max_threads]Thread = @splat(.{});
var sleepers: std.DoublyLinkedList = .{};
var big_lock: lock.SpinLock = .{};
var next_thread_id: u32 = 1;
var balance_next: u32 = 0;
var global_ticks: u64 = 0;

/// Invoked (under the big lock — keep it lock-light) when a thread owned by
/// a user context has been fully reaped.
pub var user_thread_reaped: ?*const fn (*anyopaque) void = null;

pub fn thisCpu() *PerCpu {
    return @ptrFromInt(asm ("mrs %[v], tpidr_el1"
        : [v] "=r" (-> u64),
    ));
}

/// Register the calling core: its current execution context becomes the
/// core's idle thread. Called once per core before that core enables IRQs.
pub fn registerCpu(cpu_id: u32) void {
    const daif = big_lock.lockIrqSave();
    const idle = allocThreadSlotLocked() catch @panic("no thread slot for idle");
    idle.name = "idle";
    idle.state = .running;
    idle.affinity = cpu_id;
    idle.on_cpu = cpu_id;
    const cpu = &cpus[cpu_id];
    cpu.* = .{ .id = cpu_id, .current = idle, .idle = idle, .online = true };
    big_lock.unlockRestore(daif);
    asm volatile ("msr tpidr_el1, %[v]"
        :
        : [v] "r" (@intFromPtr(cpu)),
    );
}

pub fn uptimeTicks() u64 {
    return global_ticks;
}

pub fn onlineCount() u32 {
    var n: u32 = 0;
    for (&cpus) |*cpu| {
        if (cpu.online) n += 1;
    }
    return n;
}

pub fn spawn(name: []const u8, entry: *const fn (u64) void, arg: u64, opts: SpawnOpts) Error!*Thread {
    const stack_pa = pmem.allocContiguous(stack_pages) orelse return Error.OutOfFrames;
    errdefer pmem.freeContiguous(stack_pa, stack_pages);
    try opts.stack_account.charge(stack_pages * mem.page_size);
    errdefer opts.stack_account.credit(stack_pages * mem.page_size);

    const daif = big_lock.lockIrqSave();
    defer big_lock.unlockRestore(daif);

    const t = try allocThreadSlotLocked();
    t.name = name;
    t.affinity = opts.affinity;
    t.stack_pa = stack_pa;
    t.stack_account = opts.stack_account;
    t.user_ttbr0 = opts.user_ttbr0;
    t.asid = opts.asid;
    t.user_ctx = opts.user_ctx;
    t.captable = opts.captable;
    // New threads begin in the trampoline, which unlocks the scheduler and
    // enables IRQs, then calls entry(arg) through a C-ABI shim.
    t.ctx = .{ .sp = mem.physToVirt(stack_pa) + stack_pages * mem.page_size };
    t.ctx.regs[0] = @intFromPtr(entry); // x19
    t.ctx.regs[1] = arg; // x20
    t.ctx.regs[11] = @intFromPtr(&__thread_trampoline); // x30
    enqueueLocked(t);
    return t;
}

/// Give up the CPU voluntarily; the thread re-enters its queue (possibly on
/// another core, if unpinned).
pub fn yield() void {
    const daif = big_lock.lockIrqSave();
    defer big_lock.unlockRestore(daif);
    scheduleLocked();
}

/// Sleep for at least `ticks` timer ticks.
pub fn sleep(ticks: u64) void {
    const daif = big_lock.lockIrqSave();
    defer big_lock.unlockRestore(daif);
    const cpu = thisCpu();
    const t = cpu.current;
    std.debug.assert(t != cpu.idle); // the idle thread never sleeps
    // Teardown race: destroyThreadsOf may have marked this (then-running)
    // thread exited from another core while it was entering this syscall.
    // Overwriting that with .sleeping would resurrect it into the sleepers
    // list and the domain would never drain. Die here instead.
    if (t.state == .exited) {
        scheduleLocked(); // never returns: exited threads are reaped
        unreachable;
    }
    t.state = .sleeping;
    t.wake_tick = global_ticks + ticks;
    sleepers.append(&t.node);
    scheduleLocked();
}

pub fn exit() noreturn {
    _ = big_lock.lockIrqSave(); // this context never resumes
    const cpu = thisCpu();
    cpu.current.state = .exited;
    scheduleLocked();
    unreachable;
}

/// Kill every thread belonging to `ctx` (domain teardown). Threads not
/// currently running are freed immediately (unlinked from run queues,
/// sleepers, or whatever IPC object they block on); running ones are marked
/// exited and their cores nudged, so they die at the next preemption and
/// are reaped (each reap invokes user_thread_reaped). Returns how many were
/// freed on the spot.
pub fn destroyThreadsOf(ctx: *anyopaque) u32 {
    const daif = big_lock.lockIrqSave();
    defer big_lock.unlockRestore(daif);
    const self_cpu = thisCpu().id;
    var freed: u32 = 0;
    for (&threads) |*t| {
        if (t.state == .unused or t.user_ctx != ctx) continue;
        switch (t.state) {
            .ready => {
                cpus[t.queued_on.?].queue.remove(&t.node);
                freeThreadLocked(t);
                freed += 1;
            },
            .sleeping => {
                sleepers.remove(&t.node);
                freeThreadLocked(t);
                freed += 1;
            },
            .blocked => {
                if (t.block_list) |l| l.remove(&t.node);
                if (t.block_slot) |s| s.* = null;
                freeThreadLocked(t);
                freed += 1;
            },
            .running => {
                t.state = .exited;
                const c = t.on_cpu.?;
                cpus[c].need_resched = true;
                if (c != self_cpu) gic.sendSgi(c);
            },
            .exited, .unused => {},
        }
    }
    return freed;
}

/// Expose the big lock to IPC: channel state and scheduling share one lock
/// (the big-kernel-lock era), so wait/wake transitions are race-free.
pub fn acquire() u64 {
    return big_lock.lockIrqSave();
}

pub fn release(daif: u64) void {
    big_lock.unlockRestore(daif);
}

/// Park the current thread on a wait queue or single-waiter slot. Big lock
/// held. Returns when someone wakes the thread; its mailbox then holds the
/// operation's outcome.
pub fn blockCurrentLocked(list: ?*std.DoublyLinkedList, slot: ?*?*Thread) void {
    const t = thisCpu().current;
    std.debug.assert(t != thisCpu().idle);
    // Same teardown race as sleep(): a concurrent destroy may have marked
    // this thread exited; parking it would overwrite that and leak it into
    // an IPC wait structure. Die instead.
    if (t.state == .exited) {
        scheduleLocked(); // never returns
        unreachable;
    }
    t.state = .blocked;
    t.block_list = list;
    t.block_slot = slot;
    if (list) |l| l.append(&t.node);
    if (slot) |s| s.* = t;
    scheduleLocked();
    t.block_list = null;
    t.block_slot = null;
}

/// Wake a blocked thread the caller has already unlinked (popped from its
/// queue / cleared from its slot). Big lock held.
pub fn wakeLocked(t: *Thread) void {
    std.debug.assert(t.state == .blocked);
    t.block_list = null;
    t.block_slot = null;
    enqueueLocked(t);
}

/// Timer-tick hook, called from IRQ context (IRQs masked) on every core.
/// Core 0 additionally advances global time and wakes due sleepers.
pub fn onTick(is_timekeeper: bool) void {
    const daif = big_lock.lockIrqSave();
    defer big_lock.unlockRestore(daif);
    const cpu = thisCpu();
    cpu.current.cpu_ticks += 1;
    cpu.ticks += 1;

    if (is_timekeeper) {
        global_ticks += 1;
        var it = sleepers.first;
        while (it) |node| {
            const next = node.next;
            const t: *Thread = @alignCast(@fieldParentPtr("node", node));
            if (t.wake_tick <= global_ticks) {
                sleepers.remove(node);
                t.state = .ready;
                enqueueLocked(t);
            }
            it = next;
        }
    }

    // Round-robin: preempt whenever someone else is waiting for this core.
    if (cpu.queue.first != null) cpu.need_resched = true;
}

/// Called by the trap handler after EOI when returning from an interrupt.
pub fn preemptIfNeeded() void {
    const cpu = thisCpu();
    if (!cpu.need_resched) return;
    const daif = big_lock.lockIrqSave();
    defer big_lock.unlockRestore(daif);
    cpu.need_resched = false;
    scheduleLocked();
}

pub fn currentName() []const u8 {
    return thisCpu().current.name;
}

/// Debug: log every live thread and where it is.
pub fn debugDump() void {
    for (&threads) |*t| {
        if (t.state == .unused) continue;
        log.info("thread {s}#{d}: {t} in_recv={} list={} slot={} cpu={?d} q={?d}", .{
            t.name,              t.id,
            t.state,             t.in_recv,
            t.block_list != null, t.block_slot != null,
            t.on_cpu,            t.queued_on,
        });
    }
    for (&cpus) |*c| {
        if (!c.online) continue;
        var qlen: usize = 0;
        var it = c.queue.first;
        while (it) |node| : (it = node.next) qlen += 1;
        log.info("cpu{d}: qlen={d} need_resched={} current={s} ticks={d}", .{
            c.id, qlen, c.need_resched, c.current.name, c.ticks,
        });
    }
}

pub fn ticksOfCurrent() u64 {
    return thisCpu().current.cpu_ticks;
}

fn allocThreadSlotLocked() Error!*Thread {
    for (&threads) |*t| {
        if (t.state == .unused) {
            t.* = .{ .id = next_thread_id, .state = .ready };
            next_thread_id += 1;
            return t;
        }
    }
    return Error.NoThreadSlots;
}

fn enqueueLocked(t: *Thread) void {
    t.state = .ready;
    const target = t.affinity orelse blk: {
        // Round-robin across online cores on every enqueue.
        var tries: u32 = 0;
        while (tries < max_cpus) : (tries += 1) {
            const c = balance_next % max_cpus;
            balance_next +%= 1;
            if (cpus[c].online) break :blk c;
        }
        break :blk 0;
    };
    t.queued_on = target;
    cpus[target].queue.append(&t.node);
    // Kick the target so wakeups run in microseconds, not at the next
    // 100ms tick: another core gets an SGI (leaving wfi -> preempt path);
    // our own core is handled at the next preempt point (IRQ exit or
    // syscall return).
    cpus[target].need_resched = true;
    if (&cpus[target] != thisCpu()) {
        gic.sendSgi(target);
    }
}

/// Core scheduling decision. Big lock held, IRQs masked.
fn scheduleLocked() void {
    const cpu = thisCpu();
    const prev = cpu.current;

    const next: *Thread = if (cpu.queue.popFirst()) |node|
        @as(*Thread, @alignCast(@fieldParentPtr("node", node)))
    else if (prev.state == .running)
        return // nothing else to run, keep going
    else
        cpu.idle;

    if (next == prev) return;

    switch (prev.state) {
        .running => {
            prev.on_cpu = null;
            if (prev != cpu.idle) enqueueLocked(prev);
        },
        .exited => {
            prev.on_cpu = null;
            cpu.reap = prev;
        },
        .sleeping, .blocked => prev.on_cpu = null,
        .ready, .unused => {},
    }
    next.state = .running;
    next.queued_on = null;
    next.on_cpu = cpu.id;
    cpu.current = next;
    programUserSpace(next);
    // Vector state travels with user threads (see FpState). Exited
    // threads skip the save — their state is about to be reaped.
    if (prev.user_ttbr0 != 0 and prev.state != .exited) __fp_save(&prev.fp);
    if (next.user_ttbr0 != 0) __fp_restore(&next.fp);
    __context_switch(&prev.ctx, &next.ctx);
    // We are back on this thread, possibly much later, still under the big
    // lock taken by whoever switched to us.
    reapLocked();
}

/// Program TTBR0 for the incoming thread: its domain's tables (walks
/// enabled), or no user space at all for kernel threads (walks disabled via
/// TCR.EPD0 — kernel-only contexts can never reach stale user mappings).
fn programUserSpace(t: *Thread) void {
    const epd0: u64 = 1 << 7;
    const tcr = asm ("mrs %[v], tcr_el1"
        : [v] "=r" (-> u64),
    );
    if (t.user_ttbr0 != 0) {
        asm volatile (
            \\msr ttbr0_el1, %[ttbr]
            \\msr tcr_el1, %[tcr]
            \\isb
            :
            : [ttbr] "r" (t.user_ttbr0 | (@as(u64, t.asid) << 48)),
              [tcr] "r" (tcr & ~epd0),
        );
    } else if (tcr & epd0 == 0) {
        asm volatile (
            \\msr tcr_el1, %[tcr]
            \\isb
            :
            : [tcr] "r" (tcr | epd0),
        );
    }
}

fn freeThreadLocked(t: *Thread) void {
    pmem.freeContiguous(t.stack_pa, stack_pages);
    t.stack_account.credit(stack_pages * mem.page_size);
    t.* = .{};
}

fn reapLocked() void {
    const cpu = thisCpu();
    if (cpu.reap) |dead| {
        cpu.reap = null;
        const ctx = dead.user_ctx;
        freeThreadLocked(dead);
        if (ctx) |c| {
            if (user_thread_reaped) |cb| cb(c);
        }
    }
}

/// First code run by a new thread, called from the trampoline with the big
/// lock still held and IRQs masked.
export fn schedThreadStart() callconv(.c) void {
    reapLocked();
    big_lock.unlock();
    asm volatile ("msr daifclr, #2");
}

/// C-ABI shim between the trampoline and the entry function: the entry
/// pointer uses Zig's unspecified calling convention (hidden parameters in
/// Debug builds included), so the call must be emitted by the compiler, not
/// hand-written in the trampoline's assembly.
export fn schedThreadRun(entry_raw: u64, arg: u64) callconv(.c) noreturn {
    const entry: *const fn (u64) void = @ptrFromInt(entry_raw);
    entry(arg);
    exit();
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
