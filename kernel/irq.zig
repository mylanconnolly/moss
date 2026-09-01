//! IRQ-as-message: an SPI bound to a notification is delivered by masking
//! the line (level-triggered sources must not storm) and signaling the
//! notification; the driver handles the device, then irq_ack re-enables.
//!
//! Bindings share the scheduler's big lock with the notification state, so
//! delivery, binding, and notification teardown cannot race.

const std = @import("std");
const gic = @import("gic.zig");
const ipc = @import("ipc.zig");
const sched = @import("sched.zig");

const spi_base = 32;
const max_spis = 256;

var bindings: [max_spis]?*ipc.Notification = @splat(null);

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
    if (intid < spi_base or intid >= spi_base + max_spis) return Error.OutOfRange;
    {
        const daif = sched.acquire();
        defer sched.release(daif);
        if (bindings[intid - spi_base] != null) return Error.Busy;
        bindings[intid - spi_base] = n;
    }
    gic.enableSpi(intid);
}

pub fn ack(intid: u32) Error!void {
    if (intid < spi_base or intid >= spi_base + max_spis) return Error.OutOfRange;
    gic.enableSpi(intid);
}

/// From the trap handler (IRQs masked): true if the SPI was bound and
/// delivered.
pub fn deliver(intid: u32) bool {
    if (intid < spi_base or intid >= spi_base + max_spis) return false;
    const daif = sched.acquire();
    defer sched.release(daif);
    const n = bindings[intid - spi_base] orelse return false;
    gic.disableSpi(intid);
    ipc.signalLocked(n, 1);
    return true;
}

/// Called by notification teardown WITH THE BIG LOCK HELD: sever any
/// bindings so a dead notification is never signaled, and mask the lines —
/// an unbound level-triggered device would interrupt-storm to nowhere.
fn onNotificationFreed(n: *ipc.Notification) void {
    for (&bindings, 0..) |*b, i| {
        if (b.* == n) {
            b.* = null;
            gic.disableSpi(@intCast(spi_base + i));
        }
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
