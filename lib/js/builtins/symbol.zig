//! Symbol (§20.4).
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const string = @import("string.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const asObject = b.asObject;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.symbol_prototype;
    const ctor = try b.installConstructor(vm, "Symbol", 0, construct, proto);
    inline for (.{ .{ "iterator", "iterator" }, .{ "asyncIterator", "async_iterator" }, .{ "hasInstance", "has_instance" }, .{ "toPrimitive", "to_primitive" }, .{ "toStringTag", "to_string_tag" }, .{ "species", "species" }, .{ "isConcatSpreadable", "is_concat_spreadable" }, .{ "unscopables", "unscopables" }, .{ "match", "match" }, .{ "matchAll", "match_all" }, .{ "replace", "replace" }, .{ "search", "search" }, .{ "split", "split" }, .{ "dispose", "dispose" }, .{ "asyncDispose", "async_dispose" } }) |e| {
        try vm.defineValue(ctor, e[0], Value.fromCell(&@field(vm.symbols, e[1]).header), .frozen);
    }
    _ = try vm.defineNative(ctor, "for", 1, symbolFor);
    _ = try vm.defineNative(ctor, "keyFor", 1, keyFor);
    _ = try vm.defineNative(proto, "toString", 0, toString);
    _ = try vm.defineNative(proto, "valueOf", 0, valueOf);
    try vm.defineGetter(proto, "description", descriptionGetter);
    const tp = try vm.newNative("[Symbol.toPrimitive]", 1, valueOf, Value.undefined_);
    _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.to_primitive }, tp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    try b.setToStringTag(vm, proto, "Symbol");
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (!new_target.isUndefined()) return vm.throwTypeError("Symbol is not a constructor");
    const d = arg(args, 0);
    const desc: ?*b.String = if (d.isUndefined()) null else try vm.toString(d);
    const s = try vm.newSymbol(desc);
    return Value.fromCell(&s.header);
}

fn thisSymbol(vm: *Vm, this: Value) Error!Value {
    if (this.isSymbol()) return this;
    if (this.isObject() and asObject(this).class == .symbol) return asObject(this).internal(vmod.PrimitiveData).value;
    return vm.throwTypeError("Symbol.prototype method called on incompatible receiver");
}

fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const s = try thisSymbol(vm, this);
    return strValue(try string.symbolDescriptiveString(vm, s));
}
fn valueOf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return thisSymbol(vm, this);
}
fn descriptionGetter(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const s = try thisSymbol(vm, this);
    const d = Vm.asSymbol(s).description orelse return Value.undefined_;
    return strValue(d);
}

fn symbolFor(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const key = try vm.strings.intern(try vm.toString(arg(args, 0)));
    if (vm.symbol_registry.get(key)) |s| return Value.fromCell(&s.header);
    const s = try vm.newSymbol(key);
    s.registered = true;
    try vm.symbol_registry.put(vm.meta, key, s);
    return Value.fromCell(&s.header);
}

fn keyFor(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isSymbol()) return vm.throwTypeError("Symbol.keyFor requires a symbol");
    const s = Vm.asSymbol(v);
    if (!s.registered) return Value.undefined_;
    return strValue(s.description.?);
}
