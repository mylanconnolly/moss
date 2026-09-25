//! Proxy (§10.5, §28.2): every internal method as a trap with the
//! invariants the specification checks against the target, revocation,
//! and callability inherited from the target.
const std = @import("std");
const b = @import("../builtins.zig");
const heap = @import("../heap.zig");
const vmod = @import("../vm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const Key = b.Key;
const asObject = b.asObject;
const arg = b.arg;

pub const ProxyData = extern struct {
    target: Value, // null once revoked
    handler: Value,
    callable: bool,
    constructor: bool,
    _pad: [6]u8 = @splat(0),
};

pub fn install(vm: *Vm) Error!void {
    const ctor = try vm.newNativeNamed(b.strValue(try vm.atom("Proxy")), 2, proxyConstructor, Value.undefined_, true);
    try vm.defineValue(vm.global, "Proxy", ctor.asValue(), .hidden);
    _ = try vm.defineNative(ctor, "revocable", 2, revocable);
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    const d = o.internal(ProxyData);
    m.markValue(d.target);
    m.markValue(d.handler);
}

fn data(o: *Object) *ProxyData {
    return o.internal(ProxyData);
}

/// ProxyCreate (§10.5.14).
fn proxyCreate(vm: *Vm, target: Value, handler: Value) Error!*Object {
    if (!target.isObject()) return vm.throwTypeError("Cannot create proxy with a non-object as target");
    if (!handler.isObject()) return vm.throwTypeError("Cannot create proxy with a non-object as handler");
    const o = try vm.objects.create(Value.null_, .proxy, @sizeOf(ProxyData));
    o.internal(ProxyData).* = .{ .target = target, .handler = handler, .callable = vm.isCallable(target), .constructor = vm.isConstructor(target) };
    return o;
}

fn proxyConstructor(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor Proxy requires 'new'");
    return (try proxyCreate(vm, arg(args, 0), arg(args, 1))).asValue();
}

fn revocable(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = try proxyCreate(vm, arg(args, 0), arg(args, 1));
    const revoke = try vm.newNative("", 0, revokeFn, p.asValue());
    const result = try vm.newObject();
    try vm.defineValue(result, "proxy", p.asValue(), .default);
    try vm.defineValue(result, "revoke", revoke.asValue(), .default);
    return result.asValue();
}

fn revokeFn(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const fd = f.internal(vmod.FunctionData);
    const p = fd.data;
    if (p.isNull()) return Value.undefined_;
    fd.data = Value.null_;
    const d = data(asObject(p));
    d.target = Value.null_;
    d.handler = Value.null_;
    return Value.undefined_;
}

/// The handler and target of a live proxy, and the trap named.
const Live = struct { target: *Object, handler: Value, trap: Value };

fn live(vm: *Vm, o: *Object, trap_name: []const u8) Error!Live {
    const d = data(o);
    if (d.handler.isNull()) return vm.throwTypeErrorFmt("Cannot perform '{s}' on a proxy that has been revoked", .{trap_name});
    const trap = try vm.getMethod(d.handler, .{ .atom = try vm.atom(trap_name) });
    return .{ .target = asObject(d.target), .handler = d.handler, .trap = trap };
}

pub fn isCallable(_: *Vm, o: *Object) bool {
    return data(o).callable;
}
pub fn isConstructor(_: *Vm, o: *Object) bool {
    return data(o).constructor;
}

pub fn isArray(vm: *Vm, o: *Object) Error!bool {
    const d = data(o);
    if (d.handler.isNull()) return vm.throwTypeError("Cannot perform 'IsArray' on a proxy that has been revoked");
    return vm.isArray(d.target);
}

pub fn getPrototypeOf(vm: *Vm, o: *Object) Error!Value {
    const l = try live(vm, o, "getPrototypeOf");
    if (l.trap.isUndefined()) return vm.getPrototypeOf(l.target);
    const proto = try vm.call(l.trap, l.handler, &.{l.target.asValue()});
    if (!proto.isObject() and !proto.isNull()) return vm.throwTypeError("'getPrototypeOf' on proxy: trap returned neither object nor null");
    if (try vm.isExtensible(l.target)) return proto;
    const target_proto = try vm.getPrototypeOf(l.target);
    if (!vm.sameValue(proto, target_proto)) return vm.throwTypeError("'getPrototypeOf' on proxy: proxy target is non-extensible but the trap did not return its actual prototype");
    return proto;
}

pub fn setPrototypeOf(vm: *Vm, o: *Object, p: Value) Error!bool {
    const l = try live(vm, o, "setPrototypeOf");
    if (l.trap.isUndefined()) return vm.setPrototypeOf(l.target, p);
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{ l.target.asValue(), p }));
    if (!r) return false;
    if (try vm.isExtensible(l.target)) return true;
    const target_proto = try vm.getPrototypeOf(l.target);
    if (!vm.sameValue(p, target_proto)) return vm.throwTypeError("'setPrototypeOf' on proxy: trap returned truish for setting a new prototype on the non-extensible proxy target");
    return true;
}

pub fn isExtensible(vm: *Vm, o: *Object) Error!bool {
    const l = try live(vm, o, "isExtensible");
    if (l.trap.isUndefined()) return vm.isExtensible(l.target);
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{l.target.asValue()}));
    if (r != try vm.isExtensible(l.target)) return vm.throwTypeError("'isExtensible' on proxy: trap result does not reflect extensibility of proxy target");
    return r;
}

pub fn preventExtensions(vm: *Vm, o: *Object) Error!bool {
    const l = try live(vm, o, "preventExtensions");
    if (l.trap.isUndefined()) return vm.preventExtensions(l.target);
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{l.target.asValue()}));
    if (r and try vm.isExtensible(l.target)) return vm.throwTypeError("'preventExtensions' on proxy: trap returned truish but the proxy target is extensible");
    return r;
}

/// IsCompatiblePropertyDescriptor: ValidateAndApplyPropertyDescriptor
/// with no object (a pure check).
fn isCompatible(vm: *Vm, extensible: bool, desc: Vm.Descriptor, current: ?vmod.Objects.Own) bool {
    const cur = current orelse return extensible;
    if (desc.value == null and desc.get == null and desc.set == null and desc.writable == null and desc.enumerable == null and desc.configurable == null) return true;
    if (!cur.attrs.configurable) {
        if (desc.configurable orelse false) return false;
        if (desc.enumerable != null and desc.enumerable.? != cur.attrs.enumerable) return false;
        if (desc.isAccessor() and !cur.attrs.accessor) return false;
        if (desc.isData() and cur.attrs.accessor) return false;
        if (cur.attrs.accessor) {
            const acc = cur.val.asCell().as(vmod.Accessor);
            if (desc.get != null and !vm.sameValue(desc.get.?, acc.get)) return false;
            if (desc.set != null and !vm.sameValue(desc.set.?, acc.set)) return false;
        } else if (!cur.attrs.writable) {
            if (desc.writable orelse false) return false;
            if (desc.value != null and !vm.sameValue(desc.value.?, cur.val)) return false;
        }
    }
    return true;
}

pub fn getOwnProperty(vm: *Vm, o: *Object, key: Key) Error!?vmod.Objects.Own {
    const l = try live(vm, o, "getOwnPropertyDescriptor");
    if (l.trap.isUndefined()) return vm.getOwnProperty(l.target, key);
    const result = try vm.call(l.trap, l.handler, &.{ l.target.asValue(), try vm.keyToValue(key) });
    if (!result.isObject() and !result.isUndefined()) return vm.throwTypeError("'getOwnPropertyDescriptor' on proxy: trap returned neither object nor undefined");
    const target_desc = try vm.getOwnProperty(l.target, key);
    if (result.isUndefined()) {
        if (target_desc) |td| {
            if (!td.attrs.configurable) return vm.throwTypeError("'getOwnPropertyDescriptor' on proxy: trap returned undefined for property which is non-configurable in the proxy target");
            if (!try vm.isExtensible(l.target)) return vm.throwTypeError("'getOwnPropertyDescriptor' on proxy: trap returned undefined for property which exists in the non-extensible proxy target");
        }
        return null;
    }
    const extensible = try vm.isExtensible(l.target);
    var desc = try b.toPropertyDescriptor(vm, result);
    // CompletePropertyDescriptor.
    if (desc.isAccessor()) {
        if (desc.get == null) desc.get = Value.undefined_;
        if (desc.set == null) desc.set = Value.undefined_;
    } else {
        if (desc.value == null) desc.value = Value.undefined_;
        if (desc.writable == null) desc.writable = false;
    }
    if (desc.enumerable == null) desc.enumerable = false;
    if (desc.configurable == null) desc.configurable = false;
    if (!isCompatible(vm, extensible, desc, target_desc)) return vm.throwTypeError("'getOwnPropertyDescriptor' on proxy: trap returned descriptor for property that is incompatible with the existing property in the proxy target");
    if (!desc.configurable.?) {
        if (target_desc == null or target_desc.?.attrs.configurable) return vm.throwTypeError("'getOwnPropertyDescriptor' on proxy: trap reported non-configurability for property which is either non-existent or configurable in the proxy target");
        if (desc.writable != null and !desc.writable.? and target_desc.?.attrs.writable) return vm.throwTypeError("'getOwnPropertyDescriptor' on proxy: trap reported non-configurable and writable for property which is non-configurable, non-writable in the proxy target");
    }
    // The descriptor as an Own record: an accessor needs a cell.
    if (desc.isAccessor()) {
        const acc = try vm.newAccessor(desc.get.?, desc.set.?);
        return .{ .val = Value.fromCell(&acc.header), .attrs = .{ .accessor = true, .writable = false, .enumerable = desc.enumerable.?, .configurable = desc.configurable.? }, .slot = null };
    }
    return .{ .val = desc.value.?, .attrs = .{ .writable = desc.writable.?, .enumerable = desc.enumerable.?, .configurable = desc.configurable.? }, .slot = null };
}

pub fn defineOwnProperty(vm: *Vm, o: *Object, key: Key, desc: Vm.Descriptor) Error!bool {
    const l = try live(vm, o, "defineProperty");
    if (l.trap.isUndefined()) return vm.defineOwnProperty(l.target, key, desc, false);
    // FromPropertyDescriptor of the partial descriptor.
    const desc_obj = try vm.newObject();
    if (desc.value) |v| _ = try vm.createDataProperty(desc_obj, .{ .atom = vm.atoms.value }, v);
    if (desc.writable) |w| _ = try vm.createDataProperty(desc_obj, .{ .atom = vm.atoms.writable }, Value.fromBool(w));
    if (desc.get) |g| _ = try vm.createDataProperty(desc_obj, .{ .atom = vm.atoms.get }, g);
    if (desc.set) |s| _ = try vm.createDataProperty(desc_obj, .{ .atom = vm.atoms.set }, s);
    if (desc.enumerable) |e| _ = try vm.createDataProperty(desc_obj, .{ .atom = vm.atoms.enumerable }, Value.fromBool(e));
    if (desc.configurable) |c| _ = try vm.createDataProperty(desc_obj, .{ .atom = vm.atoms.configurable }, Value.fromBool(c));
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{ l.target.asValue(), try vm.keyToValue(key), desc_obj.asValue() }));
    if (!r) return false;
    const target_desc = try vm.getOwnProperty(l.target, key);
    const extensible = try vm.isExtensible(l.target);
    const setting_non_configurable = desc.configurable != null and !desc.configurable.?;
    if (target_desc == null) {
        if (!extensible) return vm.throwTypeError("'defineProperty' on proxy: trap returned truish for adding property to the non-extensible proxy target");
        if (setting_non_configurable) return vm.throwTypeError("'defineProperty' on proxy: trap returned truish for defining non-configurable property which is non-existent in the proxy target");
        return true;
    }
    if (!isCompatible(vm, extensible, desc, target_desc)) return vm.throwTypeError("'defineProperty' on proxy: trap returned truish for adding property that is incompatible with the existing property in the proxy target");
    if (setting_non_configurable and target_desc.?.attrs.configurable) return vm.throwTypeError("'defineProperty' on proxy: trap returned truish for defining non-configurable property which is configurable in the proxy target");
    if (!target_desc.?.attrs.accessor and !target_desc.?.attrs.configurable and target_desc.?.attrs.writable) {
        if (desc.writable != null and !desc.writable.?) return vm.throwTypeError("'defineProperty' on proxy: trap returned truish for defining non-configurable, non-writable property which is writable in the proxy target");
    }
    return true;
}

pub fn has(vm: *Vm, o: *Object, key: Key) Error!bool {
    const l = try live(vm, o, "has");
    if (l.trap.isUndefined()) return vm.hasProperty(l.target, key);
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{ l.target.asValue(), try vm.keyToValue(key) }));
    if (!r) {
        if (try vm.getOwnProperty(l.target, key)) |td| {
            if (!td.attrs.configurable) return vm.throwTypeError("'has' on proxy: trap returned falsish for property which exists in the proxy target as non-configurable");
            if (!try vm.isExtensible(l.target)) return vm.throwTypeError("'has' on proxy: trap returned falsish for property but the proxy target is not extensible");
        }
    }
    return r;
}

pub fn get(vm: *Vm, o: *Object, key: Key, receiver: Value) Error!Value {
    const l = try live(vm, o, "get");
    if (l.trap.isUndefined()) return vm.get(l.target, key, receiver);
    const r = try vm.call(l.trap, l.handler, &.{ l.target.asValue(), try vm.keyToValue(key), receiver });
    if (try vm.getOwnProperty(l.target, key)) |td| {
        if (!td.attrs.configurable) {
            if (!td.attrs.accessor and !td.attrs.writable and !vm.sameValue(r, td.val)) return vm.throwTypeError("'get' on proxy: property is a read-only and non-configurable data property on the proxy target but the proxy did not return its actual value");
            if (td.attrs.accessor) {
                const acc = td.val.asCell().as(vmod.Accessor);
                if (acc.get.isUndefined() and !r.isUndefined()) return vm.throwTypeError("'get' on proxy: property is a non-configurable accessor property on the proxy target and does not have a getter function, but the trap did not return undefined");
            }
        }
    }
    return r;
}

pub fn set(vm: *Vm, o: *Object, key: Key, v: Value, receiver: Value) Error!bool {
    const l = try live(vm, o, "set");
    if (l.trap.isUndefined()) return vm.set(l.target, key, v, receiver);
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{ l.target.asValue(), try vm.keyToValue(key), v, receiver }));
    if (!r) return false;
    if (try vm.getOwnProperty(l.target, key)) |td| {
        if (!td.attrs.configurable) {
            if (!td.attrs.accessor and !td.attrs.writable and !vm.sameValue(v, td.val)) return vm.throwTypeError("'set' on proxy: trap returned truish for property which exists in the proxy target as a non-configurable and non-writable data property with a different value");
            if (td.attrs.accessor) {
                const acc = td.val.asCell().as(vmod.Accessor);
                if (acc.set.isUndefined()) return vm.throwTypeError("'set' on proxy: trap returned truish for property which exists in the proxy target as a non-configurable and non-writable accessor property without a setter");
            }
        }
    }
    return true;
}

pub fn delete(vm: *Vm, o: *Object, key: Key) Error!bool {
    const l = try live(vm, o, "deleteProperty");
    if (l.trap.isUndefined()) return vm.deleteProperty(l.target, key);
    const r = vm.toBoolean(try vm.call(l.trap, l.handler, &.{ l.target.asValue(), try vm.keyToValue(key) }));
    if (!r) return false;
    if (try vm.getOwnProperty(l.target, key)) |td| {
        if (!td.attrs.configurable) return vm.throwTypeError("'deleteProperty' on proxy: trap returned truish for property which is non-configurable in the proxy target");
        if (!try vm.isExtensible(l.target)) return vm.throwTypeError("'deleteProperty' on proxy: trap returned truish for property but the proxy target is non-extensible");
    }
    return true;
}

pub fn ownKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
    const l = try live(vm, o, "ownKeys");
    if (l.trap.isUndefined()) return vm.ownPropertyKeys(l.target, out);
    const result = try vm.call(l.trap, l.handler, &.{l.target.asValue()});
    // CreateListFromArrayLike with String and Symbol only, no duplicates.
    if (!result.isObject()) return vm.throwTypeError("'ownKeys' on proxy: trap result is not an object");
    const ro = asObject(result);
    const len = try vm.lengthOfArrayLike(ro);
    var keys: std.ArrayList(Key) = .empty;
    defer keys.deinit(vm.meta);
    var i: u32 = 0;
    while (i < len) : (i += 1) {
        const v = try vm.get(ro, .{ .index = i }, result);
        if (!v.isString() and !v.isSymbol()) return vm.throwTypeError("'ownKeys' on proxy: trap result contains a non-string, non-symbol");
        const k = try vm.toPropertyKey(v);
        for (keys.items) |x| if (x.eql(k)) return vm.throwTypeError("'ownKeys' on proxy: trap returned duplicate entries");
        try keys.append(vm.meta, k);
    }
    const extensible = try vm.isExtensible(l.target);
    var target_keys: std.ArrayList(Key) = .empty;
    defer target_keys.deinit(vm.meta);
    try vm.ownPropertyKeys(l.target, &target_keys);
    var configurable_keys: std.ArrayList(Key) = .empty;
    defer configurable_keys.deinit(vm.meta);
    var nonconfigurable_keys: std.ArrayList(Key) = .empty;
    defer nonconfigurable_keys.deinit(vm.meta);
    for (target_keys.items) |k| {
        const d = try vm.getOwnProperty(l.target, k);
        if (d != null and !d.?.attrs.configurable) try nonconfigurable_keys.append(vm.meta, k) else try configurable_keys.append(vm.meta, k);
    }
    if (extensible and nonconfigurable_keys.items.len == 0) {
        try out.appendSlice(vm.meta, keys.items);
        return;
    }
    var unchecked: std.ArrayList(?Key) = .empty;
    defer unchecked.deinit(vm.meta);
    for (keys.items) |k| try unchecked.append(vm.meta, k);
    for (nonconfigurable_keys.items) |k| {
        if (!removeKey(&unchecked, k)) return vm.throwTypeError("'ownKeys' on proxy: trap result did not include a non-configurable key of the proxy target");
    }
    if (extensible) {
        try out.appendSlice(vm.meta, keys.items);
        return;
    }
    for (configurable_keys.items) |k| {
        if (!removeKey(&unchecked, k)) return vm.throwTypeError("'ownKeys' on proxy: trap result did not include a key of the non-extensible proxy target");
    }
    for (unchecked.items) |k| if (k != null) return vm.throwTypeError("'ownKeys' on proxy: trap returned extra keys but proxy target is non-extensible");
    try out.appendSlice(vm.meta, keys.items);
}

fn removeKey(list: *std.ArrayList(?Key), k: Key) bool {
    for (list.items) |*item| if (item.*) |x| if (x.eql(k)) {
        item.* = null;
        return true;
    };
    return false;
}

pub fn call(vm: *Vm, o: *Object, this: Value, args: []const Value) Error!Value {
    const l = try live(vm, o, "apply");
    if (l.trap.isUndefined()) return vm.call(l.target.asValue(), this, args);
    const arr = try vm.arrayFromList(args);
    return vm.call(l.trap, l.handler, &.{ l.target.asValue(), this, arr.asValue() });
}

pub fn construct(vm: *Vm, o: *Object, args: []const Value, new_target: Value) Error!Value {
    const l = try live(vm, o, "construct");
    if (l.trap.isUndefined()) return vm.construct(l.target.asValue(), args, new_target);
    const arr = try vm.arrayFromList(args);
    const r = try vm.call(l.trap, l.handler, &.{ l.target.asValue(), arr.asValue(), new_target });
    if (!r.isObject()) return vm.throwTypeError("proxy [[Construct]] must return an object");
    return r;
}
