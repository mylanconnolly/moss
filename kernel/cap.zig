//! Capability tables: one page per domain, generational handles.
//!
//! A handle names (slot, generation); the slot's generation bumps on every
//! delete, so a stale handle can never resurrect authority. Lookups validate
//! slot range, generation, and expected type. There are no global cap
//! namespaces — a table is only reachable through the domain that owns it.

const std = @import("std");
const shared = @import("shared");

pub const CapType = enum(u8) {
    empty,
    /// Authority to write to the kernel debug log.
    debug_log,
    /// The serving end of a channel (recv/reply).
    channel_a,
    /// The calling end of a channel (call).
    channel_b,
    /// A notification object (signal/wait).
    notification,
    /// A shared-memory grant (map).
    shm,
    /// Authority to spawn and destroy domains.
    spawner,
    /// Control over one spawned domain (stat, destroy).
    domain_ctl,
    /// A physical MMIO window: object = base | pages << 48.
    mmio,
    /// A contiguous SPI range: object = base intid | count << 32.
    irq,
    /// Authority to seed the kernel entropy pool (rng_seed).
    entropy,
};

pub const Entry = struct {
    cap_type: CapType,
    generation: u40,
    /// Object reference; meaning depends on cap_type.
    object: u64,
    /// Badge: opaque server-chosen identity minted into channel_b caps
    /// (seL4-style); delivered to the server with every call so one
    /// channel can serve many scoped clients. 0 = unbadged.
    badge: u64 = 0,
};

pub const slots = 128;

comptime {
    std.debug.assert(slots * @sizeOf(Entry) <= 4096);
}

pub const Table = struct {
    entries: [slots]Entry,

    /// Initialize in place (the backing page arrives zeroed; generations
    /// start at 1 so the all-zero Handle is never valid).
    pub fn init(self: *Table) void {
        for (&self.entries) |*e| {
            e.* = .{ .cap_type = .empty, .generation = 1, .object = 0 };
        }
    }

    pub fn insert(self: *Table, cap_type: CapType, object: u64) ?shared.Handle {
        return self.insertBadged(cap_type, object, 0);
    }

    pub fn insertBadged(self: *Table, cap_type: CapType, object: u64, badge: u64) ?shared.Handle {
        for (&self.entries, 0..) |*e, i| {
            if (e.cap_type == .empty) {
                e.cap_type = cap_type;
                e.object = object;
                e.badge = badge;
                return .{ .slot = @intCast(i), .generation = e.generation };
            }
        }
        return null;
    }

    /// Like lookup, but also yields the badge.
    pub fn lookupBadge(self: *Table, handle: shared.Handle, expect: CapType) ?struct { obj: u64, badge: u64 } {
        if (handle.slot >= slots) return null;
        const e = &self.entries[handle.slot];
        if (e.generation != handle.generation) return null;
        if (e.cap_type != expect) return null;
        return .{ .obj = e.object, .badge = e.badge };
    }

    pub fn lookup(self: *Table, handle: shared.Handle, expect: CapType) ?u64 {
        if (handle.slot >= slots) return null;
        const e = &self.entries[handle.slot];
        if (e.generation != handle.generation) return null;
        if (e.cap_type != expect) return null;
        return e.object;
    }

    /// Remove a cap; the slot's generation bumps so outstanding handles die.
    pub fn remove(self: *Table, handle: shared.Handle) bool {
        if (handle.slot >= slots) return false;
        const e = &self.entries[handle.slot];
        if (e.generation != handle.generation or e.cap_type == .empty) return false;
        e.cap_type = .empty;
        e.object = 0;
        e.badge = 0;
        e.generation +%= 1;
        return true;
    }
};
