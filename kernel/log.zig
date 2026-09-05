//! Boot/panic logger over the port's console (arch.console). Formats into a fixed stack buffer so it
//! works with no allocator and inside the panic path. A spinlock keeps lines
//! from different cores whole; never call while holding the scheduler lock.

const std = @import("std");
const lock = @import("lock.zig");
const arch = @import("arch.zig");
const clock = @import("clock.zig");
const shared = @import("shared");

var lk: lock.SpinLock = .{};

pub const Level = enum {
    debug,
    info,
    warn,
    err,

    fn tag(self: Level) []const u8 {
        return switch (self) {
            .debug => "debug",
            .info => "info ",
            .warn => "warn ",
            .err => "error",
        };
    }
};

/// A line's stamp: the wall clock (`03:14:22.123`) once it is known,
/// the counter's seconds since boot (`+12.345`) before that.
pub fn stamp(buf: []u8) []const u8 {
    const hz = arch.cpu.cycleHz();
    const up_ms: u64 = if (hz == 0) 0 else arch.cpu.cycles() / (hz / 1000);
    const c = clock.get();
    if (c.source != .none) return shared.civil.clockText(buf, c.boot_epoch_ms + up_ms);
    return std.fmt.bufPrint(buf, "+{d}.{d:0>3}", .{ up_ms / 1000, up_ms % 1000 }) catch buf[0..0];
}

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    var st: [16]u8 = undefined;
    print("{s} [{s}] " ++ fmt ++ "\n", .{ stamp(&st), level.tag() } ++ args);
}

pub fn debug(comptime fmt: []const u8, args: anytype) void {
    log(.debug, fmt, args);
}

pub fn info(comptime fmt: []const u8, args: anytype) void {
    log(.info, fmt, args);
}

pub fn warn(comptime fmt: []const u8, args: anytype) void {
    log(.warn, fmt, args);
}

pub fn err(comptime fmt: []const u8, args: anytype) void {
    log(.err, fmt, args);
}

pub fn print(comptime fmt: []const u8, args: anytype) void {
    var buf: [1024]u8 = undefined;
    const line = std.fmt.bufPrint(&buf, fmt, args) catch blk: {
        break :blk "<log line too long>\n";
    };
    const irqs = lk.lockIrqSave();
    defer lk.unlockRestore(irqs);
    arch.console.write(line);
}
