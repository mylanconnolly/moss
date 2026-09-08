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

const Kind = enum { plain, blk, net, cluster, shell, vmnode, login, flogin, dot, gpu, term, input, seat, gseat };

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
/// `--tcg`: software emulation even where KVM exists — the way to run
/// the x86_64 drills on a CPU model the host's KVM does not offer (PCIDs
/// on a host kernel that hid them, say).
var force_tcg: bool = false;
var ovmf_code: []const u8 = "/usr/share/qemu/edk2-x86_64-code.fd";
var ovmf_vars: []const u8 = "/usr/share/qemu/edk2-i386-vars.fd";

const specs = [_]Spec{
    .{ .name = "panic", .pass = "KERNEL PANIC: panic test requested", .panic_is_failure = false, .extra_x86 = "fbcon: on the framebuffer" },
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
    .{ .name = "gpu", .kind = .gpu, .pass = "gpu-test: PASS", .extra = "gpu: surface committed", .append = "profile=gpu" },
    .{ .name = "term", .kind = .term, .pass = "term-test: PASS", .extra = "term: rendered", .append = "profile=term" },
    .{ .name = "input", .kind = .input, .pass = "input-test: PASS", .extra = "input: key", .append = "profile=input" },
    .{ .name = "seat", .kind = .seat, .pass = "seat-test: PASS", .extra = "gsh: line hi", .append = "profile=seat" },
    .{ .name = "gseat", .kind = .gseat, .pass = "gseat-test: PASS", .extra = "msh: up, serving the console", .append = "profile=gseat", .timeout_s = 120 },
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
    .{ .name = "net", .kind = .net, .pass = "net-test: PASS", .extra = "mshrun: script: served 7", .always_extra = "echocli: handed-off socket echoed on a new view", .append = "profile=net" },
    .{ .name = "dot", .kind = .dot, .pass = "dot-test: PASS", .extra = "mshrun: script: dot resolve ok", .append = "profile=dot" },
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
/// Where the net drill's TLS server listens on the host (the guest reaches
/// it as 10.0.2.2, slirp's name for the host): `openssl s_server -www`
/// with the certificate for tls.moss.test under lib/tls/.
const tls_port: u16 = 31910;
/// Where the host reaches the moss server's own TLS listener (`serve`
/// over a tls-listener), forwarded to the guest's :8443.
const tls_srv_port: u16 = 31911;
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
    while (i < argv.len and std.mem.startsWith(u8, argv[i], "--")) {
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
        } else if (std.mem.eql(u8, argv[i], "--tcg")) {
            force_tcg = true;
            i += 1;
            continue;
        } else if (std.mem.eql(u8, argv[i], "--limine")) {
            limine_dir = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--ovmf")) {
            ovmf_code = argv[i + 1];
        } else if (std.mem.eql(u8, argv[i], "--ovmf-vars")) {
            ovmf_vars = argv[i + 1];
        } else break;
        i += 2;
    }
    if (repeat == 0 or argv.len - i < 2 or (argv.len - i) % 2 != 0) {
        std.debug.print("usage: runner [--repeat N] [--only a,b] [--arch aarch64|x86_64] [--tcg] [--limine DIR] [--ovmf FD] [--ovmf-vars FD] <name> <kernel> ...\n", .{});
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
    if (spec.kind == .blk or spec.kind == .net or spec.kind == .dot or spec.kind == .gseat) try makeDisk(disk);

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
                "hostfwd=tcp:127.0.0.1:" ++ std.fmt.comptimePrint("{d}", .{http_port}) ++ "-:8080," ++
                "hostfwd=tcp:127.0.0.1:" ++ std.fmt.comptimePrint("{d}", .{tls_srv_port}) ++ "-:8443",
            "-device",
            "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0",
            "-object",
            "filter-dump,id=f0,netdev=n0,file=zig-out/check/net.pcap",
            // Entropy: a TLS handshake draws on the kernel pool, which rngd seeds.
            "-device",
            "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
        }),
        // The DNS-over-TLS drill: a NIC on slirp with a guestfwd to the
        // DoT responder (moss's own TLS server over stdio, one per
        // connection), and an entropy device for dotd's handshakes.
        .dot => try args.appendSlice(gpa, &.{
            "-netdev",
            "user,id=n0,guestfwd=tcp:10.0.2.100:853-cmd:zig-out/bin/dot-responder",
            "-device",
            "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0",
            "-device",
            "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
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
        // The graphical drills: a virtio-gpu to draw on and a QMP port so
        // the host can screendump the scanout (the real-pixels half of the
        // "both" verification) and inject input.
        .gpu, .term => try args.appendSlice(gpa, &.{
            "-device",
            "virtio-gpu-pci,disable-legacy=on,iommu_platform=on",
            "-qmp",
            try std.fmt.allocPrint(gpa, "tcp:127.0.0.1:{d},server=on,wait=off", .{qmp_port}),
        }),
        // The input drill: a virtio keyboard and a QMP port to inject key
        // presses into it.
        .input => try args.appendSlice(gpa, &.{
            "-device",
            "virtio-keyboard-pci,disable-legacy=on,iommu_platform=on",
            "-qmp",
            try std.fmt.allocPrint(gpa, "tcp:127.0.0.1:{d},server=on,wait=off", .{qmp_port}),
        }),
        // The graphical seat: both a display to render on and a keyboard
        // to type into, plus QMP to type and screendump.
        .seat => try args.appendSlice(gpa, &.{
            "-device", "virtio-gpu-pci,disable-legacy=on,iommu_platform=on",
            "-device", "virtio-keyboard-pci,disable-legacy=on,iommu_platform=on",
            "-qmp",    try std.fmt.allocPrint(gpa, "tcp:127.0.0.1:{d},server=on,wait=off", .{qmp_port}),
        }),
        // The real-msh seat: the graphical devices plus a disk for mossfs
        // (the shell's filesystem view).
        .gseat => {
            try args.appendSlice(gpa, &.{
                "-device", "virtio-gpu-pci,disable-legacy=on,iommu_platform=on",
                "-device", "virtio-keyboard-pci,disable-legacy=on,iommu_platform=on",
                "-qmp",    try std.fmt.allocPrint(gpa, "tcp:127.0.0.1:{d},server=on,wait=off", .{qmp_port}),
            });
            try appendDisk(&args, disk);
        },
        else => {},
    }
    // net and dot keep their assets (trust roots) in mossfs, so they
    // boot a scratch disk alongside the NIC.
    if (spec.kind == .net or spec.kind == .dot) try appendDisk(&args, disk);

    var tls_server: ?std.process.Child = null;
    if (spec.kind == .net) tls_server = try spawnQemu(&.{
        "openssl", "s_server",                     "-accept", std.fmt.comptimePrint("127.0.0.1:{d}", .{tls_port}), "-www", "-tls1_3", "-quiet",
        "-cert",   "lib/tls/moss-test-server.pem", "-key",    "lib/tls/moss-test-server.key",
    });
    defer if (tls_server) |*t| t.kill(io);
    var child = try spawnQemu(args.items);
    defer child.kill(io);
    if (spec.kind == .net) {
        if (!try httpProbe(spec, log_path, polls)) return false;
        if (!try tlsProbe(spec, log_path, polls)) return false;
    }
    if (spec.kind == .gpu) {
        if (!try gpuScreendump(spec, log_path, polls)) return false;
    }
    if (spec.kind == .term) {
        if (!try termScreendump(spec, log_path, polls)) return false;
    }
    if (spec.kind == .input) {
        if (!try inputInject(spec, log_path, polls)) return false;
    }
    if (spec.kind == .seat) {
        if (!try seatDrive(spec, log_path, polls)) return false;
    }
    if (spec.kind == .gseat) {
        if (!try gseatDrive(spec, log_path, polls)) return false;
    }
    const verdict = watch(log_path, spec, extra, polls);
    if (!verdict.ok) reportFailure(spec.name, verdict.why, log_path);
    return verdict.ok;
}

/// The graphical drill's host side: once the driver says its scanout is
/// up, screendump the display over QMP and confirm we got a real image —
/// the "real pixels" half of the check (the in-guest readback is the
/// deterministic half). The exact pixel-pattern assertion is tied to
/// what gpusvc draws and lands with it.
fn gpuScreendump(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "gpu: surface committed") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the gpu client never committed a surface", log_path);
            return false;
        }
    }
    var q = qmpConnect(qmp_port) catch {
        reportFailure(spec.name, "could not reach QEMU's QMP port", log_path);
        return false;
    };
    defer q.close();
    const ppm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.ppm", .{ check_dir, spec.name });
    if (!q.screendump(ppm_path)) {
        reportFailure(spec.name, "QMP screendump failed", log_path);
        return false;
    }
    const img = readPpm(ppm_path) orelse {
        reportFailure(spec.name, "the screendump was not a readable image", log_path);
        return false;
    };
    if (img.w == 0 or img.h == 0) {
        reportFailure(spec.name, "the screendump had no pixels", log_path);
        return false;
    }
    // The client fills the surface with colour A and commits it, then a
    // centred 200x120 rect with colour B and commits just that rect. So
    // the centre pixel must be B and a pixel well outside the rect must
    // be A — proving the surface path, a full commit, and a partial
    // damage-rect commit (whose copy walks the framebuffer chunks).
    const inside = pixelAt(img, img.w / 2, img.h / 2);
    const outside = pixelAt(img, 60, 60);
    if (!eqRgb(inside, 0xCC, 0x88, 0x22)) {
        std.debug.print("[FAIL] {s}: centre pixel {any}, wanted (204,136,34)\n", .{ spec.name, inside });
        reportFailure(spec.name, "the damage-rect commit did not show", log_path);
        return false;
    }
    if (!eqRgb(outside, 0x22, 0x44, 0x66)) {
        std.debug.print("[FAIL] {s}: corner pixel {any}, wanted (34,68,102)\n", .{ spec.name, outside });
        reportFailure(spec.name, "the full commit did not show", log_path);
        return false;
    }
    return true;
}

fn pixelAt(img: Ppm, x: usize, y: usize) [3]u8 {
    const o = (y * img.w + x) * 3;
    return .{ img.px[o], img.px[o + 1], img.px[o + 2] };
}
fn eqRgb(p: [3]u8, r: u8, g: u8, b: u8) bool {
    return p[0] == r and p[1] == g and p[2] == b;
}

/// The terminal drill's host side: once the terminal says it rendered,
/// screendump and check the glyph grid — the cursor block is a solid
/// white cell (font-independent, so a deterministic anchor), the text
/// area has white glyph pixels, and a blank cell stayed black (no bleed).
fn termScreendump(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "term: rendered") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the terminal never rendered", log_path);
            return false;
        }
    }
    var q = qmpConnect(qmp_port) catch {
        reportFailure(spec.name, "could not reach QEMU's QMP port", log_path);
        return false;
    };
    defer q.close();
    const ppm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.ppm", .{ check_dir, spec.name });
    if (!q.screendump(ppm_path)) {
        reportFailure(spec.name, "QMP screendump failed", log_path);
        return false;
    }
    const img = readPpm(ppm_path) orelse {
        reportFailure(spec.name, "the screendump was not a readable image", log_path);
        return false;
    };
    // The cursor block sits at cell (0,29): a solid white 8x16 rectangle.
    if (img.w < 8 or img.h < 480 or !eqRgb(pixelAt(img, 4, 472), 0xFF, 0xFF, 0xFF)) {
        reportFailure(spec.name, "the cursor block was not drawn", log_path);
        return false;
    }
    // Glyphs in the top-left text region (some white pixels there).
    var any_glyph = false;
    for (0..16) |y| for (0..48) |x| {
        if (eqRgb(pixelAt(img, x, y), 0xFF, 0xFF, 0xFF)) any_glyph = true;
    };
    if (!any_glyph) {
        reportFailure(spec.name, "no glyphs were rendered", log_path);
        return false;
    }
    // A blank cell (far right of a short text row) stayed black.
    if (!eqRgb(pixelAt(img, 500, 8), 0, 0, 0)) {
        reportFailure(spec.name, "text bled into a blank cell", log_path);
        return false;
    }
    return true;
}

/// The input drill's host side: once the driver says it is ready, inject
/// two key presses over QMP. The driver decodes them, logs each keycode,
/// and exits after the expected count — so a clean shutdown (the PASS)
/// is itself the proof the events were received and decoded.
fn inputInject(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "input: ready") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the input driver never became ready", log_path);
            return false;
        }
    }
    var q = qmpConnect(qmp_port) catch {
        reportFailure(spec.name, "could not reach QEMU's QMP port", log_path);
        return false;
    };
    defer q.close();
    if (!q.sendKey("h") or !q.sendKey("i")) {
        reportFailure(spec.name, "QMP could not inject key presses", log_path);
        return false;
    }
    // Confirm the driver decoded the two presses to the right evdev
    // keycodes (KEY_H = 35, KEY_I = 23) before the boot ends.
    var m: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        m += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "input: key 35") != null and
            std.mem.indexOf(u8, content, "input: key 23") != null) return true;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or m * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the injected keys were not decoded (wanted codes 35 and 23)", log_path);
            return false;
        }
    }
}

/// The graphical seat's host side: once the session prints its prompt,
/// type a line on the (virtual) keyboard and confirm it travelled all the
/// way through — inputsvc decoded it, the terminal rendered it, and the
/// session read it back (the "gsh: line hi" marker) — then screendump and
/// confirm the terminal actually has glyphs on screen.
fn seatDrive(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "gsh: ready") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the graphical session never started", log_path);
            return false;
        }
    }
    var q = qmpConnect(qmp_port) catch {
        reportFailure(spec.name, "could not reach QEMU's QMP port", log_path);
        return false;
    };
    defer q.close();
    if (!q.sendKey("h") or !q.sendKey("i") or !q.sendKey("ret")) {
        reportFailure(spec.name, "QMP could not type the line", log_path);
        return false;
    }
    // The line crossed keyboard -> inputsvc -> terminal -> session.
    var m: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        m += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "gsh: line hi") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or m * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the typed line did not reach the session", log_path);
            return false;
        }
    }
    const ppm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.ppm", .{ check_dir, spec.name });
    if (!q.screendump(ppm_path)) {
        reportFailure(spec.name, "QMP screendump failed", log_path);
        return false;
    }
    const img = readPpm(ppm_path) orelse {
        reportFailure(spec.name, "the screendump was not a readable image", log_path);
        return false;
    };
    // The terminal has glyphs on screen (white pixels in the top rows).
    var any_glyph = false;
    var y: usize = 0;
    while (y < 48 and y < img.h) : (y += 1) {
        var x: usize = 0;
        while (x < img.w) : (x += 1) {
            if (eqRgb(pixelAt(img, x, y), 0xFF, 0xFF, 0xFF)) any_glyph = true;
        }
    }
    if (!any_glyph) {
        reportFailure(spec.name, "the terminal showed no text", log_path);
        return false;
    }
    return true;
}

/// The real-msh seat's host side: once the shell is up on the graphical
/// console, type a command on the (virtual) keyboard and screendump to
/// confirm the terminal has the shell's output on screen, then type
/// `exit` — the shell reads it from the keyboard and exits, ending the
/// boot (the PASS), which proves the real shell read real keystrokes.
fn gseatDrive(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "msh: up, serving the console") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "msh never came up on the graphical console", log_path);
            return false;
        }
    }
    var q = qmpConnect(qmp_port) catch {
        reportFailure(spec.name, "could not reach QEMU's QMP port", log_path);
        return false;
    };
    defer q.close();
    if (!q.typeText("echo hi\n")) {
        reportFailure(spec.name, "QMP could not type a command", log_path);
        return false;
    }
    sleepMs(500); // let msh render the command and its output
    const ppm_path = try std.fmt.allocPrint(gpa, "{s}/{s}.ppm", .{ check_dir, spec.name });
    if (!q.screendump(ppm_path)) {
        reportFailure(spec.name, "QMP screendump failed", log_path);
        return false;
    }
    const img = readPpm(ppm_path) orelse {
        reportFailure(spec.name, "the screendump was not a readable image", log_path);
        return false;
    };
    var any_glyph = false;
    var y: usize = 0;
    while (y < 64 and y < img.h) : (y += 1) {
        var x: usize = 0;
        while (x < img.w) : (x += 1) {
            if (eqRgb(pixelAt(img, x, y), 0xFF, 0xFF, 0xFF)) any_glyph = true;
        }
    }
    if (!any_glyph) {
        reportFailure(spec.name, "the shell rendered no text on the terminal", log_path);
        return false;
    }
    // `exit` typed on the keyboard: the real shell reads it and exits.
    if (!q.typeText("exit\n")) {
        reportFailure(spec.name, "QMP could not type exit", log_path);
        return false;
    }
    return true;
}

/// The net check's client side: once the script says it is serving,
/// fetch four pages through the port forward and check each answer.
fn httpProbe(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "script: serving http") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the script never started serving http", log_path);
            return false;
        }
    }
    // Each probe is one connection; the last request on it says close,
    // so the read runs to the close. Probe 5 pipelines two requests on a
    // kept connection; probe 6 sends a chunked body.
    const probes = [_]struct { req: []const u8, expect: []const u8, expect2: []const u8 }{
        .{ .req = "GET /hello HTTP/1.1\r\nHost: moss\r\nConnection: close\r\n\r\n", .expect = "\r\nDate: ", .expect2 = "\r\n\r\nhello from moss" },
        .{ .req = "GET /json HTTP/1.1\r\nHost: moss\r\nConnection: close\r\n\r\n", .expect = "Content-Type: application/json", .expect2 = "[{\"n\":1},{\"n\":2}]" },
        .{ .req = "POST /echo HTTP/1.1\r\nHost: moss\r\nContent-Length: 7\r\nConnection: close\r\n\r\npayload", .expect = "x-method: POST", .expect2 = "\r\n\r\npayload" },
        .{ .req = "GET /nope HTTP/1.1\r\nHost: moss\r\nConnection: close\r\n\r\n", .expect = "HTTP/1.1 404 Not Found", .expect2 = "no such page" },
        .{ .req = "GET /hello HTTP/1.1\r\nHost: moss\r\n\r\nGET /json HTTP/1.1\r\nHost: moss\r\nConnection: close\r\n\r\n", .expect = "Connection: keep-alive\r\n\r\nhello from moss", .expect2 = "Connection: close\r\n\r\n[{\"n\":1},{\"n\":2}]" },
        .{ .req = "POST /echo HTTP/1.1\r\nHost: moss\r\nTransfer-Encoding: chunked\r\nConnection: close\r\n\r\n3\r\npay\r\n4\r\nload\r\n0\r\n\r\n", .expect = "x-method: POST", .expect2 = "Content-Length: 7\r\nConnection: close\r\n\r\npayload" },
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

/// The net check's TLS server side: once the script says it is serving
/// https, connect with `openssl s_client` (an independent TLS
/// implementation), verifying the moss server's certificate against the
/// drill's root, and check the page it serves.
fn tlsProbe(spec: Spec, log_path: []const u8, polls: *u64) !bool {
    var n: u64 = 0;
    while (true) {
        sleepMs(poll_ms);
        n += 1;
        polls.* += 1;
        const content = readLog(log_path);
        if (std.mem.indexOf(u8, content, "script: serving https") != null) break;
        if (std.mem.indexOf(u8, content, "KERNEL PANIC") != null or n * poll_ms / 1000 > spec.timeout_s) {
            reportFailure(spec.name, "the script never started serving https", log_path);
            return false;
        }
    }
    // Run under a shell so the HTTP request feeds openssl's stdin and its
    // diagnostics (the chain verification, any alert) land in a file we
    // can read on failure. -verify_return_error makes a bad chain a
    // nonzero exit; -ign_eof keeps the request from tearing the socket
    // down before the reply arrives.
    const err_file = std.fmt.comptimePrint("zig-out/check/tls-s_client.err", .{});
    const cmd = std.fmt.comptimePrint(
        "printf 'GET / HTTP/1.1\\r\\nHost: tls.moss.test\\r\\nConnection: close\\r\\n\\r\\n' | " ++
            "openssl s_client -connect 127.0.0.1:{d} -servername tls.moss.test " ++
            "-CAfile lib/tls/moss-test-ca.pem -verify_return_error -quiet -ign_eof 2>{s}",
        .{ tls_srv_port, err_file },
    );
    var child = std.process.spawn(io, .{
        .argv = &.{ "sh", "-c", cmd },
        .stdin = .ignore,
        .stdout = .pipe,
        .stderr = .ignore,
    }) catch |e| {
        std.debug.print("[FAIL] {s}: could not spawn openssl s_client: {s}\n", .{ spec.name, @errorName(e) });
        reportFailure(spec.name, "openssl s_client did not run", log_path);
        return false;
    };
    defer child.kill(io);
    var resp: std.ArrayList(u8) = .empty;
    var rbuf: [4096]u8 = undefined;
    var reader = child.stdout.?.reader(io, &rbuf);
    reader.interface.appendRemainingUnlimited(gpa, &resp) catch {};
    if (std.mem.indexOf(u8, resp.items, "secure hello from moss") == null) {
        const errs = cwd.readFileAlloc(io, err_file, gpa, .limited(4096)) catch "";
        std.debug.print("[FAIL] {s}: tls server probe got:\n{s}\n--- openssl stderr ---\n{s}\n", .{ spec.name, resp.items, errs });
        reportFailure(spec.name, "the tls server answered wrong or was not trusted", log_path);
        return false;
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
        const content = readLog(log1);
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
    const n3 = readLog(log3);
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
    const n2b = readLog(log2b);
    if (std.mem.indexOf(u8, n2b, "revocation accepted from trust root") == null) {
        reportFailure(spec.name, "revocation never reached node 2 by gossip", log2b);
        return false;
    }
    const n9 = readLog(log9);
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
    .{ .send = "start greeter", .expect = "started" },
    .{ .send = "svc", .expect = "up" },
    .{ .send = "stop greeter", .expect = "stopped" },
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
    // A user marked absent goes — record and home; a missing name never
    // means that. Then the override is removed and the default re-applied,
    // so the second boot finds the same two users.
    .{ .send = "write conf/system.msh \"{ users: [ { name: alice, absent: true } ] }\"", .expect = "" },
    .{ .send = "run apply? | where action == removed | get name", .expect = "alice" },
    .{ .send = "ls conf/users? | get name", .expect = "bob.msh" },
    .{ .send = "ls home? | where name == alice | len", .expect = "0" },
    .{ .send = "rm conf/system.msh", .expect = "" },
    .{ .send = "run apply? | where action == created | get name", .expect = "alice" },
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
    // mtime is the wall clock now (the first cut wrote seconds since boot).
    .{ .send = "(stat data/smoke/hi.txt)?.mtime > 1700000000", .expect = "true" },
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
    // Floats and the numeric tower: a float promotes an int, two ints stay integer.
    .{ .send = "1.5 * 4.0", .expect = "6.0" },
    .{ .send = "(float (ls data/smoke? | get size | first 1).0)? / 4.0", .expect = "6.5" },
    .{ .send = "1 + 1.5", .expect = "2.5" },
    .{ .send = "7 / 2", .expect = "3" },
    .{ .send = "2 == 2.0", .expect = "true" },
    // Shapes: checked where they run; every host command has a signature.
    .{ .send = "let e: { name: string, size: int } = (stat data/smoke/hi.txt)?; $e.size", .expect = "26" },
    .{ .send = "let e: { name: int } = (stat data/smoke/hi.txt)?", .expect = "error: let: e.name is hi.txt, not int" },
    .{ .send = "def size-of [p: string] -> int { (stat $p)?.size }; size-of data/smoke/hi.txt", .expect = "26" },
    .{ .send = "size-of 3", .expect = "error: size-of: p is 3, not string" },
    // Workers: a block runs in its own domain, called many times, then dropped.
    .{ .send = "let w = (spawn { $in + 1 })?; (5 | call $w)?", .expect = "6" },
    .{ .send = "let w = (spawn { $in * 10 })?; let a = (2 | call $w)?; let b = (3 | call $w)?; \"$a $b\"", .expect = "20 30" },
    .{ .send = "let w = (spawn { (err \"boom\")? })?; 0 | call $w", .expect = "err boom" },
    .{ .send = "let w = (spawn { $in.x + $in.y })?; ({ x: 3, y: 4 } | call $w)?", .expect = "7" },
    .{ .send = "let w = (spawn { (int $in)? * 2 })?; (\"21\" | call $w)?", .expect = "42" },
    .{ .send = "let w = (spawn { (stat $in)?.size })?; (\"data/smoke/hi.txt\" | call $w)?", .expect = "26" },
    // A script (not the interactive shell) spawns workers too: run mshrun
    // on a script that offloads compute and a file stat to workers.
    .{ .send = "run mshrun scripts/worker-demo.msh?", .expect = "42 26" },
    // Async: start dispatches without blocking, await joins for the result.
    .{ .send = "let w = (spawn { (int $in)? * 2 })?; (21 | dispatch $w)?; (await $w)?", .expect = "42" },
    // Two workers started before either is awaited run in parallel.
    .{ .send = "let a = (spawn { (int $in)? + 1 })?; let b = (spawn { (int $in)? + 1 })?; (10 | dispatch $a)?; (20 | dispatch $b)?; let x = (await $a)?; let y = (await $b)?; \"$x $y\"", .expect = "11 21" },
    // A handler error surfaces at await, as the collected result's err.
    .{ .send = "let w = (spawn { (err \"boom\")? })?; (0 | dispatch $w)?; await $w", .expect = "err boom" },
    // await with nothing started is an err, not a hang.
    .{ .send = "let w = (spawn { $in })?; await $w", .expect = "err nothing to await" },
    // race returns the first dispatched worker to finish: b (no sleep)
    // beats a (sleeps), so it comes back first, then a.
    .{ .send = "let a = (spawn { sleep 300; 1 })?; let b = (spawn { 2 })?; (0 | dispatch $a)?; (0 | dispatch $b)?; let f = (race [$a, $b])?; let v1 = (await $f)?; let s = (race [$a, $b])?; let v2 = (await $s)?; \"$v1 $v2\"", .expect = "2 1" },
    // race over workers none of which is dispatched is an err, not a hang.
    .{ .send = "let w = (spawn { $in })?; race [$w]", .expect = "err race: none of these workers is running" },
    // publish a worker to the pool under a service id, then reach it back
    // through lookup on this node (1) and call it — the fabric surface.
    .{ .send = "let pw = (spawn { (int $in)? * 2 })?; (publish \"myworker\" $pw)?; let svc = (lookup 1 \"myworker\")?; (21 | call $svc)?", .expect = "42" },
    // a published worker is reached only through lookup: a direct call errs.
    .{ .send = "(5 | call $pw)", .expect = "err the worker is published" },
    // dial a durable service unit: init starts and supervises it (no
    // keep-alive loop), and hands back a channel we call. Service 4 is
    // the doubler unit (conf/units/doubler.msh, mshrun in service mode).
    .{ .send = "let ds = (dial \"doubler\")?; (21 | call $ds)?", .expect = "42" },
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
    // A share stands: alice offers again and leaves; the offer is gone
    // with her session and back the moment she is, for bob to accept.
    .{ .con = 0, .send = "share notes shared bob", .expect = "" },
    .{ .con = 1, .send = "shares | get path", .expect = "notes" },
    // A passphrase is the user's to change: the old one proves the right,
    // the new one opens the same home at the next login (the identity
    // keys the volume, not the passphrase). Folded into the logout just
    // below, so the drill gains no extra login cycle on this seat.
    .{ .con = 0, .send = "passwd wrong-pass alice-new", .expect = "err denied" },
    .{ .con = 0, .send = "passwd alice-pass alice-new", .expect = "" },
    // Alice leaves; her session is torn down and the seat is free again.
    .{ .con = 0, .send = "exit", .expect = "bye", .prompt = login_prompt },
    .{ .con = 1, .send = "shares | len", .expect = "0" },
    .{ .con = 0, .send = "alice", .expect = "passphrase: ", .prompt = "" },
    .{ .con = 0, .send = "alice-new", .expect = "moss shell" },
    .{ .con = 0, .send = "cat notes/a.txt", .expect = "alice was here" },
    .{ .con = 1, .send = "shares | get name", .expect = "shared" },
    .{ .con = 1, .send = "accept shared", .expect = "" },
    .{ .con = 1, .send = "cat @shared/a.txt", .expect = "alice was here" },
    .{ .con = 0, .send = "unshare shared", .expect = "" },
    .{ .con = 1, .send = "shares | len", .expect = "0" },
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
        const content = readLog(log1);
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
    const n1 = readLog(log1);
    const n2 = readLog(log2);
    if (std.mem.indexOf(u8, n2, "mounted from node 1 (the key stays here)") == null) {
        reportFailure(spec.name, "node 2 never mounted alice's home from node 1", log2);
        return false;
    }
    // The fabric's time: node 2 synced its clock from node 1.
    if (std.mem.indexOf(u8, n2, "clock: synced from 10.77.0.1") == null) {
        reportFailure(spec.name, "node 2 never synced its clock from node 1", log2);
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

// -------------------------------------------------------------- QMP
//
// A minimal QMP client over TCP: enough to hand-shake and drive one
// synchronous command at a time (screendump for real pixels, send-key /
// input-send-event for real input) so the graphical drills can be
// checked the way the net drill is checked from the host. QEMU speaks
// line-delimited JSON; we scan the accumulated bytes for a top-level
// `"return"` (ok) or `"error"` (failed), skipping the greeting and any
// asynchronous events, which carry neither. The display drills open the
// port with `-qmp tcp:127.0.0.1:<qmp_port>,server=on,wait=off`.

const qmp_port: u16 = 31913;

const Qmp = struct {
    stream: Io.net.Stream,
    buf: [16384]u8 = undefined,
    len: usize = 0,

    fn close(q: *Qmp) void {
        q.stream.close(io);
    }

    fn send(q: *Qmp, line: []const u8) void {
        sockSend(q.stream, line);
        sockSend(q.stream, "\n");
    }

    /// Wait (bounded, ~10s) for a reply object; true on `"return"`,
    /// false on `"error"`, timeout, or a closed connection.
    fn awaitReply(q: *Qmp) bool {
        q.len = 0;
        var tries: usize = 0;
        while (tries < 100) : (tries += 1) {
            if (std.mem.indexOf(u8, q.buf[0..q.len], "\"return\"") != null) return true;
            if (std.mem.indexOf(u8, q.buf[0..q.len], "\"error\"") != null) return false;
            var pfd = [_]std.posix.pollfd{.{ .fd = q.stream.socket.handle, .events = std.posix.POLL.IN, .revents = 0 }};
            const ready = std.posix.poll(&pfd, 100) catch return false;
            if (ready == 0) continue;
            if (q.len == q.buf.len) return false; // reply larger than we hold
            const n = std.posix.read(q.stream.socket.handle, q.buf[q.len..]) catch return false;
            if (n == 0) return false;
            q.len += n;
        }
        return false;
    }

    fn execute(q: *Qmp, line: []const u8) bool {
        q.send(line);
        return q.awaitReply();
    }

    /// Write the current scanout to `ppm_path` (QEMU's binary P6).
    fn screendump(q: *Qmp, ppm_path: []const u8) bool {
        const cmd = std.fmt.allocPrint(gpa, "{{\"execute\":\"screendump\",\"arguments\":{{\"filename\":\"{s}\"}}}}", .{ppm_path}) catch return false;
        return q.execute(cmd);
    }

    /// Press and release one key (a QEMU qcode, e.g. "h"). QEMU translates
    /// it to the guest's evdev keycode for the virtio keyboard.
    fn sendKey(q: *Qmp, qcode: []const u8) bool {
        const down = std.fmt.allocPrint(gpa, "{{\"execute\":\"input-send-event\",\"arguments\":{{\"events\":[{{\"type\":\"key\",\"data\":{{\"down\":true,\"key\":{{\"type\":\"qcode\",\"data\":\"{s}\"}}}}}}]}}}}", .{qcode}) catch return false;
        if (!q.execute(down)) return false;
        const up = std.fmt.allocPrint(gpa, "{{\"execute\":\"input-send-event\",\"arguments\":{{\"events\":[{{\"type\":\"key\",\"data\":{{\"down\":false,\"key\":{{\"type\":\"qcode\",\"data\":\"{s}\"}}}}}}]}}}}", .{qcode}) catch return false;
        return q.execute(up);
    }

    /// Type a line of lowercase letters, digits, spaces and newlines by
    /// their qcodes (enough for a simple shell command).
    fn typeText(q: *Qmp, s: []const u8) bool {
        for (s) |c| {
            const qcode: []const u8 = switch (c) {
                'a'...'z' => &.{c},
                '0'...'9' => &.{c},
                ' ' => "spc",
                '\n' => "ret",
                else => continue,
            };
            if (!q.sendKey(qcode)) return false;
        }
        return true;
    }
};

/// Connect to the QMP port (retrying while QEMU comes up) and complete
/// the capabilities handshake.
fn qmpConnect(port: u16) !Qmp {
    var conn: ?Io.net.Stream = null;
    for (0..50) |_| {
        conn = tcpConnect(port) catch {
            sleepMs(poll_ms);
            continue;
        };
        break;
    }
    var q = Qmp{ .stream = conn orelse return error.QmpConnect };
    if (!q.execute("{\"execute\":\"qmp_capabilities\"}")) {
        q.close();
        return error.QmpHandshake;
    }
    return q;
}

const Ppm = struct { w: usize, h: usize, px: []const u8 };

/// Parse a QEMU screendump (binary P6, maxval 255). Null on malformation.
fn readPpm(path: []const u8) ?Ppm {
    const data = cwd.readFileAlloc(io, path, gpa, .limited(64 << 20)) catch return null;
    if (data.len < 2 or data[0] != 'P' or data[1] != '6') return null;
    var i: usize = 2;
    const w = ppmUint(data, &i) orelse return null;
    const h = ppmUint(data, &i) orelse return null;
    const maxv = ppmUint(data, &i) orelse return null;
    if (maxv != 255 or i >= data.len) return null;
    i += 1; // the single whitespace byte after maxval, then the pixels
    const need = w * h * 3;
    if (data.len - i < need) return null;
    return .{ .w = w, .h = h, .px = data[i .. i + need] };
}

fn ppmUint(data: []const u8, i: *usize) ?usize {
    while (i.* < data.len and (data[i.*] == ' ' or data[i.*] == '\n' or data[i.*] == '\t' or data[i.*] == '\r')) i.* += 1;
    var v: usize = 0;
    var any = false;
    while (i.* < data.len and data[i.*] >= '0' and data[i.*] <= '9') : (i.* += 1) {
        v = v * 10 + (data[i.*] - '0');
        any = true;
    }
    return if (any) v else null;
}

/// A log as read for matching: every line's clock stamp removed (see
/// stripLine), so markers name what was said, not when.
fn readLog(path: []const u8) []const u8 {
    const raw = cwd.readFileAlloc(io, path, gpa, .limited(1 << 20)) catch return "";
    var out = gpa.alloc(u8, raw.len) catch return raw;
    var n: usize = 0;
    var lines = std.mem.splitScalar(u8, raw, '\n');
    var first = true;
    while (lines.next()) |line| {
        if (!first) {
            out[n] = '\n';
            n += 1;
        }
        first = false;
        n += stripLine(out[n..], line);
    }
    return out[0..n];
}

/// One log line with its clock stamps (`03:14:22.123 ` or `+12.345 `)
/// removed: at the start, and again after a guest's `guest| ` prefix
/// wherever that sits — a guest's console comes through the host VMM's
/// own stamped log line. Returns the length written to `out`.
fn stripLine(out: []u8, line: []const u8) usize {
    var n: usize = 0;
    var rest = line[stampLen(line)..];
    for ([_][]const u8{ "guest| ", "guest> " }) |pre| {
        if (std.mem.indexOf(u8, rest, pre)) |at| {
            const head = rest[0 .. at + pre.len];
            @memcpy(out[n .. n + head.len], head);
            n += head.len;
            rest = rest[head.len..];
            break;
        }
    }
    rest = rest[stampLen(rest)..];
    @memcpy(out[n .. n + rest.len], rest);
    return n + rest.len;
}

test "stripLine removes the host's and the guest's stamps" {
    var buf: [128]u8 = undefined;
    const cases = [_][2][]const u8{
        .{ "+0.035 [info ] smmu: up", "[info ] smmu: up" },
        .{ "19:27:50.469 [vmm] guest| +0.502 [info ] smp: 4 cores online", "[vmm] guest| [info ] smp: 4 cores online" },
        .{ "guest| 03:14:22.123 [init] init: system up", "guest| [init] init: system up" },
        .{ "guest> ok", "guest> ok" },
        .{ "no stamp here", "no stamp here" },
        .{ "", "" },
    };
    for (cases) |c| try std.testing.expectEqualStrings(c[1], buf[0..stripLine(&buf, c[0])]);
}

/// The length of a clock stamp at the start of a line, with its space.
fn stampLen(line: []const u8) usize {
    if (line.len >= 13 and line[2] == ':' and line[5] == ':' and line[8] == '.' and line[12] == ' ') {
        for ([_]usize{ 0, 1, 3, 4, 6, 7, 9, 10, 11 }) |i| if (!std.ascii.isDigit(line[i])) return 0;
        return 13;
    }
    if (line.len > 6 and line[0] == '+' and std.ascii.isDigit(line[1])) {
        if (std.mem.indexOfScalar(u8, line, ' ')) |sp| {
            if (sp >= 6 and line[sp - 4] == '.') return sp + 1;
        }
    }
    return 0;
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

        const content = readLog(log_path);

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
    const content = readLog(log_path);
    if (content.len == 0) return;
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
    try args.appendSlice(gpa, &.{ "qemu-system-x86_64", "-machine", "q35" });
    if (!force_tcg) try args.appendSlice(gpa, &.{ "-accel", "kvm" });
    try args.appendSlice(gpa, &.{
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
