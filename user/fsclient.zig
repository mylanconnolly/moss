//! Filesystem client stubs: the typed calls a view-cap holder makes
//! against fssvc, shared by the fs demo roles (alice/bob) and msh.
//! Every path/data byte travels through the view's attached shm buffer.

const shared = @import("shared");
const usys = @import("usys.zig");

pub fn fsOpen(chan: u64, buf: [*]u8, path: []const u8, create: u64) union(enum) { fd: u64, err: shared.FsErr } {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .open = .{ .path_off = 1024, .path_len = path.len, .create = create },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return .{ .fd = x.n },
            .fs_err => |e| return .{ .err = @enumFromInt(e.code) },
            else => return .{ .err = .io },
        },
        .err => return .{ .err = .io },
    }
}

pub fn fsWrite(chan: u64, buf: [*]u8, fd: u64, data: []const u8) bool {
    @memcpy(buf[0..data.len], data);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .write = .{ .fd = fd, .off = 0, .len = data.len },
    }, 0)) {
        .ok => |rep| return rep == .num,
        .err => return false,
    }
}

pub fn fsRead(chan: u64, fd: u64, len: u64) ?u64 {
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .read = .{ .fd = fd, .off = 0, .len = len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return x.n,
            else => return null,
        },
        .err => return null,
    }
}

pub fn fsList(chan: u64, buf: [*]u8, path: []const u8) ?u64 {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .list = .{ .path_off = 1024, .path_len = path.len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return x.n,
            else => return null,
        },
        .err => return null,
    }
}

pub fn attachBuf(chan: u64) struct { va: u64, cap: u64 } {
    const s = usys.shmCreate(shared.fs_buf_pages);
    if (s.err != .ok) usys.exit(210);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(211);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .attach_buf, s.data[0])) {
        .ok => {},
        .err => usys.exit(212),
    }
    return .{ .va = m.data[0], .cap = s.data[0] };
}

pub fn fsMkdir(chan: u64, buf: [*]u8, path: []const u8) bool {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .open = .{ .path_off = 1024, .path_len = path.len, .create = 2 },
    }, 0)) {
        .ok => |rep| return rep == .ok,
        .err => return false,
    }
}

pub fn fsDelete(chan: u64, buf: [*]u8, path: []const u8) union(enum) { ok, err: shared.FsErr } {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .delete = .{ .path_off = 1024, .path_len = path.len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .ok => return .ok,
            .fs_err => |e| return .{ .err = @enumFromInt(e.code) },
            else => return .{ .err = .io },
        },
        .err => return .{ .err = .io },
    }
}

pub fn fsRename(chan: u64, buf: [*]u8, from: []const u8, to: []const u8) bool {
    @memcpy(buf[1024 .. 1024 + from.len], from);
    @memcpy(buf[1536 .. 1536 + to.len], to);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .rename = .{ .from = 1024 | (from.len << 32), .to = 1536 | (to.len << 32) },
    }, 0)) {
        .ok => |rep| return rep == .ok,
        .err => return false,
    }
}

pub fn fsTruncate(chan: u64, fd: u64, len: u64) bool {
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .truncate = .{ .fd = fd, .len = len },
    }, 0)) {
        .ok => |rep| return rep == .ok,
        .err => return false,
    }
}

pub const StatOut = struct { typ: u64, size: u64, mtime: u64 };

pub fn fsStat(chan: u64, buf: [*]u8, path: []const u8) ?StatOut {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .stat = .{ .path_off = 1024, .path_len = path.len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .stat => |st| return .{ .typ = st.typ, .size = st.size, .mtime = st.mtime },
            else => return null,
        },
        .err => return null,
    }
}

pub fn fsSymlink(chan: u64, buf: [*]u8, path: []const u8, target: []const u8) bool {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    @memcpy(buf[1536 .. 1536 + target.len], target);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .symlink = .{ .path = 1024 | (path.len << 32), .target = 1536 | (target.len << 32) },
    }, 0)) {
        .ok => |rep| return rep == .ok,
        .err => return false,
    }
}

pub fn fsReadlink(chan: u64, buf: [*]u8, path: []const u8) ?u64 {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .readlink = .{ .path_off = 1024, .path_len = path.len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return x.n,
            else => return null,
        },
        .err => return null,
    }
}

pub fn fsSync(chan: u64) bool {
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .sync, 0)) {
        .ok => |rep| return rep == .ok,
        .err => return false,
    }
}

pub const Statfs = struct { free_blocks: u64, total_blocks: u64, encrypted: bool };

pub fn fsStatfs(chan: u64) ?Statfs {
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .statfs, 0)) {
        .ok => |rep| switch (rep) {
            .statfs => |st| return .{
                .free_blocks = st.free_blocks,
                .total_blocks = st.total_blocks,
                .encrypted = st.encrypted != 0,
            },
            else => return null,
        },
        .err => return null,
    }
}

/// Positioned read/write (fd IO at an offset) — data in buf[0..len].
pub fn fsReadAt(chan: u64, fd: u64, off: u64, len: u64) ?u64 {
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .read = .{ .fd = fd, .off = off, .len = len },
    }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| return x.n,
            else => return null,
        },
        .err => return null,
    }
}

pub fn fsClose(chan: u64, fd: u64) void {
    _ = usys.callTyped(shared.FsReq, shared.FsResp, chan, .{ .close = .{ .fd = fd } }, 0);
}

/// Positioned write: data lands at buf[0..len] and goes to fd at `off`.
pub fn fsWriteAt(chan: u64, buf: [*]u8, fd: u64, off: u64, data: []const u8) bool {
    @memcpy(buf[0..data.len], data);
    switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{
        .write = .{ .fd = fd, .off = off, .len = data.len },
    }, 0)) {
        .ok => |rep| return rep == .num,
        .err => return false,
    }
}

/// Derive a narrower view (subtree, optionally read-only); the reply's
/// attached cap is the new view — it needs its own attachBuf.
pub fn fsDerive(chan: u64, buf: [*]u8, path: []const u8, ro: bool) ?u64 {
    const d = fsDeriveBadged(chan, buf, path, ro) orelse return null;
    return d.cap;
}

/// Derive, and learn the new view's badge — its name for `revoke`.
pub fn fsDeriveBadged(chan: u64, buf: [*]u8, path: []const u8, ro: bool) ?struct { cap: u64, badge: u64 } {
    @memcpy(buf[1024 .. 1024 + path.len], path);
    switch (usys.callTypedCap(shared.FsReq, shared.FsResp, chan, .{
        .derive = .{ .path_off = 1024, .path_len = path.len, .ro = @intFromBool(ro) },
    }, 0)) {
        .ok => |ok| {
            if (ok.cap == 0) return null;
            return switch (ok.rep) {
                .view => |vw| .{ .cap = ok.cap, .badge = vw.badge },
                else => .{ .cap = ok.cap, .badge = 0 },
            };
        },
        .err => return null,
    }
}

/// Withdraw a view derived through `chan` (or any, from the root view).
pub fn fsRevoke(chan: u64, badge: u64) bool {
    return switch (usys.callTyped(shared.FsReq, shared.FsResp, chan, .{ .revoke = .{ .badge = badge } }, 0)) {
        .ok => |rep| rep == .ok,
        .err => false,
    };
}
