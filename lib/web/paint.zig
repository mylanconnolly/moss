//! Painting a laid-out page into the toolkit's canvas: the canvas
//! background from the root or body, then every box in CSS 2.1's
//! order — a block's background and borders, its in-flow children,
//! its floats, its lines' inline backgrounds, text and markers — with
//! the positioned boxes around the flow in `z-index` order (negative
//! beneath it, the rest above, ties by document order). `overflow` other than `visible` clips a
//! box's children to its padding box. Text goes through the `Fonts`
//! that laid it out, so the pixels a test asserts and the pixels a
//! page domain shows come from the same calls.
const std = @import("std");
const ui = @import("../ui.zig");
const layout = @import("layout.zig");
const style = @import("style.zig");
const color = @import("color.zig");

const Layout = layout.Layout;
const Box = layout.Box;
const BoxId = layout.BoxId;
const NodeId = layout.NodeId;
const Document = layout.Document;
const Canvas = ui.Canvas;

pub const Error = error{OutOfMemory};

/// A rect in document pixels, tinted over what is under it (a find
/// match, a selection).
pub const Highlight = struct { x: f64, y: f64, w: f64, h: f64, color: u32 };

/// What a host of the page adds to the picture: highlights, and the
/// focused element (its box, or its fragments for an inline one, get
/// a ring).
pub const Options = struct {
    highlights: []const Highlight = &.{},
    focus: ?NodeId = null,
    /// The ring's colour, and a control's frame and face.
    accent: u32 = 0x2f6fde,
    frame: u32 = 0x8a8a8a,
    face: u32 = 0xe4e4e4,
};

/// Paint the whole layout, scrolled by `scroll_y` document pixels
/// (the canvas's own translation is not used; the painter subtracts).
pub fn paint(l: *const Layout, canvas: *const Canvas, scroll_y: f64) Error!void {
    return paintWith(l, canvas, scroll_y, .{});
}

pub fn paintWith(l: *const Layout, canvas: *const Canvas, scroll_y: f64, opts: Options) Error!void {
    var p: Painter = .{ .l = l, .canvas = canvas.*, .scroll = scroll_y, .opts = opts };
    // The canvas background: the root element's, else the body's, as
    // CSS propagates it; else left as the caller filled it.
    if (rootBackground(l)) |bg| p.canvas.fillAll(bg);
    // Positioned boxes paint in z-index order around the flow: the
    // negative ones beneath it, the rest (auto counting as 0) above,
    // ties in document order.
    const order = try p.l.a.dupe(layout.Absolute, l.absolutes.items);
    std.mem.sort(layout.Absolute, order, l, zBelow);
    var i: usize = 0;
    while (i < order.len and zOf(l, order[i].box) < 0) : (i += 1) try p.paintBox(order[i].box);
    try p.paintBox(l.root);
    while (i < order.len) : (i += 1) try p.paintBox(order[i].box);
    for (opts.highlights) |h| p.tint(h);
    if (opts.focus) |f| p.focusRing(f);
}

fn zOf(l: *const Layout, id: BoxId) i32 {
    return l.get(id).style.z_index orelse 0;
}

fn zBelow(l: *const Layout, a: layout.Absolute, b: layout.Absolute) bool {
    return zOf(l, a.box) < zOf(l, b.box);
}

fn rootBackground(l: *const Layout) ?u32 {
    const root = l.get(l.root);
    for (root.children.items) |c| {
        const root_el = l.get(c);
        if (root_el.style.background_color.a > 0) return root_el.style.background_color.word();
        for (root_el.children.items) |cc| {
            const body = l.get(cc);
            if (body.node != null and l.doc.isHtml(body.node.?, "body") and body.style.background_color.a > 0) return body.style.background_color.word();
        }
    }
    return null;
}

const Painter = struct {
    l: *const Layout,
    canvas: Canvas,
    scroll: f64,
    opts: Options = .{},

    fn px(v: f64) usize {
        return @intFromFloat(@max(0, @round(v)));
    }

    /// A rectangle in document coordinates, clipped by the canvas.
    fn fill(p: *const Painter, x: f64, y: f64, w: f64, h: f64, word: u32) void {
        const y0 = y - p.scroll;
        if (w <= 0 or h <= 0) return;
        const x0 = @max(0, x);
        const yy = @max(0, y0);
        const x1 = x + w;
        const y1 = y0 + h;
        if (x1 <= 0 or y1 <= 0) return;
        p.canvas.fillRect(px(x0), px(yy), px(x1 - x0), px(y1 - yy), word);
    }

    fn paintBox(p: *Painter, id: BoxId) Error!void {
        const b = p.l.get(id);
        if (b.style.visibility != .visible or b.style.opacity == 0) return;
        if (b.style.display == .none) return;
        if (b.kind == .text or b.kind == .br) return;
        // A control paints itself — except a `button` element, whose
        // face is its style and whose content is laid out like any box's.
        if (b.node) |n| if (controlOf(p.l.doc, n)) |kind| if (!p.l.doc.isHtml(n, "button")) {
            p.control(b, n, kind);
            return;
        };
        if (b.node) |n| if (p.l.doc.isHtml(n, "img") or (p.l.doc.get(n).namespace == .svg and std.mem.eql(u8, p.l.doc.get(n).name, "svg"))) {
            if (p.l.images) |imgs| if (imgs.get(n)) |bm| {
                p.picture(b, bm);
                return;
            };
        };
        // Backgrounds and borders on the border box (the root's are the
        // canvas's).
        if (b.kind != .root and b.kind != .inline_box and b.kind != .anon_block) {
            const radii = p.radiiOf(b);
            const rounded = radii[0] > 0 or radii[1] > 0 or radii[2] > 0 or radii[3] > 0;
            if (!(isHtmlOrBody(p.l, id) and rootBackground(p.l) != null)) {
                if (b.style.background_color.a > 0) {
                    // Rounded or translucent: blended per pixel.
                    if (rounded or b.style.background_color.a < 1) p.roundRect(b.x, b.y, b.w, b.h, radii, null, b.style.background_color) else p.fill(b.x, b.y, b.w, b.h, b.style.background_color.word());
                }
                p.backgroundImage(b);
            }
            if (rounded) p.roundBorders(b, radii) else p.borders(b);
        }
        // Clip children to the padding box when overflow says so.
        const saved = p.canvas;
        const clips = b.style.overflow_x != .visible or b.style.overflow_y != .visible;
        if (clips and b.kind != .root) {
            const x0 = b.x + b.border[3];
            const y0 = b.y + b.border[0] - p.scroll;
            const x1 = x0 + b.w - b.border[1] - b.border[3];
            const y1 = y0 + b.h - b.border[0] - b.border[2];
            p.canvas.clip_x0 = @max(p.canvas.clip_x0, px(@max(0, x0)));
            p.canvas.clip_y0 = @max(p.canvas.clip_y0, px(@max(0, y0)));
            p.canvas.clip_x1 = @min(p.canvas.clip_x1, px(@max(0, x1)));
            p.canvas.clip_y1 = @min(p.canvas.clip_y1, px(@max(0, y1)));
        }
        defer p.canvas = saved;
        // In-flow block children first, then floats, so a float paints
        // over the blocks it sits beside.
        for (b.children.items) |c| {
            const cb = p.l.get(c);
            if (cb.isOutOfFlow()) continue;
            if (cb.isBlockLevel()) try p.paintBox(c);
        }
        for (b.children.items) |c| if (p.l.get(c).isFloat()) try p.paintBox(c);
        // Lines: inline backgrounds, then text and atomics in order.
        for (b.lines.items) |ln| {
            const frags = p.l.fragments.items[ln.first_frag .. ln.first_frag + ln.frag_count];
            for (frags) |f| if (f.kind == .inline_span) p.inlineSpan(f);
            for (frags) |f| switch (f.kind) {
                .text, .marker => p.text(f),
                .atomic => try p.paintBox(f.box),
                else => {},
            };
        }
    }

    fn isHtmlOrBody(l: *const Layout, id: BoxId) bool {
        const b = l.get(id);
        const n = b.node orelse return false;
        return l.doc.isHtml(n, "html") or l.doc.isHtml(n, "body");
    }

    fn borders(p: *const Painter, b: *const Box) void {
        const st = b.style;
        for (0..4) |side| {
            const w = b.border[side];
            if (w <= 0) continue;
            const c = borderShade(st.borderColor(side), st.border_style[side], side);
            switch (side) {
                0 => p.fill(b.x, b.y, b.w, w, c),
                1 => p.fill(b.x + b.w - w, b.y, w, b.h, c),
                2 => p.fill(b.x, b.y + b.h - w, b.w, w, c),
                else => p.fill(b.x, b.y, w, b.h, c),
            }
            if (st.border_style[side] == .double and w >= 3) {
                // A double border is two lines with a gap: paint the
                // middle third in the background (or white).
                const third = w / 3;
                const inner = st.background_color;
                const gap: u32 = if (inner.a > 0) inner.word() else 0xffffff;
                switch (side) {
                    0 => p.fill(b.x, b.y + third, b.w, third, gap),
                    1 => p.fill(b.x + b.w - w + third, b.y, third, b.h, gap),
                    2 => p.fill(b.x, b.y + b.h - w + third, b.w, third, gap),
                    else => p.fill(b.x + third, b.y, third, b.h, gap),
                }
            }
        }
    }

    /// Inset, outset, groove and ridge borders shade their sides; dotted
    /// and dashed paint solid (the pattern is stage 9's).
    fn borderShade(c: color.Color, bs: style.BorderStyle, side: usize) u32 {
        const top_left = side == 0 or side == 3;
        const dark = switch (bs) {
            .inset, .groove => top_left,
            .outset, .ridge => !top_left,
            else => return c.word(),
        };
        const f: f64 = if (dark) 0.5 else 1.0;
        const lighten = !dark and bs != .inset and bs != .outset;
        var out = c;
        out.r = if (lighten) @min(255, c.r + (255 - c.r) * 0.5) else c.r * f;
        out.g = if (lighten) @min(255, c.g + (255 - c.g) * 0.5) else c.g * f;
        out.b = if (lighten) @min(255, c.b + (255 - c.b) * 0.5) else c.b * f;
        return out.word();
    }

    /// An inline box's background and borders across one line.
    fn inlineSpan(p: *const Painter, f: layout.Fragment) void {
        const b = p.l.get(f.box);
        const st = b.style;
        if (st.background_color.a > 0) p.fill(f.x, f.y, f.w, f.h, st.background_color.word());
        const opens = std.mem.indexOfScalar(u8, f.text, 'o') != null;
        const closes = std.mem.indexOfScalar(u8, f.text, 'c') != null;
        if (b.border[0] > 0) p.fill(f.x, f.y, f.w, b.border[0], st.borderColor(0).word());
        if (b.border[2] > 0) p.fill(f.x, f.y + f.h - b.border[2], f.w, b.border[2], st.borderColor(2).word());
        if (opens and b.border[3] > 0) p.fill(f.x, f.y, b.border[3], f.h, st.borderColor(3).word());
        if (closes and b.border[1] > 0) p.fill(f.x + f.w - b.border[1], f.y, b.border[1], f.h, st.borderColor(1).word());
    }

    /// A box's corner radii in pixels (a percentage of its width),
    /// shrunk together when two would overlap along a side.
    fn radiiOf(p: *const Painter, b: *const Box) [4]f64 {
        _ = p;
        var r: [4]f64 = undefined;
        for (0..4) |i| r[i] = @max(0, switch (b.style.border_radius[i]) {
            .px => |x| x,
            .percent => |pc| b.w * pc / 100,
        });
        const sums = [_]f64{ r[0] + r[1], r[1] + r[2], r[2] + r[3], r[3] + r[0] };
        const lens = [_]f64{ b.w, b.h, b.w, b.h };
        var f: f64 = 1;
        for (sums, lens) |sum, len| if (sum > len and sum > 0) {
            f = @min(f, len / sum);
        };
        for (&r) |*x| x.* *= f;
        return r;
    }

    /// How much of the pixel at (px_, py_) a rounded rect covers: exact
    /// inside, a one-pixel feather across a corner's arc.
    fn roundCover(x: f64, y: f64, w: f64, h: f64, r: [4]f64, px_: f64, py_: f64) f64 {
        const cx = px_ + 0.5;
        const cy = py_ + 0.5;
        if (cx < x or cy < y or cx > x + w or cy > y + h) {
            // Partly covered edge pixels.
            const ox = @max(0, @min(1, @min(cx - x + 0.5, x + w - cx + 0.5)));
            const oy = @max(0, @min(1, @min(cy - y + 0.5, y + h - cy + 0.5)));
            if (ox <= 0 or oy <= 0) return 0;
            return ox * oy;
        }
        const corners = [_][3]f64{ .{ x + r[0], y + r[0], r[0] }, .{ x + w - r[1], y + r[1], r[1] }, .{ x + w - r[2], y + h - r[2], r[2] }, .{ x + r[3], y + h - r[3], r[3] } };
        for (corners, 0..) |c, i| {
            if (c[2] <= 0) continue;
            const in_x = if (i == 0 or i == 3) cx < c[0] else cx > c[0];
            const in_y = if (i == 0 or i == 1) cy < c[1] else cy > c[1];
            if (in_x and in_y) {
                const d = @sqrt((cx - c[0]) * (cx - c[0]) + (cy - c[1]) * (cy - c[1])) - c[2];
                return std.math.clamp(0.5 - d, 0, 1);
            }
        }
        const ox = @min(1, @min(cx - x + 0.5, x + w - cx + 0.5));
        const oy = @min(1, @min(cy - y + 0.5, y + h - cy + 0.5));
        return @max(0, ox) * @max(0, oy);
    }

    /// Fill a rounded rect (minus `hole`, another, for a border ring).
    fn roundRect(p: *const Painter, x: f64, y: f64, w: f64, h: f64, r: [4]f64, hole: ?[8]f64, c: color.Color) void {
        if (w <= 0 or h <= 0 or c.a <= 0) return;
        const word = c.word();
        const alpha = c.a;
        const y0 = @max(0, @floor(y - p.scroll));
        const y1 = @min(@as(f64, @floatFromInt(p.canvas.h)), @ceil(y + h - p.scroll));
        const x0 = @max(0, @floor(x));
        const x1 = @min(@as(f64, @floatFromInt(p.canvas.w)), @ceil(x + w));
        var sy = y0;
        while (sy < y1) : (sy += 1) {
            var sx = x0;
            while (sx < x1) : (sx += 1) {
                var cov = roundCover(x, y - p.scroll, w, h, r, sx, sy);
                if (hole) |ho| if (cov > 0) {
                    cov -= roundCover(ho[0], ho[1] - p.scroll, ho[2], ho[3], .{ ho[4], ho[5], ho[6], ho[7] }, sx, sy);
                };
                if (cov <= 0) continue;
                p.canvas.blend(@intFromFloat(sx), @intFromFloat(sy), word, @intFromFloat(@round(@min(1, cov) * alpha * 255)));
            }
        }
    }

    /// Borders around rounded corners: the ring between the border box
    /// and the padding box, one colour (the top's) all round.
    fn roundBorders(p: *const Painter, b: *const Box, r: [4]f64) void {
        const bw = b.border;
        if (bw[0] <= 0 and bw[1] <= 0 and bw[2] <= 0 and bw[3] <= 0) return;
        var side: usize = 0;
        while (side < 4 and bw[side] <= 0) side += 1;
        const c = b.style.borderColor(side);
        const inner_r = [4]f64{ @max(0, r[0] - @max(bw[0], bw[3])), @max(0, r[1] - @max(bw[0], bw[1])), @max(0, r[2] - @max(bw[2], bw[1])), @max(0, r[3] - @max(bw[2], bw[3])) };
        p.roundRect(b.x, b.y, b.w, b.h, r, .{ b.x + bw[3], b.y + bw[0], b.w - bw[1] - bw[3], b.h - bw[0] - bw[2], inner_r[0], inner_r[1], inner_r[2], inner_r[3] }, c);
    }

    /// The `background-image` layer: a picture placed in the padding box
    /// by `background-position` and `-size`, tiled by `-repeat`, clipped
    /// to the border box; or a linear gradient over it.
    fn backgroundImage(p: *const Painter, b: *const Box) void {
        const st = b.style;
        switch (st.background_image) {
            .none => return,
            .linear => |g| return p.gradient(b, g.angle, g.stops, g.repeating),
            .url => {},
        }
        const imgs = p.l.images orelse return;
        const bm = imgs.background(st.background_image.url, st.background_base) orelse return;
        if (bm.w == 0 or bm.h == 0) return;
        const ax = b.x + b.border[3];
        const ay = b.y + b.border[0];
        const aw = b.w - b.border[1] - b.border[3];
        const ah = b.h - b.border[0] - b.border[2];
        if (aw <= 0 or ah <= 0) return;
        const scale = style.px_scale / bm.density;
        const nw = @as(f64, @floatFromInt(bm.w)) * scale;
        const nh = @as(f64, @floatFromInt(bm.h)) * scale;
        var tw = nw;
        var th = nh;
        switch (st.background_size) {
            .auto => {},
            .cover, .contain => {
                const f = if (st.background_size == .cover) @max(aw / nw, ah / nh) else @min(aw / nw, ah / nh);
                tw = nw * f;
                th = nh * f;
            },
            .size => |sz| {
                const w_: ?f64 = switch (sz[0]) {
                    .px => |x| x,
                    .percent => |pc| aw * pc / 100,
                    .auto => null,
                };
                const h_: ?f64 = switch (sz[1]) {
                    .px => |x| x,
                    .percent => |pc| ah * pc / 100,
                    .auto => null,
                };
                if (w_ != null and h_ != null) {
                    tw = w_.?;
                    th = h_.?;
                } else if (w_) |ww| {
                    tw = ww;
                    th = ww * nh / nw;
                } else if (h_) |hh| {
                    th = hh;
                    tw = hh * nw / nh;
                }
            },
        }
        if (tw < 0.5 or th < 0.5) return;
        const off_x = switch (st.background_position[0]) {
            .px => |x| x,
            .percent => |pc| (aw - tw) * pc / 100,
        };
        const off_y = switch (st.background_position[1]) {
            .px => |x| x,
            .percent => |pc| (ah - th) * pc / 100,
        };
        // Clipped to the border box.
        var q = p.*;
        q.canvas.clip_x0 = @max(q.canvas.clip_x0, px(@max(0, b.x)));
        q.canvas.clip_x1 = @min(q.canvas.clip_x1, px(@max(0, b.x + b.w)));
        q.canvas.clip_y0 = @max(q.canvas.clip_y0, px(@max(0, b.y - p.scroll)));
        q.canvas.clip_y1 = @min(q.canvas.clip_y1, px(@max(0, b.y + b.h - p.scroll)));
        if (q.canvas.clip_x1 <= q.canvas.clip_x0 or q.canvas.clip_y1 <= q.canvas.clip_y0) return;
        var x_start = ax + off_x;
        var y_start = ay + off_y;
        const rep_x = st.background_repeat[0];
        const rep_y = st.background_repeat[1];
        if (rep_x) x_start -= @ceil((x_start - b.x) / tw) * tw;
        if (rep_y) y_start -= @ceil((y_start - b.y) / th) * th;
        var ty = y_start;
        var rows: usize = 0;
        while (ty < b.y + b.h and rows < 4096) : (rows += 1) {
            var tx = x_start;
            var cols: usize = 0;
            while (tx < b.x + b.w and cols < 4096) : (cols += 1) {
                q.bitmap(bm, tx, ty - p.scroll, tw, th, 0, 0, @floatFromInt(bm.w), @floatFromInt(bm.h));
                if (!rep_x) break;
                tx += tw;
            }
            if (!rep_y) break;
            ty += th;
        }
    }

    /// A linear gradient over the border box: the colour at each pixel
    /// from its projection on the gradient line (CSS's length for the
    /// angle), stops interpolated in straight sRGB.
    fn gradient(p: *const Painter, b: *const Box, angle: f64, stops: []const style.Stop, repeating: bool) void {
        if (stops.len == 0 or b.w <= 0 or b.h <= 0) return;
        const rad = angle * std.math.pi / 180;
        const dx = @sin(rad);
        const dy = -@cos(rad);
        const len = @abs(b.w * dx) + @abs(b.h * dy);
        if (len <= 0) return;
        // Stop positions as fractions, the unplaced spread between the
        // placed (CSS Images §3.5.1).
        var pos_buf: [32]f64 = undefined;
        const n = @min(stops.len, pos_buf.len);
        const pos = pos_buf[0..n];
        for (stops[0..n], 0..) |st, i| pos[i] = if (st.at) |at| switch (at) {
            .px => |x| x / len,
            .percent => |pc| pc / 100,
        } else -1;
        if (pos[0] < 0) pos[0] = 0;
        if (pos[n - 1] < 0) pos[n - 1] = 1;
        var i: usize = 1;
        while (i < n) : (i += 1) {
            if (pos[i] >= 0) {
                pos[i] = @max(pos[i], pos[i - 1]);
                continue;
            }
            var j = i;
            while (pos[j] < 0) j += 1;
            const from = pos[i - 1];
            const to = @max(pos[j], from);
            for (i..j) |k| pos[k] = from + (to - from) * @as(f64, @floatFromInt(k - i + 1)) / @as(f64, @floatFromInt(j - i + 1));
            i = j;
        }
        const cxm = b.x + b.w / 2;
        const cym = b.y + b.h / 2;
        const y0 = @max(0, @floor(b.y - p.scroll));
        const y1 = @min(@as(f64, @floatFromInt(p.canvas.h)), @ceil(b.y + b.h - p.scroll));
        const x0 = @max(0, @floor(b.x));
        const x1 = @min(@as(f64, @floatFromInt(p.canvas.w)), @ceil(b.x + b.w));
        var sy = y0;
        while (sy < y1) : (sy += 1) {
            var sx = x0;
            while (sx < x1) : (sx += 1) {
                var t = ((sx + 0.5 - cxm) * dx + (sy + 0.5 + p.scroll - cym) * dy) / len + 0.5;
                if (repeating and pos[n - 1] > pos[0]) {
                    const span = pos[n - 1] - pos[0];
                    t = pos[0] + @mod(t - pos[0], span);
                }
                var c = stops[0].color;
                if (t >= pos[n - 1]) {
                    c = stops[n - 1].color;
                } else if (t > pos[0]) {
                    var k: usize = 1;
                    while (k < n and pos[k] < t) k += 1;
                    const a0 = stops[k - 1].color;
                    const a1 = stops[@min(k, n - 1)].color;
                    const span = pos[@min(k, n - 1)] - pos[k - 1];
                    const f = if (span > 0) (t - pos[k - 1]) / span else 1;
                    c = .{ .r = a0.r + (a1.r - a0.r) * f, .g = a0.g + (a1.g - a0.g) * f, .b = a0.b + (a1.b - a0.b) * f, .a = a0.a + (a1.a - a0.a) * f };
                }
                if (c.a <= 0) continue;
                p.canvas.blend(@intFromFloat(sx), @intFromFloat(sy), c.word(), @intFromFloat(@round(@min(1, c.a) * 255)));
            }
        }
    }

    /// A picture into its box's content area, scaled to it — pixel for
    /// pixel at its own size, else bilinearly (a zoomed page scales
    /// every picture) — alpha blending over what is under it.
    fn picture(p: *const Painter, b: *const layout.Box, bm: layout.Bitmap) void {
        const x0f = b.x + b.border[3] + b.padding[3];
        const y0f = b.y + b.border[0] + b.padding[0] - p.scroll;
        const cw = b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3];
        const chh = b.h - b.border[0] - b.border[2] - b.padding[0] - b.padding[2];
        if (cw <= 0 or chh <= 0 or bm.w == 0 or bm.h == 0) return;
        p.bitmap(bm, x0f, y0f, cw, chh, 0, 0, @floatFromInt(bm.w), @floatFromInt(bm.h));
    }

    /// The source rect (sx, sy, sw, sh) of a bitmap drawn into the
    /// screen rect (x, y, w, h), clipped by the canvas.
    fn bitmap(p: *const Painter, bm: layout.Bitmap, x: f64, y: f64, w: f64, h: f64, sx: f64, sy: f64, sw: f64, sh: f64) void {
        const dw: usize = px(w);
        const dh: usize = px(h);
        if (dw == 0 or dh == 0 or bm.w == 0 or bm.h == 0) return;
        const ox: i64 = @intFromFloat(@round(x));
        const oy: i64 = @intFromFloat(@round(y));
        const exact = @abs(sw - w) < 0.01 and @abs(sh - h) < 0.01;
        const fx = sw / @as(f64, @floatFromInt(dw));
        const fy = sh / @as(f64, @floatFromInt(dh));
        const cx0: i64 = @intCast(p.canvas.clip_x0);
        const cx1: i64 = @intCast(p.canvas.clip_x1);
        const cy1: i64 = @intCast(@min(p.canvas.h, p.canvas.clip_y1));
        var yy: usize = 0;
        while (yy < dh) : (yy += 1) {
            const ty = oy + @as(i64, @intCast(yy));
            if (ty < 0) continue;
            if (ty >= cy1) break;
            var xx: usize = 0;
            while (xx < dw) : (xx += 1) {
                const tx = ox + @as(i64, @intCast(xx));
                if (tx < cx0) continue;
                if (tx >= cx1) break;
                var rgba: [4]f64 = undefined;
                if (exact) {
                    const ix: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(bm.w - 1)), sx + @as(f64, @floatFromInt(xx))));
                    const iy: u32 = @intFromFloat(@min(@as(f64, @floatFromInt(bm.h - 1)), sy + @as(f64, @floatFromInt(yy))));
                    const o = (@as(usize, iy) * bm.w + ix) * 4;
                    for (0..4) |k| rgba[k] = @floatFromInt(bm.rgba[o + k]);
                } else {
                    // The sample point in source pixels, pixel centres at
                    // .5; the four around it weighted by distance, colour
                    // premultiplied so a transparent edge does not darken.
                    const u = std.math.clamp(sx + (@as(f64, @floatFromInt(xx)) + 0.5) * fx - 0.5, 0, @as(f64, @floatFromInt(bm.w - 1)));
                    const v = std.math.clamp(sy + (@as(f64, @floatFromInt(yy)) + 0.5) * fy - 0.5, 0, @as(f64, @floatFromInt(bm.h - 1)));
                    const x_0: u32 = @intFromFloat(@floor(u));
                    const y_0: u32 = @intFromFloat(@floor(v));
                    const x_1 = @min(bm.w - 1, x_0 + 1);
                    const y_1 = @min(bm.h - 1, y_0 + 1);
                    const ax = u - @floor(u);
                    const ay = v - @floor(v);
                    rgba = .{ 0, 0, 0, 0 };
                    const taps = [_]struct { x: u32, y: u32, wt: f64 }{
                        .{ .x = x_0, .y = y_0, .wt = (1 - ax) * (1 - ay) },
                        .{ .x = x_1, .y = y_0, .wt = ax * (1 - ay) },
                        .{ .x = x_0, .y = y_1, .wt = (1 - ax) * ay },
                        .{ .x = x_1, .y = y_1, .wt = ax * ay },
                    };
                    for (taps) |t| {
                        const o = (@as(usize, t.y) * bm.w + t.x) * 4;
                        const a: f64 = @floatFromInt(bm.rgba[o + 3]);
                        for (0..3) |k| rgba[k] += @as(f64, @floatFromInt(bm.rgba[o + k])) * a * t.wt;
                        rgba[3] += a * t.wt;
                    }
                    if (rgba[3] > 0) for (0..3) |k| {
                        rgba[k] /= rgba[3];
                    };
                }
                const word = (@as(u32, @intFromFloat(@round(rgba[0]))) << 16) | (@as(u32, @intFromFloat(@round(rgba[1]))) << 8) | @as(u32, @intFromFloat(@round(rgba[2])));
                p.canvas.blend(@intCast(tx), @intCast(ty), word, @intFromFloat(@round(rgba[3])));
            }
        }
    }

    /// A 1px frame inside a rect.
    fn stroke(p: *const Painter, x: f64, y: f64, w: f64, h: f64, thick: f64, word: u32) void {
        p.fill(x, y, w, thick, word);
        p.fill(x, y + h - thick, w, thick, word);
        p.fill(x, y, thick, h, word);
        p.fill(x + w - thick, y, thick, h, word);
    }

    /// A translucent tint over a rect (a highlight), blending per pixel.
    fn tint(p: *const Painter, h: Highlight) void {
        const x0: usize = px(@max(0, h.x));
        const y0f = h.y - p.scroll;
        if (y0f + h.h <= 0 or h.w <= 0 or h.h <= 0) return;
        const y0: usize = px(@max(0, y0f));
        const x1: usize = px(@max(0, h.x + h.w));
        const y1: usize = px(@max(0, y0f + h.h));
        var y = y0;
        while (y < y1 and y < p.canvas.h) : (y += 1) {
            var x = x0;
            while (x < x1 and x < p.canvas.w) : (x += 1) p.canvas.blend(x, y, h.color, 110);
        }
    }

    /// The focus ring: around the focused element's box, or around each
    /// of its fragments when it is inline (a link).
    fn focusRing(p: *const Painter, node: NodeId) void {
        for (p.l.boxes.items, 0..) |b, i| {
            if (b.node != node) continue;
            switch (b.kind) {
                .inline_box, .text => for (p.l.fragments.items) |f| {
                    if (f.dead) continue;
                    if (f.box == @as(BoxId, @intCast(i)) and f.kind == .inline_span) p.stroke(f.x - 2, f.y - 2, f.w + 4, f.h + 4, 2, p.opts.accent);
                },
                else => p.stroke(b.x - 2, b.y - 2, b.w + 4, b.h + 4, 2, p.opts.accent),
            }
        }
    }

    /// A form control, drawn by the page since no toolkit reaches in:
    /// its frame, its face, and the value or label it shows.
    fn control(p: *const Painter, b: *const layout.Box, node: NodeId, kind: Control) void {
        const doc = p.l.doc;
        const st = b.style;
        const font = layout.fontOf(st);
        const m = p.l.fonts.metrics(font);
        const white: u32 = 0xffffff;
        switch (kind) {
            .checkbox, .radio => {
                p.fill(b.x, b.y, b.w, b.h, white);
                p.stroke(b.x, b.y, b.w, b.h, 1, p.opts.frame);
                if (doc.hasAttr(node, "checked")) p.fill(b.x + 3, b.y + 3, @max(1, b.w - 6), @max(1, b.h - 6), p.opts.accent);
                return;
            },
            else => {},
        }
        // A field or a button is a box first — its background and borders
        // as its style says (the UA sheet's, or the page's own) — with its
        // value or label set in its content box.
        if (st.background_color.a > 0) p.fill(b.x, b.y, b.w, b.h, st.background_color.word());
        p.borders(b);
        const cx = b.x + b.border[3] + b.padding[3];
        const cw = b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3];
        const cy = b.y + b.border[0] + b.padding[0];
        const ch = b.h - b.border[0] - b.border[2] - b.padding[0] - b.padding[2];
        var value: []const u8 = switch (kind) {
            .textarea => doc.getAttr(node, "value") orelse (doc.textContent(node, p.l.a) catch ""),
            .select => selectedOption(doc, node),
            .button => blk: {
                const v = doc.getAttr(node, "value") orelse "";
                break :blk if (v.len == 0) "Submit" else v;
            },
            else => doc.getAttr(node, "value") orelse "",
        };
        var dots: [64]u8 = undefined;
        if (kind == .password) {
            const n = @min(value.len, dots.len);
            @memset(dots[0..n], '*');
            value = dots[0..n];
        }
        // What does not fit is cut at the content box; the text sits on
        // its centre line (a textarea's from the top).
        var q = p.*;
        q.canvas.clip_x0 = @max(q.canvas.clip_x0, px(@max(0, cx)));
        q.canvas.clip_x1 = @min(q.canvas.clip_x1, px(@max(0, cx + cw)));
        const inner_h = m.ascent + m.descent;
        const baseline = if (kind == .textarea) cy + m.ascent else cy + (ch - inner_h) / 2 + m.ascent;
        const tx = if (kind == .button) cx + @max(0, (cw - p.l.fonts.advance(font, value)) / 2) else cx;
        // An empty field shows its placeholder, greyed.
        if (value.len == 0 and (kind == .text or kind == .textarea or kind == .password)) if (doc.getAttr(node, "placeholder")) |ph| {
            p.l.fonts.draw(&q.canvas, font, tx, baseline - p.scroll, ph, 0x757575);
            return;
        };
        p.l.fonts.draw(&q.canvas, font, tx, baseline - p.scroll, value, st.color.word());
        if (kind == .select) p.l.fonts.draw(&q.canvas, font, cx + cw - p.l.fonts.advance(font, "v"), baseline - p.scroll, "v", p.opts.frame);
    }

    fn text(p: *const Painter, f: layout.Fragment) void {
        const b = p.l.get(f.box);
        const st = b.style;
        const font = layout.fontOf(st);
        const word = st.color.word();
        if (f.text.len == 0) return;
        if (f.x + f.w <= 0 or f.y + f.h - p.scroll <= 0) return;
        p.l.fonts.draw(&p.canvas, font, f.x, f.baseline - p.scroll, f.text, word);
        // Decorations: one pixel lines, or thicker with the font.
        const thick = @max(1, @round(st.font_size / 16));
        if (st.text_decoration.underline) p.fill(f.x, f.baseline + 1, f.w, thick, word);
        if (st.text_decoration.line_through) p.fill(f.x, f.baseline - st.font_size * 0.3, f.w, thick, word);
        if (st.text_decoration.overline) p.fill(f.x, f.y, f.w, thick, word);
    }
};

/// The kinds of control the painter draws itself.
pub const Control = enum { text, password, checkbox, radio, button, select, textarea };

/// The control an element is, if it is one (a hidden input is none).
pub fn controlOf(doc: *const Document, node: NodeId) ?Control {
    if (doc.isHtml(node, "textarea")) return .textarea;
    if (doc.isHtml(node, "select")) return .select;
    if (doc.isHtml(node, "button")) return .button;
    if (!doc.isHtml(node, "input")) return null;
    const t = doc.getAttr(node, "type") orelse "text";
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(t, "checkbox")) return .checkbox;
    if (eq(t, "radio")) return .radio;
    if (eq(t, "submit") or eq(t, "button") or eq(t, "reset")) return .button;
    if (eq(t, "password")) return .password;
    if (eq(t, "hidden")) return null;
    return .text;
}

/// The text of a select's chosen option: the one marked `selected`,
/// else the first.
pub fn selectedOption(doc: *const Document, node: NodeId) []const u8 {
    var first: ?NodeId = null;
    var w = doc.walk(node);
    while (w.next()) |id| if (doc.isHtml(id, "option")) {
        if (first == null) first = id;
        if (doc.hasAttr(id, "selected")) return optionText(doc, id);
    };
    return if (first) |f| optionText(doc, f) else "";
}

fn optionText(doc: *const Document, id: NodeId) []const u8 {
    const c = doc.get(id).first_child orelse return doc.getAttr(id, "value") orelse "";
    const n = doc.get(c);
    return if (n.kind == .text) std.mem.trim(u8, n.text.items, " \t\r\n") else "";
}

// ------------------------------------------------------------------ tests

const html = @import("html.zig");
const dom = @import("dom.zig");

/// Render a page into a fresh white canvas of `w`×`h` with the test fonts.
pub fn renderForTest(a: std.mem.Allocator, src: []const u8, w: usize, h: usize) ![]u32 {
    const doc = try html.parse(a, src, .{});
    const env: style.Env = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
    const sheets = try style.collectDocumentSheets(a, doc, env);
    const styles = try a.create(style.Styles);
    styles.* = try style.compute(a, doc, sheets, env);
    var fixed: layout.FixedFonts = .{};
    const l = try layout.layoutDocument(a, doc, styles, fixed.fonts(), @floatFromInt(w), @floatFromInt(h));
    const px = try a.alloc(u32, w * h);
    const canvas = Canvas.init(px.ptr, w, h);
    canvas.fillAll(0xffffff);
    try paint(l, &canvas, 0);
    return px;
}

const verbose = false;

fn reftestSize(src: []const u8) [2]usize {
    const key = "name=\"reftest-size\" content=\"";
    const at = std.mem.indexOf(u8, src, key) orelse return .{ 320, 240 };
    const rest = src[at + key.len ..];
    const end = std.mem.indexOfScalar(u8, rest, '"') orelse return .{ 320, 240 };
    const x = std.mem.indexOfScalar(u8, rest[0..end], 'x') orelse return .{ 320, 240 };
    const w = std.fmt.parseInt(usize, rest[0..x], 10) catch return .{ 320, 240 };
    const h = std.fmt.parseInt(usize, rest[x + 1 .. end], 10) catch return .{ 320, 240 };
    return .{ w, h };
}

// The reftests: every `NAME.html` under tools/testdata/web/reftests
// beside its `NAME-ref.html` must paint the same pixels; the count is
// printed and asserted. A difference names its first pixel.
test "paint: the reftests, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = std.Io.Dir.cwd().openDir(io, "tools/testdata/web/reftests", .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html") or std.mem.endsWith(u8, entry.name, "-ref.html")) continue;
        try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f);
    var passed: usize = 0;
    for (names.items) |name| {
        const test_src = try dir.readFileAlloc(io, name, a, .limited(1 << 20));
        const ref_name = try std.mem.concat(a, u8, &.{ name[0 .. name.len - ".html".len], "-ref.html" });
        const ref_src = try dir.readFileAlloc(io, ref_name, a, .limited(1 << 20));
        // The reference may ask for a canvas (`<meta name="reftest-size"
        // content="WxH">`); the default is 320×240.
        const size = reftestSize(ref_src);
        const w = size[0];
        const h = size[1];
        const got = try renderForTest(a, test_src, w, h);
        const want = try renderForTest(a, ref_src, w, h);
        var diff: ?usize = null;
        for (got, want, 0..) |g, r, i| if (g != r) {
            diff = i;
            break;
        };
        if (diff == null) passed += 1 else if (verbose) std.debug.print("--- {s}: first difference at ({d}, {d}): {x:0>6} vs {x:0>6}\n", .{ name, diff.? % w, diff.? / w, got[diff.?] & 0xffffff, want[diff.?] & 0xffffff });
    }
    std.debug.print("reftests: {d}/{d} agree\n", .{ passed, names.items.len });
    try std.testing.expectEqual(names.items.len, passed);
    try std.testing.expect(names.items.len >= 16);
}

// A line with hundreds of inline boxes: the spans appended for them grow
// the fragment list while the line's own fragments are being read
// (Wikipedia's front page found the slice taken once pointing into the
// list's freed buffer).
test "paint: a line of many inline boxes survives the fragment list growing" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "<body style='margin:0;width:4000px'><p>");
    for (0..400) |i| {
        var b: [32]u8 = undefined;
        try src.appendSlice(a, try std.fmt.bufPrint(&b, "<b><i>x{d}</i></b> ", .{i}));
    }
    try src.appendSlice(a, "</p></body>");
    _ = try renderForTest(a, src.items, 4096, 64);
}
