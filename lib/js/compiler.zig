//! The compiler: a syntax tree to `Code` cells, one per function, with
//! the scope analysis of `scope.zig` deciding where each binding lives.
//! Expressions compile destination-driven — `expr(node, dst)` puts the
//! value in `dst`, or in any register when the caller does not care —
//! over a stack of temporaries above the function's locals, so most
//! operators read their operands straight from the registers that hold
//! them. Control flow is the classic structured-jump scheme, with
//! `finally` blocks compiled once and dispatched through a completion
//! register (§14.15: try statements), and `break`/`continue`/`return`
//! that cross a `finally` or a for-of routed through it.
const std = @import("std");
const ast = @import("ast.zig");
const scope = @import("scope.zig");
const bytecode = @import("bytecode.zig");
const heap = @import("heap.zig");
const string = @import("string.zig");
const value = @import("value.zig");
const parser = @import("parser.zig");
const Node = ast.Node;
const Op = bytecode.Op;
const Insn = bytecode.Insn;
const Code = bytecode.Code;
const CodeData = bytecode.CodeData;
const Value = value.Value;
const String = string.String;
const Scope = scope.Scope;
const Binding = scope.Binding;

pub const Error = error{ OutOfMemory, SyntaxError };

pub const Options = struct {
    module: bool = false,
    strict: bool = false,
    /// Eval code: resolves free names against this environment chain.
    eval_env: ?*bytecode.Env = null,
    eval_ctx: scope.Analysis.EvalContext = .{},
    name: []const u8 = "<script>",
    /// The module record, for module code.
    module_record: ?*anyopaque = null,
    /// Where the compile's transient memory comes from — the AST, the
    /// analysis, the tables while they grow (a big site's bundle takes
    /// tens of megabytes of it for a moment) — when not `a`: an
    /// embedder's scratch, so the bookkeeping heap keeps only the code.
    scratch: ?std.mem.Allocator = null,
    /// Functions compile on their first call (`compileLazy`); off, every
    /// function compiles with its script (tests of the emitter, mostly).
    lazy: bool = true,
};

/// Compile a program; the result is the script's top-level code.
/// The compile's scratch arena: chunks of this size, freed together.
pub const scratch_chunk: usize = 512 << 10;

pub fn compile(a: std.mem.Allocator, h: *heap.Heap, strings: *string.Strings, src: []const u8, opts: Options) Error!*Code {
    var arena = @import("scratch.zig").ChunkArena.init(opts.scratch orelse a, scratch_chunk);
    defer arena.deinit();
    const scratch = arena.allocator();
    var p = parser.Parser.init(scratch, src, .{
        .module = opts.module,
        .strict = opts.strict,
        .in_function = opts.eval_ctx.has_this_function,
        .allow_new_target = opts.eval_ctx.allow_new_target,
        .allow_super_property = opts.eval_ctx.allow_super,
        .allow_super_call = opts.eval_ctx.allow_super_call,
        .no_arguments = opts.eval_ctx.no_arguments,
        .private_names = opts.eval_ctx.private_names,
    });
    const prog = p.parseProgram() catch |e| {
        last_error = p.err;
        last_error_at = p.err_at;
        return e;
    };
    var an = scope.Analysis.init(scratch);
    defer an.deinit();
    an.eval_mode = opts.eval_env != null or opts.eval_ctx.eval;
    an.eval_ctx = opts.eval_ctx;
    try an.analyzeProgram(prog);
    const source = try a.create(bytecode.Source);
    source.* = .{ .text = try a.dupe(u8, src), .refs = 0, .name = try a.dupe(u8, opts.name) };
    var c = Compiler{ .a = a, .scratch = scratch, .heap = h, .strings = strings, .an = &an, .source = source, .eval_env = opts.eval_env, .eval_mode = an.eval_mode, .module_record = opts.module_record, .lazy = opts.lazy };
    defer c.env_stack.deinit(scratch);
    defer c.pending_labels.deinit(scratch);
    const code = c.program(prog) catch |e| {
        if (source.refs == 0) {
            a.free(source.text);
            a.free(source.name);
            a.destroy(source);
        }
        return e;
    };
    return code;
}

/// Compile a stub (see `Compiler.lazyStub`) now that it is called: its
/// source parsed again from where it starts, analysed as code whose
/// outer names resolve against the closure's runtime environment chain
/// — the way eval code resolves its caller's — and emitted into the
/// stub's own record, so every closure of the function shares the
/// result. `private_names`: the enclosing classes', from the chain.
pub fn compileLazy(a: std.mem.Allocator, h: *heap.Heap, strings: *string.Strings, code: *Code, env: ?*bytecode.Env, private_names: []const []const u8, scratch_opt: ?std.mem.Allocator) Error!void {
    const d = code.data;
    if (!d.lazy) return;
    const src = d.source.?;
    stats.lazy_compiles += 1;
    stats.lazy_source_bytes += d.end - d.start;
    // A small function's compile takes a small chunk.
    var arena = @import("scratch.zig").ChunkArena.init(scratch_opt orelse a, @min(scratch_chunk, @max(16 << 10, (d.end - d.start) * 8)));
    defer arena.deinit();
    const scratch = arena.allocator();
    var p = parser.Parser.init(scratch, src.text, .{
        .module = d.module != null,
        .strict = d.strict,
        .in_function = true,
        .allow_new_target = true,
        .allow_super_property = true,
        .allow_super_call = true,
        .private_names = private_names,
    });
    const is_decl = d.lazy_form == 1;
    const fnode: *ast.Node = if (d.lazy_form == 2) blk: {
        // A method: parsed from its parameter list, its kind and
        // colouring from the stub.
        const parse_kind: ast.Function.Kind = switch (d.kind) {
            .getter => .getter,
            .setter => .setter,
            else => .method,
        };
        const is_async = d.kind == .async_function or d.kind == .async_generator;
        const is_generator = d.kind == .generator or d.kind == .async_generator;
        const mf = p.parseMethodAt(d.lazy_params, parse_kind, is_async, is_generator) catch |e| {
            last_error = p.err;
            last_error_at = p.err_at;
            return e;
        };
        mf.is_generator = is_generator;
        const n = try scratch.create(ast.Node);
        n.* = .{ .pos = d.start, .data = .{ .function = mf } };
        break :blk n;
    } else p.parseFunctionAt(d.start, is_decl) catch |e| {
        last_error = p.err;
        last_error_at = p.err_at;
        return e;
    };
    const f = if (is_decl) fnode.data.function_decl else fnode.data.function;
    const name_text: ?[]const u8 = if (d.name) |n| n.latin1() else null;
    // The analysis and the emitter want a program at the root: one
    // holding the function, never run. A declaration is a statement
    // of it (an expression would bind its name inside).
    const stmt = if (is_decl) fnode else blk: {
        const st = try scratch.create(ast.Node);
        st.* = .{ .pos = fnode.pos, .data = .{ .expr_stmt = fnode } };
        break :blk st;
    };
    const body = try scratch.alloc(*ast.Node, 1);
    body[0] = stmt;
    const prog = try scratch.create(ast.Node);
    prog.* = .{ .pos = fnode.pos, .data = .{ .program = .{ .body = body, .module = false, .strict = d.strict } } };
    var an = scope.Analysis.init(scratch);
    defer an.deinit();
    an.eval_mode = true;
    an.eval_ctx = .{ .has_this_function = true, .allow_new_target = true, .allow_super = true, .strict = d.strict, .global = false, .private_names = private_names };
    try an.analyzeProgram(prog);
    // A declaration's name is the enclosing scope's binding, on the
    // runtime chain: the root's own goes.
    if (is_decl) if (f.name) |n| {
        _ = an.root.bindings.swapRemove(n);
    };
    var c = Compiler{ .a = a, .scratch = scratch, .heap = h, .strings = strings, .an = &an, .source = src, .eval_env = env, .eval_mode = true, .module_record = d.module, .lazy_root = true };
    defer c.env_stack.deinit(scratch);
    defer c.pending_labels.deinit(scratch);
    var fs = FuncState{ .func = an.root_func, .parent = null, .strict = an.root_func.strict, .env_base = 0 };
    defer fs.deinit(scratch);
    c.fs = &fs;
    c.scope = an.root;
    const built = try c.function(f, name_text orelse f.name);
    // The stub's record becomes the code; the fresh record takes the
    // stub's empty tables and goes with its own cell, unreferenced.
    const stub = d.*;
    d.* = built.data.*;
    built.data.* = stub;
}

/// What the compiles added up to, for a tool's report.
pub var stats: struct { stubs: usize = 0, eager: usize = 0, lazy_compiles: usize = 0, lazy_source_bytes: usize = 0, not_normal: usize = 0, dynamic: usize = 0, in_params: usize = 0, super_arrow: usize = 0, called_at_once: usize = 0 } = .{};

/// Parse and compile errors: where and what (the last one).
pub var last_error: []const u8 = "";
pub var last_error_at: u32 = 0;

const Ref = union(enum) {
    reg: u16,
    env: struct { hops: u16, slot: u16, lexical: bool },
    global: u32,
    /// By name at run time (with / eval): the name's constant.
    dynamic: u32,
    /// A const binding in a register or slot: assignment throws.
    const_reg: u16,
    const_env: struct { hops: u16, slot: u16 },
    /// A named function expression's own name: readable, assignment is
    /// silent in sloppy code and a TypeError in strict code.
    fn_name: struct { strict: bool, reg: ?u16, hops: u16, slot: u16 },
    /// An import binding: read through its cell, never assigned.
    import: struct { hops: u16, slot: u16 },
    /// Assignment not allowed at all.
    immutable,
};

const Control = union(enum) {
    /// A loop or a labeled/breakable statement.
    target: struct {
        labels: []const []const u8,
        is_loop: bool,
        breaks: std.ArrayList(u32) = .empty,
        continues: std.ArrayList(u32) = .empty,
        /// The register a switch or labeled block leaves scoped temps at.
        top: u16,
    },
    /// A scope whose environment must be popped on the way out.
    env,
    /// A try region to pop on the way out.
    try_region,
    /// A for-of's iterator to close on the way out.
    for_of: struct { iter: u16, is_await: bool = false },
    /// A `finally`: jumps out through it set the completion register.
    finally: struct {
        kind: u16,
        val: u16,
        entries: std.ArrayList(u32) = .empty, // jumps to the finally body
        pending: std.ArrayList(Pending) = .empty,
    },
    const Pending = struct { id: i32, target: usize, is_continue: bool };
};

const FuncState = struct {
    func: *scope.Func,
    parent: ?*FuncState,
    insns: std.ArrayList(Insn) = .empty,
    consts: std.ArrayList(Value) = .empty,
    const_strings: std.StringHashMapUnmanaged(u32) = .empty,
    functions: std.ArrayList(*Code) = .empty,
    props: std.ArrayList(bytecode.PropSite) = .empty,
    globals: std.ArrayList(bytecode.GlobalSite) = .empty,
    scopes: std.ArrayList(*bytecode.ScopeInfo) = .empty,
    templates: std.ArrayList(bytecode.TemplateSite) = .empty,
    positions: std.ArrayList(bytecode.Position) = .empty,
    controls: std.ArrayList(Control) = .empty,
    /// Compiling the parameter defaults (see `lazyEligible`).
    in_params: bool = false,
    top: u16 = 0,
    max: u16 = 0,
    nparams: u16 = 0,
    strict: bool,
    /// The env stack height at function entry: hops never reach below.
    env_base: usize,
    finally_ids: i32 = 3,
    /// Mapped arguments: the slot of each parameter (see CodeData).
    param_slots: []u32 = &.{},
    /// A coroutine body: yields/awaits suspend the frame.
    co: enum { none, generator, async_fn, async_gen } = .none,
    /// The register holding `this` for the whole body (a non-arrow
    /// function that uses it and is not a derived constructor): every
    /// `this.x` reads it directly instead of loading it first.
    this_reg: ?u16 = null,
    /// The register holding the class's home object for methods
    /// compiled inline (class bodies): none.
    last_pos: u32 = 0,

    fn deinit(f: *FuncState, a: std.mem.Allocator) void {
        f.insns.deinit(a);
        f.consts.deinit(a);
        f.const_strings.deinit(a);
        f.functions.deinit(a);
        f.props.deinit(a);
        f.globals.deinit(a);
        f.scopes.deinit(a);
        f.templates.deinit(a);
        f.positions.deinit(a);
        for (f.controls.items) |*ctl| switch (ctl.*) {
            .target => |*t| {
                t.breaks.deinit(a);
                t.continues.deinit(a);
            },
            .finally => |*fi| {
                fi.entries.deinit(a);
                fi.pending.deinit(a);
            },
            else => {},
        };
        f.controls.deinit(a);
    }
};

pub const Compiler = struct {
    a: std.mem.Allocator,
    /// The compile's transient memory (see `Options.scratch`).
    scratch: std.mem.Allocator,
    heap: *heap.Heap,
    strings: *string.Strings,
    an: *scope.Analysis,
    source: *bytecode.Source,
    fs: *FuncState = undefined,
    scope: *Scope = undefined,
    /// Scopes with an environment on the chain, outermost first.
    env_stack: std.ArrayList(*Scope) = .empty,
    pending_labels: std.ArrayList([]const u8) = .empty,
    eval_env: ?*bytecode.Env,
    eval_mode: bool,
    module_record: ?*anyopaque = null,
    /// The optional chain being compiled: where `?.` short-circuits to.
    chain: ?*Chain = null,
    /// Script/eval code: the register statements leave their completion
    /// value in (§14: UpdateEmpty); null inside functions.
    completion: ?u16 = null,
    /// Nested functions become stubs, compiled on first call.
    lazy: bool = true,
    /// This compile is a stub's (`compileLazy`): an outer name the
    /// runtime chain does not hold is a global, not a dynamic lookup,
    /// and an arrow's `this` is the chain's or the global one.
    lazy_root: bool = false,

    const Chain = struct { dst: u16, jumps: std.ArrayList(u32) = .empty };

    fn fail(c: *Compiler, msg: []const u8, at: u32) Error {
        _ = c;
        last_error = msg;
        last_error_at = at;
        return error.SyntaxError;
    }

    // ------------------------------------------------------ emission

    fn emit(c: *Compiler, op: Op, a: u16, b: u16, cc: u16) Error!void {
        try c.fs.insns.append(c.scratch, .{ .op = op, .a = a, .b = b, .c = cc });
    }
    fn emitBc(c: *Compiler, op: Op, a: u16, bc: u32) Error!void {
        try c.fs.insns.append(c.scratch, Insn.withBc(op, a, bc));
    }
    fn pc(c: *Compiler) u32 {
        return @intCast(c.fs.insns.items.len);
    }
    /// A jump to patch later: returns its index.
    fn jump(c: *Compiler, op: Op, a: u16) Error!u32 {
        const at = c.pc();
        try c.emitBc(op, a, 0);
        return at;
    }
    fn patch(c: *Compiler, at: u32, target: u32) void {
        const i = &c.fs.insns.items[at];
        i.* = Insn.withBc(i.op, i.a, target);
    }
    fn patchHere(c: *Compiler, at: u32) void {
        c.patch(at, c.pc());
    }
    fn pos(c: *Compiler, p: u32) Error!void {
        if (p == c.fs.last_pos) return;
        c.fs.last_pos = p;
        try c.fs.positions.append(c.scratch, .{ .pc = c.pc(), .pos = p });
    }

    fn tmp(c: *Compiler) Error!u16 {
        const r = c.fs.top;
        if (r == std.math.maxInt(u16)) return c.fail("too many registers", 0);
        c.fs.top += 1;
        if (c.fs.top > c.fs.max) c.fs.max = c.fs.top;
        return r;
    }
    fn tmps(c: *Compiler, n: u16) Error!u16 {
        const r = c.fs.top;
        if (@as(u32, r) + n >= std.math.maxInt(u16)) return c.fail("too many registers", 0);
        c.fs.top += n;
        if (c.fs.top > c.fs.max) c.fs.max = c.fs.top;
        return r;
    }
    fn release(c: *Compiler, to: u16) void {
        c.fs.top = to;
    }

    fn constString(c: *Compiler, s: []const u8) Error!u32 {
        if (c.fs.const_strings.get(s)) |i| return i;
        const atom = try c.strings.atom(s);
        const i: u32 = @intCast(c.fs.consts.items.len);
        try c.fs.consts.append(c.scratch, Value.fromCell(atom.cell()));
        try c.fs.const_strings.put(c.scratch, s, i);
        return i;
    }
    fn constNumber(c: *Compiler, d: f64) Error!u32 {
        const v = Value.fromF64(d);
        for (c.fs.consts.items, 0..) |x, i| if (x.eqlBits(v)) return @intCast(i);
        const i: u32 = @intCast(c.fs.consts.items.len);
        try c.fs.consts.append(c.scratch, v);
        return i;
    }
    fn propSite(c: *Compiler, name: []const u8) Error!u16 {
        const atom = try c.strings.atom(name);
        const i = c.fs.props.items.len;
        if (i >= std.math.maxInt(u16)) return c.fail("too many property sites", 0);
        try c.fs.props.append(c.scratch, .{ .key = atom });
        return @intCast(i);
    }
    fn globalSite(c: *Compiler, name: []const u8) Error!u32 {
        const atom = try c.strings.atom(name);
        const i: u32 = @intCast(c.fs.globals.items.len);
        try c.fs.globals.append(c.scratch, .{ .name = atom });
        return i;
    }

    // ---------------------------------------------------- programs

    fn program(c: *Compiler, prog: *Node) Error!*Code {
        const p = prog.data.program;
        var fs = FuncState{ .func = c.an.root_func, .parent = null, .strict = c.an.root_func.strict, .env_base = 0 };
        defer fs.deinit(c.scratch);
        c.fs = &fs;
        c.scope = c.an.root;
        // The completion value of the script (eval's result).
        const result = try c.tmp();
        try c.emit(.ldundef, result, 0, 0);
        c.completion = result;
        // A module: its body is a coroutine (top-level await), suspended
        // once its environment and hoisted functions exist; it has no
        // completion value (its promise resolves with undefined).
        if (p.module) {
            fs.co = .async_fn;
            c.completion = null;
        }
        try c.enterScope(c.an.root);
        if (p.module) try c.emit(.modinit, 0, 0, 0);
        for (p.body) |st| try c.stmt(st);
        try c.leaveScope(c.an.root);
        try c.emit(.ret, result, 0, 0);
        return c.finish(&fs, null, if (p.module) .async_function else .normal, 0, 0);
    }

    /// A statement whose completion is undefined unless its body says
    /// otherwise (if, loops, switch, try): reset the register first.
    fn completionUndefined(c: *Compiler) Error!void {
        if (c.completion) |r| try c.emit(.ldundef, r, 0, 0);
    }

    fn finish(c: *Compiler, fs: *FuncState, name: ?[]const u8, kind: bytecode.FunctionKind, start: u32, end: u32) Error!*Code {
        stats.eager += 1;
        const d = try c.a.create(CodeData);
        d.* = .{};
        // The tables grew in scratch; the code keeps exact-size copies.
        d.insns = try c.a.dupe(Insn, fs.insns.items);
        d.consts = try c.a.dupe(Value, fs.consts.items);
        d.functions = try c.a.dupe(*Code, fs.functions.items);
        d.props = try c.a.dupe(bytecode.PropSite, fs.props.items);
        d.globals = try c.a.dupe(bytecode.GlobalSite, fs.globals.items);
        d.scopes = try c.a.dupe(*bytecode.ScopeInfo, fs.scopes.items);
        d.templates = try c.a.dupe(bytecode.TemplateSite, fs.templates.items);
        d.positions = try c.a.dupe(bytecode.Position, fs.positions.items);
        d.nregs = fs.max;
        d.nparams = fs.nparams;
        d.param_slots = fs.param_slots;
        d.kind = kind;
        d.strict = fs.strict;
        d.source = c.source;
        c.source.refs += 1;
        d.module = c.module_record;
        d.start = start;
        d.end = end;
        if (name) |n| d.name = try c.strings.atom(n);
        const f = fs.func;
        d.uses_this = f.uses_this;
        d.uses_arguments = f.uses_arguments;
        d.has_direct_eval = f.has_direct_eval;
        if (f.node) |n| {
            d.length = 0;
            for (n.params) |p| {
                if (p.data == .rest or p.data == .assign_pattern) break;
                d.length += 1;
            }
            d.is_constructor = switch (kind) {
                .normal, .class_constructor, .derived_constructor => true,
                else => false,
            };
        }
        const cell = try c.heap.alloc(.code, @sizeOf(Code));
        const code = cell.as(Code);
        code.data = d;
        return code;
    }

    // ------------------------------------------------------- scopes

    /// Enter a scope: decide storage, push its environment if it has
    /// one, initialize TDZ registers and instantiate hoisted functions.
    fn enterScope(c: *Compiler, s: *Scope) Error!void {
        const fs = c.fs;
        const dyn = s.func.dynamic;
        const is_global = s.kind == .script;
        const is_eval_root = s.kind == .eval;
        var names: std.ArrayList(*String) = .empty;
        defer names.deinit(c.a);
        var consts: std.ArrayList(bool) = .empty;
        defer consts.deinit(c.a);
        var lexical: std.ArrayList(bool) = .empty;
        defer lexical.deinit(c.a);
        var imports: std.ArrayList(bool) = .empty;
        defer imports.deinit(c.a);
        for (s.bindings.values()) |b| {
            if (b.loc != .unresolved) continue;
            if (is_global) {
                b.loc = .global;
                continue;
            }
            if (is_eval_root and !fs.strict and (b.kind == .@"var" or b.kind == .function or b.kind == .implicit)) {
                // eval's vars go to the caller's variable environment.
                b.loc = .global;
                continue;
            }
            if (b.captured or dyn or s.kind == .module or s.kind == .with) {
                b.loc = .{ .slot = @intCast(names.items.len) };
                try names.append(c.a, try c.strings.atom(b.name));
                try consts.append(c.a, b.is_const);
                try lexical.append(c.a, b.lexical);
                try imports.append(c.a, b.kind == .import);
            } else if (b.kind == .param) {
                // A simple parameter has its register already; one bound by
                // a pattern (a rest parameter, a destructured one) gets its
                // own here — left unresolved, its name was looked up at
                // run time and landed on a captured outer binding of the
                // same name (`function(...e)` beside `const e`, 2026-09-28).
                b.loc = .{ .reg = try c.tmp() };
            } else {
                b.loc = .{ .reg = try c.tmp() };
            }
        }
        if (names.items.len > 0 or dyn or s.kind == .with or s.kind == .module or (s.kind == .function and s.func.has_direct_eval)) {
            const info = try c.a.create(bytecode.ScopeInfo);
            info.* = .{
                .names = try names.toOwnedSlice(c.a),
                .consts = try consts.toOwnedSlice(c.a),
                .lexical = try lexical.toOwnedSlice(c.a),
                .imports = try imports.toOwnedSlice(c.a),
                .is_function = s.kind == .function or s.kind == .params or s.kind == .eval or s.kind == .module,
                .is_with = s.kind == .with,
                .dynamic = s.kind == .function and s.func.has_direct_eval,
            };
            const idx: u32 = @intCast(fs.scopes.items.len);
            try fs.scopes.append(c.scratch, info);
            if (s.kind != .with) try c.emitBc(.pushenv, 0, idx);
            s.has_env = true;
            try c.env_stack.append(c.scratch, s);
        }
        // Script code: GlobalDeclarationInstantiation — vars become global
        // object properties, lexical declarations global lexical bindings.
        if (is_global) {
            for (s.bindings.values()) |b| switch (b.kind) {
                .@"var" => try c.emitBc(.declvar, 0, try c.constString(b.name)),
                .let, .@"const", .class => try c.emitBc(.decllex, if (b.is_const) 1 else 0, try c.constString(b.name)),
                else => {},
            };
        }
        // Sloppy eval code: EvalDeclarationInstantiation puts its vars in
        // the caller's variable environment before anything runs.
        if (is_eval_root and !fs.strict) {
            for (s.bindings.values()) |b| if (b.kind == .@"var") try c.emitBc(.declvar, 0, try c.constString(b.name));
        }
        // TDZ for lexical registers; block functions are not lexical.
        for (s.bindings.values()) |b| if (b.loc == .reg and b.lexical) try c.emit(.ldempty, b.loc.reg, 0, 0);
        // Parameters captured into slots: copied by the prologue (function).
        // Hoisted function declarations.
        for (s.hoisted.items) |fnode| {
            const f = if (fnode.data == .function_decl) fnode.data.function_decl else fnode.data.function;
            const name = f.name orelse "*default*";
            const r = try c.tmp();
            try c.closureDecl(f, r, f.name orelse "default", fnode.data == .function_decl);
            if (s.kind == .eval or s.kind == .script) {
                try c.emit(.declfunc, 0, @intCast(try c.constString(name)), r);
            } else {
                const ref = c.resolve(name);
                try c.initialize(ref, r, name);
            }
            c.release(r);
        }
    }

    fn leaveScope(c: *Compiler, s: *Scope) Error!void {
        if (s.has_env) {
            _ = c.env_stack.pop();
            if (s.kind != .with) try c.emit(.popenv, 0, 0, 0);
            s.has_env = false;
        }
    }

    /// Resolve `name` from the current scope.
    fn resolve(c: *Compiler, name: []const u8) Ref {
        var cur: ?*Scope = c.scope;
        var crossed_with = false;
        var crossed_dynamic = false;
        while (cur) |s| : (cur = s.parent) {
            if (s.kind == .with) crossed_with = true;
            if (s.bindings.get(name)) |b| {
                if (crossed_with or s.func.has_eval_refs or crossed_dynamic) return .{ .dynamic = c.constString(name) catch 0 };
                const is_fn_name = b.kind == .@"const" and !b.lexical and s.kind == .block and isFnNameScope(s, name);
                switch (b.loc) {
                    .reg => |r| {
                        if (is_fn_name) return .{ .fn_name = .{ .strict = c.fs.strict, .reg = r, .hops = 0, .slot = 0 } };
                        if (b.is_const) return .{ .const_reg = r };
                        return .{ .reg = r };
                    },
                    .slot => |slot| {
                        const hops = c.hopsTo(s);
                        if (b.kind == .import) return .{ .import = .{ .hops = hops, .slot = @intCast(slot) } };
                        if (is_fn_name) return .{ .fn_name = .{ .strict = c.fs.strict, .reg = null, .hops = hops, .slot = @intCast(slot) } };
                        if (b.is_const) return .{ .const_env = .{ .hops = hops, .slot = @intCast(slot) } };
                        return .{ .env = .{ .hops = hops, .slot = @intCast(slot), .lexical = b.lexical } };
                    },
                    .global => return .{ .global = c.globalSite(name) catch 0 },
                    .unresolved => return .{ .dynamic = c.constString(name) catch 0 },
                }
            }
            if (s.func.has_eval_refs and (s.kind == .function or s.kind == .eval)) crossed_dynamic = true;
        }
        if (crossed_with or crossed_dynamic or c.eval_env != null) {
            // Eval code: the runtime chain may resolve it to a slot. A
            // stub's compile whose chain has no such name, and nothing
            // dynamic, has a global — what its eager compile would have.
            if (c.eval_env) |env| if (!crossed_with and !crossed_dynamic) {
                switch (c.resolveRuntime(env, name)) {
                    .found => |r| return r,
                    .absent => if (c.lazy_root) return .{ .global = c.globalSite(name) catch 0 },
                    .unknown => {},
                }
            };
            return .{ .dynamic = c.constString(name) catch 0 };
        }
        return .{ .global = c.globalSite(name) catch 0 };
    }

    fn isFnNameScope(s: *Scope, name: []const u8) bool {
        // A named function expression's name scope holds exactly one const
        // binding that is not lexical.
        _ = name;
        return s.bindings.count() == 1;
    }

    /// Eval code: resolve against the runtime environment chain.
    const RuntimeRef = union(enum) { found: Ref, absent, unknown };

    fn resolveRuntime(c: *Compiler, env: *bytecode.Env, name: []const u8) RuntimeRef {
        // Every compile-time environment of the eval code sits above the
        // runtime chain it was given.
        var hops: u16 = @intCast(c.env_stack.items.len);
        // The layouts hold atoms: the name's atom is the same cell (a
        // Latin-1 read missed every name beyond it, 2026-09-28).
        const key = c.strings.atom(name) catch return .unknown;
        var cur: ?*bytecode.Env = env;
        while (cur) |e| : (cur = e.parent) {
            const info = e.info;
            if (info.is_with or info.dynamic or e.extra != null) return .unknown;
            for (info.names, 0..) |n, i| {
                if (n == key) {
                    if (i < info.imports.len and info.imports[i]) return .{ .found = .{ .import = .{ .hops = hops, .slot = @intCast(i) } } };
                    // A named function expression's own name: the one
                    // scope of one const, non-lexical binding (assignment
                    // to it is silent in sloppy code, not an error).
                    if (info.consts[i] and !info.lexical[i] and info.names.len == 1 and !info.is_function) return .{ .found = .{ .fn_name = .{ .strict = c.fs.strict, .reg = null, .hops = hops, .slot = @intCast(i) } } };
                    if (info.consts[i]) return .{ .found = .{ .const_env = .{ .hops = hops, .slot = @intCast(i) } } };
                    return .{ .found = .{ .env = .{ .hops = hops, .slot = @intCast(i), .lexical = info.lexical[i] } } };
                }
            }
            hops += 1;
        }
        return .absent;
    }

    fn hopsTo(c: *Compiler, s: *Scope) u16 {
        var i = c.env_stack.items.len;
        while (i > 0) {
            i -= 1;
            if (c.env_stack.items[i] == s) return @intCast(c.env_stack.items.len - 1 - i);
        }
        unreachable;
    }

    /// Load a reference into `dst`.
    fn load(c: *Compiler, ref: Ref, dst: u16, name: []const u8) Error!void {
        switch (ref) {
            .reg, .const_reg => |r| {
                if (ref == .reg) {
                    if (c.isTdz(r)) try c.emitBc(.chktdz, r, try c.constString(name));
                    if (r != dst) try c.emit(.mov, dst, r, 0);
                } else {
                    if (c.isTdz(r)) try c.emitBc(.chktdz, r, try c.constString(name));
                    if (r != dst) try c.emit(.mov, dst, r, 0);
                }
            },
            .env => |e| try c.emit(if (e.lexical) .getenvchk else .getenv, dst, e.hops, e.slot),
            .const_env => |e| try c.emit(.getenvchk, dst, e.hops, e.slot),
            .global => |g| try c.emitBc(.getglobal, dst, g),
            .dynamic => |n| try c.emitBc(.getname, dst, n),
            .fn_name => |f| if (f.reg) |r| {
                if (r != dst) try c.emit(.mov, dst, r, 0);
            } else try c.emit(.getenv, dst, f.hops, f.slot),
            .import => |i| try c.emit(.getimport, dst, i.hops, i.slot),
            .immutable => try c.emitBc(.throwref, 0, try c.constString(name)),
        }
    }

    /// Whether a register binding may be in its TDZ: any lexical
    /// register binding (the check is one compare).
    fn isTdz(c: *Compiler, r: u16) bool {
        var cur: ?*Scope = c.scope;
        while (cur) |s| : (cur = s.parent) {
            for (s.bindings.values()) |b| if (b.loc == .reg and b.loc.reg == r) return b.lexical;
        }
        return false;
    }

    /// Store `src` through a reference (an assignment: TDZ and const checked).
    fn store(c: *Compiler, ref: Ref, src: u16, name: []const u8) Error!void {
        switch (ref) {
            .reg => |r| {
                if (c.isTdz(r)) try c.emitBc(.chktdz, r, try c.constString(name));
                if (r != src) try c.emit(.mov, r, src, 0);
            },
            .const_reg => |r| {
                if (c.isTdz(r)) try c.emitBc(.chktdz, r, try c.constString(name));
                try c.emitBc(.throwtype, 0, try c.constString("assignment to constant variable"));
            },
            .env => |e| try c.emit(if (e.lexical) .setenvchk else .setenv, src, e.hops, e.slot),
            .const_env => |e| {
                try c.emit(.chkconst, src, e.hops, e.slot);
            },
            .global => |g| try c.emitBc(if (c.fs.strict) .setglobalstrict else .setglobal, src, g),
            .dynamic => |n| try c.emitBc(.setname, src, n),
            .fn_name => |f| if (f.strict) try c.emitBc(.throwtype, 0, try c.constString("assignment to constant variable")),
            .import, .immutable => try c.emitBc(.throwtype, 0, try c.constString("assignment to constant variable")),
        }
    }

    /// Initialize a binding (a declaration: no TDZ check, consts allowed).
    fn initialize(c: *Compiler, ref: Ref, src: u16, name: []const u8) Error!void {
        switch (ref) {
            .reg, .const_reg => |r| if (r != src) try c.emit(.mov, r, src, 0),
            .env => |e| try c.emit(.setenv, src, e.hops, e.slot),
            .const_env => |e| try c.emit(.setenv, src, e.hops, e.slot),
            .global => |g| try c.emitBc(.initglobal, src, g),
            .dynamic => |n| try c.emitBc(.initname, src, n),
            .fn_name, .import, .immutable => {},
        }
        _ = name;
    }

    fn resolveRef(c: *Compiler, name: []const u8) Ref {
        return c.resolve(name);
    }

    // ------------------------------------------------------ functions

    /// Emit a closure of `f` into `dst`.
    fn closure(c: *Compiler, f: *ast.Function, dst: u16, name: ?[]const u8) Error!void {
        return c.closureDecl(f, dst, name, false);
    }

    fn closureDecl(c: *Compiler, f: *ast.Function, dst: u16, name: ?[]const u8, is_decl: bool) Error!void {
        const code = if (c.lazyEligible(f)) try c.lazyStub(f, name, is_decl) else try c.function(f, name);
        const idx: u32 = @intCast(c.fs.functions.items.len);
        try c.fs.functions.append(c.scratch, code);
        try c.emitBc(.closure, dst, idx);
    }

    /// Whether `f` waits for its first call: a plain function or arrow
    /// (methods, accessors and class parts compile with their class)
    /// with nothing dynamic in it, not called on the spot (`(function
    /// () {…})()`, `.call(this)`: the source right after it says).
    fn lazyEligible(c: *Compiler, f: *ast.Function) bool {
        if (!c.lazy) return false;
        // Constructors, field initializers and static blocks compile
        // with their class; methods and accessors wait like functions.
        if (f.kind != .normal and f.kind != .method and f.kind != .getter and f.kind != .setter) {
            stats.not_normal += 1;
            return false;
        }
        const fi = c.an.funcOf(f);
        if (fi.has_direct_eval or fi.dynamic or fi.has_with) {
            stats.dynamic += 1;
            return false;
        }
        // In a parameter default: the runtime chain there holds the
        // body's environment too, which the static scopes do not.
        if (c.fs.in_params) {
            stats.in_params += 1;
            return false;
        }
        const text = c.source.text;
        // An arrow's `super` is the enclosing method's: compiled with it.
        if (f.is_arrow and std.mem.indexOf(u8, text[f.start..f.end], "super") != null) {
            stats.super_arrow += 1;
            return false;
        }
        var i: usize = f.end;
        while (i < text.len and (text[i] == ' ' or text[i] == '\t' or text[i] == '\n' or text[i] == '\r' or text[i] == ')')) i += 1;
        if (i < text.len and (text[i] == '(' or text[i] == '.')) {
            stats.called_at_once += 1;
            return false;
        }
        return true;
    }

    /// A stub for `f`: what a function object needs before a call —
    /// kind, strictness, name, length, the source span — and no body.
    /// A bundle's functions mostly never run; this is what they cost.
    fn lazyStub(c: *Compiler, f: *ast.Function, name: ?[]const u8, is_decl: bool) Error!*Code {
        const fi = c.an.funcOf(f);
        stats.stubs += 1;
        const d = try c.a.create(CodeData);
        d.* = .{};
        d.kind = functionKind(f);
        d.strict = fi.strict;
        d.source = c.source;
        c.source.refs += 1;
        d.module = c.module_record;
        d.start = f.start;
        d.end = f.end;
        if (name orelse f.name) |n| d.name = try c.strings.atom(n);
        d.length = 0;
        for (f.params) |pm| {
            if (pm.data == .rest or pm.data == .assign_pattern) break;
            d.length += 1;
        }
        d.is_constructor = d.kind == .normal;
        d.uses_this = fi.uses_this;
        d.uses_arguments = fi.uses_arguments;
        d.lazy = true;
        // An anonymous declaration (`export default function () {}`)
        // parses again as an expression like any other.
        d.lazy_form = if (f.kind != .normal) 2 else if (is_decl and f.name != null) 1 else 0;
        d.lazy_params = f.params_start;
        const cell = try c.heap.alloc(.code, @sizeOf(Code));
        const code = cell.as(Code);
        code.data = d;
        return code;
    }

    fn functionKind(f: *ast.Function) bytecode.FunctionKind {
        return switch (f.kind) {
            .normal => if (f.is_arrow) (if (f.is_async) .async_arrow else .arrow) else if (f.is_generator and f.is_async) .async_generator else if (f.is_generator) .generator else if (f.is_async) .async_function else .normal,
            .method => if (f.is_generator and f.is_async) .async_generator else if (f.is_generator) .generator else if (f.is_async) .async_function else .method,
            .getter => .getter,
            .setter => .setter,
            .constructor => .class_constructor,
            .derived_constructor => .derived_constructor,
            .class_field_init => .field_init,
            .static_block => .static_block,
        };
    }

    /// Compile a function to its code (a nested FuncState).
    fn function(c: *Compiler, f: *ast.Function, name: ?[]const u8) Error!*Code {
        const fi = c.an.funcOf(f);
        const saved_fs = c.fs;
        const saved_scope = c.scope;
        const saved_chain = c.chain;
        const saved_completion = c.completion;
        c.chain = null;
        c.completion = null;
        var fs = FuncState{ .func = fi, .parent = saved_fs, .strict = fi.strict, .env_base = c.env_stack.items.len };
        defer fs.deinit(c.scratch);
        c.fs = &fs;
        defer {
            c.fs = saved_fs;
            c.scope = saved_scope;
            c.chain = saved_chain;
            c.completion = saved_completion;
        }
        // A named function expression's own-name scope.
        const name_scope: ?*Scope = if (f.name != null and !f.is_arrow) c.an.scopes.get(@ptrCast(&f.body)) else null;
        // Parameters occupy the first registers.
        fs.nparams = @intCast(f.params.len);
        var has_rest = false;
        if (f.params.len > 0 and f.params[f.params.len - 1].data == .rest) {
            has_rest = true;
            fs.nparams -= 1;
        }
        fs.top = fs.nparams;
        fs.max = fs.nparams;
        const fscope = fi.scope;
        const pscope = fi.params_scope;
        const decl_scope = pscope orelse fscope;
        // Simple parameters get their registers unless captured.
        for (f.params, 0..) |p, i| {
            if (p.data == .identifier) {
                const b = decl_scope.bindings.get(p.data.identifier).?;
                if (!b.captured and !fi.dynamic and b.loc == .unresolved) {
                    // Duplicate parameter names: the last wins.
                    b.loc = .{ .reg = @intCast(i) };
                }
            }
        }
        if (name_scope) |ns| {
            c.scope = ns;
            // The name binding: its own environment when captured, else a register.
            try c.enterScope(ns);
            const r = try c.tmp();
            try c.emit(.ldfunc, r, 0, 0);
            const b = ns.bindings.get(f.name.?).?;
            switch (b.loc) {
                .slot => |slot| try c.emit(.setenv, r, 0, @intCast(slot)),
                .reg => |reg| try c.emit(.mov, reg, r, 0),
                else => {},
            }
            c.release(r);
        }
        if (pscope) |ps| {
            c.scope = ps;
            try c.enterScope(ps);
        }
        c.scope = fscope;
        try c.enterScope(fscope);
        // A mapped arguments object: the slot of every parameter.
        if (fi.uses_arguments and !fi.strict and f.simple_params and !f.is_arrow and fs.nparams > 0) {
            const slots = try c.a.alloc(u32, fs.nparams);
            for (f.params, 0..) |p, i| {
                slots[i] = bytecode.CodeData.unmapped;
                if (p.data != .identifier) continue;
                // A later parameter of the same name takes the mapping.
                var dup = false;
                for (f.params[i + 1 ..]) |q| if (q.data == .identifier and std.mem.eql(u8, q.data.identifier, p.data.identifier)) {
                    dup = true;
                };
                if (dup) continue;
                const b = decl_scope.bindings.get(p.data.identifier).?;
                if (b.loc == .slot) slots[i] = @intCast(b.loc.slot);
            }
            fs.param_slots = slots;
        }
        // The prologue: implicit bindings and captured parameters.
        try c.prologue(f, fi, decl_scope, has_rest);
        // `this` once, into a register the body keeps (Richards loaded it
        // six million times for seven million property reads, 2026-09-25).
        if (fi.uses_this and !f.is_arrow and f.kind != .derived_constructor and !fi.has_direct_eval and !fi.dynamic) {
            const r = try c.tmp();
            try c.emit(.ldthis, r, 0, 0);
            fs.this_reg = r;
        }
        // Parameter patterns and defaults.
        fs.in_params = true;
        for (f.params, 0..) |p, i| {
            const reg: u16 = @intCast(i);
            if (p.data == .identifier) {
                const b = decl_scope.bindings.get(p.data.identifier).?;
                if (b.loc == .slot) try c.emit(.setenv, reg, c.hopsTo(decl_scope), @intCast(b.loc.slot));
            } else if (p.data == .rest) {
                const r = try c.tmp();
                try c.emitBc(.initrest, r, fs.nparams);
                try c.bindPattern(p.data.rest, r, .init);
                c.release(r);
            } else if (p.data == .assign_pattern) {
                const ap = p.data.assign_pattern;
                const skip = try c.jump(.jnundef, reg);
                if (ap.target.data == .identifier and isAnonymousFunction(ap.default)) {
                    try c.namedInto(ap.default, ap.target.data.identifier, reg);
                } else _ = try c.expr(ap.default, reg);
                c.patchHere(skip);
                try c.bindPattern(ap.target, reg, .init);
            } else {
                try c.bindPattern(p, reg, .init);
            }
        }
        fs.in_params = false;
        // A generator suspends once its parameters are bound (§27.5.3.1:
        // the body waits for the first next()); an async function runs on.
        fs.co = if (f.is_generator and f.is_async) .async_gen else if (f.is_generator) .generator else if (f.is_async) .async_fn else .none;
        if (f.is_generator) try c.emit(.genstart, 0, 0, 0);
        // The body.
        switch (f.body) {
            .block => |body| {
                for (body) |st| try c.stmt(st);
                try c.emit(.retundef, 0, 0, 0);
            },
            .expr => |e| {
                const r = try c.expr(e, null);
                try c.emit(.ret, r, 0, 0);
            },
        }
        try c.leaveScope(fscope);
        if (pscope) |ps| try c.leaveScope(ps);
        if (name_scope) |ns| try c.leaveScope(ns);
        return c.finish(&fs, name orelse f.name, functionKind(f), f.start, f.end);
    }

    fn prologue(c: *Compiler, f: *ast.Function, fi: *scope.Func, decl_scope: *Scope, has_rest: bool) Error!void {
        _ = has_rest;
        _ = decl_scope;
        const fscope = fi.scope;
        // Implicit bindings captured into the function environment.
        if (fscope.bindings.get("this")) |b| if (b.loc == .slot) {
            const r = try c.tmp();
            if (f.kind == .derived_constructor) {
                try c.emit(.ldempty, r, 0, 0);
            } else try c.emit(.ldthis, r, 0, 0);
            try c.emit(.setenv, r, 0, @intCast(b.loc.slot));
            c.release(r);
        };
        if (fscope.bindings.get("new.target")) |b| if (b.loc == .slot) {
            const r = try c.tmp();
            try c.emit(.ldnewtarget, r, 0, 0);
            try c.emit(.setenv, r, 0, @intCast(b.loc.slot));
            c.release(r);
        };
        if (fscope.bindings.get(".home")) |b| if (b.loc == .slot) {
            const r = try c.tmp();
            try c.emit(.ldhome, r, 0, 0);
            try c.emit(.setenv, r, 0, @intCast(b.loc.slot));
            c.release(r);
        };
        if (fscope.bindings.get(".func")) |b| if (b.loc == .slot) {
            const r = try c.tmp();
            try c.emit(.ldfunc, r, 0, 0);
            try c.emit(.setenv, r, 0, @intCast(b.loc.slot));
            c.release(r);
        };
        if (fscope.bindings.get("arguments")) |b| if (b.kind == .implicit) {
            const r = try c.tmp();
            try c.emit(.initargs, r, 0, 0);
            switch (b.loc) {
                .slot => |s| try c.emit(.setenv, r, 0, @intCast(s)),
                .reg => |reg| try c.emit(.mov, reg, r, 0),
                else => {},
            }
            c.release(r);
        };
    }

    /// The function's `this` reference.
    fn loadThis(c: *Compiler, dst: u16) Error!void {
        if (c.fs.this_reg) |r| {
            if (r != dst) try c.emit(.mov, dst, r, 0);
            return;
        }
        const tf = c.scope.func.this_func;
        if (tf.node == null) {
            if (c.lazy_root) {
                // A stub arrow's `this` is the enclosing function's,
                // captured into its environment; none on the chain means
                // the script's global (a module's undefined).
                if (c.eval_env) |env| switch (c.resolveRuntime(env, "this")) {
                    .found => |r| switch (r) {
                        // Checked: a derived constructor's `this` is the
                        // hole until `super()` returns.
                        .env => |e| {
                            try c.emit(.getenvchk, dst, e.hops, e.slot);
                            return;
                        },
                        else => {
                            try c.load(r, dst, "this");
                            return;
                        },
                    },
                    else => {},
                };
                try c.emit(if (c.module_record != null) .ldundef else .ldgthis, dst, 0, 0);
                return;
            }
            if (c.eval_mode) {
                try c.emitBc(.getname, dst, try c.constString("this"));
            } else if (c.scope.func != tf) {
                // An arrow at the top level: the script's `this` is the
                // global object, a module's is undefined.
                try c.emit(if (c.module_record != null) .ldundef else .ldgthis, dst, 0, 0);
            } else try c.emit(.ldthis, dst, 0, 0);
            return;
        }
        const b = tf.scope.bindings.get("this") orelse {
            try c.emit(.ldthis, dst, 0, 0);
            return;
        };
        switch (b.loc) {
            .slot => |s| try c.emit(.getenvchk, dst, c.hopsTo(tf.scope), @intCast(s)),
            else => {
                if (tf.has_eval_refs) {
                    try c.emitBc(.getname, dst, try c.constString("this"));
                } else try c.emit(.ldthis, dst, 0, 0);
            },
        }
    }

    fn loadImplicit(c: *Compiler, name: []const u8, dst: u16, op: Op) Error!void {
        const tf = c.scope.func.this_func;
        if (tf.node == null) {
            if (c.eval_mode) {
                try c.emitBc(.getname, dst, try c.constString(name));
            } else try c.emit(op, dst, 0, 0);
            return;
        }
        const b = tf.scope.bindings.get(name) orelse {
            try c.emit(op, dst, 0, 0);
            return;
        };
        switch (b.loc) {
            .slot => |s| try c.emit(.getenv, dst, c.hopsTo(tf.scope), @intCast(s)),
            else => {
                if (tf.has_eval_refs) {
                    try c.emitBc(.getname, dst, try c.constString(name));
                } else try c.emit(op, dst, 0, 0);
            },
        }
    }

    // ----------------------------------------------------- statements

    fn stmt(c: *Compiler, st: *Node) Error!void {
        try c.pos(st.pos);
        switch (st.data) {
            .var_decl => |d| try c.varDecl(d.kind, d.decls),
            .function_decl => |f| {
                // Hoisted at scope entry; an Annex B block function also
                // assigns its var-scoped twin here.
                const b = if (f.name) |n| c.scope.bindings.get(n) else null;
                if (b != null and b.?.annexb and c.scope.kind != .function) {
                    const r = try c.tmp();
                    const inner = c.resolve(f.name.?);
                    try c.load(inner, r, f.name.?);
                    const vs = varScopeOf(c.scope);
                    const saved = c.scope;
                    c.scope = vs;
                    const outer = c.resolve(f.name.?);
                    c.scope = saved;
                    try c.initialize(outer, r, f.name.?);
                    c.release(r);
                }
            },
            .class_decl => |cl| {
                const r = try c.tmp();
                // `export default class {}` binds "*default*", named "default".
                const bind = cl.name orelse "*default*";
                if (cl.name == null) try c.classExprNamed(cl, r, "default") else try c.classExpr(cl, r);
                const ref = c.resolve(bind);
                try c.initialize(ref, r, bind);
                c.release(r);
            },
            .block => |body| {
                const s = c.an.scopeOf(st);
                try c.withScope(s, body);
            },
            .empty, .debugger => {},
            .expr_stmt => |e| {
                const top = c.fs.top;
                if (c.completion != null or !try c.updateDiscard(e)) _ = try c.expr(e, c.completion);
                c.release(top);
            },
            .if_stmt => |i| {
                try c.completionUndefined();
                const top = c.fs.top;
                const cond = try c.expr(i.cond, null);
                const jf = try c.jump(.jf, cond);
                c.release(top);
                try c.stmt(i.then);
                if (i.otherwise) |o| {
                    const jend = try c.jump(.jmp, 0);
                    c.patchHere(jf);
                    try c.stmt(o);
                    c.patchHere(jend);
                } else c.patchHere(jf);
            },
            .for_stmt => {
                try c.completionUndefined();
                try c.forStmt(st);
            },
            .for_in => {
                try c.completionUndefined();
                try c.forIn(st);
            },
            .for_of => {
                try c.completionUndefined();
                try c.forOf(st);
            },
            .while_stmt => |w| {
                try c.completionUndefined();
                const labels = try c.takeLabels();
                const ctl = try c.pushTarget(labels, true);
                const start = c.pc();
                const top = c.fs.top;
                const cond = try c.expr(w.cond, null);
                const jf = try c.jump(.jf, cond);
                c.release(top);
                try c.stmt(w.body);
                try c.patchContinues(ctl, start);
                try c.emitBc(.jmp, 0, start);
                c.patchHere(jf);
                try c.popTarget(ctl);
            },
            .do_while => |w| {
                try c.completionUndefined();
                const labels = try c.takeLabels();
                const ctl = try c.pushTarget(labels, true);
                const start = c.pc();
                try c.stmt(w.body);
                try c.patchContinues(ctl, c.pc());
                const top = c.fs.top;
                const cond = try c.expr(w.cond, null);
                try c.emitBc(.jt, cond, start);
                c.release(top);
                try c.popTarget(ctl);
            },
            .return_stmt => |r| {
                const top = c.fs.top;
                var reg = if (r) |e| try c.expr(e, null) else blk: {
                    const t = try c.tmp();
                    try c.emit(.ldundef, t, 0, 0);
                    break :blk t;
                };
                // An async generator awaits what it returns (§15.6: return).
                if (c.fs.co == .async_gen and r != null) reg = try c.awaitInto(reg, null);
                try c.emitReturn(reg);
                c.release(top);
            },
            .break_stmt => |label| try c.jumpOut(label, false, st.pos),
            .continue_stmt => |label| try c.jumpOut(label, true, st.pos),
            .throw_stmt => |e| {
                const top = c.fs.top;
                const r = try c.expr(e, null);
                try c.emit(.throw, r, 0, 0);
                c.release(top);
            },
            .try_stmt => {
                try c.completionUndefined();
                try c.tryStmt(st);
            },
            .switch_stmt => {
                try c.completionUndefined();
                try c.switchStmt(st);
            },
            .labeled => |l| {
                try c.pending_labels.append(c.scratch, l.label);
                switch (l.body.data) {
                    .for_stmt, .for_in, .for_of, .while_stmt, .do_while => try c.stmt(l.body),
                    else => {
                        const labels = try c.takeLabels();
                        const ctl = try c.pushTarget(labels, false);
                        try c.stmt(l.body);
                        try c.popTarget(ctl);
                    },
                }
            },
            .with_stmt => |w| {
                const top = c.fs.top;
                const obj = try c.expr(w.object, null);
                const s = c.an.scopeOf(st);
                try c.emit(.pushwith, obj, 0, 0);
                c.release(top);
                s.has_env = true;
                try c.env_stack.append(c.scratch, s);
                try c.fs.controls.append(c.scratch, .env);
                const saved = c.scope;
                c.scope = s;
                try c.stmt(w.body);
                c.scope = saved;
                _ = c.fs.controls.pop();
                _ = c.env_stack.pop();
                s.has_env = false;
                try c.emit(.popenv, 0, 0, 0);
            },
            .import_decl => {},
            .export_decl => |e| switch (e) {
                .declaration => |d| try c.stmt(d),
                .default => |d| {
                    if (d.data == .function_decl or d.data == .class_decl) {
                        try c.stmt(d);
                    } else {
                        const r = try c.tmp();
                        if (isAnonymousFunction(d)) try c.namedInto(d, "default", r) else _ = try c.expr(d, r);
                        try c.initialize(c.resolve("*default*"), r, "*default*");
                        c.release(r);
                    }
                },
                else => {},
            },
            else => {
                const top = c.fs.top;
                _ = try c.expr(st, c.completion);
                c.release(top);
            },
        }
    }

    fn varScopeOf(s: *Scope) *Scope {
        var cur = s;
        while (true) : (cur = cur.parent.?) switch (cur.kind) {
            .function, .script, .module, .eval => return cur,
            else => {},
        };
    }

    fn withScope(c: *Compiler, s: *Scope, body: []*Node) Error!void {
        const saved = c.scope;
        const top = c.fs.top;
        c.scope = s;
        try c.enterScope(s);
        if (s.has_env) try c.fs.controls.append(c.scratch, .env);
        for (body) |st| try c.stmt(st);
        if (s.has_env) _ = c.fs.controls.pop();
        try c.leaveScope(s);
        c.scope = saved;
        c.release(top);
    }

    fn varDecl(c: *Compiler, kind: ast.DeclKind, decls: []ast.Declarator) Error!void {
        for (decls) |d| {
            const top = c.fs.top;
            defer c.release(top);
            if (d.init) |init| {
                if (d.target.data == .identifier) {
                    const name = d.target.data.identifier;
                    const ref = c.resolve(name);
                    // Straight into the register when it has one.
                    const direct: ?u16 = switch (ref) {
                        // Not when the initializer reads the binding: an
                        // array built straight into `p` would hold itself
                        // in `var p = [p]`, and `let p = [p]` would miss its
                        // TDZ error.
                        .reg => |r| if (mentions(init, name)) null else r,
                        else => null,
                    };
                    const r = if (isAnonymousFunction(init)) blk: {
                        const t = direct orelse try c.tmp();
                        try c.namedInto(init, name, t);
                        break :blk t;
                    } else try c.expr(init, direct);
                    if (kind == .@"var") try c.store(ref, r, name) else try c.initialize(ref, r, name);
                } else {
                    const r = try c.expr(init, null);
                    try c.bindPattern(d.target, r, if (kind == .@"var") .assign else .init);
                }
            } else if (kind != .@"var") {
                // `let x;` initializes to undefined.
                const name = d.target.data.identifier;
                const r = try c.tmp();
                try c.emit(.ldundef, r, 0, 0);
                try c.initialize(c.resolve(name), r, name);
            }
        }
    }

    /// An anonymous function or class expression (NamedEvaluation applies).
    fn isAnonymousFunction(n: *Node) bool {
        return switch (n.data) {
            .function => |f| f.name == null,
            .class => |cl| cl.name == null,
            else => false,
        };
    }

    /// Compile an anonymous function/class with `name` into `dst`.
    fn namedInto(c: *Compiler, n: *Node, name: []const u8, dst: u16) Error!void {
        switch (n.data) {
            .function => |f| try c.closure(f, dst, name),
            .class => |cl| try c.classExprNamed(cl, dst, name),
            else => unreachable,
        }
    }

    /// The name an anonymous function expression takes from its target.
    fn nameOf(target: *Node) ?[]const u8 {
        return switch (target.data) {
            .identifier => |n| n,
            else => null,
        };
    }

    // ------------------------------------------------- control flow

    fn takeLabels(c: *Compiler) Error![]const []const u8 {
        const l = try c.pending_labels.toOwnedSlice(c.scratch);
        return l;
    }

    fn pushTarget(c: *Compiler, labels: []const []const u8, is_loop: bool) Error!usize {
        try c.fs.controls.append(c.scratch, .{ .target = .{ .labels = labels, .is_loop = is_loop, .top = c.fs.top } });
        return c.fs.controls.items.len - 1;
    }

    fn popTarget(c: *Compiler, idx: usize) Error!void {
        var ctl = c.fs.controls.pop().?;
        std.debug.assert(c.fs.controls.items.len == idx);
        const here = c.pc();
        for (ctl.target.breaks.items) |at| c.patch(at, here);
        ctl.target.breaks.deinit(c.scratch);
        ctl.target.continues.deinit(c.scratch);
        c.scratch.free(ctl.target.labels);
    }

    fn patchContinues(c: *Compiler, idx: usize, target: u32) Error!void {
        const t = &c.fs.controls.items[idx].target;
        for (t.continues.items) |at| c.patch(at, target);
        t.continues.clearRetainingCapacity();
    }

    /// `break`/`continue`: unwind the control stack to the target.
    fn jumpOut(c: *Compiler, label: ?[]const u8, is_continue: bool, at: u32) Error!void {
        // Find the target.
        var i = c.fs.controls.items.len;
        var target: ?usize = null;
        while (i > 0) {
            i -= 1;
            const ctl = c.fs.controls.items[i];
            if (ctl != .target) continue;
            const t = ctl.target;
            if (label) |l| {
                for (t.labels) |tl| if (std.mem.eql(u8, tl, l)) {
                    target = i;
                };
                if (target != null) {
                    if (is_continue and !t.is_loop) return c.fail("continue target is not a loop", at);
                    break;
                }
            } else if (is_continue) {
                if (t.is_loop) {
                    target = i;
                    break;
                }
            } else if (t.is_loop or t.labels.len == 0) {
                // An unlabeled break targets a loop or switch (a
                // labeled block only by its label).
                if (t.is_loop or ctl.target.labels.len == 0) {
                    target = i;
                    break;
                }
            }
        }
        const ti = target orelse return c.fail("break/continue target not found", at);
        try c.unwindTo(ti, is_continue, c.fs.controls.items.len);
    }

    /// Emit the unwinding from control index `from` (exclusive) down to
    /// `target`, then the jump; a finally on the way takes over.
    fn unwindTo(c: *Compiler, target: usize, is_continue: bool, from: usize) Error!void {
        var i = from;
        while (i > target + 1) {
            i -= 1;
            switch (c.fs.controls.items[i]) {
                .target => {},
                .env => try c.emit(.popenv, 0, 0, 0),
                .try_region => try c.emit(.poptry, 0, 0, 0),
                .for_of => |f| {
                    try c.emit(.poptry, 0, 0, 0);
                    // A `continue` to this very loop keeps its iterator
                    // open; only loops left behind are closed.
                    if (is_continue and i == target + 1) continue;
                    if (f.is_await) try c.asyncIteratorClose(f.iter, false) else try c.emit(.iterclose, f.iter, 0, 0);
                },
                .finally => |*fi| {
                    const id = c.fs.finally_ids;
                    c.fs.finally_ids += 1;
                    try fi.pending.append(c.scratch, .{ .id = id, .target = target, .is_continue = is_continue });
                    try c.emitBc(.ldint, fi.kind, @bitCast(id));
                    try fi.entries.append(c.scratch, try c.jump(.jmp, 0));
                    return;
                },
            }
        }
        const t = &c.fs.controls.items[target].target;
        if (is_continue) {
            try t.continues.append(c.scratch, try c.jump(.jmp, 0));
        } else {
            try t.breaks.append(c.scratch, try c.jump(.jmp, 0));
        }
    }

    /// `return reg`, through any enclosing finally / for-of.
    fn emitReturn(c: *Compiler, reg: u16) Error!void {
        try c.emitReturnFrom(reg, c.fs.controls.items.len);
    }

    fn emitReturnFrom(c: *Compiler, reg: u16, from: usize) Error!void {
        var i = from;
        while (i > 0) {
            i -= 1;
            switch (c.fs.controls.items[i]) {
                .for_of => |f| {
                    try c.emit(.poptry, 0, 0, 0);
                    if (f.is_await) try c.asyncIteratorClose(f.iter, false) else try c.emit(.iterclose, f.iter, 0, 0);
                },
                .finally => |*fi| {
                    try c.emit(.mov, fi.val, reg, 0);
                    try c.emitBc(.ldint, fi.kind, 2);
                    try fi.entries.append(c.scratch, try c.jump(.jmp, 0));
                    return;
                },
                else => {},
            }
        }
        try c.emit(.ret, reg, 0, 0);
    }

    fn forStmt(c: *Compiler, st: *Node) Error!void {
        const f = st.data.for_stmt;
        const labels = try c.takeLabels();
        const s = c.an.scopeOf(st);
        const saved = c.scope;
        const top = c.fs.top;
        c.scope = s;
        try c.enterScope(s);
        if (s.has_env) try c.fs.controls.append(c.scratch, .env);
        if (f.init) |i| {
            if (i.data == .var_decl) try c.stmt(i) else {
                const t = c.fs.top;
                _ = try c.expr(i, null);
                c.release(t);
            }
        }
        // Per-iteration bindings when the head's lexical bindings are captured.
        const per_iter = s.has_env and f.init != null and f.init.?.data == .var_decl and f.init.?.data.var_decl.kind != .@"var";
        if (per_iter) try c.emit(.copyenv, 0, 0, 0);
        const ctl = try c.pushTarget(labels, true);
        const start = c.pc();
        var jf: ?u32 = null;
        if (f.cond) |cond| {
            const t = c.fs.top;
            const r = try c.expr(cond, null);
            jf = try c.jump(.jf, r);
            c.release(t);
        }
        try c.stmt(f.body);
        try c.patchContinues(ctl, c.pc());
        if (per_iter) try c.emit(.copyenv, 0, 0, 0);
        if (f.update) |u| {
            const t = c.fs.top;
            if (!try c.updateDiscard(u)) _ = try c.expr(u, null);
            c.release(t);
        }
        try c.emitBc(.jmp, 0, start);
        if (jf) |j| c.patchHere(j);
        try c.popTarget(ctl);
        if (s.has_env) _ = c.fs.controls.pop();
        try c.leaveScope(s);
        c.scope = saved;
        c.release(top);
    }

    fn forIn(c: *Compiler, st: *Node) Error!void {
        const f = st.data.for_in;
        const labels = try c.takeLabels();
        const s = c.an.scopeOf(st);
        const saved = c.scope;
        const top = c.fs.top;
        // The right side is evaluated with the head's bindings in TDZ.
        c.scope = s;
        const is_lexical = f.left.data == .var_decl and f.left.data.var_decl.kind != .@"var";
        // Annex B: `for (var x = init in obj)`.
        if (f.left.data == .var_decl and f.left.data.var_decl.decls[0].init != null) {
            c.scope = saved;
            try c.varDecl(.@"var", f.left.data.var_decl.decls);
            c.scope = s;
        }
        const en = try c.tmp();
        {
            // TDZ scope for the right side.
            if (is_lexical) {
                try c.enterScope(s);
                const obj = try c.expr(f.right, null);
                try c.emit(.forin, en, obj, 0);
                try c.leaveScope(s);
                for (s.bindings.values()) |b| b.loc = .unresolved;
            } else {
                c.scope = saved;
                const obj = try c.expr(f.right, null);
                try c.emit(.forin, en, obj, 0);
                c.scope = s;
            }
            c.release(en + 1);
        }
        const ctl = try c.pushTarget(labels, true);
        const start = c.pc();
        const key = try c.tmp();
        try c.emit(.forinnext, key, en, 0);
        const jdone = try c.jump(.jempty, key);
        // Each iteration binds afresh.
        if (is_lexical) {
            try c.enterScope(s);
            if (s.has_env) try c.fs.controls.append(c.scratch, .env);
        }
        try c.forBind(f.left, key);
        try c.stmt(f.body);
        if (is_lexical) {
            if (s.has_env) _ = c.fs.controls.pop();
            try c.leaveScope(s);
        }
        try c.patchContinues(ctl, c.pc());
        try c.emitBc(.jmp, 0, start);
        c.patchHere(jdone);
        try c.popTarget(ctl);
        c.scope = saved;
        c.release(top);
    }

    fn forOf(c: *Compiler, st: *Node) Error!void {
        const f = st.data.for_of;
        const labels = try c.takeLabels();
        const s = c.an.scopeOf(st);
        const saved = c.scope;
        const top = c.fs.top;
        c.scope = s;
        const is_lexical = f.left.data == .var_decl and f.left.data.var_decl.kind != .@"var";
        const iter = try c.tmps(2);
        {
            if (is_lexical) {
                try c.enterScope(s);
                const obj = try c.expr(f.right, null);
                try c.emit(if (f.is_await) .iterasync else .iter, iter, obj, 0);
                try c.leaveScope(s);
                for (s.bindings.values()) |b| b.loc = .unresolved;
            } else {
                c.scope = saved;
                const obj = try c.expr(f.right, null);
                try c.emit(if (f.is_await) .iterasync else .iter, iter, obj, 0);
                c.scope = s;
            }
            c.release(iter + 2);
        }
        const ctl = try c.pushTarget(labels, true);
        const start = c.pc();
        const val = try c.tmp();
        if (f.is_await) {
            // for await: the result object is awaited, then read.
            const r = try c.tmp();
            try c.emit(.iterstep, r, iter, 0);
            _ = try c.awaitInto(r, r);
            try c.emit(.chkobj, r, 0, 0);
            try c.emit(.iterresult, val, r, 0);
            c.release(r);
        } else try c.emit(.iternext, val, iter, 0);
        const jdone = try c.jump(.jempty, val);
        // The body runs under a handler that closes the iterator.
        const exc = try c.tmp();
        const jtry = try c.jump(.pushtry, exc);
        try c.fs.controls.append(c.scratch, .{ .for_of = .{ .iter = iter, .is_await = f.is_await } });
        if (is_lexical) {
            try c.enterScope(s);
            if (s.has_env) try c.fs.controls.append(c.scratch, .env);
        }
        try c.forBind(f.left, val);
        try c.stmt(f.body);
        if (is_lexical) {
            if (s.has_env) _ = c.fs.controls.pop();
            try c.leaveScope(s);
        }
        _ = c.fs.controls.pop();
        try c.emit(.poptry, 0, 0, 0);
        try c.patchContinues(ctl, c.pc());
        try c.emitBc(.jmp, 0, start);
        // The handler: close the iterator, rethrow.
        c.patchHere(jtry);
        if (f.is_await) {
            try c.asyncIteratorClose(iter, true);
        } else try c.emit(.iterclosethrow, iter, 0, 0);
        try c.emit(.throw, exc, 0, 0);
        c.patchHere(jdone);
        try c.popTarget(ctl);
        c.scope = saved;
        c.release(top);
    }

    /// AsyncIteratorClose (§7.4.11): call `return` if there is one and
    /// await its result; in a throw completion, errors from it are dropped.
    fn asyncIteratorClose(c: *Compiler, iter: u16, throwing: bool) Error!void {
        const top = c.fs.top;
        const t = try c.tmp();
        try c.emit(.iterreturn, t, iter, 0);
        const jskip = try c.jump(.jundef, t);
        if (throwing) {
            const exc = try c.tmp();
            const jtry = try c.jump(.pushtry, exc);
            _ = try c.awaitInto(t, t);
            try c.emit(.poptry, 0, 0, 0);
            c.patchHere(jtry);
        } else {
            _ = try c.awaitInto(t, t);
            try c.emit(.chkobj, t, 0, 0);
        }
        c.patchHere(jskip);
        c.release(top);
    }

    /// Bind a for-in/of head to the iteration value.
    fn forBind(c: *Compiler, left: *Node, val: u16) Error!void {
        if (left.data == .var_decl) {
            const d = left.data.var_decl;
            const target = d.decls[0].target;
            try c.bindPattern(target, val, if (d.kind == .@"var") .assign else .init);
        } else {
            try c.bindPattern(left, val, .assign);
        }
    }

    fn tryStmt(c: *Compiler, st: *Node) Error!void {
        const t = st.data.try_stmt;
        const top = c.fs.top;
        var fin_idx: ?usize = null;
        var kind_reg: u16 = 0;
        var val_reg: u16 = 0;
        if (t.finalizer != null) {
            kind_reg = try c.tmp();
            val_reg = try c.tmp();
            try c.emitBc(.ldint, kind_reg, 0);
            try c.fs.controls.append(c.scratch, .{ .finally = .{ .kind = kind_reg, .val = val_reg } });
            fin_idx = c.fs.controls.items.len - 1;
        }
        const exc = try c.tmp();
        // try block
        const jcatch = try c.jump(.pushtry, exc);
        try c.fs.controls.append(c.scratch, .try_region);
        try c.stmt(t.block);
        _ = c.fs.controls.pop();
        try c.emit(.poptry, 0, 0, 0);
        var jends: [2]u32 = undefined;
        var njend: usize = 0;
        jends[njend] = try c.jump(.jmp, 0);
        njend += 1;
        c.patchHere(jcatch);
        if (t.handler) |h| {
            // catch: under the finally's handler when there is one
            var jfin: ?u32 = null;
            if (t.finalizer != null) {
                jfin = try c.jump(.pushtry, val_reg);
                try c.fs.controls.append(c.scratch, .try_region);
            }
            const cs = c.an.scopeOf(st);
            const saved = c.scope;
            c.scope = cs;
            try c.enterScope(cs);
            if (cs.has_env) try c.fs.controls.append(c.scratch, .env);
            if (t.param) |p| try c.bindPattern(p, exc, .init);
            // The handler block is compiled in the catch scope directly
            // (its own scope holds the block's declarations).
            const hs = c.an.scopeOf(h);
            try c.withScope(hs, h.data.block);
            if (cs.has_env) _ = c.fs.controls.pop();
            try c.leaveScope(cs);
            c.scope = saved;
            if (t.finalizer != null) {
                _ = c.fs.controls.pop();
                try c.emit(.poptry, 0, 0, 0);
            }
            jends[njend] = try c.jump(.jmp, 0);
            njend += 1;
            if (jfin) |j| {
                c.patchHere(j);
                // An exception from the catch block: finally, then rethrow.
                try c.emitBc(.ldint, kind_reg, 1);
            }
        } else {
            // No catch: the exception goes to the finally.
            try c.emit(.mov, val_reg, exc, 0);
            try c.emitBc(.ldint, kind_reg, 1);
        }
        if (t.finalizer) |fin| {
            // Entry from a throw falls through here; normal entries jump.
            const jthrow_entry = try c.jump(.jmp, 0);
            for (jends[0..njend]) |j| c.patchHere(j);
            // (kind_reg is already 0 on the normal path)
            c.patchHere(jthrow_entry);
            var ctl = c.fs.controls.pop().?;
            std.debug.assert(c.fs.controls.items.len == fin_idx.?);
            for (ctl.finally.entries.items) |j| c.patchHere(j);
            ctl.finally.entries.deinit(c.scratch);
            const saved_completion = c.completion;
            c.completion = null;
            try c.stmt(fin);
            c.completion = saved_completion;
            // Dispatch on the completion.
            const t0 = try c.tmp();
            // throw
            try c.emitBc(.ldint, t0, 1);
            try c.emit(.seq, t0, kind_reg, t0);
            const jn1 = try c.jump(.jf, t0);
            try c.emit(.throw, val_reg, 0, 0);
            c.patchHere(jn1);
            // return
            try c.emitBc(.ldint, t0, 2);
            try c.emit(.seq, t0, kind_reg, t0);
            const jn2 = try c.jump(.jf, t0);
            try c.emitReturnFrom(val_reg, c.fs.controls.items.len);
            c.patchHere(jn2);
            for (ctl.finally.pending.items) |p| {
                try c.emitBc(.ldint, t0, @bitCast(p.id));
                try c.emit(.seq, t0, kind_reg, t0);
                const jn = try c.jump(.jf, t0);
                try c.unwindTo(p.target, p.is_continue, c.fs.controls.items.len);
                c.patchHere(jn);
            }
            ctl.finally.pending.deinit(c.scratch);
            c.release(t0);
        } else {
            for (jends[0..njend]) |j| c.patchHere(j);
        }
        c.release(top);
    }

    fn switchStmt(c: *Compiler, st: *Node) Error!void {
        const sw = st.data.switch_stmt;
        const labels = try c.takeLabels();
        const top = c.fs.top;
        const disc = try c.tmp();
        _ = try c.expr(sw.discriminant, disc);
        const s = c.an.scopeOf(st);
        const saved = c.scope;
        c.scope = s;
        try c.enterScope(s);
        if (s.has_env) try c.fs.controls.append(c.scratch, .env);
        const ctl = try c.pushTarget(labels, false);
        // Tests, then bodies.
        const jumps = try c.scratch.alloc(u32, sw.cases.len);
        defer c.scratch.free(jumps);
        var default_idx: ?usize = null;
        const t = try c.tmp();
        for (sw.cases, 0..) |cs, i| {
            if (cs.cond) |cond| {
                _ = try c.expr(cond, t);
                try c.emit(.seq, t, disc, t);
                jumps[i] = try c.jump(.jt, t);
            } else default_idx = i;
        }
        c.release(t);
        var jdefault: ?u32 = null;
        if (default_idx != null) {
            jdefault = try c.jump(.jmp, 0);
        }
        const jend = try c.jump(.jmp, 0);
        for (sw.cases, 0..) |cs, i| {
            if (cs.cond != null) c.patchHere(jumps[i]) else c.patchHere(jdefault.?);
            for (cs.body) |x| try c.stmt(x);
        }
        c.patchHere(jend);
        try c.popTarget(ctl);
        if (s.has_env) _ = c.fs.controls.pop();
        try c.leaveScope(s);
        c.scope = saved;
        c.release(top);
    }

    // ------------------------------------------------------ patterns

    const BindMode = enum { assign, init };

    /// Bind `val` to a pattern (destructuring), assigning or initializing.
    fn bindPattern(c: *Compiler, pat: *Node, val: u16, mode: BindMode) Error!void {
        switch (pat.data) {
            .identifier => |name| {
                const ref = c.resolve(name);
                if (mode == .init) try c.initialize(ref, val, name) else try c.store(ref, val, name);
            },
            .assign_pattern => |ap| {
                const skip = try c.jump(.jnundef, val);
                const top = c.fs.top;
                const r = try c.tmp();
                if (ap.target.data == .identifier and isAnonymousFunction(ap.default)) {
                    try c.namedInto(ap.default, ap.target.data.identifier, r);
                } else _ = try c.expr(ap.default, r);
                try c.emit(.mov, val, r, 0);
                c.release(top);
                c.patchHere(skip);
                try c.bindPattern(ap.target, val, mode);
            },
            .array_pattern => |els| {
                const top = c.fs.top;
                const iter = try c.tmps(2);
                try c.emit(.iter, iter, val, 0);
                const exc = try c.tmp();
                const jtry = try c.jump(.pushtry, exc);
                const done = try c.tmp();
                try c.emit(.ldfalse, done, 0, 0);
                for (els) |el| {
                    const item = try c.tmp();
                    if (el != null and el.?.data == .rest) {
                        // Collect the rest into an array.
                        try c.emitBc(.newarr, item, 0);
                        const v = try c.tmp();
                        const loop = c.pc();
                        try c.emit(.iternext, v, iter, 0);
                        const jd = try c.jump(.jempty, v);
                        try c.emit(.arrpush, item, v, 0);
                        try c.emitBc(.jmp, 0, loop);
                        c.patchHere(jd);
                        try c.emit(.ldtrue, done, 0, 0);
                        c.release(v);
                        try c.bindPattern(el.?.data.rest, item, mode);
                    } else {
                        try c.emit(.iternext, item, iter, 0);
                        const jd = try c.jump(.jnempty, item);
                        try c.emit(.ldtrue, done, 0, 0);
                        try c.emit(.ldundef, item, 0, 0);
                        c.patchHere(jd);
                        if (el) |e| try c.bindPattern(e, item, mode);
                    }
                    c.release(item);
                }
                try c.emit(.poptry, 0, 0, 0);
                // Close unless exhausted.
                const jskip = try c.jump(.jt, done);
                try c.emit(.iterclose, iter, 0, 0);
                const jend = try c.jump(.jmp, 0);
                c.patchHere(jtry);
                // On a throw: close (errors swallowed) unless exhausted, rethrow.
                const jskip2 = try c.jump(.jt, done);
                try c.emit(.iterclosethrow, iter, 0, 0);
                c.patchHere(jskip2);
                try c.emit(.throw, exc, 0, 0);
                c.patchHere(jskip);
                c.patchHere(jend);
                c.release(top);
            },
            .object_pattern => |props| {
                const top = c.fs.top;
                // RequireObjectCoercible: reading a property of null throws
                // the right error; an empty pattern still needs the check.
                const t = try c.tmp();
                try c.emit(.toobject, t, val, 0);
                c.release(t);
                var excluded: ?u16 = null;
                var has_rest = false;
                for (props) |p| if (p.is_rest) {
                    has_rest = true;
                };
                if (has_rest) {
                    excluded = try c.tmp();
                    try c.emitBc(.newarr, excluded.?, 0);
                }
                for (props) |p| {
                    if (p.is_rest) {
                        const r = try c.tmp();
                        try c.emit(.newobj, r, 0, 0);
                        try c.emit(.spreadobj, r, val, excluded.?);
                        try c.bindPattern(p.value.data.rest, r, mode);
                        c.release(r);
                        continue;
                    }
                    const item = try c.tmp();
                    if (p.computed) {
                        const k = try c.tmp();
                        _ = try c.expr(p.key, k);
                        try c.emit(.topropkey, k, k, 0);
                        if (excluded) |ex| try c.emit(.arrpush, ex, k, 0);
                        try c.emit(.getelem, item, val, k);
                    } else {
                        const key = try c.keyName(p.key);
                        if (excluded) |ex| {
                            const k = try c.tmp();
                            try c.emitBc(.ldc, k, try c.constString(key));
                            try c.emit(.arrpush, ex, k, 0);
                            c.release(k);
                        }
                        try c.emitProp(item, val, key);
                    }
                    try c.bindPattern(p.value, item, mode);
                    c.release(item);
                }
                c.release(top);
            },
            .rest => |r| try c.bindPattern(r, val, mode),
            .member => try c.assignMember(pat, val),
            else => return c.fail("invalid assignment target", pat.pos),
        }
    }

    fn keyName(c: *Compiler, key: *Node) Error![]const u8 {
        return switch (key.data) {
            .string => |s| s,
            .identifier => |s| s,
            .number => |d| try c.numberKey(d),
            .bigint => |b| b,
            else => return c.fail("bad property key", key.pos),
        };
    }

    fn numberKey(c: *Compiler, d: f64) Error![]const u8 {
        var buf: [64]u8 = undefined;
        const s = numberToString(&buf, d);
        return c.a.dupe(u8, s) catch return error.OutOfMemory;
    }

    /// An array index as a register value (an int, or a number constant
    /// past the int32 range).
    fn loadIndex(c: *Compiler, dst: u16, idx: u32) Error!void {
        if (idx <= std.math.maxInt(i32)) {
            try c.emitBc(.ldint, dst, @bitCast(@as(i32, @intCast(idx))));
        } else try c.emitBc(.ldc, dst, try c.constNumber(@floatFromInt(idx)));
    }

    /// `dst = obj.name`: an index key is an element access.
    fn emitProp(c: *Compiler, dst: u16, obj: u16, name: []const u8) Error!void {
        if (arrayIndex(name)) |idx| {
            const k = try c.tmp();
            try c.loadIndex(k, idx);
            try c.emit(.getelem, dst, obj, k);
            c.release(k);
            return;
        }
        try c.emit(.getprop, dst, obj, try c.propSite(name));
    }

    fn emitSetProp(c: *Compiler, obj: u16, name: []const u8, val: u16) Error!void {
        if (arrayIndex(name)) |idx| {
            const k = try c.tmp();
            try c.loadIndex(k, idx);
            try c.emit(.setelem, obj, k, val);
            c.release(k);
            return;
        }
        try c.emit(.setprop, obj, try c.propSite(name), val);
    }

    /// Assignment to a member expression target.
    fn assignMember(c: *Compiler, target: *Node, val: u16) Error!void {
        const m = target.data.member;
        const top = c.fs.top;
        defer c.release(top);
        if (m.object.data == .super) {
            const base = try c.superBase(m.property, m.computed);
            try c.emit(.setsuper, base, 0, val);
            return;
        }
        const obj = try c.expr(m.object, null);
        if (m.property.data == .private_name) {
            const key = try c.tmp();
            try c.load(c.resolve(m.property.data.private_name), key, m.property.data.private_name);
            try c.emit(.setpriv, obj, key, val);
        } else if (m.computed) {
            const k = try c.expr(m.property, null);
            try c.emit(.setelem, obj, k, val);
        } else {
            try c.emitSetProp(obj, m.property.data.string, val);
        }
    }

    // ---------------------------------------------------- expressions

    /// Compile `n`; the result is in `dst` when given, else in the
    /// returned register (a fresh temporary or a local's own register).
    fn expr(c: *Compiler, n: *Node, dst: ?u16) Error!u16 {
        switch (n.data) {
            .identifier => |name| {
                if (std.mem.eql(u8, name, "undefined")) {
                    // Only the global one is a constant; a local shadows it.
                    const ref = c.resolve(name);
                    if (ref == .global) {
                        const d = dst orelse try c.tmp();
                        try c.emit(.ldundef, d, 0, 0);
                        return d;
                    }
                }
                const ref = c.resolve(name);
                if (dst == null) {
                    if (ref == .reg and !c.isTdz(ref.reg)) return ref.reg;
                }
                const d = dst orelse try c.tmp();
                try c.load(ref, d, name);
                return d;
            },
            .number => |v| {
                const d = dst orelse try c.tmp();
                if (v == @trunc(v) and @abs(v) < 2147483648.0 and !(v == 0 and std.math.signbit(v))) {
                    try c.emitBc(.ldint, d, @bitCast(@as(i32, @intFromFloat(v))));
                } else try c.emitBc(.ldc, d, try c.constNumber(v));
                return d;
            },
            .string => |s| {
                const d = dst orelse try c.tmp();
                try c.emitBc(.ldc, d, try c.constString(s));
                return d;
            },
            .bigint => |s| {
                const d = dst orelse try c.tmp();
                try c.emitBc(.bigint, d, try c.constString(s));
                return d;
            },
            .null_lit => {
                const d = dst orelse try c.tmp();
                try c.emit(.ldnull, d, 0, 0);
                return d;
            },
            .bool_lit => |b| {
                const d = dst orelse try c.tmp();
                try c.emit(if (b) .ldtrue else .ldfalse, d, 0, 0);
                return d;
            },
            .this => {
                if (dst == null) if (c.fs.this_reg) |r| return r;
                const d = dst orelse try c.tmp();
                try c.loadThis(d);
                return d;
            },
            .new_target => {
                const d = dst orelse try c.tmp();
                try c.loadImplicit("new.target", d, .ldnewtarget);
                return d;
            },
            .template => |t| return c.template(t, dst),
            .tagged_template => |t| return c.taggedTemplate(t.tag, t.quasi, dst),
            .regexp => |r| {
                const d = dst orelse try c.tmp();
                try c.emit(.regexp, d, @intCast(try c.constString(r.pattern)), @intCast(try c.constString(r.flags)));
                return d;
            },
            .array => |els| {
                const d = dst orelse try c.tmp();
                try c.emitBc(.newarr, d, @intCast(els.len));
                for (els) |el| {
                    const top = c.fs.top;
                    if (el) |e| {
                        if (e.data == .spread) {
                            const r = try c.expr(e.data.spread, null);
                            try c.emit(.arrspread, d, r, 0);
                        } else {
                            const r = try c.expr(e, null);
                            try c.emit(.arrpush, d, r, 0);
                        }
                    } else {
                        const r = try c.tmp();
                        try c.emit(.ldempty, r, 0, 0);
                        try c.emit(.arrpush, d, r, 0);
                    }
                    c.release(top);
                }
                return d;
            },
            .object => |props| return c.objectLiteral(props, dst),
            .function => |f| {
                const d = dst orelse try c.tmp();
                try c.closure(f, d, f.name);
                return d;
            },
            .class => |cl| {
                const d = dst orelse try c.tmp();
                try c.classExpr(cl, d);
                return d;
            },
            .unary => |u| return c.unary(u.op, u.arg, dst, n.pos),
            .update => |u| return c.update(u.increment, u.prefix, u.arg, dst),
            .binary => |b| {
                if (b.op == .in and b.left.data == .private_name) {
                    const d = dst orelse try c.tmp();
                    const top = c.fs.top;
                    const key = try c.tmp();
                    try c.load(c.resolve(b.left.data.private_name), key, b.left.data.private_name);
                    const obj = try c.expr(b.right, null);
                    try c.emit(.haspriv, d, key, obj);
                    c.release(@max(top, d + 1));
                    return d;
                }
                if ((b.op == .eq or b.op == .ne) and (c.isNullishLiteral(b.left) or c.isNullishLiteral(b.right))) {
                    // `x == null`: one test instead of a load and a compare.
                    const other = if (c.isNullishLiteral(b.right)) b.left else b.right;
                    const d = dst orelse try c.tmp();
                    const top = c.fs.top;
                    const x = try c.expr(other, null);
                    try c.emit(if (b.op == .eq) .isnullish else .isnnullish, d, x, 0);
                    c.release(@max(top, d + 1));
                    return d;
                }
                const d = dst orelse try c.tmp();
                const top = c.fs.top;
                const l = try c.operand(b.left, b.right);
                const r = try c.expr(b.right, null);
                try c.emit(binaryOp(b.op), d, l, r);
                c.release(@max(top, d + 1));
                return d;
            },
            .logical => |l| {
                const d = dst orelse try c.tmp();
                _ = try c.expr(l.left, d);
                const j = try c.jump(switch (l.op) {
                    .@"and" => .jf,
                    .@"or" => .jt,
                    .nullish => .jnnullish,
                }, d);
                _ = try c.expr(l.right, d);
                c.patchHere(j);
                return d;
            },
            .assign => |as| return c.assign(as.op, as.target, as.value, dst),
            .conditional => |cd| {
                const d = dst orelse try c.tmp();
                const top = c.fs.top;
                const cond = try c.expr(cd.cond, null);
                const jf = try c.jump(.jf, cond);
                c.release(@max(top, d + 1));
                _ = try c.expr(cd.then, d);
                const jend = try c.jump(.jmp, 0);
                c.patchHere(jf);
                _ = try c.expr(cd.otherwise, d);
                c.patchHere(jend);
                return d;
            },
            .call => |cl| return c.call(cl.callee, cl.args, cl.optional, dst, n.pos),
            .new => |nw| return c.construct(nw.callee, nw.args, dst, n.pos),
            .member => |m| return c.member(m.object, m.property, m.computed, m.optional, dst),
            .optional_chain => |inner| {
                const d = dst orelse try c.tmp();
                var chain = Chain{ .dst = d };
                defer chain.jumps.deinit(c.scratch);
                const saved = c.chain;
                c.chain = &chain;
                _ = try c.expr(inner, d);
                c.chain = saved;
                if (chain.jumps.items.len > 0) {
                    const jend = try c.jump(.jmp, 0);
                    for (chain.jumps.items) |j| c.patchHere(j);
                    try c.emit(.ldundef, d, 0, 0);
                    c.patchHere(jend);
                }
                return d;
            },
            .sequence => |xs| {
                for (xs[0 .. xs.len - 1]) |x| {
                    const top = c.fs.top;
                    _ = try c.expr(x, null);
                    c.release(top);
                }
                return c.expr(xs[xs.len - 1], dst);
            },
            .spread => return c.fail("unexpected spread", n.pos),
            .yield => |y| {
                if (y.delegate) return c.yieldStar(y.arg.?, dst);
                const d = dst orelse try c.tmp();
                const top = c.fs.top;
                var arg = if (y.arg) |x| try c.expr(x, null) else blk: {
                    const t = try c.tmp();
                    try c.emit(.ldundef, t, 0, 0);
                    break :blk t;
                };
                // Yield in an async generator awaits its operand first (§27.5.3.7).
                if (c.fs.co == .async_gen) arg = try c.awaitInto(arg, null);
                const k = try c.tmp();
                try c.emit(.yield, d, arg, k);
                try c.resumeDispatch(d, k);
                c.release(@max(top, d + 1));
                return d;
            },
            .await => |x| {
                const d = dst orelse try c.tmp();
                const top = c.fs.top;
                const arg = try c.expr(x, null);
                _ = try c.awaitInto(arg, d);
                c.release(@max(top, d + 1));
                return d;
            },
            .import_meta => {
                const d = dst orelse try c.tmp();
                try c.emit(.importmeta, d, 0, 0);
                return d;
            },
            .import_call => |ic| {
                const d = dst orelse try c.tmp();
                const top = c.fs.top;
                const s = try c.expr(ic.source, null);
                try c.emit(.importcall, d, s, 0);
                c.release(@max(top, d + 1));
                return d;
            },
            .super => return c.fail("'super' outside a call or member access", n.pos),
            .private_name => return c.fail("unexpected private name", n.pos),
            .object_pattern, .array_pattern, .assign_pattern, .rest => return c.fail("unexpected pattern", n.pos),
            else => return c.fail("unexpected statement in expression position", n.pos),
        }
    }

    /// The left operand of a binary operator: kept in a temporary when
    /// the right operand could change a local it lives in.
    fn operand(c: *Compiler, left: *Node, right: *Node) Error!u16 {
        const pure = switch (right.data) {
            .identifier, .number, .string, .null_lit, .bool_lit, .this => true,
            else => false,
        };
        if (pure) return c.expr(left, null);
        const r = try c.expr(left, null);
        if (r < c.fs.top and c.isLocalReg(r)) {
            const t = try c.tmp();
            try c.emit(.mov, t, r, 0);
            return t;
        }
        return r;
    }

    fn isLocalReg(c: *Compiler, r: u16) bool {
        if (r < c.fs.nparams) return true;
        var cur: ?*Scope = c.scope;
        while (cur) |s| : (cur = s.parent) {
            if (s.func != c.fs.func) break;
            for (s.bindings.values()) |b| if (b.loc == .reg and b.loc.reg == r) return true;
        }
        return false;
    }

    fn binaryOp(op: ast.BinaryOp) Op {
        return switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .exp => .exp,
            .shl => .shl,
            .shr => .shr,
            .ushr => .ushr,
            .lt => .lt,
            .gt => .gt,
            .le => .le,
            .ge => .ge,
            .eq => .eq,
            .ne => .ne,
            .eq_strict => .seq,
            .ne_strict => .sne,
            .bitand => .band,
            .bitor => .bor,
            .bitxor => .bxor,
            .in => .in,
            .instanceof => .instanceof,
        };
    }

    fn assignOp(op: ast.AssignOp) Op {
        return switch (op) {
            .add => .add,
            .sub => .sub,
            .mul => .mul,
            .div => .div,
            .mod => .mod,
            .exp => .exp,
            .shl => .shl,
            .shr => .shr,
            .ushr => .ushr,
            .bitand => .band,
            .bitor => .bor,
            .bitxor => .bxor,
            else => unreachable,
        };
    }

    fn unary(c: *Compiler, op: ast.UnaryOp, arg: *Node, dst: ?u16, at: u32) Error!u16 {
        _ = at;
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        switch (op) {
            .typeof => {
                if (arg.data == .identifier) {
                    const ref = c.resolve(arg.data.identifier);
                    switch (ref) {
                        .global => |g| {
                            try c.emitBc(.typeofglobal, d, g);
                            return d;
                        },
                        .dynamic => |nm| {
                            try c.emitBc(.typeofname, d, nm);
                            return d;
                        },
                        else => {},
                    }
                }
                const r = try c.expr(arg, null);
                try c.emit(.typeof, d, r, 0);
            },
            .delete => {
                switch (arg.data) {
                    .member => |m| {
                        if (m.object.data == .super) {
                            // delete super.x: ReferenceError after evaluating.
                            try c.emitBc(.throwref, 0, try c.constString("unsupported reference to 'super'"));
                            return d;
                        }
                        const obj = try c.expr(m.object, null);
                        const k = try c.tmp();
                        if (m.computed) {
                            _ = try c.expr(m.property, k);
                        } else try c.emitBc(.ldc, k, try c.constString(m.property.data.string));
                        try c.emit(.delprop, d, obj, k);
                    },
                    .identifier => |name| {
                        const ref = c.resolve(name);
                        switch (ref) {
                            .dynamic => |nm| try c.emitBc(.delname, d, nm),
                            .global => |g| {
                                // delete of a global property.
                                _ = g;
                                try c.emitBc(.delname, d, try c.constString(name));
                            },
                            else => try c.emit(.ldfalse, d, 0, 0),
                        }
                    },
                    .optional_chain => |inner| {
                        // delete a?.b
                        var chain = Chain{ .dst = d };
                        defer chain.jumps.deinit(c.scratch);
                        const saved = c.chain;
                        c.chain = &chain;
                        const m = inner.data.member;
                        const obj = try c.expr(m.object, null);
                        if (m.optional) try chain.jumps.append(c.scratch, try c.jump(.jnullish, obj));
                        const k = try c.tmp();
                        if (m.computed) {
                            _ = try c.expr(m.property, k);
                        } else try c.emitBc(.ldc, k, try c.constString(m.property.data.string));
                        try c.emit(.delprop, d, obj, k);
                        c.chain = saved;
                        const jend = try c.jump(.jmp, 0);
                        for (chain.jumps.items) |j| c.patchHere(j);
                        try c.emit(.ldundef, d, 0, 0);
                        c.patchHere(jend);
                    },
                    else => {
                        _ = try c.expr(arg, null);
                        try c.emit(.ldtrue, d, 0, 0);
                    },
                }
            },
            .void => {
                _ = try c.expr(arg, null);
                try c.emit(.ldundef, d, 0, 0);
            },
            .neg => {
                const r = try c.expr(arg, null);
                try c.emit(.neg, d, r, 0);
            },
            .pos => {
                const r = try c.expr(arg, null);
                try c.emit(.pos, d, r, 0);
            },
            .not => {
                const r = try c.expr(arg, null);
                try c.emit(.not, d, r, 0);
            },
            .bitnot => {
                const r = try c.expr(arg, null);
                try c.emit(.bnot, d, r, 0);
            },
        }
        return d;
    }

    /// Whether the expression `n` may read or write the binding `name`:
    /// conservative (any node kind not listed says yes). A function or
    /// class inside cannot reach a register local without capturing it,
    /// and a captured binding is not a register local.
    fn mentions(n: *Node, name: []const u8) bool {
        return switch (n.data) {
            .identifier => |id| std.mem.eql(u8, id, name),
            .private_name, .number, .bigint, .string, .regexp, .null_lit, .bool_lit, .this, .super, .new_target, .import_meta, .function, .class => false,
            .template => |t| mentionsAny(t.exprs, name),
            .tagged_template => |t| mentions(t.tag, name) or mentions(t.quasi, name),
            .array => |els| {
                for (els) |e| if (e) |x| if (mentions(x, name)) return true;
                return false;
            },
            .object => |props| {
                for (props) |p| {
                    if (p.computed and mentions(p.key, name)) return true;
                    if (mentions(p.value, name)) return true;
                }
                return false;
            },
            .unary => |u| mentions(u.arg, name),
            .update => |u| mentions(u.arg, name),
            .binary => |b| mentions(b.left, name) or mentions(b.right, name),
            .logical => |b| mentions(b.left, name) or mentions(b.right, name),
            .assign => |a| mentions(a.target, name) or mentions(a.value, name),
            .conditional => |t| mentions(t.cond, name) or mentions(t.then, name) or mentions(t.otherwise, name),
            .call => |k| mentions(k.callee, name) or mentionsAny(k.args, name),
            .new => |k| mentions(k.callee, name) or mentionsAny(k.args, name),
            .member => |m| mentions(m.object, name) or (m.computed and mentions(m.property, name)),
            .optional_chain => |x| mentions(x, name),
            .sequence => |xs| mentionsAny(xs, name),
            .spread => |x| mentions(x, name),
            else => true,
        };
    }

    fn mentionsAny(xs: []*Node, name: []const u8) bool {
        for (xs) |x| if (mentions(x, name)) return true;
        return false;
    }

    /// `null`, or the global `undefined` (a local of that name shadows it).
    fn isNullishLiteral(c: *Compiler, n: *Node) bool {
        if (n.data == .null_lit) return true;
        if (n.data == .identifier and std.mem.eql(u8, n.data.identifier, "undefined")) return c.resolve("undefined") == .global;
        return false;
    }

    /// `i++`/`i--` whose value nobody reads, on a register local: one
    /// instruction in place (the general form is five).
    fn updateDiscard(c: *Compiler, e: *Node) Error!bool {
        if (e.data != .update) return false;
        const u = e.data.update;
        if (u.arg.data != .identifier) return false;
        const ref = c.resolve(u.arg.data.identifier);
        if (ref != .reg or c.isTdz(ref.reg)) return false;
        try c.emit(if (u.increment) .inc else .dec, ref.reg, ref.reg, 0);
        return true;
    }

    fn update(c: *Compiler, increment: bool, prefix: bool, arg: *Node, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        const op: Op = if (increment) .inc else .dec;
        switch (arg.data) {
            .identifier => |name| {
                const ref = c.resolve(name);
                const old = try c.tmp();
                try c.load(ref, old, name);
                try c.emit(.tonumeric, old, old, 0);
                const new = try c.tmp();
                try c.emit(op, new, old, 0);
                try c.store(ref, new, name);
                try c.emit(.mov, d, if (prefix) new else old, 0);
            },
            .member => |m| {
                if (m.object.data == .super) {
                    const base = try c.superBase(m.property, m.computed);
                    const old = try c.tmp();
                    try c.emit(.getsuper, old, base, 0);
                    try c.emit(.tonumeric, old, old, 0);
                    const new = try c.tmp();
                    try c.emit(op, new, old, 0);
                    try c.emit(.setsuper, base, 0, new);
                    try c.emit(.mov, d, if (prefix) new else old, 0);
                    return d;
                }
                const obj = try c.expr(m.object, null);
                const old = try c.tmp();
                const new = try c.tmp();
                if (m.property.data == .private_name) {
                    const key = try c.tmp();
                    try c.load(c.resolve(m.property.data.private_name), key, m.property.data.private_name);
                    try c.emit(.getpriv, old, obj, key);
                    try c.emit(.tonumeric, old, old, 0);
                    try c.emit(op, new, old, 0);
                    try c.emit(.setpriv, obj, key, new);
                } else if (m.computed) {
                    const k = try c.tmp();
                    _ = try c.expr(m.property, k);
                    try c.emit(.topropkey, k, k, 0);
                    try c.emit(.getelem, old, obj, k);
                    try c.emit(.tonumeric, old, old, 0);
                    try c.emit(op, new, old, 0);
                    try c.emit(.setelem, obj, k, new);
                } else {
                    const name = m.property.data.string;
                    try c.emitProp(old, obj, name);
                    try c.emit(.tonumeric, old, old, 0);
                    try c.emit(op, new, old, 0);
                    try c.emitSetProp(obj, name, new);
                }
                try c.emit(.mov, d, if (prefix) new else old, 0);
            },
            else => return c.fail("invalid update target", arg.pos),
        }
        return d;
    }

    fn assign(c: *Compiler, op: ast.AssignOp, target: *Node, val: *Node, dst: ?u16) Error!u16 {
        const top = c.fs.top;
        switch (op) {
            .assign => {
                switch (target.data) {
                    .identifier => |name| {
                        const ref = c.resolve(name);
                        // Into the local's register directly when possible.
                        const direct: ?u16 = if (ref == .reg and !c.isTdz(ref.reg)) ref.reg else null;
                        const r = if (isAnonymousFunction(val)) blk: {
                            const t = direct orelse dst orelse try c.tmp();
                            try c.namedInto(val, name, t);
                            break :blk t;
                        } else try c.expr(val, direct orelse dst);
                        if (direct == null) try c.store(ref, r, name);
                        if (dst) |d| {
                            if (d != r) try c.emit(.mov, d, r, 0);
                            c.release(@max(top, d + 1));
                            return d;
                        }
                        if (direct != null) return r;
                        c.release(@max(top, r + 1));
                        return r;
                    },
                    .member => {
                        const d = dst orelse try c.tmp();
                        const t2 = c.fs.top;
                        const m = target.data.member;
                        // Evaluate the target's object (and key) first.
                        if (m.object.data == .super) {
                            const base = try c.superBase(m.property, m.computed);
                            _ = try c.expr(val, d);
                            try c.emit(.setsuper, base, 0, d);
                        } else {
                            const obj = try c.exprTemp(m.object);
                            if (m.property.data == .private_name) {
                                const key = try c.tmp();
                                try c.load(c.resolve(m.property.data.private_name), key, m.property.data.private_name);
                                _ = try c.expr(val, d);
                                try c.emit(.setpriv, obj, key, d);
                            } else if (m.computed) {
                                const k = try c.exprTemp(m.property);
                                _ = try c.expr(val, d);
                                try c.emit(.setelem, obj, k, d);
                            } else {
                                _ = try c.expr(val, d);
                                try c.emitSetProp(obj, m.property.data.string, d);
                            }
                        }
                        c.release(@max(t2, d + 1));
                        return d;
                    },
                    .object_pattern, .array_pattern => {
                        const d = dst orelse try c.tmp();
                        _ = try c.expr(val, d);
                        try c.bindPattern(target, d, .assign);
                        c.release(@max(top, d + 1));
                        return d;
                    },
                    else => return c.fail("invalid assignment target", target.pos),
                }
            },
            .@"and", .@"or", .nullish => {
                const d = dst orelse try c.tmp();
                const t2 = c.fs.top;
                const jop: Op = switch (op) {
                    .@"and" => .jf,
                    .@"or" => .jt,
                    else => .jnnullish,
                };
                switch (target.data) {
                    .identifier => |name| {
                        const ref = c.resolve(name);
                        try c.load(ref, d, name);
                        const j = try c.jump(jop, d);
                        if (isAnonymousFunction(val)) try c.namedInto(val, name, d) else _ = try c.expr(val, d);
                        try c.store(ref, d, name);
                        c.patchHere(j);
                    },
                    .member => |m| {
                        const obj = try c.exprTemp(m.object);
                        const k = try c.tmp();
                        if (m.property.data == .private_name) {
                            try c.load(c.resolve(m.property.data.private_name), k, m.property.data.private_name);
                            try c.emit(.getpriv, d, obj, k);
                            const j = try c.jump(jop, d);
                            _ = try c.expr(val, d);
                            try c.emit(.setpriv, obj, k, d);
                            c.patchHere(j);
                        } else {
                            if (m.computed) {
                                _ = try c.expr(m.property, k);
                                try c.emit(.topropkey, k, k, 0);
                            } else try c.emitBc(.ldc, k, try c.constString(m.property.data.string));
                            try c.emit(.getelem, d, obj, k);
                            const j = try c.jump(jop, d);
                            _ = try c.expr(val, d);
                            try c.emit(.setelem, obj, k, d);
                            c.patchHere(j);
                        }
                    },
                    else => return c.fail("invalid assignment target", target.pos),
                }
                c.release(@max(t2, d + 1));
                return d;
            },
            else => {
                const d = dst orelse try c.tmp();
                const t2 = c.fs.top;
                const bop = assignOp(op);
                switch (target.data) {
                    .identifier => |name| {
                        const ref = c.resolve(name);
                        if (ref == .reg and !c.isTdz(ref.reg) and !mentions(val, name)) {
                            // `x += e` on a register local: one instruction
                            // writing the register. Only when `e` cannot
                            // touch `x` — `x += (x = 3)` reads the old `x`
                            // first, as the operator says.
                            const r = try c.expr(val, null);
                            try c.emit(bop, ref.reg, ref.reg, r);
                            if (dst) |dd| if (dd != ref.reg) try c.emit(.mov, dd, ref.reg, 0);
                            c.release(@max(t2, d + 1));
                            return if (dst) |dd| dd else ref.reg;
                        }
                        const old = try c.tmp();
                        try c.load(ref, old, name);
                        const r = try c.expr(val, null);
                        try c.emit(bop, d, old, r);
                        try c.store(ref, d, name);
                    },
                    .member => |m| {
                        if (m.object.data == .super) {
                            const base = try c.superBase(m.property, m.computed);
                            const old = try c.tmp();
                            try c.emit(.getsuper, old, base, 0);
                            const r = try c.expr(val, null);
                            try c.emit(bop, d, old, r);
                            try c.emit(.setsuper, base, 0, d);
                        } else {
                            const obj = try c.exprTemp(m.object);
                            const old = try c.tmp();
                            if (m.property.data == .private_name) {
                                const k = try c.tmp();
                                try c.load(c.resolve(m.property.data.private_name), k, m.property.data.private_name);
                                try c.emit(.getpriv, old, obj, k);
                                const r = try c.expr(val, null);
                                try c.emit(bop, d, old, r);
                                try c.emit(.setpriv, obj, k, d);
                            } else if (m.computed) {
                                const k = try c.tmp();
                                _ = try c.expr(m.property, k);
                                try c.emit(.topropkey, k, k, 0);
                                try c.emit(.getelem, old, obj, k);
                                const r = try c.expr(val, null);
                                try c.emit(bop, d, old, r);
                                try c.emit(.setelem, obj, k, d);
                            } else {
                                const name = m.property.data.string;
                                try c.emitProp(old, obj, name);
                                const r = try c.expr(val, null);
                                try c.emit(bop, d, old, r);
                                try c.emitSetProp(obj, name, d);
                            }
                        }
                    },
                    else => return c.fail("invalid assignment target", target.pos),
                }
                c.release(@max(t2, d + 1));
                return d;
            },
        }
    }

    /// An expression into a fresh temporary (never a local's register).
    fn exprTemp(c: *Compiler, n: *Node) Error!u16 {
        const t = try c.tmp();
        _ = try c.expr(n, t);
        return t;
    }

    /// `dst = await reg` with the throw resumption rethrown here.
    fn awaitInto(c: *Compiler, reg: u16, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        const k = try c.tmp();
        try c.emit(.await, d, reg, k);
        try c.throwDispatch(d, k);
        c.release(k);
        return d;
    }

    /// After a suspension: a throw resumption (kind 1) rethrows here.
    fn throwDispatch(c: *Compiler, d: u16, k: u16) Error!void {
        const t = try c.tmp();
        try c.emitBc(.ldint, t, 1);
        try c.emit(.seq, t, k, t);
        const j = try c.jump(.jf, t);
        try c.emit(.throw, d, 0, 0);
        c.patchHere(j);
        c.release(t);
    }

    /// After a yield: throw (kind 1) rethrows, return (kind 2) returns
    /// through the enclosing finally blocks and iterator closes; an
    /// async generator awaits the returned value first.
    fn resumeDispatch(c: *Compiler, d: u16, k: u16) Error!void {
        try c.throwDispatch(d, k);
        const t = try c.tmp();
        try c.emitBc(.ldint, t, 2);
        try c.emit(.seq, t, k, t);
        const j = try c.jump(.jf, t);
        var r = d;
        if (c.fs.co == .async_gen) r = try c.awaitInto(d, null);
        try c.emitReturn(r);
        c.patchHere(j);
        c.release(t);
    }

    /// `yield* iterable` (§27.5.3.7 step 7): drive the inner iterator,
    /// forwarding next/throw/return resumptions; the inner result
    /// objects are yielded as they are in a sync generator, their
    /// values in an async one.
    fn yieldStar(c: *Compiler, arg: *Node, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        const is_async = c.fs.co == .async_gen;
        const obj = try c.expr(arg, null);
        const base = try c.tmps(4); // iterator, next, kind, received
        try c.emit(if (is_async) .iterasync else .iter, base, obj, 0);
        try c.emitBc(.ldint, base + 2, 0);
        try c.emit(.ldundef, base + 3, 0, 0);
        const r = try c.tmps(2); // inner result, done
        const loop = c.pc();
        try c.emit(.ystep, r, base, 0);
        // No `return` method on the inner iterator: return what was received.
        const jret = try c.jump(.jempty, r);
        if (is_async) {
            _ = try c.awaitInto(r, r);
            try c.emit(.chkobj, r, 0, 0);
        }
        try c.emit(.iterdone, r + 1, r, 0);
        const jdone = try c.jump(.jt, r + 1);
        if (is_async) {
            const v = try c.tmp();
            try c.emit(.itervalue, v, r, 0);
            try c.emit(.yield, base + 3, v, base + 2);
            c.release(v);
        } else {
            try c.emit(.yieldraw, base + 3, r, base + 2);
        }
        // A return resumption in an async generator awaits its value.
        if (is_async) {
            const t = try c.tmp();
            try c.emitBc(.ldint, t, 2);
            try c.emit(.seq, t, base + 2, t);
            const jn = try c.jump(.jf, t);
            _ = try c.awaitInto(base + 3, base + 3);
            c.patchHere(jn);
            c.release(t);
        }
        try c.emitBc(.jmp, 0, loop);
        c.patchHere(jdone);
        // Done: the value is the expression's result, or what is returned
        // when the outer resumption was a return.
        try c.emit(.itervalue, d, r, 0);
        const t = try c.tmp();
        try c.emitBc(.ldint, t, 2);
        try c.emit(.seq, t, base + 2, t);
        const jend = try c.jump(.jf, t);
        try c.emitReturn(d);
        c.patchHere(jret);
        try c.emitReturn(base + 3);
        c.patchHere(jend);
        c.release(@max(top, d + 1));
        return d;
    }

    /// Three registers for a super property reference: home, this, key.
    fn superBase(c: *Compiler, property: *Node, computed: bool) Error!u16 {
        const base = try c.tmps(3);
        try c.loadImplicit(".home", base, .ldhome);
        try c.loadThis(base + 1);
        if (computed) {
            _ = try c.expr(property, base + 2);
            try c.emit(.topropkey, base + 2, base + 2, 0);
        } else try c.emitBc(.ldc, base + 2, try c.constString(property.data.string));
        return base;
    }

    fn member(c: *Compiler, object: *Node, property: *Node, computed: bool, optional: bool, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        if (object.data == .super) {
            const base = try c.superBase(property, computed);
            try c.emit(.getsuper, d, base, 0);
            return d;
        }
        const obj = try c.expr(object, null);
        if (optional) try c.chain.?.jumps.append(c.scratch, try c.jump(.jnullish, obj));
        if (property.data == .private_name) {
            const key = try c.tmp();
            try c.load(c.resolve(property.data.private_name), key, property.data.private_name);
            try c.emit(.getpriv, d, obj, key);
        } else if (computed) {
            const k = try c.expr(property, null);
            try c.emit(.getelem, d, obj, k);
        } else {
            try c.emitProp(d, obj, property.data.string);
        }
        return d;
    }

    fn hasSpread(args: []*Node) bool {
        for (args) |a| if (a.data == .spread) return true;
        return false;
    }

    /// Arguments into an array register (spread calls).
    fn argsArray(c: *Compiler, args: []*Node, arr: u16) Error!void {
        try c.emitBc(.newarr, arr, @intCast(args.len));
        for (args) |a| {
            const top = c.fs.top;
            if (a.data == .spread) {
                const r = try c.expr(a.data.spread, null);
                try c.emit(.arrspread, arr, r, 0);
            } else {
                const r = try c.expr(a, null);
                try c.emit(.arrpush, arr, r, 0);
            }
            c.release(top);
        }
    }

    fn call(c: *Compiler, callee: *Node, args: []*Node, optional: bool, dst: ?u16, at: u32) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        const spread = hasSpread(args);
        // super(...)
        if (callee.data == .super) {
            const base = try c.tmps(2);
            try c.loadImplicit(".func", base, .ldfunc);
            try c.loadImplicit("new.target", base + 1, .ldnewtarget);
            if (spread) {
                const arr = try c.tmp();
                try c.argsArray(args, arr);
                try c.pos(at);
                try c.emit(.supercallspread, d, base, 0);
            } else {
                const abase = try c.tmps(@intCast(args.len));
                for (args, 0..) |a, i| _ = try c.expr(a, abase + @as(u16, @intCast(i)));
                try c.pos(at);
                try c.emit(.supercall, d, base, @intCast(args.len));
            }
            // Bind this.
            try c.storeThis(d);
            return d;
        }
        // Direct eval.
        if (callee.data == .identifier and std.mem.eql(u8, callee.data.identifier, "eval") and !spread) {
            const base = try c.tmps(2);
            try c.load(c.resolve("eval"), base, "eval");
            try c.emit(.ldundef, base + 1, 0, 0);
            const abase = try c.tmps(@intCast(args.len));
            for (args, 0..) |a, i| _ = try c.expr(a, abase + @as(u16, @intCast(i)));
            try c.pos(at);
            try c.emit(.eval, d, base, @intCast(args.len));
            return d;
        }
        const base = try c.tmps(2);
        // The callee and its this.
        switch (callee.data) {
            .member => |m| {
                if (m.object.data == .super) {
                    try c.loadThis(base + 1);
                    const sb = try c.superBase(m.property, m.computed);
                    try c.emit(.getsuper, base, sb, 0);
                    c.release(sb);
                } else {
                    _ = try c.expr(m.object, base + 1);
                    if (m.optional) try c.chain.?.jumps.append(c.scratch, try c.jump(.jnullish, base + 1));
                    if (m.property.data == .private_name) {
                        const key = try c.tmp();
                        try c.load(c.resolve(m.property.data.private_name), key, m.property.data.private_name);
                        try c.emit(.getpriv, base, base + 1, key);
                        c.release(key);
                    } else if (m.computed) {
                        const k = try c.expr(m.property, null);
                        try c.emit(.getelem, base, base + 1, k);
                        c.release(base + 2);
                    } else {
                        try c.emitProp(base, base + 1, m.property.data.string);
                    }
                }
            },
            .identifier => |name| {
                const ref = c.resolve(name);
                if (ref == .dynamic) {
                    try c.emitBc(.getnamethis, base, ref.dynamic);
                } else {
                    try c.load(ref, base, name);
                    try c.emit(.ldundef, base + 1, 0, 0);
                }
            },
            else => {
                _ = try c.expr(callee, base);
                try c.emit(.ldundef, base + 1, 0, 0);
            },
        }
        if (optional) try c.chain.?.jumps.append(c.scratch, try c.jump(.jnullish, base));
        if (spread) {
            const arr = try c.tmp();
            try c.argsArray(args, arr);
            try c.pos(at);
            try c.emit(.callspread, d, base, 0);
        } else {
            const abase = try c.tmps(@intCast(args.len));
            for (args, 0..) |a, i| _ = try c.expr(a, abase + @as(u16, @intCast(i)));
            try c.pos(at);
            try c.emit(.call, d, base, @intCast(args.len));
        }
        return d;
    }

    /// After super(): bind `this` in the constructor.
    fn storeThis(c: *Compiler, val: u16) Error!void {
        const tf = c.scope.func.this_func;
        if (tf.scope.bindings.get("this")) |b| if (b.loc == .slot) {
            try c.emit(.setenv, val, c.hopsTo(tf.scope), @intCast(b.loc.slot));
            if (tf == c.scope.func) try c.emit(.setthis, val, 0, 0);
            return;
        };
        if (tf.has_eval_refs) {
            try c.emitBc(.setname, val, try c.constString("this"));
        }
        try c.emit(.setthis, val, 0, 0);
    }

    fn construct(c: *Compiler, callee: *Node, args: []*Node, dst: ?u16, at: u32) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        const base = try c.tmp();
        _ = try c.expr(callee, base);
        if (hasSpread(args)) {
            const arr = try c.tmp();
            try c.argsArray(args, arr);
            try c.pos(at);
            try c.emit(.newspread, d, base, 0);
        } else {
            const abase = try c.tmps(@intCast(args.len));
            for (args, 0..) |a, i| _ = try c.expr(a, abase + @as(u16, @intCast(i)));
            try c.pos(at);
            try c.emit(.new, d, base, @intCast(args.len));
        }
        return d;
    }

    fn template(c: *Compiler, t: ast.Template, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        try c.emitBc(.ldc, d, try c.constString(t.cooked[0] orelse ""));
        for (t.exprs, 0..) |e, i| {
            const r = try c.expr(e, null);
            const s = try c.tmp();
            try c.emit(.tostring, s, r, 0);
            try c.emit(.add, d, d, s);
            const next = t.cooked[i + 1] orelse "";
            if (next.len > 0) {
                try c.emitBc(.ldc, s, try c.constString(next));
                try c.emit(.add, d, d, s);
            }
            c.release(s);
        }
        return d;
    }

    fn taggedTemplate(c: *Compiler, tag: *Node, quasi: *Node, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        const top = c.fs.top;
        defer c.release(@max(top, d + 1));
        const t = quasi.data.template;
        const base = try c.tmps(2);
        switch (tag.data) {
            .member => |m| {
                if (m.object.data == .super) {
                    try c.loadThis(base + 1);
                    const sb = try c.superBase(m.property, m.computed);
                    try c.emit(.getsuper, base, sb, 0);
                    c.release(sb);
                } else {
                    _ = try c.expr(m.object, base + 1);
                    if (m.computed) {
                        const k = try c.expr(m.property, null);
                        try c.emit(.getelem, base, base + 1, k);
                        c.release(base + 2);
                    } else if (m.property.data == .private_name) {
                        const key = try c.tmp();
                        try c.load(c.resolve(m.property.data.private_name), key, m.property.data.private_name);
                        try c.emit(.getpriv, base, base + 1, key);
                        c.release(key);
                    } else try c.emitProp(base, base + 1, m.property.data.string);
                }
            },
            else => {
                _ = try c.expr(tag, base);
                try c.emit(.ldundef, base + 1, 0, 0);
            },
        }
        // The template object.
        const cooked = try c.a.alloc(?*String, t.cooked.len);
        const raws = try c.a.alloc(*String, t.raws.len);
        for (t.cooked, 0..) |cs, i| cooked[i] = if (cs) |s| try c.strings.atom(s) else null;
        for (t.raws, 0..) |r, i| raws[i] = try c.strings.atom(r);
        const site: u32 = @intCast(c.fs.templates.items.len);
        try c.fs.templates.append(c.scratch, .{ .cooked = cooked, .raw = raws });
        const abase = try c.tmps(@intCast(1 + t.exprs.len));
        try c.emitBc(.template, abase, site);
        for (t.exprs, 0..) |e, i| _ = try c.expr(e, abase + 1 + @as(u16, @intCast(i)));
        try c.emit(.call, d, base, @intCast(1 + t.exprs.len));
        return d;
    }

    fn objectLiteral(c: *Compiler, props: []ast.Property, dst: ?u16) Error!u16 {
        const d = dst orelse try c.tmp();
        try c.emit(.newobj, d, 0, 0);
        for (props) |p| {
            const top = c.fs.top;
            defer c.release(top);
            switch (p.kind) {
                .spread => {
                    const r = try c.expr(p.value, null);
                    try c.emit(.spreadobj, d, r, 0xffff);
                },
                .init, .shorthand => {
                    if (p.computed) {
                        const k = try c.tmp();
                        _ = try c.expr(p.key, k);
                        try c.emit(.topropkey, k, k, 0);
                        const v = try c.exprNamedComputed(p.value, k);
                        try c.emit(.defelem, d, k, v);
                    } else {
                        const name = try c.keyName(p.key);
                        if (p.kind == .init and !p.computed and p.key.data == .string and std.mem.eql(u8, name, "__proto__")) {
                            const v = try c.expr(p.value, null);
                            try c.emit(.defproto, d, v, 0);
                            continue;
                        }
                        const v = try c.exprNamed(p.value, name);
                        if (arrayIndex(name)) |idx| {
                            const k = try c.tmp();
                            try c.loadIndex(k, idx);
                            try c.emit(.defelem, d, k, v);
                        } else try c.emit(.defown, d, try c.propSite(name), v);
                    }
                },
                .method, .get, .set => {
                    const k = try c.tmp();
                    if (p.computed) {
                        _ = try c.expr(p.key, k);
                        try c.emit(.topropkey, k, k, 0);
                    } else {
                        const name = try c.keyName(p.key);
                        if (arrayIndex(name)) |idx| {
                            try c.loadIndex(k, idx);
                        } else try c.emitBc(.ldc, k, try c.constString(name));
                    }
                    const f = try c.tmp();
                    const fname: ?[]const u8 = if (p.computed) null else try c.keyName(p.key);
                    try c.closure(p.value.data.function, f, fname);
                    try c.emit(switch (p.kind) {
                        .method => .defmethod,
                        .get => .defgetter,
                        else => .defsetter,
                    }, d, k, f);
                },
            }
        }
        return d;
    }

    /// An anonymous function/class value gets `name`.
    fn exprNamed(c: *Compiler, n: *Node, name: []const u8) Error!u16 {
        switch (n.data) {
            .function => |f| if (f.name == null) {
                const d = try c.tmp();
                try c.closure(f, d, name);
                return d;
            },
            .class => |cl| if (cl.name == null) {
                const d = try c.tmp();
                try c.classExprNamed(cl, d, name);
                return d;
            },
            else => {},
        }
        return c.expr(n, null);
    }

    /// The same with a computed key in a register: the VM names it.
    fn exprNamedComputed(c: *Compiler, n: *Node, key: u16) Error!u16 {
        _ = key;
        return c.expr(n, null);
    }

    // ---------------------------------------------------------- classes

    fn classExpr(c: *Compiler, cl: *ast.Class, dst: u16) Error!void {
        try c.classExprNamed(cl, dst, cl.name);
    }

    fn classExprNamed(c: *Compiler, cl: *ast.Class, dst: u16, name: ?[]const u8) Error!void {
        const cs = c.an.scopeOf(cl);
        const saved = c.scope;
        const top = c.fs.top;
        c.scope = cs;
        try c.enterScope(cs);
        if (cs.has_env) try c.fs.controls.append(c.scratch, .env);
        // Private names.
        for (cs.bindings.values()) |b| if (b.kind == .implicit and b.name.len > 0 and b.name[0] == '#') {
            const r = try c.tmp();
            try c.emitBc(.privname, r, try c.constString(b.name));
            try c.initialize(c.resolve(b.name), r, b.name);
            c.release(r);
        };
        // The heritage.
        const parent = try c.tmp();
        if (cl.super_class) |sc| {
            _ = try c.expr(sc, parent);
        } else try c.emit(.ldempty, parent, 0, 0);
        // The constructor.
        var ctor: ?*ast.Function = null;
        for (cl.members) |m| if (m.kind == .method and !m.is_static and !m.computed and m.key.data == .string and std.mem.eql(u8, m.key.data.string, "constructor")) {
            ctor = m.value.?.data.function;
        };
        const ctor_code = if (ctor) |f| try c.function(f, name) else try c.defaultConstructor(cl, name);
        const fidx: u32 = @intCast(c.fs.functions.items.len);
        try c.fs.functions.append(c.scratch, ctor_code);
        try c.emit(.class, dst, parent, @intCast(fidx));
        const proto = try c.tmp();
        try c.emit(.getprop, proto, dst, try c.propSite("prototype"));
        // Members: methods and accessors now; fields into initializers.
        var key_n: usize = 0;
        var instance_fields: std.ArrayList(ast.Class.Member) = .empty;
        defer instance_fields.deinit(c.scratch);
        var static_inits: std.ArrayList(ast.Class.Member) = .empty;
        defer static_inits.deinit(c.scratch);
        var private_methods: std.ArrayList(ast.Class.Member) = .empty;
        defer private_methods.deinit(c.scratch);
        for (cl.members) |m| {
            if (m.kind == .method and !m.is_static and !m.computed and m.key.data == .string and std.mem.eql(u8, m.key.data.string, "constructor")) continue;
            const mtop = c.fs.top;
            defer c.release(mtop);
            switch (m.kind) {
                .method, .getter, .setter => {
                    const home = if (m.is_static) dst else proto;
                    if (m.key.data == .private_name) {
                        // Private methods: installed per instance (or on the
                        // constructor for static ones).
                        if (m.is_static) {
                            const key = try c.tmp();
                            try c.load(c.resolve(m.key.data.private_name), key, m.key.data.private_name);
                            const f = try c.tmp();
                            try c.closure(m.value.?.data.function, f, m.key.data.private_name);
                            try c.emit(.sethome, f, home, 0);
                            try c.emit(switch (m.kind) {
                                .method => .defprivmethod,
                                .getter => .defgetterc,
                                else => .defsetterc,
                            }, home, key, f);
                        } else try private_methods.append(c.scratch, m);
                        continue;
                    }
                    const k = try c.tmp();
                    if (m.computed) {
                        _ = try c.expr(m.key, k);
                        try c.emit(.topropkey, k, k, 0);
                    } else {
                        const kn = try c.keyName(m.key);
                        if (arrayIndex(kn)) |idx| {
                            try c.loadIndex(k, idx);
                        } else try c.emitBc(.ldc, k, try c.constString(kn));
                    }
                    const f = try c.tmp();
                    const fname: ?[]const u8 = if (m.computed) null else try c.keyName(m.key);
                    try c.closure(m.value.?.data.function, f, fname);
                    try c.emit(switch (m.kind) {
                        .method => .defmethodc,
                        .getter => .defgetterc,
                        else => .defsetterc,
                    }, home, k, f);
                },
                .field => {
                    if (m.computed) {
                        // Evaluate the key once, into the class scope.
                        var buf: [16]u8 = undefined;
                        const nm = std.fmt.bufPrint(&buf, ".key{d}", .{key_n}) catch unreachable;
                        key_n += 1;
                        const k = try c.tmp();
                        _ = try c.expr(m.key, k);
                        try c.emit(.topropkey, k, k, 0);
                        try c.initialize(c.resolve(nm), k, nm);
                    }
                    if (m.is_static) try static_inits.append(c.scratch, m) else try instance_fields.append(c.scratch, m);
                },
                .static_block => try static_inits.append(c.scratch, m),
            }
        }
        // The instance field initializer.
        if (instance_fields.items.len > 0 or private_methods.items.len > 0) {
            const init_code = try c.fieldInitializer(cl, instance_fields.items, private_methods.items, false, proto);
            const iidx: u32 = @intCast(c.fs.functions.items.len);
            try c.fs.functions.append(c.scratch, init_code);
            const f = try c.tmp();
            try c.emitBc(.closure, f, iidx);
            try c.emit(.sethome, f, proto, 0);
            try c.emit(.setfields, dst, f, 0);
            c.release(f);
        }
        // Static fields and blocks, in order, with this = the class.
        if (static_inits.items.len > 0) {
            const init_code = try c.fieldInitializer(cl, static_inits.items, &.{}, true, dst);
            const sidx: u32 = @intCast(c.fs.functions.items.len);
            try c.fs.functions.append(c.scratch, init_code);
            const base = try c.tmps(2);
            try c.emitBc(.closure, base, sidx);
            try c.emit(.sethome, base, dst, 0);
            try c.emit(.mov, base + 1, dst, 0);
            const r = try c.tmp();
            try c.emit(.call, r, base, 0);
        }
        // The inner name binding.
        if (cl.name) |n| try c.initialize(c.resolve(n), dst, n);
        if (cs.has_env) _ = c.fs.controls.pop();
        try c.leaveScope(cs);
        c.scope = saved;
        c.release(@max(top, dst + 1));
    }

    /// `constructor(...args) { super(...args); }` or `constructor() {}`.
    fn defaultConstructor(c: *Compiler, cl: *ast.Class, name: ?[]const u8) Error!*Code {
        var fs = FuncState{ .func = c.an.root_func, .parent = c.fs, .strict = true, .env_base = c.env_stack.items.len };
        defer fs.deinit(c.scratch);
        const saved_fs = c.fs;
        c.fs = &fs;
        defer c.fs = saved_fs;
        if (cl.super_class != null) {
            const base = try c.tmps(3);
            try c.emit(.ldfunc, base, 0, 0);
            try c.emit(.ldnewtarget, base + 1, 0, 0);
            try c.emitBc(.initrest, base + 2, 0);
            const r = try c.tmp();
            try c.emit(.supercallspread, r, base, 0);
            try c.emit(.setthis, r, 0, 0);
        }
        try c.emit(.retundef, 0, 0, 0);
        const code = try c.finish(&fs, name, if (cl.super_class != null) .derived_constructor else .class_constructor, cl.start, cl.end);
        code.data.is_constructor = true;
        code.data.uses_this = true;
        return code;
    }

    /// A synthetic method that defines the fields (and private methods)
    /// on `this`, compiled in the class scope.
    fn fieldInitializer(c: *Compiler, cl: *ast.Class, fields: []const ast.Class.Member, private_methods: []const ast.Class.Member, is_static: bool, home: u16) Error!*Code {
        _ = home;
        _ = cl;
        var fs = FuncState{ .func = c.an.root_func, .parent = c.fs, .strict = true, .env_base = c.env_stack.items.len };
        defer fs.deinit(c.scratch);
        const saved_fs = c.fs;
        c.fs = &fs;
        defer c.fs = saved_fs;
        const this_reg = try c.tmp();
        try c.emit(.ldthis, this_reg, 0, 0);
        for (private_methods) |m| {
            const top = c.fs.top;
            const key = try c.tmp();
            try c.load(c.resolve(m.key.data.private_name), key, m.key.data.private_name);
            const f = try c.tmp();
            try c.closure(m.value.?.data.function, f, m.key.data.private_name);
            try c.emit(.sethome, f, this_reg, 0);
            try c.emit(switch (m.kind) {
                .method => .defprivmethod,
                .getter => .defgetterc,
                else => .defsetterc,
            }, this_reg, key, f);
            c.release(top);
        }
        var key_n: usize = 0;
        // Computed keys were numbered in class order over all fields.
        for (fields) |m| {
            const top = c.fs.top;
            defer c.release(top);
            if (m.kind == .static_block) {
                const base = try c.tmps(2);
                try c.closure(m.value.?.data.function, base, null);
                try c.emit(.sethome, base, this_reg, 0);
                try c.emit(.mov, base + 1, this_reg, 0);
                const r = try c.tmp();
                try c.emit(.call, r, base, 0);
                continue;
            }
            const k = try c.tmp();
            var priv = false;
            if (m.key.data == .private_name) {
                try c.load(c.resolve(m.key.data.private_name), k, m.key.data.private_name);
                priv = true;
            } else if (m.computed) {
                var buf: [16]u8 = undefined;
                const nm = std.fmt.bufPrint(&buf, ".key{d}", .{c.computedKeyIndex(m, &key_n)}) catch unreachable;
                try c.load(c.resolve(nm), k, nm);
            } else {
                const kn = try c.keyName(m.key);
                if (arrayIndex(kn)) |idx| {
                    try c.loadIndex(k, idx);
                } else try c.emitBc(.ldc, k, try c.constString(kn));
            }
            const v = try c.tmp();
            if (m.value) |init| {
                // The initializer is a function (this = the instance):
                // call it as a method.
                const base = try c.tmps(2);
                const fname: ?[]const u8 = if (m.computed or priv) null else try c.keyName(m.key);
                try c.closure(init.data.function, base, fname);
                try c.emit(.sethome, base, this_reg, 0);
                try c.emit(.mov, base + 1, this_reg, 0);
                try c.emit(.call, v, base, 0);
            } else try c.emit(.ldundef, v, 0, 0);
            try c.emit(if (priv) .defpriv else .defelem, this_reg, k, v);
        }
        try c.emit(.retundef, 0, 0, 0);
        _ = is_static;
        return c.finish(&fs, null, .field_init, 0, 0);
    }

    /// The nth computed field key: numbered in class member order.
    fn computedKeyIndex(c: *Compiler, m: ast.Class.Member, counter: *usize) usize {
        _ = c;
        _ = m;
        const i = counter.*;
        counter.* += 1;
        return i;
    }
};

/// A canonical array index (§7.1.21: "0", "17", not "017", below 2^32-1).
pub fn arrayIndex(s: []const u8) ?u32 {
    if (s.len == 0 or s.len > 10) return null;
    if (s.len > 1 and s[0] == '0') return null;
    var v: u64 = 0;
    for (s) |ch| {
        if (ch < '0' or ch > '9') return null;
        v = v * 10 + (ch - '0');
    }
    if (v >= 0xFFFF_FFFF) return null;
    return @intCast(v);
}

/// Number::toString(10) (§6.1.6.1.20), shortest round-trip digits.
pub fn numberToString(buf: []u8, d: f64) []const u8 {
    if (std.math.isNan(d)) return "NaN";
    if (d == 0) return "0";
    if (std.math.isInf(d)) return if (d < 0) "-Infinity" else "Infinity";
    var neg = false;
    var x = d;
    if (x < 0) {
        neg = true;
        x = -x;
    }
    // Shortest digits and exponent via scientific formatting.
    var sbuf: [64]u8 = undefined;
    const sci = std.fmt.float.render(&sbuf, x, .{ .mode = .scientific }) catch return "NaN";
    // sci is like "1.2345e5" or "5e-7".
    const epos = std.mem.indexOfScalar(u8, sci, 'e').?;
    const mant = sci[0..epos];
    const exp = std.fmt.parseInt(i32, sci[epos + 1 ..], 10) catch 0;
    var digits: [32]u8 = undefined;
    var k: usize = 0;
    for (mant) |ch| if (ch != '.') {
        digits[k] = ch;
        k += 1;
    };
    // Strip trailing zeros of the digit string.
    while (k > 1 and digits[k - 1] == '0') k -= 1;
    const n: i32 = exp + 1; // the decimal point position: digits * 10^(n-k)
    var w: usize = 0;
    if (neg) {
        buf[w] = '-';
        w += 1;
    }
    const ki: i32 = @intCast(k);
    if (ki <= n and n <= 21) {
        @memcpy(buf[w .. w + k], digits[0..k]);
        w += k;
        var i: i32 = 0;
        while (i < n - ki) : (i += 1) {
            buf[w] = '0';
            w += 1;
        }
    } else if (0 < n and n <= 21) {
        const nn: usize = @intCast(n);
        @memcpy(buf[w .. w + nn], digits[0..nn]);
        w += nn;
        buf[w] = '.';
        w += 1;
        @memcpy(buf[w .. w + (k - nn)], digits[nn..k]);
        w += k - nn;
    } else if (-6 < n and n <= 0) {
        buf[w] = '0';
        buf[w + 1] = '.';
        w += 2;
        var i: i32 = 0;
        while (i < -n) : (i += 1) {
            buf[w] = '0';
            w += 1;
        }
        @memcpy(buf[w .. w + k], digits[0..k]);
        w += k;
    } else {
        buf[w] = digits[0];
        w += 1;
        if (k > 1) {
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w .. w + k - 1], digits[1..k]);
            w += k - 1;
        }
        buf[w] = 'e';
        w += 1;
        const e = n - 1;
        buf[w] = if (e < 0) '-' else '+';
        w += 1;
        const es = std.fmt.bufPrint(buf[w..], "{d}", .{@abs(e)}) catch unreachable;
        w += es.len;
    }
    return buf[0..w];
}

test "compiler: number to string follows the specification's layout" {
    var buf: [64]u8 = undefined;
    try std.testing.expectEqualStrings("1", numberToString(&buf, 1));
    try std.testing.expectEqualStrings("-1.5", numberToString(&buf, -1.5));
    try std.testing.expectEqualStrings("100", numberToString(&buf, 100));
    try std.testing.expectEqualStrings("0.1", numberToString(&buf, 0.1));
    try std.testing.expectEqualStrings("1e+21", numberToString(&buf, 1e21));
    try std.testing.expectEqualStrings("1e-7", numberToString(&buf, 1e-7));
    try std.testing.expectEqualStrings("0.000001", numberToString(&buf, 1e-6));
    try std.testing.expectEqualStrings("123456789012345680000", numberToString(&buf, 123456789012345678901.0));
    try std.testing.expectEqualStrings("1.7976931348623157e+308", numberToString(&buf, std.math.floatMax(f64)));
    try std.testing.expectEqualStrings("5e-324", numberToString(&buf, 5e-324));
    var tenth: f64 = 0.1;
    _ = &tenth;
    try std.testing.expectEqualStrings("0.30000000000000004", numberToString(&buf, tenth + 0.2));
}

test "compiler: a script compiles to code with the expected shape" {
    const region = try std.testing.allocator.alloc(u8, 1 << 20);
    defer std.testing.allocator.free(region);
    var h = heap.Heap.init(region, std.testing.allocator, testTrace);
    h.finalizer = testFinalize;
    defer h.deinit();
    var strings = string.Strings.init(&h, std.testing.allocator);
    defer strings.deinit();
    const code = try compile(std.testing.allocator, &h, &strings, "var x = 1; function f(a) { return a + x; } f(2);", .{ .lazy = false });
    try std.testing.expect(code.data.insns.len > 5);
    try std.testing.expectEqual(@as(usize, 1), code.data.functions.len);
    try std.testing.expectEqual(@as(u32, 1), code.data.functions[0].data.nparams);
    // f's `a + x`: a is register 0, x a global site.
    var saw_add = false;
    for (code.data.functions[0].data.insns) |i| if (i.op == .add and i.b == 0) {
        saw_add = true;
    };
    try std.testing.expect(saw_add);
}

fn testTrace(_: *heap.Heap, c: *heap.Cell, m: *heap.Marker) void {
    switch (c.kind) {
        .string => string.Strings.trace(c.as(String), m),
        .code => Code.trace(c.as(Code), m),
        else => {},
    }
}
fn testFinalize(h: *heap.Heap, c: *heap.Cell) void {
    if (c.kind == .code) {
        const code = c.as(Code);
        code.data.deinit(h.meta);
        h.meta.destroy(code.data);
    }
}
