//! %IteratorPrototype% (§27.1.2), the array and string iterators, and
//! the for-in enumerator's prototype.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;

pub fn install(vm: *Vm) Error!void {
    const ip = vm.intrinsics.iterator_prototype;
    _ = try vm.defineNativeSymbol(ip, vm.symbols.iterator, "[Symbol.iterator]", 0, returnThis);
    const aip = vm.intrinsics.array_iterator_prototype;
    vm.intrinsics.array_iterator_next = try vm.defineNative(aip, "next", 0, arrayIteratorNext);
    try b.setToStringTag(vm, aip, "Array Iterator");
    const sip = vm.intrinsics.string_iterator_prototype;
    _ = try vm.defineNative(sip, "next", 0, stringIteratorNext);
    try b.setToStringTag(vm, sip, "String Iterator");
}

fn returnThis(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

/// CreateArrayIterator.
pub fn createArrayIterator(vm: *Vm, target: Value, kind: vmod.IteratorKind) Error!Value {
    const o = try vm.objects.create(vm.intrinsics.array_iterator_prototype.asValue(), .iterator, @sizeOf(vmod.ArrayIteratorData));
    o.internal(vmod.ArrayIteratorData).* = .{ .target = target, .index = 0, .kind = kind };
    return o.asValue();
}

fn arrayIteratorNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject() or asObject(this).class != .iterator or asObject(this).shape.proto.bits != vm.intrinsics.array_iterator_prototype.asValue().bits) {
        // An iterator with the prototype changed still has the class.
        if (!this.isObject() or asObject(this).class != .iterator) return vm.throwTypeError("next method called on incompatible receiver");
    }
    const d = asObject(this).internal(vmod.ArrayIteratorData);
    if (d.target.isUndefined()) return vm.iterResult(Value.undefined_, true);
    const target = asObject(d.target);
    const len: u64 = if (target.class == .typed_array) try vm.lengthOfArrayLike(target) else try vm.lengthOfArrayLike(target);
    if (d.index >= len) {
        d.target = Value.undefined_;
        return vm.iterResult(Value.undefined_, true);
    }
    const i = d.index;
    d.index += 1;
    switch (d.kind) {
        .keys => return vm.iterResult(Value.fromInt(@intCast(i)), false),
        .values => return vm.iterResult(try vm.get(target, .{ .index = i }, d.target), false),
        .entries => {
            const v = try vm.get(target, .{ .index = i }, d.target);
            const pair = try vm.arrayFromList(&.{ Value.fromInt(@intCast(i)), v });
            return vm.iterResult(pair.asValue(), false);
        },
    }
}

pub fn createStringIterator(vm: *Vm, s: *b.String) Error!Value {
    const o = try vm.objects.create(vm.intrinsics.string_iterator_prototype.asValue(), .iterator, @sizeOf(vmod.StringIteratorData));
    o.internal(vmod.StringIteratorData).* = .{ .target = strValue(s), .index = 0 };
    return o.asValue();
}

fn stringIteratorNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject() or asObject(this).class != .iterator) return vm.throwTypeError("next method called on incompatible receiver");
    const d = asObject(this).internal(vmod.StringIteratorData);
    if (d.target.isUndefined()) return vm.iterResult(Value.undefined_, true);
    const s = try vm.strings.flatten(asString(d.target));
    if (d.index >= s.len) {
        d.target = Value.undefined_;
        return vm.iterResult(Value.undefined_, true);
    }
    const first = s.unitAt(d.index);
    var n: u32 = 1;
    if (first >= 0xd800 and first <= 0xdbff and d.index + 1 < s.len) {
        const second = s.unitAt(d.index + 1);
        if (second >= 0xdc00 and second <= 0xdfff) n = 2;
    }
    var units: [2]u16 = .{ first, if (n == 2) s.unitAt(d.index + 1) else 0 };
    const out = try vm.strings.fromUnits(units[0..n]);
    d.index += n;
    return vm.iterResult(strValue(out), false);
}
