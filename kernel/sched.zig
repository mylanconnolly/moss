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
//! Locking (no big lock): every core's run queue has its own lock, every
//! thread its own, sleepers theirs, and IPC objects theirs. A thread's
//! state is protected by the run-queue lock of the core it is queued on
//! or running on, and by its own lock while it is blocked or sleeping;
//! anyone else who wants to change it takes the thread lock first to
//! discover which. Order, outer to inner: IPC object → thread → run
//! queue → sleepers; the thread table lock is a leaf for slot alloc and
//! free. A blocking thread releases the object lock only after it holds
//! its run-queue lock, so a waker can never slip between "not yet in the
//! wait list" and "switched away"; a thread still switching away carries
//! `switching`, and whoever dequeues or frees it waits for that to clear.
//! schedule() is entered with the local run-queue lock held and IRQs
//! masked and always returns with the lock released — directly, or via
//! finishSwitch() at the resume point (schedule's return or the
//! new-thread trampoline), which also reaps an exited predecessor. No
//! logging while holding any of these.

const std = @import("std");
const vm = @import("vm.zig");
const ipc = @import("ipc.zig");
const cap = @import("cap.zig");
const gic = @import("gic.zig");
const kalloc = @import("kalloc.zig");
const lock = @import("lock.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");

pub const max_cpus = 8;
const max_threads = 64;
/// Kernel stacks (kernel threads and every user thread's syscall stack):
/// 32K. Debug builds spend freely — a formatted log line is over a
/// kilobyte of frames — and an overflow lands in a neighbour's stack.
pub const stack_pages = 8;

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
pub const FpState = extern struct {
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
    /// A domain partition: the cores this thread may be placed on (0 =
    /// any core not reserved by another domain).
    cpu_mask: u64 = 0,
    /// Cycle count when this thread was last dispatched, for charging.
    run_start: u64 = 0,
    /// Parked on a core's throttled list (its domain is over budget) or
    /// its evict list (it may no longer be placed on that core).
    park: Park = .none,
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
    /// The lock of the object this thread is blocked on (a channel's or a
    /// notification's): whoever wants to unlink it — teardown, a bound
    /// notification's interrupt — takes that first, then the thread.
    block_lock: ?*lock.SpinLock = null,
    /// Linked into the sleepers list (under sleepers_lock).
    in_sleepers: bool = false,
    /// Set by the core switching away from this thread until its
    /// registers are saved (cleared by finishSwitch on the other side).
    switching: std.atomic.Value(bool) = .init(false),
    lock: lock.SpinLock = .{},
    node: std.DoublyLinkedList.Node = .{},
};

pub const Park = enum(u8) { none, throttled, evicted };

pub const SpawnOpts = struct {
    affinity: ?u32 = null,
    cpu_mask: u64 = 0,
    user_ttbr0: u64 = 0,
    asid: u16 = 0,
    user_ctx: ?*anyopaque = null,
    captable: ?*cap.Table = null,
    stack_account: *kalloc.Account = &kalloc.kernel_account,
};

pub const PerCpu = struct {
    /// Cache-line aligned: each core hammers its own lock and queue, and a
    /// neighbour's line bouncing between cores would cost the scaling.
    id: u32 align(128),
    current: *Thread,
    idle: *Thread,
    queue: std.DoublyLinkedList = .{},
    /// Threads of domains over their CPU budget, parked until the period
    /// resets (under this core's lock, like the queue).
    throttled: std.DoublyLinkedList = .{},
    /// Threads that may no longer run on this core (a partition claimed
    /// it): re-placed elsewhere at this core's next tick.
    evict: std.DoublyLinkedList = .{},
    /// A partition: this core is reserved for one domain's threads
    /// (and the idle thread); nothing else is placed here.
    reserved_by: ?*anyopaque = null,
    /// The thread this core last switched away from; finishSwitch clears
    /// its `switching` (or reaps it) on the other side of the switch.
    prev: ?*Thread = null,
    need_resched: bool = false,
    online: bool = false,
    ticks: u64 = 0, // debug
    lock: lock.SpinLock = .{},
    /// The vCPU this core is running right now (a *vm.Vcpu), and the
    /// one it ran last (whose virtual timer may still fire here).
    vcpu: ?*anyopaque = null,
    last_vcpu: ?*anyopaque = null,
};

var cpus: [max_cpus]PerCpu = undefined;
var threads: [max_threads]Thread = @splat(.{});
var threads_lock: lock.SpinLock = .{};
var sleepers: std.DoublyLinkedList = .{};
var sleepers_lock: lock.SpinLock = .{};
var next_thread_id: u32 = 1;
var balance_next: u32 = 0;
var global_ticks: u64 = 0;

/// Invoked (under the big lock — keep it lock-light) when a thread owned by
/// a user context has been fully reaped.
pub var user_thread_reaped: ?*const fn (*anyopaque) void = null;

/// The per-core pointer lives in TPIDR_EL1 at EL1 and in TPIDR_EL2 as
/// the EL2 host — TPIDR_EL1 is one of the few registers VHE does not
/// redirect, and a guest at EL1 owns it.
pub var host_el2: bool = false;

pub fn thisCpu() *PerCpu {
    if (host_el2) {
        return @ptrFromInt(asm ("mrs %[v], tpidr_el2"
            : [v] "=r" (-> u64),
        ));
    }
    return @ptrFromInt(asm ("mrs %[v], tpidr_el1"
        : [v] "=r" (-> u64),
    ));
}

/// Register the calling core: its current execution context becomes the
/// core's idle thread. Called once per core before that core enables IRQs.
pub fn registerCpu(cpu_id: u32) void {
    const daif = threads_lock.lockIrqSave();
    const idle = allocThreadSlotLocked() catch @panic("no thread slot for idle");
    idle.name = "idle";
    idle.state = .running;
    idle.affinity = cpu_id;
    idle.on_cpu = cpu_id;
    const cpu = &cpus[cpu_id];
    cpu.* = .{ .id = cpu_id, .current = idle, .idle = idle, .online = true };
    threads_lock.unlockRestore(daif);
    const el = asm ("mrs %[el], CurrentEL"
        : [el] "=r" (-> u64),
    ) >> 2;
    if (el == 2) {
        host_el2 = true;
        asm volatile ("msr tpidr_el2, %[v]"
            :
            : [v] "r" (@intFromPtr(cpu)),
        );
    }
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

    const daif = threads_lock.lockIrqSave();
    const t = allocThreadSlotLocked() catch |e| {
        threads_lock.unlockRestore(daif);
        return e;
    };
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
    t.cpu_mask = opts.cpu_mask;
    threads_lock.unlock();
    t.lock.lock();
    enqueueLocked(t);
    t.lock.unlock();
    restoreIrqs(daif);
    return t;
}

fn restoreIrqs(daif: u64) void {
    asm volatile ("msr daif, %[v]"
        :
        : [v] "r" (daif),
    );
}

fn maskIrqs() u64 {
    const daif = asm ("mrs %[v], daif"
        : [v] "=r" (-> u64),
    );
    asm volatile ("msr daifset, #2");
    return daif;
}

/// Give up the CPU voluntarily; the thread re-enters its queue (possibly on
/// another core, if unpinned).
pub fn yield() void {
    const daif = maskIrqs();
    thisCpu().lock.lock();
    scheduleLocked();
    restoreIrqs(daif);
}

/// Sleep for at least `ticks` timer ticks.
pub fn sleep(ticks: u64) void {
    const daif = maskIrqs();
    const cpu = thisCpu();
    const t = cpu.current;
    std.debug.assert(t != cpu.idle); // the idle thread never sleeps
    t.lock.lock();
    cpu.lock.lock();
    // Teardown race: destroyThreadsOf may have marked this (then-running)
    // thread exited from another core while it was entering this syscall.
    // Overwriting that with .sleeping would resurrect it into the sleepers
    // list and the domain would never drain. Die here instead.
    if (t.state == .exited) {
        t.lock.unlock();
        scheduleLocked(); // never returns: exited threads are reaped
        unreachable;
    }
    t.state = .sleeping;
    t.wake_tick = global_ticks + ticks;
    // Raised before anyone can find us asleep: a tick that wakes us onto
    // another core must wait for this core to save our registers.
    t.switching.store(true, .release);
    sleepers_lock.lock();
    sleepers.append(&t.node);
    t.in_sleepers = true;
    sleepers_lock.unlock();
    t.lock.unlock();
    scheduleLocked();
    restoreIrqs(daif);
}

pub fn exit() noreturn {
    _ = maskIrqs(); // this context never resumes
    const cpu = thisCpu();
    cpu.lock.lock();
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
    const daif = maskIrqs();
    defer restoreIrqs(daif);
    var freed: u32 = 0;
    for (&threads) |*t| {
        if (@atomicLoad(State, &t.state, .acquire) == .unused or t.user_ctx != ctx) continue;
        if (destroyOne(t, ctx)) freed += 1;
    }
    return freed;
}

/// Tear down one thread of a dying domain. Every step peeks without
/// locks, then takes the locks in order and re-verifies; a transition
/// caught mid-flight (a stale object lock, a thread between queue and
/// core) is simply retried. Returns true if the thread was freed here
/// (a running thread is only marked; its core reaps it).
fn destroyOne(t: *Thread, ctx: *anyopaque) bool {
    const self_cpu = thisCpu().id;
    while (true) {
        // Blocked threads are unlinked under the object's lock, which is
        // taken before the thread's; read the object first, verify after.
        const bl = @atomicLoad(?*lock.SpinLock, &t.block_lock, .acquire);
        if (bl) |l| l.lock();
        t.lock.lock();
        if (t.user_ctx != ctx or t.state == .exited or t.state == .unused) {
            t.lock.unlock();
            if (bl) |l| l.unlock();
            return false;
        }
        if (t.block_lock != bl) {
            t.lock.unlock();
            if (bl) |l| l.unlock();
            std.atomic.spinLoopHint();
            continue;
        }
        switch (t.state) {
            .blocked => {
                if (t.block_list) |l| l.remove(&t.node);
                if (t.block_slot) |sl| sl.* = null;
                t.block_list = null;
                t.block_slot = null;
                t.block_lock = null;
                t.lock.unlock();
                bl.?.unlock();
                waitSwitched(t);
                // A cap it sent that nobody received (parked in a caller
                // queue, or a reply nobody will collect): its ref dies here.
                if (t.ipc_cap_type != 0) {
                    ipc.releaseCap(@enumFromInt(t.ipc_cap_type), t.ipc_cap_obj);
                    t.ipc_cap_type = 0;
                    t.ipc_cap_obj = 0;
                }
                freeThread(t);
                return true;
            },
            .sleeping => {
                sleepers_lock.lock();
                const ours = t.in_sleepers;
                if (ours) {
                    sleepers.remove(&t.node);
                    t.in_sleepers = false;
                } else {
                    // The tick has it in hand: it will see exited and
                    // free it.
                    t.state = .exited;
                }
                sleepers_lock.unlock();
                t.lock.unlock();
                if (!ours) return false;
                waitSwitched(t);
                freeThread(t);
                return true;
            },
            .ready, .running => {
                // Its run queue's (or core's) lock serializes with that
                // core's pick and preempt.
                if (t.queued_on) |q| {
                    const rq = &cpus[q];
                    rq.lock.lock();
                    if (t.queued_on == q) {
                        switch (t.park) {
                            .none => rq.queue.remove(&t.node),
                            .throttled => rq.throttled.remove(&t.node),
                            .evicted => rq.evict.remove(&t.node),
                        }
                        t.park = .none;
                        t.queued_on = null;
                        t.state = .exited;
                        rq.lock.unlock();
                        t.lock.unlock();
                        waitSwitched(t);
                        freeThread(t);
                        return true;
                    }
                    rq.lock.unlock();
                } else if (t.on_cpu) |c| {
                    const rq = &cpus[c];
                    rq.lock.lock();
                    if (rq.current == t) {
                        t.state = .exited;
                        rq.need_resched = true;
                        rq.lock.unlock();
                        t.lock.unlock();
                        if (c != self_cpu) gic.sendSgi(c);
                        return false;
                    }
                    rq.lock.unlock();
                }
                // Between a queue and a core: let it land, then retry.
                t.lock.unlock();
                std.atomic.spinLoopHint();
                continue;
            },
            .exited, .unused => unreachable,
        }
    }
}

/// Park the current thread on a wait queue or single-waiter slot of the
/// object whose lock `obj` the caller holds (IRQs masked), plus an
/// optional outer lock `outer` the caller also holds (a bound
/// notification's, taken before the channel's: the latched-bits peek and
/// the park must be one atomic step against signal). Both are released
/// here, after the run-queue lock is held, and are NOT held on return.
/// Returns when someone wakes the thread; its mailbox then holds the
/// operation's outcome.
pub fn block(list: ?*std.DoublyLinkedList, slot: ?*?*Thread, obj: *lock.SpinLock, outer: ?*lock.SpinLock) void {
    const cpu = thisCpu();
    const t = cpu.current;
    std.debug.assert(t != cpu.idle);
    t.lock.lock();
    cpu.lock.lock();
    // Same teardown race as sleep(): a concurrent destroy may have marked
    // this thread exited; parking it would overwrite that and leak it into
    // an IPC wait structure. Die instead.
    if (t.state == .exited) {
        t.lock.unlock();
        obj.unlock();
        if (outer) |o| o.unlock();
        scheduleLocked(); // never returns
        unreachable;
    }
    t.state = .blocked;
    t.block_list = list;
    t.block_slot = slot;
    t.block_lock = obj;
    // Raised before the object lock is released: a waker on another core
    // may enqueue us the instant it sees us blocked, and whoever dequeues
    // us must not run us until this core has saved our registers.
    t.switching.store(true, .release);
    if (list) |l| l.append(&t.node);
    if (slot) |sl| sl.* = t;
    t.lock.unlock();
    // From here a waker can find us; it waits for `switching` to clear
    // before running us anywhere.
    obj.unlock();
    if (outer) |o| o.unlock();
    scheduleLocked();
    t.block_list = null;
    t.block_slot = null;
    t.block_lock = null;
}

/// Wake a blocked thread the caller has already unlinked (popped from its
/// queue / cleared from its slot), holding the object's lock.
pub fn wake(t: *Thread) void {
    t.lock.lock();
    std.debug.assert(t.state == .blocked);
    t.block_list = null;
    t.block_slot = null;
    t.block_lock = null;
    enqueueLocked(t);
    t.lock.unlock();
}

/// A bound notification interrupting a thread blocked in recv: with the
/// notification's lock held, take the object it blocks on, then the
/// thread, and verify before unlinking. Returns false when the thread was
/// not (or no longer) blocked in recv — the latched bits will be seen at
/// its next recv.
pub fn interruptRecv(t: *Thread, status: u64) bool {
    if (!@atomicLoad(bool, &t.in_recv, .acquire)) return false;
    const bl = @atomicLoad(?*lock.SpinLock, &t.block_lock, .acquire) orelse return false;
    bl.lock();
    t.lock.lock();
    const ok = t.state == .blocked and t.in_recv and t.block_lock == bl and t.block_slot != null;
    if (ok) {
        t.block_slot.?.* = null;
        t.block_list = null;
        t.block_slot = null;
        t.block_lock = null;
        t.ipc_status = status;
        enqueueLocked(t);
    }
    t.lock.unlock();
    bl.unlock();
    return ok;
}

fn waitSwitched(t: *Thread) void {
    while (t.switching.load(.acquire)) std.atomic.spinLoopHint();
}

/// Timer-tick hook, called from IRQ context (IRQs masked) on every core.
/// Core 0 additionally advances global time and wakes due sleepers.
pub fn onTick(is_timekeeper: bool) void {
    const cpu = thisCpu();
    cpu.current.cpu_ticks += 1;
    cpu.ticks += 1;
    // Charge the running thread's domain up to now, so a long run shows
    // in its account before it is switched away.
    chargeRun(cpu.current, cycles());

    if (is_timekeeper) {
        global_ticks += 1;
        ipc.timerTick(global_ticks);
        vm.tick();
        if (global_ticks % cpu_period_ticks == 0) periodReset();
        // Take the due sleepers off the list first (sleepers lock alone),
        // then wake each under its own lock — never both at once.
        var due: [max_threads]*Thread = undefined;
        var n: usize = 0;
        sleepers_lock.lock();
        var it = sleepers.first;
        while (it) |node| {
            const next = node.next;
            const t: *Thread = @alignCast(@fieldParentPtr("node", node));
            if (t.wake_tick <= global_ticks) {
                sleepers.remove(node);
                t.in_sleepers = false;
                due[n] = t;
                n += 1;
            }
            it = next;
        }
        sleepers_lock.unlock();
        for (due[0..n]) |t| {
            t.lock.lock();
            if (t.state == .sleeping) {
                enqueueLocked(t);
                t.lock.unlock();
            } else {
                // Torn down while in our hand: nobody else will free it.
                t.lock.unlock();
                waitSwitched(t);
                freeThread(t);
            }
        }
    }

    // Evicted threads: off this core's lock first, then re-placed under
    // their own (thread → run queue, in order).
    var evicted: [max_threads]*Thread = undefined;
    var ne: usize = 0;
    cpu.lock.lock();
    while (cpu.evict.popFirst()) |node| {
        evicted[ne] = @alignCast(@fieldParentPtr("node", node));
        ne += 1;
    }
    // Round-robin: preempt whenever someone else is waiting for this core,
    // when the running domain has spent its budget, or when the running
    // thread no longer belongs here.
    const cur = cpu.current;
    if (cpu.queue.first != null or (cur != cpu.idle and (overBudget(cur) or (cur.affinity == null and !placeable(cur, cpu.id))))) cpu.need_resched = true;
    cpu.lock.unlock();
    for (evicted[0..ne]) |t| {
        t.lock.lock();
        t.queued_on = null;
        enqueueLocked(t);
        t.lock.unlock();
    }
}

/// A new budget period: every domain's spent cycles go to zero, and
/// every parked thread goes back on its core's queue.
fn periodReset() void {
    if (cpu_period_reset) |f| f();
    for (&cpus, 0..) |cpu, i| {
        if (!cpu.online) continue;
        const rq = &cpus[i];
        rq.lock.lock();
        var woke = false;
        while (rq.throttled.popFirst()) |node| {
            const t: *Thread = @alignCast(@fieldParentPtr("node", node));
            t.park = .none;
            rq.queue.append(node);
            woke = true;
        }
        if (woke) rq.need_resched = true;
        rq.lock.unlock();
        if (woke and rq != thisCpu()) gic.sendSgi(@intCast(i));
    }
}

/// The thread running on core `c` right now (a racy peek, for drills).
pub fn currentOn(c: u32) *Thread {
    return cpus[c].current;
}

pub fn isIdle(t: *Thread) bool {
    for (&cpus) |*cpu| {
        if (cpu.online and cpu.idle == t) return true;
    }
    return false;
}

/// Called by the trap handler after EOI when returning from an interrupt.
pub fn preemptIfNeeded() void {
    const cpu = thisCpu();
    if (!@atomicLoad(bool, &cpu.need_resched, .acquire)) return;
    const daif = maskIrqs();
    cpu.lock.lock();
    cpu.need_resched = false;
    scheduleLocked();
    restoreIrqs(daif);
}

pub fn currentName() []const u8 {
    return thisCpu().current.name;
}

/// Debug: log every live thread and where it is.
pub fn debugDump() void {
    for (&threads) |*t| {
        if (t.state == .unused) continue;
        log.info("thread {s}#{d}: {t} in_recv={} list={} slot={} cpu={?d} q={?d}", .{
            t.name,               t.id,
            t.state,              t.in_recv,
            t.block_list != null, t.block_slot != null,
            t.on_cpu,             t.queued_on,
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
            t.* = .{ .id = next_thread_id, .state = .ready, .lock = t.lock };
            next_thread_id += 1;
            return t;
        }
    }
    return Error.NoThreadSlots;
}

/// Put a thread (its lock held, on no queue) onto a run queue: its pinned
/// core, or the next online core round-robin — which also makes unpinned
/// threads migrate, exercising SMP paths.
fn enqueueLocked(t: *Thread) void {
    t.state = .ready;
    t.park = .none;
    const target = t.affinity orelse blk: {
        var tries: u32 = 0;
        while (tries < max_cpus) : (tries += 1) {
            const c = @atomicRmw(u32, &balance_next, .Add, 1, .monotonic) % max_cpus;
            if (placeable(t, c)) break :blk c;
        }
        break :blk 0;
    };
    const rq = &cpus[target];
    rq.lock.lock();
    t.queued_on = target;
    rq.queue.append(&t.node);
    // Kick the target so wakeups run in microseconds, not at the next
    // 100ms tick: another core gets an SGI (leaving wfi -> preempt path);
    // our own core is handled at the next preempt point (IRQ exit or
    // syscall return).
    rq.need_resched = true;
    rq.lock.unlock();
    if (rq != thisCpu()) gic.sendSgi(target);
}

/// May thread `t` be placed on core `c`: online, inside the thread's
/// partition mask if it has one, and not another domain's reserved core.
fn placeable(t: *Thread, c: u32) bool {
    const cpu = &cpus[c];
    if (!cpu.online) return false;
    if (t.cpu_mask != 0 and (t.cpu_mask >> @intCast(c)) & 1 == 0) return false;
    if (cpu.reserved_by) |who| {
        if (t.user_ctx != who) return false;
    }
    return true;
}

/// Reserve `mask`'s cores for domain `who`, exclusively: nothing else is
/// placed there from now on (threads already there drain at their next
/// switch). Core 0 (the timekeeper, the kernel's own threads) cannot be
/// reserved; a core already reserved cannot be reserved again.
pub fn reserveCores(mask: u64, who: *anyopaque) bool {
    var c: u32 = 0;
    while (c < max_cpus) : (c += 1) {
        if ((mask >> @intCast(c)) & 1 == 0) continue;
        if (c == 0 or !cpus[c].online or cpus[c].reserved_by != null) return false;
    }
    c = 0;
    while (c < max_cpus) : (c += 1) {
        if ((mask >> @intCast(c)) & 1 != 0) cpus[c].reserved_by = who;
    }
    return true;
}

pub fn releaseCores(who: *anyopaque) void {
    for (&cpus) |*cpu| {
        if (cpu.reserved_by == who) cpu.reserved_by = null;
    }
}

/// CPU budgets (domain.zig registers these): charge a domain for cycles
/// its thread ran; ask whether it is over budget; reset every period.
pub var cpu_charge: ?*const fn (*anyopaque, u64) void = null;
pub var cpu_over_budget: ?*const fn (*anyopaque) bool = null;
pub var cpu_period_reset: ?*const fn () void = null;
pub const cpu_period_ticks: u64 = 10; // 1s at the 100ms tick

fn cycles() u64 {
    return asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (-> u64),
    );
}

fn chargeRun(t: *Thread, now: u64) void {
    if (t.user_ctx) |d| {
        if (cpu_charge) |f| f(d, now -% t.run_start);
    }
    t.run_start = now;
}

fn overBudget(t: *Thread) bool {
    const d = t.user_ctx orelse return false;
    const f = cpu_over_budget orelse return false;
    return f(d);
}

/// Core scheduling decision. Local run-queue lock held, IRQs masked;
/// returns with the lock released.
fn scheduleLocked() void {
    const cpu = thisCpu();
    const prev = cpu.current;
    const now = cycles();

    // The next runnable thread whose domain has budget left; the others
    // wait on the throttled list for the period to reset.
    const picked: ?*Thread = blk: {
        while (cpu.queue.popFirst()) |node| {
            const t: *Thread = @alignCast(@fieldParentPtr("node", node));
            if (t.affinity == null and !placeable(t, cpu.id)) {
                t.park = .evicted;
                cpu.evict.append(&t.node);
                continue;
            }
            if (overBudget(t)) {
                t.park = .throttled;
                cpu.throttled.append(&t.node);
                continue;
            }
            t.queued_on = null;
            break :blk t;
        }
        break :blk null;
    };
    const next: *Thread = if (picked) |t| t else if (prev.state == .running and !(prev != cpu.idle and overBudget(prev))) {
        prev.switching.store(false, .release);
        cpu.lock.unlock();
        return; // nothing else to run, keep going
    } else cpu.idle;

    if (next == prev) {
        // Woken before we managed to leave: carry on.
        prev.state = .running;
        prev.switching.store(false, .release);
        cpu.lock.unlock();
        return;
    }
    // Woken while still switching away on another core: let that core
    // finish saving it before we run it here.
    waitSwitched(next);

    chargeRun(prev, now);
    next.run_start = now;
    switch (prev.state) {
        // Preempted: back onto the local queue (migration happens on
        // wakeups, where the target core's lock is taken in order) — or
        // parked, if its domain has spent its budget.
        .running => if (prev != cpu.idle) {
            prev.state = .ready;
            prev.queued_on = cpu.id;
            if (prev.affinity == null and !placeable(prev, cpu.id)) {
                prev.park = .evicted;
                cpu.evict.append(&prev.node);
            } else if (overBudget(prev)) {
                prev.park = .throttled;
                cpu.throttled.append(&prev.node);
            } else {
                cpu.queue.append(&prev.node);
            }
        },
        .exited, .sleeping, .blocked, .ready, .unused => {},
    }
    prev.switching.store(true, .release);
    prev.on_cpu = null;
    next.state = .running;
    next.on_cpu = cpu.id;
    cpu.current = next;
    cpu.prev = prev;
    programUserSpace(next);
    // Vector state travels with user threads (see FpState). Exited
    // threads skip the save — their state is about to be reaped.
    if (prev.user_ttbr0 != 0 and prev.state != .exited) __fp_save(&prev.fp);
    if (next.user_ttbr0 != 0) __fp_restore(&next.fp);
    __context_switch(&prev.ctx, &next.ctx);
    // We are back on this thread, possibly much later, holding the
    // run-queue lock of whichever core switched to us.
    finishSwitch();
}

/// The other side of a switch, on the new thread: the predecessor is now
/// fully off this core — reap it if it exited, else let others run it —
/// and the run-queue lock taken before the switch is released.
fn finishSwitch() void {
    const cpu = thisCpu();
    if (cpu.prev) |p| {
        cpu.prev = null;
        if (p.state == .exited) {
            reap(p);
        } else {
            p.switching.store(false, .release);
        }
    }
    cpu.lock.unlock();
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

/// Free a thread nobody can reach any more (off every queue and object,
/// registers saved). The slot is recycled under the table lock; the lock
/// word survives so a late unlock by a racing peek cannot clobber it.
fn freeThread(t: *Thread) void {
    pmem.freeContiguous(t.stack_pa, stack_pages);
    t.stack_account.credit(stack_pages * mem.page_size);
    threads_lock.lock();
    t.* = .{ .lock = t.lock };
    threads_lock.unlock();
}

fn reap(dead: *Thread) void {
    const ctx = dead.user_ctx;
    freeThread(dead);
    if (ctx) |c| {
        if (user_thread_reaped) |cb| cb(c);
    }
}

/// First code run by a new thread, called from the trampoline with the
/// run-queue lock still held and IRQs masked.
export fn schedThreadStart() callconv(.c) void {
    finishSwitch();
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

/// Save/restore the current user thread's vector state around something
/// that clobbers it (a guest run).
pub fn fpSaveCurrent() void {
    const t = thisCpu().current;
    if (t.user_ttbr0 != 0) __fp_save(&t.fp);
}

pub fn fpRestoreCurrent() void {
    const t = thisCpu().current;
    if (t.user_ttbr0 != 0) __fp_restore(&t.fp);
}

/// A guest's vector state, kept per vCPU (vm.zig).
pub fn fpSave(st: *FpState) void {
    __fp_save(st);
}

pub fn fpRestore(st: *const FpState) void {
    __fp_restore(st);
}
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
