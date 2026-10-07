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
    /// Memory for the layers a translucent, transformed or clipped box
    /// is painted into (freed within the paint; a layer that does not
    /// fit paints plainly, without its effect). None: no layers.
    scratch: ?std.mem.Allocator = null,
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
    // The canvas's background — inside the clip only: a band repaint that
    // filled the whole viewport erased the rows a scroll had just moved
    // (the page went page-background grey as it scrolled, 2026-09-24).
    if (rootBackground(l)) |bg| p.canvas.fillRect(0, 0, p.canvas.w, p.canvas.h, bg);
    // The root's content paints the positioned boxes around its flow
    // (`paintContent`): the negative z-index ones beneath it, the rest
    // above, in tree order within a z-index.
    try p.paintBox(l.root);
    for (opts.highlights) |h| p.tint(h);
    if (opts.focus) |f| p.focusRing(f);
}

fn zOf(l: *const Layout, id: BoxId) i32 {
    return l.get(id).style.z_index orelse 0;
}

/// A positioned box of a unit's layer, with its z-index; ties keep
/// tree order (box ids are build order, which is tree order).
const Layered = struct { box: BoxId, z: i32 };

fn layerBelow(_: void, a: Layered, b: Layered) bool {
    if (a.z != b.z) return a.z < b.z;
    return a.box < b.box;
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
    /// What the canvas's x = 0 is in document x: a layer's painter
    /// targets a buffer that starts at the layer's left edge.
    dx: f64 = 0,
    /// The layer box being painted into its own buffer (so its
    /// `paintBox` paints plainly, once).
    layer_root: ?BoxId = null,

    fn px(v: f64) usize {
        return @intFromFloat(@max(0, @round(v)));
    }

    /// A rectangle in document coordinates, clipped by the canvas.
    /// A solid rect, clamped to the canvas's clip: the page's background
    /// is one of these, and a band repaint that let it cover the whole
    /// viewport erased the rows a scroll had just moved (2026-09-24).
    fn fill(p: *const Painter, x: f64, y: f64, w: f64, h: f64, word: u32) void {
        const y0 = y - p.scroll;
        if (w <= 0 or h <= 0) return;
        const x0 = @max(@as(f64, @floatFromInt(p.canvas.clip_x0)), x - p.dx);
        const yy = @max(@as(f64, @floatFromInt(p.canvas.clip_y0)), y0);
        const x1 = @min(@as(f64, @floatFromInt(p.canvas.clip_x1)), x + w - p.dx);
        const y1 = @min(@as(f64, @floatFromInt(p.canvas.clip_y1)), y0 + h);
        if (x1 <= x0 or y1 <= yy) return;
        p.canvas.fillRect(px(x0), px(yy), px(x1 - x0), px(y1 - yy), word);
    }

    /// A positioned box from the global list: a fixed one (or one inside
    /// a fixed subtree) was laid out in viewport coordinates and paints
    /// without the scroll.
    fn paintPositioned(p: *Painter, id: BoxId) Error!void {
        if (!layout.inFixed(p.l, id)) return p.paintBox(id);
        const saved = p.scroll;
        p.scroll = 0;
        defer p.scroll = saved;
        try p.paintBox(id);
    }

    /// The area a background layer is positioned in: the box's padding
    /// box, or the viewport for `background-attachment: fixed` (in the
    /// painter's coordinates: the scroll is where the viewport is).
    const Area = struct { x: f64, y: f64, w: f64, h: f64 };

    fn backgroundArea(p: *const Painter, b: *const Box) Area {
        if (b.style.background_attachment == .fixed) return .{ .x = 0, .y = p.scroll, .w = p.l.viewport_w, .h = p.l.viewport_h };
        return .{ .x = b.x + b.border[3], .y = b.y + b.border[0], .w = b.w - b.border[1] - b.border[3], .h = b.h - b.border[0] - b.border[2] };
    }

    fn paintBox(p: *Painter, id: BoxId) Error!void {
        const b = p.l.get(id);
        if (b.style.visibility != .visible or b.style.opacity == 0) return;
        if (layout.isLayerBox(b) and (p.layer_root == null or p.layer_root.? != id)) return p.paintLayered(id);
        return p.paintPlain(id);
    }

    /// A 2D affine map, CSS's `matrix(a, b, c, d, e, f)`: x' = ax + cy + e,
    /// y' = bx + dy + f.
    const Affine = [6]f64;
    const identity: Affine = .{ 1, 0, 0, 1, 0, 0 };

    fn mul(m: Affine, n: Affine) Affine {
        // m ∘ n: n first.
        return .{
            m[0] * n[0] + m[2] * n[1],
            m[1] * n[0] + m[3] * n[1],
            m[0] * n[2] + m[2] * n[3],
            m[1] * n[2] + m[3] * n[3],
            m[0] * n[4] + m[2] * n[5] + m[4],
            m[1] * n[4] + m[3] * n[5] + m[5],
        };
    }

    fn apply(m: Affine, x: f64, y: f64) [2]f64 {
        return .{ m[0] * x + m[2] * y + m[4], m[1] * x + m[3] * y + m[5] };
    }

    fn invert(m: Affine) ?Affine {
        const det = m[0] * m[3] - m[1] * m[2];
        if (@abs(det) < 1e-9) return null;
        const a = m[3] / det;
        const b = -m[1] / det;
        const c = -m[2] / det;
        const d = m[0] / det;
        return .{ a, b, c, d, -(a * m[4] + c * m[5]), -(b * m[4] + d * m[5]) };
    }

    /// A box's transform in the painter's coordinates: its functions in
    /// order about its `transform-origin`.
    fn transformOf(p: *const Painter, b: *const Box) Affine {
        const st = b.style;
        if (st.transform_fns.len == 0) return identity;
        const ox = b.x + resolveLP(st.transform_origin[0], b.w);
        const oy = b.y - p.scroll + resolveLP(st.transform_origin[1], b.h);
        var m: Affine = .{ 1, 0, 0, 1, ox, oy };
        for (st.transform_fns) |f| {
            const fm: Affine = switch (f) {
                .translate => |t| .{ 1, 0, 0, 1, resolveLP(t[0], b.w), resolveLP(t[1], b.h) },
                .scale => |s| .{ s[0], 0, 0, s[1], 0, 0 },
                .rotate => |deg| blk: {
                    const r = deg * std.math.pi / 180;
                    break :blk .{ @cos(r), @sin(r), -@sin(r), @cos(r), 0, 0 };
                },
                .skew => |sk| .{ 1, @tan(sk[1] * std.math.pi / 180), @tan(sk[0] * std.math.pi / 180), 1, 0, 0 },
                .matrix => |mm| mm,
            };
            m = mul(m, fm);
        }
        return mul(m, .{ 1, 0, 0, 1, -ox, -oy });
    }

    fn resolveLP(lp: style.LengthPercent, of: f64) f64 {
        return switch (lp) {
            .px => |x| x,
            .percent => |pc| of * pc / 100,
            .calc => |c| c.of(of),
        };
    }

    /// Whether a document point is inside the box's `clip-path` shape.
    fn clipInside(b: *const Box, x: f64, y: f64) bool {
        const st = b.style;
        switch (st.clip_path) {
            .none => return true,
            .inset => |in| {
                const x0 = b.x + resolveLP(in.left, b.w);
                const x1 = b.x + b.w - resolveLP(in.right, b.w);
                const y0 = b.y + resolveLP(in.top, b.h);
                const y1 = b.y + b.h - resolveLP(in.bottom, b.h);
                if (!(x >= x0 and x < x1 and y >= y0 and y < y1)) return false;
                const r = @min(resolveLP(in.radius, b.w), (x1 - x0) / 2, (y1 - y0) / 2);
                if (r <= 0) return true;
                const cx = @max(x0 + r, @min(x1 - r, x));
                const cy = @max(y0 + r, @min(y1 - r, y));
                return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r;
            },
            .circle => |c| {
                const cx = b.x + resolveLP(c.cx, b.w);
                const cy = b.y + resolveLP(c.cy, b.h);
                const r = if (c.r) |rr| resolveLP(rr, @sqrt((b.w * b.w + b.h * b.h) / 2)) else @min(@min(cx - b.x, b.x + b.w - cx), @min(cy - b.y, b.y + b.h - cy));
                return (x - cx) * (x - cx) + (y - cy) * (y - cy) <= r * r;
            },
            .ellipse => |e| {
                const cx = b.x + resolveLP(e.cx, b.w);
                const cy = b.y + resolveLP(e.cy, b.h);
                const rx = if (e.rx) |rr| resolveLP(rr, b.w) else @min(cx - b.x, b.x + b.w - cx);
                const ry = if (e.ry) |rr| resolveLP(rr, b.h) else @min(cy - b.y, b.y + b.h - cy);
                if (rx <= 0 or ry <= 0) return false;
                const u = (x - cx) / rx;
                const v = (y - cy) / ry;
                return u * u + v * v <= 1;
            },
            .polygon => |pts| {
                // Even-odd crossing count.
                var inside = false;
                var j = pts.len - 1;
                for (pts, 0..) |pt, i| {
                    const xi = b.x + resolveLP(pt[0], b.w);
                    const yi = b.y + resolveLP(pt[1], b.h);
                    const xj = b.x + resolveLP(pts[j][0], b.w);
                    const yj = b.y + resolveLP(pts[j][1], b.h);
                    if ((yi > y) != (yj > y) and x < (xj - xi) * (y - yi) / (yj - yi) + xi) inside = !inside;
                    j = i;
                }
                return inside;
            },
        }
    }

    /// A translucent, transformed or clipped box: its subtree painted
    /// into a layer of its own — twice, over black and over white, so
    /// the alpha of every pixel is the difference — then composited
    /// onto the canvas through its transform (each destination pixel
    /// mapped back and sampled at the nearest layer pixel), its clip
    /// shape and its opacity. A layer that does not fit the scratch
    /// paints plainly.
    fn paintLayered(p: *Painter, id: BoxId) Error!void {
        const b = p.l.get(id);
        const scratch = p.opts.scratch orelse return p.paintPlain(id);
        const sb = layout.paintBounds(p.l, id);
        if (sb.w <= 0 or sb.h <= 0) return;
        const m = p.transformOf(b);
        const inv = invert(m) orelse return;
        // The source rect in painter space (x document, y scrolled), and
        // where the transform puts it on the canvas.
        const src: [4]f64 = .{ sb.x, sb.y - p.scroll, sb.x + sb.w, sb.y - p.scroll + sb.h };
        var dx0: f64 = std.math.inf(f64);
        var dy0: f64 = std.math.inf(f64);
        var dx1: f64 = -std.math.inf(f64);
        var dy1: f64 = -std.math.inf(f64);
        for ([_][2]f64{ .{ src[0], src[1] }, .{ src[2], src[1] }, .{ src[0], src[3] }, .{ src[2], src[3] } }) |c| {
            const q = apply(m, c[0], c[1]);
            dx0 = @min(dx0, q[0]);
            dy0 = @min(dy0, q[1]);
            dx1 = @max(dx1, q[0]);
            dy1 = @max(dy1, q[1]);
        }
        // Clamp to the canvas's clip (canvas x = painter x - dx).
        const cx0 = @max(@floor(dx0), @as(f64, @floatFromInt(p.canvas.clip_x0)) + p.dx);
        const cy0 = @max(@floor(dy0), @as(f64, @floatFromInt(p.canvas.clip_y0)));
        const cx1 = @min(@ceil(dx1), @as(f64, @floatFromInt(@min(p.canvas.clip_x1, p.canvas.w))) + p.dx);
        const cy1 = @min(@ceil(dy1), @as(f64, @floatFromInt(@min(p.canvas.clip_y1, p.canvas.h))));
        if (cx1 <= cx0 or cy1 <= cy0) return;
        // The part of the source that maps into it.
        var sx0: f64 = std.math.inf(f64);
        var sy0: f64 = std.math.inf(f64);
        var sx1: f64 = -std.math.inf(f64);
        var sy1: f64 = -std.math.inf(f64);
        for ([_][2]f64{ .{ cx0, cy0 }, .{ cx1, cy0 }, .{ cx0, cy1 }, .{ cx1, cy1 } }) |c| {
            const q = apply(inv, c[0], c[1]);
            sx0 = @min(sx0, q[0]);
            sy0 = @min(sy0, q[1]);
            sx1 = @max(sx1, q[0]);
            sy1 = @max(sy1, q[1]);
        }
        sx0 = @max(@floor(sx0) - 1, @floor(src[0]));
        sy0 = @max(@floor(sy0) - 1, @floor(src[1]));
        sx1 = @min(@ceil(sx1) + 1, @ceil(src[2]));
        sy1 = @min(@ceil(sy1) + 1, @ceil(src[3]));
        if (sx1 <= sx0 or sy1 <= sy0) return;
        const lw: usize = @intFromFloat(sx1 - sx0);
        const lh: usize = @intFromFloat(sy1 - sy0);
        if (lw == 0 or lh == 0 or lw * lh > layer_max_pixels) return p.paintPlain(id);
        const black = scratch.alloc(u32, lw * lh) catch return p.paintPlain(id);
        defer scratch.free(black);
        const white = scratch.alloc(u32, lw * lh) catch return p.paintPlain(id);
        defer scratch.free(white);
        for ([_][]u32{ black, white }, [_]u32{ 0x000000, 0xffffff }) |buf, bg| {
            const lc = Canvas.init(buf.ptr, lw, lh);
            lc.fillAll(bg);
            var q = p.*;
            q.canvas = lc;
            q.dx = sx0;
            q.scroll = p.scroll + sy0;
            q.layer_root = id;
            try q.paintPlain(id);
        }
        // Composite.
        const opacity = b.style.opacity;
        const clipped = b.style.clip_path != .none;
        var y = cy0;
        while (y < cy1) : (y += 1) {
            var x = cx0;
            while (x < cx1) : (x += 1) {
                const s = apply(inv, x + 0.5, y + 0.5);
                const u = s[0] - sx0;
                const v = s[1] - sy0;
                if (u < 0 or v < 0 or u >= @as(f64, @floatFromInt(lw)) or v >= @as(f64, @floatFromInt(lh))) continue;
                if (clipped and !clipInside(b, s[0], s[1] + p.scroll)) continue;
                const i = @as(usize, @intFromFloat(v)) * lw + @as(usize, @intFromFloat(u));
                const bl = black[i];
                const wh = white[i];
                var diff: u32 = 0;
                inline for (.{ 0, 8, 16 }) |shf| diff += ((wh >> shf) & 0xff) -| ((bl >> shf) & 0xff);
                const a = 1 - @as(f64, @floatFromInt(diff)) / (3 * 255);
                if (a <= 0.002) continue;
                var fg: u32 = 0;
                inline for (.{ 0, 8, 16 }) |shf| {
                    const c = @as(f64, @floatFromInt((bl >> shf) & 0xff)) / a;
                    fg |= @as(u32, @intFromFloat(@min(255, @round(c)))) << shf;
                }
                const cov = @min(1, a * opacity);
                p.canvas.blend(@intFromFloat(x - p.dx), @intFromFloat(y), fg, @intFromFloat(@round(cov * 255)));
            }
        }
    }

    const layer_max_pixels: usize = 1 << 20;

    fn paintPlain(p: *Painter, id: BoxId) Error!void {
        const b = p.l.get(id);
        if (b.style.display == .none) return;
        if (b.kind == .text or b.kind == .br) return;
        // A control paints itself — except a `button` element, whose
        // face is its style and whose content is laid out like any box's.
        if (b.node) |n| if (controlOf(p.l.doc, n)) |kind| if (!p.l.doc.isHtml(n, "button")) {
            p.control(b, n, kind);
            return;
        };
        // A picture (an `img`, an `object` whose data decoded, an inline
        // `svg`): its background and borders as any box's, then the
        // picture in its content box, and no children.
        var picture_bm: ?layout.Bitmap = null;
        if (b.node) |n| if (p.l.doc.isHtml(n, "img") or p.l.doc.isHtml(n, "object") or (p.l.doc.get(n).namespace == .svg and std.mem.eql(u8, p.l.doc.get(n).name, "svg"))) {
            if (p.l.images) |imgs| if (imgs.get(n)) |bm| {
                picture_bm = bm;
            };
        };
        // Backgrounds and borders on the border box (the root's are the
        // canvas's), then the picture, or the content in the order CSS
        // paints a stacking context's flow (Appendix E): every block's
        // background first, then the floats, then the inline content —
        // so a float covers the blocks beside it and text and atomics
        // paint over the float (Acid2's eyes: an object in a line sits
        // on a float, 2026-10-07).
        // A sticky box paints at its stuck offset, everything in it too.
        const saved_scroll = p.scroll;
        defer p.scroll = saved_scroll;
        if (b.style.position == .sticky) p.scroll -= layout.stickyOffset(p.l, id, p.scroll);
        if (b.kind != .root and (b.kind != .inline_box or picture_bm != null) and b.kind != .anon_block) p.paintSelf(b, id);
        if (picture_bm) |bm| {
            p.picture(b, bm);
            return;
        }
        const saved = p.canvas;
        p.clipTo(b);
        defer p.canvas = saved;
        try p.paintContent(id);
    }

    /// A box's content, as a unit: its positioned layer's negative
    /// z-indexes, its flow in the three phases, then the rest of the
    /// layer (CSS 2.1 Appendix E) — scrolled by its offset when it is a
    /// scroll container — then its scrollbar. The layer holds the
    /// relatively positioned and sticky boxes in its flow (each a unit
    /// of its own, not descended into), and the absolutely positioned
    /// boxes this box clips, or every unclipped one for the root.
    fn paintContent(p: *Painter, id: BoxId) Error!void {
        const b = p.l.get(id);
        const saved_scroll = p.scroll;
        defer p.scroll = saved_scroll;
        p.scroll += b.scroll_top;
        var layer: std.ArrayList(Layered) = .empty;
        try p.collectLayer(id, &layer);
        if (b.kind == .root) {
            for (p.l.absolutes.items) |ab| if (layout.clipAncestor(p.l, ab.box) == null) try layer.append(p.l.a, .{ .box = ab.box, .z = zOf(p.l, ab.box) });
        } else if (layout.clipsOverflow(b) or layout.isLayerBox(b)) {
            for (p.l.absolutes.items) |ab| if (layout.clipAncestor(p.l, ab.box) == id) try layer.append(p.l.a, .{ .box = ab.box, .z = zOf(p.l, ab.box) });
        }
        std.mem.sort(Layered, layer.items, {}, layerBelow);
        var i: usize = 0;
        while (i < layer.items.len and layer.items[i].z < 0) : (i += 1) try p.paintPositioned(layer.items[i].box);
        try p.paintFlow(id, .backgrounds);
        try p.paintFlow(id, .floats);
        try p.paintFlow(id, .inlines);
        while (i < layer.items.len) : (i += 1) try p.paintPositioned(layer.items[i].box);
        p.scroll = saved_scroll;
        if (layout.isScrollContainer(b)) p.scrollbar(b, id);
    }

    /// The relatively positioned and sticky block-level boxes of a
    /// unit's flow: the subtree, not entering another unit (a float, a
    /// clipping box, or a positioned box, each painting its own).
    fn collectLayer(p: *Painter, id: BoxId, out: *std.ArrayList(Layered)) Error!void {
        for (p.l.get(id).children.items) |c| {
            const cb = p.l.get(c);
            if (cb.isOutOfFlow() or !cb.isBlockLevel()) continue;
            if (cb.style.position == .relative or cb.style.position == .sticky or layout.isLayerBox(cb)) {
                try out.append(p.l.a, .{ .box = c, .z = zOf(p.l, c) });
                continue;
            }
            if (layout.clipsOverflow(cb)) continue;
            try p.collectLayer(c, out);
        }
    }

    /// A scroll container's vertical scrollbar: a thumb at the right
    /// edge of its padding box, when there is anything to scroll.
    fn scrollbar(p: *Painter, b: *const Box, id: BoxId) void {
        const max = layout.scrollMax(p.l, id);
        if (max <= 0) return;
        const inner_h = b.h - b.border[0] - b.border[2];
        const extent = layout.scrollExtent(p.l, id);
        if (extent <= 0 or inner_h <= 0) return;
        const thumb_h = @max(scrollbar_min, @floor(inner_h * inner_h / extent));
        const track_y = b.y + b.border[0];
        const thumb_y = track_y + @floor((inner_h - thumb_h) * (b.scroll_top / max));
        const x = b.x + b.w - b.border[1] - scrollbar_w;
        p.fill(x, thumb_y, scrollbar_w, thumb_h, scrollbar_color);
    }

    const scrollbar_w: f64 = 6;
    const scrollbar_min: f64 = 12;
    const scrollbar_color: u32 = 0x888888;

    /// A box's own background and borders.
    fn paintSelf(p: *Painter, b: *const Box, id: BoxId) void {
        const radii = p.radiiOf(b);
        const rounded = radii[0] > 0 or radii[1] > 0 or radii[2] > 0 or radii[3] > 0;
        if (!(isHtmlOrBody(p.l, id) and rootBackground(p.l) != null) and !p.maskedBackground(b)) {
            if (b.style.background_color.a > 0) {
                // Rounded or translucent: blended per pixel.
                if (rounded or b.style.background_color.a < 1) p.roundRect(b.x, b.y, b.w, b.h, radii, null, b.style.background_color) else p.fill(b.x, b.y, b.w, b.h, b.style.background_color.word());
            }
            p.backgroundImage(b);
        }
        if (rounded) p.roundBorders(b, radii) else p.borders(b);
    }

    /// Narrow the canvas's clip to the box's padding box when its
    /// overflow says so (the caller restores the canvas).
    fn clipTo(p: *Painter, b: *const Box) void {
        if (b.kind == .root) return;
        // Per axis: `clip` on one axis leaves the other visible; any
        // other non-visible value makes both clip (CSS Overflow §3.1).
        const ox = b.style.overflow_x;
        const oy = b.style.overflow_y;
        const clip_x = ox != .visible or (oy != .visible and oy != .clip);
        const clip_y = oy != .visible or (ox != .visible and ox != .clip);
        if (!clip_x and !clip_y) return;
        var x0 = b.x + b.border[3] - p.dx;
        var y0 = b.y + b.border[0] - p.scroll;
        var x1 = x0 + b.w - b.border[1] - b.border[3];
        var y1 = y0 + b.h - b.border[0] - b.border[2];
        if (ox == .clip or oy == .clip) {
            // `overflow-clip-margin`: the clip reaches past the box it
            // names by the margin.
            switch (b.style.overflow_clip_box) {
                .padding_box => {},
                .border_box => {
                    x0 -= b.border[3];
                    y0 -= b.border[0];
                    x1 += b.border[1];
                    y1 += b.border[2];
                },
                .content_box => {
                    x0 += b.padding[3];
                    y0 += b.padding[0];
                    x1 -= b.padding[1];
                    y1 -= b.padding[2];
                },
            }
            const m = b.style.overflow_clip_margin;
            x0 -= m;
            y0 -= m;
            x1 += m;
            y1 += m;
        }
        if (clip_x) {
            p.canvas.clip_x0 = @max(p.canvas.clip_x0, px(@max(0, x0)));
            p.canvas.clip_x1 = @min(p.canvas.clip_x1, px(@max(0, x1)));
        }
        if (clip_y) {
            p.canvas.clip_y0 = @max(p.canvas.clip_y0, px(@max(0, y0)));
            p.canvas.clip_y1 = @min(p.canvas.clip_y1, px(@max(0, y1)));
        }
    }

    const Phase = enum { backgrounds, floats, inlines };

    /// Whether a block-level box paints as one unit at the backgrounds
    /// phase (a control, a picture): its content is not a flow.
    fn isAtomicBlock(p: *const Painter, b: *const Box) bool {
        const n = b.node orelse return false;
        if (controlOf(p.l.doc, n)) |_| if (!p.l.doc.isHtml(n, "button")) return true;
        if (p.l.doc.isHtml(n, "img") or p.l.doc.isHtml(n, "object") or (p.l.doc.get(n).namespace == .svg and std.mem.eql(u8, p.l.doc.get(n).name, "svg"))) {
            if (p.l.images) |imgs| if (imgs.get(n) != null) return true;
        }
        return false;
    }

    /// One phase of a box's in-flow content: its block descendants'
    /// backgrounds, or the floats among them, or the lines.
    fn paintFlow(p: *Painter, id: BoxId, phase: Phase) Error!void {
        const b = p.l.get(id);
        for (b.children.items) |c| {
            const cb = p.l.get(c);
            if (cb.isFloat()) {
                if (phase == .floats) try p.paintBox(c);
                continue;
            }
            if (cb.isOutOfFlow()) continue;
            if (!cb.isBlockLevel()) continue;
            if (cb.style.visibility != .visible or cb.style.opacity == 0 or cb.style.display == .none) continue;
            // A relatively positioned or sticky box — or a layer box — is
            // in the unit's positioned layer, painted whole after the flow.
            if (cb.style.position == .relative or cb.style.position == .sticky or layout.isLayerBox(cb)) continue;
            if (p.isAtomicBlock(cb)) {
                if (phase == .backgrounds) try p.paintBox(c);
                continue;
            }
            const saved_scroll = p.scroll;
            if (phase == .backgrounds and cb.kind != .anon_block) p.paintSelf(cb, c);
            const saved = p.canvas;
            p.clipTo(cb);
            if (layout.clipsOverflow(cb)) {
                // Its content is a unit of its own: scrolled, clipped,
                // with the positioned boxes it clips — painted whole at
                // the backgrounds phase, since nothing of it may escape
                // to interleave with what is around it.
                if (phase == .backgrounds) try p.paintContent(c);
            } else {
                try p.paintFlow(c, phase);
            }
            p.canvas = saved;
            p.scroll = saved_scroll;
        }
        if (phase != .inlines) return;
        // Lines: inline backgrounds, then text and atomics in order — a
        // line wholly outside the clip band paints nothing (a band
        // repaint walks every box of the page).
        for (b.lines.items) |ln| {
            if (ln.y + ln.h - p.scroll <= @as(f64, @floatFromInt(p.canvas.clip_y0)) or ln.y - p.scroll >= @as(f64, @floatFromInt(p.canvas.clip_y1))) continue;
            for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| {
                const f = p.l.fragments.get(fi);
                if (f.kind == .inline_span) p.inlineSpan(f.*);
            }
            for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| {
                const f = p.l.fragments.get(fi);
                switch (f.kind) {
                    .text, .marker => p.text(f.*),
                    .atomic => try p.paintBox(f.box),
                    else => {},
                }
            }
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
            // A transparent border takes its room and paints nothing
            // (Acid2's picture frame, 2026-10-07).
            if (st.borderColor(side).a <= 0) continue;
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

    fn bullet(p: *const Painter, f: layout.Fragment, st: *const style.Computed) bool {
        const kind = bulletKind(f.text) orelse return false;
        const size = @max(3, @round(st.font_size * 0.36));
        // Whole pixels: a small shape is crisper on the grid.
        // Half an em before the marker's end (where the text starts).
        const x = @round(@max(f.x, f.x + f.w - st.font_size * 0.5 - size));
        const y = @round(f.baseline - st.font_size * 0.32 - size / 2);
        const r = size / 2;
        switch (kind) {
            'd' => p.roundRect(x, y, size, size, .{ r, r, r, r }, null, st.color),
            'c' => p.roundRect(x, y, size, size, .{ r, r, r, r }, .{ x + 1, y + 1, size - 2, size - 2, r - 1, r - 1, r - 1, r - 1 }, st.color),
            else => p.roundRect(x, y, size, size, .{ 0, 0, 0, 0 }, null, st.color),
        }
        return true;
    }

    /// A box's corner radii in pixels (a percentage of its width),
    /// shrunk together when two would overlap along a side.
    fn radiiOf(p: *const Painter, b: *const Box) [4]f64 {
        _ = p;
        var r: [4]f64 = undefined;
        for (0..4) |i| r[i] = @max(0, switch (b.style.border_radius[i]) {
            .px => |x| x,
            .percent => |pc| b.w * pc / 100,
            .calc => |m| m.of(b.w),
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

    /// A document rect's pixel rows and columns inside the canvas and its
    /// clip: [y0, y1) canvas rows, [x0, x1) columns.
    fn clipBounds(p: *const Painter, x: f64, y: f64, w: f64, h: f64) struct { x0: f64, x1: f64, y0: f64, y1: f64 } {
        return .{
            .y0 = @max(@as(f64, @floatFromInt(p.canvas.clip_y0)), @floor(y - p.scroll)),
            .y1 = @min(@as(f64, @floatFromInt(@min(p.canvas.h, p.canvas.clip_y1))), @ceil(y + h - p.scroll)),
            .x0 = @max(@as(f64, @floatFromInt(p.canvas.clip_x0)), @floor(x - p.dx)),
            .x1 = @min(@as(f64, @floatFromInt(@min(p.canvas.w, p.canvas.clip_x1))), @ceil(x + w - p.dx)),
        };
    }

    /// Fill a rounded rect (minus `hole`, another, for a border ring).
    fn roundRect(p: *const Painter, x: f64, y: f64, w: f64, h: f64, r: [4]f64, hole: ?[8]f64, c: color.Color) void {
        if (w <= 0 or h <= 0 or c.a <= 0) return;
        const word = c.word();
        const alpha = c.a;
        const cb = p.clipBounds(x, y, w, h);
        const y0 = cb.y0;
        const y1 = cb.y1;
        const x0 = cb.x0;
        const x1 = cb.x1;
        var sy = y0;
        while (sy < y1) : (sy += 1) {
            var sx = x0;
            while (sx < x1) : (sx += 1) {
                var cov = roundCover(x - p.dx, y - p.scroll, w, h, r, sx, sy);
                if (hole) |ho| if (cov > 0) {
                    cov -= roundCover(ho[0] - p.dx, ho[1] - p.scroll, ho[2], ho[3], .{ ho[4], ho[5], ho[6], ho[7] }, sx, sy);
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
    /// Where a picture's tiles go in a box: the first tile's corner,
    /// the tile size, whether it repeats on each axis.
    const Tiles = struct { x: f64, y: f64, w: f64, h: f64, rep_x: bool, rep_y: bool };

    /// A layer's tiles (a background's or a mask's) in the padding box:
    /// sized by `size` from the picture's natural size, placed by
    /// `position`, started early enough to cover the border box when it
    /// repeats. Null when it has no size.
    fn tilesFor(area: Area, bm: layout.Bitmap, size: style.BackgroundSize, position: [2]style.LengthPercent, repeat: [2]bool) ?Tiles {
        const ax = area.x;
        const ay = area.y;
        const aw = area.w;
        const ah = area.h;
        if (aw <= 0 or ah <= 0 or bm.w == 0 or bm.h == 0) return null;
        const scale = style.px_scale / bm.density;
        const nw = @as(f64, @floatFromInt(bm.w)) * scale;
        const nh = @as(f64, @floatFromInt(bm.h)) * scale;
        var tw = nw;
        var th = nh;
        switch (size) {
            .auto => {},
            .cover, .contain => {
                const f = if (size == .cover) @max(aw / nw, ah / nh) else @min(aw / nw, ah / nh);
                tw = nw * f;
                th = nh * f;
            },
            .size => |sz| {
                const w_: ?f64 = switch (sz[0]) {
                    .px => |x| x,
                    .percent => |pc| aw * pc / 100,
                    .calc => |m| m.of(aw),
                    .auto => null,
                };
                const h_: ?f64 = switch (sz[1]) {
                    .px => |x| x,
                    .percent => |pc| ah * pc / 100,
                    .calc => |m| m.of(ah),
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
        if (tw < 0.5 or th < 0.5) return null;
        const off_x = switch (position[0]) {
            .px => |x| x,
            .percent => |pc| (aw - tw) * pc / 100,
            .calc => |m| m.of(aw - tw),
        };
        const off_y = switch (position[1]) {
            .px => |x| x,
            .percent => |pc| (ah - th) * pc / 100,
            .calc => |m| m.of(ah - th),
        };
        var t: Tiles = .{ .x = ax + off_x, .y = ay + off_y, .w = tw, .h = th, .rep_x = repeat[0], .rep_y = repeat[1] };
        if (t.rep_x) t.x -= @ceil((t.x - ax) / tw) * tw;
        if (t.rep_y) t.y -= @ceil((t.y - ay) / th) * th;
        return t;
    }

    /// A painter clipped to a box's border box.
    fn clippedTo(p: *const Painter, b: *const Box) ?Painter {
        var q = p.*;
        q.canvas.clip_x0 = @max(q.canvas.clip_x0, px(@max(0, b.x - p.dx)));
        q.canvas.clip_x1 = @min(q.canvas.clip_x1, px(@max(0, b.x + b.w - p.dx)));
        q.canvas.clip_y0 = @max(q.canvas.clip_y0, px(@max(0, b.y - p.scroll)));
        q.canvas.clip_y1 = @min(q.canvas.clip_y1, px(@max(0, b.y + b.h - p.scroll)));
        if (q.canvas.clip_x1 <= q.canvas.clip_x0 or q.canvas.clip_y1 <= q.canvas.clip_y0) return null;
        return q;
    }

    /// The `background-image` layer: a picture placed in the padding box
    /// by `background-position` and `-size`, tiled by `-repeat`, clipped
    /// to the border box; or a linear gradient over it.
    fn backgroundImage(p: *const Painter, b: *const Box) void {
        const st = b.style;
        const area = p.backgroundArea(b);
        switch (st.background_image) {
            .none => return,
            .linear => |g| return p.gradient(area, b, g.angle, g.stops, g.repeating),
            .url => {},
        }
        const imgs = p.l.images orelse return;
        const bm = imgs.background(st.background_image.url, st.background_base) orelse return;
        const t = tilesFor(area, bm, st.background_size, st.background_position, st.background_repeat) orelse return;
        const q = p.clippedTo(b) orelse return;
        // Tiles from the area's origin, as far as the box reaches (an
        // area above the box — the viewport, scrolled — starts them
        // where they would land).
        var ty = t.y;
        var rows: usize = 0;
        while (ty < b.y + b.h and rows < 4096) : (rows += 1) {
            if (t.rep_y and ty + t.h <= b.y) {
                ty += t.h * @floor((b.y - ty) / t.h);
            }
            var tx = t.x;
            var cols: usize = 0;
            if (t.rep_x and tx + t.w <= b.x) tx += t.w * @floor((b.x - tx) / t.w);
            while (tx < b.x + b.w and cols < 4096) : (cols += 1) {
                q.bitmap(bm, tx, ty - p.scroll, t.w, t.h, 0, 0, @floatFromInt(bm.w), @floatFromInt(bm.h));
                if (!t.rep_x) break;
                tx += t.w;
            }
            if (!t.rep_y) break;
            ty += t.h;
        }
    }

    /// An element with a `mask-image`: its background colour shows
    /// through the mask's alpha (the icons a design system draws in
    /// `currentColor`). A mask that has not loaded shows nothing, as in
    /// browsers. True when the mask decided the background.
    fn maskedBackground(p: *const Painter, b: *const Box) bool {
        const st = b.style;
        if (st.mask_image != .url) return false;
        const imgs = p.l.images orelse return true;
        const bm = imgs.background(st.mask_image.url, st.mask_base) orelse return true;
        const c = st.background_color;
        if (c.a <= 0) return true;
        const t = tilesFor(.{ .x = b.x + b.border[3], .y = b.y + b.border[0], .w = b.w - b.border[1] - b.border[3], .h = b.h - b.border[0] - b.border[2] }, bm, st.mask_size, st.mask_position, st.mask_repeat) orelse return true;
        const q = p.clippedTo(b) orelse return true;
        const word = c.word();
        var ty = t.y;
        var rows: usize = 0;
        while (ty < b.y + b.h and rows < 4096) : (rows += 1) {
            var tx = t.x;
            var cols: usize = 0;
            while (tx < b.x + b.w and cols < 4096) : (cols += 1) {
                // The tile's pixels, each the mask's alpha at its centre.
                const x0 = @max(@as(f64, @floatFromInt(q.canvas.clip_x0)), @floor(tx - p.dx));
                const x1 = @min(@as(f64, @floatFromInt(q.canvas.clip_x1)), @ceil(tx + t.w - p.dx));
                const y0 = @max(@as(f64, @floatFromInt(q.canvas.clip_y0)), @floor(ty - p.scroll));
                const y1 = @min(@as(f64, @floatFromInt(@min(q.canvas.clip_y1, q.canvas.h))), @ceil(ty - p.scroll + t.h));
                var sy = y0;
                while (sy < y1) : (sy += 1) {
                    var sx = x0;
                    while (sx < x1) : (sx += 1) {
                        const u = (sx + p.dx + 0.5 - tx) / t.w * @as(f64, @floatFromInt(bm.w)) - 0.5;
                        const v = (sy + 0.5 - (ty - p.scroll)) / t.h * @as(f64, @floatFromInt(bm.h)) - 0.5;
                        const alpha = sampleAlpha(bm, u, v);
                        if (alpha <= 0) continue;
                        q.canvas.blend(@intFromFloat(sx), @intFromFloat(sy), word, @intFromFloat(@round(alpha * c.a * 255)));
                    }
                }
                if (!t.rep_x) break;
                tx += t.w;
            }
            if (!t.rep_y) break;
            ty += t.h;
        }
        return true;
    }

    /// A bitmap's alpha at source coordinates (pixel centres at .5),
    /// bilinear; 0 outside.
    fn sampleAlpha(bm: layout.Bitmap, u: f64, v: f64) f64 {
        const fw: f64 = @floatFromInt(bm.w);
        const fh: f64 = @floatFromInt(bm.h);
        if (u < -0.5 or v < -0.5 or u > fw - 0.5 or v > fh - 0.5) return 0;
        const uc = std.math.clamp(u, 0, fw - 1);
        const vc = std.math.clamp(v, 0, fh - 1);
        const x0: u32 = @intFromFloat(@floor(uc));
        const y0: u32 = @intFromFloat(@floor(vc));
        const x1 = @min(bm.w - 1, x0 + 1);
        const y1 = @min(bm.h - 1, y0 + 1);
        const ax = uc - @floor(uc);
        const ay = vc - @floor(vc);
        const at = struct {
            fn f(m: layout.Bitmap, x: u32, y: u32) f64 {
                return @as(f64, @floatFromInt(m.rgba[(@as(usize, y) * m.w + x) * 4 + 3])) / 255;
            }
        }.f;
        return at(bm, x0, y0) * (1 - ax) * (1 - ay) + at(bm, x1, y0) * ax * (1 - ay) + at(bm, x0, y1) * (1 - ax) * ay + at(bm, x1, y1) * ax * ay;
    }

    /// A linear gradient over the border box: the colour at each pixel
    /// from its projection on the gradient line (CSS's length for the
    /// angle), stops interpolated in straight sRGB.
    /// A linear gradient over `area`, painted inside the box `b`.
    fn gradient(p: *const Painter, area: Area, b: *const Box, angle: f64, stops: []const style.Stop, repeating: bool) void {
        if (stops.len == 0 or area.w <= 0 or area.h <= 0) return;
        const rad = angle * std.math.pi / 180;
        const dx = @sin(rad);
        const dy = -@cos(rad);
        const len = @abs(area.w * dx) + @abs(area.h * dy);
        if (len <= 0) return;
        // Stop positions as fractions, the unplaced spread between the
        // placed (CSS Images §3.5.1).
        var pos_buf: [32]f64 = undefined;
        const n = @min(stops.len, pos_buf.len);
        const pos = pos_buf[0..n];
        for (stops[0..n], 0..) |st, i| pos[i] = if (st.at) |at| switch (at) {
            .px => |x| x / len,
            .percent => |pc| pc / 100,
            .calc => |m| m.of(len) / len,
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
        const cxm = area.x + area.w / 2;
        const cym = area.y + area.h / 2;
        const cb = p.clipBounds(b.x, b.y, b.w, b.h);
        const y0 = cb.y0;
        const y1 = cb.y1;
        const x0 = cb.x0;
        const x1 = cb.x1;
        var sy = y0;
        while (sy < y1) : (sy += 1) {
            var sx = x0;
            while (sx < x1) : (sx += 1) {
                var t = ((sx + p.dx + 0.5 - cxm) * dx + (sy + 0.5 + p.scroll - cym) * dy) / len + 0.5;
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
        const ox: i64 = @intFromFloat(@round(x - p.dx));
        const oy: i64 = @intFromFloat(@round(y));
        const exact = @abs(sw - w) < 0.01 and @abs(sh - h) < 0.01;
        const fx = sw / @as(f64, @floatFromInt(dw));
        const fy = sh / @as(f64, @floatFromInt(dh));
        const cx0: i64 = @intCast(p.canvas.clip_x0);
        const cx1: i64 = @intCast(p.canvas.clip_x1);
        const cy0: i64 = @intCast(p.canvas.clip_y0);
        const cy1: i64 = @intCast(@min(p.canvas.h, p.canvas.clip_y1));
        var yy: usize = 0;
        while (yy < dh) : (yy += 1) {
            const ty = oy + @as(i64, @intCast(yy));
            if (ty < cy0) continue;
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
        const x0: usize = px(@max(0, h.x - p.dx));
        const y0f = h.y - p.scroll;
        if (y0f + h.h <= 0 or h.w <= 0 or h.h <= 0) return;
        const y0: usize = px(@max(0, y0f));
        const x1: usize = px(@max(0, h.x + h.w - p.dx));
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
        for (0..p.l.boxes.len) |i| {
            const b = p.l.boxes.get(i);
            if (b.node != node) continue;
            switch (b.kind) {
                .inline_box, .text => for (0..p.l.fragments.len) |fi| {
                    const f = p.l.fragments.get(fi);
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
                if (doc.isChecked(node)) p.fill(b.x + 3, b.y + 3, @max(1, b.w - 6), @max(1, b.h - 6), p.opts.accent);
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
        q.canvas.clip_x0 = @max(q.canvas.clip_x0, px(@max(0, cx - p.dx)));
        q.canvas.clip_x1 = @min(q.canvas.clip_x1, px(@max(0, cx + cw - p.dx)));
        const inner_h = m.ascent + m.descent;
        const baseline = if (kind == .textarea) cy + m.ascent else cy + (ch - inner_h) / 2 + m.ascent;
        const tx = if (kind == .button) cx + @max(0, (cw - p.l.fonts.advance(font, value)) / 2) else cx;
        // An empty field shows its placeholder, greyed.
        if (value.len == 0 and (kind == .text or kind == .textarea or kind == .password)) if (doc.getAttr(node, "placeholder")) |ph| {
            p.l.fonts.draw(&q.canvas, font, tx - p.dx, baseline - p.scroll, ph, 0x757575);
            return;
        };
        p.l.fonts.draw(&q.canvas, font, tx - p.dx, baseline - p.scroll, value, st.color.word());
        if (kind == .select) p.l.fonts.draw(&q.canvas, font, cx + cw - p.l.fonts.advance(font, "v") - p.dx, baseline - p.scroll, "v", p.opts.frame);
    }

    fn text(p: *const Painter, f: layout.Fragment) void {
        const b = p.l.get(f.box);
        const st = b.style;
        const font = layout.fontOf(st);
        const word = st.color.word();
        if (f.text.len == 0) return;
        // Outside the clip: nothing to draw, and no glyph to rasterize.
        const top = f.y - p.scroll;
        if (top >= @as(f64, @floatFromInt(p.canvas.clip_y1)) or top + f.h <= @as(f64, @floatFromInt(p.canvas.clip_y0))) return;
        if (f.x >= @as(f64, @floatFromInt(p.canvas.clip_x1)) or f.x + f.w <= @as(f64, @floatFromInt(p.canvas.clip_x0))) return;
        // Text takes its box's visibility (a hidden header link inside a
        // visible heading).
        if (st.visibility != .visible) return;
        if (f.kind == .marker) if (p.bullet(f, st)) return;
        p.l.fonts.draw(&p.canvas, font, f.x - p.dx, f.baseline - p.scroll, f.text, word);
        // Decorations: one pixel lines, or thicker with the font.
        const thick = @max(1, @round(st.font_size / 16));
        if (st.text_decoration.underline) p.fill(f.x, f.baseline + 1, f.w, thick, word);
        if (st.text_decoration.line_through) p.fill(f.x, f.baseline - st.font_size * 0.3, f.w, thick, word);
        if (st.text_decoration.overline) p.fill(f.x, f.y, f.w, thick, word);
    }
};

/// A bullet marker painted as a shape (a disc, a circle, a square), as
/// browsers draw them — their glyphs are not in every face. False for a
/// counter, which is text.
fn bulletKind(text: []const u8) ?u8 {
    if (std.mem.startsWith(u8, text, "\u{2022}")) return 'd';
    if (std.mem.startsWith(u8, text, "\u{25e6}")) return 'c';
    if (std.mem.startsWith(u8, text, "\u{25aa}")) return 's';
    return null;
}

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
const url = @import("url.zig");
const image = @import("../image.zig");

/// Render a page into a fresh white canvas of `w`×`h` with the test fonts.
pub fn renderForTest(a: std.mem.Allocator, src: []const u8, w: usize, h: usize) ![]u32 {
    return renderForTestWith(a, src, w, h, .{});
}

pub const RenderOpts = struct {
    /// Pictures for the page's `img`/`object` and backgrounds (the test
    /// harness decodes `data:` URLs through `TestImages`).
    images: ?layout.Images = null,
    /// Scroll so the element with this id has its border box's top at
    /// the viewport's (`scrollIntoView`), before painting.
    scroll_to: ?[]const u8 = null,
    /// A directory the page's linked stylesheets are read from, by
    /// relative path (absolute `/fonts/…` and `/css/…` paths are not:
    /// the Ahem face is built into the test fonts).
    dir: ?std.Io.Dir = null,
};

/// Linked stylesheets read beside the page, for the WPT tests.
const DirLoader = struct {
    a: std.mem.Allocator,
    dir: std.Io.Dir,

    fn loader(d: *DirLoader) style.Loader {
        return .{ .ctx = @ptrCast(d), .fetch = fetch };
    }

    fn fetch(ctx: *anyopaque, href: []const u8, base: ?[]const u8) ?style.Loader.Loaded {
        const d: *DirLoader = @ptrCast(@alignCast(ctx));
        if (href.len == 0 or href[0] == '/' or std.mem.startsWith(u8, href, "http")) return null;
        const path = if (base) |b| (std.fs.path.join(d.a, &.{ std.fs.path.dirname(b) orelse ".", href }) catch return null) else href;
        const text = d.dir.readFileAlloc(std.testing.io, path, d.a, .limited(1 << 20)) catch return null;
        return .{ .text = text, .url = path };
    }
};

pub fn renderForTestWith(a: std.mem.Allocator, src: []const u8, w: usize, h: usize, opts: RenderOpts) ![]u32 {
    const doc = try html.parse(a, src, .{});
    const env: style.Env = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
    const sheets = if (opts.dir) |d| blk: {
        var dl: DirLoader = .{ .a = a, .dir = d };
        break :blk try style.collectDocumentSheetsLoading(a, doc, env, try style.parseSheet(a, style.ua_sheet, .user_agent, env), dl.loader());
    } else try style.collectDocumentSheets(a, doc, env);
    const styles = try a.create(style.Styles);
    styles.* = try style.compute(a, doc, sheets, env);
    var fixed: layout.FixedFonts = .{};
    const l = try layout.layoutDocumentWith(a, doc, styles, fixed.fonts(), opts.images, @floatFromInt(w), @floatFromInt(h));
    var scroll: f64 = 0;
    if (opts.scroll_to) |want| {
        var n: usize = 0;
        const target: ?dom.NodeId = while (n < doc.nodes.len) : (n += 1) {
            const nid: dom.NodeId = @intCast(n);
            if (doc.get(nid).kind == .element) if (doc.getAttr(nid, "id")) |v| if (std.mem.eql(u8, v, want)) break nid;
        } else null;
        if (target) |t| {
            var bi: usize = 0;
            while (bi < l.boxes.len) {
                const run = l.boxes.slice(bi);
                bi += run.len;
                for (run) |*b| if (b.node == t and b.kind != .text) {
                    // Whole pixels, as a browser scrolls.
                    scroll = @round(@max(0, @min(b.y, l.height - @as(f64, @floatFromInt(h)))));
                    break;
                };
            }
        }
    }
    const px = try a.alloc(u32, w * h);
    const canvas = Canvas.init(px.ptr, w, h);
    canvas.fillAll(0xffffff);
    try paintWith(l, &canvas, scroll, .{ .scratch = a });
    return px;
}

/// Pictures for a test page: `data:` URLs decoded (the `src` of an
/// `img`, the `data` of an `object`, a background's url), anything
/// else missing — an `object` naming a URL that is not a picture falls
/// back, as it would for a 404.
pub const TestImages = struct {
    a: std.mem.Allocator,
    doc: *const dom.Document,
    cache: std.ArrayList(Entry) = .empty,

    const Entry = struct { key: []const u8, bm: ?layout.Bitmap };

    pub fn images(t: *TestImages) layout.Images {
        return .{ .ctx = @ptrCast(t), .vtable = &.{ .get = get, .background = background } };
    }

    fn decode(t: *TestImages, href: []const u8) ?layout.Bitmap {
        for (t.cache.items) |e| if (std.mem.eql(u8, e.key, href)) return e.bm;
        const bm: ?layout.Bitmap = blk: {
            const data = (url.decodeData(t.a, href) catch null) orelse break :blk null;
            if (!std.mem.startsWith(u8, data.mime, "image/")) break :blk null;
            const img = image.decode(t.a, data.bytes) catch break :blk null;
            break :blk .{ .w = img.w, .h = img.h, .rgba = img.rgba };
        };
        t.cache.append(t.a, .{ .key = t.a.dupe(u8, href) catch return null, .bm = bm }) catch {};
        return bm;
    }

    fn get(ctx: *anyopaque, node: dom.NodeId) ?layout.Bitmap {
        const t: *TestImages = @ptrCast(@alignCast(ctx));
        const n = t.doc.get(node);
        if (n.kind != .element) return null;
        const attr = if (std.mem.eql(u8, n.name, "object")) "data" else "src";
        const href = t.doc.getAttr(node, attr) orelse return null;
        return t.decode(href);
    }

    fn background(ctx: *anyopaque, href: []const u8, base: ?[]const u8) ?layout.Bitmap {
        _ = base;
        const t: *TestImages = @ptrCast(@alignCast(ctx));
        return t.decode(href);
    }
};

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
test "paint: a clipped repaint leaves the rows outside the clip alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "<!DOCTYPE html><body style='margin:0;background:#abcdef'><p style='margin:0;height:200px'>text</p><p>more text</p>";
    const w: usize = 120;
    const h: usize = 100;
    const doc = try html.parse(a, src, .{});
    const env: style.Env = .{ .width = @floatFromInt(w), .height = @floatFromInt(h) };
    const sheets = try style.collectDocumentSheets(a, doc, env);
    const styles = try a.create(style.Styles);
    styles.* = try style.compute(a, doc, sheets, env);
    var fixed: layout.FixedFonts = .{};
    const l = try layout.layoutDocument(a, doc, styles, fixed.fonts(), @floatFromInt(w), @floatFromInt(h));
    const px = try a.alloc(u32, w * h);
    var canvas = Canvas.init(px.ptr, w, h);
    canvas.fillAll(0x123456); // the rows a scroll moved into place
    canvas.clip_y0 = h / 2; // the band that came in
    try paint(l, &canvas, 0);
    for (px[0 .. w * (h / 2)]) |v| try std.testing.expectEqual(@as(u32, 0x123456), v);
    try std.testing.expectEqual(@as(u32, 0xabcdef), px[w * (h / 2) + 1]);
}

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
        if (diff == null) passed += 1 else if (verbose) {
            std.debug.print("--- {s}: first difference at ({d}, {d}): {x:0>6} vs {x:0>6}\n", .{ name, diff.? % w, diff.? / w, got[diff.?] & 0xffffff, want[diff.?] & 0xffffff });
            printBounds(got, want, w, h);
        }
    }
    std.debug.print("reftests: {d}/{d} agree\n", .{ passed, names.items.len });
    try std.testing.expectEqual(names.items.len, passed);
    try std.testing.expect(names.items.len >= 16);
}

// Acid2 (tools/fetch-acid2.sh into tools/testdata/acid2, ignored by git):
// the test scrolled to its "Hello World!" anchor on the 400×300 canvas
// of WPT's reftest wrapper, against the pixel-for-pixel CSS reference.
// The count of differing pixels is printed; both renders are written
// as PPMs under zig-out when they differ.
test "paint: Acid2 against its pixel reference" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var dir = std.Io.Dir.cwd().openDir(io, "tools/testdata/acid2", .{}) catch {
        std.debug.print("acid2 (host): not fetched (tools/fetch-acid2.sh); skipped\n", .{});
        return error.SkipZigTest;
    };
    defer dir.close(io);
    const test_src = try dir.readFileAlloc(io, "test.html", a, .limited(1 << 20));
    const ref_src = try dir.readFileAlloc(io, "px-reference.html", a, .limited(1 << 20));
    const w: usize = 400;
    const h: usize = 300;
    // The pictures: the document is parsed once more for the image
    // source (the harness parses its own copy to render).
    const doc = try html.parse(a, test_src, .{});
    var ti: TestImages = .{ .a = a, .doc = doc };
    const got = try renderForTestWith(a, test_src, w, h, .{ .images = ti.images(), .scroll_to = "top" });
    const ref_doc = try html.parse(a, ref_src, .{});
    var ri: TestImages = .{ .a = a, .doc = ref_doc };
    const want = try renderForTestWith(a, ref_src, w, h, .{ .images = ri.images() });
    var differ: usize = 0;
    var first: ?usize = null;
    for (got, want, 0..) |g, r, i| if ((g & 0xffffff) != (r & 0xffffff)) {
        differ += 1;
        if (first == null) first = i;
    };
    if (differ == 0) {
        std.debug.print("acid2 (host): agrees with its reference\n", .{});
    } else {
        std.debug.print("acid2 (host): {d} of {d} pixels differ, first at ({d}, {d})\n", .{ differ, w * h, first.? % w, first.? / w });
        for ([_][]const u8{ "zig-out/acid2-got.ppm", "zig-out/acid2-want.ppm" }, [_][]const u32{ got, want }) |path, pix| {
            var ppm: std.ArrayList(u8) = .empty;
            try ppm.print(a, "P6\n{d} {d}\n255\n", .{ w, h });
            for (pix) |v| try ppm.appendSlice(a, &.{ @intCast((v >> 16) & 0xff), @intCast((v >> 8) & 0xff), @intCast(v & 0xff) });
            std.Io.Dir.cwd().writeFile(io, .{ .sub_path = path, .data = ppm.items }) catch {};
        }
    }
    try std.testing.expectEqual(@as(usize, 0), differ);
}

// The WPT reftests (tools/fetch-wpt.sh into tools/testdata/wpt, ignored
// by git): every listed test rendered beside the reference its
// `rel=match` names on an 800×600 canvas with the Ahem face; a count per
// module is printed, never asserted — the number is the measurement.
// Tests with scripts, or a `reftest-wait`, are skipped.
test "paint: the WPT reftest subsets, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var root = std.Io.Dir.cwd().openDir(io, "tools/testdata/wpt", .{ .iterate = true }) catch {
        std.debug.print("wpt: not fetched (tools/fetch-wpt.sh); skipped\n", .{});
        return error.SkipZigTest;
    };
    defer root.close(io);
    var mods: std.ArrayList([]const u8) = .empty;
    var it = root.iterate();
    while (try it.next(io)) |entry| if (entry.kind == .directory and std.mem.startsWith(u8, entry.name, "css-")) try mods.append(a, try a.dupe(u8, entry.name));
    std.mem.sort([]const u8, mods.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f);
    for (mods.items) |mod| {
        var dir = try root.openDir(io, mod, .{ .iterate = true });
        defer dir.close(io);
        var names: std.ArrayList([]const u8) = .empty;
        var di = dir.iterate();
        while (try di.next(io)) |entry| {
            if (entry.kind != .file or !std.mem.endsWith(u8, entry.name, ".html") or std.mem.indexOf(u8, entry.name, "-ref") != null) continue;
            try names.append(a, try a.dupe(u8, entry.name));
        }
        std.mem.sort([]const u8, names.items, {}, struct {
            fn f(_: void, x: []const u8, y: []const u8) bool {
                return std.mem.order(u8, x, y) == .lt;
            }
        }.f);
        var passed: usize = 0;
        var total: usize = 0;
        for (names.items) |name| {
            const test_src = try dir.readFileAlloc(io, name, a, .limited(1 << 20));
            if (std.mem.indexOf(u8, test_src, "<script") != null or std.mem.indexOf(u8, test_src, "reftest-wait") != null) continue;
            const ref_rel = matchRef(test_src) orelse continue;
            // The reference, relative to the test (`../reference/x` too).
            const ref_src = root.readFileAlloc(io, try std.fs.path.join(a, &.{ mod, ref_rel }), a, .limited(1 << 20)) catch continue;
            total += 1;
            const w: usize = 800;
            const h: usize = 600;
            const got = try renderForTestWith(a, test_src, w, h, .{ .dir = dir });
            const want = try renderForTestWith(a, ref_src, w, h, .{ .dir = dir });
            var diff: ?usize = null;
            for (got, want, 0..) |g, r, i| if ((g & 0xffffff) != (r & 0xffffff)) {
                diff = i;
                break;
            };
            if (diff == null) passed += 1 else if (verbose) {
                std.debug.print("--- wpt/{s}/{s}: first difference at ({d}, {d}): {x:0>6} vs {x:0>6}\n", .{ mod, name, diff.? % w, diff.? / w, got[diff.?] & 0xffffff, want[diff.?] & 0xffffff });
                printBounds(got, want, w, h);
            }
        }
        std.debug.print("wpt/{s}: {d}/{d} agree\n", .{ mod, passed, total });
    }
}

/// Where each render painted anything but white, as a bounding box.
fn printBounds(got: []const u32, want: []const u32, w: usize, h: usize) void {
    for ([_][]const u32{ got, want }, [_][]const u8{ "got", "want" }) |pix, label| {
        var x0: usize = w;
        var y0: usize = h;
        var x1: usize = 0;
        var y1: usize = 0;
        for (pix, 0..) |v, i| if (v & 0xffffff != 0xffffff) {
            x0 = @min(x0, i % w);
            x1 = @max(x1, i % w + 1);
            y0 = @min(y0, i / w);
            y1 = @max(y1, i / w + 1);
        };
        std.debug.print("    {s}: painted ({d},{d})-({d},{d})\n", .{ label, x0, y0, x1, y1 });
    }
}

/// The `rel=match` reference a WPT test names (the first).
fn matchRef(src: []const u8) ?[]const u8 {
    var at: usize = 0;
    while (std.mem.indexOfPos(u8, src, at, "<link")) |i| {
        const end = std.mem.indexOfScalarPos(u8, src, i, '>') orelse return null;
        const tag = src[i..end];
        at = end;
        if (std.mem.indexOf(u8, tag, "rel=\"match\"") == null and std.mem.indexOf(u8, tag, "rel=match") == null) continue;
        const hp = std.mem.indexOf(u8, tag, "href=") orelse continue;
        var v = tag[hp + 5 ..];
        if (v.len > 0 and v[0] == '"') {
            v = v[1..];
            const q = std.mem.indexOfScalar(u8, v, '"') orelse continue;
            return v[0..q];
        }
        const sp = std.mem.indexOfAny(u8, v, " \t\r\n/>") orelse v.len;
        return v[0..sp];
    }
    return null;
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
