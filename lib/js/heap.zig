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
const builtin = @import("builtin");
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

/// Weak references' hooks: `ephemerons` runs once the mark stack drains
/// and marks what a marked key keeps alive (true when it marked anything
/// — the collector drains and asks again, to the fixpoint); `clear`
/// runs at the fixpoint, before the sweep, to drop the entries, targets
/// and cells whose referents died.
pub const WeakHooks = struct {
    ctx: *anyopaque,
    ephemerons: *const fn (ctx: *anyopaque, m: *Marker) bool,
    clear: *const fn (ctx: *anyopaque) void,
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
    /// The collector's work list, kept between collections.
    mark_stack: std.ArrayList(*Cell) = .empty,
    roots: std.ArrayList(Root) = .empty,
    /// Bytes allocated since the last collection, and the threshold
    /// that triggers the next.
    allocated_since: usize = 0,
    threshold: usize = 1 << 20,
    /// Bytes taken from the region's top since the last collection
    /// (a free-list reuse costs no room): what the low-room rule counts.
    bumped_since: usize = 0,
    /// Bytes the runtime took from the bookkeeping allocator since the
    /// last collection (through `counted`), and how many of them ask
    /// for one: what a dead object owns there — its slots and tables,
    /// a RegExp's program — comes back only when it is collected, and
    /// the cell heap alone never asked (the BBC's page filled 32 MB of
    /// bookkeeping with 6 MB of cells live and no collection, 2026-09-28).
    foreign_since: usize = 0,
    foreign_stride: usize = 4 << 20,
    /// While nonzero no collection runs: a compile keeps the code cells
    /// it has made in scratch lists the scanner does not read.
    hold: u32 = 0,
    /// The last exhaustion rescue found nothing to free: no rescue again
    /// until some allocation has succeeded since (a full heap otherwise
    /// ran a whole collection per refused allocation — GitHub's page
    /// spent five minutes in them, 2026-09-28).
    rescue_failed: bool = false,
    /// (The sweep walks the region: cells lie end to end from its start
    /// to `top`, each saying its size. A list of them cost eight bytes a
    /// cell and one contiguous block that a fragmented bookkeeping heap
    /// could not grow — 915 KB on Apple's page, 2026-09-28 — and the
    /// cell heap read as full with ten megabytes free.)
    tracer: *const fn (heap: *Heap, cell: *Cell, m: *Marker) void,
    finalizer: ?*const fn (heap: *Heap, cell: *Cell) void = null,
    weak: ?WeakHooks = null,
    collections: usize = 0,
    live_bytes: usize = 0,
    /// Set when an allocation found no room (after a collection): the
    /// embedder can tell the cell heap's exhaustion from its own.
    exhausted: bool = false,
    /// Temporary roots: cells the runtime holds in Zig locals across an
    /// allocation that could collect. Pushed and released in scopes.
    temps: std.ArrayList(*Cell) = .empty,
    /// Debugging: collect at every safe point and poison freed cells,
    /// so a missing root fails fast and near its cause.
    stress: bool = false,
    /// One bit per 16 bytes of the region: a cell starts there. What
    /// lets the collector read the native stack conservatively — any
    /// word that is a cell's address keeps the cell — so it may run
    /// while a native holds cells in Zig locals (2026-09-28: pages ran
    /// their work under natives and never collected).
    cell_map: []u8 = &.{},
    /// The native stack's upper bound to scan to: the embedder's frame
    /// at `Vm.init`, above every frame the engine runs in. Zero: no scan.
    stack_hi: usize = 0,

    pub fn init(region: []u8, meta: std.mem.Allocator, tracer: *const fn (heap: *Heap, cell: *Cell, m: *Marker) void) Heap {
        var h: Heap = .{ .region = region, .meta = meta, .tracer = tracer };
        h.threshold = @max(@min(1 << 20, region.len / 4), 1024);
        if (meta.alloc(u8, region.len / align_bytes / 8 + 1)) |map| {
            @memset(map, 0);
            h.cell_map = map;
        } else |_| {}
        return h;
    }

    /// Tear the heap down: every live cell is finalized (its off-heap
    /// bookkeeping freed), then the lists. The region is the embedder's.
    pub fn deinit(h: *Heap) void {
        if (h.finalizer) |f| {
            var w = h.walk();
            while (w.next()) |c| if (c.kind != .bytes and c.kind != .free) f(h, c);
        }
        h.mark_stack.deinit(h.meta);
        h.large.deinit(h.meta);
        h.roots.deinit(h.meta);
        h.temps.deinit(h.meta);
        if (h.cell_map.len > 0) h.meta.free(h.cell_map);
    }

    pub fn addRoot(h: *Heap, r: Root) !void {
        try h.roots.append(h.meta, r);
    }

    /// The bookkeeping allocator, counted: what the runtime takes through
    /// it adds to `foreign_since`, so bookkeeping pressure reaches the
    /// next safe point. Growth in place counts too; frees do not (what a
    /// collection frees is the point).
    pub fn counted(h: *Heap) std.mem.Allocator {
        return .{ .ptr = h, .vtable = &counted_vtable };
    }
    const counted_vtable: std.mem.Allocator.VTable = .{ .alloc = countedAlloc, .resize = countedResize, .remap = countedRemap, .free = countedFree };
    fn countedAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        h.foreign_since += n;
        return h.meta.rawAlloc(n, alignment, ra);
    }
    fn countedResize(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) h.foreign_since += new_len - memory.len;
        return h.meta.rawResize(memory, alignment, new_len, ra);
    }
    fn countedRemap(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        if (new_len > memory.len) h.foreign_since += new_len - memory.len;
        return h.meta.rawRemap(memory, alignment, new_len, ra);
    }
    fn countedFree(ctx: *anyopaque, memory: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const h: *Heap = @ptrCast(@alignCast(ctx));
        h.meta.rawFree(memory, alignment, ra);
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
            cell = h.takeFree(ci) orelse h.bump(csize) orelse h.rescue(ci, csize) orelse {
                h.exhausted = true;
                return error.OutOfMemory;
            };
            const bytes: [*]u8 = @ptrCast(cell);
            @memset(bytes[0..csize], 0);
            cell.* = .{ .kind = kind, .class = ci, .size = csize };
            h.allocated_since += csize;
        } else {
            const rounded = (sz + align_bytes - 1) & ~@as(u32, align_bytes - 1);
            // A dead large cell that fits is used again (an array that
            // doubled left its old stores behind for good, 2026-09-28).
            if (h.takeLarge(rounded)) |c| {
                const bytes: [*]u8 = @ptrCast(c);
                const keep = c.size;
                @memset(bytes[0..keep], 0);
                c.* = .{ .kind = kind, .class = 0xff, .size = keep };
                h.allocated_since += keep;
                return c;
            }
            cell = h.bump(rounded) orelse h.rescue(null, rounded) orelse {
                h.exhausted = true;
                return error.OutOfMemory;
            };
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
        if (h.hold != 0) return false;
        if (h.stress) return true;
        if (h.allocated_since >= h.threshold) return true;
        if (h.foreign_since >= h.foreign_stride) return true;
        // The bump space nearly gone: collect once half of what is left
        // has been taken — not at every safe point (the top never comes
        // down, so that once meant a collection per instruction on a
        // full heap: 24 s of them on GitHub, 2026-09-28), and not so
        // late that the next burst runs past the end.
        const room = h.region.len - h.top;
        return room < h.region.len / 8 and h.bumped_since >= @max(room / 2, 4 << 10);
    }

    /// The region's end reached between safe points: a collection here,
    /// then one more try. Safe only because the collector reads the
    /// native stack — whatever the caller holds in a local is a root —
    /// so it waits for a `stack_hi` to scan to.
    fn rescue(h: *Heap, ci: ?u8, size: u32) ?*Cell {
        if (h.stack_hi == 0 or h.cell_map.len == 0 or h.hold != 0) return null;
        if (h.rescue_failed and h.allocated_since < (64 << 10)) return null;
        h.collect();
        const got: ?*Cell = blk: {
            if (ci) |c| if (h.takeFree(c)) |cell| break :blk cell;
            if (ci == null) if (h.takeLarge(size)) |c| {
                const bytes: [*]u8 = @ptrCast(c);
                @memset(bytes[0..c.size], 0);
                break :blk c;
            };
            break :blk h.bump(size);
        };
        h.rescue_failed = got == null;
        return got;
    }

    /// The smallest dead large cell of at least `size` bytes (at most
    /// twice it, so a small request does not take a huge block).
    /// The cells in address order, from the region's start to `top`.
    pub const Walk = struct {
        h: *const Heap,
        at: usize = 0,
        pub fn next(w: *Walk) ?*Cell {
            if (w.at >= w.h.top) return null;
            const c: *Cell = @ptrCast(@alignCast(w.h.region.ptr + w.at));
            w.at = (w.at + c.size + align_bytes - 1) & ~@as(usize, align_bytes - 1);
            return c;
        }
    };
    pub fn walk(h: *const Heap) Walk {
        return .{ .h = h };
    }

    fn takeLarge(h: *Heap, size: u32) ?*Cell {
        var best: ?*Cell = null;
        for (h.large.items) |c| {
            if (c.kind != .free or c.size < size or c.size > size * 2) continue;
            if (best == null or c.size < best.?.size) best = c;
        }
        return best;
    }

    fn takeFree(h: *Heap, ci: u8) ?*Cell {
        const f = h.free[ci] orelse return null;
        h.free[ci] = f.next;
        return @ptrCast(f);
    }

    /// Fresh bytes from the region's top.
    fn bump(h: *Heap, size: u32) ?*Cell {
        const start = (h.top + align_bytes - 1) & ~@as(usize, align_bytes - 1);
        if (start + size > h.region.len) return null;
        h.top = start + size;
        h.bumped_since += size;
        const cell: *Cell = @ptrCast(@alignCast(h.region.ptr + start));
        const bit = start / align_bytes;
        if (bit / 8 < h.cell_map.len) h.cell_map[bit / 8] |= @as(u8, 1) << @intCast(bit % 8);
        return cell;
    }

    /// The cell a word points into, if it is one: at a cell's start, or
    /// inside a small cell (a Zig local may hold an interior pointer —
    /// a function's data — with the object itself dead in registers).
    fn cellAt(h: *const Heap, word: usize) ?*Cell {
        const base = @intFromPtr(h.region.ptr);
        if (word < base or word >= base + h.top or word % 8 != 0) return null;
        var idx = (word - base) / align_bytes;
        var back: usize = 0;
        while (back <= large_threshold / align_bytes) : (back += 1) {
            if (idx / 8 < h.cell_map.len and (h.cell_map[idx / 8] >> @intCast(idx % 8)) & 1 != 0) {
                const c: *Cell = @ptrCast(@alignCast(h.region.ptr + idx * align_bytes));
                return if (word < @intFromPtr(c) + c.size) c else null;
            }
            if (idx == 0) break;
            idx -= 1;
        }
        return null;
    }

    /// Every word of the native stack between `lo` and `hi` that names
    /// a cell keeps it (and what it references).
    fn scanStack(h: *const Heap, m: *Marker, lo: usize, hi: usize) void {
        var at = lo & ~@as(usize, 7);
        while (at + 8 <= hi) : (at += 8) {
            const word = @as(*const usize, @ptrFromInt(at)).*;
            if (h.cellAt(word)) |c| if (c.kind != .free) m.markCell(c);
        }
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
        // The mark stack is kept between collections: a fresh list each
        // time grew through every size class again — cheap with a bump
        // allocator that extends its last block, a copy per step with a
        // real one (found by the script domain's bench, 2026-09-25).
        var m: Marker = .{ .heap = h, .stack = h.mark_stack };
        m.stack.clearRetainingCapacity();
        defer h.mark_stack = m.stack;
        for (h.temps.items) |c| m.markCell(c);
        for (h.roots.items) |r| r.trace(r.ctx, &m);
        // The native stack, registers included (spilled here first).
        if (h.stack_hi != 0 and h.cell_map.len > 0) {
            var spill: [16]usize = @splat(0);
            spillRegisters(&spill);
            const lo = @min(@intFromPtr(&spill), @frameAddress());
            h.scanStack(&m, lo, h.stack_hi);
        }
        // Drain; then let weak tables mark what their live keys keep,
        // and drain again, until nothing new is marked.
        while (true) {
            while (m.stack.pop()) |c| h.traceCell(c, &m);
            const w = h.weak orelse break;
            if (!w.ephemerons(w.ctx, &m)) break;
        }
        if (h.weak) |w| w.clear(w.ctx);
        var live: usize = 0;
        var w = h.walk();
        while (w.next()) |c| {
            if (c.marked) {
                c.marked = false;
                live += c.size;
                continue;
            }
            // Already on a free list from an earlier sweep.
            if (c.kind == .free) continue;
            if (h.finalizer) |f| f(h, c);
            if (c.class == 0xff) {
                // A large cell: dead in place, for `takeLarge`.
                c.marked = false;
                c.kind = .free;
                continue;
            }
            if (h.stress) {
                const bytes: [*]u8 = @ptrCast(c);
                @memset(bytes[@sizeOf(FreeCell)..c.size], 0xAA);
            }
            const fc: *FreeCell = @ptrCast(@alignCast(c));
            fc.next = h.free[c.class];
            h.free[c.class] = fc;
            c.marked = false;
            c.kind = .free;
        }
        h.live_bytes = live;
        h.collections += 1;
        h.allocated_since = 0;
        h.bumped_since = 0;
        h.foreign_since = 0;
        // The next collection after as much again as is live, at least
        // 1 MB — capped so a large region still collects before it fills
        // (a longer stride let the top run through the region class by
        // class and left a small heap out of memory with little live).
        h.threshold = @min(@max(@min(1 << 20, h.region.len / 4), live), @max(h.region.len / 4, 1 << 16));
    }
};

/// The callee-saved registers into `out`, so a cell held only in one
/// is found on the stack by the scan.
fn spillRegisters(out: *[16]usize) void {
    switch (builtin.cpu.arch) {
        .aarch64 => asm volatile (
            \\stp x19, x20, [%[o]]
            \\stp x21, x22, [%[o], #16]
            \\stp x23, x24, [%[o], #32]
            \\stp x25, x26, [%[o], #48]
            \\stp x27, x28, [%[o], #64]
            \\str x29, [%[o], #80]
            :
            : [o] "r" (out),
            : .{ .memory = true }),
        .x86_64 => asm volatile (
            \\movq %%rbx, 0(%[o])
            \\movq %%rbp, 8(%[o])
            \\movq %%r12, 16(%[o])
            \\movq %%r13, 24(%[o])
            \\movq %%r14, 32(%[o])
            \\movq %%r15, 40(%[o])
            :
            : [o] "r" (out),
            : .{ .memory = true }),
        else => {},
    }
}

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
