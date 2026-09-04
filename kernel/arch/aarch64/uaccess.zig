//! The one door to user memory. A syscall runs with the calling domain's
//! user pages mapped (TTBR0 is live), so kernel code *could* dereference
//! any user pointer; everything that does so goes through here, and
//! here is the only place the hardware is told to allow it.
//!
//! On ARMv8.1+ that hardware is PAN (Privileged Access Never): while
//! PSTATE.PAN is set, a privileged load or store to a user-accessible
//! page faults, however valid the mapping. The kernel runs with it set
//! — exception entry sets it (SCTLR.SPAN = 0), and each core sets it
//! when it starts — and clears it only around the copies below. A
//! kernel bug that dereferences a user-controlled pointer anywhere else
//! is then a fault report, not a read or write on the caller's behalf.
//! On ARMv8.0 there is no PAN: the window calls are no-ops and the
//! explicit range checks the callers already make are the whole story,
//! as they were before. The feature is detected, not assumed.
//!
//! The same shape is what x86_64 will want (SMAP: stac/clac around the
//! copy); nothing outside this file knows which it is.

const log = @import("../../log.zig");

pub var available = false;
var detected = false;

/// Once per core, before it handles its first syscall: find out whether
/// the CPU has PAN (ID_AA64MMFR1_EL1.PAN, bits 23:20) and arm it.
pub fn enable() void {
    if (!detected) {
        const mmfr1 = asm ("mrs %[v], id_aa64mmfr1_el1"
            : [v] "=r" (-> u64),
        );
        available = (mmfr1 >> 20) & 0xf != 0;
        detected = true;
        if (available) {
            log.info("uaccess: PAN on — user memory only through copy windows", .{});
        } else {
            log.info("uaccess: no PAN on this CPU (ARMv8.0); range checks alone guard user memory", .{});
        }
    }
    close();
}

/// `msr pan, #0` / `msr pan, #1`, as encodings: the assembler wants a
/// v8.1 target to spell them, and the kernel's code generation stays
/// v8.0 so that it still boots on an A72.
inline fn open() void {
    if (available) asm volatile (".inst 0xd500409f" ::: .{ .memory = true });
}

inline fn close() void {
    if (available) asm volatile (".inst 0xd500419f" ::: .{ .memory = true });
}

/// Copy `dst.len` bytes from user address `src` (range-checked by the
/// caller) into kernel memory.
pub fn copyFromUser(dst: []u8, src: u64) void {
    open();
    defer close();
    @memcpy(dst, @as([*]const u8, @ptrFromInt(src))[0..dst.len]);
}

/// Copy kernel bytes to user address `dst` (range-checked by the caller).
pub fn copyToUser(dst: u64, src: []const u8) void {
    open();
    defer close();
    @memcpy(@as([*]u8, @ptrFromInt(dst))[0..src.len], src);
}

/// Run `f(buf)` with a window open on the user buffer at `ptr` — for a
/// producer that writes straight into it (the CSPRNG, the domain list).
pub fn withUserBuffer(ptr: u64, len: u64, ctx: anytype, comptime f: anytype) @TypeOf(f(ctx, @as([]u8, undefined))) {
    open();
    defer close();
    return f(ctx, @as([*]u8, @ptrFromInt(ptr))[0..len]);
}

/// Deliberately touch user memory with the window closed (the `pan`
/// drill): with PAN this faults, which is the point.
pub fn touchOutsideWindow(ptr: u64) u8 {
    return @as(*volatile u8, @ptrFromInt(ptr)).*;
}
