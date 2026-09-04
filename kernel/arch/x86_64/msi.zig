//! Message-signalled interrupts: a device writes a vector to the local
//! APIC's doorbell page (0xfee00000, the boot core's id in the address)
//! and that vector is the interrupt id. Vectors 128..223 are handed out
//! in order and never reclaimed (devices are registered once per boot).
//! The data word a device must write is the vector; the PCI enumerator
//! learns it with the port's PCIe stage.

const ioapic = @import("ioapic.zig");

pub const base: u32 = 128;
pub const count: u32 = 96;
var next: u32 = 0;
var bsp_apic_id: u32 = 0;

pub fn setBsp(apic_id: u32) void {
    bsp_apic_id = apic_id;
}

pub inline fn isActive() bool {
    return true;
}

pub fn route(device_id: u32) ?u32 {
    _ = device_id;
    if (next == count) return null;
    const v = base + next;
    next += 1;
    return v;
}

pub fn doorbellPage() u64 {
    return 0xfee0_0000;
}

/// The address a device targets: the doorbell with the boot core's
/// APIC id (ids past 255 need interrupt remapping, a later step).
pub fn translater() u64 {
    return 0xfee0_0000 | (@as(u64, bsp_apic_id & 0xff) << 12);
}

comptime {
    _ = ioapic;
}
