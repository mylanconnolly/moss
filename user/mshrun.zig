//! mshrun — a script as a program. Runs the mshl script named by its
//! argument, read through the one view it was handed, with the shared
//! file commands as its host and nothing else: a script has exactly the
//! authority its manifest or unit file gives it. Under msh (`run mshrun
//! PATH`) it has the console and hands its last value back through
//! `out`; as a unit it logs what it renders and exits — 0, or 1 with
//! the error on the log. Spawned by the fabric (arg 1) it is a REMOTE
//! STAGE: it serves RunReq on the channel it was born with — a script
//! and its input arrive in an attached buffer, the value goes back the
//! same way — answers once, and exits.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const fscmds = @import("fscmds.zig");
const netcmds = @import("netcmds.zig");
const httpcmds = @import("httpcmds.zig");
const tlscmds = @import("tlscmds.zig");
const fabcmds = @import("fabcmds.zig");
const workcmds = @import("workcmds.zig");
const loader = @import("loader.zig");
const progload = @import("progload.zig");
const syscmds = @import("syscmds.zig");
const tty = @import("tty.zig");
const boot = @import("boot.zig");
const result = @import("result.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;

comptime {
    asm (usys.imageHeader("mshrun"));
}

pub const panic = std.debug.FullPanic(uPanic);

/// A panic says what it was on the log before the exit: a silent 255
/// from an essential unit reads as a hang from the console.
fn uPanic(msg: []const u8, _: ?usize) noreturn {
    var buf: [200]u8 = undefined;
    const pre = "panic: ";
    @memcpy(buf[0..pre.len], pre);
    const n = @min(msg.len, buf.len - pre.len);
    @memcpy(buf[pre.len .. pre.len + n], msg[0..n]);
    _ = usys.log(glog, buf[0 .. pre.len + n]);
    usys.exit(255);
}

var glog: u64 = 0;
var view_chan: u64 = 0;
var view_buf: [*]u8 = undefined;
/// When this script was granted a spawner, the stage its `spawn`
/// workers are loaded into, and the spawner slot (slot 2, insert order
/// log->chan->spawner). 0 = not granted: `spawn` is refused.
var run_stage: loader.Stage = undefined;
var worker_spawner: u64 = 0;
var has_console = false;

// The interpreter's memory: an arena for the whole run (a script is one
// evaluation, statement by statement) and a pool for what it binds.
var heap_line: [1 << 20]u8 = undefined;
var line_fba: std.heap.FixedBufferAllocator = undefined;
var box_pool: mosslib.pool.Pool(256, 2048) = .{};
var host_ctx: u8 = 0;
var fs_ctx = fscmds.Fs{ .resolve = resolve, .root = 0 };
/// The stores `use NAME` reads a module from: `img/` in the view when
/// there is one, and the system store when the manifest gives it.
var stores: [2]?fscmds.Store = .{ null, null };
var net: ?netcmds.Net = null;
var fab: ?fabcmds.Fab = null;
/// The boot archive, when the manifest grants `bootfs`: scripts may be
/// read from it (a unit's `script:` path) even with no view at all.
var blob: []const u8 = "";

fn resolve(it: *mshl.Interp, path: []const u8) mshl.Error!fscmds.Target {
    if (view_chan == 0) return it.fail("no filesystem view was given to this script", .{});
    return .{ .chan = view_chan, .buf = view_buf, .path = path };
}

fn hostSignature(_: *anyopaque, name: []const u8) ?mshl.Signature {
    if (fscmds.signature(name)) |sig| return sig;
    if (worker_spawner != 0) {
        if (workcmds.signature(name)) |sig| return sig;
    }
    if (net != null) {
        if (tlscmds.signature(name)) |sig| return sig;
        if (netcmds.signature(name)) |sig| return sig;
        if (httpcmds.signature(name)) |sig| return sig;
    }
    if (fab != null) {
        if (fabcmds.signature(name)) |sig| return sig;
    }
    return syscmds.signature(name);
}

fn hostCall(_: *anyopaque, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (try fscmds.call(&fs_ctx, it, name, args, input)) |v| return v;
    if (worker_spawner != 0) {
        if (try workcmds.call(it, name, args, input)) |v| return v;
    }
    if (net) |*nt| {
        // tls first: it answers for the socket commands on its own handles.
        if (try tlscmds.call(nt, it, name, args, input)) |v| return v;
        if (try netcmds.call(nt, it, name, args, input)) |v| return v;
        if (try httpcmds.call(nt, it, name, args, input)) |v| return v;
    }
    if (fab) |*fb| {
        if (try fabcmds.call(fb, it, name, args, input)) |v| return v;
    }
    if (try syscmds.call(it, name, args)) |v| return v;
    return null;
}

/// Rendered text goes to the console when there is one, else to the
/// log a line at a time.
fn emit(text: []const u8) void {
    if (has_console) {
        for (text) |c| {
            if (c == '\n') tty.out("\r\n") else tty.out(&[_]u8{c});
        }
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var buf: [256]u8 = undefined;
        const pre = "mshrun: ";
        @memcpy(buf[0..pre.len], pre);
        const n = @min(line.len, buf.len - pre.len);
        @memcpy(buf[pre.len .. pre.len + n], line[0..n]);
        _ = usys.log(glog, buf[0 .. pre.len + n]);
    }
}

fn fail(what: []const u8, msg: []const u8) noreturn {
    var buf: [320]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ "mshrun: ", what, ": ", msg }) |part| {
        const k = @min(part.len, buf.len - n);
        @memcpy(buf[n .. n + k], part[0..k]);
        n += k;
    }
    if (has_console) {
        tty.out(buf[0..n]);
        tty.out("\r\n");
    } else _ = usys.log(glog, buf[0..n]);
    usys.exit(1);
}

/// Load the mshrun image into the run stage for a `spawn` worker (the
/// worker is mshrun in its serving mode) — from this script's own
/// stores, verified. null on any failure; workcmds turns that into the
/// `spawn` result's err.
fn loadWorkerStage(it: *mshl.Interp) ?u64 {
    return progload.loadImage(it, "mshrun", &stores, &run_stage);
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    if (blob_va != 0) blob = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    if (arg == 1) serveRemote(chan_h);
    if (arg == 2) serveWorker(chan_h);
    const setup = boot.take(chan_h);
    has_console = setup.has(.console) and setup.has(.console_buf);
    if (has_console) tty.attach(&setup);
    if (setup.has(.view)) {
        view_chan = setup.cap(.view);
        view_buf = @ptrFromInt(fsc.attachBuf(view_chan).va);
        fs_ctx.root = view_chan;
        if (fsc.fsDerive(view_chan, view_buf, "img", true)) |own| {
            stores[0] = .{ .chan = own, .buf = @ptrFromInt(fsc.attachBuf(own).va), .name = "your store" };
        }
    }
    if (setup.has(.store)) {
        const st = setup.cap(.store);
        stores[1] = .{ .chan = st, .buf = @ptrFromInt(fsc.attachBuf(st).va), .name = "the system store" };
    }
    fs_ctx.stores = &stores;
    // A spawner lands at slot 2 (grant insert order log->chan->spawner);
    // we cannot read our own grants, so probe it — a spawn-gated read
    // that answers only for a real spawner. With one, a script may
    // offload work: `spawn { handler }` and `x | call $w`, workers being
    // mshrun in its serving mode, staged from our own stores.
    {
        const spawner_slot: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });
        if (usys.sysInfo(spawner_slot).err == .ok) {
            run_stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(148);
            worker_spawner = spawner_slot;
            workcmds.setup(worker_spawner, loadWorkerStage, view_chan, view_buf, if (setup.has(.fabric)) setup.cap(.fabric) else 0);
        }
    }
    if (setup.has(.net)) net = netcmds.Net.init(setup.cap(.net));
    if (view_chan != 0) tlscmds.setRootsView(view_chan, view_buf);
    tlscmds.setIdentity(setup.file(.cert) orelse "", setup.secret());
    if (setup.has(.fabric)) fab = .{ .chan = setup.cap(.fabric) };
    const path = setup.arg();
    if (path.len == 0) fail("setup", "no script path given");

    line_fba = std.heap.FixedBufferAllocator.init(&heap_line);
    var interp = mshl.Interp.init(line_fba.allocator(), box_pool.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = hostCall, .signature = hostSignature });
    // The script: from the boot archive when it is granted and holds the
    // path (a drill's script is an archive path, even when the unit also
    // has a filesystem view for its data), else from the view.
    const text = if (blob.len != 0 and shared.marcFind(blob, path) != null)
        shared.marcFind(blob, path).?
    else if (view_chan != 0)
        fscmds.readFile(&fs_ctx, &interp, path) catch fail(path, interp.err_msg)
    else
        shared.marcFind(blob, path) orelse fail(path, "not in the boot archive (and no view was given)");

    // Every top-level statement's value is rendered as the prompt would
    // — for a human (the console, or the log). Given an `out`, the last
    // statement's value is the program's and the text is not made: a
    // program run by msh returns a value, like ls and ps.
    var out: std.ArrayList(u8) = .empty;
    const last = interp.evalScriptEach(text, &out, if (setup.has(.out)) null else emit) catch |e| {
        fail(path, switch (e) {
            error.OutOfMemory => "out of memory",
            error.Exit => "exit",
            else => interp.err_msg,
        });
    };
    if (setup.has(.out)) {
        var res = result.Result.init();
        if (last.isData() and !res.deliver(&setup, last)) fail(path, "the result does not fit the out buffer");
    }
    usys.exit(0);
}

/// The remote stage: serve one `run` on the channel the fabric spawned
/// us with. The buffer arrives with attach_buf (the fabric's twin of
/// the caller's); the script is buf[0..script_len], the input a data
/// literal after it; the value — data only — is written back at buf[0].
fn serveRemote(chan_h: u64) noreturn {
    var buf: ?[*]u8 = null;
    var buf_len: usize = 0;
    _ = usys.log(glog, "mshrun: remote stage up");
    line_fba = std.heap.FixedBufferAllocator.init(&heap_line);
    var interp = mshl.Interp.init(line_fba.allocator(), box_pool.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = hostCall, .signature = hostSignature });
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(2);
        const req = shared.decodeMsg(shared.RunReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.log(glog, "mshrun: remote stage: a message that is not a RunReq; refused");
            _ = usys.replyTyped(shared.RunResp, chan_h, .refused, 0);
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap == 0) {
                    _ = usys.log(glog, "mshrun: remote stage: attach_buf without a buffer; refused");
                    _ = usys.replyTyped(shared.RunResp, chan_h, .refused, 0);
                    continue;
                }
                const m = usys.shmMap(r.cap);
                _ = usys.capDrop(r.cap);
                if (m.err != .ok) {
                    var l: [64]u8 = undefined;
                    _ = usys.log(glog, std.fmt.bufPrint(&l, "mshrun: remote stage: cannot map the buffer ({t}); refused", .{m.err}) catch "mshrun: cannot map");
                    _ = usys.replyTyped(shared.RunResp, chan_h, .refused, 0);
                    continue;
                }
                buf = @ptrFromInt(m.data[0]);
                buf_len = m.data[1] * 4096;
                _ = usys.replyTyped(shared.RunResp, chan_h, .ok, 0);
            },
            .run => |q| {
                const b = buf orelse {
                    _ = usys.replyTyped(shared.RunResp, chan_h, .refused, 0);
                    continue;
                };
                if (q.script_len + q.input_len > buf_len) {
                    _ = usys.replyTyped(shared.RunResp, chan_h, .refused, 0);
                    continue;
                }
                line_fba.reset();
                const script = line_fba.allocator().dupe(u8, b[0..q.script_len]) catch usys.exit(3);
                const in_text = line_fba.allocator().dupe(u8, b[q.script_len .. q.script_len + q.input_len]) catch usys.exit(3);
                const outcome = runStage(&interp, script, in_text);
                const text = switch (outcome) {
                    .value => |t| t,
                    .failed => |t| t,
                };
                const n = @min(text.len, buf_len);
                @memcpy(b[0..n], text[0..n]);
                _ = usys.replyTyped(shared.RunResp, chan_h, switch (outcome) {
                    .value => .{ .value = .{ .len = n } },
                    .failed => .{ .failed = .{ .len = n } },
                }, 0);
                usys.exit(0); // one stage, one answer
            },
        }
    }
}

/// The worker stage: `spawn { handler }` in another domain. The buffer
/// arrives with attach_buf, the handler's source once, then each `call`
/// runs the handler with `$in` = the request and writes its value back.
/// The handler body is an ordinary script that reads `$in`, so every
/// call reuses `runStage`; a fresh interpreter per call keeps no state
/// between them. The worker loops until the channel closes (the caller
/// dropped or closed the handle) and then exits — no orphan.
var handler_src: [8 << 10]u8 = undefined;
var handler_len: usize = 0;

fn serveWorker(chan_h: u64) noreturn {
    var buf: ?[*]u8 = null;
    var buf_len: usize = 0;
    // An async `start` computes now and stashes its result in the buffer
    // for the next `collect`; these remember it across the two messages.
    var stashed = false;
    var stash_len: usize = 0;
    var stash_failed = false;
    // The doorbell (a notification the caller holds) and this worker's
    // bit in it: rung when a dispatch finishes, so a `select` wakes.
    var bell: u64 = 0;
    var bell_bit: u6 = 0;
    _ = usys.log(glog, "mshrun: worker up");
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(2);
        const req = shared.decodeMsg(shared.WorkReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap == 0) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                const m = usys.shmMap(r.cap);
                _ = usys.capDrop(r.cap);
                if (m.err != .ok) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                buf = @ptrFromInt(m.data[0]);
                buf_len = m.data[1] * 4096;
                _ = usys.replyTyped(shared.WorkResp, chan_h, .ok, 0);
            },
            .attach_view => {
                if (r.cap == 0) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                view_chan = r.cap;
                view_buf = @ptrFromInt(fsc.attachBuf(view_chan).va);
                fs_ctx.root = view_chan;
                if (fsc.fsDerive(view_chan, view_buf, "img", true)) |own| {
                    stores[0] = .{ .chan = own, .buf = @ptrFromInt(fsc.attachBuf(own).va), .name = "your store" };
                }
                fs_ctx.stores = &stores;
                _ = usys.replyTyped(shared.WorkResp, chan_h, .ok, 0);
            },
            .attach_bell => |q| {
                if (r.cap == 0) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                bell = r.cap;
                bell_bit = @intCast(q.bit & 63);
                _ = usys.replyTyped(shared.WorkResp, chan_h, .ok, 0);
            },
            .handler => |q| {
                const b = buf orelse {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                };
                if (q.len > handler_src.len or q.len > buf_len) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                @memcpy(handler_src[0..q.len], b[0..q.len]);
                handler_len = q.len;
                _ = usys.replyTyped(shared.WorkResp, chan_h, .ok, 0);
            },
            .call => |q| {
                const b = buf orelse {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                };
                if (q.len > buf_len) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                const r2 = runJob(b, q.len, buf_len);
                _ = usys.replyTyped(shared.WorkResp, chan_h, if (r2.failed)
                    .{ .failed = .{ .len = r2.len } }
                else
                    .{ .value = .{ .len = r2.len } }, 0);
            },
            .dispatch => |q| {
                const b = buf orelse {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                };
                // One unclaimed result at a time; the caller collects before
                // starting again.
                if (stashed or q.len > buf_len) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                // Accept NOW, before running the handler, so the caller does
                // not block on the work — it goes on to start other workers
                // while this one computes. The result waits for `collect`.
                _ = usys.replyTyped(shared.WorkResp, chan_h, .ok, 0);
                const r2 = runJob(b, q.len, buf_len);
                stash_len = r2.len;
                stash_failed = r2.failed;
                stashed = true;
                // Ring the doorbell: a `select` waiting on this worker wakes.
                if (bell != 0) _ = usys.notifySignal(bell, @as(u64, 1) << bell_bit);
            },
            .collect => {
                if (!stashed) {
                    _ = usys.replyTyped(shared.WorkResp, chan_h, .refused, 0);
                    continue;
                }
                stashed = false;
                _ = usys.replyTyped(shared.WorkResp, chan_h, if (stash_failed)
                    .{ .failed = .{ .len = stash_len } }
                else
                    .{ .value = .{ .len = stash_len } }, 0);
            },
        }
    }
}

const StageOut = union(enum) { value: []const u8, failed: []const u8 };

/// Run a worker's handler on one request. Unlike the remote stage, the
/// handler runs as a function (its source wrapped in `fn { … }`) called
/// with the request as `$in`, so a `?` inside propagates out as the
/// handler's failure carrying the err's own value — `(err "boom")?`
/// answers the call `err boom`, not a top-level "unhandled err".
/// Run the handler on the request in `b[0..in_len]` and write its value
/// (a data literal, or the error text) back to `b`, returning its length
/// and whether it failed. A fresh interpreter per job keeps no state
/// between calls. Shared by `call` (sync) and `start` (async).
fn runJob(b: [*]u8, in_len: usize, buf_len: usize) struct { len: usize, failed: bool } {
    line_fba = std.heap.FixedBufferAllocator.init(&heap_line);
    const in_text = line_fba.allocator().dupe(u8, b[0..in_len]) catch usys.exit(3);
    var interp = mshl.Interp.init(line_fba.allocator(), box_pool.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = hostCall, .signature = hostSignature });
    const outcome = runHandler(&interp, handler_src[0..handler_len], in_text);
    const text = switch (outcome) {
        .value => |t| t,
        .failed => |t| t,
    };
    const n = @min(text.len, buf_len);
    @memcpy(b[0..n], text[0..n]);
    return .{ .len = n, .failed = outcome == .failed };
}

fn runHandler(it: *mshl.Interp, src: []const u8, in_text: []const u8) StageOut {
    const in_val: Value = if (in_text.len == 0) .nothing else (it.parseData(in_text) catch return .{ .failed = "the input is not data" });
    const tin = mshl.tableize(it.arena, in_val) catch return .{ .failed = "out of memory" };
    var wrapped: [handler_src.len + 8]u8 = undefined;
    if (src.len + 6 > wrapped.len) return .{ .failed = "the handler is too large" };
    @memcpy(wrapped[0..4], "fn {");
    @memcpy(wrapped[4 .. 4 + src.len], src);
    wrapped[4 + src.len] = '}';
    const fn_val = it.evalSource(wrapped[0 .. 5 + src.len]) catch return .{ .failed = "the handler does not parse" };
    var val = it.callValue(fn_val, &.{}, tin, null) catch |e| return .{ .failed = switch (e) {
        error.OutOfMemory => "out of memory",
        error.Exit => "exit",
        else => it.err_msg,
    } };
    // A `?` inside the handler returns the err from the function, so the
    // handler's value can be a result: an err is the call's failure (its
    // own value, not "unhandled"), an ok is unwrapped to its value.
    if (val == .result) {
        if (!val.result.ok) {
            var msg: std.ArrayList(u8) = .empty;
            mshl.renderInline(val.result.val, it.arena, &msg) catch return .{ .failed = "out of memory" };
            return .{ .failed = msg.items };
        }
        val = val.result.val;
    }
    if (!val.isData()) return .{ .failed = "the value is not data (functions, results, handles and bytes cannot cross)" };
    var text: std.ArrayList(u8) = .empty;
    mshl.writeData(val, it.arena, &text) catch return .{ .failed = "out of memory" };
    return .{ .value = text.items };
}

fn runStage(it: *mshl.Interp, script: []const u8, in_text: []const u8) StageOut {
    const in_val: Value = if (in_text.len == 0) .nothing else (it.parseData(in_text) catch return .{ .failed = "the input is not data" });
    it.setVar("in", mshl.tableize(it.arena, in_val) catch return .{ .failed = "out of memory" }) catch return .{ .failed = "out of memory" };
    var out: std.ArrayList(u8) = .empty;
    const last = it.evalScript(script, &out) catch |e| return .{ .failed = switch (e) {
        error.OutOfMemory => "out of memory",
        error.Exit => "exit",
        else => it.err_msg,
    } };
    if (!last.isData()) return .{ .failed = "the value is not data (functions, results, handles and bytes cannot cross)" };
    var text: std.ArrayList(u8) = .empty;
    mshl.writeData(last, it.arena, &text) catch return .{ .failed = "out of memory" };
    return .{ .value = text.items };
}
