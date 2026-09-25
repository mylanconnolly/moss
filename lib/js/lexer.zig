//! ECMAScript 2023 lexical grammar (ECMA-262 §12): source text to
//! tokens. The lexer is driven by the parser, because the grammar's
//! goal symbol depends on syntactic context: a `/` is division after an
//! expression and a regular expression before one, and a `}` closes a
//! block or continues a template. So `next` scans under the ordinary
//! goal (InputElementDiv) and the parser asks for `rescanRegExp` or
//! `rescanTemplateContinuation` when it knows better. Every token
//! carries whether a line terminator preceded it — automatic semicolon
//! insertion and the restricted productions (`return\n x`) are decided
//! on that. Identifiers and strings are cooked (escapes decoded) into
//! the arena the lexer was given; the raw source is never edited.
const std = @import("std");

pub const Error = error{ SyntaxError, OutOfMemory };

pub const Kind = enum {
    eof,
    identifier, // an IdentifierName: reserved words are the parser's to judge
    private_name, // #name
    number,
    bigint,
    string,
    template, // `...` with no substitution
    template_head, // `...${
    template_middle, // }...${
    template_tail, // }...`
    regexp,
    // Punctuators.
    lbrace,
    rbrace,
    lparen,
    rparen,
    lbracket,
    rbracket,
    dot,
    ellipsis,
    semicolon,
    comma,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    eq_strict,
    ne_strict,
    plus,
    minus,
    star,
    slash,
    percent,
    star_star,
    plus_plus,
    minus_minus,
    shl,
    shr,
    ushr,
    amp,
    pipe,
    caret,
    bang,
    tilde,
    amp_amp,
    pipe_pipe,
    question_question,
    question,
    question_dot,
    colon,
    assign,
    plus_assign,
    minus_assign,
    star_assign,
    slash_assign,
    percent_assign,
    star_star_assign,
    shl_assign,
    shr_assign,
    ushr_assign,
    amp_assign,
    pipe_assign,
    caret_assign,
    amp_amp_assign,
    pipe_pipe_assign,
    question_question_assign,
    arrow,
};

pub const Token = struct {
    kind: Kind,
    /// Byte offsets into the source, [start, end).
    start: u32,
    end: u32,
    /// A line terminator (or a comment holding one) came before it.
    newline_before: bool = false,
    /// The cooked text: an identifier's name (escapes decoded), a
    /// string's or template's value, a regexp's pattern; a private
    /// name's without its `#`.
    text: []const u8 = "",
    /// A template with an invalid escape (only legal when tagged): the
    /// cooked text is undefined, the raw text is what remains.
    cooked_invalid: bool = false,
    /// A template's raw text; a regexp's flags; a bigint's digits.
    raw: []const u8 = "",
    /// A number's value.
    number: f64 = 0,
    /// The identifier's spelling used escapes (then it is never a
    /// keyword) — or a string or number used a legacy octal form, which
    /// strict code refuses.
    escaped: bool = false,
    legacy_octal: bool = false,

    pub fn is(t: Token, kind: Kind) bool {
        return t.kind == kind;
    }
    /// An identifier token spelling `word` without escapes: how the
    /// parser recognises keywords and contextual keywords.
    pub fn isWord(t: Token, word: []const u8) bool {
        return t.kind == .identifier and !t.escaped and std.mem.eql(u8, t.text, word);
    }
};

pub const Lexer = struct {
    src: []const u8,
    pos: u32 = 0,
    a: std.mem.Allocator,
    /// The last error's message and where.
    err: []const u8 = "",
    err_at: u32 = 0,
    /// Module code: HTML-like comments are not recognised.
    module: bool = false,

    pub fn init(a: std.mem.Allocator, src: []const u8) Lexer {
        var l: Lexer = .{ .src = src, .a = a };
        // A hashbang comment is the first line, when it is one.
        if (src.len >= 2 and src[0] == '#' and src[1] == '!') {
            while (l.pos < src.len and !isLineTerminatorAt(src, l.pos)) l.pos += 1;
        }
        return l;
    }

    pub const State = struct { pos: u32 };
    pub fn save(l: *const Lexer) State {
        return .{ .pos = l.pos };
    }
    pub fn restore(l: *Lexer, s: State) void {
        l.pos = s.pos;
    }

    fn fail(l: *Lexer, msg: []const u8, at: u32) Error {
        l.err = msg;
        l.err_at = at;
        return error.SyntaxError;
    }

    fn peekByte(l: *const Lexer, off: u32) u8 {
        const i = l.pos + off;
        return if (i < l.src.len) l.src[i] else 0;
    }

    /// Skip whitespace and comments; whether a line terminator was
    /// crossed.
    fn skipTrivia(l: *Lexer) Error!bool {
        var newline = false;
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\n' or c == '\r') {
                newline = true;
                l.pos += 1;
                continue;
            }
            if (c == ' ' or c == '\t' or c == 0x0b or c == 0x0c) {
                l.pos += 1;
                continue;
            }
            if (c == '/' and l.peekByte(1) == '/') {
                l.pos += 2;
                while (l.pos < l.src.len and !isLineTerminatorAt(l.src, l.pos)) l.pos += 1;
                continue;
            }
            if (c == '/' and l.peekByte(1) == '*') {
                const at = l.pos;
                l.pos += 2;
                while (true) {
                    if (l.pos >= l.src.len) return l.fail("unterminated comment", at);
                    if (l.src[l.pos] == '*' and l.peekByte(1) == '/') {
                        l.pos += 2;
                        break;
                    }
                    if (isLineTerminatorAt(l.src, l.pos)) newline = true;
                    l.pos += 1;
                }
                continue;
            }
            // Annex B: `<!--` anywhere and `-->` at a line's start are
            // single-line comments in script code.
            if (!l.module and c == '<' and l.peekByte(1) == '!' and l.peekByte(2) == '-' and l.peekByte(3) == '-') {
                while (l.pos < l.src.len and !isLineTerminatorAt(l.src, l.pos)) l.pos += 1;
                continue;
            }
            if (!l.module and c == '-' and l.peekByte(1) == '-' and l.peekByte(2) == '>' and (newline or l.atLineStart())) {
                while (l.pos < l.src.len and !isLineTerminatorAt(l.src, l.pos)) l.pos += 1;
                continue;
            }
            if (c >= 0x80) {
                const cp = decode(l.src, l.pos) orelse return l.fail("bad UTF-8", l.pos);
                if (cp.cp == 0x2028 or cp.cp == 0x2029) {
                    newline = true;
                    l.pos += cp.len;
                    continue;
                }
                if (isSpaceCp(cp.cp)) {
                    l.pos += cp.len;
                    continue;
                }
            }
            break;
        }
        return newline;
    }

    /// Only whitespace (and comments) before this point on its line.
    fn atLineStart(l: *const Lexer) bool {
        var i = l.pos;
        while (i > 0) {
            i -= 1;
            const c = l.src[i];
            if (c == '\n' or c == '\r') return true;
            if (c == ' ' or c == '\t') continue;
            return false;
        }
        return true;
    }

    /// The next token under the InputElementDiv goal.
    pub fn next(l: *Lexer) Error!Token {
        const newline = try l.skipTrivia();
        const start = l.pos;
        if (l.pos >= l.src.len) return .{ .kind = .eof, .start = start, .end = start, .newline_before = newline };
        var t = try l.scan();
        t.newline_before = newline;
        return t;
    }

    fn tok(l: *Lexer, kind: Kind, start: u32, len: u32) Token {
        l.pos = start + len;
        return .{ .kind = kind, .start = start, .end = l.pos };
    }

    fn scan(l: *Lexer) Error!Token {
        const start = l.pos;
        const c = l.src[start];
        const c1 = l.peekByte(1);
        const c2 = l.peekByte(2);
        const c3 = l.peekByte(3);
        switch (c) {
            '{' => return l.tok(.lbrace, start, 1),
            '}' => return l.tok(.rbrace, start, 1),
            '(' => return l.tok(.lparen, start, 1),
            ')' => return l.tok(.rparen, start, 1),
            '[' => return l.tok(.lbracket, start, 1),
            ']' => return l.tok(.rbracket, start, 1),
            ';' => return l.tok(.semicolon, start, 1),
            ',' => return l.tok(.comma, start, 1),
            ':' => return l.tok(.colon, start, 1),
            '~' => return l.tok(.tilde, start, 1),
            '.' => {
                if (c1 == '.' and c2 == '.') return l.tok(.ellipsis, start, 3);
                if (c1 >= '0' and c1 <= '9') return l.scanNumber();
                return l.tok(.dot, start, 1);
            },
            '<' => {
                if (c1 == '<') return if (c2 == '=') l.tok(.shl_assign, start, 3) else l.tok(.shl, start, 2);
                if (c1 == '=') return l.tok(.le, start, 2);
                return l.tok(.lt, start, 1);
            },
            '>' => {
                if (c1 == '>') {
                    if (c2 == '>') return if (c3 == '=') l.tok(.ushr_assign, start, 4) else l.tok(.ushr, start, 3);
                    return if (c2 == '=') l.tok(.shr_assign, start, 3) else l.tok(.shr, start, 2);
                }
                if (c1 == '=') return l.tok(.ge, start, 2);
                return l.tok(.gt, start, 1);
            },
            '=' => {
                if (c1 == '=') return if (c2 == '=') l.tok(.eq_strict, start, 3) else l.tok(.eq, start, 2);
                if (c1 == '>') return l.tok(.arrow, start, 2);
                return l.tok(.assign, start, 1);
            },
            '!' => {
                if (c1 == '=') return if (c2 == '=') l.tok(.ne_strict, start, 3) else l.tok(.ne, start, 2);
                return l.tok(.bang, start, 1);
            },
            '+' => {
                if (c1 == '+') return l.tok(.plus_plus, start, 2);
                if (c1 == '=') return l.tok(.plus_assign, start, 2);
                return l.tok(.plus, start, 1);
            },
            '-' => {
                if (c1 == '-') return l.tok(.minus_minus, start, 2);
                if (c1 == '=') return l.tok(.minus_assign, start, 2);
                return l.tok(.minus, start, 1);
            },
            '*' => {
                if (c1 == '*') return if (c2 == '=') l.tok(.star_star_assign, start, 3) else l.tok(.star_star, start, 2);
                if (c1 == '=') return l.tok(.star_assign, start, 2);
                return l.tok(.star, start, 1);
            },
            '/' => return if (c1 == '=') l.tok(.slash_assign, start, 2) else l.tok(.slash, start, 1),
            '%' => return if (c1 == '=') l.tok(.percent_assign, start, 2) else l.tok(.percent, start, 1),
            '&' => {
                if (c1 == '&') return if (c2 == '=') l.tok(.amp_amp_assign, start, 3) else l.tok(.amp_amp, start, 2);
                if (c1 == '=') return l.tok(.amp_assign, start, 2);
                return l.tok(.amp, start, 1);
            },
            '|' => {
                if (c1 == '|') return if (c2 == '=') l.tok(.pipe_pipe_assign, start, 3) else l.tok(.pipe_pipe, start, 2);
                if (c1 == '=') return l.tok(.pipe_assign, start, 2);
                return l.tok(.pipe, start, 1);
            },
            '^' => return if (c1 == '=') l.tok(.caret_assign, start, 2) else l.tok(.caret, start, 1),
            '?' => {
                if (c1 == '?') return if (c2 == '=') l.tok(.question_question_assign, start, 3) else l.tok(.question_question, start, 2);
                // `?.` only when not followed by a digit (`a?.5:b`).
                if (c1 == '.' and !(c2 >= '0' and c2 <= '9')) return l.tok(.question_dot, start, 2);
                return l.tok(.question, start, 1);
            },
            '"', '\'' => return l.scanString(c),
            '`' => return l.scanTemplate(start, .template, .template_head),
            '#' => {
                l.pos += 1;
                if (l.pos >= l.src.len or !(try l.identifierStartAt(l.pos))) return l.fail("a private name needs an identifier", start);
                var t = try l.scanIdentifier();
                t.kind = .private_name;
                t.start = start;
                // The text keeps the '#': a private name never collides
                // with an identifier in any table keyed by name.
                t.text = try std.mem.concat(l.a, u8, &.{ "#", t.text });
                return t;
            },
            '0'...'9' => return l.scanNumber(),
            else => {
                if (try l.identifierStartAt(start)) return l.scanIdentifier();
                return l.fail("unexpected character", start);
            },
        }
    }

    // ----------------------------------------------------- identifiers

    fn identifierStartAt(l: *Lexer, at: u32) Error!bool {
        const c = l.src[at];
        if (c == '$' or c == '_' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return true;
        if (c == '\\') return true;
        if (c >= 0x80) {
            const cp = decode(l.src, at) orelse return l.fail("bad UTF-8", at);
            return isIdStart(cp.cp);
        }
        return false;
    }

    /// An IdentifierName: cooked when it holds `\u` escapes, else a
    /// slice of the source.
    fn scanIdentifier(l: *Lexer) Error!Token {
        const start = l.pos;
        var cooked: ?std.ArrayList(u8) = null;
        var first = true;
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            var cp: u21 = c;
            var len: u32 = 1;
            if (c == '\\') {
                if (l.peekByte(1) != 'u') return l.fail("bad escape in identifier", l.pos);
                if (cooked == null) {
                    cooked = .empty;
                    try cooked.?.appendSlice(l.a, l.src[start..l.pos]);
                }
                l.pos += 2;
                cp = try l.scanUnicodeEscape();
                if (if (first) !isIdStart(cp) else !isIdContinue(cp)) return l.fail("escape is not an identifier character", start);
                var buf: [4]u8 = undefined;
                const n = std.unicode.utf8Encode(cp, &buf) catch return l.fail("bad code point", start);
                try cooked.?.appendSlice(l.a, buf[0..n]);
                first = false;
                continue;
            }
            if (c >= 0x80) {
                const d = decode(l.src, l.pos) orelse return l.fail("bad UTF-8", l.pos);
                cp = d.cp;
                len = d.len;
            }
            const ok = if (first) isIdStart(cp) else isIdContinue(cp);
            if (!ok) break;
            if (cooked) |*ck| try ck.appendSlice(l.a, l.src[l.pos .. l.pos + len]);
            l.pos += len;
            first = false;
        }
        return .{ .kind = .identifier, .start = start, .end = l.pos, .text = if (cooked) |ck| ck.items else l.src[start..l.pos], .escaped = cooked != null };
    }

    /// After `\u`: `XXXX` or `{X...}`.
    fn scanUnicodeEscape(l: *Lexer) Error!u21 {
        const at = l.pos;
        if (l.peekByte(0) == '{') {
            l.pos += 1;
            var v: u32 = 0;
            var n: usize = 0;
            while (l.pos < l.src.len and l.src[l.pos] != '}') : (l.pos += 1) {
                const h = hexVal(l.src[l.pos]) orelse return l.fail("bad unicode escape", at);
                v = v * 16 + h;
                n += 1;
                if (v > 0x10ffff) return l.fail("unicode escape out of range", at);
            }
            if (n == 0 or l.pos >= l.src.len) return l.fail("bad unicode escape", at);
            l.pos += 1;
            return @intCast(v);
        }
        var v: u32 = 0;
        for (0..4) |_| {
            const h = hexVal(l.peekByte(0)) orelse return l.fail("bad unicode escape", at);
            v = v * 16 + h;
            l.pos += 1;
        }
        return @intCast(v);
    }

    // --------------------------------------------------------- numbers

    fn scanNumber(l: *Lexer) Error!Token {
        const start = l.pos;
        var t: Token = .{ .kind = .number, .start = start, .end = start };
        const c = l.src[start];
        if (c == '0' and (l.peekByte(1) | 0x20) == 'x') {
            l.pos += 2;
            t.number = @floatFromInt(try l.scanRadixDigits(16, start));
            return l.finishNumber(t, start, true);
        }
        if (c == '0' and (l.peekByte(1) | 0x20) == 'o') {
            l.pos += 2;
            t.number = @floatFromInt(try l.scanRadixDigits(8, start));
            return l.finishNumber(t, start, true);
        }
        if (c == '0' and (l.peekByte(1) | 0x20) == 'b') {
            l.pos += 2;
            t.number = @floatFromInt(try l.scanRadixDigits(2, start));
            return l.finishNumber(t, start, true);
        }
        if (c == '0' and l.peekByte(1) >= '0' and l.peekByte(1) <= '9') {
            // Legacy octal (`017`) — or a decimal with a leading zero
            // (`089`), both sloppy-only.
            l.pos += 1;
            var octal = true;
            const ds = l.pos;
            while (l.pos < l.src.len and l.src[l.pos] >= '0' and l.src[l.pos] <= '9') : (l.pos += 1) {
                if (l.src[l.pos] >= '8') octal = false;
            }
            t.legacy_octal = true;
            if (octal) {
                var v: f64 = 0;
                for (l.src[ds..l.pos]) |d| v = v * 8 + @as(f64, @floatFromInt(d - '0'));
                t.number = v;
                return l.finishNumber(t, start, false);
            }
            // Decimal with a leading zero may still have a fraction/exponent.
            try l.scanDecimalRest();
            t.number = std.fmt.parseFloat(f64, l.src[ds..l.pos]) catch return l.fail("bad number", start);
            return l.finishNumber(t, start, false);
        }
        // Decimal: a separator cannot follow a leading zero (`0_1`).
        if (c == '0' and l.peekByte(1) == '_') return l.fail("misplaced numeric separator", start);
        if (c != '.') try l.scanDigits(start);
        try l.scanDecimalRest();
        var buf: [512]u8 = undefined;
        const text = stripSeparators(l.src[start..l.pos], &buf) orelse return l.fail("number too long", start);
        // BigInt: digits only, no fraction or exponent.
        if (l.peekByte(0) == 'n') {
            for (text) |d| if (d < '0' or d > '9') return l.fail("a BigInt has no fraction or exponent", start);
            l.pos += 1;
            t.kind = .bigint;
            t.raw = try l.a.dupe(u8, text);
            return l.finishNumber(t, start, false);
        }
        t.number = std.fmt.parseFloat(f64, if (text[0] == '.') blk: {
            // "0." + rest so the parser sees a leading digit.
            break :blk text;
        } else text) catch return l.fail("bad number", start);
        return l.finishNumber(t, start, false);
    }

    /// The fraction and exponent of a decimal, if present.
    fn scanDecimalRest(l: *Lexer) Error!void {
        if (l.peekByte(0) == '.') {
            l.pos += 1;
            if (l.peekByte(0) >= '0' and l.peekByte(0) <= '9') try l.scanDigits(l.pos);
        }
        if ((l.peekByte(0) | 0x20) == 'e') {
            const at = l.pos;
            l.pos += 1;
            if (l.peekByte(0) == '+' or l.peekByte(0) == '-') l.pos += 1;
            if (!(l.peekByte(0) >= '0' and l.peekByte(0) <= '9')) return l.fail("exponent needs digits", at);
            try l.scanDigits(l.pos);
        }
    }

    /// Decimal digits with `_` separators between digits.
    fn scanDigits(l: *Lexer, at: u32) Error!void {
        var last_sep = false;
        var any = false;
        while (l.pos < l.src.len) : (l.pos += 1) {
            const c = l.src[l.pos];
            if (c >= '0' and c <= '9') {
                any = true;
                last_sep = false;
            } else if (c == '_') {
                if (!any or last_sep) return l.fail("misplaced numeric separator", at);
                last_sep = true;
            } else break;
        }
        if (last_sep) return l.fail("misplaced numeric separator", at);
    }

    fn scanRadixDigits(l: *Lexer, radix: u8, at: u32) Error!u64 {
        var v: u64 = 0;
        var any = false;
        var last_sep = false;
        while (l.pos < l.src.len) : (l.pos += 1) {
            const c = l.src[l.pos];
            if (c == '_') {
                if (!any or last_sep) return l.fail("misplaced numeric separator", at);
                last_sep = true;
                continue;
            }
            const d = hexVal(c) orelse break;
            if (d >= radix) break;
            v = v *% radix +% d;
            any = true;
            last_sep = false;
        }
        if (!any or last_sep) return l.fail("digits expected", at);
        return v;
    }

    fn finishNumber(l: *Lexer, t_in: Token, start: u32, radix_form: bool) Error!Token {
        var t = t_in;
        if (radix_form and l.peekByte(0) == 'n') {
            l.pos += 1;
            t.kind = .bigint;
            t.raw = l.src[start..l.pos];
        }
        // A number runs straight into an identifier or digit: an error
        // (`3in x`, `0x1g`).
        if (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if ((c >= '0' and c <= '9') or c == '$' or c == '_' or c == '\\' or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')) return l.fail("identifier starts immediately after a number", start);
            if (c >= 0x80) if (decode(l.src, l.pos)) |d| if (isIdStart(d.cp)) return l.fail("identifier starts immediately after a number", start);
        }
        t.end = l.pos;
        return t;
    }

    // --------------------------------------------------------- strings

    fn scanString(l: *Lexer, quote: u8) Error!Token {
        const start = l.pos;
        l.pos += 1;
        var out: std.ArrayList(u8) = .empty;
        var t: Token = .{ .kind = .string, .start = start, .end = start };
        while (true) {
            if (l.pos >= l.src.len) return l.fail("unterminated string", start);
            const c = l.src[l.pos];
            if (c == quote) {
                l.pos += 1;
                break;
            }
            if (c == '\n' or c == '\r') return l.fail("unterminated string", start);
            if (c == '\\') {
                l.pos += 1;
                const r = try l.scanEscape(&out, false);
                if (r == .legacy_octal) t.legacy_octal = true;
                continue;
            }
            try out.append(l.a, c);
            l.pos += 1;
        }
        t.end = l.pos;
        t.text = out.items;
        return t;
    }

    const EscapeResult = enum { ok, legacy_octal, invalid };

    /// After a backslash: decode the escape into `out`. In a template,
    /// an invalid escape is reported rather than failed (tagged
    /// templates accept it).
    fn scanEscape(l: *Lexer, out: *std.ArrayList(u8), in_template: bool) Error!EscapeResult {
        const at = l.pos - 1;
        if (l.pos >= l.src.len) return l.fail("unterminated escape", at);
        const c = l.src[l.pos];
        l.pos += 1;
        switch (c) {
            'n' => try out.append(l.a, '\n'),
            't' => try out.append(l.a, '\t'),
            'r' => try out.append(l.a, '\r'),
            'b' => try out.append(l.a, 0x08),
            'f' => try out.append(l.a, 0x0c),
            'v' => try out.append(l.a, 0x0b),
            '\r' => {
                if (l.peekByte(0) == '\n') l.pos += 1;
            },
            '\n' => {},
            'x' => {
                const h1 = hexVal(l.peekByte(0));
                const h2 = hexVal(l.peekByte(1));
                if (h1 == null or h2 == null) {
                    if (in_template) return .invalid;
                    return l.fail("bad hex escape", at);
                }
                l.pos += 2;
                try appendCp(l.a, out, h1.? * 16 + h2.?);
            },
            'u' => {
                const mark = l.pos;
                const cp = l.scanUnicodeEscape() catch |e| switch (e) {
                    error.SyntaxError => {
                        if (in_template) {
                            l.pos = mark;
                            return .invalid;
                        }
                        return e;
                    },
                    else => return e,
                };
                try appendCp(l.a, out, cp);
            },
            '0'...'7' => {
                // `\0` not followed by a digit is NUL; other octal
                // escapes are legacy (sloppy strings only, never
                // templates).
                const after = l.peekByte(0);
                if (c == '0' and !(after >= '0' and after <= '9')) {
                    try out.append(l.a, 0);
                    return .ok;
                }
                if (in_template) return .invalid;
                var v: u32 = c - '0';
                if (after >= '0' and after <= '7') {
                    v = v * 8 + (after - '0');
                    l.pos += 1;
                    const n2 = l.peekByte(0);
                    if (c <= '3' and n2 >= '0' and n2 <= '7') {
                        v = v * 8 + (n2 - '0');
                        l.pos += 1;
                    }
                }
                try appendCp(l.a, out, @intCast(v));
                return .legacy_octal;
            },
            '8', '9' => {
                if (in_template) return .invalid;
                try out.append(l.a, c);
                return .legacy_octal;
            },
            else => {
                if (c >= 0x80) {
                    const d = decode(l.src, l.pos - 1) orelse return l.fail("bad UTF-8", at);
                    if (d.cp == 0x2028 or d.cp == 0x2029) {
                        l.pos = l.pos - 1 + d.len;
                        return .ok;
                    }
                    try out.appendSlice(l.a, l.src[l.pos - 1 .. l.pos - 1 + d.len]);
                    l.pos = l.pos - 1 + d.len;
                    return .ok;
                }
                try out.append(l.a, c);
            },
        }
        return .ok;
    }

    // ------------------------------------------------------- templates

    /// From a backtick or a `}` continuing a template: the characters up
    /// to the closing backtick or the next `${`.
    fn scanTemplate(l: *Lexer, start: u32, whole: Kind, head: Kind) Error!Token {
        l.pos = start + 1;
        var out: std.ArrayList(u8) = .empty;
        var invalid = false;
        const raw_start = l.pos;
        var raw_buf: std.ArrayList(u8) = .empty;
        var raw_needs_copy = false;
        while (true) {
            if (l.pos >= l.src.len) return l.fail("unterminated template", start);
            const c = l.src[l.pos];
            if (c == '`') {
                const raw = if (raw_needs_copy) raw_buf.items else l.src[raw_start..l.pos];
                l.pos += 1;
                return .{ .kind = whole, .start = start, .end = l.pos, .text = out.items, .raw = raw, .cooked_invalid = invalid };
            }
            if (c == '$' and l.peekByte(1) == '{') {
                const raw = if (raw_needs_copy) raw_buf.items else l.src[raw_start..l.pos];
                l.pos += 2;
                return .{ .kind = head, .start = start, .end = l.pos, .text = out.items, .raw = raw, .cooked_invalid = invalid };
            }
            if (c == '\\') {
                const esc_start = l.pos;
                l.pos += 1;
                const r = try l.scanEscape(&out, true);
                if (r == .invalid) {
                    invalid = true;
                    // The raw text keeps the escape as written; skip to
                    // its end without cooking.
                    if (l.pos < l.src.len and l.src[l.pos] != '`' and !(l.src[l.pos] == '$' and l.peekByte(1) == '{')) l.pos += 1;
                }
                if (raw_needs_copy) try raw_buf.appendSlice(l.a, l.src[esc_start..l.pos]);
                continue;
            }
            // A CR or CRLF in a template is a LF, cooked and raw both.
            if (c == '\r') {
                if (!raw_needs_copy) {
                    try raw_buf.appendSlice(l.a, l.src[raw_start..l.pos]);
                    raw_needs_copy = true;
                }
                try out.append(l.a, '\n');
                try raw_buf.append(l.a, '\n');
                l.pos += if (l.peekByte(1) == '\n') 2 else 1;
                continue;
            }
            try out.append(l.a, c);
            if (raw_needs_copy) try raw_buf.append(l.a, c);
            l.pos += 1;
        }
    }

    /// The parser saw `}` while a template's substitution was open: the
    /// rest of the template from there.
    pub fn rescanTemplateContinuation(l: *Lexer, rbrace: Token) Error!Token {
        return l.scanTemplate(rbrace.start, .template_tail, .template_middle);
    }

    // --------------------------------------------------------- regexps

    /// The parser saw `/` or `/=` where an expression starts: a regular
    /// expression literal from there. Its body is not validated here
    /// (the RegExp compiler does that); its shape is.
    pub fn rescanRegExp(l: *Lexer, slash: Token) Error!Token {
        const start = slash.start;
        l.pos = start + 1;
        var in_class = false;
        while (true) {
            if (l.pos >= l.src.len or isLineTerminatorAt(l.src, l.pos)) return l.fail("unterminated regular expression", start);
            const c = l.src[l.pos];
            if (c == '\\') {
                l.pos += 1;
                if (l.pos >= l.src.len or isLineTerminatorAt(l.src, l.pos)) return l.fail("unterminated regular expression", start);
                l.pos += utf8Len(l.src[l.pos]);
                continue;
            }
            if (c == '[') in_class = true else if (c == ']') in_class = false else if (c == '/' and !in_class) break;
            l.pos += utf8Len(c);
        }
        const body_end = l.pos;
        l.pos += 1;
        const flags_start = l.pos;
        while (l.pos < l.src.len) {
            const c = l.src[l.pos];
            if (c == '\\') return l.fail("regular expression flags cannot use escapes", flags_start);
            if (c >= 0x80) {
                const d = decode(l.src, l.pos) orelse return l.fail("bad UTF-8", l.pos);
                if (!isIdContinue(d.cp)) break;
                l.pos += d.len;
                continue;
            }
            if (!((c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or (c >= '0' and c <= '9') or c == '$' or c == '_')) break;
            l.pos += 1;
        }
        const flags = l.src[flags_start..l.pos];
        var seen: u32 = 0;
        for (flags) |f| {
            const bit: u32 = switch (f) {
                'd' => 1,
                'g' => 2,
                'i' => 4,
                'm' => 8,
                's' => 16,
                'u' => 32,
                'v' => 64,
                'y' => 128,
                else => return l.fail("unknown regular expression flag", flags_start),
            };
            if (seen & bit != 0) return l.fail("repeated regular expression flag", flags_start);
            seen |= bit;
        }
        if (seen & 32 != 0 and seen & 64 != 0) return l.fail("regular expression flags u and v together", flags_start);
        return .{ .kind = .regexp, .start = start, .end = l.pos, .text = l.src[start + 1 .. body_end], .raw = flags };
    }
};

// ---------------------------------------------------------- characters

const Decoded = struct { cp: u21, len: u32 };

fn decode(src: []const u8, at: u32) ?Decoded {
    const len = std.unicode.utf8ByteSequenceLength(src[at]) catch return null;
    if (at + len > src.len) return null;
    const cp = std.unicode.utf8Decode(src[at .. at + len]) catch return null;
    return .{ .cp = cp, .len = len };
}

fn utf8Len(first: u8) u32 {
    return std.unicode.utf8ByteSequenceLength(first) catch 1;
}

fn isLineTerminatorAt(src: []const u8, at: u32) bool {
    const c = src[at];
    if (c == '\n' or c == '\r') return true;
    // U+2028 and U+2029: E2 80 A8 / E2 80 A9.
    return c == 0xe2 and at + 2 < src.len and src[at + 1] == 0x80 and (src[at + 2] == 0xa8 or src[at + 2] == 0xa9);
}

/// White space beyond ASCII: NBSP, the BOM, and Unicode's Zs.
fn isSpaceCp(cp: u21) bool {
    return switch (cp) {
        0xa0, 0xfeff, 0x1680, 0x2000...0x200a, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn hexVal(c: u8) ?u8 {
    return switch (c) {
        '0'...'9' => c - '0',
        'a'...'f' => c - 'a' + 10,
        'A'...'F' => c - 'A' + 10,
        else => null,
    };
}

fn appendCp(a: std.mem.Allocator, out: *std.ArrayList(u8), cp: u21) Error!void {
    var buf: [4]u8 = undefined;
    // A lone surrogate from `\uD800` has no UTF-8 form; it is kept as
    // the WTF-8 sequence the string layer reads back as UTF-16.
    const n = std.unicode.wtf8Encode(cp, &buf) catch return error.SyntaxError;
    try out.appendSlice(a, buf[0..n]);
}

/// Copy a numeric literal without its `_` separators.
fn stripSeparators(text: []const u8, buf: []u8) ?[]const u8 {
    var n: usize = 0;
    for (text) |c| {
        if (c == '_') continue;
        if (n == buf.len) return null;
        buf[n] = c;
        n += 1;
    }
    return buf[0..n];
}

/// ID_Start beyond ASCII: letters by Unicode's general categories,
/// approximated by the ranges that cover the scripts in use (the exact
/// tables are the parser's next corpus — test262's identifier tests
/// count the misses).
pub fn isIdStart(cp: u21) bool {
    if (cp < 0x80) return (cp >= 'a' and cp <= 'z') or (cp >= 'A' and cp <= 'Z') or cp == '$' or cp == '_';
    return switch (cp) {
        0xaa, 0xb5, 0xba, 0xc0...0xd6, 0xd8...0xf6, 0xf8...0x2c1, 0x2c6...0x2d1, 0x2e0...0x2e4, 0x2ec, 0x2ee, 0x370...0x374, 0x376...0x377, 0x37a...0x37d, 0x37f, 0x386, 0x388...0x3ff, 0x400...0x481, 0x48a...0x52f, 0x531...0x556, 0x559, 0x560...0x588, 0x5d0...0x5ea, 0x5ef...0x5f2, 0x620...0x64a, 0x66e...0x66f, 0x671...0x6d3, 0x6d5, 0x6e5...0x6e6, 0x6ee...0x6ef, 0x6fa...0x6fc, 0x6ff, 0x710, 0x712...0x72f, 0x74d...0x7a5, 0x7b1, 0x904...0x939, 0x93d, 0x950, 0x958...0x961, 0x971...0x980, 0x985...0x9b9, 0xa05...0xa39, 0xa85...0xab9, 0xb05...0xb39, 0xb85...0xbb9, 0xc05...0xc39, 0xc85...0xcb9, 0xd05...0xd3a, 0xe01...0xe30, 0xe32...0xe33, 0xe40...0xe46, 0xe81...0xeb0, 0xf00, 0xf40...0xf6c, 0x1000...0x102a, 0x10a0...0x10ff, 0x1100...0x1248, 0x1e00...0x1fbc, 0x1fc2...0x1ffc, 0x2071, 0x207f, 0x2090...0x209c, 0x2102, 0x2107, 0x210a...0x2113, 0x2115, 0x2118...0x211d, 0x2124, 0x2126, 0x2128, 0x212a...0x2139, 0x213c...0x213f, 0x2145...0x2149, 0x214e, 0x2160...0x2188, 0x2c00...0x2ce4, 0x2ceb...0x2cee, 0x2d00...0x2d25, 0x3005...0x3007, 0x3021...0x3029, 0x3031...0x3035, 0x3038...0x303c, 0x3041...0x3096, 0x309d...0x309f, 0x30a1...0x30fa, 0x30fc...0x30ff, 0x3105...0x312f, 0x3131...0x318e, 0x31a0...0x31bf, 0x3400...0x4dbf, 0x4e00...0xa48c, 0xa4d0...0xa4fd, 0xa500...0xa60c, 0xa610...0xa61f, 0xa62a...0xa62b, 0xa640...0xa66e, 0xa67f...0xa69d, 0xa6a0...0xa6ef, 0xa717...0xa71f, 0xa722...0xa788, 0xa78b...0xa7ca, 0xa7f2...0xa801, 0xa803...0xa805, 0xa807...0xa80a, 0xa80c...0xa822, 0xa840...0xa873, 0xa882...0xa8b3, 0xa8f2...0xa8f7, 0xa8fb, 0xa8fd...0xa8fe, 0xa90a...0xa925, 0xa930...0xa946, 0xa960...0xa97c, 0xa984...0xa9b2, 0xa9cf, 0xac00...0xd7a3, 0xf900...0xfa6d, 0xfa70...0xfad9, 0xfb00...0xfb06, 0xfb13...0xfb17, 0xfb1d, 0xfb1f...0xfb28, 0xfb2a...0xfb36, 0xfb38...0xfb3c, 0xfb3e, 0xfb40...0xfb41, 0xfb43...0xfb44, 0xfb46...0xfbb1, 0xfbd3...0xfd3d, 0xfd50...0xfd8f, 0xfd92...0xfdc7, 0xfdf0...0xfdfb, 0xfe70...0xfe74, 0xfe76...0xfefc, 0xff21...0xff3a, 0xff41...0xff5a, 0xff66...0xffbe, 0xffc2...0xffc7, 0xffca...0xffcf, 0xffd2...0xffd7, 0xffda...0xffdc, 0x10000...0x1000b, 0x1000d...0x10026, 0x10028...0x1003a, 0x1003c...0x1003d, 0x1003f...0x1004d, 0x10050...0x1005d, 0x10080...0x100fa, 0x10400...0x1049d, 0x1d400...0x1d6a5, 0x1d6a8...0x1d7cb, 0x1e900...0x1e943, 0x20000...0x2a6df, 0x2a700...0x2b739, 0x2b740...0x2b81d, 0x2b820...0x2cea1, 0x2ceb0...0x2ebe0, 0x2f800...0x2fa1d, 0x30000...0x3134a => true,
        else => false,
    };
}

/// ID_Continue: ID_Start plus digits, marks and connectors, ZWNJ/ZWJ.
pub fn isIdContinue(cp: u21) bool {
    if (isIdStart(cp)) return true;
    if (cp < 0x80) return cp >= '0' and cp <= '9';
    return switch (cp) {
        0x200c, 0x200d, 0xb7, 0x387, 0x300...0x36f, 0x483...0x487, 0x591...0x5bd, 0x5bf, 0x5c1...0x5c2, 0x5c4...0x5c5, 0x5c7, 0x610...0x61a, 0x64b...0x669, 0x670, 0x6d6...0x6dc, 0x6df...0x6e4, 0x6e7...0x6e8, 0x6ea...0x6ed, 0x6f0...0x6f9, 0x711, 0x730...0x74a, 0x7a6...0x7b0, 0x901...0x903, 0x93a...0x93c, 0x93e...0x94f, 0x951...0x957, 0x962...0x963, 0x966...0x96f, 0x981...0x983, 0x9bc, 0x9be...0x9c4, 0x9c7...0x9c8, 0x9cb...0x9cd, 0x9e6...0x9ef, 0xa01...0xa03, 0xa3c...0xa4d, 0xa66...0xa71, 0xa81...0xa83, 0xabc...0xacd, 0xae6...0xaef, 0xb01...0xb03, 0xb3c...0xb57, 0xb66...0xb6f, 0xbbe...0xbcd, 0xbe6...0xbef, 0xc00...0xc04, 0xc3e...0xc56, 0xc66...0xc6f, 0xc81...0xc83, 0xcbc...0xcd6, 0xce6...0xcef, 0xd00...0xd03, 0xd3b...0xd4d, 0xd66...0xd6f, 0xe31, 0xe34...0xe3a, 0xe47...0xe4e, 0xe50...0xe59, 0xeb1, 0xeb4...0xebc, 0xec8...0xecd, 0xed0...0xed9, 0xf18...0xf19, 0xf20...0xf29, 0xf35, 0xf37, 0xf39, 0xf3e...0xf3f, 0xf71...0xf84, 0xf86...0xf87, 0xf8d...0xfbc, 0x102b...0x103e, 0x1040...0x1049, 0x1dc0...0x1dff, 0x203f...0x2040, 0x2054, 0x20d0...0x20dc, 0x20e1, 0x20e5...0x20f0, 0x2cef...0x2cf1, 0x2d7f, 0x302a...0x302f, 0x3099...0x309a, 0xa620...0xa629, 0xa66f, 0xa674...0xa67d, 0xa69e...0xa69f, 0xa6f0...0xa6f1, 0xa802, 0xa806, 0xa80b, 0xa823...0xa827, 0xa880...0xa881, 0xa8b4...0xa8c5, 0xa8d0...0xa8d9, 0xa8e0...0xa8f1, 0xa8ff...0xa909, 0xa926...0xa92d, 0xa947...0xa953, 0xa980...0xa983, 0xa9b3...0xa9c0, 0xa9d0...0xa9d9, 0xfe00...0xfe0f, 0xfe20...0xfe2f, 0xfe33...0xfe34, 0xfe4d...0xfe4f, 0xff10...0xff19, 0xff3f, 0xe0100...0xe01ef => true,
        else => false,
    };
}

// ------------------------------------------------------------- tests

fn tokens(a: std.mem.Allocator, src: []const u8) ![]Token {
    var l = Lexer.init(a, src);
    var out: std.ArrayList(Token) = .empty;
    while (true) {
        const t = try l.next();
        try out.append(a, t);
        if (t.kind == .eof) break;
    }
    return out.items;
}

test "lexer: punctuators, the longest match first" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ts = try tokens(arena.allocator(), "a >>>= b ?? c?.d ** e => f ... g !== h");
    const want = [_]Kind{ .identifier, .ushr_assign, .identifier, .question_question, .identifier, .question_dot, .identifier, .star_star, .identifier, .arrow, .identifier, .ellipsis, .identifier, .ne_strict, .identifier, .eof };
    for (want, ts) |w, t| try std.testing.expectEqual(w, t.kind);
}

test "lexer: numbers in every radix, separators, bigints, and what follows them" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try tokens(a, "0x1F 0o17 0b101 1_000.5e3 .5 017 089 12n 0x1fn");
    try std.testing.expectEqual(@as(f64, 31), ts[0].number);
    try std.testing.expectEqual(@as(f64, 15), ts[1].number);
    try std.testing.expectEqual(@as(f64, 5), ts[2].number);
    try std.testing.expectEqual(@as(f64, 1000.5e3), ts[3].number);
    try std.testing.expectEqual(@as(f64, 0.5), ts[4].number);
    try std.testing.expectEqual(@as(f64, 15), ts[5].number);
    try std.testing.expect(ts[5].legacy_octal);
    try std.testing.expectEqual(@as(f64, 89), ts[6].number);
    try std.testing.expect(ts[6].legacy_octal);
    try std.testing.expectEqual(Kind.bigint, ts[7].kind);
    try std.testing.expectEqualStrings("12", ts[7].raw);
    try std.testing.expectEqual(Kind.bigint, ts[8].kind);
    try std.testing.expectError(error.SyntaxError, tokens(a, "3in"));
    try std.testing.expectError(error.SyntaxError, tokens(a, "1__0"));
    try std.testing.expectError(error.SyntaxError, tokens(a, "1.5n"));
}

test "lexer: strings cook their escapes and flag legacy octal" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try tokens(a, "'a\\n\\x41\\u0042\\u{1F600}\\\nb' \"\\0\" '\\101'");
    try std.testing.expectEqualStrings("a\nAB\u{1F600}b", ts[0].text);
    try std.testing.expectEqualStrings("\x00", ts[1].text);
    try std.testing.expectEqualStrings("A", ts[2].text);
    try std.testing.expect(ts[2].legacy_octal and !ts[0].legacy_octal);
    try std.testing.expectError(error.SyntaxError, tokens(a, "'abc"));
    try std.testing.expectError(error.SyntaxError, tokens(a, "'a\nb'"));
}

test "lexer: templates, their raw text, and continuation after a substitution" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = Lexer.init(a, "`a\\n${x}b\\u{41}` `\\unicode`");
    const head = try l.next();
    try std.testing.expectEqual(Kind.template_head, head.kind);
    try std.testing.expectEqualStrings("a\n", head.text);
    try std.testing.expectEqualStrings("a\\n", head.raw);
    _ = try l.next(); // x
    const rb = try l.next();
    try std.testing.expectEqual(Kind.rbrace, rb.kind);
    const tail = try l.rescanTemplateContinuation(rb);
    try std.testing.expectEqual(Kind.template_tail, tail.kind);
    try std.testing.expectEqualStrings("bA", tail.text);
    const bad = try l.next();
    try std.testing.expectEqual(Kind.template, bad.kind);
    try std.testing.expect(bad.cooked_invalid);
    try std.testing.expectEqualStrings("\\unicode", bad.raw);
}

test "lexer: a regexp is rescanned from a slash, with its flags checked" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var l = Lexer.init(a, "/a[/]b\\/c/gi x /=y/");
    const slash = try l.next();
    try std.testing.expectEqual(Kind.slash, slash.kind);
    const re = try l.rescanRegExp(slash);
    try std.testing.expectEqualStrings("a[/]b\\/c", re.text);
    try std.testing.expectEqualStrings("gi", re.raw);
    _ = try l.next(); // x
    const sa = try l.next();
    try std.testing.expectEqual(Kind.slash_assign, sa.kind);
    const re2 = try l.rescanRegExp(sa);
    try std.testing.expectEqualStrings("=y", re2.text);
    var l2 = Lexer.init(a, "/a/gg");
    const s2 = try l2.next();
    try std.testing.expectError(error.SyntaxError, l2.rescanRegExp(s2));
}

test "lexer: identifiers with escapes, private names, unicode letters, and the newline flag" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const ts = try tokens(a, "\\u0061wait #priv ünïcode\n/* x\n */ y // z\n<!-- html\n--> more\nw");
    try std.testing.expectEqualStrings("await", ts[0].text);
    try std.testing.expect(ts[0].escaped and !ts[0].isWord("await"));
    try std.testing.expectEqual(Kind.private_name, ts[1].kind);
    try std.testing.expectEqualStrings("#priv", ts[1].text);
    try std.testing.expectEqualStrings("ünïcode", ts[2].text);
    try std.testing.expect(ts[3].isWord("y") and ts[3].newline_before);
    try std.testing.expect(ts[4].isWord("w") and ts[4].newline_before);
    try std.testing.expectEqual(Kind.eof, ts[5].kind);
    try std.testing.expectError(error.SyntaxError, tokens(a, "\\u0031x"));
}

test "lexer: a hashbang line is skipped and 2028/2029 are line terminators" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const ts = try tokens(arena.allocator(), "#!/usr/bin/env node\na\u{2028}b");
    try std.testing.expect(ts[0].isWord("a") and ts[0].newline_before); // the line feed after the hashbang counts
    try std.testing.expect(ts[1].isWord("b") and ts[1].newline_before);
}
