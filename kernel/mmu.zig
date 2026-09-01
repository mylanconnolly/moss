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
const log = @import("log.zig");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");

const valid = 1 << 0;
const table_or_page = 1 << 1; // in L1/L2: table; in L3: page (0 = 2MB/1GB block in L1/L2)
const attr_device = 0 << 2; // MAIR idx0 (Device-nGnRnE, set up in boot.zig)
const attr_normal = 1 << 2; // MAIR idx1 (Normal WB WA)
const ap_ro = 1 << 7;
const sh_inner = 3 << 8;
const af = 1 << 10;
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
    try mapDeviceRange(0x080a_0000, 0x2_0000); // GICv3 redistributor, core 0
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
