//! DNS, the wire format (RFC 1035, AAAA per RFC 3596, EDNS0 per RFC
//! 6891): build a query, parse a response, build a response — the
//! codec and nothing else. Transport is the caller's (UDP in netsvc
//! today; over TLS once there is TLS), so is the cache, so is policy.
//! The part of the wider world accepted here is the format itself:
//! labels, compression pointers, the 512-byte legacy that EDNS0 lifts
//! (we advertise 1232, the size that fits every path). Not here, on
//! purpose: search lists, a hosts file, mDNS, DNSSEC, TCP fallback.
//! Addresses come out as the OS's 128-bit words (an A record
//! v4-mapped), names as lowercase text without the trailing dot.

const std = @import("std");

pub const max_msg = 1232;
pub const max_name = 255;

pub const Type = enum(u16) {
    a = 1,
    ns = 2,
    cname = 5,
    soa = 6,
    ptr = 12,
    mx = 15,
    txt = 16,
    aaaa = 28,
    srv = 33,
    opt = 41,
    any = 255,
    _,
};

pub const Rcode = enum(u8) {
    ok = 0,
    formerr = 1,
    servfail = 2,
    nxdomain = 3,
    notimp = 4,
    refused = 5,
    _,
};

pub const Error = error{ OutOfMemory, Bad, TooLong };

/// One record of an answer section.
pub const Record = struct {
    name: []const u8,
    rtype: Type,
    ttl: u32,
    /// The record's data as sent (an address for A/AAAA; a name in
    /// CNAME/NS/PTR is left compressed — `nameAt` reads it).
    data: []const u8,
    /// Where `data` starts in the message, for names inside it.
    at: usize,
};

pub const Response = struct {
    id: u16,
    rcode: Rcode,
    truncated: bool,
    authoritative: bool,
    /// The question echoed back: name and type.
    qname: []const u8,
    qtype: Type,
    answers: []const Record,
    /// Authority and additional records, in order (an OPT among them).
    others: []const Record,
};

// --------------------------------------------------------------- names

/// Write `name` as labels at out[pos..]; the end position. A name is
/// dot-separated labels of 1..63 bytes, at most 255 in all; the root
/// is "" or ".".
pub fn encodeName(out: []u8, pos_in: usize, name: []const u8) Error!usize {
    var pos = pos_in;
    var it = std.mem.splitScalar(u8, std.mem.trimEnd(u8, name, "."), '.');
    var total: usize = 0;
    while (it.next()) |label| {
        if (label.len == 0) {
            if (name.len == 0 or std.mem.eql(u8, name, ".")) break;
            return error.Bad;
        }
        if (label.len > 63) return error.Bad;
        total += label.len + 1;
        if (total > max_name) return error.TooLong;
        if (pos + 1 + label.len >= out.len) return error.TooLong;
        out[pos] = @intCast(label.len);
        for (label, 0..) |c, i| out[pos + 1 + i] = std.ascii.toLower(c);
        pos += 1 + label.len;
    }
    if (pos >= out.len) return error.TooLong;
    out[pos] = 0;
    return pos + 1;
}

const Decoded = struct { text: []const u8, end: usize };

/// Read a (possibly compressed) name at msg[pos..] into fresh memory,
/// lowercase, dots between labels; `end` is where the name's own bytes
/// stop in the message (a pointer counts two).
pub fn decodeName(a: std.mem.Allocator, msg: []const u8, pos_in: usize) Error!Decoded {
    var out: std.ArrayList(u8) = .empty;
    var pos = pos_in;
    var end: ?usize = null;
    var hops: usize = 0;
    while (true) {
        if (pos >= msg.len) return error.Bad;
        const len = msg[pos];
        if (len & 0xc0 == 0xc0) {
            if (pos + 1 >= msg.len) return error.Bad;
            const target = (@as(usize, len & 0x3f) << 8) | msg[pos + 1];
            if (end == null) end = pos + 2;
            if (target >= pos_in and hops == 0) return error.Bad; // forward pointers are not a thing
            hops += 1;
            if (hops > 16) return error.Bad;
            pos = target;
            continue;
        }
        if (len & 0xc0 != 0) return error.Bad;
        pos += 1;
        if (len == 0) {
            if (end == null) end = pos;
            break;
        }
        if (pos + len > msg.len) return error.Bad;
        if (out.items.len > 0) try out.append(a, '.');
        for (msg[pos .. pos + len]) |c| try out.append(a, std.ascii.toLower(c));
        if (out.items.len > max_name) return error.TooLong;
        pos += len;
    }
    return .{ .text = out.items, .end = end.? };
}

/// The name a record's data holds (CNAME, NS, PTR), expanded.
pub fn nameAt(a: std.mem.Allocator, msg: []const u8, r: Record) Error![]const u8 {
    return (try decodeName(a, msg, r.at)).text;
}

// -------------------------------------------------------------- queries

/// A recursive query for one name and type, with an OPT record
/// announcing the payload we accept; the length written.
pub fn buildQuery(out: []u8, id: u16, name: []const u8, qtype: Type) Error!usize {
    if (out.len < 12) return error.TooLong;
    @memset(out[0..12], 0);
    put16(out[0..2], id);
    out[2] = 0x01; // recursion desired
    put16(out[4..6], 1); // one question
    put16(out[10..12], 1); // one additional: OPT
    var pos = try encodeName(out, 12, name);
    if (pos + 4 + 11 > out.len) return error.TooLong;
    put16(out[pos .. pos + 2], @intFromEnum(qtype));
    put16(out[pos + 2 .. pos + 4], 1); // IN
    pos += 4;
    // OPT: root name, type 41, class = payload size, ttl = flags 0, no data.
    out[pos] = 0;
    put16(out[pos + 1 .. pos + 3], @intFromEnum(Type.opt));
    put16(out[pos + 3 .. pos + 5], max_msg);
    @memset(out[pos + 5 .. pos + 9], 0);
    put16(out[pos + 9 .. pos + 11], 0);
    return pos + 11;
}

// ------------------------------------------------------------ responses

/// Take a message apart. The question is read back so a caller can
/// check the answer is to what it asked; records keep their data raw.
pub fn parse(a: std.mem.Allocator, msg: []const u8) Error!Response {
    if (msg.len < 12) return error.Bad;
    const flags = get16(msg[2..4]);
    const qd = get16(msg[4..6]);
    const an = get16(msg[6..8]);
    const ns = get16(msg[8..10]);
    const ar = get16(msg[10..12]);
    var pos: usize = 12;
    var qname: []const u8 = "";
    var qtype: Type = .any;
    for (0..qd) |i| {
        const d = try decodeName(a, msg, pos);
        if (d.end + 4 > msg.len) return error.Bad;
        if (i == 0) {
            qname = d.text;
            qtype = @enumFromInt(get16(msg[d.end .. d.end + 2]));
        }
        pos = d.end + 4;
    }
    var answers: std.ArrayList(Record) = .empty;
    var others: std.ArrayList(Record) = .empty;
    for (0..@as(usize, an) + ns + ar) |i| {
        const d = try decodeName(a, msg, pos);
        if (d.end + 10 > msg.len) return error.Bad;
        const rtype: Type = @enumFromInt(get16(msg[d.end .. d.end + 2]));
        const ttl = get32(msg[d.end + 4 .. d.end + 8]);
        const rdlen = get16(msg[d.end + 8 .. d.end + 10]);
        const at = d.end + 10;
        if (at + rdlen > msg.len) return error.Bad;
        const rec = Record{ .name = d.text, .rtype = rtype, .ttl = ttl, .data = msg[at .. at + rdlen], .at = at };
        try (if (i < an) answers else others).append(a, rec);
        pos = at + rdlen;
    }
    return .{
        .id = get16(msg[0..2]),
        .rcode = @enumFromInt(@as(u8, @truncate(flags & 0xf))),
        .truncated = flags & 0x0200 != 0,
        .authoritative = flags & 0x0400 != 0,
        .qname = qname,
        .qtype = qtype,
        .answers = answers.items,
        .others = others.items,
    };
}

/// An A or AAAA record's address as the OS's words (A v4-mapped).
pub fn addressOf(r: Record) ?[2]u64 {
    switch (r.rtype) {
        .a => {
            if (r.data.len != 4) return null;
            return .{ 0, 0x0000_ffff_0000_0000 | @as(u64, get32(r.data[0..4])) };
        },
        .aaaa => {
            if (r.data.len != 16) return null;
            return .{ get64(r.data[0..8]), get64(r.data[8..16]) };
        },
        else => return null,
    }
}

/// The addresses a response holds for `name` — following a CNAME
/// chain within the same answer section — in answer order, with the
/// smallest TTL among the records used (0 when none).
pub const Addresses = struct { words: []const [2]u64, ttl: u32 };

pub fn addressesFor(a: std.mem.Allocator, msg: []const u8, resp: Response, name: []const u8) Error!Addresses {
    var out: std.ArrayList([2]u64) = .empty;
    var want = name;
    var ttl: u32 = std.math.maxInt(u32);
    var hops: usize = 0;
    while (hops < 8) : (hops += 1) {
        var next: ?[]const u8 = null;
        for (resp.answers) |r| {
            if (!std.ascii.eqlIgnoreCase(r.name, want)) continue;
            if (r.rtype == .cname) {
                next = try nameAt(a, msg, r);
                ttl = @min(ttl, r.ttl);
                continue;
            }
            if (addressOf(r)) |w| {
                try out.append(a, w);
                ttl = @min(ttl, r.ttl);
            }
        }
        if (out.items.len > 0 or next == null) break;
        want = next.?;
    }
    return .{ .words = out.items, .ttl = if (out.items.len == 0) 0 else ttl };
}

// ------------------------------------------------------------ answering

/// Build a response for an authoritative server: the question echoed,
/// then address records for it (each `words` an A when v4-mapped, an
/// AAAA otherwise), or an empty answer with `rcode`.
pub fn buildResponse(out: []u8, id: u16, name: []const u8, qtype: Type, rcode: Rcode, words: []const [2]u64, ttl: u32) Error!usize {
    if (out.len < 12) return error.TooLong;
    @memset(out[0..12], 0);
    put16(out[0..2], id);
    out[2] = 0x84; // a response, authoritative
    out[3] = @intFromEnum(rcode);
    put16(out[4..6], 1);
    var pos = try encodeName(out, 12, name);
    if (pos + 4 > out.len) return error.TooLong;
    put16(out[pos .. pos + 2], @intFromEnum(qtype));
    put16(out[pos + 2 .. pos + 4], 1);
    pos += 4;
    var count: u16 = 0;
    for (words) |w| {
        const v4 = w[0] == 0 and (w[1] >> 32) == 0x0000_ffff;
        const rtype: Type = if (v4) .a else .aaaa;
        if (qtype != rtype and qtype != .any) continue;
        const rdlen: usize = if (v4) 4 else 16;
        if (pos + 2 + 10 + rdlen > out.len) return error.TooLong;
        put16(out[pos .. pos + 2], 0xc00c); // the question's name
        put16(out[pos + 2 .. pos + 4], @intFromEnum(rtype));
        put16(out[pos + 4 .. pos + 6], 1);
        put32(out[pos + 6 .. pos + 10], ttl);
        put16(out[pos + 10 .. pos + 12], @intCast(rdlen));
        pos += 12;
        if (v4) {
            put32(out[pos .. pos + 4], @truncate(w[1]));
        } else {
            put64(out[pos .. pos + 8], w[0]);
            put64(out[pos + 8 .. pos + 16], w[1]);
        }
        pos += rdlen;
        count += 1;
    }
    put16(out[6..8], count);
    return pos;
}

// ------------------------------------------------------------ utilities

fn get16(b: []const u8) u16 {
    return (@as(u16, b[0]) << 8) | b[1];
}

fn get32(b: []const u8) u32 {
    return (@as(u32, b[0]) << 24) | (@as(u32, b[1]) << 16) | (@as(u32, b[2]) << 8) | b[3];
}

fn get64(b: []const u8) u64 {
    return (@as(u64, get32(b[0..4])) << 32) | get32(b[4..8]);
}

fn put16(b: []u8, v: u16) void {
    b[0] = @truncate(v >> 8);
    b[1] = @truncate(v);
}

fn put32(b: []u8, v: u32) void {
    b[0] = @truncate(v >> 24);
    b[1] = @truncate(v >> 16);
    b[2] = @truncate(v >> 8);
    b[3] = @truncate(v);
}

fn put64(b: []u8, v: u64) void {
    put32(b[0..4], @truncate(v >> 32));
    put32(b[4..8], @truncate(v));
}

// ----------------------------------------------------------------- tests

test "dns: a query is a header, a question and an OPT record" {
    var buf: [128]u8 = undefined;
    const n = try buildQuery(&buf, 0x1234, "Example.COM.", .aaaa);
    const want = [_]u8{
        0x12, 0x34, 0x01, 0x00, 0,   1,   0,   0,   0,    0,    0,   1,
        7,    'e',  'x',  'a',  'm', 'p', 'l', 'e', 3,    'c',  'o', 'm',
        0,    0,    28,   0,    1,   0,   0,   41,  0x04, 0xd0, 0,   0,
        0,    0,    0,    0,
    };
    try std.testing.expectEqualSlices(u8, &want, buf[0..n]);
    try std.testing.expectError(error.Bad, buildQuery(&buf, 1, "a..b", .a));
    try std.testing.expectError(error.Bad, buildQuery(&buf, 1, "a" ** 64, .a));
    var tiny: [20]u8 = undefined;
    try std.testing.expectError(error.TooLong, buildQuery(&tiny, 1, "example.com", .a));
}

test "dns: a response with compression, a CNAME chain, and both address kinds" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // www.example.com CNAME example.com; example.com A 93.184.216.34, AAAA 2606:2800:220:1:248:1893:25c8:1946
    const msg = [_]u8{
        0xbe, 0xef, 0x81, 0x80, 0, 1,   0,   3,   0,   0,   0,   1,
        3,    'w',  'w',  'w',  7, 'e', 'x', 'a', 'm', 'p', 'l', 'e',
        3,    'c',  'o',  'm',  0, 0,   1,   0,   1,
        0xc0, 0x0c, 0,    5,    0,    1,    0,    0,    0x0e, 0x10, 0,    2,    0xc0, 0x10, // www -> example.com (pointer into the question)
        0xc0, 0x10, 0,    1,    0,    1,    0,    0,    0x00, 0x3c, 0,    4,    93,   184,
        216,  34,   0xc0, 0x10, 0,    28,   0,    1,    0,    0,    0x00, 0x78, 0,    16,
        0x26, 0x06, 0x28, 0x00, 0x02, 0x20, 0x00, 0x01, 0x02, 0x48, 0x18, 0x93, 0x25, 0xc8,
        0x19, 0x46,
        0, 0, 41, 0x10, 0, 0, 0, 0, 0, 0, 0, // OPT
    };
    const r = try parse(a, &msg);
    try std.testing.expectEqual(@as(u16, 0xbeef), r.id);
    try std.testing.expect(r.rcode == .ok and !r.truncated and !r.authoritative);
    try std.testing.expectEqualStrings("www.example.com", r.qname);
    try std.testing.expect(r.qtype == .a);
    try std.testing.expectEqual(@as(usize, 3), r.answers.len);
    try std.testing.expectEqualStrings("www.example.com", r.answers[0].name);
    try std.testing.expectEqualStrings("example.com", try nameAt(a, &msg, r.answers[0]));
    try std.testing.expectEqualStrings("example.com", r.answers[1].name);
    try std.testing.expectEqual(@as(usize, 1), r.others.len);
    try std.testing.expect(r.others[0].rtype == .opt);
    const addrs = try addressesFor(a, &msg, r, "WWW.example.com");
    try std.testing.expectEqual(@as(usize, 2), addrs.words.len);
    try std.testing.expectEqual([2]u64{ 0, 0x0000_ffff_5db8_d822 }, addrs.words[0]);
    try std.testing.expectEqual([2]u64{ 0x2606_2800_0220_0001, 0x0248_1893_25c8_1946 }, addrs.words[1]);
    try std.testing.expectEqual(@as(u32, 60), addrs.ttl); // the smallest along the chain
    const none = try addressesFor(a, &msg, r, "other.example.com");
    try std.testing.expectEqual(@as(usize, 0), none.words.len);
    // Malformed: a pointer loop, a truncated record, a forward pointer.
    var loop = msg;
    loop[12] = 0xc0;
    loop[13] = 0x0c;
    try std.testing.expectError(error.Bad, parse(a, &loop));
    try std.testing.expectError(error.Bad, parse(a, msg[0 .. msg.len - 20]));
    var fwd = msg;
    fwd[12] = 0xc0;
    fwd[13] = 0x20;
    try std.testing.expectError(error.Bad, parse(a, &fwd));
}

test "dns: an authoritative answer round-trips, and says nxdomain" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var buf: [256]u8 = undefined;
    const words = [_][2]u64{ .{ 0, 0x0000_ffff_0a4d_0002 }, .{ 0xfdcc_0000_0000_0000, 2 } };
    const n = try buildResponse(&buf, 7, "node2.moss.test", .aaaa, .ok, &words, 300);
    const r = try parse(a, buf[0..n]);
    try std.testing.expect(r.authoritative and r.rcode == .ok);
    try std.testing.expectEqualStrings("node2.moss.test", r.qname);
    try std.testing.expectEqual(@as(usize, 1), r.answers.len); // only the AAAA for an AAAA question
    const addrs = try addressesFor(a, buf[0..n], r, "node2.moss.test");
    try std.testing.expectEqual(words[1], addrs.words[0]);
    try std.testing.expectEqual(@as(u32, 300), addrs.ttl);
    const m = try buildResponse(&buf, 8, "node2.moss.test", .any, .ok, &words, 300);
    try std.testing.expectEqual(@as(usize, 2), (try parse(a, buf[0..m])).answers.len);
    const k = try buildResponse(&buf, 9, "nope.moss.test", .a, .nxdomain, &.{}, 0);
    const nx = try parse(a, buf[0..k]);
    try std.testing.expect(nx.rcode == .nxdomain);
    try std.testing.expectEqual(@as(usize, 0), nx.answers.len);
}
