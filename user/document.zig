//! Selected-document clients for Editor, and a Files sender that explicitly
//! offers its selected basename with a fresh parent view to the trusted broker.
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
        try self.attach();
        return self;
    }
    fn attach(self: *Client) !void {
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
    }
    pub fn take(receiver: u64) !?Client {
        if (receiver == 0) return null;
        const r = switch (usys.callTypedCap(p.Req, p.Resp, receiver, .take, 0)) {
            .ok => |v| v,
            .err => return error.Unavailable,
        };
        if (r.rep == .empty) {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            return null;
        }
        if (r.rep != .selected or r.cap == 0) {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            return error.InvalidReply;
        }
        var self: Client = .{ .chan = r.cap };
        try self.attach();
        return self;
    }
    pub fn offer(self: *Client, parent_view: u64, basename: []const u8) !u64 {
        if (basename.len == 0 or basename.len > 56 or self.va == 0) return error.InvalidPath;
        const bytes: [*]u8 = @ptrFromInt(self.va);
        @memcpy(bytes[p.name_offset..][0..basename.len], basename);
        const r = switch (usys.callTyped(p.Req, p.Resp, self.chan, .{ .offer = .{ .path_len = basename.len } }, parent_view)) {
            .ok => |v| v,
            .err => return error.Unavailable,
        };
        return switch (r) {
            .offered => |v| v.ticket,
            .failed => |f| fail(f.code),
            else => error.InvalidReply,
        };
    }
    pub fn enqueue(self: *Client, ticket: u64) !void {
        switch (usys.callTyped(p.Req, p.Resp, self.chan, .{ .enqueue = .{ .ticket = ticket } }, 0)) {
            .ok => |v| if (v != .ok) return error.DocumentUnavailable,
            .err => return error.Unavailable,
        }
    }
    pub fn cancelOffer(self: *Client, ticket: u64) void {
        _ = usys.callTyped(p.Req, p.Resp, self.chan, .{ .cancel_offer = .{ .ticket = ticket } }, 0);
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
            .failed => |f| return fail(f.code),
            else => return error.InvalidReply,
        }
    }
    fn fail(code: u64) error{ FileNotFound, InvalidPath, NotFile, DocumentBusy, ReadOnly, DiskFull, NotText, FileTooLarge, SaveUncertain, DocumentUnavailable } {
        return switch (code) {
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
        };
    }
    pub fn load(self: *Client) !?[]const u8 {
        return self.request(.load);
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

/// Editor drill: the ordinary picker grant cannot drain the recipient queue,
/// and a freshly registered document cannot read or commit another selection.
pub fn probeQueueAuthority(authority: u64) !void {
    const taken = switch (usys.callTypedCap(p.Req, p.Resp, authority, .take, 0)) {
        .ok => |r| r,
        .err => return error.ProbeTransport,
    };
    if (taken.cap != 0) _ = usys.capDrop(taken.cap);
    if (taken.rep != .failed or taken.cap != 0) return error.QueueAuthorityLeaked;
    var client = try Client.init(authority);
    defer client.deinit();
    const read = switch (usys.callTyped(p.Req, p.Resp, client.chan, .load, 0)) {
        .ok => |r| r,
        .err => return error.ProbeTransport,
    };
    if (read != .failed or read.failed.code != @intFromEnum(p.Error.bad_path)) return error.UnselectedReadAllowed;
    const queued = switch (usys.callTyped(p.Req, p.Resp, client.chan, .{ .enqueue = .{ .ticket = 0 } }, 0)) {
        .ok => |r| r,
        .err => return error.ProbeTransport,
    };
    if (queued != .failed) return error.ForeignTicketAllowed;
}

/// Real broker IPC and FS regression. This view exists only in the editor
/// drill manifest, never in the production Editor's grants.
/// The kernel refuses a call on a channel the caller's own domain serves
/// (Errno.self_call) instead of parking the caller forever: mint a badge
/// on our own setup channel — received on at boot, so this domain is its
/// server — and call it.
pub fn probeSelfCall(own_chan: u64) !void {
    const minted = usys.chanMint(own_chan, 4242);
    if (minted.err != .ok) return error.ProbeMint;
    defer _ = usys.capDrop(minted.data[1]);
    const rep = usys.callTyped(shared.picker.Req, shared.picker.Resp, minted.data[1], .register, 0);
    switch (rep) {
        .err => |e| if (e != .self_call) return error.SelfCallNotRefused,
        .ok => return error.SelfCallAnswered,
    }
}

pub fn probeHandoff(authority: u64, receiver: u64, test_view: u64) !void {
    const std = @import("std");
    const fs = @import("fsclient.zig");
    if (test_view == 0 or receiver == 0) return error.MissingProbeAuthority;
    const attached = fs.attachBuf(test_view);
    defer _ = usys.capDrop(attached.cap);
    defer _ = usys.shmUnmap(attached.va);
    const buf: [*]u8 = @ptrFromInt(attached.va);
    const folder = "handoff-probe";
    const basename = "selected.txt";
    const path = "handoff-probe/selected.txt";
    const contents = "readonly handoff fixture\n";
    if (!fs.fsMkdir(test_view, buf, folder)) return error.ProbeCreateFolder;
    defer _ = fs.fsDelete(test_view, buf, folder);
    const fd = switch (fs.fsOpen(test_view, buf, path, 3)) {
        .fd => |f| f,
        .err => return error.ProbeCreateFile,
    };
    defer _ = fs.fsDelete(test_view, buf, path);
    if (!fs.fsWriteAt(test_view, buf, fd, 0, contents)) {
        fs.fsClose(test_view, fd);
        return error.ProbeWriteFile;
    }
    fs.fsClose(test_view, fd);
    if (!fs.fsSync(test_view)) return error.ProbeSync;

    // An offer whose "parent view" is not a filesystem view is refused
    // before the broker calls on it — here, the sender's own broker
    // endpoint, which would have made the broker call itself and hang
    // every client. The broker must still answer afterwards.
    {
        var sender = try Client.init(authority);
        defer sender.deinit();
        if (sender.offer(sender.chan, basename)) |ticket| {
            sender.cancelOffer(ticket);
            return error.StrangerViewAccepted;
        } else |_| {}
        const parent = fs.fsDerive(test_view, buf, folder, true) orelse return error.ProbeFilesystem;
        defer _ = usys.capDrop(parent);
        const ticket = sender.offer(parent, basename) catch return error.BrokerStuckAfterRefusal;
        sender.cancelOffer(ticket);
    }

    // Offers cannot be committed or cancelled by another sender.
    {
        var sender = try Client.init(authority);
        defer sender.deinit();
        var stranger = try Client.init(authority);
        defer stranger.deinit();
        const parent = fs.fsDerive(test_view, buf, folder, true) orelse return error.ProbeFilesystem;
        defer _ = usys.capDrop(parent);
        const ticket = try sender.offer(parent, basename);
        if (stranger.enqueue(ticket)) |_| return error.ForeignTicketAllowed else |_| {}
        stranger.cancelOffer(ticket);
        // Prove foreign cancellation did not remove it, then remove it ourselves.
        try sender.enqueue(ticket);
        sender.cancelOffer(ticket);
        var unexpected = try Client.take(receiver);
        if (unexpected) |*c| {
            c.deinit();
            return error.CancelledOfferDelivered;
        }
    }

    // More prepared offers than the FS view pool can retain. Dropping a sender
    // must reclaim its uncommitted view, buffer, endpoint and client slab.
    for (0..40) |_| {
        var sender = try Client.init(authority);
        const parent = fs.fsDerive(test_view, buf, folder, true) orelse {
            sender.deinit();
            return error.ProbeFilesystem;
        };
        const offered = sender.offer(parent, basename);
        _ = usys.capDrop(parent);
        sender.deinit();
        _ = try offered;
        var unexpected = try Client.take(receiver);
        if (unexpected) |*c| {
            c.deinit();
            return error.PreparedOfferDelivered;
        }
    }

    // Once committed, sender exit must not remove the queued selection.
    var sender = try Client.init(authority);
    const parent = fs.fsDeriveBadged(test_view, buf, folder, true) orelse {
        sender.deinit();
        return error.ProbeFilesystem;
    };
    const offered = sender.offer(parent.cap, basename);
    _ = usys.capDrop(parent.cap);
    const ticket = offered catch |err| {
        sender.deinit();
        return err;
    };
    sender.enqueue(ticket) catch |err| {
        sender.deinit();
        return err;
    };
    sender.deinit();
    var selected = (try Client.take(receiver)) orelse return error.CommittedOfferLost;
    defer selected.deinit();
    const data = (try selected.load()) orelse return error.CommittedOfferLost;
    if (!std.mem.eql(u8, data, contents) or !std.mem.eql(u8, selected.title(), basename) or !selected.read_only) return error.WrongDocumentScope;
    if (selected.save("must not overwrite\n", false)) |_| return error.ReadonlyWriteAllowed else |err| {
        if (err != error.ReadOnly) return err;
    }
    var verify: [64]u8 = undefined;
    const actual = fs.readWhole(test_view, buf, path, &verify) orelse return error.ProbeFilesystem;
    if (!std.mem.eql(u8, actual, contents)) return error.ReadonlyWriteAllowed;
    if (!fs.fsRevoke(test_view, parent.badge)) return error.ProbeRevoke;
    if (selected.load()) |_| return error.RevokedReadAllowed else |err| {
        if (err != error.DocumentUnavailable) return err;
    }
    if (selected.save(contents, false)) |_| return error.RevokedWriteAllowed else |err| {
        if (err != error.DocumentUnavailable) return err;
    }
    selected.deinit();
    // Revoked slots must be reusable after their last cap dies.
    for (0..40) |_| {
        const revoked = fs.fsDeriveBadged(test_view, buf, folder, true) orelse return error.RevokedSlotLeaked;
        const ok = fs.fsRevoke(test_view, revoked.badge);
        _ = usys.capDrop(revoked.cap);
        if (!ok) return error.ProbeRevoke;
    }
    try probeParentReuse(authority, receiver, test_view, buf, folder, basename, contents);
    var unexpected = try Client.take(receiver);
    if (unexpected) |*c| {
        c.deinit();
        return error.DuplicateHandoff;
    }

    // A committed handoff nobody claims expires (the drill's broker keeps
    // them 1 s): the Editor may have exited between Files' connect and
    // its enqueue, and nothing else would release what the offer pins —
    // or stop a much later Editor from silently opening that file.
    {
        var late_sender = try Client.init(authority);
        defer late_sender.deinit();
        const pv = fs.fsDerive(test_view, buf, folder, true) orelse return error.ProbeFilesystem;
        defer _ = usys.capDrop(pv);
        const t = try late_sender.offer(pv, basename);
        try late_sender.enqueue(t);
        usys.sleepMs(1500);
        var late = try Client.take(receiver);
        if (late) |*c| {
            c.deinit();
            return error.ExpiredHandoffDelivered;
        }
    }
}

fn probeParentReuse(authority: u64, receiver: u64, test_view: u64, buf: [*]u8, folder: []const u8, basename: []const u8, contents: []const u8) !void {
    const std = @import("std");
    const fs = @import("fsclient.zig");
    const ancestor = fs.fsDeriveBadged(test_view, buf, folder, true) orelse return error.ProbeAncestor;
    const attached = fs.attachBuf(ancestor.cap);
    const child = fs.fsDeriveBadged(ancestor.cap, @ptrFromInt(attached.va), "", true) orelse {
        _ = usys.shmUnmap(attached.va);
        _ = usys.capDrop(attached.cap);
        _ = usys.capDrop(ancestor.cap);
        return error.ProbeChild;
    };
    _ = usys.shmUnmap(attached.va);
    _ = usys.capDrop(attached.cap);
    var sender = try Client.init(authority);
    const offered = sender.offer(child.cap, basename);
    _ = usys.capDrop(child.cap);
    const ticket = offered catch |err| {
        sender.deinit();
        _ = usys.capDrop(ancestor.cap);
        return err;
    };
    sender.enqueue(ticket) catch |err| {
        sender.deinit();
        _ = usys.capDrop(ancestor.cap);
        return err;
    };
    sender.deinit();
    _ = usys.capDrop(ancestor.cap);
    // Client-death delivery is asynchronous: wait for the old slot to become
    // reusable, rather than relying on its order against the next request.
    var stranger_cap: u64 = 0;
    for (0..40) |_| {
        const stranger = fs.fsDeriveBadged(test_view, buf, folder, true) orelse return error.ProbeStranger;
        if (stranger.badge == ancestor.badge) {
            stranger_cap = stranger.cap;
            break;
        }
        _ = usys.capDrop(stranger.cap);
        usys.sleepMs(1);
    }
    if (stranger_cap == 0) return error.ProbeDidNotReuseParent;
    defer _ = usys.capDrop(stranger_cap);
    if (fs.fsRevoke(stranger_cap, child.badge)) return error.ReusedParentAuthority;
    var selected = (try Client.take(receiver)) orelse return error.CommittedOfferLost;
    defer selected.deinit();
    const bytes = (try selected.load()) orelse return error.CommittedOfferLost;
    if (!std.mem.eql(u8, bytes, contents)) return error.ParentExitLostDocument;
}
