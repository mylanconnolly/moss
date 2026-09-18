//! Layout: CSS 2.1's visual formatting model over the DOM and its
//! computed styles — the box tree (block and inline boxes, text runs,
//! anonymous blocks around inline runs, list markers), block formatting
//! (widths from the containing block, `auto` margins, margin collapsing
//! between siblings and through parents, floats with `clear`, block
//! formatting context roots, shrink-to-fit from intrinsic widths),
//! inline formatting (white-space processing, line boxes filled
//! greedily at the break opportunities a Latin/CJK text has, inline
//! boxes with their padding and borders across lines, atomic inlines,
//! vertical alignment on the line, `text-align` including `justify`,
//! `text-indent`), and relative and absolute positioning. Text is
//! measured through `Fonts`, an interface the page domain implements
//! over its typefaces and a test over fixed cells, so the whole engine
//! runs on the host. Coordinates are document pixels as `f64`; the
//! painter rounds.
//!
//! Not built (the arc's stage 9): tables beyond block-ified rows and
//! inline-block cells, flexbox and grid, `position: sticky` beyond
//! relative, bidi and complex shaping, hyphenation, `overflow: scroll`
//! scrolling inside a box.
const std = @import("std");
const dom = @import("dom.zig");
const style = @import("style.zig");
const ui = @import("../ui.zig");

pub const Error = error{OutOfMemory};
pub const Document = dom.Document;
pub const NodeId = dom.NodeId;
const Computed = style.Computed;

// ---------------------------------------------------------------- fonts

pub const Font = struct {
    size: f64,
    weight: u16 = 400,
    italic: bool = false,
    monospace: bool = false,
    serif: bool = false,
    /// The computed `font-family` list, first choice first: a provider
    /// with faces of its own (`@font-face`) picks by name.
    families: []const []const u8 = &.{},
};

/// A picture the page has for an element: its pixels, RGBA rows of `w`.
pub const Bitmap = struct { w: u32, h: u32, rgba: []const u8 };

/// What layout (and paint) ask of images: the picture for a node, if
/// the host has decoded one. An `img` without one is sized by its
/// attributes or a placeholder.
pub const Images = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, node: NodeId) ?Bitmap,
    };

    pub fn get(i: Images, node: NodeId) ?Bitmap {
        return i.vtable.get(i.ctx, node);
    }
};

pub const FontMetrics = struct {
    /// Above and below the baseline, px.
    ascent: f64,
    descent: f64,
};

/// What layout asks of text: the advance of a run, the metrics of a
/// font, and painting a run with its baseline at a point.
pub const Fonts = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        advance: *const fn (ctx: *anyopaque, font: Font, text: []const u8) f64,
        metrics: *const fn (ctx: *anyopaque, font: Font) FontMetrics,
        draw: *const fn (ctx: *anyopaque, canvas: *const ui.Canvas, font: Font, x: f64, baseline: f64, text: []const u8, color: u32) void,
    };

    pub fn advance(f: Fonts, font: Font, text: []const u8) f64 {
        return f.vtable.advance(f.ctx, font, text);
    }
    pub fn metrics(f: Fonts, font: Font) FontMetrics {
        return f.vtable.metrics(f.ctx, font);
    }
    pub fn draw(f: Fonts, canvas: *const ui.Canvas, font: Font, x: f64, baseline: f64, text: []const u8, color: u32) void {
        f.vtable.draw(f.ctx, canvas, font, x, baseline, text, color);
    }
};

/// The test fonts: every code point a cell half the font size wide and
/// the font size tall, painted as a solid block inset by one pixel, so
/// a reftest is deterministic and a difference is a difference of
/// layout. Bold widens nothing; italic slants nothing.
pub const FixedFonts = struct {
    pub fn fonts(self: *FixedFonts) Fonts {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    fn cellW(font: Font) f64 {
        return @max(1, @round(font.size / 2));
    }

    fn adv(_: *anyopaque, font: Font, text: []const u8) f64 {
        var n: f64 = 0;
        var i: usize = 0;
        while (i < text.len) : (i += ui.typeface.utf8Len(text[i])) n += 1;
        return n * cellW(font);
    }

    fn met(_: *anyopaque, font: Font) FontMetrics {
        return .{ .ascent = @round(font.size * 0.8), .descent = @round(font.size * 0.2) };
    }

    fn drw(_: *anyopaque, canvas: *const ui.Canvas, font: Font, x: f64, baseline: f64, text: []const u8, color: u32) void {
        const cw = cellW(font);
        const asc = @round(font.size * 0.8);
        const top = baseline - asc;
        const h = @round(font.size);
        var i: usize = 0;
        var col: f64 = 0;
        while (i < text.len) : (col += 1) {
            const n = ui.typeface.utf8Len(text[i]);
            const cp = std.unicode.utf8Decode(text[i..@min(i + n, text.len)]) catch 0;
            i += n;
            if (cp == ' ' or cp == 0xa0) continue; // a space, breaking or not, is blank
            const px = x + col * cw;
            if (px < 0 or top < 0 or cw < 3 or h < 3) continue;
            canvas.fillRect(@intFromFloat(@round(px + 1)), @intFromFloat(@round(top + 1)), @intFromFloat(cw - 2), @intFromFloat(h - 2), color);
        }
    }

    const vtable: Fonts.VTable = .{ .advance = adv, .metrics = met, .draw = drw };
};

pub fn fontOf(c: *const Computed) Font {
    var mono = false;
    var serif = false;
    for (c.font_family) |f| {
        if (std.ascii.eqlIgnoreCase(f, "monospace")) mono = true;
        if (std.ascii.eqlIgnoreCase(f, "serif")) serif = true;
        break;
    }
    return .{ .size = c.font_size, .weight = c.font_weight, .italic = c.font_style != .normal, .monospace = mono, .serif = serif, .families = c.font_family };
}

// ------------------------------------------------------------- the tree

pub const Kind = enum { root, block, anon_block, inline_box, inline_block, text, br, marker };

pub const BoxId = u32;

pub const Line = struct {
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    baseline: f64,
    /// Fragments in this line, indices into `Layout.fragments`.
    first_frag: u32,
    frag_count: u32,
};

pub const Fragment = struct {
    box: BoxId,
    kind: enum { text, inline_open, inline_close, inline_span, atomic, marker },
    x: f64,
    y: f64,
    w: f64,
    h: f64,
    baseline: f64,
    text: []const u8 = "",
};

pub const Box = struct {
    kind: Kind,
    node: ?NodeId,
    style: *const Computed,
    children: std.ArrayList(BoxId) = .empty,
    parent: ?BoxId = null,
    text: []const u8 = "",
    marker_text: []const u8 = "",
    /// The border box, document coordinates.
    x: f64 = 0,
    y: f64 = 0,
    w: f64 = 0,
    h: f64 = 0,
    /// Used margins, and the content box's inset from the border box.
    margin: [4]f64 = .{ 0, 0, 0, 0 },
    padding: [4]f64 = .{ 0, 0, 0, 0 },
    border: [4]f64 = .{ 0, 0, 0, 0 },
    /// Lines, when this box holds inline content.
    lines: std.ArrayList(Line) = .empty,
    /// The first line's baseline, for an atomic inline's alignment.
    first_baseline: ?f64 = null,
    last_baseline: ?f64 = null,
    laid_out: bool = false,

    pub fn contentX(b: *const Box) f64 {
        return b.x + b.border[3] + b.padding[3];
    }
    pub fn contentY(b: *const Box) f64 {
        return b.y + b.border[0] + b.padding[0];
    }
    pub fn contentW(b: *const Box) f64 {
        return b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3];
    }
    pub fn contentH(b: *const Box) f64 {
        return b.h - b.border[0] - b.border[2] - b.padding[0] - b.padding[2];
    }
    pub fn isBlockLevel(b: *const Box) bool {
        return switch (b.kind) {
            .root, .block, .anon_block => true,
            else => false,
        };
    }
    pub fn isFloat(b: *const Box) bool {
        return b.style.float != .none and b.kind != .text;
    }
    /// Positioned out of the flow: a text box never is, whatever
    /// position its parent's style (which it shares) says.
    pub fn isPositioned(b: *const Box) bool {
        return b.kind != .text and (b.style.position == .absolute or b.style.position == .fixed);
    }
    pub fn isOutOfFlow(b: *const Box) bool {
        return b.isFloat() or b.isPositioned();
    }
};

/// An absolutely positioned box and its containing block, laid out
/// after the flow and painted around it.
pub const Absolute = struct { box: BoxId, cb: BoxId };

pub const Layout = struct {
    a: std.mem.Allocator,
    doc: *const Document,
    styles: *const style.Styles,
    fonts: Fonts,
    /// The host's pictures, if it has any.
    images: ?Images = null,
    boxes: std.ArrayList(Box) = .empty,
    fragments: std.ArrayList(Fragment) = .empty,
    root: BoxId = 0,
    viewport_w: f64,
    viewport_h: f64,
    /// The document's height after layout (the root's border box).
    height: f64 = 0,
    /// Boxes to lay out last: absolutely positioned ones with their
    /// containing block.
    absolutes: std.ArrayList(Absolute) = .empty,
    /// Every float placed, in the coordinates of the document.
    floats: std.ArrayList(FloatRec) = .empty,
    root_style: Computed = .{},

    pub fn box(l: *Layout, id: BoxId) *Box {
        return &l.boxes.items[id];
    }
    pub fn get(l: *const Layout, id: BoxId) *const Box {
        return &l.boxes.items[id];
    }
};

const FloatRec = struct { box: BoxId, x: f64, y: f64, w: f64, h: f64, left: bool, bfc: BoxId };

/// Lay out a document for a viewport. The styles must be the ones
/// computed for it; the result's boxes hold every position a painter
/// needs.
pub fn layoutDocument(a: std.mem.Allocator, doc: *const Document, styles: *const style.Styles, fonts: Fonts, viewport_w: f64, viewport_h: f64) Error!*Layout {
    return layoutDocumentWith(a, doc, styles, fonts, null, viewport_w, viewport_h);
}

/// The same, with the host's pictures for `img` sizes.
pub fn layoutDocumentWith(a: std.mem.Allocator, doc: *const Document, styles: *const style.Styles, fonts: Fonts, images: ?Images, viewport_w: f64, viewport_h: f64) Error!*Layout {
    const l = try a.create(Layout);
    l.* = .{ .a = a, .doc = doc, .styles = styles, .fonts = fonts, .images = images, .viewport_w = viewport_w, .viewport_h = viewport_h };
    l.root_style.display = .block;
    try l.boxes.append(a, .{ .kind = .root, .node = null, .style = &l.root_style });
    // The root element's box is the html element's, a block under the
    // initial containing block.
    var c = doc.get(dom.document_id).first_child;
    while (c) |cid| : (c = doc.get(cid).next) {
        if (doc.get(cid).kind == .element) try buildBoxes(l, l.root, cid);
    }
    try wrapInlines(l, l.root);
    // The initial containing block is the viewport.
    const root = l.box(l.root);
    root.x = 0;
    root.y = 0;
    root.w = viewport_w;
    root.h = viewport_h;
    var bfc: Bfc = .{ .root = l.root };
    _ = try layoutBlockChildren(l, l.root, &bfc);
    var height: f64 = 0;
    for (root.children.items) |ch| {
        const b = l.get(ch);
        height = @max(height, b.y + b.h + b.margin[2]);
    }
    for (l.floats.items) |f| height = @max(height, f.y + f.h);
    root.h = @max(viewport_h, height);
    // Absolutely positioned boxes, against their containing blocks.
    for (l.absolutes.items) |ab| try layoutAbsolute(l, ab.box, ab.cb);
    for (l.absolutes.items) |ab| {
        const b = l.get(ab.box);
        root.h = @max(root.h, b.y + b.h);
    }
    l.height = root.h;
    return l;
}

// --------------------------------------------------------- box building

fn addBox(l: *Layout, parent: BoxId, b: Box) Error!BoxId {
    var nb = b;
    nb.parent = parent;
    try l.boxes.append(l.a, nb);
    const id: BoxId = @intCast(l.boxes.items.len - 1);
    try l.box(parent).children.append(l.a, id);
    return id;
}

fn isBlockDisplay(d: style.Display) bool {
    return switch (d) {
        .block, .list_item, .flex, .grid, .table, .table_row, .table_row_group, .table_header_group, .table_footer_group, .table_caption, .flow_root => true,
        else => false,
    };
}

fn isInlineBlockDisplay(d: style.Display) bool {
    return switch (d) {
        .inline_block, .inline_flex, .inline_grid, .inline_table, .table_cell => true,
        else => false,
    };
}

/// Elements whose content is not laid out as their children (replaced
/// or form controls): an atomic inline with a size of its own.
fn isReplaced(doc: *const Document, id: NodeId) bool {
    const n = doc.get(id);
    return n.namespace == .html and (std.mem.eql(u8, n.name, "img") or std.mem.eql(u8, n.name, "input") or std.mem.eql(u8, n.name, "select") or std.mem.eql(u8, n.name, "textarea") or std.mem.eql(u8, n.name, "button") or std.mem.eql(u8, n.name, "video") or std.mem.eql(u8, n.name, "canvas") or std.mem.eql(u8, n.name, "iframe") or std.mem.eql(u8, n.name, "svg") or std.mem.eql(u8, n.name, "embed") or std.mem.eql(u8, n.name, "object") or std.mem.eql(u8, n.name, "meter") or std.mem.eql(u8, n.name, "progress"));
}

fn buildBoxes(l: *Layout, parent: BoxId, id: NodeId) Error!void {
    const doc = l.doc;
    const n = doc.get(id);
    switch (n.kind) {
        .text => {
            if (n.text.items.len == 0) return;
            _ = try addBox(l, parent, .{ .kind = .text, .node = id, .style = l.get(parent).style, .text = n.text.items });
            return;
        },
        .element => {},
        else => return,
    }
    const st = l.styles.get(id);
    if (st.display == .none) return;
    if (st.display == .contents) {
        var c = n.first_child;
        while (c) |cid| : (c = doc.get(cid).next) try buildBoxes(l, parent, cid);
        return;
    }
    const replaced = isReplaced(doc, id);
    var kind: Kind = .inline_box;
    if (replaced) {
        kind = .inline_block;
    } else if (isBlockDisplay(st.display)) {
        kind = .block;
    } else if (isInlineBlockDisplay(st.display)) {
        kind = .inline_block;
    }
    if (doc.isHtml(id, "br")) kind = .br;
    const bid = try addBox(l, parent, .{ .kind = kind, .node = id, .style = st });
    if (kind == .br or replaced) return;
    if (st.display == .list_item) l.box(bid).marker_text = try markerText(l, id, st);
    var c = n.first_child;
    while (c) |cid| : (c = doc.get(cid).next) try buildBoxes(l, bid, cid);
    if (kind == .block or kind == .inline_block) try wrapInlines(l, bid);
}

fn markerText(l: *Layout, id: NodeId, st: *const Computed) Error![]const u8 {
    switch (st.list_style_type) {
        .none => return "",
        .disc => return "\u{2022} ",
        .circle => return "\u{25e6} ",
        .square => return "\u{25aa} ",
        else => {},
    }
    // The item's ordinal among its list-item siblings (a `start`
    // attribute on the list is honoured).
    var n: usize = 1;
    const doc = l.doc;
    if (doc.get(id).parent) |p| {
        if (doc.getAttr(p, "start")) |s| n = std.fmt.parseInt(usize, s, 10) catch 1;
        var s = doc.get(p).first_child;
        while (s) |sid| : (s = doc.get(sid).next) {
            if (sid == id) break;
            if (doc.get(sid).kind == .element and l.styles.get(sid).display == .list_item) n += 1;
        }
    }
    return switch (st.list_style_type) {
        .decimal => try std.fmt.allocPrint(l.a, "{d}. ", .{n}),
        .lower_alpha => try std.fmt.allocPrint(l.a, "{c}. ", .{@as(u8, @intCast('a' + (n - 1) % 26))}),
        .upper_alpha => try std.fmt.allocPrint(l.a, "{c}. ", .{@as(u8, @intCast('A' + (n - 1) % 26))}),
        .lower_roman => try std.fmt.allocPrint(l.a, "{s}. ", .{roman(n, false)}),
        .upper_roman => try std.fmt.allocPrint(l.a, "{s}. ", .{roman(n, true)}),
        else => "",
    };
}

threadlocal var roman_buf: [16]u8 = undefined;

fn roman(n_in: usize, upper: bool) []const u8 {
    const vals = [_]usize{ 1000, 900, 500, 400, 100, 90, 50, 40, 10, 9, 5, 4, 1 };
    const syms = [_][]const u8{ "m", "cm", "d", "cd", "c", "xc", "l", "xl", "x", "ix", "v", "iv", "i" };
    var n: usize = @min(n_in, 3999);
    var len: usize = 0;
    for (vals, syms) |v, s| while (n >= v) {
        for (s) |c| {
            if (len == roman_buf.len) break;
            roman_buf[len] = if (upper) std.ascii.toUpper(c) else c;
            len += 1;
        }
        n -= v;
    };
    return roman_buf[0..len];
}

/// A block container with both block-level and inline-level children
/// wraps each run of inline-level children in an anonymous block, so
/// every child is block-level or every child is inline-level.
fn wrapInlines(l: *Layout, id: BoxId) Error!void {
    try splitInlines(l, id);
    const children = l.get(id).children.items;
    var has_block = false;
    var has_inline = false;
    for (children) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow()) continue;
        if (cb.isBlockLevel()) has_block = true else has_inline = true;
    }
    if (!has_block or !has_inline) return;
    const old = try l.a.dupe(BoxId, children);
    l.box(id).children = .empty;
    var anon: ?BoxId = null;
    for (old) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow()) {
            // Out of flow: joins the open anonymous block (it follows
            // inline content) or else stays a direct child between blocks.
            if (anon) |an| {
                try l.box(an).children.append(l.a, c);
                l.box(c).parent = an;
            } else try l.box(id).children.append(l.a, c);
            continue;
        }
        const inline_level = !cb.isBlockLevel();
        if (inline_level) {
            // Whitespace-only text between blocks is nothing.
            if (cb.kind == .text and isBlank(cb.text) and cb.style.white_space != .pre and cb.style.white_space != .pre_wrap) continue;
        }
        if (inline_level) {
            if (anon == null) {
                try l.boxes.append(l.a, .{ .kind = .anon_block, .node = null, .style = try anonStyle(l, l.get(id).style), .parent = id });
                anon = @intCast(l.boxes.items.len - 1);
                try l.box(id).children.append(l.a, anon.?);
            }
            try l.box(anon.?).children.append(l.a, c);
            l.box(c).parent = anon;
        } else {
            anon = null;
            try l.box(id).children.append(l.a, c);
        }
    }
}

/// CSS 2.1 §9.2.1.1: a block-level box inside an inline box breaks the
/// inline around it. Every inline child of `id` that holds an in-flow
/// block (however deep) is replaced by its pieces — inline boxes for
/// the runs before and after, sharing the node and style, and the
/// blocks themselves hoisted to `id`'s level, where the anonymous
/// block wrapping then takes over.
fn splitInlines(l: *Layout, id: BoxId) Error!void {
    var needs = false;
    for (l.get(id).children.items) |c| if (containsBlock(l, c)) {
        needs = true;
    };
    if (!needs) return;
    const old = try l.a.dupe(BoxId, l.get(id).children.items);
    var out: std.ArrayList(BoxId) = .empty;
    for (old) |c| {
        if (containsBlock(l, c)) try splitInline(l, c, id, &out) else try out.append(l.a, c);
    }
    l.box(id).children = out;
}

fn containsBlock(l: *const Layout, id: BoxId) bool {
    const b = l.get(id);
    if (b.kind != .inline_box) return false;
    for (b.children.items) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow()) continue;
        if (cb.isBlockLevel() or containsBlock(l, c)) return true;
    }
    return false;
}

fn splitInline(l: *Layout, ib: BoxId, container: BoxId, out: *std.ArrayList(BoxId)) Error!void {
    const kids = try l.a.dupe(BoxId, l.get(ib).children.items);
    // The original box is the first piece; later pieces are fresh boxes
    // with the same node and style.
    var cur = ib;
    l.box(cur).children = .empty;
    l.box(cur).parent = container;
    var first = true;
    for (kids) |k| {
        const kb = l.get(k);
        if (kb.isBlockLevel() and !kb.isOutOfFlow()) {
            try closePiece(l, cur, first, out);
            first = false;
            try out.append(l.a, k);
            l.box(k).parent = container;
            cur = try newPiece(l, ib, container);
        } else if (containsBlock(l, k)) {
            var sub: std.ArrayList(BoxId) = .empty;
            try splitInline(l, k, container, &sub);
            for (sub.items) |piece| {
                if (l.get(piece).isBlockLevel()) {
                    try closePiece(l, cur, first, out);
                    first = false;
                    try out.append(l.a, piece);
                    cur = try newPiece(l, ib, container);
                } else {
                    try l.box(cur).children.append(l.a, piece);
                    l.box(piece).parent = cur;
                }
            }
        } else {
            try l.box(cur).children.append(l.a, k);
            l.box(k).parent = cur;
        }
    }
    try closePiece(l, cur, first, out);
}

fn newPiece(l: *Layout, like: BoxId, container: BoxId) Error!BoxId {
    const src = l.get(like);
    try l.boxes.append(l.a, .{ .kind = .inline_box, .node = src.node, .style = src.style, .parent = container });
    return @intCast(l.boxes.items.len - 1);
}

/// An empty piece is dropped, except the first, which carries the
/// inline's opening edge.
fn closePiece(l: *Layout, piece: BoxId, first: bool, out: *std.ArrayList(BoxId)) Error!void {
    if (first or l.get(piece).children.items.len > 0) try out.append(l.a, piece);
}

fn anonStyle(l: *Layout, parent: *const style.Computed) Error!*const style.Computed {
    const st = try l.a.create(style.Computed);
    st.* = style.anonymous(parent);
    return st;
}

fn isBlank(s: []const u8) bool {
    for (s) |c| if (c != ' ' and c != '\t' and c != '\n' and c != '\r' and c != 0x0c) return false;
    return true;
}

// ---------------------------------------------------------- resolving

fn resolveLP(lp: style.LengthPercent, base: f64) f64 {
    return switch (lp) {
        .px => |x| x,
        .percent => |p| base * p / 100,
    };
}

fn resolveLA(la: style.LengthAuto, base: f64) ?f64 {
    return switch (la) {
        .px => |x| x,
        .percent => |p| base * p / 100,
        .auto => null,
    };
}

/// Margins, padding and borders in pixels against the containing
/// block's width (`auto` margins as null).
fn resolveEdges(b: *Box, cb_w: f64) [4]?f64 {
    const st = b.style;
    var margins: [4]?f64 = undefined;
    for (0..4) |i| {
        margins[i] = resolveLA(st.margin[i], cb_w);
        b.padding[i] = resolveLP(st.padding[i], cb_w);
        b.border[i] = st.borderWidth(i);
    }
    return margins;
}

fn horizontalExtras(b: *const Box) f64 {
    return b.padding[1] + b.padding[3] + b.border[1] + b.border[3];
}

fn verticalExtras(b: *const Box) f64 {
    return b.padding[0] + b.padding[2] + b.border[0] + b.border[2];
}

/// The used width of a box's content from its `width` (border-box
/// sizing subtracted) and the min/max constraints.
fn constrainWidth(b: *const Box, w: f64, cb_w: f64) f64 {
    var out = w;
    const st = b.style;
    switch (st.max_width) {
        .none => {},
        .px => |x| out = @min(out, if (st.box_sizing == .border_box) x - horizontalExtras(b) else x),
        .percent => |p| out = @min(out, cb_w * p / 100 - (if (st.box_sizing == .border_box) horizontalExtras(b) else 0)),
    }
    const min = resolveLP(st.min_width, cb_w) - (if (st.box_sizing == .border_box) horizontalExtras(b) else 0);
    return @max(out, min, 0);
}

// --------------------------------------------------------------- floats

const Bfc = struct {
    root: BoxId,
};

/// The space between floats at a vertical range, inside [x0, x1).
fn floatBounds(l: *const Layout, bfc: *const Bfc, y0: f64, y1: f64, x0: f64, x1: f64) struct { left: f64, right: f64 } {
    var left = x0;
    var right = x1;
    for (l.floats.items) |f| {
        if (f.bfc != bfc.root) continue;
        if (f.y >= y1 or f.y + f.h <= y0) continue;
        if (f.left) left = @max(left, f.x + f.w) else right = @min(right, f.x);
    }
    return .{ .left = left, .right = right };
}

/// The next y at which the float situation changes below `y`.
fn nextFloatEdge(l: *const Layout, bfc: *const Bfc, y: f64) ?f64 {
    var best: ?f64 = null;
    for (l.floats.items) |f| {
        if (f.bfc != bfc.root) continue;
        const bottom = f.y + f.h;
        if (bottom > y and (best == null or bottom < best.?)) best = bottom;
    }
    return best;
}

fn clearY(l: *const Layout, bfc: *const Bfc, clear: style.Clear, y: f64) f64 {
    var out = y;
    for (l.floats.items) |f| {
        if (f.bfc != bfc.root) continue;
        const wanted = switch (clear) {
            .none => false,
            .left => f.left,
            .right => !f.left,
            .both => true,
        };
        if (wanted) out = @max(out, f.y + f.h);
    }
    return out;
}

fn placeFloat(l: *Layout, id: BoxId, bfc: *const Bfc, cb_x: f64, cb_w: f64, y_start: f64) Error!void {
    const b = l.box(id);
    // Lay it out to know its size: shrink-to-fit width.
    const margins = resolveEdges(b, cb_w);
    b.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
    var inner: Bfc = .{ .root = id };
    const avail = cb_w - b.margin[1] - b.margin[3] - horizontalExtras(b);
    const width = if (resolveLA(b.style.width, cb_w)) |w| (if (b.style.box_sizing == .border_box) w - horizontalExtras(b) else w) else blk: {
        const pref = try preferredWidths(l, id);
        break :blk @min(@max(pref.min, avail), pref.max);
    };
    b.w = constrainWidth(b, width, cb_w) + horizontalExtras(b);
    b.x = 0;
    b.y = 0;
    try layoutBlockContents(l, id, &inner, cb_w);
    const outer_w = b.w + b.margin[1] + b.margin[3];
    const outer_h = b.h + b.margin[0] + b.margin[2];
    // The topmost place at or below y_start where it fits beside the
    // floats already there; a float never sits above an earlier one.
    var y = y_start;
    for (l.floats.items) |f| if (f.bfc == bfc.root) {
        y = @max(y, f.y);
    };
    while (true) {
        const bounds = floatBounds(l, bfc, y, y + @max(outer_h, 1), cb_x, cb_x + cb_w);
        if (bounds.right - bounds.left >= outer_w or nextFloatEdge(l, bfc, y) == null) {
            const x = if (b.style.float == .left) bounds.left else bounds.right - outer_w;
            try moveBox(l, id, x + b.margin[3] - b.x, y + b.margin[0] - b.y);
            try l.floats.append(l.a, .{ .box = id, .x = x, .y = y, .w = outer_w, .h = outer_h, .left = b.style.float == .left, .bfc = bfc.root });
            return;
        }
        y = nextFloatEdge(l, bfc, y).?;
    }
}

/// Move a box and everything in it.
fn moveBox(l: *Layout, id: BoxId, dx: f64, dy: f64) Error!void {
    if (dx == 0 and dy == 0) return;
    const b = l.box(id);
    b.x += dx;
    b.y += dy;
    for (b.lines.items) |*ln| {
        ln.x += dx;
        ln.y += dy;
        ln.baseline += dy;
        for (l.fragments.items[ln.first_frag .. ln.first_frag + ln.frag_count]) |*f| {
            f.x += dx;
            f.y += dy;
            f.baseline += dy;
        }
    }
    if (b.first_baseline) |*fb| fb.* += dy;
    if (b.last_baseline) |*lb| lb.* += dy;
    for (l.floats.items) |*f| if (f.box == id) {
        f.x += dx;
        f.y += dy;
    };
    const children = try l.a.dupe(BoxId, b.children.items);
    for (children) |c| try moveBox(l, c, dx, dy);
}

// ------------------------------------------------------- block layout

const Margin = struct {
    pos: f64 = 0,
    neg: f64 = 0,

    fn add(m: *Margin, v: f64) void {
        if (v >= 0) m.pos = @max(m.pos, v) else m.neg = @min(m.neg, v);
    }
    fn value(m: Margin) f64 {
        return m.pos + m.neg;
    }
};

fn isBfcRoot(b: *const Box) bool {
    if (b.kind == .root or b.kind == .inline_block) return true;
    if (b.isOutOfFlow()) return true;
    if (b.style.overflow_x != .visible or b.style.overflow_y != .visible) return true;
    return b.style.display == .flow_root or b.style.display == .table or b.style.display == .table_cell;
}

fn topCollapsible(b: *const Box) bool {
    return b.border[0] == 0 and b.padding[0] == 0 and !isBfcRoot(b) and b.kind != .inline_block;
}

fn bottomCollapsible(b: *const Box) bool {
    return b.border[2] == 0 and b.padding[2] == 0 and !isBfcRoot(b) and b.style.height == .auto and b.style.min_height.px == 0 and b.kind != .inline_block;
}

/// Does this block hold nothing that separates its top and bottom
/// margins (no lines, no in-flow child with content, no height)?
fn collapsesThrough(l: *const Layout, id: BoxId) bool {
    const b = l.get(id);
    if (b.kind == .inline_block or b.kind == .root) return false;
    if (b.border[0] != 0 or b.padding[0] != 0 or b.border[2] != 0 or b.padding[2] != 0) return false;
    if (b.style.height != .auto or resolveLP(b.style.min_height, 0) > 0) return false;
    if (isBfcRoot(b)) return false;
    if (hasInlineContent(l, id)) return !hasVisibleInline(l, id);
    for (b.children.items) |c| {
        if (l.get(c).isOutOfFlow()) continue;
        if (!collapsesThrough(l, c)) return false;
    }
    return true;
}

fn hasInlineContent(l: *const Layout, id: BoxId) bool {
    for (l.get(id).children.items) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow()) continue;
        if (!cb.isBlockLevel()) return true;
    }
    return false;
}

fn hasVisibleInline(l: *const Layout, id: BoxId) bool {
    for (l.get(id).children.items) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow()) continue;
        switch (cb.kind) {
            .text => if (!isBlank(cb.text) or cb.style.white_space == .pre or cb.style.white_space == .pre_wrap) return true,
            .inline_box => if (hasVisibleInline(l, c) or cb.border[0] != 0 or cb.padding[0] != 0) return true,
            .br, .inline_block, .marker => return true,
            else => {},
        }
    }
    return false;
}

/// The margin a block's top collapses into: its own with its first
/// in-flow child's, when nothing separates them.
fn collapsedTop(l: *Layout, id: BoxId, cb_w: f64) Error!Margin {
    const b = l.box(id);
    var m: Margin = .{};
    const margins = resolveEdges(b, cb_w);
    m.add(margins[0] orelse 0);
    if (!topCollapsible(b) or hasInlineContent(l, id)) return m;
    for (b.children.items) |c| {
        if (l.get(c).isOutOfFlow()) continue;
        if (l.get(c).style.clear != .none) break; // clearance separates
        const inner_w = @max(0, cb_w - (margins[1] orelse 0) - (margins[3] orelse 0) - horizontalExtras(b));
        const cm = try collapsedTop(l, c, inner_w);
        m.add(cm.pos);
        m.add(cm.neg);
        if (collapsesThrough(l, c)) continue;
        break;
    }
    return m;
}

/// The result of laying out a block's children: where the flow ended
/// and the margin still pending below it.
const FlowEnd = struct { cursor: f64, pending: Margin };

/// Lay out `id`'s block-level children below its content top; `id`'s
/// border box is already positioned and sized in width.
fn layoutBlockChildren(l: *Layout, id: BoxId, bfc: *Bfc) Error!FlowEnd {
    const b = l.box(id);
    const cb_x = b.contentX();
    const cb_w = b.contentW();
    var cursor = b.contentY();
    var pending: Margin = .{};
    // A collapsible top means the parent's caller already placed the
    // first child's top margin above this box.
    var first_collapsed = topCollapsible(b) and b.kind != .root;
    const children = try l.a.dupe(BoxId, b.children.items);
    for (children) |c| {
        const cb = l.box(c);
        if (cb.isPositioned()) {
            try l.absolutes.append(l.a, .{ .box = c, .cb = containingBlockFor(l, c) });
            continue;
        }
        if (cb.isFloat()) {
            try placeFloat(l, c, bfc, cb_x, cb_w, cursor + pending.value());
            continue;
        }
        // Clearance: the box moves below the floats it clears, and the
        // pending margin is spent.
        if (cb.style.clear != .none) {
            const cleared = clearY(l, bfc, cb.style.clear, cursor + pending.value());
            if (cleared > cursor + pending.value()) {
                cursor = cleared;
                pending = .{};
                first_collapsed = false;
            }
        }
        const top = try collapsedTop(l, c, cb_w);
        if (first_collapsed) {
            // Already above us: the child starts at the content top.
            first_collapsed = false;
        } else {
            pending.add(top.pos);
            pending.add(top.neg);
        }
        if (collapsesThrough(l, c)) {
            // Its bottom margin joins the same pending margin; it takes no room.
            const margins = resolveEdges(cb, cb_w);
            pending.add(margins[2] orelse 0);
            try positionEmptyBlock(l, c, bfc, cb_x, cursor + pending.value(), cb_w);
            continue;
        }
        const y = cursor + pending.value();
        pending = .{};
        try layoutBlockAt(l, c, bfc, cb_x, y, cb_w);
        const laid = l.get(c);
        cursor = laid.y + laid.h;
        // The child's bottom margin (collapsed with its last child's)
        // waits for the next sibling or the parent's bottom.
        const bottom = try collapsedBottom(l, c);
        pending.add(bottom.pos);
        pending.add(bottom.neg);
    }
    return .{ .cursor = cursor, .pending = pending };
}

fn positionEmptyBlock(l: *Layout, id: BoxId, bfc: *Bfc, cb_x: f64, y: f64, cb_w: f64) Error!void {
    const b = l.box(id);
    const margins = resolveEdges(b, cb_w);
    b.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
    b.x = cb_x + b.margin[3];
    b.y = y;
    b.w = @max(0, cb_w - b.margin[1] - b.margin[3]);
    b.h = 0;
    b.laid_out = true;
    const children = try l.a.dupe(BoxId, b.children.items);
    for (children) |c| {
        const cb = l.get(c);
        // An empty block still places what floats out of it.
        if (cb.isPositioned()) {
            try l.absolutes.append(l.a, .{ .box = c, .cb = containingBlockFor(l, c) });
        } else if (cb.isFloat()) {
            try placeFloat(l, c, bfc, b.x, b.w, y);
        } else try positionEmptyBlock(l, c, bfc, b.x, y, b.w);
    }
}

fn collapsedBottom(l: *Layout, id: BoxId) Error!Margin {
    const b = l.get(id);
    var m: Margin = .{};
    m.add(b.margin[2]);
    if (!bottomCollapsible(b) or hasInlineContent(l, id)) return m;
    var i = b.children.items.len;
    while (i > 0) {
        i -= 1;
        const c = b.children.items[i];
        if (l.get(c).isOutOfFlow()) continue;
        const cm = try collapsedBottom(l, c);
        m.add(cm.pos);
        m.add(cm.neg);
        if (collapsesThrough(l, c)) continue;
        break;
    }
    return m;
}

fn containingBlockFor(l: *const Layout, id: BoxId) BoxId {
    var p = l.get(id).parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (pb.kind == .root) return pid;
        if (pb.style.position != .static and pb.kind != .anon_block) return pid;
    }
    return l.root;
}

/// Lay out a block-level box with its border box's top at `y`, inside
/// a containing block of content width `cb_w` at `cb_x`.
fn layoutBlockAt(l: *Layout, id: BoxId, bfc: *Bfc, cb_x: f64, y: f64, cb_w: f64) Error!void {
    const b = l.box(id);
    const margins = resolveEdges(b, cb_w);
    const st = b.style;
    // Width: auto fills; a fixed width with auto margins centres.
    const extras = horizontalExtras(b);
    var ml = margins[3];
    var mr = margins[1];
    var content_w: f64 = undefined;
    if (resolveLA(st.width, cb_w)) |w| {
        content_w = constrainWidth(b, if (st.box_sizing == .border_box) w - extras else w, cb_w);
        const rest = cb_w - content_w - extras;
        if (ml == null and mr == null) {
            ml = @max(0, rest / 2);
            mr = @max(0, rest / 2);
        } else if (ml == null) {
            ml = rest - mr.?;
        } else if (mr == null) {
            mr = rest - ml.?;
        } else {
            // Over-constrained: the right margin gives (ltr).
            mr = rest - ml.?;
        }
    } else {
        ml = ml orelse 0;
        mr = mr orelse 0;
        content_w = constrainWidth(b, cb_w - ml.? - mr.? - extras, cb_w);
    }
    b.margin = .{ margins[0] orelse 0, mr.?, margins[2] orelse 0, ml.? };
    b.x = cb_x + ml.?;
    b.y = y;
    b.w = content_w + extras;
    if (isBfcRoot(b) and !b.isFloat()) {
        // A BFC root beside floats narrows to fit next to them.
        const bounds = floatBounds(l, bfc, y, y + 1, cb_x, cb_x + cb_w);
        if (bounds.left > b.x) {
            const shift = bounds.left - b.x;
            b.x += shift;
            b.w = @max(0, @min(b.w, bounds.right - b.x));
        } else if (b.x + b.w > bounds.right) {
            b.w = @max(0, bounds.right - b.x);
        }
        var inner: Bfc = .{ .root = id };
        try layoutBlockContents(l, id, &inner, cb_w);
    } else {
        try layoutBlockContents(l, id, bfc, cb_w);
    }
}

/// The height of a block from its children, or its `height`.
fn layoutBlockContents(l: *Layout, id: BoxId, bfc: *Bfc, cb_w: f64) Error!void {
    const b = l.box(id);
    const st = b.style;
    var content_h: f64 = 0;
    if (hasInlineContent(l, id)) {
        content_h = try layoutInlineContent(l, id, bfc);
    } else {
        const end = try layoutBlockChildren(l, id, bfc);
        content_h = end.cursor - b.contentY();
        // A bottom that does not collapse keeps the last child's margin
        // inside; a BFC root also reaches past its floats.
        if (!bottomCollapsible(b)) content_h += end.pending.value();
        if (isBfcRoot(b)) {
            for (l.floats.items) |f| if (f.bfc == id) {
                content_h = @max(content_h, f.y + f.h - b.contentY());
            };
        }
    }
    const cb_h: ?f64 = if (b.parent) |p| (if (l.get(p).style.height == .auto and l.get(p).kind != .root) null else l.get(p).contentH()) else null;
    if (st.height == .px or (st.height == .percent and cb_h != null)) {
        content_h = resolveLA(st.height, cb_h orelse 0).?;
        if (st.box_sizing == .border_box) content_h -= verticalExtras(b);
    }
    content_h = @max(content_h, resolveLP(st.min_height, cb_h orelse 0) - (if (st.box_sizing == .border_box) verticalExtras(b) else 0));
    switch (st.max_height) {
        .none => {},
        .px => |x| content_h = @min(content_h, x),
        .percent => |p| if (cb_h) |h| {
            content_h = @min(content_h, h * p / 100);
        },
    }
    b.h = @max(0, content_h) + verticalExtras(b);
    b.laid_out = true;
    // Relative positioning shifts the box after layout.
    if (st.position == .relative or st.position == .sticky) {
        const dx: f64 = resolveLA(st.inset[3], cb_w) orelse -(resolveLA(st.inset[1], cb_w) orelse 0);
        const dy: f64 = resolveLA(st.inset[0], 0) orelse -(resolveLA(st.inset[2], 0) orelse 0);
        try moveBox(l, id, dx, dy);
    }
}

fn layoutAbsolute(l: *Layout, id: BoxId, cb: BoxId) Error!void {
    const cbb = l.get(cb);
    const cb_x = if (cbb.kind == .root) cbb.x else cbb.x + cbb.border[3];
    const cb_y = if (cbb.kind == .root) cbb.y else cbb.y + cbb.border[0];
    const cb_w = if (cbb.kind == .root) cbb.w else cbb.w - cbb.border[1] - cbb.border[3];
    const cb_h = if (cbb.kind == .root) l.viewport_h else cbb.h - cbb.border[0] - cbb.border[2];
    const b = l.box(id);
    const margins = resolveEdges(b, cb_w);
    b.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
    const st = b.style;
    const left = resolveLA(st.inset[3], cb_w);
    const right = resolveLA(st.inset[1], cb_w);
    const top = resolveLA(st.inset[0], cb_h);
    const bottom = resolveLA(st.inset[2], cb_h);
    var inner: Bfc = .{ .root = id };
    const extras = horizontalExtras(b);
    var content_w: f64 = undefined;
    if (resolveLA(st.width, cb_w)) |w| {
        content_w = if (st.box_sizing == .border_box) w - extras else w;
    } else if (left != null and right != null) {
        content_w = cb_w - left.? - right.? - b.margin[1] - b.margin[3] - extras;
    } else {
        const pref = try preferredWidths(l, id);
        const avail = cb_w - (left orelse 0) - (right orelse 0) - b.margin[1] - b.margin[3] - extras;
        content_w = @min(@max(pref.min, avail), pref.max);
    }
    b.w = constrainWidth(b, content_w, cb_w) + extras;
    b.x = if (left) |x| cb_x + x + b.margin[3] else if (right) |r| cb_x + cb_w - r - b.margin[1] - b.w else cb_x + b.margin[3];
    b.y = if (top) |t| cb_y + t + b.margin[0] else if (bottom != null) cb_y else cb_y + b.margin[0];
    try layoutBlockContents(l, id, &inner, cb_w);
    if (top == null and bottom != null) try moveBox(l, id, 0, cb_y + cb_h - bottom.? - b.margin[2] - l.get(id).h - l.get(id).y);
}

// ---------------------------------------------------- intrinsic widths

const Widths = struct { min: f64, max: f64 };

/// The min-content and max-content widths of a box's border box.
fn preferredWidths(l: *Layout, id: BoxId) Error!Widths {
    const b = l.box(id);
    const st = b.style;
    for (0..4) |i| {
        b.padding[i] = resolveLP(st.padding[i], 0);
        b.border[i] = st.borderWidth(i);
    }
    const extras = horizontalExtras(b);
    if (b.kind == .inline_block and b.node != null and isReplaced(l.doc, b.node.?)) {
        const size = replacedSize(l, id, 0);
        return .{ .min = size[0] + extras, .max = size[0] + extras };
    }
    if (st.width == .px) {
        const w = if (st.box_sizing == .border_box) st.width.px else st.width.px + extras;
        return .{ .min = w, .max = w };
    }
    var min: f64 = 0;
    var max: f64 = 0;
    if (hasInlineContent(l, id)) {
        const items = try collectItems(l, id, l.fonts);
        var line: f64 = 0;
        var word: f64 = 0;
        for (items) |it| {
            switch (it.kind) {
                .text, .atomic, .inline_open, .inline_close, .marker => {
                    line += it.w;
                    word += it.w;
                    if (it.kind == .atomic or it.kind == .text) {
                        min = @max(min, word);
                        if (it.kind == .atomic) word = 0;
                    }
                },
                .space => {
                    min = @max(min, word);
                    word = 0;
                    line += it.w;
                },
                .br, .newline => {
                    min = @max(min, word);
                    word = 0;
                    max = @max(max, line);
                    line = 0;
                },
            }
        }
        min = @max(min, word);
        max = @max(max, line);
        if (st.white_space == .nowrap or st.white_space == .pre) min = max;
    } else {
        for (b.children.items) |c| {
            const cb = l.get(c);
            if (cb.isPositioned()) continue;
            const cw = try preferredWidths(l, c);
            const cm = (resolveLA(cb.style.margin[1], 0) orelse 0) + (resolveLA(cb.style.margin[3], 0) orelse 0);
            min = @max(min, cw.min + cm);
            max = @max(max, cw.max + cm);
        }
    }
    return .{ .min = min + extras, .max = max + extras };
}

// ------------------------------------------------------ inline layout

const ItemKind = enum { text, space, atomic, inline_open, inline_close, br, newline, marker };

const Item = struct {
    kind: ItemKind,
    box: BoxId,
    text: []const u8 = "",
    w: f64 = 0,
    /// Atomic and marker items: height and baseline offset from the top.
    h: f64 = 0,
    baseline: f64 = 0,
    /// A space that must not be a break opportunity (`nowrap`).
    no_break: bool = false,
};

/// Whether a break may occur between two ideographs (each is a word).
fn isCjk(cp: u21) bool {
    return (cp >= 0x2e80 and cp <= 0x9fff) or (cp >= 0xac00 and cp <= 0xd7af) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xff00 and cp <= 0xffef) or (cp >= 0x3000 and cp <= 0x30ff) or (cp >= 0x20000 and cp <= 0x2ffff);
}

/// The inline items of a block container: text cut at its break
/// opportunities with white-space applied, inline boxes opened and
/// closed, atomic inlines sized.
fn collectItems(l: *Layout, id: BoxId, fonts: Fonts) Error![]const Item {
    var items: std.ArrayList(Item) = .empty;
    const b = l.get(id);
    if (b.marker_text.len > 0 and b.style.list_style_position == .inside) {
        const font = fontOf(b.style);
        const m = fonts.metrics(font);
        try items.append(l.a, .{ .kind = .marker, .box = id, .text = b.marker_text, .w = fonts.advance(font, b.marker_text), .h = m.ascent + m.descent, .baseline = m.ascent });
    }
    var prev_space = true; // a line starts as if after a space
    try collectInto(l, id, fonts, &items, &prev_space);
    return items.items;
}

fn collectInto(l: *Layout, id: BoxId, fonts: Fonts, items: *std.ArrayList(Item), prev_space: *bool) Error!void {
    const children = l.get(id).children.items;
    for (children) |c| {
        const cb = l.box(c);
        if (cb.isPositioned()) {
            try l.absolutes.append(l.a, .{ .box = c, .cb = containingBlockFor(l, c) });
            continue;
        }
        if (cb.isFloat()) {
            // Placed when the line is built: an atomic item of no width
            // stands in so the position is known.
            try items.append(l.a, .{ .kind = .atomic, .box = c, .w = 0, .h = 0 });
            continue;
        }
        switch (cb.kind) {
            .text => try textItems(l, c, fonts, items, prev_space),
            .br => {
                try items.append(l.a, .{ .kind = .br, .box = c });
                prev_space.* = true;
            },
            .inline_box => {
                const cb_w = containerWidth(l, c);
                _ = resolveEdges(cb, cb_w);
                cb.margin = .{ 0, resolveLA(cb.style.margin[1], cb_w) orelse 0, 0, resolveLA(cb.style.margin[3], cb_w) orelse 0 };
                try items.append(l.a, .{ .kind = .inline_open, .box = c, .w = cb.margin[3] + cb.border[3] + cb.padding[3] });
                try collectInto(l, c, fonts, items, prev_space);
                try items.append(l.a, .{ .kind = .inline_close, .box = c, .w = cb.margin[1] + cb.border[1] + cb.padding[1] });
            },
            .inline_block, .block, .anon_block => {
                const size = try layoutAtomic(l, c);
                try items.append(l.a, .{ .kind = .atomic, .box = c, .w = size.w, .h = size.h, .baseline = size.baseline });
                prev_space.* = false;
            },
            else => {},
        }
    }
}

fn containerWidth(l: *const Layout, id: BoxId) f64 {
    var p = l.get(id).parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (pb.isBlockLevel() or pb.kind == .inline_block) return pb.contentW();
    }
    return l.viewport_w;
}

/// Text into words and spaces under its white-space mode.
fn textItems(l: *Layout, id: BoxId, fonts: Fonts, items: *std.ArrayList(Item), prev_space: *bool) Error!void {
    const b = l.get(id);
    const st = b.style;
    const font = fontOf(st);
    const m = fonts.metrics(font);
    const text = try transformCase(l, b.text, st.text_transform);
    const preserve = st.white_space == .pre or st.white_space == .pre_wrap or st.white_space == .break_spaces;
    const keep_newlines = preserve or st.white_space == .pre_line;
    const no_break = st.white_space == .nowrap or st.white_space == .pre;
    var i: usize = 0;
    while (i < text.len) {
        const c = text[i];
        if (c == '\n' and keep_newlines) {
            try items.append(l.a, .{ .kind = .newline, .box = id });
            prev_space.* = true;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            if (preserve) {
                // Every space is kept; a tab is eight of them.
                const s: []const u8 = if (c == '\t') "        " else " ";
                try items.append(l.a, .{ .kind = .space, .box = id, .text = s, .w = fonts.advance(font, s), .h = m.ascent + m.descent, .baseline = m.ascent, .no_break = no_break });
                i += 1;
                continue;
            }
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r' or text[j] == 0x0c)) j += 1;
            if (!prev_space.*) try items.append(l.a, .{ .kind = .space, .box = id, .text = " ", .w = fonts.advance(font, " "), .h = m.ascent + m.descent, .baseline = m.ascent, .no_break = no_break });
            prev_space.* = true;
            i = j;
            continue;
        }
        // A word: up to the next space; each ideograph its own word.
        var j = i;
        while (j < text.len) {
            const cl = ui.typeface.utf8Len(text[j]);
            const cp = std.unicode.utf8Decode(text[j..@min(j + cl, text.len)]) catch 0;
            if (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r' or text[j] == 0x0c) break;
            if (j > i and isCjk(cp)) break;
            j += cl;
            if (isCjk(cp)) break;
        }
        const word = text[i..j];
        try items.append(l.a, .{ .kind = .text, .box = id, .text = word, .w = fonts.advance(font, word), .h = m.ascent + m.descent, .baseline = m.ascent, .no_break = no_break });
        prev_space.* = false;
        i = j;
    }
}

fn transformCase(l: *Layout, text: []const u8, t: style.TextTransform) Error![]const u8 {
    switch (t) {
        .none => return text,
        .uppercase => {
            const out = try l.a.dupe(u8, text);
            for (out) |*c| c.* = std.ascii.toUpper(c.*);
            return out;
        },
        .lowercase => {
            const out = try l.a.dupe(u8, text);
            for (out) |*c| c.* = std.ascii.toLower(c.*);
            return out;
        },
        .capitalize => {
            const out = try l.a.dupe(u8, text);
            var at_start = true;
            for (out) |*c| {
                if (c.* == ' ' or c.* == '\n' or c.* == '\t') {
                    at_start = true;
                } else if (at_start) {
                    c.* = std.ascii.toUpper(c.*);
                    at_start = false;
                }
            }
            return out;
        },
    }
}

const AtomicSize = struct { w: f64, h: f64, baseline: f64 };

/// An inline-block or replaced element laid out on its own: its
/// margin box size and its baseline.
fn layoutAtomic(l: *Layout, id: BoxId) Error!AtomicSize {
    const b = l.box(id);
    const cb_w = containerWidth(l, id);
    const margins = resolveEdges(b, cb_w);
    b.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
    const extras = horizontalExtras(b);
    if (b.node != null and isReplaced(l.doc, b.node.?)) {
        const size = replacedSize(l, id, cb_w);
        b.x = 0;
        b.y = 0;
        b.w = size[0] + extras;
        b.h = size[1] + verticalExtras(b);
        b.laid_out = true;
        // A replaced element sits on its bottom margin edge.
        return .{ .w = b.w + b.margin[1] + b.margin[3], .h = b.h + b.margin[0] + b.margin[2], .baseline = b.h + b.margin[0] };
    }
    const width = if (resolveLA(b.style.width, cb_w)) |w| (if (b.style.box_sizing == .border_box) w - extras else w) else blk: {
        const pref = try preferredWidths(l, id);
        const avail = cb_w - b.margin[1] - b.margin[3] - extras;
        break :blk @min(@max(pref.min, avail), pref.max);
    };
    b.w = constrainWidth(b, width, cb_w) + extras;
    b.x = 0;
    b.y = 0;
    var inner: Bfc = .{ .root = id };
    try layoutBlockContents(l, id, &inner, cb_w);
    // The baseline is the last line's, or the bottom margin edge when
    // it has no lines or hides its overflow.
    var baseline = b.h + b.margin[0];
    if (b.style.overflow_y == .visible) if (lastBaseline(l, id)) |lb| {
        baseline = lb - b.y + b.margin[0];
    };
    return .{ .w = b.w + b.margin[1] + b.margin[3], .h = b.h + b.margin[0] + b.margin[2], .baseline = baseline };
}

fn lastBaseline(l: *const Layout, id: BoxId) ?f64 {
    const b = l.get(id);
    if (b.lines.items.len > 0) return b.lines.items[b.lines.items.len - 1].baseline;
    var i = b.children.items.len;
    while (i > 0) {
        i -= 1;
        const c = b.children.items[i];
        if (l.get(c).isOutOfFlow()) continue;
        if (lastBaseline(l, c)) |lb| return lb;
    }
    return null;
}

/// A replaced element's content size: CSS width/height, else the
/// `width`/`height` attributes, else a default (300×150 for an image
/// with no size, a text field 12em wide, a button around its text).
fn replacedSize(l: *const Layout, id: BoxId, cb_w: f64) [2]f64 {
    const b = l.get(id);
    const node = b.node.?;
    const doc = l.doc;
    const st = b.style;
    var w: ?f64 = resolveLA(st.width, cb_w);
    var h: ?f64 = resolveLA(st.height, 0);
    if (w == null) if (doc.getAttr(node, "width")) |s| {
        w = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch null;
    };
    if (h == null) if (doc.getAttr(node, "height")) |s| {
        h = std.fmt.parseFloat(f64, std.mem.trim(u8, s, " ")) catch null;
    };
    const em = st.font_size;
    const name = doc.get(node).name;
    if (std.mem.eql(u8, name, "img") or std.mem.eql(u8, name, "video") or std.mem.eql(u8, name, "canvas") or std.mem.eql(u8, name, "iframe") or std.mem.eql(u8, name, "svg") or std.mem.eql(u8, name, "embed") or std.mem.eql(u8, name, "object")) {
        // A decoded picture has its own size; one given dimension keeps
        // its ratio. Without one: a placeholder, 2:1.
        if (l.images) |imgs| if (imgs.get(node)) |bm| {
            const iw: f64 = @floatFromInt(bm.w);
            const ih: f64 = @floatFromInt(bm.h);
            if (w == null and h == null) return .{ iw, ih };
            if (w == null) return .{ h.? * iw / ih, h.? };
            if (h == null) return .{ w.?, w.? * ih / iw };
            return .{ w.?, h.? };
        };
        if (w == null and h == null) return .{ 300, 150 };
        if (w == null) return .{ h.? * 2, h.? };
        if (h == null) return .{ w.?, w.? / 2 };
        return .{ w.?, h.? };
    }
    if (std.mem.eql(u8, name, "textarea")) return .{ w orelse em * 20, h orelse em * 1.2 * 3 };
    if (std.mem.eql(u8, name, "select")) return .{ w orelse em * 8, h orelse em * 1.5 };
    if (std.mem.eql(u8, name, "button")) {
        const font = fontOf(st);
        const label = doc.textContent(node, l.a) catch "";
        return .{ w orelse (l.fonts.advance(font, label) + em), h orelse em * 1.5 };
    }
    // input: by type.
    const t = doc.getAttr(node, "type") orelse "text";
    if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) return .{ w orelse 13, h orelse 13 };
    if (std.ascii.eqlIgnoreCase(t, "submit") or std.ascii.eqlIgnoreCase(t, "button") or std.ascii.eqlIgnoreCase(t, "reset")) {
        const font = fontOf(st);
        const label = doc.getAttr(node, "value") orelse "Submit";
        return .{ w orelse (l.fonts.advance(font, label) + em), h orelse em * 1.5 };
    }
    if (std.ascii.eqlIgnoreCase(t, "hidden")) return .{ 0, 0 };
    return .{ w orelse em * 12, h orelse em * 1.5 };
}

/// A fragment being assembled on the current line.
const Pending = struct {
    item: Item,
    x: f64,
    /// The index of the item after this one (to resume from a break).
    item_index_after: usize,
};

/// Lay out the inline content of block container `id` into line
/// boxes; returns the content height.
fn layoutInlineContent(l: *Layout, id: BoxId, bfc: *Bfc) Error!f64 {
    const b = l.box(id);
    const st = b.style;
    const cx = b.contentX();
    const cw = b.contentW();
    var y = b.contentY();
    const items = try collectItems(l, id, l.fonts);
    const strut_font = fontOf(st);
    const strut_m = l.fonts.metrics(strut_font);
    const strut_lh = st.lineHeightPx();
    var pending: std.ArrayList(Pending) = .empty;
    var i: usize = 0;
    var first_line = true;
    var open_stack: std.ArrayList(BoxId) = .empty; // inline boxes open at line start
    var line_open: std.ArrayList(BoxId) = .empty;
    while (i < items.len or pending.items.len > 0) {
        // The line's horizontal extent between floats.
        const bounds = floatBounds(l, bfc, y, y + strut_lh, cx, cx + cw);
        const indent: f64 = if (first_line) resolveLP(st.text_indent, cw) else 0;
        const line_x = bounds.left + indent;
        var avail = bounds.right - line_x;
        // Marker outside: painted left of the first line.
        var x: f64 = line_x;
        pending.clearRetainingCapacity();
        line_open.clearRetainingCapacity();
        try line_open.appendSlice(l.a, open_stack.items);
        var last_break: ?usize = null; // index in pending after which we may break
        var forced = false;
        var consumed = i;
        var float_here: std.ArrayList(BoxId) = .empty;
        while (consumed < items.len) {
            const it = items[consumed];
            if (it.kind == .br or it.kind == .newline) {
                consumed += 1;
                forced = true;
                break;
            }
            if (it.kind == .atomic and l.get(it.box).isFloat()) {
                // A float already placed (this line was re-run) stays.
                if (!l.get(it.box).laid_out) try float_here.append(l.a, it.box);
                consumed += 1;
                continue;
            }
            // A collapsible space at the line start is dropped.
            if (it.kind == .space and !it.no_break and pending.items.len == 0 and it.text.len == 1 and l.get(it.box).style.white_space != .pre_wrap and l.get(it.box).style.white_space != .break_spaces) {
                consumed += 1;
                continue;
            }
            if (it.kind == .space and pending.items.len == 0 and st.white_space == .normal) {
                consumed += 1;
                continue;
            }
            const fits = x - line_x + it.w <= avail + 0.001;
            if (!fits and pending.items.len > 0 and (it.kind == .text or it.kind == .atomic or (it.kind == .space and it.no_break))) {
                // Break at the last opportunity, or before this item.
                if (last_break) |lb| {
                    consumed = pending.items[lb].item_index_after;
                    pending.items.len = lb + 1;
                } else break;
                break;
            }
            if (!fits and pending.items.len == 0 and it.kind == .text) {
                // Nothing fits on this line: if floats narrow it, move
                // below them; else the word overflows.
                if (nextFloatEdge(l, bfc, y)) |ny| if (bounds.left > cx or bounds.right < cx + cw) {
                    y = ny;
                    continue;
                };
            }
            try pending.append(l.a, .{ .item = it, .x = x, .item_index_after = consumed + 1 });
            x += it.w;
            if (it.kind == .space and !it.no_break) last_break = pending.items.len - 1;
            if (it.kind == .text and endsWithCjk(it.text)) last_break = pending.items.len - 1;
            if (it.kind == .inline_open) try line_open.append(l.a, it.box);
            if (it.kind == .inline_close) {
                if (line_open.items.len > 0) line_open.items.len -= 1;
            }
            consumed += 1;
        }
        // Trailing collapsible spaces come off the line.
        while (pending.items.len > 0) {
            const last = pending.items[pending.items.len - 1];
            if (last.item.kind == .space and !last.item.no_break and last.item.text.len == 1 and l.get(last.item.box).style.white_space != .pre_wrap) {
                pending.items.len -= 1;
            } else break;
        }
        // Floats met on this line go beside it (or below it if they do
        // not fit), then the line is measured against them again.
        var refit = false;
        for (float_here.items) |fid| {
            const line_w = if (pending.items.len > 0) pending.items[pending.items.len - 1].x + pending.items[pending.items.len - 1].item.w - line_x else 0;
            const start_y = y;
            try placeFloat(l, fid, bfc, cx, cw, start_y);
            const nb = floatBounds(l, bfc, y, y + strut_lh, cx, cx + cw);
            if (nb.right - nb.left < line_w) {
                // No room beside: the float goes below this line.
                const rec = &l.floats.items[l.floats.items.len - 1];
                const dy = (y + strut_lh) - rec.y;
                try moveBox(l, fid, 0, dy);
                rec.y += dy;
            } else refit = true;
        }
        if (refit and pending.items.len > 0) {
            // Re-run this line with the narrowed bounds.
            const nb = floatBounds(l, bfc, y, y + strut_lh, cx, cx + cw);
            if (nb.left != bounds.left or nb.right != bounds.right) continue;
        }
        i = consumed;
        if (pending.items.len == 0 and !forced and i >= items.len) break;
        // The line's height and baseline from its fragments.
        var above: f64 = strut_m.ascent + (strut_lh - (strut_m.ascent + strut_m.descent)) / 2;
        var below: f64 = strut_lh - above;
        if (pending.items.len == 0 and forced) {
            // An empty line still has the strut's height.
        }
        const first_frag: u32 = @intCast(l.fragments.items.len);
        for (pending.items) |p| {
            const it = p.item;
            const ib = l.get(it.box);
            switch (it.kind) {
                .text, .space, .marker => {
                    const lh = ib.style.lineHeightPx();
                    const half = (lh - it.h) / 2;
                    const shift = baselineShift(ib.style, it.h, it.baseline);
                    above = @max(above, it.baseline + half - shift);
                    below = @max(below, (it.h - it.baseline) + half + shift);
                },
                .atomic => {
                    const va = ib.style.vertical_align;
                    switch (va) {
                        .top, .bottom => {},
                        else => {
                            const shift = baselineShift(ib.style, it.h, it.baseline);
                            above = @max(above, it.baseline - shift);
                            below = @max(below, it.h - it.baseline + shift);
                        },
                    }
                },
                else => {},
            }
        }
        var line_h = above + below;
        for (pending.items) |p| if (p.item.kind == .atomic and (p.item.box != 0) and (l.get(p.item.box).style.vertical_align == .top or l.get(p.item.box).style.vertical_align == .bottom)) {
            line_h = @max(line_h, p.item.h);
        };
        const baseline = y + above;
        // Horizontal alignment.
        var used: f64 = if (pending.items.len > 0) pending.items[pending.items.len - 1].x + pending.items[pending.items.len - 1].item.w - line_x else 0;
        avail = bounds.right - line_x;
        var shift_x: f64 = 0;
        var justify_extra: f64 = 0;
        const last_line = i >= items.len or forced;
        switch (st.text_align) {
            .right, .end => shift_x = @max(0, avail - used),
            .center => shift_x = @max(0, (avail - used) / 2),
            .justify => if (!last_line) {
                var spaces: f64 = 0;
                for (pending.items) |p| if (p.item.kind == .space) {
                    spaces += 1;
                };
                if (spaces > 0) justify_extra = @max(0, avail - used) / spaces;
            },
            else => {},
        }
        var extra_so_far: f64 = 0;
        for (pending.items) |p| {
            const it = p.item;
            const ib = l.get(it.box);
            var fx = p.x + shift_x + extra_so_far;
            if (it.kind == .space) extra_so_far += justify_extra;
            const fw = if (it.kind == .space) it.w + justify_extra else it.w;
            switch (it.kind) {
                .text, .space, .marker => {
                    const shift = baselineShift(ib.style, it.h, it.baseline);
                    try l.fragments.append(l.a, .{ .box = it.box, .kind = if (it.kind == .marker) .marker else .text, .x = fx, .y = baseline - shift - it.baseline, .w = fw, .h = it.h, .baseline = baseline - shift, .text = it.text });
                },
                .atomic => {
                    const va = ib.style.vertical_align;
                    const top: f64 = switch (va) {
                        .top => y,
                        .bottom => y + line_h - it.h,
                        else => baseline - baselineShift(ib.style, it.h, it.baseline) - it.baseline,
                    };
                    try moveBox(l, it.box, fx + ib.margin[3] - ib.x, top + ib.margin[0] - ib.y);
                    try l.fragments.append(l.a, .{ .box = it.box, .kind = .atomic, .x = fx, .y = top, .w = fw, .h = it.h, .baseline = baseline });
                },
                .inline_open => try l.fragments.append(l.a, .{ .box = it.box, .kind = .inline_open, .x = fx, .y = y, .w = fw, .h = line_h, .baseline = baseline }),
                .inline_close => try l.fragments.append(l.a, .{ .box = it.box, .kind = .inline_close, .x = fx, .y = y, .w = fw, .h = line_h, .baseline = baseline }),
                else => {},
            }
            _ = &fx;
        }
        // Inline boxes spanning this line: one span fragment each, from
        // its open (or the line start) to its close (or the line end).
        try spanFragments(l, id, first_frag, line_x + shift_x, line_x + shift_x + used + extra_so_far, y, line_h, baseline);
        used = used;
        try b.lines.append(l.a, .{ .x = line_x, .y = y, .w = avail, .h = line_h, .baseline = baseline, .first_frag = first_frag, .frag_count = @intCast(l.fragments.items.len - first_frag) });
        if (b.first_baseline == null) b.first_baseline = baseline;
        b.last_baseline = baseline;
        // Inline boxes still open carry to the next line.
        open_stack.clearRetainingCapacity();
        try open_stack.appendSlice(l.a, line_open.items);
        y += line_h;
        first_line = false;
        if (i >= items.len and !forced) break;
        if (i >= items.len and forced and pending.items.len == 0) break;
    }
    // An outside marker sits left of the first line.
    if (b.marker_text.len > 0 and st.list_style_position == .outside and b.lines.items.len > 0) {
        const font = fontOf(st);
        const m = l.fonts.metrics(font);
        const mw = l.fonts.advance(font, b.marker_text);
        const ln = b.lines.items[0];
        try l.fragments.append(l.a, .{ .box = id, .kind = .marker, .x = ln.x - mw, .y = ln.baseline - m.ascent, .w = mw, .h = m.ascent + m.descent, .baseline = ln.baseline, .text = b.marker_text });
        b.lines.items[0].frag_count += 1;
        // Fragments must be contiguous per line: this one is appended
        // after the first line's, which is fine only when it is the last
        // line too; otherwise swap it into place.
        if (b.lines.items.len > 1) {
            const last_idx = l.fragments.items.len - 1;
            const want = ln.first_frag + ln.frag_count - 1;
            const moved = l.fragments.items[last_idx];
            var k = last_idx;
            while (k > want) : (k -= 1) l.fragments.items[k] = l.fragments.items[k - 1];
            l.fragments.items[want] = moved;
            for (b.lines.items[1..]) |*later| later.first_frag += 1;
        }
    }
    return y - b.contentY();
}

fn endsWithCjk(text: []const u8) bool {
    if (text.len == 0) return false;
    var i: usize = text.len - 1;
    while (i > 0 and (text[i] & 0xc0) == 0x80) i -= 1;
    const cp = std.unicode.utf8Decode(text[i..]) catch return false;
    return isCjk(cp);
}

/// How far above the baseline a fragment's own baseline sits, from
/// `vertical-align`.
fn baselineShift(st: *const Computed, h: f64, baseline: f64) f64 {
    return switch (st.vertical_align) {
        .baseline, .top, .bottom => 0,
        .sub => -st.font_size * 0.3,
        .super => st.font_size * 0.3,
        .middle => (h / 2 - baseline) + st.font_size * 0.25,
        .text_top => baseline - st.font_size * 0.8,
        .text_bottom => -((h - baseline) - st.font_size * 0.2),
        .length => |lp| resolveLP(lp, st.lineHeightPx()),
    };
}

/// For each inline box with content on this line, a span fragment from
/// its open fragment (or the line start, when it opened earlier) to its
/// close fragment (or the line end).
fn spanFragments(l: *Layout, container: BoxId, first_frag: u32, line_start: f64, line_end: f64, y: f64, h: f64, baseline: f64) Error!void {
    _ = container;
    const frags = l.fragments.items[first_frag..];
    // Boxes seen on this line, in order of first appearance.
    var seen: std.ArrayList(BoxId) = .empty;
    for (frags) |f| {
        const fb = l.get(f.box);
        // An inline box is any ancestor inline of a fragment up to the
        // container; spans cover the box's own open/close and its content.
        var p: ?BoxId = if (f.kind == .inline_open or f.kind == .inline_close) f.box else fb.parent;
        if (f.kind == .text or f.kind == .atomic) p = fb.parent;
        while (p) |pid| : (p = l.get(pid).parent) {
            const pb = l.get(pid);
            if (pb.kind != .inline_box) break;
            var known = false;
            for (seen.items) |s| if (s == pid) {
                known = true;
            };
            if (!known) try seen.append(l.a, pid);
        }
        if (f.kind == .inline_open or f.kind == .inline_close) {
            var known = false;
            for (seen.items) |s| if (s == f.box) {
                known = true;
            };
            if (!known) try seen.append(l.a, f.box);
        }
    }
    for (seen.items) |bid| {
        var x0 = line_start;
        var x1 = line_end;
        var opened = false;
        var closed = false;
        for (frags) |f| {
            if (f.box == bid and f.kind == .inline_open) {
                x0 = f.x;
                opened = true;
            }
            if (f.box == bid and f.kind == .inline_close) {
                x1 = f.x + f.w;
                closed = true;
            }
        }
        if (!opened or !closed) {
            // Extend to the box's content extent on this line.
            var lo: ?f64 = null;
            var hi: ?f64 = null;
            for (frags) |f| {
                if (!isInsideInline(l, f.box, bid)) continue;
                lo = if (lo) |v| @min(v, f.x) else f.x;
                hi = if (hi) |v| @max(v, f.x + f.w) else f.x + f.w;
            }
            if (!opened) x0 = lo orelse x0;
            if (!closed) x1 = hi orelse x1;
        }
        const ib = l.get(bid);
        const font = fontOf(ib.style);
        const m = l.fonts.metrics(font);
        const top = baseline - m.ascent - ib.padding[0] - ib.border[0];
        const bottom = baseline + m.descent + ib.padding[2] + ib.border[2];
        _ = y;
        _ = h;
        try l.fragments.append(l.a, .{ .box = bid, .kind = .inline_span, .x = x0, .y = top, .w = @max(0, x1 - x0), .h = bottom - top, .baseline = baseline, .text = if (opened) (if (closed) "oc" else "o") else (if (closed) "c" else "") });
    }
}

fn isInsideInline(l: *const Layout, frag_box: BoxId, inline_box: BoxId) bool {
    var p: ?BoxId = frag_box;
    while (p) |pid| : (p = l.get(pid).parent) if (pid == inline_box) return true;
    return false;
}

// ------------------------------------------------------------------ tests

const html = @import("html.zig");

fn layoutText(a: std.mem.Allocator, src: []const u8, w: f64) !*Layout {
    const doc = try html.parse(a, src, .{});
    const env: style.Env = .{ .width = w, .height = 300 };
    const sheets = try style.collectDocumentSheets(a, doc, env);
    const styles = try a.create(style.Styles);
    styles.* = try style.compute(a, doc, sheets, env);
    var fixed: FixedFonts = .{};
    return layoutDocument(a, doc, styles, fixed.fonts(), w, 300);
}

fn boxOf(l: *const Layout, doc: *const dom.Document, sel_text: []const u8) *const Box {
    const selectors = @import("selectors.zig");
    const sel = selectors.Selector.parse(l.a, sel_text) catch unreachable;
    const id = sel.queryFirst(doc, dom.document_id).?;
    for (l.boxes.items) |*b| if (b.node == id) return b;
    unreachable;
}

test "layout: blocks stack, margins collapse, widths fill" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0'><div id=a style='height:10px;margin:20px 0'></div><div id=b style='height:10px;margin:30px 0;width:50%'></div><p style='margin:0'>x</p>", 400);
    const doc = l.doc;
    const ba = boxOf(l, doc, "#a");
    const bb = boxOf(l, doc, "#b");
    try std.testing.expectEqual(@as(f64, 20), ba.y);
    try std.testing.expectEqual(@as(f64, 400), ba.w);
    // 20 + 10, then the larger of 20 and 30.
    try std.testing.expectEqual(@as(f64, 60), bb.y);
    try std.testing.expectEqual(@as(f64, 200), bb.w);
    const bp = boxOf(l, doc, "p");
    try std.testing.expectEqual(@as(f64, 100), bp.y);
    try std.testing.expectEqual(@as(usize, 1), bp.lines.items.len);
}

test "layout: lines wrap, floats intrude, inline-block sits on the baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // 16px font: 8px per cell; "aaaa bbbb cccc" is 14 cells = 112px.
    const l = try layoutText(a, "<body style='margin:0;font-size:16px;line-height:20px'><p style='margin:0;width:80px'>aaaa bbbb cccc</p><div id=f style='float:left;width:50px;height:50px'></div><p id=q style='margin:0'>zz</p>", 400);
    const doc = l.doc;
    const bp = boxOf(l, doc, "p");
    try std.testing.expectEqual(@as(usize, 2), bp.lines.items.len);
    try std.testing.expectEqual(@as(f64, 40), bp.h);
    const f = boxOf(l, doc, "#f");
    try std.testing.expectEqual(@as(f64, 40), f.y);
    const q = boxOf(l, doc, "#q");
    try std.testing.expectEqual(@as(f64, 40), q.y);
    // The line starts right of the float.
    try std.testing.expectEqual(@as(f64, 50), q.lines.items[0].x);
}

// ------------------------------------------------------------ hit testing

/// The element under document point (x, y): the deepest box whose
/// border box holds the point, text counting for its parent element;
/// null over the canvas alone. A host's click or hover starts here and
/// walks the DOM up to what it wants (a link, a control).
pub fn hitTest(l: *const Layout, x: f64, y: f64) ?NodeId {
    var best: ?BoxId = null;
    var best_depth: usize = 0;
    for (l.boxes.items, 0..) |b, i| {
        if (b.kind == .root) continue;
        const inside = switch (b.kind) {
            .text, .inline_box => fragmentHolds(l, @intCast(i), x, y),
            else => b.laid_out and x >= b.x and x < b.x + b.w and y >= b.y and y < b.y + b.h,
        };
        if (!inside) continue;
        const depth = boxDepth(l, @intCast(i));
        if (best == null or depth >= best_depth) {
            best = @intCast(i);
            best_depth = depth;
        }
    }
    const id = best orelse return null;
    var b = l.get(id);
    while (b.node == null or l.doc.get(b.node.?).kind != .element) {
        const p = b.parent orelse return null;
        b = l.get(p);
    }
    return b.node;
}

fn boxDepth(l: *const Layout, id: BoxId) usize {
    var d: usize = 0;
    var b = l.get(id);
    while (b.parent) |p| : (b = l.get(p)) d += 1;
    return d;
}

/// Inline content has no box of its own on the page: it is where its
/// fragments landed on the lines of the block that holds it.
fn fragmentHolds(l: *const Layout, id: BoxId, x: f64, y: f64) bool {
    for (l.fragments.items) |f| {
        if (f.box != id) continue;
        if (x >= f.x and x < f.x + f.w and y >= f.y and y < f.y + f.h) return true;
    }
    return false;
}

test "layout: hit test finds the link under a point" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try html.parse(a, "<body style='margin:0;font-size:16px;line-height:20px'><div style='height:40px'></div><p style='margin:0'>go <a href='x.html'>there</a> now</p>", .{});
    const env: style.Env = .{ .width = 320, .height = 240 };
    const sheets = try style.collectDocumentSheets(a, doc, env);
    const styles = try a.create(style.Styles);
    styles.* = try style.compute(a, doc, sheets, env);
    var fixed: FixedFonts = .{};
    const l = try layoutDocument(a, doc, styles, fixed.fonts(), 320, 240);
    // "go " is 3 cells of 8px; the link starts at x=24 on the line at y=40.
    const hit = hitTest(l, 30, 50) orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.isHtml(hit, "a"));
    const before = hitTest(l, 5, 50) orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.isHtml(before, "p"));
    const above = hitTest(l, 5, 10) orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.isHtml(above, "div"));
}
