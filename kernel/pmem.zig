//! Physical frame allocator: a bitmap over 4K frames, fed by the memory
//! map the port discovers (arch.platform).

const std = @import("std");
const arch = @import("arch.zig");
const lock = @import("lock.zig");
const mem = @import("mem.zig");

/// Highest physical address tracked. 4GB covers QEMU virt configurations we
/// use; raising it costs 32KB of bitmap per extra GB.
const max_phys: u64 = 4 << 30;
const frame_count = max_phys / mem.page_size;

/// Bit set = frame is free. Zero-initialized in BSS, so everything is
/// "used" until init() frees the devicetree's RAM regions.
var bitmap: [frame_count / 8]u8 = @splat(0);
var free_frames: usize = 0;
var total_frames: usize = 0;
var cursor: usize = 0;
var lk: lock.SpinLock = .{};

pub fn init(regions: []const arch.platform.MemRegion) void {
    for (regions) |r| {
        const first = mem.alignUp(r.base, mem.page_size) / mem.page_size;
        const last = mem.alignDown(r.base + r.size, mem.page_size) / mem.page_size;
        var f = first;
        while (f < last and f < frame_count) : (f += 1) {
            if (!testBit(f)) {
                setBit(f);
                free_frames += 1;
                total_frames += 1;
            }
        }
    }
}

/// Mark a physical range as permanently allocated (kernel image, DTB, ...).
pub fn reserve(base: u64, size: u64) void {
    const first = mem.alignDown(base, mem.page_size) / mem.page_size;
    const last = mem.alignUp(base + size, mem.page_size) / mem.page_size;
    var f = first;
    while (f < last and f < frame_count) : (f += 1) {
        if (testBit(f)) {
            clearBit(f);
            free_frames -= 1;
        }
    }
}

/// Allocate one 4K frame; returns its physical address.
pub fn alloc() ?u64 {
    const irqs = lk.lockIrqSave();
    defer lk.unlockRestore(irqs);
    var scanned: usize = 0;
    var f = cursor;
    while (scanned < frame_count) : (scanned += 1) {
        if (f >= frame_count) f = 0;
        if (testBit(f)) {
            clearBit(f);
            free_frames -= 1;
            cursor = f + 1;
            return f * mem.page_size;
        }
        f += 1;
    }
    return null;
}

/// Allocate `n` physically contiguous frames (so their direct-map VAs are
/// contiguous too); returns the physical address of the first.
pub fn allocContiguous(n: usize) ?u64 {
    const irqs = lk.lockIrqSave();
    defer lk.unlockRestore(irqs);
    var run: usize = 0;
    var f: usize = 0;
    while (f < frame_count) : (f += 1) {
        if (testBit(f)) {
            run += 1;
            if (run == n) {
                const first = f + 1 - n;
                for (first..f + 1) |g| {
                    clearBit(g);
                }
                free_frames -= n;
                return first * mem.page_size;
            }
        } else {
            run = 0;
        }
    }
    return null;
}

pub fn freeContiguous(pa: u64, n: usize) void {
    for (0..n) |i| {
        free(pa + i * mem.page_size);
    }
}

/// A port may zero whole pages faster than a store loop (aarch64's DC
/// ZVA; compiler-rt's memset is a byte loop in a kernel built without
/// NEON, 650 MB/s); without that, the plain store. `len` is a multiple
/// of the page size and `ptr` page-aligned: frames, never a sub-page.
pub fn zeroPages(ptr: [*]u8, len: usize) void {
    if (@hasDecl(arch.cpu, "zeroPages")) arch.cpu.zeroPages(ptr, len) else @memset(ptr[0..len], 0);
}
fn zeroPage(page: [*]u8) void {
    zeroPages(page, mem.page_size);
}

pub fn allocZeroed() ?u64 {
    const pa = alloc() orelse return null;
    zeroPage(mem.physToPtr([*]u8, pa));
    return pa;
}

pub fn free(pa: u64) void {
    const irqs = lk.lockIrqSave();
    defer lk.unlockRestore(irqs);
    const f = pa / mem.page_size;
    std.debug.assert(f < frame_count);
    std.debug.assert(!testBit(f));
    setBit(f);
    free_frames += 1;
}

pub const Stats = struct {
    free_bytes: u64,
    total_bytes: u64,
};

pub fn stats() Stats {
    return .{
        .free_bytes = free_frames * mem.page_size,
        .total_bytes = total_frames * mem.page_size,
    };
}

fn testBit(f: usize) bool {
    return bitmap[f / 8] & (@as(u8, 1) << @intCast(f % 8)) != 0;
}

fn setBit(f: usize) void {
    bitmap[f / 8] |= @as(u8, 1) << @intCast(f % 8);
}

fn clearBit(f: usize) void {
    bitmap[f / 8] &= ~(@as(u8, 1) << @intCast(f % 8));
}
