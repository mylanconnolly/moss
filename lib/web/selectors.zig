//! CSS selectors over the DOM: Selectors Level 3 and the useful part of
//! Level 4 — type, universal, id, class, attribute selectors with every
//! operator and the `i` flag, the structural pseudo-classes (`:root`,
//! `:empty`, `:first-child` and kin, `:nth-child(An+B [of S])` and kin),
//! `:not()`, `:is()`, `:where()`, `:has()`, and the four combinators. A
//! selector list is parsed once into a small tree and matched against
//! elements right to left, as engines do. The same matcher serves
//! `html-select` in the shell today and the cascade later, so nothing
//! here knows about style.
//!
//! Not built: namespaces, `:lang()`, the link and user-action
//! pseudo-classes (`:hover`, `:focus`, …: no user yet), pseudo-elements,
//! `:nth-col()`. An unknown pseudo-class fails the parse rather than
//! silently matching nothing.
const std = @import("std");
const dom = @import("dom.zig");

pub const Error = error{ OutOfMemory, Invalid };

const Document = dom.Document;
const NodeId = dom.NodeId;

pub const AttrOp = enum { exists, eq, includes, dash, prefix, suffix, substring };

pub const Nth = struct { a: i32, b: i32 };

pub const Pseudo = union(enum) {
    root,
    empty,
    first_child,
    last_child,
    only_child,
    first_of_type,
    last_of_type,
    only_of_type,
    nth_child: Nth,
    nth_last_child: Nth,
    nth_of_type: Nth,
    nth_last_of_type: Nth,
    not: []const Complex,
    is: []const Complex,
    /// `:where()`: `:is()` with no specificity.
    where: []const Complex,
    has: []const Complex,
    checked,
    disabled,
    enabled,
    link,
    /// The pointer is over the element or a descendant (`Document.hovered`).
    hover,
    /// The element or a descendant is pressed (`Document.active`).
    active,
    /// The element is focused (`:focus`, `:focus-visible`), or holds the
    /// focus (`:focus-within`).
    focus,
    focus_within,
    /// A state no static match has (`:visited`, `:target`…), or a
    /// pseudo-element (the boxes they make are not built): parsed so
    /// the rest of a selector list stands, matched by nothing.
    never,
    required,
    optional,
    read_write,
    read_only,
    placeholder_shown,
    lang: []const u8,
};

pub const Simple = union(enum) {
    universal,
    type: []const u8,
    id: []const u8,
    class: []const u8,
    attr: struct { name: []const u8, op: AttrOp, value: []const u8, insensitive: bool },
    pseudo: Pseudo,
};

pub const Combinator = enum { descendant, child, next_sibling, subsequent_sibling };

/// A compound selector and the combinator that joins it to the one on
/// its left (null for the leftmost).
pub const Compound = struct {
    simples: []const Simple,
    combinator: ?Combinator,
};

/// A complex selector: compounds left to right.
pub const Complex = struct {
    compounds: []const Compound,
    /// Set when the selector is relative (inside `:has()`): the first
    /// compound is matched against the anchor's descendants (or children,
    /// siblings) rather than anywhere.
    relative: ?Combinator = null,
};

/// Deep copies into `a`, for a selector that must outlive its parse.
pub fn cloneComplex(a: std.mem.Allocator, c: Complex) std.mem.Allocator.Error!Complex {
    const compounds = try a.alloc(Compound, c.compounds.len);
    for (c.compounds, 0..) |cp, i| {
        const simples = try a.alloc(Simple, cp.simples.len);
        for (cp.simples, 0..) |sm, j| simples[j] = try cloneSimple(a, sm);
        compounds[i] = .{ .simples = simples, .combinator = cp.combinator };
    }
    return .{ .compounds = compounds, .relative = c.relative };
}

fn cloneComplexes(a: std.mem.Allocator, list: []const Complex) std.mem.Allocator.Error![]const Complex {
    const out = try a.alloc(Complex, list.len);
    for (list, 0..) |c, i| out[i] = try cloneComplex(a, c);
    return out;
}

fn cloneSimple(a: std.mem.Allocator, sm: Simple) std.mem.Allocator.Error!Simple {
    return switch (sm) {
        .universal => .universal,
        .type => |t| .{ .type = try a.dupe(u8, t) },
        .id => |t| .{ .id = try a.dupe(u8, t) },
        .class => |t| .{ .class = try a.dupe(u8, t) },
        .attr => |at| .{ .attr = .{ .name = try a.dupe(u8, at.name), .op = at.op, .value = try a.dupe(u8, at.value), .insensitive = at.insensitive } },
        .pseudo => |ps| .{ .pseudo = switch (ps) {
            .not => |l| .{ .not = try cloneComplexes(a, l) },
            .is => |l| .{ .is = try cloneComplexes(a, l) },
            .where => |l| .{ .where = try cloneComplexes(a, l) },
            .has => |l| .{ .has = try cloneComplexes(a, l) },
            .lang => |t| .{ .lang = try a.dupe(u8, t) },
            else => ps,
        } },
    };
}

pub const Selector = struct {
    list: []const Complex,

    pub fn parse(a: std.mem.Allocator, text: []const u8) Error!Selector {
        var p: Parser = .{ .a = a, .s = text };
        const list = try p.parseList(false);
        p.skipWs();
        if (p.pos != p.s.len) return error.Invalid;
        return .{ .list = list };
    }

    /// Does `id` match any selector in the list?
    pub fn matches(sel: *const Selector, doc: *const Document, id: NodeId) bool {
        if (doc.get(id).kind != .element) return false;
        for (sel.list) |c| if (matchComplex(doc, id, c, null)) return true;
        return false;
    }

    /// Every matching element under `root` in document order (root
    /// itself excluded), into `out`.
    pub fn queryAll(sel: *const Selector, doc: *const Document, root: NodeId, a: std.mem.Allocator, out: *std.ArrayList(NodeId)) Error!void {
        var w = doc.walk(root);
        while (w.next()) |id| if (sel.matches(doc, id)) try out.append(a, id);
    }

    /// Does `id` match this one complex selector of the list?
    pub fn matchesOne(doc: *const Document, id: NodeId, c: Complex) bool {
        if (doc.get(id).kind != .element) return false;
        return matchComplex(doc, id, c, null);
    }

    pub fn queryFirst(sel: *const Selector, doc: *const Document, root: NodeId) ?NodeId {
        var w = doc.walk(root);
        while (w.next()) |id| if (sel.matches(doc, id)) return id;
        return null;
    }
};

// -------------------------------------------------------------- matching

/// Match right to left: the rightmost compound against `id`, then walk
/// the combinators leftward. `anchor` bounds a relative selector.
fn matchComplex(doc: *const Document, id: NodeId, c: Complex, anchor: ?NodeId) bool {
    return matchFrom(doc, id, c, c.compounds.len - 1, anchor);
}

fn matchFrom(doc: *const Document, id: NodeId, c: Complex, index: usize, anchor: ?NodeId) bool {
    const comp = c.compounds[index];
    if (!matchCompound(doc, id, comp.simples)) return false;
    if (index == 0) {
        // The leftmost compound of a relative selector must sit in the
        // right relation to the anchor.
        const rel = c.relative orelse return true;
        const an = anchor orelse return true;
        return switch (rel) {
            .descendant => isAncestor(doc, an, id),
            .child => doc.get(id).parent == an,
            .next_sibling => prevElement(doc, id) == an,
            .subsequent_sibling => blk: {
                var s = prevElement(doc, id);
                while (s) |sid| : (s = prevElement(doc, sid)) if (sid == an) break :blk true;
                break :blk false;
            },
        };
    }
    switch (comp.combinator.?) {
        .descendant => {
            var p = doc.get(id).parent;
            while (p) |pid| : (p = doc.get(pid).parent) {
                if (doc.get(pid).kind != .element) break;
                if (anchor != null and pid == anchor.? and c.relative == .descendant) {
                    // An anchor is never part of its own relative match.
                    break;
                }
                if (matchFrom(doc, pid, c, index - 1, anchor)) return true;
            }
            return false;
        },
        .child => {
            const p = doc.get(id).parent orelse return false;
            if (doc.get(p).kind != .element) return false;
            return matchFrom(doc, p, c, index - 1, anchor);
        },
        .next_sibling => {
            const s = prevElement(doc, id) orelse return false;
            return matchFrom(doc, s, c, index - 1, anchor);
        },
        .subsequent_sibling => {
            var s = prevElement(doc, id);
            while (s) |sid| : (s = prevElement(doc, sid)) if (matchFrom(doc, sid, c, index - 1, anchor)) return true;
            return false;
        },
    }
}

fn isAncestor(doc: *const Document, anc: NodeId, id: NodeId) bool {
    var p = doc.get(id).parent;
    while (p) |pid| : (p = doc.get(pid).parent) if (pid == anc) return true;
    return false;
}

fn prevElement(doc: *const Document, id: NodeId) ?NodeId {
    var s = doc.get(id).prev;
    while (s) |sid| : (s = doc.get(sid).prev) if (doc.get(sid).kind == .element) return sid;
    return null;
}

fn nextElement(doc: *const Document, id: NodeId) ?NodeId {
    var s = doc.get(id).next;
    while (s) |sid| : (s = doc.get(sid).next) if (doc.get(sid).kind == .element) return sid;
    return null;
}

fn matchCompound(doc: *const Document, id: NodeId, simples: []const Simple) bool {
    for (simples) |s| if (!matchSimple(doc, id, s)) return false;
    return true;
}

fn matchSimple(doc: *const Document, id: NodeId, s: Simple) bool {
    const n = doc.get(id);
    switch (s) {
        .universal => return true,
        // HTML element names are matched case-insensitively (they are
        // lowercased in the tree; the selector may not be); foreign ones
        // exactly.
        .type => |t| return if (n.namespace == .html) std.ascii.eqlIgnoreCase(n.name, t) else std.mem.eql(u8, n.name, t),
        .id => |v| return if (doc.getAttr(id, "id")) |have| std.mem.eql(u8, have, v) else false,
        .class => |v| return hasClass(doc.getAttr(id, "class") orelse return false, v),
        .attr => |at| {
            const have = attrValue(doc, id, at.name) orelse return false;
            const ci = at.insensitive;
            return switch (at.op) {
                .exists => true,
                .eq => strEq(ci, have, at.value),
                .includes => blk: {
                    if (at.value.len == 0) break :blk false;
                    var it = std.mem.tokenizeAny(u8, have, " \t\n\r\x0c");
                    while (it.next()) |w| if (strEq(ci, w, at.value)) break :blk true;
                    break :blk false;
                },
                .dash => strEq(ci, have, at.value) or (have.len > at.value.len and have[at.value.len] == '-' and strEq(ci, have[0..at.value.len], at.value)),
                .prefix => at.value.len > 0 and have.len >= at.value.len and strEq(ci, have[0..at.value.len], at.value),
                .suffix => at.value.len > 0 and have.len >= at.value.len and strEq(ci, have[have.len - at.value.len ..], at.value),
                .substring => at.value.len > 0 and (if (at.insensitive) std.ascii.indexOfIgnoreCase(have, at.value) != null else std.mem.indexOf(u8, have, at.value) != null),
            };
        },
        .pseudo => |ps| return matchPseudo(doc, id, ps),
    }
}

fn strEq(insensitive: bool, x: []const u8, y: []const u8) bool {
    return if (insensitive) std.ascii.eqlIgnoreCase(x, y) else std.mem.eql(u8, x, y);
}

/// Attribute names on HTML elements are case-insensitive.
fn attrValue(doc: *const Document, id: NodeId, name: []const u8) ?[]const u8 {
    const n = doc.get(id);
    for (n.attrs.items) |at| {
        const same = if (n.namespace == .html) std.ascii.eqlIgnoreCase(at.name, name) else std.mem.eql(u8, at.name, name);
        if (same) return at.value;
    }
    return null;
}

fn matchPseudo(doc: *const Document, id: NodeId, ps: Pseudo) bool {
    const n = doc.get(id);
    switch (ps) {
        .root => return if (n.parent) |p| doc.get(p).kind == .document else false,
        .empty => {
            var c = n.first_child;
            while (c) |cid| : (c = doc.get(cid).next) {
                const cn = doc.get(cid);
                if (cn.kind == .element) return false;
                if (cn.kind == .text and cn.text.items.len > 0) return false;
            }
            return true;
        },
        .first_child => return prevElement(doc, id) == null and parentIsElement(doc, id),
        .last_child => return nextElement(doc, id) == null and parentIsElement(doc, id),
        .only_child => return prevElement(doc, id) == null and nextElement(doc, id) == null and parentIsElement(doc, id),
        .first_of_type => return prevOfType(doc, id) == null and parentIsElement(doc, id),
        .last_of_type => return nextOfType(doc, id) == null and parentIsElement(doc, id),
        .only_of_type => return prevOfType(doc, id) == null and nextOfType(doc, id) == null and parentIsElement(doc, id),
        .nth_child => |nth| return parentIsElement(doc, id) and nthMatches(nth, countBefore(doc, id, false) + 1),
        .nth_last_child => |nth| return parentIsElement(doc, id) and nthMatches(nth, countAfter(doc, id, false) + 1),
        .nth_of_type => |nth| return parentIsElement(doc, id) and nthMatches(nth, countBefore(doc, id, true) + 1),
        .nth_last_of_type => |nth| return parentIsElement(doc, id) and nthMatches(nth, countAfter(doc, id, true) + 1),
        .not => |list| {
            for (list) |c| if (matchComplex(doc, id, c, null)) return false;
            return true;
        },
        .is, .where => |list| {
            for (list) |c| if (matchComplex(doc, id, c, null)) return true;
            return false;
        },
        .has => |list| {
            // Any element under (or beside) this one that the relative
            // selector reaches from it.
            for (list) |c| {
                if (c.relative == .next_sibling or c.relative == .subsequent_sibling) {
                    var s = nextElement(doc, id);
                    while (s) |sid| : (s = nextElement(doc, sid)) {
                        var w = doc.walk(sid);
                        if (matchComplex(doc, sid, c, id)) return true;
                        while (w.next()) |d| if (matchComplex(doc, d, c, id)) return true;
                    }
                } else {
                    var w = doc.walk(id);
                    while (w.next()) |d| if (matchComplex(doc, d, c, id)) return true;
                }
            }
            return false;
        },
        .checked => {
            // A checkbox or radio that is checked (its state, not only its
            // attribute), or a selected option.
            if (std.mem.eql(u8, n.name, "option")) return attrValue(doc, id, "selected") != null;
            if (!std.mem.eql(u8, n.name, "input")) return false;
            const t = attrValue(doc, id, "type") orelse return false;
            if (!(std.ascii.eqlIgnoreCase(t, "checkbox") or std.ascii.eqlIgnoreCase(t, "radio"))) return false;
            return doc.isChecked(id);
        },
        .disabled => return attrValue(doc, id, "disabled") != null,
        .enabled => return attrValue(doc, id, "disabled") == null and (std.mem.eql(u8, n.name, "input") or std.mem.eql(u8, n.name, "button") or std.mem.eql(u8, n.name, "select") or std.mem.eql(u8, n.name, "textarea")),
        .link => return (std.mem.eql(u8, n.name, "a") or std.mem.eql(u8, n.name, "area")) and attrValue(doc, id, "href") != null,
        .hover => return inChain(doc, doc.hovered, id),
        .active => return inChain(doc, doc.active, id),
        .focus => return doc.focused == id,
        .focus_within => return inChain(doc, doc.focused, id),
        .never => return false,
        .required => return isFormField(n.name) and attrValue(doc, id, "required") != null,
        .optional => return isFormField(n.name) and attrValue(doc, id, "required") == null,
        .read_write => return isEditable(doc, id),
        .read_only => return !isEditable(doc, id),
        .placeholder_shown => return isEditable(doc, id) and attrValue(doc, id, "placeholder") != null and (attrValue(doc, id, "value") orelse @as([]const u8, "")).len == 0,
        .lang => |want| {
            // The nearest `lang` up the tree, matched as a range.
            var q: ?NodeId = id;
            while (q) |qid| : (q = doc.get(qid).parent) {
                if (doc.get(qid).kind != .element) continue;
                const have = attrValue(doc, qid, "lang") orelse continue;
                if (have.len < want.len or !std.ascii.eqlIgnoreCase(have[0..want.len], want)) return false;
                return have.len == want.len or have[want.len] == '-';
            }
            return false;
        },
    }
}

fn isFormField(name: []const u8) bool {
    return std.mem.eql(u8, name, "input") or std.mem.eql(u8, name, "select") or std.mem.eql(u8, name, "textarea");
}

/// A text field the user can type into.
fn isEditable(doc: *const Document, id: NodeId) bool {
    const n = doc.get(id);
    if (attrValue(doc, id, "readonly") != null or attrValue(doc, id, "disabled") != null) return false;
    if (std.mem.eql(u8, n.name, "textarea")) return true;
    if (!std.mem.eql(u8, n.name, "input")) return false;
    const t = attrValue(doc, id, "type") orelse return true;
    const eq = std.ascii.eqlIgnoreCase;
    return eq(t, "text") or eq(t, "search") or eq(t, "email") or eq(t, "url") or eq(t, "tel") or eq(t, "password") or eq(t, "number") or t.len == 0;
}

/// Whether a class list holds `class`: a substring search with the
/// boundaries checked (a tokenizer per test was most of a large site's
/// cascade — descendant selectors test every ancestor).
fn hasClass(list: []const u8, class: []const u8) bool {
    if (class.len == 0 or class.len > list.len) return false;
    var from: usize = 0;
    while (std.mem.indexOfPos(u8, list, from, class)) |at| {
        const end = at + class.len;
        const before_ok = at == 0 or isClassSpace(list[at - 1]);
        const after_ok = end == list.len or isClassSpace(list[end]);
        if (before_ok and after_ok) return true;
        from = at + 1;
    }
    return false;
}

fn isClassSpace(c: u8) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
}

fn parentIsElement(doc: *const Document, id: NodeId) bool {
    const p = doc.get(id).parent orelse return false;
    return doc.get(p).kind == .element or doc.get(p).kind == .fragment;
}

fn sameType(doc: *const Document, x: NodeId, y: NodeId) bool {
    const a = doc.get(x);
    const b = doc.get(y);
    return a.namespace == b.namespace and std.mem.eql(u8, a.name, b.name);
}

fn prevOfType(doc: *const Document, id: NodeId) ?NodeId {
    var s = prevElement(doc, id);
    while (s) |sid| : (s = prevElement(doc, sid)) if (sameType(doc, sid, id)) return sid;
    return null;
}

fn nextOfType(doc: *const Document, id: NodeId) ?NodeId {
    var s = nextElement(doc, id);
    while (s) |sid| : (s = nextElement(doc, sid)) if (sameType(doc, sid, id)) return sid;
    return null;
}

/// Whether `id` is `from` or one of its ancestors.
fn inChain(doc: *const Document, from: ?NodeId, id: NodeId) bool {
    var cur = from;
    while (cur) |c| : (cur = doc.get(c).parent) if (c == id) return true;
    return false;
}

/// Whether a complex selector depends on the interaction state (so a
/// hover or press changes what matches).
pub fn isInteractive(c: Complex) bool {
    for (c.compounds) |comp| for (comp.simples) |sm| {
        if (sm != .pseudo) continue;
        switch (sm.pseudo) {
            .hover, .active, .focus, .focus_within => return true,
            .not, .is, .where, .has => |list| for (list) |inner| if (isInteractive(inner)) return true,
            else => {},
        }
    };
    return false;
}

fn countBefore(doc: *const Document, id: NodeId, of_type: bool) i32 {
    var n: i32 = 0;
    var s = prevElement(doc, id);
    while (s) |sid| : (s = prevElement(doc, sid)) if (!of_type or sameType(doc, sid, id)) {
        n += 1;
    };
    return n;
}

fn countAfter(doc: *const Document, id: NodeId, of_type: bool) i32 {
    var n: i32 = 0;
    var s = nextElement(doc, id);
    while (s) |sid| : (s = nextElement(doc, sid)) if (!of_type or sameType(doc, sid, id)) {
        n += 1;
    };
    return n;
}

fn nthMatches(nth: Nth, index: i32) bool {
    if (nth.a == 0) return index == nth.b;
    const diff = index - nth.b;
    if (@rem(diff, nth.a) != 0) return false;
    return @divTrunc(diff, nth.a) >= 0;
}

// ----------------------------------------------------------- specificity

/// A selector's specificity as one number: ids, then classes and
/// attributes and pseudo-classes, then types, ten bits each — so the
/// cascade compares by integer. `:is()`, `:not()` and `:has()` count as
/// their most specific argument; `:where()` counts nothing.
pub fn specificity(c: Complex) u32 {
    var ids: u32 = 0;
    var classes: u32 = 0;
    var types: u32 = 0;
    for (c.compounds) |comp| for (comp.simples) |s| switch (s) {
        .universal => {},
        .type => types += 1,
        .id => ids += 1,
        .class, .attr => classes += 1,
        .pseudo => |ps| switch (ps) {
            .not, .is, .has => |list| {
                var best: u32 = 0;
                for (list) |inner| best = @max(best, specificity(inner));
                ids += best >> 20;
                classes += (best >> 10) & 0x3ff;
                types += best & 0x3ff;
            },
            .where => {},
            else => classes += 1,
        },
    };
    return (@as(u32, @min(ids, 1023)) << 20) | (@as(u32, @min(classes, 1023)) << 10) | @as(u32, @min(types, 1023));
}

// --------------------------------------------------------------- parsing

const Parser = struct {
    a: std.mem.Allocator,
    s: []const u8,
    pos: usize = 0,

    fn peek(p: *const Parser) ?u8 {
        return if (p.pos < p.s.len) p.s[p.pos] else null;
    }

    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) if (!isWs(c)) break;
    }

    fn isWs(c: u8) bool {
        return c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c;
    }

    fn isNameStart(c: u8) bool {
        return std.ascii.isAlphabetic(c) or c == '_' or c == '-' or c >= 0x80 or c == '\\';
    }

    fn isNameChar(c: u8) bool {
        return isNameStart(c) or std.ascii.isDigit(c);
    }

    /// An identifier with CSS escapes undone; one without escapes is a
    /// slice of the source.
    fn ident(p: *Parser) Error![]const u8 {
        const start = p.pos;
        while (p.peek()) |c| : (p.pos += 1) if (!isNameChar(c) or c == '\\') break;
        if (p.peek() != '\\') {
            if (p.pos == start) return error.Invalid;
            return p.s[start..p.pos];
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(p.a, p.s[start..p.pos]);
        while (p.peek()) |c| {
            if (c == '\\') {
                p.pos += 1;
                const next = p.peek() orelse return error.Invalid;
                if (std.ascii.isHex(next)) {
                    var cp: u21 = 0;
                    var digits: usize = 0;
                    while (p.peek()) |h| {
                        if (digits == 6 or !std.ascii.isHex(h)) break;
                        cp = cp * 16 + (std.fmt.charToDigit(h, 16) catch 0);
                        digits += 1;
                        p.pos += 1;
                    }
                    if (p.peek() == ' ') p.pos += 1;
                    var buf: [4]u8 = undefined;
                    const n = std.unicode.utf8Encode(if (cp == 0 or cp > 0x10ffff) 0xfffd else cp, &buf) catch 1;
                    try out.appendSlice(p.a, buf[0..n]);
                } else {
                    try out.append(p.a, next);
                    p.pos += 1;
                }
                continue;
            }
            if (!isNameChar(c)) break;
            try out.append(p.a, c);
            p.pos += 1;
        }
        if (p.pos == start) return error.Invalid;
        return out.items;
    }

    fn parseList(p: *Parser, relative: bool) Error![]const Complex {
        var list: std.ArrayList(Complex) = .empty;
        while (true) {
            p.skipWs();
            try list.append(p.a, try p.parseComplex(relative));
            p.skipWs();
            if (p.peek() == ',') {
                p.pos += 1;
                continue;
            }
            break;
        }
        return list.items;
    }

    fn parseComplex(p: *Parser, relative: bool) Error!Complex {
        var compounds: std.ArrayList(Compound) = .empty;
        var rel: ?Combinator = null;
        var comb: ?Combinator = null;
        if (relative) {
            p.skipWs();
            rel = p.parseCombinatorSymbol() orelse .descendant;
            p.skipWs();
        }
        while (true) {
            const simples = try p.parseCompound();
            if (simples.len == 0) return error.Invalid;
            try compounds.append(p.a, .{ .simples = simples, .combinator = comb });
            // A combinator, or the end.
            const had_ws = p.peek() != null and isWs(p.peek().?);
            p.skipWs();
            const c = p.peek() orelse break;
            if (c == ',' or c == ')') break;
            if (p.parseCombinatorSymbol()) |sym| {
                comb = sym;
                p.skipWs();
            } else if (had_ws) {
                comb = .descendant;
            } else return error.Invalid;
        }
        return .{ .compounds = compounds.items, .relative = rel };
    }

    fn parseCombinatorSymbol(p: *Parser) ?Combinator {
        const c = p.peek() orelse return null;
        const sym: Combinator = switch (c) {
            '>' => .child,
            '+' => .next_sibling,
            '~' => .subsequent_sibling,
            else => return null,
        };
        p.pos += 1;
        return sym;
    }

    fn parseCompound(p: *Parser) Error![]const Simple {
        var simples: std.ArrayList(Simple) = .empty;
        if (p.peek()) |c| {
            if (c == '*') {
                p.pos += 1;
                try simples.append(p.a, .universal);
            } else if (isNameStart(c) and c != '-' or (c == '-' and p.pos + 1 < p.s.len and isNameStart(p.s[p.pos + 1]))) {
                try simples.append(p.a, .{ .type = try p.ident() });
            }
        }
        while (p.peek()) |c| {
            switch (c) {
                '#' => {
                    p.pos += 1;
                    try simples.append(p.a, .{ .id = try p.ident() });
                },
                '.' => {
                    p.pos += 1;
                    try simples.append(p.a, .{ .class = try p.ident() });
                },
                '[' => {
                    p.pos += 1;
                    try simples.append(p.a, try p.parseAttr());
                },
                ':' => {
                    p.pos += 1;
                    if (p.peek() == ':') {
                        // A pseudo-element: its boxes are not built, so it
                        // matches nothing — but a list it is in stands.
                        p.pos += 1;
                        try simples.append(p.a, .{ .pseudo = try p.parsePseudoElement() });
                    } else try simples.append(p.a, .{ .pseudo = try p.parsePseudo() });
                },
                else => break,
            }
        }
        return simples.items;
    }

    fn parseAttr(p: *Parser) Error!Simple {
        p.skipWs();
        const name = try p.ident();
        p.skipWs();
        var op: AttrOp = .exists;
        var value: []const u8 = "";
        var insensitive = false;
        const c = p.peek() orelse return error.Invalid;
        if (c != ']') {
            op = switch (c) {
                '=' => .eq,
                '~' => .includes,
                '|' => .dash,
                '^' => .prefix,
                '$' => .suffix,
                '*' => .substring,
                else => return error.Invalid,
            };
            p.pos += 1;
            if (op != .eq) {
                if (p.peek() != '=') return error.Invalid;
                p.pos += 1;
            }
            p.skipWs();
            value = try p.stringOrIdent();
            p.skipWs();
            if (p.peek() == 'i' or p.peek() == 'I') {
                insensitive = true;
                p.pos += 1;
                p.skipWs();
            } else if (p.peek() == 's' or p.peek() == 'S') {
                p.pos += 1;
                p.skipWs();
            }
        }
        if (p.peek() != ']') return error.Invalid;
        p.pos += 1;
        return .{ .attr = .{ .name = name, .op = op, .value = value, .insensitive = insensitive } };
    }

    fn stringOrIdent(p: *Parser) Error![]const u8 {
        const c = p.peek() orelse return error.Invalid;
        if (c != '"' and c != '\'') return p.ident();
        p.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        while (p.peek()) |ch| {
            p.pos += 1;
            if (ch == c) return out.items;
            if (ch == '\\') {
                const n = p.peek() orelse return error.Invalid;
                p.pos += 1;
                if (n == '\n') continue;
                try out.append(p.a, n);
                continue;
            }
            try out.append(p.a, ch);
        }
        return error.Invalid;
    }

    const pseudo_elements = [_][]const u8{ "before", "after", "first-line", "first-letter", "marker", "placeholder", "selection", "backdrop", "file-selector-button", "cue", "slotted", "part", "highlight", "target-text", "spelling-error", "grammar-error", "details-content" };

    fn parsePseudoElement(p: *Parser) Error!Pseudo {
        const name = try p.ident();
        var known = std.ascii.startsWithIgnoreCase(name, "-webkit-");
        for (pseudo_elements) |pe| if (std.ascii.eqlIgnoreCase(pe, name)) {
            known = true;
        };
        if (!known) return error.Invalid;
        if (p.peek() == '(') try p.skipParens();
        return .never;
    }

    /// Past a balanced `( … )`.
    fn skipParens(p: *Parser) Error!void {
        var depth: usize = 0;
        while (p.peek()) |c| {
            p.pos += 1;
            if (c == '(') depth += 1;
            if (c == ')') {
                depth -= 1;
                if (depth == 0) return;
            }
        }
        return error.Invalid;
    }

    fn parsePseudo(p: *Parser) Error!Pseudo {
        const name = try p.ident();
        const eq = std.ascii.eqlIgnoreCase;
        // The legacy single-colon pseudo-elements.
        if (eq(name, "before") or eq(name, "after") or eq(name, "first-line") or eq(name, "first-letter")) return .never;
        if (p.peek() == '(' and (eq(name, "lang"))) {
            p.pos += 1;
            p.skipWs();
            const want = try p.stringOrIdent();
            p.skipWs();
            if (p.peek() != ')') return error.Invalid;
            p.pos += 1;
            return .{ .lang = want };
        }
        if (p.peek() == '(' and (eq(name, "dir") or eq(name, "state") or eq(name, "host") or eq(name, "host-context"))) {
            try p.skipParens();
            return .never;
        }
        if (p.peek() == '(') {
            p.pos += 1;
            p.skipWs();
            var out: Pseudo = undefined;
            if (eq(name, "not")) {
                out = .{ .not = try p.parseList(false) };
            } else if (eq(name, "is") or eq(name, "matches")) {
                out = .{ .is = try p.parseList(false) };
            } else if (eq(name, "where")) {
                out = .{ .where = try p.parseList(false) };
            } else if (eq(name, "has")) {
                out = .{ .has = try p.parseList(true) };
            } else if (eq(name, "nth-child")) {
                out = .{ .nth_child = try p.parseNth() };
            } else if (eq(name, "nth-last-child")) {
                out = .{ .nth_last_child = try p.parseNth() };
            } else if (eq(name, "nth-of-type")) {
                out = .{ .nth_of_type = try p.parseNth() };
            } else if (eq(name, "nth-last-of-type")) {
                out = .{ .nth_last_of_type = try p.parseNth() };
            } else return error.Invalid;
            p.skipWs();
            if (p.peek() != ')') return error.Invalid;
            p.pos += 1;
            return out;
        }
        if (eq(name, "root")) return .root;
        if (eq(name, "empty")) return .empty;
        if (eq(name, "first-child")) return .first_child;
        if (eq(name, "last-child")) return .last_child;
        if (eq(name, "only-child")) return .only_child;
        if (eq(name, "first-of-type")) return .first_of_type;
        if (eq(name, "last-of-type")) return .last_of_type;
        if (eq(name, "only-of-type")) return .only_of_type;
        if (eq(name, "checked")) return .checked;
        if (eq(name, "disabled")) return .disabled;
        if (eq(name, "enabled")) return .enabled;
        if (eq(name, "link") or eq(name, "any-link")) return .link;
        if (eq(name, "required")) return .required;
        if (eq(name, "optional")) return .optional;
        if (eq(name, "read-write")) return .read_write;
        if (eq(name, "read-only")) return .read_only;
        if (eq(name, "placeholder-shown")) return .placeholder_shown;
        if (eq(name, "hover")) return .hover;
        if (eq(name, "active")) return .active;
        if (eq(name, "focus") or eq(name, "focus-visible")) return .focus;
        if (eq(name, "focus-within")) return .focus_within;
        // History and other states: valid, never matched here.
        const states = [_][]const u8{ "visited", "target", "target-within", "default", "indeterminate", "valid", "invalid", "in-range", "out-of-range", "user-invalid", "user-valid", "autofill", "fullscreen", "modal", "open", "closed", "popover-open", "playing", "paused", "defined", "scope", "host", "blank", "current", "past", "future", "local-link" };
        for (states) |st| if (eq(name, st)) return .never;
        return error.Invalid;
    }

    /// `An+B`, `odd`, `even`, `3`, `-n+2`, `n`.
    fn parseNth(p: *Parser) Error!Nth {
        p.skipWs();
        const start = p.pos;
        while (p.peek()) |c| : (p.pos += 1) if (c == ')') break;
        const raw = std.mem.trim(u8, p.s[start..p.pos], " \t\n\r");
        var buf: [64]u8 = undefined;
        if (raw.len > buf.len) return error.Invalid;
        var n: usize = 0;
        for (raw) |c| if (c != ' ' and c != '\t') {
            buf[n] = std.ascii.toLower(c);
            n += 1;
        };
        const t = buf[0..n];
        if (std.mem.eql(u8, t, "odd")) return .{ .a = 2, .b = 1 };
        if (std.mem.eql(u8, t, "even")) return .{ .a = 2, .b = 0 };
        const ni = std.mem.indexOfScalar(u8, t, 'n') orelse {
            return .{ .a = 0, .b = std.fmt.parseInt(i32, t, 10) catch return error.Invalid };
        };
        const a_text = t[0..ni];
        const a: i32 = if (a_text.len == 0 or std.mem.eql(u8, a_text, "+")) 1 else if (std.mem.eql(u8, a_text, "-")) -1 else std.fmt.parseInt(i32, a_text, 10) catch return error.Invalid;
        const b_text = t[ni + 1 ..];
        const b: i32 = if (b_text.len == 0) 0 else std.fmt.parseInt(i32, if (b_text[0] == '+') b_text[1..] else b_text, 10) catch return error.Invalid;
        return .{ .a = a, .b = b };
    }
};

// ------------------------------------------------------------------ tests

const html = @import("html.zig");

fn count(a: std.mem.Allocator, doc: *const Document, sel_text: []const u8) !usize {
    const sel = try Selector.parse(a, sel_text);
    var out: std.ArrayList(NodeId) = .empty;
    try sel.queryAll(doc, dom.document_id, a, &out);
    return out.items.len;
}

test "selectors: simple, attribute, structural, combinators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try html.parse(a,
        \\<!DOCTYPE html><title>t</title>
        \\<div id=main class="box big"><p class=x>one</p><p>two</p><a href="https://x.example/a.html" lang=en-US>l</a><span></span></div>
        \\<ul><li>1<li>2<li>3<li>4</ul><input type=checkbox checked disabled>
    , .{});
    try std.testing.expectEqual(@as(usize, 2), try count(a, doc, "p"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "#main"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "div.big.box"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "P.x"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "[href^='https://']"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "[href$=\".HTML\" i]"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "[lang|=en]"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "[class~=big]"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "[class=box\\ big]"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "[class=\"box big\"]"));
    // Acid2's second line: an escaped space in an attribute value, under
    // an ancestor named by two attribute selectors.
    const doc2 = try html.parse(a, "<blockquote class=\"first one\"><address class=\"second two\"></address></blockquote>", .{});
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc2, "[class~=one].first.one"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc2, "[class~=one][class~=first] address"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc2, "[class=second\\ two]"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc2, "[class~=one][class~=first] [class=second\\ two][class=\"second two\"]"));
    try std.testing.expectEqual(@as(usize, 2), try count(a, doc, "div > p"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "p + p"));
    try std.testing.expectEqual(@as(usize, 3), try count(a, doc, "p.x ~ *"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "div p:first-child"));
    try std.testing.expectEqual(@as(usize, 2), try count(a, doc, "li:nth-child(2n+1)"));
    try std.testing.expectEqual(@as(usize, 2), try count(a, doc, "li:nth-child(even)"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "li:nth-last-child(1)"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "li:last-of-type"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "span:empty"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "div :not(p):not(a)"));
    try std.testing.expectEqual(@as(usize, 3), try count(a, doc, ":is(p, a)"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "div:has(> a)"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "ul:has(li)"));
    try std.testing.expectEqual(@as(usize, 0), try count(a, doc, "p:has(li)"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "input:checked:disabled"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, ":root"));
    try std.testing.expectEqual(@as(usize, 2), try count(a, doc, "title, span"));
    try std.testing.expectError(error.Invalid, Selector.parse(a, "p >"));
    // Interaction states and pseudo-elements parse (a list holding one
    // still applies its other selectors) and match nothing; an unknown
    // pseudo-class is invalid.
    try std.testing.expectEqual(@as(usize, 0), try count(a, doc, ":hover"));
    // Hover is the document's state: the chain from the hovered element up.
    var it = doc.walk(dom.document_id);
    while (it.next()) |id| if (doc.isHtml(id, "a")) {
        doc.hovered = id;
    };
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "a:hover"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "div:hover"));
    try std.testing.expectEqual(@as(usize, 0), try count(a, doc, "p:hover"));
    doc.hovered = null;
    try std.testing.expectEqual(@as(usize, 0), try count(a, doc, "p::before"));
    try std.testing.expectEqual(@as(usize, 1), try count(a, doc, "ul, a:focus, p::after"));
    try std.testing.expectError(error.Invalid, Selector.parse(a, ":bogus"));
    try std.testing.expectError(error.Invalid, Selector.parse(a, "p::bogus"));
    const sp = try Selector.parse(a, "#a .b.c p:first-child, :where(#x) span, :is(#y, .z)");
    try std.testing.expectEqual(@as(u32, (1 << 20) | (3 << 10) | 1), specificity(sp.list[0]));
    try std.testing.expectEqual(@as(u32, 1), specificity(sp.list[1]));
    try std.testing.expectEqual(@as(u32, 1 << 20), specificity(sp.list[2]));
}
