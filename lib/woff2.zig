//! woff2 — decode a WOFF2 web font into the SFNT the rasterizer reads.
//! WOFF2 (W3C) wraps an SFNT in a Brotli stream (see lib/brotli.zig) plus a
//! table-directory with compact integer encodings, and re-encodes the
//! TrueType `glyf`/`loca` tables into a transform that must be reversed to
//! rebuild the outlines. This module does exactly that: parse the header +
//! directory, Brotli-decompress the table data, reconstruct `glyf`/`loca`
//! (the null-transform tables are copied verbatim), and reassemble a plain
//! SFNT. The reconstruction logic follows the WOFF2 spec and the reference
//! decoder (github.com/google/woff2, MIT).
//!
//! Scope: the `glyf`/`loca` transform and untransformed tables — enough for
//! the TrueType and OpenType/CFF fonts real WOFF2 files carry. The optional
//! `hmtx` transform (rare) is rejected as Unsupported.

const std = @import("std");
const brotli = @import("brotli.zig");

pub const Error = error{ BadFont, Unsupported, OutOfMemory };

fn u16be(b: []const u8, o: usize) u16 {
    return @as(u16, b[o]) << 8 | b[o + 1];
}
fn u32be(b: []const u8, o: usize) u32 {
    return @as(u32, b[o]) << 24 | @as(u32, b[o + 1]) << 16 | @as(u32, b[o + 2]) << 8 | b[o + 3];
}
fn wr16(b: []u8, o: usize, v: u16) void {
    b[o] = @intCast(v >> 8);
    b[o + 1] = @intCast(v & 0xff);
}
fn wr32(b: []u8, o: usize, v: u32) void {
    b[o] = @intCast((v >> 24) & 0xff);
    b[o + 1] = @intCast((v >> 16) & 0xff);
    b[o + 2] = @intCast((v >> 8) & 0xff);
    b[o + 3] = @intCast(v & 0xff);
}

fn tag(comptime s: *const [4]u8) u32 {
    return (@as(u32, s[0]) << 24) | (@as(u32, s[1]) << 16) | (@as(u32, s[2]) << 8) | s[3];
}
const tag_glyf = tag("glyf");
const tag_loca = tag("loca");
const tag_hmtx = tag("hmtx");
const tag_head = tag("head");

/// The 63 tags a 6-bit directory flag can name directly (index 63 = the
/// tag follows inline).
const known_tags = [63]u32{
    tag("cmap"), tag("head"), tag("hhea"), tag("hmtx"), tag("maxp"), tag("name"),
    tag("OS/2"), tag("post"), tag("cvt "), tag("fpgm"), tag("glyf"), tag("loca"),
    tag("prep"), tag("CFF "), tag("VORG"), tag("EBDT"), tag("EBLC"), tag("gasp"),
    tag("hdmx"), tag("kern"), tag("LTSH"), tag("PCLT"), tag("VDMX"), tag("vhea"),
    tag("vmtx"), tag("BASE"), tag("GDEF"), tag("GPOS"), tag("GSUB"), tag("EBSC"),
    tag("JSTF"), tag("MATH"), tag("CBDT"), tag("CBLC"), tag("COLR"), tag("CPAL"),
    tag("SVG "), tag("sbix"), tag("acnt"), tag("avar"), tag("bdat"), tag("bloc"),
    tag("bsln"), tag("cvar"), tag("fdsc"), tag("feat"), tag("fmtx"), tag("fvar"),
    tag("gvar"), tag("hsty"), tag("just"), tag("lcar"), tag("mort"), tag("morx"),
    tag("opbd"), tag("prop"), tag("trak"), tag("Zapf"), tag("Silf"), tag("Glat"),
    tag("Gloc"), tag("Feat"), tag("Sill"),
};

// glyf simple-glyph flags.
const glyf_on_curve = 0x01;
const glyf_x_short = 0x02;
const glyf_y_short = 0x04;
const glyf_repeat = 0x08;
const glyf_x_same = 0x10;
const glyf_y_same = 0x20;
const overlap_simple = 0x40;

// Composite-glyph flags (needed to size a composite in the stream).
const c_arg_words = 0x0001;
const c_have_scale = 0x0008;
const c_more_components = 0x0020;
const c_xy_scale = 0x0040;
const c_two_by_two = 0x0080;
const c_have_instructions = 0x0100;

const flag_overlap_bitmap = 0x0001;

/// A sequential big-endian reader over a byte slice.
const Cursor = struct {
    b: []const u8,
    o: usize = 0,

    fn u8_(c: *Cursor) Error!u8 {
        if (c.o >= c.b.len) return Error.BadFont;
        defer c.o += 1;
        return c.b[c.o];
    }
    fn u16_(c: *Cursor) Error!u16 {
        if (c.o + 2 > c.b.len) return Error.BadFont;
        defer c.o += 2;
        return u16be(c.b, c.o);
    }
    fn u32_(c: *Cursor) Error!u32 {
        if (c.o + 4 > c.b.len) return Error.BadFont;
        defer c.o += 4;
        return u32be(c.b, c.o);
    }
    fn take(c: *Cursor, n: usize) Error![]const u8 {
        if (c.o + n > c.b.len) return Error.BadFont;
        defer c.o += n;
        return c.b[c.o .. c.o + n];
    }
    /// UIntBase128: 1–5 bytes, 7 bits each, big-endian, no leading zero byte.
    fn base128(c: *Cursor) Error!u32 {
        var result: u32 = 0;
        var i: usize = 0;
        while (i < 5) : (i += 1) {
            const code = try c.u8_();
            if (i == 0 and code == 0x80) return Error.BadFont;
            if (result & 0xfe000000 != 0) return Error.BadFont;
            result = (result << 7) | (code & 0x7f);
            if (code & 0x80 == 0) return result;
        }
        return Error.BadFont;
    }
    /// 255UInt16: a compact 0..65535 encoding.
    fn read255(c: *Cursor) Error!u32 {
        const code = try c.u8_();
        if (code == 253) return try c.u16_();
        if (code == 255) return @as(u32, try c.u8_()) + 253;
        if (code == 254) return @as(u32, try c.u8_()) + 253 * 2;
        return code;
    }
};

const Entry = struct {
    tag: u32,
    transformed: bool,
    orig_len: u32,
    transform_len: u32,
    src: []const u8 = &.{}, // slice of the decompressed data
    out_off: u32 = 0,
    out_len: u32 = 0,
};

/// Decode a WOFF2 font in `input` into a plain SFNT written to `out` (which
/// must hold `totalSfntSize`). Uses `gpa` for the Brotli arena and scratch.
pub fn decode(gpa: std.mem.Allocator, input: []const u8, out: []u8) Error![]const u8 {
    var arena_state = std.heap.ArenaAllocator.init(gpa);
    defer arena_state.deinit();
    const a = arena_state.allocator();

    if (input.len < 48) return Error.BadFont;
    if (u32be(input, 0) != 0x774F4632) return Error.BadFont; // 'wOF2'
    const flavor = u32be(input, 4);
    const num_tables = u16be(input, 12);
    const total_sfnt = u32be(input, 16);
    const total_comp = u32be(input, 20);
    if (num_tables == 0 or total_sfnt > out.len) return Error.BadFont;

    // Table directory.
    var cur = Cursor{ .b = input, .o = 48 };
    const entries = try a.alloc(Entry, num_tables);
    var decomp_size: usize = 0;
    for (entries) |*e| {
        const flags = try cur.u8_();
        const tag_idx = flags & 0x3f;
        const transform_version = (flags >> 6) & 3;
        const t = if (tag_idx == 0x3f) try cur.u32_() else known_tags[tag_idx];
        const orig_len = try cur.base128();
        // glyf/loca: transform version 0 = transformed, 3 = null. hmtx:
        // version 1 = transformed. All others: only version 0 (null).
        var transformed = false;
        var transform_len = orig_len;
        if (t == tag_glyf or t == tag_loca) {
            transformed = transform_version == 0;
        } else if (t == tag_hmtx and transform_version == 1) {
            return Error.Unsupported; // the rare hmtx transform
        } else if (transform_version != 0) {
            return Error.BadFont;
        }
        if (transformed) transform_len = try cur.base128();
        e.* = .{ .tag = t, .transformed = transformed, .orig_len = orig_len, .transform_len = transform_len };
        decomp_size += transform_len;
    }

    // Brotli-decompress the concatenated (possibly transformed) table data.
    if (cur.o + total_comp > input.len) return Error.BadFont;
    const comp = input[cur.o .. cur.o + total_comp];
    const decomp = try a.alloc(u8, decomp_size);
    try mapBrotliError(brotli.decode(a, comp, decomp));
    var off: usize = 0;
    for (entries) |*e| {
        e.src = decomp[off .. off + e.transform_len];
        off += e.transform_len;
    }

    // Reconstruct glyf/loca once (a transformed loca is rebuilt from glyf).
    var glyf_out: []u8 = &.{};
    var loca_out: []u8 = &.{};
    for (entries) |*e| {
        if (e.tag == tag_glyf and e.transformed) {
            const r = try reconstructGlyf(a, e.src, e.orig_len);
            glyf_out = r.glyf;
            loca_out = r.loca;
        }
    }

    // Lay tables into `out` after the SFNT header + directory, 4-aligned.
    const header_size: usize = 12 + 16 * @as(usize, num_tables);
    var pos: usize = header_size;
    for (entries) |*e| {
        const body: []const u8 = if (e.transformed and e.tag == tag_glyf)
            glyf_out
        else if (e.transformed and e.tag == tag_loca)
            loca_out
        else if (e.transformed)
            return Error.Unsupported
        else
            e.src[0..e.orig_len];
        if (pos + body.len > out.len) return Error.BadFont;
        @memcpy(out[pos .. pos + body.len], body);
        e.out_off = @intCast(pos);
        e.out_len = @intCast(body.len);
        pos += body.len;
        while (pos % 4 != 0) : (pos += 1) {
            if (pos < out.len) out[pos] = 0;
        }
    }

    // head.checkSumAdjustment is left as-is; the parser does not verify it.
    // SFNT header.
    wr32(out, 0, flavor);
    wr16(out, 4, num_tables);
    // searchRange / entrySelector / rangeShift: the parser recomputes, so 0.
    wr16(out, 6, 0);
    wr16(out, 8, 0);
    wr16(out, 10, 0);
    var de: usize = 12;
    for (entries) |*e| {
        wr32(out, de, e.tag);
        wr32(out, de + 4, 0); // checksum (unverified)
        wr32(out, de + 8, e.out_off);
        wr32(out, de + 12, e.out_len);
        de += 16;
    }
    return out[0..pos];
}

fn mapBrotliError(r: brotli.Error!void) Error!void {
    r catch |e| return switch (e) {
        error.OutOfMemory => Error.OutOfMemory,
        else => Error.BadFont,
    };
}

const Point = struct { x: i32, y: i32, on: bool };

/// Rebuild the `glyf` and `loca` tables from the WOFF2 glyf transform.
fn reconstructGlyf(a: std.mem.Allocator, data: []const u8, glyf_len_hint: u32) Error!struct { glyf: []u8, loca: []u8 } {
    var h = Cursor{ .b = data };
    _ = try h.u16_(); // version (reserved)
    const flags = try h.u16_();
    const has_overlap = flags & flag_overlap_bitmap != 0;
    const num_glyphs = try h.u16_();
    const index_format = try h.u16_();

    // Seven sub-streams follow the 36-byte header, sizes given up front.
    var sizes: [7]u32 = undefined;
    for (&sizes) |*s| s.* = try h.u32_();
    var streams: [7]Cursor = undefined;
    for (&streams, sizes) |*s, sz| s.* = .{ .b = try h.take(sz) };
    var n_contour = &streams[0];
    var n_points = &streams[1];
    var flag_s = &streams[2];
    var glyph_s = &streams[3];
    var composite = &streams[4];
    var bbox_s = &streams[5];
    var instr = &streams[6];

    // The bbox bitmap (one bit per glyph) precedes the bbox values.
    const bitmap_len = ((@as(usize, num_glyphs) + 31) >> 5) << 2;
    const bbox_bitmap = try bbox_s.take(bitmap_len);
    const overlap_bitmap: []const u8 = if (has_overlap) try h.take((@as(usize, num_glyphs) + 7) >> 3) else &.{};

    var glyf: std.ArrayList(u8) = .empty;
    // The final glyf table is glyf_len_hint bytes; reserve it up front so the
    // arena (which cannot reclaim regrown buffers) doesn't waste memory.
    try glyf.ensureTotalCapacity(a, glyf_len_hint);
    var loca_values = try a.alloc(u32, @as(usize, num_glyphs) + 1);
    var points: std.ArrayList(Point) = .empty;
    defer points.deinit(a);
    var end_pts_buf: [4096]u16 = undefined; // reused per glyph (contours ≤ this)

    var gi: usize = 0;
    while (gi < num_glyphs) : (gi += 1) {
        loca_values[gi] = @intCast(glyf.items.len);
        const have_bbox = (bbox_bitmap[gi >> 3] & (@as(u8, 0x80) >> @intCast(gi & 7))) != 0;
        const n_contours: i16 = @bitCast(try n_contour.u16_());

        if (n_contours == -1) {
            // Composite glyph: numberOfContours, bbox, then the raw composite
            // data (its size scanned from the flags), then instructions.
            if (!have_bbox) return Error.BadFont;
            const csize = try compositeSize(composite.*);
            const comp_bytes = try composite.take(csize.size);
            var instruction_size: u32 = 0;
            if (csize.have_instructions) instruction_size = try glyph_s.read255();
            try appendU16(a, &glyf, @bitCast(n_contours));
            try glyf.appendSlice(a, try bbox_s.take(8));
            try glyf.appendSlice(a, comp_bytes);
            if (csize.have_instructions) {
                try appendU16(a, &glyf, @intCast(instruction_size));
                try glyf.appendSlice(a, try instr.take(instruction_size));
            }
        } else if (n_contours > 0) {
            // Simple glyph.
            const nc: usize = @intCast(n_contours);
            if (nc > end_pts_buf.len) return Error.BadFont;
            const end_pts = end_pts_buf[0..nc];
            var total_points: u32 = 0;
            for (0..nc) |ci| {
                const npc = try n_points.read255();
                total_points += npc;
                end_pts[ci] = @intCast(total_points - 1);
            }
            const flags_buf = try flag_s.take(total_points);
            points.clearRetainingCapacity();
            try tripletDecode(a, &points, flags_buf, glyph_s, total_points);
            const instruction_size = try glyph_s.read255();

            try appendU16(a, &glyf, @bitCast(n_contours));
            if (have_bbox) {
                try glyf.appendSlice(a, try bbox_s.take(8));
            } else {
                var bb: [8]u8 = undefined;
                computeBbox(points.items, &bb);
                try glyf.appendSlice(a, &bb);
            }
            for (end_pts) |ep| try appendU16(a, &glyf, ep);
            try appendU16(a, &glyf, @intCast(instruction_size));
            try glyf.appendSlice(a, try instr.take(instruction_size));
            const has_overlap_bit = has_overlap and gi < overlap_bitmap.len * 8 and
                (overlap_bitmap[gi >> 3] & (@as(u8, 0x80) >> @intCast(gi & 7))) != 0;
            try storePoints(a, &glyf, points.items, has_overlap_bit);
        } else {
            // Empty glyph (0 contours): no data, must not carry a bbox.
            if (have_bbox) return Error.BadFont;
        }
        // Pad each glyph to a 4-byte boundary.
        while (glyf.items.len % 4 != 0) try glyf.append(a, 0);
    }
    loca_values[num_glyphs] = @intCast(glyf.items.len);

    // Serialise loca in the declared index format.
    const glyf_slice = try glyf.toOwnedSlice(a);
    const offset_size: usize = if (index_format != 0) 4 else 2;
    const loca = try a.alloc(u8, (@as(usize, num_glyphs) + 1) * offset_size);
    var lo: usize = 0;
    for (loca_values) |v| {
        if (index_format != 0) {
            wr32(loca, lo, v);
            lo += 4;
        } else {
            wr16(loca, lo, @intCast(v >> 1));
            lo += 2;
        }
    }
    return .{ .glyf = glyf_slice, .loca = loca };
}

fn appendU16(a: std.mem.Allocator, l: *std.ArrayList(u8), v: u16) Error!void {
    try l.append(a, @intCast(v >> 8));
    try l.append(a, @intCast(v & 0xff));
}

fn withSign(flag: u32, base: i32) i32 {
    return if (flag & 1 != 0) base else -base;
}

/// Decode `n` points from the flag stream + coordinate triplet stream.
fn tripletDecode(a: std.mem.Allocator, out: *std.ArrayList(Point), flags: []const u8, glyph_s: *Cursor, n: u32) Error!void {
    var x: i32 = 0;
    var y: i32 = 0;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const raw = flags[i];
        const on_curve = (raw >> 7) == 0;
        const flag: u32 = raw & 0x7f;
        var dx: i32 = 0;
        var dy: i32 = 0;
        if (flag < 10) {
            const b = try glyph_s.u8_();
            dy = withSign(flag, @intCast(((flag & 14) << 7) + b));
        } else if (flag < 20) {
            const b = try glyph_s.u8_();
            dx = withSign(flag, @intCast((((flag - 10) & 14) << 7) + b));
        } else if (flag < 84) {
            const b0: i32 = @intCast(flag - 20);
            const b1: i32 = try glyph_s.u8_();
            dx = withSign(flag, 1 + (b0 & 0x30) + (b1 >> 4));
            dy = withSign(flag >> 1, 1 + ((b0 & 0x0c) << 2) + (b1 & 0x0f));
        } else if (flag < 120) {
            const b0: i32 = @intCast(flag - 84);
            const b1: i32 = try glyph_s.u8_();
            const b2: i32 = try glyph_s.u8_();
            dx = withSign(flag, 1 + (@divTrunc(b0, 12) << 8) + b1);
            dy = withSign(flag >> 1, 1 + ((@mod(b0, 12) >> 2) << 8) + b2);
        } else if (flag < 124) {
            const b0: i32 = try glyph_s.u8_();
            const b1: i32 = try glyph_s.u8_();
            const b2: i32 = try glyph_s.u8_();
            dx = withSign(flag, (b0 << 4) + (b1 >> 4));
            dy = withSign(flag >> 1, ((b1 & 0x0f) << 8) + b2);
        } else {
            const b0: i32 = try glyph_s.u8_();
            const b1: i32 = try glyph_s.u8_();
            const b2: i32 = try glyph_s.u8_();
            const b3: i32 = try glyph_s.u8_();
            dx = withSign(flag, (b0 << 8) + b1);
            dy = withSign(flag >> 1, (b2 << 8) + b3);
        }
        x +%= dx;
        y +%= dy;
        try out.append(a, .{ .x = x, .y = y, .on = on_curve });
    }
}

fn computeBbox(points: []const Point, dst: *[8]u8) void {
    var xmin: i32 = 0;
    var ymin: i32 = 0;
    var xmax: i32 = 0;
    var ymax: i32 = 0;
    if (points.len > 0) {
        xmin = points[0].x;
        xmax = points[0].x;
        ymin = points[0].y;
        ymax = points[0].y;
    }
    for (points[1..]) |p| {
        xmin = @min(xmin, p.x);
        xmax = @max(xmax, p.x);
        ymin = @min(ymin, p.y);
        ymax = @max(ymax, p.y);
    }
    wr16(dst, 0, @bitCast(@as(i16, @truncate(xmin))));
    wr16(dst, 2, @bitCast(@as(i16, @truncate(ymin))));
    wr16(dst, 4, @bitCast(@as(i16, @truncate(xmax))));
    wr16(dst, 6, @bitCast(@as(i16, @truncate(ymax))));
}

/// Re-encode decoded points as standard glyf flags + x/y coordinate deltas.
fn storePoints(a: std.mem.Allocator, glyf: *std.ArrayList(u8), points: []const Point, has_overlap: bool) Error!void {
    // Flags with run-length (kGlyfRepeat) compression.
    const flags_start = glyf.items.len;
    var last_flag: i32 = -1;
    var repeat_count: u8 = 0;
    var last_x: i32 = 0;
    var last_y: i32 = 0;
    for (points, 0..) |p, i| {
        var flag: u8 = if (p.on) glyf_on_curve else 0;
        if (has_overlap and i == 0) flag |= overlap_simple;
        const dx = p.x - last_x;
        const dy = p.y - last_y;
        if (dx == 0) {
            flag |= glyf_x_same;
        } else if (dx > -256 and dx < 256) {
            flag |= glyf_x_short | (if (dx > 0) @as(u8, glyf_x_same) else 0);
        }
        if (dy == 0) {
            flag |= glyf_y_same;
        } else if (dy > -256 and dy < 256) {
            flag |= glyf_y_short | (if (dy > 0) @as(u8, glyf_y_same) else 0);
        }
        if (@as(i32, flag) == last_flag and repeat_count != 255) {
            glyf.items[glyf.items.len - 1] |= glyf_repeat;
            repeat_count += 1;
        } else {
            if (repeat_count != 0) {
                try glyf.append(a, repeat_count);
                repeat_count = 0;
            }
            try glyf.append(a, flag);
        }
        last_x = p.x;
        last_y = p.y;
        last_flag = flag;
    }
    if (repeat_count != 0) try glyf.append(a, repeat_count);
    _ = flags_start;

    // X coordinates, then Y coordinates.
    last_x = 0;
    for (points) |p| {
        const dx = p.x - last_x;
        if (dx == 0) {} else if (dx > -256 and dx < 256) {
            try glyf.append(a, @intCast(@abs(dx)));
        } else {
            try appendU16(a, glyf, @bitCast(@as(i16, @truncate(dx))));
        }
        last_x = p.x;
    }
    last_y = 0;
    for (points) |p| {
        const dy = p.y - last_y;
        if (dy == 0) {} else if (dy > -256 and dy < 256) {
            try glyf.append(a, @intCast(@abs(dy)));
        } else {
            try appendU16(a, glyf, @bitCast(@as(i16, @truncate(dy))));
        }
        last_y = p.y;
    }
}

/// Scan a composite glyph's components to find its byte size and whether it
/// carries instructions (without consuming the source cursor).
fn compositeSize(stream: Cursor) Error!struct { size: usize, have_instructions: bool } {
    var c = stream;
    const start = c.o;
    var have_instr = false;
    var flags: u16 = c_more_components;
    while (flags & c_more_components != 0) {
        flags = try c.u16_();
        _ = try c.u16_(); // glyph index
        if (flags & c_have_instructions != 0) have_instr = true;
        var arg_size: usize = if (flags & c_arg_words != 0) 4 else 2;
        if (flags & c_have_scale != 0) {
            arg_size += 2;
        } else if (flags & c_xy_scale != 0) {
            arg_size += 4;
        } else if (flags & c_two_by_two != 0) {
            arg_size += 8;
        }
        _ = try c.take(arg_size);
    }
    return .{ .size = c.o - start, .have_instructions = have_instr };
}

// ---------------------------------------------------------------- tests

const testing = std.testing;

test "decode a real WOFF2 (glyf transform) into a valid SFNT" {
    // Source Code Pro (ExtraLight), TrueType-flavoured WOFF2 — its glyf/loca
    // are transformed, so this exercises the full reconstruction path.
    const data = @embedFile("woff2/scp.woff2");
    const total_sfnt = u32be(data, 16);
    const out = try testing.allocator.alloc(u8, total_sfnt);
    defer testing.allocator.free(out);
    const sfnt = try decode(testing.allocator, data, out);
    try testing.expectEqual(@as(usize, total_sfnt), sfnt.len);

    // The reassembled SFNT must have glyf + loca, and loca's last offset
    // must equal the glyf table length (the two are consistent).
    const n = u16be(sfnt, 4);
    var glyf_off: usize = 0;
    var glyf_len: usize = 0;
    var loca_off: usize = 0;
    var loca_len: usize = 0;
    var head_loca_long = false;
    var i: usize = 0;
    while (i < n) : (i += 1) {
        const rec = 12 + i * 16;
        const t = u32be(sfnt, rec);
        const o = u32be(sfnt, rec + 8);
        const l = u32be(sfnt, rec + 12);
        if (t == tag_glyf) {
            glyf_off = o;
            glyf_len = l;
        } else if (t == tag_loca) {
            loca_off = o;
            loca_len = l;
        } else if (t == tag_head) {
            head_loca_long = u16be(sfnt, o + 50) != 0; // indexToLocFormat
        }
    }
    try testing.expect(glyf_len > 0 and loca_len > 0);
    // Last loca entry == glyf length.
    const last: usize = if (head_loca_long)
        u32be(sfnt, loca_off + loca_len - 4)
    else
        @as(usize, u16be(sfnt, loca_off + loca_len - 2)) * 2;
    try testing.expectEqual(glyf_len, last);
}
