//! The register machine's instruction set and the `Code` cell the
//! compiler produces and the VM runs. An instruction is one 64-bit
//! word — a 16-bit opcode and three 16-bit operands (`b`/`c` combine
//! into a 32-bit immediate for constants and jump targets) — so decode
//! is one load. Operands name registers in the frame: the callee's
//! parameters first, then locals, then the temporaries expressions use.
//!
//! Variables the compiler proves are never captured live in registers;
//! captured ones live in `Env` cells (one per scope instance, chained
//! to the enclosing scope), addressed by (hops, slot) resolved at
//! compile time. Only code under `with` or a direct `eval` looks
//! anything up by name at run time.
const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");
const string = @import("string.zig");
const Cell = heap.Cell;
const Value = value.Value;
const String = string.String;

pub const Op = enum(u16) {
    nop,
    // ------------------------------------------------- moves and loads
    mov, // a = b
    ldc, // a = consts[bc]
    ldint, // a = int32(bc)
    ldundef, // a = undefined
    ldnull,
    ldtrue,
    ldfalse,
    ldempty, // a = the hole (TDZ)
    ldthis, // a = this (throws in a derived constructor before super())
    ldgthis, // a = the global object (an arrow's `this` at a script's top level)
    ldnewtarget,
    ldfunc, // a = the running function object
    ldhome, // a = the running function's home object (super)
    // ------------------------------------------------------ operators
    add, // a = b op c
    sub,
    mul,
    div,
    mod,
    exp,
    shl,
    shr,
    ushr,
    band,
    bor,
    bxor,
    lt,
    gt,
    le,
    ge,
    eq,
    ne,
    seq,
    sne,
    in,
    instanceof,
    neg, // a = op b
    pos, // a = ToNumber(b)
    tonumeric, // a = ToNumeric(b) (postfix update's old value)
    bnot,
    not,
    typeof,
    inc, // a = b + 1 (numeric b)
    dec,
    tostring, // a = ToString(b) (template literals)
    topropkey, // a = ToPropertyKey(b)
    toobject,
    // ---------------------------------------------------------- jumps
    jmp, // pc = bc
    jt, // if ToBoolean(a) pc = bc
    jf,
    jundef, // if a === undefined
    jnundef,
    jnullish, // if a == null
    jnnullish,
    isnullish, // a = (b == null)
    isnnullish, // a = (b != null)
    jempty, // if a is the hole
    jnempty,
    // ---------------------------------------------------- properties
    getprop, // a = b[props[c].key] (inline-cached)
    setprop, // a[props[b].key] = c
    getelem, // a = b[c]
    setelem, // a[b] = c
    delprop, // a = delete b[c]
    getsuper, // a = (b: home, b+1: this, b+2: key) super property
    setsuper, // (a: home, a+1: this, a+2: key) = c
    defown, // define own data property a[props[b].key] = c (literals)
    defelem, // define own a[b] = c
    defgetter, // a[b] = get c
    defsetter,
    defmethod, // a[b] = c (enumerable), c.home = a
    defmethodc, // class member: not enumerable
    defgetterc,
    defsetterc,
    sethome, // a.home = b
    bigint, // a = BigInt literal consts[bc]
    defproto, // a.__proto__ = b (literal)
    spreadobj, // CopyDataProperties(a, b), excluding the keys in array c (0xffff: none)
    getpriv, // a = b.#c (c a register holding the private key)
    setpriv, // a.#b = c
    haspriv, // a = #b in c
    defpriv, // define private field a.#b = c
    defprivmethod, // define private method a.#b = c (not writable)
    // ------------------------------------------------------- objects
    newobj, // a = {}
    newarr, // a = [] (capacity hint bc)
    arrpush, // a.push(b) (literal building; holes with ldempty)
    arrspread, // a.push(...b)
    regexp, // a = new RegExp(consts[b], consts[c])
    template, // a = the template object of templates[bc] (cached)
    closure, // a = a closure of functions[bc] over the current env
    class, // a = class with prototype parent b (or empty), constructor functions[c]
    setfields, // a.fields = b (the field initializer function)
    // --------------------------------------------------------- calls
    call, // a = b(b+1: this, b+2..: args) argc c
    callspread, // a = b(this b+1, args from array b+2)
    new, // a = new b(b+1..: args) argc c
    newspread, // a = new b(...array b+1)
    supercall, // a = super(b+2..: args) argc c; b: the constructor, b+1: new.target
    supercallspread,
    ret, // return a
    retundef,
    // --------------------------------------------------- environments
    pushenv, // env = new Env(scopes[bc]) child of env
    popenv,
    getenv, // a = env^b[c]
    setenv, // env^b[c] = a
    getenvchk, // like getenv, ReferenceError if the hole (TDZ)
    setenvchk, // like setenv, ReferenceError if the hole
    getglobal, // a = globals[bc] (ReferenceError if missing)
    setglobal, // globals[bc] = a
    setglobalstrict, // ReferenceError if missing (strict assignment)
    typeofglobal, // a = typeof globals[bc] (undefined if missing)
    getname, // a = lookup consts[bc] through with/eval scopes
    setname, // consts[bc] = a
    initname, // initialize the binding consts[bc] = a (no TDZ or const check)
    delname, // a = delete consts[bc]
    getnamethis, // a = the value of consts[bc], a+1 = its with-object base (or undefined)
    typeofname, // a = typeof consts[bc] (undefined when unresolvable)
    declvar, // declare var consts[bc] in the nearest variable environment (eval code)
    declfunc, // declare function consts[b] = c in the nearest variable environment (eval code)
    decllex, // declare a global lexical binding consts[bc] (script code; c: const when a != 0)
    initglobal, // initialize global binding globals[bc] = a (a declaration, no TDZ check)
    setthis, // this = a (a derived constructor after super())
    privname, // a = a fresh private name described by consts[bc]
    chktdz, // ReferenceError "consts[bc]" if a is the hole
    chkconst, // TypeError "consts[bc]" (assignment to a const)
    pushwith, // env = with-object env over a
    copyenv, // env = a copy of the current env (per-iteration bindings)
    initargs, // a = the arguments object
    initrest, // a = the rest array from parameter index bc
    // ----------------------------------------------------- exceptions
    throw, // throw a
    throwref, // throw ReferenceError(consts[bc])
    throwtype, // throw TypeError(consts[bc])
    pushtry, // handler at pc bc; the exception lands in a
    poptry,
    // ------------------------------------------------------ iteration
    iter, // a = GetIterator(b) (a: the iterator, a+1: its next)
    iterasync,
    iternext, // a = next value of iterator b, or the hole when done
    iterclose, // IteratorClose(a) (normal completion)
    iterclosethrow, // IteratorClose(a) in a throw completion (errors from close are swallowed)
    forin, // a = for-in enumerator of b
    forinnext, // a = next key of enumerator b, or the hole
    // ------------------------------------------------- generators
    yield, // suspend yielding b; on resumption a = the value sent, c = the kind (0 next, 1 throw, 2 return)
    yieldraw, // like yield, but b is yielded as the result object itself (yield*)
    await, // suspend on b; a = the settled value, c = the kind (0 fulfilled, 1 rejected)
    genstart, // the generator prologue: suspend after arguments are bound
    modinit, // a module's environment exists: suspend until evaluation
    getimport, // a = the import binding env^b[c] (an ImportCell), live
    ystep, // yield* step: b: iterator, b+1: next, b+2: kind, b+3: received → a = inner result (hole: return received), a+1 unused
    iterstep, // a = Call(next b+1, iterator b) — the raw result
    iterresult, // a = value of result object b, or the hole when done (TypeError if not an object)
    iterdone, // a = ToBoolean(b.done)
    itervalue, // a = b.value
    iterreturn, // a = Call(return, iterator b) or undefined without one; marks b+1 closed
    chkobj, // TypeError unless a is an object
    // ------------------------------------------------------- misc
    eval, // a = direct eval of b (argc c at b+..)
    importmeta,
    importcall,
    debugger,

    pub fn name(op: Op) []const u8 {
        return @tagName(op);
    }
};

pub const Insn = packed struct(u64) {
    op: Op,
    a: u16 = 0,
    b: u16 = 0,
    c: u16 = 0,

    pub fn bc(i: Insn) u32 {
        return @as(u32, i.b) | (@as(u32, i.c) << 16);
    }
    pub fn withBc(op: Op, a: u16, v: u32) Insn {
        return .{ .op = op, .a = a, .b = @truncate(v), .c = @truncate(v >> 16) };
    }
};

/// A property site's inline cache: the shape seen and the slot.
pub const InlineCache = struct {
    shape: ?*anyopaque = null,
    slot: u32 = 0,
    /// The property was found on the prototype at `holder` (the shape
    /// is the receiver's; the holder's shape must match too).
    holder: ?*anyopaque = null,
    holder_shape: ?*anyopaque = null,
    /// A store site that added the property: the receiver's shape
    /// afterwards, valid while no prototype anywhere has changed since
    /// (`Objects.proto_epoch`).
    add_shape: ?*anyopaque = null,
    epoch: u64 = 0,
    /// A second read entry, for a site that sees two shapes.
    shape2: ?*anyopaque = null,
    slot2: u32 = 0,
    holder2: ?*anyopaque = null,
    holder_shape2: ?*anyopaque = null,
};

pub const PropSite = struct { key: *String, ic: InlineCache = .{} };
pub const GlobalSite = struct { name: *String, ic: InlineCache = .{} };

/// A scope's layout: what each Env slot holds. `names` is what `eval`
/// and `with` resolve against; `consts` marks immutable bindings.
pub const ScopeInfo = struct {
    names: []*String,
    consts: []bool,
    /// A function scope (`var` declarations in an eval land here).
    is_function: bool = false,
    /// A `with` object environment (the slot holds the object).
    is_with: bool = false,
    /// Lexical (TDZ) slots start as the hole; others as undefined.
    lexical: []bool,
    /// A function scope with a direct eval: `var`s may be added later
    /// (`Env.extra`), so nothing under it resolves to a fixed slot.
    dynamic: bool = false,
};

/// A template literal site: the strings, and the object made on first use.
pub const TemplateSite = struct {
    cooked: []?*String,
    raw: []*String,
    cached: Value = Value.undefined_,
};

/// A scope instance at run time.
pub const Env = extern struct {
    header: Cell,
    parent: ?*Env,
    info: *const ScopeInfo,
    /// Bindings a direct eval added by name (a dictionary object), or
    /// the object of a `with` scope.
    extra: ?*Cell,
    /// The code whose tables `info` lives in: kept alive with the
    /// environment (a closure made in eval code outlives the eval).
    owner: ?*Code,
    count: u32,
    _pad: u32 = 0,

    pub fn cell(e: *Env) *Cell {
        return &e.header;
    }
    pub fn slotsPtr(e: *Env) [*]Value {
        const base: [*]u8 = @ptrCast(e);
        return @ptrCast(@alignCast(base + @sizeOf(Env)));
    }
    pub fn slots(e: *Env) []Value {
        return e.slotsPtr()[0..e.count];
    }
    pub fn up(e: *Env, hops: u32) *Env {
        var cur = e;
        var n = hops;
        while (n > 0) : (n -= 1) cur = cur.parent.?;
        return cur;
    }
    pub fn trace(e: *Env, m: *heap.Marker) void {
        if (e.parent) |p| m.markCell(p.cell());
        m.markCell(e.extra);
        if (e.owner) |o| m.markCell(o.cell());
        for (e.slots()) |v| m.markValue(v);
    }
};

pub const FunctionKind = enum(u8) { normal, arrow, method, getter, setter, class_constructor, derived_constructor, field_init, static_block, generator, async_function, async_generator, async_arrow };

/// The source text a script's codes share, freed with the last of them.
pub const Source = struct {
    text: []u8,
    refs: usize,
    name: []u8,
};

pub const Position = struct { pc: u32, pos: u32 };

/// A compiled function's body and tables (in the embedder's memory,
/// owned by the `Code` cell).
pub const CodeData = struct {
    insns: []Insn = &.{},
    consts: []Value = &.{},
    functions: []*Code = &.{},
    props: []PropSite = &.{},
    globals: []GlobalSite = &.{},
    scopes: []*ScopeInfo = &.{},
    templates: []TemplateSite = &.{},
    positions: []Position = &.{},
    nregs: u32 = 0,
    nparams: u32 = 0,
    /// The number of formal parameters for `length` (before a default
    /// or the rest).
    length: u32 = 0,
    kind: FunctionKind = .normal,
    strict: bool = false,
    /// Parameters get their own environment (non-simple parameters with
    /// closures in defaults).
    uses_this: bool = false,
    uses_arguments: bool = false,
    has_direct_eval: bool = false,
    is_constructor: bool = false,
    /// The name, for `name` and stack traces (null for anonymous).
    name: ?*String = null,
    source: ?*Source = null,
    start: u32 = 0,
    end: u32 = 0,
    /// The function-scope info, when the function's scope is an Env.
    function_scope: ?*ScopeInfo = null,
    /// The module record this code was compiled for (import.meta,
    /// import() resolution), or null for a script.
    module: ?*anyopaque = null,
    /// A mapped arguments object's aliasing: the environment slot of
    /// each parameter index (`unmapped` for a duplicate name's earlier
    /// index); empty when the arguments object is unmapped.
    param_slots: []u32 = &.{},

    pub const unmapped: u32 = 0xFFFF_FFFF;

    pub fn deinit(d: *CodeData, a: std.mem.Allocator) void {
        a.free(d.insns);
        a.free(d.consts);
        a.free(d.functions);
        a.free(d.props);
        a.free(d.globals);
        for (d.scopes) |s| {
            a.free(s.names);
            a.free(s.consts);
            a.free(s.lexical);
            a.destroy(s);
        }
        a.free(d.scopes);
        for (d.templates) |t| {
            a.free(t.cooked);
            a.free(t.raw);
        }
        a.free(d.templates);
        a.free(d.positions);
        a.free(d.param_slots);
        if (d.source) |src| {
            src.refs -= 1;
            if (src.refs == 0) {
                a.free(src.text);
                a.free(src.name);
                a.destroy(src);
            }
        }
    }

    /// The source position of `pc`, for error messages.
    pub fn posOf(d: *const CodeData, pc: u32) u32 {
        var best: u32 = 0;
        for (d.positions) |p| {
            if (p.pc > pc) break;
            best = p.pos;
        }
        return best;
    }
};

pub const Code = extern struct {
    header: Cell,
    data: *CodeData,

    pub fn cell(c: *Code) *Cell {
        return &c.header;
    }
    pub fn trace(c: *Code, m: *heap.Marker) void {
        const d = c.data;
        for (d.consts) |v| m.markValue(v);
        for (d.functions) |f| m.markCell(f.cell());
        for (d.props) |p| m.markCell(p.key.cell());
        for (d.globals) |g| m.markCell(g.name.cell());
        for (d.scopes) |s| for (s.names) |n| m.markCell(n.cell());
        for (d.templates) |t| {
            for (t.cooked) |cs| if (cs) |x| m.markCell(x.cell());
            for (t.raw) |r| m.markCell(r.cell());
            m.markValue(t.cached);
        }
        if (d.name) |n| m.markCell(n.cell());
    }
};

/// Print a code's instructions (debugging; `JS_DUMP=1` in the runner).
pub fn dump(w: anytype, c: *const Code, strings: *string.Strings, a: std.mem.Allocator) !void {
    const d = c.data;
    try w.print("code nregs={d} nparams={d} kind={s} strict={}\n", .{ d.nregs, d.nparams, @tagName(d.kind), d.strict });
    for (d.insns, 0..) |i, pc| {
        try w.print("  {d:4} {s} {d} {d} {d}", .{ pc, i.op.name(), i.a, i.b, i.c });
        switch (i.op) {
            .ldc => {
                const v = d.consts[i.bc()];
                if (v.isString()) {
                    const s = try strings.toUtf8(a, v.asCell().as(String));
                    defer a.free(s);
                    try w.print("  ; \"{s}\"", .{s});
                } else if (v.isNumber()) try w.print("  ; {d}", .{v.asNumber()});
            },
            .getprop, .defown => {
                const s = try strings.toUtf8(a, d.props[i.c].key);
                defer a.free(s);
                try w.print("  ; .{s}", .{s});
            },
            .setprop => {
                const s = try strings.toUtf8(a, d.props[i.b].key);
                defer a.free(s);
                try w.print("  ; .{s}", .{s});
            },
            .getglobal, .setglobal, .setglobalstrict, .typeofglobal => {
                const s = try strings.toUtf8(a, d.globals[i.bc()].name);
                defer a.free(s);
                try w.print("  ; {s}", .{s});
            },
            else => {},
        }
        try w.writeAll("\n");
    }
    for (d.functions, 0..) |f, n| {
        try w.print("function {d}:\n", .{n});
        try dump(w, f, strings, a);
    }
}

test "bytecode: an instruction is one word and the immediate round-trips" {
    try std.testing.expectEqual(@as(usize, 8), @sizeOf(Insn));
    const i = Insn.withBc(.jmp, 0, 0x12345678);
    try std.testing.expectEqual(@as(u32, 0x12345678), i.bc());
}
