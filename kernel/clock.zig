//! Wall time: one number, the Unix time at which the cycle counter
//! read zero (`boot_epoch_ms`), and where it came from. The port reads
//! a real-time clock once at boot if the machine has one; the time
//! service refines it over the network (clock_set, an authority). Any
//! domain reads it (clock_get) and adds its own cycle count: wall time
//! is not a capability, only setting it is. Everything the kernel
//! itself keeps is still in ticks and cycles.

const std = @import("std");
const arch = @import("arch.zig");
const log = @import("log.zig");
const shared = @import("shared");

var boot_epoch_ms: u64 = 0;
var source: shared.ClockSource = .none;

pub const Clock = struct { boot_epoch_ms: u64, source: shared.ClockSource };

/// The counter's milliseconds since boot.
fn uptimeMs() u64 {
    const hz = arch.cpu.cycleHz();
    if (hz == 0) return 0;
    return arch.cpu.cycles() / (hz / 1000);
}

/// From the port's RTC, read now: seconds since the epoch, or nothing.
pub fn init(rtc_seconds: ?u64) void {
    if (rtc_seconds) |s| {
        boot_epoch_ms = s * 1000 -| uptimeMs();
        source = .rtc;
        log.info("clock: rtc says {d} (unix seconds); boot was at {d} ms", .{ s, boot_epoch_ms });
    } else log.warn("clock: no real-time clock; wall time unknown until set", .{});
}

pub fn get() Clock {
    return .{ .boot_epoch_ms = boot_epoch_ms, .source = source };
}

pub fn set(epoch_ms: u64) void {
    boot_epoch_ms = epoch_ms;
    source = .set;
}
