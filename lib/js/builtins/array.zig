//! Array (§23.1): the constructor, from/isArray/of, and the prototype's
//! methods over generic array-likes (with fast paths for dense arrays
//! whose prototype chain is untouched).
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const iterator = @import("iterator.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const Key = b.Key;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.array_prototype;
    const ctor = try b.installConstructor(vm, "Array", 1, construct, proto);
    vm.intrinsics.array_ctor = ctor;
    _ = try vm.defineNative(ctor, "from", 1, from);
    _ = try vm.defineNative(ctor, "isArray", 1, isArray);
    _ = try vm.defineNative(ctor, "of", 0, of);
    const species = try vm.newNative("get [Symbol.species]", 0, speciesGetter, Value.undefined_);
    try vm.defineAccessor(ctor, .{ .symbol = vm.symbols.species }, species, null, .{ .enumerable = false, .configurable = true });

    _ = try vm.defineNative(proto, "at", 1, at);
    _ = try vm.defineNative(proto, "concat", 1, concat);
    _ = try vm.defineNative(proto, "copyWithin", 2, copyWithin);
    _ = try vm.defineNative(proto, "entries", 0, entries);
    _ = try vm.defineNative(proto, "every", 1, every);
    _ = try vm.defineNative(proto, "fill", 1, fill);
    _ = try vm.defineNative(proto, "filter", 1, filter);
    _ = try vm.defineNative(proto, "find", 1, find);
    _ = try vm.defineNative(proto, "findIndex", 1, findIndex);
    _ = try vm.defineNative(proto, "findLast", 1, findLast);
    _ = try vm.defineNative(proto, "findLastIndex", 1, findLastIndex);
    _ = try vm.defineNative(proto, "flat", 0, flat);
    _ = try vm.defineNative(proto, "flatMap", 1, flatMap);
    _ = try vm.defineNative(proto, "forEach", 1, forEach);
    _ = try vm.defineNative(proto, "includes", 1, includes);
    _ = try vm.defineNative(proto, "indexOf", 1, indexOf);
    _ = try vm.defineNative(proto, "join", 1, join);
    _ = try vm.defineNative(proto, "keys", 0, keys);
    _ = try vm.defineNative(proto, "lastIndexOf", 1, lastIndexOf);
    _ = try vm.defineNative(proto, "map", 1, map);
    _ = try vm.defineNative(proto, "pop", 0, pop);
    _ = try vm.defineNative(proto, "push", 1, push);
    _ = try vm.defineNative(proto, "reduce", 1, reduce);
    _ = try vm.defineNative(proto, "reduceRight", 1, reduceRight);
    _ = try vm.defineNative(proto, "reverse", 0, reverse);
    _ = try vm.defineNative(proto, "shift", 0, shift);
    _ = try vm.defineNative(proto, "slice", 2, slice);
    _ = try vm.defineNative(proto, "some", 1, some);
    _ = try vm.defineNative(proto, "sort", 1, sort);
    _ = try vm.defineNative(proto, "splice", 2, splice);
    _ = try vm.defineNative(proto, "toLocaleString", 0, toLocaleString);
    _ = try vm.defineNative(proto, "toReversed", 0, toReversed);
    _ = try vm.defineNative(proto, "toSorted", 1, toSorted);
    _ = try vm.defineNative(proto, "toSpliced", 2, toSpliced);
    _ = try vm.defineNative(proto, "toString", 0, toString);
    _ = try vm.defineNative(proto, "unshift", 1, unshift);
    const values_fn = try vm.defineNative(proto, "values", 0, values);
    _ = try vm.defineNative(proto, "with", 2, with);
    vm.intrinsics.array_proto_values = values_fn;
    _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.iterator }, values_fn.asValue(), .hidden);
    // @@unscopables
    const uns = try vm.newObjectWithProto(Value.null_);
    for ([_][]const u8{ "at", "copyWithin", "entries", "fill", "find", "findIndex", "findLast", "findLastIndex", "flat", "flatMap", "includes", "keys", "toReversed", "toSorted", "toSpliced", "values" }) |n| try vm.defineValue(uns, n, Value.true_, .default);
    _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.unscopables }, uns.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    const nt = if (new_target.isUndefined()) vm.intrinsics.array_ctor.asValue() else new_target;
    const proto = try vm.prototypeFromConstructor(nt, vm.intrinsics.array_prototype);
    const arr = try vm.objects.create(proto.asValue(), .array, 0);
    if (args.len == 1) {
        const len = args[0];
        if (!len.isNumber()) {
            try vm.arrayPush(arr, len);
            return arr.asValue();
        }
        const n = try vm.toUint32(len);
        if (@as(f64, @floatFromInt(n)) != len.asNumber()) return vm.throwRangeError("Invalid array length");
        try setLength(vm, arr, n);
        return arr.asValue();
    }
    for (args) |a| try vm.arrayPush(arr, a);
    return arr.asValue();
}

/// A dense array with `len` (holes) for a plain Array constructor.
fn setLength(vm: *Vm, arr: *Object, n: u32) Error!void {
    if (n == 0) return;
    const e = try vm.objects.growElements(arr, @min(n, 1 << 20));
    e.len = n;
}

fn isArray(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromBool(try vm.isArray(arg(args, 0)));
}

fn of(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const a = if (vm.isConstructor(this)) try vm.construct(this, &.{Value.fromInt(@intCast(args.len))}, this) else (try vm.newArray(0)).asValue();
    const o = asObject(a);
    for (args, 0..) |v, i| try vm.createDataPropertyOrThrow(o, .{ .index = @intCast(i) }, v);
    try vm.setV(a, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(args.len)), true);
    return a;
}

fn from(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const items = arg(args, 0);
    const mapfn = arg(args, 1);
    const this_arg = arg(args, 2);
    if (!mapfn.isUndefined() and !vm.isCallable(mapfn)) return vm.throwTypeError("Array.from: mapper is not a function");
    const using = try vm.getMethod(items, .{ .symbol = vm.symbols.iterator });
    if (!using.isUndefined()) {
        const a = if (vm.isConstructor(this)) try vm.construct(this, &.{}, this) else (try vm.newArray(0)).asValue();
        const o = asObject(a);
        var rec = try vm.getIteratorFromMethod(items, using);
        var k: u32 = 0;
        while (try vm.iteratorStepValue(&rec)) |v| : (k += 1) {
            var mapped = v;
            if (!mapfn.isUndefined()) mapped = vm.call(mapfn, this_arg, &.{ v, Value.fromInt(@intCast(k)) }) catch |e| {
                vm.iteratorCloseThrow(rec);
                return e;
            };
            vm.createDataPropertyOrThrow(o, .{ .index = k }, mapped) catch |e| {
                vm.iteratorCloseThrow(rec);
                return e;
            };
        }
        try vm.setV(a, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(k)), true);
        return a;
    }
    const src = try vm.toObject(items);
    const len = try vm.lengthOfArrayLike(src);
    const a = if (vm.isConstructor(this)) try vm.construct(this, &.{Value.fromF64(@floatFromInt(len))}, this) else (try vm.newArray(0)).asValue();
    const o = asObject(a);
    var k: u32 = 0;
    while (k < len) : (k += 1) {
        const v = try vm.get(src, .{ .index = k }, src.asValue());
        const mapped = if (mapfn.isUndefined()) v else try vm.call(mapfn, this_arg, &.{ v, Value.fromInt(@intCast(k)) });
        try vm.createDataPropertyOrThrow(o, .{ .index = k }, mapped);
    }
    try vm.setV(a, .{ .atom = vm.atoms.length }, Value.fromF64(@floatFromInt(len)), true);
    return a;
}

// --------------------------------------------------------- helpers

fn idx(i: u64) Key {
    return .{ .index = @intCast(i) };
}

/// Get by 64-bit index (beyond u32 as a string key).
fn getAt(vm: *Vm, o: *Object, i: u64) Error!Value {
    try vm.tick();
    if (i < 0xFFFF_FFFF) return vm.get(o, idx(i), o.asValue());
    return vm.get(o, try vm.keyFromString(try vm.toString(Value.fromF64(@floatFromInt(i)))), o.asValue());
}
fn setAt(vm: *Vm, o: *Object, i: u64, v: Value) Error!void {
    const k: Key = if (i < 0xFFFF_FFFF) idx(i) else try vm.keyFromString(try vm.toString(Value.fromF64(@floatFromInt(i))));
    if (!try vm.set(o, k, v, o.asValue())) return vm.throwTypeError("Cannot assign to read only property");
}
fn hasAt(vm: *Vm, o: *Object, i: u64) Error!bool {
    try vm.tick();
    if (i < 0xFFFF_FFFF) return vm.hasProperty(o, idx(i));
    return vm.hasProperty(o, try vm.keyFromString(try vm.toString(Value.fromF64(@floatFromInt(i)))));
}
fn deleteAt(vm: *Vm, o: *Object, i: u64) Error!void {
    try vm.tick();
    const k: Key = if (i < 0xFFFF_FFFF) idx(i) else try vm.keyFromString(try vm.toString(Value.fromF64(@floatFromInt(i))));
    if (!try vm.deleteProperty(o, k)) return vm.throwTypeError("Cannot delete property");
}
fn setLen(vm: *Vm, o: *Object, len: u64) Error!void {
    if (!try vm.set(o, .{ .atom = vm.atoms.length }, Value.fromF64(@floatFromInt(len)), o.asValue())) return vm.throwTypeError("Cannot assign to read only property 'length'");
}

/// ArraySpeciesCreate (§10.4.2.3).
fn speciesCreate(vm: *Vm, original: *Object, len: u64) Error!*Object {
    if (!try vm.isArray(original.asValue())) return vm.newArrayLen(len);
    var c = try vm.get(original, .{ .atom = vm.atoms.constructor }, original.asValue());
    if (vm.isConstructor(c)) {
        // A constructor from another realm: there is one realm.
    }
    if (c.isObject()) {
        c = try vm.get(asObject(c), .{ .symbol = vm.symbols.species }, c);
        if (c.isNull()) c = Value.undefined_;
    }
    if (c.isUndefined()) return vm.newArrayLen(len);
    if (!vm.isConstructor(c)) return vm.throwTypeError("species is not a constructor");
    const r = try vm.construct(c, &.{Value.fromF64(@floatFromInt(len))}, c);
    return asObject(r);
}

fn callback(vm: *Vm, args: []const Value) Error!Value {
    const f = arg(args, 0);
    if (!vm.isCallable(f)) return vm.throwTypeError("callback is not a function");
    return f;
}

// -------------------------------------------------------- prototype

fn at(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    const rel = try vm.toIntegerOrInfinity(arg(args, 0));
    const k = if (rel >= 0) rel else len + rel;
    if (k < 0 or k >= len) return Value.undefined_;
    return getAt(vm, o, @intFromFloat(k));
}

fn isConcatSpreadable(vm: *Vm, v: Value) Error!bool {
    if (!v.isObject()) return false;
    const s = try vm.get(asObject(v), .{ .symbol = vm.symbols.is_concat_spreadable }, v);
    if (!s.isUndefined()) return vm.toBoolean(s);
    return vm.isArray(v);
}

fn concat(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const a = try speciesCreate(vm, o, 0);
    var n: u64 = 0;
    // The receiver first, then each argument.
    var i: usize = 0;
    while (i <= args.len) : (i += 1) {
        const e = if (i == 0) o.asValue() else args[i - 1];
        if (try isConcatSpreadable(vm, e)) {
            const eo = asObject(e);
            const len = try vm.lengthOfArrayLike(eo);
            if (n + len > 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
            var k: u64 = 0;
            while (k < len) : (k += 1) {
                if (try hasAt(vm, eo, k)) try vm.createDataPropertyOrThrow(a, try bigKey(vm, n), try getAt(vm, eo, k));
                n += 1;
            }
        } else {
            if (n >= 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
            try vm.createDataPropertyOrThrow(a, try bigKey(vm, n), e);
            n += 1;
        }
    }
    try setLen(vm, a, n);
    return a.asValue();
}

fn bigKey(vm: *Vm, i: u64) Error!Key {
    if (i < 0xFFFF_FFFF) return idx(i);
    return vm.keyFromString(try vm.toString(Value.fromF64(@floatFromInt(i))));
}

fn copyWithin(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    var to = try b.relativeIndex(vm, arg(args, 0), len, 0);
    var fromi = try b.relativeIndex(vm, arg(args, 1), len, 0);
    const final = try b.relativeIndex(vm, arg(args, 2), len, len);
    var count = @min(final - fromi, len - to);
    var dir: f64 = 1;
    if (fromi < to and to < fromi + count) {
        dir = -1;
        fromi = fromi + count - 1;
        to = to + count - 1;
    }
    while (count > 0) : (count -= 1) {
        const fi: u64 = @intFromFloat(fromi);
        const ti: u64 = @intFromFloat(to);
        if (try hasAt(vm, o, fi)) {
            try setAt(vm, o, ti, try getAt(vm, o, fi));
        } else try deleteAt(vm, o, ti);
        fromi += dir;
        to += dir;
    }
    return o.asValue();
}

fn entries(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    return iterator.createArrayIterator(vm, o.asValue(), .entries);
}
fn keys(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    return iterator.createArrayIterator(vm, o.asValue(), .keys);
}
fn values(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    return iterator.createArrayIterator(vm, o.asValue(), .values);
}

fn every(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const t = arg(args, 1);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (!try hasAt(vm, o, k)) continue;
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, t, &.{ v, Value.fromF64(@floatFromInt(k)), o.asValue() });
        if (!vm.toBoolean(r)) return Value.false_;
    }
    return Value.true_;
}

fn some(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const t = arg(args, 1);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (!try hasAt(vm, o, k)) continue;
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, t, &.{ v, Value.fromF64(@floatFromInt(k)), o.asValue() });
        if (vm.toBoolean(r)) return Value.true_;
    }
    return Value.false_;
}

fn forEach(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const t = arg(args, 1);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (!try hasAt(vm, o, k)) continue;
        const v = try getAt(vm, o, k);
        _ = try vm.call(f, t, &.{ v, Value.fromF64(@floatFromInt(k)), o.asValue() });
    }
    return Value.undefined_;
}

fn map(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const t = arg(args, 1);
    const a = try speciesCreate(vm, o, len);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (!try hasAt(vm, o, k)) continue;
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, t, &.{ v, Value.fromF64(@floatFromInt(k)), o.asValue() });
        try vm.createDataPropertyOrThrow(a, try bigKey(vm, k), r);
    }
    return a.asValue();
}

fn filter(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const t = arg(args, 1);
    const a = try speciesCreate(vm, o, 0);
    var k: u64 = 0;
    var to: u64 = 0;
    while (k < len) : (k += 1) {
        if (!try hasAt(vm, o, k)) continue;
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, t, &.{ v, Value.fromF64(@floatFromInt(k)), o.asValue() });
        if (vm.toBoolean(r)) {
            try vm.createDataPropertyOrThrow(a, try bigKey(vm, to), v);
            to += 1;
        }
    }
    return a.asValue();
}

fn fill(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    const v = arg(args, 0);
    var k = try b.relativeIndex(vm, arg(args, 1), len, 0);
    const final = try b.relativeIndex(vm, arg(args, 2), len, len);
    while (k < final) : (k += 1) try setAt(vm, o, @intFromFloat(k), v);
    return o.asValue();
}

fn findGeneric(vm: *Vm, this: Value, args: []const Value, from_end: bool, want_index: bool) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const t = arg(args, 1);
    var i: u64 = 0;
    while (i < len) : (i += 1) {
        const k = if (from_end) len - 1 - i else i;
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, t, &.{ v, Value.fromF64(@floatFromInt(k)), o.asValue() });
        if (vm.toBoolean(r)) return if (want_index) Value.fromF64(@floatFromInt(k)) else v;
    }
    return if (want_index) Value.fromInt(-1) else Value.undefined_;
}
fn find(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findGeneric(vm, this, args, false, false);
}
fn findIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findGeneric(vm, this, args, false, true);
}
fn findLast(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findGeneric(vm, this, args, true, false);
}
fn findLastIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findGeneric(vm, this, args, true, true);
}

/// FlattenIntoArray.
fn flattenInto(vm: *Vm, target: *Object, source: *Object, source_len: u64, start: u64, depth: f64, mapper: ?Value, this_arg: Value) Error!u64 {
    var target_index = start;
    var i: u64 = 0;
    while (i < source_len) : (i += 1) {
        if (!try hasAt(vm, source, i)) continue;
        var el = try getAt(vm, source, i);
        if (mapper) |m| el = try vm.call(m, this_arg, &.{ el, Value.fromF64(@floatFromInt(i)), source.asValue() });
        if (depth > 0 and try vm.isArray(el)) {
            const eo = asObject(el);
            target_index = try flattenInto(vm, target, eo, try vm.lengthOfArrayLike(eo), target_index, depth - 1, null, Value.undefined_);
        } else {
            if (target_index >= 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
            try vm.createDataPropertyOrThrow(target, try bigKey(vm, target_index), el);
            target_index += 1;
        }
    }
    return target_index;
}

fn flat(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    var depth: f64 = 1;
    if (!arg(args, 0).isUndefined()) {
        depth = try vm.toIntegerOrInfinity(arg(args, 0));
        if (depth < 0) depth = 0;
    }
    const a = try speciesCreate(vm, o, 0);
    _ = try flattenInto(vm, a, o, len, 0, depth, null, Value.undefined_);
    return a.asValue();
}

fn flatMap(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    const a = try speciesCreate(vm, o, 0);
    _ = try flattenInto(vm, a, o, len, 0, 1, f, arg(args, 1));
    return a.asValue();
}

fn includes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    if (len == 0) return Value.false_;
    var n = try vm.toIntegerOrInfinity(arg(args, 1));
    if (n == std.math.inf(f64)) return Value.false_;
    if (n == -std.math.inf(f64)) n = 0;
    var k: f64 = if (n >= 0) n else @max(len + n, 0);
    const target = arg(args, 0);
    while (k < len) : (k += 1) {
        const v = try getAt(vm, o, @intFromFloat(k));
        if (vm.sameValueZero(v, target)) return Value.true_;
    }
    return Value.false_;
}

fn indexOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    if (len == 0) return Value.fromInt(-1);
    var n = try vm.toIntegerOrInfinity(arg(args, 1));
    if (n == std.math.inf(f64)) return Value.fromInt(-1);
    if (n == -std.math.inf(f64)) n = 0;
    var k: f64 = if (n >= 0) n else @max(len + n, 0);
    const target = arg(args, 0);
    while (k < len) : (k += 1) {
        const ki: u64 = @intFromFloat(k);
        if (!try hasAt(vm, o, ki)) continue;
        const v = try getAt(vm, o, ki);
        if (vm.isStrictlyEqual(v, target)) return Value.fromF64(k);
    }
    return Value.fromInt(-1);
}

fn lastIndexOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    if (len == 0) return Value.fromInt(-1);
    var n: f64 = len - 1;
    if (args.len > 1) n = try vm.toIntegerOrInfinity(args[1]);
    if (n == -std.math.inf(f64)) return Value.fromInt(-1);
    var k: f64 = if (n >= 0) @min(n, len - 1) else len + n;
    const target = arg(args, 0);
    while (k >= 0) : (k -= 1) {
        const ki: u64 = @intFromFloat(k);
        if (!try hasAt(vm, o, ki)) continue;
        const v = try getAt(vm, o, ki);
        if (vm.isStrictlyEqual(v, target)) return Value.fromF64(k);
    }
    return Value.fromInt(-1);
}

pub fn join(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const sep_v = arg(args, 0);
    const sep = if (sep_v.isUndefined()) try vm.strings.fromUtf8(",") else try vm.toString(sep_v);
    // Cycle protection: an array joining itself (through toString)
    // yields the empty string for the inner occurrence.
    if (vm.join_stack.items.len > 64) return strValue(vm.atoms.empty);
    for (vm.join_stack.items) |p| if (p == o) return strValue(vm.atoms.empty);
    try vm.join_stack.append(vm.meta, o);
    defer _ = vm.join_stack.pop();
    var out = try vm.strings.fromUtf8("");
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (k > 0) out = try vm.concatStrings(out, sep);
        const v = try getAt(vm, o, k);
        if (v.isNullish()) continue;
        out = try vm.concatStrings(out, try vm.toString(v));
    }
    return strValue(out);
}

fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const f = try vm.get(o, .{ .atom = vm.atoms.join }, o.asValue());
    if (vm.isCallable(f)) return vm.call(f, o.asValue(), &.{});
    return b.object.toString(vm, o.asValue(), &.{}, Value.undefined_);
}

fn toLocaleString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    for (vm.join_stack.items) |p| if (p == o) return strValue(vm.atoms.empty);
    try vm.join_stack.append(vm.meta, o);
    defer _ = vm.join_stack.pop();
    const sep = try vm.strings.fromUtf8(",");
    var out = try vm.strings.fromUtf8("");
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (k > 0) out = try vm.concatStrings(out, sep);
        const v = try getAt(vm, o, k);
        if (v.isNullish()) continue;
        const r = try vm.invoke(v, .{ .atom = try vm.atom("toLocaleString") }, &.{});
        out = try vm.concatStrings(out, try vm.toString(r));
    }
    return strValue(out);
}

fn pop(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    if (len == 0) {
        try setLen(vm, o, 0);
        return Value.undefined_;
    }
    const v = try getAt(vm, o, len - 1);
    try deleteAt(vm, o, len - 1);
    try setLen(vm, o, len - 1);
    return v;
}

fn push(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    // The fast path: a plain dense array.
    if (o.class == .array and !o.sparse_indexes and o.extensible and vm.lengthWritable(o) and @as(u64, Vm.arrayLength(o)) + args.len < 0xFFFF_FFFF) {
        for (args) |v| try vm.arrayPush(o, v);
        return Value.fromF64(@floatFromInt(Vm.arrayLength(o)));
    }
    const len = try vm.lengthOfArrayLike(o);
    if (len + args.len > 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
    var n = len;
    for (args) |v| {
        try setAt(vm, o, n, v);
        n += 1;
    }
    try setLen(vm, o, n);
    return Value.fromF64(@floatFromInt(n));
}

fn reduceGeneric(vm: *Vm, this: Value, args: []const Value, right: bool) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const f = try callback(vm, args);
    var k: u64 = 0;
    var acc: Value = undefined;
    if (args.len >= 2) {
        acc = args[1];
    } else {
        var found = false;
        while (k < len) : (k += 1) {
            const i = if (right) len - 1 - k else k;
            if (try hasAt(vm, o, i)) {
                acc = try getAt(vm, o, i);
                found = true;
                k += 1;
                break;
            }
        }
        if (!found) return vm.throwTypeError("Reduce of empty array with no initial value");
    }
    while (k < len) : (k += 1) {
        const i = if (right) len - 1 - k else k;
        if (!try hasAt(vm, o, i)) continue;
        const v = try getAt(vm, o, i);
        acc = try vm.call(f, Value.undefined_, &.{ acc, v, Value.fromF64(@floatFromInt(i)), o.asValue() });
    }
    return acc;
}
fn reduce(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return reduceGeneric(vm, this, args, false);
}
fn reduceRight(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return reduceGeneric(vm, this, args, true);
}

fn reverse(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const middle = len / 2;
    var lower: u64 = 0;
    while (lower != middle) : (lower += 1) {
        const upper = len - lower - 1;
        const lower_exists = try hasAt(vm, o, lower);
        const lower_v = if (lower_exists) try getAt(vm, o, lower) else Value.undefined_;
        const upper_exists = try hasAt(vm, o, upper);
        const upper_v = if (upper_exists) try getAt(vm, o, upper) else Value.undefined_;
        if (lower_exists and upper_exists) {
            try setAt(vm, o, lower, upper_v);
            try setAt(vm, o, upper, lower_v);
        } else if (upper_exists) {
            try setAt(vm, o, lower, upper_v);
            try deleteAt(vm, o, upper);
        } else if (lower_exists) {
            try deleteAt(vm, o, lower);
            try setAt(vm, o, upper, lower_v);
        }
    }
    return o.asValue();
}

fn shift(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    if (len == 0) {
        try setLen(vm, o, 0);
        return Value.undefined_;
    }
    const first = try getAt(vm, o, 0);
    if (o.class == .array and !o.sparse_indexes and !vm.proto_has_indexes and vm.lengthWritable(o)) if (o.elements) |e| if (e.len <= e.cap) {
        // Dense: slide the elements down.
        const items = e.items();
        std.mem.copyForwards(Value, items[0 .. e.len - 1], items[1..e.len]);
        items[e.len - 1] = Value.empty;
        e.len -= 1;
        return first;
    };
    var k: u64 = 1;
    while (k < len) : (k += 1) {
        if (try hasAt(vm, o, k)) {
            try setAt(vm, o, k - 1, try getAt(vm, o, k));
        } else try deleteAt(vm, o, k - 1);
    }
    try deleteAt(vm, o, len - 1);
    try setLen(vm, o, len - 1);
    return first;
}

fn unshift(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const n = args.len;
    if (n > 0) {
        if (len + n > 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
        var k = len;
        while (k > 0) : (k -= 1) {
            const src_i = k - 1;
            const to = k + n - 1;
            if (try hasAt(vm, o, src_i)) {
                try setAt(vm, o, to, try getAt(vm, o, src_i));
            } else try deleteAt(vm, o, to);
        }
        for (args, 0..) |v, j| try setAt(vm, o, j, v);
    }
    try setLen(vm, o, len + n);
    return Value.fromF64(@floatFromInt(len + n));
}

fn slice(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    var k = try b.relativeIndex(vm, arg(args, 0), len, 0);
    const final = try b.relativeIndex(vm, arg(args, 1), len, len);
    const count: u64 = @intFromFloat(@max(final - k, 0));
    const a = try speciesCreate(vm, o, count);
    var n: u64 = 0;
    while (k < final) : (k += 1) {
        const ki: u64 = @intFromFloat(k);
        if (try hasAt(vm, o, ki)) try vm.createDataPropertyOrThrow(a, try bigKey(vm, n), try getAt(vm, o, ki));
        n += 1;
    }
    try setLen(vm, a, n);
    return a.asValue();
}

fn splice(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    const start = try b.relativeIndex(vm, arg(args, 0), len, 0);
    var insert_count: u64 = 0;
    var delete_count: f64 = 0;
    if (args.len == 0) {
        delete_count = 0;
    } else if (args.len == 1) {
        delete_count = len - start;
    } else {
        insert_count = args.len - 2;
        const dc = try vm.toIntegerOrInfinity(args[1]);
        delete_count = @min(@max(dc, 0), len - start);
    }
    if (len + @as(f64, @floatFromInt(insert_count)) - delete_count > 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
    const dcount: u64 = @intFromFloat(delete_count);
    const s: u64 = @intFromFloat(start);
    const a = try speciesCreate(vm, o, dcount);
    var k: u64 = 0;
    while (k < dcount) : (k += 1) {
        if (try hasAt(vm, o, s + k)) try vm.createDataPropertyOrThrow(a, try bigKey(vm, k), try getAt(vm, o, s + k));
    }
    try setLen(vm, a, dcount);
    const ulen: u64 = @intFromFloat(len);
    const items = if (args.len > 2) args[2..] else &[_]Value{};
    if (insert_count < dcount) {
        k = s;
        while (k < ulen - dcount) : (k += 1) {
            const src_i = k + dcount;
            const to = k + insert_count;
            if (try hasAt(vm, o, src_i)) {
                try setAt(vm, o, to, try getAt(vm, o, src_i));
            } else try deleteAt(vm, o, to);
        }
        k = ulen;
        while (k > ulen - dcount + insert_count) : (k -= 1) try deleteAt(vm, o, k - 1);
    } else if (insert_count > dcount) {
        k = ulen - dcount;
        while (k > s) : (k -= 1) {
            const src_i = k + dcount - 1;
            const to = k + insert_count - 1;
            if (try hasAt(vm, o, src_i)) {
                try setAt(vm, o, to, try getAt(vm, o, src_i));
            } else try deleteAt(vm, o, to);
        }
    }
    for (items, 0..) |v, j| try setAt(vm, o, s + j, v);
    try setLen(vm, o, ulen - dcount + insert_count);
    return a.asValue();
}

/// SortCompare with an optional comparator; undefined sorts last.
const SortCtx = struct { vm: *Vm, cmp: Value, err: ?Error = null };

fn sortLess(ctx: *SortCtx, x: Value, y: Value) bool {
    if (ctx.err != null) return false;
    const vm = ctx.vm;
    if (x.isUndefined()) return false;
    if (y.isUndefined()) return true;
    if (!ctx.cmp.isUndefined()) {
        const r = vm.call(ctx.cmp, Value.undefined_, &.{ x, y }) catch |e| {
            ctx.err = e;
            return false;
        };
        const d = vm.toNumber(r) catch |e| {
            ctx.err = e;
            return false;
        };
        return d < 0;
    }
    const xs = vm.toString(x) catch |e| {
        ctx.err = e;
        return false;
    };
    const ys = vm.toString(y) catch |e| {
        ctx.err = e;
        return false;
    };
    return vm.stringLessThan(xs, ys) catch |e| {
        ctx.err = e;
        return false;
    };
}

/// SortIndexedProperties: collect, sort (stable), write back.
fn sortList(vm: *Vm, o: *Object, len: u64, cmp: Value, holes: enum { skip, keep }) Error!std.ArrayList(Value) {
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(vm.meta);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (holes == .skip) {
            if (!try hasAt(vm, o, k)) continue;
        }
        try list.append(vm.meta, try getAt(vm, o, k));
    }
    var ctx = SortCtx{ .vm = vm, .cmp = cmp };
    std.mem.sort(Value, list.items, &ctx, sortLess);
    if (ctx.err) |e| return e;
    return list;
}

fn sort(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const cmp = arg(args, 0);
    if (!cmp.isUndefined() and !vm.isCallable(cmp)) return vm.throwTypeError("The comparison function must be either a function or undefined");
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    var list = try sortList(vm, o, len, cmp, .skip);
    defer list.deinit(vm.meta);
    var j: u64 = 0;
    while (j < list.items.len) : (j += 1) try setAt(vm, o, j, list.items[j]);
    while (j < len) : (j += 1) try deleteAt(vm, o, j);
    return o.asValue();
}

fn toSorted(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const cmp = arg(args, 0);
    if (!cmp.isUndefined() and !vm.isCallable(cmp)) return vm.throwTypeError("The comparison function must be either a function or undefined");
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const a = try vm.newArrayLen(len);
    var list = try sortList(vm, o, len, cmp, .keep);
    defer list.deinit(vm.meta);
    for (list.items, 0..) |v, j| try vm.createDataPropertyOrThrow(a, try bigKey(vm, j), v);
    return a.asValue();
}

fn toReversed(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len = try vm.lengthOfArrayLike(o);
    const a = try vm.newArrayLen(len);
    var k: u64 = 0;
    while (k < len) : (k += 1) try vm.createDataPropertyOrThrow(a, try bigKey(vm, k), try getAt(vm, o, len - 1 - k));
    return a.asValue();
}

fn toSpliced(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    const start = try b.relativeIndex(vm, arg(args, 0), len, 0);
    var insert_count: u64 = 0;
    var skip: f64 = 0;
    if (args.len == 0) {
        skip = 0;
    } else if (args.len == 1) {
        skip = len - start;
    } else {
        insert_count = args.len - 2;
        const dc = try vm.toIntegerOrInfinity(args[1]);
        skip = @min(@max(dc, 0), len - start);
    }
    const new_len = len + @as(f64, @floatFromInt(insert_count)) - skip;
    if (new_len > 9007199254740991) return vm.throwTypeError("Array length exceeds the maximum");
    const a = try vm.newArrayLen(@intFromFloat(new_len));
    var i: u64 = 0;
    var r: u64 = @intFromFloat(start + skip);
    const s: u64 = @intFromFloat(start);
    while (i < s) : (i += 1) try vm.createDataPropertyOrThrow(a, try bigKey(vm, i), try getAt(vm, o, i));
    if (args.len > 2) for (args[2..]) |v| {
        try vm.createDataPropertyOrThrow(a, try bigKey(vm, i), v);
        i += 1;
    };
    const nl: u64 = @intFromFloat(new_len);
    while (i < nl) : (i += 1) {
        try vm.createDataPropertyOrThrow(a, try bigKey(vm, i), try getAt(vm, o, r));
        r += 1;
    }
    return a.asValue();
}

fn with(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const len: f64 = @floatFromInt(try vm.lengthOfArrayLike(o));
    const rel = try vm.toIntegerOrInfinity(arg(args, 0));
    const actual = if (rel >= 0) rel else len + rel;
    if (actual >= len or actual < 0) return vm.throwRangeError("Invalid index");
    const a = try vm.newArrayLen(@intFromFloat(len));
    var k: u64 = 0;
    const ai: u64 = @intFromFloat(actual);
    const ulen: u64 = @intFromFloat(len);
    while (k < ulen) : (k += 1) {
        const v = if (k == ai) arg(args, 1) else try getAt(vm, o, k);
        try vm.createDataPropertyOrThrow(a, try bigKey(vm, k), v);
    }
    return a.asValue();
}
