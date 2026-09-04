//! ACPI, the least of it: the tables the port needs from the RSDP down —
//! the FADT (for the power-off register) and the DSDT (for the S5 sleep
//! type), later the MADT (interrupt controllers) and the MCFG (PCIe).
//! Tables are read through the direct map; the loader guarantees they
//! sit in regions the port maps (platform.zig).

const std = @import("std");
const mem = @import("../../mem.zig");

pub const Header = extern struct {
    signature: [4]u8,
    length: u32 align(1),
    revision: u8,
    checksum: u8,
    oem_id: [6]u8,
    oem_table_id: [8]u8,
    oem_revision: u32 align(1),
    creator_id: u32 align(1),
    creator_revision: u32 align(1),
};

const Rsdp = extern struct {
    signature: [8]u8,
    checksum: u8,
    oem_id: [6]u8,
    revision: u8,
    rsdt_address: u32 align(1),
    length: u32 align(1),
    xsdt_address: u64 align(1),
    ext_checksum: u8,
    reserved: [3]u8,
};

var xsdt_pa: u64 = 0;
var rsdt_pa: u64 = 0;

pub fn init(rsdp_pa: u64) void {
    const rsdp = mem.physToPtr(*const Rsdp, rsdp_pa);
    if (rsdp.revision >= 2 and rsdp.xsdt_address != 0) {
        xsdt_pa = rsdp.xsdt_address;
    } else {
        rsdt_pa = rsdp.rsdt_address;
    }
}

/// The physical address of the table with `sig`, or null.
pub fn find(sig: *const [4]u8) ?u64 {
    if (xsdt_pa != 0) {
        const h = mem.physToPtr(*const Header, xsdt_pa);
        const n = (h.length - @sizeOf(Header)) / 8;
        const entries: [*]align(1) const u64 = @ptrFromInt(mem.physToVirt(xsdt_pa) + @sizeOf(Header));
        for (0..n) |i| {
            const t = mem.physToPtr(*const Header, entries[i]);
            if (std.mem.eql(u8, &t.signature, sig)) return entries[i];
        }
    } else if (rsdt_pa != 0) {
        const h = mem.physToPtr(*const Header, rsdt_pa);
        const n = (h.length - @sizeOf(Header)) / 4;
        const entries: [*]align(1) const u32 = @ptrFromInt(mem.physToVirt(rsdt_pa) + @sizeOf(Header));
        for (0..n) |i| {
            const t = mem.physToPtr(*const Header, entries[i]);
            if (std.mem.eql(u8, &t.signature, sig)) return entries[i];
        }
    }
    return null;
}

pub fn bytes(pa: u64) []const u8 {
    const h = mem.physToPtr(*const Header, pa);
    return mem.physToPtr([*]const u8, pa)[0..h.length];
}

/// The FADT fields the port reads (offsets per ACPI 6).
pub const Fadt = struct {
    pm1a_cnt: u32,
    pm1b_cnt: u32,
    dsdt: u64,
};

pub fn fadt() ?Fadt {
    const pa = find("FACP") orelse return null;
    const b = bytes(pa);
    const rd32 = struct {
        fn f(s: []const u8, off: usize) u32 {
            return if (off + 4 <= s.len) std.mem.readInt(u32, s[off..][0..4], .little) else 0;
        }
    }.f;
    const rd64 = struct {
        fn f(s: []const u8, off: usize) u64 {
            return if (off + 8 <= s.len) std.mem.readInt(u64, s[off..][0..8], .little) else 0;
        }
    }.f;
    var dsdt: u64 = rd64(b, 140); // X_DSDT
    if (dsdt == 0) dsdt = rd32(b, 40); // DSDT
    return .{ .pm1a_cnt = rd32(b, 64), .pm1b_cnt = rd32(b, 68), .dsdt = dsdt };
}

/// The MCFG: the ECAM base of segment 0 and the buses it covers.
pub const Mcfg = struct { base: u64, start_bus: u8, end_bus: u8 };

pub fn mcfg() ?Mcfg {
    const pa = find("MCFG") orelse return null;
    const b = bytes(pa);
    if (b.len < 44 + 16) return null;
    // Header (36), reserved (8), then 16-byte allocations.
    const e = b[44..][0..16];
    return .{
        .base = std.mem.readInt(u64, e[0..8], .little),
        .start_bus = e[10],
        .end_bus = e[11],
    };
}

/// The largest 32-bit memory range the DSDT's resource descriptors
/// hand out (the host bridge's `_CRS`, a DWordMemory descriptor: 0x87,
/// length, resource type 0, flags, granularity, min, max, translation,
/// length) above the first megabyte — where BARs may be placed.
pub fn pciWindow(dsdt_pa: u64) ?Reg {
    const b = bytes(dsdt_pa);
    var best: ?Reg = null;
    var i: usize = 0;
    while (i + 26 <= b.len) : (i += 1) {
        if (b[i] != 0x87 or b[i + 1] != 0x17 or b[i + 2] != 0x00 or b[i + 3] != 0x00) continue;
        const min = std.mem.readInt(u32, b[i + 10 ..][0..4], .little);
        const max = std.mem.readInt(u32, b[i + 14 ..][0..4], .little);
        const len = std.mem.readInt(u32, b[i + 22 ..][0..4], .little);
        if (min < (1 << 20) or max <= min or len == 0) continue;
        if (best == null or len > best.?.size) best = .{ .base = min, .size = len };
    }
    return best;
}

pub const Reg = struct { base: u64, size: u64 };

/// SLP_TYPa for S5 from the DSDT's `_S5_` package: `08 '_S5_' 12 <len>
/// <n> [0a] typa [0a] typb ...` — the one AML shape firmware emits for
/// it, read without an interpreter.
pub fn s5SleepType(dsdt_pa: u64) ?u16 {
    const b = bytes(dsdt_pa);
    var i: usize = 0;
    while (i + 12 < b.len) : (i += 1) {
        if (b[i] == 0x08 and std.mem.eql(u8, b[i + 1 .. i + 5], "_S5_") and b[i + 5] == 0x12) {
            var p = i + 6;
            // PkgLength: the top two bits of the first byte count the
            // following length bytes.
            p += 1 + (b[p] >> 6);
            p += 1; // NumElements
            if (b[p] == 0x0a) p += 1; // BytePrefix
            return b[p];
        }
    }
    return null;
}
