//! SVG pictures (the static, painted subset of SVG 1.1/2): a document
//! parsed into a small element tree, then drawn into RGBA at any scale —
//! the web's logos, icons and sprite sheets, which are vector art a page
//! shows at its zoom. Built: `svg` (nested, `viewBox` with the default
//! `xMidYMid meet`), `g`, `path` (every command, arcs included), `rect`
//! (rounded), `circle`, `ellipse`, `line`, `polyline`, `polygon`, `use`
//! (of `symbol`s and elements, by id), `defs`; transforms; fill and
//! stroke with their opacities, `fill-rule`, `opacity`, `display` and
//! `visibility`; presentation attributes, `style` attributes and simple
//! `<style>` sheets (`.class`, `#id`, `tag` and `tag.class` rules).
//! Paint is anti-aliased: 5 sub-scanlines a pixel with exact horizontal
//! coverage. A stroke is its segments as quads with round joins, filled
//! non-zero. Not built: gradients (a gradient fill paints its stops'
//! mean colour), patterns, clip paths and masks (the content paints
//! unclipped), filters, text, images, markers, dashes.
const std = @import("std");
const color = @import("web/color.zig");
const image = @import("image.zig");

pub const Error = error{ OutOfMemory, BadSvg };

/// Whether the bytes look like an SVG document.
pub fn sniff(bytes: []const u8) bool {
    var i: usize = 0;
    // A BOM, whitespace, an XML declaration, comments, a doctype: then
    // `<svg`.
    if (bytes.len >= 3 and std.mem.eql(u8, bytes[0..3], "\xef\xbb\xbf")) i = 3;
    const head = bytes[i..@min(bytes.len, i + 4096)];
    return std.mem.indexOf(u8, head, "<svg") != null;
}

// ------------------------------------------------------------ the tree

const Attr = struct { name: []const u8, value: []const u8 };

const Node = struct {
    name: []const u8,
    attrs: []const Attr,
    children: std.ArrayList(u32) = .empty,
    parent: ?u32 = null,
    text: []const u8 = "",

    fn get(n: *const Node, name: []const u8) ?[]const u8 {
        for (n.attrs) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
        return null;
    }
};

const Tree = struct {
    nodes: std.ArrayList(Node) = .empty,
    root: ?u32 = null,
    rules: std.ArrayList(Rule) = .empty,

    fn byId(t: *const Tree, id: []const u8) ?u32 {
        for (t.nodes.items, 0..) |n, i| if (n.get("id")) |v| if (std.mem.eql(u8, v, id)) return @intCast(i);
        return null;
    }
};

/// Local name: `svg:path` is `path`, `xlink:href` is `href`.
fn local(name: []const u8) []const u8 {
    return if (std.mem.lastIndexOfScalar(u8, name, ':')) |i| name[i + 1 ..] else name;
}

fn decodeEntities(a: std.mem.Allocator, s: []const u8) Error![]const u8 {
    if (std.mem.indexOfScalar(u8, s, '&') == null) return s;
    var out: std.ArrayList(u8) = .empty;
    var i: usize = 0;
    while (i < s.len) {
        if (s[i] == '&') if (std.mem.indexOfScalarPos(u8, s, i, ';')) |end| {
            const ent = s[i + 1 .. end];
            const ch: ?u21 = if (std.mem.eql(u8, ent, "amp")) '&' else if (std.mem.eql(u8, ent, "lt")) '<' else if (std.mem.eql(u8, ent, "gt")) '>' else if (std.mem.eql(u8, ent, "quot")) '"' else if (std.mem.eql(u8, ent, "apos")) '\'' else if (ent.len > 1 and ent[0] == '#') (if (ent[1] == 'x') std.fmt.parseInt(u21, ent[2..], 16) catch null else std.fmt.parseInt(u21, ent[1..], 10) catch null) else null;
            if (ch) |c| {
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(c, &buf) catch 0;
                try out.appendSlice(a, buf[0..n]);
                i = end + 1;
                continue;
            }
        };
        try out.append(a, s[i]);
        i += 1;
    }
    return out.items;
}

fn parse(a: std.mem.Allocator, src: []const u8) Error!Tree {
    var t: Tree = .{};
    var stack: std.ArrayList(u32) = .empty;
    var i: usize = 0;
    while (i < src.len) {
        const lt = std.mem.indexOfScalarPos(u8, src, i, '<') orelse break;
        // Text: kept for `<style>`.
        if (lt > i and stack.items.len > 0) {
            const top = &t.nodes.items[stack.items[stack.items.len - 1]];
            if (std.mem.eql(u8, top.name, "style")) top.text = src[i..lt];
        }
        i = lt;
        if (std.mem.startsWith(u8, src[i..], "<!--")) {
            i = if (std.mem.indexOfPos(u8, src, i + 4, "-->")) |e| e + 3 else src.len;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "<![CDATA[")) {
            const e = std.mem.indexOfPos(u8, src, i + 9, "]]>") orelse src.len;
            if (stack.items.len > 0) {
                const top = &t.nodes.items[stack.items[stack.items.len - 1]];
                if (std.mem.eql(u8, top.name, "style")) top.text = src[i + 9 .. e];
            }
            i = @min(src.len, e + 3);
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "<?") or std.mem.startsWith(u8, src[i..], "<!")) {
            i = if (std.mem.indexOfScalarPos(u8, src, i, '>')) |e| e + 1 else src.len;
            continue;
        }
        if (std.mem.startsWith(u8, src[i..], "</")) {
            i = if (std.mem.indexOfScalarPos(u8, src, i, '>')) |e| e + 1 else src.len;
            if (stack.items.len > 0) stack.items.len -= 1;
            continue;
        }
        // A start tag: its name, its attributes, maybe self-closed.
        i += 1;
        const name_start = i;
        while (i < src.len and !std.ascii.isWhitespace(src[i]) and src[i] != '>' and src[i] != '/') i += 1;
        const name = local(src[name_start..i]);
        var attrs: std.ArrayList(Attr) = .empty;
        var self_closed = false;
        while (i < src.len) {
            while (i < src.len and std.ascii.isWhitespace(src[i])) i += 1;
            if (i >= src.len) break;
            if (src[i] == '>') {
                i += 1;
                break;
            }
            if (src[i] == '/') {
                self_closed = true;
                i += 1;
                continue;
            }
            const an = i;
            while (i < src.len and src[i] != '=' and !std.ascii.isWhitespace(src[i]) and src[i] != '>' and src[i] != '/') i += 1;
            const aname = local(src[an..i]);
            while (i < src.len and std.ascii.isWhitespace(src[i])) i += 1;
            var value: []const u8 = "";
            if (i < src.len and src[i] == '=') {
                i += 1;
                while (i < src.len and std.ascii.isWhitespace(src[i])) i += 1;
                if (i < src.len and (src[i] == '"' or src[i] == '\'')) {
                    const q = src[i];
                    const vs = i + 1;
                    const ve = std.mem.indexOfScalarPos(u8, src, vs, q) orelse src.len;
                    value = try decodeEntities(a, src[vs..ve]);
                    i = @min(src.len, ve + 1);
                } else {
                    const vs = i;
                    while (i < src.len and !std.ascii.isWhitespace(src[i]) and src[i] != '>') i += 1;
                    value = src[vs..i];
                }
            }
            if (aname.len > 0) try attrs.append(a, .{ .name = aname, .value = value });
        }
        const id: u32 = @intCast(t.nodes.items.len);
        try t.nodes.append(a, .{ .name = name, .attrs = attrs.items, .parent = if (stack.items.len > 0) stack.items[stack.items.len - 1] else null });
        if (stack.items.len > 0) {
            try t.nodes.items[stack.items[stack.items.len - 1]].children.append(a, id);
        } else if (t.root == null and std.mem.eql(u8, name, "svg")) t.root = id;
        if (!self_closed) try stack.append(a, id);
    }
    if (t.root == null) return error.BadSvg;
    for (t.nodes.items) |n| if (std.mem.eql(u8, n.name, "style")) try parseSheet(a, &t, n.text);
    return t;
}

// ---------------------------------------------------------- <style>

const Selector = struct { tag: []const u8 = "", class: []const u8 = "", id: []const u8 = "" };
const Rule = struct { sel: Selector, decls: []const u8, spec: u32, order: u32 };

fn parseSheet(a: std.mem.Allocator, t: *Tree, text: []const u8) Error!void {
    var i: usize = 0;
    while (i < text.len) {
        const open = std.mem.indexOfScalarPos(u8, text, i, '{') orelse return;
        const close = std.mem.indexOfScalarPos(u8, text, open, '}') orelse return;
        const sels = text[i..open];
        const decls = text[open + 1 .. close];
        i = close + 1;
        if (std.mem.indexOfScalar(u8, sels, '@') != null) continue;
        var it = std.mem.splitScalar(u8, sels, ',');
        while (it.next()) |raw| {
            const sel_text = std.mem.trim(u8, raw, " \t\r\n");
            if (sel_text.len == 0 or std.mem.indexOfAny(u8, sel_text, " >+~[:") != null) continue;
            var sel: Selector = .{};
            var k: usize = 0;
            while (k < sel_text.len) {
                const kind = sel_text[k];
                var e = k + 1;
                while (e < sel_text.len and sel_text[e] != '.' and sel_text[e] != '#') e += 1;
                switch (kind) {
                    '.' => sel.class = sel_text[k + 1 .. e],
                    '#' => sel.id = sel_text[k + 1 .. e],
                    else => {
                        e = k;
                        while (e < sel_text.len and sel_text[e] != '.' and sel_text[e] != '#') e += 1;
                        sel.tag = sel_text[k..e];
                    },
                }
                k = e;
            }
            const spec: u32 = (if (sel.id.len > 0) @as(u32, 100) else 0) + (if (sel.class.len > 0) @as(u32, 10) else 0) + (if (sel.tag.len > 0) @as(u32, 1) else 0);
            try t.rules.append(a, .{ .sel = sel, .decls = decls, .spec = spec, .order = @intCast(t.rules.items.len) });
        }
    }
}

fn hasClass(list: []const u8, class: []const u8) bool {
    var it = std.mem.tokenizeAny(u8, list, " \t\r\n");
    while (it.next()) |c| if (std.mem.eql(u8, c, class)) return true;
    return false;
}

fn ruleMatches(r: Rule, n: *const Node) bool {
    if (r.sel.tag.len > 0 and !std.mem.eql(u8, r.sel.tag, n.name) and !std.mem.eql(u8, r.sel.tag, "*")) return false;
    if (r.sel.id.len > 0) if (n.get("id")) |v| {
        if (!std.mem.eql(u8, v, r.sel.id)) return false;
    } else return false;
    if (r.sel.class.len > 0) if (n.get("class")) |v| {
        if (!hasClass(v, r.sel.class)) return false;
    } else return false;
    return true;
}

// ------------------------------------------------------------- style

const Paint = union(enum) { none, rgba: [4]f64, current };

const Style = struct {
    fill: Paint = .{ .rgba = .{ 0, 0, 0, 1 } },
    stroke: Paint = .none,
    stroke_width: f64 = 1,
    fill_opacity: f64 = 1,
    stroke_opacity: f64 = 1,
    even_odd: bool = false,
    color: [4]f64 = .{ 0, 0, 0, 1 },
    visible: bool = true,
    // Not inherited.
    opacity: f64 = 1,
    display: bool = true,
};

fn parseColor(tree: *const Tree, a: std.mem.Allocator, v_raw: []const u8) ?Paint {
    const v = std.mem.trim(u8, v_raw, " \t\r\n");
    if (v.len == 0) return null;
    if (std.ascii.eqlIgnoreCase(v, "none") or std.ascii.eqlIgnoreCase(v, "transparent")) return .none;
    if (std.ascii.eqlIgnoreCase(v, "currentColor")) return .current;
    if (std.mem.startsWith(u8, v, "url(")) {
        // A gradient (or pattern) by id: the mean of its stops.
        const close = std.mem.indexOfScalar(u8, v, ')') orelse return .none;
        var ref = std.mem.trim(u8, v[4..close], " \"'");
        if (ref.len > 0 and ref[0] == '#') ref = ref[1..];
        const gid = tree.byId(ref) orelse return fallbackAfterUrl(tree, a, v[close + 1 ..]);
        return gradientMean(tree, a, gid) orelse fallbackAfterUrl(tree, a, v[close + 1 ..]);
    }
    const parsed = (color.parseText(a, v) catch return null) orelse return null;
    return switch (parsed) {
        .color => |c| .{ .rgba = .{ c.r, c.g, c.b, c.a } },
        .current => .current,
    };
}

fn fallbackAfterUrl(tree: *const Tree, a: std.mem.Allocator, rest: []const u8) Paint {
    const r = std.mem.trim(u8, rest, " \t");
    if (r.len == 0) return .none;
    return parseColor(tree, a, r) orelse .none;
}

fn gradientMean(tree: *const Tree, a: std.mem.Allocator, gid: u32) ?Paint {
    var g = gid;
    // A gradient may take its stops from another (`href`).
    for (0..4) |_| {
        const n = &tree.nodes.items[g];
        var sum: [4]f64 = .{ 0, 0, 0, 0 };
        var count: f64 = 0;
        for (n.children.items) |c| {
            const cn = &tree.nodes.items[c];
            if (!std.mem.eql(u8, cn.name, "stop")) continue;
            var sc: ?Paint = null;
            var so: f64 = 1;
            if (cn.get("stop-color")) |v| sc = parseColor(tree, a, v);
            if (cn.get("stop-opacity")) |v| so = number(v) orelse 1;
            if (cn.get("style")) |st| {
                var it = std.mem.splitScalar(u8, st, ';');
                while (it.next()) |d| {
                    const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
                    const k = std.mem.trim(u8, d[0..colon], " \t");
                    const val = std.mem.trim(u8, d[colon + 1 ..], " \t");
                    if (std.mem.eql(u8, k, "stop-color")) sc = parseColor(tree, a, val);
                    if (std.mem.eql(u8, k, "stop-opacity")) so = number(val) orelse 1;
                }
            }
            const rgba: [4]f64 = if (sc) |p| switch (p) {
                .rgba => |x| x,
                else => .{ 0, 0, 0, 1 },
            } else .{ 0, 0, 0, 1 };
            for (0..3) |k| sum[k] += rgba[k];
            sum[3] += rgba[3] * so;
            count += 1;
        }
        if (count > 0) return .{ .rgba = .{ sum[0] / count, sum[1] / count, sum[2] / count, sum[3] / count } };
        const href = n.get("href") orelse return null;
        g = tree.byId(if (href.len > 0 and href[0] == '#') href[1..] else href) orelse return null;
    }
    return null;
}

fn number(v: []const u8) ?f64 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.' or t[end] == '-' or t[end] == '+' or t[end] == 'e' or t[end] == 'E')) end += 1;
    if (end == 0) return null;
    const x = std.fmt.parseFloat(f64, t[0..end]) catch return null;
    if (end < t.len and t[end] == '%') return x / 100;
    return x;
}

/// A length in user units (`px` and unitless alike; the rest by CSS's
/// ratios; a percentage of `pct_of`).
fn length(v: []const u8, pct_of: f64) ?f64 {
    const t = std.mem.trim(u8, v, " \t\r\n");
    var end: usize = 0;
    while (end < t.len and (std.ascii.isDigit(t[end]) or t[end] == '.' or t[end] == '-' or t[end] == '+' or ((t[end] == 'e' or t[end] == 'E') and end + 1 < t.len and (std.ascii.isDigit(t[end + 1]) or t[end + 1] == '-')))) end += 1;
    if (end == 0) return null;
    const x = std.fmt.parseFloat(f64, t[0..end]) catch return null;
    const unit = t[end..];
    if (unit.len == 0 or std.mem.eql(u8, unit, "px")) return x;
    if (std.mem.eql(u8, unit, "%")) return x * pct_of / 100;
    if (std.mem.eql(u8, unit, "pt")) return x * 96 / 72;
    if (std.mem.eql(u8, unit, "pc")) return x * 16;
    if (std.mem.eql(u8, unit, "mm")) return x * 96 / 25.4;
    if (std.mem.eql(u8, unit, "cm")) return x * 96 / 2.54;
    if (std.mem.eql(u8, unit, "in")) return x * 96;
    if (std.mem.eql(u8, unit, "em")) return x * 16;
    if (std.mem.eql(u8, unit, "ex")) return x * 8;
    return x;
}

fn applyProp(tree: *const Tree, a: std.mem.Allocator, st: *Style, name: []const u8, v: []const u8) void {
    const eq = std.mem.eql;
    if (eq(u8, name, "fill")) {
        if (parseColor(tree, a, v)) |p| st.fill = p;
    } else if (eq(u8, name, "stroke")) {
        if (parseColor(tree, a, v)) |p| st.stroke = p;
    } else if (eq(u8, name, "stroke-width")) {
        if (length(v, 1)) |x| st.stroke_width = @max(0, x);
    } else if (eq(u8, name, "fill-opacity")) {
        if (number(v)) |x| st.fill_opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, name, "stroke-opacity")) {
        if (number(v)) |x| st.stroke_opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, name, "opacity")) {
        if (number(v)) |x| st.opacity = std.math.clamp(x, 0, 1);
    } else if (eq(u8, name, "fill-rule")) {
        st.even_odd = eq(u8, std.mem.trim(u8, v, " "), "evenodd");
    } else if (eq(u8, name, "color")) {
        if (parseColor(tree, a, v)) |p| switch (p) {
            .rgba => |c| st.color = c,
            else => {},
        };
    } else if (eq(u8, name, "display")) {
        st.display = !eq(u8, std.mem.trim(u8, v, " "), "none");
    } else if (eq(u8, name, "visibility")) {
        const w = std.mem.trim(u8, v, " ");
        st.visible = !(eq(u8, w, "hidden") or eq(u8, w, "collapse"));
    }
}

fn applyDecls(tree: *const Tree, a: std.mem.Allocator, st: *Style, decls: []const u8) void {
    var it = std.mem.splitScalar(u8, decls, ';');
    while (it.next()) |d| {
        const colon = std.mem.indexOfScalar(u8, d, ':') orelse continue;
        const k = std.mem.trim(u8, d[0..colon], " \t\r\n");
        var val = std.mem.trim(u8, d[colon + 1 ..], " \t\r\n");
        if (std.mem.indexOf(u8, val, "!important")) |imp| val = std.mem.trim(u8, val[0..imp], " ");
        applyProp(tree, a, st, k, val);
    }
}

const presentation = [_][]const u8{ "fill", "stroke", "stroke-width", "fill-opacity", "stroke-opacity", "opacity", "fill-rule", "color", "display", "visibility" };

/// An element's style: inherited from its parent's, then its
/// presentation attributes, the sheet's rules by specificity, its
/// `style` attribute.
fn styleOf(tree: *const Tree, a: std.mem.Allocator, n: *const Node, parent: Style) Style {
    var st = parent;
    st.opacity = 1;
    st.display = true;
    for (presentation) |p| if (n.get(p)) |v| applyProp(tree, a, &st, p, v);
    var best: [64]u32 = undefined;
    var nb: usize = 0;
    for (tree.rules.items, 0..) |r, i| if (ruleMatches(r, n) and nb < best.len) {
        best[nb] = @intCast(i);
        nb += 1;
    };
    std.mem.sort(u32, best[0..nb], tree, struct {
        fn lt(t: *const Tree, x: u32, y: u32) bool {
            const rx = t.rules.items[x];
            const ry = t.rules.items[y];
            return if (rx.spec != ry.spec) rx.spec < ry.spec else rx.order < ry.order;
        }
    }.lt);
    for (best[0..nb]) |ri| applyDecls(tree, a, &st, tree.rules.items[ri].decls);
    if (n.get("style")) |s| applyDecls(tree, a, &st, s);
    return st;
}

// ------------------------------------------------------- geometry

const Mat = struct {
    a: f64 = 1,
    b: f64 = 0,
    c: f64 = 0,
    d: f64 = 1,
    e: f64 = 0,
    f: f64 = 0,

    fn mul(m: Mat, n: Mat) Mat {
        // m then n applied inside: the result maps p to m(n(p)).
        return .{
            .a = m.a * n.a + m.c * n.b,
            .b = m.b * n.a + m.d * n.b,
            .c = m.a * n.c + m.c * n.d,
            .d = m.b * n.c + m.d * n.d,
            .e = m.a * n.e + m.c * n.f + m.e,
            .f = m.b * n.e + m.d * n.f + m.f,
        };
    }
    fn apply(m: Mat, x: f64, y: f64) [2]f64 {
        return .{ m.a * x + m.c * y + m.e, m.b * x + m.d * y + m.f };
    }
    /// The mean scale (for stroke widths and flattening).
    fn scale(m: Mat) f64 {
        return @sqrt(@abs(m.a * m.d - m.b * m.c));
    }
};

fn parseTransform(text: []const u8) Mat {
    var m: Mat = .{};
    var i: usize = 0;
    while (i < text.len) {
        while (i < text.len and (std.ascii.isWhitespace(text[i]) or text[i] == ',')) i += 1;
        const ns = i;
        while (i < text.len and std.ascii.isAlphabetic(text[i])) i += 1;
        const name = text[ns..i];
        if (name.len == 0) break;
        const open = std.mem.indexOfScalarPos(u8, text, i, '(') orelse break;
        const close = std.mem.indexOfScalarPos(u8, text, open, ')') orelse break;
        var nums: [6]f64 = @splat(0);
        var n: usize = 0;
        var it = Numbers{ .s = text[open + 1 .. close] };
        while (n < 6) : (n += 1) nums[n] = it.next() orelse break;
        i = close + 1;
        const eq = std.mem.eql;
        var t: Mat = .{};
        if (eq(u8, name, "matrix") and n == 6) {
            t = .{ .a = nums[0], .b = nums[1], .c = nums[2], .d = nums[3], .e = nums[4], .f = nums[5] };
        } else if (eq(u8, name, "translate")) {
            t = .{ .e = nums[0], .f = if (n > 1) nums[1] else 0 };
        } else if (eq(u8, name, "scale")) {
            t = .{ .a = nums[0], .d = if (n > 1) nums[1] else nums[0] };
        } else if (eq(u8, name, "rotate")) {
            const r = nums[0] * std.math.pi / 180;
            const rot: Mat = .{ .a = @cos(r), .b = @sin(r), .c = -@sin(r), .d = @cos(r) };
            if (n >= 3) {
                t = (Mat{ .e = nums[1], .f = nums[2] }).mul(rot).mul(.{ .e = -nums[1], .f = -nums[2] });
            } else t = rot;
        } else if (eq(u8, name, "skewX")) {
            t = .{ .c = @tan(nums[0] * std.math.pi / 180) };
        } else if (eq(u8, name, "skewY")) {
            t = .{ .b = @tan(nums[0] * std.math.pi / 180) };
        }
        m = m.mul(t);
    }
    return m;
}

/// Numbers in SVG's compact syntax: `1.5.5-2e3,4`.
const Numbers = struct {
    s: []const u8,
    i: usize = 0,

    fn skip(n: *Numbers) void {
        while (n.i < n.s.len and (std.ascii.isWhitespace(n.s[n.i]) or n.s[n.i] == ',')) n.i += 1;
    }
    fn next(n: *Numbers) ?f64 {
        n.skip();
        if (n.i >= n.s.len) return null;
        const start = n.i;
        if (n.s[n.i] == '-' or n.s[n.i] == '+') n.i += 1;
        var dot = false;
        var digits = false;
        while (n.i < n.s.len) : (n.i += 1) {
            const c = n.s[n.i];
            if (std.ascii.isDigit(c)) {
                digits = true;
            } else if (c == '.' and !dot) {
                dot = true;
            } else break;
        }
        if (digits and n.i < n.s.len and (n.s[n.i] == 'e' or n.s[n.i] == 'E')) {
            const save = n.i;
            n.i += 1;
            if (n.i < n.s.len and (n.s[n.i] == '-' or n.s[n.i] == '+')) n.i += 1;
            if (n.i < n.s.len and std.ascii.isDigit(n.s[n.i])) {
                while (n.i < n.s.len and std.ascii.isDigit(n.s[n.i])) n.i += 1;
            } else n.i = save;
        }
        if (!digits) {
            n.i = start;
            return null;
        }
        return std.fmt.parseFloat(f64, n.s[start..n.i]) catch null;
    }
    /// An arc's flag: a single 0 or 1, which may run into what follows.
    fn flag(n: *Numbers) ?bool {
        n.skip();
        if (n.i >= n.s.len) return null;
        const c = n.s[n.i];
        if (c != '0' and c != '1') return null;
        n.i += 1;
        return c == '1';
    }
};

/// Polylines in device space: every subpath flattened, and whether it
/// was closed.
const Poly = struct {
    pts: std.ArrayList([2]f64) = .empty,
    /// Subpath starts (indices into `pts`) and whether each closes.
    starts: std.ArrayList(u32) = .empty,
    closed: std.ArrayList(bool) = .empty,

    fn begin(p: *Poly, a: std.mem.Allocator, pt: [2]f64) Error!void {
        try p.starts.append(a, @intCast(p.pts.items.len));
        try p.closed.append(a, false);
        try p.pts.append(a, pt);
    }
    fn to(p: *Poly, a: std.mem.Allocator, pt: [2]f64) Error!void {
        if (p.starts.items.len == 0) try p.begin(a, pt) else try p.pts.append(a, pt);
    }
    fn close(p: *Poly) void {
        if (p.closed.items.len > 0) p.closed.items[p.closed.items.len - 1] = true;
    }
    fn subpath(p: *const Poly, k: usize) [][2]f64 {
        const s = p.starts.items[k];
        const e = if (k + 1 < p.starts.items.len) p.starts.items[k + 1] else @as(u32, @intCast(p.pts.items.len));
        return p.pts.items[s..e];
    }
};

/// Builds a path in user space, flattening curves after the transform
/// to about a quarter of a device pixel.
const Builder = struct {
    a: std.mem.Allocator,
    m: Mat,
    poly: *Poly,
    cur: [2]f64 = .{ 0, 0 },
    start: [2]f64 = .{ 0, 0 },

    fn dev(b: *const Builder, p: [2]f64) [2]f64 {
        return b.m.apply(p[0], p[1]);
    }
    fn move(b: *Builder, p: [2]f64) Error!void {
        b.cur = p;
        b.start = p;
        try b.poly.begin(b.a, b.dev(p));
    }
    fn line(b: *Builder, p: [2]f64) Error!void {
        b.cur = p;
        try b.poly.to(b.a, b.dev(p));
    }
    fn close(b: *Builder) Error!void {
        b.poly.close();
        b.cur = b.start;
    }
    fn steps(b: *const Builder, pts: []const [2]f64) usize {
        var len: f64 = 0;
        for (pts[1..], 0..) |p, k| {
            const q = b.dev(pts[k]);
            const r = b.dev(p);
            len += @sqrt((r[0] - q[0]) * (r[0] - q[0]) + (r[1] - q[1]) * (r[1] - q[1]));
        }
        return @intFromFloat(std.math.clamp(@ceil(@sqrt(len) * 1.5), 2, 64));
    }
    fn cubic(b: *Builder, p1: [2]f64, p2: [2]f64, p3: [2]f64) Error!void {
        const p0 = b.cur;
        const n = b.steps(&.{ p0, p1, p2, p3 });
        for (1..n + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const u = 1 - t;
            const x = u * u * u * p0[0] + 3 * u * u * t * p1[0] + 3 * u * t * t * p2[0] + t * t * t * p3[0];
            const y = u * u * u * p0[1] + 3 * u * u * t * p1[1] + 3 * u * t * t * p2[1] + t * t * t * p3[1];
            try b.poly.to(b.a, b.dev(.{ x, y }));
        }
        b.cur = p3;
    }
    fn quad(b: *Builder, p1: [2]f64, p2: [2]f64) Error!void {
        const p0 = b.cur;
        const n = b.steps(&.{ p0, p1, p2 });
        for (1..n + 1) |k| {
            const t = @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const u = 1 - t;
            try b.poly.to(b.a, b.dev(.{ u * u * p0[0] + 2 * u * t * p1[0] + t * t * p2[0], u * u * p0[1] + 2 * u * t * p1[1] + t * t * p2[1] }));
        }
        b.cur = p2;
    }
    /// SVG's endpoint arc (F.6.5), flattened.
    fn arc(b: *Builder, rx_in: f64, ry_in: f64, phi_deg: f64, large: bool, sweep: bool, p: [2]f64) Error!void {
        const p0 = b.cur;
        if (p0[0] == p[0] and p0[1] == p[1]) return;
        var rx = @abs(rx_in);
        var ry = @abs(ry_in);
        if (rx == 0 or ry == 0) return b.line(p);
        const phi = phi_deg * std.math.pi / 180;
        const cp = @cos(phi);
        const sp = @sin(phi);
        const dx = (p0[0] - p[0]) / 2;
        const dy = (p0[1] - p[1]) / 2;
        const x1 = cp * dx + sp * dy;
        const y1 = -sp * dx + cp * dy;
        const lam = (x1 * x1) / (rx * rx) + (y1 * y1) / (ry * ry);
        if (lam > 1) {
            rx *= @sqrt(lam);
            ry *= @sqrt(lam);
        }
        const num = rx * rx * ry * ry - rx * rx * y1 * y1 - ry * ry * x1 * x1;
        const den = rx * rx * y1 * y1 + ry * ry * x1 * x1;
        var co = @sqrt(@max(0, num / den));
        if (large == sweep) co = -co;
        const cxp = co * rx * y1 / ry;
        const cyp = -co * ry * x1 / rx;
        const cx = cp * cxp - sp * cyp + (p0[0] + p[0]) / 2;
        const cy = sp * cxp + cp * cyp + (p0[1] + p[1]) / 2;
        const t1 = std.math.atan2((y1 - cyp) / ry, (x1 - cxp) / rx);
        var dt = std.math.atan2((-y1 - cyp) / ry, (-x1 - cxp) / rx) - t1;
        if (sweep and dt < 0) dt += 2 * std.math.pi;
        if (!sweep and dt > 0) dt -= 2 * std.math.pi;
        const dev_r = @max(rx, ry) * b.m.scale();
        const n: usize = @intFromFloat(std.math.clamp(@ceil(@abs(dt) * @sqrt(@max(1, dev_r)) * 1.2), 4, 128));
        for (1..n + 1) |k| {
            const t = t1 + dt * @as(f64, @floatFromInt(k)) / @as(f64, @floatFromInt(n));
            const x = cp * rx * @cos(t) - sp * ry * @sin(t) + cx;
            const y = sp * rx * @cos(t) + cp * ry * @sin(t) + cy;
            try b.poly.to(b.a, b.dev(.{ x, y }));
        }
        b.cur = p;
    }
};

fn pathData(b: *Builder, d: []const u8) Error!void {
    var n = Numbers{ .s = d };
    var cmd: u8 = 0;
    var last_ctrl: ?[2]f64 = null; // for S/T reflection
    var last_kind: u8 = 0;
    while (true) {
        n.skip();
        if (n.i >= d.len) break;
        const c = d[n.i];
        if (std.ascii.isAlphabetic(c) and c != 'e' and c != 'E') {
            cmd = c;
            n.i += 1;
            if (cmd == 'Z' or cmd == 'z') {
                try b.close();
                last_kind = 'Z';
                continue;
            }
        } else if (cmd == 0) return;
        const rel = std.ascii.isLower(cmd);
        const ox: f64 = if (rel) b.cur[0] else 0;
        const oy: f64 = if (rel) b.cur[1] else 0;
        const up = std.ascii.toUpper(cmd);
        switch (up) {
            'M' => {
                const x = n.next() orelse return;
                const y = n.next() orelse return;
                try b.move(.{ ox + x, oy + y });
                // Further pairs are lines.
                cmd = if (rel) 'l' else 'L';
            },
            'L' => {
                const x = n.next() orelse return;
                const y = n.next() orelse return;
                try b.line(.{ ox + x, oy + y });
            },
            'H' => {
                const x = n.next() orelse return;
                try b.line(.{ ox + x, b.cur[1] });
            },
            'V' => {
                const y = n.next() orelse return;
                try b.line(.{ b.cur[0], oy + y });
            },
            'C' => {
                var v: [6]f64 = undefined;
                for (&v) |*x| x.* = n.next() orelse return;
                const p1 = [2]f64{ ox + v[0], oy + v[1] };
                const p2 = [2]f64{ ox + v[2], oy + v[3] };
                try b.cubic(p1, p2, .{ ox + v[4], oy + v[5] });
                last_ctrl = p2;
                last_kind = 'C';
                continue;
            },
            'S' => {
                var v: [4]f64 = undefined;
                for (&v) |*x| x.* = n.next() orelse return;
                const p1: [2]f64 = if (last_kind == 'C' and last_ctrl != null) .{ 2 * b.cur[0] - last_ctrl.?[0], 2 * b.cur[1] - last_ctrl.?[1] } else b.cur;
                const p2 = [2]f64{ ox + v[0], oy + v[1] };
                try b.cubic(p1, p2, .{ ox + v[2], oy + v[3] });
                last_ctrl = p2;
                last_kind = 'C';
                continue;
            },
            'Q' => {
                var v: [4]f64 = undefined;
                for (&v) |*x| x.* = n.next() orelse return;
                const p1 = [2]f64{ ox + v[0], oy + v[1] };
                try b.quad(p1, .{ ox + v[2], oy + v[3] });
                last_ctrl = p1;
                last_kind = 'Q';
                continue;
            },
            'T' => {
                var v: [2]f64 = undefined;
                for (&v) |*x| x.* = n.next() orelse return;
                const p1: [2]f64 = if (last_kind == 'Q' and last_ctrl != null) .{ 2 * b.cur[0] - last_ctrl.?[0], 2 * b.cur[1] - last_ctrl.?[1] } else b.cur;
                try b.quad(p1, .{ ox + v[0], oy + v[1] });
                last_ctrl = p1;
                last_kind = 'Q';
                continue;
            },
            'A' => {
                const rx = n.next() orelse return;
                const ry = n.next() orelse return;
                const rot = n.next() orelse return;
                const large = n.flag() orelse return;
                const sw = n.flag() orelse return;
                const x = n.next() orelse return;
                const y = n.next() orelse return;
                try b.arc(rx, ry, rot, large, sw, .{ ox + x, oy + y });
            },
            else => return,
        }
        last_kind = up;
    }
}

fn pointList(b: *Builder, text: []const u8, close: bool) Error!void {
    var n = Numbers{ .s = text };
    var first = true;
    while (true) {
        const x = n.next() orelse break;
        const y = n.next() orelse break;
        if (first) try b.move(.{ x, y }) else try b.line(.{ x, y });
        first = false;
    }
    if (close and !first) try b.close();
}

// ------------------------------------------------------------- raster

/// A coverage canvas: premultiplied 8-bit RGBA, composited per shape
/// (a sprite sheet at a zoom is millions of pixels: 8 bytes each with
/// the coverage, not 20).
const Raster = struct {
    w: usize,
    h: usize,
    px: []u8, // w*h*4, premultiplied
    cov: []f32, // w*h, one shape's coverage
    /// The viewport clip in device pixels (x0, y0, x1, y1): a nested
    /// `<svg>` clips what it draws to itself.
    clip: [4]f64 = .{ 0, 0, 1e9, 1e9 },

    const sub = 5;

    fn edgeCover(r: *Raster, a: std.mem.Allocator, poly: *const Poly, even_odd: bool) Error!?[4]usize {
        // Every segment of every (implicitly closed) subpath is an edge.
        const E = struct { x0: f64, y0: f64, x1: f64, y1: f64, dir: i8 };
        var edges: std.ArrayList(E) = .empty;
        var minx: f64 = std.math.inf(f64);
        var miny: f64 = std.math.inf(f64);
        var maxx: f64 = -std.math.inf(f64);
        var maxy: f64 = -std.math.inf(f64);
        for (0..poly.starts.items.len) |k| {
            const pts = poly.subpath(k);
            if (pts.len < 2) continue;
            for (pts, 0..) |p, i| {
                const q = if (i + 1 < pts.len) pts[i + 1] else pts[0];
                minx = @min(minx, p[0]);
                maxx = @max(maxx, p[0]);
                miny = @min(miny, p[1]);
                maxy = @max(maxy, p[1]);
                if (p[1] == q[1]) continue;
                if (p[1] < q[1]) try edges.append(a, .{ .x0 = p[0], .y0 = p[1], .x1 = q[0], .y1 = q[1], .dir = 1 }) else try edges.append(a, .{ .x0 = q[0], .y0 = q[1], .x1 = p[0], .y1 = p[1], .dir = -1 });
            }
        }
        if (edges.items.len == 0) return null;
        const fw: f64 = @floatFromInt(r.w);
        const fh: f64 = @floatFromInt(r.h);
        if (maxx <= 0 or maxy <= 0 or minx >= fw or miny >= fh) return null;
        const bx0: usize = @intFromFloat(@max(0, @floor(minx)));
        const by0: usize = @intFromFloat(@max(0, @floor(miny)));
        const bx1: usize = @intFromFloat(@min(fw, @ceil(maxx)));
        const by1: usize = @intFromFloat(@min(fh, @ceil(maxy)));
        for (by0..by1) |y| @memset(r.cov[y * r.w + bx0 .. y * r.w + bx1], 0);
        const X = struct { x: f64, dir: i8 };
        var xs: std.ArrayList(X) = .empty;
        // Edges sorted by top, walked with an active list per sub-row.
        std.mem.sort(E, edges.items, {}, struct {
            fn lt(_: void, p: E, q: E) bool {
                return p.y0 < q.y0;
            }
        }.lt);
        var active: std.ArrayList(u32) = .empty;
        var next_edge: usize = 0;
        for (by0..by1) |y| {
            for (0..sub) |s| {
                const sy = @as(f64, @floatFromInt(y)) + (@as(f64, @floatFromInt(s)) + 0.5) / sub;
                while (next_edge < edges.items.len and edges.items[next_edge].y0 <= sy) : (next_edge += 1) try active.append(a, @intCast(next_edge));
                xs.clearRetainingCapacity();
                var k: usize = 0;
                while (k < active.items.len) {
                    const e = edges.items[active.items[k]];
                    if (e.y1 <= sy) {
                        _ = active.swapRemove(k);
                        continue;
                    }
                    if (sy >= e.y0) try xs.append(a, .{ .x = e.x0 + (sy - e.y0) / (e.y1 - e.y0) * (e.x1 - e.x0), .dir = e.dir });
                    k += 1;
                }
                std.mem.sort(X, xs.items, {}, struct {
                    fn lt(_: void, p: X, q: X) bool {
                        return p.x < q.x;
                    }
                }.lt);
                var wind: i32 = 0;
                var j: usize = 0;
                while (j + 1 <= xs.items.len) : (j += 1) {
                    const before = wind;
                    wind = if (even_odd) (wind ^ 1) else wind + xs.items[j].dir;
                    const inside_before = before != 0;
                    const inside_after = wind != 0;
                    if (!inside_before and inside_after) {
                        // Find the span's end.
                        var k2 = j + 1;
                        var wd = wind;
                        while (k2 < xs.items.len) : (k2 += 1) {
                            wd = if (even_odd) (wd ^ 1) else wd + xs.items[k2].dir;
                            if (wd == 0) break;
                        }
                        if (k2 >= xs.items.len) break;
                        r.span(y, xs.items[j].x, xs.items[k2].x);
                        j = k2;
                        wind = 0;
                    }
                }
            }
        }
        return .{ bx0, by0, bx1, by1 };
    }

    /// Cover [x0, x1) on row y by one sub-row's share, exactly at the
    /// ends.
    fn span(r: *Raster, y: usize, x0_in: f64, x1_in: f64) void {
        const fw: f64 = @floatFromInt(r.w);
        const x0 = std.math.clamp(x0_in, 0, fw);
        const x1 = std.math.clamp(x1_in, 0, fw);
        if (x1 <= x0) return;
        const share: f32 = 1.0 / @as(f32, sub);
        const row = r.cov[y * r.w ..][0..r.w];
        const ix0: usize = @intFromFloat(@floor(x0));
        const ix1: usize = @intFromFloat(@floor(x1));
        if (ix0 == ix1) {
            if (ix0 < r.w) row[ix0] += share * @as(f32, @floatCast(x1 - x0));
            return;
        }
        row[ix0] += share * @as(f32, @floatCast(@as(f64, @floatFromInt(ix0 + 1)) - x0));
        for (ix0 + 1..ix1) |x| row[x] += share;
        if (ix1 < r.w) row[ix1] += share * @as(f32, @floatCast(x1 - @as(f64, @floatFromInt(ix1))));
    }

    fn composite(r: *Raster, bounds: [4]usize, rgba: [4]f64, alpha: f64) void {
        const al: f32 = @floatCast(std.math.clamp(rgba[3] * alpha, 0, 1));
        if (al == 0) return;
        const src = [3]f32{ @floatCast(rgba[0]), @floatCast(rgba[1]), @floatCast(rgba[2]) };
        const cx0: usize = @intFromFloat(std.math.clamp(@round(r.clip[0]), 0, @as(f64, @floatFromInt(r.w))));
        const cy0: usize = @intFromFloat(std.math.clamp(@round(r.clip[1]), 0, @as(f64, @floatFromInt(r.h))));
        const cx1: usize = @intFromFloat(std.math.clamp(@round(r.clip[2]), 0, @as(f64, @floatFromInt(r.w))));
        const cy1: usize = @intFromFloat(std.math.clamp(@round(r.clip[3]), 0, @as(f64, @floatFromInt(r.h))));
        for (@max(bounds[1], cy0)..@max(@min(bounds[3], cy1), @max(bounds[1], cy0))) |y| for (@max(bounds[0], cx0)..@max(@min(bounds[2], cx1), @max(bounds[0], cx0))) |x| {
            const c = @min(1, r.cov[y * r.w + x]);
            if (c <= 0) continue;
            const s = c * al;
            const o = (y * r.w + x) * 4;
            // Source over, premultiplied.
            for (0..3) |k| r.px[o + k] = @intFromFloat(@round(@min(255, src[k] * s + @as(f32, @floatFromInt(r.px[o + k])) * (1 - s))));
            r.px[o + 3] = @intFromFloat(@round(@min(255, 255 * s + @as(f32, @floatFromInt(r.px[o + 3])) * (1 - s))));
        };
    }
};

// ------------------------------------------------------------ drawing

const Ctx = struct {
    a: std.mem.Allocator,
    tree: *const Tree,
    r: *Raster,
    depth: u8 = 0,
};

fn drawShape(ctx: *Ctx, poly: *Poly, st: Style, m: Mat) Error!void {
    const opacity = st.opacity;
    const fill: ?[4]f64 = switch (st.fill) {
        .none => null,
        .current => st.color,
        .rgba => |c| c,
    };
    if (fill) |c| if (try ctx.r.edgeCover(ctx.a, poly, st.even_odd)) |bounds| {
        ctx.r.composite(bounds, c, st.fill_opacity * opacity);
    };
    const stroke: ?[4]f64 = switch (st.stroke) {
        .none => null,
        .current => st.color,
        .rgba => |c| c,
    };
    const sw = st.stroke_width * m.scale();
    if (stroke) |c| if (sw > 0) {
        var outline: Poly = .{};
        const hw = @max(0.35, sw / 2);
        for (0..poly.starts.items.len) |k| {
            const pts = poly.subpath(k);
            const n = pts.len;
            if (n < 2) continue;
            const segs = if (poly.closed.items[k]) n else n - 1;
            for (0..segs) |i| {
                const p = pts[i];
                const q = pts[(i + 1) % n];
                const dx = q[0] - p[0];
                const dy = q[1] - p[1];
                const len = @sqrt(dx * dx + dy * dy);
                if (len == 0) continue;
                const nx = -dy / len * hw;
                const ny = dx / len * hw;
                try outline.begin(ctx.a, .{ p[0] + nx, p[1] + ny });
                try outline.to(ctx.a, .{ q[0] + nx, q[1] + ny });
                try outline.to(ctx.a, .{ q[0] - nx, q[1] - ny });
                try outline.to(ctx.a, .{ p[0] - nx, p[1] - ny });
            }
            // Round joins (and caps): a disc at every vertex, wound the
            // way the quads are.
            if (hw > 0.75) for (pts) |p| {
                try outline.begin(ctx.a, .{ p[0] + hw, p[1] });
                for (1..12) |j| {
                    const t = @as(f64, @floatFromInt(j)) * 2 * std.math.pi / 12;
                    try outline.to(ctx.a, .{ p[0] + hw * @cos(t), p[1] + hw * @sin(t) });
                }
            };
        }
        // Quads of either orientation: even-odd would cut their overlaps,
        // non-zero with both orientations could cancel — so orient every
        // quad and disc one way first.
        for (0..outline.starts.items.len) |k| {
            const pts = outline.subpath(k);
            var area: f64 = 0;
            for (pts, 0..) |p, i| {
                const q = pts[(i + 1) % pts.len];
                area += p[0] * q[1] - q[0] * p[1];
            }
            if (area < 0) std.mem.reverse([2]f64, pts);
        }
        if (try ctx.r.edgeCover(ctx.a, &outline, false)) |bounds| ctx.r.composite(bounds, c, st.stroke_opacity * opacity);
    };
}

fn attrLen(n: *const Node, name: []const u8, pct_of: f64) f64 {
    return length(n.get(name) orelse return 0, pct_of) orelse 0;
}

fn drawNode(ctx: *Ctx, id: u32, parent_m: Mat, parent_st: Style, vw: f64, vh: f64) Error!void {
    const n = &ctx.tree.nodes.items[id];
    const eq = std.mem.eql;
    if (eq(u8, n.name, "defs") or eq(u8, n.name, "symbol") or eq(u8, n.name, "clipPath") or eq(u8, n.name, "mask") or eq(u8, n.name, "linearGradient") or eq(u8, n.name, "radialGradient") or eq(u8, n.name, "pattern") or eq(u8, n.name, "style") or eq(u8, n.name, "title") or eq(u8, n.name, "desc") or eq(u8, n.name, "metadata") or eq(u8, n.name, "filter") or eq(u8, n.name, "marker")) return;
    const st = styleOf(ctx.tree, ctx.a, n, parent_st);
    if (!st.display) return;
    var m = parent_m;
    if (n.get("transform")) |tf| m = m.mul(parseTransform(tf));
    if (eq(u8, n.name, "g") or eq(u8, n.name, "a") or eq(u8, n.name, "switch")) {
        for (n.children.items) |c| try drawNode(ctx, c, m, st, vw, vh);
        return;
    }
    if (eq(u8, n.name, "svg")) {
        // A nested viewport.
        const x = attrLen(n, "x", vw);
        const y = attrLen(n, "y", vh);
        const w = if (n.get("width")) |v| length(v, vw) orelse vw else vw;
        const h = if (n.get("height")) |v| length(v, vh) orelse vh else vh;
        const vm = viewBoxMat(n, w, h);
        const inner = m.mul(.{ .e = x, .f = y }).mul(vm.m);
        // Its viewport clips what it draws (the bounding box of the
        // transformed rect: exact unless rotated).
        const saved = ctx.r.clip;
        defer ctx.r.clip = saved;
        const c0 = m.apply(x, y);
        const c1 = m.apply(x + w, y + h);
        ctx.r.clip = .{ @max(saved[0], @min(c0[0], c1[0])), @max(saved[1], @min(c0[1], c1[1])), @min(saved[2], @max(c0[0], c1[0])), @min(saved[3], @max(c0[1], c1[1])) };
        for (n.children.items) |c| try drawNode(ctx, c, inner, st, vm.vw, vm.vh);
        return;
    }
    if (eq(u8, n.name, "use")) {
        if (ctx.depth > 8) return;
        const href = n.get("href") orelse return;
        const ref = ctx.tree.byId(if (href.len > 0 and href[0] == '#') href[1..] else href) orelse return;
        const um = m.mul(.{ .e = attrLen(n, "x", vw), .f = attrLen(n, "y", vh) });
        ctx.depth += 1;
        defer ctx.depth -= 1;
        const rn = &ctx.tree.nodes.items[ref];
        if (eq(u8, rn.name, "symbol")) {
            const w = if (n.get("width")) |v| length(v, vw) orelse vw else (if (rn.get("width")) |v| length(v, vw) orelse vw else vw);
            const h = if (n.get("height")) |v| length(v, vh) orelse vh else (if (rn.get("height")) |v| length(v, vh) orelse vh else vh);
            const vm = viewBoxMat(rn, w, h);
            const sst = styleOf(ctx.tree, ctx.a, rn, st);
            for (rn.children.items) |c| try drawNode(ctx, c, um.mul(vm.m), sst, vm.vw, vm.vh);
        } else try drawNode(ctx, ref, um, st, vw, vh);
        return;
    }
    if (!st.visible) return;
    var poly: Poly = .{};
    var b: Builder = .{ .a = ctx.a, .m = m, .poly = &poly };
    if (eq(u8, n.name, "path")) {
        try pathData(&b, n.get("d") orelse return);
    } else if (eq(u8, n.name, "rect")) {
        const x = attrLen(n, "x", vw);
        const y = attrLen(n, "y", vh);
        const w = attrLen(n, "width", vw);
        const h = attrLen(n, "height", vh);
        if (w <= 0 or h <= 0) return;
        var rx = attrLen(n, "rx", vw);
        var ry = attrLen(n, "ry", vh);
        if (n.get("rx") == null) rx = ry;
        if (n.get("ry") == null) ry = rx;
        rx = @min(rx, w / 2);
        ry = @min(ry, h / 2);
        if (rx > 0 and ry > 0) {
            try b.move(.{ x + rx, y });
            try b.line(.{ x + w - rx, y });
            try b.arc(rx, ry, 0, false, true, .{ x + w, y + ry });
            try b.line(.{ x + w, y + h - ry });
            try b.arc(rx, ry, 0, false, true, .{ x + w - rx, y + h });
            try b.line(.{ x + rx, y + h });
            try b.arc(rx, ry, 0, false, true, .{ x, y + h - ry });
            try b.line(.{ x, y + ry });
            try b.arc(rx, ry, 0, false, true, .{ x + rx, y });
        } else {
            try b.move(.{ x, y });
            try b.line(.{ x + w, y });
            try b.line(.{ x + w, y + h });
            try b.line(.{ x, y + h });
        }
        try b.close();
    } else if (eq(u8, n.name, "circle") or eq(u8, n.name, "ellipse")) {
        const cx = attrLen(n, "cx", vw);
        const cy = attrLen(n, "cy", vh);
        const diag = @sqrt((vw * vw + vh * vh) / 2);
        var rx = if (eq(u8, n.name, "circle")) attrLen(n, "r", diag) else attrLen(n, "rx", vw);
        var ry = if (eq(u8, n.name, "circle")) rx else attrLen(n, "ry", vh);
        if (!eq(u8, n.name, "circle")) {
            if (n.get("rx") == null) rx = ry;
            if (n.get("ry") == null) ry = rx;
        }
        if (rx <= 0 or ry <= 0) return;
        try b.move(.{ cx + rx, cy });
        try b.arc(rx, ry, 0, false, true, .{ cx - rx, cy });
        try b.arc(rx, ry, 0, false, true, .{ cx + rx, cy });
        try b.close();
    } else if (eq(u8, n.name, "line")) {
        try b.move(.{ attrLen(n, "x1", vw), attrLen(n, "y1", vh) });
        try b.line(.{ attrLen(n, "x2", vw), attrLen(n, "y2", vh) });
    } else if (eq(u8, n.name, "polyline") or eq(u8, n.name, "polygon")) {
        try pointList(&b, n.get("points") orelse return, eq(u8, n.name, "polygon"));
    } else return;
    // A line has no inside.
    var shape_st = st;
    if (eq(u8, n.name, "line")) shape_st.fill = .none;
    try drawShape(ctx, &poly, shape_st, m);
}

const ViewBox = struct { m: Mat, vw: f64, vh: f64 };

/// The transform a `viewBox` makes into a `w`×`h` viewport, with the
/// `preserveAspectRatio` alignment (default `xMidYMid meet`).
fn viewBoxMat(n: *const Node, w: f64, h: f64) ViewBox {
    const vb = n.get("viewBox") orelse return .{ .m = .{}, .vw = w, .vh = h };
    var it = Numbers{ .s = vb };
    const vx = it.next() orelse return .{ .m = .{}, .vw = w, .vh = h };
    const vy = it.next() orelse return .{ .m = .{}, .vw = w, .vh = h };
    const vw = it.next() orelse return .{ .m = .{}, .vw = w, .vh = h };
    const vh = it.next() orelse return .{ .m = .{}, .vw = w, .vh = h };
    if (vw <= 0 or vh <= 0) return .{ .m = .{}, .vw = w, .vh = h };
    var sx = w / vw;
    var sy = h / vh;
    const par = std.mem.trim(u8, n.get("preserveAspectRatio") orelse "xMidYMid meet", " ");
    var tx: f64 = 0;
    var ty: f64 = 0;
    if (!std.mem.startsWith(u8, par, "none")) {
        const slice = std.mem.indexOf(u8, par, "slice") != null;
        const s = if (slice) @max(sx, sy) else @min(sx, sy);
        const xa: f64 = if (std.mem.indexOf(u8, par, "xMin") != null) 0 else if (std.mem.indexOf(u8, par, "xMax") != null) 1 else 0.5;
        const ya: f64 = if (std.mem.indexOf(u8, par, "YMin") != null) 0 else if (std.mem.indexOf(u8, par, "YMax") != null) 1 else 0.5;
        tx = (w - vw * s) * xa;
        ty = (h - vh * s) * ya;
        sx = s;
        sy = s;
    }
    return .{ .m = .{ .a = sx, .d = sy, .e = tx - vx * sx, .f = ty - vy * sy }, .vw = vw, .vh = vh };
}

/// A document's natural size in CSS pixels: its `width` and `height`,
/// one completing the other by the `viewBox` ratio, else the viewBox's,
/// else 300×150.
pub fn naturalSize(a: std.mem.Allocator, src: []const u8) Error![2]f64 {
    const t = try parse(a, src);
    return sizeOf(&t);
}

fn sizeOf(t: *const Tree) [2]f64 {
    const root = &t.nodes.items[t.root.?];
    var vb_w: ?f64 = null;
    var vb_h: ?f64 = null;
    if (root.get("viewBox")) |vb| {
        var it = Numbers{ .s = vb };
        _ = it.next();
        _ = it.next();
        vb_w = it.next();
        vb_h = it.next();
    }
    const wa = root.get("width");
    const ha = root.get("height");
    const pct = struct {
        fn f(v: ?[]const u8) bool {
            const s = v orelse return true;
            return std.mem.indexOfScalar(u8, s, '%') != null;
        }
    }.f;
    var w: ?f64 = if (!pct(wa)) length(wa.?, 0) else null;
    var h: ?f64 = if (!pct(ha)) length(ha.?, 0) else null;
    if (vb_w != null and vb_h != null and vb_w.? > 0 and vb_h.? > 0) {
        if (w == null and h == null) {
            w = vb_w;
            h = vb_h;
        } else if (w == null) {
            w = h.? * vb_w.? / vb_h.?;
        } else if (h == null) h = w.? * vb_h.? / vb_w.?;
    }
    return .{ w orelse 300, h orelse 150 };
}

/// Render a document at `scale` device pixels per CSS pixel of its
/// natural size into RGBA (at most 4096 pixels a side).
pub fn render(a: std.mem.Allocator, src: []const u8, scale: f64) Error!image.Image {
    const t = try parse(a, src);
    const size = sizeOf(&t);
    const s = @max(0.01, scale);
    const w: usize = @intFromFloat(std.math.clamp(@round(size[0] * s), 1, 4096));
    const h: usize = @intFromFloat(std.math.clamp(@round(size[1] * s), 1, 4096));
    return draw(a, &t, w, h, .{ 0, 0, 0, 1 });
}

/// Render a document into exactly `w`×`h` pixels (its viewBox fitted as
/// `preserveAspectRatio` says), `current` the colour `currentColor` is:
/// an inline `<svg>` drawn at its box's size in its element's colour.
/// `fill`, when given, is the fill the document inherits (the page's
/// CSS `fill` on the `<svg>` element).
pub fn renderSize(a: std.mem.Allocator, src: []const u8, w_in: usize, h_in: usize, current: [4]f64, fill: ?[4]f64) Error!image.Image {
    const t = try parse(a, src);
    return drawFilled(a, &t, std.math.clamp(w_in, 1, 4096), std.math.clamp(h_in, 1, 4096), current, fill);
}

fn draw(a: std.mem.Allocator, t_in: *const Tree, w: usize, h: usize, current: [4]f64) Error!image.Image {
    return drawFilled(a, t_in, w, h, current, null);
}

fn drawFilled(a: std.mem.Allocator, t_in: *const Tree, w: usize, h: usize, current: [4]f64, fill: ?[4]f64) Error!image.Image {
    const t = t_in.*;
    var r: Raster = .{ .w = w, .h = h, .px = try a.alloc(u8, w * h * 4), .cov = try a.alloc(f32, w * h) };
    @memset(r.px, 0);
    const root = &t.nodes.items[t.root.?];
    const fw: f64 = @floatFromInt(w);
    const fh: f64 = @floatFromInt(h);
    const vm = viewBoxMat(root, fw, fh);
    var ctx: Ctx = .{ .a = a, .tree = &t, .r = &r };
    var inherited: Style = .{ .color = current };
    if (fill) |f| inherited.fill = .{ .rgba = f };
    const st = styleOf(&t, a, root, inherited);
    for (root.children.items) |c| try drawNode(&ctx, c, vm.m, st, vm.vw, vm.vh);
    // Un-premultiplied in place: the pixels are the picture.
    const out = r.px;
    for (0..w * h) |i| {
        const al: u32 = out[i * 4 + 3];
        if (al == 0 or al == 255) continue;
        for (0..3) |k| out[i * 4 + k] = @intCast(@min(255, (@as(u32, out[i * 4 + k]) * 255 + al / 2) / al));
    }
    return .{ .w = @intCast(w), .h = @intCast(h), .rgba = out };
}

// ------------------------------------------------------------------ tests

fn pixel(img: image.Image, x: usize, y: usize) [4]u8 {
    const o = (y * img.w + x) * 4;
    return img.rgba[o..][0..4].*;
}

test "svg: shapes, fills, strokes, transforms and viewBox" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\<?xml version="1.0"?>
        \\<svg xmlns="http://www.w3.org/2000/svg" width="40" height="20" viewBox="0 0 80 40">
        \\  <style>.blue { fill: #0000ff }</style>
        \\  <rect x="0" y="0" width="40" height="40" fill="red"/>
        \\  <g transform="translate(40,0)"><circle class="blue" cx="20" cy="20" r="20"/></g>
        \\  <path d="M0 38 H80" stroke="#00ff00" stroke-width="4" fill="none"/>
        \\</svg>
    ;
    try std.testing.expect(sniff(src));
    const size = try naturalSize(a, src);
    try std.testing.expectEqual(@as(f64, 40), size[0]);
    const img = try render(a, src, 2);
    try std.testing.expectEqual(@as(u32, 80), img.w);
    try std.testing.expectEqual(@as(u32, 40), img.h);
    // The rect's inside is red, opaque.
    try std.testing.expectEqual([4]u8{ 255, 0, 0, 255 }, pixel(img, 10, 10));
    // The circle's centre is blue; its bounding box's corner is empty.
    try std.testing.expectEqual([4]u8{ 0, 0, 255, 255 }, pixel(img, 60, 20));
    try std.testing.expectEqual(@as(u8, 0), pixel(img, 79, 0)[3]);
    // The stroke runs along the bottom.
    try std.testing.expectEqual([4]u8{ 0, 255, 0, 255 }, pixel(img, 50, 38));
}

test "svg: arcs, even-odd, use and a symbol, compact numbers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const src =
        \\<svg xmlns="http://www.w3.org/2000/svg" xmlns:xlink="http://www.w3.org/1999/xlink" viewBox="0 0 100 50">
        \\  <defs><symbol id="s" viewBox="0 0 10 10"><rect width="10" height="10" fill="#123456"/></symbol></defs>
        \\  <path fill-rule="evenodd" d="M0 0h50v50H0zM10 10h30v30H10z" fill="black"/>
        \\  <use xlink:href="#s" x="60" y="10" width="20" height="20"/>
        \\  <path d="M75.5.5a5 5 0 1 0 1e-3 0z" fill="red"/>
        \\</svg>
    ;
    const img = try render(a, src, 1);
    try std.testing.expectEqual(@as(u32, 100), img.w);
    // The ring is black, its hole empty.
    try std.testing.expectEqual(@as(u8, 255), pixel(img, 5, 25)[3]);
    try std.testing.expectEqual(@as(u8, 0), pixel(img, 25, 25)[3]);
    // The symbol drawn through `use`, scaled into its 20×20 box.
    try std.testing.expectEqual([4]u8{ 0x12, 0x34, 0x56, 255 }, pixel(img, 70, 20));
}
