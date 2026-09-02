//! ls — lists the one directory it was handed. Run by msh in its own
//! domain with a log cap, its boot channel, and a read-only view whose
//! ROOT is the requested path: there is no way to name anything above
//! it, because no such name exists in this domain.

const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
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
        \\        .ascii  "ls"
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

export fn umain(_: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    tty.attach(&setup);
    if (!setup.has(.view)) {
        tty.out("ls: no view granted\r\n");
        usys.exit(1);
    }
    const b = fsc.attachBuf(setup.cap(.view));
    const buf: [*]u8 = @ptrFromInt(b.va);
    const n = fsc.fsList(setup.cap(.view), buf, "") orelse {
        tty.out("ls: cannot list the view\r\n");
        usys.exit(1);
    };
    if (n == 0) {
        tty.out("(empty)\r\n");
        usys.exit(0);
    }
    // Names arrive '\n'-separated; the console wants "\r\n".
    var l: tty.Line = .{};
    for (buf[0..n]) |c| {
        if (c == '\n') l.flush() else _ = l.str(&[_]u8{c});
    }
    if (l.n > 0) l.flush();
    usys.exit(0);
}
