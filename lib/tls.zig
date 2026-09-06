//! TLS for moss programs: the standard library's TLS 1.3 client, run
//! over a transport the host provides (a socket's send and receive),
//! verifying the server against trust roots parsed from PEM text.
//! Nothing here touches a socket, a clock or an entropy source: the
//! host passes bytes in and out, the time, and the random bytes the
//! handshake needs, so the whole thing is host-testable and the same
//! on every port.
//!
//! A `Session` is the client side: it owns every buffer the standard
//! client needs (four of a TLS record each), so a host keeps a table of
//! them and hands one to a connection; a `Roots` is a certificate
//! bundle a host loads once from the PEM it was given and shares among
//! sessions. A `Server` is the other side — TLS 1.3 only, written here
//! on the standard library's primitives (the standard library has no
//! server): one key share (x25519), the three IANA cipher suites, a
//! certificate chain and a P-256 or Ed25519 key loaded from PEM into
//! an `Identity`. No client certificates, no resumption, no early data,
//! no key update, no HelloRetryRequest: a client that offers no x25519
//! share is refused.

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

// ------------------------------------------------------------------- wire

/// Every buffer a record passes through is a record long.
pub const buf_len = Client.min_buffer_len;

/// The wire side of either party: a `Reader` records are read from
/// and a `Writer` they are written to, both over the transport.
const Wire = struct {
    transport: Transport = undefined,
    reader: Reader = undefined,
    writer: Writer = undefined,
    /// The transport's last reason, when it failed underneath.
    err: ?[]const u8 = null,
    in_buf: [buf_len]u8 = undefined,
    out_buf: [buf_len]u8 = undefined,

    fn init(w: *Wire, transport: Transport) void {
        w.transport = transport;
        w.err = null;
        w.reader = .{ .buffer = &w.in_buf, .seek = 0, .end = 0, .vtable = &.{ .stream = stream } };
        w.writer = .{ .buffer = &w.out_buf, .vtable = &.{ .drain = drain } };
    }

    fn stream(r: *Reader, w: *Writer, limit: std.Io.Limit) Reader.StreamError!usize {
        const self: *Wire = @alignCast(@fieldParentPtr("reader", r));
        const dest = limit.slice(try w.writableSliceGreedy(1));
        switch (self.transport.recv(self.transport.ctx, dest)) {
            .n => |n| {
                if (n == 0) return error.EndOfStream;
                w.advance(n);
                return n;
            },
            .closed => return error.EndOfStream,
            .failed => |m| {
                self.err = m;
                return error.ReadFailed;
            },
        }
    }

    fn drain(w: *Writer, data: []const []const u8, splat: usize) Writer.Error!usize {
        const self: *Wire = @alignCast(@fieldParentPtr("writer", w));
        const t = self.transport;
        if (w.end > 0) {
            if (t.send(t.ctx, w.buffer[0..w.end])) |m| {
                self.err = m;
                return error.WriteFailed;
            }
            w.end = 0;
        }
        var sent: usize = 0;
        for (data[0 .. data.len - 1]) |d| {
            if (t.send(t.ctx, d)) |m| {
                self.err = m;
                return error.WriteFailed;
            }
            sent += d.len;
        }
        const last = data[data.len - 1];
        for (0..splat) |_| {
            if (t.send(t.ctx, last)) |m| {
                self.err = m;
                return error.WriteFailed;
            }
            sent += last.len;
        }
        return sent;
    }
};

// ---------------------------------------------------------------- session

pub const Session = struct {
    wire: Wire = .{},
    client: Client = undefined,
    open: bool = false,
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
        s.wire.init(transport);
        s.open = false;
        s.got_alert = false;
        s.client = Client.init(&s.wire.reader, &s.wire.writer, .{
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
        s.wire.writer.flush() catch return s.wireFailed();
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
        s.wire.writer.flush() catch {};
    }

    /// Why the last operation failed: a word (`untrusted`,
    /// `host_mismatch`, `expired`, `alert:<description>`, or the
    /// transport's own reason).
    pub fn reason(s: *const Session) []const u8 {
        return s.wire.err orelse s.fail_word;
    }

    fn wireFailed(s: *Session) Error {
        if (s.wire.err == null and std.mem.eql(u8, s.fail_word, "failed")) s.fail_word = "tls_failed";
        return error.Failed;
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

// ------------------------------------------------------------------ server
//
// TLS 1.3 the other way, written here on the standard library's crypto
// (the standard library ships no TLS server). Deliberately one path: the
// three IANA AEAD suites, an x25519 key share only, an ECDSA P-256 or
// Ed25519 certificate, no client certificates, no resumption, no early
// data, no key update, no HelloRetryRequest. A client offering no
// x25519 share is refused with `handshake_failure`.

const Aes128Gcm = std.crypto.aead.aes_gcm.Aes128Gcm;
const Aes256Gcm = std.crypto.aead.aes_gcm.Aes256Gcm;
const ChaCha20Poly1305 = std.crypto.aead.chacha_poly.ChaCha20Poly1305;
const X25519 = std.crypto.dh.X25519;
const EcdsaP256 = std.crypto.sign.ecdsa.EcdsaP256Sha256;
const Ed25519 = std.crypto.sign.Ed25519;
const der = Certificate.der;

/// The random bytes a server handshake consumes: 32 for ServerHello,
/// 32 to seed the ephemeral x25519 key.
pub const server_entropy_len = 64;

const ct_change_cipher_spec = 20;
const ct_alert = 21;
const ct_handshake = 22;
const ct_application_data = 23;
const hs_client_hello = 1;
const hs_server_hello = 2;
const hs_encrypted_extensions = 8;
const hs_certificate = 11;
const hs_certificate_verify = 15;
const hs_finished = 20;
const group_x25519 = 0x001d;

/// Which AEAD is in force; all three share a 12-byte nonce and 16-byte
/// tag, so application records dispatch on this alone.
const Aead = enum { aes128_gcm, aes256_gcm, chacha20_poly1305 };

fn AeadType(comptime a: Aead) type {
    return switch (a) {
        .aes128_gcm => Aes128Gcm,
        .aes256_gcm => Aes256Gcm,
        .chacha20_poly1305 => ChaCha20Poly1305,
    };
}

/// One record sealed with an AEAD: header (its own AAD) then ciphertext
/// then tag, written to `w`. `plaintext` is the inner content; a byte
/// naming its type is appended before sealing, per TLS 1.3.
fn seal(a: Aead, w: *Writer, key: []const u8, iv: [12]u8, seq: *u64, inner_type: u8, plaintext: []const u8) Writer.Error!void {
    var inner: [tls.max_ciphertext_inner_record_len + 1]u8 = undefined;
    @memcpy(inner[0..plaintext.len], plaintext);
    inner[plaintext.len] = inner_type;
    const inner_len = plaintext.len + 1;
    const total = inner_len + 16;
    var header: [5]u8 = .{ ct_application_data, 0x03, 0x03, @intCast(total >> 8), @intCast(total & 0xff) };
    var nonce = iv;
    const s = std.mem.toBytes(std.mem.nativeToBig(u64, seq.*));
    for (0..8) |i| nonce[4 + i] ^= s[i];
    var cipher: [tls.max_ciphertext_inner_record_len + 1]u8 = undefined;
    var tag: [16]u8 = undefined;
    switch (a) {
        inline else => |t| {
            const A = AeadType(t);
            A.encrypt(cipher[0..inner_len], &tag, inner[0..inner_len], &header, nonce, key[0..A.key_length].*);
        },
    }
    seq.* += 1;
    try w.writeAll(&header);
    try w.writeAll(cipher[0..inner_len]);
    try w.writeAll(&tag);
}

const OpenErr = error{ Truncated, WireFailed, BadRecord, Unexpected };

/// Read one record and, if it is application_data, decrypt it into
/// `out`; a plaintext change_cipher_spec is skipped and the next record
/// returned. The inner content and its type byte (trailing zero padding
/// removed).
fn openHandshake(wire: *Wire, a: Aead, key: []const u8, iv: [12]u8, seq: *u64, out: []u8) OpenErr!struct { ct: u8, body: []const u8 } {
    while (true) {
        const hdr = wire.reader.peek(5) catch |e| return wireErr(wire, e);
        const rct = hdr[0];
        const len: usize = @as(usize, hdr[3]) << 8 | hdr[4];
        var header: [5]u8 = hdr[0..5].*;
        wire.reader.toss(5);
        const body = wire.reader.take(len) catch |e| return wireErr(wire, e);
        if (rct == ct_change_cipher_spec) continue; // legacy middlebox compatibility
        if (rct == ct_alert) return error.Unexpected;
        if (rct != ct_application_data) return error.Unexpected;
        if (len < 16) return error.BadRecord;
        const ct_len = len - 16;
        if (ct_len > out.len) return error.BadRecord;
        var nonce = iv;
        const sb = std.mem.toBytes(std.mem.nativeToBig(u64, seq.*));
        for (0..8) |i| nonce[4 + i] ^= sb[i];
        const ok = switch (a) {
            inline else => |t| blk: {
                const A = AeadType(t);
                A.decrypt(out[0..ct_len], body[0..ct_len], body[ct_len..][0..16].*, &header, nonce, key[0..A.key_length].*) catch break :blk false;
                break :blk true;
            },
        };
        if (!ok) return error.BadRecord;
        seq.* += 1;
        var end = ct_len;
        while (end > 0 and out[end - 1] == 0) end -= 1;
        if (end == 0) return error.BadRecord;
        return .{ .ct = out[end - 1], .body = out[0 .. end - 1] };
    }
}

fn wireErr(wire: *Wire, e: anyerror) OpenErr {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        else => {
            if (wire.err == null) wire.err = "transport";
            return error.WireFailed;
        },
    };
}

/// A server's certificate and the key that proves it: PEM in, ready to
/// present and sign. The DER is copied into an allocation the host owns.
pub const Identity = struct {
    bytes: []u8 = &.{},
    certs: [max_certs][]const u8 = undefined,
    n_certs: usize = 0,
    key: Key = undefined,

    pub const max_certs = 4;
    pub const Key = union(enum) {
        ecdsa_p256: EcdsaP256.KeyPair,
        ed25519: Ed25519.KeyPair,
    };
    pub const LoadError = Allocator.Error || error{ NoCertificate, BadCertificate, BadKey, UnsupportedKey };

    /// The leaf certificate first, then any intermediates, as PEM; the
    /// private key as PEM (SEC1 `EC PRIVATE KEY`, or PKCS#8 `PRIVATE
    /// KEY` holding a P-256 or Ed25519 key).
    pub fn loadPem(id: *Identity, gpa: Allocator, cert_pem: []const u8, key_pem: []const u8) LoadError!void {
        id.* = .{};
        // The DER of every certificate, concatenated in the arena.
        var buf = try std.ArrayList(u8).initCapacity(gpa, cert_pem.len / 4 * 3 + 16);
        errdefer buf.deinit(gpa);
        const begin = "-----BEGIN CERTIFICATE-----";
        const end = "-----END CERTIFICATE-----";
        const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
        var start: usize = 0;
        while (std.mem.findPos(u8, cert_pem, start, begin)) |b| {
            if (id.n_certs == max_certs) break;
            const cs = b + begin.len;
            const ce = std.mem.findPos(u8, cert_pem, cs, end) orelse return error.BadCertificate;
            start = ce + end.len;
            const enc = std.mem.trim(u8, cert_pem[cs..ce], " \t\r\n");
            const off = buf.items.len;
            try buf.ensureUnusedCapacity(gpa, enc.len / 4 * 3 + 3);
            const dst = buf.unusedCapacitySlice();
            const n = base64.decode(dst, enc) catch return error.BadCertificate;
            buf.items.len += n;
            id.certs[id.n_certs] = @as([]const u8, undefined); // filled after bytes settle
            id.n_certs += 1;
            _ = off;
        }
        if (id.n_certs == 0) return error.NoCertificate;
        // Re-walk to record each cert's slice now that `bytes` is stable.
        id.bytes = try buf.toOwnedSlice(gpa);
        {
            var i: usize = 0;
            var idx: usize = 0;
            while (i < id.n_certs) : (i += 1) {
                const el = der.Element.parse(id.bytes, @intCast(idx)) catch return error.BadCertificate;
                id.certs[i] = id.bytes[idx..el.slice.end];
                idx = el.slice.end;
            }
        }
        id.key = try loadKey(key_pem);
    }

    fn loadKey(key_pem: []const u8) LoadError!Key {
        var der_buf: [1024]u8 = undefined;
        const block = pemBlock(key_pem, &der_buf) orelse return error.BadKey;
        const is_ec = std.mem.indexOf(u8, key_pem, "EC PRIVATE KEY") != null;
        const sec1: []const u8 = if (is_ec) block else pkcs8Inner(block) orelse return error.BadKey;
        // Ed25519 PKCS#8 wraps a 32-byte octet string seed, not SEC1.
        if (!is_ec) {
            if (ed25519Seed(block)) |seed| {
                const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return error.BadKey;
                return .{ .ed25519 = kp };
            }
        }
        const scalar = sec1Scalar(sec1) orelse return error.BadKey;
        const sk = EcdsaP256.SecretKey.fromBytes(scalar) catch return error.BadKey;
        const kp = EcdsaP256.KeyPair.fromSecretKey(sk) catch return error.BadKey;
        return .{ .ecdsa_p256 = kp };
    }

    fn scheme(id: *const Identity) tls.SignatureScheme {
        return switch (id.key) {
            .ecdsa_p256 => .ecdsa_secp256r1_sha256,
            .ed25519 => .ed25519,
        };
    }

    pub fn deinit(id: *Identity, gpa: Allocator) void {
        gpa.free(id.bytes);
        id.* = .{};
    }
};

fn pemBlock(pem: []const u8, out: []u8) ?[]const u8 {
    const b = std.mem.indexOf(u8, pem, "-----BEGIN") orelse return null;
    const nl = std.mem.indexOfScalarPos(u8, pem, b, '\n') orelse return null;
    const e = std.mem.indexOfPos(u8, pem, nl, "-----END") orelse return null;
    const enc = std.mem.trim(u8, pem[nl..e], " \t\r\n");
    const base64 = std.base64.standard.decoderWithIgnore(" \t\r\n");
    const n = base64.decode(out, enc) catch return null;
    return out[0..n];
}

/// The P-256 scalar in a SEC1 `ECPrivateKey` (SEQUENCE { version,
/// privateKey OCTET STRING, ... }): 32 bytes, left-padded if shorter.
fn sec1Scalar(sec1: []const u8) ?[32]u8 {
    const seq = der.Element.parse(sec1, 0) catch return null;
    const ver = der.Element.parse(sec1, seq.slice.start) catch return null;
    const oct = der.Element.parse(sec1, ver.slice.end) catch return null;
    const raw = sec1[oct.slice.start..oct.slice.end];
    if (raw.len == 0 or raw.len > 32) return null;
    var scalar: [32]u8 = @splat(0);
    @memcpy(scalar[32 - raw.len ..], raw);
    return scalar;
}

/// The SEC1 body inside a PKCS#8 `PrivateKeyInfo` (SEQUENCE { version,
/// algorithm SEQUENCE, privateKey OCTET STRING }).
fn pkcs8Inner(pkcs8: []const u8) ?[]const u8 {
    const seq = der.Element.parse(pkcs8, 0) catch return null;
    const ver = der.Element.parse(pkcs8, seq.slice.start) catch return null;
    const alg = der.Element.parse(pkcs8, ver.slice.end) catch return null;
    const oct = der.Element.parse(pkcs8, alg.slice.end) catch return null;
    return pkcs8[oct.slice.start..oct.slice.end];
}

/// The 32-byte Ed25519 seed inside a PKCS#8 key (the private-key octet
/// string wraps a second octet string holding the seed), or null when
/// the key is not Ed25519.
fn ed25519Seed(pkcs8: []const u8) ?[32]u8 {
    const seq = der.Element.parse(pkcs8, 0) catch return null;
    const ver = der.Element.parse(pkcs8, seq.slice.start) catch return null;
    const alg = der.Element.parse(pkcs8, ver.slice.end) catch return null;
    // The algorithm OID for Ed25519 is 1.3.101.112 (bytes 2b 65 70).
    const oid = der.Element.parse(pkcs8, alg.slice.start) catch return null;
    const oid_bytes = pkcs8[oid.slice.start..oid.slice.end];
    if (!std.mem.eql(u8, oid_bytes, &.{ 0x2b, 0x65, 0x70 })) return null;
    const oct = der.Element.parse(pkcs8, alg.slice.end) catch return null;
    const inner = der.Element.parse(pkcs8, oct.slice.start) catch return null;
    const seed = pkcs8[inner.slice.start..inner.slice.end];
    if (seed.len != 32) return null;
    return seed[0..32].*;
}

pub const Server = struct {
    wire: Wire = .{},
    open: bool = false,
    fail_word: []const u8 = "failed",
    /// Application keys, set once the handshake finishes.
    aead: Aead = undefined,
    key_len: usize = 0,
    c_key: [32]u8 = undefined,
    s_key: [32]u8 = undefined,
    c_iv: [12]u8 = undefined,
    s_iv: [12]u8 = undefined,
    c_seq: u64 = 0,
    s_seq: u64 = 0,
    /// Decrypted application bytes waiting past a read's buffer.
    leftover: [buf_len]u8 = undefined,
    leftover_len: usize = 0,
    leftover_off: usize = 0,

    pub const Options = struct {
        identity: *const Identity,
        entropy: *const [server_entropy_len]u8,
        now_ms: u64,
    };

    pub const Error = error{ Failed, Closed };

    /// Shake hands as the server. On failure the reason is `reason()`.
    pub fn accept(sv: *Server, transport: Transport, o: Options) Error!void {
        sv.wire.init(transport);
        sv.open = false;
        sv.leftover_len = 0;
        sv.leftover_off = 0;
        sv.c_seq = 0;
        sv.s_seq = 0;
        runAccept(sv, o) catch |e| {
            if (sv.wire.err) |m| sv.fail_word = m;
            return switch (e) {
                error.Truncated => error.Closed,
                else => error.Failed,
            };
        };
        sv.open = true;
    }

    const AcceptErr = error{ Truncated, WireFailed, BadRecord, Unexpected, NoSharedSuite, NoKeyShare, Sign, OutOfMemory };

    fn runAccept(sv: *Server, o: Options) AcceptErr!void {
        const r = &sv.wire.reader;
        // ClientHello: one plaintext handshake record.
        const hdr = r.peek(5) catch |e| return acceptWireErr(sv, e);
        if (hdr[0] != ct_handshake) return error.Unexpected;
        const rec_len: usize = @as(usize, hdr[3]) << 8 | hdr[4];
        r.toss(5);
        const hello = r.take(rec_len) catch |e| return acceptWireErr(sv, e);
        if (hello.len < 4 or hello[0] != hs_client_hello) return error.Unexpected;
        const ch = try parseClientHello(hello);
        const suite = ch.suite orelse return error.NoSharedSuite;
        const peer = ch.x25519 orelse return error.NoKeyShare;
        switch (suite) {
            inline else => |tag| try sv.handshakeWith(SuiteFor(tag), hello, ch, peer, o),
        }
    }

    fn handshakeWith(sv: *Server, comptime S: type, hello: []const u8, ch: ClientHello, peer: [32]u8, o: Options) AcceptErr!void {
        const w = &sv.wire.writer;
        var th = S.Hash.init(.{});
        th.update(hello);

        // Our ephemeral key and the shared secret.
        const kp = X25519.KeyPair.generateDeterministic(o.entropy[32..64].*) catch return error.NoKeyShare;
        const shared = X25519.scalarmult(kp.secret_key, peer) catch return error.NoKeyShare;

        // ServerHello.
        var sh: [512]u8 = undefined;
        const sh_msg = buildServerHello(&sh, o.entropy[0..32].*, ch.session_id, @intFromEnum(ch.suite_tag), kp.public_key);
        th.update(sh_msg);
        try writePlaintext(w, ct_handshake, sh_msg);
        try writePlaintext(w, ct_change_cipher_spec, &.{0x01});

        // Handshake key schedule.
        const zeroes = [_]u8{0} ** S.Hash.digest_length;
        const early = S.Hkdf.extract(&[1]u8{0}, &zeroes);
        const empty_hash = tls.emptyHash(S.Hash);
        const hs_derived = tls.hkdfExpandLabel(S.Hkdf, early, "derived", &empty_hash, S.Hash.digest_length);
        const handshake_secret = S.Hkdf.extract(&hs_derived, shared[0..]);
        const hello_hash = th.peek();
        const c_hs = tls.hkdfExpandLabel(S.Hkdf, handshake_secret, "c hs traffic", &hello_hash, S.Hash.digest_length);
        const s_hs = tls.hkdfExpandLabel(S.Hkdf, handshake_secret, "s hs traffic", &hello_hash, S.Hash.digest_length);
        var s_hs_key = tls.hkdfExpandLabel(S.Hkdf, s_hs, "key", "", S.A.key_length);
        const s_hs_iv = tls.hkdfExpandLabel(S.Hkdf, s_hs, "iv", "", 12);
        var c_hs_key = tls.hkdfExpandLabel(S.Hkdf, c_hs, "key", "", S.A.key_length);
        const c_hs_iv = tls.hkdfExpandLabel(S.Hkdf, c_hs, "iv", "", 12);
        const s_fin_key = tls.hkdfExpandLabel(S.Hkdf, s_hs, "finished", "", S.Hmac.mac_length);
        const c_fin_key = tls.hkdfExpandLabel(S.Hkdf, c_hs, "finished", "", S.Hmac.mac_length);
        const ap_derived = tls.hkdfExpandLabel(S.Hkdf, handshake_secret, "derived", &empty_hash, S.Hash.digest_length);
        const master = S.Hkdf.extract(&ap_derived, &zeroes);

        var s_seq: u64 = 0;
        var c_seq: u64 = 0;

        // EncryptedExtensions (empty).
        const ee = [_]u8{ hs_encrypted_extensions, 0, 0, 2, 0, 0 };
        th.update(&ee);
        try sealHs(S.aead, w, &s_hs_key, s_hs_iv, &s_seq, ct_handshake, &ee);

        // Certificate.
        var cert_msg: [tls.max_ciphertext_inner_record_len]u8 = undefined;
        const cm = buildCertificate(&cert_msg, o.identity);
        th.update(cm);
        try sealHs(S.aead, w, &s_hs_key, s_hs_iv, &s_seq, ct_handshake, cm);

        // CertificateVerify: sign the transcript so far.
        const cert_hash = th.peek();
        var cv: [600]u8 = undefined;
        const cvm = buildCertVerify(&cv, o.identity, &cert_hash) catch return error.Sign;
        th.update(cvm);
        try sealHs(S.aead, w, &s_hs_key, s_hs_iv, &s_seq, ct_handshake, cvm);

        // Server Finished.
        const fin_hash = th.peek();
        var s_verify: [S.Hmac.mac_length]u8 = undefined;
        S.Hmac.create(&s_verify, &fin_hash, &s_fin_key);
        var fin: [4 + S.Hmac.mac_length]u8 = undefined;
        fin[0] = hs_finished;
        fin[1] = 0;
        fin[2] = @intCast(S.Hmac.mac_length >> 8);
        fin[3] = @intCast(S.Hmac.mac_length & 0xff);
        @memcpy(fin[4..], &s_verify);
        th.update(&fin);
        try sealHs(S.aead, w, &s_hs_key, s_hs_iv, &s_seq, ct_handshake, &fin);
        w.flush() catch return acceptWireErr(sv, error.WriteFailed);

        // Application key schedule (transcript through server Finished).
        const ap_hash = th.peek();
        const c_ap = tls.hkdfExpandLabel(S.Hkdf, master, "c ap traffic", &ap_hash, S.Hash.digest_length);
        const s_ap = tls.hkdfExpandLabel(S.Hkdf, master, "s ap traffic", &ap_hash, S.Hash.digest_length);

        // Client Finished (encrypted with the client handshake key).
        var open_buf: [buf_len]u8 = undefined;
        const cf = openHandshake(&sv.wire, S.aead, &c_hs_key, c_hs_iv, &c_seq, &open_buf) catch |e| return e;
        if (cf.ct != ct_handshake or cf.body.len != 4 + S.Hmac.mac_length or cf.body[0] != hs_finished) return error.Unexpected;
        var expect: [S.Hmac.mac_length]u8 = undefined;
        S.Hmac.create(&expect, &ap_hash, &c_fin_key);
        if (!std.crypto.timing_safe.eql([S.Hmac.mac_length]u8, expect, cf.body[4..][0..S.Hmac.mac_length].*)) {
            sv.fail_word = "client_finished";
            return error.BadRecord;
        }

        // Settle the application keys for read/write.
        sv.aead = S.aead;
        sv.key_len = S.A.key_length;
        @memcpy(sv.c_key[0..S.A.key_length], &tls.hkdfExpandLabel(S.Hkdf, c_ap, "key", "", S.A.key_length));
        @memcpy(sv.s_key[0..S.A.key_length], &tls.hkdfExpandLabel(S.Hkdf, s_ap, "key", "", S.A.key_length));
        sv.c_iv = tls.hkdfExpandLabel(S.Hkdf, c_ap, "iv", "", 12);
        sv.s_iv = tls.hkdfExpandLabel(S.Hkdf, s_ap, "iv", "", 12);
        sv.c_seq = 0;
        sv.s_seq = 0;
    }

    /// Send application bytes, encrypted.
    pub fn write(sv: *Server, data: []const u8) Error!void {
        if (!sv.open) return error.Closed;
        var off: usize = 0;
        while (off < data.len) {
            const n = @min(data.len - off, tls.max_ciphertext_inner_record_len);
            seal(sv.aead, &sv.wire.writer, sv.s_key[0..sv.key_len], sv.s_iv, &sv.s_seq, ct_application_data, data[off .. off + n]) catch return sv.wireFailed();
            off += n;
        }
        sv.wire.writer.flush() catch return sv.wireFailed();
    }

    /// Some decrypted application bytes; 0 at a clean close.
    pub fn read(sv: *Server, out: []u8) Error!usize {
        if (!sv.open) return error.Closed;
        if (sv.leftover_off < sv.leftover_len) {
            const n = @min(out.len, sv.leftover_len - sv.leftover_off);
            @memcpy(out[0..n], sv.leftover[sv.leftover_off .. sv.leftover_off + n]);
            sv.leftover_off += n;
            return n;
        }
        while (true) {
            const rec = openHandshake(&sv.wire, sv.aead, sv.c_key[0..sv.key_len], sv.c_iv, &sv.c_seq, &sv.leftover) catch |e| switch (e) {
                error.Truncated => return 0,
                error.Unexpected => return 0, // a close_notify alert reads as the end
                else => {
                    sv.fail_word = "bad_record";
                    return error.Failed;
                },
            };
            if (rec.ct == ct_application_data) {
                const n = @min(out.len, rec.body.len);
                @memcpy(out[0..n], rec.body[0..n]);
                sv.leftover_len = rec.body.len;
                sv.leftover_off = n;
                // openHandshake wrote into leftover; body aliases it.
                std.mem.copyForwards(u8, &sv.leftover, rec.body);
                return n;
            }
            // A post-handshake message (a session ticket we never send,
            // key update we refuse): ignore and read on.
        }
    }

    pub fn close(sv: *Server) void {
        sv.open = false;
    }

    pub fn reason(sv: *const Server) []const u8 {
        return sv.wire.err orelse sv.fail_word;
    }

    fn wireFailed(sv: *Server) Error {
        if (sv.wire.err) |m| sv.fail_word = m;
        return error.Failed;
    }
};

fn acceptWireErr(sv: *Server, e: anyerror) Server.AcceptErr {
    return switch (e) {
        error.EndOfStream => error.Truncated,
        else => {
            if (sv.wire.err == null) sv.wire.err = "transport";
            return error.WireFailed;
        },
    };
}

fn sealHs(a: Aead, w: *Writer, key: []const u8, iv: [12]u8, seq: *u64, inner_type: u8, plaintext: []const u8) Server.AcceptErr!void {
    seal(a, w, key, iv, seq, inner_type, plaintext) catch return error.WireFailed;
}

fn writePlaintext(w: *Writer, ct: u8, body: []const u8) Server.AcceptErr!void {
    var header: [5]u8 = .{ ct, 0x03, 0x03, @intCast(body.len >> 8), @intCast(body.len & 0xff) };
    w.writeAll(&header) catch return error.WireFailed;
    w.writeAll(body) catch return error.WireFailed;
}

/// The AEAD/hash pair a suite tag names, plus the derived crypto types.
fn SuiteFor(comptime tag: CipherTag) type {
    return switch (tag) {
        .aes128 => SuiteT(Aes128Gcm, std.crypto.hash.sha2.Sha256, .aes128_gcm),
        .aes256 => SuiteT(Aes256Gcm, std.crypto.hash.sha2.Sha384, .aes256_gcm),
        .chacha => SuiteT(ChaCha20Poly1305, std.crypto.hash.sha2.Sha256, .chacha20_poly1305),
    };
}

fn SuiteT(comptime AEAD: type, comptime HashT: type, comptime a: Aead) type {
    return struct {
        const A = AEAD;
        const Hash = HashT;
        const Hmac = std.crypto.auth.hmac.Hmac(HashT);
        const Hkdf = std.crypto.kdf.hkdf.Hkdf(Hmac);
        const aead = a;
    };
}

const CipherTag = enum { aes128, aes256, chacha };

const ClientHello = struct {
    session_id: []const u8,
    suite: ?CipherTag,
    suite_tag: tls.CipherSuite,
    x25519: ?[32]u8,
};

fn cursorTake(buf: []const u8, p: *usize, n: usize) error{Unexpected}![]const u8 {
    if (p.* + n > buf.len) return error.Unexpected;
    const s = buf[p.* .. p.* + n];
    p.* += n;
    return s;
}

fn u16at(s: []const u8) usize {
    return @as(usize, s[0]) << 8 | s[1];
}

fn parseClientHello(hello: []const u8) error{Unexpected}!ClientHello {
    var p: usize = 4; // handshake type + u24 length
    _ = try cursorTake(hello, &p, 2); // legacy_version
    _ = try cursorTake(hello, &p, 32); // random
    const sid_len = (try cursorTake(hello, &p, 1))[0];
    const session_id = try cursorTake(hello, &p, sid_len);
    const cs_len = u16at(try cursorTake(hello, &p, 2));
    const cs = try cursorTake(hello, &p, cs_len);
    // Choose the first offered suite we support, in the client's order.
    var suite: ?CipherTag = null;
    var suite_tag: tls.CipherSuite = @enumFromInt(0);
    var i: usize = 0;
    while (i + 1 < cs.len) : (i += 2) {
        const v = u16at(cs[i .. i + 2]);
        const pick: ?CipherTag = switch (v) {
            0x1301 => .aes128,
            0x1302 => .aes256,
            0x1303 => .chacha,
            else => null,
        };
        if (pick) |t| {
            if (suite == null) {
                suite = t;
                suite_tag = @enumFromInt(@as(u16, @intCast(v)));
            }
        }
    }
    const comp_len = (try cursorTake(hello, &p, 1))[0];
    _ = try cursorTake(hello, &p, comp_len);
    var x: ?[32]u8 = null;
    if (p < hello.len) {
        const ext_total = u16at(try cursorTake(hello, &p, 2));
        const ext_end = p + ext_total;
        while (p + 4 <= ext_end and p + 4 <= hello.len) {
            const et = u16at(try cursorTake(hello, &p, 2));
            const el = u16at(try cursorTake(hello, &p, 2));
            const ed = try cursorTake(hello, &p, el);
            if (et == 51) x = keyShareX25519(ed) orelse x; // key_share
        }
    }
    return .{ .session_id = session_id, .suite = suite, .suite_tag = suite_tag, .x25519 = x };
}

fn keyShareX25519(ext: []const u8) ?[32]u8 {
    if (ext.len < 2) return null;
    const list_len = u16at(ext[0..2]);
    var p: usize = 2;
    const end = @min(2 + list_len, ext.len);
    while (p + 4 <= end) {
        const group = u16at(ext[p .. p + 2]);
        const klen = u16at(ext[p + 2 .. p + 4]);
        p += 4;
        if (p + klen > ext.len) return null;
        if (group == group_x25519 and klen == 32) return ext[p .. p + 32][0..32].*;
        p += klen;
    }
    return null;
}

fn buildServerHello(out: []u8, random: [32]u8, session_id: []const u8, suite: u16, pub_key: [32]u8) []const u8 {
    var p: usize = 0;
    // handshake header filled at the end
    p = 4;
    out[p] = 0x03;
    out[p + 1] = 0x03; // legacy_version
    p += 2;
    @memcpy(out[p .. p + 32], &random);
    p += 32;
    out[p] = @intCast(session_id.len);
    p += 1;
    @memcpy(out[p .. p + session_id.len], session_id);
    p += session_id.len;
    out[p] = @intCast(suite >> 8);
    out[p + 1] = @intCast(suite & 0xff);
    p += 2;
    out[p] = 0; // legacy_compression_method
    p += 1;
    // extensions: supported_versions + key_share
    const ext_start = p + 2;
    var e = ext_start;
    // supported_versions (43): selected 0x0304
    out[e] = 0x00;
    out[e + 1] = 0x2b;
    out[e + 2] = 0x00;
    out[e + 3] = 0x02;
    out[e + 4] = 0x03;
    out[e + 5] = 0x04;
    e += 6;
    // key_share (51): group x25519 + 32-byte key
    out[e] = 0x00;
    out[e + 1] = 0x33;
    out[e + 2] = 0x00;
    out[e + 3] = 0x24; // ext len = 36
    out[e + 4] = 0x00;
    out[e + 5] = 0x1d; // x25519
    out[e + 6] = 0x00;
    out[e + 7] = 0x20; // key len 32
    @memcpy(out[e + 8 .. e + 40], &pub_key);
    e += 40;
    const ext_len = e - ext_start;
    out[ext_start - 2] = @intCast(ext_len >> 8);
    out[ext_start - 1] = @intCast(ext_len & 0xff);
    const body_len = e - 4;
    out[0] = hs_server_hello;
    out[1] = @intCast(body_len >> 16);
    out[2] = @intCast((body_len >> 8) & 0xff);
    out[3] = @intCast(body_len & 0xff);
    return out[0..e];
}

fn buildCertificate(out: []u8, id: *const Identity) []const u8 {
    var p: usize = 4; // handshake header
    out[p] = 0; // certificate_request_context length
    p += 1;
    const list_len_at = p;
    p += 3; // certificate_list length
    for (id.certs[0..id.n_certs]) |c| {
        out[p] = @intCast(c.len >> 16);
        out[p + 1] = @intCast((c.len >> 8) & 0xff);
        out[p + 2] = @intCast(c.len & 0xff);
        p += 3;
        @memcpy(out[p .. p + c.len], c);
        p += c.len;
        out[p] = 0; // extensions length
        out[p + 1] = 0;
        p += 2;
    }
    const list_len = p - (list_len_at + 3);
    out[list_len_at] = @intCast(list_len >> 16);
    out[list_len_at + 1] = @intCast((list_len >> 8) & 0xff);
    out[list_len_at + 2] = @intCast(list_len & 0xff);
    const body_len = p - 4;
    out[0] = hs_certificate;
    out[1] = @intCast(body_len >> 16);
    out[2] = @intCast((body_len >> 8) & 0xff);
    out[3] = @intCast(body_len & 0xff);
    return out[0..p];
}

fn buildCertVerify(out: []u8, id: *const Identity, transcript: []const u8) error{Sign}![]const u8 {
    var content: [160]u8 = undefined; // 64 + label(33) + 1 + up to a 48-byte (SHA-384) transcript
    @memset(content[0..64], 0x20);
    const label = "TLS 1.3, server CertificateVerify";
    @memcpy(content[64 .. 64 + label.len], label);
    content[64 + label.len] = 0x00;
    const prefix = 64 + label.len + 1;
    // transcript hash length depends on the suite; append it.
    @memcpy(content[prefix .. prefix + transcript.len], transcript);
    const msg = content[0 .. prefix + transcript.len];
    var sig_buf: [140]u8 = undefined;
    const sig: []const u8 = switch (id.key) {
        .ecdsa_p256 => |kp| blk: {
            const s = kp.sign(msg, null) catch return error.Sign;
            break :blk s.toDer(sig_buf[0..EcdsaP256.Signature.der_encoded_length_max]);
        },
        .ed25519 => |kp| blk: {
            const s = kp.sign(msg, null) catch return error.Sign;
            @memcpy(sig_buf[0..64], &s.toBytes());
            break :blk sig_buf[0..64];
        },
    };
    var p: usize = 4;
    const scheme = @intFromEnum(id.scheme());
    out[p] = @intCast(scheme >> 8);
    out[p + 1] = @intCast(scheme & 0xff);
    out[p + 2] = @intCast(sig.len >> 8);
    out[p + 3] = @intCast(sig.len & 0xff);
    p += 4;
    @memcpy(out[p .. p + sig.len], sig);
    p += sig.len;
    const body_len = p - 4;
    out[0] = hs_certificate_verify;
    out[1] = @intCast(body_len >> 16);
    out[2] = @intCast((body_len >> 8) & 0xff);
    out[3] = @intCast(body_len & 0xff);
    return out[0..p];
}

// ------------------------------------------------------------------ tests

const test_ca = @embedFile("tls/moss-test-ca.pem");
const test_server = @embedFile("tls/moss-test-server.pem");
const test_key = @embedFile("tls/moss-test-server.key");
const test_now: i64 = 1_790_000_000; // 2026-09-21, after the test material was made

fn parseOne(pem: []const u8, gpa: Allocator) !Certificate.Parsed {
    var r: Roots = .{};
    defer r.deinit(gpa);
    _ = try r.add(gpa, pem, test_now);
    // The bundle holds the DER; parse a copy of it as a plain certificate.
    const der_bytes = try gpa.dupe(u8, r.bundle.bytes.items);
    return Certificate.parse(.{ .buffer = der_bytes, .index = 0 });
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

// A byte pipe between two threads: one direction of a socketpair, in
// memory. `send` appends and signals; `recv` waits for bytes or close.
const Pipe = struct {
    lock: std.atomic.Value(u32) = .init(0),
    buf: [1 << 16]u8 = undefined,
    len: usize = 0,
    off: usize = 0,
    closed: bool = false,

    fn acquire(p: *Pipe) void {
        while (p.lock.cmpxchgWeak(0, 1, .acquire, .monotonic) != null) std.Thread.yield() catch {};
    }
    fn release(p: *Pipe) void {
        p.lock.store(0, .release);
    }

    fn send(p: *Pipe, data: []const u8) ?[]const u8 {
        p.acquire();
        defer p.release();
        if (p.closed) return "closed";
        if (p.off > 0) {
            std.mem.copyForwards(u8, p.buf[0 .. p.len - p.off], p.buf[p.off..p.len]);
            p.len -= p.off;
            p.off = 0;
        }
        if (p.len + data.len > p.buf.len) return "pipe full";
        @memcpy(p.buf[p.len .. p.len + data.len], data);
        p.len += data.len;
        return null;
    }

    fn recv(p: *Pipe, out: []u8) RecvOut {
        while (true) {
            p.acquire();
            if (p.off < p.len) {
                const n = @min(out.len, p.len - p.off);
                @memcpy(out[0..n], p.buf[p.off .. p.off + n]);
                p.off += n;
                p.release();
                return .{ .n = n };
            }
            if (p.closed) {
                p.release();
                return .closed;
            }
            p.release();
            std.Thread.yield() catch {};
        }
    }

    fn hangup(p: *Pipe) void {
        p.acquire();
        defer p.release();
        p.closed = true;
    }
};

// One end of the pair: reads from `in`, writes to `out`.
const PipeEnd = struct {
    in: *Pipe,
    out: *Pipe,
    fn send(ctx: *anyopaque, data: []const u8) ?[]const u8 {
        const e: *PipeEnd = @ptrCast(@alignCast(ctx));
        return e.out.send(data);
    }
    fn recv(ctx: *anyopaque, out: []u8) RecvOut {
        const e: *PipeEnd = @ptrCast(@alignCast(ctx));
        return e.in.recv(out);
    }
    fn transport(e: *PipeEnd) Transport {
        return .{ .ctx = @ptrCast(e), .send = send, .recv = recv };
    }
};

const ServerThread = struct {
    server: *Server,
    end: *PipeEnd,
    id: *const Identity,
    entropy: [server_entropy_len]u8,
    result: Server.Error!void = {},
    got: [64]u8 = undefined,
    got_len: usize = 0,

    fn run(st: *ServerThread) void {
        st.server.accept(st.end.transport(), .{ .identity = st.id, .entropy = &st.entropy, .now_ms = test_now * 1000 }) catch |e| {
            st.result = e;
            return;
        };
        // Echo one read back, upper-cased, then close.
        const n = st.server.read(&st.got) catch |e| {
            st.result = e;
            return;
        };
        st.got_len = n;
        var reply: [64]u8 = undefined;
        for (st.got[0..n], 0..) |c, i| reply[i] = std.ascii.toUpper(c);
        st.server.write(reply[0..n]) catch |e| {
            st.result = e;
        };
        st.server.close();
        st.end.out.hangup();
    }
};

test "server: our client shakes hands with our server and they exchange bytes" {
    if (@import("builtin").single_threaded) return error.SkipZigTest;
    const gpa = std.testing.allocator;
    var id: Identity = .{};
    try id.loadPem(gpa, test_server, test_key);
    defer id.deinit(gpa);
    try std.testing.expect(id.n_certs >= 1);

    var roots: Roots = .{};
    defer roots.deinit(gpa);
    _ = try roots.add(gpa, test_ca, test_now);

    const c2s = try gpa.create(Pipe);
    defer gpa.destroy(c2s);
    const s2c = try gpa.create(Pipe);
    defer gpa.destroy(s2c);
    c2s.* = .{};
    s2c.* = .{};
    var client_end: PipeEnd = .{ .in = s2c, .out = c2s };
    var server_end: PipeEnd = .{ .in = c2s, .out = s2c };

    const server = try gpa.create(Server);
    defer gpa.destroy(server);
    server.* = .{};
    var st: ServerThread = .{ .server = server, .end = &server_end, .id = &id, .entropy = @splat(9) };
    const th = try std.Thread.spawn(.{}, ServerThread.run, .{&st});

    const session = try gpa.create(Session);
    defer gpa.destroy(session);
    session.* = .{};
    var entropy: [entropy_len]u8 = undefined;
    for (&entropy, 0..) |*b, i| b.* = @intCast((i * 7 + 3) & 0xff);
    session.connect(client_end.transport(), .{ .host = "tls.moss.test", .roots = &roots, .entropy = &entropy, .now_ms = test_now * 1000 }) catch |e| {
        c2s.hangup();
        th.join();
        std.debug.print("client failed: {s}; server: {s} ({any})\n", .{ session.reason(), server.reason(), st.result });
        return e;
    };
    try session.write("moss over tls");
    var buf: [64]u8 = undefined;
    var total: usize = 0;
    var reply: [64]u8 = undefined;
    while (total < 13) {
        const n = try session.read(buf[0..]);
        if (n == 0) break;
        @memcpy(reply[total .. total + n], buf[0..n]);
        total += n;
    }
    session.close();
    th.join();
    try st.result;
    try std.testing.expectEqualStrings("moss over tls", st.got[0..st.got_len]);
    try std.testing.expectEqualStrings("MOSS OVER TLS", reply[0..total]);
}
