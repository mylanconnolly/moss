//! PCIe host: what firmware would have done, and the table behind device
//! capabilities. At boot the kernel walks bus 0 of the ECAM window from
//! the devicetree, assigns every memory BAR out of the host's 32-bit MMIO
//! window (nobody else has: we boot straight from -kernel), enables
//! memory decoding and bus mastering, and records each endpoint — its
//! config page, the BAR its virtio registers live in, its INTx line, and
//! its stream id (the requester id the SMMU sees). A device capability
//! names an entry here; holding it is holding the device.

const std = @import("std");
const dt = @import("dt.zig");
const its = @import("its.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const shared = @import("shared");

pub const max_devices = 16;

pub const Device = struct {
    slot: u8,
    vendor: u16,
    device: u16,
    kind: shared.DeviceKind,
    /// The function's 4K page of configuration space (ECAM).
    cfg_pa: u64,
    /// The BAR holding the virtio capabilities (common cfg et al).
    bar_index: u8,
    bar_pa: u64,
    bar_len: u64,
    /// The device's interrupt as a GIC intid: an LPI when it has MSI-X
    /// and the ITS is present, else its INTx SPI (0 = none).
    intid: u32,
    /// MSI-X capability offset in config space (0 = none), and the BAR
    /// holding its table.
    msix_cap: u16 = 0,
    msix_table_pa: u64 = 0,
    /// Requester id: bus << 8 | slot << 3 | function.
    sid: u32,
};

pub var devices: [max_devices]Device = undefined;
pub var count: usize = 0;

var host: dt.PcieHost = undefined;
var mmio_next: u64 = 0;

const virtio_vendor = 0x1af4;
const virtio_modern_base = 0x1040;

pub fn init(h: dt.PcieHost) void {
    host = h;
    // Bus 0 only: 32 slots x 8 functions x 4K of config space.
    mmu.mapDeviceLive(h.ecam_base, 1 << 20) catch @panic("pci: cannot map ECAM");
    mmio_next = h.mmio_base;
    for (0..32) |slot| probe(@intCast(slot));
    if (count == 0) log.warn("pci: no endpoints on bus 0", .{});
}

pub fn byKind(kind: shared.DeviceKind) ?usize {
    for (devices[0..count], 0..) |d, i| {
        if (d.kind == kind) return i;
    }
    return null;
}

fn cfg(comptime T: type, slot: u8, off: u64) *volatile T {
    return mem.physToPtr(*volatile T, host.ecam_base + (@as(u64, slot) << 15) + off);
}

fn probe(slot: u8) void {
    const vendor = cfg(u16, slot, 0).*;
    if (vendor == 0xffff) return;
    const device = cfg(u16, slot, 2).*;
    const class = cfg(u32, slot, 8).* >> 16;
    const header = cfg(u8, slot, 0xe).* & 0x7f;
    if (header != 0 or class == 0x0600) return; // bridges, the host bridge
    if (count == max_devices) {
        log.warn("pci: 00:{d}.0 ignored (device table full)", .{slot});
        return;
    }

    // BARs: size by writing all-ones, then place, size-aligned, in the
    // 32-bit window. 64-bit BARs take two slots; I/O BARs are ignored.
    var bars: [6]struct { pa: u64, len: u64 } = @splat(.{ .pa = 0, .len = 0 });
    var i: u64 = 0;
    while (i < 6) {
        const off = 0x10 + i * 4;
        const r = cfg(u32, slot, off);
        const orig = r.*;
        r.* = 0xffff_ffff;
        const mask = r.*;
        r.* = orig;
        if (mask == 0 or mask & 1 != 0) {
            i += 1;
            continue;
        }
        const is64 = (mask >> 1) & 3 == 2;
        var size_mask: u64 = mask & ~@as(u32, 0xf);
        if (is64) {
            const rh = cfg(u32, slot, off + 4);
            const origh = rh.*;
            rh.* = 0xffff_ffff;
            size_mask |= @as(u64, rh.*) << 32;
            rh.* = origh;
        } else {
            size_mask |= 0xffff_ffff_0000_0000;
        }
        const size = ~size_mask + 1;
        const pa = std.mem.alignForward(u64, mmio_next, @max(size, mem.page_size));
        if (pa + size > host.mmio_base + host.mmio_size) {
            log.warn("pci: 00:{d}.0 BAR{d} ({d}K) does not fit the MMIO window", .{ slot, i, size >> 10 });
            return;
        }
        r.* = @truncate(pa);
        if (is64) cfg(u32, slot, off + 4).* = @truncate(pa >> 32);
        mmio_next = pa + size;
        bars[i] = .{ .pa = pa, .len = size };
        i += if (is64) 2 else 1;
    }
    // Memory decoding + bus mastering (DMA); the SMMU, when present, is
    // what makes the latter safe to hand to userspace.
    cfg(u16, slot, 4).* = cfg(u16, slot, 4).* | 0x6;

    // The BAR the virtio common configuration lives in, and MSI-X.
    var bar_index: u8 = 0xff;
    var msix_cap: u16 = 0;
    var msix_table_pa: u64 = 0;
    if (cfg(u16, slot, 6).* & 0x10 != 0) {
        var ptr: u64 = cfg(u8, slot, 0x34).* & 0xfc;
        var guard: u32 = 0;
        while (ptr != 0 and guard < 48) : (guard += 1) {
            const id = cfg(u8, slot, ptr).*;
            if (id == 0x09 and cfg(u8, slot, ptr + 3).* == 1 and bar_index == 0xff) {
                bar_index = cfg(u8, slot, ptr + 4).*;
            } else if (id == 0x11) {
                msix_cap = @intCast(ptr);
                const tab = cfg(u32, slot, ptr + 4).*;
                const bir = tab & 7;
                if (bir < 6 and bars[bir].len != 0) msix_table_pa = bars[bir].pa + (tab & ~@as(u32, 7));
            }
            ptr = cfg(u8, slot, ptr + 1).* & 0xfc;
        }
    }
    const pin = cfg(u8, slot, 0x3d).*;
    const intid: u32 = if (pin == 0) 0 else 32 + host.intx_base + ((@as(u32, slot) + pin - 1) % 4);
    const kind: shared.DeviceKind = if (vendor == virtio_vendor and device >= virtio_modern_base and device < virtio_modern_base + shared.device_kind_count)
        @enumFromInt(device - virtio_modern_base)
    else
        .none;

    devices[count] = .{
        .slot = slot,
        .vendor = vendor,
        .device = device,
        .kind = kind,
        .cfg_pa = host.ecam_base + (@as(u64, slot) << 15),
        .bar_index = if (bar_index < 6) bar_index else 0,
        .bar_pa = if (bar_index < 6) bars[bar_index].pa else 0,
        .bar_len = if (bar_index < 6) bars[bar_index].len else 0,
        .intid = intid,
        .msix_cap = msix_cap,
        .msix_table_pa = msix_table_pa,
        .sid = @as(u32, slot) << 3,
    };
    count += 1;
    log.info("pci: 00:{d}.0 {x:0>4}:{x:0>4} {t} bar{d}=0x{x}+{d}K intid={d} sid={d}", .{
        slot, vendor, device, kind, devices[count - 1].bar_index, devices[count - 1].bar_pa, devices[count - 1].bar_len >> 10, intid, devices[count - 1].sid,
    });
}

/// After the ITS is up: every device with MSI-X gets entry 0 of its table
/// pointed at the ITS doorbell with event 0, the capability enabled, and
/// an LPI routed to it. The INTx line stays as the fallback for a device
/// without MSI-X (or a machine without an ITS).
pub fn setupMsi() void {
    if (!its.active) return;
    for (devices[0..count]) |*d| {
        if (d.msix_cap == 0 or d.msix_table_pa == 0) continue;
        const lpi = its.route(d.sid) orelse {
            log.warn("pci: 00:{d}.0 no LPI left; staying on INTx {d}", .{ d.slot, d.intid });
            continue;
        };
        mmu.mapDeviceLive(d.msix_table_pa & ~@as(u64, 0xfff), mem.page_size) catch @panic("pci: msix map");
        const entry = mem.physToPtr([*]volatile u32, d.msix_table_pa);
        entry[0] = @truncate(its.translater());
        entry[1] = @truncate(its.translater() >> 32);
        entry[2] = 0; // event id
        entry[3] = 0; // unmasked
        // Message control: enable, function mask clear.
        const mc = cfg(u16, d.slot, d.msix_cap + 2);
        mc.* = (mc.* | 0x8000) & ~@as(u16, 0x4000);
        log.info("pci: 00:{d}.0 msi-x -> lpi {d} (was intx {d})", .{ d.slot, lpi, d.intid });
        d.intid = lpi;
    }
}
