const std = @import("std");
const builtin = @import("builtin");

pub fn build(b: *std.Build) void {
    const optimize = b.standardOptimizeOption(.{});
    const host_target = b.standardTargetOptions(.{});
    // User programs default to ReleaseSafe: the FS/crypto hot paths live
    // in userspace and Debug costs them ~2-5x, while ReleaseSafe keeps
    // every bounds/overflow check. The kernel follows -Doptimize (Debug
    // by default) — it has no hot loops that matter yet.
    // check: `-Dsoak=N` runs every OS test N times (intermittent failures
    // surface under repetition); `-Donly=a,b` runs only those tests (the
    // `+rs` rows are the ReleaseSafe kernel pass, e.g. `ipc+rs`).
    const soak = b.option(u32, "soak", "check: run each OS test this many times") orelse 1;
    const only = b.option([]const u8, "only", "check: run only these OS tests (comma-separated; `name+rs` = ReleaseSafe pass)");
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
    const guest_test = b.option(
        bool,
        "guest-test",
        "Run the guest drill: a userspace VMM boots a moss kernel as an EL1 guest",
    ) orelse false;
    const cpu_test = b.option(
        bool,
        "cpu-test",
        "Run the CPU drill: budgets throttle a domain to its share, a partition keeps a core to one domain",
    ) orelse false;
    const pan_test = b.option(
        bool,
        "pan-test",
        "Run the PAN drill: a syscall touches user memory outside a uaccess window and must fault",
    ) orelse false;
    const vmnode_test = b.option(
        bool,
        "vmnode-test",
        "Run the pool-node drill: a moss guest with passed-through devices joins the fabric as node 2",
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
    const users_test = b.option(
        bool,
        "users-test",
        "Run the users drill: key identities, passphrase-unlocked sessions as domains, isolated homes, layered settings",
    ) orelse false;
    const login_test = b.option(
        bool,
        "login-test",
        "Run the login drill: two users log in on two consoles at once, each session an init instance with msh on its home",
    ) orelse false;
    const flogin_test = b.option(
        bool,
        "flogin-test",
        "Run the fabric-login drill: a login on node 2 with the user's record on node 1 (pair with profile=flogin node=1 / profile=fjoin node=2)",
    ) orelse false;
    const rng_test = b.option(
        bool,
        "rng-test",
        "Run the entropy drill: virtio-rng driver seeds the kernel pool; getrandom fail-closed + policed",
    ) orelse false;

    // The architecture: one port under kernel/arch/<arch>/ selected at
    // comptime by kernel/arch.zig from the target; nothing of another
    // port is compiled. aarch64 is the first target (ROADMAP.md).
    const arch = b.option(std.Target.Cpu.Arch, "arch", "target architecture (aarch64, x86_64)") orelse .aarch64;
    if (arch != .aarch64 and arch != .x86_64) std.debug.panic("moss has no port for {s}", .{@tagName(arch)});
    const linker_script = b.path(b.fmt("kernel/arch/{s}/linker.ld", .{@tagName(arch)}));
    // The kernel never touches FP/SIMD outside the scheduler's
    // hand-written save/restore stubs, so compiled kernel code must not
    // use those registers (no vector state on kernel paths). aarch64:
    // strict_align is NOT needed — all Zig code runs with the MMU on
    // (boot.zig enables it before kmain); only pre-MMU code, which is all
    // hand-written, aligned assembly, would fault on unaligned access to
    // Device-typed memory. The el2vmsa feature is assembler vocabulary for
    // the EL2 host (VTTBR/VTCR/HPFAR, the VMALLS12 invalidations); code
    // generation is unaffected. x86_64: no x87/SSE/AVX in the kernel,
    // soft float, FSGSBASE for the per-core pointer.
    const kernel_target = b.resolveTargetQuery(switch (arch) {
        .aarch64 => .{
            .cpu_arch = .aarch64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_features_sub = std.Target.aarch64.featureSet(&.{ .fp_armv8, .neon }),
            .cpu_features_add = std.Target.aarch64.featureSet(&.{.el2vmsa}),
        },
        .x86_64 => .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_features_sub = std.Target.x86.featureSet(&.{ .x87, .mmx, .sse, .sse2, .sse3, .ssse3, .sse4_1, .sse4_2, .avx, .avx2, .fma, .f16c }),
            .cpu_features_add = std.Target.x86.featureSet(&.{ .soft_float, .fsgsbase }),
        },
        else => unreachable,
    });
    // x86_64 links in the top 2 GB (the "kernel" model) and must not use
    // the red zone (interrupts land on the current stack).
    const kernel_code_model: std.builtin.CodeModel = if (arch == .x86_64) .kernel else .small;
    const kernel_red_zone: ?bool = if (arch == .x86_64) false else null;

    // Userspace gets the vector unit: trap.init sets CPACR_EL1.FPEN and
    // the scheduler saves/restores per-thread FP state, so user programs
    // build with NEON plus the AES instructions (hardware AES-XTS in
    // std.crypto; QEMU's cortex-a72 and HVF's host CPU both provide them).
    // (x86_64: SSE2 baseline plus AES; user programs are not yet built
    // for it — the runtime's syscall stubs are aarch64.)
    const user_target = b.resolveTargetQuery(switch (arch) {
        .aarch64 => .{
            .cpu_arch = .aarch64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_features_add = std.Target.aarch64.featureSet(&.{.aes}),
        },
        .x86_64 => .{
            .cpu_arch = .x86_64,
            .os_tag = .freestanding,
            .abi = .none,
            .cpu_features_add = std.Target.x86.featureSet(&.{.aes}),
        },
        else => unreachable,
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
    build_opts.addOption(bool, "guest_test", guest_test);
    build_opts.addOption(bool, "vmnode_test", vmnode_test);
    build_opts.addOption(bool, "pan_test", pan_test);
    build_opts.addOption(bool, "cpu_test", cpu_test);
    build_opts.addOption(bool, "guest_kernel", false);
    build_opts.addOption(bool, "fs_test", fs_test);
    build_opts.addOption(bool, "net_test", net_test);
    build_opts.addOption(bool, "fabric_test", fabric_test);
    build_opts.addOption(bool, "shell_test", shell_test);
    build_opts.addOption(bool, "rng_test", rng_test);
    build_opts.addOption(bool, "users_test", users_test);
    build_opts.addOption(bool, "login_test", login_test);
    build_opts.addOption(bool, "flogin_test", flogin_test);

    const kernel_mod = b.createModule(.{
        .root_source_file = b.path("kernel/main.zig"),
        .target = kernel_target,
        .optimize = optimize,
        .code_model = kernel_code_model,
        .red_zone = kernel_red_zone,
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
        .{ .name = "pcisvc", .src = "user/pcisvc.zig" },
        .{ .name = "users", .src = "user/users.zig" },
        .{ .name = "mshrun", .src = "user/mshrun.zig" },
    };
    // The boot archive is packed at build time by tools/mkmarc from the
    // program images plus the literal boot files below, laid out per the
    // standard hierarchy (identity in etc/, boot config in conf/, images
    // in img/).

    // The mshl tools: mshfmt, mshlint and mshls, on the tree-sitter grammar's
    // generated parser and the tree-sitter runtime the host provides
    // (`brew install tree-sitter`; -Dtree-sitter=PREFIX elsewhere). Their
    // own steps and tests, outside the gate: host tooling, not the OS.
    // `fmt-test` checks every .msh under boot/ is formatted; `lint-test`
    // that every one lints clean; `ls-test` is the server's own tests.
    // The runtime's prefix: Homebrew's on macOS, the system's elsewhere;
    // the static archive when the prefix has one, else the shared library
    // the linker finds under that prefix (a distro's libtree-sitter.so).
    const ts_prefix = b.option([]const u8, "tree-sitter", "prefix of the tree-sitter runtime (include/, lib/)") orelse
        (if (builtin.os.tag == .macos) "/opt/homebrew/opt/tree-sitter" else "/usr");
    const ts_static = b.fmt("{s}/lib/libtree-sitter.a", .{ts_prefix});
    const ts_have_static = if (std.Io.Dir.cwd().access(b.graph.io, ts_static, .{})) true else |_| false;
    {
        const tree_mod = b.createModule(.{
            .root_source_file = b.path("tools/mshtree.zig"),
            .target = host_target,
            .optimize = .Debug,
            .link_libc = true,
        });
        tree_mod.addIncludePath(.{ .cwd_relative = b.fmt("{s}/include", .{ts_prefix}) });
        tree_mod.addCSourceFile(.{ .file = b.path("tools/tree-sitter-mshl/src/parser.c"), .flags = &.{"-std=c11"} });
        tree_mod.addIncludePath(b.path("tools/tree-sitter-mshl/src"));
        if (ts_have_static) {
            tree_mod.addObjectFile(.{ .cwd_relative = ts_static });
        } else {
            tree_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib", .{ts_prefix}) });
            tree_mod.addLibraryPath(.{ .cwd_relative = b.fmt("{s}/lib64", .{ts_prefix}) });
            tree_mod.linkSystemLibrary("tree-sitter", .{});
        }
        const mshl_mod = b.createModule(.{ .root_source_file = b.path("lib/mshl.zig"), .target = host_target, .optimize = .Debug });
        const toolModule = struct {
            fn make(bb: *std.Build, name: []const u8, tgt: std.Build.ResolvedTarget, imports: []const std.Build.Module.Import) *std.Build.Module {
                return bb.createModule(.{
                    .root_source_file = bb.path(bb.fmt("tools/{s}.zig", .{name})),
                    .target = tgt,
                    .optimize = .Debug,
                    .link_libc = true,
                    .imports = imports,
                });
            }
        }.make;
        const base_imports = [_]std.Build.Module.Import{ .{ .name = "mshtree", .module = tree_mod }, .{ .name = "mshl", .module = mshl_mod } };
        const fmt_mod = toolModule(b, "mshfmt", host_target, &base_imports);
        const lint_mod = toolModule(b, "mshlint", host_target, &base_imports);
        const ls_mod = toolModule(b, "mshls", host_target, &(base_imports ++ [_]std.Build.Module.Import{ .{ .name = "mshfmt", .module = fmt_mod }, .{ .name = "mshlint", .module = lint_mod } }));
        const Tool = struct { name: []const u8, mod: *std.Build.Module, step: []const u8, test_step: []const u8, over_tree: ?[]const []const u8, what: []const u8 };
        for ([_]Tool{
            .{ .name = "mshfmt", .mod = fmt_mod, .step = "fmt", .test_step = "fmt-test", .over_tree = &.{"--check"}, .what = "the mshl formatter" },
            .{ .name = "mshlint", .mod = lint_mod, .step = "lint", .test_step = "lint-test", .over_tree = &.{}, .what = "the mshl lint" },
            .{ .name = "mshls", .mod = ls_mod, .step = "ls", .test_step = "ls-test", .over_tree = null, .what = "the mshl language server" },
        }) |t| {
            const exe = b.addExecutable(.{ .name = t.name, .root_module = t.mod });
            const step = b.step(t.step, b.fmt("build {s}, {s} (needs the tree-sitter runtime)", .{ t.name, t.what }));
            step.dependOn(&b.addInstallArtifact(exe, .{}).step);
            const tests = b.addTest(.{ .root_module = t.mod });
            const test_step = b.step(t.test_step, if (t.over_tree != null) b.fmt("{s}'s own tests, then {s} over every .msh under boot/", .{ t.name, t.name }) else b.fmt("{s}'s own tests", .{t.name}));
            test_step.dependOn(&b.addRunArtifact(tests).step);
            if (t.over_tree) |args| {
                const over_tree = b.addRunArtifact(exe);
                over_tree.addArgs(args);
                for (mshFiles(b)) |f| over_tree.addFileArg(b.path(f));
                test_step.dependOn(&over_tree.step);
            }
        }
    }

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
    // The guest kernel's archive: the same tree minus the guest kernel
    // itself (which the host archive carries as img/moss-guest).
    const pack_guest = b.addRunArtifact(mkmarc);
    const marc_guest_out = pack_guest.addOutputFileArg("bootfs-guest.marc");
    // The boot tree: boot/ in the repo, laid out as the archive serves it
    // (etc/ identity, conf/ boot configuration: unit files under
    // conf/units/, test key material beside them).
    for ([_][]const u8{
        "etc/motd",                      "etc/version",
        "conf/fs.key",                   "conf/fabric/root.seed",
        "conf/units/rngd.msh",           "conf/units/blk.msh",
        "conf/units/fs.msh",             "conf/units/net.msh",
        "conf/units/fabroot.msh",        "conf/units/fabsvc.msh",
        "conf/units/cons.msh",           "conf/units/msh.msh",
        "conf/units/logsvc.msh",         "conf/units/greeter.msh",
        "conf/units/ps.msh",             "conf/units/ls.msh",
        "conf/units/net-cluster.msh",    "conf/units/blk-drill.msh",
        "conf/units/fs-alice.msh",       "conf/units/fs-bob.msh",
        "conf/units/fs-churn.msh",       "conf/units/fs-churn2.msh",
        "conf/units/net-echosrv.msh",    "conf/units/net-echocli.msh",
        "conf/units/net-boxed.msh",      "conf/msh/startup.msh",
        "conf/units/guest-hello.msh",    "conf/units/usersvc.msh",
        "conf/units/apply.msh",          "conf/units/users-drill.msh",
        "conf/system.msh",               "conf/units/cons1.msh",
        "conf/units/usersvc-login.msh",  "conf/session/msh.msh",
        "conf/units/usersvc-flogin.msh", "conf/units/usersvc-fjoin.msh",
        "conf/units/mshrun.msh",         "conf/units/script-hello.msh",
        "scripts/hello.msh",             "conf/units/net-script.msh",
        "scripts/net-drill.msh",         "conf/units/fab-script.msh",
        "scripts/fab-drill.msh",
    }) |f| {
        pack.addPrefixedFileArg(b.fmt("{s}=", .{f}), b.path(b.fmt("boot/{s}", .{f})));
        pack_guest.addPrefixedFileArg(b.fmt("{s}=", .{f}), b.path(b.fmt("boot/{s}", .{f})));
    }

    const user_blobs = b.addWriteFiles();
    // The programs, the guest and the guest kernel are aarch64 until the
    // userspace runtime has its own port seam; an x86_64 build packs the
    // boot files alone (the kernel embeds the archive either way).
    if (arch == .aarch64) for (user_progs) |p| {
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
        pack_guest.addPrefixedFileArg(b.fmt("img/{s}=", .{p.name}), prog_bin.getOutput());
    };
    // A guest: bare-metal EL1 code the VMM loads into a VM's RAM. Raw
    // binary, linked at the guest's RAM base, no MOSS header.
    if (arch == .aarch64) {
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
        pack_guest.addPrefixedFileArg("img/guest-hello=", guest_bin.getOutput());

        // The guest kernel: this very kernel, built to boot the guest profile
        // and report, embedding the guest archive; the host archive carries
        // its raw Image as img/moss-guest for the VMM to load.
        const guest_blobs = b.addWriteFiles();
        _ = guest_blobs.addCopyFile(marc_guest_out, "bootfs.marc");
        const guest_blobs_src = guest_blobs.add("user_blobs.zig", "pub const bootfs = @embedFile(\"bootfs.marc\");\n");
        const gopts = b.addOptions();
        for ([_][]const u8{
            "panic_test", "fault_test",  "sched_test",   "domain_test",
            "ipc_test",   "init_test",   "sandbox_test", "flap_test",
            "blk_test",   "fs_test",     "net_test",     "fabric_test",
            "shell_test", "rng_test",    "smmu_test",    "vm_test",
            "guest_test", "vmnode_test", "pan_test",     "cpu_test",
            "users_test", "login_test",  "flogin_test",
        }) |on| gopts.addOption(bool, on, false);
        gopts.addOption(bool, "guest_kernel", true);
        const gmod = b.createModule(.{
            .root_source_file = b.path("kernel/main.zig"),
            .target = kernel_target,
            .optimize = optimize,
            .code_model = .small,
        });
        gmod.addImport("shared", shared_mod);
        gmod.addOptions("build_options", gopts);
        gmod.addAnonymousImport("user_blobs", .{ .root_source_file = guest_blobs_src });
        const gkernel = b.addExecutable(.{ .name = "moss-guest.elf", .root_module = gmod });
        gkernel.setLinkerScript(linker_script);
        const gkernel_bin = b.addObjCopy(gkernel.getEmittedBin(), .{ .format = .bin, .basename = "moss-guest.bin" });
        pack.addPrefixedFileArg("img/moss-guest=", gkernel_bin.getOutput());
    }

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
        // The self-hosted x86_64 backend assumes SSE; the kernel is built
        // without it, by LLVM.
        .use_llvm = if (arch == .x86_64) true else null,
    });
    kernel.setLinkerScript(linker_script);
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

    const run_step = b.step("run", "Boot the kernel in QEMU (aarch64: TCG; x86_64: OVMF + Limine, KVM when there). Ctrl-A X exits.");
    if (arch == .aarch64) {
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
        run_step.dependOn(&run_qemu.step);
    } else {
        // UEFI boot: OVMF from the host's QEMU (the code flash read-only,
        // a scratch copy of the variable store), Limine's BOOTX64.EFI
        // beside the kernel ELF and a limine.conf in a directory QEMU
        // exposes as a FAT volume on virtio-blk. No disk image tooling.
        const share = if (builtin.os.tag == .macos) "/opt/homebrew/share" else "/usr/share";
        const limine_dir = b.option([]const u8, "limine", "directory holding Limine's BOOTX64.EFI") orelse b.fmt("{s}/limine", .{share});
        const ovmf_code = b.option([]const u8, "ovmf", "the x86_64 OVMF code flash image") orelse b.fmt("{s}/qemu/edk2-x86_64-code.fd", .{share});
        const ovmf_vars = b.option([]const u8, "ovmf-vars", "the OVMF variable store template") orelse b.fmt("{s}/qemu/edk2-i386-vars.fd", .{share});
        const esp = b.addWriteFiles();
        _ = esp.addCopyFile(kernel.getEmittedBin(), "moss-kernel.elf");
        _ = esp.addCopyFile(.{ .cwd_relative = b.fmt("{s}/BOOTX64.EFI", .{limine_dir}) }, "EFI/BOOT/BOOTX64.EFI");
        _ = esp.add("limine.conf", "timeout: 0\nserial: yes\n\n/moss\n    protocol: limine\n    path: boot():/moss-kernel.elf\n    cmdline: profile=system\n");
        const vars = b.addWriteFiles();
        const vars_fd = vars.addCopyFile(.{ .cwd_relative = ovmf_vars }, "vars.fd");
        const run_x86 = b.addSystemCommand(&.{
            "qemu-system-x86_64",
            "-machine",
            "q35",
            "-accel",
            "kvm",
            "-accel",
            "tcg",
            "-cpu",
            "max",
        });
        run_x86.addArgs(&qemu_common);
        run_x86.addArgs(&.{ "-drive", b.fmt("if=pflash,format=raw,readonly=on,file={s}", .{ovmf_code}) });
        run_x86.addArg("-drive");
        run_x86.addPrefixedFileArg("if=pflash,format=raw,file=", vars_fd);
        run_x86.addArg("-drive");
        run_x86.addPrefixedDirectoryArg("format=raw,readonly=on,if=virtio,file=fat:ro:", esp.getDirectory());
        run_step.dependOn(&run_x86.step);
    }

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

    // run-login: the multi-user boot. Seat 0 is your terminal, seat 1 a
    // TCP console (`nc 127.0.0.1 31905`); log in as alice / alice-pass or
    // bob / bob-pass (the drill's records, written at boot).
    const run_login = b.addSystemCommand(&.{
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
        "-device",
        "virtio-serial-pci,disable-legacy=on,iommu_platform=on",
        "-chardev",
        "socket,id=c1,host=127.0.0.1,port=31905,server=on,wait=off",
        "-device",
        "virtconsole,chardev=c1",
        "-display",
        "none",
        "-serial",
        "file:zig-out/login-kernel.log",
        "-smp",
        "4",
        "-m",
        "512M",
        "-append",
        "profile=login",
    });
    run_login.step.dependOn(&mkdisk_sh.step);
    const run_login_step = b.step("run-login", "Multi-user boot: a login prompt on your terminal and on a TCP console at 127.0.0.1:31905 (kernel log: zig-out/login-kernel.log).");
    run_login_step.dependOn(&run_login.step);

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
    if (soak > 1) run_check.addArgs(&.{ "--repeat", b.fmt("{d}", .{soak}) });
    if (only) |o| run_check.addArgs(&.{ "--only", o });

    const all_test_opts = [_][]const u8{
        "panic_test", "fault_test",  "sched_test",   "domain_test",
        "ipc_test",   "init_test",   "sandbox_test", "flap_test",
        "blk_test",   "fs_test",     "net_test",     "fabric_test",
        "shell_test", "rng_test",    "smmu_test",    "vm_test",
        "guest_test", "vmnode_test", "pan_test",     "cpu_test",
        "users_test", "login_test",  "flogin_test",
    };
    const variants = [_][]const u8{
        "panic",   "fault", "sched", "domain", "ipc",    "init",
        "sandbox", "flap",  "blk",   "fs",     "net",    "fabric",
        "shell",   "rng",   "smmu",  "vm",     "guest",  "vmnode",
        "pan",     "cpu",   "users", "login",  "flogin",
    };
    // The same drills once more under a ReleaseSafe kernel (the `+rs`
    // rows): the optimizer reorders and merges what a Debug build leaves
    // in source order, so a race or a non-volatile register read shows up
    // here and nowhere else. The kernel-heavy drills, kept short.
    const release_variants = [_][]const u8{
        "sched", "domain", "ipc", "sandbox", "fs", "users",
    };
    const Variant = struct {
        fn add(
            bb: *std.Build,
            run: *std.Build.Step.Run,
            vn: []const u8,
            label: []const u8,
            opt: std.builtin.OptimizeMode,
            target: std.Build.ResolvedTarget,
            shared: *std.Build.Module,
            blobs: std.Build.LazyPath,
            test_opts: []const []const u8,
            script: std.Build.LazyPath,
        ) std.Build.LazyPath {
            const vopts = bb.addOptions();
            const enabled = bb.fmt("{s}_test", .{vn});
            for (test_opts) |on| {
                vopts.addOption(bool, on, std.mem.eql(u8, on, enabled));
            }
            vopts.addOption(bool, "guest_kernel", false);
            const vmod = bb.createModule(.{
                .root_source_file = bb.path("kernel/main.zig"),
                .target = target,
                .optimize = opt,
                .code_model = .small,
            });
            vmod.addImport("shared", shared);
            vmod.addOptions("build_options", vopts);
            vmod.addAnonymousImport("user_blobs", .{ .root_source_file = blobs });
            const vexe = bb.addExecutable(.{
                .name = bb.fmt("moss-check-{s}.elf", .{label}),
                .root_module = vmod,
            });
            vexe.setLinkerScript(script);
            const vbin = bb.addObjCopy(vexe.getEmittedBin(), .{
                .format = .bin,
                .basename = bb.fmt("moss-check-{s}.bin", .{label}),
            });
            run.addArg(label);
            run.addFileArg(vbin.getOutput());
            return vbin.getOutput();
        }
    };
    if (arch == .aarch64) for (variants) |vn| {
        const vbin = Variant.add(b, run_check, vn, vn, optimize, kernel_target, shared_mod, user_blobs_src, &all_test_opts, linker_script);
        // Plain `zig build run-shell` boots this variant — no flag needed.
        if (std.mem.eql(u8, vn, "shell")) {
            run_shell.addArg("-kernel");
            run_shell.addFileArg(vbin);
        }
        if (std.mem.eql(u8, vn, "login")) {
            run_login.addArg("-kernel");
            run_login.addFileArg(vbin);
        }
    };
    if (arch == .aarch64) for (release_variants) |vn| {
        _ = Variant.add(b, run_check, vn, b.fmt("{s}+rs", .{vn}), .ReleaseSafe, kernel_target, shared_mod, user_blobs_src, &all_test_opts, linker_script);
    };
    // The gate is aarch64's until the x86_64 port has drills of its own.
    const check_step = b.step("check", "Run the full OS test suite in QEMU (plus host unit tests; aarch64)");
    check_step.dependOn(test_step);
    if (arch == .aarch64) check_step.dependOn(&run_check.step);
}

/// Every .msh file under boot/, sorted, as build-root-relative paths.
fn mshFiles(b: *std.Build) []const []const u8 {
    const io = b.graph.io;
    var found: std.ArrayList([]const u8) = .empty;
    var dir = b.build_root.handle.openDir(io, "boot", .{ .iterate = true }) catch @panic("boot/ missing");
    defer dir.close(io);
    var walker = dir.walk(b.allocator) catch @panic("OOM");
    defer walker.deinit();
    while (walker.next(io) catch @panic("walking boot/")) |e| {
        if (e.kind != .file or !std.mem.endsWith(u8, e.basename, ".msh")) continue;
        found.append(b.allocator, b.fmt("boot/{s}", .{e.path})) catch @panic("OOM");
    }
    std.mem.sort([]const u8, found.items, {}, struct {
        fn lt(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.lessThan(u8, x, y);
        }
    }.lt);
    return found.items;
}
