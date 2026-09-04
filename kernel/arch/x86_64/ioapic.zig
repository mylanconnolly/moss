//! The I/O APICs, from the MADT: each owns a range of global system
//! interrupts (GSIs) and a redirection table entry per line. A line's
//! interrupt id is 32 + its GSI, and the vector it raises is that id, so
//! delivery needs no translation. ISA lines take the polarity and
//! trigger the MADT's overrides give them; PCI lines are level, active
//! low. Every line goes to the boot core, as on the aarch64 port.

const cpu = @import("cpu.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const mmu = @import("mmu.zig");

pub const line_base: u32 = 32;
pub const line_count: u32 = 96;

const Ioapic = struct { base: u64, gsi_base: u32, count: u32 };
var ioapics: [4]Ioapic = undefined;
var nioapics: usize = 0;
const Override = struct { gsi: u32, level: bool, low: bool };
var overrides: [16]Override = undefined;
var noverrides: usize = 0;
var bsp_apic_id: u32 = 0;

pub fn add(base: u64, gsi_base: u32) void {
    if (nioapics == ioapics.len) return;
    mmu.mapDeviceLive(base, mem.page_size) catch @panic("ioapic: cannot map registers");
    const ver = readReg(base, 1);
    const count = ((ver >> 16) & 0xff) + 1;
    ioapics[nioapics] = .{ .base = base, .gsi_base = gsi_base, .count = count };
    nioapics += 1;
    // Everything masked until bound.
    for (0..count) |i| writeRte(base, @intCast(i), 1 << 16, 0);
    log.info("ioapic: at 0x{x}, GSIs {d}..{d}", .{ base, gsi_base, gsi_base + count - 1 });
}

pub fn addOverride(gsi: u32, flags: u16) void {
    if (noverrides == overrides.len) return;
    overrides[noverrides] = .{ .gsi = gsi, .level = flags & 0xc == 0xc, .low = flags & 0x3 == 0x3 };
    noverrides += 1;
}

pub fn setBsp(apic_id: u32) void {
    bsp_apic_id = apic_id;
}

fn readReg(base: u64, reg: u32) u32 {
    mem.physToPtr(*volatile u32, base).* = reg;
    return mem.physToPtr(*volatile u32, base + 0x10).*;
}

fn writeReg(base: u64, reg: u32, v: u32) void {
    mem.physToPtr(*volatile u32, base).* = reg;
    mem.physToPtr(*volatile u32, base + 0x10).* = v;
}

fn writeRte(base: u64, i: u32, lo: u32, hi: u32) void {
    writeReg(base, 0x11 + 2 * i, hi);
    writeReg(base, 0x10 + 2 * i, lo);
}

fn find(gsi: u32) ?struct { base: u64, i: u32 } {
    for (ioapics[0..nioapics]) |a| {
        if (gsi >= a.gsi_base and gsi < a.gsi_base + a.count) return .{ .base = a.base, .i = gsi - a.gsi_base };
    }
    return null;
}

fn lineMode(gsi: u32) struct { level: bool, low: bool } {
    for (overrides[0..noverrides]) |o| if (o.gsi == gsi) return .{ .level = o.level, .low = o.low };
    // ISA lines are edge/high by default; PCI's are level/low.
    return if (gsi < 16) .{ .level = false, .low = false } else .{ .level = true, .low = true };
}

pub fn enableLine(intid: u32) void {
    const gsi = intid - line_base;
    const a = find(gsi) orelse return;
    const m = lineMode(gsi);
    var lo: u32 = intid; // vector = interrupt id, fixed delivery, physical
    if (m.low) lo |= 1 << 13;
    if (m.level) lo |= 1 << 15;
    writeRte(a.base, a.i, lo, bsp_apic_id << 24);
}

pub fn disableLine(intid: u32) void {
    const a = find(intid - line_base) orelse return;
    const lo = readReg(a.base, 0x10 + 2 * a.i);
    writeReg(a.base, 0x10 + 2 * a.i, lo | (1 << 16));
}

pub fn configureEdge(intid: u32) void {
    const a = find(intid - line_base) orelse return;
    const lo = readReg(a.base, 0x10 + 2 * a.i);
    writeReg(a.base, 0x10 + 2 * a.i, lo & ~@as(u32, 1 << 15));
}

pub const LineState = struct { enabled: bool, pending: bool, active: bool };

pub fn lineState(intid: u32) LineState {
    const a = find(intid - line_base) orelse return .{ .enabled = false, .pending = false, .active = false };
    const lo = readReg(a.base, 0x10 + 2 * a.i);
    return .{ .enabled = lo & (1 << 16) == 0, .pending = lo & (1 << 12) != 0, .active = lo & (1 << 14) != 0 };
}
