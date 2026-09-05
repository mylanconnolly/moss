//! The OS test runner: boots each test's kernel variant under QEMU with the
//! right machine configuration, watches its serial log for PASS / panic
//! markers, and enforces timeouts. Tests power themselves off (PSCI) after
//! reporting, so the normal case is a clean QEMU exit within seconds.
//!
//! Invoked by `zig build check` with (name, kernel.bin) argument pairs,
//! after optional flags: `--repeat N` runs every test N times (a soak for
//! intermittent failures; the first failure stops that test and leaves
//! its log), `--only a,b` runs only the named tests. A name may carry a
//! `+rs` suffix — the same spec booting a ReleaseSafe kernel; logs and
//! disks take the full label so the two passes never share files.
//! To add a test: give it a self-terminating driver with a unique
//! "<name>-test: PASS" line, add the build variant in build.zig, and a Spec
//! here.

const std = @import("std");
const Io = std.Io;

const Kind = enum { plain, blk, net, cluster, shell, vmnode, login, flogin };

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
    /// The x86_64 port's markers where they differ (its fault dump).
    pass_x86: ?[]const u8 = null,
    extra_x86: ?[]const u8 = null,
};

/// Which port the kernels under test are (`--arch`): the QEMU machine,
/// the boot method and a drill's markers follow it.
const Arch = enum { aarch64, x86_64 };
var target_arch: Arch = .aarch64;
var limine_dir: []const u8 = "/usr/share/limine";
var ovmf_code: []const u8 = "/usr/share/qemu/edk2-x86_64-code.fd";
var ovmf_vars: []const u8 = "/usr/share/qemu/edk2-i386-vars.fd";

const specs = [_]Spec{
    .{ .name = "panic", .pass = "KERNEL PANIC: panic test requested", .panic_is_failure = false },
    .{ .name = "fault", .pass = "!! EXCEPTION: cur_spx_sync", .extra = "far=0xffffff7fdead0000", .panic_is_failure = false, .pass_x86 = "!! EXCEPTION: vector 14 — page fault", .extra_x86 = "cr2=0xffffff7fdead0000" },
    .{ .name = "pan", .pass = "privileged access to user memory refused (PAN)", .extra = "pan-test: touching the caller's buffer outside a uaccess window", .panic_is_failure = false, .pass_x86 = "privileged access to user memory refused (SMAP)" },
    .{ .name = "sched", .pass = "sched-test: PASS" },
    .{ .name = "cpu", .pass = "cpu-test: PASS", .extra = "a second reservation of core 3 refused", .timeout_s = 90 },
    .{ .name = "domain", .pass = "domain-test: PASS" },
    .{ .name = "ipc", .pass = "ipc-test: PASS" },
    .{ .name = "init", .pass = "init-test: PASS" },
    .{ .name = "sandbox", .pass = "sandbox-test: PASS" },
    .{ .name = "flap", .pass = "flap-test: PASS" },
    .{ .name = "blk", .kind = .blk, .pass = "blk-test: PASS", .append = "profile=blk" },
    .{ .name = "smmu", .kind = .blk, .pass = "smmu-test: PASS", .extra = "smmu: DMA refused", .extra_x86 = "vtd: DMA refused" },
    .{ .name = "vm", .pass = "vm-test: PASS", .extra = "guest> guest: tick 3" },
    .{ .name = "guest", .pass = "guest-test: PASS", .extra = "guest| [info ] smp: 4 cores online", .always_extra = "guest-hello: hello from EL0, inside a moss guest of moss" },
    .{ .name = "vmnode", .kind = .vmnode, .pass = "vmnode-test: PASS", .extra = "fabric-test: node 2 joined the fabric via seed 1", .always_extra = "guest| [info ] smp: 4 cores online", .timeout_s = 180 },
    .{
        .name = "fs",
        .kind = .blk,
        .pass = "fs-test: PASS",
        .extra = "formatted fresh mossfs (std hierarchy, encrypted)",
        .always_extra = "alice: v2 ops verified",
        .second_run_extra = "existing mossfs found (encrypted, key verified)",
        .append = "profile=fs",
    },
    .{ .name = "net", .kind = .net, .pass = "net-test: PASS", .extra = "mshrun: script: served 4", .append = "profile=net" },
    .{
        .name = "users",
        .kind = .blk,
        .pass = "users-test: PASS",
        .extra = "users-drill: homes isolated",
        .always_extra = "the home persisted across sessions",
        .append = "profile=users",
    },
    .{
        .name = "login",
        .kind = .login,
        .pass = "login-test: PASS",
        .extra = "usersvc: every console had its session and logged out",
        .append = "profile=login",
        .timeout_s = 120,
    },
    .{ .name = "rng", .pass = "rng-test: PASS", .extra = "rngprobe: unseeded pool refuses getrandom" },
    .{
        .name = "flogin",
        .kind = .flogin,
        .pass = "flogin-test: PASS",
        .extra = "fetched from node 1",
        .always_extra = "mshrun: script: remote stages done",
        .timeout_s = 150,
    },
    .{
        .name = "shell",
        .kind = .shell,
        .pass = "shell-test: PASS",
        .extra = "fabric identity born and certified",
        .always_extra = "mshrun: hello from a script: ",
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
/// The net check's port forward to the script's HTTP server (:8080).
const http_port: u16 = 31909;
/// The fabric-login drill's own hub port: a listener the three-node
/// drill left in TIME_WAIT must never be the one node 2 dials.
const flogin_port = "31911";
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
    var repeat: u32 = 1;
    var only: ?[]const u8 = null;
    var i: usize = 1;
    while (i < argv.len and std.mem.startsWith(u8, argv[i], "--")) : (i += 2) {
        if (i + 1 >= argv.len) break;
        if (std.mem.eql(u8, argv[i], "--repeat")) {
            repeat = std.fmt.parseInt(u32, argv[i + 1], 10) catch 0;
        } else if (std.mem.eql(u8, argv[i], "--only")) {
            only = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--arch")) {
            target_arch = std.meta.stringToEnum(Arch, argv[i + 1]) orelse {
                std.debug.print("runner: unknown --arch {s}\n", .{argv[i + 1]});
                return 2;
            };
        } else if (std.mem.eql(u8, argv[i], "--limine")) {
            limine_dir = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--ovmf")) {
            ovmf_code = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--ovmf-vars")) {
            ovmf_vars = argv[i + 1];
        } else break;
    }
    if (repeat == 0 or argv.len - i < 2 or (argv.len - i) % 2 != 0) {
        std.debug.print("usage: runner [--repeat N] [--only a,b] [--arch aarch64|x86_64] [--limine DIR] [--ovmf FD] [--ovmf-vars FD] <name> <kernel> ...\n", .{});
        return 2;
    }
    cwd.createDirPath(io, check_dir) catch {};

    var failures: u32 = 0;
    var ran: u32 = 0;
    var total_polls: u64 = 0;
    while (i + 1 < argv.len) : (i += 2) {
        const label = argv[i];
        const bin = argv[i + 1];
        const base = if (std.mem.endsWith(u8, label, "+rs")) label[0 .. label.len - 3] else label;
        if (only) |list| {
            if (!listed(list, label) and !listed(list, base)) continue;
        }
        var spec = specByName(base) orelse {
            std.debug.print("[FAIL] {s}: no spec for this test\n", .{label});
            failures += 1;
            continue;
        };
        spec.name = label; // logs and disks per label: the +rs pass keeps its own
        if (target_arch == .x86_64) {
            if (spec.pass_x86) |p| spec.pass = p;
            if (spec.extra_x86) |e| spec.extra = e;
        }
        ran += 1;
        var polls: u64 = 0;
        var ok = true;
        var runs: u32 = 0;
        while (ok and runs < repeat) : (runs += 1) {
            ok = runSpec(spec, bin, &polls) catch |e| blk: {
                std.debug.print("[FAIL] {s}: runner error {t}\n", .{ label, e });
                break :blk false;
            };
        }
        total_polls += polls;
        if (ok) {
            if (repeat > 1) {
                std.debug.print("[ ok ] {s:<10} {d}.{d}s  x{d}\n", .{ label, polls / 10, polls % 10, repeat });
            } else {
                std.debug.print("[ ok ] {s:<10} {d}.{d}s\n", .{ label, polls / 10, polls % 10 });
            }
        } else {
            if (runs > 1) std.debug.print("[FAIL] {s}: failed on run {d} of {d}\n", .{ label, runs, repeat });
            failures += 1;
            // Keep the evidence: the next run of this label would overwrite
            // its log, and a failure that took ten runs to show is not
            // worth losing to an eager rerun.
            keepFailedLog(label);
        }
    }
    if (failures == 0) {
        std.debug.print("check: all {d} OS tests passed ({d}s)\n", .{ ran, total_polls / 10 });
        return 0;
    }
    std.debug.print("check: {d} of {d} FAILED\n", .{ failures, ran });
    return 1;
}

/// Copy `<label>-1.log` to `<label>-failed.log` (overwriting an older
/// keepsake), so a rerun cannot erase the failing run's serial log.
fn keepFailedLog(label: []const u8) void {
    const src = std.fmt.allocPrint(gpa, "{s}/{s}-1.log", .{ check_dir, label }) catch return;
    const dst = std.fmt.allocPrint(gpa, "{s}/{s}-failed.log", .{ check_dir, label }) catch return;
    cwd.copyFile(src, cwd, dst, io, .{}) catch return;
    std.debug.print("       (log kept as {s})\n", .{dst});
}

/// Is `name` one of the comma-separated entries of `list`?
fn listed(list: []const u8, name: []const u8) bool {
    var it = std.mem.splitScalar(u8, list, ',');
    while (it.next()) |entry| {
        if (std.mem.eql(u8, std.mem.trim(u8, entry, " "), name)) return true;
    }
    return false;
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
    if (spec.kind == .login) return runLogin(spec, bin, polls);
    if (spec.kind == .flogin) return runFlogin(spec, bin, polls);

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
    try appendBase(&args, log_path, bin, spec.name, spec.append);
    switch (spec.kind) {
        .blk => try appendDisk(&args, disk),
        // The wire echo (cat), a canned HTTP server for `fetch`, and a
        // forward from the host to the script's own server.
        .net => try args.appendSlice(gpa, &.{
            "-netdev",
            "user,id=n0,guestfwd=tcp:10.0.2.100:9000-cmd:cat," ++
                "guestfwd=tcp:10.0.2.100:9001-cmd:printf 'HTTP/1.1 200 OK\\r\\nContent-Length: 11\\r\\n\\r\\nhello moss!'," ++
                "hostfwd=tcp:127.0.0.1:" ++ std.fmt.comptimePrint("{d}", .{http_port}) ++ "-:8080",
            "-device",
            "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0",
            "-object",
            "filter-dump,id=f0,netdev=n0,file=zig-out/check/net.pcap",
        }),
        // Two NICs on one hub (host node 1, guest node 2) and a second
        // entropy device for the guest.
        .vmnode => try args.appendSlice(gpa, &.{
            "-netdev", "hubport,id=h1,hubid=0",
            "-device", "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=h1",
            "-netdev", "hubport,id=h2,hubid=0",
            "-device", "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=h2",
            "-device", "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
        }),
        else => {},
    }

    var child = try spawnQemu(args.items);
    defer child.kill(io);
    if (spec.kind == .net) {
        if (!try httpProbe(spec, log_path, polls)) return false;
    }
    const verdict = watch(log_path, spec, extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log_path);
    return verdict.ok;
}

/// The net check's client side: once the script says it is serving,
/// fetch four pages through the port forward and check each answer.
fn httpProbe(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = cwd.readFileAlloc(io, log_path, gpa, .limited(1 << 20)) catch "";
        if (std.mem.indexOf(u8, content, "script: serving http") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the script never started serving http", log_path);
            return false;
        }
    }
    const probes = [_]struct { req: []const u8, expect: []const u8, expect2: []const u8 }{
        .{ .req = "GET /hello HTTP/1.1\r\nHost: moss\r\n\r\n", .expect = "HTTP/1.1 200 OK", .expect2 = "\r\n\r\nhello from moss" },
        .{ .req = "GET /json HTTP/1.1\r\nHost: moss\r\n\r\n", .expect = "Content-Type: application/json", .expect2 = "[{\"n\":1},{\"n\":2}]" },
        .{ .req = "POST /echo HTTP/1.1\r\nHost: moss\r\nContent-Length: 7\r\n\r\npayload", .expect = "x-method: POST", .expect2 = "\r\n\r\npayload" },
        .{ .req = "GET /nope HTTP/1.1\r\nHost: moss\r\n\r\n", .expect = "HTTP/1.1 404 Not Found", .expect2 = "no such page" },
    };
    for (probes, 0..) |p, i| {
        var conn: ?Io.net.Stream = null;
        for (0..50) |_| {
            conn = tcpConnect(http_port) catch {
                sleepMs(poll_ms);
                polls.* += 1;
                continue;
            };
            break;
        }
        const stream = conn orelse {
            reportFailure(spec.name, "could not connect to the script's http server", log_path);
            return false;
        };
        defer stream.close(io);
        sockSend(stream, p.req);
        var resp: std.ArrayList(u8) = .empty;
        var rbuf: [4096]u8 = undefined;
        var reader = stream.reader(io, &rbuf);
        reader.interface.appendRemainingUnlimited(gpa, &resp) catch {};
        if (std.mem.indexOf(u8, resp.items, p.expect) == null or std.mem.indexOf(u8, resp.items, p.expect2) == null) {
            std.debug.print("[FAIL] {s}: http probe {d} got:\n{s}\n", .{ spec.name, i, resp.items });
            reportFailure(spec.name, "an http probe answered wrong", log_path);
            return false;
        }
    }
    return true;
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
    try appendBase(&args1, log1, bin, try std.fmt.allocPrint(gpa, "{s}-node1", .{spec.name}), "node=1");
    try args1.appendSlice(gpa, &.{
        "-netdev", "hubport,id=h1,hubid=0",
        "-device", "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=h1",
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s2,listen=127.0.0.1:{s}", .{cluster_port}),
        "-netdev", "hubport,id=h2,hubid=0,netdev=s2",
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s3,listen=127.0.0.1:{s}", .{cluster_port2}),
        "-netdev", "hubport,id=h3,hubid=0,netdev=s3",
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s9,listen=127.0.0.1:{s}", .{cluster_port3}),
        "-netdev", "hubport,id=h9,hubid=0,netdev=s9",
    });
    var c1 = try spawnQemu(args1.items);
    defer c1.kill(io);
    sleepMs(1000);

    var c2 = try spawnQemu(try joinerArgs(try std.fmt.allocPrint(gpa, "{s}-node2", .{spec.name}), log2, bin, cluster_port, "node=2 drill=1"));
    defer c2.kill(io);
    var c3 = try spawnQemu(try joinerArgs(try std.fmt.allocPrint(gpa, "{s}-node3", .{spec.name}), log3, bin, cluster_port2, "node=3"));
    defer c3.kill(io);
    // The imposter: wrong fabric key; the handshake must refuse it.
    const log9 = try std.fmt.allocPrint(gpa, "{s}/{s}-node9.log", .{ check_dir, spec.name });
    cwd.deleteFile(io, log9) catch {};
    var c9 = try spawnQemu(try joinerArgs(try std.fmt.allocPrint(gpa, "{s}-node9", .{spec.name}), log9, bin, cluster_port3, "node=9 badkey=1"));
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
    c2b = try spawnQemu(try joinerArgs(try std.fmt.allocPrint(gpa, "{s}-node2b", .{spec.name}), log2b, bin, cluster_port, "node=2 drill=0"));

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
    if (std.mem.indexOf(u8, n3, "reached node 1's published service") == null) {
        reportFailure(spec.name, "node 3 never reached the published service (lookup)", log3);
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

fn joinerArgs(label: []const u8, log_path: []const u8, bin: []const u8, port: []const u8, append: []const u8) ![]const []const u8 {
    var args: std.ArrayList([]const u8) = .empty;
    try appendBase(&args, log_path, bin, label, append);
    try args.appendSlice(gpa, &.{
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=n0,connect=127.0.0.1:{s}", .{port}),
        "-device", "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0",
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
    stream: Io.net.Stream,
    /// Everything the console ever said in this session (a long script
    /// with tables and help text runs past 64 KB; the first size did,
    /// and every step after the overflow "hung").
    buf: [1 << 22]u8 = undefined,
    overflowed: bool = false,
    reader_done: bool = false,
    /// Reader thread appends bytes then releases len; the main thread
    /// acquires len and scans past its discard watermark. Single writer,
    /// single reader, append-only: no lock needed.
    len: std.atomic.Value(usize) = .init(0),
    start: usize = 0, // main-thread-only discard watermark

    fn readerLoop(t: *ConsoleTap) void {
        var chunk: [1024]u8 = undefined;
        defer t.reader_done = true;
        while (true) {
            const n = std.posix.read(t.stream.socket.handle, &chunk) catch |e| {
                std.debug.print("[FAIL] console tap: read failed: {t}\n", .{e});
                break;
            };
            if (n == 0) break;
            const old = t.len.load(.monotonic);
            const k = @min(n, t.buf.len - old);
            if (k == 0) {
                t.overflowed = true;
                std.debug.print("[FAIL] console tap overflowed ({d} bytes): the session said more than the tap holds\n", .{t.buf.len});
                break;
            }
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

    /// What the console said since the step began (for a failure
    /// report: the step's own echo and whatever came back), on one line
    /// — a raw carriage return would hide the answer behind the echo.
    fn dumpRecent(t: *ConsoleTap) void {
        const end = t.len.load(.acquire);
        if (end <= t.start) return std.debug.print("       (the console said nothing)\n", .{});
        const got = t.buf[t.start..end];
        var shown: [700]u8 = undefined;
        var n: usize = 0;
        for (got[0..@min(got.len, 600)]) |ch| {
            if (ch == '\r') continue;
            if (ch == '\n') {
                @memcpy(shown[n .. n + 3], " | ");
                n += 3;
                continue;
            }
            shown[n] = ch;
            n += 1;
        }
        std.debug.print("       the console said: {s}\n       (tap: {d} bytes so far, reader {s})\n", .{ shown[0..n], end, if (t.reader_done) "gone" else "alive" });
    }

    /// The whole session so far, kept beside the kernel log on a failure.
    fn save(t: *ConsoleTap, path: []const u8) void {
        const end = t.len.load(.acquire);
        const f = cwd.createFile(io, path, .{ .truncate = true }) catch return;
        defer f.close(io);
        var wbuf: [4096]u8 = undefined;
        var w = f.writer(io, &wbuf);
        w.interface.writeAll(t.buf[0..end]) catch return;
        w.interface.flush() catch return;
        std.debug.print("       (console transcript kept as {s})\n", .{path});
    }

    /// The console line that contains `pat` (from the pattern to the end
    /// of its line), for reporting a measurement.
    fn line(t: *ConsoleTap, pat: []const u8) ?[]const u8 {
        const end = t.len.load(.acquire);
        if (end <= t.start) return null;
        const hay = t.buf[t.start..end];
        const at = std.mem.lastIndexOf(u8, hay, pat) orelse return null;
        var stop = at;
        while (stop < hay.len and hay[stop] != '\r' and hay[stop] != '\n') stop += 1;
        return hay[at..stop];
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
    .{ .send = "rspawn 9 9", .expect = "err no_peer" },
    .{ .send = "rm data/smoke/l", .expect = "" },
    .{ .send = "sync", .expect = "" },
    .{ .send = "rand | len", .expect = "32" },
    // What the world decides is a result: `?` unwraps it, `match` takes
    // it apart, and an err is a word from the protocol.
    .{ .send = "ls img? | get name", .expect = "ps.msh" },
    .{ .send = "cat data/none", .expect = "err not_found" },
    .{ .send = "match (cat data/none) { ok $t => $t; err not_found => \"no such file\"; err $e => $e }", .expect = "no such file" },
    .{ .send = "ls | get name", .expect = "error: cannot take .name of a result" },
    // Programs return values: their tables compose with the language.
    .{ .send = "run ps? | where name == shell | get name", .expect = "shell" },
    .{ .send = "run ls data/smoke? | get name", .expect = "hi.txt" },
    .{ .send = "run nope", .expect = "err not_found" },
    // The desired-state tool from the shell: users created once, then kept.
    .{ .send = "run apply? | where kind == user | len", .expect = "2" },
    .{ .send = "run apply? | where action == kept | len", .expect = "3" },
    .{ .send = "ls conf/users? | get name", .expect = "alice.msh" },
    // Functions, data files, scripts (the startup script defined `alive`).
    .{ .send = "def twice [x] { $x * 2 }; twice 21", .expect = "42" },
    .{ .send = "alive | where name == fs | len", .expect = "1" },
    .{ .send = "ls data/smoke? | to-data | save data/l.msh", .expect = "" },
    .{ .send = "open data/l.msh? | from-data | get name", .expect = "hi.txt" },
    .{ .send = "write data/s.msh \"let n = 7; \\$n + 1000\"", .expect = "" },
    .{ .send = "source data/s.msh", .expect = "1007" },
    // The language: typed pipelines, variables, control flow, redirection.
    .{ .send = "ls data/smoke? | where size > 0 | get name", .expect = "hi.txt" },
    .{ .send = "ls data/smoke? | select name size", .expect = "hi.txt  26" },
    .{ .send = "let n = (ls data/smoke? | len); if $n == 1 { echo \"one file\" } else { echo many }", .expect = "one file" },
    .{ .send = "for f in (ls data/smoke? | get name) { echo \"file: $f\" }", .expect = "file: hi.txt" },
    .{ .send = "let i = 0; while $i < 3 { let i = $i + 1 }; $i", .expect = "3" },
    .{ .send = "tree data", .expect = "hi.txt" },
    .{ .send = "ls data/smoke? | select name > data/listing.txt", .expect = "" },
    .{ .send = "cat data/listing.txt", .expect = "hi.txt" },
    .{ .send = "echo hello world > data/hello.txt", .expect = "" },
    .{ .send = "cat data/hello.txt? | lines | first 1", .expect = "hello world" },
    .{ .send = "(stat data/smoke)?.type == dir", .expect = "true" },
    // mshl v3: functions as values, results, match, modules, typing.
    .{ .send = "[1, 2, 3, 4] | map { $it * 2 } | reduce 0 { $acc + $it }", .expect = "20" },
    .{ .send = "ls data/smoke? | filter { $it.size > 0 } | map { $it.name }", .expect = "hi.txt" },
    .{ .send = "def adder [n] { fn [x] { $x + $n } }; let add5 = (adder 5); $add5 10", .expect = "15" },
    .{ .send = "match (int nope) { ok $n => $n; err $e => echo \"bad: $e\" }", .expect = "bad: not a number: nope" },
    .{ .send = "match (try { frobnicate }) { ok _ => \"ran\"; err $e => \"caught: $e\" }", .expect = "caught: unknown command 'frobnicate'" },
    .{ .send = "def first-line [p] { (cat $p)? | lines | first 1 }; first-line data/smoke/hi.txt", .expect = "typed ipc all the way down" },
    .{ .send = "first-line data/none", .expect = "err not_found" },
    .{ .send = "write data/m.msh \"def double [x] { \\$x * 2 }; def quad [x] { double (double \\$x) }\"", .expect = "" },
    .{ .send = "let m = (use data/m.msh); $m.quad 4", .expect = "16" },
    .{ .send = "if 1 { echo x }", .expect = "error: if: condition is a int, not a bool" },
    .{ .send = "\"héllo\" | len", .expect = "5" },
    // Floats: a second kind of number, never mixed with the first.
    .{ .send = "1.5 * 4.0", .expect = "6.0" },
    .{ .send = "(float (ls data/smoke? | get size | first 1).0)? / 4.0", .expect = "6.5" },
    .{ .send = "1 + 1.5", .expect = "error: cannot add a int and a float" },
    // Shapes: checked where they run; every host command has a signature.
    .{ .send = "let e: { name: string, size: int } = (stat data/smoke/hi.txt)?; $e.size", .expect = "26" },
    .{ .send = "let e: { name: int } = (stat data/smoke/hi.txt)?", .expect = "error: let: e.name is hi.txt, not int" },
    .{ .send = "def size-of [p: string] -> int { (stat $p)?.size }; size-of data/smoke/hi.txt", .expect = "26" },
    .{ .send = "size-of 3", .expect = "error: size-of: p is 3, not string" },
    .{ .send = "match (stat data/smoke)?.type: dir | file | symlink { dir => \"a directory\"; file => \"a file\"; symlink => \"a link\" }", .expect = "a directory" },
    .{ .send = "match (stat data/smoke)?.type: dir | file | symlink { dir => 1; file => 2 }", .expect = "error: match: the arms do not cover symlink" },
    .{ .send = "stat 1", .expect = "error: stat: path is 1, not string" },
    .{ .send = "ls | stat data", .expect = "error: stat: takes no input, got a result" },
    .{ .send = "(signature stat).returns", .expect = "ok { name: string, type: file | dir | symlink, size: int, mtime: int } | err (denied | not_found | no_space | bad_path | bad_fd | exists | io | not_empty | bad_key)" },
    .{ .send = "let S = shape (dir | file); $S", .expect = "dir | file" },
    .{ .send = "(signature map).params | get \"shape\"", .expect = "function" },
    .{ .send = "[1] | map 3", .expect = "error: map: f is 3, not function" },
    .{ .send = "(ls data/smoke? | check (signature ls).returns) | type", .expect = "result" },
    // The library: a module from the store, installed from the archive.
    .{ .send = "let math = (use math); [3, 1, 2] | $math.sum", .expect = "6" },
    .{ .send = "$math.clamp 15 0 10", .expect = "10" },
    .{ .send = "[1.0, 2.0, 6.0] | $math.mean", .expect = "3.0" },
    .{ .send = "use nope", .expect = "error: use: nope: not_found" },
    // Scripts as programs: mshrun runs a script under a manifest and
    // returns its last value; its errors are its exit.
    .{ .send = "write data/s2.msh \"[1, 2, 3] | map { \\$it * 3 } | reduce 0 { \\$acc + \\$it }\"", .expect = "" },
    .{ .send = "run mshrun data/s2.msh", .expect = "18" },
    .{ .send = "write data/s3.msh \"ls data/smoke? | where size > 0\"", .expect = "" },
    .{ .send = "run mshrun data/s3.msh? | get name", .expect = "hi.txt" },
    .{ .send = "write data/s4.msh \"frobnicate\"", .expect = "" },
    .{ .send = "run mshrun data/s4.msh", .expect = "unknown command 'frobnicate'" },
    .{ .send = "write data/s5.msh \"let m = (use math); [4, 5] | \\$m.product\"", .expect = "" },
    .{ .send = "run mshrun data/s5.msh", .expect = "20" },
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
    try appendBase(&args, log_path, bin, spec.name, null);
    try appendDisk(&args, disk);
    try args.appendSlice(gpa, &.{
        "-device",  "virtio-serial-pci,disable-legacy=on,iommu_platform=on",
        "-chardev", try std.fmt.allocPrint(gpa, "socket,id=c0,host=127.0.0.1,port={d},server=on,wait=off", .{shell_port}),
        "-device",  "virtconsole,chardev=c0",
        "-netdev",  "user,id=un0",
        "-device",  "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=un0",
    });

    var child = try spawnQemu(args.items);
    defer child.kill(io);

    // Connect (QEMU binds the chardev at startup).
    var fd: ?Io.net.Stream = null;
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
    tap.* = .{ .stream = sock };
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
            tap.dumpRecent();
            tap.save(std.fmt.allocPrint(gpa, "{s}/{s}-console.log", .{ check_dir, spec.name }) catch "console.log");
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

/// The multi-user drill: two virtio-console devices on two TCP chardevs,
/// two users logging in at once, each in its own session — an init
/// instance with msh holding the user's home as its whole filesystem.
/// Steps name their console; a step's `expect` must appear, then the
/// prompt it names (the login prompt, or msh's).
const LoginStep = struct { con: u8, send: []const u8, expect: []const u8, prompt: []const u8 = "msh> " };

const login_prompt = "moss login: ";

const login_script = [_]LoginStep{
    // Alice, wrong passphrase first, then in.
    .{ .con = 0, .send = "alice", .expect = "passphrase: ", .prompt = "" },
    .{ .con = 0, .send = "wrong-pass", .expect = "login refused", .prompt = login_prompt },
    .{ .con = 0, .send = "alice", .expect = "passphrase: ", .prompt = "" },
    .{ .con = 0, .send = "alice-pass", .expect = "moss shell" },
    // Bob, on the other console, while alice is in.
    .{ .con = 1, .send = "bob", .expect = "passphrase: ", .prompt = "" },
    .{ .con = 1, .send = "bob-pass", .expect = "moss shell" },
    // Each works in a home that is its whole filesystem.
    .{ .con = 0, .send = "mkdir notes; write notes/a.txt \"alice was here\"", .expect = "" },
    .{ .con = 1, .send = "write b.txt \"bob was here\"", .expect = "" },
    .{ .con = 0, .send = "ls? | get name", .expect = "notes" },
    .{ .con = 1, .send = "ls? | get name", .expect = "b.txt" },
    .{ .con = 0, .send = "ls? | where name == notes | len", .expect = "1" },
    .{ .con = 1, .send = "ls? | where name == b.txt | len", .expect = "1" },
    .{ .con = 0, .send = "ls? | where name == b.txt | len", .expect = "0" },
    .{ .con = 0, .send = "df", .expect = "encrypted: true" },
    .{ .con = 0, .send = "cat ../b.txt", .expect = "err bad_path" },
    .{ .con = 1, .send = "cat notes/a.txt", .expect = "err not_found" },
    // Both shells alive at once, seen from either.
    .{ .con = 0, .send = "ps | where name == shell | len", .expect = "2" },
    .{ .con = 1, .send = "nodes", .expect = "error" },
    // Sharing: alice offers her notes to bob read-only; bob lists the
    // offer, accepts it, reads through it, cannot write through it;
    // alice withdraws it and bob's next read fails.
    .{ .con = 0, .send = "share notes shared bob", .expect = "" },
    .{ .con = 0, .send = "share notes shared bob", .expect = "err exists" },
    .{ .con = 1, .send = "shares | get name", .expect = "shared" },
    .{ .con = 1, .send = "cat @shared/a.txt", .expect = "error" },
    .{ .con = 1, .send = "accept shared", .expect = "" },
    .{ .con = 1, .send = "cat @shared/a.txt", .expect = "alice was here" },
    .{ .con = 1, .send = "ls @shared? | get name", .expect = "a.txt" },
    .{ .con = 1, .send = "write @shared/x.txt \"no\"", .expect = "err denied" },
    .{ .con = 1, .send = "shares | where accepted == true | len", .expect = "1" },
    .{ .con = 0, .send = "unshare shared", .expect = "" },
    .{ .con = 1, .send = "cat @shared/a.txt", .expect = "err bad_fd" },
    .{ .con = 1, .send = "shares | len", .expect = "0" },
    // Alice leaves; her session is torn down and the seat is free again.
    .{ .con = 0, .send = "exit", .expect = "bye", .prompt = login_prompt },
    .{ .con = 0, .send = "alice", .expect = "passphrase: ", .prompt = "" },
    .{ .con = 0, .send = "alice-pass", .expect = "moss shell" },
    .{ .con = 0, .send = "cat notes/a.txt", .expect = "alice was here" },
    // Programs: the system store serves a session; `install` copies one
    // into the home's own store, which `run` then finds first.
    .{ .con = 0, .send = "run ps? | where name == shell | get name", .expect = "shell" },
    .{ .con = 0, .send = "ls img? | len", .expect = "0" },
    .{ .con = 0, .send = "install ps", .expect = "installed ps into your store" },
    .{ .con = 0, .send = "ls img? | get name", .expect = "ps.msh" },
    .{ .con = 0, .send = "run ps? | where name == shell | len", .expect = "2" },
    .{ .con = 1, .send = "ps | where name == shell | len", .expect = "2" },
    // A module from the system store, then installed into the home's own.
    .{ .con = 1, .send = "let m = (use math); [2, 3] | $m.sum", .expect = "5" },
    .{ .con = 1, .send = "install math", .expect = "installed math into your store" },
    .{ .con = 1, .send = "ls img? | where name == math.msh | len", .expect = "1" },
    .{ .con = 0, .send = "exit", .expect = "bye", .prompt = login_prompt },
    // The last logout ends the drill: the manager exits, no prompt follows.
    .{ .con = 1, .send = "exit", .expect = "bye", .prompt = "" },
};

fn runLogin(spec: Spec, bin: []const u8, polls: *u64) !bool {
    const disk = try std.fmt.allocPrint(gpa, "{s}/{s}.img", .{ check_dir, spec.name });
    cwd.deleteFile(io, disk) catch {};
    try makeDisk(disk);
    const log_path = try std.fmt.allocPrint(gpa, "{s}/{s}-1.log", .{ check_dir, spec.name });
    cwd.deleteFile(io, log_path) catch {};

    const ports = [2]u16{ shell_port + 1, shell_port + 2 };
    var args: std.ArrayList([]const u8) = .empty;
    try appendBase(&args, log_path, bin, spec.name, spec.append);
    try appendDisk(&args, disk);
    for (ports, 0..) |port, i| {
        try args.appendSlice(gpa, &.{
            "-device",  "virtio-serial-pci,disable-legacy=on,iommu_platform=on",
            "-chardev", try std.fmt.allocPrint(gpa, "socket,id=c{d},host=127.0.0.1,port={d},server=on,wait=off", .{ i, port }),
            "-device",  try std.fmt.allocPrint(gpa, "virtconsole,chardev=c{d}", .{i}),
        });
    }
    var child = try spawnQemu(args.items);
    defer child.kill(io);

    var taps: [2]*ConsoleTap = undefined;
    for (ports, 0..) |port, i| {
        var fd: ?Io.net.Stream = null;
        for (0..50) |_| {
            fd = tcpConnect(port) catch {
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
        taps[i] = try gpa.create(ConsoleTap);
        taps[i].* = .{ .stream = sock };
        const th = try std.Thread.spawn(.{}, ConsoleTap.readerLoop, .{taps[i]});
        th.detach();
    }
    for (taps) |tap| {
        if (!waitFor(tap, login_prompt, 600, polls)) {
            reportFailure(spec.name, "no login prompt", log_path);
            return false;
        }
    }
    for (&login_script) |step| {
        const tap = taps[step.con];
        tap.clear();
        sockSend(tap.stream, step.send);
        sockSend(tap.stream, "\r");
        const got = step.expect.len == 0 or waitFor(tap, step.expect, 600, polls);
        const prompted = step.prompt.len == 0 or waitFor(tap, step.prompt, 600, polls);
        if (!(got and prompted)) {
            std.debug.print("[FAIL] {s}: console {d} step '{s}' missing '{s}' / '{s}'\n", .{ spec.name, step.con, step.send, step.expect, step.prompt });
            tap.dumpRecent();
            tap.save(std.fmt.allocPrint(gpa, "{s}/{s}-console{d}.log", .{ check_dir, spec.name, step.con }) catch "console.log");
            reportFailure(spec.name, "login script step failed", log_path);
            return false;
        }
    }
    const verdict = watch(log_path, spec, spec.extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log_path);
    return verdict.ok;
}

/// The fabric-login drill: node 1 (a disk, the users applied, its
/// session manager published to the pool) and node 2 (a fresh disk, a
/// console, no records) on one segment; alice logs in on node 2 and her
/// record comes from node 1 over the wire. Node 2's log carries the
/// verdict; node 1 is stopped when it is in.
/// After `expect`, `prompt` must appear before the next line is typed
/// (a line typed while the shell is busy is lost).
const FloginStep = struct { send: []const u8, expect: []const u8, prompt: []const u8 = "msh> " };
/// Boot 1: alice, whose record and home live on node 1, logs in on node
/// 2 — the record is fetched, the home is leased and mounted through
/// the fabric — and writes a file. Boot 2: node 2's disk is wiped first,
/// and the file is still there: it lives on node 1.
const flogin_script = [_]FloginStep{
    .{ .send = "alice", .expect = "passphrase: ", .prompt = "" },
    .{ .send = "alice-pass", .expect = "moss shell" },
    .{ .send = "df", .expect = "encrypted: true" },
    .{ .send = "ls? | len", .expect = "5" },
    .{ .send = "write hello.txt \"born on node 2\"", .expect = "" },
    .{ .send = "cat hello.txt", .expect = "born on node 2" },
    // The remote home's speed, measured: 64 KB written, then read back.
    .{ .send = "let big = (range 0 6400 | map { \"0123456789\" } | join \"\")", .expect = "" },
    .{ .send = "let t = (now); write big.txt $big; let d = ((now) - $t); echo \"remote home: 64 KB written in $d ms\"", .expect = "remote home: 64 KB written in" },
    .{ .send = "let t = (now); let n = (cat big.txt? | len); let d = ((now) - $t); echo \"remote home: 64 KB read in $d ms ($n bytes)\"", .expect = "remote home: 64 KB read in" },
    .{ .send = "exit", .expect = "bye", .prompt = "" },
};
const flogin_script2 = [_]FloginStep{
    .{ .send = "alice", .expect = "passphrase: ", .prompt = "" },
    .{ .send = "alice-pass", .expect = "moss shell" },
    .{ .send = "cat hello.txt", .expect = "born on node 2" },
    .{ .send = "let t = (now); let n = (cat big.txt? | len); let d = ((now) - $t); echo \"remote home: 64 KB read cold in $d ms ($n bytes)\"", .expect = "remote home: 64 KB read cold in" },
    .{ .send = "exit", .expect = "bye", .prompt = "" },
};

fn runFlogin(spec: Spec, bin: []const u8, polls: *u64) !bool {
    const disk1 = try std.fmt.allocPrint(gpa, "{s}/{s}-node1.img", .{ check_dir, spec.name });
    const disk2 = try std.fmt.allocPrint(gpa, "{s}/{s}-node2.img", .{ check_dir, spec.name });
    for ([_][]const u8{ disk1, disk2 }) |f| cwd.deleteFile(io, f) catch {};
    try makeDisk(disk1);
    try makeDisk(disk2);
    if (!try floginBoot(spec, bin, disk1, disk2, 1, &flogin_script, "the home is on node 1: a fresh disk here", polls)) return false;
    // Node 2 forgets everything; node 1 keeps alice's home.
    cwd.deleteFile(io, disk2) catch {};
    try makeDisk(disk2);
    return floginBoot(spec, bin, disk1, disk2, 2, &flogin_script2, "the home is on node 1: a fresh disk here", polls);
}

fn floginBoot(spec: Spec, bin: []const u8, disk1: []const u8, disk2: []const u8, boot: u32, script: []const FloginStep, mounted: []const u8, polls: *u64) !bool {
    _ = mounted;
    const log1 = try std.fmt.allocPrint(gpa, "{s}/{s}-node1-{d}.log", .{ check_dir, spec.name, boot });
    const log2 = try std.fmt.allocPrint(gpa, "{s}/{s}-node2-{d}.log", .{ check_dir, spec.name, boot });
    for ([_][]const u8{ log1, log2 }) |f| cwd.deleteFile(io, f) catch {};

    var args1: std.ArrayList([]const u8) = .empty;
    try appendBase(&args1, log1, bin, try std.fmt.allocPrint(gpa, "{s}-node1", .{spec.name}), "profile=flogin node=1");
    try appendDisk(&args1, disk1);
    try args1.appendSlice(gpa, &.{
        "-netdev", "hubport,id=h1,hubid=0",
        "-device", "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=h1",
        "-object", try std.fmt.allocPrint(gpa, "filter-dump,id=f1,netdev=h1,file={s}/{s}-node1-{d}.pcap", .{ check_dir, spec.name, boot }),
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=s2,listen=127.0.0.1:{s}", .{flogin_port}),
        "-netdev", "hubport,id=h2,hubid=0,netdev=s2",
    });
    var c1 = try spawnQemu(args1.items);
    defer c1.kill(io);
    sleepMs(1000);

    const port: u16 = shell_port + 3;
    var args2: std.ArrayList([]const u8) = .empty;
    try appendBase(&args2, log2, bin, try std.fmt.allocPrint(gpa, "{s}-node2", .{spec.name}), "profile=fjoin node=2");
    try appendDisk(&args2, disk2);
    try args2.appendSlice(gpa, &.{
        "-netdev",  try std.fmt.allocPrint(gpa, "socket,id=n0,connect=127.0.0.1:{s}", .{flogin_port}),
        "-device",  "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0",
        "-object",  try std.fmt.allocPrint(gpa, "filter-dump,id=f2,netdev=n0,file={s}/{s}-node2-{d}.pcap", .{ check_dir, spec.name, boot }),
        "-device",  "virtio-serial-pci,disable-legacy=on,iommu_platform=on",
        "-chardev", try std.fmt.allocPrint(gpa, "socket,id=c0,host=127.0.0.1,port={d},server=on,wait=off", .{port}),
        "-device",  "virtconsole,chardev=c0",
    });
    var c2 = try spawnQemu(args2.items);
    defer c2.kill(io);

    // Node 1 must be serving before anyone logs in on node 2.
    var published = false;
    for (0..600) |_| {
        sleepMs(poll_ms);
        polls.* += 1;
        const content = cwd.readFileAlloc(io, log1, gpa, .limited(1 << 20)) catch "";
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null) break;
        if (std.mem.indexOf(u8, content, "usersvc: published to the pool") != null) {
            published = true;
            break;
        }
    }
    if (!published) {
        reportFailure(spec.name, "node 1 never published its session manager", log1);
        return false;
    }

    var fd: ?Io.net.Stream = null;
    for (0..50) |_| {
        fd = tcpConnect(port) catch {
            sleepMs(100);
            polls.* += 1;
            continue;
        };
        break;
    }
    const sock = fd orelse {
        reportFailure(spec.name, "console socket never accepted", log2);
        return false;
    };
    const tap = try gpa.create(ConsoleTap);
    tap.* = .{ .stream = sock };
    const th = try std.Thread.spawn(.{}, ConsoleTap.readerLoop, .{tap});
    th.detach();
    if (!waitFor(tap, login_prompt, 600, polls)) {
        reportFailure(spec.name, "no login prompt on node 2", log2);
        return false;
    }
    for (script) |step| {
        tap.clear();
        sockSend(tap.stream, step.send);
        sockSend(tap.stream, "\r");
        const got = (step.expect.len == 0 or waitFor(tap, step.expect, 900, polls)) and
            (step.prompt.len == 0 or waitFor(tap, step.prompt, 900, polls));
        if (!got) {
            std.debug.print("[FAIL] {s}: node 2 console step '{s}' (boot {d}) missing '{s}'\n", .{ spec.name, step.send, boot, step.expect });
            reportFailure(spec.name, "fabric login script step failed", log2);
            return false;
        }
        // Measurements are reported, so every gate run shows the number.
        if (std.mem.startsWith(u8, step.expect, "remote home:")) {
            const line = tap.line(step.expect) orelse "";
            if (std.mem.indexOfScalar(u8, line, '$') != null or std.mem.indexOf(u8, line, " ms") == null) {
                const end = tap.len.load(.acquire);
                std.debug.print("[FAIL] {s}: the measurement was not produced: {s}\n[console] {s}\n", .{ spec.name, line, tap.buf[tap.start..end] });
                reportFailure(spec.name, "a remote-home measurement failed", log2);
                return false;
            }
            std.debug.print("       {s}\n", .{line});
        }
    }
    // The mount is the proof of the transport; the lease's release the
    // proof of the lifecycle — both in the logs.
    const verdict = watch(log2, spec, spec.extra, polls);
    if (!verdict.ok) {
        reportFailure(spec.name, verdict.why, log2);
        return false;
    }
    const n1 = cwd.readFileAlloc(io, log1, gpa, .limited(1 << 20)) catch "";
    const n2 = cwd.readFileAlloc(io, log2, gpa, .limited(1 << 20)) catch "";
    if (std.mem.indexOf(u8, n2, "mounted from node 1 (the key stays here)") == null) {
        reportFailure(spec.name, "node 2 never mounted alice's home from node 1", log2);
        return false;
    }
    if (std.mem.indexOf(u8, n1, "home leased to a session on another node: alice") == null or
        std.mem.indexOf(u8, n1, "lease released on the home of alice") == null)
    {
        reportFailure(spec.name, "node 1 never leased alice's home, or never saw the lease released", log1);
        return false;
    }
    return true;
}

fn sockSend(stream: Io.net.Stream, bytes: []const u8) void {
    var wbuf: [4096]u8 = undefined;
    var writer = stream.writer(io, &wbuf);
    writer.interface.writeAll(bytes) catch return;
    writer.interface.flush() catch return;
}

fn tcpConnect(port: u16) !Io.net.Stream {
    const addr = try Io.net.IpAddress.parse("127.0.0.1", port);
    return addr.connect(io, .{ .mode = .stream });
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

/// The machine, the console log and the kernel — by port. aarch64 boots
/// the raw Image with `-kernel` and takes `-append`; x86_64 boots an ELF
/// through OVMF and Limine from a directory QEMU presents as a FAT
/// volume, the boot arguments in that directory's limine.conf.
fn appendBase(args: *std.ArrayList([]const u8), log_path: []const u8, bin: []const u8, label: []const u8, append: ?[]const u8) !void {
    if (target_arch == .x86_64) return appendBaseX86(args, log_path, bin, label, append);
    try args.appendSlice(gpa, &.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,iommu=smmuv3,virtualization=on",
        "-cpu",
        "cortex-a76",
        "-smp",
        "4",
        "-m",
        "512M",
        "-display",
        "none",
        "-nic",
        "none",
        "-device",
        "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
        "-serial",
        try std.fmt.allocPrint(gpa, "file:{s}", .{log_path}),
        "-kernel",
        bin,
    });
    if (append) |a| try args.appendSlice(gpa, &.{ "-append", a });
}

fn appendBaseX86(args: *std.ArrayList([]const u8), log_path: []const u8, bin: []const u8, label: []const u8, append: ?[]const u8) !void {
    const esp = try std.fmt.allocPrint(gpa, "{s}/esp-{s}", .{ check_dir, label });
    try cwd.createDirPath(io, try std.fmt.allocPrint(gpa, "{s}/EFI/BOOT", .{esp}));
    try cwd.copyFile(try std.fmt.allocPrint(gpa, "{s}/BOOTX64.EFI", .{limine_dir}), cwd, try std.fmt.allocPrint(gpa, "{s}/EFI/BOOT/BOOTX64.EFI", .{esp}), io, .{});
    try cwd.copyFile(bin, cwd, try std.fmt.allocPrint(gpa, "{s}/moss-kernel.elf", .{esp}), io, .{});
    {
        const f = try cwd.createFile(io, try std.fmt.allocPrint(gpa, "{s}/limine.conf", .{esp}), .{ .truncate = true });
        defer f.close(io);
        var wbuf: [512]u8 = undefined;
        var w = f.writer(io, &wbuf);
        try w.interface.print("timeout: 0\nserial: yes\n\n/moss\n    protocol: limine\n    path: boot():/moss-kernel.elf\n    cmdline: {s}\n", .{append orelse ""});
        try w.interface.flush();
    }
    // A scratch variable store per label: OVMF writes it.
    const vars = try std.fmt.allocPrint(gpa, "{s}/{s}-vars.fd", .{ check_dir, label });
    try cwd.copyFile(ovmf_vars, cwd, vars, io, .{});
    try args.appendSlice(gpa, &.{
        "qemu-system-x86_64",
        "-machine",
        "q35",
        "-accel",
        "kvm",
        "-accel",
        "tcg",
        "-cpu",
        "max",
        "-smp",
        "4",
        "-m",
        "512M",
        "-display",
        "none",
        "-monitor",
        "none",
        "-nic",
        "none",
        // The IOMMU first (QEMU wants it before the devices it fronts):
        // scalable mode with first-stage translation, so the domain's own
        // page tables are what devices walk.
        "-device",
        "intel-iommu,x-scalable-mode=on,x-flts=on",
        "-device",
        "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
        "-serial",
        try std.fmt.allocPrint(gpa, "file:{s}", .{log_path}),
        "-drive",
        try std.fmt.allocPrint(gpa, "if=pflash,format=raw,readonly=on,file={s}", .{ovmf_code}),
        "-drive",
        try std.fmt.allocPrint(gpa, "if=pflash,format=raw,file={s}", .{vars}),
        "-drive",
        try std.fmt.allocPrint(gpa, "format=raw,readonly=on,if=virtio,file=fat:ro:{s}", .{esp}),
    });
}

fn appendDisk(args: *std.ArrayList([]const u8), disk: []const u8) !void {
    try args.appendSlice(gpa, &.{
        "-drive",
        try std.fmt.allocPrint(gpa, "if=none,file={s},format=raw,id=hd", .{disk}),
        "-device",
        "virtio-blk-pci,disable-legacy=on,iommu_platform=on,drive=hd",
    });
}

fn makeDisk(path: []const u8) !void {
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.setLength(io, 16 * 1024 * 1024);
}
