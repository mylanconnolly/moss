//! brotli — a from-scratch Brotli decompressor (RFC 7932), pure and
//! freestanding-safe, host-tested. moss needs it for WOFF2 fonts, whose
//! tables are a raw Brotli stream; the decoder is generic, so it is a
//! standalone `lib/` module rather than buried in the font code.
//!
//! It is a straight-through decoder: the whole compressed input and the
//! exact decompressed size are known up front (WOFF2 states the size), so
//! there is no incremental/resumable state machine and no ring buffer —
//! the output buffer *is* the window, and back-references index into it.
//! The algorithm and every constant table are faithful to the reference
//! decoder (bit reader, prefix codes, block/context machinery, the static
//! dictionary + word transforms); the fast lookup tables of the reference
//! are replaced by a plain canonical prefix-code walk, which is simple and
//! plenty fast for a ~10 KB font stream decoded once and cached.
//!
//! The 122 KB static dictionary and the 2 KB context-lookup table are
//! embedded as binary assets, and the word transforms compiled in as data.
//! These fixed tables are defined by RFC 7932 and extracted verbatim from
//! the reference implementation (github.com/google/brotli), which is MIT
//! licensed — see brotli/LICENSE. The decoder logic here is an independent
//! from-scratch implementation.

const std = @import("std");

pub const Error = error{ BadStream, Unsupported, OutOfMemory };

// ---------------------------------------------------------- embedded data

/// The RFC 7932 static dictionary (122784 bytes) and per-length geometry.
const dict_data = @embedFile("brotli/dict.bin");
// size_bits_by_length[L] = log2(number of dictionary words of length L);
// offsets_by_length[L] = byte offset in dict_data where length-L words begin.
const dict_size_bits = [25]u8{ 0, 0, 0, 0, 10, 10, 11, 11, 10, 10, 10, 10, 10, 9, 9, 8, 7, 7, 8, 7, 7, 6, 6, 5, 5 };
const dict_offsets = [25]u32{ 0, 0, 0, 0, 0, 4096, 9216, 21504, 35840, 44032, 53248, 63488, 74752, 87040, 93696, 100864, 104704, 106752, 108928, 113536, 115968, 118528, 119872, 121280, 122016 };
const dict_min_len = 4;
const dict_max_len = 24;

/// The context-lookup table: four 512-byte modes (LSB6, MSB6, UTF8, Signed),
/// each split into a 256-byte last-byte lookup and a 256-byte prior-byte
/// lookup. `context = tbl[mode*512 + p1] | tbl[mode*512 + 256 + p2]`.
const ctx_lut = @embedFile("brotli/ctx.bin");

// Word-transform data (RFC 7932 §8). `prefix_suffix` holds length-prefixed
// strings; `ps_map[id]` is the offset of string `id`; each transform is a
// triple {prefix_id, type, suffix_id}.
const prefix_suffix = [_]u8{ 1, 32, 2, 44, 32, 8, 32, 111, 102, 32, 116, 104, 101, 32, 4, 32, 111, 102, 32, 2, 115, 32, 1, 46, 5, 32, 97, 110, 100, 32, 4, 32, 105, 110, 32, 1, 34, 4, 32, 116, 111, 32, 2, 34, 62, 1, 10, 2, 46, 32, 1, 93, 5, 32, 102, 111, 114, 32, 3, 32, 97, 32, 6, 32, 116, 104, 97, 116, 32, 1, 39, 6, 32, 119, 105, 116, 104, 32, 6, 32, 102, 114, 111, 109, 32, 4, 32, 98, 121, 32, 1, 40, 6, 46, 32, 84, 104, 101, 32, 4, 32, 111, 110, 32, 4, 32, 97, 115, 32, 4, 32, 105, 115, 32, 4, 105, 110, 103, 32, 2, 10, 9, 1, 58, 3, 101, 100, 32, 2, 61, 34, 4, 32, 97, 116, 32, 3, 108, 121, 32, 1, 44, 2, 61, 39, 5, 46, 99, 111, 109, 47, 7, 46, 32, 84, 104, 105, 115, 32, 5, 32, 110, 111, 116, 32, 3, 101, 114, 32, 3, 97, 108, 32, 4, 102, 117, 108, 32, 4, 105, 118, 101, 32, 5, 108, 101, 115, 115, 32, 4, 101, 115, 116, 32, 4, 105, 122, 101, 32, 2, 194, 160, 4, 111, 117, 115, 32, 5, 32, 116, 104, 101, 32, 2, 101, 32, 0 };
const ps_map = [_]u16{ 0, 2, 5, 14, 19, 22, 24, 30, 35, 37, 42, 45, 47, 50, 52, 58, 62, 69, 71, 78, 85, 90, 92, 99, 104, 109, 114, 119, 122, 124, 128, 131, 136, 140, 142, 145, 151, 159, 165, 169, 173, 178, 183, 189, 194, 199, 202, 207, 213, 216 };
// 121 transforms × {prefix_id, type, suffix_id}.
const transforms_data = [_]u8{ 49, 0, 49, 49, 0, 0, 0, 0, 0, 49, 12, 49, 49, 10, 0, 49, 0, 47, 0, 0, 49, 4, 0, 0, 49, 0, 3, 49, 10, 49, 49, 0, 6, 49, 13, 49, 49, 1, 49, 1, 0, 0, 49, 0, 1, 0, 10, 0, 49, 0, 7, 49, 0, 9, 48, 0, 0, 49, 0, 8, 49, 0, 5, 49, 0, 10, 49, 0, 11, 49, 3, 49, 49, 0, 13, 49, 0, 14, 49, 14, 49, 49, 2, 49, 49, 0, 15, 49, 0, 16, 0, 10, 49, 49, 0, 12, 5, 0, 49, 0, 0, 1, 49, 15, 49, 49, 0, 18, 49, 0, 17, 49, 0, 19, 49, 0, 20, 49, 16, 49, 49, 17, 49, 47, 0, 49, 49, 4, 49, 49, 0, 22, 49, 11, 49, 49, 0, 23, 49, 0, 24, 49, 0, 25, 49, 7, 49, 49, 1, 26, 49, 0, 27, 49, 0, 28, 0, 0, 12, 49, 0, 29, 49, 20, 49, 49, 18, 49, 49, 6, 49, 49, 0, 21, 49, 10, 1, 49, 8, 49, 49, 0, 31, 49, 0, 32, 47, 0, 3, 49, 5, 49, 49, 9, 49, 0, 10, 1, 49, 10, 8, 5, 0, 21, 49, 11, 0, 49, 10, 10, 49, 0, 30, 0, 0, 5, 35, 0, 49, 47, 0, 2, 49, 10, 17, 49, 0, 36, 49, 0, 33, 5, 0, 0, 49, 10, 21, 49, 10, 5, 49, 0, 37, 0, 0, 30, 49, 0, 38, 0, 11, 0, 49, 0, 39, 0, 11, 49, 49, 0, 34, 49, 11, 8, 49, 10, 12, 0, 0, 21, 49, 0, 40, 0, 10, 12, 49, 0, 41, 49, 0, 42, 49, 11, 17, 49, 0, 43, 0, 10, 5, 49, 11, 10, 0, 0, 34, 49, 10, 33, 49, 0, 44, 49, 11, 5, 45, 0, 49, 0, 0, 33, 49, 10, 30, 49, 11, 30, 49, 0, 46, 49, 11, 1, 49, 10, 34, 0, 10, 33, 0, 11, 30, 0, 11, 1, 49, 11, 33, 49, 11, 21, 49, 11, 12, 0, 11, 5, 49, 11, 34, 0, 11, 12, 0, 10, 30, 0, 11, 34, 0, 10, 34 };
const num_transforms = 121;

// Transform types (RFC 7932 §8).
const T_IDENTITY = 0;
const T_OMIT_LAST_1 = 1;
const T_OMIT_LAST_9 = 9;
const T_UPPERCASE_FIRST = 10;
const T_UPPERCASE_ALL = 11;
const T_OMIT_FIRST_1 = 12;
const T_OMIT_FIRST_9 = 20;

// ------------------------------------------------------------ constants

// Insert-length codes: {base, extra_bits}, indexed by insert code (0..23).
const insert_base = [24]u32{ 0, 1, 2, 3, 4, 5, 6, 8, 10, 14, 18, 26, 34, 50, 66, 98, 130, 194, 322, 578, 1090, 2114, 6210, 22594 };
const insert_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 12, 14, 24 };
// Copy-length codes: {base, extra_bits}, indexed by copy code (0..23).
const copy_base = [24]u32{ 2, 3, 4, 5, 6, 7, 8, 9, 10, 12, 14, 18, 22, 30, 38, 54, 70, 102, 134, 198, 326, 582, 1094, 2118 };
const copy_extra = [24]u5{ 0, 0, 0, 0, 0, 0, 0, 0, 1, 1, 2, 2, 3, 3, 4, 4, 5, 5, 6, 7, 8, 9, 10, 24 };
// Block-count codes: {base, extra_bits}, indexed by block-count symbol (0..25).
const block_base = [26]u32{ 1, 5, 9, 13, 17, 25, 33, 41, 49, 65, 81, 97, 113, 145, 177, 209, 241, 305, 369, 497, 753, 1265, 2289, 4337, 8433, 16625 };
const block_extra = [26]u5{ 2, 2, 2, 2, 3, 3, 3, 3, 4, 4, 4, 4, 5, 5, 5, 5, 6, 6, 7, 8, 9, 10, 11, 12, 13, 24 };

// Command-code decode: a command symbol's high bits pick a "cell", whose
// position (kCellPos) splits the low bits into insert and copy codes.
//   cell = cmd >> 6; pos = kCellPos[cell]
//   insert_code = (pos & 0x18) + ((cmd >> 3) & 7)
//   copy_code   = ((pos << 3) & 0x18) + (cmd & 7)
// The distance is implicitly the last distance (no code follows) when the
// cell index is < 2 (cmd < 128).
const cell_pos_lut = [11]u8{ 0, 1, 0, 1, 8, 9, 2, 16, 10, 17, 18 };

// Reading the 18 code-length code-lengths: peek 4 bits, index these.
const cl_prefix_len = [16]u3{ 2, 2, 2, 3, 2, 2, 2, 4, 2, 2, 2, 3, 2, 2, 2, 4 };
const cl_prefix_val = [16]u8{ 0, 4, 3, 2, 0, 4, 3, 1, 0, 4, 3, 2, 0, 4, 3, 5 };
const code_length_order = [18]u8{ 1, 2, 3, 4, 0, 5, 17, 6, 16, 7, 8, 9, 10, 11, 12, 13, 14, 15 };

const repeat_prev = 16; // code length 16: repeat previous
const repeat_zero = 17; // code length 17: repeat zero
const initial_repeated_code_length = 8;
const num_dist_short = 16;
const literal_context_bits = 6;
const distance_context_bits = 2;

// ------------------------------------------------------------ bit reader

/// LSB-first bit reader. Reads past the end are permitted and return zero
/// bits (the reference tolerates a few bits of over-read at the tail).
const BitReader = struct {
    data: []const u8,
    byte_pos: usize = 0,
    buf: u64 = 0,
    cnt: u32 = 0, // valid bits in `buf`

    fn fill(br: *BitReader) void {
        while (br.cnt <= 56 and br.byte_pos < br.data.len) {
            br.buf |= @as(u64, br.data[br.byte_pos]) << @intCast(br.cnt);
            br.byte_pos += 1;
            br.cnt += 8;
        }
    }
    fn readBits(br: *BitReader, n: u32) u32 {
        if (n == 0) return 0;
        if (br.cnt < n) br.fill();
        const mask: u64 = (@as(u64, 1) << @intCast(n)) - 1;
        const v: u32 = @truncate(br.buf & mask);
        br.buf >>= @intCast(n);
        br.cnt = if (br.cnt >= n) br.cnt - n else 0;
        return v;
    }
    fn readBit(br: *BitReader) u32 {
        return br.readBits(1);
    }
    fn peek4(br: *BitReader) u32 {
        if (br.cnt < 4) br.fill();
        return @truncate(br.buf & 0xf);
    }
    /// Peek `n` bits (LSB-first) without consuming; zero-padded past EOF.
    fn peekBits(br: *BitReader, n: u32) u32 {
        if (br.cnt < n) br.fill();
        const mask: u64 = (@as(u64, 1) << @intCast(n)) - 1;
        return @truncate(br.buf & mask);
    }
    fn drop(br: *BitReader, n: u32) void {
        if (n <= br.cnt) {
            br.buf >>= @intCast(n);
            br.cnt -= n;
        } else {
            br.buf = 0;
            br.cnt = 0;
        }
    }
    /// Discard bits back to the next byte boundary of the input.
    fn alignByte(br: *BitReader) void {
        const r = br.cnt & 7;
        if (r != 0) br.drop(r);
    }
    /// The input byte index of the next unread bit (only meaningful when
    /// byte-aligned). Buffered whole bytes are "put back".
    fn bytePos(br: *BitReader) usize {
        return br.byte_pos - br.cnt / 8;
    }
    fn seekByte(br: *BitReader, pos: usize) void {
        br.byte_pos = pos;
        br.buf = 0;
        br.cnt = 0;
    }
};

// ------------------------------------------------------------ huffman

/// A canonical prefix code as a flat lookup table. Brotli packs codes
/// LSB-first, so canonical (MSB-first) codes are bit-reversed and the next
/// `max_len` stream bits index straight into `table`. Each entry packs the
/// code length in the high 4 bits and the symbol in the low 12.
const Huff = struct {
    table: []u16 = &.{},
    max_len: u5 = 0,
    single: i32 = -1, // a one-symbol code emits this reading zero bits

    fn decode(h: *const Huff, br: *BitReader) u16 {
        if (h.single >= 0) return @intCast(h.single);
        const idx = br.peekBits(h.max_len);
        const entry = h.table[idx];
        br.drop(entry >> 12);
        return entry & 0x0fff;
    }
};

fn reverseBits(v: u32, len: u5) u32 {
    var r: u32 = 0;
    var i: u5 = 0;
    while (i < len) : (i += 1) {
        r |= ((v >> i) & 1) << (len - 1 - i);
    }
    return r;
}

/// Build a lookup-table prefix code from per-symbol bit lengths (0 = absent).
fn buildHuff(a: std.mem.Allocator, lengths: []const u8) Error!Huff {
    var h = Huff{};
    var counts: [16]u16 = @splat(0);
    var n: usize = 0;
    var max_len: u5 = 0;
    for (lengths) |l| {
        if (l != 0) {
            counts[l] += 1;
            n += 1;
            if (l > max_len) max_len = @intCast(l);
        }
    }
    if (n == 0) return Error.BadStream;
    if (n == 1) {
        for (lengths, 0..) |l, sym| {
            if (l != 0) h.single = @intCast(sym);
        }
        return h;
    }
    // Canonical (MSB-first) first-code per length.
    var next_code: [16]u32 = @splat(0);
    var code: u32 = 0;
    var len: usize = 1;
    while (len <= 15) : (len += 1) {
        code = (code + counts[len - 1]) << 1;
        next_code[len] = code;
    }
    h.max_len = max_len;
    h.table = try a.alloc(u16, @as(usize, 1) << max_len);
    for (lengths, 0..) |l, sym| {
        if (l == 0) continue;
        const canonical = next_code[l];
        next_code[l] += 1;
        const rev = reverseBits(canonical, @intCast(l));
        const entry: u16 = (@as(u16, @intCast(l)) << 12) | @as(u16, @intCast(sym));
        // Every combination of the unused high bits maps to this symbol.
        const step: u32 = @as(u32, 1) << @intCast(l);
        var slot: u32 = rev;
        while (slot < h.table.len) : (slot += step) h.table[slot] = entry;
    }
    return h;
}

// ------------------------------------------------ reading a prefix code

/// Read a complete prefix code from the stream (simple or complex form),
/// over an alphabet of `alphabet_size` symbols, into a freshly built Huff.
fn readHuffmanCode(a: std.mem.Allocator, br: *BitReader, alphabet_size: usize) Error!Huff {
    const kind = br.readBits(2);
    if (kind == 1) {
        // Simple code: 1..4 explicitly listed symbols.
        const max_bits = log2Ceil(alphabet_size);
        const nsym = br.readBits(2) + 1;
        var syms: [4]u16 = undefined;
        var i: usize = 0;
        while (i < nsym) : (i += 1) {
            const v = br.readBits(max_bits);
            if (v >= alphabet_size) return Error.BadStream;
            syms[i] = @intCast(v);
        }
        var lengths = try a.alloc(u8, alphabet_size);
        defer a.free(lengths);
        @memset(lengths, 0);
        switch (nsym) {
            1 => {
                var h = Huff{};
                h.single = syms[0];
                return h;
            },
            2 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 1;
            },
            3 => {
                lengths[syms[0]] = 1;
                lengths[syms[1]] = 2;
                lengths[syms[2]] = 2;
            },
            4 => {
                const tree_select = br.readBit();
                if (tree_select == 0) {
                    for (0..4) |k| lengths[syms[k]] = 2;
                } else {
                    lengths[syms[0]] = 1;
                    lengths[syms[1]] = 2;
                    lengths[syms[2]] = 3;
                    lengths[syms[3]] = 3;
                }
            },
            else => unreachable,
        }
        return buildHuff(a, lengths);
    }

    // Complex code: `kind` (0/2/3) is HSKIP, the number of leading
    // code-length symbols to skip. First read the 18 code-length code
    // lengths (each 0..5) using the fixed prefix code above.
    const hskip = kind;
    var cl_lengths: [18]u8 = @splat(0);
    var space: i32 = 32;
    var num_codes: usize = 0;
    var i: usize = hskip;
    while (i < 18) : (i += 1) {
        const idx = br.peek4();
        br.drop(cl_prefix_len[idx]);
        const v = cl_prefix_val[idx];
        cl_lengths[code_length_order[i]] = v;
        if (v != 0) {
            space -= @as(i32, 32) >> @intCast(v);
            num_codes += 1;
            if (space <= 0) break;
        }
    }
    if (num_codes != 1 and space != 0) return Error.BadStream;
    var cl_code = try buildHuff(a, &cl_lengths);

    // Then read the alphabet's per-symbol lengths using that code, with
    // repeat operators 16 (repeat previous) and 17 (repeat zero).
    var lengths = try a.alloc(u8, alphabet_size);
    defer a.free(lengths);
    @memset(lengths, 0);
    var symbol: usize = 0;
    var prev_code_len: u8 = initial_repeated_code_length;
    var repeat: u32 = 0;
    var repeat_code_len: u8 = 0;
    var mspace: i64 = 32768;
    while (symbol < alphabet_size and mspace > 0) {
        const code_len = cl_code.decode(br);
        if (code_len < repeat_prev) {
            repeat = 0;
            if (code_len != 0) {
                lengths[symbol] = @intCast(code_len);
                prev_code_len = @intCast(code_len);
                mspace -= @as(i64, 32768) >> @intCast(code_len);
            }
            symbol += 1;
        } else {
            const extra_bits: u5 = if (code_len == repeat_prev) 2 else 3;
            const new_len: u8 = if (code_len == repeat_prev) prev_code_len else 0;
            const repeat_delta = br.readBits(extra_bits);
            if (repeat_code_len != new_len) {
                repeat = 0;
                repeat_code_len = new_len;
            }
            const old_repeat = repeat;
            if (repeat > 0) {
                repeat -= 2;
                repeat <<= extra_bits;
            }
            repeat += repeat_delta + 3;
            const delta = repeat - old_repeat;
            if (symbol + delta > alphabet_size) return Error.BadStream;
            if (repeat_code_len != 0) {
                var k: u32 = 0;
                while (k < delta) : (k += 1) {
                    lengths[symbol] = repeat_code_len;
                    symbol += 1;
                }
                mspace -= @as(i64, delta) * (@as(i64, 32768) >> @intCast(repeat_code_len));
            } else {
                symbol += delta;
            }
        }
    }
    return buildHuff(a, lengths);
}

fn log2Ceil(n: usize) u32 {
    // Bits needed to represent symbols 0..n-1: Log2Floor(n-1)+1 in brotli.
    if (n <= 1) return 0;
    return 32 - @clz(@as(u32, @intCast(n - 1)));
}

// ------------------------------------------------------- context map

/// Decode a context map of `size` entries; returns the map and the number
/// of htrees it references.
fn decodeContextMap(a: std.mem.Allocator, br: *BitReader, size: usize) Error!struct { map: []u8, num_htrees: usize } {
    const num_htrees = try decodeVarLenUint8(br) + 1;
    const map = try a.alloc(u8, size);
    @memset(map, 0);
    if (num_htrees <= 1) return .{ .map = map, .num_htrees = num_htrees };

    // RLE-of-zeros prefix: 1 bit selects RLE; if set, 4 bits give max run.
    var max_run: u32 = 0;
    if (br.readBit() != 0) {
        max_run = br.readBits(4) + 1;
    }

    var code = try readHuffmanCode(a, br, num_htrees + max_run);
    var i: usize = 0;
    while (i < size) {
        const sym = code.decode(br);
        if (sym == 0) {
            map[i] = 0;
            i += 1;
        } else if (sym <= max_run) {
            var reps = br.readBits(@intCast(sym)) + (@as(u32, 1) << @intCast(sym));
            if (i + reps > size) return Error.BadStream;
            while (reps > 0) : (reps -= 1) {
                map[i] = 0;
                i += 1;
            }
        } else {
            map[i] = @intCast(sym - max_run);
            i += 1;
        }
    }
    // Optional inverse move-to-front.
    if (br.readBit() != 0) inverseMoveToFront(map);
    return .{ .map = map, .num_htrees = num_htrees };
}

fn inverseMoveToFront(v: []u8) void {
    var table: [256]u8 = undefined;
    for (0..256) |i| table[i] = @intCast(i);
    for (v) |*e| {
        const index = e.*;
        const value = table[index];
        e.* = value;
        var j: usize = index;
        while (j > 0) : (j -= 1) table[j] = table[j - 1];
        table[0] = value;
    }
}

fn decodeVarLenUint8(br: *BitReader) Error!u32 {
    if (br.readBit() == 0) return 0;
    const n = br.readBits(3);
    if (n == 0) return 1;
    return (@as(u32, 1) << @intCast(n)) + br.readBits(@intCast(n));
}

// ------------------------------------------------------------ decode

const HGroup = struct {
    trees: []Huff,
};

fn readHGroup(a: std.mem.Allocator, br: *BitReader, count: usize, alphabet_size: usize) Error!HGroup {
    const trees = try a.alloc(Huff, count);
    for (trees) |*t| t.* = try readHuffmanCode(a, br, alphabet_size);
    return .{ .trees = trees };
}

/// Per-category block-switch machinery.
const BlockState = struct {
    num_types: usize = 1,
    length: u32 = 1 << 24, // BROTLI_BLOCK_SIZE_CAP
    type_tree: Huff = .{},
    len_tree: Huff = .{},
    rb0: u32 = 1,
    rb1: u32 = 0, // current type = rb1

    fn switchBlock(bs: *BlockState, br: *BitReader) void {
        var t = bs.type_tree.decode(br);
        bs.length = readBlockLength(&bs.len_tree, br);
        var bt: u32 = undefined;
        if (t == 1) {
            bt = bs.rb1 + 1;
        } else if (t == 0) {
            bt = bs.rb0;
        } else {
            bt = @as(u32, t) - 2;
        }
        if (bt >= bs.num_types) bt -= @intCast(bs.num_types);
        bs.rb0 = bs.rb1;
        bs.rb1 = bt;
        t = 0;
    }
};

fn readBlockLength(tree: *const Huff, br: *BitReader) u32 {
    const code = tree.decode(br);
    return block_base[code] + br.readBits(block_extra[code]);
}

/// Decompress a raw Brotli stream `input` into `out` (whose length must be
/// the exact decompressed size). Uses `gpa` as an arena internally.
pub fn decode(gpa: std.mem.Allocator, input: []const u8, out: []u8) Error!void {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    var br = BitReader{ .data = input };

    // Window size (WBITS): consumed for stream conformance; the output
    // buffer is the window, so we only need the max backward distance.
    const wbits = readWindowBits(&br);
    const max_backward: usize = (@as(usize, 1) << @intCast(wbits)) - 16;

    var pos: usize = 0;
    var dist_rb = [4]u32{ 16, 15, 11, 4 };
    var dist_rb_idx: u32 = 0;

    metablock: while (true) {
        // ---- meta-block header ----
        const is_last = br.readBit() != 0;
        if (is_last and br.readBit() != 0) break; // ISLASTEMPTY
        const mnib_code = br.readBits(2);
        if (mnib_code == 3) {
            // Metadata meta-block: reserved bit, MSKIPBYTES, skip bytes.
            if (is_last) return Error.BadStream;
            if (br.readBit() != 0) return Error.BadStream; // reserved
            const skip_bytes = br.readBits(2);
            var skip_len: usize = 0;
            if (skip_bytes != 0) {
                var k: u32 = 0;
                var shift: u5 = 0;
                while (k < skip_bytes) : (k += 1) {
                    skip_len |= @as(usize, br.readBits(8)) << shift;
                    shift += 8;
                }
                skip_len += 1;
            }
            br.alignByte();
            br.seekByte(br.bytePos() + skip_len);
            continue :metablock;
        }
        const nibbles = mnib_code + 4;
        var mlen: usize = 0;
        {
            var k: u32 = 0;
            var shift: u5 = 0;
            while (k < nibbles) : (k += 1) {
                mlen |= @as(usize, br.readBits(4)) << shift;
                shift += 4;
            }
            mlen += 1;
        }
        if (!is_last) {
            if (br.readBit() != 0) {
                // Uncompressed meta-block.
                br.alignByte();
                const src = br.bytePos();
                if (src + mlen > input.len or pos + mlen > out.len) return Error.BadStream;
                @memcpy(out[pos .. pos + mlen], input[src .. src + mlen]);
                pos += mlen;
                br.seekByte(src + mlen);
                continue :metablock;
            }
        }
        if (pos + mlen > out.len) return Error.BadStream;

        // ---- meta-block body header ----
        var lit = BlockState{};
        var cmd = BlockState{};
        var dist = BlockState{};
        try readBlockCategory(a, &br, &lit);
        try readBlockCategory(a, &br, &cmd);
        try readBlockCategory(a, &br, &dist);

        const npostfix: u5 = @intCast(br.readBits(2));
        const ndirect: u32 = br.readBits(4) << npostfix;

        // Literal context modes, one per literal block type.
        const context_modes = try a.alloc(u8, lit.num_types);
        for (context_modes) |*m| m.* = @intCast(br.readBits(2));

        const lit_cm = try decodeContextMap(a, &br, lit.num_types << literal_context_bits);
        const dist_cm = try decodeContextMap(a, &br, dist.num_types << distance_context_bits);

        const lit_group = try readHGroup(a, &br, lit_cm.num_htrees, 256);
        const cmd_group = try readHGroup(a, &br, cmd.num_types, 704);
        const dist_alphabet = num_dist_short + ndirect + (@as(usize, 24) << (npostfix + 1));
        const dist_group = try readHGroup(a, &br, dist_cm.num_htrees, dist_alphabet);

        // Current literal context lookup + htree slice.
        var ctx_mode_off: usize = @as(usize, context_modes[lit.rb1]) * 512;
        var lit_cm_slice: usize = lit.rb1 << literal_context_bits;
        var dist_cm_slice: usize = dist.rb1 << distance_context_bits;

        var remaining: i64 = @intCast(mlen);
        // ---- command loop ----
        while (remaining > 0) {
            if (cmd.length == 0) {
                cmd.switchBlock(&br);
            }
            cmd.length -= 1;

            // Read the insert-and-copy command.
            const cmd_code = cmd_group.trees[cmd.rb1].decode(&br);
            const cell_idx = cmd_code >> 6;
            const cell_pos: u32 = cell_pos_lut[cell_idx];
            const insert_code = (cell_pos & 0x18) + ((cmd_code >> 3) & 7);
            const copy_code = ((cell_pos << 3) & 0x18) + (cmd_code & 7);
            const insert_len = insert_base[insert_code] + br.readBits(insert_extra[insert_code]);
            var copy_len = copy_base[copy_code] + br.readBits(copy_extra[copy_code]);
            // Distance context is keyed on the copy length (2→0, 3→1, 4→2, >4→3).
            const dist_context: u32 = if (copy_len > 4) 3 else copy_len - 2;
            const cmd_implicit = cell_idx < 2;
            var dist_htree = dist_cm.map[dist_cm_slice + dist_context];

            // Insert literals.
            var n = insert_len;
            remaining -= @intCast(n);
            while (n > 0) : (n -= 1) {
                if (lit.length == 0) {
                    lit.switchBlock(&br);
                    ctx_mode_off = @as(usize, context_modes[lit.rb1]) * 512;
                    lit_cm_slice = lit.rb1 << literal_context_bits;
                }
                const p1: usize = if (pos >= 1) out[pos - 1] else 0;
                const p2: usize = if (pos >= 2) out[pos - 2] else 0;
                const context = ctx_lut[ctx_mode_off + p1] | ctx_lut[ctx_mode_off + 256 + p2];
                const htree = lit_cm.map[lit_cm_slice + context];
                out[pos] = @intCast(lit_group.trees[htree].decode(&br));
                pos += 1;
                lit.length -= 1;
            }
            if (remaining <= 0) break;

            // Resolve the distance. `roll` is the ring-buffer roll
            // compensation that the dictionary path must re-apply.
            var distance: usize = undefined;
            var roll: u32 = 0;
            if (cmd_implicit) {
                // Reuse the last distance; roll the ring index back by one.
                roll = 1;
                dist_rb_idx -%= 1;
                distance = dist_rb[dist_rb_idx & 3];
            } else {
                if (dist.length == 0) {
                    dist.switchBlock(&br);
                    dist_cm_slice = dist.rb1 << distance_context_bits;
                    dist_htree = dist_cm.map[dist_cm_slice + dist_context];
                }
                dist.length -= 1;
                const r = readDistance(&br, dist_group.trees[dist_htree], npostfix, ndirect, &dist_rb, &dist_rb_idx);
                distance = r.distance;
                roll = r.roll;
            }

            const max_distance = @min(pos, max_backward);
            if (distance > max_distance) {
                // Static-dictionary reference.
                const len: usize = copy_len;
                if (len < dict_min_len or len > dict_max_len) return Error.BadStream;
                const shift: u5 = @intCast(dict_size_bits[len]);
                const address = distance - max_distance - 1;
                const word_idx = address & ((@as(usize, 1) << shift) - 1);
                const transform_idx = address >> shift;
                dist_rb_idx +%= roll; // compensate the ring-buffer roll
                if (transform_idx >= num_transforms) return Error.BadStream;
                const word_off = dict_offsets[len] + word_idx * len;
                const written = transformWord(out[pos..], dict_data[word_off .. word_off + len], @intCast(transform_idx));
                pos += written;
                remaining -= @intCast(written);
            } else {
                // LZ77 back-reference into the output.
                if (distance > pos) return Error.BadStream;
                const src = pos - distance;
                var k: usize = 0;
                while (k < copy_len) : (k += 1) out[pos + k] = out[src + k];
                dist_rb[dist_rb_idx & 3] = @intCast(distance);
                dist_rb_idx +%= 1;
                pos += copy_len;
                remaining -= @intCast(copy_len);
            }
            copy_len = 0;
        }

        if (is_last) break;
    }
    if (pos != out.len) return Error.BadStream;
}

fn readBlockCategory(a: std.mem.Allocator, br: *BitReader, bs: *BlockState) Error!void {
    bs.num_types = try decodeVarLenUint8(br) + 1;
    if (bs.num_types >= 2) {
        bs.type_tree = try readHuffmanCode(a, br, bs.num_types + 2);
        bs.len_tree = try readHuffmanCode(a, br, 26);
        bs.length = readBlockLength(&bs.len_tree, br);
    }
}

fn readWindowBits(br: *BitReader) u32 {
    if (br.readBit() == 0) return 16;
    const n = br.readBits(3);
    if (n != 0) return 17 + n;
    const m = br.readBits(3);
    if (m != 0) return 8 + m;
    return 17;
}

/// Decode a distance code into an absolute distance, updating the ring
/// buffer exactly as the reference does. `roll` is the amount by which the
/// caller's dictionary path must re-advance the ring index.
fn readDistance(br: *BitReader, tree: Huff, npostfix: u5, ndirect: u32, rb: *[4]u32, rb_idx: *u32) struct { distance: usize, roll: u32 } {
    const code = tree.decode(br);
    if (code < 16) {
        // Short code referencing the distance ring buffer.
        const dc: i32 = code;
        const offset = dc - 3;
        var distance: i64 = undefined;
        var roll: u32 = 0;
        if (dc <= 3) {
            roll = @as(u32, 1) >> @intCast(@as(u32, @intCast(dc)));
            distance = rb[(rb_idx.* -% @as(u32, @bitCast(offset))) & 3];
            rb_idx.* -%= roll;
        } else {
            var index_delta: i32 = 3;
            var base = dc - 10;
            if (dc < 10) {
                base = dc - 4;
            } else {
                index_delta = 2;
            }
            const delta: i64 = @as(i64, (@as(i32, 0x605142) >> @intCast(4 * base)) & 0xf) - 3;
            distance = @as(i64, rb[(rb_idx.* +% @as(u32, @bitCast(index_delta))) & 3]) + delta;
            if (distance <= 0) distance = 0x7FFFFFFF;
        }
        return .{ .distance = @intCast(distance), .roll = roll };
    }
    if (code < 16 + ndirect) {
        return .{ .distance = code - 16 + 1, .roll = 0 };
    }
    const xcode: u32 = code - ndirect - 16;
    const ndistbits: u5 = @intCast(1 + (xcode >> (npostfix + 1)));
    const extra = br.readBits(ndistbits);
    const half = (xcode >> npostfix) & 1;
    const postfix = xcode & ((@as(u32, 1) << npostfix) - 1);
    const offset = ((@as(usize, 2) + half) << ndistbits) - 4;
    return .{ .distance = ((offset + extra) << npostfix) + postfix + ndirect + 1, .roll = 0 };
}

// ------------------------------------------------------ word transforms

/// Apply transform `idx` to a dictionary `word`, writing to `dst`; returns
/// the number of bytes written. Mirrors BrotliTransformDictionaryWord.
fn transformWord(dst: []u8, word: []const u8, idx: usize) usize {
    const prefix_id = transforms_data[idx * 3 + 0];
    const ttype = transforms_data[idx * 3 + 1];
    const suffix_id = transforms_data[idx * 3 + 2];
    var out_i: usize = 0;

    // Prefix.
    {
        const off = ps_map[prefix_id];
        const plen = prefix_suffix[off];
        for (0..plen) |k| {
            dst[out_i] = prefix_suffix[off + 1 + k];
            out_i += 1;
        }
    }

    // Word body with omit-first/last applied.
    var w = word;
    var len: usize = word.len;
    if (ttype <= T_OMIT_LAST_9) {
        len -= ttype; // identity (0) or omit-last-N
    } else if (ttype >= T_OMIT_FIRST_1 and ttype <= T_OMIT_FIRST_9) {
        const skip = ttype - (T_OMIT_FIRST_1 - 1);
        if (skip <= len) {
            w = w[skip..];
            len -= skip;
        } else {
            len = 0;
        }
    }
    const body_start = out_i;
    for (0..len) |k| {
        dst[out_i] = w[k];
        out_i += 1;
    }
    if (ttype == T_UPPERCASE_FIRST) {
        _ = toUpperCase(dst[body_start..out_i]);
    } else if (ttype == T_UPPERCASE_ALL) {
        var p: usize = body_start;
        while (p < out_i) p += toUpperCase(dst[p..out_i]);
    }

    // Suffix.
    {
        const off = ps_map[suffix_id];
        const slen = prefix_suffix[off];
        for (0..slen) |k| {
            dst[out_i] = prefix_suffix[off + 1 + k];
            out_i += 1;
        }
    }
    return out_i;
}

/// Uppercase the first UTF-8 code point in `p`; returns its byte length.
fn toUpperCase(p: []u8) usize {
    if (p.len == 0) return 1;
    if (p[0] < 0xC0) {
        if (p[0] >= 'a' and p[0] <= 'z') p[0] ^= 32;
        return 1;
    }
    if (p[0] < 0xE0) {
        if (p.len >= 2) p[1] ^= 32;
        return 2;
    }
    if (p.len >= 3) p[2] ^= 5;
    return 3;
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "brotli decodes a raw stream (text with dictionary refs)" {
    // `brotli -c` of "the time to work is now, the time is now.\n" — exercises
    // literals, copies, and a static-dictionary word. Generated with brotli 1.2.0.
    const comp = @embedFile("brotli/testvec1.br");
    const expect = "the time to work is now, the time is now.\n";
    var buf: [64]u8 = undefined;
    try decode(testing.allocator, comp, buf[0..expect.len]);
    try testing.expectEqualStrings(expect, buf[0..expect.len]);
}

test "brotli decodes a copy-heavy stream" {
    // "ab" repeated 80× — a short literal run then long back-reference copies.
    const comp = @embedFile("brotli/testvec2.br");
    var buf: [160]u8 = undefined;
    try decode(testing.allocator, comp, &buf);
    for (0..160) |i| try testing.expectEqual(@as(u8, if (i % 2 == 0) 'a' else 'b'), buf[i]);
}

test "brotli decodes an incompressible stream" {
    // Bytes 0..199 — no matches, so it stresses the literal/store path.
    const comp = @embedFile("brotli/testvec3.br");
    var buf: [200]u8 = undefined;
    try decode(testing.allocator, comp, &buf);
    for (0..200) |i| try testing.expectEqual(@as(u8, @intCast(i)), buf[i]);
}
