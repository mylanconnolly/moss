//! mshl — the msh language: a small structured shell language in the
//! spirit of the OS. Pipelines carry VALUES (records and tables), never
//! bytes to be re-parsed; text exists only when a value is rendered for a
//! human. Pure and freestanding-safe: the interpreter takes allocators
//! and a host callback for environment commands (files, domains, the
//! fabric), and every language feature is tested here on the host.
//!
//! Grammar (small and regular, by design):
//!   program  := stmt (';' | newline)*
//!   stmt     := 'let' name '=' expr | 'if' expr block ['else' (block|if)]
//!             | 'for' name 'in' expr block | 'while' expr block | pipeline
//!   pipeline := stage ('|' stage)* ['>' word]        ('>' = '| save word')
//!   stage    := name arg* | expr
//!   arg      := word | string | '$'var | '(' pipeline ')' | '[' list ']' | block
//!   expr     := or; or := and ('or' and)*; and := not ('and' not)*
//!   not      := 'not' not | cmp; cmp := add (op add)?; add/mul as usual
//!   primary  := number[unit] | string | '$'var | word | '(' pipeline ')'
//!             | '[' expr,* ']' | 'true' | 'false' | 'null'
//!   postfix  := primary ('.' name | '.' index)*
//!   record   := '{' (word ':' expr (',' | newline)*)* '}'   (a '{' followed
//!               by `word:` is a record; otherwise it is a block)
//! Inside `where`, a bare word naming a column of the current row is that
//! column; elsewhere a bare word is a string. Strings interpolate "$var".
//!
//! DATA FILES (unit files, config) are the literal subset of the same
//! syntax — numbers with units, strings, bare words, true/false/null,
//! lists, records, comments — parsed by `parseData`, which accepts
//! literals and nothing else: no commands, no variables, no evaluation.
//! A `.msh` file is a program or a record depending only on which entry
//! point reads it.

const std = @import("std");

pub const Value = union(enum) {
    nothing,
    bool: bool,
    int: i64,
    str: []const u8,
    list: []const Value,
    record: Record,
    table: Table,

    pub fn typeName(v: Value) []const u8 {
        return switch (v) {
            .nothing => "nothing",
            .bool => "bool",
            .int => "int",
            .str => "string",
            .list => "list",
            .record => "record",
            .table => "table",
        };
    }

    pub fn truthy(v: Value) bool {
        return switch (v) {
            .nothing => false,
            .bool => |b| b,
            .int => |i| i != 0,
            .str => |s| s.len != 0,
            .list => |l| l.len != 0,
            .record => true,
            .table => |t| t.rows.len != 0,
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

pub const Error = error{ OutOfMemory, Syntax, Runtime, Exit };

/// The environment: commands the language does not define itself.
/// Return null for an unknown name (the interpreter reports it).
pub const Host = struct {
    ctx: *anyopaque,
    call: *const fn (ctx: *anyopaque, it: *Interp, name: []const u8, args: []const Value, input: ?Value) Error!?Value,
};

/// Commands defined by the language itself (pure value operations).
pub const builtin_names = [_][]const u8{
    "echo",   "len", "first", "last", "reverse", "where", "sort-by",
    "select", "get", "lines", "keys", "let",     "if",    "for",
    "while",  "not", "and",   "or",   "true",    "false", "null",
    "else",   "in",
};

pub const max_vars = 32;
pub const max_funcs = 16;

const Var = struct { name: []const u8, value: Value };

/// `def name [params] { body }`: the body's tree lives in the persistent
/// allocator (source and nodes copied), so a function outlives the line
/// that defined it.
const Func = struct { name: []const u8, params: []const []const u8, body: *Node };

pub const Interp = struct {
    /// Per-evaluation temporaries (reset by the host between lines).
    arena: std.mem.Allocator,
    /// Variables live here (deep copies) across evaluations.
    persist: std.mem.Allocator,
    host: Host,
    vars: [max_vars]Var = undefined,
    nvars: usize = 0,
    /// Rendered output of the last evaluation.
    out: std.ArrayList(u8) = .empty,
    /// The message behind the last Syntax/Runtime error.
    err_msg: []const u8 = "",
    /// Set by `where`: the row bare words resolve against.
    row: ?Record = null,
    funcs: [max_funcs]Func = undefined,
    nfuncs: usize = 0,

    pub fn init(arena: std.mem.Allocator, persist: std.mem.Allocator, host: Host) Interp {
        return .{ .arena = arena, .persist = persist, .host = host };
    }

    /// Parse and evaluate one program; the value of its last statement is
    /// returned AND rendered into `out` (which the caller shows and
    /// clears). Errors carry a message in err_msg.
    pub fn run(self: *Interp, src: []const u8) Error!Value {
        self.out = .empty;
        var p = Parser{ .it = self, .lex = Lexer{ .src = src } };
        const prog = try p.program();
        const v = try self.evalBlock(prog);
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
    /// statement's value is rendered into `out` as it is produced.
    pub fn evalScript(self: *Interp, src: []const u8, out: *std.ArrayList(u8)) Error!void {
        var p = Parser{ .it = self, .lex = Lexer{ .src = src } };
        const prog = try p.program();
        for (prog) |stmt| {
            const v = try self.evalStmt(stmt);
            try render(v, self.arena, out);
        }
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

    // ---------------------------------------------------------- variables

    pub fn lookup(self: *Interp, name: []const u8) ?Value {
        var i = self.nvars;
        while (i > 0) : (i -= 1) {
            if (std.mem.eql(u8, self.vars[i - 1].name, name)) return self.vars[i - 1].value;
        }
        return null;
    }

    pub fn setVar(self: *Interp, name: []const u8, v: Value) Error!void {
        const copy = try dupValue(self.persist, v);
        for (self.vars[0..self.nvars]) |*e| {
            if (std.mem.eql(u8, e.name, name)) {
                e.value = copy;
                return;
            }
        }
        if (self.nvars == max_vars) return self.fail("too many variables", .{});
        self.vars[self.nvars] = .{ .name = try self.persist.dupe(u8, name), .value = copy };
        self.nvars += 1;
    }

    // --------------------------------------------------------- evaluation

    fn evalBlock(self: *Interp, stmts: []const *Node) Error!Value {
        var last: Value = .nothing;
        for (stmts) |s| last = try self.evalStmt(s);
        return last;
    }

    fn evalStmt(self: *Interp, n: *Node) Error!Value {
        switch (n.*) {
            .let => |l| {
                try self.setVar(l.name, try self.evalNode(l.expr));
                return .nothing;
            },
            .def => |d| {
                try self.defineFunc(d.name, d.params, d.body);
                return .nothing;
            },
            .if_ => |c| {
                if ((try self.evalNode(c.cond)).truthy()) return self.evalNode(c.then);
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
                for (items) |item| {
                    try self.setVar(f.name, item);
                    last = try self.evalNode(f.body);
                }
                return last;
            },
            .while_ => |w| {
                var last: Value = .nothing;
                var guard: usize = 0;
                while ((try self.evalNode(w.cond)).truthy()) : (guard += 1) {
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
                    .not => .{ .bool = !v.truthy() },
                    .neg => switch (v) {
                        .int => |i| .{ .int = -i },
                        else => self.fail("cannot negate a {s}", .{v.typeName()}),
                    },
                };
            },
            .let, .def, .if_, .for_, .while_ => return self.evalStmt(n),
        }
    }

    // ---------------------------------------------------------- functions

    fn defineFunc(self: *Interp, name: []const u8, params: []const []const u8, body: *Node) Error!void {
        const pname = try self.persist.dupe(u8, name);
        const pparams = try self.persist.alloc([]const u8, params.len);
        for (params, 0..) |p, i| pparams[i] = try self.persist.dupe(u8, p);
        const pbody = try dupNode(self.persist, body);
        for (self.funcs[0..self.nfuncs]) |*f| {
            if (std.mem.eql(u8, f.name, name)) {
                f.* = .{ .name = pname, .params = pparams, .body = pbody };
                return;
            }
        }
        if (self.nfuncs == max_funcs) return self.fail("too many functions", .{});
        self.funcs[self.nfuncs] = .{ .name = pname, .params = pparams, .body = pbody };
        self.nfuncs += 1;
    }

    fn findFunc(self: *Interp, name: []const u8) ?*Func {
        for (self.funcs[0..self.nfuncs]) |*f| {
            if (std.mem.eql(u8, f.name, name)) return f;
        }
        return null;
    }

    /// Call a function: parameters bind as variables in a scope that ends
    /// with the call; the pipeline input is `$in`.
    fn callFunc(self: *Interp, f: *Func, args: []const Value, input: ?Value) Error!Value {
        if (args.len != f.params.len) return self.fail("{s}: {d} argument(s) expected, got {d}", .{ f.name, f.params.len, args.len });
        const saved = self.nvars;
        defer self.nvars = saved;
        for (f.params, args) |p, a| try self.setVarNew(p, a);
        try self.setVarNew("in", input orelse .nothing);
        return self.evalNode(f.body);
    }

    /// A fresh binding (shadowing), for scopes.
    fn setVarNew(self: *Interp, name: []const u8, v: Value) Error!void {
        if (self.nvars == max_vars) return self.fail("too many variables", .{});
        self.vars[self.nvars] = .{ .name = try self.persist.dupe(u8, name), .value = try dupValue(self.persist, v) };
        self.nvars += 1;
    }

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
                const l = try self.evalNode(b.lhs);
                if (!l.truthy()) return .{ .bool = false };
                return .{ .bool = (try self.evalNode(b.rhs)).truthy() };
            },
            .@"or" => {
                const l = try self.evalNode(b.lhs);
                if (l.truthy()) return .{ .bool = true };
                return .{ .bool = (try self.evalNode(b.rhs)).truthy() };
            },
            else => {},
        }
        const l = try self.evalNode(b.lhs);
        const r = try self.evalNode(b.rhs);
        switch (b.op) {
            .eq => return .{ .bool = valueEql(l, r) },
            .ne => return .{ .bool = !valueEql(l, r) },
            .lt, .le, .gt, .ge => {
                const c = compareValues(l, r) orelse return self.fail("cannot compare {s} with {s}", .{ l.typeName(), r.typeName() });
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
                if (l == .str and r == .str) return .{ .str = try std.mem.concat(self.arena, u8, &.{ l.str, r.str }) };
                if (l == .list and r == .list) return .{ .list = try std.mem.concat(self.arena, Value, &.{ l.list, r.list }) };
                return self.fail("cannot add {s} and {s}", .{ l.typeName(), r.typeName() });
            },
            .sub, .mul, .div, .mod => {
                if (l != .int or r != .int) return self.fail("arithmetic needs ints, got {s} and {s}", .{ l.typeName(), r.typeName() });
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

    fn evalCall(self: *Interp, c: Call, input: ?Value) Error!Value {
        // Language-level commands that need unevaluated arguments.
        if (std.mem.eql(u8, c.name, "where")) return self.cmdWhere(c, input);

        const args = try self.arena.alloc(Value, c.args.len);
        for (c.args, 0..) |a, i| args[i] = try self.evalNode(a);
        if (self.findFunc(c.name)) |f| return self.callFunc(f, args, input);
        if (try self.builtin(c.name, args, input)) |v| return v;
        if (try self.host.call(self.host.ctx, self, c.name, args, input)) |v| return v;
        return self.fail("unknown command '{s}'", .{c.name});
    }

    fn cmdWhere(self: *Interp, c: Call, input: ?Value) Error!Value {
        if (c.args.len != 1) return self.fail("where: one condition expected", .{});
        const cond = c.args[0];
        const in = input orelse return self.fail("where: needs input", .{});
        const saved = self.row;
        defer self.row = saved;
        switch (in) {
            .table => |t| {
                var rows: std.ArrayList([]const Value) = .empty;
                for (t.rows, 0..) |r, i| {
                    self.row = t.row(i);
                    if ((try self.evalNode(cond)).truthy()) try rows.append(self.arena, r);
                }
                return .{ .table = .{ .cols = t.cols, .rows = rows.items } };
            },
            .list => |l| {
                var keep: std.ArrayList(Value) = .empty;
                for (l) |item| {
                    self.row = if (item == .record) item.record else null;
                    if (self.row == null) try self.setVar("it", item);
                    if ((try self.evalNode(cond)).truthy()) try keep.append(self.arena, item);
                }
                return .{ .list = keep.items };
            },
            else => return self.fail("where: needs a table or list, got {s}", .{in.typeName()}),
        }
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
                .str => |s| s.len,
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
            var buf: std.ArrayList(u8) = .empty;
            try writeData(v, self.arena, &buf);
            return .{ .str = buf.items };
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
        return null;
    }

    fn intArg(self: *Interp, v: Value, cmd: []const u8) Error!i64 {
        return switch (v) {
            .int => |i| i,
            .str => |s| std.fmt.parseInt(i64, s, 10) catch self.fail("{s}: number expected, got '{s}'", .{ cmd, s }),
            else => self.fail("{s}: number expected", .{cmd}),
        };
    }

    fn strArg(self: *Interp, v: Value, cmd: []const u8) Error![]const u8 {
        return switch (v) {
            .str => |s| s,
            .int => |i| std.fmt.allocPrint(self.arena, "{d}", .{i}) catch return Error.OutOfMemory,
            else => self.fail("{s}: name expected, got a {s}", .{ cmd, v.typeName() }),
        };
    }
};

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
/// that hand msh structured results.
pub fn writeData(v: Value, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    switch (v) {
        .nothing => try out.appendSlice(a, "null"),
        .bool => |b| try out.appendSlice(a, if (b) "true" else "false"),
        .int => |i| {
            var buf: [24]u8 = undefined;
            try out.appendSlice(a, std.fmt.bufPrint(&buf, "{d}", .{i}) catch "0");
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
    }
}

/// Quote unless the text reads back as the same bare word.
fn writeStr(s: []const u8, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
    var bare = s.len > 0 and !std.ascii.isDigit(s[0]) and s[0] != '-' and s[0] != '$';
    for (s) |c| {
        if (!Lexer.isWordChar(c) or c == ':' or c == '#') bare = false;
    }
    if (bare and s[s.len - 1] == ':') bare = false;
    for ([_][]const u8{ "true", "false", "null", "not", "and", "or", "in" }) |kw| {
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
        .let => |l| .{ .let = .{ .name = try a.dupe(u8, l.name), .expr = try dupNode(a, l.expr) } },
        .def => |d| blk: {
            const ps = try a.alloc([]const u8, d.params.len);
            for (d.params, 0..) |p, i| ps[i] = try a.dupe(u8, p);
            break :blk .{ .def = .{ .name = try a.dupe(u8, d.name), .params = ps, .body = try dupNode(a, d.body) } };
        },
        .if_ => |c| .{ .if_ = .{ .cond = try dupNode(a, c.cond), .then = try dupNode(a, c.then), .else_ = if (c.else_) |e| try dupNode(a, e) else null } },
        .for_ => |f| .{ .for_ = .{ .name = try a.dupe(u8, f.name), .iter = try dupNode(a, f.iter), .body = try dupNode(a, f.body) } },
        .while_ => |w| .{ .while_ = .{ .cond = try dupNode(a, w.cond), .body = try dupNode(a, w.body) } },
        .block => |stmts| .{ .block = try dupNodes(a, stmts) },
        .pipeline => |p| .{ .pipeline = .{ .stages = try dupNodes(a, p.stages), .redirect = if (p.redirect) |r| try a.dupe(u8, r) else null } },
        .call => |c| .{ .call = .{ .name = try a.dupe(u8, c.name), .args = try dupNodes(a, c.args) } },
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
            const fs = try a.alloc(Field, fields.len);
            for (fields, 0..) |f, i| fs[i] = .{ .key = try a.dupe(u8, f.key), .value = try dupNode(a, f.value) };
            break :blk .{ .record = fs };
        },
        .binop => |b| .{ .binop = .{ .op = b.op, .lhs = try dupNode(a, b.lhs), .rhs = try dupNode(a, b.rhs) } },
        .unop => |u| .{ .unop = .{ .op = u.op, .operand = try dupNode(a, u.operand) } },
    };
    return out;
}

fn dupNodes(a: std.mem.Allocator, ns: []const *Node) Error![]const *Node {
    const out = try a.alloc(*Node, ns.len);
    for (ns, 0..) |n, i| out[i] = try dupNode(a, n);
    return out;
}

pub fn valueEql(a: Value, b: Value) bool {
    if (std.meta.activeTag(a) != std.meta.activeTag(b)) {
        // 1 == "1" style leniency: compare through their rendering.
        if ((a == .int or a == .str or a == .bool) and (b == .int or b == .str or b == .bool)) {
            var x: [64]u8 = undefined;
            var y: [64]u8 = undefined;
            return std.mem.eql(u8, scalarText(a, &x), scalarText(b, &y));
        }
        return false;
    }
    return switch (a) {
        .nothing => true,
        .bool => a.bool == b.bool,
        .int => a.int == b.int,
        .str => std.mem.eql(u8, a.str, b.str),
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
        .table => a.table.rows.len == b.table.rows.len,
    };
}

fn scalarText(v: Value, buf: []u8) []const u8 {
    return switch (v) {
        .int => |i| std.fmt.bufPrint(buf, "{d}", .{i}) catch "",
        .str => |s| s,
        .bool => |b| if (b) "true" else "false",
        else => "",
    };
}

pub fn compareValues(a: Value, b: Value) ?std.math.Order {
    if (a == .int and b == .int) return std.math.order(a.int, b.int);
    if (a == .str and b == .str) return std.mem.order(u8, a.str, b.str);
    if (a == .bool and b == .bool) return std.math.order(@intFromBool(a.bool), @intFromBool(b.bool));
    if (a == .int and b == .str) {
        const bi = std.fmt.parseInt(i64, b.str, 10) catch return null;
        return std.math.order(a.int, bi);
    }
    if (a == .str and b == .int) {
        const ai = std.fmt.parseInt(i64, a.str, 10) catch return null;
        return std.math.order(ai, b.int);
    }
    return null;
}

/// Deep copy into another allocator (variables outlive the line arena).
pub fn dupValue(a: std.mem.Allocator, v: Value) Error!Value {
    return switch (v) {
        .nothing, .bool, .int => v,
        .str => |s| .{ .str = try a.dupe(u8, s) },
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
    };
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
        .bool, .int, .str => {
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
        .str => |s| try out.appendSlice(a, s),
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
    }
}

// ----------------------------------------------------------------- lexer

const Tok = union(enum) {
    word: []const u8,
    string: []const u8, // raw contents, escapes and $vars unprocessed
    number: i64,
    var_: []const u8,
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
    dot,
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
            ' ', '\t', '\r', '\n', '(', ')', '[', ']', '{', '}', '|', ';', '"', '$', ',', '>', '<', '=', '!' => false,
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
        if (parseNumber(w)) |n| return .{ .number = n };
        if (l.expr and w.len > 1 and w[0] == '-') {
            if (parseNumber(w[1..])) |n| return .{ .number = -n };
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

    fn parseNumber(w: []const u8) ?i64 {
        if (w.len == 0 or !std.ascii.isDigit(w[0])) return null;
        var i: usize = 0;
        var v: i64 = 0;
        while (i < w.len and std.ascii.isDigit(w[i])) : (i += 1) {
            v = std.math.mul(i64, v, 10) catch return null;
            v = std.math.add(i64, v, w[i] - '0') catch return null;
        }
        const unit = w[i..];
        const mult: i64 = if (unit.len == 0) 1 else if (std.ascii.eqlIgnoreCase(unit, "b")) 1 else if (std.ascii.eqlIgnoreCase(unit, "kb")) 1024 else if (std.ascii.eqlIgnoreCase(unit, "mb")) 1024 * 1024 else if (std.ascii.eqlIgnoreCase(unit, "gb")) 1024 * 1024 * 1024 else return null;
        return std.math.mul(i64, v, mult) catch null;
    }
};

// ------------------------------------------------------------------ AST

pub const Node = union(enum) {
    let: struct { name: []const u8, expr: *Node },
    def: struct { name: []const u8, params: []const []const u8, body: *Node },
    if_: struct { cond: *Node, then: *Node, else_: ?*Node },
    for_: struct { name: []const u8, iter: *Node, body: *Node },
    while_: struct { cond: *Node, body: *Node },
    block: []const *Node,
    pipeline: Pipeline,
    call: Call,
    lit: Value,
    word: []const u8,
    var_: []const u8,
    interp: []const StrPart,
    field: struct { base: *Node, name: []const u8 },
    list: []const *Node,
    record: []const Field,
    binop: BinOp,
    unop: struct { op: enum { not, neg }, operand: *Node },
};

const Pipeline = struct { stages: []const *Node, redirect: ?[]const u8 };
const Field = struct { key: []const u8, value: *Node };
const Call = struct { name: []const u8, args: []const *Node };
const BinOp = struct { op: Op, lhs: *Node, rhs: *Node };
const StrPart = union(enum) { text: []const u8, var_: []const u8 };

// --------------------------------------------------------------- parser

const Parser = struct {
    it: *Interp,
    lex: Lexer,
    tok: Tok = .eof,
    peeked: bool = false,
    tok_start: usize = 0,

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
        const stmts = try p.program();
        if (p.peekAt() != .rbrace) return p.syntax("'}}' expected", .{});
        _ = p.take();
        return p.mk(.{ .block = stmts });
    }

    fn stmt(p: *Parser) Error!*Node {
        p.setExpr(false);
        const t = p.peekAt();
        if (isWord(t, "let")) {
            _ = p.take();
            const name = p.take();
            if (name != .word) return p.syntax("let: name expected", .{});
            p.setExpr(true);
            const eq = p.peekAt();
            if (eq != .op or eq.op != .assign) return p.syntax("let: '=' expected", .{});
            _ = p.take();
            const e = try p.expr();
            return p.mk(.{ .let = .{ .name = name.word, .expr = e } });
        }
        if (isWord(t, "def")) {
            _ = p.take();
            const name = p.take();
            if (name != .word) return p.syntax("def: name expected", .{});
            var params: std.ArrayList([]const u8) = .empty;
            if (p.peekAt() == .lbracket) {
                _ = p.take();
                while (true) {
                    const q = p.take();
                    switch (q) {
                        .rbracket => break,
                        .comma => continue,
                        .word => |w| try params.append(p.a(), w),
                        else => return p.syntax("def: parameter name expected", .{}),
                    }
                }
            }
            const body = try p.block();
            return p.mk(.{ .def = .{ .name = name.word, .params = params.items, .body = body } });
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

    /// A pipeline stage: a command call, or a bare expression.
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
                while (true) {
                    p.setExpr(false);
                    const n = p.peekAt();
                    switch (n) {
                        .eof, .pipe, .semi, .newline, .rparen, .rbrace, .redirect => break,
                        else => try args.append(p.a(), try p.arg()),
                    }
                }
            }
            return p.mk(.{ .call = .{ .name = t.word, .args = args.items } });
        }
        p.setExpr(true);
        return p.expr();
    }

    fn looksNumeric(w: []const u8) bool {
        if (w.len == 0) return false;
        if (std.ascii.isDigit(w[0])) return true;
        return w.len > 1 and w[0] == '-' and std.ascii.isDigit(w[1]);
    }

    fn isKeywordStart(w: []const u8) bool {
        return std.mem.eql(u8, w, "true") or std.mem.eql(u8, w, "false") or std.mem.eql(u8, w, "null") or std.mem.eql(u8, w, "not");
    }

    /// A command argument (command context: '>' is not an operator, '-x'
    /// is a flag word).
    fn arg(p: *Parser) Error!*Node {
        const t = p.peekAt();
        switch (t) {
            .word => |w| {
                _ = p.take();
                if (std.mem.eql(u8, w, "true")) return p.mk(.{ .lit = .{ .bool = true } });
                if (std.mem.eql(u8, w, "false")) return p.mk(.{ .lit = .{ .bool = false } });
                if (std.mem.eql(u8, w, "null")) return p.mk(.{ .lit = .nothing });
                return p.mk(.{ .lit = .{ .str = w } });
            },
            .number => |n| {
                _ = p.take();
                return p.mk(.{ .lit = .{ .int = n } });
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
            .lbrace => return p.block(),
            else => return p.syntax("unexpected token in arguments", .{}),
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
    /// so bare words may still contain dots (hi.txt, 10.77.0.1).
    fn postfix(p: *Parser) Error!*Node {
        var base = try p.primary();
        while (!p.peeked and p.lex.pos < p.lex.src.len and p.lex.src[p.lex.pos] == '.') {
            p.lex.pos += 1;
            const start = p.lex.pos;
            while (p.lex.pos < p.lex.src.len and (std.ascii.isAlphanumeric(p.lex.src[p.lex.pos]) or p.lex.src[p.lex.pos] == '_' or p.lex.src[p.lex.pos] == '-')) p.lex.pos += 1;
            if (p.lex.pos == start) return p.syntax("field name expected after '.'", .{});
            base = try p.mk(.{ .field = .{ .base = base, .name = p.lex.src[start..p.lex.pos] } });
        }
        return base;
    }

    fn primary(p: *Parser) Error!*Node {
        const t = p.take();
        switch (t) {
            .number => |n| return p.mk(.{ .lit = .{ .int = n } }),
            .string => |s| return p.stringNode(s),
            .var_ => |name| return p.mk(.{ .var_ = name }),
            .word => |w| {
                if (std.mem.eql(u8, w, "true")) return p.mk(.{ .lit = .{ .bool = true } });
                if (std.mem.eql(u8, w, "false")) return p.mk(.{ .lit = .{ .bool = false } });
                if (std.mem.eql(u8, w, "null")) return p.mk(.{ .lit = .nothing });
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
                p.peeked = false;
                p.lex.pos = p.tok_start;
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
        var fields: std.ArrayList(Field) = .empty;
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
};

// ------------------------------------------------------------------ tests

const TestHost = struct {
    saved_path: []const u8 = "",
    saved_text: []const u8 = "",

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
        return null;
    }
};

fn testInterp(host: *TestHost, arena: std.mem.Allocator) Interp {
    // Variables and functions persist in the same arena here; msh gives
    // them a region of their own.
    return Interp.init(arena, arena, .{ .ctx = host, .call = TestHost.call });
}

fn expectOut(it: *Interp, src: []const u8, expected: []const u8) !void {
    _ = it.run(src) catch |e| {
        std.debug.print("error {t}: {s}\n", .{ e, it.err_msg });
        return e;
    };
    try std.testing.expectEqualStrings(expected, it.out.items);
}

test "arithmetic, comparison, logic, units" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "1 + 2 * 3", "7\n");
    try expectOut(&it, "(1 + 2) * 3", "9\n");
    try expectOut(&it, "10 / 3", "3\n");
    try expectOut(&it, "4kb", "4096\n");
    try expectOut(&it, "3 > 2 and not false", "true\n");
    try expectOut(&it, "1 == 1 or 1 == 2", "true\n");
    try expectOut(&it, "\"a\" + \"b\"", "ab\n");
    try expectOut(&it, "-5 + 2", "-3\n");
}

test "let, if, for, while, interpolation" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "let x = 3; $x * 2", "6\n");
    try expectOut(&it, "if $x == 3 { echo yes } else { echo no }", "yes\n");
    try expectOut(&it, "if $x == 4 { echo yes } else if $x == 3 { echo three } else { echo no }", "three\n");
    try expectOut(&it, "let n = 0; while $n < 3 { let n = $n + 1 }; $n", "3\n");
    try expectOut(&it, "for i in [1, 2, 3] { echo \"i=$i\" }", "i=3\n");
    try expectOut(&it, "let name = \"moss\"; echo \"hello $name!\"", "hello moss!\n");
}

test "pipelines over tables: where, sort-by, select, get, first, len" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "ls | len", "3\n");
    try expectOut(&it, "ls | where size > 1kb | get name", "big.bin\n");
    try expectOut(&it, "ls | where type == dir | select name", "name\n----\nsub\n");
    try expectOut(&it, "ls | sort-by size --desc | first 1 | get name", "big.bin\n");
    try expectOut(&it, "ls | sort-by name | get name", "big.bin\nhi.txt\nsub\n");
    try expectOut(&it, "(ls | where name == \"hi.txt\").0.size", "27\n");
    try expectOut(&it, "(stat data).type == dir", "true\n");
    try expectOut(&it, "ls | reverse | first 1 | get type", "dir\n");
    try expectOut(&it, "ls | keys", "name\ntype\nsize\n");
    try expectOut(&it, "\"a\\nb\" | lines | len", "2\n");
    try expectOut(&it, "[3, 1, 2] | where $it > 1 | len", "2\n");
    try expectOut(&it, "ls | select name size", "name     size\n-------  ----\nhi.txt   27\nbig.bin  8192\nsub      0\n");
}

test "redirection renders and saves through the host" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    defer std.testing.allocator.free(host.saved_path);
    defer std.testing.allocator.free(host.saved_text);
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "ls | get name > data/list.txt", "");
    try std.testing.expectEqualStrings("data/list.txt", host.saved_path);
    try std.testing.expectEqualStrings("hi.txt\nbig.bin\nsub\n", host.saved_text);
}

test "errors carry messages" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try std.testing.expectError(Error.Runtime, it.run("frobnicate 1"));
    try std.testing.expectEqualStrings("unknown command 'frobnicate'", it.err_msg);
    try std.testing.expectError(Error.Syntax, it.run("if true { echo x"));
    try std.testing.expectError(Error.Runtime, it.run("1 / 0"));
    try std.testing.expectError(Error.Runtime, it.run("$nope"));
    try std.testing.expectEqualStrings("unknown variable $nope", it.err_msg);
}

test "record literals and the strict data parser" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    // At the prompt, a record is a value like any other.
    try expectOut(&it, "{ a: 1, b: two }", "a: 1\nb: two\n");
    try expectOut(&it, "{ a: 1, b: two }.b", "two\n");
    try expectOut(&it, "{ x: (1 + 2) }.x", "3\n");
    try expectOut(&it, "if true { echo block }", "block\n"); // braces still block

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
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "def twice [x] { $x * 2 }", "");
    try expectOut(&it, "twice 21", "42\n");
    try expectOut(&it, "def big { $in | where size > 1kb | get name }", "");
    try expectOut(&it, "ls | big", "big.bin\n");
    try expectOut(&it, "def greet [who] { echo \"hi $who\" }; greet moss", "hi moss\n");
    try std.testing.expectError(Error.Runtime, it.run("twice 1 2"));
}

test "to-data / from-data round-trip through the strict parser" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "ls | to-data | from-data | where size > 1kb | get name", "big.bin\n");
    try expectOut(&it, "[1, \"two words\", true, null] | to-data", "[1, \"two words\", true, null]\n");
    try expectOut(&it, "{ a: \"x:y\", b: [1] } | to-data | from-data | get a", "x:y\n");
    try expectOut(&it, "\"a\\\"b\" | to-data | from-data", "a\"b\n");
    try expectOut(&it, "ls | to-data | from-data | len", "3\n");
}

test "scripts render every statement's value" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    var out: std.ArrayList(u8) = .empty;
    try it.evalScript("echo one\nlet x = 2\n$x\ndef f { 3 }\nf", &out);
    try std.testing.expectEqualStrings("one\n2\n3\n", out.items);
}

test "records render as key: value lines; tables align" {
    var arena_state = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena_state.deinit();
    var host = TestHost{};
    var it = testInterp(&host, arena_state.allocator());
    try expectOut(&it, "stat data", "type: dir\nsize: 0\n");
    try expectOut(&it, "echo a b 3", "a b 3\n");
}
