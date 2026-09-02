const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});
    // User programs default to ReleaseSafe: the FS/crypto hot paths live
    // in userspace and Debug costs them ~2-5x, while ReleaseSafe keeps
    // every bounds/overflow check. The kernel follows -Doptimize (Debug
    // by default) — it has no hot loops that matter yet.
    const user_optimize = b.option(
        std.builtin.OptimizeMode,
        "user-optimize",
        "Optimize mode for user programs (default ReleaseSafe)",
    ) orelse .ReleaseSafe;
    const panic_test = b.option(
        bool,
        "panic-test",
        "Panic after boot to exercise the panic handler",
    ) orelse false;
    const fault_test = b.option(
        bool,
        "fault-test",
        "Read unmapped memory after boot to exercise fault reporting",
    ) orelse false;
    const sched_test = b.option(
        bool,
        "sched-test",
        "Run pinned + migrating threads across all cores after boot",
    ) orelse false;
    const domain_test = b.option(
        bool,
        "domain-test",
        "Spawn, revoke, and leak-check user domains after boot",
    ) orelse false;
    const ipc_test = b.option(
        bool,
        "ipc-test",
        "Run the IPC demo: typed RPC, cap grants, fault-as-message, peer death",
    ) orelse false;
    const init_test = b.option(
        bool,
        "init-test",
        "Boot the userspace root/init tree: lazy activation, supervised restarts, re-wiring",
    ) orelse false;
    const sandbox_test = b.option(
        bool,
        "sandbox-test",
        "Run the sandbox demo: interposition proxy, nested domains, subtree revocation, benchmarks",
    ) orelse false;
    const flap_test = b.option(
        bool,
        "flap-test",
        "Run the supervision-restart drill: budget exhaustion escalates up the tree",
    ) orelse false;
    const vm_test = b.option(
        bool,
        "vm-test",
        "Run the VM drill: a userspace VMM runs a bare-metal EL1 guest in a stage-2 world",
    ) orelse false;
    const smmu_test = b.option(
        bool,
        "smmu-test",
        "Run the IOMMU drill: the block drill through the SMMU, then a rogue DMA refused",
    ) orelse false;
    const blk_test = b.option(
        bool,
        "blk-test",
        "Run the virtio-blk demo (use with zig build run-blk, which attaches a disk)",
    ) orelse false;
    const fs_test = b.option(
        bool,
        "fs-test",
        "Run the filesystem demo: per-process namespace views on real storage (use run-blk)",
    ) orelse false;
    const net_test = b.option(
        bool,
        "net-test",
        "Run the networking demo: dual-stack TCP + allowlist views (use run-net)",
    ) orelse false;
    const fabric_test = b.option(
        bool,
        "fabric-test",
        "Run the multi-node fabric demo (use run-cluster)",
    ) orelse false;
    const shell_test = b.option(
        bool,
        "shell-test",
        "Boot the developer shell topology (use run-shell for a live console)",
    ) orelse false;
    const rng_test = b.option(
        bool,
        "rng-test",
        "Run the entropy drill: virtio-rng driver seeds the kernel pool; getrandom fail-closed + policed",
    ) orelse false;

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        // The kernel never touches FP/SIMD outside the scheduler's
        // hand-written save/restore stubs, so compiled kernel code must
        // not use those registers (no vector state on kernel paths).
        // strict_align is NOT needed: all Zig code runs with the MMU on
        // (boot.zig enables it before kmain); only pre-MMU code — which is
        // all hand-written, aligned assembly — would fault on unaligned
        // access to Device-typed memory.
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon }),
        // Assembler vocabulary for the EL2 host: the stage-2 registers
        // (VTTBR/VTCR/HPFAR, the VMALLS12 invalidations) sit behind this
        // feature; code generation is unaffected.
        .cpu_features_add = std.Target.aarch64.featureSet(&.{.el2vmsa}),
    });

    // Userspace gets the vector unit: trap.init sets CPACR_EL1.FPEN and
    // the scheduler saves/restores per-thread FP state, so user programs
    // build with NEON plus the AES instructions (hardware AES-XTS in
    // std.crypto; QEMU's cortex-a72 and HVF's host CPU both provide them).
    const user_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        .cpu_features_add = std.Target.aarch64.featureSet(&.{.aes}),
    });

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("shared/lib.zig"),
    });

    // Static libraries (lib/): pure freestanding-safe modules — the locked
    // code-sharing model (no dynamic loader).
    const lib_mod = b.createModule(.{
        .root_source_file = b.path("lib/lib.zig"),
    });

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "panic_test", panic_test);
    build_opts.addOption(bool, "fault_test", fault_test);
    build_opts.addOption(bool, "sched_test", sched_test);
    build_opts.addOption(bool, "domain_test", domain_test);
    build_opts.addOption(bool, "ipc_test", ipc_test);
    build_opts.addOption(bool, "init_test", init_test);
    build_opts.addOption(bool, "sandbox_test", sandbox_test);
    build_opts.addOption(bool, "flap_test", flap_test);
    build_opts.addOption(bool, "blk_test", blk_test);
    build_opts.addOption(bool, "smmu_test", smmu_test);
    build_opts.addOption(bool, "vm_test", vm_test);
    build_opts.addOption(bool, "fs_test", fs_test);
    build_opts.addOption(bool, "net_test", net_test);
    build_opts.addOption(bool, "fabric_test", fabric_test);
    build_opts.addOption(bool, "shell_test", shell_test);
    build_opts.addOption(bool, "rng_test", rng_test);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
    });
    kernel_mod.addImport("shared", shared_mod);
    kernel_mod.addOptions("build_options", build_opts);

    // User programs: freestanding flat MOSS images. Each becomes an
    // img/<name> entry of the boot archive (the ONE blob the kernel embeds);
    // the kernel holds no image table, so nothing here is order-coupled —
    // a program is listed here and in the shared.ImageId catalog, by name.
    const user_progs = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "hello", .src = "user/hello.zig" },
        .{ .name = "pingpong", .src = "user/pingpong.zig" },
        .{ .name = "root", .src = "user/root.zig" },
        .{ .name = "init", .src = "user/init.zig" },
        .{ .name = "services", .src = "user/services.zig" },
        .{ .name = "sandbox", .src = "user/sandbox.zig" },
        .{ .name = "blk", .src = "user/blk.zig" },
        .{ .name = "fs", .src = "user/fs.zig" },
        .{ .name = "net", .src = "user/net.zig" },
        .{ .name = "fabric", .src = "user/fabric.zig" },
        .{ .name = "cons", .src = "user/cons.zig" },
        .{ .name = "shell", .src = "user/shell.zig" },
        .{ .name = "rng", .src = "user/rng.zig" },
        .{ .name = "ps", .src = "user/ps.zig" },
        .{ .name = "ls", .src = "user/ls.zig" },
        .{ .name = "vmm", .src = "user/vmm.zig" },
    };
    // The boot archive is packed at build time by tools/mkmarc from the
    // program images plus the literal boot files below, laid out per the
    // standard hierarchy (identity in etc/, boot config in conf/, images
    // in img/).
    const mkmarc = b.addExecutable(.{
        .name = "mkmarc",
        .root_module = b.createModule(.{
            .root_source_file = b.path("tools/mkmarc.zig"),
            .target = host_target,
            .optimize = .Debug,
        }),
    });
    const pack = b.addRunArtifact(mkmarc);
    const marc_out = pack.addOutputFileArg("bootfs.marc");
    // The boot tree: boot/ in the repo, laid out as the archive serves it
    // (etc/ identity, conf/ boot configuration: unit files under
    // conf/units/, test key material beside them).
    for ([_][]const u8{
        "etc/motd",                   "etc/version",
        "conf/fs.key",                "conf/fabric/root.seed",
        "conf/units/rngd.msh",        "conf/units/blk.msh",
        "conf/units/fs.msh",          "conf/units/net.msh",
        "conf/units/fabroot.msh",     "conf/units/fabsvc.msh",
        "conf/units/cons.msh",        "conf/units/msh.msh",
        "conf/units/logsvc.msh",      "conf/units/greeter.msh",
        "conf/units/ps.msh",          "conf/units/ls.msh",
        "conf/units/net-cluster.msh", "conf/units/blk-drill.msh",
        "conf/units/fs-alice.msh",    "conf/units/fs-bob.msh",
        "conf/units/net-echosrv.msh", "conf/units/net-echocli.msh",
        "conf/units/net-boxed.msh",   "conf/msh/startup.msh",
    }) |f| {
        pack.addPrefixedFileArg(b.fmt("{s}=", .{f}), b.path(b.fmt("boot/{s}", .{f})));
    }

    const user_blobs = b.addWriteFiles();
    for (user_progs) |p| {
        const prog_mod = b.createModule(.{
            .root_source_file = b.path(p.src),
            .target = user_target,
            .optimize = user_optimize,
            .code_model = .small,
        });
        prog_mod.addImport("shared", shared_mod);
        prog_mod.addImport("mosslib", lib_mod);
        const prog = b.addExecutable(.{
            .name = b.fmt("{s}.elf", .{p.name}),
            .root_module = prog_mod,
        });
        prog.setLinkerScript(b.path("user/user.ld"));
        prog.entry = .{ .symbol_name = "_ustart" };
        const prog_bin = b.addObjCopy(prog.getEmittedBin(), .{
            .format = .bin,
            .basename = b.fmt("{s}.bin", .{p.name}),
        });
        pack.addPrefixedFileArg(b.fmt("img/{s}=", .{p.name}), prog_bin.getOutput());
    }
    // A guest: bare-metal EL1 code the VMM loads into a VM's RAM. Raw
    // binary, linked at the guest's RAM base, no MOSS header.
    const guest_mod = b.createModule(.{
        .root_source_file = b.path("guest/hello.zig"),
        .target = user_target,
        .optimize = .ReleaseSmall,
        .code_model = .small,
    });
    const guest = b.addExecutable(.{ .name = "guest-hello.elf", .root_module = guest_mod });
    guest.setLinkerScript(b.path("guest/guest.ld"));
    guest.entry = .{ .symbol_name = "_start" };
    const guest_bin = b.addObjCopy(guest.getEmittedBin(), .{ .format = .bin, .basename = "guest-hello.bin" });
    pack.addPrefixedFileArg("img/guest-hello=", guest_bin.getOutput());

    _ = user_blobs.addCopyFile(marc_out, "bootfs.marc");
    const user_blobs_src = user_blobs.add(
        "user_blobs.zig",
        "pub const bootfs = @embedFile(\"bootfs.marc\");\n",
    );
    kernel_mod.addAnonymousImport("user_blobs", .{
        .root_source_file = user_blobs_src,
    });

    const kernel = b.addExecutable(.{
        .name = "moss-kernel.elf",
        .root_module = kernel_mod,
    });
    kernel.setLinkerScript(b.path("kernel/linker.ld"));
    b.installArtifact(kernel);

    // QEMU virt only provides a DTB for Linux-boot-protocol payloads, so the
    // bootable artifact is the raw arm64 Image; the ELF is kept for symbols.
    const kernel_bin = b.addObjCopy(kernel.getEmittedBin(), .{
        .format = .bin,
        .basename = "moss-kernel.bin",
    });
    const install_bin = b.addInstallBinFile(kernel_bin.getOutput(), "moss-kernel.bin");
    b.getInstallStep().dependOn(&install_bin.step);

    // Every boot carries a virtio-rng: the entropy driver is part of the
    // base system (fabric handshakes refuse to run without it). Devices
    // are modern-only virtio over PCI (the SMMU sits in front of PCIe;
    // `-nic none` suppresses QEMU's stray default NIC).
    const qemu_common = [_][]const u8{
        "-smp",                                               "4",
        "-m",                                                 "512M",
        "-nographic",                                         "-nic",
        "none",                                               "-device",
        "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
    };

    const run_qemu = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,iommu=smmuv3,virtualization=on",
        "-cpu",
        "cortex-a76",
    });
    run_qemu.addArgs(&qemu_common);
    run_qemu.addArg("-kernel");
    run_qemu.addFileArg(kernel_bin.getOutput());
    const run_step = b.step("run", "Boot the kernel in QEMU (TCG). Ctrl-A X exits.");
    run_step.dependOn(&run_qemu.step);

    const run_hvf = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,iommu=smmuv3,accel=hvf",
        "-cpu",
        "host",
    });
    run_hvf.addArgs(&qemu_common);
    run_hvf.addArg("-kernel");
    run_hvf.addFileArg(kernel_bin.getOutput());
    const run_hvf_step = b.step("run-hvf", "Boot the kernel in QEMU with Hypervisor.framework acceleration.");
    run_hvf_step.dependOn(&run_hvf.step);

    // run-blk: like run, plus a scratch virtio disk (created if missing).
    const mkdisk = b.addSystemCommand(&.{
        "sh", "-c", "test -f zig-out/disk.img || dd if=/dev/zero of=zig-out/disk.img bs=1048576 count=4 2>/dev/null",
    });
    const run_blk = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,iommu=smmuv3,virtualization=on",
        "-cpu",
        "cortex-a76",
        "-drive",
        "if=none,file=zig-out/disk.img,format=raw,id=hd",
        "-device",
        "virtio-blk-pci,disable-legacy=on,iommu_platform=on,drive=hd",
    });
    run_blk.addArgs(&qemu_common);
    run_blk.addArg("-kernel");
    run_blk.addFileArg(kernel_bin.getOutput());
    run_blk.step.dependOn(&mkdisk.step);
    const run_blk_step = b.step("run-blk", "Boot with a virtio disk attached (pairs with -Dblk-test).");
    run_blk_step.dependOn(&run_blk.step);

    // run-shell: the interactive developer boot. YOUR TERMINAL IS MSH —
    // the virtio console rides stdio while the kernel log goes to a file.
    // Build with -Dshell-test (the same topology the scripted check uses).
    const mkdisk_sh = b.addSystemCommand(&.{
        "sh", "-c", "test -f zig-out/shell-disk.img || dd if=/dev/zero of=zig-out/shell-disk.img bs=1048576 count=8 2>/dev/null",
    });
    const run_shell = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,iommu=smmuv3,virtualization=on",
        "-cpu",
        "cortex-a76",
        "-drive",
        "if=none,file=zig-out/shell-disk.img,format=raw,id=hd",
        "-device",
        "virtio-blk-pci,disable-legacy=on,iommu_platform=on,drive=hd",
        "-nic",
        "none",
        "-device",
        "virtio-rng-pci,disable-legacy=on,iommu_platform=on",
        "-device",
        "virtio-serial-pci,disable-legacy=on,iommu_platform=on",
        "-chardev",
        "stdio,id=c0,signal=off",
        "-device",
        "virtconsole,chardev=c0",
        "-netdev",
        "user,id=un0",
        "-device",
        "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=un0",
        "-display",
        "none",
        "-serial",
        "file:zig-out/shell-kernel.log",
        "-smp",
        "4",
        "-m",
        "512M",
    });
    run_shell.step.dependOn(&mkdisk_sh.step);
    const run_shell_step = b.step("run-shell", "Interactive msh console on your terminal (kernel log: zig-out/shell-kernel.log; exit with the `exit` command).");
    run_shell_step.dependOn(&run_shell.step);

    // run-net: virtio-net over slirp (v4 + v6), with a guestfwd echo server
    // (cat) at 10.0.2.100:9000.
    const run_net = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,iommu=smmuv3,virtualization=on",
        "-cpu",
        "cortex-a76",
        "-netdev",
        "user,id=n0,guestfwd=tcp:10.0.2.100:9000-cmd:cat",
        "-device",
        "virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0",
    });
    run_net.addArgs(&qemu_common);
    run_net.addArg("-kernel");
    run_net.addFileArg(kernel_bin.getOutput());
    const run_net_step = b.step("run-net", "Boot with a virtio NIC on slirp (pairs with -Dnet-test).");
    run_net_step.dependOn(&run_net.step);

    // run-cluster: two nodes on a private Ethernet segment (socket netdev),
    // node ids via bootargs. Node 2 powers off mid-run (the kill drill);
    // node 1 reports the verdict and powers off too.
    const cluster = b.addSystemCommand(&.{ "sh", "-c" });
    cluster.addArg(b.fmt(
        \\set -e
        \\K={s}
        \\qemu-system-aarch64 -machine virt,gic-version=3,iommu=smmuv3,virtualization=on -cpu cortex-a76 -smp 4 -m 512M -display none \
        \\  -nic none -device virtio-rng-pci,disable-legacy=on,iommu_platform=on \
        \\  -netdev socket,id=n0,listen=127.0.0.1:31337 -device virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0 \
        \\  -append "node=1" -serial file:zig-out/cluster-node1.log -kernel "$K" &
        \\A=$!
        \\sleep 1
        \\qemu-system-aarch64 -machine virt,gic-version=3,iommu=smmuv3,virtualization=on -cpu cortex-a76 -smp 4 -m 512M -display none \
        \\  -nic none -device virtio-rng-pci,disable-legacy=on,iommu_platform=on \
        \\  -netdev socket,id=n0,connect=127.0.0.1:31337 -device virtio-net-pci,disable-legacy=on,iommu_platform=on,netdev=n0 \
        \\  -append "node=2" -serial file:zig-out/cluster-node2.log -kernel "$K" &
        \\B=$!
        \\wait $A $B || true
        \\echo "=== node 1 ==="; cat zig-out/cluster-node1.log
        \\echo "=== node 2 ==="; cat zig-out/cluster-node2.log
    , .{"zig-out/bin/moss-kernel.bin"}));
    cluster.step.dependOn(b.getInstallStep());
    const cluster_step = b.step("run-cluster", "Boot a 2-node cluster (pairs with -Dfabric-test).");
    cluster_step.dependOn(&cluster.step);

    const shared_test_mod = b.createModule(.{
        .root_source_file = b.path("shared/lib.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const shared_tests = b.addTest(.{ .root_module = shared_test_mod });
    const dt_test_mod = b.createModule(.{
        .root_source_file = b.path("kernel/dt.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const dt_tests = b.addTest(.{ .root_module = dt_test_mod });
    // Host baseline benchmarks (`zig build bench`): primitives + the
    // mossfs core over a RAM device, ReleaseFast. `bench-soft` strips the
    // CPU's AES feature to approximate today's no-NEON moss userspace.
    for ([_]struct { step: []const u8, soft: bool }{
        .{ .step = "bench", .soft = false },
        .{ .step = "bench-soft", .soft = true },
    }) |bv| {
        const btarget = if (bv.soft) b.resolveTargetQuery(.{
            .cpu_features_sub = std.Target.aarch64.featureSet(&.{.aes}),
        }) else b.resolveTargetQuery(.{});
        const blib = b.createModule(.{
            .root_source_file = b.path("lib/lib.zig"),
            .target = btarget,
            .optimize = .ReleaseFast,
        });
        const bfs = b.createModule(.{
            .root_source_file = b.path("user/mossfs.zig"),
            .target = btarget,
            .optimize = .ReleaseFast,
        });
        bfs.addImport("mosslib", blib);
        const bmod = b.createModule(.{
            .root_source_file = b.path("tools/bench.zig"),
            .target = btarget,
            .optimize = .ReleaseFast,
        });
        bmod.addImport("mosslib", blib);
        bmod.addImport("mossfs", bfs);
        const bexe = b.addExecutable(.{ .name = b.fmt("moss-{s}", .{bv.step}), .root_module = bmod });
        const brun = b.addRunArtifact(bexe);
        b.step(bv.step, if (bv.soft)
            "Host baselines with software AES (the pre-FP/SIMD reference point)"
        else
            "Host baselines (native AES)").dependOn(&brun.step);
    }

    const lib_test_mod = b.createModule(.{
        .root_source_file = b.path("lib/lib.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    const lib_tests = b.addTest(.{ .root_module = lib_test_mod });
    const mossfs_test_mod = b.createModule(.{
        .root_source_file = b.path("user/mossfs.zig"),
        .target = host_target,
        .optimize = optimize,
    });
    mossfs_test_mod.addImport("mosslib", lib_test_mod);
    const mossfs_tests = b.addTest(.{ .root_module = mossfs_test_mod });
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);
    test_step.dependOn(&b.addRunArtifact(dt_tests).step);
    test_step.dependOn(&b.addRunArtifact(lib_tests).step);
    test_step.dependOn(&b.addRunArtifact(mossfs_tests).step);

    // ------------------------------------------------------------- check
    // `zig build check`: one kernel variant per OS test (built in
    // parallel), then tools/runner.zig boots each under QEMU with the
    // right machine config and scores it by its serial markers. Tests
    // power themselves off after reporting, so runs are quick.
    const runner_mod = b.createModule(.{
        .root_source_file = b.path("tools/runner.zig"),
        .target = host_target,
        .optimize = .Debug,
    });
    const runner = b.addExecutable(.{ .name = "moss-check", .root_module = runner_mod });
    // Installed too, so one test can be run by hand:
    //   zig build -D<name>-test && zig-out/bin/moss-check <name> zig-out/bin/moss-kernel.bin
    b.installArtifact(runner);
    const run_check = b.addRunArtifact(runner);

    const all_test_opts = [_][]const u8{
        "panic_test", "fault_test", "sched_test",   "domain_test",
        "ipc_test",   "init_test",  "sandbox_test", "flap_test",
        "blk_test",   "fs_test",    "net_test",     "fabric_test",
        "shell_test", "rng_test",   "smmu_test",    "vm_test",
    };
    const variants = [_][]const u8{
        "panic",   "fault", "sched", "domain", "ipc", "init",
        "sandbox", "flap",  "blk",   "fs",     "net", "fabric",
        "shell",   "rng",   "smmu",  "vm",
    };
    for (variants) |vn| {
        const vopts = b.addOptions();
        const enabled = b.fmt("{s}_test", .{vn});
        for (all_test_opts) |on| {
            vopts.addOption(bool, on, std.mem.eql(u8, on, enabled));
        }
        const vmod = b.createModule(.{
            .root_source_file = b.path("kernel/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .small,
        });
        vmod.addImport("shared", shared_mod);
        vmod.addOptions("build_options", vopts);
        vmod.addAnonymousImport("user_blobs", .{ .root_source_file = user_blobs_src });
        const vexe = b.addExecutable(.{
            .name = b.fmt("moss-check-{s}.elf", .{vn}),
            .root_module = vmod,
        });
        vexe.setLinkerScript(b.path("kernel/linker.ld"));
        const vbin = b.addObjCopy(vexe.getEmittedBin(), .{
            .format = .bin,
            .basename = b.fmt("moss-check-{s}.bin", .{vn}),
        });
        run_check.addArg(vn);
        run_check.addFileArg(vbin.getOutput());
        // Plain `zig build run-shell` boots this variant — no flag needed.
        if (std.mem.eql(u8, vn, "shell")) {
            run_shell.addArg("-kernel");
            run_shell.addFileArg(vbin.getOutput());
        }
    }
    const check_step = b.step("check", "Run the full OS test suite in QEMU (plus host unit tests)");
    check_step.dependOn(test_step);
    check_step.dependOn(&run_check.step);
}
