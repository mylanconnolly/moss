//! VT-d, scalable mode, first-stage translation: the IOMMU in front of
//! the PCIe bus walks the page tables of the domain that holds a device's
//! capability — the very same PML4 the CPU uses for that domain, so a
//! driver's device sees exactly what the driver sees and nothing else
//! (first-stage walks require the user bit, so the kernel half is out of
//! reach by construction). Device address == the driver's virtual
//! address, as on the aarch64 port's SMMU. A device without a holder has
//! no present context entry and its DMA is refused; a transaction that
//! misses the holder's tables is refused and recorded in the fault
//! register, which the kernel reads on the IOMMU's interrupt.
//!
//! Layout: a root table (bus 0's entry points at one scalable-mode
//! context table for devfn 0..127), one PASID directory and one PASID
//! table shared by every device — device table index `i` uses PASID
//! `i + 1` as its RID_PASID, so its PASID entry is its binding: PGTT =
//! first-stage, DID = the domain's ASID, FLPTPTR = the domain's root.
//! Invalidations go through the queue (scalable mode allows nothing
//! else): PASID-cache, PASID-IOTLB and context-cache descriptors, then
//! a wait descriptor whose status word the kernel polls.

const std = @import("std");
const acpi = @import("acpi.zig");
const lock = @import("../../lock.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const mmu = @import("mmu.zig");
const msi = @import("msi.zig");
const pci = @import("../../pci.zig");
const pmem = @import("../../pmem.zig");

pub var active = false;
pub var fault_count: u64 = 0;
pub var last_fault_type: u32 = 0;
pub var last_fault_sid: u32 = 0;
pub var last_fault_addr: u64 = 0;
/// The first refused address since the counter was last read to zero.
pub var first_fault_addr: u64 = 0;
const log_first_events = 4;

var base: u64 = 0;
var root_pa: u64 = 0;
var ctx_pa: u64 = 0;
var pasid_dir_pa: u64 = 0;
var pasid_tbl_pa: u64 = 0;
var iq_pa: u64 = 0;
var status_pa: u64 = 0;
var iq_tail: u32 = 0;
var gcmd: u32 = 0;
var fault_vector: u32 = 0;
var cmd_lock: lock.SpinLock = .{};
var holder: [pci.max_devices]?*anyopaque = @splat(null);

// Registers.
const r_cap = 0x08;
const r_ecap = 0x10;
const r_gcmd = 0x18;
const r_gsts = 0x1c;
const r_rtaddr = 0x20;
const r_fsts = 0x34;
const r_fectl = 0x38;
const r_fedata = 0x3c;
const r_feaddr = 0x40;
const r_iqh = 0x80;
const r_iqt = 0x88;
const r_iqa = 0x90;
const r_frcd_lo = 0x220;
const r_frcd_hi = 0x228;

const gcmd_te: u32 = 1 << 31;
const gcmd_srtp: u32 = 1 << 30;
const gcmd_qie: u32 = 1 << 26;
const ecap_smts: u64 = 1 << 43;
const ecap_flts: u64 = 1 << 47;
const ecap_qi: u64 = 1 << 1;

const iq_entries = 128; // 32-byte descriptors, one page

fn reg32(off: u64) *volatile u32 {
    return mem.physToPtr(*volatile u32, base + off);
}

fn reg64(off: u64) *volatile u64 {
    return mem.physToPtr(*volatile u64, base + off);
}

fn setGcmd(bit: u32, status_bit: u32) void {
    gcmd |= bit;
    reg32(r_gcmd).* = gcmd;
    while (reg32(r_gsts).* & status_bit == 0) std.atomic.spinLoopHint();
}

/// The DMAR's first DRHD: the register base.
fn drhdBase() ?u64 {
    const pa = acpi.find("DMAR") orelse return null;
    const b = acpi.bytes(pa);
    var off: usize = 48; // header (36), width (1), flags (1), reserved (10)
    while (off + 16 <= b.len) {
        const kind = std.mem.readInt(u16, b[off..][0..2], .little);
        const len = std.mem.readInt(u16, b[off + 2 ..][0..2], .little);
        if (len < 16) break;
        if (kind == 0) return std.mem.readInt(u64, b[off + 8 ..][0..8], .little);
        off += len;
    }
    return null;
}

pub fn init() void {
    base = drhdBase() orelse {
        log.warn("vtd: no DMAR/DRHD; device DMA is untranslated", .{});
        return;
    };
    mmu.mapDeviceLive(base, mem.page_size) catch @panic("vtd: cannot map registers");
    const ecap = reg64(r_ecap).*;
    if (ecap & ecap_smts == 0 or ecap & ecap_flts == 0 or ecap & ecap_qi == 0) {
        log.warn("vtd: at 0x{x} without scalable-mode first-stage translation (ecap=0x{x}); DMA stays untranslated", .{ base, ecap });
        return;
    }
    root_pa = pmem.allocZeroed() orelse @panic("vtd: no frames");
    ctx_pa = pmem.allocZeroed() orelse @panic("vtd: no frames");
    pasid_dir_pa = pmem.allocZeroed() orelse @panic("vtd: no frames");
    pasid_tbl_pa = pmem.allocZeroed() orelse @panic("vtd: no frames");
    iq_pa = pmem.allocZeroed() orelse @panic("vtd: no frames");
    status_pa = pmem.allocZeroed() orelse @panic("vtd: no frames");
    // Bus 0's root entry -> the context table; every context entry ->
    // the one PASID directory -> the one PASID table (entries filled at
    // attach). RID_PASID = index + 1, so an unbound device (or one whose
    // slot was never registered) resolves to a non-present PASID entry.
    mem.physToPtr([*]volatile u64, root_pa)[0] = ctx_pa | 1;
    mem.physToPtr([*]volatile u64, pasid_dir_pa)[0] = pasid_tbl_pa | 1;

    // The fault interrupt: a message to the boot core, a vector of ours.
    fault_vector = msi.route(0xffff) orelse @panic("vtd: no vector for faults");
    reg32(r_fedata).* = fault_vector;
    reg32(r_feaddr).* = @truncate(msi.translater());
    reg32(r_fectl).* = 0; // unmask

    reg64(r_rtaddr).* = root_pa | (1 << 10); // scalable-mode table
    setGcmd(gcmd_srtp, 1 << 30);
    reg64(r_iqa).* = iq_pa | 0x800; // 256-bit descriptors, 2^(0+7) of them
    reg64(r_iqt).* = 0;
    iq_tail = 0;
    setGcmd(gcmd_qie, 1 << 26);
    setGcmd(gcmd_te, 1 << 31);
    active = true;
    log.info("vtd: at 0x{x}, scalable-mode first-stage translation on; a device without a holder is refused", .{base});
}

// ----------------------------------------------------------- the queue

/// Append one 256-bit descriptor.
fn issue(d: [4]u64) void {
    const q = mem.physToPtr([*]volatile u64, iq_pa);
    const i: usize = iq_tail * 4;
    q[i] = d[0];
    q[i + 1] = d[1];
    q[i + 2] = d[2];
    q[i + 3] = d[3];
    iq_tail = (iq_tail + 1) % iq_entries;
}

/// Submit what was appended and wait: a wait descriptor writes a status
/// word the kernel polls (on QEMU the queue is drained at the tail
/// write; hardware is asynchronous).
var wait_serial: u32 = 0;

fn sync() void {
    wait_serial +%= 1;
    const want: u32 = wait_serial | 0x8000_0000;
    const status = mem.physToPtr(*volatile u32, status_pa);
    status.* = 0;
    issue(.{ 0x5 | (1 << 5) | (@as(u64, want) << 32), status_pa, 0, 0 }); // wait, status write
    asm volatile ("" ::: .{ .memory = true });
    reg64(r_iqt).* = @as(u64, iq_tail) << 5;
    while (status.* != want) {
        if (reg32(r_fsts).* & (1 << 4) != 0) @panic("vtd: invalidation queue error");
        std.atomic.spinLoopHint();
    }
}

fn invalidateDevice(sid: u32, did: u16, pasid: u32) void {
    // Context cache, device-selective; PASID cache, PASID-selective;
    // PASID-IOTLB, everything in the PASID.
    issue(.{ 0x1 | (3 << 4) | (@as(u64, did) << 16) | (@as(u64, sid) << 32), 0, 0, 0 });
    issue(.{ 0x7 | (1 << 4) | (@as(u64, did) << 16) | (@as(u64, pasid) << 32), 0, 0, 0 });
    issue(.{ 0x6 | (2 << 4) | (@as(u64, did) << 16) | (@as(u64, pasid) << 32), 0, 0, 0 });
}

// ------------------------------------------------------ attach/detach

fn pasidEntry(idx: u64) [*]volatile u64 {
    return mem.physToPtr([*]volatile u64, pasid_tbl_pa + (idx + 1) * 64);
}

fn contextEntry(sid: u32) [*]volatile u64 {
    return mem.physToPtr([*]volatile u64, ctx_pa + @as(u64, sid & 0x7f) * 32);
}

/// Bind device `idx` to the address space (root, asid); `who` is the
/// holding domain, an opaque token teardown hands back.
pub fn attach(idx: u64, root: u64, asid: u16, who: *anyopaque) void {
    if (!active or idx >= pci.count) return;
    const irqs = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(irqs);
    const dev = &pci.devices[idx];
    const pasid: u32 = @intCast(idx + 1);
    const pe = pasidEntry(idx);
    pe[2] = root & 0x000f_ffff_ffff_f000; // FLPTPTR, 4-level (FLPM 0)
    pe[1] = asid; // DID
    for (3..8) |i| pe[i] = 0;
    asm volatile ("" ::: .{ .memory = true });
    pe[0] = 1 | (1 << 6); // present, first-stage translation
    const ce = contextEntry(dev.sid);
    ce[1] = pasid; // RID_PASID
    ce[2] = 0;
    ce[3] = 0;
    asm volatile ("" ::: .{ .memory = true });
    ce[0] = pasid_dir_pa | 1; // present, PDTS 0 (one page)
    invalidateDevice(dev.sid, asid, pasid);
    sync();
    holder[idx] = who;
}

/// No hypervisor on this port: a guest never holds a device.
pub fn attachStage2(idx: u64, s2_root: u64, vmid: u16, who: *anyopaque) void {
    _ = .{ idx, s2_root, vmid, who };
}

pub fn detachStage2(idx: u64, vmid: u16, who: *anyopaque) void {
    _ = .{ idx, vmid, who };
}

/// Unbind device `idx` if `who` is its holder: the entries go
/// non-present and the caches are dropped before the tables can go away.
pub fn detachIfHolder(idx: u64, who: *anyopaque, asid: u16) void {
    if (!active or idx >= pci.count) return;
    const irqs = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(irqs);
    if (holder[idx] != who) return;
    holder[idx] = null;
    const dev = &pci.devices[idx];
    contextEntry(dev.sid)[0] = 0;
    pasidEntry(idx)[0] = 0;
    asm volatile ("" ::: .{ .memory = true });
    invalidateDevice(dev.sid, asid, @intCast(idx + 1));
    sync();
}

/// A domain's page tables changed under a live binding (an shm window
/// unmapped): retire whatever the IOMMU cached for its domain id.
pub fn invalidateAsid(asid: u16) void {
    if (!active) return;
    const irqs = cmd_lock.lockIrqSave();
    defer cmd_lock.unlockRestore(irqs);
    // IOTLB, domain-selective (covers every PASID bound to the domain).
    issue(.{ 0x2 | (2 << 4) | (@as(u64, asid) << 16), 0, 0, 0 });
    sync();
}

// ------------------------------------------------------------- faults

fn faultName(fr: u32) []const u8 {
    return switch (fr) {
        0x01 => "root entry not present",
        0x02 => "context entry not present (no holder)",
        0x51 => "PASID directory entry not present",
        0x59 => "PASID entry not present (no holder)",
        0x5b => "invalid PASID entry",
        0x70 => "first-stage paging entry unreadable",
        0x71 => "first-stage paging entry not present (unmapped)",
        0x72 => "first-stage paging entry: reserved bits",
        0x73 => "invalid first-stage root",
        0x80 => "non-canonical address",
        0x81 => "privilege violation (a kernel page)",
        0x85 => "no write permission",
        else => "fault",
    };
}

/// From the interrupt path: true if `vector` was ours. The one fault
/// recording register is read and released; a device retrying a refused
/// burst records again.
pub fn handleIrq(vector: u32) bool {
    if (!active or vector != fault_vector) return false;
    while (true) {
        const hi = reg64(r_frcd_hi).*;
        if (hi & (1 << 63) == 0) break;
        const lo = reg64(r_frcd_lo).*;
        const fr: u32 = @truncate((hi >> 32) & 0xff);
        const sid: u32 = @truncate(hi & 0xffff);
        fault_count += 1;
        last_fault_type = fr;
        last_fault_sid = sid;
        last_fault_addr = lo & ~@as(u64, 0xfff);
        if (fault_count == 1) first_fault_addr = last_fault_addr;
        if (fault_count <= log_first_events) {
            log.warn("vtd: DMA refused — {s} (0x{x}) sid={d} addr=0x{x}{s}", .{ faultName(fr), fr, sid, last_fault_addr, if (hi & (1 << 62) != 0) " read" else " write" });
        } else if (fault_count == log_first_events + 1) {
            log.warn("vtd: further refusals counted, not logged (fault_count)", .{});
        }
        reg64(r_frcd_hi).* = 1 << 63; // release the record
    }
    reg32(r_fsts).* = 0x1 | (1 << 4); // overflow, queue error: cleared
    return true;
}
