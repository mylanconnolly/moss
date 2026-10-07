//! Regular expressions (ECMA-262 §22.2): the pattern grammar parsed
//! into a tree, compiled to a small instruction set, and matched by a
//! backtracking machine over UTF-16 code units (code points under the
//! `u` and `v` flags) with an explicit backtrack stack — no recursion
//! grows with the input — and a step budget so a pathological pattern
//! is a RangeError, not a hang. Semantics follow the specification's
//! matcher: greedy and lazy quantifiers, the empty-iteration check,
//! captures cleared per iteration, lookahead and lookbehind (the latter
//! matched backwards), backreferences by number and name, Annex B's
//! tolerant syntax in non-unicode mode.
const std = @import("std");
const strings = @import("builtins/string.zig");
const unicode = @import("unicode.zig");

pub const Error = error{ OutOfMemory, SyntaxError };

pub const Flags = packed struct(u8) {
    global: bool = false,
    ignore_case: bool = false,
    multiline: bool = false,
    dot_all: bool = false,
    unicode: bool = false,
    unicode_sets: bool = false,
    sticky: bool = false,
    has_indices: bool = false,

    /// Parse a flags string; null when a flag repeats or is unknown.
    pub fn parse(s: []const u16) ?Flags {
        var f: Flags = .{};
        for (s) |c| {
            switch (c) {
                'g' => if (f.global) return null else {
                    f.global = true;
                },
                'i' => if (f.ignore_case) return null else {
                    f.ignore_case = true;
                },
                'm' => if (f.multiline) return null else {
                    f.multiline = true;
                },
                's' => if (f.dot_all) return null else {
                    f.dot_all = true;
                },
                'u' => if (f.unicode) return null else {
                    f.unicode = true;
                },
                'v' => if (f.unicode_sets) return null else {
                    f.unicode_sets = true;
                },
                'y' => if (f.sticky) return null else {
                    f.sticky = true;
                },
                'd' => if (f.has_indices) return null else {
                    f.has_indices = true;
                },
                else => return null,
            }
        }
        if (f.unicode and f.unicode_sets) return null;
        return f;
    }

    pub fn unicodeMode(f: Flags) bool {
        return f.unicode or f.unicode_sets;
    }
};

pub const Range = struct { lo: u21, hi: u21 };

/// A character class as sorted, merged ranges.
pub const Class = struct {
    ranges: []Range,
    negate: bool,
    /// The case rule in force where the class was written: a
    /// `(?i:...)` modifier scopes it, so the program's flag cannot say.
    ignore_case: bool = false,
};

// ----------------------------------------------------------------- AST

const Node = union(enum) {
    empty,
    char: u21,
    any,
    class: Class,
    seq: []*Node,
    alt: []*Node,
    group: struct { index: ?u32, body: *Node },
    backref: u32,
    named_backref: []const u16,
    assert_start,
    assert_end,
    word_boundary: bool, // true: \b, false: \B
    look: struct { ahead: bool, negate: bool, body: *Node, caps_from: u32, caps_to: u32 },
    repeat: struct { min: u32, max: ?u32, greedy: bool, body: *Node, caps_from: u32, caps_to: u32 },
    /// `(?ims-ims:body)` (ES2025): the flags in force inside.
    modifiers: struct { flags: Flags, body: *Node },
};

/// A named group; `path` is where it sits in the pattern's alternations
/// (each enclosing disjunction and the alternative taken), so two groups
/// of one name are allowed when some disjunction keeps them apart —
/// duplicate named groups, ES2025.
pub const GroupName = struct { name: []const u16, index: u32, path: []const AltStep = &.{} };
pub const AltStep = struct { disjunction: u32, alternative: u32 };

/// Two groups may share a name when they can never both participate:
/// at some disjunction they lie in different alternatives.
fn pathsDistinct(a: []const AltStep, b: []const AltStep) bool {
    const n = @min(a.len, b.len);
    for (a[0..n], b[0..n]) |x, y| {
        if (x.disjunction != y.disjunction) return false;
        if (x.alternative != y.alternative) return true;
    }
    return false;
}

// -------------------------------------------------------------- parser

const Parser = struct {
    a: std.mem.Allocator,
    src: []const u16,
    pos: usize = 0,
    flags: Flags,
    unicode: bool,
    ncaps: u32 = 1, // capture 0 is the whole match
    names: std.ArrayList(GroupName) = .empty,
    /// Named backreferences are resolved after the parse.
    has_named_groups: bool,
    err: []const u8 = "",
    /// Backreference numbers seen, checked against the group count.
    max_backref: u32 = 0,
    /// The group count from the pre-scan (Annex B decides `\N` by it).
    total_groups: u32 = 0,
    /// The alternation path of the term being parsed (`GroupName.path`).
    alt_path: std.ArrayList(AltStep) = .empty,
    next_disjunction: u32 = 0,

    fn fail(p: *Parser, msg: []const u8) Error {
        if (p.err.len == 0) p.err = msg;
        return error.SyntaxError;
    }

    fn peek(p: *Parser) ?u16 {
        return if (p.pos < p.src.len) p.src[p.pos] else null;
    }
    fn peekAt(p: *Parser, off: usize) ?u16 {
        return if (p.pos + off < p.src.len) p.src[p.pos + off] else null;
    }
    fn eat(p: *Parser, c: u16) bool {
        if (p.peek() == c) {
            p.pos += 1;
            return true;
        }
        return false;
    }

    /// The next pattern character as a code point (a surrogate pair is
    /// one character in unicode mode).
    fn nextCp(p: *Parser) ?u21 {
        const c = p.peek() orelse return null;
        p.pos += 1;
        if (p.unicode and c >= 0xd800 and c <= 0xdbff) {
            if (p.peek()) |lo| if (lo >= 0xdc00 and lo <= 0xdfff) {
                p.pos += 1;
                return 0x10000 + ((@as(u21, c) - 0xd800) << 10) + (lo - 0xdc00);
            };
        }
        return c;
    }

    fn node(p: *Parser, data: Node) Error!*Node {
        const n = try p.a.create(Node);
        n.* = data;
        return n;
    }

    fn parseDisjunction(p: *Parser) Error!*Node {
        var alts: std.ArrayList(*Node) = .empty;
        const id = p.next_disjunction;
        p.next_disjunction += 1;
        try p.alt_path.append(p.a, .{ .disjunction = id, .alternative = 0 });
        defer _ = p.alt_path.pop();
        try alts.append(p.a, try p.parseAlternative());
        while (p.eat('|')) {
            p.alt_path.items[p.alt_path.items.len - 1].alternative += 1;
            try alts.append(p.a, try p.parseAlternative());
        }
        if (alts.items.len == 1) return alts.items[0];
        return p.node(.{ .alt = alts.items });
    }

    fn parseAlternative(p: *Parser) Error!*Node {
        var terms: std.ArrayList(*Node) = .empty;
        while (p.peek()) |c| {
            if (c == '|' or c == ')') break;
            try terms.append(p.a, try p.parseTerm());
        }
        if (terms.items.len == 1) return terms.items[0];
        if (terms.items.len == 0) return p.node(.empty);
        return p.node(.{ .seq = terms.items });
    }

    fn parseTerm(p: *Parser) Error!*Node {
        const c = p.peek().?;
        const caps_before = p.ncaps;
        var atom: *Node = undefined;
        var quantifiable = true;
        switch (c) {
            '^' => {
                p.pos += 1;
                return p.node(.assert_start);
            },
            '$' => {
                p.pos += 1;
                return p.node(.assert_end);
            },
            '\\' => {
                if (p.peekAt(1) == 'b') {
                    p.pos += 2;
                    return p.node(.{ .word_boundary = true });
                }
                if (p.peekAt(1) == 'B') {
                    p.pos += 2;
                    return p.node(.{ .word_boundary = false });
                }
                atom = try p.parseAtomEscape();
            },
            '(' => {
                p.pos += 1;
                if (p.eat('?')) {
                    const k = p.peek() orelse return p.fail("unterminated group");
                    switch (k) {
                        ':' => {
                            p.pos += 1;
                            const body = try p.parseDisjunction();
                            if (!p.eat(')')) return p.fail("unterminated group");
                            atom = try p.node(.{ .group = .{ .index = null, .body = body } });
                        },
                        '=', '!' => {
                            p.pos += 1;
                            const body = try p.parseDisjunction();
                            if (!p.eat(')')) return p.fail("unterminated group");
                            atom = try p.node(.{ .look = .{ .ahead = true, .negate = k == '!', .body = body, .caps_from = caps_before, .caps_to = p.ncaps } });
                            // Annex B: lookaheads are quantifiable in non-unicode mode.
                            quantifiable = !p.unicode;
                        },
                        '<' => {
                            if (p.peekAt(1) == '=' or p.peekAt(1) == '!') {
                                const neg = p.peekAt(1) == '!';
                                p.pos += 2;
                                const body = try p.parseDisjunction();
                                if (!p.eat(')')) return p.fail("unterminated group");
                                atom = try p.node(.{ .look = .{ .ahead = false, .negate = neg, .body = body, .caps_from = caps_before, .caps_to = p.ncaps } });
                                quantifiable = false;
                            } else {
                                p.pos += 1;
                                const name = try p.parseGroupName();
                                const path = try p.a.dupe(AltStep, p.alt_path.items);
                                for (p.names.items) |g| if (std.mem.eql(u16, g.name, name) and !pathsDistinct(g.path, path)) return p.fail("duplicate capture group name");
                                const index = p.ncaps;
                                p.ncaps += 1;
                                try p.names.append(p.a, .{ .name = name, .index = index, .path = path });
                                const body = try p.parseDisjunction();
                                if (!p.eat(')')) return p.fail("unterminated group");
                                atom = try p.node(.{ .group = .{ .index = index, .body = body } });
                            }
                        },
                        'i', 'm', 's', '-' => {
                            const inner = try p.parseModifiers();
                            const saved = p.flags;
                            p.flags = inner;
                            const body = try p.parseDisjunction();
                            p.flags = saved;
                            if (!p.eat(')')) return p.fail("unterminated group");
                            atom = try p.node(.{ .modifiers = .{ .flags = inner, .body = body } });
                        },
                        else => return p.fail("invalid group"),
                    }
                } else {
                    const index = p.ncaps;
                    p.ncaps += 1;
                    const body = try p.parseDisjunction();
                    if (!p.eat(')')) return p.fail("unterminated group");
                    atom = try p.node(.{ .group = .{ .index = index, .body = body } });
                }
            },
            ')' => return p.fail("unmatched ')'"),
            '.' => {
                p.pos += 1;
                atom = try p.node(.any);
            },
            '[' => atom = try p.parseClass(),
            '*', '+', '?' => return p.fail("nothing to repeat"),
            '{' => {
                if (p.unicode) return p.fail("nothing to repeat");
                // Annex B: a `{` that does not start a quantifier is literal.
                if (p.looksLikeQuantifier()) return p.fail("nothing to repeat");
                p.pos += 1;
                atom = try p.node(.{ .char = '{' });
            },
            '}', ']' => {
                if (p.unicode) return p.fail("lone quantifier bracket");
                p.pos += 1;
                atom = try p.node(.{ .char = c });
            },
            else => {
                const cp = p.nextCp().?;
                atom = try p.node(.{ .char = cp });
            },
        }
        return p.parseQuantifier(atom, quantifiable, caps_before);
    }

    fn looksLikeQuantifier(p: *Parser) bool {
        // `{` digits [`,` [digits]] `}`
        var i = p.pos + 1;
        var digits: usize = 0;
        while (i < p.src.len and p.src[i] >= '0' and p.src[i] <= '9') : (i += 1) digits += 1;
        if (digits == 0) return false;
        if (i < p.src.len and p.src[i] == '}') return true;
        if (i < p.src.len and p.src[i] == ',') {
            i += 1;
            while (i < p.src.len and p.src[i] >= '0' and p.src[i] <= '9') : (i += 1) {}
            return i < p.src.len and p.src[i] == '}';
        }
        return false;
    }

    fn parseDecimal(p: *Parser) ?u32 {
        var v: u64 = 0;
        var n: usize = 0;
        while (p.peek()) |c| : (p.pos += 1) {
            if (c < '0' or c > '9') break;
            v = @min(v * 10 + (c - '0'), 0xFFFF_FFFF);
            n += 1;
        }
        if (n == 0) return null;
        return @intCast(v);
    }

    fn parseQuantifier(p: *Parser, atom: *Node, quantifiable: bool, caps_from: u32) Error!*Node {
        const c = p.peek() orelse return atom;
        var min: u32 = 0;
        var max: ?u32 = null;
        switch (c) {
            '*' => {
                p.pos += 1;
            },
            '+' => {
                p.pos += 1;
                min = 1;
            },
            '?' => {
                p.pos += 1;
                max = 1;
            },
            '{' => {
                if (!p.looksLikeQuantifier()) {
                    if (p.unicode) return p.fail("incomplete quantifier");
                    return atom;
                }
                p.pos += 1;
                min = p.parseDecimal().?;
                if (p.eat(',')) {
                    max = p.parseDecimal(); // null: unbounded
                } else max = min;
                if (!p.eat('}')) return p.fail("incomplete quantifier");
                if (max) |m| if (m < min) return p.fail("numbers out of order in quantifier");
            },
            else => return atom,
        }
        if (!quantifiable) return p.fail("nothing to repeat");
        const greedy = !p.eat('?');
        return p.node(.{ .repeat = .{ .min = min, .max = max, .greedy = greedy, .body = atom, .caps_from = caps_from, .caps_to = p.ncaps } });
    }

    /// `(?ims-ims:` (§22.2.1 RegularExpressionModifiers): the flags in
    /// force inside the group. Each of i, m, s at most once, never both
    /// added and removed, and the two sets not both empty (`(?:` is the
    /// plain group).
    fn parseModifiers(p: *Parser) Error!Flags {
        var add: u8 = 0;
        var remove: u8 = 0;
        add = try p.parseModifierSet(0);
        if (p.eat('-')) {
            remove = try p.parseModifierSet(add);
            if (add == 0 and remove == 0) return p.fail("empty modifiers");
        }
        if (!p.eat(':')) return p.fail("invalid group");
        var f = p.flags;
        if (add & 1 != 0) f.ignore_case = true;
        if (add & 2 != 0) f.multiline = true;
        if (add & 4 != 0) f.dot_all = true;
        if (remove & 1 != 0) f.ignore_case = false;
        if (remove & 2 != 0) f.multiline = false;
        if (remove & 4 != 0) f.dot_all = false;
        return f;
    }

    /// One modifier set as bits (i=1, m=2, s=4); `other` is the set it
    /// may not share a flag with.
    fn parseModifierSet(p: *Parser, other: u8) Error!u8 {
        var set: u8 = 0;
        while (p.peek()) |c| {
            const bit: u8 = switch (c) {
                'i' => 1,
                'm' => 2,
                's' => 4,
                else => 0,
            };
            if (bit == 0) break;
            if (set & bit != 0) return p.fail("repeated modifier");
            if (other & bit != 0) return p.fail("modifier both added and removed");
            set |= bit;
            p.pos += 1;
        }
        return set;
    }

    fn parseGroupName(p: *Parser) Error![]const u16 {
        // After `<`: RegExpIdentifierName `>`.
        var name: std.ArrayList(u16) = .empty;
        var first = true;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated group name");
            if (c == '>') {
                p.pos += 1;
                break;
            }
            var cp: u21 = undefined;
            if (c == '\\') {
                p.pos += 1;
                if (!p.eat('u')) return p.fail("invalid group name");
                cp = try p.parseUnicodeEscapeBody(true);
            } else {
                // Surrogate pairs are one character in a name in every mode.
                cp = c;
                p.pos += 1;
                if (c >= 0xd800 and c <= 0xdbff) if (p.peek()) |lo| if (lo >= 0xdc00 and lo <= 0xdfff) {
                    p.pos += 1;
                    cp = 0x10000 + ((@as(u21, c) - 0xd800) << 10) + (lo - 0xdc00);
                };
            }
            const ok = if (first) isIdStart(cp) else isIdContinue(cp);
            if (!ok) return p.fail("invalid group name");
            first = false;
            try appendCp(&name, p.a, cp);
        }
        if (name.items.len == 0) return p.fail("empty group name");
        return name.items;
    }

    /// `u` escapes: `\uXXXX`, `\u{...}` (unicode mode), surrogate pairs
    /// written as two `\u` escapes (unicode mode) — after the `u`.
    fn parseUnicodeEscapeBody(p: *Parser, force_unicode: bool) Error!u21 {
        const uni = p.unicode or force_unicode;
        if (uni and p.eat('{')) {
            var v: u32 = 0;
            var n: usize = 0;
            while (p.peek()) |c| : (p.pos += 1) {
                if (c == '}') break;
                const d = hexDigit(c) orelse return p.fail("invalid unicode escape");
                v = v * 16 + d;
                if (v > 0x10FFFF) return p.fail("invalid unicode escape");
                n += 1;
            }
            if (n == 0 or !p.eat('}')) return p.fail("invalid unicode escape");
            return @intCast(v);
        }
        var v: u32 = 0;
        var i: usize = 0;
        while (i < 4) : (i += 1) {
            const c = p.peek() orelse return p.fail("invalid unicode escape");
            const d = hexDigit(c) orelse return p.fail("invalid unicode escape");
            v = v * 16 + d;
            p.pos += 1;
        }
        if (uni and v >= 0xd800 and v <= 0xdbff and p.peek() == '\\' and p.peekAt(1) == 'u') {
            // A trailing surrogate escape joins the pair.
            const save = p.pos;
            p.pos += 2;
            var lo: u32 = 0;
            var ok = true;
            var j: usize = 0;
            while (j < 4) : (j += 1) {
                const c = p.peek() orelse {
                    ok = false;
                    break;
                };
                const d = hexDigit(c) orelse {
                    ok = false;
                    break;
                };
                lo = lo * 16 + d;
                p.pos += 1;
            }
            if (ok and lo >= 0xdc00 and lo <= 0xdfff) return @intCast(0x10000 + ((v - 0xd800) << 10) + (lo - 0xdc00));
            p.pos = save;
        }
        return @intCast(v);
    }

    /// An escape after `\` outside a class: a character, a class escape,
    /// or a backreference.
    fn parseAtomEscape(p: *Parser) Error!*Node {
        p.pos += 1; // the backslash
        const c = p.peek() orelse return p.fail("\\ at end of pattern");
        switch (c) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.pos += 1;
                return p.node(.{ .class = try p.classEscape(c) });
            },
            'p', 'P' => {
                if (p.flags.unicode_sets) {
                    p.pos += 1;
                    return p.classSetNode(try p.parsePropertyEscapeSet(c == 'P'));
                }
                if (p.unicode) {
                    p.pos += 1;
                    var cls = try p.parsePropertyEscape(c == 'P');
                    // Under `i` the matcher checks a character and its
                    // canonical form against the set, so the set must hold
                    // every case variant. `\P` is the complement of the
                    // plain set in `u` mode (so `A` matches `\P{Lu}`
                    // through `a`) and of the folded set in `v` mode
                    // (MaybeSimpleCaseFolding, §22.2.2.9.1).
                    if (cls.negate) {
                        const base = if (p.flags.ignore_case and p.flags.unicode_sets) try p.foldRanges(cls.ranges) else cls.ranges;
                        cls = .{ .ranges = try invertRanges(p.a, base), .negate = false };
                    } else if (p.flags.ignore_case) cls.ranges = try p.foldRanges(cls.ranges);
                    return p.node(.{ .class = cls });
                }
                p.pos += 1;
                return p.node(.{ .char = c });
            },
            'k' => {
                if (p.unicode or p.has_named_groups) {
                    p.pos += 1;
                    if (!p.eat('<')) return p.fail("invalid named reference");
                    const name = try p.parseGroupName();
                    return p.node(.{ .named_backref = name });
                }
                p.pos += 1;
                return p.node(.{ .char = 'k' });
            },
            '1'...'9' => {
                // A backreference, unless (Annex B) it exceeds the group
                // count, when it is a legacy octal escape or identity.
                const save = p.pos;
                const n = p.parseDecimal().?;
                if (p.unicode) {
                    if (n > p.max_backref) p.max_backref = n;
                    return p.node(.{ .backref = n });
                }
                // Non-unicode: decided after the parse (group count known
                // only then); record the largest and re-parse if needed.
                p.pos = save;
                return p.parseLegacyBackrefOrOctal();
            },
            else => {
                const cp = try p.parseCharacterEscape();
                return p.node(.{ .char = cp });
            },
        }
    }

    /// Non-unicode `\N`: a backreference when N ≤ the total group count
    /// (counted in a pre-scan), else legacy octal / identity.
    fn parseLegacyBackrefOrOctal(p: *Parser) Error!*Node {
        const save = p.pos;
        const n = p.parseDecimal().?;
        if (n <= p.total_groups) return p.node(.{ .backref = n });
        p.pos = save;
        const c = p.peek().?;
        if (c == '8' or c == '9') {
            p.pos += 1;
            return p.node(.{ .char = c });
        }
        return p.node(.{ .char = p.parseLegacyOctal() });
    }

    /// Up to three octal digits, value ≤ 255.
    fn parseLegacyOctal(p: *Parser) u21 {
        var v: u21 = 0;
        var n: usize = 0;
        while (p.peek()) |c| {
            if (c < '0' or c > '7') break;
            if (n == 2 and v > 3) break;
            v = v * 8 + (c - '0');
            p.pos += 1;
            n += 1;
            if (n == 3) break;
        }
        return v;
    }

    /// CharacterEscape (§22.2.1): after the backslash, `c` being the
    /// current character.
    fn parseCharacterEscape(p: *Parser) Error!u21 {
        const c = p.peek() orelse return p.fail("\\ at end of pattern");
        p.pos += 1;
        switch (c) {
            'f' => return 0x0c,
            'n' => return '\n',
            'r' => return '\r',
            't' => return '\t',
            'v' => return 0x0b,
            'c' => {
                if (p.peek()) |l| if ((l >= 'a' and l <= 'z') or (l >= 'A' and l <= 'Z')) {
                    p.pos += 1;
                    return @intCast(l % 32);
                };
                if (p.unicode) return p.fail("invalid control escape");
                // Annex B: `\c` followed by a non-letter is a literal backslash.
                p.pos -= 1;
                return '\\';
            },
            '0' => {
                if (p.peek()) |d| if (d >= '0' and d <= '9') {
                    if (p.unicode) return p.fail("invalid decimal escape");
                    p.pos -= 1;
                    return p.parseLegacyOctal();
                };
                return 0;
            },
            'x' => {
                if (p.peek()) |h1| if (hexDigit(h1)) |d1| if (p.peekAt(1)) |h2| if (hexDigit(h2)) |d2| {
                    p.pos += 2;
                    return @intCast(d1 * 16 + d2);
                };
                if (p.unicode) return p.fail("invalid hex escape");
                return 'x';
            },
            'u' => {
                const save = p.pos;
                return p.parseUnicodeEscapeBody(false) catch |e| {
                    if (p.unicode) return e;
                    p.err = "";
                    p.pos = save;
                    return 'u';
                };
            },
            else => {
                if (p.unicode) {
                    // Only syntax characters and `/` may be escaped.
                    if (isSyntaxChar(c) or c == '/') return c;
                    return p.fail("invalid escape");
                }
                if (c >= 0xd800 and c <= 0xdbff) {
                    // A lone surrogate escape stays a unit.
                }
                return c;
            },
        }
    }

    fn classEscape(p: *Parser, c: u16) Error!Class {
        _ = p;
        return switch (c) {
            'd' => .{ .ranges = @constCast(&digit_ranges), .negate = false },
            'D' => .{ .ranges = @constCast(&digit_ranges), .negate = true },
            's' => .{ .ranges = @constCast(&space_ranges), .negate = false },
            'S' => .{ .ranges = @constCast(&space_ranges), .negate = true },
            'w' => .{ .ranges = @constCast(&word_ranges), .negate = false },
            'W' => .{ .ranges = @constCast(&word_ranges), .negate = true },
            else => unreachable,
        };
    }

    /// `\p{...}` / `\P{...}`: the properties the engine knows.
    fn parsePropertyEscape(p: *Parser, negate: bool) Error!Class {
        if (!p.eat('{')) return p.fail("invalid property name");
        var name: std.ArrayList(u8) = .empty;
        var value: std.ArrayList(u8) = .empty;
        var in_value = false;
        while (true) {
            const c = p.peek() orelse return p.fail("invalid property name");
            p.pos += 1;
            if (c == '}') break;
            if (c == '=') {
                if (in_value) return p.fail("invalid property name");
                in_value = true;
                continue;
            }
            if (c > 127) return p.fail("invalid property name");
            try (if (in_value) &value else &name).append(p.a, @intCast(c));
        }
        // A lone value name may only be a binary property or a general
        // category; `Script=` needs its key. A property of strings needs
        // the `v` flag.
        if (!in_value and unicode.stringProperty(name.items) != null) return p.fail("a property of strings needs the v flag");
        const ranges = (try unicodeProperty(p.a, name.items, if (in_value) value.items else null)) orelse return p.fail("invalid property name");
        return .{ .ranges = ranges, .negate = negate };
    }

    /// `[...]` (§22.2.2.9); the `v` flag's class sets are their own
    /// grammar (`parseClassV`).
    fn parseClass(p: *Parser) Error!*Node {
        p.pos += 1; // [
        if (p.flags.unicode_sets) return p.parseClassV();
        const negate = p.eat('^');
        var set = try p.parseClassContents();
        if (!p.eat(']')) return p.fail("unterminated character class");
        if (p.flags.ignore_case) set = try p.foldRanges(set);
        return p.node(.{ .class = .{ .ranges = set, .negate = negate } });
    }

    /// The ranges of a class body up to its `]`.
    fn parseClassContents(p: *Parser) Error![]Range {
        var out: std.ArrayList(Range) = .empty;
        var op: enum { none, intersect, subtract } = .none;
        var first_operand = true;
        var last_was_class = false;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated character class");
            if (c == ']') break;
            // v-mode set operations.
            if (p.flags.unicode_sets and c == '&' and p.peekAt(1) == '&') {
                p.pos += 2;
                op = .intersect;
                continue;
            }
            if (p.flags.unicode_sets and c == '-' and p.peekAt(1) == '-') {
                p.pos += 2;
                op = .subtract;
                continue;
            }
            var operand: []Range = undefined;
            // In unicode mode a class escape cannot be a range endpoint.
            if (p.unicode and c == '-' and !first_operand and last_was_class and p.peekAt(1) != ']') return p.fail("invalid character class range");
            last_was_class = false;
            if (p.flags.unicode_sets and c == '[') {
                p.pos += 1;
                const neg = p.eat('^');
                var inner = try p.parseClassContents();
                if (!p.eat(']')) return p.fail("unterminated character class");
                if (neg) inner = try invertRanges(p.a, inner);
                operand = inner;
            } else {
                const atom = try p.parseClassAtom();
                switch (atom) {
                    .class => |cl| {
                        operand = if (cl.negate) try invertRanges(p.a, cl.ranges) else cl.ranges;
                        last_was_class = true;
                    },
                    .char => |lo| {
                        var hi = lo;
                        // A range `a-b`.
                        if (p.peek() == '-' and p.peekAt(1) != ']' and p.peekAt(1) != null and !(p.flags.unicode_sets and p.peekAt(1) == '-')) {
                            p.pos += 1;
                            const hi_atom = try p.parseClassAtom();
                            switch (hi_atom) {
                                .char => |h| hi = h,
                                .class => |cl2| {
                                    if (p.unicode) return p.fail("invalid character class range");
                                    // Annex B: `a-\d` is the union of a, '-', \d.
                                    var tmp: std.ArrayList(Range) = .empty;
                                    try tmp.append(p.a, .{ .lo = lo, .hi = lo });
                                    try tmp.append(p.a, .{ .lo = '-', .hi = '-' });
                                    try tmp.appendSlice(p.a, if (cl2.negate) try invertRanges(p.a, cl2.ranges) else cl2.ranges);
                                    operand = try mergeRanges(p.a, tmp.items);
                                    try out.appendSlice(p.a, operand);
                                    continue;
                                },
                            }
                            if (hi < lo) return p.fail("range out of order in character class");
                        }
                        const one = try p.a.alloc(Range, 1);
                        one[0] = .{ .lo = lo, .hi = hi };
                        operand = one;
                    },
                }
            }
            switch (op) {
                .none => try out.appendSlice(p.a, operand),
                .intersect => {
                    const merged = try mergeRanges(p.a, out.items);
                    out = .empty;
                    try out.appendSlice(p.a, try intersectRanges(p.a, merged, try mergeRanges(p.a, operand)));
                },
                .subtract => {
                    const merged = try mergeRanges(p.a, out.items);
                    out = .empty;
                    try out.appendSlice(p.a, try intersectRanges(p.a, merged, try invertRanges(p.a, try mergeRanges(p.a, operand))));
                },
            }
            first_operand = false;
        }
        return mergeRanges(p.a, out.items);
    }

    // ------------------------------------------------- v-mode classes

    /// A `v`-mode class set: code points as ranges, and the strings of
    /// other lengths (`\q{}` literals, properties of strings).
    const ClassSet = struct { ranges: []Range, strings: []const []const u21 };

    /// `[...]` under the `v` flag (§22.2.2.9.1 ClassSetExpression): a
    /// union, an intersection (`&&`) or a subtraction (`--`) of operands —
    /// never mixed — where an operand may be a nested class, a `\q{}`
    /// string disjunction or a property of strings. A negated class may
    /// hold no strings.
    fn parseClassV(p: *Parser) Error!*Node {
        const negate = p.eat('^');
        const set = try p.parseClassSetContents();
        if (!p.eat(']')) return p.fail("unterminated character class");
        if (negate) {
            if (set.strings.len > 0) return p.fail("negated character class may contain strings");
            const base = if (p.flags.ignore_case) try p.foldRanges(set.ranges) else set.ranges;
            return p.node(.{ .class = .{ .ranges = try invertRanges(p.a, base), .negate = false } });
        }
        return p.classSetNode(set);
    }

    /// The node for a class set: a class of its code points, or — with
    /// strings — the alternation the specification prescribes: longest
    /// strings first, then the code points, the empty string last.
    fn classSetNode(p: *Parser, set: ClassSet) Error!*Node {
        const ranges = if (p.flags.ignore_case) try p.foldRanges(set.ranges) else set.ranges;
        if (set.strings.len == 0) return p.node(.{ .class = .{ .ranges = ranges, .negate = false } });
        const sorted = try p.a.dupe([]const u21, set.strings);
        std.mem.sort([]const u21, sorted, {}, struct {
            fn longer(_: void, x: []const u21, y: []const u21) bool {
                return x.len > y.len;
            }
        }.longer);
        var alts: std.ArrayList(*Node) = .empty;
        var has_empty = false;
        for (sorted) |s| {
            if (s.len == 0) {
                has_empty = true;
                continue;
            }
            var items: std.ArrayList(*Node) = .empty;
            for (s) |ch| try items.append(p.a, try p.node(.{ .char = ch }));
            try alts.append(p.a, try p.node(.{ .seq = items.items }));
        }
        if (ranges.len > 0) try alts.append(p.a, try p.node(.{ .class = .{ .ranges = ranges, .negate = false } }));
        if (has_empty) try alts.append(p.a, try p.node(.empty));
        if (alts.items.len == 1) return alts.items[0];
        return p.node(.{ .alt = alts.items });
    }

    const SetOp = enum { none, intersect, subtract };

    fn parseClassSetContents(p: *Parser) Error!ClassSet {
        var acc: ClassSet = .{ .ranges = &.{}, .strings = &.{} };
        var op: SetOp = .none;
        var operands: usize = 0;
        var after_op = false;
        var last_range = false;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated character class");
            if (c == ']') break;
            const is_and = c == '&' and p.peekAt(1) == '&';
            const is_minus = c == '-' and p.peekAt(1) == '-';
            if (is_and or is_minus) {
                const this_op: SetOp = if (is_and) .intersect else .subtract;
                if (operands == 0 or after_op) return p.fail("set operation without an operand");
                if (op == .none and operands > 1) return p.fail("set operation after a class union");
                if (last_range) return p.fail("a range cannot be a set operand");
                if (op != .none and op != this_op) return p.fail("mixed set operations in a character class");
                op = this_op;
                after_op = true;
                p.pos += 2;
                continue;
            }
            var is_range = false;
            const operand = try p.parseClassSetOperand(&is_range);
            if (op != .none) {
                if (!after_op) return p.fail("set operation after a class union");
                if (is_range) return p.fail("a range cannot be a set operand");
            }
            acc = switch (op) {
                .none => try p.unionSets(acc, operand),
                .intersect => try p.intersectSets(acc, operand),
                .subtract => try p.subtractSets(acc, operand),
            };
            operands += 1;
            after_op = false;
            last_range = is_range;
        }
        if (after_op) return p.fail("set operation without an operand");
        return acc;
    }

    /// One ClassSetOperand (or a ClassSetRange, flagged): a nested
    /// class, a class escape, a property escape, a string disjunction,
    /// or a character.
    fn parseClassSetOperand(p: *Parser, is_range: *bool) Error!ClassSet {
        const c = p.peek().?;
        if (c == '[') {
            p.pos += 1;
            const negate = p.eat('^');
            var inner = try p.parseClassSetContents();
            if (!p.eat(']')) return p.fail("unterminated character class");
            if (negate) {
                if (inner.strings.len > 0) return p.fail("negated character class may contain strings");
                const base = if (p.flags.ignore_case) try p.foldRanges(inner.ranges) else inner.ranges;
                inner = .{ .ranges = try invertRanges(p.a, base), .strings = &.{} };
            }
            return inner;
        }
        if (c == '\\') {
            switch (p.peekAt(1) orelse return p.fail("\\ at end of pattern")) {
                'q' => {
                    p.pos += 2;
                    return p.parseClassStringDisjunction();
                },
                'p', 'P' => {
                    const negate = p.peekAt(1) == 'P';
                    p.pos += 2;
                    return p.parsePropertyEscapeSet(negate);
                },
                'd', 'D', 's', 'S', 'w', 'W' => {
                    const e: u16 = @intCast(p.peekAt(1).?);
                    p.pos += 2;
                    const cl = try p.classEscape(e);
                    return .{ .ranges = if (cl.negate) try invertRanges(p.a, cl.ranges) else cl.ranges, .strings = &.{} };
                },
                else => {},
            }
        }
        const lo = try p.parseClassSetCharacter();
        var hi = lo;
        if (p.peek() == '-' and p.peekAt(1) != '-') {
            p.pos += 1;
            hi = try p.parseClassSetCharacter();
            if (hi < lo) return p.fail("range out of order in character class");
            is_range.* = true;
        }
        const one = try p.a.alloc(Range, 1);
        one[0] = .{ .lo = lo, .hi = hi };
        return .{ .ranges = one, .strings = &.{} };
    }

    /// `\q{a|bc|}`: each alternative a string; one of length one is a
    /// code point of the set.
    fn parseClassStringDisjunction(p: *Parser) Error!ClassSet {
        if (!p.eat('{')) return p.fail("expected '{' after \\q");
        var ranges: std.ArrayList(Range) = .empty;
        var strs: std.ArrayList([]const u21) = .empty;
        var cur: std.ArrayList(u21) = .empty;
        while (true) {
            const c = p.peek() orelse return p.fail("unterminated \\q{}");
            if (c == '|' or c == '}') {
                if (cur.items.len == 1) {
                    try ranges.append(p.a, .{ .lo = cur.items[0], .hi = cur.items[0] });
                } else try strs.append(p.a, try p.a.dupe(u21, cur.items));
                cur = .empty;
                p.pos += 1;
                if (c == '}') break;
                continue;
            }
            try cur.append(p.a, try p.parseClassSetCharacter());
        }
        return .{ .ranges = try mergeRanges(p.a, ranges.items), .strings = try dedupeStrings(p.a, strs.items) };
    }

    /// `\p{...}` in `v` mode: a property of strings (never negated) or a
    /// code point property.
    fn parsePropertyEscapeSet(p: *Parser, negate: bool) Error!ClassSet {
        if (!p.eat('{')) return p.fail("invalid property name");
        var name: std.ArrayList(u8) = .empty;
        var value: std.ArrayList(u8) = .empty;
        var in_value = false;
        while (true) {
            const c = p.peek() orelse return p.fail("invalid property name");
            p.pos += 1;
            if (c == '}') break;
            if (c == '=') {
                if (in_value) return p.fail("invalid property name");
                in_value = true;
                continue;
            }
            if (c > 127) return p.fail("invalid property name");
            try (if (in_value) &value else &name).append(p.a, @intCast(c));
        }
        if (!in_value) if (unicode.stringProperty(name.items)) |sp| {
            if (negate) return p.fail("a property of strings cannot be negated");
            const ranges = try p.a.alloc(Range, sp.ranges.len);
            for (sp.ranges, 0..) |r, i| ranges[i] = .{ .lo = @intCast(r.lo), .hi = @intCast(r.hi) };
            var strs: std.ArrayList([]const u21) = .empty;
            var it = sp.strings();
            while (it.next()) |s| {
                const copy = try p.a.alloc(u21, s.len);
                for (s, 0..) |cp, i| copy[i] = @intCast(cp);
                try strs.append(p.a, copy);
            }
            return .{ .ranges = ranges, .strings = strs.items };
        };
        const ranges = (try unicodeProperty(p.a, name.items, if (in_value) value.items else null)) orelse return p.fail("invalid property name");
        if (negate) {
            const base = if (p.flags.ignore_case) try p.foldRanges(ranges) else ranges;
            return .{ .ranges = try invertRanges(p.a, base), .strings = &.{} };
        }
        return .{ .ranges = ranges, .strings = &.{} };
    }

    /// A ClassSetCharacter: no unescaped syntax character, no doubled
    /// punctuator (reserved for operators); the reserved punctuators
    /// may be escaped.
    fn parseClassSetCharacter(p: *Parser) Error!u21 {
        const c = p.peek() orelse return p.fail("unterminated character class");
        if (c == '\\') {
            const e = p.peekAt(1) orelse return p.fail("\\ at end of pattern");
            if (isClassSetReservedPunctuator(e) or isClassSetSyntaxCharacter(e)) {
                p.pos += 2;
                return @intCast(e);
            }
            const atom = try p.parseClassAtom();
            return switch (atom) {
                .char => |ch| ch,
                .class => p.fail("a class escape is not a character"),
            };
        }
        if (isClassSetSyntaxCharacter(c)) return p.fail("a syntax character must be escaped in a v-mode class");
        if (isClassSetReservedDouble(c) and p.peekAt(1) == c) return p.fail("a doubled punctuator is reserved in a v-mode class");
        return p.nextCp().?;
    }

    fn isClassSetSyntaxCharacter(c: u16) bool {
        return switch (c) {
            '(', ')', '[', ']', '{', '}', '/', '-', '\\', '|' => true,
            else => false,
        };
    }

    fn isClassSetReservedDouble(c: u16) bool {
        return switch (c) {
            '&', '!', '#', '$', '%', '*', '+', ',', '.', ':', ';', '<', '=', '>', '?', '@', '^', '`', '~' => true,
            else => false,
        };
    }

    fn isClassSetReservedPunctuator(c: u16) bool {
        return switch (c) {
            '&', '-', '!', '#', '%', ',', ':', ';', '<', '=', '>', '@', '`', '~' => true,
            else => false,
        };
    }

    fn unionSets(p: *Parser, a: ClassSet, b: ClassSet) Error!ClassSet {
        var ranges: std.ArrayList(Range) = .empty;
        try ranges.appendSlice(p.a, a.ranges);
        try ranges.appendSlice(p.a, b.ranges);
        var strs: std.ArrayList([]const u21) = .empty;
        try strs.appendSlice(p.a, a.strings);
        try strs.appendSlice(p.a, b.strings);
        return .{ .ranges = try mergeRanges(p.a, ranges.items), .strings = try dedupeStrings(p.a, strs.items) };
    }

    fn intersectSets(p: *Parser, a: ClassSet, b: ClassSet) Error!ClassSet {
        var strs: std.ArrayList([]const u21) = .empty;
        for (a.strings) |s| if (hasString(b.strings, s)) try strs.append(p.a, s);
        return .{ .ranges = try intersectRanges(p.a, try mergeRanges(p.a, a.ranges), try mergeRanges(p.a, b.ranges)), .strings = strs.items };
    }

    fn subtractSets(p: *Parser, a: ClassSet, b: ClassSet) Error!ClassSet {
        var strs: std.ArrayList([]const u21) = .empty;
        for (a.strings) |s| if (!hasString(b.strings, s)) try strs.append(p.a, s);
        return .{ .ranges = try intersectRanges(p.a, try mergeRanges(p.a, a.ranges), try invertRanges(p.a, try mergeRanges(p.a, b.ranges))), .strings = strs.items };
    }

    const ClassAtom = union(enum) { char: u21, class: Class };

    fn parseClassAtom(p: *Parser) Error!ClassAtom {
        const c = p.peek().?;
        if (c != '\\') {
            return .{ .char = p.nextCp().? };
        }
        p.pos += 1;
        const e = p.peek() orelse return p.fail("\\ at end of pattern");
        switch (e) {
            'd', 'D', 's', 'S', 'w', 'W' => {
                p.pos += 1;
                return .{ .class = try p.classEscape(e) };
            },
            'p', 'P' => {
                if (p.unicode) {
                    p.pos += 1;
                    return .{ .class = try p.parsePropertyEscape(e == 'P') };
                }
                p.pos += 1;
                return .{ .char = e };
            },
            'b' => {
                p.pos += 1;
                return .{ .char = 8 };
            },
            '-' => {
                if (p.unicode) {
                    p.pos += 1;
                    return .{ .char = '-' };
                }
                p.pos += 1;
                return .{ .char = '-' };
            },
            'c' => {
                p.pos += 1;
                if (p.peek()) |l| {
                    if ((l >= 'a' and l <= 'z') or (l >= 'A' and l <= 'Z') or (!p.unicode and ((l >= '0' and l <= '9') or l == '_'))) {
                        p.pos += 1;
                        return .{ .char = @intCast(l % 32) };
                    }
                }
                if (p.unicode) return p.fail("invalid class escape");
                p.pos -= 1;
                return .{ .char = '\\' };
            },
            '0'...'9' => {
                if (p.unicode) {
                    if (e == '0' and !(p.peekAt(1) != null and p.peekAt(1).? >= '0' and p.peekAt(1).? <= '9')) {
                        p.pos += 1;
                        return .{ .char = 0 };
                    }
                    return p.fail("invalid class escape");
                }
                if (e == '8' or e == '9') {
                    p.pos += 1;
                    return .{ .char = e };
                }
                return .{ .char = p.parseLegacyOctal() };
            },
            'k' => {
                if (p.unicode) return p.fail("invalid class escape");
                p.pos += 1;
                return .{ .char = 'k' };
            },
            else => return .{ .char = try p.parseCharacterEscape() },
        }
    }

    /// Case-insensitive classes match the folded forms too.
    fn foldRanges(p: *Parser, set: []Range) Error![]Range {
        var out: std.ArrayList(Range) = .empty;
        try out.appendSlice(p.a, set);
        for (set) |r| {
            // Expand small ranges character by character; large ranges
            // keep only the ASCII-letter folding (they already contain
            // most case pairs).
            if (r.hi - r.lo < 512) {
                var c = r.lo;
                while (c <= r.hi) : (c += 1) {
                    const f = canonicalize(c, p.unicode);
                    if (f != c) try out.append(p.a, .{ .lo = f, .hi = f });
                    // The inverse mapping: characters whose canonical form
                    // is c.
                    const inv = inverseCanonical(c, p.unicode);
                    for (inv) |x| if (x != 0) try out.append(p.a, .{ .lo = x, .hi = x });
                    // Folding is a set: what c folds to, and what folds to that.
                    if (p.unicode) {
                        const f2 = canonicalize(f, true);
                        if (f2 != f) try out.append(p.a, .{ .lo = f2, .hi = f2 });
                    }
                    if (c == 0x10FFFF) break;
                }
            } else {
                if (r.lo <= 'z' and r.hi >= 'a') try out.append(p.a, .{ .lo = @max(r.lo, 'a') - 32, .hi = @min(r.hi, 'z') - 32 });
                if (r.lo <= 'Z' and r.hi >= 'A') try out.append(p.a, .{ .lo = @max(r.lo, 'A') + 32, .hi = @min(r.hi, 'Z') + 32 });
            }
        }
        return mergeRanges(p.a, out.items);
    }
};

fn hexDigit(c: u16) ?u32 {
    if (c >= '0' and c <= '9') return c - '0';
    if (c >= 'a' and c <= 'f') return c - 'a' + 10;
    if (c >= 'A' and c <= 'F') return c - 'A' + 10;
    return null;
}

fn isSyntaxChar(c: u16) bool {
    return switch (c) {
        '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|' => true,
        else => false,
    };
}

fn isIdStart(cp: u21) bool {
    return unicode.isIdStart(cp);
}
fn isIdContinue(cp: u21) bool {
    return unicode.isIdContinue(cp);
}

fn appendCp(list: *std.ArrayList(u16), a: std.mem.Allocator, cp: u21) Error!void {
    if (cp < 0x10000) {
        try list.append(a, @intCast(cp));
    } else {
        const c = cp - 0x10000;
        try list.append(a, @intCast(0xd800 + (c >> 10)));
        try list.append(a, @intCast(0xdc00 + (c & 0x3ff)));
    }
}

const digit_ranges = [_]Range{.{ .lo = '0', .hi = '9' }};
const word_ranges = [_]Range{ .{ .lo = '0', .hi = '9' }, .{ .lo = 'A', .hi = 'Z' }, .{ .lo = '_', .hi = '_' }, .{ .lo = 'a', .hi = 'z' } };
const space_ranges = [_]Range{ .{ .lo = 9, .hi = 13 }, .{ .lo = 32, .hi = 32 }, .{ .lo = 0xa0, .hi = 0xa0 }, .{ .lo = 0x1680, .hi = 0x1680 }, .{ .lo = 0x2000, .hi = 0x200a }, .{ .lo = 0x2028, .hi = 0x2029 }, .{ .lo = 0x202f, .hi = 0x202f }, .{ .lo = 0x205f, .hi = 0x205f }, .{ .lo = 0x3000, .hi = 0x3000 }, .{ .lo = 0xfeff, .hi = 0xfeff } };

/// A `\p{}` table from the Unicode data, copied into the pattern's arena.
fn unicodeProperty(a: std.mem.Allocator, name: []const u8, value: ?[]const u8) Error!?[]Range {
    const table = unicode.property(name, value) orelse return null;
    const out = try a.alloc(Range, table.len);
    for (table, 0..) |r, i| out[i] = .{ .lo = @intCast(r.lo), .hi = @intCast(r.hi) };
    return out;
}

fn hasString(list: []const []const u21, s: []const u21) bool {
    for (list) |t| if (std.mem.eql(u21, t, s)) return true;
    return false;
}

fn dedupeStrings(a: std.mem.Allocator, in: []const []const u21) Error![]const []const u21 {
    var out: std.ArrayList([]const u21) = .empty;
    for (in) |s| if (!hasString(out.items, s)) try out.append(a, s);
    return out.items;
}

fn lessRange(_: void, a: Range, b: Range) bool {
    return a.lo < b.lo;
}

/// Sorted, merged ranges.
fn mergeRanges(a: std.mem.Allocator, in: []Range) Error![]Range {
    if (in.len == 0) return in;
    const copy = try a.dupe(Range, in);
    std.mem.sort(Range, copy, {}, lessRange);
    var w: usize = 0;
    for (copy) |r| {
        if (w > 0 and r.lo <= copy[w - 1].hi + 1) {
            if (r.hi > copy[w - 1].hi) copy[w - 1].hi = r.hi;
        } else {
            copy[w] = r;
            w += 1;
        }
    }
    return copy[0..w];
}

fn invertRanges(a: std.mem.Allocator, in: []Range) Error![]Range {
    const sorted = try mergeRanges(a, in);
    var out: std.ArrayList(Range) = .empty;
    var next: u21 = 0;
    for (sorted) |r| {
        if (r.lo > next) try out.append(a, .{ .lo = next, .hi = r.lo - 1 });
        next = if (r.hi == 0x10FFFF) 0x10FFFF else r.hi + 1;
        if (r.hi == 0x10FFFF) return out.items;
    }
    try out.append(a, .{ .lo = next, .hi = 0x10FFFF });
    return out.items;
}

fn intersectRanges(a: std.mem.Allocator, x: []Range, y: []Range) Error![]Range {
    var out: std.ArrayList(Range) = .empty;
    var i: usize = 0;
    var j: usize = 0;
    while (i < x.len and j < y.len) {
        const lo = @max(x[i].lo, y[j].lo);
        const hi = @min(x[i].hi, y[j].hi);
        if (lo <= hi) try out.append(a, .{ .lo = lo, .hi = hi });
        if (x[i].hi < y[j].hi) i += 1 else j += 1;
    }
    return out.items;
}

fn inRanges(ranges: []const Range, c: u21) bool {
    // Binary search over sorted ranges.
    var lo: usize = 0;
    var hi: usize = ranges.len;
    while (lo < hi) {
        const mid = (lo + hi) / 2;
        if (c < ranges[mid].lo) {
            hi = mid;
        } else if (c > ranges[mid].hi) {
            lo = mid + 1;
        } else return true;
    }
    return false;
}

/// Canonicalize (§22.2.2.7.3): simple case folding under `u`/`v`; else
/// the single-unit upper case, never folding a non-ASCII to ASCII.
pub fn canonicalize(c: u21, unicode_mode: bool) u21 {
    if (unicode_mode) return @intCast(unicode.foldSimple(c));
    if (c < 128) {
        if (c >= 'a' and c <= 'z') return c - 32;
        return c;
    }
    var out: [3]u32 = undefined;
    const n = unicode.toUpperFull(c, &out);
    if (n != 1) return c;
    const u = out[0];
    if (u < 128) return c;
    if (u > 0xffff) return c;
    return @intCast(u);
}

/// Characters whose canonical form is `c`: found by folding every
/// candidate the case tables relate to it (the simple mappings both
/// ways cover the pairs; a few special folds are listed).
fn inverseCanonical(c: u21, unicode_mode: bool) [4]u21 {
    var out: [4]u21 = .{ 0, 0, 0, 0 };
    var n: usize = 0;
    const cands = [_]u21{ @intCast(unicode.toUpperSimple(c)), @intCast(unicode.toLowerSimple(c)), @intCast(unicode.foldSimple(c)) };
    for (cands) |x| if (x != c and canonicalize(x, unicode_mode) == c) {
        out[n] = x;
        n += 1;
    };
    if (unicode_mode) {
        const extra: ?u21 = switch (c) {
            0xdf => 0x1e9e,
            's' => 0x17f,
            'k' => 0x212a,
            0x3c9 => 0x2126,
            0x3c3 => 0x3c2,
            0x3b9 => 0x345,
            0x3b8 => 0x3f4,
            0xe5 => 0x212b,
            0x3b2 => 0x3d0,
            0x3b5 => 0x3f5,
            0x3ba => 0x3f0,
            0x3c0 => 0x3d6,
            0x3c1 => 0x3f1,
            0x3c6 => 0x3d5,
            0x1e61 => 0x1e9b,
            else => null,
        };
        if (extra) |x| if (n < 4) {
            out[n] = x;
            n += 1;
        };
    }
    return out;
}

// ------------------------------------------------------------ program

pub const Op = enum(u8) { char, char_i, any, any_nl, class, split, jmp, save, clear, assert_start, assert_end, word_b, nword_b, backref, backref_i, look, rep_init, rep_top, rep_enter, rep_end, match, fail, bchar, bchar_i, bany, bany_nl, bclass, bbackref, bbackref_i, star, nbackref, nbackref_i, bnbackref, bnbackref_i };

pub const Insn = struct {
    op: Op,
    a: u32 = 0,
    b: u32 = 0,
    c: u32 = 0,
    d: u32 = 0,
};

pub const Program = struct {
    insns: []Insn,
    classes: []Class,
    ncaps: u32,
    names: []GroupName,
    /// The groups behind each `nbackref` (a name several groups share).
    name_sets: [][]const u32 = &.{},
    nloops: u32,
    flags: Flags,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(p: *Program) void {
        p.arena.deinit();
    }
};

const Compiler = struct {
    a: std.mem.Allocator,
    insns: std.ArrayList(Insn) = .empty,
    classes: std.ArrayList(Class) = .empty,
    name_sets: std.ArrayList([]const u32) = .empty,
    nloops: u32 = 0,
    flags: Flags,
    unicode: bool,
    names: []GroupName,

    fn emit(c: *Compiler, i: Insn) Error!u32 {
        try c.insns.append(c.a, i);
        return @intCast(c.insns.items.len - 1);
    }

    fn pc(c: *Compiler) u32 {
        return @intCast(c.insns.items.len);
    }

    /// Compile a node; `backward` for lookbehind bodies.
    fn compile(c: *Compiler, n: *Node, backward: bool) Error!void {
        switch (n.*) {
            .empty => {},
            .char => |ch| {
                if (c.flags.ignore_case) {
                    _ = try c.emit(.{ .op = if (backward) .bchar_i else .char_i, .a = canonicalize(ch, c.unicode) });
                } else _ = try c.emit(.{ .op = if (backward) .bchar else .char, .a = ch });
            },
            .any => _ = try c.emit(.{ .op = if (c.flags.dot_all) (if (backward) .bany_nl else .any_nl) else (if (backward) .bany else .any) }),
            .class => |cl| {
                const idx: u32 = @intCast(c.classes.items.len);
                var scoped = cl;
                scoped.ignore_case = c.flags.ignore_case;
                try c.classes.append(c.a, scoped);
                _ = try c.emit(.{ .op = if (backward) .bclass else .class, .a = idx });
            },
            .seq => |items| {
                if (backward) {
                    var i = items.len;
                    while (i > 0) {
                        i -= 1;
                        try c.compile(items[i], backward);
                    }
                } else for (items) |it| try c.compile(it, backward);
            },
            .alt => |alts| {
                // split L1, L2; L1: a; jmp end; L2: split ...
                var jumps: std.ArrayList(u32) = .empty;
                defer jumps.deinit(c.a);
                for (alts, 0..) |alt, i| {
                    if (i + 1 < alts.len) {
                        const split = try c.emit(.{ .op = .split });
                        c.insns.items[split].a = c.pc();
                        try c.compile(alt, backward);
                        try jumps.append(c.a, try c.emit(.{ .op = .jmp }));
                        c.insns.items[split].b = c.pc();
                    } else try c.compile(alt, backward);
                }
                for (jumps.items) |j| c.insns.items[j].a = c.pc();
            },
            .group => |g| {
                if (g.index) |idx| {
                    _ = try c.emit(.{ .op = .save, .a = if (backward) idx * 2 + 1 else idx * 2 });
                    try c.compile(g.body, backward);
                    _ = try c.emit(.{ .op = .save, .a = if (backward) idx * 2 else idx * 2 + 1 });
                } else try c.compile(g.body, backward);
            },
            .backref => |idx| _ = try c.emit(.{ .op = if (c.flags.ignore_case) (if (backward) .bbackref_i else .backref_i) else (if (backward) .bbackref else .backref), .a = idx }),
            .named_backref => |name| {
                var idx: u32 = 0;
                var count: u32 = 0;
                for (c.names) |g| if (std.mem.eql(u16, g.name, name)) {
                    idx = g.index;
                    count += 1;
                };
                if (count > 1) {
                    // Several groups of the name: the one that
                    // participated is found at match time (`name_sets`).
                    var set: std.ArrayList(u32) = .empty;
                    for (c.names) |g| if (std.mem.eql(u16, g.name, name)) try set.append(c.a, g.index);
                    const si: u32 = @intCast(c.name_sets.items.len);
                    try c.name_sets.append(c.a, set.items);
                    _ = try c.emit(.{ .op = if (c.flags.ignore_case) (if (backward) .bnbackref_i else .nbackref_i) else (if (backward) .bnbackref else .nbackref), .a = si });
                    return;
                }
                _ = try c.emit(.{ .op = if (c.flags.ignore_case) (if (backward) .bbackref_i else .backref_i) else (if (backward) .bbackref else .backref), .a = idx });
            },
            // `a`: the flag in force where the assertion was written.
            .assert_start => _ = try c.emit(.{ .op = .assert_start, .a = @intFromBool(c.flags.multiline) }),
            .assert_end => _ = try c.emit(.{ .op = .assert_end, .a = @intFromBool(c.flags.multiline) }),
            .word_boundary => |b| _ = try c.emit(.{ .op = if (b) .word_b else .nword_b, .a = @intFromBool(c.flags.ignore_case) }),
            .modifiers => |md| {
                const saved = c.flags;
                c.flags = md.flags;
                defer c.flags = saved;
                try c.compile(md.body, backward);
            },
            .look => |l| {
                // look negate ahead body_start body_end; the body ends in match.
                const at = try c.emit(.{ .op = .look, .a = @intFromBool(l.negate), .b = @intFromBool(l.ahead) });
                c.insns.items[at].c = c.pc();
                try c.compile(l.body, !l.ahead);
                _ = try c.emit(.{ .op = .match });
                c.insns.items[at].d = c.pc();
            },
            .repeat => |r| {
                // A greedy repeat of one character matcher: consume all it
                // can, hand back one at a time on backtracking (one stack
                // entry however long the run).
                if (r.greedy and !backward) {
                    const kind: ?u32 = switch (r.body.*) {
                        .char => 0,
                        .any => 2,
                        .class => 4,
                        else => null,
                    };
                    if (kind) |k0| {
                        var k = k0;
                        var argv: u32 = 0;
                        switch (r.body.*) {
                            .char => |ch| {
                                if (c.flags.ignore_case) {
                                    k = 1;
                                    argv = canonicalize(ch, c.unicode);
                                } else argv = ch;
                            },
                            .any => if (c.flags.dot_all) {
                                k = 3;
                            },
                            .class => |cl| {
                                argv = @intCast(c.classes.items.len);
                                var scoped = cl;
                                scoped.ignore_case = c.flags.ignore_case;
                                try c.classes.append(c.a, scoped);
                            },
                            else => unreachable,
                        }
                        _ = try c.emit(.{ .op = .star, .a = k, .b = argv, .c = r.min, .d = r.max orelse 0xFFFF_FFFF });
                        return;
                    }
                }
                const k = c.nloops;
                c.nloops += 1;
                _ = try c.emit(.{ .op = .rep_init, .a = k });
                const top = try c.emit(.{ .op = .rep_top, .a = k, .b = r.min, .c = r.max orelse 0xFFFF_FFFF, .d = @intFromBool(r.greedy) });
                // rep_enter k caps_from caps_to
                _ = try c.emit(.{ .op = .rep_enter, .a = k, .b = r.caps_from, .c = r.caps_to });
                try c.compile(r.body, backward);
                _ = try c.emit(.{ .op = .rep_end, .a = k, .b = r.min, .c = top });
                // rep_top's exit target: after rep_end.
                c.insns.items[top].d |= (c.pc() << 1);
            },
        }
    }
};

/// Parse and compile a pattern.
pub fn compile(gpa: std.mem.Allocator, source: []const u16, flags: Flags, err_out: *[]const u8) Error!*Program {
    var arena = std.heap.ArenaAllocator.init(gpa);
    errdefer arena.deinit();
    const a = arena.allocator();
    // Pre-scan: the total group count (Annex B decides `\N` by it) and
    // whether any named group exists (which turns `\k` into a reference).
    var total_groups: u32 = 0;
    var has_named = false;
    {
        var i: usize = 0;
        var in_class = false;
        while (i < source.len) : (i += 1) {
            const ch = source[i];
            if (ch == '\\') {
                i += 1;
                continue;
            }
            if (in_class) {
                if (ch == ']') in_class = false;
                continue;
            }
            if (ch == '[') {
                in_class = true;
                continue;
            }
            if (ch == '(') {
                if (i + 1 < source.len and source[i + 1] == '?') {
                    if (i + 2 < source.len and source[i + 2] == '<' and i + 3 < source.len and source[i + 3] != '=' and source[i + 3] != '!') {
                        total_groups += 1;
                        has_named = true;
                    }
                } else total_groups += 1;
            }
        }
    }
    var p = Parser{ .a = a, .src = source, .flags = flags, .unicode = flags.unicodeMode(), .has_named_groups = has_named, .total_groups = total_groups };
    const root = p.parseDisjunction() catch |e| {
        err_out.* = if (p.err.len > 0) p.err else "invalid regular expression";
        return e;
    };
    if (p.pos < source.len) {
        err_out.* = if (source[p.pos] == ')') "unmatched ')'" else "invalid regular expression";
        return error.SyntaxError;
    }
    if (p.unicode and p.max_backref >= p.ncaps) {
        err_out.* = "invalid backreference";
        return error.SyntaxError;
    }
    // Named backreferences must name a group.
    if (!try checkNamedRefs(root, p.names.items)) {
        err_out.* = "invalid named reference";
        return error.SyntaxError;
    }
    var c = Compiler{ .a = a, .flags = flags, .unicode = flags.unicodeMode(), .names = p.names.items };
    _ = try c.emit(.{ .op = .save, .a = 0 });
    try c.compile(root, false);
    _ = try c.emit(.{ .op = .save, .a = 1 });
    _ = try c.emit(.{ .op = .match });
    const prog = try a.create(Program);
    prog.* = .{ .insns = c.insns.items, .classes = c.classes.items, .ncaps = p.ncaps, .names = p.names.items, .name_sets = c.name_sets.items, .nloops = c.nloops, .flags = flags, .arena = arena };
    return prog;
}

fn checkNamedRefs(n: *Node, names: []GroupName) Error!bool {
    switch (n.*) {
        .named_backref => |name| {
            for (names) |g| if (std.mem.eql(u16, g.name, name)) return true;
            return false;
        },
        .seq, .alt => |items| {
            for (items) |it| if (!try checkNamedRefs(it, names)) return false;
            return true;
        },
        .group => |g| return checkNamedRefs(g.body, names),
        .look => |l| return checkNamedRefs(l.body, names),
        .repeat => |r| return checkNamedRefs(r.body, names),
        else => return true,
    }
}

// ------------------------------------------------------------ matcher

const Entry = union(enum) {
    choice: struct { pc: u32, pos: u32 },
    cap: struct { idx: u32, old: u32 },
    counter: struct { k: u32, old: u32 },
    lastpos: struct { k: u32, old: u32 },
    /// A lookaround's frame boundary: below it lives the outer search.
    barrier: struct { pc: u32, pos: u32 },
    /// A greedy run of single characters: resume at `pc` with one fewer
    /// character while `hi` is above `lo`.
    range: struct { pc: u32, lo: u32, hi: u32 },
};

pub const none: u32 = 0xFFFF_FFFF;

pub const MatchError = error{ OutOfMemory, Budget };

/// The matcher state for one exec.
pub const Matcher = struct {
    prog: *Program,
    text: []const u16,
    caps: []u32,
    counters: []u32,
    lastpos: []u32,
    stack: std.ArrayList(Entry) = .empty,
    gpa: std.mem.Allocator,
    steps: u64 = 0,
    budget: u64,
    unicode: bool,

    pub fn init(gpa: std.mem.Allocator, prog: *Program, text: []const u16, budget: u64) MatchError!Matcher {
        const caps = try gpa.alloc(u32, prog.ncaps * 2);
        @memset(caps, none);
        const counters = try gpa.alloc(u32, prog.nloops);
        const lastpos = try gpa.alloc(u32, prog.nloops);
        return .{ .prog = prog, .text = text, .caps = caps, .counters = counters, .lastpos = lastpos, .gpa = gpa, .budget = budget, .unicode = prog.flags.unicodeMode() };
    }

    pub fn deinit(m: *Matcher) void {
        m.gpa.free(m.caps);
        m.gpa.free(m.counters);
        m.gpa.free(m.lastpos);
        m.stack.deinit(m.gpa);
    }

    /// Try a match starting exactly at `start`; true on success with
    /// `caps` filled.
    pub fn matchAt(m: *Matcher, start: u32) MatchError!bool {
        @memset(m.caps, none);
        m.stack.clearRetainingCapacity();
        return m.run(0, start);
    }

    fn push(m: *Matcher, e: Entry) MatchError!void {
        if (m.stack.items.len > 4_000_000) return error.Budget;
        try m.stack.append(m.gpa, e);
    }

    fn setCap(m: *Matcher, idx: u32, v: u32) MatchError!void {
        try m.push(.{ .cap = .{ .idx = idx, .old = m.caps[idx] } });
        m.caps[idx] = v;
    }

    /// The code unit / code point at `pos` going forward, with its width.
    fn charAt(m: *Matcher, pos: u32) ?struct { c: u21, w: u32 } {
        if (pos >= m.text.len) return null;
        const c = m.text[pos];
        if (m.unicode and c >= 0xd800 and c <= 0xdbff and pos + 1 < m.text.len) {
            const lo = m.text[pos + 1];
            if (lo >= 0xdc00 and lo <= 0xdfff) return .{ .c = 0x10000 + ((@as(u21, c) - 0xd800) << 10) + (lo - 0xdc00), .w = 2 };
        }
        return .{ .c = c, .w = 1 };
    }

    /// The character before `pos`.
    fn charBefore(m: *Matcher, pos: u32) ?struct { c: u21, w: u32 } {
        if (pos == 0) return null;
        const c = m.text[pos - 1];
        if (m.unicode and c >= 0xdc00 and c <= 0xdfff and pos >= 2) {
            const hi = m.text[pos - 2];
            if (hi >= 0xd800 and hi <= 0xdbff) return .{ .c = 0x10000 + ((@as(u21, hi) - 0xd800) << 10) + (c - 0xdc00), .w = 2 };
        }
        return .{ .c = c, .w = 1 };
    }

    fn isWordAt(m: *Matcher, pos: u32, ignore_case: bool) bool {
        if (pos >= m.text.len) return false;
        const c = m.text[pos];
        if (c < 128) return (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '_';
        // With `u` and `i`, the folds of word characters count too.
        if (m.unicode and ignore_case) return c == 0x17f or c == 0x212a;
        return false;
    }

    fn isLineTerminator(c: u21) bool {
        return c == '\n' or c == '\r' or c == 0x2028 or c == 0x2029;
    }

    fn classMatches(m: *Matcher, idx: u32, c: u21) bool {
        const cl = m.prog.classes[idx];
        var hit = inRanges(cl.ranges, c);
        if (!hit and cl.ignore_case) hit = inRanges(cl.ranges, canonicalize(c, m.unicode));
        return hit != cl.negate;
    }

    /// Backtrack to the last choice point; false when none is left
    /// above the current barrier.
    fn backtrack(m: *Matcher, pc_out: *u32, pos_out: *u32) bool {
        while (m.stack.items.len > 0) {
            const e = m.stack.items[m.stack.items.len - 1];
            switch (e) {
                .barrier => return false,
                else => {},
            }
            if (e == .range) {
                const r = e.range;
                if (r.hi > r.lo) {
                    const back = m.charBefore(r.hi).?;
                    const nhi = r.hi - back.w;
                    if (nhi >= r.lo) {
                        m.stack.items[m.stack.items.len - 1] = .{ .range = .{ .pc = r.pc, .lo = r.lo, .hi = nhi } };
                        pc_out.* = r.pc;
                        pos_out.* = nhi;
                        return true;
                    }
                }
                _ = m.stack.pop();
                continue;
            }
            _ = m.stack.pop();
            switch (e) {
                .choice => |ch| {
                    pc_out.* = ch.pc;
                    pos_out.* = ch.pos;
                    return true;
                },
                .range => unreachable,
                .cap => |cp| m.caps[cp.idx] = cp.old,
                .counter => |ct| m.counters[ct.k] = ct.old,
                .lastpos => |lp| m.lastpos[lp.k] = lp.old,
                .barrier => unreachable,
            }
        }
        return false;
    }

    /// Run from `pc` at `pos` until match or exhaustion of this frame's
    /// choices.
    fn run(m: *Matcher, start_pc: u32, start_pos: u32) MatchError!bool {
        var pc = start_pc;
        var pos = start_pos;
        const insns = m.prog.insns;
        while (true) {
            m.steps += 1;
            if (m.steps > m.budget) return error.Budget;
            const insn = insns[pc];
            var ok = true;
            switch (insn.op) {
                .char, .char_i => {
                    if (m.charAt(pos)) |ch| {
                        const c = if (insn.op == .char_i) canonicalize(ch.c, m.unicode) else ch.c;
                        if (c == insn.a) {
                            pos += ch.w;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .bchar, .bchar_i => {
                    if (m.charBefore(pos)) |ch| {
                        const c = if (insn.op == .bchar_i) canonicalize(ch.c, m.unicode) else ch.c;
                        if (c == insn.a) {
                            pos -= ch.w;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .any, .any_nl => {
                    if (m.charAt(pos)) |ch| {
                        if (insn.op == .any_nl or !isLineTerminator(ch.c)) {
                            pos += ch.w;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .bany, .bany_nl => {
                    if (m.charBefore(pos)) |ch| {
                        if (insn.op == .bany_nl or !isLineTerminator(ch.c)) {
                            pos -= ch.w;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .class => {
                    if (m.charAt(pos)) |ch| {
                        if (m.classMatches(insn.a, ch.c)) {
                            pos += ch.w;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .bclass => {
                    if (m.charBefore(pos)) |ch| {
                        if (m.classMatches(insn.a, ch.c)) {
                            pos -= ch.w;
                            pc += 1;
                        } else ok = false;
                    } else ok = false;
                },
                .split => {
                    try m.push(.{ .choice = .{ .pc = insn.b, .pos = pos } });
                    pc = insn.a;
                },
                .jmp => pc = insn.a,
                .save => {
                    try m.setCap(insn.a, pos);
                    pc += 1;
                },
                .clear => {
                    var i = insn.a;
                    while (i < insn.b) : (i += 1) try m.setCap(i, none);
                    pc += 1;
                },
                .assert_start => {
                    if (pos == 0 or (insn.a != 0 and isLineTerminator(m.text[pos - 1]))) pc += 1 else ok = false;
                },
                .assert_end => {
                    if (pos == m.text.len or (insn.a != 0 and isLineTerminator(m.text[pos]))) pc += 1 else ok = false;
                },
                .word_b, .nword_b => {
                    const a = pos > 0 and m.isWordAt(pos - 1, insn.a != 0);
                    const b = m.isWordAt(pos, insn.a != 0);
                    const at_boundary = a != b;
                    if (at_boundary == (insn.op == .word_b)) pc += 1 else ok = false;
                },
                .backref, .backref_i, .bbackref, .bbackref_i, .nbackref, .nbackref_i, .bnbackref, .bnbackref_i => {
                    // A name several groups share: the one that
                    // participated (at most one can have).
                    var gi: u32 = insn.a;
                    const named = switch (insn.op) {
                        .nbackref, .nbackref_i, .bnbackref, .bnbackref_i => true,
                        else => false,
                    };
                    if (named) {
                        gi = m.prog.name_sets[insn.a][0];
                        for (m.prog.name_sets[insn.a]) |g| if (m.caps[g * 2] != none and m.caps[g * 2 + 1] != none) {
                            gi = g;
                        };
                    }
                    const s = m.caps[gi * 2];
                    const e = m.caps[gi * 2 + 1];
                    if (s == none or e == none) {
                        pc += 1; // an unset group matches empty
                    } else {
                        const len = e - s;
                        const fold = switch (insn.op) {
                            .backref_i, .bbackref_i, .nbackref_i, .bnbackref_i => true,
                            else => false,
                        };
                        const forward = switch (insn.op) {
                            .backref, .backref_i, .nbackref, .nbackref_i => true,
                            else => false,
                        };
                        if (forward) {
                            if (pos + len > m.text.len) {
                                ok = false;
                            } else {
                                var i: u32 = 0;
                                while (i < len) : (i += 1) {
                                    var x: u21 = m.text[s + i];
                                    var y: u21 = m.text[pos + i];
                                    if (fold) {
                                        x = canonicalize(x, m.unicode);
                                        y = canonicalize(y, m.unicode);
                                    }
                                    if (x != y) {
                                        ok = false;
                                        break;
                                    }
                                }
                                if (ok) {
                                    pos += len;
                                    pc += 1;
                                }
                            }
                        } else {
                            if (pos < len) {
                                ok = false;
                            } else {
                                var i: u32 = 0;
                                while (i < len) : (i += 1) {
                                    var x: u21 = m.text[s + i];
                                    var y: u21 = m.text[pos - len + i];
                                    if (fold) {
                                        x = canonicalize(x, m.unicode);
                                        y = canonicalize(y, m.unicode);
                                    }
                                    if (x != y) {
                                        ok = false;
                                        break;
                                    }
                                }
                                if (ok) {
                                    pos -= len;
                                    pc += 1;
                                }
                            }
                        }
                    }
                },
                .look => {
                    const negate = insn.a == 1;
                    // The body runs above a barrier; its choices are dropped
                    // afterwards (no backtracking into a lookaround) but its
                    // capture undo entries are kept for the outer search.
                    const base = m.stack.items.len;
                    try m.push(.{ .barrier = .{ .pc = pc, .pos = pos } });
                    const matched = try m.run(insn.c, pos);
                    if (matched and !negate) {
                        // Keep undo entries, drop choices and the barrier.
                        var keep: std.ArrayList(Entry) = .empty;
                        defer keep.deinit(m.gpa);
                        for (m.stack.items[base + 1 ..]) |e| switch (e) {
                            .choice, .barrier, .range => {},
                            else => try keep.append(m.gpa, e),
                        };
                        m.stack.shrinkRetainingCapacity(base);
                        try m.stack.appendSlice(m.gpa, keep.items);
                        pc = insn.d;
                    } else {
                        // Undo everything the body did.
                        var tmp_pc: u32 = 0;
                        var tmp_pos: u32 = 0;
                        while (m.backtrack(&tmp_pc, &tmp_pos)) {}
                        if (m.stack.items.len > base) m.stack.shrinkRetainingCapacity(base); // the barrier
                        if (matched == negate) ok = false else pc = insn.d;
                    }
                },
                .rep_init => {
                    try m.push(.{ .counter = .{ .k = insn.a, .old = m.counters[insn.a] } });
                    m.counters[insn.a] = 0;
                    try m.push(.{ .lastpos = .{ .k = insn.a, .old = m.lastpos[insn.a] } });
                    m.lastpos[insn.a] = none;
                    pc += 1;
                },
                .rep_top => {
                    const k = insn.a;
                    const min = insn.b;
                    const max = insn.c;
                    const greedy = insn.d & 1 == 1;
                    const exit = insn.d >> 1;
                    const count = m.counters[k];
                    if (count < min) {
                        pc += 1;
                    } else if (count >= max) {
                        pc = exit;
                    } else if (greedy) {
                        try m.push(.{ .choice = .{ .pc = exit, .pos = pos } });
                        pc += 1;
                    } else {
                        try m.push(.{ .choice = .{ .pc = pc + 1, .pos = pos } });
                        pc = exit;
                    }
                },
                .rep_enter => {
                    const k = insn.a;
                    try m.push(.{ .lastpos = .{ .k = k, .old = m.lastpos[k] } });
                    m.lastpos[k] = pos;
                    try m.push(.{ .counter = .{ .k = k, .old = m.counters[k] } });
                    m.counters[k] += 1;
                    var i = insn.b * 2;
                    while (i < insn.c * 2) : (i += 1) if (m.caps[i] != none) try m.setCap(i, none);
                    pc += 1;
                },
                .rep_end => {
                    const k = insn.a;
                    const min = insn.b;
                    // An optional iteration that matched nothing ends the loop
                    // (the specification's empty check).
                    if (m.counters[k] > min and m.lastpos[k] == pos) {
                        ok = false;
                    } else pc = insn.c;
                },
                .star => {
                    const kind = insn.a;
                    const min = insn.c;
                    const max = insn.d;
                    var count: u32 = 0;
                    var lo_pos = pos;
                    while (count < max) {
                        const ch = m.charAt(pos) orelse break;
                        const hit = switch (kind) {
                            0 => ch.c == insn.b,
                            1 => canonicalize(ch.c, m.unicode) == insn.b,
                            2 => !isLineTerminator(ch.c),
                            3 => true,
                            else => m.classMatches(insn.b, ch.c),
                        };
                        if (!hit) break;
                        pos += ch.w;
                        count += 1;
                        if (count == min) lo_pos = pos;
                        m.steps += 1;
                    }
                    if (count < min) {
                        ok = false;
                    } else {
                        if (pos > lo_pos) try m.push(.{ .range = .{ .pc = pc + 1, .lo = lo_pos, .hi = pos } });
                        pc += 1;
                    }
                },
                .match => return true,
                .fail => ok = false,
            }
            if (!ok) {
                if (!m.backtrack(&pc, &pos)) return false;
            }
        }
    }
};

// -------------------------------------------------------------- tests

fn toUnits(gpa: std.mem.Allocator, list: *std.ArrayList(u16), utf8: []const u8) !void {
    var it = std.unicode.Wtf8View.initUnchecked(utf8).iterator();
    while (it.nextCodepoint()) |cp| try appendCp(list, gpa, cp);
}

fn testMatch(gpa: std.mem.Allocator, pattern: []const u8, flags_s: []const u8, text: []const u8) !?[]const u32 {
    var pat: std.ArrayList(u16) = .empty;
    defer pat.deinit(gpa);
    try toUnits(gpa, &pat, pattern);
    var fl: std.ArrayList(u16) = .empty;
    defer fl.deinit(gpa);
    try toUnits(gpa, &fl, flags_s);
    var txt: std.ArrayList(u16) = .empty;
    defer txt.deinit(gpa);
    try toUnits(gpa, &txt, text);
    var err: []const u8 = "";
    const prog = try compile(gpa, pat.items, Flags.parse(fl.items).?, &err);
    defer prog.deinit();
    var m = try Matcher.init(gpa, prog, txt.items, 1_000_000);
    defer m.deinit();
    var start: u32 = 0;
    while (start <= txt.items.len) : (start += 1) {
        if (try m.matchAt(start)) return try gpa.dupe(u32, m.caps);
        if (prog.flags.sticky) break;
    }
    return null;
}

test "regexp: literals, classes, quantifiers, groups and backreferences" {
    const gpa = std.testing.allocator;
    const cases = [_]struct { p: []const u8, f: []const u8, t: []const u8, want: ?[]const u32 }{
        .{ .p = "ab+c", .f = "", .t = "xabbbcx", .want = &.{ 1, 6 } },
        .{ .p = "a.c", .f = "", .t = "abc", .want = &.{ 0, 3 } },
        .{ .p = "a.c", .f = "", .t = "a\nc", .want = null },
        .{ .p = "a.c", .f = "s", .t = "a\nc", .want = &.{ 0, 3 } },
        .{ .p = "(\\d+)-(\\d+)", .f = "", .t = "tel 12-345", .want = &.{ 4, 10, 4, 6, 7, 10 } },
        .{ .p = "(a*)*b", .f = "", .t = "aaab", .want = &.{ 0, 4, 0, 3 } },
        .{ .p = "(a|ab)(c|bcd)(d*)", .f = "", .t = "abcd", .want = &.{ 0, 4, 0, 1, 1, 4, 4, 4 } },
        .{ .p = "a*?b", .f = "", .t = "aaab", .want = &.{ 0, 4 } },
        .{ .p = "(\\w+)\\s\\1", .f = "", .t = "hey hey you", .want = &.{ 0, 7, 0, 3 } },
        .{ .p = "^\\w+$", .f = "", .t = "ab cd", .want = null },
        .{ .p = "^\\w+$", .f = "m", .t = "ab\ncd", .want = &.{ 0, 2 } },
        .{ .p = "ABC", .f = "i", .t = "xabcx", .want = &.{ 1, 4 } },
        // Modifiers scope i, m and s to a group.
        .{ .p = "(?i:a)b", .f = "", .t = "Ab", .want = &.{ 0, 2 } },
        .{ .p = "(?i:a)b", .f = "", .t = "AB", .want = null },
        .{ .p = "(?-i:a)b", .f = "i", .t = "aB", .want = &.{ 0, 2 } },
        .{ .p = "(?-i:a)b", .f = "i", .t = "AB", .want = null },
        .{ .p = "(?i:[a-c])d", .f = "", .t = "Bd", .want = &.{ 0, 2 } },
        .{ .p = "(?m:^b)", .f = "", .t = "a\nb", .want = &.{ 2, 3 } },
        .{ .p = "(?-m:^b)", .f = "m", .t = "a\nb", .want = null },
        .{ .p = "(?s:.)b", .f = "", .t = "\nb", .want = &.{ 0, 2 } },
        .{ .p = "(?i:\\w)", .f = "u", .t = "\u{17f}", .want = &.{ 0, 1 } },
        // Property escapes fold under `i`; `\P` complements the plain set in `u` mode and the folded one in `v` mode.
        .{ .p = "\\p{Lu}", .f = "iu", .t = "a", .want = &.{ 0, 1 } },
        .{ .p = "\\P{Lu}", .f = "iu", .t = "A", .want = &.{ 0, 1 } },
        .{ .p = "\\P{Lu}", .f = "iv", .t = "A", .want = null },
        .{ .p = "(?i:\\p{Lu})", .f = "u", .t = "z", .want = &.{ 0, 1 } },
        // Duplicate named groups (ES2025): one name per alternative; `\k` follows the one that matched.
        .{ .p = "(?:(?<x>a)|(?<x>b))\\k<x>", .f = "", .t = "bb", .want = &.{ 0, 2, 0xFFFFFFFF, 0xFFFFFFFF, 0, 1 } },
        .{ .p = "(?:(?<x>a)|(?<x>b))\\k<x>", .f = "", .t = "ab", .want = null },
        // v-mode class sets: string literals, properties of strings, set operations.
        .{ .p = "[\\q{abc|d}]", .f = "v", .t = "xabc", .want = &.{ 1, 4 } },
        .{ .p = "^[\\q{abc|d}]$", .f = "v", .t = "d", .want = &.{ 0, 1 } },
        .{ .p = "^[\\q{abc|d}]$", .f = "v", .t = "ab", .want = null },
        .{ .p = "^[[a-z]--[aeiou]]+$", .f = "v", .t = "xyz", .want = &.{ 0, 3 } },
        .{ .p = "^[[a-z]--[aeiou]]+$", .f = "v", .t = "xaz", .want = null },
        .{ .p = "^[[a-z]&&[^aeiou]]+$", .f = "v", .t = "xyz", .want = &.{ 0, 3 } },
        .{ .p = "^[\\q{ab|cd}--\\q{cd}]$", .f = "v", .t = "cd", .want = null },
        .{ .p = "^\\p{Emoji_Keycap_Sequence}$", .f = "v", .t = "#\u{FE0F}\u{20E3}", .want = &.{ 0, 3 } },
        .{ .p = "^\\p{RGI_Emoji}$", .f = "v", .t = "\u{231A}", .want = &.{ 0, 1 } },
        .{ .p = "^[\\p{RGI_Emoji}--\\q{\u{231A}}]$", .f = "v", .t = "\u{231A}", .want = null },
        .{ .p = "[a-c]+", .f = "", .t = "xxabcabcd", .want = &.{ 2, 8 } },
        .{ .p = "[^a-c]+", .f = "", .t = "abcxyz", .want = &.{ 3, 6 } },
        .{ .p = "a(?=b)", .f = "", .t = "acab", .want = &.{ 2, 3 } },
        .{ .p = "a(?!b)", .f = "", .t = "abac", .want = &.{ 2, 3 } },
        .{ .p = "(?<=\\$)\\d+", .f = "", .t = "cost $42", .want = &.{ 6, 8 } },
        .{ .p = "(?<!\\$)\\b\\d+", .f = "", .t = "$42 17", .want = &.{ 4, 6 } },
        .{ .p = "(?<y>\\d{4})-(?<m>\\d{2})", .f = "", .t = "on 2026-09", .want = &.{ 3, 10, 3, 7, 8, 10 } },
        .{ .p = "\\k<n>(?<n>a)", .f = "", .t = "a", .want = &.{ 0, 1, 0, 1 } },
        .{ .p = "x{2,3}", .f = "", .t = "xxxxx", .want = &.{ 0, 3 } },
        .{ .p = "x{2,}?", .f = "", .t = "xxxxx", .want = &.{ 0, 2 } },
        .{ .p = "(?:a|b)*c", .f = "", .t = "ababc", .want = &.{ 0, 5 } },
        .{ .p = "\\u{1F600}", .f = "u", .t = "x\u{1F600}", .want = &.{ 1, 3 } },
        .{ .p = "^.$", .f = "u", .t = "\u{1F600}", .want = &.{ 0, 2 } },
        .{ .p = "^.$", .f = "", .t = "\u{1F600}", .want = null },
        .{ .p = "\\bfoo\\b", .f = "", .t = "a foo.", .want = &.{ 2, 5 } },
        .{ .p = "(a?)*", .f = "", .t = "b", .want = &.{ 0, 0, none, none } },
        .{ .p = "(z)((a+)?(b+)?(c))*", .f = "", .t = "zaacbbbcac", .want = &.{ 0, 10, 0, 1, 8, 10, 8, 9, none, none, 9, 10 } },
    };
    for (cases) |c| {
        const got = try testMatch(gpa, c.p, c.f, c.t);
        defer if (got) |g| gpa.free(g);
        if (c.want) |w| {
            if (got == null) {
                std.debug.print("no match: /{s}/{s} on {s}\n", .{ c.p, c.f, c.t });
                return error.TestUnexpectedResult;
            }
            if (!std.mem.eql(u32, w, got.?)) {
                std.debug.print("bad captures: /{s}/{s} on {s}: {any}\n", .{ c.p, c.f, c.t, got.? });
                return error.TestUnexpectedResult;
            }
        } else if (got != null) {
            std.debug.print("unexpected match: /{s}/{s} on {s}: {any}\n", .{ c.p, c.f, c.t, got.? });
            return error.TestUnexpectedResult;
        }
    }
}

test "regexp: syntax errors and the step budget" {
    const gpa = std.testing.allocator;
    var err: []const u8 = "";
    for ([_][]const u8{ "(", "a**", "[b-a]", "\\", "(?<n>a)(?<n>b)", "\\k<x>(?<n>a)", "(?-:a)", "(?ii:a)", "(?i-i:a)", "(?i-mm:a)", "(?x:a)", "(?i", "(?i:a", "(?<n>a)(?:(?<n>b)|c)", "(?:(?<n>a)|b)(?<n>c)" }) |bad| {
        var pat: std.ArrayList(u16) = .empty;
        defer pat.deinit(gpa);
        for (bad) |c| try pat.append(gpa, c);
        try std.testing.expectError(error.SyntaxError, compile(gpa, pat.items, .{}, &err));
    }
    for ([_][]const u8{ "[(]", "[}]", "[!!]", "[++]", "[_^^]", "[a&&b--c]", "[ab&&c]", "[a-z&&b]", "[^\\q{ab}]", "[\\P{RGI_Emoji}]", "\\P{RGI_Emoji}", "[a--]", "[&&a]" }) |bad| {
        var pat: std.ArrayList(u16) = .empty;
        defer pat.deinit(gpa);
        for (bad) |c| try pat.append(gpa, c);
        try std.testing.expectError(error.SyntaxError, compile(gpa, pat.items, .{ .unicode_sets = true }, &err));
    }
    // A property of strings needs the v flag.
    {
        var pat: std.ArrayList(u16) = .empty;
        defer pat.deinit(gpa);
        for ("\\p{RGI_Emoji}") |c| try pat.append(gpa, c);
        try std.testing.expectError(error.SyntaxError, compile(gpa, pat.items, .{ .unicode = true }, &err));
    }
    // Catastrophic backtracking meets the budget.
    var pat: std.ArrayList(u16) = .empty;
    defer pat.deinit(gpa);
    for ("(a+)+$") |c| try pat.append(gpa, c);
    const prog = try compile(gpa, pat.items, .{}, &err);
    defer prog.deinit();
    var txt: std.ArrayList(u16) = .empty;
    defer txt.deinit(gpa);
    for ("aaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaaab") |c| try txt.append(gpa, c);
    var m = try Matcher.init(gpa, prog, txt.items, 100_000);
    defer m.deinit();
    try std.testing.expectError(error.Budget, m.matchAt(0));
}
