//! Kernel object allocation with quota accounting.
//!
//! Every kernel allocation is charged to an Account; when domains arrive
//! (Phase 3) each domain owns one and teardown verifies the balance returns
//! to zero. Page-granularity for now — object slabs come with the first real
//! kernel objects.

const std = @import("std");
const mem = @import("mem.zig");
const pmem = @import("pmem.zig");

pub const Error = error{
    QuotaExceeded,
    OutOfFrames,
};

pub const Account = struct {
    limit: usize,
    used: std.atomic.Value(usize) = .init(0),

    pub fn charge(self: *Account, bytes: usize) Error!void {
        const prev = self.used.fetchAdd(bytes, .monotonic);
        if (prev + bytes > self.limit) {
            _ = self.used.fetchSub(bytes, .monotonic);
            return Error.QuotaExceeded;
        }
    }

    pub fn credit(self: *Account, bytes: usize) void {
        const prev = self.used.fetchSub(bytes, .monotonic);
        std.debug.assert(prev >= bytes);
    }

    pub fn balance(self: *const Account) usize {
        return self.used.load(.monotonic);
    }
};

/// The kernel's own account, for allocations that precede any domain.
pub var kernel_account: Account = .{ .limit = 16 << 20 };

pub fn allocPage(account: *Account) Error![*]u8 {
    try account.charge(mem.page_size);
    errdefer account.credit(mem.page_size);
    const pa = pmem.allocZeroed() orelse return Error.OutOfFrames;
    return mem.physToPtr([*]u8, pa);
}

pub fn freePage(account: *Account, page: [*]u8) void {
    pmem.free(mem.virtToPhys(@intFromPtr(page)));
    account.credit(mem.page_size);
}
