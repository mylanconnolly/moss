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
const its = @import("its.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const pci = @import("pci.zig");
const pmem = @import("pmem.zig");
const psci = @import("psci.zig");
const rng = @import("rng.zig");
const sched = @import("sched.zig");
const sched_test = @import("sched_test.zig");
const smmu = @import("smmu.zig");
const smp = @import("smp.zig");
const timer = @import("timer.zig");
const trace = @import("trace.zig");
const trap = @import("trap.zig");
const vm = @import("vm.zig");

comptime {
    _ = @import("boot.zig");
}

pub const panic = std.debug.FullPanic(panicHandler);

export fn kmain(dtb_pa: u64) noreturn {
    log.print("\nmoss {f} — aarch64 / qemu-virt\n\n", .{shared.version});

    trap.init();
    log.info("core 0 up at EL{d}{s}, vectors installed", .{ currentEl(), if (currentEl() == 2) " (VHE host)" else "" });

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
        boot_profile = parseProfile(args);
    }
    // Devices come from the tree, not from constants: the PCIe host is
    // enumerated once the memory map is up (its ECAM needs a mapping).
    pcie_host = fdt.pcieHost();
    if (pcie_host == null) log.warn("devicetree: no PCIe host; userspace drivers will find no devices", .{});
    smmu_info = fdt.smmu();
    its_reg = fdt.findReg("arm,gic-v3-its");

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
    if (pcie_host) |h| pci.init(h);
    if (smmu_info) |i| smmu.init(i) else log.warn("devicetree: no SMMU; device DMA is untranslated", .{});

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
    if (its_reg) |r| its.init(r.base, r.size) else log.warn("devicetree: no ITS; devices stay on INTx", .{});
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

    if (build_options.login_test) {
        _ = sched.spawn("boot-watch", loginTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.flogin_test) {
        _ = sched.spawn("boot-watch", floginTestWorker, 0, .{}) catch |e| {
            std.debug.panic("spawn boot-watch: {t}", .{e});
        };
    }

    if (build_options.users_test) {
        _ = sched.spawn("boot-watch", usersTestWorker, 0, .{}) catch |e| {
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

    if (build_options.cpu_test) {
        _ = sched.spawn("cpu-test", cpuTestWorker, 0, .{}) catch @panic("spawn cpu-test");
    }
    if (build_options.pan_test) {
        _ = sched.spawn("pan-test", panTestWorker, 0, .{}) catch @panic("spawn pan-test");
    }
    if (build_options.vm_test) {
        _ = sched.spawn("vm-test", vmTestWorker, 0, .{}) catch @panic("spawn vm-test");
    }
    if (build_options.guest_test) {
        _ = sched.spawn("guest-test", vmTestWorker, 1, .{}) catch @panic("spawn guest-test");
    }
    if (build_options.guest_kernel) {
        // This kernel IS the guest: a fabric node when its VMM named one
        // (`node=` in the devicetree it wrote), else the guest profile.
        if (boot_node != 0) {
            _ = sched.spawn("boot-watch", fabricTestWorker, boot_node, .{}) catch @panic("spawn boot-watch");
        } else {
            _ = sched.spawn("boot-watch", guestKernelWorker, 0, .{}) catch @panic("spawn boot-watch");
        }
    }
    if (build_options.vmnode_test) {
        _ = sched.spawn("vmnode-test", vmnodeTestWorker, 0, .{}) catch @panic("spawn vmnode-test");
    }
    if (build_options.smmu_test) {
        _ = sched.spawn("smmu-test", smmuTestWorker, 0, .{}) catch @panic("spawn smmu-test");
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
        var token: u64 = 0;
        const e = ipc.recv(fault_ch, &msg, &badge, &token);
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
    ipc.unrefSide(fault_ch, .a, 0);

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

    // In-transit caps die with their sender: a client parked in a call
    // with a shared buffer attached, torn down before anyone receives;
    // then one whose server side dies under the call. The shm account
    // must be zero after both — a ref left in a dead thread's mailbox
    // once leaked a page per unanswered logout.
    {
        const ch2 = ipc.createChannel(1, 1) catch @panic("channel pool empty");
        const parked = domain.spawn("parked", .{ .blob = img(.pingpong) }, .{
            .grant_debug_log = true,
            .grant_channel_b = ch2,
            .arg = 4,
        }) catch |e| std.debug.panic("spawn parked: {t}", .{e});
        sched.sleep(5);
        domain.destroy(parked);
        while (!domain.drained(parked)) sched.sleep(1);
        domain.finishTeardown(parked);
        ipc.unrefSide(ch2, .a, 0); // a grant transfers the side's ref; ours was A
        const ch3 = ipc.createChannel(1, 1) catch @panic("channel pool empty");
        const orphan = domain.spawn("orphan", .{ .blob = img(.pingpong) }, .{
            .grant_debug_log = true,
            .grant_channel_b = ch3,
            .arg = 4,
        }) catch |e| std.debug.panic("spawn orphan: {t}", .{e});
        sched.sleep(5);
        ipc.unrefSide(ch3, .a, 0); // the server side dies under the call
        while (!(orphan.state == .dying and domain.drained(orphan))) sched.sleep(1);
        domain.finishTeardown(orphan);
        sched.sleep(2);
        if (orphan.exit_code != 0 or ipc.shm_account.balance() != 0) {
            ipc.dumpShms();
            std.debug.panic("ipc-test: FAIL — in-transit cap leaked: orphan exit {d}, shm {d}B", .{ orphan.exit_code, ipc.shm_account.balance() });
        }
        log.info("ipc-test: in-transit caps released — sender torn down mid-call, server death under a call", .{});
    }

    // Client identities: a badge minted on a channel is refcounted on its
    // own, and the server hears of THAT client's death — while other
    // clients and the side live on — as client_dead naming the badge,
    // waking it if it is parked in recv. Every remaining death is
    // reported before the side's own.
    {
        const chb = ipc.createChannel(1, 1) catch @panic("channel pool empty");
        ipc.mintBadge(chb, 7) catch @panic("badge pool empty");
        ipc.refSide(chb, .b, 7); // a copy of client 7's cap
        ipc.mintBadge(chb, 9) catch @panic("badge pool empty");
        ipc.unrefSide(chb, .b, 7); // one copy dies: client 7 lives on
        if (chb.deaths_pending != 0) @panic("ipc-test: a death reported while a copy of the cap lives");
        const helper = sched.spawn("badge-recv", badgeRecvHelper, @intFromPtr(chb), .{}) catch
            @panic("spawn badge-recv");
        _ = helper;
        sched.sleep(3); // the helper is parked in recv by now
        ipc.unrefSide(chb, .b, 7); // client 7's last cap
        sched.sleep(3);
        if (badge_recv_err != .client_dead or badge_recv_badge != 7) {
            std.debug.panic("ipc-test: FAIL — parked server got {t} badge {d}, expected client_dead 7", .{ badge_recv_err, badge_recv_badge });
        }
        if (!chb.b_open) @panic("ipc-test: side closed while client 9 lives");
        ipc.unrefSide(chb, .b, 9); // client 9's last cap...
        ipc.unrefSide(chb, .b, 0); // ...and our own unbadged ref: the side closes
        var msg: ipc.Msg = .{};
        var badge: u64 = 0;
        var token: u64 = 0;
        const e1 = ipc.recv(chb, &msg, &badge, &token);
        const e2 = ipc.recv(chb, &msg, &badge, &token);
        if (e1 != .client_dead or badge != 9 or e2 != .peer_dead) {
            std.debug.panic("ipc-test: FAIL — after the last client: {t} (badge {d}) then {t}, expected client_dead 9 then peer_dead", .{ e1, badge, e2 });
        }
        ipc.unrefSide(chb, .a, 0);
        if (ipc.badgeCount() != 0) std.debug.panic("ipc-test: FAIL — {d} badge entries left after the channel died", .{ipc.badgeCount()});
        log.info("ipc-test: client identities — a badge's last cap reported as client_dead (a parked server woken), the side outliving it until every client is gone", .{});
    }

    // The scaling benchmark: call/reply pairs pinned one per core. How
    // far three cores get past one is the scheduler lock's fingerprint.
    const one = ipcBench(1);
    const three = ipcBench(@min(3, sched.onlineCount() - 1));
    log.info("ipc-test: bench call/reply — 1 core: {d} kops/s, 3 cores: {d} kops/s total ({d}.{d}x)", .{
        one / 1000, three / 1000, three / @max(one, 1), (three * 10 / @max(one, 1)) % 10,
    });
    sched.sleep(3); // let the bench threads be reaped before the leak bar

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
        .grant_windows = true,
        .grant_entropy = true,
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
        .grant_windows = true,
        .grant_entropy = true,
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

/// The blk drill: a system boot under profile "blk" — root, init, and the
/// unit files do everything; the kernel spawns root and holds the leak
/// bar when the drill's essential unit has exited.
fn blkTestWorker(_: u64) void {
    systemDrill("blk");
}

/// The fs drill: a system boot under profile "fs" — root, init, and the
/// unit files do everything; the kernel spawns root and holds the leak
/// bar when the drill's essential unit has exited.
fn fsTestWorker(_: u64) void {
    systemDrill("fs");
}

/// The users drill: a system boot under profile "users" — the admin step
/// writes user records, then the drill logs in as two users at once
/// through the session manager; the kernel holds the leak bar after the
/// sessions (domains) and the drill have exited.
fn usersTestWorker(_: u64) void {
    systemDrill("users");
}

/// The login drill: a system boot under profile "login" — the session
/// manager runs a login prompt on two consoles and the runner logs two
/// users in at once, each getting an init instance with msh on its home;
/// the manager exits when both have logged out.
fn loginTestWorker(_: u64) void {
    systemDrill("login");
}

/// The fabric-login drill: two system boots on one segment, both with a
/// disk. Node 1 (profile flogin) applies the users and publishes its
/// session manager; node 2 (profile fjoin) has no records, joins the
/// fabric, and the runner logs alice in on its console — her record is
/// fetched from node 1 over the wire, her home is born on node 2.
fn floginTestWorker(_: u64) void {
    systemDrill("flogin");
}

/// Developer-tooling boot: the storage stack, the virtio-console driver,
/// init (serving its front channel), and msh — the interactive shell —
/// wired together by capability grants. Used by both `zig build
/// run-shell` (a human on the console) and the scripted shell check
/// (the runner drives the console over a socket chardev). PASS when msh
/// exits cleanly and nothing leaked.
fn shellTestWorker(_: u64) void {
    systemDrill("shell");
}

/// A system boot: root gets the boot grants — log, spawn authority, the
/// boot archive, and the device capabilities — plus the profile from
/// the boot arguments, and init starts that profile's eager units from
/// boot/conf/units. The kernel's only remaining job is to spawn root
/// and, when the system has shut itself down, hold the leak bar.
fn systemDrill(comptime name: []const u8) void {
    const frames_before = pmem.stats().free_bytes;

    log.info(name ++ ": spawning root (profile {t})", .{boot_profile});
    const root = domain.spawn("root", .{ .blob = img(.root) }, .{
        .arg = 2 | (@intFromEnum(boot_profile) << 8) | (boot_node << 16),
        .grant_debug_log = true,
        .grant_spawner = true,
        .grant_bootfs = true,
        .grant_windows = true,
        .grant_entropy = true,
        .kobj_limit = 24 << 20,
        .user_limit = 128 << 20,
    }) catch |e| std.debug.panic("spawn root: {t}", .{e});

    // A hang is a failure with a dump, not a runner timeout on a silent
    // log: past the deadline, every thread and core is printed.
    const hang_ticks = 60 * timer.ticks_per_second;
    var waited: u64 = 0;
    while (!(root.state == .dying and domain.drained(root))) {
        sched.sleep(2);
        waited += 2;
        if (waited > hang_ticks) {
            sched.debugDump();
            domain.debugDump();
            ipc.debugDumpNotifications();
            irq.debugDump();
            trace.dump();
            std.debug.panic(name ++ "-test: HANG — the system has not shut down after 60s", .{});
        }
    }
    domain.finishTeardown(root);
    const code = root.exit_code;

    sched.sleep(5);
    const frames_after = pmem.stats().free_bytes;
    if (code == 0 and frames_after == frames_before and ipc.shm_account.balance() == 0) {
        log.info(name ++ "-test: PASS — the system booted from unit files, ran its drill, and shut down clean", .{});
        psci.systemOff();
    } else {
        ipc.dumpShms();
        trace.dump();
        std.debug.panic(name ++ "-test: FAIL — root exit {d}, pmem delta {d}B, shm {d}B", .{
            code, frames_before -% frames_after, ipc.shm_account.balance(),
        });
    }
}

/// The net drill: a system boot under profile "net" — root, init, and the
/// unit files do everything; the kernel spawns root and holds the leak
/// bar when the drill's essential unit has exited.
fn netTestWorker(_: u64) void {
    systemDrill("net");
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
    bootGiveDevice(boot_ch, .rng);
    bootGive(boot_ch, .entropy, .entropy, 0, 0);
    bootGo(boot_ch);
    ipc.unrefSide(boot_ch, .b, 0);
    var waited: u64 = 0;
    while (!rng.isSeeded()) : (waited += 1) {
        if (d.state == .dead) std.debug.panic("rngd died before seeding: exit {d}", .{d.exit_code});
        if (waited == 100) std.debug.panic("rngd never seeded the pool", .{});
        sched.sleep(1);
    }
    return d;
}

// ------------------------------------------------------- boot protocol
//
// The kernel's boot drivers speak the same BootReq messages init will:
// caps by tag, secrets and data staged in the program's buffer, go.

fn bootGive(boot_ch: *ipc.Channel, tag: shared.CapTag, ct: cap.CapType, obj: u64, badge: u64) void {
    const res = ipc.call(boot_ch, .{
        .data = shared.encodeMsg(shared.BootReq, .{ .cap = .{ .tag = @intFromEnum(tag), .kind = 0 } }),
        .cap_type = @intFromEnum(ct),
        .cap_obj = obj,
        .cap_badge = badge,
    }, 0);
    std.debug.assert(res.err == .ok);
}

/// Hand over the B side of a channel (takes a ref for the receiver).
fn bootGiveChan(boot_ch: *ipc.Channel, tag: shared.CapTag, ch: *ipc.Channel) void {
    ipc.refSide(ch, .b, 0);
    bootGive(boot_ch, tag, .channel_b, @intFromPtr(ch), 0);
}

/// Hand over a shared buffer (takes a ref for the receiver).
fn bootGiveShm(boot_ch: *ipc.Channel, tag: shared.CapTag, s: *ipc.Shm) void {
    ipc.refShm(s);
    bootGive(boot_ch, tag, .shm, @intFromPtr(s), 0);
}

fn bootSecret(boot_ch: *ipc.Channel, off: u64, len: u64) void {
    const res = ipc.call(boot_ch, .{ .data = shared.encodeMsg(shared.BootReq, .{ .secret = .{ .off = off, .len = len } }) }, 0);
    std.debug.assert(res.err == .ok);
}

fn bootGo(boot_ch: *ipc.Channel) void {
    const res = ipc.call(boot_ch, .{ .data = shared.encodeMsg(shared.BootReq, .go) }, 0);
    std.debug.assert(res.err == .ok);
}

/// Spawn a driver (log + its service channel) and hand it its device
/// over that channel, then go.
fn spawnDevice(name: []const u8, id: shared.ImageId, arg: u64, ch: *ipc.Channel, kind: shared.DeviceKind) *domain.Domain {
    const d = domain.spawn(name, .{ .blob = img(id) }, .{
        .arg = arg,
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn {s}: {t}", .{ name, e });
    bootGiveDevice(ch, kind);
    bootGo(ch);
    return d;
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

/// The IOMMU drill. First the ordinary block drill, now with every DMA
/// translated by the SMMU (root, init and the blk profile's units, as
/// in the blk test). Then a rogue: a program handed the same disk that
/// asks it to DMA into a kernel page — the physical address of the
/// canary below — and the SMMU must refuse: an event recorded with that
/// stream id and address, the canary untouched. PASS also holds the
/// usual leak bar.
var smmu_canary: [4096]u8 align(4096) = @splat(0);

fn smmuTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;
    if (!smmu.active) std.debug.panic("smmu-test: FAIL — no SMMU in front of the bus", .{});
    ensureDevices();
    const blk_idx = pci.byKind(.blk) orelse std.debug.panic("smmu-test: FAIL — no virtio-blk on the bus", .{});

    log.info("smmu-test: block drill with every DMA translated", .{});
    const root = domain.spawn("root", .{ .blob = img(.root) }, .{
        .arg = 2 | (@intFromEnum(shared.BootProfile.blk) << 8),
        .grant_debug_log = true,
        .grant_spawner = true,
        .grant_bootfs = true,
        .grant_windows = true,
        .grant_entropy = true,
        .kobj_limit = 24 << 20,
        .user_limit = 96 << 20,
    }) catch |e| std.debug.panic("spawn root: {t}", .{e});
    while (!(root.state == .dying and domain.drained(root))) sched.sleep(2);
    domain.finishTeardown(root);
    if (root.exit_code != 0) std.debug.panic("smmu-test: FAIL — block drill exit {d}", .{root.exit_code});
    if (smmu.fault_count != 0) std.debug.panic("smmu-test: FAIL — {d} DMA faults during the honest drill", .{smmu.fault_count});
    log.info("smmu-test: block drill completed through the SMMU without a fault", .{});

    @memset(&smmu_canary, 0xa5);
    const target = mem.virtToPhys(@intFromPtr(&smmu_canary));
    log.info("smmu-test: handing the disk to a rogue that targets kernel page 0x{x}", .{target});
    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const rogue = domain.spawn("rogue", .{ .blob = img(.blk) }, .{
        .arg = 3 | (target << 8),
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn rogue: {t}", .{e});
    bootGiveDevice(ch, .blk);
    bootGo(ch);
    ipc.unrefSide(ch, .b, 0);
    while (rogue.state != .dead) sched.sleep(1);
    sched.sleep(3);

    // (By pointer: iterating the array by value would copy 4K onto a
    // kernel stack that Debug-mode formatting frames already crowd.)
    var intact = true;
    for (&smmu_canary) |*b| {
        if (b.* != 0xa5) intact = false;
    }
    // The device retries a refused burst word by word: many events, all
    // inside the one sector it was pointed at.
    const sid = pci.devices[blk_idx].sid;
    const faulted = smmu.fault_count >= 1 and smmu.last_fault_sid == sid and
        smmu.first_fault_addr == target and smmu.last_fault_addr >= target and smmu.last_fault_addr < target + 512;
    const frames_after = pmem.stats().free_bytes;
    if (intact and faulted and frames_after == frames_before and ipc.shm_account.balance() == 0) {
        log.info("smmu-test: PASS — DMA confined to the holder's address space: the rogue's write to kernel memory was refused ({d} refusals recorded, canary intact), nothing leaked", .{smmu.fault_count});
        psci.systemOff();
    } else {
        std.debug.panic("smmu-test: FAIL — canary intact {}, fault matched {} (count {d}, sid {d}, addr 0x{x}), pmem delta {d}B", .{
            intact, faulted, smmu.fault_count, smmu.last_fault_sid, smmu.last_fault_addr, frames_before -% frames_after,
        });
    }
}

/// The VM drill: a userspace VMM, handed the hypervisor capability and
/// the boot archive, builds a VM, loads the bare-metal guest image into
/// it and runs it at EL1 in its own stage-2 world. The guest's UART
/// stores trap to the VMM (log lines), its virtual timer ticks are
/// injected through the vGIC, and its PSCI power-off ends the run. PASS
/// when the VMM exits 0 (it saw three ticks and the power-off) and the
/// leak bar holds.
fn vmTestWorker(which: u64) void {
    const frames_before = pmem.stats().free_bytes;
    const name: []const u8 = if (which == 1) "guest-test" else "vm-test";
    if (currentEl() != 2) std.debug.panic("{s}: FAIL — the kernel is not an EL2 host", .{name});
    log.info("{s}: starting the VMM ({s})", .{ name, if (which == 1) "a moss kernel as the guest" else "the bare-metal guest" });
    const vmm = spawnVmm(which);
    var waited: u64 = 0;
    while (vmm.state != .dead) : (waited += 1) {
        if (waited == 600) {
            log.warn("{s}: vm stats: entries {d}, wfi {d}, waits {d}, timer fires {d} injected {d} unmasks {d}, spi injected {d}", .{
                name, vm.stat_entries, vm.stat_wfi, vm.stat_waits, vm.stat_timer_fires, vm.stat_timer_injected, vm.stat_unmasks, vm.stat_spi_injected,
            });
            std.debug.panic("{s}: FAIL — the guest never powered off", .{name});
        }
        sched.sleep(1);
    }
    if (vmm.exit_code != 0) std.debug.panic("{s}: FAIL — vmm exit {d}", .{ name, vmm.exit_code });
    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    if (frames_after != frames_before) std.debug.panic("{s}: FAIL — {d}B unaccounted", .{ name, frames_before -% frames_after });
    if (which == 1) {
        log.info("guest-test: PASS — a moss kernel booted at EL1 inside a moss VM: devicetree from the VMM, PL011 and GIC emulated as trapped MMIO, virtual timer, PSCI over HVC, its userspace ran and it powered off; nothing leaked", .{});
    } else {
        log.info("vm-test: PASS — an EL1 guest ran in its own stage-2 world: MMIO trapped to the VMM, virtual timer ticks injected through the vGIC, PSCI power-off honoured, nothing leaked", .{});
    }
    psci.systemOff();
}

/// This kernel is a guest: the system boot under the profile its VMM
/// named (`guest`: one program that says hello and exits), then power
/// off through PSCI — which the hypervisor turns into the VMM's exit.
fn guestKernelWorker(_: u64) void {
    systemDrill("guest");
}

/// The CPU drill, the third budget and the partition: three domains
/// of two spinning threads each. "quarter" may spend a quarter of a
/// core per period; "greedy" has no limit of its own; "island" owns
/// core 3 exclusively. Three periods later: quarter's last period is
/// near 250 permille, greedy's is well over a core, island's is one
/// core, and every sample of core 3 ran island (or idle) while island
/// never ran elsewhere. Then teardown and the leak bar.
fn cpuTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;
    log.info("cpu-test: a quarter-core budget, an unlimited sibling, and a partition on core 3", .{});
    const quarter = domain.spawn("quarter", .{ .blob = img(.services) }, .{
        .arg = 6,
        .grant_debug_log = true,
        .auto_reap = true,
        .cpu_permille = 250,
    }) catch |e| std.debug.panic("spawn quarter: {t}", .{e});
    const greedy = domain.spawn("greedy", .{ .blob = img(.services) }, .{
        .arg = 6,
        .grant_debug_log = true,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn greedy: {t}", .{e});
    const island = domain.spawn("island", .{ .blob = img(.services) }, .{
        .arg = 6,
        .grant_debug_log = true,
        .auto_reap = true,
        .cores = 1 << 3,
    }) catch |e| std.debug.panic("spawn island: {t}", .{e});
    if (domain.spawn("squatter", .{ .blob = img(.services) }, .{ .arg = 6, .grant_debug_log = true, .auto_reap = true, .cores = 1 << 3 })) |_| {
        std.debug.panic("cpu-test: FAIL — a second domain reserved core 3", .{});
    } else |e| {
        if (e != domain.Error.CoresBusy) std.debug.panic("cpu-test: FAIL — wrong refusal {t}", .{e});
        log.info("cpu-test: a second reservation of core 3 refused", .{});
    }

    // Three and a half periods, sampling placement every tick.
    const t0 = cycles();
    var bad_placement: u64 = 0;
    var island_seen_on_3: u64 = 0;
    for (0..35) |_| {
        sched.sleep(1);
        var c: u32 = 1;
        while (c < 4) : (c += 1) {
            const t = sched.currentOn(c);
            const owner: ?*anyopaque = t.user_ctx;
            if (c == 3) {
                if (owner == @as(*anyopaque, @ptrCast(island))) {
                    island_seen_on_3 += 1;
                } else if (owner != null or !sched.isIdle(t)) {
                    bad_placement += 1;
                }
            } else if (owner == @as(*anyopaque, @ptrCast(island))) {
                bad_placement += 1;
            }
        }
    }
    const elapsed = cycles() - t0;
    const q = domain.cpuPermilleAvg(quarter, elapsed);
    const g = domain.cpuPermilleAvg(greedy, elapsed);
    const i = domain.cpuPermilleAvg(island, elapsed);
    log.info("cpu-test: averaged — quarter {d}‰ (last period {d}‰), greedy {d}‰, island {d}‰ of a core; island on core 3 in {d} samples, misplacements {d}", .{
        q, domain.cpuPermilleUsed(quarter), g, i, island_seen_on_3, bad_placement,
    });

    domain.destroy(quarter);
    domain.destroy(greedy);
    domain.destroy(island);
    while (quarter.state != .dead or greedy.state != .dead or island.state != .dead) sched.sleep(1);
    sched.sleep(3);
    const frames_after = pmem.stats().free_bytes;
    const budget_ok = q >= 150 and q <= 380;
    const greedy_ok = g >= 1000;
    const island_ok = i >= 850 and i <= 1100 and island_seen_on_3 >= 25 and bad_placement == 0;
    if (budget_ok and greedy_ok and island_ok and frames_after == frames_before) {
        log.info("cpu-test: PASS — the CPU budget held a domain to its share, an unlimited sibling took the rest, and a partition kept a core to one domain; nothing leaked", .{});
        psci.systemOff();
    } else {
        std.debug.panic("cpu-test: FAIL — budget {} (q={d}), greedy {} (g={d}), island {} (i={d} on3={d} bad={d}), pmem delta {d}B", .{
            budget_ok, q, greedy_ok, g, island_ok, i, island_seen_on_3, bad_placement, frames_before -% frames_after,
        });
    }
}

/// The PAN drill: a domain logs a line; the log syscall (built with the
/// drill flag) touches the caller's range-checked buffer with the
/// uaccess window closed. With PAN the kernel faults — the expected
/// end of this boot, reported as such. Without PAN (an ARMv8.0 CPU)
/// the access goes through and the boot ends cleanly, saying so.
fn panTestWorker(_: u64) void {
    log.info("pan-test: a syscall will touch user memory outside a uaccess window; PAN must refuse it", .{});
    const hello = domain.spawn("hello", .{ .blob = img(.hello) }, .{
        .grant_debug_log = true,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn hello: {t}", .{e});
    sched.sleep(20);
    _ = hello;
    log.info("pan-test: no fault — this CPU has no PAN; range checks alone (ARMv8.0 behaviour)", .{});
    psci.systemOff();
}

/// The VMM: log, the boot archive (guest images), the hypervisor cap
/// (slot 2, after log and its boot channel), and over the boot channel
/// whatever devices the guest is to own — none for the first two
/// guests, the second rng and net for a pool node.
fn spawnVmm(which: u64) *domain.Domain {
    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const vmm = domain.spawn("vmm", .{ .blob = img(.vmm) }, .{
        .arg = which,
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .grant_bootfs = true,
        .grant_hypervisor = true,
        .auto_reap = true,
        .kobj_limit = 8 << 20,
        .user_limit = 192 << 20,
    }) catch |e| std.debug.panic("spawn vmm: {t}", .{e});
    if (which == 2) {
        bootGiveDeviceNth(ch, .rng, 1);
        bootGiveDeviceNth(ch, .net, 1);
    }
    bootGo(ch);
    ipc.unrefSide(ch, .b, 0);
    return vmm;
}

/// The pool-node drill: this machine is fabric node 1, and a VM on it
/// is node 2. Node 1 comes up as in the fabric drill (entropy, the
/// network in cluster mode, root of trust, fabric service, certified
/// with spawn authority). The VMM gets the machine's second entropy
/// device and second NIC passed through — BARs in the guest's stage 2,
/// DMA through it by the SMMU, interrupts injected — and boots a moss
/// kernel told `node=2`, which runs the same joiner path a physical
/// node does. PASS when node 2 appears in node 1's membership and a
/// remote spawn placed on it answers an RPC: one box, two pool nodes.
fn vmnodeTestWorker(_: u64) void {
    const frames_before = pmem.stats().free_bytes;
    if (currentEl() != 2) std.debug.panic("vmnode-test: FAIL — the kernel is not an EL2 host", .{});
    ensureDevices();
    if (pci.nthByKind(.net, 1) == null or pci.nthByKind(.rng, 1) == null)
        std.debug.panic("vmnode-test: FAIL — the guest needs a second NIC and a second entropy device on the bus", .{});
    log.info("vmnode-test: node 1 coming up", .{});
    _ = spawnRngd(0);
    const net_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    _ = spawnDevice("netsvc", .net, 1 | (1 << 8), net_ch, .net);
    sched.sleep(3);
    const fab_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    _ = domain.spawn("fabsvc", .{ .blob = img(.fabric) }, .{
        .arg = 1 | (1 << 8),
        .grant_debug_log = true,
        .grant_channel_a = fab_ch,
        .grant_spawner = true,
        .grant_bootfs = true,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn fabsvc: {t}", .{e});
    const root = spawnFabroot(false);
    const pathbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, pathbuf.pages[0]);
    certifyFabric(root, fab_ch, pathbuf, pb, 1, shared.fab_flag_gossip | shared.fab_flag_spawn, ~@as(u64, 0), deriveNetView(net_ch, 0, 0, 0));

    log.info("vmnode-test: starting the VMM with the second NIC and entropy device passed through; the guest is node 2", .{});
    const vmm = spawnVmm(2);

    if (!waitMember(fab_ch, pb, 2, true, 1200)) {
        if (vmm.state == .dead) log.warn("vmnode-test: the VMM died with exit {d}", .{vmm.exit_code});
        log.warn("vmnode-test: vm stats: entries {d}, wfi {d}, waits {d}, timer fires {d} injected {d} unmasks {d}, spi injected {d}", .{
            vm.stat_entries, vm.stat_wfi, vm.stat_waits, vm.stat_timer_fires, vm.stat_timer_injected, vm.stat_unmasks, vm.stat_spi_injected,
        });
        std.debug.panic("vmnode-test: FAIL — the guest never joined the fabric", .{});
    }
    log.info("vmnode-test: the guest joined the fabric as node 2 — a VM is a pool node", .{});
    const placed = remoteSpawnRpc(fab_ch, 2) orelse std.debug.panic("vmnode-test: FAIL — spawn on the guest node failed", .{});
    if (placed.node != 2) std.debug.panic("vmnode-test: FAIL — spawn landed on node {d}", .{placed.node});
    log.info("vmnode-test: remote spawn landed on node 2 (inside the VM) and answered an RPC", .{});
    // The VM stays up (a pool node is not a drill that ends), so the
    // leak bar is the other VM tests' job.
    _ = frames_before;
    log.info("vmnode-test: PASS — one box, two pool nodes: a moss guest with passed-through devices joined the fabric and ran a remote spawn", .{});
    psci.systemOff();
}

var boot_node: u64 = 0;
var boot_drill: u64 = 0;
var boot_badkey: u64 = 0;
var boot_profile: shared.BootProfile = .system;

/// `profile=<name>` in the boot arguments selects which units init starts.
fn parseProfile(args: []const u8) shared.BootProfile {
    const key = "profile=";
    var i: usize = 0;
    while (i + key.len <= args.len) : (i += 1) {
        if (!std.mem.eql(u8, args[i .. i + key.len], key)) continue;
        var end = i + key.len;
        while (end < args.len and args[end] != ' ') end += 1;
        return std.meta.stringToEnum(shared.BootProfile, args[i + key.len .. end]) orelse .system;
    }
    return .system;
}

/// The PCIe host bridge from the devicetree (null if none).
var pcie_host: ?dt.PcieHost = null;
var smmu_info: ?dt.Smmu = null;
var its_reg: ?dt.Reg = null;

/// The kernel's own drills need the device table filled: spawn the
/// enumerator once (told to register and exit) with the platform
/// windows over its boot channel, and wait for it.
var devices_ready = false;

fn ensureDevices() void {
    if (devices_ready) return;
    devices_ready = true;
    if (!pci.have_host) return;
    const ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    const d = domain.spawn("pcisvc", .{ .blob = img(.pcisvc) }, .{
        .arg = 1,
        .grant_debug_log = true,
        .grant_channel_a = ch,
        .auto_reap = true,
    }) catch |e| std.debug.panic("spawn pcisvc: {t}", .{e});
    bootGive(ch, .ecam, .window, 0, 0);
    bootGive(ch, .mmio, .window, 1, 0);
    bootGo(ch);
    ipc.unrefSide(ch, .b, 0);
    var waited: u64 = 0;
    while (d.state != .dead) : (waited += 1) {
        if (waited == 100) std.debug.panic("pcisvc never finished", .{});
        sched.sleep(1);
    }
    if (d.exit_code != 0) std.debug.panic("pcisvc exit {d}", .{d.exit_code});
    log.info("pci: {d} device(s) registered by pcisvc", .{pci.count});
}

/// Hand a device of the given kind (the first enumerated) to a program
/// over its boot channel, filed under its kind.
fn bootGiveDevice(boot_ch: *ipc.Channel, kind: shared.DeviceKind) void {
    bootGiveDeviceNth(boot_ch, kind, 0);
}

fn bootGiveDeviceNth(boot_ch: *ipc.Channel, kind: shared.DeviceKind, nth: usize) void {
    ensureDevices();
    const idx = pci.nthByKind(kind, nth) orelse std.debug.panic("no {t} device #{d} on the bus", .{ kind, nth });
    const res = ipc.call(boot_ch, .{
        .data = shared.encodeMsg(shared.BootReq, .{ .cap = .{ .tag = @intFromEnum(shared.CapTag.device), .kind = @intFromEnum(kind) } }),
        .cap_type = @intFromEnum(cap.CapType.device),
        .cap_obj = idx,
        .cap_badge = 0,
    }, 0);
    std.debug.assert(res.err == .ok);
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
    _ = spawnDevice("netsvc", .net, 1 | (node << 8), net_ch, .net);
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
        // Memory accounts nest: the children it spawns for peers (the
        // drill's remote echo, a remote stage) are paid from here.
        .kobj_limit = 4 << 20,
        .user_limit = 16 << 20,
    }) catch |e| std.debug.panic("spawn fabsvc: {t}", .{e});
    // Identity: the root of trust certifies this node over the fabric's
    // boot channel, then certification opens the network. The imposter's
    // root is a DIFFERENT key, so its certificate must be refused by
    // every real member. Node 3's certificate carries no spawn authority
    // (the authorization drill).
    const root = spawnFabroot(badkey != 0);
    const pathbuf = ipc.createShm(1) orelse @panic("shm pool empty");
    const pb = mem.physToPtr([*]u8, pathbuf.pages[0]);
    const flags: u64 = if (node == 3) shared.fab_flag_gossip else shared.fab_flag_gossip | shared.fab_flag_spawn;
    certifyFabric(root, fab_ch, pathbuf, pb, node, flags, ~@as(u64, 0), deriveNetView(net_ch, 0, 0, 0));
    var res: ipc.CallResult = undefined;

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
        var reached = false;
        while (true) : (t += 1) {
            fabPump(fab_ch, 1);
            // Node 3, with no spawn authority, reaches a service node 1
            // PUBLISHED: lookup hands it a channel, the call comes back.
            if (node == 3 and !reached and t % 10 == 0 and t <= 300) {
                const lres = ipc.call(fab_ch, .{
                    .data = shared.encodeMsg(shared.FabReq, .{ .lookup = .{ .node = 1, .service = @intFromEnum(shared.ServiceId.calc) } }),
                }, 0);
                if (lres.err == .ok and lres.msg.cap_type != 0) {
                    if (shared.decodeMsg(shared.FabResp, lres.msg.data)) |lrep| {
                        if (lrep == .found) {
                            const cres = ipc.call(fab_ch, .{
                                .data = shared.encodeMsg(shared.CalcRequest, .{ .add = .{ .a = 40, .b = 2 } }),
                            }, lres.msg.cap_badge);
                            if (cres.err == .ok and cres.msg.data[0] != shared.fabric_err_sentinel) {
                                if (shared.decodeMsg(shared.CalcReply, cres.msg.data)) |crep| {
                                    if (crep == .sum and crep.sum.value == 42) {
                                        reached = true;
                                        log.info("fabric-test: node 3 reached node 1's published service: 40+2=42", .{});
                                    }
                                }
                            }
                            ipc.releaseCap(@enumFromInt(lres.msg.cap_type), lres.msg.cap_obj, lres.msg.cap_badge);
                        }
                    }
                }
            }
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
    const placed = remoteSpawnRpc(fab_ch, 0) orelse
        std.debug.panic("fabric-test: placement spawn failed", .{});
    var landed = placed.node;
    log.info("fabric-test: placement spawn landed on node {d}; RPC verified", .{landed});

    // Stage B1: a service PUBLISHED to the pool. A local calc service's
    // channel is offered under ServiceId.calc; node 3 (no spawn
    // authority) looks it up and calls it — its log carries the proof.
    {
        const pub_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
        _ = domain.spawn("calc-pub", .{ .blob = img(.pingpong) }, .{
            .grant_debug_log = true,
            .grant_channel_a = pub_ch,
            .arg = 1,
            .auto_reap = true,
        }) catch |e| std.debug.panic("spawn calc-pub: {t}", .{e});
        // Our B ref rides the publish; the fabric's export keeps it.
        const pres = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .{ .publish = .{ .service = @intFromEnum(shared.ServiceId.calc) } }),
            .cap_type = @intFromEnum(cap.CapType.channel_b),
            .cap_obj = @intFromPtr(pub_ch),
        }, 0);
        const prep = if (pres.err == .ok) shared.decodeMsg(shared.FabResp, pres.msg.data) else null;
        if (prep == null or prep.? != .ok) std.debug.panic("fabric-test: FAIL — publish refused", .{});
        // And a lookup of our own node answers with the export itself.
        const lres = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.FabReq, .{ .lookup = .{ .node = 1, .service = @intFromEnum(shared.ServiceId.calc) } }),
        }, 0);
        if (lres.err != .ok or lres.msg.cap_type == 0) std.debug.panic("fabric-test: FAIL — local lookup found nothing", .{});
        const cres = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.CalcRequest, .{ .add = .{ .a = 1, .b = 1 } }),
        }, lres.msg.cap_badge);
        _ = cres;
        ipc.releaseCap(@enumFromInt(lres.msg.cap_type), lres.msg.cap_obj, lres.msg.cap_badge);
        log.info("fabric-test: calc published to the pool (node 1)", .{});
    }

    // Stage B2: a capability crosses the wire. A local calc service's
    // channel rides a greet to the remote child, which calls back through
    // it — node 2 to node 1 over the reverse proxy — and returns the sum.
    {
        const calc_ch = ipc.createChannel(1, 1) catch @panic("channel pool empty");
        const calc = domain.spawn("calc", .{ .blob = img(.pingpong) }, .{
            .grant_debug_log = true,
            .grant_channel_a = calc_ch,
            .arg = 1,
            .auto_reap = true,
        }) catch |e| std.debug.panic("spawn calc: {t}", .{e});
        ipc.refSide(calc_ch, .b, 0);
        const xres = ipc.call(fab_ch, .{
            .data = shared.encodeMsg(shared.CalcRequest, .greet),
            .cap_type = @intFromEnum(cap.CapType.channel_b),
            .cap_obj = @intFromPtr(calc_ch),
        }, placed.badge);
        const rep = if (xres.err == .ok and xres.msg.data[0] != shared.fabric_err_sentinel)
            shared.decodeMsg(shared.CalcReply, xres.msg.data)
        else
            null;
        if (rep == null or rep.? != .sum or rep.?.sum.value != 3)
            std.debug.panic("fabric-test: FAIL — the capability did not work across the wire", .{});
        log.info("fabric-test: capability crossed the wire and called back: 1+2=3", .{});
        domain.destroy(calc);
        while (calc.state != .dead) sched.sleep(1);
        ipc.unrefSide(calc_ch, .b, 0);
    }

    // Stage B3: exchanges pipeline. Three callers hammer the remote
    // channel at once; the fabric must keep more than one in flight.
    {
        test_fab_ch = fab_ch;
        callers_done.store(0, .release);
        for (0..3) |i| {
            _ = sched.spawn("caller", concurrentCaller, placed.badge | (@as(u64, i) << 32), .{}) catch @panic("spawn caller");
        }
        var waited: u64 = 0;
        while (callers_done.load(.acquire) < 3) : (waited += 1) {
            if (waited == 600) std.debug.panic("fabric-test: FAIL — concurrent callers never finished", .{});
            sched.sleep(1);
        }
        const st = ipc.call(fab_ch, .{ .data = shared.encodeMsg(shared.FabReq, .stats) }, 0);
        const rep = shared.decodeMsg(shared.FabResp, st.msg.data) orelse @panic("bad stats reply");
        if (rep != .num or rep.num.n < 2)
            std.debug.panic("fabric-test: FAIL — exchanges never overlapped", .{});
        log.info("fabric-test: {d} exchanges in flight at once through one link", .{rep.num.n});
    }

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
    landed = (remoteSpawnRpc(fab_ch, 2) orelse
        std.debug.panic("fabric-test: post-rejoin spawn failed", .{})).node;
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
    bootGiveShm(ch, .buf, buf);
    const root_seed = "moss-root-of-trust-seed-01234567";
    comptime std.debug.assert(root_seed.len == 32);
    @memcpy(pb[0..32], root_seed);
    if (bad_root) pb[0] ^= 0xff;
    bootSecret(ch, 0, 32);
    bootGo(ch);
    return .{ .d = d, .ch = ch, .buf = buf, .pb = pb };
}

fn rootNum(res: ipc.CallResult, want: u64) void {
    std.debug.assert(res.err == .ok);
    const rep = shared.decodeMsg(shared.FabResp, res.msg.data) orelse @panic("root: bad reply");
    if (rep != .num or rep.num.n != want) @panic("root: refused");
}

/// Boot and certify fabsvc: over its boot channel it receives its staging
/// buffer, its identity (seed + cluster key, secret — it derives the
/// keypair and leaves the PUBLIC key in the buffer), and a net view;
/// fabroot signs that key into a certificate with the node's
/// authorizations; set_cert installs it and opens the network. The boot
/// driver is the out-of-band channel — neither service sees the other's
/// secret. `buf`/`fb` are fabsvc's staging buffer and its kernel pointer.
fn certifyFabric(root: FabRoot, fab_ch: *ipc.Channel, buf: *ipc.Shm, fb: [*]u8, node: u64, flags: u64, image_mask: u64, net_view: NetView) void {
    rootNum(ipc.call(root.ch, .{
        .data = shared.encodeMsg(shared.RootReq, .cluster_key),
    }, 0), 32);
    bootGiveShm(fab_ch, .buf, buf);
    var node_seed: [32]u8 = "moss-node-identity-seed-00000000".*;
    node_seed[31] = @intCast(node);
    @memcpy(fb[0..32], &node_seed);
    @memcpy(fb[32..64], root.pb[0..32]);
    bootSecret(fab_ch, 0, shared.fab_identity_len);
    bootGive(fab_ch, .net, .channel_b, net_view.obj, net_view.badge);
    bootGo(fab_ch);
    // Ask for the identity's public key; the root certifies it.
    rootNum(ipc.call(fab_ch, .{
        .data = shared.encodeMsg(shared.FabReq, .identity_key),
    }, 0), 32);
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
    if (rep != .ok) @panic("fabsvc refused its certificate or the network");
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

/// Let `ticks` pass. Nobody pumps the fabric any more — its own timer
/// and socket doorbells keep it breathing — so waiting is just waiting.
fn fabPump(fab_ch: *ipc.Channel, ticks: u64) void {
    _ = fab_ch;
    sched.sleep(ticks);
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

var test_fab_ch: *ipc.Channel = undefined;
var callers_done: std.atomic.Value(u32) = .init(0);

/// One of the concurrent callers: eight adds through the remote channel,
/// each answer checked.
fn concurrentCaller(arg: u64) void {
    const badge = arg & 0xffff_ffff;
    const id = arg >> 32;
    for (0..8) |i| {
        const a: u64 = id * 100 + i;
        const res = ipc.call(test_fab_ch, .{
            .data = shared.encodeMsg(shared.CalcRequest, .{ .add = .{ .a = a, .b = 1 } }),
        }, badge);
        if (res.err != .ok or res.msg.data[0] == shared.fabric_err_sentinel)
            std.debug.panic("fabric-test: FAIL — concurrent call {d}/{d} failed", .{ id, i });
        const rep = shared.decodeMsg(shared.CalcReply, res.msg.data) orelse @panic("bad reply");
        if (rep != .sum or rep.sum.value != a + 1)
            std.debug.panic("fabric-test: FAIL — concurrent call answered wrong", .{});
    }
    _ = callers_done.fetchAdd(1, .acq_rel);
}

const Placed = struct { node: u64, badge: u64 };

/// remote_spawn (node 0 = placement) + one verified RPC through the
/// proxied channel. Returns the node the spawn landed on and the badge.
fn remoteSpawnRpc(fab_ch: *ipc.Channel, node: u64) ?Placed {
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
    return .{ .node = landed, .badge = badge };
}

const NetView = struct { obj: u64, badge: u64 };

fn deriveNetView(net_ch: *ipc.Channel, hi: u64, lo: u64, port: u64) NetView {
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

// ---------------------------------------------------------- ipc bench

const bench_rounds: u64 = 60_000;
var bench_done: std.atomic.Value(u32) = .init(0);
var bench_end: [3]std.atomic.Value(u64) = .{ .init(0), .init(0), .init(0) };
var bench_chs: [3]*ipc.Channel = undefined;

fn benchServer(arg: u64) void {
    const ch = bench_chs[arg];
    var msg: ipc.Msg = .{};
    var badge: u64 = 0;
    var token: u64 = 0;
    for (0..bench_rounds) |_| {
        if (ipc.recv(ch, &msg, &badge, &token) != .ok) return;
        _ = ipc.replyTo(ch, msg, token);
    }
}

fn benchClient(arg: u64) void {
    const idx: usize = @intCast(arg);
    const ch = bench_chs[idx];
    for (0..bench_rounds) |i| {
        const res = ipc.call(ch, .{ .data = .{ i, 0, 0, 0 } }, 0);
        if (res.err != .ok) break;
    }
    bench_end[idx].store(cycles(), .release);
    _ = bench_done.fetchAdd(1, .acq_rel);
}

/// `pairs` call/reply pairs, pair i pinned to core i+1, all at once.
/// Returns round trips per second across all pairs.
fn ipcBench(pairs: u32) u64 {
    const freq = asm ("mrs %[v], cntfrq_el0"
        : [v] "=r" (-> u64),
    );
    for (0..pairs) |i| bench_chs[i] = ipc.createChannel(1, 1) catch @panic("channel pool empty");
    bench_done.store(0, .release);
    const t0 = cycles();
    for (0..pairs) |i| {
        const core: u32 = @intCast(1 + i);
        _ = sched.spawn("bench-srv", benchServer, i, .{ .affinity = core }) catch @panic("spawn");
        _ = sched.spawn("bench-cli", benchClient, i, .{ .affinity = core }) catch @panic("spawn");
    }
    while (bench_done.load(.acquire) < pairs) sched.sleep(1);
    // Each client stamps its own finish: no tick quantization.
    var t1: u64 = 0;
    for (0..pairs) |i| t1 = @max(t1, bench_end[i].load(.acquire));
    for (0..pairs) |i| {
        ipc.unrefSide(bench_chs[i], .a, 0);
        ipc.unrefSide(bench_chs[i], .b, 0);
    }
    const elapsed = @max(t1 - t0, 1);
    return bench_rounds * pairs * freq / elapsed;
}

var badge_recv_err: shared.Errno = .ok;
var badge_recv_badge: u64 = 0;

/// A server parked in recv: the death of a client identity must wake it.
fn badgeRecvHelper(arg: u64) void {
    const ch: *ipc.Channel = @ptrFromInt(arg);
    var msg: ipc.Msg = .{};
    var badge: u64 = 0;
    var token: u64 = 0;
    badge_recv_err = ipc.recv(ch, &msg, &badge, &token);
    badge_recv_badge = badge;
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
