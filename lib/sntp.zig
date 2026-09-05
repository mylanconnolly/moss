//! SNTP (RFC 4330), the small part of NTP a node needs: a client
//! request, a server reply, and the offset a round trip yields. NTP
//! timestamps are seconds since 1900 with a 32-bit fraction; here they
//! are Unix milliseconds at the edges. Pure and host-tested; the clock
//! service moves the packets over UDP.

const std = @import("std");

pub const packet_len = 48;
/// Seconds between the NTP era (1900) and the Unix one (1970).
pub const era_offset: u64 = 2_208_988_800;

/// A packet's timestamps, as Unix milliseconds (0 when unset).
pub const Reply = struct {
    stratum: u8,
    /// The server's clock: when our request arrived, when its reply left.
    receive_ms: u64,
    transmit_ms: u64,
    /// Our transmit time, echoed (the originate field).
    originate_ms: u64,
};

pub const Error = error{ Bad, KissOfDeath };

fn toNtp(unix_ms: u64) u64 {
    const secs = unix_ms / 1000 + era_offset;
    const frac = ((unix_ms % 1000) << 32) / 1000;
    return (secs << 32) | frac;
}

fn fromNtp(ts: u64) u64 {
    const secs = ts >> 32;
    if (secs < era_offset) return 0;
    const frac = ts & 0xffff_ffff;
    return (secs - era_offset) * 1000 + ((frac * 1000 + (1 << 31)) >> 32); // rounded, not floored
}

fn put64(b: []u8, v: u64) void {
    for (0..8) |i| b[i] = @truncate(v >> @intCast((7 - i) * 8));
}

fn get64(b: []const u8) u64 {
    var v: u64 = 0;
    for (0..8) |i| v |= @as(u64, b[i]) << @intCast((7 - i) * 8);
    return v;
}

/// A client request (version 4, mode 3) carrying our transmit time.
pub fn buildRequest(out: *[packet_len]u8, transmit_ms: u64) void {
    @memset(out, 0);
    out[0] = (4 << 3) | 3; // LI 0, VN 4, mode client
    put64(out[40..48], toNtp(transmit_ms));
}

/// A server reply (mode 4) to a request: the request's transmit time
/// echoed as the originate field, our receive and transmit times.
pub fn buildReply(out: *[packet_len]u8, request: *const [packet_len]u8, stratum: u8, receive_ms: u64, transmit_ms: u64) void {
    @memset(out, 0);
    out[0] = (4 << 3) | 4; // LI 0, VN 4, mode server
    out[1] = stratum;
    out[2] = 6; // poll: 64 s
    out[3] = 0xec; // precision: about a microsecond
    @memcpy(out[12..16], "MOSS"); // the reference id: who we are
    put64(out[16..24], toNtp(transmit_ms)); // reference: the last time we set ours
    @memcpy(out[24..32], request[40..48]); // originate = the client's transmit
    put64(out[32..40], toNtp(receive_ms));
    put64(out[40..48], toNtp(transmit_ms));
}

/// Take a reply apart; a server that says "go away" (stratum 0, a
/// kiss-of-death code) is an error, as is anything but a mode-4 reply.
pub fn parseReply(p: []const u8) Error!Reply {
    if (p.len < packet_len) return error.Bad;
    const mode = p[0] & 7;
    const version = (p[0] >> 3) & 7;
    if (mode != 4 or version < 3 or version > 4) return error.Bad;
    const stratum = p[1];
    if (stratum == 0) return error.KissOfDeath;
    if (stratum > 15) return error.Bad;
    const transmit = get64(p[40..48]);
    if (transmit == 0) return error.Bad;
    return .{
        .stratum = stratum,
        .receive_ms = fromNtp(get64(p[32..40])),
        .transmit_ms = fromNtp(transmit),
        .originate_ms = fromNtp(get64(p[24..32])),
    };
}

/// The clock offset a round trip yields (RFC 4330 §5): what to add to
/// our clock, in milliseconds, given our send and receive times, and
/// the delay, for weighing samples.
pub const Sample = struct { offset_ms: i64, delay_ms: i64 };

pub fn sample(r: Reply, sent_ms: u64, got_ms: u64) Sample {
    const t1: i64 = @intCast(sent_ms);
    const t2: i64 = @intCast(r.receive_ms);
    const t3: i64 = @intCast(r.transmit_ms);
    const t4: i64 = @intCast(got_ms);
    return .{
        .offset_ms = @divTrunc((t2 - t1) + (t3 - t4), 2),
        .delay_ms = @max((t4 - t1) - (t3 - t2), 0),
    };
}

/// The sample to trust of several: the median offset among those
/// with the smallest delays (the best half).
pub fn choose(samples: []const Sample) ?Sample {
    if (samples.len == 0) return null;
    var sorted: [16]Sample = undefined;
    const n = @min(samples.len, sorted.len);
    @memcpy(sorted[0..n], samples[0..n]);
    std.mem.sort(Sample, sorted[0..n], {}, struct {
        fn lt(_: void, a: Sample, b: Sample) bool {
            return a.delay_ms < b.delay_ms;
        }
    }.lt);
    const best = sorted[0 .. (n + 1) / 2];
    std.mem.sort(Sample, best, {}, struct {
        fn lt(_: void, a: Sample, b: Sample) bool {
            return a.offset_ms < b.offset_ms;
        }
    }.lt);
    return best[best.len / 2];
}

test "sntp: timestamps round-trip through the 1900 era with a fraction" {
    try std.testing.expectEqual(@as(u64, 1_700_000_000_500), fromNtp(toNtp(1_700_000_000_500)));
    try std.testing.expectEqual(@as(u64, 0), fromNtp(0));
    try std.testing.expectEqual(era_offset + 1, toNtp(1000) >> 32);
}

test "sntp: a request, a reply, and the offset between two clocks" {
    var req: [packet_len]u8 = undefined;
    buildRequest(&req, 1_000_000);
    try std.testing.expectEqual(@as(u8, 0x23), req[0]);
    // The server's clock runs 5000 ms ahead; the wire takes 20 ms each way.
    var rep: [packet_len]u8 = undefined;
    buildReply(&rep, &req, 2, 1_000_000 + 5000 + 20, 1_000_000 + 5000 + 25);
    const r = try parseReply(&rep);
    try std.testing.expectEqual(@as(u8, 2), r.stratum);
    try std.testing.expectEqual(@as(u64, 1_000_000), r.originate_ms);
    const s = sample(r, 1_000_000, 1_000_000 + 45);
    try std.testing.expectEqual(@as(i64, 5000), s.offset_ms);
    try std.testing.expectEqual(@as(i64, 40), s.delay_ms);
    // Refusals and nonsense.
    rep[1] = 0;
    try std.testing.expectError(error.KissOfDeath, parseReply(&rep));
    rep[1] = 2;
    rep[0] = 0x23;
    try std.testing.expectError(error.Bad, parseReply(&rep));
    try std.testing.expectError(error.Bad, parseReply(rep[0..40]));
}

test "sntp: the median of the best half wins" {
    const samples = [_]Sample{
        .{ .offset_ms = 100, .delay_ms = 400 }, // a slow path, ignored
        .{ .offset_ms = 5, .delay_ms = 10 },
        .{ .offset_ms = 7, .delay_ms = 12 },
        .{ .offset_ms = 6, .delay_ms = 11 },
    };
    try std.testing.expectEqual(@as(i64, 6), choose(&samples).?.offset_ms);
    try std.testing.expect(choose(&.{}) == null);
    try std.testing.expectEqual(@as(i64, 5), choose(samples[1..2]).?.offset_ms);
}
