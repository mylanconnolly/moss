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
//! `text-indent`, quirks mode's line heights), relative and absolute
//! positioning, flexbox (Level 1) and tables (CSS 2.1 §17's auto
//! layout: anonymous parts, spans, percentage columns). Replaced
//! elements (pictures, inline `<svg>`, controls) size by their ratio on
//! every path. Text is measured through `Fonts`, an interface the page
//! domain implements over its typefaces and a test over fixed cells,
//! so the whole engine runs on the host. Coordinates are document
//! pixels as `f64`; the painter rounds.
//!
//! Grid (Level 1's core) lays out too.
//!
//! Not built (the arc's stage 9): subgrid, `position: sticky` beyond
//! relative, merged collapsed table borders, bidi and complex shaping,
//! hyphenation, `overflow: scroll` scrolling inside a box.
const std = @import("std");
const store = @import("store.zig");
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
/// `density` is its pixels per CSS pixel: 1 for a PNG or JPEG, the zoom
/// for an SVG the page rasterized at it (so it paints pixel for pixel).
pub const Bitmap = struct { w: u32, h: u32, rgba: []const u8, density: f64 = 1 };

/// What layout (and paint) ask of images: the picture for a node, if
/// the host has decoded one. An `img` without one is sized by its
/// attributes or a placeholder.
pub const Images = struct {
    ctx: *anyopaque,
    vtable: *const VTable,

    pub const VTable = struct {
        get: *const fn (ctx: *anyopaque, node: NodeId) ?Bitmap,
        /// A `background-image` url as written, and the URL of the sheet
        /// that declared it (null: the page's).
        background: ?*const fn (ctx: *anyopaque, url: []const u8, base: ?[]const u8) ?Bitmap = null,
    };

    pub fn get(i: Images, node: NodeId) ?Bitmap {
        return i.vtable.get(i.ctx, node);
    }

    pub fn background(i: Images, url: []const u8, base: ?[]const u8) ?Bitmap {
        const f = i.vtable.background orelse return null;
        return f(i.ctx, url, base);
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

    /// The Ahem face (`font-family: Ahem`, WPT's test font): every glyph
    /// a square the font size wide and tall — ascent 0.8, descent 0.2 —
    /// `X` and the rest solid, a space blank, `p` the descender part
    /// alone, `É` the ascender part alone.
    fn isAhem(font: Font) bool {
        for (font.families) |f| {
            if (std.ascii.eqlIgnoreCase(f, "ahem")) return true;
            break;
        }
        return false;
    }

    fn cellW(font: Font) f64 {
        if (isAhem(font)) return @max(1, @round(font.size));
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
            if (isAhem(font)) {
                // Exact squares, no inset: the glyph is the box.
                const y0: f64 = if (cp == 'p') baseline else top;
                const gh: f64 = if (cp == 'p') h - asc else if (cp == 0xc9) asc else h;
                if (px < 0 or y0 < 0) continue;
                canvas.fillRect(@intFromFloat(@round(px)), @intFromFloat(@round(y0)), @intFromFloat(cw), @intFromFloat(gh), color);
                continue;
            }
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
    /// Left behind by a subtree laid out again (a flex item measured,
    /// then sized): no line reaches it, and every scan of the list skips
    /// it. Removing it instead would shift the indexes every other
    /// line holds into this list (2026-09-18).
    dead: bool = false,
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
    /// How far relative positioning and `transform` moved the box from
    /// where the flow placed it: what follows in the flow ignores it.
    rel_dx: f64 = 0,
    rel_dy: f64 = 0,
    /// A scroll container's offset (the host keeps it across layouts
    /// and sets it after each): its content paints that much higher.
    scroll_top: f64 = 0,
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
    /// Preferred and content-only widths by box, measured once a layout.
    /// One entry per box, appended as boxes are seen (chunked: the
    /// doubling `resize` of a list left its old buffers in the arena).
    preferred_widths: store.Chunked(?Widths, 8) = .{},
    content_widths: store.Chunked(?Widths, 8) = .{},
    a: std.mem.Allocator,
    doc: *const Document,
    styles: *const style.Styles,
    fonts: Fonts,
    /// The host's pictures, if it has any.
    images: ?Images = null,
    /// A `position: fixed` box exists: the viewport's rows no longer
    /// move rigidly with a scroll (a host repaints whole).
    has_fixed: bool = false,
    /// A `position: sticky` box exists (the same consequence).
    has_sticky: bool = false,
    /// Some container is scrolled (the host set a `scroll_top`).
    has_scrolled: bool = false,
    /// Chunked lists (`store`): an append never moves a box or a
    /// fragment, and a bump arena never pays for a doubling.
    boxes: store.Chunked(Box, 8) = .{},
    fragments: store.Chunked(Fragment, 9) = .{},
    /// A stack for what one inline layout or measurement needs and
    /// drops — its items, its open-box lists — marked and released
    /// around each; the layout arena is a bump allocator, and a
    /// container measuring and placing its subtrees left 255,000 such
    /// lists behind on the Guardian's front page (2026-09-28). Full,
    /// it falls back to the arena.
    scratch_buf: []u8 = &.{},
    scratch_fba: std.heap.FixedBufferAllocator = undefined,
    /// Dead fragments in the store (see `resetLines`).
    dead_fragments: usize = 0,
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
        return l.boxes.at(id);
    }
    pub fn get(l: *const Layout, id: BoxId) *const Box {
        return l.boxes.get(id);
    }
};

const FloatRec = struct { box: BoxId, x: f64, y: f64, w: f64, h: f64, left: bool, bfc: BoxId };

/// Lay out a document for a viewport. The styles must be the ones
/// computed for it; the result's boxes hold every position a painter
/// needs.
pub fn layoutDocument(a: std.mem.Allocator, doc: *const Document, styles: *const style.Styles, fonts: Fonts, viewport_w: f64, viewport_h: f64) Error!*Layout {
    return layoutDocumentWith(a, doc, styles, fonts, null, viewport_w, viewport_h);
}

/// The layout under construction, for a page that runs out of memory
/// building it to say how far it got: set until the layout succeeds, so
/// the caller's error path still finds it (a `defer` cleared it first);
/// a page clears it when it resets its layout arena, since the struct
/// lives there.
pub var in_progress: ?*const Layout = null;

/// The same, with the host's pictures for `img` sizes.
pub fn layoutDocumentWith(a: std.mem.Allocator, doc: *const Document, styles: *const style.Styles, fonts: Fonts, images: ?Images, viewport_w: f64, viewport_h: f64) Error!*Layout {
    const l = try a.create(Layout);
    l.* = .{ .a = a, .doc = doc, .styles = styles, .fonts = fonts, .images = images, .viewport_w = viewport_w, .viewport_h = viewport_h };
    l.scratch_buf = try a.alloc(u8, scratch_size);
    l.scratch_fba = std.heap.FixedBufferAllocator.init(l.scratch_buf);
    in_progress = l;
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
    // By index: laying one out can add those inside it to the list.
    var ai: usize = 0;
    while (ai < l.absolutes.items.len) : (ai += 1) {
        const ab = l.absolutes.items[ai];
        try layoutAbsolute(l, ab.box, ab.cb);
    }
    for (l.absolutes.items) |ab| {
        const b = l.get(ab.box);
        root.h = @max(root.h, b.y + b.h);
    }
    l.height = root.h;
    in_progress = null;
    return l;
}

// --------------------------------------------------------- box building

fn addBox(l: *Layout, parent: BoxId, b: Box) Error!BoxId {
    var nb = b;
    nb.parent = parent;
    try l.boxes.append(l.a, nb);
    const id: BoxId = @intCast(l.boxes.len - 1);
    try l.box(parent).children.append(l.a, id);
    return id;
}

fn isBlockDisplay(d: style.Display) bool {
    return switch (d) {
        .block, .list_item, .flex, .grid, .table, .table_row, .table_row_group, .table_header_group, .table_footer_group, .table_caption, .table_cell, .flow_root => true,
        else => false,
    };
}

fn isInlineBlockDisplay(d: style.Display) bool {
    return switch (d) {
        .inline_block, .inline_flex, .inline_grid, .inline_table => true,
        else => false,
    };
}

/// Elements whose content is not laid out as their children (replaced
/// or form controls): an atomic inline with a size of its own. A
/// `button` is not one: its content is laid out, in its own face.
fn isReplaced(l: *const Layout, id: NodeId) bool {
    const doc = l.doc;
    const n = doc.get(id);
    // An `<object>` is a picture only once its data has decoded; until
    // then (and when it never does: an unknown type, a 404) its content
    // is its fallback, laid out as any element's.
    if (n.namespace == .html and std.mem.eql(u8, n.name, "object")) {
        const imgs = l.images orelse return false;
        return imgs.get(id) != null;
    }
    // An outermost `<svg>` in HTML is a picture of its own markup.
    if (n.namespace == .svg and std.mem.eql(u8, n.name, "svg")) {
        const p = n.parent orelse return true;
        return doc.get(p).namespace != .svg;
    }
    return n.namespace == .html and (std.mem.eql(u8, n.name, "img") or std.mem.eql(u8, n.name, "input") or std.mem.eql(u8, n.name, "select") or std.mem.eql(u8, n.name, "textarea") or std.mem.eql(u8, n.name, "video") or std.mem.eql(u8, n.name, "canvas") or std.mem.eql(u8, n.name, "iframe") or std.mem.eql(u8, n.name, "svg") or std.mem.eql(u8, n.name, "embed") or std.mem.eql(u8, n.name, "object") or std.mem.eql(u8, n.name, "meter") or std.mem.eql(u8, n.name, "progress"));
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
    // Columns size nothing yet (their widths are not read): no boxes.
    if (st.display == .table_column or st.display == .table_column_group) return;
    if (st.display == .contents) {
        var c = n.first_child;
        while (c) |cid| : (c = doc.get(cid).next) try buildBoxes(l, parent, cid);
        return;
    }
    const replaced = isReplaced(l, id);
    var kind: Kind = .inline_box;
    if (replaced) {
        kind = if (isBlockDisplay(st.display)) .block else .inline_block;
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
    if (isFlexDisplay(st.display) or isGridDisplay(st.display)) {
        // A grid's children become items exactly as a flex container's.
        try wrapFlexItems(l, bid);
    } else if (kind == .block or kind == .inline_block) {
        try fixTableParts(l, bid);
        try wrapInlines(l, bid);
    }
}

fn isFlexDisplay(d: style.Display) bool {
    return d == .flex or d == .inline_flex;
}

fn isFlexContainer(b: *const Box) bool {
    return (b.kind == .block or b.kind == .inline_block) and isFlexDisplay(b.style.display);
}

/// A flex container's children become flex items: every in-flow element
/// child is blockified (its own box, laid out as a block whatever its
/// display), each run of text becomes an anonymous block item, and
/// whitespace-only text between items is nothing. Floats do not float
/// in a flex container; absolutes stay out of flow.
fn wrapFlexItems(l: *Layout, id: BoxId) Error!void {
    try splitInlines(l, id);
    const old = try l.a.dupe(BoxId, l.get(id).children.items);
    l.box(id).children = .empty;
    var anon: ?BoxId = null;
    for (old) |c| {
        const cb = l.box(c);
        if (cb.isPositioned()) {
            try l.box(id).children.append(l.a, c);
            anon = null;
            continue;
        }
        if (cb.kind == .text) {
            if (isBlank(cb.text) and cb.style.white_space != .pre and cb.style.white_space != .pre_wrap) continue;
            if (anon == null) {
                try l.boxes.append(l.a, .{ .kind = .anon_block, .node = null, .style = try anonStyle(l, l.get(id).style), .parent = id });
                anon = @intCast(l.boxes.len - 1);
                try l.box(id).children.append(l.a, anon.?);
            }
            try l.box(anon.?).children.append(l.a, c);
            l.box(c).parent = anon;
            continue;
        }
        anon = null;
        // Blockified: an inline element, an inline-block, a br, a marker
        // all lay out as a block-level item of their own. (`wrapInlines`
        // appends boxes, so the box is fetched again after it: a pointer
        // held across the append wrote into a freed list and made the
        // tree a cycle, 2026-09-18.)
        const kind = cb.kind;
        if (kind == .inline_box or kind == .inline_block or kind == .br) {
            if (kind == .inline_box) try wrapInlines(l, c);
            l.box(c).kind = .block;
        }
        try l.box(id).children.append(l.a, c);
    }
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
        .lower_roman => blk: {
            var buf: [16]u8 = undefined;
            break :blk try std.fmt.allocPrint(l.a, "{s}. ", .{roman(&buf, n, false)});
        },
        .upper_roman => blk: {
            var buf: [16]u8 = undefined;
            break :blk try std.fmt.allocPrint(l.a, "{s}. ", .{roman(&buf, n, true)});
        },
        else => "",
    };
}

// Into the caller's buffer: nothing a user program links may be
// `threadlocal` (no thread-local storage there; see encoding.zig).
fn roman(roman_buf: *[16]u8, n_in: usize, upper: bool) []const u8 {
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
                anon = @intCast(l.boxes.len - 1);
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
    return @intCast(l.boxes.len - 1);
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
        .calc => |m| m.of(base),
    };
}

fn resolveLA(la: style.LengthAuto, base: f64) ?f64 {
    return switch (la) {
        .px => |x| x,
        .percent => |p| base * p / 100,
        .calc => |m| m.of(base),
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
    // Measuring intrinsic widths, a percentage max-width is `none` (it
    // would be of a width the measurement is finding).
    if (measuring > 0 and st.max_width != .px) return @max(out, resolveLP(st.min_width, cb_w) - (if (st.box_sizing == .border_box) horizontalExtras(b) else 0), 0);
    switch (st.max_width) {
        .none => {},
        .px => |x| out = @min(out, if (st.box_sizing == .border_box) x - horizontalExtras(b) else x),
        .percent => |p| out = @min(out, cb_w * p / 100 - (if (st.box_sizing == .border_box) horizontalExtras(b) else 0)),
        .calc => |m| out = @min(out, m.of(cb_w) - (if (st.box_sizing == .border_box) horizontalExtras(b) else 0)),
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
        // Shrink-to-fit: the preferred widths are border-box ones (a
        // float with borders was as wide again as them, 2026-10-07).
        const pref = try preferredWidths(l, id);
        const extras = horizontalExtras(b);
        break :blk @min(@max(pref.min - extras, avail), pref.max - extras);
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
        for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| {
            const f = l.fragments.at(fi);
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
    // The box store is chunked: a box never moves, so its children list
    // is walked in place (a copy per move was 41,000 allocations on the
    // Guardian's front page, whose lines move their boxes at every pass).
    for (b.children.items) |c| try moveBox(l, c, dx, dy);
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
    return b.style.display == .flow_root or b.style.display == .table or b.style.display == .table_cell or b.style.display == .grid or b.style.display == .inline_grid;
}

fn topCollapsible(b: *const Box) bool {
    return b.border[0] == 0 and b.padding[0] == 0 and !isBfcRoot(b) and b.kind != .inline_block;
}

fn bottomCollapsible(b: *const Box) bool {
    return b.border[2] == 0 and b.padding[2] == 0 and !isBfcRoot(b) and b.style.height == .auto and b.style.min_height.px == 0 and b.kind != .inline_block;
}

fn bottomCollapsibleIn(l: *const Layout, b: *const Box) bool {
    return b.border[2] == 0 and b.padding[2] == 0 and !isBfcRoot(b) and heightIsAuto(l, b) and b.style.min_height.px == 0 and b.kind != .inline_block;
}

/// Does this block hold nothing that separates its top and bottom
/// margins (no lines, no in-flow child with content, no height)?
/// Whether a box's `height` is auto for layout: `auto`, or a percentage
/// (or calc) against a containing block whose height is itself auto
/// (CSS 2.1 §10.5 — Acid2's `.empty { height: 10% }` is empty).
fn heightIsAuto(l: *const Layout, b: *const Box) bool {
    switch (b.style.height) {
        .auto => return true,
        .px => return false,
        .percent, .calc => {
            const p = b.parent orelse return true;
            const pb = l.get(p);
            return pb.kind != .root and pb.style.height == .auto;
        },
    }
}

fn collapsesThrough(l: *const Layout, id: BoxId) bool {
    const b = l.get(id);
    if (b.kind == .inline_block or b.kind == .root) return false;
    // A picture or a control has a height of its own (a picture that has
    // not arrived and has no size yet is 0 tall, and still not empty).
    if (isReplacedBox(l, b)) return false;
    if (b.border[0] != 0 or b.padding[0] != 0 or b.border[2] != 0 or b.padding[2] != 0) return false;
    if (!heightIsAuto(l, b) or resolveLP(b.style.min_height, 0) > 0) return false;
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
            try addAbsolute(l, c);
            continue;
        }
        if (cb.isFloat()) {
            try placeFloat(l, c, bfc, cb_x, cb_w, cursor + pending.value());
            continue;
        }
        const top = try collapsedTop(l, c, cb_w);
        // Clearance (CSS 2.1 §9.5.2): where the border edge would land
        // with every margin collapsed — the hypothetical position — is
        // held against the floats to clear; when it is not past them,
        // the edge lands at their bottom, the box's own top margin spent
        // inside the clearance (which may be negative: Acid2's smile).
        if (cb.style.clear != .none) {
            // A first child's top margin already sits above the parent.
            var hyp = pending;
            if (!first_collapsed) {
                hyp.add(top.pos);
                hyp.add(top.neg);
            }
            const hyp_border = cursor + hyp.value();
            const cleared = clearY(l, bfc, cb.style.clear, hyp_border);
            if (cleared > hyp_border) {
                cursor = if (first_collapsed) cleared else cleared - top.value();
                pending = .{};
            }
        }
        if (first_collapsed) {
            // Already above us: the child starts at the content top.
            first_collapsed = false;
        } else {
            pending.add(top.pos);
            pending.add(top.neg);
        }
        if (collapsesThrough(l, c)) {
            // Its bottom margin — and its empty descendants' (Acid2's
            // `.empty` holds a child with a -6em bottom) — join the same
            // pending margin; it takes no room.
            try positionEmptyBlock(l, c, bfc, cb_x, cursor + pending.value(), cb_w);
            const bottom = try collapsedBottom(l, c);
            pending.add(bottom.pos);
            pending.add(bottom.neg);
            continue;
        }
        const y = cursor + pending.value();
        pending = .{};
        try layoutBlockAt(l, c, bfc, cb_x, y, cb_w);
        // A block split out of a relatively positioned inline moves with it.
        const split_off = splitAncestorOffset(l, c, cb_w);
        if (split_off[0] != 0 or split_off[1] != 0) {
            try moveBox(l, c, split_off[0], split_off[1]);
            l.box(c).rel_dx += split_off[0];
            l.box(c).rel_dy += split_off[1];
        }
        const laid = l.get(c);
        cursor = laid.y - laid.rel_dy + laid.h;
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
    // Its own width when it has one: the floats it places go by it.
    b.w = if (resolveLA(b.style.width, cb_w)) |w| (if (b.style.box_sizing == .border_box) w else w + horizontalExtras(b)) else @max(0, cb_w - b.margin[1] - b.margin[3]);
    b.h = 0;
    b.laid_out = true;
    const children = try l.a.dupe(BoxId, b.children.items);
    for (children) |c| {
        const cb = l.get(c);
        // An empty block still places what floats out of it.
        if (cb.isPositioned()) {
            try addAbsolute(l, c);
        } else if (cb.isFloat()) {
            try placeFloat(l, c, bfc, b.x, b.w, y);
        } else try positionEmptyBlock(l, c, bfc, b.x, y, b.w);
    }
}

fn collapsedBottom(l: *Layout, id: BoxId) Error!Margin {
    const b = l.get(id);
    var m: Margin = .{};
    m.add(b.margin[2]);
    if (!bottomCollapsibleIn(l, b) or hasInlineContent(l, id)) return m;
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

/// What a relative box's percentage `top`/`bottom` resolve against: its
/// containing block's content height when that is specified, else
/// nothing (CSS 2.1 §9.3.2: as `auto`).
/// A relative box's vertical inset: a percentage, or a calc with one,
/// against an indefinite containing-block height is `auto`.
fn relativeInset(lp: style.LengthAuto, cb_h: f64, definite: bool) ?f64 {
    switch (lp) {
        .auto => return null,
        .px => |x| return x,
        .percent => |pc| return if (definite) cb_h * pc / 100 else null,
        .calc => |m| return if (definite or m.pct == 0) m.of(cb_h) else null,
    }
}

fn relativeCbDefinite(l: *const Layout, id: BoxId) bool {
    var p = l.get(id).parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (pb.kind == .anon_block or pb.kind == .inline_box) continue;
        if (pb.kind == .root) return false;
        return pb.style.height != .auto;
    }
    return false;
}

fn relativeCbHeight(l: *const Layout, id: BoxId) f64 {
    var p = l.get(id).parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (pb.kind == .anon_block or pb.kind == .inline_box) continue;
        if (pb.kind == .root) return 0;
        return if (pb.style.height == .auto) 0 else pb.contentH();
    }
    return 0;
}

fn containingBlockFor(l: *const Layout, id: BoxId) BoxId {
    // A transformed ancestor is a containing block for absolute and
    // fixed descendants (CSS Transforms §2); a fixed box's is otherwise
    // the viewport: the root, whose height is the viewport's for an
    // absolute (`layoutAbsolute`).
    const fixed = l.get(id).style.position == .fixed;
    var p = l.get(id).parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (pb.kind == .root) return pid;
        if (pb.kind == .anon_block) continue;
        if (pb.style.has_transform) return pid;
        if (!fixed and pb.style.position != .static) return pid;
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
    const replaced_w: ?f64 = if (isReplacedBox(l, b)) blk: {
        for (0..4) |i| b.padding[i] = resolveLP(st.padding[i], cb_w);
        break :blk replacedSize(l, id, cb_w)[0];
    } else if (isTableBox(b)) blk: {
        // A table: its width, or shrink-to-fit — never narrower than its
        // columns' minimum.
        const tw = try tableWidths(l, id);
        const min_c = tw.min - extras;
        if (resolveLA(st.width, cb_w)) |w| break :blk @max(min_c, if (st.box_sizing == .border_box) w - extras else w);
        const avail = cb_w - (margins[3] orelse 0) - (margins[1] orelse 0) - extras;
        break :blk @max(min_c, @min(tw.max - extras, avail));
    } else null;
    if (replaced_w orelse (if (resolveLA(st.width, cb_w)) |w| constrainWidth(b, if (st.box_sizing == .border_box) w - extras else w, cb_w) else null)) |cw| {
        content_w = cw;
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
    if (isReplacedBox(l, b)) {
        // Its height from its width and ratio, whatever laid it out.
        const size = replacedSizeAtWidth(l, id, cb_w, b.contentW());
        b.h = size + verticalExtras(b);
        b.laid_out = true;
        if (st.position == .relative) {
            const cb_h = relativeCbHeight(l, id);
            const definite = relativeCbDefinite(l, id);
            const dx: f64 = resolveLA(st.inset[3], cb_w) orelse -(resolveLA(st.inset[1], cb_w) orelse 0);
            const dy: f64 = relativeInset(st.inset[0], cb_h, definite) orelse -(relativeInset(st.inset[2], cb_h, definite) orelse 0);
            try moveBox(l, id, dx, dy);
            l.box(id).rel_dx += dx;
            l.box(id).rel_dy += dy;
        }
        if (st.position == .sticky) l.has_sticky = true;
        try translateBox(l, id);
        return;
    } else if (isTableBox(b)) {
        content_h = try layoutTableContents(l, id, cb_w);
    } else if (isGridContainer(b)) {
        content_h = try layoutGridContents(l, id, cb_w);
    } else if (isFlexContainer(b)) {
        content_h = try layoutFlexContents(l, id, cb_w);
    } else if (hasInlineContent(l, id)) {
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
        // A list item whose content starts with a block: its outside
        // marker sits on the first line inside it, as a line of its own.
        if (b.marker_text.len > 0 and st.list_style_position == .outside and b.lines.items.len == 0) {
            if (firstLine(l, id)) |ln| {
                const font = fontOf(st);
                const m = l.fonts.metrics(font);
                const mw = l.fonts.advance(font, b.marker_text);
                const first: u32 = @intCast(l.fragments.len);
                try l.fragments.append(l.a, .{ .box = id, .kind = .marker, .x = b.contentX() - mw, .y = ln.baseline - m.ascent, .w = mw, .h = m.ascent + m.descent, .baseline = ln.baseline, .text = b.marker_text });
                try l.box(id).lines.append(l.a, .{ .x = b.contentX(), .y = ln.y, .w = 0, .h = ln.h, .baseline = ln.baseline, .first_frag = first, .frag_count = 1 });
            }
        }
    }
    const cb_h: ?f64 = if (b.parent) |p| (if (l.get(p).style.height == .auto and l.get(p).kind != .root) null else l.get(p).contentH()) else null;
    if (st.height == .px or ((st.height == .percent or st.height == .calc) and cb_h != null)) {
        content_h = resolveLA(st.height, cb_h orelse 0).?;
        if (st.box_sizing == .border_box) content_h -= verticalExtras(b);
    }
    // `max-height` first, then `min-height`: a minimum above the maximum
    // wins (CSS 2.1 §10.7; Acid2's scalp).
    switch (st.max_height) {
        .none => {},
        .px => |x| content_h = @min(content_h, x - (if (st.box_sizing == .border_box) verticalExtras(b) else 0)),
        .percent => |p| if (cb_h) |h| {
            content_h = @min(content_h, h * p / 100 - (if (st.box_sizing == .border_box) verticalExtras(b) else 0));
        },
        .calc => |m| if (cb_h) |h| {
            content_h = @min(content_h, m.of(h) - (if (st.box_sizing == .border_box) verticalExtras(b) else 0));
        },
    }
    content_h = @max(content_h, resolveLP(st.min_height, cb_h orelse 0) - (if (st.box_sizing == .border_box) verticalExtras(b) else 0));
    b.h = @max(0, content_h) + verticalExtras(b);
    b.laid_out = true;
    // Relative positioning shifts the box after layout — the flow it
    // sits in does not move (Acid2's smile: a child moved down by
    // `bottom: -1em` once made its parent 12px taller, 2026-10-07).
    if (st.position == .relative) {
        const rel_h = relativeCbHeight(l, id);
        const definite = relativeCbDefinite(l, id);
        const dx: f64 = resolveLA(st.inset[3], cb_w) orelse -(resolveLA(st.inset[1], cb_w) orelse 0);
        const dy: f64 = relativeInset(st.inset[0], rel_h, definite) orelse -(relativeInset(st.inset[2], rel_h, definite) orelse 0);
        try moveBox(l, id, dx, dy);
        l.box(id).rel_dx += dx;
        l.box(id).rel_dy += dy;
    }
    // A sticky box stays where the flow put it; its stuck offset is the
    // painter's and the hit test's, from the scroll of the moment.
    if (st.position == .sticky) l.has_sticky = true;
    try translateBox(l, id);
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
    if (isReplacedBox(l, b)) {
        content_w = replacedSize(l, id, cb_w)[0];
    } else if (resolveLA(st.width, cb_w)) |w| {
        content_w = if (st.box_sizing == .border_box) w - extras else w;
    } else if (left != null and right != null) {
        content_w = cb_w - left.? - right.? - b.margin[1] - b.margin[3] - extras;
    } else {
        // Shrink-to-fit: the preferred widths are border-box ones.
        const pref = try preferredWidths(l, id);
        const avail = cb_w - (left orelse 0) - (right orelse 0) - b.margin[1] - b.margin[3] - extras;
        content_w = @min(@max(pref.min - extras, avail), pref.max - extras);
    }
    b.w = constrainWidth(b, content_w, cb_w) + extras;
    b.x = if (left) |x| cb_x + x + b.margin[3] else if (right) |r| cb_x + cb_w - r - b.margin[1] - b.w else cb_x + b.margin[3];
    b.y = if (top) |t| cb_y + t + b.margin[0] else if (bottom != null) cb_y else cb_y + b.margin[0];
    try layoutBlockContents(l, id, &inner, cb_w);
    if (top == null and bottom != null) try moveBox(l, id, 0, cb_y + cb_h - bottom.? - b.margin[2] - l.get(id).h - l.get(id).y);
}

// -------------------------------------------------------------- grid

fn isGridDisplay(d: style.Display) bool {
    return d == .grid or d == .inline_grid;
}

fn isGridContainer(b: *const Box) bool {
    return (b.kind == .block or b.kind == .inline_block) and isGridDisplay(b.style.display);
}

const GridItem = struct { box: BoxId, row0: u32, row1: u32, col0: u32, col1: u32 };

/// One axis of the explicit grid with its `auto-fill`/`auto-fit`
/// repeat expanded for `avail`: the tracks, and a map from an explicit
/// line number (1-based, before the expansion) to the line it became.
const Axis = struct {
    tracks: []style.Track,
    names: []const style.LineName,
    repeat_at: u32 = 0,
    repeat_added: u32 = 0,

    fn line(ax: *const Axis, explicit: u32) u32 {
        return if (explicit > ax.repeat_at + 1) explicit + ax.repeat_added else explicit;
    }
    fn explicitLines(ax: *const Axis) u32 {
        return @intCast(ax.tracks.len + 1);
    }
};

fn fixedTrackSize(t: style.TrackSize, avail: ?f64) ?f64 {
    return switch (t) {
        .px => |x| x,
        .percent => |p| if (avail) |a| a * p / 100 else null,
        else => null,
    };
}

fn expandAxis(l: *Layout, list: style.TrackList, avail: ?f64, gap: f64) Error!Axis {
    var tracks: std.ArrayList(style.Track) = .empty;
    const ar = list.auto_repeat orelse {
        try tracks.appendSlice(l.a, list.tracks);
        return .{ .tracks = tracks.items, .names = list.names };
    };
    // How many repetitions fit: each repeated track at its fixed size
    // (its max, else its min), the explicit ones too.
    var count: u32 = 1;
    if (avail) |av| {
        var fixed: f64 = 0;
        for (list.tracks) |t| fixed += (fixedTrackSize(t.max, av) orelse fixedTrackSize(t.min, av) orelse 0) + gap;
        var per: f64 = 0;
        for (ar.tracks) |t| per += (fixedTrackSize(t.max, av) orelse fixedTrackSize(t.min, av) orelse 0) + gap;
        if (per > 0) count = @max(1, @as(u32, @intFromFloat(@floor((av - fixed + gap) / per))));
        count = @min(count, 1000);
    }
    try tracks.appendSlice(l.a, list.tracks[0..@min(ar.at, list.tracks.len)]);
    for (0..count) |_| try tracks.appendSlice(l.a, ar.tracks);
    try tracks.appendSlice(l.a, list.tracks[@min(ar.at, list.tracks.len)..]);
    return .{ .tracks = tracks.items, .names = list.names, .repeat_at = ar.at, .repeat_added = count * @as(u32, @intCast(ar.tracks.len)) };
}

/// A placement's start line (0-based index) and span on one axis, or
/// null for automatic.
const Span = struct { start: ?i64, span: u32 };

fn resolvePlacement(start: style.GridLine, end: style.GridLine, ax: *const Axis, areas: []const style.GridArea, rows: bool) Span {
    const n_lines: i64 = @intCast(ax.tracks.len + 1);
    const lineOf = struct {
        fn f(g: style.GridLine, a: *const Axis, ar: []const style.GridArea, is_rows: bool, is_end: bool, lines: i64) ?i64 {
            switch (g) {
                .line => |n| {
                    if (n > 0) return @as(i64, a.line(@intCast(n))) - 1;
                    return lines + n; // -1 is the last line
                },
                .name => |nm| {
                    for (ar) |area| if (std.mem.eql(u8, area.name, nm)) {
                        return if (is_rows) (if (is_end) area.row1 else area.row0) else (if (is_end) area.col1 else area.col0);
                    };
                    // `name-start` / `name-end` lines, then the name itself.
                    const suffix: []const u8 = if (is_end) "-end" else "-start";
                    for (a.names) |ln| {
                        if (ln.name.len == nm.len + suffix.len and std.mem.startsWith(u8, ln.name, nm) and std.mem.eql(u8, ln.name[nm.len..], suffix)) return @as(i64, a.line(ln.line)) - 1;
                    }
                    for (a.names) |ln| if (std.mem.eql(u8, ln.name, nm)) return @as(i64, a.line(ln.line)) - 1;
                    return null;
                },
                else => return null,
            }
        }
    }.f;
    const s = lineOf(start, ax, areas, rows, false, n_lines);
    const e = lineOf(end, ax, areas, rows, true, n_lines);
    if (s != null and e != null) {
        const lo = @min(s.?, e.?);
        const hi = @max(s.?, e.?);
        return .{ .start = lo, .span = @intCast(@max(1, hi - lo)) };
    }
    if (s) |sv| return .{ .start = sv, .span = if (end == .span) end.span else 1 };
    if (e) |ev| {
        const sp: u32 = if (start == .span) start.span else 1;
        return .{ .start = ev - sp, .span = sp };
    }
    const sp: u32 = if (start == .span) start.span else if (end == .span) end.span else 1;
    return .{ .start = null, .span = sp };
}

/// Place a grid's items: definite placements first, then the rest by
/// the auto-placement cursor (row by row, or column by column). The
/// grid grows implicit tracks as they are needed.
fn placeGridItems(l: *Layout, id: BoxId, cols: *const Axis, rows: *const Axis) Error!struct { items: []GridItem, ncols: u32, nrows: u32 } {
    const st = l.get(id).style;
    const column_flow = st.grid_auto_flow.column;
    var items: std.ArrayList(GridItem) = .empty;
    var pending: std.ArrayList(struct { box: BoxId, r: Span, c: Span }) = .empty;
    var ncols: i64 = @intCast(cols.tracks.len);
    var nrows: i64 = @intCast(rows.tracks.len);
    var min_col: i64 = 0;
    var min_row: i64 = 0;
    for (l.get(id).children.items) |c| {
        const cb = l.get(c);
        if (cb.isPositioned()) {
            try addAbsolute(l, c);
            continue;
        }
        const gp = cb.style.grid_place;
        const r = resolvePlacement(gp[0], gp[2], rows, st.grid_template_areas, true);
        const k = resolvePlacement(gp[1], gp[3], cols, st.grid_template_areas, false);
        try pending.append(l.a, .{ .box = c, .r = r, .c = k });
        if (r.start) |sv| {
            nrows = @max(nrows, sv + r.span);
            min_row = @min(min_row, sv);
        } else nrows = @max(nrows, r.span);
        if (k.start) |sv| {
            ncols = @max(ncols, sv + k.span);
            min_col = @min(min_col, sv);
        } else ncols = @max(ncols, k.span);
    }
    // Lines before the explicit grid (negative indexes) shift it.
    const shift_c: i64 = -min_col;
    const shift_r: i64 = -min_row;
    ncols += shift_c;
    nrows += shift_r;
    if (ncols < 1) ncols = 1;
    // Occupancy, grown as rows (or columns) are added.
    var occ: std.ArrayList(bool) = .empty;
    const major_len: usize = @intCast(if (column_flow) nrows else ncols);
    const Grow = struct {
        fn ensure(a: std.mem.Allocator, o: *std.ArrayList(bool), lines: usize, width: usize) Error!void {
            while (o.items.len < lines * width) try o.append(a, false);
        }
    };
    const width: usize = @max(1, major_len);
    const mark = struct {
        fn f(a: std.mem.Allocator, o: *std.ArrayList(bool), w: usize, minor0: usize, minor_span: usize, major0: usize, major_span: usize) Error!void {
            try Grow.ensure(a, o, minor0 + minor_span, w);
            for (minor0..minor0 + minor_span) |mi| for (major0..@min(w, major0 + major_span)) |ma| {
                o.items[mi * w + ma] = true;
            };
        }
        fn free(o: *const std.ArrayList(bool), w: usize, minor0: usize, minor_span: usize, major0: usize, major_span: usize) bool {
            if (major0 + major_span > w) return false;
            for (minor0..minor0 + minor_span) |mi| for (major0..major0 + major_span) |ma| {
                const idx = mi * w + ma;
                if (idx < o.items.len and o.items[idx]) return false;
            };
            return true;
        }
    };
    // Definite on both axes first.
    for (pending.items) |p| if (p.r.start != null and p.c.start != null) {
        const r0: usize = @intCast(p.r.start.? + shift_r);
        const c0: usize = @intCast(p.c.start.? + shift_c);
        try items.append(l.a, .{ .box = p.box, .row0 = @intCast(r0), .row1 = @intCast(r0 + p.r.span), .col0 = @intCast(c0), .col1 = @intCast(c0 + p.c.span) });
        if (column_flow) try mark.f(l.a, &occ, width, c0, p.c.span, r0, p.r.span) else try mark.f(l.a, &occ, width, r0, p.r.span, c0, p.c.span);
    };
    // Then the rest, in order, by the cursor.
    var cur_minor: usize = 0;
    var cur_major: usize = 0;
    for (pending.items) |p| {
        if (p.r.start != null and p.c.start != null) continue;
        const major_fixed: ?i64 = if (column_flow) p.r.start else p.c.start;
        const minor_fixed: ?i64 = if (column_flow) p.c.start else p.r.start;
        const major_span: usize = @min(width, @as(usize, if (column_flow) p.r.span else p.c.span));
        const minor_span: usize = if (column_flow) p.c.span else p.r.span;
        var mi: usize = if (minor_fixed) |v| @intCast(v + (if (column_flow) shift_c else shift_r)) else if (st.grid_auto_flow.dense) 0 else cur_minor;
        var ma: usize = if (major_fixed) |v| @intCast(v + (if (column_flow) shift_r else shift_c)) else if (st.grid_auto_flow.dense or minor_fixed != null) 0 else cur_major;
        var guard: usize = 0;
        while (guard < 100000) : (guard += 1) {
            if (major_fixed != null) {
                if (mark.free(&occ, width, mi, minor_span, ma, major_span)) break;
                mi += 1;
                continue;
            }
            if (ma + major_span <= width and mark.free(&occ, width, mi, minor_span, ma, major_span)) break;
            ma += 1;
            if (ma + major_span > width) {
                if (minor_fixed != null) {
                    // A fixed row with no room left: past the end.
                    ma = 0;
                    mi += 0;
                    if (guard > width) break;
                    continue;
                }
                ma = 0;
                mi += 1;
            }
        }
        try mark.f(l.a, &occ, width, mi, minor_span, ma, major_span);
        if (major_fixed == null and minor_fixed == null) {
            cur_minor = mi;
            cur_major = ma + major_span;
        }
        const r0 = if (column_flow) ma else mi;
        const c0 = if (column_flow) mi else ma;
        const rs = if (column_flow) major_span else minor_span;
        const cs = if (column_flow) minor_span else major_span;
        try items.append(l.a, .{ .box = p.box, .row0 = @intCast(r0), .row1 = @intCast(r0 + rs), .col0 = @intCast(c0), .col1 = @intCast(c0 + cs) });
    }
    var nr: u32 = @intCast(nrows);
    var nc: u32 = @intCast(ncols);
    for (items.items) |it| {
        nr = @max(nr, it.row1);
        nc = @max(nc, it.col1);
    }
    return .{ .items = items.items, .ncols = nc, .nrows = nr };
}

/// The track sizing algorithm (§12), simplified: fixed tracks at their
/// size; intrinsic ones from their items' contributions (`contrib`
/// gives an item's min and max on this axis), spanning items spread
/// over what they span; free space grows tracks to their limits, then
/// `fr` tracks share what is left (with no `fr` track, `auto` tracks
/// stretch to fill it). `avail` null sizes for max-content.
fn sizeTracks(l: *Layout, tracks_in: []const style.Track, count: u32, auto_track: style.Track, items: []const GridItem, rows: bool, avail: ?f64, gap: f64, contrib: *const fn (l: *Layout, it: GridItem) Error!Widths, stretch_auto: bool) Error![]f64 {
    const n: usize = count;
    const base = try l.a.alloc(f64, n);
    const limit = try l.a.alloc(f64, n);
    const tracks = try l.a.alloc(style.Track, n);
    for (0..n) |k| tracks[k] = if (k < tracks_in.len) tracks_in[k] else auto_track;
    for (tracks, 0..) |t, k| {
        base[k] = fixedTrackSize(t.min, avail) orelse 0;
        limit[k] = switch (t.max) {
            .px, .percent => fixedTrackSize(t.max, avail) orelse std.math.inf(f64),
            .fr => std.math.inf(f64),
            else => -1, // from the items
        };
    }
    const isFlex = struct {
        fn f(t: style.Track) bool {
            return t.max == .fr;
        }
    }.f;
    // Contributions, one-track items first.
    for ([_]bool{ false, true }) |spanning| for (items) |it| {
        const a0: usize = if (rows) it.row0 else it.col0;
        const a1: usize = if (rows) it.row1 else it.col1;
        if ((a1 - a0 > 1) != spanning) continue;
        var any_flex = false;
        for (a0..a1) |k| if (isFlex(tracks[k])) {
            any_flex = true;
        };
        const cw = try contrib(l, it);
        const gaps = gap * @as(f64, @floatFromInt(a1 - a0 - 1));
        if (!spanning) {
            const k = a0;
            const t = tracks[k];
            switch (t.min) {
                .auto, .min_content => base[k] = @max(base[k], cw.min),
                .max_content => base[k] = @max(base[k], cw.max),
                else => {},
            }
            // A flexible track's automatic minimum is the content's.
            switch (t.max) {
                .auto, .max_content => limit[k] = @max(limit[k], cw.max),
                .min_content => limit[k] = @max(limit[k], cw.min),
                else => {},
            }
            continue;
        }
        // Spanning: the excess over what the tracks have, spread over
        // the intrinsic ones among them (the flexible ones when any).
        var have: f64 = gaps;
        var have_lim: f64 = gaps;
        var intrinsic: usize = 0;
        for (a0..a1) |k| {
            have += base[k];
            have_lim += if (limit[k] < 0) base[k] else if (std.math.isInf(limit[k])) base[k] else limit[k];
            const t = tracks[k];
            if ((any_flex and isFlex(t)) or (!any_flex and (t.min == .auto or t.min == .min_content or t.min == .max_content))) intrinsic += 1;
        }
        if (intrinsic == 0) continue;
        const nf: f64 = @floatFromInt(intrinsic);
        for (a0..a1) |k| {
            const t = tracks[k];
            if (!((any_flex and isFlex(t)) or (!any_flex and (t.min == .auto or t.min == .min_content or t.min == .max_content)))) continue;
            if (cw.min > have) base[k] += (cw.min - have) / nf;
            if (!any_flex and cw.max > have_lim and limit[k] >= 0 and !std.math.isInf(limit[k])) limit[k] += (cw.max - have_lim) / nf;
            if (!any_flex and limit[k] < 0) limit[k] = @max(0, base[k]);
        }
    };
    for (0..n) |k| {
        if (limit[k] < 0) limit[k] = base[k];
        if (!std.math.isInf(limit[k])) limit[k] = @max(limit[k], base[k]);
    }
    const gaps_total = gap * @as(f64, @floatFromInt(if (n > 0) n - 1 else 0));
    var sum: f64 = gaps_total;
    for (base) |b| sum += b;
    const room: ?f64 = if (avail) |a| a - sum else null;
    // Grow toward the limits.
    if (room == null) {
        for (0..n) |k| if (!isFlex(tracks[k]) and !std.math.isInf(limit[k])) {
            base[k] = limit[k];
        };
    } else if (room.? > 0) {
        var free = room.?;
        var rounds: usize = 0;
        while (free > 0.01 and rounds < 8) : (rounds += 1) {
            var growable: usize = 0;
            for (0..n) |k| if (!isFlex(tracks[k]) and base[k] < limit[k]) {
                growable += 1;
            };
            if (growable == 0) break;
            const share = free / @as(f64, @floatFromInt(growable));
            for (0..n) |k| if (!isFlex(tracks[k]) and base[k] < limit[k]) {
                const g = @min(share, limit[k] - base[k]);
                base[k] += g;
                free -= g;
            };
        }
    }
    // Flexible tracks share what is left.
    var flex_sum: f64 = 0;
    for (tracks) |t| if (isFlex(t)) {
        flex_sum += t.max.fr;
    };
    if (flex_sum > 0) {
        var inflexible = try l.a.alloc(bool, n);
        @memset(inflexible, false);
        if (avail) |a| {
            var rounds: usize = 0;
            while (rounds < 8) : (rounds += 1) {
                var left: f64 = a - gaps_total;
                var fs: f64 = 0;
                for (0..n) |k| {
                    if (isFlex(tracks[k]) and !inflexible[k]) fs += tracks[k].max.fr else left -= base[k];
                }
                if (fs <= 0) break;
                const unit = @max(0, left) / @max(1, fs);
                var changed = false;
                for (0..n) |k| if (isFlex(tracks[k]) and !inflexible[k] and base[k] > unit * tracks[k].max.fr) {
                    inflexible[k] = true;
                    changed = true;
                };
                if (!changed) {
                    for (0..n) |k| if (isFlex(tracks[k]) and !inflexible[k]) {
                        base[k] = unit * tracks[k].max.fr;
                    };
                    break;
                }
            }
        } else {
            // Max-content: the fr unit that gives every flexible track
            // its content.
            var unit: f64 = 0;
            for (0..n) |k| if (isFlex(tracks[k]) and tracks[k].max.fr > 0) {
                unit = @max(unit, base[k] / tracks[k].max.fr);
            };
            for (0..n) |k| if (isFlex(tracks[k])) {
                base[k] = @max(base[k], unit * tracks[k].max.fr);
            };
        }
    } else if (stretch_auto) if (avail) |a| {
        // No flexible track: `auto` ones stretch into the rest.
        var total: f64 = gaps_total;
        for (base) |b| total += b;
        var autos: usize = 0;
        for (tracks) |t| if (t.max == .auto) {
            autos += 1;
        };
        if (autos > 0 and a > total) for (0..n) |k| if (tracks[k].max == .auto) {
            base[k] += (a - total) / @as(f64, @floatFromInt(autos));
        };
    };
    return base;
}

fn colContrib(l: *Layout, it: GridItem) Error!Widths {
    const cb = l.box(it.box);
    const pw = try preferredWidths(l, it.box);
    const m = (resolveLA(cb.style.margin[1], 0) orelse 0) + (resolveLA(cb.style.margin[3], 0) orelse 0);
    return .{ .min = pw.min + m, .max = pw.max + m };
}

fn rowContrib(l: *Layout, it: GridItem) Error!Widths {
    // Laid out at its column width already: its margin box height.
    const cb = l.get(it.box);
    const h = cb.h + cb.margin[0] + cb.margin[2];
    return .{ .min = h, .max = h };
}

fn gridWidths(l: *Layout, id: BoxId) Error!Widths {
    const st = l.get(id).style;
    const gap = resolveLP(st.column_gap, 0);
    const cols = try expandAxis(l, st.grid_template_columns, null, gap);
    const rows = try expandAxis(l, st.grid_template_rows, null, resolveLP(st.row_gap, 0));
    const placed = try placeGridItems(l, id, &cols, &rows);
    const max = try sizeTracks(l, cols.tracks, placed.ncols, st.grid_auto_columns, placed.items, false, null, gap, colContrib, false);
    const min = try sizeTracks(l, cols.tracks, placed.ncols, st.grid_auto_columns, placed.items, false, 0, gap, colContrib, false);
    const gaps = gap * @as(f64, @floatFromInt(if (placed.ncols > 0) placed.ncols - 1 else 0));
    var out: Widths = .{ .min = gaps, .max = gaps };
    for (min) |x| out.min += x;
    for (max) |x| out.max += x;
    out.max = @max(out.max, out.min);
    return out;
}

/// Lay a grid container's items out in its content box; returns the
/// content height.
fn layoutGridContents(l: *Layout, id: BoxId, cb_w: f64) Error!f64 {
    _ = cb_w;
    const g = l.get(id);
    const st = g.style;
    const content_x = g.contentX();
    const content_y = g.contentY();
    const content_w = g.contentW();
    const col_gap = resolveLP(st.column_gap, content_w);
    const row_gap = resolveLP(st.row_gap, content_w);
    const parent_h: ?f64 = if (g.parent) |p| (if (l.get(p).style.height == .auto and l.get(p).kind != .root) null else l.get(p).contentH()) else null;
    var definite_h: ?f64 = null;
    if (st.height == .px) definite_h = st.height.px - (if (st.box_sizing == .border_box) verticalExtras(g) else 0);
    if ((st.height == .percent or st.height == .calc) and parent_h != null) definite_h = resolveLA(st.height, parent_h.?).? - (if (st.box_sizing == .border_box) verticalExtras(g) else 0);
    const cols = try expandAxis(l, st.grid_template_columns, content_w, col_gap);
    const rows = try expandAxis(l, st.grid_template_rows, definite_h, row_gap);
    const placed = try placeGridItems(l, id, &cols, &rows);
    const widths = try sizeTracks(l, cols.tracks, placed.ncols, st.grid_auto_columns, placed.items, false, content_w, col_gap, colContrib, true);
    // `auto-fit`: empty repeated tracks collapse.
    if (st.grid_template_columns.auto_repeat) |ar| if (ar.fit) {
        for (cols.repeat_at..cols.repeat_at + cols.repeat_added) |k| {
            if (k >= widths.len) break;
            var used = false;
            for (placed.items) |it| if (it.col0 <= k and k < it.col1) {
                used = true;
            };
            if (!used) widths[k] = 0;
        }
    };
    const col_x = try l.a.alloc(f64, placed.ncols + 1);
    // `justify-content` over the tracks when they leave room.
    var used_w: f64 = col_gap * @as(f64, @floatFromInt(if (placed.ncols > 0) placed.ncols - 1 else 0));
    for (widths) |w| used_w += w;
    const spare_w = @max(0, content_w - used_w);
    var x0 = content_x;
    var between: f64 = 0;
    switch (st.justify_content) {
        .center => x0 += spare_w / 2,
        .flex_end, .end => x0 += spare_w,
        .space_between => if (placed.ncols > 1) {
            between = spare_w / @as(f64, @floatFromInt(placed.ncols - 1));
        },
        .space_around => if (placed.ncols > 0) {
            between = spare_w / @as(f64, @floatFromInt(placed.ncols));
            x0 += between / 2;
        },
        .space_evenly => if (placed.ncols > 0) {
            between = spare_w / @as(f64, @floatFromInt(placed.ncols + 1));
            x0 += between;
        },
        else => {},
    }
    col_x[0] = x0;
    for (0..placed.ncols) |k| col_x[k + 1] = col_x[k] + widths[k] + col_gap + between;
    // Each item laid out at its area's width (or its own, aligned).
    for (placed.items) |it| {
        const cb = l.box(it.box);
        const margins = resolveEdges(cb, content_w);
        cb.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
        const area_w = col_x[it.col1] - col_gap - between - col_x[it.col0];
        const extras = horizontalExtras(cb);
        const justify: style.AlignSelf = if (cb.style.justify_self != .auto) cb.style.justify_self else switch (st.justify_items) {
            .stretch, .normal => .stretch,
            .center => .center,
            .end, .flex_end, .self_end, .right => .end,
            else => .start,
        };
        const auto_margins = margins[1] == null or margins[3] == null;
        var w: f64 = undefined;
        if (resolveLA(cb.style.width, area_w)) |sw| {
            w = constrainWidth(cb, if (cb.style.box_sizing == .border_box) sw - extras else sw, area_w);
        } else if (isReplacedBox(l, cb)) {
            w = replacedSize(l, it.box, area_w)[0];
        } else if ((justify == .stretch or justify == .normal) and !auto_margins) {
            w = constrainWidth(cb, @max(0, area_w - cb.margin[1] - cb.margin[3] - extras), area_w);
        } else {
            // Shrink-to-fit in the area (preferred widths are border-box).
            const pw = try preferredWidths(l, it.box);
            const room = area_w - cb.margin[1] - cb.margin[3] - extras;
            w = constrainWidth(cb, @min(@max(pw.min - extras, room), pw.max - extras), area_w);
        }
        const free_w = @max(0, area_w - cb.margin[1] - cb.margin[3] - extras - w);
        var dx: f64 = 0;
        if (auto_margins) {
            if (margins[1] == null and margins[3] == null) dx = free_w / 2 else if (margins[3] == null) dx = free_w;
        } else switch (justify) {
            .center => dx = free_w / 2,
            .end, .flex_end, .self_end, .right => dx = free_w,
            else => {},
        }
        try layoutFlexItem(l, it.box, col_x[it.col0] + dx, 0, w, null);
    }
    const heights = try sizeTracks(l, rows.tracks, placed.nrows, st.grid_auto_rows, placed.items, true, definite_h, row_gap, rowContrib, definite_h != null);
    const row_y = try l.a.alloc(f64, placed.nrows + 1);
    row_y[0] = content_y;
    for (0..placed.nrows) |k| row_y[k + 1] = row_y[k] + heights[k] + row_gap;
    // Items into their rows, stretched or aligned.
    for (placed.items) |it| {
        const cb = l.box(it.box);
        const area_h = row_y[it.row1] - row_gap - row_y[it.row0];
        const alignment: style.AlignSelf = if (cb.style.align_self != .auto) cb.style.align_self else switch (st.align_items) {
            .stretch, .normal => .stretch,
            .center => .center,
            .end, .flex_end, .self_end => .end,
            else => .start,
        };
        const outer_h = cb.h + cb.margin[0] + cb.margin[2];
        var dy: f64 = 0;
        if ((alignment == .stretch or alignment == .normal) and cb.style.height == .auto and !isReplacedBox(l, cb)) {
            cb.h = @max(cb.h, area_h - cb.margin[0] - cb.margin[2]);
        } else switch (alignment) {
            .center => dy = (area_h - outer_h) / 2,
            .end, .flex_end, .self_end => dy = area_h - outer_h,
            else => {},
        }
        try moveBox(l, it.box, 0, row_y[it.row0] + cb.margin[0] + dy - cb.y);
    }
    const total = if (placed.nrows > 0) row_y[placed.nrows] - row_gap - content_y else 0;
    return @max(0, total);
}

// ------------------------------------------------------------ tables

fn isTableBox(b: *const Box) bool {
    return (b.kind == .block or b.kind == .inline_block) and (b.style.display == .table or b.style.display == .inline_table);
}

fn isRowGroupDisplay(d: style.Display) bool {
    return d == .table_row_group or d == .table_header_group or d == .table_footer_group;
}

fn isTablePart(d: style.Display) bool {
    return isRowGroupDisplay(d) or d == .table_row or d == .table_cell or d == .table_caption;
}

/// CSS 2.1 §17.2.1, the common cases: inside a table, a row group or a
/// row, whitespace between the parts is nothing; a run of cells outside
/// a row gets an anonymous row; a run of table parts outside a table
/// gets an anonymous table (so `display: table-cell` columns lay out
/// side by side).
fn fixTableParts(l: *Layout, id: BoxId) Error!void {
    const d = l.get(id).style.display;
    const in_table = d == .table or d == .inline_table;
    const in_group = isRowGroupDisplay(d);
    const in_row = d == .table_row;
    const old = try l.a.dupe(BoxId, l.get(id).children.items);
    var any_part = false;
    for (old) |c| {
        const cb = l.get(c);
        if (cb.kind != .text and isTablePart(cb.style.display)) any_part = true;
    }
    if (!any_part and !in_table and !in_group and !in_row) return;
    var out: std.ArrayList(BoxId) = .empty;
    var run: ?BoxId = null; // the anonymous wrapper being filled
    for (old) |c| {
        const cb = l.get(c);
        const cd = cb.style.display;
        const is_part = cb.kind != .text and !cb.isOutOfFlow() and isTablePart(cd);
        if ((in_table or in_group or in_row) and cb.kind == .text and isBlank(cb.text)) continue;
        var wrap_as: ?style.Display = null;
        if (in_row) {
            // Everything in a row is a cell.
            if (!(is_part and cd == .table_cell)) wrap_as = .table_cell;
        } else if (in_table or in_group) {
            if (is_part and cd == .table_cell) wrap_as = .table_row;
            if (!is_part) wrap_as = .table_row;
        } else if (is_part) {
            wrap_as = .table;
        }
        if (wrap_as) |wd| {
            if (run) |r| if (l.get(r).style.display == wd) {
                try l.box(r).children.append(l.a, c);
                l.box(c).parent = r;
                continue;
            };
            const st = try l.a.create(style.Computed);
            st.* = style.anonymous(l.get(id).style);
            st.display = wd;
            if (wd == .table) {
                st.border_spacing_x = 0;
                st.border_spacing_y = 0;
            }
            try l.boxes.append(l.a, .{ .kind = .block, .node = null, .style = st, .parent = id });
            const nid: BoxId = @intCast(l.boxes.len - 1);
            try l.box(nid).children.append(l.a, c);
            l.box(c).parent = nid;
            try out.append(l.a, nid);
            run = nid;
        } else {
            run = null;
            try out.append(l.a, c);
        }
    }
    l.box(id).children = out;
    // A new wrapper's own contents need the same fix-up (a cell wrapped
    // into a row wrapped into a table), and a cell made of text is a
    // block of inline content.
    for (out.items) |c| if (l.get(c).node == null and l.get(c).kind == .block) {
        try fixTableParts(l, c);
        try wrapInlines(l, c);
    };
}

const TableCell = struct { box: BoxId, row: u32, col: u32, rows: u32, cols: u32 };

const TableGrid = struct {
    rows: []BoxId,
    cells: []TableCell,
    ncols: u32,
    captions: []BoxId,
    spacing_x: f64,
    spacing_y: f64,
};

fn spanAttr(l: *const Layout, node: ?NodeId, name: []const u8) u32 {
    const n = node orelse return 1;
    const v = attrNumber(l.doc, n, name) orelse return 1;
    return @intFromFloat(std.math.clamp(@floor(v), 0, 1000));
}

/// The table's rows in visual order (header groups, then bodies and
/// bare rows, then footers) and its cells placed in slots by their
/// spans.
fn tableGrid(l: *Layout, id: BoxId) Error!TableGrid {
    const b = l.get(id);
    var heads: std.ArrayList(BoxId) = .empty;
    var bodies: std.ArrayList(BoxId) = .empty;
    var feet: std.ArrayList(BoxId) = .empty;
    var captions: std.ArrayList(BoxId) = .empty;
    for (b.children.items) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow()) continue;
        switch (cb.style.display) {
            .table_caption => try captions.append(l.a, c),
            .table_header_group, .table_footer_group, .table_row_group => {
                const list = if (cb.style.display == .table_header_group) &heads else if (cb.style.display == .table_footer_group) &feet else &bodies;
                for (cb.children.items) |r| if (l.get(r).style.display == .table_row) try list.append(l.a, r);
            },
            .table_row => try bodies.append(l.a, c),
            else => {},
        }
    }
    var rows: std.ArrayList(BoxId) = .empty;
    try rows.appendSlice(l.a, heads.items);
    try rows.appendSlice(l.a, bodies.items);
    try rows.appendSlice(l.a, feet.items);
    // Slots taken by row spans from rows above, per column.
    var busy: std.ArrayList(u32) = .empty; // rows still covered, by column
    var cells: std.ArrayList(TableCell) = .empty;
    var ncols: u32 = 0;
    const nrows: u32 = @intCast(rows.items.len);
    for (rows.items, 0..) |r, ri| {
        var col: u32 = 0;
        for (l.get(r).children.items) |c| {
            const cb = l.get(c);
            if (cb.isOutOfFlow() or cb.style.display != .table_cell) continue;
            while (col < busy.items.len and busy.items[col] > 0) col += 1;
            const cs = @max(1, spanAttr(l, cb.node, "colspan"));
            var rs = spanAttr(l, cb.node, "rowspan");
            if (rs == 0) rs = nrows - @as(u32, @intCast(ri));
            rs = @max(1, @min(rs, nrows - @as(u32, @intCast(ri))));
            try cells.append(l.a, .{ .box = c, .row = @intCast(ri), .col = col, .rows = rs, .cols = cs });
            while (busy.items.len < col + cs) try busy.append(l.a, 0);
            for (col..col + cs) |k| busy.items[k] = @max(busy.items[k], rs);
            col += cs;
            ncols = @max(ncols, col);
        }
        // A row ends: every span covers one row fewer.
        for (busy.items) |*v| v.* -|= 1;
    }
    const collapse = b.style.border_collapse == .collapse;
    return .{
        .rows = rows.items,
        .cells = cells.items,
        .ncols = ncols,
        .captions = captions.items,
        .spacing_x = if (collapse) 0 else b.style.border_spacing_x,
        .spacing_y = if (collapse) 0 else b.style.border_spacing_y,
    };
}

/// Per column: the minimum and maximum widths, and the percentage of
/// the table its cells ask for (0: none).
const ColumnWidths = struct { min: []f64, max: []f64, pct: []f64 };

/// Each column's minimum and maximum width from its cells' (a cell's
/// fixed width raises both), a spanning cell's excess spread over the
/// columns it spans.
fn columnWidths(l: *Layout, g: TableGrid) Error!ColumnWidths {
    const min = try l.a.alloc(f64, g.ncols);
    const max = try l.a.alloc(f64, g.ncols);
    const pct = try l.a.alloc(f64, g.ncols);
    @memset(min, 0);
    @memset(max, 0);
    @memset(pct, 0);
    for ([_]bool{ false, true }) |spanning| for (g.cells) |c| {
        if ((c.cols > 1) != spanning) continue;
        const cb = l.box(c.box);
        const pw = try preferredWidths(l, c.box);
        var cmin = pw.min;
        var cmax = @max(pw.max, pw.min);
        if (cb.style.width == .px) {
            const w = if (cb.style.box_sizing == .border_box) cb.style.width.px else cb.style.width.px + horizontalExtras(cb);
            cmin = @max(cmin, @min(w, cmax));
            cmax = @max(cmin, w);
        }
        if (cb.style.width == .percent and c.cols == 1) pct[c.col] = @max(pct[c.col], cb.style.width.percent);
        const span_space = g.spacing_x * @as(f64, @floatFromInt(c.cols - 1));
        var have_min: f64 = span_space;
        var have_max: f64 = span_space;
        for (c.col..c.col + c.cols) |k| {
            have_min += min[k];
            have_max += max[k];
        }
        const n: f64 = @floatFromInt(c.cols);
        if (cmin > have_min) for (c.col..c.col + c.cols) |k| {
            min[k] += (cmin - have_min) / n;
        };
        if (cmax > have_max) for (c.col..c.col + c.cols) |k| {
            max[k] += (cmax - have_max) / n;
        };
        for (c.col..c.col + c.cols) |k| max[k] = @max(max[k], min[k]);
    };
    return .{ .min = min, .max = max, .pct = pct };
}

/// What a table's columns are made of, for the host's `webshot`
/// (`WEBSHOT_TABLE=box`): every cell's min and max, then the columns'.
pub fn debugTableColumns(l: *Layout, id: BoxId) Error!void {
    const g = try tableGrid(l, id);
    for (g.cells) |c| {
        const pw = try preferredWidths(l, c.box);
        std.debug.print("  cell box {d} col {d} span {d}: min {d:.1} max {d:.1}\n", .{ c.box, c.col, c.cols, pw.min, pw.max });
    }
    const cw = try columnWidths(l, g);
    for (cw.min, cw.max, 0..) |a, b, k| std.debug.print("  column {d}: min {d:.1} max {d:.1}\n", .{ k, a, b });
}

/// Column widths for `avail`: percentage columns take their share (at
/// least their minimum) first; the rest share what is left between their
/// minimum and maximum, or past the maximum by it.
fn distributeColumns(cw: ColumnWidths, avail: f64, out: []f64) void {
    const n = out.len;
    var sum_pct: f64 = 0;
    for (cw.pct) |x| sum_pct += x;
    const pct_scale: f64 = if (sum_pct > 100) 100 / sum_pct else 1;
    var used: f64 = 0;
    var sum_min: f64 = 0;
    var sum_max: f64 = 0;
    var free_cols: usize = 0;
    for (0..n) |k| {
        if (cw.pct[k] > 0) {
            out[k] = @max(cw.min[k], avail * cw.pct[k] * pct_scale / 100);
            used += out[k];
        } else {
            sum_min += cw.min[k];
            sum_max += cw.max[k];
            free_cols += 1;
        }
    }
    const left = @max(0, avail - used);
    if (free_cols == 0) {
        // Only percentage columns: what is left goes to them by share.
        if (used > 0 and left > 0) for (0..n) |k| {
            out[k] += left * out[k] / used;
        };
        return;
    }
    for (0..n) |k| {
        if (cw.pct[k] > 0) continue;
        if (sum_max <= left) {
            const extra = left - sum_max;
            out[k] = cw.max[k] + if (sum_max > 0) extra * cw.max[k] / sum_max else extra / @as(f64, @floatFromInt(free_cols));
        } else if (sum_min >= left) {
            out[k] = cw.min[k];
        } else {
            out[k] = cw.min[k] + (cw.max[k] - cw.min[k]) * (left - sum_min) / (sum_max - sum_min);
        }
    }
}

/// A table's minimum and maximum border-box widths (its columns, the
/// spacing and its own edges; a caption can widen it).
fn tableWidths(l: *Layout, id: BoxId) Error!Widths {
    const g = try tableGrid(l, id);
    const cw = try columnWidths(l, g);
    const spacing = g.spacing_x * @as(f64, @floatFromInt(g.ncols + 1));
    var min: f64 = spacing;
    var max: f64 = spacing;
    for (cw.min, cw.max) |a, x| {
        min += a;
        max += x;
    }
    // Percentage columns widen the table until each gets its share and
    // the others their maximum in what is left.
    var sum_pct: f64 = 0;
    var other_max: f64 = 0;
    var need: f64 = max - spacing;
    for (cw.pct, cw.max) |pc, x| {
        if (pc > 0) {
            sum_pct += pc;
            need = @max(need, x * 100 / pc);
        } else other_max += x;
    }
    if (sum_pct > 0 and sum_pct < 100) need = @max(need, other_max * 100 / (100 - sum_pct));
    max = @max(max, need + spacing);
    for (g.captions) |c| {
        const pw = try preferredWidths(l, c);
        min = @max(min, pw.min);
    }
    const extras = horizontalExtras(l.get(id));
    return .{ .min = min + extras, .max = @max(min, max) + extras };
}

/// Lay a table's parts out inside its content box (its width already
/// set): captions on top, columns sized from the cells, each row as
/// tall as its tallest cell, cells aligned in their rows by
/// `vertical-align`. Returns the content height.
fn layoutTableContents(l: *Layout, id: BoxId, cb_w: f64) Error!f64 {
    _ = cb_w;
    const g = try tableGrid(l, id);
    const cw = try columnWidths(l, g);
    // Columns are never narrower than their minimums: a table specified
    // narrower than they need widens to them (and overflows its
    // container, as browsers let it) rather than drawing a border its
    // cells spill past.
    {
        var need: f64 = g.spacing_x * @as(f64, @floatFromInt(g.ncols + 1));
        for (cw.min) |m| need += m;
        const tb = l.box(id);
        if (need > tb.contentW()) tb.w += need - tb.contentW();
    }
    const t = l.get(id);
    const content_x = t.contentX();
    const content_w = t.contentW();
    var y = t.contentY();
    for (g.captions) |c| {
        var bfc: Bfc = .{ .root = c };
        if (l.get(c).laid_out) try purgeSubtree(l, c);
        try layoutBlockAt(l, c, &bfc, content_x, y, content_w);
        const cb = l.get(c);
        y = cb.y + cb.h + cb.margin[2];
    }
    // Column widths into the space the table has.
    const n = g.ncols;
    const widths = try l.a.alloc(f64, n);
    const avail = @max(0, content_w - g.spacing_x * @as(f64, @floatFromInt(n + 1)));
    var sum_min: f64 = 0;
    var sum_max: f64 = 0;
    for (cw.min, cw.max) |a, x| {
        sum_min += a;
        sum_max += x;
    }
    distributeColumns(cw, avail, widths);
    const col_x = try l.a.alloc(f64, n + 1);
    col_x[0] = content_x + g.spacing_x;
    for (0..n) |k| col_x[k + 1] = col_x[k] + widths[k] + g.spacing_x;
    // Every cell laid out at its width (at the top for now), then the
    // rows sized from the cells that end in them.
    const nrows = g.rows.len;
    const row_h = try l.a.alloc(f64, nrows);
    @memset(row_h, 0);
    for (g.rows, 0..) |r, ri| if (l.get(r).style.height == .px) {
        row_h[ri] = l.get(r).style.height.px;
    };
    for (g.cells) |c| {
        if (l.get(c.box).laid_out) try purgeSubtree(l, c.box);
        const cb = l.box(c.box);
        _ = resolveEdges(cb, content_w);
        cb.margin = .{ 0, 0, 0, 0 };
        cb.x = col_x[c.col];
        cb.y = 0;
        cb.w = col_x[c.col + c.cols] - g.spacing_x - col_x[c.col];
        var inner: Bfc = .{ .root = c.box };
        try layoutBlockContents(l, c.box, &inner, cb.w);
        if (c.rows == 1) row_h[c.row] = @max(row_h[c.row], l.get(c.box).h);
    }
    for (g.cells) |c| if (c.rows > 1) {
        var have = g.spacing_y * @as(f64, @floatFromInt(c.rows - 1));
        for (c.row..c.row + c.rows) |k| have += row_h[k];
        const need = l.get(c.box).h;
        if (need > have) row_h[c.row + c.rows - 1] += need - have;
    };
    // Row tops; then each cell moved into place, as tall as its rows,
    // its content aligned in it.
    const row_y = try l.a.alloc(f64, nrows + 1);
    row_y[0] = y + g.spacing_y;
    for (0..nrows) |k| row_y[k + 1] = row_y[k] + row_h[k] + g.spacing_y;
    for (g.cells) |c| {
        const cb = l.box(c.box);
        const top = row_y[c.row];
        const span_h = row_y[c.row + c.rows] - g.spacing_y - top;
        const natural = cb.h;
        const free = @max(0, span_h - natural);
        const offset: f64 = switch (cb.style.vertical_align) {
            .middle => free / 2,
            .bottom => free,
            else => 0,
        };
        try moveBox(l, c.box, 0, top + offset);
        const moved = l.box(c.box);
        moved.y = top;
        moved.h = span_h;
    }
    // The rows and their groups cover what their cells do (for their
    // backgrounds and hit tests).
    for (g.rows, 0..) |r, ri| {
        const rb = l.box(r);
        rb.x = content_x;
        rb.w = content_w;
        rb.y = row_y[ri];
        rb.h = row_h[ri];
        rb.laid_out = true;
    }
    for (t.children.items) |c| {
        const gb = l.box(c);
        if (!isRowGroupDisplay(gb.style.display)) continue;
        var lo: ?f64 = null;
        var hi: f64 = 0;
        for (gb.children.items) |r| {
            const rb = l.get(r);
            if (!rb.laid_out) continue;
            lo = if (lo) |v| @min(v, rb.y) else rb.y;
            hi = @max(hi, rb.y + rb.h);
        }
        gb.x = content_x;
        gb.w = content_w;
        gb.y = lo orelse y;
        gb.h = if (lo) |v| hi - v else 0;
        gb.laid_out = true;
    }
    return row_y[nrows] - t.contentY();
}

// ---------------------------------------------------- intrinsic widths

const Widths = struct { min: f64, max: f64 };

/// The min-content and max-content widths of a box's border box.
fn preferredWidths(l: *Layout, id: BoxId) Error!Widths {
    return preferredWidthsOf(l, id, false);
}

/// The widths of the contents alone, a specified `width` ignored: a
/// flex item's automatic minimum is the smaller of this and its size.
fn contentWidths(l: *Layout, id: BoxId) Error!Widths {
    return preferredWidthsOf(l, id, true);
}

/// Nonzero while intrinsic widths are being measured (the engine is
/// single-threaded; a counter, since measurements nest).
var measuring: u32 = 0;

fn preferredWidthsOf(l: *Layout, id: BoxId, contents_only: bool) Error!Widths {
    // A box's preferred widths are its subtree's alone: measured once
    // per layout (nested flex containers measure their items again at
    // every level — GitHub's menus cost megabytes before this).
    const cache = if (contents_only) &l.content_widths else &l.preferred_widths;
    while (cache.len < l.boxes.len) try cache.append(l.a, null);
    if (cache.get(id).*) |w| return w;
    const w = try measureWidths(l, id, contents_only);
    // (The list may have grown while measuring; an entry never moves.)
    if (id < cache.len) cache.at(id).* = w;
    return w;
}

fn measureWidths(l: *Layout, id: BoxId, contents_only: bool) Error!Widths {
    measuring += 1;
    defer measuring -= 1;
    const b = l.box(id);
    const st = b.style;
    for (0..4) |i| {
        b.padding[i] = resolveLP(st.padding[i], 0);
        b.border[i] = st.borderWidth(i);
    }
    const extras = horizontalExtras(b);
    if (isReplacedBox(l, b)) {
        const size = replacedSize(l, id, 0);
        // A replaced box limited by a percentage (`img { max-width: 100% }`,
        // the web's way of letting a picture shrink to its column) has no
        // minimum of its own: a 330px picture fits a 22em infobox, and
        // the table's columns are not forced past its width (2026-09-24).
        const shrinks = st.max_width == .percent or st.max_width == .calc or st.width == .percent;
        return .{ .min = if (shrinks) extras else size[0] + extras, .max = size[0] + extras };
    }
    if (isTableBox(b)) {
        const tw = try tableWidths(l, id);
        if (st.width == .px and !contents_only) {
            const w = @max(tw.min, if (st.box_sizing == .border_box) st.width.px else st.width.px + extras);
            return .{ .min = w, .max = w };
        }
        return tw;
    }
    if (st.width == .px and !contents_only) {
        const w = if (st.box_sizing == .border_box) st.width.px else st.width.px + extras;
        return .{ .min = w, .max = w };
    }
    var min: f64 = 0;
    var max: f64 = 0;
    if (isGridContainer(b)) {
        const gw = try gridWidths(l, id);
        min = gw.min;
        max = gw.max;
    } else if (isFlexContainer(b)) {
        // A row's max-content is its items' side by side (plus gaps),
        // its min-content the widest item's unless it cannot wrap; a
        // column's are the widest item's.
        const row = st.flex_direction == .row or st.flex_direction == .row_reverse;
        var n: usize = 0;
        for (b.children.items) |c| {
            const cb = l.get(c);
            if (cb.isPositioned()) continue;
            const cw = try preferredWidths(l, c);
            const cm = (resolveLA(cb.style.margin[1], 0) orelse 0) + (resolveLA(cb.style.margin[3], 0) orelse 0);
            if (row) {
                max += cw.max + cm;
                if (st.flex_wrap == .nowrap) min += cw.min + cm else min = @max(min, cw.min + cm);
            } else {
                max = @max(max, cw.max + cm);
                min = @max(min, cw.min + cm);
            }
            n += 1;
        }
        if (row and n > 1) {
            const gap = resolveLP(st.column_gap, 0) * @as(f64, @floatFromInt(n - 1));
            max += gap;
            if (st.flex_wrap == .nowrap) min += gap;
        }
    } else if (hasInlineContent(l, id)) {
        const mark = l.scratch_fba.end_index;
        defer l.scratch_fba.end_index = mark;
        const items = try collectItemsFor(l, id, l.fonts, true);
        var line: f64 = 0;
        var word: f64 = 0;
        for (items) |it| {
            switch (it.kind) {
                .text, .atomic, .inline_open, .inline_close, .marker => {
                    line += it.w;
                    word += it.min_w orelse it.w;
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
    /// Measuring: an atomic's min-content width (`w` is its max).
    min_w: ?f64 = null,
};

/// Whether a break may occur between two ideographs (each is a word).
fn isCjk(cp: u21) bool {
    return (cp >= 0x2e80 and cp <= 0x9fff) or (cp >= 0xac00 and cp <= 0xd7af) or (cp >= 0xf900 and cp <= 0xfaff) or (cp >= 0xff00 and cp <= 0xffef) or (cp >= 0x3000 and cp <= 0x30ff) or (cp >= 0x20000 and cp <= 0x2ffff);
}

/// The inline items of a block container: text cut at its break
/// opportunities with white-space applied, inline boxes opened and
/// closed, atomic inlines sized.
fn collectItems(l: *Layout, id: BoxId, fonts: Fonts) Error![]const Item {
    return collectItemsFor(l, id, fonts, false);
}

/// `measure`: for intrinsic widths only — an atomic inline is not laid
/// out, its preferred widths stand for it (laying it out for every
/// measurement of every ancestor cost deep flex pages megabytes).
fn collectItemsFor(l: *Layout, id: BoxId, fonts: Fonts, measure: bool) Error![]const Item {
    var items: std.ArrayList(Item) = .empty;
    const b = l.get(id);
    if (b.marker_text.len > 0 and b.style.list_style_position == .inside) {
        const font = fontOf(b.style);
        const m = fonts.metrics(font);
        try items.append(sa(l), .{ .kind = .marker, .box = id, .text = b.marker_text, .w = fonts.advance(font, b.marker_text), .h = m.ascent + m.descent, .baseline = m.ascent });
    }
    var prev_space = true; // a line starts as if after a space
    try collectInto(l, id, fonts, &items, &prev_space, measure);
    return items.items;
}

fn collectInto(l: *Layout, id: BoxId, fonts: Fonts, items: *std.ArrayList(Item), prev_space: *bool, measure: bool) Error!void {
    const children = l.get(id).children.items;
    for (children) |c| {
        const cb = l.box(c);
        if (cb.isPositioned()) {
            try addAbsolute(l, c);
            continue;
        }
        if (cb.isFloat()) {
            // Placed when the line is built: an atomic item of no width
            // stands in so the position is known.
            try items.append(sa(l), .{ .kind = .atomic, .box = c, .w = 0, .h = 0 });
            continue;
        }
        switch (cb.kind) {
            .text => try textItems(l, c, fonts, items, prev_space),
            .br => {
                try items.append(sa(l), .{ .kind = .br, .box = c });
                prev_space.* = true;
            },
            .inline_box => {
                const cb_w = containerWidth(l, c);
                _ = resolveEdges(cb, cb_w);
                cb.margin = .{ 0, resolveLA(cb.style.margin[1], cb_w) orelse 0, 0, resolveLA(cb.style.margin[3], cb_w) orelse 0 };
                try items.append(sa(l), .{ .kind = .inline_open, .box = c, .w = cb.margin[3] + cb.border[3] + cb.padding[3] });
                try collectInto(l, c, fonts, items, prev_space, measure);
                try items.append(sa(l), .{ .kind = .inline_close, .box = c, .w = cb.margin[1] + cb.border[1] + cb.padding[1] });
            },
            .inline_block, .block, .anon_block => {
                if (measure) {
                    const pw = try preferredWidths(l, c);
                    const m = (resolveLA(cb.style.margin[1], 0) orelse 0) + (resolveLA(cb.style.margin[3], 0) orelse 0);
                    try items.append(sa(l), .{ .kind = .atomic, .box = c, .w = pw.max + m, .min_w = pw.min + m });
                    prev_space.* = false;
                    continue;
                }
                const size = try layoutAtomic(l, c);
                try items.append(sa(l), .{ .kind = .atomic, .box = c, .w = size.w, .h = size.h, .baseline = size.baseline });
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
            try items.append(sa(l), .{ .kind = .newline, .box = id });
            prev_space.* = true;
            i += 1;
            continue;
        }
        if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
            if (preserve) {
                // Every space is kept; a tab is eight of them.
                const s: []const u8 = if (c == '\t') "        " else " ";
                try items.append(sa(l), .{ .kind = .space, .box = id, .text = s, .w = fonts.advance(font, s), .h = m.ascent + m.descent, .baseline = m.ascent, .no_break = no_break });
                i += 1;
                continue;
            }
            var j = i;
            while (j < text.len and (text[j] == ' ' or text[j] == '\t' or text[j] == '\n' or text[j] == '\r' or text[j] == 0x0c)) j += 1;
            if (!prev_space.*) try items.append(sa(l), .{ .kind = .space, .box = id, .text = " ", .w = fonts.advance(font, " "), .h = m.ascent + m.descent, .baseline = m.ascent, .no_break = no_break });
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
        try items.append(sa(l), .{ .kind = .text, .box = id, .text = word, .w = fonts.advance(font, word), .h = m.ascent + m.descent, .baseline = m.ascent, .no_break = no_break });
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
    // Measured before (a container's preferred widths lay its atomics
    // out): what that left behind goes first.
    if (l.get(id).laid_out) try purgeSubtree(l, id);
    const b = l.box(id);
    const cb_w = containerWidth(l, id);
    const margins = resolveEdges(b, cb_w);
    b.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
    const extras = horizontalExtras(b);
    if (b.node != null and isReplaced(l, b.node.?)) {
        const size = replacedSize(l, id, cb_w);
        b.x = 0;
        b.y = 0;
        b.w = size[0] + extras;
        b.h = size[1] + verticalExtras(b);
        b.laid_out = true;
        // A replaced element sits on its bottom margin edge.
        return .{ .w = b.w + b.margin[1] + b.margin[3], .h = b.h + b.margin[0] + b.margin[2], .baseline = b.h + b.margin[0] };
    }
    // Measuring, a percentage width is `auto` (CSS Sizing's cyclic
    // percentages).
    const pct_width = b.style.width == .percent or b.style.width == .calc;
    const width = if (if (measuring > 0 and pct_width) null else resolveLA(b.style.width, cb_w)) |w| (if (b.style.box_sizing == .border_box) w - extras else w) else blk: {
        // Shrink-to-fit: the preferred widths are border-box ones.
        const pref = try preferredWidths(l, id);
        const avail = cb_w - b.margin[1] - b.margin[3] - extras;
        break :blk @min(@max(pref.min - extras, avail), pref.max - extras);
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

/// The first line box in a block's in-flow subtree.
fn firstLine(l: *const Layout, id: BoxId) ?Line {
    const b = l.get(id);
    if (b.lines.items.len > 0) return b.lines.items[0];
    for (b.children.items) |c| {
        const cb = l.get(c);
        if (cb.isOutOfFlow() or !cb.isBlockLevel()) continue;
        if (firstLine(l, c)) |ln| return ln;
    }
    return null;
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

/// A replaced element's content size. A picture: the `width` and
/// `height` it is given (HTML's attributes arrive as presentational
/// hints), one of them completing the other by the picture's ratio (or
/// the attributes' when it has not arrived), else its natural size —
/// then min/max width, the ratio kept. Without a picture or a size, an
/// image takes no room; video, canvas and frames are 300×150. A control
/// sizes by its type (a text field 12em wide, a button around its text).
fn replacedSize(l: *const Layout, id: BoxId, cb_w: f64) [2]f64 {
    const b = l.get(id);
    const node = b.node.?;
    const doc = l.doc;
    const st = b.style;
    const border_box = st.box_sizing == .border_box;
    var w: ?f64 = resolveLA(st.width, cb_w);
    if (w != null and border_box) w = @max(0, w.? - horizontalExtras(b));
    var h: ?f64 = if (st.height == .px) st.height.px else null;
    if (h != null and border_box) h = @max(0, h.? - verticalExtras(b));
    const em = st.font_size;
    const name = doc.get(node).name;
    if (std.mem.eql(u8, name, "img") or std.mem.eql(u8, name, "video") or std.mem.eql(u8, name, "canvas") or std.mem.eql(u8, name, "iframe") or std.mem.eql(u8, name, "svg") or std.mem.eql(u8, name, "embed") or std.mem.eql(u8, name, "object")) {
        var natural: ?[2]f64 = null;
        if (l.images) |imgs| if (imgs.get(node)) |bm| {
            // A picture's size is in CSS pixels (its pixels over its
            // density): zoomed like the rest.
            if (bm.w > 0 and bm.h > 0) natural = .{ @as(f64, @floatFromInt(bm.w)) / bm.density * style.px_scale, @as(f64, @floatFromInt(bm.h)) / bm.density * style.px_scale };
        };
        // An inline `<svg>` is sized by its `width` and `height`
        // attributes (CSS pixels) or its viewBox's ratio.
        if (natural == null and std.mem.eql(u8, name, "svg")) {
            const aw = attrNumber(doc, node, "width");
            const ah = attrNumber(doc, node, "height");
            var vr: ?f64 = null;
            if (doc.getAttr(node, "viewBox")) |vb| {
                var it = std.mem.tokenizeAny(u8, vb, " ,\t\r\n");
                _ = it.next();
                _ = it.next();
                const vw = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                const vh = std.fmt.parseFloat(f64, it.next() orelse "0") catch 0;
                if (vw > 0 and vh > 0) vr = vw / vh;
            }
            if (w == null and h == null and aw != null and ah != null) {
                w = aw.? * style.px_scale;
                h = ah.? * style.px_scale;
            } else if (w == null and h == null and aw != null) {
                w = aw.? * style.px_scale;
                if (vr) |r| h = w.? / r;
            } else if (w == null and h == null and ah != null) {
                h = ah.? * style.px_scale;
                if (vr) |r| w = h.? * r;
            }
            // A ratio and no size: the containing block's width (CSS
            // 2.1 §10.3.2's suggestion, and what browsers do).
            if (w == null and h == null and aw == null and ah == null) if (vr) |r| {
                w = cb_w;
                h = cb_w / r;
            };
            if (w != null and h == null) if (vr) |r| {
                h = w.? / r;
            };
            if (h != null and w == null) if (vr) |r| {
                w = h.? * r;
            };
        }
        // The ratio: the picture's, else the size attributes'.
        var ratio: ?f64 = if (natural) |nat| nat[0] / nat[1] else null;
        if (ratio == null) {
            const aw = attrNumber(doc, node, "width");
            const ah = attrNumber(doc, node, "height");
            if (aw != null and ah != null and ah.? > 0) ratio = aw.? / ah.?;
        }
        const is_img = std.mem.eql(u8, name, "img");
        const default: [2]f64 = if (natural) |nat| nat else if (is_img) .{ 0, 0 } else .{ 300 * style.px_scale, 150 * style.px_scale };
        var out: [2]f64 = undefined;
        if (w != null and h != null) {
            out = .{ w.?, h.? };
        } else if (w) |ww| {
            out = .{ ww, if (ratio) |r| ww / r else default[1] };
        } else if (h) |hh| {
            out = .{ if (ratio) |r| hh * r else default[0], hh };
        } else out = default;
        // min/max width, the height following when it was not given.
        const cw = constrainWidth(b, out[0], cb_w);
        if (cw != out[0]) {
            if (h == null) if (ratio) |r| {
                out[1] = cw / r;
            };
            out[0] = cw;
        }
        switch (st.max_height) {
            .px => |mh| if (out[1] > mh) {
                if (w == null) if (ratio) |r| {
                    out[0] = mh * r;
                };
                out[1] = mh;
            },
            else => {},
        }
        return out;
    }
    if (std.mem.eql(u8, name, "textarea")) return .{ w orelse em * 20, h orelse em * 1.2 * 3 };
    if (std.mem.eql(u8, name, "select")) return .{ w orelse em * 8, h orelse em * 1.25 };
    // input: by type.
    const t = doc.getAttr(node, "type") orelse "text";
    if (std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio")) return .{ w orelse 13 * style.px_scale, h orelse 13 * style.px_scale };
    if (std.ascii.eqlIgnoreCase(t, "submit") or std.ascii.eqlIgnoreCase(t, "button") or std.ascii.eqlIgnoreCase(t, "reset")) {
        const font = fontOf(st);
        const label = doc.getAttr(node, "value") orelse "Submit";
        return .{ w orelse l.fonts.advance(font, label), h orelse em * 1.25 };
    }
    if (std.ascii.eqlIgnoreCase(t, "hidden")) return .{ 0, 0 };
    // A text field: `size` characters wide (20 by default).
    const chars = attrNumber(doc, node, "size") orelse 20;
    return .{ w orelse em * 0.5 * @max(1, chars), h orelse em * 1.25 };
}

/// A `transform`'s translation, applied as layout's last word on a box
/// (percentages of its own border box).
fn translateBox(l: *Layout, id: BoxId) Error!void {
    const b = l.get(id);
    const t = b.style.translate;
    if (t[0] == .px and t[0].px == 0 and t[1] == .px and t[1].px == 0) return;
    const dx = resolveLP(t[0], b.w);
    const dy = resolveLP(t[1], b.h);
    try moveBox(l, id, dx, dy);
    l.box(id).rel_dx += dx;
    l.box(id).rel_dy += dy;
}

/// A replaced box's content height once its content width is settled
/// (by a flex line, a stretch, or `left` and `right`): its own height,
/// else the width over its ratio.
fn replacedSizeAtWidth(l: *const Layout, id: BoxId, cb_w: f64, content_w: f64) f64 {
    const size = replacedSize(l, id, cb_w);
    const st = l.get(id).style;
    if (st.height != .auto or size[0] <= 0 or size[1] <= 0) return size[1];
    return content_w * size[1] / size[0];
}

fn attrNumber(doc: *const Document, node: NodeId, name: []const u8) ?f64 {
    const v = std.mem.trim(u8, doc.getAttr(node, name) orelse return null, " \t\r\n");
    var end: usize = 0;
    while (end < v.len and (std.ascii.isDigit(v[end]) or v[end] == '.')) : (end += 1) {}
    if (end == 0 or (end < v.len and v[end] == '%')) return null;
    return std.fmt.parseFloat(f64, v[0..end]) catch null;
}

fn isReplacedBox(l: *const Layout, b: *const Box) bool {
    return b.node != null and b.kind != .text and isReplaced(l, b.node.?);
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
const scratch_size: usize = 2 << 20;

/// The scratch stack, falling back to the arena when it is full.
fn sa(l: *Layout) std.mem.Allocator {
    return .{ .ptr = l, .vtable = &scratch_vtable };
}
const scratch_vtable: std.mem.Allocator.VTable = .{ .alloc = scratchAlloc, .resize = scratchResize, .remap = scratchRemap, .free = scratchFree };
fn scratchOwns(l: *Layout, mem: []u8) bool {
    const p = @intFromPtr(mem.ptr);
    return p >= @intFromPtr(l.scratch_buf.ptr) and p < @intFromPtr(l.scratch_buf.ptr) + l.scratch_buf.len;
}
pub var stat_scratch_fallbacks: usize = 0;
pub var stat_scratch_peak: usize = 0;
fn scratchAlloc(ctx: *anyopaque, n: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const l: *Layout = @ptrCast(@alignCast(ctx));
    if (l.scratch_fba.allocator().rawAlloc(n, alignment, ra)) |p| {
        stat_scratch_peak = @max(stat_scratch_peak, l.scratch_fba.end_index);
        return p;
    }
    stat_scratch_fallbacks += 1;
    return l.a.rawAlloc(n, alignment, ra);
}
fn scratchResize(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const l: *Layout = @ptrCast(@alignCast(ctx));
    return if (scratchOwns(l, mem)) l.scratch_fba.allocator().rawResize(mem, alignment, new_len, ra) else l.a.rawResize(mem, alignment, new_len, ra);
}
fn scratchRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const l: *Layout = @ptrCast(@alignCast(ctx));
    return if (scratchOwns(l, mem)) l.scratch_fba.allocator().rawRemap(mem, alignment, new_len, ra) else l.a.rawRemap(mem, alignment, new_len, ra);
}
fn scratchFree(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const l: *Layout = @ptrCast(@alignCast(ctx));
    if (scratchOwns(l, mem)) l.scratch_fba.allocator().rawFree(mem, alignment, ra) else l.a.rawFree(mem, alignment, ra);
}

/// Counts for a tool's census: inline layouts run, lines made, and
/// lines made into a list that had no room (a fresh list, or growth).
pub var stat_inline_layouts: usize = 0;
pub var stat_lines: usize = 0;
pub var stat_line_growth: usize = 0;

noinline fn layoutInlineContent(l: *Layout, id: BoxId, bfc: *Bfc) Error!f64 {
    stat_inline_layouts += 1;
    const b = l.box(id);
    const st = b.style;
    const cx = b.contentX();
    const cw = b.contentW();
    var y = b.contentY();
    const mark = l.scratch_fba.end_index;
    defer l.scratch_fba.end_index = mark;
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
        try line_open.appendSlice(sa(l), open_stack.items);
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
                if (!l.get(it.box).laid_out) try float_here.append(sa(l), it.box);
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
                    // Inline boxes closing right after the break close on
                    // this line (else `<a>word </a>` spans to the line's
                    // end, underline and all).
                    var keep = lb + 1;
                    while (keep < pending.items.len and pending.items[keep].item.kind == .inline_close) keep += 1;
                    consumed = pending.items[keep - 1].item_index_after;
                    pending.items.len = keep;
                    line_open.clearRetainingCapacity();
                    try line_open.appendSlice(sa(l), open_stack.items);
                    for (pending.items) |pi| {
                        if (pi.item.kind == .inline_open) try line_open.append(sa(l), pi.item.box);
                        if (pi.item.kind == .inline_close and line_open.items.len > 0) line_open.items.len -= 1;
                    }
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
            try pending.append(sa(l), .{ .item = it, .x = x, .item_index_after = consumed + 1 });
            x += it.w;
            if (it.kind == .space and !it.no_break) last_break = pending.items.len - 1;
            if (it.kind == .text and endsWithCjk(it.text)) last_break = pending.items.len - 1;
            if (it.kind == .inline_open) try line_open.append(sa(l), it.box);
            if (it.kind == .inline_close) {
                if (line_open.items.len > 0) line_open.items.len -= 1;
            }
            consumed += 1;
        }
        // Trailing collapsible spaces come off the line — also one just
        // inside a closing inline box (`<a>text </a>`, whose underline
        // would otherwise run on under it).
        while (pending.items.len > 0) {
            var k = pending.items.len;
            while (k > 0 and (pending.items[k - 1].item.kind == .inline_close or pending.items[k - 1].item.kind == .inline_open)) k -= 1;
            if (k == 0) break;
            const last = pending.items[k - 1];
            if (last.item.kind == .space and !last.item.no_break and last.item.text.len == 1 and l.get(last.item.box).style.white_space != .pre_wrap) {
                // Later items shift left by the space's width.
                const w = last.item.w;
                _ = pending.orderedRemove(k - 1);
                for (pending.items[k - 1 ..]) |*q| q.x -= w;
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
        // The line's height and baseline from its fragments. The strut
        // (the container's own font and line height) holds every line
        // open — except in quirks mode, where a line whose text is all
        // inside inline boxes (or that has none: a picture alone) is only
        // as tall as what it holds (the line height calculation quirk).
        var strut = true;
        if (l.doc.quirks != .no_quirks) {
            strut = forced and pending.items.len == 0;
            for (pending.items) |p| if ((p.item.kind == .text or p.item.kind == .space or p.item.kind == .marker) and l.get(p.item.box).parent == id) {
                strut = true;
            };
        }
        var above: f64 = if (strut) strut_m.ascent + (strut_lh - (strut_m.ascent + strut_m.descent)) / 2 else 0;
        var below: f64 = if (strut) strut_lh - above else 0;
        if (pending.items.len == 0 and forced) {
            // An empty line still has the strut's height.
        }
        const first_frag: u32 = @intCast(l.fragments.len);
        for (pending.items) |p| {
            const it = p.item;
            const ib = l.get(it.box);
            switch (it.kind) {
                .text, .space, .marker => {
                    const lh = ib.style.lineHeightPx();
                    const half = (lh - it.h) / 2;
                    // A fragment sits `shift` above the baseline (placed
                    // below at baseline - shift - its own ascent).
                    const shift = baselineShift(ib.style, it.h, it.baseline);
                    above = @max(above, it.baseline + half + shift);
                    below = @max(below, (it.h - it.baseline) + half - shift);
                },
                .atomic => {
                    const va = ib.style.vertical_align;
                    switch (va) {
                        .top, .bottom => {},
                        else => {
                            const shift = baselineShift(ib.style, it.h, it.baseline);
                            above = @max(above, it.baseline + shift);
                            below = @max(below, it.h - it.baseline - shift);
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
        stat_lines += 1;
        if (b.lines.items.len == b.lines.capacity) stat_line_growth += 1;
        try b.lines.append(l.a, .{ .x = line_x, .y = y, .w = avail, .h = line_h, .baseline = baseline, .first_frag = first_frag, .frag_count = @intCast(l.fragments.len - first_frag) });
        if (b.first_baseline == null) b.first_baseline = baseline;
        b.last_baseline = baseline;
        // Inline boxes still open carry to the next line.
        open_stack.clearRetainingCapacity();
        try open_stack.appendSlice(sa(l), line_open.items);
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
            const last_idx = l.fragments.len - 1;
            const want = ln.first_frag + ln.frag_count - 1;
            const moved = l.fragments.get(last_idx).*;
            var k = last_idx;
            while (k > want) : (k -= 1) l.fragments.at(k).* = l.fragments.get(k - 1).*;
            l.fragments.at(want).* = moved;
            for (b.lines.items[1..]) |*later| later.first_frag += 1;
        }
    }
    // Relatively positioned inline boxes: what is inside them moves by
    // their offsets (an atomic inline's box with its fragment).
    const rel_h: f64 = if (st.height == .px) st.height.px else 0;
    const definite = st.height != .auto;
    for (l.box(id).lines.items) |ln| for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| {
        const f = l.fragments.at(fi);
        const from = if (f.kind == .atomic) l.get(f.box).parent else f.box;
        const off = inlineOffset(l, from, cw, rel_h, definite);
        if (off[0] == 0 and off[1] == 0) continue;
        f.x += off[0];
        f.y += off[1];
        if (f.kind == .atomic) try moveBox(l, f.box, off[0], off[1]);
    };
    return y - b.contentY();
}

/// The relative offsets of the inline boxes from `from` up to the block
/// container, summed.
fn inlineOffset(l: *const Layout, from: ?BoxId, cb_w: f64, cb_h: f64, definite: bool) [2]f64 {
    var off: [2]f64 = .{ 0, 0 };
    var cur = from;
    while (cur) |c| : (cur = l.get(c).parent) {
        const b = l.get(c);
        if (b.kind != .inline_box and b.kind != .text) break;
        if (b.kind == .inline_box and b.style.position == .relative) {
            const st = b.style;
            off[0] += resolveLA(st.inset[3], cb_w) orelse -(resolveLA(st.inset[1], cb_w) orelse 0);
            off[1] += relativeInset(st.inset[0], cb_h, definite) orelse -(relativeInset(st.inset[2], cb_h, definite) orelse 0);
        }
    }
    return off;
}

/// A block split out of a relatively positioned inline (`splitInlines`
/// made it the container's child): the inline's offsets, found through
/// the document's parents between the block and the container.
fn splitAncestorOffset(l: *const Layout, id: BoxId, cb_w: f64) [2]f64 {
    var off: [2]f64 = .{ 0, 0 };
    const b = l.get(id);
    const node = b.node orelse return off;
    const container = b.parent orelse return off;
    const cb = l.get(container);
    const cnode = cb.node;
    const cb_h: f64 = if (cb.style.height == .px) cb.style.height.px else 0;
    const definite = cb.style.height != .auto;
    var cur = l.doc.get(node).parent;
    var depth: usize = 0;
    while (cur) |n| : (cur = l.doc.get(n).parent) {
        if (cnode != null and n == cnode.?) break;
        depth += 1;
        if (depth > 32) break;
        if (l.doc.get(n).kind != .element or n >= l.styles.computed.len) continue;
        const st = l.styles.get(n);
        if (st.position == .relative and st.display == .@"inline") {
            off[0] += resolveLA(st.inset[3], cb_w) orelse -(resolveLA(st.inset[1], cb_w) orelse 0);
            off[1] += relativeInset(st.inset[0], cb_h, definite) orelse -(relativeInset(st.inset[2], cb_h, definite) orelse 0);
        }
    }
    return off;
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
noinline fn spanFragments(l: *Layout, container: BoxId, first_frag: u32, line_start: f64, line_end: f64, y: f64, h: f64, baseline: f64) Error!void {
    _ = container;
    // The line's fragments are the range [first_frag, last_frag) of the
    // list; the spans appended below join the same list past it.
    const last_frag = l.fragments.len;
    // Boxes seen on this line, in order of first appearance.
    // The line's boxes seen so far: scratch, released with the line.
    const mark = l.scratch_fba.end_index;
    defer l.scratch_fba.end_index = mark;
    var seen: std.ArrayList(BoxId) = .empty;
    for (first_frag..last_frag) |fi| {
        const f = l.fragments.get(fi);
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
            if (!known) try seen.append(sa(l), pid);
        }
        if (f.kind == .inline_open or f.kind == .inline_close) {
            var known = false;
            for (seen.items) |s| if (s == f.box) {
                known = true;
            };
            if (!known) try seen.append(sa(l), f.box);
        }
    }
    for (seen.items) |bid| {
        var x0 = line_start;
        var x1 = line_end;
        var opened = false;
        var closed = false;
        for (first_frag..last_frag) |fi| {
            const f = l.fragments.get(fi);
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
            for (first_frag..last_frag) |fi| {
                const f = l.fragments.get(fi);
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

// ------------------------------------------------------------- flexbox

/// One flex item while its line is being built.
const FlexItem = struct {
    box: BoxId,
    /// The flex base size (inner main size before flexing) and the
    /// hypothetical one (clamped by min/max).
    base: f64,
    hyp: f64,
    /// Min and max inner main sizes.
    min: f64,
    max: f64,
    /// Outer edges on the main axis (margins + padding + border), with
    /// auto margins counted as zero, and how many main margins are auto.
    outer: f64,
    auto_main: u8,
    /// The result of flexing: the inner main size.
    main: f64 = 0,
    frozen: bool = false,
    /// The item's cross size (outer, margins included) once laid out.
    cross: f64 = 0,
};

const FlexLine = struct { first: usize, count: usize, cross: f64 = 0, main_used: f64 = 0 };

/// Lay out a flex container's items (CSS Flexbox Level 1, single and
/// multi-line): base sizes, line breaking, flexible lengths with min/max
/// clamping, cross sizes, `align-content`, `justify-content` with auto
/// margins absorbing free space, `align-items`/`align-self` including
/// stretch, `order`, gaps, and the reverse directions. Baseline
/// alignment is taken as flex-start. Returns the content height.
fn layoutFlexContents(l: *Layout, id: BoxId, cb_w: f64) Error!f64 {
    const container = l.box(id);
    const st = container.style;
    const row = st.flex_direction == .row or st.flex_direction == .row_reverse;
    const reverse_main = st.flex_direction == .row_reverse or st.flex_direction == .column_reverse;
    const content_w = container.contentW();
    // The container's definite height, when it has one: the column's
    // main size and the row's cross size to align against.
    const parent_h: ?f64 = if (container.parent) |p| (if (l.get(p).style.height == .auto and l.get(p).kind != .root) null else l.get(p).contentH()) else null;
    var definite_h: ?f64 = null;
    if (st.height == .px) definite_h = st.height.px - (if (st.box_sizing == .border_box) verticalExtras(container) else 0);
    if ((st.height == .percent or st.height == .calc) and parent_h != null) definite_h = resolveLA(st.height, parent_h.?).? - (if (st.box_sizing == .border_box) verticalExtras(container) else 0);
    const main_avail: ?f64 = if (row) content_w else definite_h;
    const cross_avail: ?f64 = if (row) definite_h else content_w;
    const main_gap = resolveLP(if (row) st.column_gap else st.row_gap, content_w);
    const cross_gap = resolveLP(if (row) st.row_gap else st.column_gap, content_w);

    // The items, in `order`, absolutes set aside.
    const mark = l.scratch_fba.end_index;
    defer l.scratch_fba.end_index = mark;
    var items: std.ArrayList(FlexItem) = .empty;
    for (container.children.items) |c| {
        const cb = l.box(c);
        if (cb.isPositioned()) {
            try addAbsolute(l, c);
            continue;
        }
        const margins = resolveEdges(cb, cb_w);
        cb.margin = .{ margins[0] orelse 0, margins[1] orelse 0, margins[2] orelse 0, margins[3] orelse 0 };
        const extras = if (row) horizontalExtras(cb) else verticalExtras(cb);
        const main_margins = if (row) cb.margin[1] + cb.margin[3] else cb.margin[0] + cb.margin[2];
        const auto_main: u8 = if (row) @as(u8, @intFromBool(margins[3] == null)) + @intFromBool(margins[1] == null) else @as(u8, @intFromBool(margins[0] == null)) + @intFromBool(margins[2] == null);
        // The flex base size: the basis, else the main size property,
        // else the content's max-content (row) or its laid-out height
        // (column).
        const pref = try preferredWidths(l, c);
        const cross_w_for_measure = if (row) content_w else measureCrossWidth(l, c, content_w, extras);
        var base: ?f64 = null;
        const basis = cb.style.flex_basis;
        const main_prop = if (row) cb.style.width else cb.style.height;
        if (basis != .auto) {
            if (basis == .px) base = basis.px else if (main_avail) |m| base = basis.percent * m / 100;
        }
        if (base == null and main_prop != .auto) {
            if (main_prop == .px) base = main_prop.px else if (main_avail) |m| base = main_prop.percent * m / 100;
        }
        if (base != null and cb.style.box_sizing == .border_box) base = base.? - extras;
        if (base == null) {
            if (row) {
                base = @max(0, pref.max - horizontalExtras(cb));
            } else {
                try layoutFlexItem(l, c, 0, 0, cross_w_for_measure, null);
                base = cb.h - verticalExtras(cb);
            }
        }
        var min: f64 = 0;
        var max: f64 = std.math.inf(f64);
        if (row) {
            min = resolveLP(cb.style.min_width, cb_w) - (if (cb.style.box_sizing == .border_box) extras else 0);
            // `min-width: auto` on a flex item: the content's min size,
            // no wider than the specified size.
            if (cb.style.min_width == .px and cb.style.min_width.px == 0 and cb.style.overflow_x == .visible) {
                const content = try contentWidths(l, c);
                min = @min(@max(0, content.min - horizontalExtras(cb)), base.?);
            }
            switch (cb.style.max_width) {
                .none => {},
                .px => |x| max = x - (if (cb.style.box_sizing == .border_box) extras else 0),
                .percent => |pc| max = cb_w * pc / 100 - (if (cb.style.box_sizing == .border_box) extras else 0),
                .calc => |m| max = m.of(cb_w) - (if (cb.style.box_sizing == .border_box) extras else 0),
            }
        } else {
            min = resolveLP(cb.style.min_height, parent_h orelse 0) - (if (cb.style.box_sizing == .border_box) extras else 0);
            // `min-height: auto` on a column item: its content's height,
            // no taller than a specified height (GitHub's content, basis
            // 0 in an indefinite column, stayed 0 tall without it).
            if (cb.style.min_height == .px and cb.style.min_height.px == 0 and cb.style.overflow_y == .visible) {
                try layoutFlexItem(l, c, 0, 0, cross_w_for_measure, null);
                var content_min = @max(0, l.get(c).h - verticalExtras(cb));
                if (cb.style.height == .px) content_min = @min(content_min, cb.style.height.px - (if (cb.style.box_sizing == .border_box) extras else 0));
                min = @max(min, content_min);
            }
            switch (cb.style.max_height) {
                .none => {},
                .px => |x| max = x - (if (cb.style.box_sizing == .border_box) extras else 0),
                .percent => |pc| if (definite_h) |h| {
                    max = h * pc / 100 - (if (cb.style.box_sizing == .border_box) extras else 0);
                },
                .calc => |m| if (definite_h) |h| {
                    max = m.of(h) - (if (cb.style.box_sizing == .border_box) extras else 0);
                },
            }
        }
        min = @max(0, min);
        max = @max(min, max);
        const hyp = @min(@max(base.?, min), max);
        try items.append(sa(l), .{ .box = c, .base = base.?, .hyp = hyp, .min = min, .max = max, .outer = extras + main_margins, .auto_main = auto_main });
    }
    // `order`: a stable sort on the property.
    std.mem.sort(FlexItem, items.items, l, struct {
        fn lessThan(ctx: *Layout, x: FlexItem, y: FlexItem) bool {
            return ctx.get(x.box).style.order < ctx.get(y.box).style.order;
        }
    }.lessThan);

    // Lines: everything on one, or as many fit.
    var lines: std.ArrayList(FlexLine) = .empty;
    if (items.items.len > 0) {
        if (st.flex_wrap == .nowrap or main_avail == null) {
            try lines.append(sa(l), .{ .first = 0, .count = items.items.len });
        } else {
            var first: usize = 0;
            var used: f64 = 0;
            for (items.items, 0..) |it, i| {
                const outer = it.hyp + it.outer;
                const with_gap = if (i > first) used + main_gap + outer else outer;
                if (i > first and with_gap > main_avail.? + 0.01) {
                    try lines.append(sa(l), .{ .first = first, .count = i - first });
                    first = i;
                    used = outer;
                } else used = with_gap;
            }
            try lines.append(sa(l), .{ .first = first, .count = items.items.len - first });
        }
    }

    // Flexible lengths per line, then cross sizes.
    for (lines.items) |*line| {
        const slice = items.items[line.first .. line.first + line.count];
        const gaps = main_gap * @as(f64, @floatFromInt(@max(line.count, 1) - 1));
        if (main_avail) |avail| {
            try resolveFlexibleLengths(l, slice, avail - gaps);
        } else for (slice) |*it| {
            it.main = it.hyp;
        }
        var used: f64 = gaps;
        for (slice) |it| used += it.main + it.outer;
        line.main_used = used;
        // Each item laid out at its main size; its cross size follows.
        line.cross = 0;
        for (slice) |*it| {
            const cb = l.box(it.box);
            if (row) {
                try layoutFlexItem(l, it.box, 0, 0, it.main, null);
                it.cross = cb.h + cb.margin[0] + cb.margin[2];
            } else {
                const w = measureCrossWidth(l, it.box, content_w, horizontalExtras(cb));
                try layoutFlexItem(l, it.box, 0, 0, w, it.main);
                it.cross = cb.w + cb.margin[1] + cb.margin[3];
            }
            line.cross = @max(line.cross, it.cross);
        }
    }
    // A single line in a container with a definite cross size fills it.
    if (lines.items.len == 1 and cross_avail != null and st.flex_wrap == .nowrap) lines.items[0].cross = cross_avail.?;

    // `align-content`: where the lines go in the cross axis.
    var lines_cross: f64 = 0;
    for (lines.items) |ln| lines_cross += ln.cross;
    const n_lines: f64 = @floatFromInt(lines.items.len);
    lines_cross += cross_gap * @max(n_lines - 1, 0);
    var cross_start: f64 = 0;
    var cross_between: f64 = cross_gap;
    if (cross_avail) |avail| if (lines.items.len > 0) {
        const free = avail - lines_cross;
        switch (st.align_content) {
            .stretch => if (free > 0) {
                for (lines.items) |*ln| ln.cross += free / n_lines;
            },
            .flex_end, .end => cross_start = free,
            .center => cross_start = free / 2,
            .space_between => if (lines.items.len > 1 and free > 0) {
                cross_between += free / (n_lines - 1);
            },
            .space_around => if (free > 0) {
                cross_start = free / n_lines / 2;
                cross_between += free / n_lines;
            },
            .space_evenly => if (free > 0) {
                cross_start = free / (n_lines + 1);
                cross_between += free / (n_lines + 1);
            },
            .flex_start, .start => {},
        }
    };

    // Place: main positions with `justify-content` and auto margins,
    // cross positions with `align-self`, stretch resizing the item.
    const main_origin = if (row) container.contentX() else container.contentY();
    const cross_origin = if (row) container.contentY() else container.contentX();
    var cross_pos = cross_origin + cross_start;
    const wrap_reverse = st.flex_wrap == .wrap_reverse;
    var line_index: usize = 0;
    while (line_index < lines.items.len) : (line_index += 1) {
        const line = lines.items[if (wrap_reverse) lines.items.len - 1 - line_index else line_index];
        const slice = items.items[line.first .. line.first + line.count];
        const avail = main_avail orelse line.main_used;
        var free = @max(0, avail - line.main_used);
        var auto_count: usize = 0;
        for (slice) |it| auto_count += it.auto_main;
        var main_start: f64 = 0;
        var main_between: f64 = main_gap;
        if (auto_count > 0) {
            // Auto margins take the free space; justify-content is moot.
        } else switch (st.justify_content) {
            .flex_start, .start => {},
            .flex_end, .end => main_start = free,
            .center => main_start = free / 2,
            .space_between => if (line.count > 1) {
                main_between += free / @as(f64, @floatFromInt(line.count - 1));
            },
            .space_around => {
                main_start = free / @as(f64, @floatFromInt(line.count)) / 2;
                main_between += free / @as(f64, @floatFromInt(line.count));
            },
            .space_evenly => {
                main_start = free / @as(f64, @floatFromInt(line.count + 1));
                main_between += free / @as(f64, @floatFromInt(line.count + 1));
            },
        }
        const auto_share: f64 = if (auto_count > 0) free / @as(f64, @floatFromInt(auto_count)) else 0;
        if (auto_count > 0) free = 0;
        var pos = main_origin + main_start;
        for (slice, 0..) |*it, k| {
            const cb = l.box(it.box);
            if (k > 0) pos += main_between;
            const margins = resolveEdges(cb, cb_w);
            // Auto main margins get their share now.
            if (row) {
                if (margins[3] == null) cb.margin[3] = auto_share;
                if (margins[1] == null) cb.margin[1] = auto_share;
            } else {
                if (margins[0] == null) cb.margin[0] = auto_share;
                if (margins[2] == null) cb.margin[2] = auto_share;
            }
            const outer_main = it.main + (if (row) horizontalExtras(cb) + cb.margin[1] + cb.margin[3] else verticalExtras(cb) + cb.margin[0] + cb.margin[2]);
            // Cross alignment: the item's own `align-self`, else the
            // container's `align-items` (baseline taken as flex-start).
            const alignment: style.AlignSelf = if (cb.style.align_self != .auto) cb.style.align_self else switch (st.align_items) {
                .stretch, .normal => .stretch,
                .flex_start, .start, .self_start, .baseline, .left => .flex_start,
                .flex_end, .end, .self_end, .right => .flex_end,
                .center => .center,
            };
            const cross_auto_margins = if (row) (margins[0] == null or margins[2] == null) else (margins[1] == null or margins[3] == null);
            var cross_size = it.cross; // outer
            if ((alignment == .stretch or alignment == .normal) and !cross_auto_margins and (if (row) cb.style.height == .auto else cb.style.width == .auto)) {
                cross_size = line.cross;
                if (row) {
                    cb.h = @max(0, line.cross - cb.margin[0] - cb.margin[2]);
                } else {
                    // A column item stretches in width: laid out again at it.
                    const w = @max(0, line.cross - cb.margin[1] - cb.margin[3] - horizontalExtras(cb));
                    try layoutFlexItem(l, it.box, 0, 0, w, it.main);
                }
            }
            var cross_offset: f64 = 0;
            if (cross_auto_margins) {
                // Auto cross margins centre (both) or push (one).
                const spare = @max(0, line.cross - it.cross);
                if (row) {
                    if (margins[0] == null and margins[2] == null) cross_offset = spare / 2 else if (margins[0] == null) cross_offset = spare;
                } else {
                    if (margins[3] == null and margins[1] == null) cross_offset = spare / 2 else if (margins[3] == null) cross_offset = spare;
                }
            } else switch (alignment) {
                .flex_end, .end, .self_end, .right => cross_offset = line.cross - cross_size,
                .center => cross_offset = (line.cross - cross_size) / 2,
                else => {},
            }
            const main_pos = if (reverse_main) main_origin + avail - (pos - main_origin) - outer_main else pos;
            const x = if (row) main_pos + cb.margin[3] else cross_pos + cross_offset + cb.margin[3];
            const y = if (row) cross_pos + cross_offset + cb.margin[0] else main_pos + cb.margin[0];
            try moveBox(l, it.box, x - cb.x, y - cb.y);
            pos += outer_main;
        }
        cross_pos += line.cross + cross_between;
    }
    if (row) return if (definite_h) |h| h else lines_cross;
    // A column: the main extent, or the definite height.
    if (definite_h) |h| return h;
    var main_extent: f64 = 0;
    for (lines.items) |ln| main_extent = @max(main_extent, ln.main_used);
    return main_extent;
}

/// A column item's width before its cross size is known: its `width`,
/// else the container's content width (what stretch will give it).
fn measureCrossWidth(l: *Layout, id: BoxId, content_w: f64, extras: f64) f64 {
    const cb = l.box(id);
    if (resolveLA(cb.style.width, content_w)) |w| return constrainWidth(cb, if (cb.style.box_sizing == .border_box) w - extras else w, content_w);
    return constrainWidth(cb, @max(0, content_w - cb.margin[1] - cb.margin[3] - extras), content_w);
}

/// The flexible lengths algorithm (§9.7) for one line: grow or shrink
/// the unfrozen items into `avail`, clamping by min and max and
/// redistributing until nothing violates.
fn resolveFlexibleLengths(l: *Layout, items: []FlexItem, avail: f64) Error!void {
    var hyp_sum: f64 = 0;
    for (items) |it| hyp_sum += it.hyp + it.outer;
    const growing = hyp_sum < avail;
    for (items) |*it| {
        const cb = l.get(it.box);
        const factor = if (growing) cb.style.flex_grow else cb.style.flex_shrink;
        it.main = it.hyp;
        // Inflexible, or already past what flexing would do to it.
        it.frozen = factor == 0 or (growing and it.base > it.hyp) or (!growing and it.base < it.hyp);
    }
    var rounds: usize = 0;
    while (rounds < 16) : (rounds += 1) {
        var frozen_space: f64 = 0;
        var unfrozen: usize = 0;
        var factor_sum: f64 = 0;
        var scaled_sum: f64 = 0;
        for (items) |it| {
            const cb = l.get(it.box);
            if (it.frozen) {
                frozen_space += it.main + it.outer;
            } else {
                unfrozen += 1;
                frozen_space += it.base + it.outer;
                factor_sum += if (growing) cb.style.flex_grow else cb.style.flex_shrink;
                scaled_sum += cb.style.flex_shrink * it.base;
            }
        }
        if (unfrozen == 0) break;
        var free = avail - frozen_space;
        if (factor_sum > 0 and factor_sum < 1) free *= factor_sum;
        var total_violation: f64 = 0;
        for (items) |*it| {
            if (it.frozen) continue;
            const cb = l.get(it.box);
            var target = it.base;
            if (growing and factor_sum > 0) {
                target = it.base + free * cb.style.flex_grow / factor_sum;
            } else if (!growing and scaled_sum > 0) {
                target = it.base + free * (cb.style.flex_shrink * it.base) / scaled_sum;
            }
            const clamped = @min(@max(target, it.min), it.max);
            total_violation += clamped - target;
            it.main = clamped;
        }
        if (@abs(total_violation) < 0.001) {
            for (items) |*it| it.frozen = true;
            break;
        }
        for (items) |*it| {
            if (it.frozen) continue;
            const cb = l.get(it.box);
            var target = it.base;
            if (growing and factor_sum > 0) {
                target = it.base + free * cb.style.flex_grow / factor_sum;
            } else if (!growing and scaled_sum > 0) {
                target = it.base + free * (cb.style.flex_shrink * it.base) / scaled_sum;
            }
            // Freeze the items clamped in the direction of the total.
            if (total_violation > 0 and it.main > target) it.frozen = true;
            if (total_violation < 0 and it.main < target) it.frozen = true;
        }
    }
}

/// Lay out a flex item as a block of its own formatting context at
/// `content_w`, and at `content_h` when given (a column item's main
/// size); its origin is placed by the caller. An item laid out again
/// (a column item measured, then sized) first drops what its previous
/// layout recorded.
fn layoutFlexItem(l: *Layout, id: BoxId, x: f64, y: f64, content_w: f64, content_h: ?f64) Error!void {
    const b = l.box(id);
    if (b.laid_out) try purgeSubtree(l, id);
    b.x = x + b.margin[3];
    b.y = y + b.margin[0];
    b.w = content_w + horizontalExtras(b);
    var inner: Bfc = .{ .root = id };
    try layoutBlockContents(l, id, &inner, content_w);
    if (content_h) |h| b.h = h + verticalExtras(b);
}

/// An out-of-flow box for the end of layout, once however often its
/// container was measured or laid out.
fn addAbsolute(l: *Layout, id: BoxId) Error!void {
    if (l.get(id).style.position == .fixed) l.has_fixed = true;
    for (l.absolutes.items) |ab| if (ab.box == id) return;
    try l.absolutes.append(l.a, .{ .box = id, .cb = containingBlockFor(l, id) });
}

/// Forget a subtree's layout records — floats, fragments, lines,
/// baselines — before it is laid out again.
fn purgeSubtree(l: *Layout, root_id: BoxId) Error!void {
    var i: usize = 0;
    while (i < l.floats.items.len) {
        if (isDescendant(l, l.floats.items[i].box, root_id)) {
            _ = l.floats.orderedRemove(i);
        } else i += 1;
    }
    // Absolutes stay: each is listed once (`addAbsolute`) and laid out
    // at the end whatever measured its container.
    try resetLines(l, root_id);
}

/// A subtree's lines go, and the fragments they held die with them —
/// and when the dead ones are the store's newest, the store shrinks
/// back over them. A subtree laid out again was most often laid out
/// last (a container measuring its items, then placing them), so its
/// fragments sit at the end; kept, they piled up to 662,000 dead
/// against 6,600 live on the Guardian's front page, 40 MB the page
/// domain did not have (2026-09-28).
fn resetLines(l: *Layout, id: BoxId) Error!void {
    var low: usize = l.fragments.len;
    try resetLinesFrom(l, id, &low);
    var i = low;
    while (i < l.fragments.len) : (i += 1) if (!l.fragments.get(i).dead) break;
    if (i == l.fragments.len) {
        l.dead_fragments -= @min(l.dead_fragments, l.fragments.len - low);
        l.fragments.len = low;
        return;
    }
    // Dead ones under live ones (a container's items laid out in turn,
    // then again): once they are most of the store, pack the live ones
    // down and renumber every line — 175,000 dead against 6,600 live
    // on the Guardian's front page were 11 MB (2026-09-28).
    if (l.fragments.len >= 4096 and l.dead_fragments > l.fragments.len / 2) compactFragments(l);
}

/// The live fragments packed down in order, every line's first index
/// rewritten (a line's fragments are consecutive, dead or live together).
fn compactFragments(l: *Layout) void {
    const mark = l.scratch_fba.end_index;
    defer l.scratch_fba.end_index = mark;
    const n = l.fragments.len;
    const dead_before = sa(l).alloc(u32, n) catch return;
    var dead: u32 = 0;
    for (0..n) |i| {
        dead_before[i] = dead;
        if (l.fragments.get(i).dead) dead += 1;
    }
    for (0..l.boxes.len) |bi| for (l.boxes.at(bi).lines.items) |*ln| {
        if (ln.frag_count > 0) ln.first_frag -= dead_before[ln.first_frag];
    };
    var w: usize = 0;
    for (0..n) |r| {
        const f = l.fragments.get(r).*;
        if (f.dead) continue;
        l.fragments.at(w).* = f;
        w += 1;
    }
    l.fragments.len = w;
    l.dead_fragments = 0;
}

fn resetLinesFrom(l: *Layout, id: BoxId, low: *usize) Error!void {
    const b = l.box(id);
    for (b.lines.items) |ln| {
        if (ln.frag_count > 0) low.* = @min(low.*, ln.first_frag);
        for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| l.fragments.at(fi).dead = true;
        l.dead_fragments += ln.frag_count;
    }
    b.lines.clearRetainingCapacity();
    b.first_baseline = null;
    b.last_baseline = null;
    b.laid_out = false;
    for (b.children.items) |c| try resetLinesFrom(l, c, low);
}

/// Whether `id` is `root_id` or below it.
fn isDescendant(l: *const Layout, id: BoxId, root_id: BoxId) bool {
    var p: ?BoxId = id;
    while (p) |pid| : (p = l.get(pid).parent) if (pid == root_id) return true;
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
    for (0..l.boxes.len) |i| if (l.boxes.get(i).node == id) return l.boxes.get(i);
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
// ------------------------------------------------- scrolling and sticky

/// A box whose vertical overflow scrolls (`scroll` or `auto`), the root
/// aside (the viewport scrolls the root).
pub fn isScrollContainer(b: *const Box) bool {
    return b.kind != .root and b.kind != .text and (b.style.overflow_y == .scroll or b.style.overflow_y == .auto);
}

/// A box that clips its content (any non-visible overflow).
pub fn clipsOverflow(b: *const Box) bool {
    return b.kind != .root and b.kind != .text and (b.style.overflow_x != .visible or b.style.overflow_y != .visible);
}

/// The scrollable overflow of a container: how far its content reaches
/// below its padding box's top, from every descendant box (floats and
/// positioned ones included, a fixed one not).
pub fn scrollExtent(l: *const Layout, id: BoxId) f64 {
    const b = l.get(id);
    const top = b.y + b.border[0];
    var bottom = top + b.h - b.border[0] - b.border[2];
    var stack: [64]BoxId = undefined;
    var n: usize = 0;
    for (b.children.items) |c| if (n < stack.len) {
        stack[n] = c;
        n += 1;
    };
    while (n > 0) {
        n -= 1;
        const cid = stack[n];
        const cb = l.get(cid);
        if (cb.kind == .text or cb.style.position == .fixed) continue;
        if (cb.laid_out) bottom = @max(bottom, cb.y + cb.h + cb.margin[2]);
        for (cb.children.items) |c| if (n < stack.len) {
            stack[n] = c;
            n += 1;
        };
    }
    return bottom - top;
}

/// How far a container can scroll: its extent past its padding box.
pub fn scrollMax(l: *const Layout, id: BoxId) f64 {
    const b = l.get(id);
    const inner = b.h - b.border[0] - b.border[2];
    return @max(0, scrollExtent(l, id) - inner);
}

/// A box the painter renders as a layer of its own (a stacking
/// context): translucent, transformed beyond a translation, or clipped
/// by a shape.
pub fn isLayerBox(b: *const Box) bool {
    if (b.kind == .root or b.kind == .text) return false;
    const st = b.style;
    return (st.opacity > 0 and st.opacity < 1) or st.transform_fns.len > 0 or st.clip_path != .none;
}

/// The nearest ancestor that owns an absolutely positioned box's
/// painting — a layer box anywhere above it (a stacking context takes
/// every descendant), or an overflow box between it and its containing
/// block (inclusive). None for a fixed box, unless a layer holds it.
pub fn clipAncestor(l: *const Layout, id: BoxId) ?BoxId {
    const b = l.get(id);
    const cb = containingBlockFor(l, id);
    var past_cb = b.style.position == .fixed;
    var p = b.parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (isLayerBox(pb)) return pid;
        if (!past_cb and clipsOverflow(pb)) return pid;
        if (pid == cb) past_cb = true;
    }
    return null;
}

pub const Bounds = struct { x: f64, y: f64, w: f64, h: f64 };

/// What a box's subtree paints: the union of its and its descendants'
/// border boxes (a fixed descendant aside), document coordinates.
pub fn paintBounds(l: *const Layout, id: BoxId) Bounds {
    const b = l.get(id);
    var x0 = b.x;
    var y0 = b.y;
    var x1 = b.x + b.w;
    var y1 = b.y + b.h;
    var stack: [64]BoxId = undefined;
    var n: usize = 0;
    for (b.children.items) |c| if (n < stack.len) {
        stack[n] = c;
        n += 1;
    };
    while (n > 0) {
        n -= 1;
        const cid = stack[n];
        const cb = l.get(cid);
        if (cb.kind == .text or cb.style.position == .fixed) continue;
        if (cb.laid_out and cb.kind != .inline_box) {
            x0 = @min(x0, cb.x);
            y0 = @min(y0, cb.y);
            x1 = @max(x1, cb.x + cb.w);
            y1 = @max(y1, cb.y + cb.h);
        }
        for (cb.lines.items) |ln| {
            x0 = @min(x0, ln.x);
            y0 = @min(y0, ln.y);
            x1 = @max(x1, ln.x + ln.w);
            y1 = @max(y1, ln.y + ln.h);
        }
        for (cb.children.items) |c| if (n < stack.len) {
            stack[n] = c;
            n += 1;
        };
    }
    return .{ .x = x0, .y = y0, .w = x1 - x0, .h = y1 - y0 };
}

/// A sticky box's offset at this scroll: it is held at its `top` (or
/// `bottom`) inset of the scrollport — the viewport, or the nearest
/// scroll container — while its containing block's content box has room
/// for it (CSS Positioned Layout §3.4).
pub fn stickyOffset(l: *const Layout, id: BoxId, scroll_y: f64) f64 {
    const b = l.get(id);
    if (b.style.position != .sticky) return 0;
    // The scrollport, in the coordinates the box was laid out in.
    var view_top = scroll_y;
    var view_bottom = scroll_y + l.viewport_h;
    var p = b.parent;
    while (p) |pid| : (p = l.get(pid).parent) {
        const pb = l.get(pid);
        if (isScrollContainer(pb)) {
            view_top = pb.y + pb.border[0] + pb.scroll_top;
            view_bottom = view_top + pb.h - pb.border[0] - pb.border[2];
            break;
        }
    }
    const parent = l.get(b.parent orelse return 0);
    const cb_top = parent.contentY();
    const cb_bottom = parent.contentY() + parent.contentH();
    const outer_top = b.y - b.margin[0];
    const outer_bottom = b.y + b.h + b.margin[2];
    var dy: f64 = 0;
    if (resolveLA(b.style.inset[0], l.viewport_h)) |t| {
        dy = @max(0, view_top + t - outer_top);
        dy = @min(dy, @max(0, cb_bottom - outer_bottom));
    }
    if (resolveLA(b.style.inset[2], l.viewport_h)) |bt| {
        var up = @min(0, view_bottom - bt - outer_bottom);
        up = @max(up, @min(0, cb_top - outer_top));
        if (dy == 0) dy = up;
    }
    return dy;
}

/// How far the painter moves a box from where the flow put it, at this
/// scroll: the sticky offsets of the box and its ancestors, less the
/// scroll of every container above it.
pub fn flowOffset(l: *const Layout, id: BoxId, scroll_y: f64) f64 {
    if (!l.has_sticky and !l.has_scrolled) return 0;
    var off: f64 = 0;
    var cur: ?BoxId = id;
    var first = true;
    while (cur) |c| : (cur = l.get(c).parent) {
        const b = l.get(c);
        if (b.style.position == .sticky) off += stickyOffset(l, c, scroll_y);
        if (!first and isScrollContainer(b)) off -= b.scroll_top;
        first = false;
    }
    return off;
}

/// Whether a box is inside a `position: fixed` subtree: laid out in
/// viewport coordinates, painted without the scroll.
pub fn inFixed(l: *const Layout, id: BoxId) bool {
    if (!l.has_fixed) return false;
    var cur: ?BoxId = id;
    while (cur) |c| : (cur = l.get(c).parent) {
        if (l.get(c).style.position == .fixed) return true;
    }
    return false;
}

/// The element under a point: `x`, `y` in document coordinates (the
/// viewport's plus the scroll); a fixed subtree is tested against the
/// viewport's.
pub fn hitTest(l: *const Layout, x: f64, y: f64, scroll_y: f64) ?NodeId {
    var best: ?BoxId = null;
    var best_depth: usize = 0;
    // Inline content is where its fragments landed: one pass over them
    // finds every inline box under the point (a pass per box scanned the
    // whole list per box — 10⁸ compares a mouse move on a long article).
    var i: usize = 0;
    while (i < l.fragments.len) {
        const run = l.fragments.slice(i);
        i += run.len;
        for (run) |*f| {
            if (f.dead or !(x >= f.x and x < f.x + f.w)) continue;
            const yy = (if (inFixed(l, f.box)) y - scroll_y else y) - flowOffset(l, f.box, scroll_y);
            if (!(yy >= f.y and yy < f.y + f.h)) continue;
            const depth = boxDepth(l, f.box);
            if (best == null or depth >= best_depth) {
                best = f.box;
                best_depth = depth;
            }
        }
    }
    var bi: usize = 0;
    while (bi < l.boxes.len) {
        const run = l.boxes.slice(bi);
        const base = bi;
        bi += run.len;
        for (run, 0..) |*b, k| {
            if (b.kind == .root or b.kind == .text or b.kind == .inline_box) continue;
            if (!(b.laid_out and x >= b.x and x < b.x + b.w)) continue;
            const id: BoxId = @intCast(base + k);
            const yy = (if (inFixed(l, id)) y - scroll_y else y) - flowOffset(l, id, scroll_y);
            if (!(yy >= b.y and yy < b.y + b.h)) continue;
            const depth = boxDepth(l, id);
            if (best == null or depth >= best_depth) {
                best = id;
                best_depth = depth;
            }
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
    const hit = hitTest(l, 30, 50, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.isHtml(hit, "a"));
    const before = hitTest(l, 5, 50, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.isHtml(before, "p"));
    const above = hitTest(l, 5, 10, 0) orelse return error.TestUnexpectedResult;
    try std.testing.expect(doc.isHtml(above, "div"));
}

/// A stand-in picture provider: every `img` is a `w`×`h` bitmap.
const TestImages = struct {
    w: u32,
    h: u32,
    px: [4]u8 = .{ 0, 0, 0, 255 },

    fn get(ctx: *anyopaque, _: NodeId) ?Bitmap {
        const self: *TestImages = @ptrCast(@alignCast(ctx));
        return .{ .w = self.w, .h = self.h, .rgba = &self.px };
    }
    const vtable: Images.VTable = .{ .get = get };
    fn images(self: *TestImages) Images {
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }
};

fn layoutWithImages(a: std.mem.Allocator, src: []const u8, w: f64, imgs: *TestImages) !*Layout {
    const doc = try html.parse(a, src, .{});
    const env: style.Env = .{ .width = w, .height = 300 };
    const sheets = try style.collectDocumentSheets(a, doc, env);
    const styles = try a.create(style.Styles);
    styles.* = try style.compute(a, doc, sheets, env);
    var fixed: FixedFonts = .{};
    return layoutDocumentWith(a, doc, styles, fixed.fonts(), imgs.images(), w, 300);
}

// Wikipedia's globe (2026-09-23): an absolutely positioned picture took
// the block path and was laid out 0 tall; a block picture that had not
// arrived collapsed through like an empty div.
test "layout: a picture keeps its size however it is laid out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var imgs: TestImages = .{ .w = 200, .h = 100 };
    const l = try layoutWithImages(a, "<body style='margin:0'><div style='position:relative'><img id=abs style='position:absolute;top:5px;left:7px' src=x></div><img id=blk style='display:block;margin:0 auto' src=x><img id=css style='display:block;width:50px;height:auto' width=200 height=100 src=x><div style='display:flex'><img id=flex src=x></div>", 400, &imgs);
    const doc = l.doc;
    const abs = boxOf(l, doc, "#abs");
    try std.testing.expectEqual(@as(f64, 200), abs.w);
    try std.testing.expectEqual(@as(f64, 100), abs.h);
    try std.testing.expectEqual(@as(f64, 7), abs.x);
    const blk = boxOf(l, doc, "#blk");
    // A block picture is its own width, centred by auto margins.
    try std.testing.expectEqual(@as(f64, 200), blk.w);
    try std.testing.expectEqual(@as(f64, 100), blk.h);
    try std.testing.expectEqual(@as(f64, 100), blk.x);
    // CSS width wins over the attribute; `height: auto` keeps the ratio.
    const css_img = boxOf(l, doc, "#css");
    try std.testing.expectEqual(@as(f64, 50), css_img.w);
    try std.testing.expectEqual(@as(f64, 25), css_img.h);
    const flex = boxOf(l, doc, "#flex");
    try std.testing.expectEqual(@as(f64, 100), flex.h);
}

test "layout: size attributes are hints, and give a ratio before the picture" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0'><img id=hint width=120 height=60><img id=ratio style='width:60px' width=120 height=60><img id=none>", 400);
    const doc = l.doc;
    try std.testing.expectEqual(@as(f64, 120), boxOf(l, doc, "#hint").w);
    try std.testing.expectEqual(@as(f64, 60), boxOf(l, doc, "#hint").h);
    // The author's width wins over the hint and the attribute's height
    // stands (the presentational hint is a declaration like any other).
    try std.testing.expectEqual(@as(f64, 60), boxOf(l, doc, "#ratio").w);
    try std.testing.expectEqual(@as(f64, 60), boxOf(l, doc, "#ratio").h);
    // A picture with no size that has not arrived takes no room.
    try std.testing.expectEqual(@as(f64, 0), boxOf(l, doc, "#none").w);
}

// Google's bar (2026-09-23): measuring a container's widths laid its
// inline-blocks out, and every measurement added another set of lines —
// "Gmail" painted four times, each pass a little further along.
test "layout: an inline-block measured and laid out again keeps one set of lines" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0'><div style='display:flex;justify-content:flex-end'><div style='display:inline-block'><a id=g style='display:inline-block;padding:0 4px'>Gmail</a> <a style='display:inline-block'>Images</a></div></div>", 400);
    const doc = l.doc;
    const g = boxOf(l, doc, "#g");
    try std.testing.expectEqual(@as(usize, 1), g.lines.items.len);
    var live: usize = 0;
    for (0..l.fragments.len) |fi| {
        const f = l.fragments.get(fi);
        if (!f.dead and std.mem.eql(u8, f.text, "Gmail")) live += 1;
    }
    try std.testing.expectEqual(@as(usize, 1), live);
}

test "layout: an absolute inside an absolute is laid out" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0'><div style='position:absolute;top:10px;left:10px;width:100px;height:100px'><div id=in style='position:absolute;top:5px;left:5px;width:20px;height:20px'></div></div>", 400);
    const inner = boxOf(l, l.doc, "#in");
    try std.testing.expectEqual(@as(f64, 15), inner.x);
    try std.testing.expectEqual(@as(f64, 15), inner.y);
    try std.testing.expectEqual(@as(f64, 20), inner.h);
}

// Wikipedia's search row: a 44px field with `vertical-align: middle` sat
// 36px down its line — the line's height counted the shift the wrong way.
test "layout: a middle-aligned atomic grows its line on both sides of the baseline" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0;font-size:16px;line-height:20px'><div id=line><span id=box style='display:inline-block;height:40px;width:10px;vertical-align:middle'></span>x</div>", 400);
    const doc = l.doc;
    const line = boxOf(l, doc, "#line");
    const box = boxOf(l, doc, "#box");
    // The box starts at the line's top, not below it.
    try std.testing.expectEqual(line.y, box.y);
    try std.testing.expect(line.h >= 40 and line.h < 50);
}

test "layout: a button's content is laid out like any box's" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0'><button id=b>\n<i id=i style='display:inline-block;width:22px;height:22px'></i>\n</button>", 400);
    const doc = l.doc;
    const i = boxOf(l, doc, "#i");
    const b = boxOf(l, doc, "#b");
    try std.testing.expectEqual(@as(f64, 22), i.h);
    try std.testing.expect(i.x > b.x and i.x + i.w < b.x + b.w);
}

test "layout: a table sizes its columns from its cells and its rows from the tallest" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    // FixedFonts: 16px text is 8px a character.
    const l = try layoutText(a, "<body style='margin:0;font-size:16px;line-height:20px'><table id=t cellspacing=4 cellpadding=0><tr><td id=a>aaaa</td><td id=b>bb</td></tr><tr><td id=c colspan=2>cccccccccccccccc</td></tr><tr><td id=d style='height:50px'>d</td><td id=e style='vertical-align:bottom'>e</td></tr></table>", 400);
    const doc = l.doc;
    const t = boxOf(l, doc, "#t");
    const ba = boxOf(l, doc, "#a");
    const bb = boxOf(l, doc, "#b");
    const bc = boxOf(l, doc, "#c");
    const bd = boxOf(l, doc, "#d");
    const be = boxOf(l, doc, "#e");
    // Shrink-to-fit: the spanning cell's 128px is the widest need.
    try std.testing.expectEqual(@as(f64, 4 + 128 + 4), t.w);
    try std.testing.expectEqual(@as(f64, 4), ba.x);
    try std.testing.expectEqual(ba.x + ba.w + 4, bb.x);
    try std.testing.expectEqual(@as(f64, 128), bc.w);
    // Cells in a row share its top and its height.
    try std.testing.expectEqual(bd.y, be.y);
    try std.testing.expectApproxEqAbs(@as(f64, 50), be.h, 0.001);
    // A bottom-aligned cell's line sits at the bottom.
    try std.testing.expect(be.lines.items[0].y > be.y + 20);
    try std.testing.expectApproxEqAbs(ba.y + ba.h + 4, bc.y, 0.001);
}

test "layout: a picture with a percentage max-width shrinks to a fixed-width table" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0'><table id=t style='width:200px;border-spacing:0'><tr><td style='padding:0'><img id=i width=300 height=100 style='max-width:100%'></td></tr></table>", 600);
    const t = boxOf(l, l.doc, "#t");
    try std.testing.expectApproxEqAbs(@as(f64, 200), t.w, 0.5);
    const i = boxOf(l, l.doc, "#i");
    try std.testing.expect(i.w <= 200.5);
    try std.testing.expect(i.w >= 199.5);
}

test "layout: a table narrower than its columns' minimums widens to them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0'><table id=t style='width:50px;border-spacing:0'><tr><td style='padding:0'><div style='width:120px;height:10px'></div></td></tr></table>", 600);
    const t = boxOf(l, l.doc, "#t");
    try std.testing.expect(t.w >= 120);
}

test "layout: percentage columns widen an auto table and take their share" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0;font-size:16px'><table cellspacing=0 cellpadding=0><tr><td id=l width='25%'>x</td><td id=m>mmmmmmmmmmmmmmmmmmmm</td><td id=r width='25%'>y</td></tr></table>", 800);
    const doc = l.doc;
    const m = boxOf(l, doc, "#m");
    const left = boxOf(l, doc, "#l");
    // The middle's 160px is half: the table is 320 and each side 80.
    try std.testing.expectEqual(@as(f64, 160), m.w);
    try std.testing.expectEqual(@as(f64, 80), left.w);
    try std.testing.expectEqual(@as(f64, 80), m.x);
}

test "layout: table-cell boxes outside a table get an anonymous one" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<body style='margin:0;font-size:16px'><div><div id=x style='display:table-cell;width:100px'>a</div><div id=y style='display:table-cell;width:50px'>b</div></div>", 400);
    const doc = l.doc;
    const x = boxOf(l, doc, "#x");
    const y = boxOf(l, doc, "#y");
    try std.testing.expectEqual(x.y, y.y);
    try std.testing.expectEqual(@as(f64, 100), x.w);
    try std.testing.expectEqual(x.x + 100, y.x);
}

// Hacker News (2026-09-23): no doctype, so quirks mode — its tables do
// not inherit `<center>`'s alignment, and a line whose text is all in
// inline boxes is only as tall as that text.
test "layout: quirks mode resets tables and drops the strut from text-less roots" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src = "<body style='margin:0;font-size:32px'><center><table cellspacing=0 cellpadding=0 width=400><tr><td id=c><span id=s style='font-size:10px;line-height:12px'>x</span></td></tr></table></center>";
    const quirky = try layoutText(a, src, 400);
    const cq = boxOf(quirky, quirky.doc, "#c");
    try std.testing.expectEqual(@as(f64, 12), cq.h);
    // The span's text starts at the cell's left (not centred).
    var text_x: f64 = -1;
    for (0..quirky.fragments.len) |fi| {
        const f = quirky.fragments.get(fi);
        if (!f.dead and std.mem.eql(u8, f.text, "x")) text_x = f.x;
    }
    try std.testing.expectEqual(@as(f64, 0), text_x);
    const standard = try layoutText(a, try std.mem.concat(a, u8, &.{ "<!DOCTYPE html>", src }), 400);
    const cs = boxOf(standard, standard.doc, "#c");
    try std.testing.expect(cs.h > 30);
}

test "layout: an inline svg with only a viewBox fills its container's width" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0'><div style='width:24px'><svg id=s viewBox='0 0 24 12'><path d='M0 0h24v12z'/></svg></div><svg id=t width=30 height=10></svg>", 400);
    const doc = l.doc;
    const s = boxOf(l, doc, "#s");
    try std.testing.expectEqual(@as(f64, 24), s.w);
    try std.testing.expectEqual(@as(f64, 12), s.h);
    try std.testing.expectEqual(@as(f64, 30), boxOf(l, doc, "#t").w);
}

test "layout: grid tracks — fixed, fr, auto — with gaps and explicit placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0;font-size:16px;line-height:20px'><div style='display:grid;grid-template-columns:100px 1fr 2fr;column-gap:10px;row-gap:5px'><div id=a>a</div><div id=b>b</div><div id=c>c</div><div id=d style='grid-column:2 / 4'>d</div><div id=e style='grid-row:3;grid-column:1'>e</div></div>", 400);
    const doc = l.doc;
    const ba = boxOf(l, doc, "#a");
    const bb = boxOf(l, doc, "#b");
    const bc = boxOf(l, doc, "#c");
    const bd = boxOf(l, doc, "#d");
    const be = boxOf(l, doc, "#e");
    // 400 - 100 - 20 = 280 for 3fr: 93.33 and 186.67.
    try std.testing.expectEqual(@as(f64, 100), ba.w);
    try std.testing.expectEqual(@as(f64, 110), bb.x);
    try std.testing.expectApproxEqAbs(@as(f64, 280.0 / 3.0), bb.w, 0.01);
    try std.testing.expectApproxEqAbs(@as(f64, 400), bc.x + bc.w, 0.01);
    // The spanning item covers columns 2 and 3 and the gap between.
    try std.testing.expectEqual(@as(f64, 110), bd.x);
    try std.testing.expectApproxEqAbs(@as(f64, 290), bd.w, 0.01);
    try std.testing.expectEqual(ba.y + 20 + 5, bd.y);
    try std.testing.expectEqual(bd.y + 20 + 5, be.y);
}

test "layout: grid areas, auto-fill and auto-placement" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0;font-size:16px;line-height:20px'><div style=\"display:grid;grid-template-columns:120px 1fr;grid-template-areas:'side main' 'foot foot'\"><div id=m style='grid-area:main'>m</div><div id=s style='grid-area:side'>s</div><div id=f style='grid-area:foot'>f</div></div><div style='display:grid;grid-template-columns:repeat(auto-fill, 100px)'><i id=i1>1</i><i id=i2>2</i><i id=i3>3</i><i id=i4>4</i><i id=i5>5</i></div>", 400);
    const doc = l.doc;
    const m = boxOf(l, doc, "#m");
    const s = boxOf(l, doc, "#s");
    const f = boxOf(l, doc, "#f");
    try std.testing.expectEqual(@as(f64, 0), s.x);
    try std.testing.expectEqual(@as(f64, 120), m.x);
    try std.testing.expectEqual(m.y, s.y);
    try std.testing.expectEqual(@as(f64, 400), f.w);
    try std.testing.expect(f.y > m.y);
    // Four 100px columns fit in 400: the fifth item wraps.
    const r1 = boxOf(l, doc, "#i4");
    const r2 = boxOf(l, doc, "#i5");
    try std.testing.expectEqual(@as(f64, 300), r1.x);
    try std.testing.expectEqual(@as(f64, 0), r2.x);
    try std.testing.expect(r2.y > r1.y);
}

// GitHub (2026-09-23): `flex: 1 1 0` was dropped whole for its
// unitless zero, so a `width:100%` item took the line and the sidebar
// wrapped below it.
test "layout: flex 1 1 0 shares the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0'><div style='display:flex;flex-wrap:wrap'><div id=c style='flex:1 1 0;width:100%'>c</div><div id=p style='width:100px'>p</div></div>", 400);
    const doc = l.doc;
    try std.testing.expectEqual(@as(f64, 300), boxOf(l, doc, "#c").w);
    try std.testing.expectEqual(@as(f64, 300), boxOf(l, doc, "#p").x);
}

// GitHub's file names: a `max-width:100%` inline-block measured inside
// a flex item came out 0 wide.
test "layout: a percentage size is auto while intrinsic widths are measured" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0;font-size:16px'><div style='display:flex'><div id=o style='overflow:hidden'><span style='display:inline-block;max-width:100%;white-space:nowrap'>abcdef</span></div></div>", 400);
    try std.testing.expectEqual(@as(f64, 48), boxOf(l, l.doc, "#o").w);
}

test "layout: translate moves a box after layout; logical margins are physical" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0'><div style='position:relative;height:100px'><div id=t style='position:absolute;top:50%;width:20px;height:20px;transform:translateY(-50%) translateX(5px)'></div></div><div id=m style='margin-inline-start:12px;padding-block:3px 4px'></div>", 400);
    const t = boxOf(l, l.doc, "#t");
    try std.testing.expectEqual(@as(f64, 40), t.y);
    try std.testing.expectEqual(@as(f64, 5), t.x);
    const m = boxOf(l, l.doc, "#m");
    try std.testing.expectEqual(@as(f64, 12), m.x);
    try std.testing.expectEqual(@as(f64, 7), m.h);
}

// Lite CNN: `<a>headline </a>` at a line's end underlined the space.
test "layout: a trailing space inside a closing inline box comes off the line" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0;font-size:16px'><div style='width:64px'><a id=a href=x>aaaa </a>bbbbbbbb</div>", 400);
    for (0..l.fragments.len) |fi| {
        const f = l.fragments.get(fi);
        if (f.dead or f.kind != .inline_span) continue;
        // The link's span ends where its text does: 4 cells.
        try std.testing.expectEqual(@as(f64, 32), f.w);
    }
}

// The Python docs' contents: an item whose text is an anonymous block
// before a nested list had no bullet.
test "layout: an item that starts with a block still has its marker" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0;font-size:16px;line-height:20px'><ul style='margin:0;padding-left:40px'><li id=i>text<ul><li>inner</li></ul></li></ul>", 400);
    const li = boxOf(l, l.doc, "#i");
    try std.testing.expectEqual(@as(usize, 1), li.lines.items.len);
    const f = l.fragments.get(li.lines.items[0].first_frag);
    try std.testing.expect(f.kind == .marker);
    try std.testing.expectEqual(li.y, li.lines.items[0].y);
}

// GitHub's narrow layout: `flex: 1 1 0` in an indefinite column made the
// content 0 tall; a flex item's automatic minimum is its content.
test "layout: a column item's automatic minimum height is its content" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const l = try layoutText(a, "<!DOCTYPE html><body style='margin:0;font-size:16px;line-height:20px'><div style='display:flex;flex-direction:column'><div id=c style='flex:1 1 0'><p style='margin:0'>a</p><p style='margin:0'>b</p></div><div id=n style='flex:1 1 0;overflow:hidden'>x</div></div>", 400);
    try std.testing.expectEqual(@as(f64, 40), boxOf(l, l.doc, "#c").h);
    // Not so for one that clips its overflow.
    try std.testing.expectEqual(@as(f64, 0), boxOf(l, l.doc, "#n").h);
}
