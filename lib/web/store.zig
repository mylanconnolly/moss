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

        /// Chunks held, counting the partial last one.
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
}
