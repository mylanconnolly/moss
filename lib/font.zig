//! font — a from-scratch vector-font rasterizer for moss's system font
//! service. Pure, freestanding-safe, host-tested: no allocator of its own
//! beyond what the caller hands in, no I/O, just bytes in (an SFNT font)
//! and an anti-aliased coverage bitmap out.
//!
//! Every font format moss will support converges here: an SFNT container
//! (a table directory) whose glyph outlines are filled by one rasterizer.
//! This stage parses TrueType (`glyf`, quadratic outlines); OpenType
//! (`CFF ` cubic charstrings), WOFF (zlib) and WOFF2 (Brotli) are additive
//! front-ends — they decompress/transform to the same SFNT this reads.
//!
//! The rasterizer is a supersampled scanline fill with non-zero winding:
//! simple and correct, and a glyph is rasterized once per (glyph, size)
//! and cached by the service, so clarity beats cleverness here.

const std = @import("std");

pub const Error = error{ BadFont, Unsupported, OutOfMemory };

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
    // The chosen Unicode cmap subtable (a slice of `cmap`), and its format.
    cmap_sub: []const u8,
    cmap_fmt: u16,
    ascent: i16,
    descent: i16,

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
            .cmap_sub = &.{},
            .cmap_fmt = 0,
            .ascent = 0,
            .descent = 0,
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
        if (f.glyf.len == 0 or f.loca.len == 0) return Error.Unsupported; // CFF (OTF) is a later front-end
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

    /// The advance width of a glyph, in font units.
    pub fn advance(f: *const Font, gid: u16) u16 {
        if (f.num_hmetrics == 0 or f.hmtx.len < 4) return 0;
        const idx = if (gid < f.num_hmetrics) gid else f.num_hmetrics - 1;
        const o = @as(usize, idx) * 4;
        if (o + 2 > f.hmtx.len) return 0;
        return u16be(f.hmtx, o);
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
};

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
    try decodeOutline(f, a, gid, &out, 0);
    const adv = @as(f32, @floatFromInt(f.advance(gid))) * scale;

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
