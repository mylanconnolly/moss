//! A list that grows in fixed chunks: the node, box and fragment lists
//! of a page. A page's allocator is a bump region that cannot take back
//! what a doubling list leaves behind, and a 1.2 MB article's lists
//! left 15 MB of dead buffers behind them, twice what they held
//! (2026-09-24). A chunked list never moves an element — a pointer to
//! one stays good for the list's life, which the tree walks in the
//! parser and the layout used to lose across an append — and wastes at
//! most one chunk.
const std = @import("std");

pub fn Chunked(comptime T: type, comptime chunk_bits: u5) type {
    return struct {
        const Self = @This();
        pub const chunk_len: usize = 1 << chunk_bits;
        const mask: usize = chunk_len - 1;

        chunks: std.ArrayList([*]T) = .empty,
        len: usize = 0,

        pub fn append(self: *Self, a: std.mem.Allocator, v: T) std.mem.Allocator.Error!void {
            if (self.len == self.chunks.items.len * chunk_len) {
                const chunk = try a.alloc(T, chunk_len);
                try self.chunks.append(a, chunk.ptr);
            }
            self.chunks.items[self.len >> chunk_bits][self.len & mask] = v;
            self.len += 1;
        }

        pub fn at(self: *Self, i: usize) *T {
            std.debug.assert(i < self.len);
            return &self.chunks.items[i >> chunk_bits][i & mask];
        }

        pub fn get(self: *const Self, i: usize) *const T {
            std.debug.assert(i < self.len);
            return &self.chunks.items[i >> chunk_bits][i & mask];
        }

        pub fn last(self: *Self) *T {
            return self.at(self.len - 1);
        }

        /// The rest of the chunk holding element `i`: the run from `i`
        /// to the chunk's end (or the list's), for loops that want to
        /// walk the list a chunk at a time instead of a `get` per element.
        pub fn slice(self: *const Self, i: usize) []T {
            std.debug.assert(i < self.len);
            const chunk = self.chunks.items[i >> chunk_bits];
            const from = i & mask;
            const to = @min(chunk_len, self.len - (i - from));
            return chunk[from..to];
        }

        /// Elements the chunks held so far have room for, the partial
        /// last one counted whole.
        pub fn capacity(self: *const Self) usize {
            return self.chunks.items.len * chunk_len;
        }
    };
}

test "store: a chunked list keeps its elements in place across growth" {
    var s: Chunked(u64, 2) = .{};
    const a = std.testing.allocator;
    defer {
        for (s.chunks.items) |c| {
            const chunk: []u64 = c[0..@TypeOf(s).chunk_len];
            a.free(chunk);
        }
        s.chunks.deinit(a);
    }
    try s.append(a, 10);
    const p0 = s.at(0);
    for (1..11) |i| try s.append(a, @intCast(i * 10));
    try std.testing.expectEqual(@as(usize, 11), s.len);
    try std.testing.expectEqual(@as(usize, 12), s.capacity());
    try std.testing.expect(p0 == s.at(0));
    try std.testing.expectEqual(@as(u64, 70), s.get(7).*);
    s.at(7).* = 71;
    try std.testing.expectEqual(@as(u64, 71), s.last().* - 29);
    // Chunk runs cover the list exactly once, in order.
    var seen: usize = 0;
    var i: usize = 0;
    while (i < s.len) {
        const run = s.slice(i);
        try std.testing.expect(run.len > 0 and run.len <= @TypeOf(s).chunk_len);
        seen += run.len;
        i += run.len;
    }
    try std.testing.expectEqual(s.len, seen);
    try std.testing.expectEqual(@as(usize, 3), s.slice(8).len);
}
