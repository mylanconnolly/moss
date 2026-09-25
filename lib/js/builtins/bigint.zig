//! BigInt (§21.2): stage d. The hooks the VM's abstract operations
//! call are here; until the stage lands a BigInt literal throws.
const std = @import("std");
const b = @import("../builtins.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const String = b.String;

pub fn install(vm: *Vm) Error!void {
    _ = vm;
}

pub fn fromLiteral(vm: *Vm, s: *String) Error!Value {
    _ = s;
    return vm.throwSyntaxError("BigInt is not supported yet");
}
pub fn toNumber(vm: *Vm, v: Value) Error!f64 {
    _ = v;
    return vm.throwTypeError("BigInt is not supported yet");
}
pub fn isNonZero(v: Value) bool {
    _ = v;
    return true;
}
pub fn toString(vm: *Vm, v: Value, radix: u8) Error!*String {
    _ = v;
    _ = radix;
    return vm.throwTypeError("BigInt is not supported yet");
}
pub fn equals(a: Value, b_: Value) bool {
    return a.eqlBits(b_);
}
pub fn looseEqualsString(vm: *Vm, a: Value, s: *String) Error!bool {
    _ = vm;
    _ = a;
    _ = s;
    return false;
}
pub fn equalsNumber(a: Value, d: f64) bool {
    _ = a;
    _ = d;
    return false;
}
pub fn fromString(vm: *Vm, s: *String) Error!?Value {
    _ = vm;
    _ = s;
    return null;
}
pub fn compare(a: Value, b_: Value) std.math.Order {
    _ = a;
    _ = b_;
    return .eq;
}
pub fn compareNumber(a: Value, d: f64) std.math.Order {
    _ = a;
    _ = d;
    return .eq;
}
pub fn binary(vm: *Vm, op: Vm.ArithOp, a: Value, b_: Value) Error!Value {
    _ = op;
    _ = a;
    _ = b_;
    return vm.throwTypeError("Cannot mix BigInt and other types, use explicit conversions");
}
pub fn negate(vm: *Vm, a: Value) Error!Value {
    _ = a;
    return vm.throwTypeError("BigInt is not supported yet");
}
pub fn bitNot(vm: *Vm, a: Value) Error!Value {
    _ = a;
    return vm.throwTypeError("BigInt is not supported yet");
}
