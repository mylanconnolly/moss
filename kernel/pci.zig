//! The device table behind device capabilities, and the platform windows
//! behind the enumerator. The kernel does not walk the PCI bus: it hands
//! the ECAM window (bus 0) and the 32-bit MMIO window from the
//! devicetree to root as `window` capabilities, and a userspace
//! enumerator (user/pcisvc.zig — firmware's job, done by a program)
//! sizes and places BARs, programs MSI-X, and registers each endpoint
//! here through `device_register`. What the kernel keeps is what only it
//! can do: the table a device capability names, the LPI it routes
//! through the ITS, and the requester id the SMMU keys its stream on.

const std = @import("std");
const arch = @import("arch.zig");
const log = @import("log.zig");
const shared = @import("shared");

pub const max_devices = 16;

pub const Device = struct {
    slot: u8,
    kind: shared.DeviceKind,
    /// The function's 4K page of configuration space (ECAM).
    cfg_pa: u64,
    /// The BAR holding the virtio capabilities (common cfg et al).
    bar_index: u8,
    bar_pa: u64,
    bar_len: u64,
    /// The device's interrupt id: a message interrupt when the port routed
    /// one (the enumerator then programs MSI-X), else its INTx line.
    intid: u32,
    /// Requester id: bus << 8 | slot << 3 | function.
    sid: u32,
};

pub var devices: [max_devices]Device = undefined;
pub var count: usize = 0;

/// The platform windows a `window` capability names: 0 = ECAM (bus 0),
/// 1 = the 32-bit MMIO window BARs are placed in.
pub const Window = struct { base: u64 = 0, size: u64 = 0 };
pub var windows: [2]Window = @splat(.{});
pub var have_host = false;

var host: arch.platform.PcieHost = undefined;

pub fn init(h: arch.platform.PcieHost) void {
    host = h;
    have_host = true;
    windows[0] = .{ .base = h.ecam_base, .size = 1 << 20 };
    windows[1] = .{ .base = h.mmio_base, .size = h.mmio_size };
    log.info("pci: host bridge — ECAM 0x{x} (bus 0), MMIO window 0x{x}+{d}M, INTx from SPI {d}; enumeration is userspace's", .{
        h.ecam_base, h.mmio_base, h.mmio_size >> 20, h.intx_base,
    });
}

pub const Error = error{ NoHost, TableFull, BadDevice };

/// Register an endpoint the enumerator found: its requester id, kind,
/// the BAR its virtio structures live in, its INTx pin (0 = none), and
/// whether the enumerator can program an MSI-X entry for it — only then
/// is a message interrupt routed; a device whose MSI-X table it cannot
/// reach keeps its INTx line as its interrupt. (The x86_64 port's local
/// APIC routes messages for any device, so without the enumerator's word
/// a guest's passed-through device — its MSI-X BAR hidden by the VMM —
/// would wait on a vector the VMM never delivers.)
/// Returns the table index and the LPI routed for it (0 without an
/// ITS). Registering a requester id again returns the existing entry.
pub fn register(sid: u32, kind: shared.DeviceKind, bar_index: u8, bar_pa: u64, bar_len: u64, pin: u8, want_msi: bool) Error!struct { idx: usize, lpi: u32 } {
    if (!have_host) return Error.NoHost;
    if (sid >= 256 or pin > 4 or bar_index >= 6) return Error.BadDevice;
    if (bar_len != 0 and (bar_pa < windows[1].base or bar_pa + bar_len > windows[1].base + windows[1].size)) return Error.BadDevice;
    for (devices[0..count], 0..) |d, i| {
        if (d.sid == sid) return .{ .idx = i, .lpi = if (d.intid >= arch.msi.base) d.intid else 0 };
    }
    if (count == max_devices) return Error.TableFull;
    const slot: u8 = @intCast(sid >> 3);
    var intid: u32 = if (pin == 0) 0 else arch.platform.intxIntid(host, slot, pin);
    var lpi: u32 = 0;
    if (want_msi) if (arch.msi.route(sid)) |l| {
        lpi = l;
        intid = l;
    };
    devices[count] = .{
        .slot = slot,
        .kind = kind,
        .cfg_pa = windows[0].base + (@as(u64, slot) << 15),
        .bar_index = bar_index,
        .bar_pa = bar_pa,
        .bar_len = bar_len,
        .intid = intid,
        .sid = sid,
    };
    count += 1;
    return .{ .idx = count - 1, .lpi = lpi };
}

pub fn byKind(kind: shared.DeviceKind) ?usize {
    return nthByKind(kind, 0);
}

/// The n-th (0-based) registered device of a kind.
pub fn nthByKind(kind: shared.DeviceKind, nth: usize) ?usize {
    var seen: usize = 0;
    for (devices[0..count], 0..) |d, i| {
        if (d.kind != kind) continue;
        if (seen == nth) return i;
        seen += 1;
    }
    return null;
}
