//! IPC objects: channels, notifications, shared-memory grants.
//!
//! Channels are synchronous call/reply rendezvous with the message carried
//! in registers (four words) plus an optional capability attachment — cap
//! transfer over messages is the buffer-grant mechanism. Side A serves
//! (recv/reply), side B calls; per-side refcounts count the caps naming
//! that side (plus kernel holders), and when a side's last ref dies the
//! channel closes: every in-flight and future operation on the other side
//! completes with Errno.peer_dead. Failure is in the vocabulary, from the
//! first version.
//!
//! Every object carries its own lock (taken with IRQs masked: signals
//! arrive from interrupt context). Blocked threads are parked either on a
//! channel's caller queue or in a single-waiter slot, under the object's
//! lock, which sched.block releases only once the thread is safely on its
//! way out; a thread remembers that lock (block_lock) so teardown and
//! bound-notification interrupts can unlink it in the same order:
//! notification → channel → thread → run queue. Slot allocation for all
//! three tables is under objs_lock; timers and IRQ bindings have theirs,
//! taken inside a notification's — which is why the tick and IRQ delivery
//! collect their targets first and signal after letting go.

const std = @import("std");
const arch = @import("arch.zig");
const cap = @import("cap.zig");
const kalloc = @import("kalloc.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");
const lock = @import("lock.zig");
const sched = @import("sched.zig");
const shared = @import("shared");
const log = @import("log.zig");
const trace = @import("trace.zig");

const max_channels = 64;
const max_notifications = 64;
const max_shms = 64;
pub const shm_max_pages = 128; // 512K: the blk data window needs 8 x 32K slots; a program stage 512K

pub const Side = enum { a, b };

pub const Msg = struct {
    data: [4]u64 = @splat(0),
    /// Cap in transit (kernel representation). cap_type 0 = none.
    cap_type: u8 = 0,
    cap_obj: u64 = 0,
    cap_badge: u64 = 0,
};

pub const Channel = struct {
    /// Cache-line aligned so channels driven from different cores never
    /// share a line (see PerCpu).
    active: bool align(128) = false,
    refs_a: u32 = 0,
    refs_b: u32 = 0,
    a_open: bool = false,
    b_open: bool = false,
    /// Threads blocked in call(), waiting for the server to recv.
    callers: std.DoublyLinkedList = .{},
    /// Server thread blocked in recv(), if any.
    server_waiting: ?*sched.Thread = null,
    /// Clients whose calls were delivered and now await reply(): a server
    /// may hold several open (deferred replies), each named by the token
    /// recv returned — slot + 1 in the low byte, a serial above it so a
    /// stale token can never answer a later caller in a reused slot.
    pending: [max_pending]?*sched.Thread = @splat(null),
    pending_serial: [max_pending]u32 = @splat(0),
    serial: u32 = 0,
    /// Badged identities on this side B whose last cap died and whose
    /// death the server has not collected yet (see Badge): recv reports
    /// them, one per call, as Errno.client_dead before serving anyone.
    deaths_pending: u32 = 0,
    lock: lock.SpinLock = .{},
};

pub const max_pending = 8;

/// A client identity: one badge on one channel's B side, refcounted
/// apart from the side so the server learns when THAT client is gone —
/// a side closes only when every cap naming it has died, and a service
/// serving many badged clients on one channel would otherwise never hear
/// of one client's death while the others live. Minted by chan_mint,
/// copied by every cap transfer, released by cap_drop and teardown like
/// the side ref it rides with; when the last cap carrying it dies the
/// entry turns dead and the channel's server is woken to collect it
/// (recv → client_dead, badge in x6). Badge 0 is "unbadged": never
/// tracked, its holders' death is the side's.
pub const Badge = struct {
    ch: ?*Channel = null,
    badge: u64 = 0,
    refs: u32 = 0,
    dead: bool = false,
};

const max_badges = 256;

pub const Notification = struct {
    active: bool align(128) = false,
    refs: u32 = 0,
    bits: u64 = 0,
    waiter: ?*sched.Thread = null,
    /// A thread bound via watch_deaths: a signal arriving while it is
    /// blocked in recv interrupts the recv (Errno.interrupted) so one
    /// thread can both serve a channel and supervise.
    bound: ?*sched.Thread = null,
    lock: lock.SpinLock = .{},
};

pub const Shm = struct {
    active: bool = false,
    refs: u32 = 0,
    npages: u32 = 0,
    pages: [shm_max_pages]u64 = @splat(0),
    /// Who created it (for the leak bar's report).
    creator: [16]u8 = @splat(0),
};

var channels: [max_channels]Channel = @splat(.{});
var notifications: [max_notifications]Notification = @splat(.{});
var shms: [max_shms]Shm = @splat(.{});
var badges: [max_badges]Badge = @splat(.{});
var objs_lock: lock.SpinLock = .{};
var shm_lock: lock.SpinLock = .{};
/// A leaf: taken under a channel's lock, never held while taking one.
var badges_lock: lock.SpinLock = .{};
var timers_lock: lock.SpinLock = .{};

/// Shared-memory pages are charged here for now; per-domain accounting for
/// objects that outlive their creator arrives with real object lifetimes in
/// Phase 5.
pub var shm_account: kalloc.Account = .{ .limit = 16 << 20 };

pub const Error = error{NoObjects};

// ---------------------------------------------------------------- channels

/// Create a channel; both refcounts start at the caller's ownership (the
/// caller then hands sides out via manifest grants or keeps them).
pub fn createChannel(refs_a: u32, refs_b: u32) Error!*Channel {
    const irqs = objs_lock.lockIrqSave();
    defer objs_lock.unlockRestore(irqs);
    for (&channels) |*ch| {
        if (@atomicLoad(bool, &ch.active, .acquire)) continue;
        // A freeing side may still hold the lock for an instant.
        ch.lock.lock();
        defer ch.lock.unlock();
        if (ch.active) continue;
        ch.* = .{ .active = true, .refs_a = refs_a, .refs_b = refs_b, .a_open = true, .b_open = true, .lock = ch.lock };
        return ch;
    }
    return Error.NoObjects;
}

pub const CallResult = struct {
    err: shared.Errno,
    msg: Msg = .{},
};

/// Client side: send four words (+ optional cap) and block until the reply
/// or the peer's death. `caller_badge` is the badge minted into the cap the
/// caller invoked (0 for unbadged/kernel callers); recv delivers it.
pub fn call(ch: *Channel, msg: Msg, caller_badge: u64) CallResult {
    const irqs = ch.lock.lockIrqSave();
    if (!ch.a_open or !ch.b_open) {
        ch.lock.unlockRestore(irqs);
        return .{ .err = .peer_dead };
    }

    const t = sched.thisCpu().current;
    t.ipc_data = msg.data;
    t.ipc_cap_type = msg.cap_type;
    t.ipc_cap_obj = msg.cap_obj;
    t.ipc_cap_badge = msg.cap_badge;
    t.ipc_badge = caller_badge;
    t.ipc_status = @intFromEnum(shared.Errno.ok);

    if (ch.server_waiting) |server| {
        ch.server_waiting = null;
        sched.wake(server);
    }
    sched.block(&ch.callers, null, &ch.lock, null); // releases ch.lock
    restoreIrqs(irqs);

    // Woken: either the server replied (mailbox holds the reply) or the
    // channel died under us. Either way the mailbox's cap — the reply's,
    // or our own if nobody ever received it — travels out with the
    // result, and its ref is the caller's to deliver or drop: nothing
    // stays behind in the thread.
    const out: Msg = .{
        .data = t.ipc_data,
        .cap_type = t.ipc_cap_type,
        .cap_obj = t.ipc_cap_obj,
        .cap_badge = t.ipc_cap_badge,
    };
    t.ipc_cap_type = 0;
    t.ipc_cap_obj = 0;
    if (t.ipc_status != @intFromEnum(shared.Errno.ok)) {
        return .{ .err = @enumFromInt(t.ipc_status), .msg = out };
    }
    return .{ .err = .ok, .msg = out };
}

/// Server side: block until a call arrives; its words land in the returned
/// Msg (badge_out gets the caller's cap badge, token_out the reply token)
/// and the caller is parked in a pending slot until reply(). With every
/// slot occupied, recv reports busy: reply to something first.
pub fn recv(ch: *Channel, out: *Msg, badge_out: *u64, token_out: *u64) shared.Errno {
    const irqs = maskIrqs();
    defer restoreIrqs(irqs);
    // A bound notification's lock is held from the latched-bits peek until
    // the thread is parked (block releases it): a signal either lands
    // before the peek and is seen, or after the park and interrupts it.
    // Without this a death signaled between the two was lost for good.
    const bound: ?*Notification = if (sched.thisCpu().current.bound_notif) |bn| @ptrCast(@alignCast(bn)) else null;
    const outer: ?*lock.SpinLock = if (bound) |n| &n.lock else null;
    while (true) {
        if (outer) |o| o.lock();
        ch.lock.lock();
        // A signal that arrived while this thread was busy between recvs
        // must not be lost: surface latched bound-notification bits first.
        if (bound) |n| {
            if (n.bits != 0) {
                ch.lock.unlock();
                outer.?.unlock();
                return .interrupted;
            }
        }
        if (!ch.a_open) {
            ch.lock.unlock();
            if (outer) |o| o.unlock();
            return .peer_dead;
        }
        // A client identity that died is reported before anyone is
        // served: the server frees what it kept for that badge, and the
        // badge may be minted again only after this.
        if (ch.deaths_pending > 0) {
            if (takeDeadBadge(ch)) |b| {
                ch.deaths_pending -= 1;
                badge_out.* = b;
                ch.lock.unlock();
                if (outer) |o| o.unlock();
                return .client_dead;
            }
            ch.deaths_pending = 0;
        }
        var free: ?usize = null;
        for (&ch.pending, 0..) |p, i| {
            if (p == null) {
                free = i;
                break;
            }
        }
        const slot = free orelse {
            ch.lock.unlock();
            if (outer) |o| o.unlock();
            return .busy;
        };
        if (ch.callers.popFirst()) |node| {
            const caller: *sched.Thread = @alignCast(@fieldParentPtr("node", node));
            caller.block_list = null;
            ch.pending[slot] = caller;
            caller.block_slot = &ch.pending[slot];
            ch.serial +%= 1;
            if (ch.serial == 0) ch.serial = 1;
            ch.pending_serial[slot] = ch.serial;
            out.* = .{
                .data = caller.ipc_data,
                .cap_type = caller.ipc_cap_type,
                .cap_obj = caller.ipc_cap_obj,
                .cap_badge = caller.ipc_cap_badge,
            };
            // The attached cap's ref now rides the message (delivered or
            // dropped by the receiver); the caller no longer holds it.
            caller.ipc_cap_type = 0;
            caller.ipc_cap_obj = 0;
            badge_out.* = caller.ipc_badge;
            token_out.* = (@as(u64, ch.serial) << 8) | (slot + 1);
            ch.lock.unlock();
            if (outer) |o| o.unlock();
            return .ok;
        }
        if (!ch.b_open) {
            ch.lock.unlock();
            if (outer) |o| o.unlock();
            return .peer_dead;
        }
        const t = sched.thisCpu().current;
        t.ipc_status = @intFromEnum(shared.Errno.ok);
        t.in_recv = true;
        sched.block(null, &ch.server_waiting, &ch.lock, outer); // releases both
        t.in_recv = false;
        if (t.ipc_status != @intFromEnum(shared.Errno.ok)) {
            return @enumFromInt(t.ipc_status);
        }
    }
}

fn maskIrqs() arch.cpu.IrqState {
    return arch.cpu.irqSave();
}

fn restoreIrqs(irqs: arch.cpu.IrqState) void {
    arch.cpu.irqRestore(irqs);
}

/// Reply to the oldest pending caller (the one-at-a-time server's reply).
pub fn reply(ch: *Channel, msg: Msg) shared.Errno {
    return replyTo(ch, msg, 0);
}

/// Reply to the caller named by `token` (0 = whichever pending caller
/// was delivered first). A stale or unknown token is bad_state; a client
/// that died mid-call reports peer_dead when its side is gone.
pub fn replyTo(ch: *Channel, msg: Msg, token: u64) shared.Errno {
    const irqs = ch.lock.lockIrqSave();
    defer ch.lock.unlockRestore(irqs);
    var slot: ?usize = null;
    if (token == 0) {
        // Oldest = the lowest serial among the pending.
        var best: u32 = 0;
        for (ch.pending, 0..) |p, i| {
            if (p != null and (slot == null or ch.pending_serial[i] < best)) {
                slot = i;
                best = ch.pending_serial[i];
            }
        }
    } else {
        const i: usize = @intCast((token & 0xff) -% 1);
        if (i < max_pending and ch.pending[i] != null and ch.pending_serial[i] == @as(u32, @truncate(token >> 8))) slot = i;
    }
    const i = slot orelse {
        // The client may have died mid-call; that is a distinct outcome.
        return if (!ch.b_open) .peer_dead else .bad_state;
    };
    const client = ch.pending[i].?;
    ch.pending[i] = null;
    client.block_slot = null;
    client.ipc_data = msg.data;
    client.ipc_cap_type = msg.cap_type;
    client.ipc_cap_obj = msg.cap_obj;
    client.ipc_cap_badge = msg.cap_badge;
    client.ipc_status = @intFromEnum(shared.Errno.ok);
    sched.wake(client);
    return .ok;
}

/// A side's last cap died (channel lock held): close it and complete every
/// in-flight operation on the other side with peer_dead.
fn closeSideLocked(ch: *Channel, side: Side) void {
    switch (side) {
        .a => ch.a_open = false,
        .b => ch.b_open = false,
    }
    // Callers can't be served anymore once A is gone.
    if (!ch.a_open) {
        while (ch.callers.popFirst()) |node| {
            const t: *sched.Thread = @alignCast(@fieldParentPtr("node", node));
            t.block_list = null;
            t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
            sched.wake(t);
        }
        for (&ch.pending) |*p| {
            if (p.*) |t| {
                p.* = null;
                t.block_slot = null;
                t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
                sched.wake(t);
            }
        }
    }
    // A server waiting on a dead client side wakes with peer_dead.
    if (!ch.b_open) {
        if (ch.server_waiting) |t| {
            ch.server_waiting = null;
            t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
            sched.wake(t);
        }
    }
    if (ch.refs_a == 0 and ch.refs_b == 0) {
        purgeBadges(ch); // every badge ref was a side ref: all dead by now
        ch.* = .{ .lock = ch.lock }; // the lock word stays ours to release
    }
}

/// A cap to a side was duplicated (cap transfer, spawn grant). `badge`
/// is the cap's badge (side B; 0 = unbadged): a badged copy also refs
/// the client identity, which chan_mint must have created.
pub fn refSide(ch: *Channel, side: Side, badge: u64) void {
    if (side == .b and badge != 0) {
        const irqs = badges_lock.lockIrqSave();
        defer badges_lock.unlockRestore(irqs);
        const b = findBadge(ch, badge) orelse std.debug.panic("refSide: badge {d} was never minted", .{badge});
        b.refs += 1;
    }
    refSideOnly(ch, side);
}

fn refSideOnly(ch: *Channel, side: Side) void {
    const irqs = ch.lock.lockIrqSave();
    defer ch.lock.unlockRestore(irqs);
    switch (side) {
        .a => ch.refs_a += 1,
        .b => ch.refs_b += 1,
    }
}

/// A cap to a side died (cap_drop, teardown, a dropped attachment). A
/// badged cap's death that is the identity's last wakes the server to
/// collect it; a side's last ref closes the side.
pub fn unrefSide(ch: *Channel, side: Side, badge: u64) void {
    var died = false;
    if (side == .b and badge != 0) {
        const irqs = badges_lock.lockIrqSave();
        defer badges_lock.unlockRestore(irqs);
        const b = findBadge(ch, badge) orelse std.debug.panic("unrefSide: badge {d} was never minted", .{badge});
        std.debug.assert(b.refs > 0);
        b.refs -= 1;
        if (b.refs == 0) {
            b.dead = true;
            died = true;
        }
    }
    const irqs = ch.lock.lockIrqSave();
    defer ch.lock.unlockRestore(irqs);
    if (died) {
        trace.record(.badge_dead, channelIndex(ch), badge);
        ch.deaths_pending += 1;
        // The server, if parked in recv, loops around and finds it (its
        // mailbox status is still ok).
        if (ch.server_waiting) |t| {
            ch.server_waiting = null;
            sched.wake(t);
        }
    }
    const refs = switch (side) {
        .a => &ch.refs_a,
        .b => &ch.refs_b,
    };
    std.debug.assert(refs.* > 0);
    refs.* -= 1;
    if (refs.* == 0) closeSideLocked(ch, side);
}

// ---------------------------------------------------------------- badges

/// The serving side mints a client identity on its own channel: the
/// identity's first ref, or one more if the same badge is minted again
/// (both caps are the same client). Fails when the badge table is full.
pub fn mintBadge(ch: *Channel, badge: u64) Error!void {
    if (badge != 0) {
        const irqs = badges_lock.lockIrqSave();
        defer badges_lock.unlockRestore(irqs);
        const b = findBadge(ch, badge) orelse allocBadge(ch, badge) orelse return Error.NoObjects;
        b.refs += 1;
    }
    refSideOnly(ch, .b);
}

/// The live entry for (channel, badge); badges_lock held. A dead entry
/// still waiting to be collected is not it: the server must not have
/// minted the badge again before hearing of the death, and if it did,
/// the new identity is a new entry.
fn findBadge(ch: *Channel, badge: u64) ?*Badge {
    for (&badges) |*b| {
        if (b.ch == ch and b.badge == badge and !b.dead) return b;
    }
    return null;
}

fn allocBadge(ch: *Channel, badge: u64) ?*Badge {
    for (&badges) |*b| {
        if (b.ch == null) {
            b.* = .{ .ch = ch, .badge = badge };
            return b;
        }
    }
    return null;
}

/// Collect one dead badge of this channel (channel lock held).
fn takeDeadBadge(ch: *Channel) ?u64 {
    badges_lock.lock();
    defer badges_lock.unlock();
    for (&badges) |*b| {
        if (b.ch == ch and b.dead) {
            const badge = b.badge;
            b.* = .{};
            return badge;
        }
    }
    return null;
}

/// The channel is being freed: forget every identity on it.
fn purgeBadges(ch: *Channel) void {
    badges_lock.lock();
    defer badges_lock.unlock();
    for (&badges) |*b| {
        if (b.ch == ch) b.* = .{};
    }
}

/// Identities in the table (live or awaiting collection): the leak bar.
pub fn badgeCount() usize {
    const irqs = badges_lock.lockIrqSave();
    defer badges_lock.unlockRestore(irqs);
    var n: usize = 0;
    for (&badges) |*b| {
        if (b.ch != null) n += 1;
    }
    return n;
}

// ----------------------------------------------------------- notifications

pub fn createNotification() Error!*Notification {
    const irqs = objs_lock.lockIrqSave();
    defer objs_lock.unlockRestore(irqs);
    for (&notifications) |*n| {
        if (@atomicLoad(bool, &n.active, .acquire)) continue;
        n.lock.lock();
        defer n.lock.unlock();
        if (n.active) continue;
        n.* = .{ .active = true, .refs = 1, .lock = n.lock };
        return n;
    }
    return Error.NoObjects;
}

/// Signal: latch the bits, wake a waiter, or interrupt a bound thread
/// blocked in recv (the bits stay latched for its follow-up notify_wait).
/// A notification freed under a late IRQ/timer signal drops it.
pub fn signal(n: *Notification, bits: u64) void {
    const irqs = n.lock.lockIrqSave();
    defer n.lock.unlockRestore(irqs);
    if (!n.active) return;
    n.bits |= bits;
    if (n.waiter) |t| {
        n.waiter = null;
        t.block_slot = null;
        t.ipc_data[0] = n.bits;
        t.ipc_status = @intFromEnum(shared.Errno.ok);
        n.bits = 0;
        sched.wake(t);
        trace.record(.signal, notifIndex(n), 1);
        return;
    }
    if (n.bound) |t| {
        const woke = sched.interruptRecv(t, @intFromEnum(shared.Errno.interrupted));
        trace.record(.signal, notifIndex(n), if (woke) 2 else 3);
        return;
    }
    trace.record(.signal, notifIndex(n), 0);
}

pub fn notifIndex(n: *const Notification) u64 {
    return (@intFromPtr(n) - @intFromPtr(&notifications[0])) / @sizeOf(Notification);
}

pub fn refNotification(n: *Notification) void {
    const irqs = n.lock.lockIrqSave();
    defer n.lock.unlockRestore(irqs);
    n.refs += 1;
}

/// Bind `t` for recv interruption (see Notification.bound).
pub fn bindNotification(n: *Notification, t: *sched.Thread) void {
    const irqs = n.lock.lockIrqSave();
    defer n.lock.unlockRestore(irqs);
    n.bound = t;
    t.bound_notif = n;
}

/// Block until any bits are signaled; returns and clears them.
pub fn wait(n: *Notification) struct { err: shared.Errno, bits: u64 } {
    const irqs = n.lock.lockIrqSave();
    if (n.bits != 0) {
        const bits = n.bits;
        n.bits = 0;
        n.lock.unlockRestore(irqs);
        return .{ .err = .ok, .bits = bits };
    }
    if (n.waiter != null) {
        n.lock.unlockRestore(irqs);
        return .{ .err = .busy, .bits = 0 };
    }
    const t = sched.thisCpu().current;
    t.ipc_status = @intFromEnum(shared.Errno.ok);
    sched.block(null, &n.waiter, &n.lock, null); // releases n.lock
    restoreIrqs(irqs);
    return .{ .err = @enumFromInt(t.ipc_status), .bits = t.ipc_data[0] };
}

/// Registered by irq.zig; called with the notification's lock held when
/// it is freed, so IRQ bindings never outlive their target.
pub var notif_freed_hook: ?*const fn (*Notification) void = null;

// ------------------------------------------------------------------ timers
//
// A timer is a notification the timekeeper signals on a period: the
// same shape as an IRQ (notification bits on an event) and the same
// wake path (a bound thread's recv is interrupted). Services that need
// a clock — heartbeats, timeouts — arm one instead of being polled.

const Timer = struct {
    n: ?*Notification = null,
    period: u64 = 0,
    next: u64 = 0,
    bits: u64 = 0,
};

const max_timers = 16;
var timers: [max_timers]Timer = @splat(.{});

/// Arm (or, with period 0, disarm) the timer on `n`: every `period`
/// ticks the notification is signaled with `bits`. One timer per
/// notification; re-arming replaces it. The timer holds no ref — a
/// notification freed under it is disarmed.
pub fn armTimer(n: *Notification, period: u64, bits: u64, now: u64) bool {
    const irqs = timers_lock.lockIrqSave();
    defer timers_lock.unlockRestore(irqs);
    var free: ?*Timer = null;
    for (&timers) |*t| {
        if (t.n == n) {
            if (period == 0) {
                t.* = .{};
                return true;
            }
            t.period = period;
            t.next = now + period;
            t.bits = bits;
            return true;
        }
        if (t.n == null and free == null) free = t;
    }
    if (period == 0) return true;
    const t = free orelse return false;
    t.* = .{ .n = n, .period = period, .next = now + period, .bits = bits };
    return true;
}

/// The timekeeper's tick (IRQ context). Due timers are collected under
/// the timers lock and signaled after it is released: a notification's
/// lock is never taken inside it (teardown takes them the other way).
pub fn timerTick(now: u64) void {
    var due: [max_timers]struct { n: *Notification, bits: u64 } = undefined;
    var count: usize = 0;
    timers_lock.lock();
    for (&timers) |*t| {
        const n = t.n orelse continue;
        if (now < t.next) continue;
        t.next = now + t.period;
        due[count] = .{ .n = n, .bits = t.bits };
        count += 1;
    }
    timers_lock.unlock();
    for (due[0..count]) |d| signal(d.n, d.bits);
}

fn timerNotifFreed(n: *Notification) void {
    timers_lock.lock();
    defer timers_lock.unlock();
    for (&timers) |*t| {
        if (t.n == n) t.* = .{};
    }
}

pub fn unrefNotification(n: *Notification) void {
    const irqs = n.lock.lockIrqSave();
    defer n.lock.unlockRestore(irqs);
    std.debug.assert(n.refs > 0);
    n.refs -= 1;
    if (n.refs == 0) {
        if (n.waiter) |t| {
            n.waiter = null;
            t.block_slot = null;
            t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
            sched.wake(t);
        }
        timerNotifFreed(n);
        if (notif_freed_hook) |f| f(n);
        n.* = .{ .lock = n.lock };
    }
}

pub fn channelIndex(ch: *const Channel) u64 {
    return (@intFromPtr(ch) - @intFromPtr(&channels[0])) / @sizeOf(Channel);
}

/// Debug: name the object a blocked thread's block_lock belongs to
/// ("chan#3", "notif#7"), for the scheduler dump.
pub fn describeLock(l: *const lock.SpinLock, buf: []u8) []const u8 {
    for (&channels, 0..) |*ch, i| {
        if (&ch.lock == l) return std.fmt.bufPrint(buf, "chan#{d}", .{i}) catch "chan";
    }
    for (&notifications, 0..) |*n, i| {
        if (&n.lock == l) return std.fmt.bufPrint(buf, "notif#{d}", .{i}) catch "notif";
    }
    return "?";
}

/// Debug: every live notification — latched bits, refs, who waits on it
/// and who is bound to it (a death signal that never woke anyone shows
/// as bits latched under a bound thread parked elsewhere).
pub fn debugDumpNotifications() void {
    for (&notifications, 0..) |*n, i| {
        if (!n.active) continue;
        log.info("notif#{d}: bits=0x{x} refs={d} waiter={s} bound={s}", .{
            i,                                n.bits,
            n.refs,                           if (n.waiter) |t| t.name else "-",
            if (n.bound) |t| t.name else "-",
        });
    }
    for (&channels, 0..) |*ch, i| {
        if (!ch.active) continue;
        var pending: u32 = 0;
        for (ch.pending) |p| {
            if (p != null) pending += 1;
        }
        log.info("chan#{d}: refs a={d} b={d} open a={} b={} server_waiting={s} pending={d} deaths={d}", .{
            i,         ch.refs_a,
            ch.refs_b, ch.a_open,
            ch.b_open, if (ch.server_waiting) |t| t.name else "-",
            pending,   ch.deaths_pending,
        });
    }
}

// ------------------------------------------------------------------- shm

pub fn createShm(npages: u32) ?*Shm {
    return createShmBy(npages, "kernel");
}

/// Every still-active shared buffer: what the leak bar reports.
pub fn dumpShms() void {
    for (&shms, 0..) |*s, i| {
        if (!s.active) continue;
        const n = std.mem.indexOfScalar(u8, &s.creator, 0) orelse 16;
        log.warn("shm[{d}]: {d} pages, {d} refs, created by {s}", .{ i, s.npages, s.refs, s.creator[0..n] });
    }
}

pub fn createShmBy(npages: u32, creator: []const u8) ?*Shm {
    if (npages == 0 or npages > shm_max_pages) return null;
    const irqs = shm_lock.lockIrqSave();
    defer shm_lock.unlockRestore(irqs);
    for (&shms) |*s| {
        if (!s.active) {
            s.* = .{ .active = true, .refs = 1, .npages = npages };
            const k = @min(creator.len, 16);
            @memcpy(s.creator[0..k], creator[0..k]);
            trace.record(.shm_create, (@intFromPtr(s) - @intFromPtr(&shms[0])) / @sizeOf(Shm), npages);
            for (0..npages) |i| {
                const page = kalloc.allocPage(&shm_account) catch {
                    for (0..i) |j| kalloc.freePage(&shm_account, mem.physToPtr([*]u8, s.pages[j]));
                    s.* = .{};
                    return null;
                };
                s.pages[i] = mem.virtToPhys(@intFromPtr(page));
            }
            return s;
        }
    }
    return null;
}

pub fn refShm(s: *Shm) void {
    const irqs = shm_lock.lockIrqSave();
    defer shm_lock.unlockRestore(irqs);
    s.refs += 1;
    trace.record(.shm_ref, (@intFromPtr(s) - @intFromPtr(&shms[0])) / @sizeOf(Shm), s.refs);
}

pub fn unrefShm(s: *Shm) void {
    const irqs = shm_lock.lockIrqSave();
    defer shm_lock.unlockRestore(irqs);
    if (s.refs == 0) std.debug.panic("unrefShm: no ref to drop ({d} pages, created by {s})", .{ s.npages, s.creator });
    s.refs -= 1;
    trace.record(.shm_unref, (@intFromPtr(s) - @intFromPtr(&shms[0])) / @sizeOf(Shm), s.refs);
    if (s.refs == 0) {
        trace.record(.shm_free, (@intFromPtr(s) - @intFromPtr(&shms[0])) / @sizeOf(Shm), 0);
        for (0..s.npages) |i| {
            kalloc.freePage(&shm_account, mem.physToPtr([*]u8, s.pages[i]));
        }
        s.* = .{};
    }
}

// -------------------------------------------------------------- releasing

/// Registered by domain.zig (import-cycle firewall): releases one
/// domain_ctl reference.
pub var domain_ctl_release: ?*const fn (u64) void = null;
/// Registered by vm.zig's owner (main): tears a VM down when its cap dies.
pub var vm_release: ?*const fn (u64) void = null;

/// Release one cap's reference to whatever kernel object it names. Called
/// for each entry when a domain's cap table is torn down, by explicit
/// cap deletion (cap_drop), and for an attachment nobody took. `badge`
/// is the cap's (a badged channel_b cap also holds its client identity).
pub fn releaseCap(cap_type: cap.CapType, obj: u64, badge: u64) void {
    switch (cap_type) {
        .empty, .debug_log, .spawner, .device, .entropy, .introspect, .hypervisor, .window => {},
        .vm => if (vm_release) |f| f(obj),
        .channel_a => unrefSide(@ptrFromInt(obj), .a, 0),
        .channel_b => unrefSide(@ptrFromInt(obj), .b, badge),
        .notification => unrefNotification(@ptrFromInt(obj)),
        .shm => unrefShm(@ptrFromInt(obj)),
        .domain_ctl => if (domain_ctl_release) |f| f(obj),
    }
}
