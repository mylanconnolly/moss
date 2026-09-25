//! Function (§20.2): the constructor (source text compiled on the
//! spot), Function.prototype's apply/bind/call/toString and
//! @@hasInstance, and %ThrowTypeError%.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const compiler = @import("../compiler.zig");
const interp = @import("../interp.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.function_prototype;
    _ = try vm.objects.defineOwn(proto, .{ .atom = vm.atoms.length }, Value.fromInt(0), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try vm.objects.defineOwn(proto, .{ .atom = vm.atoms.name }, strValue(vm.atoms.empty), .{ .writable = false, .enumerable = false, .configurable = true });
    const ctor = try b.installConstructor(vm, "Function", 1, construct, proto);
    vm.intrinsics.function_ctor = ctor;
    _ = try vm.defineNative(proto, "apply", 2, apply);
    _ = try vm.defineNative(proto, "bind", 1, bind);
    _ = try vm.defineNative(proto, "call", 1, call);
    _ = try vm.defineNative(proto, "toString", 0, toString);
    const hi = try vm.newNative("[Symbol.hasInstance]", 1, hasInstance, Value.undefined_);
    _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.has_instance }, hi.asValue(), .frozen);
    // Function.prototype.caller/arguments: the poison-pill accessors.
    try vm.defineAccessor(proto, .{ .atom = vm.atoms.caller }, vm.intrinsics.throw_type_error, vm.intrinsics.throw_type_error, .{ .enumerable = false, .configurable = true });
    try vm.defineAccessor(proto, .{ .atom = vm.atoms.arguments }, vm.intrinsics.throw_type_error, vm.intrinsics.throw_type_error, .{ .enumerable = false, .configurable = true });
}

/// Function.prototype itself is callable and returns undefined.
pub fn prototypeCall(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.undefined_;
}

pub fn throwTypeError(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return vm.throwTypeError("'caller', 'callee', and 'arguments' properties may not be accessed on strict mode functions or the arguments objects for calls to them");
}

/// CreateDynamicFunction (§20.2.1.1.1): the parameters and body joined
/// into a function expression and compiled.
pub fn createDynamicFunction(vm: *Vm, args: []const Value, kind: enum { normal, generator, async, async_generator }, new_target: Value) Error!Value {
    var src: std.ArrayList(u8) = .empty;
    defer src.deinit(vm.meta);
    const prefix: []const u8 = switch (kind) {
        .normal => "(function anonymous(",
        .generator => "(function* anonymous(",
        .async => "(async function anonymous(",
        .async_generator => "(async function* anonymous(",
    };
    try src.appendSlice(vm.meta, prefix);
    const n = args.len;
    if (n > 1) {
        for (args[0 .. n - 1], 0..) |p, i| {
            if (i > 0) try src.append(vm.meta, ',');
            const s = try vm.toString(p);
            const u = try vm.utf8(s, vm.meta);
            defer vm.meta.free(u);
            try src.appendSlice(vm.meta, u);
        }
    }
    try src.appendSlice(vm.meta, "\n) {\n");
    if (n > 0) {
        const s = try vm.toString(args[n - 1]);
        const u = try vm.utf8(s, vm.meta);
        defer vm.meta.free(u);
        try src.appendSlice(vm.meta, u);
    }
    try src.appendSlice(vm.meta, "\n})");
    // The parameters and the body must each parse on their own: a
    // body that closes the function early is refused.
    const code = compiler.compile(vm.meta, &vm.heap, &vm.strings, src.items, .{ .name = "<Function>" }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return vm.throwSyntaxError(compiler.last_error),
    };
    if (code.data.functions.len != 1) return vm.throwSyntaxError("invalid function source");
    const fcode = code.data.functions[0];
    if (fcode.data.end - fcode.data.start != src.items.len - 2) return vm.throwSyntaxError("invalid function source");
    const f = try vm.newFunction(fcode, null, Value.undefined_);
    // The prototype from new.target.
    if (!new_target.isUndefined()) {
        const p = try vm.prototypeFromConstructor(new_target, vm.intrinsics.function_prototype);
        _ = try vm.objects.setProto(f, p.asValue());
    }
    return f.asValue();
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    return createDynamicFunction(vm, args, .normal, new_target);
}

fn apply(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!vm.isCallable(this)) return vm.throwTypeError("Function.prototype.apply was called on a non-function");
    const this_arg = arg(args, 0);
    const arr = arg(args, 1);
    if (arr.isNullish()) return vm.call(this, this_arg, &.{});
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(vm.meta);
    try vm.listFromArrayLike(arr, &list);
    return vm.call(this, this_arg, list.items);
}

fn call(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!vm.isCallable(this)) return vm.throwTypeError("Function.prototype.call was called on a non-function");
    return vm.call(this, arg(args, 0), if (args.len > 1) args[1..] else &.{});
}

fn bind(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!vm.isCallable(this)) return vm.throwTypeError("Bind must be called on a function");
    const target = asObject(this);
    const bound_args = try vm.arrayFromList(if (args.len > 1) args[1..] else &.{});
    const proto = try vm.getPrototypeOf(target);
    const o = try vm.objects.create(proto, .bound_function, @sizeOf(vmod.BoundData));
    o.internal(vmod.BoundData).* = .{ .target = target, .bound_this = arg(args, 0), .args = bound_args };
    // length: max(0, target.length - bound args) when target has a numeric length.
    var len: f64 = 0;
    if (try vm.hasOwnProperty(target, .{ .atom = vm.atoms.length })) {
        const l = try vm.get(target, .{ .atom = vm.atoms.length }, this);
        if (l.isNumber()) {
            const d = l.asNumber();
            if (std.math.isInf(d)) {
                len = if (d > 0) d else 0;
            } else if (!std.math.isNan(d)) {
                len = @max(0, @trunc(d) - @as(f64, @floatFromInt(Vm.arrayLength(bound_args))));
            }
        }
    }
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.length }, Value.fromF64(len), .{ .writable = false, .enumerable = false, .configurable = true });
    var name = try vm.get(target, .{ .atom = vm.atoms.name }, this);
    if (!name.isString()) name = strValue(vm.atoms.empty);
    const bound = try vm.concatStrings(try vm.strings.fromUtf8("bound "), asString(name));
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.name }, strValue(bound), .{ .writable = false, .enumerable = false, .configurable = true });
    return o.asValue();
}

fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!vm.isCallable(this)) return vm.throwTypeError("Function.prototype.toString requires that 'this' be a Function");
    return vm.functionSource(asObject(this));
}

fn hasInstance(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return Value.fromBool(try vm.ordinaryHasInstance(this, arg(args, 0)));
}
