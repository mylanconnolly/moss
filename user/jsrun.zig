//! The script domain: where a JavaScript program runs. Spawned by a host
//! with a single capability — a badged calling end of the host's
//! channel — it asks the host for its data buffer, finds the source
//! there, runs it with the engine in `lib/js` over a static heap, sends
//! each `print` line back through the same buffer and finally reports
//! the completion value or the uncaught exception. It holds no
//! filesystem, no network and no clock; a script gets exactly what its
//! domain holds, which is nothing but this channel. When its heap runs
//! out it says so and dies, and the host sees a dead client.
const std = @import("std");
const shared = @import("shared");
const mosslib = @import("mosslib");
const usys = @import("usys.zig");
const js = mosslib.js;
const wire = shared.js;
const Vm = js.vm.Vm;
const Value = js.value.Value;

comptime {
    asm (usys.imageHeaderStack("jsrun", 128));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    var line: [240]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&line, "jsrun: panic: {s} (at 0x{x})", .{ msg, ret_addr orelse 0 }) catch "jsrun: panic");
    var fp: usize = @frameAddress();
    var depth: usize = 0;
    while (fp != 0 and depth < 12) : (depth += 1) {
        const frame: *const [2]usize = @ptrFromInt(fp);
        _ = usys.log(glog, std.fmt.bufPrint(&line, "  frame {d}: 0x{x}", .{ depth, frame[1] }) catch "?");
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
    usys.exit(255);
}

var glog: u64 = 0;
var host: u64 = 0;
var data: [*]u8 = undefined;
var data_len: usize = 0;

/// The engine's heap: every JavaScript value lives here.
var region: [8 << 20]u8 align(16) = undefined;
/// The engine's bookkeeping (shapes, atoms, the register stack, the
/// compiler's scratch): a bump heap for now, which frees only its last
/// block — enough for a script's run, and the residual the design
/// notes name.
var meta_buf: [12 << 20]u8 align(16) = undefined;
var meta_fba: std.heap.FixedBufferAllocator = undefined;
var vm: Vm = undefined;

fn call(req: wire.RunReq) wire.HostResp {
    return switch (usys.callTyped(wire.RunReq, wire.HostResp, host, req, 0)) {
        .ok => |rep| rep,
        .err => usys.exit(0), // the host is gone: so are we
    };
}

fn attach() []const u8 {
    const d = switch (usys.callTypedCap(wire.RunReq, wire.HostResp, host, .attach_data, 0)) {
        .ok => |ok| ok,
        .err => usys.exit(0),
    };
    if (d.rep != .data_buf or d.cap == 0) {
        _ = usys.log(glog, "jsrun: no data buffer from the host");
        usys.exit(3);
    }
    const dm = usys.shmMap(d.cap);
    _ = usys.capDrop(d.cap);
    if (dm.err != .ok) usys.exit(3);
    data = @ptrFromInt(dm.data[0]);
    data_len = dm.data[1] * 4096;
    return data[0..@min(d.rep.data_buf.len, data_len)];
}

/// Text to the host through the data buffer, cut to what fits.
fn sendText(comptime req: enum { output, done }, ok: bool, text: []const u8) void {
    const n = @min(text.len, data_len);
    @memcpy(data[0..n], text[0..n]);
    _ = switch (req) {
        .output => call(.{ .output = .{ .len = n } }),
        .done => call(.{ .done = .{ .ok = if (ok) 1 else 0, .len = n } }),
    };
}

/// `print(...)`: the arguments' strings joined by spaces, one line.
fn print(v: *Vm, _: Value, args: []const Value, _: Value) js.vm.Error!Value {
    var line: std.ArrayList(u8) = .empty;
    defer line.deinit(v.meta);
    for (args, 0..) |a, i| {
        if (i > 0) try line.append(v.meta, ' ');
        const s = try v.toString(a);
        const u = try v.utf8(s, v.meta);
        defer v.meta.free(u);
        try line.appendSlice(v.meta, u);
    }
    sendText(.output, true, line.items);
    return Value.undefined_;
}

fn exceptionText(a: std.mem.Allocator) []const u8 {
    const s = vm.toString(vm.exception) catch return "uncaught exception";
    return vm.utf8(s, a) catch "uncaught exception";
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, _: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    host = chan_h;
    if (arg != wire.run_arg) {
        _ = usys.log(glog, "jsrun: spawned without a host to serve");
        usys.exit(2);
    }
    meta_fba = std.heap.FixedBufferAllocator.init(&meta_buf);
    const meta = meta_fba.allocator();
    // The source is copied out of the shared buffer: the engine keeps
    // slices of it (a function's text) and the buffer is about to carry
    // the output.
    const in_buf = attach();
    const src = meta.dupe(u8, in_buf) catch usys.exit(5);
    vm.init(&region, meta) catch {
        _ = usys.log(glog, "jsrun: the engine did not fit its heap");
        usys.exit(5);
    };
    _ = vm.defineNative(vm.global, "print", 1, print) catch usys.exit(5);
    _ = usys.log(glog, "jsrun: up");
    const code = js.compiler.compile(meta, &vm.heap, &vm.strings, src, .{ .name = "script" }) catch |e| switch (e) {
        error.OutOfMemory => {
            _ = usys.log(glog, "jsrun: out of memory compiling");
            usys.exit(5);
        },
        error.SyntaxError => {
            var line: [512]u8 = undefined;
            sendText(.done, false, std.fmt.bufPrint(&line, "SyntaxError: {s}", .{js.compiler.last_error}) catch "SyntaxError");
            usys.exit(0);
        },
    };
    const result = js.interp.runScript(&vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| switch (e) {
        error.OutOfMemory => {
            _ = usys.log(glog, "jsrun: out of memory running");
            usys.exit(5);
        },
        error.Exception => {
            sendText(.done, false, exceptionText(meta));
            usys.exit(0);
        },
    };
    vm.runJobs() catch {};
    const text = blk: {
        const s = vm.toString(result) catch break :blk "";
        break :blk vm.utf8(s, meta) catch "";
    };
    sendText(.done, true, text);
    usys.exit(0);
}
