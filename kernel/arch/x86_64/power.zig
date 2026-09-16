//! Power off: ACPI S5 — the sleep type from the DSDT's `_S5_` package
//! written to PM1a_CNT with SLP_EN. What every x86 machine since 1999
//! has done; QEMU's q35 answers it by exiting.

const acpi = @import("acpi.zig");
const cpu = @import("cpu.zig");
const log = @import("../../log.zig");

/// Reset: the PCI reset control register (0xCF9), a full reset with
/// SYS_RST | RST_CPU — what chipsets since the 440BX honour and QEMU's
/// q35 answers by rebooting. Halts if nothing listens.
pub fn systemReset() noreturn {
    cpu.irqMaskAll();
    cpu.outb(0xcf9, 0x02);
    cpu.outb(0xcf9, 0x06);
    while (true) cpu.halt();
}

pub fn systemOff() noreturn {
    cpu.irqMaskAll();
    if (acpi.fadt()) |f| {
        if (acpi.s5SleepType(f.dsdt)) |typ| {
            const val: u16 = (@as(u16, typ) << 10) | (1 << 13);
            if (f.pm1b_cnt != 0) cpu.outw(@intCast(f.pm1b_cnt), val);
            cpu.outw(@intCast(f.pm1a_cnt), val);
        } else log.warn("power: no _S5_ in the DSDT; halting instead", .{});
    } else log.warn("power: no FADT; halting instead", .{});
    while (true) cpu.halt();
}
