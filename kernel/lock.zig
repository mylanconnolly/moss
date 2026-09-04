//! Spinlocks. The IRQ-saving form is the default in kernel paths: a lock
//! taken with interrupts enabled invites deadlock the moment an interrupt
//! handler wants the same lock on the same core.

const std = @import("std");
const arch = @import("arch.zig");

pub const SpinLock = struct {
    v: std.atomic.Value(u32) = .init(0),

    pub fn lock(self: *SpinLock) void {
        while (true) {
            if (self.v.cmpxchgWeak(0, 1, .acquire, .monotonic) == null) return;
            while (self.v.load(.monotonic) != 0) {
                std.atomic.spinLoopHint();
            }
        }
    }

    pub fn unlock(self: *SpinLock) void {
        self.v.store(0, .release);
    }

    /// Mask IRQs on this core, then take the lock. Returns the saved
    /// interrupt state for unlockRestore.
    pub fn lockIrqSave(self: *SpinLock) arch.cpu.IrqState {
        const saved = arch.cpu.irqSave();
        self.lock();
        return saved;
    }

    pub fn unlockRestore(self: *SpinLock, saved: arch.cpu.IrqState) void {
        self.unlock();
        arch.cpu.irqRestore(saved);
    }
};
