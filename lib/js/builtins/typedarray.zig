//! TypedArray objects (§23.2): %TypedArray%, its twelve concrete
//! constructors, the integer-indexed exotic object's internal methods
//! (§10.4.5), and the element conversions the buffers share with
//! DataView. An element is read and written as raw bits through the
//! buffer object a view holds, so detaching or resizing the buffer is
//! visible to every view immediately; a view's length may track its
//! buffer's (a length-tracking view of a resizable buffer).
const std = @import("std");
const builtin = @import("builtin");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const ab = @import("arraybuffer.zig");
const bigint = @import("bigint.zig");
const iterator = @import("iterator.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const String = b.String;
const Key = b.Key;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

pub const Kind = enum(u8) { int8, uint8, uint8c, int16, uint16, int32, uint32, float16, float32, float64, bigint64, biguint64 };
pub const kind_count = 12;
pub const names = [kind_count][]const u8{ "Int8Array", "Uint8Array", "Uint8ClampedArray", "Int16Array", "Uint16Array", "Int32Array", "Uint32Array", "Float16Array", "Float32Array", "Float64Array", "BigInt64Array", "BigUint64Array" };

pub fn elemSize(k: Kind) u8 {
    return switch (k) {
        .int8, .uint8, .uint8c => 1,
        .int16, .uint16, .float16 => 2,
        .int32, .uint32, .float32 => 4,
        .float64, .bigint64, .biguint64 => 8,
    };
}

pub fn isBigIntKind(k: Kind) bool {
    return k == .bigint64 or k == .biguint64;
}

pub const TypedArrayData = extern struct {
    buffer: Value,
    byte_offset: u64,
    /// Ignored when `length_tracking`.
    array_length: u64,
    kind: Kind,
    length_tracking: bool,
    _pad: [6]u8 = @splat(0),
};

pub fn data(o: *Object) *TypedArrayData {
    return o.internal(TypedArrayData);
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    m.markValue(data(o).buffer);
}

pub fn isTypedArray(v: Value) bool {
    return v.isObject() and asObject(v).class == .typed_array;
}

// ------------------------------------------------- element conversions

const native_little = builtin.cpu.arch.endian() == .little;

/// The raw bits of an element from its bytes.
pub fn readRaw(src: []const u8, k: Kind, little: bool) u64 {
    const e: std.builtin.Endian = if (little) .little else .big;
    return switch (elemSize(k)) {
        1 => src[0],
        2 => std.mem.readInt(u16, src[0..2], e),
        4 => std.mem.readInt(u32, src[0..4], e),
        else => std.mem.readInt(u64, src[0..8], e),
    };
}

pub fn writeRaw(dst: []u8, k: Kind, raw: u64, little: bool) void {
    const e: std.builtin.Endian = if (little) .little else .big;
    switch (elemSize(k)) {
        1 => dst[0] = @truncate(raw),
        2 => std.mem.writeInt(u16, dst[0..2], @truncate(raw), e),
        4 => std.mem.writeInt(u32, dst[0..4], @truncate(raw), e),
        else => std.mem.writeInt(u64, dst[0..8], raw, e),
    }
}

/// ToUint8Clamp (§7.1.12): clamp, then round half to even.
fn toUint8Clamp(d: f64) u8 {
    if (std.math.isNan(d) or d <= 0) return 0;
    if (d >= 255) return 255;
    const f = @floor(d);
    if (f + 0.5 < d) return @intFromFloat(f + 1);
    if (d < f + 0.5) return @intFromFloat(f);
    const fi: u8 = @intFromFloat(f);
    return if (fi % 2 == 0) fi else fi + 1;
}

/// A Number to a non-BigInt element's raw bits (the ToInt8 ... family).
pub fn numberToRaw(k: Kind, d: f64) u64 {
    return switch (k) {
        .int8 => @as(u8, @bitCast(@as(i8, @truncate(Vm.f64ToInt32(d))))),
        .uint8 => @as(u8, @truncate(@as(u32, @bitCast(Vm.f64ToInt32(d))))),
        .uint8c => toUint8Clamp(d),
        .int16 => @as(u16, @bitCast(@as(i16, @truncate(Vm.f64ToInt32(d))))),
        .uint16 => @as(u16, @truncate(@as(u32, @bitCast(Vm.f64ToInt32(d))))),
        .int32, .uint32 => @as(u32, @bitCast(Vm.f64ToInt32(d))),
        .float16 => @as(u16, @bitCast(@as(f16, @floatCast(d)))),
        .float32 => @as(u32, @bitCast(@as(f32, @floatCast(d)))),
        .float64 => @as(u64, @bitCast(d)),
        .bigint64, .biguint64 => unreachable,
    };
}

/// A JS value to raw bits: ToBigInt for the BigInt kinds, else ToNumber.
pub fn toRaw(vm: *Vm, k: Kind, v: Value) Error!u64 {
    if (isBigIntKind(k)) {
        const n = try bigint.toBigInt(vm, v);
        return bigint.toU64Bits(n);
    }
    return numberToRaw(k, try vm.toNumber(v));
}

/// Raw bits to the JS value they denote.
pub fn fromRaw(vm: *Vm, k: Kind, raw: u64) Error!Value {
    return switch (k) {
        .int8 => Value.fromInt(@as(i8, @bitCast(@as(u8, @truncate(raw))))),
        .uint8, .uint8c => Value.fromInt(@as(u8, @truncate(raw))),
        .int16 => Value.fromInt(@as(i16, @bitCast(@as(u16, @truncate(raw))))),
        .uint16 => Value.fromInt(@as(u16, @truncate(raw))),
        .int32 => Value.fromInt(@as(i32, @bitCast(@as(u32, @truncate(raw))))),
        .uint32 => Value.fromF64(@floatFromInt(@as(u32, @truncate(raw)))),
        .float16 => Value.fromF64(@floatCast(@as(f16, @bitCast(@as(u16, @truncate(raw)))))),
        .float32 => Value.fromF64(@floatCast(@as(f32, @bitCast(@as(u32, @truncate(raw)))))),
        .float64 => Value.fromF64(@bitCast(raw)),
        .bigint64 => bigint.fromI64(vm, @bitCast(raw)),
        .biguint64 => bigint.fromU64(vm, raw),
    };
}

// ------------------------------------------------------- the view itself

fn bufferOf(t: *TypedArrayData) *Object {
    return asObject(t.buffer);
}

/// IsTypedArrayOutOfBounds (§10.4.5.13).
pub fn isOutOfBounds(t: *TypedArrayData) bool {
    const buf = ab.data(bufferOf(t));
    if (buf.detached) return true;
    if (t.byte_offset > buf.len) return true;
    if (t.length_tracking) return false;
    return t.byte_offset + t.array_length * elemSize(t.kind) > buf.len;
}

/// TypedArrayLength; 0 when out of bounds.
pub fn length(t: *TypedArrayData) u64 {
    if (isOutOfBounds(t)) return 0;
    if (t.length_tracking) return (ab.data(bufferOf(t)).len - t.byte_offset) / elemSize(t.kind);
    return t.array_length;
}

fn byteLength(t: *TypedArrayData) u64 {
    return length(t) * elemSize(t.kind);
}

/// IsValidIntegerIndex (§10.4.5.14).
pub fn isValidIndex(t: *TypedArrayData, index: f64) bool {
    if (ab.data(bufferOf(t)).detached) return false;
    if (index != @trunc(index)) return false;
    if (index == 0 and std.math.signbit(index)) return false;
    if (index < 0) return false;
    return index < @as(f64, @floatFromInt(length(t)));
}

fn elemBytes(t: *TypedArrayData, index: u64) []u8 {
    const size = elemSize(t.kind);
    const start: usize = @intCast(t.byte_offset + index * size);
    return ab.bytes(bufferOf(t))[start .. start + size];
}

/// TypedArrayGetElement: undefined for an invalid index.
pub fn getElement(vm: *Vm, o: *Object, index: f64) Error!Value {
    const t = data(o);
    if (!isValidIndex(t, index)) return Value.undefined_;
    return fromRaw(vm, t.kind, readRaw(elemBytes(t, @intFromFloat(index)), t.kind, native_little));
}

fn getAt(vm: *Vm, o: *Object, i: u64) Error!Value {
    return getElement(vm, o, @floatFromInt(i));
}

/// TypedArraySetElement: convert first (which may detach), then write
/// if the index is still valid.
pub fn setElement(vm: *Vm, o: *Object, index: f64, v: Value) Error!void {
    const t = data(o);
    const raw = try toRaw(vm, t.kind, v);
    if (isImmutable(t) or !isValidIndex(t, index)) return;
    writeRaw(elemBytes(t, @intFromFloat(index)), t.kind, raw, native_little);
}

fn setRawAt(t: *TypedArrayData, i: u64, raw: u64) void {
    if (i < length(t)) writeRaw(elemBytes(t, i), t.kind, raw, native_little);
}

fn rawAt(t: *TypedArrayData, i: u64) u64 {
    return readRaw(elemBytes(t, i), t.kind, native_little);
}

/// CanonicalNumericIndexString for a key that is not an array index:
/// the number whose string form is exactly the key, or null.
pub fn numericKey(vm: *Vm, key: Key) Error!?f64 {
    switch (key) {
        .index => |i| return @floatFromInt(i),
        .symbol => return null,
        .atom => |s| {
            const text = s.latin1() orelse return null;
            if (text.len == 0) return null;
            const c = text[0];
            if (!(c == '-' or c == 'I' or c == 'N' or (c >= '0' and c <= '9'))) return null;
            if (std.mem.eql(u8, text, "-0")) return -0.0;
            const n = try vm.stringToNumber(s);
            const back = try vm.toString(Value.fromF64(n));
            if (!vm.stringEquals(back, s)) return null;
            return n;
        },
    }
}

// ------------------------------------------------- the exotic methods

pub fn getOwn(vm: *Vm, o: *Object, index: f64) Error!?vmod.Objects.Own {
    const v = try getElement(vm, o, index);
    if (v.isUndefined() and !isValidIndex(data(o), index)) return null;
    const writable = !isImmutable(data(o));
    return .{ .val = v, .attrs = .{ .writable = writable, .enumerable = true, .configurable = writable }, .slot = null };
}

pub fn defineOwn(vm: *Vm, o: *Object, index: f64, desc: Vm.Descriptor) Error!bool {
    if (!isValidIndex(data(o), index)) return false;
    if (isImmutable(data(o))) {
        // Only a descriptor that changes nothing is accepted.
        if (desc.configurable orelse false) return false;
        if (desc.enumerable != null and !desc.enumerable.?) return false;
        if (desc.isAccessor()) return false;
        if (desc.writable orelse false) return false;
        if (desc.value) |v| return vm.sameValue(v, try getElement(vm, o, index));
        return true;
    }
    if (desc.configurable != null and !desc.configurable.?) return false;
    if (desc.enumerable != null and !desc.enumerable.?) return false;
    if (desc.isAccessor()) return false;
    if (desc.writable != null and !desc.writable.?) return false;
    if (desc.value) |v| try setElement(vm, o, index, v);
    return true;
}

/// [[Set]] for a numeric key: true when handled (the caller returns
/// `result`), false when OrdinarySet should proceed with the element as
/// the own descriptor.
pub fn setNumeric(vm: *Vm, o: *Object, index: f64, v: Value, receiver: Value, result: *bool) Error!bool {
    if (receiver.isObject() and asObject(receiver) == o) {
        try setElement(vm, o, index, v);
        result.* = !isImmutable(data(o)) or !isValidIndex(data(o), index);
        return true;
    }
    if (!isValidIndex(data(o), index)) {
        result.* = true;
        return true;
    }
    return false;
}

pub fn ownKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
    const t = data(o);
    const len = length(t);
    var i: u64 = 0;
    while (i < len) : (i += 1) try out.append(vm.meta, .{ .index = @intCast(i) });
    var rest: std.ArrayList(Key) = .empty;
    defer rest.deinit(vm.meta);
    try vm.objects.ownKeys(o, &rest);
    for (rest.items) |k| {
        if (k == .symbol and k.symbol.private) continue;
        try out.append(vm.meta, k);
    }
}

/// The length the array iterator sees (TypeError when out of bounds).
pub fn iterLength(vm: *Vm, o: *Object) Error!u64 {
    const t = data(o);
    if (isOutOfBounds(t)) return vm.throwTypeError("TypedArray is out of bounds");
    return length(t);
}

// ------------------------------------------------------------ install

pub fn install(vm: *Vm) Error!void {
    const i = &vm.intrinsics;
    const proto = try vm.newObject();
    i.typed_array_prototype = proto;
    const ctor = try vm.newNativeNamed(strValue(try vm.atom("TypedArray")), 0, abstractConstruct, Value.undefined_, true);
    i.typed_array_ctor = ctor;
    _ = try vm.objects.defineOwn(ctor, .{ .atom = vm.atoms.prototype }, proto.asValue(), .frozen);
    _ = try vm.objects.defineOwn(proto, .{ .atom = vm.atoms.constructor }, ctor.asValue(), .hidden);
    _ = try vm.defineNative(ctor, "from", 1, from);
    _ = try vm.defineNative(ctor, "of", 0, of);
    const sg = try vm.newNative("get [Symbol.species]", 0, speciesGetter, Value.undefined_);
    try vm.defineAccessor(ctor, .{ .symbol = vm.symbols.species }, sg, null, .{ .enumerable = false, .configurable = true });
    try vm.defineGetter(proto, "buffer", getBuffer);
    try vm.defineGetter(proto, "byteLength", getByteLength);
    try vm.defineGetter(proto, "byteOffset", getByteOffset);
    try vm.defineGetter(proto, "length", getLength);
    const tag = try vm.newNative("get [Symbol.toStringTag]", 0, toStringTagGetter, Value.undefined_);
    try vm.defineAccessor(proto, .{ .symbol = vm.symbols.to_string_tag }, tag, null, .{ .enumerable = false, .configurable = true });
    inline for (.{
        .{ "at", at, 1 },             .{ "copyWithin", copyWithin, 2 },         .{ "entries", entries, 0 },         .{ "every", every, 1 },
        .{ "fill", fill, 1 },         .{ "filter", filter, 1 },                 .{ "find", find, 1 },               .{ "findIndex", findIndex, 1 },
        .{ "findLast", findLast, 1 }, .{ "findLastIndex", findLastIndex, 1 },   .{ "forEach", forEach, 1 },         .{ "includes", includes, 1 },
        .{ "indexOf", indexOf, 1 },   .{ "join", join, 1 },                     .{ "keys", keys, 0 },               .{ "lastIndexOf", lastIndexOf, 1 },
        .{ "map", map, 1 },           .{ "reduce", reduce, 1 },                 .{ "reduceRight", reduceRight, 1 }, .{ "reverse", reverse, 0 },
        .{ "set", set, 1 },           .{ "slice", slice, 2 },                   .{ "some", some, 1 },               .{ "sort", sort, 1 },
        .{ "subarray", subarray, 2 }, .{ "toLocaleString", toLocaleString, 0 }, .{ "toReversed", toReversed, 0 },   .{ "toSorted", toSorted, 1 },
        .{ "with", with, 2 },
    }) |e| _ = try vm.defineNative(proto, e[0], e[2], e[1]);
    const values_fn = try vm.defineNative(proto, "values", 0, values);
    _ = try vm.objects.defineOwn(proto, .{ .symbol = vm.symbols.iterator }, values_fn.asValue(), .hidden);
    // toString is Array.prototype's very function object.
    const array_to_string = try vm.get(i.array_prototype, .{ .atom = vm.atoms.toString }, i.array_prototype.asValue());
    try vm.defineValue(proto, "toString", array_to_string, .hidden);
    // The concrete constructors.
    inline for (0..kind_count) |k| {
        const kind: Kind = @enumFromInt(k);
        const p = try vm.objects.create(proto.asValue(), .ordinary, 0);
        const c = try vm.newNativeNamed(strValue(try vm.atom(names[k])), 3, concreteConstruct, Value.fromInt(k), true);
        _ = try vm.objects.setProto(c, ctor.asValue());
        _ = try vm.objects.defineOwn(c, .{ .atom = vm.atoms.prototype }, p.asValue(), .frozen);
        _ = try vm.objects.defineOwn(p, .{ .atom = vm.atoms.constructor }, c.asValue(), .hidden);
        try vm.defineValue(c, "BYTES_PER_ELEMENT", Value.fromInt(elemSize(kind)), .frozen);
        try vm.defineValue(p, "BYTES_PER_ELEMENT", Value.fromInt(elemSize(kind)), .frozen);
        try vm.defineValue(vm.global, names[k], c.asValue(), .hidden);
        i.typed_array_ctors[k] = c;
        i.typed_array_protos[k] = p;
    }
    // Uint8Array's base64 and hex methods (the arraybuffer-base64 proposal).
    const u8c = i.typed_array_ctors[@intFromEnum(Kind.uint8)];
    const u8p = i.typed_array_protos[@intFromEnum(Kind.uint8)];
    _ = try vm.defineNative(u8c, "fromBase64", 1, fromBase64);
    _ = try vm.defineNative(u8c, "fromHex", 1, fromHex);
    _ = try vm.defineNative(u8p, "setFromBase64", 1, setFromBase64);
    _ = try vm.defineNative(u8p, "setFromHex", 1, setFromHex);
    _ = try vm.defineNative(u8p, "toBase64", 0, toBase64);
    _ = try vm.defineNative(u8p, "toHex", 0, toHex);
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

fn abstractConstruct(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return vm.throwTypeError("Abstract class TypedArray not directly constructable");
}

/// ValidateTypedArray: a typed array that is in bounds.
fn validate(vm: *Vm, this: Value, what: []const u8) Error!*Object {
    if (!isTypedArray(this)) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    const o = asObject(this);
    if (isOutOfBounds(data(o))) return vm.throwTypeError("TypedArray is detached or out of bounds");
    return o;
}

/// ValidateTypedArray for a method that writes: an immutable buffer refuses.
fn validateWrite(vm: *Vm, this: Value, what: []const u8) Error!*Object {
    if (!isTypedArray(this)) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    const o = asObject(this);
    if (isImmutable(data(o))) return vm.throwTypeError("TypedArray is backed by an immutable ArrayBuffer");
    if (isOutOfBounds(data(o))) return vm.throwTypeError("TypedArray is detached or out of bounds");
    return o;
}

pub fn isImmutable(t: *TypedArrayData) bool {
    return ab.data(bufferOf(t)).immutable;
}

fn requireTypedArray(vm: *Vm, this: Value, what: []const u8) Error!*Object {
    if (!isTypedArray(this)) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    return asObject(this);
}

// --------------------------------------------------------- creation

/// AllocateTypedArray with a fresh buffer of `len` elements.
fn allocate(vm: *Vm, kind: Kind, new_target: Value, len: u64) Error!*Object {
    const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.typed_array_protos[@intFromEnum(kind)]);
    return allocateWithProto(vm, kind, proto, len);
}

fn allocateWithProto(vm: *Vm, kind: Kind, proto: *Object, len: u64) Error!*Object {
    const o = try vm.objects.create(proto.asValue(), .typed_array, @sizeOf(TypedArrayData));
    data(o).* = .{ .buffer = Value.undefined_, .byte_offset = 0, .array_length = 0, .kind = kind, .length_tracking = false };
    if (len > @as(u64, 1 << 31) / elemSize(kind)) return vm.throwRangeError("Invalid typed array length");
    const buf = try ab.allocate(vm, vm.intrinsics.array_buffer_ctor.asValue(), len * elemSize(kind), null, false);
    data(o).buffer = buf.asValue();
    data(o).array_length = len;
    return o;
}

fn concreteConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    const f = vm.current_native.?;
    const kind: Kind = @enumFromInt(f.internal(vmod.FunctionData).data.asInt());
    if (new_target.isUndefined()) return vm.throwTypeErrorFmt("Constructor {s} requires 'new'", .{names[@intFromEnum(kind)]});
    const first = arg(args, 0);
    if (!first.isObject()) {
        const len = try vm.toIndex(first);
        const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.typed_array_protos[@intFromEnum(kind)]);
        return (try allocateWithProto(vm, kind, proto, len)).asValue();
    }
    const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.typed_array_protos[@intFromEnum(kind)]);
    const src = asObject(first);
    if (src.class == .typed_array) {
        // InitializeTypedArrayFromTypedArray.
        const st = data(src);
        if (isOutOfBounds(st)) return vm.throwTypeError("Source typed array is detached or out of bounds");
        const len = length(st);
        if (isBigIntKind(st.kind) != isBigIntKind(kind)) return vm.throwTypeError("Cannot mix BigInt and Number typed arrays");
        const o = try allocateWithProto(vm, kind, proto, len);
        if (st.kind == kind) {
            @memcpy(ab.bytes(bufferOf(data(o)))[0..@intCast(len * elemSize(kind))], ab.bytes(bufferOf(st))[@intCast(st.byte_offset)..@intCast(st.byte_offset + len * elemSize(kind))]);
        } else {
            var k: u64 = 0;
            while (k < len) : (k += 1) try setElement(vm, o, @floatFromInt(k), try getAt(vm, src, k));
        }
        return o.asValue();
    }
    if (src.class == .array_buffer) {
        // InitializeTypedArrayFromArrayBuffer.
        const o = try vm.objects.create(proto.asValue(), .typed_array, @sizeOf(TypedArrayData));
        data(o).* = .{ .buffer = first, .byte_offset = 0, .array_length = 0, .kind = kind, .length_tracking = false };
        const size = elemSize(kind);
        const offset = try vm.toIndex(arg(args, 1));
        if (offset % size != 0) return vm.throwRangeError("Start offset must be a multiple of the element size");
        const fixed = !ab.data(src).resizable;
        const length_arg = arg(args, 2);
        var new_len: ?u64 = null;
        if (!length_arg.isUndefined()) new_len = try vm.toIndex(length_arg);
        if (ab.data(src).detached) return vm.throwTypeError("ArrayBuffer is detached");
        const buf_len = ab.data(src).len;
        if (new_len == null and !fixed) {
            if (offset > buf_len) return vm.throwRangeError("Start offset is outside the bounds of the buffer");
            data(o).length_tracking = true;
            data(o).byte_offset = offset;
        } else if (new_len == null) {
            if (buf_len % size != 0) return vm.throwRangeError("Byte length of buffer must be a multiple of the element size");
            if (offset > buf_len) return vm.throwRangeError("Start offset is outside the bounds of the buffer");
            data(o).byte_offset = offset;
            data(o).array_length = (buf_len - offset) / size;
        } else {
            if (offset + new_len.? * size > buf_len) return vm.throwRangeError("Invalid typed array length");
            data(o).byte_offset = offset;
            data(o).array_length = new_len.?;
        }
        return o.asValue();
    }
    // An iterable or array-like.
    const using_iterator = try vm.getMethod(first, .{ .symbol = vm.symbols.iterator });
    if (!using_iterator.isUndefined()) {
        var values_list: std.ArrayList(Value) = .empty;
        defer values_list.deinit(vm.meta);
        var rec = try vm.getIteratorFromMethod(first, using_iterator);
        while (try vm.iteratorStepValue(&rec)) |v| try values_list.append(vm.meta, v);
        const o = try allocateWithProto(vm, kind, proto, values_list.items.len);
        for (values_list.items, 0..) |v, k| try setElement(vm, o, @floatFromInt(k), v);
        return o.asValue();
    }
    // Array-like: the buffer is allocated before the elements are read.
    const len = try vm.lengthOfArrayLike(src);
    const o = try allocateWithProto(vm, kind, proto, len);
    var k: u64 = 0;
    while (k < len) : (k += 1) try setElement(vm, o, @floatFromInt(k), try vm.get(src, try bigKey(vm, k), first));
    return o.asValue();
}

fn bigKey(vm: *Vm, i: u64) Error!Key {
    if (i < std.math.maxInt(u32)) return .{ .index = @intCast(i) };
    var buf: [24]u8 = undefined;
    const s = std.fmt.bufPrint(&buf, "{d}", .{i}) catch unreachable;
    return .{ .atom = try vm.atom(s) };
}

/// TypedArrayCreateFromConstructor (§23.2.4.2); a result that will be
/// written to must not sit on an immutable buffer.
fn createFromConstructor(vm: *Vm, ctor: Value, args: []const Value) Error!*Object {
    return createFromConstructorMode(vm, ctor, args, true);
}

fn createFromConstructorMode(vm: *Vm, ctor: Value, args: []const Value, write: bool) Error!*Object {
    const nv = try vm.construct(ctor, args, ctor);
    const o = if (write) try validateWrite(vm, nv, "TypedArray species constructor") else try validate(vm, nv, "TypedArray species constructor");
    if (args.len == 1 and args[0].isNumber()) {
        if (@as(f64, @floatFromInt(length(data(o)))) < args[0].asNumber()) return vm.throwTypeError("Species constructor returned a too-short typed array");
    }
    return o;
}

/// TypedArraySpeciesCreate (§23.2.4.1).
fn speciesCreate(vm: *Vm, exemplar: *Object, args: []const Value) Error!*Object {
    return speciesCreateMode(vm, exemplar, args, true);
}

fn speciesCreateMode(vm: *Vm, exemplar: *Object, args: []const Value, write: bool) Error!*Object {
    const kind = data(exemplar).kind;
    const default_ctor = vm.intrinsics.typed_array_ctors[@intFromEnum(kind)];
    const ctor = try vm.speciesConstructor(exemplar, default_ctor.asValue());
    const result = try createFromConstructorMode(vm, ctor, args, write);
    if (isBigIntKind(data(result).kind) != isBigIntKind(kind)) return vm.throwTypeError("Species constructor returned a typed array of the wrong content type");
    return result;
}

/// TypedArrayCreateSameType.
fn createSameType(vm: *Vm, exemplar: *Object, len: u64) Error!*Object {
    const kind = data(exemplar).kind;
    return allocateWithProto(vm, kind, vm.intrinsics.typed_array_protos[@intFromEnum(kind)], len);
}

fn from(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!vm.isConstructor(this)) return vm.throwTypeError("TypedArray.from: this is not a constructor");
    const source = arg(args, 0);
    const mapfn = arg(args, 1);
    const this_arg = arg(args, 2);
    const mapping = !mapfn.isUndefined();
    if (mapping and !vm.isCallable(mapfn)) return vm.throwTypeError("TypedArray.from: mapper is not a function");
    const using_iterator = try vm.getMethod(source, .{ .symbol = vm.symbols.iterator });
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(vm.meta);
    var target: *Object = undefined;
    var len: u64 = 0;
    var array_like: ?*Object = null;
    if (!using_iterator.isUndefined()) {
        var rec = try vm.getIteratorFromMethod(source, using_iterator);
        while (try vm.iteratorStepValue(&rec)) |v| try list.append(vm.meta, v);
        len = list.items.len;
        target = try createFromConstructor(vm, this, &.{Value.fromF64(@floatFromInt(len))});
    } else {
        const o = try vm.toObject(source);
        array_like = o;
        len = try vm.lengthOfArrayLike(o);
        target = try createFromConstructor(vm, this, &.{Value.fromF64(@floatFromInt(len))});
    }
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        const kv = if (array_like) |o| try vm.get(o, try bigKey(vm, k), o.asValue()) else list.items[k];
        const mapped = if (mapping) try vm.call(mapfn, this_arg, &.{ kv, Value.fromF64(@floatFromInt(k)) }) else kv;
        if (!try vm.set(target, try bigKey(vm, k), mapped, target.asValue())) return vm.throwTypeError("Cannot set typed array element");
    }
    return target.asValue();
}

fn of(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!vm.isConstructor(this)) return vm.throwTypeError("TypedArray.of: this is not a constructor");
    const target = try createFromConstructor(vm, this, &.{Value.fromF64(@floatFromInt(args.len))});
    for (args, 0..) |v, k| {
        if (!try vm.set(target, .{ .index = @intCast(k) }, v, target.asValue())) return vm.throwTypeError("Cannot set typed array element");
    }
    return target.asValue();
}

// ----------------------------------------------------------- getters

fn getBuffer(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try requireTypedArray(vm, this, "get TypedArray.prototype.buffer");
    return data(o).buffer;
}

fn getByteLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try requireTypedArray(vm, this, "get TypedArray.prototype.byteLength");
    return Value.fromF64(@floatFromInt(byteLength(data(o))));
}

fn getByteOffset(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try requireTypedArray(vm, this, "get TypedArray.prototype.byteOffset");
    if (isOutOfBounds(data(o))) return Value.fromInt(0);
    return Value.fromF64(@floatFromInt(data(o).byte_offset));
}

fn getLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try requireTypedArray(vm, this, "get TypedArray.prototype.length");
    return Value.fromF64(@floatFromInt(length(data(o))));
}

fn toStringTagGetter(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!isTypedArray(this)) return Value.undefined_;
    return strValue(try vm.atom(names[@intFromEnum(data(asObject(this)).kind)]));
}

// ----------------------------------------------------------- methods

fn callback(vm: *Vm, args: []const Value, what: []const u8) Error!Value {
    const f = arg(args, 0);
    if (!vm.isCallable(f)) return vm.throwTypeErrorFmt("{s}: callback is not a function", .{what});
    return f;
}

fn at(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.at");
    const len: f64 = @floatFromInt(length(data(o)));
    const rel = try vm.toIntegerOrInfinity(arg(args, 0));
    const k = if (rel >= 0) rel else len + rel;
    if (k < 0 or k >= len) return Value.undefined_;
    return getElement(vm, o, k);
}

fn copyWithin(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validateWrite(vm, this, "TypedArray.prototype.copyWithin");
    const t = data(o);
    var len: f64 = @floatFromInt(length(t));
    const to = try b.relativeIndex(vm, arg(args, 0), len, 0);
    const from_ = try b.relativeIndex(vm, arg(args, 1), len, 0);
    const final = try b.relativeIndex(vm, arg(args, 2), len, len);
    const count = @min(final - from_, len - to);
    if (count > 0) {
        if (isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
        len = @floatFromInt(length(t));
        const size: f64 = @floatFromInt(elemSize(t.kind));
        const offset: f64 = @floatFromInt(t.byte_offset);
        const limit = len * size + offset;
        const to_byte = to * size + offset;
        const from_byte = from_ * size + offset;
        var count_bytes = count * size;
        if (from_byte + count_bytes > limit or to_byte + count_bytes > limit) count_bytes = @min(limit - from_byte, limit - to_byte);
        if (count_bytes > 0) {
            const buf = ab.bytes(bufferOf(t));
            const fb: usize = @intFromFloat(from_byte);
            const tb: usize = @intFromFloat(to_byte);
            const cb: usize = @intFromFloat(count_bytes);
            if (fb < tb and tb < fb + cb) {
                std.mem.copyBackwards(u8, buf[tb .. tb + cb], buf[fb .. fb + cb]);
            } else std.mem.copyForwards(u8, buf[tb .. tb + cb], buf[fb .. fb + cb]);
        }
    }
    return this;
}

fn entries(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try validate(vm, this, "TypedArray.prototype.entries");
    return iterator.createArrayIterator(vm, this, .entries);
}
fn keys(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try validate(vm, this, "TypedArray.prototype.keys");
    return iterator.createArrayIterator(vm, this, .keys);
}
fn values(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    _ = try validate(vm, this, "TypedArray.prototype.values");
    return iterator.createArrayIterator(vm, this, .values);
}

fn every(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.every");
    const len = length(data(o));
    const f = try callback(vm, args, "TypedArray.prototype.every");
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        const r = try vm.call(f, arg(args, 1), &.{ try getAt(vm, o, k), Value.fromF64(@floatFromInt(k)), this });
        if (!vm.toBoolean(r)) return Value.false_;
    }
    return Value.true_;
}

fn some(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.some");
    const len = length(data(o));
    const f = try callback(vm, args, "TypedArray.prototype.some");
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        const r = try vm.call(f, arg(args, 1), &.{ try getAt(vm, o, k), Value.fromF64(@floatFromInt(k)), this });
        if (vm.toBoolean(r)) return Value.true_;
    }
    return Value.false_;
}

fn forEach(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.forEach");
    const len = length(data(o));
    const f = try callback(vm, args, "TypedArray.prototype.forEach");
    var k: u64 = 0;
    while (k < len) : (k += 1) _ = try vm.call(f, arg(args, 1), &.{ try getAt(vm, o, k), Value.fromF64(@floatFromInt(k)), this });
    return Value.undefined_;
}

fn fill(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validateWrite(vm, this, "TypedArray.prototype.fill");
    const t = data(o);
    var len: f64 = @floatFromInt(length(t));
    const raw = try toRaw(vm, t.kind, arg(args, 0));
    const k = try b.relativeIndex(vm, arg(args, 1), len, 0);
    var final = try b.relativeIndex(vm, arg(args, 2), len, len);
    if (isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
    len = @floatFromInt(length(t));
    final = @min(final, len);
    var i: u64 = @intFromFloat(k);
    const end: u64 = @intFromFloat(@max(final, 0));
    while (i < end) : (i += 1) setRawAt(t, i, raw);
    return this;
}

fn filter(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.filter");
    const len = length(data(o));
    const f = try callback(vm, args, "TypedArray.prototype.filter");
    var kept: std.ArrayList(Value) = .empty;
    defer kept.deinit(vm.meta);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, arg(args, 1), &.{ v, Value.fromF64(@floatFromInt(k)), this });
        if (vm.toBoolean(r)) try kept.append(vm.meta, v);
    }
    const a = try speciesCreate(vm, o, &.{Value.fromF64(@floatFromInt(kept.items.len))});
    for (kept.items, 0..) |v, n| _ = try vm.set(a, try bigKey(vm, n), v, a.asValue());
    return a.asValue();
}

fn findImpl(vm: *Vm, this: Value, args: []const Value, what: []const u8, from_end: bool, want_index: bool) Error!Value {
    const o = try validate(vm, this, what);
    const len = length(data(o));
    const f = try callback(vm, args, what);
    var n: u64 = 0;
    while (n < len) : (n += 1) {
        const k = if (from_end) len - 1 - n else n;
        const v = try getAt(vm, o, k);
        const r = try vm.call(f, arg(args, 1), &.{ v, Value.fromF64(@floatFromInt(k)), this });
        if (vm.toBoolean(r)) return if (want_index) Value.fromF64(@floatFromInt(k)) else v;
    }
    return if (want_index) Value.fromInt(-1) else Value.undefined_;
}

fn find(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findImpl(vm, this, args, "TypedArray.prototype.find", false, false);
}
fn findIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findImpl(vm, this, args, "TypedArray.prototype.findIndex", false, true);
}
fn findLast(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findImpl(vm, this, args, "TypedArray.prototype.findLast", true, false);
}
fn findLastIndex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return findImpl(vm, this, args, "TypedArray.prototype.findLastIndex", true, true);
}

fn includes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.includes");
    const len: f64 = @floatFromInt(length(data(o)));
    if (len == 0) return Value.false_;
    var n = try vm.toIntegerOrInfinity(arg(args, 1));
    if (n == std.math.inf(f64)) return Value.false_;
    if (n == -std.math.inf(f64)) n = 0;
    var k: f64 = if (n >= 0) n else @max(len + n, 0);
    const target = arg(args, 0);
    while (k < len) : (k += 1) {
        if (vm.sameValueZero(try getElement(vm, o, k), target)) return Value.true_;
    }
    return Value.false_;
}

fn indexOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.indexOf");
    const t = data(o);
    const len: f64 = @floatFromInt(length(t));
    if (len == 0) return Value.fromInt(-1);
    var n = try vm.toIntegerOrInfinity(arg(args, 1));
    if (n == std.math.inf(f64)) return Value.fromInt(-1);
    if (n == -std.math.inf(f64)) n = 0;
    var k: f64 = if (n >= 0) n else @max(len + n, 0);
    const target = arg(args, 0);
    while (k < len) : (k += 1) {
        if (!isValidIndex(t, k)) continue;
        if (vm.isStrictlyEqual(try getElement(vm, o, k), target)) return Value.fromF64(k);
    }
    return Value.fromInt(-1);
}

fn lastIndexOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.lastIndexOf");
    const t = data(o);
    const len: f64 = @floatFromInt(length(t));
    if (len == 0) return Value.fromInt(-1);
    const n = if (args.len > 1) try vm.toIntegerOrInfinity(args[1]) else len - 1;
    if (n == -std.math.inf(f64)) return Value.fromInt(-1);
    var k: f64 = if (n >= 0) @min(n, len - 1) else len + n;
    const target = arg(args, 0);
    while (k >= 0) : (k -= 1) {
        if (!isValidIndex(t, k)) continue;
        if (vm.isStrictlyEqual(try getElement(vm, o, k), target)) return Value.fromF64(k);
    }
    return Value.fromInt(-1);
}

fn join(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.join");
    const len = length(data(o));
    const sep_arg = arg(args, 0);
    const sep = if (sep_arg.isUndefined()) try vm.atom(",") else try vm.toString(sep_arg);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (k > 0) try appendUnits(vm, &out, sep);
        const v = try getAt(vm, o, k);
        if (!v.isUndefined()) try appendUnits(vm, &out, try vm.toString(v));
    }
    return strValue(try vm.strings.fromUnits(out.items));
}

fn appendUnits(vm: *Vm, out: *std.ArrayList(u16), s: *String) Error!void {
    const flat = try vm.strings.flatten(s);
    var i: u32 = 0;
    while (i < flat.len) : (i += 1) try out.append(vm.meta, flat.unitAt(i));
}

fn map(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.map");
    const len = length(data(o));
    const f = try callback(vm, args, "TypedArray.prototype.map");
    const a = try speciesCreate(vm, o, &.{Value.fromF64(@floatFromInt(len))});
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        const mapped = try vm.call(f, arg(args, 1), &.{ try getAt(vm, o, k), Value.fromF64(@floatFromInt(k)), this });
        if (!try vm.set(a, try bigKey(vm, k), mapped, a.asValue())) return vm.throwTypeError("Cannot set typed array element");
    }
    return a.asValue();
}

fn reduceImpl(vm: *Vm, this: Value, args: []const Value, what: []const u8, from_end: bool) Error!Value {
    const o = try validate(vm, this, what);
    const len = length(data(o));
    const f = try callback(vm, args, what);
    if (len == 0 and args.len < 2) return vm.throwTypeError("Reduce of empty array with no initial value");
    var n: u64 = 0;
    var acc: Value = undefined;
    if (args.len >= 2) {
        acc = args[1];
    } else {
        acc = try getAt(vm, o, if (from_end) len - 1 else 0);
        n = 1;
    }
    while (n < len) : (n += 1) {
        const k = if (from_end) len - 1 - n else n;
        acc = try vm.call(f, Value.undefined_, &.{ acc, try getAt(vm, o, k), Value.fromF64(@floatFromInt(k)), this });
    }
    return acc;
}

fn reduce(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return reduceImpl(vm, this, args, "TypedArray.prototype.reduce", false);
}
fn reduceRight(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return reduceImpl(vm, this, args, "TypedArray.prototype.reduceRight", true);
}

fn reverse(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try validateWrite(vm, this, "TypedArray.prototype.reverse");
    const t = data(o);
    const len = length(t);
    if (len < 2) return this;
    var lo: u64 = 0;
    var hi: u64 = len - 1;
    while (lo < hi) : ({
        lo += 1;
        hi -= 1;
    }) {
        const a = rawAt(t, lo);
        const c = rawAt(t, hi);
        setRawAt(t, lo, c);
        setRawAt(t, hi, a);
    }
    return this;
}

fn set(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try requireTypedArray(vm, this, "TypedArray.prototype.set");
    const t = data(o);
    if (isImmutable(t)) return vm.throwTypeError("TypedArray is backed by an immutable ArrayBuffer");
    const source = arg(args, 0);
    const target_offset = try vm.toIntegerOrInfinity(arg(args, 1));
    if (target_offset < 0) return vm.throwRangeError("Offset is out of bounds");
    if (isTypedArray(source)) {
        // SetTypedArrayFromTypedArray.
        if (isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
        const target_len = length(t);
        const src = asObject(source);
        const st = data(src);
        if (isOutOfBounds(st)) return vm.throwTypeError("Source typed array is detached or out of bounds");
        const src_len = length(st);
        if (isBigIntKind(st.kind) != isBigIntKind(t.kind)) return vm.throwTypeError("Cannot mix BigInt and Number typed arrays");
        if (target_offset == std.math.inf(f64) or @as(f64, @floatFromInt(src_len)) + target_offset > @as(f64, @floatFromInt(target_len))) return vm.throwRangeError("Offset is out of bounds");
        const off: u64 = @intFromFloat(target_offset);
        const src_size = elemSize(st.kind);
        const src_bytes_all = ab.bytes(bufferOf(st))[@intCast(st.byte_offset)..@intCast(st.byte_offset + src_len * src_size)];
        // The same buffer: copy the source out first.
        const same = bufferOf(st) == bufferOf(t);
        const tmp = if (same) try vm.meta.dupe(u8, src_bytes_all) else src_bytes_all;
        defer if (same) vm.meta.free(tmp);
        if (st.kind == t.kind) {
            const dst = ab.bytes(bufferOf(t))[@intCast(t.byte_offset + off * src_size)..@intCast(t.byte_offset + (off + src_len) * src_size)];
            @memcpy(dst, tmp);
        } else {
            var k: u64 = 0;
            while (k < src_len) : (k += 1) {
                const raw = readRaw(tmp[@intCast(k * src_size)..@intCast((k + 1) * src_size)], st.kind, native_little);
                const v = try fromRaw(vm, st.kind, raw);
                setRawAt(t, off + k, try toRaw(vm, t.kind, v));
            }
        }
        return Value.undefined_;
    }
    // SetTypedArrayFromArrayLike.
    if (isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
    const target_len = length(t);
    const src = try vm.toObject(source);
    const src_len = try vm.lengthOfArrayLike(src);
    if (target_offset == std.math.inf(f64) or @as(f64, @floatFromInt(src_len)) + target_offset > @as(f64, @floatFromInt(target_len))) return vm.throwRangeError("Offset is out of bounds");
    const off: u64 = @intFromFloat(target_offset);
    var k: u64 = 0;
    while (k < src_len) : (k += 1) {
        const v = try vm.get(src, try bigKey(vm, k), src.asValue());
        try setElement(vm, o, @floatFromInt(off + k), v);
    }
    return Value.undefined_;
}

fn slice(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.slice");
    const t = data(o);
    var len: f64 = @floatFromInt(length(t));
    const start = try b.relativeIndex(vm, arg(args, 0), len, 0);
    var final = try b.relativeIndex(vm, arg(args, 1), len, len);
    var count = @max(final - start, 0);
    const a = try speciesCreate(vm, o, &.{Value.fromF64(count)});
    if (count > 0) {
        if (isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
        len = @floatFromInt(length(t));
        final = @min(final, len);
        count = @max(final - start, 0);
        const at_ = data(a);
        if (at_.kind == t.kind) {
            const size = elemSize(t.kind);
            const src_byte: u64 = t.byte_offset + @as(u64, @intFromFloat(start)) * size;
            var n: u64 = @as(u64, @intFromFloat(count)) * size;
            const src_end = t.byte_offset + byteLength(t);
            n = if (src_byte >= src_end) 0 else @min(n, src_end - src_byte);
            n = @min(n, byteLength(at_));
            if (n > 0) {
                // The species result may view the same buffer: the
                // specification copies byte by byte, forwards, so an
                // overlap ahead reads what was just written.
                const dst = ab.bytes(bufferOf(at_))[@intCast(at_.byte_offset)..@intCast(at_.byte_offset + n)];
                const src = ab.bytes(bufferOf(t))[@intCast(src_byte)..@intCast(src_byte + n)];
                std.mem.copyForwards(u8, dst, src);
            }
        } else {
            var k = start;
            var n: u64 = 0;
            while (k < final) : ({
                k += 1;
                n += 1;
            }) _ = try vm.set(a, try bigKey(vm, n), try getElement(vm, o, k), a.asValue());
        }
    }
    return a.asValue();
}

const SortCtx = struct { vm: *Vm, cmp: Value, kind: Kind, err: ?Error = null };

fn sortLess(ctx: *SortCtx, x: Value, y: Value) bool {
    if (ctx.err != null) return false;
    const vm = ctx.vm;
    if (!ctx.cmp.isUndefined()) {
        const r = vm.call(ctx.cmp, Value.undefined_, &.{ x, y }) catch |e| {
            ctx.err = e;
            return false;
        };
        const d = vm.toNumber(r) catch |e| {
            ctx.err = e;
            return false;
        };
        return d < 0;
    }
    if (isBigIntKind(ctx.kind)) return bigint.compare(x, y) == .lt;
    const a = x.asNumber();
    const c = y.asNumber();
    if (std.math.isNan(a)) return false;
    if (std.math.isNan(c)) return true;
    if (a < c) return true;
    if (a > c) return false;
    if (a == 0 and c == 0) return std.math.signbit(a) and !std.math.signbit(c);
    return false;
}

fn sortedValues(vm: *Vm, o: *Object, cmp: Value) Error!std.ArrayList(Value) {
    const t = data(o);
    const len = length(t);
    var list: std.ArrayList(Value) = .empty;
    errdefer list.deinit(vm.meta);
    var k: u64 = 0;
    while (k < len) : (k += 1) try list.append(vm.meta, try getAt(vm, o, k));
    var ctx = SortCtx{ .vm = vm, .cmp = cmp, .kind = t.kind };
    std.mem.sort(Value, list.items, &ctx, sortLess);
    if (ctx.err) |e| return e;
    return list;
}

fn sort(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const cmp = arg(args, 0);
    if (!cmp.isUndefined() and !vm.isCallable(cmp)) return vm.throwTypeError("The comparison function must be either a function or undefined");
    const o = try validateWrite(vm, this, "TypedArray.prototype.sort");
    var list = try sortedValues(vm, o, cmp);
    defer list.deinit(vm.meta);
    for (list.items, 0..) |v, j| try setElement(vm, o, @floatFromInt(j), v);
    return this;
}

fn toSorted(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const cmp = arg(args, 0);
    if (!cmp.isUndefined() and !vm.isCallable(cmp)) return vm.throwTypeError("The comparison function must be either a function or undefined");
    const o = try validate(vm, this, "TypedArray.prototype.toSorted");
    const len = length(data(o));
    const a = try createSameType(vm, o, len);
    var list = try sortedValues(vm, o, cmp);
    defer list.deinit(vm.meta);
    for (list.items, 0..) |v, j| try setElement(vm, a, @floatFromInt(j), v);
    return a.asValue();
}

fn subarray(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try requireTypedArray(vm, this, "TypedArray.prototype.subarray");
    const t = data(o);
    const src_len: f64 = @floatFromInt(length(t));
    const begin = try b.relativeIndex(vm, arg(args, 0), src_len, 0);
    const size: f64 = @floatFromInt(elemSize(t.kind));
    const begin_byte = Value.fromF64(@as(f64, @floatFromInt(t.byte_offset)) + begin * size);
    if (t.length_tracking and arg(args, 1).isUndefined()) {
        return (try speciesCreateMode(vm, o, &.{ t.buffer, begin_byte }, false)).asValue();
    }
    const final = try b.relativeIndex(vm, arg(args, 1), src_len, src_len);
    const new_len = @max(final - begin, 0);
    return (try speciesCreateMode(vm, o, &.{ t.buffer, begin_byte, Value.fromF64(new_len) }, false)).asValue();
}

fn toLocaleString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.toLocaleString");
    const len = length(data(o));
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    const sep = try vm.atom(",");
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        if (k > 0) try appendUnits(vm, &out, sep);
        const v = try getAt(vm, o, k);
        if (v.isNullish()) continue;
        const r = try vm.invoke(v, .{ .atom = try vm.atom("toLocaleString") }, &.{});
        try appendUnits(vm, &out, try vm.toString(r));
    }
    return strValue(try vm.strings.fromUnits(out.items));
}

fn toReversed(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.toReversed");
    const len = length(data(o));
    const a = try createSameType(vm, o, len);
    var k: u64 = 0;
    while (k < len) : (k += 1) setRawAt(data(a), k, rawAt(data(o), len - 1 - k));
    return a.asValue();
}

fn with(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, this, "TypedArray.prototype.with");
    const t = data(o);
    const len: u64 = length(t);
    const rel = try vm.toIntegerOrInfinity(arg(args, 0));
    const actual = if (rel >= 0) rel else @as(f64, @floatFromInt(len)) + rel;
    const value: Value = if (isBigIntKind(t.kind)) try bigint.toBigInt(vm, arg(args, 1)) else Value.fromF64(try vm.toNumber(arg(args, 1)));
    if (!isValidIndex(t, actual)) return vm.throwRangeError("Invalid typed array index");
    const a = try createSameType(vm, o, len);
    var k: u64 = 0;
    while (k < len) : (k += 1) {
        // The conversion above may have shrunk the buffer: a read past
        // the end is undefined, as Get says.
        const v = if (@as(f64, @floatFromInt(k)) == actual) value else try getAt(vm, o, k);
        try setElement(vm, a, @floatFromInt(k), v);
    }
    return a.asValue();
}

// ------------------------------------------------- base64 and hex

const Alphabet = enum { base64, base64url };
const LastChunk = enum { loose, strict, stop_before_partial };
const base64_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789+/";
const base64url_chars = "ABCDEFGHIJKLMNOPQRSTUVWXYZabcdefghijklmnopqrstuvwxyz0123456789-_";

/// GetOptionsObject: undefined is empty, anything else must be an object.
fn optionsObject(vm: *Vm, v: Value) Error!?*Object {
    if (v.isUndefined()) return null;
    if (!v.isObject()) return vm.throwTypeError("Options must be an object");
    return asObject(v);
}

fn stringOption(vm: *Vm, opts: ?*Object, name: []const u8) Error!?*String {
    const o = opts orelse return null;
    const v = try vm.get(o, .{ .atom = try vm.atom(name) }, o.asValue());
    if (v.isUndefined()) return null;
    if (!v.isString()) return vm.throwTypeErrorFmt("Option '{s}' must be a string", .{name});
    return asString(v);
}

fn alphabetOption(vm: *Vm, opts: ?*Object) Error!Alphabet {
    const s = (try stringOption(vm, opts, "alphabet")) orelse return .base64;
    var buf: [16]u8 = undefined;
    const text = b.utf8Buf(vm, s, &buf) catch "";
    if (std.mem.eql(u8, text, "base64")) return .base64;
    if (std.mem.eql(u8, text, "base64url")) return .base64url;
    return vm.throwTypeError("alphabet must be 'base64' or 'base64url'");
}

fn lastChunkOption(vm: *Vm, opts: ?*Object) Error!LastChunk {
    const s = (try stringOption(vm, opts, "lastChunkHandling")) orelse return .loose;
    var buf: [32]u8 = undefined;
    const text = b.utf8Buf(vm, s, &buf) catch "";
    if (std.mem.eql(u8, text, "loose")) return .loose;
    if (std.mem.eql(u8, text, "strict")) return .strict;
    if (std.mem.eql(u8, text, "stop-before-partial")) return .stop_before_partial;
    return vm.throwTypeError("lastChunkHandling must be 'loose', 'strict' or 'stop-before-partial'");
}

fn isAsciiWhitespace(c: u16) bool {
    return c == ' ' or c == '\t' or c == '\n' or c == 0x0c or c == '\r';
}

fn skipWhitespace(s: *String, start: usize) usize {
    var i = start;
    while (i < s.len and isAsciiWhitespace(s.unitAt(i))) i += 1;
    return i;
}

fn base64Value(c: u16) ?u6 {
    if (c >= 'A' and c <= 'Z') return @intCast(c - 'A');
    if (c >= 'a' and c <= 'z') return @intCast(c - 'a' + 26);
    if (c >= '0' and c <= '9') return @intCast(c - '0' + 52);
    if (c == '+') return 62;
    if (c == '/') return 63;
    return null;
}

const Decoded = struct { read: usize, bytes: std.ArrayList(u8), err: ?Error = null };

/// DecodeBase64Chunk: 2, 3 or 4 characters to 1, 2 or 3 bytes.
fn decodeChunk(vm: *Vm, out: *std.ArrayList(u8), chunk: []const u6, throw_on_extra: bool) Error!void {
    var bits: u32 = 0;
    for (chunk) |c| bits = (bits << 6) | c;
    switch (chunk.len) {
        2 => {
            if (throw_on_extra and (bits & 0xf) != 0) return vm.throwSyntaxError("Invalid base64 padding bits");
            try out.append(vm.meta, @intCast(bits >> 4));
        },
        3 => {
            if (throw_on_extra and (bits & 0x3) != 0) return vm.throwSyntaxError("Invalid base64 padding bits");
            try out.append(vm.meta, @intCast(bits >> 10));
            try out.append(vm.meta, @intCast((bits >> 2) & 0xff));
        },
        else => {
            try out.append(vm.meta, @intCast(bits >> 16));
            try out.append(vm.meta, @intCast((bits >> 8) & 0xff));
            try out.append(vm.meta, @intCast(bits & 0xff));
        },
    }
}

/// FromBase64 (the proposal's decoder): at most `max_len` bytes.
fn fromBase64Text(vm: *Vm, s: *String, alphabet: Alphabet, last: LastChunk, max_len: usize) Error!Decoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(vm.meta);
    if (max_len == 0) return .{ .read = 0, .bytes = out };
    var read: usize = 0;
    var chunk: [4]u6 = undefined;
    var chunk_len: usize = 0;
    var index: usize = 0;
    const len = s.len;
    while (true) {
        index = skipWhitespace(s, index);
        if (index == len) {
            if (chunk_len > 0) {
                if (last == .stop_before_partial) return .{ .read = read, .bytes = out };
                if (last == .loose) {
                    if (chunk_len == 1) return fail(vm, out, "Invalid base64 string");
                    decodeChunk(vm, &out, chunk[0..chunk_len], false) catch |e| return .{ .read = read, .bytes = out, .err = e };
                } else return fail(vm, out, "Invalid base64 string");
            }
            return .{ .read = len, .bytes = out };
        }
        var c = s.unitAt(index);
        index += 1;
        if (c == '=') {
            if (chunk_len < 2) return fail(vm, out, "Invalid base64 string");
            index = skipWhitespace(s, index);
            if (chunk_len == 2) {
                if (index == len) {
                    if (last == .stop_before_partial) return .{ .read = read, .bytes = out };
                    return fail(vm, out, "Invalid base64 string");
                }
                if (s.unitAt(index) == '=') {
                    index += 1;
                    index = skipWhitespace(s, index);
                }
            }
            if (index < len) return fail(vm, out, "Invalid base64 string");
            decodeChunk(vm, &out, chunk[0..chunk_len], last == .strict) catch |e| return .{ .read = read, .bytes = out, .err = e };
            return .{ .read = len, .bytes = out };
        }
        if (alphabet == .base64url) {
            if (c == '+' or c == '/') return fail(vm, out, "Invalid base64url character");
            if (c == '-') c = '+' else if (c == '_') c = '/';
        }
        const v = base64Value(c) orelse return fail(vm, out, "Invalid base64 character");
        const remaining = max_len - out.items.len;
        if ((remaining == 1 and chunk_len == 2) or (remaining == 2 and chunk_len == 3)) return .{ .read = read, .bytes = out };
        chunk[chunk_len] = v;
        chunk_len += 1;
        if (chunk_len == 4) {
            decodeChunk(vm, &out, chunk[0..4], false) catch |e| return .{ .read = read, .bytes = out, .err = e };
            chunk_len = 0;
            read = index;
            if (out.items.len == max_len) return .{ .read = read, .bytes = out };
        }
    }
}

/// A decode failure: the exception is set, the bytes so far are kept
/// for the caller to write before it rethrows.
fn fail(vm: *Vm, out: std.ArrayList(u8), msg: []const u8) Decoded {
    const e: Error = vm.throwSyntaxError(msg);
    return .{ .read = 0, .bytes = out, .err = e };
}

fn hexValue(c: u16) ?u8 {
    if (c >= '0' and c <= '9') return @intCast(c - '0');
    if (c >= 'a' and c <= 'f') return @intCast(c - 'a' + 10);
    if (c >= 'A' and c <= 'F') return @intCast(c - 'A' + 10);
    return null;
}

fn fromHexText(vm: *Vm, s: *String, max_len: usize) Error!Decoded {
    var out: std.ArrayList(u8) = .empty;
    errdefer out.deinit(vm.meta);
    if (s.len % 2 != 0) return fail(vm, out, "Hex string must have an even length");
    var index: usize = 0;
    while (index < s.len and out.items.len < max_len) : (index += 2) {
        const hi = hexValue(s.unitAt(index)) orelse return fail(vm, out, "Invalid hex character");
        const lo = hexValue(s.unitAt(index + 1)) orelse return fail(vm, out, "Invalid hex character");
        try out.append(vm.meta, hi * 16 + lo);
    }
    return .{ .read = index, .bytes = out };
}

fn stringArg(vm: *Vm, v: Value) Error!*String {
    if (!v.isString()) return vm.throwTypeError("Argument must be a string");
    return asString(v);
}

fn newUint8Array(vm: *Vm, content: []const u8) Error!Value {
    const o = try allocateWithProto(vm, .uint8, vm.intrinsics.typed_array_protos[@intFromEnum(Kind.uint8)], content.len);
    @memcpy(ab.bytes(bufferOf(data(o)))[0..content.len], content);
    return o.asValue();
}

fn fromBase64(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try stringArg(vm, arg(args, 0));
    const opts = try optionsObject(vm, arg(args, 1));
    const alphabet = try alphabetOption(vm, opts);
    const last = try lastChunkOption(vm, opts);
    var r = try fromBase64Text(vm, s, alphabet, last, std.math.maxInt(usize));
    defer r.bytes.deinit(vm.meta);
    if (r.err) |e| return e;
    return newUint8Array(vm, r.bytes.items);
}

fn fromHex(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try stringArg(vm, arg(args, 0));
    var r = try fromHexText(vm, s, std.math.maxInt(usize));
    defer r.bytes.deinit(vm.meta);
    if (r.err) |e| return e;
    return newUint8Array(vm, r.bytes.items);
}

/// ValidateUint8Array: a Uint8Array (writable when asked); the bounds
/// are checked separately, after the options have been read.
fn thisUint8(vm: *Vm, this: Value, write: bool) Error!*Object {
    if (!isTypedArray(this) or data(asObject(this)).kind != .uint8) return vm.throwTypeError("Receiver must be a Uint8Array");
    const o = asObject(this);
    if (write and isImmutable(data(o))) return vm.throwTypeError("Uint8Array is backed by an immutable ArrayBuffer");
    return o;
}

fn inBounds(vm: *Vm, o: *Object) Error!*Object {
    if (isOutOfBounds(data(o))) return vm.throwTypeError("Uint8Array is detached or out of bounds");
    return o;
}

fn setFromResult(vm: *Vm, o: *Object, r: *Decoded) Error!Value {
    const t = data(o);
    const n = r.bytes.items.len;
    @memcpy(ab.bytes(bufferOf(t))[@intCast(t.byte_offset)..@intCast(t.byte_offset + n)], r.bytes.items);
    if (r.err) |e| return e;
    const result = try vm.newObject();
    try vm.defineValue(result, "read", Value.fromF64(@floatFromInt(r.read)), .default);
    try vm.defineValue(result, "written", Value.fromF64(@floatFromInt(n)), .default);
    return result.asValue();
}

fn setFromBase64(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisUint8(vm, this, true);
    const s = try stringArg(vm, arg(args, 0));
    const opts = try optionsObject(vm, arg(args, 1));
    const alphabet = try alphabetOption(vm, opts);
    const last = try lastChunkOption(vm, opts);
    const oo = try inBounds(vm, o);
    var r = try fromBase64Text(vm, s, alphabet, last, @intCast(length(data(oo))));
    defer r.bytes.deinit(vm.meta);
    return setFromResult(vm, o, &r);
}

fn setFromHex(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisUint8(vm, this, true);
    const s = try stringArg(vm, arg(args, 0));
    _ = try inBounds(vm, o);
    var r = try fromHexText(vm, s, @intCast(length(data(o))));
    defer r.bytes.deinit(vm.meta);
    return setFromResult(vm, o, &r);
}

fn toBase64(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    _ = try thisUint8(vm, this, false);
    const opts = try optionsObject(vm, arg(args, 0));
    const alphabet = try alphabetOption(vm, opts);
    var omit_padding = false;
    if (opts) |op| omit_padding = vm.toBoolean(try vm.get(op, .{ .atom = try vm.atom("omitPadding") }, op.asValue()));
    const oo = try inBounds(vm, asObject(this));
    const t = data(oo);
    const src = ab.bytes(bufferOf(t))[@intCast(t.byte_offset)..@intCast(t.byte_offset + length(t))];
    const table = if (alphabet == .base64) base64_chars else base64url_chars;
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.meta);
    var i: usize = 0;
    while (i + 3 <= src.len) : (i += 3) {
        const bits: u32 = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8) | src[i + 2];
        try out.appendSlice(vm.meta, &.{ table[bits >> 18], table[(bits >> 12) & 63], table[(bits >> 6) & 63], table[bits & 63] });
    }
    const rest = src.len - i;
    if (rest == 1) {
        const bits: u32 = @as(u32, src[i]) << 16;
        try out.appendSlice(vm.meta, &.{ table[bits >> 18], table[(bits >> 12) & 63] });
        if (!omit_padding) try out.appendSlice(vm.meta, "==");
    } else if (rest == 2) {
        const bits: u32 = (@as(u32, src[i]) << 16) | (@as(u32, src[i + 1]) << 8);
        try out.appendSlice(vm.meta, &.{ table[bits >> 18], table[(bits >> 12) & 63], table[(bits >> 6) & 63] });
        if (!omit_padding) try out.append(vm.meta, '=');
    }
    return vm.str(out.items);
}

fn toHex(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try inBounds(vm, try thisUint8(vm, this, false));
    const t = data(o);
    const src = ab.bytes(bufferOf(t))[@intCast(t.byte_offset)..@intCast(t.byte_offset + length(t))];
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.meta);
    const digits = "0123456789abcdef";
    for (src) |c| try out.appendSlice(vm.meta, &.{ digits[c >> 4], digits[c & 15] });
    return vm.str(out.items);
}
