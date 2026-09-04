//! The HAL: everything the generic kernel needs from the machine, behind
//! one comptime switch on the target. Only the selected port is analyzed
//! and compiled — nothing of another architecture reaches the binary.
//!
//! The interface is the list below; a port is a directory under `arch/`
//! whose `arch.zig` provides every name with the documented shape. Generic
//! code imports this file and nothing under `arch/` directly; arch code
//! may call up into the generic kernel (the trap handler dispatches
//! syscalls, a secondary core registers with the scheduler), and those
//! upcalls are the exported/C-ABI functions the assembly names plus the
//! public API of the generic modules.

const builtin = @import("builtin");

const impl = switch (builtin.cpu.arch) {
    .aarch64 => @import("arch/aarch64/arch.zig"),
    else => @compileError("moss has no port for this architecture"),
};

/// A short name for the banner ("aarch64 / qemu-virt").
pub const name = impl.name;
/// The kernel's direct map: virt = phys + kvirt_offset.
pub const kvirt_offset = impl.kvirt_offset;
/// The boot entry: referenced so its assembly is emitted.
pub const boot = impl.boot;
/// Interrupt masking, the per-core pointer, the cycle counter, halting.
pub const cpu = impl.cpu;
/// Exception vectors, the trap frame, `init` per core.
pub const trap = impl.trap;
/// Kernel thread context and user entry: `Context`, `FpState`,
/// `initContext`, `switchContext`, `fpSave`/`fpRestore`, `enterUser`.
pub const thread = impl.thread;
/// Page tables, kernel and user: `init`, `activate`, `mapDeviceLive`,
/// `UserPerms`, `mapUserPage(Tagged)`, `unmapUserPages`,
/// `destroyUserSpace`, `switchUser`, `publishTables`.
pub const mmu = impl.mmu;
/// The one door to user memory (PAN here, SMAP on x86_64).
pub const uaccess = impl.uaccess;
/// The interrupt controller: line interrupts (`line_base`, `line_count`,
/// `enableLine`, `disableLine`, `configureEdge`), `initCore`, `kick`,
/// `acknowledge`, `endOfInterrupt`, `spurious`, `lineState`.
pub const intc = impl.intc;
/// Message-signalled interrupts: `active`, `base`, `count`, `route`,
/// `doorbellPage`, `translater`.
pub const msi = impl.msi;
/// The per-core tick source: `initCore`, `rearm`, `intid`.
pub const timer = impl.timer;
/// `systemOff`.
pub const power = impl.power;
/// Secondary cores: `bringUp`.
pub const smp = impl.smp;
/// The IOMMU in front of the bus.
pub const iommu = impl.iommu;
/// The hypervisor (a port without one answers `NotHost`).
pub const vm = impl.vm;
/// Discovery of memory and devices from firmware: `discover`,
/// `initInterrupts`, `initIommu`, `intxIntid`, the `MemRegion` and
/// `PcieHost` shapes.
pub const platform = impl.platform;
/// The boot console: `write`.
pub const console = impl.console;
