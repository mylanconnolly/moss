//! ps — a program that looks but cannot act. Run by msh in its own
//! domain with exactly: a log cap, its boot channel, and a read-only
//! introspect cap (slot 2: log → chan → introspect). No spawn authority
//! anywhere near it; the ledger is all it can reach.

const shared = @import("shared");
const usys = @import("usys.zig");
const tty = @import("tty.zig");
const boot = @import("boot.zig");

comptime {
    asm (
        \\.section .text.uhdr, "ax"
        \\.global __uhdr
        \\__uhdr:
        \\        .ascii  "MOSS"
        \\        .word   0
        \\        .quad   __utext_size
        \\        .quad   __uload_size
        \\        .quad   __umem_size
        \\        .ascii  "ps"
        \\        .space  14
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const introspect_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

export fn umain(_: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    tty.attach(&setup);
    var recs: [16 * shared.DomainRec.size]u8 = undefined;
    const r = usys.domainList(introspect_h, &recs);
    if (r.err != .ok) {
        tty.out("ps: introspection denied\r\n");
        usys.exit(1);
    }
    tty.domainTable(&recs, r.data[0]);
    var l: tty.Line = .{};
    _ = l.num(r.data[0]).str(" domains (seen through an introspect cap; no spawn authority held)");
    l.flush();
    usys.exit(0);
}
