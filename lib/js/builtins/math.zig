//! Math (§21.3).
const std = @import("std");
const b = @import("../builtins.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const m = try vm.newObject();
    try vm.defineValue(vm.global, "Math", m.asValue(), .hidden);
    try b.setToStringTag(vm, m, "Math");
    try vm.defineValue(m, "E", Value.fromF64(std.math.e), .frozen);
    try vm.defineValue(m, "LN10", Value.fromF64(std.math.ln10), .frozen);
    try vm.defineValue(m, "LN2", Value.fromF64(std.math.ln2), .frozen);
    try vm.defineValue(m, "LOG10E", Value.fromF64(std.math.log10e), .frozen);
    try vm.defineValue(m, "LOG2E", Value.fromF64(std.math.log2e), .frozen);
    try vm.defineValue(m, "PI", Value.fromF64(std.math.pi), .frozen);
    try vm.defineValue(m, "SQRT1_2", Value.fromF64(std.math.sqrt1_2), .frozen);
    try vm.defineValue(m, "SQRT2", Value.fromF64(std.math.sqrt2), .frozen);
    inline for (.{
        .{ "abs", unaryFn(absF) },     .{ "acos", unaryFn(acosF) },   .{ "acosh", unaryFn(acoshF) },   .{ "asin", unaryFn(asinF) },
        .{ "asinh", unaryFn(asinhF) }, .{ "atan", unaryFn(atanF) },   .{ "atanh", unaryFn(atanhF) },   .{ "cbrt", unaryFn(cbrtF) },
        .{ "ceil", unaryFn(ceilF) },   .{ "cos", unaryFn(cosF) },     .{ "cosh", unaryFn(coshF) },     .{ "exp", unaryFn(expF) },
        .{ "expm1", unaryFn(expm1F) }, .{ "floor", unaryFn(floorF) }, .{ "fround", unaryFn(froundF) }, .{ "f16round", unaryFn(f16roundF) },
        .{ "log", unaryFn(logF) },     .{ "log1p", unaryFn(log1pF) }, .{ "log10", unaryFn(log10F) },   .{ "log2", unaryFn(log2F) },
        .{ "round", unaryFn(roundF) }, .{ "sign", unaryFn(signF) },   .{ "sin", unaryFn(sinF) },       .{ "sinh", unaryFn(sinhF) },
        .{ "sqrt", unaryFn(sqrtF) },   .{ "tan", unaryFn(tanF) },     .{ "tanh", unaryFn(tanhF) },     .{ "trunc", unaryFn(truncF) },
        .{ "clz32", clz32 },
    }) |e| _ = try vm.defineNative(m, e[0], 1, e[1]);
    _ = try vm.defineNative(m, "atan2", 2, atan2);
    _ = try vm.defineNative(m, "hypot", 2, hypot);
    _ = try vm.defineNative(m, "imul", 2, imul);
    _ = try vm.defineNative(m, "max", 2, max);
    _ = try vm.defineNative(m, "min", 2, min);
    _ = try vm.defineNative(m, "pow", 2, pow);
    _ = try vm.defineNative(m, "random", 0, random);
}

fn unaryFn(comptime f: fn (f64) f64) b.NativeFn {
    return struct {
        fn n(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
            return Value.fromF64(f(try vm.toNumber(arg(args, 0))));
        }
    }.n;
}

fn acosF(x: f64) f64 {
    return std.math.acos(x);
}
fn acoshF(x: f64) f64 {
    return std.math.acosh(x);
}
fn asinF(x: f64) f64 {
    return std.math.asin(x);
}
fn asinhF(x: f64) f64 {
    return std.math.asinh(x);
}
fn atanF(x: f64) f64 {
    return std.math.atan(x);
}
fn atanhF(x: f64) f64 {
    return std.math.atanh(x);
}
fn cbrtF(x: f64) f64 {
    return std.math.cbrt(x);
}
fn cosF(x: f64) f64 {
    return std.math.cos(x);
}
fn coshF(x: f64) f64 {
    return std.math.cosh(x);
}
fn expF(x: f64) f64 {
    return std.math.exp(x);
}
fn expm1F(x: f64) f64 {
    return std.math.expm1(x);
}
fn log1pF(x: f64) f64 {
    return std.math.log1p(x);
}
fn sinF(x: f64) f64 {
    return std.math.sin(x);
}
fn sinhF(x: f64) f64 {
    return std.math.sinh(x);
}
fn tanF(x: f64) f64 {
    return std.math.tan(x);
}
fn tanhF(x: f64) f64 {
    return std.math.tanh(x);
}
fn absF(x: f64) f64 {
    return @abs(x);
}
fn ceilF(x: f64) f64 {
    return @ceil(x);
}
fn floorF(x: f64) f64 {
    return @floor(x);
}
fn truncF(x: f64) f64 {
    return @trunc(x);
}
fn sqrtF(x: f64) f64 {
    return @sqrt(x);
}
fn logF(x: f64) f64 {
    return @log(x);
}
fn log10F(x: f64) f64 {
    return @log10(x);
}
fn log2F(x: f64) f64 {
    return @log2(x);
}
fn froundF(x: f64) f64 {
    return @floatCast(@as(f32, @floatCast(x)));
}
/// Math.f16round (ES2025): the nearest binary16, ties to even.
fn f16roundF(x: f64) f64 {
    return @floatCast(@as(f16, @floatCast(x)));
}
fn roundF(x: f64) f64 {
    if (!std.math.isFinite(x) or x == 0) return x;
    if (x > 0 and x < 0.5) return 0;
    if (x < 0 and x >= -0.5) return -0.0;
    return @floor(x + 0.5);
}
fn signF(x: f64) f64 {
    if (std.math.isNan(x) or x == 0) return x;
    return if (x > 0) 1 else -1;
}

fn clz32(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const n = try vm.toUint32(arg(args, 0));
    return Value.fromInt(@intCast(@clz(n)));
}

fn atan2(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const y = try vm.toNumber(arg(args, 0));
    const x = try vm.toNumber(arg(args, 1));
    return Value.fromF64(std.math.atan2(y, x));
}

fn hypot(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var coerced: [16]f64 = undefined;
    var list: std.ArrayList(f64) = .empty;
    defer list.deinit(vm.meta);
    for (args) |a| try list.append(vm.meta, try vm.toNumber(a));
    _ = &coerced;
    var inf = false;
    var nan = false;
    for (list.items) |d| {
        if (std.math.isInf(d)) inf = true;
        if (std.math.isNan(d)) nan = true;
    }
    if (inf) return Value.fromF64(std.math.inf(f64));
    if (nan) return Value.fromF64(std.math.nan(f64));
    var m: f64 = 0;
    for (list.items) |d| m = @max(m, @abs(d));
    if (m == 0) return Value.fromF64(0);
    var sum: f64 = 0;
    var comp: f64 = 0;
    for (list.items) |d| {
        const t = (d / m) * (d / m);
        const y = t - comp;
        const s = sum + y;
        comp = (s - sum) - y;
        sum = s;
    }
    return Value.fromF64(@sqrt(sum) * m);
}

fn imul(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const a = try vm.toInt32(arg(args, 0));
    const c = try vm.toInt32(arg(args, 1));
    return Value.fromInt(a *% c);
}

fn max(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var r: f64 = -std.math.inf(f64);
    var nan = false;
    for (args) |a| {
        const d = try vm.toNumber(a);
        if (std.math.isNan(d)) nan = true;
        if (d > r or (d == 0 and r == 0 and !std.math.signbit(d))) r = d;
    }
    return Value.fromF64(if (nan) std.math.nan(f64) else r);
}

fn min(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var r: f64 = std.math.inf(f64);
    var nan = false;
    for (args) |a| {
        const d = try vm.toNumber(a);
        if (std.math.isNan(d)) nan = true;
        if (d < r or (d == 0 and r == 0 and std.math.signbit(d))) r = d;
    }
    return Value.fromF64(if (nan) std.math.nan(f64) else r);
}

fn pow(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const x = try vm.toNumber(arg(args, 0));
    const y = try vm.toNumber(arg(args, 1));
    return Value.fromF64(Vm.jsPow(x, y));
}

var prng = std.Random.DefaultPrng.init(0x9e3779b97f4a7c15);

fn random(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromF64(prng.random().float(f64));
}
