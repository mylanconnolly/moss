//! User credentials — a user is a key, not a number. A user record holds
//! an Ed25519 **identity** (its public half in the clear) and the
//! identity's 32-byte seed sealed under a key derived from a passphrase
//! (scrypt, memory-hard; parameters live in the record so a deployment
//! picks its own cost). Logging in is unsealing the seed and checking
//! that the key it regenerates is the one on record: no password hash is
//! ever compared, and the same key later signs challenges (fabric logins)
//! or derives a home-volume key. Nothing here is a uid, a group, or a
//! mode bit. Pure and freestanding-safe: the KDF takes an allocator for
//! its work area (128 * 2^ln * r bytes); `zig test lib/lib.zig` covers it
//! on the host.

const std = @import("std");

pub const Ed25519 = std.crypto.sign.Ed25519;
const scrypt = std.crypto.pwhash.scrypt;
const Aead = std.crypto.aead.aegis.Aegis256;

pub const seed_len: usize = 32;
pub const pk_len: usize = 32;
pub const salt_len: usize = 16;
pub const tag_len: usize = Aead.tag_length; // 16
pub const sealed_len: usize = seed_len + tag_len; // 48

/// scrypt cost. `ln` is log2(N); memory is 128 * 2^ln * r bytes.
pub const Kdf = struct {
    ln: u6 = 12,
    r: u30 = 8,
    p: u30 = 1,

    pub fn memoryBytes(k: Kdf) usize {
        return 128 * (@as(usize, 1) << k.ln) * k.r;
    }
};

pub const Record = struct {
    pk: [pk_len]u8,
    salt: [salt_len]u8,
    sealed: [sealed_len]u8,
    kdf: Kdf,
};

pub const Error = error{ OutOfMemory, WeakParameters, BadKey };

// The seal's nonce is fixed: the key it protects is derived from a
// per-user random salt and used exactly once per seal, so it is unique
// by construction; a label separates it from any other use of the key.
const seal_label = "moss-user-seed-v1";
const seal_nonce: [Aead.nonce_length]u8 = @splat(0);

/// Derive the sealing key from a passphrase.
fn kek(allocator: std.mem.Allocator, out: *[32]u8, passphrase: []const u8, salt: *const [salt_len]u8, kdf: Kdf) Error!void {
    scrypt.kdf(allocator, out, passphrase, salt, .{ .ln = kdf.ln, .r = kdf.r, .p = kdf.p }) catch |e| switch (e) {
        error.OutOfMemory => return Error.OutOfMemory,
        else => return Error.WeakParameters,
    };
}

/// Make a record from fresh random material (seed, salt) and a passphrase.
pub fn create(allocator: std.mem.Allocator, seed: *const [seed_len]u8, salt: *const [salt_len]u8, passphrase: []const u8, kdf: Kdf) Error!Record {
    const kp = Ed25519.KeyPair.generateDeterministic(seed.*) catch return Error.BadKey;
    var key: [32]u8 = undefined;
    defer @memset(&key, 0);
    try kek(allocator, &key, passphrase, salt, kdf);
    var rec: Record = .{ .pk = kp.public_key.toBytes(), .salt = salt.*, .sealed = undefined, .kdf = kdf };
    var tag: [tag_len]u8 = undefined;
    Aead.encrypt(rec.sealed[0..seed_len], &tag, seed, seal_label, seal_nonce, key);
    @memcpy(rec.sealed[seed_len..], &tag);
    return rec;
}

/// Prove a passphrase: unseal the seed and regenerate the identity. On
/// success the key pair is the user's identity, in the caller's custody.
pub fn unlock(allocator: std.mem.Allocator, rec: *const Record, passphrase: []const u8) Error!Ed25519.KeyPair {
    var key: [32]u8 = undefined;
    defer @memset(&key, 0);
    try kek(allocator, &key, passphrase, &rec.salt, rec.kdf);
    var seed: [seed_len]u8 = undefined;
    defer @memset(&seed, 0);
    Aead.decrypt(&seed, rec.sealed[0..seed_len], rec.sealed[seed_len..].*, seal_label, seal_nonce, key) catch return Error.BadKey;
    const kp = Ed25519.KeyPair.generateDeterministic(seed) catch return Error.BadKey;
    if (!std.crypto.timing_safe.eql([pk_len]u8, kp.public_key.toBytes(), rec.pk)) return Error.BadKey;
    return kp;
}

/// The key of the user's home volume, derived from the identity: the
/// same identity always opens the same volume, and nothing but the
/// unlocked identity can derive it (HKDF over the seed, labeled).
pub fn homeKey(kp: Ed25519.KeyPair) [32]u8 {
    const Hkdf = std.crypto.kdf.hkdf.HkdfSha256;
    const sk = kp.secret_key.toBytes();
    const prk = Hkdf.extract("moss-home-volume-v1", sk[0..seed_len]);
    var out: [32]u8 = undefined;
    Hkdf.expand(&out, "home", prk);
    return out;
}

// -------------------------------------------------------------- hex I/O
//
// Records travel as mshl data literals with hex-string fields; these are
// the only encoders the record needs.

pub fn hexEncode(out: []u8, bytes: []const u8) []const u8 {
    const digits = "0123456789abcdef";
    for (bytes, 0..) |b, i| {
        out[i * 2] = digits[b >> 4];
        out[i * 2 + 1] = digits[b & 15];
    }
    return out[0 .. bytes.len * 2];
}

pub fn hexDecode(out: []u8, text: []const u8) ?[]const u8 {
    if (text.len != out.len * 2) return null;
    for (out, 0..) |*b, i| {
        const hi = nibble(text[i * 2]) orelse return null;
        const lo = nibble(text[i * 2 + 1]) orelse return null;
        b.* = hi << 4 | lo;
    }
    return out;
}

fn nibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

// ------------------------------------------------------------------ tests

const test_kdf: Kdf = .{ .ln = 8, .r = 8, .p = 1 }; // fast on the host

test "a passphrase unlocks the identity it sealed" {
    const a = std.testing.allocator;
    const seed: [32]u8 = @splat(0x11);
    const salt: [16]u8 = @splat(0x22);
    const rec = try create(a, &seed, &salt, "correct horse", test_kdf);
    const kp = try unlock(a, &rec, "correct horse");
    try std.testing.expectEqualSlices(u8, &rec.pk, &kp.public_key.toBytes());
    const expect = try Ed25519.KeyPair.generateDeterministic(seed);
    try std.testing.expectEqualSlices(u8, &expect.public_key.toBytes(), &kp.public_key.toBytes());
}

test "the wrong passphrase, a tampered seal, and a swapped key are refused" {
    const a = std.testing.allocator;
    const seed: [32]u8 = @splat(0x33);
    const salt: [16]u8 = @splat(0x44);
    const rec = try create(a, &seed, &salt, "hunter2", test_kdf);
    try std.testing.expectError(Error.BadKey, unlock(a, &rec, "hunter3"));
    var t = rec;
    t.sealed[5] ^= 1;
    try std.testing.expectError(Error.BadKey, unlock(a, &t, "hunter2"));
    t = rec;
    t.salt[0] ^= 1; // a different salt derives a different sealing key
    try std.testing.expectError(Error.BadKey, unlock(a, &t, "hunter2"));
    t = rec;
    t.pk[0] ^= 1; // a record claiming another identity for this seed
    try std.testing.expectError(Error.BadKey, unlock(a, &t, "hunter2"));
}

test "the home key follows the identity, not the passphrase" {
    const a = std.testing.allocator;
    const seed: [32]u8 = @splat(0x55);
    const salt: [16]u8 = @splat(0x66);
    const rec1 = try create(a, &seed, &salt, "one", test_kdf);
    const rec2 = try create(a, &seed, &salt, "two", test_kdf);
    const k1 = homeKey(try unlock(a, &rec1, "one"));
    const k2 = homeKey(try unlock(a, &rec2, "two"));
    try std.testing.expectEqualSlices(u8, &k1, &k2);
    try std.testing.expect(!std.mem.eql(u8, &k1, &seed));
    const other = try create(a, &[_]u8{0x56} ** 32, &salt, "one", test_kdf);
    try std.testing.expect(!std.mem.eql(u8, &k1, &homeKey(try unlock(a, &other, "one"))));
}

test "hex round-trips and refuses bad input" {
    var hex: [96]u8 = undefined;
    const bytes: [48]u8 = @splat(0xa5);
    const text = hexEncode(&hex, &bytes);
    var back: [48]u8 = undefined;
    try std.testing.expectEqualSlices(u8, &bytes, hexDecode(&back, text).?);
    try std.testing.expect(hexDecode(&back, text[0..94]) == null);
    var bad: [96]u8 = @splat('g');
    try std.testing.expect(hexDecode(&back, &bad) == null);
}
