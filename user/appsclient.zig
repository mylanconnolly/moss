//! Read-only discovery through this session's init; metadata grants no caps.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
pub var authority: u64 = 0;
pub const Catalog = struct {
    records: [128]shared.apps.Record = undefined,
    len: usize = 0,
    pub fn refresh(self: *Catalog) bool {
        self.len = 0;
        var complete = false;
        defer if (!complete) {
            self.len = 0;
        };
        if (authority == 0) return false;
        const sh = usys.shmCreate(1);
        if (sh.err != .ok) return false;
        defer _ = usys.capDrop(sh.data[0]);
        const map = usys.shmMap(sh.data[0]);
        if (map.err != .ok) return false;
        defer _ = usys.shmUnmap(map.data[0]);
        const rows: [*]const u8 = @ptrFromInt(map.data[0]);
        var start: u64 = 0;
        while (true) {
            const reply = switch (usys.callTyped(shared.InitRequest, shared.InitReply, authority, .{ .apps = .{ .start = start } }, sh.data[0])) {
                .ok => |r| r,
                .err => return false,
            };
            if (reply != .apps) return false;
            const page = reply.apps;
            if (page.n > 4096 / shared.apps.Record.size or page.n > self.records.len - self.len) return false;
            const n: usize = @intCast(page.n);
            for (0..n) |i| self.records[self.len + i] = shared.apps.Record.decode(rows[i * shared.apps.Record.size ..][0..shared.apps.Record.size]);
            self.len += n;
            if (page.next == 0) break;
            if (page.next <= start) return false;
            start = page.next;
        }
        std.mem.sort(shared.apps.Record, self.records[0..self.len], {}, struct {
            fn less(_: void, a: shared.apps.Record, b: shared.apps.Record) bool {
                if (a.order != b.order) return a.order < b.order;
                return std.mem.order(u8, std.mem.sliceTo(&a.name, 0), std.mem.sliceTo(&b.name, 0)) == .lt;
            }
        }.less);
        complete = true;
        return true;
    }
};
pub fn activate(app: *const shared.apps.Record, display: u64) bool {
    const title = shared.strToWords(std.mem.sliceTo(&app.window, 0));
    const restored = usys.callTyped(shared.GpuReq, shared.GpuResp, display, .{ .restore_titled = .{ .a = title[0], .b = title[1] } }, 0);
    if (restored == .ok and restored.ok == .ok) return true;
    const name = shared.strToWords(std.mem.sliceTo(&app.unit, 0));
    return switch (usys.callTypedCap(shared.InitRequest, shared.InitReply, authority, .{ .connect_named = .{ .a = name[0], .b = name[1] } }, 0)) {
        .ok => |r| blk: {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            break :blk r.rep == .connected;
        },
        .err => false,
    };
}
