//! Text for layout and paint over real faces: `FaceFonts` is the
//! `layout.Fonts` provider the page domain (and the host's `webshot`)
//! set a page in. The system faces come first — sans, then mono, then
//! any fallbacks — and the `@font-face` faces a page fetched are picked
//! by the family names its styles list. A code point the chosen face
//! lacks is looked for in the others in order, so a script the page's
//! face does not cover still reads; one no face has is a box. Invisible
//! format characters (direction marks, joiners, the soft hyphen) take no
//! room and draw nothing. Glyphs are rasterized by `lib/font` into a
//! bounded cache over a buffer the caller owns.
const std = @import("std");
const font = @import("../font.zig");
const ui = @import("../ui.zig");
const layout = @import("layout.zig");

pub const max_system = 6;
pub const max_web = 8;

pub const FaceFonts = struct {
    /// Sans first, mono second, then the fallbacks; null where absent.
    system: [max_system]?font.Font = @splat(null),
    /// `@font-face` faces the page fetched, by the family they declare.
    web: [max_web]WebFace = undefined,
    n_web: usize = 0,
    cache: [512]Entry = undefined,
    cache_len: usize = 0,
    glyph_fba: std.heap.FixedBufferAllocator,
    fixed: layout.FixedFonts = .{},
    /// Called once when a web face first draws a glyph (the browser
    /// drill checks a page's text really is set in what it fetched).
    on_web_face_used: ?*const fn (name: []const u8) void = null,

    pub const WebFace = struct { name: [64]u8, name_len: usize, face: font.Font, used: bool = false };
    const Entry = struct { face: u8, gid: u16, size: u16, glyph: font.Glyph };
    const web_base: u8 = max_system;

    pub fn init(glyph_heap: []u8) FaceFonts {
        return .{ .glyph_fba = std.heap.FixedBufferAllocator.init(glyph_heap) };
    }

    /// A system face at `slot` (0 sans, 1 mono, 2.. fallbacks).
    pub fn setSystem(self: *FaceFonts, slot: usize, face: ?font.Font) void {
        self.system[slot] = face;
        self.dropCache();
    }

    /// Add a fetched face under its family name.
    pub fn addWebFace(self: *FaceFonts, family: []const u8, face: font.Font) bool {
        if (self.n_web == max_web) return false;
        const w = &self.web[self.n_web];
        w.name_len = @min(family.len, w.name.len);
        @memcpy(w.name[0..w.name_len], family[0..w.name_len]);
        w.face = face;
        w.used = false;
        self.n_web += 1;
        return true;
    }

    /// A new page: its web faces go (their bytes went with its arena),
    /// and the glyph cache with them (their indices are reused).
    pub fn forgetWebFaces(self: *FaceFonts) void {
        if (self.n_web == 0) return;
        self.n_web = 0;
        self.dropCache();
    }

    fn dropCache(self: *FaceFonts) void {
        self.cache_len = 0;
        self.glyph_fba.reset();
    }

    pub fn fonts(self: *FaceFonts) layout.Fonts {
        if (self.primary() == null) return self.fixed.fonts();
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: layout.Fonts.VTable = .{ .advance = adv, .metrics = met, .draw = draw };

    fn primary(self: *FaceFonts) ?*const font.Font {
        for (&self.system) |*f| if (f.*) |*face| return face;
        return null;
    }

    fn faceAt(self: *FaceFonts, idx: u8) *const font.Font {
        if (idx >= web_base) return &self.web[idx - web_base].face;
        return &self.system[idx].?;
    }

    /// The face the style asks for: the computed family list, first
    /// choice first — a web face by its declared name wins; the generic
    /// families fall to the system ones.
    fn chosen(self: *FaceFonts, f: layout.Font) u8 {
        for (f.families) |fam| {
            for (self.web[0..self.n_web], 0..) |*w, i| {
                if (std.ascii.eqlIgnoreCase(w.name[0..w.name_len], fam)) return web_base + @as(u8, @intCast(i));
            }
            if (std.ascii.eqlIgnoreCase(fam, "monospace") and self.system[1] != null) return 1;
            if (std.ascii.eqlIgnoreCase(fam, "sans-serif") or std.ascii.eqlIgnoreCase(fam, "serif")) break;
        }
        if (f.monospace and self.system[1] != null) return 1;
        for (self.system, 0..) |s, i| if (s != null) return @intCast(i);
        unreachable; // fonts() hands out this vtable only with a face
    }

    const Pick = struct { idx: u8, gid: u16 };

    /// The face and glyph for one code point: the chosen face's, else
    /// the first system face that has it, else the chosen face's box.
    fn pick(self: *FaceFonts, want: u8, cp: u21) Pick {
        const first = self.faceAt(want).glyphIndex(cp);
        if (first != 0 or cp < 0x80) return .{ .idx = want, .gid = first };
        for (&self.system, 0..) |*s, i| if (s.*) |*face| {
            if (i == want) continue;
            const g = face.glyphIndex(cp);
            if (g != 0) return .{ .idx = @intCast(i), .gid = g };
        };
        return .{ .idx = want, .gid = 0 };
    }

    fn scaleOf(face: *const font.Font, size: f64) f64 {
        return size / @as(f64, @floatFromInt(face.units_per_em));
    }

    fn advanceOf(self: *FaceFonts, p: Pick, size: f64) f64 {
        const face = self.faceAt(p.idx);
        return @as(f64, @floatFromInt(face.advance(p.gid))) * scaleOf(face, size);
    }

    /// Bold without a bold face: every face here is a regular one, so a
    /// weight of 600 or more is synthesized — the glyph drawn again this
    /// many pixels to the right, each advance that much wider.
    fn emboldening(f: layout.Font) f64 {
        if (f.weight < 600) return 0;
        return @max(1, @round(f.size / 20));
    }

    fn adv(ctx: *anyopaque, f: layout.Font, text: []const u8) f64 {
        const self: *FaceFonts = @ptrCast(@alignCast(ctx));
        const want = self.chosen(f);
        const bold = emboldening(f);
        var total: f64 = 0;
        var it = CodePoints{ .s = text };
        while (it.next()) |cp| {
            if (invisible(cp)) continue;
            total += self.advanceOf(self.pick(want, cp), f.size) + bold;
        }
        return total;
    }

    fn met(ctx: *anyopaque, f: layout.Font) layout.FontMetrics {
        const self: *FaceFonts = @ptrCast(@alignCast(ctx));
        const face = self.faceAt(self.chosen(f));
        const scale = scaleOf(face, f.size);
        const asc = @as(f64, @floatFromInt(face.ascent)) * scale;
        const desc = -@as(f64, @floatFromInt(face.descent)) * scale;
        return .{ .ascent = @round(@max(asc, f.size * 0.6)), .descent = @round(@max(desc, f.size * 0.15)) };
    }

    fn glyph(self: *FaceFonts, idx: u8, gid: u16, size: f64) ?*const font.Glyph {
        const size_q: u16 = @intFromFloat(@min(65535, @max(0, size * 4)));
        for (self.cache[0..self.cache_len]) |*e| {
            if (e.face == idx and e.gid == gid and e.size == size_q) return &e.glyph;
        }
        // Full: start over. A page rarely uses this many glyph shapes at
        // once; when it does, the miss is a rasterization.
        if (self.cache_len == self.cache.len) self.dropCache();
        const face = self.faceAt(idx);
        const g = font.rasterize(face, self.glyph_fba.allocator(), gid, @floatCast(size)) catch |e| switch (e) {
            error.OutOfMemory => blk: {
                self.dropCache();
                break :blk font.rasterize(face, self.glyph_fba.allocator(), gid, @floatCast(size)) catch return null;
            },
            else => return null,
        };
        self.cache[self.cache_len] = .{ .face = idx, .gid = gid, .size = size_q, .glyph = g };
        self.cache_len += 1;
        if (idx >= web_base) {
            const w = &self.web[idx - web_base];
            if (!w.used) {
                w.used = true;
                if (self.on_web_face_used) |cb| cb(w.name[0..w.name_len]);
            }
        }
        return &self.cache[self.cache_len - 1].glyph;
    }

    fn draw(ctx: *anyopaque, canvas: *const ui.Canvas, f: layout.Font, x: f64, baseline: f64, text: []const u8, color: u32) void {
        const self: *FaceFonts = @ptrCast(@alignCast(ctx));
        const want = self.chosen(f);
        const bold = emboldening(f);
        const smear: usize = @intFromFloat(bold);
        var pen = x;
        var it = CodePoints{ .s = text };
        while (it.next()) |cp| {
            if (invisible(cp)) continue;
            const p = self.pick(want, cp);
            if (cp != ' ' and cp != 0xa0) if (self.glyph(p.idx, p.gid, f.size)) |g| {
                const gx: i64 = @as(i64, @intFromFloat(@round(pen))) + g.left;
                // `top` is the bitmap's top from the baseline, downward
                // (negative above it), as the toolkit reads it.
                const gy: i64 = @as(i64, @intFromFloat(@round(baseline))) + g.top;
                for (0..g.h) |row| {
                    const y = gy + @as(i64, @intCast(row));
                    if (y < 0) continue;
                    // Emboldened, a pixel takes the most coverage of the
                    // glyph's copies over it (blending each would darken
                    // the edges twice).
                    for (0..g.w + smear) |col| {
                        const xx = gx + @as(i64, @intCast(col));
                        if (xx < 0) continue;
                        var cov: u8 = 0;
                        for (0..smear + 1) |d| {
                            if (col < d or col - d >= g.w) continue;
                            cov = @max(cov, g.cov[row * g.w + col - d]);
                        }
                        canvas.blend(@intCast(xx), @intCast(y), color, cov);
                    }
                }
            };
            pen += self.advanceOf(p, f.size) + bold;
        }
    }
};

/// Unicode's default-ignorable format characters a page's text carries
/// for bidi and line breaking: they have no glyph and no width.
pub fn invisible(cp: u21) bool {
    return switch (cp) {
        0xad, 0x34f, 0x61c, 0x115f, 0x1160, 0x17b4, 0x17b5, 0x180b...0x180f, 0x200b...0x200f, 0x202a...0x202e, 0x2060...0x206f, 0x3164, 0xfe00...0xfe0f, 0xfeff, 0xffa0, 0xfff0...0xfff8, 0xe0000...0xe0fff => true,
        else => false,
    };
}

const CodePoints = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *CodePoints) ?u21 {
        if (it.i >= it.s.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch {
            it.i += 1;
            return 0xfffd;
        };
        if (it.i + len > it.s.len) {
            it.i = it.s.len;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(it.s[it.i .. it.i + len]) catch 0xfffd;
        it.i += len;
        return cp;
    }
};

test "fonts: invisible format characters take no room" {
    try std.testing.expect(invisible(0x200e));
    try std.testing.expect(invisible(0xad));
    try std.testing.expect(!invisible('a'));
    try std.testing.expect(!invisible(0x3042));
}
