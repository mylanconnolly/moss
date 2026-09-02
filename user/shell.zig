//! msh — the moss shell. An ordinary user process holding exactly the
//! capabilities a developer console needs: a console channel (virtio
//! console driver), a filesystem view (the same badged view protocol as
//! everyone else), an init front channel (service control), and a
//! spawner cap (which gates the kernel's typed introspection: domain
//! records and system stats — the mossctl functionality, as builtins).
//!
//! Startup handshake: msh serves its spawn channel; the boot driver
//! calls in three messages, each carrying one cap, in fixed order —
//! console channel, fs view, init front — then msh prints the banner.
//!
//! Everything is typed IPC end to end; the only text in the system is
//! what msh renders for the human.

const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const loader = @import("loader.zig");
const tty = @import("tty.zig");
const Line = tty.Line;
const out = tty.out;
const digits = tty.digits;

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

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// Grant slots (insert order log -> chan -> spawner).
const spawner_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

var cons_chan: u64 = 0;
var cons_buf: u64 = 0; // 1-page byte buffer shared with the console driver
var cons_shm_h: u64 = 0; // its cap: run tools get the same buffer
var run_stage: loader.Stage = undefined;
var fs_chan: u64 = 0;
var fs_buf: [*]u8 = undefined;
var init_chan: u64 = 0;
var fab_chan: u64 = 0;
var fab_buf: u64 = 0; // attached lazily on first `nodes`
var glog: u64 = 0;

export fn umain(log_h: u64, boot_chan: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;

    // Cap intake: four calls from the boot driver, one cap each.
    var caps: [4]u64 = undefined;
    for (&caps) |*c| {
        const r = usys.recvMsg(boot_chan);
        if (r.err != .ok or r.cap == 0) usys.exit(140);
        c.* = r.cap;
        _ = usys.replyRaw(boot_chan, .{ 0, 0, 0, 0 }, 0);
    }
    cons_chan = caps[0];
    fs_chan = caps[1];
    init_chan = caps[2];
    fab_chan = caps[3];

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

    // Filesystem view buffer.
    const b = fsc.attachBuf(fs_chan);
    fs_buf = @ptrFromInt(b.va);

    _ = usys.log(log_h, "msh: up, serving the console");
    out("\r\nmoss shell — 'help' lists commands\r\n");
    repl();
}

fn repl() noreturn {
    var line: [256]u8 = undefined;
    while (true) {
        out("msh> ");
        const n = readLine(&line);
        const cmd = trim(line[0..n]);
        if (cmd.len == 0) continue;
        dispatch(cmd);
    }
}

// ------------------------------------------------------------- line input

fn readLine(line: []u8) usize {
    var n: usize = 0;
    while (true) {
        const got = consRead(64);
        var echo: [192]u8 = undefined;
        var e: usize = 0;
        const src: [*]const volatile u8 = @ptrFromInt(cons_buf);
        var done = false;
        for (0..got) |i| {
            const c = src[i];
            switch (c) {
                '\r', '\n' => {
                    echo[e] = '\r';
                    echo[e + 1] = '\n';
                    e += 2;
                    done = true;
                    break;
                },
                0x7f, 0x08 => {
                    if (n > 0) {
                        n -= 1;
                        @memcpy(echo[e .. e + 3], "\x08 \x08");
                        e += 3;
                    }
                },
                0x03 => { // ctrl-c: abandon the line
                    @memcpy(echo[e .. e + 4], "^C\r\n");
                    e += 4;
                    n = 0;
                    done = true;
                    break;
                },
                else => {
                    if (c >= 0x20 and c < 0x7f and n < line.len) {
                        line[n] = c;
                        n += 1;
                        echo[e] = c;
                        e += 1;
                    }
                },
            }
        }
        if (e > 0) out(echo[0..e]);
        if (done) return n;
    }
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

// ------------------------------------------------------------ line output

// -------------------------------------------------------------- dispatch

fn dispatch(cmd: []const u8) void {
    var args: [4][]const u8 = undefined;
    const argc = split(cmd, &args);
    const c0 = args[0];

    if (eq(c0, "help")) return cmdHelp();
    if (eq(c0, "ps")) return cmdPs();
    if (eq(c0, "mem")) return cmdMem();
    if (eq(c0, "svc")) return cmdSvc();
    if (eq(c0, "nodes")) return cmdNodes();
    if (eq(c0, "rspawn") and argc >= 3) return cmdRspawn(args[1], args[2]);
    if (eq(c0, "start") and argc >= 2) return cmdStart(args[1]);
    if (eq(c0, "stop") and argc >= 2) return cmdStop(args[1]);
    if (eq(c0, "ls")) return cmdLs(if (argc >= 2) args[1] else "");
    if (eq(c0, "cat") and argc >= 2) return cmdCat(args[1]);
    if (eq(c0, "write") and argc >= 3) return cmdWrite(args[1], rest(cmd, args[2]));
    if (eq(c0, "mkdir") and argc >= 2) return cmdMkdir(args[1]);
    if (eq(c0, "rm") and argc >= 2) return cmdRm(args[1]);
    if (eq(c0, "mv") and argc >= 3) return cmdMv(args[1], args[2]);
    if (eq(c0, "ln") and argc >= 3) return cmdLn(args[1], args[2]);
    if (eq(c0, "readlink") and argc >= 2) return cmdReadlink(args[1]);
    if (eq(c0, "stat") and argc >= 2) return cmdStat(args[1]);
    if (eq(c0, "df")) return cmdDf();
    if (eq(c0, "sync")) return cmdSync();
    if (eq(c0, "rand")) return cmdRand();
    if (eq(c0, "run") and argc >= 2) return cmdRun(args[1], if (argc >= 3) args[2] else "");
    if (eq(c0, "exit")) {
        out("bye\r\n");
        usys.exit(0);
    }
    out("unknown command (try 'help')\r\n");
}

fn cmdHelp() void {
    out("commands:\r\n" ++
        "  ps                    domains: state, threads, budgets\r\n" ++
        "  mem                   physical memory, cores, uptime\r\n" ++
        "  svc | start N | stop N   services via init\r\n" ++
        "  nodes                 fabric membership (id, state, free MB)\r\n" ++
        "  rspawn N I            spawn image I on node N (0 = least loaded)\r\n" ++
        "  ls [p] | cat p | write p text... | mkdir p | rm p\r\n" ++
        "  mv a b | ln p target | readlink p | stat p | df | sync\r\n" ++
        "  rand                  16 bytes from the kernel CSPRNG (getrandom)\r\n" ++
        "  run NAME [path]       run a program from img/ in its own domain\r\n" ++
        "  exit\r\n");
}

// -------------------------------------------------------------------- run
//
// `run NAME [path]`: a program from the content-addressed img/ store gets
// its own domain with exactly what its kind needs — the console, and for
// a path-taking tool a view of that path alone — then msh waits for it to
// exit. The image is read through msh's view, verified against its
// digest, and spawned from msh's stage. Manifest knowledge lives here
// for now (a manifest file per image is the evolution).

const RunKind = struct { name: []const u8, introspect: bool = false, view: bool = false, ro: bool = true };
const run_kinds = [_]RunKind{
    .{ .name = "ps", .introspect = true },
    .{ .name = "ls", .view = true },
};

fn cmdRun(name: []const u8, path: []const u8) void {
    var digest: [shared.img_digest_hex_len]u8 = undefined;
    if (!indexLookup(name, &digest)) return out("run: no such image in img/index\r\n");
    var img_path: [4 + shared.img_digest_hex_len]u8 = undefined;
    @memcpy(img_path[0..4], "img/");
    @memcpy(img_path[4..], &digest);
    const len = readIntoStage(&img_path) orelse return out("run: image unreadable\r\n");
    if (!run_stage.verify(len, &digest)) return out("run: image does not match its digest; refusing\r\n");

    var kind: RunKind = .{ .name = name };
    for (run_kinds) |k| {
        if (eq(k.name, name)) kind = k;
    }
    var view: u64 = 0;
    if (kind.view) {
        view = fsc.fsDerive(fs_chan, fs_buf, path, kind.ro) orelse return out("run: no such path\r\n");
    }

    // The tool serves side A of its boot channel; we feed it caps on B.
    const ch = usys.chanCreate();
    if (ch.err != .ok) return out("run: out of channels\r\n");
    var flags: u64 = shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a;
    if (kind.introspect) flags |= shared.SpawnFlags.grant_introspect;
    const sp = usys.spawn(spawner_h, run_stage.handle, 0, ch.data[0], flags, usys.kbLimits(512, 2 << 10));
    _ = usys.capDrop(ch.data[0]);
    if (sp.err != .ok) {
        _ = usys.capDrop(ch.data[1]);
        if (view != 0) _ = usys.capDrop(view);
        return out("run: spawn refused\r\n");
    }
    const boot = ch.data[1];
    var ok = runSend(boot, .console, cons_chan) and runSend(boot, .console_buf, cons_shm_h);
    if (ok and view != 0) ok = runSend(boot, .view, view);
    if (ok) {
        const w = shared.strToWords(path);
        ok = runSend(boot, .{ .arg = .{ .a = w[0], .b = w[1], .c = w[2] } }, 0);
    }
    if (ok) ok = runSend(boot, .go, 0);
    if (!ok) out("run: the program did not take its setup\r\n");

    // The console is the tool's until it exits.
    while (true) {
        const st = usys.domainStat(sp.data[0]);
        if (st.err != .ok or st.data[0] == @intFromEnum(shared.DomainState.dead)) {
            if (st.err == .ok and st.data[1] != 0) {
                var l: Line = .{};
                _ = l.str("run: ").str(name).str(" exited with code ").num(st.data[1]);
                l.flush();
            }
            break;
        }
        usys.sleep(1);
    }
    _ = usys.capDrop(sp.data[0]);
    _ = usys.capDrop(boot);
    if (view != 0) _ = usys.capDrop(view);
}

fn runSend(boot: u64, req: shared.RunReq, cap: u64) bool {
    return switch (usys.callTyped(shared.RunReq, shared.RunResp, boot, req, cap)) {
        .ok => true,
        .err => false,
    };
}

/// img/index: "name digest" lines.
fn indexLookup(name: []const u8, digest: *[shared.img_digest_hex_len]u8) bool {
    const fd = switch (fsc.fsOpen(fs_chan, fs_buf, shared.img_index_path, 0)) {
        .fd => |fd| fd,
        .err => return false,
    };
    defer fsc.fsClose(fs_chan, fd);
    const n = fsc.fsRead(fs_chan, fd, shared.fs_max_io) orelse return false;
    var text: [4096]u8 = undefined;
    const m = @min(n, text.len);
    @memcpy(text[0..m], fs_buf[0..m]);
    var lines = text[0..m];
    while (lines.len > 0) {
        var eol: usize = 0;
        while (eol < lines.len and lines[eol] != '\n') eol += 1;
        const line = lines[0..eol];
        lines = if (eol == lines.len) "" else lines[eol + 1 ..];
        var sp: usize = 0;
        while (sp < line.len and line[sp] != ' ') sp += 1;
        if (sp == line.len or line.len - sp - 1 != shared.img_digest_hex_len) continue;
        if (eq(line[0..sp], name)) {
            @memcpy(digest, line[sp + 1 ..]);
            return true;
        }
    }
    return false;
}

/// Read a file through the view buffer into the run stage; returns its length.
fn readIntoStage(path: []const u8) ?usize {
    const fd = switch (fsc.fsOpen(fs_chan, fs_buf, path, 0)) {
        .fd => |fd| fd,
        .err => return null,
    };
    defer fsc.fsClose(fs_chan, fd);
    var off: usize = 0;
    while (off < run_stage.bytes) {
        const n = fsc.fsReadAt(fs_chan, fd, off, @min(shared.fs_max_io, run_stage.bytes - off)) orelse return null;
        if (n == 0) break;
        @memcpy(run_stage.slice(off + n)[off..], fs_buf[0..n]);
        off += n;
    }
    return off;
}

// --------------------------------------------------------- introspection

fn cmdPs() void {
    var recs: [16 * shared.DomainRec.size]u8 = undefined;
    const r = usys.domainList(spawner_h, &recs);
    if (r.err != .ok) return out("ps: introspection denied\r\n");
    tty.domainTable(&recs, r.data[0]);
}

fn cmdMem() void {
    const r = usys.sysInfo(spawner_h);
    if (r.err != .ok) return out("mem: introspection denied\r\n");
    var l: Line = .{};
    _ = l.str("pmem: ").num(r.data[0] >> 20).str(" MB free of ").num(r.data[1] >> 20).str(" MB");
    l.flush();
    _ = l.str("cores: ").num(r.data[2]).str("   uptime: ").num(r.data[3] / 10).str("s");
    l.flush();
}

/// getrandom needs no capability at all — the one ambient syscall besides
/// the counter, because random bytes are authority over nothing.
fn cmdRand() void {
    var bytes: [16]u8 = undefined;
    const e = usys.getrandom(&bytes);
    if (e == .bad_state) return out("rand failed: kernel pool unseeded (no rngd)\r\n");
    if (e != .ok) return out("rand failed\r\n");
    var l: Line = .{};
    _ = l.str("rand: ").hex(&bytes);
    l.flush();
}

// -------------------------------------------------------------- services

const svc_names = [_][]const u8{ "logsvc", "greeter" };

fn cmdSvc() void {
    var l: Line = .{};
    _ = l.str("  ID NAME      STATE  RESTARTS");
    l.flush();
    for (svc_names, 0..) |name, id| {
        switch (usys.callTyped(shared.InitRequest, shared.InitReply, init_chan, .{
            .status = .{ .service = id },
        }, 0)) {
            .ok => |rep| switch (rep) {
                .svc_status => |st| {
                    _ = l.pad(3).num(id).str(" ").str(name);
                    _ = l.pad(14).str(if (st.up != 0) "up" else "down");
                    _ = l.pad(21).num(st.restarts).str("/").num(st.max_restarts);
                    l.flush();
                },
                else => out("svc: bad reply\r\n"),
            },
            .err => out("svc: init unreachable\r\n"),
        }
    }
}

fn cmdStart(arg: []const u8) void {
    const id = atoi(arg) orelse return out("start: bad service id\r\n");
    switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, init_chan, .{
        .connect = .{ .service = id },
    }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .connected => {
                // We only wanted the start side effect; drop the channel.
                if (ok.cap != 0) _ = usys.capDrop(ok.cap);
                out("started\r\n");
            },
            else => out("start: failed\r\n"),
        },
        .err => out("start: init unreachable\r\n"),
    }
}

fn cmdStop(arg: []const u8) void {
    const id = atoi(arg) orelse return out("stop: bad service id\r\n");
    switch (usys.callTyped(shared.InitRequest, shared.InitReply, init_chan, .{
        .stop = .{ .service = id },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .stopped => out("stopped\r\n"),
            else => out("stop: failed\r\n"),
        },
        .err => out("stop: init unreachable\r\n"),
    }
}

// ----------------------------------------------------------------- fabric

fn fabAttach() bool {
    if (fab_buf != 0) return true;
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

fn cmdNodes() void {
    if (!fabAttach()) return out("nodes: fabric unreachable\r\n");
    const n = switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .members, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| x.n,
            else => return out("nodes: bad reply\r\n"),
        },
        .err => return out("nodes: fabric unreachable\r\n"),
    };
    var l: Line = .{};
    _ = l.str("  ID STATE  FREE MB");
    l.flush();
    const recs: [*]const u8 = @ptrFromInt(fab_buf);
    for (0..n) |i| {
        const rec = recs[i * shared.fab_member_size ..];
        const id = @as(u64, rec[0]) | (@as(u64, rec[1]) << 8);
        const up = rec[2] != 0;
        const free = @as(u64, rec[4]) | (@as(u64, rec[5]) << 8);
        _ = l.pad(3).num(id);
        _ = l.pad(5).str(if (up) "up" else "down");
        _ = l.pad(12).num(free);
        l.flush();
    }
}

fn cmdRspawn(node_s: []const u8, image_s: []const u8) void {
    const node = atoi(node_s) orelse return out("rspawn: bad node\r\n");
    const image = atoi(image_s) orelse return out("rspawn: bad image id\r\n");
    switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{
        .remote_spawn = .{ .node = node, .image = image, .arg = 2 },
    }, 0)) {
        .ok => |ok| switch (ok.rep) {
            .spawned => |sp| {
                if (ok.cap == 0) return out("rspawn: no channel\r\n");
                // Prove the remote channel with a typed RPC through it.
                const r = usys.callRaw(ok.cap, shared.encodeMsg(shared.CalcRequest, .{
                    .add = .{ .a = 40, .b = 2 },
                }), 0);
                var l: Line = .{};
                if (r.err == .ok and r.data[0] != shared.fabric_err_sentinel) {
                    if (shared.decodeMsg(shared.CalcReply, r.data)) |crep| {
                        if (crep == .sum) {
                            _ = l.str("spawned on node ").num(sp.node)
                                .str("; remote says 40+2=").num(crep.sum.value);
                            l.flush();
                            _ = usys.capDrop(ok.cap);
                            return;
                        }
                    }
                }
                _ = l.str("spawned on node ").num(sp.node).str(" but the RPC failed");
                l.flush();
                _ = usys.capDrop(ok.cap);
            },
            else => out("rspawn: failed\r\n"),
        },
        .err => out("rspawn: fabric unreachable\r\n"),
    }
}

// ------------------------------------------------------------- filesystem

fn cmdLs(path: []const u8) void {
    const n = fsc.fsList(fs_chan, fs_buf, path) orelse return out("ls: error\r\n");
    if (n == 0) return out("(empty)\r\n");
    var tmp: [2048]u8 = undefined;
    for (0..n) |i| tmp[i] = if (fs_buf[i] == '\n') '\n' else fs_buf[i];
    // Console wants \r\n.
    var o: usize = 0;
    var lineb: [2100]u8 = undefined;
    for (tmp[0..n]) |c| {
        if (c == '\n') {
            lineb[o] = '\r';
            o += 1;
        }
        lineb[o] = c;
        o += 1;
    }
    out(lineb[0..o]);
}

fn cmdCat(path: []const u8) void {
    const fd = switch (fsc.fsOpen(fs_chan, fs_buf, path, 0)) {
        .fd => |f| f,
        .err => return out("cat: cannot open\r\n"),
    };
    defer fsc.fsClose(fs_chan, fd);
    var off: u64 = 0;
    var tmp: [2048]u8 = undefined;
    while (true) {
        const n = fsc.fsReadAt(fs_chan, fd, off, 2048) orelse return out("cat: read error\r\n");
        if (n == 0) break;
        for (0..n) |i| tmp[i] = fs_buf[i];
        out(tmp[0..n]);
        off += n;
    }
    out("\r\n");
}

fn cmdWrite(path: []const u8, text: []const u8) void {
    const fd = switch (fsc.fsOpen(fs_chan, fs_buf, path, 1)) {
        .fd => |f| f,
        .err => return out("write: cannot open\r\n"),
    };
    defer fsc.fsClose(fs_chan, fd);
    if (!fsc.fsWrite(fs_chan, fs_buf, fd, text)) return out("write: failed\r\n");
    if (!fsc.fsTruncate(fs_chan, fd, text.len)) return out("write: truncate failed\r\n");
    out("ok\r\n");
}

fn cmdMkdir(path: []const u8) void {
    if (fsc.fsMkdir(fs_chan, fs_buf, path)) out("ok\r\n") else out("mkdir: failed\r\n");
}

fn cmdRm(path: []const u8) void {
    switch (fsc.fsDelete(fs_chan, fs_buf, path)) {
        .ok => out("ok\r\n"),
        .err => out("rm: failed\r\n"),
    }
}

fn cmdMv(from: []const u8, to: []const u8) void {
    if (fsc.fsRename(fs_chan, fs_buf, from, to)) out("ok\r\n") else out("mv: failed\r\n");
}

fn cmdLn(path: []const u8, target: []const u8) void {
    if (fsc.fsSymlink(fs_chan, fs_buf, path, target)) out("ok\r\n") else out("ln: failed\r\n");
}

fn cmdReadlink(path: []const u8) void {
    const n = fsc.fsReadlink(fs_chan, fs_buf, path) orelse return out("readlink: failed\r\n");
    var tmp: [256]u8 = undefined;
    const k = @min(n, tmp.len);
    for (0..k) |i| tmp[i] = fs_buf[i];
    out(tmp[0..k]);
    out("\r\n");
}

fn cmdStat(path: []const u8) void {
    const st = fsc.fsStat(fs_chan, fs_buf, path) orelse return out("stat: not found\r\n");
    var l: Line = .{};
    _ = l.str(switch (st.typ) {
        @intFromEnum(shared.FsType.file) => "file",
        @intFromEnum(shared.FsType.dir) => "dir",
        @intFromEnum(shared.FsType.symlink) => "symlink",
        else => "?",
    }).str("  size ").num(st.size).str("  mtime ").num(st.mtime);
    l.flush();
}

fn cmdDf() void {
    const st = fsc.fsStatfs(fs_chan) orelse return out("df: failed\r\n");
    var l: Line = .{};
    _ = l.num(st.free_blocks * 4).str(" KB free of ").num(st.total_blocks * 4).str(" KB");
    _ = l.str(if (st.encrypted) "  (encrypted)" else "");
    l.flush();
}

fn cmdSync() void {
    if (fsc.fsSync(fs_chan)) out("ok\r\n") else out("sync: failed\r\n");
}

// ------------------------------------------------------------- utilities

fn split(s: []const u8, out_args: *[4][]const u8) usize {
    var n: usize = 0;
    var i: usize = 0;
    while (i < s.len and n < 4) {
        while (i < s.len and s[i] == ' ') i += 1;
        if (i >= s.len) break;
        const start = i;
        while (i < s.len and s[i] != ' ') i += 1;
        out_args[n] = s[start..i];
        n += 1;
    }
    return n;
}

/// Everything from token `from` to the end of the command (for `write`'s
/// free text argument, spaces preserved).
fn rest(cmd: []const u8, from: []const u8) []const u8 {
    const off = @intFromPtr(from.ptr) - @intFromPtr(cmd.ptr);
    return cmd[off..];
}

fn trim(s: []const u8) []const u8 {
    var a: usize = 0;
    var b: usize = s.len;
    while (a < b and (s[a] == ' ' or s[a] == '\r' or s[a] == '\n')) a += 1;
    while (b > a and (s[b - 1] == ' ' or s[b - 1] == '\r' or s[b - 1] == '\n')) b -= 1;
    return s[a..b];
}

fn eq(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn atoi(s: []const u8) ?u64 {
    if (s.len == 0) return null;
    var v: u64 = 0;
    for (s) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
    }
    return v;
}
