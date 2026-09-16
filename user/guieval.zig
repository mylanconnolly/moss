//! Bounded evaluation epochs for resident mshl views. A GUI window is a
//! host command that runs for minutes inside one statement of the script
//! that opened it, rendering thousands of view trees: callbacks use
//! scratch memory reset per render, and the state/tree snapshot retains
//! the functions and capability handles that escape a render.
//!
//! The interpreter frees a box when the statement that dropped it to zero
//! ends. Everything the enclosing statement already dropped — the
//! command's own arguments, a closure evaluated just before it — is owed
//! that lifetime, so the epoch detaches the interpreter's pending dead
//! list for its duration: its per-render collections see only boxes the
//! epoch itself let go, and `deinit` hands the pending ones back for the
//! statement's end. (The first version instead re-pinned every suspended
//! caller's values around each collection, and still freed an argument
//! that had been evaluated but not yet bound.)
const std = @import("std");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;
pub const Epoch = struct {
    it: *mshl.Interp = undefined,
    scratch: std.heap.ArenaAllocator = undefined,
    outer: std.mem.Allocator = undefined,
    frames: @TypeOf(@as(mshl.Interp, undefined).free_frames) = .empty,
    out: std.ArrayList(u8) = .empty,
    ret: Value = .nothing,
    returned: Value = .nothing,
    err_msg: []const u8 = "",
    roots: ?*mshl.Box = null,
    snapshot: ?*mshl.Box = null,
    pending: ?*mshl.Box = null,
    active: bool = false,

    /// `roots` names the spec/callback values this host loop keeps calling;
    /// they are held so a release during the epoch cannot retire them.
    pub fn begin(self: *Epoch, it: *mshl.Interp, roots: Value) mshl.Error!void {
        std.debug.assert(!self.active);
        const held = try it.holdHostValue(roots); // alive before they leave the pending list
        const pending = it.detachDead(roots);
        self.* = .{ .it = it, .scratch = std.heap.ArenaAllocator.init(it.heap), .outer = it.arena, .frames = it.free_frames, .out = it.out, .ret = it.ret, .err_msg = it.err_msg, .roots = held, .pending = pending, .active = true };
        it.arena = self.scratch.allocator();
        it.free_frames = .empty;
        it.out = .empty;
        it.err_msg = "";
    }

    /// Call once before each render, replacing `it.reclaim()`. No renderer
    /// pointers from the previous tree may be used after this call; redraw
    /// before reading hit boxes. Allocation failure preserves the old epoch.
    pub fn checkpoint(self: *Epoch, state: *Value, tree: *Value) mshl.Error!void {
        const next = try self.it.holdHostValue(.{ .list = &.{ state.*, tree.* } });
        if (self.snapshot) |old| self.it.releaseHostValue(old);
        self.snapshot = next;
        state.* = next.value.list[0];
        tree.* = next.value.list[1];
        self.it.free_frames = .empty;
        self.it.out = .empty;
        self.it.ret = .nothing;
        self.it.err_msg = "";
        _ = self.scratch.reset(.free_all);
        self.it.reclaim();
    }

    /// A GUI's returned state belongs to the caller's original arena.
    pub fn finish(self: *Epoch, value: Value) mshl.Error!Value {
        const out = try mshl.dupValue(self.outer, value);
        self.returned = out;
        return out;
    }

    pub fn deinit(self: *Epoch) void {
        if (!self.active) return;
        const message = self.it.err_msg;
        self.it.err_msg = if (message.len == 0) self.err_msg else self.outer.dupe(u8, message) catch "GUI evaluation failed (out of memory)";
        self.it.arena = self.outer;
        self.it.free_frames = self.frames;
        self.it.out = self.out;
        self.it.ret = self.ret;
        // The snapshot and the roots go, and what they alone kept alive is
        // collected now — a window reopened in the same statement must not
        // find the last one's tree still allocated — except the returned
        // value, which the caller's `let` has yet to retain: it is queued
        // for the enclosing statement's end, with the pending boxes.
        if (self.snapshot) |box| self.it.releaseHostValue(box);
        if (self.roots) |box| self.it.releaseHostValue(box);
        self.it.reclaimKeeping(self.returned);
        self.it.restoreDead(self.pending);
        self.scratch.deinit();
        self.active = false;
    }
};

test "10000 resident views fit the original 2MiB line arena and retain escaped values" {
    const Host = struct {
        dropped: usize = 0,
        created: usize = 0,
        line: *std.heap.FixedBufferAllocator,
        fn drop(ctx: *anyopaque, _: []const u8, _: u64) void {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.dropped += 1;
        }
        fn call(ctx: *anyopaque, it: *mshl.Interp, name: []const u8, args: []const Value, _: ?Value) mshl.Error!?Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (std.mem.eql(u8, name, "fresh")) {
                self.created += 1;
                return try it.newHandle("probe", self.created, ctx, drop);
            }
            if (std.mem.eql(u8, name, "keep")) {
                // A handle evaluated as an earlier argument of this same
                // statement must survive the epoch `cycle` ran in between:
                // the last view's handle and this one are the two alive.
                if (self.created - self.dropped != 2) return error.Runtime;
                return args[0];
            }
            if (std.mem.eql(u8, name, "cycle")) {
                const baseline = self.line.end_index;
                var state = try mshl.toValue(it.arena, .{ .n = @as(i64, 0) });
                var tree: Value = .nothing;
                var epoch: Epoch = .{};
                try epoch.begin(it, .{ .list = args });
                defer epoch.deinit();
                for (0..10000) |i| {
                    tree = try it.callValue(args[0], &.{state}, null, null);
                    state = tree;
                    try epoch.checkpoint(&state, &tree);
                    const got = try it.callValue(tree.record.get("callback").?, &.{.{ .int = 7 }}, null, null);
                    if (got != .int or got.int != @as(i64, @intCast(i)) + 8) return error.Runtime;
                    // View strings, records, frames and handles must never
                    // consume the script's fixed, non-reclaiming arena.
                    if (self.line.end_index > baseline + 512) return error.OutOfMemory;
                    if (self.created - self.dropped > 2) return error.Runtime;
                }
                return try epoch.finish(state);
            }
            return null;
        }
    };
    const storage = try std.testing.allocator.alloc(u8, 2 * 1024 * 1024);
    defer std.testing.allocator.free(storage);
    var line = std.heap.FixedBufferAllocator.init(storage);
    var host = Host{ .line = &line };
    // Match mshrun's actual reclaiming heap as well as its line arena.
    const Pool = @import("mosslib").pool.Pool(256, 2048);
    const pool = try std.testing.allocator.create(Pool);
    defer std.testing.allocator.destroy(pool);
    pool.* = .{};
    var it = mshl.Interp.init(line.allocator(), pool.allocator(), .{ .ctx = &host, .call = Host.call });
    errdefer it.deinit();
    const result = it.run(
        \\let view = fn [state] {
        \\  let n = ($state.n + 1)
        \\  { n: $n, callback: (fn [x] { $n + $x }), handle: (fresh), label: "Application $n", items: ["Files", "Editor", "Terminal"] }
        \\}
        \\let outer = fn [view] {
        \\  let saved = fn [x] { $x + 73 }
        \\  let result = (cycle $view)
        \\  { result: $result, saved: ($saved 0) }
        \\}
        \\keep (fresh) (cycle $view)
        \\$outer $view
    ) catch |err| {
        std.debug.print("epoch test: {s}\n", .{it.err_msg});
        return err;
    };
    try std.testing.expectEqual(@as(i64, 73), result.record.get("saved").?.int);
    const state = result.record.get("result").?;
    try std.testing.expectEqual(@as(i64, 10000), state.record.get("n").?.int);
    const callback = try it.callValue(state.record.get("callback").?, &.{.{ .int = 7 }}, null, null);
    try std.testing.expectEqual(@as(i64, 10007), callback.int);
    try std.testing.expectEqual(@as(usize, 20001), host.created); // two cycles and the kept probe
    it.reclaim();
    try std.testing.expectEqual(host.created, host.dropped);
    it.deinit();
    for (pool.used) |used| try std.testing.expect(!used);
}

test "reopening large inline views retires each epoch before allocating the next" {
    const Pool = @import("mosslib").pool.Pool(256, 2048);
    const Host = struct {
        pool: *Pool,
        calls: usize = 0,
        fn call(ctx: *anyopaque, it: *mshl.Interp, name: []const u8, args: []const Value, _: ?Value) mshl.Error!?Value {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            if (!std.mem.eql(u8, name, "once")) return null;
            var epoch: Epoch = .{};
            try epoch.begin(it, .{ .list = args });
            errdefer epoch.deinit();
            var state: Value = .nothing;
            var tree = try it.callValue(args[0], &.{state}, null, null);
            try epoch.checkpoint(&state, &tree);
            if (tree.str.len != 32768) return error.Runtime;
            const answer = try epoch.finish(.nothing);
            epoch.deinit();
            var live: usize = 0;
            for (self.pool.used) |used| live += @intFromBool(used);
            // Parser source stays in the outer line arena; the finished
            // window's large closure AST and tree must be retired already.
            if (live > 64) return error.OutOfMemory;
            self.calls += 1;
            return answer;
        }
    };
    const pool = try std.testing.allocator.create(Pool);
    defer std.testing.allocator.destroy(pool);
    pool.* = .{};
    const storage = try std.testing.allocator.alloc(u8, 1024 * 1024);
    defer std.testing.allocator.free(storage);
    var line = std.heap.FixedBufferAllocator.init(storage);
    var host = Host{ .pool = pool };
    var it = mshl.Interp.init(line.allocator(), pool.allocator(), .{ .ctx = &host, .call = Host.call });
    errdefer it.deinit();
    const padding = try std.testing.allocator.alloc(u8, 32768);
    defer std.testing.allocator.free(padding);
    @memset(padding, 'a');
    const script = try std.fmt.allocPrint(std.testing.allocator, "let n = 0; while ($n < 100) {{ once (fn [state] {{ \"{s}\" }}); let n = ($n + 1) }}; $n", .{padding});
    defer std.testing.allocator.free(script);
    const result = try it.run(script);
    try std.testing.expectEqual(@as(i64, 100), result.int);
    try std.testing.expectEqual(@as(usize, 100), host.calls);
    it.deinit();
    for (pool.used) |used| try std.testing.expect(!used);
}
