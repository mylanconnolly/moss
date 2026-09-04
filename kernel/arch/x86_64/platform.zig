//! What the loader tells this port about the machine: Limine's memory
//! map, the command line, the RSDP (ACPI: the FADT for power-off, later
//! the MADT and MCFG), the TSC frequency and the CPU list. Everything is
//! copied out of the loader's memory here, while its direct map is
//! still the one in force beside ours; after mmu.activate only what the
//! port kept is reachable.

const std = @import("std");
const acpi = @import("acpi.zig");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");
const ioapic = @import("ioapic.zig");
const lapic = @import("lapic.zig");
const limine = @import("limine.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const msi = @import("msi.zig");

pub const MemRegion = struct { base: u64, size: u64 };
pub const Reg = struct { base: u64, size: u64 };
/// The PCIe host bridge as pci.zig wants it (from the MCFG, later).
pub const PcieHost = struct { ecam_base: u64, mmio_base: u64, mmio_size: u64, intx_base: u32 };

pub const Info = struct {
    regions: []const MemRegion,
    reserved: []const Reg,
    bootargs: ?[]const u8,
    pcie: ?PcieHost,
};

const max_regions = 32;
var region_buf: [max_regions]MemRegion = undefined;
var reserved_buf: [max_regions]Reg = undefined;
var cmdline_buf: [256]u8 = undefined;
/// Firmware memory the direct map must also cover: the ACPI tables.
pub var extra_maps: [max_regions]Reg = undefined;
pub var extra_map_count: usize = 0;
pub var rsdp_pa: u64 = 0;

fn loaderToPhys(p: u64) u64 {
    return p - boot.hhdm_offset;
}

pub fn discover(boot_arg: u64) Info {
    _ = boot_arg; // the responses are globals the loader filled
    if (boot.bootloader_info_request.response) |bi| {
        const name = mem.physToPtr([*:0]const u8, loaderToPhys(@intFromPtr(bi.name)));
        const ver = mem.physToPtr([*:0]const u8, loaderToPhys(@intFromPtr(bi.version)));
        log.info("boot: {s} {s}, base revision {d}", .{ std.mem.span(name), std.mem.span(ver), boot.limine_base_revision[1] });
    }
    const mm = boot.memmap_request.response orelse @panic("limine: no memory map");
    const entries: [*]const u64 = @ptrFromInt(mem.physToVirt(loaderToPhys(@intFromPtr(mm.entries))));
    var nr: usize = 0;
    var nres: usize = 0;
    for (0..mm.entry_count) |i| {
        const e = mem.physToPtr(*const limine.MemmapEntry, loaderToPhys(entries[i]));
        switch (e.type) {
            .usable => if (nr < max_regions) {
                region_buf[nr] = .{ .base = e.base, .size = e.length };
                nr += 1;
            },
            // The loader's data (responses, the parked cores' state) is
            // RAM the allocator will own once every reader is done with
            // it; it is mapped and reserved until then.
            .bootloader_reclaimable => if (nr < max_regions and nres < max_regions) {
                region_buf[nr] = .{ .base = e.base, .size = e.length };
                nr += 1;
                reserved_buf[nres] = .{ .base = e.base, .size = e.length };
                nres += 1;
            },
            .acpi_reclaimable, .acpi_nvs, .reserved_mapped => if (extra_map_count < max_regions) {
                extra_maps[extra_map_count] = .{ .base = e.base, .size = e.length };
                extra_map_count += 1;
            },
            else => {},
        }
    }
    // The image itself, where the loader placed it.
    if (nres < max_regions) {
        reserved_buf[nres] = .{ .base = boot.image_phys_base, .size = mem.kernelEnd() - mem.kernelStart() };
        nres += 1;
    }
    var bootargs: ?[]const u8 = null;
    if (boot.cmdline_request.response) |c| {
        const s = std.mem.span(mem.physToPtr([*:0]const u8, loaderToPhys(@intFromPtr(c.cmdline))));
        const n = @min(s.len, cmdline_buf.len);
        @memcpy(cmdline_buf[0..n], s[0..n]);
        if (n > 0) bootargs = cmdline_buf[0..n];
    }
    var pcie: ?PcieHost = null;
    if (boot.rsdp_request.response) |r| {
        rsdp_pa = loaderToPhys(r.address);
        acpi.init(rsdp_pa);
        if (acpi.fadt()) |f| {
            log.info("acpi: FADT pm1a_cnt=0x{x}, S5 sleep type {?d}", .{ f.pm1a_cnt, acpi.s5SleepType(f.dsdt) });
            // The PCIe host: ECAM from the MCFG, the BAR window from the
            // host bridge's resources in the DSDT. INTx lines on this
            // class of machine are GSIs 16..23 (PCI links); MSI-X is what
            // the enumerator uses.
            if (acpi.mcfg()) |m| {
                if (acpi.pciWindow(f.dsdt)) |w| {
                    pcie = .{ .ecam_base = m.base, .mmio_base = w.base, .mmio_size = w.size, .intx_base = 16 + 32 };
                } else log.warn("acpi: no 32-bit memory window in the DSDT; no BAR placement", .{});
            } else log.warn("acpi: no MCFG; no PCIe", .{});
        } else log.warn("acpi: no FADT; no power-off", .{});
    } else log.warn("limine: no RSDP; no ACPI, no power-off", .{});
    if (boot.tsc_request.response) |t| {
        cpu.tsc_hz = t.frequency;
    } else {
        const l = cpu.cpuid(0x15, 0);
        if (l.eax != 0 and l.ebx != 0 and l.ecx != 0) cpu.tsc_hz = @as(u64, l.ecx) * l.ebx / l.eax;
    }
    if (cpu.tsc_hz == 0) @panic("x86_64: no TSC frequency from the loader or CPUID.15H");
    if (boot.mp_request.response) |mp| {
        cpu.x2apic = mp.flags & limine.mp_x2apic != 0;
        @import("smp.zig").note(mp);
    }
    log.info("tsc: {d} MHz; {s}", .{ cpu.tsc_hz / 1_000_000, cpu.describe() });
    return .{
        .regions = region_buf[0..nr],
        .reserved = reserved_buf[0..nres],
        .bootargs = bootargs,
        .pcie = pcie,
    };
}

/// The IOMMU: stage 4 of the port.
pub fn initIommu(info: *const Info) void {
    _ = info;
    log.warn("x86_64: no IOMMU driver yet; device DMA is untranslated", .{});
}

/// The I/O APICs and the ISA overrides, from the MADT; the local APICs
/// are per core (intc.initCore). Every line and message targets the boot
/// core, whose id the MSI doorbell address carries.
pub fn initInterrupts(info: *const Info) void {
    _ = info;
    ioapic.setBsp(lapic.id());
    msi.setBsp(lapic.id());
    const pa = acpi.find("APIC") orelse {
        log.warn("acpi: no MADT; no I/O APIC lines", .{});
        return;
    };
    const b = acpi.bytes(pa);
    var off: usize = 44; // header (36) + local APIC address (4) + flags (4)
    while (off + 2 <= b.len) {
        const kind = b[off];
        const len = b[off + 1];
        if (len < 2 or off + len > b.len) break;
        switch (kind) {
            1 => ioapic.add(std.mem.readInt(u32, b[off + 4 ..][0..4], .little), std.mem.readInt(u32, b[off + 8 ..][0..4], .little)),
            2 => ioapic.addOverride(std.mem.readInt(u32, b[off + 4 ..][0..4], .little), std.mem.readInt(u16, b[off + 8 ..][0..2], .little)),
            else => {},
        }
        off += len;
    }
}

/// The line a function's INTx pin raises (an interrupt id: 32 + GSI),
/// by the conventional slot swizzle; the enumerator uses MSI-X, so
/// this is the fallback for a device without it.
pub fn intxIntid(host: PcieHost, slot: u8, pin: u8) u32 {
    return host.intx_base + ((@as(u32, slot) + pin - 1) % 4);
}
