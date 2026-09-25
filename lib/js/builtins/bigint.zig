//! BigInt (§6.1.6.2, §21.2): arbitrary-precision integers as heap cells
//! of limbs, arithmetic through std's big integers (operands viewed in
//! place, results copied into fresh cells), the conversions and the
//! constructor's functions.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const String = b.String;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;
const big = std.math.big;
const Limb = big.Limb;
const Managed = big.int.Managed;
const Const = big.int.Const;

/// A BigInt cell: sign, limb count, then the limbs (little endian).
pub const BigIntCell = extern struct {
    header: heap.Cell,
    negative: bool,
    _pad: [3]u8 = @splat(0),
    len: u32,

    pub fn limbs(c: *BigIntCell) []Limb {
        const base: [*]u8 = @ptrCast(c);
        const p: [*]Limb = @ptrCast(@alignCast(base + 16));
        return p[0..c.len];
    }
    pub fn toConst(c: *BigIntCell) Const {
        return .{ .limbs = c.limbs(), .positive = !c.negative };
    }
};

fn cellOf(v: Value) *BigIntCell {
    return v.asCell().as(BigIntCell);
}

/// A value from a big integer (normalized; zero is positive).
pub fn fromConst(vm: *Vm, c: Const) Error!Value {
    var n = c.limbs.len;
    while (n > 0 and c.limbs[n - 1] == 0) n -= 1;
    const cell = try vm.heap.alloc(.bigint, 16 + @max(n, 1) * @sizeOf(Limb));
    const bc = cell.as(BigIntCell);
    bc.negative = if (n == 0) false else !c.positive;
    bc.len = @intCast(@max(n, 1));
    const dst = bc.limbs();
    if (n == 0) {
        dst[0] = 0;
    } else @memcpy(dst[0..n], c.limbs[0..n]);
    return Value.fromCell(cell);
}

pub fn fromI64(vm: *Vm, v: i64) Error!Value {
    var m = try Managed.initSet(vm.meta, v);
    defer m.deinit();
    return fromConst(vm, m.toConst());
}

pub fn fromU64(vm: *Vm, v: u64) Error!Value {
    var m = try Managed.initSet(vm.meta, v);
    defer m.deinit();
    return fromConst(vm, m.toConst());
}

/// The low 64 bits of a BigInt in two's complement (the value modulo
/// 2^64): what the 64-bit typed arrays store.
pub fn toU64Bits(v: Value) u64 {
    const c = cellOf(v);
    const low: u64 = @truncate(c.limbs()[0]);
    return if (c.negative) 0 -% low else low;
}

/// A double that is an integer, as a BigInt.
fn fromF64(vm: *Vm, d: f64) Error!Value {
    if (@abs(d) < 9.0e18) return fromI64(vm, @intFromFloat(d));
    // Exact: the mantissa shifted by the exponent.
    const bits: u64 = @bitCast(@abs(d));
    const exp: i32 = @intCast((bits >> 52) & 0x7ff);
    const mant: u64 = (bits & ((1 << 52) - 1)) | (1 << 52);
    var m = try Managed.initSet(vm.meta, mant);
    defer m.deinit();
    try m.shiftLeft(&m, @intCast(exp - 1075));
    if (d < 0) m.negate();
    return fromConst(vm, m.toConst());
}

pub fn isNonZero(v: Value) bool {
    const c = cellOf(v);
    return !(c.len == 1 and c.limbs()[0] == 0);
}

pub fn toString(vm: *Vm, v: Value, radix: u8) Error!*String {
    const c = cellOf(v);
    const s = try c.toConst().toStringAlloc(vm.meta, radix, .lower);
    defer vm.meta.free(s);
    return vm.strings.fromUtf8(s);
}

pub fn equals(a: Value, b_: Value) bool {
    return cellOf(a).toConst().eql(cellOf(b_).toConst());
}

pub fn compare(a: Value, b_: Value) std.math.Order {
    return cellOf(a).toConst().order(cellOf(b_).toConst());
}

/// Compare a BigInt with a number (not NaN): by sign, then by bit
/// length, then exactly against the double's integer part, and the
/// fraction breaks a tie.
pub fn compareNumber(a: Value, d: f64) std.math.Order {
    if (std.math.isInf(d)) return if (d > 0) .lt else .gt;
    const c = cellOf(a).toConst();
    const whole = @trunc(d);
    const cneg = !c.positive and !c.eqlZero();
    const dneg = whole < 0 or (whole == 0 and d < 0);
    if (c.eqlZero() and whole == 0) {
        if (d > 0) return .lt;
        if (d < 0) return .gt;
        return .eq;
    }
    if (cneg != dneg) return if (cneg) .lt else .gt;
    // Same sign: compare magnitudes, the sign flips the answer.
    const mag = magnitudeOrder(c, @abs(whole), @abs(d) > @abs(whole));
    return if (cneg) mag.invert() else mag;
}

/// |c| against |whole| (+ a fraction), both non-negative.
fn magnitudeOrder(c: Const, whole: f64, has_fraction: bool) std.math.Order {
    if (whole == 0) return if (c.eqlZero()) (if (has_fraction) .lt else .eq) else .gt;
    const bits_d: u64 = @bitCast(whole);
    const exp: i32 = @intCast((bits_d >> 52) & 0x7ff);
    const dbits: usize = @intCast(exp - 1022); // bit length of the integer part
    const cbits = c.bitCountAbs();
    if (cbits != dbits) return if (cbits < dbits) .lt else .gt;
    const abs_c: Const = .{ .limbs = c.limbs, .positive = true };
    var ord: std.math.Order = undefined;
    if (dbits <= 64) {
        const w: u64 = @intFromFloat(whole);
        const cv = abs_c.toInt(u64) catch unreachable;
        ord = std.math.order(cv, w);
    } else {
        // The double is mant << (dbits - 53), exactly: compare c's top
        // 53 bits with the mantissa; any lower set bit makes c greater.
        const mant: u64 = (bits_d & ((1 << 52) - 1)) | (1 << 52);
        ord = compareTopBits(abs_c, mant, cbits);
    }
    if (ord != .eq) return ord;
    return if (has_fraction) .lt else .eq;
}

fn compareTopBits(c: Const, mant: u64, cbits: usize) std.math.Order {
    const lb = @bitSizeOf(Limb);
    const shift = cbits - 53;
    const li = shift / lb;
    const bo: std.math.Log2Int(Limb) = @intCast(shift % lb);
    var top: u64 = @intCast(c.limbs[li] >> bo);
    if (bo != 0 and li + 1 < c.limbs.len) {
        const hi: u64 = @intCast(c.limbs[li + 1] & ((@as(Limb, 1) << bo) - 1));
        top |= hi << @intCast(lb - @as(usize, bo));
    }
    top &= (1 << 53) - 1;
    if (top != mant) return if (top < mant) .lt else .gt;
    if ((c.limbs[li] & ((@as(Limb, 1) << bo) - 1)) != 0) return .gt;
    var j: usize = 0;
    while (j < li) : (j += 1) if (c.limbs[j] != 0) return .gt;
    return .eq;
}

pub fn equalsNumber(a: Value, d: f64) bool {
    if (std.math.isNan(d) or std.math.isInf(d)) return false;
    if (d != @trunc(d)) return false;
    return compareNumber(a, d) == .eq;
}

pub fn toNumber(vm: *Vm, v: Value) Error!f64 {
    const c = cellOf(v).toConst();
    _ = vm;
    return c.toFloat(f64, .nearest_even)[0];
}

/// StringToBigInt (§7.1.14): null when the text is not an integer literal.
pub fn fromString(vm: *Vm, s: *String) Error!?Value {
    const text = try vm.utf8(s, vm.meta);
    defer vm.meta.free(text);
    return parseLiteral(vm, std.mem.trim(u8, text, &vmod.whitespace_utf8), true);
}

/// A BigInt literal's digits (without the `n`), or a string's text.
fn parseLiteral(vm: *Vm, text_in: []const u8, allow_sign: bool) Error!?Value {
    var text = text_in;
    if (text.len == 0) return try fromI64(vm, 0);
    var negative = false;
    var radix: u8 = 10;
    if (text.len >= 2 and text[0] == '0') {
        switch (text[1]) {
            'x', 'X' => radix = 16,
            'o', 'O' => radix = 8,
            'b', 'B' => radix = 2,
            else => {},
        }
        if (radix != 10) text = text[2..];
    } else if (allow_sign and (text[0] == '+' or text[0] == '-')) {
        negative = text[0] == '-';
        text = text[1..];
    }
    if (text.len == 0) return null;
    // Digits (numeric separators allowed in literals).
    var digits: std.ArrayList(u8) = .empty;
    defer digits.deinit(vm.meta);
    for (text) |ch| {
        if (ch == '_') continue;
        _ = std.fmt.charToDigit(ch, radix) catch return null;
        try digits.append(vm.meta, ch);
    }
    if (digits.items.len == 0) return null;
    var m = try Managed.init(vm.meta);
    defer m.deinit();
    m.setString(radix, digits.items) catch return null;
    if (negative) m.negate();
    return try fromConst(vm, m.toConst());
}

pub fn fromLiteral(vm: *Vm, s: *String) Error!Value {
    const text = try vm.utf8(s, vm.meta);
    defer vm.meta.free(text);
    const digits = if (text.len > 0 and text[text.len - 1] == 'n') text[0 .. text.len - 1] else text;
    return (try parseLiteral(vm, digits, false)) orelse vm.throwSyntaxError("Invalid BigInt literal");
}

pub fn looseEqualsString(vm: *Vm, a: Value, s: *String) Error!bool {
    const n = (try fromString(vm, s)) orelse return false;
    return equals(a, n);
}

fn managed(vm: *Vm, v: Value) Error!Managed {
    var m = try Managed.init(vm.meta);
    try m.copy(cellOf(v).toConst());
    return m;
}

pub fn binary(vm: *Vm, op: Vm.ArithOp, a: Value, b_: Value) Error!Value {
    if (!a.isBigInt() or !b_.isBigInt()) return vm.throwTypeError("Cannot mix BigInt and other types, use explicit conversions");
    var x = try managed(vm, a);
    defer x.deinit();
    var y = try managed(vm, b_);
    defer y.deinit();
    var r = try Managed.init(vm.meta);
    defer r.deinit();
    switch (op) {
        .add => try r.add(&x, &y),
        .sub => try r.sub(&x, &y),
        .mul => try r.mul(&x, &y),
        .div => {
            if (y.eqlZero()) return vm.throwRangeError("Division by zero");
            var rem = try Managed.init(vm.meta);
            defer rem.deinit();
            try r.divTrunc(&rem, &x, &y);
        },
        .mod => {
            if (y.eqlZero()) return vm.throwRangeError("Division by zero");
            var q = try Managed.init(vm.meta);
            defer q.deinit();
            try q.divTrunc(&r, &x, &y);
        },
        .exp => {
            if (!y.isPositive() and !y.eqlZero()) return vm.throwRangeError("Exponent must be non-negative");
            const e = y.toConst().toInt(u32) catch return vm.throwRangeError("Maximum BigInt size exceeded");
            if (x.eqlZero() or (x.toConst().eql(big.int.Const{ .limbs = &.{1}, .positive = true }))) {
                try r.copy(if (e == 0) (big.int.Const{ .limbs = &.{1}, .positive = true }) else x.toConst());
            } else {
                if (e > 1 << 20) return vm.throwRangeError("Maximum BigInt size exceeded");
                try r.pow(&x, e);
            }
        },
        .shl, .shr => {
            var shift = y.toConst().toInt(i64) catch return vm.throwRangeError("Maximum BigInt size exceeded");
            if (op == .shr) shift = -shift;
            if (shift >= 0) {
                if (shift > 1 << 24) return vm.throwRangeError("Maximum BigInt size exceeded");
                try r.shiftLeft(&x, @intCast(shift));
            } else {
                // Arithmetic right shift (std's shiftRight floors).
                const n: usize = @intCast(@min(-shift, 1 << 24));
                try r.shiftRight(&x, n);
            }
        },
        .ushr => return vm.throwTypeError("BigInts have no unsigned right shift, use >> instead"),
        .band => try r.bitAnd(&x, &y),
        .bor => try r.bitOr(&x, &y),
        .bxor => try r.bitXor(&x, &y),
    }
    return fromConst(vm, r.toConst());
}

pub fn negate(vm: *Vm, a: Value) Error!Value {
    var x = try managed(vm, a);
    defer x.deinit();
    x.negate();
    return fromConst(vm, x.toConst());
}

pub fn bitNot(vm: *Vm, a: Value) Error!Value {
    // ~x = -x - 1
    var x = try managed(vm, a);
    defer x.deinit();
    x.negate();
    var one = try Managed.initSet(vm.meta, 1);
    defer one.deinit();
    try x.sub(&x, &one);
    return fromConst(vm, x.toConst());
}

// ------------------------------------------------------------ builtin

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.bigint_prototype;
    const ctor = try b.installConstructor(vm, "BigInt", 1, construct, proto);
    _ = try vm.defineNative(ctor, "asIntN", 2, asIntN);
    _ = try vm.defineNative(ctor, "asUintN", 2, asUintN);
    _ = try vm.defineNative(proto, "toLocaleString", 0, protoToLocaleString);
    _ = try vm.defineNative(proto, "toString", 0, protoToString);
    _ = try vm.defineNative(proto, "valueOf", 0, protoValueOf);
    try b.setToStringTag(vm, proto, "BigInt");
}

/// ToBigInt (§7.1.13).
pub fn toBigInt(vm: *Vm, v: Value) Error!Value {
    const prim = try vm.toPrimitive(v, .number);
    if (prim.isBigInt()) return prim;
    if (prim.isBool()) return fromI64(vm, if (prim.asBool()) 1 else 0);
    if (prim.isString()) return (try fromString(vm, asString(prim))) orelse vm.throwSyntaxError("Cannot convert string to a BigInt");
    if (prim.isNumber()) return vm.throwTypeError("Cannot convert a Number to a BigInt");
    if (prim.isSymbol()) return vm.throwTypeError("Cannot convert a Symbol to a BigInt");
    return vm.throwTypeError("Cannot convert undefined or null to a BigInt");
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (!new_target.isUndefined()) return vm.throwTypeError("BigInt is not a constructor");
    const prim = try vm.toPrimitive(arg(args, 0), .number);
    if (prim.isNumber()) {
        const d = prim.asNumber();
        if (!std.math.isFinite(d) or d != @trunc(d)) return vm.throwRangeError("The number cannot be converted to a BigInt because it is not an integer");
        return fromF64(vm, d);
    }
    return toBigInt(vm, prim);
}

fn thisBigInt(vm: *Vm, this: Value) Error!Value {
    if (this.isBigInt()) return this;
    if (this.isObject() and asObject(this).class == .bigint) return asObject(this).internal(vmod.PrimitiveData).value;
    return vm.throwTypeError("BigInt.prototype method called on incompatible receiver");
}

fn protoToString(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const v = try thisBigInt(vm, this);
    var radix: u8 = 10;
    if (!arg(args, 0).isUndefined()) {
        const r = try vm.toIntegerOrInfinity(arg(args, 0));
        if (r < 2 or r > 36) return vm.throwRangeError("toString() radix must be between 2 and 36");
        radix = @intFromFloat(r);
    }
    return strValue(try toString(vm, v, radix));
}

fn protoToLocaleString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return strValue(try toString(vm, try thisBigInt(vm, this), 10));
}

fn protoValueOf(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return thisBigInt(vm, this);
}

/// BigInt.asIntN / asUintN: the value modulo 2^bits, signed or not.
fn asN(vm: *Vm, args: []const Value, signed: bool) Error!Value {
    const bits = try vm.toIndex(arg(args, 0));
    const v = try toBigInt(vm, arg(args, 1));
    if (bits == 0) return fromI64(vm, 0);
    if (bits > 1 << 24) return vm.throwRangeError("Maximum BigInt size exceeded");
    var x = try managed(vm, v);
    defer x.deinit();
    // mod 2^bits into [0, 2^bits)
    var modulus = try Managed.initSet(vm.meta, 1);
    defer modulus.deinit();
    try modulus.shiftLeft(&modulus, @intCast(bits));
    var q = try Managed.init(vm.meta);
    defer q.deinit();
    var r = try Managed.init(vm.meta);
    defer r.deinit();
    try q.divFloor(&r, &x, &modulus);
    if (signed) {
        // r >= 2^(bits-1) → r - 2^bits
        var half = try Managed.initSet(vm.meta, 1);
        defer half.deinit();
        try half.shiftLeft(&half, @intCast(bits - 1));
        if (r.toConst().order(half.toConst()) != .lt) try r.sub(&r, &modulus);
    }
    return fromConst(vm, r.toConst());
}

fn asIntN(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return asN(vm, args, true);
}
fn asUintN(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return asN(vm, args, false);
}
