//! Atomics (§25.4) for a single agent: every operation is an ordinary
//! read-modify-write on the typed array's buffer (nothing else runs),
//! `wait` returns at once — no other agent can ever notify — and
//! `notify` finds no waiters. The validations are the specification's,
//! so a page's use of the API is checked exactly as elsewhere.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const ab = @import("arraybuffer.zig");
const ta = @import("typedarray.zig");
const bigint = @import("bigint.zig");
const realm = @import("../realm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const o = try vm.newObject();
    try vm.defineValue(vm.global, "Atomics", o.asValue(), .hidden);
    inline for (.{
        .{ "add", rmw(.add), 3 },         .{ "and", rmw(.band), 3 }, .{ "compareExchange", compareExchange, 4 }, .{ "exchange", rmw(.exchange), 3 },
        .{ "isLockFree", isLockFree, 1 }, .{ "load", load, 2 },      .{ "notify", notify, 3 },                   .{ "or", rmw(.bor), 3 },
        .{ "pause", pause, 0 },           .{ "store", store, 3 },    .{ "sub", rmw(.sub), 3 },                   .{ "wait", wait, 4 },
        .{ "waitAsync", waitAsync, 4 },   .{ "xor", rmw(.bxor), 3 },
    }) |e| _ = try vm.defineNative(o, e[0], e[2], e[1]);
    try b.setToStringTag(vm, o, "Atomics");
}

/// ValidateIntegerTypedArray (§25.4.3.1): an integer typed array in
/// bounds; a waitable one is Int32 or BigInt64.
fn validate(vm: *Vm, v: Value, waitable: bool, write: bool) Error!*Object {
    if (!ta.isTypedArray(v)) return vm.throwTypeError("Argument is not a typed array");
    const o = asObject(v);
    const t = ta.data(o);
    if (waitable) {
        if (t.kind != .int32 and t.kind != .bigint64) return vm.throwTypeError("Atomics.wait requires an Int32Array or BigInt64Array");
    } else switch (t.kind) {
        .int8, .uint8, .int16, .uint16, .int32, .uint32, .bigint64, .biguint64 => {},
        else => return vm.throwTypeError("Atomics operations require an integer typed array"),
    }
    if (write and ta.isImmutable(t)) return vm.throwTypeError("TypedArray is backed by an immutable ArrayBuffer");
    if (ta.isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
    return o;
}

/// ValidateAtomicAccess: the element index, checked against the length.
fn access(vm: *Vm, o: *Object, index: Value) Error!u64 {
    const len = ta.length(ta.data(o));
    const i = try vm.toIndex(index);
    if (i >= len) return vm.throwRangeError("Atomics access index is out of range");
    return i;
}

/// The operand as raw element bits (ToBigInt, or ToIntegerOrInfinity
/// then the element's wrap), and as the value the operation returns.
fn operand(vm: *Vm, kind: ta.Kind, v: Value) Error!struct { raw: u64, value: Value } {
    if (ta.isBigIntKind(kind)) {
        const n = try bigint.toBigInt(vm, v);
        return .{ .raw = bigint.toU64Bits(n), .value = n };
    }
    const d = try vm.toIntegerOrInfinity(v);
    return .{ .raw = ta.numberToRaw(kind, d), .value = Value.fromF64(d + 0.0) };
}

/// After the operand was coerced the array may have gone away.
fn revalidate(vm: *Vm, o: *Object, i: u64) Error!void {
    const t = ta.data(o);
    if (ta.isOutOfBounds(t)) return vm.throwTypeError("TypedArray is detached or out of bounds");
    if (i >= ta.length(t)) return vm.throwRangeError("Atomics access index is out of range");
}

fn readRaw(o: *Object, i: u64) u64 {
    const t = ta.data(o);
    const size = ta.elemSize(t.kind);
    const at: usize = @intCast(t.byte_offset + i * size);
    return ta.readRaw(ab.bytes(asObject(t.buffer))[at .. at + size], t.kind, true);
}

fn writeRaw(o: *Object, i: u64, raw: u64) void {
    const t = ta.data(o);
    const size = ta.elemSize(t.kind);
    const at: usize = @intCast(t.byte_offset + i * size);
    ta.writeRaw(ab.bytes(asObject(t.buffer))[at .. at + size], t.kind, raw, true);
}

/// The bits an element's size keeps.
fn mask(kind: ta.Kind) u64 {
    return switch (ta.elemSize(kind)) {
        1 => 0xff,
        2 => 0xffff,
        4 => 0xffff_ffff,
        else => 0xffff_ffff_ffff_ffff,
    };
}

const Op = enum { add, sub, band, bor, bxor, exchange };

/// AtomicReadModifyWrite: the old value is returned.
fn rmw(comptime op: Op) b.NativeFn {
    return struct {
        fn f(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
            const o = try validate(vm, arg(args, 0), false, true);
            const i = try access(vm, o, arg(args, 1));
            const kind = ta.data(o).kind;
            const v = try operand(vm, kind, arg(args, 2));
            try revalidate(vm, o, i);
            const old = readRaw(o, i);
            const m = mask(kind);
            const new: u64 = switch (op) {
                .add => (old +% v.raw) & m,
                .sub => (old -% v.raw) & m,
                .band => old & v.raw & m,
                .bor => (old | v.raw) & m,
                .bxor => (old ^ v.raw) & m,
                .exchange => v.raw & m,
            };
            writeRaw(o, i, new);
            return ta.fromRaw(vm, kind, old);
        }
    }.f;
}

fn compareExchange(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, arg(args, 0), false, true);
    const i = try access(vm, o, arg(args, 1));
    const kind = ta.data(o).kind;
    const expected = try operand(vm, kind, arg(args, 2));
    const replacement = try operand(vm, kind, arg(args, 3));
    try revalidate(vm, o, i);
    const old = readRaw(o, i);
    const m = mask(kind);
    if ((old & m) == (expected.raw & m)) writeRaw(o, i, replacement.raw & m);
    return ta.fromRaw(vm, kind, old);
}

fn load(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, arg(args, 0), false, false);
    const i = try access(vm, o, arg(args, 1));
    return ta.fromRaw(vm, ta.data(o).kind, readRaw(o, i));
}

fn store(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, arg(args, 0), false, true);
    const i = try access(vm, o, arg(args, 1));
    const kind = ta.data(o).kind;
    const v = try operand(vm, kind, arg(args, 2));
    try revalidate(vm, o, i);
    writeRaw(o, i, v.raw & mask(kind));
    return v.value;
}

fn isLockFree(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    return Value.fromBool(n == 1 or n == 2 or n == 4 or n == 8);
}

fn pause(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const n = arg(args, 0);
    if (!n.isUndefined()) {
        if (!n.isNumber() or !std.math.isFinite(n.asNumber()) or n.asNumber() != @trunc(n.asNumber())) return vm.throwTypeError("Atomics.pause argument must be an integral Number");
    }
    return Value.undefined_;
}

/// DoWait (§25.4.3.14) with no other agent: the value is compared and
/// the wait, whatever its timeout, is over at once.
const WaitResult = enum { not_equal, timed_out };

fn doWait(vm: *Vm, args: []const Value) Error!struct { result: WaitResult, timeout: f64 } {
    const o = try validate(vm, arg(args, 0), true, false);
    const t = ta.data(o);
    if (!ab.data(asObject(t.buffer)).shared) return vm.throwTypeError("Atomics.wait requires a shared typed array");
    const i = try access(vm, o, arg(args, 1));
    var expect: u64 = undefined;
    if (t.kind == .bigint64) {
        expect = bigint.toU64Bits(try bigint.toBigInt(vm, arg(args, 2)));
    } else {
        expect = @as(u32, @bitCast(try vm.toInt32(arg(args, 2))));
    }
    const q = try vm.toNumber(arg(args, 3));
    const timeout: f64 = if (std.math.isNan(q)) std.math.inf(f64) else @max(q, 0);
    const cur = readRaw(o, i);
    if (cur != expect) return .{ .result = .not_equal, .timeout = timeout };
    return .{ .result = .timed_out, .timeout = timeout };
}

fn wait(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const r = try doWait(vm, args);
    return vm.str(if (r.result == .not_equal) "not-equal" else "timed-out");
}

fn waitAsync(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const r = try doWait(vm, args);
    const result = try vm.newObject();
    if (r.result == .not_equal or r.timeout == 0) {
        try vm.defineValue(result, "async", Value.false_, .default);
        try vm.defineValue(result, "value", try vm.str(if (r.result == .not_equal) "not-equal" else "timed-out"), .default);
        return result.asValue();
    }
    // A promise that settles when the timeout would: no notifier exists,
    // so it settles with "timed-out" on the job queue.
    const p = try realm.promiseResolve(vm, try vm.str("timed-out"));
    try vm.defineValue(result, "async", Value.true_, .default);
    try vm.defineValue(result, "value", p, .default);
    return result.asValue();
}

fn notify(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const o = try validate(vm, arg(args, 0), true, false);
    const i = try access(vm, o, arg(args, 1));
    _ = i;
    const c = arg(args, 2);
    if (!c.isUndefined()) _ = @max(try vm.toIntegerOrInfinity(c), 0);
    return Value.fromInt(0);
}
