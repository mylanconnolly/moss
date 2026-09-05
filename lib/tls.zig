//! TLS for moss programs: the standard library's TLS 1.3 client, run
//! over a transport the host provides (a socket's send and receive),
//! verifying the server against trust roots parsed from PEM text.
//! Nothing here touches a socket, a clock or an entropy source: the
//! host passes bytes in and out, the time, and the random bytes the
//! handshake needs, so the whole thing is host-testable and the same
//! on every port.
//!
//! A `Session` owns every buffer the client needs (four of a TLS
//! record each), so a host keeps a static table of them and hands one
//! to a connection; a `Roots` is a certificate bundle a host loads once
//! from the PEM it was given and shares among sessions.

const std = @import("std");
const tls = std.crypto.tls;
const Client = tls.Client;
const Certificate = std.crypto.Certificate;
const Reader = std.Io.Reader;
const Writer = std.Io.Writer;
const Allocator = std.mem.Allocator;

/// How a session reaches the wire. `send` sends every byte and answers
/// null, or the reason it could not; `recv` fills some of `buf`.
pub const Transport = struct {
    ctx: *anyopaque,
    send: *const fn (ctx: *anyopaque, data: []const u8) ?[]const u8,
    recv: *const fn (ctx: *anyopaque, buf: []u8) RecvOut,
};

pub const RecvOut = union(enum) { n: usize, closed, failed: []const u8 };

/// The random bytes a handshake consumes.
pub const entropy_len = Client.Options.entropy_len;

// ------------------------------------------------------------------ roots

/// The certificates a session trusts: a bundle built from PEM text.
pub const Roots = struct {
    bundle: Certificate.Bundle = .empty,
    lock: std.Io.RwLock = .init,
    /// The allocator the bundle grew with (the client's option wants one).
    gpa: Allocator = undefined,

    pub const AddError = Allocator.Error || error{ MissingEndCertificateMarker, BadBase64, CertificateTooBig };

    /// Add every `-----BEGIN CERTIFICATE-----` block of `pem`; one that
    /// does not parse, or has expired by `now_sec`, is left out. The
    /// count of those kept.
    pub fn add(r: *Roots, gpa: Allocator, pem: []const u8, now_sec: i64) AddError!usize {
        r.gpa = gpa;
        const begin_marker = "-----BEGIN CERTIFICATE-----";
        const end_marker = "-----END CERTIFICATE-----";
        const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
        // Room for everything decoded, reserved once: an arena never
        // has to grow the bytes and copy (a fixed buffer cannot).
        try r.bundle.bytes.ensureUnusedCapacity(gpa, pem.len / 4 * 3 + 3);
        var added: usize = 0;
        var start: usize = 0;
        while (std.mem.findPos(u8, pem, start, begin_marker)) |b| {
            const cert_start = b + begin_marker.len;
            const cert_end = std.mem.findPos(u8, pem, cert_start, end_marker) orelse return error.MissingEndCertificateMarker;
            start = cert_end + end_marker.len;
            const encoded = std.mem.trim(u8, pem[cert_start..cert_end], " \t\r\n");
            const upper = encoded.len / 4 * 3 + 3;
            try r.bundle.bytes.ensureUnusedCapacity(gpa, upper);
            const decoded_start = std.math.cast(u32, r.bundle.bytes.items.len) orelse return error.CertificateTooBig;
            const dest = r.bundle.bytes.allocatedSlice()[decoded_start..];
            const n = base64.decode(dest, encoded) catch return error.BadBase64;
            r.bundle.bytes.items.len += n;
            const before = r.bundle.map.count();
            r.bundle.parseCert(gpa, decoded_start, now_sec) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                else => {
                    r.bundle.bytes.items.len = decoded_start;
                    continue;
                },
            };
            if (r.bundle.map.count() > before) added += 1;
        }
        return added;
    }

    pub fn count(r: *const Roots) usize {
        return r.bundle.map.count();
    }

    pub fn deinit(r: *Roots, gpa: Allocator) void {
        r.bundle.deinit(gpa);
        r.* = .{};
    }
};

// ---------------------------------------------------------------- session

/// Every buffer a client needs is a record long.
pub const buf_len = Client.min_buffer_len;

pub const Session = struct {
    transport: Transport = undefined,
    /// The wire side: what the client reads records from and writes
    /// them to, over the transport.
    sock_reader: Reader = undefined,
    sock_writer: Writer = undefined,
    client: Client = undefined,
    /// The transport's last reason, when it failed under the client.
    wire_err: ?[]const u8 = null,
    open: bool = false,
    in_buf: [buf_len]u8 = undefined,
    out_buf: [buf_len]u8 = undefined,
    read_buf: [buf_len]u8 = undefined,
    write_buf: [4096]u8 = undefined,
    alert: tls.Alert = undefined,
    got_alert: bool = false,
    fail_word: []const u8 = "failed",

    pub const Options = struct {
        /// The name the certificate must be for (also the SNI sent).
        host: []const u8,
        roots: *Roots,
        entropy: *const [entropy_len]u8,
        /// The wall clock, for the certificates' validity.
        now_ms: u64,
    };

    pub const Error = error{ Failed, Closed };

    /// The handshake: on failure the reason is `reason()`.
    pub fn connect(s: *Session, transport: Transport, o: Options) Error!void {
        s.transport = transport;
        s.wire_err = null;
        s.open = false;
        s.sock_reader = .{ .buffer = &s.in_buf, .seek = 0, .end = 0, .vtable = &.{ .stream = sockStream } };
        s.sock_writer = .{ .buffer = &s.out_buf, .vtable = &.{ .drain = sockDrain } };
        s.got_alert = false;
        s.client = Client.init(&s.sock_reader, &s.sock_writer, .{
            .host = .{ .explicit = o.host },
            // The lock is never contended (one thread per host) and the
            // io is only reached to fetch a missing root from the OS,
            // which the client never does off a real OS: neither is used.
            .ca = .{ .bundle = .{ .gpa = o.roots.gpa, .io = undefined, .lock = &o.roots.lock, .bundle = &o.roots.bundle } },
            .write_buffer = &s.write_buf,
            .read_buffer = &s.read_buf,
            .entropy = o.entropy,
            .realtime_now = .{ .nanoseconds = @as(i96, o.now_ms) * std.time.ns_per_ms },
            .alert = &s.alert,
        }) catch |e| {
            s.fail_word = wordOf(e, if (e == error.TlsAlert) s.alert else null);
            return if (e == error.EndOfStream or e == error.TlsConnectionTruncated) error.Closed else error.Failed;
        };
        s.open = true;
    }

    /// Send every byte, encrypted.
    pub fn write(s: *Session, data: []const u8) Error!void {
        if (!s.open) return error.Closed;
        s.client.writer.writeAll(data) catch return s.wireFailed();
        s.client.writer.flush() catch return s.wireFailed();
        s.sock_writer.flush() catch return s.wireFailed();
    }

    /// Some decrypted bytes into `buf`; 0 when the peer closed cleanly.
    pub fn read(s: *Session, buf: []u8) Error!usize {
        if (!s.open) return error.Closed;
        const r = &s.client.reader;
        // A record may carry no application data at all (the session
        // tickets a server sends right after the handshake): read on
        // until one does, or the stream ends.
        while (r.bufferedLen() == 0) r.fillMore() catch |e| switch (e) {
            error.EndOfStream => return 0,
            error.ReadFailed => {
                if (s.client.read_err) |re| s.fail_word = wordOf(re, s.client.alert);
                return s.wireFailed();
            },
        };
        const have = r.buffered();
        const n = @min(have.len, buf.len);
        @memcpy(buf[0..n], have[0..n]);
        r.toss(n);
        return n;
    }

    /// Say goodbye (close_notify), best effort; the transport is the
    /// host's to close.
    pub fn close(s: *Session) void {
        if (!s.open) return;
        s.open = false;
        s.client.end() catch {};
        s.sock_writer.flush() catch {};
    }

    /// Why the last operation failed: a word (`untrusted`,
    /// `host_mismatch`, `expired`, `alert:<description>`, or the
    /// transport's own reason).
    pub fn reason(s: *const Session) []const u8 {
        return s.wire_err orelse s.fail_word;
    }

    fn wireFailed(s: *Session) Error {
        if (s.wire_err == null and std.mem.eql(u8, s.fail_word, "failed")) s.fail_word = "tls_failed";
        return error.Failed;
    }

    fn sockStream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const s: *Session = @alignCast(@fieldParentPtr("sock_reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        switch (s.transport.recv(s.transport.ctx, dest)) {
            .n => |n| {
                if (n == 0) return error.EndOfStream;
                w.advance(n);
                return n;
            },
            .closed => return error.EndOfStream,
            .failed => |m| {
                s.wire_err = m;
                return error.ReadFailed;
            },
        }
    }

    fn sockDrain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const s: *Session = @alignCast(@fieldParentPtr("sock_writer", w));
        const t = s.transport;
        if (w.end > 0) {
            if (t.send(t.ctx, w.buffer[0..w.end])) |m| {
                s.wire_err = m;
                return error.WriteFailed;
            }
            w.end = 0;
        }
        var sent: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            if (t.send(t.ctx, d)) |m| {
                s.wire_err = m;
                return error.WriteFailed;
            }
            sent += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            if (t.send(t.ctx, last)) |m| {
                s.wire_err = m;
                return error.WriteFailed;
            }
            sent += last.len;
        }
        return sent;
    }
};

/// A word for what went wrong, for a result the language can match on.
fn wordOf(e: anyerror, alert: ?tls.Alert) []const u8 {
    return switch (e) {
        error.TlsAlert => if (alert) |a| switch (a.description) {
            .handshake_failure => "alert:handshake_failure",
            .protocol_version => "alert:protocol_version",
            .unrecognized_name => "alert:unrecognized_name",
            .certificate_required => "alert:certificate_required",
            .bad_certificate => "alert:bad_certificate",
            .internal_error => "alert:internal_error",
            .illegal_parameter => "alert:illegal_parameter",
            .decrypt_error => "alert:decrypt_error",
            .close_notify => "closed",
            else => "alert",
        } else "alert",
        error.TlsCertificateNotVerified, error.CertificateIssuerNotFound, error.CertificateSignatureInvalid, error.CertificateIssuerMismatch => "untrusted",
        error.CertificateHostMismatch => "host_mismatch",
        error.CertificateExpired, error.CertificateNotYetValid => "expired",
        error.EndOfStream, error.TlsConnectionTruncated => "closed",
        error.TlsBadRecordMac, error.TlsDecryptError => "bad_record",
        error.TlsUnexpectedMessage, error.TlsDecodeError, error.TlsIllegalParameter, error.TlsBadLength, error.TlsRecordOverflow => "protocol",
        error.ReadFailed, error.WriteFailed => "transport",
        else => @errorName(e),
    };
}

// ------------------------------------------------------------------ tests

const test_ca = @embedFile("tls/moss-test-ca.pem");
const test_server = @embedFile("tls/moss-test-server.pem");
const test_now: i64 = 1_790_000_000; // 2026-09-21, after the test material was made

fn parseOne(pem: []const u8, gpa: Allocator) !Certificate.Parsed {
    var r: Roots = .{};
    defer r.deinit(gpa);
    _ = try r.add(gpa, pem, test_now);
    // The bundle holds the DER; parse a copy of it as a plain certificate.
    const der = try gpa.dupe(u8, r.bundle.bytes.items);
    return Certificate.parse(.{ .buffer = der, .index = 0 });
}

test "roots: the test root loads and vouches for the test server, by name" {
    const gpa = std.testing.allocator;
    var roots: Roots = .{};
    defer roots.deinit(gpa);
    try std.testing.expectEqual(@as(usize, 1), try roots.add(gpa, test_ca, test_now));
    try std.testing.expectEqual(@as(usize, 1), roots.count());
    const leaf = try parseOne(test_server, gpa);
    defer gpa.free(leaf.certificate.buffer);
    try roots.bundle.verify(leaf, test_now);
    try leaf.verifyHostName("tls.moss.test");
    try std.testing.expectError(error.CertificateHostMismatch, leaf.verifyHostName("10.0.2.2"));
    try std.testing.expectError(error.CertificateHostMismatch, leaf.verifyHostName("evil.moss.test"));
}

test "roots: an empty bundle vouches for nothing; a stale certificate is left out" {
    const gpa = std.testing.allocator;
    var roots: Roots = .{};
    defer roots.deinit(gpa);
    const leaf = try parseOne(test_server, gpa);
    defer gpa.free(leaf.certificate.buffer);
    try std.testing.expectError(error.CertificateIssuerNotFound, roots.bundle.verify(leaf, test_now));
    // A root already expired at load is not kept: nothing to verify against.
    try std.testing.expectEqual(@as(usize, 0), try roots.add(gpa, test_ca, 6_000_000_000));
    // Junk between certificates is skipped; a missing end marker is an error.
    try std.testing.expectEqual(@as(usize, 1), try roots.add(gpa, "junk\n" ++ test_ca ++ "\nmore junk", test_now));
    try std.testing.expectError(error.MissingEndCertificateMarker, roots.add(gpa, "-----BEGIN CERTIFICATE-----\nabcd\n", test_now));
}

test "session: a transport that closes at once fails the handshake with `closed`" {
    const gpa = std.testing.allocator;
    var roots: Roots = .{};
    defer roots.deinit(gpa);
    _ = try roots.add(gpa, test_ca, test_now);
    const Closed = struct {
        sent: usize = 0,
        fn send(ctx: *anyopaque, data: []const u8) ?[]const u8 {
            const c: *@This() = @ptrCast(@alignCast(ctx));
            c.sent += data.len;
            return null;
        }
        fn recv(_: *anyopaque, _: []u8) RecvOut {
            return .closed;
        }
    };
    var wire: Closed = .{};
    const s = try gpa.create(Session);
    defer gpa.destroy(s);
    s.* = .{};
    const entropy: [entropy_len]u8 = @splat(7);
    const r = s.connect(.{ .ctx = @ptrCast(&wire), .send = Closed.send, .recv = Closed.recv }, .{ .host = "tls.moss.test", .roots = &roots, .entropy = &entropy, .now_ms = test_now * 1000 });
    try std.testing.expectError(error.Closed, r);
    try std.testing.expectEqualStrings("closed", s.reason());
    try std.testing.expect(wire.sent > 100); // the client hello went out
    try std.testing.expectError(error.Closed, s.write("x"));
}
