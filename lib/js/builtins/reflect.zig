//! Reflect (§28.1).
const std = @import("std");
const b = @import("../builtins.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Key = b.Key;
const asObject = b.asObject;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const r = try vm.newObject();
    try vm.defineValue(vm.global, "Reflect", r.asValue(), .hidden);
    try b.setToStringTag(vm, r, "Reflect");
    _ = try vm.defineNative(r, "apply", 3, apply);
    _ = try vm.defineNative(r, "construct", 2, construct);
    _ = try vm.defineNative(r, "defineProperty", 3, defineProperty);
    _ = try vm.defineNative(r, "deleteProperty", 2, deleteProperty);
    _ = try vm.defineNative(r, "get", 2, get);
    _ = try vm.defineNative(r, "getOwnPropertyDescriptor", 2, getOwnPropertyDescriptor);
    _ = try vm.defineNative(r, "getPrototypeOf", 1, getPrototypeOf);
    _ = try vm.defineNative(r, "has", 2, has);
    _ = try vm.defineNative(r, "isExtensible", 1, isExtensible);
    _ = try vm.defineNative(r, "ownKeys", 1, ownKeys);
    _ = try vm.defineNative(r, "preventExtensions", 1, preventExtensions);
    _ = try vm.defineNative(r, "set", 3, set);
    _ = try vm.defineNative(r, "setPrototypeOf", 2, setPrototypeOf);
}

fn target(vm: *Vm, args: []const Value) Error!*b.Object {
    const t = arg(args, 0);
    if (!t.isObject()) return vm.throwTypeError("Reflect method called on non-object");
    return asObject(t);
}

fn apply(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = arg(args, 0);
    if (!vm.isCallable(f)) return vm.throwTypeError("Reflect.apply target is not callable");
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(vm.meta);
    try vm.listFromArrayLike(arg(args, 2), &list);
    return vm.call(f, arg(args, 1), list.items);
}

fn construct(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = arg(args, 0);
    if (!vm.isConstructor(f)) return vm.throwTypeError("Reflect.construct target is not a constructor");
    const nt = if (args.len > 2) args[2] else f;
    if (!vm.isConstructor(nt)) return vm.throwTypeError("Reflect.construct newTarget is not a constructor");
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(vm.meta);
    try vm.listFromArrayLike(arg(args, 1), &list);
    return vm.construct(f, list.items, nt);
}

fn defineProperty(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const key = try b.keyArg(vm, args, 1);
    const desc = try b.toPropertyDescriptor(vm, arg(args, 2));
    return Value.fromBool(try vm.defineOwnProperty(t, key, desc, false));
}

fn deleteProperty(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const key = try b.keyArg(vm, args, 1);
    return Value.fromBool(try vm.deleteProperty(t, key));
}

fn get(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const key = try b.keyArg(vm, args, 1);
    const receiver = if (args.len > 2) args[2] else t.asValue();
    return vm.get(t, key, receiver);
}

fn getOwnPropertyDescriptor(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const key = try b.keyArg(vm, args, 1);
    return b.fromPropertyDescriptor(vm, try vm.getOwnProperty(t, key));
}

fn getPrototypeOf(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return vm.getPrototypeOf(try target(vm, args));
}

fn has(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const key = try b.keyArg(vm, args, 1);
    return Value.fromBool(try vm.hasProperty(t, key));
}

fn isExtensible(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromBool(try vm.isExtensible(try target(vm, args)));
}

fn ownKeys(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    var list: std.ArrayList(Key) = .empty;
    defer list.deinit(vm.meta);
    try vm.ownPropertyKeys(t, &list);
    const out = try vm.newArray(0);
    for (list.items) |k| try vm.arrayPush(out, try vm.keyToValue(k));
    return out.asValue();
}

fn preventExtensions(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromBool(try vm.preventExtensions(try target(vm, args)));
}

fn set(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const key = try b.keyArg(vm, args, 1);
    const receiver = if (args.len > 3) args[3] else t.asValue();
    return Value.fromBool(try vm.set(t, key, arg(args, 2), receiver));
}

fn setPrototypeOf(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const t = try target(vm, args);
    const p = arg(args, 1);
    if (!p.isObject() and !p.isNull()) return vm.throwTypeError("Object prototype may only be an Object or null");
    return Value.fromBool(try vm.setPrototypeOf(t, p));
}
