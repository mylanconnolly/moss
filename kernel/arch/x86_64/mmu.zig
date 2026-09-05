//! Page tables: 4-level, 4K granule, 48-bit VAs. The direct map at
//! `kvirt_offset` (PML4 slot 256 up) as 2 MB pages, RW and NX; the
//! kernel image in the top 2 GB (slot 511) as 4K pages, W^X from the
//! linker symbols; device MMIO 4K, uncached, at direct-map addresses.
//! Every user root shares the kernel half: its upper PML4 entries are
//! copied from the kernel's on first use.
//!
//! This stage keeps one CR3 per switch with a full TLB flush; PCIDs and
//! cross-core shootdowns arrive with SMP.

const std = @import("std");
const boot = @import("boot.zig");
const cpu = @import("cpu.zig");
const kalloc = @import("../../kalloc.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const lapic = @import("lapic.zig");
const lock = @import("../../lock.zig");
const platform = @import("platform.zig");
const pmem = @import("../../pmem.zig");
const sched = @import("../../sched.zig");
const smp = @import("smp.zig");

const present: u64 = 1 << 0;
const writable: u64 = 1 << 1;
const user: u64 = 1 << 2;
const pwt: u64 = 1 << 3;
const pcd: u64 = 1 << 4;
const huge: u64 = 1 << 7;
const global: u64 = 1 << 8;
/// Software bit: this mapping does not own its frame (shm grants).
const sw_unowned: u64 = 1 << 9;
const nx: u64 = 1 << 63;
const addr_mask: u64 = 0x000f_ffff_ffff_f000;

const Perms = enum {
    kernel_text,
    kernel_ro,
    kernel_rw,
    device,
    /// Write-combining: PAT entry 1 (PWT alone), which trap.init makes
    /// WC on every core.
    framebuffer,

    fn bits(self: Perms) u64 {
        return switch (self) {
            .kernel_text => present | global,
            .kernel_ro => present | global | nx,
            .kernel_rw => present | writable | global | nx,
            .device => present | writable | global | nx | pcd | pwt,
            .framebuffer => present | writable | global | nx | pwt,
        };
    }
};

const block_2m: u64 = 2 << 20;

var root_pa: u64 = 0;

pub const Error = error{OutOfFrames};

pub fn init(regions: []const platform.MemRegion) Error!void {
    root_pa = pmem.allocZeroed() orelse return Error.OutOfFrames;
    for (regions) |r| {
        const start = mem.alignDown(r.base, block_2m);
        const end = mem.alignUp(r.base + r.size, block_2m);
        var pa = start;
        while (pa < end) : (pa += block_2m) try mapBlock2M(pa, .kernel_rw);
    }
    // Firmware's tables (ACPI), 4K, normal memory.
    for (platform.extra_maps[0..platform.extra_map_count]) |r| {
        var pa = mem.alignDown(r.base, mem.page_size);
        while (pa < mem.alignUp(r.base + r.size, mem.page_size)) : (pa += mem.page_size) {
            try mapAt(mem.physToVirt(pa), pa, Perms.kernel_rw.bits());
        }
    }
    // The image, W^X.
    const kstart = mem.kernelStart();
    const text_end = mem.textEnd();
    const rodata_end = mem.rodataEnd();
    var va = kstart;
    while (va < mem.kernelEnd()) : (va += mem.page_size) {
        const perms: Perms = if (va < text_end) .kernel_text else if (va < rodata_end) .kernel_ro else .kernel_rw;
        try mapAt(va, boot.imagePhys(va), perms.bits());
    }
}

pub fn mapDeviceLive(base: u64, size: u64) Error!void {
    var pa = base;
    while (pa < base + size) : (pa += mem.page_size) {
        try mapAt(mem.physToVirt(pa), pa, Perms.device.bits());
        cpu.invlpg(mem.physToVirt(pa));
    }
}

/// The framebuffer at its direct-map address, write-combining: stores
/// stream to it, nothing is cached, and a scroll's screenful costs what
/// a memcpy does. Live tables, so each page is invalidated.
pub fn mapFramebuffer(base: u64, size: u64) Error!void {
    var pa = mem.alignDown(base, mem.page_size);
    const end = mem.alignUp(base + size, mem.page_size);
    while (pa < end) : (pa += mem.page_size) {
        try mapAt(mem.physToVirt(pa), pa, Perms.framebuffer.bits());
        cpu.invlpg(mem.physToVirt(pa));
    }
}

fn mapBlock2M(pa: u64, perms: Perms) Error!void {
    const va = mem.physToVirt(pa);
    const pdpt = try walk(root_pa, idx(va, 39), false);
    const pd = try walk(pdpt, idx(va, 30), false);
    entryAt(pd, idx(va, 21)).* = pa | perms.bits() | huge;
}

fn mapAt(va: u64, pa: u64, bits: u64) Error!void {
    const pdpt = try walk(root_pa, idx(va, 39), false);
    const pd = try walk(pdpt, idx(va, 30), false);
    const pt = try walk(pd, idx(va, 21), false);
    entryAt(pt, idx(va, 12)).* = pa | bits;
}

fn walk(table_pa: u64, i: usize, for_user: bool) Error!u64 {
    const e = entryAt(table_pa, i);
    if (e.* & present != 0) return e.* & addr_mask;
    const next = pmem.allocZeroed() orelse return Error.OutOfFrames;
    e.* = next | present | writable | (if (for_user) user else 0);
    return next;
}

fn entryAt(table_pa: u64, i: usize) *volatile u64 {
    return &mem.physToPtr([*]volatile u64, table_pa)[i];
}

fn idx(va: u64, comptime shift: u6) usize {
    return @intCast((va >> shift) & 0x1ff);
}

/// Switch to the rebuilt tables; the loader's mappings are gone.
pub fn activate() void {
    cpu.writeCr3(root_pa);
}

// -------------------------------------------------------------- user half

pub const UserPerms = enum {
    code, // R X (user), read-only
    data, // RW, NX
    rodata, // R, NX
    device, // MMIO for userspace drivers: RW, NX, uncached
    /// The MSI doorbell: reachable by devices, not by the domain's code.
    msi_doorbell,

    fn bits(self: UserPerms) u64 {
        return switch (self) {
            .code => present | user,
            .data => present | writable | user | nx,
            .rodata => present | user | nx,
            .device => present | writable | user | nx | pcd | pwt,
            .msi_doorbell => present | writable | nx | pcd | pwt,
        };
    }
};

/// A fresh user root shares the kernel's upper half.
fn ensureKernelHalf(root_pa_user: u64) void {
    const t = mem.physToPtr([*]volatile u64, root_pa_user);
    if (t[256] != 0) return;
    const k = mem.physToPtr([*]const u64, root_pa);
    for (256..512) |i| t[i] = k[i];
}

pub fn mapUserPage(root_pa_user: u64, va: u64, pa: u64, perms: UserPerms, table_account: *kalloc.Account) !void {
    return mapUserPageTagged(root_pa_user, va, pa, perms, table_account, true);
}

pub fn mapUserPageTagged(root_pa_user: u64, va: u64, pa: u64, perms: UserPerms, table_account: *kalloc.Account, owned: bool) !void {
    ensureKernelHalf(root_pa_user);
    const tag: u64 = if (owned) 0 else sw_unowned;
    const pdpt = try walkUser(root_pa_user, idx(va, 39), table_account);
    const pd = try walkUser(pdpt, idx(va, 30), table_account);
    const pt = try walkUser(pd, idx(va, 21), table_account);
    entryAt(pt, idx(va, 12)).* = pa | perms.bits() | tag;
}

pub fn unmapUserPages(root_pa_user: u64, va: u64, npages: u64, asid: u16) void {
    _ = asid;
    defer shootdown(root_pa_user);
    for (0..npages) |i| {
        const a = va + i * mem.page_size;
        const pdpt = lookup(root_pa_user, idx(a, 39)) orelse @panic("unmapUserPages: no PDPT");
        const pd = lookup(pdpt, idx(a, 30)) orelse @panic("unmapUserPages: no PD");
        const pt = lookup(pd, idx(a, 21)) orelse @panic("unmapUserPages: no PT");
        const e = entryAt(pt, idx(a, 12));
        std.debug.assert(e.* & present != 0 and e.* & sw_unowned != 0);
        e.* = 0;
        cpu.invlpg(a);
    }
}

fn lookup(table_pa: u64, i: usize) ?u64 {
    const e = entryAt(table_pa, i);
    if (e.* & present == 0) return null;
    return e.* & addr_mask;
}

fn walkUser(table_pa: u64, i: usize, account: *kalloc.Account) !u64 {
    const e = entryAt(table_pa, i);
    if (e.* & present != 0) return e.* & addr_mask;
    const page = try kalloc.allocPage(account);
    const next = mem.virtToPhys(@intFromPtr(page));
    e.* = next | present | writable | user;
    return next;
}

/// Tear down a user tree's lower half: leaf pages to `user_account`,
/// table pages to `table_account`.
pub fn destroyUserSpace(root_pa_user: u64, user_account: *kalloc.Account, table_account: *kalloc.Account, asid: u16) void {
    _ = asid;
    const pml4 = mem.physToPtr([*]volatile u64, root_pa_user);
    for (0..256) |e4| {
        if (pml4[e4] & present == 0) continue;
        const pdpt_pa = pml4[e4] & addr_mask;
        const pdpt = mem.physToPtr([*]volatile u64, pdpt_pa);
        for (0..512) |e3| {
            if (pdpt[e3] & present == 0) continue;
            const pd_pa = pdpt[e3] & addr_mask;
            const pd = mem.physToPtr([*]volatile u64, pd_pa);
            for (0..512) |e2| {
                if (pd[e2] & present == 0) continue;
                const pt_pa = pd[e2] & addr_mask;
                const pt = mem.physToPtr([*]volatile u64, pt_pa);
                for (0..512) |e1| {
                    if (pt[e1] & present == 0) continue;
                    if (pt[e1] & sw_unowned != 0) continue;
                    kalloc.freePage(user_account, mem.physToPtr([*]u8, pt[e1] & addr_mask));
                }
                kalloc.freePage(table_account, mem.physToPtr([*]u8, pt_pa));
            }
            kalloc.freePage(table_account, mem.physToPtr([*]u8, pd_pa));
        }
        kalloc.freePage(table_account, mem.physToPtr([*]u8, pdpt_pa));
    }
    kalloc.freePage(table_account, mem.physToPtr([*]u8, root_pa_user));
    // Whatever this core cached of the tree goes with the next CR3 load.
}

/// The incoming thread's user half (its root shares our kernel half), or
/// the kernel's own tables for a kernel thread. Every CR3 load flushes
/// the non-global entries (no PCIDs yet), so a core's TLB can only hold
/// a user tree it is running right now — which is what `cpu_root`
/// records, for the shootdown.
pub fn switchUser(user_root: u64, asid: u16) void {
    _ = asid;
    const want = if (user_root != 0) user_root else root_pa;
    if (cpu.readCr3() & addr_mask != want) cpu.writeCr3(want);
    cpu_root[sched.thisCpu().id] = want;
}

var cpu_root: [sched.max_cpus]u64 = @splat(0);
var tlb_lock: lock.SpinLock = .{};
var tlb_acks = std.atomic.Value(u32).init(0);

/// Retire `root`'s entries on every other core running it: an IPI each,
/// answered by a CR3 reload and an ack; the caller frees nothing until
/// every ack is in. Senders are serialized by the lock so acks are theirs.
fn shootdown(root: u64) void {
    const me = sched.thisCpu().id;
    tlb_lock.lock();
    defer tlb_lock.unlock();
    tlb_acks.store(0, .release);
    var pending: u32 = 0;
    for (0..sched.max_cpus) |i| {
        if (i == me or cpu_root[i] != root) continue;
        lapic.sendIpi(smp.apicIdOf(@intCast(i)), lapic.vector_tlb);
        pending += 1;
    }
    while (tlb_acks.load(.acquire) < pending) std.atomic.spinLoopHint();
}

/// On the target core, from the interrupt path.
pub fn onShootdown() void {
    cpu.writeCr3(cpu.readCr3());
    _ = tlb_acks.fetchAdd(1, .release);
}

/// Page-table writes are ordered stores on x86; walkers see them once
/// the TLB no longer caches the old entry, which the callers invalidate.
pub fn publishTables() void {
    asm volatile ("" ::: .{ .memory = true });
}
