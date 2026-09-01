//! Boot/panic logger over the PL011. Formats into a fixed stack buffer so it
//! works with no allocator and inside the panic path. A spinlock keeps lines
//! from different cores whole; never call while holding the scheduler lock.

const std = @import("std");
const lock = @import("lock.zig");
const pl011 = @import("driver/pl011.zig");

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

pub fn log(level: Level, comptime fmt: []const u8, args: anytype) void {
    print("[{s}] " ++ fmt ++ "\n", .{level.tag()} ++ args);
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
    const daif = lk.lockIrqSave();
    defer lk.unlockRestore(daif);
    pl011.write(line);
}
