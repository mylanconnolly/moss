//! aarch64 on QEMU virt: GICv3 (+ITS), the generic timer, PSCI, SMMUv3,
//! a PL011 console, devicetree discovery, and the VHE hypervisor. This
//! file maps the port's modules onto the HAL's names (kernel/arch.zig).

const gic = @import("gic.zig");
const its = @import("its.zig");
const psci = @import("psci.zig");

pub const name = "aarch64 / qemu-virt";
pub const kvirt_offset: u64 = 0xffffff80_0000_0000;

/// The image lives inside the direct map on this port.
pub fn imagePhys(va: u64) u64 {
    return va - kvirt_offset;
}

pub const boot = @import("boot.zig");
pub const cpu = @import("cpu.zig");
pub const trap = @import("trap.zig");
pub const thread = @import("thread.zig");
pub const mmu = @import("mmu.zig");
pub const uaccess = @import("uaccess.zig");
pub const timer = @import("timer.zig");
pub const smp = @import("smp.zig");
pub const iommu = @import("smmu.zig");
pub const vm = @import("vm.zig");
pub const platform = @import("platform.zig");
pub const console = @import("pl011.zig");

pub const intc = struct {
    /// Shared peripheral interrupts: the lines devices and the IOMMU raise.
    pub const line_base: u32 = 32;
    pub const line_count: u32 = 256;
    pub const spurious = gic.spurious_intid;
    pub const initCore = gic.initCore;
    pub const enableLine = gic.enableSpi;
    pub const disableLine = gic.disableSpi;
    pub const configureEdge = gic.configureEdge;
    /// Nudge a core into its preemption path.
    pub const kick = gic.sendSgi;
    pub const acknowledge = gic.acknowledge;
    pub const endOfInterrupt = gic.endOfInterrupt;
    pub const LineState = struct { enabled: bool, pending: bool, active: bool };
    pub fn lineState(intid: u32) LineState {
        const reg = intid / 32;
        const bit = @as(u32, 1) << @intCast(intid % 32);
        return .{
            .enabled = gic.gicdRead(0x100 + reg * 4) & bit != 0,
            .pending = gic.gicdRead(0x200 + reg * 4) & bit != 0,
            .active = gic.gicdRead(0x300 + reg * 4) & bit != 0,
        };
    }
};

pub const msi = struct {
    pub const base = its.lpi_base;
    pub const count = its.max_lpis;
    pub inline fn isActive() bool {
        return its.active;
    }
    pub const route = its.route;
    /// The data word a device writes with its message: the ITS event id
    /// (0 — one event per device is routed).
    pub fn data(intid: u32) u32 {
        _ = intid;
        return 0;
    }
    pub const doorbellPage = its.doorbellPage;
    pub const translater = its.translater;
};

pub const power = struct {
    pub const systemOff = psci.systemOff;
};
