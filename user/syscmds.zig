//! The few commands every mshl host has that belong to no service:
//! `sleep MS` (the kernel's ticks, rounded up to a tenth of a second), `now`
//! (milliseconds since boot, from the cycle counter — a clock for
//! measuring) and `date` (the wall clock the kernel keeps, as a record:
//! Unix seconds, ISO text, the calendar fields; an err until the system
//! knows the time).

const std = @import("std");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const civil = mosslib.civil;
const Value = mshl.Value;

/// What `date` answers.
pub const Date = struct {
    unix: i64,
    ms: i64,
    iso: []const u8,
    year: i64,
    month: i64,
    day: i64,
    hour: i64,
    minute: i64,
    second: i64,
    weekday: i64,
    source: enum { rtc, set },
};

pub fn nowMs() i64 {
    const hz = usys.cycleHz();
    if (hz == 0) return 0;
    return @intCast(usys.cycles() / (hz / 1000));
}

/// null = not one of these.
pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value) mshl.Error!?Value {
    if (std.mem.eql(u8, name, "sleep")) {
        if (args[0].int < 0) return it.fail("sleep: milliseconds expected", .{});
        usys.sleepMs(@intCast(args[0].int));
        return .nothing;
    }
    if (std.mem.eql(u8, name, "now")) {
        if (args.len != 0) return it.fail("now: takes no arguments", .{});
        return .{ .int = nowMs() };
    }
    if (std.mem.eql(u8, name, "date")) {
        const ms = usys.wallMs() orelse return try it.mkResult(false, .{ .str = "no_clock" });
        const secs: i64 = @intCast(ms / 1000);
        const c = civil.fromUnix(secs);
        var buf: [32]u8 = undefined;
        const iso = try it.arena.dupe(u8, civil.isoText(&buf, secs));
        return try it.mkResult(true, try mshl.toValue(it.arena, Date{
            .unix = secs,
            .ms = @intCast(ms),
            .iso = iso,
            .year = c.year,
            .month = c.month,
            .day = c.day,
            .hour = c.hour,
            .minute = c.minute,
            .second = c.second,
            .weekday = c.weekday,
            .source = if (usys.clockGet().source == .rtc) .rtc else .set,
        }));
    }
    return null;
}

pub const command_names = [_][]const u8{ "sleep", "now", "date" };

const date_result = mshl.resultShape(mshl.shapeOf(Date), .{ .word = "no_clock" });

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "sleep")) return .{ .params = &.{.{ .name = "ms", .shape = .int }}, .ret = .nothing };
    if (std.mem.eql(u8, name, "now")) return .{ .ret = .int };
    if (std.mem.eql(u8, name, "date")) return .{ .ret = date_result };
    return null;
}
