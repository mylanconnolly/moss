//! Cross-boundary ABI and protocol types shared by the kernel, userspace,
//! host-side tests, and (eventually) MCU leaf nodes. This module is the IDL:
//! everything here must compile identically for every target, so it may not
//! import kernel or userspace code and may not allocate.

const std = @import("std");

pub const version: std.SemanticVersion = .{ .major = 0, .minor = 0, .patch = 0 };

/// Generational handle: the only form in which kernel object identity crosses
/// the ABI. Slot indexes a domain's cap table; the generation is bumped on
/// slot reuse so a stale handle can never resurrect authority. 40 bits of
/// generation means a slot reused once per microsecond takes ~35 years to
/// wrap.
pub const Handle = packed struct(u64) {
    slot: u24,
    generation: u40,

    pub const invalid: Handle = .{ .slot = 0, .generation = 0 };

    pub fn eql(a: Handle, b: Handle) bool {
        return @as(u64, @bitCast(a)) == @as(u64, @bitCast(b));
    }
};

test "handle round-trips through its integer representation" {
    const h: Handle = .{ .slot = 7, .generation = 42 };
    const bits: u64 = @bitCast(h);
    const back: Handle = @bitCast(bits);
    try std.testing.expect(h.eql(back));
    try std.testing.expect(!h.eql(Handle.invalid));
}
