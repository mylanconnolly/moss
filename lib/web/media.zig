//! Media queries (Media Queries Levels 3 and 4, the part a screen on a
//! desktop asks): a media query list parsed from component values —
//! `screen`, `print`, `all`, `not`, `only`, `and`, `or`, commas — with
//! the features `width`, `height`, their `min-`/`max-` forms and the
//! range syntax (`(width >= 600px)`), `orientation`,
//! `prefers-color-scheme`, `prefers-contrast`, `prefers-reduced-motion`,
//! `hover` and `pointer`, evaluated against an `Env` the session
//! provides (the viewport, the appearance axes). Anything unknown
//! evaluates to false, as the standard says an unknown feature must.
const std = @import("std");
const css = @import("css.zig");

pub const Error = error{OutOfMemory};

pub const Env = struct {
    width: f64,
    height: f64,
    /// The session's theme axis.
    dark: bool = false,
    /// The session's contrast axis.
    high_contrast: bool = false,
    reduced_motion: bool = false,
    print: bool = false,
    /// A pointing device that hovers (a mouse), against a touch screen.
    can_hover: bool = true,
};

const Feature = enum { width, height, min_width, max_width, min_height, max_height, orientation, prefers_color_scheme, prefers_contrast, prefers_reduced_motion, hover, pointer, unknown };

const Cmp = enum { lt, le, gt, ge, eq };

const Node = union(enum) {
    /// A media type; `all` matches everything, `screen` when not printing.
    media_type: []const u8,
    /// A feature in a block, already reduced to a predicate.
    feature: struct { feature: Feature, cmp: Cmp, value: f64, ident: []const u8 },
    not: *const Node,
    all_of: []const Node,
    any_of: []const Node,
    /// A block the parser could not read: false.
    unknown,
};

pub const Query = struct {
    root: Node,

    /// A media query list from CSS text (a `media` attribute, an
    /// `@media` prelude). An empty list means `all`.
    pub fn parseText(a: std.mem.Allocator, text: []const u8) Error!Query {
        var p = try css.Parser.init(a, text, false);
        return parseValues(a, try p.parseListOfComponentValues());
    }

    pub fn parseValues(a: std.mem.Allocator, values: []const css.Value) Error!Query {
        var parts: std.ArrayList(Node) = .empty;
        var start: usize = 0;
        var i: usize = 0;
        while (i <= values.len) : (i += 1) {
            if (i == values.len or (values[i] == .token and values[i].token == .comma)) {
                const q = try parseOne(a, values[start..i]);
                try parts.append(a, q);
                start = i + 1;
            }
        }
        if (parts.items.len == 1) return .{ .root = parts.items[0] };
        return .{ .root = .{ .any_of = parts.items } };
    }

    pub fn matches(q: *const Query, env: Env) bool {
        return eval(q.root, env);
    }
};

fn isWs(v: css.Value) bool {
    return v == .token and v.token == .whitespace;
}

fn identOf(v: css.Value) ?[]const u8 {
    return if (v == .token and v.token == .ident) v.token.ident else null;
}

/// One query: `[not|only]? type [and cond]*` or a condition alone.
fn parseOne(a: std.mem.Allocator, values: []const css.Value) Error!Node {
    return parseOneValues(a, values);
}

fn parseOneValues(a: std.mem.Allocator, values: []const css.Value) Error!Node {
    var items: std.ArrayList(css.Value) = .empty;
    for (values) |v| if (!isWs(v)) try items.append(a, v);
    const toks = items.items;
    if (toks.len == 0) return .{ .media_type = "all" };
    var i: usize = 0;
    var negate = false;
    if (identOf(toks[0])) |w| {
        if (std.ascii.eqlIgnoreCase(w, "not")) {
            negate = true;
            i = 1;
        } else if (std.ascii.eqlIgnoreCase(w, "only")) {
            i = 1;
        }
    }
    var terms: std.ArrayList(Node) = .empty;
    var any_or = false;
    var first = true;
    while (i < toks.len) {
        if (!first) {
            const w = identOf(toks[i]) orelse return .unknown;
            if (std.ascii.eqlIgnoreCase(w, "and")) {
                // fine
            } else if (std.ascii.eqlIgnoreCase(w, "or")) {
                any_or = true;
            } else return .unknown;
            i += 1;
            if (i >= toks.len) return .unknown;
        }
        const t = toks[i];
        i += 1;
        first = false;
        if (identOf(t)) |w| {
            if (std.ascii.eqlIgnoreCase(w, "not")) {
                // `not (cond)`: a negated block follows.
                if (i >= toks.len) return .unknown;
                const inner = try parseOneValues(a, toks[i .. i + 1]);
                i += 1;
                const boxed = try a.create(Node);
                boxed.* = inner;
                try terms.append(a, .{ .not = boxed });
                continue;
            }
            try terms.append(a, .{ .media_type = w });
            continue;
        }
        if (t == .block and t.block.kind == '(') {
            try terms.append(a, try parseBlock(a, t.block.values));
            continue;
        }
        return .unknown;
    }
    const body: Node = if (terms.items.len == 1) terms.items[0] else if (any_or) .{ .any_of = terms.items } else .{ .all_of = terms.items };
    if (!negate) return body;
    const boxed = try a.create(Node);
    boxed.* = body;
    return .{ .not = boxed };
}

/// The inside of `( … )`: a feature with a value, a bare feature, a
/// range, or a nested condition.
fn parseBlock(a: std.mem.Allocator, values: []const css.Value) Error!Node {
    var items: std.ArrayList(css.Value) = .empty;
    for (values) |v| if (!isWs(v)) try items.append(a, v);
    const toks = items.items;
    if (toks.len == 0) return .unknown;
    // A nested condition: `((a) and (b))`, `(not (a))`.
    if (toks[0] == .block or (identOf(toks[0]) != null and std.ascii.eqlIgnoreCase(identOf(toks[0]).?, "not") and toks.len > 1 and toks[1] == .block)) return parseOneValues(a, values);
    const name = identOf(toks[0]) orelse return .unknown;
    const feature = featureNamed(name);
    if (toks.len == 1) {
        // A bare feature is true when its value is not zero/none.
        return .{ .feature = .{ .feature = feature, .cmp = .gt, .value = 0, .ident = "" } };
    }
    // `name: value` or `name <op> value`.
    if (toks[1] == .token and toks[1].token == .colon) {
        if (toks.len != 3) return .unknown;
        return featureNode(feature, .eq, toks[2]);
    }
    // The range form: `width >= 600px`; the two-sided form is not built.
    if (toks.len == 3 or toks.len == 4) {
        var j: usize = 1;
        var cmp: Cmp = undefined;
        const d0 = delimOf(toks[j]) orelse return .unknown;
        j += 1;
        if (d0 == '<' or d0 == '>') {
            cmp = if (d0 == '<') .lt else .gt;
            if (j < toks.len - 1) if (delimOf(toks[j])) |d1| if (d1 == '=') {
                cmp = if (d0 == '<') .le else .ge;
                j += 1;
            };
        } else if (d0 == '=') {
            cmp = .eq;
        } else return .unknown;
        if (j != toks.len - 1) return .unknown;
        return featureNode(feature, cmp, toks[j]);
    }
    return .unknown;
}

fn delimOf(v: css.Value) ?u8 {
    return if (v == .token and v.token == .delim) v.token.delim else null;
}

fn featureNamed(name: []const u8) Feature {
    const eq = std.ascii.eqlIgnoreCase;
    if (eq(name, "width")) return .width;
    if (eq(name, "height")) return .height;
    if (eq(name, "min-width")) return .min_width;
    if (eq(name, "max-width")) return .max_width;
    if (eq(name, "min-height")) return .min_height;
    if (eq(name, "max-height")) return .max_height;
    if (eq(name, "orientation")) return .orientation;
    if (eq(name, "prefers-color-scheme")) return .prefers_color_scheme;
    if (eq(name, "prefers-contrast")) return .prefers_contrast;
    if (eq(name, "prefers-reduced-motion")) return .prefers_reduced_motion;
    if (eq(name, "hover") or eq(name, "any-hover")) return .hover;
    if (eq(name, "pointer") or eq(name, "any-pointer")) return .pointer;
    return .unknown;
}

fn featureNode(feature: Feature, cmp: Cmp, v: css.Value) Node {
    switch (feature) {
        .min_width, .min_height => return .{ .feature = .{ .feature = feature, .cmp = .ge, .value = lengthOf(v) orelse return .unknown, .ident = "" } },
        .max_width, .max_height => return .{ .feature = .{ .feature = feature, .cmp = .le, .value = lengthOf(v) orelse return .unknown, .ident = "" } },
        .width, .height => return .{ .feature = .{ .feature = feature, .cmp = cmp, .value = lengthOf(v) orelse return .unknown, .ident = "" } },
        .orientation, .prefers_color_scheme, .prefers_contrast, .prefers_reduced_motion, .hover, .pointer => return .{ .feature = .{ .feature = feature, .cmp = .eq, .value = 0, .ident = identOf(v) orelse return .unknown } },
        .unknown => return .unknown,
    }
}

/// A length in CSS pixels: px, em/rem at 16px, and the absolute units.
pub fn lengthOf(v: css.Value) ?f64 {
    if (v == .function) return mathOf(v, 0);
    if (v != .token) return null;
    switch (v.token) {
        .number => |n| return if (n.value == 0) 0 else null,
        .dimension => |d| {
            const eq = std.ascii.eqlIgnoreCase;
            const x = d.num.value;
            if (eq(d.unit, "px")) return x;
            if (eq(d.unit, "em") or eq(d.unit, "rem")) return x * 16;
            if (eq(d.unit, "in")) return x * 96;
            if (eq(d.unit, "cm")) return x * 96 / 2.54;
            if (eq(d.unit, "mm")) return x * 96 / 25.4;
            if (eq(d.unit, "pt")) return x * 96 / 72;
            if (eq(d.unit, "pc")) return x * 16;
            if (eq(d.unit, "q")) return x * 96 / 101.6;
            return null;
        },
        else => return null,
    }
}

/// `calc()`, `min()`, `max()`, `clamp()` of lengths (no percentages
/// in a media query): `(width <= calc(48rem - .02px))`.
fn mathOf(v: css.Value, depth: u8) ?f64 {
    if (depth > 8 or v != .function) return null;
    const eq = std.ascii.eqlIgnoreCase;
    const f = v.function;
    if (eq(f.name, "calc")) return (mathSum(f.values, depth) orelse return null).len;
    if (!(eq(f.name, "min") or eq(f.name, "max") or eq(f.name, "clamp"))) return null;
    var args: [4]f64 = undefined;
    var n: usize = 0;
    var start: usize = 0;
    for (0..f.values.len + 1) |i| {
        if (i < f.values.len and !(f.values[i] == .token and f.values[i].token == .comma)) continue;
        if (n == args.len) return null;
        args[n] = (mathSum(f.values[start..i], depth) orelse return null).len;
        n += 1;
        start = i + 1;
    }
    if (n == 0) return null;
    if (eq(f.name, "clamp")) return if (n == 3) @max(args[0], @min(args[1], args[2])) else null;
    var best = args[0];
    for (args[1..n]) |x| best = if (eq(f.name, "min")) @min(best, x) else @max(best, x);
    return best;
}

const MathTerm = struct { len: f64 = 0, num: f64 = 0, is_len: bool = false };

fn mathSum(vals_in: []const css.Value, depth: u8) ?MathTerm {
    var buf: [32]css.Value = undefined;
    var n: usize = 0;
    for (vals_in) |x| if (!(x == .token and x.token == .whitespace)) {
        if (n == buf.len) return null;
        buf[n] = x;
        n += 1;
    };
    const vals = buf[0..n];
    var total: MathTerm = .{};
    var sign: f64 = 1;
    var i: usize = 0;
    while (i < vals.len) {
        var j = i;
        while (j < vals.len and !isDelim(vals[j], '+') and !isDelim(vals[j], '-')) j += 1;
        const t = mathProduct(vals[i..j], depth) orelse return null;
        total.len += sign * t.len;
        total.num += sign * t.num;
        total.is_len = total.is_len or t.is_len;
        if (j == vals.len) break;
        sign = if (isDelim(vals[j], '+')) 1 else -1;
        i = j + 1;
    }
    return if (vals.len == 0) null else total;
}

fn isDelim(v: css.Value, c: u8) bool {
    return v == .token and v.token == .delim and v.token.delim == c;
}

fn mathProduct(vals: []const css.Value, depth: u8) ?MathTerm {
    if (vals.len == 0) return null;
    var acc = mathAtom(vals[0], depth) orelse return null;
    var i: usize = 1;
    while (i + 1 < vals.len + 1 and i < vals.len) : (i += 2) {
        if (i + 1 >= vals.len) return null;
        const rhs = mathAtom(vals[i + 1], depth) orelse return null;
        if (isDelim(vals[i], '*')) {
            if (acc.is_len and rhs.is_len) return null;
            if (rhs.is_len) {
                acc = .{ .len = rhs.len * acc.num, .is_len = true };
            } else if (acc.is_len) acc.len *= rhs.num else acc.num *= rhs.num;
        } else if (isDelim(vals[i], '/')) {
            if (rhs.is_len or rhs.num == 0) return null;
            if (acc.is_len) acc.len /= rhs.num else acc.num /= rhs.num;
        } else return null;
    }
    return acc;
}

fn mathAtom(v: css.Value, depth: u8) ?MathTerm {
    switch (v) {
        .token => |t| switch (t) {
            .number => |num| return .{ .num = num.value },
            .dimension => return .{ .len = lengthOf(v) orelse return null, .is_len = true },
            else => return null,
        },
        .block => |b| return if (b.kind == '(') mathSum(b.values, depth + 1) else null,
        .function => return .{ .len = mathOf(v, depth + 1) orelse return null, .is_len = true },
        else => return null,
    }
}

fn eval(n: Node, env: Env) bool {
    switch (n) {
        .media_type => |t| {
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(t, "all")) return true;
            if (eq(t, "screen")) return !env.print;
            if (eq(t, "print")) return env.print;
            return false;
        },
        .not => |inner| return !eval(inner.*, env),
        .all_of => |list| {
            for (list) |x| if (!eval(x, env)) return false;
            return true;
        },
        .any_of => |list| {
            for (list) |x| if (eval(x, env)) return true;
            return false;
        },
        .unknown => return false,
        .feature => |f| {
            const eq = std.ascii.eqlIgnoreCase;
            switch (f.feature) {
                .width, .min_width, .max_width => return compare(env.width, f.cmp, f.value),
                .height, .min_height, .max_height => return compare(env.height, f.cmp, f.value),
                .orientation => return if (f.ident.len == 0) true else if (eq(f.ident, "landscape")) env.width >= env.height else if (eq(f.ident, "portrait")) env.height > env.width else false,
                .prefers_color_scheme => return if (eq(f.ident, "dark")) env.dark else if (eq(f.ident, "light")) !env.dark else f.ident.len == 0,
                .prefers_contrast => return if (eq(f.ident, "more")) env.high_contrast else if (eq(f.ident, "no-preference")) !env.high_contrast else if (f.ident.len == 0) env.high_contrast else false,
                .prefers_reduced_motion => return if (eq(f.ident, "reduce")) env.reduced_motion else if (eq(f.ident, "no-preference")) !env.reduced_motion else if (f.ident.len == 0) env.reduced_motion else false,
                .hover => return if (eq(f.ident, "hover")) env.can_hover else if (eq(f.ident, "none")) !env.can_hover else if (f.ident.len == 0) env.can_hover else false,
                .pointer => return if (eq(f.ident, "fine")) env.can_hover else if (eq(f.ident, "coarse")) !env.can_hover else if (eq(f.ident, "none")) false else if (f.ident.len == 0) true else false,
                .unknown => return false,
            }
        },
    }
}

fn compare(have: f64, cmp: Cmp, want: f64) bool {
    return switch (cmp) {
        .lt => have < want,
        .le => have <= want,
        .gt => have > want,
        .ge => have >= want,
        .eq => have == want,
    };
}

test "media: types, features, ranges, preferences" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: Env = .{ .width = 1280, .height = 1024, .dark = true };
    const cases = [_]struct { q: []const u8, want: bool }{
        .{ .q = "", .want = true },
        .{ .q = "all", .want = true },
        .{ .q = "screen", .want = true },
        .{ .q = "print", .want = false },
        .{ .q = "not print", .want = true },
        .{ .q = "only screen and (min-width: 600px)", .want = true },
        .{ .q = "screen and (max-width: 600px)", .want = false },
        .{ .q = "(max-width: 600px), print, (min-height: 1000px)", .want = true },
        .{ .q = "(width >= 1280px)", .want = true },
        .{ .q = "(width > 1280px)", .want = false },
        .{ .q = "(orientation: landscape)", .want = true },
        .{ .q = "(prefers-color-scheme: dark)", .want = true },
        .{ .q = "(prefers-color-scheme: light)", .want = false },
        .{ .q = "(prefers-contrast: more)", .want = false },
        .{ .q = "(hover: hover) and (pointer: fine)", .want = true },
        .{ .q = "not all and (min-width: 600px)", .want = false },
        .{ .q = "(min-width: 80em)", .want = true },
        .{ .q = "(color-gamut: p3)", .want = false },
        .{ .q = "speech", .want = false },
        .{ .q = "((min-width: 600px) and (max-width: 2000px))", .want = true },
    };
    for (cases) |c| {
        const q = try Query.parseText(a, c.q);
        try std.testing.expectEqual(c.want, q.matches(env));
    }
}

test "media: calc() in a range" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const narrow = try Query.parseText(a, "(width<=calc(48rem - .02px))");
    try std.testing.expect(narrow.matches(.{ .width = 700, .height = 500 }));
    try std.testing.expect(!narrow.matches(.{ .width = 768, .height = 500 }));
    const wide = try Query.parseText(a, "(min-width: max(30em, 500px))");
    try std.testing.expect(wide.matches(.{ .width = 500, .height = 500 }));
    try std.testing.expect(!wide.matches(.{ .width = 479, .height = 500 }));
}
