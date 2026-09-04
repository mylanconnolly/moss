//! SMMUv3: the IOMMU in front of the PCIe bus, stage-1 translation. A
//! device's DMA is translated through the page tables of the domain that
//! holds its device capability — the very same TTBR0 the CPU uses for
//! that domain, so a driver's device sees exactly what the driver sees
//! and nothing else. Device address == the driver's virtual address; a
//! shared buffer mapped into a driver is DMA-able exactly because the
//! driver can see it. Streams without a holder have no valid stream
//! table entry and abort; a transaction that misses the holder's tables
//! aborts too and is recorded on the event queue, which the kernel
//! drains on its interrupt and logs — the driver learns nothing, memory
//! it was not given stays untouched.
//!
//! Layout: a linear stream table (256 entries: bus 0's requester ids),
//! one context descriptor per device-table index, a command queue and
//! an event queue, one page each. Attach writes the CD (TTB0 = the
//! domain's tables, its ASID, MAIR as the kernel programs it), then the
//! STE, then invalidates the STE's cached config and syncs; detach
//! clears the STE and invalidates the ASID's TLB entries — before the
//! domain's tables are freed, which is why teardown does it while
//! releasing capabilities.

const std = @import("std");
const dt = @import("../../dt.zig");
const gic = @import("gic.zig");
const lock = @import("../../lock.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const mmu = @import("mmu.zig");
const pci = @import("../../pci.zig");
const pmem = @import("../../pmem.zig");

pub var active = false;
pub var fault_count: u64 = 0;
pub var last_fault_type: u32 = 0;
pub var last_fault_sid: u32 = 0;
pub var last_fault_addr: u64 = 0;
/// The first refused address since the counter was last read to zero —
/// a device that keeps retrying (QEMU splits a refused burst into
/// word-sized retries) reports hundreds of events for one request.
pub var first_fault_addr: u64 = 0;
const log_first_events = 4;

var base: u64 = 0;
var info: dt.Smmu = undefined;
var strtab_pa: u64 = 0;
var strtab_raw_pa: u64 = 0;
var cd_pa: u64 = 0;
var cmdq_pa: u64 = 0;
var evtq_pa: u64 = 0;
var cmdq_prod: u32 = 0;
var evtq_cons: u32 = 0;
var cmd_lock: lock.SpinLock = .{};
var holder: [pci.max_devices]?*anyopaque = @splat(null);

const strtab_log2 = 8; // 256 STEs x 64B = 16K
const cmdq_log2 = 8; // 256 x 16B = 4K
const evtq_log2 = 7; // 128 x 32B = 4K

// Registers (page 0 unless noted).
const r_idr0 = 0x0;
const r_idr1 = 0x4;
const r_idr5 = 0x14;
const r_cr0 = 0x20;
const r_cr0ack = 0x24;
const r_cr1 = 0x28;
const r_cr2 = 0x2c;
const r_gbpa = 0x44;
const r_irq_ctrl = 0x50;
const r_irq_ctrlack = 0x54;
const r_gerror = 0x60;
const r_gerrorn = 0x64;
const r_strtab_base = 0x80;
const r_strtab_base_cfg = 0x88;
const r_cmdq_base = 0x90;
const r_cmdq_prod = 0x98;
const r_cmdq_cons = 0x9c;
const r_evtq_base = 0xa0;
const r_evtq_prod = 0x100a8; // page 1
const r_evtq_cons = 0x100ac;

const cr0_smmuen = 1 << 0;
const cr0_evtqen = 1 << 2;
const cr0_cmdqen = 1 << 3;

fn reg32(off: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, base + off);
}

fn reg64(off: u64) *volatile u64 {
    return mem.physToPtr(*volatile u64, base + off);
}

fn writeCr0(v: u32) void {
    reg32(r_cr0).* = v;
    while (reg32(r_cr0ack).* != v) std.atomic.spinLoopHint();
}

pub fn init(i: dt.Smmu) void {
    info = i;
    base = i.base;
    mmu.mapDeviceLive(base, i.size) catch @panic("smmu: cannot map registers");

    const idr0 = reg32(r_idr0).*;
    const idr1 = reg32(r_idr1).*;
    const idr5 = reg32(r_idr5).*;
    const s1p = idr0 & (1 << 1) != 0;
    const ttf_aa64 = idr0 & (1 << 3) != 0;
    const sidsize: u32 = idr1 & 0x3f;
    const gran4k = idr5 & (1 << 4) != 0;
    if (!s1p or !ttf_aa64 or !gran4k or sidsize < strtab_log2) {
        log.warn("smmu: unusable (idr0=0x{x} idr1=0x{x} idr5=0x{x}); DMA stays untranslated", .{ idr0, idr1, idr5 });
        return;
    }

    writeCr0(0);
    // Tables and queues: inner-shareable, write-back read/write-allocate.
    reg32(r_cr1).* = (3 << 10) | (1 << 8) | (1 << 6) | (3 << 4) | (1 << 2) | 1;
    // Private TLB maintenance (we invalidate explicitly), record C_BAD_STREAMID.
    reg32(r_cr2).* = (1 << 2) | (1 << 1);

    // The stream table wants its size alignment (16K): carve from 32K.
    strtab_raw_pa = pmem.allocContiguous(8) orelse @panic("smmu: no frames");
    strtab_pa = std.mem.alignForward(u64, strtab_raw_pa, 16 << 10);
    @memset(mem.physToPtr([*]u8, strtab_pa)[0 .. 16 << 10], 0);
    cd_pa = pmem.allocZeroed() orelse @panic("smmu: no frames");
    cmdq_pa = pmem.allocZeroed() orelse @panic("smmu: no frames");
    evtq_pa = pmem.allocZeroed() orelse @panic("smmu: no frames");
    asm volatile ("dsb ish");

    reg64(r_strtab_base).* = strtab_pa | (1 << 62); // RA
    reg32(r_strtab_base_cfg).* = strtab_log2; // linear
    reg64(r_cmdq_base).* = cmdq_pa | cmdq_log2 | (1 << 62);
    reg32(r_cmdq_prod).* = 0;
    reg32(r_cmdq_cons).* = 0;
    reg64(r_evtq_base).* = evtq_pa | evtq_log2 | (1 << 62);
    reg32(r_evtq_prod).* = 0;
    reg32(r_evtq_cons).* = 0;
    cmdq_prod = 0;
    evtq_cons = 0;

    writeCr0(cr0_cmdqen);
    issue(.{ 0x04, 31 }); // CFGI_ALL
    issue(.{ 0x30, 0 }); // TLBI_NSNH_ALL
    sync();

    reg32(r_irq_ctrl).* = (1 << 2) | 1; // EVTQ, GERROR
    while (reg32(r_irq_ctrlack).* != ((1 << 2) | 1)) std.atomic.spinLoopHint();
    writeCr0(cr0_cmdqen | cr0_evtqen);
    // Wired, edge-triggered (the devicetree says so; a pulse on a
    // level-sensitive line is never seen).
    gic.configureEdge(info.irqs[0]);
    gic.configureEdge(info.irqs[3]);
    gic.enableSpi(info.irqs[0]);
    gic.enableSpi(info.irqs[3]);
    writeCr0(cr0_cmdqen | cr0_evtqen | cr0_smmuen);
    active = true;
    log.info("smmu: v3 at 0x{x}, stage-1 translation on, {d}-bit stream ids; a device without a holder aborts", .{ base, sidsize });
}

// ------------------------------------------------------------ commands

fn issue(cmd: [2]u64) void {
    const q = mem.physToPtr([*]volatile u64, cmdq_pa);
    const mask: u32 = (1 << cmdq_log2) - 1;
    // Full when the index matches and the wrap bit differs.
    while (true) {
        const cons = reg32(r_cmdq_cons).*;
        if ((cmdq_prod & mask) != (cons & mask) or ((cmdq_prod ^ cons) & (1 << cmdq_log2)) == 0) break;
        std.atomic.spinLoopHint();
    }
    const idx = cmdq_prod & mask;
    q[idx * 2] = cmd[0];
    q[idx * 2 + 1] = cmd[1];
    asm volatile ("dsb ish");
    cmdq_prod = (cmdq_prod + 1) & ((1 << (cmdq_log2 + 1)) - 1);
    reg32(r_cmdq_prod).* = cmdq_prod;
}

/// CMD_SYNC, then wait for the queue to drain: every earlier command,
/// invalidations included, has completed.
fn sync() void {
    issue(.{ 0x46, 0 });
    while (reg32(r_cmdq_cons).* != cmdq_prod) std.atomic.spinLoopHint();
}

// ------------------------------------------------------- attach/detach

/// Bind device `idx`'s stream to the address space (ttbr0, asid); `who`
/// is the holding domain, an opaque token teardown hands back.
pub fn attach(idx: u64, ttbr0_pa: u64, asid: u16, who: *anyopaque) void {
    if (!active or idx >= pci.count) return;
    const daif = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(daif);
    const dev = &pci.devices[idx];
    const cd = mem.physToPtr([*]volatile u64, cd_pa + idx * 64);
    // Context descriptor: T0SZ 25 (39-bit VA), 4K, WB RA/WA, inner
    // shareable, TTB1 disabled, IPS 40-bit, access flag faults off,
    // AArch64 tables, record faults and abort them, private ASID.
    cd[0] = 25 | (1 << 8) | (1 << 10) | (3 << 12) | (1 << 30) | (1 << 31) |
        (@as(u64, 2) << 32) | (1 << 35) | (1 << 41) | (1 << 45) | (1 << 46) | (1 << 47) |
        (@as(u64, asid) << 48);
    cd[1] = ttbr0_pa & 0x000f_ffff_ffff_fff0;
    cd[2] = 0;
    cd[3] = 0xff00; // MAIR: idx0 Device-nGnRnE, idx1 Normal WB — as the CPU's
    cd[4] = 0;
    cd[5] = 0;
    cd[6] = 0;
    cd[7] = 0;
    asm volatile ("dsb ish");
    const ste = mem.physToPtr([*]volatile u64, strtab_pa + @as(u64, dev.sid) * 64);
    // dw1 first: S1CIR/S1COR WB, S1CSH inner, NS-EL1, PRIVCFG = privileged
    // (the device may reach the privileged-only ITS doorbell page; every
    // user page is accessible to privileged transactions too). S1STALLD
    // stays 0: QEMU's model rejects the entry otherwise (the CD's S=0
    // already makes faults terminate rather than stall).
    ste[1] = (1 << 2) | (1 << 4) | (3 << 6) | (@as(u64, 3) << 48);
    ste[2] = 0;
    ste[3] = 0;
    asm volatile ("dsb ish");
    // dw0 last: valid, stage-1 translate / stage-2 bypass, the CD.
    ste[0] = 1 | (0b101 << 1) | ((cd_pa + idx * 64) & 0x000f_ffff_ffff_ffc0);
    asm volatile ("dsb ish");
    issue(.{ 0x03 | (@as(u64, dev.sid) << 32), 1 }); // CFGI_STE leaf
    sync();
    holder[idx] = who;
}

/// Bind device `idx`'s stream to a guest: stage-2 translation through
/// the VM's tables (39-bit IPA, start level 1, 4K, 40-bit PA), stage 1
/// bypassed — the guest's own DMA addresses are IPAs, and only the
/// guest's memory is reachable. `who` is the VM.
pub fn attachStage2(idx: u64, s2_root: u64, vmid: u16, who: *anyopaque) void {
    if (!active or idx >= pci.count) return;
    const daif = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(daif);
    const dev = &pci.devices[idx];
    const ste = mem.physToPtr([*]volatile u64, strtab_pa + @as(u64, dev.sid) * 64);
    ste[1] = 0;
    // S2VMID, S2T0SZ 25, S2SL0 1, WB RA/WA, inner shareable, 4K, 40-bit PA,
    // AArch64 tables, access-flag faults off, record faults.
    ste[2] = @as(u64, vmid) | (@as(u64, 25) << 32) | (@as(u64, 1) << 38) | (@as(u64, 1) << 40) |
        (@as(u64, 1) << 42) | (@as(u64, 3) << 44) | (@as(u64, 2) << 48) | (@as(u64, 1) << 51) |
        (@as(u64, 1) << 53) | (@as(u64, 1) << 58);
    ste[3] = s2_root & 0x000f_ffff_ffff_fff0;
    asm volatile ("dsb ish");
    ste[0] = 1 | (0b110 << 1); // valid, stage 1 bypass / stage 2 translate
    asm volatile ("dsb ish");
    issue(.{ 0x03 | (@as(u64, dev.sid) << 32), 1 });
    sync();
    holder[idx] = who;
    log.info("smmu: stream {d} -> stage 2, vmid {d}", .{ dev.sid, vmid });
}

/// Unbind a guest's device: STE invalid, the VMID's stage-2 TLB entries
/// dropped, before the VM's tables go away.
pub fn detachStage2(idx: u64, vmid: u16, who: *anyopaque) void {
    if (!active or idx >= pci.count) return;
    const daif = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(daif);
    if (holder[idx] != who) return;
    holder[idx] = null;
    const dev = &pci.devices[idx];
    const ste = mem.physToPtr([*]volatile u64, strtab_pa + @as(u64, dev.sid) * 64);
    ste[0] = 0;
    asm volatile ("dsb ish");
    issue(.{ 0x03 | (@as(u64, dev.sid) << 32), 1 });
    issue(.{ 0x28 | (@as(u64, vmid) << 32), 0 }); // TLBI_S12_VMALL
    sync();
}

/// Unbind device `idx` if `who` is its holder: the STE goes invalid and
/// the ASID's TLB entries are dropped before the tables can go away.
pub fn detachIfHolder(idx: u64, who: *anyopaque, asid: u16) void {
    if (!active or idx >= pci.count) return;
    const daif = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(daif);
    if (holder[idx] != who) return;
    holder[idx] = null;
    const dev = &pci.devices[idx];
    const ste = mem.physToPtr([*]volatile u64, strtab_pa + @as(u64, dev.sid) * 64);
    ste[0] = 0;
    asm volatile ("dsb ish");
    issue(.{ 0x03 | (@as(u64, dev.sid) << 32), 1 });
    issue(.{ 0x11 | (@as(u64, asid) << 48), 0 }); // TLBI_NH_ASID
    sync();
}

/// A domain's page tables changed under a live stream (an shm window
/// unmapped): retire whatever the SMMU cached for its ASID before the
/// frames are reused.
pub fn invalidateAsid(asid: u16) void {
    if (!active) return;
    const daif = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(daif);
    issue(.{ 0x11 | (@as(u64, asid) << 48), 0 }); // TLBI_NH_ASID
    sync();
}

// ------------------------------------------------------------- events

/// From the trap handler: true if `intid` was one of ours.
pub fn handleIrq(intid: u32) bool {
    if (!active) return false;
    if (intid == info.irqs[0]) {
        drainEvents();
        return true;
    }
    if (intid == info.irqs[3]) {
        const err = reg32(r_gerror).*;
        if (err & (1 << 2) != 0) {
            // A flood (one refused burst retried word by word) outran
            // the event queue: events were dropped, the count stands.
            log.warn("smmu: event queue overflowed; refusals beyond the queue were dropped", .{});
        } else {
            log.warn("smmu: global error 0x{x}", .{err});
        }
        reg32(r_gerrorn).* = err;
        return true;
    }
    return false;
}

fn eventName(t: u32) []const u8 {
    return switch (t) {
        0x01 => "F_UUT",
        0x02 => "C_BAD_STREAMID (no holder)",
        0x03 => "F_STE_FETCH",
        0x04 => "C_BAD_STE",
        0x05 => "F_BAD_ATS_TREQ",
        0x06 => "F_STREAM_DISABLED",
        0x07 => "F_TRANSL_FORBIDDEN",
        0x08 => "C_BAD_SUBSTREAMID",
        0x09 => "F_CD_FETCH",
        0x0a => "C_BAD_CD",
        0x0b => "F_WALK_EABT",
        0x10 => "F_TRANSLATION (unmapped)",
        0x11 => "F_ADDR_SIZE",
        0x12 => "F_ACCESS",
        0x13 => "F_PERMISSION",
        else => "event",
    };
}

fn drainEvents() void {
    const q = mem.physToPtr([*]volatile u64, evtq_pa);
    const mask: u32 = (1 << evtq_log2) - 1;
    while (true) {
        const prod = reg32(r_evtq_prod).*;
        if ((prod & 0x7fff_ffff) == evtq_cons) break;
        const idx = evtq_cons & mask;
        const dw0 = q[idx * 4];
        const addr = q[idx * 4 + 2];
        const t: u32 = @truncate(dw0 & 0xff);
        const sid: u32 = @truncate(dw0 >> 32);
        fault_count += 1;
        last_fault_type = t;
        last_fault_sid = sid;
        last_fault_addr = addr;
        if (fault_count == 1) first_fault_addr = addr;
        if (fault_count <= log_first_events) {
            log.warn("smmu: DMA refused — {s} sid={d} addr=0x{x}", .{ eventName(t), sid, addr });
        } else if (fault_count == log_first_events + 1) {
            log.warn("smmu: further refusals counted, not logged (fault_count)", .{});
        }
        evtq_cons = (evtq_cons + 1) & ((1 << (evtq_log2 + 1)) - 1);
        reg32(r_evtq_cons).* = evtq_cons;
    }
}
