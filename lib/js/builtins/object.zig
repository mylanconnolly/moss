//! Object (§20.1): the constructor's reflection functions and
//! Object.prototype, with Annex B's __proto__ and legacy accessors.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
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
    const proto = vm.intrinsics.object_prototype;
    const ctor = try b.installConstructor(vm, "Object", 1, construct, proto);
    vm.intrinsics.object_ctor = ctor;
    _ = try vm.defineNative(ctor, "assign", 2, assign);
    _ = try vm.defineNative(ctor, "create", 2, create);
    _ = try vm.defineNative(ctor, "defineProperties", 2, defineProperties);
    _ = try vm.defineNative(ctor, "defineProperty", 3, defineProperty);
    _ = try vm.defineNative(ctor, "entries", 1, entries);
    _ = try vm.defineNative(ctor, "freeze", 1, freeze);
    _ = try vm.defineNative(ctor, "fromEntries", 1, fromEntries);
    _ = try vm.defineNative(ctor, "getOwnPropertyDescriptor", 2, getOwnPropertyDescriptor);
    _ = try vm.defineNative(ctor, "getOwnPropertyDescriptors", 1, getOwnPropertyDescriptors);
    _ = try vm.defineNative(ctor, "getOwnPropertyNames", 1, getOwnPropertyNames);
    _ = try vm.defineNative(ctor, "getOwnPropertySymbols", 1, getOwnPropertySymbols);
    _ = try vm.defineNative(ctor, "getPrototypeOf", 1, getPrototypeOf);
    _ = try vm.defineNative(ctor, "hasOwn", 2, hasOwn);
    _ = try vm.defineNative(ctor, "is", 2, is);
    _ = try vm.defineNative(ctor, "isExtensible", 1, isExtensible);
    _ = try vm.defineNative(ctor, "isFrozen", 1, isFrozen);
    _ = try vm.defineNative(ctor, "isSealed", 1, isSealed);
    _ = try vm.defineNative(ctor, "keys", 1, keys);
    _ = try vm.defineNative(ctor, "preventExtensions", 1, preventExtensions);
    _ = try vm.defineNative(ctor, "seal", 1, seal);
    _ = try vm.defineNative(ctor, "setPrototypeOf", 2, setPrototypeOf);
    _ = try vm.defineNative(ctor, "values", 1, values);
    _ = try vm.defineNative(ctor, "groupBy", 2, groupBy);

    _ = try vm.defineNative(proto, "hasOwnProperty", 1, hasOwnProperty);
    _ = try vm.defineNative(proto, "isPrototypeOf", 1, isPrototypeOf);
    _ = try vm.defineNative(proto, "propertyIsEnumerable", 1, propertyIsEnumerable);
    _ = try vm.defineNative(proto, "toLocaleString", 0, toLocaleString);
    _ = try vm.defineNative(proto, "toString", 0, toString);
    _ = try vm.defineNative(proto, "valueOf", 0, valueOf);
    _ = try vm.defineNative(proto, "__defineGetter__", 2, defineGetterLegacy);
    _ = try vm.defineNative(proto, "__defineSetter__", 2, defineSetterLegacy);
    _ = try vm.defineNative(proto, "__lookupGetter__", 1, lookupGetterLegacy);
    _ = try vm.defineNative(proto, "__lookupSetter__", 1, lookupSetterLegacy);
    const pg = try vm.newNative("get __proto__", 0, protoGetter, Value.undefined_);
    const ps = try vm.newNative("set __proto__", 1, protoSetter, Value.undefined_);
    try vm.defineAccessor(proto, .{ .atom = vm.atoms.__proto__ }, pg, ps, .{ .enumerable = false, .configurable = true });
}

fn construct(vm: *Vm, this: Value, args: []const Value, new_target: Value) Error!Value {
    _ = this;
    if (!new_target.isUndefined() and !new_target.eqlBits(vm.intrinsics.object_ctor.asValue())) {
        return (try vm.createFromConstructor(new_target, vm.intrinsics.object_prototype, .ordinary, 0)).asValue();
    }
    const v = arg(args, 0);
    if (v.isNullish()) return (try vm.newObject()).asValue();
    return (try vm.toObject(v)).asValue();
}

fn assign(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = this;
    const to = try vm.toObject(arg(args, 0));
    for (args[@min(1, args.len)..]) |src| {
        if (src.isNullish()) continue;
        const from = try vm.toObject(src);
        var list: std.ArrayList(Key) = .empty;
        defer list.deinit(vm.meta);
        try vm.ownPropertyKeys(from, &list);
        for (list.items) |k| {
            const own = (try vm.getOwnProperty(from, k)) orelse continue;
            if (!own.attrs.enumerable) continue;
            const v = try vm.get(from, k, from.asValue());
            if (!try vm.set(to, k, v, to.asValue())) return vm.throwTypeError("Cannot assign to read only property");
        }
    }
    return to.asValue();
}

fn create(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = this;
    const p = arg(args, 0);
    if (!p.isObject() and !p.isNull()) return vm.throwTypeError("Object prototype may only be an Object or null");
    const o = try vm.newObjectWithProto(p);
    const props = arg(args, 1);
    if (!props.isUndefined()) try objectDefineProperties(vm, o, props);
    return o.asValue();
}

fn objectDefineProperties(vm: *Vm, o: *Object, props_v: Value) Error!void {
    const props = try vm.toObject(props_v);
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(props, &list);
    var descs: std.ArrayList(struct { k: Key, d: Vm.Descriptor }) = .empty;
    defer descs.deinit(vm.meta);
    for (list.items) |k| {
        const own = (try vm.getOwnProperty(props, k)) orelse continue;
        if (!own.attrs.enumerable) continue;
        const dv = try vm.get(props, k, props.asValue());
        try descs.append(vm.meta, .{ .k = k, .d = try b.toPropertyDescriptor(vm, dv) });
    }
    for (descs.items) |e| _ = try vm.defineOwnProperty(o, e.k, e.d, true);
}

fn defineProperties(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = this;
    const ov = arg(args, 0);
    if (!ov.isObject()) return vm.throwTypeError("Object.defineProperties called on non-object");
    try objectDefineProperties(vm, asObject(ov), arg(args, 1));
    return ov;
}

fn defineProperty(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = this;
    const ov = arg(args, 0);
    if (!ov.isObject()) return vm.throwTypeError("Object.defineProperty called on non-object");
    const key = try b.keyArg(vm, args, 1);
    const desc = try b.toPropertyDescriptor(vm, arg(args, 2));
    _ = try vm.defineOwnProperty(asObject(ov), key, desc, true);
    return ov;
}

const EnumKind = enum { keys, values, entries };

fn enumerableOwn(vm: *Vm, v: Value, kind: EnumKind) Error!Value {
    const o = try vm.toObject(v);
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(o, &list);
    const out = try vm.newArray(0);
    for (list.items) |k| {
        if (k == .symbol) continue;
        const own = (try vm.getOwnProperty(o, k)) orelse continue;
        if (!own.attrs.enumerable) continue;
        const ks = try vm.keyToValue(k);
        switch (kind) {
            .keys => try vm.arrayPush(out, ks),
            .values => try vm.arrayPush(out, try vm.get(o, k, o.asValue())),
            .entries => {
                const val = try vm.get(o, k, o.asValue());
                const pair = try vm.arrayFromList(&.{ ks, val });
                try vm.arrayPush(out, pair.asValue());
            },
        }
    }
    return out.asValue();
}

fn entries(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return enumerableOwn(vm, arg(args, 0), .entries);
}
fn keys(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return enumerableOwn(vm, arg(args, 0), .keys);
}
fn values(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return enumerableOwn(vm, arg(args, 0), .values);
}

/// SetIntegrityLevel (§7.3.15).
pub fn setIntegrityLevel(vm: *Vm, o: *Object, frozen: bool) Error!void {
    if (!try vm.preventExtensions(o)) return vm.throwTypeError("Cannot prevent extensions");
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(o, &list);
    for (list.items) |k| {
        if (frozen) {
            const own = (try vm.getOwnProperty(o, k)) orelse continue;
            if (own.attrs.accessor) {
                _ = try vm.defineOwnProperty(o, k, .{ .configurable = false }, true);
            } else {
                _ = try vm.defineOwnProperty(o, k, .{ .configurable = false, .writable = false }, true);
            }
        } else {
            _ = try vm.defineOwnProperty(o, k, .{ .configurable = false }, true);
        }
    }
}

/// TestIntegrityLevel.
fn testIntegrityLevel(vm: *Vm, o: *Object, frozen: bool) Error!bool {
    if (try vm.isExtensible(o)) return false;
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(o, &list);
    for (list.items) |k| {
        const own = (try vm.getOwnProperty(o, k)) orelse continue;
        if (own.attrs.configurable) return false;
        if (frozen and !own.attrs.accessor and own.attrs.writable) return false;
    }
    return true;
}

fn freeze(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return v;
    try setIntegrityLevel(vm, asObject(v), true);
    return v;
}
fn seal(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return v;
    try setIntegrityLevel(vm, asObject(v), false);
    return v;
}
fn isFrozen(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return Value.true_;
    return Value.fromBool(try testIntegrityLevel(vm, asObject(v), true));
}
fn isSealed(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return Value.true_;
    return Value.fromBool(try testIntegrityLevel(vm, asObject(v), false));
}
fn preventExtensions(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return v;
    if (!try vm.preventExtensions(asObject(v))) return vm.throwTypeError("Cannot prevent extensions");
    return v;
}
fn isExtensible(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return Value.false_;
    return Value.fromBool(try vm.isExtensible(asObject(v)));
}

fn fromEntries(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const iterable = arg(args, 0);
    if (iterable.isNullish()) return vm.throwTypeError("Object.fromEntries requires an iterable");
    const o = try vm.newObject();
    var rec = try vm.getIterator(iterable);
    while (try vm.iteratorStepValue(&rec)) |entry| {
        if (!entry.isObject()) {
            vm.iteratorCloseThrow(rec);
            return vm.throwTypeError("Iterator value is not an entry object");
        }
        const k = vm.get(asObject(entry), .{ .index = 0 }, entry) catch |e| {
            vm.iteratorCloseThrow(rec);
            return e;
        };
        const v = vm.get(asObject(entry), .{ .index = 1 }, entry) catch |e| {
            vm.iteratorCloseThrow(rec);
            return e;
        };
        const key = vm.toPropertyKey(k) catch |e| {
            vm.iteratorCloseThrow(rec);
            return e;
        };
        _ = try vm.createDataProperty(o, key, v);
    }
    return o.asValue();
}

fn getOwnPropertyDescriptor(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(arg(args, 0));
    const key = try b.keyArg(vm, args, 1);
    return b.fromPropertyDescriptor(vm, try vm.getOwnProperty(o, key));
}

fn getOwnPropertyDescriptors(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(arg(args, 0));
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(o, &list);
    const out = try vm.newObject();
    for (list.items) |k| {
        const d = try b.fromPropertyDescriptor(vm, try vm.getOwnProperty(o, k));
        if (!d.isUndefined()) _ = try vm.createDataProperty(out, k, d);
    }
    return out.asValue();
}

fn ownKeysOf(vm: *Vm, v: Value, symbols: bool) Error!Value {
    const o = try vm.toObject(v);
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(o, &list);
    const out = try vm.newArray(0);
    for (list.items) |k| {
        if ((k == .symbol) != symbols) continue;
        try vm.arrayPush(out, try vm.keyToValue(k));
    }
    return out.asValue();
}

fn getOwnPropertyNames(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return ownKeysOf(vm, arg(args, 0), false);
}
fn getOwnPropertySymbols(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return ownKeysOf(vm, arg(args, 0), true);
}

fn getPrototypeOf(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(arg(args, 0));
    return vm.getPrototypeOf(o);
}

fn setPrototypeOf(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (v.isNullish()) return vm.throwTypeError("Object.setPrototypeOf called on null or undefined");
    const p = arg(args, 1);
    if (!p.isObject() and !p.isNull()) return vm.throwTypeError("Object prototype may only be an Object or null");
    if (!v.isObject()) return v;
    if (!try vm.setPrototypeOf(asObject(v), p)) return vm.throwTypeError("Cannot set prototype");
    return v;
}

fn hasOwn(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(arg(args, 0));
    const key = try b.keyArg(vm, args, 1);
    return Value.fromBool(try vm.hasOwnProperty(o, key));
}

fn is(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromBool(vm.sameValue(arg(args, 0), arg(args, 1)));
}

fn groupBy(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const items = arg(args, 0);
    const cb = arg(args, 1);
    if (items.isNullish()) return vm.throwTypeError("Object.groupBy called on null or undefined");
    if (!vm.isCallable(cb)) return vm.throwTypeError("callback is not a function");
    const out = try vm.newObjectWithProto(Value.null_);
    var rec = try vm.getIterator(items);
    var k: f64 = 0;
    while (try vm.iteratorStepValue(&rec)) |v| {
        const kv = vm.call(cb, Value.undefined_, &.{ v, Value.fromF64(k) }) catch |e| {
            vm.iteratorCloseThrow(rec);
            return e;
        };
        const key = vm.toPropertyKey(kv) catch |e| {
            vm.iteratorCloseThrow(rec);
            return e;
        };
        var group = try vm.get(out, key, out.asValue());
        if (group.isUndefined()) {
            group = (try vm.newArray(0)).asValue();
            _ = try vm.createDataProperty(out, key, group);
        }
        try vm.arrayPush(asObject(group), v);
        k += 1;
    }
    return out.asValue();
}

// ---------------------------------------------------------- prototype

fn hasOwnProperty(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const key = try b.keyArg(vm, args, 0);
    const o = try vm.toObject(this);
    return Value.fromBool(try vm.hasOwnProperty(o, key));
}

fn isPrototypeOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return Value.false_;
    const o = try vm.toObject(this);
    var cur = try vm.getPrototypeOf(asObject(v));
    while (cur.isObject()) {
        if (asObject(cur) == o) return Value.true_;
        cur = try vm.getPrototypeOf(asObject(cur));
    }
    return Value.false_;
}

fn propertyIsEnumerable(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const key = try b.keyArg(vm, args, 0);
    const o = try vm.toObject(this);
    const own = (try vm.getOwnProperty(o, key)) orelse return Value.false_;
    return Value.fromBool(own.attrs.enumerable);
}

fn toLocaleString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return vm.invoke(this, .{ .atom = vm.atoms.toString }, &.{});
}

/// Object.prototype.toString (§20.1.3.6).
pub fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (this.isUndefined()) return vm.str("[object Undefined]");
    if (this.isNull()) return vm.str("[object Null]");
    const o = try vm.toObject(this);
    var builtin_tag: []const u8 = "Object";
    if (try vm.isArray(this)) {
        builtin_tag = "Array";
    } else switch (o.class) {
        .function, .bound_function => builtin_tag = "Function",
        .error_ => builtin_tag = "Error",
        .boolean => builtin_tag = "Boolean",
        .number => builtin_tag = "Number",
        .string => builtin_tag = "String",
        .date => builtin_tag = "Date",
        .regexp => builtin_tag = "RegExp",
        .arguments => builtin_tag = "Arguments",
        .proxy => if (vm.isCallable(this)) {
            builtin_tag = "Function";
        },
        else => {},
    }
    const tag = try vm.get(o, .{ .symbol = vm.symbols.to_string_tag }, this);
    var buf: [128]u8 = undefined;
    const t = if (tag.isString()) (b.utf8Buf(vm, asString(tag), &buf) catch builtin_tag) else builtin_tag;
    var out: [160]u8 = undefined;
    const s = std.fmt.bufPrint(&out, "[object {s}]", .{t}) catch return vm.str("[object Object]");
    return vm.str(s);
}

fn valueOf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return (try vm.toObject(this)).asValue();
}

fn protoGetter(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    return vm.getPrototypeOf(o);
}

fn protoSetter(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (this.isNullish()) return vm.throwTypeError("Object.prototype.__proto__ called on null or undefined");
    const p = arg(args, 0);
    if (!p.isObject() and !p.isNull()) return Value.undefined_;
    if (!this.isObject()) return Value.undefined_;
    if (!try vm.setPrototypeOf(asObject(this), p)) return vm.throwTypeError("Cannot set prototype");
    return Value.undefined_;
}

fn defineGetterLegacy(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const g = arg(args, 1);
    if (!vm.isCallable(g)) return vm.throwTypeError("Getter must be a function");
    const key = try b.keyArg(vm, args, 0);
    _ = try vm.defineOwnProperty(o, key, .{ .get = g, .enumerable = true, .configurable = true }, true);
    return Value.undefined_;
}
fn defineSetterLegacy(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try vm.toObject(this);
    const s = arg(args, 1);
    if (!vm.isCallable(s)) return vm.throwTypeError("Setter must be a function");
    const key = try b.keyArg(vm, args, 0);
    _ = try vm.defineOwnProperty(o, key, .{ .set = s, .enumerable = true, .configurable = true }, true);
    return Value.undefined_;
}
fn lookupLegacy(vm: *Vm, this: Value, args: []const Value, getter: bool) Error!Value {
    var o = try vm.toObject(this);
    const key = try b.keyArg(vm, args, 0);
    while (true) {
        if (try vm.getOwnProperty(o, key)) |own| {
            if (own.attrs.accessor) {
                const acc = own.val.asCell().as(vmod.Accessor);
                return if (getter) acc.get else acc.set;
            }
            return Value.undefined_;
        }
        const p = try vm.getPrototypeOf(o);
        if (!p.isObject()) return Value.undefined_;
        o = asObject(p);
    }
}
fn lookupGetterLegacy(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return lookupLegacy(vm, this, args, true);
}
fn lookupSetterLegacy(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return lookupLegacy(vm, this, args, false);
}
