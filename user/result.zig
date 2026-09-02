//! Structured results for programs msh runs: build a value in a small
//! arena, then hand it back through the `out` buffer as an mshl data
//! literal. Text exists only if there is no `out` — then the program is
//! talking to a human and renders for one.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const mshl = @import("mosslib").mshl;

var heap: [128 << 10]u8 = undefined;

pub const Result = struct {
    fba: std.heap.FixedBufferAllocator,

    pub fn init() Result {
        return .{ .fba = std.heap.FixedBufferAllocator.init(&heap) };
    }

    pub fn allocator(r: *Result) std.mem.Allocator {
        return r.fba.allocator();
    }

    /// Write `v` into the `out` buffer (NUL-terminated data literal).
    /// False when there is no `out` or it is too small.
    pub fn deliver(r: *Result, setup: *const boot.Setup, v: mshl.Value) bool {
        const cap = setup.cap(.out);
        if (cap == 0) return false;
        const m = usys.shmMap(cap);
        if (m.err != .ok) return false;
        var text: std.ArrayList(u8) = .empty;
        mshl.writeData(v, r.allocator(), &text) catch return false;
        const room = m.data[1] * 4096;
        if (text.items.len + 1 > room) return false;
        const dst: [*]volatile u8 = @ptrFromInt(m.data[0]);
        for (text.items, 0..) |c, i| dst[i] = c;
        dst[text.items.len] = 0;
        return true;
    }
};
