//! GICv3 ITS: message-signalled interrupts as LPIs. A device's MSI-X entry
//! points at GITS_TRANSLATER with an event id; the ITS maps (device id =
//! the PCI requester id, event) to an LPI (intid ≥ 8192) via a per-device
//! interrupt translation table, and a collection (one per core) says
//! which redistributor gets it. LPIs are edge-like messages: nothing to
//! mask or re-enable per interrupt, so INTx line sharing — four wires
//! for a whole bus — stops being a limit on how many devices a boot may
//! carry. Tables: a device table and a collection table (one page each),
//! a command queue (one page), one ITT page per mapped device, one
//! shared LPI configuration table and a per-core pending table.

const std = @import("std");
const gic = @import("gic.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const pmem = @import("pmem.zig");

pub var active = false;
pub var base: u64 = 0;

pub const lpi_base: u32 = 8192;
pub const max_lpis: u32 = 64;
const id_bits = 14; // 16K interrupt ids: LPIs 8192..16383

var cmdq_pa: u64 = 0;
var cmdq_write: u64 = 0; // byte offset
var prop_pa: u64 = 0;
var next_lpi: u32 = 0;
/// One interrupt translation table page per routable device, allocated
/// at init: routing happens at registration time, after the drills'
/// leak baselines, and must not move the frame count.
var itt_pool_pa: u64 = 0;
var pta = false; // GITS_TYPER.PTA: RDbase is an address, not a processor number

const r_ctlr = 0x0;
const r_typer = 0x8;
const r_cbaser = 0x80;
const r_cwriter = 0x88;
const r_creadr = 0x90;
const r_baser0 = 0x100;

fn reg32(off: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, base + off);
}

fn reg64(off: u64) *volatile u64 {
    return mem.physToPtr(*volatile u64, base + off);
}

/// The doorbell a device's MSI targets (GITS_TRANSLATER's page).
pub fn doorbellPage() u64 {
    return base + 0x10000;
}

pub fn translater() u64 {
    return base + 0x10040;
}

const attr_inner_wb: u64 = (1 << 10) | (5 << 59); // inner shareable, RA/WB

pub fn init(its_base: u64, size: u64) void {
    base = its_base;
    mmu.mapDeviceLive(base, size) catch @panic("its: cannot map registers");
    const typer = reg64(r_typer).*;
    pta = typer & (1 << 19) != 0;
    // Quiescent, disabled, before any table is programmed.
    reg32(r_ctlr).* = 0;
    while (reg32(r_ctlr).* & (1 << 31) == 0) std.atomic.spinLoopHint();

    // Device and collection tables: one page each, flat.
    var i: u64 = 0;
    while (i < 8) : (i += 1) {
        const b = reg64(r_baser0 + i * 8).*;
        const kind = (b >> 56) & 7;
        if (kind != 1 and kind != 4) continue;
        const page = pmem.allocZeroed() orelse @panic("its: no frames");
        // Keep the read-only entry-size field, set address, size 1 page.
        reg64(r_baser0 + i * 8).* = (b & (0x1f << 48)) | (kind << 56) | (1 << 63) | attr_inner_wb | page;
    }
    cmdq_pa = pmem.allocZeroed() orelse @panic("its: no frames");
    reg64(r_cbaser).* = (1 << 63) | attr_inner_wb | cmdq_pa; // size 0 = 1 page
    reg64(r_cwriter).* = 0;
    cmdq_write = 0;

    // The LPI configuration table (shared by every redistributor):
    // one byte per LPI, disabled until routed.
    prop_pa = pmem.allocContiguous(2) orelse @panic("its: no frames");
    @memset(mem.physToPtr([*]u8, prop_pa)[0 .. 2 * mem.page_size], 0);
    itt_pool_pa = pmem.allocContiguous(max_lpis) orelse @panic("its: no frames");
    @memset(mem.physToPtr([*]u8, itt_pool_pa)[0 .. max_lpis * mem.page_size], 0);
    asm volatile ("dsb ish");

    reg32(r_ctlr).* = 1; // Enabled
    active = true;
    log.info("its: at 0x{x}, {d} LPIs from {d}, doorbell 0x{x}", .{ base, max_lpis, lpi_base, translater() });
}

/// Per redistributor (the core that owns it, during gic.initCore): the
/// shared configuration table, a private pending table, LPIs on, and a
/// collection naming this core.
pub fn initRedistributor(cpu: u32) void {
    if (!active) return;
    const rd = gic.redistributorBase(cpu);
    // Pending table: 64K-aligned; carve from 32 pages.
    const raw = pmem.allocContiguous(32) orelse @panic("its: no frames");
    const pend = std.mem.alignForward(u64, raw, 64 << 10);
    @memset(mem.physToPtr([*]u8, pend)[0 .. 16 << 10], 0);
    asm volatile ("dsb ish");
    mem.physToPtr(*volatile u64, rd + 0x70).* = prop_pa | (id_bits - 1) | (1 << 10) | (5 << 7); // PROPBASER
    mem.physToPtr(*volatile u64, rd + 0x78).* = pend | (1 << 62) | (1 << 10) | (5 << 7); // PENDBASER, PTZ
    mem.physToPtr(*volatile u32, rd + 0x0).* = 1; // GICR_CTLR.EnableLPIs
    // Collection `cpu` -> this redistributor.
    const rdbase: u64 = if (pta) rd >> 16 else cpu;
    issue(.{ 0x09, 0, @as(u64, cpu) | (rdbase << 16) | (1 << 63), 0 }); // MAPC
    issue(.{ 0x05, 0, rdbase << 16, 0 }); // SYNC
    wait();
}

fn issue(cmd: [4]u64) void {
    const q = mem.physToPtr([*]volatile u64, cmdq_pa + cmdq_write);
    q[0] = cmd[0];
    q[1] = cmd[1];
    q[2] = cmd[2];
    q[3] = cmd[3];
    asm volatile ("dsb ish");
    cmdq_write = (cmdq_write + 32) % mem.page_size;
    reg64(r_cwriter).* = cmdq_write;
}

fn wait() void {
    while ((reg64(r_creadr).* & 0xfffe0) != cmdq_write) std.atomic.spinLoopHint();
}

/// Route MSI event 0 of `device_id` to a fresh LPI delivered to core 0;
/// returns the intid, or null when the ITS is absent or out of LPIs.
pub fn route(device_id: u32) ?u32 {
    if (!active or next_lpi == max_lpis) return null;
    const lpi = lpi_base + next_lpi;
    const itt = itt_pool_pa + @as(u64, next_lpi) * mem.page_size;
    next_lpi += 1;
    // Enabled, priority 0x80 (PMR is open; any priority delivers).
    mem.physToPtr([*]volatile u8, prop_pa)[lpi - lpi_base] = 0x81;
    asm volatile ("dsb ish");
    issue(.{ 0x08 | (@as(u64, device_id) << 32), 3, itt | (1 << 63), 0 }); // MAPD, 16 events
    issue(.{ 0x0a | (@as(u64, device_id) << 32), @as(u64, lpi) << 32, 0, 0 }); // MAPTI event 0 -> lpi, collection 0
    issue(.{ 0x0c | (@as(u64, device_id) << 32), 0, 0, 0 }); // INV
    issue(.{ 0x05, 0, if (pta) gic.redistributorBase(0) >> 16 << 16 else 0, 0 }); // SYNC
    wait();
    return lpi;
}
