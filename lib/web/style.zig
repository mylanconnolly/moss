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
//! Custom properties cascade and inherit, and `var()` is substituted at
//! computed-value time; HTML's presentational hints join the cascade
//! under every author rule; `px_scale` is the page zoom.
//!
//! `calc()`, `min()`, `max()` and `clamp()` resolve to px plus a
//! percentage; cascade layers rank between origin and specificity;
//! rules are bucketed and filtered by an ancestor Bloom filter.
//!
//! Not built: the other math functions, `@supports` beyond a property
//! check, the user origin, `revert`, and animations.
const std = @import("std");
const css = @import("css.zig");
const weburl = @import("url.zig");
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
    /// A `calc()` with a percentage in it: resolved at layout.
    calc: Mix,

    pub fn zero() LengthPercent {
        return .{ .px = 0 };
    }
};

/// `px` plus `pct` percent of whatever the percentage is of: what a
/// `calc()` mixing the two comes to once every other unit is resolved.
pub const Mix = struct {
    px: f64,
    pct: f64,

    pub fn of(m: Mix, base: f64) f64 {
        return m.px + base * m.pct / 100;
    }
};

/// `auto` beside a length or percentage.
pub const LengthAuto = union(enum) { px: f64, percent: f64, auto, calc: Mix };
/// `none` beside a length or percentage (max sizes).
pub const LengthNone = union(enum) { px: f64, percent: f64, none, calc: Mix };

pub const Display = enum { @"inline", block, inline_block, list_item, none, contents, flex, inline_flex, grid, inline_grid, table, inline_table, table_row, table_cell, table_row_group, table_header_group, table_footer_group, table_caption, table_column, table_column_group, flow_root };
pub const Position = enum { static, relative, absolute, fixed, sticky };
// Flexbox (Level 1). `start`/`end` are taken as the flex ones; `left`/
// `right`/`normal` are not (a declaration using them is dropped, so the
// initial value stands, which is what those resolve to in a row anyway).
pub const FlexDirection = enum { row, row_reverse, column, column_reverse };
pub const FlexWrap = enum { nowrap, wrap, wrap_reverse };
pub const JustifyContent = enum { flex_start, flex_end, center, space_between, space_around, space_evenly, start, end };
pub const AlignItems = enum { stretch, flex_start, flex_end, center, baseline, start, end, self_start, self_end, normal, left, right };
pub const AlignSelf = enum { auto, stretch, flex_start, flex_end, center, baseline, start, end, self_start, self_end, normal, left, right };

// Grid (Level 1).
/// One side of a track's size: a length, a percentage, a flexible
/// fraction, or sized by its items.
pub const TrackSize = union(enum) { px: f64, percent: f64, fr: f64, auto, min_content, max_content };
/// A track: `minmax(min, max)`; a single size is both (a `fr` one is
/// `minmax(auto, fr)`).
pub const Track = struct { min: TrackSize, max: TrackSize };
pub const LineName = struct { name: []const u8, line: u32 };
/// `repeat(auto-fill | auto-fit, …)`: its tracks, inserted before the
/// explicit track `at`, repeated as often as they fit.
pub const AutoRepeat = struct { at: u32, tracks: []const Track, fit: bool };
pub const TrackList = struct {
    tracks: []const Track = &.{},
    /// Named lines (1-based line numbers of the explicit grid).
    names: []const LineName = &.{},
    auto_repeat: ?AutoRepeat = null,
};
/// Where an item starts or ends on one axis.
pub const GridLine = union(enum) { auto, line: i32, span: u32, name: []const u8 };
/// A named area from `grid-template-areas`: rows and columns, 0-based,
/// ends exclusive.
pub const GridArea = struct { name: []const u8, row0: u32, row1: u32, col0: u32, col1: u32 };
pub const GridAutoFlow = struct { column: bool = false, dense: bool = false };
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
pub const ClipBox = enum { content_box, padding_box, border_box };
/// `background-attachment`: `fixed` anchors the image to the viewport
/// (its positioning area), the others to the box.
pub const BackgroundAttachment = enum { scroll, fixed, local };

/// A timing function (`transition-timing-function`, `animation-*`).
pub const TimingFn = union(enum) {
    linear,
    ease,
    ease_in,
    ease_out,
    ease_in_out,
    cubic: [4]f64,
    /// `steps(n, start|end)`.
    steps: struct { n: u32, start: bool },

    /// The eased progress for a linear one in [0, 1].
    pub fn at(tf: TimingFn, t_in: f64) f64 {
        const t = @max(0, @min(1, t_in));
        return switch (tf) {
            .linear => t,
            .ease => bezier(0.25, 0.1, 0.25, 1, t),
            .ease_in => bezier(0.42, 0, 1, 1, t),
            .ease_out => bezier(0, 0, 0.58, 1, t),
            .ease_in_out => bezier(0.42, 0, 0.58, 1, t),
            .cubic => |c| bezier(c[0], c[1], c[2], c[3], t),
            .steps => |st| blk: {
                const n: f64 = @floatFromInt(@max(1, st.n));
                const k = if (st.start) @ceil(t * n) else @floor(t * n);
                break :blk @min(1, k / n);
            },
        };
    }

    /// A cubic Bézier easing curve: the y at the x that equals t, by
    /// bisection on the curve's x.
    fn bezier(x1: f64, y1: f64, x2: f64, y2: f64, t: f64) f64 {
        if (t <= 0) return 0;
        if (t >= 1) return 1;
        var lo: f64 = 0;
        var hi: f64 = 1;
        var u: f64 = t;
        var i: usize = 0;
        while (i < 24) : (i += 1) {
            const x = 3 * (1 - u) * (1 - u) * u * x1 + 3 * (1 - u) * u * u * x2 + u * u * u;
            if (x < t) lo = u else hi = u;
            u = (lo + hi) / 2;
        }
        return 3 * (1 - u) * (1 - u) * u * y1 + 3 * (1 - u) * u * u * y2 + u * u * u;
    }
};

pub const AnimationDirection = enum { normal, reverse, alternate, alternate_reverse };
pub const AnimationFill = enum { none, forwards, backwards, both };

/// One function of a `transform` list, in order; angles in degrees.
pub const TransformFn = union(enum) {
    translate: [2]LengthPercent,
    scale: [2]f64,
    rotate: f64,
    skew: [2]f64,
    matrix: [6]f64,
};

/// `clip-path`: a basic shape over the border box.
pub const ClipPath = union(enum) {
    none,
    inset: struct { top: LengthPercent, right: LengthPercent, bottom: LengthPercent, left: LengthPercent, radius: LengthPercent },
    /// Null radius: `closest-side`.
    circle: struct { r: ?LengthPercent, cx: LengthPercent, cy: LengthPercent },
    ellipse: struct { rx: ?LengthPercent, ry: ?LengthPercent, cx: LengthPercent, cy: LengthPercent },
    polygon: []const [2]LengthPercent,
};
pub const Visibility = enum { visible, hidden, collapse };
pub const Cursor = enum { auto, default, none, context_menu, help, pointer, progress, wait, cell, crosshair, text, vertical_text, alias, copy, move, no_drop, not_allowed, grab, grabbing, e_resize, n_resize, ne_resize, nw_resize, s_resize, se_resize, sw_resize, w_resize, ew_resize, ns_resize, nesw_resize, nwse_resize, col_resize, row_resize, all_scroll, zoom_in, zoom_out };
pub const BoxSizing = enum { content_box, border_box };
pub const BorderCollapse = enum { separate, collapse };
pub const BackgroundRepeat = enum { repeat, repeat_x, repeat_y, no_repeat };
pub const FillPaint = union(enum) { none, current, color: Color };

/// A gradient's colour stop: its colour and, when given, where it sits
/// along the line (a fraction; percentages and lengths alike are taken
/// against the line when painted).
pub const Stop = struct { color: Color, at: ?LengthPercent = null };

/// `background-image`: one layer — a picture by URL (as written; the
/// declaring sheet's URL is `background_base`) or a linear gradient.
pub const BackgroundImage = union(enum) {
    none,
    url: []const u8,
    /// `angle` in degrees, CSS's (0 up, 90 right, 180 down); `repeating`
    /// tiles the stops.
    linear: struct { angle: f64, stops: []const Stop, repeating: bool = false },
};

/// `background-size`: `auto` (the picture's own), `cover`, `contain`, or
/// a width and height (either `auto`).
pub const BackgroundSize = union(enum) { auto, cover, contain, size: [2]LengthAuto };
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
    /// `overflow-clip-margin`: how far past the padding box (or the box
    /// named) an `overflow: clip` box's clip reaches.
    overflow_clip_margin: f64 = 0,
    overflow_clip_box: ClipBox = .padding_box,
    visibility: Visibility = .visible,
    cursor: Cursor = .auto,
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
    /// Tables: the spacing between cells (horizontal, vertical) and
    /// whether adjacent borders collapse into one. Inherited.
    border_spacing_x: f64 = 0,
    border_spacing_y: f64 = 0,
    border_collapse: BorderCollapse = .separate,
    background_image: BackgroundImage = .none,
    /// The URL a `background-image` url is relative to: the sheet that
    /// declared it (null: the page).
    background_base: ?[]const u8 = null,
    background_position: [2]LengthPercent = .{ .{ .percent = 0 }, .{ .percent = 0 } },
    background_size: BackgroundSize = .auto,
    background_repeat: [2]bool = .{ true, true },
    background_attachment: BackgroundAttachment = .scroll,
    /// SVG's `fill` as page CSS gives it to an inline `<svg>` (inherited):
    /// null when no rule sets it; `current` is `currentColor`.
    fill: ?FillPaint = null,
    /// The translation part of `transform` (a percentage is of the box's
    /// own size); scales and rotations are not painted yet.
    translate: [2]LengthPercent = .{ .{ .px = 0 }, .{ .px = 0 } },
    /// The `transform` list when it is more than translations (then
    /// `translate` is zero and the painter maps the box through it);
    /// empty for none or for pure translations.
    transform_fns: []const TransformFn = &.{},
    /// `transform` is not `none` (a translation alone included): the box
    /// is a containing block for absolute and fixed descendants.
    has_transform: bool = false,
    transform_origin: [2]LengthPercent = .{ .{ .percent = 50 }, .{ .percent = 50 } },
    clip_path: ClipPath = .none,
    /// `transition-*`, as lists (the i-th property takes the i-th
    /// duration, delay and timing, each list repeating): an empty
    /// property list means `all`, a null entry means `all` too.
    transition_property: []const ?Prop = &.{},
    transition_none: bool = false,
    transition_duration: []const f64 = &.{},
    transition_delay: []const f64 = &.{},
    transition_timing: []const TimingFn = &.{},
    /// `animation-*`, the first animation of the list (one per element).
    animation_name: []const u8 = "",
    animation_duration: f64 = 0,
    animation_delay: f64 = 0,
    animation_timing: TimingFn = .ease,
    animation_iterations: f64 = 1,
    animation_direction: AnimationDirection = .normal,
    animation_fill: AnimationFill = .none,
    animation_paused: bool = false,
    /// `mask-image` and its placement (the background's kinds): what of
    /// the element shows is the picture's alpha.
    mask_image: BackgroundImage = .none,
    mask_base: ?[]const u8 = null,
    mask_position: [2]LengthPercent = .{ .{ .percent = 0 }, .{ .percent = 0 } },
    mask_size: BackgroundSize = .auto,
    mask_repeat: [2]bool = .{ true, true },
    grid_template_columns: TrackList = .{},
    grid_template_rows: TrackList = .{},
    grid_template_areas: []const GridArea = &.{},
    grid_auto_columns: Track = .{ .min = .auto, .max = .auto },
    grid_auto_rows: Track = .{ .min = .auto, .max = .auto },
    grid_auto_flow: GridAutoFlow = .{},
    /// Placement: row start, column start, row end, column end.
    grid_place: [4]GridLine = .{ .auto, .auto, .auto, .auto },
    justify_items: AlignItems = .normal,
    justify_self: AlignSelf = .auto,
    /// Corner radii, horizontal only (top-left, top-right, bottom-right,
    /// bottom-left).
    border_radius: [4]LengthPercent = .{ .{ .px = 0 }, .{ .px = 0 }, .{ .px = 0 }, .{ .px = 0 } },
    /// The custom properties in force, inherited: the parent's list,
    /// shared unless this element declares some of its own.
    customs: ?*const CustomScope = null,

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
    cursor,
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
    border_spacing_x,
    border_spacing_y,
    border_collapse,
    background_image,
    background_position_x,
    background_position_y,
    background_size,
    background_repeat,
    background_attachment,
    border_top_left_radius,
    border_top_right_radius,
    border_bottom_right_radius,
    border_bottom_left_radius,
    fill,
    transform,
    transform_origin,
    clip_path,
    overflow_clip_margin,
    transition_property,
    transition_duration,
    transition_delay,
    transition_timing_function,
    animation_name,
    animation_duration,
    animation_delay,
    animation_timing_function,
    animation_iteration_count,
    animation_direction,
    animation_fill_mode,
    animation_play_state,
    mask_image,
    mask_position_x,
    mask_position_y,
    mask_size,
    mask_repeat,
    grid_template_columns,
    grid_template_rows,
    grid_template_areas,
    grid_auto_columns,
    grid_auto_rows,
    grid_auto_flow,
    grid_row_start,
    grid_column_start,
    grid_row_end,
    grid_column_end,
    justify_items,
    justify_self,

    pub fn inherited(p: Prop) bool {
        return switch (p) {
            .color, .font_size, .font_weight, .font_style, .font_family, .line_height, .text_align, .text_indent, .text_transform, .white_space, .list_style_type, .list_style_position, .visibility, .cursor, .border_spacing_x, .border_spacing_y, .border_collapse, .fill => true,
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
    /// A custom property's value (`--name: …`), kept as written; the
    /// declaration's `name` says which, and its `prop` means nothing.
    custom: []const css.Value,
    /// A value with `var()` in it: checked only once the variables are
    /// substituted at computed-value time. When the declaration came from
    /// a shorthand, its `name` is the shorthand, expanded again then.
    pending: []const css.Value,
};

pub const Declaration = struct {
    prop: Prop,
    value: Declared,
    important: bool,
    name: []const u8 = "",
};

/// An element's custom properties: the ones its own declarations
/// changed, over its parent's scope (shared by every element that
/// changes nothing). A theme's `:root` holds thousands; an element that
/// sets three gets a node of three, not a copy of all of them.
pub const CustomScope = struct {
    parent: ?*const CustomScope,
    names: []const []const u8,
    values: []const []const css.Value,
    /// A large scope's names to their positions.
    map: ?*const std.StringHashMapUnmanaged(u32) = null,

    pub fn get(scope: ?*const CustomScope, name: []const u8) ?[]const css.Value {
        var cur = scope;
        while (cur) |c| : (cur = c.parent) {
            if (c.map) |m| {
                if (m.get(name)) |i| return c.values[i];
                continue;
            }
            var i = c.names.len;
            while (i > 0) {
                i -= 1;
                if (std.mem.eql(u8, c.names[i], name)) return c.values[i];
            }
        }
        return null;
    }
};

pub const Origin = enum(u8) { user_agent = 0, author = 1 };

pub const Rule = struct {
    /// One complex selector; a list becomes several rules sharing
    /// declarations, so each carries its own specificity.
    selector: selectors.Complex,
    specificity: u32,
    declarations: []const Declaration,
    /// The cascade layer, by order of first mention in the sheet;
    /// `unlayered` (the highest) outside any `@layer`.
    layer: u8 = unlayered,
};

pub const unlayered: u8 = 255;

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
    /// `@keyframes` rules seen, in order (a later name wins).
    keyframes: []const Keyframes = &.{},
    /// A selector in the sheet depends on the interaction state
    /// (`:hover`, `:active`, `:focus`): a hover change restyles.
    interactive: bool = false,
    /// The sheet's own URL when it was fetched (a `<link>` or an
    /// `@import`); null for a `<style>` block, whose base is the page.
    base: ?[]const u8 = null,
};

pub const Keyframe = struct { offset: f64, declarations: []const Declaration };
pub const Keyframes = struct { name: []const u8, frames: []const Keyframe };

/// The keyframes named `name` across the sheets: the last declared.
pub fn keyframesNamed(sheets: []const Sheet, name: []const u8) ?Keyframes {
    var found: ?Keyframes = null;
    for (sheets) |sh| for (sh.keyframes) |k| if (std.mem.eql(u8, k.name, name)) {
        found = k;
    };
    return found;
}

/// Whether any sheet's selectors depend on the interaction state.
pub fn sheetsInteractive(sheets: []const Sheet) bool {
    for (sheets) |sh| if (sh.interactive) return true;
    return false;
}

/// A deep copy of a sheet into `a`: parse a sheet through a scratch
/// arena — its tokens, blocks and re-flattened token lists are ten
/// times the rules that come out (Wikipedia's 198 KB bundle held
/// 13 MB live, 2026-09-18) — and keep only this in the document's.
pub fn cloneSheet(a: std.mem.Allocator, sheet: Sheet) Error!Sheet {
    const rules = try a.alloc(Rule, sheet.rules.len);
    for (sheet.rules, 0..) |r, i| {
        const decls = try a.alloc(Declaration, r.declarations.len);
        for (r.declarations, 0..) |d, j| decls[j] = .{ .prop = d.prop, .important = d.important, .name = if (d.name.len > 0) try a.dupe(u8, d.name) else "", .value = switch (d.value) {
            .values => |v| .{ .values = try css.cloneValues(a, v) },
            .custom => |v| .{ .custom = try css.cloneValues(a, v) },
            .pending => |v| .{ .pending = try css.cloneValues(a, v) },
            else => d.value,
        } };
        rules[i] = .{ .selector = try selectors.cloneComplex(a, r.selector), .specificity = r.specificity, .declarations = decls, .layer = r.layer };
    }
    const imports = try a.alloc([]const u8, sheet.imports.len);
    for (sheet.imports, 0..) |u, i| imports[i] = try a.dupe(u8, u);
    const faces = try a.alloc(FontFace, sheet.font_faces.len);
    for (sheet.font_faces, 0..) |f, i| faces[i] = .{ .family = try a.dupe(u8, f.family), .src = try a.dupe(u8, f.src), .base = if (f.base) |b| try a.dupe(u8, b) else null };
    const kfs = try a.alloc(Keyframes, sheet.keyframes.len);
    for (sheet.keyframes, 0..) |k, i| {
        const frames = try a.alloc(Keyframe, k.frames.len);
        for (k.frames, 0..) |fr, j| {
            const decls = try a.alloc(Declaration, fr.declarations.len);
            for (fr.declarations, 0..) |d, m| decls[m] = .{ .prop = d.prop, .important = d.important, .name = if (d.name.len > 0) try a.dupe(u8, d.name) else "", .value = switch (d.value) {
                .values => |v| .{ .values = try css.cloneValues(a, v) },
                .custom => |v| .{ .custom = try css.cloneValues(a, v) },
                .pending => |v| .{ .pending = try css.cloneValues(a, v) },
                else => d.value,
            } };
            frames[j] = .{ .offset = fr.offset, .declarations = decls };
        }
        kfs[i] = .{ .name = try a.dupe(u8, k.name), .frames = frames };
    }
    return .{ .origin = sheet.origin, .rules = rules, .imports = imports, .font_faces = faces, .keyframes = kfs, .interactive = sheet.interactive, .base = if (sheet.base) |b| try a.dupe(u8, b) else null };
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
    var list: std.ArrayList([]const u8) = .empty;
    return parseSheetLayered(a, text, origin, env, base, .{ .list = &list, .a = a });
}

/// A sheet's cascade layers by name, in order of first mention; shared
/// by the pieces of a sheet parsed in pieces, so it lives where they
/// are kept.
const Layers = struct { list: *std.ArrayList([]const u8), a: std.mem.Allocator };

fn parseSheetLayered(a: std.mem.Allocator, text: []const u8, origin: Origin, env: Env, base: ?[]const u8, layers: Layers) Error!Sheet {
    var p = try css.Parser.init(a, text, false);
    const rules = try p.parseStylesheetDirect();
    var out: std.ArrayList(Rule) = .empty;
    var imports: std.ArrayList([]const u8) = .empty;
    var faces: std.ArrayList(FontFace) = .empty;
    var kfs: std.ArrayList(Keyframes) = .empty;
    // The per-block parsers below share the sheet parser's value stack.
    try collectRulesFaces(a, rules, env, &out, &imports, &faces, &kfs, p.scratchOf(), layers, "");
    if (base != null) for (faces.items) |*f| {
        f.base = base;
    };
    var interactive = false;
    for (out.items) |r| if (selectors.isInteractive(r.selector)) {
        interactive = true;
        break;
    };
    return .{ .origin = origin, .rules = out.items, .imports = imports.items, .font_faces = faces.items, .keyframes = kfs.items, .interactive = interactive, .base = base };
}

/// A sheet's `@import`s fetched and appended before it (an imported
/// sheet's rules come first, as the cascade orders them), then the
/// sheet itself; a chain deeper than `max_import_depth` or a fetch that
/// fails leaves that import out, never the sheet.
/// Every id, class, tag and attribute name a document uses.
const DocKeys = struct {
    set: std.StringHashMapUnmanaged(void) = .empty,
    /// Quirks mode matches classes and ids ignoring case.
    fold: bool = false,

    fn of(a: std.mem.Allocator, doc: *const Document) Error!DocKeys {
        var k: DocKeys = .{ .fold = doc.quirks == .quirks };
        var w = doc.walk(dom.document_id);
        while (w.next()) |id| {
            const n = doc.get(id);
            if (n.kind != .element) continue;
            try k.put(a, 't', n.name, true);
            for (n.attrs.items) |at| {
                try k.put(a, 'a', at.name, true);
                // `name=value`, for `[name=value]` (short values only).
                if (at.value.len < 128 and at.name.len < 64) {
                    var buf: [200]u8 = undefined;
                    const nv = std.fmt.bufPrint(&buf, "{s}={s}", .{ at.name, at.value }) catch continue;
                    try k.put(a, 'v', nv, false);
                }
                if (std.mem.eql(u8, at.name, "id")) try k.put(a, '#', at.value, k.fold);
                if (std.mem.eql(u8, at.name, "class")) {
                    var it = std.mem.tokenizeAny(u8, at.value, " \t\r\n\x0c");
                    while (it.next()) |c| try k.put(a, '.', c, k.fold);
                }
            }
        }
        return k;
    }

    fn key(buf: []u8, kind: u8, name: []const u8, lower: bool) ?[]const u8 {
        if (name.len + 1 > buf.len) return null;
        buf[0] = kind;
        for (name, 0..) |c, i| buf[i + 1] = if (lower) std.ascii.toLower(c) else c;
        return buf[0 .. name.len + 1];
    }

    fn put(k: *DocKeys, a: std.mem.Allocator, kind: u8, name: []const u8, lower: bool) Error!void {
        var buf: [256]u8 = undefined;
        const kk = key(&buf, kind, name, lower) orelse return;
        if (k.set.contains(kk)) return;
        try k.set.put(a, try a.dupe(u8, kk), {});
    }

    fn has(k: *const DocKeys, kind: u8, name: []const u8, lower: bool) bool {
        var buf: [256]u8 = undefined;
        const kk = key(&buf, kind, name, lower) orelse return true;
        return k.set.contains(kk);
    }

    /// Whether a selector could match anything here: each compound's
    /// ids, classes, tags and attribute names must occur somewhere.
    fn couldMatch(k: *const DocKeys, c: selectors.Complex) bool {
        for (c.compounds) |comp| for (comp.simples) |sm| switch (sm) {
            .id => |v| if (!k.has('#', v, k.fold)) return false,
            .class => |v| if (!k.has('.', v, k.fold)) return false,
            .type => |v| if (!std.mem.eql(u8, v, "*") and !k.has('t', v, true)) return false,
            .attr => |at| {
                if (!k.has('a', at.name, true)) return false;
                if (at.op == .eq and !at.insensitive and at.value.len < 128 and at.name.len < 64) {
                    var buf: [200]u8 = undefined;
                    const nv = std.fmt.bufPrint(&buf, "{s}={s}", .{ at.name, at.value }) catch return true;
                    if (!k.has('v', nv, false)) return false;
                }
            },
            else => {},
        };
        return true;
    }
};

/// A keeper that first drops the rules that cannot match the document,
/// then hands the sheet to the real keeper (if any).
const Filter = struct {
    has: DocKeys,
    inner: ?Keep,

    fn keepFn(ctx: *anyopaque, sheet: Sheet) Error!Sheet {
        const f: *Filter = @ptrCast(@alignCast(ctx));
        var s = sheet;
        // Filtered in place: the sheet's own rule list, parsed just now.
        const rules = @constCast(sheet.rules);
        var n: usize = 0;
        for (rules) |r| {
            // Custom properties on the root go wherever the root does;
            // everything else is judged by its selector.
            if (!f.has.couldMatch(r.selector)) continue;
            rules[n] = r;
            n += 1;
        }
        s.rules = rules[0..n];
        return if (f.inner) |k| k.keep(k.ctx, s) else s;
    }
};

/// A sheet this big is parsed in pieces when its rules are kept
/// elsewhere: a parse holds ~20 times the text (GitHub sends 700 KB).
const piece_bytes = 64 << 10;

/// An author sheet's text into the list: whole, or — when a keeper
/// copies each parse out and frees the scratch — in pieces cut at
/// top-level rule boundaries, sharing one layer registry.
fn appendSheetText(a: std.mem.Allocator, sheets: *std.ArrayList(Sheet), text: []const u8, env: Env, base: ?[]const u8, loader: ?Loader, keep: ?Keep) Error!void {
    const k = keep orelse return appendSheetWithImports(a, sheets, try parseSheetAt(a, text, .author, env, base), env, loader, keep, 0);
    const pieces = (@as(*Filter, @ptrCast(@alignCast(k.ctx)))).inner != null;
    if (text.len <= piece_bytes or !pieces) return appendSheetWithImports(a, sheets, try parseSheetAt(a, text, .author, env, base), env, loader, keep, 0);
    const list = try k.a.create(std.ArrayList([]const u8));
    list.* = .empty;
    const layers: Layers = .{ .list = list, .a = k.a };
    var start: usize = 0;
    var first = true;
    // A wrapper (`@layer x`, `@media …`) a piece ended inside, reopened
    // at the next piece's start.
    var wrapper: ?[]const u8 = null;
    while (start < text.len) {
        const piece = nextPiece(text, start, wrapper);
        const body = text[start..piece.end];
        const piece_text = if (wrapper == null and piece.open == null) body else try std.mem.concat(a, u8, &.{ if (wrapper) |w| w else "", if (wrapper != null) "{" else "", body, if (piece.open != null) "}" else "" });
        const parsed = try parseSheetLayered(a, piece_text, .author, env, base, layers);
        // The first piece carries the `@import`s; the rest are rules.
        if (first) try appendSheetWithImports(a, sheets, parsed, env, loader, keep, 0) else try sheets.append(k.a, try k.keep(k.ctx, parsed));
        first = false;
        start = piece.end;
        // The prelude is a slice of the text, which outlives the scratch.
        wrapper = piece.open;
    }
}

const Piece = struct { end: usize, open: ?[]const u8 };

/// Where a piece starting at `start` ends: past the first top-level `}`
/// (or `;`) after `piece_bytes` of text — or, inside a wrapping at-rule
/// of rules, past the first `}` that closes one of its rules, the
/// wrapper then left open (`open`, its prelude) for the next piece to
/// reopen. Strings and comments are skipped.
fn nextPiece(text: []const u8, start: usize, wrapper_in: ?[]const u8) Piece {
    var depth: usize = if (wrapper_in != null) 1 else 0;
    var wrapper: ?[]const u8 = wrapper_in;
    var boundary = start;
    var i = start;
    while (i < text.len) : (i += 1) {
        const c = text[i];
        switch (c) {
            '/' => if (i + 1 < text.len and text[i + 1] == '*') {
                i = if (std.mem.indexOfPos(u8, text, i + 2, "*/")) |e| e + 1 else text.len;
            },
            '"', '\'' => {
                i += 1;
                while (i < text.len and text[i] != c) : (i += 1) {
                    if (text[i] == '\\') i += 1;
                }
            },
            '{' => {
                if (depth == 0) {
                    const prelude = std.mem.trim(u8, text[boundary..i], " \t\r\n");
                    wrapper = if (isRuleWrapper(prelude)) prelude else null;
                }
                depth += 1;
            },
            '}' => {
                if (depth > 0) depth -= 1;
                if (depth == 0) {
                    boundary = i + 1;
                    wrapper = null;
                    if (i - start >= piece_bytes) return .{ .end = i + 1, .open = null };
                } else if (depth == 1 and wrapper != null and i - start >= piece_bytes) {
                    return .{ .end = i + 1, .open = wrapper };
                }
            },
            ';' => if (depth == 0) {
                boundary = i + 1;
                if (i - start >= piece_bytes) return .{ .end = i + 1, .open = null };
            },
            else => {},
        }
    }
    return .{ .end = text.len, .open = null };
}

/// An at-rule whose block holds rules, safe to close and reopen.
fn isRuleWrapper(prelude: []const u8) bool {
    const names = [_][]const u8{ "@layer", "@media", "@supports", "@container" };
    for (names) |n| if (std.ascii.startsWithIgnoreCase(prelude, n)) return true;
    return false;
}

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

/// A stylesheet's text without a CDATA section's markers around it.
fn stripCdata(text: []const u8) []const u8 {
    const t = std.mem.trim(u8, text, " \t\r\n");
    if (std.mem.startsWith(u8, t, "<![CDATA[") and std.mem.endsWith(u8, t, "]]>")) return t["<![CDATA[".len .. t.len - "]]>".len];
    return text;
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
    var kfs: std.ArrayList(Keyframes) = .empty;
    var scratch: css.Scratch = .empty;
    var layer_list: std.ArrayList([]const u8) = .empty;
    try collectRulesFaces(a, rules, env, out, imports, &faces, &kfs, &scratch, .{ .list = &layer_list, .a = a }, "");
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

/// A layer's index by its full name, registered on first mention.
fn layerIndex(layers: Layers, name: []const u8) Error!u8 {
    for (layers.list.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return @intCast(i);
    if (layers.list.items.len >= unlayered - 1) return unlayered - 1;
    try layers.list.append(layers.a, try layers.a.dupe(u8, name));
    return @intCast(layers.list.items.len - 1);
}

fn collectRulesFaces(a: std.mem.Allocator, rules: []const css.Rule, env: Env, out: *std.ArrayList(Rule), imports: *std.ArrayList([]const u8), faces: *std.ArrayList(FontFace), kf: *std.ArrayList(Keyframes), scratch: *css.Scratch, layers: Layers, layer_prefix: []const u8) Error!void {
    for (rules) |r| switch (r) {
        .err => {},
        .qualified => |q| if (q.items) |items| try addQualifiedItems(a, q.prelude, items, out) else try addQualified(a, q, out, scratch),
        .at => |at| {
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(at.name, "media")) {
                const q = try media.Query.parseValues(a, at.prelude);
                if (!q.matches(env)) continue;
                if (at.rules) |rs| {
                    try collectRulesFaces(a, rs, env, out, imports, faces, kf, scratch, layers, layer_prefix);
                    continue;
                }
                const block = at.block orelse continue;
                try collectRulesFaces(a, try rulesOfBlock(a, block, scratch), env, out, imports, faces, kf, scratch, layers, layer_prefix);
            } else if (eq(at.name, "keyframes") or eq(at.name, "-webkit-keyframes")) {
                var name: ?[]const u8 = null;
                for (at.prelude) |v| {
                    if (v == .token and v.token == .ident) name = v.token.ident;
                    if (v == .token and v.token == .string) name = v.token.string;
                }
                const kname = name orelse continue;
                const rs = at.rules orelse blk: {
                    const block = at.block orelse continue;
                    break :blk try rulesOfBlock(a, block, scratch);
                };
                var frames: std.ArrayList(Keyframe) = .empty;
                for (rs) |fr| {
                    if (fr != .qualified) continue;
                    const q = fr.qualified;
                    // The selector list: `from`, `to`, percentages.
                    var offsets: [16]f64 = undefined;
                    var no: usize = 0;
                    for (q.prelude) |v| {
                        if (no == offsets.len) break;
                        if (v == .token and v.token == .ident) {
                            if (eq(v.token.ident, "from")) {
                                offsets[no] = 0;
                                no += 1;
                            } else if (eq(v.token.ident, "to")) {
                                offsets[no] = 1;
                                no += 1;
                            }
                        } else if (v == .token and v.token == .percentage) {
                            offsets[no] = @max(0, @min(1, v.token.percentage.value / 100));
                            no += 1;
                        }
                    }
                    if (no == 0) continue;
                    const items = q.items orelse blk: {
                        var bp = try css.Parser.fromValuesScratch(a, q.block, scratch);
                        break :blk try bp.parseBlockContents();
                    };
                    var decls: std.ArrayList(Declaration) = .empty;
                    for (items) |item| if (item == .declaration) try expand(a, item.declaration, &decls);
                    for (offsets[0..no]) |off| try frames.append(a, .{ .offset = off, .declarations = decls.items });
                }
                // In offset order (a stable sort keeps a repeated offset's
                // later block later).
                std.mem.sort(Keyframe, frames.items, {}, struct {
                    fn lt(_: void, x: Keyframe, y: Keyframe) bool {
                        return x.offset < y.offset;
                    }
                }.lt);
                try kf.append(a, .{ .name = kname, .frames = frames.items });
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
            } else if (eq(at.name, "layer")) {
                // `@layer a, b;` orders layers; `@layer a { … }` holds rules
                // (an unnamed one is a layer of its own).
                var names: std.ArrayList([]const u8) = .empty;
                for (at.prelude) |v| if (v == .token and v.token == .ident) {
                    const full = if (layer_prefix.len > 0) try std.mem.concat(a, u8, &.{ layer_prefix, ".", v.token.ident }) else v.token.ident;
                    try names.append(a, full);
                };
                const rs = at.rules orelse {
                    for (names.items) |n| _ = try layerIndex(layers, n);
                    continue;
                };
                const name = if (names.items.len > 0) names.items[0] else try std.fmt.allocPrint(a, "{s}.#anon{d}", .{ layer_prefix, layers.list.items.len });
                const idx = try layerIndex(layers, name);
                const first = out.items.len;
                try collectRulesFaces(a, rs, env, out, imports, faces, kf, scratch, layers, name);
                for (out.items[first..]) |*rule| if (rule.layer == unlayered) {
                    rule.layer = idx;
                };
            } else if (eq(at.name, "container") or eq(at.name, "scope")) {
                // A container query is taken against the viewport (the
                // nearest approximation without container sizes); a scope
                // as if unscoped.
                if (eq(at.name, "container")) {
                    var k: usize = 0;
                    while (k < at.prelude.len and (isWs(at.prelude[k]) or (at.prelude[k] == .token and at.prelude[k].token == .ident and !std.ascii.eqlIgnoreCase(at.prelude[k].token.ident, "not")))) k += 1;
                    const q = media.Query.parseValues(a, at.prelude[k..]) catch continue;
                    if (!q.matches(env)) continue;
                }
                if (at.rules) |rs| try collectRulesFaces(a, rs, env, out, imports, faces, kf, scratch, layers, layer_prefix);
            } else if (eq(at.name, "supports")) {
                if (!supportsMatches(a, at.prelude)) continue;
                if (at.rules) |rs| {
                    try collectRulesFaces(a, rs, env, out, imports, faces, kf, scratch, layers, layer_prefix);
                    continue;
                }
                const block = at.block orelse continue;
                try collectRulesFaces(a, try rulesOfBlock(a, block, scratch), env, out, imports, faces, kf, scratch, layers, layer_prefix);
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
    // `-webkit-mask…` is `mask…`, as every engine now takes it; a
    // logical property is its physical one (left to right, top down).
    const name = logicalToPhysical(if (std.ascii.startsWithIgnoreCase(d.name, "-webkit-mask")) d.name[8..] else d.name);
    const vals = try nonWs(a, d.value);
    // A custom property: any value, even none, kept for `var()`.
    if (name.len > 2 and name[0] == '-' and name[1] == '-') {
        const value: Declared = if (wideKeyword(vals)) |w| w else .{ .custom = vals };
        return decls.append(a, .{ .prop = .display, .value = value, .important = d.important, .name = name });
    }
    if (vals.len == 0) return;
    if (containsVar(vals)) {
        // Unchecked until computed-value time; a shorthand stands for
        // each of its longhands (found by expanding `initial`).
        if (Prop.parse(name)) |p| return decls.append(a, .{ .prop = p, .value = .{ .pending = vals }, .important = d.important });
        var longhands: std.ArrayList(Declaration) = .empty;
        try expand(a, .{ .name = name, .value = &.{.{ .token = .{ .ident = "initial" } }}, .important = false }, &longhands);
        for (longhands.items) |lh| try decls.append(a, .{ .prop = lh.prop, .value = .{ .pending = vals }, .important = d.important, .name = name });
        return;
    }
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
        const bg_props = [_]Prop{ .background_color, .background_image, .background_position_x, .background_position_y, .background_size, .background_repeat, .background_attachment };
        if (wide) {
            for (bg_props) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        // The layers: the image from whichever has one (a url before a
        // gradient), position, size and repeat from that layer, the
        // colour from the last. What a layer does not say is reset.
        var layers: std.ArrayList([]const css.Value) = .empty;
        var start: usize = 0;
        for (vals, 0..) |v, i| if (v == .token and v.token == .comma) {
            try layers.append(a, vals[start..i]);
            start = i + 1;
        };
        try layers.append(a, vals[start..]);
        var chosen: ?usize = null;
        for (layers.items, 0..) |layer, li| for (layer) |v| if (urlOf(v) != null) {
            if (chosen == null) chosen = li;
        };
        if (chosen == null) for (layers.items, 0..) |layer, li| for (layer) |v| if (isGradient(v)) {
            if (chosen == null) chosen = li;
        };
        const last = layers.items[layers.items.len - 1];
        var col: []const css.Value = &.{};
        var ncol: usize = 0;
        for (last) |v| if (color.parseValue(v) != null and urlOf(v) == null) {
            col = try single(a, v);
            ncol += 1;
        };
        // Two colours in a layer (`red pink`) make the whole declaration
        // invalid (Acid2's parser line).
        if (ncol > 1) return;
        try push(a, decls, .background_color, col, d.important);
        var image: []const css.Value = &.{};
        var pos: std.ArrayList(css.Value) = .empty;
        var size: []const css.Value = &.{};
        var repeat: std.ArrayList(css.Value) = .empty;
        var attachment: []const css.Value = &.{};
        if (chosen) |li| {
            const layer = layers.items[li];
            var k: usize = 0;
            while (k < layer.len) : (k += 1) {
                const v = layer[k];
                if (urlOf(v) != null or isGradient(v)) {
                    image = try single(a, v);
                } else if (v == .token and v.token == .delim and v.token.delim == '/') {
                    // The size follows the position.
                    var e = k + 1;
                    while (e < layer.len and e < k + 3 and (lengthAuto(layer[e], 16, .{ .width = 0, .height = 0 }) != null or (ident(layer[e]) != null and (eq(ident(layer[e]).?, "cover") or eq(ident(layer[e]).?, "contain") or eq(ident(layer[e]).?, "auto"))))) e += 1;
                    size = layer[k + 1 .. e];
                    k = e - 1;
                } else if (ident(v)) |w| {
                    if (eq(w, "repeat") or eq(w, "repeat-x") or eq(w, "repeat-y") or eq(w, "no-repeat") or eq(w, "space") or eq(w, "round")) {
                        try repeat.append(a, v);
                    } else if (eq(w, "fixed") or eq(w, "scroll") or eq(w, "local")) {
                        attachment = try single(a, v);
                    } else if (eq(w, "left") or eq(w, "right") or eq(w, "top") or eq(w, "bottom") or eq(w, "center")) {
                        try pos.append(a, v);
                    }
                } else if (v == .token and (v.token == .dimension or v.token == .percentage or v.token == .number)) {
                    try pos.append(a, v);
                }
            }
        }
        try push(a, decls, .background_image, image, d.important);
        if (try splitPosition(a, pos.items)) |xy| {
            try push(a, decls, .background_position_x, xy[0], d.important);
            try push(a, decls, .background_position_y, xy[1], d.important);
        } else {
            try push(a, decls, .background_position_x, &.{}, d.important);
            try push(a, decls, .background_position_y, &.{}, d.important);
        }
        try push(a, decls, .background_size, size, d.important);
        try push(a, decls, .background_repeat, repeat.items, d.important);
        try push(a, decls, .background_attachment, attachment, d.important);
        return;
    }
    if (eq(name, "transition")) {
        const t_props = [_]Prop{ .transition_property, .transition_duration, .transition_delay, .transition_timing_function };
        if (wide) {
            for (t_props) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        // Per item: the first time is the duration, the second the
        // delay, a timing keyword or function the timing, any other
        // identifier the property.
        var props: std.ArrayList(css.Value) = .empty;
        var durs: std.ArrayList(css.Value) = .empty;
        var delays: std.ArrayList(css.Value) = .empty;
        var fns: std.ArrayList(css.Value) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= vals.len) : (i += 1) {
            if (i < vals.len and !(vals[i] == .token and vals[i].token == .comma)) continue;
            const item = vals[start..i];
            start = i + 1;
            var prop: ?css.Value = null;
            var dur: ?css.Value = null;
            var delay: ?css.Value = null;
            var fnv: ?css.Value = null;
            for (item) |v| {
                if (isWs(v)) continue;
                if (timeMs(v) != null) {
                    if (dur == null) dur = v else if (delay == null) delay = v else return;
                } else if (timingOf(v) != null) {
                    if (fnv != null) return;
                    fnv = v;
                } else if (ident(v) != null) {
                    if (prop != null) return;
                    prop = v;
                } else return;
            }
            if (prop == null and dur == null and delay == null and fnv == null) continue;
            const comma: css.Value = .{ .token = .comma };
            if (props.items.len > 0) {
                try props.append(a, comma);
                try durs.append(a, comma);
                try delays.append(a, comma);
                try fns.append(a, comma);
            }
            try props.append(a, prop orelse .{ .token = .{ .ident = "all" } });
            try durs.append(a, dur orelse .{ .token = .{ .dimension = .{ .num = .{ .value = 0, .integer = true, .repr = "0" }, .unit = "s" } } });
            try delays.append(a, delay orelse .{ .token = .{ .dimension = .{ .num = .{ .value = 0, .integer = true, .repr = "0" }, .unit = "s" } } });
            try fns.append(a, fnv orelse .{ .token = .{ .ident = "ease" } });
        }
        try push(a, decls, .transition_property, props.items, d.important);
        try push(a, decls, .transition_duration, durs.items, d.important);
        try push(a, decls, .transition_delay, delays.items, d.important);
        try push(a, decls, .transition_timing_function, fns.items, d.important);
        return;
    }
    if (eq(name, "animation")) {
        const an_props = [_]Prop{ .animation_name, .animation_duration, .animation_delay, .animation_timing_function, .animation_iteration_count, .animation_direction, .animation_fill_mode, .animation_play_state };
        if (wide) {
            for (an_props) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        // The first animation of the list only.
        var item: []const css.Value = vals;
        for (vals, 0..) |v, i| if (v == .token and v.token == .comma) {
            item = vals[0..i];
            break;
        };
        var name_v: ?css.Value = null;
        var dur: ?css.Value = null;
        var delay: ?css.Value = null;
        var fnv: ?css.Value = null;
        var count: ?css.Value = null;
        var dir: ?css.Value = null;
        var fill: ?css.Value = null;
        var play: ?css.Value = null;
        for (item) |v| {
            if (isWs(v)) continue;
            if (timeMs(v) != null) {
                if (dur == null) dur = v else if (delay == null) delay = v else return;
            } else if (timingOf(v) != null) {
                if (fnv != null) return;
                fnv = v;
            } else if (v == .token and v.token == .number) {
                if (count != null) return;
                count = v;
            } else if (ident(v)) |w| {
                if (eq(w, "infinite") and count == null) {
                    count = v;
                } else if (keyword(AnimationDirection, v) != null and dir == null) {
                    dir = v;
                } else if (keyword(AnimationFill, v) != null and fill == null) {
                    fill = v;
                } else if ((eq(w, "running") or eq(w, "paused")) and play == null) {
                    play = v;
                } else if (name_v == null) {
                    name_v = v;
                } else return;
            } else if (v == .token and v.token == .string) {
                if (name_v != null) return;
                name_v = v;
            } else return;
        }
        const zero: css.Value = .{ .token = .{ .dimension = .{ .num = .{ .value = 0, .integer = true, .repr = "0" }, .unit = "s" } } };
        try push(a, decls, .animation_name, try single(a, name_v orelse .{ .token = .{ .ident = "none" } }), d.important);
        try push(a, decls, .animation_duration, try single(a, dur orelse zero), d.important);
        try push(a, decls, .animation_delay, try single(a, delay orelse zero), d.important);
        try push(a, decls, .animation_timing_function, try single(a, fnv orelse .{ .token = .{ .ident = "ease" } }), d.important);
        try push(a, decls, .animation_iteration_count, try single(a, count orelse .{ .token = .{ .number = .{ .value = 1, .integer = true, .repr = "1" } } }), d.important);
        try push(a, decls, .animation_direction, try single(a, dir orelse .{ .token = .{ .ident = "normal" } }), d.important);
        try push(a, decls, .animation_fill_mode, try single(a, fill orelse .{ .token = .{ .ident = "none" } }), d.important);
        try push(a, decls, .animation_play_state, try single(a, play orelse .{ .token = .{ .ident = "running" } }), d.important);
        return;
    }
    if (eq(name, "mask")) {
        const mask_props = [_]Prop{ .mask_image, .mask_position_x, .mask_position_y, .mask_size, .mask_repeat };
        if (wide) {
            for (mask_props) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        // One layer's image, position / size and repeat.
        var n: usize = 0;
        while (n < vals.len and !(vals[n] == .token and vals[n].token == .comma)) n += 1;
        const layer = vals[0..n];
        var image: []const css.Value = &.{};
        var pos: std.ArrayList(css.Value) = .empty;
        var size: []const css.Value = &.{};
        var repeat: std.ArrayList(css.Value) = .empty;
        var k: usize = 0;
        while (k < layer.len) : (k += 1) {
            const v = layer[k];
            if (urlOf(v) != null or isGradient(v)) {
                image = try single(a, v);
            } else if (v == .token and v.token == .delim and v.token.delim == '/') {
                var e = k + 1;
                while (e < layer.len and e < k + 3 and (lengthAuto(layer[e], 16, .{ .width = 0, .height = 0 }) != null or (ident(layer[e]) != null and (eq(ident(layer[e]).?, "cover") or eq(ident(layer[e]).?, "contain") or eq(ident(layer[e]).?, "auto"))))) e += 1;
                size = layer[k + 1 .. e];
                k = e - 1;
            } else if (ident(v)) |w| {
                if (eq(w, "repeat") or eq(w, "repeat-x") or eq(w, "repeat-y") or eq(w, "no-repeat") or eq(w, "space") or eq(w, "round")) {
                    try repeat.append(a, v);
                } else if (eq(w, "left") or eq(w, "right") or eq(w, "top") or eq(w, "bottom") or eq(w, "center")) {
                    try pos.append(a, v);
                }
            } else if (v == .token and (v.token == .dimension or v.token == .percentage or v.token == .number)) {
                try pos.append(a, v);
            }
        }
        try push(a, decls, .mask_image, image, d.important);
        if (try splitPosition(a, pos.items)) |xy| {
            try push(a, decls, .mask_position_x, xy[0], d.important);
            try push(a, decls, .mask_position_y, xy[1], d.important);
        } else {
            try push(a, decls, .mask_position_x, &.{}, d.important);
            try push(a, decls, .mask_position_y, &.{}, d.important);
        }
        try push(a, decls, .mask_size, size, d.important);
        try push(a, decls, .mask_repeat, repeat.items, d.important);
        return;
    }
    if (eq(name, "mask-position")) {
        var n: usize = 0;
        while (n < vals.len and !(vals[n] == .token and vals[n].token == .comma)) n += 1;
        const xy = (try splitPosition(a, vals[0..n])) orelse return;
        try push(a, decls, .mask_position_x, xy[0], d.important);
        try push(a, decls, .mask_position_y, xy[1], d.important);
        return;
    }
    if (eq(name, "background-position")) {
        if (wide) {
            try push(a, decls, .background_position_x, vals, d.important);
            try push(a, decls, .background_position_y, vals, d.important);
            return;
        }
        var n: usize = 0;
        while (n < vals.len and !(vals[n] == .token and vals[n].token == .comma)) n += 1;
        const xy = (try splitPosition(a, vals[0..n])) orelse return;
        try push(a, decls, .background_position_x, xy[0], d.important);
        try push(a, decls, .background_position_y, xy[1], d.important);
        return;
    }
    if (eq(name, "border-radius")) {
        const corners = [_]Prop{ .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius };
        if (wide) {
            for (corners) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        // The horizontal radii (before any `/`), one to four.
        var n: usize = 0;
        while (n < vals.len and !(vals[n] == .token and vals[n].token == .delim and vals[n].token.delim == '/')) n += 1;
        const h = vals[0..n];
        if (h.len == 0 or h.len > 4) return;
        const idx = [_][4]usize{ .{ 0, 0, 0, 0 }, .{ 0, 1, 0, 1 }, .{ 0, 1, 2, 1 }, .{ 0, 1, 2, 3 } };
        for (corners, 0..) |p, c| try push(a, decls, p, h[idx[h.len - 1][c] .. idx[h.len - 1][c] + 1], d.important);
        return;
    }
    if (eq(name, "overflow")) {
        if (vals.len > 2) return;
        try push(a, decls, .overflow_x, vals[0..1], d.important);
        try push(a, decls, .overflow_y, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    }
    if (eq(name, "text-decoration")) {
        if (wide) return push(a, decls, .text_decoration_line, vals, d.important);
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
                // A third number can only be a unitless zero basis.
                if (grow == null) grow = v.token.number.value else if (shrink == null) shrink = v.token.number.value else if (v.token.number.value == 0 and basis == null) {
                    basis = v;
                } else return;
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
        if (wide) {
            try push(a, decls, .flex_direction, vals, d.important);
            try push(a, decls, .flex_wrap, vals, d.important);
            return;
        }
        for (vals) |v| {
            if (keyword(FlexDirection, v) != null) try push(a, decls, .flex_direction, try single(a, v), d.important) else if (keyword(FlexWrap, v) != null) try push(a, decls, .flex_wrap, try single(a, v), d.important) else return;
        }
        return;
    }
    if (eq(name, "grid-row") or eq(name, "grid-column")) {
        const row = eq(name, "grid-row");
        const start: Prop = if (row) .grid_row_start else .grid_column_start;
        const end: Prop = if (row) .grid_row_end else .grid_column_end;
        if (wide) {
            try push(a, decls, start, vals, d.important);
            try push(a, decls, end, vals, d.important);
            return;
        }
        var slash: ?usize = null;
        for (vals, 0..) |v, i| if (v == .token and v.token == .delim and v.token.delim == '/') {
            slash = i;
        };
        if (slash) |sl| {
            try push(a, decls, start, vals[0..sl], d.important);
            try push(a, decls, end, vals[sl + 1 ..], d.important);
        } else {
            try push(a, decls, start, vals, d.important);
            // A name alone ends at the same name; anything else spans one.
            const one_name = vals.len == 1 and ident(vals[0]) != null and !eq(ident(vals[0]).?, "auto");
            try push(a, decls, end, if (one_name) vals else &.{}, d.important);
        }
        return;
    }
    if (eq(name, "grid-area")) {
        const props = [_]Prop{ .grid_row_start, .grid_column_start, .grid_row_end, .grid_column_end };
        if (wide) {
            for (props) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        var parts: [4][]const css.Value = .{ &.{}, &.{}, &.{}, &.{} };
        var n: usize = 0;
        var start: usize = 0;
        for (0..vals.len + 1) |i| {
            if (i < vals.len and !(vals[i] == .token and vals[i].token == .delim and vals[i].token.delim == '/')) continue;
            if (n == 4) return;
            parts[n] = vals[start..i];
            n += 1;
            start = i + 1;
        }
        // Missing parts copy a name from their opposite, else are auto.
        const named = n >= 1 and parts[0].len == 1 and ident(parts[0][0]) != null and !eq(ident(parts[0][0]).?, "auto");
        if (n < 2) parts[1] = if (named) parts[0] else &.{};
        if (n < 3) parts[2] = if (named or (parts[0].len == 1 and ident(parts[0][0]) != null)) parts[0] else &.{};
        if (n < 4) parts[3] = if (parts[1].len == 1 and ident(parts[1][0]) != null) parts[1] else &.{};
        for (props, 0..) |p, i| try push(a, decls, p, parts[i], d.important);
        return;
    }
    if (eq(name, "grid-template")) {
        // `rows / columns` (the areas form is left to the longhands).
        if (wide) {
            for ([_]Prop{ .grid_template_rows, .grid_template_columns, .grid_template_areas }) |p| try push(a, decls, p, vals, d.important);
            return;
        }
        for (vals, 0..) |v, i| if (v == .token and v.token == .delim and v.token.delim == '/') {
            try push(a, decls, .grid_template_rows, vals[0..i], d.important);
            try push(a, decls, .grid_template_columns, vals[i + 1 ..], d.important);
            return;
        };
        return;
    }
    if (eq(name, "place-items") or eq(name, "place-self")) {
        const items = eq(name, "place-items");
        const al: Prop = if (items) .align_items else .align_self;
        const ju: Prop = if (items) .justify_items else .justify_self;
        if (vals.len == 0 or vals.len > 2) return;
        try push(a, decls, al, vals[0..1], d.important);
        try push(a, decls, ju, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    }
    // The two-sided logical shorthands: start then end.
    const pairs = [_]struct { n: []const u8, a: []const u8, b: []const u8 }{
        .{ .n = "margin-inline", .a = "margin-left", .b = "margin-right" },
        .{ .n = "margin-block", .a = "margin-top", .b = "margin-bottom" },
        .{ .n = "padding-inline", .a = "padding-left", .b = "padding-right" },
        .{ .n = "padding-block", .a = "padding-top", .b = "padding-bottom" },
        .{ .n = "inset-inline", .a = "left", .b = "right" },
        .{ .n = "inset-block", .a = "top", .b = "bottom" },
        .{ .n = "border-inline-width", .a = "border-left-width", .b = "border-right-width" },
        .{ .n = "border-block-width", .a = "border-top-width", .b = "border-bottom-width" },
        .{ .n = "border-inline-color", .a = "border-left-color", .b = "border-right-color" },
        .{ .n = "border-block-color", .a = "border-top-color", .b = "border-bottom-color" },
        .{ .n = "border-inline-style", .a = "border-left-style", .b = "border-right-style" },
        .{ .n = "border-block-style", .a = "border-top-style", .b = "border-bottom-style" },
    };
    for (pairs) |pr| if (eq(name, pr.n)) {
        if (vals.len == 0 or vals.len > 2) return;
        const pa = Prop.parse(pr.a).?;
        const pb = Prop.parse(pr.b).?;
        try push(a, decls, pa, vals[0..1], d.important);
        try push(a, decls, pb, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    };
    if (eq(name, "border-inline") or eq(name, "border-block")) {
        try expandBorder(a, vals, if (eq(name, "border-inline")) &.{ 1, 3 } else &.{ 0, 2 }, d.important, decls);
        return;
    }
    if (eq(name, "border-spacing")) {
        if (vals.len == 0 or vals.len > 2) return;
        try push(a, decls, .border_spacing_x, vals[0..1], d.important);
        try push(a, decls, .border_spacing_y, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    }
    if (eq(name, "gap")) {
        if (vals.len == 0 or vals.len > 2) return;
        try push(a, decls, .row_gap, vals[0..1], d.important);
        try push(a, decls, .column_gap, if (vals.len == 2) vals[1..2] else vals[0..1], d.important);
        return;
    }
}

/// A `url()` in either spelling: the tokenizer's url token, or the
/// function around a string.
fn urlOf(v: css.Value) ?[]const u8 {
    if (v == .token and v.token == .url) return v.token.url;
    if (v == .function and std.ascii.eqlIgnoreCase(v.function.name, "url")) {
        for (v.function.values) |x| if (x == .token and x.token == .string) return x.token.string;
    }
    return null;
}

fn isGradient(v: css.Value) bool {
    if (v != .function) return false;
    const n = v.function.name;
    return std.ascii.eqlIgnoreCase(n, "linear-gradient") or std.ascii.eqlIgnoreCase(n, "repeating-linear-gradient") or std.ascii.eqlIgnoreCase(n, "radial-gradient") or std.ascii.eqlIgnoreCase(n, "repeating-radial-gradient") or std.ascii.eqlIgnoreCase(n, "conic-gradient") or std.ascii.startsWithIgnoreCase(n, "-webkit-");
}

/// The layers of `background-image`: the first url, else the first
/// gradient that paints anything, else none. (One layer is kept: a
/// gradient under a picture is almost always a fallback or a tint.)
fn backgroundImageOf(vals: []const css.Value, font_size: f64, env: Env, a: std.mem.Allocator) ParseFail!?BackgroundImage {
    var gradient: ?BackgroundImage = null;
    var any = false;
    for (vals) |v| {
        if (v == .token and v.token == .comma) continue;
        any = true;
        if (urlOf(v)) |u| return .{ .url = u };
        if (ident(v)) |w| if (std.ascii.eqlIgnoreCase(w, "none")) continue;
        if (isGradient(v)) {
            if (gradient == null) if (try linearGradientOf(v, font_size, env, a)) |g| {
                gradient = g;
            };
            continue;
        }
        return null;
    }
    if (!any) return null;
    return gradient orelse .none;
}

/// `linear-gradient([<angle> | to <side-or-corner>,]? <stop>, …)`; a
/// gradient whose stops are all transparent is none.
fn linearGradientOf(v: css.Value, font_size: f64, env: Env, a: std.mem.Allocator) ParseFail!?BackgroundImage {
    const f = v.function;
    const repeating = std.ascii.eqlIgnoreCase(f.name, "repeating-linear-gradient");
    if (!repeating and !std.ascii.eqlIgnoreCase(f.name, "linear-gradient")) return null;
    // Split the arguments at top-level commas.
    var args: std.ArrayList([]const css.Value) = .empty;
    var start: usize = 0;
    for (f.values, 0..) |x, i| if (x == .token and x.token == .comma) {
        try args.append(a, try nonWs(a, f.values[start..i]));
        start = i + 1;
    };
    try args.append(a, try nonWs(a, f.values[start..]));
    var angle: f64 = 180;
    var first: usize = 0;
    if (args.items.len > 0 and args.items[0].len > 0) {
        const head = args.items[0];
        if (head[0] == .token and head[0].token == .dimension) {
            const d = head[0].token.dimension;
            const eq = std.ascii.eqlIgnoreCase;
            angle = if (eq(d.unit, "deg")) d.num.value else if (eq(d.unit, "rad")) d.num.value * 180 / std.math.pi else if (eq(d.unit, "turn")) d.num.value * 360 else if (eq(d.unit, "grad")) d.num.value * 0.9 else return null;
            first = 1;
        } else if (ident(head[0])) |w| if (std.ascii.eqlIgnoreCase(w, "to")) {
            var dx: f64 = 0;
            var dy: f64 = 0;
            for (head[1..]) |side| {
                const s = ident(side) orelse return null;
                const eq = std.ascii.eqlIgnoreCase;
                if (eq(s, "top")) dy = -1 else if (eq(s, "bottom")) dy = 1 else if (eq(s, "left")) dx = -1 else if (eq(s, "right")) dx = 1 else return null;
            }
            angle = std.math.atan2(dx, -dy) * 180 / std.math.pi;
            first = 1;
        };
    }
    var stops: std.ArrayList(Stop) = .empty;
    var visible = false;
    for (args.items[first..]) |arg| {
        if (arg.len == 0) continue;
        const c = switch (color.parseValue(arg[0]) orelse return null) {
            .color => |col| col,
            .current => Color.rgb(0, 0, 0),
        };
        if (c.a > 0) visible = true;
        const at: ?LengthPercent = if (arg.len > 1) lengthPercent(arg[1], font_size, env) else null;
        try stops.append(a, .{ .color = c, .at = at });
        if (arg.len > 2) if (lengthPercent(arg[2], font_size, env)) |at2| try stops.append(a, .{ .color = c, .at = at2 });
    }
    if (stops.items.len == 0) return null;
    if (!visible) return .none;
    return .{ .linear = .{ .angle = angle, .stops = stops.items, .repeating = repeating } };
}

fn backgroundSizeOf(vals: []const css.Value, font_size: f64, env: Env) ?BackgroundSize {
    // The first layer's.
    var n: usize = 0;
    while (n < vals.len and !(vals[n] == .token and vals[n].token == .comma)) n += 1;
    const layer = vals[0..n];
    if (layer.len == 0 or layer.len > 2) return null;
    if (ident(layer[0])) |w| {
        if (std.ascii.eqlIgnoreCase(w, "cover")) return .cover;
        if (std.ascii.eqlIgnoreCase(w, "contain")) return .contain;
    }
    var out: [2]LengthAuto = .{ .auto, .auto };
    for (layer, 0..) |x, i| out[i] = lengthAuto(x, font_size, env) orelse return null;
    if (layer.len == 1 and out[0] == .auto) return .auto;
    return .{ .size = out };
}

fn backgroundRepeatOf(vals: []const css.Value) ?[2]bool {
    var n: usize = 0;
    while (n < vals.len and !(vals[n] == .token and vals[n].token == .comma)) n += 1;
    const layer = vals[0..n];
    if (layer.len == 0 or layer.len > 2) return null;
    const eq = std.ascii.eqlIgnoreCase;
    const w0 = ident(layer[0]) orelse return null;
    if (layer.len == 1) {
        if (eq(w0, "repeat-x")) return .{ true, false };
        if (eq(w0, "repeat-y")) return .{ false, true };
        if (eq(w0, "repeat") or eq(w0, "space") or eq(w0, "round")) return .{ true, true };
        if (eq(w0, "no-repeat")) return .{ false, false };
        return null;
    }
    const w1 = ident(layer[1]) orelse return null;
    const r = struct {
        fn f(w: []const u8) ?bool {
            if (std.ascii.eqlIgnoreCase(w, "no-repeat")) return false;
            if (std.ascii.eqlIgnoreCase(w, "repeat") or std.ascii.eqlIgnoreCase(w, "space") or std.ascii.eqlIgnoreCase(w, "round")) return true;
            return null;
        }
    }.f;
    return .{ r(w0) orelse return null, r(w1) orelse return null };
}

/// One axis of `background-position` (its longhands take a keyword or a
/// length; `right 10px` style offsets are taken from their side).
fn positionComponent(vals: []const css.Value, horizontal: bool, font_size: f64, env: Env) ?LengthPercent {
    var n: usize = 0;
    while (n < vals.len and !(vals[n] == .token and vals[n].token == .comma)) n += 1;
    const layer = vals[0..n];
    if (layer.len == 0 or layer.len > 2) return null;
    const eq = std.ascii.eqlIgnoreCase;
    if (ident(layer[0])) |w| {
        const pct: f64 = if (eq(w, "left") or eq(w, "top")) 0 else if (eq(w, "center")) 50 else if (eq(w, "right") or eq(w, "bottom")) 100 else return null;
        _ = horizontal;
        if (layer.len == 2) {
            const off = lengthPx(layer[1], font_size, env) orelse return null;
            // An offset from the far side cannot be one length; its
            // nearest reading keeps the side.
            return if (pct == 100) .{ .percent = 100 } else .{ .px = off };
        }
        return .{ .percent = pct };
    }
    return lengthPercent(layer[0], font_size, env);
}

/// `background-position`'s one or two components (with keywords in
/// either order) as the x and y longhands' values.
fn splitPosition(a: std.mem.Allocator, layer: []const css.Value) Error!?[2][]const css.Value {
    if (layer.len == 0) return null;
    const eq = std.ascii.eqlIgnoreCase;
    if (layer.len == 1) {
        if (ident(layer[0])) |w| {
            if (eq(w, "top") or eq(w, "bottom")) return .{ try single(a, .{ .token = .{ .ident = "center" } }), layer[0..1] };
            return .{ layer[0..1], try single(a, .{ .token = .{ .ident = "center" } }) };
        }
        return .{ layer[0..1], try single(a, .{ .token = .{ .ident = "center" } }) };
    }
    if (layer.len == 2) {
        // `top left` is `left top`.
        if (ident(layer[0])) |w| if (eq(w, "top") or eq(w, "bottom")) return .{ layer[1..2], layer[0..1] };
        return .{ layer[0..1], layer[1..2] };
    }
    if (layer.len == 4) return .{ layer[0..2], layer[2..4] };
    return null;
}

/// The sum of a `transform` list's translations (`translate*()` and a
/// matrix's last two numbers); the other functions are accepted and
/// not applied.
fn translationOf(vals: []const css.Value, font_size: f64, env: Env) ?[2]LengthPercent {
    if (vals.len == 1) if (ident(vals[0])) |w| if (std.ascii.eqlIgnoreCase(w, "none")) return .{ .{ .px = 0 }, .{ .px = 0 } };
    var out: [2]Mix = .{ .{ .px = 0, .pct = 0 }, .{ .px = 0, .pct = 0 } };
    for (vals) |v| {
        if (v != .function) return null;
        const f = v.function;
        var args: [6]css.Value = undefined;
        var n: usize = 0;
        for (f.values) |x| {
            if (isWs(x) or (x == .token and x.token == .comma)) continue;
            if (n == args.len) return null;
            args[n] = x;
            n += 1;
        }
        const eq = std.ascii.eqlIgnoreCase;
        const add = struct {
            fn plus(m: *Mix, x: css.Value, fs: f64, e: Env) bool {
                const lp = lengthPercent(x, fs, e) orelse return false;
                switch (lp) {
                    .px => |px| m.px += px,
                    .percent => |pc| m.pct += pc,
                    .calc => |c| {
                        m.px += c.px;
                        m.pct += c.pct;
                    },
                }
                return true;
            }
        }.plus;
        if (eq(f.name, "translate") or eq(f.name, "translate3d")) {
            if (n < 1 or !add(&out[0], args[0], font_size, env)) return null;
            if (n >= 2 and !add(&out[1], args[1], font_size, env)) return null;
        } else if (eq(f.name, "translatex")) {
            if (n != 1 or !add(&out[0], args[0], font_size, env)) return null;
        } else if (eq(f.name, "translatey")) {
            if (n != 1 or !add(&out[1], args[0], font_size, env)) return null;
        } else if (eq(f.name, "matrix")) {
            if (n != 6) return null;
            for (args[4..6], 0..) |x, i| {
                if (x != .token or x.token != .number) return null;
                out[i].px += x.token.number.value * px_scale;
            }
        } else if (!(eq(f.name, "scale") or eq(f.name, "scalex") or eq(f.name, "scaley") or eq(f.name, "rotate") or eq(f.name, "rotatez") or eq(f.name, "skew") or eq(f.name, "skewx") or eq(f.name, "skewy") or eq(f.name, "matrix3d") or eq(f.name, "perspective") or eq(f.name, "translatez") or eq(f.name, "scale3d") or eq(f.name, "rotate3d") or eq(f.name, "rotatex") or eq(f.name, "rotatey"))) return null;
    }
    var res: [2]LengthPercent = undefined;
    for (out, 0..) |m, i| res[i] = if (m.pct == 0) .{ .px = m.px } else if (m.px == 0) .{ .percent = m.pct } else .{ .calc = m };
    return res;
}

/// A `transform` list: a pure translation goes to layout (`translate`);
/// anything else is kept as functions for the painter, which maps the
/// box through them in order. Null for an invalid list.
const Transform = struct { translate: [2]LengthPercent, fns: []const TransformFn, some: bool = true };

fn transformOf(a: std.mem.Allocator, vals: []const css.Value, font_size: f64, env: Env) ?Transform {
    const none: Transform = .{ .translate = .{ .{ .px = 0 }, .{ .px = 0 } }, .fns = &.{}, .some = false };
    if (vals.len == 1) if (ident(vals[0])) |w| if (std.ascii.eqlIgnoreCase(w, "none")) return none;
    var fns: std.ArrayList(TransformFn) = .empty;
    var pure = true;
    for (vals) |v| {
        if (v != .function) return null;
        const f = v.function;
        var args: [6]css.Value = undefined;
        var n: usize = 0;
        for (f.values) |x| {
            if (isWs(x) or (x == .token and x.token == .comma)) continue;
            if (n == args.len) return null;
            args[n] = x;
            n += 1;
        }
        const eq = std.ascii.eqlIgnoreCase;
        const num = struct {
            fn of(x: css.Value) ?f64 {
                if (x == .token and x.token == .number) return x.token.number.value;
                if (x == .token and x.token == .percentage) return x.token.percentage.value / 100;
                return null;
            }
        }.of;
        var fnv: ?TransformFn = null;
        if (eq(f.name, "translate") or eq(f.name, "translate3d")) {
            if (n < 1) return null;
            const x = lengthPercent(args[0], font_size, env) orelse return null;
            const y: LengthPercent = if (n >= 2) (lengthPercent(args[1], font_size, env) orelse return null) else .{ .px = 0 };
            fnv = .{ .translate = .{ x, y } };
        } else if (eq(f.name, "translatex")) {
            if (n != 1) return null;
            fnv = .{ .translate = .{ lengthPercent(args[0], font_size, env) orelse return null, .{ .px = 0 } } };
        } else if (eq(f.name, "translatey")) {
            if (n != 1) return null;
            fnv = .{ .translate = .{ .{ .px = 0 }, lengthPercent(args[0], font_size, env) orelse return null } };
        } else if (eq(f.name, "translatez")) {
            if (n != 1) return null;
            fnv = .{ .translate = .{ .{ .px = 0 }, .{ .px = 0 } } };
        } else if (eq(f.name, "scale") or eq(f.name, "scale3d")) {
            if (n < 1) return null;
            const x = num(args[0]) orelse return null;
            const y = if (n >= 2) (num(args[1]) orelse return null) else x;
            fnv = .{ .scale = .{ x, y } };
            pure = false;
        } else if (eq(f.name, "scalex")) {
            if (n != 1) return null;
            fnv = .{ .scale = .{ num(args[0]) orelse return null, 1 } };
            pure = false;
        } else if (eq(f.name, "scaley")) {
            if (n != 1) return null;
            fnv = .{ .scale = .{ 1, num(args[0]) orelse return null } };
            pure = false;
        } else if (eq(f.name, "rotate") or eq(f.name, "rotatez")) {
            if (n != 1) return null;
            fnv = .{ .rotate = angleDeg(args[0]) orelse return null };
            pure = false;
        } else if (eq(f.name, "rotate3d")) {
            if (n != 4) return null;
            fnv = .{ .rotate = angleDeg(args[3]) orelse return null };
            pure = false;
        } else if (eq(f.name, "rotatex") or eq(f.name, "rotatey")) {
            // Out of the plane: taken as no rotation.
            if (n != 1) return null;
            fnv = .{ .rotate = 0 };
        } else if (eq(f.name, "skew")) {
            if (n < 1) return null;
            const x = angleDeg(args[0]) orelse return null;
            const y = if (n >= 2) (angleDeg(args[1]) orelse return null) else 0;
            fnv = .{ .skew = .{ x, y } };
            pure = false;
        } else if (eq(f.name, "skewx")) {
            if (n != 1) return null;
            fnv = .{ .skew = .{ angleDeg(args[0]) orelse return null, 0 } };
            pure = false;
        } else if (eq(f.name, "skewy")) {
            if (n != 1) return null;
            fnv = .{ .skew = .{ 0, angleDeg(args[0]) orelse return null } };
            pure = false;
        } else if (eq(f.name, "matrix")) {
            if (n != 6) return null;
            var m: [6]f64 = undefined;
            for (args[0..6], 0..) |x, i| {
                if (x != .token or x.token != .number) return null;
                m[i] = x.token.number.value;
            }
            m[4] *= px_scale;
            m[5] *= px_scale;
            fnv = .{ .matrix = m };
            if (m[0] != 1 or m[1] != 0 or m[2] != 0 or m[3] != 1) pure = false;
        } else if (eq(f.name, "matrix3d") or eq(f.name, "perspective")) {
            // Accepted, not applied.
            fnv = .{ .matrix = .{ 1, 0, 0, 1, 0, 0 } };
        } else return null;
        fns.append(a, fnv.?) catch return null;
    }
    if (pure) {
        // The sum of the translations, as before: layout moves the box.
        var out: [2]Mix = .{ .{ .px = 0, .pct = 0 }, .{ .px = 0, .pct = 0 } };
        for (fns.items) |fv| switch (fv) {
            .translate => |t| for (t, 0..) |lp, i| switch (lp) {
                .px => |px| out[i].px += px,
                .percent => |pc| out[i].pct += pc,
                .calc => |c| {
                    out[i].px += c.px;
                    out[i].pct += c.pct;
                },
            },
            .matrix => |m| {
                out[0].px += m[4];
                out[1].px += m[5];
            },
            else => {},
        };
        var res: [2]LengthPercent = undefined;
        for (out, 0..) |m, i| res[i] = if (m.pct == 0) .{ .px = m.px } else if (m.px == 0) .{ .percent = m.pct } else .{ .calc = m };
        return .{ .translate = res, .fns = &.{} };
    }
    return .{ .translate = .{ .{ .px = 0 }, .{ .px = 0 } }, .fns = fns.items };
}

/// A `<time>` in milliseconds (`s`, `ms`; a plain `0`).
fn timeMs(v: css.Value) ?f64 {
    if (v == .token and v.token == .number and v.token.number.value == 0) return 0;
    if (v != .token or v.token != .dimension) return null;
    const d = v.token.dimension;
    if (std.ascii.eqlIgnoreCase(d.unit, "ms")) return d.num.value;
    if (std.ascii.eqlIgnoreCase(d.unit, "s")) return d.num.value * 1000;
    return null;
}

/// A timing function: a keyword, `cubic-bezier()`, `steps()`.
fn timingOf(v: css.Value) ?TimingFn {
    const eq = std.ascii.eqlIgnoreCase;
    if (ident(v)) |w| {
        if (eq(w, "linear")) return .linear;
        if (eq(w, "ease")) return .ease;
        if (eq(w, "ease-in")) return .ease_in;
        if (eq(w, "ease-out")) return .ease_out;
        if (eq(w, "ease-in-out")) return .ease_in_out;
        if (eq(w, "step-start")) return .{ .steps = .{ .n = 1, .start = true } };
        if (eq(w, "step-end")) return .{ .steps = .{ .n = 1, .start = false } };
        return null;
    }
    if (v != .function) return null;
    const f = v.function;
    var args: [4]f64 = undefined;
    var n: usize = 0;
    var start = false;
    for (f.values) |x| {
        if (isWs(x) or (x == .token and x.token == .comma)) continue;
        if (x == .token and x.token == .number) {
            if (n == 4) return null;
            args[n] = x.token.number.value;
            n += 1;
        } else if (ident(x)) |w| {
            if (eq(w, "start") or eq(w, "jump-start")) start = true else if (!(eq(w, "end") or eq(w, "jump-end"))) return null;
        } else return null;
    }
    if (eq(f.name, "cubic-bezier") and n == 4) return .{ .cubic = args };
    if (eq(f.name, "steps") and n == 1 and args[0] >= 1) return .{ .steps = .{ .n = @intFromFloat(args[0]), .start = start } };
    return null;
}

/// An angle in degrees (`deg`, `rad`, `turn`, `grad`; `0` alone).
fn angleDeg(v: css.Value) ?f64 {
    if (v == .token and v.token == .number and v.token.number.value == 0) return 0;
    if (v != .token or v.token != .dimension) return null;
    const d = v.token.dimension;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(d.unit, "deg")) return d.num.value;
    if (eq(d.unit, "rad")) return d.num.value * 180 / std.math.pi;
    if (eq(d.unit, "turn")) return d.num.value * 360;
    if (eq(d.unit, "grad")) return d.num.value * 0.9;
    return null;
}

/// `transform-origin`: one or two values, keywords or lengths (a third,
/// the z offset, is ignored).
fn transformOriginOf(vals: []const css.Value, font_size: f64, env: Env) ?[2]LengthPercent {
    var out: [2]LengthPercent = .{ .{ .percent = 50 }, .{ .percent = 50 } };
    var n: usize = 0;
    for (vals) |v| {
        if (isWs(v)) continue;
        if (n >= 2) break;
        if (ident(v)) |w| {
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(w, "left")) out[0] = .{ .percent = 0 } else if (eq(w, "right")) out[0] = .{ .percent = 100 } else if (eq(w, "top")) out[1] = .{ .percent = 0 } else if (eq(w, "bottom")) out[1] = .{ .percent = 100 } else if (eq(w, "center")) {} else return null;
        } else {
            out[n] = lengthPercent(v, font_size, env) orelse return null;
        }
        n += 1;
    }
    return out;
}

/// `clip-path`: `none`, or a basic shape (`inset`, `circle`, `ellipse`,
/// `polygon`); a shape with a geometry box or a url is `none`.
fn clipPathOf(a: std.mem.Allocator, vals: []const css.Value, font_size: f64, env: Env) ?ClipPath {
    const first = blk: {
        for (vals) |v| if (!isWs(v)) break :blk v;
        return null;
    };
    if (ident(first)) |w| return if (std.ascii.eqlIgnoreCase(w, "none")) .none else null;
    if (first != .function) return null;
    const f = first.function;
    const eq = std.ascii.eqlIgnoreCase;
    var args: [64]css.Value = undefined;
    var n: usize = 0;
    for (f.values) |x| {
        if (isWs(x)) continue;
        if (n == args.len) return null;
        args[n] = x;
        n += 1;
    }
    const isComma = struct {
        fn is(x: css.Value) bool {
            return x == .token and x.token == .comma;
        }
    }.is;
    if (eq(f.name, "inset")) {
        var sides: [4]LengthPercent = undefined;
        var k: usize = 0;
        var i: usize = 0;
        var radius: LengthPercent = .{ .px = 0 };
        while (i < n) : (i += 1) {
            if (ident(args[i])) |w| if (eq(w, "round")) {
                if (i + 1 < n) radius = lengthPercent(args[i + 1], font_size, env) orelse return null;
                break;
            };
            if (k == 4) return null;
            sides[k] = lengthPercent(args[i], font_size, env) orelse return null;
            k += 1;
        }
        if (k == 0) return null;
        const t = sides[0];
        const r = if (k >= 2) sides[1] else t;
        const b = if (k >= 3) sides[2] else t;
        const l = if (k >= 4) sides[3] else r;
        return .{ .inset = .{ .top = t, .right = r, .bottom = b, .left = l, .radius = radius } };
    }
    if (eq(f.name, "circle") or eq(f.name, "ellipse")) {
        var radii: [2]?LengthPercent = .{ null, null };
        var nr: usize = 0;
        var cx: LengthPercent = .{ .percent = 50 };
        var cy: LengthPercent = .{ .percent = 50 };
        var i: usize = 0;
        var at = false;
        var npos: usize = 0;
        while (i < n) : (i += 1) {
            if (ident(args[i])) |w| {
                if (eq(w, "at")) {
                    at = true;
                    continue;
                }
                if (eq(w, "closest-side") or eq(w, "farthest-side")) {
                    if (!at and nr < 2) {
                        radii[nr] = null;
                        nr += 1;
                    }
                    continue;
                }
                if (at) {
                    if (eq(w, "left")) cx = .{ .percent = 0 } else if (eq(w, "right")) cx = .{ .percent = 100 } else if (eq(w, "top")) cy = .{ .percent = 0 } else if (eq(w, "bottom")) cy = .{ .percent = 100 } else if (!eq(w, "center")) return null;
                    npos += 1;
                    continue;
                }
                return null;
            }
            const lp = lengthPercent(args[i], font_size, env) orelse return null;
            if (at) {
                if (npos == 0) cx = lp else cy = lp;
                npos += 1;
            } else {
                if (nr == 2) return null;
                radii[nr] = lp;
                nr += 1;
            }
        }
        if (eq(f.name, "circle")) return .{ .circle = .{ .r = radii[0], .cx = cx, .cy = cy } };
        return .{ .ellipse = .{ .rx = radii[0], .ry = radii[1], .cx = cx, .cy = cy } };
    }
    if (eq(f.name, "polygon")) {
        var pts: std.ArrayList([2]LengthPercent) = .empty;
        var i: usize = 0;
        if (n > 0) if (ident(args[0])) |w| if (eq(w, "nonzero") or eq(w, "evenodd")) {
            i = 1;
            if (i < n and isComma(args[i])) i += 1;
        };
        while (i < n) {
            const x = lengthPercent(args[i], font_size, env) orelse return null;
            if (i + 1 >= n) return null;
            const y = lengthPercent(args[i + 1], font_size, env) orelse return null;
            pts.append(a, .{ x, y }) catch return null;
            i += 2;
            if (i < n) {
                if (!isComma(args[i])) return null;
                i += 1;
            }
        }
        if (pts.items.len < 3) return null;
        return .{ .polygon = pts.items };
    }
    return null;
}

/// One side of a track size.
fn trackSizeOf(v: css.Value, font_size: f64, env: Env) ?TrackSize {
    if (ident(v)) |w| {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "auto")) return .auto;
        if (eq(w, "min-content")) return .min_content;
        if (eq(w, "max-content")) return .max_content;
        return null;
    }
    if (v == .token and v.token == .dimension and std.ascii.eqlIgnoreCase(v.token.dimension.unit, "fr")) {
        const x = v.token.dimension.num.value;
        return if (x >= 0) .{ .fr = x } else null;
    }
    return switch (lengthPercent(v, font_size, env) orelse return null) {
        .px => |x| .{ .px = x },
        .percent => |x| .{ .percent = x },
        // A mixed calc() track: its length part.
        .calc => |m| .{ .px = m.px },
    };
}

/// A track: a size, `minmax()`, `fit-content()`.
fn trackOf(v: css.Value, font_size: f64, env: Env) ?Track {
    if (v == .function) {
        const f = v.function;
        var args: [2]css.Value = undefined;
        var n: usize = 0;
        for (f.values) |x| {
            if (isWs(x) or (x == .token and x.token == .comma)) continue;
            if (n == 2) return null;
            args[n] = x;
            n += 1;
        }
        if (std.ascii.eqlIgnoreCase(f.name, "minmax") and n == 2) {
            const lo = trackSizeOf(args[0], font_size, env) orelse return null;
            const hi = trackSizeOf(args[1], font_size, env) orelse return null;
            if (lo == .fr) return null;
            return .{ .min = lo, .max = hi };
        }
        if (std.ascii.eqlIgnoreCase(f.name, "fit-content") and n == 1) {
            const lim = trackSizeOf(args[0], font_size, env) orelse return null;
            return .{ .min = .auto, .max = lim };
        }
        if (lengthPercent(v, font_size, env)) |lp| return switch (lp) {
            .px => |x| .{ .min = .{ .px = x }, .max = .{ .px = x } },
            .percent => |x| .{ .min = .{ .percent = x }, .max = .{ .percent = x } },
            .calc => |m| .{ .min = .{ .px = m.px }, .max = .{ .px = m.px } },
        };
        return null;
    }
    const s = trackSizeOf(v, font_size, env) orelse return null;
    if (s == .fr) return .{ .min = .auto, .max = s };
    return .{ .min = s, .max = s };
}

/// `grid-template-columns` / `-rows`: `none`, or tracks with line names
/// and `repeat()`s.
fn trackListOf(vals: []const css.Value, font_size: f64, env: Env, a: std.mem.Allocator) ParseFail!?TrackList {
    if (vals.len == 1) if (ident(vals[0])) |w| if (std.ascii.eqlIgnoreCase(w, "none")) return TrackList{};
    var tracks: std.ArrayList(Track) = .empty;
    var names: std.ArrayList(LineName) = .empty;
    var auto_repeat: ?AutoRepeat = null;
    for (vals) |v| {
        if (v == .block and v.block.kind == '[') {
            for (v.block.values) |x| if (ident(x)) |nm| try names.append(a, .{ .name = nm, .line = @intCast(tracks.items.len + 1) });
            continue;
        }
        if (v == .function and std.ascii.eqlIgnoreCase(v.function.name, "repeat")) {
            const fv = v.function.values;
            var comma: ?usize = null;
            for (fv, 0..) |x, i| if (x == .token and x.token == .comma) {
                comma = i;
                break;
            };
            const c = comma orelse return null;
            var count_v: ?css.Value = null;
            for (fv[0..c]) |x| if (!isWs(x)) {
                count_v = x;
            };
            const cv = count_v orelse return null;
            var inner: std.ArrayList(Track) = .empty;
            for (fv[c + 1 ..]) |x| {
                if (isWs(x)) continue;
                if (x == .block) continue; // line names inside a repeat: not kept
                try inner.append(a, trackOf(x, font_size, env) orelse return null);
            }
            if (inner.items.len == 0) return null;
            if (ident(cv)) |w| {
                const fill = std.ascii.eqlIgnoreCase(w, "auto-fill");
                const fit = std.ascii.eqlIgnoreCase(w, "auto-fit");
                if (!fill and !fit) return null;
                if (auto_repeat != null) return null;
                auto_repeat = .{ .at = @intCast(tracks.items.len), .tracks = inner.items, .fit = fit };
                continue;
            }
            if (cv != .token or cv.token != .number) return null;
            const times: usize = @intFromFloat(std.math.clamp(cv.token.number.value, 1, 1000));
            for (0..times) |_| try tracks.appendSlice(a, inner.items);
            continue;
        }
        try tracks.append(a, trackOf(v, font_size, env) orelse return null);
    }
    return .{ .tracks = tracks.items, .names = names.items, .auto_repeat = auto_repeat };
}

/// `grid-template-areas`: one string a row, a name a cell (`.` none);
/// each name must make a rectangle.
fn areasOf(vals: []const css.Value, a: std.mem.Allocator) ParseFail!?[]const GridArea {
    if (vals.len == 1) if (ident(vals[0])) |w| if (std.ascii.eqlIgnoreCase(w, "none")) return &.{};
    var areas: std.ArrayList(GridArea) = .empty;
    var cols: ?usize = null;
    for (vals, 0..) |v, row| {
        if (v != .token or v.token != .string) return null;
        var it = std.mem.tokenizeAny(u8, v.token.string, " \t\r\n");
        var col: u32 = 0;
        while (it.next()) |cell| : (col += 1) {
            if (cell[0] == '.') continue;
            var found = false;
            for (areas.items) |*ar| if (std.mem.eql(u8, ar.name, cell)) {
                found = true;
                ar.row1 = @max(ar.row1, @as(u32, @intCast(row + 1)));
                ar.col0 = @min(ar.col0, col);
                ar.col1 = @max(ar.col1, col + 1);
            };
            if (!found) try areas.append(a, .{ .name = cell, .row0 = @intCast(row), .row1 = @intCast(row + 1), .col0 = col, .col1 = col + 1 });
        }
        if (cols) |c| {
            if (c != col) return null;
        } else cols = col;
    }
    return areas.items;
}

/// `grid-row-start` and the like: `auto`, a line number, `span N`, a
/// name (`name N` takes the name).
fn gridLineOf(vals: []const css.Value) ?GridLine {
    if (vals.len == 0 or vals.len > 3) return null;
    var span = false;
    var num: ?i32 = null;
    var nm: ?[]const u8 = null;
    for (vals) |v| {
        if (ident(v)) |w| {
            if (std.ascii.eqlIgnoreCase(w, "auto")) {
                if (vals.len != 1) return null;
                return .auto;
            }
            if (std.ascii.eqlIgnoreCase(w, "span")) {
                span = true;
            } else nm = w;
        } else if (v == .token and v.token == .number and v.token.number.integer) {
            num = @intFromFloat(v.token.number.value);
        } else return null;
    }
    if (span) return .{ .span = @intCast(@max(1, num orelse 1)) };
    if (nm) |n| return .{ .name = n };
    if (num) |n| return if (n == 0) null else .{ .line = n };
    return null;
}

/// A logical property's physical name for left-to-right horizontal
/// text; any other name as it is.
fn logicalToPhysical(name: []const u8) []const u8 {
    const map = [_][2][]const u8{
        .{ "margin-inline-start", "margin-left" },                   .{ "margin-inline-end", "margin-right" },
        .{ "margin-block-start", "margin-top" },                     .{ "margin-block-end", "margin-bottom" },
        .{ "padding-inline-start", "padding-left" },                 .{ "padding-inline-end", "padding-right" },
        .{ "padding-block-start", "padding-top" },                   .{ "padding-block-end", "padding-bottom" },
        .{ "inset-inline-start", "left" },                           .{ "inset-inline-end", "right" },
        .{ "inset-block-start", "top" },                             .{ "inset-block-end", "bottom" },
        .{ "inline-size", "width" },                                 .{ "block-size", "height" },
        .{ "min-inline-size", "min-width" },                         .{ "max-inline-size", "max-width" },
        .{ "min-block-size", "min-height" },                         .{ "max-block-size", "max-height" },
        .{ "border-inline-start", "border-left" },                   .{ "border-inline-end", "border-right" },
        .{ "border-block-start", "border-top" },                     .{ "border-block-end", "border-bottom" },
        .{ "border-inline-start-width", "border-left-width" },       .{ "border-inline-end-width", "border-right-width" },
        .{ "border-block-start-width", "border-top-width" },         .{ "border-block-end-width", "border-bottom-width" },
        .{ "border-inline-start-color", "border-left-color" },       .{ "border-inline-end-color", "border-right-color" },
        .{ "border-block-start-color", "border-top-color" },         .{ "border-block-end-color", "border-bottom-color" },
        .{ "border-inline-start-style", "border-left-style" },       .{ "border-inline-end-style", "border-right-style" },
        .{ "border-block-start-style", "border-top-style" },         .{ "border-block-end-style", "border-bottom-style" },
        .{ "border-start-start-radius", "border-top-left-radius" },  .{ "border-start-end-radius", "border-top-right-radius" },
        .{ "border-end-start-radius", "border-bottom-left-radius" }, .{ "border-end-end-radius", "border-bottom-right-radius" },
    };
    for (map) |m| if (std.ascii.eqlIgnoreCase(m[0], name)) return m[1];
    return name;
}

/// Whether a value list uses `var()` anywhere, however deep.
fn containsVar(vals: []const css.Value) bool {
    for (vals) |v| switch (v) {
        .function => |f| if (std.ascii.eqlIgnoreCase(f.name, "var") or containsVar(f.values)) return true,
        .block => |b| if (containsVar(b.values)) return true,
        else => {},
    };
    return false;
}

/// Substitute every `var()` in `vals` from `customs`: the variable's
/// value, else the fallback after the comma; null when neither exists
/// (the declaration is then invalid at computed-value time) or the
/// references nest past any sane depth (a cycle).
/// Where `var()` looks: an element's own new values first (while its
/// scope is being made), then a scope.
const Scope = struct {
    customs: ?*const CustomScope,
    overlay: ?*const std.StringHashMapUnmanaged([]const css.Value) = null,

    fn get(sc: Scope, name: []const u8) ?[]const css.Value {
        if (sc.overlay) |o| if (o.get(name)) |v| return v;
        return CustomScope.get(sc.customs, name);
    }
};

fn substitute(a: std.mem.Allocator, vals: []const css.Value, customs: ?*const CustomScope, depth: u8) Error!?[]const css.Value {
    return substituteIn(a, vals, .{ .customs = customs }, depth);
}

fn substituteIn(a: std.mem.Allocator, vals: []const css.Value, scope: Scope, depth: u8) Error!?[]const css.Value {
    if (depth > 16) return null;
    var out: std.ArrayList(css.Value) = .empty;
    for (vals) |v| switch (v) {
        .function => |f| {
            if (std.ascii.eqlIgnoreCase(f.name, "var")) {
                var i: usize = 0;
                while (i < f.values.len and isWs(f.values[i])) : (i += 1) {}
                if (i == f.values.len or ident(f.values[i]) == null) return null;
                const var_name = ident(f.values[i]).?;
                i += 1;
                while (i < f.values.len and isWs(f.values[i])) : (i += 1) {}
                const fallback: ?[]const css.Value = if (i < f.values.len and f.values[i] == .token and f.values[i].token == .comma) f.values[i + 1 ..] else null;
                const got = scope.get(var_name) orelse fallback orelse return null;
                const sub = (try substituteIn(a, got, scope, depth + 1)) orelse return null;
                for (sub) |sv| if (!isWs(sv)) try out.append(a, sv);
            } else {
                const inner = (try substituteIn(a, f.values, scope, depth + 1)) orelse return null;
                try out.append(a, .{ .function = .{ .name = f.name, .values = inner } });
            }
        },
        .block => |b| {
            const inner = (try substituteIn(a, b.values, scope, depth + 1)) orelse return null;
            try out.append(a, .{ .block = .{ .kind = b.kind, .values = inner } });
        },
        else => try out.append(a, v),
    };
    return out.items;
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
/// Every node's computed style, shared: elements whose styles come out
/// identical point at one copy (siblings in a list, cells in a table —
/// a 30,000-node page has a few thousand distinct styles, and a
/// `Computed` is well over a kilobyte).
/// A computed property as CSS text, for a script's `getComputedStyle`:
/// the properties the cascade computes to a value a script can use
/// (lengths in px, colours as rgb()); null for the rest.
pub fn propertyText(c: *const Computed, name: []const u8, buf: []u8) ?[]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    const a = fba.allocator();
    const P = struct {
        fn px(al: std.mem.Allocator, v: f64) ?[]const u8 {
            return std.fmt.allocPrint(al, "{d}px", .{v}) catch null;
        }
        fn lengthAuto(al: std.mem.Allocator, l: LengthAuto) ?[]const u8 {
            return switch (l) {
                .px => |v| px(al, v),
                .percent => |v| std.fmt.allocPrint(al, "{d}%", .{v}) catch null,
                .auto => "auto",
                .calc => |m| std.fmt.allocPrint(al, "calc({d}% + {d}px)", .{ m.pct, m.px }) catch null,
            };
        }
        fn lengthPercent(al: std.mem.Allocator, l: LengthPercent) ?[]const u8 {
            return switch (l) {
                .px => |v| px(al, v),
                .percent => |v| std.fmt.allocPrint(al, "{d}%", .{v}) catch null,
                .calc => |m| std.fmt.allocPrint(al, "calc({d}% + {d}px)", .{ m.pct, m.px }) catch null,
            };
        }
        fn side(nm: []const u8, prefix: []const u8) ?usize {
            if (!std.mem.startsWith(u8, nm, prefix)) return null;
            const rest = nm[prefix.len..];
            if (std.mem.eql(u8, rest, "top")) return 0;
            if (std.mem.eql(u8, rest, "right")) return 1;
            if (std.mem.eql(u8, rest, "bottom")) return 2;
            if (std.mem.eql(u8, rest, "left")) return 3;
            return null;
        }
        fn kebab(al: std.mem.Allocator, tag: []const u8) ?[]const u8 {
            const out = al.dupe(u8, tag) catch return null;
            for (out) |*ch| if (ch.* == '_') {
                ch.* = '-';
            };
            return out;
        }
    };
    const eq = std.mem.eql;
    if (eq(u8, name, "display")) return P.kebab(a, @tagName(c.display));
    if (eq(u8, name, "position")) return @tagName(c.position);
    if (eq(u8, name, "float")) return @tagName(c.float);
    if (eq(u8, name, "visibility")) return @tagName(c.visibility);
    if (eq(u8, name, "cursor")) return P.kebab(a, @tagName(c.cursor));
    if (eq(u8, name, "color")) return c.color.serialize(a) catch null;
    if (eq(u8, name, "background-color")) return c.background_color.serialize(a) catch null;
    if (eq(u8, name, "font-size")) return P.px(a, c.font_size);
    if (eq(u8, name, "font-weight")) return std.fmt.allocPrint(a, "{d}", .{c.font_weight}) catch null;
    if (eq(u8, name, "font-style")) return @tagName(c.font_style);
    if (eq(u8, name, "font-family")) {
        var out: std.ArrayList(u8) = .empty;
        for (c.font_family, 0..) |f, i| {
            if (i > 0) out.appendSlice(a, ", ") catch return null;
            out.appendSlice(a, f) catch return null;
        }
        return out.items;
    }
    if (eq(u8, name, "line-height")) return switch (c.line_height) {
        .normal => "normal",
        .number => |n| std.fmt.allocPrint(a, "{d}", .{n}) catch null,
        .px => |v| P.px(a, v),
    };
    if (eq(u8, name, "text-align")) return @tagName(c.text_align);
    if (eq(u8, name, "text-decoration") or eq(u8, name, "text-decoration-line")) return if (c.text_decoration.underline) "underline" else if (c.text_decoration.line_through) "line-through" else if (c.text_decoration.overline) "overline" else "none";
    if (eq(u8, name, "text-transform")) return @tagName(c.text_transform);
    if (eq(u8, name, "white-space")) return P.kebab(a, @tagName(c.white_space));
    if (eq(u8, name, "list-style-type")) return P.kebab(a, @tagName(c.list_style_type));
    if (eq(u8, name, "opacity")) return std.fmt.allocPrint(a, "{d}", .{c.opacity}) catch null;
    if (eq(u8, name, "z-index")) return if (c.z_index) |z| (std.fmt.allocPrint(a, "{d}", .{z}) catch null) else "auto";
    if (eq(u8, name, "box-sizing")) return P.kebab(a, @tagName(c.box_sizing));
    if (eq(u8, name, "overflow-x")) return @tagName(c.overflow_x);
    if (eq(u8, name, "overflow-y")) return @tagName(c.overflow_y);
    if (eq(u8, name, "overflow")) return @tagName(c.overflow_y);
    if (eq(u8, name, "width")) return P.lengthAuto(a, c.width);
    if (eq(u8, name, "height")) return P.lengthAuto(a, c.height);
    if (eq(u8, name, "min-width")) return P.lengthPercent(a, c.min_width);
    if (eq(u8, name, "min-height")) return P.lengthPercent(a, c.min_height);
    if (P.side(name, "margin-")) |i| return P.lengthAuto(a, c.margin[i]);
    if (P.side(name, "padding-")) |i| return P.lengthPercent(a, c.padding[i]);
    if (P.side(name, "border-")) |i| return P.px(a, c.borderWidth(i));
    if (std.mem.startsWith(u8, name, "border-") and std.mem.endsWith(u8, name, "-width")) {
        if (P.side(name[0 .. name.len - "-width".len], "border-")) |i| return P.px(a, c.borderWidth(i));
    }
    if (std.mem.startsWith(u8, name, "border-") and std.mem.endsWith(u8, name, "-style")) {
        if (P.side(name[0 .. name.len - "-style".len], "border-")) |i| return @tagName(c.border_style[i]);
    }
    if (eq(u8, name, "top")) return P.lengthAuto(a, c.inset[0]);
    if (eq(u8, name, "right")) return P.lengthAuto(a, c.inset[1]);
    if (eq(u8, name, "bottom")) return P.lengthAuto(a, c.inset[2]);
    if (eq(u8, name, "left")) return P.lengthAuto(a, c.inset[3]);
    if (eq(u8, name, "flex-direction")) return P.kebab(a, @tagName(c.flex_direction));
    if (eq(u8, name, "flex-wrap")) return P.kebab(a, @tagName(c.flex_wrap));
    if (eq(u8, name, "flex-grow")) return std.fmt.allocPrint(a, "{d}", .{c.flex_grow}) catch null;
    if (eq(u8, name, "flex-shrink")) return std.fmt.allocPrint(a, "{d}", .{c.flex_shrink}) catch null;
    if (eq(u8, name, "justify-content")) return P.kebab(a, @tagName(c.justify_content));
    if (eq(u8, name, "align-items")) return P.kebab(a, @tagName(c.align_items));
    return null;
}

// ------------------------------------------------------- animation

fn lerp(x: f64, y: f64, t: f64) f64 {
    return x + (y - x) * t;
}

fn lerpLP(x: LengthPercent, y: LengthPercent, t: f64) LengthPercent {
    if (x == .px and y == .px) return .{ .px = lerp(x.px, y.px, t) };
    if (x == .percent and y == .percent) return .{ .percent = lerp(x.percent, y.percent, t) };
    return if (t < 0.5) x else y;
}

fn lerpLA(x: LengthAuto, y: LengthAuto, t: f64) LengthAuto {
    if (x == .px and y == .px) return .{ .px = lerp(x.px, y.px, t) };
    if (x == .percent and y == .percent) return .{ .percent = lerp(x.percent, y.percent, t) };
    return if (t < 0.5) x else y;
}

fn lerpLN(x: LengthNone, y: LengthNone, t: f64) LengthNone {
    if (x == .px and y == .px) return .{ .px = lerp(x.px, y.px, t) };
    if (x == .percent and y == .percent) return .{ .percent = lerp(x.percent, y.percent, t) };
    return if (t < 0.5) x else y;
}

fn lerpColor(x: Color, y: Color, t: f64) Color {
    return .{ .r = lerp(x.r, y.r, t), .g = lerp(x.g, y.g, t), .b = lerp(x.b, y.b, t), .a = lerp(x.a, y.a, t) };
}

/// The computed values `t` of the way from one to the other: lengths,
/// percentages, colours, numbers, the translation and a transform list
/// of the same shape interpolate; anything else switches at the half
/// (CSS Transitions §2, Web Animations' discrete interpolation). The
/// result is a fresh value whose slices are the ends' (a transform
/// list is allocated).
pub fn interpolate(a: std.mem.Allocator, x: *const Computed, y: *const Computed, t: f64) Error!Computed {
    var out = if (t < 0.5) x.* else y.*;
    out.width = lerpLA(x.width, y.width, t);
    out.height = lerpLA(x.height, y.height, t);
    out.min_width = lerpLP(x.min_width, y.min_width, t);
    out.min_height = lerpLP(x.min_height, y.min_height, t);
    out.max_width = lerpLN(x.max_width, y.max_width, t);
    out.max_height = lerpLN(x.max_height, y.max_height, t);
    for (0..4) |i| {
        out.margin[i] = lerpLA(x.margin[i], y.margin[i], t);
        out.padding[i] = lerpLP(x.padding[i], y.padding[i], t);
        out.border_width[i] = lerp(x.border_width[i], y.border_width[i], t);
        out.inset[i] = lerpLA(x.inset[i], y.inset[i], t);
        out.border_radius[i] = lerpLP(x.border_radius[i], y.border_radius[i], t);
        if (x.border_color[i] != null and y.border_color[i] != null) out.border_color[i] = lerpColor(x.border_color[i].?, y.border_color[i].?, t);
    }
    out.color = lerpColor(x.color, y.color, t);
    out.background_color = lerpColor(x.background_color, y.background_color, t);
    out.font_size = lerp(x.font_size, y.font_size, t);
    out.opacity = lerp(x.opacity, y.opacity, t);
    out.flex_grow = lerp(x.flex_grow, y.flex_grow, t);
    out.flex_shrink = lerp(x.flex_shrink, y.flex_shrink, t);
    out.row_gap = lerpLP(x.row_gap, y.row_gap, t);
    out.column_gap = lerpLP(x.column_gap, y.column_gap, t);
    out.text_indent = lerpLP(x.text_indent, y.text_indent, t);
    if (x.line_height == .px and y.line_height == .px) out.line_height = .{ .px = lerp(x.line_height.px, y.line_height.px, t) };
    if (x.line_height == .number and y.line_height == .number) out.line_height = .{ .number = lerp(x.line_height.number, y.line_height.number, t) };
    out.translate = .{ lerpLP(x.translate[0], y.translate[0], t), lerpLP(x.translate[1], y.translate[1], t) };
    for (0..2) |i| out.transform_origin[i] = lerpLP(x.transform_origin[i], y.transform_origin[i], t);
    if (x.z_index != null and y.z_index != null) out.z_index = @intFromFloat(@round(lerp(@floatFromInt(x.z_index.?), @floatFromInt(y.z_index.?), t)));
    // A transform list interpolates function by function when the two
    // lists have the same functions in the same order.
    if (x.transform_fns.len > 0 and x.transform_fns.len == y.transform_fns.len) {
        var same = true;
        for (x.transform_fns, y.transform_fns) |fx, fy| if (std.meta.activeTag(fx) != std.meta.activeTag(fy)) {
            same = false;
        };
        if (same) {
            const fns = try a.alloc(TransformFn, x.transform_fns.len);
            for (x.transform_fns, y.transform_fns, 0..) |fx, fy, i| fns[i] = switch (fx) {
                .translate => |tx| .{ .translate = .{ lerpLP(tx[0], fy.translate[0], t), lerpLP(tx[1], fy.translate[1], t) } },
                .scale => |sx| .{ .scale = .{ lerp(sx[0], fy.scale[0], t), lerp(sx[1], fy.scale[1], t) } },
                .rotate => |rx| .{ .rotate = lerp(rx, fy.rotate, t) },
                .skew => |kx| .{ .skew = .{ lerp(kx[0], fy.skew[0], t), lerp(kx[1], fy.skew[1], t) } },
                .matrix => |mx| blk: {
                    var m: [6]f64 = undefined;
                    for (0..6) |k| m[k] = lerp(mx[k], fy.matrix[k], t);
                    break :blk .{ .matrix = m };
                },
            };
            out.transform_fns = fns;
        }
    } else if (x.transform_fns.len == 0 and y.transform_fns.len > 0 and t < 0.5) {
        // From none: the identity is the other list with its functions
        // at rest — approximated as a switch at the half.
        out.transform_fns = &.{};
    }
    return out;
}

/// A keyframe's declarations applied over a base computed style (the
/// element's, with its parent for `inherit`): the frame's values.
pub fn applyKeyframe(a: std.mem.Allocator, base: *const Computed, parent: *const Computed, decls: []const Declaration, env: Env) Error!Computed {
    var out = base.*;
    for (decls) |d| try applyDeclared(a, &out, d.prop, d.value, parent, env);
    return out;
}

pub const Styles = struct {
    computed: []*const Computed,

    pub fn get(s: *const Styles, id: NodeId) *const Computed {
        return s.computed[id];
    }
};

const InternCtx = struct {
    pub fn hash(_: InternCtx, c: *const Computed) u64 {
        var h = std.hash.Wyhash.init(0x7374796c);
        const f = struct {
            fn add(hh: *std.hash.Wyhash, x: anytype) void {
                const T = @TypeOf(x);
                switch (@typeInfo(T)) {
                    .float => hh.update(std.mem.asBytes(&@as(f64, x))),
                    .@"enum" => hh.update(std.mem.asBytes(&@as(u32, @intFromEnum(x)))),
                    .int => hh.update(std.mem.asBytes(&@as(u64, @intCast(x)))),
                    .@"union" => {
                        hh.update(std.mem.asBytes(&@as(u32, @intFromEnum(std.meta.activeTag(x)))));
                        switch (x) {
                            inline else => |payload| if (@TypeOf(payload) == f64) hh.update(std.mem.asBytes(&payload)),
                        }
                    },
                    else => @compileError("hash " ++ @typeName(T)),
                }
            }
        }.add;
        f(&h, c.display);
        f(&h, c.position);
        f(&h, c.float);
        f(&h, c.font_size);
        f(&h, c.font_weight);
        f(&h, c.color.r);
        f(&h, c.color.g);
        f(&h, c.color.b);
        f(&h, c.background_color.r);
        f(&h, c.background_color.a);
        f(&h, c.width);
        f(&h, c.height);
        for (c.margin) |m| f(&h, m);
        for (c.padding) |m| f(&h, m);
        for (c.border_width) |x| f(&h, x);
        for (c.border_style) |x| f(&h, x);
        f(&h, c.text_align);
        f(&h, c.white_space);
        h.update(std.mem.asBytes(&@intFromPtr(c.customs)));
        h.update(std.mem.asBytes(&@intFromPtr(c.font_family.ptr)));
        return h.final();
    }
    pub fn eql(_: InternCtx, x: *const Computed, y: *const Computed) bool {
        return std.meta.eql(x.*, y.*);
    }
};

/// A font-family list's shared copy (a page has a handful of distinct
/// ones; each element that declares one allocates its own).
fn internFamily(a: std.mem.Allocator, families: *std.ArrayList(FontFamily), f: FontFamily) Error!FontFamily {
    outer: for (families.items) |known| {
        if (known.ptr == f.ptr and known.len == f.len) return known;
        if (known.len != f.len) continue;
        for (known, f) |x, y| if (!std.mem.eql(u8, x, y)) continue :outer;
        return known;
    }
    try families.append(a, f);
    return f;
}

/// A computed style's shared copy: an equal one already made, or a new
/// one.
fn intern(a: std.mem.Allocator, set: *std.HashMapUnmanaged(*const Computed, void, InternCtx, 80), c: *const Computed) Error!*const Computed {
    const e = try set.getOrPutContext(a, c, .{});
    if (e.found_existing) return e.key_ptr.*;
    const copy = try a.create(Computed);
    copy.* = c.*;
    e.key_ptr.* = copy;
    return copy;
}

const Candidate = struct {
    decl: Declaration,
    origin: Origin,
    specificity: u32,
    order: u32,
    /// The declaring sheet's URL (a fetched sheet's); its `url()`s are
    /// relative to it.
    base: ?[]const u8 = null,
    layer: u8 = unlayered,

    /// Higher wins: importance and origin first, then specificity, then
    /// order.
    /// Layers sit between origin and specificity: later layers win,
    /// unlayered rules above them all — reversed for `!important`.
    fn rank(c: Candidate) u128 {
        const tier: u128 = if (c.decl.important) (if (c.origin == .user_agent) 3 else 2) else (if (c.origin == .author) 1 else 0);
        const layer: u128 = if (c.decl.important) unlayered - c.layer else c.layer;
        return (tier << 72) | (layer << 64) | (@as(u128, c.specificity) << 32) | c.order;
    }
};

/// Compute the whole document's styles from the sheets (the user-agent
/// sheet first), with `style` attributes as the last author rules.
pub fn compute(a: std.mem.Allocator, doc: *const Document, sheets: []const Sheet, env: Env) Error!Styles {
    const computed = try a.alloc(*const Computed, doc.nodes.len);
    const doc_style = try a.create(Computed);
    doc_style.* = .{};
    doc_style.color = env_text;
    // Every slot reads: a node the walk does not reach (one a script made
    // and never inserted, one under `display: none`) has the document's
    // style rather than an undefined pointer (the animation engine's
    // snapshot found one, 2026-10-07).
    @memset(computed, doc_style);
    // The initial font size (`medium`), zoomed; `rem` is of it until
    // the root element has its own.
    doc_style.font_size = 16 * px_scale;
    for (computed) |*c| c.* = doc_style;
    var interned: std.HashMapUnmanaged(*const Computed, void, InternCtx, 80) = .empty;
    var tmp: Computed = .{};
    root_font_size = 16 * px_scale;
    var winners: [@typeInfo(Prop).@"enum".fields.len]?Candidate = undefined;
    var custom_winners: std.ArrayList(Candidate) = .empty;
    var order: u32 = 0;
    const index = try RuleIndex.build(a, sheets);
    var pending_scratch = try ScratchFallback.init(a, 64 << 10);
    var families: std.ArrayList(FontFamily) = .empty;
    // Each node's ancestors' keys (a parent is walked before its children).
    const ancestors = try a.alloc(Bloom, doc.nodes.len);
    ancestors[dom.document_id] = @splat(0);
    var candidates: std.ArrayList(u32) = .empty;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| {
        const parent_id = doc.get(id).parent orelse dom.document_id;
        if (id == dom.document_id) continue;
        const parent = computed[parent_id];
        @memset(&winners, null);
        custom_winners.clearRetainingCapacity();
        order = 0;
        try index.candidatesFor(a, doc, id, &candidates);
        ancestors[id] = if (id == dom.document_id) @as(Bloom, @splat(0)) else ancestors[parent_id] | bloomOfElement(doc, parent_id);
        const have = ancestors[id];
        for (candidates.items) |gi| {
            const need = index.need_of[gi];
            if (@reduce(.Or, need & ~have) != 0) continue;
            const sheet = sheets[index.sheet_of[gi]];
            const rule = sheet.rules[index.rule_of[gi]];
            if (!selectors.Selector.matchesOne(doc, id, rule.selector)) continue;
            for (rule.declarations) |d| {
                order += 1;
                const cand: Candidate = .{ .decl = d, .origin = sheet.origin, .specificity = rule.specificity, .order = order, .base = sheet.base, .layer = rule.layer };
                if (d.name.len > 0 and d.value != .pending) {
                    try customCandidate(a, &custom_winners, cand);
                    continue;
                }
                const slot = &winners[@intFromEnum(d.prop)];
                if (slot.* == null or cand.rank() > slot.*.?.rank()) slot.* = cand;
            }
        }
        // Presentational hints (HTML's `width`, `bgcolor`, `align`…):
        // author-level, beneath every author rule.
        if (try presentationalHints(a, doc, id)) |decls| for (decls) |d| {
            const cand: Candidate = .{ .decl = d, .origin = .author, .specificity = 0, .order = 0, .layer = 0 };
            const slot = &winners[@intFromEnum(d.prop)];
            if (slot.* == null or cand.rank() > slot.*.?.rank()) slot.* = cand;
        };
        if (doc.getAttr(id, "style")) |text| {
            const decls = try parseInline(a, text);
            for (decls) |d| {
                order += 1;
                const cand: Candidate = .{ .decl = d, .origin = .author, .specificity = 0x3fff_ffff, .order = order };
                if (d.name.len > 0 and d.value != .pending) {
                    try customCandidate(a, &custom_winners, cand);
                    continue;
                }
                const slot = &winners[@intFromEnum(d.prop)];
                if (slot.* == null or cand.rank() > slot.*.?.rank()) slot.* = cand;
            }
        }
        // The custom properties first: the parent's, then this element's
        // own, each computed (its own `var()`s substituted) as it is set.
        var customs = parent.customs;
        if (custom_winners.items.len > 0) customs = try ownCustoms(a, parent.customs, custom_winners.items);
        // Then every declaration waiting on them: substituted, and a
        // shorthand's expanded again for the longhand it stands for.
        // What fails is invalid at computed-value time: `unset`.
        // `var()` substitution's temporaries: a scratch reset per element
        // (what the computed style keeps, applyValues copies into `a`).
        pending_scratch.reset();
        const sa = pending_scratch.allocator();
        for (&winners) |*slot| if (slot.*) |*c| if (c.decl.value == .pending) {
            c.decl.value = try resolvePending(sa, c.decl, customs);
        };
        try computeOne(a, &tmp, parent, &winners, env);
        tmp.customs = customs;
        if (winners[@intFromEnum(Prop.background_image)]) |c| if (tmp.background_image == .url) {
            tmp.background_base = c.base;
        };
        if (winners[@intFromEnum(Prop.mask_image)]) |c| if (tmp.mask_image == .url) {
            tmp.mask_base = c.base;
        };
        // Equal family lists become one list, so equal styles can share.
        if (tmp.font_family.len > 0) tmp.font_family = try internFamily(a, &families, tmp.font_family);
        computed[id] = try intern(a, &interned, &tmp);
        if (parent_id == dom.document_id and doc.get(id).kind == .element) root_font_size = tmp.font_size;
    }
    return .{ .computed = computed };
}

/// The rules of every sheet bucketed by what their subject compound
/// needs of an element — an id, else a class, else a tag — so an
/// element is matched only against the rules it could meet (GitHub's
/// 20,000 rules against every element took seconds). Global indexes
/// run in sheet and rule order, which the cascade's order needs.
const RuleIndex = struct {
    sheet_of: []u32,
    rule_of: []u32,
    /// What a rule's ancestor compounds need (tags, ids, classes), as
    /// Bloom bits: an element whose ancestors lack any is not matched.
    need_of: []Bloom,
    ids: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    classes: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    tags: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    /// Subjects with only an attribute to go by: by the attribute's name.
    attrs: std.StringHashMapUnmanaged(std.ArrayList(u32)) = .empty,
    universal: std.ArrayList(u32) = .empty,

    fn build(a: std.mem.Allocator, sheets: []const Sheet) Error!RuleIndex {
        var total: usize = 0;
        for (sheets) |sh| total += sh.rules.len;
        var ix: RuleIndex = .{ .sheet_of = try a.alloc(u32, total), .rule_of = try a.alloc(u32, total), .need_of = try a.alloc(Bloom, total) };
        var gi: u32 = 0;
        for (sheets, 0..) |sh, si| for (sh.rules, 0..) |r, ri| {
            ix.sheet_of[gi] = @intCast(si);
            ix.rule_of[gi] = @intCast(ri);
            const comps = r.selector.compounds;
            // A compound whose own combinator (the one to its right) is
            // child or descendant sits at an ancestor of the subject —
            // siblings share ancestors, so `A B ~ C` puts A above C, but
            // `A ~ B C` puts A beside an ancestor, not above the subject
            // (a sticky flag here once pruned that rule wrongly).
            var need: Bloom = @splat(0);
            var ci = comps.len;
            while (ci > 1) {
                ci -= 1;
                var ancestor = false;
                if (comps[ci].combinator) |comb| if (comb == .descendant or comb == .child) {
                    ancestor = true;
                };
                if (ancestor) for (comps[ci - 1].simples) |sm| switch (sm) {
                    .type => |v| if (!std.mem.eql(u8, v, "*")) bloomAddLower(&need, v),
                    .id => |v| bloomAdd(&need, v),
                    .class => |v| bloomAdd(&need, v),
                    else => {},
                };
            }
            ix.need_of[gi] = need;
            var id_key: ?[]const u8 = null;
            var class_key: ?[]const u8 = null;
            var tag_key: ?[]const u8 = null;
            var attr_key: ?[]const u8 = null;
            if (comps.len > 0) for (comps[comps.len - 1].simples) |sm| switch (sm) {
                .id => |v| id_key = v,
                .class => |v| {
                    if (class_key == null) class_key = v;
                },
                .type => |v| if (!std.mem.eql(u8, v, "*")) {
                    tag_key = v;
                },
                .attr => |at| {
                    if (attr_key == null) attr_key = at.name;
                },
                else => {},
            };
            if (id_key) |k| {
                try addTo(a, &ix.ids, k, gi);
            } else if (class_key) |k| {
                try addTo(a, &ix.classes, k, gi);
            } else if (tag_key) |k| {
                try addTo(a, &ix.tags, try std.ascii.allocLowerString(a, k), gi);
            } else if (attr_key) |k| {
                try addTo(a, &ix.attrs, try std.ascii.allocLowerString(a, k), gi);
            } else try ix.universal.append(a, gi);
            gi += 1;
        };
        return ix;
    }

    fn addTo(a: std.mem.Allocator, map: *std.StringHashMapUnmanaged(std.ArrayList(u32)), key: []const u8, gi: u32) Error!void {
        const e = try map.getOrPut(a, key);
        if (!e.found_existing) e.value_ptr.* = .empty;
        try e.value_ptr.append(a, gi);
    }

    /// The rules an element could match, in order, once each.
    fn candidatesFor(ix: *const RuleIndex, a: std.mem.Allocator, doc: *const Document, id: NodeId, out: *std.ArrayList(u32)) Error!void {
        out.clearRetainingCapacity();
        const n = doc.get(id);
        if (n.kind != .element) return;
        try out.appendSlice(a, ix.universal.items);
        var lower: [64]u8 = undefined;
        if (n.name.len <= lower.len) {
            const ln = std.ascii.lowerString(&lower, n.name);
            if (ix.tags.get(ln)) |list| try out.appendSlice(a, list.items);
        }
        if (doc.getAttr(id, "id")) |v| if (ix.ids.get(v)) |list| try out.appendSlice(a, list.items);
        if (ix.attrs.count() > 0) for (n.attrs.items) |at| {
            if (at.name.len > lower.len) continue;
            if (ix.attrs.get(std.ascii.lowerString(&lower, at.name))) |list| try out.appendSlice(a, list.items);
        };
        if (doc.getAttr(id, "class")) |cls| {
            var it = std.mem.tokenizeAny(u8, cls, " \t\r\n\x0c");
            while (it.next()) |c| if (ix.classes.get(c)) |list| try out.appendSlice(a, list.items);
        }
        std.mem.sort(u32, out.items, {}, std.sort.asc(u32));
        // A class named twice brings its rules twice.
        var w: usize = 0;
        for (out.items, 0..) |v, i| {
            if (i > 0 and v == out.items[i - 1]) continue;
            out.items[w] = v;
            w += 1;
        }
        out.items.len = w;
    }
};

/// 256 bits of hashed tags, ids and classes.
const Bloom = @Vector(4, u64);

fn bloomAdd(b: *Bloom, key: []const u8) void {
    const h = std.hash.Wyhash.hash(0x6d6f7373, key);
    var arr: [4]u64 = b.*;
    arr[(h >> 6) & 3] |= @as(u64, 1) << @intCast(h & 63);
    arr[(h >> 14) & 3] |= @as(u64, 1) << @intCast((h >> 8) & 63);
    b.* = arr;
}

fn bloomAddLower(b: *Bloom, key: []const u8) void {
    var buf: [64]u8 = undefined;
    if (key.len > buf.len) return;
    bloomAdd(b, std.ascii.lowerString(&buf, key));
}

/// An element's own keys, for its descendants' filters.
fn bloomOfElement(doc: *const Document, id: NodeId) Bloom {
    var b: Bloom = @splat(0);
    const n = doc.get(id);
    if (n.kind != .element) return b;
    bloomAddLower(&b, n.name);
    if (doc.getAttr(id, "id")) |v| bloomAdd(&b, v);
    if (doc.getAttr(id, "class")) |cls| {
        var it = std.mem.tokenizeAny(u8, cls, " \t\r\n\x0c");
        while (it.next()) |c| bloomAdd(&b, c);
    }
    return b;
}

/// A custom property's candidate: the best per name wins.
fn customCandidate(a: std.mem.Allocator, list: *std.ArrayList(Candidate), cand: Candidate) Error!void {
    for (list.items) |*c| if (std.mem.eql(u8, c.decl.name, cand.decl.name)) {
        if (cand.rank() > c.rank()) c.* = cand;
        return;
    };
    try list.append(a, cand);
}

/// An element's custom properties: its parent's, then its own winners
/// (later entries override earlier ones by name). `initial` removes one
/// (an empty value stands for the guaranteed-invalid one); `inherit` and
/// `unset` keep the parent's.
/// Whether two value lists say the same thing.
fn valuesEql(x: []const css.Value, y: []const css.Value) bool {
    if (x.ptr == y.ptr and x.len == y.len) return true;
    if (x.len != y.len) return false;
    for (x, y) |p, q| {
        if (std.meta.activeTag(p) != std.meta.activeTag(q)) return false;
        switch (p) {
            .token => |t| {
                const u = q.token;
                if (std.meta.activeTag(t) != std.meta.activeTag(u)) return false;
                switch (t) {
                    .ident, .function, .at_keyword, .string, .url => |sv| if (!std.mem.eql(u8, sv, switch (u) {
                        .ident, .function, .at_keyword, .string, .url => |uv| uv,
                        else => unreachable,
                    })) return false,
                    .hash => |h| if (!std.mem.eql(u8, h.value, u.hash.value)) return false,
                    .delim => |c| if (c != u.delim) return false,
                    .number, .percentage => |n| if (n.value != (if (u == .number) u.number.value else u.percentage.value)) return false,
                    .dimension => |d| if (d.num.value != u.dimension.num.value or !std.ascii.eqlIgnoreCase(d.unit, u.dimension.unit)) return false,
                    else => {},
                }
            },
            .function => |f| if (!std.mem.eql(u8, f.name, q.function.name) or !valuesEql(f.values, q.function.values)) return false,
            .block => |b| if (b.kind != q.block.kind or !valuesEql(b.values, q.block.values)) return false,
            .err => {},
        }
    }
    return true;
}

/// A value list's arrays copied into `a` (their strings are the sheet's,
/// which outlive the cascade).
fn dupeValues(a: std.mem.Allocator, vals: []const css.Value) Error![]const css.Value {
    const out = try a.alloc(css.Value, vals.len);
    for (vals, 0..) |v, i| out[i] = switch (v) {
        .function => |f| .{ .function = .{ .name = f.name, .values = try dupeValues(a, f.values) } },
        .block => |b| .{ .block = .{ .kind = b.kind, .values = try dupeValues(a, b.values) } },
        else => v,
    };
    return out;
}

/// An element's custom-property scope: its parent's, unless its own
/// declarations change something — then a node of just those changes
/// over the parent's. `initial` makes one guaranteed-invalid (empty);
/// `inherit`/`unset` keep the parent's.
fn ownCustoms(a: std.mem.Allocator, parent: ?*const CustomScope, own: []const Candidate) Error!?*const CustomScope {
    var scratch = std.heap.stackFallback(8 << 10, a);
    const sa = scratch.get();
    var names: std.ArrayList([]const u8) = .empty;
    var values: std.ArrayList([]const css.Value) = .empty;
    // The changes so far by name, for `var()`s among them.
    var overlay: std.StringHashMapUnmanaged([]const css.Value) = .empty;
    for (own) |c| {
        const before = CustomScope.get(parent, c.decl.name);
        var value: []const css.Value = &.{};
        switch (c.decl.value) {
            .custom => |vals| {
                value = vals;
                if (containsVar(vals)) value = (try substituteIn(sa, vals, .{ .customs = parent, .overlay = &overlay }, 0)) orelse &.{};
                if (before) |bv| if (valuesEql(bv, value)) continue;
                if (containsVar(vals)) value = try dupeValues(a, value);
            },
            .initial => if (before == null) continue,
            else => continue,
        }
        try names.append(sa, c.decl.name);
        try values.append(sa, value);
        try overlay.put(sa, c.decl.name, value);
    }
    if (names.items.len == 0) return parent;
    const node = try a.create(CustomScope);
    node.* = .{ .parent = parent, .names = try a.dupe([]const u8, names.items), .values = try a.dupe([]const css.Value, values.items) };
    if (names.items.len > 16) {
        const m = try a.create(std.StringHashMapUnmanaged(u32));
        m.* = .empty;
        try m.ensureTotalCapacity(a, @intCast(names.items.len));
        for (node.names, 0..) |n, i| m.putAssumeCapacity(n, @intCast(i));
        node.map = m;
    }
    return node;
}

/// A fixed scratch reset per element, falling back to the arena when an
/// element needs more (what falls back is simply not reclaimed).
const ScratchFallback = struct {
    fba: std.heap.FixedBufferAllocator = std.heap.FixedBufferAllocator.init(&.{}),
    fallback: std.mem.Allocator,
    size: usize,

    /// The buffer is taken on first use: a small document (or a caller
    /// with a small heap, the shell's `html-style`) may need none.
    fn init(a: std.mem.Allocator, size: usize) Error!ScratchFallback {
        return .{ .fallback = a, .size = size };
    }
    fn reset(s: *ScratchFallback) void {
        s.fba.reset();
    }
    fn allocator(s: *ScratchFallback) std.mem.Allocator {
        return .{ .ptr = s, .vtable = &.{ .alloc = allocFn, .resize = resizeFn, .remap = remapFn, .free = freeFn } };
    }
    fn allocFn(ctx: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
        const s: *ScratchFallback = @ptrCast(@alignCast(ctx));
        if (s.fba.buffer.len == 0 and s.size > 0) {
            const buf = s.fallback.alloc(u8, s.size) catch null;
            s.size = 0; // one try
            if (buf) |b| s.fba = std.heap.FixedBufferAllocator.init(b);
        }
        return s.fba.allocator().rawAlloc(len, alignment, ra) orelse s.fallback.rawAlloc(len, alignment, ra);
    }
    fn resizeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
        const s: *ScratchFallback = @ptrCast(@alignCast(ctx));
        if (s.fba.ownsSlice(mem)) return s.fba.allocator().rawResize(mem, alignment, new_len, ra);
        return s.fallback.rawResize(mem, alignment, new_len, ra);
    }
    fn remapFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
        const s: *ScratchFallback = @ptrCast(@alignCast(ctx));
        if (s.fba.ownsSlice(mem)) return s.fba.allocator().rawRemap(mem, alignment, new_len, ra);
        return s.fallback.rawRemap(mem, alignment, new_len, ra);
    }
    fn freeFn(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
        const s: *ScratchFallback = @ptrCast(@alignCast(ctx));
        if (s.fba.ownsSlice(mem)) return s.fba.allocator().rawFree(mem, alignment, ra);
        s.fallback.rawFree(mem, alignment, ra);
    }
};

/// A pending declaration made ordinary, or `unset` when its variables
/// do not resolve or the result does not parse.
fn resolvePending(a: std.mem.Allocator, d: Declaration, customs: ?*const CustomScope) Error!Declared {
    const sub = (try substitute(a, d.value.pending, customs, 0)) orelse return .unset;
    if (d.name.len == 0) {
        if (wideKeyword(sub)) |wk| return wk;
        return .{ .values = sub };
    }
    var decls: std.ArrayList(Declaration) = .empty;
    try expand(a, .{ .name = d.name, .value = sub, .important = d.important }, &decls);
    for (decls.items) |e| if (e.prop == d.prop) return e.value;
    return .unset;
}

/// The presentational hints of an element's attributes (HTML §15), as
/// declarations the cascade ranks under every author rule: the sizes of
/// pictures and table parts, `bgcolor`, `align`, `valign`, `nowrap`,
/// `<body text>`, `<font color size face>`, an image's `border`,
/// `hspace` and `vspace`. Null when the element has none.
fn presentationalHints(a: std.mem.Allocator, doc: *const Document, id: NodeId) Error!?[]const Declaration {
    const n = doc.get(id);
    if (n.kind != .element or n.namespace != .html) return null;
    const name = n.name;
    const is_cell = std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th");
    if (n.attrs.items.len == 0 and !is_cell) return null;
    const eq = std.mem.eql;
    var buf: [512]u8 = undefined;
    var w: std.Io.Writer = .fixed(&buf);
    const sized = eq(u8, name, "img") or eq(u8, name, "video") or eq(u8, name, "canvas") or eq(u8, name, "iframe") or eq(u8, name, "embed") or eq(u8, name, "object") or eq(u8, name, "table") or eq(u8, name, "td") or eq(u8, name, "th") or eq(u8, name, "col") or eq(u8, name, "hr") or eq(u8, name, "svg") or (eq(u8, name, "input") and std.ascii.eqlIgnoreCase(doc.getAttr(id, "type") orelse "", "image"));
    if (sized) {
        if (doc.getAttr(id, "width")) |v| hintLength(&w, "width", v);
        if (!eq(u8, name, "hr")) if (doc.getAttr(id, "height")) |v| hintLength(&w, "height", v);
    }
    if (eq(u8, name, "body") or eq(u8, name, "table") or eq(u8, name, "tr") or eq(u8, name, "td") or eq(u8, name, "th") or eq(u8, name, "thead") or eq(u8, name, "tbody") or eq(u8, name, "tfoot")) {
        if (doc.getAttr(id, "bgcolor")) |v| hintColor(&w, "background-color", v);
    }
    if (eq(u8, name, "body")) if (doc.getAttr(id, "text")) |v| hintColor(&w, "color", v);
    if (eq(u8, name, "font")) {
        if (doc.getAttr(id, "color")) |v| hintColor(&w, "color", v);
        if (doc.getAttr(id, "face")) |v| if (safeHint(v)) w.print("font-family:{s};", .{v}) catch {};
        if (doc.getAttr(id, "size")) |v| hintFontSize(&w, v);
    }
    if (doc.getAttr(id, "align")) |v_raw| {
        const v = std.mem.trim(u8, v_raw, " \t\r\n");
        const ieq = std.ascii.eqlIgnoreCase;
        if (eq(u8, name, "img") or eq(u8, name, "iframe") or eq(u8, name, "embed") or eq(u8, name, "object") or eq(u8, name, "input")) {
            if (ieq(v, "left") or ieq(v, "right")) w.print("float:{s};", .{if (ieq(v, "left")) "left" else "right"}) catch {};
            if (ieq(v, "middle") or ieq(v, "absmiddle")) w.writeAll("vertical-align:middle;") catch {};
            if (ieq(v, "top") or ieq(v, "bottom")) w.print("vertical-align:{s};", .{if (ieq(v, "top")) "top" else "bottom"}) catch {};
        } else if (eq(u8, name, "table")) {
            if (ieq(v, "center")) w.writeAll("margin-left:auto;margin-right:auto;") catch {};
            if (ieq(v, "left") or ieq(v, "right")) w.print("float:{s};", .{if (ieq(v, "left")) "left" else "right"}) catch {};
        } else if (eq(u8, name, "hr")) {
            if (ieq(v, "center")) w.writeAll("margin-left:auto;margin-right:auto;") catch {};
            if (ieq(v, "left")) w.writeAll("margin-left:0;margin-right:auto;") catch {};
            if (ieq(v, "right")) w.writeAll("margin-left:auto;margin-right:0;") catch {};
        } else if (ieq(v, "left") or ieq(v, "right") or ieq(v, "center") or ieq(v, "justify") or ieq(v, "middle")) {
            w.print("text-align:{s};", .{if (ieq(v, "middle")) "center" else if (ieq(v, "left")) "left" else if (ieq(v, "right")) "right" else if (ieq(v, "center")) "center" else "justify"}) catch {};
        }
    }
    if (eq(u8, name, "td") or eq(u8, name, "th") or eq(u8, name, "tr") or eq(u8, name, "thead") or eq(u8, name, "tbody") or eq(u8, name, "tfoot")) {
        if (doc.getAttr(id, "valign")) |v| {
            const ieq = std.ascii.eqlIgnoreCase;
            if (ieq(v, "top") or ieq(v, "middle") or ieq(v, "bottom") or ieq(v, "baseline")) w.print("vertical-align:{s};", .{if (ieq(v, "top")) "top" else if (ieq(v, "middle")) "middle" else if (ieq(v, "bottom")) "bottom" else "baseline"}) catch {};
        }
        if (doc.hasAttr(id, "nowrap")) w.writeAll("white-space:nowrap;") catch {};
    }
    if (eq(u8, name, "img") or eq(u8, name, "object")) {
        if (doc.getAttr(id, "hspace")) |v| if (hintNumber(v)) |x| w.print("margin-left:{d}px;margin-right:{d}px;", .{ x, x }) catch {};
        if (doc.getAttr(id, "vspace")) |v| if (hintNumber(v)) |x| w.print("margin-top:{d}px;margin-bottom:{d}px;", .{ x, x }) catch {};
        if (doc.getAttr(id, "border")) |v| if (hintNumber(v)) |x| w.print("border:{d}px solid;", .{x}) catch {};
    }
    if (eq(u8, name, "table")) {
        if (doc.getAttr(id, "border")) |v| {
            const x = hintNumber(v) orelse 1;
            if (x > 0) w.print("border:{d}px outset;", .{x}) catch {};
        }
        if (doc.getAttr(id, "cellspacing")) |v| if (hintNumber(v)) |x| w.print("border-spacing:{d}px;", .{x}) catch {};
    }
    // A cell takes its table's `cellpadding`, and a 1px inset border
    // when the table has a border.
    if (eq(u8, name, "td") or eq(u8, name, "th")) {
        var q = n.parent;
        while (q) |qid| : (q = doc.get(qid).parent) if (doc.isHtml(qid, "table")) {
            if (doc.getAttr(qid, "cellpadding")) |v| if (hintNumber(v)) |x| w.print("padding:{d}px;", .{x}) catch {};
            if (doc.getAttr(qid, "border")) |v| if ((hintNumber(v) orelse 1) > 0) w.writeAll("border:1px inset #808080;") catch {};
            break;
        };
    }
    if (w.end == 0) return null;
    return try parseInline(a, try a.dupe(u8, w.buffered()));
}

/// A non-negative number an attribute gives (leading digits, as HTML's
/// rules for dimension values parse them).
fn hintNumber(v_raw: []const u8) ?f64 {
    const v = std.mem.trim(u8, v_raw, " \t\r\n");
    var end: usize = 0;
    while (end < v.len and (std.ascii.isDigit(v[end]) or v[end] == '.')) : (end += 1) {}
    if (end == 0) return null;
    return std.fmt.parseFloat(f64, v[0..end]) catch null;
}

fn hintLength(w: *std.Io.Writer, prop: []const u8, v_raw: []const u8) void {
    const x = hintNumber(v_raw) orelse return;
    const v = std.mem.trim(u8, v_raw, " \t\r\n");
    const pct = v.len > 0 and v[v.len - 1] == '%';
    w.print("{s}:{d}{s};", .{ prop, x, if (pct) "%" else "px" }) catch {};
}

/// An attribute's value is only ever copied into a declaration when it
/// cannot close one or open another.
fn safeHint(v: []const u8) bool {
    for (v) |c| if (c == ';' or c == '{' or c == '}' or c == '<' or c == '\\' or c == '!') return false;
    return v.len > 0 and v.len < 128;
}

fn hintColor(w: *std.Io.Writer, prop: []const u8, v_raw: []const u8) void {
    const v = std.mem.trim(u8, v_raw, " \t\r\n");
    if (!safeHint(v)) return;
    // Legacy colours are often bare hex digits.
    var hex = v.len == 6 or v.len == 3;
    for (v) |c| if (!std.ascii.isHex(c)) {
        hex = false;
    };
    if (hex and v[0] != '#') w.print("{s}:#{s};", .{ prop, v }) catch {} else w.print("{s}:{s};", .{ prop, v }) catch {};
}

/// `<font size>`: 1 to 7, or relative to 3.
fn hintFontSize(w: *std.Io.Writer, v_raw: []const u8) void {
    const v = std.mem.trim(u8, v_raw, " \t\r\n");
    if (v.len == 0) return;
    const rel = v[0] == '+' or v[0] == '-';
    const x = hintNumber(if (rel) v[1..] else v) orelse return;
    var n: i64 = @intFromFloat(x);
    if (rel) n = if (v[0] == '+') 3 + n else 3 - n;
    const names = [_][]const u8{ "x-small", "x-small", "small", "medium", "large", "x-large", "xx-large", "xxx-large" };
    w.print("font-size:{s};", .{names[@intCast(std.math.clamp(n, 1, 7))]}) catch {};
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
        .custom, .pending => {},
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

pub fn copyProp(out: *Computed, from: *const Computed, p: Prop) void {
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
        .cursor => out.cursor = from.cursor,
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
        .border_spacing_x => out.border_spacing_x = from.border_spacing_x,
        .border_spacing_y => out.border_spacing_y = from.border_spacing_y,
        .border_collapse => out.border_collapse = from.border_collapse,
        .background_image => {
            out.background_image = from.background_image;
            out.background_base = from.background_base;
        },
        .background_position_x => out.background_position[0] = from.background_position[0],
        .background_position_y => out.background_position[1] = from.background_position[1],
        .background_size => out.background_size = from.background_size,
        .background_repeat => out.background_repeat = from.background_repeat,
        .background_attachment => out.background_attachment = from.background_attachment,
        .border_top_left_radius => out.border_radius[0] = from.border_radius[0],
        .border_top_right_radius => out.border_radius[1] = from.border_radius[1],
        .border_bottom_right_radius => out.border_radius[2] = from.border_radius[2],
        .border_bottom_left_radius => out.border_radius[3] = from.border_radius[3],
        .fill => out.fill = from.fill,
        .transform => {
            out.translate = from.translate;
            out.transform_fns = from.transform_fns;
            out.has_transform = from.has_transform;
        },
        .transform_origin => out.transform_origin = from.transform_origin,
        .clip_path => out.clip_path = from.clip_path,
        .overflow_clip_margin => {
            out.overflow_clip_margin = from.overflow_clip_margin;
            out.overflow_clip_box = from.overflow_clip_box;
        },
        .transition_property => {
            out.transition_property = from.transition_property;
            out.transition_none = from.transition_none;
        },
        .transition_duration => out.transition_duration = from.transition_duration,
        .transition_delay => out.transition_delay = from.transition_delay,
        .transition_timing_function => out.transition_timing = from.transition_timing,
        .animation_name => out.animation_name = from.animation_name,
        .animation_duration => out.animation_duration = from.animation_duration,
        .animation_delay => out.animation_delay = from.animation_delay,
        .animation_timing_function => out.animation_timing = from.animation_timing,
        .animation_iteration_count => out.animation_iterations = from.animation_iterations,
        .animation_direction => out.animation_direction = from.animation_direction,
        .animation_fill_mode => out.animation_fill = from.animation_fill,
        .animation_play_state => out.animation_paused = from.animation_paused,
        .mask_image => {
            out.mask_image = from.mask_image;
            out.mask_base = from.mask_base;
        },
        .mask_position_x => out.mask_position[0] = from.mask_position[0],
        .mask_position_y => out.mask_position[1] = from.mask_position[1],
        .mask_size => out.mask_size = from.mask_size,
        .mask_repeat => out.mask_repeat = from.mask_repeat,
        .grid_template_columns => out.grid_template_columns = from.grid_template_columns,
        .grid_template_rows => out.grid_template_rows = from.grid_template_rows,
        .grid_template_areas => out.grid_template_areas = from.grid_template_areas,
        .grid_auto_columns => out.grid_auto_columns = from.grid_auto_columns,
        .grid_auto_rows => out.grid_auto_rows = from.grid_auto_rows,
        .grid_auto_flow => out.grid_auto_flow = from.grid_auto_flow,
        .grid_row_start => out.grid_place[0] = from.grid_place[0],
        .grid_column_start => out.grid_place[1] = from.grid_place[1],
        .grid_row_end => out.grid_place[2] = from.grid_place[2],
        .grid_column_end => out.grid_place[3] = from.grid_place[3],
        .justify_items => out.justify_items = from.justify_items,
        .justify_self => out.justify_self = from.justify_self,
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
    if (v == .function) {
        // A math function with no percentage in it is a length now.
        const m = mathOf(v, font_size, env) orelse return null;
        return if (m.pct == 0) m.px else null;
    }
    if (v != .token) return null;
    switch (v.token) {
        .number => |n| return if (n.value == 0) 0 else null,
        .dimension => |d| {
            const eq = std.ascii.eqlIgnoreCase;
            const x = d.num.value;
            // Font-relative units are of sizes already in device pixels;
            // the rest are CSS pixels, `px_scale` device pixels each (the
            // viewport `env` gives is in CSS pixels too).
            if (eq(d.unit, "em")) return x * font_size;
            if (eq(d.unit, "rem")) return x * root_font_size;
            if (eq(d.unit, "ex") or eq(d.unit, "ch")) return x * font_size * 0.5;
            const css_px: f64 = if (eq(d.unit, "px")) x else if (eq(d.unit, "vw")) x * env.width / 100 else if (eq(d.unit, "vh")) x * env.height / 100 else if (eq(d.unit, "vmin")) x * @min(env.width, env.height) / 100 else if (eq(d.unit, "vmax")) x * @max(env.width, env.height) / 100 else if (eq(d.unit, "in")) x * 96 else if (eq(d.unit, "cm")) x * 96 / 2.54 else if (eq(d.unit, "mm")) x * 96 / 25.4 else if (eq(d.unit, "q")) x * 96 / 101.6 else if (eq(d.unit, "pt")) x * 96 / 72 else if (eq(d.unit, "pc")) x * 16 else return null;
            return css_px * px_scale;
        },
        else => return null,
    }
}

/// The root element's computed font size, which `rem` is of: set by
/// `compute` once the root is computed (before, the initial size).
pub var root_font_size: f64 = 16;
/// Device pixels per CSS pixel: the page zoom. Every absolute length,
/// font-size keyword and border-width keyword is scaled by it, and a
/// picture's natural size (layout); media queries see the viewport in
/// CSS pixels (the host divides its `Env` by it).
pub var px_scale: f64 = 1;

fn lengthPercent(v: css.Value, font_size: f64, env: Env) ?LengthPercent {
    if (v == .token and v.token == .percentage) return .{ .percent = v.token.percentage.value };
    if (v == .function) {
        const m = mathOf(v, font_size, env) orelse return null;
        if (m.pct == 0) return .{ .px = m.px };
        if (m.px == 0) return .{ .percent = m.pct };
        return .{ .calc = m };
    }
    if (lengthPx(v, font_size, env)) |px| return .{ .px = px };
    return null;
}

fn lengthAuto(v: css.Value, font_size: f64, env: Env) ?LengthAuto {
    if (ident(v)) |w| return if (std.ascii.eqlIgnoreCase(w, "auto")) .auto else null;
    return switch (lengthPercent(v, font_size, env) orelse return null) {
        .px => |x| .{ .px = x },
        .percent => |x| .{ .percent = x },
        .calc => |m| .{ .calc = m },
    };
}

// ------------------------------------------------------- math functions

/// A term of a math expression: a number, or a length as px plus a
/// percentage.
const MathVal = struct { num: f64 = 0, px: f64 = 0, pct: f64 = 0, is_len: bool = false };

/// `calc()`, `min()`, `max()` and `clamp()` over lengths, percentages
/// and numbers (CSS Values 4 §10). `min`/`max`/`clamp` need their
/// arguments comparable now, so a percentage in one is not taken.
fn mathOf(v: css.Value, font_size: f64, env: Env) ?Mix {
    const r = mathFunction(v, font_size, env, 0) orelse return null;
    if (!r.is_len and r.num != 0) return null;
    return .{ .px = r.px, .pct = r.pct };
}

fn mathFunction(v: css.Value, font_size: f64, env: Env, depth: u8) ?MathVal {
    if (depth > 16 or v != .function) return null;
    const name = v.function.name;
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "calc") or eq(name, "-webkit-calc")) return mathSum(v.function.values, font_size, env, depth + 1);
    if (!(eq(name, "min") or eq(name, "max") or eq(name, "clamp"))) return null;
    // The comma-separated arguments.
    var args: [8]MathVal = undefined;
    var n: usize = 0;
    var start: usize = 0;
    const vals = v.function.values;
    for (0..vals.len + 1) |i| {
        if (i < vals.len and !(vals[i] == .token and vals[i].token == .comma)) continue;
        if (n == args.len) return null;
        args[n] = mathSum(vals[start..i], font_size, env, depth + 1) orelse return null;
        if (args[n].pct != 0) return null;
        n += 1;
        start = i + 1;
    }
    if (n == 0) return null;
    const key = struct {
        fn f(m: MathVal) f64 {
            return if (m.is_len) m.px else m.num;
        }
    }.f;
    if (eq(name, "clamp")) {
        if (n != 3) return null;
        const lo = key(args[0]);
        const mid = key(args[1]);
        const hi = key(args[2]);
        const out = @max(lo, @min(mid, hi));
        return if (args[1].is_len) .{ .px = out, .is_len = true } else .{ .num = out };
    }
    var best = args[0];
    for (args[1..n]) |x| {
        if (eq(name, "min") and key(x) < key(best)) best = x;
        if (eq(name, "max") and key(x) > key(best)) best = x;
    }
    return best;
}

fn isDelim(v: css.Value, c: u8) bool {
    return v == .token and v.token == .delim and v.token.delim == c;
}

/// `a + b - c`: the operators need whitespace around them.
fn mathSum(vals_in: []const css.Value, font_size: f64, env: Env, depth: u8) ?MathVal {
    var buf: [64]css.Value = undefined;
    var n: usize = 0;
    for (vals_in) |x| if (!isWs(x)) {
        if (n == buf.len) return null;
        buf[n] = x;
        n += 1;
    };
    const vals = buf[0..n];
    if (vals.len == 0) return null;
    var total: MathVal = .{};
    var sign: f64 = 1;
    var i: usize = 0;
    var first = true;
    while (i < vals.len) {
        // A product runs to the next top-level + or -.
        var j = i;
        while (j < vals.len and !isDelim(vals[j], '+') and !isDelim(vals[j], '-')) j += 1;
        const term = mathProduct(vals[i..j], font_size, env, depth) orelse return null;
        if (!first and term.is_len != total.is_len) return null;
        total.num += sign * term.num;
        total.px += sign * term.px;
        total.pct += sign * term.pct;
        total.is_len = term.is_len;
        first = false;
        if (j == vals.len) break;
        sign = if (isDelim(vals[j], '+')) 1 else -1;
        i = j + 1;
    }
    return total;
}

fn mathProduct(vals: []const css.Value, font_size: f64, env: Env, depth: u8) ?MathVal {
    if (vals.len == 0) return null;
    var acc = mathAtom(vals[0], font_size, env, depth) orelse return null;
    var i: usize = 1;
    while (i + 1 < vals.len + 1 and i < vals.len) : (i += 2) {
        const op = vals[i];
        if (i + 1 >= vals.len) return null;
        const rhs = mathAtom(vals[i + 1], font_size, env, depth) orelse return null;
        if (isDelim(op, '*')) {
            if (acc.is_len and rhs.is_len) return null;
            if (rhs.is_len) {
                acc = .{ .px = rhs.px * acc.num, .pct = rhs.pct * acc.num, .is_len = true };
            } else if (acc.is_len) {
                acc.px *= rhs.num;
                acc.pct *= rhs.num;
            } else acc.num *= rhs.num;
        } else if (isDelim(op, '/')) {
            if (rhs.is_len or rhs.num == 0) return null;
            if (acc.is_len) {
                acc.px /= rhs.num;
                acc.pct /= rhs.num;
            } else acc.num /= rhs.num;
        } else return null;
    }
    return acc;
}

fn mathAtom(v: css.Value, font_size: f64, env: Env, depth: u8) ?MathVal {
    switch (v) {
        .token => |t| switch (t) {
            .number => |num| return .{ .num = num.value },
            .percentage => |pc| return .{ .pct = pc.value, .is_len = true },
            .dimension => return .{ .px = lengthPx(v, font_size, env) orelse return null, .is_len = true },
            else => return null,
        },
        .block => |b| {
            if (b.kind != '(') return null;
            return mathSum(b.values, font_size, env, depth + 1);
        },
        .function => return mathFunction(v, font_size, env, depth + 1),
        else => return null,
    }
}

fn borderWidthOf(v: css.Value, font_size: f64, env: Env) ?f64 {
    if (ident(v)) |w| {
        const eq = std.ascii.eqlIgnoreCase;
        if (eq(w, "thin")) return 1 * px_scale;
        if (eq(w, "medium")) return 3 * px_scale;
        if (eq(w, "thick")) return 5 * px_scale;
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
    switch (p) {
        .background_image => {
            out.background_image = (try backgroundImageOf(vals, font_size, env, a)) orelse return error.Invalid;
            return true;
        },
        .mask_image => {
            out.mask_image = (try backgroundImageOf(vals, font_size, env, a)) orelse return error.Invalid;
            return true;
        },
        .transform => {
            const t = transformOf(a, vals, font_size, env) orelse return error.Invalid;
            out.translate = t.translate;
            out.transform_fns = t.fns;
            out.has_transform = t.some;
            return true;
        },
        .transform_origin => {
            out.transform_origin = transformOriginOf(vals, font_size, env) orelse return error.Invalid;
            return true;
        },
        .clip_path => {
            out.clip_path = clipPathOf(a, vals, font_size, env) orelse return error.Invalid;
            return true;
        },
        .overflow_clip_margin => {
            out.overflow_clip_margin = 0;
            out.overflow_clip_box = .padding_box;
            for (vals) |v| {
                if (isWs(v)) continue;
                if (keyword(ClipBox, v)) |kb| {
                    out.overflow_clip_box = kb;
                } else if (lengthPercent(v, font_size, env)) |lp| {
                    out.overflow_clip_margin = if (lp == .px) lp.px else return error.Invalid;
                } else return error.Invalid;
            }
            return true;
        },
        .transition_property => {
            var props: std.ArrayList(?Prop) = .empty;
            out.transition_none = false;
            for (vals) |v| {
                if (v == .token and v.token == .comma) continue;
                const w = ident(v) orelse return error.Invalid;
                if (std.ascii.eqlIgnoreCase(w, "none")) {
                    out.transition_none = true;
                } else if (std.ascii.eqlIgnoreCase(w, "all")) {
                    try props.append(a, null);
                } else try props.append(a, Prop.parse(w) orelse continue);
            }
            out.transition_property = props.items;
            return true;
        },
        .transition_duration, .transition_delay => {
            var times: std.ArrayList(f64) = .empty;
            for (vals) |v| {
                if (v == .token and v.token == .comma) continue;
                try times.append(a, timeMs(v) orelse return error.Invalid);
            }
            if (p == .transition_duration) out.transition_duration = times.items else out.transition_delay = times.items;
            return true;
        },
        .transition_timing_function => {
            var fns: std.ArrayList(TimingFn) = .empty;
            for (vals) |v| {
                if (v == .token and v.token == .comma) continue;
                try fns.append(a, timingOf(v) orelse return error.Invalid);
            }
            out.transition_timing = fns.items;
            return true;
        },
        .animation_name => {
            const v = vals[0];
            if (ident(v)) |w| {
                out.animation_name = if (std.ascii.eqlIgnoreCase(w, "none")) "" else w;
            } else if (v == .token and v.token == .string) {
                out.animation_name = v.token.string;
            } else return error.Invalid;
            return true;
        },
        .animation_duration => {
            out.animation_duration = timeMs(vals[0]) orelse return error.Invalid;
            return true;
        },
        .animation_delay => {
            out.animation_delay = timeMs(vals[0]) orelse return error.Invalid;
            return true;
        },
        .animation_timing_function => {
            out.animation_timing = timingOf(vals[0]) orelse return error.Invalid;
            return true;
        },
        .animation_iteration_count => {
            const v = vals[0];
            if (ident(v)) |w| {
                if (!std.ascii.eqlIgnoreCase(w, "infinite")) return error.Invalid;
                out.animation_iterations = std.math.inf(f64);
            } else if (v == .token and v.token == .number and v.token.number.value >= 0) {
                out.animation_iterations = v.token.number.value;
            } else return error.Invalid;
            return true;
        },
        .animation_direction => {
            out.animation_direction = keyword(AnimationDirection, vals[0]) orelse return error.Invalid;
            return true;
        },
        .animation_fill_mode => {
            out.animation_fill = keyword(AnimationFill, vals[0]) orelse return error.Invalid;
            return true;
        },
        .animation_play_state => {
            const w = ident(vals[0]) orelse return error.Invalid;
            out.animation_paused = if (std.ascii.eqlIgnoreCase(w, "paused")) true else if (std.ascii.eqlIgnoreCase(w, "running")) false else return error.Invalid;
            return true;
        },
        .mask_size => {
            out.mask_size = backgroundSizeOf(vals, font_size, env) orelse return error.Invalid;
            return true;
        },
        .mask_repeat => {
            out.mask_repeat = backgroundRepeatOf(vals) orelse return error.Invalid;
            return true;
        },
        .mask_position_x, .mask_position_y => {
            const pos = positionComponent(vals, p == .mask_position_x, font_size, env) orelse return error.Invalid;
            out.mask_position[if (p == .mask_position_x) 0 else 1] = pos;
            return true;
        },
        .grid_template_columns, .grid_template_rows => {
            const list = (try trackListOf(vals, font_size, env, a)) orelse return error.Invalid;
            if (p == .grid_template_columns) out.grid_template_columns = list else out.grid_template_rows = list;
            return true;
        },
        .grid_template_areas => {
            out.grid_template_areas = (try areasOf(vals, a)) orelse return error.Invalid;
            return true;
        },
        .grid_auto_columns, .grid_auto_rows => {
            if (vals.len != 1) return error.Invalid;
            const t = trackOf(vals[0], font_size, env) orelse return error.Invalid;
            if (p == .grid_auto_columns) out.grid_auto_columns = t else out.grid_auto_rows = t;
            return true;
        },
        .grid_auto_flow => {
            var f: GridAutoFlow = .{};
            for (vals) |x| {
                const w = ident(x) orelse return error.Invalid;
                if (std.ascii.eqlIgnoreCase(w, "column")) f.column = true else if (std.ascii.eqlIgnoreCase(w, "dense")) f.dense = true else if (!std.ascii.eqlIgnoreCase(w, "row")) return error.Invalid;
            }
            out.grid_auto_flow = f;
            return true;
        },
        .grid_row_start, .grid_column_start, .grid_row_end, .grid_column_end => {
            const gl = gridLineOf(vals) orelse return error.Invalid;
            const idx: usize = switch (p) {
                .grid_row_start => 0,
                .grid_column_start => 1,
                .grid_row_end => 2,
                else => 3,
            };
            out.grid_place[idx] = gl;
            return true;
        },
        .background_size => {
            out.background_size = backgroundSizeOf(vals, font_size, env) orelse return error.Invalid;
            return true;
        },
        .background_repeat => {
            out.background_repeat = backgroundRepeatOf(vals) orelse return error.Invalid;
            return true;
        },
        .background_attachment => {
            const w = ident(vals[0]) orelse return error.Invalid;
            out.background_attachment = if (std.mem.eql(u8, w, "fixed")) .fixed else if (std.mem.eql(u8, w, "local")) .local else if (std.mem.eql(u8, w, "scroll")) .scroll else return error.Invalid;
            return true;
        },
        .background_position_x, .background_position_y => {
            const pos = positionComponent(vals, p == .background_position_x, font_size, env) orelse return error.Invalid;
            out.background_position[if (p == .background_position_x) 0 else 1] = pos;
            return true;
        },
        .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius => {
            // `a b` (elliptical) keeps the horizontal radius.
            const r = lengthPercent(vals[0], font_size, env) orelse return error.Invalid;
            const idx: usize = switch (p) {
                .border_top_left_radius => 0,
                .border_top_right_radius => 1,
                .border_bottom_right_radius => 2,
                else => 3,
            };
            out.border_radius[idx] = r;
            return true;
        },
        else => {},
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
                .calc => |m| .{ .calc = m },
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
                    out.font_size = k.px * px_scale;
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
                .calc => |m| m.of(parent.font_size),
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
                .calc => |m| .{ .px = m.of(font_size) },
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
        .cursor => out.cursor = keyword(Cursor, v) orelse return error.Invalid,
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
        .border_spacing_x, .border_spacing_y => {
            const x = lengthPx(v, font_size, env) orelse return error.Invalid;
            if (x < 0) return error.Invalid;
            if (p == .border_spacing_x) out.border_spacing_x = x else out.border_spacing_y = x;
        },
        .border_collapse => out.border_collapse = keyword(BorderCollapse, v) orelse return error.Invalid,
        .fill => {
            if (ident(v)) |w| if (std.ascii.eqlIgnoreCase(w, "none")) {
                out.fill = .none;
                return true;
            };
            out.fill = switch (color.parseValue(v) orelse return error.Invalid) {
                .color => |c| .{ .color = c },
                .current => .current,
            };
        },
        .transform, .transform_origin, .clip_path, .overflow_clip_margin, .transition_property, .transition_duration, .transition_delay, .transition_timing_function, .animation_name, .animation_duration, .animation_delay, .animation_timing_function, .animation_iteration_count, .animation_direction, .animation_fill_mode, .animation_play_state, .mask_image, .mask_position_x, .mask_position_y, .mask_size, .mask_repeat, .grid_template_columns, .grid_template_rows, .grid_template_areas, .grid_auto_columns, .grid_auto_rows, .grid_auto_flow, .grid_row_start, .grid_column_start, .grid_row_end, .grid_column_end => unreachable,
        .justify_items => out.justify_items = keyword(AlignItems, v) orelse return error.Invalid,
        .justify_self => out.justify_self = keyword(AlignSelf, v) orelse return error.Invalid,
        .background_image, .background_size, .background_repeat, .background_attachment, .background_position_x, .background_position_y, .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius => unreachable,
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

/// The quirks-mode additions (HTML §15.3.2's, as browsers ship them):
/// a table does not inherit its text's size, weight, alignment or
/// wrapping from outside it.
pub const quirks_sheet =
    \\table { font-weight: normal; font-style: normal; font-size: medium; line-height: normal; white-space: normal; text-align: start }
;

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
    \\table { display: table; box-sizing: border-box; text-indent: 0; border-spacing: 2px; border-collapse: separate }
    \\thead, tbody, tfoot, tr { vertical-align: middle } td, th { vertical-align: inherit }
    \\caption { display: table-caption; text-align: center }
    \\thead { display: table-header-group } tbody { display: table-row-group } tfoot { display: table-footer-group }
    \\tr { display: table-row } td, th { display: table-cell; padding: 1px } th { font-weight: bold; text-align: center }
    \\colgroup { display: table-column-group } col { display: table-column }
    \\input, select, button, textarea, meter, progress { display: inline-block }
    \\button, select, input { font-family: sans-serif }
    \\button { padding: 1px 6px; border: 1px solid #767676; background-color: #efefef; text-align: center }
    \\input, select, textarea, button { font-size: 13.333px }
    \\input, select, textarea { border: 1px solid #767676; background-color: #ffffff; padding: 1px 2px }
    \\input[type=submit], input[type=button], input[type=reset] { background-color: #efefef; padding: 1px 6px; text-align: center }
    \\input[type=checkbox], input[type=radio], input[type=image] { border: 0; padding: 0; background-color: transparent }
    \\input[type=checkbox], input[type=radio] { margin: 3px 3px 3px 4px }
    \\input[type=hidden] { display: none }
    \\dialog:not([open]) { display: none }
    \\dialog { position: absolute; left: 0; right: 0; margin: auto; border: solid; padding: 1em; background-color: #ffffff; color: #000000 }
    \\details:not([open]) > :not(summary:first-of-type) { display: none }
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
    try std.testing.expectEqual(@as(f64, 3), s.width.px); // calc() resolved
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
pub fn collectDocumentSheetsKept(a: std.mem.Allocator, doc: *const Document, env: Env, ua: Sheet, loader: ?Loader, keep_in: ?Keep) Error![]const Sheet {
    var sheets: std.ArrayList(Sheet) = .empty;
    const list_a = if (keep_in) |k| k.a else a;
    // What the document has, so rules that can never match it are not
    // kept (the tree does not change: there is no script yet).
    const has = try DocKeys.of(list_a, doc);
    var filter: Filter = .{ .has = has, .inner = keep_in };
    const keep: ?Keep = .{ .ctx = @ptrCast(&filter), .a = list_a, .keep = Filter.keepFn };
    try sheets.append(list_a, ua);
    // A document in quirks mode: the rules the HTML Standard keeps for it.
    if (doc.quirks == .quirks) {
        const q = try parseSheet(a, quirks_sheet, .user_agent, env);
        try sheets.append(list_a, if (keep) |k| try k.keep(k.ctx, q) else q);
    }
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| {
        const is_style = doc.isHtml(id, "style");
        const is_link = doc.isHtml(id, "link");
        if (!is_style and !is_link) continue;
        if (is_link) {
            if (!linkIsStylesheet(doc.getAttr(id, "rel") orelse continue)) continue;
            if (doc.getAttr(id, "disabled") != null) continue;
        }
        if (doc.getAttr(id, "media")) |m| {
            const q = try media.Query.parseText(a, m);
            if (!q.matches(env)) continue;
        }
        if (is_style) {
            // Where it survives the scratch being reset between pieces.
            // An XHTML page's `<![CDATA[ … ]]>` around the text is the
            // XML parser's to remove; without one, it is removed here
            // (WPT's shared references are XHTML, 2026-10-07).
            const text = stripCdata(try doc.textContent(id, if (keep) |k| k.a else a));
            try appendSheetText(a, &sheets, text, env, null, loader, keep);
        } else {
            const href = std.mem.trim(u8, doc.getAttr(id, "href") orelse continue, " \t\n\r");
            if (href.len == 0) continue;
            // A `data:` sheet needs no loader (Acid2's appendix sheet).
            if (weburl.decodeData(a, href) catch null) |d| {
                if (std.ascii.startsWithIgnoreCase(d.mime, "text/css")) try appendSheetText(a, &sheets, d.bytes, env, null, loader, keep);
                continue;
            }
            const ld = loader orelse continue;
            const got = ld.fetch(ld.ctx, href, null) orelse continue;
            try appendSheetText(a, &sheets, got.text, env, got.url, loader, keep);
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

test "style: custom properties cascade, inherit and substitute" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><style>
        \\  :root { --c: rgb(1, 2, 3); --w: 4px; --b: var(--w) solid var(--c) }
        \\  .x { --w: 6px; color: var(--c); border: var(--b); margin: var(--w) 0 }
        \\  .y { color: var(--missing, #0a0b0c); padding-left: var(--nope) }
        \\  .z { --c: red }
        \\</style>
        \\<p class=x>a</p><p class=y>b</p><div class=z><p class=x>c</p></div>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var ps: [3]NodeId = undefined;
    var n: usize = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        ps[n] = id;
        n += 1;
    };
    const x = styles.get(ps[0]);
    try std.testing.expect(x.color.r == 1 and x.color.g == 2 and x.color.b == 3);
    // --b was computed at the root, where --w is 4px.
    try std.testing.expectEqual(@as(f64, 4), x.border_width[0]);
    try std.testing.expectEqual(BorderStyle.solid, x.border_style[3]);
    try std.testing.expectEqual(@as(f64, 6), x.margin[0].px);
    const y = styles.get(ps[1]);
    try std.testing.expect(y.color.r == 10 and y.color.b == 12);
    // An unresolved var() is invalid at computed-value time: unset.
    try std.testing.expectEqual(@as(f64, 0), y.padding[3].px);
    // Custom properties inherit; the nearer declaration wins.
    const z = styles.get(ps[2]);
    try std.testing.expect(z.color.r == 255 and z.color.g == 0);
}

test "style: rem is of the root's size, and zoom scales every absolute length" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a, "<!DOCTYPE html><style>html { font-size: 62.5% } p { font-size: 1.4rem; margin-left: 10px; border-top: thin solid }</style><p>x</p>", .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    var p_id: NodeId = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        p_id = id;
    };
    const plain = try compute(a, doc, sheets, env);
    try std.testing.expectEqual(@as(f64, 14), plain.get(p_id).font_size);
    px_scale = 2;
    defer px_scale = 1;
    const zoomed = try compute(a, doc, sheets, env);
    try std.testing.expectEqual(@as(f64, 28), zoomed.get(p_id).font_size);
    try std.testing.expectEqual(@as(f64, 20), zoomed.get(p_id).margin[3].px);
    try std.testing.expectEqual(@as(f64, 2), zoomed.get(p_id).border_width[0]);
}

test "style: presentational hints sit under every author rule" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a, "<!DOCTYPE html><style>.w { width: 30px }</style><body bgcolor=ff0000 text=\"#00ff00\"><img class=w width=10 height=20><img width=\"50%\"><font color=blue size=5>f</font><td align=center valign=top nowrap>c</td>", .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var imgs: [2]NodeId = undefined;
    var n: usize = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| {
        if (doc.isHtml(id, "img")) {
            imgs[n] = id;
            n += 1;
        }
        if (doc.isHtml(id, "body")) {
            try std.testing.expectEqual(@as(f64, 255), styles.get(id).background_color.r);
            try std.testing.expectEqual(@as(f64, 255), styles.get(id).color.g);
        }
        if (doc.isHtml(id, "font")) {
            try std.testing.expectEqual(@as(f64, 255), styles.get(id).color.b);
            try std.testing.expectEqual(@as(f64, 24), styles.get(id).font_size);
        }
    }
    try std.testing.expectEqual(@as(f64, 30), styles.get(imgs[0]).width.px);
    try std.testing.expectEqual(@as(f64, 20), styles.get(imgs[0]).height.px);
    try std.testing.expectEqual(@as(f64, 50), styles.get(imgs[1]).width.percent);
}

// Acid2's second line under the cascade: the float rule's subject is
// named by attribute selectors alone, one with an escaped space.
test "style: an attribute-only subject with an escaped space floats" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 400, .height = 300 };
    const doc = try html.parse(a,
        \\<style>
        \\[class~=one].first.one { position: absolute; top: 0; }
        \\[class~=one][class~=first] [class=second\ two][class="second two"] { float: right; width: 48px; height: 12px; background: yellow; }
        \\</style><blockquote class="first one"><address class="second two"></address></blockquote>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var w = doc.walk(dom.document_id);
    var seen = false;
    while (w.next()) |id| if (doc.isHtml(id, "address")) {
        seen = true;
        try std.testing.expectEqual(Float.right, styles.get(id).float);
        try std.testing.expectEqual(@as(f64, 48), styles.get(id).width.px);
    };
    try std.testing.expect(seen);
}

test "style: backgrounds, gradients and radii" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><style>
        \\  .a { background: url(sprite.svg) no-repeat 10px -20px / 30px auto #fff }
        \\  .b { background-image: linear-gradient(transparent, transparent), url("x.png"); background-position: right bottom }
        \\  .c { background: linear-gradient(to right, red, blue 75%); border-radius: 4px 50% }
        \\  .d { background-image: linear-gradient(transparent, transparent) }
        \\</style><p class=a>a</p><p class=b>b</p><p class=c>c</p><p class=d>d</p>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var ps: [4]NodeId = undefined;
    var n: usize = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        ps[n] = id;
        n += 1;
    };
    const pa = styles.get(ps[0]);
    try std.testing.expectEqualStrings("sprite.svg", pa.background_image.url);
    try std.testing.expectEqual(@as(f64, 10), pa.background_position[0].px);
    try std.testing.expectEqual(@as(f64, -20), pa.background_position[1].px);
    try std.testing.expectEqual(@as(f64, 30), pa.background_size.size[0].px);
    try std.testing.expect(!pa.background_repeat[0] and !pa.background_repeat[1]);
    try std.testing.expectEqual(@as(f64, 255), pa.background_color.r);
    const pb = styles.get(ps[1]);
    // Of a tint over a picture, the picture.
    try std.testing.expectEqualStrings("x.png", pb.background_image.url);
    try std.testing.expectEqual(@as(f64, 100), pb.background_position[0].percent);
    const pc = styles.get(ps[2]);
    try std.testing.expectEqual(@as(f64, 90), pc.background_image.linear.angle);
    try std.testing.expectEqual(@as(usize, 2), pc.background_image.linear.stops.len);
    try std.testing.expectEqual(@as(f64, 75), pc.background_image.linear.stops[1].at.?.percent);
    try std.testing.expectEqual(@as(f64, 4), pc.border_radius[0].px);
    try std.testing.expectEqual(@as(f64, 50), pc.border_radius[1].percent);
    // An all-transparent gradient paints nothing.
    try std.testing.expect(styles.get(ps[3]).background_image == .none);
}

test "style: calc(), min(), max() and clamp()" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><style>
        \\  p { font-size: 10px; width: calc(100% - 2 * 1em); margin-left: calc((4px + 6px) / 2);
        \\      padding-left: max(3px, 1vw); padding-right: clamp(1px, 50px, 20px); height: calc(40px + 2em) }
        \\  .v { --gap: 8px; margin-top: calc(var(--gap) * -1) }
        \\</style><p class=v>x</p>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        const c = styles.get(id);
        try std.testing.expectEqual(@as(f64, 100), c.width.calc.pct);
        try std.testing.expectEqual(@as(f64, -20), c.width.calc.px);
        try std.testing.expectEqual(@as(f64, 5), c.margin[3].px);
        try std.testing.expectEqual(@as(f64, 10), c.padding[3].px);
        try std.testing.expectEqual(@as(f64, 20), c.padding[1].px);
        try std.testing.expectEqual(@as(f64, 60), c.height.px);
        try std.testing.expectEqual(@as(f64, -8), c.margin[0].px);
    };
}

test "style: cascade layers rank below unlayered rules, later layers above earlier" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a,
        \\<!DOCTYPE html><style>
        \\  @layer base, theme;
        \\  @layer theme { #p { color: rgb(0, 0, 3) } }
        \\  @layer base { #p { color: rgb(0, 0, 2); margin-left: 5px } a { text-decoration: none } #p { padding-left: 1px !important } }
        \\  p { color: rgb(0, 0, 9) }
        \\  #p { padding-left: 2px !important }
        \\  @container (min-width: 10px) { p { margin-top: 7px } }
        \\</style><p id=p>x <a href=y>l</a></p>
    , .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const styles = try compute(a, doc, sheets, env);
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| {
        if (doc.isHtml(id, "p")) {
            const c = styles.get(id);
            // Unlayered `p` beats the layered `#p`, specificity aside.
            try std.testing.expectEqual(@as(f64, 9), c.color.b);
            try std.testing.expectEqual(@as(f64, 5), c.margin[3].px);
            // Important: the layered declaration wins.
            try std.testing.expectEqual(@as(f64, 1), c.padding[3].px);
            try std.testing.expectEqual(@as(f64, 7), c.margin[0].px);
        }
        if (doc.isHtml(id, "a")) try std.testing.expect(!styles.get(id).text_decoration.underline);
    }
}

test "style: a big sheet parsed in pieces cascades as it does whole" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "<!DOCTYPE html><style>@layer base, top; @layer top { p { color: rgb(0, 0, 7) } }");
    for (0..4000) |i| try src.print(a, ".f{d} {{ color: red; margin: 1px }} ", .{i});
    try src.appendSlice(a, "@layer base { p { color: rgb(0, 0, 3); padding-left: 4px } } p { margin-left: 5px }</style><p>x</p>");
    try std.testing.expect(src.items.len > 2 * piece_bytes);
    const doc = try html.parse(a, src.items, .{});
    const whole = try collectDocumentSheets(a, doc, env);
    // A keeper that copies each parse into its own arena, as a page does.
    var kept_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer kept_arena.deinit();
    const K = struct {
        fn keepFn(_: *anyopaque, sheet: Sheet) Error!Sheet {
            return sheet;
        }
    };
    var dummy: u8 = 0;
    const keep: Keep = .{ .ctx = @ptrCast(&dummy), .a = kept_arena.allocator(), .keep = K.keepFn };
    const pieces = try collectDocumentSheetsKept(a, doc, env, try parseSheet(a, ua_sheet, .user_agent, env), null, keep);
    try std.testing.expect(pieces.len > whole.len);
    for ([_][]const Sheet{ whole, pieces }) |sheets| {
        const styles = try compute(a, doc, sheets, env);
        var w = doc.walk(dom.document_id);
        while (w.next()) |id| if (doc.isHtml(id, "p")) {
            const c = styles.get(id);
            // The later layer wins over the earlier across pieces.
            try std.testing.expectEqual(@as(f64, 7), c.color.b);
            try std.testing.expectEqual(@as(f64, 4), c.padding[3].px);
            try std.testing.expectEqual(@as(f64, 5), c.margin[3].px);
        };
    }
}

// GitHub's primer-react sheet is one `@layer` block of 300 KB: the
// pieces cut inside it close and reopen the layer.
test "style: a sheet wrapped in one layer is cut inside it and still cascades" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    var src: std.ArrayList(u8) = .empty;
    try src.appendSlice(a, "<!DOCTYPE html><style>@layer lo, hi; @layer hi { p { padding-left: 9px } } @layer lo { p { color: rgb(0, 0, 3) }");
    for (0..4000) |i| try src.print(a, " .f{d} {{ color: red }} @media (min-width: 1px) {{ .g{d} {{ margin: 1px }} }}", .{ i, i });
    try src.appendSlice(a, " p { padding-left: 4px; margin-left: 6px } } p { margin-top: 2px }</style><p class=f3>x</p>");
    const doc = try html.parse(a, src.items, .{});
    var kept_arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer kept_arena.deinit();
    const K = struct {
        fn keepFn(_: *anyopaque, sheet: Sheet) Error!Sheet {
            return sheet;
        }
    };
    var dummy: u8 = 0;
    const keep: Keep = .{ .ctx = @ptrCast(&dummy), .a = kept_arena.allocator(), .keep = K.keepFn };
    const pieces = try collectDocumentSheetsKept(a, doc, env, try parseSheet(a, ua_sheet, .user_agent, env), null, keep);
    try std.testing.expect(pieces.len > 3);
    const styles = try compute(a, doc, pieces, env);
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        const c = styles.get(id);
        // `.f3 { color: red }` inside the layer wins over `p` there.
        try std.testing.expectEqual(@as(f64, 255), c.color.r);
        // The later layer's padding beats the earlier's, across pieces.
        try std.testing.expectEqual(@as(f64, 9), c.padding[3].px);
        try std.testing.expectEqual(@as(f64, 6), c.margin[3].px);
        try std.testing.expectEqual(@as(f64, 2), c.margin[0].px);
    };
}

test "style: rules that cannot match the document are not kept, and equal styles are shared" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1000, .height = 800, .dark = false };
    const doc = try html.parse(a, "<!DOCTYPE html><style>.absent { color: red } p { color: blue } [data-theme=dark] p { color: green } .here p { margin: 1px }</style><div class=here data-theme=light><p>a</p><p>b</p></div>", .{});
    const sheets = try collectDocumentSheets(a, doc, env);
    const author = sheets[sheets.len - 1];
    // `.absent` and `[data-theme=dark]` cannot match: two rules left.
    try std.testing.expectEqual(@as(usize, 2), author.rules.len);
    const styles = try compute(a, doc, sheets, env);
    var ps: [2]NodeId = undefined;
    var n: usize = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "p")) {
        ps[n] = id;
        n += 1;
    };
    try std.testing.expect(styles.get(ps[0]) == styles.get(ps[1]));
    try std.testing.expectEqual(@as(f64, 255), styles.get(ps[0]).color.b);
}
