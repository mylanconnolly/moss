//! ArrayBuffer, SharedArrayBuffer (§25.1, §25.2) and DataView (§25.3).
//! A buffer's bytes live in the bookkeeping allocator (a resizable
//! buffer allocates its maximum up front, so resizing never moves
//! them) and are freed when the collector finalizes the object; views
//! hold the buffer object and read through it, so a detached or
//! resized buffer is seen by every view at once.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const ta = @import("typedarray.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const arg = b.arg;

pub const BufferData = extern struct {
    ptr: ?[*]u8,
    /// The current byte length.
    len: u64,
    /// The maximum (== len for a fixed-length buffer).
    max_len: u64,
    /// Bytes actually allocated at `ptr`.
    cap: u64,
    detach_key: Value,
    detached: bool,
    shared: bool,
    resizable: bool,
    immutable: bool,
    _pad: [4]u8 = @splat(0),
};

pub const DataViewData = extern struct {
    buffer: Value,
    byte_offset: u64,
    byte_length: u64,
    length_tracking: bool,
    _pad: [7]u8 = @splat(0),
};

pub fn data(o: *Object) *BufferData {
    return o.internal(BufferData);
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    switch (o.class) {
        .array_buffer => m.markValue(data(o).detach_key),
        .data_view => m.markValue(o.internal(DataViewData).buffer),
        else => {},
    }
}

pub fn finalize(vm: *Vm, o: *Object) void {
    const d = data(o);
    if (d.ptr) |p| vm.meta.free(p[0..@intCast(d.cap)]);
    d.ptr = null;
}

pub fn isBuffer(v: Value) bool {
    return v.isObject() and asObject(v).class == .array_buffer;
}

pub fn isDetached(o: *Object) bool {
    return data(o).detached;
}

pub fn byteLength(o: *Object) u64 {
    return data(o).len;
}

/// The live bytes of a buffer (empty once detached).
pub fn bytes(o: *Object) []u8 {
    const d = data(o);
    if (d.ptr) |p| return p[0..@intCast(d.len)];
    return &.{};
}

/// AllocateArrayBuffer / AllocateSharedArrayBuffer: the prototype comes
/// from the constructor first, then the block is made (zeroed).
pub fn allocate(vm: *Vm, new_target: Value, len: u64, max_len: ?u64, shared: bool) Error!*Object {
    if (max_len) |m| if (len > m) return vm.throwRangeError("byteLength exceeds maxByteLength");
    const default_proto = if (shared) vm.intrinsics.shared_array_buffer_prototype else vm.intrinsics.array_buffer_prototype;
    const o = try vm.createFromConstructor(new_target, default_proto, .array_buffer, @sizeOf(BufferData));
    const cap = max_len orelse len;
    if (cap > (1 << 31)) return vm.throwRangeError("Array buffer allocation failed");
    const block = vm.meta.alloc(u8, @intCast(@max(cap, 1))) catch return vm.throwRangeError("Array buffer allocation failed");
    @memset(block, 0);
    o.internal(BufferData).* = .{ .ptr = block.ptr, .len = len, .max_len = cap, .cap = @max(cap, 1), .detach_key = Value.undefined_, .detached = false, .shared = shared, .resizable = max_len != null, .immutable = false };
    return o;
}

/// AllocateImmutableArrayBuffer: a fixed buffer holding a copy of
/// `src` (zero-filled past it) that nothing can change or detach.
fn allocateImmutable(vm: *Vm, len: u64, src: []const u8) Error!*Object {
    const o = try allocate(vm, vm.intrinsics.array_buffer_ctor.asValue(), len, null, false);
    const n = @min(len, src.len);
    @memcpy(bytes(o)[0..@intCast(n)], src[0..@intCast(n)]);
    data(o).immutable = true;
    return o;
}

/// DetachArrayBuffer (§25.1.3.5).
pub fn detach(vm: *Vm, o: *Object, key: Value) Error!void {
    const d = data(o);
    if (d.shared) return vm.throwTypeError("Cannot detach a SharedArrayBuffer");
    if (d.immutable) return vm.throwTypeError("Cannot detach an immutable ArrayBuffer");
    if (!vm.sameValue(key, d.detach_key)) return vm.throwTypeError("ArrayBuffer detach key mismatch");
    if (d.ptr) |p| vm.meta.free(p[0..@intCast(d.cap)]);
    d.ptr = null;
    d.len = 0;
    d.max_len = 0;
    d.cap = 0;
    d.detached = true;
}

// ------------------------------------------------------------ install

pub fn install(vm: *Vm) Error!void {
    const i = &vm.intrinsics;
    // ArrayBuffer
    i.array_buffer_prototype = try vm.newObject();
    i.array_buffer_ctor = try b.installConstructor(vm, "ArrayBuffer", 1, construct, i.array_buffer_prototype);
    _ = try vm.defineNative(i.array_buffer_ctor, "isView", 1, isView);
    try species(vm, i.array_buffer_ctor);
    try vm.defineGetter(i.array_buffer_prototype, "byteLength", getByteLength);
    try vm.defineGetter(i.array_buffer_prototype, "detached", getDetached);
    try vm.defineGetter(i.array_buffer_prototype, "immutable", getImmutable);
    try vm.defineGetter(i.array_buffer_prototype, "maxByteLength", getMaxByteLength);
    try vm.defineGetter(i.array_buffer_prototype, "resizable", getResizable);
    _ = try vm.defineNative(i.array_buffer_prototype, "resize", 1, resize);
    _ = try vm.defineNative(i.array_buffer_prototype, "slice", 2, slice);
    _ = try vm.defineNative(i.array_buffer_prototype, "sliceToImmutable", 2, sliceToImmutable);
    _ = try vm.defineNative(i.array_buffer_prototype, "transfer", 0, transfer);
    _ = try vm.defineNative(i.array_buffer_prototype, "transferToFixedLength", 0, transferToFixedLength);
    _ = try vm.defineNative(i.array_buffer_prototype, "transferToImmutable", 0, transferToImmutable);
    try b.setToStringTag(vm, i.array_buffer_prototype, "ArrayBuffer");
    // SharedArrayBuffer
    i.shared_array_buffer_prototype = try vm.newObject();
    i.shared_array_buffer_ctor = try b.installConstructor(vm, "SharedArrayBuffer", 1, constructShared, i.shared_array_buffer_prototype);
    try species(vm, i.shared_array_buffer_ctor);
    try vm.defineGetter(i.shared_array_buffer_prototype, "byteLength", sharedByteLength);
    try vm.defineGetter(i.shared_array_buffer_prototype, "growable", sharedGrowable);
    try vm.defineGetter(i.shared_array_buffer_prototype, "maxByteLength", sharedMaxByteLength);
    _ = try vm.defineNative(i.shared_array_buffer_prototype, "grow", 1, sharedGrow);
    _ = try vm.defineNative(i.shared_array_buffer_prototype, "slice", 2, sharedSlice);
    try b.setToStringTag(vm, i.shared_array_buffer_prototype, "SharedArrayBuffer");
    // DataView
    i.data_view_prototype = try vm.newObject();
    _ = try b.installConstructor(vm, "DataView", 1, constructDataView, i.data_view_prototype);
    try vm.defineGetter(i.data_view_prototype, "buffer", dvBuffer);
    try vm.defineGetter(i.data_view_prototype, "byteLength", dvByteLength);
    try vm.defineGetter(i.data_view_prototype, "byteOffset", dvByteOffset);
    inline for (.{
        .{ "Int8", .int8 },       .{ "Uint8", .uint8 },       .{ "Int16", .int16 },         .{ "Uint16", .uint16 },
        .{ "Int32", .int32 },     .{ "Uint32", .uint32 },     .{ "Float16", .float16 },     .{ "Float32", .float32 },
        .{ "Float64", .float64 }, .{ "BigInt64", .bigint64 }, .{ "BigUint64", .biguint64 },
    }) |e| {
        _ = try vm.defineNative(i.data_view_prototype, "get" ++ e[0], 1, dvGetter(e[1]));
        _ = try vm.defineNative(i.data_view_prototype, "set" ++ e[0], 2, dvSetter(e[1]));
    }
    try b.setToStringTag(vm, i.data_view_prototype, "DataView");
}

fn species(vm: *Vm, ctor: *Object) Error!void {
    const g = try vm.newNative("get [Symbol.species]", 0, speciesGetter, Value.undefined_);
    try vm.defineAccessor(ctor, .{ .symbol = vm.symbols.species }, g, null, .{ .enumerable = false, .configurable = true });
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

/// GetArrayBufferMaxByteLengthOption.
fn maxByteLengthOption(vm: *Vm, options: Value) Error!?u64 {
    if (!options.isObject()) return null;
    const m = try vm.get(asObject(options), .{ .atom = try vm.atom("maxByteLength") }, options);
    if (m.isUndefined()) return null;
    return try vm.toIndex(m);
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor ArrayBuffer requires 'new'");
    const len = try vm.toIndex(arg(args, 0));
    const max = try maxByteLengthOption(vm, arg(args, 1));
    return (try allocate(vm, new_target, len, max, false)).asValue();
}

fn constructShared(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor SharedArrayBuffer requires 'new'");
    const len = try vm.toIndex(arg(args, 0));
    const max = try maxByteLengthOption(vm, arg(args, 1));
    return (try allocate(vm, new_target, len, max, true)).asValue();
}

fn isView(_: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isObject()) return Value.false_;
    const c = asObject(v).class;
    return Value.fromBool(c == .typed_array or c == .data_view);
}

fn thisBuffer(vm: *Vm, this: Value, shared: bool, what: []const u8) Error!*Object {
    if (!isBuffer(this) or data(asObject(this)).shared != shared) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    return asObject(this);
}

fn getByteLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "get ArrayBuffer.prototype.byteLength");
    return Value.fromF64(@floatFromInt(data(o).len));
}

fn getDetached(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "get ArrayBuffer.prototype.detached");
    return Value.fromBool(data(o).detached);
}

fn getMaxByteLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "get ArrayBuffer.prototype.maxByteLength");
    const d = data(o);
    if (d.detached) return Value.fromInt(0);
    return Value.fromF64(@floatFromInt(if (d.resizable) d.max_len else d.len));
}

fn getImmutable(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "get ArrayBuffer.prototype.immutable");
    return Value.fromBool(data(o).immutable);
}

fn getResizable(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "get ArrayBuffer.prototype.resizable");
    return Value.fromBool(data(o).resizable);
}

fn resize(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "ArrayBuffer.prototype.resize");
    const d = data(o);
    if (d.immutable) return vm.throwTypeError("ArrayBuffer is immutable");
    if (!d.resizable) return vm.throwTypeError("ArrayBuffer is not resizable");
    const new_len = try vm.toIndex(arg(args, 0));
    if (d.detached) return vm.throwTypeError("ArrayBuffer is detached");
    if (new_len > d.max_len) return vm.throwRangeError("Invalid array buffer length");
    if (new_len > d.len) @memset(d.ptr.?[@intCast(d.len)..@intCast(new_len)], 0);
    d.len = new_len;
    return Value.undefined_;
}

fn sliceImpl(vm: *Vm, this: Value, args: []const Value, shared: bool) Error!Value {
    const o = try thisBuffer(vm, this, shared, "ArrayBuffer.prototype.slice");
    const d = data(o);
    if (d.detached) return vm.throwTypeError("ArrayBuffer is detached");
    const len: f64 = @floatFromInt(d.len);
    const first = try b.relativeIndex(vm, arg(args, 0), len, 0);
    const final = try b.relativeIndex(vm, arg(args, 1), len, len);
    const new_len: u64 = @intFromFloat(@max(final - first, 0));
    const default_ctor = if (shared) vm.intrinsics.shared_array_buffer_ctor else vm.intrinsics.array_buffer_ctor;
    const ctor = try vm.speciesConstructor(o, default_ctor.asValue());
    const nv = try vm.construct(ctor, &.{Value.fromF64(@floatFromInt(new_len))}, ctor);
    if (!isBuffer(nv) or data(asObject(nv)).shared != shared) return vm.throwTypeError("Species constructor did not return an ArrayBuffer");
    const n = asObject(nv);
    if (data(n).detached) return vm.throwTypeError("Species constructor returned a detached ArrayBuffer");
    if (data(n).immutable) return vm.throwTypeError("Species constructor returned an immutable ArrayBuffer");
    if (n == o) return vm.throwTypeError("Species constructor returned the same ArrayBuffer");
    if (data(n).len < new_len) return vm.throwTypeError("Species constructor returned a too-small ArrayBuffer");
    if (d.detached) return vm.throwTypeError("ArrayBuffer is detached");
    const cur_len = d.len;
    const f: u64 = @intFromFloat(first);
    if (f < cur_len) {
        const count = @min(new_len, cur_len - f);
        @memcpy(bytes(n)[0..@intCast(count)], bytes(o)[@intCast(f)..@intCast(f + count)]);
    }
    return nv;
}

fn slice(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return sliceImpl(vm, this, args, false);
}

/// ArrayBufferCopyAndDetach (§25.1.3.3), also making the immutable copy
/// of the proposal.
const Preserve = enum { resizability, fixed, immutable };

fn copyAndDetach(vm: *Vm, this: Value, new_length: Value, preserve: Preserve) Error!Value {
    const o = try thisBuffer(vm, this, false, "ArrayBuffer.prototype.transfer");
    const d = data(o);
    const new_len: u64 = if (new_length.isUndefined()) d.len else try vm.toIndex(new_length);
    if (d.detached) return vm.throwTypeError("ArrayBuffer is detached");
    if (d.immutable) return vm.throwTypeError("ArrayBuffer is immutable");
    if (!d.detach_key.isUndefined()) return vm.throwTypeError("ArrayBuffer has a detach key");
    var n: *Object = undefined;
    if (preserve == .immutable) {
        n = try allocateImmutable(vm, new_len, bytes(o));
    } else {
        const new_max: ?u64 = if (preserve == .resizability and d.resizable) d.max_len else null;
        n = try allocate(vm, vm.intrinsics.array_buffer_ctor.asValue(), new_len, new_max, false);
        const count = @min(new_len, d.len);
        @memcpy(bytes(n)[0..@intCast(count)], bytes(o)[0..@intCast(count)]);
    }
    try detach(vm, o, Value.undefined_);
    return n.asValue();
}

fn transferToImmutable(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return copyAndDetach(vm, this, arg(args, 0), .immutable);
}

/// ArrayBuffer.prototype.sliceToImmutable (the immutable buffers proposal).
fn sliceToImmutable(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, false, "ArrayBuffer.prototype.sliceToImmutable");
    const d = data(o);
    if (d.detached) return vm.throwTypeError("ArrayBuffer is detached");
    const len: f64 = @floatFromInt(d.len);
    const first = try b.relativeIndex(vm, arg(args, 0), len, 0);
    const final = try b.relativeIndex(vm, arg(args, 1), len, len);
    const new_len: u64 = @intFromFloat(@max(final - first, 0));
    if (d.detached) return vm.throwTypeError("ArrayBuffer is detached");
    if (@as(f64, @floatFromInt(d.len)) < final) return vm.throwRangeError("ArrayBuffer shrank during slicing");
    const f: u64 = @intFromFloat(first);
    return (try allocateImmutable(vm, new_len, bytes(o)[@intCast(f)..@intCast(f + new_len)])).asValue();
}

fn transfer(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return copyAndDetach(vm, this, arg(args, 0), .resizability);
}

fn transferToFixedLength(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return copyAndDetach(vm, this, arg(args, 0), .fixed);
}

// ---------------------------------------------------- SharedArrayBuffer

fn sharedByteLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, true, "get SharedArrayBuffer.prototype.byteLength");
    return Value.fromF64(@floatFromInt(data(o).len));
}

fn sharedGrowable(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, true, "get SharedArrayBuffer.prototype.growable");
    return Value.fromBool(data(o).resizable);
}

fn sharedMaxByteLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, true, "get SharedArrayBuffer.prototype.maxByteLength");
    const d = data(o);
    return Value.fromF64(@floatFromInt(if (d.resizable) d.max_len else d.len));
}

fn sharedGrow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisBuffer(vm, this, true, "SharedArrayBuffer.prototype.grow");
    const d = data(o);
    if (!d.resizable) return vm.throwTypeError("SharedArrayBuffer is not growable");
    const new_len = try vm.toIndex(arg(args, 0));
    if (new_len > d.max_len) return vm.throwRangeError("Invalid array buffer length");
    if (new_len < d.len) return vm.throwRangeError("SharedArrayBuffer cannot shrink");
    d.len = new_len;
    return Value.undefined_;
}

fn sharedSlice(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return sliceImpl(vm, this, args, true);
}

// ------------------------------------------------------------ DataView

fn dv(o: *Object) *DataViewData {
    return o.internal(DataViewData);
}

fn thisView(vm: *Vm, this: Value, what: []const u8) Error!*Object {
    if (!this.isObject() or asObject(this).class != .data_view) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    return asObject(this);
}

/// IsViewOutOfBounds.
fn viewOutOfBounds(v: *DataViewData) bool {
    const buf = asObject(v.buffer);
    if (data(buf).detached) return true;
    const buf_len = data(buf).len;
    if (v.byte_offset > buf_len) return true;
    if (v.length_tracking) return false;
    return v.byte_offset + v.byte_length > buf_len;
}

fn viewByteLength(v: *DataViewData) u64 {
    if (v.length_tracking) return data(asObject(v.buffer)).len - v.byte_offset;
    return v.byte_length;
}

fn constructDataView(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor DataView requires 'new'");
    const buffer = arg(args, 0);
    if (!isBuffer(buffer)) return vm.throwTypeError("First argument to DataView constructor must be an ArrayBuffer");
    const buf = asObject(buffer);
    const offset = try vm.toIndex(arg(args, 1));
    if (data(buf).detached) return vm.throwTypeError("ArrayBuffer is detached");
    var buf_len = data(buf).len;
    if (offset > buf_len) return vm.throwRangeError("Start offset is outside the bounds of the buffer");
    const fixed = !data(buf).resizable;
    const length_arg = arg(args, 2);
    var tracking = false;
    var view_len: u64 = 0;
    if (length_arg.isUndefined()) {
        if (fixed) view_len = buf_len - offset else tracking = true;
    } else {
        view_len = try vm.toIndex(length_arg);
        if (offset + view_len > buf_len) return vm.throwRangeError("Invalid DataView length");
    }
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.data_view_prototype, .data_view, @sizeOf(DataViewData));
    if (data(buf).detached) return vm.throwTypeError("ArrayBuffer is detached");
    buf_len = data(buf).len;
    if (offset > buf_len) return vm.throwRangeError("Start offset is outside the bounds of the buffer");
    if (!length_arg.isUndefined() and offset + view_len > buf_len) return vm.throwRangeError("Invalid DataView length");
    dv(o).* = .{ .buffer = buffer, .byte_offset = offset, .byte_length = view_len, .length_tracking = tracking };
    return o.asValue();
}

fn dvBuffer(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisView(vm, this, "get DataView.prototype.buffer");
    return dv(o).buffer;
}

fn dvByteLength(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisView(vm, this, "get DataView.prototype.byteLength");
    if (viewOutOfBounds(dv(o))) return vm.throwTypeError("DataView is out of bounds");
    return Value.fromF64(@floatFromInt(viewByteLength(dv(o))));
}

fn dvByteOffset(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisView(vm, this, "get DataView.prototype.byteOffset");
    if (viewOutOfBounds(dv(o))) return vm.throwTypeError("DataView is out of bounds");
    return Value.fromF64(@floatFromInt(dv(o).byte_offset));
}

/// GetViewValue (§25.3.1.5).
fn dvGetter(comptime kind: ta.Kind) b.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
            const o = try thisView(vm, this, "DataView.prototype.get");
            const index = try vm.toIndex(arg(args, 0));
            const little = vm.toBoolean(arg(args, 1));
            const v = dv(o);
            if (viewOutOfBounds(v)) return vm.throwTypeError("DataView is out of bounds");
            const size = ta.elemSize(kind);
            if (index + size > viewByteLength(v)) return vm.throwRangeError("Offset is outside the bounds of the DataView");
            const at: usize = @intCast(v.byte_offset + index);
            const raw = ta.readRaw(bytes(asObject(v.buffer))[at .. at + size], kind, little);
            return ta.fromRaw(vm, kind, raw);
        }
    }.f;
}

/// SetViewValue (§25.3.1.6).
fn dvSetter(comptime kind: ta.Kind) b.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
            const o = try thisView(vm, this, "DataView.prototype.set");
            const v = dv(o);
            if (data(asObject(v.buffer)).immutable) return vm.throwTypeError("DataView is over an immutable ArrayBuffer");
            const index = try vm.toIndex(arg(args, 0));
            const raw = try ta.toRaw(vm, kind, arg(args, 1));
            const little = vm.toBoolean(arg(args, 2));
            if (viewOutOfBounds(v)) return vm.throwTypeError("DataView is out of bounds");
            const size = ta.elemSize(kind);
            if (index + size > viewByteLength(v)) return vm.throwRangeError("Offset is outside the bounds of the DataView");
            const at: usize = @intCast(v.byte_offset + index);
            ta.writeRaw(bytes(asObject(v.buffer))[at .. at + size], kind, raw, little);
            return Value.undefined_;
        }
    }.f;
}
