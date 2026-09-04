//! x86_64, UEFI era only: Limine boot, x2APIC, the TSC, ACPI, a 16550
//! console. Stage 1 of the port: boot to kmain on the boot core, the
//! memory map, the page tables, power-off; no interrupts, no user mode
//! yet. This file maps the port's modules onto the HAL's names
//! (kernel/arch.zig).

const boot_mod = @import("boot.zig");
const stubs = @import("stubs.zig");

pub const name = "x86_64 / uefi (stage 1)";
pub const kvirt_offset: u64 = boot_mod.kvirt_offset;

pub const boot = boot_mod;
pub const cpu = @import("cpu.zig");
pub const trap = @import("trap.zig");
pub const thread = @import("thread.zig");
pub const mmu = @import("mmu.zig");
pub const uaccess = @import("uaccess.zig");
pub const intc = stubs.intc;
pub const msi = stubs.msi;
pub const timer = stubs.timer;
pub const power = @import("power.zig");
pub const smp = @import("smp.zig");
pub const iommu = stubs.iommu;
pub const vm = @import("vm.zig");
pub const platform = @import("platform.zig");
pub const console = @import("console.zig");
