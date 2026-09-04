//! The interrupt controller as the HAL names it: the local APIC per core
//! (acknowledge is implicit — the vector arrives in the frame — and
//! end-of-interrupt is one MSR write), the I/O APICs for lines, an IPI
//! to kick a core. Interrupt ids are vectors: lines 32..127 (GSI + 32),
//! messages 128..223, the tick 0xf0, the kick 0xf1, spurious 0xff.

const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const smp = @import("smp.zig");

pub const line_base = ioapic.line_base;
pub const line_count = ioapic.line_count;
pub const spurious = lapic.vector_spurious;
pub const enableLine = ioapic.enableLine;
pub const disableLine = ioapic.disableLine;
pub const configureEdge = ioapic.configureEdge;
pub const LineState = ioapic.LineState;
pub const lineState = ioapic.lineState;

pub fn initCore(cpu: u32) void {
    _ = cpu;
    lapic.initCore();
}

/// Nudge a core (by scheduler index) into its preemption path.
pub fn kick(cpu: u32) void {
    lapic.sendIpi(smp.apicIdOf(cpu), lapic.vector_resched);
}

/// The vector is in the frame; nothing to read.
pub fn acknowledge() u32 {
    return spurious;
}

pub fn endOfInterrupt(intid: u32) void {
    _ = intid;
    lapic.eoi();
}
