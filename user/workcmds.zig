//! Workers for mshl hosts that hold a spawner: `spawn { handler }` runs
//! the handler block in another domain (an mshrun worker stage) behind a
//! typed channel, and `x | call $w` sends `x` to it and gets the
//! handler's value back — the handler runs there with `$in = x`. Only
//! data crosses (the `remote` rule); captures do not, so the block sees
//! `$in` and nothing of the caller's scope. A worker lives across calls
//! until its handle is dropped or `close`d, which destroys its domain
//! totally (crash-only) — the caller owns the handle, so a script's exit
//! kills its live workers and leaves no orphan.
//!
//! The channel and the shared buffer are the same shape the remote stage
//! uses: a small message (`shared.WorkReq`/`WorkResp`) carries the
//! lengths, the value itself is an mshl data literal in the buffer.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const Shape = mshl.Shape;

/// The host wires these once: the spawner cap, and a way to load the
/// mshrun image into a stage (returning the stage handle, verified) —
/// which needs the host's own store lookup, so it is a callback.
pub const LoadFn = *const fn (it: *mshl.Interp) ?u64;
var spawner: u64 = 0;
var loadStage: ?LoadFn = null;

pub fn setup(spawner_cap: u64, load: LoadFn) void {
    spawner = spawner_cap;
    loadStage = load;
}

const buf_pages = shared.fab_bulk_pages; // 8 pages / 32 KB, like a remote stage
const max_workers = 4;

const Worker = struct {
    used: bool = false,
    /// Bumped per spawn: a handle names slot and generation, so a stale
    /// handle cannot drive the worker that took its slot.
    gen: u32 = 0,
    chan: u64 = 0, // our end of the worker's channel
    ctl: u64 = 0, // the worker domain's control cap (for teardown)
    shm: u64 = 0,
    buf: [*]u8 = undefined,
    buf_len: usize = 0,
};
var workers: [max_workers]Worker = @splat(.{});

pub const Conn = u64;

fn idOf(idx: usize) Conn {
    return @as(u64, workers[idx].gen) << 8 | idx;
}

fn slotOf(c: Conn) ?*Worker {
    const idx: usize = @intCast(c & 0xff);
    if (idx >= max_workers) return null;
    const w = &workers[idx];
    if (!w.used or w.gen != c >> 8) return null;
    return w;
}

const SpawnOut = union(enum) { conn: Conn, failed: []const u8 };

/// Spawn a worker running `handler_src` (the block's body, a script that
/// reads `$in`). The mshrun image must already be staged; `stage_handle`
/// is what the loader returned.
fn spawnWorker(stage_handle: u64, handler_src: []const u8) SpawnOut {
    if (handler_src.len > buf_pages * 4096) return .{ .failed = "the handler is too large" };
    var idx: usize = 0;
    while (idx < max_workers and workers[idx].used) idx += 1;
    if (idx == max_workers) return .{ .failed = "too_many" };

    const ch = usys.chanCreate();
    if (ch.err != .ok) return .{ .failed = "out of channels" };
    const sp = usys.spawn(spawner, stage_handle, 2, ch.data[0], shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a, usys.kbLimits(1 << 10, 4 << 10));
    _ = usys.capDrop(ch.data[0]);
    if (sp.err != .ok) {
        _ = usys.capDrop(ch.data[1]);
        return .{ .failed = "refused" };
    }
    const chan = ch.data[1];
    const ctl = sp.data[0];

    const sh = usys.shmCreate(buf_pages);
    if (sh.err != .ok) {
        tearDown(ctl, chan, 0, 0);
        return .{ .failed = "out of shared memory" };
    }
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) {
        _ = usys.capDrop(sh.data[0]);
        tearDown(ctl, chan, 0, 0);
        return .{ .failed = "cannot map the buffer" };
    }
    const buf: [*]u8 = @ptrFromInt(m.data[0]);

    switch (usys.callTyped(shared.WorkReq, shared.WorkResp, chan, .attach_buf, sh.data[0])) {
        .ok => |rep| if (rep != .ok) {
            tearDown(ctl, chan, sh.data[0], m.data[0]);
            return .{ .failed = "the worker refused the buffer" };
        },
        .err => {
            tearDown(ctl, chan, sh.data[0], m.data[0]);
            return .{ .failed = "the worker did not start" };
        },
    }
    @memcpy(buf[0..handler_src.len], handler_src);
    switch (usys.callTyped(shared.WorkReq, shared.WorkResp, chan, .{ .handler = .{ .len = handler_src.len } }, 0)) {
        .ok => |rep| if (rep != .ok) {
            tearDown(ctl, chan, sh.data[0], m.data[0]);
            return .{ .failed = "the worker refused the handler" };
        },
        .err => {
            tearDown(ctl, chan, sh.data[0], m.data[0]);
            return .{ .failed = "the worker vanished setting the handler" };
        },
    }

    const w = &workers[idx];
    w.* = .{ .used = true, .gen = w.gen +% 1, .chan = chan, .ctl = ctl, .shm = sh.data[0], .buf = buf, .buf_len = m.data[1] * 4096 };
    return .{ .conn = idOf(idx) };
}

/// Destroy a worker's domain and drop every cap we hold for it. Total
/// and immediate — the crash-only teardown.
fn tearDown(ctl: u64, chan: u64, shm: u64, buf_va: u64) void {
    if (ctl != 0) _ = usys.domainDestroy(ctl);
    if (buf_va != 0) _ = usys.shmUnmap(buf_va);
    if (shm != 0) _ = usys.capDrop(shm);
    if (chan != 0) _ = usys.capDrop(chan);
    if (ctl != 0) _ = usys.capDrop(ctl);
}

pub fn close(c: Conn) void {
    const w = slotOf(c) orelse return;
    tearDown(w.ctl, w.chan, w.shm, @intFromPtr(w.buf));
    w.used = false;
}

fn dropWorker(_: *anyopaque, _: []const u8, id: u64) void {
    close(id);
}

// --------------------------------------------------------------- commands

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    return it.mkResult(false, .{ .str = msg });
}
fn okResult(it: *mshl.Interp, v: Value) mshl.Error!Value {
    return it.mkResult(true, v);
}

const worker_kind: Shape = .{ .kind = "worker" };
const worker_result = mshl.resultShape(worker_kind, .string);
const call_result = mshl.resultShape(.any, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "spawn")) return .{ .params = &.{.{ .name = "handler", .shape = .function }}, .ret = worker_result };
    if (std.mem.eql(u8, name, "call")) return .{ .params = &.{ .{ .name = "worker", .shape = worker_kind }, .{ .name = "input", .optional = true } }, .input = .{ .optional = .any }, .ret = call_result };
    return null;
}

/// null = not for us: `spawn`, `call`, and `close`/`status` on a worker
/// handle (other handles fall through to the socket/tls commands).
pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "spawn")) {
        if (spawner == 0 or loadStage == null) return it.fail("spawn: this program cannot spawn (no spawner)", .{});
        const src = switch (args[0]) {
            .func => |cl| cl.src,
            else => return it.fail("spawn: a block or function expected, got a {s}", .{args[0].typeName()}),
        };
        const stage_handle = loadStage.?(it) orelse return try errResult(it, "unreadable");
        return switch (spawnWorker(stage_handle, src)) {
            .conn => |c| try okResult(it, try it.newHandle("worker", c, &workers, dropWorker)),
            .failed => |m| try errResult(it, m),
        };
    }
    if (is(u8, name, "call")) {
        // The worker is the first argument; the request is the piped
        // input (`x | call $w`) or the second argument (`call $w x`).
        if (args.len < 1) return it.fail("call: a worker expected", .{});
        const w = try workerArg(it, args[0]);
        const in_val: Value = if (input) |v| v else if (args.len > 1) args[1] else .nothing;
        if (!in_val.isData()) return it.fail("call: the input is a {s}, which cannot cross to a worker (only data can)", .{in_val.typeName()});
        return try callWorker(it, w, in_val);
    }
    // close / status on a worker handle only.
    const hv = input orelse (if (args.len > 0) args[0] else return null);
    if (hv != .handle or !is(u8, hv.handle.kind, "worker")) return null;
    if (is(u8, name, "close")) {
        if (!hv.handle.closed) {
            close(hv.handle.id);
            it.closeHandle(hv);
        }
        return .nothing;
    }
    if (is(u8, name, "status")) {
        return .{ .str = if (hv.handle.closed or slotOf(hv.handle.id) == null) "closed" else "alive" };
    }
    return null;
}

fn workerArg(it: *mshl.Interp, v: Value) mshl.Error!*Worker {
    if (v != .handle or !std.mem.eql(u8, v.handle.kind, "worker")) return it.fail("call: a worker expected, got a {s}", .{v.typeName()});
    if (v.handle.closed) return it.fail("call: the worker is closed", .{});
    return slotOf(v.handle.id) orelse return it.fail("call: the worker is closed", .{});
}

fn callWorker(it: *mshl.Interp, w: *Worker, in_val: Value) mshl.Error!Value {
    var in_text: std.ArrayList(u8) = .empty;
    if (in_val != .nothing) try mshl.writeData(in_val, it.arena, &in_text);
    if (in_text.items.len > w.buf_len) return try errResult(it, "the request is larger than the buffer");
    @memcpy(w.buf[0..in_text.items.len], in_text.items);
    return switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .{ .call = .{ .len = in_text.items.len } }, 0)) {
        .ok => |rep| switch (rep) {
            .value => |v| blk: {
                if (v.len == 0) break :blk try okResult(it, .nothing);
                if (v.len > w.buf_len) break :blk try errResult(it, "the worker's value overran the buffer");
                const text = try it.arena.dupe(u8, w.buf[0..v.len]);
                break :blk try okResult(it, try mshl.tableize(it.arena, try it.parseData(text)));
            },
            .failed => |e| try errResult(it, try it.arena.dupe(u8, w.buf[0..@min(e.len, w.buf_len)])),
            .refused => try errResult(it, "the worker refused"),
            .ok => try okResult(it, .nothing),
        },
        .err => try errResult(it, "the worker vanished"),
    };
}

pub const command_names = [_][]const u8{ "spawn", "call" };
