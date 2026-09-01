//! Spinlocks. The IRQ-saving form is the default in kernel paths: a lock
//! taken with interrupts enabled invites deadlock the moment an interrupt
//! handler wants the same lock on the same core.

const std = @import("std");

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

    /// Mask IRQs on this core, then take the lock. Returns the saved DAIF
    /// state for unlockRestore.
    pub fn lockIrqSave(self: *SpinLock) u64 {
        const daif = asm ("mrs %[v], daif"
            : [v] "=r" (-> u64),
        );
        asm volatile ("msr daifset, #2");
        self.lock();
        return daif;
    }

    pub fn unlockRestore(self: *SpinLock, daif: u64) void {
        self.unlock();
        asm volatile ("msr daif, %[v]"
            :
            : [v] "r" (daif),
        );
    }
};
