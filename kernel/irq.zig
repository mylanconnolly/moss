//! IRQ-as-message: an SPI bound to a notification is delivered by masking
//! the line (level-triggered sources must not storm) and signaling the
//! notification; the driver handles the device, then irq_ack re-enables.
//!
//! Bindings have their own lock, taken inside a notification's (teardown
//! severs bindings under both). Delivery reads the binding under the lock
//! and signals after releasing it, so it never holds irq_lock while
//! taking the notification's — a signal that lands on a notification
//! freed in that window is dropped by signal() itself.

const std = @import("std");
const arch = @import("arch.zig");
const ipc = @import("ipc.zig");
const lock = @import("lock.zig");

const spi_base = arch.intc.line_base;
const max_spis = arch.intc.line_count;
const lpi_base = arch.msi.base;
const max_lpis = arch.msi.count;

/// Where an interrupt goes: a notification (a driver in this kernel's
/// userspace) or a guest (injected as a virtual SPI by vm.zig).
const Target = union(enum) {
    none,
    notif: *ipc.Notification,
    guest: struct { token: *anyopaque, vintid: u32 },
};

var bindings: [max_spis]Target = @splat(.none);
var lpi_bindings: [max_lpis]Target = @splat(.none);
var irq_lock: lock.SpinLock = .{};

fn slot(intid: u32) ?*Target {
    if (intid >= spi_base and intid < spi_base + max_spis) return &bindings[intid - spi_base];
    if (intid >= lpi_base and intid < lpi_base + max_lpis) return &lpi_bindings[intid - lpi_base];
    return null;
}

fn isLpi(intid: u32) bool {
    return intid >= lpi_base;
}

pub fn init() void {
    ipc.notif_freed_hook = &onNotificationFreed;
}

pub const Error = error{
    OutOfRange,
    Busy,
};

/// Route `intid` to a notification. The binding holds no reference: when
/// the notification's caps all die it is freed, and onNotificationFreed
/// severs the binding under the same lock delivery uses.
pub fn bind(intid: u32, n: *ipc.Notification) Error!void {
    const s = slot(intid) orelse return Error.OutOfRange;
    {
        const irqs = irq_lock.lockIrqSave();
        defer irq_lock.unlockRestore(irqs);
        if (s.* != .none) return Error.Busy;
        s.* = .{ .notif = n };
    }
    if (!isLpi(intid)) arch.intc.enableLine(intid);
}

/// Route `intid` into a guest as virtual SPI `vintid` (a passed-through
/// device's interrupt; replaces whatever binding the host held).
pub fn bindGuest(intid: u32, token: *anyopaque, vintid: u32) Error!void {
    const s = slot(intid) orelse return Error.OutOfRange;
    {
        const irqs = irq_lock.lockIrqSave();
        defer irq_lock.unlockRestore(irqs);
        s.* = .{ .guest = .{ .token = token, .vintid = vintid } };
    }
    if (!isLpi(intid)) arch.intc.enableLine(intid);
}

pub fn unbindGuest(intid: u32, token: *anyopaque) void {
    const s = slot(intid) orelse return;
    const irqs = irq_lock.lockIrqSave();
    defer irq_lock.unlockRestore(irqs);
    if (s.* == .guest and s.guest.token == token) s.* = .none;
}

/// Re-enable a level line after the driver serviced the device; LPIs are
/// messages, nothing to re-enable.
pub fn ack(intid: u32) Error!void {
    if (slot(intid) == null) return Error.OutOfRange;
    if (!isLpi(intid)) arch.intc.enableLine(intid);
}

/// From the trap handler (IRQs masked): true if the interrupt was bound
/// and delivered. A level-triggered SPI is masked until acked; an LPI
/// is an edge and just delivered.
pub fn deliver(intid: u32) bool {
    const s = slot(intid) orelse return false;
    const irqs = irq_lock.lockIrqSave();
    const target = s.*;
    if (target == .none) {
        irq_lock.unlockRestore(irqs);
        return false;
    }
    if (!isLpi(intid)) arch.intc.disableLine(intid);
    irq_lock.unlockRestore(irqs);
    if (target == .guest) {
        arch.vm.injectSpi(target.guest.token, target.guest.vintid);
        return true;
    }
    const n = target.notif;
    ipc.signal(n, 1);
    return true;
}

/// Called by notification teardown with the notification's lock held:
/// sever any bindings so a dead notification is never signaled, and mask
/// the lines — an unbound level-triggered device would interrupt-storm to
/// nowhere.
fn onNotificationFreed(n: *ipc.Notification) void {
    irq_lock.lock();
    defer irq_lock.unlock();
    for (&bindings, 0..) |*b, i| {
        if (b.* == .notif and b.notif == n) {
            b.* = .none;
            arch.intc.disableLine(@intCast(spi_base + i));
        }
    }
    for (&lpi_bindings) |*b| {
        if (b.* == .notif and b.notif == n) b.* = .none;
    }
}

/// Debug: log the controller's state for every bound line.
pub fn debugDump() void {
    const log = @import("log.zig");
    for (&bindings, 0..) |b, i| {
        if (b == .none) continue;
        const intid: u32 = @intCast(spi_base + i);
        const st = arch.intc.lineState(intid);
        log.info("irq[{d}]: enabled={} pending={} active={} target={s}", .{
            intid, st.enabled, st.pending, st.active, @tagName(b),
        });
    }
}
