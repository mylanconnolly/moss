const std = @import("std");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});
    const panic_test = b.option(
        bool,
        "panic-test",
        "Panic after boot to exercise the panic handler",
    ) orelse false;

    const kernel_target = b.resolveTargetQuery(.{
        .cpu_arch = .aarch64,
        .os_tag = .freestanding,
        .abi = .none,
        // CPACR_EL1 resets with FP/SIMD trapped at EL1 and the kernel never
        // saves vector state, so kernel code must not touch those registers.
        .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon }),
        // With the MMU off, EL1 treats all memory as Device memory, where
        // unaligned accesses fault; strict_align keeps codegen aligned until
        // the MMU comes up (Phase 1).
        .cpu_features_add = std.Target.aarch64.featureSet(&.{.strict_align}),
    });

    const shared_mod = b.createModule(.{
        .root_source_file = b.path("shared/lib.zig"),
    });

    const build_opts = b.addOptions();
    build_opts.addOption(bool, "panic_test", panic_test);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = .small,
    });
    kernel_mod.addImport("shared", shared_mod);
    kernel_mod.addOptions("build_options", build_opts);

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
        "-smp",        "1",
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
    const test_step = b.step("test", "Run host-side unit tests");
    test_step.dependOn(&b.addRunArtifact(shared_tests).step);
}
