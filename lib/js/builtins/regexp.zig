//! RegExp (§22.2.4–22.2.9): the object over `lib/js/regexp.zig`'s
//! compiled programs — construction and `compile`, `exec` with
//! lastIndex/global/sticky/unicode semantics and match indices, the
//! flag and `source` accessors, and the Symbol methods String delegates
//! to (`match`, `matchAll`, `replace`, `search`, `split`), each written
//! generically over `exec` as the specification has them.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const re = @import("../regexp.zig");
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

/// The internal slots: the compiled program (embedder memory, freed
/// with the object) and the original source and flags strings.
pub const RegExpData = extern struct {
    prog: ?*re.Program,
    source: Value,
    flags: Value,
    /// A `lastIndex` that stayed a plain writable data property is read
    /// from its slot directly.
    _pad: u64 = 0,
};

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.regexp_prototype;
    const ctor = try b.installConstructor(vm, "RegExp", 2, construct, proto);
    vm.intrinsics.regexp_ctor = ctor;
    const species = try vm.newNative("get [Symbol.species]", 0, speciesGetter, Value.undefined_);
    try vm.defineAccessor(ctor, .{ .symbol = vm.symbols.species }, species, null, .{ .enumerable = false, .configurable = true });
    _ = try vm.defineNative(ctor, "escape", 1, escape);
    _ = try vm.defineNative(proto, "exec", 1, exec);
    _ = try vm.defineNative(proto, "test", 1, testFn);
    _ = try vm.defineNative(proto, "toString", 0, toString);
    _ = try vm.defineNative(proto, "compile", 2, compileFn);
    try vm.defineGetter(proto, "flags", flagsGetter);
    try vm.defineGetter(proto, "source", sourceGetter);
    inline for (.{ .{ "global", "g" }, .{ "ignoreCase", "i" }, .{ "multiline", "m" }, .{ "dotAll", "s" }, .{ "unicode", "u" }, .{ "unicodeSets", "v" }, .{ "sticky", "y" }, .{ "hasIndices", "d" } }) |f| {
        try vm.defineGetter(proto, f[0], flagGetter(f[1][0]));
    }
    _ = try vm.defineNativeSymbol(proto, vm.symbols.match, "[Symbol.match]", 1, symbolMatch);
    _ = try vm.defineNativeSymbol(proto, vm.symbols.match_all, "[Symbol.matchAll]", 1, symbolMatchAll);
    _ = try vm.defineNativeSymbol(proto, vm.symbols.replace, "[Symbol.replace]", 2, symbolReplace);
    _ = try vm.defineNativeSymbol(proto, vm.symbols.search, "[Symbol.search]", 1, symbolSearch);
    _ = try vm.defineNativeSymbol(proto, vm.symbols.split, "[Symbol.split]", 2, symbolSplit);
    // %RegExpStringIteratorPrototype%
    const rsip = try vm.objects.create(vm.intrinsics.iterator_prototype.asValue(), .ordinary, 0);
    vm.intrinsics.regexp_string_iterator_prototype = rsip;
    _ = try vm.defineNative(rsip, "next", 0, stringIteratorNext);
    try b.setToStringTag(vm, rsip, "RegExp String Iterator");
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    const d = o.internal(RegExpData);
    m.markValue(d.source);
    m.markValue(d.flags);
}

pub fn finalize(vm: *Vm, o: *Object) void {
    _ = vm;
    const d = o.internal(RegExpData);
    if (d.prog) |p| {
        p.deinit();
        d.prog = null;
    }
}

fn isRegExpObject(v: Value) bool {
    return v.isObject() and asObject(v).class == .regexp and asObject(v).internal(RegExpData).prog != null;
}

fn data(v: Value) *RegExpData {
    return asObject(v).internal(RegExpData);
}

/// The flattened UTF-16 units of a string (Latin-1 widened into `buf`).
fn units(vm: *Vm, s: *String, list: *std.ArrayList(u16)) Error![]const u16 {
    const f = try vm.strings.flatten(s);
    if (f.utf16()) |u| return u;
    const bytes = f.latin1().?;
    try list.ensureTotalCapacity(vm.meta, bytes.len);
    list.clearRetainingCapacity();
    for (bytes) |c| list.appendAssumeCapacity(c);
    return list.items;
}

/// RegExpAlloc + RegExpInitialize (§22.2.3.1–3): compile `pattern`
/// with `flags` into `o`.
fn initialize(vm: *Vm, o: *Object, pattern: Value, flags: Value) Error!Value {
    const p_s = if (pattern.isUndefined()) vm.atoms.empty else try vm.toString(pattern);
    const f_s = if (flags.isUndefined()) vm.atoms.empty else try vm.toString(flags);
    var fbuf: std.ArrayList(u16) = .empty;
    defer fbuf.deinit(vm.meta);
    const f_units = try units(vm, f_s, &fbuf);
    const fl = re.Flags.parse(f_units) orelse return vm.throwSyntaxError("Invalid regular expression flags");
    var pbuf: std.ArrayList(u16) = .empty;
    defer pbuf.deinit(vm.meta);
    const p_units = try units(vm, p_s, &pbuf);
    var err: []const u8 = "";
    const prog = re.compile(vm.meta, p_units, fl, &err) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => {
            var buf: [300]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Invalid regular expression: {s}", .{err}) catch "Invalid regular expression";
            return vm.throwSyntaxError(msg);
        },
    };
    const d = o.internal(RegExpData);
    if (d.prog) |old| old.deinit();
    d.prog = prog;
    d.source = strValue(p_s);
    d.flags = strValue(f_s);
    // lastIndex = 0 (Set with throw).
    try vm.setV(o.asValue(), .{ .atom = vm.atoms.lastIndex }, Value.fromInt(0), true);
    return o.asValue();
}

fn alloc(vm: *Vm, new_target: Value) Error!*Object {
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.regexp_prototype, .regexp, @sizeOf(RegExpData));
    o.internal(RegExpData).* = .{ .prog = null, .source = Value.undefined_, .flags = Value.undefined_ };
    _ = try vm.objects.defineOwn(o, .{ .atom = vm.atoms.lastIndex }, Value.fromInt(0), .{ .writable = true, .enumerable = false, .configurable = false });
    return o;
}

/// A literal (`regexp` instruction).
pub fn create(vm: *Vm, pattern: Value, flags: Value) Error!Value {
    const o = try alloc(vm, vm.intrinsics.regexp_ctor.asValue());
    return initialize(vm, o, pattern, flags);
}

/// IsRegExp (§7.2.8).
fn isRegExp(vm: *Vm, v: Value) Error!bool {
    if (!v.isObject()) return false;
    const m = try vm.get(asObject(v), .{ .symbol = vm.symbols.match }, v);
    if (!m.isUndefined()) return vm.toBoolean(m);
    return isRegExpObject(v);
}

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    var pattern = arg(args, 0);
    var flags = arg(args, 1);
    const pattern_is_regexp = try isRegExp(vm, pattern);
    var nt = new_target;
    if (nt.isUndefined()) {
        nt = vm.intrinsics.regexp_ctor.asValue();
        if (pattern_is_regexp and flags.isUndefined()) {
            const pc = try vm.get(asObject(pattern), .{ .atom = vm.atoms.constructor }, pattern);
            if (pc.eqlBits(nt)) return pattern;
        }
    }
    if (isRegExpObject(pattern)) {
        const d = data(pattern);
        const src = d.source;
        if (flags.isUndefined()) flags = d.flags;
        pattern = src;
    } else if (pattern_is_regexp) {
        const src = try vm.get(asObject(pattern), .{ .atom = vm.atoms.source }, pattern);
        if (flags.isUndefined()) flags = try vm.get(asObject(pattern), .{ .atom = vm.atoms.flags }, pattern);
        pattern = src;
    }
    const o = try alloc(vm, nt);
    return initialize(vm, o, pattern, flags);
}

/// RegExp.escape (ES2025): a string safe to embed in a pattern.
fn escape(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    if (!v.isString()) return vm.throwTypeError("RegExp.escape requires a string");
    const s = try vm.strings.flatten(asString(v));
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const c = s.unitAt(i);
        const hex4 = (i == 0 and ((c >= '0' and c <= '9') or (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z')));
        const syntax = switch (c) {
            '^', '$', '\\', '.', '*', '+', '?', '(', ')', '[', ']', '{', '}', '|', '/' => true,
            else => false,
        };
        const punct = switch (c) {
            ',', '-', '=', '<', '>', '#', '&', '!', '%', ':', ';', '@', '~', '\'', '`', '"' => true,
            else => false,
        };
        const white = switch (c) {
            ' ', '\t', '\n', '\r', 0x0b, 0x0c, 0xa0, 0xfeff, 0x1680, 0x2000...0x200a, 0x2028, 0x2029, 0x202f, 0x205f, 0x3000 => true,
            else => false,
        };
        const lone_surrogate = (c >= 0xd800 and c <= 0xdfff) and !((c <= 0xdbff and i + 1 < s.len and s.unitAt(i + 1) >= 0xdc00 and s.unitAt(i + 1) <= 0xdfff) or (c >= 0xdc00 and i > 0 and s.unitAt(i - 1) >= 0xd800 and s.unitAt(i - 1) <= 0xdbff));
        const control: ?u8 = switch (c) {
            '\t' => 't',
            '\n' => 'n',
            0x0b => 'v',
            0x0c => 'f',
            '\r' => 'r',
            else => null,
        };
        if (control) |ch| {
            try out.append(vm.meta, '\\');
            try out.append(vm.meta, ch);
        } else if (hex4 or punct or white or lone_surrogate) {
            var buf: [8]u8 = undefined;
            const h = if (c < 0x100) std.fmt.bufPrint(&buf, "\\x{x:0>2}", .{c}) catch unreachable else std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
            for (h) |ch| try out.append(vm.meta, ch);
        } else if (syntax) {
            try out.append(vm.meta, '\\');
            try out.append(vm.meta, c);
        } else try out.append(vm.meta, c);
    }
    return strValue(try vm.strings.fromUnits(out.items));
}

fn thisRegExp(vm: *Vm, this: Value, what: []const u8) Error!*Object {
    if (!isRegExpObject(this)) return vm.throwTypeErrorFmt("RegExp.prototype.{s} requires that 'this' be a RegExp object", .{what});
    return asObject(this);
}

fn compileFn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisRegExp(vm, this, "compile");
    var pattern = arg(args, 0);
    var flags = arg(args, 1);
    if (isRegExpObject(pattern)) {
        if (!flags.isUndefined()) return vm.throwTypeError("flags must be undefined when the pattern is a RegExp");
        const d = data(pattern);
        flags = d.flags;
        pattern = d.source;
    }
    return initialize(vm, o, pattern, flags);
}

// ---------------------------------------------------------- accessors

fn flagGetter(comptime flag: u8) vmod.NativeFn {
    return struct {
        fn f(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
            if (!this.isObject()) return vm.throwTypeError("RegExp flag getter called on non-object");
            if (!isRegExpObject(this)) {
                if (asObject(this) == vm.intrinsics.regexp_prototype) return Value.undefined_;
                return vm.throwTypeError("RegExp flag getter called on incompatible receiver");
            }
            const fl = data(this).prog.?.flags;
            return Value.fromBool(switch (flag) {
                'g' => fl.global,
                'i' => fl.ignore_case,
                'm' => fl.multiline,
                's' => fl.dot_all,
                'u' => fl.unicode,
                'v' => fl.unicode_sets,
                'y' => fl.sticky,
                'd' => fl.has_indices,
                else => unreachable,
            });
        }
    }.f;
}

/// get RegExp.prototype.flags (§22.2.6.4): built from the individual
/// getters, in the order d g i m s u v y.
fn flagsGetter(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype.flags getter called on non-object");
    const o = asObject(this);
    var out: [8]u8 = undefined;
    var n: usize = 0;
    inline for (.{ .{ "hasIndices", 'd' }, .{ "global", 'g' }, .{ "ignoreCase", 'i' }, .{ "multiline", 'm' }, .{ "dotAll", 's' }, .{ "unicode", 'u' }, .{ "unicodeSets", 'v' }, .{ "sticky", 'y' } }) |f| {
        const v = try vm.get(o, .{ .atom = try vm.atom(f[0]) }, this);
        if (vm.toBoolean(v)) {
            out[n] = f[1];
            n += 1;
        }
    }
    return vm.str(out[0..n]);
}

/// get RegExp.prototype.source: EscapeRegExpPattern.
fn sourceGetter(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype.source getter called on non-object");
    if (!isRegExpObject(this)) {
        if (asObject(this) == vm.intrinsics.regexp_prototype) return vm.str("(?:)");
        return vm.throwTypeError("RegExp.prototype.source getter called on incompatible receiver");
    }
    const src = asString(data(this).source);
    if (src.len == 0) return vm.str("(?:)");
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.meta);
    const u = try units(vm, src, &buf);
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    var in_class = false;
    var i: usize = 0;
    while (i < u.len) : (i += 1) {
        const c = u[i];
        if (c == '\\' and i + 1 < u.len) {
            try out.append(vm.meta, c);
            try out.append(vm.meta, u[i + 1]);
            i += 1;
            continue;
        }
        if (c == '[') in_class = true;
        if (c == ']') in_class = false;
        switch (c) {
            '/' => if (in_class) try out.append(vm.meta, c) else try out.appendSlice(vm.meta, &.{ '\\', '/' }),
            '\n' => try out.appendSlice(vm.meta, &.{ '\\', 'n' }),
            '\r' => try out.appendSlice(vm.meta, &.{ '\\', 'r' }),
            0x2028 => try out.appendSlice(vm.meta, &.{ '\\', 'u', '2', '0', '2', '8' }),
            0x2029 => try out.appendSlice(vm.meta, &.{ '\\', 'u', '2', '0', '2', '9' }),
            else => try out.append(vm.meta, c),
        }
    }
    return strValue(try vm.strings.fromUnits(out.items));
}

fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype.toString requires an object");
    const o = asObject(this);
    const src = try vm.toString(try vm.get(o, .{ .atom = vm.atoms.source }, this));
    const flags = try vm.toString(try vm.get(o, .{ .atom = vm.atoms.flags }, this));
    const slash = try vm.strings.fromUtf8("/");
    return strValue(try vm.concatStrings(try vm.concatStrings(try vm.concatStrings(slash, src), slash), flags));
}

// --------------------------------------------------------------- exec

fn getLastIndex(vm: *Vm, o: *Object) Error!u64 {
    return vm.toLength(try vm.get(o, .{ .atom = vm.atoms.lastIndex }, o.asValue()));
}

fn setLastIndex(vm: *Vm, o: *Object, v: u64) Error!void {
    try vm.setV(o.asValue(), .{ .atom = vm.atoms.lastIndex }, Value.fromF64(@floatFromInt(v)), true);
}

/// RegExpBuiltinExec (§22.2.7.2).
pub fn builtinExec(vm: *Vm, o: *Object, s: *String) Error!Value {
    const d = o.internal(RegExpData);
    const prog = d.prog.?;
    var last_index = try getLastIndex(vm, o);
    const fl = prog.flags;
    const global_or_sticky = fl.global or fl.sticky;
    if (!global_or_sticky) last_index = 0;
    var buf: std.ArrayList(u16) = .empty;
    defer buf.deinit(vm.meta);
    const text = try units(vm, s, &buf);
    if (last_index > text.len) {
        if (global_or_sticky) try setLastIndex(vm, o, 0);
        return Value.null_;
    }
    var m = re.Matcher.init(vm.meta, prog, text, 400_000_000) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.Budget => unreachable,
    };
    defer m.deinit();
    var start: u32 = @intCast(last_index);
    var matched = false;
    while (start <= text.len) {
        const r = m.matchAt(start) catch |e| switch (e) {
            error.OutOfMemory => return error.OutOfMemory,
            error.Budget => return vm.throwRangeError("regular expression exceeded its step budget"),
        };
        if (r) {
            matched = true;
            break;
        }
        if (fl.sticky) break;
        // AdvanceStringIndex.
        start += 1;
        if (fl.unicodeMode() and start < text.len and text[start - 1] >= 0xd800 and text[start - 1] <= 0xdbff and text[start] >= 0xdc00 and text[start] <= 0xdfff) start += 1;
    }
    vm.steps += m.steps / 16;
    if (!matched) {
        if (global_or_sticky) try setLastIndex(vm, o, 0);
        return Value.null_;
    }
    const e = m.caps[1];
    if (global_or_sticky) try setLastIndex(vm, o, e);
    // The result array.
    const n = prog.ncaps;
    const a = try vm.newArray(0);
    _ = try vm.createDataProperty(a, .{ .atom = vm.atoms.index }, Value.fromInt(@intCast(m.caps[0])));
    _ = try vm.createDataProperty(a, .{ .atom = vm.atoms.input }, strValue(s));
    var i: u32 = 0;
    while (i < n) : (i += 1) {
        const cs = m.caps[i * 2];
        const ce = m.caps[i * 2 + 1];
        const v = if (cs == re.none or ce == re.none) Value.undefined_ else strValue(try vm.strings.fromUnits(text[cs..ce]));
        try vm.arrayPush(a, v);
    }
    var groups: Value = Value.undefined_;
    if (prog.names.len > 0) {
        const g = try vm.objects.create(Value.null_, .ordinary, 0);
        for (prog.names) |gn| {
            const gv = a.elements.?.items()[gn.index];
            const key: Key = .{ .atom = try vm.strings.intern(try vm.strings.fromUnits(gn.name)) };
            // A name several groups share: the one that participated
            // (the property keeps its first position).
            if (gv.isUndefined() and (try vm.objects.getOwn(g, key)) != null) continue;
            _ = try vm.createDataProperty(g, key, gv);
        }
        groups = g.asValue();
    }
    _ = try vm.createDataProperty(a, .{ .atom = vm.atoms.groups }, groups);
    if (fl.has_indices) {
        const indices = try vm.newArray(0);
        i = 0;
        while (i < n) : (i += 1) {
            const cs = m.caps[i * 2];
            const ce = m.caps[i * 2 + 1];
            if (cs == re.none or ce == re.none) {
                try vm.arrayPush(indices, Value.undefined_);
            } else {
                const pair = try vm.arrayFromList(&.{ Value.fromInt(@intCast(cs)), Value.fromInt(@intCast(ce)) });
                try vm.arrayPush(indices, pair.asValue());
            }
        }
        var igroups: Value = Value.undefined_;
        if (prog.names.len > 0) {
            const g = try vm.objects.create(Value.null_, .ordinary, 0);
            for (prog.names) |gn| {
                const iv = indices.elements.?.items()[gn.index];
                const key: Key = .{ .atom = try vm.strings.intern(try vm.strings.fromUnits(gn.name)) };
                if (iv.isUndefined() and (try vm.objects.getOwn(g, key)) != null) continue;
                _ = try vm.createDataProperty(g, key, iv);
            }
            igroups = g.asValue();
        }
        _ = try vm.createDataProperty(indices, .{ .atom = vm.atoms.groups }, igroups);
        _ = try vm.createDataProperty(a, .{ .atom = try vm.atom("indices") }, indices.asValue());
    }
    return a.asValue();
}

/// RegExpExec (§22.2.7.1): a user `exec`, or the built-in.
pub fn regExpExec(vm: *Vm, r: *Object, s: *String) Error!Value {
    const exec_v = try vm.get(r, .{ .atom = vm.atoms.exec }, r.asValue());
    if (vm.isCallable(exec_v)) {
        const result = try vm.call(exec_v, r.asValue(), &.{strValue(s)});
        if (!result.isObject() and !result.isNull()) return vm.throwTypeError("exec result must be an object or null");
        return result;
    }
    if (!isRegExpObject(r.asValue())) return vm.throwTypeError("RegExp exec method called on incompatible receiver");
    return builtinExec(vm, r, s);
}

fn exec(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const o = try thisRegExp(vm, this, "exec");
    const s = try vm.toString(arg(args, 0));
    return builtinExec(vm, o, s);
}

fn testFn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype.test called on non-object");
    const s = try vm.toString(arg(args, 0));
    const r = try regExpExec(vm, asObject(this), s);
    return Value.fromBool(!r.isNull());
}

// ------------------------------------------------------ symbol methods

fn flagsOf(vm: *Vm, o: *Object) Error!*String {
    return vm.toString(try vm.get(o, .{ .atom = vm.atoms.flags }, o.asValue()));
}

fn hasFlag(vm: *Vm, flags: *String, c: u16) Error!bool {
    const f = try vm.strings.flatten(flags);
    var i: usize = 0;
    while (i < f.len) : (i += 1) if (f.unitAt(i) == c) return true;
    return false;
}

fn advanceIndex(s: *String, index: u64, unicode: bool) u64 {
    if (!unicode) return index + 1;
    if (index + 1 >= s.len) return index + 1;
    const c = s.unitAt(index);
    if (c >= 0xd800 and c <= 0xdbff) {
        const lo = s.unitAt(index + 1);
        if (lo >= 0xdc00 and lo <= 0xdfff) return index + 2;
    }
    return index + 1;
}

fn symbolMatch(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype[Symbol.match] called on non-object");
    const rx = asObject(this);
    const s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const flags = try flagsOf(vm, rx);
    if (!try hasFlag(vm, flags, 'g')) return regExpExec(vm, rx, s);
    const full_unicode = (try hasFlag(vm, flags, 'u')) or (try hasFlag(vm, flags, 'v'));
    try setLastIndex(vm, rx, 0);
    const a = try vm.newArray(0);
    var n: u32 = 0;
    while (true) {
        const result = try regExpExec(vm, rx, s);
        if (result.isNull()) return if (n == 0) Value.null_ else a.asValue();
        const match_str = try vm.toString(try vm.get(asObject(result), .{ .index = 0 }, result));
        try vm.arrayPush(a, strValue(match_str));
        if (match_str.len == 0) {
            const li = try getLastIndex(vm, rx);
            try setLastIndex(vm, rx, advanceIndex(s, li, full_unicode));
        }
        n += 1;
    }
}

fn symbolSearch(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype[Symbol.search] called on non-object");
    const rx = asObject(this);
    const s = try vm.toString(arg(args, 0));
    const previous = try vm.get(rx, .{ .atom = vm.atoms.lastIndex }, this);
    if (!vm.sameValue(previous, Value.fromInt(0))) try vm.setV(this, .{ .atom = vm.atoms.lastIndex }, Value.fromInt(0), true);
    const result = try regExpExec(vm, rx, s);
    const current = try vm.get(rx, .{ .atom = vm.atoms.lastIndex }, this);
    if (!vm.sameValue(current, previous)) try vm.setV(this, .{ .atom = vm.atoms.lastIndex }, previous, true);
    if (result.isNull()) return Value.fromInt(-1);
    return vm.get(asObject(result), .{ .atom = vm.atoms.index }, result);
}

/// GetSubstitution (§22.1.3.19.1) with captures and named groups.
pub fn getSubstitution(vm: *Vm, matched: *String, str: *String, position: usize, captures: []const Value, named: Value, replacement: *String, out: *std.ArrayList(u16)) Error!void {
    const rep = try vm.strings.flatten(replacement);
    const m = captures.len;
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
                try appendString(vm, out, matched);
                i += 1;
            },
            '`' => {
                var k: usize = 0;
                while (k < position) : (k += 1) try out.append(vm.meta, str.unitAt(k));
                i += 1;
            },
            '\'' => {
                var k: usize = @min(position + matched.len, str.len);
                while (k < str.len) : (k += 1) try out.append(vm.meta, str.unitAt(k));
                i += 1;
            },
            '0'...'9' => {
                // $n or $nn, the longest valid two-digit form first.
                var digits: usize = 1;
                var idx: usize = n - '0';
                if (i + 2 < rep.len) {
                    const n2 = rep.unitAt(i + 2);
                    if (n2 >= '0' and n2 <= '9') {
                        const two = idx * 10 + (n2 - '0');
                        if (two >= 1 and two <= m) {
                            idx = two;
                            digits = 2;
                        }
                    }
                }
                if (idx >= 1 and idx <= m) {
                    const cap = captures[idx - 1];
                    if (!cap.isUndefined()) try appendString(vm, out, try vm.toString(cap));
                    i += digits;
                } else {
                    try out.append(vm.meta, '$');
                }
            },
            '<' => {
                if (named.isUndefined()) {
                    try out.append(vm.meta, '$');
                    continue;
                }
                // $<name>
                var j = i + 2;
                while (j < rep.len and rep.unitAt(j) != '>') j += 1;
                if (j >= rep.len) {
                    try out.append(vm.meta, '$');
                    continue;
                }
                var name: std.ArrayList(u16) = .empty;
                defer name.deinit(vm.meta);
                var k = i + 2;
                while (k < j) : (k += 1) try name.append(vm.meta, rep.unitAt(k));
                const key = try vm.keyFromString(try vm.strings.fromUnits(name.items));
                const cap = try vm.get(asObject(named), key, named);
                if (!cap.isUndefined()) try appendString(vm, out, try vm.toString(cap));
                i = j;
            },
            else => try out.append(vm.meta, '$'),
        }
    }
}

fn appendString(vm: *Vm, out: *std.ArrayList(u16), s: *String) Error!void {
    const f = try vm.strings.flatten(s);
    var k: usize = 0;
    while (k < f.len) : (k += 1) try out.append(vm.meta, f.unitAt(k));
}

fn symbolReplace(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype[Symbol.replace] called on non-object");
    const rx = asObject(this);
    const s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    var replace_v = arg(args, 1);
    const functional = vm.isCallable(replace_v);
    if (!functional) replace_v = strValue(try vm.toString(replace_v));
    const flags = try flagsOf(vm, rx);
    const global = try hasFlag(vm, flags, 'g');
    var full_unicode = false;
    if (global) {
        full_unicode = (try hasFlag(vm, flags, 'u')) or (try hasFlag(vm, flags, 'v'));
        try setLastIndex(vm, rx, 0);
    }
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.meta);
    while (true) {
        const result = try regExpExec(vm, rx, s);
        if (result.isNull()) break;
        try results.append(vm.meta, result);
        if (!global) break;
        const match_str = try vm.toString(try vm.get(asObject(result), .{ .index = 0 }, result));
        if (match_str.len == 0) {
            const li = try getLastIndex(vm, rx);
            try setLastIndex(vm, rx, advanceIndex(s, li, full_unicode));
        }
    }
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    var next_source: usize = 0;
    for (results.items) |result| {
        const ro = asObject(result);
        const ncaps = try vm.lengthOfArrayLike(ro);
        const n_captures: usize = if (ncaps > 0) @intCast(ncaps - 1) else 0;
        const matched = try vm.strings.flatten(try vm.toString(try vm.get(ro, .{ .index = 0 }, result)));
        const pos_v = try vm.toIntegerOrInfinity(try vm.get(ro, .{ .atom = vm.atoms.index }, result));
        const position: usize = @intFromFloat(@max(0, @min(pos_v, @as(f64, @floatFromInt(s.len)))));
        var captures: std.ArrayList(Value) = .empty;
        defer captures.deinit(vm.meta);
        var k: u32 = 1;
        while (k <= n_captures) : (k += 1) {
            var cap = try vm.get(ro, .{ .index = k }, result);
            if (!cap.isUndefined()) cap = strValue(try vm.toString(cap));
            try captures.append(vm.meta, cap);
        }
        var named = try vm.get(ro, .{ .atom = vm.atoms.groups }, result);
        var replacement: *String = undefined;
        if (functional) {
            var call_args: std.ArrayList(Value) = .empty;
            defer call_args.deinit(vm.meta);
            try call_args.append(vm.meta, strValue(matched));
            try call_args.appendSlice(vm.meta, captures.items);
            try call_args.append(vm.meta, Value.fromInt(@intCast(position)));
            try call_args.append(vm.meta, strValue(s));
            if (!named.isUndefined()) try call_args.append(vm.meta, named);
            const rv = try vm.call(replace_v, Value.undefined_, call_args.items);
            replacement = try vm.toString(rv);
        } else {
            if (!named.isUndefined()) named = (try vm.toObject(named)).asValue();
            var rep: std.ArrayList(u16) = .empty;
            defer rep.deinit(vm.meta);
            try getSubstitution(vm, matched, s, position, captures.items, named, asString(replace_v), &rep);
            replacement = try vm.strings.fromUnits(rep.items);
        }
        if (position >= next_source) {
            var k2 = next_source;
            while (k2 < position) : (k2 += 1) try out.append(vm.meta, s.unitAt(k2));
            try appendString(vm, &out, replacement);
            next_source = position + matched.len;
        }
    }
    var k3 = next_source;
    while (k3 < s.len) : (k3 += 1) try out.append(vm.meta, s.unitAt(k3));
    return strValue(try vm.strings.fromUnits(out.items));
}

fn symbolSplit(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype[Symbol.split] called on non-object");
    const rx = asObject(this);
    const s = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const c = try vm.speciesConstructor(rx, vm.intrinsics.regexp_ctor.asValue());
    const flags = try flagsOf(vm, rx);
    const unicode = (try hasFlag(vm, flags, 'u')) or (try hasFlag(vm, flags, 'v'));
    var new_flags = flags;
    if (!try hasFlag(vm, flags, 'y')) new_flags = try vm.concatStrings(flags, try vm.strings.fromUtf8("y"));
    const splitter_v = try vm.construct(c, &.{ this, strValue(new_flags) }, c);
    const splitter = asObject(splitter_v);
    const a = try vm.newArray(0);
    const limit_v = arg(args, 1);
    const lim: u32 = if (limit_v.isUndefined()) std.math.maxInt(u32) else try vm.toUint32(limit_v);
    if (lim == 0) return a.asValue();
    const size = s.len;
    if (size == 0) {
        const z = try regExpExec(vm, splitter, s);
        if (!z.isNull()) return a.asValue();
        try vm.arrayPush(a, strValue(s));
        return a.asValue();
    }
    var p: usize = 0;
    var q: usize = p;
    var count: u32 = 0;
    while (q < size) {
        try setLastIndex(vm, splitter, q);
        const z = try regExpExec(vm, splitter, s);
        if (z.isNull()) {
            q = @intCast(advanceIndex(s, q, unicode));
            continue;
        }
        const e_raw = try getLastIndex(vm, splitter);
        const e: usize = @intCast(@min(e_raw, size));
        if (e == p) {
            q = @intCast(advanceIndex(s, q, unicode));
            continue;
        }
        try vm.arrayPush(a, strValue(try substring(vm, s, p, q)));
        count += 1;
        if (count == lim) return a.asValue();
        p = e;
        const zo = asObject(z);
        const ncaps = try vm.lengthOfArrayLike(zo);
        var i: u32 = 1;
        while (i < ncaps) : (i += 1) {
            try vm.arrayPush(a, try vm.get(zo, .{ .index = i }, z));
            count += 1;
            if (count == lim) return a.asValue();
        }
        q = p;
    }
    try vm.arrayPush(a, strValue(try substring(vm, s, p, size)));
    return a.asValue();
}

fn substring(vm: *Vm, s: *String, from: usize, to: usize) Error!*String {
    if (from >= to) return vm.atoms.empty;
    if (s.latin1()) |bytes| return vm.strings.fromLatin1(bytes[from..to]);
    return vm.strings.fromUnits(s.utf16().?[from..to]);
}

// ------------------------------------------------------------ matchAll

const StringIteratorData = extern struct {
    target: Value, // the splitter regexp, undefined once done
    extra: Value, // the string
    global: bool,
    unicode: bool,
    _pad: [6]u8 = @splat(0),
};

fn symbolMatchAll(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("RegExp.prototype[Symbol.matchAll] called on non-object");
    const rx = asObject(this);
    const s = try vm.toString(arg(args, 0));
    const c = try vm.speciesConstructor(rx, vm.intrinsics.regexp_ctor.asValue());
    const flags = try flagsOf(vm, rx);
    const matcher_v = try vm.construct(c, &.{ this, strValue(flags) }, c);
    const last_index = try getLastIndex(vm, rx);
    try setLastIndex(vm, asObject(matcher_v), last_index);
    const global = try hasFlag(vm, flags, 'g');
    const unicode = (try hasFlag(vm, flags, 'u')) or (try hasFlag(vm, flags, 'v'));
    const o = try vm.objects.create(vm.intrinsics.regexp_string_iterator_prototype.asValue(), .iterator, @sizeOf(StringIteratorData));
    o.internal(StringIteratorData).* = .{ .target = matcher_v, .extra = strValue(s), .global = global, .unicode = unicode };
    return o.asValue();
}

fn stringIteratorNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject() or asObject(this).class != .iterator or asObject(this).shape.proto.bits != vm.intrinsics.regexp_string_iterator_prototype.asValue().bits) return vm.throwTypeError("RegExp String Iterator next called on incompatible receiver");
    const d = asObject(this).internal(StringIteratorData);
    if (d.target.isUndefined()) return vm.iterResult(Value.undefined_, true);
    const rx = asObject(d.target);
    const s = try vm.strings.flatten(asString(d.extra));
    const result = try regExpExec(vm, rx, s);
    if (result.isNull()) {
        d.target = Value.undefined_;
        return vm.iterResult(Value.undefined_, true);
    }
    if (!d.global) {
        d.target = Value.undefined_;
        return vm.iterResult(result, false);
    }
    const match_str = try vm.toString(try vm.get(asObject(result), .{ .index = 0 }, result));
    if (match_str.len == 0) {
        const li = try getLastIndex(vm, rx);
        try setLastIndex(vm, rx, advanceIndex(s, li, d.unicode));
    }
    return vm.iterResult(result, false);
}
