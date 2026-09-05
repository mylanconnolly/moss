//! clock — the time service. The kernel learned the time of boot from
//! the machine's real-time clock, if it has one; this service refines
//! it over the network (SNTP, RFC 4330) and, holding the `clock`
//! grant, sets it (clock_set); and it serves SNTP itself on UDP 123, so
//! a node with no clock and no way out learns the time from a peer —
//! the fabric's time comes from the fabric. Settings (`conf/clock.msh`,
//! given as a file): the servers to ask, in order, whether to serve,
//! and how often to ask again. One loop over two datagram sockets on
//! one doorbell: while a question of ours is out, peers' questions are
//! still answered (in the drill the server is this very process, over
//! loopback).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const netcmds = @import("netcmds.zig");
const syscmds = @import("syscmds.zig");
const mosslib = @import("mosslib");
const sntp = mosslib.sntp;
const civil = mosslib.civil;
const mshl = mosslib.mshl;

comptime {
    asm (usys.imageHeader("clock"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    var buf: [200]u8 = undefined;
    const pre = "clock: panic: ";
    @memcpy(buf[0..pre.len], pre);
    const n = @min(msg.len, buf.len - pre.len);
    @memcpy(buf[pre.len .. pre.len + n], msg[0..n]);
    _ = usys.log(glog, buf[0 .. pre.len + n]);
    usys.exit(255);
}

var glog: u64 = 0;
/// Grants land in slot order: log (0), the boot channel (1), clock (2).
const clock_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

const max_servers = 4;
var servers: [max_servers][]const u8 = undefined;
var n_servers: usize = 0;
var serve = true;
var interval_s: u64 = 3600;
var settings_mem: [4 << 10]u8 = undefined;

const samples_per_server = 4;
const reply_wait_ms: u64 = 1000;
/// A server whose clock is this far from ours is still believed; the
/// RTC is trusted to the hour, so an offset beyond a day is a lie.
const max_offset_ms: i64 = 86_400_000;

var net: netcmds.Net = undefined;
var server_sock: ?u64 = null;

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const mshl.Value, _: ?mshl.Value) mshl.Error!?mshl.Value {
    return null;
}

fn readSettings(text: []const u8) void {
    if (text.len == 0) return;
    var fba = std.heap.FixedBufferAllocator.init(&settings_mem);
    const a = fba.allocator();
    var ctx: u8 = 0;
    var it = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&ctx), .call = noHost });
    const v = it.parseData(text) catch return;
    if (v != .record) return;
    if (v.record.get("servers")) |list| {
        if (list == .list) for (list.list) |item| {
            if (item == .str and n_servers < max_servers) {
                servers[n_servers] = item.str;
                n_servers += 1;
            }
        };
    }
    if (v.record.get("serve")) |s| serve = s.asBool();
    if (v.record.get("interval")) |i| {
        if (i == .int and i.int >= 10) interval_s = @intCast(i.int);
    }
}

fn logLine(comptime fmt: []const u8, args: anytype) void {
    var buf: [200]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&buf, fmt, args) catch "clock: (a line too long to log)");
}

fn isoNow(buf: []u8) []const u8 {
    const ms = usys.wallMs() orelse return "unknown";
    return civil.isoText(buf, @intCast(ms / 1000));
}

/// Answer one SNTP question with our clock; nothing when we have none.
fn answer(d: netcmds.Net.Dgram) void {
    const s = server_sock orelse return;
    if (d.data.len < sntp.packet_len or (d.data[0] & 7) != 3) return; // a client's question only
    const now = usys.wallMs() orelse return;
    var req: [sntp.packet_len]u8 = undefined;
    @memcpy(&req, d.data[0..sntp.packet_len]);
    var rep: [sntp.packet_len]u8 = undefined;
    const stratum: u8 = if (usys.clockGet().source == .set) 3 else 2;
    sntp.buildReply(&rep, &req, stratum, now, usys.wallMs() orelse now);
    _ = net.udpSendRaw(s, d.from, d.port, &rep);
}

/// Drain the server socket: every waiting question answered.
fn serveWaiting() void {
    const s = server_sock orelse return;
    while (net.udpTryRecvRaw(s)) |d| answer(d);
}

/// One exchange with a server: the sample it yields, or null.
fn ask(client: u64, to: [2]u64) ?sntp.Sample {
    const sent = usys.wallMs() orelse return null;
    var req: [sntp.packet_len]u8 = undefined;
    sntp.buildRequest(&req, sent);
    if (net.udpSendRaw(client, to, 123, &req) != null) return null;
    const start = syscmds.nowMs();
    while (syscmds.nowMs() - start < @as(i64, @intCast(reply_wait_ms))) {
        // Our own questions may be to ourselves: keep serving meanwhile.
        serveWaiting();
        if (net.udpTryRecvRaw(client)) |d| {
            if (d.port != 123 or d.from[0] != to[0] or d.from[1] != to[1]) continue;
            const got = usys.wallMs() orelse return null;
            const r = sntp.parseReply(d.data) catch continue;
            if (r.originate_ms != sent) continue; // not an answer to this question
            return sntp.sample(r, sent, got);
        }
        _ = net.waitFor(reply_wait_ms);
    }
    return null;
}

/// Ask each server in turn until one answers well; set the clock by
/// the median of its best samples.
fn sync(client: u64) void {
    for (servers[0..n_servers]) |name| {
        const addrs = switch (net.addressesOf(name)) {
            .addresses => |r| r,
            .failed => |m| {
                logLine("clock: {s}: {s}", .{ name, m });
                continue;
            },
        };
        for (addrs.words[0..addrs.n]) |to| {
            var samples: [samples_per_server]sntp.Sample = undefined;
            var n: usize = 0;
            // An address that never answers the first question is left
            // after that one (an IPv6 address behind a gateway that
            // cannot route it); the rest of the questions go to one that does.
            for (0..samples_per_server) |_| {
                if (ask(client, to)) |s| {
                    samples[n] = s;
                    n += 1;
                } else if (n == 0) break;
            }
            const best = sntp.choose(samples[0..n]) orelse continue;
            if (best.offset_ms > max_offset_ms or best.offset_ms < -max_offset_ms) {
                logLine("clock: {s} is {d} ms away; not believed", .{ name, best.offset_ms });
                continue;
            }
            const c = usys.clockGet();
            const epoch: i64 = @as(i64, @intCast(c.boot_epoch_ms)) + best.offset_ms;
            if (usys.clockSet(clock_h, @intCast(@max(epoch, 0))) != .ok) {
                logLine("clock: the kernel refused clock_set (no grant?)", .{});
                return;
            }
            var when: [24]u8 = undefined;
            logLine("clock: synced from {s}: offset {d} ms, delay {d} ms, {d} samples; now {s}", .{ name, best.offset_ms, best.delay_ms, n, isoNow(&when) });
            return;
        }
    }
    if (n_servers > 0) logLine("clock: no server answered", .{});
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    readSettings(setup.data());
    {
        var when: [24]u8 = undefined;
        const c = usys.clockGet();
        logLine("clock: at boot the kernel says {s} ({s})", .{ isoNow(&when), @tagName(c.source) });
    }
    if (!setup.has(.net)) {
        logLine("clock: no network view; the RTC's time stands", .{});
        while (true) usys.sleepMs(60_000);
    }
    net = netcmds.Net.init(setup.cap(.net));
    if (serve) {
        server_sock = switch (net.udpBindRaw(123)) {
            .sock => |s| s,
            .failed => |m| blk: {
                logLine("clock: cannot serve sntp: {s}", .{m});
                break :blk null;
            },
        };
    }
    const client = switch (net.udpBindRaw(0)) {
        .sock => |s| s,
        .failed => |m| {
            logLine("clock: no client socket: {s}", .{m});
            usys.exit(1);
        },
    };
    if (n_servers > 0 and usys.wallMs() == null) logLine("clock: no RTC; asking the network", .{});
    // Serving whoever asks, asking again every interval; a machine with
    // no RTC keeps asking until someone answers.
    var last_sync: ?i64 = null;
    while (true) {
        const now = syscmds.nowMs();
        const due: i64 = if (usys.wallMs() == null) 30_000 else @intCast(interval_s * 1000);
        if (n_servers > 0 and (last_sync == null or now - last_sync.? >= due)) {
            sync(client);
            last_sync = syscmds.nowMs();
        }
        serveWaiting();
        // Sleep until a datagram or a tenth of the interval, whichever first.
        _ = net.waitFor(@max(interval_s * 100, 1000));
    }
}
