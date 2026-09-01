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
var fs_chan: u64 = 0;
var fs_buf: [*]u8 = undefined;
var init_chan: u64 = 0;
var glog: u64 = 0;

export fn umain(log_h: u64, boot_chan: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;

    // Cap intake: three calls from the boot driver, one cap each.
    var caps: [3]u64 = undefined;
    for (&caps) |*c| {
        const r = usys.recvMsg(boot_chan);
        if (r.err != .ok or r.cap == 0) usys.exit(140);
        c.* = r.cap;
        _ = usys.replyRaw(boot_chan, .{ 0, 0, 0, 0 }, 0);
    }
    cons_chan = caps[0];
    fs_chan = caps[1];
    init_chan = caps[2];

    // Console byte buffer.
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(141);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(142);
    cons_buf = m.data[0];
    switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons_chan, .setup, s.data[0])) {
        .ok => {},
        .err => usys.exit(143),
    }

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

fn out(s: []const u8) void {
    var off: usize = 0;
    while (off < s.len) {
        const chunk = @min(s.len - off, 2048);
        const dst: [*]volatile u8 = @ptrFromInt(cons_buf);
        for (0..chunk) |i| dst[i] = s[off + i];
        switch (usys.callTyped(shared.ConsReq, shared.ConsResp, cons_chan, .{
            .write = .{ .len = chunk },
        }, 0)) {
            .ok => {},
            .err => usys.exit(146),
        }
        off += chunk;
    }
}

const Line = struct {
    buf: [256]u8 = undefined,
    n: usize = 0,

    fn str(l: *Line, s: []const u8) *Line {
        const k = @min(s.len, l.buf.len - l.n);
        @memcpy(l.buf[l.n .. l.n + k], s[0..k]);
        l.n += k;
        return l;
    }

    fn num(l: *Line, v: u64) *Line {
        var ds: [20]u8 = undefined;
        var d: usize = 0;
        var x = v;
        while (true) {
            ds[d] = '0' + @as(u8, @intCast(x % 10));
            d += 1;
            x /= 10;
            if (x == 0) break;
        }
        while (d > 0) {
            d -= 1;
            _ = l.str(ds[d .. d + 1]);
        }
        return l;
    }

    /// Right-pad with spaces to column `col` (from line start).
    fn pad(l: *Line, col: usize) *Line {
        while (l.n < col and l.n < l.buf.len) {
            l.buf[l.n] = ' ';
            l.n += 1;
        }
        return l;
    }

    fn flush(l: *Line) void {
        _ = l.str("\r\n");
        out(l.buf[0..l.n]);
        l.n = 0;
    }
};

// -------------------------------------------------------------- dispatch

fn dispatch(cmd: []const u8) void {
    var args: [4][]const u8 = undefined;
    const argc = split(cmd, &args);
    const c0 = args[0];

    if (eq(c0, "help")) return cmdHelp();
    if (eq(c0, "ps")) return cmdPs();
    if (eq(c0, "mem")) return cmdMem();
    if (eq(c0, "svc")) return cmdSvc();
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
        "  ls [p] | cat p | write p text... | mkdir p | rm p\r\n" ++
        "  mv a b | ln p target | readlink p | stat p | df | sync\r\n" ++
        "  exit\r\n");
}

// --------------------------------------------------------- introspection

fn cmdPs() void {
    var recs: [16 * shared.DomainRec.size]u8 = undefined;
    const r = usys.domainList(spawner_h, &recs);
    if (r.err != .ok) return out("ps: introspection denied\r\n");
    var l: Line = .{};
    _ = l.str("  ID NAME             ST     THR  KOBJ KB (used/max)  USER KB (used/max)");
    l.flush();
    for (0..r.data[0]) |i| {
        const rec = shared.DomainRec.decode(recs[i * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        const w = digits(rec.id);
        if (w < 4) _ = l.pad(4 - w);
        _ = l.num(rec.id).str(" ").str(rec.nameSlice());
        _ = l.pad(21).str(switch (rec.state) {
            .alive => "alive",
            .dying => "dying",
            .dead => "dead",
        });
        _ = l.pad(28).num(rec.threads);
        _ = l.pad(33).num(rec.kobj_kb >> 32).str("/").num(rec.kobj_kb & 0xffff_ffff);
        _ = l.pad(53).num(rec.user_kb >> 32).str("/").num(rec.user_kb & 0xffff_ffff);
        l.flush();
    }
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

fn digits(v: u64) usize {
    var d: usize = 1;
    var x = v;
    while (x >= 10) : (x /= 10) d += 1;
    return d;
}
