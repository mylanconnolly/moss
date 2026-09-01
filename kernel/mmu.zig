//! Page tables: replaces the coarse boot map with a proper kernel address
//! space, then drops the boot identity map.
//!
//! 4K granule, 39-bit kernel VA (levels 1..3). RAM gets the direct map
//! (virt = phys + kvirt_offset) as 2MB blocks, RW+PXN; the 2MB spans holding
//! the kernel image are carved into 4K pages so the image is W^X: text RX,
//! rodata RO, data/bss/stack RW, all non-executable except text. Device MMIO
//! (UART, GIC) is mapped 4K at direct-map addresses with device attributes.

const std = @import("std");
const dt = @import("dt.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");

const valid = 1 << 0;
const table_or_page = 1 << 1; // in L1/L2: table; in L3: page (0 = 2MB/1GB block in L1/L2)
const attr_device = 0 << 2; // MAIR idx0 (Device-nGnRnE, set up in boot.zig)
const attr_normal = 1 << 2; // MAIR idx1 (Normal WB WA)
const ap_el0 = 1 << 6;
const ap_ro = 1 << 7;
const sh_inner = 3 << 8;
const af = 1 << 10;
const ng = 1 << 11;
const pxn = 1 << 53;
const uxn = 1 << 54;

const Perms = enum {
    kernel_text, // RX, read-only
    kernel_ro, // no execute anywhere
    kernel_rw, // no execute anywhere
    device,

    fn bits(self: Perms) u64 {
        return switch (self) {
            .kernel_text => attr_normal | sh_inner | af | uxn | ap_ro,
            .kernel_ro => attr_normal | sh_inner | af | uxn | pxn | ap_ro,
            .kernel_rw => attr_normal | sh_inner | af | uxn | pxn,
            .device => attr_device | af | uxn | pxn,
        };
    }
};

const block_2m: u64 = 2 << 20;

var root_pa: u64 = 0;

pub const Error = error{OutOfFrames};

pub fn init(regions: []const dt.MemRegion) Error!void {
    root_pa = pmem.allocZeroed() orelse return Error.OutOfFrames;

    const kstart_pa = mem.virtToPhys(mem.kernelStart());
    const kend_pa = mem.virtToPhys(mem.kernelEnd());
    const kspan_start = mem.alignDown(kstart_pa, block_2m);
    const kspan_end = mem.alignUp(kend_pa, block_2m);

    for (regions) |r| {
        const start = mem.alignDown(r.base, block_2m);
        const end = mem.alignUp(r.base + r.size, block_2m);
        var pa = start;
        while (pa < end) : (pa += block_2m) {
            if (pa >= kspan_start and pa < kspan_end) {
                try mapKernelImageChunk(pa);
            } else {
                try mapBlock2M(pa, .kernel_rw);
            }
        }
    }

    // Device windows, 4K pages at direct-map addresses.
    try mapDeviceRange(0x0900_0000, 0x1000); // PL011 UART
    try mapDeviceRange(0x0800_0000, 0x1_0000); // GICv3 distributor
    try mapDeviceRange(0x080a_0000, 0x10_0000); // GICv3 redistributors, 8 cores
}

/// Map one 2MB span overlapping the kernel image as 4K pages with W^X perms.
fn mapKernelImageChunk(chunk_pa: u64) Error!void {
    const kstart_pa = mem.virtToPhys(mem.kernelStart());
    const text_end_pa = mem.virtToPhys(mem.textEnd());
    const rodata_end_pa = mem.virtToPhys(mem.rodataEnd());
    const kend_pa = mem.virtToPhys(mem.kernelEnd());

    var pa = chunk_pa;
    while (pa < chunk_pa + block_2m) : (pa += mem.page_size) {
        const perms: Perms = if (pa < kstart_pa or pa >= kend_pa)
            .kernel_rw
        else if (pa < text_end_pa)
            .kernel_text
        else if (pa < rodata_end_pa)
            .kernel_ro
        else
            .kernel_rw;
        try mapPage4K(pa, perms);
    }
}

fn mapDeviceRange(base: u64, size: u64) Error!void {
    var pa = base;
    while (pa < base + size) : (pa += mem.page_size) {
        try mapPage4K(pa, .device);
    }
}

fn mapBlock2M(pa: u64, perms: Perms) Error!void {
    const va = mem.physToVirt(pa);
    const l2 = try walk(root_pa, l1Index(va));
    entryAt(l2, l2Index(va)).* = pa | perms.bits() | valid;
}

fn mapPage4K(pa: u64, perms: Perms) Error!void {
    const va = mem.physToVirt(pa);
    const l2 = try walk(root_pa, l1Index(va));
    const l3 = try walk(l2, l2Index(va));
    entryAt(l3, l3Index(va)).* = pa | perms.bits() | valid | table_or_page;
}

/// Get the table one level down from table_pa[index], allocating it if the
/// slot is empty.
fn walk(table_pa: u64, index: usize) Error!u64 {
    const entry = entryAt(table_pa, index);
    if (entry.* & valid != 0) {
        std.debug.assert(entry.* & table_or_page != 0);
        return entry.* & 0x0000_ffff_ffff_f000;
    }
    const next = pmem.allocZeroed() orelse return Error.OutOfFrames;
    entry.* = next | valid | table_or_page;
    return next;
}

fn entryAt(table_pa: u64, index: usize) *volatile u64 {
    const table = mem.physToPtr([*]volatile u64, table_pa);
    return &table[index];
}

fn l1Index(va: u64) usize {
    return @intCast((va >> 30) & 0x1ff);
}

fn l2Index(va: u64) usize {
    return @intCast((va >> 21) & 0x1ff);
}

fn l3Index(va: u64) usize {
    return @intCast((va >> 12) & 0x1ff);
}

/// User-space (TTBR0) mappings — non-global so per-domain ASIDs isolate TLB
/// entries; W^X in user space too: code is read-only + EL0-executable, data
/// is EL0-writable + never executable anywhere.
pub const UserPerms = enum {
    code, // R X (EL0), read-only everywhere, PXN
    data, // RW (EL0+EL1), XN everywhere

    fn bits(self: UserPerms) u64 {
        return switch (self) {
            .code => attr_normal | sh_inner | af | ng | ap_el0 | ap_ro | pxn,
            .data => attr_normal | sh_inner | af | ng | ap_el0 | pxn | uxn,
        };
    }
};

/// Map one user page into a domain's TTBR0 tree, allocating intermediate
/// tables from the domain's kernel-object account.
pub fn mapUserPage(
    root_pa_user: u64,
    va: u64,
    pa: u64,
    perms: UserPerms,
    table_account: *kalloc.Account,
) !void {
    const l2 = try walkUser(root_pa_user, l1Index(va), table_account);
    const l3 = try walkUser(l2, l2Index(va), table_account);
    entryAt(l3, l3Index(va)).* = pa | perms.bits() | valid | table_or_page;
}

fn walkUser(table_pa: u64, index: usize, account: *kalloc.Account) !u64 {
    const entry = entryAt(table_pa, index);
    if (entry.* & valid != 0) {
        return entry.* & 0x0000_ffff_ffff_f000;
    }
    const page = try kalloc.allocPage(account);
    const next = mem.virtToPhys(@intFromPtr(page));
    entry.* = next | valid | table_or_page;
    return next;
}

/// Tear down a user TTBR0 tree: leaf pages are credited to `user_account`,
/// table pages to `table_account`, and everything returns to pmem.
pub fn destroyUserSpace(
    root_pa_user: u64,
    user_account: *kalloc.Account,
    table_account: *kalloc.Account,
    asid: u16,
) void {
    const l1 = mem.physToPtr([*]volatile u64, root_pa_user);
    for (0..512) |e1| {
        if (l1[e1] & valid == 0) continue;
        const l2_pa = l1[e1] & 0x0000_ffff_ffff_f000;
        const l2 = mem.physToPtr([*]volatile u64, l2_pa);
        for (0..512) |e2| {
            if (l2[e2] & valid == 0) continue;
            const l3_pa = l2[e2] & 0x0000_ffff_ffff_f000;
            const l3 = mem.physToPtr([*]volatile u64, l3_pa);
            for (0..512) |e3| {
                if (l3[e3] & valid == 0) continue;
                const page_pa = l3[e3] & 0x0000_ffff_ffff_f000;
                kalloc.freePage(user_account, mem.physToPtr([*]u8, page_pa));
            }
            kalloc.freePage(table_account, mem.physToPtr([*]u8, l3_pa));
        }
        kalloc.freePage(table_account, mem.physToPtr([*]u8, l2_pa));
    }
    kalloc.freePage(table_account, mem.physToPtr([*]u8, root_pa_user));

    // Retire every TLB entry tagged with this ASID before the slot is reused.
    asm volatile (
        \\dsb ish
        \\tlbi aside1is, %[v]
        \\dsb ish
        \\isb
        :
        : [v] "r" (@as(u64, asid) << 48),
    );
}

/// Switch TTBR1 to the rebuilt tables and disable TTBR0 walks (TCR.EPD0),
/// dropping the boot identity map. The kernel has no low-half mappings until
/// user address spaces arrive in Phase 3.
pub fn activate() void {
    asm volatile (
        \\msr ttbr1_el1, %[root]
        \\isb
        \\tlbi vmalle1
        \\dsb ish
        \\isb
        :
        : [root] "r" (root_pa),
    );
    const tcr = asm ("mrs %[v], tcr_el1"
        : [v] "=r" (-> u64),
    );
    asm volatile (
        \\msr tcr_el1, %[v]
        \\isb
        \\tlbi vmalle1
        \\dsb ish
        \\isb
        :
        : [v] "r" (tcr | (1 << 7)),
    );
}
