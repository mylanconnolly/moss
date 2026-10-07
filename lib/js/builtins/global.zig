//! The global object's own functions and values (§19): globalThis,
//! eval (indirect), isFinite, isNaN, parseFloat, parseInt, the URI
//! functions, and Annex B's escape/unescape.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const compiler = @import("../compiler.zig");
const interp = @import("../interp.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const g = vm.global;
    try vm.defineValue(g, "globalThis", g.asValue(), .hidden);
    try vm.defineValue(g, "undefined", Value.undefined_, .frozen);
    try vm.defineValue(g, "NaN", Value.fromF64(std.math.nan(f64)), .frozen);
    try vm.defineValue(g, "Infinity", Value.fromF64(std.math.inf(f64)), .frozen);
    vm.intrinsics.eval = try vm.defineNative(g, "eval", 1, eval);
    _ = try vm.defineNative(g, "isFinite", 1, isFinite);
    _ = try vm.defineNative(g, "isNaN", 1, isNaN);
    const pf = try vm.defineNative(g, "parseFloat", 1, parseFloat);
    const pi = try vm.defineNative(g, "parseInt", 2, parseInt);
    // Number.parseFloat/parseInt are the same function objects.
    const number_ctor = try vm.get(g, .{ .atom = try vm.atom("Number") }, g.asValue());
    if (number_ctor.isObject()) {
        try vm.defineValue(b.asObject(number_ctor), "parseFloat", pf.asValue(), .hidden);
        try vm.defineValue(b.asObject(number_ctor), "parseInt", pi.asValue(), .hidden);
    }
    _ = try vm.defineNative(g, "encodeURI", 1, encodeURI);
    _ = try vm.defineNative(g, "encodeURIComponent", 1, encodeURIComponent);
    _ = try vm.defineNative(g, "decodeURI", 1, decodeURI);
    _ = try vm.defineNative(g, "decodeURIComponent", 1, decodeURIComponent);
    _ = try vm.defineNative(g, "escape", 1, escape);
    _ = try vm.defineNative(g, "unescape", 1, unescape);
}

/// Indirect eval: global code in the global environment.
fn eval(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const x = arg(args, 0);
    if (!x.isString()) return x;
    const src = try vm.utf8(asString(x), vm.meta);
    defer vm.meta.free(src);
    const code = compiler.compile(vm.meta, &vm.heap, &vm.strings, src, .{ .eval_ctx = .{ .eval = true, .global = true }, .name = "<eval>" }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return vm.throwSyntaxError(compiler.last_error),
    };
    try interp.evalDeclarationCheck(vm, null, code.data, false, false);
    return interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_);
}

fn isFinite(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const d = try vm.toNumber(arg(args, 0));
    return Value.fromBool(std.math.isFinite(d));
}

fn isNaN(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const d = try vm.toNumber(arg(args, 0));
    return Value.fromBool(std.math.isNan(d));
}

fn isStrWhitespace(cp: u21) bool {
    return switch (cp) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0, 0xfeff, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn trimStartUtf8(s: []const u8) []const u8 {
    var i: usize = 0;
    while (i < s.len) {
        const n = std.unicode.utf8ByteSequenceLength(s[i]) catch 1;
        if (i + n > s.len) break;
        const cp = std.unicode.utf8Decode(s[i .. i + n]) catch break;
        if (!isStrWhitespace(cp)) break;
        i += n;
    }
    return s[i..];
}

pub fn parseFloat(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try vm.toString(arg(args, 0));
    const text = try vm.utf8(s, vm.meta);
    defer vm.meta.free(text);
    const t = trimStartUtf8(text);
    // The longest prefix that is a StrDecimalLiteral.
    var i: usize = 0;
    if (i < t.len and (t[i] == '+' or t[i] == '-')) i += 1;
    if (std.mem.startsWith(u8, t[i..], "Infinity")) {
        return Value.fromF64(if (t[0] == '-') -std.math.inf(f64) else std.math.inf(f64));
    }
    var digits: usize = 0;
    while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits += 1;
    if (i < t.len and t[i] == '.') {
        i += 1;
        while (i < t.len and std.ascii.isDigit(t[i])) : (i += 1) digits += 1;
    }
    if (digits == 0) return Value.fromF64(std.math.nan(f64));
    var end = i;
    if (i < t.len and (t[i] == 'e' or t[i] == 'E')) {
        var j = i + 1;
        if (j < t.len and (t[j] == '+' or t[j] == '-')) j += 1;
        var ed: usize = 0;
        while (j < t.len and std.ascii.isDigit(t[j])) : (j += 1) ed += 1;
        if (ed > 0) end = j;
    }
    var lit = t[0..end];
    // "1." parses as 1; strip a trailing dot for the float parser.
    if (lit.len > 0 and lit[lit.len - 1] == '.') lit = lit[0 .. lit.len - 1];
    const v = std.fmt.parseFloat(f64, lit) catch return Value.fromF64(std.math.nan(f64));
    return Value.fromF64(v);
}

pub fn parseInt(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try vm.toString(arg(args, 0));
    const text = try vm.utf8(s, vm.meta);
    defer vm.meta.free(text);
    var t = trimStartUtf8(text);
    var sign: f64 = 1;
    if (t.len > 0 and (t[0] == '+' or t[0] == '-')) {
        if (t[0] == '-') sign = -1;
        t = t[1..];
    }
    var radix = try vm.toInt32(arg(args, 1));
    var strip_prefix = true;
    if (radix != 0) {
        if (radix < 2 or radix > 36) return Value.fromF64(std.math.nan(f64));
        if (radix != 16) strip_prefix = false;
    } else radix = 10;
    if (strip_prefix and t.len >= 2 and t[0] == '0' and (t[1] == 'x' or t[1] == 'X')) {
        t = t[2..];
        radix = 16;
    }
    var v: f64 = 0;
    var n: usize = 0;
    const r: u8 = @intCast(radix);
    // Exact for up to 2^53; beyond that the digits are accumulated in
    // floating point as the specification allows ("approximated").
    while (n < t.len) : (n += 1) {
        const d = std.fmt.charToDigit(t[n], r) catch break;
        v = v * @as(f64, @floatFromInt(r)) + @as(f64, @floatFromInt(d));
    }
    if (n == 0) return Value.fromF64(std.math.nan(f64));
    if (radix == 10 and n > 15) {
        // Re-parse decimal digits exactly to get correct rounding.
        v = std.fmt.parseFloat(f64, t[0..n]) catch v;
    }
    return Value.fromF64(sign * v);
}

// ------------------------------------------------------------- URIs

const uri_reserved = ";/?:@&=+$,";
const uri_unescaped_extra = "-_.!~*'()";

fn isUnescaped(ch: u8, comptime extra: []const u8) bool {
    if (std.ascii.isAlphanumeric(ch)) return true;
    for (uri_unescaped_extra) |c| if (c == ch) return true;
    for (extra) |c| if (c == ch) return true;
    return false;
}

fn encode(vm: *Vm, v: Value, comptime keep: []const u8) Error!Value {
    const s = try vm.strings.flatten(try vm.toString(v));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const unit = s.unitAt(i);
        if (unit < 128 and isUnescaped(@intCast(unit), keep)) {
            try out.append(vm.meta, @intCast(unit));
            continue;
        }
        var cp: u21 = unit;
        if (unit >= 0xdc00 and unit <= 0xdfff) return vm.throwError(.URIError, "URI malformed");
        if (unit >= 0xd800 and unit <= 0xdbff) {
            if (i + 1 >= s.len) return vm.throwError(.URIError, "URI malformed");
            const lo = s.unitAt(i + 1);
            if (lo < 0xdc00 or lo > 0xdfff) return vm.throwError(.URIError, "URI malformed");
            cp = 0x10000 + ((@as(u21, unit) - 0xd800) << 10) + (lo - 0xdc00);
            i += 1;
        }
        var buf: [4]u8 = undefined;
        const n = std.unicode.utf8Encode(cp, &buf) catch return vm.throwError(.URIError, "URI malformed");
        for (buf[0..n]) |byte| {
            try out.append(vm.meta, '%');
            try out.append(vm.meta, std.fmt.digitToChar(byte >> 4, .upper));
            try out.append(vm.meta, std.fmt.digitToChar(byte & 15, .upper));
        }
    }
    return vm.str(out.items);
}

fn decode(vm: *Vm, v: Value, comptime reserved: []const u8) Error!Value {
    const s = try vm.strings.flatten(try vm.toString(v));
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const unit = s.unitAt(i);
        if (unit != '%') {
            try units.append(vm.meta, unit);
            continue;
        }
        const start = i;
        if (i + 2 >= s.len) return vm.throwError(.URIError, "URI malformed");
        const byte = hexByte(s.unitAt(i + 1), s.unitAt(i + 2)) orelse return vm.throwError(.URIError, "URI malformed");
        i += 2;
        if (byte < 0x80) {
            var keep = false;
            for (reserved) |r| if (r == byte) {
                keep = true;
            };
            if (keep) {
                var j = start;
                while (j <= i) : (j += 1) try units.append(vm.meta, s.unitAt(j));
            } else try units.append(vm.meta, byte);
            continue;
        }
        const n = std.unicode.utf8ByteSequenceLength(byte) catch return vm.throwError(.URIError, "URI malformed");
        var buf: [4]u8 = undefined;
        buf[0] = byte;
        var k: usize = 1;
        while (k < n) : (k += 1) {
            if (i + 3 > s.len or s.unitAt(i + 1) != '%') return vm.throwError(.URIError, "URI malformed");
            const b2 = hexByte(s.unitAt(i + 2), s.unitAt(i + 3)) orelse return vm.throwError(.URIError, "URI malformed");
            if (b2 & 0xc0 != 0x80) return vm.throwError(.URIError, "URI malformed");
            buf[k] = b2;
            i += 3;
        }
        const cp = std.unicode.utf8Decode(buf[0..n]) catch return vm.throwError(.URIError, "URI malformed");
        if (cp >= 0xd800 and cp <= 0xdfff) return vm.throwError(.URIError, "URI malformed");
        if (cp < 0x10000) {
            try units.append(vm.meta, @intCast(cp));
        } else {
            const c = cp - 0x10000;
            try units.append(vm.meta, @intCast(0xd800 + (c >> 10)));
            try units.append(vm.meta, @intCast(0xdc00 + (c & 0x3ff)));
        }
    }
    return strValue(try vm.strings.fromUnits(units.items));
}

fn hexByte(hi: u16, lo: u16) ?u8 {
    if (hi > 127 or lo > 127) return null;
    const h = std.fmt.charToDigit(@intCast(hi), 16) catch return null;
    const l = std.fmt.charToDigit(@intCast(lo), 16) catch return null;
    return (h << 4) | l;
}

fn encodeURI(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return encode(vm, arg(args, 0), uri_reserved ++ "#");
}
fn encodeURIComponent(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return encode(vm, arg(args, 0), "");
}
fn decodeURI(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return decode(vm, arg(args, 0), uri_reserved ++ "#");
}
fn decodeURIComponent(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    return decode(vm, arg(args, 0), "");
}

fn escape(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    var out: std.ArrayList(u8) = .empty;
    defer out.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const u = s.unitAt(i);
        if (u < 128 and (std.ascii.isAlphanumeric(@intCast(u)) or std.mem.indexOfScalar(u8, "@*_+-./", @intCast(u)) != null)) {
            try out.append(vm.meta, @intCast(u));
        } else if (u < 256) {
            var tmp: [8]u8 = undefined;
            try out.appendSlice(vm.meta, std.fmt.bufPrint(&tmp, "%{X:0>2}", .{u}) catch unreachable);
        } else {
            var tmp: [8]u8 = undefined;
            try out.appendSlice(vm.meta, std.fmt.bufPrint(&tmp, "%u{X:0>4}", .{u}) catch unreachable);
        }
    }
    return vm.str(out.items);
}

fn unescape(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const u = s.unitAt(i);
        if (u == '%') {
            if (i + 5 < s.len and s.unitAt(i + 1) == 'u') {
                var v: u16 = 0;
                var ok = true;
                for (0..4) |k| {
                    const c = s.unitAt(i + 2 + k);
                    const d = if (c < 128) std.fmt.charToDigit(@intCast(c), 16) catch null else null;
                    if (d == null) {
                        ok = false;
                        break;
                    }
                    v = v * 16 + d.?;
                }
                if (ok) {
                    try units.append(vm.meta, v);
                    i += 5;
                    continue;
                }
            }
            if (i + 2 < s.len) if (hexByte(s.unitAt(i + 1), s.unitAt(i + 2))) |byte| {
                try units.append(vm.meta, byte);
                i += 2;
                continue;
            };
        }
        try units.append(vm.meta, u);
    }
    return strValue(try vm.strings.fromUnits(units.items));
}
