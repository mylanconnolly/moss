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
const netcmds = @import("netcmds.zig");
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
/// init's front channel, when the host holds one: `dial` reaches a
/// durable service unit through it (init starts and supervises it).
var init_chan: u64 = 0;

pub fn setup(spawner_cap: u64, load: LoadFn, view_chan: u64, view_buf: [*]u8, fabric: u64, init: u64) void {
    spawner = spawner_cap;
    loadStage = load;
    fs_chan = view_chan;
    fs_buf = view_buf;
    fab_chan = fabric;
    init_chan = init;
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

// ------------------------------ isolation helpers for other hosts ----
//
// A host (the GUI runtime) can run one of its own mshl functions in a
// worker domain for crash-isolation, without going through the `spawn`
// command: reconstruct the function as a script that reads `$in`, spawn
// it once, and `call` it per event. A crashed `call` comes back as
// `.crashed` (the domain died) so the host re-spawns and carries on —
// only data crosses, the same rule as `spawn`.

/// Whether this host can spawn workers at all (holds a spawner and a way
/// to stage the worker image).
pub fn canSpawn() bool {
    return spawner != 0 and loadStage != null;
}

/// Spawn a persistent worker running `handler_src` (a script reading
/// `$in`). Returns its Conn, or null if spawning failed. `close` tears
/// it down; the host owns it.
pub fn spawnBlock(it: *mshl.Interp, handler_src: []const u8) ?Conn {
    const stage_handle = loadStage.?(it) orelse return null;
    return switch (spawnWorker(stage_handle, handler_src)) {
        .conn => |c| c,
        .failed => null,
    };
}

/// The outcome of running a worker once, for a host that isolates its
/// own callback: `.value` is the handler's returned value, unwrapped (no
/// result envelope). `.raised` is the handler's own error (it ran but
/// failed — the worker is alive; its message is the value). `.crashed`
/// is a dead worker (its domain faulted, or refused the call) — the
/// caller should re-spawn. Both `.raised` and `.crashed` mean "the call
/// did not produce a value"; only `.crashed` needs a re-spawn.
pub const CallOut = union(enum) { value: Value, raised: Value, crashed };

/// Run a persistent worker once with `$in = in_val`, returning a
/// `CallOut`. Unlike `call`, this keeps the crash and the handler's own
/// error distinct, so a host can hold its last good state across either.
pub fn callConn(it: *mshl.Interp, c: Conn, in_val: Value) mshl.Error!CallOut {
    const w = slotOf(c) orelse return .crashed;
    if (w.pending) return .crashed;
    const len = switch (try loadRequest(it, w, in_val)) {
        .len => |n| n,
        .err => |e| return .{ .raised = e },
    };
    return switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .{ .call = .{ .len = len } }, 0)) {
        .ok => |rep| switch (rep) {
            // The handler's value as a data literal — parsed to the raw
            // value, not the ok/err envelope `replyToValue` builds.
            .value => |v| blk: {
                if (v.len == 0) break :blk .{ .value = .nothing };
                if (v.len > w.buf_len) break :blk .crashed;
                const text = try it.arena.dupe(u8, w.buf[0..v.len]);
                break :blk .{ .value = try mshl.tableize(it.arena, try it.parseData(text)) };
            },
            .ok => .{ .value = .nothing },
            .failed => |e| .{ .raised = .{ .str = try it.arena.dupe(u8, w.buf[0..@min(e.len, w.buf_len)]) } },
            .refused => .crashed,
        },
        .err => .crashed,
    };
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

// A signal: a notification this script waits on (`wait`), publishable to
// the pool so a peer can ring it by name (`notify NODE NAME`). The cap is
// shared — the script keeps waiting on it while a copy goes to fabsvc.
const max_signals = 8;
const Signal = struct { used: bool = false, gen: u32 = 0, notif: u64 = 0 };
var signals: [max_signals]Signal = @splat(.{});

fn sigId(idx: usize) u64 {
    return @as(u64, signals[idx].gen) << 8 | idx;
}
fn sigSlot(c: u64) ?*Signal {
    const idx: usize = @intCast(c & 0xff);
    if (idx >= max_signals) return null;
    const s = &signals[idx];
    if (!s.used or s.gen != c >> 8) return null;
    return s;
}
fn closeSignal(c: u64) void {
    const s = sigSlot(c) orelse return;
    if (s.notif != 0) _ = usys.capDrop(s.notif);
    s.used = false;
}
fn dropSignal(_: *anyopaque, _: []const u8, id: u64) void {
    closeSignal(id);
}
fn newSignalHandle(it: *mshl.Interp) mshl.Error!Value {
    var idx: usize = 0;
    while (idx < max_signals and signals[idx].used) idx += 1;
    if (idx == max_signals) return try errResult(it, "too many signals");
    const n = usys.notifyCreate();
    if (n.err != .ok) return try errResult(it, "the kernel gave no notification");
    const s = &signals[idx];
    s.* = .{ .used = true, .gen = s.gen +% 1, .notif = n.data[0] };
    return try okResult(it, try it.newHandle("signal", sigId(idx), &signals, dropSignal));
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
fn publishWorker(it: *mshl.Interp, name: []const u8, w: *Worker) mshl.Error!Value {
    if (w.published) return try errResult(it, "the worker is already published");
    if (w.pending) return try errResult(it, "the worker is running; await it first");
    const nw = shared.strToWords(name);
    return switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .{ .publish = .{ .a = nw[0], .b = nw[1] } }, w.chan)) {
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

/// Publish a signal to the pool under `name`: a copy of the notification
/// cap goes to fabsvc (we keep ours to `wait` on it), which rings it when
/// a peer `notify`s that name.
fn publishSignal(it: *mshl.Interp, name: []const u8, notif: u64) mshl.Error!Value {
    const nw = shared.strToWords(name);
    return switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .{ .publish_signal = .{ .a = nw[0], .b = nw[1] } }, notif)) {
        .ok => |rep| switch (rep) {
            .ok => try okResult(it, .nothing),
            .fab_err => |e| try errResult(it, fabErr(e.code)),
            else => try errResult(it, "the fabric gave an unexpected reply"),
        },
        .err => try errResult(it, "the fabric did not answer"),
    };
}

/// Ring the signal `node` published under `name`, carrying `bits`. Ok once
/// the fabric sent it (a reachable member); an err if not.
fn signalRemote(it: *mshl.Interp, node: u64, name: []const u8, bits: u64) mshl.Error!Value {
    const nw = shared.strToWords(name);
    return switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .{ .signal = .{ .a = nw[0], .b = nw[1], .node_bits = shared.packNodeBits(node, bits) } }, 0)) {
        .ok => |rep| switch (rep) {
            .ok => try okResult(it, .nothing),
            .fab_err => |e| try errResult(it, fabErr(e.code)),
            else => try errResult(it, "the fabric gave an unexpected reply"),
        },
        .err => try errResult(it, "the fabric did not answer"),
    };
}

/// Wrap a channel to a service (from lookup or dial) as a callable
/// `service` handle; drops the channel and errs if no slot is free.
fn newServiceHandle(it: *mshl.Interp, chan: u64) mshl.Error!Value {
    var idx: usize = 0;
    while (idx < max_services and services[idx].used) idx += 1;
    if (idx == max_services) {
        _ = usys.capDrop(chan);
        return try errResult(it, "too many services");
    }
    const sv = &services[idx];
    sv.* = .{ .used = true, .gen = sv.gen +% 1, .chan = chan };
    return try okResult(it, try it.newHandle("service", svcId(idx), &services, dropService));
}

/// Look up a published service on `node` and wrap the channel the fabric
/// hands back as a callable `service` handle.
fn lookupService(it: *mshl.Interp, node: u64, name: []const u8) mshl.Error!Value {
    const nw = shared.strToWords(name);
    return switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{ .lookup = .{ .node = node, .a = nw[0], .b = nw[1] } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .found => blk: {
                if (ok.cap == 0) break :blk try errResult(it, "the fabric handed back no channel");
                break :blk try newServiceHandle(it, ok.cap);
            },
            .fab_err => |e| try errResult(it, fabErr(e.code)),
            else => try errResult(it, "the fabric gave an unexpected reply"),
        },
        .err => try errResult(it, "the fabric did not answer"),
    };
}

/// Dial a durable service unit on another node through the fabric: the
/// peer's init starts and supervises it, and hands a channel back that
/// we wrap as a callable `service` handle — the same as a local dial,
/// only the node is elsewhere (transparent clustering).
fn remoteConnect(it: *mshl.Interp, node: u64, name: []const u8) mshl.Error!Value {
    const w = shared.strToWords(name);
    return switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{ .remote_connect = .{ .node = node, .a = w[0], .b = w[1] } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .found => blk: {
                if (ok.cap == 0) break :blk try errResult(it, "the fabric handed back no channel");
                break :blk try newServiceHandle(it, ok.cap);
            },
            .fab_err => |e| try errResult(it, fabErr(e.code)),
            else => try errResult(it, "the fabric gave an unexpected reply"),
        },
        .err => try errResult(it, "the fabric did not answer"),
    };
}

/// Dial a durable service unit through init: init starts it (or restarts
/// a stopped one) and supervises it, and hands back a channel we wrap as
/// a callable `service` handle. The service outlives us — it is init's.
fn dialService(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    const w = shared.strToWords(name);
    return switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_chan, .{ .connect_named = .{ .a = w[0], .b = w[1] } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .connected => blk: {
                if (ok.cap == 0) break :blk try errResult(it, "init handed back no channel");
                break :blk try newServiceHandle(it, ok.cap);
            },
            .failed => try errResult(it, "refused"),
            else => try errResult(it, "init gave an unexpected reply"),
        },
        .err => try errResult(it, "init did not answer"),
    };
}

/// Start (or restart) a unit through init and let go — fire-and-forget,
/// unlike `dial`, which keeps a callable handle. The desktop dock launches
/// GUI app units this way: init starts the unit, the unit's own
/// `{ tag: display, session: true }` give opens its surface on the
/// compositor, and the dock never needs to talk to it. The returned
/// channel is dropped (init supervises the unit; it is not ours). Returns
/// the unit name on success.
fn launchUnit(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    const w = shared.strToWords(name);
    return switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_chan, .{ .connect_named = .{ .a = w[0], .b = w[1] } }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .connected => blk: {
                if (ok.cap != 0) _ = usys.capDrop(ok.cap);
                break :blk try okResult(it, .{ .str = try it.arena.dupe(u8, name) });
            },
            .failed => try errResult(it, "refused"),
            else => try errResult(it, "init gave an unexpected reply"),
        },
        .err => try errResult(it, "init did not answer"),
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
const listener_kind: Shape = .{ .kind = "listener" };
const serve_result = mshl.resultShape(.int, .string);
const signal_kind: Shape = .{ .kind = "signal" };
const signal_result = mshl.resultShape(signal_kind, .string);
const publishable_kind: Shape = .{ .one_of = &.{ worker_kind, signal_kind } };

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "signal")) return .{ .ret = signal_result };
    if (std.mem.eql(u8, name, "wait")) return .{ .params = &.{.{ .name = "signal", .shape = signal_kind, .optional = true }}, .input = .{ .optional = signal_kind }, .ret = .int };
    if (std.mem.eql(u8, name, "notify")) return .{ .params = &.{ .{ .name = "node", .shape = .int }, .{ .name = "name", .shape = .string }, .{ .name = "bits", .shape = .int, .optional = true } }, .ret = call_result };
    if (std.mem.eql(u8, name, "spawn")) return .{ .params = &.{.{ .name = "handler", .shape = .function }}, .ret = worker_result };
    if (std.mem.eql(u8, name, "serve")) return .{ .params = &.{ .{ .name = "listener", .shape = listener_kind }, .{ .name = "handler", .shape = .function }, .{ .name = "count", .shape = .int, .optional = true } }, .ret = serve_result };
    if (std.mem.eql(u8, name, "call")) return .{ .params = &.{ .{ .name = "worker", .shape = callable_kind }, .{ .name = "input", .optional = true } }, .input = .{ .optional = .any }, .ret = call_result };
    if (std.mem.eql(u8, name, "dispatch")) return .{ .params = &.{ .{ .name = "worker", .shape = worker_kind }, .{ .name = "input", .optional = true } }, .input = .{ .optional = .any }, .ret = call_result };
    if (std.mem.eql(u8, name, "await")) return .{ .params = &.{.{ .name = "worker", .shape = worker_kind }}, .input = .{ .optional = worker_kind }, .ret = call_result };
    if (std.mem.eql(u8, name, "race")) return .{ .params = &.{.{ .name = "workers", .shape = .list }}, .input = .{ .optional = .list }, .ret = worker_result };
    if (std.mem.eql(u8, name, "publish")) return .{ .params = &.{ .{ .name = "name", .shape = .string }, .{ .name = "target", .shape = publishable_kind } }, .ret = call_result };
    if (std.mem.eql(u8, name, "lookup")) return .{ .params = &.{ .{ .name = "node", .shape = .int }, .{ .name = "name", .shape = .string } }, .ret = service_result };
    if (std.mem.eql(u8, name, "dial")) return .{ .params = &.{ .{ .name = "node_or_name", .shape = .{ .one_of = &.{ .string, .int } } }, .{ .name = "name", .shape = .string, .optional = true } }, .ret = service_result };
    if (std.mem.eql(u8, name, "launch")) return .{ .params = &.{.{ .name = "unit", .shape = .string }}, .ret = call_result };
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
    if (is(u8, name, "serve")) {
        if (spawner == 0 or loadStage == null) return it.fail("serve: this program cannot spawn workers (no spawner)", .{});
        if (args.len < 2) return it.fail("serve: a listener and a handler expected", .{});
        if (args[0] != .handle or !is(u8, args[0].handle.kind, "listener")) return it.fail("serve: a listener expected, got a {s}", .{args[0].typeName()});
        if (args[0].handle.closed) return it.fail("serve: the listener is closed", .{});
        const src = switch (args[1]) {
            .func => |cl| cl.src,
            else => return it.fail("serve: a handler block expected, got a {s}", .{args[1].typeName()}),
        };
        var count: ?i64 = null;
        if (args.len > 2) {
            if (args[2] != .int or args[2].int < 1) return it.fail("serve: the count must be a positive int", .{});
            count = args[2].int;
        }
        const n: *netcmds.Net = @ptrCast(@alignCast(args[0].handle.ctx));
        return try poolServe(it, n, args[0].handle.id, src, count);
    }
    if (is(u8, name, "call")) {
        // The worker (or a looked-up service) is the first argument; the
        // request is the piped input (`x | call $w`) or the second arg.
        if (args.len < 1) return it.fail("call: a worker expected", .{});
        const in_val: Value = if (input) |v| v else if (args.len > 1) args[1] else .nothing;
        // A socket handed to a worker: it crosses (handed off), the rest
        // is the worker serving the connection.
        if (in_val == .handle and is(u8, in_val.handle.kind, "socket") and !in_val.handle.closed and args[0] == .handle and is(u8, args[0].handle.kind, "worker")) {
            const w = try workerArg(it, args[0]);
            return try callServeSocket(it, w, in_val);
        }
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
        // A socket dispatched to a worker: it serves the connection while
        // we go on (concurrent serve, reaped by await/race).
        if (in_val == .handle and is(u8, in_val.handle.kind, "socket") and !in_val.handle.closed) {
            return try dispatchServeSocket(it, w, in_val);
        }
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
    if (is(u8, name, "signal")) {
        return try newSignalHandle(it);
    }
    if (is(u8, name, "wait")) {
        const hv = input orelse (if (args.len > 0) args[0] else return it.fail("wait: a signal expected", .{}));
        if (hv != .handle or !is(u8, hv.handle.kind, "signal")) return it.fail("wait: a signal expected, got a {s}", .{hv.typeName()});
        const s = sigSlot(hv.handle.id) orelse return it.fail("wait: this signal is closed", .{});
        const w = usys.notifyWait(s.notif);
        if (w.err != .ok) return it.fail("wait: the notification failed", .{});
        return .{ .int = @intCast(w.data[0]) };
    }
    if (is(u8, name, "notify")) {
        if (fab_chan == 0) return it.fail("notify: this program has no fabric", .{});
        if (args.len < 2 or args[0] != .int or args[1] != .str) return it.fail("notify: NODE NAME [BITS] expected", .{});
        if (args[1].str.len == 0 or args[1].str.len > 16) return it.fail("notify: a signal name is 1..16 bytes", .{});
        const node: u64 = @intCast(@max(args[0].int, 0));
        const bits: u64 = if (args.len >= 3 and args[2] == .int) @intCast(@max(args[2].int, 0)) else 1;
        return try signalRemote(it, node, args[1].str, bits);
    }
    if (is(u8, name, "publish")) {
        if (fab_chan == 0) return it.fail("publish: this program has no fabric", .{});
        if (args.len < 2 or args[0] != .str) return it.fail("publish: NAME WORKER|SIGNAL expected", .{});
        if (args[0].str.len == 0 or args[0].str.len > 16) return it.fail("publish: a service name is 1..16 bytes", .{});
        // A signal handle publishes as a signal export; a worker as a
        // callable service.
        if (args[1] == .handle and is(u8, args[1].handle.kind, "signal")) {
            const s = sigSlot(args[1].handle.id) orelse return it.fail("publish: this signal is closed", .{});
            return try publishSignal(it, args[0].str, s.notif);
        }
        const w = try workerArg(it, args[1]);
        return try publishWorker(it, args[0].str, w);
    }
    if (is(u8, name, "lookup")) {
        if (fab_chan == 0) return it.fail("lookup: this program has no fabric", .{});
        if (args.len < 2 or args[0] != .int or args[1] != .str) return it.fail("lookup: NODE NAME expected", .{});
        const node: u64 = @intCast(@max(args[0].int, 0));
        if (args[1].str.len == 0 or args[1].str.len > 16) return it.fail("lookup: a service name is 1..16 bytes", .{});
        return try lookupService(it, node, args[1].str);
    }
    if (is(u8, name, "dial")) {
        if (args.len == 0) return it.fail("dial: a service name (or NODE NAME) expected", .{});
        if (args.len >= 2) {
            // dial NODE NAME: reach a durable service unit on another node
            // through the fabric — its init starts and supervises it.
            if (fab_chan == 0) return it.fail("dial: this program has no fabric", .{});
            if (args[0] != .int or args[1] != .str) return it.fail("dial: NODE NAME expected", .{});
            const node: u64 = @intCast(@max(args[0].int, 0));
            if (args[1].str.len > 16) return it.fail("dial: a service name is at most 16 bytes", .{});
            return try remoteConnect(it, node, args[1].str);
        }
        if (init_chan == 0) return it.fail("dial: this program cannot reach init", .{});
        if (args[0] != .str) return it.fail("dial: a service name expected, got a {s}", .{args[0].typeName()});
        if (args[0].str.len > 16) return it.fail("dial: a service name is at most 16 bytes", .{});
        return try dialService(it, args[0].str);
    }
    if (is(u8, name, "launch")) {
        if (init_chan == 0) return it.fail("launch: this program cannot reach init", .{});
        if (args.len == 0 or args[0] != .str) return it.fail("launch: a unit name expected", .{});
        if (args[0].str.len == 0 or args[0].str.len > 16) return it.fail("launch: a unit name is 1..16 bytes", .{});
        return try launchUnit(it, args[0].str);
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

/// Hand a connected socket to a worker and run its handler with `$in`
/// the socket. netsvc moves the socket to a fresh net view; that view's
/// cap goes to the worker (attach_net), and the worker serves the socket
/// by its number. The socket is consumed here — the caller's handle no
/// longer owns it.
/// Hand a socket to a worker and set it serving (async): hand off the
/// socket, give the worker the resulting net view, and send `serve` —
/// the worker acks, runs its handler on the socket, and rings the
/// doorbell when done, so many connections serve at once. Returns an
/// error result on failure, or null on success (the worker is pending).
fn startServe(it: *mshl.Interp, w: *Worker, sv: Value) mshl.Error!?Value {
    const n: *netcmds.Net = @ptrCast(@alignCast(sv.handle.ctx));
    if (startServeRaw(w, n, sv.handle.id)) |m| return try errResult(it, m);
    it.closeHandle(sv); // the socket moved; our handle no longer owns it
    return null;
}

/// The core of `startServe`, working on a raw socket number on view `n`
/// rather than a socket Value — the built-in `serve` uses it directly so
/// its accept loop makes no per-connection interpreter handle. Returns an
/// error message on failure, or null on success (the worker is pending).
fn startServeRaw(w: *Worker, n: *netcmds.Net, id: u64) ?[]const u8 {
    if (w.published) return "the worker is published; reach it through lookup";
    if (w.pending) return "the worker is already running";
    const cap = netcmds.handoff(n, id) orelse return "the socket could not be handed off";
    switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .attach_net, cap)) {
        .ok => |rep| if (rep != .ok) {
            _ = usys.capDrop(cap);
            return "the worker refused the net view";
        },
        .err => {
            _ = usys.capDrop(cap);
            return "the worker vanished";
        },
    }
    _ = usys.capDrop(cap); // the worker holds its own ref now
    ready_mask &= ~(@as(u64, 1) << w.bit); // a fresh run
    switch (usys.callTyped(shared.WorkReq, shared.WorkResp, w.chan, .{ .serve = .{ .idx = id } }, 0)) {
        .ok => |rep| if (rep != .ok) return "the worker refused to serve",
        .err => return "the worker vanished",
    }
    w.pending = true;
    return null;
}

/// `socket | call $w`: serve the connection and wait for the handler's
/// value (synchronous).
fn callServeSocket(it: *mshl.Interp, w: *Worker, sv: Value) mshl.Error!Value {
    if (try startServe(it, w, sv)) |e| return e;
    return try awaitWorker(it, w);
}

/// `socket | dispatch $w`: serve the connection and go on — `await`/
/// `race` reaps the worker when it finishes (concurrent serve).
fn dispatchServeSocket(it: *mshl.Interp, w: *Worker, sv: Value) mshl.Error!Value {
    if (try startServe(it, w, sv)) |e| return e;
    return try okResult(it, .nothing);
}

// -------------------------------------------------- built-in serve pool
//
// `serve $listener { handler } [count]` is the concurrent-serve script
// pattern made a command: accept connections and hand each to a fresh
// worker running the handler block (with `$in` the socket), up to
// `max_workers` serving at once. When the pool is full the accept loop
// waits on the doorbell for one worker to finish and reaps it (its
// domain torn down, its value discarded) before taking the next; at the
// end every worker still serving is drained. A worker attaches exactly
// one net view — the handed-off socket's, torn down with its domain — so
// there is no per-connection view leak; the pool bounds concurrency.

fn removeInflight(inflight: []Conn, n_inflight: *usize, i: usize) void {
    n_inflight.* -= 1;
    inflight[i] = inflight[n_inflight.*]; // swap-remove; order does not matter
}

/// Wait on the doorbell until one in-flight worker has finished serving
/// (its handler returned, so its response is already sent), then tear it
/// down and drop it from the list. Requires `n_inflight.* > 0`.
fn reapOneServe(inflight: []Conn, n_inflight: *usize) void {
    var wanted: u64 = 0;
    for (inflight[0..n_inflight.*]) |c| {
        if (slotOf(c)) |w| if (w.pending) {
            wanted |= @as(u64, 1) << w.bit;
        };
    }
    if (wanted != 0 and doorbell != 0) {
        while (ready_mask & wanted == 0) {
            const r = usys.notifyWait(doorbell);
            if (r.err != .ok) break;
            ready_mask |= r.data[0];
        }
    }
    // Reap the first ready worker (with no doorbell, or a failed wait,
    // the first worker — it is done or gone either way).
    var i: usize = 0;
    while (i < n_inflight.*) : (i += 1) {
        const w = slotOf(inflight[i]) orelse {
            removeInflight(inflight, n_inflight, i);
            return;
        };
        if (doorbell == 0 or (ready_mask & (@as(u64, 1) << w.bit)) != 0) {
            ready_mask &= ~(@as(u64, 1) << w.bit);
            close(inflight[i]);
            removeInflight(inflight, n_inflight, i);
            return;
        }
    }
    // A successful wait always flags one of the wanted bits, so this is a
    // safety net: reap the first to avoid stalling.
    close(inflight[0]);
    removeInflight(inflight, n_inflight, 0);
}

fn drainServe(inflight: []Conn, n_inflight: *usize) void {
    while (n_inflight.* > 0) reapOneServe(inflight, n_inflight);
}

/// The built-in `serve`: accept on listener `l` (view `n`) and hand each
/// connection to a worker running `src`, up to `max_workers` at once.
/// Returns the number of connections served (an int result), or an error
/// result if accept fails or no worker can be had for the first one.
fn poolServe(it: *mshl.Interp, n: *netcmds.Net, l: u64, src: []const u8, count: ?i64) mshl.Error!Value {
    const stage = loadStage.?(it) orelse return try errResult(it, "unreadable");
    var inflight: [max_workers]Conn = undefined;
    var n_inflight: usize = 0;
    var served: i64 = 0;
    while (count == null or served < count.?) {
        const id = switch (n.acceptRaw(l)) {
            .sock => |s| s,
            .failed => |m| {
                drainServe(&inflight, &n_inflight);
                return try errResult(it, m);
            },
        };
        // A worker for this connection: a fresh spawn, reaping one of ours
        // if every worker slot is taken (the pool is full).
        var out = spawnWorker(stage, src);
        if (out == .failed and std.mem.eql(u8, out.failed, "too_many")) {
            if (n_inflight == 0) {
                n.closeRaw(id); // no worker to serve it, and none to reap
                return try errResult(it, "serve: no worker slots are free");
            }
            reapOneServe(&inflight, &n_inflight);
            out = spawnWorker(stage, src);
        }
        const conn = switch (out) {
            .conn => |c| c,
            .failed => |m| {
                n.closeRaw(id);
                drainServe(&inflight, &n_inflight);
                return try errResult(it, m);
            },
        };
        const w = slotOf(conn).?;
        if (startServeRaw(w, n, id)) |_| {
            // This one connection could not be handed off; drop it and its
            // worker and keep serving — one client's failure is not the
            // server's. (If the socket moved, closeRaw here is a no-op.)
            close(conn);
            n.closeRaw(id);
            continue;
        }
        inflight[n_inflight] = conn;
        n_inflight += 1;
        served += 1;
    }
    drainServe(&inflight, &n_inflight);
    return try okResult(it, .{ .int = served });
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

pub const command_names = [_][]const u8{ "spawn", "serve", "call", "dispatch", "await", "race", "publish", "lookup", "dial", "launch", "signal", "wait", "notify" };
