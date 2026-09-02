//! The OS test runner: boots each test's kernel variant under QEMU with the
//! right machine configuration, watches its serial log for PASS / panic
//! markers, and enforces timeouts. Tests power themselves off (PSCI) after
//! reporting, so the normal case is a clean QEMU exit within seconds.
//!
//! Invoked by `zig build check` with (name, kernel.bin) argument pairs.
//! To add a test: give it a self-terminating driver with a unique
//! "<name>-test: PASS" line, add the build variant in build.zig, and a Spec
//! here.

const std = @import("std");
const Io = std.Io;

const Kind = enum { plain, blk, net, cluster, shell };

const Spec = struct {
    name: []const u8,
    kind: Kind = .plain,
    pass: []const u8,
    /// Additional marker that must also appear.
    extra: ?[]const u8 = null,
    /// Marker required on every run (persistence runs included).
    always_extra: ?[]const u8 = null,
    /// For panic-path tests, "KERNEL PANIC" is the point, not a failure.
    panic_is_failure: bool = true,
    /// Second run on the same disk (persistence); this marker must appear.
    second_run_extra: ?[]const u8 = null,
    /// Boot arguments (QEMU -append): the unit-file drills pick a profile.
    append: ?[]const u8 = null,
    timeout_s: u64 = 90,
};

const specs = [_]Spec{
    .{ .name = "panic", .pass = "KERNEL PANIC: panic test requested", .panic_is_failure = false },
    .{ .name = "fault", .pass = "!! EXCEPTION: cur_spx_sync", .extra = "far=0xffffff7fdead0000", .panic_is_failure = false },
    .{ .name = "sched", .pass = "sched-test: PASS" },
    .{ .name = "domain", .pass = "domain-test: PASS" },
    .{ .name = "ipc", .pass = "ipc-test: PASS" },
    .{ .name = "init", .pass = "init-test: PASS" },
    .{ .name = "sandbox", .pass = "sandbox-test: PASS" },
    .{ .name = "flap", .pass = "flap-test: PASS" },
    .{ .name = "blk", .kind = .blk, .pass = "blk-test: PASS", .append = "profile=blk" },
    .{
        .name = "fs",
        .kind = .blk,
        .pass = "fs-test: PASS",
        .extra = "formatted fresh mossfs (std hierarchy, encrypted)",
        .always_extra = "alice: v2 ops verified",
        .second_run_extra = "existing mossfs found (encrypted, key verified)",
        .append = "profile=fs",
    },
    .{ .name = "net", .kind = .net, .pass = "net-test: PASS", .append = "profile=net" },
    .{ .name = "rng", .pass = "rng-test: PASS", .extra = "rngprobe: unseeded pool refuses getrandom" },
    .{
        .name = "shell",
        .kind = .shell,
        .pass = "shell-test: PASS",
        .extra = "fabric identity born and certified",
        .second_run_extra = "fabric identity restored from state",
        .timeout_s = 120,
    },
    .{ .name = "fabric", .kind = .cluster, .pass = "fabric-test: PASS", .extra = "fabsvc: revoked identity refused", .timeout_s = 150 },
};

const check_dir = "zig-out/check";
const cluster_port = "31901";
const cluster_port2 = "31902";
const cluster_port3 = "31904"; // the imposter's hub port
const shell_port: u16 = 31903;
const poll_ms = 100;

var io: Io = undefined;
var gpa: std.mem.Allocator = undefined;
const cwd = Io.Dir.cwd();

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    gpa = init.arena.allocator();

    var argv_list: std.ArrayList([]const u8) = .empty;
    var arg_it = std.process.Args.Iterator.init(init.minimal.args);
    while (arg_it.next()) |a| try argv_list.append(gpa, try gpa.dupe(u8, a));
    const argv = argv_list.items;
    if (argv.len < 3 or (argv.len - 1) % 2 != 0) {
        std.debug.print("usage: runner <name> <kernel.bin> ...\n", .{});
        return 2;
    }
    cwd.createDirPath(io, check_dir) catch {};

    var failures: u32 = 0;
    var ran: u32 = 0;
    var total_polls: u64 = 0;
    var i: usize = 1;
    while (i + 1 < argv.len + 1 and i + 1 <= argv.len) : (i += 2) {
        const name = argv[i];
        const bin = argv[i + 1];
        const spec = specByName(name) orelse {
            std.debug.print("[FAIL] {s}: no spec for this test\n", .{name});
            failures += 1;
            continue;
        };
        ran += 1;
        var polls: u64 = 0;
        const ok = runSpec(spec, bin, &polls) catch |e| blk: {
            std.debug.print("[FAIL] {s}: runner error {t}\n", .{ name, e });
            break :blk false;
        };
        total_polls += polls;
        if (ok) {
            std.debug.print("[ ok ] {s:<8} {d}.{d}s\n", .{ name, polls / 10, polls % 10 });
        } else {
            failures += 1;
        }
    }
    if (failures == 0) {
        std.debug.print("check: all {d} OS tests passed ({d}s)\n", .{ ran, total_polls / 10 });
        return 0;
    }
    std.debug.print("check: {d} of {d} FAILED\n", .{ failures, ran });
    return 1;
}

fn specByName(name: []const u8) ?Spec {
    for (specs) |s| {
        if (std.mem.eql(u8, s.name, name)) return s;
    }
    return null;
}

fn runSpec(spec: Spec, bin: []const u8, polls: *u64) !bool {
    if (spec.kind == .cluster) return runCluster(spec, bin, polls);
    if (spec.kind == .shell) return runShell(spec, bin, polls);

    const disk = try std.fmt.allocPrint(gpa, "{s}/{s}.img", .{ check_dir, spec.name });
    if (spec.kind == .blk) try makeDisk(disk);

    if (!try runOnce(spec, bin, disk, 1, spec.extra, polls)) return false;
    if (spec.second_run_extra) |extra2| {
        return runOnce(spec, bin, disk, 2, extra2, polls);
    }
    return true;
}

fn runOnce(spec: Spec, bin: []const u8, disk: []const u8, run_no: u32, extra: ?[]const u8, polls: *u64) !bool {
    const log_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{d}.log", .{ check_dir, spec.name, run_no });
    cwd.deleteFile(io, log_path) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    try appendBase(&args, log_path, bin);
    if (spec.append) |a| try args.appendSlice(gpa, &.{ "-append", a });
    switch (spec.kind) {
        .blk => try appendDisk(&args, disk),
        .net => try args.appendSlice(gpa, &.{
            "-netdev", "user,id=n0,guestfwd=tcp:10.0.2.100:9000-cmd:cat",
            "-device", "virtio-net-pci,disable-legacy=on,netdev=n0",
        }),
        else => {},
    }

    var child = try spawnQemu(args.items);
    defer child.kill(io);
    const verdict = watch(log_path, spec, extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log_path);
    return verdict.ok;
}

/// The dynamic-membership drill: three nodes on one L2 segment (node 1's
/// QEMU hosts the hub — hubport netdevs bridge its NIC to two socket
/// listeners, since mcast sockets do not deliver between processes on
/// this host). Node 2 boots with drill=1 and powers off mid-life; when
/// node 1 reports the death through the fabric's own membership, the
/// runner RELAUNCHES node 2 (drill=0) and node 1 must see the rejoin and
/// spawn on it again. The gossip proof is node 3's own "full mesh" log.
fn runCluster(spec: Spec, bin: []const u8, polls: *u64) !bool {
    const log1 = try std.fmt.allocPrint(gpa, "{s}/{s}-node1.log", .{ check_dir, spec.name });
    const log2 = try std.fmt.allocPrint(gpa, "{s}/{s}-node2.log", .{ check_dir, spec.name });
    const log2b = try std.fmt.allocPrint(gpa, "{s}/{s}-node2-rejoin.log", .{ check_dir, spec.name });
    const log3 = try std.fmt.allocPrint(gpa, "{s}/{s}-node3.log", .{ check_dir, spec.name });
    for ([_][]const u8{ log1, log2, log2b, log3 }) |l| cwd.deleteFile(io, l) catch {};

    var args1: std.ArrayList([]const u8) = .empty;
    try appendBase(&args1, log1, bin);
    try args1.appendSlice(gpa, &.{
        "-netdev", "hubport,id=h1,hubid=0",
        "-device", "virtio-net-pci,disable-legacy=on,netdev=h1",
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s2,listen=127.0.0.1:{s}", .{cluster_port}),
        "-netdev", "hubport,id=h2,hubid=0,netdev=s2",
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s3,listen=127.0.0.1:{s}", .{cluster_port2}),
        "-netdev", "hubport,id=h3,hubid=0,netdev=s3",
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s9,listen=127.0.0.1:{s}", .{cluster_port3}),
        "-netdev", "hubport,id=h9,hubid=0,netdev=s9",
        "-append", "node=1",
    });
    var c1 = try spawnQemu(args1.items);
    defer c1.kill(io);
    sleepMs(1000);

    var c2 = try spawnQemu(try joinerArgs(log2, bin, cluster_port, "node=2 drill=1"));
    defer c2.kill(io);
    var c3 = try spawnQemu(try joinerArgs(log3, bin, cluster_port2, "node=3"));
    defer c3.kill(io);
    // The imposter: wrong fabric key; the handshake must refuse it.
    const log9 = try std.fmt.allocPrint(gpa, "{s}/{s}-node9.log", .{ check_dir, spec.name });
    cwd.deleteFile(io, log9) catch {};
    var c9 = try spawnQemu(try joinerArgs(log9, bin, cluster_port3, "node=9 badkey=1"));
    defer c9.kill(io);

    // Stage: wait for the death marker, then relaunch node 2 (the rejoin).
    var c2b: ?std.process.Child = null;
    defer if (c2b) |*c| c.kill(io);
    const death_deadline = 600; // polls
    var seen_death = false;
    for (0..death_deadline) |_| {
        sleepMs(poll_ms);
        polls.* += 1;
        const content = cwd.readFileAlloc(io, log1, gpa, .limited(1 << 20)) catch "";
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null) break;
        if (std.mem.indexOf(u8, content, "node 2 death detected") != null) {
            seen_death = true;
            break;
        }
    }
    if (!seen_death) {
        reportFailure(spec.name, "death never detected", log1);
        return false;
    }
    c2b = try spawnQemu(try joinerArgs(log2b, bin, cluster_port, "node=2 drill=0"));

    // The verdict lives in node 1's log; the gossip proof in node 3's.
    const verdict = watch(log1, spec, spec.extra, polls);
    if (!verdict.ok) {
        reportFailure(spec.name, verdict.why, log1);
        return false;
    }
    const n3 = cwd.readFileAlloc(io, log3, gpa, .limited(1 << 20)) catch "";
    if (std.mem.indexOf(u8, n3, "full mesh") == null) {
        reportFailure(spec.name, "node 3 never reached full mesh (gossip)", log3);
        return false;
    }
    if (std.mem.indexOf(u8, n3, "spawn refused on certificate grounds") == null) {
        reportFailure(spec.name, "node 3's unauthorized spawn was not refused", log3);
        return false;
    }
    if (std.mem.indexOf(u8, n3, "rejoin attempt refused") == null) {
        reportFailure(spec.name, "node 3 was not refused after revocation", log3);
        return false;
    }
    // The revocation must have reached node 2 by gossip (its rejoin log).
    const n2b = cwd.readFileAlloc(io, log2b, gpa, .limited(1 << 20)) catch "";
    if (std.mem.indexOf(u8, n2b, "revocation accepted from trust root") == null) {
        reportFailure(spec.name, "revocation never reached node 2 by gossip", log2b);
        return false;
    }
    const n9 = cwd.readFileAlloc(io, log9, gpa, .limited(1 << 20)) catch "";
    if (std.mem.indexOf(u8, n9, "untrusted identity rejected") == null) {
        reportFailure(spec.name, "imposter was not rejected", log9);
        return false;
    }
    return true;
}

fn joinerArgs(log_path: []const u8, bin: []const u8, port: []const u8, append: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try appendBase(&args, log_path, bin);
    try args.appendSlice(gpa, &.{
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=n0,connect=127.0.0.1:{s}", .{port}),
        "-device", "virtio-net-pci,disable-legacy=on,netdev=n0",
        "-append", append,
    });
    return args.items;
}

/// The scripted developer-console session: boot the shell topology with
/// the virtio console on a TCP chardev, drive real commands through msh,
/// require each expected response, then `exit` and require the PASS
/// marker + leak check in the kernel log. A reader thread drains the
/// socket into a shared buffer the script polls — same poll-with-timeout
/// shape as the log watching.
const ConsoleTap = struct {
    fd: std.posix.fd_t,
    buf: [1 << 16]u8 = undefined,
    /// Reader thread appends bytes then releases len; the main thread
    /// acquires len and scans past its discard watermark. Single writer,
    /// single reader, append-only: no lock needed.
    len: std.atomic.Value(usize) = .init(0),
    start: usize = 0, // main-thread-only discard watermark

    fn readerLoop(t: *ConsoleTap) void {
        var chunk: [1024]u8 = undefined;
        while (true) {
            const n = std.posix.read(t.fd, &chunk) catch break;
            if (n == 0) break;
            const old = t.len.load(.monotonic);
            const k = @min(n, t.buf.len - old);
            if (k == 0) break;
            @memcpy(t.buf[old .. old + k], chunk[0..k]);
            t.len.store(old + k, .release);
        }
    }

    fn clear(t: *ConsoleTap) void {
        t.start = t.len.load(.acquire);
    }

    fn contains(t: *ConsoleTap, pat: []const u8) bool {
        const end = t.len.load(.acquire);
        if (end <= t.start) return false;
        return std.mem.indexOf(u8, t.buf[t.start..end], pat) != null;
    }
};

/// A scripted step: `send` goes to the console (with "\r" unless raw),
/// then `expect` must appear (empty = only the prompt), then the prompt.
const Step = struct { send: []const u8, expect: []const u8, raw: bool = false };

const shell_script = [_]Step{
    .{ .send = "help", .expect = "commands" },
    .{ .send = "clear", .expect = "\x1b[2J" },
    .{ .send = "ps", .expect = "shell" },
    .{ .send = "mem", .expect = "free_mb" },
    .{ .send = "df", .expect = "encrypted: true" },
    .{ .send = "mkdir data/smoke", .expect = "" },
    .{ .send = "write data/smoke/hi.txt \"typed ipc all the way down\"", .expect = "" },
    .{ .send = "cat data/smoke/hi.txt", .expect = "typed ipc all the way down" },
    .{ .send = "ln data/smoke/l hi.txt", .expect = "" },
    .{ .send = "cat data/smoke/l", .expect = "typed ipc" },
    .{ .send = "stat data/smoke/l", .expect = "symlink" },
    .{ .send = "start 1", .expect = "started" },
    .{ .send = "svc", .expect = "up" },
    .{ .send = "stop 1", .expect = "stopped" },
    .{ .send = "nodes", .expect = "up" },
    .{ .send = "rspawn 9 9", .expect = "error: rspawn" },
    .{ .send = "rm data/smoke/l", .expect = "" },
    .{ .send = "sync", .expect = "" },
    .{ .send = "rand | len", .expect = "32" },
    .{ .send = "ls img", .expect = "index" },
    // Programs return values: their tables compose with the language.
    .{ .send = "run ps | where name == shell | get name", .expect = "shell" },
    .{ .send = "run ls data/smoke | get name", .expect = "hi.txt" },
    .{ .send = "run nope", .expect = "no such image" },
    // Functions, data files, scripts (the startup script defined `alive`).
    .{ .send = "def twice [x] { $x * 2 }; twice 21", .expect = "42" },
    .{ .send = "alive | where name == fs | len", .expect = "1" },
    .{ .send = "ls data/smoke | to-data | save data/l.msh", .expect = "" },
    .{ .send = "open data/l.msh | from-data | get name", .expect = "hi.txt" },
    .{ .send = "write data/s.msh \"let n = 7; \\$n + 1000\"", .expect = "" },
    .{ .send = "source data/s.msh", .expect = "1007" },
    // The language: typed pipelines, variables, control flow, redirection.
    .{ .send = "ls data/smoke | where size > 0 | get name", .expect = "hi.txt" },
    .{ .send = "ls data/smoke | select name size", .expect = "hi.txt  26" },
    .{ .send = "let n = (ls data/smoke | len); if $n == 1 { echo \"one file\" } else { echo many }", .expect = "one file" },
    .{ .send = "for f in (ls data/smoke | get name) { echo \"file: $f\" }", .expect = "file: hi.txt" },
    .{ .send = "let i = 0; while $i < 3 { let i = $i + 1 }; $i", .expect = "3" },
    .{ .send = "tree data", .expect = "hi.txt" },
    .{ .send = "ls data/smoke | select name > data/listing.txt", .expect = "" },
    .{ .send = "cat data/listing.txt", .expect = "hi.txt" },
    .{ .send = "echo hello world > data/hello.txt", .expect = "" },
    .{ .send = "cat data/hello.txt | lines | first 1", .expect = "hello world" },
    .{ .send = "(stat data/smoke).type == dir", .expect = "true" },
    // The editor: tab completes a command, ctrl-c abandons the line.
    .{ .send = "mkd\t", .expect = "mkdir", .raw = true },
    .{ .send = "\x03", .expect = "^C", .raw = true },
};

fn runShell(spec: Spec, bin: []const u8, polls: *u64) !bool {
    const disk = try std.fmt.allocPrint(gpa, "{s}/{s}.img", .{ check_dir, spec.name });
    cwd.deleteFile(io, disk) catch {};
    try makeDisk(disk);
    // A fresh volume, then the same volume again: what was born on the
    // first boot must be restored on the second.
    if (!try runShellOnce(spec, bin, disk, 1, spec.extra, polls)) return false;
    if (spec.second_run_extra) |extra2| return runShellOnce(spec, bin, disk, 2, extra2, polls);
    return true;
}

fn runShellOnce(spec: Spec, bin: []const u8, disk: []const u8, run_no: u32, extra: ?[]const u8, polls: *u64) !bool {
    const log_path = try std.fmt.allocPrint(gpa, "{s}/{s}-{d}.log", .{ check_dir, spec.name, run_no });
    cwd.deleteFile(io, log_path) catch {};

    var args: std.ArrayList([]const u8) = .empty;
    try appendBase(&args, log_path, bin);
    try appendDisk(&args, disk);
    try args.appendSlice(gpa, &.{
        "-device",  "virtio-serial-pci,disable-legacy=on",
        "-chardev", try std.fmt.allocPrint(gpa, "socket,id=c0,host=127.0.0.1,port={d},server=on,wait=off", .{shell_port}),
        "-device",  "virtconsole,chardev=c0",
        "-netdev",  "user,id=un0",
        "-device",  "virtio-net-pci,disable-legacy=on,netdev=un0",
    });

    var child = try spawnQemu(args.items);
    defer child.kill(io);

    // Connect (QEMU binds the chardev at startup).
    var fd: ?std.posix.fd_t = null;
    for (0..50) |_| {
        fd = tcpConnect(shell_port) catch {
            sleepMs(100);
            polls.* += 1;
            continue;
        };
        break;
    }
    const sock = fd orelse {
        reportFailure(spec.name, "console socket never accepted", log_path);
        return false;
    };
    var tap = try gpa.create(ConsoleTap);
    tap.* = .{ .fd = sock };
    const th = try std.Thread.spawn(.{}, ConsoleTap.readerLoop, .{tap});
    th.detach();

    // The startup script prints the motd before the first prompt.
    sockSend(sock, "\r");
    if (!waitFor(tap, "Welcome to moss", 300, polls) or !waitFor(tap, "msh> ", 300, polls)) {
        reportFailure(spec.name, "no startup banner / shell prompt", log_path);
        return false;
    }
    for (&shell_script) |step| {
        tap.clear();
        sockSend(sock, step.send);
        if (!step.raw) sockSend(sock, "\r");
        const got = step.expect.len == 0 or waitFor(tap, step.expect, 300, polls);
        if (!(got and waitFor(tap, "msh> ", 300, polls))) {
            std.debug.print("[FAIL] {s}: console step '{s}' missing '{s}'\n", .{ spec.name, step.send, step.expect });
            reportFailure(spec.name, "console script step failed", log_path);
            return false;
        }
    }
    tap.clear();
    sockSend(sock, "exit\r");

    const verdict = watch(log_path, spec, extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log_path);
    return verdict.ok;
}

fn sockSend(fd: std.posix.fd_t, bytes: []const u8) void {
    var off: usize = 0;
    while (off < bytes.len) {
        const n = std.c.write(fd, bytes.ptr + off, bytes.len - off);
        if (n <= 0) return;
        off += @intCast(n);
    }
}

fn tcpConnect(port: u16) !std.posix.fd_t {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    const stream = try addr.connect(io, .{ .mode = .stream });
    return stream.socket.handle;
}

/// Poll the console tap for a pattern; `ticks` are 100ms polls.
fn waitFor(tap: *ConsoleTap, pat: []const u8, ticks: u64, polls: *u64) bool {
    for (0..ticks) |_| {
        if (tap.contains(pat)) return true;
        sleepMs(poll_ms);
        polls.* += 1;
    }
    return false;
}

const Verdict = struct { ok: bool, why: []const u8 = "" };

/// Poll the log until pass markers appear, a failure marker appears, or the
/// timeout lapses.
fn watch(log_path: []const u8, spec: Spec, extra: ?[]const u8, polls: *u64) Verdict {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;

        const content = cwd.readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch "";

        if (spec.panic_is_failure and std.mem.indexOf(u8, content, "KERNEL PANIC") != null) {
            return .{ .ok = false, .why = "kernel panic" };
        }
        if (std.mem.indexOf(u8, content, ": FAIL") != null) {
            return .{ .ok = false, .why = "test reported FAIL" };
        }
        const have_pass = std.mem.indexOf(u8, content, spec.pass) != null;
        const have_extra = extra == null or std.mem.indexOf(u8, content, extra.?) != null;
        const have_always = spec.always_extra == null or
            std.mem.indexOf(u8, content, spec.always_extra.?) != null;
        if (have_pass and have_extra and have_always) return .{ .ok = true };

        if (n * poll_ms / 1000 > spec.timeout_s) {
            return .{ .ok = false, .why = "timeout" };
        }
    }
}

fn reportFailure(name: []const u8, why: []const u8, log_path: []const u8) void {
    std.debug.print("[FAIL] {s}: {s} (log: {s})\n", .{ name, why, log_path });
    const content = cwd.readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch return;
    var start = content.len;
    var lines: u32 = 0;
    while (start > 0 and lines < 15) {
        start -= 1;
        if (content[start] == '\n') lines += 1;
    }
    std.debug.print("------ last lines ------\n{s}\n------------------------\n", .{content[start..]});
}

fn spawnQemu(argv: []const []const u8) !std.process.Child {
    return std.process.spawn(io, .{
        .argv = argv,
        .stdin = .ignore,
        .stdout = .ignore,
        .stderr = .ignore,
    });
}

fn sleepMs(ms: u64) void {
    Io.sleep(io, .fromMilliseconds(@intCast(ms)), .awake) catch {};
}

fn appendBase(args: *std.ArrayList([]const u8), log_path: []const u8, bin: []const u8) !void {
    try args.appendSlice(gpa, &.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3",
        "-cpu",
        "cortex-a72",
        "-smp",
        "4",
        "-m",
        "512M",
        "-display",
        "none",
        "-nic",
        "none",
        "-device",
        "virtio-rng-pci,disable-legacy=on",
        "-serial",
        try std.fmt.allocPrint(gpa, "file:{s}", .{log_path}),
        "-kernel",
        bin,
    });
}

fn appendDisk(args: *std.ArrayList([]const u8), disk: []const u8) !void {
    try args.appendSlice(gpa, &.{
        "-drive",
        try std.fmt.allocPrint(gpa, "if=none,file={s},format=raw,id=hd", .{disk}),
        "-device",
        "virtio-blk-pci,disable-legacy=on,drive=hd",
    });
}

fn makeDisk(path: []const u8) !void {
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.setLength(io, 4 * 1024 * 1024);
}
