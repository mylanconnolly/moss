//! ECMAScript 2023 syntactic grammar (ECMA-262 §13–§16): tokens to the
//! tree in `ast.zig`, with the early errors the specification attaches
//! to each production. Recursive descent; binary operators by
//! precedence climbing; the cover grammars — a parenthesized
//! expression that turns out to be arrow parameters, an object or array
//! literal that turns out to be an assignment target — parsed as the
//! expression first and reinterpreted, as the specification does.
//! Context (strict mode, `yield`/`await` as keywords, where `super`
//! and `new.target` may appear, what `break` may reach) travels in the
//! parser's flags, saved and restored around every function and class.
const std = @import("std");
const lexer = @import("lexer.zig");
const ast = @import("ast.zig");
const analysis = @import("scope.zig");
const ChunkArena = @import("scratch.zig").ChunkArena;
const regexp = @import("regexp.zig");

const Token = lexer.Token;
const Kind = lexer.Kind;
const Node = ast.Node;

pub const Error = error{ SyntaxError, OutOfMemory };

pub const Options = struct {
    module: bool = false,
    /// Code already strict (a class body, a "use strict" caller): eval.
    strict: bool = false,
    /// Direct eval code inherits its caller's syntactic context
    /// (§19.2.1.1 PerformEval steps 5–12).
    in_function: bool = false,
    allow_new_target: bool = false,
    allow_super_property: bool = false,
    allow_super_call: bool = false,
    /// Inside a class field initializer: `arguments` is an error.
    no_arguments: bool = false,
    /// Private names of the enclosing classes, visible to eval code.
    private_names: []const []const u8 = &.{},
    /// Preparse: a function body that will compile on its first call is
    /// parsed, summarised (`ast.Function.Lazy`) and dropped from the
    /// arena, so a bundle's tree is the code that runs now (what the
    /// big engines do; a 466 KB script's tree cost 14 MB, 2026-09-28).
    /// Needs `scratch_arena`, the arena the nodes live in.
    lazy: bool = false,
    /// The outermost function keeps its body (it is the one being
    /// compiled: `compileLazy`).
    keep_outer: bool = false,
    scratch_arena: ?*ChunkArena = null,
};

/// What the preparse did, for the tools' tallies.
pub var stats: struct { dropped: usize = 0, kept_called: usize = 0, kept_dynamic: usize = 0, kept_super: usize = 0 } = .{};
/// Off, every body is kept (the test262 tool's `TEST262_NODROP=1`, to
/// tell a preparse fault from a lazy-compile one).
pub var drop_enabled: bool = true;

/// Parse a Script or Module. Nodes live in `a`; the error message and
/// position stay on the parser.
pub fn parse(a: std.mem.Allocator, src: []const u8, opts: Options) Error!*Node {
    var p = Parser.init(a, src, opts);
    return p.parseProgram();
}

pub const Parser = struct {
    a: std.mem.Allocator,
    lex: lexer.Lexer,
    tok: Token,
    /// Where the previous token ended, for spans.
    prev_end: u32 = 0,
    err: []const u8 = "",
    err_at: u32 = 0,

    module: bool,
    strict: bool,
    opts: Options,
    // The function context.
    in_function: bool = false,
    in_generator: bool = false,
    in_async: bool = false,
    /// `await` parses as an expression: an async function, or a module's
    /// top level.
    await_expr: bool = false,
    allow_super_property: bool = false,
    allow_super_call: bool = false,
    allow_new_target: bool = false,
    /// A class field initializer or static block: `arguments` is an error.
    no_arguments: bool = false,
    /// Inside a `class` body's static block: `await` is reserved.
    in_static_block: bool = false,
    // Statement context.
    labels: std.ArrayList(Label) = .empty,
    breakable: u32 = 0, // loops and switches
    loops: u32 = 0,
    scope: ?*Scope = null,
    /// A cover-initialized name (`{a = 1}`) was parsed and not yet
    /// consumed by a pattern: its position, to report if it stays.
    cover_init_at: ?u32 = null,
    /// Private names referenced in the current class body, checked
    /// against its declarations when the body ends.
    class_privates: ?*PrivateScope = null,
    /// Counts of `yield` and `await` expressions (and `await` names)
    /// parsed so far: a function's parameters may hold neither.
    yield_count: u32 = 0,
    await_count: u32 = 0,
    /// A class heritage is a LeftHandSideExpression: no arrow may end it.
    no_arrow: bool = false,
    /// Function nesting, the outermost body at 1 (`Options.keep_outer`).
    fn_depth: u32 = 0,
    /// A module's exported names (each once) and the local names its
    /// `export { x }` clauses name, resolved against the top scope at the
    /// end.
    exported: std.StringHashMapUnmanaged(void) = .empty,
    export_locals: std.ArrayList(NameAt) = .empty,

    const Label = struct { name: []const u8, is_loop: bool };
    const NameAt = struct { name: []const u8, pos: u32 };

    const Scope = struct {
        parent: ?*Scope,
        is_function: bool,
        lexical: std.StringHashMapUnmanaged(void) = .empty,
        vars: std.StringHashMapUnmanaged(void) = .empty,
        /// Function declarations at a block's top level (sloppy code
        /// may repeat them, Annex B).
        funcs: std.StringHashMapUnmanaged(void) = .empty,
        special_funcs: std.StringHashMapUnmanaged(void) = .empty,
        /// Names the function's parameters bound: a body's lexical
        /// declaration may not repeat one.
        params: std.StringHashMapUnmanaged(void) = .empty,
        /// A catch clause's simple parameter: `var` may repeat it — but
        /// not a destructured one's names.
        catch_param: ?[]const u8 = null,
        catch_param_pattern: bool = false,
    };

    const PrivateScope = struct {
        parent: ?*PrivateScope,
        declared: std.StringHashMapUnmanaged(u8) = .empty, // 1 method/field, 2 getter, 3 setter, 4 both
        referenced: std.ArrayList(NameAt) = .empty,
    };

    pub fn init(a: std.mem.Allocator, src: []const u8, opts: Options) Parser {
        var p: Parser = .{ .a = a, .lex = lexer.Lexer.init(a, src), .tok = undefined, .module = opts.module, .strict = opts.strict or opts.module, .opts = opts };
        p.lex.module = opts.module;
        return p;
    }

    /// A parser that starts at `start` and never reads before it: for
    /// a function parsed again from a source whose text is unpacked
    /// only around that span (`bytecode.Source.view`).
    pub fn initAt(a: std.mem.Allocator, src: []const u8, start: u32, opts: Options) Parser {
        var p: Parser = .{ .a = a, .lex = .{ .src = src, .a = a, .pos = start }, .tok = undefined, .module = opts.module, .strict = opts.strict or opts.module, .opts = opts };
        p.lex.module = opts.module;
        return p;
    }

    fn checkRegExpLiteral(p: *Parser, pattern: []const u8, flags: []const u8, pos: u32) Error!void {
        var pat: std.ArrayList(u16) = .empty;
        defer pat.deinit(p.a);
        var it = std.unicode.Wtf8View.initUnchecked(pattern).iterator();
        while (it.nextCodepoint()) |cp| {
            if (cp < 0x10000) {
                try pat.append(p.a, @intCast(cp));
            } else {
                const c = cp - 0x10000;
                try pat.append(p.a, @intCast(0xd800 + (c >> 10)));
                try pat.append(p.a, @intCast(0xdc00 + (c & 0x3ff)));
            }
        }
        var fl: std.ArrayList(u16) = .empty;
        defer fl.deinit(p.a);
        for (flags) |c| try fl.append(p.a, c);
        const f = regexp.Flags.parse(fl.items) orelse return p.fail("invalid regular expression flags", pos);
        var err: []const u8 = "";
        const prog = regexp.compile(p.a, pat.items, f, &err) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.SyntaxError => return p.fail("invalid regular expression", pos),
        };
        prog.deinit();
    }

    fn fail(p: *Parser, msg: []const u8, where: u32) Error {
        if (p.err.len == 0) {
            p.err = msg;
            p.err_at = where;
        }
        return error.SyntaxError;
    }

    fn failLex(p: *Parser, e: Error) Error {
        if (e == error.SyntaxError and p.err.len == 0) {
            p.err = p.lex.err;
            p.err_at = p.lex.err_at;
        }
        return e;
    }

    fn node(p: *Parser, pos: u32, data: Node.Data) Error!*Node {
        const n = try p.a.create(Node);
        n.* = .{ .pos = pos, .data = data };
        return n;
    }

    // ------------------------------------------------------- tokens

    fn advance(p: *Parser) Error!void {
        p.prev_end = p.tok.end;
        p.tok = p.lex.next() catch |e| return p.failLex(e);
    }

    fn at(p: *const Parser, k: Kind) bool {
        return p.tok.kind == k;
    }

    fn atWord(p: *const Parser, w: []const u8) bool {
        return p.tok.isWord(w);
    }

    fn eat(p: *Parser, k: Kind) Error!bool {
        if (p.tok.kind != k) return false;
        try p.advance();
        return true;
    }

    fn eatWord(p: *Parser, w: []const u8) Error!bool {
        if (!p.atWord(w)) return false;
        try p.advance();
        return true;
    }

    fn expect(p: *Parser, k: Kind, what: []const u8) Error!void {
        if (p.tok.kind != k) return p.fail(what, p.tok.start);
        try p.advance();
    }

    fn expectWord(p: *Parser, w: []const u8, what: []const u8) Error!void {
        if (!p.atWord(w)) return p.fail(what, p.tok.start);
        try p.advance();
    }

    /// The token after the current one, without consuming anything.
    fn peek(p: *Parser) Error!Token {
        const st = p.lex.save();
        defer p.lex.restore(st);
        return p.lex.next() catch |e| return p.failLex(e);
    }

    /// Automatic semicolon insertion (§12.10): a `;`, or a `}`, the end,
    /// or a line break before the offending token.
    fn consumeSemicolon(p: *Parser) Error!void {
        if (try p.eat(.semicolon)) return;
        if (p.at(.rbrace) or p.at(.eof) or p.tok.newline_before) return;
        return p.fail("expected ';'", p.tok.start);
    }

    // ------------------------------------------------------ keywords

    const reserved = [_][]const u8{ "break", "case", "catch", "class", "const", "continue", "debugger", "default", "delete", "do", "else", "enum", "export", "extends", "false", "finally", "for", "function", "if", "import", "in", "instanceof", "new", "null", "return", "super", "switch", "this", "throw", "true", "try", "typeof", "var", "void", "while", "with" };
    const strict_reserved = [_][]const u8{ "implements", "interface", "let", "package", "private", "protected", "public", "static", "yield" };

    fn isReservedWord(p: *const Parser, name: []const u8) bool {
        for (reserved) |r| if (std.mem.eql(u8, r, name)) return true;
        if (p.strict) for (strict_reserved) |r| if (std.mem.eql(u8, r, name)) return true;
        if (std.mem.eql(u8, name, "yield") and p.in_generator) return true;
        if (std.mem.eql(u8, name, "await") and (p.await_expr or p.module or p.in_static_block)) return true;
        return false;
    }

    /// The current token as an IdentifierReference, or null when it is
    /// a keyword in this context.
    fn identifierReference(p: *Parser) Error!?[]const u8 {
        if (p.tok.kind != .identifier) return null;
        const name = p.tok.text;
        if (p.tok.escaped) {
            // An escaped spelling of a reserved word is an error, never
            // an identifier and never a keyword.
            if (p.isReservedWord(name) or std.mem.eql(u8, name, "yield") or std.mem.eql(u8, name, "await") or std.mem.eql(u8, name, "let") or std.mem.eql(u8, name, "static")) {
                if (p.isReservedWord(name)) return p.fail("keyword must not contain escapes", p.tok.start);
            }
            return name;
        }
        if (p.isReservedWord(name)) return null;
        return name;
    }

    /// A BindingIdentifier: an identifier that may be declared here.
    fn bindingIdentifier(p: *Parser) Error![]const u8 {
        const pos = p.tok.start;
        const name = (try p.identifierReference()) orelse return p.fail("expected an identifier", pos);
        try p.checkBindingName(name, pos);
        try p.advance();
        return name;
    }

    fn checkBindingName(p: *Parser, name: []const u8, pos: u32) Error!void {
        if (p.strict and (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments"))) return p.fail("'eval' and 'arguments' cannot be bound in strict code", pos);
        if (p.strict) for (strict_reserved) |r| if (std.mem.eql(u8, r, name)) return p.fail("reserved word cannot be bound in strict code", pos);
        if (std.mem.eql(u8, name, "let") and p.strict) return p.fail("'let' cannot be bound in strict code", pos);
        if (std.mem.eql(u8, name, "yield") and (p.strict or p.in_generator)) return p.fail("'yield' cannot be bound here", pos);
        if (std.mem.eql(u8, name, "await") and (p.await_expr or p.module or p.in_static_block)) return p.fail("'await' cannot be bound here", pos);
    }

    // -------------------------------------------------------- scopes

    fn pushScope(p: *Parser, is_function: bool) Error!*Scope {
        const s = try p.a.create(Scope);
        s.* = .{ .parent = p.scope, .is_function = is_function };
        p.scope = s;
        return s;
    }

    fn popScope(p: *Parser) void {
        p.scope = p.scope.?.parent;
    }

    const DeclareKind = enum { @"var", lexical, function, function_special, param, catch_param };

    fn declare(p: *Parser, name: []const u8, kind: DeclareKind, pos: u32) Error!void {
        const s = p.scope orelse return;
        switch (kind) {
            .lexical => {
                if (s.lexical.contains(name) or s.funcs.contains(name)) return p.fail("duplicate declaration", pos);
                if (s.vars.contains(name)) return p.fail("declaration conflicts with a var", pos);
                if (s.params.contains(name)) return p.fail("declaration repeats a parameter", pos);
                if (s.catch_param) |cp| if (std.mem.eql(u8, cp, name)) return p.fail("declaration repeats the catch parameter", pos);
                if (std.mem.eql(u8, name, "let")) return p.fail("'let' cannot be a lexical name", pos);
                try s.lexical.put(p.a, name, {});
            },
            .function, .function_special => {
                // At a function's or script's top level, function
                // declarations are var-scoped; in a block, lexical — but
                // sloppy code may repeat a plain one there (Annex B); a
                // generator or async one never.
                if (s.is_function and !(p.module and s.parent == null)) {
                    if (s.lexical.contains(name)) return p.fail("declaration conflicts with a lexical name", pos);
                    try s.vars.put(p.a, name, {});
                } else if (s.is_function) {
                    // A module's top level: function declarations are lexical.
                    if (s.lexical.contains(name) or s.vars.contains(name) or s.funcs.contains(name)) return p.fail("duplicate declaration", pos);
                    try s.lexical.put(p.a, name, {});
                } else {
                    if (s.lexical.contains(name) or s.vars.contains(name)) return p.fail("duplicate declaration", pos);
                    if (s.catch_param) |cp| if (std.mem.eql(u8, cp, name)) return p.fail("declaration repeats the catch parameter", pos);
                    if (s.funcs.contains(name) and (p.strict or kind == .function_special)) return p.fail("duplicate function declaration", pos);
                    if (s.special_funcs.contains(name)) return p.fail("duplicate function declaration", pos);
                    try s.funcs.put(p.a, name, {});
                    if (kind == .function_special) try s.special_funcs.put(p.a, name, {});
                }
            },
            .@"var" => {
                var it: ?*Scope = s;
                while (it) |sc| : (it = sc.parent) {
                    if (sc.lexical.contains(name)) return p.fail("var conflicts with a lexical declaration", pos);
                    if (!sc.is_function and sc.funcs.contains(name)) return p.fail("var conflicts with a lexical declaration", pos);
                    if (sc.catch_param) |cp| if (std.mem.eql(u8, cp, name) and sc.catch_param_pattern) return p.fail("var conflicts with the catch parameter", pos);
                    try sc.vars.put(p.a, name, {});
                    if (sc.is_function) break;
                }
            },
            .param => try s.params.put(p.a, name, {}),
            .catch_param => {},
        }
    }

    // ------------------------------------------------------- program

    /// A function or arrow expression at `start` in the source, as a
    /// lazily compiled function is parsed again: the node, with the
    /// positions absolute, in a function context with private names
    /// from `opts` declared.
    pub fn parseFunctionAt(p: *Parser, start: u32, declaration: bool) Error!*Node {
        // The private names of the enclosing classes: their references
        // are never checked here (the runtime chain has them); the list
        // only needs freeing.
        var owned_privates: ?*PrivateScope = null;
        defer if (owned_privates) |ps| p.freeReferenced(ps);
        p.lex.pos = start;
        try p.advance();
        _ = try p.pushScope(true);
        p.allow_new_target = true;
        p.in_function = true;
        p.allow_super_property = p.opts.allow_super_property;
        p.allow_super_call = p.opts.allow_super_call;
        p.no_arguments = p.opts.no_arguments;
        if (p.opts.private_names.len > 0) {
            const ps = try p.a.create(PrivateScope);
            ps.* = .{ .parent = null };
            for (p.opts.private_names) |n| try ps.declared.put(p.a, n, 1);
            p.class_privates = ps;
            owned_privates = ps;
        }
        if (declaration) return p.parseFunctionDeclaration(false);
        const e = try p.parseAssignment(true);
        return switch (e.data) {
            .function => e,
            else => p.fail("expected a function", start),
        };
    }

    /// A method, getter or setter at its parameter list, as a lazily
    /// compiled one is parsed again: the function, positions absolute.
    pub fn parseMethodAt(p: *Parser, params_start: u32, kind: ast.Function.Kind, is_async: bool, is_generator: bool) Error!*ast.Function {
        // The private names of the enclosing classes: their references
        // are never checked here (the runtime chain has them); the list
        // only needs freeing.
        var owned_privates: ?*PrivateScope = null;
        defer if (owned_privates) |ps| p.freeReferenced(ps);
        p.lex.pos = params_start;
        try p.advance();
        _ = try p.pushScope(true);
        if (p.opts.private_names.len > 0) {
            const ps = try p.a.create(PrivateScope);
            ps.* = .{ .parent = null };
            for (p.opts.private_names) |n| try ps.declared.put(p.a, n, 1);
            p.class_privates = ps;
            owned_privates = ps;
        }
        return p.parseFunctionRest(params_start, null, is_async, is_generator, kind, false);
    }

    pub fn parseProgram(p: *Parser) Error!*Node {
        try p.advance();
        const scope = try p.pushScope(true);
        _ = scope;
        if (p.module) {
            p.await_expr = true;
        } else {
            p.allow_new_target = p.opts.allow_new_target;
            p.in_function = p.opts.in_function;
            p.allow_super_property = p.opts.allow_super_property;
            p.allow_super_call = p.opts.allow_super_call;
            p.no_arguments = p.opts.no_arguments;
        }
        // Eval code inside a class: its private names are declared.
        var outer_privates: ?*PrivateScope = null;
        if (p.opts.private_names.len > 0) {
            const ps = try p.a.create(PrivateScope);
            ps.* = .{ .parent = null };
            for (p.opts.private_names) |n| try ps.declared.put(p.a, n, 1);
            p.class_privates = ps;
            outer_privates = ps;
        }
        var body: std.ArrayList(*Node) = .empty;
        // The directive prologue.
        _ = try p.directivePrologue(&body, &p.strict);
        while (!p.at(.eof)) {
            const st = if (p.module) try p.parseModuleItem() else try p.parseStatementListItem();
            try body.append(p.a, st);
        }
        if (p.cover_init_at) |at_| return p.fail("invalid shorthand property initializer", at_);
        // `export { x }` names a declaration of this module.
        const top = p.scope.?;
        for (p.export_locals.items) |ex| {
            if (!top.lexical.contains(ex.name) and !top.vars.contains(ex.name) and !top.funcs.contains(ex.name)) return p.fail("export of an undeclared name", ex.pos);
        }
        if (outer_privates) |ps| {
            defer p.freeReferenced(ps);
            for (ps.referenced.items) |r| if (!ps.declared.contains(r.name)) return p.fail("undeclared private name", r.pos);
        }
        p.popScope();
        return p.node(0, .{ .program = .{ .body = body.items, .module = p.module, .strict = p.strict } });
    }

    /// Leading string-literal expression statements; "use strict" among
    /// them makes the code strict — and then no directive may spell an
    /// octal escape.
    fn directivePrologue(p: *Parser, body: *std.ArrayList(*Node), strict: *bool) Error!bool {
        var saw_octal: ?u32 = null;
        var saw_use_strict = false;
        while (p.at(.string)) {
            const t = p.tok;
            const next = try p.peek();
            const ends = next.kind == .semicolon or next.kind == .rbrace or next.kind == .eof or next.newline_before;
            if (!ends) break;
            const raw = p.lex.src[t.start + 1 .. t.end - 1];
            if (t.legacy_octal and saw_octal == null) saw_octal = t.start;
            if (std.mem.eql(u8, raw, "use strict")) {
                strict.* = true;
                p.strict = true;
                saw_use_strict = true;
            }
            const st = try p.parseStatement();
            try body.append(p.a, st);
        }
        if (strict.* and saw_octal != null) return p.fail("octal escape in strict code", saw_octal.?);
        return saw_use_strict;
    }

    // ---------------------------------------------------- statements

    fn parseStatementListItem(p: *Parser) Error!*Node {
        if (p.atWord("function")) return p.parseFunctionDeclaration(false);
        if (p.atWord("async") and !p.tok.escaped) {
            const next = try p.peek();
            if (next.isWord("function") and !next.newline_before) return p.parseFunctionDeclaration(false);
        }
        if (p.atWord("class")) return p.parseClassDeclaration();
        if (p.atWord("const")) return p.parseLexicalDeclaration(.@"const", true);
        if (p.atWord("let") and try p.letStartsDeclaration()) return p.parseLexicalDeclaration(.let, true);
        return p.parseStatement();
    }

    /// `let` begins a declaration when what follows can only be one:
    /// `[`, `{`, or an identifier (that is not a keyword ending the
    /// statement) — in strict code `let` is always a keyword.
    fn letStartsDeclaration(p: *Parser) Error!bool {
        if (p.tok.escaped) return false;
        const next = try p.peek();
        if (next.kind == .lbracket or next.kind == .lbrace) return true;
        if (next.kind == .identifier) {
            if (next.escaped) return true;
            // `let` newline `let` / `yield` / `await`... is still a declaration attempt
            // except for contextual keywords that begin statements: ASI splits
            // `let \n foo` only when `foo` cannot continue it — the spec says
            // `let` followed by an identifier is a declaration regardless of
            // the newline, unless the identifier is `in`/`instanceof`/`of`?
            if (next.isWord("in") or next.isWord("instanceof")) return false;
            return true;
        }
        return false;
    }

    fn parseStatement(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        switch (p.tok.kind) {
            .lbrace => return p.parseBlockStatement(),
            .semicolon => {
                try p.advance();
                return p.node(pos, .empty);
            },
            .identifier => {},
            else => return p.parseExpressionStatement(),
        }
        const w = p.tok.text;
        if (p.tok.escaped) {
            // An escaped spelling is never a keyword; it may still label.
            const next = try p.peek();
            if (next.kind == .colon and (try p.identifierReference()) != null) return p.parseLabeled();
            return p.parseExpressionStatement();
        }
        if (std.mem.eql(u8, w, "var")) return p.parseVarStatement();
        if (std.mem.eql(u8, w, "if")) return p.parseIf();
        if (std.mem.eql(u8, w, "for")) return p.parseFor();
        if (std.mem.eql(u8, w, "while")) return p.parseWhile();
        if (std.mem.eql(u8, w, "do")) return p.parseDoWhile();
        if (std.mem.eql(u8, w, "return")) return p.parseReturn();
        if (std.mem.eql(u8, w, "break")) return p.parseBreakContinue(true);
        if (std.mem.eql(u8, w, "continue")) return p.parseBreakContinue(false);
        if (std.mem.eql(u8, w, "throw")) return p.parseThrow();
        if (std.mem.eql(u8, w, "try")) return p.parseTry();
        if (std.mem.eql(u8, w, "switch")) return p.parseSwitch();
        if (std.mem.eql(u8, w, "with")) return p.parseWith();
        if (std.mem.eql(u8, w, "debugger")) {
            try p.advance();
            try p.consumeSemicolon();
            return p.node(pos, .debugger);
        }
        if (std.mem.eql(u8, w, "function")) return p.fail("a function declaration is not a statement here", pos);
        if (std.mem.eql(u8, w, "class")) return p.fail("a class declaration is not a statement here", pos);
        if (std.mem.eql(u8, w, "const")) return p.fail("a lexical declaration is not a statement here", pos);
        if (std.mem.eql(u8, w, "let")) {
            const next = try p.peek();
            if (next.kind == .lbracket and !next.newline_before) return p.fail("a lexical declaration is not a statement here", pos);
            if (p.strict) return p.fail("'let' is reserved in strict code", pos);
        }
        if (std.mem.eql(u8, w, "import")) {
            const next = try p.peek();
            if (next.kind != .lparen and next.kind != .dot) return p.fail("an import declaration is only at a module's top level", pos);
        }
        if (std.mem.eql(u8, w, "export")) return p.fail("an export declaration is only at a module's top level", pos);
        // A label?
        if (!p.isReservedWord(w) or std.mem.eql(u8, w, "yield") or std.mem.eql(u8, w, "await")) {
            const next = try p.peek();
            if (next.kind == .colon and (try p.identifierReference()) != null) return p.parseLabeled();
        }
        return p.parseExpressionStatement();
    }

    fn parseExpressionStatement(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        // Lookahead restrictions: `{`, `function`, `class`, `let [`, `async function`.
        if (p.atWord("async") and !p.tok.escaped) {
            const next = try p.peek();
            if (next.isWord("function") and !next.newline_before) return p.fail("an async function declaration is not a statement here", pos);
        }
        const e = try p.parseExpression(true);
        try p.consumeSemicolon();
        return p.node(pos, .{ .expr_stmt = e });
    }

    fn parseBlockStatement(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.expect(.lbrace, "expected '{'");
        _ = try p.pushScope(false);
        const body = try p.parseStatementList();
        p.popScope();
        try p.expect(.rbrace, "expected '}'");
        return p.node(pos, .{ .block = body });
    }

    fn parseStatementList(p: *Parser) Error![]*Node {
        var list: std.ArrayList(*Node) = .empty;
        while (!p.at(.rbrace) and !p.at(.eof)) try list.append(p.a, try p.parseStatementListItem());
        return list.items;
    }

    fn parseVarStatement(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        const decls = try p.parseDeclarators(.@"var", true);
        try p.consumeSemicolon();
        return p.node(pos, .{ .var_decl = .{ .kind = .@"var", .decls = decls } });
    }

    fn parseLexicalDeclaration(p: *Parser, kind: ast.DeclKind, allow_in: bool) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        const decls = try p.parseDeclarators(kind, allow_in);
        try p.consumeSemicolon();
        return p.node(pos, .{ .var_decl = .{ .kind = kind, .decls = decls } });
    }

    /// Declarators after `var`/`let`/`const`; `for` heads pass `allow_in`
    /// false and check initializers themselves.
    fn parseDeclarators(p: *Parser, kind: ast.DeclKind, allow_in: bool) Error![]ast.Declarator {
        var list: std.ArrayList(ast.Declarator) = .empty;
        while (true) {
            const pos = p.tok.start;
            const target = try p.parseBindingTarget(if (kind == .@"var") .@"var" else .lexical);
            var initial: ?*Node = null;
            if (try p.eat(.assign)) {
                initial = try p.parseAssignment(allow_in);
            } else if (allow_in) {
                if (kind == .@"const") return p.fail("a const declaration needs an initializer", pos);
                if (target.data != .identifier) return p.fail("a destructuring declaration needs an initializer", pos);
            }
            try list.append(p.a, .{ .target = target, .init = initial });
            if (!try p.eat(.comma)) break;
        }
        return list.items;
    }

    /// A BindingIdentifier or BindingPattern, its names declared.
    fn parseBindingTarget(p: *Parser, kind: DeclareKind) Error!*Node {
        const pos = p.tok.start;
        if (p.at(.lbracket) or p.at(.lbrace)) {
            const pat = try p.parseBindingPattern();
            try p.declarePatternNames(pat, kind);
            return pat;
        }
        const name = try p.bindingIdentifier();
        try p.declare(name, kind, pos);
        return p.node(pos, .{ .identifier = name });
    }

    fn declarePatternNames(p: *Parser, pat: *Node, kind: DeclareKind) Error!void {
        switch (pat.data) {
            .identifier => |name| try p.declare(name, kind, pat.pos),
            .array_pattern => |els| for (els) |el| if (el) |e| try p.declarePatternNames(e, kind),
            .object_pattern => |props| for (props) |pr| try p.declarePatternNames(pr.value, kind),
            .assign_pattern => |ap| try p.declarePatternNames(ap.target, kind),
            .rest => |r| try p.declarePatternNames(r, kind),
            else => {},
        }
    }

    /// `[ ... ]` or `{ ... }` as a binding pattern, parsed directly.
    fn parseBindingPattern(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        if (try p.eat(.lbracket)) {
            var els: std.ArrayList(?*Node) = .empty;
            while (!p.at(.rbracket)) {
                if (try p.eat(.comma)) {
                    try els.append(p.a, null);
                    continue;
                }
                if (p.at(.ellipsis)) {
                    const rpos = p.tok.start;
                    try p.advance();
                    const target = try p.parseBindingElementTarget();
                    try els.append(p.a, try p.node(rpos, .{ .rest = target }));
                    if (p.at(.comma)) return p.fail("a rest element must be last", p.tok.start);
                    break;
                }
                try els.append(p.a, try p.parseBindingElement());
                if (!p.at(.rbracket)) try p.expect(.comma, "expected ',' in array pattern");
            }
            try p.expect(.rbracket, "expected ']'");
            return p.node(pos, .{ .array_pattern = els.items });
        }
        try p.expect(.lbrace, "expected a pattern");
        var props: std.ArrayList(ast.PatternProperty) = .empty;
        while (!p.at(.rbrace)) {
            if (p.at(.ellipsis)) {
                const rpos = p.tok.start;
                try p.advance();
                const name = try p.bindingIdentifier();
                const id = try p.node(rpos, .{ .identifier = name });
                try props.append(p.a, .{ .key = id, .value = try p.node(rpos, .{ .rest = id }), .is_rest = true });
                if (p.at(.comma)) return p.fail("a rest property must be last", p.tok.start);
                break;
            }
            const kpos = p.tok.start;
            var computed = false;
            var key: *Node = undefined;
            var shorthand_name: ?[]const u8 = null;
            if (try p.eat(.lbracket)) {
                computed = true;
                key = try p.parseAssignment(true);
                try p.expect(.rbracket, "expected ']'");
            } else if (p.at(.string)) {
                key = try p.node(kpos, .{ .string = p.tok.text });
                try p.advance();
            } else if (p.at(.number)) {
                key = try p.node(kpos, .{ .number = p.tok.number });
                try p.advance();
            } else if (p.at(.bigint)) {
                key = try p.node(kpos, .{ .bigint = p.tok.raw });
                try p.advance();
            } else if (p.at(.identifier)) {
                shorthand_name = p.tok.text;
                key = try p.node(kpos, .{ .string = p.tok.text });
                try p.advance();
            } else return p.fail("expected a property name", kpos);
            var value: *Node = undefined;
            if (try p.eat(.colon)) {
                value = try p.parseBindingElement();
            } else {
                const name = shorthand_name orelse return p.fail("expected ':'", p.tok.start);
                if (p.isReservedWord(name)) return p.fail("keyword cannot be a binding", kpos);
                try p.checkBindingName(name, kpos);
                const id = try p.node(kpos, .{ .identifier = name });
                value = if (try p.eat(.assign)) try p.node(kpos, .{ .assign_pattern = .{ .target = id, .default = try p.parseAssignment(true) } }) else id;
            }
            try props.append(p.a, .{ .key = key, .computed = computed, .value = value });
            if (!p.at(.rbrace)) try p.expect(.comma, "expected ',' in object pattern");
        }
        try p.expect(.rbrace, "expected '}'");
        return p.node(pos, .{ .object_pattern = props.items });
    }

    fn parseBindingElementTarget(p: *Parser) Error!*Node {
        if (p.at(.lbracket) or p.at(.lbrace)) return p.parseBindingPattern();
        const pos = p.tok.start;
        const name = try p.bindingIdentifier();
        return p.node(pos, .{ .identifier = name });
    }

    /// A binding element: a target with an optional default.
    fn parseBindingElement(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        const target = try p.parseBindingElementTarget();
        if (try p.eat(.assign)) return p.node(pos, .{ .assign_pattern = .{ .target = target, .default = try p.parseAssignment(true) } });
        return target;
    }

    fn parseIf(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        try p.expect(.lparen, "expected '('");
        const cond = try p.parseExpression(true);
        try p.expect(.rparen, "expected ')'");
        const then = try p.parseSubStatement(true);
        var otherwise: ?*Node = null;
        if (try p.eatWord("else")) otherwise = try p.parseSubStatement(true);
        return p.node(pos, .{ .if_stmt = .{ .cond = cond, .then = then, .otherwise = otherwise } });
    }

    /// The body of `if`/`while`/`for`/`with`/labels: a Statement — and
    /// in sloppy code, `if` alone may take a plain function declaration
    /// (Annex B). A labelled function is never a body.
    fn parseSubStatement(p: *Parser, allow_function: bool) Error!*Node {
        if (p.atWord("function") and !p.strict and allow_function) {
            const next = try p.peek();
            if (next.kind != .star) {
                _ = try p.pushScope(false);
                defer p.popScope();
                return p.parseFunctionDeclaration(true);
            }
        }
        const body = try p.parseSubStatementInner();
        if (isLabelledFunction(body)) return p.fail("a labelled function declaration cannot be a body", body.pos);
        return body;
    }

    fn isLabelledFunction(n: *Node) bool {
        var b = n;
        while (b.data == .labeled) b = b.data.labeled.body;
        return b != n and b.data == .function_decl;
    }

    fn parseSubStatementInner(p: *Parser) Error!*Node {
        if (p.atWord("class")) return p.fail("a class declaration is not a statement here", p.tok.start);
        if (p.atWord("let")) {
            const next = try p.peek();
            if (next.kind == .lbracket) return p.fail("a lexical declaration is not a statement here", p.tok.start);
        }
        return p.parseStatement();
    }

    fn loopBody(p: *Parser) Error!*Node {
        p.loops += 1;
        p.breakable += 1;
        defer {
            p.loops -= 1;
            p.breakable -= 1;
        }
        for (p.labels.items) |*l| l.is_loop = true;
        return p.parseSubStatement(false);
    }

    fn parseWhile(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        try p.expect(.lparen, "expected '('");
        const cond = try p.parseExpression(true);
        try p.expect(.rparen, "expected ')'");
        const body = try p.loopBody();
        return p.node(pos, .{ .while_stmt = .{ .cond = cond, .body = body } });
    }

    fn parseDoWhile(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        const body = try p.loopBody();
        try p.expectWord("while", "expected 'while'");
        try p.expect(.lparen, "expected '('");
        const cond = try p.parseExpression(true);
        try p.expect(.rparen, "expected ')'");
        _ = try p.eat(.semicolon); // ASI after do-while always
        return p.node(pos, .{ .do_while = .{ .body = body, .cond = cond } });
    }

    fn parseFor(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        var is_await = false;
        if (p.atWord("await")) {
            if (!p.await_expr) return p.fail("'for await' needs an async context", p.tok.start);
            is_await = true;
            try p.advance();
        }
        try p.expect(.lparen, "expected '('");
        _ = try p.pushScope(false);
        defer p.popScope();
        var initial: ?*Node = null;
        const init_pos = p.tok.start;
        var is_decl = false;
        var decl_kind: ast.DeclKind = .@"var";
        if (p.at(.semicolon)) {
            // no init
        } else if (p.atWord("var") or p.atWord("const") or (p.atWord("let") and try p.letStartsDeclaration())) {
            is_decl = true;
            decl_kind = if (p.atWord("var")) .@"var" else if (p.atWord("let")) .let else .@"const";
            try p.advance();
            const decls = try p.parseDeclarators(decl_kind, false);
            initial = try p.node(init_pos, .{ .var_decl = .{ .kind = decl_kind, .decls = decls } });
        } else {
            // `for (let` in sloppy code where `let` is an identifier: `let`
            // followed by `of` is an error, `in` allowed.
            const starts_let = p.atWord("let");
            const starts_async = p.atWord("async") and !p.tok.escaped;
            const cover_before = p.cover_init_at;
            initial = try p.parseExpressionNoIn();
            if (p.atWord("of") or p.atWord("in")) p.cover_init_at = cover_before; // the literal becomes a pattern
            if (starts_let and p.atWord("of")) return p.fail("'let' cannot start a for-of head", init_pos);
            if (starts_async and p.atWord("of") and initial.?.data == .identifier and !is_await) return p.fail("'async' cannot start a for-of head", init_pos);
        }
        if (p.atWord("of") or p.atWord("in")) {
            const is_of = p.atWord("of");
            if (is_await and !is_of) return p.fail("'for await' needs 'of'", p.tok.start);
            var left = initial.?;
            if (is_decl) {
                const d = left.data.var_decl;
                if (d.decls.len != 1) return p.fail("one binding in a for-in/of head", init_pos);
                if (d.decls[0].init != null) {
                    // Annex B: `for (var x = 1 in obj)` in sloppy code, simple identifier only.
                    if (is_of or p.strict or decl_kind != .@"var" or d.decls[0].target.data != .identifier) return p.fail("no initializer in a for-in/of head", init_pos);
                }
            } else {
                left = try p.toAssignmentTarget(left, false);
            }
            try p.advance();
            const right = if (is_of) try p.parseAssignment(true) else try p.parseExpression(true);
            try p.expect(.rparen, "expected ')'");
            const body = try p.loopBody();
            if (is_of) return p.node(pos, .{ .for_of = .{ .left = left, .right = right, .body = body, .is_await = is_await } });
            return p.node(pos, .{ .for_in = .{ .left = left, .right = right, .body = body } });
        }
        if (is_await) return p.fail("'for await' needs 'of'", p.tok.start);
        if (is_decl) {
            const d = initial.?.data.var_decl;
            for (d.decls) |dc| if (dc.init == null and (d.kind == .@"const" or dc.target.data != .identifier)) return p.fail("this declaration needs an initializer", init_pos);
        }
        try p.expect(.semicolon, "expected ';'");
        const cond: ?*Node = if (p.at(.semicolon)) null else try p.parseExpression(true);
        try p.expect(.semicolon, "expected ';'");
        const update: ?*Node = if (p.at(.rparen)) null else try p.parseExpression(true);
        try p.expect(.rparen, "expected ')'");
        const body = try p.loopBody();
        return p.node(pos, .{ .for_stmt = .{ .init = initial, .cond = cond, .update = update, .body = body } });
    }

    fn parseReturn(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        if (!p.in_function) return p.fail("'return' outside a function", pos);
        try p.advance();
        var arg: ?*Node = null;
        if (!p.at(.semicolon) and !p.at(.rbrace) and !p.at(.eof) and !p.tok.newline_before) arg = try p.parseExpression(true);
        try p.consumeSemicolon();
        return p.node(pos, .{ .return_stmt = arg });
    }

    fn parseBreakContinue(p: *Parser, is_break: bool) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        var label: ?[]const u8 = null;
        if (p.at(.identifier) and !p.tok.newline_before and !p.isReservedWord(p.tok.text)) {
            label = p.tok.text;
            var found = false;
            for (p.labels.items) |l| if (std.mem.eql(u8, l.name, label.?)) {
                found = true;
                if (!is_break and !l.is_loop) return p.fail("'continue' label is not a loop", pos);
            };
            if (!found) return p.fail("undefined label", p.tok.start);
            try p.advance();
        } else {
            if (is_break and p.breakable == 0) return p.fail("'break' outside a loop or switch", pos);
            if (!is_break and p.loops == 0) return p.fail("'continue' outside a loop", pos);
        }
        try p.consumeSemicolon();
        return p.node(pos, if (is_break) .{ .break_stmt = label } else .{ .continue_stmt = label });
    }

    fn parseThrow(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        if (p.tok.newline_before) return p.fail("no line break after 'throw'", p.tok.start);
        const arg = try p.parseExpression(true);
        try p.consumeSemicolon();
        return p.node(pos, .{ .throw_stmt = arg });
    }

    fn parseTry(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        const block = try p.parseBlockStatement();
        var param: ?*Node = null;
        var handler: ?*Node = null;
        var finalizer: ?*Node = null;
        if (try p.eatWord("catch")) {
            const scope = try p.pushScope(false);
            if (try p.eat(.lparen)) {
                if (p.at(.identifier)) {
                    const npos = p.tok.start;
                    const name = try p.bindingIdentifier();
                    scope.catch_param = name;
                    param = try p.node(npos, .{ .identifier = name });
                } else {
                    param = try p.parseBindingPattern();
                    try p.declarePatternNames(param.?, .lexical);
                    scope.catch_param_pattern = true;
                }
                try p.expect(.rparen, "expected ')'");
            }
            // The catch block shares the parameter's scope for
            // redeclaration checks.
            const bpos = p.tok.start;
            try p.expect(.lbrace, "expected '{'");
            const body = try p.parseStatementList();
            try p.expect(.rbrace, "expected '}'");
            handler = try p.node(bpos, .{ .block = body });
            p.popScope();
        }
        if (try p.eatWord("finally")) finalizer = try p.parseBlockStatement();
        if (handler == null and finalizer == null) return p.fail("'try' needs 'catch' or 'finally'", pos);
        return p.node(pos, .{ .try_stmt = .{ .block = block, .param = param, .handler = handler, .finalizer = finalizer } });
    }

    fn parseSwitch(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        try p.expect(.lparen, "expected '('");
        const disc = try p.parseExpression(true);
        try p.expect(.rparen, "expected ')'");
        try p.expect(.lbrace, "expected '{'");
        _ = try p.pushScope(false);
        defer p.popScope();
        p.breakable += 1;
        defer p.breakable -= 1;
        var cases: std.ArrayList(ast.Case) = .empty;
        var saw_default = false;
        while (!p.at(.rbrace)) {
            var cond: ?*Node = null;
            if (try p.eatWord("case")) {
                cond = try p.parseExpression(true);
            } else if (try p.eatWord("default")) {
                if (saw_default) return p.fail("more than one default clause", p.tok.start);
                saw_default = true;
            } else return p.fail("expected 'case' or 'default'", p.tok.start);
            try p.expect(.colon, "expected ':'");
            var body: std.ArrayList(*Node) = .empty;
            while (!p.at(.rbrace) and !p.atWord("case") and !p.atWord("default")) try body.append(p.a, try p.parseStatementListItem());
            try cases.append(p.a, .{ .cond = cond, .body = body.items });
        }
        try p.expect(.rbrace, "expected '}'");
        return p.node(pos, .{ .switch_stmt = .{ .discriminant = disc, .cases = cases.items } });
    }

    fn parseWith(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        if (p.strict) return p.fail("'with' in strict code", pos);
        try p.advance();
        try p.expect(.lparen, "expected '('");
        const obj = try p.parseExpression(true);
        try p.expect(.rparen, "expected ')'");
        const body = try p.parseSubStatement(false);
        return p.node(pos, .{ .with_stmt = .{ .object = obj, .body = body } });
    }

    fn parseLabeled(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        const name = p.tok.text;
        if (std.mem.eql(u8, name, "await") and (p.await_expr or p.module)) return p.fail("'await' cannot be a label here", pos);
        if (std.mem.eql(u8, name, "yield") and (p.strict or p.in_generator)) return p.fail("'yield' cannot be a label here", pos);
        for (p.labels.items) |l| if (std.mem.eql(u8, l.name, name)) return p.fail("duplicate label", pos);
        try p.advance();
        try p.expect(.colon, "expected ':'");
        try p.labels.append(p.a, .{ .name = name, .is_loop = false });
        defer _ = p.labels.pop();
        // A labelled function declaration: sloppy only, never a generator/async.
        if (p.atWord("function")) {
            if (p.strict) return p.fail("a labelled function declaration in strict code", p.tok.start);
            const next = try p.peek();
            if (next.kind == .star) return p.fail("a labelled generator declaration", p.tok.start);
            const f = try p.parseFunctionDeclaration(true);
            return p.node(pos, .{ .labeled = .{ .label = name, .body = f } });
        }
        const body = try p.parseSubStatementInner();
        return p.node(pos, .{ .labeled = .{ .label = name, .body = body } });
    }

    // ----------------------------------------------------- functions

    const Context = struct {
        strict: bool,
        in_function: bool,
        in_generator: bool,
        in_async: bool,
        await_expr: bool,
        allow_super_property: bool,
        allow_super_call: bool,
        allow_new_target: bool,
        no_arguments: bool,
        in_static_block: bool,
        labels: std.ArrayList(Label),
        breakable: u32,
        loops: u32,
        scope: ?*Scope,
        cover_init_at: ?u32,
    };

    fn saveContext(p: *Parser) Context {
        return .{ .strict = p.strict, .in_function = p.in_function, .in_generator = p.in_generator, .in_async = p.in_async, .await_expr = p.await_expr, .allow_super_property = p.allow_super_property, .allow_super_call = p.allow_super_call, .allow_new_target = p.allow_new_target, .no_arguments = p.no_arguments, .in_static_block = p.in_static_block, .labels = p.labels, .breakable = p.breakable, .loops = p.loops, .scope = p.scope, .cover_init_at = p.cover_init_at };
    }

    fn restoreContext(p: *Parser, c: Context) void {
        p.strict = c.strict;
        p.in_function = c.in_function;
        p.in_generator = c.in_generator;
        p.in_async = c.in_async;
        p.await_expr = c.await_expr;
        p.allow_super_property = c.allow_super_property;
        p.allow_super_call = c.allow_super_call;
        p.allow_new_target = c.allow_new_target;
        p.no_arguments = c.no_arguments;
        p.in_static_block = c.in_static_block;
        p.labels = c.labels;
        p.breakable = c.breakable;
        p.loops = c.loops;
        p.scope = c.scope;
        p.cover_init_at = c.cover_init_at;
    }

    /// `function` (or `async function`) declaration. `as_statement`: in
    /// a sloppy `if` body or under a label (Annex B).
    fn parseFunctionDeclaration(p: *Parser, as_statement: bool) Error!*Node {
        const pos = p.tok.start;
        var is_async = false;
        if (p.atWord("async")) {
            is_async = true;
            try p.advance();
        }
        try p.expectWord("function", "expected 'function'");
        const is_generator = try p.eat(.star);
        if (as_statement and (is_async or is_generator)) return p.fail("only a plain function declaration here", pos);
        const npos = p.tok.start;
        // The name binds in the enclosing scope, under the enclosing
        // context's rules for yield/await.
        const name = try p.bindingIdentifier();
        try p.declare(name, if (is_async or is_generator) .function_special else .function, npos);
        const f = try p.parseFunctionRest(pos, name, is_async, is_generator, .normal, true);
        return p.node(pos, .{ .function_decl = f });
    }

    /// A function expression: the name binds inside, under the
    /// function's own generator/async rules.
    fn parseFunctionExpression(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        var is_async = false;
        if (p.atWord("async")) {
            is_async = true;
            try p.advance();
        }
        try p.expectWord("function", "expected 'function'");
        const is_generator = try p.eat(.star);
        var name: ?[]const u8 = null;
        if (!p.at(.lparen)) {
            const c = p.saveContext();
            p.in_generator = is_generator;
            p.await_expr = is_async;
            p.in_static_block = false;
            const npos = p.tok.start;
            name = try p.bindingIdentifier();
            _ = npos;
            p.restoreContext(c);
        }
        const f = try p.parseFunctionRest(pos, name, is_async, is_generator, .normal, false);
        return p.node(pos, .{ .function = f });
    }

    /// Parameters and body, in the function's own context.
    fn parseFunctionRest(p: *Parser, pos: u32, name: ?[]const u8, is_async: bool, is_generator: bool, kind: ast.Function.Kind, is_decl: bool) Error!*ast.Function {
        const c = p.saveContext();
        defer p.restoreContext(c);
        p.fn_depth += 1;
        defer p.fn_depth -= 1;
        p.in_function = true;
        p.in_generator = is_generator;
        p.in_async = is_async;
        p.await_expr = is_async;
        p.in_static_block = false;
        p.labels = .empty;
        p.breakable = 0;
        p.loops = 0;
        p.cover_init_at = null;
        p.no_arguments = false;
        p.allow_new_target = true;
        switch (kind) {
            .normal => {
                p.allow_super_property = false;
                p.allow_super_call = false;
            },
            .method, .getter, .setter, .class_field_init => {
                p.allow_super_property = true;
                p.allow_super_call = false;
            },
            .constructor => {
                p.allow_super_property = true;
                p.allow_super_call = false;
            },
            .derived_constructor => {
                p.allow_super_property = true;
                p.allow_super_call = true;
            },
            .static_block => {},
        }
        const scope = try p.pushScope(true);
        const params_at = p.tok.start;
        try p.expect(.lparen, "expected '('");
        var params: std.ArrayList(*Node) = .empty;
        var simple = true;
        var names: std.ArrayList(NameAt) = .empty;
        const yields_before = p.yield_count;
        const awaits_before = p.await_count;
        while (!p.at(.rparen)) {
            const ppos = p.tok.start;
            if (try p.eat(.ellipsis)) {
                simple = false;
                const target = try p.parseBindingElementTarget();
                try p.collectNames(target, &names);
                try params.append(p.a, try p.node(ppos, .{ .rest = target }));
                if (!p.at(.rparen)) return p.fail("a rest parameter must be last", p.tok.start);
                break;
            }
            const el = try p.parseBindingElement();
            if (el.data != .identifier) simple = false;
            try p.collectNames(el, &names);
            try params.append(p.a, el);
            if (!p.at(.rparen)) try p.expect(.comma, "expected ',' between parameters");
        }
        try p.expect(.rparen, "expected ')'");
        if (is_generator and p.yield_count != yields_before) return p.fail("'yield' in a generator's parameters", pos);
        if (is_async and p.await_count != awaits_before) return p.fail("'await' in an async function's parameters", pos);
        if (kind == .getter and params.items.len != 0) return p.fail("a getter takes no parameters", pos);
        if (kind == .setter and (params.items.len != 1 or params.items[0].data == .rest)) return p.fail("a setter takes exactly one parameter", pos);
        for (names.items) |n| try scope.params.put(p.a, n.name, {});
        // The body, with its own directive prologue. The function node
        // sits below the mark: a dropped body takes everything after it.
        try p.expect(.lbrace, "expected '{'");
        const f = try p.a.create(ast.Function);
        const mark = p.bodyMark();
        var body: std.ArrayList(*Node) = .empty;
        var body_strict = p.strict;
        const directive = try p.directivePrologue(&body, &body_strict);
        if (directive and !simple) return p.fail("'use strict' in a function with non-simple parameters", pos);
        p.strict = body_strict;
        // Duplicate parameters: never in strict code, arrows, methods or
        // non-simple lists.
        const dups_allowed = !p.strict and simple and kind == .normal;
        try p.checkParamNames(names.items, dups_allowed);
        if (p.strict) {
            if (name) |nm| try p.checkBindingName(nm, pos);
        }
        while (!p.at(.rbrace) and !p.at(.eof)) try body.append(p.a, try p.parseStatementListItem());
        if (!p.at(.rbrace)) return p.fail("expected '}'", p.tok.start);
        const end = p.tok.end;
        if (p.cover_init_at) |at_| return p.fail("invalid shorthand property initializer", at_);
        p.popScope();
        f.* = .{ .name = name, .params = params.items, .body = .{ .block = body.items }, .kind = kind, .is_async = is_async, .is_generator = is_generator, .strict = p.strict, .simple_params = simple, .start = pos, .params_start = params_at, .end = end };
        // Before the `}` is passed: the token after it is lexed into a
        // live arena, whichever way this goes.
        try p.maybeDrop(f, mark, is_decl);
        try p.expect(.rbrace, "expected '}'");
        return f;
    }

    /// Memory that must outlive a dropped body: the lists a class keeps
    /// of the private names its members reference grow inside those
    /// members' bodies. From the arena's child when bodies are dropped.
    fn stable(p: *Parser) std.mem.Allocator {
        return if (p.opts.scratch_arena) |ar| ar.child else p.a;
    }

    fn freeReferenced(p: *Parser, ps: *PrivateScope) void {
        for (ps.referenced.items) |r| p.stable().free(r.name);
        ps.referenced.deinit(p.stable());
    }

    /// Whether a name's text is the source's own (else the lexer cooked
    /// it into the arena, where a dropped body would take it).
    fn inSource(p: *const Parser, text: []const u8) bool {
        const lo = @intFromPtr(p.lex.src.ptr);
        return @intFromPtr(text.ptr) >= lo and @intFromPtr(text.ptr) + text.len <= lo + p.lex.src.len;
    }

    /// Where a body starts in the arena, when bodies may be dropped.
    fn bodyMark(p: *Parser) ChunkArena.Mark {
        return if (p.opts.scratch_arena) |ar| ar.mark() else .{ .top = null, .end = 0 };
    }

    /// The source right after a function says it is called on the spot
    /// (`(function () {…})()`, `.call(this)`): compiled with its script.
    fn calledAtOnce(text: []const u8, end: u32) bool {
        var i: usize = end;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == ')')) i += 1;
        return i < text.len and (text[i] == '(' or text[i] == '.');
    }

    /// The preparse: a function that will compile on its first call
    /// keeps a summary of its body (`ast.Function.Lazy`) and gives the
    /// tree back to the arena. Kept: the outermost function when the
    /// caller compiles it now, class parts, one called on the spot, one
    /// with a direct eval or a `with` in it, an arrow that says `super`
    /// (its enclosing method's) — the compiler's own rules, decided here
    /// with the tree still in hand, and the compiler asks for a parse
    /// again should it ever need a dropped body.
    fn maybeDrop(p: *Parser, f: *ast.Function, mark: ChunkArena.Mark, is_decl: bool) Error!void {
        const arena = p.opts.scratch_arena orelse return;
        if (!p.opts.lazy or !drop_enabled) return;
        if (p.fn_depth == 1 and p.opts.keep_outer) return;
        if (f.kind != .normal and f.kind != .method and f.kind != .getter and f.kind != .setter) return;
        if (calledAtOnce(p.lex.src, f.end)) {
            stats.kept_called += 1;
            return;
        }
        const sum = try analysis.Summary.run(p.a, f, is_decl);
        if (sum.dynamic) {
            stats.kept_dynamic += 1;
            return;
        }
        if (f.is_arrow and (sum.uses_super or sum.uses_super_call)) {
            stats.kept_super += 1;
            return;
        }
        // The names mostly live in the source; a cooked one (escapes, a
        // private name's '#') is copied out from under the reset and
        // back in after it, the list with it.
        const n = sum.free.items.len;
        const held = try arena.child.alloc([]const u8, n);
        defer arena.child.free(held);
        var copied: usize = 0;
        defer for (held[0..copied]) |h| if (!p.inSource(h)) arena.child.free(h);
        for (sum.free.items, 0..) |name, i| {
            held[i] = if (p.inSource(name)) name else try arena.child.dupe(u8, name);
            copied = i + 1;
        }
        const lz: ast.Function.Lazy = .{ .free = &.{}, .uses_this = sum.uses_this, .uses_new_target = sum.uses_new_target, .uses_super = sum.uses_super, .uses_super_call = sum.uses_super_call, .is_decl = is_decl };
        arena.reset(mark);
        const free = try p.a.alloc([]const u8, n);
        for (held, 0..) |h, i| free[i] = if (p.inSource(h)) h else try p.a.dupe(u8, h);
        f.body = .{ .lazy = lz };
        f.body.lazy.free = free;
        stats.dropped += 1;
    }

    fn collectNames(p: *Parser, pat: *Node, out: *std.ArrayList(NameAt)) Error!void {
        switch (pat.data) {
            .identifier => |name| try out.append(p.a, .{ .name = name, .pos = pat.pos }),
            .array_pattern => |els| for (els) |el| if (el) |e| try p.collectNames(e, out),
            .object_pattern => |props| for (props) |pr| try p.collectNames(pr.value, out),
            .assign_pattern => |ap| try p.collectNames(ap.target, out),
            .rest => |r| try p.collectNames(r, out),
            else => {},
        }
    }

    fn checkParamNames(p: *Parser, names: []const NameAt, dups_allowed: bool) Error!void {
        for (names, 0..) |n, i| {
            try p.checkBindingName(n.name, n.pos);
            if (!dups_allowed) for (names[0..i]) |m| if (std.mem.eql(u8, m.name, n.name)) return p.fail("duplicate parameter name", n.pos);
        }
    }

    /// An arrow function from parameters already parsed (as a cover) and
    /// the `=>` just consumed.
    fn parseArrowBody(p: *Parser, pos: u32, params: []*Node, is_async: bool) Error!*Node {
        const c = p.saveContext();
        defer p.restoreContext(c);
        p.in_function = true;
        p.in_generator = false;
        p.in_async = is_async;
        p.await_expr = is_async;
        p.in_static_block = false; // an arrow is a boundary for the static block's rule
        p.labels = .empty;
        p.breakable = 0;
        p.loops = 0;
        p.cover_init_at = null;
        // super, new.target and arguments are the enclosing function's.
        const scope = try p.pushScope(true);
        var names: std.ArrayList(NameAt) = .empty;
        var simple = true;
        for (params) |pm| {
            if (pm.data != .identifier) simple = false;
            try p.collectNames(pm, &names);
        }
        for (names.items) |n| try scope.params.put(p.a, n.name, {});
        try p.checkParamNames(names.items, false);
        for (names.items) |n| {
            if (std.mem.eql(u8, n.name, "await") and is_async) return p.fail("'await' cannot be an async arrow's parameter", n.pos);
            if (std.mem.eql(u8, n.name, "yield") and (p.strict or c.in_generator)) return p.fail("'yield' cannot be a parameter here", n.pos);
        }
        const f = try p.a.create(ast.Function);
        p.fn_depth += 1;
        defer p.fn_depth -= 1;
        if (p.at(.lbrace)) {
            try p.advance();
            const mark = p.bodyMark();
            var body: std.ArrayList(*Node) = .empty;
            var body_strict = p.strict;
            const directive = try p.directivePrologue(&body, &body_strict);
            if (directive and !simple) return p.fail("'use strict' in an arrow with non-simple parameters", pos);
            p.strict = body_strict;
            if (p.strict) try p.checkParamNames(names.items, false);
            while (!p.at(.rbrace) and !p.at(.eof)) try body.append(p.a, try p.parseStatementListItem());
            if (!p.at(.rbrace)) return p.fail("expected '}'", p.tok.start);
            const end = p.tok.end;
            if (p.cover_init_at) |at_| return p.fail("invalid shorthand property initializer", at_);
            p.popScope();
            f.* = .{ .params = params, .body = .{ .block = body.items }, .is_async = is_async, .is_arrow = true, .strict = p.strict, .simple_params = simple, .start = pos, .end = end };
            try p.maybeDrop(f, mark, false);
            try p.expect(.rbrace, "expected '}'");
            return p.node(pos, .{ .function = f });
        }
        // An expression body stays: it is small, and the token after it
        // is already lexed.
        const e = try p.parseAssignment(true);
        f.* = .{ .params = params, .body = .{ .expr = e }, .is_async = is_async, .is_arrow = true, .strict = p.strict, .simple_params = simple, .start = pos, .end = p.prev_end };
        if (p.cover_init_at) |at_| return p.fail("invalid shorthand property initializer", at_);
        p.popScope();
        return p.node(pos, .{ .function = f });
    }

    // ------------------------------------------------------- classes

    fn parseClassDeclaration(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        const npos = p.tok.start;
        const was = p.strict;
        p.strict = true; // the name too is strict code
        const name = try p.bindingIdentifier();
        p.strict = was;
        try p.declare(name, .lexical, npos);
        const cl = try p.parseClassRest(pos, name);
        return p.node(pos, .{ .class_decl = cl });
    }

    fn parseClassExpression(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        var name: ?[]const u8 = null;
        if (p.at(.identifier) and !p.atWord("extends")) {
            const was = p.strict;
            p.strict = true;
            name = try p.bindingIdentifier();
            p.strict = was;
        }
        const cl = try p.parseClassRest(pos, name);
        return p.node(pos, .{ .class = cl });
    }

    fn parseClassRest(p: *Parser, pos: u32, name: ?[]const u8) Error!*ast.Class {
        const c = p.saveContext();
        defer p.restoreContext(c);
        p.strict = true;
        var super_class: ?*Node = null;
        if (try p.eatWord("extends")) {
            p.no_arrow = true;
            defer p.no_arrow = false;
            super_class = try p.parseLeftHandSide();
            if (isBareArrow(super_class.?)) return p.fail("an arrow cannot be a class heritage", super_class.?.pos);
        }
        try p.expect(.lbrace, "expected '{'");
        const privates = try p.a.create(PrivateScope);
        privates.* = .{ .parent = p.class_privates };
        p.class_privates = privates;
        defer p.class_privates = privates.parent;
        defer p.freeReferenced(privates);
        var members: std.ArrayList(ast.Class.Member) = .empty;
        var saw_constructor = false;
        while (!p.at(.rbrace)) {
            if (try p.eat(.semicolon)) continue;
            const m = try p.parseClassMember(super_class != null, &saw_constructor, privates);
            try members.append(p.a, m);
        }
        const end = p.tok.end;
        try p.expect(.rbrace, "expected '}'");
        // Every private name referenced must be declared in this class or
        // an enclosing one.
        for (privates.referenced.items) |r| {
            var sc: ?*PrivateScope = privates;
            var found = false;
            while (sc) |s| : (sc = s.parent) if (s.declared.contains(r.name)) {
                found = true;
                break;
            };
            if (!found) {
                if (privates.parent == null) return p.fail("undeclared private name", r.pos);
                try privates.parent.?.referenced.append(p.stable(), .{ .name = try p.stable().dupe(u8, r.name), .pos = r.pos });
            }
        }
        const cl = try p.a.create(ast.Class);
        cl.* = .{ .name = name, .super_class = super_class, .members = members.items, .start = pos, .end = end };
        return cl;
    }

    fn parseClassMember(p: *Parser, derived: bool, saw_constructor: *bool, privates: *PrivateScope) Error!ast.Class.Member {
        const pos = p.tok.start;
        var is_static = false;
        var is_async = false;
        var is_generator = false;
        var accessor: enum { none, get, set } = .none;
        // `static` is a modifier unless it names the member.
        if (p.atWord("static") and !p.tok.escaped) {
            const next = try p.peek();
            if (next.kind != .lparen and next.kind != .assign and next.kind != .semicolon and next.kind != .rbrace and !(next.newline_before and next.kind != .lbrace and next.kind != .identifier and next.kind != .string and next.kind != .number and next.kind != .lbracket and next.kind != .star and next.kind != .private_name)) {
                is_static = true;
                try p.advance();
                // A static initialization block.
                if (p.at(.lbrace)) return p.parseStaticBlock(pos);
            }
        }
        if (p.atWord("async") and !p.tok.escaped) {
            const next = try p.peek();
            if (next.kind != .lparen and next.kind != .assign and next.kind != .semicolon and next.kind != .rbrace and !next.newline_before) {
                is_async = true;
                try p.advance();
            }
        }
        if (try p.eat(.star)) is_generator = true;
        if ((p.atWord("get") or p.atWord("set")) and !p.tok.escaped and !is_async and !is_generator) {
            const next = try p.peek();
            if (next.kind != .lparen and next.kind != .assign and next.kind != .semicolon and next.kind != .rbrace and !(next.kind == .star and next.newline_before)) {
                accessor = if (p.atWord("get")) .get else .set;
                try p.advance();
            }
        }
        // The key.
        const kpos = p.tok.start;
        var computed = false;
        var key: *Node = undefined;
        var key_name: ?[]const u8 = null; // for constructor/prototype checks
        var is_private = false;
        if (p.at(.private_name)) {
            is_private = true;
            key_name = p.tok.text;
            key = try p.node(kpos, .{ .private_name = p.tok.text });
            if (std.mem.eql(u8, p.tok.text, "#constructor")) return p.fail("#constructor is not allowed", kpos);
            try p.advance();
        } else if (try p.eat(.lbracket)) {
            computed = true;
            key = try p.parseAssignment(true);
            try p.expect(.rbracket, "expected ']'");
        } else if (p.at(.string)) {
            key_name = p.tok.text;
            key = try p.node(kpos, .{ .string = p.tok.text });
            try p.advance();
        } else if (p.at(.number)) {
            key = try p.node(kpos, .{ .number = p.tok.number });
            try p.advance();
        } else if (p.at(.bigint)) {
            key = try p.node(kpos, .{ .bigint = p.tok.raw });
            try p.advance();
        } else if (p.at(.identifier)) {
            key_name = p.tok.text;
            key = try p.node(kpos, .{ .string = p.tok.text });
            try p.advance();
        } else return p.fail("expected a class member", kpos);
        if (is_private) {
            const slot: u8 = (switch (accessor) {
                .none => @as(u8, 1),
                .get => 2,
                .set => 3,
            }) | (if (is_static) @as(u8, 8) else 0);
            if (privates.declared.get(key_name.?)) |have| {
                // A getter and a setter may pair, with the same staticness.
                const pair = ((have & 7) == 2 and (slot & 7) == 3) or ((have & 7) == 3 and (slot & 7) == 2);
                if (!pair or (have & 8) != (slot & 8)) return p.fail("duplicate private name", kpos);
                try privates.declared.put(p.a, key_name.?, 4 | (slot & 8));
            } else try privates.declared.put(p.a, key_name.?, slot);
        }
        // A field?
        if (p.at(.assign) or p.at(.semicolon) or p.at(.rbrace) or (p.tok.newline_before and !p.at(.lparen))) {
            if (accessor != .none or is_async or is_generator) return p.fail("expected '('", p.tok.start);
            if (key_name) |kn| if (!computed) {
                if (std.mem.eql(u8, kn, "constructor") and !is_private) return p.fail("a field cannot be named 'constructor'", kpos);
                if (is_static and std.mem.eql(u8, kn, "prototype")) return p.fail("a static field cannot be named 'prototype'", kpos);
            };
            var value: ?*Node = null;
            if (try p.eat(.assign)) {
                const c = p.saveContext();
                defer p.restoreContext(c);
                p.in_function = true;
                p.in_generator = false;
                p.in_async = false;
                p.await_expr = false;
                p.allow_super_property = true;
                p.allow_super_call = false;
                p.allow_new_target = true;
                p.no_arguments = true;
                p.labels = .empty;
                p.breakable = 0;
                p.loops = 0;
                p.cover_init_at = null;
                const fpos = p.tok.start;
                _ = try p.pushScope(true);
                const e = try p.parseAssignment(true);
                if (p.cover_init_at) |at_| return p.fail("invalid shorthand property initializer", at_);
                p.popScope();
                const f = try p.a.create(ast.Function);
                f.* = .{ .params = &.{}, .body = .{ .expr = e }, .kind = .class_field_init, .strict = true, .start = fpos, .end = p.prev_end };
                value = try p.node(fpos, .{ .function = f });
            }
            try p.consumeSemicolon();
            return .{ .kind = .field, .key = key, .computed = computed, .is_static = is_static, .value = value };
        }
        // A method.
        var kind: ast.Function.Kind = switch (accessor) {
            .none => .method,
            .get => .getter,
            .set => .setter,
        };
        if (key_name) |kn| if (!computed and !is_private and std.mem.eql(u8, kn, "constructor") and !is_static) {
            if (accessor != .none or is_async or is_generator) return p.fail("the constructor cannot be a getter, setter, generator or async", kpos);
            if (saw_constructor.*) return p.fail("more than one constructor", kpos);
            saw_constructor.* = true;
            kind = if (derived) .derived_constructor else .constructor;
        };
        if (is_static and !computed and !is_private and key_name != null and std.mem.eql(u8, key_name.?, "prototype")) return p.fail("a static member cannot be named 'prototype'", kpos);
        const f = try p.parseFunctionRest(pos, null, is_async, is_generator, kind, false);
        f.is_generator = is_generator;
        const fnode = try p.node(pos, .{ .function = f });
        return .{ .kind = switch (accessor) {
            .none => .method,
            .get => .getter,
            .set => .setter,
        }, .key = key, .computed = computed, .is_static = is_static, .value = fnode };
    }

    fn parseStaticBlock(p: *Parser, pos: u32) Error!ast.Class.Member {
        const c = p.saveContext();
        defer p.restoreContext(c);
        p.in_function = true;
        p.in_generator = false;
        p.in_async = false;
        p.await_expr = false;
        p.in_static_block = true;
        p.allow_super_property = true;
        p.allow_super_call = false;
        p.allow_new_target = true;
        p.no_arguments = true;
        p.labels = .empty;
        p.breakable = 0;
        p.loops = 0;
        p.cover_init_at = null;
        try p.expect(.lbrace, "expected '{'");
        _ = try p.pushScope(true);
        var body: std.ArrayList(*Node) = .empty;
        while (!p.at(.rbrace) and !p.at(.eof)) {
            const st = try p.parseStatementListItem();
            if (st.data == .return_stmt) return p.fail("'return' in a static block", st.pos);
            try body.append(p.a, st);
        }
        const end = p.tok.end;
        try p.expect(.rbrace, "expected '}'");
        if (p.cover_init_at) |at_| return p.fail("invalid shorthand property initializer", at_);
        p.popScope();
        const f = try p.a.create(ast.Function);
        f.* = .{ .params = &.{}, .body = .{ .block = body.items }, .kind = .static_block, .strict = true, .start = pos, .end = end };
        const key = try p.node(pos, .{ .string = "" });
        return .{ .kind = .static_block, .key = key, .is_static = true, .value = try p.node(pos, .{ .function = f }) };
    }

    // ------------------------------------------------------- modules

    fn parseModuleItem(p: *Parser) Error!*Node {
        if (p.atWord("import")) {
            const next = try p.peek();
            if (next.kind != .lparen and next.kind != .dot) return p.parseImport();
        }
        if (p.atWord("export")) return p.parseExport();
        return p.parseStatementListItem();
    }

    fn moduleSpecifier(p: *Parser) Error![]const u8 {
        if (!p.at(.string)) return p.fail("expected a module specifier", p.tok.start);
        const s = p.tok.text;
        try p.advance();
        return s;
    }

    fn parseImport(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        var imp: ast.Import = .{ .source = "", .named = &.{} };
        if (p.at(.string)) {
            imp.source = try p.moduleSpecifier();
            try p.skipImportAttributes();
            try p.consumeSemicolon();
            return p.node(pos, .{ .import_decl = imp });
        }
        var named: std.ArrayList(ast.Import.Named) = .empty;
        if (p.at(.identifier) and !p.atWord("from") or (p.atWord("from") and (try p.peek()).isWord("from"))) {
            const npos = p.tok.start;
            const name = try p.bindingIdentifier();
            try p.declare(name, .lexical, npos);
            imp.default = name;
            if (!try p.eat(.comma)) {
                try p.expectWord("from", "expected 'from'");
                imp.source = try p.moduleSpecifier();
                try p.skipImportAttributes();
                try p.consumeSemicolon();
                return p.node(pos, .{ .import_decl = imp });
            }
        }
        if (try p.eat(.star)) {
            try p.expectWord("as", "expected 'as'");
            const npos = p.tok.start;
            const name = try p.bindingIdentifier();
            try p.declare(name, .lexical, npos);
            imp.namespace = name;
        } else {
            try p.expect(.lbrace, "expected '{'");
            while (!p.at(.rbrace)) {
                const npos = p.tok.start;
                var imported: []const u8 = undefined;
                var local: []const u8 = undefined;
                if (p.at(.string)) {
                    imported = p.tok.text;
                    try p.advance();
                    try p.expectWord("as", "a string import name needs 'as'");
                    local = try p.bindingIdentifier();
                } else if (p.at(.identifier)) {
                    imported = p.tok.text;
                    try p.advance();
                    if (try p.eatWord("as")) {
                        local = try p.bindingIdentifier();
                    } else {
                        if (p.isReservedWord(imported)) return p.fail("keyword cannot be an import binding", npos);
                        try p.checkBindingName(imported, npos);
                        local = imported;
                    }
                } else return p.fail("expected an import name", npos);
                try p.declare(local, .lexical, npos);
                try named.append(p.a, .{ .imported = imported, .local = local });
                if (!p.at(.rbrace)) try p.expect(.comma, "expected ','");
            }
            try p.expect(.rbrace, "expected '}'");
        }
        try p.expectWord("from", "expected 'from'");
        imp.source = try p.moduleSpecifier();
        imp.named = named.items;
        try p.skipImportAttributes();
        try p.consumeSemicolon();
        return p.node(pos, .{ .import_decl = imp });
    }

    /// `with { type: "json" }` after a specifier: accepted, not kept.
    fn skipImportAttributes(p: *Parser) Error!void {
        if (!p.atWord("with") and !(p.atWord("assert") and !p.tok.newline_before)) return;
        try p.advance();
        try p.expect(.lbrace, "expected '{'");
        var keys: std.ArrayList([]const u8) = .empty;
        while (!p.at(.rbrace)) {
            if (!p.at(.identifier) and !p.at(.string)) return p.fail("expected an attribute key", p.tok.start);
            for (keys.items) |k| if (std.mem.eql(u8, k, p.tok.text)) return p.fail("duplicate import attribute", p.tok.start);
            try keys.append(p.a, p.tok.text);
            try p.advance();
            try p.expect(.colon, "expected ':'");
            if (!p.at(.string)) return p.fail("expected an attribute value", p.tok.start);
            try p.advance();
            if (!p.at(.rbrace)) try p.expect(.comma, "expected ','");
        }
        try p.expect(.rbrace, "expected '}'");
    }

    /// Every exported name once; a string name must be well-formed UTF-16.
    fn noteExport(p: *Parser, name: []const u8, pos: u32) Error!void {
        if (hasLoneSurrogate(name)) return p.fail("an export name must be well-formed", pos);
        if (p.exported.contains(name)) return p.fail("duplicate export", pos);
        try p.exported.put(p.a, name, {});
    }

    fn noteExportedPattern(p: *Parser, pat: *Node) Error!void {
        switch (pat.data) {
            .identifier => |name| try p.noteExport(name, pat.pos),
            .array_pattern => |els| for (els) |el| if (el) |e| try p.noteExportedPattern(e),
            .object_pattern => |props| for (props) |pr| try p.noteExportedPattern(pr.value),
            .assign_pattern => |ap| try p.noteExportedPattern(ap.target),
            .rest => |r| try p.noteExportedPattern(r),
            else => {},
        }
    }

    fn parseExport(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        if (try p.eat(.star)) {
            var as: ?[]const u8 = null;
            if (try p.eatWord("as")) {
                if (!p.at(.identifier) and !p.at(.string)) return p.fail("expected an export name", p.tok.start);
                as = p.tok.text;
                try p.noteExport(as.?, p.tok.start);
                try p.advance();
            }
            try p.expectWord("from", "expected 'from'");
            const src = try p.moduleSpecifier();
            try p.skipImportAttributes();
            try p.consumeSemicolon();
            return p.node(pos, .{ .export_decl = .{ .all = .{ .as = as, .source = src } } });
        }
        if (try p.eatWord("default")) {
            try p.noteExport("default", pos);
            if (p.atWord("function") or (p.atWord("async") and (try p.peek()).isWord("function") and !(try p.peek()).newline_before)) {
                // A default function may be anonymous.
                const fpos = p.tok.start;
                var is_async = false;
                if (p.atWord("async")) {
                    is_async = true;
                    try p.advance();
                }
                try p.advance(); // function
                const is_generator = try p.eat(.star);
                var name: ?[]const u8 = null;
                if (p.at(.identifier)) {
                    const npos = p.tok.start;
                    name = try p.bindingIdentifier();
                    try p.declare(name.?, .function, npos);
                }
                const f = try p.parseFunctionRest(fpos, name, is_async, is_generator, .normal, true);
                return p.node(pos, .{ .export_decl = .{ .default = try p.node(fpos, .{ .function_decl = f }) } });
            }
            if (p.atWord("class")) {
                const cpos = p.tok.start;
                try p.advance();
                var name: ?[]const u8 = null;
                if (p.at(.identifier) and !p.atWord("extends")) {
                    const npos = p.tok.start;
                    name = try p.bindingIdentifier();
                    try p.declare(name.?, .lexical, npos);
                }
                const cl = try p.parseClassRest(cpos, name);
                return p.node(pos, .{ .export_decl = .{ .default = try p.node(cpos, .{ .class_decl = cl }) } });
            }
            const e = try p.parseAssignment(true);
            try p.consumeSemicolon();
            return p.node(pos, .{ .export_decl = .{ .default = e } });
        }
        if (p.at(.lbrace)) {
            try p.advance();
            var specs: std.ArrayList(ast.Export.Named) = .empty;
            var locals: std.ArrayList(NameAt) = .empty;
            var needs_from = false;
            while (!p.at(.rbrace)) {
                if (!p.at(.identifier) and !p.at(.string)) return p.fail("expected an export name", p.tok.start);
                if (p.at(.string)) needs_from = true;
                const local = p.tok.text;
                if (p.at(.identifier) and p.isReservedWord(local) and !std.mem.eql(u8, local, "await") and !std.mem.eql(u8, local, "yield")) needs_from = true;
                const lpos = p.tok.start;
                try p.advance();
                var exported = local;
                var epos = lpos;
                if (try p.eatWord("as")) {
                    if (!p.at(.identifier) and !p.at(.string)) return p.fail("expected an export name", p.tok.start);
                    exported = p.tok.text;
                    epos = p.tok.start;
                    try p.advance();
                }
                try p.noteExport(exported, epos);
                try specs.append(p.a, .{ .local = local, .exported = exported });
                try locals.append(p.a, .{ .name = local, .pos = lpos });
                if (!p.at(.rbrace)) try p.expect(.comma, "expected ','");
            }
            try p.expect(.rbrace, "expected '}'");
            var src: ?[]const u8 = null;
            if (try p.eatWord("from")) {
                src = try p.moduleSpecifier();
                try p.skipImportAttributes();
            } else {
                if (needs_from) return p.fail("a string or keyword export name needs 'from'", pos);
                for (locals.items) |l| try p.export_locals.append(p.a, l);
            }
            try p.consumeSemicolon();
            return p.node(pos, .{ .export_decl = .{ .named = .{ .specifiers = specs.items, .source = src } } });
        }
        // A declaration: its names are exported.
        var decl: *Node = undefined;
        if (p.atWord("var")) {
            decl = try p.parseVarStatement();
        } else if (p.atWord("let") or p.atWord("const")) {
            decl = try p.parseLexicalDeclaration(if (p.atWord("let")) .let else .@"const", true);
        } else if (p.atWord("function") or p.atWord("async")) {
            decl = try p.parseFunctionDeclaration(false);
        } else if (p.atWord("class")) {
            decl = try p.parseClassDeclaration();
        } else return p.fail("expected a declaration to export", p.tok.start);
        switch (decl.data) {
            .var_decl => |vd| for (vd.decls) |d| try p.noteExportedPattern(d.target),
            .function_decl => |f| try p.noteExport(f.name.?, decl.pos),
            .class_decl => |c| try p.noteExport(c.name.?, decl.pos),
            else => {},
        }
        return p.node(pos, .{ .export_decl = .{ .declaration = decl } });
    }

    // ---------------------------------------------------- expressions

    fn parseExpression(p: *Parser, allow_in: bool) Error!*Node {
        const pos = p.tok.start;
        const first = try p.parseAssignment(allow_in);
        if (!p.at(.comma)) return first;
        var list: std.ArrayList(*Node) = .empty;
        try list.append(p.a, first);
        while (try p.eat(.comma)) try list.append(p.a, try p.parseAssignment(allow_in));
        return p.node(pos, .{ .sequence = list.items });
    }

    fn parseExpressionNoIn(p: *Parser) Error!*Node {
        return p.parseExpression(false);
    }

    fn isAssignOp(k: Kind) ?ast.AssignOp {
        return switch (k) {
            .assign => .assign,
            .plus_assign => .add,
            .minus_assign => .sub,
            .star_assign => .mul,
            .slash_assign => .div,
            .percent_assign => .mod,
            .star_star_assign => .exp,
            .shl_assign => .shl,
            .shr_assign => .shr,
            .ushr_assign => .ushr,
            .amp_assign => .bitand,
            .pipe_assign => .bitor,
            .caret_assign => .bitxor,
            .amp_amp_assign => .@"and",
            .pipe_pipe_assign => .@"or",
            .question_question_assign => .nullish,
            else => null,
        };
    }

    fn parseAssignment(p: *Parser, allow_in: bool) Error!*Node {
        const pos = p.tok.start;
        // yield
        if (p.atWord("yield") and p.in_generator) return p.parseYield(allow_in);
        // Arrow with a single identifier parameter: `x => ...`, `async x => ...`.
        if (p.at(.identifier)) {
            const next = try p.peek();
            if (next.kind == .arrow and !next.newline_before and !p.isReservedWord(p.tok.text)) {
                const name = try p.bindingIdentifier();
                const id = try p.node(pos, .{ .identifier = name });
                try p.advance(); // =>
                const params = try p.a.dupe(*Node, &.{id});
                return p.parseArrowBody(pos, params, false);
            }
            if (p.atWord("async") and !p.tok.escaped and next.kind == .identifier and !next.newline_before and !next.isWord("function")) {
                // `async x =>`
                const st = p.lex.save();
                const tok = p.tok;
                try p.advance();
                const next2 = try p.peek();
                if (next2.kind == .arrow and !next2.newline_before) {
                    const ppos = p.tok.start;
                    const c = p.saveContext();
                    p.await_expr = true;
                    const name = p.bindingIdentifier() catch |e| {
                        p.restoreContext(c);
                        return e;
                    };
                    p.restoreContext(c);
                    const id = try p.node(ppos, .{ .identifier = name });
                    try p.advance(); // =>
                    const params = try p.a.dupe(*Node, &.{id});
                    return p.parseArrowBody(pos, params, true);
                }
                p.lex.restore(st);
                p.tok = tok;
            }
        }
        const cover_before = p.cover_init_at;
        const left = try p.parseConditional(allow_in);
        if (isBareArrow(left)) return left;
        if (isAssignOp(p.tok.kind)) |op| {
            const target = if (op == .assign) try p.toAssignmentTarget(left, true) else blk: {
                if (!isSimpleTarget(left)) return p.fail("invalid assignment target", left.pos);
                try p.checkSimpleTarget(left);
                break :blk left;
            };
            try p.advance();
            const value = try p.parseAssignment(allow_in);
            // A cover-initialized name inside a converted pattern is used up.
            if (op == .assign) p.cover_init_at = cover_before;
            return p.node(pos, .{ .assign = .{ .op = op, .target = target, .value = value } });
        }
        return left;
    }

    fn parseYield(p: *Parser, allow_in: bool) Error!*Node {
        const pos = p.tok.start;
        p.yield_count += 1;
        try p.advance();
        var delegate = false;
        var arg: ?*Node = null;
        if (!p.tok.newline_before) {
            if (try p.eat(.star)) {
                delegate = true;
                arg = try p.parseAssignment(allow_in);
            } else if (!p.at(.rparen) and !p.at(.rbracket) and !p.at(.rbrace) and !p.at(.comma) and !p.at(.semicolon) and !p.at(.colon) and !p.at(.eof) and !p.at(.template_middle) and !p.at(.template_tail) and !(p.atWord("in") and !allow_in)) {
                arg = try p.parseAssignment(allow_in);
            }
        }
        return p.node(pos, .{ .yield = .{ .arg = arg, .delegate = delegate } });
    }

    fn parseConditional(p: *Parser, allow_in: bool) Error!*Node {
        const pos = p.tok.start;
        const cond = try p.parseBinary(0, allow_in);
        if (isBareArrow(cond)) return cond;
        if (!try p.eat(.question)) return cond;
        const then = try p.parseAssignment(true);
        try p.expect(.colon, "expected ':'");
        const otherwise = try p.parseAssignment(allow_in);
        return p.node(pos, .{ .conditional = .{ .cond = cond, .then = then, .otherwise = otherwise } });
    }

    const BinInfo = struct { prec: u8, right: bool = false };

    fn binaryInfo(p: *const Parser, allow_in: bool) ?struct { info: BinInfo, kind: enum { binary, logical }, bop: ast.BinaryOp, lop: ast.LogicalOp } {
        const t = p.tok;
        const B = ast.BinaryOp;
        const L = ast.LogicalOp;
        return switch (t.kind) {
            .question_question => .{ .info = .{ .prec = 1 }, .kind = .logical, .bop = .add, .lop = L.nullish },
            .pipe_pipe => .{ .info = .{ .prec = 2 }, .kind = .logical, .bop = .add, .lop = L.@"or" },
            .amp_amp => .{ .info = .{ .prec = 3 }, .kind = .logical, .bop = .add, .lop = L.@"and" },
            .pipe => .{ .info = .{ .prec = 4 }, .kind = .binary, .bop = B.bitor, .lop = .@"or" },
            .caret => .{ .info = .{ .prec = 5 }, .kind = .binary, .bop = B.bitxor, .lop = .@"or" },
            .amp => .{ .info = .{ .prec = 6 }, .kind = .binary, .bop = B.bitand, .lop = .@"or" },
            .eq => .{ .info = .{ .prec = 7 }, .kind = .binary, .bop = B.eq, .lop = .@"or" },
            .ne => .{ .info = .{ .prec = 7 }, .kind = .binary, .bop = B.ne, .lop = .@"or" },
            .eq_strict => .{ .info = .{ .prec = 7 }, .kind = .binary, .bop = B.eq_strict, .lop = .@"or" },
            .ne_strict => .{ .info = .{ .prec = 7 }, .kind = .binary, .bop = B.ne_strict, .lop = .@"or" },
            .lt => .{ .info = .{ .prec = 8 }, .kind = .binary, .bop = B.lt, .lop = .@"or" },
            .gt => .{ .info = .{ .prec = 8 }, .kind = .binary, .bop = B.gt, .lop = .@"or" },
            .le => .{ .info = .{ .prec = 8 }, .kind = .binary, .bop = B.le, .lop = .@"or" },
            .ge => .{ .info = .{ .prec = 8 }, .kind = .binary, .bop = B.ge, .lop = .@"or" },
            .shl => .{ .info = .{ .prec = 9 }, .kind = .binary, .bop = B.shl, .lop = .@"or" },
            .shr => .{ .info = .{ .prec = 9 }, .kind = .binary, .bop = B.shr, .lop = .@"or" },
            .ushr => .{ .info = .{ .prec = 9 }, .kind = .binary, .bop = B.ushr, .lop = .@"or" },
            .plus => .{ .info = .{ .prec = 10 }, .kind = .binary, .bop = B.add, .lop = .@"or" },
            .minus => .{ .info = .{ .prec = 10 }, .kind = .binary, .bop = B.sub, .lop = .@"or" },
            .star => .{ .info = .{ .prec = 11 }, .kind = .binary, .bop = B.mul, .lop = .@"or" },
            .slash => .{ .info = .{ .prec = 11 }, .kind = .binary, .bop = B.div, .lop = .@"or" },
            .percent => .{ .info = .{ .prec = 11 }, .kind = .binary, .bop = B.mod, .lop = .@"or" },
            .star_star => .{ .info = .{ .prec = 12, .right = true }, .kind = .binary, .bop = B.exp, .lop = .@"or" },
            .identifier => if (t.isWord("instanceof")) .{ .info = .{ .prec = 8 }, .kind = .binary, .bop = B.instanceof, .lop = .@"or" } else if (t.isWord("in") and allow_in) .{ .info = .{ .prec = 8 }, .kind = .binary, .bop = B.in, .lop = .@"or" } else null,
            else => null,
        };
    }

    /// Precedence climbing over the binary and logical operators; `??`
    /// may not mix with `||`/`&&` without parentheses.
    fn parseBinary(p: *Parser, min_prec: u8, allow_in: bool) Error!*Node {
        const pos = p.tok.start;
        var left: *Node = undefined;
        // `#x in obj`
        if (p.at(.private_name) and min_prec <= 8) {
            const next = try p.peek();
            if (next.isWord("in") and allow_in) {
                try p.notePrivateReference(p.tok.text, pos);
                left = try p.node(pos, .{ .private_name = p.tok.text });
                try p.advance();
                try p.advance(); // in
                const right = try p.parseBinary(9, allow_in);
                left = try p.node(pos, .{ .binary = .{ .op = .in, .left = left, .right = right } });
                return p.continueBinary(left, pos, min_prec, allow_in);
            }
        }
        left = try p.parseUnary();
        if (isBareArrow(left)) return left;
        return p.continueBinary(left, pos, min_prec, allow_in);
    }

    fn continueBinary(p: *Parser, left_in: *Node, pos: u32, min_prec: u8, allow_in: bool) Error!*Node {
        var left = left_in;
        while (p.binaryInfo(allow_in)) |bi| {
            if (bi.info.prec < min_prec) break;
            const op_pos = p.tok.start;
            if (bi.bop == .exp and !left.parenthesized and (left.data == .unary or (left.data == .await))) return p.fail("unary operator before '**' needs parentheses", op_pos);
            try p.advance();
            const next_min: u8 = if (bi.info.right) bi.info.prec else bi.info.prec + 1;
            const right = try p.parseBinary(next_min, allow_in);
            if (bi.kind == .logical) {
                // `??` beside `||`/`&&`: only with parentheses.
                if (bi.lop == .nullish) {
                    if ((left.data == .logical and left.data.logical.op != .nullish and !left.parenthesized) or (right.data == .logical and right.data.logical.op != .nullish and !right.parenthesized)) return p.fail("'??' cannot mix with '||' or '&&' without parentheses", op_pos);
                } else {
                    if ((left.data == .logical and left.data.logical.op == .nullish and !left.parenthesized) or (right.data == .logical and right.data.logical.op == .nullish and !right.parenthesized)) return p.fail("'??' cannot mix with '||' or '&&' without parentheses", op_pos);
                }
                left = try p.node(pos, .{ .logical = .{ .op = bi.lop, .left = left, .right = right } });
            } else {
                left = try p.node(pos, .{ .binary = .{ .op = bi.bop, .left = left, .right = right } });
            }
        }
        return left;
    }

    fn parseUnary(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        const op: ?ast.UnaryOp = switch (p.tok.kind) {
            .minus => .neg,
            .plus => .pos,
            .bang => .not,
            .tilde => .bitnot,
            .identifier => if (p.tok.escaped) null else if (p.atWord("typeof")) .typeof else if (p.atWord("void")) .void else if (p.atWord("delete")) .delete else null,
            else => null,
        };
        if (op) |o| {
            try p.advance();
            const arg = try p.parseUnary();
            if (o == .delete) {
                if (p.strict and arg.data == .identifier) return p.fail("'delete' of an identifier in strict code", pos);
                if (arg.data == .member and arg.data.member.property.data == .private_name) return p.fail("'delete' of a private name", pos);
                if (arg.data == .optional_chain and endsInPrivate(arg.data.optional_chain)) return p.fail("'delete' of a private name", pos);
            }
            return p.node(pos, .{ .unary = .{ .op = o, .arg = arg } });
        }
        if (p.at(.plus_plus) or p.at(.minus_minus)) {
            const inc = p.at(.plus_plus);
            try p.advance();
            const arg = try p.parseUnary();
            if (!isSimpleTarget(arg)) return p.fail("invalid update target", arg.pos);
            try p.checkSimpleTarget(arg);
            return p.node(pos, .{ .update = .{ .increment = inc, .prefix = true, .arg = arg } });
        }
        if (p.atWord("await") and p.await_expr and !p.tok.escaped) {
            if (p.in_static_block) return p.fail("'await' in a static block", pos);
            p.await_count += 1;
            try p.advance();
            const arg = try p.parseUnary();
            return p.node(pos, .{ .await = arg });
        }
        return p.parsePostfix();
    }

    fn endsInPrivate(n: *Node) bool {
        return n.data == .member and n.data.member.property.data == .private_name;
    }

    fn parsePostfix(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        const e = try p.parseLeftHandSide();
        if (isBareArrow(e)) return e;
        if ((p.at(.plus_plus) or p.at(.minus_minus)) and !p.tok.newline_before) {
            const inc = p.at(.plus_plus);
            if (!isSimpleTarget(e)) return p.fail("invalid update target", e.pos);
            try p.checkSimpleTarget(e);
            try p.advance();
            return p.node(pos, .{ .update = .{ .increment = inc, .prefix = false, .arg = e } });
        }
        return e;
    }

    /// An arrow function not wrapped in parentheses ends the expression it
    /// is in: `x => x()` is an arrow whose body is a call, and nothing
    /// may follow it but the enclosing grammar.
    fn isBareArrow(n: *Node) bool {
        return n.data == .function and n.data.function.is_arrow and !n.parenthesized;
    }

    /// A simple assignment target: an identifier or a member access (not
    /// an optional chain, not a call).
    fn isSimpleTarget(n: *Node) bool {
        return switch (n.data) {
            .identifier => true,
            .member => true,
            else => false,
        };
    }

    fn checkSimpleTarget(p: *Parser, n: *Node) Error!void {
        if (n.data == .identifier) {
            const name = n.data.identifier;
            if (p.strict and (std.mem.eql(u8, name, "eval") or std.mem.eql(u8, name, "arguments"))) return p.fail("cannot assign to 'eval' or 'arguments' in strict code", n.pos);
        }
    }

    /// LeftHandSideExpression: `new`, calls, member accesses, optional
    /// chains, tagged templates, `super`, `import()`.
    fn parseLeftHandSide(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        var e: *Node = undefined;
        if (p.atWord("new") and !p.tok.escaped) {
            e = try p.parseNew();
        } else if (p.atWord("super") and !p.tok.escaped) {
            try p.advance();
            if (p.at(.lparen)) {
                if (!p.allow_super_call) return p.fail("'super()' only in a derived class constructor", pos);
                const args = try p.parseArguments();
                e = try p.node(pos, .{ .call = .{ .callee = try p.node(pos, .super), .args = args, .optional = false } });
            } else if (p.at(.dot) or p.at(.lbracket)) {
                if (!p.allow_super_property) return p.fail("'super.x' only in a method", pos);
                e = try p.node(pos, .super);
            } else return p.fail("'super' must be followed by '(' or a property", pos);
        } else if (p.atWord("import") and !p.tok.escaped) {
            try p.advance();
            if (try p.eat(.dot)) {
                if (!p.atWord("meta")) return p.fail("expected 'import.meta'", p.tok.start);
                if (!p.module) return p.fail("'import.meta' only in a module", pos);
                try p.advance();
                e = try p.node(pos, .import_meta);
            } else {
                try p.expect(.lparen, "expected '(' after 'import'");
                const src = try p.parseAssignment(true);
                var options: ?*Node = null;
                if (try p.eat(.comma)) {
                    if (!p.at(.rparen)) {
                        options = try p.parseAssignment(true);
                        _ = try p.eat(.comma);
                    }
                }
                try p.expect(.rparen, "expected ')'");
                e = try p.node(pos, .{ .import_call = .{ .source = src, .options = options } });
            }
        } else {
            e = try p.parsePrimary();
            if (isBareArrow(e)) return e;
        }
        return p.parseCallTail(e, pos, false);
    }

    fn parseNew(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance(); // new
        if (try p.eat(.dot)) {
            if (!p.atWord("target")) return p.fail("expected 'new.target'", p.tok.start);
            if (!p.allow_new_target) return p.fail("'new.target' outside a function", pos);
            try p.advance();
            return p.node(pos, .new_target);
        }
        var callee: *Node = undefined;
        if (p.atWord("new")) {
            callee = try p.parseNew();
        } else if (p.atWord("super") and !p.tok.escaped) {
            try p.advance();
            if (!p.allow_super_property or !(p.at(.dot) or p.at(.lbracket))) return p.fail("'super' here must be a property access", pos);
            callee = try p.node(pos, .super);
        } else if (p.atWord("import") and !p.tok.escaped) {
            return p.fail("'new import(...)' is not allowed", pos);
        } else {
            callee = try p.parsePrimary();
        }
        // Member accesses (no calls) bind to the callee.
        while (true) {
            if (p.at(.dot)) {
                try p.advance();
                callee = try p.parseMemberName(callee);
            } else if (p.at(.lbracket)) {
                try p.advance();
                const prop = try p.parseExpression(true);
                try p.expect(.rbracket, "expected ']'");
                callee = try p.node(callee.pos, .{ .member = .{ .object = callee, .property = prop, .computed = true, .optional = false } });
            } else if (p.at(.template) or p.at(.template_head)) {
                callee = try p.parseTaggedTemplate(callee);
            } else if (p.at(.question_dot)) {
                return p.fail("optional chain in a 'new' expression", p.tok.start);
            } else break;
        }
        var args: []*Node = &.{};
        if (p.at(.lparen)) args = try p.parseArguments();
        return p.node(pos, .{ .new = .{ .callee = callee, .args = args } });
    }

    fn parseMemberName(p: *Parser, object: *Node) Error!*Node {
        const kpos = p.tok.start;
        if (p.at(.private_name)) {
            if (object.data == .super) return p.fail("'super' has no private members", kpos);
            try p.notePrivateReference(p.tok.text, kpos);
            const prop = try p.node(kpos, .{ .private_name = p.tok.text });
            try p.advance();
            return p.node(object.pos, .{ .member = .{ .object = object, .property = prop, .computed = false, .optional = false } });
        }
        if (!p.at(.identifier)) return p.fail("expected a property name", kpos);
        const prop = try p.node(kpos, .{ .string = p.tok.text });
        try p.advance();
        return p.node(object.pos, .{ .member = .{ .object = object, .property = prop, .computed = false, .optional = false } });
    }

    fn notePrivateReference(p: *Parser, name: []const u8, pos: u32) Error!void {
        const ps = p.class_privates orelse return p.fail("private name outside a class", pos);
        // The name's text is the lexer's (a '#' put before it), in the
        // arena: a dropped body would take it, so the list keeps a copy.
        try ps.referenced.append(p.stable(), .{ .name = try p.stable().dupe(u8, name), .pos = pos });
    }

    /// Calls, members and optional chains after a callee.
    fn parseCallTail(p: *Parser, callee_in: *Node, pos: u32, in_chain_in: bool) Error!*Node {
        var e = callee_in;
        var in_chain = in_chain_in;
        while (true) {
            if (p.at(.dot)) {
                try p.advance();
                e = try p.parseMemberName(e);
            } else if (p.at(.question_dot)) {
                try p.advance();
                in_chain = true;
                if (p.at(.lparen)) {
                    const args = try p.parseArguments();
                    e = try p.node(pos, .{ .call = .{ .callee = e, .args = args, .optional = true } });
                } else if (p.at(.lbracket)) {
                    try p.advance();
                    const prop = try p.parseExpression(true);
                    try p.expect(.rbracket, "expected ']'");
                    e = try p.node(pos, .{ .member = .{ .object = e, .property = prop, .computed = true, .optional = true } });
                } else if (p.at(.template) or p.at(.template_head)) {
                    return p.fail("a tagged template cannot follow an optional chain", p.tok.start);
                } else {
                    e = try p.parseMemberName(e);
                    e.data.member.optional = true;
                }
            } else if (p.at(.lbracket)) {
                try p.advance();
                const prop = try p.parseExpression(true);
                try p.expect(.rbracket, "expected ']'");
                e = try p.node(pos, .{ .member = .{ .object = e, .property = prop, .computed = true, .optional = false } });
            } else if (p.at(.lparen)) {
                // `async (...)` that turns out to be an arrow head.
                const was_async = e.data == .identifier and std.mem.eql(u8, e.data.identifier, "async") and !e.parenthesized and !p.tok.newline_before and e.pos == pos;
                const cover_before = p.cover_init_at;
                const awaits_before = p.await_count;
                const yields_before = p.yield_count;
                const args = try p.parseArguments();
                if (was_async and p.at(.arrow) and !p.tok.newline_before) {
                    if (in_chain) return p.fail("an arrow in an optional chain", p.tok.start);
                    if (p.no_arrow) return p.fail("an arrow cannot be a class heritage", pos);
                    if (p.await_count != awaits_before) return p.fail("'await' in an async arrow's parameters", pos);
                    if (p.in_generator and p.yield_count != yields_before) return p.fail("'yield' in an arrow's parameters", pos);
                    try p.advance();
                    const params = try p.argsToParams(args);
                    p.cover_init_at = cover_before;
                    return p.parseArrowBody(pos, params, true);
                }
                e = try p.node(pos, .{ .call = .{ .callee = e, .args = args, .optional = false } });
            } else if (p.at(.template) or p.at(.template_head)) {
                if (in_chain) return p.fail("a tagged template cannot follow an optional chain", p.tok.start);
                e = try p.parseTaggedTemplate(e);
            } else break;
        }
        if (in_chain and !in_chain_in) return p.node(pos, .{ .optional_chain = e });
        return e;
    }

    fn parseArguments(p: *Parser) Error![]*Node {
        try p.expect(.lparen, "expected '('");
        var args: std.ArrayList(*Node) = .empty;
        while (!p.at(.rparen)) {
            const apos = p.tok.start;
            if (try p.eat(.ellipsis)) {
                try args.append(p.a, try p.node(apos, .{ .spread = try p.parseAssignment(true) }));
            } else try args.append(p.a, try p.parseAssignment(true));
            if (!p.at(.rparen)) try p.expect(.comma, "expected ',' between arguments");
        }
        try p.expect(.rparen, "expected ')'");
        return args.items;
    }

    /// Arguments of an `async(...)` call reinterpreted as arrow parameters.
    fn argsToParams(p: *Parser, args: []*Node) Error![]*Node {
        var params: std.ArrayList(*Node) = .empty;
        for (args, 0..) |arg, i| {
            if (arg.data == .spread) {
                if (i != args.len - 1) return p.fail("a rest parameter must be last", arg.pos);
                try params.append(p.a, try p.node(arg.pos, .{ .rest = try p.toBindingPattern(arg.data.spread) }));
            } else try params.append(p.a, try p.toBindingPattern(arg));
        }
        return params.items;
    }

    fn parseTaggedTemplate(p: *Parser, tag: *Node) Error!*Node {
        const quasi = try p.parseTemplate(true);
        return p.node(tag.pos, .{ .tagged_template = .{ .tag = tag, .quasi = quasi } });
    }

    /// A template literal from its first token; `tagged` permits
    /// invalid escapes (cooked undefined).
    fn parseTemplate(p: *Parser, tagged: bool) Error!*Node {
        const pos = p.tok.start;
        var cooked: std.ArrayList(?[]const u8) = .empty;
        var raws: std.ArrayList([]const u8) = .empty;
        var exprs: std.ArrayList(*Node) = .empty;
        var t = p.tok;
        while (true) {
            if (t.cooked_invalid and !tagged) return p.fail("invalid escape in a template", t.start);
            try cooked.append(p.a, if (t.cooked_invalid) null else t.text);
            try raws.append(p.a, t.raw);
            if (t.kind == .template or t.kind == .template_tail) {
                try p.advance();
                break;
            }
            try p.advance();
            try exprs.append(p.a, try p.parseExpression(true));
            if (!p.at(.rbrace)) return p.fail("expected '}' in template", p.tok.start);
            t = p.lex.rescanTemplateContinuation(p.tok) catch |e| return p.failLex(e);
            p.tok = t;
        }
        return p.node(pos, .{ .template = .{ .cooked = cooked.items, .raws = raws.items, .exprs = exprs.items } });
    }

    fn parsePrimary(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        const t = p.tok;
        switch (t.kind) {
            .number => {
                if (t.legacy_octal and p.strict) return p.fail("legacy octal literal in strict code", pos);
                try p.advance();
                return p.node(pos, .{ .number = t.number });
            },
            .bigint => {
                try p.advance();
                return p.node(pos, .{ .bigint = t.raw });
            },
            .string => {
                if (t.legacy_octal and p.strict) return p.fail("octal escape in strict code", pos);
                try p.advance();
                return p.node(pos, .{ .string = t.text });
            },
            .template, .template_head => return p.parseTemplate(false),
            .slash, .slash_assign => {
                const re = p.lex.rescanRegExp(t) catch |e| return p.failLex(e);
                // A literal's pattern is an early error when it does not
                // compile (§13.2.7.1).
                try p.checkRegExpLiteral(re.text, re.raw, pos);
                p.tok = re;
                try p.advance();
                return p.node(pos, .{ .regexp = .{ .pattern = re.text, .flags = re.raw } });
            },
            .lparen => return p.parseParenthesized(),
            .lbracket => return p.parseArrayLiteral(),
            .lbrace => return p.parseObjectLiteral(),
            .private_name => {
                // Only `#x in obj`, handled by parseBinary.
                return p.fail("unexpected private name", pos);
            },
            .identifier => {},
            else => return p.fail("unexpected token", pos),
        }
        const w = t.text;
        if (!t.escaped) {
            if (std.mem.eql(u8, w, "function")) return p.parseFunctionExpression();
            if (std.mem.eql(u8, w, "async")) {
                const next = try p.peek();
                if (next.isWord("function") and !next.newline_before) return p.parseFunctionExpression();
            }
            if (std.mem.eql(u8, w, "class")) return p.parseClassExpression();
            if (std.mem.eql(u8, w, "this")) {
                try p.advance();
                return p.node(pos, .this);
            }
            if (std.mem.eql(u8, w, "null")) {
                try p.advance();
                return p.node(pos, .null_lit);
            }
            if (std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false")) {
                try p.advance();
                return p.node(pos, .{ .bool_lit = w[0] == 't' });
            }
        } else {
            for (reserved) |r| if (std.mem.eql(u8, r, w)) return p.fail("keyword must not contain escapes", pos);
        }
        const name = (try p.identifierReference()) orelse return p.fail("unexpected keyword", pos);
        if (p.no_arguments and std.mem.eql(u8, name, "arguments")) return p.fail("'arguments' in a class field initializer or static block", pos);
        if (std.mem.eql(u8, name, "await")) p.await_count += 1;
        if (p.strict and !t.escaped) for (strict_reserved) |r| if (std.mem.eql(u8, r, name)) return p.fail("reserved word in strict code", pos);
        try p.advance();
        return p.node(pos, .{ .identifier = name });
    }

    /// `( ... )`: a parenthesized expression, or an arrow function's
    /// parameters (the cover grammar).
    fn parseParenthesized(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        const cover_before = p.cover_init_at;
        const yields_before = p.yield_count;
        const awaits_before = p.await_count;
        var items: std.ArrayList(*Node) = .empty;
        var must_be_arrow = false;
        var trailing_comma = false;
        var rest: ?*Node = null;
        // Arrow parameters that use `await`/`yield` are judged after we
        // know it is an arrow; the expression path keeps the current rules.
        if (p.at(.rparen)) {
            must_be_arrow = true;
        } else while (true) {
            if (p.at(.ellipsis)) {
                const rpos = p.tok.start;
                try p.advance();
                const target = try p.parseBindingElementTarget();
                rest = try p.node(rpos, .{ .rest = target });
                must_be_arrow = true;
                if (!p.at(.rparen)) return p.fail("a rest parameter must be last", p.tok.start);
                break;
            }
            try items.append(p.a, try p.parseAssignment(true));
            if (p.at(.rparen)) break;
            try p.expect(.comma, "expected ',' or ')'");
            if (p.at(.rparen)) {
                trailing_comma = true;
                must_be_arrow = true;
                break;
            }
        }
        try p.expect(.rparen, "expected ')'");
        if (p.at(.arrow) and !p.tok.newline_before) {
            if (p.in_generator and p.yield_count != yields_before) return p.fail("'yield' in an arrow's parameters", pos);
            if (p.await_expr and p.await_count != awaits_before) return p.fail("'await' in an arrow's parameters", pos);
            try p.advance();
            var params: std.ArrayList(*Node) = .empty;
            for (items.items) |it| try params.append(p.a, try p.toBindingPattern(it));
            if (rest) |r| try params.append(p.a, r);
            p.cover_init_at = cover_before;
            return p.parseArrowBody(pos, params.items, false);
        }
        if (must_be_arrow) return p.fail("expected '=>'", p.tok.start);
        var e: *Node = undefined;
        if (items.items.len == 1) e = items.items[0] else e = try p.node(pos, .{ .sequence = items.items });
        // Parentheses are remembered on a copy, so a shared literal node
        // is not marked twice.
        const wrapped = try p.a.create(Node);
        wrapped.* = e.*;
        wrapped.parenthesized = true;
        return wrapped;
    }

    fn parseArrayLiteral(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        var els: std.ArrayList(?*Node) = .empty;
        var comma_after_spread = false;
        while (!p.at(.rbracket)) {
            if (try p.eat(.comma)) {
                try els.append(p.a, null);
                continue;
            }
            const epos = p.tok.start;
            var spread = false;
            if (try p.eat(.ellipsis)) {
                spread = true;
                try els.append(p.a, try p.node(epos, .{ .spread = try p.parseAssignment(true) }));
            } else try els.append(p.a, try p.parseAssignment(true));
            if (!p.at(.rbracket)) {
                try p.expect(.comma, "expected ',' in array literal");
                if (spread and p.at(.rbracket)) comma_after_spread = true;
            }
        }
        try p.expect(.rbracket, "expected ']'");
        const arr = try p.node(pos, .{ .array = els.items });
        arr.comma_after_spread = comma_after_spread;
        return arr;
    }

    fn parseObjectLiteral(p: *Parser) Error!*Node {
        const pos = p.tok.start;
        try p.advance();
        var props: std.ArrayList(ast.Property) = .empty;
        var saw_proto = false;
        var comma_after_spread = false;
        while (!p.at(.rbrace)) {
            const ppos = p.tok.start;
            if (try p.eat(.ellipsis)) {
                const e = try p.parseAssignment(true);
                try props.append(p.a, .{ .kind = .spread, .key = e, .value = e });
                if (p.at(.comma)) comma_after_spread = true;
            } else {
                comma_after_spread = false;
                var is_async = false;
                var is_generator = false;
                var accessor: enum { none, get, set } = .none;
                if (p.atWord("async") and !p.tok.escaped) {
                    const next = try p.peek();
                    if (next.kind != .lparen and next.kind != .colon and next.kind != .comma and next.kind != .rbrace and next.kind != .assign and !next.newline_before) {
                        is_async = true;
                        try p.advance();
                    }
                }
                if (try p.eat(.star)) is_generator = true;
                if ((p.atWord("get") or p.atWord("set")) and !p.tok.escaped and !is_async and !is_generator) {
                    const next = try p.peek();
                    if (next.kind != .lparen and next.kind != .colon and next.kind != .comma and next.kind != .rbrace and next.kind != .assign) {
                        accessor = if (p.atWord("get")) .get else .set;
                        try p.advance();
                    }
                }
                const kpos = p.tok.start;
                var computed = false;
                var key: *Node = undefined;
                var shorthand: ?Token = null;
                if (try p.eat(.lbracket)) {
                    computed = true;
                    key = try p.parseAssignment(true);
                    try p.expect(.rbracket, "expected ']'");
                } else if (p.at(.string)) {
                    key = try p.node(kpos, .{ .string = p.tok.text });
                    try p.advance();
                } else if (p.at(.number)) {
                    if (p.tok.legacy_octal and p.strict) return p.fail("legacy octal literal in strict code", kpos);
                    key = try p.node(kpos, .{ .number = p.tok.number });
                    try p.advance();
                } else if (p.at(.bigint)) {
                    key = try p.node(kpos, .{ .bigint = p.tok.raw });
                    try p.advance();
                } else if (p.at(.identifier)) {
                    shorthand = p.tok;
                    key = try p.node(kpos, .{ .string = p.tok.text });
                    try p.advance();
                } else if (p.at(.private_name)) {
                    return p.fail("private names belong to classes", kpos);
                } else return p.fail("expected a property name", kpos);
                if (accessor != .none or is_async or is_generator or p.at(.lparen)) {
                    const kind: ast.Function.Kind = switch (accessor) {
                        .none => .method,
                        .get => .getter,
                        .set => .setter,
                    };
                    const f = try p.parseFunctionRest(ppos, null, is_async, is_generator, kind, false);
                    const fnode = try p.node(ppos, .{ .function = f });
                    try props.append(p.a, .{ .kind = switch (accessor) {
                        .none => .method,
                        .get => .get,
                        .set => .set,
                    }, .key = key, .computed = computed, .value = fnode });
                } else if (try p.eat(.colon)) {
                    const v = try p.parseAssignment(true);
                    if (!computed and key.data == .string and std.mem.eql(u8, key.data.string, "__proto__")) {
                        if (saw_proto) {
                            // Duplicate __proto__ is an error unless the object
                            // becomes a pattern; remember like a cover init.
                            if (p.cover_init_at == null) p.cover_init_at = kpos;
                        }
                        saw_proto = true;
                    }
                    try props.append(p.a, .{ .kind = .init, .key = key, .computed = computed, .value = v });
                } else {
                    const st = shorthand orelse return p.fail("expected ':'", p.tok.start);
                    const name = st.text;
                    if (st.escaped) {
                        for (reserved) |r| if (std.mem.eql(u8, r, name)) return p.fail("keyword must not contain escapes", kpos);
                    } else if (p.isReservedWord(name)) return p.fail("keyword cannot be a shorthand property", kpos);
                    if (p.strict) for (strict_reserved) |r| if (std.mem.eql(u8, r, name)) return p.fail("reserved word in strict code", kpos);
                    if (std.mem.eql(u8, name, "await") and (p.await_expr or p.module)) return p.fail("'await' here", kpos);
                    if (p.no_arguments and std.mem.eql(u8, name, "arguments")) return p.fail("'arguments' in a class field initializer", kpos);
                    const id = try p.node(kpos, .{ .identifier = name });
                    if (p.at(.assign)) {
                        // CoverInitializedName: only a pattern accepts it.
                        try p.advance();
                        const def = try p.parseAssignment(true);
                        if (p.cover_init_at == null) p.cover_init_at = kpos;
                        try props.append(p.a, .{ .kind = .shorthand, .key = key, .value = try p.node(kpos, .{ .assign_pattern = .{ .target = id, .default = def } }), .cover_init = true });
                    } else {
                        try props.append(p.a, .{ .kind = .shorthand, .key = key, .value = id });
                    }
                }
            }
            if (!p.at(.rbrace)) try p.expect(.comma, "expected ',' in object literal");
        }
        try p.expect(.rbrace, "expected '}'");
        const obj = try p.node(pos, .{ .object = props.items });
        obj.comma_after_spread = comma_after_spread;
        return obj;
    }

    // ------------------------------------------------- cover grammars

    /// An expression parsed as a literal, reinterpreted as an assignment
    /// target (`[a, b] = ...`, `({a} = ...)`, for-in/of heads).
    fn toAssignmentTarget(p: *Parser, n: *Node, top: bool) Error!*Node {
        switch (n.data) {
            .identifier => {
                try p.checkSimpleTarget(n);
                return n;
            },
            .member => return n,
            .array => |els| {
                if (n.parenthesized) return p.fail("invalid assignment target", n.pos);
                if (n.comma_after_spread) return p.fail("a rest element must be last", n.pos);
                var out: std.ArrayList(?*Node) = .empty;
                for (els, 0..) |el, i| {
                    if (el == null) {
                        try out.append(p.a, null);
                        continue;
                    }
                    const e = el.?;
                    if (e.data == .spread) {
                        if (i != els.len - 1) return p.fail("a rest element must be last", e.pos);
                        const target = try p.toAssignmentTarget(e.data.spread, false);
                        if (target.data == .assign_pattern) return p.fail("a rest element cannot have a default", e.pos);
                        try out.append(p.a, try p.node(e.pos, .{ .rest = target }));
                    } else try out.append(p.a, try p.toAssignmentElement(e));
                }
                return p.node(n.pos, .{ .array_pattern = out.items });
            },
            .object => |props| {
                if (n.parenthesized) return p.fail("invalid assignment target", n.pos);
                if (n.comma_after_spread) return p.fail("a rest property must be last", n.pos);
                var out: std.ArrayList(ast.PatternProperty) = .empty;
                for (props, 0..) |pr, i| {
                    switch (pr.kind) {
                        .spread => {
                            if (i != props.len - 1) return p.fail("a rest property must be last", pr.value.pos);
                            const target = try p.toAssignmentTarget(pr.value, false);
                            if (target.data != .identifier and target.data != .member) return p.fail("a rest property needs a simple target", pr.value.pos);
                            try out.append(p.a, .{ .key = pr.key, .value = try p.node(pr.value.pos, .{ .rest = target }), .is_rest = true });
                        },
                        .init => try out.append(p.a, .{ .key = pr.key, .computed = pr.computed, .value = try p.toAssignmentElement(pr.value) }),
                        .shorthand => {
                            if (pr.cover_init) {
                                const ap = pr.value.data.assign_pattern;
                                try p.checkSimpleTarget(ap.target);
                                try out.append(p.a, .{ .key = pr.key, .value = pr.value });
                            } else {
                                try p.checkSimpleTarget(pr.value);
                                try out.append(p.a, .{ .key = pr.key, .value = pr.value });
                            }
                        },
                        .get, .set, .method => return p.fail("invalid assignment target", pr.value.pos),
                    }
                }
                return p.node(n.pos, .{ .object_pattern = out.items });
            },
            .assign => |as| {
                // `[a = 1] = x`: an element with a default, only inside a pattern.
                if (top or as.op != .assign or n.parenthesized) return p.fail("invalid assignment target", n.pos);
                return p.node(n.pos, .{ .assign_pattern = .{ .target = try p.toAssignmentTarget(as.target, false), .default = as.value } });
            },
            .object_pattern, .array_pattern, .assign_pattern => return n,
            else => return p.fail("invalid assignment target", n.pos),
        }
    }

    fn toAssignmentElement(p: *Parser, e: *Node) Error!*Node {
        if (e.data == .assign and e.data.assign.op == .assign and !e.parenthesized) {
            return p.node(e.pos, .{ .assign_pattern = .{ .target = try p.toAssignmentTarget(e.data.assign.target, false), .default = e.data.assign.value } });
        }
        return p.toAssignmentTarget(e, false);
    }

    /// An expression parsed as a cover, reinterpreted as a binding
    /// pattern (arrow parameters): identifiers only, with defaults.
    fn toBindingPattern(p: *Parser, n: *Node) Error!*Node {
        if (n.parenthesized) return p.fail("invalid parameter", n.pos);
        switch (n.data) {
            .identifier => |name| {
                if (p.isReservedWord(name) and !std.mem.eql(u8, name, "yield") and !std.mem.eql(u8, name, "await")) return p.fail("keyword cannot be a parameter", n.pos);
                try p.checkBindingName(name, n.pos);
                return n;
            },
            .assign => |as| {
                if (as.op != .assign) return p.fail("invalid parameter", n.pos);
                return p.node(n.pos, .{ .assign_pattern = .{ .target = try p.toBindingPattern(as.target), .default = as.value } });
            },
            .array => |els| {
                if (n.comma_after_spread) return p.fail("a rest element must be last", n.pos);
                var out: std.ArrayList(?*Node) = .empty;
                for (els, 0..) |el, i| {
                    if (el == null) {
                        try out.append(p.a, null);
                        continue;
                    }
                    const e = el.?;
                    if (e.data == .spread) {
                        if (i != els.len - 1) return p.fail("a rest element must be last", e.pos);
                        const target = try p.toBindingPattern(e.data.spread);
                        if (target.data == .assign_pattern) return p.fail("a rest element cannot have a default", e.pos);
                        try out.append(p.a, try p.node(e.pos, .{ .rest = target }));
                    } else try out.append(p.a, try p.toBindingPattern(e));
                }
                return p.node(n.pos, .{ .array_pattern = out.items });
            },
            .object => |props| {
                if (n.comma_after_spread) return p.fail("a rest property must be last", n.pos);
                var out: std.ArrayList(ast.PatternProperty) = .empty;
                for (props, 0..) |pr, i| {
                    switch (pr.kind) {
                        .spread => {
                            if (i != props.len - 1) return p.fail("a rest property must be last", pr.value.pos);
                            const target = try p.toBindingPattern(pr.value);
                            if (target.data != .identifier) return p.fail("a rest property needs an identifier", pr.value.pos);
                            try out.append(p.a, .{ .key = pr.key, .value = try p.node(pr.value.pos, .{ .rest = target }), .is_rest = true });
                        },
                        .init => try out.append(p.a, .{ .key = pr.key, .computed = pr.computed, .value = try p.toBindingPattern(pr.value) }),
                        .shorthand => {
                            if (pr.cover_init) {
                                const ap = pr.value.data.assign_pattern;
                                _ = try p.toBindingPattern(ap.target);
                                try out.append(p.a, .{ .key = pr.key, .value = pr.value });
                            } else {
                                _ = try p.toBindingPattern(pr.value);
                                try out.append(p.a, .{ .key = pr.key, .value = pr.value });
                            }
                        },
                        .get, .set, .method => return p.fail("invalid parameter", pr.value.pos),
                    }
                }
                return p.node(n.pos, .{ .object_pattern = out.items });
            },
            .object_pattern, .array_pattern, .assign_pattern, .rest => return n,
            else => return p.fail("invalid parameter", n.pos),
        }
    }
};

/// A cooked string holding a lone surrogate (WTF-8: ED A0..BF xx).
fn hasLoneSurrogate(s: []const u8) bool {
    var i: usize = 0;
    while (i + 2 < s.len) : (i += 1) {
        if (s[i] == 0xed and s[i + 1] >= 0xa0) return true;
    }
    return false;
}

// ------------------------------------------------------------- tests

fn parseOk(a: std.mem.Allocator, src: []const u8) !void {
    var p = Parser.init(a, src, .{});
    _ = p.parseProgram() catch |e| {
        std.debug.print("  parse failed: {s} at {d} in `{s}`\n", .{ p.err, p.err_at, src });
        return e;
    };
}

fn parseErr(a: std.mem.Allocator, src: []const u8) !void {
    var p = Parser.init(a, src, .{});
    if (p.parseProgram()) |_| {
        std.debug.print("  parsed but should not: `{s}`\n", .{src});
        return error.TestUnexpectedResult;
    } else |_| {}
}

test "parser: statements, declarations and ASI" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try parseOk(a, "var a = 1, b; let [c, ...d] = e; const {f, g: h = 2} = i\nif (a) b; else { c }");
    try parseOk(a, "for (var i = 0; i < 10; i++) {} for (const k in o) ; for (let v of arr) {} for (;;) break");
    try parseOk(a, "outer: for (;;) { inner: while (true) { continue outer; break inner } }");
    try parseOk(a, "try { throw 1 } catch ({ message }) { } finally { }\ntry {} catch {}");
    try parseOk(a, "switch (x) { case 1: case 2: y(); break; default: z() }");
    try parseOk(a, "a\n++b");
    try parseOk(a, "x = y\n(z)");
    try parseOk(a, "let\nlet2 = 1");
    try parseErr(a, "a\n++");
    try parseErr(a, "for (let of x) ;");
    try parseErr(a, "break;");
    try parseErr(a, "continue foo;");
    try parseErr(a, "let a; let a;");
    try parseErr(a, "let a; var a;");
    try parseErr(a, "'use strict'; with (a) {}");
    try parseErr(a, "'use strict'; var eval = 1;");
    try parseErr(a, "'use strict'; 010");
    try parseErr(a, "function f() { 'use strict'; delete x }");
    try parseErr(a, "return 1");
}

test "parser: expressions, precedence and covers" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    try parseOk(a, "a ?? (b || c); (a ?? b) || c; a ** b ** c; (-a) ** b; a?.b?.[c]?.(d); new new A()(); new A.b.c(); a`x${b}y`");
    try parseOk(a, "[a, b] = [b, a]; ({a, b: {c}, ...d} = e); [x = 1, [y], ...z] = w");
    try parseOk(a, "const f = (a, b = 1, {c}, [d], ...e) => a; const g = async (x) => await x; const h = async x => x; (() => {})()");
    try parseOk(a, "o = { a, b: 1, [c]: 2, get d() {}, set d(v) {}, async *e() {}, 'f': 3, 4: 5, ...g, __proto__: null }");
    try parseOk(a, "class A extends B { #x = 1; static #y; constructor() { super(); super.m(); } get x() { return this.#x } static { this.z = 1 } static m() {} *gen() { yield 1; yield* x } async am() { await 1 } has(o) { return #x in o } }");
    try parseOk(a, "function* g() { yield; yield 1; const x = yield; } async function af() { for await (const x of y) {} }");
    try parseOk(a, "/re/g.test(s); a = b / c / d; x = /[/]/; if (a) /b/.test(c)");
    try parseOk(a, "label: function f() {}");
    try parseErr(a, "a ?? b || c");
    try parseErr(a, "-a ** b");
    try parseErr(a, "({a = 1})");
    try parseOk(a, "(a, b)"); // a comma expression, not a failed arrow
    try parseErr(a, "() ");
    try parseErr(a, "class A { constructor() {} constructor() {} }");
    try parseErr(a, "class A { #x; #x }");
    try parseErr(a, "class A { m() { this.#y } }");
    try parseErr(a, "function f() { super.x }");
    try parseErr(a, "new.target");
    try parseErr(a, "a?.b = 1");
    try parseErr(a, "async () => await;");
    try parseErr(a, "function f(a, a) { 'use strict' }");
    try parseErr(a, "(a, a) => 1");
    try parseErr(a, "`\\unicode`");
    try parseOk(a, "tag`\\unicode`");
}

test "parser: modules" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    var p = Parser.init(a, "import x, { y as z, 'w' as v } from 'm'; import * as ns from 'n'; export const q = await 1; export default function () {} export { q as r }; export * from 'o'; import.meta.url", .{ .module = true });
    _ = p.parseProgram() catch |e| {
        std.debug.print("  parse failed: {s} at {d}\n", .{ p.err, p.err_at });
        return e;
    };
    var p2 = Parser.init(a, "var await = 1", .{ .module = true });
    try std.testing.expectError(error.SyntaxError, p2.parseProgram());
}
