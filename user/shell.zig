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
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;

comptime {
    asm (
        \\.section .text.uhdr, "ax"
        \\.global __uhdr
        \\__uhdr:
        \\        .ascii  "MOSS"
        \\        .word   0
        \\        .quad   __utext_size
        \\        .quad   __uload_size
        \\        .quad   __umem_size
        \\        .ascii  "shell"
        \\        .space  11
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
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
const Store = struct { chan: u64, buf: [*]u8, name: []const u8 };
var own_store: ?Store = null;
var sys_store: ?Store = null;
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

/// Where a path lives: this shell's filesystem, or a mounted share.
const Target = struct { chan: u64, buf: [*]u8, path: []const u8 };

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
    init_chan = setup.cap(.init);
    fab_chan = setup.cap(.fabric);
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
        const text = readFile(&interp, path) catch continue;
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
// from another service.

fn hostCall(_: *anyopaque, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const a = it.arena;
    if (is(name, "help")) return .{ .str = help_text };
    if (is(name, "exit")) return error.Exit;
    if (is(name, "clear")) {
        tty.out("\x1b[2J\x1b[H"); // clear the screen, cursor home (ctrl-l does the same)
        return .nothing;
    }
    if (is(name, "ls")) return try lsTable(it, if (args.len > 0) try pathArg(it, args[0]) else "");
    if (is(name, "tree")) {
        var path: []const u8 = "";
        var depth: usize = 8;
        var i: usize = 0;
        while (i < args.len) : (i += 1) {
            const s = try pathArg(it, args[i]);
            if (is(s, "--depth") and i + 1 < args.len) {
                depth = @intCast(try intOf(it, args[i + 1]));
                i += 1;
            } else path = s;
        }
        var text: std.ArrayList(u8) = .empty;
        try text.appendSlice(a, if (path.len == 0) "." else path);
        try text.append(a, '\n');
        try treeInto(it, &text, path, "", depth);
        return .{ .str = text.items };
    }
    if (is(name, "cat") or is(name, "open")) {
        if (args.len < 1) return it.fail("{s}: path expected", .{name});
        return .{ .str = try readFile(it, try pathArg(it, args[0])) };
    }
    if (is(name, "write")) {
        if (args.len < 2) return it.fail("write: path and text expected", .{});
        var text: std.ArrayList(u8) = .empty;
        try mshl.renderInline(args[1], a, &text);
        try writeFile(it, try pathArg(it, args[0]), text.items);
        return .nothing;
    }
    if (is(name, "save")) {
        // `x | save path`, or the redirect form (path, rendered text).
        if (args.len < 1) return it.fail("save: path expected", .{});
        var text: std.ArrayList(u8) = .empty;
        if (args.len >= 2) {
            try mshl.renderInline(args[1], a, &text);
        } else if (input) |v| {
            try mshl.render(v, a, &text);
        } else return it.fail("save: nothing to save", .{});
        try writeFile(it, try pathArg(it, args[0]), text.items);
        return .nothing;
    }
    if (is(name, "stat")) {
        if (args.len < 1) return it.fail("stat: path expected", .{});
        const path = try pathArg(it, args[0]);
        const t = try target(it, path);
        const st = fsc.fsStat(t.chan, t.buf, t.path) orelse return it.fail("stat: {s}: not found", .{path});
        return try statRecord(it, baseName(path), st);
    }
    if (is(name, "mkdir")) {
        if (args.len < 1) return it.fail("mkdir: path expected", .{});
        const path = try pathArg(it, args[0]);
        const t = try target(it, path);
        if (!fsc.fsMkdir(t.chan, t.buf, t.path)) return it.fail("mkdir: {s}: failed", .{path});
        return .nothing;
    }
    if (is(name, "rm")) {
        if (args.len < 1) return it.fail("rm: path expected", .{});
        const path = try pathArg(it, args[0]);
        const t = try target(it, path);
        return switch (fsc.fsDelete(t.chan, t.buf, t.path)) {
            .ok => .nothing,
            .err => |e| it.fail("rm: {s}: {t}", .{ path, e }),
        };
    }
    if (is(name, "mv")) {
        if (args.len < 2) return it.fail("mv: from and to expected", .{});
        const from = try target(it, try pathArg(it, args[0]));
        const to = try target(it, try pathArg(it, args[1]));
        if (from.chan != to.chan) return it.fail("mv: both paths must be in the same filesystem", .{});
        if (!fsc.fsRename(from.chan, from.buf, from.path, to.path)) return it.fail("mv: failed", .{});
        return .nothing;
    }
    if (is(name, "ln")) {
        if (args.len < 2) return it.fail("ln: path and target expected", .{});
        const t = try target(it, try pathArg(it, args[0]));
        if (!fsc.fsSymlink(t.chan, t.buf, t.path, try pathArg(it, args[1]))) return it.fail("ln: failed", .{});
        return .nothing;
    }
    if (is(name, "readlink")) {
        if (args.len < 1) return it.fail("readlink: path expected", .{});
        const t = try target(it, try pathArg(it, args[0]));
        const n = fsc.fsReadlink(t.chan, t.buf, t.path) orelse return it.fail("readlink: failed", .{});
        return .{ .str = try a.dupe(u8, t.buf[0..@min(n, 256)]) };
    }
    if (is(name, "sync")) {
        if (!fsc.fsSync(fs_chan)) return it.fail("sync: failed", .{});
        return .nothing;
    }
    if (is(name, "df")) {
        const st = fsc.fsStatfs(fs_chan) orelse return it.fail("df: failed", .{});
        return try record(it, &.{ "free_kb", "total_kb", "encrypted" }, &.{
            .{ .int = @intCast(st.free_blocks * 4) }, .{ .int = @intCast(st.total_blocks * 4) }, .{ .bool = st.encrypted },
        });
    }
    if (is(name, "ps")) return try psTable(it);
    if (is(name, "mem")) {
        const r = usys.sysInfo(spawner_h);
        if (r.err != .ok) return it.fail("mem: introspection denied", .{});
        return try record(it, &.{ "free_mb", "total_mb", "cores", "uptime_s" }, &.{
            .{ .int = @intCast(r.data[0] >> 20) }, .{ .int = @intCast(r.data[1] >> 20) }, .{ .int = @intCast(r.data[2]) }, .{ .int = @intCast(r.data[3] / 10) },
        });
    }
    if (is(name, "svc")) return try svcTable(it);
    if (is(name, "start") or is(name, "stop")) {
        if (args.len < 1) return it.fail("{s}: service id expected", .{name});
        const id: u64 = @intCast(try intOf(it, args[0]));
        return try svcControl(it, name, id);
    }
    if (is(name, "nodes")) return try nodesTable(it);
    if (is(name, "rspawn")) {
        if (fab_chan == 0) return it.fail("rspawn: no fabric in this session", .{});
        if (args.len < 2) return it.fail("rspawn: node and image id expected", .{});
        return try rspawn(it, @intCast(try intOf(it, args[0])), @intCast(try intOf(it, args[1])));
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
    if (is(name, "run")) {
        if (args.len < 1) return it.fail("run: program name expected", .{});
        return try cmdRun(it, try pathArg(it, args[0]), if (args.len > 1) try pathArg(it, args[1]) else "");
    }
    if (is(name, "install")) {
        if (args.len < 1) return it.fail("install: program name expected", .{});
        return try cmdInstall(it, try pathArg(it, args[0]));
    }
    if (is(name, "share")) {
        if (args.len < 3) return it.fail("share: PATH NAME USER [rw] expected", .{});
        const rw = args.len > 3 and args[3] == .str and is(args[3].str, "rw");
        return try cmdShare(it, try pathArg(it, args[0]), try pathArg(it, args[1]), try pathArg(it, args[2]), rw);
    }
    if (is(name, "unshare")) {
        if (args.len < 1) return it.fail("unshare: NAME expected", .{});
        return try cmdUnshare(it, try pathArg(it, args[0]));
    }
    if (is(name, "shares")) return try cmdShares(it);
    if (is(name, "accept")) {
        if (args.len < 1) return it.fail("accept: NAME expected", .{});
        return try cmdAccept(it, try pathArg(it, args[0]));
    }
    if (is(name, "source")) {
        if (args.len < 1) return it.fail("source: path expected", .{});
        const text = try readFile(it, try pathArg(it, args[0]));
        try it.evalScript(text, &it.out); // its output joins this line's
        return .nothing;
    }
    return null;
}

const help_text =
    \\commands (every one yields a value; pipe them):
    \\  ls [p] | tree [p] [--depth n] | stat p | cat p | write p text | save p
    \\  mkdir p | rm p | mv a b | ln p target | readlink p | df | sync
    \\  ps | mem | svc | start N | stop N | nodes | rspawn N I | rand
    \\  run NAME [path]        a program from your store (img/) or the system's, in its own domain; its result is a value
    \\  install NAME           copy a program from the system store into your own (img/)
    \\  share PATH NAME USER [rw]  offer a view of PATH in your home to USER as NAME
    \\  unshare NAME | shares  withdraw an offer (holders lose it) | list offers to and by you
    \\  accept NAME            mount an offer made to you: paths @NAME/...
    \\  source p               run a script in this session (startup: conf/msh/startup.msh)
    \\  x | to-data | save p   write a value as data; open p | from-data reads it back
    \\  def name [a b] { .. }  a function ($in is the pipeline input); fn [a] { .. } is a value; $f args calls one
    \\  use p                  a file evaluated as a module: a record of its bindings
    \\language:
    \\  x | where size > 4kb | sort-by name --desc | select name size
    \\  x | get col | first n | last n | reverse | len | keys | lines
    \\  x | map { $it * 2 } | filter { .. } | reduce 0 { $acc + $it } | any | all | find
    \\  let v = expr; $v; "text $v"; if c { } else { }; for x in list { }
    \\  while c { }; (sub | pipeline); [a, b]; { k: v }; x > path  (save rendered)
    \\  ok v | err e; r?; try { cmd }; match v { ok $x => ..; err $e => ..; [$h, ..$t] => ..; _ => .. }
    \\  str v | int text | type v | to-bytes | from-bytes   (strong types: nothing coerces)
    \\  ctrl-a/e, arrows, history, tab completes commands and paths
    \\  clear (or ctrl-l) | help | exit
;

// ------------------------------------------------------------ filesystem

fn lsTable(it: *mshl.Interp, path_arg: []const u8) mshl.Error!Value {
    const a = it.arena;
    const t = try target(it, path_arg);
    const path = t.path;
    const count = fsc.fsList(t.chan, t.buf, path) orelse return it.fail("ls: {s}: cannot list", .{path_arg});
    const names = try a.dupe(u8, t.buf[0..count]);
    var rows: std.ArrayList([]const Value) = .empty;
    var split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        var full: [256]u8 = undefined;
        const fl = joinPath(&full, path, name);
        const st = fsc.fsStat(t.chan, t.buf, full[0..fl]) orelse continue;
        const row = try a.alloc(Value, 4);
        row[0] = .{ .str = name };
        row[1] = .{ .str = typeName(st.typ) };
        row[2] = .{ .int = @intCast(st.size) };
        row[3] = .{ .int = @intCast(st.mtime) };
        try rows.append(a, row);
    }
    return .{ .table = .{ .cols = &.{ "name", "type", "size", "mtime" }, .rows = rows.items } };
}

fn treeInto(it: *mshl.Interp, text: *std.ArrayList(u8), path_arg: []const u8, indent: []const u8, depth: usize) mshl.Error!void {
    const a = it.arena;
    if (depth == 0) return;
    const t = try target(it, path_arg);
    const path = t.path;
    const count = fsc.fsList(t.chan, t.buf, path) orelse return;
    const names = try a.dupe(u8, t.buf[0..count]);
    var total: usize = 0;
    var split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |n| {
        if (n.len > 0) total += 1;
    }
    var i: usize = 0;
    split = std.mem.splitScalar(u8, names, '\n');
    while (split.next()) |name| {
        if (name.len == 0) continue;
        i += 1;
        const last = i == total;
        var full: [256]u8 = undefined;
        const fl = joinPath(&full, path, name);
        const st = fsc.fsStat(t.chan, t.buf, full[0..fl]);
        try text.appendSlice(a, indent);
        try text.appendSlice(a, if (last) "└── " else "├── ");
        try text.appendSlice(a, name);
        if (st) |s| {
            if (s.typ == @intFromEnum(shared.FsType.dir)) {
                try text.appendSlice(a, "/\n");
                const sub = try std.mem.concat(a, u8, &.{ indent, if (last) "    " else "│   " });
                try treeInto(it, text, full[0..fl], sub, depth - 1);
                continue;
            }
            if (s.typ == @intFromEnum(shared.FsType.symlink)) try text.appendSlice(a, " -> ?");
        }
        try text.append(a, '\n');
    }
}

fn readFile(it: *mshl.Interp, path: []const u8) mshl.Error![]const u8 {
    const t = try target(it, path);
    return readFileVia(it, t.chan, t.buf, t.path);
}

fn readFileVia(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8) mshl.Error![]const u8 {
    const fd = switch (fsc.fsOpen(chan, buf, path, 0)) {
        .fd => |f| f,
        .err => |e| return it.fail("cannot open {s}: {t}", .{ path, e }),
    };
    defer fsc.fsClose(chan, fd);
    var out: std.ArrayList(u8) = .empty;
    var off: u64 = 0;
    while (true) {
        const n = fsc.fsReadAt(chan, fd, off, shared.fs_max_io) orelse return it.fail("read error on {s}", .{path});
        if (n == 0) break;
        try out.appendSlice(it.arena, buf[0..n]);
        off += n;
    }
    return out.items;
}

fn writeFile(it: *mshl.Interp, path: []const u8, text: []const u8) mshl.Error!void {
    const t = try target(it, path);
    return writeFileVia(it, t.chan, t.buf, t.path, text);
}

fn writeFileVia(it: *mshl.Interp, chan: u64, buf: [*]u8, path: []const u8, text: []const u8) mshl.Error!void {
    const fd = switch (fsc.fsOpen(chan, buf, path, 1)) {
        .fd => |f| f,
        .err => |e| return it.fail("cannot open {s}: {t}", .{ path, e }),
    };
    defer fsc.fsClose(chan, fd);
    var off: usize = 0;
    while (off < text.len) {
        const n = @min(shared.fs_max_io, text.len - off);
        if (!fsc.fsWriteAt(chan, buf, fd, off, text[off .. off + n])) return it.fail("write failed on {s}", .{path});
        off += n;
    }
    if (!fsc.fsTruncate(chan, fd, text.len)) return it.fail("truncate failed on {s}", .{path});
}

fn statRecord(it: *mshl.Interp, name: []const u8, st: fsc.StatOut) mshl.Error!Value {
    return record(it, &.{ "name", "type", "size", "mtime" }, &.{
        .{ .str = name }, .{ .str = typeName(st.typ) }, .{ .int = @intCast(st.size) }, .{ .int = @intCast(st.mtime) },
    });
}

fn typeName(typ: u64) []const u8 {
    return switch (typ) {
        @intFromEnum(shared.FsType.file) => "file",
        @intFromEnum(shared.FsType.dir) => "dir",
        @intFromEnum(shared.FsType.symlink) => "symlink",
        else => "?",
    };
}

// ---------------------------------------------------------- introspection

fn psTable(it: *mshl.Interp) mshl.Error!Value {
    const a = it.arena;
    var recs: [16 * shared.DomainRec.size]u8 = undefined;
    const r = usys.domainList(spawner_h, &recs);
    if (r.err != .ok) return it.fail("ps: introspection denied", .{});
    var rows: std.ArrayList([]const Value) = .empty;
    for (0..r.data[0]) |i| {
        const rec = shared.DomainRec.decode(recs[i * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        const row = try a.alloc(Value, 8);
        row[0] = .{ .int = rec.id };
        row[1] = .{ .str = try a.dupe(u8, rec.nameSlice()) };
        row[2] = .{ .str = switch (rec.state) {
            .alive => "alive",
            .dying => "dying",
            .dead => "dead",
        } };
        row[3] = .{ .int = rec.threads };
        row[4] = .{ .int = @intCast(rec.kobj_kb >> 32) };
        row[5] = .{ .int = @intCast(rec.kobj_kb & 0xffff_ffff) };
        row[6] = .{ .int = @intCast(rec.user_kb >> 32) };
        row[7] = .{ .int = @intCast(rec.user_kb & 0xffff_ffff) };
        try rows.append(a, row);
    }
    return .{ .table = .{
        .cols = &.{ "id", "name", "state", "threads", "kobj_kb", "kobj_max", "user_kb", "user_max" },
        .rows = rows.items,
    } };
}

const svc_names = [_][]const u8{ "logsvc", "greeter" };

fn svcTable(it: *mshl.Interp) mshl.Error!Value {
    const a = it.arena;
    var rows: std.ArrayList([]const Value) = .empty;
    for (svc_names, 0..) |sname, id| {
        switch (usys.callTyped(shared.InitRequest, shared.InitReply, init_chan, .{
            .status = .{ .service = id },
        }, 0)) {
            .ok => |rep| switch (rep) {
                .svc_status => |st| {
                    const row = try a.alloc(Value, 5);
                    row[0] = .{ .int = @intCast(id) };
                    row[1] = .{ .str = sname };
                    row[2] = .{ .str = if (st.up != 0) "up" else "down" };
                    row[3] = .{ .int = @intCast(st.restarts) };
                    row[4] = .{ .int = @intCast(st.max_restarts) };
                    try rows.append(a, row);
                },
                else => return it.fail("svc: bad reply from init", .{}),
            },
            .err => return it.fail("svc: init unreachable", .{}),
        }
    }
    return .{ .table = .{ .cols = &.{ "id", "name", "state", "restarts", "max" }, .rows = rows.items } };
}

fn svcControl(it: *mshl.Interp, op: []const u8, id: u64) mshl.Error!Value {
    if (is(op, "start")) {
        switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_chan, .{
            .connect = .{ .service = id },
        }, 0)) {
            .ok => |ok| switch (ok.rep) {
                .connected => {
                    if (ok.cap != 0) _ = usys.capDrop(ok.cap); // we only wanted the side effect
                    return .{ .str = "started" };
                },
                else => return it.fail("start: init refused service {d}", .{id}),
            },
            .err => return it.fail("start: init unreachable", .{}),
        }
    }
    switch (usys.callTyped(shared.InitRequest, shared.InitReply, init_chan, .{
        .stop = .{ .service = id },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .stopped => return .{ .str = "stopped" },
            else => return it.fail("stop: init refused service {d}", .{id}),
        },
        .err => return it.fail("stop: init unreachable", .{}),
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
    var rows: std.ArrayList([]const Value) = .empty;
    const recs: [*]const u8 = @ptrFromInt(fab_buf);
    for (0..n) |i| {
        const rec = recs[i * shared.fab_member_size ..];
        const row = try a.alloc(Value, 3);
        row[0] = .{ .int = @as(i64, rec[0]) | (@as(i64, rec[1]) << 8) };
        row[1] = .{ .str = if (rec[2] != 0) "up" else "down" };
        row[2] = .{ .int = @as(i64, rec[4]) | (@as(i64, rec[5]) << 8) };
        try rows.append(a, row);
    }
    return .{ .table = .{ .cols = &.{ "id", "state", "free_mb" }, .rows = rows.items } };
}

fn rspawn(it: *mshl.Interp, node: u64, image: u64) mshl.Error!Value {
    switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{
        .remote_spawn = .{ .node = node, .image = image, .arg = 2 },
    }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .spawned => |sp| {
                if (ok.cap == 0) return it.fail("rspawn: no channel came back", .{});
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
                return try record(it, &.{ "node", "rpc_40_plus_2" }, &.{ .{ .int = @intCast(sp.node) }, .{ .int = sum } });
            },
            .fab_err => |e| return it.fail("rspawn: fabric refused ({t})", .{@as(shared.FabErr, @enumFromInt(e.code))}),
            else => return it.fail("rspawn: failed", .{}),
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

fn sessErr(it: *mshl.Interp, what: []const u8, resp: shared.SessResp) mshl.Error {
    return switch (resp) {
        .sess_err => |e| switch (e.code) {
            2 => it.fail("{s}: no such share", .{what}),
            5 => it.fail("{s}: not allowed from here", .{what}),
            6 => it.fail("{s}: bad name, or no such user", .{what}),
            7 => it.fail("{s}: you already share something by that name", .{what}),
            8 => it.fail("{s}: already accepted", .{what}),
            else => it.fail("{s}: refused ({d})", .{ what, e.code }),
        },
        .denied => it.fail("{s}: denied", .{what}),
        else => it.fail("{s}: unexpected answer", .{what}),
    };
}

fn cmdShare(it: *mshl.Interp, path: []const u8, name: []const u8, user: []const u8, rw: bool) mshl.Error!Value {
    if (sess_chan == 0) return it.fail("share: no session manager here (not a user session)", .{});
    if (path.len > 0 and path[0] == '@') return it.fail("share: only paths in your own home can be shared", .{});
    if (name.len == 0 or name.len > 16 or user.len == 0 or user.len > 16) return it.fail("share: NAME and USER are at most 16 characters", .{});
    const d = fsc.fsDeriveBadged(fs_chan, fs_buf, path, !rw) orelse return it.fail("share: no such path: {s}", .{path});
    const nw = sessWord(0, name);
    const uw = sessWord(64, user);
    const res = usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .share = .{ .name = nw, .user = uw, .badge = d.badge } }, d.cap);
    _ = usys.capDrop(d.cap); // the manager's copy (or nobody's) carries on
    switch (res) {
        .ok => |rep| if (rep != .ok) return sessErr(it, "share", rep),
        .err => |e| return it.fail("share: {t}", .{e}),
    }
    return .nothing;
}

fn cmdUnshare(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    if (sess_chan == 0) return it.fail("unshare: no session manager here", .{});
    if (name.len == 0 or name.len > 16) return it.fail("unshare: NAME is at most 16 characters", .{});
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .unshare = .{ .name = sessWord(0, name) } }, 0)) {
        .ok => |rep| if (rep != .ok) return sessErr(it, "unshare", rep),
        .err => |e| return it.fail("unshare: {t}", .{e}),
    }
    return .nothing;
}

fn cmdShares(it: *mshl.Interp) mshl.Error!Value {
    if (sess_chan == 0) return it.fail("shares: no session manager here", .{});
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .shares, 0)) {
        .ok => |rep| switch (rep) {
            .data => |d| {
                const text = try it.arena.dupe(u8, sess_buf[0..@min(d.len, 4096)]);
                return try mshl.tableize(it.arena, try it.parseData(text));
            },
            else => return sessErr(it, "shares", rep),
        },
        .err => |e| return it.fail("shares: {t}", .{e}),
    }
}

fn cmdAccept(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    if (sess_chan == 0) return it.fail("accept: no session manager here", .{});
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
    const m = slot orelse return it.fail("accept: no room for another share (at most {d})", .{max_mounts});
    switch (usys.callTypedCap(shared.SessReq, shared.SessResp, sess_chan, .{ .accept = .{ .name = sessWord(0, name) } }, 0)) {
        .ok => |ok| {
            if (ok.rep != .ok) return sessErr(it, "accept", ok.rep);
            if (ok.cap == 0) return it.fail("accept: the manager sent no view", .{});
            m.* = .{ .used = true, .len = name.len, .chan = ok.cap, .buf = @ptrFromInt(fsc.attachBuf(ok.cap).va) };
            @memcpy(m.name[0..name.len], name);
        },
        .err => |e| return it.fail("accept: {t}", .{e}),
    }
    return .nothing;
}

/// A program found in a store: which store, its digest, its manifest.
const Program = struct { store: Store, digest: [shared.img_digest_hex_len]u8, manifest: Value };

/// `img/<name>.msh` in the user's own store, then the system's.
fn findProgram(it: *mshl.Interp, name: []const u8) mshl.Error!?Program {
    const stores = [_]?Store{ own_store, sys_store };
    for (stores) |maybe| {
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

fn cmdRun(it: *mshl.Interp, name: []const u8, path: []const u8) mshl.Error!Value {
    const prog = (try findProgram(it, name)) orelse return it.fail("run: no such program: {s} (not in your store, nor the system's)", .{name});
    const len = readIntoStageVia(prog.store.chan, prog.store.buf, &prog.digest) orelse return it.fail("run: image unreadable in {s}", .{prog.store.name});
    if (!run_stage.verify(len, &prog.digest)) return it.fail("run: image does not match its digest; refusing", .{});

    // The manifest says what the program is handed: kernel grants and
    // views (a view path of `arg` is the run argument). The console is
    // always ours to give.
    var flags: u64 = shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a;
    var view: u64 = 0;
    var run_arg: u64 = 0;
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
                const fs_path = item.record.get("fs") orelse continue;
                if (fs_path != .str) continue;
                const p = if (is(fs_path.str, "arg")) path else fs_path.str;
                var ro = true;
                if (item.record.get("ro")) |r| ro = r.asBool();
                const t = try target(it, p);
                view = fsc.fsDerive(t.chan, t.buf, t.path, ro) orelse return it.fail("run: no such path: {s}", .{p});
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
        return it.fail("run: spawn refused ({t})", .{sp.err});
    }
    const bch = ch.data[1];
    // A clean result buffer: the program's value comes back through it.
    @memset(@as([*]u8, @ptrFromInt(run_out_va))[0 .. run_out_pages * 4096], 0);
    var ok = boot.giveCap(bch, .console, cons_chan) and boot.giveCap(bch, .console_buf, cons_shm_h) and boot.giveCap(bch, .out, run_out_h);
    if (ok and view != 0) ok = boot.giveCap(bch, .view, view);
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
    if (n == 0) return .nothing;
    const text = try it.arena.dupe(u8, out_bytes[0..n]);
    return try mshl.tableize(it.arena, try it.parseData(text));
}

/// `install NAME`: the program's image and manifest, copied from the
/// system store into the user's own — the image verified against its
/// digest on the way, present images skipped (the name IS the content).
/// From then on `run NAME` finds it in the user's store first.
fn cmdInstall(it: *mshl.Interp, name: []const u8) mshl.Error!Value {
    const own = own_store orelse return it.fail("install: this shell has no store of its own (no img/ here)", .{});
    const sys = sys_store orelse return it.fail("install: no system store to install from", .{});
    var mpath: [64]u8 = undefined;
    if (name.len + shared.img_manifest_ext.len > mpath.len) return it.fail("install: name too long", .{});
    @memcpy(mpath[0..name.len], name);
    @memcpy(mpath[name.len .. name.len + shared.img_manifest_ext.len], shared.img_manifest_ext);
    const mp = mpath[0 .. name.len + shared.img_manifest_ext.len];
    const text = readFileVia(it, sys.chan, sys.buf, mp) catch return it.fail("install: no such program in the system store: {s}", .{name});
    const v = try it.parseData(text);
    if (v != .record) return it.fail("install: {s}: the manifest is not a record", .{name});
    const img = v.record.get("image") orelse return it.fail("install: {s}: manifest names no image", .{name});
    if (img != .str or img.str.len != shared.img_digest_hex_len) return it.fail("install: {s}: manifest image is not a digest", .{name});
    var digest: [shared.img_digest_hex_len]u8 = undefined;
    @memcpy(&digest, img.str);
    const len = readIntoStageVia(sys.chan, sys.buf, &digest) orelse return it.fail("install: image unreadable in the system store", .{});
    if (!run_stage.verify(len, &digest)) return it.fail("install: image does not match its digest; refusing", .{});
    if (fsc.fsStat(own.chan, own.buf, &digest) == null) {
        try writeFileVia(it, own.chan, own.buf, &digest, run_stage.slice(len));
    }
    try writeFileVia(it, own.chan, own.buf, mp, text);
    var l: tty.Line = .{};
    _ = l.str("installed ").str(name).str(" into your store");
    l.flush();
    return .nothing;
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

fn record(it: *mshl.Interp, keys: []const []const u8, vals: []const Value) mshl.Error!Value {
    return .{ .record = .{ .keys = keys, .vals = try it.arena.dupe(Value, vals) } };
}

fn pathArg(it: *mshl.Interp, v: Value) mshl.Error![]const u8 {
    return switch (v) {
        .str => |s| s,
        .int => |i| std.fmt.allocPrint(it.arena, "{d}", .{i}) catch return error.OutOfMemory,
        else => it.fail("path expected, got a {s}", .{v.typeName()}),
    };
}

fn intOf(it: *mshl.Interp, v: Value) mshl.Error!i64 {
    return switch (v) {
        .int => |i| i,
        .str => |s| std.fmt.parseInt(i64, s, 10) catch it.fail("number expected, got '{s}'", .{s}),
        else => it.fail("number expected, got a {s}", .{v.typeName()}),
    };
}

fn joinPath(out: *[256]u8, dir: []const u8, name: []const u8) usize {
    var n: usize = 0;
    if (dir.len > 0) {
        const d = @min(dir.len, out.len - 1);
        @memcpy(out[0..d], dir[0..d]);
        n = d;
        out[n] = '/';
        n += 1;
    }
    const k = @min(name.len, out.len - n);
    @memcpy(out[n .. n + k], name[0..k]);
    return n + k;
}

fn baseName(path: []const u8) []const u8 {
    var i = path.len;
    while (i > 0 and path[i - 1] != '/') i -= 1;
    return path[i..];
}

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

fn is(a: []const u8, b: []const u8) bool {
    return std.mem.eql(u8, a, b);
}
