//! Optional clipboard client. Authority is supplied by the session manifest.
const shared = @import("shared");
const usys = @import("usys.zig");
pub var authority: u64 = 0;
var chan: u64 = 0;
var va: u64 = 0;
fn close() void {
    if (va != 0) _ = usys.shmUnmap(va);
    if (chan != 0) _ = usys.capDrop(chan);
    chan = 0;
    va = 0;
}
fn ready() bool {
    if (chan != 0 and va != 0) return true;
    if (authority == 0) return false;
    const r = usys.callTypedCap(shared.ClipReq, shared.ClipResp, authority, .register, 0);
    switch (r) {
        .ok => |ok| {
            if (ok.rep != .registered or ok.cap == 0) return false;
            chan = ok.cap;
        },
        .err => return false,
    }
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) {
        close();
        return false;
    }
    defer _ = usys.capDrop(sh.data[0]);
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) {
        close();
        return false;
    }
    va = m.data[0];
    switch (usys.callTyped(shared.ClipReq, shared.ClipResp, chan, .attach_buf, sh.data[0])) {
        .ok => |rep| if (rep == .ok) {
            return true;
        },
        .err => {},
    }
    close();
    return false;
}
pub fn set(text: []const u8) bool {
    if (!ready() or text.len > 4096) return false;
    const buf: [*]u8 = @ptrFromInt(va);
    @memcpy(buf[0..text.len], text);
    switch (usys.callTyped(shared.ClipReq, shared.ClipResp, chan, .{ .set = .{ .len = text.len } }, 0)) {
        .ok => |rep| return rep == .ok,
        .err => {
            close();
            return false;
        },
    }
}
pub fn get() ?[]const u8 {
    if (!ready()) return null;
    switch (usys.callTyped(shared.ClipReq, shared.ClipResp, chan, .get, 0)) {
        .ok => |rep| switch (rep) {
            .data => |d| {
                const buf: [*]const u8 = @ptrFromInt(va);
                return buf[0..@min(d.len, 4096)];
            },
            else => return null,
        },
        .err => {
            close();
            return null;
        },
    }
}
