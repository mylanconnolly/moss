//! The built-in objects (ECMA-262 §19–§28), one file per area under
//! builtins/. `install` populates a fresh realm's global object. Each
//! native is a Zig function taking `this`, the arguments and
//! `new.target`; the helpers here (argument access, constructor and
//! prototype wiring, `this` coercions) keep them short.
const std = @import("std");
const vmod = @import("vm.zig");
const heap = @import("heap.zig");
pub const Vm = vmod.Vm;
pub const Value = vmod.Value;
pub const Error = vmod.Error;
pub const Object = vmod.Object;
pub const String = vmod.String;
pub const Symbol = vmod.Symbol;
pub const Key = vmod.Key;
pub const NativeFn = vmod.NativeFn;
pub const Attributes = vmod.Attributes;
pub const asObject = Vm.asObject;
pub const asString = Vm.asString;
pub const strValue = Vm.strValue;

pub const object = @import("builtins/object.zig");
pub const function = @import("builtins/function.zig");
pub const array = @import("builtins/array.zig");
pub const string = @import("builtins/string.zig");
pub const number = @import("builtins/number.zig");
pub const symbol = @import("builtins/symbol.zig");
pub const math = @import("builtins/math.zig");
pub const json = @import("builtins/json.zig");
pub const errors = @import("builtins/error.zig");
pub const global = @import("builtins/global.zig");
pub const reflect = @import("builtins/reflect.zig");
pub const iterator = @import("builtins/iterator.zig");
pub const generator = @import("builtins/generator.zig");
pub const regexp = @import("builtins/regexp.zig");
pub const bigint = @import("builtins/bigint.zig");
pub const proxy = @import("builtins/proxy.zig");

pub fn install(vm: *Vm) Error!void {
    try object.install(vm);
    try function.install(vm);
    try errors.install(vm);
    try iterator.install(vm);
    try array.install(vm);
    try string.install(vm);
    try number.install(vm);
    try symbol.install(vm);
    try math.install(vm);
    try json.install(vm);
    try reflect.install(vm);
    try global.install(vm);
    try generator.install(vm);
    try regexp.install(vm);
    try bigint.install(vm);
    try proxy.install(vm);
}

pub fn traceExtra(o: *Object, m: *heap.Marker) void {
    switch (o.class) {
        .regexp => regexp.trace(o, m),
        .generator => generator.trace(o, m),
        .proxy => proxy.trace(o, m),
        else => {},
    }
}

pub fn finalizeExtra(vm: *Vm, o: *Object) void {
    switch (o.class) {
        .regexp => regexp.finalize(vm, o),
        .generator => generator.finalize(vm, o),
        else => {},
    }
}

// --------------------------------------------------------- helpers

pub fn arg(args: []const Value, i: usize) Value {
    return if (i < args.len) args[i] else Value.undefined_;
}

/// A constructor with its `prototype` wired both ways, installed on
/// the global object under `name`.
pub fn installConstructor(vm: *Vm, name: []const u8, length: u32, f: NativeFn, proto: *Object) Error!*Object {
    const ctor = try vm.newNativeNamed(strValue(try vm.atom(name)), length, f, Value.undefined_, true);
    _ = try vm.objects.defineOwn(ctor, .{ .atom = vm.atoms.prototype }, proto.asValue(), .frozen);
    _ = try vm.objects.defineOwn(proto, .{ .atom = vm.atoms.constructor }, ctor.asValue(), .hidden);
    try vm.defineValue(vm.global, name, ctor.asValue(), .hidden);
    return ctor;
}

pub fn setToStringTag(vm: *Vm, o: *Object, tag: []const u8) Error!void {
    _ = try vm.objects.defineOwn(o, .{ .symbol = vm.symbols.to_string_tag }, strValue(try vm.atom(tag)), .{ .writable = false, .enumerable = false, .configurable = true });
}

/// A property key from an argument.
pub fn keyArg(vm: *Vm, args: []const Value, i: usize) Error!Key {
    return vm.toPropertyKey(arg(args, i));
}

/// The number a `this` of Number.prototype methods carries.
pub fn thisNumber(vm: *Vm, this: Value) Error!f64 {
    if (this.isNumber()) return this.asNumber();
    if (this.isObject() and asObject(this).class == .number) return asObject(this).internal(vmod.PrimitiveData).value.asNumber();
    return vm.throwTypeError("Number.prototype method called on incompatible receiver");
}

pub fn thisString(vm: *Vm, this: Value) Error!*String {
    if (this.isString()) return asString(this);
    if (this.isObject() and asObject(this).class == .string) return asString(asObject(this).internal(vmod.PrimitiveData).value);
    return vm.throwTypeError("String.prototype method called on incompatible receiver");
}

/// RequireObjectCoercible then ToString (most String.prototype methods).
pub fn thisToString(vm: *Vm, this: Value) Error!*String {
    if (this.isString()) return asString(this);
    if (this.isNullish()) return vm.throwTypeError("String.prototype method called on null or undefined");
    return vm.toString(this);
}

/// ToPropertyDescriptor (§6.2.6.5).
pub fn toPropertyDescriptor(vm: *Vm, v: Value) Error!Vm.Descriptor {
    if (!v.isObject()) return vm.throwTypeError("Property description must be an object");
    const o = asObject(v);
    var d: Vm.Descriptor = .{};
    if (try vm.hasProperty(o, .{ .atom = vm.atoms.enumerable })) d.enumerable = vm.toBoolean(try vm.get(o, .{ .atom = vm.atoms.enumerable }, v));
    if (try vm.hasProperty(o, .{ .atom = vm.atoms.configurable })) d.configurable = vm.toBoolean(try vm.get(o, .{ .atom = vm.atoms.configurable }, v));
    if (try vm.hasProperty(o, .{ .atom = vm.atoms.value })) d.value = try vm.get(o, .{ .atom = vm.atoms.value }, v);
    if (try vm.hasProperty(o, .{ .atom = vm.atoms.writable })) d.writable = vm.toBoolean(try vm.get(o, .{ .atom = vm.atoms.writable }, v));
    if (try vm.hasProperty(o, .{ .atom = vm.atoms.get })) {
        const g = try vm.get(o, .{ .atom = vm.atoms.get }, v);
        if (!g.isUndefined() and !vm.isCallable(g)) return vm.throwTypeError("Getter must be a function");
        d.get = g;
    }
    if (try vm.hasProperty(o, .{ .atom = vm.atoms.set })) {
        const s = try vm.get(o, .{ .atom = vm.atoms.set }, v);
        if (!s.isUndefined() and !vm.isCallable(s)) return vm.throwTypeError("Setter must be a function");
        d.set = s;
    }
    if ((d.get != null or d.set != null) and (d.value != null or d.writable != null)) return vm.throwTypeError("Invalid property descriptor. Cannot both specify accessors and a value or writable attribute");
    return d;
}

/// FromPropertyDescriptor.
pub fn fromPropertyDescriptor(vm: *Vm, own: ?vmod.Objects.Own) Error!Value {
    const d = own orelse return Value.undefined_;
    const o = try vm.newObject();
    if (d.attrs.accessor) {
        const acc = d.val.asCell().as(vmod.Accessor);
        _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.get }, acc.get);
        _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.set }, acc.set);
    } else {
        _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.value }, d.val);
        _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.writable }, Value.fromBool(d.attrs.writable));
    }
    _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.enumerable }, Value.fromBool(d.attrs.enumerable));
    _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.configurable }, Value.fromBool(d.attrs.configurable));
    return o.asValue();
}

/// A relative index argument (§ Array.prototype.slice and friends):
/// clamps `arg` into [0, len].
pub fn relativeIndex(vm: *Vm, v: Value, len: f64, default: f64) Error!f64 {
    const r = if (v.isUndefined()) default else try vm.toIntegerOrInfinity(v);
    if (r < 0) return @max(len + r, 0);
    return @min(r, len);
}

/// The UTF-8 of a string in a stack-fallback buffer.
pub fn utf8Buf(vm: *Vm, s: *String, buf: []u8) Error![]const u8 {
    var fba = std.heap.FixedBufferAllocator.init(buf);
    return vm.strings.toUtf8(fba.allocator(), s) catch |e| switch (e) {
        error.OutOfMemory => return vm.strings.toUtf8(vm.meta, s),
    };
}
