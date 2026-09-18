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
    for (line) |c| {
        ring[ring_head % ring_size] = c;
        ring_head += 1;
    }
}

// The recent log as bytes: every line printed, kernel's and domains',
// in a ring the `log_read` syscall copies out by offset — a log viewer's
// window onto the machine, without a second logging path. The offset is
// the count of bytes ever written, so a reader resumes where it left off
// and can tell when the ring has dropped what it had not read.
const ring_size = 128 << 10;
var ring: [ring_size]u8 = undefined;
var ring_head: u64 = 0;

pub const Read = struct { n: usize, start: u64, head: u64 };

/// Copy the log from offset `from` into `buf`: whole lines when more
/// remains after the buffer (the last partial line is left for the next
/// call), so a reader never splits one. `from` older than the ring holds
/// resumes at the first whole line kept.
pub fn read(from: u64, buf: []u8) Read {
    const irqs = lk.lockIrqSave();
    defer lk.unlockRestore(irqs);
    const oldest = if (ring_head > ring_size) ring_head - ring_size else 0;
    var start = @min(@max(from, oldest), ring_head);
    if (from < oldest) {
        while (start < ring_head and ring[start % ring_size] != '\n') start += 1;
        if (start < ring_head) start += 1;
    }
    var n: usize = 0;
    while (start + n < ring_head and n < buf.len) : (n += 1) buf[n] = ring[(start + n) % ring_size];
    if (n == buf.len and start + n < ring_head) {
        if (std.mem.lastIndexOfScalar(u8, buf[0..n], '\n')) |nl| n = nl + 1;
    }
    return .{ .n = n, .start = start, .head = ring_head };
}
