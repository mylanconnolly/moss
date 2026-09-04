//! ps — a program that looks but cannot act. Run by msh in its own
//! domain with exactly: a log cap, its boot channel, and a read-only
//! introspect cap (slot 2: log → chan → introspect). No spawn authority
//! anywhere near it; the ledger is all it can reach. Its result is a
//! table handed back to msh as data (the `out` buffer), so it composes
//! with the language: `run ps | where state == alive | get name`. With
//! no `out` it renders the table itself.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const tty = @import("tty.zig");
const boot = @import("boot.zig");
const result = @import("result.zig");
const mshl = @import("mosslib").mshl;

comptime {
    asm (usys.imageHeader("ps"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const introspect_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

export fn umain(_: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    tty.attach(&setup);
    var recs: [16 * shared.DomainRec.size]u8 = undefined;
    const r = usys.domainList(introspect_h, &recs);
    if (r.err != .ok) {
        tty.out("ps: introspection denied\r\n");
        usys.exit(1);
    }
    var res = result.Result.init();
    const a = res.allocator();
    const cols = [_][]const u8{ "id", "name", "state", "threads", "kobj_kb", "kobj_max", "user_kb", "user_max", "cpu_pm", "cpu_max" };
    const rows = a.alloc([]const mshl.Value, r.data[0]) catch usys.exit(2);
    for (0..r.data[0]) |i| {
        const rec = shared.DomainRec.decode(recs[i * shared.DomainRec.size ..][0..shared.DomainRec.size]);
        const row = a.alloc(mshl.Value, cols.len) catch usys.exit(2);
        row[0] = .{ .int = rec.id };
        row[1] = .{ .str = a.dupe(u8, rec.nameSlice()) catch usys.exit(2) };
        row[2] = .{ .str = switch (rec.state) {
            .alive => "alive",
            .dying => "dying",
            .dead => "dead",
        } };
        row[3] = .{ .int = rec.threads };
        row[4] = .{ .int = @intCast(rec.kobj_kb >> 32) };
        row[5] = .{ .int = @intCast(rec.kobj_kb & 0xffff_ffff) };
        row[6] = .{ .int = @intCast(rec.user_kb >> 32) };
        row[7] = .{ .int = @intCast(rec.user_kb & 0xffff_ffff) };
        row[8] = .{ .int = @intCast(rec.cpu >> 32) };
        row[9] = .{ .int = @intCast(rec.cpu & 0xffff) };
        rows[i] = row;
    }
    const table: mshl.Value = .{ .table = .{ .cols = &cols, .rows = rows } };
    if (!res.deliver(&setup, table)) {
        tty.domainTable(&recs, r.data[0]);
        tty.out("(no spawn authority held: seen through an introspect cap)\r\n");
    }
    usys.exit(0);
}
