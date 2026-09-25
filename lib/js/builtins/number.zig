//! Number and Boolean (§21.1, §20.3).
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const compiler = @import("../compiler.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const asObject = b.asObject;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.number_prototype;
    const ctor = try b.installConstructor(vm, "Number", 1, construct, proto);
    try vm.defineValue(ctor, "EPSILON", Value.fromF64(std.math.floatEps(f64)), .frozen);
    try vm.defineValue(ctor, "MAX_SAFE_INTEGER", Value.fromF64(9007199254740991), .frozen);
    try vm.defineValue(ctor, "MAX_VALUE", Value.fromF64(std.math.floatMax(f64)), .frozen);
    try vm.defineValue(ctor, "MIN_SAFE_INTEGER", Value.fromF64(-9007199254740991), .frozen);
    try vm.defineValue(ctor, "MIN_VALUE", Value.fromF64(5e-324), .frozen);
    try vm.defineValue(ctor, "NaN", Value.fromF64(std.math.nan(f64)), .frozen);
    try vm.defineValue(ctor, "NEGATIVE_INFINITY", Value.fromF64(-std.math.inf(f64)), .frozen);
    try vm.defineValue(ctor, "POSITIVE_INFINITY", Value.fromF64(std.math.inf(f64)), .frozen);
    _ = try vm.defineNative(ctor, "isFinite", 1, isFinite);
    _ = try vm.defineNative(ctor, "isInteger", 1, isInteger);
    _ = try vm.defineNative(ctor, "isNaN", 1, isNaN);
    _ = try vm.defineNative(ctor, "isSafeInteger", 1, isSafeInteger);
    _ = try vm.defineNative(proto, "toExponential", 1, toExponential);
    _ = try vm.defineNative(proto, "toFixed", 1, toFixed);
    _ = try vm.defineNative(proto, "toLocaleString", 0, toLocaleString);
    _ = try vm.defineNative(proto, "toPrecision", 1, toPrecision);
    _ = try vm.defineNative(proto, "toString", 1, toString);
    _ = try vm.defineNative(proto, "valueOf", 0, valueOf);

    const bproto = vm.intrinsics.boolean_prototype;
    _ = try b.installConstructor(vm, "Boolean", 1, booleanConstruct, bproto);
    _ = try vm.defineNative(bproto, "toString", 0, booleanToString);
    _ = try vm.defineNative(bproto, "valueOf", 0, booleanValueOf);
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    var n: Value = Value.fromInt(0);
    if (args.len > 0) {
        const prim = try vm.toNumeric(args[0]);
        n = if (prim.isBigInt()) Value.fromF64(try b.bigint.toNumber(vm, prim)) else prim;
    }
    if (new_target.isUndefined()) return n;
    const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.number_prototype);
    const o = try vm.objects.create(proto.asValue(), .number, @sizeOf(vmod.PrimitiveData));
    o.internal(vmod.PrimitiveData).value = n;
    return o.asValue();
}

fn isFinite(_: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isFinite(v.asNumber()));
}
fn isInteger(_: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.false_;
    const d = v.asNumber();
    return Value.fromBool(std.math.isFinite(d) and @trunc(d) == d);
}
fn isNaN(_: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    return Value.fromBool(v.isNumber() and std.math.isNan(v.asNumber()));
}
fn isSafeInteger(_: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isNumber()) return Value.false_;
    const d = v.asNumber();
    return Value.fromBool(std.math.isFinite(d) and @trunc(d) == d and @abs(d) <= 9007199254740991);
}

fn valueOf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromF64(try b.thisNumber(vm, this));
}

fn toLocaleString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const d = try b.thisNumber(vm, this);
    return strValue(try vm.toString(Value.fromF64(d)));
}

/// Number.prototype.toString(radix).
fn toString(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try b.thisNumber(vm, this);
    var radix: u8 = 10;
    if (!arg(args, 0).isUndefined()) {
        const r = try vm.toIntegerOrInfinity(arg(args, 0));
        if (r < 2 or r > 36) return vm.throwRangeError("toString() radix must be between 2 and 36");
        radix = @intFromFloat(r);
    }
    if (radix == 10) return strValue(try vm.toString(Value.fromF64(d)));
    var buf: [1100]u8 = undefined;
    return vm.str(radixToString(&buf, d, radix));
}

/// A double in a non-decimal radix: integer digits exactly, then the
/// fraction to enough digits to round-trip.
pub fn radixToString(buf: []u8, d_in: f64, radix: u8) []const u8 {
    if (std.math.isNan(d_in)) return "NaN";
    if (d_in == 0) return "0";
    if (std.math.isInf(d_in)) return if (d_in < 0) "-Infinity" else "Infinity";
    var d = d_in;
    var w: usize = 0;
    if (d < 0) {
        buf[w] = '-';
        w += 1;
        d = -d;
    }
    var int_part = @floor(d);
    var frac = d - int_part;
    // Integer digits, generated backwards.
    var tmp: [1100]u8 = undefined;
    var n: usize = 0;
    if (int_part == 0) {
        tmp[0] = '0';
        n = 1;
    } else {
        // Large integers: repeated division is exact for doubles.
        while (int_part >= 1 and n < tmp.len) {
            const q = @floor(int_part / @as(f64, @floatFromInt(radix)));
            const r = int_part - q * @as(f64, @floatFromInt(radix));
            tmp[n] = std.fmt.digitToChar(@intFromFloat(r), .lower);
            n += 1;
            int_part = q;
        }
    }
    while (n > 0) {
        n -= 1;
        buf[w] = tmp[n];
        w += 1;
    }
    if (frac > 0) {
        buf[w] = '.';
        w += 1;
        // Generate digits until the remaining fraction is below the
        // precision of the value (delta shrinks with each digit).
        var delta = 0.5 * (std.math.nextAfter(f64, d, std.math.inf(f64)) - d);
        delta = @max(std.math.nextAfter(f64, 0.0, 1.0), delta);
        if (delta > 0) {
            var count: usize = 0;
            while (count < 1080) : (count += 1) {
                frac *= @floatFromInt(radix);
                delta *= @floatFromInt(radix);
                const digit: u8 = @intFromFloat(@floor(frac));
                frac -= @floatFromInt(digit);
                if (frac > 0.5 or (frac == 0.5 and (digit & 1) == 1)) {
                    if (frac + delta > 1) {
                        // Round up and propagate.
                        var dd = digit + 1;
                        var ww = w;
                        while (true) {
                            if (dd < radix) {
                                buf[ww] = std.fmt.digitToChar(dd, .lower);
                                w = ww + 1;
                                return buf[0..w];
                            }
                            // Carry into the previous digit.
                            if (ww == 0 or buf[ww - 1] == '.') {
                                // Rare: carry into the integer part — fall back to the plain digit.
                                buf[ww] = std.fmt.digitToChar(digit, .lower);
                                w = ww + 1;
                                return buf[0..w];
                            }
                            ww -= 1;
                            dd = (std.fmt.charToDigit(buf[ww], radix) catch 0) + 1;
                        }
                    }
                }
                buf[w] = std.fmt.digitToChar(digit, .lower);
                w += 1;
                if (frac < delta) break;
            }
        }
    }
    return buf[0..w];
}

fn toFixed(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try b.thisNumber(vm, this);
    const f = try vm.toIntegerOrInfinity(arg(args, 0));
    if (f < 0 or f > 100 or std.math.isInf(f)) return vm.throwRangeError("toFixed() digits argument must be between 0 and 100");
    if (!std.math.isFinite(d)) return strValue(try vm.toString(Value.fromF64(d)));
    if (@abs(d) >= 1e21) return strValue(try vm.toString(Value.fromF64(d)));
    const digits: usize = @intFromFloat(f);
    var buf: [1300]u8 = undefined;
    return vm.str(fixedDigits(&buf, d, digits));
}

/// The exact decimal digits of a double via big integer arithmetic on
/// its mantissa and exponent.
pub fn fixedDigits(buf: []u8, d_in: f64, digits: usize) []const u8 {
    var d = d_in;
    var w: usize = 0;
    if (d < 0 or (d == 0 and std.math.signbit(d))) {
        if (d != 0) {
            buf[w] = '-';
            w += 1;
        }
        d = -d;
    }
    // x = m * 2^e exactly. n = round(x * 10^digits).
    const bits: u64 = @bitCast(d);
    const exp_bits: i32 = @intCast((bits >> 52) & 0x7ff);
    var mant: u64 = bits & ((1 << 52) - 1);
    var e: i32 = undefined;
    if (exp_bits == 0) {
        e = -1074;
    } else {
        mant |= 1 << 52;
        e = exp_bits - 1075;
    }
    // Big integer as base 1e9 limbs (little endian).
    var num = Big.init(mant);
    // num = mant * 10^digits * 2^e (e may be negative: divide with rounding).
    var i: usize = 0;
    while (i < digits) : (i += 1) num.mulSmall(10);
    if (e >= 0) {
        var k: i32 = 0;
        while (k < e) : (k += 1) num.mulSmall(2);
    } else {
        // Divide by 2^-e with round-half-up.
        const shift: u32 = @intCast(-e);
        num.divPow2Round(shift);
    }
    // Digits of num.
    var digs: [1200]u8 = undefined;
    const n = num.toDecimal(&digs);
    // Insert the decimal point `digits` from the right, zero-padding.
    if (n <= digits) {
        buf[w] = '0';
        w += 1;
        if (digits > 0) {
            buf[w] = '.';
            w += 1;
            var z: usize = 0;
            while (z < digits - n) : (z += 1) {
                buf[w] = '0';
                w += 1;
            }
            @memcpy(buf[w .. w + n], digs[0..n]);
            w += n;
        }
    } else {
        const int_len = n - digits;
        @memcpy(buf[w .. w + int_len], digs[0..int_len]);
        w += int_len;
        if (digits > 0) {
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w .. w + digits], digs[int_len..n]);
            w += digits;
        }
    }
    return buf[0..w];
}

/// A small arbitrary-precision unsigned integer for exact formatting.
pub const Big = struct {
    limbs: [140]u32 = undefined, // base 1e9; enough for 2^1074 * 10^100
    len: usize = 0,
    const base: u64 = 1_000_000_000;

    pub fn init(v: u64) Big {
        var b_: Big = .{};
        var x = v;
        while (x > 0) {
            b_.limbs[b_.len] = @intCast(x % base);
            b_.len += 1;
            x /= base;
        }
        return b_;
    }
    pub fn isZero(b_: *const Big) bool {
        return b_.len == 0;
    }
    pub fn mulSmall(b_: *Big, m: u32) void {
        var carry: u64 = 0;
        var i: usize = 0;
        while (i < b_.len) : (i += 1) {
            const v = @as(u64, b_.limbs[i]) * m + carry;
            b_.limbs[i] = @intCast(v % base);
            carry = v / base;
        }
        while (carry > 0) {
            b_.limbs[b_.len] = @intCast(carry % base);
            b_.len += 1;
            carry /= base;
        }
    }
    pub fn addSmall(b_: *Big, a: u32) void {
        var carry: u64 = a;
        var i: usize = 0;
        while (carry > 0) : (i += 1) {
            if (i == b_.len) {
                b_.limbs[b_.len] = 0;
                b_.len += 1;
            }
            const v = @as(u64, b_.limbs[i]) + carry;
            b_.limbs[i] = @intCast(v % base);
            carry = v / base;
        }
    }
    /// Divide by 2, returning the remainder.
    fn halve(b_: *Big) u32 {
        var rem: u64 = 0;
        var i = b_.len;
        while (i > 0) {
            i -= 1;
            const v = rem * base + b_.limbs[i];
            b_.limbs[i] = @intCast(v / 2);
            rem = v % 2;
        }
        while (b_.len > 0 and b_.limbs[b_.len - 1] == 0) b_.len -= 1;
        return @intCast(rem);
    }
    /// Divide by 2^shift, rounding half up (ties to the larger n).
    pub fn divPow2Round(b_: *Big, shift: u32) void {
        var last_bit: u32 = 0;
        var k: u32 = 0;
        while (k < shift) : (k += 1) last_bit = b_.halve();
        // Round half up: the last dropped bit set means >= half.
        if (last_bit == 1) b_.addSmall(1);
    }
    pub fn toDecimal(b_: *const Big, out: []u8) usize {
        if (b_.len == 0) {
            out[0] = '0';
            return 1;
        }
        var w: usize = 0;
        var i = b_.len;
        var first = true;
        while (i > 0) {
            i -= 1;
            var tmp: [9]u8 = undefined;
            const s = if (first) std.fmt.bufPrint(&tmp, "{d}", .{b_.limbs[i]}) catch unreachable else std.fmt.bufPrint(&tmp, "{d:0>9}", .{b_.limbs[i]}) catch unreachable;
            first = false;
            @memcpy(out[w .. w + s.len], s);
            w += s.len;
        }
        return w;
    }
};

fn toExponential(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try b.thisNumber(vm, this);
    const f = try vm.toIntegerOrInfinity(arg(args, 0));
    if (!std.math.isFinite(d)) return strValue(try vm.toString(Value.fromF64(d)));
    if (f < 0 or f > 100 or std.math.isInf(f)) return vm.throwRangeError("toExponential() argument must be between 0 and 100");
    var buf: [1400]u8 = undefined;
    const s = exponential(&buf, d, if (arg(args, 0).isUndefined()) null else @as(usize, @intFromFloat(f)));
    return vm.str(s);
}

/// The exact decimal digits of a finite double: `digits` (no leading
/// zeros, no trailing point) and the decimal exponent `exp10` such that
/// |x| = 0.d1d2d3... × 10^exp10. Zero gives a single "0".
const Exact = struct { digits: []const u8, exp10: i32 };

pub fn exactDigits(buf: []u8, d_in: f64) Exact {
    const d = @abs(d_in);
    if (d == 0) {
        buf[0] = '0';
        return .{ .digits = buf[0..1], .exp10 = 1 };
    }
    const bits: u64 = @bitCast(d);
    const exp_bits: i32 = @intCast((bits >> 52) & 0x7ff);
    var mant: u64 = bits & ((1 << 52) - 1);
    var e: i32 = undefined;
    if (exp_bits == 0) {
        e = -1074;
    } else {
        mant |= 1 << 52;
        e = exp_bits - 1075;
    }
    // x = mant × 2^e. For e ≥ 0 the value is the integer mant × 2^e; for
    // e < 0 it is mant × 5^-e × 10^e, so the digits of mant × 5^-e with
    // the point moved |e| places left.
    var num = Big.init(mant);
    var shift: i32 = 0;
    if (e >= 0) {
        var k: i32 = 0;
        while (k < e) : (k += 1) num.mulSmall(2);
    } else {
        var k: i32 = 0;
        while (k < -e) : (k += 1) num.mulSmall(5);
        shift = e;
    }
    const n = num.toDecimal(buf);
    // Strip trailing zeros (they carry no information past the point).
    var len = n;
    while (len > 1 and buf[len - 1] == '0') len -= 1;
    return .{ .digits = buf[0..len], .exp10 = @as(i32, @intCast(n)) + shift };
}

/// Round `ex` to `count` significant digits, half up (the larger n on a
/// tie, as toExponential/toPrecision specify). The result may carry
/// into one more digit (999 → 1000), raising the exponent.
fn roundDigits(out: []u8, ex: Exact, count: usize) Exact {
    var n = @min(ex.digits.len, count);
    @memcpy(out[0..n], ex.digits[0..n]);
    var exp10 = ex.exp10;
    if (ex.digits.len > count) {
        // Round half up: the first dropped digit decides ("5" and
        // anything after rounds up).
        if (ex.digits[count] >= '5') {
            var j = n;
            var carry = true;
            while (j > 0 and carry) {
                j -= 1;
                if (out[j] == '9') {
                    out[j] = '0';
                } else {
                    out[j] += 1;
                    carry = false;
                }
            }
            if (carry) {
                std.mem.copyBackwards(u8, out[1 .. n + 1], out[0..n]);
                out[0] = '1';
                exp10 += 1;
                // Keep `count` digits: the last one is a zero now.
            }
        }
    }
    // Pad with zeros to `count`.
    while (n < count) : (n += 1) out[n] = '0';
    return .{ .digits = out[0..count], .exp10 = exp10 };
}

/// x in exponential form with `digits` fraction digits (null: as many
/// as the shortest round-trip needs).
fn exponential(buf: []u8, d_in: f64, digits: ?usize) []const u8 {
    var w: usize = 0;
    if (d_in < 0 or (d_in == 0 and std.math.signbit(d_in) and false)) {
        buf[w] = '-';
        w += 1;
    }
    var digs: [1400]u8 = undefined;
    var n: usize = 0;
    var e: i32 = 0;
    if (digits) |want| {
        var ebuf: [1400]u8 = undefined;
        const ex = exactDigits(&ebuf, d_in);
        var rbuf: [200]u8 = undefined;
        const r = roundDigits(&rbuf, ex, want + 1);
        @memcpy(digs[0..r.digits.len], r.digits);
        n = r.digits.len;
        e = r.exp10 - 1;
        if (d_in == 0) e = 0;
    } else {
        var sbuf: [64]u8 = undefined;
        const sci = std.fmt.float.render(&sbuf, @abs(d_in), .{ .mode = .scientific }) catch return buf[0..0];
        const epos = std.mem.indexOfScalar(u8, sci, 'e').?;
        for (sci[0..epos]) |ch| if (ch != '.') {
            digs[n] = ch;
            n += 1;
        };
        e = std.fmt.parseInt(i32, sci[epos + 1 ..], 10) catch 0;
        if (d_in == 0) e = 0;
    }
    buf[w] = digs[0];
    w += 1;
    if (n > 1) {
        buf[w] = '.';
        w += 1;
        @memcpy(buf[w .. w + n - 1], digs[1..n]);
        w += n - 1;
    }
    buf[w] = 'e';
    w += 1;
    buf[w] = if (e < 0) '-' else '+';
    w += 1;
    const es = std.fmt.bufPrint(buf[w..], "{d}", .{@abs(e)}) catch unreachable;
    w += es.len;
    return buf[0..w];
}

fn toPrecision(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try b.thisNumber(vm, this);
    if (arg(args, 0).isUndefined()) return strValue(try vm.toString(Value.fromF64(d)));
    const p = try vm.toIntegerOrInfinity(arg(args, 0));
    if (!std.math.isFinite(d)) return strValue(try vm.toString(Value.fromF64(d)));
    if (p < 1 or p > 100 or std.math.isInf(p)) return vm.throwRangeError("toPrecision() argument must be between 1 and 100");
    const prec: usize = @intFromFloat(p);
    var buf: [1400]u8 = undefined;
    var w: usize = 0;
    if (d < 0) {
        buf[0] = '-';
        w = 1;
    }
    if (d == 0) {
        buf[w] = '0';
        w += 1;
        if (prec > 1) {
            buf[w] = '.';
            w += 1;
            @memset(buf[w .. w + prec - 1], '0');
            w += prec - 1;
        }
        return vm.str(buf[0..w]);
    }
    var ebuf: [1400]u8 = undefined;
    const ex = exactDigits(&ebuf, d);
    var rbuf: [200]u8 = undefined;
    const r = roundDigits(&rbuf, ex, prec);
    const digs = r.digits;
    const n = digs.len;
    const e = r.exp10 - 1;
    if (e < -6 or e >= @as(i32, @intCast(prec))) {
        // Exponential notation.
        buf[w] = digs[0];
        w += 1;
        if (n > 1) {
            buf[w] = '.';
            w += 1;
            @memcpy(buf[w .. w + n - 1], digs[1..n]);
            w += n - 1;
        }
        buf[w] = 'e';
        w += 1;
        buf[w] = if (e < 0) '-' else '+';
        w += 1;
        const xs = std.fmt.bufPrint(buf[w..], "{d}", .{@abs(e)}) catch unreachable;
        w += xs.len;
        return vm.str(buf[0..w]);
    }
    if (e == @as(i32, @intCast(prec)) - 1) {
        @memcpy(buf[w .. w + n], digs[0..n]);
        w += n;
        return vm.str(buf[0..w]);
    }
    if (e >= 0) {
        const int_len: usize = @intCast(e + 1);
        @memcpy(buf[w .. w + int_len], digs[0..int_len]);
        w += int_len;
        buf[w] = '.';
        w += 1;
        @memcpy(buf[w .. w + n - int_len], digs[int_len..n]);
        w += n - int_len;
        return vm.str(buf[0..w]);
    }
    buf[w] = '0';
    buf[w + 1] = '.';
    w += 2;
    const zeros: usize = @intCast(-e - 1);
    @memset(buf[w .. w + zeros], '0');
    w += zeros;
    @memcpy(buf[w .. w + n], digs[0..n]);
    w += n;
    return vm.str(buf[0..w]);
}

// ----------------------------------------------------------- Boolean

fn booleanConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    const v = Value.fromBool(vm.toBoolean(arg(args, 0)));
    if (new_target.isUndefined()) return v;
    const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.boolean_prototype);
    const o = try vm.objects.create(proto.asValue(), .boolean, @sizeOf(vmod.PrimitiveData));
    o.internal(vmod.PrimitiveData).value = v;
    return o.asValue();
}

fn thisBoolean(vm: *Vm, this: Value) Error!bool {
    if (this.isBool()) return this.asBool();
    if (this.isObject() and asObject(this).class == .boolean) return asObject(this).internal(vmod.PrimitiveData).value.asBool();
    return vm.throwTypeError("Boolean.prototype method called on incompatible receiver");
}

fn booleanToString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return strValue(if (try thisBoolean(vm, this)) vm.atoms.true_ else vm.atoms.false_);
}
fn booleanValueOf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return Value.fromBool(try thisBoolean(vm, this));
}

test "number: fixed and radix formatting" {
    var buf: [600]u8 = undefined;
    try std.testing.expectEqualStrings("1.00", fixedDigits(&buf, 1, 2));
    try std.testing.expectEqualStrings("0.13", fixedDigits(&buf, 0.125, 2));
    try std.testing.expectEqualStrings("1000000000000000128", fixedDigits(&buf, 1000000000000000128, 0));
    try std.testing.expectEqualStrings("0.000", fixedDigits(&buf, 0.0001, 3));
    try std.testing.expectEqualStrings("-1.5", fixedDigits(&buf, -1.5, 1));
    try std.testing.expectEqualStrings("ff", radixToString(&buf, 255, 16));
    try std.testing.expectEqualStrings("-101", radixToString(&buf, -5, 2));
    try std.testing.expectEqualStrings("0.1", radixToString(&buf, 0.5, 2));
    try std.testing.expectEqualStrings("0.24", radixToString(&buf, 0.3125, 8));
    var eb: [1400]u8 = undefined;
    const ex = exactDigits(&eb, 0.1);
    try std.testing.expectEqualStrings("1000000000000000055511151231257827021181583404541015625", ex.digits);
    try std.testing.expectEqual(@as(i32, 0), ex.exp10);
    try std.testing.expectEqualStrings("1.00e+0", exponential(&buf, 1, 2));
    try std.testing.expectEqualStrings("1.2346e+5", exponential(&buf, 123456, 4));
    try std.testing.expectEqualStrings("1e+2", exponential(&buf, 99.5, 0));
    try std.testing.expectEqualStrings("-1.5e-7", exponential(&buf, -1.5e-7, 1));
    try std.testing.expectEqualStrings("1.23456e+5", exponential(&buf, 123456, null));
}
