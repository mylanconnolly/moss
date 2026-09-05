//! What firmware tells this port about the machine: the devicetree QEMU
//! leaves in RAM (x0 at entry, per the arm64 Image boot protocol) —
//! memory, the boot arguments, the PCIe host bridge, the SMMU, the ITS.
//! The generic kernel sees a `Info` and the init calls below; nothing
//! outside this directory reads the tree.

const std = @import("std");
const dt = @import("../../dt.zig");
const gic = @import("gic.zig");
const its = @import("its.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const smmu = @import("smmu.zig");
const mmu = @import("mmu.zig");

pub const MemRegion = dt.MemRegion;
pub const PcieHost = dt.PcieHost;
pub const Reg = dt.Reg;

pub const Info = struct {
    regions: []const MemRegion,
    /// Firmware memory the allocator must not hand out (the tree itself).
    reserved: []const Reg,
    bootargs: ?[]const u8,
    pcie: ?PcieHost,
    smmu: ?dt.Smmu = null,
    its: ?Reg = null,
    /// The PL031 real-time clock, when the tree has one.
    rtc: ?Reg = null,
};

var region_buf: [8]MemRegion = undefined;
var reserved_buf: [2]Reg = undefined;

/// Parse the tree at physical `boot_arg`. Panics on a bad tree: there is
/// no machine to run on without one.
pub fn discover(boot_arg: u64) Info {
    const fdt = dt.Fdt.parse(mem.physToPtr([*]const u8, boot_arg)) catch |e| {
        std.debug.panic("bad devicetree at 0x{x}: {t}", .{ boot_arg, e });
    };
    const regions = fdt.memoryRegions(&region_buf) catch |e| {
        std.debug.panic("devicetree memory walk failed: {t}", .{e});
    };
    reserved_buf[0] = .{ .base = boot_arg, .size = fdt.totalSize() };
    // The image lives inside the direct map on this port.
    reserved_buf[1] = .{ .base = mem.virtToPhys(mem.kernelStart()), .size = mem.kernelEnd() - mem.kernelStart() };
    const pcie = fdt.pcieHost();
    if (pcie == null) log.warn("devicetree: no PCIe host; userspace drivers will find no devices", .{});
    return .{
        .regions = regions,
        .reserved = &reserved_buf,
        .bootargs = fdt.bootargs(),
        .pcie = pcie,
        .smmu = fdt.smmu(),
        .its = fdt.findReg("arm,gic-v3-its"),
        .rtc = fdt.findReg("arm,pl031"),
    };
}

/// The real-time clock, read once: Unix seconds from the PL031's data
/// register, or nothing when the machine has none.
pub fn rtcSeconds(info: *const Info) ?u64 {
    const r = info.rtc orelse return null;
    mmu.mapDeviceLive(r.base, mem.page_size) catch return null;
    const dr: *volatile u32 = @ptrFromInt(mem.physToVirt(r.base));
    return dr.*;
}

/// The IOMMU, once the memory map is up (its registers need a mapping).
pub fn initIommu(info: *const Info) void {
    if (info.smmu) |i| smmu.init(i) else log.warn("devicetree: no SMMU; device DMA is untranslated", .{});
}

/// The interrupt controller's global part and the MSI translator, from
/// the boot core, before any core's `intc.initCore`.
pub fn initInterrupts(info: *const Info) void {
    gic.initDistributor();
    if (info.its) |r| its.init(r.base, r.size) else log.warn("devicetree: no ITS; devices stay on INTx", .{});
}

/// The line a PCI function's INTx pin (1..4) raises: the virt bridge
/// swizzles by slot onto four SPIs from `intx_base`.
pub fn intxIntid(host: PcieHost, slot: u8, pin: u8) u32 {
    return 32 + host.intx_base + ((@as(u32, slot) + pin - 1) % 4);
}
