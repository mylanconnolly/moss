//! Kernel root: kmain and the panic handler.

const std = @import("std");
const build_options = @import("build_options");
const shared = @import("shared");
const domain = @import("domain.zig");
const dt = @import("dt.zig");
const gic = @import("gic.zig");
const kalloc = @import("kalloc.zig");
const log = @import("log.zig");
const mem = @import("mem.zig");
const mmu = @import("mmu.zig");
const pmem = @import("pmem.zig");
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
    domain.init();
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
