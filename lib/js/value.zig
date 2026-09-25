//! An ECMAScript value in 64 bits (NaN-boxing, JavaScriptCore's
//! arrangement): a double is stored offset by 2^49 so that its top 16
//! bits are never 0x0000 or 0xFFFE; an int32 has top bits 0xFFFE; a
//! heap pointer has top bits 0x0000 (48-bit addresses); and the four
//! constants — undefined, null, true, false — are small pointer-range
//! numbers no allocation can produce. Decoding is two compares, and a
//! double that is a small integer is kept as an int32 so arithmetic on
//! indexes and counters never touches the FPU.
const std = @import("std");
const heap = @import("heap.zig");

pub const Value = packed struct(u64) {
    bits: u64,

    const double_offset: u64 = 0x0002_0000_0000_0000;
    const int_tag: u64 = 0xFFFE_0000_0000_0000;
    const tag_mask: u64 = 0xFFFE_0000_0000_0000;

    pub const undefined_: Value = .{ .bits = 0x0a };
    pub const null_: Value = .{ .bits = 0x02 };
    pub const false_: Value = .{ .bits = 0x06 };
    pub const true_: Value = .{ .bits = 0x07 };
    /// A hole in an array or an uninitialized binding (TDZ): never a
    /// value a program sees.
    pub const empty: Value = .{ .bits = 0x00 };

    pub fn fromBool(b: bool) Value {
        return if (b) true_ else false_;
    }

    pub fn fromInt(i: i32) Value {
        return .{ .bits = int_tag | @as(u64, @as(u32, @bitCast(i))) };
    }

    pub fn fromF64(d: f64) Value {
        // A small integer stays an int32 (and -0 stays a double).
        if (d >= -2147483648.0 and d <= 2147483647.0) {
            const i: i32 = @intFromFloat(d);
            if (@as(f64, @floatFromInt(i)) == d and !(i == 0 and std.math.signbit(d))) return fromInt(i);
        }
        var bits: u64 = @bitCast(d);
        if (std.math.isNan(d)) bits = 0x7ff8_0000_0000_0000; // one NaN
        return .{ .bits = bits +% double_offset };
    }

    pub fn fromCell(c: *heap.Cell) Value {
        return .{ .bits = @intFromPtr(c) };
    }

    pub fn isUndefined(v: Value) bool {
        return v.bits == undefined_.bits;
    }
    pub fn isNull(v: Value) bool {
        return v.bits == null_.bits;
    }
    pub fn isNullish(v: Value) bool {
        return v.bits == undefined_.bits or v.bits == null_.bits;
    }
    pub fn isBool(v: Value) bool {
        return v.bits == true_.bits or v.bits == false_.bits;
    }
    pub fn isEmpty(v: Value) bool {
        return v.bits == 0;
    }
    pub fn isInt(v: Value) bool {
        return v.bits & tag_mask == int_tag;
    }
    pub fn isDouble(v: Value) bool {
        return v.bits & tag_mask != 0 and !v.isInt();
    }
    pub fn isNumber(v: Value) bool {
        return v.bits & tag_mask != 0;
    }
    pub fn isCell(v: Value) bool {
        return v.bits & tag_mask == 0 and v.bits > 0x0f;
    }

    pub fn asBool(v: Value) bool {
        return v.bits == true_.bits;
    }
    pub fn asInt(v: Value) i32 {
        return @bitCast(@as(u32, @truncate(v.bits)));
    }
    pub fn asDouble(v: Value) f64 {
        return @bitCast(v.bits -% double_offset);
    }
    /// Any number as a double.
    pub fn asNumber(v: Value) f64 {
        return if (v.isInt()) @floatFromInt(v.asInt()) else v.asDouble();
    }
    pub fn asCell(v: Value) *heap.Cell {
        return @ptrFromInt(v.bits);
    }

    pub fn isString(v: Value) bool {
        return v.isCell() and v.asCell().kind == .string;
    }
    pub fn isObject(v: Value) bool {
        return v.isCell() and v.asCell().kind == .object;
    }
    pub fn isSymbol(v: Value) bool {
        return v.isCell() and v.asCell().kind == .symbol;
    }
    pub fn isBigInt(v: Value) bool {
        return v.isCell() and v.asCell().kind == .bigint;
    }

    /// The same value (SameValue for non-numbers, bitwise for numbers
    /// once both are canonical): what a map keys by.
    pub fn eqlBits(a: Value, b: Value) bool {
        return a.bits == b.bits;
    }
};

test "value: numbers round-trip and small integers stay integers" {
    try std.testing.expect(Value.fromF64(3).isInt());
    try std.testing.expectEqual(@as(i32, 3), Value.fromF64(3).asInt());
    try std.testing.expect(Value.fromF64(3.5).isDouble());
    try std.testing.expectEqual(@as(f64, 3.5), Value.fromF64(3.5).asDouble());
    try std.testing.expect(Value.fromF64(-0.0).isDouble());
    try std.testing.expect(std.math.signbit(Value.fromF64(-0.0).asDouble()));
    try std.testing.expect(std.math.isNan(Value.fromF64(std.math.nan(f64)).asNumber()));
    try std.testing.expect(Value.fromF64(2147483648.0).isDouble());
    try std.testing.expect(Value.fromInt(-1).isInt());
    try std.testing.expectEqual(@as(i32, -1), Value.fromInt(-1).asInt());
    try std.testing.expect(!Value.fromInt(-1).isCell());
    try std.testing.expect(Value.fromF64(1e300).isDouble());
    try std.testing.expect(Value.fromF64(-1e300).isDouble());
    try std.testing.expectEqual(@as(f64, -1e300), Value.fromF64(-1e300).asDouble());
}

test "value: the constants are not numbers, cells, or each other" {
    const vs = [_]Value{ Value.undefined_, Value.null_, Value.true_, Value.false_, Value.empty };
    for (vs, 0..) |v, i| {
        try std.testing.expect(!v.isNumber() and !v.isCell());
        for (vs[0..i]) |w| try std.testing.expect(!v.eqlBits(w));
    }
    try std.testing.expect(Value.true_.asBool() and !Value.false_.asBool() and Value.undefined_.isNullish());
}
