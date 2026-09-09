//! font — a from-scratch vector-font rasterizer for moss's system font
//! service. Pure, freestanding-safe, host-tested: no allocator of its own
//! beyond what the caller hands in, no I/O, just bytes in (an SFNT font)
//! and an anti-aliased coverage bitmap out.
//!
//! Every font format moss will support converges here: an SFNT container
//! (a table directory) whose glyph outlines are filled by one rasterizer.
//! Two outline flavours land in the same coverage bitmap: TrueType (`glyf`,
//! quadratic curves) and OpenType/PostScript (`CFF `, Type2 charstrings with
//! cubic curves). WOFF (zlib) and WOFF2 (Brotli) are additive front-ends —
//! they decompress/transform to the same SFNT this reads.
//!
//! The rasterizer is a supersampled scanline fill with non-zero winding:
//! simple and correct, and a glyph is rasterized once per (glyph, size)
//! and cached by the service, so clarity beats cleverness here.

const std = @import("std");
const flate = std.compress.flate;
const woff2 = @import("woff2.zig");
const tthint = @import("tthint.zig");

pub const Error = error{ BadFont, Unsupported, OutOfMemory, Hint };

// ------------------------------------------------------------ big-endian

fn u16be(b: []const u8, off: usize) u16 {
    return @as(u16, b[off]) << 8 | b[off + 1];
}
fn i16be(b: []const u8, off: usize) i16 {
    return @bitCast(u16be(b, off));
}
fn u32be(b: []const u8, off: usize) u32 {
    return @as(u32, b[off]) << 24 | @as(u32, b[off + 1]) << 16 | @as(u32, b[off + 2]) << 8 | b[off + 3];
}
fn wr16be(b: []u8, off: usize, v: u16) void {
    b[off] = @intCast(v >> 8);
    b[off + 1] = @intCast(v & 0xff);
}
fn wr32be(b: []u8, off: usize, v: u32) void {
    b[off] = @intCast((v >> 24) & 0xff);
    b[off + 1] = @intCast((v >> 16) & 0xff);
    b[off + 2] = @intCast((v >> 8) & 0xff);
    b[off + 3] = @intCast(v & 0xff);
}

// ------------------------------------------------ front-ends → SFNT
//
// Every container converges to an SFNT (a table directory) the parser
// below reads. TrueType/OpenType are already SFNT; WOFF wraps one with
// per-table zlib compression; WOFF2 is Brotli plus a glyf/loca transform
// (lib/woff2.zig). `toSfnt` normalises the input into `out` and returns the
// SFNT bytes — or the input itself, untouched, when it is already an SFNT.
// The allocator is used only by the WOFF2 path (Brotli + reconstruction).

const sfnt_true = 0x00010000; // TrueType outlines
const sfnt_ttcf = 0x74746366; // 'ttcf' collection (unsupported)
const tag_true = 0x74727565; // 'true'
const tag_otto = 0x4F54544F; // 'OTTO' (OpenType/CFF)
const tag_woff = 0x774F4646; // 'wOFF'
const tag_woff2 = 0x774F4632; // 'wOF2'

/// Decompress a zlib stream into `out` (exactly `out.len` bytes expected).
fn zlibInto(comp: []const u8, out: []u8) bool {
    var in = std.Io.Reader.fixed(comp);
    var window: [flate.max_window_len]u8 = undefined;
    var dc = flate.Decompress.init(&in, .zlib, &window);
    dc.reader.readSliceAll(out) catch return false;
    return true;
}

/// Normalise a font file to SFNT bytes. SFNT input is returned as-is;
/// WOFF/WOFF2 are decompressed/reassembled into `out`. `out` must hold the
/// whole SFNT (both formats state its size). `a` backs the WOFF2 path.
pub fn toSfnt(a: std.mem.Allocator, input: []const u8, out: []u8) Error![]const u8 {
    if (input.len < 4) return Error.BadFont;
    const magic = u32be(input, 0);
    if (magic == sfnt_true or magic == tag_true or magic == tag_otto) return input;
    if (magic == tag_woff2) {
        return woff2.decode(a, input, out) catch |e| switch (e) {
            error.OutOfMemory => Error.OutOfMemory,
            error.Unsupported => Error.Unsupported,
            error.BadFont => Error.BadFont,
        };
    }
    if (magic != tag_woff) return Error.BadFont;
    // WOFF: a 44-byte header, then numTables 20-byte directory entries.
    if (input.len < 44) return Error.BadFont;
    const flavor = u32be(input, 4);
    const num = u16be(input, 12);
    const total = u32be(input, 16); // totalSfntSize
    if (total > out.len) return Error.BadFont;
    // The reassembled SFNT: header, directory, then each table (4-aligned).
    wr32be(out, 0, flavor);
    wr16be(out, 4, num);
    wr16be(out, 6, 0); // searchRange / entrySelector / rangeShift: the
    wr16be(out, 8, 0); // parser recomputes from numTables, so leave zero.
    wr16be(out, 10, 0);
    var dst: usize = (12 + @as(usize, num) * 16 + 3) & ~@as(usize, 3);
    var i: usize = 0;
    while (i < num) : (i += 1) {
        const e = 44 + i * 20;
        if (e + 20 > input.len) return Error.BadFont;
        const tag = u32be(input, e);
        const off = u32be(input, e + 4);
        const comp = u32be(input, e + 8);
        const orig = u32be(input, e + 12);
        const csum = u32be(input, e + 16);
        if (off + comp > input.len or dst + orig > out.len) return Error.BadFont;
        if (comp < orig) {
            if (!zlibInto(input[off .. off + comp], out[dst .. dst + orig])) return Error.BadFont;
        } else {
            @memcpy(out[dst .. dst + orig], input[off .. off + comp]);
        }
        const de = 12 + i * 16;
        wr32be(out, de, tag);
        wr32be(out, de + 4, csum);
        wr32be(out, de + 8, @intCast(dst));
        wr32be(out, de + 12, orig);
        dst = (dst + orig + 3) & ~@as(usize, 3);
    }
    return out[0..dst];
}

// ------------------------------------------------------------ the font

/// A parsed SFNT: the table slices we need, and the header fields that
/// tell us how to read glyphs. Borrows `data`; it must outlive the Font.
pub const Font = struct {
    data: []const u8,
    units_per_em: u16,
    num_glyphs: u16,
    long_loca: bool, // head.indexToLocFormat: 0 = u16 offsets (×2), 1 = u32
    num_hmetrics: u16,
    // Table byte-slices (empty if absent).
    head: []const u8,
    maxp: []const u8,
    hhea: []const u8,
    hmtx: []const u8,
    loca: []const u8,
    glyf: []const u8,
    cmap: []const u8,
    name: []const u8,
    // TrueType hinting programs (empty if unhinted): the font program
    // (functions), the control-value program (per-size setup) and the CVT.
    fpgm: []const u8,
    prep: []const u8,
    cvt: []const u8,
    // The chosen Unicode cmap subtable (a slice of `cmap`), and its format.
    cmap_sub: []const u8,
    cmap_fmt: u16,
    ascent: i16,
    descent: i16,
    // OpenType/CFF (`CFF ` table): when present the outlines are Type2
    // charstrings, not `glyf`. `is_cff` picks the outline decoder.
    is_cff: bool,
    cff: []const u8,
    cff_charstrings: Index,
    cff_gsubrs: Index,
    cff_lsubrs: Index,

    pub fn parse(data: []const u8) Error!Font {
        if (data.len < 12) return Error.BadFont;
        const tag = u32be(data, 0);
        // 0x00010000 (TrueType), 'true', 'OTTO' (OpenType/CFF), 'ttcf' (collection).
        if (tag == 0x74746366) return Error.Unsupported; // 'ttcf' collection: pick a face later
        const num_tables = u16be(data, 4);
        var f = Font{
            .data = data,
            .units_per_em = 1000,
            .num_glyphs = 0,
            .long_loca = false,
            .num_hmetrics = 0,
            .head = &.{},
            .maxp = &.{},
            .hhea = &.{},
            .hmtx = &.{},
            .loca = &.{},
            .glyf = &.{},
            .cmap = &.{},
            .name = &.{},
            .fpgm = &.{},
            .prep = &.{},
            .cvt = &.{},
            .cmap_sub = &.{},
            .cmap_fmt = 0,
            .ascent = 0,
            .descent = 0,
            .is_cff = false,
            .cff = &.{},
            .cff_charstrings = Index.empty(),
            .cff_gsubrs = Index.empty(),
            .cff_lsubrs = Index.empty(),
        };
        var i: usize = 0;
        const dir = 12;
        while (i < num_tables) : (i += 1) {
            const rec = dir + i * 16;
            if (rec + 16 > data.len) return Error.BadFont;
            const t = u32be(data, rec);
            const off = u32be(data, rec + 8);
            const len = u32be(data, rec + 12);
            if (off + len > data.len) return Error.BadFont;
            const slice = data[off .. off + len];
            switch (t) {
                0x68656164 => f.head = slice, // 'head'
                0x6D617870 => f.maxp = slice, // 'maxp'
                0x68686561 => f.hhea = slice, // 'hhea'
                0x686D7478 => f.hmtx = slice, // 'hmtx'
                0x6C6F6361 => f.loca = slice, // 'loca'
                0x676C7966 => f.glyf = slice, // 'glyf'
                0x636D6170 => f.cmap = slice, // 'cmap'
                0x6E616D65 => f.name = slice, // 'name'
                0x43464620 => f.cff = slice, // 'CFF ' (OpenType/PostScript)
                0x6670676D => f.fpgm = slice, // 'fpgm' (font program)
                0x70726570 => f.prep = slice, // 'prep' (control-value program)
                0x63767420 => f.cvt = slice, // 'cvt ' (control-value table)
                else => {},
            }
        }
        if (f.head.len < 54 or f.maxp.len < 6 or f.hhea.len < 36) return Error.BadFont;
        f.units_per_em = u16be(f.head, 18);
        f.long_loca = i16be(f.head, 50) != 0;
        f.num_glyphs = u16be(f.maxp, 4);
        f.ascent = i16be(f.hhea, 4);
        f.descent = i16be(f.hhea, 6);
        f.num_hmetrics = u16be(f.hhea, 34);
        if (f.units_per_em == 0) return Error.BadFont;
        if (f.glyf.len != 0 and f.loca.len != 0) {
            f.is_cff = false;
        } else if (f.cff.len != 0) {
            f.is_cff = true;
            try f.parseCff();
        } else return Error.Unsupported; // neither TrueType nor CFF outlines
        try f.pickCmap();
        return f;
    }

    /// Choose a Unicode cmap subtable: prefer (3,10)/(3,1)/(0,*), format 4 or 12.
    fn pickCmap(f: *Font) Error!void {
        if (f.cmap.len < 4) return Error.BadFont;
        const n = u16be(f.cmap, 2);
        var best_off: usize = 0;
        var best_score: i32 = -1;
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const rec = 4 + i * 8;
            if (rec + 8 > f.cmap.len) return Error.BadFont;
            const plat = u16be(f.cmap, rec);
            const enc = u16be(f.cmap, rec + 2);
            const off = u32be(f.cmap, rec + 4);
            if (off + 2 > f.cmap.len) continue;
            const fmt = u16be(f.cmap, off);
            if (fmt != 4 and fmt != 12) continue;
            // Prefer full-Unicode (3,10)/(0,6) then BMP (3,1)/(0,3..4).
            const score: i32 = blk: {
                if (plat == 3 and enc == 10) break :blk 5;
                if (plat == 0 and enc >= 4) break :blk 4;
                if (plat == 3 and enc == 1) break :blk 3;
                if (plat == 0) break :blk 2;
                break :blk 1;
            };
            if (score > best_score) {
                best_score = score;
                best_off = off;
            }
        }
        if (best_score < 0) return Error.Unsupported;
        f.cmap_sub = f.cmap[best_off..];
        f.cmap_fmt = u16be(f.cmap_sub, 0);
    }

    /// The glyph index for a Unicode code point (0 = .notdef / missing).
    pub fn glyphIndex(f: *const Font, cp: u21) u16 {
        return switch (f.cmap_fmt) {
            4 => f.cmapFmt4(cp),
            12 => f.cmapFmt12(cp),
            else => 0,
        };
    }

    fn cmapFmt4(f: *const Font, cp: u21) u16 {
        if (cp > 0xffff) return 0;
        const s = f.cmap_sub;
        if (s.len < 14) return 0;
        const segx2 = u16be(s, 6);
        const segs = segx2 / 2;
        const end_o = 14;
        const start_o = end_o + segx2 + 2; // +2 reservedPad
        const delta_o = start_o + segx2;
        const range_o = delta_o + segx2;
        const c: u16 = @intCast(cp);
        var i: usize = 0;
        while (i < segs) : (i += 1) {
            const end = u16be(s, end_o + i * 2);
            if (c > end) continue;
            const start = u16be(s, start_o + i * 2);
            if (c < start) return 0;
            const delta = u16be(s, delta_o + i * 2);
            const range = u16be(s, range_o + i * 2);
            if (range == 0) return c +% delta;
            // glyphId at rangeOffset location (the spec's pointer trick).
            const gi_o = range_o + i * 2 + range + (c - start) * 2;
            if (gi_o + 2 > s.len) return 0;
            const g = u16be(s, gi_o);
            return if (g == 0) 0 else g +% delta;
        }
        return 0;
    }

    fn cmapFmt12(f: *const Font, cp: u21) u16 {
        const s = f.cmap_sub;
        if (s.len < 16) return 0;
        const ngroups = u32be(s, 12);
        var i: usize = 0;
        while (i < ngroups) : (i += 1) {
            const g = 16 + i * 12;
            if (g + 12 > s.len) return 0;
            const start = u32be(s, g);
            const end = u32be(s, g + 4);
            const gid = u32be(s, g + 8);
            if (cp >= start and cp <= end) return @intCast(gid + (cp - start));
        }
        return 0;
    }

    /// Whether this font carries a TrueType hint program worth running
    /// (glyf outlines with a prep or fpgm). CFF fonts never do.
    pub fn hasHints(f: *const Font) bool {
        return !f.is_cff and (f.prep.len != 0 or f.fpgm.len != 0);
    }

    /// Generous interpreter buffer sizes, from `maxp` but never trusting
    /// its (routinely under-reported) values — a font that defines
    /// functions while claiming maxFunctionDefs=0 is common. Hinting is
    /// best-effort, so over-provisioning is cheap and under-provisioning
    /// merely trips the fallback.
    pub const HintLimits = struct { stack: usize, storage: usize, funcs: usize, twilight: usize };
    pub fn hintLimits(f: *const Font) HintLimits {
        const stack = if (f.maxp.len >= 26) u16be(f.maxp, 24) else 0;
        const storage = if (f.maxp.len >= 20) u16be(f.maxp, 18) else 0;
        const funcs = if (f.maxp.len >= 22) u16be(f.maxp, 20) else 0;
        const twilight = if (f.maxp.len >= 18) u16be(f.maxp, 16) else 0;
        return .{
            .stack = @max(@as(usize, stack), 256) + 256,
            .storage = @max(@as(usize, storage) + 8, 64),
            .funcs = @max(@as(usize, funcs), 256),
            .twilight = @max(@as(usize, twilight) + 4, 16),
        };
    }

    /// The advance width of a glyph, in font units.
    pub fn advance(f: *const Font, gid: u16) u16 {
        if (f.num_hmetrics == 0 or f.hmtx.len < 4) return 0;
        const idx = if (gid < f.num_hmetrics) gid else f.num_hmetrics - 1;
        const o = @as(usize, idx) * 4;
        if (o + 2 > f.hmtx.len) return 0;
        return u16be(f.hmtx, o);
    }

    /// The left side bearing of a glyph, in font units (for a hinted
    /// glyph's left phantom point). Glyphs past num_hmetrics share the
    /// last advance but keep their own lsb in the trailing array.
    pub fn leftBearing(f: *const Font, gid: u16) i16 {
        if (f.num_hmetrics == 0) return 0;
        if (gid < f.num_hmetrics) {
            const o = @as(usize, gid) * 4 + 2;
            if (o + 2 > f.hmtx.len) return 0;
            return i16be(f.hmtx, o);
        }
        const o = @as(usize, f.num_hmetrics) * 4 + @as(usize, gid - f.num_hmetrics) * 2;
        if (o + 2 > f.hmtx.len) return 0;
        return i16be(f.hmtx, o);
    }

    /// The font's family name (`name` table, nameID 1), decoded ASCII into
    /// `buf` — how the font registry keys a family. Prefers the Windows
    /// (UTF-16BE) record, falls back to a Mac/ASCII one; empty if absent.
    pub fn familyName(f: *const Font, buf: []u8) []const u8 {
        const s = f.name;
        if (s.len < 6) return "";
        const count = u16be(s, 2);
        const str_base = u16be(s, 4);
        var best_off: usize = 0;
        var best_len: usize = 0;
        var best_win = false; // the chosen record is UTF-16BE (platform 3/0)
        var best_score: i32 = -1;
        var i: usize = 0;
        while (i < count) : (i += 1) {
            const rec = 6 + i * 12;
            if (rec + 12 > s.len) break;
            const plat = u16be(s, rec);
            const name_id = u16be(s, rec + 6);
            if (name_id != 1) continue; // Font Family
            const len = u16be(s, rec + 8);
            const off = u16be(s, rec + 10);
            const score: i32 = switch (plat) {
                3 => 3, // Windows (UTF-16BE)
                0 => 2, // Unicode (UTF-16BE)
                1 => 1, // Mac (single-byte)
                else => 0,
            };
            if (score > best_score) {
                best_score = score;
                best_off = @as(usize, str_base) + off;
                best_len = len;
                best_win = plat == 3 or plat == 0;
            }
        }
        if (best_score < 0 or best_off + best_len > s.len) return "";
        const raw = s[best_off .. best_off + best_len];
        var n: usize = 0;
        if (best_win) {
            // UTF-16BE: take the low byte of each unit (ASCII family names).
            var j: usize = 1;
            while (j < raw.len and n < buf.len) : (j += 2) {
                buf[n] = raw[j];
                n += 1;
            }
        } else {
            const m = @min(raw.len, buf.len);
            @memcpy(buf[0..m], raw[0..m]);
            n = m;
        }
        return buf[0..n];
    }

    /// The byte range of glyph `gid` in the `glyf` table (null = empty glyph).
    fn glyfRange(f: *const Font, gid: u16) ?struct { start: usize, end: usize } {
        if (gid >= f.num_glyphs) return null;
        const g: usize = gid;
        var start: usize = 0;
        var end: usize = 0;
        if (f.long_loca) {
            if ((g + 2) * 4 > f.loca.len) return null;
            start = u32be(f.loca, g * 4);
            end = u32be(f.loca, (g + 1) * 4);
        } else {
            if ((g + 2) * 2 > f.loca.len) return null;
            start = @as(usize, u16be(f.loca, g * 2)) * 2;
            end = @as(usize, u16be(f.loca, (g + 1) * 2)) * 2;
        }
        if (end <= start or end > f.glyf.len) return null; // empty (space) glyph
        return .{ .start = start, .end = end };
    }

    /// Parse the `CFF ` table down to the three INDEXes the Type2 charstring
    /// interpreter needs: CharStrings (one per glyph), global subrs, and the
    /// local subrs named by the Private DICT. Non-CID only (a single Top +
    /// Private DICT) — the CID case (FDArray/FDSelect) is a later refinement.
    fn parseCff(f: *Font) Error!void {
        const c = f.cff;
        if (c.len < 4) return Error.BadFont;
        const hdr_size = c[2];
        if (hdr_size < 4 or hdr_size > c.len) return Error.BadFont;
        // Name, Top DICT, String, Global Subr INDEXes, back to back.
        const name_idx = try parseIndex(c, hdr_size);
        const top_idx = try parseIndex(c, name_idx.end);
        const string_idx = try parseIndex(c, top_idx.end);
        const gsubr_idx = try parseIndex(c, string_idx.end);
        if (top_idx.count == 0) return Error.BadFont;
        const td = try parseTopDict(top_idx.item(0));
        if (td.is_cid) return Error.Unsupported; // CID-keyed: FDArray/FDSelect
        if (td.cstype != 2) return Error.Unsupported; // Type1 charstrings
        if (td.charstrings == 0) return Error.BadFont;
        const cs_idx = try parseIndex(c, td.charstrings);
        // The Private DICT gives the local subrs (offset relative to itself).
        var lsubr = Index.empty();
        if (td.priv_size > 0 and td.priv_off + td.priv_size <= c.len) {
            const pd = try parsePrivDict(c[td.priv_off .. td.priv_off + td.priv_size]);
            if (pd.subrs != 0 and td.priv_off + pd.subrs < c.len) {
                lsubr = try parseIndex(c, td.priv_off + pd.subrs);
            }
        }
        f.cff_charstrings = cs_idx;
        f.cff_gsubrs = gsubr_idx;
        f.cff_lsubrs = lsubr;
    }
};

// ---------------------------------------------------------------- CFF

/// A CFF INDEX: a count-prefixed array of variable-length objects, indexed
/// by an offset array. Borrows the `CFF ` table bytes.
const Index = struct {
    bytes: []const u8,
    count: u32,
    off_size: u8,
    off_arr: usize, // byte offset of the offset array
    data_off: usize, // object-data base minus 1 (offsets are 1-based)
    end: usize, // one past the whole INDEX

    fn empty() Index {
        return .{ .bytes = &.{}, .count = 0, .off_size = 1, .off_arr = 0, .data_off = 0, .end = 0 };
    }

    fn readOff(self: Index, i: u32) usize {
        var v: usize = 0;
        const p = self.off_arr + @as(usize, i) * self.off_size;
        var k: usize = 0;
        while (k < self.off_size) : (k += 1) v = (v << 8) | self.bytes[p + k];
        return v;
    }

    /// Object `i` (empty slice if out of range or malformed).
    fn item(self: Index, i: u32) []const u8 {
        if (i >= self.count) return &.{};
        const s = self.data_off + self.readOff(i);
        const e = self.data_off + self.readOff(i + 1);
        if (s > e or e > self.bytes.len) return &.{};
        return self.bytes[s..e];
    }
};

fn parseIndex(bytes: []const u8, at: usize) Error!Index {
    if (at + 2 > bytes.len) return Error.BadFont;
    const count = u16be(bytes, at);
    if (count == 0) return .{ .bytes = bytes, .count = 0, .off_size = 1, .off_arr = at + 2, .data_off = at + 2, .end = at + 2 };
    if (at + 3 > bytes.len) return Error.BadFont;
    const off_size = bytes[at + 2];
    if (off_size < 1 or off_size > 4) return Error.BadFont;
    const off_arr = at + 3;
    const n_off = @as(usize, count) + 1;
    if (off_arr + n_off * off_size > bytes.len) return Error.BadFont;
    const data_off = off_arr + n_off * off_size - 1;
    var idx = Index{ .bytes = bytes, .count = count, .off_size = off_size, .off_arr = off_arr, .data_off = data_off, .end = 0 };
    idx.end = data_off + idx.readOff(count);
    if (idx.end > bytes.len or idx.end < data_off) return Error.BadFont;
    return idx;
}

// --- DICT parsing (operands precede their operator) ---

const DictOp = struct { val: f64, next: usize };

/// Read one DICT operand at `i` (integers exact; reals skipped as 0 — the
/// operators we read take integers).
fn readDictOperand(d: []const u8, i: usize) Error!DictOp {
    const b0 = d[i];
    if (b0 == 28) {
        if (i + 3 > d.len) return Error.BadFont;
        return .{ .val = @floatFromInt(i16be(d, i + 1)), .next = i + 3 };
    }
    if (b0 == 29) {
        if (i + 5 > d.len) return Error.BadFont;
        return .{ .val = @floatFromInt(@as(i32, @bitCast(u32be(d, i + 1)))), .next = i + 5 };
    }
    if (b0 == 30) {
        // Real number: BCD nibbles terminated by an 0xf nibble.
        var j = i + 1;
        while (j < d.len) {
            const byte = d[j];
            j += 1;
            if ((byte >> 4) == 0xf or (byte & 0xf) == 0xf) break;
        }
        return .{ .val = 0, .next = j };
    }
    if (b0 >= 32 and b0 <= 246) return .{ .val = @floatFromInt(@as(i32, b0) - 139), .next = i + 1 };
    if (b0 >= 247 and b0 <= 250) {
        if (i + 2 > d.len) return Error.BadFont;
        return .{ .val = @floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, d[i + 1]) + 108), .next = i + 2 };
    }
    if (b0 >= 251 and b0 <= 254) {
        if (i + 2 > d.len) return Error.BadFont;
        return .{ .val = @floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, d[i + 1]) - 108), .next = i + 2 };
    }
    return Error.BadFont;
}

const TopDict = struct {
    charstrings: usize = 0,
    priv_size: usize = 0,
    priv_off: usize = 0,
    cstype: u8 = 2,
    is_cid: bool = false,
};

fn parseTopDict(d: []const u8) Error!TopDict {
    var td = TopDict{};
    var ops: [48]f64 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < d.len) {
        const b = d[i];
        if (b <= 21) {
            var op: u16 = b;
            i += 1;
            if (b == 12) {
                if (i >= d.len) return Error.BadFont;
                op = 0x0c00 | @as(u16, d[i]);
                i += 1;
            }
            switch (op) {
                17 => if (n >= 1) {
                    td.charstrings = @intFromFloat(ops[0]);
                },
                18 => if (n >= 2) {
                    td.priv_size = @intFromFloat(ops[0]);
                    td.priv_off = @intFromFloat(ops[1]);
                },
                0x0c06 => if (n >= 1) {
                    td.cstype = @intFromFloat(ops[0]);
                },
                0x0c1e => td.is_cid = true, // ROS: CID-keyed font
                else => {},
            }
            n = 0;
        } else {
            const r = try readDictOperand(d, i);
            if (n < ops.len) {
                ops[n] = r.val;
                n += 1;
            }
            i = r.next;
        }
    }
    return td;
}

const PrivDict = struct { subrs: usize = 0 };

fn parsePrivDict(d: []const u8) Error!PrivDict {
    var pd = PrivDict{};
    var ops: [48]f64 = undefined;
    var n: usize = 0;
    var i: usize = 0;
    while (i < d.len) {
        const b = d[i];
        if (b <= 21) {
            var op: u16 = b;
            i += 1;
            if (b == 12) {
                if (i >= d.len) return Error.BadFont;
                op = 0x0c00 | @as(u16, d[i]);
                i += 1;
            }
            if (op == 19 and n >= 1) pd.subrs = @intFromFloat(ops[0]); // Subrs
            n = 0;
        } else {
            const r = try readDictOperand(d, i);
            if (n < ops.len) {
                ops[n] = r.val;
                n += 1;
            }
            i = r.next;
        }
    }
    return pd;
}

// -------------------------------------------------------------- outlines

/// A point of a glyph contour, in font units (y up). `on` = on-curve.
const Point = struct { x: f32, y: f32, on: bool };

/// A decoded outline: points and the index one-past-the-end of each contour.
const Outline = struct {
    pts: std.ArrayList(Point),
    ends: std.ArrayList(usize),
    fn deinit(o: *Outline, a: std.mem.Allocator) void {
        o.pts.deinit(a);
        o.ends.deinit(a);
    }
};

// glyf simple-glyph flags.
const ON_CURVE: u8 = 0x01;
const X_SHORT: u8 = 0x02;
const Y_SHORT: u8 = 0x04;
const REPEAT: u8 = 0x08;
const X_SAME_POS: u8 = 0x10; // x is same, or (with X_SHORT) positive
const Y_SAME_POS: u8 = 0x20;

/// Decode glyph `gid` into an outline in font units. Composite glyphs are
/// flattened by recursively placing their components (offset only; the
/// rare scaled component is a later refinement). An empty glyph yields no
/// contours. `depth` guards against a cyclic composite.
fn decodeOutline(f: *const Font, a: std.mem.Allocator, gid: u16, out: *Outline, depth: u8) Error!void {
    if (depth > 5) return;
    const r = f.glyfRange(gid) orelse return; // empty glyph: nothing to draw
    const g = f.glyf[r.start..r.end];
    if (g.len < 10) return Error.BadFont;
    const ncont = i16be(g, 0);
    if (ncont < 0) return decodeComposite(f, a, g, out, depth);

    const nc: usize = @intCast(ncont);
    var o: usize = 10;
    if (o + nc * 2 > g.len) return Error.BadFont;
    const base = out.pts.items.len;
    var npts: usize = 0;
    var ci: usize = 0;
    while (ci < nc) : (ci += 1) {
        const e = u16be(g, o);
        o += 2;
        npts = @as(usize, e) + 1;
        try out.ends.append(a, base + npts);
    }
    // Skip instructions.
    if (o + 2 > g.len) return Error.BadFont;
    const ilen = u16be(g, o);
    o += 2 + ilen;
    // Flags (run-length encoded).
    const flags = try a.alloc(u8, npts);
    defer a.free(flags);
    var k: usize = 0;
    while (k < npts) {
        if (o >= g.len) return Error.BadFont;
        const fl = g[o];
        o += 1;
        flags[k] = fl;
        k += 1;
        if (fl & REPEAT != 0) {
            if (o >= g.len) return Error.BadFont;
            var rep = g[o];
            o += 1;
            while (rep > 0 and k < npts) : (rep -= 1) {
                flags[k] = fl;
                k += 1;
            }
        }
    }
    // X coordinates (deltas).
    const xs = try a.alloc(f32, npts);
    defer a.free(xs);
    var xacc: i32 = 0;
    for (0..npts) |p| {
        const fl = flags[p];
        if (fl & X_SHORT != 0) {
            if (o >= g.len) return Error.BadFont;
            const d: i32 = g[o];
            o += 1;
            xacc += if (fl & X_SAME_POS != 0) d else -d;
        } else if (fl & X_SAME_POS == 0) {
            if (o + 2 > g.len) return Error.BadFont;
            xacc += i16be(g, o);
            o += 2;
        }
        xs[p] = @floatFromInt(xacc);
    }
    // Y coordinates (deltas).
    var yacc: i32 = 0;
    for (0..npts) |p| {
        const fl = flags[p];
        if (fl & Y_SHORT != 0) {
            if (o >= g.len) return Error.BadFont;
            const d: i32 = g[o];
            o += 1;
            yacc += if (fl & Y_SAME_POS != 0) d else -d;
        } else if (fl & Y_SAME_POS == 0) {
            if (o + 2 > g.len) return Error.BadFont;
            yacc += i16be(g, o);
            o += 2;
        }
        try out.pts.append(a, .{ .x = xs[p], .y = @floatFromInt(yacc), .on = flags[p] & ON_CURVE != 0 });
    }
}

const ARGS_WORDS: u16 = 0x0001;
const ARGS_XY: u16 = 0x0002;
const MORE_COMPONENTS: u16 = 0x0020;

fn decodeComposite(f: *const Font, a: std.mem.Allocator, g: []const u8, out: *Outline, depth: u8) Error!void {
    var o: usize = 10;
    while (true) {
        if (o + 4 > g.len) return Error.BadFont;
        const flags = u16be(g, o);
        const cgid = u16be(g, o + 2);
        o += 4;
        var dx: f32 = 0;
        var dy: f32 = 0;
        if (flags & ARGS_WORDS != 0) {
            if (o + 4 > g.len) return Error.BadFont;
            if (flags & ARGS_XY != 0) {
                dx = @floatFromInt(i16be(g, o));
                dy = @floatFromInt(i16be(g, o + 2));
            }
            o += 4;
        } else {
            if (o + 2 > g.len) return Error.BadFont;
            if (flags & ARGS_XY != 0) {
                dx = @floatFromInt(@as(i8, @bitCast(g[o])));
                dy = @floatFromInt(@as(i8, @bitCast(g[o + 1])));
            }
            o += 2;
        }
        // Skip the transform (scale/2x2) — offset placement covers Latin.
        if (flags & 0x0008 != 0) o += 2 // WE_HAVE_A_SCALE
        else if (flags & 0x0040 != 0) o += 4 // X_AND_Y_SCALE
        else if (flags & 0x0080 != 0) o += 8; // 2x2
        const before = out.pts.items.len;
        try decodeOutline(f, a, cgid, out, depth + 1);
        for (out.pts.items[before..]) |*p| {
            p.x += dx;
            p.y += dy;
        }
        if (flags & MORE_COMPONENTS == 0) break;
    }
}

// ------------------------------------------------------ CFF outlines

/// Flatten a cubic Bézier into the outline as on-curve points (p0 already
/// present; emit p1 last). Font units, y-up — same space as glyf points,
/// so the shared rasterizer walk below treats every point as on-curve.
fn flattenCubic(a: std.mem.Allocator, out: *Outline, p0: [2]f32, c0: [2]f32, c1: [2]f32, p1: [2]f32) Error!void {
    const n = 8;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / n;
        const mt = 1 - t;
        const x = mt * mt * mt * p0[0] + 3 * mt * mt * t * c0[0] + 3 * mt * t * t * c1[0] + t * t * t * p1[0];
        const y = mt * mt * mt * p0[1] + 3 * mt * mt * t * c0[1] + 3 * mt * t * t * c1[1] + t * t * t * p1[1];
        try out.pts.append(a, .{ .x = x, .y = y, .on = true });
    }
}

/// A running Type2 charstring interpretation: the current point, the
/// operand stack, hint-count (for hintmask sizing), width/contour state,
/// and the outline being built (all-on-curve points, closed by contour).
const CffState = struct {
    f: *const Font,
    a: std.mem.Allocator,
    out: *Outline,
    x: f32 = 0,
    y: f32 = 0,
    stack: [48]f32 = undefined,
    sp: usize = 0,
    nstems: u32 = 0,
    width_parsed: bool = false,
    open: bool = false,
    done: bool = false,

    fn push(st: *CffState, v: f32) void {
        if (st.sp < st.stack.len) {
            st.stack[st.sp] = v;
            st.sp += 1;
        }
    }
    fn closeContour(st: *CffState) Error!void {
        if (st.open) {
            try st.out.ends.append(st.a, st.out.pts.items.len);
            st.open = false;
        }
    }
    fn moveTo(st: *CffState, nx: f32, ny: f32) Error!void {
        try st.closeContour();
        st.x = nx;
        st.y = ny;
        try st.out.pts.append(st.a, .{ .x = nx, .y = ny, .on = true });
        st.open = true;
    }
    fn lineTo(st: *CffState, nx: f32, ny: f32) Error!void {
        st.x = nx;
        st.y = ny;
        try st.out.pts.append(st.a, .{ .x = nx, .y = ny, .on = true });
    }
    fn curveTo(st: *CffState, c0x: f32, c0y: f32, c1x: f32, c1y: f32, nx: f32, ny: f32) Error!void {
        try flattenCubic(st.a, st.out, .{ st.x, st.y }, .{ c0x, c0y }, .{ c1x, c1y }, .{ nx, ny });
        st.x = nx;
        st.y = ny;
    }
    /// hstem/vstem/hintmask: count stems (pairs), consuming a leading width
    /// operand the first time the stack is cleared.
    fn countStems(st: *CffState) void {
        var n = st.sp;
        if (!st.width_parsed and (n & 1) == 1) n -= 1; // leading width
        st.width_parsed = true;
        st.nstems += @intCast(n / 2);
        st.sp = 0;
    }
};

fn cffBias(n: u32) i32 {
    if (n < 1240) return 107;
    if (n < 33900) return 1131;
    return 32768;
}

/// Decode CFF glyph `gid` into an all-on-curve outline (cubics flattened),
/// then the shared rasterizer path fills it exactly like a glyf outline.
fn decodeCffOutline(f: *const Font, a: std.mem.Allocator, gid: u16, out: *Outline) Error!void {
    var st = CffState{ .f = f, .a = a, .out = out };
    const cs = f.cff_charstrings.item(gid);
    if (cs.len == 0) return; // empty glyph
    try execCharstring(&st, cs, 0);
    try st.closeContour();
}

fn execCharstring(st: *CffState, code: []const u8, depth: u8) Error!void {
    if (depth > 10) return Error.BadFont;
    var i: usize = 0;
    while (i < code.len and !st.done) {
        const b0 = code[i];
        if (b0 >= 32 or b0 == 28) {
            // An operand (number).
            if (b0 == 28) {
                if (i + 3 > code.len) return Error.BadFont;
                st.push(@floatFromInt(i16be(code, i + 1)));
                i += 3;
            } else if (b0 < 247) {
                st.push(@floatFromInt(@as(i32, b0) - 139));
                i += 1;
            } else if (b0 < 251) {
                if (i + 2 > code.len) return Error.BadFont;
                st.push(@floatFromInt((@as(i32, b0) - 247) * 256 + @as(i32, code[i + 1]) + 108));
                i += 2;
            } else if (b0 < 255) {
                if (i + 2 > code.len) return Error.BadFont;
                st.push(@floatFromInt(-(@as(i32, b0) - 251) * 256 - @as(i32, code[i + 1]) - 108));
                i += 2;
            } else {
                // 255: 16.16 fixed.
                if (i + 5 > code.len) return Error.BadFont;
                const raw: i32 = @bitCast(u32be(code, i + 1));
                st.push(@as(f32, @floatFromInt(raw)) / 65536.0);
                i += 5;
            }
            continue;
        }
        // An operator.
        i += 1;
        switch (b0) {
            1, 3, 18, 23 => st.countStems(), // hstem/vstem/hstemhm/vstemhm
            19, 20 => { // hintmask, cntrmask
                st.countStems();
                i += (st.nstems + 7) / 8; // skip the mask bytes
            },
            21 => { // rmoveto
                var k: usize = 0;
                if (!st.width_parsed and st.sp > 2) k = 1;
                st.width_parsed = true;
                if (st.sp >= k + 2) try st.moveTo(st.x + st.stack[k], st.y + st.stack[k + 1]);
                st.sp = 0;
            },
            22 => { // hmoveto
                var k: usize = 0;
                if (!st.width_parsed and st.sp > 1) k = 1;
                st.width_parsed = true;
                if (st.sp >= k + 1) try st.moveTo(st.x + st.stack[k], st.y);
                st.sp = 0;
            },
            4 => { // vmoveto
                var k: usize = 0;
                if (!st.width_parsed and st.sp > 1) k = 1;
                st.width_parsed = true;
                if (st.sp >= k + 1) try st.moveTo(st.x, st.y + st.stack[k]);
                st.sp = 0;
            },
            5 => { // rlineto
                var k: usize = 0;
                while (k + 2 <= st.sp) : (k += 2) try st.lineTo(st.x + st.stack[k], st.y + st.stack[k + 1]);
                st.sp = 0;
            },
            6, 7 => { // hlineto / vlineto (alternating)
                var k: usize = 0;
                var horiz = b0 == 6;
                while (k < st.sp) : (k += 1) {
                    if (horiz) try st.lineTo(st.x + st.stack[k], st.y) else try st.lineTo(st.x, st.y + st.stack[k]);
                    horiz = !horiz;
                }
                st.sp = 0;
            },
            8 => { // rrcurveto
                var k: usize = 0;
                while (k + 6 <= st.sp) : (k += 6) {
                    const c0x = st.x + st.stack[k];
                    const c0y = st.y + st.stack[k + 1];
                    const c1x = c0x + st.stack[k + 2];
                    const c1y = c0y + st.stack[k + 3];
                    try st.curveTo(c0x, c0y, c1x, c1y, c1x + st.stack[k + 4], c1y + st.stack[k + 5]);
                }
                st.sp = 0;
            },
            24 => { // rcurveline: curves then a final line
                var k: usize = 0;
                while (k + 8 <= st.sp) : (k += 6) {
                    const c0x = st.x + st.stack[k];
                    const c0y = st.y + st.stack[k + 1];
                    const c1x = c0x + st.stack[k + 2];
                    const c1y = c0y + st.stack[k + 3];
                    try st.curveTo(c0x, c0y, c1x, c1y, c1x + st.stack[k + 4], c1y + st.stack[k + 5]);
                }
                if (k + 2 <= st.sp) try st.lineTo(st.x + st.stack[k], st.y + st.stack[k + 1]);
                st.sp = 0;
            },
            25 => { // rlinecurve: lines then a final curve
                var k: usize = 0;
                while (k + 8 <= st.sp) : (k += 2) try st.lineTo(st.x + st.stack[k], st.y + st.stack[k + 1]);
                if (k + 6 <= st.sp) {
                    const c0x = st.x + st.stack[k];
                    const c0y = st.y + st.stack[k + 1];
                    const c1x = c0x + st.stack[k + 2];
                    const c1y = c0y + st.stack[k + 3];
                    try st.curveTo(c0x, c0y, c1x, c1y, c1x + st.stack[k + 4], c1y + st.stack[k + 5]);
                }
                st.sp = 0;
            },
            26 => { // vvcurveto
                var k: usize = 0;
                var dx1: f32 = 0;
                if ((st.sp & 3) == 1) {
                    dx1 = st.stack[0];
                    k = 1;
                }
                while (k + 4 <= st.sp) : (k += 4) {
                    const c0x = st.x + dx1;
                    const c0y = st.y + st.stack[k];
                    const c1x = c0x + st.stack[k + 1];
                    const c1y = c0y + st.stack[k + 2];
                    try st.curveTo(c0x, c0y, c1x, c1y, c1x, c1y + st.stack[k + 3]);
                    dx1 = 0;
                }
                st.sp = 0;
            },
            27 => { // hhcurveto
                var k: usize = 0;
                var dy1: f32 = 0;
                if ((st.sp & 3) == 1) {
                    dy1 = st.stack[0];
                    k = 1;
                }
                while (k + 4 <= st.sp) : (k += 4) {
                    const c0x = st.x + st.stack[k];
                    const c0y = st.y + dy1;
                    const c1x = c0x + st.stack[k + 1];
                    const c1y = c0y + st.stack[k + 2];
                    try st.curveTo(c0x, c0y, c1x, c1y, c1x + st.stack[k + 3], c1y);
                    dy1 = 0;
                }
                st.sp = 0;
            },
            30, 31 => { // vhcurveto / hvcurveto (alternating tangents)
                var k: usize = 0;
                var horiz = b0 == 31;
                while (st.sp - k >= 4) {
                    const last = (st.sp - k == 5);
                    if (horiz) {
                        const c0x = st.x + st.stack[k];
                        const c0y = st.y;
                        const c1x = c0x + st.stack[k + 1];
                        const c1y = c0y + st.stack[k + 2];
                        const py = c1y + st.stack[k + 3];
                        const px = if (last) c1x + st.stack[k + 4] else c1x;
                        try st.curveTo(c0x, c0y, c1x, c1y, px, py);
                    } else {
                        const c0x = st.x;
                        const c0y = st.y + st.stack[k];
                        const c1x = c0x + st.stack[k + 1];
                        const c1y = c0y + st.stack[k + 2];
                        const px = c1x + st.stack[k + 3];
                        const py = if (last) c1y + st.stack[k + 4] else c1y;
                        try st.curveTo(c0x, c0y, c1x, c1y, px, py);
                    }
                    k += 4;
                    horiz = !horiz;
                }
                st.sp = 0;
            },
            10 => { // callsubr (local)
                if (st.sp == 0) return Error.BadFont;
                st.sp -= 1;
                const idx = @as(i32, @intFromFloat(st.stack[st.sp])) + cffBias(st.f.cff_lsubrs.count);
                if (idx < 0 or idx >= st.f.cff_lsubrs.count) return Error.BadFont;
                try execCharstring(st, st.f.cff_lsubrs.item(@intCast(idx)), depth + 1);
            },
            29 => { // callgsubr (global)
                if (st.sp == 0) return Error.BadFont;
                st.sp -= 1;
                const idx = @as(i32, @intFromFloat(st.stack[st.sp])) + cffBias(st.f.cff_gsubrs.count);
                if (idx < 0 or idx >= st.f.cff_gsubrs.count) return Error.BadFont;
                try execCharstring(st, st.f.cff_gsubrs.item(@intCast(idx)), depth + 1);
            },
            11 => return, // return from subr
            14 => { // endchar
                if (!st.width_parsed and (st.sp == 1 or st.sp == 5)) {
                    // A leading width operand (4 trailing args = deprecated seac).
                }
                st.width_parsed = true;
                st.done = true;
                return;
            },
            12 => { // two-byte flex operators
                if (i >= code.len) return Error.BadFont;
                const b1 = code[i];
                i += 1;
                try execFlex(st, b1);
                st.sp = 0;
            },
            else => st.sp = 0, // unknown/ignored operator: drop its operands
        }
    }
}

/// The four flex operators (12 34..37): two joined cubics, expressed with
/// various implicit zero coordinates. All resolve to two `curveTo`s.
fn execFlex(st: *CffState, sub: u8) Error!void {
    const s = &st.stack;
    switch (sub) {
        34 => { // hflex: 7 args, flat ends
            if (st.sp < 7) return;
            const c0x = st.x + s[0];
            const c0y = st.y;
            const c1x = c0x + s[1];
            const c1y = c0y + s[2];
            const jx = c1x + s[3];
            const jy = c1y;
            try st.curveTo(c0x, c0y, c1x, c1y, jx, jy);
            const d0x = jx + s[4];
            const d0y = jy;
            const d1x = d0x + s[5];
            const d1y = st.y; // back to the original y
            try st.curveTo(d0x, d0y, d1x, d1y, d1x + s[6], st.y);
        },
        35 => { // flex: 13 args (last is fd, ignored)
            if (st.sp < 13) return;
            const c0x = st.x + s[0];
            const c0y = st.y + s[1];
            const c1x = c0x + s[2];
            const c1y = c0y + s[3];
            const jx = c1x + s[4];
            const jy = c1y + s[5];
            try st.curveTo(c0x, c0y, c1x, c1y, jx, jy);
            const d0x = jx + s[6];
            const d0y = jy + s[7];
            const d1x = d0x + s[8];
            const d1y = d0y + s[9];
            try st.curveTo(d0x, d0y, d1x, d1y, d1x + s[10], d1y + s[11]);
        },
        36 => { // hflex1: 9 args, flat ends in y
            if (st.sp < 9) return;
            const start_y = st.y;
            const c0x = st.x + s[0];
            const c0y = st.y + s[1];
            const c1x = c0x + s[2];
            const c1y = c0y + s[3];
            const jx = c1x + s[4];
            const jy = c1y;
            try st.curveTo(c0x, c0y, c1x, c1y, jx, jy);
            const d0x = jx + s[5];
            const d0y = jy;
            const d1x = d0x + s[6];
            const d1y = d0y + s[7];
            try st.curveTo(d0x, d0y, d1x, d1y, d1x + s[8], start_y);
        },
        37 => { // flex1: 11 args, last coord returns to start
            if (st.sp < 11) return;
            const start_x = st.x;
            const start_y = st.y;
            const c0x = st.x + s[0];
            const c0y = st.y + s[1];
            const c1x = c0x + s[2];
            const c1y = c0y + s[3];
            const jx = c1x + s[4];
            const jy = c1y + s[5];
            try st.curveTo(c0x, c0y, c1x, c1y, jx, jy);
            const d0x = jx + s[6];
            const d0y = jy + s[7];
            const d1x = d0x + s[8];
            const d1y = d0y + s[9];
            const sum_dx = s[0] + s[2] + s[4] + s[6] + s[8];
            const sum_dy = s[1] + s[3] + s[5] + s[7] + s[9];
            if (@abs(sum_dx) > @abs(sum_dy)) {
                try st.curveTo(d0x, d0y, d1x, d1y, d1x + s[10], start_y);
            } else {
                try st.curveTo(d0x, d0y, d1x, d1y, start_x, d1y + s[10]);
            }
        },
        else => {},
    }
}

// ------------------------------------------------------------ rasterize

/// A rasterized glyph: an 8-bit coverage bitmap (0..255), its size, the
/// offset of its top-left from the pen origin/baseline (`left` right, `top`
/// up), and the advance to the next glyph — all in device pixels.
pub const Glyph = struct {
    w: usize,
    h: usize,
    cov: []u8, // w*h, caller frees
    left: i32, // x of the bitmap's left edge from the pen
    top: i32, // y of the bitmap's top edge above the baseline
    advance: f32,
};

const ss = 4; // supersampling per axis (16 samples/pixel)

/// A flattened edge in pixel space (y grows down), for the scanline fill.
const Edge = struct { x0: f32, y0: f32, x1: f32, y1: f32, dir: i2 };

fn flattenQuad(a: std.mem.Allocator, edges: *std.ArrayList(Edge), p0: [2]f32, pc: [2]f32, p1: [2]f32) Error!void {
    // Fixed subdivision: 8 segments is smooth at UI sizes.
    const n = 8;
    var prev = p0;
    var i: usize = 1;
    while (i <= n) : (i += 1) {
        const t = @as(f32, @floatFromInt(i)) / n;
        const mt = 1 - t;
        const x = mt * mt * p0[0] + 2 * mt * t * pc[0] + t * t * p1[0];
        const y = mt * mt * p0[1] + 2 * mt * t * pc[1] + t * t * p1[1];
        try addEdge(a, edges, prev, .{ x, y });
        prev = .{ x, y };
    }
}

fn addEdge(a: std.mem.Allocator, edges: *std.ArrayList(Edge), p0: [2]f32, p1: [2]f32) Error!void {
    if (p0[1] == p1[1]) return; // horizontal: contributes no crossing
    if (p0[1] < p1[1]) {
        try edges.append(a, .{ .x0 = p0[0], .y0 = p0[1], .x1 = p1[0], .y1 = p1[1], .dir = 1 });
    } else {
        try edges.append(a, .{ .x0 = p1[0], .y0 = p1[1], .x1 = p0[0], .y1 = p0[1], .dir = -1 });
    }
}

/// Rasterize glyph `gid` at `px_size` pixels/em into an anti-aliased
/// coverage bitmap. Caller owns `Glyph.cov` (freed with `a`).
pub fn rasterize(f: *const Font, a: std.mem.Allocator, gid: u16, px_size: f32) Error!Glyph {
    const scale = px_size / @as(f32, @floatFromInt(f.units_per_em));
    var out = Outline{ .pts = .empty, .ends = .empty };
    defer out.deinit(a);
    if (f.is_cff) try decodeCffOutline(f, a, gid, &out) else try decodeOutline(f, a, gid, &out, 0);
    const adv = @as(f32, @floatFromInt(f.advance(gid))) * scale;
    return fillOutline(a, &out, scale, adv);
}

/// Fill an outline whose points are in font-unit space (multiplied by
/// `scale` and y-flipped to device pixels here) into a coverage bitmap.
/// The hinted path (`rasterizeHinted`) passes points already in pixel
/// space with `scale = 1`. Caller owns `Glyph.cov`.
fn fillOutline(a: std.mem.Allocator, out: *const Outline, scale: f32, adv: f32) Error!Glyph {
    if (out.pts.items.len == 0 or out.ends.items.len == 0) {
        return .{ .w = 0, .h = 0, .cov = &.{}, .left = 0, .top = 0, .advance = adv };
    }

    // Contour points → pixel space (y down), tracking the bbox.
    var minx: f32 = 1e9;
    var miny: f32 = 1e9;
    var maxx: f32 = -1e9;
    var maxy: f32 = -1e9;
    for (out.pts.items) |p| {
        const px = p.x * scale;
        const py = -p.y * scale; // flip: font y-up → device y-down
        minx = @min(minx, px);
        miny = @min(miny, py);
        maxx = @max(maxx, px);
        maxy = @max(maxy, py);
    }
    const left: i32 = @intFromFloat(@floor(minx));
    const top: i32 = @intFromFloat(@floor(miny));
    const w: usize = @intCast(@as(i32, @intFromFloat(@ceil(maxx))) - left + 1);
    const h: usize = @intCast(@as(i32, @intFromFloat(@ceil(maxy))) - top + 1);
    if (w == 0 or h == 0 or w > 4096 or h > 4096) return Error.BadFont;

    // Build edges (flattened, in bitmap-local pixel space).
    var edges: std.ArrayList(Edge) = .empty;
    defer edges.deinit(a);
    const ox: f32 = @floatFromInt(left);
    const oy: f32 = @floatFromInt(top);
    var start: usize = 0;
    for (out.ends.items) |end| {
        const cpts = out.pts.items[start..end];
        start = end;
        if (cpts.len < 2) continue;
        // Walk the contour, synthesising implied on-curve midpoints between
        // consecutive off-curve points, and emitting line/quad edges.
        var prev = ptPix(cpts[cpts.len - 1], scale, ox, oy);
        // Ensure we begin on an on-curve point.
        const cur = anchorOn(cpts, scale, ox, oy);
        prev = cur.start;
        var idx = cur.idx;
        var count: usize = 0;
        while (count < cpts.len) : (count += 1) {
            const p = cpts[(idx + 1) % cpts.len];
            idx += 1;
            const pp = ptPix(p, scale, ox, oy);
            if (p.on) {
                try addEdge(a, &edges, prev, pp);
                prev = pp;
            } else {
                // Off-curve control: the segment end is the next on-curve
                // point, or the implied midpoint if the next is also off.
                const np = cpts[(idx + 1) % cpts.len];
                const npp = ptPix(np, scale, ox, oy);
                const endp = if (np.on) npp else [2]f32{ (pp[0] + npp[0]) / 2, (pp[1] + npp[1]) / 2 };
                try flattenQuad(a, &edges, prev, pp, endp);
                prev = endp;
                if (np.on) {
                    idx += 1;
                    count += 1;
                }
            }
        }
    }

    const cov = try a.alloc(u8, w * h);
    @memset(cov, 0);
    // Supersampled scanline fill, non-zero winding.
    const acc = try a.alloc(u16, w); // subsample hits per pixel column, per row
    defer a.free(acc);
    var xw: std.ArrayList(Xw) = .empty;
    defer xw.deinit(a);
    var row: usize = 0;
    while (row < h) : (row += 1) {
        @memset(acc, 0);
        var sub: usize = 0;
        while (sub < ss) : (sub += 1) {
            const sy = @as(f32, @floatFromInt(row)) + (@as(f32, @floatFromInt(sub)) + 0.5) / ss;
            xw.clearRetainingCapacity();
            for (edges.items) |e| {
                if (sy < e.y0 or sy >= e.y1) continue;
                const t = (sy - e.y0) / (e.y1 - e.y0);
                try xw.append(a, .{ .x = e.x0 + t * (e.x1 - e.x0), .dir = e.dir });
            }
            std.mem.sort(Xw, xw.items, {}, xwLess);
            var wind: i32 = 0;
            var j: usize = 0;
            while (j < xw.items.len) : (j += 1) {
                const before = wind;
                wind += xw.items[j].dir;
                if (before == 0 and wind != 0) {
                    // span opens at xw[j].x; find where winding returns to 0.
                    const span_x0 = xw.items[j].x;
                    var k = j + 1;
                    var wnd = wind;
                    while (k < xw.items.len and wnd != 0) : (k += 1) wnd += xw.items[k].dir;
                    if (k > j) {
                        const span_x1 = xw.items[k - 1].x;
                        coverSpan(acc, w, span_x0, span_x1);
                        j = k - 1;
                        wind = 0;
                    }
                }
            }
        }
        for (0..w) |c| {
            const v = @as(u32, acc[c]) * 255 / (ss * ss);
            cov[row * w + c] = @intCast(@min(v, 255));
        }
    }

    return .{ .w = w, .h = h, .cov = cov, .left = left, .top = top, .advance = adv };
}

/// A simple glyph loaded for hinting: its points in font units (y-up),
/// per-point on-curve flags, per-contour end indices (inclusive), its own
/// instruction stream, and its bbox. Composite glyphs are not hinted here
/// (the caller falls back). All slices are owned by `a`.
const HintGlyph = struct {
    xs: []i32,
    ys: []i32,
    on: []bool,
    ends: []u16,
    instr: []const u8,
    xmin: i16,
    ymin: i16,
    xmax: i16,
    ymax: i16,
    fn deinit(hg: *HintGlyph, a: std.mem.Allocator) void {
        a.free(hg.xs);
        a.free(hg.ys);
        a.free(hg.on);
        a.free(hg.ends);
    }
};

fn loadGlyphForHint(f: *const Font, a: std.mem.Allocator, gid: u16) Error!HintGlyph {
    const r = f.glyfRange(gid) orelse return Error.Hint; // empty: nothing to hint
    const g = f.glyf[r.start..r.end];
    if (g.len < 10) return Error.Hint;
    const ncont = i16be(g, 0);
    if (ncont <= 0) return Error.Hint; // composite (or empty): fall back
    const nc: usize = @intCast(ncont);
    var o: usize = 10;
    if (o + nc * 2 > g.len) return Error.Hint;
    const ends = try a.alloc(u16, nc);
    errdefer a.free(ends);
    var ci: usize = 0;
    while (ci < nc) : (ci += 1) {
        ends[ci] = u16be(g, o);
        o += 2;
    }
    const npts: usize = @as(usize, ends[nc - 1]) + 1;
    if (o + 2 > g.len) return Error.Hint;
    const ilen = u16be(g, o);
    o += 2;
    if (o + ilen > g.len) return Error.Hint;
    const instr = g[o .. o + ilen];
    o += ilen;
    // Flags (run-length encoded).
    const flags = try a.alloc(u8, npts);
    defer a.free(flags);
    var k: usize = 0;
    while (k < npts) {
        if (o >= g.len) return Error.Hint;
        const fl = g[o];
        o += 1;
        flags[k] = fl;
        k += 1;
        if (fl & REPEAT != 0) {
            if (o >= g.len) return Error.Hint;
            var rep = g[o];
            o += 1;
            while (rep > 0 and k < npts) : (rep -= 1) {
                flags[k] = fl;
                k += 1;
            }
        }
    }
    const xs = try a.alloc(i32, npts);
    errdefer a.free(xs);
    const ys = try a.alloc(i32, npts);
    errdefer a.free(ys);
    const on = try a.alloc(bool, npts);
    errdefer a.free(on);
    var xacc: i32 = 0;
    for (0..npts) |p| {
        const fl = flags[p];
        if (fl & X_SHORT != 0) {
            if (o >= g.len) return Error.Hint;
            const d: i32 = g[o];
            o += 1;
            xacc += if (fl & X_SAME_POS != 0) d else -d;
        } else if (fl & X_SAME_POS == 0) {
            if (o + 2 > g.len) return Error.Hint;
            xacc += i16be(g, o);
            o += 2;
        }
        xs[p] = xacc;
        on[p] = fl & ON_CURVE != 0;
    }
    var yacc: i32 = 0;
    for (0..npts) |p| {
        const fl = flags[p];
        if (fl & Y_SHORT != 0) {
            if (o >= g.len) return Error.Hint;
            const d: i32 = g[o];
            o += 1;
            yacc += if (fl & Y_SAME_POS != 0) d else -d;
        } else if (fl & Y_SAME_POS == 0) {
            if (o + 2 > g.len) return Error.Hint;
            yacc += i16be(g, o);
            o += 2;
        }
        ys[p] = yacc;
    }
    return .{
        .xs = xs,
        .ys = ys,
        .on = on,
        .ends = ends,
        .instr = instr,
        .xmin = i16be(g, 2),
        .ymin = i16be(g, 4),
        .xmax = i16be(g, 6),
        .ymax = i16be(g, 8),
    };
}

/// Rasterize glyph `gid` with the font's own TrueType hints applied at the
/// hinter's ppem — the outline is grid-fitted so stems land on whole
/// pixels. Simple glyphs only; returns `error.Hint` for anything the
/// hinter cannot handle, and the caller keeps the unhinted `rasterize`.
pub fn rasterizeHinted(f: *const Font, a: std.mem.Allocator, hinter: *tthint.Hinter, gid: u16, px_size: f32) Error!Glyph {
    if (f.is_cff) return Error.Hint;
    var hg = try loadGlyphForHint(f, a, gid);
    defer hg.deinit(a);
    const npts = hg.xs.len;
    const nz = npts + 4; // four phantom points

    const org = try a.alloc([2]tthint.F26Dot6, nz);
    defer a.free(org);
    const cur = try a.alloc([2]tthint.F26Dot6, nz);
    defer a.free(cur);
    const zflags = try a.alloc(u8, nz);
    defer a.free(zflags);

    for (0..npts) |p| {
        org[p] = .{ hinter.scaleFUnit(hg.xs[p]), hinter.scaleFUnit(hg.ys[p]) };
        cur[p] = org[p];
        zflags[p] = if (hg.on[p]) tthint.flag_on else 0;
    }
    // Phantom points (font units → 26.6): the horizontal pair carries the
    // side bearing and advance, the vertical pair the top/bottom.
    const lsb = f.leftBearing(gid);
    const advw: i32 = f.advance(gid);
    const pp1x: i32 = @as(i32, hg.xmin) - lsb;
    const phantom = [4][2]i32{
        .{ pp1x, 0 },
        .{ pp1x + advw, 0 },
        .{ 0, hg.ymax },
        .{ 0, hg.ymin },
    };
    for (0..4) |i| {
        org[npts + i] = .{ hinter.scaleFUnit(phantom[i][0]), hinter.scaleFUnit(phantom[i][1]) };
        cur[npts + i] = org[npts + i];
        zflags[npts + i] = 0;
    }

    const zone = tthint.Zone{
        .n = nz,
        .org = org,
        .cur = cur,
        .flags = zflags,
        .ends = hg.ends,
        .n_contours = hg.ends.len,
    };
    try hinter.hintGlyph(zone, hg.instr);

    // Fitted points (26.6, y-up) → float pixel outline; fillOutline flips
    // y and scales by 1 (they are already in pixels).
    var out = Outline{ .pts = .empty, .ends = .empty };
    defer out.deinit(a);
    for (0..npts) |p| {
        try out.pts.append(a, .{
            .x = @as(f32, @floatFromInt(cur[p][0])) / 64.0,
            .y = @as(f32, @floatFromInt(cur[p][1])) / 64.0,
            .on = zflags[p] & tthint.flag_on != 0,
        });
    }
    for (hg.ends) |e| try out.ends.append(a, @as(usize, e) + 1); // exclusive
    const scale = px_size / @as(f32, @floatFromInt(f.units_per_em));
    const adv = @as(f32, @floatFromInt(advw)) * scale; // keep the linear advance
    return fillOutline(a, &out, 1.0, adv);
}

const Xw = struct { x: f32, dir: i2 };
fn xwLess(_: void, a: Xw, b: Xw) bool {
    return a.x < b.x;
}

fn ptPix(p: Point, scale: f32, ox: f32, oy: f32) [2]f32 {
    return .{ p.x * scale - ox, -p.y * scale - oy };
}

/// Find an on-curve start point for a contour (synthesising one between
/// the first two off-curve points if the contour starts off-curve).
fn anchorOn(cpts: []const Point, scale: f32, ox: f32, oy: f32) struct { start: [2]f32, idx: usize } {
    for (cpts, 0..) |p, i| {
        if (p.on) return .{ .start = ptPix(p, scale, ox, oy), .idx = i };
    }
    // All off-curve: start at the midpoint of the last and first.
    const a0 = ptPix(cpts[cpts.len - 1], scale, ox, oy);
    const a1 = ptPix(cpts[0], scale, ox, oy);
    return .{ .start = .{ (a0[0] + a1[0]) / 2, (a0[1] + a1[1]) / 2 }, .idx = cpts.len - 1 };
}

/// Add one subsample row's coverage for the span [x0, x1] into `acc`
/// (per-column subsample hit counts, with fractional edge coverage).
fn coverSpan(acc: []u16, w: usize, x0: f32, x1: f32) void {
    if (x1 <= 0 or x0 >= @as(f32, @floatFromInt(w))) return;
    const a = @max(x0, 0);
    const b = @min(x1, @as(f32, @floatFromInt(w)));
    if (b <= a) return;
    var c: usize = @intFromFloat(@floor(a));
    const last: usize = @intFromFloat(@ceil(b) - 1);
    while (c <= last and c < w) : (c += 1) {
        const cl = @as(f32, @floatFromInt(c));
        const cover = @min(b, cl + 1) - @max(a, cl); // 0..1 fraction of this column covered
        acc[c] += @intFromFloat(cover * ss + 0.5); // scaled to subsamples-per-axis
    }
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

fn beU16(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u16) !void {
    try l.append(a, @intCast(v >> 8));
    try l.append(a, @intCast(v & 0xff));
}
fn beU32(l: *std.ArrayList(u8), a: std.mem.Allocator, v: u32) !void {
    try l.append(a, @intCast((v >> 24) & 0xff));
    try l.append(a, @intCast((v >> 16) & 0xff));
    try l.append(a, @intCast((v >> 8) & 0xff));
    try l.append(a, @intCast(v & 0xff));
}
fn beI16(l: *std.ArrayList(u8), a: std.mem.Allocator, v: i16) !void {
    try beU16(l, a, @bitCast(v));
}

const TestTable = struct { tag: u32, bytes: []const u8 };

fn assembleSfnt(a: std.mem.Allocator, tables: []const TestTable) ![]u8 {
    var out: std.ArrayList(u8) = .empty;
    const n: u16 = @intCast(tables.len);
    try beU32(&out, a, 0x00010000);
    try beU16(&out, a, n);
    try beU16(&out, a, 0);
    try beU16(&out, a, 0);
    try beU16(&out, a, 0);
    var off: u32 = 12 + @as(u32, n) * 16;
    for (tables) |t| {
        try beU32(&out, a, t.tag);
        try beU32(&out, a, 0); // checksum (ignored by the parser)
        try beU32(&out, a, off);
        try beU32(&out, a, @intCast(t.bytes.len));
        off += @intCast((t.bytes.len + 3) & ~@as(usize, 3)); // 4-byte aligned
    }
    for (tables) |t| {
        try out.appendSlice(a, t.bytes);
        while (out.items.len % 4 != 0) try out.append(a, 0);
    }
    return out.toOwnedSlice(a);
}

fn buildTestFont(a: std.mem.Allocator) ![]u8 {
    // glyf: glyph 1 is a 100..500 square (glyph 0 is empty / .notdef).
    var glyf: std.ArrayList(u8) = .empty;
    defer glyf.deinit(a);
    try beI16(&glyf, a, 1); // numberOfContours
    try beI16(&glyf, a, 100); // xMin
    try beI16(&glyf, a, 100); // yMin
    try beI16(&glyf, a, 500); // xMax
    try beI16(&glyf, a, 500); // yMax
    try beU16(&glyf, a, 3); // endPtsOfContours[0]
    try beU16(&glyf, a, 0); // instructionLength
    for (0..4) |_| try glyf.append(a, ON_CURVE); // flags
    for ([_]i16{ 100, 400, 0, -400 }) |d| try beI16(&glyf, a, d); // x deltas
    for ([_]i16{ 100, 0, 400, 0 }) |d| try beI16(&glyf, a, d); // y deltas

    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(a);
    try head.appendNTimes(a, 0, 54);
    head.items[18] = 0x03;
    head.items[19] = 0xE8; // unitsPerEm = 1000
    // indexToLocFormat at [50] = 0 (short) already zero.

    var maxp: std.ArrayList(u8) = .empty;
    defer maxp.deinit(a);
    try beU32(&maxp, a, 0x00010000);
    try beU16(&maxp, a, 2); // numGlyphs

    var hhea: std.ArrayList(u8) = .empty;
    defer hhea.deinit(a);
    try hhea.appendNTimes(a, 0, 36);
    hhea.items[4] = 0x03;
    hhea.items[5] = 0x20; // ascent 800
    hhea.items[34] = 0x00;
    hhea.items[35] = 0x02; // numberOfHMetrics = 2

    var hmtx: std.ArrayList(u8) = .empty;
    defer hmtx.deinit(a);
    try beU16(&hmtx, a, 600); // glyph0 advance
    try beI16(&hmtx, a, 0);
    try beU16(&hmtx, a, 600); // glyph1 advance
    try beI16(&hmtx, a, 100);

    var loca: std.ArrayList(u8) = .empty;
    defer loca.deinit(a);
    try beU16(&loca, a, 0); // glyph0 start
    try beU16(&loca, a, 0); // glyph0 end / glyph1 start
    try beU16(&loca, a, @intCast(glyf.items.len / 2)); // glyph1 end

    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(a);
    try beU16(&cmap, a, 0); // version
    try beU16(&cmap, a, 1); // numTables
    try beU16(&cmap, a, 3); // platformID
    try beU16(&cmap, a, 1); // encodingID
    try beU32(&cmap, a, 12); // subtable offset
    // format 4 (maps 'A' → 1)
    try beU16(&cmap, a, 4); // format
    try beU16(&cmap, a, 32); // length
    try beU16(&cmap, a, 0); // language
    try beU16(&cmap, a, 4); // segCountX2
    try beU16(&cmap, a, 0); // searchRange
    try beU16(&cmap, a, 0); // entrySelector
    try beU16(&cmap, a, 0); // rangeShift
    try beU16(&cmap, a, 0x41); // endCode[0]
    try beU16(&cmap, a, 0xffff); // endCode[1]
    try beU16(&cmap, a, 0); // reservedPad
    try beU16(&cmap, a, 0x41); // startCode[0]
    try beU16(&cmap, a, 0xffff); // startCode[1]
    try beU16(&cmap, a, 0xFFC0); // idDelta[0] = -64 → 0x41 maps to 1
    try beU16(&cmap, a, 0x0001); // idDelta[1]
    try beU16(&cmap, a, 0); // idRangeOffset[0]
    try beU16(&cmap, a, 0); // idRangeOffset[1]

    var name: std.ArrayList(u8) = .empty;
    defer name.deinit(a);
    try beU16(&name, a, 0); // format
    try beU16(&name, a, 1); // count
    try beU16(&name, a, 18); // stringOffset (6 header + 12 record)
    try beU16(&name, a, 3); // platformID (Windows)
    try beU16(&name, a, 1); // encodingID (UTF-16BE)
    try beU16(&name, a, 0x409); // languageID
    try beU16(&name, a, 1); // nameID (Font Family)
    try beU16(&name, a, 8); // length ("Test" in UTF-16BE)
    try beU16(&name, a, 0); // offset
    for ("Test") |ch| try beU16(&name, a, ch); // UTF-16BE

    return assembleSfnt(a, &.{
        .{ .tag = 0x68656164, .bytes = head.items },
        .{ .tag = 0x6D617870, .bytes = maxp.items },
        .{ .tag = 0x68686561, .bytes = hhea.items },
        .{ .tag = 0x686D7478, .bytes = hmtx.items },
        .{ .tag = 0x6C6F6361, .bytes = loca.items },
        .{ .tag = 0x676C7966, .bytes = glyf.items },
        .{ .tag = 0x636D6170, .bytes = cmap.items },
        .{ .tag = 0x6E616D65, .bytes = name.items },
    });
}

test "parse a minimal TrueType font and read its header + cmap" {
    const a = testing.allocator;
    const data = try buildTestFont(a);
    defer a.free(data);
    var f = try Font.parse(data);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
    try testing.expectEqual(@as(u16, 2), f.num_glyphs);
    try testing.expectEqual(@as(u16, 1), f.glyphIndex('A'));
    try testing.expectEqual(@as(u16, 0), f.glyphIndex('B'));
    try testing.expectEqual(@as(u16, 600), f.advance(1));
    var nb: [64]u8 = undefined;
    try testing.expectEqualStrings("Test", f.familyName(&nb));
}

test "rasterize a glyph to an anti-aliased coverage bitmap" {
    const a = testing.allocator;
    const data = try buildTestFont(a);
    defer a.free(data);
    var f = try Font.parse(data);
    const gid = f.glyphIndex('A');
    const g = try rasterize(&f, a, gid, 100); // scale 0.1 → a 40×40 square
    defer a.free(g.cov);
    try testing.expect(g.w >= 39 and g.w <= 43);
    try testing.expect(g.h >= 39 and g.h <= 43);
    try testing.expectApproxEqAbs(@as(f32, 60), g.advance, 0.5); // 600 * 0.1
    // Deep inside the square is fully covered; well outside the em is not.
    try testing.expect(g.cov[(g.h / 2) * g.w + g.w / 2] > 250);
    // An empty glyph (.notdef, gid 0) rasterizes to nothing but keeps advance.
    const e = try rasterize(&f, a, 0, 100);
    defer a.free(e.cov);
    try testing.expectEqual(@as(usize, 0), e.w);
}

test "zlib decompress (the WOFF table path)" {
    const comp = [_]u8{ 0x78, 0xda, 0xcb, 0xcd, 0x2f, 0x2e, 0x56, 0x48, 0xcb, 0xcf, 0x2b, 0x29, 0xb6, 0x52, 0xa8, 0xca, 0xc9, 0x4c, 0x52, 0x28, 0xca, 0x2f, 0xcd, 0x4b, 0xd1, 0x2d, 0x29, 0xca, 0x2c, 0x00, 0x00, 0x8f, 0xc7, 0x0a, 0x4c };
    var out: [27]u8 = undefined;
    try testing.expect(zlibInto(&comp, &out));
    try testing.expectEqualStrings("moss fonts: zlib round-trip", &out);
}

test "toSfnt returns an SFNT input unchanged" {
    const a = testing.allocator;
    const data = try buildTestFont(a);
    defer a.free(data);
    var scratch: [16]u8 = undefined;
    const sfnt = try toSfnt(a, data, &scratch);
    try testing.expect(sfnt.ptr == data.ptr); // no copy for an SFNT
}

// --- CFF (OpenType/PostScript) ---

/// Assemble a CFF INDEX (count-prefixed variable-length objects).
fn cffIndex(l: *std.ArrayList(u8), a: std.mem.Allocator, items: []const []const u8) !void {
    const count: u16 = @intCast(items.len);
    try beU16(l, a, count);
    if (count == 0) return;
    var total: usize = 0;
    for (items) |it| total += it.len;
    const off_size: u8 = if (total + 1 <= 0xff) 1 else if (total + 1 <= 0xffff) 2 else 4;
    try l.append(a, off_size);
    var acc: usize = 1;
    // The offset array: count+1 entries, 1-based, `off_size` bytes each.
    var e: usize = 0;
    while (e <= count) : (e += 1) {
        if (e > 0) acc += items[e - 1].len;
        var b: usize = off_size;
        while (b > 0) : (b -= 1) try l.append(a, @intCast((acc >> @intCast((b - 1) * 8)) & 0xff));
    }
    for (items) |it| try l.appendSlice(a, it);
}

fn buildCffTestFont(a: std.mem.Allocator) ![]u8 {
    // A CFF table whose glyph 1 is the same 100..500 square as the glyf font,
    // drawn by a Type2 charstring; glyph 0 (.notdef) is empty.
    const cs_notdef = [_]u8{14}; // endchar
    // rmoveto 100 100; rlineto 400 0; rlineto 0 400; rlineto -400 0; endchar.
    // 100 = 239 (b0-139); 400 = 28,0x01,0x90; 0 = 139; -400 = 28,0xFE,0x70.
    const cs_square = [_]u8{
        239, 239, 21, // rmoveto 100 100
        28, 0x01, 0x90, 139, 5, // rlineto 400 0
        139, 28, 0x01, 0x90, 5, // rlineto 0 400
        28, 0xFE, 0x70, 139, 5, // rlineto -400 0
        14, // endchar
    };
    var charstrings: std.ArrayList(u8) = .empty;
    defer charstrings.deinit(a);
    try cffIndex(&charstrings, a, &.{ &cs_notdef, &cs_square });

    var name_index: std.ArrayList(u8) = .empty;
    defer name_index.deinit(a);
    try cffIndex(&name_index, a, &.{"A"});

    // Layout: header(4) name TopDICT-INDEX string(empty,2) gsubr(empty,2) CharStrings.
    // The Top DICT encodes the CharStrings offset with the fixed 5-byte int
    // form (op 29) so the Top DICT INDEX length is known before we place it.
    const top_dict_len = 6; // [29 b1 b2 b3 b4] + [17]
    const top_index_len = 2 + 1 + 2 + top_dict_len; // count,offSize,2 one-byte offsets,data
    const cs_off = 4 + name_index.items.len + top_index_len + 2 + 2;

    var cff: std.ArrayList(u8) = .empty;
    defer cff.deinit(a);
    try cff.appendSlice(a, &.{ 1, 0, 4, 1 }); // header: v1.0, hdrSize 4, offSize 1
    try cff.appendSlice(a, name_index.items);
    // Top DICT INDEX (one entry).
    var top_dict: std.ArrayList(u8) = .empty;
    defer top_dict.deinit(a);
    try top_dict.append(a, 29); // 5-byte integer operand
    try beU32(&top_dict, a, @intCast(cs_off));
    try top_dict.append(a, 17); // CharStrings operator
    try cffIndex(&cff, a, &.{top_dict.items});
    try cffIndex(&cff, a, &.{}); // String INDEX (empty)
    try cffIndex(&cff, a, &.{}); // Global Subr INDEX (empty)
    try testing.expectEqual(cs_off, cff.items.len); // CharStrings land where the DICT says
    try cff.appendSlice(a, charstrings.items);

    // The rest of the SFNT: reuse the minimal tables (no glyf/loca).
    var head: std.ArrayList(u8) = .empty;
    defer head.deinit(a);
    try head.appendNTimes(a, 0, 54);
    head.items[18] = 0x03;
    head.items[19] = 0xE8; // unitsPerEm = 1000

    var maxp: std.ArrayList(u8) = .empty;
    defer maxp.deinit(a);
    try beU32(&maxp, a, 0x00005000); // version 0.5 (CFF)
    try beU16(&maxp, a, 2); // numGlyphs

    var hhea: std.ArrayList(u8) = .empty;
    defer hhea.deinit(a);
    try hhea.appendNTimes(a, 0, 36);
    hhea.items[4] = 0x03;
    hhea.items[5] = 0x20; // ascent 800
    hhea.items[34] = 0x00;
    hhea.items[35] = 0x02; // numberOfHMetrics = 2

    var hmtx: std.ArrayList(u8) = .empty;
    defer hmtx.deinit(a);
    try beU16(&hmtx, a, 600);
    try beI16(&hmtx, a, 0);
    try beU16(&hmtx, a, 600);
    try beI16(&hmtx, a, 100);

    var cmap: std.ArrayList(u8) = .empty;
    defer cmap.deinit(a);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 1);
    try beU16(&cmap, a, 3);
    try beU16(&cmap, a, 1);
    try beU32(&cmap, a, 12);
    try beU16(&cmap, a, 4); // format 4
    try beU16(&cmap, a, 32);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 4);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 0x41);
    try beU16(&cmap, a, 0xffff);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 0x41);
    try beU16(&cmap, a, 0xffff);
    try beU16(&cmap, a, 0xFFC0);
    try beU16(&cmap, a, 0x0001);
    try beU16(&cmap, a, 0);
    try beU16(&cmap, a, 0);

    return assembleSfnt(a, &.{
        .{ .tag = 0x68656164, .bytes = head.items },
        .{ .tag = 0x6D617870, .bytes = maxp.items },
        .{ .tag = 0x68686561, .bytes = hhea.items },
        .{ .tag = 0x686D7478, .bytes = hmtx.items },
        .{ .tag = 0x636D6170, .bytes = cmap.items },
        .{ .tag = 0x43464620, .bytes = cff.items }, // 'CFF '
    });
}

test "parse and rasterize a minimal CFF (Type2 charstring) font" {
    const a = testing.allocator;
    const data = try buildCffTestFont(a);
    defer a.free(data);
    var f = try Font.parse(data);
    try testing.expect(f.is_cff);
    try testing.expectEqual(@as(u16, 1000), f.units_per_em);
    try testing.expectEqual(@as(u16, 2), f.num_glyphs);
    try testing.expectEqual(@as(u32, 2), f.cff_charstrings.count);
    const gid = f.glyphIndex('A');
    try testing.expectEqual(@as(u16, 1), gid);
    // The charstring square rasterizes just like the glyf one: ~40×40, filled.
    const g = try rasterize(&f, a, gid, 100);
    defer a.free(g.cov);
    try testing.expect(g.w >= 39 and g.w <= 43);
    try testing.expect(g.h >= 39 and g.h <= 43);
    try testing.expectApproxEqAbs(@as(f32, 60), g.advance, 0.5);
    try testing.expect(g.cov[(g.h / 2) * g.w + g.w / 2] > 250);
}

test "hinting a real glyph (IBM Plex Mono) is crisper than the unhinted fill" {
    const a = testing.allocator;
    const data = @embedFile("tthint/plexmono.ttf");
    const f = try Font.parse(data);
    try testing.expect(f.hasHints());
    const gid = f.glyphIndex('H'); // a glyph of vertical + horizontal stems
    try testing.expect(gid != 0);

    const lim = f.hintLimits();
    var h = try tthint.Hinter.init(a, f.fpgm, f.prep, f.cvt, f.units_per_em, 16, lim.stack, lim.storage, lim.funcs, lim.twilight);
    defer {
        a.free(h.stack);
        a.free(h.storage);
        a.free(h.cvt);
        a.free(h.funcs);
        a.free(h.twilight.org);
        a.free(h.twilight.cur);
        a.free(h.twilight.flags);
    }

    const hinted = try rasterizeHinted(&f, a, &h, gid, 16);
    defer a.free(hinted.cov);
    const plain = try rasterize(&f, a, gid, 16);
    defer a.free(plain.cov);

    // Crispness metric: hinting snaps stem edges to whole pixels, so fewer
    // pixels are left partially covered (grey anti-aliased edges) relative
    // to solid black. Count the mid-grey pixels in each.
    const grey = struct {
        fn count(g: Glyph) usize {
            var n: usize = 0;
            for (g.cov) |c| if (c > 40 and c < 215) {
                n += 1;
            };
            return n;
        }
    }.count;
    try testing.expect(hinted.w > 0 and hinted.h > 0);
    try testing.expect(grey(hinted) < grey(plain)); // sharper edges
}
