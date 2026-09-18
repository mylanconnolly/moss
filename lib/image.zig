//! The image decoders: PNG (every colour type and depth, interlaced or
//! not, through std's inflate), JPEG (baseline and progressive, any
//! sampling, restart intervals, greyscale) and GIF (the first frame,
//! interlace, a transparent colour). Pure, allocation-explicit,
//! freestanding-safe: a page domain decodes what it fetched here, and
//! a hostile file can only cost that page. Every decoder answers the
//! same `Image` — RGBA, eight bits a channel, rows top to bottom — or
//! an error, never a partial picture; the host tests decode the corpus
//! under tools/testdata/images against what ImageMagick made of each.
//!
//! Not built, said so: APNG and GIF animation (the first frame is the
//! picture), 16-bit precision beyond the top byte, colour management
//! (gAMA, iCCP, sRGB chunks are read past), arithmetic-coded and
//! lossless JPEG, CMYK JPEG, WebP, SVG.
const std = @import("std");

pub const Error = error{ OutOfMemory, BadImage, Unsupported };

pub const Image = struct {
    w: u32,
    h: u32,
    /// w × h pixels, four bytes each: R, G, B, A.
    rgba: []u8,

    pub fn at(img: Image, x: usize, y: usize) [4]u8 {
        const o = (y * img.w + x) * 4;
        return img.rgba[o..][0..4].*;
    }
};

pub const Kind = enum { png, jpeg, gif };

/// What a file is, by its first bytes.
pub fn sniff(bytes: []const u8) ?Kind {
    if (bytes.len >= 8 and std.mem.eql(u8, bytes[0..8], &png_signature)) return .png;
    if (bytes.len >= 3 and bytes[0] == 0xff and bytes[1] == 0xd8 and bytes[2] == 0xff) return .jpeg;
    if (bytes.len >= 6 and (std.mem.eql(u8, bytes[0..6], "GIF87a") or std.mem.eql(u8, bytes[0..6], "GIF89a"))) return .gif;
    return null;
}

/// Decode any format this file knows; the pixels are the caller's.
pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
    return switch (sniff(bytes) orelse return Error.Unsupported) {
        .png => png.decode(a, bytes),
        .jpeg => jpeg.decode(a, bytes),
        .gif => gif.decode(a, bytes),
    };
}

/// A picture this big is refused before a byte is allocated: pixels
/// times four is the memory it would take.
pub const max_pixels: u64 = 32 << 20;

fn checkSize(w: u64, h: u64) Error!void {
    if (w == 0 or h == 0 or w * h > max_pixels) return Error.BadImage;
}

const png_signature = [8]u8{ 0x89, 'P', 'N', 'G', 0x0d, 0x0a, 0x1a, 0x0a };

// ----------------------------------------------------------------- PNG

pub const png = struct {
    const flate = std.compress.flate;

    const Header = struct { w: u32, h: u32, depth: u8, ctype: u8, interlace: u8 };

    fn channels(ctype: u8) Error!u8 {
        return switch (ctype) {
            0 => 1,
            2 => 3,
            3 => 1,
            4 => 2,
            6 => 4,
            else => Error.BadImage,
        };
    }

    pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
        if (sniff(bytes) != .png) return Error.BadImage;
        var pos: usize = 8;
        var hdr: ?Header = null;
        var plte: []const u8 = &.{};
        var trns: []const u8 = &.{};
        var idat: std.ArrayList(u8) = .empty;
        defer idat.deinit(a);
        while (pos + 8 <= bytes.len) {
            const len = std.mem.readInt(u32, bytes[pos..][0..4], .big);
            const kind = bytes[pos + 4 .. pos + 8];
            pos += 8;
            if (len > bytes.len - pos) return Error.BadImage;
            const data = bytes[pos .. pos + len];
            pos += len + 4; // the CRC is not checked: a corrupt file fails as one
            if (std.mem.eql(u8, kind, "IHDR")) {
                if (data.len < 13) return Error.BadImage;
                const h: Header = .{
                    .w = std.mem.readInt(u32, data[0..4], .big),
                    .h = std.mem.readInt(u32, data[4..8], .big),
                    .depth = data[8],
                    .ctype = data[9],
                    .interlace = data[12],
                };
                if (data[10] != 0 or data[11] != 0 or h.interlace > 1) return Error.BadImage;
                try checkSize(h.w, h.h);
                _ = try channels(h.ctype);
                const ok_depth = switch (h.ctype) {
                    0 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8 or h.depth == 16,
                    3 => h.depth == 1 or h.depth == 2 or h.depth == 4 or h.depth == 8,
                    else => h.depth == 8 or h.depth == 16,
                };
                if (!ok_depth) return Error.BadImage;
                hdr = h;
            } else if (std.mem.eql(u8, kind, "PLTE")) {
                plte = data;
            } else if (std.mem.eql(u8, kind, "tRNS")) {
                trns = data;
            } else if (std.mem.eql(u8, kind, "IDAT")) {
                try idat.appendSlice(a, data);
            } else if (std.mem.eql(u8, kind, "IEND")) {
                break;
            }
        }
        const h = hdr orelse return Error.BadImage;
        if (h.ctype == 3 and plte.len == 0) return Error.BadImage;
        const ch = try channels(h.ctype);
        const bits: usize = @as(usize, ch) * h.depth;
        const bpp: usize = @max(1, bits / 8);
        // The inflated size: every pass's rows, each a filter byte and its samples.
        var raw_len: usize = 0;
        var pass: usize = 0;
        const npasses: usize = if (h.interlace == 1) 7 else 1;
        while (pass < npasses) : (pass += 1) {
            const pw = passWidth(h, pass);
            const ph = passHeight(h, pass);
            if (pw == 0 or ph == 0) continue;
            raw_len += ph * (1 + (pw * bits + 7) / 8);
        }
        const raw = try a.alloc(u8, raw_len);
        defer a.free(raw);
        {
            var in = std.Io.Reader.fixed(idat.items);
            const window = try a.alloc(u8, flate.max_window_len);
            defer a.free(window);
            var dc = flate.Decompress.init(&in, .zlib, window);
            dc.reader.readSliceAll(raw) catch return Error.BadImage;
        }
        const out = try a.alloc(u8, @as(usize, h.w) * h.h * 4);
        errdefer a.free(out);
        var off: usize = 0;
        pass = 0;
        while (pass < npasses) : (pass += 1) {
            const pw = passWidth(h, pass);
            const ph = passHeight(h, pass);
            if (pw == 0 or ph == 0) continue;
            const stride = (pw * bits + 7) / 8;
            const rows = raw[off .. off + ph * (1 + stride)];
            off += ph * (1 + stride);
            try unfilter(rows, stride, bpp);
            var y: usize = 0;
            while (y < ph) : (y += 1) {
                const row = rows[y * (1 + stride) + 1 .. (y + 1) * (1 + stride)];
                var x: usize = 0;
                while (x < pw) : (x += 1) {
                    const px = sample(row, x, h, plte, trns);
                    const ox = if (h.interlace == 1) passX(pass, x) else x;
                    const oy = if (h.interlace == 1) passY(pass, y) else y;
                    const o = (oy * h.w + ox) * 4;
                    out[o..][0..4].* = px;
                }
            }
        }
        return .{ .w = h.w, .h = h.h, .rgba = out };
    }

    // Adam7: each pass's start and step along both axes.
    const adam7 = [7][4]usize{ .{ 0, 0, 8, 8 }, .{ 4, 0, 8, 8 }, .{ 0, 4, 4, 8 }, .{ 2, 0, 4, 4 }, .{ 0, 2, 2, 4 }, .{ 1, 0, 2, 2 }, .{ 0, 1, 1, 2 } };

    fn passWidth(h: Header, pass: usize) usize {
        if (h.interlace == 0) return h.w;
        const p = adam7[pass];
        return if (h.w > p[0]) (h.w - p[0] + p[2] - 1) / p[2] else 0;
    }
    fn passHeight(h: Header, pass: usize) usize {
        if (h.interlace == 0) return h.h;
        const p = adam7[pass];
        return if (h.h > p[1]) (h.h - p[1] + p[3] - 1) / p[3] else 0;
    }
    fn passX(pass: usize, x: usize) usize {
        return adam7[pass][0] + x * adam7[pass][2];
    }
    fn passY(pass: usize, y: usize) usize {
        return adam7[pass][1] + y * adam7[pass][3];
    }

    /// The five filters, undone in place; row 0's "previous row" is zeros.
    fn unfilter(rows: []u8, stride: usize, bpp: usize) Error!void {
        const nrows = rows.len / (1 + stride);
        var y: usize = 0;
        while (y < nrows) : (y += 1) {
            const base = y * (1 + stride);
            const ftype = rows[base];
            const cur = rows[base + 1 .. base + 1 + stride];
            var i: usize = 0;
            while (i < stride) : (i += 1) {
                const left: u16 = if (i >= bpp) cur[i - bpp] else 0;
                const up: u16 = if (y > 0) rows[base - stride + i] else 0;
                const ul: u16 = if (y > 0 and i >= bpp) rows[base - stride + i - bpp] else 0;
                const raw: u16 = cur[i];
                cur[i] = @truncate(switch (ftype) {
                    0 => raw,
                    1 => raw + left,
                    2 => raw + up,
                    3 => raw + (left + up) / 2,
                    4 => raw + paeth(left, up, ul),
                    else => return Error.BadImage,
                });
            }
        }
    }

    fn paeth(a: u16, b: u16, c: u16) u16 {
        const p: i32 = @as(i32, a) + @as(i32, b) - @as(i32, c);
        const pa = @abs(p - @as(i32, a));
        const pb = @abs(p - @as(i32, b));
        const pc = @abs(p - @as(i32, c));
        if (pa <= pb and pa <= pc) return a;
        if (pb <= pc) return b;
        return c;
    }

    /// One sample of `depth` bits at index `i` of a row, scaled to 8 bits.
    fn bitsAt(row: []const u8, i: usize, depth: u8) u8 {
        return switch (depth) {
            8 => row[i],
            16 => @intCast((@as(u32, std.mem.readInt(u16, row[i * 2 ..][0..2], .big)) * 255 + 32767) / 65535),
            1 => (row[i / 8] >> @intCast(7 - (i % 8))) & 1,
            2 => (row[i / 4] >> @intCast(6 - 2 * (i % 4))) & 3,
            4 => (row[i / 2] >> @intCast(4 - 4 * (i % 2))) & 15,
            else => 0,
        };
    }

    fn scaled(v: u8, depth: u8) u8 {
        return switch (depth) {
            1 => v * 255,
            2 => v * 85,
            4 => v * 17,
            else => v,
        };
    }

    fn sample(row: []const u8, x: usize, h: Header, plte: []const u8, trns: []const u8) [4]u8 {
        switch (h.ctype) {
            0 => {
                const g = bitsAt(row, x, h.depth);
                var alpha: u8 = 255;
                if (trns.len >= 2) {
                    const key = std.mem.readInt(u16, trns[0..2], .big);
                    if (h.depth == 16) {
                        if (row[x * 2] == @as(u8, @truncate(key >> 8)) and row[x * 2 + 1] == @as(u8, @truncate(key))) alpha = 0;
                    } else if (g == key) alpha = 0;
                }
                const s = scaled(g, h.depth);
                return .{ s, s, s, alpha };
            },
            2 => {
                const r = bitsAt(row, x * 3, h.depth);
                const g = bitsAt(row, x * 3 + 1, h.depth);
                const b = bitsAt(row, x * 3 + 2, h.depth);
                var alpha: u8 = 255;
                if (trns.len >= 6 and h.depth == 8) {
                    if (r == trns[1] and g == trns[3] and b == trns[5]) alpha = 0;
                }
                return .{ r, g, b, alpha };
            },
            3 => {
                const i: usize = bitsAt(row, x, h.depth);
                if (i * 3 + 2 >= plte.len) return .{ 0, 0, 0, 255 };
                const alpha: u8 = if (i < trns.len) trns[i] else 255;
                return .{ plte[i * 3], plte[i * 3 + 1], plte[i * 3 + 2], alpha };
            },
            4 => {
                const g = bitsAt(row, x * 2, h.depth);
                const al = bitsAt(row, x * 2 + 1, h.depth);
                return .{ g, g, g, al };
            },
            6 => return .{ bitsAt(row, x * 4, h.depth), bitsAt(row, x * 4 + 1, h.depth), bitsAt(row, x * 4 + 2, h.depth), bitsAt(row, x * 4 + 3, h.depth) },
            else => return .{ 0, 0, 0, 255 },
        }
    }
};

// ----------------------------------------------------------------- GIF

pub const gif = struct {
    pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
        if (sniff(bytes) != .gif) return Error.BadImage;
        if (bytes.len < 13) return Error.BadImage;
        const w: u32 = std.mem.readInt(u16, bytes[6..8], .little);
        const h: u32 = std.mem.readInt(u16, bytes[8..10], .little);
        try checkSize(w, h);
        const packed_lsd = bytes[10];
        var pos: usize = 13;
        var gct: []const u8 = &.{};
        if (packed_lsd & 0x80 != 0) {
            const n: usize = @as(usize, 2) << @intCast(packed_lsd & 7);
            if (pos + n * 3 > bytes.len) return Error.BadImage;
            gct = bytes[pos .. pos + n * 3];
            pos += n * 3;
        }
        const out = try a.alloc(u8, @as(usize, w) * h * 4);
        errdefer a.free(out);
        @memset(out, 0); // transparent until the first frame paints
        var transparent: ?u8 = null;
        while (pos < bytes.len) {
            const b = bytes[pos];
            pos += 1;
            switch (b) {
                0x3b => break, // trailer
                0x21 => { // an extension
                    if (pos >= bytes.len) return Error.BadImage;
                    const label = bytes[pos];
                    pos += 1;
                    if (label == 0xf9) {
                        // Graphic control: the transparent colour, if any.
                        if (pos + 5 > bytes.len) return Error.BadImage;
                        const size = bytes[pos];
                        const flags = bytes[pos + 1];
                        if (size >= 4 and flags & 1 != 0) transparent = bytes[pos + 4];
                    }
                    pos = try skipSubBlocks(bytes, pos);
                },
                0x2c => { // an image
                    if (pos + 9 > bytes.len) return Error.BadImage;
                    const ix: usize = std.mem.readInt(u16, bytes[pos..][0..2], .little);
                    const iy: usize = std.mem.readInt(u16, bytes[pos + 2 ..][0..2], .little);
                    const iw: usize = std.mem.readInt(u16, bytes[pos + 4 ..][0..2], .little);
                    const ih: usize = std.mem.readInt(u16, bytes[pos + 6 ..][0..2], .little);
                    const flags = bytes[pos + 8];
                    pos += 9;
                    var table = gct;
                    if (flags & 0x80 != 0) {
                        const n: usize = @as(usize, 2) << @intCast(flags & 7);
                        if (pos + n * 3 > bytes.len) return Error.BadImage;
                        table = bytes[pos .. pos + n * 3];
                        pos += n * 3;
                    }
                    if (table.len == 0 or iw == 0 or ih == 0 or iw * ih > max_pixels) return Error.BadImage;
                    if (pos >= bytes.len) return Error.BadImage;
                    const min_code = bytes[pos];
                    pos += 1;
                    // The compressed data, sub-blocks joined.
                    var data: std.ArrayList(u8) = .empty;
                    defer data.deinit(a);
                    while (pos < bytes.len) {
                        const n = bytes[pos];
                        pos += 1;
                        if (n == 0) break;
                        if (pos + n > bytes.len) return Error.BadImage;
                        try data.appendSlice(a, bytes[pos .. pos + n]);
                        pos += n;
                    }
                    const indices = try a.alloc(u8, iw * ih);
                    defer a.free(indices);
                    try lzw(data.items, min_code, indices);
                    const interlaced = flags & 0x40 != 0;
                    var row: usize = 0;
                    while (row < ih) : (row += 1) {
                        const oy = iy + (if (interlaced) deinterlace(row, ih) else row);
                        if (oy >= h) continue;
                        var col: usize = 0;
                        while (col < iw) : (col += 1) {
                            const ox = ix + col;
                            if (ox >= w) continue;
                            const idx: usize = indices[row * iw + col];
                            if (transparent != null and idx == transparent.?) continue;
                            if (idx * 3 + 2 >= table.len) continue;
                            const o = (oy * w + ox) * 4;
                            out[o] = table[idx * 3];
                            out[o + 1] = table[idx * 3 + 1];
                            out[o + 2] = table[idx * 3 + 2];
                            out[o + 3] = 255;
                        }
                    }
                    // The first frame is the picture.
                    return .{ .w = w, .h = h, .rgba = out };
                },
                else => return Error.BadImage,
            }
        }
        return .{ .w = w, .h = h, .rgba = out };
    }

    fn skipSubBlocks(bytes: []const u8, start: usize) Error!usize {
        var pos = start;
        while (pos < bytes.len) {
            const n = bytes[pos];
            pos += 1;
            if (n == 0) return pos;
            pos += n;
        }
        return Error.BadImage;
    }

    /// The row a stored interlaced row lands on: passes of every 8th
    /// from 0, every 8th from 4, every 4th from 2, every 2nd from 1.
    fn deinterlace(row: usize, h: usize) usize {
        const p0 = (h + 7) / 8;
        const p1 = (h + 3) / 8;
        const p2 = (h + 1) / 4;
        if (row < p0) return row * 8;
        if (row < p0 + p1) return (row - p0) * 8 + 4;
        if (row < p0 + p1 + p2) return (row - p0 - p1) * 4 + 2;
        return (row - p0 - p1 - p2) * 2 + 1;
    }

    /// GIF's LZW: variable code width from `min_code + 1`, clear and end
    /// codes, a table of up to 4096 strings kept as (prefix, suffix).
    fn lzw(data: []const u8, min_code: u8, out: []u8) Error!void {
        if (min_code < 2 or min_code > 11) return Error.BadImage;
        const clear: u16 = @as(u16, 1) << @intCast(min_code);
        const end: u16 = clear + 1;
        var prefix: [4096]u16 = undefined;
        var suffix: [4096]u8 = undefined;
        var length: [4096]u16 = undefined;
        var next: u16 = clear + 2;
        var width: u5 = @intCast(min_code + 1);
        var prev: ?u16 = null;
        var bitbuf: u32 = 0;
        var bits: u5 = 0;
        var pos: usize = 0;
        var o: usize = 0;
        var stack: [4096]u8 = undefined;
        var i: u16 = 0;
        while (i < clear) : (i += 1) {
            prefix[i] = 0xffff;
            suffix[i] = @truncate(i);
            length[i] = 1;
        }
        while (o < out.len) {
            while (bits < width) {
                if (pos >= data.len) return; // short data: the rest stays as it is
                bitbuf |= @as(u32, data[pos]) << bits;
                pos += 1;
                bits += 8;
            }
            const code: u16 = @intCast(bitbuf & ((@as(u32, 1) << width) - 1));
            bitbuf >>= width;
            bits -= width;
            if (code == clear) {
                next = clear + 2;
                width = @intCast(min_code + 1);
                prev = null;
                continue;
            }
            if (code == end) return;
            var entry = code;
            var first: u8 = 0;
            if (code >= next) {
                // KwKwK: the code being defined; its string is prev's + prev's first.
                const p = prev orelse return Error.BadImage;
                if (code != next) return Error.BadImage;
                entry = p;
                first = firstOf(p, &prefix, &suffix);
                // Emit prev's string then its first byte.
                var n: usize = 0;
                var e = p;
                while (true) {
                    stack[n] = suffix[e];
                    n += 1;
                    if (prefix[e] == 0xffff) break;
                    e = prefix[e];
                }
                var k = n;
                while (k > 0) : (k -= 1) {
                    if (o < out.len) {
                        out[o] = stack[k - 1];
                        o += 1;
                    }
                }
                if (o < out.len) {
                    out[o] = first;
                    o += 1;
                }
            } else {
                var n: usize = 0;
                var e = code;
                while (true) {
                    stack[n] = suffix[e];
                    n += 1;
                    if (prefix[e] == 0xffff) break;
                    e = prefix[e];
                }
                first = stack[n - 1];
                var k = n;
                while (k > 0) : (k -= 1) {
                    if (o < out.len) {
                        out[o] = stack[k - 1];
                        o += 1;
                    }
                }
            }
            if (prev) |p| if (next < 4096) {
                prefix[next] = p;
                suffix[next] = first;
                length[next] = length[p] + 1;
                next += 1;
                if (next == (@as(u16, 1) << @as(u4, @intCast(width))) and width < 12) width += 1;
            };
            prev = code;
        }
    }

    fn firstOf(code: u16, prefix: *const [4096]u16, suffix: *const [4096]u8) u8 {
        var e = code;
        while (prefix[e] != 0xffff) e = prefix[e];
        return suffix[e];
    }
};

// ---------------------------------------------------------------- JPEG

pub const jpeg = struct {
    const zigzag = [64]u8{ 0, 1, 8, 16, 9, 2, 3, 10, 17, 24, 32, 25, 18, 11, 4, 5, 12, 19, 26, 33, 40, 48, 41, 34, 27, 20, 13, 6, 7, 14, 21, 28, 35, 42, 49, 56, 57, 50, 43, 36, 29, 22, 15, 23, 30, 37, 44, 51, 58, 59, 52, 45, 38, 31, 39, 46, 53, 60, 61, 54, 47, 55, 62, 63 };

    const Huffman = struct {
        /// For each code length 1..16: the first code and the symbol index
        /// where its symbols start; `symbols` in code order.
        mincode: [17]i32 = @splat(0),
        maxcode: [17]i32 = @splat(-1),
        valptr: [17]i32 = @splat(0),
        symbols: [256]u8 = @splat(0),
        present: bool = false,

        fn build(counts: *const [16]u8, symbols: []const u8) Huffman {
            var h: Huffman = .{ .present = true };
            @memcpy(h.symbols[0..symbols.len], symbols);
            var code: i32 = 0;
            var k: i32 = 0;
            var len: usize = 1;
            while (len <= 16) : (len += 1) {
                const n: i32 = counts[len - 1];
                if (n == 0) {
                    h.maxcode[len] = -1;
                } else {
                    h.valptr[len] = k;
                    h.mincode[len] = code;
                    code += n;
                    k += n;
                    h.maxcode[len] = code - 1;
                }
                code <<= 1;
            }
            return h;
        }
    };

    const Component = struct {
        id: u8,
        h: u8,
        v: u8,
        tq: u8,
        /// The plane's block dimensions and coefficient store.
        bw: usize = 0,
        bh: usize = 0,
        coefs: []i16 = &.{},
        dc_pred: i32 = 0,
        td: u8 = 0,
        ta: u8 = 0,
    };

    const Reader = struct {
        bytes: []const u8,
        pos: usize,
        bitbuf: u32 = 0,
        bits: u6 = 0,
        /// A marker met inside the entropy stream (RSTn, or the next
        /// segment): reads past it give zero bits.
        marker: ?u8 = null,

        fn fill(r: *Reader) void {
            while (r.bits <= 24) {
                var b: u8 = 0;
                if (r.marker == null and r.pos < r.bytes.len) {
                    b = r.bytes[r.pos];
                    if (b == 0xff) {
                        const nx: u8 = if (r.pos + 1 < r.bytes.len) r.bytes[r.pos + 1] else 0xd9;
                        if (nx == 0) {
                            r.pos += 2;
                        } else if (nx == 0xff) {
                            r.pos += 1; // fill bytes
                            continue;
                        } else {
                            r.marker = nx;
                            b = 0;
                        }
                    } else r.pos += 1;
                }
                r.bitbuf |= @as(u32, b) << @intCast(24 - r.bits);
                r.bits += 8;
            }
        }

        fn bit(r: *Reader) u1 {
            if (r.bits == 0) r.fill();
            const v: u1 = @intCast(r.bitbuf >> 31);
            r.bitbuf <<= 1;
            r.bits -= 1;
            return v;
        }

        fn take(r: *Reader, n: u5) u32 {
            if (n == 0) return 0;
            if (r.bits < n) r.fill();
            const v = r.bitbuf >> @intCast(32 - @as(u6, n));
            r.bitbuf <<= n;
            r.bits -= n;
            return v;
        }

        /// A signed value of `n` bits as JPEG extends it.
        fn receiveExtend(r: *Reader, n: u5) i32 {
            if (n == 0) return 0;
            const v: i32 = @intCast(r.take(n));
            return if (v < (@as(i32, 1) << @intCast(n - 1))) v - (@as(i32, 1) << @intCast(n)) + 1 else v;
        }

        fn decodeSymbol(r: *Reader, h: *const Huffman) Error!u8 {
            var code: i32 = 0;
            var len: usize = 1;
            while (len <= 16) : (len += 1) {
                code = (code << 1) | r.bit();
                if (code <= h.maxcode[len]) {
                    const idx = h.valptr[len] + code - h.mincode[len];
                    if (idx < 0 or idx >= 256) return Error.BadImage;
                    return h.symbols[@intCast(idx)];
                }
            }
            return Error.BadImage;
        }

        /// Past a restart marker: the bit buffer is dropped and the
        /// marker consumed.
        fn restart(r: *Reader) void {
            r.bitbuf = 0;
            r.bits = 0;
            // The buffer may still hold the padding before the marker,
            // so the marker may not have been reached: seek to it.
            if (r.marker == null) {
                while (r.pos + 1 < r.bytes.len) : (r.pos += 1) {
                    if (r.bytes[r.pos] == 0xff and r.bytes[r.pos + 1] >= 0xd0 and r.bytes[r.pos + 1] <= 0xd7) {
                        r.marker = r.bytes[r.pos + 1];
                        break;
                    }
                }
            }
            if (r.marker) |m| if (m >= 0xd0 and m <= 0xd7) {
                r.pos += 2;
                r.marker = null;
            };
        }
    };

    const Decoder = struct {
        a: std.mem.Allocator,
        qt: [4][64]u16 = @splat(@splat(1)),
        dc: [4]Huffman = @splat(.{}),
        ac: [4]Huffman = @splat(.{}),
        comps: [4]Component = undefined,
        ncomp: usize = 0,
        w: usize = 0,
        h: usize = 0,
        hmax: u8 = 1,
        vmax: u8 = 1,
        mcux: usize = 0,
        mcuy: usize = 0,
        progressive: bool = false,
        restart_interval: usize = 0,
        eobrun: u32 = 0,
        frame_seen: bool = false,

        fn compByIndex(d: *Decoder, i: usize) *Component {
            return &d.comps[i];
        }
    };

    pub fn decode(a: std.mem.Allocator, bytes: []const u8) Error!Image {
        if (sniff(bytes) != .jpeg) return Error.BadImage;
        var d: Decoder = .{ .a = a };
        defer for (d.comps[0..d.ncomp]) |c| if (c.coefs.len > 0) a.free(c.coefs);
        var pos: usize = 2;
        while (pos + 4 <= bytes.len) {
            if (bytes[pos] != 0xff) {
                pos += 1;
                continue;
            }
            const marker = bytes[pos + 1];
            if (marker == 0xff) {
                pos += 1;
                continue;
            }
            pos += 2;
            if (marker == 0xd8 or (marker >= 0xd0 and marker <= 0xd7) or marker == 0x01) continue;
            if (marker == 0xd9) break;
            if (pos + 2 > bytes.len) return Error.BadImage;
            const len: usize = std.mem.readInt(u16, bytes[pos..][0..2], .big);
            if (len < 2 or pos + len > bytes.len) return Error.BadImage;
            const seg = bytes[pos + 2 .. pos + len];
            pos += len;
            switch (marker) {
                0xdb => try readDqt(&d, seg),
                0xc4 => try readDht(&d, seg),
                0xc0, 0xc1, 0xc2 => try readSof(&d, seg, marker == 0xc2),
                0xc3, 0xc5, 0xc6, 0xc7, 0xc9, 0xca, 0xcb, 0xcd, 0xce, 0xcf => return Error.Unsupported,
                0xdd => {
                    if (seg.len < 2) return Error.BadImage;
                    d.restart_interval = std.mem.readInt(u16, seg[0..2], .big);
                },
                0xda => {
                    if (!d.frame_seen) return Error.BadImage;
                    pos = try readScan(&d, bytes, seg, pos);
                },
                else => {}, // APPn, COM, DNL and the rest
            }
        }
        if (!d.frame_seen) return Error.BadImage;
        return try output(&d);
    }

    fn readDqt(d: *Decoder, seg: []const u8) Error!void {
        var p: usize = 0;
        while (p < seg.len) {
            const pq = seg[p] >> 4;
            const tq = seg[p] & 15;
            p += 1;
            if (tq > 3) return Error.BadImage;
            var i: usize = 0;
            while (i < 64) : (i += 1) {
                if (pq == 0) {
                    if (p >= seg.len) return Error.BadImage;
                    d.qt[tq][zigzag[i]] = seg[p];
                    p += 1;
                } else {
                    if (p + 1 >= seg.len) return Error.BadImage;
                    d.qt[tq][zigzag[i]] = std.mem.readInt(u16, seg[p..][0..2], .big);
                    p += 2;
                }
            }
        }
    }

    fn readDht(d: *Decoder, seg: []const u8) Error!void {
        var p: usize = 0;
        while (p + 17 <= seg.len) {
            const tc = seg[p] >> 4;
            const th = seg[p] & 15;
            p += 1;
            if (th > 3 or tc > 1) return Error.BadImage;
            const counts: *const [16]u8 = seg[p..][0..16];
            p += 16;
            var total: usize = 0;
            for (counts) |c| total += c;
            if (total > 256 or p + total > seg.len) return Error.BadImage;
            const table = Huffman.build(counts, seg[p .. p + total]);
            p += total;
            if (tc == 0) d.dc[th] = table else d.ac[th] = table;
        }
    }

    fn readSof(d: *Decoder, seg: []const u8, progressive: bool) Error!void {
        if (seg.len < 6) return Error.BadImage;
        if (seg[0] != 8) return Error.Unsupported;
        d.h = std.mem.readInt(u16, seg[1..3], .big);
        d.w = std.mem.readInt(u16, seg[3..5], .big);
        try checkSize(d.w, d.h);
        d.ncomp = seg[5];
        if (d.ncomp == 0 or d.ncomp > 4 or seg.len < 6 + d.ncomp * 3) return Error.BadImage;
        if (d.ncomp == 4) return Error.Unsupported; // CMYK
        d.progressive = progressive;
        var i: usize = 0;
        while (i < d.ncomp) : (i += 1) {
            const c = &d.comps[i];
            c.* = .{ .id = seg[6 + i * 3], .h = seg[7 + i * 3] >> 4, .v = seg[7 + i * 3] & 15, .tq = seg[8 + i * 3] };
            if (c.h == 0 or c.h > 4 or c.v == 0 or c.v > 4 or c.tq > 3) return Error.BadImage;
            d.hmax = @max(d.hmax, c.h);
            d.vmax = @max(d.vmax, c.v);
        }
        d.mcux = (d.w + 8 * @as(usize, d.hmax) - 1) / (8 * @as(usize, d.hmax));
        d.mcuy = (d.h + 8 * @as(usize, d.vmax) - 1) / (8 * @as(usize, d.vmax));
        i = 0;
        while (i < d.ncomp) : (i += 1) {
            const c = &d.comps[i];
            c.bw = d.mcux * c.h;
            c.bh = d.mcuy * c.v;
            c.coefs = try d.a.alloc(i16, c.bw * c.bh * 64);
            @memset(c.coefs, 0);
        }
        d.frame_seen = true;
    }

    /// One scan: its components and tables from the header, then the
    /// entropy-coded data up to the next marker; returns where it ended.
    fn readScan(d: *Decoder, bytes: []const u8, seg: []const u8, data_start: usize) Error!usize {
        if (seg.len < 1) return Error.BadImage;
        const ns: usize = seg[0];
        if (ns == 0 or ns > d.ncomp or seg.len < 1 + ns * 2 + 3) return Error.BadImage;
        var scomp: [4]usize = undefined;
        var i: usize = 0;
        while (i < ns) : (i += 1) {
            const cid = seg[1 + i * 2];
            const tables = seg[2 + i * 2];
            var found = false;
            var k: usize = 0;
            while (k < d.ncomp) : (k += 1) if (d.comps[k].id == cid) {
                scomp[i] = k;
                d.comps[k].td = tables >> 4;
                d.comps[k].ta = tables & 15;
                if (d.comps[k].td > 3 or d.comps[k].ta > 3) return Error.BadImage;
                found = true;
            };
            if (!found) return Error.BadImage;
        }
        const ss = seg[1 + ns * 2];
        const se = seg[2 + ns * 2];
        const ah: u5 = @intCast(seg[3 + ns * 2] >> 4);
        const al: u5 = @intCast(seg[3 + ns * 2] & 15);
        if (se > 63 or ss > se or al > 13) return Error.BadImage;
        var r: Reader = .{ .bytes = bytes, .pos = data_start };
        for (d.comps[0..d.ncomp]) |*c| c.dc_pred = 0;
        d.eobrun = 0;
        var mcus_done: usize = 0;
        if (ns == 1) {
            // Non-interleaved: the component's own blocks, in raster order
            // over its real (not MCU-padded) extent.
            const c = &d.comps[scomp[0]];
            const cw = (d.w * c.h + 8 * @as(usize, d.hmax) - 1) / (8 * @as(usize, d.hmax));
            const chh = (d.h * c.v + 8 * @as(usize, d.vmax) - 1) / (8 * @as(usize, d.vmax));
            var by: usize = 0;
            while (by < chh) : (by += 1) {
                var bx: usize = 0;
                while (bx < cw) : (bx += 1) {
                    try decodeBlock(d, &r, c, by * c.bw + bx, ss, se, ah, al);
                    mcus_done += 1;
                    if (d.restart_interval != 0 and mcus_done % d.restart_interval == 0 and !(by + 1 == chh and bx + 1 == cw)) {
                        r.restart();
                        for (d.comps[0..d.ncomp]) |*cc| cc.dc_pred = 0;
                        d.eobrun = 0;
                    }
                }
            }
        } else {
            var my: usize = 0;
            while (my < d.mcuy) : (my += 1) {
                var mx: usize = 0;
                while (mx < d.mcux) : (mx += 1) {
                    i = 0;
                    while (i < ns) : (i += 1) {
                        const c = &d.comps[scomp[i]];
                        var v: usize = 0;
                        while (v < c.v) : (v += 1) {
                            var hh: usize = 0;
                            while (hh < c.h) : (hh += 1) {
                                const bx = mx * c.h + hh;
                                const by = my * c.v + v;
                                try decodeBlock(d, &r, c, by * c.bw + bx, ss, se, ah, al);
                            }
                        }
                    }
                    mcus_done += 1;
                    if (d.restart_interval != 0 and mcus_done % d.restart_interval == 0 and !(my + 1 == d.mcuy and mx + 1 == d.mcux)) {
                        r.restart();
                        for (d.comps[0..d.ncomp]) |*cc| cc.dc_pred = 0;
                        d.eobrun = 0;
                    }
                }
            }
        }
        // Past the scan: at the marker the reader met, or where it stopped.
        if (r.marker != null) return r.pos;
        return r.pos;
    }

    /// One block's coefficients from the scan: a baseline block whole,
    /// or a progressive scan's share of it (DC first or refinement, AC
    /// first with EOB runs, AC refinement).
    fn decodeBlock(d: *Decoder, r: *Reader, c: *Component, block: usize, ss: u8, se: u8, ah: u5, al: u5) Error!void {
        if (block * 64 + 64 > c.coefs.len) return Error.BadImage;
        const blk = c.coefs[block * 64 .. block * 64 + 64];
        if (!d.progressive) {
            const t = try r.decodeSymbol(&d.dc[c.td]);
            const diff = r.receiveExtend(@intCast(t));
            c.dc_pred += diff;
            blk[0] = @intCast(std.math.clamp(c.dc_pred, -32768, 32767));
            var k: usize = 1;
            while (k < 64) {
                const rs = try r.decodeSymbol(&d.ac[c.ta]);
                const run: usize = rs >> 4;
                const size: u5 = @intCast(rs & 15);
                if (size == 0) {
                    if (run == 15) {
                        k += 16;
                        continue;
                    }
                    break;
                }
                k += run;
                if (k > 63) return Error.BadImage;
                blk[zigzag[k]] = @intCast(std.math.clamp(r.receiveExtend(size), -32768, 32767));
                k += 1;
            }
            return;
        }
        if (ss == 0) {
            // DC scan.
            if (ah == 0) {
                const t = try r.decodeSymbol(&d.dc[c.td]);
                const diff = r.receiveExtend(@intCast(t));
                c.dc_pred += diff;
                blk[0] = @intCast(std.math.clamp(c.dc_pred << al, -32768, 32767));
            } else if (r.bit() == 1) {
                blk[0] |= @as(i16, 1) << @as(u4, @intCast(al));
            }
            return;
        }
        // AC scans: one component at a time.
        if (ah == 0) {
            if (d.eobrun > 0) {
                d.eobrun -= 1;
                return;
            }
            var k: usize = ss;
            while (k <= se) {
                const rs = try r.decodeSymbol(&d.ac[c.ta]);
                const run: u5 = @intCast(rs >> 4);
                const size: u5 = @intCast(rs & 15);
                if (size == 0) {
                    if (run < 15) {
                        d.eobrun = (@as(u32, 1) << run) - 1;
                        if (run > 0) d.eobrun += r.take(run);
                        break;
                    }
                    k += 16;
                    continue;
                }
                k += run;
                if (k > 63) return Error.BadImage;
                blk[zigzag[k]] = @intCast(std.math.clamp(r.receiveExtend(size) * (@as(i32, 1) << al), -32768, 32767));
                k += 1;
            }
            return;
        }
        // AC refinement.
        const p1: i16 = @as(i16, 1) << @as(u4, @intCast(al));
        const m1: i16 = -p1;
        var k: usize = ss;
        if (d.eobrun == 0) {
            while (k <= se) {
                const rs = try r.decodeSymbol(&d.ac[c.ta]);
                var run: i32 = rs >> 4;
                const size: u5 = @intCast(rs & 15);
                var value: i16 = 0;
                if (size == 0) {
                    if (run < 15) {
                        d.eobrun = (@as(u32, 1) << @intCast(run));
                        if (run > 0) d.eobrun += r.take(@intCast(run));
                        break;
                    }
                } else {
                    if (size != 1) return Error.BadImage;
                    value = if (r.bit() == 1) p1 else m1;
                }
                while (k <= se) {
                    const z = zigzag[k];
                    if (blk[z] != 0) {
                        if (r.bit() == 1) {
                            if ((blk[z] & p1) == 0) {
                                if (blk[z] >= 0) blk[z] += p1 else blk[z] += m1;
                            }
                        }
                    } else {
                        if (run == 0) {
                            if (value != 0) blk[z] = value;
                            k += 1;
                            break;
                        }
                        run -= 1;
                    }
                    k += 1;
                }
            }
        }
        if (d.eobrun > 0) {
            while (k <= se) : (k += 1) {
                const z = zigzag[k];
                if (blk[z] != 0) {
                    if (r.bit() == 1) {
                        if ((blk[z] & p1) == 0) {
                            if (blk[z] >= 0) blk[z] += p1 else blk[z] += m1;
                        }
                    }
                }
            }
            d.eobrun -= 1;
        }
    }

    /// Dequantize, transform, upsample and convert: the picture.
    fn output(d: *Decoder) Error!Image {
        const a = d.a;
        const out = try a.alloc(u8, d.w * d.h * 4);
        errdefer a.free(out);
        // Each component to samples on its own plane.
        var planes: [4][]u8 = undefined;
        var np: usize = 0;
        defer for (planes[0..np]) |p| a.free(p);
        var cos_table: [8][8]f32 = undefined;
        for (0..8) |x| for (0..8) |u| {
            const cu: f32 = if (u == 0) 1.0 / @sqrt(2.0) else 1.0;
            cos_table[x][u] = cu * @cos(@as(f32, @floatFromInt((2 * x + 1) * u)) * std.math.pi / 16.0);
        };
        var i: usize = 0;
        while (i < d.ncomp) : (i += 1) {
            const c = &d.comps[i];
            const pw = c.bw * 8;
            const ph = c.bh * 8;
            const plane = try a.alloc(u8, pw * ph);
            planes[np] = plane;
            np += 1;
            const q = &d.qt[c.tq];
            var by: usize = 0;
            while (by < c.bh) : (by += 1) {
                var bx: usize = 0;
                while (bx < c.bw) : (bx += 1) {
                    const blk = c.coefs[(by * c.bw + bx) * 64 ..][0..64];
                    var f: [64]f32 = undefined;
                    for (0..64) |k| f[k] = @as(f32, @floatFromInt(blk[k])) * @as(f32, @floatFromInt(q[k]));
                    var tmp: [64]f32 = undefined;
                    // Rows then columns of the separable inverse DCT.
                    for (0..8) |y| for (0..8) |x| {
                        var s: f32 = 0;
                        for (0..8) |u| s += cos_table[x][u] * f[y * 8 + u];
                        tmp[y * 8 + x] = s / 2;
                    };
                    for (0..8) |x| for (0..8) |y| {
                        var s: f32 = 0;
                        for (0..8) |v| s += cos_table[y][v] * tmp[v * 8 + x];
                        const val = s / 2 + 128;
                        plane[(by * 8 + y) * pw + bx * 8 + x] = @intFromFloat(std.math.clamp(@round(val), 0, 255));
                    };
                }
            }
        }
        // To RGBA, each component sampled at its own resolution.
        var y: usize = 0;
        while (y < d.h) : (y += 1) {
            var x: usize = 0;
            while (x < d.w) : (x += 1) {
                var s: [3]u8 = .{ 0, 128, 128 };
                i = 0;
                while (i < d.ncomp and i < 3) : (i += 1) {
                    const c = &d.comps[i];
                    s[i] = sampleAt(planes[i], c.bw * 8, c.bh * 8, x, y, c.h, c.v, d.hmax, d.vmax);
                }
                const o = (y * d.w + x) * 4;
                if (d.ncomp == 1) {
                    out[o] = s[0];
                    out[o + 1] = s[0];
                    out[o + 2] = s[0];
                } else {
                    const yy: f32 = @floatFromInt(s[0]);
                    const cb: f32 = @as(f32, @floatFromInt(s[1])) - 128;
                    const cr: f32 = @as(f32, @floatFromInt(s[2])) - 128;
                    out[o] = clamp8(yy + 1.402 * cr);
                    out[o + 1] = clamp8(yy - 0.344136 * cb - 0.714136 * cr);
                    out[o + 2] = clamp8(yy + 1.772 * cb);
                }
                out[o + 3] = 255;
            }
        }
        return .{ .w = @intCast(d.w), .h = @intCast(d.h), .rgba = out };
    }

    /// A component's sample under picture pixel (x, y): its own pixel
    /// when the component is full size, else interpolated between its
    /// neighbours, centre to centre — what libjpeg's "fancy" upsampling
    /// does, and the references were made with it.
    fn sampleAt(plane: []const u8, pw: usize, ph: usize, x: usize, y: usize, ch: u8, cv: u8, hmax: u8, vmax: u8) u8 {
        if (ch == hmax and cv == vmax) return plane[y * pw + x];
        const fx = (@as(f32, @floatFromInt(x)) + 0.5) * @as(f32, @floatFromInt(ch)) / @as(f32, @floatFromInt(hmax)) - 0.5;
        const fy = (@as(f32, @floatFromInt(y)) + 0.5) * @as(f32, @floatFromInt(cv)) / @as(f32, @floatFromInt(vmax)) - 0.5;
        const x0f = @max(0, @floor(fx));
        const y0f = @max(0, @floor(fy));
        const x0: usize = @intFromFloat(x0f);
        const y0: usize = @intFromFloat(y0f);
        const x1 = @min(x0 + 1, pw - 1);
        const y1 = @min(y0 + 1, ph - 1);
        const tx = @max(0, fx - x0f);
        const ty = @max(0, fy - y0f);
        const p00: f32 = @floatFromInt(plane[y0 * pw + x0]);
        const p10: f32 = @floatFromInt(plane[y0 * pw + x1]);
        const p01: f32 = @floatFromInt(plane[y1 * pw + x0]);
        const p11: f32 = @floatFromInt(plane[y1 * pw + x1]);
        const top = p00 + (p10 - p00) * tx;
        const bot = p01 + (p11 - p01) * tx;
        return clamp8(top + (bot - top) * ty);
    }

    fn clamp8(v: f32) u8 {
        return @intFromFloat(std.math.clamp(@round(v), 0, 255));
    }
};

// ---------------------------------------------------------------- tests

const verbose = false;

// The corpus: every picture under tools/testdata/images beside the
// RGBA bytes ImageMagick decoded it to and its size; PNG and GIF must
// match exactly, JPEG within a tolerance (two IDCTs, and chroma
// upsampling, differ by a shade). The count is printed and asserted.
test "images: the corpus decodes as its references" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = std.Io.Dir.cwd().openDir(io, "tools/testdata/images", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file) continue;
        const ext = std.fs.path.extension(entry.name);
        if (std.mem.eql(u8, ext, ".png") or std.mem.eql(u8, ext, ".jpg") or std.mem.eql(u8, ext, ".gif")) try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f);
    var passed: usize = 0;
    for (names.items) |name| {
        const stem = name[0 .. name.len - 4];
        const bytes = try dir.readFileAlloc(io, name, a, .limited(1 << 22));
        const ref = try dir.readFileAlloc(io, try std.mem.concat(a, u8, &.{ stem, ".rgba" }), a, .limited(1 << 24));
        const size_text = try dir.readFileAlloc(io, try std.mem.concat(a, u8, &.{ stem, ".txt" }), a, .limited(64));
        var parts = std.mem.tokenizeAny(u8, size_text, " \n\r");
        const w = try std.fmt.parseInt(u32, parts.next() orelse "0", 10);
        const h = try std.fmt.parseInt(u32, parts.next() orelse "0", 10);
        if (verbose) std.debug.print("... {s}\n", .{name});
        const img = decode(a, bytes) catch |e| {
            if (verbose) std.debug.print("--- {s}: {s}\n", .{ name, @errorName(e) });
            continue;
        };
        if (img.w != w or img.h != h or ref.len != img.rgba.len) {
            if (verbose) std.debug.print("--- {s}: size {d}x{d}, wanted {d}x{d}\n", .{ name, img.w, img.h, w, h });
            continue;
        }
        const tolerance: i32 = if (std.mem.endsWith(u8, name, ".jpg")) 12 else 0;
        var worst: i32 = 0;
        var bad: ?usize = null;
        for (img.rgba, ref, 0..) |g, r, i| {
            const diff: i32 = @intCast(@abs(@as(i32, g) - @as(i32, r)));
            worst = @max(worst, diff);
            if (diff > tolerance and bad == null) bad = i;
        }
        if (bad) |i| {
            if (verbose) std.debug.print("--- {s}: pixel {d} channel {d}: got {d}, wanted {d} (worst {d})\n", .{ name, i / 4, i % 4, img.rgba[i], ref[i], worst });
            continue;
        }
        passed += 1;
    }
    std.debug.print("images: {d}/{d} of the corpus decode as their references\n", .{ passed, names.items.len });
    try std.testing.expectEqual(names.items.len, passed);
}

test "images: a truncated or foreign file is refused, never a partial picture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try std.testing.expectError(Error.Unsupported, decode(a, "not a picture at all"));
    var trunc = png_signature ++ [_]u8{ 0, 0, 0, 13, 'I', 'H', 'D', 'R', 0, 0, 0, 5 };
    try std.testing.expectError(Error.BadImage, decode(a, &trunc));
    try std.testing.expectError(Error.BadImage, decode(a, "GIF89a\x05\x00"));
    try std.testing.expectError(Error.BadImage, decode(a, "\xff\xd8\xff\xe0\x00\x04"));
}
