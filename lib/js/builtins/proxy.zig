//! Proxy (§28.2): stage d. No proxy object exists before then; the
//! hooks are what the VM's internal methods dispatch to.
const std = @import("std");
const b = @import("../builtins.zig");
const heap = @import("../heap.zig");
const vmod = @import("../vm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const Key = b.Key;

pub fn install(vm: *Vm) Error!void {
    _ = vm;
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    _ = o;
    _ = m;
}

pub fn isCallable(_: *Vm, _: *Object) bool {
    return false;
}
pub fn isConstructor(_: *Vm, _: *Object) bool {
    return false;
}
pub fn isArray(_: *Vm, _: *Object) Error!bool {
    return false;
}
pub fn getOwnProperty(vm: *Vm, o: *Object, key: Key) Error!?vmod.Objects.Own {
    return vm.objects.getOwn(o, key);
}
pub fn get(vm: *Vm, o: *Object, key: Key, receiver: Value) Error!Value {
    _ = o;
    _ = key;
    _ = receiver;
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn set(vm: *Vm, _: *Object, _: Key, _: Value, _: Value) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn has(vm: *Vm, _: *Object, _: Key) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn defineOwnProperty(vm: *Vm, _: *Object, _: Key, _: Vm.Descriptor) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn delete(vm: *Vm, _: *Object, _: Key) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn ownKeys(vm: *Vm, _: *Object, _: *std.ArrayList(Key)) Error!void {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn getPrototypeOf(vm: *Vm, _: *Object) Error!Value {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn setPrototypeOf(vm: *Vm, _: *Object, _: Value) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn preventExtensions(vm: *Vm, _: *Object) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn isExtensible(vm: *Vm, _: *Object) Error!bool {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn call(vm: *Vm, _: *Object, _: Value, _: []const Value) Error!Value {
    return vm.throwTypeError("Proxy is not supported yet");
}
pub fn construct(vm: *Vm, _: *Object, _: []const Value, _: Value) Error!Value {
    return vm.throwTypeError("Proxy is not supported yet");
}
