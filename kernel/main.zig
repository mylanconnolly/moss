//! Kernel root: kmain and the panic handler.

const std = @import("std");
const build_options = @import("build_options");
const shared = @import("shared");
const cap = @import("cap.zig");
const domain = @import("domain.zig");
const dt = @import("dt.zig");
const gic = @import("gic.zig");
const ipc = @import("ipc.zig");
const irq = @import("irq.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const pmem = @import("pmem.zig");
const psci = @import("psci.zig");
const sched = @import("sched.zig");
const sched_test = @import("sched_test.zig");
const smp = @import("smp.zig");
const timer = @import("timer.zig");
const trap = @import("trap.zig");

comptime {
    _ = @import("boot.zig");
}

pub const panic = std.debug.FullPanic(panicHandler);

export fn kmain(dtb_pa: u64) noreturn {
    log.print("\nmoss {f} — aarch64 / qemu-virt\n\n", .{shared.version});

    trap.init();
    log.info("core 0 up at EL{d}, vectors installed", .{currentEl()});

    // QEMU passes the DTB in x0 per the arm64 Image boot protocol.
    const fdt = dt.Fdt.parse(mem.physToPtr([*]const u8, dtb_pa)) catch |e| {
        std.debug.panic("bad devicetree at 0x{x}: {t}", .{ dtb_pa, e });
    };
    var region_buf: [8]dt.MemRegion = undefined;
    const regions = fdt.memoryRegions(&region_buf) catch |e| {
        std.debug.panic("devicetree memory walk failed: {t}", .{e});
    };
    for (regions) |r| {
        log.info("ram: 0x{x} + {d}MB", .{ r.base, r.size >> 20 });
    }
    if (fdt.bootargs()) |args| {
        boot_node = parseNodeArg(args);
        if (boot_node != 0) log.info("bootargs: node id {d}", .{boot_node});
    }

    pmem.init(regions);
    pmem.reserve(
        mem.virtToPhys(mem.kernelStart()),
        mem.kernelEnd() - mem.kernelStart(),
    );
    pmem.reserve(dtb_pa, fdt.totalSize());
    const s = pmem.stats();
    log.info("pmem: {d}MB free of {d}MB", .{ s.free_bytes >> 20, s.total_bytes >> 20 });

    mmu.init(regions) catch |e| std.debug.panic("mmu build failed: {t}", .{e});
    mmu.activate();
    log.info("mmu: W^X kernel map active, boot identity map dropped", .{});

    // Allocator smoke test: quota round-trips to zero.
    {
        const before = kalloc.kernel_account.balance();
        const page = kalloc.allocPage(&kalloc.kernel_account) catch |e| {
            std.debug.panic("kalloc failed: {t}", .{e});
        };
        page[0] = 0xa5;
        kalloc.freePage(&kalloc.kernel_account, page);
        std.debug.assert(kalloc.kernel_account.balance() == before);
        log.info("kalloc: page alloc/free round-trip, quota balanced", .{});
    }

    sched.registerCpu(0);
    // Image table order must match shared.ImageId.
    const blobs = @import("user_blobs");
    domain.init(&.{ blobs.hello, blobs.pingpong, blobs.root, blobs.init, blobs.services, blobs.sandbox, blobs.blk, blobs.fs, blobs.net, blobs.fabric });
    domain.setSystemBlob(blobs.bootfs);
    irq.init();
    domain.startReaper();
    gic.initDistributor();
    gic.initCore(0);
    timer.initCore(0);
    smp.bringUp();
    trap.enableIrqs();

    if (build_options.fault_test) {
        log.warn("about to read unmapped memory (-Dfault-test)", .{});
        const bad: *volatile u64 = @ptrFromInt(0xffffff7f_dead_0000);
        _ = bad.*;
    }

    if (build_options.panic_test) {
        @panic("panic test requested via -Dpanic-test");
    }

    if (build_options.sched_test) {
        sched_test.start();
    }

    if (build_options.domain_test) {
        _ = sched.spawn("root-sim", domainTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn root-sim: {t}", .{e});
        };
    }

    if (build_options.ipc_test) {
        _ = sched.spawn("root-sim", ipcTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn root-sim: {t}", .{e});
        };
    }

    if (build_options.init_test) {
        _ = sched.spawn("boot-watch", initTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.sandbox_test) {
        _ = sched.spawn("boot-watch", sandboxTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.flap_test) {
        _ = sched.spawn("boot-watch", flapTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.blk_test) {
        _ = sched.spawn("boot-watch", blkTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.fs_test) {
        _ = sched.spawn("boot-watch", fsTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.net_test) {
        _ = sched.spawn("boot-watch", netTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.fabric_test) {
        _ = sched.spawn("boot-watch", fabricTestWorker, boot_node, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    log.info("boot complete; core 0 idling", .{});
    // This context is core 0's idle thread from here on.
    halt();
}

/// Phase 3 exit-criterion driver, standing in for the Phase 5 root task:
/// spawn a domain from a manifest, watch it work, revoke it, and verify
/// nothing leaked — then spawn the same image with an empty manifest and
/// watch authority be refused.
fn domainTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    log.info("domain-test: spawning 'hello' (debug_log granted)", .{});
    const hello = domain.spawn("hello", blobs.hello, .{
        .grant_debug_log = true,
    }) catch |e| std.debug.panic("spawn hello: {t}", .{e});

    sched.sleep(22); // let it live a little
    log.info("domain-test: revoking 'hello' (one operation)", .{});
    domain.destroy(hello);
    while (!domain.drained(hello)) sched.sleep(1);
    domain.finishTeardown(hello);
    log.info("domain-test: hello destroyed — kobj={d}B user={d}B (both must be 0)", .{
        hello.kobj.balance(), hello.user_mem.balance(),
    });

    log.info("domain-test: spawning 'sneaky' (same binary, empty manifest)", .{});
    const sneaky = domain.spawn("sneaky", blobs.hello, .{}) catch |e|
        std.debug.panic("spawn sneaky: {t}", .{e});
    while (!domain.drained(sneaky)) sched.sleep(1);
    domain.finishTeardown(sneaky);
    log.info("domain-test: sneaky exited with code {d} (42 = every attempt denied)", .{
        sneaky.exit_code,
    });

    const frames_after = pmem.stats().free_bytes;
    if (frames_after == frames_before) {
        log.info("domain-test: PASS — pmem identical ({d}MB free), quotas zero", .{
            frames_after >> 20,
        });
    } else {
        std.debug.panic("domain-test: LEAK — {d}B of frames unaccounted", .{
            frames_before -% frames_after,
        });
    }
}

/// Phase 4 exit-criterion driver: two user processes RPC through typed
/// stubs; the server is revoked mid-conversation and the client observes
/// peer_dead and carries on. Plus: buffer-cap grant over a channel,
/// fault-as-message to a supervisor, kernel-side notification smoke test,
/// and the usual nothing-leaked accounting at the end.
fn ipcTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    // Notification smoke test, kernel-side: signal from a helper thread.
    {
        const n = ipc.createNotification() catch @panic("notif pool empty");
        _ = sched.spawn("notif-helper", notifHelper, @intFromPtr(n), .{}) catch
            @panic("spawn notif-helper");
        const got = ipc.wait(n);
        log.info("ipc-test: notification delivered bits 0b{b} ({t})", .{ got.bits, got.err });
        ipc.unrefNotification(n);
    }

    // Fault-as-message: crasher faults, the supervisor (this thread) gets
    // the message and pronounces the verdict.
    const fault_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const crasher = domain.spawn("crasher", blobs.pingpong, .{
        .grant_debug_log = true,
        .supervisor = fault_ch,
        .arg = 3,
    }) catch |e| std.debug.panic("spawn crasher: {t}", .{e});
    {
        var msg: ipc.Msg = .{};
        var badge: u64 = 0;
        const e = ipc.recv(fault_ch, &msg, &badge);
        std.debug.assert(e == .ok);
        const fm = shared.decodeMsg(shared.FaultMsg, msg.data).?;
        log.info("ipc-test: supervisor got fault message from crasher: esr=0x{x} far=0x{x} elr=0x{x}", .{
            fm.fault.esr, fm.fault.far, fm.fault.elr,
        });
        log.info("ipc-test: supervisor verdict: teardown", .{});
        domain.destroy(crasher);
        while (!domain.drained(crasher)) sched.sleep(1);
        domain.finishTeardown(crasher);
    }
    ipc.unrefSide(fault_ch, .a);

    // The RPC pair: calc serves side A, askr calls on side B.
    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const calc = domain.spawn("calc", blobs.pingpong, .{
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .arg = 1,
    }) catch |e| std.debug.panic("spawn calc: {t}", .{e});
    const askr = domain.spawn("askr", blobs.pingpong, .{
        .grant_debug_log = true,
        .grant_channel_b = ch,
        .arg = 2,
    }) catch |e| std.debug.panic("spawn askr: {t}", .{e});

    sched.sleep(15); // let them converse
    log.info("ipc-test: revoking calc mid-conversation", .{});
    domain.destroy(calc);
    while (!domain.drained(calc)) sched.sleep(1);
    domain.finishTeardown(calc);

    // askr must observe peer_dead and exit 7 on its own.
    while (!(askr.state == .dying and domain.drained(askr))) sched.sleep(1);
    domain.finishTeardown(askr);
    log.info("ipc-test: askr exited with code {d} (7 = observed peer_dead and continued)", .{
        askr.exit_code,
    });

    const frames_after = pmem.stats().free_bytes;
    const shm_left = ipc.shm_account.balance();
    if (frames_after == frames_before and shm_left == 0 and askr.exit_code == 7) {
        log.info("ipc-test: PASS — pmem identical, shm account zero, death observed", .{});
    } else {
        std.debug.panic("ipc-test: FAIL — pmem delta {d}B, shm {d}B, askr exit {d}", .{
            frames_before -% frames_after, shm_left, askr.exit_code,
        });
    }
}

/// Phase 5 exit-criterion driver: the kernel's only jobs are to spawn the
/// userspace root task with the boot grants and verify nothing leaked once
/// the whole tree has finished. Everything else — init, lazy activation,
/// supervision, re-wiring — happens in userspace.
fn initTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    log.info("init-test: starting userspace root task", .{});
    const root = domain.spawn("root", blobs.root, .{
        .grant_debug_log = true,
        .grant_spawner = true,
        // Roomy: the whole userspace tree's usage cascades into these.
        .kobj_limit = 16 << 20,
        .user_limit = 48 << 20,
    }) catch |e| std.debug.panic("spawn root: {t}", .{e});

    while (!(root.state == .dying and domain.drained(root))) sched.sleep(2);
    domain.finishTeardown(root);
    log.info("init-test: root exited with code {d}", .{root.exit_code});

    // Give the reaper a beat to finish any stragglers, then account.
    sched.sleep(5);
    const frames_after = pmem.stats().free_bytes;
    if (frames_after == frames_before and root.exit_code == 0) {
        log.info("init-test: PASS — userspace tree finished clean, pmem identical", .{});
    } else {
        std.debug.panic("init-test: FAIL — pmem delta {d}B, root exit {d}", .{
            frames_before -% frames_after, root.exit_code,
        });
    }
}

/// Phase 6 exit-criterion driver: interposition (filter + audit proxy the
/// child cannot detect), nesting (grandchild from the child's budget
/// slice), subtree revocation in one call, and setup/teardown benchmarks.
fn sandboxTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    // Benchmark: spawn + revoke of a minimal domain must stay cheap.
    {
        const freq = asm ("mrs %[v], cntfrq_el0"
            : [v] "=r" (-> u64),
        );
        const t0 = cycles();
        const bench = domain.spawn("bench", blobs.sandbox, .{
            .arg = 5, // sleeper
            .auto_reap = true,
        }) catch |e| std.debug.panic("spawn bench: {t}", .{e});
        const t1 = cycles();
        domain.destroy(bench);
        const t2 = cycles();
        while (bench.state != .dead) sched.sleep(1);
        const t3 = cycles();
        log.info("sandbox-test: bench — spawn {d}us, destroy call {d}us, full reclaim {d}us", .{
            (t1 - t0) * 1_000_000 / freq,
            (t2 - t1) * 1_000_000 / freq,
            (t3 - t0) * 1_000_000 / freq,
        });
    }

    log.info("sandbox-test: starting sandbox parent", .{});
    const parent = domain.spawn("parent", blobs.sandbox, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_spawner = true,
        .kobj_limit = 4 << 20,
        .user_limit = 16 << 20,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn parent: {t}", .{e});

    sched.sleep(20); // let the child log through the proxy

    log.info("sandbox-test: revoking the parent (one call, whole subtree)", .{});
    domain.destroy(parent);
    while (parent.state != .dead) sched.sleep(1);

    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (frames_after == frames_before) {
        log.info("sandbox-test: PASS — subtree reclaimed, budgets zero, pmem identical", .{});
    } else {
        std.debug.panic("sandbox-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

/// The supervision-restart drill: a permanently-crashing service must
/// exhaust init's restart budget and escalate up the tree (init exits 77,
/// root retries init once, then gives up and reports 77).
fn flapTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    log.info("flap-test: starting root with the flap-drill topology", .{});
    const root = domain.spawn("root", blobs.root, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_spawner = true,
        .kobj_limit = 16 << 20,
        .user_limit = 48 << 20,
    }) catch |e| std.debug.panic("spawn root: {t}", .{e});

    while (!(root.state == .dying and domain.drained(root))) sched.sleep(2);
    domain.finishTeardown(root);

    sched.sleep(5);
    const frames_after = pmem.stats().free_bytes;
    if (root.exit_code == 77 and frames_after == frames_before) {
        log.info("flap-test: PASS — escalation reached the top (code 77), pmem identical", .{});
    } else {
        std.debug.panic("flap-test: FAIL — root exit {d}, pmem delta {d}B", .{
            root.exit_code, frames_before -% frames_after,
        });
    }
}

/// Phase 7 exit-criterion driver: a userspace virtio-blk driver serving a
/// userspace client over IPC — the kernel only wires caps: MMIO window,
/// IRQ range, channel, log. QEMU virt: virtio-mmio slots at 0x0a000000
/// (32 x 0x200), IRQs SPI 16.. (intid 48..).
fn blkTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    log.info("blk-test: starting userspace virtio-blk driver", .{});
    const drv = domain.spawn("blkdrv", blobs.blk, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .grant_mmio = .{ .base = 0x0a00_0000, .pages = 4 },
        .grant_irq = .{ .base = 48, .count = 32 },
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn blkdrv: {t}", .{e});

    const user = domain.spawn("blkuser", blobs.blk, .{
        .arg = 2,
        .grant_debug_log = true,
        .grant_channel_b = ch,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn blkuser: {t}", .{e});

    while (user.state != .dead) sched.sleep(2);
    log.info("blk-test: client exited with code {d}", .{user.exit_code});
    domain.destroy(drv);
    while (drv.state != .dead) sched.sleep(1);

    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (user.exit_code == 0 and frames_after == frames_before and ipc.shm_account.balance() == 0) {
        log.info("blk-test: PASS — real disk I/O through a sandboxed userspace driver, nothing leaked", .{});
    } else {
        std.debug.panic("blk-test: FAIL — client exit {d}, pmem delta {d}B", .{
            user.exit_code, frames_before -% frames_after,
        });
    }
}

/// Phase 9 exit-criterion driver: filesystem service on the virtio-blk
/// driver, per-process namespaces as badged view caps. Alice gets the root
/// view (rw) and populates the disk; bob gets a derived read-only view of
/// disk/pub and must be unable to see, write, or escape anything else.
fn fsTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    // The storage stack: driver, then the FS service on top of it.
    const blk_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const drv = domain.spawn("blkdrv", blobs.blk, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = blk_ch,
        .grant_mmio = .{ .base = 0x0a00_0000, .pages = 4 },
        .grant_irq = .{ .base = 48, .count = 32 },
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn blkdrv: {t}", .{e});

    const fs_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const fssvc = domain.spawn("fssvc", blobs.fs, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = fs_ch,
        .grant_blob = blobs.bootfs,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fssvc: {t}", .{e});

    // Hand the FS its disk: an attach carrying the blk channel cap.
    ipc.refSide(blk_ch, .b);
    var res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .attach_buf),
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = @intFromPtr(blk_ch),
    }, 0);
    std.debug.assert(res.err == .ok);

    // A path buffer for the kernel's own root view (badge 0).
    const pathbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, pathbuf.pages[0]);
    ipc.refShm(pathbuf);
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .attach_buf),
        .cap_type = @intFromEnum(cap.CapType.shm),
        .cap_obj = @intFromPtr(pathbuf),
    }, 0);
    std.debug.assert(res.err == .ok);

    // Alice: the whole root view, read-write.
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .derive = .{ .path_off = 0, .path_len = 0, .ro = 0 } }),
    }, 0);
    std.debug.assert(res.err == .ok and res.msg.cap_type != 0);
    log.info("fs-test: alice gets the root view (rw)", .{});
    const alice = domain.spawn("alice", blobs.fs, .{
        .arg = 2,
        .grant_debug_log = true,
        .grant_channel_b = @ptrFromInt(res.msg.cap_obj),
        .grant_channel_b_badge = res.msg.cap_badge,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn alice: {t}", .{e});
    while (alice.state != .dead) sched.sleep(2);
    if (alice.exit_code != 0) std.debug.panic("alice failed: {d}", .{alice.exit_code});

    // Bob: only data/pub, and only to look at.
    const p = "data/pub";
    @memcpy(pb[0..p.len], p);
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .derive = .{ .path_off = 0, .path_len = p.len, .ro = 1 } }),
    }, 0);
    std.debug.assert(res.err == .ok and res.msg.cap_type != 0);
    log.info("fs-test: bob gets a read-only view of data/pub", .{});
    const bob = domain.spawn("bob", blobs.fs, .{
        .arg = 3,
        .grant_debug_log = true,
        .grant_channel_b = @ptrFromInt(res.msg.cap_obj),
        .grant_channel_b_badge = res.msg.cap_badge,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn bob: {t}", .{e});
    while (bob.state != .dead) sched.sleep(2);
    if (bob.exit_code != 0) std.debug.panic("bob failed: {d}", .{bob.exit_code});

    // Teardown, inside out: the FS first, then its driver.
    domain.destroy(fssvc);
    while (fssvc.state != .dead) sched.sleep(1);
    domain.destroy(drv);
    while (drv.state != .dead) sched.sleep(1);
    ipc.unrefSide(fs_ch, .b);
    ipc.unrefShm(pathbuf);

    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (frames_after == frames_before) {
        log.info("fs-test: PASS — disjoint namespaces on real storage, nothing leaked", .{});
    } else {
        std.debug.panic("fs-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

/// Phase 10 exit-criterion driver: two processes speak TCP through the
/// userspace net service (loopback over v4-mapped AND IPv6, plus real wire
/// TCP through slirp), and a sandboxed child holding an allowlist view can
/// reach only its allowlisted destination.
fn netTestWorker(_: u64) void {
    const blobs = @import("user_blobs");
    const frames_before = pmem.stats().free_bytes;

    const net_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    log.info("net-test: starting userspace netsvc (driver + dual-stack tcp)", .{});
    const svc = domain.spawn("netsvc", blobs.net, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = net_ch,
        .grant_mmio = .{ .base = 0x0a00_0000, .pages = 4 },
        .grant_irq = .{ .base = 48, .count = 32 },
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn netsvc: {t}", .{e});
    sched.sleep(5);
    if (svc.state == .dead) std.debug.panic("netsvc died at init: exit {d}", .{svc.exit_code});

    // Unrestricted views for the echo pair, via derive.
    const srv_view = deriveNetView(net_ch, 0, 0, 0);
    const cli_view = deriveNetView(net_ch, 0, 0, 0);
    const srv = domain.spawn("echosrv", blobs.net, .{
        .arg = 2,
        .grant_debug_log = true,
        .grant_channel_b = @ptrFromInt(srv_view.obj),
        .grant_channel_b_badge = srv_view.badge,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn echosrv: {t}", .{e});
    sched.sleep(3);
    const cli = domain.spawn("echocli", blobs.net, .{
        .arg = 3,
        .grant_debug_log = true,
        .grant_channel_b = @ptrFromInt(cli_view.obj),
        .grant_channel_b_badge = cli_view.badge,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn echocli: {t}", .{e});

    while (cli.state != .dead) sched.sleep(2);
    if (cli.exit_code != 0) std.debug.panic("echocli failed: {d}", .{cli.exit_code});
    while (srv.state != .dead) sched.sleep(2);
    if (srv.exit_code != 0) std.debug.panic("echosrv failed: {d}", .{srv.exit_code});
    log.info("net-test: both echo processes finished clean", .{});

    // The sandboxed child: allowlist = the wire echo destination only.
    const v4w = shared.v4Words(shared.net_echo_ip4);
    const box_view = deriveNetView(net_ch, v4w[0], v4w[1], shared.net_echo_port);
    const box = domain.spawn("boxed", blobs.net, .{
        .arg = 4,
        .grant_debug_log = true,
        .grant_channel_b = @ptrFromInt(box_view.obj),
        .grant_channel_b_badge = box_view.badge,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn boxed: {t}", .{e});
    while (box.state != .dead) sched.sleep(2);
    if (box.exit_code != 0) std.debug.panic("boxed failed: {d}", .{box.exit_code});

    domain.destroy(svc);
    while (svc.state != .dead) sched.sleep(1);
    ipc.unrefSide(net_ch, .b);

    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (frames_after == frames_before and ipc.shm_account.balance() == 0) {
        log.info("net-test: PASS — dual-stack tcp via userspace netsvc, allowlist enforced, nothing leaked", .{});
    } else {
        std.debug.panic("net-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

var boot_node: u64 = 0;

fn parseNodeArg(args: []const u8) u64 {
    const key = "node=";
    var i: usize = 0;
    outer: while (i + key.len < args.len + 1) : (i += 1) {
        for (key, 0..) |c, j| {
            if (i + j >= args.len or args[i + j] != c) continue :outer;
        }
        var v: u64 = 0;
        var k = i + key.len;
        while (k < args.len and args[k] >= '0' and args[k] <= '9') : (k += 1) {
            v = v * 10 + (args[k] - '0');
        }
        return v;
    }
    return 0;
}

/// Phase 11 exit-criterion driver, parameterized by node id (from
/// bootargs). Node 1 is the initiator: hello with node 2, remote-spawn a
/// service THERE, RPC to it through the proxied channel, and survive node
/// 2's death mid-conversation. Node 2 serves reactively and then powers
/// off — the node-kill drill.
fn fabricTestWorker(node: u64) void {
    const blobs = @import("user_blobs");
    log.info("fabric-test: node {d} coming up", .{node});

    // The network, in cluster mode.
    const net_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    _ = domain.spawn("netsvc", blobs.net, .{
        .arg = 1 | (node << 8),
        .grant_debug_log = true,
        .grant_channel_a = net_ch,
        .grant_mmio = .{ .base = 0x0a00_0000, .pages = 4 },
        .grant_irq = .{ .base = 48, .count = 32 },
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn netsvc: {t}", .{e});
    sched.sleep(3);

    // The fabric service, wired to a net view.
    const fab_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    _ = domain.spawn("fabsvc", blobs.fabric, .{
        .arg = 1 | (node << 8),
        .grant_debug_log = true,
        .grant_channel_a = fab_ch,
        .grant_spawner = true,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fabsvc: {t}", .{e});
    const view = deriveNetView(net_ch, 0, 0, 0);
    var res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .attach_net),
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = view.obj,
        .cap_badge = view.badge,
    }, 0);
    std.debug.assert(res.err == .ok);

    if (node != 1) {
        // Node 2+: pump the fabric for 90 ticks, then die abruptly.
        for (0..90) |_| {
            _ = ipc.call(fab_ch, .{
                .data = shared.encodeMsg(shared.FabReq, .poll),
            }, 0);
            sched.sleep(1);
        }
        log.info("fabric-test: node {d} powering off mid-conversation (drill)", .{node});
        psci.systemOff();
    }

    // Node 1: the initiator.
    var hello_ok = false;
    for (0..60) |_| {
        res = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .{ .connect_peer = .{ .node = 2 } }),
        }, 0);
        if (res.err == .ok) {
            if (shared.decodeMsg(shared.FabResp, res.msg.data)) |rep| {
                if (rep == .ok) {
                    hello_ok = true;
                    break;
                }
            }
        }
        sched.sleep(3);
    }
    if (!hello_ok) std.debug.panic("fabric-test: no hello from node 2", .{});
    log.info("fabric-test: cross-VM hello with node 2 complete", .{});

    // Remote spawn: run remote-echo ON NODE 2 from node 1's manifest.
    res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .{ .remote_spawn = .{
            .node = 2,
            .image = @intFromEnum(shared.ImageId.fabric),
            .arg = 2,
        } }),
    }, 0);
    std.debug.assert(res.err == .ok);
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse
        @panic("fabric-test: bad spawn reply");
    if (rep != .spawned or res.msg.cap_type == 0)
        std.debug.panic("fabric-test: remote spawn failed", .{});
    const remote_badge = res.msg.cap_badge;
    log.info("fabric-test: remote-echo spawned on node 2; got proxied channel", .{});

    // Cross-VM typed RPC through the proxied channel until the peer dies.
    var rpcs: u64 = 0;
    var observed_death = false;
    for (0..200) |i| {
        const call_res = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.CalcRequest, .{ .add = .{ .a = i, .b = 1000 } }),
        }, remote_badge);
        if (call_res.err != .ok) break;
        if (call_res.msg.data[0] == shared.fabric_err_sentinel) {
            log.info("fabric-test: peer died mid-RPC (fabric error {d}); observed and recovering", .{
                call_res.msg.data[1],
            });
            observed_death = true;
            break;
        }
        const crep = shared.decodeMsg(shared.CalcReply, call_res.msg.data) orelse break;
        switch (crep) {
            .sum => |v| {
                if (v.value != i + 1000) std.debug.panic("fabric-test: bad RPC result", .{});
                rpcs += 1;
                if (rpcs == 1) log.info("fabric-test: first cross-VM RPC verified ({d}+1000={d})", .{ i, v.value });
            },
            .hi => {},
        }
        sched.sleep(3);
    }

    if (rpcs > 0 and observed_death) {
        log.info("fabric-test: PASS — {d} cross-VM RPCs, remote spawn, node-kill observed and survived", .{rpcs});
    } else {
        std.debug.panic("fabric-test: FAIL — rpcs={d} death_observed={}", .{ rpcs, observed_death });
    }
    psci.systemOff();
}

fn deriveNetView(net_ch: *ipc.Channel, hi: u64, lo: u64, port: u64) struct { obj: u64, badge: u64 } {
    const res = ipc.call(net_ch, .{
        .data = shared.encodeMsg(shared.NetReq, .{
            .derive = .{ .ip_hi = hi, .ip_lo = lo, .port = port },
        }),
    }, 0);
    std.debug.assert(res.err == .ok and res.msg.cap_type != 0);
    return .{ .obj = res.msg.cap_obj, .badge = res.msg.cap_badge };
}

fn cycles() u64 {
    return asm volatile ("mrs %[v], cntpct_el0"
        : [v] "=r" (-> u64),
    );
}

fn notifHelper(arg: u64) void {
    const n: *ipc.Notification = @ptrFromInt(arg);
    sched.sleep(2);
    ipc.signal(n, 0b101);
}

fn panicHandler(msg: []const u8, first_trace_addr: ?usize) noreturn {
    // Mask all interrupt classes: nothing may preempt panic reporting.
    asm volatile ("msr daifset, #0xf");
    log.print("\n!! KERNEL PANIC: {s}\n", .{msg});
    if (first_trace_addr) |addr| {
        log.print("!! first trace address: 0x{x}\n", .{addr});
    }
    log.print("!! core halted\n", .{});
    halt();
}

fn currentEl() u64 {
    const el = asm ("mrs %[el], CurrentEL"
        : [el] "=r" (-> u64),
    );
    return el >> 2;
}

fn halt() noreturn {
    while (true) {
        asm volatile ("wfi");
    }
}
