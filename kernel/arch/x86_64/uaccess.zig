//! The one door to user memory. SMAP (Supervisor Mode Access Prevention):
//! while RFLAGS.AC is clear, a privileged load or store to a user page
//! faults, however valid the mapping; the kernel runs with it clear (the
//! syscall entry masks it, interrupt entry clears it) and opens it only
//! around the copies below with `stac`/`clac`. A kernel bug that
//! dereferences a user-controlled pointer anywhere else is a fault
//! report, not a read or write on the caller's behalf. Without SMAP the
//! range checks the callers make are the whole story, as on ARMv8.0.

const cpu = @import("cpu.zig");
const log = @import("../../log.zig");

pub var available = false;
var detected = false;

/// Once per core, before it handles its first syscall (trap.init sets
/// CR4.SMAP where the CPU reports it).
pub fn enable() void {
    if (!detected) {
        available = cpu.cpuid(7, 0).ebx & (1 << 20) != 0;
        detected = true;
        if (available) {
            log.info("uaccess: SMAP on — user memory only through copy windows", .{});
        } else {
            log.info("uaccess: no SMAP on this CPU; range checks alone guard user memory", .{});
        }
    }
    close();
}

inline fn open() void {
    if (available) asm volatile ("stac" ::: .{ .memory = true });
}

inline fn close() void {
    if (available) asm volatile ("clac" ::: .{ .memory = true });
}

pub fn copyFromUser(dst: []u8, src: u64) void {
    open();
    defer close();
    @memcpy(dst, @as([*]const u8, @ptrFromInt(src))[0..dst.len]);
}

pub fn copyToUser(dst: u64, src: []const u8) void {
    open();
    defer close();
    @memcpy(@as([*]u8, @ptrFromInt(dst))[0..src.len], src);
}

pub fn withUserBuffer(ptr: u64, len: u64, ctx: anytype, comptime f: anytype) @TypeOf(f(ctx, @as([]u8, undefined))) {
    open();
    defer close();
    return f(ctx, @as([*]u8, @ptrFromInt(ptr))[0..len]);
}

/// Deliberately touch user memory with the window closed (the `pan`
/// drill): with SMAP this faults, which is the point.
pub fn touchOutsideWindow(ptr: u64) u8 {
    return @as(*volatile u8, @ptrFromInt(ptr)).*;
}
