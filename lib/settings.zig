//! Settings are data in the hierarchy, in layers: the system layer
//! (`conf/<svc>.msh`, admin-written) and the user layer
//! (`home/<user>/conf/<svc>.msh`). A program merges the two for its own
//! keys, and which keys a user may override is stated by the program's
//! schema — a *locked* key keeps the system value no matter what the
//! user layer says, so a setting a user may not change is not overridable
//! rather than merely discouraged. There is no settings daemon, no
//! registry, and no third syntax: both layers are mshl data literals read
//! by the same strict parser as unit files and user records. Pure and
//! host-tested.

const std = @import("std");
const mshl = @import("mshl.zig");
const Value = mshl.Value;

/// Effective settings: every key of `system`, each replaced by the user
/// layer's value unless the key is locked; keys the user layer adds that
/// the system does not know are ignored (a schema, not a dumping ground).
pub fn merge(a: std.mem.Allocator, system: mshl.Record, user: ?mshl.Record, locked: []const []const u8) error{OutOfMemory}!mshl.Record {
    const vals = try a.alloc(Value, system.vals.len);
    for (system.keys, system.vals, 0..) |k, v, i| {
        vals[i] = v;
        if (user) |u| {
            if (!isLocked(k, locked)) {
                if (u.get(k)) |uv| vals[i] = uv;
            }
        }
    }
    return .{ .keys = system.keys, .vals = vals };
}

fn isLocked(key: []const u8, locked: []const []const u8) bool {
    for (locked) |l| {
        if (std.mem.eql(u8, l, key)) return true;
    }
    return false;
}

// ------------------------------------------------------------------ tests

fn rec(keys: []const []const u8, vals: []const Value) mshl.Record {
    return .{ .keys = keys, .vals = vals };
}

test "user values override system ones except for locked keys" {
    const a = std.testing.allocator;
    const system = rec(&.{ "theme", "tab_width", "telemetry" }, &.{ .{ .str = "dark" }, .{ .int = 4 }, .{ .bool = false } });
    const user = rec(&.{ "theme", "telemetry", "unknown" }, &.{ .{ .str = "light" }, .{ .bool = true }, .{ .int = 9 } });
    const eff = try merge(a, system, user, &.{"telemetry"});
    defer a.free(eff.vals);
    try std.testing.expectEqualStrings("light", eff.get("theme").?.str);
    try std.testing.expectEqual(@as(i64, 4), eff.get("tab_width").?.int);
    try std.testing.expectEqual(false, eff.get("telemetry").?.bool);
    try std.testing.expect(eff.get("unknown") == null);
}

test "no user layer yields the system layer" {
    const a = std.testing.allocator;
    const system = rec(&.{"theme"}, &.{.{ .str = "dark" }});
    const eff = try merge(a, system, null, &.{});
    defer a.free(eff.vals);
    try std.testing.expectEqualStrings("dark", eff.get("theme").?.str);
}

test "the layers parse with the data parser unit files use" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var ctx: u8 = 0;
    var it = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&ctx), .call = noHost });
    const sys = try it.parseData("{ theme: dark, tab_width: 4, telemetry: false }");
    const usr = try it.parseData("{ theme: light, telemetry: true }");
    const eff = try merge(a, sys.record, usr.record, &.{"telemetry"});
    try std.testing.expectEqualStrings("light", eff.get("theme").?.str);
    try std.testing.expectEqual(false, eff.get("telemetry").?.bool);
}

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const Value, _: ?Value) mshl.Error!?Value {
    return null;
}
