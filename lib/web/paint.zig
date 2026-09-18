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
        if (b.node) |n| if (controlOf(p.l.doc, n)) |kind| {
            p.control(b, n, kind);
            return;
        };
        // Backgrounds and borders on the border box (the root's are the
        // canvas's).
        if (b.kind != .root and b.kind != .inline_box and b.kind != .anon_block) {
            if (!(isHtmlOrBody(p.l, id) and rootBackground(p.l) != null)) {
                if (b.style.background_color.a > 0) p.fill(b.x, b.y, b.w, b.h, b.style.background_color.word());
            }
            p.borders(b);
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
            .text, .password, .textarea, .select => {
                p.fill(b.x, b.y, b.w, b.h, if (st.background_color.a > 0) st.background_color.word() else white);
                p.stroke(b.x, b.y, b.w, b.h, 1, p.opts.frame);
                var value: []const u8 = if (kind == .textarea) (doc.textContent(node, p.l.a) catch "") else (doc.getAttr(node, "value") orelse "");
                if (kind == .textarea) if (doc.getAttr(node, "value")) |v| {
                    value = v;
                };
                if (kind == .select) value = selectedOption(doc, node);
                var dots: [64]u8 = undefined;
                if (kind == .password) {
                    const n = @min(value.len, dots.len);
                    @memset(dots[0..n], '*');
                    value = dots[0..n];
                }
                // The text sits on the control's centre line; what does not
                // fit is cut at the frame.
                const saved = p.canvas;
                var clipped = p.canvas;
                clipped.clip_x0 = @max(clipped.clip_x0, px(@max(0, b.x + 2)));
                clipped.clip_x1 = @min(clipped.clip_x1, px(@max(0, b.x + b.w - 2)));
                const inner_h = m.ascent + m.descent;
                const baseline = b.y + (b.h - inner_h) / 2 + m.ascent;
                var q = p.*;
                q.canvas = clipped;
                p.l.fonts.draw(&q.canvas, font, b.x + 4, baseline - p.scroll, value, st.color.word());
                if (kind == .select) p.l.fonts.draw(&q.canvas, font, b.x + b.w - 4 - p.l.fonts.advance(font, "v"), baseline - p.scroll, "v", p.opts.frame);
                _ = saved;
            },
            .checkbox, .radio => {
                p.fill(b.x, b.y, b.w, b.h, white);
                p.stroke(b.x, b.y, b.w, b.h, 1, p.opts.frame);
                if (doc.hasAttr(node, "checked")) p.fill(b.x + 3, b.y + 3, @max(1, b.w - 6), @max(1, b.h - 6), p.opts.accent);
            },
            .button => {
                p.fill(b.x, b.y, b.w, b.h, if (st.background_color.a > 0) st.background_color.word() else p.opts.face);
                p.stroke(b.x, b.y, b.w, b.h, 1, p.opts.frame);
                var label: []const u8 = doc.getAttr(node, "value") orelse "";
                if (doc.isHtml(node, "button")) label = doc.textContent(node, p.l.a) catch "";
                if (label.len == 0) label = "Submit";
                const tw = p.l.fonts.advance(font, label);
                const inner_h = m.ascent + m.descent;
                const baseline = b.y + (b.h - inner_h) / 2 + m.ascent;
                p.l.fonts.draw(&p.canvas, font, b.x + @max(0, (b.w - tw) / 2), baseline - p.scroll, label, st.color.word());
            },
        }
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
