//! The engine's heap: cells in a region the embedder hands over (a page
//! domain gives part of its own region; the host a buffer), precisely
//! collected. Every cell starts with a `Cell` header naming its kind,
//! and every kind knows how to trace its references, so the collector
//! is a mark from the roots and a sweep of the size-class free lists —
//! no conservative scanning, no reference counts, cycles included.
//!
//! Roots are explicit: the embedder's `Handle`s (a handle scope per
//! host call, released together), the realm's intrinsics, and the VM's
//! frames, each registering a `Root` tracer. A generational nursery is
//! the design's next step (the `writeBarrier` every store already goes
//! through is where old-to-young pointers will be remembered); until
//! pointers move, the barrier is free.
const std = @import("std");
const value = @import("value.zig");
const Value = value.Value;

/// `free` marks a swept cell on a free list: the sweep skips it (a
/// cell must never be put on a free list twice).
pub const Kind = enum(u8) { string, object, symbol, bigint, env, code, shape, accessor, binding, bytes, free };

/// Every heap cell's first word.
pub const Cell = extern struct {
    kind: Kind,
    marked: bool = false,
    /// The size class the cell was allocated from (index into `classes`),
    /// or 0xff for a large cell with its own block.
    class: u8,
    _pad: u8 = 0,
    /// The cell's byte size (header included), rounded to the class.
    size: u32,

    pub fn as(c: *Cell, comptime T: type) *T {
        return @ptrCast(@alignCast(c));
    }
};

/// A traced reference the collector can see.
pub const Root = struct {
    ctx: *anyopaque,
    trace: *const fn (ctx: *anyopaque, gc: *Marker) void,
};

/// What a tracer marks with.
pub const Marker = struct {
    heap: *Heap,
    stack: std.ArrayList(*Cell),

    pub fn markValue(m: *Marker, v: Value) void {
        if (v.isCell()) m.markCell(v.asCell());
    }
    pub fn markCell(m: *Marker, c: ?*Cell) void {
        const cell = c orelse return;
        if (cell.marked) return;
        cell.marked = true;
        m.stack.append(m.heap.meta, cell) catch {
            // Out of mark-stack memory: mark eagerly instead (deep, but
            // never wrong).
            m.heap.traceCell(cell, m);
        };
    }
};

/// Size classes, in bytes, header included.
const classes = [_]u32{ 16, 32, 48, 64, 96, 128, 192, 256, 384, 512, 768, 1024, 1536, 2048 };
const large_threshold: u32 = 2048;
const align_bytes = 16;

const FreeCell = extern struct { header: Cell, next: ?*FreeCell };

pub const Heap = struct {
    /// The region: bump-allocated from `top`, the rest held by free lists.
    region: []u8,
    top: usize = 0,
    free: [classes.len]?*FreeCell = @splat(null),
    /// Large cells, each its own allocation from the region (never
    /// returned: rare, and the region is the page's).
    large: std.ArrayList(*Cell) = .empty,
    /// Bookkeeping memory (mark stack, lists) — the embedder's allocator.
    meta: std.mem.Allocator,
    roots: std.ArrayList(Root) = .empty,
    /// Bytes allocated since the last collection, and the threshold
    /// that triggers the next.
    allocated_since: usize = 0,
    threshold: usize = 1 << 20,
    /// Every cell ever allocated, for the sweep (a class-indexed
    /// segregated list would do without this; it is the simple form).
    cells: std.ArrayList(*Cell) = .empty,
    tracer: *const fn (heap: *Heap, cell: *Cell, m: *Marker) void,
    finalizer: ?*const fn (heap: *Heap, cell: *Cell) void = null,
    collections: usize = 0,
    live_bytes: usize = 0,
    /// Temporary roots: cells the runtime holds in Zig locals across an
    /// allocation that could collect. Pushed and released in scopes.
    temps: std.ArrayList(*Cell) = .empty,
    /// Debugging: collect at every safe point and poison freed cells,
    /// so a missing root fails fast and near its cause.
    stress: bool = false,

    pub fn init(region: []u8, meta: std.mem.Allocator, tracer: *const fn (heap: *Heap, cell: *Cell, m: *Marker) void) Heap {
        return .{ .region = region, .meta = meta, .tracer = tracer };
    }

    /// Tear the heap down: every live cell is finalized (its off-heap
    /// bookkeeping freed), then the lists. The region is the embedder's.
    pub fn deinit(h: *Heap) void {
        if (h.finalizer) |f| {
            // (Large cells are in `cells` too.)
            for (h.cells.items) |c| if (c.kind != .bytes and c.kind != .free) f(h, c);
        }
        h.cells.deinit(h.meta);
        h.large.deinit(h.meta);
        h.roots.deinit(h.meta);
        h.temps.deinit(h.meta);
    }

    pub fn addRoot(h: *Heap, r: Root) !void {
        try h.roots.append(h.meta, r);
    }

    /// Keep `c` alive until the matching `tempRelease`.
    pub fn tempPush(h: *Heap, c: *Cell) void {
        h.temps.append(h.meta, c) catch {};
    }
    pub fn tempMark(h: *const Heap) usize {
        return h.temps.items.len;
    }
    pub fn tempRelease(h: *Heap, mark: usize) void {
        h.temps.shrinkRetainingCapacity(mark);
    }

    pub fn removeRoot(h: *Heap, ctx: *anyopaque) void {
        var i: usize = 0;
        while (i < h.roots.items.len) : (i += 1) if (h.roots.items[i].ctx == ctx) {
            _ = h.roots.swapRemove(i);
            return;
        };
    }

    fn classOf(size: u32) ?u8 {
        for (classes, 0..) |c, i| if (size <= c) return @intCast(i);
        return null;
    }

    /// A cell of `size` bytes (header included), zeroed, of `kind`.
    /// Allocation never collects: the collector runs at the VM's safe
    /// points (`wantsCollect` between instructions), where every live
    /// value is in a register or a root and no Zig local holds one —
    /// the discipline that will let the nursery move cells. A region
    /// that fills between safe points is out of memory.
    pub fn alloc(h: *Heap, kind: Kind, size: usize) error{OutOfMemory}!*Cell {
        const sz: u32 = @intCast(size);
        var cell: *Cell = undefined;
        if (classOf(sz)) |ci| {
            const csize = classes[ci];
            cell = h.takeFree(ci) orelse h.bump(csize) orelse return error.OutOfMemory;
            const bytes: [*]u8 = @ptrCast(cell);
            @memset(bytes[0..csize], 0);
            cell.* = .{ .kind = kind, .class = ci, .size = csize };
            h.allocated_since += csize;
        } else {
            const rounded = (sz + align_bytes - 1) & ~@as(u32, align_bytes - 1);
            cell = h.bump(rounded) orelse return error.OutOfMemory;
            const bytes: [*]u8 = @ptrCast(cell);
            @memset(bytes[0..rounded], 0);
            cell.* = .{ .kind = kind, .class = 0xff, .size = rounded };
            try h.large.append(h.meta, cell);
            h.allocated_since += rounded;
        }
        return cell;
    }

    /// Whether a safe point should collect: enough allocated since the
    /// last collection, or the region's free space running low.
    pub inline fn wantsCollect(h: *const Heap) bool {
        if (h.stress) return true;
        return h.allocated_since >= h.threshold or h.region.len - h.top < h.region.len / 8;
    }

    fn takeFree(h: *Heap, ci: u8) ?*Cell {
        const f = h.free[ci] orelse return null;
        h.free[ci] = f.next;
        return @ptrCast(f);
    }

    /// Fresh bytes from the region's top, registered in the cell list.
    fn bump(h: *Heap, size: u32) ?*Cell {
        const start = (h.top + align_bytes - 1) & ~@as(usize, align_bytes - 1);
        if (start + size > h.region.len) return null;
        h.top = start + size;
        const cell: *Cell = @ptrCast(@alignCast(h.region.ptr + start));
        h.cells.append(h.meta, cell) catch return null;
        return cell;
    }

    pub fn traceCell(h: *Heap, cell: *Cell, m: *Marker) void {
        h.tracer(h, cell, m);
    }

    /// A store of a reference into a cell: where a generational
    /// collector remembers old-to-young pointers. Nothing moves yet.
    pub inline fn writeBarrier(h: *Heap, into: *Cell, v: Value) void {
        _ = h;
        _ = into;
        _ = v;
    }

    /// Mark from every root, sweep every cell not marked onto its free
    /// list.
    pub fn collect(h: *Heap) void {
        var m: Marker = .{ .heap = h, .stack = .empty };
        defer m.stack.deinit(h.meta);
        for (h.temps.items) |c| m.markCell(c);
        for (h.roots.items) |r| r.trace(r.ctx, &m);
        while (m.stack.pop()) |c| h.traceCell(c, &m);
        var live: usize = 0;
        var kept: usize = 0;
        for (h.cells.items) |c| {
            if (c.marked) {
                c.marked = false;
                live += c.size;
                h.cells.items[kept] = c;
                kept += 1;
                continue;
            }
            if (c.kind == .free) {
                // Already on a free list from an earlier sweep.
                h.cells.items[kept] = c;
                kept += 1;
                continue;
            }
            if (h.finalizer) |f| f(h, c);
            if (c.class != 0xff) {
                if (h.stress) {
                    const bytes: [*]u8 = @ptrCast(c);
                    @memset(bytes[@sizeOf(FreeCell)..c.size], 0xAA);
                }
                const fc: *FreeCell = @ptrCast(@alignCast(c));
                fc.next = h.free[c.class];
                h.free[c.class] = fc;
                // Keep it in the cell list: a freed cell is reused in place.
                h.cells.items[kept] = c;
                kept += 1;
                c.marked = false;
                c.kind = .free;
            }
        }
        h.cells.shrinkRetainingCapacity(kept);
        h.live_bytes = live;
        h.collections += 1;
        h.allocated_since = 0;
        // The next collection after as much again as is live, at least
        // 1 MB — capped so a large region still collects before it fills.
        h.threshold = @min(@max(1 << 20, live), @max(h.region.len / 4, 1 << 16));
    }
};

// ------------------------------------------------------------- tests

const TestCell = extern struct { header: Cell, ref: ?*Cell, payload: u64 };

fn testTrace(_: *Heap, cell: *Cell, m: *Marker) void {
    if (cell.kind == .bytes) return;
    const t = cell.as(TestCell);
    m.markCell(t.ref);
}

const TestRoots = struct {
    keep: std.ArrayList(*Cell) = .empty,
    fn trace(ctx: *anyopaque, m: *Marker) void {
        const self: *TestRoots = @ptrCast(@alignCast(ctx));
        for (self.keep.items) |c| m.markCell(c);
    }
};

test "heap: cells survive through roots and references, garbage is reused" {
    const region = try std.testing.allocator.alloc(u8, 64 << 10);
    defer std.testing.allocator.free(region);
    var h = Heap.init(region, std.testing.allocator, testTrace);
    defer h.deinit();
    var roots: TestRoots = .{};
    defer roots.keep.deinit(std.testing.allocator);
    try h.addRoot(.{ .ctx = &roots, .trace = TestRoots.trace });
    const a = try h.alloc(.object, @sizeOf(TestCell));
    const b = try h.alloc(.object, @sizeOf(TestCell));
    a.as(TestCell).ref = b; // b reachable through a
    a.as(TestCell).payload = 7;
    b.as(TestCell).payload = 9;
    try roots.keep.append(std.testing.allocator, a);
    const garbage = try h.alloc(.object, @sizeOf(TestCell));
    garbage.as(TestCell).payload = 42;
    h.collect();
    try std.testing.expectEqual(@as(u64, 7), a.as(TestCell).payload);
    try std.testing.expectEqual(@as(u64, 9), b.as(TestCell).payload);
    try std.testing.expectEqual(@as(usize, 2 * classes[Heap.classOf(@sizeOf(TestCell)).?]), h.live_bytes);
    // The freed cell is handed out again.
    const again = try h.alloc(.object, @sizeOf(TestCell));
    try std.testing.expectEqual(garbage, again);
    try std.testing.expectEqual(@as(u64, 0), again.as(TestCell).payload);
}

test "heap: a large cell and a full region" {
    const region = try std.testing.allocator.alloc(u8, 16 << 10);
    defer std.testing.allocator.free(region);
    var h = Heap.init(region, std.testing.allocator, testTrace);
    defer h.deinit();
    const big = try h.alloc(.bytes, 4096);
    try std.testing.expectEqual(@as(u8, 0xff), big.class);
    // Fill the region with garbage: collecting at safe points keeps it going.
    var n: usize = 0;
    while (n < 10000) : (n += 1) {
        if (h.wantsCollect()) h.collect();
        _ = try h.alloc(.bytes, 64);
    }
    try std.testing.expect(h.collections > 0);
    // Without a safe point the region fills and says so.
    var m: usize = 0;
    while (m < 10000) : (m += 1) _ = h.alloc(.bytes, 64) catch break;
    try std.testing.expect(m < 10000);
}
