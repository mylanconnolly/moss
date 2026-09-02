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
const gic = @import("gic.zig");
const ipc = @import("ipc.zig");
const its = @import("its.zig");
const lock = @import("lock.zig");

const spi_base = 32;
const max_spis = 256;
const lpi_base = its.lpi_base;
const max_lpis = its.max_lpis;

var bindings: [max_spis]?*ipc.Notification = @splat(null);
var lpi_bindings: [max_lpis]?*ipc.Notification = @splat(null);
var irq_lock: lock.SpinLock = .{};

fn slot(intid: u32) ?*?*ipc.Notification {
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
        const daif = irq_lock.lockIrqSave();
        defer irq_lock.unlockRestore(daif);
        if (s.* != null) return Error.Busy;
        s.* = n;
    }
    if (!isLpi(intid)) gic.enableSpi(intid);
}

/// Re-enable a level line after the driver serviced the device; LPIs are
/// messages, nothing to re-enable.
pub fn ack(intid: u32) Error!void {
    if (slot(intid) == null) return Error.OutOfRange;
    if (!isLpi(intid)) gic.enableSpi(intid);
}

/// From the trap handler (IRQs masked): true if the interrupt was bound
/// and delivered. A level-triggered SPI is masked until acked; an LPI
/// is an edge and just delivered.
pub fn deliver(intid: u32) bool {
    const s = slot(intid) orelse return false;
    const daif = irq_lock.lockIrqSave();
    const n = s.* orelse {
        irq_lock.unlockRestore(daif);
        return false;
    };
    if (!isLpi(intid)) gic.disableSpi(intid);
    irq_lock.unlockRestore(daif);
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
        if (b.* == n) {
            b.* = null;
            gic.disableSpi(@intCast(spi_base + i));
        }
    }
    for (&lpi_bindings) |*b| {
        if (b.* == n) b.* = null;
    }
}

/// Debug: log GIC state for every bound SPI.
pub fn debugDump() void {
    const log = @import("log.zig");
    for (&bindings, 0..) |b, i| {
        if (b == null) continue;
        const intid: u32 = @intCast(spi_base + i);
        const reg = intid / 32;
        const bit = @as(u32, 1) << @intCast(intid % 32);
        const enabled = gic.gicdRead(0x100 + reg * 4) & bit != 0;
        const pending = gic.gicdRead(0x200 + reg * 4) & bit != 0;
        const active = gic.gicdRead(0x300 + reg * 4) & bit != 0;
        log.info("irq[{d}]: enabled={} pending={} active={} bits={x}", .{
            intid, enabled, pending, active, b.?.bits,
        });
    }
}
