//! The one door to user memory. SMAP (stac/clac around the copies) is
//! what this port will arm once user mode exists; until then the window
//! is the range checks alone, as on an ARMv8.0 core.

pub var available = false;

pub fn enable() void {}

inline fn open() void {}
inline fn close() void {}

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

pub fn touchOutsideWindow(ptr: u64) u8 {
    return @as(*volatile u8, @ptrFromInt(ptr)).*;
}
