//! The script domain's host: spawns `jsrun` from a staged image with one
//! badged calling end of its channel, hands it the source through a
//! shared buffer, collects its `print` lines and its ending, and
//! destroys it. One run at a time; the caller sees only the outcome.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const wire = shared.js;

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

    /// Run `source` in a fresh script domain and wait for its end.
    pub fn run(h: *Host, stage_handle: u64, source: []const u8) Result {
        h.output_len = 0;
        h.text_len = 0;
        const d = usys.shmCreate(wire.data_pages);
        if (d.err != .ok) return .{ .outcome = .refused, .text = "no room for the data buffer", .output = "" };
        defer _ = usys.capDrop(d.data[0]);
        const dm = usys.shmMap(d.data[0]);
        if (dm.err != .ok) return .{ .outcome = .refused, .text = "the data buffer did not map", .output = "" };
        defer _ = usys.shmUnmap(dm.data[0]);
        const buf = @as([*]u8, @ptrFromInt(dm.data[0]))[0 .. dm.data[1] * 4096];
        if (source.len > buf.len) return .{ .outcome = .refused, .text = "the source is larger than the data buffer", .output = "" };
        @memcpy(buf[0..source.len], source);

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
                _ = usys.replyTypedTo(wire.HostResp, h.chan, .none, 0, r.token);
                continue;
            }
            const req = shared.decodeMsg(wire.RunReq, r.data) orelse {
                _ = usys.replyTypedTo(wire.HostResp, h.chan, .none, 0, r.token);
                continue;
            };
            switch (req) {
                .attach_data => _ = usys.replyTypedTo(wire.HostResp, h.chan, .{ .data_buf = .{ .pages = wire.data_pages, .len = source.len } }, d.data[0], r.token),
                .output => |o| {
                    const n = @min(o.len, buf.len);
                    const room = h.output.len - h.output_len;
                    if (n + 1 <= room) {
                        @memcpy(h.output[h.output_len .. h.output_len + n], buf[0..n]);
                        h.output_len += n;
                        h.output[h.output_len] = '\n';
                        h.output_len += 1;
                    }
                    _ = usys.replyTypedTo(wire.HostResp, h.chan, .ok, 0, r.token);
                },
                .done => |dn| {
                    const n = @min(@min(dn.len, buf.len), h.text.len);
                    @memcpy(h.text[0..n], buf[0..n]);
                    h.text_len = n;
                    _ = usys.replyTypedTo(wire.HostResp, h.chan, .ok, 0, r.token);
                    return .{ .outcome = if (dn.ok != 0) .ok else .threw, .text = h.text[0..n], .output = h.output[0..h.output_len] };
                },
            }
        }
    }
};

pub fn logf(log: u64, comptime fmt: []const u8, args: anytype) void {
    var line: [256]u8 = undefined;
    _ = usys.log(log, std.fmt.bufPrint(&line, fmt, args) catch fmt);
}
