//! ls — lists the one directory it was handed. Run by msh in its own
//! domain with a log cap, its boot channel, and a read-only view whose
//! ROOT is the requested path: there is no way to name anything above
//! it, because no such name exists in this domain. Its result is a
//! name/type/size/mtime table handed back to msh as data.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const tty = @import("tty.zig");
const boot = @import("boot.zig");
const result = @import("result.zig");
const mshl = @import("mosslib").mshl;

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

pub const panic = std.debug.FullPanic(uPanic);

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
    const view = setup.cap(.view);
    const b = fsc.attachBuf(view);
    const buf: [*]u8 = @ptrFromInt(b.va);
    const n = fsc.fsList(view, buf, "") orelse {
        tty.out("ls: cannot list the view\r\n");
        usys.exit(1);
    };
    var res = result.Result.init();
    const a = res.allocator();
    const names = a.dupe(u8, buf[0..n]) catch usys.exit(2);
    var rows: std.ArrayList([]const mshl.Value) = .empty;
    var it = std.mem.splitScalar(u8, names, '\n');
    while (it.next()) |name| {
        if (name.len == 0) continue;
        const st = fsc.fsStat(view, buf, name) orelse continue;
        const row = a.alloc(mshl.Value, 4) catch usys.exit(2);
        row[0] = .{ .str = name };
        row[1] = .{ .str = switch (st.typ) {
            @intFromEnum(shared.FsType.file) => "file",
            @intFromEnum(shared.FsType.dir) => "dir",
            @intFromEnum(shared.FsType.symlink) => "symlink",
            else => "?",
        } };
        row[2] = .{ .int = @intCast(st.size) };
        row[3] = .{ .int = @intCast(st.mtime) };
        rows.append(a, row) catch usys.exit(2);
    }
    const cols = [_][]const u8{ "name", "type", "size", "mtime" };
    const table: mshl.Value = .{ .table = .{ .cols = &cols, .rows = rows.items } };
    if (!res.deliver(&setup, table)) {
        var text: std.ArrayList(u8) = .empty;
        mshl.render(table, a, &text) catch usys.exit(2);
        for (text.items) |c| {
            if (c == '\n') tty.out("\r\n") else tty.out(&[_]u8{c});
        }
    }
    usys.exit(0);
}
