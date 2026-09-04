//! mshrun — a script as a program. Runs the mshl script named by its
//! argument, read through the one view it was handed, with the shared
//! file commands as its host and nothing else: a script has exactly the
//! authority its manifest or unit file gives it. Under msh (`run mshrun
//! PATH`) it has the console and hands its last value back through
//! `out`; as a unit it logs what it renders and exits — 0, or 1 with
//! the error on the log.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const fscmds = @import("fscmds.zig");
const netcmds = @import("netcmds.zig");
const httpcmds = @import("httpcmds.zig");
const tty = @import("tty.zig");
const boot = @import("boot.zig");
const result = @import("result.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;

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
        \\        .ascii  "mshrun"
        \\        .space  10
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;
var view_chan: u64 = 0;
var view_buf: [*]u8 = undefined;
var has_console = false;

// The interpreter's memory: an arena for the whole run (a script is one
// evaluation, statement by statement) and a pool for what it binds.
var heap_line: [1 << 20]u8 = undefined;
var line_fba: std.heap.FixedBufferAllocator = undefined;
var box_pool: mosslib.pool.Pool(256, 2048) = .{};
var host_ctx: u8 = 0;
var fs_ctx = fscmds.Fs{ .resolve = resolve, .root = 0 };
var net: ?netcmds.Net = null;
/// The boot archive, when the manifest grants `bootfs`: scripts may be
/// read from it (a unit's `script:` path) even with no view at all.
var blob: []const u8 = "";

fn resolve(it: *mshl.Interp, path: []const u8) mshl.Error!fscmds.Target {
    if (view_chan == 0) return it.fail("no filesystem view was given to this script", .{});
    return .{ .chan = view_chan, .buf = view_buf, .path = path };
}

fn hostCall(_: *anyopaque, it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (try fscmds.call(&fs_ctx, it, name, args, input)) |v| return v;
    if (net) |*nt| {
        if (try netcmds.call(nt, it, name, args, input)) |v| return v;
        if (try httpcmds.call(nt, it, name, args, input)) |v| return v;
    }
    return null;
}

/// Rendered text goes to the console when there is one, else to the
/// log a line at a time.
fn emit(text: []const u8) void {
    if (has_console) {
        for (text) |c| {
            if (c == '\n') tty.out("\r\n") else tty.out(&[_]u8{c});
        }
        return;
    }
    var it = std.mem.splitScalar(u8, text, '\n');
    while (it.next()) |line| {
        if (line.len == 0) continue;
        var buf: [256]u8 = undefined;
        const pre = "mshrun: ";
        @memcpy(buf[0..pre.len], pre);
        const n = @min(line.len, buf.len - pre.len);
        @memcpy(buf[pre.len .. pre.len + n], line[0..n]);
        _ = usys.log(glog, buf[0 .. pre.len + n]);
    }
}

fn fail(what: []const u8, msg: []const u8) noreturn {
    var buf: [320]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ "mshrun: ", what, ": ", msg }) |part| {
        const k = @min(part.len, buf.len - n);
        @memcpy(buf[n .. n + k], part[0..k]);
        n += k;
    }
    if (has_console) {
        tty.out(buf[0..n]);
        tty.out("\r\n");
    } else _ = usys.log(glog, buf[0..n]);
    usys.exit(1);
}

export fn umain(log_h: u64, chan_h: u64, _: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    if (blob_va != 0) blob = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    const setup = boot.take(chan_h);
    has_console = setup.has(.console) and setup.has(.console_buf);
    if (has_console) tty.attach(&setup);
    if (setup.has(.view)) {
        view_chan = setup.cap(.view);
        view_buf = @ptrFromInt(fsc.attachBuf(view_chan).va);
        fs_ctx.root = view_chan;
    }
    if (setup.has(.net)) net = netcmds.Net.init(setup.cap(.net));
    const path = setup.arg();
    if (path.len == 0) fail("setup", "no script path given");

    line_fba = std.heap.FixedBufferAllocator.init(&heap_line);
    var interp = mshl.Interp.init(line_fba.allocator(), box_pool.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = hostCall });
    // The script: from the view, else from the boot archive.
    const text = if (view_chan != 0)
        fscmds.readFile(&fs_ctx, &interp, path) catch fail(path, interp.err_msg)
    else
        shared.marcFind(blob, path) orelse fail(path, "not in the boot archive (and no view was given)");

    // Every top-level statement's value is rendered as the prompt would
    // — for a human (the console, or the log). Given an `out`, the last
    // statement's value is the program's and the text is not made: a
    // program run by msh returns a value, like ls and ps.
    var out: std.ArrayList(u8) = .empty;
    const last = interp.evalScriptEach(text, &out, if (setup.has(.out)) null else emit) catch |e| {
        fail(path, switch (e) {
            error.OutOfMemory => "out of memory",
            error.Exit => "exit",
            else => interp.err_msg,
        });
    };
    if (setup.has(.out)) {
        var res = result.Result.init();
        if (last.isData() and !res.deliver(&setup, last)) fail(path, "the result does not fit the out buffer");
    }
    usys.exit(0);
}
