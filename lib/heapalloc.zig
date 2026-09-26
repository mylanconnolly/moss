//! A general-purpose allocator over one region of bytes, for programs
//! that hold a static heap and no kernel-provided one: the script
//! domain's bookkeeping (shapes, atoms, lists that grow by doubling)
//! and, next, the page domain's. Blocks come in size classes — 32
//! bytes to 4 KB in steps of 1.5×, then powers of two up to the region
//! — each class with an intrusive free list; a block never returns to
//! the region, only to its class's list, so memory freed is memory
//! reused by the next allocation of the same class and never lost. A
//! 16-byte header before every payload names the block's start and
//! class, which is what lets `free` find its list from a pointer of any
//! alignment. Simple rather than compact: a doubling list wastes at
//! most a third, an aligned request at most its alignment, and the
//! region's end is the only out-of-memory.
const std = @import("std");
const Alignment = std.mem.Alignment;

const header_len: usize = 16;
/// Size classes: the block sizes handed out, header included.
const small_classes = [_]usize{ 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096, 6144, 8192, 12288, 16384, 24576, 32768, 49152, 65536, 98304, 131072, 196608, 262144, 393216, 524288, 786432, 1048576 };
const large_base: usize = 1 << 20;
const max_classes = small_classes.len + 20; // up to 1 MB << 20 = 1 TB, far past any region

const Header = extern struct {
    /// The block's first byte (the payload may sit later, for a large
    /// alignment).
    block: usize,
    class: u32,
    _pad: u32 = 0,
};

pub const Allocator = struct {
    region: []u8,
    top: usize = 0,
    free_lists: [max_classes]?*Free = @splat(null),
    /// Bytes handed out and not yet freed, for a program's own accounting.
    live: usize = 0,

    const Free = struct { next: ?*Free };

    pub fn init(region: []u8) Allocator {
        return .{ .region = region };
    }

    pub fn allocator(a: *Allocator) std.mem.Allocator {
        return .{ .ptr = a, .vtable = &vtable };
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };

    fn classSize(ci: u32) usize {
        if (ci < small_classes.len) return small_classes[ci];
        return large_base << @intCast(ci - small_classes.len + 1);
    }

    /// The smallest class whose block holds `need` bytes.
    fn classFor(need: usize) ?u32 {
        for (small_classes, 0..) |c, i| if (need <= c) return @intCast(i);
        var ci: u32 = small_classes.len;
        while (ci < max_classes) : (ci += 1) if (need <= classSize(ci)) return ci;
        return null;
    }

    fn takeBlock(a: *Allocator, ci: u32) ?usize {
        if (a.free_lists[ci]) |f| {
            a.free_lists[ci] = f.next;
            return @intFromPtr(f) - @intFromPtr(a.region.ptr);
        }
        const size = classSize(ci);
        // Blocks start 16-aligned: the region's base is, and every
        // class size is a multiple of 16.
        if (a.top + size > a.region.len) return null;
        const at = a.top;
        a.top += size;
        return at;
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const a: *Allocator = @ptrCast(@alignCast(ctx));
        const al = alignment.toByteUnits();
        // Room for the header, the payload, and moving the payload up to
        // its alignment when that is more than the block's own 16.
        const slack: usize = if (al > 16) al else 0;
        const need = header_len + len + slack;
        const ci = classFor(need) orelse return null;
        const off = a.takeBlock(ci) orelse return null;
        const base = @intFromPtr(a.region.ptr) + off;
        const payload = alignment.forward(base + header_len);
        const h: *Header = @ptrFromInt(payload - header_len);
        h.* = .{ .block = base, .class = ci };
        a.live += classSize(ci);
        return @ptrFromInt(payload);
    }

    fn headerOf(ptr: [*]u8) *Header {
        return @ptrFromInt(@intFromPtr(ptr) - header_len);
    }

    fn capacity(ptr: [*]u8) usize {
        const h = headerOf(ptr);
        return h.block + classSize(h.class) - @intFromPtr(ptr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        if (new_len <= capacity(memory.ptr)) return true;
        // The newest block, at the region's top, grows in place into a
        // larger class by taking the bytes after it — what a list that
        // is being built gets from a bump allocator, without the copy.
        const a: *Allocator = @ptrCast(@alignCast(ctx));
        const h = headerOf(memory.ptr);
        const base = @intFromPtr(a.region.ptr);
        const old_size = classSize(h.class);
        if (h.block + old_size != base + a.top) return false;
        const need = (@intFromPtr(memory.ptr) - h.block) + new_len;
        const ci = classFor(need) orelse return false;
        const new_size = classSize(ci);
        if (h.block - base + new_size > a.region.len) return false;
        a.top = h.block - base + new_size;
        a.live += new_size - old_size;
        h.class = ci;
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resizeFn(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const a: *Allocator = @ptrCast(@alignCast(ctx));
        const h = headerOf(memory.ptr);
        const ci = h.class;
        a.live -= classSize(ci);
        const f: *Free = @ptrFromInt(h.block);
        f.next = a.free_lists[ci];
        a.free_lists[ci] = f;
    }
};

test "heapalloc: the standard allocator suite" {
    const region = try std.testing.allocator.alignedAlloc(u8, .@"16", 8 << 20);
    defer std.testing.allocator.free(region);
    var a = Allocator.init(region);
    try std.heap.testAllocator(a.allocator());
    try std.heap.testAllocatorAligned(a.allocator());
    try std.heap.testAllocatorLargeAlignment(a.allocator());
    try std.heap.testAllocatorAlignedShrink(a.allocator());
}

test "heapalloc: freed blocks come back, and the region's end is the limit" {
    const region = try std.testing.allocator.alignedAlloc(u8, .@"16", 256 << 10);
    defer std.testing.allocator.free(region);
    var a = Allocator.init(region);
    const al = a.allocator();
    // A doubling list: every old buffer is reused by a later one.
    var list: std.ArrayList(u64) = .empty;
    defer list.deinit(al);
    var i: u64 = 0;
    while (i < 2000) : (i += 1) try list.append(al, i);
    try std.testing.expectEqual(@as(u64, 1999), list.items[1999]);
    const top_after = a.top;
    var other: std.ArrayList(u64) = .empty;
    defer other.deinit(al);
    i = 0;
    while (i < 2000) : (i += 1) try other.append(al, i);
    // The second list took the first's freed growth blocks; the region
    // grew by one block only, the final one (the first list keeps its own).
    try std.testing.expect(a.top - top_after <= 32768);
    // A list built alone grows in place at the top: no block per step.
    var alone = Allocator.init(region[128 << 10 ..]);
    var l3: std.ArrayList(u64) = .empty;
    defer l3.deinit(alone.allocator());
    i = 0;
    while (i < 2000) : (i += 1) try l3.append(alone.allocator(), i);
    try std.testing.expect(alone.top <= 32768);
    // Out of memory is an error, not a fault.
    try std.testing.expectError(error.OutOfMemory, al.alloc(u8, 1 << 20));
    const before = a.live;
    const p = try al.alloc(u8, 100);
    try std.testing.expect(a.live > before);
    al.free(p);
    try std.testing.expectEqual(before, a.live);
}
