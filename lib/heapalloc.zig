//! A general-purpose allocator over one region of bytes, for programs
//! that hold a static heap and no kernel-provided one: the script
//! domain's bookkeeping (shapes, atoms, lists that grow by doubling)
//! and the page domain's. Small blocks (up to 4 KB) come in size
//! classes — 32 bytes up in steps of 1.5× — each class with an
//! intrusive free list: memory freed is memory reused by the next
//! allocation of the same class, or split for a smaller one when the
//! region's end is reached. Bigger blocks are exact-sized and coalesce:
//! a freed one merges with a free neighbour, and a block freed at the
//! region's top lowers the top, so a list that doubles or a compile's
//! arena chunks (1, 2, 4, 8 MB, freed together) do not leave the
//! region partitioned by size — which is what ran five real sites'
//! scripts out of a 16 MB heap with 6 MB live (2026-09-28). A 16-byte
//! header before every payload names the block's start and class,
//! which is what lets `free` find its list from a pointer of any
//! alignment. Simple rather than compact: a doubling list wastes at
//! most a third, an aligned request at most its alignment, and the
//! region's end is the only out-of-memory.
const std = @import("std");
const Alignment = std.mem.Alignment;

const header_len: usize = 16;
/// Size classes: the block sizes handed out, header included.
const small_classes = [_]usize{ 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048, 3072, 4096 };
const max_small: usize = small_classes[small_classes.len - 1];
/// A large block never shrinks below this by splitting (the remainder
/// goes to the small classes instead). Blocks over 4 KB are large: the
/// classes between 6 and 48 KB stranded five megabytes of a real
/// site's lists that grew through them (2026-09-28).
const large_min: usize = 4096 + 16;
const large_class: u32 = 0xffff_ffff;

const Header = extern struct {
    /// The block's first byte (the payload may sit later, for a large
    /// alignment).
    block: usize,
    class: u32,
    /// A large block's size (`class` is `large_class`).
    size: u32 = 0,
};

pub const Allocator = struct {
    region: []u8,
    top: usize = 0,
    free_lists: [small_classes.len]?*Free = @splat(null),
    /// Free large blocks by address, each merged with its free neighbours.
    large_free: ?*LargeFree = null,
    /// Bytes handed out and not yet freed, for a program's own accounting.
    live: usize = 0,

    const Free = struct { next: ?*Free };
    const LargeFree = struct { next: ?*LargeFree, size: usize };

    pub fn init(region: []u8) Allocator {
        return .{ .region = region };
    }

    pub fn allocator(a: *Allocator) std.mem.Allocator {
        return .{ .ptr = a, .vtable = &vtable };
    }

    /// Where the region went: the top, the live bytes, and the bytes
    /// waiting free by class (what a program that ran out with live
    /// bytes to spare has stranded by size).
    pub fn report(a: *const Allocator, buf: []u8) []const u8 {
        var w = std.Io.Writer.fixed(buf);
        var free_total: usize = 0;
        for (a.free_lists, 0..) |head, ci| {
            var n: usize = 0;
            var f = head;
            while (f) |x| : (f = x.next) n += 1;
            free_total += n * small_classes[ci];
        }
        var large_n: usize = 0;
        var large_bytes: usize = 0;
        var lf = a.large_free;
        while (lf) |x| : (lf = x.next) {
            large_n += 1;
            large_bytes += x.size;
        }
        free_total += large_bytes;
        w.print("top {d} KB of {d}, live {d} KB, free {d} KB ({d} large blocks, {d} KB):", .{ a.top / 1024, a.region.len / 1024, a.live / 1024, free_total / 1024, large_n, large_bytes / 1024 }) catch return w.buffered();
        for (a.free_lists, 0..) |head, ci| {
            var n: usize = 0;
            var f = head;
            while (f) |x| : (f = x.next) n += 1;
            if (n == 0) continue;
            const size = small_classes[ci];
            if (size >= 1024) w.print(" {d}K×{d}", .{ size / 1024, n }) catch break else w.print(" {d}×{d}", .{ size, n }) catch break;
        }
        return w.buffered();
    }

    const vtable: std.mem.Allocator.VTable = .{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };

    /// The smallest class whose block holds `need` bytes; null for a
    /// large block.
    fn classFor(need: usize) ?u32 {
        for (small_classes, 0..) |c, i| if (need <= c) return @intCast(i);
        return null;
    }

    fn base(a: *const Allocator) usize {
        return @intFromPtr(a.region.ptr);
    }

    /// A small block of class `ci`: its free list, the region's top, a
    /// bigger class's free block split, or a large free block carved.
    fn takeSmall(a: *Allocator, ci: u32) ?usize {
        if (a.free_lists[ci]) |f| {
            a.free_lists[ci] = f.next;
            return @intFromPtr(f) - a.base();
        }
        const size = small_classes[ci];
        // Blocks start 16-aligned: the region's base is, and every
        // class size is a multiple of 16.
        if (a.top + size <= a.region.len) {
            const at = a.top;
            a.top += size;
            return at;
        }
        var bigger: u32 = ci + 1;
        while (bigger < small_classes.len) : (bigger += 1) if (a.free_lists[bigger]) |f| {
            a.free_lists[bigger] = f.next;
            const at = @intFromPtr(f) - a.base();
            a.giveBack(at + size, small_classes[bigger] - size);
            return at;
        };
        return a.takeLarge(size);
    }

    /// A large block of exactly `size` bytes (a multiple of 16): the
    /// first free one that fits, split, else the region's top.
    fn takeLarge(a: *Allocator, size: usize) ?usize {
        var prev: ?*LargeFree = null;
        var cur = a.large_free;
        while (cur) |f| : ({
            prev = f;
            cur = f.next;
        }) {
            if (f.size < size) continue;
            const at = @intFromPtr(f) - a.base();
            const rest = f.size - size;
            const next = f.next;
            if (rest >= large_min) {
                const tail: *LargeFree = @ptrFromInt(a.base() + at + size);
                tail.* = .{ .next = next, .size = rest };
                if (prev) |pf| pf.next = tail else a.large_free = tail;
            } else {
                if (prev) |pf| pf.next = next else a.large_free = next;
                a.giveBack(at + size, rest);
            }
            return at;
        }
        if (a.top + size > a.region.len) return null;
        const at = a.top;
        a.top += size;
        return at;
    }

    /// Bytes at `at`, as free small blocks of the largest classes that
    /// fit (a remainder under the smallest class is lost, at most 16
    /// bytes) — or one large free block when they are enough for one.
    fn giveBack(a: *Allocator, at: usize, len: usize) void {
        if (len >= large_min) {
            a.freeLarge(at, len);
            return;
        }
        var off = at;
        var left = len;
        while (left >= small_classes[0]) {
            var ci: u32 = small_classes.len - 1;
            while (small_classes[ci] > left) ci -= 1;
            const f: *Free = @ptrFromInt(a.base() + off);
            f.next = a.free_lists[ci];
            a.free_lists[ci] = f;
            off += small_classes[ci];
            left -= small_classes[ci];
        }
    }

    /// A large block given back: merged with a free neighbour on either
    /// side, and the top lowered when it ends there.
    fn freeLarge(a: *Allocator, at: usize, size: usize) void {
        var start = at;
        var len = size;
        var prev: ?*LargeFree = null;
        var cur = a.large_free;
        while (cur) |f| : ({
            prev = f;
            cur = f.next;
        }) {
            if (@intFromPtr(f) - a.base() > start) break;
        }
        // `prev` is the last free block before this one, `cur` the first after.
        var next = cur;
        if (cur) |f| if (@intFromPtr(f) - a.base() == start + len) {
            len += f.size;
            next = f.next;
        };
        if (prev) |pf| {
            const pf_at = @intFromPtr(pf) - a.base();
            if (pf_at + pf.size == start) {
                start = pf_at;
                len += pf.size;
                // Walk back to re-find prev's predecessor.
                var pp: ?*LargeFree = null;
                var c2 = a.large_free;
                while (c2) |f| : (c2 = f.next) {
                    if (f == pf) break;
                    pp = f;
                }
                prev = pp;
            }
        }
        if (start + len == a.top) {
            a.top = start;
            if (prev) |pf| pf.next = next else a.large_free = next;
            return;
        }
        const node: *LargeFree = @ptrFromInt(a.base() + start);
        node.* = .{ .next = next, .size = len };
        if (prev) |pf| pf.next = node else a.large_free = node;
    }

    fn allocFn(ctx: *anyopaque, len: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const a: *Allocator = @ptrCast(@alignCast(ctx));
        const al = alignment.toByteUnits();
        // Room for the header, the payload, and moving the payload up to
        // its alignment when that is more than the block's own 16.
        const slack: usize = if (al > 16) al else 0;
        const need = header_len + len + slack;
        var off: usize = undefined;
        var class: u32 = undefined;
        var size: usize = undefined;
        if (classFor(need)) |ci| {
            off = a.takeSmall(ci) orelse return null;
            class = ci;
            size = small_classes[ci];
        } else {
            size = @max(large_min, (need + 15) & ~@as(usize, 15));
            if (size > std.math.maxInt(u32)) return null;
            off = a.takeLarge(size) orelse return null;
            class = large_class;
        }
        const block = a.base() + off;
        const payload = alignment.forward(block + header_len);
        const h: *Header = @ptrFromInt(payload - header_len);
        h.* = .{ .block = block, .class = class, .size = @intCast(size) };
        a.live += size;
        return @ptrFromInt(payload);
    }

    fn headerOf(ptr: [*]u8) *Header {
        return @ptrFromInt(@intFromPtr(ptr) - header_len);
    }

    fn blockSize(h: *const Header) usize {
        return if (h.class == large_class) h.size else small_classes[h.class];
    }

    fn capacity(ptr: [*]u8) usize {
        const h = headerOf(ptr);
        return h.block + blockSize(h) - @intFromPtr(ptr);
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        if (new_len <= capacity(memory.ptr)) return true;
        // The newest block, at the region's top, grows in place by
        // taking the bytes after it — what a list that is being built
        // gets from a bump allocator, without the copy.
        const a: *Allocator = @ptrCast(@alignCast(ctx));
        const h = headerOf(memory.ptr);
        const old_size = blockSize(h);
        if (h.block + old_size != a.base() + a.top) return false;
        const need = (@intFromPtr(memory.ptr) - h.block) + new_len;
        var new_size: usize = undefined;
        var class: u32 = undefined;
        if (classFor(need)) |ci| {
            new_size = small_classes[ci];
            class = ci;
        } else {
            new_size = @max(large_min, (need + 15) & ~@as(usize, 15));
            if (new_size > std.math.maxInt(u32)) return false;
            class = large_class;
        }
        if (h.block - a.base() + new_size > a.region.len) return false;
        a.top = h.block - a.base() + new_size;
        a.live += new_size - old_size;
        h.class = class;
        h.size = @intCast(new_size);
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resizeFn(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const a: *Allocator = @ptrCast(@alignCast(ctx));
        const h = headerOf(memory.ptr);
        const size = blockSize(h);
        a.live -= size;
        const at = h.block - a.base();
        if (h.class == large_class) {
            a.freeLarge(at, size);
            return;
        }
        // The newest block given back lowers the top instead: the bytes
        // serve any size next, not only this class.
        if (at + size == a.top) {
            a.top = at;
            return;
        }
        const f: *Free = @ptrFromInt(h.block);
        f.next = a.free_lists[h.class];
        a.free_lists[h.class] = f;
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

test "heapalloc: arena chunks and doubling lists do not partition the region" {
    const region = try std.testing.allocator.alignedAlloc(u8, .@"16", 16 << 20);
    defer std.testing.allocator.free(region);
    var a = Allocator.init(region);
    const al = a.allocator();
    // Ten compiles' worth of arena chunks (the arena grows them by
    // half again each time; ten megabytes a round, freed together),
    // each round leaving a little live behind: the class-ladder
    // allocator ran out on the third round.
    var kept: std.ArrayList([]u8) = .empty;
    defer kept.deinit(std.testing.allocator);
    for (0..10) |_| {
        var arena = std.heap.ArenaAllocator.init(al);
        _ = try arena.allocator().alloc(u8, 512 << 10);
        _ = try arena.allocator().alloc(u8, 1 << 20);
        _ = try arena.allocator().alloc(u8, 2 << 20);
        try kept.append(std.testing.allocator, try al.alloc(u8, 100 << 10));
        arena.deinit();
    }
    // Two lists doubling in turn, 200 KB each in the end.
    var l1: std.ArrayList(u64) = .empty;
    var l2: std.ArrayList(u64) = .empty;
    defer l1.deinit(al);
    defer l2.deinit(al);
    for (0..25_000) |i| {
        try l1.append(al, i);
        try l2.append(al, i);
    }
    // A large free block in the middle merges with the ones around it.
    const x = try al.alloc(u8, 300 << 10);
    const y = try al.alloc(u8, 300 << 10);
    const z = try al.alloc(u8, 300 << 10);
    _ = try al.alloc(u8, 16);
    al.free(x);
    al.free(z);
    al.free(y);
    const top_before = a.top;
    const big = try al.alloc(u8, 850 << 10);
    try std.testing.expectEqual(top_before, a.top);
    al.free(big);
    for (kept.items) |k| al.free(k);
}
