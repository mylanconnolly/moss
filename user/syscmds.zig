//! The few commands every mshl host has that belong to no service:
//! `sleep MS` (the host's ticks, rounded up to ten milliseconds) and
//! `now` (milliseconds since boot, from the cycle counter — a clock for
//! measuring, not a calendar).

const std = @import("std");
const usys = @import("usys.zig");
const mshl = @import("mosslib").mshl;
const Value = mshl.Value;

pub fn nowMs() i64 {
    const hz = usys.cycleHz();
    if (hz == 0) return 0;
    return @intCast(usys.cycles() / (hz / 1000));
}

/// null = not one of these.
pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value) mshl.Error!?Value {
    if (std.mem.eql(u8, name, "sleep")) {
        if (args.len != 1 or args[0] != .int or args[0].int < 0) return it.fail("sleep: milliseconds expected", .{});
        usys.sleep(@intCast(@divTrunc(args[0].int + 9, 10)));
        return .nothing;
    }
    if (std.mem.eql(u8, name, "now")) {
        if (args.len != 0) return it.fail("now: takes no arguments", .{});
        return .{ .int = nowMs() };
    }
    return null;
}

pub const command_names = [_][]const u8{ "sleep", "now" };
