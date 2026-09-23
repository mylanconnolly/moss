//! CSS Syntax Level 3 (https://drafts.csswg.org/css-syntax-3/): the
//! tokenizer and the parser's entry points — a stylesheet, a list of
//! rules, one rule, one declaration, a list of declarations, a block's
//! contents (the nesting-era mix of declarations and rules), one
//! component value and a list of them — with the standard's error
//! recovery. Everything is a tree of component values (tokens, blocks,
//! functions) that the cascade above reads; nothing here knows what a
//! property means. Text is UTF-8 (the decoder before it saw to that).
//!
//! The host test runs the css-parsing-tests corpus and prints its count.
//! Two tokens the corpus still expects are gone from the standard — the
//! `~=`-style match tokens (delims now) and unicode-range tokens outside
//! a font-face descriptor (an option here, off by default) — and their
//! handful of cases count against us; the EOF markers inside a token
//! stream (`eof-in-string`, `eof-in-url`) are produced as the corpus
//! writes them, as `err` values a consumer ignores.
const std = @import("std");

pub const Error = error{OutOfMemory};

pub const Num = struct {
    repr: []const u8,
    value: f64,
    integer: bool,
};

pub const Token = union(enum) {
    ident: []const u8,
    function: []const u8,
    at_keyword: []const u8,
    hash: struct { value: []const u8, id: bool },
    string: []const u8,
    bad_string,
    url: []const u8,
    bad_url,
    delim: u8,
    number: Num,
    percentage: Num,
    dimension: struct { num: Num, unit: []const u8 },
    whitespace,
    cdo,
    cdc,
    colon,
    semicolon,
    comma,
    open_square,
    close_square,
    open_paren,
    close_paren,
    open_curly,
    close_curly,
    unicode_range: struct { start: u32, end: u32 },
    /// A marker the corpus writes into the stream: `eof-in-string`,
    /// `eof-in-url`. A consumer treats it as nothing.
    err: []const u8,
    eof,
};

pub const Tokenizer = struct {
    a: std.mem.Allocator,
    src: []const u8,
    pos: usize = 0,
    /// Produce unicode-range tokens for `u+…` (a font-face descriptor's
    /// context; off elsewhere, as the standard says).
    unicode_ranges: bool = false,
    queued: ?Token = null,

    pub fn init(a: std.mem.Allocator, input: []const u8) Error!Tokenizer {
        // The input stream: CR, FF and CR LF become LF; NUL becomes U+FFFD.
        // Input with none of them is used as it is.
        if (std.mem.indexOfAny(u8, input, "\r\x0c\x00") == null) return .{ .a = a, .src = input };
        var out: std.ArrayList(u8) = .empty;
        try out.ensureTotalCapacity(a, input.len);
        var i: usize = 0;
        while (i < input.len) : (i += 1) {
            const c = input[i];
            if (c == '\r') {
                try out.append(a, '\n');
                if (i + 1 < input.len and input[i + 1] == '\n') i += 1;
            } else if (c == 0x0c) {
                try out.append(a, '\n');
            } else if (c == 0) {
                try out.appendSlice(a, "\u{fffd}");
            } else try out.append(a, c);
        }
        return .{ .a = a, .src = out.items };
    }

    fn peek(t: *const Tokenizer, ahead: usize) ?u8 {
        return if (t.pos + ahead < t.src.len) t.src[t.pos + ahead] else null;
    }

    fn isNameStart(c: ?u8) bool {
        const ch = c orelse return false;
        return std.ascii.isAlphabetic(ch) or ch == '_' or ch >= 0x80;
    }

    fn isName(c: ?u8) bool {
        const ch = c orelse return false;
        return isNameStart(ch) or std.ascii.isDigit(ch) or ch == '-';
    }

    fn isWs(c: ?u8) bool {
        const ch = c orelse return false;
        return ch == ' ' or ch == '\t' or ch == '\n';
    }

    fn validEscape(first: ?u8, second: ?u8) bool {
        if (first != '\\') return false;
        const s = second orelse return false;
        return s != '\n';
    }

    fn startsIdent(first: ?u8, second: ?u8, third: ?u8) bool {
        const f = first orelse return false;
        if (f == '-') return isNameStart(second) or second == '-' or validEscape(second, third);
        if (isNameStart(f)) return true;
        return validEscape(first, second);
    }

    fn startsNumber(first: ?u8, second: ?u8, third: ?u8) bool {
        const f = first orelse return false;
        if (f == '+' or f == '-') {
            if (second != null and std.ascii.isDigit(second.?)) return true;
            return second == '.' and third != null and std.ascii.isDigit(third.?);
        }
        if (f == '.') return second != null and std.ascii.isDigit(second.?);
        return std.ascii.isDigit(f);
    }

    fn wouldStartIdent(t: *const Tokenizer) bool {
        return startsIdent(t.peek(0), t.peek(1), t.peek(2));
    }

    fn wouldStartNumber(t: *const Tokenizer) bool {
        return startsNumber(t.peek(0), t.peek(1), t.peek(2));
    }

    fn skipComments(t: *Tokenizer) void {
        while (t.peek(0) == '/' and t.peek(1) == '*') {
            const end = std.mem.indexOfPos(u8, t.src, t.pos + 2, "*/") orelse {
                t.pos = t.src.len;
                return;
            };
            t.pos = end + 2;
        }
    }

    pub fn next(t: *Tokenizer) Error!Token {
        if (t.queued) |q| {
            t.queued = null;
            return q;
        }
        t.skipComments();
        const c = t.peek(0) orelse return .eof;
        if (isWs(c)) {
            while (isWs(t.peek(0))) t.pos += 1;
            return .whitespace;
        }
        switch (c) {
            '"', '\'' => {
                t.pos += 1;
                return t.consumeString(c);
            },
            '#' => {
                if (isName(t.peek(1)) or validEscape(t.peek(1), t.peek(2))) {
                    t.pos += 1;
                    const id = t.wouldStartIdent();
                    return .{ .hash = .{ .value = try t.consumeName(), .id = id } };
                }
                t.pos += 1;
                return .{ .delim = c };
            },
            '(' => {
                t.pos += 1;
                return .open_paren;
            },
            ')' => {
                t.pos += 1;
                return .close_paren;
            },
            '+' => {
                if (t.wouldStartNumber()) return t.consumeNumeric();
                t.pos += 1;
                return .{ .delim = c };
            },
            ',' => {
                t.pos += 1;
                return .comma;
            },
            '-' => {
                if (t.wouldStartNumber()) return t.consumeNumeric();
                if (t.peek(1) == '-' and t.peek(2) == '>') {
                    t.pos += 3;
                    return .cdc;
                }
                if (t.wouldStartIdent()) return t.consumeIdentLike();
                t.pos += 1;
                return .{ .delim = c };
            },
            '.' => {
                if (t.wouldStartNumber()) return t.consumeNumeric();
                t.pos += 1;
                return .{ .delim = c };
            },
            ':' => {
                t.pos += 1;
                return .colon;
            },
            ';' => {
                t.pos += 1;
                return .semicolon;
            },
            '<' => {
                if (t.peek(1) == '!' and t.peek(2) == '-' and t.peek(3) == '-') {
                    t.pos += 4;
                    return .cdo;
                }
                t.pos += 1;
                return .{ .delim = c };
            },
            '@' => {
                if (startsIdent(t.peek(1), t.peek(2), t.peek(3))) {
                    t.pos += 1;
                    return .{ .at_keyword = try t.consumeName() };
                }
                t.pos += 1;
                return .{ .delim = c };
            },
            '[' => {
                t.pos += 1;
                return .open_square;
            },
            '\\' => {
                if (validEscape(t.peek(0), t.peek(1))) return t.consumeIdentLike();
                t.pos += 1;
                return .{ .delim = c };
            },
            ']' => {
                t.pos += 1;
                return .close_square;
            },
            '{' => {
                t.pos += 1;
                return .open_curly;
            },
            '}' => {
                t.pos += 1;
                return .close_curly;
            },
            else => {},
        }
        if (std.ascii.isDigit(c)) return t.consumeNumeric();
        if ((c == 'u' or c == 'U') and t.unicode_ranges and t.peek(1) == '+' and (t.peek(2) == '?' or (t.peek(2) != null and std.ascii.isHex(t.peek(2).?)))) {
            return t.consumeUnicodeRange();
        }
        if (isNameStart(c)) return t.consumeIdentLike();
        t.pos += 1;
        return .{ .delim = c };
    }

    /// An escape after the backslash was consumed: a code point as UTF-8.
    fn consumeEscape(t: *Tokenizer, out: *std.ArrayList(u8)) Error!void {
        const c = t.peek(0) orelse {
            try out.appendSlice(t.a, "\u{fffd}");
            return;
        };
        if (std.ascii.isHex(c)) {
            var cp: u32 = 0;
            var n: usize = 0;
            while (n < 6) : (n += 1) {
                const h = t.peek(0) orelse break;
                if (!std.ascii.isHex(h)) break;
                cp = cp * 16 + (std.fmt.charToDigit(h, 16) catch 0);
                t.pos += 1;
            }
            if (isWs(t.peek(0))) t.pos += 1;
            if (cp == 0 or cp > 0x10ffff or (cp >= 0xd800 and cp <= 0xdfff)) cp = 0xfffd;
            var buf: [4]u8 = undefined;
            const len = std.unicode.utf8Encode(@intCast(cp), &buf) catch 0;
            try out.appendSlice(t.a, buf[0..len]);
            return;
        }
        try out.append(t.a, c);
        t.pos += 1;
    }

    fn consumeName(t: *Tokenizer) Error![]const u8 {
        // The common name has no escape: it is a slice of the source.
        const start = t.pos;
        while (t.peek(0)) |c| : (t.pos += 1) if (!isName(c)) break;
        if (t.peek(0) != '\\' or !validEscape('\\', t.peek(1))) return t.src[start..t.pos];
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(t.a, t.src[start..t.pos]);
        while (true) {
            const c = t.peek(0) orelse break;
            if (isName(c)) {
                try out.append(t.a, c);
                t.pos += 1;
            } else if (validEscape(c, t.peek(1))) {
                t.pos += 1;
                try t.consumeEscape(&out);
            } else break;
        }
        return out.items;
    }

    fn consumeNumeric(t: *Tokenizer) Error!Token {
        const start = t.pos;
        var integer = true;
        if (t.peek(0) == '+' or t.peek(0) == '-') t.pos += 1;
        while (t.peek(0) != null and std.ascii.isDigit(t.peek(0).?)) t.pos += 1;
        if (t.peek(0) == '.' and t.peek(1) != null and std.ascii.isDigit(t.peek(1).?)) {
            integer = false;
            t.pos += 2;
            while (t.peek(0) != null and std.ascii.isDigit(t.peek(0).?)) t.pos += 1;
        }
        if (t.peek(0) == 'e' or t.peek(0) == 'E') {
            var k: usize = 1;
            if (t.peek(1) == '+' or t.peek(1) == '-') k = 2;
            if (t.peek(k) != null and std.ascii.isDigit(t.peek(k).?)) {
                integer = false;
                t.pos += k;
                while (t.peek(0) != null and std.ascii.isDigit(t.peek(0).?)) t.pos += 1;
            }
        }
        const repr = t.src[start..t.pos];
        const value = std.fmt.parseFloat(f64, repr) catch 0;
        const num: Num = .{ .repr = repr, .value = value, .integer = integer };
        if (t.wouldStartIdent()) return .{ .dimension = .{ .num = num, .unit = try t.consumeName() } };
        if (t.peek(0) == '%') {
            t.pos += 1;
            return .{ .percentage = num };
        }
        return .{ .number = num };
    }

    fn consumeIdentLike(t: *Tokenizer) Error!Token {
        const name = try t.consumeName();
        if (std.ascii.eqlIgnoreCase(name, "url") and t.peek(0) == '(') {
            t.pos += 1;
            while (isWs(t.peek(0)) and isWs(t.peek(1))) t.pos += 1;
            const q0 = t.peek(0);
            const q1 = t.peek(1);
            if (q0 == '"' or q0 == '\'' or (isWs(q0) and (q1 == '"' or q1 == '\''))) return .{ .function = name };
            return t.consumeUrl();
        }
        if (t.peek(0) == '(') {
            t.pos += 1;
            return .{ .function = name };
        }
        return .{ .ident = name };
    }

    fn consumeString(t: *Tokenizer, quote: u8) Error!Token {
        // A string with no escape is a slice of the source.
        const start = t.pos;
        var scan = t.pos;
        while (scan < t.src.len) : (scan += 1) {
            const c = t.src[scan];
            if (c == quote) {
                t.pos = scan + 1;
                return .{ .string = t.src[start..scan] };
            }
            if (c == '\\' or c == '\n') break;
        }
        var out: std.ArrayList(u8) = .empty;
        try out.appendSlice(t.a, t.src[start..scan]);
        t.pos = scan;
        while (true) {
            const c = t.peek(0) orelse {
                t.queued = .{ .err = "eof-in-string" };
                return .{ .string = out.items };
            };
            if (c == quote) {
                t.pos += 1;
                return .{ .string = out.items };
            }
            if (c == '\n') return .bad_string; // the newline is reconsumed
            if (c == '\\') {
                t.pos += 1;
                const n = t.peek(0) orelse continue;
                if (n == '\n') {
                    t.pos += 1;
                    continue;
                }
                try t.consumeEscape(&out);
                continue;
            }
            try out.append(t.a, c);
            t.pos += 1;
        }
    }

    fn consumeUrl(t: *Tokenizer) Error!Token {
        var out: std.ArrayList(u8) = .empty;
        while (isWs(t.peek(0))) t.pos += 1;
        while (true) {
            const c = t.peek(0) orelse {
                t.queued = .{ .err = "eof-in-url" };
                return .{ .url = out.items };
            };
            if (c == ')') {
                t.pos += 1;
                return .{ .url = out.items };
            }
            if (isWs(c)) {
                while (isWs(t.peek(0))) t.pos += 1;
                const n = t.peek(0) orelse {
                    t.queued = .{ .err = "eof-in-url" };
                    return .{ .url = out.items };
                };
                if (n == ')') {
                    t.pos += 1;
                    return .{ .url = out.items };
                }
                t.consumeBadUrlRemnants();
                return .bad_url;
            }
            if (c == '"' or c == '\'' or c == '(' or c < 0x20 or c == 0x7f) {
                t.consumeBadUrlRemnants();
                return .bad_url;
            }
            if (c == '\\') {
                if (validEscape(c, t.peek(1))) {
                    t.pos += 1;
                    try t.consumeEscape(&out);
                    continue;
                }
                t.consumeBadUrlRemnants();
                return .bad_url;
            }
            try out.append(t.a, c);
            t.pos += 1;
        }
    }

    fn consumeBadUrlRemnants(t: *Tokenizer) void {
        while (true) {
            const c = t.peek(0) orelse return;
            t.pos += 1;
            if (c == ')') return;
            if (validEscape(c, t.peek(0))) {
                var scratch: std.ArrayList(u8) = .empty;
                t.consumeEscape(&scratch) catch {};
            }
        }
    }

    fn consumeUnicodeRange(t: *Tokenizer) Token {
        t.pos += 2; // u+
        var start: u32 = 0;
        var end: u32 = 0;
        var n: usize = 0;
        var questions: usize = 0;
        while (n < 6) : (n += 1) {
            const c = t.peek(0) orelse break;
            if (std.ascii.isHex(c) and questions == 0) {
                start = start * 16 + (std.fmt.charToDigit(c, 16) catch 0);
                end = start;
                t.pos += 1;
            } else if (c == '?') {
                start = start * 16;
                end = end * 16 + 15;
                questions += 1;
                t.pos += 1;
            } else break;
        }
        if (questions > 0) return .{ .unicode_range = .{ .start = start, .end = end } };
        if (t.peek(0) == '-' and t.peek(1) != null and std.ascii.isHex(t.peek(1).?)) {
            t.pos += 1;
            end = 0;
            n = 0;
            while (n < 6) : (n += 1) {
                const c = t.peek(0) orelse break;
                if (!std.ascii.isHex(c)) break;
                end = end * 16 + (std.fmt.charToDigit(c, 16) catch 0);
                t.pos += 1;
            }
        }
        return .{ .unicode_range = .{ .start = start, .end = end } };
    }
};

// ----------------------------------------------------------- the parser

pub const Value = union(enum) {
    token: Token,
    block: struct { kind: u8, values: []const Value },
    function: struct { name: []const u8, values: []const Value },
    /// An unmatched close token where a value was wanted: `)`, `]`, `}`.
    err: []const u8,
};

pub const Declaration = struct { name: []const u8, value: []const Value, important: bool };

/// A deep copy of values into `a`: every slice a token or a value holds
/// duplicated, so the copy outlives the parse that made the original
/// (a sheet parsed in a scratch arena and kept in another).
pub fn cloneValues(a: std.mem.Allocator, values: []const Value) std.mem.Allocator.Error![]const Value {
    const out = try a.alloc(Value, values.len);
    for (values, 0..) |v, i| out[i] = try cloneValue(a, v);
    return out;
}

pub fn cloneValue(a: std.mem.Allocator, v: Value) std.mem.Allocator.Error!Value {
    return switch (v) {
        .token => |t| .{ .token = try cloneToken(a, t) },
        .block => |b| .{ .block = .{ .kind = b.kind, .values = try cloneValues(a, b.values) } },
        .function => |f| .{ .function = .{ .name = try a.dupe(u8, f.name), .values = try cloneValues(a, f.values) } },
        .err => |e| .{ .err = try a.dupe(u8, e) },
    };
}

pub fn cloneToken(a: std.mem.Allocator, t: Token) std.mem.Allocator.Error!Token {
    return switch (t) {
        .ident => |x| .{ .ident = try a.dupe(u8, x) },
        .function => |x| .{ .function = try a.dupe(u8, x) },
        .at_keyword => |x| .{ .at_keyword = try a.dupe(u8, x) },
        .hash => |h| .{ .hash = .{ .value = try a.dupe(u8, h.value), .id = h.id } },
        .string => |x| .{ .string = try a.dupe(u8, x) },
        .url => |x| .{ .url = try a.dupe(u8, x) },
        .dimension => |d| .{ .dimension = .{ .num = d.num, .unit = try a.dupe(u8, d.unit) } },
        .err => |x| .{ .err = try a.dupe(u8, x) },
        else => t,
    };
}
pub const AtRule = struct {
    name: []const u8,
    prelude: []const Value,
    block: ?[]const Value,
    /// Direct mode (`parseStylesheetDirect`): a `@media`/`@supports`
    /// body as rules, any other body as items, and `block` empty — the
    /// body's tokens were never materialised as values.
    rules: ?[]const Rule = null,
    items: ?[]const Item = null,
};
pub const QualifiedRule = struct {
    prelude: []const Value,
    block: []const Value,
    /// Direct mode: the body's declarations and nested rules, parsed in
    /// place from the token stream; `block` is then empty.
    items: ?[]const Item = null,
};

/// A rule, or the record of one the parser could not make (a
/// qualified rule with no block before the end): consumers skip `err`.
pub const Rule = union(enum) { at: AtRule, qualified: QualifiedRule, err: []const u8 };

/// What a declaration list or a block's contents hold, in source
/// order; `err` is a syntax error the parser recovered from.
pub const Item = union(enum) { declaration: Declaration, at: AtRule, qualified: QualifiedRule, err: []const u8 };

pub const ParseError = error{ OutOfMemory, Empty, Invalid, ExtraInput };

/// The scratch the consume algorithms build their value lists on: one
/// stack, marked on entry and copied out exact on return, so a sheet's
/// arena holds each list once at its final size. A block's own list
/// growing by doubling in an arena that cannot take the old buffers
/// back cost Wikipedia's 198 KB bundle 9.7 MB (2026-09-18); the
/// cascade's per-block parsers share the sheet's stack.
pub const Scratch = std.ArrayList(Value);

pub const Parser = struct {
    a: std.mem.Allocator,
    tokens: []const Token,
    pos: usize = 0,
    /// Null until first use: a parser is returned by value from `init`,
    /// so its own stack is found by address only once it is in place.
    scratch: ?*Scratch = null,
    own_scratch: Scratch = .empty,
    /// The item and rule lists of direct mode, the same way: stacks
    /// marked on entry and copied out exact, since a list growing by
    /// doubling per rule body left 2.7 KB a rule behind in the arena.
    item_scratch: std.ArrayList(Item) = .empty,
    rule_scratch: std.ArrayList(Rule) = .empty,
    /// Sheet mode: rule bodies parsed in place (see `AtRule.rules`).
    /// A stylesheet's blocks materialised as values and re-flattened for
    /// every body held a token stream three times over; Wikipedia's
    /// 198 KB bundle needed 13 MB that way (2026-09-18).
    direct: bool = false,

    pub fn init(a: std.mem.Allocator, input: []const u8, unicode_ranges: bool) Error!Parser {
        var t = try Tokenizer.init(a, input);
        t.unicode_ranges = unicode_ranges;
        var list: std.ArrayList(Token) = .empty;
        // About a token per three bytes of CSS: one allocation, no doubling
        // — then shrunk to what came, in place (the last allocation).
        try list.ensureTotalCapacity(a, input.len / 3 + 16);
        while (true) {
            const tok = try t.next();
            if (tok == .eof) break;
            try list.append(a, tok);
        }
        list.shrinkAndFree(a, list.items.len);
        return .{ .a = a, .tokens = list.items, .scratch = null };
    }

    /// The scratch to hand a parser over this one's values (a block's
    /// contents parsed as rules or declarations): the same stack.
    pub fn scratchOf(p: *Parser) *Scratch {
        if (p.scratch == null) p.scratch = &p.own_scratch;
        return p.scratch.?;
    }

    fn mark(p: *Parser) usize {
        return p.scratchOf().items.len;
    }

    fn push(p: *Parser, v: Value) Error!void {
        try p.scratchOf().append(p.a, v);
    }

    /// The values pushed since `from`, copied out exact; the stack
    /// shrinks back to the mark.
    fn take(p: *Parser, from: usize) Error![]const Value {
        const st = p.scratchOf();
        const out = try p.a.dupe(Value, st.items[from..]);
        st.shrinkRetainingCapacity(from);
        return out;
    }

    /// A parser over component values already parsed (a block's
    /// contents): the values flattened back into their tokens, with no
    /// text to re-tokenize.
    pub fn fromValues(a: std.mem.Allocator, values: []const Value) Error!Parser {
        var list: std.ArrayList(Token) = .empty;
        try list.ensureTotalCapacity(a, countTokens(values));
        try flatten(a, values, &list);
        return .{ .a = a, .tokens = list.items, .scratch = null };
    }

    /// `fromValues` sharing a stack already grown (the enclosing sheet's).
    pub fn fromValuesScratch(a: std.mem.Allocator, values: []const Value, scratch: *Scratch) Error!Parser {
        var list: std.ArrayList(Token) = .empty;
        try list.ensureTotalCapacity(a, countTokens(values));
        try flatten(a, values, &list);
        return .{ .a = a, .tokens = list.items, .scratch = scratch };
    }

    fn countTokens(values: []const Value) usize {
        var n: usize = 0;
        for (values) |v| n += switch (v) {
            .token, .err => 1,
            .block => |b| 2 + countTokens(b.values),
            .function => |f| 2 + countTokens(f.values),
        };
        return n;
    }

    fn flatten(a: std.mem.Allocator, values: []const Value, out: *std.ArrayList(Token)) Error!void {
        for (values) |v| switch (v) {
            .token => |t| try out.append(a, t),
            .err => |e| try out.append(a, if (e.len == 1 and e[0] == '}') .close_curly else if (e.len == 1 and e[0] == ']') .close_square else .close_paren),
            .block => |b| {
                try out.append(a, switch (b.kind) {
                    '{' => .open_curly,
                    '[' => .open_square,
                    else => .open_paren,
                });
                try flatten(a, b.values, out);
                try out.append(a, switch (b.kind) {
                    '{' => .close_curly,
                    '[' => .close_square,
                    else => .close_paren,
                });
            },
            .function => |f| {
                try out.append(a, .{ .function = f.name });
                try flatten(a, f.values, out);
                try out.append(a, .close_paren);
            },
        };
    }

    fn peek(p: *const Parser) Token {
        return if (p.pos < p.tokens.len) p.tokens[p.pos] else .eof;
    }

    fn next(p: *Parser) Token {
        const t = p.peek();
        if (p.pos < p.tokens.len) p.pos += 1;
        return t;
    }

    fn skipWs(p: *Parser) void {
        while (p.peek() == .whitespace) p.pos += 1;
    }

    // --- the entry points

    /// A stylesheet with every rule body parsed in place: the cascade's
    /// entry (the corpus tests keep `parseStylesheet`, the spec's shape).
    pub fn parseStylesheetDirect(p: *Parser) Error![]const Rule {
        p.direct = true;
        return p.consumeListOfRules(true);
    }

    pub fn parseStylesheet(p: *Parser) Error![]const Rule {
        return p.consumeListOfRules(true);
    }

    pub fn parseListOfRules(p: *Parser) Error![]const Rule {
        return p.consumeListOfRules(false);
    }

    pub fn parseRule(p: *Parser) ParseError!Rule {
        p.skipWs();
        if (p.peek() == .eof) return error.Empty;
        const rule: Rule = if (p.peek() == .at_keyword) .{ .at = try p.consumeAtRule(false) } else .{ .qualified = (try p.consumeQualifiedRule(false)) orelse return error.Invalid };
        if (rule == .err) return error.Invalid;
        p.skipWs();
        if (p.peek() != .eof) return error.ExtraInput;
        return rule;
    }

    pub fn parseDeclaration(p: *Parser) ParseError!Declaration {
        p.skipWs();
        if (p.peek() == .eof) return error.Empty;
        if (p.peek() != .ident) return error.Invalid;
        return (try p.consumeDeclaration(false)) orelse error.Invalid;
    }

    /// The 2021 standard's "parse a list of declarations": declarations
    /// and at-rules, an error for anything else.
    pub fn parseListOfDeclarations(p: *Parser) Error![]const Item {
        var items: std.ArrayList(Item) = .empty;
        while (true) {
            switch (p.peek()) {
                .whitespace, .semicolon => p.pos += 1,
                .eof => return items.items,
                .at_keyword => try items.append(p.a, .{ .at = try p.consumeAtRule(true) }),
                .ident => {
                    // The declaration is parsed from the tokens up to the
                    // next semicolon, on their own.
                    const start = p.pos;
                    while (p.peek() != .semicolon and p.peek() != .eof) p.pos += 1;
                    var sub: Parser = .{ .a = p.a, .tokens = p.tokens[start..p.pos], .scratch = p.scratchOf() };
                    if (try sub.consumeDeclaration(false)) |d| try items.append(p.a, .{ .declaration = d }) else try items.append(p.a, .{ .err = "invalid" });
                },
                else => {
                    while (p.peek() != .semicolon and p.peek() != .eof) _ = try p.consumeComponentValue();
                    try items.append(p.a, .{ .err = "invalid" });
                },
            }
        }
    }

    /// The nesting-era "parse a block's contents": declarations, at-rules
    /// and qualified rules together, in source order.
    pub fn parseBlockContents(p: *Parser) Error![]const Item {
        var items: std.ArrayList(Item) = .empty;
        while (true) {
            switch (p.peek()) {
                .whitespace, .semicolon => p.pos += 1,
                .eof => return items.items,
                .at_keyword => try items.append(p.a, .{ .at = try p.consumeAtRule(true) }),
                else => {
                    const at = p.pos;
                    if (p.peek() == .ident) {
                        if (try p.consumeDeclaration(true)) |d| {
                            try items.append(p.a, .{ .declaration = d });
                            continue;
                        }
                    }
                    p.pos = at;
                    if (try p.consumeQualifiedRule(true)) |q| try items.append(p.a, .{ .qualified = q }) else try items.append(p.a, .{ .err = "invalid" });
                },
            }
        }
    }

    pub fn parseComponentValue(p: *Parser) ParseError!Value {
        p.skipWs();
        if (p.peek() == .eof) return error.Empty;
        const v = try p.consumeComponentValue();
        p.skipWs();
        if (p.peek() != .eof) return error.ExtraInput;
        return v;
    }

    pub fn parseListOfComponentValues(p: *Parser) Error![]const Value {
        const from = p.mark();
        while (p.peek() != .eof) try p.push(try p.consumeComponentValue());
        return p.take(from);
    }

    // --- the consume algorithms

    fn takeRules(p: *Parser, from: usize) Error![]const Rule {
        const out = try p.a.dupe(Rule, p.rule_scratch.items[from..]);
        p.rule_scratch.shrinkRetainingCapacity(from);
        return out;
    }

    fn takeItems(p: *Parser, from: usize) Error![]const Item {
        const out = try p.a.dupe(Item, p.item_scratch.items[from..]);
        p.item_scratch.shrinkRetainingCapacity(from);
        return out;
    }

    fn consumeListOfRules(p: *Parser, top_level: bool) Error![]const Rule {
        const from = p.rule_scratch.items.len;
        while (true) {
            switch (p.peek()) {
                .whitespace => p.pos += 1,
                .eof => return p.takeRules(from),
                // A nested list (an at-rule's body, parsed in place) ends
                // at its close brace, which is consumed.
                .close_curly => if (!top_level) {
                    p.pos += 1;
                    return p.takeRules(from);
                } else if (try p.consumeQualifiedRule(false)) |q| try p.rule_scratch.append(p.a, .{ .qualified = q }) else try p.rule_scratch.append(p.a, .{ .err = "invalid" }),
                .cdo, .cdc => {
                    if (top_level) {
                        p.pos += 1;
                        continue;
                    }
                    if (try p.consumeQualifiedRule(false)) |q| try p.rule_scratch.append(p.a, .{ .qualified = q }) else try p.rule_scratch.append(p.a, .{ .err = "invalid" });
                },
                .at_keyword => {
                    const at = try p.consumeAtRule(false);
                    try p.rule_scratch.append(p.a, .{ .at = at });
                },
                else => if (try p.consumeQualifiedRule(false)) |q| try p.rule_scratch.append(p.a, .{ .qualified = q }) else try p.rule_scratch.append(p.a, .{ .err = "invalid" }),
            }
        }
    }

    fn consumeAtRule(p: *Parser, nested: bool) Error!AtRule {
        const name = p.next().at_keyword;
        const from = p.mark();
        while (true) {
            switch (p.peek()) {
                .semicolon => {
                    p.pos += 1;
                    return .{ .name = name, .prelude = try p.take(from), .block = null };
                },
                .eof => return .{ .name = name, .prelude = try p.take(from), .block = null },
                .close_curly => {
                    if (nested) return .{ .name = name, .prelude = try p.take(from), .block = null };
                    p.pos += 1;
                    try p.push(.{ .err = "}" });
                },
                .open_curly => {
                    p.pos += 1;
                    const prelude = try p.take(from);
                    if (p.direct) {
                        if (std.ascii.eqlIgnoreCase(name, "media") or std.ascii.eqlIgnoreCase(name, "supports") or std.ascii.eqlIgnoreCase(name, "layer") or std.ascii.eqlIgnoreCase(name, "container") or std.ascii.eqlIgnoreCase(name, "scope")) {
                            return .{ .name = name, .prelude = prelude, .block = &.{}, .rules = try p.consumeListOfRules(false) };
                        }
                        return .{ .name = name, .prelude = prelude, .block = &.{}, .items = try p.consumeBlockItems() };
                    }
                    const block = try p.consumeSimpleBlock(.close_curly);
                    return .{ .name = name, .prelude = prelude, .block = block };
                },
                else => try p.push(try p.consumeComponentValue()),
            }
        }
    }

    /// A block's contents parsed in place (direct mode): declarations
    /// and nested rules up to the block's close brace, which is consumed.
    fn consumeBlockItems(p: *Parser) Error![]const Item {
        const from = p.item_scratch.items.len;
        while (true) {
            switch (p.peek()) {
                .whitespace, .semicolon => p.pos += 1,
                .eof => return p.takeItems(from),
                .close_curly => {
                    p.pos += 1;
                    return p.takeItems(from);
                },
                .at_keyword => {
                    const at = try p.consumeAtRule(true);
                    try p.item_scratch.append(p.a, .{ .at = at });
                },
                else => {
                    const at = p.pos;
                    if (p.peek() == .ident) {
                        if (try p.consumeDeclaration(true)) |d| {
                            try p.item_scratch.append(p.a, .{ .declaration = d });
                            continue;
                        }
                    }
                    p.pos = at;
                    if (try p.consumeQualifiedRule(true)) |q| try p.item_scratch.append(p.a, .{ .qualified = q }) else {
                        // Not a rule either: skip to the next `;` or the
                        // block's end rather than loop on the same token.
                        try p.item_scratch.append(p.a, .{ .err = "invalid" });
                        while (p.peek() != .eof and p.peek() != .semicolon and p.peek() != .close_curly) p.pos += 1;
                    }
                },
            }
        }
    }

    fn consumeQualifiedRule(p: *Parser, nested: bool) Error!?QualifiedRule {
        const from = p.mark();
        while (true) {
            switch (p.peek()) {
                .eof => {
                    p.scratchOf().shrinkRetainingCapacity(from);
                    return null;
                },
                .semicolon => {
                    if (nested) {
                        p.scratchOf().shrinkRetainingCapacity(from);
                        return null;
                    }
                    p.pos += 1;
                    try p.push(.{ .token = .semicolon });
                },
                .close_curly => {
                    if (nested) {
                        p.scratchOf().shrinkRetainingCapacity(from);
                        return null;
                    }
                    p.pos += 1;
                    try p.push(.{ .err = "}" });
                },
                .open_curly => {
                    p.pos += 1;
                    const prelude = try p.take(from);
                    if (p.direct) return .{ .prelude = prelude, .block = &.{}, .items = try p.consumeBlockItems() };
                    const block = try p.consumeSimpleBlock(.close_curly);
                    return .{ .prelude = prelude, .block = block };
                },
                else => try p.push(try p.consumeComponentValue()),
            }
        }
    }

    fn consumeSimpleBlock(p: *Parser, ending: std.meta.Tag(Token)) Error![]const Value {
        const from = p.mark();
        while (true) {
            const t = p.peek();
            if (t == .eof) return p.take(from);
            if (std.meta.activeTag(t) == ending) {
                p.pos += 1;
                return p.take(from);
            }
            try p.push(try p.consumeComponentValue());
        }
    }

    fn consumeFunction(p: *Parser, name: []const u8) Error!Value {
        const from = p.mark();
        while (true) {
            switch (p.peek()) {
                .eof => return .{ .function = .{ .name = name, .values = try p.take(from) } },
                .close_paren => {
                    p.pos += 1;
                    return .{ .function = .{ .name = name, .values = try p.take(from) } };
                },
                else => try p.push(try p.consumeComponentValue()),
            }
        }
    }

    fn consumeComponentValue(p: *Parser) Error!Value {
        const t = p.next();
        switch (t) {
            .open_curly => return .{ .block = .{ .kind = '{', .values = try p.consumeSimpleBlock(.close_curly) } },
            .open_square => return .{ .block = .{ .kind = '[', .values = try p.consumeSimpleBlock(.close_square) } },
            .open_paren => return .{ .block = .{ .kind = '(', .values = try p.consumeSimpleBlock(.close_paren) } },
            .function => |name| return p.consumeFunction(name),
            .close_curly => return .{ .err = "}" },
            .close_square => return .{ .err = "]" },
            .close_paren => return .{ .err = ")" },
            else => return .{ .token = t },
        }
    }

    fn consumeDeclaration(p: *Parser, nested: bool) Error!?Declaration {
        const name_tok = p.next();
        if (name_tok != .ident) return null;
        const name = name_tok.ident;
        p.skipWs();
        if (p.peek() != .colon) return null;
        p.pos += 1;
        p.skipWs();
        const from = p.mark();
        while (true) {
            switch (p.peek()) {
                .eof, .semicolon => break,
                .close_curly => {
                    if (nested) break;
                    p.pos += 1;
                    try p.push(.{ .err = "}" });
                },
                else => try p.push(try p.consumeComponentValue()),
            }
        }
        const st = p.scratchOf();
        var seg: []const Value = st.items[from..];
        // A top-level {}-block is a declaration's whole value or not a
        // declaration at all (a nested rule's prelude looked like one).
        if (nested) {
            var has_block = false;
            var has_other = false;
            for (seg) |v| {
                if (v == .block and v.block.kind == '{') has_block = true else if (!(v == .token and v.token == .whitespace)) has_other = true;
            }
            if (has_block and has_other) {
                st.shrinkRetainingCapacity(from);
                return null;
            }
        }
        // Trailing whitespace goes; `!important` is a flag, not a value.
        var important = false;
        seg = trimWs(seg);
        if (seg.len >= 2) {
            const last = seg[seg.len - 1];
            var i = seg.len - 2;
            while (i > 0 and seg[i] == .token and seg[i].token == .whitespace) i -= 1;
            const bang = seg[i];
            if (last == .token and last.token == .ident and std.ascii.eqlIgnoreCase(last.token.ident, "important") and bang == .token and bang.token == .delim and bang.token.delim == '!') {
                important = true;
                seg = trimWs(seg[0..i]);
            }
        }
        const value = try p.a.dupe(Value, seg);
        st.shrinkRetainingCapacity(from);
        return .{ .name = name, .value = value, .important = important };
    }

    fn trimWs(values: []const Value) []const Value {
        var n = values.len;
        while (n > 0) {
            const last = values[n - 1];
            if (last == .token and last.token == .whitespace) n -= 1 else break;
        }
        return values[0..n];
    }
};

// ------------------------------------------------------ text of values

/// Component values back as CSS text (the tokens' own form: a name's
/// escapes undone, a number's original spelling), for a consumer that
/// wants a selector's text or a value as written.
pub fn writeValues(a: std.mem.Allocator, values: []const Value, out: *std.ArrayList(u8)) Error!void {
    for (values) |v| try writeValue(a, v, out);
}

pub fn writeValue(a: std.mem.Allocator, v: Value, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .err => {},
        .block => |b| {
            try out.append(a, b.kind);
            try writeValues(a, b.values, out);
            try out.append(a, switch (b.kind) {
                '{' => '}',
                '[' => ']',
                else => ')',
            });
        },
        .function => |f| {
            try out.appendSlice(a, f.name);
            try out.append(a, '(');
            try writeValues(a, f.values, out);
            try out.append(a, ')');
        },
        .token => |t| switch (t) {
            .ident => |s| try out.appendSlice(a, s),
            .at_keyword => |s| {
                try out.append(a, '@');
                try out.appendSlice(a, s);
            },
            .hash => |h| {
                try out.append(a, '#');
                try out.appendSlice(a, h.value);
            },
            .string => |s| {
                try out.append(a, '"');
                for (s) |c| {
                    if (c == '"' or c == '\\') try out.append(a, '\\');
                    try out.append(a, c);
                }
                try out.append(a, '"');
            },
            .url => |s| {
                try out.appendSlice(a, "url(\"");
                try out.appendSlice(a, s);
                try out.appendSlice(a, "\")");
            },
            .delim => |c| try out.append(a, c),
            .number => |n| try out.appendSlice(a, n.repr),
            .percentage => |n| {
                try out.appendSlice(a, n.repr);
                try out.append(a, '%');
            },
            .dimension => |d| {
                try out.appendSlice(a, d.num.repr);
                try out.appendSlice(a, d.unit);
            },
            .whitespace => try out.append(a, ' '),
            .colon => try out.append(a, ':'),
            .semicolon => try out.append(a, ';'),
            .comma => try out.append(a, ','),
            .cdo => try out.appendSlice(a, "<!--"),
            .cdc => try out.appendSlice(a, "-->"),
            .unicode_range => |r| try out.print(a, "U+{X}-{X}", .{ r.start, r.end }),
            .function, .open_curly, .open_square, .open_paren, .close_curly, .close_square, .close_paren, .bad_string, .bad_url, .err, .eof => {},
        },
    }
}

pub fn valuesText(a: std.mem.Allocator, values: []const Value) Error![]const u8 {
    var out: std.ArrayList(u8) = .empty;
    try writeValues(a, values, &out);
    return std.mem.trim(u8, out.items, " ");
}

// ------------------------------------------------------------------ tests

test "css: tokens and a stylesheet" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = try Parser.init(a, "@import url(x.css); p.a > b::before { color: #f00 !important; margin: 1.5em 0 } /* c */ @media (max-width: 600px) { p { display: none } }", false);
    const rules = try p.parseStylesheet();
    try std.testing.expectEqual(@as(usize, 3), rules.len);
    try std.testing.expectEqualStrings("import", rules[0].at.name);
    try std.testing.expect(rules[0].at.block == null);
    try std.testing.expectEqualStrings("p.a > b::before", try valuesText(a, rules[1].qualified.prelude));
    var body: Parser = .{ .a = a, .tokens = &.{} };
    _ = &body;
    var inner = try Parser.init(a, "color: #f00 !important; margin: 1.5em 0", false);
    const decls = try inner.parseBlockContents();
    try std.testing.expectEqual(@as(usize, 2), decls.len);
    try std.testing.expect(decls[0].declaration.important);
    try std.testing.expectEqualStrings("#f00", try valuesText(a, decls[0].declaration.value));
    try std.testing.expectEqualStrings("1.5em 0", try valuesText(a, decls[1].declaration.value));
    try std.testing.expectEqualStrings("media", rules[2].at.name);
    try std.testing.expectEqualStrings("(max-width: 600px)", try valuesText(a, rules[2].at.prelude));
}

// The css-parsing-tests corpus: each file is one entry point; inputs and
// expected results alternate; both sides are serialized into the
// corpus's own JSON notation and compared as text.
const verbose = false;

test "css: the css-parsing-tests corpus, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const Kind = enum { component_value_list, one_component_value, declaration_list, blocks_contents, one_declaration, one_rule, rule_list, stylesheet };
    const files = [_]struct { name: []const u8, kind: Kind }{
        .{ .name = "component_value_list", .kind = .component_value_list },
        .{ .name = "one_component_value", .kind = .one_component_value },
        .{ .name = "declaration_list", .kind = .declaration_list },
        .{ .name = "blocks_contents", .kind = .blocks_contents },
        .{ .name = "one_declaration", .kind = .one_declaration },
        .{ .name = "one_rule", .kind = .one_rule },
        .{ .name = "rule_list", .kind = .rule_list },
        .{ .name = "stylesheet", .kind = .stylesheet },
    };
    var total: usize = 0;
    var passed: usize = 0;
    for (files) |f| {
        const path = try std.fmt.allocPrint(a, "tools/testdata/web/css-parsing-tests/{s}.json", .{f.name});
        const text = std.Io.Dir.cwd().readFileAlloc(io, path, a, .limited(4 << 20)) catch return error.SkipZigTest;
        const parsed = try std.json.parseFromSliceLeaky(std.json.Value, a, text, .{});
        const items = parsed.array.items;
        var i: usize = 0;
        while (i + 1 < items.len) : (i += 2) {
            total += 1;
            const input = items[i].string;
            var want: std.ArrayList(u8) = .empty;
            try writeJson(a, items[i + 1], &want);
            var got: std.ArrayList(u8) = .empty;
            var p = try Parser.init(a, input, true);
            switch (f.kind) {
                .component_value_list => try writeValuesJson(a, try p.parseListOfComponentValues(), &got),
                .one_component_value => if (p.parseComponentValue()) |v| try writeValueJson(a, v, &got) else |e| try writeParseError(a, e, &got),
                .declaration_list => try writeItemsJson(a, try p.parseListOfDeclarations(), &got),
                .blocks_contents => try writeItemsJson(a, try p.parseBlockContents(), &got),
                .one_declaration => if (p.parseDeclaration()) |d| try writeItemJson(a, .{ .declaration = d }, &got) else |e| try writeParseError(a, e, &got),
                .one_rule => if (p.parseRule()) |r| try writeRuleJson(a, r, &got) else |e| try writeParseError(a, e, &got),
                .rule_list => try writeRulesJson(a, try p.parseListOfRules(), &got),
                .stylesheet => try writeRulesJson(a, try p.parseStylesheet(), &got),
            }
            if (std.mem.eql(u8, got.items, want.items)) passed += 1 else if (verbose) std.debug.print("--- {s}: {s}\n got  {s}\n want {s}\n", .{ f.name, input, got.items, want.items });
        }
    }
    std.debug.print("css syntax: {d}/{d} of css-parsing-tests agree\n", .{ passed, total });
    // The floor is the count as of 2026-09-18; the fourteen left are the
    // corpus's pre-standard match tokens and lone-declaration whitespace.
    try std.testing.expect(passed >= 135);
}

fn writeParseError(a: std.mem.Allocator, e: ParseError, out: *std.ArrayList(u8)) Error!void {
    try out.appendSlice(a, switch (e) {
        error.Empty => "[\"error\",\"empty\"]",
        error.Invalid => "[\"error\",\"invalid\"]",
        error.ExtraInput => "[\"error\",\"extra-input\"]",
        error.OutOfMemory => return error.OutOfMemory,
    });
}

fn writeJsonString(a: std.mem.Allocator, s: []const u8, out: *std.ArrayList(u8)) Error!void {
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        else => if (c < 0x20) try out.print(a, "\\u{x:0>4}", .{c}) else try out.append(a, c),
    };
    try out.append(a, '"');
}

fn writeNumber(a: std.mem.Allocator, v: f64, out: *std.ArrayList(u8)) Error!void {
    try out.print(a, "{d}", .{if (v == 0) @as(f64, 0) else v}); // no "-0"
}

/// The expected side, from JSON.
fn writeJson(a: std.mem.Allocator, v: std.json.Value, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .null => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .integer => |i| try writeNumber(a, @floatFromInt(i), out),
        .float => |f| try writeNumber(a, f, out),
        .number_string => |s| try out.appendSlice(a, s),
        .string => |s| try writeJsonString(a, s, out),
        .array => |arr| {
            try out.append(a, '[');
            for (arr.items, 0..) |item, i| {
                if (i > 0) try out.append(a, ',');
                try writeJson(a, item, out);
            }
            try out.append(a, ']');
        },
        .object => try out.appendSlice(a, "{}"),
    }
}

fn writeNum(a: std.mem.Allocator, kind: []const u8, n: Num, out: *std.ArrayList(u8)) Error!void {
    try out.appendSlice(a, "[\"");
    try out.appendSlice(a, kind);
    try out.appendSlice(a, "\",");
    try writeJsonString(a, n.repr, out);
    try out.append(a, ',');
    try writeNumber(a, n.value, out);
    try out.appendSlice(a, if (n.integer) ",\"integer\"" else ",\"number\"");
}

fn writeTokenJson(a: std.mem.Allocator, t: Token, out: *std.ArrayList(u8)) Error!void {
    switch (t) {
        .ident => |s| {
            try out.appendSlice(a, "[\"ident\",");
            try writeJsonString(a, s, out);
            try out.append(a, ']');
        },
        .at_keyword => |s| {
            try out.appendSlice(a, "[\"at-keyword\",");
            try writeJsonString(a, s, out);
            try out.append(a, ']');
        },
        .hash => |h| {
            try out.appendSlice(a, "[\"hash\",");
            try writeJsonString(a, h.value, out);
            try out.appendSlice(a, if (h.id) ",\"id\"]" else ",\"unrestricted\"]");
        },
        .string => |s| {
            try out.appendSlice(a, "[\"string\",");
            try writeJsonString(a, s, out);
            try out.append(a, ']');
        },
        .url => |s| {
            try out.appendSlice(a, "[\"url\",");
            try writeJsonString(a, s, out);
            try out.append(a, ']');
        },
        .bad_string => try out.appendSlice(a, "[\"error\",\"bad-string\"]"),
        .bad_url => try out.appendSlice(a, "[\"error\",\"bad-url\"]"),
        .err => |e| {
            try out.appendSlice(a, "[\"error\",");
            try writeJsonString(a, e, out);
            try out.append(a, ']');
        },
        .delim => |c| try writeJsonString(a, &.{c}, out),
        .number => |n| {
            try writeNum(a, "number", n, out);
            try out.append(a, ']');
        },
        .percentage => |n| {
            try writeNum(a, "percentage", n, out);
            try out.append(a, ']');
        },
        .dimension => |d| {
            try writeNum(a, "dimension", d.num, out);
            try out.append(a, ',');
            try writeJsonString(a, d.unit, out);
            try out.append(a, ']');
        },
        .whitespace => try out.appendSlice(a, "\" \""),
        .cdo => try out.appendSlice(a, "\"<!--\""),
        .cdc => try out.appendSlice(a, "\"-->\""),
        .colon => try out.appendSlice(a, "\":\""),
        .semicolon => try out.appendSlice(a, "\";\""),
        .comma => try out.appendSlice(a, "\",\""),
        .unicode_range => |r| try out.print(a, "[\"unicode-range\",{d},{d}]", .{ r.start, r.end }),
        .function, .open_curly, .open_square, .open_paren, .close_curly, .close_square, .close_paren, .eof => try out.appendSlice(a, "\"?\""),
    }
}

fn writeValueJson(a: std.mem.Allocator, v: Value, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .token => |t| try writeTokenJson(a, t, out),
        .err => |e| {
            try out.appendSlice(a, "[\"error\",");
            try writeJsonString(a, e, out);
            try out.append(a, ']');
        },
        .block => |b| {
            try out.appendSlice(a, switch (b.kind) {
                '{' => "[\"{}\"",
                '[' => "[\"[]\"",
                else => "[\"()\"",
            });
            for (b.values) |x| {
                try out.append(a, ',');
                try writeValueJson(a, x, out);
            }
            try out.append(a, ']');
        },
        .function => |f| {
            try out.appendSlice(a, "[\"function\",");
            try writeJsonString(a, f.name, out);
            for (f.values) |x| {
                try out.append(a, ',');
                try writeValueJson(a, x, out);
            }
            try out.append(a, ']');
        },
    }
}

fn writeValuesJson(a: std.mem.Allocator, values: []const Value, out: *std.ArrayList(u8)) Error!void {
    try out.append(a, '[');
    for (values, 0..) |v, i| {
        if (i > 0) try out.append(a, ',');
        try writeValueJson(a, v, out);
    }
    try out.append(a, ']');
}

fn writeRuleJson(a: std.mem.Allocator, r: Rule, out: *std.ArrayList(u8)) Error!void {
    switch (r) {
        .err => |e| {
            try out.appendSlice(a, "[\"error\",");
            try writeJsonString(a, e, out);
            try out.append(a, ']');
        },
        .at => |at| {
            try out.appendSlice(a, "[\"at-rule\",");
            try writeJsonString(a, at.name, out);
            try out.append(a, ',');
            try writeValuesJson(a, at.prelude, out);
            try out.append(a, ',');
            if (at.block) |b| try writeValuesJson(a, b, out) else try out.appendSlice(a, "null");
            try out.append(a, ']');
        },
        .qualified => |q| {
            try out.appendSlice(a, "[\"qualified rule\",");
            try writeValuesJson(a, q.prelude, out);
            try out.append(a, ',');
            try writeValuesJson(a, q.block, out);
            try out.append(a, ']');
        },
    }
}

fn writeRulesJson(a: std.mem.Allocator, rules: []const Rule, out: *std.ArrayList(u8)) Error!void {
    try out.append(a, '[');
    for (rules, 0..) |r, i| {
        if (i > 0) try out.append(a, ',');
        try writeRuleJson(a, r, out);
    }
    try out.append(a, ']');
}

fn writeItemJson(a: std.mem.Allocator, item: Item, out: *std.ArrayList(u8)) Error!void {
    switch (item) {
        .declaration => |d| {
            try out.appendSlice(a, "[\"declaration\",");
            try writeJsonString(a, d.name, out);
            try out.append(a, ',');
            try writeValuesJson(a, d.value, out);
            try out.appendSlice(a, if (d.important) ",true]" else ",false]");
        },
        .at => |at| try writeRuleJson(a, .{ .at = at }, out),
        .qualified => |q| try writeRuleJson(a, .{ .qualified = q }, out),
        .err => |e| {
            try out.appendSlice(a, "[\"error\",");
            try writeJsonString(a, e, out);
            try out.append(a, ']');
        },
    }
}

fn writeItemsJson(a: std.mem.Allocator, items: []const Item, out: *std.ArrayList(u8)) Error!void {
    try out.append(a, '[');
    for (items, 0..) |item, i| {
        if (i > 0) try out.append(a, ',');
        try writeItemJson(a, item, out);
    }
    try out.append(a, ']');
}
