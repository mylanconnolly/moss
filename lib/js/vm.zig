//! The virtual machine: one realm's state — heap, strings, objects,
//! intrinsics, the register stack and its frames — with the abstract
//! operations of ECMA-262 §7 under their specification names
//! (`toPrimitive`, `toNumber`, `toPropertyKey`, `get`, `set`, `call`,
//! `construct`, ...) that the interpreter (`interp.zig`) and the
//! built-ins (`builtins/`) share. A thrown exception is Zig's
//! `error.Exception` with the value in `exception`; out of memory is
//! `error.OutOfMemory`, which the embedder sees as the page's end.
//!
//! Garbage collection runs only at the interpreter's safe points
//! (between instructions, where every live value is in a register,
//! a frame, or an intrinsic), so built-ins hold values in Zig locals
//! freely. The rule that keeps that true: nothing outside the
//! interpreter calls `Heap.collect`.
const std = @import("std");
const heap = @import("heap.zig");
const value = @import("value.zig");
const string = @import("string.zig");
const object = @import("object.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const interp = @import("interp.zig");
const realm = @import("realm.zig");
const module = @import("module.zig");
pub const Cell = heap.Cell;
pub const Heap = heap.Heap;
pub const Value = value.Value;
pub const String = string.String;
pub const Strings = string.Strings;
pub const Object = object.Object;
pub const Objects = object.Objects;
pub const Key = object.Key;
pub const Shape = object.Shape;
pub const Symbol = object.Symbol;
pub const Accessor = object.Accessor;
pub const Attributes = object.Attributes;
pub const Class = object.Class;
pub const Code = bytecode.Code;
pub const Env = bytecode.Env;

pub const Error = error{ OutOfMemory, Exception };

/// A native function: `this`, the arguments, and `new.target`
/// (undefined for a call).
pub const NativeFn = *const fn (vm: *Vm, this: Value, args: []const Value, new_target: Value) Error!Value;

/// The internal slots of a function object (`Class.function`).
pub const FunctionData = extern struct {
    code: ?*Code,
    env: ?*Env,
    native: ?NativeFn,
    home_object: Value,
    /// The class field initializer (a function) or undefined.
    fields: Value,
    /// A native's closure value.
    data: Value,
    this_mode: enum(u8) { lexical, strict, sloppy },
    is_class_constructor: bool,
    is_constructor: bool,
    /// The class constructor's [[ConstructorKind]] derived.
    derived: bool,
    _pad: [4]u8 = @splat(0),
};

pub const BoundData = extern struct {
    target: *Object,
    bound_this: Value,
    /// The bound arguments live in an array object.
    args: *Object,
};

/// A primitive wrapper's value (Boolean, Number, String, Symbol, BigInt).
pub const PrimitiveData = extern struct { value: Value };

pub const IteratorKind = enum(u8) { keys, values, entries };

/// Every iterator payload starts with two traced values: the target
/// (undefined once done) and a second reference the kind may use.
pub const IteratorHead = extern struct { target: Value, extra: Value };

pub const ArrayIteratorData = extern struct {
    target: Value, // undefined once done
    extra: Value = Value.undefined_,
    index: u32,
    kind: IteratorKind,
    _pad: [3]u8 = @splat(0),
};

pub const StringIteratorData = extern struct { target: Value, extra: Value = Value.undefined_, index: u32, _pad: u32 = 0 };

pub const ForInData = extern struct {
    target: Value,
    /// Keys collected up front (an array), and the cursor.
    keys: Value,
    index: u32,
    _pad: u32 = 0,
};

pub const ErrorData = extern struct {
    /// The position and code of the throw site, for stack traces.
    pos: u32,
    _pad: u32 = 0,
    code: ?*Code,
};

pub const ArgumentsData = extern struct {
    /// The environment the parameters live in (mapped arguments objects
    /// of sloppy simple-parameter functions), or null.
    env: ?*Env,
    /// The code whose `param_slots` give each index's slot.
    code: ?*Code,
    /// Which indices still alias their parameter (the first 64).
    mapped: u64,
};

/// A generator's or async function's suspended frame (`Class.generator`):
/// the register window copied to the heap on yield or await, copied
/// back on resumption.
pub const CoroutineData = extern struct {
    /// 0 suspended at start, 1 at a yield, 2 at an await, 3 executing,
    /// 4 completed, 5 completed and awaiting a `return` value (async gen).
    state: u8,
    /// 0 generator, 1 async function, 2 async generator.
    kind: u8,
    /// The yielded value is a result object to hand over as is (yield*).
    yield_raw: bool,
    _pad: [5]u8 = @splat(0),
    code: *Code,
    func: ?*Object,
    this: Value,
    new_target: Value,
    env: ?*Env,
    pc: u32,
    resume_reg: u16,
    kind_reg: u16,
    nregs: u32,
    nhandlers: u32,
    /// The saved registers (a bytes cell of `nregs` values).
    regs: ?*Cell,
    /// The saved handler stack (a bytes cell of `nhandlers` Handlers).
    handlers: ?*Cell,
    /// What the last yield or await produced.
    yielded: Value,
    /// An async function's result promise and its resolving functions.
    promise: Value,
    resolve: Value,
    reject: Value,
    /// An async generator's request queue (an array of records).
    queue: Value,

    pub const suspended_start: u8 = 0;
    pub const suspended_yield: u8 = 1;
    pub const suspended_await: u8 = 2;
    pub const executing: u8 = 3;
    pub const completed: u8 = 4;
    pub const awaiting_return: u8 = 5;

    pub fn savedRegs(d: *CoroutineData) []Value {
        const c = d.regs orelse return &.{};
        const base: [*]u8 = @ptrCast(c);
        const p: [*]Value = @ptrCast(@alignCast(base + 16));
        return p[0..d.nregs];
    }
    pub fn savedHandlers(d: *CoroutineData) []Handler {
        const c = d.handlers orelse return &.{};
        const base: [*]u8 = @ptrCast(c);
        const p: [*]Handler = @ptrCast(@alignCast(base + 16));
        return p[0..d.nhandlers];
    }
};

/// A promise's state (`Class.promise`).
pub const PromiseData = extern struct {
    /// 0 pending, 1 fulfilled, 2 rejected.
    state: u8,
    is_handled: bool,
    _pad: [6]u8 = @splat(0),
    result: Value,
    /// Arrays of reaction records while pending.
    fulfill_reactions: Value,
    reject_reactions: Value,
};

pub const Frame = struct {
    code: *Code,
    func: ?*Object,
    /// The coroutine this frame belongs to, if any.
    co: ?*Object = null,
    pc: u32,
    /// The register window: `vm.stack[base..base+nregs]`.
    base: u32,
    this: Value,
    new_target: Value,
    env: ?*Env,
    /// The actual arguments, in the caller's window.
    args_base: u32,
    argc: u32,
    handlers_base: u32,
    /// Where the caller wants the result (a register in its window).
    ret_dst: u16,
    is_construct: bool,
    /// The frame is the entry of a `run` (a native called into JS).
    entry: bool,
    /// The stack height to restore when the frame pops.
    saved_sp: u32,
};

pub const Handler = struct { pc: u32, reg: u16, env: ?*Env, frame: u32 };

pub const ErrorKind = enum { Error, TypeError, RangeError, ReferenceError, SyntaxError, EvalError, URIError, AggregateError };

pub const Vm = struct {
    meta: std.mem.Allocator,
    heap: Heap,
    strings: Strings,
    objects: Objects,
    stack: []Value,
    /// The register stack's used height (the top frame's window end).
    frames: std.ArrayList(Frame) = .empty,
    handlers: std.ArrayList(Handler) = .empty,
    exception: Value = Value.undefined_,
    intrinsics: realm.Intrinsics = undefined,
    global: *Object = undefined,
    /// The global lexical declarative record (script let/const/class).
    global_lex: std.AutoHashMapUnmanaged(*String, GlobalLex) = .empty,
    symbols: realm.WellKnownSymbols = undefined,
    symbol_registry: std.HashMapUnmanaged(*String, *Symbol, string.Strings.AtomContext, 80) = .empty,
    atoms: realm.Atoms = undefined,
    /// Pending promise jobs (stage c) — a queue of (function, args) pairs.
    jobs: std.ArrayList(Job) = .empty,
    /// Native call depth, against runaway recursion.
    depth: u32 = 0,
    /// Set while the interpreter runs the top frame; `collect` only then.
    in_interp: bool = false,
    /// An embedder hook run before each collection (extra roots).
    embedder_roots: ?heap.Root = null,
    /// A hook for `print` (test262 / the runner).
    print_fn: ?*const fn (vm: *Vm, s: []const u8) void = null,
    /// Direct-eval compile errors and their positions.
    last_syntax_error: []const u8 = "",
    /// Test262's `$262` host object needs `createRealm`, `evalScript`:
    /// provided by the runner through this hook.
    host_data: ?*anyopaque = null,
    /// Bumped when a global lexical binding is added: global-site caches
    /// carry the epoch they were filled at.
    global_lex_epoch: usize = 1,
    /// Arrays being joined (Array.prototype.join cycle detection).
    join_stack: std.ArrayList(*Object) = .empty,
    /// Backward jumps taken, against `step_limit` (the embedder's budget
    /// for a runaway script; RangeError when exceeded).
    steps: u64 = 0,
    step_limit: u64 = std.math.maxInt(u64),
    /// Values staged above the top frame's window (arguments awaiting
    /// their frame) that a nested call must not overwrite.
    sp_extra: u32 = 0,
    /// The native function object being called (so a native reads the
    /// data it closed over).
    current_native: ?*Object = null,
    /// Module records by canonical name, and the host's loader.
    modules: std.StringArrayHashMapUnmanaged(*module.Module) = .empty,
    host_load: ?module.HostLoad = null,
    host_import_meta: ?*const fn (vm: *Vm, name: []const u8, meta: *Object) Error!void = null,
    /// The host's clock for `Date.now` (milliseconds since the epoch);
    /// without one every date is the epoch.
    host_now: ?*const fn () f64 = null,
    /// Array.prototype and Object.prototype have no indexed properties
    /// (the usual case): array element stores need no prototype walk.
    proto_has_indexes: bool = false,

    pub const GlobalLex = struct { v: Value, is_const: bool };
    pub const Job = struct { func: Value, args: [3]Value, argc: u8 };

    pub const stack_values = 1 << 18;
    /// The frame list never reallocates (the interpreter keeps pointers
    /// into it across nested calls): its capacity is the call depth.
    pub const max_frames = 20000;

    /// Create a VM over `region` (the heap the cells live in), with
    /// `meta` for bookkeeping memory, and its intrinsics.
    pub fn init(vm: *Vm, region: []u8, meta: std.mem.Allocator) !void {
        vm.* = .{
            .meta = meta,
            .heap = Heap.init(region, meta, traceCell),
            .strings = undefined,
            .objects = undefined,
            .stack = try meta.alloc(Value, stack_values),
        };
        vm.heap.finalizer = finalizeCell;
        try vm.frames.ensureTotalCapacityPrecise(meta, max_frames);
        vm.strings = Strings.init(&vm.heap, meta);
        vm.objects = Objects.init(&vm.heap, &vm.strings, meta);
        try vm.heap.addRoot(.{ .ctx = vm, .trace = traceRoots });
        try realm.create(vm);
    }

    pub fn deinit(vm: *Vm) void {
        vm.heap.deinit();
        vm.objects.deinit();
        vm.strings.deinit();
        vm.global_lex.deinit(vm.meta);
        vm.symbol_registry.deinit(vm.meta);
        vm.frames.deinit(vm.meta);
        vm.handlers.deinit(vm.meta);
        vm.jobs.deinit(vm.meta);
        vm.join_stack.deinit(vm.meta);
        for (vm.modules.values()) |m| {
            m.deinit(vm.meta);
            vm.meta.destroy(m);
        }
        vm.modules.deinit(vm.meta);
        vm.meta.free(vm.stack);
    }

    /// The first free stack slot: above the top frame's window.
    pub fn sp(vm: *Vm) u32 {
        if (vm.frames.items.len == 0) return vm.sp_extra;
        const f = vm.frames.items[vm.frames.items.len - 1];
        return f.base + f.code.data.nregs + vm.sp_extra;
    }

    /// Whether an array hole store can skip the prototype chain.
    pub fn arrayProtoClean(vm: *Vm) bool {
        return !vm.proto_has_indexes;
    }

    // ------------------------------------------------------- tracing

    fn traceCell(h: *Heap, c: *Cell, m: *heap.Marker) void {
        const vm: *Vm = @fieldParentPtr("heap", h);
        switch (c.kind) {
            .string => Strings.trace(c.as(String), m),
            .object => vm.traceObject(c.as(Object), m),
            .shape => Objects.traceShape(c.as(Shape), m),
            .symbol => Objects.traceSymbol(c.as(Symbol), m),
            .env => Env.trace(c.as(Env), m),
            .code => Code.trace(c.as(Code), m),
            .accessor => Objects.traceAccessor(c.as(Accessor), m),
            .binding => module.ImportCell.trace(c.as(module.ImportCell), m),
            .bigint => {},
            .bytes, .free => {
                // Slot and element vectors: traced by their owners.
            },
        }
    }

    fn traceObject(vm: *Vm, o: *Object, m: *heap.Marker) void {
        _ = vm;
        Objects.trace(o, m);
        switch (o.class) {
            .function => {
                const f = o.internal(FunctionData);
                if (f.code) |c| m.markCell(c.cell());
                if (f.env) |e| m.markCell(e.cell());
                m.markValue(f.home_object);
                m.markValue(f.fields);
                m.markValue(f.data);
            },
            .bound_function => {
                const b = o.internal(BoundData);
                m.markCell(b.target.cell());
                m.markValue(b.bound_this);
                m.markCell(b.args.cell());
            },
            .boolean, .number, .string, .symbol, .bigint => m.markValue(o.internal(PrimitiveData).value),
            .iterator => {
                const h = o.internal(IteratorHead);
                m.markValue(h.target);
                m.markValue(h.extra);
            },
            .arguments => {
                const a = o.internal(ArgumentsData);
                if (a.env) |e| m.markCell(e.cell());
                if (a.code) |c| m.markCell(c.cell());
            },
            .error_ => {
                const e = o.internal(ErrorData);
                if (e.code) |c| m.markCell(c.cell());
            },
            .generator => {
                const d = o.internal(CoroutineData);
                m.markCell(d.code.cell());
                if (d.func) |f| m.markCell(f.cell());
                m.markValue(d.this);
                m.markValue(d.new_target);
                if (d.env) |e| m.markCell(e.cell());
                if (d.regs) |c| {
                    m.markCell(c);
                    for (d.savedRegs()) |v| m.markValue(v);
                }
                if (d.handlers) |c| {
                    m.markCell(c);
                    for (d.savedHandlers()) |h| if (h.env) |e| m.markCell(e.cell());
                }
                m.markValue(d.yielded);
                m.markValue(d.promise);
                m.markValue(d.resolve);
                m.markValue(d.reject);
                m.markValue(d.queue);
            },
            .promise => {
                const d = o.internal(PromiseData);
                m.markValue(d.result);
                m.markValue(d.fulfill_reactions);
                m.markValue(d.reject_reactions);
            },
            .map, .set, .weak_map, .weak_set, .proxy, .regexp, .date, .array_buffer, .typed_array, .data_view, .namespace => {
                // Stage c/d classes trace through their own hooks.
                realm.traceExtra(o, m);
            },
            .ordinary, .array, .global => {},
        }
        // Accessor properties: the slots hold accessor cells traced here.
        // (Marked as values already: an accessor cell is a cell value;
        // its get/set are traced when the cell is traced.)
    }

    fn finalizeCell(h: *Heap, c: *Cell) void {
        const vm: *Vm = @fieldParentPtr("heap", h);
        switch (c.kind) {
            .shape => vm.objects.finalizeShape(c.as(Shape)),
            .string => vm.strings.forget(c.as(String)),
            .code => {
                const code = c.as(Code);
                code.data.deinit(vm.meta);
                vm.meta.destroy(code.data);
            },
            .object => realm.finalizeExtra(vm, c.as(Object)),
            else => {},
        }
    }

    fn traceRoots(ctx: *anyopaque, m: *heap.Marker) void {
        const vm: *Vm = @ptrCast(@alignCast(ctx));
        vm.strings.markRoots(m);
        vm.objects.markRoots(m);
        realm.traceIntrinsics(vm, m);
        m.markCell(vm.global.cell());
        var it = vm.global_lex.iterator();
        while (it.next()) |e| {
            m.markCell(e.key_ptr.*.cell());
            m.markValue(e.value_ptr.v);
        }
        var sit = vm.symbol_registry.iterator();
        while (sit.next()) |e| {
            m.markCell(e.key_ptr.*.cell());
            m.markCell(&e.value_ptr.*.header);
        }
        m.markValue(vm.exception);
        // Frames and their register windows.
        for (vm.frames.items) |f| {
            m.markCell(f.code.cell());
            if (f.func) |fo| m.markCell(fo.cell());
            if (f.co) |co| m.markCell(co.cell());
            m.markValue(f.this);
            m.markValue(f.new_target);
            if (f.env) |e| m.markCell(e.cell());
            const end = f.base + f.code.data.nregs;
            for (vm.stack[f.base..end]) |v| m.markValue(v);
            for (vm.stack[f.args_base .. f.args_base + f.argc]) |v| m.markValue(v);
        }
        for (vm.handlers.items) |h| if (h.env) |e| m.markCell(e.cell());
        for (vm.jobs.items) |j| {
            m.markValue(j.func);
            for (j.args[0..j.argc]) |a| m.markValue(a);
        }
        for (vm.modules.values()) |mod| mod.trace(m);
        if (vm.embedder_roots) |r| r.trace(r.ctx, m);
    }

    /// One unit of the embedder's execution budget (a backward jump, a
    /// call, an element of a native loop): RangeError past the limit.
    pub inline fn tick(vm: *Vm) Error!void {
        vm.steps += 1;
        if (vm.steps > vm.step_limit) return vm.throwRangeError("execution budget exceeded");
    }

    /// A safe point: collect when the heap asks for it. Only the
    /// interpreter calls this, between instructions.
    pub fn safePoint(vm: *Vm) void {
        if (vm.heap.wantsCollect()) vm.heap.collect();
    }

    /// The accessor cell value's tracer is needed when a slot holds one:
    /// `Objects.trace` marks the accessor cell; this traces its values.
    pub fn traceAccessorCell(c: *Cell, m: *heap.Marker) void {
        Objects.traceAccessor(c.as(Accessor), m);
    }

    // -------------------------------------------------------- errors

    pub fn throwValue(vm: *Vm, v: Value) Error {
        vm.exception = v;
        return error.Exception;
    }

    pub fn throwError(vm: *Vm, kind: ErrorKind, msg: []const u8) Error {
        const e = vm.newError(kind, msg) catch |err| switch (err) {
            error.OutOfMemory => return error.OutOfMemory,
            else => unreachable,
        };
        vm.exception = e.asValue();
        return error.Exception;
    }

    pub fn throwTypeError(vm: *Vm, msg: []const u8) Error {
        return vm.throwError(.TypeError, msg);
    }
    pub fn throwRangeError(vm: *Vm, msg: []const u8) Error {
        return vm.throwError(.RangeError, msg);
    }
    pub fn throwReferenceError(vm: *Vm, msg: []const u8) Error {
        return vm.throwError(.ReferenceError, msg);
    }
    pub fn throwSyntaxError(vm: *Vm, msg: []const u8) Error {
        return vm.throwError(.SyntaxError, msg);
    }

    /// A TypeError with a formatted message.
    pub fn throwTypeErrorFmt(vm: *Vm, comptime fmt: []const u8, args: anytype) Error {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, fmt, args) catch "type error";
        return vm.throwError(.TypeError, msg);
    }

    /// An Error object of `kind` with `msg`.
    pub fn newError(vm: *Vm, kind: ErrorKind, msg: []const u8) Error!*Object {
        const proto = switch (kind) {
            .Error => vm.intrinsics.error_prototype,
            .TypeError => vm.intrinsics.type_error_prototype,
            .RangeError => vm.intrinsics.range_error_prototype,
            .ReferenceError => vm.intrinsics.reference_error_prototype,
            .SyntaxError => vm.intrinsics.syntax_error_prototype,
            .EvalError => vm.intrinsics.eval_error_prototype,
            .URIError => vm.intrinsics.uri_error_prototype,
            .AggregateError => vm.intrinsics.aggregate_error_prototype,
        };
        const o = try vm.objects.create(proto.asValue(), .error_, @sizeOf(ErrorData));
        const ed = o.internal(ErrorData);
        ed.* = .{ .pos = 0, .code = null };
        if (vm.frames.items.len > 0) {
            const f = vm.frames.items[vm.frames.items.len - 1];
            ed.pos = f.code.data.posOf(f.pc);
            ed.code = f.code;
        }
        const m = try vm.strings.fromUtf8(msg);
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.message }, Value.fromCell(m.cell()), .hidden);
        return o;
    }

    // ------------------------------------------------------- strings

    /// An atom for a literal.
    pub fn atom(vm: *Vm, s: []const u8) Error!*String {
        return vm.strings.atom(s);
    }
    pub fn str(vm: *Vm, s: []const u8) Error!Value {
        const st = try vm.strings.fromUtf8(s);
        return Value.fromCell(st.cell());
    }
    pub fn strValue(s: *String) Value {
        return Value.fromCell(s.cell());
    }
    pub fn asString(v: Value) *String {
        return v.asCell().as(String);
    }
    pub fn asObject(v: Value) *Object {
        return v.asCell().as(Object);
    }
    pub fn asSymbol(v: Value) *Symbol {
        return v.asCell().as(Symbol);
    }

    /// The UTF-8 of a string value, in `a`.
    pub fn utf8(vm: *Vm, s: *String, a: std.mem.Allocator) Error![]u8 {
        return vm.strings.toUtf8(a, s);
    }

    /// The longest string (in UTF-16 units) the engine builds.
    pub const max_string_len = 1 << 30;

    /// Concatenation with the length limit (RangeError past it).
    pub fn concatStrings(vm: *Vm, a: *String, b: *String) Error!*String {
        if (@as(u64, a.len) + b.len > max_string_len) return vm.throwRangeError("Invalid string length");
        return vm.strings.concat(a, b);
    }

    // ------------------------------------------------- type conversion

    pub fn toBoolean(vm: *Vm, v: Value) bool {
        _ = vm;
        if (v.isBool()) return v.asBool();
        if (v.isInt()) return v.asInt() != 0;
        if (v.isDouble()) {
            const d = v.asDouble();
            return !(d == 0 or std.math.isNan(d));
        }
        if (v.isNullish() or v.isEmpty()) return false;
        if (v.isString()) return asString(v).len != 0;
        if (v.isBigInt()) return realm.bigintIsNonZero(v);
        return true;
    }

    pub const PreferredType = enum { default, number, string };

    /// ToPrimitive (§7.1.1).
    pub fn toPrimitive(vm: *Vm, v: Value, hint: PreferredType) Error!Value {
        if (!v.isObject()) return v;
        const o = asObject(v);
        const exotic = try vm.getMethod(v, .{ .symbol = vm.symbols.to_primitive });
        if (!exotic.isUndefined()) {
            const hint_s = switch (hint) {
                .default => vm.atoms.default,
                .number => vm.atoms.number,
                .string => vm.atoms.string,
            };
            const r = try vm.call(exotic, v, &.{strValue(hint_s)});
            if (r.isObject()) return vm.throwTypeError("Cannot convert object to primitive value");
            return r;
        }
        return vm.ordinaryToPrimitive(o, if (hint == .string) .string else .number);
    }

    pub fn ordinaryToPrimitive(vm: *Vm, o: *Object, hint: PreferredType) Error!Value {
        const order: [2]*String = if (hint == .string) .{ vm.atoms.toString, vm.atoms.valueOf } else .{ vm.atoms.valueOf, vm.atoms.toString };
        for (order) |name| {
            const m = try vm.get(o, .{ .atom = name }, o.asValue());
            if (vm.isCallable(m)) {
                const r = try vm.call(m, o.asValue(), &.{});
                if (!r.isObject()) return r;
            }
        }
        return vm.throwTypeError("Cannot convert object to primitive value");
    }

    /// ToNumber (§7.1.4).
    pub fn toNumber(vm: *Vm, v: Value) Error!f64 {
        if (v.isNumber()) return v.asNumber();
        if (v.isUndefined()) return std.math.nan(f64);
        if (v.isNull()) return 0;
        if (v.isBool()) return if (v.asBool()) 1 else 0;
        if (v.isString()) return vm.stringToNumber(asString(v));
        if (v.isSymbol()) return vm.throwTypeError("Cannot convert a Symbol value to a number");
        if (v.isBigInt()) return vm.throwTypeError("Cannot convert a BigInt value to a number");
        const p = try vm.toPrimitive(v, .number);
        return vm.toNumber(p);
    }

    /// ToNumeric: a Number or a BigInt value.
    pub fn toNumeric(vm: *Vm, v: Value) Error!Value {
        const p = try vm.toPrimitive(v, .number);
        if (p.isBigInt()) return p;
        return Value.fromF64(try vm.toNumber(p));
    }

    /// StringToNumber (§7.1.4.1.1).
    pub fn stringToNumber(vm: *Vm, s: *String) Error!f64 {
        const flat = try vm.strings.flatten(s);
        var buf: [64]u8 = undefined;
        var a = std.heap.stackFallback(256, vm.meta);
        const alloc = a.get();
        const text = try vm.strings.toUtf8(alloc, flat);
        defer alloc.free(text);
        _ = &buf;
        return parseNumberLiteral(std.mem.trim(u8, text, &whitespace_utf8)) orelse std.math.nan(f64);
    }

    /// ToString (§7.1.17) to a string cell.
    pub fn toString(vm: *Vm, v: Value) Error!*String {
        if (v.isString()) return asString(v);
        if (v.isInt()) {
            var buf: [16]u8 = undefined;
            const s = std.fmt.bufPrint(&buf, "{d}", .{v.asInt()}) catch unreachable;
            return vm.strings.fromUtf8(s);
        }
        if (v.isDouble()) {
            var buf: [64]u8 = undefined;
            return vm.strings.fromUtf8(compiler.numberToString(&buf, v.asDouble()));
        }
        if (v.isUndefined()) return vm.atoms.undefined_;
        if (v.isNull()) return vm.atoms.null_;
        if (v.isBool()) return if (v.asBool()) vm.atoms.true_ else vm.atoms.false_;
        if (v.isSymbol()) return vm.throwTypeError("Cannot convert a Symbol value to a string");
        if (v.isBigInt()) return realm.bigintToString(vm, v, 10);
        const p = try vm.toPrimitive(v, .string);
        return vm.toString(p);
    }

    pub fn toStringValue(vm: *Vm, v: Value) Error!Value {
        return strValue(try vm.toString(v));
    }

    /// ToObject (§7.1.18).
    pub fn toObject(vm: *Vm, v: Value) Error!*Object {
        if (v.isObject()) return asObject(v);
        if (v.isNullish() or v.isEmpty()) return vm.throwTypeError("Cannot convert undefined or null to object");
        var proto: *Object = undefined;
        var class: Class = undefined;
        if (v.isNumber()) {
            proto = vm.intrinsics.number_prototype;
            class = .number;
        } else if (v.isBool()) {
            proto = vm.intrinsics.boolean_prototype;
            class = .boolean;
        } else if (v.isString()) {
            proto = vm.intrinsics.string_prototype;
            class = .string;
        } else if (v.isSymbol()) {
            proto = vm.intrinsics.symbol_prototype;
            class = .symbol;
        } else {
            proto = vm.intrinsics.bigint_prototype;
            class = .bigint;
        }
        const o = try vm.objects.create(proto.asValue(), class, @sizeOf(PrimitiveData));
        o.internal(PrimitiveData).value = v;
        if (class == .string) {
            // The wrapper's `length`.
            _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(asString(v).len)), .frozen);
        }
        return o;
    }

    /// ToPropertyKey (§7.1.19).
    pub fn toPropertyKey(vm: *Vm, v: Value) Error!Key {
        if (v.isInt()) {
            const i = v.asInt();
            if (i >= 0) return .{ .index = @intCast(i) };
        }
        if (v.isSymbol()) return .{ .symbol = asSymbol(v) };
        if (v.isString()) return vm.keyFromString(asString(v));
        if (v.isDouble()) {
            const d = v.asDouble();
            if (d >= 0 and d < 4294967295.0 and d == @trunc(d)) return .{ .index = @intFromFloat(d) };
        }
        const p = try vm.toPrimitive(v, .string);
        if (p.isSymbol()) return .{ .symbol = asSymbol(p) };
        return vm.keyFromString(try vm.toString(p));
    }

    pub fn keyFromString(vm: *Vm, s: *String) Error!Key {
        const flat = try vm.strings.flatten(s);
        if (flat.latin1()) |bytes| {
            if (compiler.arrayIndex(bytes)) |i| return .{ .index = i };
        }
        return .{ .atom = try vm.strings.intern(flat) };
    }

    /// A key back to a value (string or symbol).
    pub fn keyToValue(vm: *Vm, k: Key) Error!Value {
        return switch (k) {
            .atom => |s| strValue(s),
            .symbol => |s| Value.fromCell(&s.header),
            .index => |i| strValue(try vm.toString(Value.fromF64(@floatFromInt(i)))),
        };
    }

    pub fn keyToString(vm: *Vm, k: Key) Error!*String {
        return switch (k) {
            .atom => |s| s,
            .symbol => vm.throwTypeError("Cannot convert a Symbol value to a string"),
            .index => |i| vm.toString(Value.fromF64(@floatFromInt(i))),
        };
    }

    /// ToIntegerOrInfinity (§7.1.5).
    pub fn toIntegerOrInfinity(vm: *Vm, v: Value) Error!f64 {
        const d = try vm.toNumber(v);
        if (std.math.isNan(d)) return 0;
        if (std.math.isInf(d)) return d;
        return @trunc(d) + 0.0;
    }

    /// ToLength (§7.1.20).
    pub fn toLength(vm: *Vm, v: Value) Error!u64 {
        const d = try vm.toIntegerOrInfinity(v);
        if (d <= 0) return 0;
        if (d >= 9007199254740991.0) return 9007199254740991;
        return @intFromFloat(d);
    }

    /// ToIndex (§7.1.22).
    pub fn toIndex(vm: *Vm, v: Value) Error!u64 {
        if (v.isUndefined()) return 0;
        const d = try vm.toIntegerOrInfinity(v);
        if (d < 0 or d > 9007199254740991.0) return vm.throwRangeError("Invalid index");
        return @intFromFloat(d);
    }

    pub fn toInt32(vm: *Vm, v: Value) Error!i32 {
        if (v.isInt()) return v.asInt();
        return f64ToInt32(try vm.toNumber(v));
    }
    pub fn toUint32(vm: *Vm, v: Value) Error!u32 {
        if (v.isInt()) return @bitCast(v.asInt());
        return @bitCast(f64ToInt32(try vm.toNumber(v)));
    }

    pub fn f64ToInt32(d: f64) i32 {
        if (std.math.isNan(d) or std.math.isInf(d)) return 0;
        const t = @trunc(d);
        if (t >= -2147483648.0 and t <= 2147483647.0) return @intFromFloat(t);
        const m = @mod(t, 4294967296.0);
        const u: u32 = @intFromFloat(m);
        return @bitCast(u);
    }

    /// CanonicalNumericIndexString for typed arrays / string keys: not needed yet.
    // ---------------------------------------------------- comparisons

    pub fn sameValue(vm: *Vm, a: Value, b: Value) bool {
        if (a.isNumber() and b.isNumber()) {
            const x = a.asNumber();
            const y = b.asNumber();
            if (std.math.isNan(x) and std.math.isNan(y)) return true;
            if (x == 0 and y == 0) return std.math.signbit(x) == std.math.signbit(y);
            return x == y;
        }
        return vm.sameValueNonNumber(a, b);
    }

    pub fn sameValueZero(vm: *Vm, a: Value, b: Value) bool {
        if (a.isNumber() and b.isNumber()) {
            const x = a.asNumber();
            const y = b.asNumber();
            if (std.math.isNan(x) and std.math.isNan(y)) return true;
            return x == y;
        }
        return vm.sameValueNonNumber(a, b);
    }

    fn sameValueNonNumber(vm: *Vm, a: Value, b: Value) bool {
        if (a.isString() and b.isString()) return vm.stringEquals(asString(a), asString(b));
        if (a.isBigInt() and b.isBigInt()) return realm.bigintEquals(a, b);
        return a.eqlBits(b);
    }

    pub fn stringEquals(vm: *Vm, a: *String, b: *String) bool {
        if (a == b) return true;
        if (a.len != b.len) return false;
        if (a.atom and b.atom) return false;
        const fa = vm.strings.flatten(a) catch return false;
        const fb = vm.strings.flatten(b) catch return false;
        return fa.eql(fb);
    }

    /// IsStrictlyEqual (§7.2.15).
    pub fn isStrictlyEqual(vm: *Vm, a: Value, b: Value) bool {
        if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber();
        if (a.isNumber() or b.isNumber()) return false;
        return vm.sameValueNonNumber(a, b);
    }

    /// IsLooselyEqual (§7.2.14).
    pub fn isLooselyEqual(vm: *Vm, a: Value, b: Value) Error!bool {
        if (a.isNumber() and b.isNumber()) return a.asNumber() == b.asNumber();
        if (a.isString() and b.isString()) return vm.stringEquals(asString(a), asString(b));
        if (a.isNullish() and b.isNullish()) return true;
        if (a.isNullish() or b.isNullish()) return false;
        if (a.isBool() and b.isBool()) return a.eqlBits(b);
        if (a.isSymbol() and b.isSymbol()) return a.eqlBits(b);
        if (a.isObject() and b.isObject()) return a.eqlBits(b);
        if (a.isBigInt() and b.isBigInt()) return realm.bigintEquals(a, b);
        if (a.isNumber() and b.isString()) return a.asNumber() == try vm.toNumber(b);
        if (a.isString() and b.isNumber()) return (try vm.toNumber(a)) == b.asNumber();
        if (a.isBigInt() and b.isString()) return realm.bigintLooseEqualsString(vm, a, asString(b));
        if (a.isString() and b.isBigInt()) return realm.bigintLooseEqualsString(vm, b, asString(a));
        if (a.isBool()) return vm.isLooselyEqual(Value.fromF64(if (a.asBool()) 1 else 0), b);
        if (b.isBool()) return vm.isLooselyEqual(a, Value.fromF64(if (b.asBool()) 1 else 0));
        if ((a.isNumber() or a.isString() or a.isBigInt() or a.isSymbol()) and b.isObject()) return vm.isLooselyEqual(a, try vm.toPrimitive(b, .default));
        if (a.isObject() and (b.isNumber() or b.isString() or b.isBigInt() or b.isSymbol())) return vm.isLooselyEqual(try vm.toPrimitive(a, .default), b);
        if (a.isBigInt() and b.isNumber()) return realm.bigintEqualsNumber(a, b.asNumber());
        if (a.isNumber() and b.isBigInt()) return realm.bigintEqualsNumber(b, a.asNumber());
        return false;
    }

    /// IsLessThan (§7.2.13): true, false, or undefined (NaN) as ?bool.
    pub fn isLessThan(vm: *Vm, x: Value, y: Value, left_first: bool) Error!?bool {
        var px: Value = undefined;
        var py: Value = undefined;
        if (left_first) {
            px = try vm.toPrimitive(x, .number);
            py = try vm.toPrimitive(y, .number);
        } else {
            py = try vm.toPrimitive(y, .number);
            px = try vm.toPrimitive(x, .number);
        }
        if (px.isString() and py.isString()) {
            return try vm.stringLessThan(asString(px), asString(py));
        }
        if (px.isBigInt() and py.isString()) {
            const ny = realm.stringToBigInt(vm, asString(py)) catch return null;
            const nyv = ny orelse return null;
            return realm.bigintCompare(px, nyv) == .lt;
        }
        if (px.isString() and py.isBigInt()) {
            const nx = realm.stringToBigInt(vm, asString(px)) catch return null;
            const nxv = nx orelse return null;
            return realm.bigintCompare(nxv, py) == .lt;
        }
        const nx = try vm.toNumeric(px);
        const ny = try vm.toNumeric(py);
        if (nx.isBigInt() and ny.isBigInt()) return realm.bigintCompare(nx, ny) == .lt;
        if (nx.isBigInt()) {
            const d = ny.asNumber();
            if (std.math.isNan(d)) return null;
            return realm.bigintCompareNumber(nx, d) == .lt;
        }
        if (ny.isBigInt()) {
            const d = nx.asNumber();
            if (std.math.isNan(d)) return null;
            return realm.bigintCompareNumber(ny, d) == .gt;
        }
        const a = nx.asNumber();
        const b = ny.asNumber();
        if (std.math.isNan(a) or std.math.isNan(b)) return null;
        return a < b;
    }

    pub fn stringLessThan(vm: *Vm, a: *String, b: *String) Error!bool {
        const fa = try vm.strings.flatten(a);
        const fb = try vm.strings.flatten(b);
        const n = @min(fa.len, fb.len);
        var i: usize = 0;
        while (i < n) : (i += 1) {
            const ca = fa.unitAt(i);
            const cb = fb.unitAt(i);
            if (ca != cb) return ca < cb;
        }
        return fa.len < fb.len;
    }

    pub fn typeOf(vm: *Vm, v: Value) *String {
        const a = &vm.atoms;
        if (v.isNumber()) return a.number;
        if (v.isString()) return a.string;
        if (v.isUndefined()) return a.undefined_;
        if (v.isNull()) return a.object;
        if (v.isBool()) return a.boolean;
        if (v.isSymbol()) return a.symbol;
        if (v.isBigInt()) return a.bigint;
        if (v.isObject()) {
            const o = asObject(v);
            if (o.class == .proxy) return realm.proxyTypeOf(vm, o);
            return if (vm.isCallable(v)) a.function else a.object;
        }
        return a.undefined_;
    }

    // ----------------------------------------------------- objects

    pub fn isCallable(vm: *Vm, v: Value) bool {
        if (!v.isObject()) return false;
        const o = asObject(v);
        return switch (o.class) {
            .function, .bound_function => true,
            .proxy => realm.proxyIsCallable(vm, o),
            else => false,
        };
    }

    pub fn isConstructor(vm: *Vm, v: Value) bool {
        if (!v.isObject()) return false;
        const o = asObject(v);
        return switch (o.class) {
            .function => o.internal(FunctionData).is_constructor,
            .bound_function => vm.isConstructor(o.internal(BoundData).target.asValue()),
            .proxy => realm.proxyIsConstructor(vm, o),
            else => false,
        };
    }

    /// IsArray (§7.2.2).
    pub fn isArray(vm: *Vm, v: Value) Error!bool {
        if (!v.isObject()) return false;
        const o = asObject(v);
        if (o.class == .array) return true;
        if (o.class == .proxy) return realm.proxyIsArray(vm, o);
        return false;
    }

    pub fn newObject(vm: *Vm) Error!*Object {
        return vm.objects.create(vm.intrinsics.object_prototype.asValue(), .ordinary, 0);
    }

    pub fn newObjectWithProto(vm: *Vm, proto: Value) Error!*Object {
        return vm.objects.create(proto, .ordinary, 0);
    }

    pub fn newArray(vm: *Vm, len: u32) Error!*Object {
        const o = try vm.objects.create(vm.intrinsics.array_prototype.asValue(), .array, 0);
        if (len > 0) {
            const e = try vm.objects.growElements(o, @min(len, 1 << 16));
            e.len = len;
        }
        return o;
    }

    /// ArrayCreate(len) for a 64-bit length.
    pub fn newArrayLen(vm: *Vm, len: u64) Error!*Object {
        if (len > 0xFFFF_FFFF) return vm.throwRangeError("Invalid array length");
        return vm.newArray(@intCast(len));
    }

    /// CreateArrayFromList.
    pub fn arrayFromList(vm: *Vm, items: []const Value) Error!*Object {
        const o = try vm.newArray(0);
        if (items.len == 0) return o;
        const e = try vm.objects.growElements(o, @intCast(items.len));
        @memcpy(e.items()[0..items.len], items);
        e.len = @intCast(items.len);
        return o;
    }

    pub fn arrayLength(o: *Object) u32 {
        return if (o.elements) |e| e.len else 0;
    }

    /// Append to an array (the literal-building fast path).
    pub fn arrayPush(vm: *Vm, o: *Object, v: Value) Error!void {
        const len = arrayLength(o);
        const e = try vm.objects.growElements(o, len + 1);
        e.items()[len] = v;
        e.len = len + 1;
    }

    /// A JS function object from code.
    pub fn newFunction(vm: *Vm, code: *Code, env: ?*Env, home: Value) Error!*Object {
        const d = code.data;
        const proto = switch (d.kind) {
            .generator => vm.intrinsics.generator_function_prototype,
            .async_function, .async_arrow => vm.intrinsics.async_function_prototype,
            .async_generator => vm.intrinsics.async_generator_function_prototype,
            else => vm.intrinsics.function_prototype,
        };
        const o = try vm.objects.create(proto.asValue(), .function, @sizeOf(FunctionData));
        const f = o.internal(FunctionData);
        f.* = .{
            .code = code,
            .env = env,
            .native = null,
            .home_object = home,
            .fields = Value.undefined_,
            .data = Value.undefined_,
            .this_mode = if (d.kind == .arrow or d.kind == .async_arrow) .lexical else if (d.strict) .strict else .sloppy,
            .is_class_constructor = d.kind == .class_constructor or d.kind == .derived_constructor,
            .is_constructor = d.is_constructor,
            .derived = d.kind == .derived_constructor,
        };
        // length and name.
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(d.length)), .{ .writable = false, .enumerable = false, .configurable = true });
        const name: Value = if (d.name) |n| strValue(n) else strValue(vm.atoms.empty);
        var name_v = name;
        if (d.kind == .getter or d.kind == .setter) {
            const prefix = if (d.kind == .getter) "get " else "set ";
            name_v = strValue(try vm.strings.concat(try vm.strings.fromUtf8(prefix), asString(name)));
        }
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.name }, name_v, .{ .writable = false, .enumerable = false, .configurable = true });
        // A sloppy plain function carries the legacy `caller` and
        // `arguments` (null, immutable), as implementations do; the
        // poison pills on Function.prototype then apply only to the rest.
        if (d.kind == .normal and !d.strict) {
            _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.caller }, Value.null_, .frozen);
            _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.arguments }, Value.null_, .frozen);
        }
        // A constructor gets a prototype object; generators get their
        // prototype from the generator prototype.
        if (d.kind == .generator or d.kind == .async_generator) {
            const gp = try vm.objects.create((if (d.kind == .generator) vm.intrinsics.generator_prototype else vm.intrinsics.async_generator_prototype).asValue(), .ordinary, 0);
            _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.prototype }, gp.asValue(), .{ .writable = true, .enumerable = false, .configurable = false });
        } else if (d.is_constructor and d.kind != .method) {
            const p = try vm.newObject();
            _ = try vm.objects.defineOwn(p, .{ .atom = vm.atoms.constructor }, o.asValue(), .hidden);
            _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.prototype }, p.asValue(), .{ .writable = d.kind == .normal, .enumerable = false, .configurable = false });
        }
        return o;
    }

    /// A native function object.
    pub fn newNative(vm: *Vm, name: []const u8, length: u32, f: NativeFn, data: Value) Error!*Object {
        return vm.newNativeNamed(strValue(try vm.strings.atom(name)), length, f, data, false);
    }

    pub fn newNativeNamed(vm: *Vm, name: Value, length: u32, f: NativeFn, data: Value, is_ctor: bool) Error!*Object {
        const o = try vm.objects.create(vm.intrinsics.function_prototype.asValue(), .function, @sizeOf(FunctionData));
        const fd = o.internal(FunctionData);
        fd.* = .{
            .code = null,
            .env = null,
            .native = f,
            .home_object = Value.undefined_,
            .fields = Value.undefined_,
            .data = data,
            .this_mode = .strict,
            .is_class_constructor = false,
            .is_constructor = is_ctor,
            .derived = false,
        };
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(length)), .{ .writable = false, .enumerable = false, .configurable = true });
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.name }, name, .{ .writable = false, .enumerable = false, .configurable = true });
        return o;
    }

    /// Define a method on `o` (writable, configurable, not enumerable).
    pub fn defineNative(vm: *Vm, o: *Object, name: []const u8, length: u32, f: NativeFn) Error!*Object {
        const fo = try vm.newNative(name, length, f, Value.undefined_);
        _ = try vm.objects.defineOwn(o, .{ .atom = try vm.atom(name) }, fo.asValue(), .hidden);
        return fo;
    }

    pub fn defineNativeSymbol(vm: *Vm, o: *Object, sym: *Symbol, name: []const u8, length: u32, f: NativeFn) Error!*Object {
        const fo = try vm.newNative(name, length, f, Value.undefined_);
        _ = try vm.objects.defineOwn(o, .{ .symbol = sym }, fo.asValue(), .hidden);
        return fo;
    }

    pub fn defineValue(vm: *Vm, o: *Object, name: []const u8, v: Value, attrs: Attributes) Error!void {
        _ = try vm.objects.defineOwn(o, .{ .atom = try vm.atom(name) }, v, attrs);
    }

    /// An accessor property.
    pub fn defineAccessor(vm: *Vm, o: *Object, key: Key, getter: ?*Object, setter: ?*Object, attrs: Attributes) Error!void {
        const acc = try vm.newAccessor(if (getter) |g| g.asValue() else Value.undefined_, if (setter) |s| s.asValue() else Value.undefined_);
        var a = attrs;
        a.accessor = true;
        a.writable = false;
        _ = try vm.objects.defineOwn(o, key, Value.fromCell(&acc.header), a);
    }

    pub fn defineGetter(vm: *Vm, o: *Object, name: []const u8, f: NativeFn) Error!void {
        const g = try vm.newNativeNamed(strValue(try vm.strings.concat(try vm.strings.fromUtf8("get "), try vm.atom(name))), 0, f, Value.undefined_, false);
        try vm.defineAccessor(o, .{ .atom = try vm.atom(name) }, g, null, .{ .enumerable = false, .configurable = true });
    }

    pub fn newAccessor(vm: *Vm, get_: Value, set_: Value) Error!*Accessor {
        const c = try vm.heap.alloc(.accessor, @sizeOf(Accessor));
        const acc = c.as(Accessor);
        acc.get = get_;
        acc.set = set_;
        return acc;
    }

    pub fn newSymbol(vm: *Vm, description: ?*String) Error!*Symbol {
        const c = try vm.heap.alloc(.symbol, @sizeOf(Symbol));
        const s = c.as(Symbol);
        s.description = description;
        s.registered = false;
        return s;
    }

    // ------------------------------------------------- property access

    /// [[GetOwnProperty]] with exotic objects handled.
    pub fn getOwnProperty(vm: *Vm, o: *Object, key: Key) Error!?Objects.Own {
        switch (o.class) {
            .array => if (key == .atom and key.atom == vm.atoms.length) {
                return .{ .val = Value.fromF64(@floatFromInt(arrayLength(o))), .attrs = .{ .writable = vm.arrayLengthWritable(o), .enumerable = false, .configurable = false }, .slot = null };
            },
            .arguments => if (key == .index) if (try realm.argumentsGetOwn(vm, o, key.index)) |own| return own,
            .proxy => return realm.proxyGetOwnProperty(vm, o, key),
            .namespace => return module.nsGetOwnProperty(vm, o, key),
            .typed_array => if (try realm.typedArrayNumericKey(vm, key)) |n| return realm.typedArrayGetOwn(vm, o, n),
            else => {},
        }
        return vm.objects.getOwn(o, key);
    }

    pub fn arrayLengthWritable(vm: *Vm, o: *Object) bool {
        return vm.lengthWritable(o);
    }

    /// [[Get]] (§10.1.8) with receiver.
    pub fn get(vm: *Vm, o: *Object, key: Key, receiver: Value) Error!Value {
        var cur: *Object = o;
        while (true) {
            if (cur.class == .proxy) return realm.proxyGet(vm, cur, key, receiver);
            if (cur.class == .typed_array) if (try realm.typedArrayNumericKey(vm, key)) |n| return realm.typedArrayGetElement(vm, cur, n);
            if (try vm.getOwnProperty(cur, key)) |own| {
                if (own.attrs.accessor) {
                    const acc = own.val.asCell().as(Accessor);
                    if (acc.get.isUndefined()) return Value.undefined_;
                    return vm.call(acc.get, receiver, &.{});
                }
                return own.val;
            }
            const p = cur.shape.proto;
            if (!p.isObject()) return Value.undefined_;
            cur = asObject(p);
        }
    }

    /// GetV: property of any value (primitives through their prototype).
    pub fn getV(vm: *Vm, v: Value, key: Key) Error!Value {
        if (v.isObject()) return vm.get(asObject(v), key, v);
        if (v.isString()) {
            const s = asString(v);
            if (key == .index) {
                if (key.index < s.len) {
                    const flat = try vm.strings.flatten(s);
                    const unit = [_]u16{flat.unitAt(key.index)};
                    return strValue(try vm.strings.fromUnits(&unit));
                }
                return Value.undefined_;
            }
            if (key == .atom and key.atom == vm.atoms.length) return Value.fromInt(@intCast(s.len));
            return vm.get(vm.intrinsics.string_prototype, key, v);
        }
        if (v.isNumber()) return vm.get(vm.intrinsics.number_prototype, key, v);
        if (v.isBool()) return vm.get(vm.intrinsics.boolean_prototype, key, v);
        if (v.isSymbol()) return vm.get(vm.intrinsics.symbol_prototype, key, v);
        if (v.isBigInt()) return vm.get(vm.intrinsics.bigint_prototype, key, v);
        return vm.throwTypeErrorFmt("Cannot read properties of {s}", .{if (v.isNull()) "null" else "undefined"});
    }

    /// GetMethod (§7.3.11).
    pub fn getMethod(vm: *Vm, v: Value, key: Key) Error!Value {
        const f = try vm.getV(v, key);
        if (f.isNullish()) return Value.undefined_;
        if (!vm.isCallable(f)) return vm.throwTypeError("is not a function");
        return f;
    }

    /// [[Set]] (§10.1.9): OrdinarySet with receiver.
    pub fn set(vm: *Vm, o: *Object, key: Key, v: Value, receiver: Value) Error!bool {
        var cur: *Object = o;
        var own_desc: ?Objects.Own = null;
        while (true) {
            if (cur.class == .proxy) return realm.proxySet(vm, cur, key, v, receiver);
            if (cur.class == .namespace and key != .symbol) return false;
            if (cur.class == .typed_array) if (try realm.typedArrayNumericKey(vm, key)) |n| {
                var result = false;
                if (try realm.typedArraySetNumeric(vm, cur, n, v, receiver, &result)) return result;
            };
            own_desc = try vm.getOwnProperty(cur, key);
            if (own_desc != null) break;
            const p = cur.shape.proto;
            if (!p.isObject()) break;
            cur = asObject(p);
        }
        if (own_desc) |d| {
            if (d.attrs.accessor) {
                const acc = d.val.asCell().as(Accessor);
                if (acc.set.isUndefined()) return false;
                _ = try vm.call(acc.set, receiver, &.{v});
                return true;
            }
            if (!d.attrs.writable) return false;
            if (!receiver.isObject()) return false;
            const r = asObject(receiver);
            if (r == cur and d.slot != null and r.class != .proxy and r.class != .arguments) {
                // The fast path: the receiver owns the data property.
                vm.heap.writeBarrier(&r.header, v);
                r.slot(d.slot.?).* = v;
                return true;
            }
            // The receiver's own property, or a new one.
            if (try vm.getOwnProperty(r, key)) |rd| {
                if (rd.attrs.accessor or !rd.attrs.writable) return false;
                return vm.defineOwnProperty(r, key, .{ .value = v }, false);
            }
            return vm.createDataProperty(r, key, v);
        }
        if (!receiver.isObject()) return false;
        const r = asObject(receiver);
        if (r != o) {
            // The walk began elsewhere (Reflect.set, a proxy target):
            // the receiver may own the key (§10.1.9.2 step 2.c).
            if (try vm.getOwnProperty(r, key)) |rd| {
                if (rd.attrs.accessor or !rd.attrs.writable) return false;
                return vm.defineOwnProperty(r, key, .{ .value = v }, false);
            }
        }
        return vm.createDataProperty(r, key, v);
    }

    /// Set on any value (PutValue for a member reference).
    pub fn setV(vm: *Vm, target: Value, key: Key, v: Value, strict: bool) Error!void {
        if (target.isObject()) {
            const ok = try vm.set(asObject(target), key, v, target);
            if (!ok and strict) return vm.throwTypeErrorFmt("Cannot assign to read only property '{s}'", .{vm.keyDebug(key)});
            return;
        }
        if (target.isNullish()) return vm.throwTypeErrorFmt("Cannot set properties of {s}", .{if (target.isNull()) "null" else "undefined"});
        const o = try vm.toObject(target);
        const ok = try vm.set(o, key, v, target);
        if (!ok and strict) return vm.throwTypeError("Cannot create property on primitive value");
    }

    pub fn keyDebug(vm: *Vm, key: Key) []const u8 {
        return switch (key) {
            .atom => |s| s.latin1() orelse "?",
            .symbol => "symbol",
            .index => blk: {
                _ = vm;
                break :blk "index";
            },
        };
    }

    /// HasProperty (§7.3.12).
    pub fn hasProperty(vm: *Vm, o: *Object, key: Key) Error!bool {
        var cur: *Object = o;
        while (true) {
            if (cur.class == .proxy) return realm.proxyHas(vm, cur, key);
            if (cur.class == .typed_array) if (try realm.typedArrayNumericKey(vm, key)) |n| return realm.typedArrayIsValidIndex(cur, n);
            if ((try vm.getOwnProperty(cur, key)) != null) return true;
            const p = cur.shape.proto;
            if (!p.isObject()) return false;
            cur = asObject(p);
        }
    }

    pub fn hasOwnProperty(vm: *Vm, o: *Object, key: Key) Error!bool {
        return (try vm.getOwnProperty(o, key)) != null;
    }

    /// A property descriptor for [[DefineOwnProperty]].
    pub const Descriptor = struct {
        value: ?Value = null,
        get: ?Value = null,
        set: ?Value = null,
        writable: ?bool = null,
        enumerable: ?bool = null,
        configurable: ?bool = null,

        pub fn isAccessor(d: Descriptor) bool {
            return d.get != null or d.set != null;
        }
        pub fn isData(d: Descriptor) bool {
            return d.value != null or d.writable != null;
        }
    };

    /// [[DefineOwnProperty]] (§10.1.6) — ValidateAndApplyPropertyDescriptor,
    /// with array `length` and index semantics (§10.4.2.1).
    pub fn defineOwnProperty(vm: *Vm, o: *Object, key: Key, desc: Descriptor, throw: bool) Error!bool {
        const ok = try vm.defineOwnPropertyInner(o, key, desc);
        if (!ok and throw) return vm.throwTypeErrorFmt("Cannot redefine property: {s}", .{vm.keyDebug(key)});
        return ok;
    }

    fn defineOwnPropertyInner(vm: *Vm, o: *Object, key: Key, desc: Descriptor) Error!bool {
        switch (o.class) {
            .array => {
                if (key == .atom and key.atom == vm.atoms.length) return vm.arraySetLength(o, desc);
                if (key == .index) {
                    const len = arrayLength(o);
                    if (key.index >= len and !vm.arrayLengthWritableReal(o)) return false;
                    const ok = try vm.ordinaryDefineOwnProperty(o, key, desc);
                    if (!ok) return false;
                    if (key.index >= len) {
                        if (o.elements) |e| {
                            e.len = key.index + 1;
                        } else {
                            const e = try vm.objects.growElements(o, 1);
                            e.len = key.index + 1;
                        }
                    }
                    return true;
                }
            },
            .arguments => if (key == .index) return realm.argumentsDefineOwn(vm, o, key.index, desc),
            .proxy => return realm.proxyDefineOwnProperty(vm, o, key, desc),
            .namespace => return module.nsDefineOwnProperty(vm, o, key, desc),
            .typed_array => if (try realm.typedArrayNumericKey(vm, key)) |n| return realm.typedArrayDefineOwn(vm, o, n, desc),
            .string => if (key == .index) {
                // String index properties are not redefinable.
                const s = o.internal(PrimitiveData).value;
                if (key.index < asString(s).len) {
                    const cur = (try vm.objects.getOwn(o, key)).?;
                    return vm.isCompatible(cur, desc);
                }
            },
            else => {},
        }
        return vm.ordinaryDefineOwnProperty(o, key, desc);
    }

    fn arrayLengthWritableReal(vm: *Vm, o: *Object) bool {
        return vm.lengthWritable(o);
    }

    /// Whether `desc` is compatible with an existing non-configurable
    /// property `cur` (no change).
    fn isCompatible(vm: *Vm, cur: Objects.Own, desc: Descriptor) bool {
        if (desc.configurable orelse false) return false;
        if (desc.enumerable != null and desc.enumerable.? != cur.attrs.enumerable) return false;
        if (cur.attrs.accessor) {
            if (desc.isData()) return false;
            const acc = cur.val.asCell().as(Accessor);
            if (desc.get != null and !desc.get.?.eqlBits(acc.get)) return false;
            if (desc.set != null and !desc.set.?.eqlBits(acc.set)) return false;
            return true;
        }
        if (desc.isAccessor()) return false;
        if (!cur.attrs.writable) {
            if (desc.writable orelse false) return false;
            if (desc.value != null and !vm.sameValue(desc.value.?, cur.val)) return false;
        }
        return true;
    }

    pub fn ordinaryDefineOwnProperty(vm: *Vm, o: *Object, key: Key, desc: Descriptor) Error!bool {
        if (key == .index and (o == vm.intrinsics.array_prototype or o == vm.intrinsics.object_prototype)) vm.proto_has_indexes = true;
        const current = try vm.objects.getOwn(o, key);
        if (current == null) {
            if (!o.extensible) return false;
            if (desc.isAccessor()) {
                const acc = try vm.newAccessor(desc.get orelse Value.undefined_, desc.set orelse Value.undefined_);
                return vm.objects.defineOwn(o, key, Value.fromCell(&acc.header), .{ .accessor = true, .writable = false, .enumerable = desc.enumerable orelse false, .configurable = desc.configurable orelse false });
            }
            return vm.objects.defineOwn(o, key, desc.value orelse Value.undefined_, .{ .writable = desc.writable orelse false, .enumerable = desc.enumerable orelse false, .configurable = desc.configurable orelse false });
        }
        const cur = current.?;
        // Every field absent: nothing to do.
        if (desc.value == null and desc.get == null and desc.set == null and desc.writable == null and desc.enumerable == null and desc.configurable == null) return true;
        if (!cur.attrs.configurable) {
            if (desc.configurable orelse false) return false;
            if (desc.enumerable != null and desc.enumerable.? != cur.attrs.enumerable) return false;
            if (desc.isAccessor() and !cur.attrs.accessor) return false;
            if (desc.isData() and cur.attrs.accessor) return false;
            if (cur.attrs.accessor) {
                const acc = cur.val.asCell().as(Accessor);
                if (desc.get != null and !desc.get.?.eqlBits(acc.get)) return false;
                if (desc.set != null and !desc.set.?.eqlBits(acc.set)) return false;
                return true;
            }
            if (!cur.attrs.writable) {
                if (desc.writable orelse false) return false;
                if (desc.value != null and !vm.sameValue(desc.value.?, cur.val)) return false;
                return true;
            }
        }
        var attrs = cur.attrs;
        if (desc.enumerable) |e| attrs.enumerable = e;
        if (desc.configurable) |cf| attrs.configurable = cf;
        var val = cur.val;
        if (desc.isAccessor()) {
            if (!cur.attrs.accessor) {
                attrs.accessor = true;
                attrs.writable = false;
                val = Value.fromCell(&(try vm.newAccessor(desc.get orelse Value.undefined_, desc.set orelse Value.undefined_)).header);
            } else {
                const old = cur.val.asCell().as(Accessor);
                val = Value.fromCell(&(try vm.newAccessor(desc.get orelse old.get, desc.set orelse old.set)).header);
            }
        } else if (desc.isData()) {
            if (cur.attrs.accessor) {
                attrs.accessor = false;
                attrs.writable = desc.writable orelse false;
                val = desc.value orelse Value.undefined_;
            } else {
                if (desc.writable) |w| attrs.writable = w;
                if (desc.value) |v| val = v;
            }
        }
        // A data property keeping its attributes: a plain slot write.
        if (@as(u8, @bitCast(attrs)) == @as(u8, @bitCast(cur.attrs)) and cur.slot != null and !attrs.accessor) {
            vm.heap.writeBarrier(&o.header, val);
            o.slot(cur.slot.?).* = val;
            return true;
        }
        // Force the (possibly non-configurable) redefinition through.
        return vm.objects.defineOwnForce(o, key, val, attrs);
    }

    /// ArraySetLength (§10.4.2.4).
    fn arraySetLength(vm: *Vm, o: *Object, desc: Descriptor) Error!bool {
        if (desc.value == null) {
            if (desc.isAccessor()) return false;
            if (desc.configurable orelse false) return false;
            if (desc.enumerable orelse false) return false;
            if (desc.writable) |w| if (w and !vm.lengthWritable(o)) return false;
            if (desc.writable) |w| if (!w) try vm.setLengthWritable(o, false);
            return true;
        }
        const new_len_num = try vm.toUint32(desc.value.?);
        const number_len = try vm.toNumber(desc.value.?);
        if (@as(f64, @floatFromInt(new_len_num)) != number_len) return vm.throwRangeError("Invalid array length");
        if (desc.configurable orelse false) return false;
        if (desc.enumerable orelse false) return false;
        if (desc.isAccessor()) return false;
        const old_len = arrayLength(o);
        if (!vm.lengthWritable(o)) {
            if (new_len_num != old_len) return false;
            if (desc.writable orelse false) return false;
            return true;
        }
        if (new_len_num >= old_len) {
            if (o.elements) |e| {
                e.len = new_len_num;
            } else if (new_len_num > 0) {
                const e = try vm.objects.growElements(o, 1);
                e.len = new_len_num;
            }
        } else {
            // Delete from the end; stop at a non-configurable one.
            if (o.elements) |e| {
                var i: u32 = @min(old_len, e.cap);
                while (i > new_len_num) : (i -= 1) e.items()[i - 1] = Value.empty;
                e.len = new_len_num;
            }
            // Sparse index properties in the shape table.
            var keys: std.ArrayList(Key) = .empty;
            defer keys.deinit(vm.meta);
            try vm.objects.ownKeys(o, &keys);
            var i = keys.items.len;
            var stopped: ?u32 = null;
            while (i > 0) {
                i -= 1;
                const k = keys.items[i];
                if (k != .index or k.index < new_len_num) continue;
                if (o.elements != null and k.index < o.elements.?.cap) continue;
                if (!try vm.objects.delete(o, k)) {
                    stopped = k.index + 1;
                    break;
                }
            }
            if (stopped) |s| {
                if (o.elements) |e| e.len = s;
                if (desc.writable) |w| if (!w) try vm.setLengthWritable(o, false);
                return false;
            }
        }
        if (desc.writable) |w| if (!w) try vm.setLengthWritable(o, false);
        return true;
    }

    /// The array length's writability lives in a hidden symbol-keyed
    /// property (rare: only frozen arrays have it).
    pub fn lengthWritable(vm: *Vm, o: *Object) bool {
        const own = vm.objects.getOwn(o, .{ .symbol = vm.symbols.length_frozen }) catch return true;
        return own == null;
    }
    fn setLengthWritable(vm: *Vm, o: *Object, w: bool) Error!void {
        if (w) return;
        // The marker goes on even when the array is no longer extensible.
        _ = try vm.objects.defineOwnForce(o, .{ .symbol = vm.symbols.length_frozen }, Value.true_, .frozen);
    }

    /// CreateDataProperty (§7.3.5).
    pub fn createDataProperty(vm: *Vm, o: *Object, key: Key, v: Value) Error!bool {
        return vm.defineOwnProperty(o, key, .{ .value = v, .writable = true, .enumerable = true, .configurable = true }, false);
    }

    pub fn createDataPropertyOrThrow(vm: *Vm, o: *Object, key: Key, v: Value) Error!void {
        if (!try vm.createDataProperty(o, key, v)) return vm.throwTypeError("Cannot define property");
    }

    /// [[Delete]] (§10.1.10).
    pub fn deleteProperty(vm: *Vm, o: *Object, key: Key) Error!bool {
        switch (o.class) {
            .array => if (key == .atom and key.atom == vm.atoms.length) return false,
            .proxy => return realm.proxyDelete(vm, o, key),
            .namespace => return module.nsDelete(vm, o, key),
            .arguments => if (key == .index) return realm.argumentsDelete(vm, o, key.index),
            .typed_array => if (try realm.typedArrayNumericKey(vm, key)) |n| return !realm.typedArrayIsValidIndex(o, n),
            .string => if (key == .index) {
                const s = o.internal(PrimitiveData).value;
                if (key.index < asString(s).len) return false;
            },
            else => {},
        }
        return vm.objects.delete(o, key);
    }

    /// [[OwnPropertyKeys]] (§10.1.11).
    pub fn ownPropertyKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
        switch (o.class) {
            .proxy => return realm.proxyOwnKeys(vm, o, out),
            .namespace => return module.nsOwnKeys(vm, o, out),
            .typed_array => return realm.typedArrayOwnKeys(vm, o, out),
            else => {},
        }
        try vm.objects.ownKeys(o, out);
        // Private names are invisible to reflection.
        var w: usize = 0;
        for (out.items) |k| {
            if (k == .symbol and k.symbol.private) continue;
            out.items[w] = k;
            w += 1;
        }
        out.shrinkRetainingCapacity(w);
        if (o.class == .array) {
            // `length` after the indexes, before other strings.
            var i: usize = 0;
            while (i < out.items.len and out.items[i] == .index) i += 1;
            try out.insert(vm.meta, i, .{ .atom = vm.atoms.length });
        }
        if (o.class == .arguments) try realm.argumentsOwnKeys(vm, o, out);
    }

    /// [[GetPrototypeOf]].
    pub fn getPrototypeOf(vm: *Vm, o: *Object) Error!Value {
        if (o.class == .proxy) return realm.proxyGetPrototypeOf(vm, o);
        return o.shape.proto;
    }

    /// [[SetPrototypeOf]].
    pub fn setPrototypeOf(vm: *Vm, o: *Object, p: Value) Error!bool {
        if (o.class == .proxy) return realm.proxySetPrototypeOf(vm, o, p);
        if (o.class == .namespace) return p.isNull();
        if (o.class == .global and false) return false;
        if (o == vm.intrinsics.object_prototype and !p.isNull()) return false; // immutable prototype exotic
        // An array whose chain leaves the intrinsic one may meet indexed
        // properties or a proxy there: element stores take the slow path.
        if (o.class == .array or o == vm.intrinsics.array_prototype) {
            if (p.bits != vm.intrinsics.array_prototype.asValue().bits or o == vm.intrinsics.array_prototype) vm.proto_has_indexes = true;
        }
        return vm.objects.setProto(o, p);
    }

    /// [[PreventExtensions]].
    pub fn preventExtensions(vm: *Vm, o: *Object) Error!bool {
        if (o.class == .proxy) return realm.proxyPreventExtensions(vm, o);
        o.extensible = false;
        return true;
    }

    pub fn isExtensible(vm: *Vm, o: *Object) Error!bool {
        if (o.class == .proxy) return realm.proxyIsExtensible(vm, o);
        return o.extensible;
    }

    /// LengthOfArrayLike (§7.3.19).
    pub fn lengthOfArrayLike(vm: *Vm, o: *Object) Error!u64 {
        if (o.class == .array) return arrayLength(o);
        return vm.toLength(try vm.get(o, .{ .atom = vm.atoms.length }, o.asValue()));
    }

    /// CreateListFromArrayLike (§7.3.20).
    pub fn listFromArrayLike(vm: *Vm, v: Value, out: *std.ArrayList(Value)) Error!void {
        if (!v.isObject()) return vm.throwTypeError("CreateListFromArrayLike called on non-object");
        const o = asObject(v);
        const len = try vm.lengthOfArrayLike(o);
        if (len > 1 << 24) return vm.throwRangeError("Too many arguments");
        var i: u32 = 0;
        while (i < len) : (i += 1) try out.append(vm.meta, try vm.get(o, .{ .index = i }, v));
    }

    /// EnumerableOwnProperties keys: strings only, in order.
    pub fn enumerableOwnKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
        var keys: std.ArrayList(Key) = .empty;
        defer keys.deinit(vm.meta);
        try vm.ownPropertyKeys(o, &keys);
        for (keys.items) |k| {
            if (k == .symbol) continue;
            const own = (try vm.getOwnProperty(o, k)) orelse continue;
            if (own.attrs.enumerable) try out.append(vm.meta, k);
        }
    }

    /// CopyDataProperties (§7.3.25).
    pub fn copyDataProperties(vm: *Vm, target: *Object, source: Value, excluded: ?*Object) Error!void {
        if (source.isNullish()) return;
        const from = try vm.toObject(source);
        var keys: std.ArrayList(Key) = .empty;
        defer keys.deinit(vm.meta);
        try vm.ownPropertyKeys(from, &keys);
        for (keys.items) |k| {
            if (excluded) |ex| {
                var skip = false;
                const n = arrayLength(ex);
                var i: u32 = 0;
                while (i < n) : (i += 1) {
                    const kv = ex.elements.?.items()[i];
                    const ek = try vm.toPropertyKey(kv);
                    if (ek.eql(k)) {
                        skip = true;
                        break;
                    }
                }
                if (skip) continue;
            }
            const own = (try vm.getOwnProperty(from, k)) orelse continue;
            if (!own.attrs.enumerable) continue;
            const v = try vm.get(from, k, from.asValue());
            _ = try vm.createDataProperty(target, k, v);
        }
    }

    /// OrdinaryHasInstance (§7.3.22).
    pub fn ordinaryHasInstance(vm: *Vm, c: Value, o: Value) Error!bool {
        if (!vm.isCallable(c)) return false;
        const co = asObject(c);
        if (co.class == .bound_function) return vm.instanceOf(o, co.internal(BoundData).target.asValue());
        if (!o.isObject()) return false;
        const p = try vm.get(co, .{ .atom = vm.atoms.prototype }, c);
        if (!p.isObject()) return vm.throwTypeError("Function has non-object prototype in instanceof check");
        var cur = try vm.getPrototypeOf(asObject(o));
        while (cur.isObject()) {
            if (cur.eqlBits(p)) return true;
            cur = try vm.getPrototypeOf(asObject(cur));
        }
        return false;
    }

    /// InstanceofOperator (§13.10.2).
    pub fn instanceOf(vm: *Vm, v: Value, target: Value) Error!bool {
        if (!target.isObject()) return vm.throwTypeError("Right-hand side of 'instanceof' is not an object");
        const h = try vm.getMethod(target, .{ .symbol = vm.symbols.has_instance });
        if (!h.isUndefined()) return vm.toBoolean(try vm.call(h, target, &.{v}));
        if (!vm.isCallable(target)) return vm.throwTypeError("Right-hand side of 'instanceof' is not callable");
        return vm.ordinaryHasInstance(target, v);
    }

    /// GetPrototypeFromConstructor (§10.1.14).
    pub fn prototypeFromConstructor(vm: *Vm, ctor: Value, default: *Object) Error!*Object {
        if (!ctor.isObject()) return default;
        const p = try vm.get(asObject(ctor), .{ .atom = vm.atoms.prototype }, ctor);
        if (p.isObject()) return asObject(p);
        // A constructor from another realm would use its realm's
        // intrinsic; there is one realm.
        return default;
    }

    /// OrdinaryCreateFromConstructor.
    pub fn createFromConstructor(vm: *Vm, new_target: Value, default: *Object, class: Class, extra: usize) Error!*Object {
        const proto = try vm.prototypeFromConstructor(new_target, default);
        if (class == .array and proto != vm.intrinsics.array_prototype) vm.proto_has_indexes = true;
        return vm.objects.create(proto.asValue(), class, extra);
    }

    /// SpeciesConstructor (§7.3.23).
    pub fn speciesConstructor(vm: *Vm, o: *Object, default: Value) Error!Value {
        const c = try vm.get(o, .{ .atom = vm.atoms.constructor }, o.asValue());
        if (c.isUndefined()) return default;
        if (!c.isObject()) return vm.throwTypeError("constructor is not an object");
        const s = try vm.get(asObject(c), .{ .symbol = vm.symbols.species }, c);
        if (s.isNullish()) return default;
        if (vm.isConstructor(s)) return s;
        return vm.throwTypeError("species is not a constructor");
    }

    // ----------------------------------------------------- calling

    /// Call (§7.3.14).
    pub fn call(vm: *Vm, f: Value, this: Value, args: []const Value) Error!Value {
        if (!vm.isCallable(f)) return vm.throwTypeError("is not a function");
        try vm.tick();
        return interp.callValue(vm, f, this, args);
    }

    /// Construct (§7.3.15).
    pub fn construct(vm: *Vm, f: Value, args: []const Value, new_target: Value) Error!Value {
        if (!vm.isConstructor(f)) return vm.throwTypeError("is not a constructor");
        return interp.constructValue(vm, f, args, new_target);
    }

    /// Invoke (§7.3.15): call a method by key.
    pub fn invoke(vm: *Vm, v: Value, key: Key, args: []const Value) Error!Value {
        const f = try vm.getV(v, key);
        return vm.call(f, v, args);
    }

    /// Run the pending promise jobs (stage c).
    pub fn runJobs(vm: *Vm) Error!void {
        while (vm.jobs.items.len > 0) {
            const j = vm.jobs.orderedRemove(0);
            _ = vm.call(j.func, Value.undefined_, j.args[0..j.argc]) catch |e| switch (e) {
                error.Exception => {
                    // A job's exception is reported by the host; drop it.
                    vm.exception = Value.undefined_;
                },
                else => return e,
            };
        }
    }

    // ---------------------------------------------------- iteration

    pub const IteratorRecord = struct { iterator: Value, next: Value, done: bool = false };

    /// GetIterator (§7.4.2), sync.
    pub fn getIterator(vm: *Vm, v: Value) Error!IteratorRecord {
        const m = try vm.getMethod(v, .{ .symbol = vm.symbols.iterator });
        if (m.isUndefined()) return vm.throwTypeError("is not iterable");
        return vm.getIteratorFromMethod(v, m);
    }

    pub fn getIteratorFromMethod(vm: *Vm, v: Value, m: Value) Error!IteratorRecord {
        const it = try vm.call(m, v, &.{});
        if (!it.isObject()) return vm.throwTypeError("Result of the Symbol.iterator method is not an object");
        const next = try vm.get(asObject(it), .{ .atom = vm.atoms.next }, it);
        return .{ .iterator = it, .next = next };
    }

    /// IteratorStep + IteratorValue: the next value, or null when done.
    pub fn iteratorStepValue(vm: *Vm, rec: *IteratorRecord) Error!?Value {
        const r = vm.call(rec.next, rec.iterator, &.{}) catch |e| {
            rec.done = true;
            return e;
        };
        if (!r.isObject()) {
            rec.done = true;
            return vm.throwTypeError("Iterator result is not an object");
        }
        const done = vm.get(asObject(r), .{ .atom = vm.atoms.done }, r) catch |e| {
            rec.done = true;
            return e;
        };
        if (vm.toBoolean(done)) {
            rec.done = true;
            return null;
        }
        return vm.get(asObject(r), .{ .atom = vm.atoms.value }, r) catch |e| {
            rec.done = true;
            return e;
        };
    }

    /// IteratorClose (§7.4.6) on a normal completion.
    pub fn iteratorClose(vm: *Vm, rec: IteratorRecord) Error!void {
        const ret = try vm.getMethod(rec.iterator, .{ .atom = vm.atoms.@"return" });
        if (ret.isUndefined()) return;
        const r = try vm.call(ret, rec.iterator, &.{});
        if (!r.isObject()) return vm.throwTypeError("Iterator return result is not an object");
    }

    /// IteratorClose on a throw completion: errors from `return` are dropped.
    pub fn iteratorCloseThrow(vm: *Vm, rec: IteratorRecord) void {
        const saved = vm.exception;
        const ret = vm.getMethod(rec.iterator, .{ .atom = vm.atoms.@"return" }) catch {
            vm.exception = saved;
            return;
        };
        if (!ret.isUndefined()) _ = vm.call(ret, rec.iterator, &.{}) catch {};
        vm.exception = saved;
    }

    /// Collect an iterable into a list (IterableToList).
    pub fn iterableToList(vm: *Vm, v: Value, out: *std.ArrayList(Value)) Error!void {
        var rec = try vm.getIterator(v);
        while (try vm.iteratorStepValue(&rec)) |item| try out.append(vm.meta, item);
    }

    /// CreateIterResultObject.
    pub fn iterResult(vm: *Vm, v: Value, done: bool) Error!Value {
        const o = try vm.newObject();
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.value }, v, .default);
        _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.done }, Value.fromBool(done), .default);
        return o.asValue();
    }

    // --------------------------------------------------- arithmetic

    /// ApplyStringOrNumericBinaryOperator for `+` (§13.15.3).
    pub fn add(vm: *Vm, a: Value, b: Value) Error!Value {
        if (a.isInt() and b.isInt()) {
            const r = @as(i64, a.asInt()) + @as(i64, b.asInt());
            return Value.fromF64(@floatFromInt(r));
        }
        if (a.isNumber() and b.isNumber()) return Value.fromF64(a.asNumber() + b.asNumber());
        if (a.isString() and b.isString()) return strValue(try vm.concatStrings(asString(a), asString(b)));
        const pa = try vm.toPrimitive(a, .default);
        const pb = try vm.toPrimitive(b, .default);
        if (pa.isString() or pb.isString()) {
            const sa = try vm.toString(pa);
            const sb = try vm.toString(pb);
            return strValue(try vm.concatStrings(sa, sb));
        }
        const na = try vm.toNumeric(pa);
        const nb = try vm.toNumeric(pb);
        if (na.isBigInt() or nb.isBigInt()) return realm.bigintBinary(vm, .add, na, nb);
        return Value.fromF64(na.asNumber() + nb.asNumber());
    }

    pub const ArithOp = enum { add, sub, mul, div, mod, exp, shl, shr, ushr, band, bor, bxor };

    /// The other numeric binary operators.
    pub fn arith(vm: *Vm, op: ArithOp, a: Value, b: Value) Error!Value {
        if (a.isNumber() and b.isNumber()) return numberArith(op, a.asNumber(), b.asNumber());
        const na = try vm.toNumeric(a);
        const nb = try vm.toNumeric(b);
        if (na.isBigInt() or nb.isBigInt()) return realm.bigintBinary(vm, op, na, nb);
        return numberArith(op, na.asNumber(), nb.asNumber());
    }

    pub fn numberArith(op: ArithOp, x: f64, y: f64) Value {
        return switch (op) {
            .add => Value.fromF64(x + y),
            .sub => Value.fromF64(x - y),
            .mul => Value.fromF64(x * y),
            .div => Value.fromF64(x / y),
            .mod => Value.fromF64(jsRemainder(x, y)),
            .exp => Value.fromF64(jsPow(x, y)),
            .shl => Value.fromInt(f64ToInt32(x) << @as(u5, @truncate(@as(u32, @bitCast(f64ToInt32(y)))))),
            .shr => Value.fromInt(f64ToInt32(x) >> @as(u5, @truncate(@as(u32, @bitCast(f64ToInt32(y)))))),
            .ushr => Value.fromF64(@floatFromInt(@as(u32, @bitCast(f64ToInt32(x))) >> @as(u5, @truncate(@as(u32, @bitCast(f64ToInt32(y))))))),
            .band => Value.fromInt(f64ToInt32(x) & f64ToInt32(y)),
            .bor => Value.fromInt(f64ToInt32(x) | f64ToInt32(y)),
            .bxor => Value.fromInt(f64ToInt32(x) ^ f64ToInt32(y)),
        };
    }

    pub fn jsRemainder(x: f64, y: f64) f64 {
        if (std.math.isNan(x) or std.math.isNan(y) or std.math.isInf(x) or y == 0) return std.math.nan(f64);
        if (std.math.isInf(y) or x == 0) return x;
        const r = @rem(x, y);
        if (r == 0 and std.math.signbit(x)) return -0.0;
        return r;
    }

    /// Number::exponentiate (§6.1.6.1.3).
    pub fn jsPow(x: f64, y: f64) f64 {
        if (std.math.isNan(y)) return std.math.nan(f64);
        if (y == 0) return 1;
        if (std.math.isNan(x)) return std.math.nan(f64);
        if (std.math.isInf(y)) {
            const ax = @abs(x);
            if (ax == 1) return std.math.nan(f64);
            if (ax > 1) return if (y > 0) std.math.inf(f64) else 0;
            return if (y > 0) 0 else std.math.inf(f64);
        }
        return std.math.pow(f64, x, y);
    }

    /// Unary minus / ToNumeric negate.
    pub fn negate(vm: *Vm, v: Value) Error!Value {
        if (v.isInt()) {
            const i = v.asInt();
            if (i == 0) return Value.fromF64(-0.0);
            if (i == std.math.minInt(i32)) return Value.fromF64(2147483648.0);
            return Value.fromInt(-i);
        }
        if (v.isDouble()) return Value.fromF64(-v.asDouble());
        const n = try vm.toNumeric(v);
        if (n.isBigInt()) return realm.bigintNegate(vm, n);
        return Value.fromF64(-n.asNumber());
    }

    pub fn bitNot(vm: *Vm, v: Value) Error!Value {
        if (v.isInt()) return Value.fromInt(~v.asInt());
        const n = try vm.toNumeric(v);
        if (n.isBigInt()) return realm.bigintBitNot(vm, n);
        return Value.fromInt(~f64ToInt32(n.asNumber()));
    }

    // ----------------------------------------------------- functions

    /// The function data of a callable object (functions only).
    pub fn functionData(o: *Object) *FunctionData {
        return o.internal(FunctionData);
    }

    /// Function.prototype.toString's source text.
    pub fn functionSource(vm: *Vm, o: *Object) Error!Value {
        if (o.class == .function) {
            const f = o.internal(FunctionData);
            if (f.code) |code| {
                const d = code.data;
                if (d.source) |src| if (d.end > d.start and d.end <= src.text.len) {
                    return vm.str(src.text[d.start..d.end]);
                };
            }
            const name = try vm.get(o, .{ .atom = vm.atoms.name }, o.asValue());
            var buf: [256]u8 = undefined;
            var a = std.heap.FixedBufferAllocator.init(&buf);
            const n = if (name.isString()) vm.utf8(asString(name), a.allocator()) catch "" else "";
            var out: [300]u8 = undefined;
            const s = std.fmt.bufPrint(&out, "function {s}() {{ [native code] }}", .{n}) catch "function () { [native code] }";
            return vm.str(s);
        }
        return vm.str("function () { [native code] }");
    }
};

pub const whitespace_utf8 = [_]u8{ ' ', '\t', '\n', '\r', 0x0b, 0x0c };

/// StringNumericLiteral (§7.1.4.1): a trimmed string to a number, or
/// null when it is not one. Unicode whitespace beyond ASCII is trimmed
/// by the caller's flattening (BOM and NBSP handled here).
pub fn parseNumberLiteral(text_in: []const u8) ?f64 {
    var text = text_in;
    // Trim the non-ASCII whitespace a UTF-8 string may carry.
    const ws = [_][]const u8{ "\u{00a0}", "\u{feff}", "\u{2028}", "\u{2029}", "\u{1680}", "\u{2000}", "\u{2001}", "\u{2002}", "\u{2003}", "\u{2004}", "\u{2005}", "\u{2006}", "\u{2007}", "\u{2008}", "\u{2009}", "\u{200a}", "\u{202f}", "\u{205f}", "\u{3000}" };
    var trimmed = true;
    while (trimmed) {
        trimmed = false;
        text = std.mem.trim(u8, text, &whitespace_utf8);
        for (ws) |w| {
            if (std.mem.startsWith(u8, text, w)) {
                text = text[w.len..];
                trimmed = true;
            }
            if (std.mem.endsWith(u8, text, w)) {
                text = text[0 .. text.len - w.len];
                trimmed = true;
            }
        }
    }
    if (text.len == 0) return 0;
    if (text.len > 2 and text[0] == '0') {
        const radix: u8 = switch (text[1]) {
            'x', 'X' => 16,
            'o', 'O' => 8,
            'b', 'B' => 2,
            else => 0,
        };
        if (radix != 0) {
            var v: f64 = 0;
            for (text[2..]) |ch| {
                const d = std.fmt.charToDigit(ch, radix) catch return null;
                v = v * @as(f64, @floatFromInt(radix)) + @as(f64, @floatFromInt(d));
            }
            return v;
        }
    }
    var s = text;
    var neg = false;
    if (s[0] == '+' or s[0] == '-') {
        neg = s[0] == '-';
        s = s[1..];
    }
    if (std.mem.eql(u8, s, "Infinity")) return if (neg) -std.math.inf(f64) else std.math.inf(f64);
    // StrDecimalLiteral: digits [. digits] [e[+-]digits]
    var i: usize = 0;
    var digits: usize = 0;
    while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    if (i < s.len and s[i] == '.') {
        i += 1;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return null;
    if (i < s.len and (s[i] == 'e' or s[i] == 'E')) {
        i += 1;
        if (i < s.len and (s[i] == '+' or s[i] == '-')) i += 1;
        var ed: usize = 0;
        while (i < s.len and std.ascii.isDigit(s[i])) : (i += 1) ed += 1;
        if (ed == 0) return null;
    }
    if (i != s.len) return null;
    const v = std.fmt.parseFloat(f64, s) catch return null;
    return if (neg) -v else v;
}

test "vm: string numeric literals" {
    try std.testing.expectEqual(@as(f64, 0), parseNumberLiteral("").?);
    try std.testing.expectEqual(@as(f64, 42), parseNumberLiteral("  42 ").?);
    try std.testing.expectEqual(@as(f64, 255), parseNumberLiteral("0xff").?);
    try std.testing.expectEqual(@as(f64, -1.5e3), parseNumberLiteral("-1.5e3").?);
    try std.testing.expect(parseNumberLiteral("1x") == null);
    try std.testing.expect(parseNumberLiteral("-0x10") == null);
    try std.testing.expect(std.math.isInf(parseNumberLiteral("Infinity").?));
    try std.testing.expectEqual(@as(f64, 0.5), parseNumberLiteral(".5").?);
}
