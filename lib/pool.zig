//! A chunk pool: a general allocator over one static buffer, for
//! userspace programs that need to give memory back (msh's interpreter
//! boxes). Fixed-size chunks, first fit for a run of them, freed by
//! clearing their marks; nothing is ever handed to the kernel. Simple
//! rather than fast — the interpreter allocates a box per binding, not
//! per value, so the pool sees hundreds of calls per line, not millions.

const std = @import("std");

pub fn Pool(comptime chunk: usize, comptime nchunks: usize) type {
    return struct {
        const Self = @This();

        buf: [chunk * nchunks]u8 align(16) = undefined,
        used: [nchunks]bool = [_]bool{false} ** nchunks,
        /// High-water mark, for the host's curiosity.
        peak: usize = 0,

        pub fn allocator(self: *Self) std.mem.Allocator {
            return .{ .ptr = self, .vtable = &vtable };
        }

        const vtable = std.mem.Allocator.VTable{ .alloc = alloc, .resize = resize, .remap = remap, .free = free };

        fn chunksFor(len: usize) usize {
            return @max(1, (len + chunk - 1) / chunk);
        }

        fn indexOf(self: *Self, ptr: [*]u8) usize {
            return (@intFromPtr(ptr) - @intFromPtr(&self.buf)) / chunk;
        }

        fn alloc(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
            const self: *Self = @ptrCast(@alignCast(ctx));
            if (alignment.toByteUnits() > chunk) return null;
            const n = chunksFor(len);
            var i: usize = 0;
            while (i + n <= nchunks) {
                var run: usize = 0;
                while (run < n and !self.used[i + run]) run += 1;
                if (run == n) {
                    @memset(self.used[i .. i + n], true);
                    self.peak = @max(self.peak, i + n);
                    return @ptrCast(&self.buf[i * chunk]);
                }
                i += run + 1;
            }
            return null;
        }

        fn resize(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const i = self.indexOf(memory.ptr);
            const old = chunksFor(memory.len);
            const new = chunksFor(new_len);
            if (new <= old) {
                @memset(self.used[i + new .. i + old], false);
                return true;
            }
            if (i + new > nchunks) return false;
            for (self.used[i + old .. i + new]) |u| if (u) return false;
            @memset(self.used[i + old .. i + new], true);
            self.peak = @max(self.peak, i + new);
            return true;
        }

        fn remap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
            return if (resize(ctx, memory, alignment, new_len, ra)) memory.ptr else null;
        }

        fn free(ctx: *anyopaque, memory: []u8, _: std.mem.Alignment, _: usize) void {
            const self: *Self = @ptrCast(@alignCast(ctx));
            const i = self.indexOf(memory.ptr);
            @memset(self.used[i .. i + chunksFor(memory.len)], false);
        }
    };
}

test "pool: allocate, free, reuse, grow in place" {
    const P = Pool(64, 16);
    const p = try std.testing.allocator.create(P);
    defer std.testing.allocator.destroy(p);
    p.* = .{};
    const a = p.allocator();
    const x = try a.alloc(u8, 100); // 2 chunks
    const y = try a.alloc(u8, 10); // 1 chunk
    try std.testing.expectEqual(@as(usize, 3), p.peak);
    a.free(x);
    const z = try a.alloc(u8, 64); // reuses x's first chunk
    try std.testing.expectEqual(@intFromPtr(x.ptr), @intFromPtr(z.ptr));
    try std.testing.expect(a.resize(z, 128)); // grows into x's second chunk
    const z2: []u8 = z.ptr[0..128];
    try std.testing.expect(!a.resize(z2, 200)); // y is in the way
    a.free(y);
    a.free(z2);
    try std.testing.expect(a.alloc(u8, 64 * 17) == error.OutOfMemory);
    var arena = std.heap.ArenaAllocator.init(a);
    _ = try arena.allocator().alloc(u8, 300);
    arena.deinit();
    for (p.used) |u| try std.testing.expect(!u);
}
