//! Client of the selected-document picker. No directory authority or paths in requests.
const shared = @import("shared");
const usys = @import("usys.zig");
const p = shared.picker;
pub const Client = struct {
    chan: u64 = 0,
    va: u64 = 0,
    name: [256]u8 = undefined,
    name_len: usize = 0,
    read_only: bool = false,
    pub fn init(authority: u64) !Client {
        var self: Client = .{};
        const r = usys.callTypedCap(p.Req, p.Resp, authority, .register, 0);
        self.chan = switch (r) {
            .ok => |v| if (v.rep == .registered and v.cap != 0) v.cap else return error.Unavailable,
            .err => return error.Unavailable,
        };
        errdefer self.deinit();
        const sh = usys.shmCreate(p.pages);
        if (sh.err != .ok) return error.OutOfMemory;
        defer _ = usys.capDrop(sh.data[0]);
        const m = usys.shmMap(sh.data[0]);
        if (m.err != .ok) return error.OutOfMemory;
        self.va = m.data[0];
        switch (usys.callTyped(p.Req, p.Resp, self.chan, .attach_buf, sh.data[0])) {
            .ok => |v| if (v != .ok) return error.Unavailable,
            .err => return error.Unavailable,
        }
        return self;
    }
    pub fn deinit(self: *Client) void {
        if (self.chan != 0) _ = usys.capDrop(self.chan);
        if (self.va != 0) _ = usys.shmUnmap(self.va);
        self.chan = 0;
        self.va = 0;
    }
    pub fn title(self: *const Client) []const u8 {
        return self.name[0..self.name_len];
    }
    fn request(self: *Client, req: p.Req) !?[]const u8 {
        const r = switch (usys.callTyped(p.Req, p.Resp, self.chan, req, 0)) {
            .ok => |v| v,
            .err => return error.Unavailable,
        };
        switch (r) {
            .cancelled => return null,
            .document => |d| {
                if (d.len > p.max_bytes or d.name_len > self.name.len) return error.InvalidReply;
                const bytes: [*]const u8 = @ptrFromInt(self.va);
                self.name_len = @intCast(d.name_len);
                @memcpy(self.name[0..self.name_len], bytes[p.name_offset..][0..self.name_len]);
                self.read_only = d.read_only != 0;
                return bytes[0..@intCast(d.len)];
            },
            .failed => |f| return switch (f.code) {
                @intFromEnum(p.Error.not_found) => error.FileNotFound,
                @intFromEnum(p.Error.bad_path) => error.InvalidPath,
                @intFromEnum(p.Error.not_file) => error.NotFile,
                @intFromEnum(p.Error.busy) => error.DocumentBusy,
                @intFromEnum(p.Error.read_only) => error.ReadOnly,
                @intFromEnum(p.Error.no_space) => error.DiskFull,
                @intFromEnum(p.Error.not_text) => error.NotText,
                @intFromEnum(p.Error.too_large) => error.FileTooLarge,
                @intFromEnum(p.Error.commit_uncertain) => error.SaveUncertain,
                else => error.DocumentUnavailable,
            },
            else => return error.InvalidReply,
        }
    }
    pub fn open(self: *Client) !?[]const u8 {
        return self.request(.open);
    }
    pub fn save(self: *Client, text: []const u8, save_as: bool) !bool {
        if (text.len > p.max_bytes) return error.FileTooLarge;
        const bytes: [*]u8 = @ptrFromInt(self.va);
        @memcpy(bytes[0..text.len], text);
        return (try self.request(if (save_as or self.name_len == 0) .{ .save_as = .{ .len = text.len } } else .{ .save = .{ .len = text.len } })) != null;
    }
};
