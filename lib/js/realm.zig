//! The realm: intrinsic objects (§9.3), the global object, the atoms
//! and well-known symbols the engine names, and the exotic-object
//! hooks the VM dispatches to (arguments objects, for-in enumeration,
//! and the stage c/d classes — generators, proxies, BigInt, typed
//! arrays — whose entry points live here until their stage lands).
const std = @import("std");
const vmod = @import("vm.zig");
const object = @import("object.zig");
const bytecode = @import("bytecode.zig");
const heap = @import("heap.zig");
const interp = @import("interp.zig");
const builtins = @import("builtins.zig");
const Vm = vmod.Vm;
const Value = vmod.Value;
const Error = vmod.Error;
const Object = vmod.Object;
const String = vmod.String;
const Symbol = vmod.Symbol;
const Key = vmod.Key;
const Frame = vmod.Frame;
const asObject = Vm.asObject;
const asString = Vm.asString;
const strValue = Vm.strValue;

pub const Intrinsics = struct {
    object_prototype: *Object,
    function_prototype: *Object,
    array_prototype: *Object,
    string_prototype: *Object,
    number_prototype: *Object,
    boolean_prototype: *Object,
    symbol_prototype: *Object,
    bigint_prototype: *Object,
    error_prototype: *Object,
    type_error_prototype: *Object,
    range_error_prototype: *Object,
    reference_error_prototype: *Object,
    syntax_error_prototype: *Object,
    eval_error_prototype: *Object,
    uri_error_prototype: *Object,
    aggregate_error_prototype: *Object,
    iterator_prototype: *Object,
    array_iterator_prototype: *Object,
    string_iterator_prototype: *Object,
    for_in_iterator_prototype: *Object,
    generator_function_prototype: *Object,
    generator_prototype: *Object,
    async_function_prototype: *Object,
    async_generator_function_prototype: *Object,
    async_generator_prototype: *Object,
    async_iterator_prototype: *Object,
    async_from_sync_iterator_prototype: *Object,
    regexp_prototype: *Object,
    regexp_ctor: *Object,
    regexp_string_iterator_prototype: *Object,
    promise_prototype: *Object,
    map_prototype: *Object,
    map_iterator_prototype: *Object,
    set_prototype: *Object,
    set_iterator_prototype: *Object,
    weak_map_prototype: *Object,
    weak_set_prototype: *Object,
    weak_ref_prototype: *Object,
    finalization_registry_prototype: *Object,
    date_prototype: *Object,
    array_buffer_prototype: *Object,
    array_buffer_ctor: *Object,
    shared_array_buffer_prototype: *Object,
    shared_array_buffer_ctor: *Object,
    data_view_prototype: *Object,
    typed_array_ctor: *Object,
    typed_array_prototype: *Object,
    typed_array_ctors: [builtins.typedarray.kind_count]*Object,
    typed_array_protos: [builtins.typedarray.kind_count]*Object,
    iterator_ctor: *Object,
    iterator_helper_prototype: *Object,
    wrap_for_valid_iterator_prototype: *Object,
    promise_ctor: *Object,
    generator_function: *Object,
    async_generator_function: *Object,
    async_function: *Object,
    object_ctor: *Object,
    function_ctor: *Object,
    array_ctor: *Object,
    eval: *Object,
    throw_type_error: *Object,
    /// Array.prototype.values and %ArrayIteratorPrototype%.next, for the
    /// for-of fast path.
    array_proto_values: *Object,
    array_iterator_next: *Object,

    pub fn each(i: *Intrinsics, m: *heap.Marker) void {
        inline for (@typeInfo(Intrinsics).@"struct".fields) |f| {
            if (f.type == *Object) {
                m.markCell(@field(i, f.name).cell());
            } else if (f.type == [builtins.typedarray.kind_count]*Object) {
                for (@field(i, f.name)) |o| m.markCell(o.cell());
            }
        }
    }
};

pub const WellKnownSymbols = struct {
    iterator: *Symbol,
    async_iterator: *Symbol,
    has_instance: *Symbol,
    to_primitive: *Symbol,
    to_string_tag: *Symbol,
    species: *Symbol,
    is_concat_spreadable: *Symbol,
    unscopables: *Symbol,
    match: *Symbol,
    match_all: *Symbol,
    replace: *Symbol,
    search: *Symbol,
    split: *Symbol,
    dispose: *Symbol,
    async_dispose: *Symbol,
    /// Internal: marks an array whose length is not writable.
    length_frozen: *Symbol,

    pub fn each(s: *WellKnownSymbols, m: *heap.Marker) void {
        inline for (@typeInfo(WellKnownSymbols).@"struct".fields) |f| m.markCell(&@field(s, f.name).header);
    }
};

/// Atoms the engine names directly. Field names ending in `_` are
/// keywords; the rest spell the property name.
pub const Atoms = struct {
    length: *String,
    name: *String,
    prototype: *String,
    constructor: *String,
    message: *String,
    default: *String,
    number: *String,
    string: *String,
    toString: *String,
    valueOf: *String,
    next: *String,
    done: *String,
    value: *String,
    @"return": *String,
    throw: *String,
    undefined_: *String,
    null_: *String,
    true_: *String,
    false_: *String,
    empty: *String,
    object: *String,
    boolean: *String,
    symbol: *String,
    bigint: *String,
    function: *String,
    this_: *String,
    new_target: *String,
    home: *String,
    func: *String,
    raw: *String,
    get: *String,
    set: *String,
    writable: *String,
    enumerable: *String,
    configurable: *String,
    callee: *String,
    caller: *String,
    arguments: *String,
    cause: *String,
    errors: *String,
    lastIndex: *String,
    index: *String,
    input: *String,
    groups: *String,
    then: *String,
    toJSON: *String,
    description: *String,
    join: *String,
    flags: *String,
    source: *String,
    exec: *String,
    __proto__: *String,
    toISOString: *String,
    stack: *String,

    pub fn each(a: *Atoms, m: *heap.Marker) void {
        inline for (@typeInfo(Atoms).@"struct".fields) |f| m.markCell(@field(a, f.name).cell());
    }
};

fn symbolDescription(comptime field: []const u8) []const u8 {
    if (std.mem.eql(u8, field, "length_frozen")) return "";
    comptime var out: []const u8 = "Symbol.";
    comptime var up = false;
    inline for (field) |ch| {
        if (ch == '_') {
            up = true;
        } else {
            out = out ++ [_]u8{if (up) std.ascii.toUpper(ch) else ch};
            up = false;
        }
    }
    return out;
}

/// The `with` environment's scope info (no names; the object is `extra`).
pub var with_scope_info: bytecode.ScopeInfo = .{ .names = &.{}, .consts = &.{}, .lexical = &.{}, .is_with = true };

/// Extra tracing for stage c/d classes with off-object state.
pub fn traceExtra(o: *Object, m: *heap.Marker) void {
    builtins.traceExtra(o, m);
}

pub fn finalizeExtra(vm: *Vm, o: *Object) void {
    builtins.finalizeExtra(vm, o);
}

/// Build the realm: atoms, symbols, intrinsics, the global object.
pub fn create(vm: *Vm) Error!void {
    // Atoms.
    inline for (@typeInfo(Atoms).@"struct".fields) |f| {
        const text: []const u8 = comptime blk: {
            if (std.mem.eql(u8, f.name, "undefined_")) break :blk "undefined";
            if (std.mem.eql(u8, f.name, "null_")) break :blk "null";
            if (std.mem.eql(u8, f.name, "true_")) break :blk "true";
            if (std.mem.eql(u8, f.name, "false_")) break :blk "false";
            if (std.mem.eql(u8, f.name, "empty")) break :blk "";
            if (std.mem.eql(u8, f.name, "this_")) break :blk "this";
            if (std.mem.eql(u8, f.name, "new_target")) break :blk "new.target";
            if (std.mem.eql(u8, f.name, "home")) break :blk ".home";
            if (std.mem.eql(u8, f.name, "func")) break :blk ".func";
            break :blk f.name;
        };
        @field(vm.atoms, f.name) = try vm.strings.atom(text);
    }
    // Well-known symbols: Symbol.<camelCase of the field name>.
    inline for (@typeInfo(WellKnownSymbols).@"struct".fields) |f| {
        const desc = comptime symbolDescription(f.name);
        const s = try vm.newSymbol(if (desc.len == 0) null else try vm.strings.atom(desc));
        if (desc.len == 0) s.private = true;
        @field(vm.symbols, f.name) = s;
    }
}

/// Trace one realm's intrinsics.
pub fn traceIntrinsics(i: *Intrinsics, m: *heap.Marker) void {
    i.each(m);
}

/// Trace what every realm shares: the atoms and the well-known symbols.
pub fn traceShared(vm: *Vm, m: *heap.Marker) void {
    vm.symbols.each(m);
    vm.atoms.each(m);
}

/// A realm's own state: the intrinsics and the global object, built into
/// the VM's live fields (the current realm's), then the standard
/// library installed on them.
pub fn createIntrinsics(vm: *Vm) Error!void {
    // The prototypes first (everything hangs off them).
    const objp = try vm.objects.create(Value.null_, .ordinary, 0);
    vm.intrinsics.object_prototype = objp;
    const fnp = try vm.objects.create(objp.asValue(), .function, @sizeOf(vmod.FunctionData));
    fnp.internal(vmod.FunctionData).* = .{ .realm = vm.realm, .code = null, .env = null, .native = builtins.function.prototypeCall, .home_object = Value.undefined_, .fields = Value.undefined_, .data = Value.undefined_, .this_mode = .strict, .is_class_constructor = false, .is_constructor = false, .derived = false };
    vm.intrinsics.function_prototype = fnp;
    inline for (@typeInfo(Intrinsics).@"struct".fields) |f| {
        if (!std.mem.eql(u8, f.name, "object_prototype") and !std.mem.eql(u8, f.name, "function_prototype")) {
            if (f.type == *Object) {
                @field(vm.intrinsics, f.name) = objp; // placeholders until installed
            } else {
                @field(vm.intrinsics, f.name) = @splat(objp);
            }
        }
    }
    const mk = struct {
        fn proto(v: *Vm, parent: *Object) Error!*Object {
            return v.objects.create(parent.asValue(), .ordinary, 0);
        }
    };
    const i = &vm.intrinsics;
    i.array_prototype = try vm.objects.create(objp.asValue(), .array, 0);
    i.string_prototype = try vm.objects.create(objp.asValue(), .string, @sizeOf(vmod.PrimitiveData));
    i.string_prototype.internal(vmod.PrimitiveData).value = strValue(vm.atoms.empty);
    _ = try vm.objects.defineOwn(i.string_prototype, .{ .atom = vm.atoms.length }, Value.fromInt(0), .frozen);
    i.number_prototype = try vm.objects.create(objp.asValue(), .number, @sizeOf(vmod.PrimitiveData));
    i.number_prototype.internal(vmod.PrimitiveData).value = Value.fromInt(0);
    i.boolean_prototype = try vm.objects.create(objp.asValue(), .boolean, @sizeOf(vmod.PrimitiveData));
    i.boolean_prototype.internal(vmod.PrimitiveData).value = Value.false_;
    i.symbol_prototype = try mk.proto(vm, objp);
    i.bigint_prototype = try mk.proto(vm, objp);
    i.error_prototype = try mk.proto(vm, objp);
    i.type_error_prototype = try mk.proto(vm, i.error_prototype);
    i.range_error_prototype = try mk.proto(vm, i.error_prototype);
    i.reference_error_prototype = try mk.proto(vm, i.error_prototype);
    i.syntax_error_prototype = try mk.proto(vm, i.error_prototype);
    i.eval_error_prototype = try mk.proto(vm, i.error_prototype);
    i.uri_error_prototype = try mk.proto(vm, i.error_prototype);
    i.aggregate_error_prototype = try mk.proto(vm, i.error_prototype);
    i.iterator_prototype = try mk.proto(vm, objp);
    i.array_iterator_prototype = try mk.proto(vm, i.iterator_prototype);
    i.string_iterator_prototype = try mk.proto(vm, i.iterator_prototype);
    i.for_in_iterator_prototype = try mk.proto(vm, i.iterator_prototype);
    i.generator_function_prototype = try mk.proto(vm, fnp);
    i.generator_prototype = try mk.proto(vm, i.iterator_prototype);
    i.async_function_prototype = try mk.proto(vm, fnp);
    i.async_generator_function_prototype = try mk.proto(vm, fnp);
    i.async_iterator_prototype = try mk.proto(vm, objp);
    i.async_from_sync_iterator_prototype = try mk.proto(vm, i.async_iterator_prototype);
    i.async_generator_prototype = try mk.proto(vm, i.async_iterator_prototype);
    i.regexp_prototype = try mk.proto(vm, objp);
    i.promise_prototype = try mk.proto(vm, objp);
    i.map_prototype = try mk.proto(vm, objp);
    i.map_iterator_prototype = try mk.proto(vm, i.iterator_prototype);
    i.set_prototype = try mk.proto(vm, objp);
    i.set_iterator_prototype = try mk.proto(vm, i.iterator_prototype);
    i.weak_map_prototype = try mk.proto(vm, objp);
    i.weak_set_prototype = try mk.proto(vm, objp);
    i.weak_ref_prototype = try mk.proto(vm, objp);
    i.finalization_registry_prototype = try mk.proto(vm, objp);
    i.date_prototype = try mk.proto(vm, objp);
    // The global object.
    vm.global = try vm.objects.create(objp.asValue(), .global, 0);
    // %ThrowTypeError%.
    i.throw_type_error = try vm.newNative("", 0, builtins.function.throwTypeError, Value.undefined_);
    i.throw_type_error.extensible = false;
    // Everything else.
    try builtins.install(vm);
}

// -------------------------------------------------------- arguments

/// CreateUnmappedArgumentsObject / CreateMappedArgumentsObject
/// (§10.4.4.6–7). A mapped object's indexed properties alias the
/// parameters through the function's environment slots.
pub fn createArgumentsObject(vm: *Vm, frame: *Frame) Error!Value {
    const code = frame.code.data;
    const o = try vm.objects.create(vm.intrinsics.object_prototype.asValue(), .arguments, @sizeOf(vmod.ArgumentsData));
    const ad = o.internal(vmod.ArgumentsData);
    ad.* = .{ .env = null, .code = null, .mapped = 0 };
    const args = vm.stack[frame.args_base .. frame.args_base + frame.argc];
    for (args, 0..) |a, i| _ = try vm.objects.defineOwn(o, .{ .index = @intCast(i) }, a, .default);
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(args.len)), .hidden);
    _ = try vm.objects.defineOwn(o, .{ .symbol = vm.symbols.iterator }, vm.intrinsics.array_proto_values.asValue(), .hidden);
    if (code.param_slots.len == 0) {
        if (code.strict or true) {
            // Unmapped: strict functions and non-simple parameters. A
            // sloppy function whose arguments object is unmapped (no
            // parameters) still exposes callee.
            if (code.strict) {
                try vm.defineAccessor(o, .{ .atom = vm.atoms.callee }, vm.intrinsics.throw_type_error, vm.intrinsics.throw_type_error, .{ .enumerable = false, .configurable = false });
            } else {
                _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.callee }, if (frame.func) |f| f.asValue() else Value.undefined_, .hidden);
            }
        }
        return o.asValue();
    }
    ad.env = frame.env;
    ad.code = frame.code;
    const n = @min(args.len, code.param_slots.len, 64);
    var i: usize = 0;
    while (i < n) : (i += 1) if (code.param_slots[i] != bytecode.CodeData.unmapped) {
        ad.mapped |= @as(u64, 1) << @intCast(i);
    };
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.callee }, if (frame.func) |f| f.asValue() else Value.undefined_, .hidden);
    return o.asValue();
}

fn isMapped(o: *Object, index: u32) bool {
    const ad = o.internal(vmod.ArgumentsData);
    return index < 64 and (ad.mapped >> @intCast(index)) & 1 == 1;
}

fn mappedSlot(o: *Object, index: u32) *Value {
    const ad = o.internal(vmod.ArgumentsData);
    const slot = ad.code.?.data.param_slots[index];
    return &ad.env.?.slots()[slot];
}

fn unmap(o: *Object, index: u32) void {
    const ad = o.internal(vmod.ArgumentsData);
    if (index < 64) ad.mapped &= ~(@as(u64, 1) << @intCast(index));
}

/// [[GetOwnProperty]] of a mapped index: the ordinary property with the
/// parameter's current value.
pub fn argumentsGetOwn(vm: *Vm, o: *Object, index: u32) Error!?object.Objects.Own {
    if (!isMapped(o, index)) return null;
    var own = (try vm.objects.getOwn(o, .{ .index = index })) orelse return null;
    own.val = mappedSlot(o, index).*;
    return own;
}

/// [[DefineOwnProperty]] (§10.4.4.2).
pub fn argumentsDefineOwn(vm: *Vm, o: *Object, index: u32, desc_in: Vm.Descriptor) Error!bool {
    var desc = desc_in;
    const mapped = isMapped(o, index);
    if (mapped and desc.isData() and desc.value == null and desc.writable != null and !desc.writable.?) {
        // Keep the current parameter value when the property freezes.
        desc.value = mappedSlot(o, index).*;
    }
    if (!try vm.ordinaryDefineOwnProperty(o, .{ .index = index }, desc)) return false;
    if (mapped) {
        if (desc.isAccessor()) {
            unmap(o, index);
        } else {
            if (desc.value) |v| {
                const slot = mappedSlot(o, index);
                vm.heap.writeBarrier(o.internal(vmod.ArgumentsData).env.?.cell(), v);
                slot.* = v;
            }
            if (desc.writable != null and !desc.writable.?) unmap(o, index);
        }
    }
    return true;
}

pub fn argumentsDelete(vm: *Vm, o: *Object, index: u32) Error!bool {
    const ok = try vm.objects.delete(o, .{ .index = index });
    if (ok) unmap(o, index);
    return ok;
}

pub fn argumentsOwnKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
    _ = vm;
    _ = o;
    _ = out;
}

// ----------------------------------------------------------- for-in

/// The for-in enumerator: the enumerable string keys of the chain,
/// collected up front (deleted ones are skipped when visited).
pub fn createForInIterator(vm: *Vm, v: Value) Error!Value {
    const keys = try vm.newArray(0);
    const o = try vm.objects.create(vm.intrinsics.for_in_iterator_prototype.asValue(), .iterator, @sizeOf(vmod.ForInData));
    o.internal(vmod.ForInData).* = .{ .keys = keys.asValue(), .target = Value.undefined_, .index = 0 };
    if (v.isNullish()) return o.asValue();
    const target = try vm.toObject(v);
    o.internal(vmod.ForInData).target = target.asValue();
    var seen: std.ArrayList(*String) = .empty;
    defer seen.deinit(vm.meta);
    var cur: ?*Object = target;
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    while (cur) |c| {
        list.clearRetainingCapacity();
        try vm.ownPropertyKeys(c, &list);
        for (list.items) |k| {
            if (k == .symbol) continue;
            const s = try vm.keyToString(k);
            var dup = false;
            for (seen.items) |x| if (x == s or vm.stringEquals(x, s)) {
                dup = true;
                break;
            };
            if (dup) continue;
            try seen.append(vm.meta, s);
            const own = (try vm.getOwnProperty(c, k)) orelse continue;
            if (!own.attrs.enumerable) continue;
            try vm.arrayPush(keys, strValue(s));
        }
        const p = try vm.getPrototypeOf(c);
        cur = if (p.isObject()) asObject(p) else null;
    }
    return o.asValue();
}

pub fn forInNext(vm: *Vm, v: Value) Error!Value {
    const o = asObject(v);
    const d = o.internal(vmod.ForInData);
    if (d.target.isUndefined()) return Value.empty;
    const keys = asObject(d.keys);
    const n = Vm.arrayLength(keys);
    while (d.index < n) {
        const k = keys.elements.?.items()[d.index];
        d.index += 1;
        // Skip a key deleted since collection.
        const key = try vm.keyFromString(asString(k));
        if (try vm.hasProperty(asObject(d.target), key)) return k;
    }
    return Value.empty;
}

// --------------------------------------------------------- iterators

/// The for-of fast path: `it` is an intrinsic array iterator whose
/// `next` is the intrinsic and whose target is a plain array. Returns
/// null when the slow path must run.
pub fn arrayIteratorFast(vm: *Vm, it: Value, next: Value) ?Value {
    if (!it.isObject() or !next.isObject()) return null;
    if (asObject(next) != vm.intrinsics.array_iterator_next) return null;
    const o = asObject(it);
    if (o.class != .iterator or o.shape.proto.bits != vm.intrinsics.array_iterator_prototype.asValue().bits) return null;
    const d = o.internal(vmod.ArrayIteratorData);
    if (d.kind != .values) return null;
    if (!d.target.isObject()) return Value.empty;
    const arr = asObject(d.target);
    if (arr.class != .array or arr.sparse_indexes or vm.objects.proto_has_indexes) return null;
    const len = Vm.arrayLength(arr);
    if (d.index >= len) {
        d.target = Value.undefined_;
        return Value.empty;
    }
    const e = arr.elements orelse return null;
    if (d.index >= e.cap) return null;
    const v = e.items()[d.index];
    if (v.isEmpty()) return null; // a hole: the prototype may have it
    d.index += 1;
    return v;
}

pub fn getAsyncIterator(vm: *Vm, v: Value) Error!Vm.IteratorRecord {
    return builtins.generator.getAsyncIterator(vm, v);
}

pub fn callGenerator(vm: *Vm, f: *Object, this: Value, args: []const Value) Error!Value {
    return builtins.generator.call(vm, f, this, args);
}

pub fn createGeneratorObject(vm: *Vm, f: *Object) Error!*Object {
    return builtins.generator.createGeneratorObject(vm, f);
}

pub fn promiseResolve(vm: *Vm, v: Value) Error!Value {
    return builtins.promise.promiseResolve(vm, vm.intrinsics.promise_ctor.asValue(), v);
}

pub fn awaitValue(vm: *Vm, co: *Object, p: Value) Error!void {
    return builtins.generator.awaitValue(vm, co, p);
}

/// SetIntegrityLevel frozen for a literal-built array.
pub fn freezeArray(vm: *Vm, arr: *Object) Error!void {
    try builtins.object.setIntegrityLevel(vm, arr, true);
}

// ------------------------------------------------------ stage c/d hooks

pub fn newRegExp(vm: *Vm, pattern: Value, flags: Value) Error!Value {
    return builtins.regexp.create(vm, pattern, flags);
}

pub fn bigintFromLiteral(vm: *Vm, s: *String) Error!Value {
    return builtins.bigint.fromLiteral(vm, s);
}
pub fn bigintFromI64(vm: *Vm, v: i64) Error!Value {
    return builtins.bigint.fromI64(vm, v);
}
pub fn bigintIsNonZero(v: Value) bool {
    return builtins.bigint.isNonZero(v);
}
pub fn bigintToString(vm: *Vm, v: Value, radix: u8) Error!*String {
    return builtins.bigint.toString(vm, v, radix);
}
pub fn bigintEquals(a: Value, b: Value) bool {
    return builtins.bigint.equals(a, b);
}
pub fn bigintLooseEqualsString(vm: *Vm, a: Value, s: *String) Error!bool {
    return builtins.bigint.looseEqualsString(vm, a, s);
}
pub fn bigintEqualsNumber(a: Value, d: f64) bool {
    return builtins.bigint.equalsNumber(a, d);
}
pub fn stringToBigInt(vm: *Vm, s: *String) Error!?Value {
    return builtins.bigint.fromString(vm, s);
}
pub fn bigintCompare(a: Value, b: Value) std.math.Order {
    return builtins.bigint.compare(a, b);
}
pub fn bigintCompareNumber(a: Value, d: f64) std.math.Order {
    return builtins.bigint.compareNumber(a, d);
}
pub fn bigintBinary(vm: *Vm, op: Vm.ArithOp, a: Value, b: Value) Error!Value {
    return builtins.bigint.binary(vm, op, a, b);
}
pub fn bigintNegate(vm: *Vm, a: Value) Error!Value {
    return builtins.bigint.negate(vm, a);
}
pub fn bigintBitNot(vm: *Vm, a: Value) Error!Value {
    return builtins.bigint.bitNot(vm, a);
}

pub fn proxyTypeOf(vm: *Vm, o: *Object) *String {
    return if (proxyIsCallable(vm, o)) vm.atoms.function else vm.atoms.object;
}
pub fn proxyIsCallable(vm: *Vm, o: *Object) bool {
    return builtins.proxy.isCallable(vm, o);
}
pub fn proxyIsConstructor(vm: *Vm, o: *Object) bool {
    return builtins.proxy.isConstructor(vm, o);
}
pub fn proxyIsArray(vm: *Vm, o: *Object) Error!bool {
    return builtins.proxy.isArray(vm, o);
}
pub fn proxyGetOwnProperty(vm: *Vm, o: *Object, key: Key) Error!?object.Objects.Own {
    return builtins.proxy.getOwnProperty(vm, o, key);
}
pub fn proxyGet(vm: *Vm, o: *Object, key: Key, receiver: Value) Error!Value {
    return builtins.proxy.get(vm, o, key, receiver);
}
pub fn proxySet(vm: *Vm, o: *Object, key: Key, v: Value, receiver: Value) Error!bool {
    return builtins.proxy.set(vm, o, key, v, receiver);
}
pub fn proxyHas(vm: *Vm, o: *Object, key: Key) Error!bool {
    return builtins.proxy.has(vm, o, key);
}
pub fn proxyDefineOwnProperty(vm: *Vm, o: *Object, key: Key, desc: Vm.Descriptor) Error!bool {
    return builtins.proxy.defineOwnProperty(vm, o, key, desc);
}
pub fn proxyDelete(vm: *Vm, o: *Object, key: Key) Error!bool {
    return builtins.proxy.delete(vm, o, key);
}
pub fn proxyOwnKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
    return builtins.proxy.ownKeys(vm, o, out);
}
pub fn proxyGetPrototypeOf(vm: *Vm, o: *Object) Error!Value {
    return builtins.proxy.getPrototypeOf(vm, o);
}
pub fn proxySetPrototypeOf(vm: *Vm, o: *Object, p: Value) Error!bool {
    return builtins.proxy.setPrototypeOf(vm, o, p);
}
pub fn proxyPreventExtensions(vm: *Vm, o: *Object) Error!bool {
    return builtins.proxy.preventExtensions(vm, o);
}
pub fn proxyIsExtensible(vm: *Vm, o: *Object) Error!bool {
    return builtins.proxy.isExtensible(vm, o);
}
pub fn proxyCall(vm: *Vm, o: *Object, this: Value, args: []const Value) Error!Value {
    return builtins.proxy.call(vm, o, this, args);
}
pub fn proxyConstruct(vm: *Vm, o: *Object, args: []const Value, new_target: Value) Error!Value {
    return builtins.proxy.construct(vm, o, args, new_target);
}

pub fn typedArrayNumericKey(vm: *Vm, key: Key) Error!?f64 {
    return builtins.typedarray.numericKey(vm, key);
}
pub fn typedArrayGetOwn(vm: *Vm, o: *Object, index: f64) Error!?object.Objects.Own {
    return builtins.typedarray.getOwn(vm, o, index);
}
pub fn typedArrayGetElement(vm: *Vm, o: *Object, index: f64) Error!Value {
    return builtins.typedarray.getElement(vm, o, index);
}
pub fn typedArraySetNumeric(vm: *Vm, o: *Object, index: f64, v: Value, receiver: Value, result: *bool) Error!bool {
    return builtins.typedarray.setNumeric(vm, o, index, v, receiver, result);
}
pub fn typedArrayIsValidIndex(o: *Object, index: f64) bool {
    return builtins.typedarray.isValidIndex(builtins.typedarray.data(o), index);
}
pub fn typedArrayDefineOwn(vm: *Vm, o: *Object, index: f64, desc: Vm.Descriptor) Error!bool {
    return builtins.typedarray.defineOwn(vm, o, index, desc);
}
pub fn typedArrayOwnKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
    return builtins.typedarray.ownKeys(vm, o, out);
}
pub fn typedArrayIterLength(vm: *Vm, o: *Object) Error!u64 {
    return builtins.typedarray.iterLength(vm, o);
}
