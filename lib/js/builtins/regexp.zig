//! RegExp (§22.2): stage d. A literal makes an object carrying its
//! source and flags; matching is not implemented yet.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.regexp_prototype;
    _ = try b.installConstructor(vm, "RegExp", 2, construct, proto);
    _ = try vm.defineNative(proto, "exec", 1, exec);
    _ = try vm.defineNative(proto, "test", 1, exec);
    _ = try vm.defineNative(proto, "toString", 0, toString);
}

pub fn create(vm: *Vm, pattern: Value, flags: Value) Error!Value {
    const o = try vm.objects.create(vm.intrinsics.regexp_prototype.asValue(), .regexp, 0);
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.source }, pattern, .hidden);
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.flags }, flags, .hidden);
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.lastIndex }, Value.fromInt(0), .{ .writable = true, .enumerable = false, .configurable = false });
    return o.asValue();
}

fn construct(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const p = arg(args, 0);
    const pattern = if (p.isUndefined()) strValue(vm.atoms.empty) else strValue(try vm.toString(p));
    const f = arg(args, 1);
    const flags = if (f.isUndefined()) strValue(vm.atoms.empty) else strValue(try vm.toString(f));
    return create(vm, pattern, flags);
}

fn exec(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return vm.throwTypeError("regular expressions are not supported yet");
}

fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype.toString requires an object");
    const o = b.asObject(this);
    const src = try vm.toString(try vm.get(o, .{ .atom = vm.atoms.source }, this));
    const flags = try vm.toString(try vm.get(o, .{ .atom = vm.atoms.flags }, this));
    const slash = try vm.strings.fromUtf8("/");
    return strValue(try vm.concatStrings(try vm.concatStrings(try vm.concatStrings(slash, src), slash), flags));
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    _ = o;
    _ = m;
}
pub fn finalize(vm: *Vm, o: *Object) void {
    _ = vm;
    _ = o;
}
