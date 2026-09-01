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
//! All channel state shares the scheduler's big lock, so wait/wake
//! transitions cannot race with teardown. Blocked threads are parked either
//! on a channel's caller queue or in a single-waiter slot; sched teardown
//! knows how to unlink both.

const std = @import("std");
const cap = @import("cap.zig");
const kalloc = @import("kalloc.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");
const sched = @import("sched.zig");
const shared = @import("shared");

const max_channels = 16;
const max_notifications = 16;
const max_shms = 16;
pub const shm_max_pages = 8;

pub const Side = enum { a, b };

pub const Msg = struct {
    data: [4]u64 = @splat(0),
    /// Cap in transit (kernel representation). cap_type 0 = none.
    cap_type: u8 = 0,
    cap_obj: u64 = 0,
    cap_badge: u64 = 0,
};

pub const Channel = struct {
    active: bool = false,
    refs_a: u32 = 0,
    refs_b: u32 = 0,
    a_open: bool = false,
    b_open: bool = false,
    /// Threads blocked in call(), waiting for the server to recv.
    callers: std.DoublyLinkedList = .{},
    /// Server thread blocked in recv(), if any.
    server_waiting: ?*sched.Thread = null,
    /// Client whose call was delivered and now awaits reply().
    processing: ?*sched.Thread = null,
};

pub const Notification = struct {
    active: bool = false,
    refs: u32 = 0,
    bits: u64 = 0,
    waiter: ?*sched.Thread = null,
    /// A thread bound via watch_deaths: a signal arriving while it is
    /// blocked in recv interrupts the recv (Errno.interrupted) so one
    /// thread can both serve a channel and supervise.
    bound: ?*sched.Thread = null,
};

pub const Shm = struct {
    active: bool = false,
    refs: u32 = 0,
    npages: u32 = 0,
    pages: [shm_max_pages]u64 = @splat(0),
};

var channels: [max_channels]Channel = @splat(.{});
var notifications: [max_notifications]Notification = @splat(.{});
var shms: [max_shms]Shm = @splat(.{});

/// Shared-memory pages are charged here for now; per-domain accounting for
/// objects that outlive their creator arrives with real object lifetimes in
/// Phase 5.
pub var shm_account: kalloc.Account = .{ .limit = 16 << 20 };

pub const Error = error{NoObjects};

// ---------------------------------------------------------------- channels

/// Create a channel; both refcounts start at the caller's ownership (the
/// caller then hands sides out via manifest grants or keeps them).
pub fn createChannel(refs_a: u32, refs_b: u32) Error!*Channel {
    const daif = sched.acquire();
    defer sched.release(daif);
    for (&channels) |*ch| {
        if (!ch.active) {
            ch.* = .{ .active = true, .refs_a = refs_a, .refs_b = refs_b, .a_open = true, .b_open = true };
            return ch;
        }
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
    const daif = sched.acquire();
    defer sched.release(daif);
    if (!ch.a_open or !ch.b_open) return .{ .err = .peer_dead };

    const t = sched.thisCpu().current;
    t.ipc_data = msg.data;
    t.ipc_cap_type = msg.cap_type;
    t.ipc_cap_obj = msg.cap_obj;
    t.ipc_cap_badge = msg.cap_badge;
    t.ipc_badge = caller_badge;
    t.ipc_status = @intFromEnum(shared.Errno.ok);

    if (ch.server_waiting) |server| {
        ch.server_waiting = null;
        sched.wakeLocked(server);
    }
    sched.blockCurrentLocked(&ch.callers, null);

    // Woken: either the server replied (mailbox holds the reply) or the
    // channel died under us.
    if (t.ipc_status != @intFromEnum(shared.Errno.ok)) {
        return .{ .err = @enumFromInt(t.ipc_status) };
    }
    return .{ .err = .ok, .msg = .{
        .data = t.ipc_data,
        .cap_type = t.ipc_cap_type,
        .cap_obj = t.ipc_cap_obj,
        .cap_badge = t.ipc_cap_badge,
    } };
}

/// Server side: block until a call arrives; its words land in the returned
/// Msg (badge_out gets the caller's cap badge) and the caller is parked in
/// `processing` until reply().
pub fn recv(ch: *Channel, out: *Msg, badge_out: *u64) shared.Errno {
    const daif = sched.acquire();
    defer sched.release(daif);
    while (true) {
        // A signal that arrived while this thread was busy between recvs
        // must not be lost: surface latched bound-notification bits first.
        if (sched.thisCpu().current.bound_notif) |bn| {
            const n: *Notification = @ptrCast(@alignCast(bn));
            if (n.bits != 0) return .interrupted;
        }
        if (!ch.a_open) return .peer_dead;
        if (ch.processing != null) return .busy;
        if (ch.callers.popFirst()) |node| {
            const caller: *sched.Thread = @alignCast(@fieldParentPtr("node", node));
            caller.block_list = null;
            ch.processing = caller;
            caller.block_slot = &ch.processing;
            out.* = .{
                .data = caller.ipc_data,
                .cap_type = caller.ipc_cap_type,
                .cap_obj = caller.ipc_cap_obj,
                .cap_badge = caller.ipc_cap_badge,
            };
            badge_out.* = caller.ipc_badge;
            return .ok;
        }
        if (!ch.b_open) return .peer_dead;
        const t = sched.thisCpu().current;
        t.ipc_status = @intFromEnum(shared.Errno.ok);
        t.in_recv = true;
        sched.blockCurrentLocked(null, &ch.server_waiting);
        t.in_recv = false;
        if (t.ipc_status != @intFromEnum(shared.Errno.ok)) {
            return @enumFromInt(t.ipc_status);
        }
    }
}

pub fn reply(ch: *Channel, msg: Msg) shared.Errno {
    const daif = sched.acquire();
    defer sched.release(daif);
    const client = ch.processing orelse {
        // The client may have died mid-call; that is a distinct outcome.
        return if (!ch.b_open) .peer_dead else .bad_state;
    };
    ch.processing = null;
    client.block_slot = null;
    client.ipc_data = msg.data;
    client.ipc_cap_type = msg.cap_type;
    client.ipc_cap_obj = msg.cap_obj;
    client.ipc_cap_badge = msg.cap_badge;
    client.ipc_status = @intFromEnum(shared.Errno.ok);
    sched.wakeLocked(client);
    return .ok;
}

/// A side's last cap died: close it and complete every in-flight operation
/// on the other side with peer_dead. Big lock taken inside.
fn closeSide(ch: *Channel, side: Side) void {
    const daif = sched.acquire();
    defer sched.release(daif);
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
            sched.wakeLocked(t);
        }
        if (ch.processing) |t| {
            ch.processing = null;
            t.block_slot = null;
            t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
            sched.wakeLocked(t);
        }
    }
    // A server waiting on a dead client side wakes with peer_dead.
    if (!ch.b_open) {
        if (ch.server_waiting) |t| {
            ch.server_waiting = null;
            t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
            sched.wakeLocked(t);
        }
    }
    if (ch.refs_a == 0 and ch.refs_b == 0) {
        ch.* = .{};
    }
}

/// A cap to a side was duplicated (cap transfer, spawn grant).
pub fn refSide(ch: *Channel, side: Side) void {
    const daif = sched.acquire();
    defer sched.release(daif);
    switch (side) {
        .a => ch.refs_a += 1,
        .b => ch.refs_b += 1,
    }
}

pub fn unrefSide(ch: *Channel, side: Side) void {
    const last = blk: {
        const daif = sched.acquire();
        defer sched.release(daif);
        const refs = switch (side) {
            .a => &ch.refs_a,
            .b => &ch.refs_b,
        };
        std.debug.assert(refs.* > 0);
        refs.* -= 1;
        break :blk refs.* == 0;
    };
    if (last) closeSide(ch, side);
}

// ----------------------------------------------------------- notifications

pub fn createNotification() Error!*Notification {
    const daif = sched.acquire();
    defer sched.release(daif);
    for (&notifications) |*n| {
        if (!n.active) {
            n.* = .{ .active = true, .refs = 1 };
            return n;
        }
    }
    return Error.NoObjects;
}

pub fn signal(n: *Notification, bits: u64) void {
    const daif = sched.acquire();
    defer sched.release(daif);
    signalLocked(n, bits);
}

/// Signal with the big lock already held (IRQ delivery).
pub fn signalLocked(n: *Notification, bits: u64) void {
    n.bits |= bits;
    if (n.waiter) |t| {
        n.waiter = null;
        t.block_slot = null;
        t.ipc_data[0] = n.bits;
        t.ipc_status = @intFromEnum(shared.Errno.ok);
        n.bits = 0;
        sched.wakeLocked(t);
        return;
    }
    // Interrupt a bound thread blocked in recv; the bits stay latched for
    // its follow-up notify_wait.
    if (n.bound) |t| {
        if (t.state == .blocked and t.in_recv and t.block_slot != null) {
            t.block_slot.?.* = null;
            t.block_slot = null;
            t.ipc_status = @intFromEnum(shared.Errno.interrupted);
            sched.wakeLocked(t);
        }
    }
}

pub fn refNotification(n: *Notification) void {
    const daif = sched.acquire();
    defer sched.release(daif);
    n.refs += 1;
}

/// Bind `t` for recv interruption (see Notification.bound).
pub fn bindNotification(n: *Notification, t: *sched.Thread) void {
    const daif = sched.acquire();
    defer sched.release(daif);
    n.bound = t;
    t.bound_notif = n;
}

/// Block until any bits are signaled; returns and clears them.
pub fn wait(n: *Notification) struct { err: shared.Errno, bits: u64 } {
    const daif = sched.acquire();
    defer sched.release(daif);
    if (n.bits != 0) {
        const bits = n.bits;
        n.bits = 0;
        return .{ .err = .ok, .bits = bits };
    }
    if (n.waiter != null) return .{ .err = .busy, .bits = 0 };
    const t = sched.thisCpu().current;
    t.ipc_status = @intFromEnum(shared.Errno.ok);
    sched.blockCurrentLocked(null, &n.waiter);
    return .{ .err = @enumFromInt(t.ipc_status), .bits = t.ipc_data[0] };
}

/// Registered by irq.zig; called with the big lock held when a
/// notification is freed, so IRQ bindings never outlive their target.
pub var notif_freed_hook: ?*const fn (*Notification) void = null;

pub fn unrefNotification(n: *Notification) void {
    const daif = sched.acquire();
    defer sched.release(daif);
    std.debug.assert(n.refs > 0);
    n.refs -= 1;
    if (n.refs == 0) {
        if (n.waiter) |t| {
            n.waiter = null;
            t.block_slot = null;
            t.ipc_status = @intFromEnum(shared.Errno.peer_dead);
            sched.wakeLocked(t);
        }
        if (notif_freed_hook) |f| f(n);
        n.* = .{};
    }
}

// ------------------------------------------------------------------- shm

pub fn createShm(npages: u32) ?*Shm {
    if (npages == 0 or npages > shm_max_pages) return null;
    const daif = sched.acquire();
    defer sched.release(daif);
    for (&shms) |*s| {
        if (!s.active) {
            s.* = .{ .active = true, .refs = 1, .npages = npages };
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
    const daif = sched.acquire();
    defer sched.release(daif);
    s.refs += 1;
}

pub fn unrefShm(s: *Shm) void {
    const daif = sched.acquire();
    defer sched.release(daif);
    std.debug.assert(s.refs > 0);
    s.refs -= 1;
    if (s.refs == 0) {
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

/// Release one cap's reference to whatever kernel object it names. Called
/// for each entry when a domain's cap table is torn down, and by explicit
/// cap deletion (cap_drop).
pub fn releaseCap(cap_type: cap.CapType, obj: u64) void {
    switch (cap_type) {
        .empty, .debug_log, .spawner, .mmio, .irq => {},
        .channel_a => unrefSide(@ptrFromInt(obj), .a),
        .channel_b => unrefSide(@ptrFromInt(obj), .b),
        .notification => unrefNotification(@ptrFromInt(obj)),
        .shm => unrefShm(@ptrFromInt(obj)),
        .domain_ctl => if (domain_ctl_release) |f| f(obj),
    }
}

