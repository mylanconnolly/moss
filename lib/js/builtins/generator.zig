//! Generators and async functions (§27.3–27.7): stage c. Until then a
//! generator function can be created and inspected, and calling one
//! throws.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const bytecode = @import("../bytecode.zig");
const heap = @import("../heap.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;

pub fn install(vm: *Vm) Error!void {
    const gfp = vm.intrinsics.generator_function_prototype;
    const gp = vm.intrinsics.generator_prototype;
    _ = try vm.objects.defineOwn(gfp, .{ .atom = vm.atoms.prototype }, gp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try vm.objects.defineOwn(gp, .{ .atom = vm.atoms.constructor }, gfp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    try b.setToStringTag(vm, gfp, "GeneratorFunction");
    try b.setToStringTag(vm, gp, "Generator");
    try b.setToStringTag(vm, vm.intrinsics.async_function_prototype, "AsyncFunction");
}

pub fn call(vm: *Vm, f: *Object, this: Value, args: []const Value) Error!Value {
    _ = f;
    _ = this;
    _ = args;
    return vm.throwTypeError("generators and async functions are not supported yet");
}

pub fn op(vm: *Vm, frame: *vmod.Frame, insn: bytecode.Insn, regs: [*]Value) Error!?Value {
    _ = frame;
    _ = insn;
    _ = regs;
    return vm.throwTypeError("generators and async functions are not supported yet");
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    _ = o;
    _ = m;
}
pub fn finalize(vm: *Vm, o: *Object) void {
    _ = vm;
    _ = o;
}
