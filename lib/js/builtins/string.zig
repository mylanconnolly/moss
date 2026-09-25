//! String (§22.1): the constructor, fromCharCode/fromCodePoint/raw and
//! the prototype. Methods work on UTF-16 code units through the
//! flattened string; the regular-expression-taking ones delegate to
//! the pattern's @@symbol method and otherwise treat it as a string.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const iterator = @import("iterator.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const String = b.String;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.string_prototype;
    const ctor = try b.installConstructor(vm, "String", 1, construct, proto);
    _ = try vm.defineNative(ctor, "fromCharCode", 1, fromCharCode);
    _ = try vm.defineNative(ctor, "fromCodePoint", 1, fromCodePoint);
    _ = try vm.defineNative(ctor, "raw", 1, raw);
    _ = try vm.defineNative(proto, "at", 1, at);
    _ = try vm.defineNative(proto, "charAt", 1, charAt);
    _ = try vm.defineNative(proto, "charCodeAt", 1, charCodeAt);
    _ = try vm.defineNative(proto, "codePointAt", 1, codePointAt);
    _ = try vm.defineNative(proto, "concat", 1, concat);
    _ = try vm.defineNative(proto, "endsWith", 1, endsWith);
    _ = try vm.defineNative(proto, "includes", 1, includes);
    _ = try vm.defineNative(proto, "indexOf", 1, indexOf);
    _ = try vm.defineNative(proto, "isWellFormed", 0, isWellFormed);
    _ = try vm.defineNative(proto, "lastIndexOf", 1, lastIndexOf);
    _ = try vm.defineNative(proto, "localeCompare", 1, localeCompare);
    _ = try vm.defineNative(proto, "match", 1, match);
    _ = try vm.defineNative(proto, "matchAll", 1, matchAll);
    _ = try vm.defineNative(proto, "normalize", 0, normalize);
    _ = try vm.defineNative(proto, "padEnd", 1, padEnd);
    _ = try vm.defineNative(proto, "padStart", 1, padStart);
    _ = try vm.defineNative(proto, "repeat", 1, repeat);
    _ = try vm.defineNative(proto, "replace", 2, replace);
    _ = try vm.defineNative(proto, "replaceAll", 2, replaceAll);
    _ = try vm.defineNative(proto, "search", 1, search);
    _ = try vm.defineNative(proto, "slice", 2, slice);
    _ = try vm.defineNative(proto, "split", 2, split);
    _ = try vm.defineNative(proto, "startsWith", 1, startsWith);
    _ = try vm.defineNative(proto, "substring", 2, substring);
    _ = try vm.defineNative(proto, "substr", 2, substr);
    _ = try vm.defineNative(proto, "toLocaleLowerCase", 0, toLowerCase);
    _ = try vm.defineNative(proto, "toLocaleUpperCase", 0, toUpperCase);
    _ = try vm.defineNative(proto, "toLowerCase", 0, toLowerCase);
    _ = try vm.defineNative(proto, "toString", 0, toStringFn);
    _ = try vm.defineNative(proto, "toUpperCase", 0, toUpperCase);
    _ = try vm.defineNative(proto, "toWellFormed", 0, toWellFormed);
    _ = try vm.defineNative(proto, "trim", 0, trim);
    _ = try vm.defineNative(proto, "trimEnd", 0, trimEnd);
    _ = try vm.defineNative(proto, "trimStart", 0, trimStart);
    _ = try vm.defineNative(proto, "valueOf", 0, toStringFn);
    _ = try vm.defineNativeSymbol(proto, vm.symbols.iterator, "[Symbol.iterator]", 0, iteratorFn);
    // Annex B: trimLeft/trimRight aliases and the HTML methods.
    try vm.defineValue(proto, "trimLeft", try vm.get(proto, .{ .atom = try vm.atom("trimStart") }, proto.asValue()), .hidden);
    try vm.defineValue(proto, "trimRight", try vm.get(proto, .{ .atom = try vm.atom("trimEnd") }, proto.asValue()), .hidden);
    inline for (.{ .{ "anchor", "a", "name" }, .{ "big", "big", "" }, .{ "blink", "blink", "" }, .{ "bold", "b", "" }, .{ "fixed", "tt", "" }, .{ "fontcolor", "font", "color" }, .{ "fontsize", "font", "size" }, .{ "italics", "i", "" }, .{ "link", "a", "href" }, .{ "small", "small", "" }, .{ "strike", "strike", "" }, .{ "sub", "sub", "" }, .{ "sup", "sup", "" } }) |h| {
        _ = try vm.defineNative(proto, h[0], if (h[2].len > 0) 1 else 0, htmlMethod(h[1], h[2]));
    }
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    var s: *String = undefined;
    if (args.len == 0) {
        s = vm.atoms.empty;
    } else {
        const v = args[0];
        if (new_target.isUndefined() and v.isSymbol()) return strValue(try symbolDescriptiveString(vm, v));
        s = try vm.toString(v);
    }
    if (new_target.isUndefined()) return strValue(s);
    const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.string_prototype);
    const o = try vm.objects.create(proto.asValue(), .string, @sizeOf(vmod.PrimitiveData));
    o.internal(vmod.PrimitiveData).value = strValue(s);
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.length }, Value.fromInt(@intCast(s.len)), .frozen);
    return o.asValue();
}

pub fn symbolDescriptiveString(vm: *Vm, v: Value) Error!*String {
    const sym = Vm.asSymbol(v);
    const open = try vm.strings.fromUtf8("Symbol(");
    const close = try vm.strings.fromUtf8(")");
    const d = sym.description orelse vm.atoms.empty;
    return vm.concatStrings(try vm.concatStrings(open, d), close);
}

fn fromCharCode(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    for (args) |a| try units.append(vm.meta, @truncate(try vm.toUint32(a)));
    return strValue(try vm.strings.fromUnits(units.items));
}

fn fromCodePoint(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    for (args) |a| {
        const d = try vm.toNumber(a);
        if (d != @trunc(d) or d < 0 or d > 0x10ffff or std.math.isNan(d)) return vm.throwRangeError("Invalid code point");
        const cp: u21 = @intFromFloat(d);
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

fn raw(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const cooked = try vm.toObject(arg(args, 0));
    const raws = try vm.toObject(try vm.get(cooked, .{ .atom = vm.atoms.raw }, cooked.asValue()));
    const len = try vm.lengthOfArrayLike(raws);
    if (len == 0) return strValue(vm.atoms.empty);
    var out = vm.atoms.empty;
    var i: u64 = 0;
    while (true) : (i += 1) {
        const seg = try vm.toString(try vm.get(raws, .{ .index = @intCast(i) }, raws.asValue()));
        out = try vm.concatStrings(out, seg);
        if (i + 1 == len) break;
        if (i + 1 < args.len) out = try vm.concatStrings(out, try vm.toString(args[i + 1]));
    }
    return strValue(out);
}

// --------------------------------------------------------- helpers

fn thisStr(vm: *Vm, this: Value) Error!*String {
    return vm.strings.flatten(try b.thisToString(vm, this));
}

/// A substring by code-unit range.
fn sub(vm: *Vm, s: *String, start: usize, end: usize) Error!*String {
    if (start >= end) return vm.atoms.empty;
    if (start == 0 and end == s.len) return s;
    const flat = try vm.strings.flatten(s);
    if (flat.latin1()) |bytes| return vm.strings.fromLatin1(bytes[start..end]);
    return vm.strings.fromUnits(flat.utf16().?[start..end]);
}

/// The index of `needle` in `hay` at or after `from`, or null.
fn indexOfUnits(hay: *String, needle: *String, from: usize) ?usize {
    if (needle.len == 0) return if (from <= hay.len) from else null;
    if (needle.len > hay.len) return null;
    var i = from;
    while (i + needle.len <= hay.len) : (i += 1) {
        var j: usize = 0;
        while (j < needle.len) : (j += 1) if (hay.unitAt(i + j) != needle.unitAt(j)) break;
        if (j == needle.len) return i;
    }
    return null;
}

fn isWhite(u: u16) bool {
    return switch (u) {
        ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0, 0xfeff, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
        else => false,
    };
}

fn isRegExp(vm: *Vm, v: Value) Error!bool {
    if (!v.isObject()) return false;
    const m = try vm.get(asObject(v), .{ .symbol = vm.symbols.match }, v);
    if (!m.isUndefined()) return vm.toBoolean(m);
    return asObject(v).class == .regexp;
}

// -------------------------------------------------------- prototype

fn toStringFn(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return strValue(try b.thisString(vm, this));
}

fn iteratorFn(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const s = try b.thisToString(vm, this);
    return iterator.createStringIterator(vm, s);
}

fn at(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const len: f64 = @floatFromInt(s.len);
    const rel = try vm.toIntegerOrInfinity(arg(args, 0));
    const k = if (rel >= 0) rel else len + rel;
    if (k < 0 or k >= len) return Value.undefined_;
    const i: usize = @intFromFloat(k);
    return strValue(try sub(vm, s, i, i + 1));
}

fn charAt(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const pos = try vm.toIntegerOrInfinity(arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.len))) return strValue(vm.atoms.empty);
    const i: usize = @intFromFloat(pos);
    return strValue(try sub(vm, s, i, i + 1));
}

fn charCodeAt(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const pos = try vm.toIntegerOrInfinity(arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.len))) return Value.fromF64(std.math.nan(f64));
    return Value.fromInt(s.unitAt(@intFromFloat(pos)));
}

fn codePointAt(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const pos = try vm.toIntegerOrInfinity(arg(args, 0));
    if (pos < 0 or pos >= @as(f64, @floatFromInt(s.len))) return Value.undefined_;
    const i: usize = @intFromFloat(pos);
    const first = s.unitAt(i);
    if (first >= 0xd800 and first <= 0xdbff and i + 1 < s.len) {
        const second = s.unitAt(i + 1);
        if (second >= 0xdc00 and second <= 0xdfff) return Value.fromInt(@intCast(0x10000 + ((@as(u32, first) - 0xd800) << 10) + (second - 0xdc00)));
    }
    return Value.fromInt(first);
}

fn concat(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var s = try b.thisToString(vm, this);
    for (args) |a| s = try vm.concatStrings(s, try vm.toString(a));
    return strValue(s);
}

fn endsWith(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    if (try isRegExp(vm, arg(args, 0))) return vm.throwTypeError("First argument to String.prototype.endsWith must not be a regular expression");
    const search_s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const len: f64 = @floatFromInt(s.len);
    const end: f64 = if (arg(args, 1).isUndefined()) len else @min(@max(try vm.toIntegerOrInfinity(arg(args, 1)), 0), len);
    const e: usize = @intFromFloat(end);
    if (search_s.len > e) return Value.false_;
    const start = e - search_s.len;
    var j: usize = 0;
    while (j < search_s.len) : (j += 1) if (s.unitAt(start + j) != search_s.unitAt(j)) return Value.false_;
    return Value.true_;
}

fn startsWith(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    if (try isRegExp(vm, arg(args, 0))) return vm.throwTypeError("First argument to String.prototype.startsWith must not be a regular expression");
    const search_s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const len: f64 = @floatFromInt(s.len);
    const start: usize = @intFromFloat(@min(@max(try vm.toIntegerOrInfinity(arg(args, 1)), 0), len));
    if (start + search_s.len > s.len) return Value.false_;
    var j: usize = 0;
    while (j < search_s.len) : (j += 1) if (s.unitAt(start + j) != search_s.unitAt(j)) return Value.false_;
    return Value.true_;
}

fn includes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    if (try isRegExp(vm, arg(args, 0))) return vm.throwTypeError("First argument to String.prototype.includes must not be a regular expression");
    const search_s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const len: f64 = @floatFromInt(s.len);
    const start: usize = @intFromFloat(@min(@max(try vm.toIntegerOrInfinity(arg(args, 1)), 0), len));
    return Value.fromBool(indexOfUnits(s, search_s, start) != null);
}

fn indexOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const search_s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const len: f64 = @floatFromInt(s.len);
    const start: usize = @intFromFloat(@min(@max(try vm.toIntegerOrInfinity(arg(args, 1)), 0), len));
    if (indexOfUnits(s, search_s, start)) |i| return Value.fromInt(@intCast(i));
    return Value.fromInt(-1);
}

fn lastIndexOf(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const search_s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const num = try vm.toNumber(arg(args, 1));
    const len: f64 = @floatFromInt(s.len);
    const pos: f64 = if (std.math.isNan(num)) std.math.inf(f64) else @trunc(num);
    const start: usize = @intFromFloat(@min(@max(pos, 0), len));
    if (search_s.len > s.len) return Value.fromInt(-1);
    var i: usize = @min(start, s.len - search_s.len);
    while (true) : (i -= 1) {
        var j: usize = 0;
        while (j < search_s.len) : (j += 1) if (s.unitAt(i + j) != search_s.unitAt(j)) break;
        if (j == search_s.len) return Value.fromInt(@intCast(i));
        if (i == 0) break;
    }
    return Value.fromInt(-1);
}

fn isWellFormed(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const u = s.unitAt(i);
        if (u >= 0xd800 and u <= 0xdbff) {
            if (i + 1 < s.len and s.unitAt(i + 1) >= 0xdc00 and s.unitAt(i + 1) <= 0xdfff) {
                i += 1;
                continue;
            }
            return Value.false_;
        }
        if (u >= 0xdc00 and u <= 0xdfff) return Value.false_;
    }
    return Value.true_;
}

fn toWellFormed(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const u = s.unitAt(i);
        if (u >= 0xd800 and u <= 0xdbff and i + 1 < s.len and s.unitAt(i + 1) >= 0xdc00 and s.unitAt(i + 1) <= 0xdfff) {
            try units.append(vm.meta, u);
            try units.append(vm.meta, s.unitAt(i + 1));
            i += 1;
        } else if (u >= 0xd800 and u <= 0xdfff) {
            try units.append(vm.meta, 0xfffd);
        } else try units.append(vm.meta, u);
    }
    return strValue(try vm.strings.fromUnits(units.items));
}

fn localeCompare(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const t = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    if (try vm.stringLessThan(s, t)) return Value.fromInt(-1);
    if (s.eql(t)) return Value.fromInt(0);
    return Value.fromInt(1);
}

fn normalize(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try b.thisToString(vm, this);
    const f = arg(args, 0);
    if (!f.isUndefined()) {
        const form = try vm.toString(f);
        var buf: [16]u8 = undefined;
        const fs = b.utf8Buf(vm, form, &buf) catch "";
        if (!std.mem.eql(u8, fs, "NFC") and !std.mem.eql(u8, fs, "NFD") and !std.mem.eql(u8, fs, "NFKC") and !std.mem.eql(u8, fs, "NFKD")) return vm.throwRangeError("The normalization form should be one of NFC, NFD, NFKC, NFKD.");
    }
    // Normalization tables are a stage e item; ASCII and precomposed
    // text is already in every form.
    return strValue(s);
}

fn pad(vm: *Vm, this: Value, args: []const Value, at_start: bool) Error!Value {
    const s = try thisStr(vm, this);
    const max_len = try vm.toLength(arg(args, 0));
    if (max_len <= s.len) return strValue(s);
    var filler = try vm.strings.fromUtf8(" ");
    if (!arg(args, 1).isUndefined()) filler = try vm.strings.flatten(try vm.toString(arg(args, 1)));
    if (filler.len == 0) return strValue(s);
    if (max_len > (1 << 30)) return vm.throwRangeError("Invalid string length");
    const fill_len: usize = @intCast(max_len - s.len);
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    var i: usize = 0;
    while (i < fill_len) : (i += 1) try units.append(vm.meta, filler.unitAt(i % filler.len));
    const f = try vm.strings.fromUnits(units.items);
    return strValue(if (at_start) try vm.concatStrings(f, s) else try vm.concatStrings(s, f));
}
fn padEnd(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return pad(vm, this, args, false);
}
fn padStart(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return pad(vm, this, args, true);
}

fn repeat(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const n = try vm.toIntegerOrInfinity(arg(args, 0));
    if (n < 0 or n == std.math.inf(f64)) return vm.throwRangeError("Invalid count value");
    const count: usize = @intFromFloat(n);
    if (count == 0 or s.len == 0) return strValue(vm.atoms.empty);
    if (@as(u64, count) * s.len > (1 << 30)) return vm.throwRangeError("Invalid string length");
    var out = vm.atoms.empty;
    var i: usize = 0;
    while (i < count) : (i += 1) out = try vm.concatStrings(out, s);
    return strValue(out);
}

/// GetSubstitution (§22.1.3.19.1) for string patterns.
fn substitution(vm: *Vm, matched: *String, str: *String, position: usize, replacement: *String, out: *std.ArrayList(u16)) Error!void {
    const rep = try vm.strings.flatten(replacement);
    var i: usize = 0;
    while (i < rep.len) : (i += 1) {
        const c = rep.unitAt(i);
        if (c != '$' or i + 1 >= rep.len) {
            try out.append(vm.meta, c);
            continue;
        }
        const n = rep.unitAt(i + 1);
        switch (n) {
            '$' => {
                try out.append(vm.meta, '$');
                i += 1;
            },
            '&' => {
                var k: usize = 0;
                while (k < matched.len) : (k += 1) try out.append(vm.meta, matched.unitAt(k));
                i += 1;
            },
            '`' => {
                var k: usize = 0;
                while (k < position) : (k += 1) try out.append(vm.meta, str.unitAt(k));
                i += 1;
            },
            '\'' => {
                var k: usize = position + matched.len;
                while (k < str.len) : (k += 1) try out.append(vm.meta, str.unitAt(k));
                i += 1;
            },
            else => try out.append(vm.meta, c),
        }
    }
}

fn replaceImpl(vm: *Vm, this: Value, args: []const Value, all: bool) Error!Value {
    if (this.isNullish()) return vm.throwTypeError("String.prototype.replace called on null or undefined");
    const search_v = arg(args, 0);
    const replace_v = arg(args, 1);
    if (!search_v.isNullish()) {
        if (all and try isRegExp(vm, search_v)) {
            const flags = try vm.toString(try vm.get(asObject(search_v), .{ .atom = vm.atoms.flags }, search_v));
            const ff = try vm.strings.flatten(flags);
            var has_g = false;
            var i: usize = 0;
            while (i < ff.len) : (i += 1) if (ff.unitAt(i) == 'g') {
                has_g = true;
            };
            if (!has_g) return vm.throwTypeError("replaceAll must be called with a global RegExp");
        }
        const replacer = try vm.getMethod(search_v, .{ .symbol = vm.symbols.replace });
        if (!replacer.isUndefined()) return vm.call(replacer, search_v, &.{ this, replace_v });
    }
    const s = try thisStr(vm, this);
    const search_s = try vm.strings.flatten(try vm.toString(search_v));
    const functional = vm.isCallable(replace_v);
    const replace_s = if (functional) null else try vm.toString(replace_v);
    // Match positions.
    var positions: std.ArrayList(usize) = .empty;
    defer positions.deinit(vm.meta);
    const advance = @max(search_s.len, 1);
    var pos = indexOfUnits(s, search_s, 0);
    while (pos) |p| {
        try positions.append(vm.meta, p);
        if (!all) break;
        pos = indexOfUnits(s, search_s, p + advance);
    }
    if (positions.items.len == 0) return strValue(s);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    var end_of_last: usize = 0;
    for (positions.items) |p| {
        var k = end_of_last;
        while (k < p) : (k += 1) try out.append(vm.meta, s.unitAt(k));
        if (functional) {
            const r = try vm.call(replace_v, Value.undefined_, &.{ strValue(search_s), Value.fromInt(@intCast(p)), strValue(s) });
            const rs = try vm.strings.flatten(try vm.toString(r));
            var j: usize = 0;
            while (j < rs.len) : (j += 1) try out.append(vm.meta, rs.unitAt(j));
        } else try substitution(vm, search_s, s, p, replace_s.?, &out);
        end_of_last = p + search_s.len;
    }
    var k = end_of_last;
    while (k < s.len) : (k += 1) try out.append(vm.meta, s.unitAt(k));
    return strValue(try vm.strings.fromUnits(out.items));
}
fn replace(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return replaceImpl(vm, this, args, false);
}
fn replaceAll(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return replaceImpl(vm, this, args, true);
}

fn delegate(vm: *Vm, this: Value, args: []const Value, sym: *b.Symbol, name: []const u8) Error!?Value {
    if (this.isNullish()) return vm.throwTypeErrorFmt("String.prototype.{s} called on null or undefined", .{name});
    const v = arg(args, 0);
    if (!v.isNullish()) {
        const m = try vm.getMethod(v, .{ .symbol = sym });
        if (!m.isUndefined()) return try vm.call(m, v, &.{this});
    }
    return null;
}

fn match(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (try delegate(vm, this, args, vm.symbols.match, "match")) |r| return r;
    const s = try b.thisToString(vm, this);
    const rx = try vm.construct(try vm.get(vm.global, .{ .atom = try vm.atom("RegExp") }, vm.global.asValue()), &.{arg(args, 0)}, Value.undefined_);
    return vm.invoke(rx, .{ .symbol = vm.symbols.match }, &.{strValue(s)});
}

fn matchAll(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (this.isNullish()) return vm.throwTypeError("String.prototype.matchAll called on null or undefined");
    const v = arg(args, 0);
    if (!v.isNullish()) {
        if (try isRegExp(vm, v)) {
            const flags = try vm.toString(try vm.get(asObject(v), .{ .atom = vm.atoms.flags }, v));
            const ff = try vm.strings.flatten(flags);
            var has_g = false;
            var i: usize = 0;
            while (i < ff.len) : (i += 1) if (ff.unitAt(i) == 'g') {
                has_g = true;
            };
            if (!has_g) return vm.throwTypeError("matchAll must be called with a global RegExp");
        }
        const m = try vm.getMethod(v, .{ .symbol = vm.symbols.match_all });
        if (!m.isUndefined()) return vm.call(m, v, &.{this});
    }
    const s = try b.thisToString(vm, this);
    const rx = try vm.construct(try vm.get(vm.global, .{ .atom = try vm.atom("RegExp") }, vm.global.asValue()), &.{ v, strValue(try vm.strings.fromUtf8("g")) }, Value.undefined_);
    return vm.invoke(rx, .{ .symbol = vm.symbols.match_all }, &.{strValue(s)});
}

fn search(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (try delegate(vm, this, args, vm.symbols.search, "search")) |r| return r;
    const s = try b.thisToString(vm, this);
    const rx = try vm.construct(try vm.get(vm.global, .{ .atom = try vm.atom("RegExp") }, vm.global.asValue()), &.{arg(args, 0)}, Value.undefined_);
    return vm.invoke(rx, .{ .symbol = vm.symbols.search }, &.{strValue(s)});
}

fn slice(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const len: f64 = @floatFromInt(s.len);
    const from = try b.relativeIndex(vm, arg(args, 0), len, 0);
    const to = try b.relativeIndex(vm, arg(args, 1), len, len);
    if (from >= to) return strValue(vm.atoms.empty);
    return strValue(try sub(vm, s, @intFromFloat(from), @intFromFloat(to)));
}

fn split(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (this.isNullish()) return vm.throwTypeError("String.prototype.split called on null or undefined");
    const sep_v = arg(args, 0);
    const limit_v = arg(args, 1);
    if (!sep_v.isNullish()) {
        const m = try vm.getMethod(sep_v, .{ .symbol = vm.symbols.split });
        if (!m.isUndefined()) return vm.call(m, sep_v, &.{ this, limit_v });
    }
    const s = try thisStr(vm, this);
    const lim: u32 = if (limit_v.isUndefined()) std.math.maxInt(u32) else try vm.toUint32(limit_v);
    const sep = try vm.strings.flatten(try vm.toString(sep_v));
    const a = try vm.newArray(0);
    if (lim == 0) return a.asValue();
    if (sep_v.isUndefined()) {
        try vm.arrayPush(a, strValue(s));
        return a.asValue();
    }
    if (s.len == 0) {
        if (sep.len > 0) try vm.arrayPush(a, strValue(s));
        return a.asValue();
    }
    if (sep.len == 0) {
        var i: usize = 0;
        while (i < s.len and i < lim) : (i += 1) try vm.arrayPush(a, strValue(try sub(vm, s, i, i + 1)));
        return a.asValue();
    }
    var p: usize = 0;
    var count: u32 = 0;
    while (indexOfUnits(s, sep, p)) |q| {
        try vm.arrayPush(a, strValue(try sub(vm, s, p, q)));
        count += 1;
        if (count >= lim) return a.asValue();
        p = q + sep.len;
    }
    try vm.arrayPush(a, strValue(try sub(vm, s, p, s.len)));
    return a.asValue();
}

fn substring(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const len: f64 = @floatFromInt(s.len);
    const a = @min(@max(try vm.toIntegerOrInfinity(arg(args, 0)), 0), len);
    const e = if (arg(args, 1).isUndefined()) len else @min(@max(try vm.toIntegerOrInfinity(arg(args, 1)), 0), len);
    const from: usize = @intFromFloat(@min(a, e));
    const to: usize = @intFromFloat(@max(a, e));
    return strValue(try sub(vm, s, from, to));
}

fn substr(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const s = try thisStr(vm, this);
    const len: f64 = @floatFromInt(s.len);
    var start = try vm.toIntegerOrInfinity(arg(args, 0));
    if (start == -std.math.inf(f64)) start = 0 else if (start < 0) start = @max(len + start, 0) else start = @min(start, len);
    const l = if (arg(args, 1).isUndefined()) len else try vm.toIntegerOrInfinity(arg(args, 1));
    const end = @min(start + @max(l, 0), len);
    if (start >= end) return strValue(vm.atoms.empty);
    return strValue(try sub(vm, s, @intFromFloat(start), @intFromFloat(end)));
}

fn caseMap(vm: *Vm, this: Value, upper: bool) Error!Value {
    const s = try thisStr(vm, this);
    if (s.latin1()) |bytes| {
        var ascii = true;
        for (bytes) |c| if (c >= 0x80) {
            ascii = false;
            break;
        };
        if (ascii) {
            const out = try vm.meta.alloc(u8, bytes.len);
            defer vm.meta.free(out);
            for (bytes, 0..) |c, i| out[i] = if (upper) std.ascii.toUpper(c) else std.ascii.toLower(c);
            return strValue(try vm.strings.fromLatin1(out));
        }
    }
    // The full mapping (with expansions like ß → SS) through code points.
    var units: std.ArrayList(u16) = .empty;
    defer units.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        var cp: u21 = s.unitAt(i);
        if (cp >= 0xd800 and cp <= 0xdbff and i + 1 < s.len) {
            const lo = s.unitAt(i + 1);
            if (lo >= 0xdc00 and lo <= 0xdfff) {
                cp = 0x10000 + ((cp - 0xd800) << 10) + (lo - 0xdc00);
                i += 1;
            }
        }
        if (upper and cp == 0xdf) {
            try units.appendSlice(vm.meta, &.{ 'S', 'S' });
            continue;
        }
        const mapped: u21 = if (upper) unicodeUpper(cp) else unicodeLower(cp);
        if (mapped < 0x10000) {
            try units.append(vm.meta, @intCast(mapped));
        } else {
            const c = mapped - 0x10000;
            try units.append(vm.meta, @intCast(0xd800 + (c >> 10)));
            try units.append(vm.meta, @intCast(0xdc00 + (c & 0x3ff)));
        }
    }
    return strValue(try vm.strings.fromUnits(units.items));
}

/// Simple case mappings for the common scripts (Latin, Greek, Cyrillic,
/// Armenian, and the Latin Extended blocks by parity).
fn unicodeUpper(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toUpper(@intCast(cp));
    if (cp >= 0xe0 and cp <= 0xfe and cp != 0xf7) return cp - 0x20;
    if (cp == 0xff) return 0x178;
    if (cp == 0xb5) return 0x39c;
    if (cp >= 0x100 and cp <= 0x17f) {
        if ((cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17e)) return if (cp % 2 == 0) cp - 1 else cp;
        if (cp == 0x131) return 'I';
        if (cp == 0x17f) return 'S';
        return if (cp % 2 == 1) cp - 1 else cp;
    }
    if (cp >= 0x3b1 and cp <= 0x3c9 and cp != 0x3c2) return cp - 0x20;
    if (cp == 0x3c2) return 0x3a3;
    if (cp >= 0x430 and cp <= 0x44f) return cp - 0x20;
    if (cp >= 0x450 and cp <= 0x45f) return cp - 0x50;
    if (cp >= 0x561 and cp <= 0x586) return cp - 0x30;
    if (cp >= 0x1e00 and cp <= 0x1eff) return if (cp % 2 == 1) cp - 1 else cp;
    if (cp >= 0xff41 and cp <= 0xff5a) return cp - 0x20;
    if (cp >= 0x10428 and cp <= 0x1044f) return cp - 0x28;
    return cp;
}

fn unicodeLower(cp: u21) u21 {
    if (cp < 0x80) return std.ascii.toLower(@intCast(cp));
    if (cp >= 0xc0 and cp <= 0xde and cp != 0xd7) return cp + 0x20;
    if (cp == 0x178) return 0xff;
    if (cp >= 0x100 and cp <= 0x17f) {
        if ((cp >= 0x139 and cp <= 0x148) or (cp >= 0x179 and cp <= 0x17e)) return if (cp % 2 == 1) cp + 1 else cp;
        if (cp == 0x130) return 'i';
        return if (cp % 2 == 0) cp + 1 else cp;
    }
    if (cp >= 0x391 and cp <= 0x3a9 and cp != 0x3a2) return cp + 0x20;
    if (cp >= 0x410 and cp <= 0x42f) return cp + 0x20;
    if (cp >= 0x400 and cp <= 0x40f) return cp + 0x50;
    if (cp >= 0x531 and cp <= 0x556) return cp + 0x30;
    if (cp >= 0x1e00 and cp <= 0x1eff) return if (cp % 2 == 0) cp + 1 else cp;
    if (cp >= 0xff21 and cp <= 0xff3a) return cp + 0x20;
    if (cp >= 0x10400 and cp <= 0x10427) return cp + 0x28;
    return cp;
}

fn toLowerCase(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return caseMap(vm, this, false);
}
fn toUpperCase(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return caseMap(vm, this, true);
}

fn trimImpl(vm: *Vm, this: Value, start: bool, end: bool) Error!Value {
    const s = try thisStr(vm, this);
    var from: usize = 0;
    var to: usize = s.len;
    if (start) while (from < to and isWhite(s.unitAt(from))) : (from += 1) {};
    if (end) while (to > from and isWhite(s.unitAt(to - 1))) : (to -= 1) {};
    return strValue(try sub(vm, s, from, to));
}
fn trim(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return trimImpl(vm, this, true, true);
}
fn trimStart(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return trimImpl(vm, this, true, false);
}
fn trimEnd(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return trimImpl(vm, this, false, true);
}

fn htmlMethod(comptime tag: []const u8, comptime attr: []const u8) vmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
            const s = try b.thisToString(vm, this);
            var out = try vm.strings.fromUtf8("<" ++ tag);
            if (attr.len > 0) {
                out = try vm.concatStrings(out, try vm.strings.fromUtf8(" " ++ attr ++ "=\""));
                const v = try vm.strings.flatten(try vm.toString(arg(args, 0)));
                // Escape quotes.
                var units: std.ArrayList(u16) = .empty;
                defer units.deinit(vm.meta);
                var i: usize = 0;
                while (i < v.len) : (i += 1) {
                    const u = v.unitAt(i);
                    if (u == '"') {
                        try units.appendSlice(vm.meta, &.{ '&', 'q', 'u', 'o', 't', ';' });
                    } else try units.append(vm.meta, u);
                }
                out = try vm.concatStrings(out, try vm.strings.fromUnits(units.items));
                out = try vm.concatStrings(out, try vm.strings.fromUtf8("\""));
            }
            out = try vm.concatStrings(out, try vm.strings.fromUtf8(">"));
            out = try vm.concatStrings(out, s);
            out = try vm.concatStrings(out, try vm.strings.fromUtf8("</" ++ tag ++ ">"));
            return strValue(out);
        }
    }.f;
}
