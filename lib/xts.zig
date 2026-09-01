//! AES-256-XTS sector encryption (IEEE P1619 XEX with tweak chaining),
//! pure and allocation-free over std.crypto's AES cores. On the moss
//! target (no NEON yet) this uses the software AES implementation;
//! hardware AES arrives with FP/SIMD enablement (ROADMAP).
//!
//! The unit is one 512-byte sector; the tweak is the absolute physical
//! sector number (dm-crypt convention). Sectors divide evenly into 16-byte
//! blocks, so no ciphertext stealing is needed.

const std = @import("std");
const aes = std.crypto.core.aes;

pub const sector_size = 512;
pub const key_len = 64; // two AES-256 keys

pub const Xts256 = struct {
    enc1: aes.AesEncryptCtx(aes.Aes256),
    dec1: aes.AesDecryptCtx(aes.Aes256),
    enc2: aes.AesEncryptCtx(aes.Aes256), // tweak key

    pub fn init(key: [key_len]u8) Xts256 {
        return .{
            .enc1 = aes.Aes256.initEnc(key[0..32].*),
            .dec1 = aes.Aes256.initDec(key[0..32].*),
            .enc2 = aes.Aes256.initEnc(key[32..64].*),
        };
    }

    const wide = 8; // XTS blocks are independent: run the AES cores wide

    pub fn encryptSector(x: *const Xts256, buf: *[sector_size]u8, sector: u64) void {
        var tw: [sector_size]u8 align(16) = undefined;
        x.tweakRun(&tw, sector);
        xorAll(buf, &tw);
        var i: usize = 0;
        while (i < sector_size) : (i += 16 * wide) {
            const b = buf[i..][0 .. 16 * wide];
            x.enc1.encryptWide(wide, b, b);
        }
        xorAll(buf, &tw);
    }

    pub fn decryptSector(x: *const Xts256, buf: *[sector_size]u8, sector: u64) void {
        var tw: [sector_size]u8 align(16) = undefined;
        x.tweakRun(&tw, sector);
        xorAll(buf, &tw);
        var i: usize = 0;
        while (i < sector_size) : (i += 16 * wide) {
            const b = buf[i..][0 .. 16 * wide];
            x.dec1.decryptWide(wide, b, b);
        }
        xorAll(buf, &tw);
    }

    /// The 32 per-block tweaks of one sector: E(K2, sector) then GF
    /// doubling — a cheap serial shift chain.
    fn tweakRun(x: *const Xts256, tw: *[sector_size]u8, sector: u64) void {
        var t = x.tweak(sector);
        var i: usize = 0;
        while (i < sector_size) : (i += 16) {
            @memcpy(tw[i..][0..16], &t);
            gfDouble(&t);
        }
    }

    fn tweak(x: *const Xts256, sector: u64) [16]u8 {
        var plain: [16]u8 = @splat(0);
        std.mem.writeInt(u64, plain[0..8], sector, .little);
        var t: [16]u8 = undefined;
        x.enc2.encrypt(&t, &plain);
        return t;
    }
};

fn xorAll(b: *[sector_size]u8, t: *const [sector_size]u8) void {
    var i: usize = 0;
    while (i < sector_size) : (i += 8) {
        const x = std.mem.readInt(u64, b[i..][0..8], .little) ^
            std.mem.readInt(u64, t[i..][0..8], .little);
        std.mem.writeInt(u64, b[i..][0..8], x, .little);
    }
}

/// Multiply by x in GF(2^128), little-endian byte order, P1619 polynomial.
fn gfDouble(t: *[16]u8) void {
    const lo = std.mem.readInt(u64, t[0..8], .little);
    const hi = std.mem.readInt(u64, t[8..16], .little);
    var nlo = lo << 1;
    if (hi >> 63 != 0) nlo ^= 0x87;
    std.mem.writeInt(u64, t[0..8], nlo, .little);
    std.mem.writeInt(u64, t[8..16], (hi << 1) | (lo >> 63), .little);
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

// Reference vectors generated with OpenSSL 3.6.3 via python-cryptography:
// key = bytes(range(64)); plaintext = bytes(range(256)) * 2;
// tweak = 16-byte little-endian sector number.
const test_key: [64]u8 = blk: {
    var k: [64]u8 = undefined;
    for (&k, 0..) |*b, i| b.* = @intCast(i);
    break :blk k;
};

fn refPlain() [512]u8 {
    var p: [512]u8 = undefined;
    for (&p, 0..) |*b, i| b.* = @truncate(i);
    return p;
}

test "reference vector: sector 0" {
    const x = Xts256.init(test_key);
    var buf = refPlain();
    x.encryptSector(&buf, 0);
    var head: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&head, "dc8c665b97cbc0246d4f1639a9678a3e2a2dcf4a3fbf1342ebbb771234f1a1c3");
    var tail: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&tail, "3c88ac86abd05303e21acdf2908ecfd5f04100379dedfce370af7f179a14ca5a");
    try testing.expectEqualSlices(u8, &head, buf[0..32]);
    try testing.expectEqualSlices(u8, &tail, buf[480..512]);
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&buf, &sha, .{});
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "a53d4b3da1fb62790761c71f13185869d39106ced357a3ba2b83e7bdeb9dce46");
    try testing.expectEqualSlices(u8, &want, &sha);
}

test "reference vector: sector 0x123456789a (tweak sensitivity)" {
    const x = Xts256.init(test_key);
    var buf = refPlain();
    x.encryptSector(&buf, 0x123456789a);
    var head: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&head, "1ad4aaecba8050a2cdaaa7327fec9bf450bf671c1fb491a77a01bb3517f343cc");
    try testing.expectEqualSlices(u8, &head, buf[0..32]);
    var sha: [32]u8 = undefined;
    std.crypto.hash.sha2.Sha256.hash(&buf, &sha, .{});
    var want: [32]u8 = undefined;
    _ = try std.fmt.hexToBytes(&want, "6fbe438b3044f915145b387cd315781ee22cc8410dc24d7f9c2cd5bb48a04794");
    try testing.expectEqualSlices(u8, &want, &sha);
}

test "roundtrip across sectors and keys" {
    var prng = std.Random.DefaultPrng.init(0x1e57);
    var key: [64]u8 = undefined;
    prng.random().bytes(&key);
    const x = Xts256.init(key);
    for ([_]u64{ 0, 1, 8, 0xffff, 1 << 40 }) |sector| {
        var buf: [512]u8 = undefined;
        prng.random().bytes(&buf);
        const orig = buf;
        x.encryptSector(&buf, sector);
        try testing.expect(!std.mem.eql(u8, &orig, &buf));
        x.decryptSector(&buf, sector);
        try testing.expectEqualSlices(u8, &orig, &buf);
    }
}

test "XTS block independence: a plaintext bit flip scrambles only its 16B block" {
    const x = Xts256.init(test_key);
    var a = refPlain();
    var b = refPlain();
    b[100] ^= 1; // inside block 6 (bytes 96..112)
    x.encryptSector(&a, 7);
    x.encryptSector(&b, 7);
    for (0..32) |blkidx| {
        const same = std.mem.eql(u8, a[blkidx * 16 ..][0..16], b[blkidx * 16 ..][0..16]);
        try testing.expectEqual(blkidx != 6, same);
    }
}

test "different sectors, same plaintext, different ciphertext" {
    const x = Xts256.init(test_key);
    var a = refPlain();
    var b = refPlain();
    x.encryptSector(&a, 1);
    x.encryptSector(&b, 2);
    try testing.expect(!std.mem.eql(u8, &a, &b));
}
