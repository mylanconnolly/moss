//! dnsd — an authoritative name server for one zone, the OS's own
//! names: `conf/dns.msh` (given to the unit as a file) says the zone,
//! a TTL, and each name's addresses; the server binds UDP 53 on its
//! network view and answers A and AAAA questions from that, NXDOMAIN
//! for a name it does not have, and refuses anything else. It is the
//! resolver's first stop on a node (see conf/net.msh), the fabric's
//! way to a name instead of `10.77.0.N`, and the gate's hermetic
//! upstream. One thread, one question at a time; a datagram nobody
//! could ever wait for.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const netcmds = @import("netcmds.zig");
const mosslib = @import("mosslib");
const dns = mosslib.dns;
const mshl = mosslib.mshl;

comptime {
    asm (usys.imageHeader("dnsd"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    var buf: [200]u8 = undefined;
    const pre = "dnsd: panic: ";
    @memcpy(buf[0..pre.len], pre);
    const n = @min(msg.len, buf.len - pre.len);
    @memcpy(buf[pre.len .. pre.len + n], msg[0..n]);
    _ = usys.log(glog, buf[0 .. pre.len + n]);
    usys.exit(255);
}

var glog: u64 = 0;

const max_names = 32;
const max_addrs = 4;
const Name = struct { label: []const u8, words: [max_addrs][2]u64, n: usize };

var zone: []const u8 = "";
var ttl: u32 = 300;
var names: [max_names]Name = undefined;
var n_names: usize = 0;
/// The fabric front channel, when the unit was given one (the cluster
/// dnsd). Zero for the plain net-drill dnsd, which serves the static
/// zone alone.
var fab_chan: u64 = 0;
/// The zone file's values live here for the life of the server.
var zone_mem: [8 << 10]u8 = undefined;

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const mshl.Value, _: ?mshl.Value) mshl.Error!?mshl.Value {
    return null;
}

fn fail(msg: []const u8) noreturn {
    _ = usys.log(glog, msg);
    usys.exit(1);
}

/// `{ zone: moss.test, ttl: 300, names: { www: [::1], node1: [a, b] } }`
fn readZone(text: []const u8) void {
    var fba = std.heap.FixedBufferAllocator.init(&zone_mem);
    const a = fba.allocator();
    var ctx: u8 = 0;
    var it = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&ctx), .call = noHost });
    const v = it.parseData(text) catch fail("dnsd: the zone file is not data");
    if (v != .record) fail("dnsd: the zone file is not a record");
    const z = v.record.get("zone") orelse fail("dnsd: the zone has no name");
    if (z != .str) fail("dnsd: zone: a name expected");
    zone = z.str;
    if (v.record.get("ttl")) |t| {
        if (t == .int and t.int > 0) ttl = @intCast(@min(t.int, 86400));
    }
    const list = v.record.get("names") orelse fail("dnsd: the zone has no names");
    if (list != .record) fail("dnsd: names: a record expected");
    for (list.record.keys, list.record.vals) |k, val| {
        if (n_names == max_names) break;
        var name = Name{ .label = k, .words = undefined, .n = 0 };
        const addrs: []const mshl.Value = switch (val) {
            .list => |l| l,
            .str => &.{val},
            else => continue,
        };
        for (addrs) |item| {
            if (item != .str or name.n == max_addrs) continue;
            name.words[name.n] = shared.parseAddr(item.str) orelse continue;
            name.n += 1;
        }
        names[n_names] = name;
        n_names += 1;
    }
}

/// Is the name in our zone at all? (`moss.test` itself, or `x.moss.test`.)
fn inZone(qname: []const u8) bool {
    if (qname.len < zone.len or !std.ascii.eqlIgnoreCase(qname[qname.len - zone.len ..], zone)) return false;
    const head = qname[0 .. qname.len - zone.len];
    return head.len == 0 or head[head.len - 1] == '.';
}

/// The single label of an in-zone name, without the trailing dot;
/// null if it carries a further subdomain (`a.b.moss.test`) or is the
/// apex. `node1.moss.test` -> `node1`.
fn zoneLabel(qname: []const u8) ?[]const u8 {
    if (!inZone(qname)) return null;
    const head = qname[0 .. qname.len - zone.len];
    if (head.len == 0) return null;
    const label = head[0 .. head.len - 1]; // drop the '.' inZone guaranteed
    if (label.len == 0 or std.mem.indexOfScalar(u8, label, '.') != null) return null;
    return label;
}

/// `nodeN.moss.test` -> N, for a plain decimal N in range; null for any
/// other name. This is the dynamic overlay's trigger: only these names
/// consult the fabric's live membership.
fn nodeIdOf(qname: []const u8) ?u64 {
    const label = zoneLabel(qname) orelse return null;
    if (label.len <= 4 or !std.ascii.eqlIgnoreCase(label[0..4], "node")) return null;
    var v: u64 = 0;
    for (label[4..]) |c| {
        if (c < '0' or c > '9') return null;
        v = v * 10 + (c - '0');
        if (v > 0xffff) return null;
    }
    return v;
}

const MemberState = enum { unknown, down, up };

/// Ask our node's fabric service what it currently believes about node
/// N. A single-word RPC (no shared buffer), so it cannot race the
/// members-listing buffer other clients attach.
fn memberState(node: u64) MemberState {
    if (fab_chan == 0) return .unknown;
    return switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .{ .member_state = .{ .node = node } }, 0)) {
        .ok => |rep| switch (rep) {
            .num => |x| switch (x.n) {
                2 => .up,
                1 => .down,
                else => .unknown,
            },
            else => .unknown,
        },
        .err => .unknown,
    };
}

/// The cluster addresses of node N, by the same convention netsvc
/// assigns itself: A = 10.77.0.N (v4-mapped), AAAA = fdcc::N. Built
/// directly as the OS's address words — no text round-trip, so the
/// hex-vs-decimal trap of `fdcc::10` never arises.
fn synthNode(node: u64, out: *[2][2]u64) []const [2]u64 {
    out[0] = shared.v4Words(shared.nodeIp4(node));
    out[1] = .{ 0xfdcc_0000_0000_0000, node };
    return out[0..2];
}

/// `www.moss.test` → the entry `www`; the zone apex itself is `@`.
fn lookup(qname: []const u8) ?*const Name {
    if (!inZone(qname)) return null;
    const head = qname[0 .. qname.len - zone.len];
    const label = if (head.len == 0) "@" else head[0 .. head.len - 1];
    for (names[0..n_names]) |*n| {
        if (std.ascii.eqlIgnoreCase(n.label, label)) return n;
    }
    return null;
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.net)) fail("dnsd: no network view");
    readZone(setup.data());
    if (setup.has(.fabric)) fab_chan = setup.cap(.fabric);
    var net = netcmds.Net.init(setup.cap(.net));
    const sock = switch (net.udpBindRaw(53)) {
        .sock => |s| s,
        .failed => |m| fail(m),
    };
    var line: [128]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&line, "dnsd: serving {s} ({d} names{s}) on udp 53", .{ zone, n_names, if (fab_chan != 0) ", + live members" else "" }) catch "dnsd: serving");

    var scratch: [4 << 10]u8 = undefined;
    while (true) {
        const d = switch (net.udpRecvRaw(sock)) {
            .datagram => |x| x,
            .failed => |m| fail(m),
        };
        var fba = std.heap.FixedBufferAllocator.init(&scratch);
        const q = dns.parse(fba.allocator(), d.data) catch continue;
        if (q.qname.len == 0) continue;
        var out: [512]u8 = undefined;
        // Ours: an answer, or NXDOMAIN. Not ours: REFUSED, so a resolver
        // asking us first moves on to the next server.
        const n = blk: {
            // Dynamic overlay: with a fabric view, a `nodeN.moss.test`
            // name tracks live membership — an up member answers the
            // cluster address, a member we have seen but that is now down
            // is NXDOMAIN, and a node the fabric has never heard of falls
            // through to whatever the static zone says (bootstrap, and the
            // plain net-drill dnsd, are unaffected).
            if (nodeIdOf(q.qname)) |node| {
                switch (memberState(node)) {
                    .up => {
                        var words: [2][2]u64 = undefined;
                        const w = synthNode(node, &words);
                        if (q.qtype == .a or q.qtype == .aaaa or q.qtype == .any) {
                            break :blk dns.buildResponse(&out, q.id, q.qname, q.qtype, .ok, w, ttl) catch continue;
                        }
                        break :blk dns.buildResponse(&out, q.id, q.qname, q.qtype, .notimp, &.{}, 0) catch continue;
                    },
                    .down => break :blk dns.buildResponse(&out, q.id, q.qname, q.qtype, .nxdomain, &.{}, 0) catch continue,
                    .unknown => {},
                }
            }
            if (lookup(q.qname)) |name| {
                if (q.qtype == .a or q.qtype == .aaaa or q.qtype == .any) {
                    break :blk dns.buildResponse(&out, q.id, q.qname, q.qtype, .ok, name.words[0..name.n], ttl) catch continue;
                }
                break :blk dns.buildResponse(&out, q.id, q.qname, q.qtype, .notimp, &.{}, 0) catch continue;
            }
            const rcode: dns.Rcode = if (inZone(q.qname)) .nxdomain else .refused;
            break :blk dns.buildResponse(&out, q.id, q.qname, q.qtype, rcode, &.{}, 0) catch continue;
        };
        _ = net.udpSendRaw(sock, d.from, d.port, out[0..n]);
    }
}
