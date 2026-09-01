//! Kernel root: kmain and the panic handler.

const std = @import("std");
const build_options = @import("build_options");
const shared = @import("shared");
const log = @import("log.zig");

comptime {
    _ = @import("boot.zig");
}

pub const panic = std.debug.FullPanic(panicHandler);

const dtb_magic: u32 = 0xd00dfeed;

export fn kmain(dtb_pa: u64) noreturn {
    log.print("\nmoss {f} — aarch64 / qemu-virt\n\n", .{shared.version});

    log.info("core 0 up at EL{d}", .{currentEl()});

    // QEMU passes the DTB in x0 only for Linux-protocol (raw Image) boots;
    // for ELF loads x0 is 0 and the DTB sits at the base of RAM.
    const ram_base: u64 = 0x4000_0000;
    const candidates = [_]u64{ dtb_pa, ram_base };
    const dtb: ?u64 = for (candidates) |pa| {
        if (pa == 0) continue;
        const magic_be: *const volatile u32 = @ptrFromInt(pa);
        if (std.mem.bigToNative(u32, magic_be.*) == dtb_magic) break pa;
    } else null;
    if (dtb) |pa| {
        log.info("devicetree at 0x{x}", .{pa});
    } else {
        log.warn("no devicetree found (x0=0x{x})", .{dtb_pa});
    }

    if (build_options.panic_test) {
        @panic("panic test requested via -Dpanic-test");
    }

    log.info("boot complete; nothing more to do — halting", .{});
    halt();
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
