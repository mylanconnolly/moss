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
const fsc = @import("fsclient.zig");
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
var fs_chan: u64 = 0;
var fs_buf: [*]u8 = undefined;
/// The fabric channel, when the host holds one: `publish`/`lookup` offer
/// a worker to the pool and reach one there. 0 = no fabric.
var fab_chan: u64 = 0;

pub fn setup(spawner_cap: u64, load: LoadFn, view_chan: u64, view_buf: [*]u8, fabric: u64) void {
    spawner = spawner_cap;
    loadStage = load;
    fs_chan = view_chan;
    fs_buf = view_buf;
    fab_chan = fabric;
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
    /// A dispatch is outstanding: the worker is computing (or its result
    /// waits unclaimed), and `await`/`race` will collect it.
    pending: bool = false,
    /// This worker's bit in the shared doorbell (its slot index).
    bit: u6 = 0,
    /// Offered to the pool by `publish`: reached only through `lookup`
    /// now, so a direct `call`/`dispatch` is refused (its buffer is the
    /// looker-up's).
    published: bool = false,
    shm: u64 = 0,
    buf: [*]u8 = undefined,
    buf_len: usize = 0,
};
var workers: [max_workers]Worker = @splat(.{});
/// The doorbell every worker rings when a dispatch finishes (created on
/// first spawn), and the bits seen so far but not yet collected — how
/// `race` learns which worker completed first.
var doorbell: u64 = 0;
var ready_mask: u64 = 0;

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
    // The worker is our agent: hand it a filesystem view so its handler
    // can read and write files. It must be a FRESH view (its own badge),
    // derived from ours — a shared badge would make the worker's own
    // attached buffer displace ours on the same view. Best-effort: a
    // worker still computes if the view cannot be given.
    if (fs_chan != 0) {
        if (fsc.fsDerive(fs_chan, fs_buf, "", false)) |wv| {
            _ = usys.callTyped(shared.WorkReq, shared.WorkResp, chan, .attach_view, wv);
            _ = usys.capDrop(wv); // the worker holds its own ref now
        }
    }
    // A doorbell for race: one notification the caller waits on, which
    // every worker rings (with its own bit) when a dispatch finishes.
    // Best-effort — without it a worker still computes; only `race`
    // needs it.
    if (doorbell == 0) {
        const n = usys.notifyCreate();
        if (n.err == .ok) doorbell = n.data[0];
    }
    if (doorbell != 0) {
        _ = usys.callTyped(shared.WorkReq, shared.WorkResp, chan, .{ .attach_bell = .{ .bit = idx } }, doorbell);
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
    w.* = .{ .used = true, .gen = w.gen +% 1, .bit = @intCast(idx), .chan = chan, .ctl = ctl, .shm = sh.data[0], .buf = buf, .buf_len = m.data[1] * 4096 };
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

// ---------------------------------------------------------- services
//
// A worker `publish`ed to the pool is reached elsewhere by `lookup`,
// which hands back a channel to it; a `service` handle wraps that
// channel with its own shared buffer, and `call` on it speaks the same
// worker protocol (the fabric proxies the buffer across the wire). One
// client at a time for now: the buffer is the looker-up's.

const max_services = 4;
const Service = struct {
    used: bool = false,
    gen: u32 = 0,
    chan: u64 = 0,
    shm: u64 = 0,
    buf: [*]u8 = undefined,
    buf_len: usize = 0,
    attached: bool = false,
};
var services: [max_services]Service = @splat(.{});

fn svcId(idx: usize) Conn {
    return @as(u64, services[idx].gen) << 8 | idx;
}
fn svcSlot(c: Conn) ?*Service {
    const idx: usize = @intCast(c & 0xff);
    if (idx >= max_services) return null;
    const sv = &services[idx];
    if (!sv.used or sv.gen != c >> 8) return null;
    return sv;
}

fn closeService(c: Conn) void {
    const sv = svcSlot(c) orelse return;
    if (sv.attached) _ = usys.shmUnmap(@intFromPtr(sv.buf));
    if (sv.shm != 0) _ = usys.capDrop(sv.shm);
    if (sv.chan != 0) _ = usys.capDrop(sv.chan);
    sv.used = false;
}

fn dropService(_: *anyopaque, _: []const u8, id: u64) void {
    closeService(id);
}

/// Give the service its own shared buffer the first time it is called.
fn ensureServiceBuf(sv: *Service) bool {
    if (sv.attached) return true;
    const sh = usys.shmCreate(buf_pages);
    if (sh.err != .ok) return false;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) {
        _ = usys.capDrop(sh.data[0]);
        return false;
    }
    switch (usys.callTyped(shared.WorkReq, shared.WorkResp, sv.chan, .attach_buf, sh.data[0])) {
        .ok => |rep| if (rep != .ok) {
            _ = usys.shmUnmap(m.data[0]);
            _ = usys.capDrop(sh.data[0]);
            return false;
        },
        .err => {
            _ = usys.shmUnmap(m.data[0]);
            _ = usys.capDrop(sh.data[0]);
            return false;
        },
    }
    sv.shm = sh.data[0];
    sv.buf = @ptrFromInt(m.data[0]);
    sv.buf_len = m.data[1] * 4096;
    sv.attached = true;
    return true;
}

fn callService(it: *mshl.Interp, sv: *Service, in_val: Value) mshl.Error!Value {
    if (!ensureServiceBuf(sv)) return try errResult(it, "cannot attach a buffer to the service");
    var in_text: std.ArrayList(u8) = .empty;
    if (in_val != .nothing) try mshl.writeData(in_val, it.arena, &in_text);
    if (in_text.items.len > sv.buf_len) return try errResult(it, "the request is larger than the buffer");
    @memcpy(sv.buf[0..in_text.items.len], in_text.items);
    return switch (usys.callTyped(shared.WorkReq, shared.WorkResp, sv.chan, .{ .call = .{ .len = in_text.items.len } }, 0)) {
        .ok => |rep| try replyToValue(it, sv.buf, sv.buf_len, rep),
        .err => try errResult(it, "the service vanished"),
    };
}

/// The fabric's error as a word, for a publish/lookup result.
fn fabErr(code: u64) []const u8 {
    const e = std.enums.fromInt(shared.FabErr, code) orelse return "error";
    return @tagName(e);
}

/// Offer a worker to the pool under a service id. The worker's channel
/// (our client end) becomes the export; remote callers reach the worker
/// through it, the fabric proxying their buffer. The worker is then
/// reached only through `lookup` — its buffer is the looker-up's.
fn publishWorker(it: *mshl.Interp, id: u64, w: *Worker) mshl.Error!Value {
    if (w.published) return try errResult(it, "the worker is already published");
    if (w.pending) return try errResult(it, "the worker is running; await it first");
    return switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .{ .publish = .{ .service = id } }, w.chan)) {
        .ok => |rep| switch (rep) {
            .ok => blk: {
                w.published = true;
                break :blk try okResult(it, .nothing);
            },
            .fab_err => |e| try errResult(it, fabErr(e.code)),
            else => try errResult(it, "the fabric gave an unexpected reply"),
        },
        .err => try errResult(it, "the fabric did not answer"),
    };
}

/// Look up a published service on `node` and wrap the channel the fabric
/// hands back as a callable `service` handle.
fn lookupService(it: *mshl.Interp, node: u64, id: u64) mshl.Error!Value {
    return switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{ .lookup = .{ .node = node, .service = id } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .found => blk: {
                if (ok.cap == 0) break :blk try errResult(it, "the fabric handed back no channel");
                var idx: usize = 0;
                while (idx < max_services and services[idx].used) idx += 1;
                if (idx == max_services) {
                    _ = usys.capDrop(ok.cap);
                    break :blk try errResult(it, "too many services");
                }
                const sv = &services[idx];
                sv.* = .{ .used = true, .gen = sv.gen +% 1, .chan = ok.cap };
                break :blk try okResult(it, try it.newHandle("service", svcId(idx), &services, dropService));
            },
            .fab_err => |e| try errResult(it, fabErr(e.code)),
            else => try errResult(it, "the fabric gave an unexpected reply"),
        },
        .err => try errResult(it, "the fabric did not answer"),
    };
}

// ---------------------------------------------------------- commands

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    return it.mkResult(false, .{ .str = msg });
}
fn okResult(it: *mshl.Interp, v: Value) mshl.Error!Value {
    return it.mkResult(true, v);
}

const worker_kind: Shape = .{ .kind = "worker" };
const service_kind: Shape = .{ .kind = "service" };
const worker_result = mshl.resultShape(worker_kind, .string);
const service_result = mshl.resultShape(service_kind, .string);
const callable_kind: Shape = .{ .one_of = &.{ worker_kind, service_kind } };
const call_result = mshl.resultShape(.any, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "spawn")) return .{ .params = &.{.{ .name = "handler", .shape = .function }}, .ret = worker_result };
    if (std.mem.eql(u8, name, "call")) return .{ .params = &.{ .{ .name = "worker", .shape = callable_kind }, .{ .name = "input", .optional = true } }, .input = .{ .optional = .any }, .ret = call_result };
    if (std.mem.eql(u8, name, "dispatch")) return .{ .params = &.{ .{ .name = "worker", .shape = worker_kind }, .{ .name = "input", .optional = true } }, .input = .{ .optional = .any }, .ret = call_result };
    if (std.mem.eql(u8, name, "await")) return .{ .params = &.{.{ .name = "worker", .shape = worker_kind }}, .input = .{ .optional = worker_kind }, .ret = call_result };
    if (std.mem.eql(u8, name, "race")) return .{ .params = &.{.{ .name = "workers", .shape = .list }}, .input = .{ .optional = .list }, .ret = worker_result };
    if (std.mem.eql(u8, name, "publish")) return .{ .params = &.{ .{ .name = "service", .shape = .int }, .{ .name = "worker", .shape = worker_kind } }, .ret = call_result };
    if (std.mem.eql(u8, name, "lookup")) return .{ .params = &.{ .{ .name = "node", .shape = .int }, .{ .name = "service", .shape = .int } }, .ret = service_result };
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
        // The worker (or a looked-up service) is the first argument; the
        // request is the piped input (`x | call $w`) or the second arg.
        if (args.len < 1) return it.fail("call: a worker expected", .{});
        const in_val: Value = if (input) |v| v else if (args.len > 1) args[1] else .nothing;
        if (!in_val.isData()) return it.fail("call: the input is a {s}, which cannot cross to a worker (only data can)", .{in_val.typeName()});
        if (args[0] == .handle and is(u8, args[0].handle.kind, "service")) {
            if (args[0].handle.closed) return it.fail("call: the service is closed", .{});
            const sv = svcSlot(args[0].handle.id) orelse return it.fail("call: the service is closed", .{});
            return try callService(it, sv, in_val);
        }
        const w = try workerArg(it, args[0]);
        return try callWorker(it, w, in_val);
    }
    if (is(u8, name, "dispatch")) {
        if (args.len < 1) return it.fail("dispatch: a worker expected", .{});
        const w = try workerArg(it, args[0]);
        const in_val: Value = if (input) |v| v else if (args.len > 1) args[1] else .nothing;
        if (!in_val.isData()) return it.fail("dispatch: the input is a {s}, which cannot cross to a worker (only data can)", .{in_val.typeName()});
        return try dispatchWorker(it, w, in_val);
    }
    if (is(u8, name, "await")) {
        const wv = input orelse (if (args.len > 0) args[0] else return it.fail("await: a worker expected", .{}));
        const w = try workerArg(it, wv);
        return try awaitWorker(it, w);
    }
    if (is(u8, name, "race")) {
        const lv = input orelse (if (args.len > 0) args[0] else return it.fail("race: a list of workers expected", .{}));
        if (lv != .list) return it.fail("race: a list of workers expected, got a {s}", .{lv.typeName()});
        return try raceWorkers(it, lv.list);
    }
    if (is(u8, name, "publish")) {
        if (fab_chan == 0) return it.fail("publish: this program has no fabric", .{});
        if (args.len < 2 or args[0] != .int) return it.fail("publish: SERVICE WORKER expected", .{});
        const id: u64 = @intCast(@max(args[0].int, 0));
        if (id >= shared.fab_max_services) return it.fail("publish: service id must be 0..{d}", .{shared.fab_max_services - 1});
        const w = try workerArg(it, args[1]);
        return try publishWorker(it, id, w);
    }
    if (is(u8, name, "lookup")) {
        if (fab_chan == 0) return it.fail("lookup: this program has no fabric", .{});
        if (args.len < 2 or args[0] != .int or args[1] != .int) return it.fail("lookup: NODE SERVICE expected", .{});
        const node: u64 = @intCast(@max(args[0].int, 0));
        const id: u64 = @intCast(@max(args[1].int, 0));
        if (id >= shared.fab_max_services) return it.fail("lookup: service id must be 0..{d}", .{shared.fab_max_services - 1});
        return try lookupService(it, node, id);
    }
    // close / status on a service handle.
    const hv = input orelse (if (args.len > 0) args[0] else return null);
    if (hv == .handle and is(u8, hv.handle.kind, "service")) {
        if (is(u8, name, "close")) {
            if (!hv.handle.closed) {
                closeService(hv.handle.id);
                it.closeHandle(hv);
            }
            return .nothing;
        }
        if (is(u8, name, "status")) {
            return .{ .str = if (hv.handle.closed or svcSlot(hv.handle.id) == null) "closed" else "alive" };
        }
        return null;
    }
    // close / status on a worker handle only.
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

/// Turn a worker's reply (its value/error in `buf`) into a result.
fn replyToValue(it: *mshl.Interp, buf: [*]u8, buf_len: usize, rep: shared.WorkResp) mshl.Error!Value {
    return switch (rep) {
        .value => |v| blk: {
            if (v.len == 0) break :blk try okResult(it, .nothing);
            if (v.len > buf_len) break :blk try errResult(it, "the worker's value overran the buffer");
            const text = try it.arena.dupe(u8, buf[0..v.len]);
            break :blk try okResult(it, try mshl.tableize(it.arena, try it.parseData(text)));
        },
        .failed => |e| try errResult(it, try it.arena.dupe(u8, buf[0..@min(e.len, buf_len)])),
        .refused => try errResult(it, "the worker refused"),
        .ok => try okResult(it, .nothing),
    };
}

/// Write the request into the worker's buffer; returns its length or an
/// error result if it does not fit.
fn loadRequest(it: *mshl.Interp, w: *Worker, in_val: Value) mshl.Error!union(enum) { len: usize, err: Value } {
    var in_text: std.ArrayList(u8) = .empty;
    if (in_val != .nothing) try mshl.writeData(in_val, it.arena, &in_text);
    if (in_text.items.len > w.buf_len) return .{ .err = try errResult(it, "the request is larger than the buffer") };
    @memcpy(w.buf[0..in_text.items.len], in_text.items);
    return .{ .len = in_text.items.len };
}

fn callWorker(it: *mshl.Interp, w: *Worker, in_val: Value) mshl.Error!Value {
    if (w.published) return try errResult(it, "the worker is published; reach it through lookup");
    if (w.pending) return try errResult(it, "the worker is running; await it first");
    const len = switch (try loadRequest(it, w, in_val)) {
        .len => |n| n,
        .err => |e| return e,
    };
    return switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .{ .call = .{ .len = len } }, 0)) {
        .ok => |rep| try replyToValue(it, w.buf, w.buf_len, rep),
        .err => try errResult(it, "the worker vanished"),
    };
}

/// Async dispatch: hand the worker its input and let it compute while we
/// go on. The worker acks at once; its result waits for `await`.
fn dispatchWorker(it: *mshl.Interp, w: *Worker, in_val: Value) mshl.Error!Value {
    if (w.published) return try errResult(it, "the worker is published; reach it through lookup");
    if (w.pending) return try errResult(it, "the worker is already running");
    ready_mask &= ~(@as(u64, 1) << w.bit); // a fresh run: forget any old bell
    const len = switch (try loadRequest(it, w, in_val)) {
        .len => |n| n,
        .err => |e| return e,
    };
    return switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .{ .dispatch = .{ .len = len } }, 0)) {
        .ok => |rep| switch (rep) {
            .ok => blk: {
                w.pending = true;
                break :blk try okResult(it, .nothing);
            },
            else => try errResult(it, "the worker refused the start"),
        },
        .err => try errResult(it, "the worker vanished"),
    };
}

/// Join a started worker for its result (blocks until it is done).
fn awaitWorker(it: *mshl.Interp, w: *Worker) mshl.Error!Value {
    if (!w.pending) return try errResult(it, "nothing to await: the worker was not started");
    // Consume this worker's doorbell bit before collecting — so `await`
    // and `select` both drain the bell, and a ring from this run can
    // never linger to make a later `race` on a reused slot fire early.
    // With no doorbell, `collect` itself blocks until the worker is done.
    if (doorbell != 0) {
        const wanted = @as(u64, 1) << w.bit;
        while (ready_mask & wanted == 0) {
            const r = usys.notifyWait(doorbell);
            if (r.err != .ok) break;
            ready_mask |= r.data[0];
        }
        ready_mask &= ~wanted;
    }
    w.pending = false;
    return switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .collect, 0)) {
        .ok => |rep| try replyToValue(it, w.buf, w.buf_len, rep),
        .err => try errResult(it, "the worker vanished"),
    };
}

/// Wait until the first of `items` (dispatched workers) finishes, and
/// return that worker handle — the caller `await`s it for the result.
/// Blocks on the shared doorbell; a worker not dispatched is skipped.
fn raceWorkers(it: *mshl.Interp, items: []const Value) mshl.Error!Value {
    // The bits we are waiting for: the dispatched workers among `items`.
    var wanted: u64 = 0;
    for (items) |v| {
        if (v != .handle or !std.mem.eql(u8, v.handle.kind, "worker") or v.handle.closed) continue;
        const w = slotOf(v.handle.id) orelse continue;
        if (w.pending) wanted |= @as(u64, 1) << w.bit;
    }
    if (wanted == 0) return try errResult(it, "race: none of these workers is running");
    if (doorbell == 0) return try errResult(it, "race: no doorbell");
    // Wait until at least one wanted worker has rung.
    while (ready_mask & wanted == 0) {
        const r = usys.notifyWait(doorbell);
        if (r.err != .ok) return try errResult(it, "race: the wait failed");
        ready_mask |= r.data[0];
    }
    // Return the first ready worker in the list's order.
    for (items) |v| {
        if (v != .handle or !std.mem.eql(u8, v.handle.kind, "worker") or v.handle.closed) continue;
        const w = slotOf(v.handle.id) orelse continue;
        if (w.pending and (ready_mask & (@as(u64, 1) << w.bit)) != 0) return try okResult(it, v);
    }
    return try errResult(it, "race: no worker became ready");
}

pub const command_names = [_][]const u8{ "spawn", "call", "dispatch", "await", "race", "publish", "lookup" };
