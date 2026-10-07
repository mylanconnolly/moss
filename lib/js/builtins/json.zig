//! JSON (§25.5): parse with a reviver, stringify with replacer and
//! indentation, over UTF-16 text.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
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

pub fn install(vm: *Vm) Error!void {
    const j = try vm.newObject();
    try vm.defineValue(vm.global, "JSON", j.asValue(), .hidden);
    try b.setToStringTag(vm, j, "JSON");
    _ = try vm.defineNative(j, "parse", 2, parse);
    _ = try vm.defineNative(j, "stringify", 3, stringify);
}

// ------------------------------------------------------------- parse

const Parser = struct {
    vm: *Vm,
    s: *String,
    pos: usize = 0,

    fn peek(p: *Parser) ?u16 {
        return if (p.pos < p.s.len) p.s.unitAt(p.pos) else null;
    }
    fn skipWs(p: *Parser) void {
        while (p.peek()) |c| : (p.pos += 1) if (c != ' ' and c != '\t' and c != '\n' and c != '\r') break;
    }
    fn fail(p: *Parser) Error {
        var buf: [64]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Unexpected token in JSON at position {d}", .{p.pos}) catch "Unexpected token in JSON";
        return p.vm.throwSyntaxError(msg);
    }
    fn expectWord(p: *Parser, w: []const u8) Error!void {
        for (w) |ch| {
            if (p.peek() != @as(u16, ch)) return p.fail();
            p.pos += 1;
        }
    }

    fn value(p: *Parser) Error!Value {
        p.skipWs();
        const c = p.peek() orelse return p.fail();
        switch (c) {
            '{' => {
                p.pos += 1;
                const o = try p.vm.newObject();
                p.skipWs();
                if (p.peek() == '}') {
                    p.pos += 1;
                    return o.asValue();
                }
                while (true) {
                    p.skipWs();
                    if (p.peek() != '"') return p.fail();
                    const k = try p.string();
                    p.skipWs();
                    if (p.peek() != ':') return p.fail();
                    p.pos += 1;
                    const v = try p.value();
                    _ = try p.vm.createDataProperty(o, try p.vm.keyFromString(k), v);
                    p.skipWs();
                    const n = p.peek() orelse return p.fail();
                    p.pos += 1;
                    if (n == '}') return o.asValue();
                    if (n != ',') return p.fail();
                }
            },
            '[' => {
                p.pos += 1;
                const a = try p.vm.newArray(0);
                p.skipWs();
                if (p.peek() == ']') {
                    p.pos += 1;
                    return a.asValue();
                }
                while (true) {
                    const v = try p.value();
                    try p.vm.arrayPush(a, v);
                    p.skipWs();
                    const n = p.peek() orelse return p.fail();
                    p.pos += 1;
                    if (n == ']') return a.asValue();
                    if (n != ',') return p.fail();
                }
            },
            '"' => return strValue(try p.string()),
            't' => {
                try p.expectWord("true");
                return Value.true_;
            },
            'f' => {
                try p.expectWord("false");
                return Value.false_;
            },
            'n' => {
                try p.expectWord("null");
                return Value.null_;
            },
            else => return p.number(),
        }
    }

    fn number(p: *Parser) Error!Value {
        const start = p.pos;
        var buf: [400]u8 = undefined;
        var n: usize = 0;
        if (p.peek() == '-') {
            buf[n] = '-';
            n += 1;
            p.pos += 1;
        }
        const first = p.peek() orelse return p.fail();
        if (first == '0') {
            buf[n] = '0';
            n += 1;
            p.pos += 1;
        } else if (first >= '1' and first <= '9') {
            while (p.peek()) |c| : (p.pos += 1) {
                if (c < '0' or c > '9') break;
                if (n < buf.len) {
                    buf[n] = @intCast(c);
                    n += 1;
                }
            }
        } else return p.fail();
        if (p.peek() == '.') {
            if (n < buf.len) {
                buf[n] = '.';
                n += 1;
            }
            p.pos += 1;
            var digits: usize = 0;
            while (p.peek()) |c| : (p.pos += 1) {
                if (c < '0' or c > '9') break;
                if (n < buf.len) {
                    buf[n] = @intCast(c);
                    n += 1;
                }
                digits += 1;
            }
            if (digits == 0) return p.fail();
        }
        if (p.peek() == 'e' or p.peek() == 'E') {
            if (n < buf.len) {
                buf[n] = 'e';
                n += 1;
            }
            p.pos += 1;
            if (p.peek() == '+' or p.peek() == '-') {
                if (n < buf.len) {
                    buf[n] = @intCast(p.peek().?);
                    n += 1;
                }
                p.pos += 1;
            }
            var digits: usize = 0;
            while (p.peek()) |c| : (p.pos += 1) {
                if (c < '0' or c > '9') break;
                if (n < buf.len) {
                    buf[n] = @intCast(c);
                    n += 1;
                }
                digits += 1;
            }
            if (digits == 0) return p.fail();
        }
        if (p.pos - start > buf.len) {
            // Too long for the buffer: go through the string path.
            const units = try p.vm.meta.alloc(u16, p.pos - start);
            defer p.vm.meta.free(units);
            for (units, 0..) |*u, i| u.* = p.s.unitAt(start + i);
            const s = try p.vm.strings.fromUnits(units);
            return Value.fromF64(try p.vm.stringToNumber(s));
        }
        const d = std.fmt.parseFloat(f64, buf[0..n]) catch return p.fail();
        return Value.fromF64(d);
    }

    fn string(p: *Parser) Error!*String {
        p.pos += 1; // opening quote
        var units: std.ArrayList(u16) = .empty;
        defer units.deinit(p.vm.meta);
        while (true) {
            const c = p.peek() orelse return p.fail();
            p.pos += 1;
            if (c == '"') break;
            if (c < 0x20) return p.fail();
            if (c != '\\') {
                try units.append(p.vm.meta, c);
                continue;
            }
            const e = p.peek() orelse return p.fail();
            p.pos += 1;
            switch (e) {
                '"' => try units.append(p.vm.meta, '"'),
                '\\' => try units.append(p.vm.meta, '\\'),
                '/' => try units.append(p.vm.meta, '/'),
                'b' => try units.append(p.vm.meta, 8),
                'f' => try units.append(p.vm.meta, 12),
                'n' => try units.append(p.vm.meta, '\n'),
                'r' => try units.append(p.vm.meta, '\r'),
                't' => try units.append(p.vm.meta, '\t'),
                'u' => {
                    var v: u16 = 0;
                    var k: usize = 0;
                    while (k < 4) : (k += 1) {
                        const h = p.peek() orelse return p.fail();
                        if (h > 127) return p.fail();
                        const d = std.fmt.charToDigit(@intCast(h), 16) catch return p.fail();
                        v = v * 16 + d;
                        p.pos += 1;
                    }
                    try units.append(p.vm.meta, v);
                },
                else => return p.fail(),
            }
        }
        return p.vm.strings.fromUnits(units.items);
    }
};

/// The value of a JSON text (a flat string), or a SyntaxError; what
/// `JSON.parse` and a JSON module share.
pub fn parseText(vm: *Vm, text: *String) Error!Value {
    var p = Parser{ .vm = vm, .s = text };
    const v = try p.value();
    p.skipWs();
    if (p.pos != text.len) return p.fail();
    return v;
}

fn parse(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const text = try vm.strings.flatten(try vm.toString(arg(args, 0)));
    const v = try parseText(vm, text);
    const reviver = arg(args, 1);
    if (vm.isCallable(reviver)) {
        const root = try vm.newObject();
        _ = try vm.createDataProperty(root, .{ .atom = vm.atoms.empty }, v);
        return internalize(vm, root, .{ .atom = vm.atoms.empty }, reviver);
    }
    return v;
}

/// InternalizeJSONProperty.
fn internalize(vm: *Vm, holder: *Object, name: Key, reviver: Value) Error!Value {
    const val = try vm.get(holder, name, holder.asValue());
    if (val.isObject()) {
        const o = asObject(val);
        if (try vm.isArray(val)) {
            const len = try vm.lengthOfArrayLike(o);
            var i: u32 = 0;
            while (i < len) : (i += 1) {
                const k: Key = .{ .index = i };
                const nv = try internalize(vm, o, k, reviver);
                if (nv.isUndefined()) {
                    _ = try vm.deleteProperty(o, k);
                } else _ = try vm.createDataProperty(o, k, nv);
            }
        } else {
            var keys: std.ArrayList(Key) = .empty;
            defer keys.deinit(vm.meta);
            try vm.enumerableOwnKeys(o, &keys);
            for (keys.items) |k| {
                const nv = try internalize(vm, o, k, reviver);
                if (nv.isUndefined()) {
                    _ = try vm.deleteProperty(o, k);
                } else _ = try vm.createDataProperty(o, k, nv);
            }
        }
    }
    const name_v = try vm.keyToValue(name);
    return vm.call(reviver, holder.asValue(), &.{ name_v, val });
}

// --------------------------------------------------------- stringify

const Stringifier = struct {
    vm: *Vm,
    out: std.ArrayList(u16) = .empty,
    replacer_fn: Value = Value.undefined_,
    property_list: ?std.ArrayList(Key) = null,
    gap: []const u16 = &.{},
    indent: std.ArrayList(u16) = .empty,
    stack: std.ArrayList(*Object) = .empty,

    fn deinit(s: *Stringifier) void {
        s.out.deinit(s.vm.meta);
        s.indent.deinit(s.vm.meta);
        s.stack.deinit(s.vm.meta);
        if (s.property_list) |*l| l.deinit(s.vm.meta);
    }

    fn appendAscii(s: *Stringifier, text: []const u8) Error!void {
        for (text) |ch| try s.out.append(s.vm.meta, ch);
    }

    fn appendString(s: *Stringifier, str: *String) Error!void {
        const f = try s.vm.strings.flatten(str);
        var i: usize = 0;
        while (i < f.len) : (i += 1) try s.out.append(s.vm.meta, f.unitAt(i));
    }

    /// QuoteJSONString.
    fn quote(s: *Stringifier, str: *String) Error!void {
        const f = try s.vm.strings.flatten(str);
        try s.out.append(s.vm.meta, '"');
        var i: usize = 0;
        while (i < f.len) : (i += 1) {
            const c = f.unitAt(i);
            switch (c) {
                8 => try s.appendAscii("\\b"),
                9 => try s.appendAscii("\\t"),
                10 => try s.appendAscii("\\n"),
                12 => try s.appendAscii("\\f"),
                13 => try s.appendAscii("\\r"),
                '"' => try s.appendAscii("\\\""),
                '\\' => try s.appendAscii("\\\\"),
                else => {
                    var lone = false;
                    if (c >= 0xd800 and c <= 0xdbff) {
                        if (i + 1 < f.len and f.unitAt(i + 1) >= 0xdc00 and f.unitAt(i + 1) <= 0xdfff) {
                            try s.out.append(s.vm.meta, c);
                            try s.out.append(s.vm.meta, f.unitAt(i + 1));
                            i += 1;
                            continue;
                        }
                        lone = true;
                    } else if (c >= 0xdc00 and c <= 0xdfff) lone = true;
                    if (c < 0x20 or lone) {
                        var buf: [8]u8 = undefined;
                        const h = std.fmt.bufPrint(&buf, "\\u{x:0>4}", .{c}) catch unreachable;
                        try s.appendAscii(h);
                    } else try s.out.append(s.vm.meta, c);
                },
            }
        }
        try s.out.append(s.vm.meta, '"');
    }

    /// SerializeJSONProperty: returns false when the value is not serialized (undefined).
    fn property(s: *Stringifier, key: Key, holder: *Object) Error!bool {
        const vm = s.vm;
        var value = try vm.get(holder, key, holder.asValue());
        if (value.isObject() or value.isBigInt()) {
            const to_json = try vm.getV(value, .{ .atom = vm.atoms.toJSON });
            if (vm.isCallable(to_json)) value = try vm.call(to_json, value, &.{try vm.keyToValue(key)});
        }
        if (!s.replacer_fn.isUndefined()) value = try vm.call(s.replacer_fn, holder.asValue(), &.{ try vm.keyToValue(key), value });
        if (value.isObject()) {
            const o = asObject(value);
            switch (o.class) {
                .number => value = Value.fromF64(try vm.toNumber(value)),
                .string => value = strValue(try vm.toString(value)),
                .boolean, .bigint => value = o.internal(vmod.PrimitiveData).value,
                else => {},
            }
        }
        if (value.isNull()) {
            try s.appendAscii("null");
            return true;
        }
        if (value.isBool()) {
            try s.appendAscii(if (value.asBool()) "true" else "false");
            return true;
        }
        if (value.isString()) {
            try s.quote(asString(value));
            return true;
        }
        if (value.isNumber()) {
            if (std.math.isFinite(value.asNumber())) {
                try s.appendString(try vm.toString(value));
            } else try s.appendAscii("null");
            return true;
        }
        if (value.isBigInt()) return vm.throwTypeError("Do not know how to serialize a BigInt");
        if (value.isObject() and !vm.isCallable(value)) {
            if (try vm.isArray(value)) {
                try s.array(asObject(value));
            } else try s.object(asObject(value));
            return true;
        }
        return false;
    }

    fn checkCycle(s: *Stringifier, o: *Object) Error!void {
        for (s.stack.items) |p| if (p == o) return s.vm.throwTypeError("Converting circular structure to JSON");
        try s.stack.append(s.vm.meta, o);
    }

    fn newline(s: *Stringifier) Error!void {
        if (s.gap.len == 0) return;
        try s.out.append(s.vm.meta, '\n');
        try s.out.appendSlice(s.vm.meta, s.indent.items);
    }

    fn object(s: *Stringifier, o: *Object) Error!void {
        const vm = s.vm;
        try s.checkCycle(o);
        defer _ = s.stack.pop();
        const stepback = s.indent.items.len;
        try s.indent.appendSlice(vm.meta, s.gap);
        defer s.indent.shrinkRetainingCapacity(stepback);
        var keys: std.ArrayList(Key) = .empty;
        defer keys.deinit(vm.meta);
        if (s.property_list) |pl| {
            try keys.appendSlice(vm.meta, pl.items);
        } else try vm.enumerableOwnKeys(o, &keys);
        try s.out.append(vm.meta, '{');
        var any = false;
        for (keys.items) |k| {
            const mark = s.out.items.len;
            if (any) try s.out.append(vm.meta, ',');
            try s.newline();
            try s.quote(try vm.keyToString(k));
            try s.out.append(vm.meta, ':');
            if (s.gap.len > 0) try s.out.append(vm.meta, ' ');
            if (!try s.property(k, o)) {
                s.out.shrinkRetainingCapacity(mark);
                continue;
            }
            any = true;
        }
        if (any) {
            s.indent.shrinkRetainingCapacity(stepback);
            try s.newline();
        }
        try s.out.append(vm.meta, '}');
    }

    fn array(s: *Stringifier, o: *Object) Error!void {
        const vm = s.vm;
        try s.checkCycle(o);
        defer _ = s.stack.pop();
        const stepback = s.indent.items.len;
        try s.indent.appendSlice(vm.meta, s.gap);
        defer s.indent.shrinkRetainingCapacity(stepback);
        const len = try vm.lengthOfArrayLike(o);
        try s.out.append(vm.meta, '[');
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            if (i > 0) try s.out.append(vm.meta, ',');
            try s.newline();
            if (!try s.property(.{ .index = i }, o)) try s.appendAscii("null");
        }
        if (len > 0) {
            s.indent.shrinkRetainingCapacity(stepback);
            try s.newline();
        }
        try s.out.append(vm.meta, ']');
    }
};

fn stringify(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    var s = Stringifier{ .vm = vm };
    defer s.deinit();
    const replacer = arg(args, 1);
    if (vm.isCallable(replacer)) {
        s.replacer_fn = replacer;
    } else if (try vm.isArray(replacer)) {
        var list: std.ArrayList(Key) = .empty;
        const ro = asObject(replacer);
        const len = try vm.lengthOfArrayLike(ro);
        var i: u32 = 0;
        while (i < len) : (i += 1) {
            const v = try vm.get(ro, .{ .index = i }, replacer);
            var item: ?*String = null;
            if (v.isString()) {
                item = asString(v);
            } else if (v.isNumber()) {
                item = try vm.toString(v);
            } else if (v.isObject() and (asObject(v).class == .string or asObject(v).class == .number)) {
                item = try vm.toString(v);
            }
            if (item) |it| {
                const k = try vm.keyFromString(it);
                var dup = false;
                for (list.items) |x| if (x.eql(k)) {
                    dup = true;
                    break;
                };
                if (!dup) try list.append(vm.meta, k);
            }
        }
        s.property_list = list;
    }
    var space = arg(args, 2);
    if (space.isObject()) {
        const so = asObject(space);
        if (so.class == .number) space = Value.fromF64(try vm.toNumber(space)) else if (so.class == .string) space = strValue(try vm.toString(space));
    }
    var gap_buf: [10]u16 = undefined;
    if (space.isNumber()) {
        const n: usize = @intFromFloat(@min(10, @max(0, try vm.toIntegerOrInfinity(space))));
        @memset(gap_buf[0..n], ' ');
        s.gap = gap_buf[0..n];
    } else if (space.isString()) {
        const f = try vm.strings.flatten(asString(space));
        const n = @min(10, f.len);
        var i: usize = 0;
        while (i < n) : (i += 1) gap_buf[i] = f.unitAt(i);
        s.gap = gap_buf[0..n];
    }
    const wrapper = try vm.newObject();
    _ = try vm.createDataProperty(wrapper, .{ .atom = vm.atoms.empty }, arg(args, 0));
    if (!try s.property(.{ .atom = vm.atoms.empty }, wrapper)) return Value.undefined_;
    return strValue(try vm.strings.fromUnits(s.out.items));
}
