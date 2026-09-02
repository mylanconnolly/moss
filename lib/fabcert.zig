//! Fabric identity certificates and revocations — the trust artifacts of
//! fabric security v2. A cluster has one **root of trust** (an Ed25519
//! keypair whose public half, the cluster key, every node is configured
//! with); each node has its own Ed25519 **identity**; the root signs a
//! certificate binding a node id to its identity key plus what that node
//! may do to peers (gossip membership, request spawns, of which images).
//! Joining is presenting the certificate and proving the identity key —
//! no shared secret exists anywhere. Revoking a node is a signed record
//! naming (node, minimum acceptable serial): certs below it are refused
//! everywhere the record reaches, and the node returns only with a fresh
//! key and a fresh cert. Pure and freestanding-safe (no allocator, no
//! OS); `zig test lib/lib.zig` covers it on the host.

const std = @import("std");

pub const Ed25519 = std.crypto.sign.Ed25519;

pub const cert_ver: u8 = 1;
pub const body_len: usize = 48;
pub const sig_len: usize = Ed25519.Signature.encoded_length; // 64
pub const cert_len: usize = body_len + sig_len; // 112
pub const rev_body_len: usize = 8;
pub const rev_len: usize = rev_body_len + sig_len; // 72
pub const pk_len: usize = Ed25519.PublicKey.encoded_length; // 32

/// This node may gossip membership (member up/down/view frames are
/// believed) — without it, only its own liveness is learned from it.
/// (shared/lib.zig mirrors these as fab_flag_* for orchestration code.)
pub const flag_gossip: u8 = 1 << 0;
/// This node may request remote spawns here (subject to image_mask).
pub const flag_spawn: u8 = 1 << 1;

// Signatures are domain-separated by a label prefix so a certificate can
// never be replayed as a revocation or a handshake transcript.
const cert_label = "moss-fabric-cert-v1";
const rev_label = "moss-fabric-revoke-v1";

pub const Cert = struct {
    node: u16,
    flags: u8,
    /// Bit i set: the holder may request image i (shared.ImageId) here.
    image_mask: u64,
    /// Monotonic per node; revocation names a minimum acceptable serial.
    serial: u32,
    node_pk: [pk_len]u8,
};

pub const Revocation = struct {
    node: u16,
    min_serial: u32,
};

pub const Error = error{ BadVersion, BadSignature, BadKey };

/// Body layout (48 bytes): ver u8 | node u16 | flags u8 | image_mask u64 |
/// serial u32 | node_pk 32.
pub fn encodeBody(c: Cert, out: *[body_len]u8) void {
    out[0] = cert_ver;
    std.mem.writeInt(u16, out[1..3], c.node, .little);
    out[3] = c.flags;
    std.mem.writeInt(u64, out[4..12], c.image_mask, .little);
    std.mem.writeInt(u32, out[12..16], c.serial, .little);
    @memcpy(out[16..48], &c.node_pk);
}

pub fn decodeBody(b: *const [body_len]u8) Error!Cert {
    if (b[0] != cert_ver) return Error.BadVersion;
    return .{
        .node = std.mem.readInt(u16, b[1..3], .little),
        .flags = b[3],
        .image_mask = std.mem.readInt(u64, b[4..12], .little),
        .serial = std.mem.readInt(u32, b[12..16], .little),
        .node_pk = b[16..48].*,
    };
}

/// Root of trust: sign a certificate.
pub fn issue(root: Ed25519.KeyPair, c: Cert, out: *[cert_len]u8) Error!void {
    encodeBody(c, out[0..body_len]);
    const sig = signLabeled(root, cert_label, out[0..body_len]) catch return Error.BadKey;
    @memcpy(out[body_len..cert_len], &sig);
}

/// Anyone holding the cluster key: verify a certificate.
pub fn verify(bytes: *const [cert_len]u8, cluster_pk: [pk_len]u8) Error!Cert {
    const c = try decodeBody(bytes[0..body_len]);
    try verifyLabeled(cluster_pk, cert_label, bytes[0..body_len], bytes[body_len..cert_len]);
    return c;
}

/// Body layout (8 bytes): ver u8 | node u16 | min_serial u32 | pad u8.
pub fn issueRevocation(root: Ed25519.KeyPair, r: Revocation, out: *[rev_len]u8) Error!void {
    out[0] = cert_ver;
    std.mem.writeInt(u16, out[1..3], r.node, .little);
    std.mem.writeInt(u32, out[3..7], r.min_serial, .little);
    out[7] = 0;
    const sig = signLabeled(root, rev_label, out[0..rev_body_len]) catch return Error.BadKey;
    @memcpy(out[rev_body_len..rev_len], &sig);
}

pub fn verifyRevocation(bytes: *const [rev_len]u8, cluster_pk: [pk_len]u8) Error!Revocation {
    if (bytes[0] != cert_ver) return Error.BadVersion;
    try verifyLabeled(cluster_pk, rev_label, bytes[0..rev_body_len], bytes[rev_body_len..rev_len]);
    return .{
        .node = std.mem.readInt(u16, bytes[1..3], .little),
        .min_serial = std.mem.readInt(u32, bytes[3..7], .little),
    };
}

/// Longest message any fabric artifact signs (a handshake transcript).
pub const max_signed_len: usize = 512;

/// Sign label || msg. Deterministic Ed25519 (RFC 8032, no noise): the
/// same artifact always carries the same signature, and no RNG is needed
/// on the signing path.
pub fn signLabeled(kp: Ed25519.KeyPair, label: []const u8, msg: []const u8) !([sig_len]u8) {
    var buf: [max_signed_len]u8 = undefined;
    if (label.len + msg.len > buf.len) return error.MessageTooLong;
    @memcpy(buf[0..label.len], label);
    @memcpy(buf[label.len .. label.len + msg.len], msg);
    const sig = try kp.sign(buf[0 .. label.len + msg.len], null);
    return sig.toBytes();
}

pub fn verifyLabeled(pk_bytes: [pk_len]u8, label: []const u8, msg: []const u8, sig_bytes: []const u8) Error!void {
    if (sig_bytes.len != sig_len) return Error.BadSignature;
    const pk = Ed25519.PublicKey.fromBytes(pk_bytes) catch return Error.BadKey;
    const sig = Ed25519.Signature.fromBytes(sig_bytes[0..sig_len].*);
    var v = sig.verifier(pk) catch return Error.BadSignature;
    v.update(label);
    v.update(msg);
    v.verify() catch return Error.BadSignature;
}

// ------------------------------------------------------------------ tests

fn testRoot(tag: u8) Ed25519.KeyPair {
    var seed: [32]u8 = @splat(tag);
    seed[0] = 0x5a;
    return Ed25519.KeyPair.generateDeterministic(seed) catch unreachable;
}

test "certificate round-trips and verifies under its root" {
    const root = testRoot(1);
    const node = Ed25519.KeyPair.generateDeterministic(@splat(7)) catch unreachable;
    const c: Cert = .{
        .node = 3,
        .flags = flag_gossip,
        .image_mask = 1 << 9,
        .serial = 1,
        .node_pk = node.public_key.toBytes(),
    };
    var bytes: [cert_len]u8 = undefined;
    try issue(root, c, &bytes);
    const back = try verify(&bytes, root.public_key.toBytes());
    try std.testing.expectEqual(c.node, back.node);
    try std.testing.expectEqual(c.flags, back.flags);
    try std.testing.expectEqual(c.image_mask, back.image_mask);
    try std.testing.expectEqual(c.serial, back.serial);
    try std.testing.expectEqualSlices(u8, &c.node_pk, &back.node_pk);
}

test "tampered body, wrong root, and wrong version are refused" {
    const root = testRoot(1);
    const other = testRoot(2);
    const node = Ed25519.KeyPair.generateDeterministic(@splat(9)) catch unreachable;
    var bytes: [cert_len]u8 = undefined;
    try issue(root, .{ .node = 2, .flags = flag_gossip | flag_spawn, .image_mask = ~@as(u64, 0), .serial = 4, .node_pk = node.public_key.toBytes() }, &bytes);

    try std.testing.expectError(Error.BadSignature, verify(&bytes, other.public_key.toBytes()));

    var t = bytes;
    t[3] |= 0x80; // grant itself a flag
    try std.testing.expectError(Error.BadSignature, verify(&t, root.public_key.toBytes()));
    t = bytes;
    t[1] = 1; // impersonate node 1
    try std.testing.expectError(Error.BadSignature, verify(&t, root.public_key.toBytes()));
    t = bytes;
    t[0] = 2;
    try std.testing.expectError(Error.BadVersion, verify(&t, root.public_key.toBytes()));

    // A certificate is not a revocation (domain separation).
    try std.testing.expectError(Error.BadSignature, verifyRevocation(bytes[0..rev_len], root.public_key.toBytes()));
}

test "revocation round-trips and binds to its root" {
    const root = testRoot(3);
    var rec: [rev_len]u8 = undefined;
    try issueRevocation(root, .{ .node = 5, .min_serial = 9 }, &rec);
    const r = try verifyRevocation(&rec, root.public_key.toBytes());
    try std.testing.expectEqual(@as(u16, 5), r.node);
    try std.testing.expectEqual(@as(u32, 9), r.min_serial);
    var t = rec;
    t[3] = 1; // lower the bar
    try std.testing.expectError(Error.BadSignature, verifyRevocation(&t, root.public_key.toBytes()));
    try std.testing.expectError(Error.BadSignature, verifyRevocation(&rec, testRoot(4).public_key.toBytes()));
}
