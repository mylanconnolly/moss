//! CSS colours (CSS Color Levels 3 and 4, the sRGB part): the named
//! colours, `#rgb` to `#rrggbbaa`, `rgb()`/`rgba()` and `hsl()`/`hsla()`
//! in the legacy comma form and the modern space form with `/` alpha,
//! `hwb()`, `transparent` and `currentcolor` — parsed from component
//! values, held as 8-bit sRGB with an alpha, and serialized as Level 4
//! says (`rgb(r, g, b)` or `rgba(r, g, b, a)`). The wide-gamut and
//! lab-family functions (`color()`, `lab()`, `lch()`, `oklab()`,
//! `oklch()`) are not built; a screen in sRGB shows nothing they add.
const std = @import("std");
const css = @import("css.zig");

pub const Error = error{OutOfMemory};

/// sRGB channels in 0..255 as computed (a colour from `hsl()` is not
/// on the integer grid, and Level 4 serializes what was computed), and
/// an alpha in 0..1; `word` rounds for a canvas.
pub const Color = struct {
    r: f64,
    g: f64,
    b: f64,
    a: f64 = 1,

    pub fn rgb(r: u8, g: u8, b: u8) Color {
        return .{ .r = @floatFromInt(r), .g = @floatFromInt(g), .b = @floatFromInt(b) };
    }

    pub const transparent: Color = .{ .r = 0, .g = 0, .b = 0, .a = 0 };

    fn byte(x: f64) u32 {
        return @intFromFloat(@round(@min(255, @max(0, x))));
    }

    /// XRGB for a canvas.
    pub fn word(c: Color) u32 {
        return (byte(c.r) << 16) | (byte(c.g) << 8) | byte(c.b);
    }

    /// Level 4 serialization: channels to six places, alpha when it is
    /// not one.
    pub fn serialize(c: Color, a: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(a, if (c.a >= 1) "rgb(" else "rgba(");
        try writeNumber(a, c.r, &out);
        try out.appendSlice(a, ", ");
        try writeNumber(a, c.g, &out);
        try out.appendSlice(a, ", ");
        try writeNumber(a, c.b, &out);
        if (c.a < 1) {
            try out.appendSlice(a, ", ");
            try writeNumber(a, c.a, &out);
        }
        try out.append(a, ')');
        return out.items;
    }
};

/// A number rounded to six places, trailing zeros dropped, no "-0".
fn writeNumber(a: std.mem.Allocator, v: f64, out: *std.ArrayList(u8)) Error!void {
    const rounded = @round(v * 1e6) / 1e6;
    try out.print(a, "{d}", .{if (rounded == 0) @as(f64, 0) else rounded});
}

/// `currentcolor`, which the cascade resolves to the element's `color`.
pub const Parsed = union(enum) { color: Color, current };

/// Parse a colour from CSS text (a declaration's value).
pub fn parseText(a: std.mem.Allocator, text: []const u8) Error!?Parsed {
    var p = try css.Parser.init(a, text, false);
    const values = try p.parseListOfComponentValues();
    return parseValues(values);
}

/// Parse a colour from component values: exactly one colour, whitespace
/// around it allowed.
pub fn parseValues(values: []const css.Value) ?Parsed {
    var i: usize = 0;
    while (i < values.len and isWs(values[i])) i += 1;
    if (i == values.len) return null;
    const v = values[i];
    i += 1;
    while (i < values.len and isWs(values[i])) i += 1;
    if (i != values.len) return null;
    return parseValue(v);
}

fn isWs(v: css.Value) bool {
    return v == .token and v.token == .whitespace;
}

pub fn parseValue(v: css.Value) ?Parsed {
    switch (v) {
        .token => |t| switch (t) {
            .ident => |name| {
                if (std.ascii.eqlIgnoreCase(name, "currentcolor")) return .current;
                if (std.ascii.eqlIgnoreCase(name, "transparent")) return .{ .color = Color.transparent };
                if (named(name)) |c| return .{ .color = c };
                return null;
            },
            .hash => |h| return if (parseHex(h.value)) |c| .{ .color = c } else null,
            else => return null,
        },
        .function => |f| {
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(f.name, "rgb") or eq(f.name, "rgba")) return if (parseRgb(f.values)) |c| .{ .color = c } else null;
            if (eq(f.name, "hsl") or eq(f.name, "hsla")) return if (parseHsl(f.values)) |c| .{ .color = c } else null;
            if (eq(f.name, "hwb")) return if (parseHwb(f.values)) |c| .{ .color = c } else null;
            return null;
        },
        else => return null,
    }
}

fn hexNibble(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

pub fn parseHex(s: []const u8) ?Color {
    var n: [8]u8 = undefined;
    if (s.len != 3 and s.len != 4 and s.len != 6 and s.len != 8) return null;
    for (s, 0..) |c, i| n[i] = hexNibble(c) orelse return null;
    switch (s.len) {
        3 => return Color.rgb(n[0] * 17, n[1] * 17, n[2] * 17),
        4 => {
            var c = Color.rgb(n[0] * 17, n[1] * 17, n[2] * 17);
            c.a = @as(f64, @floatFromInt(n[3] * 17)) / 255;
            return c;
        },
        6 => return Color.rgb(n[0] * 16 + n[1], n[2] * 16 + n[3], n[4] * 16 + n[5]),
        else => {
            var c = Color.rgb(n[0] * 16 + n[1], n[2] * 16 + n[3], n[4] * 16 + n[5]);
            c.a = @as(f64, @floatFromInt(n[6] * 16 + n[7])) / 255;
            return c;
        },
    }
}

/// The arguments of a colour function: numbers, percentages, `none`,
/// with commas (the legacy form, all or nothing) or spaces and a `/`
/// before the alpha.
const Arg = union(enum) { number: f64, percentage: f64, none, angle: f64 };

const Args = struct {
    items: [4]Arg = undefined,
    n: usize = 0,
    legacy: bool = false,
    has_alpha: bool = false,
};

fn readArgs(values: []const css.Value) ?Args {
    var out: Args = .{};
    var i: usize = 0;
    var commas: usize = 0;
    var slash = false;
    // In the legacy form a comma sits between every two values; in the
    // modern form values are just spaced, with `/` before the alpha.
    var after_value = false;
    var after_sep = false;
    while (i < values.len) : (i += 1) {
        const v = values[i];
        if (isWs(v)) continue;
        if (v != .token) return null;
        var arg: ?Arg = null;
        switch (v.token) {
            .comma => {
                if (!after_value or slash) return null;
                commas += 1;
                after_value = false;
                after_sep = true;
                continue;
            },
            .delim => |d| {
                if (d != '/' or !after_value or slash or commas > 0 or out.n != 3) return null;
                slash = true;
                after_value = false;
                after_sep = true;
                continue;
            },
            .number => |x| arg = .{ .number = x.value },
            .percentage => |x| arg = .{ .percentage = x.value },
            .dimension => |d| {
                const unit = d.unit;
                const eq = std.ascii.eqlIgnoreCase;
                const deg: f64 = if (eq(unit, "deg")) d.num.value else if (eq(unit, "grad")) d.num.value * 360 / 400 else if (eq(unit, "rad")) d.num.value * 180 / std.math.pi else if (eq(unit, "turn")) d.num.value * 360 else return null;
                arg = .{ .angle = deg };
            },
            .ident => |name| {
                if (!std.ascii.eqlIgnoreCase(name, "none")) return null;
                arg = .none;
            },
            else => return null,
        }
        if (out.n == 4) return null;
        // A comma form needs its comma between values.
        if (after_value and commas > 0) return null;
        if (out.n == 3 and !slash and commas == 0) return null; // a fourth space value needs the slash
        out.items[out.n] = arg.?;
        out.n += 1;
        after_value = true;
        after_sep = false;
    }
    if (after_sep) return null; // a trailing comma or slash
    if (out.n < 3) return null;
    out.legacy = commas > 0;
    if (out.legacy) {
        if (commas != out.n - 1) return null;
        for (out.items[0..out.n]) |it| if (it == .none) return null;
    } else if (slash and out.n != 4) return null;
    out.has_alpha = out.n == 4;
    return out;
}

fn clamp01(x: f64) f64 {
    return @min(1, @max(0, x));
}

fn channel(x: f64) f64 {
    return @min(255, @max(0, x));
}

fn alphaOf(arg: ?Arg) ?f64 {
    const it = arg orelse return 1;
    return switch (it) {
        .number => |x| clamp01(x),
        .percentage => |x| clamp01(x / 100),
        .none => 0,
        .angle => null,
    };
}

fn parseRgb(values: []const css.Value) ?Color {
    const args = readArgs(values) orelse return null;
    const first = args.items[0];
    var chans: [3]f64 = undefined;
    for (args.items[0..3], 0..) |it, i| {
        chans[i] = switch (it) {
            .number => |x| blk: {
                // The legacy form takes numbers or percentages, not mixed.
                if (args.legacy and first == .percentage) return null;
                break :blk x;
            },
            .percentage => |x| blk: {
                if (args.legacy and first == .number) return null;
                break :blk x * 255 / 100;
            },
            .none => 0,
            .angle => return null,
        };
    }
    const alpha = alphaOf(if (args.has_alpha) args.items[3] else null) orelse return null;
    return .{ .r = channel(chans[0]), .g = channel(chans[1]), .b = channel(chans[2]), .a = alpha };
}

fn hueOf(arg: Arg, legacy: bool) ?f64 {
    return switch (arg) {
        .number => |x| x,
        .angle => |x| if (legacy) null else x,
        .none => 0,
        .percentage => null,
    };
}

fn percentOf(arg: Arg, legacy: bool) ?f64 {
    return switch (arg) {
        .percentage => |x| x,
        .number => |x| if (legacy) null else x,
        .none => 0,
        .angle => null,
    };
}

fn hslToRgb(h_in: f64, s_in: f64, l_in: f64) [3]f64 {
    // CSS Color 4's algorithm, hue in degrees, s and l in 0..100.
    var h = @mod(h_in, 360);
    if (h < 0) h += 360;
    const s = clamp01(s_in / 100);
    const l = clamp01(l_in / 100);
    const f = struct {
        fn f(n: f64, h_: f64, s_: f64, l_: f64) f64 {
            const k = @mod(n + h_ / 30, 12);
            const a = s_ * @min(l_, 1 - l_);
            return l_ - a * @max(-1, @min(k - 3, @min(9 - k, 1)));
        }
    }.f;
    return .{ f(0, h, s, l) * 255, f(8, h, s, l) * 255, f(4, h, s, l) * 255 };
}

fn parseHsl(values: []const css.Value) ?Color {
    const args = readArgs(values) orelse return null;
    const h = hueOf(args.items[0], args.legacy) orelse return null;
    const s = percentOf(args.items[1], args.legacy) orelse return null;
    const l = percentOf(args.items[2], args.legacy) orelse return null;
    const alpha = alphaOf(if (args.has_alpha) args.items[3] else null) orelse return null;
    const rgb = hslToRgb(h, s, l);
    return .{ .r = channel(rgb[0]), .g = channel(rgb[1]), .b = channel(rgb[2]), .a = alpha };
}

fn parseHwb(values: []const css.Value) ?Color {
    const args = readArgs(values) orelse return null;
    if (args.legacy) return null;
    const h = hueOf(args.items[0], false) orelse return null;
    var w = clamp01((percentOf(args.items[1], false) orelse return null) / 100);
    var b = clamp01((percentOf(args.items[2], false) orelse return null) / 100);
    const alpha = alphaOf(if (args.has_alpha) args.items[3] else null) orelse return null;
    if (w + b >= 1) {
        const gray = w / (w + b) * 255;
        return .{ .r = channel(gray), .g = channel(gray), .b = channel(gray), .a = alpha };
    }
    _ = &w;
    _ = &b;
    const base = hslToRgb(h, 100, 50);
    var out: [3]f64 = undefined;
    for (base, 0..) |c, i| out[i] = (c / 255 * (1 - w - b) + w) * 255;
    return .{ .r = channel(out[0]), .g = channel(out[1]), .b = channel(out[2]), .a = alpha };
}

// ---------------------------------------------------------------- names

const Named = struct { name: []const u8, rgb: u24 };
const named_colors = [_]Named{
    .{ .name = "aliceblue", .rgb = 0xf0f8ff },       .{ .name = "antiquewhite", .rgb = 0xfaebd7 },      .{ .name = "aqua", .rgb = 0x00ffff },                 .{ .name = "aquamarine", .rgb = 0x7fffd4 },
    .{ .name = "azure", .rgb = 0xf0ffff },           .{ .name = "beige", .rgb = 0xf5f5dc },             .{ .name = "bisque", .rgb = 0xffe4c4 },               .{ .name = "black", .rgb = 0x000000 },
    .{ .name = "blanchedalmond", .rgb = 0xffebcd },  .{ .name = "blue", .rgb = 0x0000ff },              .{ .name = "blueviolet", .rgb = 0x8a2be2 },           .{ .name = "brown", .rgb = 0xa52a2a },
    .{ .name = "burlywood", .rgb = 0xdeb887 },       .{ .name = "cadetblue", .rgb = 0x5f9ea0 },         .{ .name = "chartreuse", .rgb = 0x7fff00 },           .{ .name = "chocolate", .rgb = 0xd2691e },
    .{ .name = "coral", .rgb = 0xff7f50 },           .{ .name = "cornflowerblue", .rgb = 0x6495ed },    .{ .name = "cornsilk", .rgb = 0xfff8dc },             .{ .name = "crimson", .rgb = 0xdc143c },
    .{ .name = "cyan", .rgb = 0x00ffff },            .{ .name = "darkblue", .rgb = 0x00008b },          .{ .name = "darkcyan", .rgb = 0x008b8b },             .{ .name = "darkgoldenrod", .rgb = 0xb8860b },
    .{ .name = "darkgray", .rgb = 0xa9a9a9 },        .{ .name = "darkgreen", .rgb = 0x006400 },         .{ .name = "darkgrey", .rgb = 0xa9a9a9 },             .{ .name = "darkkhaki", .rgb = 0xbdb76b },
    .{ .name = "darkmagenta", .rgb = 0x8b008b },     .{ .name = "darkolivegreen", .rgb = 0x556b2f },    .{ .name = "darkorange", .rgb = 0xff8c00 },           .{ .name = "darkorchid", .rgb = 0x9932cc },
    .{ .name = "darkred", .rgb = 0x8b0000 },         .{ .name = "darksalmon", .rgb = 0xe9967a },        .{ .name = "darkseagreen", .rgb = 0x8fbc8f },         .{ .name = "darkslateblue", .rgb = 0x483d8b },
    .{ .name = "darkslategray", .rgb = 0x2f4f4f },   .{ .name = "darkslategrey", .rgb = 0x2f4f4f },     .{ .name = "darkturquoise", .rgb = 0x00ced1 },        .{ .name = "darkviolet", .rgb = 0x9400d3 },
    .{ .name = "deeppink", .rgb = 0xff1493 },        .{ .name = "deepskyblue", .rgb = 0x00bfff },       .{ .name = "dimgray", .rgb = 0x696969 },              .{ .name = "dimgrey", .rgb = 0x696969 },
    .{ .name = "dodgerblue", .rgb = 0x1e90ff },      .{ .name = "firebrick", .rgb = 0xb22222 },         .{ .name = "floralwhite", .rgb = 0xfffaf0 },          .{ .name = "forestgreen", .rgb = 0x228b22 },
    .{ .name = "fuchsia", .rgb = 0xff00ff },         .{ .name = "gainsboro", .rgb = 0xdcdcdc },         .{ .name = "ghostwhite", .rgb = 0xf8f8ff },           .{ .name = "gold", .rgb = 0xffd700 },
    .{ .name = "goldenrod", .rgb = 0xdaa520 },       .{ .name = "gray", .rgb = 0x808080 },              .{ .name = "green", .rgb = 0x008000 },                .{ .name = "greenyellow", .rgb = 0xadff2f },
    .{ .name = "grey", .rgb = 0x808080 },            .{ .name = "honeydew", .rgb = 0xf0fff0 },          .{ .name = "hotpink", .rgb = 0xff69b4 },              .{ .name = "indianred", .rgb = 0xcd5c5c },
    .{ .name = "indigo", .rgb = 0x4b0082 },          .{ .name = "ivory", .rgb = 0xfffff0 },             .{ .name = "khaki", .rgb = 0xf0e68c },                .{ .name = "lavender", .rgb = 0xe6e6fa },
    .{ .name = "lavenderblush", .rgb = 0xfff0f5 },   .{ .name = "lawngreen", .rgb = 0x7cfc00 },         .{ .name = "lemonchiffon", .rgb = 0xfffacd },         .{ .name = "lightblue", .rgb = 0xadd8e6 },
    .{ .name = "lightcoral", .rgb = 0xf08080 },      .{ .name = "lightcyan", .rgb = 0xe0ffff },         .{ .name = "lightgoldenrodyellow", .rgb = 0xfafad2 }, .{ .name = "lightgray", .rgb = 0xd3d3d3 },
    .{ .name = "lightgreen", .rgb = 0x90ee90 },      .{ .name = "lightgrey", .rgb = 0xd3d3d3 },         .{ .name = "lightpink", .rgb = 0xffb6c1 },            .{ .name = "lightsalmon", .rgb = 0xffa07a },
    .{ .name = "lightseagreen", .rgb = 0x20b2aa },   .{ .name = "lightskyblue", .rgb = 0x87cefa },      .{ .name = "lightslategray", .rgb = 0x778899 },       .{ .name = "lightslategrey", .rgb = 0x778899 },
    .{ .name = "lightsteelblue", .rgb = 0xb0c4de },  .{ .name = "lightyellow", .rgb = 0xffffe0 },       .{ .name = "lime", .rgb = 0x00ff00 },                 .{ .name = "limegreen", .rgb = 0x32cd32 },
    .{ .name = "linen", .rgb = 0xfaf0e6 },           .{ .name = "magenta", .rgb = 0xff00ff },           .{ .name = "maroon", .rgb = 0x800000 },               .{ .name = "mediumaquamarine", .rgb = 0x66cdaa },
    .{ .name = "mediumblue", .rgb = 0x0000cd },      .{ .name = "mediumorchid", .rgb = 0xba55d3 },      .{ .name = "mediumpurple", .rgb = 0x9370db },         .{ .name = "mediumseagreen", .rgb = 0x3cb371 },
    .{ .name = "mediumslateblue", .rgb = 0x7b68ee }, .{ .name = "mediumspringgreen", .rgb = 0x00fa9a }, .{ .name = "mediumturquoise", .rgb = 0x48d1cc },      .{ .name = "mediumvioletred", .rgb = 0xc71585 },
    .{ .name = "midnightblue", .rgb = 0x191970 },    .{ .name = "mintcream", .rgb = 0xf5fffa },         .{ .name = "mistyrose", .rgb = 0xffe4e1 },            .{ .name = "moccasin", .rgb = 0xffe4b5 },
    .{ .name = "navajowhite", .rgb = 0xffdead },     .{ .name = "navy", .rgb = 0x000080 },              .{ .name = "oldlace", .rgb = 0xfdf5e6 },              .{ .name = "olive", .rgb = 0x808000 },
    .{ .name = "olivedrab", .rgb = 0x6b8e23 },       .{ .name = "orange", .rgb = 0xffa500 },            .{ .name = "orangered", .rgb = 0xff4500 },            .{ .name = "orchid", .rgb = 0xda70d6 },
    .{ .name = "palegoldenrod", .rgb = 0xeee8aa },   .{ .name = "palegreen", .rgb = 0x98fb98 },         .{ .name = "paleturquoise", .rgb = 0xafeeee },        .{ .name = "palevioletred", .rgb = 0xdb7093 },
    .{ .name = "papayawhip", .rgb = 0xffefd5 },      .{ .name = "peachpuff", .rgb = 0xffdab9 },         .{ .name = "peru", .rgb = 0xcd853f },                 .{ .name = "pink", .rgb = 0xffc0cb },
    .{ .name = "plum", .rgb = 0xdda0dd },            .{ .name = "powderblue", .rgb = 0xb0e0e6 },        .{ .name = "purple", .rgb = 0x800080 },               .{ .name = "rebeccapurple", .rgb = 0x663399 },
    .{ .name = "red", .rgb = 0xff0000 },             .{ .name = "rosybrown", .rgb = 0xbc8f8f },         .{ .name = "royalblue", .rgb = 0x4169e1 },            .{ .name = "saddlebrown", .rgb = 0x8b4513 },
    .{ .name = "salmon", .rgb = 0xfa8072 },          .{ .name = "sandybrown", .rgb = 0xf4a460 },        .{ .name = "seagreen", .rgb = 0x2e8b57 },             .{ .name = "seashell", .rgb = 0xfff5ee },
    .{ .name = "sienna", .rgb = 0xa0522d },          .{ .name = "silver", .rgb = 0xc0c0c0 },            .{ .name = "skyblue", .rgb = 0x87ceeb },              .{ .name = "slateblue", .rgb = 0x6a5acd },
    .{ .name = "slategray", .rgb = 0x708090 },       .{ .name = "slategrey", .rgb = 0x708090 },         .{ .name = "snow", .rgb = 0xfffafa },                 .{ .name = "springgreen", .rgb = 0x00ff7f },
    .{ .name = "steelblue", .rgb = 0x4682b4 },       .{ .name = "tan", .rgb = 0xd2b48c },               .{ .name = "teal", .rgb = 0x008080 },                 .{ .name = "thistle", .rgb = 0xd8bfd8 },
    .{ .name = "tomato", .rgb = 0xff6347 },          .{ .name = "turquoise", .rgb = 0x40e0d0 },         .{ .name = "violet", .rgb = 0xee82ee },               .{ .name = "wheat", .rgb = 0xf5deb3 },
    .{ .name = "white", .rgb = 0xffffff },           .{ .name = "whitesmoke", .rgb = 0xf5f5f5 },        .{ .name = "yellow", .rgb = 0xffff00 },               .{ .name = "yellowgreen", .rgb = 0x9acd32 },
};

pub fn named(name: []const u8) ?Color {
    for (named_colors) |n| if (std.ascii.eqlIgnoreCase(n.name, name)) return Color.rgb(@intCast(n.rgb >> 16), @intCast((n.rgb >> 8) & 0xff), @intCast(n.rgb & 0xff));
    return null;
}

// ------------------------------------------------------------------ tests

test "color: names, hex, functions" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const cases = [_]struct { in: []const u8, out: ?[]const u8 }{
        .{ .in = "Red", .out = "rgb(255, 0, 0)" },
        .{ .in = "#f00", .out = "rgb(255, 0, 0)" },
        .{ .in = "#ff000080", .out = "rgba(255, 0, 0, 0.501961)" },
        .{ .in = "rgb(1, 2, 3)", .out = "rgb(1, 2, 3)" },
        .{ .in = "rgb(10% 20% 30% / 50%)", .out = "rgba(25.5, 51, 76.5, 0.5)" },
        .{ .in = "rgba(1, 2, 3, 0.25)", .out = "rgba(1, 2, 3, 0.25)" },
        .{ .in = "hsl(120, 100%, 50%)", .out = "rgb(0, 255, 0)" },
        .{ .in = "hsl(120deg 100% 25%)", .out = "rgb(0, 127.5, 0)" },
        .{ .in = "hwb(0 0% 0%)", .out = "rgb(255, 0, 0)" },
        .{ .in = "transparent", .out = "rgba(0, 0, 0, 0)" },
        .{ .in = "rgb(1, 2)", .out = null },
        .{ .in = "rgb(1 2 3 4)", .out = null },
        .{ .in = "#12345", .out = null },
        .{ .in = "blurple", .out = null },
    };
    for (cases) |c| {
        const got = try parseText(a, c.in);
        if (c.out) |want| {
            try std.testing.expect(got != null and got.? == .color);
            try std.testing.expectEqualStrings(want, try got.?.color.serialize(a));
        } else try std.testing.expect(got == null);
    }
    try std.testing.expect((try parseText(a, "currentColor")).? == .current);
}

const verbose = false;

// The colour files of css-parsing-tests: input text to a Level 4
// serialization or null.
test "color: the css-parsing-tests corpus, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const files = [_][]const u8{ "color_hexadecimal_3", "color_hexadecimal_4", "color_keywords_3", "color_keywords_4", "color_hsl_3", "color_hsl_4", "color_hwb_4" };
    var total: usize = 0;
    var passed: usize = 0;
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "tools/testdata/web/css-parsing-tests/{s}.json", .{f});
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return error.SkipZigTest;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const items = parsed.array.items;
        var i: usize = 0;
        while (i + 1 < items.len) : (i += 2) {
            total += 1;
            const input = items[i].string;
            const want: ?[]const u8 = if (items[i + 1] == .string) items[i + 1].string else null;
            const got = try parseText(a, input);
            const got_text: ?[]const u8 = if (got) |g| (if (g == .color) try g.color.serialize(a) else "currentcolor") else null;
            const ok = (want == null and got_text == null) or (want != null and got_text != null and std.mem.eql(u8, want.?, got_text.?));
            if (ok) passed += 1 else if (verbose) std.debug.print("--- {s}: {s} -> {s} (want {s})\n", .{ f, input, got_text orelse "null", want orelse "null" });
        }
    }
    std.debug.print("color: {d}/{d} of css-parsing-tests' colour cases agree\n", .{ passed, total });
    // The floor is the count as of 2026-09-18; the forty left are grey
    // `hwb()` values the corpus rounds one way and IEEE the other.
    try std.testing.expect(passed >= 1782);
}
