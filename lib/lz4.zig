//! LZ4 block format (no frame), pure and allocation-free — the moss
//! static-module pattern: freestanding-safe, host-tested, compiled into
//! whatever needs it.
//!
//! The decoder is *output-driven* and fully bounds-checked: it stops
//! cleanly when the destination is full and ignores any trailing input
//! bytes. mossfs stores compressed blocks padded to sector boundaries and
//! LZ4 is not self-terminating, so "decode until the logical block is
//! reconstructed" is the format contract, and hostile input must never
//! read or write out of bounds (the block checksum is verified before
//! decoding, but the decoder does not rely on that).
//!
//! The encoder is a greedy single-pass matcher over a caller-provided
//! hash table (no hidden state, no allocation). Inputs are capped at
//! 64KB — position indices and match offsets are u16.

const std = @import("std");

pub const max_input = 65535;

/// Encoder scratch state. Zero-init is NOT valid — compress() resets it.
pub const EncTable = struct {
    /// Hashed 4-byte prefixes -> source position; 0xffff = empty.
    pos: [4096]u16 = undefined,
};

const empty_slot: u16 = 0xffff;
const min_match = 4;
/// Spec: the last match must start at least 12 bytes before the end, and
/// the last 5 bytes are always literals.
const mf_limit = 12;
const last_literals = 5;

fn hash4(v: u32) u12 {
    return @truncate((v *% 2654435761) >> 20);
}

fn read32(src: []const u8, i: usize) u32 {
    return std.mem.readInt(u32, src[i..][0..4], .little);
}

/// Compress src into dst. Returns the compressed length, or null when the
/// result would not fit in dst (treat as incompressible and store raw).
pub fn compress(src: []const u8, dst: []u8, tbl: *EncTable) ?usize {
    if (src.len > max_input) return null;
    @memset(&tbl.pos, empty_slot);

    var op: usize = 0; // dst write position
    var anchor: usize = 0; // start of pending literals
    var ip: usize = 0;

    if (src.len >= mf_limit + 1) {
        const limit = src.len - mf_limit;
        while (ip < limit) {
            const h = hash4(read32(src, ip));
            const cand = tbl.pos[h];
            tbl.pos[h] = @intCast(ip);
            if (cand != empty_slot and cand < ip and
                read32(src, cand) == read32(src, ip))
            {
                // Extend the match, never into the final-literals region.
                const max_len = src.len - last_literals - ip;
                var mlen: usize = min_match;
                while (mlen < max_len and src[cand + mlen] == src[ip + mlen]) mlen += 1;
                op = emitSequence(src[anchor..ip], @intCast(ip - cand), mlen, dst, op) orelse return null;
                ip += mlen;
                anchor = ip;
                continue;
            }
            ip += 1;
        }
    }
    // Final literals-only sequence.
    op = emitSequence(src[anchor..], 0, 0, dst, op) orelse return null;
    return op;
}

/// Emit one sequence: literals, then (when mlen > 0) offset + match.
fn emitSequence(lit: []const u8, offset: u16, mlen: usize, dst: []u8, op0: usize) ?usize {
    var op = op0;
    if (op >= dst.len) return null;
    const token_at = op;
    op += 1;

    var token: u8 = 0;
    if (lit.len >= 15) {
        token |= 0xf0;
        var rest = lit.len - 15;
        while (rest >= 255) : (rest -= 255) {
            if (op >= dst.len) return null;
            dst[op] = 255;
            op += 1;
        }
        if (op >= dst.len) return null;
        dst[op] = @intCast(rest);
        op += 1;
    } else {
        token |= @as(u8, @intCast(lit.len)) << 4;
    }
    if (op + lit.len > dst.len) return null;
    @memcpy(dst[op .. op + lit.len], lit);
    op += lit.len;

    if (mlen > 0) {
        if (op + 2 > dst.len) return null;
        std.mem.writeInt(u16, dst[op..][0..2], offset, .little);
        op += 2;
        const mcode = mlen - min_match;
        if (mcode >= 15) {
            token |= 0x0f;
            var rest = mcode - 15;
            while (rest >= 255) : (rest -= 255) {
                if (op >= dst.len) return null;
                dst[op] = 255;
                op += 1;
            }
            if (op >= dst.len) return null;
            dst[op] = @intCast(rest);
            op += 1;
        } else {
            token |= @intCast(mcode);
        }
    }
    dst[token_at] = token;
    return op;
}

pub const DecodeError = error{Malformed};

/// Decompress src into dst. Output-driven: returns the bytes written,
/// stopping cleanly when dst is full (trailing input ignored) or when the
/// input ends on a literals-only final sequence. Every access is
/// bounds-checked; malformed input returns an error, never UB.
pub fn decompress(src: []const u8, dst: []u8) DecodeError!usize {
    var ip: usize = 0;
    var op: usize = 0;
    while (true) {
        if (ip >= src.len) return op; // clean end between sequences
        const token = src[ip];
        ip += 1;

        // Literals.
        var llen: usize = token >> 4;
        if (llen == 15) {
            while (true) {
                if (ip >= src.len) return error.Malformed;
                const b = src[ip];
                ip += 1;
                llen += b;
                if (b != 255) break;
            }
        }
        if (ip + llen > src.len) return error.Malformed;
        if (op + llen > dst.len) return error.Malformed;
        @memcpy(dst[op .. op + llen], src[ip .. ip + llen]);
        ip += llen;
        op += llen;
        if (op == dst.len) return op; // output complete
        if (ip == src.len) return op; // literals-only final sequence

        // Match.
        if (ip + 2 > src.len) return error.Malformed;
        const offset = std.mem.readInt(u16, src[ip..][0..2], .little);
        ip += 2;
        if (offset == 0 or offset > op) return error.Malformed;
        var mlen: usize = (token & 0x0f) + min_match;
        if (token & 0x0f == 15) {
            while (true) {
                if (ip >= src.len) return error.Malformed;
                const b = src[ip];
                ip += 1;
                mlen += b;
                if (b != 255) break;
            }
        }
        if (op + mlen > dst.len) return error.Malformed;
        // Overlapping copy semantics: strictly byte-by-byte, forward.
        for (0..mlen) |i| dst[op + i] = dst[op - offset + i];
        op += mlen;
        if (op == dst.len) return op;
    }
}

// ----------------------------------------------------------------- tests

const testing = std.testing;

fn roundtrip(src: []const u8) !void {
    var tbl: EncTable = .{};
    var comp: [70000]u8 = undefined;
    var out: [70000]u8 = undefined;
    const clen = compress(src, &comp, &tbl) orelse return error.TestNoFit;
    const dlen = try decompress(comp[0..clen], out[0..src.len]);
    try testing.expectEqual(src.len, dlen);
    try testing.expectEqualSlices(u8, src, out[0..dlen]);
}

test "reference vector: 100 x 'a' (encoder-compatible stream decodes)" {
    // lz4.block.compress(b"a"*100, store_size=False)
    const ref = [_]u8{ 0x1f, 0x61, 0x01, 0x00, 0x4b, 0x50, 0x61, 0x61, 0x61, 0x61, 0x61 };
    var out: [100]u8 = undefined;
    const n = try decompress(&ref, &out);
    try testing.expectEqual(@as(usize, 100), n);
    for (out) |c| try testing.expectEqual(@as(u8, 'a'), c);
}

test "reference vector: 4K cycling bytes decodes to original" {
    const hex = "fff1000102030405060708090a0b0c0d0e0f101112131415161718191a1b1c1d1e1f202122232425262728292a2b2c2d2e2f303132333435363738393a3b3c3d3e3f404142434445464748494a4b4c4d4e4f505152535455565758595a5b5c5d5e5f606162636465666768696a6b6c6d6e6f707172737475767778797a7b7c7d7e7f808182838485868788898a8b8c8d8e8f909192939495969798999a9b9c9d9e9fa0a1a2a3a4a5a6a7a8a9aaabacadaeafb0b1b2b3b4b5b6b7b8b9babbbcbdbebfc0c1c2c3c4c5c6c7c8c9cacbcccdcecfd0d1d2d3d4d5d6d7d8d9dadbdcdddedfe0e1e2e3e4e5e6e7e8e9eaebecedeeeff0f1f2f3f4f5f6f7f8f9fafbfcfdfeff0001fffffffffffffffffffffffffffff650fbfcfdfeff";
    var ref: [281]u8 = undefined;
    _ = try std.fmt.hexToBytes(&ref, hex);
    var out: [4096]u8 = undefined;
    const n = try decompress(&ref, &out);
    try testing.expectEqual(@as(usize, 4096), n);
    for (out, 0..) |c, i| try testing.expectEqual(@as(u8, @truncate(i)), c);
}

test "reference vector: english text decodes to original" {
    const hex = "f01074686520717569636b2062726f776e20666f78206a756d7073206f766572201f00816c617a7920646f670d000f2c00ffffffffffffffffffffffffffffff3f5020646f6720";
    var ref: [71]u8 = undefined;
    _ = try std.fmt.hexToBytes(&ref, hex);
    const expect = "the quick brown fox jumps over the lazy dog " ** 90;
    var out: [expect.len]u8 = undefined;
    const n = try decompress(&ref, &out);
    try testing.expectEqual(expect.len, n);
    try testing.expectEqualSlices(u8, expect, out[0..n]);
}

test "roundtrip: patterns, text, incompressible" {
    try roundtrip("");
    try roundtrip("short");
    try roundtrip("a" ** 4096);
    try roundtrip("the quick brown fox jumps over the lazy dog " ** 90);
    var cyc: [4096]u8 = undefined;
    for (&cyc, 0..) |*c, i| c.* = @truncate(i);
    try roundtrip(&cyc);
    var prng = std.Random.DefaultPrng.init(0x1234);
    var rnd: [4096]u8 = undefined;
    prng.random().bytes(&rnd);
    try roundtrip(&rnd); // random: roundtrips even though it will not shrink
    var mixed: [8192]u8 = undefined;
    prng.random().bytes(mixed[0..1024]);
    @memset(mixed[1024..], 0);
    try roundtrip(&mixed);
}

test "compress returns null when dst is too small" {
    var tbl: EncTable = .{};
    var prng = std.Random.DefaultPrng.init(9);
    var rnd: [4096]u8 = undefined;
    prng.random().bytes(&rnd);
    var tiny: [512]u8 = undefined;
    try testing.expectEqual(@as(?usize, null), compress(&rnd, &tiny, &tbl));
}

test "output-driven: trailing pad after full output is ignored" {
    var tbl: EncTable = .{};
    const src = "abcdefgh" ** 512; // 4096
    var comp: [4200]u8 = undefined;
    const clen = compress(src, &comp, &tbl).?;
    // Pad to a sector multiple, as mossfs does.
    const padded = (clen + 511) / 512 * 512;
    @memset(comp[clen..padded], 0xaa);
    var out: [4096]u8 = undefined;
    const n = try decompress(comp[0..padded], &out);
    try testing.expectEqual(@as(usize, 4096), n);
    try testing.expectEqualSlices(u8, src, &out);
}

test "hostile input never overruns" {
    var out: [256]u8 = undefined;
    // Literal run past end of input.
    try testing.expectError(error.Malformed, decompress(&.{0xf0}, &out));
    // Offset zero.
    try testing.expectError(error.Malformed, decompress(&.{ 0x10, 'x', 0, 0, 0 }, &out));
    // Offset beyond written output.
    try testing.expectError(error.Malformed, decompress(&.{ 0x10, 'x', 9, 0, 0 }, &out));
    // Match overruns dst.
    var small: [4]u8 = undefined;
    try testing.expectError(error.Malformed, decompress(&.{ 0x1f, 'x', 1, 0, 200 }, &small));
    // Random garbage: must error or return cleanly, never crash.
    var prng = std.Random.DefaultPrng.init(0xfeed);
    var junk: [512]u8 = undefined;
    for (0..2000) |_| {
        prng.random().bytes(&junk);
        _ = decompress(&junk, &out) catch continue;
    }
}
