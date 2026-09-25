//! The host `js` runner: `zig build js -- file.js [more.js...]` runs
//! each file as a script in one realm, with `print` on the global. An
//! uncaught exception prints and exits 1. `JS_DUMP=1` prints the
//! bytecode of each file before running it.
const std = @import("std");
const mosslib = @import("mosslib");
const js = mosslib.js;
const Vm = js.vm.Vm;
const Value = js.vm.Value;

var io: std.Io = undefined;

fn print(vm: *Vm, _: Value, args: []const Value, _: Value) js.vm.Error!Value {
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.meta);
    for (args, 0..) |a, i| {
        if (i > 0) try out.append(vm.meta, ' ');
        const s = try vm.toString(a);
        const u = try vm.utf8(s, vm.meta);
        defer vm.meta.free(u);
        try out.appendSlice(vm.meta, u);
    }
    std.debug.print("{s}\n", .{out.items});
    return Value.undefined_;
}

fn exceptionText(vm: *Vm, gpa: std.mem.Allocator) []const u8 {
    const s = vm.toString(vm.exception) catch return "?";
    return vm.utf8(s, gpa) catch "?";
}

/// Modules relative to the referrer's directory, or the working
/// directory; the name is the normalized path (one record per file).
fn hostLoad(vm: *Vm, referrer: ?[]const u8, specifier: []const u8) js.vm.Error!?js.module.Loaded {
    const gpa = vm.meta;
    var path: std.ArrayList(u8) = .empty;
    defer path.deinit(gpa);
    const relative = std.mem.startsWith(u8, specifier, "./") or std.mem.startsWith(u8, specifier, "../");
    if (relative and referrer != null) {
        const ref = referrer.?;
        if (std.mem.lastIndexOfScalar(u8, ref, '/')) |i| try path.appendSlice(gpa, ref[0..i]);
    }
    // Resolve the specifier's segments onto the directory.
    var it = std.mem.splitScalar(u8, specifier, '/');
    while (it.next()) |seg| {
        if (seg.len == 0 or std.mem.eql(u8, seg, ".")) continue;
        if (std.mem.eql(u8, seg, "..")) {
            if (std.mem.lastIndexOfScalar(u8, path.items, '/')) |i| path.shrinkRetainingCapacity(i) else path.clearRetainingCapacity();
            continue;
        }
        if (path.items.len > 0 or specifier[0] == '/') try path.append(gpa, '/');
        try path.appendSlice(gpa, seg);
    }
    const src = std.Io.Dir.cwd().readFileAlloc(io, path.items, gpa, .limited(64 << 20)) catch return null;
    return .{ .name = try gpa.dupe(u8, path.items), .source = src };
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const gpa = init.gpa;
    var args: std.ArrayList([]const u8) = .empty;
    var ait = std.process.Args.Iterator.init(init.minimal.args);
    while (ait.next()) |a| try args.append(gpa, try gpa.dupe(u8, a));
    if (args.items.len < 2) {
        std.debug.print("usage: js file.js [more.js...]\n", .{});
        return 2;
    }
    const region = try gpa.alloc(u8, 256 << 20);
    defer gpa.free(region);
    const vm = try gpa.create(Vm);
    defer gpa.destroy(vm);
    try vm.init(region, gpa);
    defer vm.deinit();
    _ = try vm.defineNative(vm.global, "print", 1, print);
    vm.host_load = hostLoad;
    vm.host_now = hostNow;
    const dump = std.c.getenv("JS_DUMP") != null;
    js.interp.trace_enabled = std.c.getenv("JS_TRACE") != null;
    vm.heap.stress = std.c.getenv("JS_GC_STRESS") != null;
    for (args.items[1..]) |path| {
        const src = std.Io.Dir.cwd().readFileAlloc(io, path, gpa, .limited(64 << 20)) catch |e| {
            std.debug.print("js: cannot read {s}: {s}\n", .{ path, @errorName(e) });
            return 1;
        };
        defer gpa.free(src);
        if (std.mem.endsWith(u8, path, ".mjs")) {
            const p = js.module.runEntry(vm, path, src) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Exception => {
                    std.debug.print("{s}: {s}\n", .{ path, exceptionText(vm, gpa) });
                    return 1;
                },
            };
            vm.runJobs() catch {};
            const pd = Vm.asObject(p).internal(js.vm.PromiseData);
            if (pd.state == 2) {
                vm.exception = pd.result;
                std.debug.print("{s}: uncaught {s}\n", .{ path, exceptionText(vm, gpa) });
                return 1;
            }
            continue;
        }
        const code = js.compiler.compile(gpa, &vm.heap, &vm.strings, src, .{ .name = path }) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => {
                std.debug.print("{s}: SyntaxError: {s} (at {d})\n", .{ path, js.compiler.last_error, js.compiler.last_error_at });
                return 1;
            },
        };
        if (dump) {
            var buf: [1 << 16]u8 = undefined;
            var w = std.Io.Writer.fixed(&buf);
            js.bytecode.dump(&w, code, &vm.strings, gpa) catch {};
            std.debug.print("{s}\n", .{w.buffered()});
        }
        _ = js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| switch (e) {
            error.OutOfMemory => {
                std.debug.print("{s}: out of memory\n", .{path});
                return 1;
            },
            error.Exception => {
                const s = vm.toString(vm.exception) catch null;
                const u = if (s) |ss| vm.utf8(ss, gpa) catch "?" else "?";
                std.debug.print("{s}: uncaught {s}\n", .{ path, u });
                return 1;
            },
        };
        vm.runJobs() catch {};
    }
    return 0;
}

fn hostNow() f64 {
    return @floatFromInt(@divTrunc(std.Io.Clock.real.now(io).nanoseconds, std.time.ns_per_ms));
}
