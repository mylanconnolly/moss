//! msh — the moss shell. An ordinary user process holding exactly the
//! capabilities a developer console needs: a console channel (virtio
//! console driver), a filesystem view (the same badged view protocol as
//! everyone else), an init front channel (service control), and a
//! spawner cap (kernel introspection and `run`).
//!
//! The language is mshl (lib/mshl.zig): pipelines carry VALUES — records
//! and tables from typed IPC — and text exists only when a value is
//! rendered here for the human. msh is the interpreter's host: every
//! command below turns a typed reply into a value; the language does the
//! rest (where/sort-by/select/get, let/if/for/while, redirection).
//!
//! Startup: msh takes its world over its boot channel (BootReq caps
//! tagged console, view, init, fabric), then prints the banner and hands
//! the console to the line editor.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const loader = @import("loader.zig");
const tty = @import("tty.zig");
const lineedit = @import("lineedit.zig");
const boot = @import("boot.zig");
const fscmds = @import("fscmds.zig");
const netcmds = @import("netcmds.zig");
const httpcmds = @import("httpcmds.zig");
const fabcmds = @import("fabcmds.zig");
const syscmds = @import("syscmds.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;
const Target = fscmds.Target;
const pathArg = fscmds.pathArg;
const intOf = fscmds.intOf;
const record = fscmds.record;
const baseName = fscmds.baseName;
const is = fscmds.is;
const joinPath = fscmds.joinPath;
const statRecord = fscmds.statRecord;
const readFileVia = fscmds.readFileVia;
const writeFileVia = fscmds.writeFileVia;

comptime {
    asm (usys.imageHeader("shell"));
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

// Grant slots (insert order log -> chan -> spawner).
const spawner_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

var cons_chan: u64 = 0;
var cons_buf: u64 = 0; // 1-page byte buffer shared with the console driver
var cons_shm_h: u64 = 0; // its cap: run tools get the same buffer
var fs_chan: u64 = 0;
var fs_buf: [*]u8 = undefined;
var init_chan: u64 = 0;
var fab_chan: u64 = 0;
var fab_buf: u64 = 0; // attached lazily on first `nodes`
var glog: u64 = 0;
var run_stage: loader.Stage = undefined;
// The result buffer run programs write their value into (data literal).
var run_out_h: u64 = 0;
var run_out_va: u64 = 0;
/// The program stores `run` consults, in order: the user's own — `img/`
/// in the filesystem this shell holds (a home, or the system volume)
/// — then the system's, a read-only view handed over as `store`. A
/// session gets the system store from the manager; the home's img/ is
/// the user's to fill (`install`).
const Store = fscmds.Store;
var own_store: ?Store = null;
var sys_store: ?Store = null;
/// The two, in the order `use NAME` consults them.
var stores: [2]?Store = .{ null, null };
/// The session manager's channel (a session's own badged copy), for
/// sharing; absent in the system shell.
var sess_chan: u64 = 0;
var sess_buf: [*]u8 = undefined;
/// Views other users shared and this shell accepted, addressed as
/// `@name/path`. A revoked or dead share fails its calls; `accept`
/// again replaces a dead mount of the same name.
const max_mounts = 8;
const Mount = struct { used: bool = false, name: [16]u8 = @splat(0), len: usize = 0, chan: u64 = 0, buf: [*]u8 = undefined };
var mounts: [max_mounts]Mount = @splat(.{});

/// The shared file commands resolve paths through `target` (this
/// shell's filesystem, or a mounted share).
var fs_ctx = fscmds.Fs{ .resolve = target, .root = 0 };
/// The network, when this shell's unit gives a `net` view.
var net: ?netcmds.Net = null;
var fab_ctx: fabcmds.Fab = .{ .chan = 0 };

fn targetOf(path: []const u8) ?Target {
    if (path.len == 0 or path[0] != '@') return .{ .chan = fs_chan, .buf = fs_buf, .path = path };
    var end: usize = 1;
    while (end < path.len and path[end] != '/') end += 1;
    const name = path[1..end];
    for (&mounts) |*m| {
        if (m.used and is(m.name[0..m.len], name)) return .{ .chan = m.chan, .buf = m.buf, .path = if (end < path.len) path[end + 1 ..] else "" };
    }
    return null;
}

fn target(it: *mshl.Interp, path: []const u8) mshl.Error!Target {
    return targetOf(path) orelse it.fail("no such share: {s} (`shares` lists offers; `accept NAME` mounts one)", .{path});
}
const run_out_pages: u64 = 8;

// The interpreter's memory: a per-line arena (reset before every line)
// and a pool the interpreter's boxes — what `let` and `def` bind — are
// allocated from and returned to. Static, like everything in moss
// userspace; msh's manifest budget covers it.
var heap_line: [2 << 20]u8 = undefined;
var line_fba: std.heap.FixedBufferAllocator = undefined;
var box_pool: @import("mosslib").pool.Pool(256, 4096) = .{};
var interp: mshl.Interp = undefined;
var host_ctx: u8 = 0;

export fn umain(log_h: u64, boot_chan: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;

    // Our world arrives over the boot channel: console, fs view, init
    // front, fabric.
    const setup = boot.take(boot_chan);
    cons_chan = setup.cap(.console);
    fs_chan = setup.cap(.view);
    fs_ctx.root = fs_chan;
    init_chan = setup.cap(.init);
    fab_chan = setup.cap(.fabric);
    fab_ctx.chan = fab_chan;
    if (setup.has(.net)) net = netcmds.Net.init(setup.cap(.net));
    // The fabric is optional: a user session has none.
    if (cons_chan == 0 or fs_chan == 0 or init_chan == 0) usys.exit(140);

    // Console byte buffer.
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(141);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(142);
    cons_buf = m.data[0];
    cons_shm_h = s.data[0];
    switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons_chan, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(143),
    }
    tty.init(cons_chan, cons_buf);
    run_stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(147);
    {
        const o = usys.shmCreate(run_out_pages);
        if (o.err != .ok) usys.exit(148);
        const om = usys.shmMap(o.data[0]);
        if (om.err != .ok) usys.exit(149);
        run_out_h = o.data[0];
        run_out_va = om.data[0];
    }

    // Filesystem view buffer.
    const b = fsc.attachBuf(fs_chan);
    fs_buf = @ptrFromInt(b.va);
    if (fsc.fsDerive(fs_chan, fs_buf, "img", false)) |v| {
        own_store = .{ .chan = v, .buf = @ptrFromInt(fsc.attachBuf(v).va), .name = "your store" };
    }
    const store_chan = setup.cap(.store);
    if (store_chan != 0) {
        sys_store = .{ .chan = store_chan, .buf = @ptrFromInt(fsc.attachBuf(store_chan).va), .name = "the system store" };
    }
    stores = .{ own_store, sys_store };
    fs_ctx.stores = &stores;
    sess_chan = setup.cap(.sess);
    if (sess_chan != 0) {
        const sh = usys.shmCreate(1);
        const sm = if (sh.err == .ok) usys.shmMap(sh.data[0]) else sh;
        if (sh.err != .ok or sm.err != .ok) usys.exit(150);
        sess_buf = @ptrFromInt(sm.data[0]);
        switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .attach_buf, sh.data[0])) {
            .ok => {},
            .err => usys.exit(151),
        }
    }

    line_fba = std.heap.FixedBufferAllocator.init(&heap_line);
    interp = mshl.Interp.init(line_fba.allocator(), box_pool.allocator(), .{
        .ctx = @ptrCast(&host_ctx),
        .call = hostCall,
        .signature = hostSignature,
    });

    _ = usys.log(log_h, "msh: up, serving the console");
    tty.out("\r\nmoss shell — 'help' lists commands; tab completes; pipelines carry tables\r\n");
    startup();
    repl();
}

/// The startup script: conf/msh/startup.msh on the volume if the admin
/// wrote one, else the archive's boot/conf/msh/startup.msh. Runs in the
/// same interpreter, so its variables and functions are the session's.
fn startup() void {
    line_fba.reset();
    for ([_][]const u8{ "conf/msh/startup.msh", "boot/conf/msh/startup.msh" }) |path| {
        const text = fscmds.readFile(&fs_ctx, &interp, path) catch continue;
        runScript(text);
        return;
    }
}

fn runScript(text: []const u8) void {
    var out: std.ArrayList(u8) = .empty;
    if (interp.evalScript(text, &out)) |_| {
        printText(out.items);
    } else |e| switch (e) {
        error.Exit => usys.exit(0),
        error.OutOfMemory => tty.out("script: out of memory\r\n"),
        else => {
            tty.out("script error: ");
            tty.out(interp.err_msg);
            tty.out("\r\n");
        },
    }
}

fn repl() noreturn {
    var editor: lineedit.Editor = .{
        .io = .{ .ctx = @ptrCast(&host_ctx), .read = edRead, .write = edWrite, .complete = edComplete },
        .prompt = "msh> ",
    };
    var line: [lineedit.max_line]u8 = undefined;
    while (true) {
        const n = editor.readLine(&line);
        const src = trim(line[0..n]);
        if (src.len == 0) continue;
        line_fba.reset();
        if (interp.run(src)) |_| {
            printText(interp.out.items);
        } else |e| switch (e) {
            error.Exit => {
                tty.out("bye\r\n");
                usys.exit(0);
            },
            error.OutOfMemory => tty.out("error: out of memory (line too large)\r\n"),
            error.Syntax, error.Runtime => {
                tty.out("error: ");
                tty.out(interp.err_msg);
                tty.out("\r\n");
            },
        }
    }
}

/// Console output: '\n' becomes "\r\n".
fn printText(text: []const u8) void {
    var start: usize = 0;
    for (text, 0..) |c, i| {
        if (c == '\n') {
            tty.out(text[start..i]);
            tty.out("\r\n");
            start = i + 1;
        }
    }
    if (start < text.len) tty.out(text[start..]);
}

// ------------------------------------------------------------ editor io

fn edRead(_: *anyopaque, buf: []u8) usize {
    const got = consRead(@min(buf.len, 64));
    const src: [*]const volatile u8 = @ptrFromInt(cons_buf);
    for (0..got) |i| buf[i] = src[i];
    return got;
}

fn edWrite(_: *anyopaque, bytes: []const u8) void {
    tty.out(bytes);
}

fn consRead(max: u64) u64 {
    switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons_chan, .{
        .read = .{ .max = max },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .n => |x| return x.n,
            else => usys.exit(144),
        },
        .err => usys.exit(145),
    }
}

const command_names = [_][]const u8{
    "ls",    "tree",    "cat",    "open",   "write",    "save",   "stat",
    "mkdir", "rm",      "mv",     "ln",     "readlink", "sync",   "df",
    "ps",    "mem",     "svc",    "start",  "stop",     "nodes",  "rspawn",
    "rand",  "run",     "help",   "exit",   "clear",    "source", "install",
    "share", "unshare", "shares", "accept",
};

/// Tab completion: command names in command position, paths elsewhere
/// (listing the prefix's directory through the view; directories get a
/// trailing '/').
fn edComplete(_: *anyopaque, word: []const u8, first: bool, out: *[lineedit.max_candidates][lineedit.candidate_len]u8, lens: *[lineedit.max_candidates]usize) usize {
    var n: usize = 0;
    if (first) {
        for (command_names) |c| n = addCandidate(out, lens, n, c, word, "", false);
        for (mshl.builtin_names) |c| n = addCandidate(out, lens, n, c, word, "", false);
        return n;
    }
    var slash: ?usize = null;
    for (word, 0..) |c, i| {
        if (c == '/') slash = i;
    }
    const dir = if (slash) |i| word[0..i] else "";
    const prefix = if (slash) |i| word[i + 1 ..] else word;
    const dir_prefix = if (slash) |i| word[0 .. i + 1] else "";
    const t = targetOf(dir) orelse return 0;
    const count = fsc.fsList(t.chan, t.buf, t.path) orelse return 0;
    var names: [4096]u8 = undefined;
    const k = @min(count, names.len);
    @memcpy(names[0..k], t.buf[0..k]);
    var it = std.mem.splitScalar(u8, names[0..k], '\n');
    while (it.next()) |name| {
        if (name.len == 0 or !startsWith(name, prefix)) continue;
        var full: [256]u8 = undefined;
        const fl = joinPath(&full, t.path, name);
        const st = fsc.fsStat(t.chan, t.buf, full[0..fl]);
        const is_dir = st != null and st.?.typ == @intFromEnum(shared.FsType.dir);
        n = addCandidate(out, lens, n, name, "", dir_prefix, is_dir);
        if (n == lineedit.max_candidates) break;
    }
    return n;
}

fn addCandidate(out: *[lineedit.max_candidates][lineedit.candidate_len]u8, lens: *[lineedit.max_candidates]usize, n: usize, name: []const u8, prefix: []const u8, dir_prefix: []const u8, is_dir: bool) usize {
    if (n == lineedit.max_candidates or !startsWith(name, prefix)) return n;
    const total = dir_prefix.len + name.len + @intFromBool(is_dir);
    if (total > lineedit.candidate_len) return n;
    @memcpy(out[n][0..dir_prefix.len], dir_prefix);
    @memcpy(out[n][dir_prefix.len .. dir_prefix.len + name.len], name);
    if (is_dir) out[n][total - 1] = '/';
    lens[n] = total;
    return n + 1;
}

// ------------------------------------------------------------- the host
//
// Every command: typed IPC in, a Value out. The language never sees text
// from another service. Every command has a signature (checked by the
// interpreter around the call), and what the world decides — a program
// that is not there, a service that refuses — is a result whose err is
// a word; the shell's own words are below.

const Shape = mshl.Shape;
const Param = mshl.Param;
const svc_result = mshl.resultShape(.{ .one_of = &.{ .{ .word = "started" }, .{ .word = "stopped" } } }, .{ .one_of = &.{ .{ .word = "refused" }, .{ .word = "unreachable" } } });
const run_err: Shape = .{ .one_of = &.{ .{ .word = "not_found" }, .{ .word = "unreadable" }, .{ .word = "bad_digest" }, .{ .word = "bad_manifest" }, .{ .word = "no_such_path" }, .{ .word = "refused" } } };
const run_result = mshl.resultShape(.any, run_err);
const install_result = mshl.resultShape(.nothing, .{ .one_of = &.{ .{ .word = "not_found" }, .{ .word = "unreadable" }, .{ .word = "bad_digest" }, .{ .word = "bad_manifest" }, .{ .word = "no_store" }, mshl.shapeOf(shared.FsErr) } });
const sess_err: Shape = .{ .one_of = &.{ .{ .word = "not_found" }, .{ .word = "denied" }, .{ .word = "no_such_user" }, .{ .word = "exists" }, .{ .word = "no_session" }, .{ .word = "refused" }, .{ .word = "no_room" } } };
const sess_result = mshl.resultShape(.nothing, sess_err);
const rspawn_result = mshl.resultShape(mshl.shapeOf(struct { node: i64, rpc_40_plus_2: i64 }), .{ .one_of = &.{ mshl.shapeOf(shared.FabErr), .{ .word = "error" } } });
const Proc = struct { id: i64, name: []const u8, state: enum { alive, dying, dead }, threads: i64, kobj_kb: i64, kobj_max: i64, user_kb: i64, user_max: i64 };
const Mem = struct { free_mb: i64, total_mb: i64, cores: i64, uptime_s: i64 };
const Svc = struct { id: i64, name: []const u8, state: enum { up, down }, restarts: i64, max: i64 };
const Node = struct { id: i64, state: enum { up, down }, free_mb: i64 };
const ps_shape = mshl.shapeOf([]const Proc);
const mem_shape = mshl.shapeOf(Mem);
const svc_shape = mshl.shapeOf([]const Svc);
const nodes_shape = mshl.shapeOf([]const Node);

fn hostSignature(_: *anyopaque, name: []const u8) ?mshl.Signature {
    if (is(name, "help")) return .{ .ret = .string };
    if (is(name, "exit") or is(name, "clear")) return .{ .ret = .nothing };
    if (fscmds.signature(name)) |sig| return sig;
    if (net != null) {
        if (netcmds.signature(name)) |sig| return sig;
        if (httpcmds.signature(name)) |sig| return sig;
    }
    if (fab_chan != 0) {
        if (fabcmds.signature(name)) |sig| return sig;
    }
    if (syscmds.signature(name)) |sig| return sig;
    if (is(name, "ps")) return .{ .ret = ps_shape };
    if (is(name, "mem")) return .{ .ret = mem_shape };
    if (is(name, "svc")) return .{ .ret = svc_shape };
    if (is(name, "start") or is(name, "stop")) return .{ .params = &.{.{ .name = "service", .shape = .int }}, .ret = svc_result };
    if (is(name, "nodes")) return .{ .ret = nodes_shape };
    if (is(name, "rspawn")) return .{ .params = &.{ .{ .name = "node", .shape = .int }, .{ .name = "image", .shape = .int } }, .ret = rspawn_result };
    if (is(name, "rand")) return .{ .ret = .string };
    if (is(name, "run")) return .{ .params = &.{ .{ .name = "program", .shape = .string }, .{ .name = "path", .shape = .string, .optional = true } }, .ret = run_result };
    if (is(name, "install")) return .{ .params = &.{.{ .name = "program", .shape = .string }}, .ret = install_result };
    if (is(name, "share")) return .{ .params = &.{ .{ .name = "path", .shape = .string }, .{ .name = "name", .shape = .string }, .{ .name = "user", .shape = .string }, .{ .name = "mode", .shape = .{ .word = "rw" }, .optional = true } }, .ret = sess_result };
    if (is(name, "unshare") or is(name, "accept")) return .{ .params = &.{.{ .name = "name", .shape = .string }}, .ret = sess_result };
    if (is(name, "shares")) return .{ .ret = .table };
    return null;
}

fn okv(it: *mshl.Interp, v: Value) mshl.Error!Value {
    return it.mkResult(true, v);
}

fn errWord(it: *mshl.Interp, word: []const u8) mshl.Error!Value {
    return it.mkResult(false, .{ .str = word });
}

fn hostCall(_: *anyopaque, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const a = it.arena;
    if (is(name, "help")) return .{ .str = help_text };
    if (is(name, "exit")) return error.Exit;
    if (is(name, "clear")) {
        tty.out("\x1b[2J\x1b[H"); // clear the screen, cursor home (ctrl-l does the same)
        return .nothing;
    }
    if (try fscmds.call(&fs_ctx, it, name, args, input)) |v| return v;
    if (net) |*nt| {
        if (try netcmds.call(nt, it, name, args, input)) |v| return v;
        if (try httpcmds.call(nt, it, name, args, input)) |v| return v;
    }
    if (fab_chan != 0) {
        if (try fabcmds.call(&fab_ctx, it, name, args, input)) |v| return v;
    }
    if (try syscmds.call(it, name, args)) |v| return v;
    if (is(name, "ps")) return try psTable(it);
    if (is(name, "mem")) {
        const r = usys.sysInfo(spawner_h);
        if (r.err != .ok) return it.fail("mem: introspection denied", .{});
        return try mshl.toValue(a, Mem{ .free_mb = @intCast(r.data[0] >> 20), .total_mb = @intCast(r.data[1] >> 20), .cores = @intCast(r.data[2]), .uptime_s = @intCast(r.data[3] / 10) });
    }
    if (is(name, "svc")) return try svcTable(it);
    if (is(name, "start") or is(name, "stop")) {
        if (args[0].int < 0) return it.fail("{s}: a service id is not negative", .{name});
        return try svcControl(it, name, @intCast(args[0].int));
    }
    if (is(name, "nodes")) return try nodesTable(it);
    if (is(name, "rspawn")) {
        if (fab_chan == 0) return it.fail("rspawn: no fabric in this session", .{});
        if (args[0].int < 0 or args[1].int < 0) return it.fail("rspawn: node and image are not negative", .{});
        return try rspawn(it, @intCast(args[0].int), @intCast(args[1].int));
    }
    if (is(name, "rand")) {
        var bytes: [16]u8 = undefined;
        const e = usys.getrandom(&bytes);
        if (e == .bad_state) return it.fail("rand: kernel pool unseeded (no rngd)", .{});
        if (e != .ok) return it.fail("rand: refused", .{});
        var hex: [32]u8 = undefined;
        const digits = "0123456789abcdef";
        for (bytes, 0..) |x, i| {
            hex[i * 2] = digits[x >> 4];
            hex[i * 2 + 1] = digits[x & 15];
        }
        return .{ .str = try a.dupe(u8, &hex) };
    }
    if (is(name, "run")) return try cmdRun(it, args[0].str, if (args.len > 1) args[1].str else "");
    if (is(name, "install")) return try cmdInstall(it, args[0].str);
    if (is(name, "share")) return try cmdShare(it, args[0].str, args[1].str, args[2].str, args.len > 3);
    if (is(name, "unshare")) return try cmdUnshare(it, args[0].str);
    if (is(name, "shares")) return try cmdShares(it);
    if (is(name, "accept")) return try cmdAccept(it, args[0].str);
    return null;
}

const help_text =
    \\commands (every one yields a value; pipe them):
    \\  ls [p] | tree [p] [--depth n] | stat p | cat p | write p text | save p
    \\  mkdir p | rm p | mv a b | ln p target | readlink p | df | sync
    \\  ps | mem | svc | start N | stop N | nodes | rspawn N I | rand
    \\  run NAME [path]        a program from your store (img/) or the system's, in its own domain; its result is a value
    \\  install NAME           copy a program (or a module) from the system store into your own (img/)
    \\  share PATH NAME USER [rw]  offer a view of PATH in your home to USER as NAME
    \\  unshare NAME | shares  withdraw an offer (holders lose it) | list offers to and by you
    \\  accept NAME            mount an offer made to you: paths @NAME/...
    \\  source p               run a script in this session (startup: conf/msh/startup.msh)
    \\  x | to-data | save p   write a value as data; open p | from-data reads it back
    \\  def name [a b] { .. }  a function ($in is the pipeline input); fn [a] { .. } is a value; $f args calls one
    \\  use p | use NAME       a file (or a module from the store) evaluated as a module: a record of its bindings
    \\  connect ADDR PORT | listen PORT | accept $l | send $s DATA | recv $s | close $s | status $s
    \\                         sockets as values (results: ok/err), when this shell holds a network view
    \\  http-read $s | http-write $s RESP | serve $l $handler [n] | fetch URL [{ method, headers, body }]
    \\                         HTTP on those sockets; a handler returns a record { status, headers, body }, text, or data (JSON)
    \\  x | remote NODE { .. }  run the block on another node with $in = x (the fabric)
    \\  sleep MS | now | date  wait; milliseconds since boot (a clock for measuring); the wall clock as a record
    \\language:
    \\  x | where size > 4kb | sort-by name --desc | select name size
    \\  x | get col | first n | last n | reverse | len | keys | lines
    \\  x | map { $it * 2 } | filter { .. } | reduce 0 { $acc + $it } | any | all | find
    \\  let v = expr; $v; "text $v"; if c { } else { }; for x in list { }
    \\  while c { }; (sub | pipeline); [a, b]; { k: v }; x > path  (save rendered)
    \\  ok v | err e; r?; try { cmd }; match v { ok $x => ..; err $e => ..; [$h, ..$t] => ..; _ => .. }
    \\  what the world decides is a result: cat p? | lines; match (cat p) { ok $t => ..; err not_found => .. }
    \\  str v | int text | float text | type v | to-bytes | from-bytes   (strong types: nothing coerces)
    \\  let x: { name: string } = ..; def f [n: int] -> int { .. }; match v: dir | file { .. }   (shapes, checked where they run)
    \\  x | check $Shape; shape { k: int }; signature CMD   (a shape is a value; every command declares one)
    \\  ctrl-a/e, arrows, history, tab completes commands and paths
    \\  clear (or ctrl-l) | help | exit
;

// ---------------------------------------------------------- introspection

fn psTable(it: *mshl.Interp) mshl.Error!Value {
    const a = it.arena;
    var recs: [16 * shared.DomainRec.size]u8 = undefined;
    const r = usys.domainList(spawner_h, &recs);
    if (r.err != .ok) return it.fail("ps: introspection denied", .{});
    var rows: std.ArrayList(Proc) = .empty;
    for (0..r.data[0]) |i| {
        const rec = shared.DomainRec.decode(recs[i * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        try rows.append(a, .{
            .id = rec.id,
            .name = try a.dupe(u8, rec.nameSlice()),
            .state = switch (rec.state) {
                .alive => .alive,
                .dying => .dying,
                .dead => .dead,
            },
            .threads = rec.threads,
            .kobj_kb = @intCast(rec.kobj_kb >> 32),
            .kobj_max = @intCast(rec.kobj_kb & 0xffff_ffff),
            .user_kb = @intCast(rec.user_kb >> 32),
            .user_max = @intCast(rec.user_kb & 0xffff_ffff),
        });
    }
    if (rows.items.len == 0) return .{ .table = .{ .cols = &.{ "id", "name", "state", "threads", "kobj_kb", "kobj_max", "user_kb", "user_max" }, .rows = &.{} } };
    return try mshl.toValue(a, @as([]const Proc, rows.items));
}

const svc_names = [_][]const u8{ "logsvc", "greeter" };

fn svcTable(it: *mshl.Interp) mshl.Error!Value {
    const a = it.arena;
    var rows: std.ArrayList(Svc) = .empty;
    for (svc_names, 0..) |sname, id| {
        switch (usys.callTyped(shared.InitRequest, shared.InitReply, init_chan, .{
            .status = .{ .service = id },
        }, 0)) {
            .ok => |rep| switch (rep) {
                .svc_status => |st| try rows.append(a, .{
                    .id = @intCast(id),
                    .name = sname,
                    .state = if (st.up != 0) .up else .down,
                    .restarts = @intCast(st.restarts),
                    .max = @intCast(st.max_restarts),
                }),
                else => return it.fail("svc: bad reply from init", .{}),
            },
            .err => return it.fail("svc: init unreachable", .{}),
        }
    }
    return try mshl.toValue(a, @as([]const Svc, rows.items));
}

/// `start N` / `stop N`: what init decides is a result.
fn svcControl(it: *mshl.Interp, op: []const u8, id: u64) mshl.Error!Value {
    if (is(op, "start")) {
        switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_chan, .{
            .connect = .{ .service = id },
        }, 0)) {
            .ok => |ok| switch (ok.rep) {
                .connected => {
                    if (ok.cap != 0) _ = usys.capDrop(ok.cap); // we only wanted the side effect
                    return try okv(it, .{ .str = "started" });
                },
                else => return try errWord(it, "refused"),
            },
            .err => return try errWord(it, "unreachable"),
        }
    }
    switch (usys.callTyped(shared.InitRequest, shared.InitReply, init_chan, .{
        .stop = .{ .service = id },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .stopped => return try okv(it, .{ .str = "stopped" }),
            else => return try errWord(it, "refused"),
        },
        .err => return try errWord(it, "unreachable"),
    }
}

// ----------------------------------------------------------------- fabric

fn fabAttach() bool {
    if (fab_buf != 0) return true;
    if (fab_chan == 0) return false;
    const s = usys.shmCreate(1);
    if (s.err != .ok) return false;
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) return false;
    switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .attach_buf, s.data[0])) {
        .ok => {},
        .err => return false,
    }
    fab_buf = m.data[0];
    return true;
}

fn nodesTable(it: *mshl.Interp) mshl.Error!Value {
    const a = it.arena;
    if (!fabAttach()) return it.fail("nodes: fabric unreachable", .{});
    const n = switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .members, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| x.n,
            else => return it.fail("nodes: bad reply", .{}),
        },
        .err => return it.fail("nodes: fabric unreachable", .{}),
    };
    var rows: std.ArrayList(Node) = .empty;
    const recs: [*]const u8 = @ptrFromInt(fab_buf);
    for (0..n) |i| {
        const rec = recs[i * shared.fab_member_size ..];
        try rows.append(a, .{
            .id = @as(i64, rec[0]) | (@as(i64, rec[1]) << 8),
            .state = if (rec[2] != 0) .up else .down,
            .free_mb = @as(i64, rec[4]) | (@as(i64, rec[5]) << 8),
        });
    }
    if (rows.items.len == 0) return .{ .table = .{ .cols = &.{ "id", "state", "free_mb" }, .rows = &.{} } };
    return try mshl.toValue(a, @as([]const Node, rows.items));
}

fn rspawn(it: *mshl.Interp, node: u64, image: u64) mshl.Error!Value {
    switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{
        .remote_spawn = .{ .node = node, .image = image, .arg = 2 },
    }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .spawned => |sp| {
                if (ok.cap == 0) return try errWord(it, "error");
                defer _ = usys.capDrop(ok.cap);
                // Prove the remote channel with a typed RPC through it.
                const r = usys.callRaw(ok.cap, shared.encodeMsg(shared.CalcRequest, .{
                    .add = .{ .a = 40, .b = 2 },
                }), 0);
                var sum: i64 = -1;
                if (r.err == .ok and r.data[0] != shared.fabric_err_sentinel) {
                    if (shared.decodeMsg(shared.CalcReply, r.data)) |crep| {
                        if (crep == .sum) sum = @intCast(crep.sum.value);
                    }
                }
                return try okv(it, try record(it, &.{ "node", "rpc_40_plus_2" }, &.{ .{ .int = @intCast(sp.node) }, .{ .int = sum } }));
            },
            .fab_err => |e| return try errWord(it, fabcmds.fabErrName(e.code)),
            else => return try errWord(it, "error"),
        },
        .err => return it.fail("rspawn: fabric unreachable", .{}),
    }
}

// -------------------------------------------------------------------- run
//
// `run NAME [path]`: a program from the content-addressed img/ store gets
// its own domain with exactly what its unit file (boot/conf/units/NAME.msh)
// says — kernel grants, and a view of the argument path for a tool that
// takes one — plus the console, then msh waits for it to exit. The image
// is read through msh's view, verified against its digest, and spawned
// from msh's stage.

// ------------------------------------------------------------- sharing
//
// A share is a view of a path in this home, derived here (a badged cap
// on the home filesystem, with the badge learned from the reply) and
// handed to the session manager with a name and a user. The other
// user's shell lists offers, accepts one — the cap comes back to it —
// and mounts it as `@NAME`. `unshare` asks the home filesystem, through
// the manager, to withdraw the view: the holder's calls fail from then
// on, whatever copies of the cap exist.

fn sessWord(off: usize, s: []const u8) u64 {
    @memcpy(sess_buf[off .. off + s.len], s);
    return @as(u64, off) | (@as(u64, s.len) << 32);
}

/// The manager's answer as a word: what it decided, for a script to
/// match on.
fn sessWordOf(resp: shared.SessResp) []const u8 {
    return switch (resp) {
        .sess_err => |e| switch (e.code) {
            2 => "not_found",
            5 => "denied",
            6 => "no_such_user",
            7, 8 => "exists",
            else => "refused",
        },
        .denied => "denied",
        else => "refused",
    };
}

fn cmdShare(it: *mshl.Interp, path: []const u8, name: []const u8, user: []const u8, rw: bool) mshl.Error!Value {
    if (sess_chan == 0) return try errWord(it, "no_session");
    if (path.len > 0 and path[0] == '@') return it.fail("share: only paths in your own home can be shared", .{});
    if (name.len == 0 or name.len > 16 or user.len == 0 or user.len > 16) return it.fail("share: NAME and USER are at most 16 characters", .{});
    const d = fsc.fsDeriveBadged(fs_chan, fs_buf, path, !rw) orelse return try errWord(it, "not_found");
    const nw = sessWord(0, name);
    const uw = sessWord(64, user);
    const res = usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .share = .{ .name = nw, .user = uw, .badge = d.badge } }, d.cap);
    _ = usys.capDrop(d.cap); // the manager's copy (or nobody's) carries on
    switch (res) {
        .ok => |rep| if (rep != .ok) return try errWord(it, sessWordOf(rep)),
        .err => |e| return it.fail("share: {t}", .{e}),
    }
    return try okv(it, .nothing);
}

fn cmdUnshare(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    if (sess_chan == 0) return try errWord(it, "no_session");
    if (name.len == 0 or name.len > 16) return it.fail("unshare: NAME is at most 16 characters", .{});
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .unshare = .{ .name = sessWord(0, name) } }, 0)) {
        .ok => |rep| if (rep != .ok) return try errWord(it, sessWordOf(rep)),
        .err => |e| return it.fail("unshare: {t}", .{e}),
    }
    return try okv(it, .nothing);
}

fn cmdShares(it: *mshl.Interp) mshl.Error!Value {
    if (sess_chan == 0) return it.fail("shares: no session manager here", .{});
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .shares, 0)) {
        .ok => |rep| switch (rep) {
            .data => |d| {
                const text = try it.arena.dupe(u8, sess_buf[0..@min(d.len, 4096)]);
                const v = try mshl.tableize(it.arena, try it.parseData(text));
                // No offers: an empty table, still a table.
                if (v == .list and v.list.len == 0) return .{ .table = .{ .cols = &.{ "name", "path", "from", "to", "rw", "accepted" }, .rows = &.{} } };
                return v;
            },
            else => return it.fail("shares: {s}", .{sessWordOf(rep)}),
        },
        .err => |e| return it.fail("shares: {t}", .{e}),
    }
}

fn cmdAccept(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    if (sess_chan == 0) return try errWord(it, "no_session");
    if (name.len == 0 or name.len > 16) return it.fail("accept: NAME is at most 16 characters", .{});
    // A mount by that name, dead or alive, goes first: its cap is dropped
    // (the owner's filesystem hears of it); its buffer stays mapped.
    var slot: ?*Mount = null;
    for (&mounts) |*m| {
        if (m.used and is(m.name[0..m.len], name)) {
            _ = usys.capDrop(m.chan);
            m.used = false;
        }
        if (!m.used and slot == null) slot = m;
    }
    const m = slot orelse return try errWord(it, "no_room");
    switch (usys.callTypedCap(shared.SessReq, shared.SessResp, sess_chan, .{ .accept = .{ .name = sessWord(0, name) } }, 0)) {
        .ok => |ok| {
            if (ok.rep != .ok) return try errWord(it, sessWordOf(ok.rep));
            if (ok.cap == 0) return it.fail("accept: the manager sent no view", .{});
            m.* = .{ .used = true, .len = name.len, .chan = ok.cap, .buf = @ptrFromInt(fsc.attachBuf(ok.cap).va) };
            @memcpy(m.name[0..name.len], name);
        },
        .err => |e| return it.fail("accept: {t}", .{e}),
    }
    return try okv(it, .nothing);
}

/// A program found in a store: which store, its digest, its manifest.
const Program = struct { store: Store, digest: [shared.img_digest_hex_len]u8, manifest: Value };

/// `img/<name>.msh` in the user's own store, then the system's.
fn findProgram(it: *mshl.Interp, name: []const u8) mshl.Error!?Program {
    const candidates = [_]?Store{ own_store, sys_store };
    for (candidates) |maybe| {
        const st = maybe orelse continue;
        var mpath: [64]u8 = undefined;
        if (name.len + shared.img_manifest_ext.len > mpath.len) return it.fail("run: name too long", .{});
        @memcpy(mpath[0..name.len], name);
        @memcpy(mpath[name.len .. name.len + shared.img_manifest_ext.len], shared.img_manifest_ext);
        const mp = mpath[0 .. name.len + shared.img_manifest_ext.len];
        const text = readFileVia(it, st.chan, st.buf, mp) catch continue;
        const v = try it.parseData(text);
        if (v != .record) return it.fail("run: {s}: the manifest in {s} is not a record", .{ name, st.name });
        const img = v.record.get("image") orelse return it.fail("run: {s}: manifest names no image", .{name});
        if (img != .str or img.str.len != shared.img_digest_hex_len) return it.fail("run: {s}: manifest image is not a digest", .{name});
        var p: Program = .{ .store = st, .digest = undefined, .manifest = v };
        @memcpy(&p.digest, img.str);
        return p;
    }
    return null;
}

/// `run NAME [path]`: what the store and the spawner decide is a result
/// (`err not_found`, `err bad_digest` …); the program's own value is the
/// `ok`.
fn cmdRun(it: *mshl.Interp, name: []const u8, path: []const u8) mshl.Error!Value {
    const prog = (try findProgram(it, name)) orelse return try errWord(it, "not_found");
    const len = readIntoStageVia(prog.store.chan, prog.store.buf, &prog.digest) orelse return try errWord(it, "unreadable");
    if (!run_stage.verify(len, &prog.digest)) return try errWord(it, "bad_digest");

    // The manifest says what the program is handed: kernel grants and
    // views (a view path of `arg` is the run argument), and the system
    // store when it asks (`{ tag: store }`). The console is always ours
    // to give.
    var flags: u64 = shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a;
    var view: u64 = 0;
    var run_arg: u64 = 0;
    var give_store = false;
    {
        const unit = prog.manifest;
        if (unit.record.get("grant")) |g| {
            if (g == .list) for (g.list) |item| {
                if (item == .str and is(item.str, "introspect")) flags |= shared.SpawnFlags.grant_introspect;
                if (item == .str and is(item.str, "bootfs")) flags |= shared.SpawnFlags.grant_bootfs;
            };
        }
        if (unit.record.get("arg")) |g| {
            if (g == .int) run_arg = @intCast(@max(g.int, 0));
        }
        if (unit.record.get("give")) |g| {
            if (g == .list) for (g.list) |item| {
                if (item != .record) continue;
                if (item.record.get("tag")) |tg| {
                    if (tg == .str and is(tg.str, "store")) {
                        give_store = true;
                        continue;
                    }
                }
                const fs_path = item.record.get("fs") orelse continue;
                if (fs_path != .str) continue;
                const p = if (is(fs_path.str, "arg")) path else fs_path.str;
                var ro = true;
                if (item.record.get("ro")) |r| ro = r.asBool();
                const t = try target(it, p);
                view = fsc.fsDerive(t.chan, t.buf, t.path, ro) orelse return try errWord(it, "no_such_path");
            };
        }
    }

    // The tool serves side A of its boot channel; we feed it caps on B.
    const ch = usys.chanCreate();
    if (ch.err != .ok) return it.fail("run: out of channels", .{});
    const sp = usys.spawn(spawner_h, run_stage.handle, run_arg, ch.data[0], flags, usys.kbLimits(1 << 10, 8 << 10));
    _ = usys.capDrop(ch.data[0]);
    if (sp.err != .ok) {
        _ = usys.capDrop(ch.data[1]);
        if (view != 0) _ = usys.capDrop(view);
        return try errWord(it, "refused");
    }
    const bch = ch.data[1];
    // A clean result buffer: the program's value comes back through it.
    @memset(@as([*]u8, @ptrFromInt(run_out_va))[0 .. run_out_pages * 4096], 0);
    var ok = boot.giveCap(bch, .console, cons_chan) and boot.giveCap(bch, .console_buf, cons_shm_h) and boot.giveCap(bch, .out, run_out_h);
    if (ok and view != 0) ok = boot.giveCap(bch, .view, view);
    if (ok and give_store) {
        if (sys_store) |st| ok = boot.giveCap(bch, .store, st.chan);
    }
    if (ok) {
        const w = shared.strToWords(path);
        ok = boot.give(bch, .{ .arg = .{ .a = w[0], .b = w[1], .c = w[2] } }, 0);
    }
    if (ok) ok = boot.give(bch, .go, 0);
    if (!ok) tty.out("run: the program did not take its setup\r\n");

    // The console is the tool's until it exits.
    while (true) {
        const st = usys.domainStat(sp.data[0]);
        if (st.err != .ok or st.data[0] == @intFromEnum(shared.DomainState.dead)) {
            if (st.err == .ok and st.data[1] != 0) {
                var l: tty.Line = .{};
                _ = l.str("run: ").str(name).str(" exited with code ").num(st.data[1]);
                l.flush();
            }
            break;
        }
        usys.sleep(1);
    }
    _ = usys.capDrop(sp.data[0]);
    _ = usys.capDrop(bch);
    if (view != 0) _ = usys.capDrop(view);
    // Whatever the program wrote back is its value; nothing = nothing.
    const out_bytes = @as([*]const u8, @ptrFromInt(run_out_va));
    var n: usize = 0;
    while (n < run_out_pages * 4096 and out_bytes[n] != 0) n += 1;
    if (n == 0) return try okv(it, .nothing);
    const text = try it.arena.dupe(u8, out_bytes[0..n]);
    return try okv(it, try mshl.tableize(it.arena, try it.parseData(text)));
}

/// `install NAME`: the program's image (or a module's source) and its
/// manifest, copied from the system store into the user's own — the
/// blob verified against its digest on the way, present ones skipped
/// (the name IS the content). From then on `run NAME` (or `use NAME`)
/// finds it in the user's store first. What the stores decide is a
/// result.
fn cmdInstall(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    const own = own_store orelse return try errWord(it, "no_store");
    const sys = sys_store orelse return try errWord(it, "no_store");
    var mpath: [64]u8 = undefined;
    if (name.len + shared.img_manifest_ext.len > mpath.len) return it.fail("install: name too long", .{});
    @memcpy(mpath[0..name.len], name);
    @memcpy(mpath[name.len .. name.len + shared.img_manifest_ext.len], shared.img_manifest_ext);
    const mp = mpath[0 .. name.len + shared.img_manifest_ext.len];
    const text = switch (try fscmds.readFileViaR(it, sys.chan, sys.buf, mp)) {
        .text => |t| t,
        .err => return try errWord(it, "not_found"),
    };
    const v = try it.parseData(text);
    if (v != .record) return try errWord(it, "bad_manifest");
    const is_module = v.record.get("image") == null;
    const blob = v.record.get(if (is_module) "source" else "image") orelse return try errWord(it, "bad_manifest");
    if (blob != .str or blob.str.len != shared.img_digest_hex_len) return try errWord(it, "bad_manifest");
    var digest: [shared.img_digest_hex_len]u8 = undefined;
    @memcpy(&digest, blob.str);
    var bytes: []const u8 = undefined;
    if (is_module) {
        bytes = switch (try fscmds.readFileViaR(it, sys.chan, sys.buf, &digest)) {
            .text => |t| t,
            .err => return try errWord(it, "unreadable"),
        };
        const have = loader.digestHex(bytes);
        if (!std.mem.eql(u8, &have, &digest)) return try errWord(it, "bad_digest");
    } else {
        const len = readIntoStageVia(sys.chan, sys.buf, &digest) orelse return try errWord(it, "unreadable");
        if (!run_stage.verify(len, &digest)) return try errWord(it, "bad_digest");
        bytes = run_stage.slice(len);
    }
    if (fsc.fsStat(own.chan, own.buf, &digest) == null) {
        switch (fscmds.writeFileViaR(own.chan, own.buf, &digest, bytes)) {
            .ok => {},
            .err => |e| return try errWord(it, @tagName(e)),
        }
    }
    switch (fscmds.writeFileViaR(own.chan, own.buf, mp, text)) {
        .ok => {},
        .err => |e| return try errWord(it, @tagName(e)),
    }
    var l: tty.Line = .{};
    _ = l.str("installed ").str(name).str(" into your store");
    l.flush();
    return try okv(it, .nothing);
}

/// Read a store's image `<digest>` through that store's buffer into the
/// run stage; returns its length.
fn readIntoStageVia(chan: u64, buf: [*]u8, digest: *const [shared.img_digest_hex_len]u8) ?usize {
    const fd = switch (fsc.fsOpen(chan, buf, digest, 0)) {
        .fd => |fd| fd,
        .err => return null,
    };
    defer fsc.fsClose(chan, fd);
    var off: usize = 0;
    while (off < run_stage.bytes) {
        const n = fsc.fsReadAt(chan, fd, off, @min(shared.fs_max_io, run_stage.bytes - off)) orelse return null;
        if (n == 0) break;
        @memcpy(run_stage.slice(off + n)[off..], buf[0..n]);
        off += n;
    }
    return off;
}

// ------------------------------------------------------------- utilities

fn startsWith(s: []const u8, prefix: []const u8) bool {
    return s.len >= prefix.len and is(s[0..prefix.len], prefix);
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\r' or s[a] == '\n')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\r' or s[b - 1] == '\n')) b -= 1;
    return s[a..b];
}
