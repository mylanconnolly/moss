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
const rng = @import("rng.zig");
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
    // The device capabilities come from the tree, not from constants: the
    // virtio-mmio window and its SPI range are what root (and, for now,
    // the boot drivers) hand to userspace drivers.
    if (fdt.virtioWindow()) |vw| {
        devices = vw;
        log.info("devicetree: virtio-mmio window 0x{x} + {d} pages, intids {d}..{d}", .{
            vw.mmio_base, vw.mmio_pages, vw.irq_base, vw.irq_base + vw.irq_count - 1,
        });
    } else {
        log.warn("devicetree: no virtio-mmio transports; userspace drivers will find no devices", .{});
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
    const blobs = @import("user_blobs");
    // The kernel embeds exactly one thing: the boot archive. Every program
    // image lives inside it at img/<name>; the boot drivers below read it
    // the same way userspace spawners do.
    domain.init();
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

    if (build_options.shell_test) {
        _ = sched.spawn("boot-watch", shellTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.net_test) {
        _ = sched.spawn("boot-watch", netTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.rng_test) {
        _ = sched.spawn("boot-watch", rngTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.fabric_test) {
        _ = sched.spawn("boot-watch", fabricTestWorker, boot_node | (boot_drill << 8) | (boot_badkey << 16), .{}) catch |e| {
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
    const frames_before = pmem.stats().free_bytes;

    log.info("domain-test: spawning 'hello' (debug_log granted)", .{});
    const hello = domain.spawn("hello", .{ .blob = img(.hello) }, .{
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
    const sneaky = domain.spawn("sneaky", .{ .blob = img(.hello) }, .{}) catch |e|
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
        psci.systemOff();
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
    const crasher = domain.spawn("crasher", .{ .blob = img(.pingpong) }, .{
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
    const calc = domain.spawn("calc", .{ .blob = img(.pingpong) }, .{
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .arg = 1,
    }) catch |e| std.debug.panic("spawn calc: {t}", .{e});
    const askr = domain.spawn("askr", .{ .blob = img(.pingpong) }, .{
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
        psci.systemOff();
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
    const frames_before = pmem.stats().free_bytes;

    log.info("init-test: starting userspace root task", .{});
    const root = domain.spawn("root", .{ .blob = img(.root) }, .{
        .grant_debug_log = true,
        .grant_spawner = true,
        .grant_bootfs = true,
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
        psci.systemOff();
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
    const frames_before = pmem.stats().free_bytes;

    // Benchmark: spawn + revoke of a minimal domain must stay cheap.
    {
        const freq = asm ("mrs %[v], cntfrq_el0"
            : [v] "=r" (-> u64),
        );
        const t0 = cycles();
        const bench = domain.spawn("bench", .{ .blob = img(.sandbox) }, .{
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
    const parent = domain.spawn("parent", .{ .blob = img(.sandbox) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_spawner = true,
        .grant_bootfs = true,
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
        psci.systemOff();
    } else {
        std.debug.panic("sandbox-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

/// The supervision-restart drill: a permanently-crashing service must
/// exhaust init's restart budget and escalate up the tree (init exits 77,
/// root retries init once, then gives up and reports 77).
fn flapTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;

    log.info("flap-test: starting root with the flap-drill topology", .{});
    const root = domain.spawn("root", .{ .blob = img(.root) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_spawner = true,
        .grant_bootfs = true,
        .kobj_limit = 16 << 20,
        .user_limit = 48 << 20,
    }) catch |e| std.debug.panic("spawn root: {t}", .{e});

    while (!(root.state == .dying and domain.drained(root))) sched.sleep(2);
    domain.finishTeardown(root);

    sched.sleep(5);
    const frames_after = pmem.stats().free_bytes;
    if (root.exit_code == 77 and frames_after == frames_before) {
        log.info("flap-test: PASS — escalation reached the top (code 77), pmem identical", .{});
        psci.systemOff();
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
    const frames_before = pmem.stats().free_bytes;

    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    log.info("blk-test: starting userspace virtio-blk driver", .{});
    const drv = domain.spawn("blkdrv", .{ .blob = img(.blk) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn blkdrv: {t}", .{e});

    const user = domain.spawn("blkuser", .{ .blob = img(.blk) }, .{
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
        psci.systemOff();
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
    const frames_before = pmem.stats().free_bytes;

    // The storage stack: driver, then the FS service on top of it.
    const blk_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const drv = domain.spawn("blkdrv", .{ .blob = img(.blk) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = blk_ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn blkdrv: {t}", .{e});

    const fs_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const fssvc = domain.spawn("fssvc", .{ .blob = img(.fs) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = fs_ch,
        .grant_bootfs = true,
        .user_limit = 4 << 20, // mossfs core: caches + overlay live in BSS
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fssvc: {t}", .{e});

    // A path buffer for the kernel's own root view (badge 0).
    const pathbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, pathbuf.pages[0]);
    ipc.refShm(pathbuf);
    var res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .attach_buf),
        .cap_type = @intFromEnum(cap.CapType.shm),
        .cap_obj = @intFromPtr(pathbuf),
    }, 0);
    std.debug.assert(res.err == .ok);

    // Stage the volume key (badge-0 handshake): the test volume is
    // encrypted + compressed, exercising the full v3 path.
    const test_key = "moss-fs-test-key-0123456789abcde";
    comptime std.debug.assert(test_key.len == 32);
    @memcpy(pb[0..32], test_key);
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .set_key = .{ .off = 0, .len = 32 } }),
    }, 0);
    std.debug.assert(res.err == .ok);

    // Hand the FS its disk: an attach_disk carrying the blk channel cap.
    ipc.refSide(blk_ch, .b);
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .attach_disk),
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = @intFromPtr(blk_ch),
    }, 0);
    std.debug.assert(res.err == .ok);

    // Alice: the whole root view, read-write.
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .derive = .{ .path_off = 0, .path_len = 0, .ro = 0 } }),
    }, 0);
    std.debug.assert(res.err == .ok and res.msg.cap_type != 0);
    log.info("fs-test: alice gets the root view (rw)", .{});
    const alice = domain.spawn("alice", .{ .blob = img(.fs) }, .{
        .arg = 2,
        .grant_debug_log = true,
        .user_limit = 4 << 20, // the fs image carries the mossfs BSS for every role
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
    const bob = domain.spawn("bob", .{ .blob = img(.fs) }, .{
        .arg = 3,
        .grant_debug_log = true,
        .user_limit = 4 << 20, // the fs image carries the mossfs BSS for every role
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
        psci.systemOff();
    } else {
        std.debug.panic("fs-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

/// Developer-tooling boot: the storage stack, the virtio-console driver,
/// init (serving its front channel), and msh — the interactive shell —
/// wired together by capability grants. Used by both `zig build
/// run-shell` (a human on the console) and the scripted shell check
/// (the runner drives the console over a socket chardev). PASS when msh
/// exits cleanly and nothing leaked.
fn shellTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;

    // Storage: driver, then the FS service (encrypted volume, fs-test key).
    const blk_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const blkdrv = domain.spawn("blkdrv", .{ .blob = img(.blk) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = blk_ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn blkdrv: {t}", .{e});

    const fs_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const fssvc = domain.spawn("fssvc", .{ .blob = img(.fs) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = fs_ch,
        .grant_bootfs = true,
        .user_limit = 4 << 20,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fssvc: {t}", .{e});

    // Entropy first: the fabric refuses the network until the pool is live.
    const rngd = spawnRngd(0);

    // The network + a single-node fabric (msh's nodes/rspawn commands).
    const shellnet_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const shellnet = domain.spawn("netsvc", .{ .blob = img(.net) }, .{
        .arg = 1 | (1 << 8), // cluster addressing, node 1
        .grant_debug_log = true,
        .grant_channel_a = shellnet_ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn netsvc: {t}", .{e});
    const shellfab_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const shellfab = domain.spawn("fabsvc", .{ .blob = img(.fabric) }, .{
        .arg = 1 | (1 << 8),
        .grant_debug_log = true,
        .grant_channel_a = shellfab_ch,
        .grant_spawner = true,
        .grant_bootfs = true, // remote spawns load their images from it
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fabsvc: {t}", .{e});

    // Console driver (virtio-console, device id 3).
    const cons_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const consdrv = domain.spawn("consdrv", .{ .blob = img(.cons) }, .{
        .grant_debug_log = true,
        .grant_channel_a = cons_ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn consdrv: {t}", .{e});

    // FS handshake: badge-0 buffer, key, disk (same flow as fs-test).
    const pathbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, pathbuf.pages[0]);
    ipc.refShm(pathbuf);
    var res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .attach_buf),
        .cap_type = @intFromEnum(cap.CapType.shm),
        .cap_obj = @intFromPtr(pathbuf),
    }, 0);
    std.debug.assert(res.err == .ok);
    const shell_key = "moss-fs-test-key-0123456789abcde";
    @memcpy(pb[0..32], shell_key);
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .set_key = .{ .off = 0, .len = 32 } }),
    }, 0);
    std.debug.assert(res.err == .ok);
    ipc.refSide(blk_ch, .b);
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .attach_disk),
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = @intFromPtr(blk_ch),
    }, 0);
    std.debug.assert(res.err == .ok);

    // Wire the fabric to a net view (identity first: fail-closed). The
    // fabric gets its OWN staging buffer: an shm cap delivered to a service
    // is unref'd by that service's teardown, so one buffer must never be
    // handed to two services against a single ref.
    const fabbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const fb = mem.physToPtr([*]u8, fabbuf.pages[0]);
    ipc.refShm(fabbuf);
    const root = spawnFabroot(false);
    {
        var r2 = ipc.call(shellfab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .attach_buf),
            .cap_type = @intFromEnum(cap.CapType.shm),
            .cap_obj = @intFromPtr(fabbuf),
        }, 0);
        std.debug.assert(r2.err == .ok);
        certifyFabric(root, shellfab_ch, fb, 1, shared.fab_flag_gossip | shared.fab_flag_spawn, ~@as(u64, 0));
        const nview = deriveNetView(shellnet_ch, 0, 0, 0);
        r2 = ipc.call(shellfab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .attach_net),
            .cap_type = @intFromEnum(cap.CapType.channel_b),
            .cap_obj = nview.obj,
            .cap_badge = nview.badge,
        }, 0);
        std.debug.assert(r2.err == .ok);
    }

    // The shell's filesystem view: the whole root, read-write.
    res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .derive = .{ .path_off = 0, .path_len = 0, .ro = 0 } }),
    }, 0);
    std.debug.assert(res.err == .ok and res.msg.cap_type != 0);
    const view_obj = res.msg.cap_obj;
    const view_badge = res.msg.cap_badge;

    // init, serving a granted front channel (no demo worker).
    const front_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const initd = domain.spawn("init", .{ .blob = img(.init) }, .{
        .grant_debug_log = true,
        .grant_spawner = true,
        .grant_channel_a = front_ch,
        .grant_bootfs = true,
        .kobj_limit = 4 << 20,
        .user_limit = 24 << 20, // its services' budgets nest inside
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn init: {t}", .{e});

    // The image store: init installs the archive's programs into img/
    // (content-addressed) so msh's `run` loads programs as files. A
    // volume that cannot take the store is reported, not fatal: msh still
    // boots, and `run` reports the missing index.
    installImageStore(fs_ch, pb, front_ch);

    // msh: serves its boot channel; we feed it cons, fs view, init front.
    const boot_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const msh = domain.spawn("msh", .{ .blob = img(.shell) }, .{
        .grant_debug_log = true,
        .grant_spawner = true, // gates ps/mem introspection and `run`
        .grant_channel_a = boot_ch,
        .user_limit = 8 << 20, // the interpreter's arenas live in its BSS
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn msh: {t}", .{e});

    ipc.refSide(cons_ch, .b);
    res = ipc.call(boot_ch, .{
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = @intFromPtr(cons_ch),
    }, 0);
    std.debug.assert(res.err == .ok);
    res = ipc.call(boot_ch, .{
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = view_obj,
        .cap_badge = view_badge,
    }, 0);
    std.debug.assert(res.err == .ok);
    ipc.refSide(front_ch, .b);
    res = ipc.call(boot_ch, .{
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = @intFromPtr(front_ch),
    }, 0);
    std.debug.assert(res.err == .ok);
    ipc.refSide(shellfab_ch, .b);
    res = ipc.call(boot_ch, .{
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = @intFromPtr(shellfab_ch),
    }, 0);
    std.debug.assert(res.err == .ok);
    log.info("shell: system up — msh on the console", .{});

    // The human (or the runner's script) drives; we keep the single-node
    // fabric breathing while we wait for msh to exit.
    while (msh.state != .dead) {
        _ = ipc.call(shellfab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .poll),
        }, 0);
        sched.sleep(2);
    }
    const msh_code = msh.exit_code;

    // Teardown, inside out: init exits on front-channel death, then the
    // drivers and the FS.
    ipc.unrefSide(front_ch, .b);
    while (initd.state != .dead) sched.sleep(1);
    domain.destroy(shellfab);
    while (shellfab.state != .dead) sched.sleep(1);
    domain.destroy(shellnet);
    while (shellnet.state != .dead) sched.sleep(1);
    domain.destroy(root.d);
    while (root.d.state != .dead) sched.sleep(1);
    ipc.unrefSide(root.ch, .b);
    ipc.unrefShm(root.buf);
    ipc.unrefSide(shellnet_ch, .b);
    ipc.unrefSide(shellfab_ch, .b);
    ipc.unrefShm(fabbuf);
    domain.destroy(consdrv);
    while (consdrv.state != .dead) sched.sleep(1);
    domain.destroy(fssvc);
    while (fssvc.state != .dead) sched.sleep(1);
    domain.destroy(blkdrv);
    while (blkdrv.state != .dead) sched.sleep(1);
    domain.destroy(rngd);
    while (rngd.state != .dead) sched.sleep(1);
    ipc.unrefSide(fs_ch, .b);
    ipc.unrefSide(boot_ch, .b);
    ipc.unrefShm(pathbuf);

    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (msh_code == 0 and frames_after == frames_before and ipc.shm_account.balance() == 0) {
        log.info("shell-test: PASS — an interactive capability shell, nothing leaked", .{});
        psci.systemOff();
    } else {
        std.debug.panic("shell-test: FAIL — msh exit {d}, pmem delta {d}B", .{
            msh_code, frames_before -% frames_after,
        });
    }
}

/// Phase 10 exit-criterion driver: two processes speak TCP through the
/// userspace net service (loopback over v4-mapped AND IPv6, plus real wire
/// TCP through slirp), and a sandboxed child holding an allowlist view can
/// reach only its allowlisted destination.
fn netTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;

    const net_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    log.info("net-test: starting userspace netsvc (driver + dual-stack tcp)", .{});
    const svc = domain.spawn("netsvc", .{ .blob = img(.net) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = net_ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn netsvc: {t}", .{e});
    sched.sleep(5);
    if (svc.state == .dead) std.debug.panic("netsvc died at init: exit {d}", .{svc.exit_code});

    // Unrestricted views for the echo pair, via derive.
    const srv_view = deriveNetView(net_ch, 0, 0, 0);
    const cli_view = deriveNetView(net_ch, 0, 0, 0);
    const srv = domain.spawn("echosrv", .{ .blob = img(.net) }, .{
        .arg = 2,
        .grant_debug_log = true,
        .grant_channel_b = @ptrFromInt(srv_view.obj),
        .grant_channel_b_badge = srv_view.badge,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn echosrv: {t}", .{e});
    sched.sleep(3);
    const cli = domain.spawn("echocli", .{ .blob = img(.net) }, .{
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
    const box = domain.spawn("boxed", .{ .blob = img(.net) }, .{
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
        psci.systemOff();
    } else {
        std.debug.panic("net-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

/// The entropy driver: virtio-rng behind the standard driver grants plus
/// the entropy cap — the one holder of the right to seed the kernel
/// pool. Blocks until the boot seed has landed (getrandom is fail-closed
/// until then, and the services spawned next depend on it).
/// `reseed_ticks` = 0 takes the driver's default.
fn spawnRngd(reseed_ticks: u64) *domain.Domain {
    // The driver is handed its device over its boot channel — the same
    // protocol init will speak once orchestration moves to userspace.
    const boot_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const d = domain.spawn("rngd", .{ .blob = img(.rng) }, .{
        .arg = 1 | (reseed_ticks << 8),
        .grant_debug_log = true,
        .grant_channel_a = boot_ch,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn rngd: {t}", .{e});
    giveCap(boot_ch, .mmio, .mmio, mmioCapObj());
    giveCap(boot_ch, .irq, .irq, irqCapObj());
    giveCap(boot_ch, .entropy, .entropy, 0);
    const go = ipc.call(boot_ch, .{ .data = shared.encodeMsg(shared.BootReq, .go) }, 0);
    std.debug.assert(go.err == .ok);
    ipc.unrefSide(boot_ch, .b);
    var waited: u64 = 0;
    while (!rng.isSeeded()) : (waited += 1) {
        if (d.state == .dead) std.debug.panic("rngd died before seeding: exit {d}", .{d.exit_code});
        if (waited == 100) std.debug.panic("rngd never seeded the pool", .{});
        sched.sleep(1);
    }
    return d;
}

/// Hand a program one capability over its boot channel (BootReq.cap).
fn giveCap(boot_ch: *ipc.Channel, tag: shared.CapTag, ct: cap.CapType, obj: u64) void {
    const res = ipc.call(boot_ch, .{
        .data = shared.encodeMsg(shared.BootReq, .{ .cap = .{ .tag = @intFromEnum(tag) } }),
        .cap_type = @intFromEnum(ct),
        .cap_obj = obj,
    }, 0);
    std.debug.assert(res.err == .ok);
}

/// The entropy drill: (1) the pool is fail-closed — a probe spawned
/// before any driver exists gets bad_state; (2) the userspace virtio-rng
/// driver seeds it through the entropy cap; (3) a probe verifies
/// getrandom end to end (fresh bytes per call, every bad argument
/// refused, seeding without the cap refused); (4) the driver's own
/// reseed clock delivers more entropy; (5) the kernel itself can draw;
/// then the usual teardown bar: pmem byte-identical.
fn rngTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;

    log.info("rng-test: probing the pool before any entropy driver exists", .{});
    const early = domain.spawn("rngprobe", .{ .blob = img(.rng) }, .{
        .arg = 3,
        .grant_debug_log = true,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn rngprobe: {t}", .{e});
    while (early.state != .dead) sched.sleep(1);
    if (early.exit_code != 0) std.debug.panic("rng-test: FAIL — early probe exit {d}", .{early.exit_code});

    log.info("rng-test: starting userspace virtio-rng driver (reseed every 5 ticks)", .{});
    const rngd = spawnRngd(5);
    const seeds0 = rng.seedCount();
    log.info("rng-test: pool seeded by rngd ({d} seed so far)", .{seeds0});

    const probe = domain.spawn("rngprobe", .{ .blob = img(.rng) }, .{
        .arg = 2,
        .grant_debug_log = true,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn rngprobe: {t}", .{e});
    while (probe.state != .dead) sched.sleep(1);
    if (probe.exit_code != 0) std.debug.panic("rng-test: FAIL — probe exit {d}", .{probe.exit_code});

    // The driver keeps feeding the pool on its own clock.
    var waited: u64 = 0;
    while (rng.seedCount() < seeds0 + 2) : (waited += 1) {
        if (waited == 200) std.debug.panic("rng-test: FAIL — no reseeds arrived", .{});
        sched.sleep(1);
    }
    log.info("rng-test: reseeds landing ({d} seeds total)", .{rng.seedCount()});

    // Kernel-side draw: two blocks, distinct.
    var ka: [32]u8 = undefined;
    var kb: [32]u8 = undefined;
    rng.fill(&ka) catch @panic("kernel draw refused");
    rng.fill(&kb) catch @panic("kernel draw refused");
    if (std.mem.eql(u8, &ka, &kb)) std.debug.panic("rng-test: FAIL — kernel draws identical", .{});

    domain.destroy(rngd);
    while (rngd.state != .dead) sched.sleep(1);

    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (frames_after == frames_before) {
        log.info("rng-test: PASS — hardware entropy through a sandboxed driver, getrandom fail-closed and policed, nothing leaked", .{});
        psci.systemOff();
    } else {
        std.debug.panic("rng-test: FAIL — {d}B unaccounted", .{frames_before -% frames_after});
    }
}

var boot_node: u64 = 0;
var boot_drill: u64 = 0;
var boot_badkey: u64 = 0;

/// The virtio-mmio device window from the devicetree (zero if none).
var devices: dt.VirtioWindow = .{ .mmio_base = 0, .mmio_pages = 0, .irq_base = 0, .irq_count = 0 };

fn devMmio() ?domain.MmioGrant {
    if (devices.mmio_pages == 0) return null;
    return .{ .base = devices.mmio_base, .pages = devices.mmio_pages };
}

fn devIrq() ?domain.IrqGrant {
    if (devices.irq_count == 0) return null;
    return .{ .base = devices.irq_base, .count = devices.irq_count };
}

/// The device capability object words (the same encoding the cap table
/// holds), for handing devices to a program over its boot channel.
fn mmioCapObj() u64 {
    return devices.mmio_base | (devices.mmio_pages << 48);
}

fn irqCapObj() u64 {
    return @as(u64, devices.irq_base) | (@as(u64, devices.irq_count) << 32);
}

fn parseArgNum(args: []const u8, comptime key: []const u8) u64 {
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

fn parseNodeArg(args: []const u8) u64 {
    boot_drill = parseArgNum(args, "drill=");
    boot_badkey = parseArgNum(args, "badkey=");
    return parseArgNum(args, "node=");
}

/// The dynamic-membership drill, parameterized by node id + drill flag
/// (bootargs "node=N drill=D"). Node 1 is the seed and verifier; nodes 2
/// and 3 join it and the membership gossips them together. Node 2 (with
/// drill=1) powers off mid-life; the runner relaunches it with drill=0
/// and node 1 must see the death AND the rejoin purely through the
/// fabric's own liveness — then place a spawn by load and spawn on the
/// rejoined node. Staged markers narrate for the runner.
fn fabricTestWorker(arg: u64) void {
    const node = arg & 0xff;
    const drill = (arg >> 8) & 0xff;
    const badkey = (arg >> 16) & 0xff;
    log.info("fabric-test: node {d} coming up (drill={d})", .{ node, drill });

    // Entropy: handshake nonces come from getrandom; no pool, no fabric.
    _ = spawnRngd(0);

    // The network, in cluster mode.
    const net_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    _ = domain.spawn("netsvc", .{ .blob = img(.net) }, .{
        .arg = 1 | (node << 8),
        .grant_debug_log = true,
        .grant_channel_a = net_ch,
        .grant_mmio = devMmio(),
        .grant_irq = devIrq(),
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn netsvc: {t}", .{e});
    sched.sleep(3);

    // The fabric service, wired to a net view.
    const fab_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    _ = domain.spawn("fabsvc", .{ .blob = img(.fabric) }, .{
        .arg = 1 | (node << 8),
        .grant_debug_log = true,
        .grant_channel_a = fab_ch,
        .grant_spawner = true,
        .grant_bootfs = true, // remote spawns load their images from it
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fabsvc: {t}", .{e});
    // Identity: the root of trust certifies this node, then the net is
    // handed over. The imposter's root is a DIFFERENT key, so its
    // certificate must be refused by every real member. Node 3's
    // certificate carries no spawn authority (the authorization drill).
    const root = spawnFabroot(badkey != 0);
    const pathbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, pathbuf.pages[0]);
    ipc.refShm(pathbuf);
    var res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .attach_buf),
        .cap_type = @intFromEnum(cap.CapType.shm),
        .cap_obj = @intFromPtr(pathbuf),
    }, 0);
    std.debug.assert(res.err == .ok);
    const flags: u64 = if (node == 3) shared.fab_flag_gossip else shared.fab_flag_gossip | shared.fab_flag_spawn;
    certifyFabric(root, fab_ch, pb, node, flags, ~@as(u64, 0));

    const view = deriveNetView(net_ch, 0, 0, 0);
    res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .attach_net),
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = view.obj,
        .cap_badge = view.badge,
    }, 0);
    std.debug.assert(res.err == .ok);

    if (node == 9) {
        // The imposter: a certificate from the wrong root of trust; the
        // join must be REFUSED by the handshake.
        for (0..10) |_| {
            res = ipc.call(fab_ch, .{
                .data = shared.encodeMsg(shared.FabReq, .{ .connect_peer = .{ .node = 1 } }),
            }, 0);
            if (res.err == .ok) {
                if (shared.decodeMsg(shared.FabResp, res.msg.data)) |rep| {
                    if (rep == .ok) std.debug.panic("fabric-test: WRONG-KEY JOIN ACCEPTED", .{});
                }
            }
            fabPump(fab_ch, 2);
        }
        log.info("fabric-test: untrusted identity rejected (as designed)", .{});
        psci.systemOff();
    }

    if (node != 1) {
        // Joiners: node 3 waits so it must learn node 2 by GOSSIP, not by
        // being around for its hello.
        if (node == 3) fabPump(fab_ch, 30);
        var joined = false;
        for (0..60) |_| {
            res = ipc.call(fab_ch, .{
                .data = shared.encodeMsg(shared.FabReq, .{ .connect_peer = .{ .node = 1 } }),
            }, 0);
            if (res.err == .ok) {
                if (shared.decodeMsg(shared.FabResp, res.msg.data)) |rep| {
                    if (rep == .ok) {
                        joined = true;
                        break;
                    }
                }
            }
            fabPump(fab_ch, 2);
        }
        if (!joined) std.debug.panic("fabric-test: node {d} could not join via seed", .{node});
        log.info("fabric-test: node {d} joined the fabric via seed 1", .{node});
        if (node == 3) {
            // Authorization drill: node 3's certificate has no spawn
            // authority, so node 1 must refuse its spawn request on
            // certificate grounds — a typed denial, not a timeout.
            res = ipc.call(fab_ch, .{
                .data = shared.encodeMsg(shared.FabReq, .{ .remote_spawn = .{
                    .node = 1,
                    .image = @intFromEnum(shared.ImageId.fabric),
                    .arg = 2,
                } }),
            }, 0);
            var denied = false;
            if (res.err == .ok) {
                if (shared.decodeMsg(shared.FabResp, res.msg.data)) |rep| {
                    denied = rep == .fab_err and rep.fab_err.code == @intFromEnum(shared.FabErr.denied);
                }
            }
            if (!denied) std.debug.panic("fabric-test: unauthorized spawn was NOT refused (err {t}, words {x} {x})", .{
                res.err, res.msg.data[0], res.msg.data[1],
            });
            log.info("fabric-test: node 3 spawn refused on certificate grounds (no spawn authority)", .{});
        }
        var t: u64 = 0;
        while (true) : (t += 1) {
            fabPump(fab_ch, 1);
            if (drill == 1 and t == 120) {
                log.info("fabric-test: node {d} powering off mid-life (drill)", .{node});
                psci.systemOff();
            }
            // Node 3 keeps trying to come back once cut off: after its
            // revocation every attempt must be refused at the handshake.
            if (node == 3 and t % 30 == 0 and !memberUp(fab_ch, pb, 1)) {
                res = ipc.call(fab_ch, .{
                    .data = shared.encodeMsg(shared.FabReq, .{ .connect_peer = .{ .node = 1 } }),
                }, 0);
                var ok = false;
                if (res.err == .ok) {
                    if (shared.decodeMsg(shared.FabResp, res.msg.data)) |rep| ok = rep == .ok;
                }
                if (!ok) log.info("fabric-test: node 3 rejoin attempt refused", .{});
            }
        }
    }

    // ------------------------------------------------ node 1: the verifier
    // Stage A: both nodes join; the membership converges by gossip.
    if (!waitMember(fab_ch, pb, 2, true, 600) or !waitMember(fab_ch, pb, 3, true, 600))
        std.debug.panic("fabric-test: membership never converged", .{});
    log.info("fabric-test: membership complete — nodes 1,2,3 up (join + gossip)", .{});

    // Stage B: placement — "run this anywhere" picks a live loaded node.
    var landed = remoteSpawnRpc(fab_ch, 0) orelse
        std.debug.panic("fabric-test: placement spawn failed", .{});
    log.info("fabric-test: placement spawn landed on node {d}; RPC verified", .{landed});

    // Stage C: node 2's drill poweroff must surface as membership, with no
    // call in flight — the heartbeats alone carry the news.
    if (!waitMember(fab_ch, pb, 2, false, 900))
        std.debug.panic("fabric-test: node 2 death never detected", .{});
    log.info("fabric-test: node 2 death detected via membership", .{});

    // Stage D: the runner relaunches node 2; it must rejoin.
    if (!waitMember(fab_ch, pb, 2, true, 900))
        std.debug.panic("fabric-test: node 2 never rejoined", .{});
    log.info("fabric-test: node 2 rejoined the fabric", .{});

    // Stage E: the rejoined node hosts work again.
    landed = remoteSpawnRpc(fab_ch, 2) orelse
        std.debug.panic("fabric-test: post-rejoin spawn failed", .{});
    log.info("fabric-test: rejoined node hosts work again", .{});

    // Stage F: revoke node 3's identity through the root of trust. The
    // fabric must drop it (membership), gossip the revocation to node 2,
    // and refuse node 3's every attempt to come back — no cluster rekey.
    fabRevoke(root, fab_ch, pb, 3, 2);
    if (!waitMember(fab_ch, pb, 3, false, 300))
        std.debug.panic("fabric-test: node 3 still a member after revocation", .{});
    log.info("fabric-test: node 3 revoked by the trust root; dropped from membership", .{});
    fabPump(fab_ch, 100); // node 3's rejoin attempts must hit the refusal
    log.info("fabric-test: PASS — join, gossip, placement, death, rejoin, respawn, authorization, revocation", .{});
    psci.systemOff();
}

/// Image store setup for the shell boot: init gets the root-of-trust
/// view (the one view that sees everything — its by design) and
/// installs the archive's programs under img/, creating the directory
/// on a volume that predates it. Every step reports its typed error and
/// gives up rather than taking the boot down with an assert.
fn installImageStore(fs_ch: *ipc.Channel, pb: [*]u8, front_ch: *ipc.Channel) void {
    _ = pb;
    const res = ipc.call(fs_ch, .{
        .data = shared.encodeMsg(shared.FsReq, .{ .derive = .{ .path_off = 0, .path_len = 0, .ro = 0 } }),
    }, 0);
    if (res.err != .ok or res.msg.cap_type == 0) {
        if (shared.decodeMsg(shared.FsResp, res.msg.data)) |rep| {
            if (rep == .fs_err) return log.warn("shell: image store skipped: root view refused (fs error {d})", .{rep.fs_err.code});
        }
        return log.warn("shell: image store skipped: root view failed ({t})", .{res.err});
    }
    const img_view = ipc.call(front_ch, .{
        .data = shared.encodeMsg(shared.InitRequest, .install),
        .cap_type = @intFromEnum(cap.CapType.channel_b),
        .cap_obj = res.msg.cap_obj,
        .cap_badge = res.msg.cap_badge,
    }, 0);
    if (img_view.err != .ok) return log.warn("shell: image store skipped: init unreachable ({t})", .{img_view.err});
    const rep = shared.decodeMsg(shared.InitReply, img_view.msg.data) orelse return log.warn("shell: image store skipped: bad reply from init", .{});
    if (rep != .installed) return log.warn("shell: image store skipped: init refused to install", .{});
    log.info("shell: image store ready ({d} images installed this boot)", .{rep.installed.n});
}

/// One-shot membership query: is `node` up in this fabric's view?
fn memberUp(fab_ch: *ipc.Channel, pb: [*]u8, node: u64) bool {
    const res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .members),
    }, 0);
    if (res.err != .ok) return false;
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse return false;
    if (rep != .num) return false;
    for (0..@intCast(rep.num.n)) |i| {
        const rec = pb[i * shared.fab_member_size ..];
        const rnode = @as(u64, rec[0]) | (@as(u64, rec[1]) << 8);
        if (rnode == node) return rec[2] != 0;
    }
    return false;
}

/// The root of trust for one boot: fabroot, a separate domain holding the
/// cluster's root signing key (the imposter drill flips a seed byte — a
/// different root). Kept alive as the admin's key-custody service.
const FabRoot = struct { d: *domain.Domain, ch: *ipc.Channel, buf: *ipc.Shm, pb: [*]u8 };

fn spawnFabroot(bad_root: bool) FabRoot {
    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const d = domain.spawn("fabroot", .{ .blob = img(.fabric) }, .{
        .arg = 3,
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fabroot: {t}", .{e});
    const buf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, buf.pages[0]);
    ipc.refShm(buf);
    var res = ipc.call(ch, .{
        .data = shared.encodeMsg(shared.RootReq, .attach_buf),
        .cap_type = @intFromEnum(cap.CapType.shm),
        .cap_obj = @intFromPtr(buf),
    }, 0);
    std.debug.assert(res.err == .ok);
    const root_seed = "moss-root-of-trust-seed-01234567";
    comptime std.debug.assert(root_seed.len == 32);
    @memcpy(pb[0..32], root_seed);
    if (bad_root) pb[0] ^= 0xff;
    res = ipc.call(ch, .{
        .data = shared.encodeMsg(shared.RootReq, .{ .set_root = .{ .off = 0, .len = 32 } }),
    }, 0);
    std.debug.assert(res.err == .ok);
    return .{ .d = d, .ch = ch, .buf = buf, .pb = pb };
}

fn rootNum(res: ipc.CallResult, want: u64) void {
    std.debug.assert(res.err == .ok);
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse @panic("root: bad reply");
    if (rep != .num or rep.num.n != want) @panic("root: refused");
}

/// Certify fabsvc's identity: fabsvc derives its keypair from a node seed
/// and exports the PUBLIC key; fabroot signs it into a certificate with
/// the node's authorizations; fabsvc verifies and installs it. The boot
/// driver is the out-of-band channel between the two — neither service
/// ever sees the other's secret. `fb` is fabsvc's attached buffer.
fn certifyFabric(root: FabRoot, fab_ch: *ipc.Channel, fb: [*]u8, node: u64, flags: u64, image_mask: u64) void {
    rootNum(ipc.call(root.ch, .{
        .data = shared.encodeMsg(shared.RootReq, .cluster_key),
    }, 0), 32);
    var node_seed: [32]u8 = "moss-node-identity-seed-00000000".*;
    node_seed[31] = @intCast(node);
    @memcpy(fb[0..32], &node_seed);
    @memcpy(fb[32..64], root.pb[0..32]);
    rootNum(ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .{ .set_identity = .{ .off = 0, .len = shared.fab_identity_len } }),
    }, 0), 32);
    // fabsvc left its public key at fb[0..32]; the root certifies it.
    @memcpy(root.pb[0..32], fb[0..32]);
    rootNum(ipc.call(root.ch, .{
        .data = shared.encodeMsg(shared.RootReq, .{
            .issue = .{
                .node = node,
                .flags_serial = flags | (1 << 8), // serial 1
                .image_mask = image_mask,
            },
        }),
    }, 0), shared.fab_cert_len);
    @memcpy(fb[0..shared.fab_cert_len], root.pb[0..shared.fab_cert_len]);
    const res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .{ .set_cert = .{ .off = 0, .len = shared.fab_cert_len } }),
    }, 0);
    std.debug.assert(res.err == .ok);
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse @panic("fabsvc: bad reply");
    if (rep != .ok) @panic("fabsvc refused its own certificate");
}

/// Revoke a node's identity: a root-signed record, handed to the local
/// fabsvc, which applies it and gossips it through the mesh.
fn fabRevoke(root: FabRoot, fab_ch: *ipc.Channel, fb: [*]u8, node: u64, min_serial: u64) void {
    rootNum(ipc.call(root.ch, .{
        .data = shared.encodeMsg(shared.RootReq, .{ .revoke = .{ .node = node, .min_serial = min_serial } }),
    }, 0), shared.fab_rev_len);
    @memcpy(fb[0..shared.fab_rev_len], root.pb[0..shared.fab_rev_len]);
    const res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .{ .revoke = .{ .off = 0, .len = shared.fab_rev_len } }),
    }, 0);
    std.debug.assert(res.err == .ok);
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse @panic("fabsvc: bad reply");
    if (rep != .ok) @panic("fabsvc refused the revocation");
}

/// Pump the fabric for `ticks` driver ticks.
fn fabPump(fab_ch: *ipc.Channel, ticks: u64) void {
    for (0..ticks) |_| {
        _ = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .poll),
        }, 0);
        sched.sleep(1);
    }
}

/// Poll the fabric's member view until `node` reaches `want_up`.
fn waitMember(fab_ch: *ipc.Channel, pb: [*]u8, node: u64, want_up: bool, ticks: u64) bool {
    for (0..ticks) |_| {
        fabPump(fab_ch, 1);
        const res = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .members),
        }, 0);
        if (res.err != .ok) continue;
        const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse continue;
        if (rep != .num) continue;
        const n = rep.num.n;
        for (0..@intCast(n)) |i| {
            const rec = pb[i * shared.fab_member_size ..];
            const rnode = @as(u64, rec[0]) | (@as(u64, rec[1]) << 8);
            const up = rec[2] != 0;
            if (rnode == node and up == want_up) return true;
        }
    }
    return false;
}

/// remote_spawn (node 0 = placement) + one verified RPC through the
/// proxied channel. Returns the node the spawn landed on.
fn remoteSpawnRpc(fab_ch: *ipc.Channel, node: u64) ?u64 {
    const res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .{ .remote_spawn = .{
            .node = node,
            .image = @intFromEnum(shared.ImageId.fabric),
            .arg = 2,
        } }),
    }, 0);
    if (res.err != .ok) return null;
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse return null;
    if (rep != .spawned or res.msg.cap_type == 0) return null;
    const landed = rep.spawned.node;
    const badge = res.msg.cap_badge;
    const call_res = ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.CalcRequest, .{ .add = .{ .a = 40, .b = 2 } }),
    }, badge);
    if (call_res.err != .ok) return null;
    if (call_res.msg.data[0] == shared.fabric_err_sentinel) return null;
    const crep = shared.decodeMsg(shared.CalcReply, call_res.msg.data) orelse return null;
    if (crep != .sum or crep.sum.value != 42) return null;
    return landed;
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

/// A program image out of the boot archive (img/<name>) for the kernel's
/// own boot drivers. Userspace spawners stage the same entries themselves.
fn img(id: shared.ImageId) []const u8 {
    return domain.bootImage(shared.imagePath(id)) orelse
        std.debug.panic("boot archive lacks {s}", .{shared.imagePath(id)});
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
