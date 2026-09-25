//! `js-run SOURCE`: a JavaScript program run the way a page's script
//! would run — in a script domain holding nothing but the channel to
//! this program, which is its host. The domain is spawned from the
//! store's `jsrun` image for the one run and destroyed after it. The
//! result is `{ value, lines }`: the completion value's text and the
//! `print` lines; an uncaught exception, a syntax error or a script
//! that dies of its heap is an error result carrying the reason.
const std = @import("std");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const Shape = mshl.Shape;
const jshost = @import("jshost.zig");
const progload = @import("progload.zig");
const loader = @import("loader.zig");
const fscmds = @import("fscmds.zig");

pub const command_names = [_][]const u8{"js-run"};

var spawner: u64 = 0;
var stores: []const ?fscmds.Store = &.{};
var log_h: u64 = 0;
var host: jshost.Host = undefined;
var host_ready = false;
var stage: ?loader.Stage = null;
var staged = false;

pub fn setup(spawner_cap: u64, s: []const ?fscmds.Store, log: u64) void {
    spawner = spawner_cap;
    stores = s;
    log_h = log;
}

const run_shape = blk: {
    const fields = [_]Shape.Field{
        .{ .key = "value", .shape = .string },
        .{ .key = "lines", .shape = .list },
    };
    break :blk Shape{ .record_of = &fields };
};
const run_result = mshl.resultShape(run_shape, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "js-run")) return .{ .params = &.{.{ .name = "source", .shape = .string }}, .ret = run_result };
    return null;
}

fn errResult(it: *mshl.Interp, comptime fmt: []const u8, args: anytype) mshl.Error!?Value {
    return try it.mkResult(false, .{ .str = try std.fmt.allocPrint(it.arena, fmt, args) });
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    _ = input;
    if (!std.mem.eql(u8, name, "js-run")) return null;
    if (args.len < 1 or args[0] != .str) return it.fail("js-run: the source is needed", .{});
    if (spawner == 0) return errResult(it, "js-run: this program holds no spawner", .{});
    if (!host_ready) {
        host.reset(log_h, spawner);
        if (!host.init()) return errResult(it, "js-run: out of channels", .{});
        host_ready = true;
    }
    if (stage == null) stage = loader.Stage.init(loader.Stage.default_pages) orelse return errResult(it, "js-run: no room to stage the script image", .{});
    if (!staged) {
        _ = progload.loadImage(it, "jsrun", stores, &stage.?) orelse return errResult(it, "js-run: the jsrun image is not in the store", .{});
        staged = true;
    }
    const r = host.run(stage.?.handle, args[0].str);
    switch (r.outcome) {
        .ok => {},
        .threw => return errResult(it, "js-run: uncaught {s}", .{r.text}),
        .dead => return errResult(it, "js-run: the script died", .{}),
        .refused => return errResult(it, "js-run: {s}", .{r.text}),
    }
    var lines: std.ArrayList(Value) = .empty;
    var it_lines = std.mem.splitScalar(u8, r.output, '\n');
    while (it_lines.next()) |line| {
        if (line.len == 0 and it_lines.peek() == null) break;
        try lines.append(it.arena, .{ .str = try it.arena.dupe(u8, line) });
    }
    const keys = try it.arena.dupe([]const u8, &.{ "value", "lines" });
    const vals = try it.arena.dupe(Value, &.{ .{ .str = try it.arena.dupe(u8, r.text) }, .{ .list = lines.items } });
    return try it.mkResult(true, .{ .record = .{ .keys = keys, .vals = vals } });
}
