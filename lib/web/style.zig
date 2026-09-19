//! The cascade and computed values (CSS Cascading and Inheritance Level
//! 4, CSS Values Level 4, and the properties' own modules): stylesheets
//! parsed into rules with their selectors and longhand declarations
//! (shorthands expanded as they are read), every element's declared
//! values found by matching, the winner per property chosen by origin
//! and importance, then specificity, then order — the `style` attribute
//! after every selector — and the computed value derived from it: `em`
//! and `%` of font sizes resolved, `inherit`/`initial`/`unset` applied,
//! inherited properties flowing down. The properties are the ones a
//! block-and-inline layout and its painter need; a property this file
//! does not know is kept nowhere. The user-agent sheet is the HTML
//! Standard's rendering section, trimmed to those properties.
//!
//! Not built: `calc()` and the other math functions (a declaration
//! with one is dropped), `@import` (recorded, not fetched), `@supports`
//! beyond a property check, the user origin, `revert`, and animations.
const std = @import("std");
const css = @import("css.zig");
const color = @import("color.zig");
const media = @import("media.zig");
const selectors = @import("selectors.zig");
const dom = @import("dom.zig");

pub const Error = error{OutOfMemory};
const Color = color.Color;
const Document = dom.Document;
const NodeId = dom.NodeId;

// ------------------------------------------------------------ values

/// A length that may wait for layout (a percentage of the containing
/// block) or is already in pixels.
pub const LengthPercent = union(enum) {
    px: f64,
    percent: f64,

    pub fn zero() LengthPercent {
        return .{ .px = 0 };
    }
};

/// `auto` beside a length or percentage.
pub const LengthAuto = union(enum) { px: f64, percent: f64, auto };
/// `none` beside a length or percentage (max sizes).
pub const LengthNone = union(enum) { px: f64, percent: f64, none };

pub const Display = enum { @"inline", block, inline_block, list_item, none, contents, flex, inline_flex, grid, inline_grid, table, inline_table, table_row, table_cell, table_row_group, table_header_group, table_footer_group, table_caption, table_column, table_column_group, flow_root };
pub const Position = enum { static, relative, absolute, fixed, sticky };
// Flexbox (Level 1). `start`/`end` are taken as the flex ones; `left`/
// `right`/`normal` are not (a declaration using them is dropped, so the
// initial value stands, which is what those resolve to in a row anyway).
pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const JustifyContent = enum { flex_start, flex_end, center, space_between, space_around, space_evenly, start, end };
pub const AlignItems = enum { stretch, flex_start, flex_end, center, baseline, start, end, self_start, self_end };
pub const AlignSelf = enum { auto, stretch, flex_start, flex_end, center, baseline, start, end, self_start, self_end };
pub const AlignContent = enum { stretch, flex_start, flex_end, center, space_between, space_around, space_evenly, start, end };
pub const Float = enum { none, left, right };
pub const Clear = enum { none, left, right, both };
pub const BorderStyle = enum { none, hidden, solid, dashed, dotted, double, groove, ridge, inset, outset };
pub const FontStyle = enum { normal, italic, oblique };
pub const TextAlign = enum { left, right, center, justify, start, end };
pub const TextTransform = enum { none, uppercase, lowercase, capitalize };
pub const WhiteSpace = enum { normal, nowrap, pre, pre_wrap, pre_line, break_spaces };
pub const ListStyleType = enum { disc, circle, square, decimal, lower_alpha, upper_alpha, lower_roman, upper_roman, none };
pub const ListStylePosition = enum { inside, outside };
pub const Overflow = enum { visible, hidden, scroll, auto, clip };
pub const Visibility = enum { visible, hidden, collapse };
pub const BoxSizing = enum { content_box, border_box };
pub const VerticalAlign = union(enum) { baseline, top, middle, bottom, sub, super, text_top, text_bottom, length: LengthPercent };
pub const LineHeight = union(enum) { normal, number: f64, px: f64 };

pub const Decoration = packed struct { underline: bool = false, overline: bool = false, line_through: bool = false, _pad: u5 = 0 };

/// A font family list: names as written (generic families as idents).
pub const FontFamily = []const []const u8;

/// Every element's computed style. Inherited properties are marked in
/// `inherited`; the rest take their initial value unless declared.
pub const Computed = struct {
    display: Display = .@"inline",
    position: Position = .static,
    float: Float = .none,
    clear: Clear = .none,
    width: LengthAuto = .auto,
    height: LengthAuto = .auto,
    min_width: LengthPercent = .{ .px = 0 },
    min_height: LengthPercent = .{ .px = 0 },
    max_width: LengthNone = .none,
    max_height: LengthNone = .none,
    margin: [4]LengthAuto = .{ .{ .px = 0 }, .{ .px = 0 }, .{ .px = 0 }, .{ .px = 0 } },
    padding: [4]LengthPercent = .{ .{ .px = 0 }, .{ .px = 0 }, .{ .px = 0 }, .{ .px = 0 } },
    border_width: [4]f64 = .{ 3, 3, 3, 3 },
    border_style: [4]BorderStyle = .{ .none, .none, .none, .none },
    border_color: [4]?Color = .{ null, null, null, null }, // null: currentcolor
    inset: [4]LengthAuto = .{ .auto, .auto, .auto, .auto }, // top right bottom left
    color: Color = Color.rgb(0, 0, 0),
    background_color: Color = Color.transparent,
    font_size: f64 = 16,
    font_weight: u16 = 400,
    font_style: FontStyle = .normal,
    font_family: FontFamily = &.{"sans-serif"},
    line_height: LineHeight = .normal,
    text_align: TextAlign = .start,
    text_decoration: Decoration = .{},
    text_indent: LengthPercent = .{ .px = 0 },
    text_transform: TextTransform = .none,
    white_space: WhiteSpace = .normal,
    vertical_align: VerticalAlign = .baseline,
    list_style_type: ListStyleType = .disc,
    list_style_position: ListStylePosition = .outside,
    overflow_x: Overflow = .visible,
    overflow_y: Overflow = .visible,
    visibility: Visibility = .visible,
    opacity: f64 = 1,
    box_sizing: BoxSizing = .content_box,
    z_index: ?i32 = null,
    flex_direction: FlexDirection = .row,
    flex_wrap: FlexWrap = .nowrap,
    justify_content: JustifyContent = .flex_start,
    align_items: AlignItems = .stretch,
    align_self: AlignSelf = .auto,
    align_content: AlignContent = .stretch,
    flex_grow: f64 = 0,
    flex_shrink: f64 = 1,
    /// `auto` defers to the main size property; `content` is auto here.
    flex_basis: LengthAuto = .auto,
    order: i32 = 0,
    row_gap: LengthPercent = .{ .px = 0 },
    column_gap: LengthPercent = .{ .px = 0 },

    /// The four sides' order everywhere: top, right, bottom, left.
    pub const top = 0;
    pub const right = 1;
    pub const bottom = 2;
    pub const left = 3;

    /// A border's used width: zero unless its style draws.
    pub fn borderWidth(c: *const Computed, side: usize) f64 {
        return switch (c.border_style[side]) {
            .none, .hidden => 0,
            else => c.border_width[side],
        };
    }

    pub fn borderColor(c: *const Computed, side: usize) Color {
        return c.border_color[side] orelse c.color;
    }

    /// The line height in pixels (`normal` is 1.2 of the font size).
    pub fn lineHeightPx(c: *const Computed) f64 {
        return switch (c.line_height) {
            .normal => c.font_size * 1.2,
            .number => |n| c.font_size * n,
            .px => |p| p,
        };
    }
};

/// The longhand properties this cascade knows, by name.
pub const Prop = enum {
    display,
    position,
    float,
    clear,
    width,
    height,
    min_width,
    min_height,
    max_width,
    max_height,
    margin_top,
    margin_right,
    margin_bottom,
    margin_left,
    padding_top,
    padding_right,
    padding_bottom,
    padding_left,
    border_top_width,
    border_right_width,
    border_bottom_width,
    border_left_width,
    border_top_style,
    border_right_style,
    border_bottom_style,
    border_left_style,
    border_top_color,
    border_right_color,
    border_bottom_color,
    border_left_color,
    top,
    right,
    bottom,
    left,
    color,
    background_color,
    font_size,
    font_weight,
    font_style,
    font_family,
    line_height,
    text_align,
    text_decoration_line,
    text_indent,
    text_transform,
    white_space,
    vertical_align,
    list_style_type,
    list_style_position,
    overflow_x,
    overflow_y,
    visibility,
    opacity,
    box_sizing,
    z_index,
    flex_direction,
    flex_wrap,
    justify_content,
    align_items,
    align_self,
    align_content,
    flex_grow,
    flex_shrink,
    flex_basis,
    order,
    row_gap,
    column_gap,

    pub fn inherited(p: Prop) bool {
        return switch (p) {
            .color, .font_size, .font_weight, .font_style, .font_family, .line_height, .text_align, .text_indent, .text_transform, .white_space, .list_style_type, .list_style_position, .visibility => true,
            else => false,
        };
    }

    pub fn parse(name: []const u8) ?Prop {
        const eq = std.ascii.eqlIgnoreCase;
        inline for (@typeInfo(Prop).@"enum".fields) |f| {
            // Enum names use underscores where CSS uses hyphens.
            var buf: [32]u8 = undefined;
            if (f.name.len <= buf.len) {
                for (f.name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
                if (eq(buf[0..f.name.len], name)) return @enumFromInt(f.value);
            }
        }
        return null;
    }
};

// --------------------------------------------------------- declarations

/// A declared value: the CSS-wide keywords, or component values to be
/// parsed for the property when the cascade picks them.
pub const Declared = union(enum) {
    inherit,
    initial,
    unset,
    values: []const css.Value,
};

pub const Declaration = struct {
    prop: Prop,
    value: Declared,
    important: bool,
};

pub const Origin = enum(u8) { user_agent = 0, author = 1 };

pub const Rule = struct {
    /// One complex selector; a list becomes several rules sharing
    /// declarations, so each carries its own specificity.
    selector: selectors.Complex,
    specificity: u32,
    declarations: []const Declaration,
};

/// An `@font-face` rule: the family it declares and the first `src`
/// URL (a `local()` source is skipped), for a page to fetch and add
/// to its faces. Weight and style are not matched yet: the first face
/// declared for a family serves every variant.
pub const FontFace = struct {
    family: []const u8,
    src: []const u8,
    /// The URL of the sheet that declared it, when the sheet was
    /// fetched: `src` resolves against it, not the page.
    base: ?[]const u8 = null,
};

pub const Sheet = struct {
    origin: Origin,
    rules: []const Rule,
    /// `@import` URLs seen, for a loader to fetch and prepend.
    imports: []const []const u8,
    /// `@font-face` rules seen, in order.
    font_faces: []const FontFace = &.{},
    /// The sheet's own URL when it was fetched (a `<link>` or an
    /// `@import`); null for a `<style>` block, whose base is the page.
    base: ?[]const u8 = null,
};

/// A deep copy of a sheet into `a`: parse a sheet through a scratch
/// arena — its tokens, blocks and re-flattened token lists are ten
/// times the rules that come out (Wikipedia's 198 KB bundle held
/// 13 MB live, 2026-09-18) — and keep only this in the document's.
pub fn cloneSheet(a: std.mem.Allocator, sheet: Sheet) Error!Sheet {
    const rules = try a.alloc(Rule, sheet.rules.len);
    for (sheet.rules, 0..) |r, i| {
        const decls = try a.alloc(Declaration, r.declarations.len);
        for (r.declarations, 0..) |d, j| decls[j] = .{ .prop = d.prop, .important = d.important, .value = switch (d.value) {
            .values => |v| .{ .values = try css.cloneValues(a, v) },
            else => d.value,
        } };
        rules[i] = .{ .selector = try selectors.cloneComplex(a, r.selector), .specificity = r.specificity, .declarations = decls };
    }
    const imports = try a.alloc([]const u8, sheet.imports.len);
    for (sheet.imports, 0..) |u, i| imports[i] = try a.dupe(u8, u);
    const faces = try a.alloc(FontFace, sheet.font_faces.len);
    for (sheet.font_faces, 0..) |f, i| faces[i] = .{ .family = try a.dupe(u8, f.family), .src = try a.dupe(u8, f.src), .base = if (f.base) |b| try a.dupe(u8, b) else null };
    return .{ .origin = sheet.origin, .rules = rules, .imports = imports, .font_faces = faces, .base = if (sheet.base) |b| try a.dupe(u8, b) else null };
}

test "style: a cloned sheet outlives the arena it was parsed in" {
    var keep = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer keep.deinit();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    var cloned: Sheet = undefined;
    {
        var scratch = std.heap.ArenaAllocator.init(std.testing.allocator);
        defer scratch.deinit();
        const parsed = try parseSheetAt(scratch.allocator(), "@import \"x.css\"; @font-face { font-family: F; src: url(f.woff) } p.a > b[x=\"y\"]:not(.z) { color: rgb(1, 2, 3); margin: 4px 0 !important } @media (min-width: 10px) { i { color: red } }", .author, env, "http://h/s.css");
        cloned = try cloneSheet(keep.allocator(), parsed);
    }
    // The scratch is gone; everything the clone holds is its own.
    try std.testing.expectEqual(@as(usize, 2), cloned.rules.len);
    try std.testing.expectEqualStrings("http://h/s.css", cloned.base.?);
    try std.testing.expectEqualStrings("x.css", cloned.imports[0]);
    try std.testing.expectEqualStrings("f.woff", cloned.font_faces[0].src);
    try std.testing.expectEqual(@as(usize, 2), cloned.rules[0].selector.compounds.len);
    const decl = cloned.rules[0].declarations[0];
    try std.testing.expect(decl.value == .values);
    const doc = try html.parse(keep.allocator(), "<p class=a><b x=y>t</b></p>", .{});
    const styles = try compute(keep.allocator(), doc, &.{cloned}, env);
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "b")) {
        const c = styles.get(id).color;
        try std.testing.expect(c.r == 1 and c.g == 2 and c.b == 3);
    };
}

/// What fetches a linked sheet for the cascade: given an `href` and the
/// URL it is relative to (the page's, or the importing sheet's), the
/// sheet's text and its resolved URL, or null when it cannot be had.
/// The library stays pure; a page hands one in that goes through its
/// broker, `web-render` one that goes through the shell's network.
pub const Loader = struct {
    ctx: *anyopaque,
    fetch: *const fn (ctx: *anyopaque, href: []const u8, base: ?[]const u8) ?Loaded,
    pub const Loaded = struct { text: []const u8, url: []const u8 };
};

/// How deep `@import` chains go before they are left unread.
const max_import_depth = 3;

/// What keeps a parsed sheet: given the sheet as the scratch holds it,
/// the sheet as the caller will hold it (a deep copy into the document's
/// arena), after which the caller may reset the scratch — a parent
/// sheet is kept before its imports are parsed, so a reset between
/// sheets is safe. The sheet list itself is allocated from `a`.
pub const Keep = struct {
    ctx: *anyopaque,
    a: std.mem.Allocator,
    keep: *const fn (ctx: *anyopaque, sheet: Sheet) Error!Sheet,
};

pub const Env = media.Env;

/// Parse a stylesheet's text into rules for `env`: `@media` blocks that
/// match are flattened in, those that do not are dropped, `@import`s
/// recorded, other at-rules ignored.
pub fn parseSheet(a: std.mem.Allocator, text: []const u8, origin: Origin, env: Env) Error!Sheet {
    return parseSheetAt(a, text, origin, env, null);
}

/// The same for a sheet fetched from `base`: it and its font faces
/// remember the URL their `url()`s resolve against.
pub fn parseSheetAt(a: std.mem.Allocator, text: []const u8, origin: Origin, env: Env, base: ?[]const u8) Error!Sheet {
    var p = try css.Parser.init(a, text, false);
    const rules = try p.parseStylesheetDirect();
    var out: std.ArrayList(Rule) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    var faces: std.ArrayList(FontFace) = .empty;
    // The per-block parsers below share the sheet parser's value stack.
    try collectRulesFaces(a, rules, env, &out, &imports, &faces, p.scratchOf());
    if (base != null) for (faces.items) |*f| {
        f.base = base;
    };
    return .{ .origin = origin, .rules = out.items, .imports = imports.items, .font_faces = faces.items, .base = base };
}

/// A sheet's `@import`s fetched and appended before it (an imported
/// sheet's rules come first, as the cascade orders them), then the
/// sheet itself; a chain deeper than `max_import_depth` or a fetch that
/// fails leaves that import out, never the sheet.
fn appendSheetWithImports(a: std.mem.Allocator, sheets: *std.ArrayList(Sheet), parsed: Sheet, env: Env, loader: ?Loader, keep: ?Keep, depth: usize) Error!void {
    const sheet = if (keep) |k| try k.keep(k.ctx, parsed) else parsed;
    const list_a = if (keep) |k| k.a else a;
    if (loader) |ld| if (depth < max_import_depth) for (sheet.imports) |href| {
        const got = ld.fetch(ld.ctx, href, sheet.base) orelse continue;
        const imported = try parseSheetAt(a, got.text, sheet.origin, env, got.url);
        try appendSheetWithImports(a, sheets, imported, env, loader, keep, depth + 1);
    };
    try sheets.append(list_a, sheet);
}

/// Whether a `<link>`'s `rel` names a stylesheet that applies: the
/// token list holds `stylesheet`, not `alternate`; case does not matter.
fn linkIsStylesheet(rel: []const u8) bool {
    var has = false;
    var it = std.mem.tokenizeAny(u8, rel, " \t\n\r\x0c");
    while (it.next()) |tok| {
        if (std.ascii.eqlIgnoreCase(tok, "stylesheet")) has = true;
        if (std.ascii.eqlIgnoreCase(tok, "alternate")) return false;
    }
    return has;
}

fn collectRules(a: std.mem.Allocator, rules: []const css.Rule, env: Env, out: *std.ArrayList(Rule), imports: *std.ArrayList([]const u8)) Error!void {
    var faces: std.ArrayList(FontFace) = .empty;
    var scratch: css.Scratch = .empty;
    try collectRulesFaces(a, rules, env, out, imports, &faces, &scratch);
}

/// An `@font-face` block's descriptors: the family and the first
/// `url()` in `src`.
fn fontFaceOf(a: std.mem.Allocator, block: []const css.Value, scratch: *css.Scratch) Error!?FontFace {
    var p = try css.Parser.fromValuesScratch(a, block, scratch);
    return fontFaceOfItems(try p.parseListOfDeclarations());
}

fn fontFaceOfItems(items: []const css.Item) Error!?FontFace {
    var family: ?[]const u8 = null;
    var src: ?[]const u8 = null;
    for (items) |item| {
        if (item != .declaration) continue;
        const d = item.declaration;
        if (std.ascii.eqlIgnoreCase(d.name, "font-family")) {
            for (d.value) |v| {
                if (v == .token and v.token == .string) family = v.token.string;
                if (v == .token and v.token == .ident and family == null) family = v.token.ident;
            }
        } else if (std.ascii.eqlIgnoreCase(d.name, "src")) {
            for (d.value) |v| {
                if (src != null) break;
                if (v == .token and v.token == .url) src = v.token.url;
                if (v == .function and std.ascii.eqlIgnoreCase(v.function.name, "url")) for (v.function.values) |x| if (x == .token and x.token == .string) {
                    src = x.token.string;
                };
            }
        }
    }
    if (family == null or src == null) return null;
    return .{ .family = family.?, .src = src.? };
}

fn collectRulesFaces(a: std.mem.Allocator, rules: []const css.Rule, env: Env, out: *std.ArrayList(Rule), imports: *std.ArrayList([]const u8), faces: *std.ArrayList(FontFace), scratch: *css.Scratch) Error!void {
    for (rules) |r| switch (r) {
        .err => {},
        .qualified => |q| if (q.items) |items| try addQualifiedItems(a, q.prelude, items, out) else try addQualified(a, q, out, scratch),
        .at => |at| {
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(at.name, "media")) {
                const q = try media.Query.parseValues(a, at.prelude);
                if (!q.matches(env)) continue;
                if (at.rules) |rs| {
                    try collectRulesFaces(a, rs, env, out, imports, faces, scratch);
                    continue;
                }
                const block = at.block orelse continue;
                try collectRulesFaces(a, try rulesOfBlock(a, block, scratch), env, out, imports, faces, scratch);
            } else if (eq(at.name, "font-face")) {
                if (at.items) |items| {
                    if (try fontFaceOfItems(items)) |f| try faces.append(a, f);
                    continue;
                }
                const block = at.block orelse continue;
                if (try fontFaceOf(a, block, scratch)) |f| try faces.append(a, f);
            } else if (eq(at.name, "import")) {
                for (at.prelude) |v| {
                    if (v == .token and v.token == .string) try imports.append(a, v.token.string);
                    if (v == .token and v.token == .url) try imports.append(a, v.token.url);
                    if (v == .function and eq(v.function.name, "url")) for (v.function.values) |x| if (x == .token and x.token == .string) try imports.append(a, x.token.string);
                }
            } else if (eq(at.name, "supports")) {
                if (!supportsMatches(a, at.prelude)) continue;
                if (at.rules) |rs| {
                    try collectRulesFaces(a, rs, env, out, imports, faces, scratch);
                    continue;
                }
                const block = at.block orelse continue;
                try collectRulesFaces(a, try rulesOfBlock(a, block, scratch), env, out, imports, faces, scratch);
            }
        },
    };
}

/// The rules inside a block's component values, parsed as a list of
/// rules from the values themselves.
fn rulesOfBlock(a: std.mem.Allocator, block: []const css.Value, scratch: *css.Scratch) Error![]const css.Rule {
    var p = try css.Parser.fromValuesScratch(a, block, scratch);
    return p.parseListOfRules();
}

/// `@supports (prop: value)`: true when the property is one this file
/// knows and the value parses for it; `not`, `and`, `or` over blocks.
fn supportsMatches(a: std.mem.Allocator, prelude: []const css.Value) bool {
    var result: ?bool = null;
    var negate = false;
    var op: enum { none, and_, or_ } = .none;
    for (prelude) |v| {
        if (v == .token and v.token == .whitespace) continue;
        if (v == .token and v.token == .ident) {
            const w = v.token.ident;
            if (std.ascii.eqlIgnoreCase(w, "not")) negate = true else if (std.ascii.eqlIgnoreCase(w, "and")) op = .and_ else if (std.ascii.eqlIgnoreCase(w, "or")) op = .or_;
            continue;
        }
        if (v != .block or v.block.kind != '(') return false;
        var term = supportsBlock(a, v.block.values);
        if (negate) term = !term;
        negate = false;
        result = if (result) |r| switch (op) {
            .and_ => r and term,
            .or_ => r or term,
            .none => term,
        } else term;
    }
    return result orelse false;
}

fn supportsBlock(a: std.mem.Allocator, values: []const css.Value) bool {
    // Either a nested condition or `name: value`.
    var i: usize = 0;
    while (i < values.len and values[i] == .token and values[i].token == .whitespace) i += 1;
    if (i < values.len and values[i] == .block) return supportsMatches(a, values);
    if (i >= values.len or values[i] != .token or values[i].token != .ident) return false;
    const prop = Prop.parse(values[i].token.ident) orelse return false;
    i += 1;
    while (i < values.len and values[i] == .token and values[i].token == .whitespace) i += 1;
    if (i >= values.len or values[i] != .token or values[i].token != .colon) return false;
    var scratch: Computed = .{};
    return applyValues(&scratch, prop, values[i + 1 ..], &scratch, 16, .{ .width = 0, .height = 0 }, a) catch false;
}

fn addQualified(a: std.mem.Allocator, q: css.QualifiedRule, out: *std.ArrayList(Rule), scratch: *css.Scratch) Error!void {
    var bp = try css.Parser.fromValuesScratch(a, q.block, scratch);
    try addQualifiedItems(a, q.prelude, try bp.parseBlockContents(), out);
}

/// A qualified rule from its prelude and its parsed body.
fn addQualifiedItems(a: std.mem.Allocator, prelude: []const css.Value, items: []const css.Item, out: *std.ArrayList(Rule)) Error!void {
    const sel_text = try css.valuesText(a, prelude);
    const sel = selectors.Selector.parse(a, sel_text) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Invalid => return, // a selector list with an unknown part drops the rule
    };
    var decls: std.ArrayList(Declaration) = .empty;
    for (items) |item| if (item == .declaration) try expand(a, item.declaration, &decls);
    if (decls.items.len == 0) return;
    for (sel.list) |complex| try out.append(a, .{ .selector = complex, .specificity = selectors.specificity(complex), .declarations = decls.items });
}

/// Parse a `style` attribute's declarations.
pub fn parseInline(a: std.mem.Allocator, text: []const u8) Error![]const Declaration {
    var p = try css.Parser.init(a, text, false);
    const items = try p.parseBlockContents();
    var decls: std.ArrayList(Declaration) = .empty;
    for (items) |item| if (item == .declaration) try expand(a, item.declaration, &decls);
    return decls.items;
}

fn isWs(v: css.Value) bool {
    return v == .token and v.token == .whitespace;
}

fn nonWs(a: std.mem.Allocator, values: []const css.Value) Error![]const css.Value {
    var out: std.ArrayList(css.Value) = .empty;
    for (values) |v| if (!isWs(v)) try out.append(a, v);
    return out.items;
}

fn wideKeyword(values: []const css.Value) ?Declared {
    if (values.len != 1 or values[0] != .token or values[0].token != .ident) return null;
    const w = values[0].token.ident;
    if (std.ascii.eqlIgnoreCase(w, "inherit")) return .inherit;
    if (std.ascii.eqlIgnoreCase(w, "initial")) return .initial;
    if (std.ascii.eqlIgnoreCase(w, "unset") or std.ascii.eqlIgnoreCase(w, "revert")) return .unset;
    return null;
}

fn push(a: std.mem.Allocator, decls: *std.ArrayList(Declaration), prop: Prop, values: []const css.Value, important: bool) Error!void {
    if (wideKeyword(values)) |w| return decls.append(a, .{ .prop = prop, .value = w, .important = important });
    // A value that does not parse for its property is dropped here, at
    // parse time, so it never shadows a lesser rule in the cascade. The
    // trial applies into a throwaway: what it allocates (a family list,
    // a formatted string) is garbage the sheet's arena must not keep —
    // 2.4 KB a declaration over Wikipedia's bundle (2026-09-18). A trial
    // too big for the throwaway is taken as valid.
    var scratch: Computed = .{};
    var trial_mem: [4096]u8 = undefined;
    var trial = std.heap.FixedBufferAllocator.init(&trial_mem);
    _ = applyValues(&scratch, prop, values, &scratch, 16, .{ .width = 0, .height = 0 }, trial.allocator()) catch |e| switch (e) {
        error.OutOfMemory => {},
        error.Invalid => return,
    };
    try decls.append(a, .{ .prop = prop, .value = .{ .values = values }, .important = important });
}

/// One declaration into its longhands.
fn expand(a: std.mem.Allocator, d: css.Declaration, decls: *std.ArrayList(Declaration)) Error!void {
    const eq = std.ascii.eqlIgnoreCase;
    const name = d.name;
    const vals = try nonWs(a, d.value);
    if (vals.len == 0) return;
    if (Prop.parse(name)) |p| return push(a, decls, p, vals, d.important);
    const wide = wideKeyword(vals) != null;
    const sides = [_][4]Prop{
        .{ .margin_top, .margin_right, .margin_bottom, .margin_left },
        .{ .padding_top, .padding_right, .padding_bottom, .padding_left },
        .{ .border_top_width, .border_right_width, .border_bottom_width, .border_left_width },
        .{ .border_top_style, .border_right_style, .border_bottom_style, .border_left_style },
        .{ .border_top_color, .border_right_color, .border_bottom_color, .border_left_color },
        .{ .top, .right, .bottom, .left },
    };
    const four = [_][]const u8{ "margin", "padding", "border-width", "border-style", "border-color", "inset" };
    for (four, 0..) |n, i| if (eq(name, n)) {
        if (wide) {
            for (sides[i]) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        if (vals.len == 0 or vals.len > 4) return;
        const idx = [_][4]usize{ .{ 0, 0, 0, 0 }, .{ 0, 1, 0, 1 }, .{ 0, 1, 2, 1 }, .{ 0, 1, 2, 3 } };
        for (sides[i], 0..) |p, side| try push(a, decls, p, vals[idx[vals.len - 1][side] .. idx[vals.len - 1][side] + 1], d.important);
        return;
    };
    const one_side = [_]struct { n: []const u8, side: usize }{ .{ .n = "border-top", .side = 0 }, .{ .n = "border-right", .side = 1 }, .{ .n = "border-bottom", .side = 2 }, .{ .n = "border-left", .side = 3 } };
    if (eq(name, "border")) {
        try expandBorder(a, vals, &.{ 0, 1, 2, 3 }, d.important, decls);
        return;
    }
    for (one_side) |os| if (eq(name, os.n)) {
        try expandBorder(a, vals, &.{os.side}, d.important, decls);
        return;
    };
    if (eq(name, "background")) {
        // Only the colour is kept: the last value that parses as one.
        var i = vals.len;
        while (i > 0) {
            i -= 1;
            if (color.parseValue(vals[i]) != null) return push(a, decls, .background_color, vals[i .. i + 1], d.important);
        }
        if (wide) return push(a, decls, .background_color, vals, d.important);
        return push(a, decls, .background_color, &.{}, d.important);
    }
    if (eq(name, "overflow")) {
        if (vals.len > 2) return;
        try push(a, decls, .overflow_x, vals[0..1], d.important);
        try push(a, decls, .overflow_y, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    }
    if (eq(name, "text-decoration")) {
        // The line keywords, whatever else is there.
        for (vals) |v| if (v == .token and v.token == .ident) {
            const w = v.token.ident;
            if (eq(w, "underline") or eq(w, "overline") or eq(w, "line-through") or eq(w, "none")) return push(a, decls, .text_decoration_line, vals, d.important);
        };
        return;
    }
    if (eq(name, "list-style")) {
        if (wide) {
            try push(a, decls, .list_style_type, vals, d.important);
            try push(a, decls, .list_style_position, vals, d.important);
            return;
        }
        for (vals) |v| if (v == .token and v.token == .ident) {
            const w = v.token.ident;
            // `single`: a value list the cascade keeps must be the arena's,
            // never a pointer to a temporary (Wikipedia's bundle read a
            // dead frame through one, 2026-09-18).
            if (eq(w, "inside") or eq(w, "outside")) try push(a, decls, .list_style_position, try single(a, v), d.important) else try push(a, decls, .list_style_type, try single(a, v), d.important);
        };
        return;
    }
    if (eq(name, "font")) return expandFont(a, vals, d.important, decls);
    if (eq(name, "flex")) {
        // none | [ <grow> <shrink>? || <basis> ]; `flex: 1` is 1 1 0.
        if (wide) {
            try push(a, decls, .flex_grow, vals, d.important);
            try push(a, decls, .flex_shrink, vals, d.important);
            try push(a, decls, .flex_basis, vals, d.important);
            return;
        }
        var grow: ?f64 = null;
        var shrink: ?f64 = null;
        var basis: ?css.Value = null;
        for (vals) |v| {
            if (ident(v)) |w| {
                if (eq(w, "none")) {
                    grow = 0;
                    shrink = 0;
                    basis = v; // `auto`, below
                    basis = .{ .token = .{ .ident = "auto" } };
                    continue;
                }
                if (eq(w, "auto") or eq(w, "content")) {
                    if (grow == null) grow = 1;
                    if (shrink == null) shrink = 1;
                    basis = v;
                    continue;
                }
                return;
            }
            if (v == .token and v.token == .number) {
                if (grow == null) grow = v.token.number.value else if (shrink == null) shrink = v.token.number.value else return;
                continue;
            }
            if (v == .token and (v.token == .dimension or v.token == .percentage)) {
                basis = v;
                continue;
            }
            return;
        }
        var nb: [24]u8 = undefined;
        const g = grow orelse 1;
        const sh = shrink orelse 1;
        const gt = std.fmt.bufPrint(&nb, "{d}", .{g}) catch return;
        try push(a, decls, .flex_grow, try single(a, .{ .token = .{ .number = .{ .repr = try a.dupe(u8, gt), .value = g, .integer = g == @trunc(g) } } }), d.important);
        var sb: [24]u8 = undefined;
        const st = std.fmt.bufPrint(&sb, "{d}", .{sh}) catch return;
        try push(a, decls, .flex_shrink, try single(a, .{ .token = .{ .number = .{ .repr = try a.dupe(u8, st), .value = sh, .integer = sh == @trunc(sh) } } }), d.important);
        // A flex with a number and no basis flexes from zero.
        const b: css.Value = basis orelse .{ .token = .{ .dimension = .{ .num = .{ .repr = "0", .value = 0, .integer = true }, .unit = "px" } } };
        try push(a, decls, .flex_basis, try single(a, b), d.important);
        return;
    }
    if (eq(name, "flex-flow")) {
        for (vals) |v| {
            if (keyword(FlexDirection, v) != null) try push(a, decls, .flex_direction, try single(a, v), d.important) else if (keyword(FlexWrap, v) != null) try push(a, decls, .flex_wrap, try single(a, v), d.important) else return;
        }
        return;
    }
    if (eq(name, "gap")) {
        if (vals.len == 0 or vals.len > 2) return;
        try push(a, decls, .row_gap, vals[0..1], d.important);
        try push(a, decls, .column_gap, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    }
}

fn single(a: std.mem.Allocator, v: css.Value) Error![]const css.Value {
    const out = try a.alloc(css.Value, 1);
    out[0] = v;
    return out;
}

fn expandBorder(a: std.mem.Allocator, vals: []const css.Value, which: []const usize, important: bool, decls: *std.ArrayList(Declaration)) Error!void {
    const widths = [_]Prop{ .border_top_width, .border_right_width, .border_bottom_width, .border_left_width };
    const styles = [_]Prop{ .border_top_style, .border_right_style, .border_bottom_style, .border_left_style };
    const colors = [_]Prop{ .border_top_color, .border_right_color, .border_bottom_color, .border_left_color };
    if (wideKeyword(vals) != null) {
        for (which) |s| {
            try push(a, decls, widths[s], vals, important);
            try push(a, decls, styles[s], vals, important);
            try push(a, decls, colors[s], vals, important);
        }
        return;
    }
    // Each value is a width, a style or a colour; a shorthand resets
    // what it does not mention.
    var width: ?css.Value = null;
    var style: ?css.Value = null;
    var col: ?css.Value = null;
    for (vals) |v| {
        if (borderStyleOf(v) != null) {
            style = v;
        } else if (color.parseValue(v) != null) {
            col = v;
        } else if (borderWidthOf(v, 16, .{ .width = 0, .height = 0 }) != null) {
            width = v;
        } else return;
    }
    for (which) |s| {
        try push(a, decls, widths[s], if (width) |w| try single(a, w) else &.{}, important);
        try push(a, decls, styles[s], if (style) |st| try single(a, st) else &.{}, important);
        try push(a, decls, colors[s], if (col) |c| try single(a, c) else &.{}, important);
    }
}

/// `font: [style] [weight] size[/line-height] family`.
fn expandFont(a: std.mem.Allocator, vals: []const css.Value, important: bool, decls: *std.ArrayList(Declaration)) Error!void {
    if (wideKeyword(vals) != null) {
        for ([_]Prop{ .font_style, .font_weight, .font_size, .line_height, .font_family }) |p| try push(a, decls, p, vals, important);
        return;
    }
    var i: usize = 0;
    var style: []const css.Value = &.{};
    var weight: []const css.Value = &.{};
    while (i < vals.len) : (i += 1) {
        const v = vals[i];
        if (v != .token) break;
        if (v.token == .ident) {
            const w = v.token.ident;
            if (std.ascii.eqlIgnoreCase(w, "italic") or std.ascii.eqlIgnoreCase(w, "oblique")) {
                style = vals[i .. i + 1];
                continue;
            }
            if (std.ascii.eqlIgnoreCase(w, "bold") or std.ascii.eqlIgnoreCase(w, "bolder") or std.ascii.eqlIgnoreCase(w, "lighter")) {
                weight = vals[i .. i + 1];
                continue;
            }
            if (std.ascii.eqlIgnoreCase(w, "normal")) continue;
        }
        if (v.token == .number and v.token.number.value >= 100 and v.token.number.value <= 900) {
            weight = vals[i .. i + 1];
            continue;
        }
        break;
    }
    if (i >= vals.len) return;
    // The size, then maybe `/` line-height, then the family (the rest).
    const size = vals[i .. i + 1];
    i += 1;
    var lh: []const css.Value = &.{};
    if (i + 1 < vals.len and vals[i] == .token and vals[i].token == .delim and vals[i].token.delim == '/') {
        lh = vals[i + 1 .. i + 2];
        i += 2;
    }
    if (i >= vals.len) return;
    const family = vals[i..];
    try push(a, decls, .font_style, style, important);
    try push(a, decls, .font_weight, weight, important);
    try push(a, decls, .font_size, size, important);
    try push(a, decls, .line_height, lh, important);
    try push(a, decls, .font_family, family, important);
}

// ------------------------------------------------------------ the cascade

/// Every element's computed style, by node id (non-elements get the
/// default).
pub const Styles = struct {
    computed: []Computed,

    pub fn get(s: *const Styles, id: NodeId) *const Computed {
        return &s.computed[id];
    }
};

const Candidate = struct {
    decl: Declaration,
    origin: Origin,
    specificity: u32,
    order: u32,

    /// Higher wins: importance and origin first, then specificity, then
    /// order.
    fn rank(c: Candidate) u64 {
        const tier: u64 = if (c.decl.important) (if (c.origin == .user_agent) 3 else 2) else (if (c.origin == .author) 1 else 0);
        return (tier << 62) | (@as(u64, c.specificity) << 32) | c.order;
    }
};

/// Compute the whole document's styles from the sheets (the user-agent
/// sheet first), with `style` attributes as the last author rules.
pub fn compute(a: std.mem.Allocator, doc: *const Document, sheets: []const Sheet, env: Env) Error!Styles {
    const computed = try a.alloc(Computed, doc.nodes.items.len);
    for (computed) |*c| c.* = .{};
    computed[dom.document_id].color = env_text;
    var winners: [@typeInfo(Prop).@"enum".fields.len]?Candidate = undefined;
    var order: u32 = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| {
        const parent_id = doc.get(id).parent orelse dom.document_id;
        const parent = &computed[parent_id];
        @memset(&winners, null);
        order = 0;
        for (sheets) |sheet| for (sheet.rules) |rule| {
            if (!selectors.Selector.matchesOne(doc, id, rule.selector)) continue;
            for (rule.declarations) |d| {
                order += 1;
                const cand: Candidate = .{ .decl = d, .origin = sheet.origin, .specificity = rule.specificity, .order = order };
                const slot = &winners[@intFromEnum(d.prop)];
                if (slot.* == null or cand.rank() > slot.*.?.rank()) slot.* = cand;
            }
        };
        if (doc.getAttr(id, "style")) |text| {
            const decls = try parseInline(a, text);
            for (decls) |d| {
                order += 1;
                const cand: Candidate = .{ .decl = d, .origin = .author, .specificity = 0x3fff_ffff, .order = order };
                const slot = &winners[@intFromEnum(d.prop)];
                if (slot.* == null or cand.rank() > slot.*.?.rank()) slot.* = cand;
            }
        }
        try computeOne(a, &computed[id], parent, &winners, env);
    }
    return .{ .computed = computed };
}

/// The initial `color`, the text colour a page starts with.
pub var env_text: Color = Color.rgb(0, 0, 0);

fn computeOne(a: std.mem.Allocator, out: *Computed, parent: *const Computed, winners: []const ?Candidate, env: Env) Error!void {
    // Start from the initial values, then inherit the inherited ones.
    out.* = .{};
    inline for (@typeInfo(Prop).@"enum".fields) |f| {
        const p: Prop = @enumFromInt(f.value);
        if (p.inherited()) copyProp(out, parent, p);
    }
    // font-size first: every em below depends on it.
    if (winners[@intFromEnum(Prop.font_size)]) |c| try applyDeclared(a, out, .font_size, c.decl.value, parent, env);
    inline for (@typeInfo(Prop).@"enum".fields) |f| {
        const p: Prop = @enumFromInt(f.value);
        if (p != .font_size) if (winners[f.value]) |c| try applyDeclared(a, out, p, c.decl.value, parent, env);
    }
    // A float or an absolutely positioned box is blockified.
    if (out.float != .none or out.position == .absolute or out.position == .fixed) {
        out.display = switch (out.display) {
            .@"inline", .inline_block, .inline_table, .table_row, .table_cell, .table_row_group, .table_header_group, .table_footer_group, .table_caption, .table_column, .table_column_group => .block,
            .inline_flex => .flex,
            .inline_grid => .grid,
            else => out.display,
        };
    }
}

fn applyDeclared(a: std.mem.Allocator, out: *Computed, p: Prop, d: Declared, parent: *const Computed, env: Env) Error!void {
    switch (d) {
        .inherit => copyProp(out, parent, p),
        .initial => resetProp(out, p),
        .unset => if (p.inherited()) copyProp(out, parent, p) else resetProp(out, p),
        .values => |vals| {
            // A value that does not parse for its property is as if
            // undeclared: the inherited or initial value already stands.
            _ = applyValues(out, p, vals, parent, out.font_size, env, a) catch |e| switch (e) {
                error.OutOfMemory => return error.OutOfMemory,
                error.Invalid => false,
            };
        },
    }
}

/// The style of an anonymous box: initial values with the parent's
/// inherited properties, as CSS 2.1 §9.2.1.1 gives it — nothing of the
/// parent's position, float, box edges or sizes.
pub fn anonymous(parent: *const Computed) Computed {
    var out: Computed = .{};
    inline for (comptime std.enums.values(Prop)) |p| if (p.inherited()) copyProp(&out, parent, p);
    return out;
}

fn copyProp(out: *Computed, from: *const Computed, p: Prop) void {
    switch (p) {
        .display => out.display = from.display,
        .position => out.position = from.position,
        .float => out.float = from.float,
        .clear => out.clear = from.clear,
        .width => out.width = from.width,
        .height => out.height = from.height,
        .min_width => out.min_width = from.min_width,
        .min_height => out.min_height = from.min_height,
        .max_width => out.max_width = from.max_width,
        .max_height => out.max_height = from.max_height,
        .margin_top, .margin_right, .margin_bottom, .margin_left => out.margin[sideOf(p)] = from.margin[sideOf(p)],
        .padding_top, .padding_right, .padding_bottom, .padding_left => out.padding[sideOf(p)] = from.padding[sideOf(p)],
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width => out.border_width[sideOf(p)] = from.border_width[sideOf(p)],
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style => out.border_style[sideOf(p)] = from.border_style[sideOf(p)],
        .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => out.border_color[sideOf(p)] = from.border_color[sideOf(p)],
        .top, .right, .bottom, .left => out.inset[sideOf(p)] = from.inset[sideOf(p)],
        .color => out.color = from.color,
        .background_color => out.background_color = from.background_color,
        .font_size => out.font_size = from.font_size,
        .font_weight => out.font_weight = from.font_weight,
        .font_style => out.font_style = from.font_style,
        .font_family => out.font_family = from.font_family,
        .line_height => out.line_height = from.line_height,
        .text_align => out.text_align = from.text_align,
        .text_decoration_line => out.text_decoration = from.text_decoration,
        .text_indent => out.text_indent = from.text_indent,
        .text_transform => out.text_transform = from.text_transform,
        .white_space => out.white_space = from.white_space,
        .vertical_align => out.vertical_align = from.vertical_align,
        .list_style_type => out.list_style_type = from.list_style_type,
        .list_style_position => out.list_style_position = from.list_style_position,
        .overflow_x => out.overflow_x = from.overflow_x,
        .overflow_y => out.overflow_y = from.overflow_y,
        .visibility => out.visibility = from.visibility,
        .opacity => out.opacity = from.opacity,
        .flex_direction => out.flex_direction = from.flex_direction,
        .flex_wrap => out.flex_wrap = from.flex_wrap,
        .justify_content => out.justify_content = from.justify_content,
        .align_items => out.align_items = from.align_items,
        .align_self => out.align_self = from.align_self,
        .align_content => out.align_content = from.align_content,
        .flex_grow => out.flex_grow = from.flex_grow,
        .flex_shrink => out.flex_shrink = from.flex_shrink,
        .flex_basis => out.flex_basis = from.flex_basis,
        .order => out.order = from.order,
        .row_gap => out.row_gap = from.row_gap,
        .column_gap => out.column_gap = from.column_gap,
        .box_sizing => out.box_sizing = from.box_sizing,
        .z_index => out.z_index = from.z_index,
    }
}

fn resetProp(out: *Computed, p: Prop) void {
    const initial: Computed = .{};
    copyProp(out, &initial, p);
}

fn sideOf(p: Prop) usize {
    return switch (p) {
        .margin_top, .padding_top, .border_top_width, .border_top_style, .border_top_color, .top => 0,
        .margin_right, .padding_right, .border_right_width, .border_right_style, .border_right_color, .right => 1,
        .margin_bottom, .padding_bottom, .border_bottom_width, .border_bottom_style, .border_bottom_color, .bottom => 2,
        else => 3,
    };
}

// ------------------------------------------------------ value parsing

const ParseFail = error{ OutOfMemory, Invalid };

fn ident(v: css.Value) ?[]const u8 {
    return if (v == .token and v.token == .ident) v.token.ident else null;
}

fn keyword(comptime T: type, v: css.Value) ?T {
    const w = ident(v) orelse return null;
    inline for (@typeInfo(T).@"enum".fields) |f| {
        var buf: [32]u8 = undefined;
        for (f.name, 0..) |c, i| buf[i] = if (c == '_') '-' else c;
        if (std.ascii.eqlIgnoreCase(buf[0..f.name.len], w)) return @enumFromInt(f.value);
    }
    return null;
}

/// A length in pixels: `em` against `font_size`, `rem` against the
/// root's (16 here; the root's own size when it is computed), the
/// viewport units against `env`, the absolute units as CSS says. A
/// unitless zero is a length.
fn lengthPx(v: css.Value, font_size: f64, env: Env) ?f64 {
    if (v != .token) return null;
    switch (v.token) {
        .number => |n| return if (n.value == 0) 0 else null,
        .dimension => |d| {
            const eq = std.ascii.eqlIgnoreCase;
            const x = d.num.value;
            if (eq(d.unit, "px")) return x;
            if (eq(d.unit, "em")) return x * font_size;
            if (eq(d.unit, "rem")) return x * root_font_size;
            if (eq(d.unit, "ex") or eq(d.unit, "ch")) return x * font_size * 0.5;
            if (eq(d.unit, "vw")) return x * env.width / 100;
            if (eq(d.unit, "vh")) return x * env.height / 100;
            if (eq(d.unit, "vmin")) return x * @min(env.width, env.height) / 100;
            if (eq(d.unit, "vmax")) return x * @max(env.width, env.height) / 100;
            if (eq(d.unit, "in")) return x * 96;
            if (eq(d.unit, "cm")) return x * 96 / 2.54;
            if (eq(d.unit, "mm")) return x * 96 / 25.4;
            if (eq(d.unit, "q")) return x * 96 / 101.6;
            if (eq(d.unit, "pt")) return x * 96 / 72;
            if (eq(d.unit, "pc")) return x * 16;
            return null;
        },
        else => return null,
    }
}

pub var root_font_size: f64 = 16;

fn lengthPercent(v: css.Value, font_size: f64, env: Env) ?LengthPercent {
    if (v == .token and v.token == .percentage) return .{ .percent = v.token.percentage.value };
    if (lengthPx(v, font_size, env)) |px| return .{ .px = px };
    return null;
}

fn lengthAuto(v: css.Value, font_size: f64, env: Env) ?LengthAuto {
    if (ident(v)) |w| return if (std.ascii.eqlIgnoreCase(w, "auto")) .auto else null;
    return switch (lengthPercent(v, font_size, env) orelse return null) {
        .px => |x| .{ .px = x },
        .percent => |x| .{ .percent = x },
    };
}

fn borderWidthOf(v: css.Value, font_size: f64, env: Env) ?f64 {
    if (ident(v)) |w| {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "thin")) return 1;
        if (eq(w, "medium")) return 3;
        if (eq(w, "thick")) return 5;
        return null;
    }
    return lengthPx(v, font_size, env);
}

fn borderStyleOf(v: css.Value) ?BorderStyle {
    return keyword(BorderStyle, v);
}

const font_size_keywords = [_]struct { n: []const u8, px: f64 }{ .{ .n = "xx-small", .px = 9 }, .{ .n = "x-small", .px = 10 }, .{ .n = "small", .px = 13 }, .{ .n = "medium", .px = 16 }, .{ .n = "large", .px = 18 }, .{ .n = "x-large", .px = 24 }, .{ .n = "xx-large", .px = 32 }, .{ .n = "xxx-large", .px = 48 } };

/// Apply component values to a property; `error.Invalid` leaves `out`
/// untouched. `font_size` is the element's (for em), `parent` the
/// parent's computed style (for font-size's own em and the relative
/// weights).
fn applyValues(out: *Computed, p: Prop, vals_in: []const css.Value, parent: *const Computed, font_size: f64, env: Env, a: std.mem.Allocator) ParseFail!bool {
    var scratch: [16]css.Value = undefined;
    var n: usize = 0;
    for (vals_in) |v| if (!isWs(v)) {
        if (n == scratch.len) return error.Invalid;
        scratch[n] = v;
        n += 1;
    };
    const vals = scratch[0..n];
    if (vals.len == 0) {
        // An empty value from a shorthand means "the initial value".
        resetProp(out, p);
        return true;
    }
    const v = vals[0];
    switch (p) {
        .display => out.display = keyword(Display, v) orelse blk: {
            // `flow-root`, `inline flow-root` and the two-value syntax.
            const w = ident(v) orelse return error.Invalid;
            if (std.ascii.eqlIgnoreCase(w, "flow")) break :blk Display.block;
            return error.Invalid;
        },
        .position => out.position = keyword(Position, v) orelse return error.Invalid,
        .float => out.float = keyword(Float, v) orelse return error.Invalid,
        .clear => out.clear = keyword(Clear, v) orelse return error.Invalid,
        .width => out.width = lengthAuto(v, font_size, env) orelse return error.Invalid,
        .height => out.height = lengthAuto(v, font_size, env) orelse return error.Invalid,
        .min_width, .min_height => {
            const lp: LengthPercent = if (ident(v) != null and std.ascii.eqlIgnoreCase(ident(v).?, "auto")) .{ .px = 0 } else lengthPercent(v, font_size, env) orelse return error.Invalid;
            if (p == .min_width) out.min_width = lp else out.min_height = lp;
        },
        .max_width, .max_height => {
            const ln: LengthNone = if (ident(v) != null and std.ascii.eqlIgnoreCase(ident(v).?, "none")) .none else switch (lengthPercent(v, font_size, env) orelse return error.Invalid) {
                .px => |x| .{ .px = x },
                .percent => |x| .{ .percent = x },
            };
            if (p == .max_width) out.max_width = ln else out.max_height = ln;
        },
        .margin_top, .margin_right, .margin_bottom, .margin_left => out.margin[sideOf(p)] = lengthAuto(v, font_size, env) orelse return error.Invalid,
        .padding_top, .padding_right, .padding_bottom, .padding_left => out.padding[sideOf(p)] = lengthPercent(v, font_size, env) orelse return error.Invalid,
        .border_top_width, .border_right_width, .border_bottom_width, .border_left_width => out.border_width[sideOf(p)] = borderWidthOf(v, font_size, env) orelse return error.Invalid,
        .border_top_style, .border_right_style, .border_bottom_style, .border_left_style => out.border_style[sideOf(p)] = borderStyleOf(v) orelse return error.Invalid,
        .border_top_color, .border_right_color, .border_bottom_color, .border_left_color => out.border_color[sideOf(p)] = switch (color.parseValue(v) orelse return error.Invalid) {
            .color => |c| c,
            .current => null,
        },
        .top, .right, .bottom, .left => out.inset[sideOf(p)] = lengthAuto(v, font_size, env) orelse return error.Invalid,
        .color => out.color = switch (color.parseValue(v) orelse return error.Invalid) {
            .color => |c| c,
            .current => parent.color,
        },
        .background_color => out.background_color = switch (color.parseValue(v) orelse return error.Invalid) {
            .color => |c| c,
            .current => out.color,
        },
        .font_size => {
            if (ident(v)) |w| {
                for (font_size_keywords) |k| if (std.ascii.eqlIgnoreCase(k.n, w)) {
                    out.font_size = k.px;
                    return true;
                };
                if (std.ascii.eqlIgnoreCase(w, "smaller")) {
                    out.font_size = parent.font_size / 1.2;
                    return true;
                }
                if (std.ascii.eqlIgnoreCase(w, "larger")) {
                    out.font_size = parent.font_size * 1.2;
                    return true;
                }
                return error.Invalid;
            }
            // em and % here are of the parent's size.
            out.font_size = switch (lengthPercent(v, parent.font_size, env) orelse return error.Invalid) {
                .px => |x| x,
                .percent => |x| parent.font_size * x / 100,
            };
            if (out.font_size < 0) return error.Invalid;
        },
        .font_weight => {
            if (ident(v)) |w| {
                const eq = std.ascii.eqlIgnoreCase;
                if (eq(w, "normal")) {
                    out.font_weight = 400;
                } else if (eq(w, "bold")) {
                    out.font_weight = 700;
                } else if (eq(w, "bolder")) {
                    out.font_weight = if (parent.font_weight < 350) 400 else if (parent.font_weight < 550) 700 else 900;
                } else if (eq(w, "lighter")) {
                    out.font_weight = if (parent.font_weight < 550) 100 else if (parent.font_weight < 750) 400 else 700;
                } else return error.Invalid;
                return true;
            }
            if (v != .token or v.token != .number) return error.Invalid;
            const x = v.token.number.value;
            if (x < 1 or x > 1000) return error.Invalid;
            out.font_weight = @intFromFloat(x);
        },
        .font_style => out.font_style = keyword(FontStyle, v) orelse return error.Invalid,
        .font_family => {
            // Names: strings, or runs of idents joined by spaces; commas
            // between families.
            var fams: std.ArrayList([]const u8) = .empty;
            var name: std.ArrayList(u8) = .empty;
            var quoted = false; // the family before this comma was a string
            for (vals) |x| {
                if (x == .token and x.token == .comma) {
                    if (name.items.len == 0 and !quoted) return error.Invalid;
                    if (name.items.len > 0) try fams.append(a, name.items);
                    name = .empty;
                    quoted = false;
                    continue;
                }
                if (x == .token and x.token == .string) {
                    if (name.items.len != 0 or quoted) return error.Invalid;
                    try fams.append(a, x.token.string);
                    // A string is a whole family; a comma or the end follows.
                    quoted = true;
                    continue;
                }
                if (quoted) return error.Invalid;
                const w = ident(x) orelse return error.Invalid;
                if (name.items.len > 0) try name.append(a, ' ');
                try name.appendSlice(a, w);
            }
            if (name.items.len > 0) try fams.append(a, name.items);
            if (fams.items.len == 0) return error.Invalid;
            out.font_family = fams.items;
        },
        .line_height => {
            if (ident(v)) |w| {
                if (!std.ascii.eqlIgnoreCase(w, "normal")) return error.Invalid;
                out.line_height = .normal;
                return true;
            }
            if (v == .token and v.token == .number) {
                if (v.token.number.value < 0) return error.Invalid;
                out.line_height = .{ .number = v.token.number.value };
                return true;
            }
            out.line_height = switch (lengthPercent(v, font_size, env) orelse return error.Invalid) {
                .px => |x| .{ .px = x },
                .percent => |x| .{ .px = font_size * x / 100 },
            };
        },
        .text_align => out.text_align = keyword(TextAlign, v) orelse return error.Invalid,
        .text_decoration_line => {
            var d: Decoration = .{};
            for (vals) |x| {
                const w = ident(x) orelse return error.Invalid;
                const eq = std.ascii.eqlIgnoreCase;
                if (eq(w, "none")) {
                    if (vals.len != 1) return error.Invalid;
                } else if (eq(w, "underline")) d.underline = true else if (eq(w, "overline")) d.overline = true else if (eq(w, "line-through")) d.line_through = true else if (eq(w, "blink")) {} else return error.Invalid;
            }
            out.text_decoration = d;
        },
        .text_indent => out.text_indent = lengthPercent(v, font_size, env) orelse return error.Invalid,
        .text_transform => out.text_transform = keyword(TextTransform, v) orelse return error.Invalid,
        .white_space => out.white_space = keyword(WhiteSpace, v) orelse return error.Invalid,
        .vertical_align => {
            if (keyword(enum { baseline, top, middle, bottom, sub, super, text_top, text_bottom }, v)) |k| {
                out.vertical_align = switch (k) {
                    .baseline => .baseline,
                    .top => .top,
                    .middle => .middle,
                    .bottom => .bottom,
                    .sub => .sub,
                    .super => .super,
                    .text_top => .text_top,
                    .text_bottom => .text_bottom,
                };
                return true;
            }
            out.vertical_align = .{ .length = lengthPercent(v, font_size, env) orelse return error.Invalid };
        },
        .list_style_type => out.list_style_type = keyword(ListStyleType, v) orelse return error.Invalid,
        .list_style_position => out.list_style_position = keyword(ListStylePosition, v) orelse return error.Invalid,
        .overflow_x => out.overflow_x = keyword(Overflow, v) orelse return error.Invalid,
        .overflow_y => out.overflow_y = keyword(Overflow, v) orelse return error.Invalid,
        .visibility => out.visibility = keyword(Visibility, v) orelse return error.Invalid,
        .opacity => {
            const x: f64 = if (v == .token and v.token == .number) v.token.number.value else if (v == .token and v.token == .percentage) v.token.percentage.value / 100 else return error.Invalid;
            out.opacity = @min(1, @max(0, x));
        },
        .box_sizing => out.box_sizing = keyword(BoxSizing, v) orelse return error.Invalid,
        .flex_direction => out.flex_direction = keyword(FlexDirection, v) orelse return error.Invalid,
        .flex_wrap => out.flex_wrap = keyword(FlexWrap, v) orelse return error.Invalid,
        .justify_content => out.justify_content = keyword(JustifyContent, v) orelse return error.Invalid,
        .align_items => out.align_items = keyword(AlignItems, v) orelse return error.Invalid,
        .align_self => out.align_self = keyword(AlignSelf, v) orelse return error.Invalid,
        .align_content => out.align_content = keyword(AlignContent, v) orelse return error.Invalid,
        .flex_grow, .flex_shrink => {
            if (v != .token or v.token != .number or v.token.number.value < 0) return error.Invalid;
            if (p == .flex_grow) out.flex_grow = v.token.number.value else out.flex_shrink = v.token.number.value;
        },
        .flex_basis => {
            if (ident(v)) |w| if (std.ascii.eqlIgnoreCase(w, "content")) {
                out.flex_basis = .auto;
                return true;
            };
            out.flex_basis = lengthAuto(v, font_size, env) orelse return error.Invalid;
        },
        .order => {
            if (v != .token or v.token != .number or !v.token.number.integer) return error.Invalid;
            out.order = @intFromFloat(v.token.number.value);
        },
        .row_gap, .column_gap => {
            const lp: LengthPercent = if (ident(v) != null and std.ascii.eqlIgnoreCase(ident(v).?, "normal")) .{ .px = 0 } else lengthPercent(v, font_size, env) orelse return error.Invalid;
            if (p == .row_gap) out.row_gap = lp else out.column_gap = lp;
        },
        .z_index => {
            if (ident(v)) |w| {
                if (!std.ascii.eqlIgnoreCase(w, "auto")) return error.Invalid;
                out.z_index = null;
                return true;
            }
            if (v != .token or v.token != .number or !v.token.number.integer) return error.Invalid;
            out.z_index = @intFromFloat(v.token.number.value);
        },
    }
    return true;
}

// ------------------------------------------------------ the UA sheet

/// The HTML Standard's rendering section, the part these properties
/// can say. `a[href]` stands for `:link` (every link is unvisited).
pub const ua_sheet =
    \\html, body, div, p, h1, h2, h3, h4, h5, h6, ul, ol, li, dl, dt, dd, pre, blockquote, address, article, aside, footer, header, hgroup, main, nav, section, figure, figcaption, form, fieldset, legend, details, summary, dialog, hr, center, dir, menu, search, listing, xmp, plaintext, optgroup { display: block }
    \\head, link, meta, script, style, title, base, template, area, param, datalist, noframes, rp, [hidden] { display: none }
    \\body { margin: 8px }
    \\h1 { font-size: 2em; margin: 0.67em 0; font-weight: bold }
    \\h2 { font-size: 1.5em; margin: 0.83em 0; font-weight: bold }
    \\h3 { font-size: 1.17em; margin: 1em 0; font-weight: bold }
    \\h4 { margin: 1.33em 0; font-weight: bold }
    \\h5 { font-size: 0.83em; margin: 1.67em 0; font-weight: bold }
    \\h6 { font-size: 0.67em; margin: 2.33em 0; font-weight: bold }
    \\p, dl, ul, ol, menu, dir, pre, listing, xmp, plaintext { margin: 1em 0 }
    \\blockquote, figure { margin: 1em 40px }
    \\ul, menu, dir { list-style-type: disc; padding-left: 40px }
    \\ol { list-style-type: decimal; padding-left: 40px }
    \\ul ul, ol ul { list-style-type: circle }
    \\ul ul ul, ol ul ul, ol ol ul, ul ol ul { list-style-type: square }
    \\li { display: list-item }
    \\dd { margin-left: 40px }
    \\pre, listing, xmp, plaintext { font-family: monospace; white-space: pre }
    \\code, kbd, samp, tt { font-family: monospace }
    \\b, strong { font-weight: bolder }
    \\i, em, cite, var, dfn, address { font-style: italic }
    \\u, ins { text-decoration: underline }
    \\s, strike, del { text-decoration: line-through }
    \\small { font-size: smaller }
    \\big { font-size: larger }
    \\sub { vertical-align: sub; font-size: smaller }
    \\sup { vertical-align: super; font-size: smaller }
    \\a[href] { color: #0000ee; text-decoration: underline }
    \\hr { color: gray; border-style: inset; border-width: 1px; margin: 0.5em auto }
    \\table { display: table; box-sizing: border-box; text-indent: 0 }
    \\caption { display: table-caption; text-align: center }
    \\thead { display: table-header-group } tbody { display: table-row-group } tfoot { display: table-footer-group }
    \\tr { display: table-row } td, th { display: table-cell; padding: 1px } th { font-weight: bold; text-align: center }
    \\colgroup { display: table-column-group } col { display: table-column }
    \\input, select, button, textarea, meter, progress { display: inline-block }
    \\button, select, input { font-family: sans-serif }
    \\textarea { white-space: pre-wrap }
    \\center { text-align: center }
    \\iframe { border: 2px inset }
    \\br { display: inline }
    \\ruby { display: inline } rt { display: inline; font-size: 50% }
;

// ------------------------------------------------------------------ tests

const html = @import("html.zig");

test "style: the cascade, inheritance, shorthands, units" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><style>
        \\  p { color: red; margin: 1em 2px; font-size: 20px }
        \\  #x { color: blue !important; padding: 5% 4px 3px }
        \\  p.big { font-size: 200% }
        \\  .side { border: 2px dashed green; border-left-width: thick }
        \\  @media (max-width: 500px) { p { display: none } }
        \\  @media (min-width: 500px) { .m { text-align: center } }
        \\  span { font-weight: bolder; line-height: 1.5 }
        \\  em { color: inherit }
        \\  .n { display: bogus; color: nonsense; width: calc(1px + 2px) }
        \\</style>
        \\<p id=x class="big side m n" style="color: green; opacity: .5"><span>a<em>b</em></span></p><ul><li>x</ul><h1>T</h1>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    const p = selectors.Selector.parse(a, "#x") catch unreachable;
    const px = p.queryFirst(doc, dom.document_id).?;
    const s = styles.get(px);
    try std.testing.expectEqual(Display.block, s.display);
    // !important in the sheet beats the style attribute.
    try std.testing.expectEqualStrings("rgb(0, 0, 255)", try s.color.serialize(a));
    try std.testing.expectEqual(@as(f64, 0.5), s.opacity);
    try std.testing.expectEqual(@as(f64, 32), s.font_size); // 200% of the parent's 16, later rule wins over 20px
    try std.testing.expect(s.margin[0] == .px and s.margin[0].px == 32); // 1em of 32
    try std.testing.expect(s.margin[1] == .px and s.margin[1].px == 2);
    try std.testing.expect(s.padding[0] == .percent and s.padding[0].percent == 5);
    try std.testing.expect(s.padding[3] == .px and s.padding[3].px == 4);
    try std.testing.expectEqual(BorderStyle.dashed, s.border_style[0]);
    try std.testing.expectEqual(@as(f64, 5), s.border_width[3]);
    try std.testing.expectEqual(@as(f64, 2), s.border_width[0]);
    try std.testing.expectEqualStrings("rgb(0, 128, 0)", try s.borderColor(0).serialize(a));
    try std.testing.expectEqual(TextAlign.center, s.text_align);
    try std.testing.expect(s.width == .auto); // calc() dropped
    const span_sel = selectors.Selector.parse(a, "span") catch unreachable;
    const span = styles.get(span_sel.queryFirst(doc, dom.document_id).?);
    try std.testing.expectEqual(@as(u16, 700), span.font_weight);
    try std.testing.expectEqual(@as(f64, 32), span.font_size); // inherited
    try std.testing.expect(span.line_height == .number);
    try std.testing.expectEqual(@as(f64, 48), span.lineHeightPx());
    const em_sel = selectors.Selector.parse(a, "em") catch unreachable;
    const em = styles.get(em_sel.queryFirst(doc, dom.document_id).?);
    try std.testing.expectEqualStrings("rgb(0, 0, 255)", try em.color.serialize(a));
    try std.testing.expectEqual(FontStyle.italic, em.font_style); // the UA sheet
    const li_sel = selectors.Selector.parse(a, "li") catch unreachable;
    const li = styles.get(li_sel.queryFirst(doc, dom.document_id).?);
    try std.testing.expectEqual(Display.list_item, li.display);
    try std.testing.expectEqual(ListStyleType.disc, li.list_style_type);
    const h1_sel = selectors.Selector.parse(a, "h1") catch unreachable;
    const h1 = styles.get(h1_sel.queryFirst(doc, dom.document_id).?);
    try std.testing.expectEqual(@as(f64, 32), h1.font_size);
    try std.testing.expect(h1.margin[0] == .px and h1.margin[0].px == 32 * 0.67);
    const head_sel = selectors.Selector.parse(a, "head") catch unreachable;
    try std.testing.expectEqual(Display.none, styles.get(head_sel.queryFirst(doc, dom.document_id).?).display);
}

/// The document's stylesheets in order: the user-agent sheet, then
/// every `<style>` element's text (a `media` attribute honoured), for
/// `env`. `<link rel=stylesheet>` needs a fetch and is the loader's.
pub fn collectDocumentSheets(a: std.mem.Allocator, doc: *const Document, env: Env) Error![]const Sheet {
    return collectDocumentSheetsWith(a, doc, env, try parseSheet(a, ua_sheet, .user_agent, env));
}

/// The same with a user-agent sheet parsed earlier (a host keeps one
/// across calls: parsing it is most of a small page's cascade).
pub fn collectDocumentSheetsWith(a: std.mem.Allocator, doc: *const Document, env: Env, ua: Sheet) Error![]const Sheet {
    return collectDocumentSheetsLoading(a, doc, env, ua, null);
}

/// `collectDocumentSheetsLoading` without a keeper: everything in `a`.
pub fn collectDocumentSheetsLoading(a: std.mem.Allocator, doc: *const Document, env: Env, ua: Sheet, loader: ?Loader) Error![]const Sheet {
    return collectDocumentSheetsKept(a, doc, env, ua, loader, null);
}

/// The document's sheets in document order — `<style>` blocks and, with
/// a loader, `<link rel=stylesheet>`s fetched through it, each with its
/// `@import`s before it — after the user-agent sheet. Without a loader
/// the links are left out and the page paints as its inline styles.
pub fn collectDocumentSheetsKept(a: std.mem.Allocator, doc: *const Document, env: Env, ua: Sheet, loader: ?Loader, keep: ?Keep) Error![]const Sheet {
    var sheets: std.ArrayList(Sheet) = .empty;
    const list_a = if (keep) |k| k.a else a;
    try sheets.append(list_a, ua);
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| {
        const is_style = doc.isHtml(id, "style");
        const is_link = doc.isHtml(id, "link");
        if (!is_style and !is_link) continue;
        if (is_link) {
            if (loader == null) continue;
            if (!linkIsStylesheet(doc.getAttr(id, "rel") orelse continue)) continue;
            if (doc.getAttr(id, "disabled") != null) continue;
        }
        if (doc.getAttr(id, "media")) |m| {
            const q = try media.Query.parseText(a, m);
            if (!q.matches(env)) continue;
        }
        if (is_style) {
            const text = try doc.textContent(id, a);
            try appendSheetWithImports(a, &sheets, try parseSheet(a, text, .author, env), env, loader, keep, 0);
        } else {
            const href = std.mem.trim(u8, doc.getAttr(id, "href") orelse continue, " \t\n\r");
            if (href.len == 0) continue;
            const ld = loader.?;
            const got = ld.fetch(ld.ctx, href, null) orelse continue;
            try appendSheetWithImports(a, &sheets, try parseSheetAt(a, got.text, .author, env, got.url), env, loader, keep, 0);
        }
    }
    return sheets.items;
}

test "style: linked sheets and their @imports join the cascade in order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const Table = struct {
        fetched: std.ArrayList([]const u8) = .empty,
        a: std.mem.Allocator,
        fn fetch(ctx: *anyopaque, href: []const u8, base: ?[]const u8) ?Loader.Loaded {
            const self: *@This() = @ptrCast(@alignCast(ctx));
            self.fetched.append(self.a, href) catch return null;
            // A toy resolver: a relative href joins the base's directory.
            var url_buf: [128]u8 = undefined;
            const url = if (std.mem.startsWith(u8, href, "http")) href else std.fmt.bufPrint(&url_buf, "{s}{s}", .{ if (base) |b| b[0 .. std.mem.lastIndexOfScalar(u8, b, '/').? + 1] else "http://x/", href }) catch return null;
            const owned = self.a.dupe(u8, url) catch return null;
            if (std.mem.endsWith(u8, owned, "/a.css")) return .{ .text = "@import \"deep/b.css\"; h1 { color: red }", .url = owned };
            if (std.mem.endsWith(u8, owned, "/deep/b.css")) return .{ .text = "@font-face { font-family: F; src: url(f.woff) } h1 { color: blue; margin: 0 }", .url = owned };
            if (std.mem.endsWith(u8, owned, "/gone.css")) return null;
            return null;
        }
    };
    var table = Table{ .a = a };
    const loader: Loader = .{ .ctx = &table, .fetch = Table.fetch };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><head>
        \\<link rel="Stylesheet" href="a.css">
        \\<link rel="alternate stylesheet" href="gone.css">
        \\<link rel="stylesheet" href="gone.css" media="(max-width: 100px)">
        \\<style>h1 { color: green }</style>
        \\<link rel="stylesheet" href="gone.css">
        \\</head><body><h1>t</h1></body>
    , .{});
    const ua = try parseSheet(a, ua_sheet, .user_agent, env);
    const sheets = try collectDocumentSheetsLoading(a, doc, env, ua, loader);
    // ua, b.css (imported, first), a.css, the style block; gone.css was
    // asked for once (the alternate and the non-matching media never).
    try std.testing.expectEqual(@as(usize, 4), sheets.len);
    try std.testing.expectEqualStrings("http://x/deep/b.css", sheets[1].base.?);
    try std.testing.expectEqualStrings("http://x/a.css", sheets[2].base.?);
    try std.testing.expect(sheets[3].base == null);
    try std.testing.expectEqual(@as(usize, 1), sheets[1].font_faces.len);
    try std.testing.expectEqualStrings("http://x/deep/b.css", sheets[1].font_faces[0].base.?);
    try std.testing.expectEqual(@as(usize, 3), table.fetched.items.len);
    // The cascade: the style block wins (last), so the heading is green.
    const styles = try compute(a, doc, sheets, env);
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "h1")) {
        const c = styles.get(id).color;
        try std.testing.expect(c.r == 0 and c.g == 128 and c.b == 0);
    };
    // Without a loader the links are skipped and only the block applies.
    const inline_only = try collectDocumentSheetsWith(a, doc, env, ua);
    try std.testing.expectEqual(@as(usize, 2), inline_only.len);
}

test "style: a quoted family followed by more families is a list" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><style>
        \\  .q { font-family: "Plex Serif", serif }
        \\  .u { font-family: Plex Sans, "Fira Code", monospace }
        \\  .bad { font-family: "A" B }
        \\</style>
        \\<p class=q>a</p><p class=u>b</p><p class=bad>c</p>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var w = doc.walk(dom.document_id);
    var seen: usize = 0;
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        const fams = styles.get(id).font_family;
        switch (seen) {
            0 => {
                try std.testing.expectEqual(@as(usize, 2), fams.len);
                try std.testing.expectEqualStrings("Plex Serif", fams[0]);
                try std.testing.expectEqualStrings("serif", fams[1]);
            },
            1 => {
                try std.testing.expectEqual(@as(usize, 3), fams.len);
                try std.testing.expectEqualStrings("Plex Sans", fams[0]);
                try std.testing.expectEqualStrings("Fira Code", fams[1]);
                try std.testing.expectEqualStrings("monospace", fams[2]);
            },
            // Invalid: the declaration is dropped and the default stands.
            else => try std.testing.expectEqualStrings("sans-serif", fams[0]),
        }
        seen += 1;
    };
    try std.testing.expectEqual(@as(usize, 3), seen);
}

test "style: @font-face rules are collected with their family and first url" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const sheet = try parseSheet(a, "@font-face { font-family: \"Plex Serif\"; src: local(Plex), url(/f/serif.woff) format(\"woff\"); } p { color: red } @font-face { font-family: Mono; src: url(\"mono.ttf\") }", .author, .{ .width = 800, .height = 600 });
    try std.testing.expectEqual(@as(usize, 2), sheet.font_faces.len);
    try std.testing.expectEqualStrings("Plex Serif", sheet.font_faces[0].family);
    try std.testing.expectEqualStrings("/f/serif.woff", sheet.font_faces[0].src);
    try std.testing.expectEqualStrings("Mono", sheet.font_faces[1].family);
    try std.testing.expectEqualStrings("mono.ttf", sheet.font_faces[1].src);
    try std.testing.expectEqual(@as(usize, 1), sheet.rules.len);
}
