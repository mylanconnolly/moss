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

const Kind = enum { plain, blk, net, cluster };

const Spec = struct {
    name: []const u8,
    kind: Kind = .plain,
    pass: []const u8,
    /// Additional marker that must also appear.
    extra: ?[]const u8 = null,
    /// For panic-path tests, "KERNEL PANIC" is the point, not a failure.
    panic_is_failure: bool = true,
    /// Second run on the same disk (persistence); this marker must appear.
    second_run_extra: ?[]const u8 = null,
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
    .{ .name = "blk", .kind = .blk, .pass = "blk-test: PASS" },
    .{
        .name = "fs",
        .kind = .blk,
        .pass = "fs-test: PASS",
        .extra = "formatted fresh mossfs",
        .second_run_extra = "existing mossfs found",
    },
    .{ .name = "net", .kind = .net, .pass = "net-test: PASS" },
    .{ .name = "fabric", .kind = .cluster, .pass = "fabric-test: PASS", .timeout_s = 120 },
};

const check_dir = "zig-out/check";
const cluster_port = "31901";
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
    switch (spec.kind) {
        .blk => try appendDisk(&args, disk),
        .net => try args.appendSlice(gpa, &.{
            "-netdev", "user,id=n0,guestfwd=tcp:10.0.2.100:9000-cmd:cat",
            "-device", "virtio-net-device,netdev=n0",
        }),
        else => {},
    }

    var child = try spawnQemu(args.items);
    defer child.kill(io);
    const verdict = watch(log_path, spec, extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log_path);
    return verdict.ok;
}

fn runCluster(spec: Spec, bin: []const u8, polls: *u64) !bool {
    const log1 = try std.fmt.allocPrint(gpa, "{s}/{s}-node1.log", .{ check_dir, spec.name });
    const log2 = try std.fmt.allocPrint(gpa, "{s}/{s}-node2.log", .{ check_dir, spec.name });
    cwd.deleteFile(io, log1) catch {};
    cwd.deleteFile(io, log2) catch {};

    var args1: std.ArrayList([]const u8) = .empty;
    try appendBase(&args1, log1, bin);
    try args1.appendSlice(gpa, &.{
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=n0,listen=127.0.0.1:{s}", .{cluster_port}),
        "-device", "virtio-net-device,netdev=n0",
        "-append", "node=1",
    });
    var args2: std.ArrayList([]const u8) = .empty;
    try appendBase(&args2, log2, bin);
    try args2.appendSlice(gpa, &.{
        "-netdev", try std.fmt.allocPrint(gpa, "socket,id=n0,connect=127.0.0.1:{s}", .{cluster_port}),
        "-device", "virtio-net-device,netdev=n0",
        "-append", "node=2",
    });

    var c1 = try spawnQemu(args1.items);
    defer c1.kill(io);
    sleepMs(1000);
    var c2 = try spawnQemu(args2.items);
    defer c2.kill(io);

    // The verdict lives in node 1's log.
    const verdict = watch(log1, spec, spec.extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log1);
    return verdict.ok;
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
        if (have_pass and have_extra) return .{ .ok = true };

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
        "-global",
        "virtio-mmio.force-legacy=false",
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
        "virtio-blk-device,drive=hd",
    });
}

fn makeDisk(path: []const u8) !void {
    const f = try cwd.createFile(io, path, .{ .truncate = true });
    defer f.close(io);
    try f.setLength(io, 4 * 1024 * 1024);
}
