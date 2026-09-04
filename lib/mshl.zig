//! mshl — the msh language: a small structured shell language in the
//! spirit of the OS. Pipelines carry VALUES (records and tables), never
//! bytes to be re-parsed; text exists only when a value is rendered for a
//! human. Pure and freestanding-safe: the interpreter takes allocators
//! and a host callback for environment commands (files, domains, the
//! fabric), and every language feature is tested here on the host.
//!
//! Grammar (small and regular, by design):
//!   program  := stmt (';' | newline)*
//!   stmt     := 'let' name '=' expr | 'def' name ['[' params ']'] block
//!             | 'if' expr block ['else' (block|if)] | 'for' name 'in' expr block
//!             | 'while' expr block | pipeline
//!   pipeline := stage ('|' stage)* ['>' word]        ('>' = '| save word')
//!   stage    := name arg* ['?'] | '$'var arg+ ['?'] | expr
//!   arg      := word | string | '$'var | '(' pipeline ')' | '[' list ']'
//!             | record | block                        (a block argument is a
//!                                                      function of `$it`)
//!   expr     := or; or := and ('or' and)*; and := not ('and' not)*
//!   not      := 'not' not | cmp; cmp := add (op add)?; add/mul as usual
//!   primary  := number[unit] | string | '$'var | word | '(' pipeline ')'
//!             | '[' expr,* ']' | record | block | 'true' | 'false' | 'null'
//!             | 'fn' ['[' params ']'] block | 'match' expr '{' arm* '}'
//!             | 'try' (block | primary)
//!   postfix  := primary ('.' name | '.' index)* ['?']
//!   record   := '{' (word ':' expr (',' | newline)*)* '}'   (a '{' followed
//!               by `word:` is a record; otherwise it is a block)
//!   arm      := pattern ['if' expr] '=>' (block | stmt)
//!   pattern  := '_' | '$'name | literal | word | 'ok' pattern | 'err' pattern
//!             | '[' pattern,* ['..' ['$'name]] ']'
//!             | '{' (word ':' pattern | word),* '}'
//! Inside `where`, a bare word naming a column of the current row is that
//! column; elsewhere a bare word is a string. Strings interpolate "$var".
//!
//! TYPES are strong and dynamic: nothing, bool, int, string (UTF-8, `len`
//! in code points), bytes, list, record, table, function, result. Nothing
//! coerces: conditions take bools, `==` and `<` take matching types, and
//! a mismatch is a typed error, never a silent false.
//!
//! FAILURE is a value: `ok v` / `err e` results, unwrapped with `?` (which
//! returns the `err` from the enclosing function) or taken apart by an
//! exhaustive `match`; `try { … }` turns a failing command into an `err`.
//!
//! MEMORY: values are immutable. A line's temporaries live in an arena
//! the host resets; what a `let` or `def` binds at the prompt (or in a
//! module) escapes into a counted BOX, dropped when the name is rebound
//! or its scope dies — exact reference counts, no tracing. A function is
//! a closure: its tree and a snapshot of the enclosing function's locals
//! it uses, plus a reference to the scope it was defined in, which it
//! reads by name when it runs (so functions call each other by name).
//! `use path` evaluates a file in a scope of its own and hands back its
//! bindings as a record: a module.
//!
//! DATA FILES (unit files, config) are the literal subset of the same
//! syntax — numbers with units, strings, bare words, true/false/null,
//! lists, records, comments — parsed by `parseData`, which accepts
//! literals and nothing else: no commands, no variables, no evaluation.
//! A `.msh` file is a program or a record depending only on which entry
//! point reads it.

const std = @import("std");
const json = @import("json.zig");

pub const Value = union(enum) {
    nothing,
    bool: bool,
    int: i64,
    float: f64,
    str: []const u8,
    bytes: []const u8,
    list: []const Value,
    record: Record,
    table: Table,
    func: *const Closure,
    result: *const Result,
    /// A capability the host holds on the program's behalf (a socket,
    /// a listener): counted like a function, released — the host's
    /// `drop` runs — when the last value naming it is gone.
    handle: *const Handle,
    /// A shape (`shape { name: string }`): what a value must look like,
    /// as a value — bound to a name, passed to `check`, kept in a
    /// signature.
    shape: *const Shape,

    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nothing => "nothing",
            .bool => "bool",
            .int => "int",
            .float => "float",
            .str => "string",
            .bytes => "bytes",
            .list => "list",
            .record => "record",
            .table => "table",
            .func => "function",
            .result => "result",
            .handle => |h| h.kind,
            .shape => "shape",
        };
    }

    /// For hosts reading flags out of data files: `true`, and nothing
    /// else, is true (no coercion here either).
    pub fn asBool(v: Value) bool {
        return v == .bool and v.bool;
    }

    /// Scalars live inline in a binding; everything else needs a box.
    fn isScalar(v: Value) bool {
        return switch (v) {
            .nothing, .bool, .int, .float => true,
            else => false,
        };
    }

    /// The literal subset: what a data file can hold.
    pub fn isData(v: Value) bool {
        return switch (v) {
            .nothing, .bool, .int, .str => true,
            .float => |f| std.math.isFinite(f),
            .bytes, .func, .result, .handle, .shape => false,
            .list => |l| for (l) |x| {
                if (!x.isData()) break false;
            } else true,
            .record => |r| for (r.vals) |x| {
                if (!x.isData()) break false;
            } else true,
            .table => |t| for (t.rows) |row| {
                for (row) |x| if (!x.isData()) break;
            } else true,
        };
    }
};

pub const Record = struct {
    keys: []const []const u8,
    vals: []const Value,

    pub fn get(r: Record, key: []const u8) ?Value {
        for (r.keys, r.vals) |k, v| {
            if (std.mem.eql(u8, k, key)) return v;
        }
        return null;
    }
};

/// Uniform rows: every row has one Value per column.
pub const Table = struct {
    cols: []const []const u8,
    rows: []const []const Value,

    pub fn col(t: Table, name: []const u8) ?usize {
        for (t.cols, 0..) |c, i| {
            if (std.mem.eql(u8, c, name)) return i;
        }
        return null;
    }

    pub fn row(t: Table, i: usize) Record {
        return .{ .keys = t.cols, .vals = t.rows[i] };
    }
};

/// `ok v` or `err e`.
pub const Result = struct { ok: bool, val: Value };

/// A shape: what a value must look like. Structural and optional —
/// `{ name: string, size: int }` admits any record with those fields,
/// `dir | file` any of those words (an enumeration), `[int]` a list
/// (or table) of ints, `ok int | err string` a result. Written after a
/// `let name:`, a parameter, a `->`, a `match subject:`, or the word
/// `shape`; checked where it runs, never before (there is no static
/// checker), and at a boundary by `check` and by a host's signature.
pub const Shape = union(enum) {
    any,
    nothing,
    bool,
    int,
    float,
    string,
    bytes,
    list,
    record,
    table,
    function,
    result,
    shape,
    handle,
    /// A handle of one kind: `handle socket`.
    kind: []const u8,
    /// Exactly this string, written as a bare word (or quoted): one
    /// member of an enumeration.
    word: []const u8,
    /// `[S]`: a list, or a table, whose every item is an S.
    list_of: *const Shape,
    /// `{ k: S, … }`: a record with at least these fields.
    record_of: []const Field,
    /// `ok S`, `err S`: a result of that side.
    ok: *const Shape,
    err: *const Shape,
    /// `S | S`: any of them.
    one_of: []const Shape,
    /// `$name`: a shape bound in scope, looked up where the annotation
    /// runs (a shape *value* never holds one: `shape` resolves them).
    ref: []const u8,

    pub const Field = struct { key: []const u8, shape: Shape };

    /// Render as it is written.
    pub fn write(s: Shape, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        switch (s) {
            .any, .nothing, .bool, .int, .float, .string, .bytes, .list, .record, .table, .function, .result, .shape, .handle => try out.appendSlice(a, @tagName(s)),
            .kind => |k| {
                try out.appendSlice(a, "handle ");
                try out.appendSlice(a, k);
            },
            .word => |w| {
                // A word spelt like a type name is quoted, or it would
                // read back as the type.
                if (Parser.isShapeKeyword(w)) {
                    try out.append(a, '"');
                    try out.appendSlice(a, w);
                    try out.append(a, '"');
                } else if (std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "null")) {
                    try out.appendSlice(a, w); // words in a shape, and read back as such
                } else try writeStr(w, a, out);
            },
            .list_of => |inner| {
                try out.append(a, '[');
                try inner.write(a, out);
                try out.append(a, ']');
            },
            .record_of => |fields| {
                if (fields.len == 0) return out.appendSlice(a, "{}");
                try out.appendSlice(a, "{ ");
                for (fields, 0..) |f, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try out.appendSlice(a, f.key);
                    try out.appendSlice(a, ": ");
                    try f.shape.write(a, out);
                }
                try out.appendSlice(a, " }");
            },
            .ok, .err => |inner| {
                try out.appendSlice(a, if (s == .ok) "ok " else "err ");
                if (inner.* == .one_of) try out.append(a, '(');
                try inner.write(a, out);
                if (inner.* == .one_of) try out.append(a, ')');
            },
            .one_of => |alts| for (alts, 0..) |alt, i| {
                if (i > 0) try out.appendSlice(a, " | ");
                try alt.write(a, out);
            },
            .ref => |name| {
                try out.append(a, '$');
                try out.appendSlice(a, name);
            },
        }
    }

    pub fn text(s: Shape, a: std.mem.Allocator) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try s.write(a, &buf);
        return buf.items;
    }
};

/// One argument of a host command, in its signature.
pub const Param = struct { name: []const u8, shape: Shape = .any, optional: bool = false };

/// What a command takes from the pipeline.
pub const Input = union(enum) { none, optional: Shape, required: Shape };

/// A host command's signature: its arguments, its input, its answer.
/// The interpreter checks the arguments and the input before the call
/// and the answer after it, so a pipeline's mistake is a typed error at
/// the boundary — never a value that is silently wrong — and a host's
/// slip is reported as its own. Hosts derive shapes from the protocol
/// types they answer with (`shapeOf`), so the two cannot drift.
pub const Signature = struct {
    params: []const Param = &.{},
    /// Arguments past `params` are allowed, each of this shape.
    rest: ?Shape = null,
    input: Input = .none,
    ret: Shape = .any,
};

/// `ok OK | err ERR`: the shape of a command whose outcome the world
/// decides.
pub fn resultShape(comptime ok_shape: Shape, comptime err_shape: Shape) Shape {
    comptime {
        const o = ok_shape;
        const e = err_shape;
        const alts = [_]Shape{ .{ .ok = &o }, .{ .err = &e } };
        return .{ .one_of = &alts };
    }
}

/// The shape of a Zig type: a struct is a record of its fields, an
/// enum a choice of its tags as words, a slice a list (`[]const u8` a
/// string), an optional the shape or nothing. With `toValue` on the
/// same type, a host's answer and its declared shape come from one
/// definition — the protocol's.
pub fn shapeOf(comptime T: type) Shape {
    comptime {
        if (T == Value) return .any;
        switch (@typeInfo(T)) {
            .bool => return .bool,
            .int, .comptime_int => return .int,
            .float, .comptime_float => return .float,
            .void => return .nothing,
            .optional => |o| {
                const alts = [_]Shape{ shapeOf(o.child), .nothing };
                return .{ .one_of = &alts };
            },
            .@"enum" => |e| {
                var alts: [e.fields.len]Shape = undefined;
                for (e.fields, 0..) |f, i| alts[i] = .{ .word = f.name };
                const done = alts;
                return .{ .one_of = &done };
            },
            .@"struct" => |s| {
                var fields: [s.fields.len]Shape.Field = undefined;
                for (s.fields, 0..) |f, i| fields[i] = .{ .key = f.name, .shape = shapeOf(f.type) };
                const done = fields;
                return .{ .record_of = &done };
            },
            .pointer => |p| {
                if (p.size == .one) return shapeOf(p.child);
                if (p.size != .slice) @compileError("no shape for " ++ @typeName(T));
                if (p.child == u8) return .string;
                const inner = shapeOf(p.child);
                return .{ .list_of = &inner };
            },
            .array => |arr| {
                if (arr.child == u8) return .string;
                const inner = shapeOf(arr.child);
                return .{ .list_of = &inner };
            },
            else => @compileError("no shape for " ++ @typeName(T)),
        }
    }
}

/// A Zig value as an mshl value, by the same rules as `shapeOf`: a
/// struct is a record (its field names the keys), an enum its tag as a
/// word, a slice a list, an optional nothing or the value. Text is
/// copied (a host's buffer is reused by its next call).
pub fn toValue(a: std.mem.Allocator, x: anytype) Error!Value {
    const T = @TypeOf(x);
    if (T == Value) return x;
    switch (@typeInfo(T)) {
        .bool => return .{ .bool = x },
        .int, .comptime_int => return .{ .int = @intCast(x) },
        .float, .comptime_float => return .{ .float = @floatCast(x) },
        .void, .null => return .nothing,
        .optional => return if (x) |v| try toValue(a, v) else .nothing,
        .@"enum" => return .{ .str = @tagName(x) },
        .@"struct" => |s| {
            const keys = try a.alloc([]const u8, s.fields.len);
            const vals = try a.alloc(Value, s.fields.len);
            inline for (s.fields, 0..) |f, i| {
                keys[i] = f.name;
                vals[i] = try toValue(a, @field(x, f.name));
            }
            return .{ .record = .{ .keys = keys, .vals = vals } };
        },
        .pointer => |p| {
            if (p.size == .one) return toValue(a, x.*);
            if (p.size != .slice) @compileError("no value for " ++ @typeName(T));
            if (p.child == u8) return .{ .str = try a.dupe(u8, x) };
            const items = try a.alloc(Value, x.len);
            for (x, 0..) |item, i| items[i] = try toValue(a, item);
            return tableize(a, .{ .list = items });
        },
        .array => return toValue(a, x[0..]),
        else => @compileError("no value for " ++ @typeName(T)),
    }
}

/// A function value. Lives in its own box (its tree, parameter names,
/// captured locals); `scope` is what it sees by name when it runs.
pub const Closure = struct {
    box: *Box,
    name: []const u8,
    params: []const []const u8,
    /// A shape per parameter (null: any), and for what it returns.
    param_shapes: []const ?Shape,
    ret: ?Shape,
    body: *Node,
    /// The body's source text, for hosts that ship a function elsewhere
    /// (a remote stage runs it with only `$in`; no captures cross).
    src: []const u8,
    captures: []const Capture,
    scope: *Scope,
    /// A block written as an argument: binds `$it` (and `$acc`) by name.
    implicit: bool,
};

const Capture = struct { name: []const u8, value: Value };

/// A host-held capability as a value. `kind` names it for the human
/// and for `type`; `id` is the host's number for it; `drop` is called
/// once, when its box is freed, unless the host closed it first.
pub const Handle = struct {
    box: *Box,
    kind: []const u8,
    id: u64,
    ctx: *anyopaque,
    drop: *const fn (ctx: *anyopaque, kind: []const u8, id: u64) void,
    closed: bool = false,
};

/// Counted storage for one escaping value: an arena that holds it (and,
/// for a function, the closure) and a count of the bindings and values
/// that reference it. Dropped to zero, it waits on the interpreter's
/// dead list until the top-level statement ends — nothing evaluated in
/// that statement can still be looking at it then.
pub const Box = struct {
    rc: usize,
    arena: std.heap.ArenaAllocator,
    value: Value,
    next_dead: ?*Box = null,
    dead: bool = false,
};

/// Names bound at a top level: the session's, or a module's. Every
/// closure defined in it points back at it (that is how functions call
/// each other by name), and the scope's slots hold those closures: the
/// one cycle in the value graph, and it is collected knowingly — a
/// scope nobody holds (`held`) whose closures are referenced only from
/// its own slots is garbage, checked at every reclaim (see
/// `scopeGarbage`).
pub const Scope = struct {
    /// Closures whose scope this is.
    rc: usize,
    /// The interpreter (the session) or a running `use` holds it.
    held: bool,
    heap: std.mem.Allocator,
    names: std.ArrayList([]const u8) = .empty,
    slots: std.ArrayList(Slot) = .empty,
    next: ?*Scope = null,

    const Slot = struct { value: Value, box: ?*Box };

    fn find(s: *Scope, name: []const u8) ?*Slot {
        for (s.names.items, 0..) |n, i| {
            if (std.mem.eql(u8, n, name)) return &s.slots.items[i];
        }
        return null;
    }
};

/// A function call's locals: captures, parameters, `$in`, and every
/// `let` in the body. Arena memory; gone with the line.
const Frame = struct {
    names: std.ArrayList([]const u8) = .empty,
    vals: std.ArrayList(Value) = .empty,
    input: ?Value,

    fn get(f: *Frame, name: []const u8) ?Value {
        var i = f.names.items.len;
        while (i > 0) : (i -= 1) {
            if (std.mem.eql(u8, f.names.items[i - 1], name)) return f.vals.items[i - 1];
        }
        return null;
    }

    fn set(f: *Frame, a: std.mem.Allocator, name: []const u8, v: Value) Error!void {
        var i = f.names.items.len;
        while (i > 0) : (i -= 1) {
            if (std.mem.eql(u8, f.names.items[i - 1], name)) {
                f.vals.items[i - 1] = v;
                return;
            }
        }
        try f.names.append(a, name);
        try f.vals.append(a, v);
    }
};

pub const Error = error{ OutOfMemory, Syntax, Runtime, Exit };

/// The environment: commands the language does not define itself.
/// Return null for an unknown name (the interpreter reports it).
/// `signature`, when a host has one for a name, is checked around the
/// call: arguments and input before, the answer after. `use name` asks
/// for `module name` first (a bare name is looked up in a store, a path
/// in the view) and falls back to `open`.
pub const Host = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, it: *Interp, name: []const u8, args: []const Value, input: ?Value) Error!?Value,
    signature: ?*const fn (ctx: *anyopaque, name: []const u8) ?Signature = null,
};

/// Commands and keywords defined by the language itself.
pub const builtin_names = [_][]const u8{
    "echo",      "len",     "first",     "last",     "reverse",    "where",   "sort-by",   "select",
    "get",       "lines",   "keys",      "let",      "def",        "fn",      "if",        "for",
    "while",     "match",   "try",       "use",      "not",        "and",     "or",        "true",
    "false",     "null",    "else",      "in",       "ok",         "err",     "map",       "filter",
    "reduce",    "any",     "all",       "find",     "range",      "join",    "split",     "str",
    "int",       "float",   "round",     "floor",    "ceil",       "type",    "shape",     "check",
    "signature", "to-data", "from-data", "to-bytes", "from-bytes", "to-json", "from-json",
};

/// Bindings per scope.
pub const max_vars = 128;
const max_use_depth = 8;

pub const Interp = struct {
    /// Per-evaluation temporaries (reset by the host between lines).
    arena: std.mem.Allocator,
    /// Boxes and scopes: must support free (a pool, a GPA, the testing
    /// allocator). An arena works too; it just never gives memory back.
    heap: std.mem.Allocator,
    host: Host,
    /// The session's scope, created on first use.
    session: ?*Scope = null,
    /// Every live scope (the session's and modules'), for the collector.
    scopes: ?*Scope = null,
    /// The scope names resolve in right now (the session's, a module's
    /// while `use` evaluates it, a closure's while it runs).
    scope: ?*Scope = null,
    /// The running function's locals, or null at a top level.
    frame: ?*Frame = null,
    /// Frames of calls that returned, kept for the next call: calls nest
    /// last-in first-out, so a line's frames cost its deepest nesting,
    /// not its number of calls (a `map` over ten thousand items reused
    /// one frame, once this existed).
    free_frames: std.ArrayList(*Frame) = .empty,
    /// Frames ever created in this line (a statistic for the tests).
    frames_made: usize = 0,
    /// Rendered output of the last evaluation.
    out: std.ArrayList(u8) = .empty,
    /// The message behind the last Syntax/Runtime error.
    err_msg: []const u8 = "",
    /// Set by `where`: the row bare words resolve against.
    row: ?Record = null,
    /// Boxes at zero, freed when the top-level statement ends.
    dead: ?*Box = null,
    /// `?` on an err: the result unwinding to the enclosing function.
    propagating: bool = false,
    ret: Value = .nothing,
    use_depth: usize = 0,

    pub fn init(arena: std.mem.Allocator, heap: std.mem.Allocator, host: Host) Interp {
        return .{ .arena = arena, .heap = heap, .host = host };
    }

    /// Release everything the session holds. Nothing is leaked if every
    /// box came back: the host tests check that with the testing allocator.
    pub fn deinit(self: *Interp) void {
        if (self.session) |s| {
            self.session = null;
            self.scope = null;
            s.held = false;
        }
        self.reclaim();
    }

    /// Parse and evaluate one program; the value of its last statement is
    /// returned AND rendered into `out` (which the caller shows and
    /// clears). Errors carry a message in err_msg. The value is good
    /// until the next call.
    pub fn run(self: *Interp, src: []const u8) Error!Value {
        self.out = .empty;
        self.free_frames = .empty; // the host reset the arena: the pool went with it
        self.reclaim();
        var p = Parser{ .it = self, .lex = Lexer{ .src = src } };
        const prog = try p.program();
        var v: Value = .nothing;
        for (prog, 0..) |stmt, i| {
            if (i > 0) self.reclaim();
            v = self.evalTop(stmt) catch |e| {
                self.reclaim();
                return e;
            };
        }
        try render(v, self.arena, &self.out);
        return v;
    }

    /// Evaluate a program without touching `out` (scripts sourced from
    /// inside a command); the caller renders the value if it wants to.
    pub fn evalSource(self: *Interp, src: []const u8) Error!Value {
        var p = Parser{ .it = self, .lex = Lexer{ .src = src } };
        const prog = try p.program();
        return self.evalBlock(prog);
    }

    /// Run a script the way the prompt runs lines: every top-level
    /// statement's value is rendered into `out` as it is produced. The
    /// last statement's value is the script's (good until the next call).
    pub fn evalScript(self: *Interp, src: []const u8, out: *std.ArrayList(u8)) Error!Value {
        return self.evalScriptEach(src, out, null);
    }

    /// evalScript, telling `sink` after every statement what was just
    /// rendered (a host that shows output as it happens — a script
    /// that serves forever still says it started).
    pub fn evalScriptEach(self: *Interp, src: []const u8, out: *std.ArrayList(u8), sink: ?*const fn (text: []const u8) void) Error!Value {
        if (self.frame == null) self.free_frames = .empty;
        var p = Parser{ .it = self, .lex = Lexer{ .src = src } };
        const prog = try p.program();
        var last: Value = .nothing;
        for (prog, 0..) |stmt, i| {
            if (i > 0) self.reclaim();
            last = self.evalTop(stmt) catch |e| {
                self.reclaim();
                return e;
            };
            const before = out.items.len;
            try render(last, self.arena, out);
            if (sink) |f| f(out.items[before..]);
        }
        return last;
    }

    /// A top-level statement: an unhandled `?` is an error here.
    fn evalTop(self: *Interp, stmt: *Node) Error!Value {
        return self.evalStmt(stmt) catch |e| {
            if (e == Error.Runtime and self.propagating) {
                self.propagating = false;
                var buf: std.ArrayList(u8) = .empty;
                try renderInline(self.ret, self.arena, &buf);
                return self.fail("unhandled {s}", .{buf.items});
            }
            return e;
        };
    }

    /// Parse `src` as DATA: one literal value (usually a record), nothing
    /// executable. The result lives in the arena.
    pub fn parseData(self: *Interp, src: []const u8) Error!Value {
        var p = Parser{ .it = self, .lex = Lexer{ .src = src } };
        p.setExpr(true);
        // Leading separators.
        while (p.peekAt() == .newline or p.peekAt() == .semi) _ = p.take();
        const node = try p.expr();
        while (p.peekAt() == .newline or p.peekAt() == .semi) _ = p.take();
        if (p.peekAt() != .eof) return p.syntax("data: one value expected", .{});
        return self.literal(node);
    }

    /// Reduce a literal-only tree to a value; anything else is refused.
    fn literal(self: *Interp, n: *Node) Error!Value {
        switch (n.*) {
            .lit => |v| return v,
            .word => |w| return .{ .str = w },
            .list => |items| {
                const vals = try self.arena.alloc(Value, items.len);
                for (items, 0..) |item, i| vals[i] = try self.literal(item);
                return .{ .list = vals };
            },
            .record => |fields| {
                const keys = try self.arena.alloc([]const u8, fields.len);
                const vals = try self.arena.alloc(Value, fields.len);
                for (fields, 0..) |f, i| {
                    keys[i] = f.key;
                    vals[i] = try self.literal(f.value);
                }
                return .{ .record = .{ .keys = keys, .vals = vals } };
            },
            .unop => |u| {
                if (u.op == .neg) {
                    const v = try self.literal(u.operand);
                    if (v == .int) return .{ .int = -v.int };
                }
                return self.fail("data: literal expected", .{});
            },
            else => return self.fail("data: literal expected (no commands, variables, or operators)", .{}),
        }
    }

    pub fn fail(self: *Interp, comptime fmt: []const u8, args: anytype) Error {
        self.err_msg = std.fmt.allocPrint(self.arena, fmt, args) catch "error";
        return Error.Runtime;
    }

    // ------------------------------------------------------- memory model

    fn cur(self: *Interp) Error!*Scope {
        if (self.scope) |s| return s;
        const s = try self.newScope();
        self.session = s;
        self.scope = s;
        return s;
    }

    fn newScope(self: *Interp) Error!*Scope {
        const s = try self.heap.create(Scope);
        s.* = .{ .rc = 0, .held = true, .heap = self.heap, .next = self.scopes };
        self.scopes = s;
        return s;
    }

    /// A closure of this scope died.
    fn dropScope(self: *Interp, s: *Scope) void {
        _ = self;
        s.rc -= 1;
    }

    /// Is an unheld scope unreachable from outside itself? True when
    /// every closure that points at it is referenced exactly as many
    /// times as its own slots reference it — nothing else can name it.
    fn scopeGarbage(self: *Interp, s: *Scope) bool {
        const Seen = struct { box: *Box, k: usize };
        var seen: std.ArrayList(Seen) = .empty;
        defer seen.deinit(self.heap);
        for (s.slots.items) |slot| {
            countClosures(s, slot.value, &seen, self.heap) catch return false;
        }
        if (seen.items.len != s.rc) return false;
        for (seen.items) |e| {
            if (e.box.rc != e.k) return false;
        }
        return true;
    }

    fn countClosures(s: *Scope, v: Value, seen: anytype, heap: std.mem.Allocator) Error!void {
        switch (v) {
            .func => |cl| {
                if (cl.scope != s) return;
                for (seen.items) |*e| {
                    if (e.box == cl.box) {
                        e.k += 1;
                        return;
                    }
                }
                try seen.append(heap, .{ .box = cl.box, .k = 1 });
            },
            .list => |l| for (l) |x| try countClosures(s, x, seen, heap),
            .record => |r| for (r.vals) |x| try countClosures(s, x, seen, heap),
            .table => |t| for (t.rows) |row| {
                for (row) |x| try countClosures(s, x, seen, heap);
            },
            .result => |r| try countClosures(s, r.val, seen, heap),
            else => {},
        }
    }

    /// Tear a garbage scope down: its slots drop their boxes, the
    /// closures among them die (each taking one reference off the
    /// scope), and the scope itself goes once the count is zero.
    fn freeScope(self: *Interp, s: *Scope) void {
        var link = &self.scopes;
        while (link.*) |sc| : (link = &sc.next) {
            if (sc == s) {
                link.* = sc.next;
                break;
            }
        }
        for (s.slots.items) |slot| {
            if (slot.box) |b| self.dropBox(b);
        }
        for (s.names.items) |n| self.heap.free(n);
        s.names.deinit(self.heap);
        s.slots.deinit(self.heap);
        self.drainDead();
        std.debug.assert(s.rc == 0);
        self.heap.destroy(s);
    }

    /// Put a value in a box of its own: a deep copy, functions inside
    /// retained. A function's value IS its box: retained, not copied.
    fn boxValue(self: *Interp, v: Value) Error!*Box {
        if (v == .func) {
            v.func.box.rc += 1;
            return v.func.box;
        }
        if (v == .handle) {
            v.handle.box.rc += 1;
            return v.handle.box;
        }
        const b = try self.heap.create(Box);
        b.* = .{ .rc = 1, .arena = std.heap.ArenaAllocator.init(self.heap), .value = .nothing };
        b.value = try self.dupRetained(b.arena.allocator(), v);
        return b;
    }

    /// Deep copy for escaping values: like dupValue, plus a reference on
    /// every function inside.
    fn dupRetained(self: *Interp, a: std.mem.Allocator, v: Value) Error!Value {
        _ = self;
        retainValue(v);
        return dupValue(a, v);
    }

    fn dropBox(self: *Interp, b: *Box) void {
        b.rc -= 1;
        if (b.rc > 0 or b.dead) return;
        b.dead = true;
        b.next_dead = self.dead;
        self.dead = b;
    }

    /// Free the boxes that reached zero during the statement that just
    /// ended. A box retained again meanwhile (a module's bindings, read
    /// into a record after their scope died) is simply kept.
    pub fn reclaim(self: *Interp) void {
        while (true) {
            self.drainDead();
            var freed = false;
            var it = self.scopes;
            while (it) |s| {
                const next = s.next;
                if (!s.held and self.scopeGarbage(s)) {
                    self.freeScope(s);
                    freed = true;
                }
                it = next;
            }
            if (!freed) break;
        }
    }

    fn drainDead(self: *Interp) void {
        while (self.dead) |b| {
            self.dead = b.next_dead;
            b.dead = false;
            b.next_dead = null;
            if (b.rc > 0) continue;
            if (b.value == .func) {
                const cl = b.value.func;
                for (cl.captures) |c| self.releaseValue(c.value);
                self.dropScope(cl.scope);
            } else if (b.value == .handle) {
                const h = b.value.handle;
                if (!h.closed) h.drop(h.ctx, h.kind, h.id);
            } else self.releaseValue(b.value);
            b.arena.deinit();
            self.heap.destroy(b);
        }
    }

    /// Drop the references a value holds (the functions inside it).
    fn releaseValue(self: *Interp, v: Value) void {
        switch (v) {
            .func => |cl| self.dropBox(cl.box),
            .handle => |h| self.dropBox(h.box),
            .list => |l| for (l) |x| self.releaseValue(x),
            .record => |r| for (r.vals) |x| self.releaseValue(x),
            .table => |t| for (t.rows) |row| {
                for (row) |x| self.releaseValue(x);
            },
            .result => |r| self.releaseValue(r.val),
            else => {},
        }
    }

    // ---------------------------------------------------------- variables

    pub fn lookup(self: *Interp, name: []const u8) ?Value {
        if (self.frame) |f| {
            if (f.get(name)) |v| return v;
        }
        if (self.scope) |s| {
            if (s.find(name)) |slot| return slot.value;
        }
        return null;
    }

    /// Bind in the running function's frame, or at the top level.
    fn bind(self: *Interp, name: []const u8, v: Value) Error!void {
        if (self.frame) |f| return f.set(self.arena, name, v);
        const box: ?*Box = if (v.isScalar()) null else try self.boxValue(v);
        try self.bindSlot(name, if (box) |b| b.value else v, box);
    }

    /// Bind in the session (the host's way to preset a variable).
    pub fn setVar(self: *Interp, name: []const u8, v: Value) Error!void {
        const saved = self.frame;
        self.frame = null;
        defer self.frame = saved;
        try self.bind(name, v);
    }

    /// Install a slot value (already boxed, or a scalar) under a name in
    /// the current scope, dropping what the name held before.
    fn bindSlot(self: *Interp, name: []const u8, v: Value, box: ?*Box) Error!void {
        const s = try self.cur();
        if (s.find(name)) |slot| {
            const old = slot.box;
            slot.* = .{ .value = v, .box = box };
            if (old) |b| self.dropBox(b);
            return;
        }
        if (s.names.items.len == max_vars) return self.fail("too many variables", .{});
        const n = try self.heap.dupe(u8, name);
        errdefer self.heap.free(n);
        try s.names.append(self.heap, n);
        s.slots.append(self.heap, .{ .value = v, .box = box }) catch |e| {
            _ = s.names.pop();
            return e;
        };
    }

    // --------------------------------------------------------- evaluation

    fn evalBlock(self: *Interp, stmts: []const *Node) Error!Value {
        var last: Value = .nothing;
        for (stmts) |s| last = try self.evalStmt(s);
        return last;
    }

    fn condition(self: *Interp, v: Value, what: []const u8) Error!bool {
        return switch (v) {
            .bool => |b| b,
            else => self.fail("{s}: condition is a {s}, not a bool", .{ what, v.typeName() }),
        };
    }

    fn evalStmt(self: *Interp, n: *Node) Error!Value {
        switch (n.*) {
            .let => |l| {
                // `let x = $y` at a top level shares y's box.
                if (self.frame == null and l.expr.* == .var_ and l.shape == null) {
                    if (self.scope) |s| if (s.find(l.expr.var_)) |src| if (src.box) |b| {
                        b.rc += 1;
                        try self.bindSlot(l.name, src.value, b);
                        return .nothing;
                    };
                }
                const v = try self.evalNode(l.expr);
                if (l.shape) |s| {
                    if (try self.mismatch(v, s, l.name)) |why| return self.fail("let: {s}", .{why});
                }
                try self.bind(l.name, v);
                return .nothing;
            },
            .def => |d| {
                try self.bind(d.name, try self.makeClosure(d.name, d.params, d.param_shapes, d.ret, d.body, false, d.src));
                return .nothing;
            },
            .if_ => |c| {
                if (try self.condition(try self.evalNode(c.cond), "if")) return self.evalNode(c.then);
                if (c.else_) |e| return self.evalNode(e);
                return .nothing;
            },
            .for_ => |f| {
                const iter = try self.evalNode(f.iter);
                const items: []const Value = switch (iter) {
                    .list => |l| l,
                    .table => |t| blk: {
                        const rs = try self.arena.alloc(Value, t.rows.len);
                        for (rs, 0..) |*r, i| r.* = .{ .record = t.row(i) };
                        break :blk rs;
                    },
                    .str => |s| blk: {
                        var lines: std.ArrayList(Value) = .empty;
                        var itl = std.mem.splitScalar(u8, s, '\n');
                        while (itl.next()) |line| try lines.append(self.arena, .{ .str = line });
                        break :blk lines.items;
                    },
                    else => return self.fail("for: cannot iterate a {s}", .{iter.typeName()}),
                };
                var last: Value = .nothing;
                if (self.frame) |fr| {
                    for (items) |item| {
                        try fr.set(self.arena, f.name, item);
                        last = try self.evalNode(f.body);
                    }
                    return last;
                }
                // Top level: the loop variable is bound unboxed while the
                // loop runs (no copy per row), and boxed once at the end —
                // or on the way out of an error, so the slot never keeps
                // an arena pointer past the line.
                var current: Value = .nothing;
                errdefer self.bind(f.name, .nothing) catch {};
                for (items) |item| {
                    current = item;
                    try self.bindSlot(f.name, item, null);
                    last = try self.evalNode(f.body);
                }
                try self.bind(f.name, current);
                return last;
            },
            .while_ => |w| {
                var last: Value = .nothing;
                var guard: usize = 0;
                while (try self.condition(try self.evalNode(w.cond), "while")) : (guard += 1) {
                    if (guard == 100_000) return self.fail("while: iteration limit", .{});
                    last = try self.evalNode(w.body);
                }
                return last;
            },
            else => return self.evalNode(n),
        }
    }

    pub fn evalNode(self: *Interp, n: *Node) Error!Value {
        switch (n.*) {
            .block => |stmts| return self.evalBlock(stmts),
            .pipeline => |p| return self.evalPipeline(p),
            .call => |c| return self.evalCall(c, null),
            .callv => |c| return self.evalCallv(c, null),
            .lit => |v| return v,
            .word => |w| {
                if (self.row) |r| {
                    if (r.get(w)) |v| return v;
                }
                return .{ .str = w };
            },
            .var_ => |name| return self.lookup(name) orelse self.fail("unknown variable ${s}", .{name}),
            .interp => |parts| {
                var buf: std.ArrayList(u8) = .empty;
                for (parts) |part| switch (part) {
                    .text => |t| try buf.appendSlice(self.arena, t),
                    .var_ => |name| {
                        const v = self.lookup(name) orelse return self.fail("unknown variable ${s}", .{name});
                        try renderInline(v, self.arena, &buf);
                    },
                };
                return .{ .str = buf.items };
            },
            .field => |f| {
                const base = try self.evalNode(f.base);
                return self.fieldOf(base, f.name);
            },
            .list => |items| {
                const vals = try self.arena.alloc(Value, items.len);
                for (items, 0..) |item, i| vals[i] = try self.evalNode(item);
                return .{ .list = vals };
            },
            .record => |fields| {
                const keys = try self.arena.alloc([]const u8, fields.len);
                const vals = try self.arena.alloc(Value, fields.len);
                for (fields, 0..) |f, i| {
                    keys[i] = f.key;
                    vals[i] = try self.evalNode(f.value);
                }
                return .{ .record = .{ .keys = keys, .vals = vals } };
            },
            .binop => |b| return self.evalBinop(b),
            .unop => |u| {
                const v = try self.evalNode(u.operand);
                return switch (u.op) {
                    .not => .{ .bool = !(try self.condition(v, "not")) },
                    .neg => switch (v) {
                        .int => |i| .{ .int = -%i },
                        .float => |f| .{ .float = -f },
                        else => self.fail("cannot negate a {s}", .{v.typeName()}),
                    },
                };
            },
            .fn_ => |f| return self.makeClosure("fn", f.params, f.param_shapes, f.ret, f.body, f.implicit, f.src),
            .match_ => |m| return self.evalMatch(m),
            .shape_lit => |s| {
                const out = try self.arena.create(Shape);
                out.* = try self.resolveShape(s);
                return .{ .shape = out };
            },
            .try_ => |inner| {
                // A failing evaluation becomes an err, a value an ok — and
                // a result is already in that vocabulary: it passes through.
                const v = self.evalNode(inner) catch |e| switch (e) {
                    Error.Runtime => {
                        if (self.propagating) {
                            self.propagating = false;
                            return self.ret;
                        }
                        return self.mkResult(false, .{ .str = self.err_msg });
                    },
                    else => return e,
                };
                if (v == .result) return v;
                return self.mkResult(true, v);
            },
            .unwrap => |inner| {
                const v = try self.evalNode(inner);
                if (v != .result) return self.fail("?: needs a result, got a {s}", .{v.typeName()});
                if (v.result.ok) return v.result.val;
                self.ret = v;
                self.propagating = true;
                return Error.Runtime;
            },
            .let, .def, .if_, .for_, .while_ => return self.evalStmt(n),
        }
    }

    pub fn mkResult(self: *Interp, ok: bool, v: Value) Error!Value {
        const r = try self.arena.create(Result);
        r.* = .{ .ok = ok, .val = v };
        return .{ .result = r };
    }

    // ---------------------------------------------------------- functions

    /// Build a closure in a box of its own: the tree copied, the locals
    /// of the enclosing function that the body names snapshotted, the
    /// current scope retained.
    fn makeClosure(self: *Interp, name: []const u8, params: []const []const u8, param_shapes: []const ?Shape, ret: ?Shape, body: *Node, implicit: bool, src: []const u8) Error!Value {
        const scope = try self.cur();
        const b = try self.heap.create(Box);
        b.* = .{ .rc = 0, .arena = std.heap.ArenaAllocator.init(self.heap), .value = .nothing };
        const a = b.arena.allocator();
        const cl = try a.create(Closure);
        const ps = try a.alloc([]const u8, params.len);
        for (params, 0..) |p, i| ps[i] = try a.dupe(u8, p);
        const shapes = try a.alloc(?Shape, param_shapes.len);
        for (param_shapes, 0..) |s, i| shapes[i] = if (s) |sh| try dupShape(a, sh) else null;
        var caps: std.ArrayList(Capture) = .empty;
        if (self.frame != null) try self.captureInto(a, &caps, body, params, param_shapes, ret);
        cl.* = .{
            .box = b,
            .name = try a.dupe(u8, name),
            .params = ps,
            .param_shapes = shapes,
            .ret = if (ret) |r| try dupShape(a, r) else null,
            .body = try dupNode(a, body),
            .src = try a.dupe(u8, src),
            .captures = caps.items,
            .scope = scope,
            .implicit = implicit,
        };
        scope.rc += 1;
        b.value = .{ .func = cl };
        // Born on the dead list with no references: bound by the end of
        // the statement (a `let`, a record, a module) it is kept, else it
        // was a temporary — a block argument — and reclaim frees it.
        b.dead = true;
        b.next_dead = self.dead;
        self.dead = b;
        return b.value;
    }

    /// A handle for the host: born on the dead list like a closure, kept
    /// only if something binds it by the end of the statement — else
    /// `drop` runs at reclaim, so a socket nobody kept is closed.
    pub fn newHandle(self: *Interp, kind: []const u8, id: u64, ctx: *anyopaque, drop: *const fn (ctx: *anyopaque, kind: []const u8, id: u64) void) Error!Value {
        const b = try self.heap.create(Box);
        b.* = .{ .rc = 0, .arena = std.heap.ArenaAllocator.init(self.heap), .value = .nothing };
        const a = b.arena.allocator();
        const h = try a.create(Handle);
        h.* = .{ .box = b, .kind = try a.dupe(u8, kind), .id = id, .ctx = ctx, .drop = drop };
        b.value = .{ .handle = h };
        b.dead = true;
        b.next_dead = self.dead;
        self.dead = b;
        return b.value;
    }

    /// The host closed a handle itself: `drop` will not run again.
    pub fn closeHandle(self: *Interp, v: Value) void {
        _ = self;
        if (v == .handle) @constCast(v.handle).closed = true;
    }

    /// Every name the body uses that the running function has bound is
    /// copied into the closure (a snapshot: rebinding later changes
    /// nothing the closure sees).
    fn captureInto(self: *Interp, a: std.mem.Allocator, caps: *std.ArrayList(Capture), n: *const Node, params: []const []const u8, param_shapes: []const ?Shape, ret: ?Shape) Error!void {
        var ctx = CaptureCtx{ .it = self, .a = a, .caps = caps, .params = params };
        try ctx.shapesIn(param_shapes, ret);
        try ctx.walk(n);
    }

    const CaptureCtx = struct {
        it: *Interp,
        a: std.mem.Allocator,
        caps: *std.ArrayList(Capture),
        params: []const []const u8,

        fn name(c: *CaptureCtx, nm: []const u8) Error!void {
            for (c.params) |p| if (std.mem.eql(u8, p, nm)) return;
            for (c.caps.items) |cap| if (std.mem.eql(u8, cap.name, nm)) return;
            const f = c.it.frame orelse return;
            const v = f.get(nm) orelse return;
            try c.caps.append(c.a, .{ .name = try c.a.dupe(u8, nm), .value = try c.it.dupRetained(c.a, v) });
        }

        /// A `$name` in a shape is a name like any other.
        fn shapeNames(c: *CaptureCtx, s: Shape) Error!void {
            switch (s) {
                .ref => |r| try c.name(r),
                .list_of, .ok, .err => |inner| try c.shapeNames(inner.*),
                .record_of => |fields| for (fields) |f| try c.shapeNames(f.shape),
                .one_of => |alts| for (alts) |alt| try c.shapeNames(alt),
                else => {},
            }
        }

        fn shapesIn(c: *CaptureCtx, shapes: []const ?Shape, ret: ?Shape) Error!void {
            for (shapes) |maybe| if (maybe) |s| try c.shapeNames(s);
            if (ret) |r| try c.shapeNames(r);
        }

        fn walk(c: *CaptureCtx, n: *const Node) Error!void {
            switch (n.*) {
                .let => |l| {
                    if (l.shape) |s| try c.shapeNames(s);
                    try c.walk(l.expr);
                },
                .def => |d| {
                    try c.shapesIn(d.param_shapes, d.ret);
                    try c.walk(d.body);
                },
                .if_ => |i| {
                    try c.walk(i.cond);
                    try c.walk(i.then);
                    if (i.else_) |e| try c.walk(e);
                },
                .for_ => |f| {
                    try c.walk(f.iter);
                    try c.walk(f.body);
                },
                .while_ => |w| {
                    try c.walk(w.cond);
                    try c.walk(w.body);
                },
                .block => |stmts| for (stmts) |s| try c.walk(s),
                .pipeline => |p| for (p.stages) |s| try c.walk(s),
                .call => |cl| {
                    try c.name(cl.name);
                    for (cl.args) |x| try c.walk(x);
                },
                .callv => |cl| {
                    try c.walk(cl.callee);
                    for (cl.args) |x| try c.walk(x);
                },
                .lit => {},
                .word => {},
                .var_ => |v| try c.name(v),
                .interp => |parts| for (parts) |p| switch (p) {
                    .var_ => |v| try c.name(v),
                    .text => {},
                },
                .field => |f| try c.walk(f.base),
                .list => |items| for (items) |x| try c.walk(x),
                .record => |fields| for (fields) |f| try c.walk(f.value),
                .binop => |b| {
                    try c.walk(b.lhs);
                    try c.walk(b.rhs);
                },
                .unop => |u| try c.walk(u.operand),
                .fn_ => |f| {
                    try c.shapesIn(f.param_shapes, f.ret);
                    try c.walk(f.body);
                },
                .match_ => |m| {
                    try c.walk(m.subject);
                    if (m.shape) |s| try c.shapeNames(s);
                    for (m.arms) |arm| {
                        if (arm.guard) |g| try c.walk(g);
                        try c.walk(arm.body);
                    }
                },
                .shape_lit => |s| try c.shapeNames(s),
                .try_, .unwrap => |inner| try c.walk(inner),
            }
        }
    };

    /// Call a function value: a fresh frame with its captures, its
    /// parameters (by position, or by the names the caller gives for a
    /// block argument) and `$in`; names resolve in the closure's scope.
    /// A `?` inside on an err returns that err from here.
    pub fn callValue(self: *Interp, fv: Value, args: []const Value, input: ?Value, names: ?[]const []const u8) Error!Value {
        if (fv != .func) return self.fail("cannot call a {s}", .{fv.typeName()});
        const cl = fv.func;
        const fr = try self.allocFrame(input);
        errdefer self.releaseFrame(fr);
        for (cl.captures) |c| try fr.set(self.arena, c.name, c.value);
        try fr.set(self.arena, "in", input orelse .nothing);
        if (cl.implicit) {
            const nms = names orelse &[_][]const u8{"it"};
            for (args, 0..) |a, i| {
                if (i < nms.len) try fr.set(self.arena, nms[i], a);
            }
        } else {
            if (args.len != cl.params.len) return self.fail("{s}: {d} argument(s) expected, got {d}", .{ cl.name, cl.params.len, args.len });
            for (cl.params, args) |p, a| try fr.set(self.arena, p, a);
        }
        const saved_frame = self.frame;
        const saved_scope = self.scope;
        const saved_row = self.row;
        self.frame = fr;
        self.scope = cl.scope;
        self.row = null;
        defer {
            self.frame = saved_frame;
            self.scope = saved_scope;
            self.row = saved_row;
            self.releaseFrame(fr);
        }
        // Annotated parameters are checked in the function's own scope
        // (a `$Shape` in them is the function's, not the caller's).
        if (!cl.implicit) {
            for (cl.params, cl.param_shapes, args) |p, maybe, a| {
                const s = maybe orelse continue;
                if (try self.mismatch(a, s, p)) |why| return self.fail("{s}: {s}", .{ cl.name, why });
            }
        }
        const out = self.evalNode(cl.body) catch |e| blk: {
            if (e == Error.Runtime and self.propagating) {
                self.propagating = false;
                break :blk self.ret;
            }
            return e;
        };
        if (cl.ret) |r| {
            if (try self.mismatch(out, r, "return")) |why| return self.fail("{s}: {s}", .{ cl.name, why });
        }
        return out;
    }

    fn allocFrame(self: *Interp, input: ?Value) Error!*Frame {
        if (self.free_frames.pop()) |fr| {
            fr.input = input;
            return fr;
        }
        const fr = try self.arena.create(Frame);
        fr.* = .{ .input = input };
        self.frames_made += 1;
        return fr;
    }

    fn releaseFrame(self: *Interp, fr: *Frame) void {
        fr.names.clearRetainingCapacity();
        fr.vals.clearRetainingCapacity();
        fr.input = null;
        self.free_frames.append(self.arena, fr) catch {}; // lost to the arena, not leaked
    }

    fn evalCallv(self: *Interp, c: Callv, input: ?Value) Error!Value {
        const f = try self.evalNode(c.callee);
        // `x | $f`: a function is called with the input; `$f` alone, or a
        // value that is not a function, is itself.
        if (c.args.len == 0) {
            if (f == .func and input != null) return self.callValue(f, &.{}, input, null);
            return f;
        }
        const args = try self.arena.alloc(Value, c.args.len);
        for (c.args, 0..) |a, i| args[i] = try self.evalNode(a);
        return self.callValue(f, args, input, null);
    }

    // -------------------------------------------------------------- match

    const Bind = struct { name: []const u8, value: Value };

    fn evalMatch(self: *Interp, m: Match) Error!Value {
        const subject = try self.evalNode(m.subject);
        // `match v: shape { … }`: the subject must have the shape, and the
        // arms must cover it — checked here, where the shape is known,
        // before any arm is tried, so a missing case is reported whether
        // or not it is the case that arrived.
        if (m.shape) |s| {
            const shape = try self.resolveShape(s);
            if (try self.mismatch(subject, shape, "subject")) |why| return self.fail("match: {s}", .{why});
            var pats = try self.arena.alloc(*const Pattern, m.arms.len);
            var n: usize = 0;
            for (m.arms) |*arm| {
                if (arm.guard != null) continue;
                pats[n] = &arm.pat;
                n += 1;
            }
            if (try self.uncovered(shape, pats[0..n])) |missing| {
                return self.fail("match: the arms do not cover {s}", .{try missing.text(self.arena)});
            }
        }
        var binds: std.ArrayList(Bind) = .empty;
        for (m.arms) |arm| {
            binds.clearRetainingCapacity();
            if (!try self.matchPattern(&arm.pat, subject, &binds)) continue;
            for (binds.items) |b| try self.bind(b.name, b.value);
            if (arm.guard) |g| {
                if (!try self.condition(try self.evalNode(g), "match guard")) continue;
            }
            return self.evalNode(arm.body);
        }
        var buf: std.ArrayList(u8) = .empty;
        try renderInline(subject, self.arena, &buf);
        return self.fail("match: no arm matches {s}", .{buf.items});
    }

    fn matchPattern(self: *Interp, pat: *const Pattern, v: Value, binds: *std.ArrayList(Bind)) Error!bool {
        switch (pat.*) {
            .wild => return true,
            .bind => |name| {
                try binds.append(self.arena, .{ .name = name, .value = v });
                return true;
            },
            .lit => |l| return valueEql(l, v),
            .ok => |inner| return v == .result and v.result.ok and try self.matchPattern(inner, v.result.val, binds),
            .err => |inner| return v == .result and !v.result.ok and try self.matchPattern(inner, v.result.val, binds),
            .list => |lp| {
                const items: []const Value = switch (v) {
                    .list => |l| l,
                    .table => |t| blk: {
                        const rs = try self.arena.alloc(Value, t.rows.len);
                        for (rs, 0..) |*r, i| r.* = .{ .record = t.row(i) };
                        break :blk rs;
                    },
                    else => return false,
                };
                if (lp.has_rest) {
                    if (items.len < lp.items.len) return false;
                } else if (items.len != lp.items.len) return false;
                for (lp.items, 0..) |*ip, i| {
                    if (!try self.matchPattern(ip, items[i], binds)) return false;
                }
                if (lp.rest) |name| try binds.append(self.arena, .{ .name = name, .value = .{ .list = items[lp.items.len..] } });
                return true;
            },
            .record => |fps| {
                if (v != .record) return false;
                for (fps) |fp| {
                    const fv = v.record.get(fp.key) orelse return false;
                    if (fp.pat) |*sub| {
                        if (!try self.matchPattern(sub, fv, binds)) return false;
                    } else try binds.append(self.arena, .{ .name = fp.key, .value = fv });
                }
                return true;
            },
        }
    }

    // ---------------------------------------------------------- operators

    fn fieldOf(self: *Interp, base: Value, name: []const u8) Error!Value {
        switch (base) {
            .record => |r| return r.get(name) orelse self.fail("no field '{s}'", .{name}),
            .table => |t| {
                if (std.fmt.parseInt(usize, name, 10)) |i| {
                    if (i >= t.rows.len) return self.fail("row {d} out of range", .{i});
                    return .{ .record = t.row(i) };
                } else |_| {}
                const ci = t.col(name) orelse return self.fail("no column '{s}'", .{name});
                const vals = try self.arena.alloc(Value, t.rows.len);
                for (t.rows, 0..) |r, i| vals[i] = r[ci];
                return .{ .list = vals };
            },
            .list => |l| {
                const i = std.fmt.parseInt(usize, name, 10) catch return self.fail("list index expected, got '{s}'", .{name});
                if (i >= l.len) return self.fail("index {d} out of range", .{i});
                return l[i];
            },
            else => return self.fail("cannot take .{s} of a {s}", .{ name, base.typeName() }),
        }
    }

    fn evalBinop(self: *Interp, b: BinOp) Error!Value {
        // Short-circuit logic first.
        switch (b.op) {
            .@"and" => {
                if (!try self.condition(try self.evalNode(b.lhs), "and")) return .{ .bool = false };
                return .{ .bool = try self.condition(try self.evalNode(b.rhs), "and") };
            },
            .@"or" => {
                if (try self.condition(try self.evalNode(b.lhs), "or")) return .{ .bool = true };
                return .{ .bool = try self.condition(try self.evalNode(b.rhs), "or") };
            },
            else => {},
        }
        const l = try self.evalNode(b.lhs);
        const r = try self.evalNode(b.rhs);
        switch (b.op) {
            .eq, .ne => {
                if (std.meta.activeTag(l) != std.meta.activeTag(r) and l != .nothing and r != .nothing)
                    return self.fail("cannot compare a {s} with a {s}", .{ l.typeName(), r.typeName() });
                const same = valueEql(l, r);
                return .{ .bool = if (b.op == .eq) same else !same };
            },
            .lt, .le, .gt, .ge => {
                const c = compareValues(l, r) orelse return self.fail("cannot order a {s} against a {s}", .{ l.typeName(), r.typeName() });
                return .{ .bool = switch (b.op) {
                    .lt => c == .lt,
                    .le => c != .gt,
                    .gt => c == .gt,
                    .ge => c != .lt,
                    else => unreachable,
                } };
            },
            .add => {
                if (l == .int and r == .int) return .{ .int = l.int +% r.int };
                if (l == .float and r == .float) return .{ .float = l.float + r.float };
                if (l == .str and r == .str) return .{ .str = try std.mem.concat(self.arena, u8, &.{ l.str, r.str }) };
                if (l == .bytes and r == .bytes) return .{ .bytes = try std.mem.concat(self.arena, u8, &.{ l.bytes, r.bytes }) };
                if (l == .list and r == .list) return .{ .list = try std.mem.concat(self.arena, Value, &.{ l.list, r.list }) };
                return self.fail("cannot add a {s} and a {s}", .{ l.typeName(), r.typeName() });
            },
            .sub, .mul, .div, .mod => {
                // Two ints or two floats: a number never changes kind on
                // its own (`float`/`int` convert, and say when they cannot).
                if (l == .float and r == .float) {
                    if ((b.op == .div or b.op == .mod) and r.float == 0) return self.fail("division by zero", .{});
                    return .{ .float = switch (b.op) {
                        .sub => l.float - r.float,
                        .mul => l.float * r.float,
                        .div => l.float / r.float,
                        .mod => @rem(l.float, r.float),
                        else => unreachable,
                    } };
                }
                if (l != .int or r != .int) return self.fail("arithmetic needs two ints or two floats, got a {s} and a {s}", .{ l.typeName(), r.typeName() });
                if ((b.op == .div or b.op == .mod) and r.int == 0) return self.fail("division by zero", .{});
                return .{ .int = switch (b.op) {
                    .sub => l.int -% r.int,
                    .mul => l.int *% r.int,
                    .div => @divTrunc(l.int, r.int),
                    .mod => @rem(l.int, r.int),
                    else => unreachable,
                } };
            },
            else => unreachable,
        }
    }

    fn evalPipeline(self: *Interp, p: Pipeline) Error!Value {
        var input: ?Value = null;
        for (p.stages) |stage| {
            input = switch (stage.*) {
                .call => |c| try self.evalCall(c, input),
                .callv => |c| try self.evalCallv(c, input),
                .unwrap => |inner| switch (inner.*) {
                    .call => |c| try self.unwrapValue(try self.evalCall(c, input)),
                    .callv => |c| try self.unwrapValue(try self.evalCallv(c, input)),
                    else => try self.evalNode(stage),
                },
                else => try self.evalNode(stage),
            };
        }
        var v = input orelse .nothing;
        if (p.redirect) |path| {
            var text: std.ArrayList(u8) = .empty;
            try render(v, self.arena, &text);
            const args = [_]Value{ .{ .str = path }, .{ .str = text.items } };
            v = (try self.host.call(self.host.ctx, self, "save", &args, null)) orelse
                return self.fail("cannot redirect: no save command", .{});
        }
        return v;
    }

    fn unwrapValue(self: *Interp, v: Value) Error!Value {
        if (v != .result) return self.fail("?: needs a result, got a {s}", .{v.typeName()});
        if (v.result.ok) return v.result.val;
        self.ret = v;
        self.propagating = true;
        return Error.Runtime;
    }

    fn evalCall(self: *Interp, c: Call, input: ?Value) Error!Value {
        // Language-level commands that need unevaluated arguments.
        if (std.mem.eql(u8, c.name, "where")) return self.cmdWhere(c, input);

        const args = try self.arena.alloc(Value, c.args.len);
        for (c.args, 0..) |a, i| args[i] = try self.evalNode(a);
        if (self.lookup(c.name)) |v| {
            if (v == .func) return self.callValue(v, args, input, null);
        }
        if (try self.builtin(c.name, args, input)) |v| return v;
        // A host command with a signature is checked at the boundary,
        // both ways.
        const sig: ?Signature = if (self.host.signature) |f| f(self.host.ctx, c.name) else null;
        if (sig) |s| try self.checkCall(c.name, s, args, input);
        if (try self.host.call(self.host.ctx, self, c.name, args, input)) |v| {
            if (sig) |s| {
                if (try self.mismatch(v, s.ret, "answer")) |why| return self.fail("{s}: {s} (the host's slip, not yours)", .{ c.name, why });
            }
            return v;
        }
        return self.fail("unknown command '{s}'", .{c.name});
    }

    /// The arguments and the input against a signature.
    fn checkCall(self: *Interp, name: []const u8, sig: Signature, args: []const Value, input: ?Value) Error!void {
        var required: usize = 0;
        for (sig.params) |p| {
            if (!p.optional) required += 1;
        }
        if (args.len < required) {
            var need: std.ArrayList(u8) = .empty;
            for (sig.params, 0..) |p, i| {
                if (p.optional) continue;
                if (i > 0) try need.append(self.arena, ' ');
                try need.appendSlice(self.arena, p.name);
            }
            return self.fail("{s}: {s} expected", .{ name, need.items });
        }
        if (args.len > sig.params.len and sig.rest == null) {
            return self.fail("{s}: {d} argument(s) at most, got {d}", .{ name, sig.params.len, args.len });
        }
        for (args, 0..) |a, i| {
            if (i < sig.params.len) {
                if (try self.mismatch(a, sig.params[i].shape, sig.params[i].name)) |why| return self.fail("{s}: {s}", .{ name, why });
            } else if (try self.mismatch(a, sig.rest.?, "argument")) |why| return self.fail("{s}: {s}", .{ name, why });
        }
        switch (sig.input) {
            .none => if (input) |v| {
                if (v != .nothing) return self.fail("{s}: takes no input, got a {s}", .{ name, v.typeName() });
            },
            .optional => |s| if (input) |v| {
                if (try self.mismatch(v, s, "input")) |why| return self.fail("{s}: {s}", .{ name, why });
            },
            .required => |s| {
                const v = input orelse return self.fail("{s}: needs input ({s})", .{ name, try s.text(self.arena) });
                if (try self.mismatch(v, s, "input")) |why| return self.fail("{s}: {s}", .{ name, why });
            },
        }
    }

    fn cmdWhere(self: *Interp, c: Call, input: ?Value) Error!Value {
        if (c.args.len != 1) return self.fail("where: one condition expected", .{});
        const cond = c.args[0];
        const in = input orelse return self.fail("where: needs input", .{});
        const saved = self.row;
        defer self.row = saved;
        // `$it` binds in a frame: the running function's, or one for the
        // duration (the session's names stay visible through it).
        const saved_frame = self.frame;
        var temp: ?*Frame = null;
        defer {
            self.frame = saved_frame;
            if (temp) |t| self.releaseFrame(t);
        }
        if (self.frame == null) {
            temp = try self.allocFrame(null);
            self.frame = temp;
        }
        switch (in) {
            .table => |t| {
                var rows: std.ArrayList([]const Value) = .empty;
                for (t.rows, 0..) |r, i| {
                    self.row = t.row(i);
                    try self.frame.?.set(self.arena, "it", .{ .record = self.row.? });
                    if (try self.condition(try self.evalNode(cond), "where")) try rows.append(self.arena, r);
                }
                return .{ .table = .{ .cols = t.cols, .rows = rows.items } };
            },
            .list => |l| {
                var keep: std.ArrayList(Value) = .empty;
                for (l) |item| {
                    self.row = if (item == .record) item.record else null;
                    try self.frame.?.set(self.arena, "it", item);
                    if (try self.condition(try self.evalNode(cond), "where")) try keep.append(self.arena, item);
                }
                return .{ .list = keep.items };
            },
            else => return self.fail("where: needs a table or list, got {s}", .{in.typeName()}),
        }
    }

    // ----------------------------------------------------------- builtins

    /// Items of a list, or the rows of a table as records.
    fn itemsOf(self: *Interp, v: Value, cmd: []const u8) Error![]const Value {
        return switch (v) {
            .list => |l| l,
            .table => |t| blk: {
                const rs = try self.arena.alloc(Value, t.rows.len);
                for (rs, 0..) |*r, i| r.* = .{ .record = t.row(i) };
                break :blk rs;
            },
            else => self.fail("{s}: needs a list or table, got a {s}", .{ cmd, v.typeName() }),
        };
    }

    fn funcArg(self: *Interp, args: []const Value, cmd: []const u8) Error!Value {
        if (args.len != 1 or args[0] != .func) return self.fail("{s}: a function expected", .{cmd});
        return args[0];
    }

    /// The pure builtins. null = not one of ours.
    fn builtin(self: *Interp, name: []const u8, args: []const Value, input: ?Value) Error!?Value {
        const eql = std.mem.eql;
        if (eql(u8, name, "echo")) {
            var buf: std.ArrayList(u8) = .empty;
            for (args, 0..) |a, i| {
                if (i > 0) try buf.append(self.arena, ' ');
                try renderInline(a, self.arena, &buf);
            }
            return .{ .str = buf.items };
        }
        if (eql(u8, name, "len")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("len: needs input", .{}));
            return .{ .int = @intCast(switch (v) {
                .str => |s| std.unicode.utf8CountCodepoints(s) catch s.len,
                .bytes => |b| b.len,
                .list => |l| l.len,
                .table => |t| t.rows.len,
                .record => |r| r.keys.len,
                else => return self.fail("len: cannot measure a {s}", .{v.typeName()}),
            }) };
        }
        if (eql(u8, name, "first") or eql(u8, name, "last")) {
            const v = input orelse return self.fail("{s}: needs input", .{name});
            const n: usize = if (args.len > 0) @intCast(try self.intArg(args[0], name)) else 1;
            const total = switch (v) {
                .list => |l| l.len,
                .table => |t| t.rows.len,
                else => return self.fail("{s}: needs a table or list", .{name}),
            };
            const k = @min(n, total);
            const lo = if (eql(u8, name, "first")) 0 else total - k;
            return switch (v) {
                .list => |l| .{ .list = l[lo .. lo + k] },
                .table => |t| .{ .table = .{ .cols = t.cols, .rows = t.rows[lo .. lo + k] } },
                else => unreachable,
            };
        }
        if (eql(u8, name, "reverse")) {
            const v = input orelse return self.fail("reverse: needs input", .{});
            switch (v) {
                .list => |l| {
                    const out = try self.arena.dupe(Value, l);
                    std.mem.reverse(Value, out);
                    return .{ .list = out };
                },
                .table => |t| {
                    const out = try self.arena.dupe([]const Value, t.rows);
                    std.mem.reverse([]const Value, out);
                    return .{ .table = .{ .cols = t.cols, .rows = out } };
                },
                else => return self.fail("reverse: needs a table or list", .{}),
            }
        }
        if (eql(u8, name, "sort-by")) {
            const v = input orelse return self.fail("sort-by: needs input", .{});
            if (v != .table) return self.fail("sort-by: needs a table", .{});
            var key: ?[]const u8 = null;
            var desc = false;
            for (args) |a| {
                if (a == .str and eql(u8, a.str, "--desc")) desc = true else if (a == .str) key = a.str;
            }
            const ci = v.table.col(key orelse return self.fail("sort-by: column name expected", .{})) orelse
                return self.fail("sort-by: no column '{s}'", .{key.?});
            const rows = try self.arena.dupe([]const Value, v.table.rows);
            const Ctx = struct { ci: usize, desc: bool };
            std.mem.sort([]const Value, rows, Ctx{ .ci = ci, .desc = desc }, struct {
                fn lessThan(ctx: Ctx, a: []const Value, b: []const Value) bool {
                    const c = compareValues(a[ctx.ci], b[ctx.ci]) orelse .eq;
                    return if (ctx.desc) c == .gt else c == .lt;
                }
            }.lessThan);
            return .{ .table = .{ .cols = v.table.cols, .rows = rows } };
        }
        if (eql(u8, name, "select")) {
            const v = input orelse return self.fail("select: needs input", .{});
            if (args.len == 0) return self.fail("select: column names expected", .{});
            switch (v) {
                .table => |t| {
                    const idx = try self.arena.alloc(usize, args.len);
                    const cols = try self.arena.alloc([]const u8, args.len);
                    for (args, 0..) |a, i| {
                        const cn = try self.strArg(a, "select");
                        idx[i] = t.col(cn) orelse return self.fail("select: no column '{s}'", .{cn});
                        cols[i] = cn;
                    }
                    const rows = try self.arena.alloc([]const Value, t.rows.len);
                    for (t.rows, 0..) |r, ri| {
                        const nr = try self.arena.alloc(Value, idx.len);
                        for (idx, 0..) |ci, k| nr[k] = r[ci];
                        rows[ri] = nr;
                    }
                    return .{ .table = .{ .cols = cols, .rows = rows } };
                },
                .record => |r| {
                    const keys = try self.arena.alloc([]const u8, args.len);
                    const vals = try self.arena.alloc(Value, args.len);
                    for (args, 0..) |a, i| {
                        const kn = try self.strArg(a, "select");
                        keys[i] = kn;
                        vals[i] = r.get(kn) orelse return self.fail("select: no field '{s}'", .{kn});
                    }
                    return .{ .record = .{ .keys = keys, .vals = vals } };
                },
                else => return self.fail("select: needs a table or record", .{}),
            }
        }
        if (eql(u8, name, "get")) {
            const v = input orelse return self.fail("get: needs input", .{});
            if (args.len != 1) return self.fail("get: one column or field expected", .{});
            return try self.fieldOf(v, try self.strArg(args[0], "get"));
        }
        if (eql(u8, name, "keys")) {
            const v = input orelse return self.fail("keys: needs input", .{});
            const names = switch (v) {
                .record => |r| r.keys,
                .table => |t| t.cols,
                else => return self.fail("keys: needs a record or table", .{}),
            };
            const vals = try self.arena.alloc(Value, names.len);
            for (names, 0..) |k, i| vals[i] = .{ .str = k };
            return .{ .list = vals };
        }
        if (eql(u8, name, "to-data")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("to-data: needs input", .{}));
            if (!v.isData()) return self.fail("to-data: a {s} is not data (functions, results, handles and bytes never are)", .{v.typeName()});
            var buf: std.ArrayList(u8) = .empty;
            try writeData(v, self.arena, &buf);
            return .{ .str = buf.items };
        }
        if (eql(u8, name, "to-json")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("to-json: needs input", .{}));
            if (!v.isData()) return self.fail("to-json: a {s} is not data (functions, results, handles and bytes never are)", .{v.typeName()});
            var buf: std.ArrayList(u8) = .empty;
            try json.encode(v, self.arena, &buf);
            return .{ .str = buf.items };
        }
        if (eql(u8, name, "from-json")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("from-json: needs input", .{}));
            const text: []const u8 = switch (v) {
                .str => |t| t,
                .bytes => |b| b,
                else => return self.fail("from-json: needs text or bytes", .{}),
            };
            const parsed = json.decode(self.arena, text) catch |e| return switch (e) {
                error.OutOfMemory => Error.OutOfMemory,
                error.Utf8 => self.fail("from-json: a string that is not valid UTF-8", .{}),
                error.BadJson => self.fail("from-json: not JSON", .{}),
            };
            return try tableize(self.arena, parsed);
        }
        if (eql(u8, name, "from-data")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("from-data: needs input", .{}));
            if (v != .str) return self.fail("from-data: needs text", .{});
            return try tableize(self.arena, try self.parseData(v.str));
        }
        if (eql(u8, name, "lines")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("lines: needs input", .{}));
            if (v != .str) return self.fail("lines: needs a string", .{});
            var out: std.ArrayList(Value) = .empty;
            var itl = std.mem.splitScalar(u8, v.str, '\n');
            while (itl.next()) |line| {
                if (line.len > 0) try out.append(self.arena, .{ .str = line });
            }
            return .{ .list = out.items };
        }
        // Results.
        if (eql(u8, name, "ok") or eql(u8, name, "err")) {
            if (args.len > 1) return self.fail("{s}: one value expected", .{name});
            return try self.mkResult(eql(u8, name, "ok"), if (args.len == 1) args[0] else (input orelse .nothing));
        }
        // Higher-order verbs: the function is called with each item (a
        // block argument sees it as `$it`).
        if (eql(u8, name, "map")) {
            const items = try self.itemsOf(input orelse return self.fail("map: needs input", .{}), "map");
            const f = try self.funcArg(args, "map");
            const out = try self.arena.alloc(Value, items.len);
            for (items, 0..) |item, i| out[i] = try self.callValue(f, &.{item}, null, null);
            return try tableize(self.arena, .{ .list = out });
        }
        if (eql(u8, name, "filter")) {
            const v = input orelse return self.fail("filter: needs input", .{});
            const items = try self.itemsOf(v, "filter");
            const f = try self.funcArg(args, "filter");
            var keep: std.ArrayList(Value) = .empty;
            for (items) |item| {
                if (try self.condition(try self.callValue(f, &.{item}, null, null), "filter")) try keep.append(self.arena, item);
            }
            if (v == .table) return try tableize(self.arena, .{ .list = keep.items });
            return .{ .list = keep.items };
        }
        if (eql(u8, name, "reduce")) {
            const items = try self.itemsOf(input orelse return self.fail("reduce: needs input", .{}), "reduce");
            if (args.len != 2 or args[1] != .func) return self.fail("reduce: an initial value and a function expected", .{});
            var acc = args[0];
            for (items) |item| acc = try self.callValue(args[1], &.{ acc, item }, null, &.{ "acc", "it" });
            return acc;
        }
        if (eql(u8, name, "any") or eql(u8, name, "all")) {
            const items = try self.itemsOf(input orelse return self.fail("{s}: needs input", .{name}), name);
            const f = try self.funcArg(args, name);
            const want_any = eql(u8, name, "any");
            for (items) |item| {
                const hit = try self.condition(try self.callValue(f, &.{item}, null, null), name);
                if (want_any and hit) return .{ .bool = true };
                if (!want_any and !hit) return .{ .bool = false };
            }
            return .{ .bool = !want_any };
        }
        if (eql(u8, name, "find")) {
            const items = try self.itemsOf(input orelse return self.fail("find: needs input", .{}), "find");
            const f = try self.funcArg(args, "find");
            for (items) |item| {
                if (try self.condition(try self.callValue(f, &.{item}, null, null), "find")) return item;
            }
            return .nothing;
        }
        if (eql(u8, name, "range")) {
            if (args.len != 2) return self.fail("range: from and to expected", .{});
            const lo = try self.intArg(args[0], "range");
            const hi = try self.intArg(args[1], "range");
            if (hi < lo or hi - lo > 1_000_000) return self.fail("range: bad bounds", .{});
            const out = try self.arena.alloc(Value, @intCast(hi - lo));
            for (out, 0..) |*o, i| o.* = .{ .int = lo + @as(i64, @intCast(i)) };
            return .{ .list = out };
        }
        // Strings and bytes.
        if (eql(u8, name, "join")) {
            const items = try self.itemsOf(input orelse return self.fail("join: needs input", .{}), "join");
            const sep = if (args.len > 0) try self.strArg(args[0], "join") else "";
            var buf: std.ArrayList(u8) = .empty;
            for (items, 0..) |item, i| {
                if (i > 0) try buf.appendSlice(self.arena, sep);
                if (item != .str) return self.fail("join: item {d} is a {s}, not a string", .{ i, item.typeName() });
                try buf.appendSlice(self.arena, item.str);
            }
            return .{ .str = buf.items };
        }
        if (eql(u8, name, "split")) {
            const v = input orelse return self.fail("split: needs input", .{});
            if (v != .str) return self.fail("split: needs a string", .{});
            const sep = if (args.len > 0) try self.strArg(args[0], "split") else " ";
            if (sep.len == 0) return self.fail("split: empty separator", .{});
            var out: std.ArrayList(Value) = .empty;
            var its = std.mem.splitSequence(u8, v.str, sep);
            while (its.next()) |part| try out.append(self.arena, .{ .str = part });
            return .{ .list = out.items };
        }
        if (eql(u8, name, "str")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("str: needs input", .{}));
            var buf: std.ArrayList(u8) = .empty;
            try renderInline(v, self.arena, &buf);
            return .{ .str = buf.items };
        }
        if (eql(u8, name, "int")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("int: needs input", .{}));
            return switch (v) {
                .int => try self.mkResult(true, v),
                .float => |f| if (std.math.isFinite(f) and f > -9.3e18 and f < 9.3e18)
                    try self.mkResult(true, .{ .int = @intFromFloat(@trunc(f)) })
                else
                    try self.mkResult(false, .{ .str = try std.fmt.allocPrint(self.arena, "not an int: {s}", .{try floatText(self.arena, f)}) }),
                .str => |s| if (std.fmt.parseInt(i64, std.mem.trim(u8, s, " \t\r\n"), 10)) |i|
                    try self.mkResult(true, .{ .int = i })
                else |_|
                    try self.mkResult(false, .{ .str = try std.fmt.allocPrint(self.arena, "not a number: {s}", .{s}) }),
                else => self.fail("int: needs a string, int or float, got a {s}", .{v.typeName()}),
            };
        }
        if (eql(u8, name, "float")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("float: needs input", .{}));
            return switch (v) {
                .float => try self.mkResult(true, v),
                .int => |i| try self.mkResult(true, .{ .float = @floatFromInt(i) }),
                .str => |s| if (std.fmt.parseFloat(f64, std.mem.trim(u8, s, " \t\r\n"))) |f|
                    try self.mkResult(true, .{ .float = f })
                else |_|
                    try self.mkResult(false, .{ .str = try std.fmt.allocPrint(self.arena, "not a number: {s}", .{s}) }),
                else => self.fail("float: needs a string, int or float, got a {s}", .{v.typeName()}),
            };
        }
        if (eql(u8, name, "round") or eql(u8, name, "floor") or eql(u8, name, "ceil")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("{s}: needs input", .{name}));
            return switch (v) {
                .int => v,
                .float => |f| .{ .float = if (eql(u8, name, "round")) @round(f) else if (eql(u8, name, "floor")) @floor(f) else @ceil(f) },
                else => self.fail("{s}: needs a float or int, got a {s}", .{ name, v.typeName() }),
            };
        }
        if (eql(u8, name, "type")) {
            const v = input orelse (if (args.len > 0) args[0] else .nothing);
            return .{ .str = v.typeName() };
        }
        // Shapes at a boundary: `x | check $Shape` is `ok x`, or an err
        // saying what does not fit.
        if (eql(u8, name, "check")) {
            if (args.len == 0 or args[args.len - 1] != .shape) return self.fail("check: a shape expected (last)", .{});
            const s = args[args.len - 1].shape.*;
            const v = input orelse (if (args.len == 2) args[0] else return self.fail("check: needs input, or a value before the shape", .{}));
            if (try self.mismatch(v, s, "it")) |why| return try self.mkResult(false, .{ .str = why });
            return try self.mkResult(true, v);
        }
        // `signature NAME`: a host command's signature as a record (its
        // shapes as shape values), or nothing.
        if (eql(u8, name, "signature")) {
            if (args.len != 1 or args[0] != .str) return self.fail("signature: a command name expected", .{});
            const f = self.host.signature orelse return .nothing;
            const sig = f(self.host.ctx, args[0].str) orelse return .nothing;
            return try self.signatureRecord(args[0].str, sig);
        }
        if (eql(u8, name, "to-bytes")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("to-bytes: needs input", .{}));
            return switch (v) {
                .str => |s| .{ .bytes = s },
                .bytes => v,
                else => self.fail("to-bytes: needs a string, got a {s}", .{v.typeName()}),
            };
        }
        if (eql(u8, name, "from-bytes")) {
            const v = input orelse (if (args.len > 0) args[0] else return self.fail("from-bytes: needs input", .{}));
            if (v != .bytes) return self.fail("from-bytes: needs bytes, got a {s}", .{v.typeName()});
            if (!std.unicode.utf8ValidateSlice(v.bytes)) return try self.mkResult(false, .{ .str = "not valid UTF-8" });
            return try self.mkResult(true, .{ .str = v.bytes });
        }
        if (eql(u8, name, "use")) return try self.cmdUse(args);
        return null;
    }

    /// `use path` or `use name`: the module's text — the host's `module`
    /// command finds it (a bare name in a store, a path in the view; a
    /// host without one answers `open`) — evaluated in a scope of its
    /// own; its bindings come back as a record. Functions in it keep the
    /// scope alive and call each other by name.
    fn cmdUse(self: *Interp, args: []const Value) Error!Value {
        if (args.len != 1) return self.fail("use: a path or a module name expected", .{});
        const path = try self.strArg(args[0], "use");
        if (self.use_depth == max_use_depth) return self.fail("use: modules nested too deep at {s}", .{path});
        var answer = try self.host.call(self.host.ctx, self, "module", args, null);
        if (answer == null) answer = try self.host.call(self.host.ctx, self, "open", args, null);
        var text = answer orelse return self.fail("use: cannot read {s}", .{path});
        if (text == .result) {
            if (!text.result.ok) {
                var why: std.ArrayList(u8) = .empty;
                try renderInline(text.result.val, self.arena, &why);
                return self.fail("use: {s}: {s}", .{ path, why.items });
            }
            text = text.result.val;
        }
        if (text != .str) return self.fail("use: {s} is not text", .{path});
        const mod = try self.newScope();
        const saved_scope = self.scope;
        const saved_frame = self.frame;
        self.scope = mod;
        self.frame = null;
        self.use_depth += 1;
        defer {
            self.scope = saved_scope;
            self.frame = saved_frame;
            self.use_depth -= 1;
            mod.held = false;
        }
        _ = try self.evalSource(text.str);
        const keys = try self.arena.alloc([]const u8, mod.names.items.len);
        const vals = try self.arena.alloc(Value, mod.names.items.len);
        for (mod.names.items, mod.slots.items, 0..) |n, slot, i| {
            keys[i] = try self.arena.dupe(u8, n);
            vals[i] = try dupValue(self.arena, slot.value);
        }
        return .{ .record = .{ .keys = keys, .vals = vals } };
    }

    fn intArg(self: *Interp, v: Value, cmd: []const u8) Error!i64 {
        return switch (v) {
            .int => |i| i,
            else => self.fail("{s}: an int expected, got a {s}", .{ cmd, v.typeName() }),
        };
    }

    fn strArg(self: *Interp, v: Value, cmd: []const u8) Error![]const u8 {
        return switch (v) {
            .str => |s| s,
            else => self.fail("{s}: a name expected, got a {s}", .{ cmd, v.typeName() }),
        };
    }

    // ------------------------------------------------------------- shapes

    /// A shape with every `$name` looked up: what `shape …` evaluates to,
    /// so a shape value carries no names to resolve later.
    fn resolveShape(self: *Interp, s: Shape) Error!Shape {
        switch (s) {
            .ref => |name| {
                const v = self.lookup(name) orelse return self.fail("shape: unknown variable ${s}", .{name});
                if (v != .shape) return self.fail("shape: ${s} is a {s}, not a shape", .{ name, v.typeName() });
                return v.shape.*;
            },
            .list_of, .ok, .err => |inner| {
                const out = try self.arena.create(Shape);
                out.* = try self.resolveShape(inner.*);
                return switch (s) {
                    .list_of => .{ .list_of = out },
                    .ok => .{ .ok = out },
                    else => .{ .err = out },
                };
            },
            .record_of => |fields| {
                const out = try self.arena.alloc(Shape.Field, fields.len);
                for (fields, 0..) |f, i| out[i] = .{ .key = f.key, .shape = try self.resolveShape(f.shape) };
                return .{ .record_of = out };
            },
            .one_of => |alts| {
                const out = try self.arena.alloc(Shape, alts.len);
                for (alts, 0..) |alt, i| out[i] = try self.resolveShape(alt);
                return .{ .one_of = out };
            },
            else => return s,
        }
    }

    /// Null when `v` has shape `s`; else why not — "path is 3, not
    /// string", "path.size is a string, not int", "path has no field
    /// 'size'" — with `path` naming what was checked.
    pub fn mismatch(self: *Interp, v: Value, s: Shape, path: []const u8) Error!?[]const u8 {
        const fits: bool = switch (s) {
            .any => true,
            .nothing => v == .nothing,
            .bool => v == .bool,
            .int => v == .int,
            .float => v == .float,
            .string => v == .str,
            .bytes => v == .bytes,
            .list => v == .list or v == .table,
            .record => v == .record,
            .table => v == .table or (v == .list and for (v.list) |x| {
                if (x != .record) break false;
            } else true),
            .function => v == .func,
            .result => v == .result,
            .shape => v == .shape,
            .handle => v == .handle,
            .kind => |k| v == .handle and std.mem.eql(u8, v.handle.kind, k),
            .word => |w| v == .str and std.mem.eql(u8, v.str, w),
            .ref => return self.mismatch(v, try self.resolveShape(s), path),
            .one_of => |alts| for (alts) |alt| {
                if (try self.mismatch(v, alt, path) == null) break true;
            } else false,
            .list_of => |inner| {
                const items: []const Value = switch (v) {
                    .list => |l| l,
                    .table => |t| blk: {
                        const rs = try self.arena.alloc(Value, t.rows.len);
                        for (rs, 0..) |*r, i| r.* = .{ .record = t.row(i) };
                        break :blk rs;
                    },
                    else => return try self.explain(v, s, path),
                };
                for (items, 0..) |item, i| {
                    if (try self.mismatch(item, inner.*, try std.fmt.allocPrint(self.arena, "{s}[{d}]", .{ path, i }))) |why| return why;
                }
                return null;
            },
            .record_of => |fields| {
                if (v != .record) return try self.explain(v, s, path);
                for (fields) |f| {
                    const fv = v.record.get(f.key) orelse return try std.fmt.allocPrint(self.arena, "{s} has no field '{s}'", .{ path, f.key });
                    if (try self.mismatch(fv, f.shape, try std.fmt.allocPrint(self.arena, "{s}.{s}", .{ path, f.key }))) |why| return why;
                }
                return null;
            },
            .ok, .err => |inner| {
                if (v != .result or v.result.ok != (s == .ok)) return try self.explain(v, s, path);
                return self.mismatch(v.result.val, inner.*, try std.fmt.allocPrint(self.arena, "{s} ({s})", .{ path, if (s == .ok) "ok" else "err" }));
            },
        };
        if (fits) return null;
        return try self.explain(v, s, path);
    }

    fn explain(self: *Interp, v: Value, s: Shape, path: []const u8) Error![]const u8 {
        var buf: std.ArrayList(u8) = .empty;
        try buf.appendSlice(self.arena, path);
        try buf.appendSlice(self.arena, " is ");
        switch (v) {
            .nothing, .bool, .int, .float => try renderInline(v, self.arena, &buf),
            .str => |t| if (t.len <= 24) {
                try writeStr(t, self.arena, &buf);
            } else try buf.appendSlice(self.arena, "a string"),
            .result => |r| {
                try buf.appendSlice(self.arena, if (r.ok) "ok " else "err ");
                if (r.val == .record or r.val == .table or r.val == .list) {
                    try buf.appendSlice(self.arena, "a ");
                    try buf.appendSlice(self.arena, r.val.typeName());
                } else try renderInline(r.val, self.arena, &buf);
            },
            else => {
                try buf.appendSlice(self.arena, "a ");
                try buf.appendSlice(self.arena, v.typeName());
            },
        }
        try buf.appendSlice(self.arena, ", not ");
        try s.write(self.arena, &buf);
        return buf.items;
    }

    /// The part of `s` that no pattern in `pats` covers, or null when
    /// they cover it all. A catch-all covers anything; a word needs a
    /// literal; `bool` both literals; `ok S` an `ok p` whose `p` covers
    /// S; a record shape a record pattern whose fields all cover theirs;
    /// a list shape `[..]`; everything else a catch-all.
    fn uncovered(self: *Interp, s: Shape, pats: []const *const Pattern) Error!?Shape {
        for (pats) |p| if (p.irrefutable()) return null;
        switch (s) {
            .one_of => |alts| {
                for (alts) |alt| if (try self.uncovered(alt, pats)) |u| return u;
                return null;
            },
            .ref => return self.uncovered(try self.resolveShape(s), pats),
            .word => |w| {
                for (pats) |p| if (p.* == .lit and p.lit == .str and std.mem.eql(u8, p.lit.str, w)) return null;
                return s;
            },
            .nothing => {
                for (pats) |p| if (p.* == .lit and p.lit == .nothing) return null;
                return s;
            },
            .bool => {
                var t = false;
                var f = false;
                for (pats) |p| if (p.* == .lit and p.lit == .bool) {
                    if (p.lit.bool) t = true else f = true;
                };
                if (t and f) return null;
                return .{ .word = if (t) "false" else "true" };
            },
            .result => {
                const any: Shape = .any;
                const both = [_]Shape{ .{ .ok = &any }, .{ .err = &any } };
                return self.uncovered(.{ .one_of = &both }, pats);
            },
            .ok, .err => |inner| {
                var subs: std.ArrayList(*const Pattern) = .empty;
                for (pats) |p| {
                    if (p.* == .ok and s == .ok) try subs.append(self.arena, p.ok);
                    if (p.* == .err and s == .err) try subs.append(self.arena, p.err);
                }
                const u = (try self.uncovered(inner.*, subs.items)) orelse return null;
                const boxed = try self.arena.create(Shape);
                boxed.* = u;
                return if (s == .ok) .{ .ok = boxed } else .{ .err = boxed };
            },
            .record_of => |fields| {
                var recs: std.ArrayList(*const Pattern) = .empty;
                for (pats) |p| if (p.* == .record) try recs.append(self.arena, p);
                return if (try self.recordCovered(fields, recs.items)) null else s;
            },
            .list_of => {
                for (pats) |p| if (p.* == .list and p.list.items.len == 0 and p.list.has_rest) return null;
                return s;
            },
            else => return s,
        }
    }

    /// Do these record patterns, together, match every record of the
    /// shape? Case by case: take the first field any pattern names,
    /// split the field's shape into its alternatives, and for each keep
    /// the patterns that admit it — with that field crossed off — until
    /// a pattern has nothing left to ask (it matches) or no pattern
    /// remains for some case (it does not).
    fn recordCovered(self: *Interp, fields: []const Shape.Field, pats: []const *const Pattern) Error!bool {
        var key: ?[]const u8 = null;
        for (pats) |p| {
            if (p.record.len == 0) return true;
            if (key == null) key = p.record[0].key;
        }
        const k = key orelse return false;
        const fshape = for (fields) |f| {
            if (std.mem.eql(u8, f.key, k)) break f.shape;
        } else return false; // a field the shape does not promise: never relied on
        const cases: []const Shape = switch (fshape) {
            .one_of => |alts| alts,
            .bool => &.{ .{ .word = "true" }, .{ .word = "false" } },
            else => &.{fshape},
        };
        for (cases) |case| {
            var kept: std.ArrayList(*const Pattern) = .empty;
            for (pats) |p| {
                var admits = true;
                var rest: std.ArrayList(FieldPat) = .empty;
                for (p.record) |fp| {
                    if (!std.mem.eql(u8, fp.key, k)) {
                        try rest.append(self.arena, fp);
                        continue;
                    }
                    if (fp.pat) |*sub| {
                        const one = [_]*const Pattern{sub};
                        const probe: Shape = if (fshape == .bool and case == .word) .bool else case;
                        if (fshape == .bool) {
                            // The bool cases are words here; a literal must name this one.
                            admits = sub.irrefutable() or (sub.* == .lit and sub.lit == .bool and sub.lit.bool == std.mem.eql(u8, case.word, "true"));
                        } else admits = (try self.uncovered(probe, &one)) == null;
                    }
                }
                if (!admits) continue;
                const np = try self.arena.create(Pattern);
                np.* = .{ .record = rest.items };
                try kept.append(self.arena, np);
            }
            if (!try self.recordCovered(fields, kept.items)) return false;
        }
        return true;
    }

    fn signatureRecord(self: *Interp, name: []const u8, sig: Signature) Error!Value {
        const a = self.arena;
        const params = try a.alloc(Value, sig.params.len);
        for (sig.params, 0..) |p, i| {
            const sh = try a.create(Shape);
            sh.* = p.shape;
            const keys = try a.dupe([]const u8, &.{ "name", "shape", "optional" });
            const vals = try a.dupe(Value, &.{ .{ .str = p.name }, .{ .shape = sh }, .{ .bool = p.optional } });
            params[i] = .{ .record = .{ .keys = keys, .vals = vals } };
        }
        const rest: Value = if (sig.rest) |r| blk: {
            const sh = try a.create(Shape);
            sh.* = r;
            break :blk .{ .shape = sh };
        } else .nothing;
        const input: Value = switch (sig.input) {
            .none => .nothing,
            .optional, .required => |s| blk: {
                const sh = try a.create(Shape);
                sh.* = s;
                break :blk .{ .shape = sh };
            },
        };
        const ret = try a.create(Shape);
        ret.* = sig.ret;
        const keys = try a.dupe([]const u8, &.{ "name", "params", "rest", "input", "returns" });
        const vals = try a.dupe(Value, &.{ .{ .str = name }, try tableize(a, .{ .list = params }), rest, input, .{ .shape = ret } });
        return .{ .record = .{ .keys = keys, .vals = vals } };
    }
};

/// A float as text that reads back as a float: a fraction always
/// (`3.0`, never `3`), exponent form for the very large and small.
pub fn floatText(a: std.mem.Allocator, f: f64) Error![]const u8 {
    if (std.math.isNan(f)) return "nan";
    if (std.math.isInf(f)) return if (f > 0) "inf" else "-inf";
    const mag = @abs(f);
    var buf: [64]u8 = undefined;
    if (mag != 0 and (mag >= 1e15 or mag < 1e-4)) return a.dupe(u8, std.fmt.bufPrint(&buf, "{e}", .{f}) catch "0.0");
    const t = std.fmt.bufPrint(&buf, "{d}", .{f}) catch "0.0";
    if (std.mem.indexOfScalar(u8, t, '.') == null) return std.mem.concat(a, u8, &.{ t, ".0" });
    return a.dupe(u8, t);
}

/// Deep copy of a shape (annotations outlive the line arena).
fn dupShape(a: std.mem.Allocator, s: Shape) Error!Shape {
    return switch (s) {
        .kind => |k| .{ .kind = try a.dupe(u8, k) },
        .word => |w| .{ .word = try a.dupe(u8, w) },
        .ref => |r| .{ .ref = try a.dupe(u8, r) },
        .list_of => |inner| .{ .list_of = try dupShapePtr(a, inner) },
        .ok => |inner| .{ .ok = try dupShapePtr(a, inner) },
        .err => |inner| .{ .err = try dupShapePtr(a, inner) },
        .record_of => |fields| blk: {
            const out = try a.alloc(Shape.Field, fields.len);
            for (fields, 0..) |f, i| out[i] = .{ .key = try a.dupe(u8, f.key), .shape = try dupShape(a, f.shape) };
            break :blk .{ .record_of = out };
        },
        .one_of => |alts| blk: {
            const out = try a.alloc(Shape, alts.len);
            for (alts, 0..) |alt, i| out[i] = try dupShape(a, alt);
            break :blk .{ .one_of = out };
        },
        else => s,
    };
}

fn dupShapePtr(a: std.mem.Allocator, s: *const Shape) Error!*const Shape {
    const out = try a.create(Shape);
    out.* = try dupShape(a, s.*);
    return out;
}

/// A list of records with one shape is a table; anything else is itself.
/// The data syntax has no table literal — a table IS a list of records —
/// so readers call this on what they parse.
pub fn tableize(a: std.mem.Allocator, v: Value) Error!Value {
    if (v != .list or v.list.len == 0) return v;
    const first = v.list[0];
    if (first != .record) return v;
    const cols = first.record.keys;
    for (v.list) |item| {
        if (item != .record or item.record.keys.len != cols.len) return v;
        for (item.record.keys, cols) |k, c| {
            if (!std.mem.eql(u8, k, c)) return v;
        }
    }
    const rows = try a.alloc([]const Value, v.list.len);
    for (v.list, 0..) |item, i| rows[i] = item.record.vals;
    return .{ .table = .{ .cols = cols, .rows = rows } };
}

/// Write a value as a data literal the strict parser reads back: the
/// interchange form for files (`to-data` / `from-data`) and for programs
/// that hand msh structured results. Functions, results and bytes are
/// not data (Error.Runtime; `to-data` says so first).
pub fn writeData(v: Value, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .nothing => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |i| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0");
        },
        .float => |f| {
            if (!std.math.isFinite(f)) return Error.Runtime;
            try out.appendSlice(a, try floatText(a, f));
        },
        .str => |s| try writeStr(s, a, out),
        .list => |l| {
            try out.append(a, '[');
            for (l, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try writeData(item, a, out);
            }
            try out.append(a, ']');
        },
        .record => |r| {
            try out.append(a, '{');
            for (r.keys, r.vals, 0..) |k, val, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, k);
                try out.appendSlice(a, ": ");
                try writeData(val, a, out);
            }
            try out.append(a, '}');
        },
        .table => |t| {
            try out.append(a, '[');
            for (t.rows, 0..) |row, ri| {
                if (ri > 0) try out.appendSlice(a, ",\n ");
                try writeData(.{ .record = .{ .keys = t.cols, .vals = row } }, a, out);
            }
            try out.append(a, ']');
        },
        .bytes, .func, .result, .handle, .shape => return Error.Runtime,
    }
}

/// Quote unless the text reads back as the same bare word.
fn writeStr(s: []const u8, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    var bare = s.len > 0 and !std.ascii.isDigit(s[0]) and s[0] != '-' and s[0] != '$';
    for (s) |c| {
        if (!Lexer.isWordChar(c) or c == ':' or c == '#') bare = false;
    }
    if (bare and s[s.len - 1] == ':') bare = false;
    for ([_][]const u8{ "true", "false", "null", "not", "and", "or", "in", "fn", "match", "try", "shape", "_" }) |kw| {
        if (std.mem.eql(u8, s, kw)) bare = false;
    }
    if (bare) return out.appendSlice(a, s);
    try out.append(a, '"');
    for (s) |c| switch (c) {
        '"' => try out.appendSlice(a, "\\\""),
        '\\' => try out.appendSlice(a, "\\\\"),
        '\n' => try out.appendSlice(a, "\\n"),
        '$' => try out.appendSlice(a, "\\$"),
        else => try out.append(a, c),
    };
    try out.append(a, '"');
}

/// Deep copy of a tree (function bodies outlive the line arena).
fn dupNode(a: std.mem.Allocator, n: *Node) Error!*Node {
    const out = try a.create(Node);
    out.* = switch (n.*) {
        .let => |l| .{ .let = .{ .name = try a.dupe(u8, l.name), .shape = if (l.shape) |s| try dupShape(a, s) else null, .expr = try dupNode(a, l.expr) } },
        .def => |d| .{ .def = .{ .name = try a.dupe(u8, d.name), .params = try dupStrs(a, d.params), .param_shapes = try dupShapes(a, d.param_shapes), .ret = if (d.ret) |r| try dupShape(a, r) else null, .body = try dupNode(a, d.body), .src = try a.dupe(u8, d.src) } },
        .if_ => |c| .{ .if_ = .{ .cond = try dupNode(a, c.cond), .then = try dupNode(a, c.then), .else_ = if (c.else_) |e| try dupNode(a, e) else null } },
        .for_ => |f| .{ .for_ = .{ .name = try a.dupe(u8, f.name), .iter = try dupNode(a, f.iter), .body = try dupNode(a, f.body) } },
        .while_ => |w| .{ .while_ = .{ .cond = try dupNode(a, w.cond), .body = try dupNode(a, w.body) } },
        .block => |stmts| .{ .block = try dupNodes(a, stmts) },
        .pipeline => |p| .{ .pipeline = .{ .stages = try dupNodes(a, p.stages), .redirect = if (p.redirect) |r| try a.dupe(u8, r) else null } },
        .call => |c| .{ .call = .{ .name = try a.dupe(u8, c.name), .args = try dupNodes(a, c.args) } },
        .callv => |c| .{ .callv = .{ .callee = try dupNode(a, c.callee), .args = try dupNodes(a, c.args) } },
        .lit => |v| .{ .lit = try dupValue(a, v) },
        .word => |w| .{ .word = try a.dupe(u8, w) },
        .var_ => |v| .{ .var_ = try a.dupe(u8, v) },
        .interp => |parts| blk: {
            const ps = try a.alloc(StrPart, parts.len);
            for (parts, 0..) |p, i| ps[i] = switch (p) {
                .text => |t| .{ .text = try a.dupe(u8, t) },
                .var_ => |v| .{ .var_ = try a.dupe(u8, v) },
            };
            break :blk .{ .interp = ps };
        },
        .field => |f| .{ .field = .{ .base = try dupNode(a, f.base), .name = try a.dupe(u8, f.name) } },
        .list => |items| .{ .list = try dupNodes(a, items) },
        .record => |fields| blk: {
            const fs = try a.alloc(RecField, fields.len);
            for (fields, 0..) |f, i| fs[i] = .{ .key = try a.dupe(u8, f.key), .value = try dupNode(a, f.value) };
            break :blk .{ .record = fs };
        },
        .binop => |b| .{ .binop = .{ .op = b.op, .lhs = try dupNode(a, b.lhs), .rhs = try dupNode(a, b.rhs) } },
        .unop => |u| .{ .unop = .{ .op = u.op, .operand = try dupNode(a, u.operand) } },
        .fn_ => |f| .{ .fn_ = .{ .params = try dupStrs(a, f.params), .param_shapes = try dupShapes(a, f.param_shapes), .ret = if (f.ret) |r| try dupShape(a, r) else null, .body = try dupNode(a, f.body), .implicit = f.implicit, .src = try a.dupe(u8, f.src) } },
        .match_ => |m| blk: {
            const arms = try a.alloc(Arm, m.arms.len);
            for (m.arms, 0..) |arm, i| arms[i] = .{
                .pat = try dupPattern(a, &arm.pat),
                .guard = if (arm.guard) |g| try dupNode(a, g) else null,
                .body = try dupNode(a, arm.body),
            };
            break :blk .{ .match_ = .{ .subject = try dupNode(a, m.subject), .shape = if (m.shape) |s| try dupShape(a, s) else null, .arms = arms } };
        },
        .shape_lit => |s| .{ .shape_lit = try dupShape(a, s) },
        .try_ => |inner| .{ .try_ = try dupNode(a, inner) },
        .unwrap => |inner| .{ .unwrap = try dupNode(a, inner) },
    };
    return out;
}

fn dupShapes(a: std.mem.Allocator, ss: []const ?Shape) Error![]const ?Shape {
    const out = try a.alloc(?Shape, ss.len);
    for (ss, 0..) |s, i| out[i] = if (s) |sh| try dupShape(a, sh) else null;
    return out;
}

fn dupPattern(a: std.mem.Allocator, p: *const Pattern) Error!Pattern {
    return switch (p.*) {
        .wild => .wild,
        .bind => |n| .{ .bind = try a.dupe(u8, n) },
        .lit => |v| .{ .lit = try dupValue(a, v) },
        .ok => |inner| .{ .ok = try dupPatternPtr(a, inner) },
        .err => |inner| .{ .err = try dupPatternPtr(a, inner) },
        .list => |lp| blk: {
            const items = try a.alloc(Pattern, lp.items.len);
            for (lp.items, 0..) |*ip, i| items[i] = try dupPattern(a, ip);
            break :blk .{ .list = .{ .items = items, .has_rest = lp.has_rest, .rest = if (lp.rest) |r| try a.dupe(u8, r) else null } };
        },
        .record => |fps| blk: {
            const out = try a.alloc(FieldPat, fps.len);
            for (fps, 0..) |fp, i| out[i] = .{ .key = try a.dupe(u8, fp.key), .pat = if (fp.pat) |*sub| try dupPattern(a, sub) else null };
            break :blk .{ .record = out };
        },
    };
}

fn dupPatternPtr(a: std.mem.Allocator, p: *const Pattern) Error!*const Pattern {
    const out = try a.create(Pattern);
    out.* = try dupPattern(a, p);
    return out;
}

fn dupNodes(a: std.mem.Allocator, ns: []const *Node) Error![]const *Node {
    const out = try a.alloc(*Node, ns.len);
    for (ns, 0..) |n, i| out[i] = try dupNode(a, n);
    return out;
}

/// Structural equality. Values of different types are never equal
/// (the `==` operator refuses to compare them at all); functions are
/// equal only to themselves.
pub fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) return false;
    return switch (a) {
        .nothing => true,
        .bool => a.bool == b.bool,
        .int => a.int == b.int,
        .float => a.float == b.float,
        .str => std.mem.eql(u8, a.str, b.str),
        .bytes => std.mem.eql(u8, a.bytes, b.bytes),
        .list => blk: {
            if (a.list.len != b.list.len) break :blk false;
            for (a.list, b.list) |x, y| {
                if (!valueEql(x, y)) break :blk false;
            }
            break :blk true;
        },
        .record => blk: {
            if (a.record.keys.len != b.record.keys.len) break :blk false;
            for (a.record.keys, a.record.vals) |k, v| {
                const o = b.record.get(k) orelse break :blk false;
                if (!valueEql(v, o)) break :blk false;
            }
            break :blk true;
        },
        .table => blk: {
            if (a.table.rows.len != b.table.rows.len or a.table.cols.len != b.table.cols.len) break :blk false;
            for (a.table.cols, b.table.cols) |x, y| {
                if (!std.mem.eql(u8, x, y)) break :blk false;
            }
            for (a.table.rows, b.table.rows) |x, y| {
                for (x, y) |p, q| {
                    if (!valueEql(p, q)) break :blk false;
                }
            }
            break :blk true;
        },
        .func => a.func == b.func,
        .handle => a.handle == b.handle,
        .result => a.result.ok == b.result.ok and valueEql(a.result.val, b.result.val),
        .shape => shapeEql(a.shape.*, b.shape.*),
    };
}

/// Shapes are equal when they are written the same.
fn shapeEql(a: Shape, b: Shape) bool {
    var bufs: [2][256]u8 = undefined;
    var fa = std.heap.FixedBufferAllocator.init(&bufs[0]);
    var fb = std.heap.FixedBufferAllocator.init(&bufs[1]);
    const ta = a.text(fa.allocator()) catch return false;
    const tb = b.text(fb.allocator()) catch return false;
    return std.mem.eql(u8, ta, tb);
}

/// Ordering, for values of one orderable type only.
pub fn compareValues(a: Value, b: Value) ?std.math.Order {
    if (a == .int and b == .int) return std.math.order(a.int, b.int);
    if (a == .float and b == .float) return if (a.float < b.float) .lt else if (a.float > b.float) .gt else .eq;
    if (a == .str and b == .str) return std.mem.order(u8, a.str, b.str);
    if (a == .bytes and b == .bytes) return std.mem.order(u8, a.bytes, b.bytes);
    return null;
}

/// Deep copy into another allocator (values outlive the line arena).
/// Functions are shared, not copied: a function IS its box.
pub fn dupValue(a: std.mem.Allocator, v: Value) Error!Value {
    return switch (v) {
        .nothing, .bool, .int, .float, .func, .handle => v,
        .shape => |s| .{ .shape = try dupShapePtr(a, s) },
        .str => |s| .{ .str = try a.dupe(u8, s) },
        .bytes => |s| .{ .bytes = try a.dupe(u8, s) },
        .list => |l| blk: {
            const out = try a.alloc(Value, l.len);
            for (l, 0..) |x, i| out[i] = try dupValue(a, x);
            break :blk .{ .list = out };
        },
        .record => |r| .{ .record = .{ .keys = try dupStrs(a, r.keys), .vals = try dupVals(a, r.vals) } },
        .table => |t| blk: {
            const rows = try a.alloc([]const Value, t.rows.len);
            for (t.rows, 0..) |r, i| rows[i] = try dupVals(a, r);
            break :blk .{ .table = .{ .cols = try dupStrs(a, t.cols), .rows = rows } };
        },
        .result => |r| blk: {
            const out = try a.create(Result);
            out.* = .{ .ok = r.ok, .val = try dupValue(a, r.val) };
            break :blk .{ .result = out };
        },
    };
}

/// One more reference on every function inside a value.
fn retainValue(v: Value) void {
    switch (v) {
        .func => |cl| cl.box.rc += 1,
        .handle => |h| h.box.rc += 1,
        .list => |l| for (l) |x| retainValue(x),
        .record => |r| for (r.vals) |x| retainValue(x),
        .table => |t| for (t.rows) |row| {
            for (row) |x| retainValue(x);
        },
        .result => |r| retainValue(r.val),
        else => {},
    }
}

fn dupStrs(a: std.mem.Allocator, ss: []const []const u8) Error![]const []const u8 {
    const out = try a.alloc([]const u8, ss.len);
    for (ss, 0..) |s, i| out[i] = try a.dupe(u8, s);
    return out;
}

fn dupVals(a: std.mem.Allocator, vs: []const Value) Error![]const Value {
    const out = try a.alloc(Value, vs.len);
    for (vs, 0..) |v, i| out[i] = try dupValue(a, v);
    return out;
}

// ------------------------------------------------------------- rendering

/// Render a value as the human sees it: scalars plain, lists one per
/// line, records as "key: value" lines, tables as aligned columns.
pub fn render(v: Value, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .nothing => {},
        // At the top, an `ok` shows what it holds (the answer is the
        // interesting part; `ls` is a table on the screen, not "ok
        // <table>") and an `err` says so.
        .result => |r| {
            if (r.ok) return render(r.val, a, out);
            try renderInline(v, a, out);
            try out.append(a, '\n');
        },
        .bool, .int, .float, .str, .bytes, .func, .handle, .shape => {
            try renderInline(v, a, out);
            try out.append(a, '\n');
        },
        .list => |l| {
            for (l) |item| {
                if (item == .record or item == .list or item == .table) {
                    try render(item, a, out);
                } else {
                    try renderInline(item, a, out);
                    try out.append(a, '\n');
                }
            }
        },
        .record => |r| {
            var w: usize = 0;
            for (r.keys) |k| w = @max(w, k.len);
            for (r.keys, r.vals) |k, val| {
                try out.appendSlice(a, k);
                try out.append(a, ':');
                try out.appendNTimes(a, ' ', w - k.len + 1);
                try renderInline(val, a, out);
                try out.append(a, '\n');
            }
        },
        .table => |t| {
            const widths = try a.alloc(usize, t.cols.len);
            for (t.cols, 0..) |c, i| widths[i] = c.len;
            var cell: std.ArrayList(u8) = .empty;
            for (t.rows) |r| {
                for (r, 0..) |val, i| {
                    cell.clearRetainingCapacity();
                    try renderInline(val, a, &cell);
                    widths[i] = @max(widths[i], @min(cell.items.len, 40));
                }
            }
            try renderRow(a, out, t.cols.len, widths, HeaderCells{ .cols = t.cols }, true);
            for (t.rows) |r| try renderRow(a, out, t.cols.len, widths, RowCells{ .vals = r }, false);
        },
    }
}

const HeaderCells = struct {
    cols: []const []const u8,
    fn cellText(self: @This(), a: std.mem.Allocator, i: usize, buf: *std.ArrayList(u8)) Error!void {
        try buf.appendSlice(a, self.cols[i]);
    }
};

const RowCells = struct {
    vals: []const Value,
    fn cellText(self: @This(), a: std.mem.Allocator, i: usize, buf: *std.ArrayList(u8)) Error!void {
        try renderInline(self.vals[i], a, buf);
    }
};

fn renderRow(a: std.mem.Allocator, out: *std.ArrayList(u8), ncols: usize, widths: []const usize, cells: anytype, header: bool) Error!void {
    var cell: std.ArrayList(u8) = .empty;
    for (0..ncols) |i| {
        cell.clearRetainingCapacity();
        try cells.cellText(a, i, &cell);
        const text = cell.items[0..@min(cell.items.len, 40)];
        try out.appendSlice(a, text);
        if (i + 1 < ncols) try out.appendNTimes(a, ' ', widths[i] - text.len + 2);
    }
    try out.append(a, '\n');
    if (header) {
        for (0..ncols) |i| {
            try out.appendNTimes(a, '-', widths[i]);
            if (i + 1 < ncols) try out.appendNTimes(a, ' ', 2);
        }
        try out.append(a, '\n');
    }
}

/// One-line form (cells, echo, interpolation).
pub fn renderInline(v: Value, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .nothing => {},
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |i| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "?");
        },
        .float => |f| try out.appendSlice(a, try floatText(a, f)),
        .str => |s| try out.appendSlice(a, s),
        .bytes => |b| {
            var buf: [32]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "<bytes: {d}>", .{b.len}) catch "<bytes>");
        },
        .shape => |s| try s.write(a, out),
        .list => |l| {
            try out.append(a, '[');
            for (l, 0..) |item, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try renderInline(item, a, out);
            }
            try out.append(a, ']');
        },
        .record => |r| {
            try out.append(a, '{');
            for (r.keys, r.vals, 0..) |k, val, i| {
                if (i > 0) try out.appendSlice(a, ", ");
                try out.appendSlice(a, k);
                try out.appendSlice(a, ": ");
                try renderInline(val, a, out);
            }
            try out.append(a, '}');
        },
        .table => |t| {
            var buf: [32]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "<table: {d} rows>", .{t.rows.len}) catch "<table>");
        },
        .func => |cl| {
            try out.appendSlice(a, "<fn ");
            try out.appendSlice(a, cl.name);
            if (cl.implicit) {
                try out.appendSlice(a, " { $it }");
            } else {
                try out.appendSlice(a, " [");
                for (cl.params, 0..) |p, i| {
                    if (i > 0) try out.appendSlice(a, ", ");
                    try out.appendSlice(a, p);
                }
                try out.append(a, ']');
            }
            try out.append(a, '>');
        },
        .result => |r| {
            try out.appendSlice(a, if (r.ok) "ok " else "err ");
            try renderInline(r.val, a, out);
        },
        .handle => |h| {
            var buf: [24]u8 = undefined;
            try out.append(a, '<');
            try out.appendSlice(a, h.kind);
            try out.appendSlice(a, std.fmt.bufPrint(&buf, " {d}", .{h.id}) catch "");
            if (h.closed) try out.appendSlice(a, " closed");
            try out.append(a, '>');
        },
    }
}

// ----------------------------------------------------------------- lexer

const Tok = union(enum) {
    word: []const u8,
    string: []const u8, // raw contents, escapes and $vars unprocessed
    number: Value, // an int, or a float
    var_: []const u8,
    ret_arrow, // `->`, the return shape of a function
    lparen,
    rparen,
    lbrace,
    rbrace,
    lbracket,
    rbracket,
    pipe,
    semi,
    newline,
    redirect,
    comma,
    question,
    arrow,
    op: Op,
    eof,
};

const Op = enum { eq, ne, lt, le, gt, ge, add, sub, mul, div, mod, @"and", @"or", assign };

const Lexer = struct {
    src: []const u8,
    pos: usize = 0,
    /// Set while lexing expression context so '-' before a digit is a
    /// number and '>' is a comparison; at command level '>' redirects.
    expr: bool = false,

    fn isWordChar(c: u8) bool {
        return switch (c) {
            ' ', '\t', '\r', '\n', '(', ')', '[', ']', '{', '}', '|', ';', '"', '$', ',', '>', '<', '=', '!', '?' => false,
            else => true,
        };
    }

    fn peekByte(l: *Lexer) ?u8 {
        return if (l.pos < l.src.len) l.src[l.pos] else null;
    }

    fn next(l: *Lexer) Tok {
        while (l.pos < l.src.len and (l.src[l.pos] == ' ' or l.src[l.pos] == '\t' or l.src[l.pos] == '\r')) l.pos += 1;
        if (l.pos < l.src.len and l.src[l.pos] == '#') {
            while (l.pos < l.src.len and l.src[l.pos] != '\n') l.pos += 1;
        }
        if (l.pos >= l.src.len) return .eof;
        const c = l.src[l.pos];
        l.pos += 1;
        switch (c) {
            '\n' => return .newline,
            '(' => return .lparen,
            ')' => return .rparen,
            '{' => return .lbrace,
            '}' => return .rbrace,
            '[' => return .lbracket,
            ']' => return .rbracket,
            '|' => return .pipe,
            ';' => return .semi,
            ',' => return .comma,
            '?' => return .question,
            '>' => {
                if (l.peekByte() == '=') {
                    l.pos += 1;
                    return .{ .op = .ge };
                }
                return if (l.expr) .{ .op = .gt } else .redirect;
            },
            '<' => {
                if (l.peekByte() == '=') {
                    l.pos += 1;
                    return .{ .op = .le };
                }
                return .{ .op = .lt };
            },
            '=' => {
                if (l.peekByte() == '=') {
                    l.pos += 1;
                    return .{ .op = .eq };
                }
                if (l.peekByte() == '>') {
                    l.pos += 1;
                    return .arrow;
                }
                return .{ .op = .assign };
            },
            '!' => {
                if (l.peekByte() == '=') {
                    l.pos += 1;
                    return .{ .op = .ne };
                }
                return .{ .word = "!" };
            },
            '"' => {
                const start = l.pos;
                while (l.pos < l.src.len and l.src[l.pos] != '"') : (l.pos += 1) {
                    if (l.src[l.pos] == '\\' and l.pos + 1 < l.src.len) l.pos += 1;
                }
                const s = l.src[start..l.pos];
                if (l.pos < l.src.len) l.pos += 1;
                return .{ .string = s };
            },
            '$' => {
                const start = l.pos;
                while (l.pos < l.src.len and (std.ascii.isAlphanumeric(l.src[l.pos]) or l.src[l.pos] == '_')) l.pos += 1;
                return .{ .var_ = l.src[start..l.pos] };
            },
            else => {},
        }
        // A word, possibly a number with a size unit.
        const start = l.pos - 1;
        while (l.pos < l.src.len and isWordChar(l.src[l.pos])) l.pos += 1;
        // In expression context, a lone '.' after a word is field access;
        // words themselves may contain dots (paths, versions).
        const w = l.src[start..l.pos];
        if (w.len == 1 and w[0] == '-' and l.peekByte() == '>') {
            l.pos += 1;
            return .ret_arrow;
        }
        if (parseNumber(w)) |n| return .{ .number = n };
        if (l.expr and w.len > 1 and w[0] == '-') {
            if (parseNumber(w[1..])) |n| return .{ .number = switch (n) {
                .int => |i| .{ .int = -%i },
                .float => |f| .{ .float = -f },
                else => unreachable,
            } };
        }
        if (w.len == 1 and l.expr) switch (w[0]) {
            '+' => return .{ .op = .add },
            '-' => return .{ .op = .sub },
            '*' => return .{ .op = .mul },
            '/' => return .{ .op = .div },
            '%' => return .{ .op = .mod },
            else => {},
        };
        return .{ .word = w };
    }

    /// `42`, `4kb`; `1.5`, `2e3`, `1.5kb` (a fraction or an exponent
    /// makes a float). Anything else — `1.2.3`, `10.77.0.1` — is a word.
    fn parseNumber(w: []const u8) ?Value {
        if (w.len == 0 or !std.ascii.isDigit(w[0])) return null;
        var i: usize = 0;
        while (i < w.len and std.ascii.isDigit(w[i])) i += 1;
        var is_float = false;
        if (i + 1 < w.len and w[i] == '.' and std.ascii.isDigit(w[i + 1])) {
            is_float = true;
            i += 1;
            while (i < w.len and std.ascii.isDigit(w[i])) i += 1;
        }
        if (i < w.len and (w[i] == 'e' or w[i] == 'E')) {
            var j = i + 1;
            if (j < w.len and (w[j] == '+' or w[j] == '-')) j += 1;
            if (j < w.len and std.ascii.isDigit(w[j])) {
                is_float = true;
                i = j;
                while (i < w.len and std.ascii.isDigit(w[i])) i += 1;
            }
        }
        const unit = w[i..];
        const mult: i64 = if (unit.len == 0) 1 else if (std.ascii.eqlIgnoreCase(unit, "b")) 1 else if (std.ascii.eqlIgnoreCase(unit, "kb")) 1024 else if (std.ascii.eqlIgnoreCase(unit, "mb")) 1024 * 1024 else if (std.ascii.eqlIgnoreCase(unit, "gb")) 1024 * 1024 * 1024 else return null;
        if (is_float) {
            const f = std.fmt.parseFloat(f64, w[0..i]) catch return null;
            return .{ .float = f * @as(f64, @floatFromInt(mult)) };
        }
        const v = std.fmt.parseInt(i64, w[0..i], 10) catch return null;
        return .{ .int = std.math.mul(i64, v, mult) catch return null };
    }
};

// ------------------------------------------------------------------ AST

pub const Node = union(enum) {
    let: struct { name: []const u8, shape: ?Shape, expr: *Node },
    def: struct { name: []const u8, params: []const []const u8, param_shapes: []const ?Shape, ret: ?Shape, body: *Node, src: []const u8 },
    if_: struct { cond: *Node, then: *Node, else_: ?*Node },
    for_: struct { name: []const u8, iter: *Node, body: *Node },
    while_: struct { cond: *Node, body: *Node },
    block: []const *Node,
    pipeline: Pipeline,
    call: Call,
    callv: Callv,
    lit: Value,
    word: []const u8,
    var_: []const u8,
    interp: []const StrPart,
    field: struct { base: *Node, name: []const u8 },
    list: []const *Node,
    record: []const RecField,
    binop: BinOp,
    unop: struct { op: enum { not, neg }, operand: *Node },
    fn_: struct { params: []const []const u8, param_shapes: []const ?Shape, ret: ?Shape, body: *Node, implicit: bool, src: []const u8 },
    match_: Match,
    /// `shape S`: a shape as a value (its `$name`s resolved when evaluated).
    /// One term: a union is written `shape (a | b)`, since a `|` after
    /// it would otherwise be read as the union and never as the pipe.
    shape_lit: Shape,
    try_: *Node,
    unwrap: *Node,
};

const Pipeline = struct { stages: []const *Node, redirect: ?[]const u8 };
const RecField = struct { key: []const u8, value: *Node };
const Call = struct { name: []const u8, args: []const *Node };
const Callv = struct { callee: *Node, args: []const *Node };
const BinOp = struct { op: Op, lhs: *Node, rhs: *Node };
const StrPart = union(enum) { text: []const u8, var_: []const u8 };
const Match = struct { subject: *Node, shape: ?Shape, arms: []const Arm };
pub const Arm = struct { pat: Pattern, guard: ?*Node, body: *Node };
pub const Pattern = union(enum) {
    wild,
    bind: []const u8,
    lit: Value,
    ok: *const Pattern,
    err: *const Pattern,
    list: struct { items: []const Pattern, has_rest: bool, rest: ?[]const u8 },
    record: []const FieldPat,

    /// Matches every value (no guard considered).
    fn irrefutable(p: *const Pattern) bool {
        return p.* == .wild or p.* == .bind;
    }
};
const FieldPat = struct { key: []const u8, pat: ?Pattern };

// --------------------------------------------------------------- parser

const Parser = struct {
    it: *Interp,
    lex: Lexer,
    tok: Tok = .eof,
    peeked: bool = false,
    tok_start: usize = 0,
    /// The text between the braces of the block most recently parsed.
    last_block_src: []const u8 = "",

    fn a(p: *Parser) std.mem.Allocator {
        return p.it.arena;
    }

    fn take(p: *Parser) Tok {
        const t = p.peekAt();
        p.peeked = false;
        return t;
    }

    fn setExpr(p: *Parser, on: bool) void {
        // Re-lex the lookahead under the new mode, since '>' and '-'
        // depend on it.
        if (p.peeked and p.lex.expr != on) {
            p.lex.pos = p.tok_start;
            p.peeked = false;
        }
        p.lex.expr = on;
    }

    fn peekAt(p: *Parser) Tok {
        if (!p.peeked) {
            skipSpace(&p.lex);
            p.tok_start = p.lex.pos;
            p.tok = p.lex.next();
            p.peeked = true;
        }
        return p.tok;
    }

    /// Un-read the lookahead so the source is re-lexed from it.
    fn rewind(p: *Parser) void {
        p.lex.pos = p.tok_start;
        p.peeked = false;
    }

    fn skipSpace(l: *Lexer) void {
        while (l.pos < l.src.len and (l.src[l.pos] == ' ' or l.src[l.pos] == '\t' or l.src[l.pos] == '\r')) l.pos += 1;
    }

    fn syntax(p: *Parser, comptime fmt: []const u8, args: anytype) Error {
        p.it.err_msg = std.fmt.allocPrint(p.a(), fmt, args) catch "syntax error";
        return Error.Syntax;
    }

    fn mk(p: *Parser, n: Node) Error!*Node {
        const out = try p.a().create(Node);
        out.* = n;
        return out;
    }

    fn isWord(t: Tok, s: []const u8) bool {
        return t == .word and std.mem.eql(u8, t.word, s);
    }

    fn program(p: *Parser) Error![]const *Node {
        var stmts: std.ArrayList(*Node) = .empty;
        while (true) {
            const t = p.peekAt();
            switch (t) {
                .eof => break,
                .semi, .newline => {
                    _ = p.take();
                    continue;
                },
                .rbrace => break,
                else => try stmts.append(p.a(), try p.stmt()),
            }
        }
        return stmts.items;
    }

    fn block(p: *Parser) Error!*Node {
        p.setExpr(false);
        if (p.peekAt() != .lbrace) return p.syntax("'{{' expected", .{});
        _ = p.take();
        const start = p.lex.pos;
        const stmts = try p.program();
        if (p.peekAt() != .rbrace) return p.syntax("'}}' expected", .{});
        p.last_block_src = std.mem.trim(u8, p.lex.src[start..p.tok_start], " \t\r\n");
        _ = p.take();
        return p.mk(.{ .block = stmts });
    }

    /// `[a, b]`, or annotated: `[a: int, b: string | nothing]`, then an
    /// optional `-> shape` for what the function returns.
    const Params = struct { names: []const []const u8, shapes: []const ?Shape, ret: ?Shape };

    fn params(p: *Parser, what: []const u8) Error!Params {
        var names: std.ArrayList([]const u8) = .empty;
        var shapes: std.ArrayList(?Shape) = .empty;
        if (p.peekAt() == .lbracket) {
            _ = p.take();
            while (true) {
                p.setExpr(false);
                const q = p.take();
                switch (q) {
                    .rbracket => break,
                    .comma => continue,
                    .word => |w| {
                        if (w.len > 1 and w[w.len - 1] == ':') {
                            try names.append(p.a(), w[0 .. w.len - 1]);
                            try shapes.append(p.a(), try p.shapeUnion());
                        } else {
                            try names.append(p.a(), w);
                            try shapes.append(p.a(), null);
                        }
                    },
                    else => return p.syntax("{s}: parameter name expected", .{what}),
                }
            }
        }
        p.setExpr(false);
        var ret: ?Shape = null;
        if (p.peekAt() == .ret_arrow) {
            _ = p.take();
            ret = try p.shapeUnion();
        }
        return .{ .names = names.items, .shapes = shapes.items, .ret = ret };
    }

    fn stmt(p: *Parser) Error!*Node {
        p.setExpr(false);
        const t = p.peekAt();
        if (isWord(t, "let")) {
            _ = p.take();
            const name = p.take();
            if (name != .word) return p.syntax("let: name expected", .{});
            var nm = name.word;
            var shape: ?Shape = null;
            if (nm.len > 1 and nm[nm.len - 1] == ':') {
                nm = nm[0 .. nm.len - 1];
                shape = try p.shapeUnion();
            }
            p.setExpr(true);
            const eq = p.peekAt();
            if (eq != .op or eq.op != .assign) return p.syntax("let: '=' expected", .{});
            _ = p.take();
            const e = try p.expr();
            return p.mk(.{ .let = .{ .name = nm, .shape = shape, .expr = e } });
        }
        if (isWord(t, "def")) {
            _ = p.take();
            const name = p.take();
            if (name != .word) return p.syntax("def: name expected", .{});
            const ps = try p.params("def");
            const body = try p.block();
            return p.mk(.{ .def = .{ .name = name.word, .params = ps.names, .param_shapes = ps.shapes, .ret = ps.ret, .body = body, .src = p.last_block_src } });
        }
        if (isWord(t, "if")) return p.ifStmt();
        if (isWord(t, "for")) {
            _ = p.take();
            const name = p.take();
            if (name != .word) return p.syntax("for: name expected", .{});
            if (!isWord(p.peekAt(), "in")) return p.syntax("for: 'in' expected", .{});
            _ = p.take();
            p.setExpr(true);
            const iter = try p.expr();
            const body = try p.block();
            return p.mk(.{ .for_ = .{ .name = name.word, .iter = iter, .body = body } });
        }
        if (isWord(t, "while")) {
            _ = p.take();
            p.setExpr(true);
            const cond = try p.expr();
            const body = try p.block();
            return p.mk(.{ .while_ = .{ .cond = cond, .body = body } });
        }
        return p.pipeline();
    }

    fn ifStmt(p: *Parser) Error!*Node {
        _ = p.take(); // if
        p.setExpr(true);
        const cond = try p.expr();
        const then = try p.block();
        var else_: ?*Node = null;
        p.setExpr(false);
        if (isWord(p.peekAt(), "else")) {
            _ = p.take();
            else_ = if (isWord(p.peekAt(), "if")) try p.ifStmt() else try p.block();
        }
        return p.mk(.{ .if_ = .{ .cond = cond, .then = then, .else_ = else_ } });
    }

    fn pipeline(p: *Parser) Error!*Node {
        var stages: std.ArrayList(*Node) = .empty;
        var redirect: ?[]const u8 = null;
        while (true) {
            try stages.append(p.a(), try p.stage());
            p.setExpr(false);
            const t = p.peekAt();
            if (t == .pipe) {
                _ = p.take();
                continue;
            }
            if (t == .redirect) {
                _ = p.take();
                const w = p.take();
                if (w != .word) return p.syntax("'>' needs a path", .{});
                redirect = w.word;
            }
            break;
        }
        return p.mk(.{ .pipeline = .{ .stages = stages.items, .redirect = redirect } });
    }

    /// A pipeline stage: a command call, a call of a function value
    /// (`$f args`, `$m.f args`), or a bare expression.
    fn stage(p: *Parser) Error!*Node {
        p.setExpr(false);
        const t = p.peekAt();
        if (t == .word and !isKeywordStart(t.word) and !looksNumeric(t.word)) {
            _ = p.take();
            var args: std.ArrayList(*Node) = .empty;
            const is_where = std.mem.eql(u8, t.word, "where");
            if (is_where) {
                p.setExpr(true);
                try args.append(p.a(), try p.expr());
            } else {
                try p.argList(&args);
            }
            const call = try p.mk(.{ .call = .{ .name = t.word, .args = args.items } });
            return p.trailingUnwrap(call);
        }
        if (t == .var_) {
            const start = p.tok_start;
            p.setExpr(true);
            const callee = try p.postfix();
            p.setExpr(false);
            if (callee.* != .unwrap and argStart(p.peekAt())) {
                var args: std.ArrayList(*Node) = .empty;
                try p.argList(&args);
                const call = try p.mk(.{ .callv = .{ .callee = callee, .args = args.items } });
                return p.trailingUnwrap(call);
            }
            // A stage that is just `$f` or `$m.f`: a function value there
            // is called with the pipeline's input (the only way to call a
            // function of no parameters); anything else is the value.
            if ((callee.* == .var_ or callee.* == .field) and stageEnd(p.peekAt())) {
                return p.mk(.{ .callv = .{ .callee = callee, .args = &.{} } });
            }
            // Not a call: an expression that happens to start with $var.
            p.lex.pos = start;
            p.peeked = false;
        }
        p.setExpr(true);
        return p.expr();
    }

    fn argList(p: *Parser, out: *std.ArrayList(*Node)) Error!void {
        while (true) {
            p.setExpr(false);
            const n = p.peekAt();
            switch (n) {
                .eof, .pipe, .semi, .newline, .rparen, .rbrace, .redirect, .question => break,
                else => try out.append(p.a(), try p.arg()),
            }
        }
    }

    /// A trailing `?` unwraps the stage's result.
    fn trailingUnwrap(p: *Parser, n: *Node) Error!*Node {
        p.setExpr(false);
        if (p.peekAt() == .question) {
            _ = p.take();
            return p.mk(.{ .unwrap = n });
        }
        return n;
    }

    /// Does this token end a stage? (`>` is not one here: after a bare
    /// `$x` it is a comparison, read in expression mode.)
    fn stageEnd(t: Tok) bool {
        return switch (t) {
            .eof, .pipe, .semi, .newline, .rparen, .rbrace => true,
            else => false,
        };
    }

    /// In command context: can this token begin an argument (as opposed
    /// to continuing an expression)?
    fn argStart(t: Tok) bool {
        return switch (t) {
            .word => |w| !(w.len == 1 and (w[0] == '+' or w[0] == '-' or w[0] == '*' or w[0] == '/' or w[0] == '%')) and
                !std.mem.eql(u8, w, "and") and !std.mem.eql(u8, w, "or"),
            .string, .number, .var_, .lparen, .lbracket, .lbrace => true,
            else => false,
        };
    }

    fn looksNumeric(w: []const u8) bool {
        if (w.len == 0) return false;
        if (std.ascii.isDigit(w[0])) return true;
        return w.len > 1 and w[0] == '-' and std.ascii.isDigit(w[1]);
    }

    fn isKeywordStart(w: []const u8) bool {
        for ([_][]const u8{ "true", "false", "null", "not", "fn", "match", "try", "shape" }) |kw| {
            if (std.mem.eql(u8, w, kw)) return true;
        }
        return false;
    }

    /// A command argument (command context: '>' is not an operator, '-x'
    /// is a flag word). A block is a function of `$it`.
    fn arg(p: *Parser) Error!*Node {
        const t = p.peekAt();
        switch (t) {
            .word => |w| {
                _ = p.take();
                if (std.mem.eql(u8, w, "true")) return p.mk(.{ .lit = .{ .bool = true } });
                if (std.mem.eql(u8, w, "false")) return p.mk(.{ .lit = .{ .bool = false } });
                if (std.mem.eql(u8, w, "null")) return p.mk(.{ .lit = .nothing });
                if (std.mem.eql(u8, w, "shape")) return p.mk(.{ .shape_lit = try p.shapeTerm() });
                return p.mk(.{ .lit = .{ .str = w } });
            },
            .number => |n| {
                _ = p.take();
                return p.mk(.{ .lit = n });
            },
            .string => |s| {
                _ = p.take();
                return p.stringNode(s);
            },
            .var_ => {
                p.setExpr(true);
                return p.postfix();
            },
            .lparen => {
                p.setExpr(true);
                return p.postfix();
            },
            .lbracket => {
                p.setExpr(true);
                return p.primary();
            },
            .lbrace => {
                _ = p.take();
                if (p.recordAhead()) return p.recordLit();
                p.rewind();
                const body = try p.block();
                return p.mk(.{ .fn_ = .{ .params = &.{}, .param_shapes = &.{}, .ret = null, .body = body, .implicit = true, .src = p.last_block_src } });
            },
            else => return p.syntax("unexpected token in arguments", .{}),
        }
    }

    // Shapes.

    /// `S | S | …`
    fn shapeUnion(p: *Parser) Error!Shape {
        var alts: std.ArrayList(Shape) = .empty;
        try alts.append(p.a(), try p.shapeTerm());
        while (p.peekAt() == .pipe) {
            _ = p.take();
            try alts.append(p.a(), try p.shapeTerm());
        }
        if (alts.items.len == 1) return alts.items[0];
        return .{ .one_of = alts.items };
    }

    const shape_names = [_]struct { name: []const u8, shape: Shape }{
        .{ .name = "any", .shape = .any },       .{ .name = "nothing", .shape = .nothing }, .{ .name = "null", .shape = .nothing },
        .{ .name = "bool", .shape = .bool },     .{ .name = "int", .shape = .int },         .{ .name = "float", .shape = .float },
        .{ .name = "string", .shape = .string }, .{ .name = "bytes", .shape = .bytes },     .{ .name = "list", .shape = .list },
        .{ .name = "record", .shape = .record }, .{ .name = "table", .shape = .table },     .{ .name = "function", .shape = .function },
        .{ .name = "result", .shape = .result }, .{ .name = "shape", .shape = .shape },
    };

    fn isShapeKeyword(w: []const u8) bool {
        for (shape_names) |sn| if (std.mem.eql(u8, w, sn.name)) return true;
        return std.mem.eql(u8, w, "ok") or std.mem.eql(u8, w, "err") or std.mem.eql(u8, w, "handle");
    }

    /// One shape: a type name, `handle [kind]`, `ok S` / `err S`, a bare
    /// or quoted word (an enumeration's member), `$name`, `[S]`,
    /// `{ key: S, … }`, or `(S | S)`.
    fn shapeTerm(p: *Parser) Error!Shape {
        p.setExpr(true);
        const t = p.take();
        switch (t) {
            .word => |w| {
                for (shape_names) |sn| {
                    if (std.mem.eql(u8, w, sn.name)) return sn.shape;
                }
                if (std.mem.eql(u8, w, "ok") or std.mem.eql(u8, w, "err")) {
                    const inner = try p.a().create(Shape);
                    inner.* = try p.shapeTerm();
                    return if (w[0] == 'o') .{ .ok = inner } else .{ .err = inner };
                }
                if (std.mem.eql(u8, w, "handle")) {
                    const n = p.peekAt();
                    if (n == .word and !std.mem.eql(u8, n.word, "ok") and !std.mem.eql(u8, n.word, "err")) {
                        for (shape_names) |sn| if (std.mem.eql(u8, n.word, sn.name)) return .handle;
                        _ = p.take();
                        return .{ .kind = n.word };
                    }
                    return .handle;
                }
                return .{ .word = w };
            },
            .string => |s| {
                const n = try p.stringNode(s);
                if (n.* != .lit or n.lit != .str) return p.syntax("shape: a plain string expected", .{});
                return .{ .word = n.lit.str };
            },
            .var_ => |name| return .{ .ref = name },
            .lbracket => {
                const inner = try p.a().create(Shape);
                inner.* = try p.shapeUnion();
                if (p.take() != .rbracket) return p.syntax("shape: ']' expected", .{});
                return .{ .list_of = inner };
            },
            .lparen => {
                const inner = try p.shapeUnion();
                if (p.take() != .rparen) return p.syntax("shape: ')' expected", .{});
                return inner;
            },
            .lbrace => {
                var fields: std.ArrayList(Shape.Field) = .empty;
                while (true) {
                    p.setExpr(true);
                    const n = p.peekAt();
                    switch (n) {
                        .rbrace => {
                            _ = p.take();
                            break;
                        },
                        .comma, .newline, .semi => {
                            _ = p.take();
                            continue;
                        },
                        .word => |w| {
                            _ = p.take();
                            if (w.len < 2 or w[w.len - 1] != ':') return p.syntax("shape: 'key:' expected, got '{s}'", .{w});
                            try fields.append(p.a(), .{ .key = w[0 .. w.len - 1], .shape = try p.shapeUnion() });
                        },
                        .eof => return p.syntax("shape: '}}' expected", .{}),
                        else => return p.syntax("shape: 'key:' expected", .{}),
                    }
                }
                return .{ .record_of = fields.items };
            },
            else => return p.syntax("shape expected", .{}),
        }
    }

    fn stringNode(p: *Parser, raw: []const u8) Error!*Node {
        var parts: std.ArrayList(StrPart) = .empty;
        var text: std.ArrayList(u8) = .empty;
        var i: usize = 0;
        var plain = true;
        while (i < raw.len) : (i += 1) {
            const c = raw[i];
            if (c == '\\' and i + 1 < raw.len) {
                i += 1;
                try text.append(p.a(), switch (raw[i]) {
                    'n' => '\n',
                    't' => '\t',
                    'r' => '\r',
                    else => raw[i],
                });
                continue;
            }
            if (c == '$' and i + 1 < raw.len and (std.ascii.isAlphabetic(raw[i + 1]) or raw[i + 1] == '_')) {
                plain = false;
                if (text.items.len > 0) {
                    if (!std.unicode.utf8ValidateSlice(text.items)) return p.syntax("string is not valid UTF-8", .{});
                    try parts.append(p.a(), .{ .text = try p.a().dupe(u8, text.items) });
                    text.clearRetainingCapacity();
                }
                var j = i + 1;
                while (j < raw.len and (std.ascii.isAlphanumeric(raw[j]) or raw[j] == '_')) j += 1;
                try parts.append(p.a(), .{ .var_ = raw[i + 1 .. j] });
                i = j - 1;
                continue;
            }
            try text.append(p.a(), c);
        }
        if (!std.unicode.utf8ValidateSlice(text.items)) return p.syntax("string is not valid UTF-8", .{});
        if (plain) return p.mk(.{ .lit = .{ .str = text.items } });
        if (text.items.len > 0) try parts.append(p.a(), .{ .text = text.items });
        return p.mk(.{ .interp = parts.items });
    }

    // Expressions (expression context: operators live).

    fn expr(p: *Parser) Error!*Node {
        p.setExpr(true);
        return p.orExpr();
    }

    fn orExpr(p: *Parser) Error!*Node {
        var lhs = try p.andExpr();
        while (isWord(p.peekAt(), "or")) {
            _ = p.take();
            const rhs = try p.andExpr();
            lhs = try p.mk(.{ .binop = .{ .op = .@"or", .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn andExpr(p: *Parser) Error!*Node {
        var lhs = try p.notExpr();
        while (isWord(p.peekAt(), "and")) {
            _ = p.take();
            const rhs = try p.notExpr();
            lhs = try p.mk(.{ .binop = .{ .op = .@"and", .lhs = lhs, .rhs = rhs } });
        }
        return lhs;
    }

    fn notExpr(p: *Parser) Error!*Node {
        if (isWord(p.peekAt(), "not")) {
            _ = p.take();
            const operand = try p.notExpr();
            return p.mk(.{ .unop = .{ .op = .not, .operand = operand } });
        }
        return p.cmpExpr();
    }

    fn cmpExpr(p: *Parser) Error!*Node {
        const lhs = try p.addExpr();
        const t = p.peekAt();
        if (t == .op) switch (t.op) {
            .eq, .ne, .lt, .le, .gt, .ge => {
                _ = p.take();
                const rhs = try p.addExpr();
                return p.mk(.{ .binop = .{ .op = t.op, .lhs = lhs, .rhs = rhs } });
            },
            else => {},
        };
        return lhs;
    }

    fn addExpr(p: *Parser) Error!*Node {
        var lhs = try p.mulExpr();
        while (true) {
            const t = p.peekAt();
            if (t == .op and (t.op == .add or t.op == .sub)) {
                _ = p.take();
                const rhs = try p.mulExpr();
                lhs = try p.mk(.{ .binop = .{ .op = t.op, .lhs = lhs, .rhs = rhs } });
            } else break;
        }
        return lhs;
    }

    fn mulExpr(p: *Parser) Error!*Node {
        var lhs = try p.unary();
        while (true) {
            const t = p.peekAt();
            if (t == .op and (t.op == .mul or t.op == .div or t.op == .mod)) {
                _ = p.take();
                const rhs = try p.unary();
                lhs = try p.mk(.{ .binop = .{ .op = t.op, .lhs = lhs, .rhs = rhs } });
            } else break;
        }
        return lhs;
    }

    fn unary(p: *Parser) Error!*Node {
        const t = p.peekAt();
        if (t == .op and t.op == .sub) {
            _ = p.take();
            const operand = try p.unary();
            return p.mk(.{ .unop = .{ .op = .neg, .operand = operand } });
        }
        return p.postfix();
    }

    /// Field access binds tighter than lexing: a '.' glued to the end of
    /// a primary (no space) is `.field`, read straight from the source,
    /// so bare words may still contain dots (hi.txt, 10.77.0.1). A `?`
    /// glued after that unwraps.
    fn postfix(p: *Parser) Error!*Node {
        var base = try p.primary();
        while (!p.peeked and p.lex.pos < p.lex.src.len) {
            const ch = p.lex.src[p.lex.pos];
            if (ch == '.') {
                p.lex.pos += 1;
                const start = p.lex.pos;
                while (p.lex.pos < p.lex.src.len and (std.ascii.isAlphanumeric(p.lex.src[p.lex.pos]) or p.lex.src[p.lex.pos] == '_' or p.lex.src[p.lex.pos] == '-')) p.lex.pos += 1;
                if (p.lex.pos == start) return p.syntax("field name expected after '.'", .{});
                base = try p.mk(.{ .field = .{ .base = base, .name = p.lex.src[start..p.lex.pos] } });
            } else if (ch == '?') {
                p.lex.pos += 1;
                base = try p.mk(.{ .unwrap = base });
            } else break;
        }
        return base;
    }

    fn primary(p: *Parser) Error!*Node {
        const t = p.take();
        switch (t) {
            .number => |n| return p.mk(.{ .lit = n }),
            .string => |s| return p.stringNode(s),
            .var_ => |name| return p.mk(.{ .var_ = name }),
            .word => |w| {
                if (std.mem.eql(u8, w, "true")) return p.mk(.{ .lit = .{ .bool = true } });
                if (std.mem.eql(u8, w, "false")) return p.mk(.{ .lit = .{ .bool = false } });
                if (std.mem.eql(u8, w, "null")) return p.mk(.{ .lit = .nothing });
                if (std.mem.eql(u8, w, "fn")) {
                    const ps = try p.params("fn");
                    const body = try p.block();
                    return p.mk(.{ .fn_ = .{ .params = ps.names, .param_shapes = ps.shapes, .ret = ps.ret, .body = body, .implicit = false, .src = p.last_block_src } });
                }
                if (std.mem.eql(u8, w, "shape")) return p.mk(.{ .shape_lit = try p.shapeTerm() });
                if (std.mem.eql(u8, w, "match")) return p.matchExpr();
                if (std.mem.eql(u8, w, "try")) {
                    p.setExpr(false);
                    const inner = if (p.peekAt() == .lbrace) try p.block() else blk: {
                        p.setExpr(true);
                        break :blk try p.postfix();
                    };
                    return p.mk(.{ .try_ = inner });
                }
                return p.mk(.{ .word = w });
            },
            .lparen => {
                const inner = try p.pipeline();
                p.setExpr(true);
                if (p.peekAt() != .rparen) return p.syntax("')' expected", .{});
                _ = p.take();
                return inner;
            },
            .lbracket => {
                var items: std.ArrayList(*Node) = .empty;
                while (true) {
                    p.setExpr(true);
                    const n = p.peekAt();
                    if (n == .rbracket) {
                        _ = p.take();
                        break;
                    }
                    if (n == .comma or n == .newline) {
                        _ = p.take();
                        continue;
                    }
                    if (n == .eof) return p.syntax("']' expected", .{});
                    try items.append(p.a(), try p.expr());
                }
                return p.mk(.{ .list = items.items });
            },
            .lbrace => {
                // `{ word: ...` is a record literal; anything else a block.
                if (p.recordAhead()) return p.recordLit();
                p.rewind();
                return p.block();
            },
            else => return p.syntax("expression expected", .{}),
        }
    }

    /// After a consumed '{': does a `word:` follow (past newlines)?
    fn recordAhead(p: *Parser) bool {
        var i = p.lex.pos;
        const src = p.lex.src;
        while (i < src.len and (src[i] == ' ' or src[i] == '\t' or src[i] == '\r' or src[i] == '\n')) i += 1;
        if (i >= src.len) return false;
        if (src[i] == '}') return false;
        while (i < src.len and Lexer.isWordChar(src[i]) and src[i] != ':') i += 1;
        return i < src.len and src[i] == ':';
    }

    fn recordLit(p: *Parser) Error!*Node {
        var fields: std.ArrayList(RecField) = .empty;
        while (true) {
            p.setExpr(true);
            const t = p.peekAt();
            switch (t) {
                .rbrace => {
                    _ = p.take();
                    break;
                },
                .comma, .newline, .semi => {
                    _ = p.take();
                    continue;
                },
                .word => |w| {
                    _ = p.take();
                    if (w.len < 2 or w[w.len - 1] != ':') return p.syntax("record: 'key:' expected, got '{s}'", .{w});
                    const key = w[0 .. w.len - 1];
                    const value = try p.expr();
                    try fields.append(p.a(), .{ .key = key, .value = value });
                },
                .eof => return p.syntax("'}}' expected", .{}),
                else => return p.syntax("record: 'key:' expected", .{}),
            }
        }
        return p.mk(.{ .record = fields.items });
    }

    // Pattern matching.

    /// `match expr { arm* }`, checked here for exhaustiveness: a
    /// catch-all arm, both `ok` and `err` with irrefutable insides, or
    /// both `true` and `false` — else a syntax error, not a runtime one.
    fn matchExpr(p: *Parser) Error!*Node {
        p.setExpr(true);
        const subject = try p.expr();
        // `match v: shape { … }`: the arms must cover the shape, which is
        // checked where the match runs (the shape may be a `$name`).
        var shape: ?Shape = null;
        if (subject.* == .word and subject.word.len > 1 and subject.word[subject.word.len - 1] == ':') {
            // A bare word keeps its colon as one token (`dir:`, `5:`):
            // split it, and read what is left as the lexer would have.
            const w = subject.word[0 .. subject.word.len - 1];
            subject.* = if (Lexer.parseNumber(w)) |n| .{ .lit = n } else if (std.mem.eql(u8, w, "true")) .{ .lit = .{ .bool = true } } else if (std.mem.eql(u8, w, "false")) .{ .lit = .{ .bool = false } } else if (std.mem.eql(u8, w, "null")) .{ .lit = .nothing } else .{ .word = w };
            shape = try p.shapeUnion();
        } else if (isWord(p.peekAt(), ":")) {
            _ = p.take();
            shape = try p.shapeUnion();
        }
        p.setExpr(false);
        if (p.peekAt() != .lbrace) return p.syntax("match: '{{' expected", .{});
        _ = p.take();
        var arms: std.ArrayList(Arm) = .empty;
        var catch_all = false;
        var ok_all = false;
        var err_all = false;
        var true_lit = false;
        var false_lit = false;
        while (true) {
            p.setExpr(true);
            const t = p.peekAt();
            if (t == .rbrace) {
                _ = p.take();
                break;
            }
            if (t == .newline or t == .semi or t == .comma) {
                _ = p.take();
                continue;
            }
            if (t == .eof) return p.syntax("match: '}}' expected", .{});
            const pat = try p.pattern();
            var guard: ?*Node = null;
            p.setExpr(true);
            if (isWord(p.peekAt(), "if")) {
                _ = p.take();
                guard = try p.expr();
            }
            p.setExpr(true);
            if (p.peekAt() != .arrow) return p.syntax("match: '=>' expected after the pattern", .{});
            _ = p.take();
            const body = try p.armBody();
            if (guard == null) {
                if (pat.irrefutable()) catch_all = true;
                if (pat == .ok and pat.ok.irrefutable()) ok_all = true;
                if (pat == .err and pat.err.irrefutable()) err_all = true;
                if (pat == .lit and pat.lit == .bool) {
                    if (pat.lit.bool) true_lit = true else false_lit = true;
                }
            }
            try arms.append(p.a(), .{ .pat = pat, .guard = guard, .body = body });
        }
        if (arms.items.len == 0) return p.syntax("match: no arms", .{});
        if (shape == null and !catch_all and !(ok_all and err_all) and !(true_lit and false_lit)) {
            if (ok_all) return p.syntax("match: not exhaustive — no `err _ =>` arm", .{});
            if (err_all) return p.syntax("match: not exhaustive — no `ok _ =>` arm", .{});
            return p.syntax("match: not exhaustive — add a `_ =>` arm", .{});
        }
        return p.mk(.{ .match_ = .{ .subject = subject, .shape = shape, .arms = arms.items } });
    }

    /// An arm's body: a block, or one statement on the same line (an
    /// `if`, a `let`, a pipeline …).
    fn armBody(p: *Parser) Error!*Node {
        p.setExpr(false);
        if (p.peekAt() == .lbrace) {
            _ = p.take();
            const is_record = p.recordAhead();
            p.rewind();
            if (!is_record) return p.block();
        }
        return p.stmt();
    }

    fn pattern(p: *Parser) Error!Pattern {
        p.setExpr(true);
        const t = p.take();
        switch (t) {
            .word => |w| {
                if (std.mem.eql(u8, w, "_")) return .wild;
                if (std.mem.eql(u8, w, "true")) return .{ .lit = .{ .bool = true } };
                if (std.mem.eql(u8, w, "false")) return .{ .lit = .{ .bool = false } };
                if (std.mem.eql(u8, w, "null")) return .{ .lit = .nothing };
                if (std.mem.eql(u8, w, "ok") or std.mem.eql(u8, w, "err")) {
                    const inner = try p.a().create(Pattern);
                    inner.* = try p.pattern();
                    return if (w[0] == 'o') .{ .ok = inner } else .{ .err = inner };
                }
                return .{ .lit = .{ .str = w } };
            },
            .var_ => |name| return .{ .bind = name },
            .number => |n| return .{ .lit = n },
            .string => |s| {
                const n = try p.stringNode(s);
                if (n.* != .lit) return p.syntax("pattern: a plain string expected", .{});
                return .{ .lit = n.lit };
            },
            .lbracket => {
                var items: std.ArrayList(Pattern) = .empty;
                var has_rest = false;
                var rest: ?[]const u8 = null;
                while (true) {
                    p.setExpr(true);
                    const n = p.peekAt();
                    if (n == .rbracket) {
                        _ = p.take();
                        break;
                    }
                    if (n == .comma or n == .newline) {
                        _ = p.take();
                        continue;
                    }
                    if (n == .eof) return p.syntax("pattern: ']' expected", .{});
                    if (has_rest) return p.syntax("pattern: '..' must be last", .{});
                    if (isWord(n, "..")) {
                        _ = p.take();
                        has_rest = true;
                        if (p.peekAt() == .var_) rest = p.take().var_;
                        continue;
                    }
                    try items.append(p.a(), try p.pattern());
                }
                return .{ .list = .{ .items = items.items, .has_rest = has_rest, .rest = rest } };
            },
            .lbrace => {
                var fields: std.ArrayList(FieldPat) = .empty;
                while (true) {
                    p.setExpr(true);
                    const n = p.peekAt();
                    switch (n) {
                        .rbrace => {
                            _ = p.take();
                            break;
                        },
                        .comma, .newline => {
                            _ = p.take();
                            continue;
                        },
                        .word => |w| {
                            _ = p.take();
                            if (w.len > 1 and w[w.len - 1] == ':') {
                                try fields.append(p.a(), .{ .key = w[0 .. w.len - 1], .pat = try p.pattern() });
                            } else try fields.append(p.a(), .{ .key = w, .pat = null });
                        },
                        else => return p.syntax("pattern: 'key:' or a field name expected", .{}),
                    }
                }
                return .{ .record = fields.items };
            },
            else => return p.syntax("pattern expected", .{}),
        }
    }
};

// ------------------------------------------------------------------ tests

const TestHost = struct {
    saved_path: []const u8 = "",
    saved_text: []const u8 = "",
    closed: usize = 0,
    dropped: usize = 0,
    last_dropped: u64 = 0,

    fn call(ctx: *anyopaque, it: *Interp, name: []const u8, args: []const Value, input: ?Value) Error!?Value {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        _ = input;
        if (std.mem.eql(u8, name, "ls")) {
            const cols = [_][]const u8{ "name", "type", "size" };
            const rows = [_][]const Value{
                &.{ .{ .str = "hi.txt" }, .{ .str = "file" }, .{ .int = 27 } },
                &.{ .{ .str = "big.bin" }, .{ .str = "file" }, .{ .int = 8192 } },
                &.{ .{ .str = "sub" }, .{ .str = "dir" }, .{ .int = 0 } },
            };
            return .{ .table = .{ .cols = try it.arena.dupe([]const u8, &cols), .rows = try it.arena.dupe([]const Value, &rows) } };
        }
        if (std.mem.eql(u8, name, "stat")) {
            const keys = [_][]const u8{ "type", "size" };
            const vals = [_]Value{ .{ .str = "dir" }, .{ .int = 0 } };
            return .{ .record = .{ .keys = try it.arena.dupe([]const u8, &keys), .vals = try it.arena.dupe(Value, &vals) } };
        }
        if (std.mem.eql(u8, name, "save")) {
            self.saved_path = try std.testing.allocator.dupe(u8, args[0].str);
            self.saved_text = try std.testing.allocator.dupe(u8, args[1].str);
            return .nothing;
        }
        if (std.mem.eql(u8, name, "open")) {
            // The world decides: a result, with the protocol's word.
            const path = args[0].str;
            if (std.mem.eql(u8, path, "lib/math.msh")) return try it.mkResult(true, .{ .str = math_module });
            if (std.mem.eql(u8, path, "lib/self.msh")) return try it.mkResult(true, .{ .str = "let me = (use lib/self.msh)" });
            if (std.mem.eql(u8, path, "lib/bad.msh")) return try it.mkResult(true, .{ .str = "def f { 1 }; frobnicate" });
            return try it.mkResult(false, .{ .str = "not_found" });
        }
        // `module NAME`: a bare name is looked up in the store; a path
        // is the host's `open`.
        if (std.mem.eql(u8, name, "module")) {
            const mname = args[0].str;
            if (std.mem.indexOfScalar(u8, mname, '/') != null) return null;
            if (std.mem.eql(u8, mname, "math")) return try it.mkResult(true, .{ .str = math_module });
            // The real library, as the archive ships it.
            if (std.mem.eql(u8, mname, "std-math")) return try it.mkResult(true, .{ .str = @embedFile("msh/math.msh") });
            return try it.mkResult(false, .{ .str = "not_found" });
        }
        if (std.mem.eql(u8, name, "fails")) return it.fail("fails: as asked", .{});
        if (std.mem.eql(u8, name, "lies")) return .{ .int = 1 };
        // Handles: `open-sock N` makes one; `close-sock $h` closes it;
        // dropped handles count in `dropped`.
        if (std.mem.eql(u8, name, "open-sock")) return try it.newHandle("socket", @intCast(args[0].int), ctx, dropSock);
        if (std.mem.eql(u8, name, "close-sock")) {
            it.closeHandle(args[0]);
            self.closed += 1;
            return .nothing;
        }
        return null;
    }

    fn dropSock(ctx: *anyopaque, kind: []const u8, id: u64) void {
        const self: *TestHost = @ptrCast(@alignCast(ctx));
        std.debug.assert(std.mem.eql(u8, kind, "socket"));
        self.dropped += 1;
        self.last_dropped = id;
    }

    const math_module =
        \\# a module: its bindings are its exports
        \\let version = 2
        \\def double [x] { $x * 2 }
        \\def quad [x] { double (double $x) }
        \\def fact [n] { if $n < 2 { 1 } else { $n * (fact ($n - 1)) } }
    ;

    /// What `ls` answers, as the host would declare it from its protocol
    /// types: the shape and the value come from one definition.
    const Entry = struct { name: []const u8, type: enum { file, dir }, size: i64 };
    const Stat = struct { type: enum { file, dir }, size: i64 };

    // Shapes are built once, at compile time (shapeOf and resultShape
    // run only there).
    const stat_shape = shapeOf(Stat);
    const ls_shape = shapeOf([]const Entry);
    const open_shape = resultShape(.string, .{ .word = "not_found" });

    fn signature(_: *anyopaque, name: []const u8) ?Signature {
        const path = Param{ .name = "path", .shape = .string };
        if (std.mem.eql(u8, name, "stat")) return .{ .params = &.{path}, .ret = stat_shape };
        if (std.mem.eql(u8, name, "ls")) return .{ .params = &.{.{ .name = "path", .shape = .string, .optional = true }}, .ret = ls_shape };
        if (std.mem.eql(u8, name, "open")) return .{ .params = &.{path}, .ret = open_shape };
        if (std.mem.eql(u8, name, "save")) return .{ .params = &.{ path, .{ .name = "text", .optional = true } }, .input = .{ .optional = .any }, .ret = .nothing };
        if (std.mem.eql(u8, name, "lies")) return .{ .ret = .string };
        return null;
    }
};

const TestState = struct {
    arena_state: std.heap.ArenaAllocator,
    host: TestHost = .{},
    it: Interp = undefined,

    fn start(self: *TestState) void {
        self.host = .{};
        self.arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
        self.it = Interp.init(self.arena_state.allocator(), std.testing.allocator, .{ .ctx = &self.host, .call = TestHost.call, .signature = TestHost.signature });
    }

    fn stop(self: *TestState) void {
        self.it.deinit();
        self.arena_state.deinit();
    }
};

fn expectOut(it: *Interp, src: []const u8, expected: []const u8) !void {
    _ = it.run(src) catch |e| {
        std.debug.print("error {t}: {s}\n", .{ e, it.err_msg });
        return e;
    };
    try std.testing.expectEqualStrings(expected, it.out.items);
}

fn expectRuntime(it: *Interp, src: []const u8, msg: []const u8) !void {
    try std.testing.expectError(Error.Runtime, it.run(src));
    try std.testing.expectEqualStrings(msg, it.err_msg);
}

test "arithmetic, comparison, logic, units" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "1 + 2 * 3", "7\n");
    try expectOut(it, "(1 + 2) * 3", "9\n");
    try expectOut(it, "10 / 3", "3\n");
    try expectOut(it, "4kb", "4096\n");
    try expectOut(it, "3 > 2 and not false", "true\n");
    try expectOut(it, "1 == 1 or 1 == 2", "true\n");
    try expectOut(it, "\"a\" + \"b\"", "ab\n");
    try expectOut(it, "-5 + 2", "-3\n");
    try expectOut(it, "[1, 2] == [1, 2]", "true\n");
    try expectOut(it, "{ a: 1 } == { a: 1 }", "true\n");
}

test "let, if, for, while, interpolation" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "let x = 3; $x * 2", "6\n");
    try expectOut(it, "if $x == 3 { echo yes } else { echo no }", "yes\n");
    try expectOut(it, "if $x == 4 { echo yes } else if $x == 3 { echo three } else { echo no }", "three\n");
    try expectOut(it, "let n = 0; while $n < 3 { let n = $n + 1 }; $n", "3\n");
    try expectOut(it, "for i in [1, 2, 3] { echo \"i=$i\" }", "i=3\n");
    try expectOut(it, "let name = \"moss\"; echo \"hello $name!\"", "hello moss!\n");
    // The loop variable outlives the loop, boxed once at the end.
    try expectOut(it, "for r in [{ a: 1 }, { a: 2 }] { $r.a }; $r.a", "2\n");
    // Rebinding the list a loop walks is safe: the old box waits for the
    // statement to end.
    try expectOut(it, "let l = [10, 20, 30]; for v in $l { let l = [$v] }; $l", "30\n");
}

test "pipelines over tables: where, sort-by, select, get, first, len" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "ls | len", "3\n");
    try expectOut(it, "ls | where size > 1kb | get name", "big.bin\n");
    try expectOut(it, "ls | where type == dir | select name", "name\n----\nsub\n");
    try expectOut(it, "ls | sort-by size --desc | first 1 | get name", "big.bin\n");
    try expectOut(it, "ls | sort-by name | get name", "big.bin\nhi.txt\nsub\n");
    try expectOut(it, "(ls | where name == \"hi.txt\").0.size", "27\n");
    try expectOut(it, "(stat data).type == dir", "true\n");
    try expectOut(it, "ls | reverse | first 1 | get type", "dir\n");
    try expectOut(it, "ls | keys", "name\ntype\nsize\n");
    try expectOut(it, "\"a\\nb\" | lines | len", "2\n");
    try expectOut(it, "[3, 1, 2] | where $it > 1 | len", "2\n");
    try expectOut(it, "ls | select name size", "name     size\n-------  ----\nhi.txt   27\nbig.bin  8192\nsub      0\n");
    try expectOut(it, "ls | where $it.size == 0 | get name", "sub\n");
}

test "redirection renders and saves through the host" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    defer std.testing.allocator.free(t.host.saved_path);
    defer std.testing.allocator.free(t.host.saved_text);
    const it = &t.it;
    try expectOut(it, "ls | get name > data/list.txt", "");
    try std.testing.expectEqualStrings("data/list.txt", t.host.saved_path);
    try std.testing.expectEqualStrings("hi.txt\nbig.bin\nsub\n", t.host.saved_text);
}

test "errors carry messages" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectRuntime(it, "frobnicate 1", "unknown command 'frobnicate'");
    try std.testing.expectError(Error.Syntax, it.run("if true { echo x"));
    try expectRuntime(it, "1 / 0", "division by zero");
    try expectRuntime(it, "$nope", "unknown variable $nope");
}

test "strong typing: nothing coerces" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectRuntime(it, "if 1 { echo x }", "if: condition is a int, not a bool");
    try expectRuntime(it, "if \"yes\" { echo x }", "if: condition is a string, not a bool");
    try expectRuntime(it, "1 == \"1\"", "cannot compare a int with a string");
    try expectRuntime(it, "1 < \"2\"", "cannot order a int against a string");
    try expectRuntime(it, "true and 1", "and: condition is a int, not a bool");
    try expectRuntime(it, "1 + \"a\"", "cannot add a int and a string");
    try expectRuntime(it, "[1] | where $it", "where: condition is a int, not a bool");
    try expectRuntime(it, "ls | first \"2\"", "first: an int expected, got a string");
    // nothing compares with anything (absence is a question worth asking).
    try expectOut(it, "null == 1", "false\n");
    try expectOut(it, "let x = null; $x == null", "true\n");
    // Explicit conversions are commands with typed results.
    try expectOut(it, "str 42", "42\n");
    try expectOut(it, "(int \"42\")? + 1", "43\n");
    try expectOut(it, "int nope", "err not a number: nope\n");
    try expectOut(it, "type 1; type \"s\"; type [1]; type (fn { 1 }); type (ok 1)", "result\n");
    try expectOut(it, "[(type 1), (type \"s\"), (type null), (type (ok 1))]", "int\nstring\nnothing\nresult\n");
}

test "strings are UTF-8, bytes are bytes" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "\"héllo\" | len", "5\n");
    try expectOut(it, "\"héllo\" | to-bytes | len", "6\n");
    try expectOut(it, "\"héllo\" | to-bytes | from-bytes", "héllo\n");
    try expectOut(it, "\"héllo\" | to-bytes | from-bytes | type", "result\n");
    try expectOut(it, "(\"a\" | to-bytes) + (\"b\" | to-bytes) | from-bytes", "ab\n");
    try expectOut(it, "\"x\" | to-bytes", "<bytes: 1>\n");
    try expectRuntime(it, "\"a\" + (\"b\" | to-bytes)", "cannot add a string and a bytes");
    try expectRuntime(it, "\"a\" | to-bytes | to-data", "to-data: a bytes is not data (functions, results, handles and bytes never are)");
    try std.testing.expectError(Error.Syntax, it.run("\"\xff\""));
    try expectOut(it, "\"a,b,c\" | split \",\" | join \"-\"", "a-b-c\n");
}

test "record literals and the strict data parser" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    // At the prompt, a record is a value like any other.
    try expectOut(it, "{ a: 1, b: two }", "a: 1\nb: two\n");
    try expectOut(it, "{ a: 1, b: two }.b", "two\n");
    try expectOut(it, "{ x: (1 + 2) }.x", "3\n");
    try expectOut(it, "if true { echo block }", "block\n"); // braces still block

    // A unit file: the literal subset only.
    const unit =
        \\# the filesystem service
        \\{
        \\  image:  fs
        \\  arg:    1
        \\  budget: { kobj: 1mb, user: 4mb }
        \\  grant:  [log, bootfs]
        \\  give: [
        \\    { tag: buf,  shm: 1 }
        \\    { tag: key,  secret: conf/fs.key }
        \\    { tag: disk, unit: blk }
        \\  ]
        \\  restart: { policy: one-for-one, max: 5 }
        \\}
    ;
    const v = try it.parseData(unit);
    try std.testing.expect(v == .record);
    try std.testing.expectEqualStrings("fs", v.record.get("image").?.str);
    try std.testing.expectEqual(@as(i64, 4 * 1024 * 1024), v.record.get("budget").?.record.get("user").?.int);
    try std.testing.expectEqual(@as(usize, 3), v.record.get("give").?.list.len);
    try std.testing.expectEqualStrings("blk", v.record.get("give").?.list[2].record.get("unit").?.str);
    try std.testing.expectEqualStrings("log", v.record.get("grant").?.list[0].str);

    // Not data: refused, never evaluated.
    try std.testing.expectError(Error.Runtime, it.parseData("{ a: (ls | len) }"));
    try std.testing.expectError(Error.Runtime, it.parseData("{ a: $x }"));
    try std.testing.expectError(Error.Syntax, it.parseData("{ a: 1 } { b: 2 }"));
    try std.testing.expectError(Error.Syntax, it.parseData("echo hi"));
}

test "def: functions with parameters, $in, and persistence across lines" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "def twice [x] { $x * 2 }", "");
    try expectOut(it, "twice 21", "42\n");
    try expectOut(it, "def big { $in | where size > 1kb | get name }", "");
    try expectOut(it, "ls | big", "big.bin\n");
    try expectOut(it, "def greet [who] { echo \"hi $who\" }; greet moss", "hi moss\n");
    try expectRuntime(it, "twice 1 2", "twice: 1 argument(s) expected, got 2");
    // Recursion by name: the body finds `fact` in its scope when it runs.
    try expectOut(it, "def fact [n] { if $n < 2 { 1 } else { $n * (fact ($n - 1)) } }; fact 10", "3628800\n");
    // A function sees its scope as it is at call time, not at definition.
    try expectOut(it, "def f { $k }; let k = 1; f", "1\n");
    try expectOut(it, "let k = 2; f", "2\n");
    // Locals stay local: a let inside a body never touches the session.
    try expectOut(it, "def g { let k = 99; $k }; g; $k", "2\n");
}

test "functions are values: fn, closures, block arguments, higher-order verbs" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "let inc = fn [x] { $x + 1 }; $inc 41", "42\n");
    try expectOut(it, "$inc", "<fn fn [x]>\n");
    try expectOut(it, "[1, 2, 3] | map $inc", "2\n3\n4\n");
    try expectOut(it, "[1, 2, 3] | map { $it * 10 }", "10\n20\n30\n");
    try expectOut(it, "[1, 2, 3, 4] | filter { $it % 2 == 0 }", "2\n4\n");
    try expectOut(it, "[1, 2, 3, 4] | reduce 0 { $acc + $it }", "10\n");
    try expectOut(it, "[1, 2, 3, 4] | reduce 0 (fn [a, b] { $a + $b })", "10\n");
    try expectOut(it, "[1, 2, 3] | any { $it > 2 }", "true\n");
    try expectOut(it, "[1, 2, 3] | all { $it > 2 }", "false\n");
    try expectOut(it, "[1, 2, 3] | find { $it > 1 }", "2\n");
    try expectOut(it, "[1, 2, 3] | find { $it > 5 }", "");
    try expectOut(it, "range 0 5 | map { $it * $it } | reduce 0 { $acc + $it }", "30\n");
    // Tables flow through map and filter as records.
    try expectOut(it, "ls | filter { $it.size > 0 } | map { $it.name }", "hi.txt\nbig.bin\n");
    try expectOut(it, "ls | map { { n: $it.name, big: ($it.size > 1kb) } } | where big | get n", "big.bin\n");
    // A closure snapshots the locals of the function that made it.
    try expectOut(it, "def adder [n] { fn [x] { $x + $n } }; let add5 = (adder 5); $add5 10", "15\n");
    try expectOut(it, "def scale [k] { $in | map { $it * $k } }; [1, 2] | scale 3", "3\n6\n");
    try expectOut(it, "def make { let base = 100; let f = fn [x] { $base + $x }; let base = 0; $f 1 }; make", "101\n");
    // Functions in records, called through a field.
    try expectOut(it, "let m = { double: (fn [x] { $x * 2 }) }; $m.double 4", "8\n");
    // A function remembers its source (a host may ship it elsewhere).
    try expectOut(it, "def twice [x] { $x * 2 }; type $twice", "function\n");
    try std.testing.expectEqualStrings("$x * 2", it.lookup("twice").?.func.src);
    try expectOut(it, "let g = fn {\n  $in | len\n}", "");
    try std.testing.expectEqualStrings("$in | len", it.lookup("g").?.func.src);
    try expectRuntime(it, "$m 1", "cannot call a record");
    try expectRuntime(it, "[1] | map 3", "map: a function expected");
    // A $var stage that is not a call is still an expression.
    try expectOut(it, "let x = 3; $x * 2", "6\n");
    try expectOut(it, "$x", "3\n");
    try expectOut(it, "$x + 1 == 4 and $x > 0", "true\n");
}

test "match: patterns, destructuring, guards, exhaustiveness" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "match 2 { 1 => \"one\"; 2 => \"two\"; _ => \"many\" }", "two\n");
    try expectOut(it, "match [1, 2, 3] { [] => \"empty\"; [$h, ..$t] => { echo \"$h then $t\" }; _ => \"not a list\" }", "1 then [2, 3]\n");
    // Lists and records are open shapes: only `_` (or a binder) covers them.
    try std.testing.expectError(Error.Syntax, it.run("match [1] { [] => \"e\"; [$h, ..] => $h }"));
    try expectOut(it, "match [1, 2, 3] { [$a, $b] => \"two\"; [$a, $b, $c] => \"three\"; _ => \"other\" }", "three\n");
    try expectOut(it, "match [1, 2, 3] { [1, ..] => \"starts with 1\"; _ => \"no\" }", "starts with 1\n");
    try expectOut(it, "match { name: sub, size: 0 } { { name: $n, size: 0 } => echo \"empty $n\"; _ => \"full\" }", "empty sub\n");
    try expectOut(it, "match (stat x) { { type } => $type; _ => \"untyped\" }", "dir\n");
    try expectOut(it, "match 7 { $n if $n > 5 => \"big\"; $n => \"small\" }", "big\n");
    try expectOut(it, "match 3 { $n if $n > 5 => \"big\"; $n => \"small\" }", "small\n");
    // An arm's body may be any one statement.
    try expectOut(it, "match 3 { $n => if $n > 2 { \"big\" } else { \"small\" } }", "big\n");
    try expectOut(it, "match dir { file => \"f\"; dir => \"d\"; _ => \"x\" }", "d\n");
    try expectOut(it, "match true { true => \"t\"; false => \"f\" }", "t\n");
    try expectOut(it, "match \"a b\" { \"a b\" => \"yes\"; _ => \"no\" }", "yes\n");
    // As an expression, and inside a function with a table subject.
    try expectOut(it, "let kind = match 0 { 0 => \"zero\"; _ => \"other\" }; $kind", "zero\n");
    try expectOut(it, "def first-name { match $in { [$r, ..] => $r.name; _ => \"null\" } }; ls | first-name", "hi.txt\n");
    // Nested patterns and multi-line arms.
    try expectOut(it,
        \\match { who: { name: moss } } {
        \\  { who: { name: $n } } => {
        \\    let greeting = "hi $n"
        \\    $greeting
        \\  }
        \\  _ => nobody
        \\}
    , "hi moss\n");
    // Exhaustiveness is checked when the match is parsed.
    try std.testing.expectError(Error.Syntax, it.run("match 1 { 1 => \"one\" }"));
    try std.testing.expectEqualStrings("match: not exhaustive — add a `_ =>` arm", it.err_msg);
    try std.testing.expectError(Error.Syntax, it.run("match 1 { $n if $n > 0 => \"pos\" }"));
    try std.testing.expectError(Error.Syntax, it.run("match (ok 1) { ok $v => $v }"));
    try std.testing.expectEqualStrings("match: not exhaustive — no `err _ =>` arm", it.err_msg);
    try std.testing.expectError(Error.Syntax, it.run("match true { true => \"t\" }"));
}

test "results: ok, err, ?, try, and match on them" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    // At the top an ok shows what it holds; inline (echo, str, a list) it says ok.
    try expectOut(it, "ok 1", "1\n");
    try expectOut(it, "echo (ok 1)", "ok 1\n");
    try expectOut(it, "[(ok 1), (err 2)]", "ok 1\nerr 2\n");
    try expectOut(it, "err \"boom\"", "err boom\n");
    try expectOut(it, "(ok 5)? + 1", "6\n");
    try expectOut(it, "match (int \"7\") { ok $n => $n * 2; err $e => -1 }", "14\n");
    try expectOut(it, "match (int x) { ok $n => $n * 2; err $e => -1 }", "-1\n");
    try expectOut(it, "match (int x) { ok $n => $n; err { code: $c } => $c; err $e => \"failed: $e\" }", "failed: not a number: x\n");
    // ? inside a function returns the err from that function.
    try expectOut(it, "def parse2 [a, b] { ok ((int $a)? + (int $b)?) }; echo (parse2 1 2)", "ok 3\n");
    try expectOut(it, "parse2 1 x", "err not a number: x\n");
    try expectOut(it, "def total { $in | map { (int $it)? } | reduce 0 { $acc + $it } }; [\"1\", \"2\"] | total", "3\n");
    // The pipeline form: `stage ?`.
    try expectOut(it, "int \"9\" ?", "9\n");
    try expectOut(it, "[\"4\"] | map { int $it ? }", "4\n");
    // At the top level an err has nowhere to go.
    try expectRuntime(it, "(int x)?", "unhandled err not a number: x");
    try expectRuntime(it, "5?", "?: needs a result, got a int");
    // try: a failing command becomes an err value; a good one an ok.
    try expectOut(it, "try { fails }", "err fails: as asked\n");
    try expectOut(it, "echo (try { 1 + 1 })", "ok 2\n");
    // A result passes through try as it is: no double wrapping.
    try expectOut(it, "echo (try { int x })", "err not a number: x\n");
    try expectOut(it, "echo (try (ok 4))", "ok 4\n");
    try expectOut(it, "try (fails)", "err fails: as asked\n");
    try expectOut(it, "match (try { fails }) { ok _ => \"fine\"; err $e => \"caught: $e\" }", "caught: fails: as asked\n");
    try expectOut(it, "try { (int x)? }", "err not a number: x\n");
    try expectRuntime(it, "ok 1 2", "ok: one value expected");
    try expectRuntime(it, "ok 1 | to-data", "to-data: a result is not data (functions, results, handles and bytes never are)");
}

test "use: a file is a module, its bindings a record" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "let math = (use lib/math.msh)", "");
    try expectOut(it, "$math.version", "2\n");
    try expectOut(it, "$math.double 21", "42\n");
    // Module functions find each other by name in the module's scope,
    // never in the session's.
    try expectOut(it, "$math.quad 2", "8\n");
    try expectOut(it, "$math.fact 5", "120\n");
    try expectRuntime(it, "double 2", "unknown command 'double'");
    try expectOut(it, "$math | keys", "version\ndouble\nquad\nfact\n");
    try expectOut(it, "[1, 2] | map $math.double", "2\n4\n");
    // The module's scope outlives the record that reached it.
    try expectOut(it, "let q = $math.quad; let math = 0; $q 3", "12\n");
    try expectRuntime(it, "use lib/none.msh", "use: lib/none.msh: not_found");
    try expectRuntime(it, "use lib/bad.msh", "unknown command 'frobnicate'");
    try expectRuntime(it, "use lib/self.msh", "use: modules nested too deep at lib/self.msh");
    // A bare name is a module in the store (the host's `module` command).
    try expectOut(it, "let m = (use math); $m.double 4", "8\n");
    try expectRuntime(it, "use nope", "use: nope: not_found");
}

test "the standard library: lib/msh/math.msh through use" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "let m = (use std-math); [3, 1, 2] | $m.sum", "6\n");
    // A function value as a stage is called with the input; alone it is the value.
    try expectOut(it, "$m.sum", "<fn sum []>\n");
    try expectOut(it, "let total = $m.sum; [1, 2] | $total", "3\n");
    try expectOut(it, "[1.5, 2.5] | $m.sum", "4.0\n");
    try expectOut(it, "[] | $m.sum", "0\n");
    try expectOut(it, "[4, 5] | $m.product", "20\n");
    try expectOut(it, "[3, 9, 2] | $m.max-of", "9\n");
    try expectOut(it, "[3, 9, 2] | $m.min-of", "2\n");
    try expectOut(it, "[1.0, 2.0, 6.0] | $m.mean", "3.0\n");
    try expectOut(it, "[1, 2] | $m.mean", "1.5\n");
    try expectOut(it, "[] | $m.mean", "0.0\n");
    try expectOut(it, "$m.clamp 15 0 10", "10\n");
    try expectOut(it, "$m.clamp (0 - 3) 0 10", "0\n");
}

test "floats: a second kind of number, never mixed with the first" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "1.5 + 2.25", "3.75\n");
    try expectOut(it, "3.0", "3.0\n");
    try expectOut(it, "2e3", "2000.0\n");
    try expectOut(it, "1.5kb", "1536.0\n");
    try expectOut(it, "-0.5 * 4.0", "-2.0\n");
    try expectOut(it, "7.0 / 2.0", "3.5\n");
    try expectOut(it, "1.0 / 3.0", "0.3333333333333333\n");
    try expectOut(it, "7.5 % 2.0", "1.5\n");
    try expectOut(it, "type 1.5", "float\n");
    try expectOut(it, "1.2.3", "1.2.3\n"); // a version, not a number
    try expectRuntime(it, "1 + 1.5", "cannot add a int and a float");
    try expectRuntime(it, "2 * 1.5", "arithmetic needs two ints or two floats, got a int and a float");
    try expectRuntime(it, "1.0 / 0.0", "division by zero");
    try expectRuntime(it, "1.5 == 1", "cannot compare a float with a int");
    try expectOut(it, "1.5 < 2.0 and 2.0 == 2.0", "true\n");
    // Conversions are commands with typed answers.
    try expectOut(it, "(float 2)? * 1.5", "3.0\n");
    try expectOut(it, "(int 2.9)?", "2\n");
    try expectOut(it, "(-2.9 | int)?", "-2\n");
    try expectOut(it, "float \"1e-3\"", "0.001\n");
    try expectOut(it, "echo (float x)", "err not a number: x\n");
    try expectOut(it, "echo (int 1e30)", "err not an int: 1e30\n");
    try expectOut(it, "[(round 2.5), (floor 2.5), (ceil 2.5), (round 3)]", "3.0\n2.0\n3.0\n3\n");
    try expectOut(it, "str 2.50", "2.5\n");
    // Data and JSON carry floats as floats.
    try expectOut(it, "[1.5, 0.25] | to-data", "[1.5, 0.25]\n");
    try expectOut(it, "{ x: 1e21, y: 3.0 } | to-data | from-data | get x", "1e21\n");
    try expectOut(it, "[1.5, 3.0] | to-json", "[1.5,3.0]\n");
    try expectOut(it, "\"{\\\"v\\\": 2.5}\" | from-json | get v | type", "float\n");
    try expectRuntime(it, "(1e308 * 10.0) | to-data", "to-data: a float is not data (functions, results, handles and bytes never are)");
}

test "shapes: annotations checked where they run, check at a boundary" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    // let
    try expectOut(it, "let n: int = 3; $n", "3\n");
    try expectRuntime(it, "let s: string = 5", "let: s is 5, not string");
    try expectOut(it, "let e: { name: string, size: int } = { name: a, size: 1, extra: true }; $e.extra", "true\n");
    try expectRuntime(it, "let e: { name: string, size: int } = { name: a, size: x }", "let: e.size is x, not int");
    try expectRuntime(it, "let e: { name: string } = { size: 1 }", "let: e has no field 'name'");
    try expectRuntime(it, "let l: [int] = [1, 2, x]", "let: l[2] is x, not int");
    try expectRuntime(it, "let k: dir | file = symlink", "let: k is symlink, not dir | file");
    try expectOut(it, "let o: int | nothing = null; $o == null", "true\n");
    try expectOut(it, "let f: float = 1.5; $f", "1.5\n");
    try expectOut(it, "let t: [{ name: string }] = (ls); $t | len", "3\n");
    try expectRuntime(it, "let t: [{ name: int }] = (ls)", "let: t[0].name is hi.txt, not int");
    try expectOut(it, "let r: ok int | err string = (int \"4\"); $r", "4\n");
    try expectRuntime(it, "let r: ok string = (int \"4\")", "let: r (ok) is 4, not string");
    try expectRuntime(it, "let r: err any = (int \"4\")", "let: r is ok 4, not err any");
    // Parameters and returns, checked at the call.
    try expectOut(it, "def twice [x: int] -> int { $x * 2 }; twice 21", "42\n");
    try expectRuntime(it, "twice a", "twice: x is a, not int");
    try expectRuntime(it, "def bad [x: int] -> string { $x }; bad 1", "bad: return is 1, not string");
    try expectOut(it, "def safe [t: string] -> ok int | err string { int $t }; safe \"4\"", "4\n");
    try expectOut(it, "echo (safe q)", "err not a number: q\n");
    try expectOut(it, "(fn [a: bool] { $a }) true", "true\n");
    try expectOut(it, "def first-name [r: { name: string }] { $r.name }; first-name { name: bo, age: 3 }", "bo\n");
    // Shapes are values; `check` answers a result.
    try expectOut(it, "let S = shape { name: string, size: int }; type $S", "shape\n");
    try expectOut(it, "$S", "{ name: string, size: int }\n");
    try expectOut(it, "{ name: a, size: 1 } | check $S", "name: a\nsize: 1\n");
    try expectOut(it, "echo ({ name: a } | check $S)", "err it has no field 'size'\n");
    try expectOut(it, "echo (check 3 shape int)", "ok 3\n");
    try expectOut(it, "echo (5 | check shape (int | string))", "ok 5\n");
    try expectOut(it, "5 | check shape int | type", "result\n");
    try expectOut(it, "let T = shape [$S]; $T", "[{ name: string, size: int }]\n");
    try expectOut(it, "(ls | check $T)? | len", "3\n");
    try expectOut(it, "shape (ok int | err (string | nothing))", "ok int | err (string | nothing)\n");
    try expectOut(it, "shape handle socket", "handle socket\n");
    try expectOut(it, "echo ((open-sock 1) | check shape handle socket | type)", "result\n");
    try expectOut(it, "shape (\"two words\" | \"int\")", "\"two words\" | \"int\"\n");
    try expectRuntime(it, "let x: $nope = 1", "shape: unknown variable $nope");
    try expectRuntime(it, "let y = 1; let x: $y = 1", "shape: $y is a int, not a shape");
    try expectRuntime(it, "shape { a: int } | to-data", "to-data: a shape is not data (functions, results, handles and bytes never are)");
    // A shape in a closure resolves in the closure's scope.
    try expectOut(it, "def mk [] { let P = shape int; fn [x: $P] { $x } }; let g = (mk); $g 7", "7\n");
    try expectRuntime(it, "$g a", "fn: x is a, not int");
    // match with a shape: the subject must fit, the arms must cover it.
    try expectOut(it, "match dir: dir | file { dir => 1; file => 2 }", "1\n");
    try expectRuntime(it, "match dir: dir | file | symlink { dir => 1; file => 2 }", "match: the arms do not cover symlink");
    try expectRuntime(it, "match x: dir | file { dir => 1; file => 2 }", "match: subject is x, not dir | file");
    try expectOut(it, "match (int \"3\"): ok int | err string { ok $n => $n; err _ => 0 }", "3\n");
    try expectRuntime(it, "match (int \"3\"): result { ok _ => 1 }", "match: the arms do not cover err any");
    try expectRuntime(it, "match (int \"3\"): ok (int | nothing) | err string { ok $n if $n > 1 => $n; ok null => 0; err _ => 0 }", "match: the arms do not cover ok int");
    try expectRuntime(it, "match 5: int { 5 => a }", "match: the arms do not cover int");
    try expectOut(it, "match true: bool { true => 1; false => 0 }", "1\n");
    try expectRuntime(it, "match true: bool { true => 1 }", "match: the arms do not cover false");
    try expectOut(it, "match { name: a }: { name: string } { { name: $n } => $n }", "a\n");
    try expectRuntime(it, "match { name: dir }: { name: dir | file } { { name: dir } => 1 }", "match: the arms do not cover { name: dir | file }");
    try expectOut(it, "match { name: file }: { name: dir | file } { { name: dir } => 1; { name: file } => 2 }", "2\n");
    try expectOut(it, "match [1]: [int] { [..] => \"y\" }", "y\n");
    try expectRuntime(it, "match [1]: [int] { [$h, ..] => $h }", "match: the arms do not cover [int]");
    // Two fields: every combination must be covered.
    try expectRuntime(it, "match { a: dir, b: true }: { a: dir | file, b: bool } { { a: dir, b: true } => 1; { a: file } => 2 }", "match: the arms do not cover { a: dir | file, b: bool }");
    try expectOut(it, "match { a: dir, b: false }: { a: dir | file, b: bool } { { a: dir, b: true } => 1; { a: file } => 2; { b: false } => 3 }", "3\n");
    try expectOut(it, "let K = shape (dir | file); match file: $K { dir => 1; file => 2 }", "2\n");
    try expectOut(it, "def kind [t: dir | file] { match $t: dir | file { dir => \"d\"; file => \"f\" } }; kind file", "f\n");
}

test "signatures: a host command is checked at the boundary, both ways" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "stat x | get type", "dir\n");
    try expectRuntime(it, "stat 1", "stat: path is 1, not string");
    try expectRuntime(it, "stat", "stat: path expected");
    try expectRuntime(it, "stat a b", "stat: 1 argument(s) at most, got 2");
    try expectRuntime(it, "ls | stat x", "stat: takes no input, got a table");
    try expectOut(it, "ls | len", "3\n");
    try expectOut(it, "ls data | len", "3\n");
    try expectRuntime(it, "ls 1", "ls: path is 1, not string");
    // The host's own answer is checked too, and the blame is placed.
    try expectRuntime(it, "lies", "lies: answer is 1, not string (the host's slip, not yours)");
    // No signature: no check (the command is on its own).
    try expectRuntime(it, "fails 1 2 3", "fails: as asked");
    // `signature NAME` is a record of shape values.
    try expectOut(it, "(signature stat).returns", "{ type: file | dir, size: int }\n");
    try expectOut(it, "(signature ls).params | get name", "path\n");
    try expectOut(it, "(signature ls).params | get optional", "true\n");
    try expectOut(it, "(signature ls).returns", "[{ name: string, type: file | dir, size: int }]\n");
    try expectOut(it, "(signature open).returns", "ok string | err not_found\n");
    try expectOut(it, "(signature save).input", "any\n");
    try expectOut(it, "signature nope", "");
    try expectOut(it, "(stat x | check (signature stat).returns)? | get size", "0\n");
    try expectOut(it, "let sh: shape = (signature ls).returns; (ls | check $sh)? | len", "3\n");
}

test "memory: boxes are counted exactly and released when unbound" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "let a = [1, 2, 3]", "");
    const box_a = it.session.?.find("a").?.box.?;
    try std.testing.expectEqual(@as(usize, 1), box_a.rc);
    // `let b = $a` shares the box; `let c = ($a | first 1)` copies.
    try expectOut(it, "let b = $a; let c = ($a | first 1)", "");
    try std.testing.expectEqual(@as(usize, 2), box_a.rc);
    try std.testing.expect(it.session.?.find("c").?.box.? != box_a);
    try expectOut(it, "let b = 0", "");
    try std.testing.expectEqual(@as(usize, 1), box_a.rc);
    try std.testing.expect(it.session.?.find("b").?.box == null); // scalars live inline
    // A function in a record: the record's box retains the closure's.
    try expectOut(it, "let f = fn { 1 }; let r = { f: $f }", "");
    const box_f = it.session.?.find("f").?.box.?;
    try std.testing.expectEqual(@as(usize, 2), box_f.rc);
    try expectOut(it, "let r = 0", "");
    it.reclaim(); // a statement's garbage waits for the statement's end — here, the next call
    try std.testing.expectEqual(@as(usize, 1), box_f.rc);
    // Closures hold their scope; a module scope dies with its last closure.
    try expectOut(it, "let m = (use lib/math.msh); let d = $m.double; let m = 0; $d 2", "4\n");
    try expectOut(it, "let d = 0", "");
    // Rebinding inside a loop over the old value: the box outlives the
    // statement, not the line (the leak check at deinit is the proof).
    try expectOut(it, "let big = (range 0 100); for x in $big { let big = [$x] }; $big", "99\n");
}

test "calls reuse frames: ten thousand block calls cost one frame's worth" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    it.frames_made = 0;
    try expectOut(it, "range 0 10000 | map { $it * 2 } | reduce 0 { $acc + $it }", "99990000\n");
    // Two verbs, each one frame reused ten thousand times.
    try std.testing.expect(it.frames_made <= 2);
    it.frames_made = 0;
    try expectOut(it, "def depth [n] { if $n == 0 { 0 } else { 1 + (depth ($n - 1)) } }; depth 50", "50\n");
    try std.testing.expectEqual(@as(usize, 51), it.frames_made); // nesting costs frames; repetition does not
}

test "handles: a host capability as a value, dropped at the last use" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    // Unbound: dropped when the statement ends.
    try expectOut(it, "open-sock 7", "<socket 7>\n");
    it.reclaim();
    try std.testing.expectEqual(@as(usize, 1), t.host.dropped);
    try std.testing.expectEqual(@as(u64, 7), t.host.last_dropped);
    // Bound: kept while any name or value holds it, then dropped once.
    try expectOut(it, "let s = (open-sock 8); type $s", "socket\n");
    try expectOut(it, "let r = { sock: $s }; let s = 0", "");
    it.reclaim();
    try std.testing.expectEqual(@as(usize, 1), t.host.dropped);
    try expectOut(it, "let r = 0", "");
    it.reclaim();
    try std.testing.expectEqual(@as(usize, 2), t.host.dropped);
    try std.testing.expectEqual(@as(u64, 8), t.host.last_dropped);
    // Closed by the host: no drop afterwards.
    try expectOut(it, "let c = (open-sock 9); close-sock $c; $c", "<socket 9 closed>\n");
    try expectOut(it, "let c = 0", "");
    it.reclaim();
    try std.testing.expectEqual(@as(usize, 1), t.host.closed);
    try std.testing.expectEqual(@as(usize, 2), t.host.dropped);
    // A handle in a closure's capture lives with the closure.
    try expectOut(it, "def keep [h] { fn { $h } }; let k = (keep (open-sock 10)); $k", "<fn fn []>\n");
    it.reclaim();
    try std.testing.expectEqual(@as(usize, 2), t.host.dropped);
    try expectOut(it, "let k = 0", "");
    it.reclaim();
    try std.testing.expectEqual(@as(usize, 3), t.host.dropped);
    try expectRuntime(it, "open-sock 1 | to-data", "to-data: a socket is not data (functions, results, handles and bytes never are)");
}

test "to-data / from-data round-trip through the strict parser" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "ls | to-data | from-data | where size > 1kb | get name", "big.bin\n");
    try expectOut(it, "[1, \"two words\", true, null] | to-data", "[1, \"two words\", true, null]\n");
    try expectOut(it, "{ a: \"x:y\", b: [1] } | to-data | from-data | get a", "x:y\n");
    try expectOut(it, "\"a\\\"b\" | to-data | from-data", "a\"b\n");
    try expectOut(it, "ls | to-data | from-data | len", "3\n");
    try expectOut(it, "[\"fn\", \"match\", \"_\", \"ok\"] | to-data", "[\"fn\", \"match\", \"_\", ok]\n");
}

test "json: to-json and from-json, tables included" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "{ a: [1, two, true, null], b: { c: \"x\" } } | to-json", "{\"a\":[1,\"two\",true,null],\"b\":{\"c\":\"x\"}}\n");
    try expectOut(it, "ls | to-json", "[{\"name\":\"hi.txt\",\"type\":\"file\",\"size\":27},{\"name\":\"big.bin\",\"type\":\"file\",\"size\":8192},{\"name\":\"sub\",\"type\":\"dir\",\"size\":0}]\n");
    try expectOut(it, "ls | to-json | from-json | where size > 1kb | get name", "big.bin\n");
    try expectOut(it, "\"{\\\"k\\\": [1, 2]}\" | from-json | get k | len", "2\n");
    try expectOut(it, "\"[1.5, 2e3]\" | from-json | to-json", "[1.5,2000.0]\n");
    try expectRuntime(it, "\"nope\" | from-json", "from-json: not JSON");
    try expectRuntime(it, "(fn { 1 }) | to-json", "to-json: a function is not data (functions, results, handles and bytes never are)");
}

test "scripts render every statement's value" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    var out: std.ArrayList(u8) = .empty;
    const last = try it.evalScript("echo one\nlet x = 2\n$x\ndef f { 3 }\nf", &out);
    try std.testing.expectEqual(@as(i64, 3), last.int);
    try std.testing.expectEqualStrings("one\n2\n3\n", out.items);
}

test "records render as key: value lines; tables align" {
    var t: TestState = undefined;
    t.start();
    defer t.stop();
    const it = &t.it;
    try expectOut(it, "stat data", "type: dir\nsize: 0\n");
    try expectOut(it, "echo a b 3", "a b 3\n");
}
