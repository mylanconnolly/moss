//! The script domain's host: spawns `jsrun` from a staged image with one
//! badged calling end of its channel, hands it the source through a
//! shared buffer, collects its `print` lines and its ending, serves the
//! one filesystem view it may lend (a program's `moss:fs` and its
//! relative imports are calls back here, answered through that view
//! and nothing wider), and destroys it. One run at a time; the caller
//! sees only the outcome.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const fscmds = @import("fscmds.zig");
const webhost = @import("webhost.zig");
const wire = shared.js;
const web = shared.web;

/// The script's memory: its image's static heaps (8 MB of JavaScript
/// values, 12 MB of bookkeeping) plus stack and the data buffer.
pub const script_user_kb: u64 = 32 << 10;
pub const script_kobj_kb: u64 = 2 << 10;

pub const Outcome = enum { ok, threw, dead, refused };

pub const Result = struct {
    outcome: Outcome,
    /// The completion value's text, or the exception's.
    text: []const u8,
    /// The `print` lines, each ending in a newline.
    output: []const u8,
};

/// What a run is offered: a filesystem view (its channel and attach
/// buffer), and whether the source is a module.
pub const Options = struct {
    fs_chan: u64 = 0,
    fs_buf: [*]u8 = undefined,
    module: bool = false,
    /// The page host whose broker answers the program's fetches (the
    /// shell's own network view, policed as a page's is), or null.
    web: ?*webhost.Host = null,
};

pub const Host = struct {
    log: u64,
    spawner: u64,
    chan: u64 = 0,
    /// The channel's own calling end, held so the side stays open
    /// between runs (a side whose last cap goes is closed for good).
    chan_b: u64 = 0,
    next_badge: u64 = 1,
    output: [64 << 10]u8 = undefined,
    output_len: usize = 0,
    text: [4096]u8 = undefined,
    text_len: usize = 0,
    /// A path in flight: the data buffer it came in carries the answer.
    /// (No larger scratch here: a static buffer in `mshrun` is paid by
    /// every shell it spawns, and 256 KB tipped a worker's budget.)
    path: [1024]u8 = undefined,
    /// The broker's state for the running program (what it has open,
    /// the connection it parks between requests).
    client: webhost.Client = .{},

    pub fn reset(h: *Host, log: u64, spawner: u64) void {
        h.* = .{ .log = log, .spawner = spawner };
    }

    pub fn init(h: *Host) bool {
        const ch = usys.chanCreate();
        if (ch.err != .ok) return false;
        h.chan = ch.data[0];
        h.chan_b = ch.data[1];
        return true;
    }

    fn reply(h: *Host, rep: wire.HostResp, cap: u64, token: u64) void {
        _ = usys.replyTypedTo(wire.HostResp, h.chan, rep, cap, token);
    }

    fn refuse(h: *Host, token: u64, code: u64) void {
        h.reply(.{ .refused = .{ .code = code } }, 0, token);
    }

    /// A path the script named, copied out of the data buffer (which
    /// the answer will overwrite), cleaned of what a view must not see.
    fn takePath(h: *Host, buf: []const u8, len: u64) ?[]const u8 {
        const n: usize = @intCast(@min(len, h.path.len));
        if (n == 0 or n > buf.len) return null;
        @memcpy(h.path[0..n], buf[0..n]);
        const p = h.path[0..n];
        if (std.mem.indexOf(u8, p, "..") != null or std.mem.indexOfScalar(u8, p, 0) != null) return null;
        return p;
    }

    fn serveFs(h: *Host, opts: Options, buf: []u8, req: wire.RunReq, token: u64) void {
        if (opts.fs_chan == 0) return h.refuse(token, 0);
        const chan = opts.fs_chan;
        const fb = opts.fs_buf;
        switch (req) {
            .fs_read => |r| {
                const path = h.takePath(buf, r.len) orelse return h.refuse(token, @intFromEnum(shared.FsErr.not_found));
                // The file lands straight in the data buffer, which is
                // where the answer goes (the path was copied out first).
                const content = fsc.readWhole(chan, fb, path, buf) orelse return h.refuse(token, @intFromEnum(shared.FsErr.not_found));
                h.reply(.{ .text = .{ .len = content.len } }, 0, token);
            },
            .fs_write => |w| {
                const path = h.takePath(buf, w.path_len) orelse return h.refuse(token, @intFromEnum(shared.FsErr.not_found));
                const start: usize = @intCast(w.path_len);
                const n: usize = @intCast(@min(w.data_len, buf.len - start));
                // The text goes out of the data buffer through the view's
                // own buffer, chunk by chunk.
                switch (fscmds.writeFileViaR(chan, fb, path, buf[start .. start + n])) {
                    .ok => h.reply(.ok, 0, token),
                    .err => |e| h.refuse(token, @intFromEnum(e)),
                }
            },
            .fs_list => |l| {
                const path = h.takePath(buf, l.len) orelse return h.refuse(token, @intFromEnum(shared.FsErr.not_found));
                const dir: []const u8 = if (std.mem.eql(u8, path, ".")) "" else path;
                const count = switch (fsc.fsListR(chan, fb, dir)) {
                    .ok => |n| n,
                    .err => |e| return h.refuse(token, @intFromEnum(e)),
                };
                // The names come back in the view's buffer, which the
                // stats below reuse: they move to the data buffer's upper
                // half, and the lines are built in its lower half.
                const half = buf.len / 2;
                const names_len: usize = @intCast(@min(count, half));
                @memcpy(buf[half .. half + names_len], fb[0..names_len]);
                var out: usize = 0;
                var names = std.mem.splitScalar(u8, buf[half .. half + names_len], '\n');
                while (names.next()) |name| {
                    if (name.len == 0) continue;
                    var full: [256]u8 = undefined;
                    const fl = fscmds.joinPath(&full, dir, name);
                    const st = fsc.fsStat(chan, fb, full[0..fl]) orelse continue;
                    const kind: u8 = switch (std.enums.fromInt(shared.FsType, st.typ) orelse .file) {
                        .dir => 'd',
                        .symlink => 'l',
                        .file => 'f',
                    };
                    var line: [300]u8 = undefined;
                    const l2 = std.fmt.bufPrint(&line, "{c} {d} {s}\n", .{ kind, st.size, name }) catch continue;
                    if (out + l2.len > half) break;
                    @memcpy(buf[out .. out + l2.len], l2);
                    out += l2.len;
                }
                h.reply(.{ .text = .{ .len = out } }, 0, token);
            },
            .fs_stat => |s| {
                const path = h.takePath(buf, s.len) orelse return h.refuse(token, @intFromEnum(shared.FsErr.not_found));
                switch (fsc.fsStatR(chan, fb, path)) {
                    .ok => |st| h.reply(.{ .stat = .{ .kind = st.typ, .size = st.size } }, 0, token),
                    .err => |e| h.refuse(token, @intFromEnum(e)),
                }
            },
            else => h.reply(.none, 0, token),
        }
    }

    /// The network requests: the page seam's open/read/cancel, answered
    /// by the web host's broker for this run's client.
    fn serveNet(h: *Host, opts: Options, buf: []u8, req: wire.RunReq, token: u64) void {
        const w = opts.web orelse return h.refuse(token, 0);
        switch (req) {
            .net_open => |o| {
                if (o.off > buf.len or o.len > buf.len - o.off or o.len == 0) return h.refuse(token, @intFromEnum(web.RefuseCode.bad_url));
                const post = o.flags & 1 != 0;
                const body_len: usize = @intCast(@min(o.flags >> 8, buf.len - (o.off + o.len)));
                const url = buf[@intCast(o.off)..@intCast(o.off + o.len)];
                const body = buf[@intCast(o.off + o.len)..@intCast(o.off + o.len + body_len)];
                switch (w.brokerOpen(&h.client, url, post, body, "script")) {
                    .refused => |code| h.refuse(token, @intFromEnum(code)),
                    .opened => |op| {
                        const url_len = @min(op.url.len, buf.len);
                        @memcpy(buf[0..url_len], op.url[0..url_len]);
                        const ct_len = @min(op.ct.len, buf.len - url_len);
                        @memcpy(buf[url_len .. url_len + ct_len], op.ct[0..ct_len]);
                        h.reply(.{ .opened = .{ .status = op.status, .url_len = url_len, .type_len = ct_len } }, 0, token);
                    },
                }
            },
            .net_read => |r| {
                const out = w.brokerRead(&h.client, buf[0..@intCast(@min(r.max, buf.len))], "script");
                h.reply(.{ .chunk = .{ .len = out.len, .done = @intFromEnum(out.end) } }, 0, token);
            },
            .net_cancel => {
                w.brokerCancel(&h.client);
                h.reply(.ok, 0, token);
            },
            else => h.reply(.none, 0, token),
        }
    }

    /// Run `source` in a fresh script domain and wait for its end.
    pub fn run(h: *Host, stage_handle: u64, source: []const u8, opts: Options) Result {
        h.output_len = 0;
        h.text_len = 0;
        h.client = .{};
        defer if (opts.web) |w| {
            w.brokerCancel(&h.client);
            w.dropParked(&h.client);
        };
        const d = usys.shmCreate(wire.data_pages);
        if (d.err != .ok) return .{ .outcome = .refused, .text = "no room for the data buffer", .output = "" };
        defer _ = usys.capDrop(d.data[0]);
        const dm = usys.shmMap(d.data[0]);
        if (dm.err != .ok) return .{ .outcome = .refused, .text = "the data buffer did not map", .output = "" };
        defer _ = usys.shmUnmap(dm.data[0]);
        const buf = @as([*]u8, @ptrFromInt(dm.data[0]))[0 .. dm.data[1] * 4096];
        if (source.len > buf.len) return .{ .outcome = .refused, .text = "the source is larger than the data buffer", .output = "" };
        @memcpy(buf[0..source.len], source);
        var flags: u64 = 0;
        if (opts.fs_chan != 0) flags |= wire.flag_fs;
        if (opts.module) flags |= wire.flag_module;
        if (opts.web != null) flags |= wire.flag_net;

        const badge = h.next_badge;
        h.next_badge += 1;
        const minted = usys.chanMint(h.chan, badge);
        if (minted.err != .ok) return .{ .outcome = .refused, .text = "no channel for the script", .output = "" };
        var sp = usys.spawn(h.spawner, stage_handle, wire.run_arg, minted.data[1], shared.SpawnFlags.grant_log, usys.kbLimits(script_kobj_kb, script_user_kb));
        var tries: usize = 0;
        while (sp.err == .no_space and tries < 50) : (tries += 1) {
            usys.sleepMs(20);
            sp = usys.spawn(h.spawner, stage_handle, wire.run_arg, minted.data[1], shared.SpawnFlags.grant_log, usys.kbLimits(script_kobj_kb, script_user_kb));
        }
        _ = usys.capDrop(minted.data[1]);
        if (sp.err != .ok) {
            logf(h.log, "jshost: spawn refused: {s}", .{@tagName(sp.err)});
            return .{ .outcome = .refused, .text = "the script domain could not be spawned", .output = "" };
        }
        const ctl = sp.data[0];
        defer {
            _ = usys.domainDestroy(ctl);
            _ = usys.capDrop(ctl);
        }
        // Serve the script until it reports its end or dies.
        while (true) {
            const r = usys.recvMsg(h.chan);
            if (r.err == .client_dead) {
                if (r.badge != badge) continue;
                logf(h.log, "jshost: the script died (badge {d})", .{badge});
                return .{ .outcome = .dead, .text = "the script died", .output = h.output[0..h.output_len] };
            }
            if (r.err != .ok) {
                logf(h.log, "jshost: recv failed: {s}", .{@tagName(r.err)});
                return .{ .outcome = .refused, .text = "the host's channel failed", .output = h.output[0..h.output_len] };
            }
            if (r.cap != 0) _ = usys.capDrop(r.cap); // a script sends no caps
            if (r.badge != badge) {
                h.reply(.none, 0, r.token);
                continue;
            }
            const req = shared.decodeMsg(wire.RunReq, r.data) orelse {
                h.reply(.none, 0, r.token);
                continue;
            };
            switch (req) {
                .attach_data => h.reply(.{ .data_buf = .{ .pages = wire.data_pages, .len = source.len, .flags = flags } }, d.data[0], r.token),
                .output => |o| {
                    const n = @min(o.len, buf.len);
                    const room = h.output.len - h.output_len;
                    if (n + 1 <= room) {
                        @memcpy(h.output[h.output_len .. h.output_len + n], buf[0..n]);
                        h.output_len += n;
                        h.output[h.output_len] = '\n';
                        h.output_len += 1;
                    }
                    h.reply(.ok, 0, r.token);
                },
                .done => |dn| {
                    const n = @min(@min(dn.len, buf.len), h.text.len);
                    @memcpy(h.text[0..n], buf[0..n]);
                    h.text_len = n;
                    h.reply(.ok, 0, r.token);
                    return .{ .outcome = if (dn.ok != 0) .ok else .threw, .text = h.text[0..n], .output = h.output[0..h.output_len] };
                },
                .fs_read, .fs_write, .fs_list, .fs_stat => h.serveFs(opts, buf, req, r.token),
                .net_open, .net_read, .net_cancel => h.serveNet(opts, buf, req, r.token),
            }
        }
    }
};

pub fn logf(log: u64, comptime fmt: []const u8, args: anytype) void {
    var line: [256]u8 = undefined;
    _ = usys.log(log, std.fmt.bufPrint(&line, fmt, args) catch fmt);
}
