const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});
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

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        // CPACR_EL1 resets with FP/SIMD trapped at EL1 and the kernel never
        // saves vector state, so kernel code must not touch those registers.
        // strict_align is NOT needed: all Zig code runs with the MMU on
        // (boot.zig enables it before kmain); only pre-MMU code — which is
        // all hand-written, aligned assembly — would fault on unaligned
        // access to Device-typed memory.
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon }),
    });

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("shared/lib.zig"),
    });

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "panic_test", panic_test);
    build_opts.addOption(bool, "fault_test", fault_test);
    build_opts.addOption(bool, "sched_test", sched_test);
    build_opts.addOption(bool, "domain_test", domain_test);
    build_opts.addOption(bool, "ipc_test", ipc_test);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
    });
    kernel_mod.addImport("shared", shared_mod);
    kernel_mod.addOptions("build_options", build_opts);

    // User programs: freestanding flat MOSS images, embedded in the kernel
    // until a filesystem exists (Phase 9).
    const user_progs = [_]struct { name: []const u8, src: []const u8 }{
        .{ .name = "hello", .src = "user/hello.zig" },
        .{ .name = "pingpong", .src = "user/pingpong.zig" },
    };
    const user_blobs = b.addWriteFiles();
    var blobs_zig: std.ArrayList(u8) = .empty;
    for (user_progs) |p| {
        const prog_mod = b.createModule(.{
            .root_source_file = b.path(p.src),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .small,
        });
        prog_mod.addImport("shared", shared_mod);
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
        _ = user_blobs.addCopyFile(prog_bin.getOutput(), b.fmt("{s}.bin", .{p.name}));
        blobs_zig.appendSlice(
            b.allocator,
            b.fmt("pub const {s} = @embedFile(\"{s}.bin\");\n", .{ p.name, p.name }),
        ) catch @panic("OOM");
    }
    const user_blobs_src = user_blobs.add("user_blobs.zig", blobs_zig.items);
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

    const qemu_common = [_][]const u8{
        "-smp",        "4",
        "-m",          "512M",
        "-nographic",
    };

    const run_qemu = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3",
        "-cpu",
        "cortex-a72",
    });
    run_qemu.addArgs(&qemu_common);
    run_qemu.addArg("-kernel");
    run_qemu.addFileArg(kernel_bin.getOutput());
    const run_step = b.step("run", "Boot the kernel in QEMU (TCG). Ctrl-A X exits.");
    run_step.dependOn(&run_qemu.step);

    const run_hvf = b.addSystemCommand(&.{
        "qemu-system-aarch64",
        "-machine",
        "virt,gic-version=3,accel=hvf",
        "-cpu",
        "host",
    });
    run_hvf.addArgs(&qemu_common);
    run_hvf.addArg("-kernel");
    run_hvf.addFileArg(kernel_bin.getOutput());
    const run_hvf_step = b.step("run-hvf", "Boot the kernel in QEMU with Hypervisor.framework acceleration.");
    run_hvf_step.dependOn(&run_hvf.step);

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
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);
    test_step.dependOn(&b.addRunArtifact(dt_tests).step);
}
