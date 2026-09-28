//! A scratch arena for a compile: chunks of one size from a child
//! allocator, freed together, in the order they came. The standard
//! arena grows each chunk by half again, so its chunks add up to about
//! three times what is live, and on the page's layout stack — which
//! gives memory back only in order — that was the peak: a page ran out
//! of memory compiling with its heaps a fifth used (2026-09-28). Here
//! the peak is what is live plus one chunk. A request bigger than a
//! chunk gets a chunk of its own. The newest allocation grows in place
//! when there is room, as a list being built wants.
const std = @import("std");
const Allocator = std.mem.Allocator;
const Alignment = std.mem.Alignment;

pub const ChunkArena = struct {
    child: Allocator,
    chunk_size: usize,
    /// The newest chunk; each chunk's header names the one before it,
    /// so the arena keeps no list of its own — on a stack child a list
    /// above the chunks kept every chunk from going back (a page ran
    /// out of memory compiling after a few dozen compiles, 2026-09-28).
    top: ?*Header = null,
    /// The newest chunk's fill, header included.
    end: usize = 0,

    const Header = struct { prev: ?*Header, len: usize };
    const header_len: usize = 32;

    pub fn init(child: Allocator, chunk_size: usize) ChunkArena {
        return .{ .child = child, .chunk_size = chunk_size };
    }

    /// Every chunk back to the child, newest first (a stack child
    /// wants that order).
    pub fn deinit(a: *ChunkArena) void {
        var cur = a.top;
        while (cur) |h| {
            const prev = h.prev;
            const bytes: [*]align(16) u8 = @ptrCast(@alignCast(h));
            a.child.free(bytes[0..h.len]);
            cur = prev;
        }
        a.top = null;
    }

    pub fn allocator(a: *ChunkArena) Allocator {
        return .{ .ptr = a, .vtable = &vtable };
    }

    const vtable: Allocator.VTable = .{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn };

    fn chunkBytes(h: *Header) [*]u8 {
        return @ptrCast(h);
    }

    fn allocFn(ctx: *anyopaque, n: usize, alignment: Alignment, _: usize) ?[*]u8 {
        const a: *ChunkArena = @ptrCast(@alignCast(ctx));
        if (a.top) |h| {
            const base = @intFromPtr(h);
            const start = alignment.forward(base + a.end) - base;
            if (start + n <= h.len) {
                a.end = start + n;
                return chunkBytes(h) + start;
            }
        }
        const size = @max(a.chunk_size, header_len + n + alignment.toByteUnits());
        const chunk = a.child.alignedAlloc(u8, .@"16", size) catch return null;
        const h: *Header = @ptrCast(@alignCast(chunk.ptr));
        h.* = .{ .prev = a.top, .len = size };
        a.top = h;
        const start = alignment.forward(@intFromPtr(h) + header_len) - @intFromPtr(h);
        a.end = start + n;
        return chunk.ptr + start;
    }

    fn isLast(a: *ChunkArena, memory: []u8) bool {
        const h = a.top orelse return false;
        return @intFromPtr(memory.ptr) + memory.len == @intFromPtr(h) + a.end;
    }

    fn resizeFn(ctx: *anyopaque, memory: []u8, _: Alignment, new_len: usize, _: usize) bool {
        const a: *ChunkArena = @ptrCast(@alignCast(ctx));
        if (new_len <= memory.len) {
            if (a.isLast(memory)) a.end -= memory.len - new_len;
            return true;
        }
        if (!a.isLast(memory)) return false;
        const h = a.top.?;
        const start = @intFromPtr(memory.ptr) - @intFromPtr(h);
        if (start + new_len > h.len) return false;
        a.end = start + new_len;
        return true;
    }

    fn remapFn(ctx: *anyopaque, memory: []u8, alignment: Alignment, new_len: usize, ra: usize) ?[*]u8 {
        return if (resizeFn(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
    }

    fn freeFn(ctx: *anyopaque, memory: []u8, _: Alignment, _: usize) void {
        const a: *ChunkArena = @ptrCast(@alignCast(ctx));
        // Only the newest allocation comes back; the rest waits for deinit.
        if (a.isLast(memory)) a.end -= memory.len;
    }
};

test "scratch: chunks fill in order, the last allocation grows in place, all goes back" {
    var arena = ChunkArena.init(std.testing.allocator, 4096);
    defer arena.deinit();
    const al = arena.allocator();
    var list: std.ArrayList(u64) = .empty;
    for (0..1000) |i| try list.append(al, i);
    try std.testing.expectEqual(@as(u64, 999), list.items[999]);
    const big = try al.alloc(u8, 10_000);
    try std.testing.expectEqual(@as(usize, 10_000), big.len);
    var chunks: usize = 0;
    var cur = arena.top;
    while (cur) |h| : (cur = h.prev) chunks += 1;
    try std.testing.expect(chunks >= 3);
    const small = try al.alloc(u8, 16);
    small[0] = 7;
    try std.heap.testAllocator(al);
}
