//! Map, Set, WeakMap and WeakSet (§24.1–24.4): an insertion-ordered
//! entry list (a JS array of key/value pairs, holes for deletions, so
//! the collector sees it) indexed by a hash table keyed by
//! SameValueZero. Iterators walk the list by index, which gives the
//! specification's semantics for entries added or removed during
//! iteration. The weak collections hold their keys strongly for now:
//! ephemeron support in the collector is the nursery's stage.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const String = b.String;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

/// The hash index: a key's slot in the entry list.
const Index = std.HashMapUnmanaged(Value, u32, KeyContext, 80);

const KeyContext = struct {
    vm: *Vm,
    pub fn hash(ctx: KeyContext, v: Value) u64 {
        if (v.isString()) return asString(v).hash();
        _ = ctx;
        return std.hash.Wyhash.hash(0, std.mem.asBytes(&v.bits));
    }
    pub fn eql(ctx: KeyContext, a: Value, b_: Value) bool {
        return ctx.vm.sameValueZero(a, b_);
    }
};

pub const CollectionData = extern struct {
    /// key0, value0, key1, value1, ... (a Set stores the key twice).
    entries: Value,
    index: ?*Index,
    size: u32,
    _pad: u32 = 0,
};

pub fn trace(o: *Object, m: *heap.Marker) void {
    m.markValue(o.internal(CollectionData).entries);
}

pub fn finalize(vm: *Vm, o: *Object) void {
    const d = o.internal(CollectionData);
    if (d.index) |ix| {
        ix.deinit(vm.meta);
        vm.meta.destroy(ix);
        d.index = null;
    }
}

pub fn install(vm: *Vm) Error!void {
    const i = &vm.intrinsics;
    // Map
    i.map_prototype = try vm.newObject();
    const map_ctor = try b.installConstructor(vm, "Map", 0, mapConstruct, i.map_prototype);
    _ = try vm.defineNative(map_ctor, "groupBy", 2, mapGroupBy);
    try species(vm, map_ctor);
    _ = try vm.defineNative(i.map_prototype, "clear", 0, mapClear);
    _ = try vm.defineNative(i.map_prototype, "delete", 1, mapDelete);
    _ = try vm.defineNative(i.map_prototype, "entries", 0, mapEntries);
    _ = try vm.defineNative(i.map_prototype, "forEach", 1, mapForEach);
    _ = try vm.defineNative(i.map_prototype, "get", 1, mapGet);
    _ = try vm.defineNative(i.map_prototype, "getOrInsert", 2, mapGetOrInsert);
    _ = try vm.defineNative(i.map_prototype, "getOrInsertComputed", 2, mapGetOrInsertComputed);
    _ = try vm.defineNative(i.map_prototype, "has", 1, mapHas);
    _ = try vm.defineNative(i.map_prototype, "keys", 0, mapKeys);
    _ = try vm.defineNative(i.map_prototype, "set", 2, mapSet);
    try vm.defineGetter(i.map_prototype, "size", mapSize);
    _ = try vm.defineNative(i.map_prototype, "values", 0, mapValues);
    _ = try vm.objects.defineOwn(i.map_prototype, .{ .symbol = vm.symbols.iterator }, try vm.get(i.map_prototype, .{ .atom = try vm.atom("entries") }, i.map_prototype.asValue()), .hidden);
    try b.setToStringTag(vm, i.map_prototype, "Map");
    i.map_iterator_prototype = try vm.objects.create(i.iterator_prototype.asValue(), .ordinary, 0);
    _ = try vm.defineNative(i.map_iterator_prototype, "next", 0, mapIteratorNext);
    try b.setToStringTag(vm, i.map_iterator_prototype, "Map Iterator");
    // Set
    i.set_prototype = try vm.newObject();
    const set_ctor = try b.installConstructor(vm, "Set", 0, setConstruct, i.set_prototype);
    try species(vm, set_ctor);
    _ = try vm.defineNative(i.set_prototype, "add", 1, setAdd);
    _ = try vm.defineNative(i.set_prototype, "clear", 0, setClear);
    _ = try vm.defineNative(i.set_prototype, "delete", 1, setDelete);
    _ = try vm.defineNative(i.set_prototype, "entries", 0, setEntries);
    _ = try vm.defineNative(i.set_prototype, "forEach", 1, setForEach);
    _ = try vm.defineNative(i.set_prototype, "has", 1, setHas);
    _ = try vm.defineNative(i.set_prototype, "union", 1, setUnion);
    _ = try vm.defineNative(i.set_prototype, "intersection", 1, setIntersection);
    _ = try vm.defineNative(i.set_prototype, "difference", 1, setDifference);
    _ = try vm.defineNative(i.set_prototype, "symmetricDifference", 1, setSymmetricDifference);
    _ = try vm.defineNative(i.set_prototype, "isSubsetOf", 1, setIsSubsetOf);
    _ = try vm.defineNative(i.set_prototype, "isSupersetOf", 1, setIsSupersetOf);
    _ = try vm.defineNative(i.set_prototype, "isDisjointFrom", 1, setIsDisjointFrom);
    try vm.defineGetter(i.set_prototype, "size", setSize);
    const set_values = try vm.defineNative(i.set_prototype, "values", 0, setValues);
    try vm.defineValue(i.set_prototype, "keys", set_values.asValue(), .hidden);
    _ = try vm.objects.defineOwn(i.set_prototype, .{ .symbol = vm.symbols.iterator }, set_values.asValue(), .hidden);
    try b.setToStringTag(vm, i.set_prototype, "Set");
    i.set_iterator_prototype = try vm.objects.create(i.iterator_prototype.asValue(), .ordinary, 0);
    _ = try vm.defineNative(i.set_iterator_prototype, "next", 0, setIteratorNext);
    try b.setToStringTag(vm, i.set_iterator_prototype, "Set Iterator");
    // WeakMap / WeakSet
    i.weak_map_prototype = try vm.newObject();
    _ = try b.installConstructor(vm, "WeakMap", 0, weakMapConstruct, i.weak_map_prototype);
    _ = try vm.defineNative(i.weak_map_prototype, "delete", 1, weakMapDelete);
    _ = try vm.defineNative(i.weak_map_prototype, "get", 1, weakMapGet);
    _ = try vm.defineNative(i.weak_map_prototype, "getOrInsert", 2, weakMapGetOrInsert);
    _ = try vm.defineNative(i.weak_map_prototype, "getOrInsertComputed", 2, weakMapGetOrInsertComputed);
    _ = try vm.defineNative(i.weak_map_prototype, "has", 1, weakMapHas);
    _ = try vm.defineNative(i.weak_map_prototype, "set", 2, weakMapSet);
    try b.setToStringTag(vm, i.weak_map_prototype, "WeakMap");
    i.weak_set_prototype = try vm.newObject();
    _ = try b.installConstructor(vm, "WeakSet", 0, weakSetConstruct, i.weak_set_prototype);
    _ = try vm.defineNative(i.weak_set_prototype, "add", 1, weakSetAdd);
    _ = try vm.defineNative(i.weak_set_prototype, "delete", 1, weakSetDelete);
    _ = try vm.defineNative(i.weak_set_prototype, "has", 1, weakSetHas);
    try b.setToStringTag(vm, i.weak_set_prototype, "WeakSet");
}

fn species(vm: *Vm, ctor: *Object) Error!void {
    const g = try vm.newNative("get [Symbol.species]", 0, speciesGetter, Value.undefined_);
    try vm.defineAccessor(ctor, .{ .symbol = vm.symbols.species }, g, null, .{ .enumerable = false, .configurable = true });
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

// ------------------------------------------------------------ core

fn newCollection(vm: *Vm, new_target: Value, class: vmod.Class, default_proto: *Object) Error!*Object {
    const o = try vm.createFromConstructor(new_target, default_proto, class, @sizeOf(CollectionData));
    try initCollection(vm, o);
    return o;
}

fn newCollectionWithProto(vm: *Vm, class: vmod.Class, proto: *Object) Error!*Object {
    const o = try vm.objects.create(proto.asValue(), class, @sizeOf(CollectionData));
    try initCollection(vm, o);
    return o;
}

fn initCollection(vm: *Vm, o: *Object) Error!void {
    const ix = try vm.meta.create(Index);
    ix.* = .empty;
    o.internal(CollectionData).* = .{ .entries = (try vm.newArray(0)).asValue(), .index = ix, .size = 0 };
}

fn thisCollection(vm: *Vm, this: Value, class: vmod.Class, what: []const u8) Error!*CollectionData {
    if (!this.isObject() or asObject(this).class != class or asObject(this).internal(CollectionData).index == null) return vm.throwTypeErrorFmt("{s} method called on incompatible receiver", .{what});
    return asObject(this).internal(CollectionData);
}

/// The key as stored: -0 becomes +0 (SameValueZero).
fn normalize(k: Value) Value {
    if (k.isDouble() and k.asDouble() == 0) return Value.fromInt(0);
    return k;
}

fn lookup(vm: *Vm, d: *CollectionData, key: Value) ?u32 {
    return d.index.?.getContext(normalize(key), .{ .vm = vm });
}

fn entriesArr(d: *CollectionData) *Object {
    return asObject(d.entries);
}

fn insert(vm: *Vm, d: *CollectionData, key: Value, value: Value) Error!void {
    const k = normalize(key);
    if (lookup(vm, d, k)) |slot| {
        const items = entriesArr(d).elements.?.items();
        vm.heap.writeBarrier(&entriesArr(d).header, value);
        items[slot * 2 + 1] = value;
        return;
    }
    const arr = entriesArr(d);
    const slot: u32 = Vm.arrayLength(arr) / 2;
    try vm.arrayPush(arr, k);
    try vm.arrayPush(arr, value);
    try d.index.?.putContext(vm.meta, k, slot, .{ .vm = vm });
    d.size += 1;
}

fn remove(vm: *Vm, d: *CollectionData, key: Value) bool {
    const k = normalize(key);
    const slot = lookup(vm, d, k) orelse return false;
    const items = entriesArr(d).elements.?.items();
    items[slot * 2] = Value.empty;
    items[slot * 2 + 1] = Value.empty;
    _ = d.index.?.removeContext(k, .{ .vm = vm });
    d.size -= 1;
    return true;
}

fn clearAll(vm: *Vm, d: *CollectionData) void {
    const arr = entriesArr(d);
    const n = Vm.arrayLength(arr);
    if (n > 0) {
        const items = arr.elements.?.items();
        @memset(items[0..n], Value.empty);
    }
    d.index.?.clearRetainingCapacity();
    _ = vm;
    d.size = 0;
}

/// AddEntriesFromIterable / the Set constructor's adds.
fn fillFromIterable(vm: *Vm, target: *Object, iterable: Value, adder_name: []const u8, pairs: bool) Error!void {
    const adder = try vm.get(target, .{ .atom = try vm.atom(adder_name) }, target.asValue());
    if (!vm.isCallable(adder)) return vm.throwTypeErrorFmt("'{s}' is not a function", .{adder_name});
    var rec = try vm.getIterator(iterable);
    while (try vm.iteratorStepValue(&rec)) |item| {
        if (pairs) {
            if (!item.isObject()) {
                vm.iteratorCloseThrow(rec);
                return vm.throwTypeError("Iterator value is not an entry object");
            }
            const k = vm.get(asObject(item), .{ .index = 0 }, item) catch |e| {
                vm.iteratorCloseThrow(rec);
                return e;
            };
            const v = vm.get(asObject(item), .{ .index = 1 }, item) catch |e| {
                vm.iteratorCloseThrow(rec);
                return e;
            };
            _ = vm.call(adder, target.asValue(), &.{ k, v }) catch |e| {
                vm.iteratorCloseThrow(rec);
                return e;
            };
        } else {
            _ = vm.call(adder, target.asValue(), &.{item}) catch |e| {
                vm.iteratorCloseThrow(rec);
                return e;
            };
        }
    }
}

// -------------------------------------------------------------- Map

fn mapConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor Map requires 'new'");
    const o = try newCollection(vm, new_target, .map, vm.intrinsics.map_prototype);
    const iterable = arg(args, 0);
    if (!iterable.isNullish()) try fillFromIterable(vm, o, iterable, "set", true);
    return o.asValue();
}

fn mapClear(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    clearAll(vm, try thisCollection(vm, this, .map, "Map.prototype.clear"));
    return Value.undefined_;
}

fn setClear(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    clearAll(vm, try thisCollection(vm, this, .set, "Set.prototype.clear"));
    return Value.undefined_;
}

fn mapDelete(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.delete");
    return Value.fromBool(remove(vm, d, arg(args, 0)));
}

fn mapGet(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.get");
    const slot = lookup(vm, d, arg(args, 0)) orelse return Value.undefined_;
    return entriesArr(d).elements.?.items()[slot * 2 + 1];
}

fn mapHas(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.has");
    return Value.fromBool(lookup(vm, d, arg(args, 0)) != null);
}

fn mapSet(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.set");
    try insert(vm, d, arg(args, 0), arg(args, 1));
    return this;
}

/// getOrInsert / getOrInsertComputed (the upsert proposal, in test262).
fn getOrInsert(vm: *Vm, d: *CollectionData, key: Value, value: Value) Error!Value {
    if (lookup(vm, d, key)) |slot| return entriesArr(d).elements.?.items()[slot * 2 + 1];
    try insert(vm, d, key, value);
    return value;
}

fn getOrInsertComputed(vm: *Vm, d: *CollectionData, key: Value, cb: Value) Error!Value {
    if (lookup(vm, d, key)) |slot| return entriesArr(d).elements.?.items()[slot * 2 + 1];
    const value = try vm.call(cb, Value.undefined_, &.{normalize(key)});
    try insert(vm, d, key, value); // overwrites what the callback inserted
    return value;
}

fn mapGetOrInsert(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.getOrInsert");
    return getOrInsert(vm, d, arg(args, 0), arg(args, 1));
}

fn mapGetOrInsertComputed(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.getOrInsertComputed");
    if (!vm.isCallable(arg(args, 1))) return vm.throwTypeError("Map.prototype.getOrInsertComputed callback is not a function");
    return getOrInsertComputed(vm, d, arg(args, 0), arg(args, 1));
}

fn weakMapGetOrInsert(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_map, "WeakMap.prototype.getOrInsert");
    if (!canBeHeldWeakly(arg(args, 0))) return vm.throwTypeError("Invalid value used as weak map key");
    return getOrInsert(vm, d, arg(args, 0), arg(args, 1));
}

fn weakMapGetOrInsertComputed(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_map, "WeakMap.prototype.getOrInsertComputed");
    if (!canBeHeldWeakly(arg(args, 0))) return vm.throwTypeError("Invalid value used as weak map key");
    if (!vm.isCallable(arg(args, 1))) return vm.throwTypeError("WeakMap.prototype.getOrInsertComputed callback is not a function");
    return getOrInsertComputed(vm, d, arg(args, 0), arg(args, 1));
}

fn mapSize(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "get Map.prototype.size");
    return Value.fromInt(@intCast(d.size));
}

fn mapForEach(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .map, "Map.prototype.forEach");
    const f = arg(args, 0);
    if (!vm.isCallable(f)) return vm.throwTypeError("Map.prototype.forEach callback is not a function");
    var i: u32 = 0;
    while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
        const items = entriesArr(d).elements.?.items();
        const k = items[i];
        if (k.isEmpty()) continue;
        _ = try vm.call(f, arg(args, 1), &.{ items[i + 1], k, this });
    }
    return Value.undefined_;
}

const IterData = extern struct {
    target: Value, // the collection, undefined once done
    extra: Value = Value.undefined_,
    index: u32,
    kind: u8, // 0 keys, 1 values, 2 entries
    _pad: [3]u8 = @splat(0),
};

fn newIterator(vm: *Vm, target: Value, proto: *Object, kind: u8) Error!Value {
    const o = try vm.objects.create(proto.asValue(), .iterator, @sizeOf(IterData));
    o.internal(IterData).* = .{ .target = target, .index = 0, .kind = kind };
    return o.asValue();
}

fn mapEntries(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisCollection(vm, this, .map, "Map.prototype.entries");
    return newIterator(vm, this, vm.intrinsics.map_iterator_prototype, 2);
}
fn mapKeys(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisCollection(vm, this, .map, "Map.prototype.keys");
    return newIterator(vm, this, vm.intrinsics.map_iterator_prototype, 0);
}
fn mapValues(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisCollection(vm, this, .map, "Map.prototype.values");
    return newIterator(vm, this, vm.intrinsics.map_iterator_prototype, 1);
}

fn iteratorNext(vm: *Vm, this: Value, proto: *Object) Error!Value {
    if (!this.isObject() or asObject(this).class != .iterator or asObject(this).shape.proto.bits != proto.asValue().bits) return vm.throwTypeError("next method called on incompatible receiver");
    const it = asObject(this).internal(IterData);
    if (it.target.isUndefined()) return vm.iterResult(Value.undefined_, true);
    const d = asObject(it.target).internal(CollectionData);
    while (it.index < Vm.arrayLength(entriesArr(d))) {
        const items = entriesArr(d).elements.?.items();
        const i = it.index;
        it.index += 2;
        const k = items[i];
        if (k.isEmpty()) continue;
        const v = items[i + 1];
        return switch (it.kind) {
            0 => vm.iterResult(k, false),
            1 => vm.iterResult(v, false),
            else => vm.iterResult((try vm.arrayFromList(&.{ k, v })).asValue(), false),
        };
    }
    it.target = Value.undefined_;
    return vm.iterResult(Value.undefined_, true);
}

fn mapIteratorNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return iteratorNext(vm, this, vm.intrinsics.map_iterator_prototype);
}

fn mapGroupBy(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const items = arg(args, 0);
    const cb = arg(args, 1);
    if (items.isNullish()) return vm.throwTypeError("Map.groupBy called on null or undefined");
    if (!vm.isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const out = try newCollectionWithProto(vm, .map, vm.intrinsics.map_prototype);
    const d = out.internal(CollectionData);
    var rec = try vm.getIterator(items);
    var k: f64 = 0;
    while (try vm.iteratorStepValue(&rec)) |v| {
        const key = vm.call(cb, Value.undefined_, &.{ v, Value.fromF64(k) }) catch |e| {
            vm.iteratorCloseThrow(rec);
            return e;
        };
        if (lookup(vm, d, key)) |slot| {
            try vm.arrayPush(asObject(entriesArr(d).elements.?.items()[slot * 2 + 1]), v);
        } else {
            const group = try vm.arrayFromList(&.{v});
            try insert(vm, d, key, group.asValue());
        }
        k += 1;
    }
    return out.asValue();
}

// -------------------------------------------------------------- Set

fn setConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor Set requires 'new'");
    const o = try newCollection(vm, new_target, .set, vm.intrinsics.set_prototype);
    const iterable = arg(args, 0);
    if (!iterable.isNullish()) try fillFromIterable(vm, o, iterable, "add", false);
    return o.asValue();
}

fn setAdd(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.add");
    const k = arg(args, 0);
    if (lookup(vm, d, k) == null) try insert(vm, d, k, normalize(k));
    return this;
}

fn setDelete(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.delete");
    return Value.fromBool(remove(vm, d, arg(args, 0)));
}

fn setHas(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.has");
    return Value.fromBool(lookup(vm, d, arg(args, 0)) != null);
}

fn setSize(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "get Set.prototype.size");
    return Value.fromInt(@intCast(d.size));
}

fn setForEach(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.forEach");
    const f = arg(args, 0);
    if (!vm.isCallable(f)) return vm.throwTypeError("Set.prototype.forEach callback is not a function");
    var i: u32 = 0;
    while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
        const items = entriesArr(d).elements.?.items();
        const k = items[i];
        if (k.isEmpty()) continue;
        _ = try vm.call(f, arg(args, 1), &.{ k, k, this });
    }
    return Value.undefined_;
}

// The set methods (§24.2.4): a "set-like" argument is read through
// GetSetRecord, and every result is a plain Set (no species).

const SetRecord = struct { set: *Object, size: f64, has: Value, keys: Value };

fn getSetRecord(vm: *Vm, v: Value) Error!SetRecord {
    if (!v.isObject()) return vm.throwTypeError("The set-like argument must be an object");
    const o = asObject(v);
    const raw_size = try vm.get(o, .{ .atom = try vm.atom("size") }, v);
    const num_size = try vm.toNumber(raw_size);
    if (std.math.isNan(num_size)) return vm.throwTypeError("The set-like argument's 'size' is not a number");
    const int_size = try vm.toIntegerOrInfinity(Value.fromF64(num_size));
    if (int_size < 0) return vm.throwRangeError("The set-like argument's 'size' is negative");
    const has = try vm.get(o, .{ .atom = try vm.atom("has") }, v);
    if (!vm.isCallable(has)) return vm.throwTypeError("The set-like argument's 'has' is not a function");
    const keys = try vm.get(o, .{ .atom = try vm.atom("keys") }, v);
    if (!vm.isCallable(keys)) return vm.throwTypeError("The set-like argument's 'keys' is not a function");
    return .{ .set = o, .size = int_size, .has = has, .keys = keys };
}

fn newSetFrom(vm: *Vm, d: *CollectionData) Error!*Object {
    const out = try newCollectionWithProto(vm, .set, vm.intrinsics.set_prototype);
    const od = out.internal(CollectionData);
    var i: u32 = 0;
    while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
        const k = entriesArr(d).elements.?.items()[i];
        if (k.isEmpty()) continue;
        try insert(vm, od, k, k);
    }
    return out;
}

fn otherHas(vm: *Vm, rec: SetRecord, k: Value) Error!bool {
    return vm.toBoolean(try vm.call(rec.has, rec.set.asValue(), &.{k}));
}

/// The next key of the other set-like's iterator, canonicalized.
fn otherNext(vm: *Vm, it: *Vm.IteratorRecord) Error!?Value {
    const v = (try vm.iteratorStepValue(it)) orelse return null;
    return normalize(v);
}

fn setUnion(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.union");
    const rec = try getSetRecord(vm, arg(args, 0));
    var it = try vm.getIteratorFromMethod(rec.set.asValue(), rec.keys);
    const out = try newSetFrom(vm, d);
    const od = out.internal(CollectionData);
    while (try otherNext(vm, &it)) |k| {
        if (lookup(vm, od, k) == null) try insert(vm, od, k, k);
    }
    return out.asValue();
}

fn setIntersection(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.intersection");
    const rec = try getSetRecord(vm, arg(args, 0));
    const out = try newCollectionWithProto(vm, .set, vm.intrinsics.set_prototype);
    const od = out.internal(CollectionData);
    if (@as(f64, @floatFromInt(d.size)) <= rec.size) {
        var i: u32 = 0;
        while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
            const k = entriesArr(d).elements.?.items()[i];
            if (k.isEmpty()) continue;
            if (try otherHas(vm, rec, k)) {
                if (lookup(vm, od, k) == null) try insert(vm, od, k, k);
            }
        }
    } else {
        var it = try vm.getIteratorFromMethod(rec.set.asValue(), rec.keys);
        while (try otherNext(vm, &it)) |k| {
            if (lookup(vm, d, k) != null and lookup(vm, od, k) == null) try insert(vm, od, k, k);
        }
    }
    return out.asValue();
}

fn setDifference(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.difference");
    const rec = try getSetRecord(vm, arg(args, 0));
    const out = try newSetFrom(vm, d);
    const od = out.internal(CollectionData);
    if (@as(f64, @floatFromInt(d.size)) <= rec.size) {
        var i: u32 = 0;
        while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
            const k = entriesArr(d).elements.?.items()[i];
            if (k.isEmpty()) continue;
            if (try otherHas(vm, rec, k)) _ = remove(vm, od, k);
        }
    } else {
        var it = try vm.getIteratorFromMethod(rec.set.asValue(), rec.keys);
        while (try otherNext(vm, &it)) |k| _ = remove(vm, od, k);
    }
    return out.asValue();
}

fn setSymmetricDifference(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.symmetricDifference");
    const rec = try getSetRecord(vm, arg(args, 0));
    var it = try vm.getIteratorFromMethod(rec.set.asValue(), rec.keys);
    const out = try newSetFrom(vm, d);
    const od = out.internal(CollectionData);
    while (try otherNext(vm, &it)) |k| {
        if (lookup(vm, d, k) != null) {
            _ = remove(vm, od, k);
        } else if (lookup(vm, od, k) == null) try insert(vm, od, k, k);
    }
    return out.asValue();
}

fn setIsSubsetOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.isSubsetOf");
    const rec = try getSetRecord(vm, arg(args, 0));
    if (@as(f64, @floatFromInt(d.size)) > rec.size) return Value.false_;
    var i: u32 = 0;
    while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
        const k = entriesArr(d).elements.?.items()[i];
        if (k.isEmpty()) continue;
        if (!try otherHas(vm, rec, k)) return Value.false_;
    }
    return Value.true_;
}

fn setIsSupersetOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.isSupersetOf");
    const rec = try getSetRecord(vm, arg(args, 0));
    if (@as(f64, @floatFromInt(d.size)) < rec.size) return Value.false_;
    var it = try vm.getIteratorFromMethod(rec.set.asValue(), rec.keys);
    while (try otherNext(vm, &it)) |k| {
        if (lookup(vm, d, k) == null) {
            try vm.iteratorClose(it);
            return Value.false_;
        }
    }
    return Value.true_;
}

fn setIsDisjointFrom(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .set, "Set.prototype.isDisjointFrom");
    const rec = try getSetRecord(vm, arg(args, 0));
    if (@as(f64, @floatFromInt(d.size)) <= rec.size) {
        var i: u32 = 0;
        while (i < Vm.arrayLength(entriesArr(d))) : (i += 2) {
            const k = entriesArr(d).elements.?.items()[i];
            if (k.isEmpty()) continue;
            if (try otherHas(vm, rec, k)) return Value.false_;
        }
    } else {
        var it = try vm.getIteratorFromMethod(rec.set.asValue(), rec.keys);
        while (try otherNext(vm, &it)) |k| {
            if (lookup(vm, d, k) != null) {
                try vm.iteratorClose(it);
                return Value.false_;
            }
        }
    }
    return Value.true_;
}

fn setEntries(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisCollection(vm, this, .set, "Set.prototype.entries");
    return newIterator(vm, this, vm.intrinsics.set_iterator_prototype, 2);
}
fn setValues(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try thisCollection(vm, this, .set, "Set.prototype.values");
    return newIterator(vm, this, vm.intrinsics.set_iterator_prototype, 1);
}
fn setIteratorNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return iteratorNext(vm, this, vm.intrinsics.set_iterator_prototype);
}

// ----------------------------------------------------------- Weak*

/// CanBeHeldWeakly: objects and non-registered symbols.
fn canBeHeldWeakly(v: Value) bool {
    if (v.isObject()) return true;
    if (v.isSymbol()) return !Vm.asSymbol(v).registered;
    return false;
}

fn weakMapConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor WeakMap requires 'new'");
    const o = try newCollection(vm, new_target, .weak_map, vm.intrinsics.weak_map_prototype);
    const iterable = arg(args, 0);
    if (!iterable.isNullish()) try fillFromIterable(vm, o, iterable, "set", true);
    return o.asValue();
}

fn weakMapDelete(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_map, "WeakMap.prototype.delete");
    if (!canBeHeldWeakly(arg(args, 0))) return Value.false_;
    return Value.fromBool(remove(vm, d, arg(args, 0)));
}

fn weakMapGet(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_map, "WeakMap.prototype.get");
    if (!canBeHeldWeakly(arg(args, 0))) return Value.undefined_;
    const slot = lookup(vm, d, arg(args, 0)) orelse return Value.undefined_;
    return entriesArr(d).elements.?.items()[slot * 2 + 1];
}

fn weakMapHas(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_map, "WeakMap.prototype.has");
    if (!canBeHeldWeakly(arg(args, 0))) return Value.false_;
    return Value.fromBool(lookup(vm, d, arg(args, 0)) != null);
}

fn weakMapSet(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_map, "WeakMap.prototype.set");
    if (!canBeHeldWeakly(arg(args, 0))) return vm.throwTypeError("Invalid value used as weak map key");
    try insert(vm, d, arg(args, 0), arg(args, 1));
    return this;
}

fn weakSetConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor WeakSet requires 'new'");
    const o = try newCollection(vm, new_target, .weak_set, vm.intrinsics.weak_set_prototype);
    const iterable = arg(args, 0);
    if (!iterable.isNullish()) try fillFromIterable(vm, o, iterable, "add", false);
    return o.asValue();
}

fn weakSetAdd(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_set, "WeakSet.prototype.add");
    const k = arg(args, 0);
    if (!canBeHeldWeakly(k)) return vm.throwTypeError("Invalid value used in weak set");
    if (lookup(vm, d, k) == null) try insert(vm, d, k, k);
    return this;
}

fn weakSetDelete(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_set, "WeakSet.prototype.delete");
    if (!canBeHeldWeakly(arg(args, 0))) return Value.false_;
    return Value.fromBool(remove(vm, d, arg(args, 0)));
}

fn weakSetHas(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisCollection(vm, this, .weak_set, "WeakSet.prototype.has");
    if (!canBeHeldWeakly(arg(args, 0))) return Value.false_;
    return Value.fromBool(lookup(vm, d, arg(args, 0)) != null);
}
