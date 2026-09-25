//! Scope analysis, the compiler's first pass: every function, block,
//! catch clause and class in the tree gets a `Scope` listing what it
//! declares, and every identifier reference is resolved once so that a
//! binding used from an inner function is marked `captured`. The
//! emitter then gives an uncaptured binding a register and a captured
//! one a slot in the scope's environment cell — and a function with a
//! direct `eval` or a `with` keeps everything by name, since code it
//! has not seen may ask for it.
//!
//! Declarations follow §8.2 (VarDeclaredNames, LexicallyDeclaredNames)
//! and §10.2.11 FunctionDeclarationInstantiation; the parser has already
//! rejected redeclaration errors.
const std = @import("std");
const ast = @import("ast.zig");
const Node = ast.Node;

pub const BindingKind = enum { @"var", let, @"const", function, param, class, catch_param, implicit, import };

pub const Binding = struct {
    name: []const u8,
    kind: BindingKind,
    captured: bool = false,
    /// A lexical binding starts in its temporal dead zone.
    lexical: bool,
    is_const: bool,
    /// Assigned once by the emitter.
    loc: Loc = .unresolved,
    /// An Annex B.3.3 block function: its var-scoped twin.
    annexb: bool = false,

    pub const Loc = union(enum) { unresolved, reg: u16, slot: u32, global };
};

pub const ScopeKind = enum { script, module, eval, function, params, block, catch_clause, class, with, for_head, switch_block };

pub const Scope = struct {
    kind: ScopeKind,
    parent: ?*Scope,
    func: *Func,
    /// In declaration order: the order of environment slots.
    bindings: std.StringArrayHashMapUnmanaged(*Binding) = .empty,
    /// Function declarations to instantiate at entry.
    hoisted: std.ArrayList(*Node) = .empty,
    /// The scope needs an environment cell: a captured binding, or the
    /// function is dynamic.
    needs_env: bool = false,
    /// Set by the emitter: the scope's environment is on the chain.
    has_env: bool = false,
    /// A `with` scope, or one under it: names resolve at run time.
    dynamic: bool = false,

    pub fn lookup(s: *Scope, name: []const u8) ?*Binding {
        return s.bindings.get(name);
    }
};

pub const Func = struct {
    node: ?*ast.Function,
    parent: ?*Func,
    /// The var scope; for non-simple parameters a separate params
    /// scope encloses it.
    scope: *Scope = undefined,
    params_scope: ?*Scope = null,
    is_arrow: bool = false,
    is_generator: bool = false,
    is_async: bool = false,
    strict: bool = false,
    uses_this: bool = false,
    uses_arguments: bool = false,
    uses_new_target: bool = false,
    uses_super: bool = false,
    uses_super_call: bool = false,
    has_direct_eval: bool = false,
    has_with: bool = false,
    /// Every binding by name in environments: a direct eval or a `with`
    /// in this function or one nested in it may ask for them by name.
    dynamic: bool = false,
    /// This function's own references resolve by name: it contains a
    /// direct eval, which may add bindings that shadow anything.
    has_eval_refs: bool = false,
    /// The `this`-carrying function (itself, or the nearest non-arrow
    /// enclosing one).
    this_func: *Func = undefined,
    kind: ast.Function.Kind = .normal,
    simple_params: bool = true,
};

pub const Error = error{OutOfMemory};

/// The analysis of one program (script, module, or eval code).
pub const Analysis = struct {
    a: std.mem.Allocator,
    /// Scopes by the node that opens them (function nodes map to
    /// their var scope; blocks, loops, catch clauses, classes, switch
    /// and with statements to theirs).
    scopes: std.AutoHashMapUnmanaged(*const anyopaque, *Scope) = .empty,
    funcs: std.AutoHashMapUnmanaged(*const ast.Function, *Func) = .empty,
    root: *Scope = undefined,
    root_func: *Func = undefined,
    all_scopes: std.ArrayList(*Scope) = .empty,
    all_funcs: std.ArrayList(*Func) = .empty,
    /// Eval code: names the enclosing chain may resolve are looked up
    /// at run time; these are the names the eval's own scopes declare.
    eval_mode: bool = false,
    /// Eval code inside a function with `this`, `new.target`, super.
    eval_ctx: EvalContext = .{},

    pub const EvalContext = struct {
        has_this_function: bool = false,
        allow_super: bool = false,
        allow_super_call: bool = false,
        allow_new_target: bool = false,
        no_arguments: bool = false,
        private_names: []const []const u8 = &.{},
        strict: bool = false,
        /// Eval at the top level: var declarations become globals.
        global: bool = true,
        /// This is eval code at all.
        eval: bool = false,
    };

    pub fn init(a: std.mem.Allocator) Analysis {
        return .{ .a = a };
    }

    pub fn deinit(an: *Analysis) void {
        for (an.all_scopes.items) |s| {
            var it = s.bindings.iterator();
            while (it.next()) |e| an.a.destroy(e.value_ptr.*);
            s.bindings.deinit(an.a);
            s.hoisted.deinit(an.a);
            an.a.destroy(s);
        }
        for (an.all_funcs.items) |f| an.a.destroy(f);
        an.all_scopes.deinit(an.a);
        an.all_funcs.deinit(an.a);
        an.scopes.deinit(an.a);
        an.funcs.deinit(an.a);
    }

    pub fn scopeOf(an: *Analysis, node: *const anyopaque) *Scope {
        return an.scopes.get(node).?;
    }
    pub fn funcOf(an: *Analysis, f: *const ast.Function) *Func {
        return an.funcs.get(f).?;
    }

    // -------------------------------------------------------- building

    fn newScope(an: *Analysis, kind: ScopeKind, parent: ?*Scope, func: *Func, key: ?*const anyopaque) Error!*Scope {
        const s = try an.a.create(Scope);
        s.* = .{ .kind = kind, .parent = parent, .func = func };
        if (parent) |p| s.dynamic = p.dynamic;
        try an.all_scopes.append(an.a, s);
        if (key) |k| try an.scopes.put(an.a, k, s);
        return s;
    }

    fn newFunc(an: *Analysis, node: ?*ast.Function, parent: ?*Func) Error!*Func {
        const f = try an.a.create(Func);
        f.* = .{ .node = node, .parent = parent };
        if (node) |n| {
            f.is_arrow = n.is_arrow;
            f.is_generator = n.is_generator;
            f.is_async = n.is_async;
            f.strict = n.strict;
            f.kind = n.kind;
            f.simple_params = n.simple_params;
            try an.funcs.put(an.a, n, f);
        }
        f.this_func = if (f.is_arrow and parent != null) parent.?.this_func else f;
        try an.all_funcs.append(an.a, f);
        return f;
    }

    pub fn declare(an: *Analysis, s: *Scope, name: []const u8, kind: BindingKind) Error!*Binding {
        if (s.bindings.get(name)) |b| {
            // A later declaration of the same var/function name: the
            // function wins for hoisting (handled by the emitter);
            // keep the binding.
            if (kind == .function and b.kind == .@"var") b.kind = .function;
            return b;
        }
        const b = try an.a.create(Binding);
        b.* = .{
            .name = name,
            .kind = kind,
            .lexical = kind == .let or kind == .@"const" or kind == .class or kind == .import,
            .is_const = kind == .@"const" or kind == .import,
        };
        try s.bindings.put(an.a, name, b);
        return b;
    }

    /// The scope `var` declarations land in.
    fn varScope(s: *Scope) *Scope {
        var cur = s;
        while (true) : (cur = cur.parent.?) {
            switch (cur.kind) {
                .function, .script, .module, .eval => return cur,
                else => {},
            }
        }
    }

    // ------------------------------------------------------- analysis

    /// Analyse a program.
    pub fn analyzeProgram(an: *Analysis, prog: *Node) Error!void {
        const p = prog.data.program;
        const f = try an.newFunc(null, null);
        f.strict = p.strict;
        an.root_func = f;
        const kind: ScopeKind = if (an.eval_mode) .eval else if (p.module) .module else .script;
        const s = try an.newScope(kind, null, f, prog);
        f.scope = s;
        an.root = s;
        if (an.eval_mode) {
            f.dynamic = true;
            s.dynamic = true;
            f.has_direct_eval = false;
        }
        if (an.eval_mode) f.strict = f.strict or an.eval_ctx.strict;
        try an.hoistDeclarations(s, p.body, true);
        for (p.body) |st| try an.stmt(s, st);
        if (f.has_direct_eval) an.markDynamic(f);
    }

    /// Everything a function with eval or with can be asked for by
    /// name: mark every binding on the chain captured and every scope
    /// as needing an environment.
    fn markDynamic(an: *Analysis, f: *Func) void {
        _ = an;
        var cur: ?*Func = f;
        while (cur) |fc| : (cur = fc.parent) fc.dynamic = true;
        if (f.has_direct_eval) f.has_eval_refs = true;
    }

    fn hoistDeclarations(an: *Analysis, s: *Scope, body: []*Node, top: bool) Error!void {
        _ = top;
        for (body) |st| try an.hoistStatement(s, st, true);
    }

    /// Declarations `st` contributes to scope `s`: var-scoped ones go to
    /// the var scope; lexical ones to `s` when `direct` (a statement of
    /// the block itself).
    fn hoistStatement(an: *Analysis, s: *Scope, st: *Node, direct: bool) Error!void {
        switch (st.data) {
            .var_decl => |d| {
                for (d.decls) |dc| try an.declarePattern(s, dc.target, switch (d.kind) {
                    .@"var" => .@"var",
                    .let => .let,
                    .@"const" => .@"const",
                }, direct);
            },
            .function_decl => |f| {
                if (direct) {
                    const vs = varScope(s);
                    // `export default function () {}` binds "*default*".
                    const fname = f.name orelse "*default*";
                    if (vs == s) {
                        _ = try an.declare(s, fname, .function);
                    } else {
                        // A block-level function: lexical in the block; in
                        // sloppy code also var-bound in the function
                        // (Annex B.3.3) when no lexical name conflicts.
                        _ = try an.declare(s, fname, .let);
                        const b = s.bindings.get(fname).?;
                        b.lexical = false; // block functions are initialized at block entry
                        if (!s.func.strict and !f.is_async and !f.is_generator) {
                            if (an.annexBAllowed(s, fname)) {
                                const vb = try an.declare(vs, fname, .@"var");
                                vb.annexb = true;
                                b.annexb = true;
                            }
                        }
                    }
                    try s.hoisted.append(an.a, st);
                }
            },
            .class_decl => |c| if (direct) {
                _ = try an.declare(s, c.name orelse "*default*", .class);
            },
            .if_stmt => |i| {
                try an.hoistStatement(s, i.then, false);
                if (i.otherwise) |o| try an.hoistStatement(s, o, false);
            },
            .for_stmt => |f| {
                if (f.init) |i| try an.hoistStatement(s, i, false);
                try an.hoistStatement(s, f.body, false);
            },
            .for_in => |f| {
                try an.hoistStatement(s, f.left, false);
                try an.hoistStatement(s, f.body, false);
            },
            .for_of => |f| {
                try an.hoistStatement(s, f.left, false);
                try an.hoistStatement(s, f.body, false);
            },
            .while_stmt => |w| try an.hoistStatement(s, w.body, false),
            .do_while => |w| try an.hoistStatement(s, w.body, false),
            .block => |b| for (b) |x| try an.hoistStatement(s, x, false),
            .try_stmt => |t| {
                try an.hoistStatement(s, t.block, false);
                if (t.handler) |h| try an.hoistStatement(s, h, false);
                if (t.finalizer) |f| try an.hoistStatement(s, f, false);
            },
            .switch_stmt => |sw| for (sw.cases) |c| for (c.body) |x| try an.hoistStatement(s, x, false),
            .labeled => |l| try an.hoistStatement(s, l.body, direct),
            .with_stmt => |w| try an.hoistStatement(s, w.body, false),
            .export_decl => |e| switch (e) {
                .declaration => |d| try an.hoistStatement(s, d, direct),
                .default => |d| {
                    if (d.data == .function_decl or d.data == .class_decl) {
                        try an.hoistStatement(s, d, direct);
                    } else {
                        // `export default <expression>`: a const binding
                        // initialized when the statement runs.
                        _ = try an.declare(s, "*default*", .@"const");
                    }
                },
                else => {},
            },
            .import_decl => |im| {
                if (im.default) |d| _ = try an.declare(s, d, .import);
                if (im.namespace) |n| _ = try an.declare(s, n, .import);
                for (im.named) |nm| _ = try an.declare(s, nm.local, .import);
            },
            else => {},
        }
    }

    /// Annex B.3.3: the var binding is created unless a lexical binding
    /// of the name (other than the block function itself) sits between
    /// the block and the function scope, or is a parameter.
    fn annexBAllowed(an: *Analysis, s: *Scope, name: []const u8) bool {
        _ = an;
        var cur: ?*Scope = s.parent;
        while (cur) |c| : (cur = c.parent) {
            if (c.bindings.get(name)) |b| {
                if (b.kind == .param) return false;
                if (b.lexical and b.kind != .function) return false;
                if (c.kind == .catch_clause) {
                    // A simple catch parameter does not block (B.3.4).
                    if (b.kind == .catch_param) continue;
                }
                if (b.kind == .let and !b.lexical) return false; // another block function
            }
            switch (c.kind) {
                .function, .script, .eval, .module => return c.kind != .module,
                else => {},
            }
        }
        return true;
    }

    fn declarePattern(an: *Analysis, s: *Scope, pat: *Node, kind: BindingKind, direct: bool) Error!void {
        switch (pat.data) {
            .identifier => |name| {
                if (kind == .@"var") {
                    _ = try an.declare(varScope(s), name, .@"var");
                } else if (direct) _ = try an.declare(s, name, kind);
            },
            .object_pattern => |props| for (props) |p| try an.declarePattern(s, p.value, kind, direct),
            .array_pattern => |els| for (els) |e| if (e) |el| try an.declarePattern(s, el, kind, direct),
            .assign_pattern => |ap| try an.declarePattern(s, ap.target, kind, direct),
            .rest => |r| try an.declarePattern(s, r, kind, direct),
            else => {},
        }
    }

    fn stmts(an: *Analysis, s: *Scope, body: []*Node) Error!void {
        for (body) |st| try an.stmt(s, st);
    }

    fn block(an: *Analysis, parent: *Scope, node: *Node, body: []*Node) Error!void {
        const s = try an.newScope(.block, parent, parent.func, node);
        for (body) |st| try an.hoistStatement(s, st, true);
        for (body) |st| try an.stmt(s, st);
    }

    fn stmt(an: *Analysis, s: *Scope, st: *Node) Error!void {
        switch (st.data) {
            .var_decl => |d| for (d.decls) |dc| {
                try an.pattern(s, dc.target);
                if (dc.init) |i| try an.expr(s, i);
            },
            .function_decl => |f| try an.function(s, f),
            .class_decl => |c| try an.class(s, c),
            .block => |b| try an.block(s, st, b),
            .empty, .debugger => {},
            .expr_stmt => |e| try an.expr(s, e),
            .if_stmt => |i| {
                try an.expr(s, i.cond);
                try an.stmt(s, i.then);
                if (i.otherwise) |o| try an.stmt(s, o);
            },
            .for_stmt => |f| {
                const fs = try an.newScope(.for_head, s, s.func, st);
                if (f.init) |i| {
                    try an.hoistStatement(fs, i, true);
                    try an.stmt(fs, i);
                }
                if (f.cond) |c| try an.expr(fs, c);
                if (f.update) |u| try an.expr(fs, u);
                try an.stmt(fs, f.body);
            },
            .for_in => |f| {
                const fs = try an.newScope(.for_head, s, s.func, st);
                try an.hoistStatement(fs, f.left, true);
                try an.forLeft(fs, f.left);
                try an.expr(fs, f.right);
                try an.stmt(fs, f.body);
            },
            .for_of => |f| {
                const fs = try an.newScope(.for_head, s, s.func, st);
                try an.hoistStatement(fs, f.left, true);
                try an.forLeft(fs, f.left);
                try an.expr(fs, f.right);
                try an.stmt(fs, f.body);
            },
            .while_stmt => |w| {
                try an.expr(s, w.cond);
                try an.stmt(s, w.body);
            },
            .do_while => |w| {
                try an.stmt(s, w.body);
                try an.expr(s, w.cond);
            },
            .return_stmt => |r| if (r) |e| try an.expr(s, e),
            .break_stmt, .continue_stmt => {},
            .throw_stmt => |e| try an.expr(s, e),
            .try_stmt => |t| {
                try an.stmt(s, t.block);
                if (t.handler) |h| {
                    const cs = try an.newScope(.catch_clause, s, s.func, st);
                    if (t.param) |p| {
                        try an.declarePattern(cs, p, .catch_param, true);
                        try an.pattern(cs, p);
                    }
                    // The catch block's own scope is the handler block.
                    try an.stmt(cs, h);
                }
                if (t.finalizer) |f| try an.stmt(s, f);
            },
            .switch_stmt => |sw| {
                try an.expr(s, sw.discriminant);
                const ss = try an.newScope(.switch_block, s, s.func, st);
                for (sw.cases) |c| for (c.body) |x| try an.hoistStatement(ss, x, true);
                for (sw.cases) |c| {
                    if (c.cond) |cond| try an.expr(ss, cond);
                    for (c.body) |x| try an.stmt(ss, x);
                }
            },
            .labeled => |l| try an.stmt(s, l.body),
            .with_stmt => |w| {
                try an.expr(s, w.object);
                s.func.has_with = true;
                const ws = try an.newScope(.with, s, s.func, st);
                ws.dynamic = true;
                try an.stmt(ws, w.body);
                an.markDynamic(s.func);
            },
            .import_decl => {},
            .export_decl => |e| switch (e) {
                .declaration => |d| try an.stmt(s, d),
                .default => |d| {
                    if (d.data == .function_decl or d.data == .class_decl) try an.stmt(s, d) else try an.expr(s, d);
                },
                .named => |n| if (n.source == null) for (n.specifiers) |sp| try an.reference(s, sp.local),
                .all => {},
            },
            else => try an.expr(s, st),
        }
    }

    fn forLeft(an: *Analysis, s: *Scope, left: *Node) Error!void {
        if (left.data == .var_decl) {
            for (left.data.var_decl.decls) |dc| {
                try an.pattern(s, dc.target);
                if (dc.init) |i| try an.expr(s, i);
            }
        } else try an.pattern(s, left);
    }

    /// A binding or assignment pattern: references (targets) and defaults.
    fn pattern(an: *Analysis, s: *Scope, pat: *Node) Error!void {
        switch (pat.data) {
            .identifier => |name| try an.reference(s, name),
            .object_pattern => |props| for (props) |p| {
                if (p.computed) try an.expr(s, p.key);
                try an.pattern(s, p.value);
            },
            .array_pattern => |els| for (els) |e| if (e) |el| try an.pattern(s, el),
            .assign_pattern => |ap| {
                try an.pattern(s, ap.target);
                try an.expr(s, ap.default);
            },
            .rest => |r| try an.pattern(s, r),
            else => try an.expr(s, pat), // a member expression target
        }
    }

    /// Resolve a reference: the binding found on the chain is captured
    /// when it belongs to another function.
    pub fn reference(an: *Analysis, s: *Scope, name: []const u8) Error!void {
        _ = an;
        var cur: ?*Scope = s;
        while (cur) |c| : (cur = c.parent) {
            if (c.bindings.get(name)) |b| {
                if (c.func != s.func) b.captured = true;
                if (c.func != s.func or c.dynamic) c.needs_env = true;
                return;
            }
        }
    }

    fn implicit(an: *Analysis, s: *Scope, name: []const u8) Error!void {
        // `this`, `new.target`, `.home`, `.func`: bindings of the nearest
        // non-arrow function, captured when used from an arrow.
        const tf = s.func.this_func;
        if (tf.node == null and !an.eval_mode) return; // global this
        if (tf.node == null and an.eval_mode) return;
        const b = try an.declare(tf.scope, name, .implicit);
        if (tf != s.func) {
            b.captured = true;
            tf.scope.needs_env = true;
        }
    }

    fn function(an: *Analysis, s: *Scope, f: *ast.Function) Error!void {
        const fi = try an.newFunc(f, s.func);
        var outer = s;
        // A named function expression binds its name in its own scope
        // between the parameters and the enclosing scope; a declaration's
        // name lives in the enclosing scope.
        _ = &outer;
        const ps: ?*Scope = if (!f.simple_params) try an.newScope(.params, outer, fi, null) else null;
        const fs = try an.newScope(.function, ps orelse outer, fi, f);
        fi.scope = fs;
        fi.params_scope = ps;
        const decl_scope = ps orelse fs;
        // Parameters.
        for (f.params) |p| try an.declarePattern(decl_scope, p, .param, true);
        for (decl_scope.bindings.values()) |b| if (b.kind == .param) {
            b.lexical = false;
        };
        // Body declarations.
        switch (f.body) {
            .block => |body| try an.hoistDeclarations(fs, body, true),
            .expr => {},
        }
        // References: parameter defaults in the params scope, the body in
        // the function scope.
        for (f.params) |p| try an.pattern(decl_scope, p);
        switch (f.body) {
            .block => |body| try an.stmts(fs, body),
            .expr => |e| try an.expr(fs, e),
        }
        if (fi.has_direct_eval) an.markDynamic(fi);
        // A mapped arguments object aliases the parameters: they live in
        // environment slots so the object can reach them.
        if (fi.uses_arguments and !fi.strict and f.simple_params and !f.is_arrow) {
            for (decl_scope.bindings.values()) |b| if (b.kind == .param) {
                b.captured = true;
            };
            decl_scope.needs_env = true;
        }
        if (fi.dynamic) {
            fs.needs_env = true;
            if (ps) |p| p.needs_env = true;
            for (fs.bindings.values()) |b| b.captured = true;
            if (ps) |p| for (p.bindings.values()) |b| {
                b.captured = true;
            };
        }
    }

    /// A function expression: an optional own-name scope.
    fn functionExpr(an: *Analysis, s: *Scope, f: *ast.Function) Error!void {
        if (f.name != null and !f.is_arrow) {
            const ns = try an.newScope(.block, s, s.func, @ptrCast(f.name.?.ptr));
            _ = try an.declare(ns, f.name.?, .@"const");
            ns.bindings.get(f.name.?).?.lexical = false;
            // Keyed by the function node with a marker: the emitter asks
            // for `funcNameScope(f)`.
            try an.scopes.put(an.a, @ptrCast(&f.body), ns);
            try an.function(ns, f);
        } else try an.function(s, f);
    }

    fn class(an: *Analysis, s: *Scope, c: *ast.Class) Error!void {
        // The class scope: the inner name binding, private names, and
        // computed-key temporaries.
        const cs = try an.newScope(.class, s, s.func, c);
        if (c.name) |n| _ = try an.declare(cs, n, .@"const");
        for (c.members) |m| if (m.key.data == .private_name) {
            _ = try an.declare(cs, m.key.data.private_name, .implicit);
        };
        // The heritage is evaluated in the class scope (with the name in TDZ).
        if (c.super_class) |sc| try an.expr(cs, sc);
        var key_n: usize = 0;
        for (c.members) |m| {
            if (m.computed) {
                try an.expr(cs, m.key);
                // A computed key of a field is evaluated once and kept.
                if (m.kind == .field) {
                    var buf: [16]u8 = undefined;
                    const nm = std.fmt.bufPrint(&buf, ".key{d}", .{key_n}) catch unreachable;
                    const b = try an.declare(cs, try an.a.dupe(u8, nm), .implicit);
                    b.captured = true;
                    cs.needs_env = true;
                    key_n += 1;
                }
            }
            if (m.value) |v| {
                if (v.data == .function) try an.function(cs, v.data.function);
            }
        }
        // Private names and the class binding are used from member
        // functions: environment slots.
        for (cs.bindings.values()) |b| if (b.kind == .implicit and b.name.len > 0 and b.name[0] == '#') {
            b.captured = true;
            cs.needs_env = true;
        };
    }

    fn expr(an: *Analysis, s: *Scope, e: *Node) Error!void {
        switch (e.data) {
            .identifier => |name| {
                if (std.mem.eql(u8, name, "arguments")) {
                    // The nearest non-arrow function's arguments object,
                    // unless a binding shadows it.
                    var cur: ?*Scope = s;
                    var shadowed = false;
                    while (cur) |c| : (cur = c.parent) {
                        if (c.bindings.get(name)) |_| {
                            shadowed = true;
                            break;
                        }
                        if (c.func != s.func.this_func and c.func.this_func != s.func.this_func) break;
                        if (c.kind == .function and c.func == s.func.this_func) break;
                    }
                    const tf = s.func.this_func;
                    if (!shadowed and tf.node != null and tf.kind != .class_field_init and tf.kind != .static_block) {
                        tf.uses_arguments = true;
                        const b = try an.declare(tf.scope, "arguments", .implicit);
                        if (tf != s.func) {
                            b.captured = true;
                            tf.scope.needs_env = true;
                        }
                        return;
                    }
                }
                try an.reference(s, name);
            },
            .private_name => |name| try an.reference(s, name),
            .number, .bigint, .string, .null_lit, .bool_lit, .regexp, .new_target, .import_meta, .debugger => {
                if (e.data == .new_target) {
                    s.func.this_func.uses_new_target = true;
                    try an.implicit(s, "new.target");
                }
            },
            .this => {
                s.func.this_func.uses_this = true;
                try an.implicit(s, "this");
            },
            .super => {
                s.func.this_func.uses_super = true;
                try an.implicit(s, ".home");
            },
            .template => |t| for (t.exprs) |x| try an.expr(s, x),
            .tagged_template => |t| {
                try an.expr(s, t.tag);
                try an.expr(s, t.quasi);
            },
            .array => |els| for (els) |el| if (el) |x| try an.expr(s, x),
            .object => |props| for (props) |p| {
                if (p.computed) try an.expr(s, p.key);
                if (p.kind == .shorthand) {
                    try an.expr(s, p.value);
                } else if (p.value.data == .function) {
                    try an.function(s, p.value.data.function);
                } else try an.expr(s, p.value);
            },
            .function => |f| try an.functionExpr(s, f),
            .class => |c| try an.class(s, c),
            .unary => |u| try an.expr(s, u.arg),
            .update => |u| try an.expr(s, u.arg),
            .binary => |b| {
                try an.expr(s, b.left);
                try an.expr(s, b.right);
            },
            .logical => |b| {
                try an.expr(s, b.left);
                try an.expr(s, b.right);
            },
            .assign => |as| {
                try an.pattern(s, as.target);
                try an.expr(s, as.value);
            },
            .conditional => |c| {
                try an.expr(s, c.cond);
                try an.expr(s, c.then);
                try an.expr(s, c.otherwise);
            },
            .call => |c| {
                if (c.callee.data == .identifier and std.mem.eql(u8, c.callee.data.identifier, "eval")) {
                    // A direct eval: the function keeps everything by name,
                    // and needs this/arguments/new.target reachable.
                    s.func.has_direct_eval = true;
                    s.func.this_func.uses_this = true;
                    try an.implicit(s, "this");
                    try an.implicit(s, "new.target");
                    try an.implicit(s, ".home");
                    const tf = s.func.this_func;
                    if (tf.node != null and tf.kind != .class_field_init and tf.kind != .static_block) {
                        tf.uses_arguments = true;
                        _ = try an.declare(tf.scope, "arguments", .implicit);
                    }
                    s.func.has_eval_refs = true;
                    an.markDynamic(s.func);
                    var sc: ?*Scope = s;
                    while (sc) |scp| : (sc = scp.parent) scp.needs_env = true;
                }
                if (c.callee.data == .super) {
                    s.func.this_func.uses_super_call = true;
                    try an.implicit(s, "this");
                    try an.implicit(s, "new.target");
                    try an.implicit(s, ".func");
                } else try an.expr(s, c.callee);
                for (c.args) |x| try an.expr(s, x);
            },
            .new => |n| {
                try an.expr(s, n.callee);
                for (n.args) |x| try an.expr(s, x);
            },
            .member => |m| {
                if (m.object.data == .super) {
                    s.func.this_func.uses_super = true;
                    try an.implicit(s, ".home");
                    try an.implicit(s, "this");
                } else try an.expr(s, m.object);
                if (m.computed) try an.expr(s, m.property);
                if (m.property.data == .private_name) try an.reference(s, m.property.data.private_name);
            },
            .optional_chain => |x| try an.expr(s, x),
            .sequence => |xs| for (xs) |x| try an.expr(s, x),
            .spread => |x| try an.expr(s, x),
            .yield => |y| if (y.arg) |x| try an.expr(s, x),
            .await => |x| try an.expr(s, x),
            .import_call => |ic| {
                try an.expr(s, ic.source);
                if (ic.options) |o| try an.expr(s, o);
            },
            .object_pattern, .array_pattern, .assign_pattern, .rest => try an.pattern(s, e),
            else => {},
        }
    }
};

test "scope: a captured binding is marked, an uncaptured one is not" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try parser.parse(a, "function f(a, b) { var c = 1; return function () { return a + c; }; }", .{});
    var an = Analysis.init(std.testing.allocator);
    defer an.deinit();
    try an.analyzeProgram(prog);
    const fnode = prog.data.program.body[0].data.function_decl;
    const fs = an.scopeOf(fnode);
    try std.testing.expect(fs.lookup("a").?.captured);
    try std.testing.expect(!fs.lookup("b").?.captured);
    try std.testing.expect(fs.lookup("c").?.captured);
    try std.testing.expect(fs.needs_env);
    try std.testing.expect(!an.funcOf(fnode).dynamic);
}

test "scope: eval makes the function dynamic; arrows capture this" {
    const parser = @import("parser.zig");
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const prog = try parser.parse(a, "function g(x) { eval('x'); } function h() { return () => this; }", .{});
    var an = Analysis.init(std.testing.allocator);
    defer an.deinit();
    try an.analyzeProgram(prog);
    const g = prog.data.program.body[0].data.function_decl;
    try std.testing.expect(an.funcOf(g).dynamic);
    try std.testing.expect(an.scopeOf(g).lookup("x").?.captured);
    const h = prog.data.program.body[1].data.function_decl;
    try std.testing.expect(an.scopeOf(h).lookup("this").?.captured);
}
