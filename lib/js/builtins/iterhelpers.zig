//! The Iterator constructor and the iterator helpers (§27.1.3, ES2025),
//! with the proposals test262 counts alongside them: `Iterator.concat`,
//! `Iterator.zip`/`zipKeyed`, `chunks`/`windows`, `includes`/`join` and
//! `Symbol.dispose`. A helper is the specification's generator over an
//! abstract closure written as a native state machine: `next` runs one
//! step to the next yield, `return` performs the closure's abrupt
//! completion (closing what it holds open), and a step that throws
//! completes the helper for good.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const Key = b.Key;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;
const IteratorRecord = Vm.IteratorRecord;

const Kind = enum(u8) { map, filter, take, drop, flat_map, chunks, windows, concat, zip };
const State = enum(u8) { suspended_start, suspended_yield, executing, completed };
const Mode = enum(u8) { shortest, longest, strict };

pub const HelperData = extern struct {
    /// The underlying iterator and its `next` (for concat: the current
    /// inner iterator, once opened).
    target: Value,
    extra: Value,
    /// map/filter/flatMap: the callback. zip: the keys array or undefined.
    func: Value,
    /// flatMap: the inner iterator. concat: the list of [method, iterable].
    /// zip: the iterators array (null entries are exhausted). chunks/
    /// windows: the buffer array.
    inner: Value,
    /// flatMap: the inner `next`. zip: the `next` methods array.
    inner_next: Value,
    /// zip: the padding array.
    aux: Value,
    counter: f64,
    remaining: f64,
    kind: Kind,
    state: State,
    mode: Mode,
    inner_alive: bool,
    /// concat: index of the next record to open.
    position: u32,
};

fn hd(o: *Object) *HelperData {
    return o.internal(HelperData);
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    const d = hd(o);
    m.markValue(d.target);
    m.markValue(d.extra);
    m.markValue(d.func);
    m.markValue(d.inner);
    m.markValue(d.inner_next);
    m.markValue(d.aux);
}

// ------------------------------------------------------------ install

pub fn install(vm: *Vm) Error!void {
    const i = &vm.intrinsics;
    const ip = i.iterator_prototype;
    const ctor = try vm.newNativeNamed(strValue(try vm.atom("Iterator")), 0, construct, Value.undefined_, true);
    i.iterator_ctor = ctor;
    _ = try vm.objects.defineOwn(ctor, .{ .atom = vm.atoms.prototype }, ip.asValue(), .frozen);
    try vm.defineValue(vm.global, "Iterator", ctor.asValue(), .hidden);
    _ = try vm.defineNative(ctor, "from", 1, from);
    _ = try vm.defineNative(ctor, "concat", 0, concat);
    _ = try vm.defineNative(ctor, "zip", 1, zip);
    _ = try vm.defineNative(ctor, "zipKeyed", 1, zipKeyed);
    // constructor and @@toStringTag are accessors whose setter ignores
    // the prototype itself.
    const cget = try vm.newNative("get constructor", 0, getConstructor, Value.undefined_);
    const cset = try vm.newNative("set constructor", 1, setConstructor, Value.undefined_);
    try vm.defineAccessor(ip, .{ .atom = vm.atoms.constructor }, cget, cset, .{ .enumerable = false, .configurable = true });
    const tget = try vm.newNative("get [Symbol.toStringTag]", 0, getToStringTag, Value.undefined_);
    const tset = try vm.newNative("set [Symbol.toStringTag]", 1, setToStringTag, Value.undefined_);
    try vm.defineAccessor(ip, .{ .symbol = vm.symbols.to_string_tag }, tget, tset, .{ .enumerable = false, .configurable = true });
    inline for (.{
        .{ "map", map, 1 },         .{ "filter", filter, 1 }, .{ "take", take, 1 },       .{ "drop", drop, 1 },
        .{ "flatMap", flatMap, 1 }, .{ "reduce", reduce, 1 }, .{ "toArray", toArray, 0 }, .{ "forEach", forEach, 1 },
        .{ "some", some, 1 },       .{ "every", every, 1 },   .{ "find", find, 1 },       .{ "includes", includes, 1 },
        .{ "join", join, 1 },       .{ "chunks", chunks, 1 }, .{ "windows", windows, 1 },
    }) |e| _ = try vm.defineNative(ip, e[0], e[2], e[1]);
    _ = try vm.defineNativeSymbol(ip, vm.symbols.dispose, "[Symbol.dispose]", 0, dispose);
    // %IteratorHelperPrototype%
    const hp = try vm.objects.create(ip.asValue(), .ordinary, 0);
    i.iterator_helper_prototype = hp;
    _ = try vm.defineNative(hp, "next", 0, helperNext);
    _ = try vm.defineNative(hp, "return", 0, helperReturn);
    try b.setToStringTag(vm, hp, "Iterator Helper");
    // %WrapForValidIteratorPrototype%
    const wp = try vm.objects.create(ip.asValue(), .ordinary, 0);
    i.wrap_for_valid_iterator_prototype = wp;
    _ = try vm.defineNative(wp, "next", 0, wrapNext);
    _ = try vm.defineNative(wp, "return", 0, wrapReturn);
}

fn construct(vm: *Vm, _: Value, _: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined() or (new_target.isObject() and asObject(new_target) == vm.intrinsics.iterator_ctor)) return vm.throwTypeError("Iterator is an abstract class; use a subclass or Iterator.from");
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.iterator_prototype, .ordinary, 0);
    return o.asValue();
}

fn getConstructor(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return vm.intrinsics.iterator_ctor.asValue();
}

fn getToStringTag(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return vm.str("Iterator");
}

/// SetterThatIgnoresPrototypeProperties (§27.1.3.2.1.1).
fn setterIgnoringPrototype(vm: *Vm, this: Value, key: Key, v: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype setter called on a non-object");
    const o = asObject(this);
    if (o == vm.intrinsics.iterator_prototype) return vm.throwTypeError("Cannot assign to this property of Iterator.prototype");
    if ((try vm.getOwnProperty(o, key)) == null) {
        try vm.createDataPropertyOrThrow(o, key, v);
    } else {
        if (!try vm.set(o, key, v, this)) return vm.throwTypeError("Cannot assign to read only property");
    }
    return Value.undefined_;
}

fn setConstructor(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return setterIgnoringPrototype(vm, this, .{ .atom = vm.atoms.constructor }, arg(args, 0));
}

fn setToStringTag(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return setterIgnoringPrototype(vm, this, .{ .symbol = vm.symbols.to_string_tag }, arg(args, 0));
}

// ----------------------------------------------------------- records

/// GetIteratorDirect: the object and its `next`, read once.
fn getIteratorDirect(vm: *Vm, o: *Object) Error!IteratorRecord {
    const next = try vm.get(o, .{ .atom = try vm.atom("next") }, o.asValue());
    return .{ .iterator = o.asValue(), .next = next };
}

/// GetIteratorFlattenable (§7.4.13).
fn getIteratorFlattenable(vm: *Vm, v: Value, allow_strings: bool) Error!IteratorRecord {
    if (!v.isObject()) {
        if (!(allow_strings and v.isString())) return vm.throwTypeError("Value is not an iterator or iterable object");
    }
    const method = try vm.getMethod(v, .{ .symbol = vm.symbols.iterator });
    var it: Value = v;
    if (!method.isUndefined()) it = try vm.call(method, v, &.{});
    if (!it.isObject()) return vm.throwTypeError("The iterator is not an object");
    return getIteratorDirect(vm, asObject(it));
}

/// IteratorClose with a throw completion in flight: `return` is called
/// and its result ignored; the pending exception is what propagates.
fn closeThrow(vm: *Vm, rec: IteratorRecord, e: Error) Error {
    vm.iteratorCloseThrow(rec);
    return e;
}

/// The `this` of a helper method: an object, with the argument check
/// closing it on failure (§27.1.4.x steps 2-4).
fn thisRecord(vm: *Vm, this: Value, callback: ?Value, what: []const u8) Error!IteratorRecord {
    if (!this.isObject()) return vm.throwTypeErrorFmt("{s} called on non-object", .{what});
    if (callback) |f| if (!vm.isCallable(f)) {
        const rec = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
        return closeThrow(vm, rec, vm.throwTypeErrorFmt("{s}: callback is not a function", .{what}));
    };
    return getIteratorDirect(vm, asObject(this));
}

// --------------------------------------------------- Iterator.from

fn from(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const rec = try getIteratorFlattenable(vm, arg(args, 0), true);
    if (try vm.ordinaryHasInstance(vm.intrinsics.iterator_ctor.asValue(), rec.iterator)) return rec.iterator;
    const w = try vm.objects.create(vm.intrinsics.wrap_for_valid_iterator_prototype.asValue(), .iterator, @sizeOf(vmod.IteratorHead));
    w.internal(vmod.IteratorHead).* = .{ .target = rec.iterator, .extra = rec.next };
    return w.asValue();
}

fn thisWrapper(vm: *Vm, this: Value) Error!*vmod.IteratorHead {
    if (!this.isObject() or asObject(this).class != .iterator or asObject(this).shape.proto.bits != vm.intrinsics.wrap_for_valid_iterator_prototype.asValue().bits) return vm.throwTypeError("Method called on incompatible receiver");
    return asObject(this).internal(vmod.IteratorHead);
}

fn wrapNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const h = try thisWrapper(vm, this);
    return vm.call(h.extra, h.target, &.{});
}

fn wrapReturn(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const h = try thisWrapper(vm, this);
    const ret = try vm.getMethod(h.target, .{ .atom = try vm.atom("return") });
    if (ret.isUndefined()) return vm.iterResult(Value.undefined_, true);
    return vm.call(ret, h.target, &.{});
}

// ----------------------------------------------------------- helpers

fn newHelper(vm: *Vm, kind: Kind, rec: IteratorRecord, func: Value) Error!*Object {
    const o = try vm.objects.create(vm.intrinsics.iterator_helper_prototype.asValue(), .iterator_helper, @sizeOf(HelperData));
    hd(o).* = .{ .target = rec.iterator, .extra = rec.next, .func = func, .inner = Value.undefined_, .inner_next = Value.undefined_, .aux = Value.undefined_, .counter = 0, .remaining = 0, .kind = kind, .state = .suspended_start, .mode = .shortest, .inner_alive = false, .position = 0 };
    return o;
}

fn underlying(d: *HelperData) IteratorRecord {
    return .{ .iterator = d.target, .next = d.extra };
}

fn innerRecord(d: *HelperData) IteratorRecord {
    return .{ .iterator = d.inner, .next = d.inner_next };
}

fn thisHelper(vm: *Vm, this: Value) Error!*Object {
    if (!this.isObject() or asObject(this).class != .iterator_helper) return vm.throwTypeError("Iterator Helper method called on incompatible receiver");
    return asObject(this);
}

fn helperNext(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisHelper(vm, this);
    const d = hd(o);
    switch (d.state) {
        .executing => return vm.throwTypeError("Generator is already running"),
        .completed => return vm.iterResult(Value.undefined_, true),
        else => {},
    }
    d.state = .executing;
    const v = step(vm, o) catch |e| {
        d.state = .completed;
        return e;
    };
    if (v) |value| {
        d.state = .suspended_yield;
        return vm.iterResult(value, false);
    }
    d.state = .completed;
    return vm.iterResult(Value.undefined_, true);
}

fn helperReturn(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const o = try thisHelper(vm, this);
    const d = hd(o);
    switch (d.state) {
        .executing => return vm.throwTypeError("Generator is already running"),
        .completed => return vm.iterResult(Value.undefined_, true),
        .suspended_start => {
            d.state = .completed;
            switch (d.kind) {
                .concat => {},
                .zip => try closeAll(vm, d, null),
                else => try vm.iteratorClose(underlying(d)),
            }
            return vm.iterResult(Value.undefined_, true);
        },
        .suspended_yield => {
            d.state = .executing;
            abruptReturn(vm, d) catch |e| {
                d.state = .completed;
                return e;
            };
            d.state = .completed;
            return vm.iterResult(Value.undefined_, true);
        },
    }
}

/// The closure's handling of a return completion at its yield.
fn abruptReturn(vm: *Vm, d: *HelperData) Error!void {
    switch (d.kind) {
        .flat_map => {
            if (d.inner_alive) {
                vm.iteratorClose(innerRecord(d)) catch |e| return closeThrow(vm, underlying(d), e);
            }
            try vm.iteratorClose(underlying(d));
        },
        .concat => {
            if (d.inner_alive) try vm.iteratorClose(underlying(d));
        },
        .zip => try closeAll(vm, d, null),
        else => try vm.iteratorClose(underlying(d)),
    }
}

/// One step of the closure: the next value to yield, or null when the
/// closure returns.
fn step(vm: *Vm, o: *Object) Error!?Value {
    const d = hd(o);
    switch (d.kind) {
        .map => {
            var rec = underlying(d);
            const v = (try vm.iteratorStepValue(&rec)) orelse return null;
            const mapped = vm.call(d.func, Value.undefined_, &.{ v, Value.fromF64(d.counter) }) catch |e| return closeThrow(vm, rec, e);
            d.counter += 1;
            return mapped;
        },
        .filter => {
            var rec = underlying(d);
            while (true) {
                const v = (try vm.iteratorStepValue(&rec)) orelse return null;
                const selected = vm.call(d.func, Value.undefined_, &.{ v, Value.fromF64(d.counter) }) catch |e| return closeThrow(vm, rec, e);
                d.counter += 1;
                if (vm.toBoolean(selected)) return v;
            }
        },
        .take => {
            var rec = underlying(d);
            if (d.remaining == 0) {
                try vm.iteratorClose(rec);
                return null;
            }
            if (d.remaining != std.math.inf(f64)) d.remaining -= 1;
            return try vm.iteratorStepValue(&rec);
        },
        .drop => {
            var rec = underlying(d);
            while (d.remaining > 0) {
                if (d.remaining != std.math.inf(f64)) d.remaining -= 1;
                if ((try vm.iteratorStepValue(&rec)) == null) return null;
            }
            return try vm.iteratorStepValue(&rec);
        },
        .flat_map => {
            var rec = underlying(d);
            while (true) {
                if (d.inner_alive) {
                    var inner = innerRecord(d);
                    const r = vm.iteratorStepValue(&inner) catch |e| return closeThrow(vm, rec, e);
                    if (r) |v| return v;
                    d.inner_alive = false;
                    d.inner = Value.undefined_;
                    d.inner_next = Value.undefined_;
                }
                const v = (try vm.iteratorStepValue(&rec)) orelse return null;
                const mapped = vm.call(d.func, Value.undefined_, &.{ v, Value.fromF64(d.counter) }) catch |e| return closeThrow(vm, rec, e);
                const inner = getIteratorFlattenable(vm, mapped, false) catch |e| return closeThrow(vm, rec, e);
                d.inner = inner.iterator;
                d.inner_next = inner.next;
                d.inner_alive = true;
                d.counter += 1;
            }
        },
        .chunks => {
            var rec = underlying(d);
            const buf = asObject(d.inner);
            while (Vm.arrayLength(buf) < @as(u32, @intFromFloat(d.remaining))) {
                const v = (try vm.iteratorStepValue(&rec)) orelse {
                    if (Vm.arrayLength(buf) == 0) return null;
                    const out = buf.asValue();
                    d.inner = (try vm.newArray(0)).asValue();
                    d.inner_alive = false;
                    return out;
                };
                try vm.arrayPush(buf, v);
            }
            const out = buf.asValue();
            d.inner = (try vm.newArray(0)).asValue();
            return out;
        },
        .windows => {
            var rec = underlying(d);
            const size: u32 = @intFromFloat(d.remaining);
            const buf = asObject(d.inner);
            if (!d.inner_alive) {
                // The first window fills up; fewer values than the size
                // is no window at all.
                while (Vm.arrayLength(buf) < size) {
                    const v = (try vm.iteratorStepValue(&rec)) orelse {
                        // allow-partial: a non-empty short buffer is the
                        // one and only window.
                        if (d.mode == .longest and Vm.arrayLength(buf) > 0) {
                            d.mode = .shortest;
                            var part: std.ArrayList(Value) = .empty;
                            defer part.deinit(vm.meta);
                            try part.appendSlice(vm.meta, buf.elements.?.items()[0..Vm.arrayLength(buf)]);
                            d.inner_alive = true;
                            d.position = 1; // exhausted
                            return (try vm.arrayFromList(part.items)).asValue();
                        }
                        return null;
                    };
                    try vm.arrayPush(buf, v);
                }
                d.inner_alive = true;
            } else {
                if (d.position == 1) return null;
                const v = (try vm.iteratorStepValue(&rec)) orelse return null;
                const items = buf.elements.?.items();
                std.mem.copyForwards(Value, items[0 .. size - 1], items[1..size]);
                vm.heap.writeBarrier(&buf.header, v);
                items[size - 1] = v;
            }
            var copy: std.ArrayList(Value) = .empty;
            defer copy.deinit(vm.meta);
            try copy.appendSlice(vm.meta, buf.elements.?.items()[0..size]);
            return (try vm.arrayFromList(copy.items)).asValue();
        },
        .concat => return concatStep(vm, d),
        .zip => return zipStep(vm, d),
    }
}

/// ToIntegerOrInfinity of a take/drop limit, closing the iterator on
/// a bad one.
fn limitOf(vm: *Vm, rec: IteratorRecord, v: Value) Error!f64 {
    const num = vm.toNumber(v) catch |e| return closeThrow(vm, rec, e);
    if (std.math.isNan(num)) return closeThrow(vm, rec, vm.throwRangeError("The limit must be a number"));
    if (std.math.isFinite(num) and num > 9007199254740991.0) return closeThrow(vm, rec, vm.throwRangeError("The limit is too large"));
    const n = try vm.toIntegerOrInfinity(Value.fromF64(num));
    if (n < 0) return closeThrow(vm, rec, vm.throwRangeError("The limit must not be negative"));
    return n;
}

fn map(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const rec = try thisRecord(vm, this, arg(args, 0), "Iterator.prototype.map");
    return (try newHelper(vm, .map, rec, arg(args, 0))).asValue();
}

fn filter(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const rec = try thisRecord(vm, this, arg(args, 0), "Iterator.prototype.filter");
    return (try newHelper(vm, .filter, rec, arg(args, 0))).asValue();
}

fn take(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype.take called on non-object");
    const pre = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
    const limit = try limitOf(vm, pre, arg(args, 0));
    const rec = try getIteratorDirect(vm, asObject(this));
    const h = try newHelper(vm, .take, rec, Value.undefined_);
    hd(h).remaining = limit;
    return h.asValue();
}

fn drop(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype.drop called on non-object");
    const pre = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
    const limit = try limitOf(vm, pre, arg(args, 0));
    const rec = try getIteratorDirect(vm, asObject(this));
    const h = try newHelper(vm, .drop, rec, Value.undefined_);
    hd(h).remaining = limit;
    return h.asValue();
}

fn flatMap(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const rec = try thisRecord(vm, this, arg(args, 0), "Iterator.prototype.flatMap");
    return (try newHelper(vm, .flat_map, rec, arg(args, 0))).asValue();
}

/// A chunk or window size: an integral Number (no coercion) in
/// [1, 2^32 - 1].
fn sizeOf(vm: *Vm, rec: IteratorRecord, v: Value) Error!f64 {
    if (!v.isNumber()) return closeThrow(vm, rec, vm.throwTypeError("The size must be a Number"));
    const n = v.asNumber();
    if (!std.math.isFinite(n) or n != @trunc(n)) return closeThrow(vm, rec, vm.throwTypeError("The size must be an integral Number"));
    if (n < 1 or n > 4294967295.0) return closeThrow(vm, rec, vm.throwRangeError("The size must be a positive integer below 2^32"));
    return n;
}

fn chunks(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype.chunks called on non-object");
    const pre = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
    const size = try sizeOf(vm, pre, arg(args, 0));
    const rec = try getIteratorDirect(vm, asObject(this));
    const h = try newHelper(vm, .chunks, rec, Value.undefined_);
    hd(h).remaining = size;
    hd(h).inner = (try vm.newArray(0)).asValue();
    return h.asValue();
}

fn windows(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype.windows called on non-object");
    const pre = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
    const size = try sizeOf(vm, pre, arg(args, 0));
    // undersized: "only-full" (the default) or "allow-partial".
    var allow_partial = false;
    const u = arg(args, 1);
    if (!u.isUndefined()) {
        var buf: [16]u8 = undefined;
        const text = if (u.isString()) b.utf8Buf(vm, asString(u), &buf) catch "" else "";
        if (std.mem.eql(u8, text, "allow-partial")) {
            allow_partial = true;
        } else if (!std.mem.eql(u8, text, "only-full")) return closeThrow(vm, pre, vm.throwTypeError("undersized must be 'only-full' or 'allow-partial'"));
    }
    const rec = try getIteratorDirect(vm, asObject(this));
    const h = try newHelper(vm, .windows, rec, Value.undefined_);
    hd(h).remaining = size;
    hd(h).inner = (try vm.newArray(0)).asValue();
    hd(h).mode = if (allow_partial) .longest else .shortest;
    return h.asValue();
}

// ------------------------------------------------- the eager methods

fn reduce(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var rec = try thisRecord(vm, this, arg(args, 0), "Iterator.prototype.reduce");
    const reducer = arg(args, 0);
    var acc: Value = undefined;
    var counter: f64 = 0;
    if (args.len < 2) {
        acc = (try vm.iteratorStepValue(&rec)) orelse return vm.throwTypeError("Reduce of empty iterator with no initial value");
        counter = 1;
    } else acc = args[1];
    while (try vm.iteratorStepValue(&rec)) |v| {
        acc = vm.call(reducer, Value.undefined_, &.{ acc, v, Value.fromF64(counter) }) catch |e| return closeThrow(vm, rec, e);
        counter += 1;
    }
    return acc;
}

fn toArray(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    var rec = try thisRecord(vm, this, null, "Iterator.prototype.toArray");
    const a = try vm.newArray(0);
    while (try vm.iteratorStepValue(&rec)) |v| try vm.arrayPush(a, v);
    return a.asValue();
}

fn forEach(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    var rec = try thisRecord(vm, this, arg(args, 0), "Iterator.prototype.forEach");
    var counter: f64 = 0;
    while (try vm.iteratorStepValue(&rec)) |v| {
        _ = vm.call(arg(args, 0), Value.undefined_, &.{ v, Value.fromF64(counter) }) catch |e| return closeThrow(vm, rec, e);
        counter += 1;
    }
    return Value.undefined_;
}

fn searchImpl(vm: *Vm, this: Value, args: []const Value, what: []const u8, comptime want: enum { some, every, find }) Error!Value {
    var rec = try thisRecord(vm, this, arg(args, 0), what);
    var counter: f64 = 0;
    while (try vm.iteratorStepValue(&rec)) |v| {
        const r = vm.call(arg(args, 0), Value.undefined_, &.{ v, Value.fromF64(counter) }) catch |e| return closeThrow(vm, rec, e);
        counter += 1;
        const truthy = vm.toBoolean(r);
        switch (want) {
            .some => if (truthy) {
                try vm.iteratorClose(rec);
                return Value.true_;
            },
            .every => if (!truthy) {
                try vm.iteratorClose(rec);
                return Value.false_;
            },
            .find => if (truthy) {
                try vm.iteratorClose(rec);
                return v;
            },
        }
    }
    return switch (want) {
        .some => Value.false_,
        .every => Value.true_,
        .find => Value.undefined_,
    };
}

fn some(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return searchImpl(vm, this, args, "Iterator.prototype.some", .some);
}
fn every(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return searchImpl(vm, this, args, "Iterator.prototype.every", .every);
}
fn find(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return searchImpl(vm, this, args, "Iterator.prototype.find", .find);
}

fn includes(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype.includes called on non-object");
    const pre = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
    // skippedElements: an integral Number or an infinity, not negative,
    // not beyond 2^53 - 1; no coercion.
    var to_skip: f64 = 0;
    const sk = arg(args, 1);
    if (!sk.isUndefined()) {
        if (!sk.isNumber()) return closeThrow(vm, pre, vm.throwTypeError("skippedElements must be a Number"));
        const n = sk.asNumber();
        if (std.math.isNan(n) or (std.math.isFinite(n) and n != @trunc(n))) return closeThrow(vm, pre, vm.throwTypeError("skippedElements must be an integral Number"));
        if (n < 0) return closeThrow(vm, pre, vm.throwRangeError("skippedElements must not be negative"));
        if (std.math.isFinite(n) and n > 9007199254740991.0) return closeThrow(vm, pre, vm.throwRangeError("skippedElements is too large"));
        to_skip = n;
    }
    var rec = try getIteratorDirect(vm, asObject(this));
    var skipped: f64 = 0;
    while (try vm.iteratorStepValue(&rec)) |v| {
        if (skipped < to_skip) {
            skipped += 1;
            continue;
        }
        if (vm.sameValueZero(v, arg(args, 0))) {
            try vm.iteratorClose(rec);
            return Value.true_;
        }
    }
    return Value.false_;
}

fn join(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype.join called on non-object");
    const pre = IteratorRecord{ .iterator = this, .next = Value.undefined_ };
    const sep_arg = arg(args, 0);
    const sep = if (sep_arg.isUndefined()) try vm.atom(",") else vm.toString(sep_arg) catch |e| return closeThrow(vm, pre, e);
    var rec = try getIteratorDirect(vm, asObject(this));
    var out: std.ArrayList(u16) = .empty;
    defer out.deinit(vm.meta);
    var first = true;
    while (try vm.iteratorStepValue(&rec)) |v| {
        if (!first) try appendUnits(vm, &out, sep);
        first = false;
        if (v.isNullish()) continue;
        const s = vm.toString(v) catch |e| return closeThrow(vm, rec, e);
        try appendUnits(vm, &out, s);
    }
    return strValue(try vm.strings.fromUnits(out.items));
}

fn appendUnits(vm: *Vm, out: *std.ArrayList(u16), s: *b.String) Error!void {
    const flat = try vm.strings.flatten(s);
    var i: u32 = 0;
    while (i < flat.len) : (i += 1) try out.append(vm.meta, flat.unitAt(i));
}

fn dispose(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Iterator.prototype[Symbol.dispose] called on non-object");
    const ret = try vm.getMethod(this, .{ .atom = try vm.atom("return") });
    if (!ret.isUndefined()) _ = try vm.call(ret, this, &.{});
    return Value.undefined_;
}

// ------------------------------------------------------ Iterator.concat

fn concat(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const list = try vm.newArray(0);
    for (args) |item| {
        if (!item.isObject()) return vm.throwTypeError("Iterator.concat: argument is not an object");
        const method = try vm.getMethod(item, .{ .symbol = vm.symbols.iterator });
        if (method.isUndefined()) return vm.throwTypeError("Iterator.concat: argument is not iterable");
        try vm.arrayPush(list, method);
        try vm.arrayPush(list, item);
    }
    const h = try newHelper(vm, .concat, .{ .iterator = Value.undefined_, .next = Value.undefined_ }, Value.undefined_);
    hd(h).inner = list.asValue();
    return h.asValue();
}

fn concatStep(vm: *Vm, d: *HelperData) Error!?Value {
    const list = asObject(d.inner);
    while (true) {
        if (d.inner_alive) {
            var rec = underlying(d);
            if (try vm.iteratorStepValue(&rec)) |v| return v;
            d.inner_alive = false;
            d.target = Value.undefined_;
            d.extra = Value.undefined_;
        }
        const n = Vm.arrayLength(list);
        if (d.position * 2 >= n) return null;
        const items = list.elements.?.items();
        const method = items[d.position * 2];
        const iterable = items[d.position * 2 + 1];
        d.position += 1;
        const it = try vm.call(method, iterable, &.{});
        if (!it.isObject()) return vm.throwTypeError("Iterator.concat: the iterator is not an object");
        const rec = try getIteratorDirect(vm, asObject(it));
        d.target = rec.iterator;
        d.extra = rec.next;
        d.inner_alive = true;
    }
}

// --------------------------------------------------------- Iterator.zip

/// The options of zip/zipKeyed: the mode and, for `longest`, padding.
const ZipOptions = struct { mode: Mode, padding: Value };

fn zipOptions(vm: *Vm, options: Value) Error!ZipOptions {
    var mode: Mode = .shortest;
    var padding: Value = Value.undefined_;
    if (!options.isUndefined()) {
        if (!options.isObject()) return vm.throwTypeError("Iterator.zip: options must be an object");
        const o = asObject(options);
        const m = try vm.get(o, .{ .atom = try vm.atom("mode") }, options);
        if (!m.isUndefined()) {
            if (!m.isString()) return vm.throwTypeError("Iterator.zip: mode must be a string");
            var buf: [16]u8 = undefined;
            const text = b.utf8Buf(vm, asString(m), &buf) catch "";
            if (std.mem.eql(u8, text, "shortest")) {
                mode = .shortest;
            } else if (std.mem.eql(u8, text, "longest")) {
                mode = .longest;
            } else if (std.mem.eql(u8, text, "strict")) {
                mode = .strict;
            } else return vm.throwTypeError("Iterator.zip: mode must be 'shortest', 'longest' or 'strict'");
        }
        if (mode == .longest) {
            padding = try vm.get(o, .{ .atom = try vm.atom("padding") }, options);
            if (!padding.isUndefined() and !padding.isObject()) return vm.throwTypeError("Iterator.zip: padding must be an object");
        }
    }
    return .{ .mode = mode, .padding = padding };
}

/// IteratorCloseAll over the open iterators, in reverse; a pending
/// throw completion is kept, a normal one becomes the first throw.
fn closeAll(vm: *Vm, d: *HelperData, pending: ?Error) Error!void {
    const iters = asObject(d.inner);
    const nexts = asObject(d.inner_next);
    const n = Vm.arrayLength(iters);
    var err: ?Error = pending;
    var i = n;
    while (i > 0) : (i -= 1) {
        const it = iters.elements.?.items()[i - 1];
        if (it.isNull()) continue;
        iters.elements.?.items()[i - 1] = Value.null_;
        const rec = IteratorRecord{ .iterator = it, .next = nexts.elements.?.items()[i - 1] };
        if (err) |_| {
            vm.iteratorCloseThrow(rec);
        } else {
            vm.iteratorClose(rec) catch |e| {
                err = e;
            };
        }
    }
    if (err) |e| return e;
}

/// closeAll with a throw completion in flight: that error propagates.
fn closeAllErr(vm: *Vm, d: *HelperData, e: Error) Error {
    closeAll(vm, d, e) catch |err| return err;
    return e;
}

fn zipCommon(vm: *Vm, iters: *Object, nexts: *Object, padding: *Object, keys: Value, mode: Mode) Error!Value {
    const h = try newHelper(vm, .zip, .{ .iterator = Value.undefined_, .next = Value.undefined_ }, keys);
    const d = hd(h);
    d.inner = iters.asValue();
    d.inner_next = nexts.asValue();
    d.aux = padding.asValue();
    d.mode = mode;
    d.remaining = @floatFromInt(Vm.arrayLength(iters)); // the count still open
    return h.asValue();
}

/// Close the iterators opened so far when opening another fails (a
/// throw completion is in flight, so their errors are dropped).
fn closeOpened(vm: *Vm, iters: *Object, nexts: *Object) void {
    var i = Vm.arrayLength(iters);
    while (i > 0) : (i -= 1) {
        const it = iters.elements.?.items()[i - 1];
        if (it.isNull()) continue;
        vm.iteratorCloseThrow(.{ .iterator = it, .next = nexts.elements.?.items()[i - 1] });
    }
}

fn zip(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const iterables = arg(args, 0);
    if (!iterables.isObject()) return vm.throwTypeError("Iterator.zip: iterables must be an object");
    const opts = try zipOptions(vm, arg(args, 1));
    const iters = try vm.newArray(0);
    const nexts = try vm.newArray(0);
    var input = try vm.getIterator(iterables);
    while (true) {
        const next = vm.iteratorStepValue(&input) catch |e| {
            closeOpened(vm, iters, nexts);
            return e;
        };
        const v = next orelse break;
        const rec = getIteratorFlattenable(vm, v, false) catch |e| {
            // IteratorCloseAll over « inputIter » ++ iters, in reverse.
            closeOpened(vm, iters, nexts);
            vm.iteratorCloseThrow(input);
            return e;
        };
        try vm.arrayPush(iters, rec.iterator);
        try vm.arrayPush(nexts, rec.next);
    }
    const padding = try vm.newArray(0);
    const count = Vm.arrayLength(iters);
    if (opts.mode == .longest) {
        if (!opts.padding.isUndefined()) {
            var pad_it = vm.getIterator(opts.padding) catch |e| {
                closeOpened(vm, iters, nexts);
                return e;
            };
            var using = true;
            var i: u32 = 0;
            while (i < count) : (i += 1) {
                var v: Value = Value.undefined_;
                if (using) {
                    const r = vm.iteratorStepValue(&pad_it) catch |e| {
                        closeOpened(vm, iters, nexts);
                        return e;
                    };
                    if (r) |pv| v = pv else using = false;
                }
                try vm.arrayPush(padding, v);
            }
            if (using) vm.iteratorClose(pad_it) catch |e| {
                closeOpened(vm, iters, nexts);
                return e;
            };
        }
    }
    while (Vm.arrayLength(padding) < count) try vm.arrayPush(padding, Value.undefined_);
    return zipCommon(vm, iters, nexts, padding, Value.undefined_, opts.mode);
}

fn zipKeyed(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const iterables = arg(args, 0);
    if (!iterables.isObject()) return vm.throwTypeError("Iterator.zipKeyed: iterables must be an object");
    const o = asObject(iterables);
    const opts = try zipOptions(vm, arg(args, 1));
    var all_keys: std.ArrayList(Key) = .empty;
    defer all_keys.deinit(vm.meta);
    try vm.ownPropertyKeys(o, &all_keys);
    const keys = try vm.newArray(0);
    const iters = try vm.newArray(0);
    const nexts = try vm.newArray(0);
    for (all_keys.items) |k| {
        const desc = vm.getOwnProperty(o, k) catch |e| {
            closeOpened(vm, iters, nexts);
            return e;
        };
        if (desc == null or !desc.?.attrs.enumerable) continue;
        const v = vm.get(o, k, iterables) catch |e| {
            closeOpened(vm, iters, nexts);
            return e;
        };
        if (v.isUndefined()) continue;
        const rec = getIteratorFlattenable(vm, v, false) catch |e| {
            closeOpened(vm, iters, nexts);
            return e;
        };
        try vm.arrayPush(keys, try vm.keyToValue(k));
        try vm.arrayPush(iters, rec.iterator);
        try vm.arrayPush(nexts, rec.next);
    }
    const padding = try vm.newArray(0);
    const count = Vm.arrayLength(iters);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        var v: Value = Value.undefined_;
        if (opts.mode == .longest and !opts.padding.isUndefined()) {
            const k = try vm.toPropertyKey(keys.elements.?.items()[i]);
            v = vm.get(asObject(opts.padding), k, opts.padding) catch |e| {
                closeOpened(vm, iters, nexts);
                return e;
            };
        }
        try vm.arrayPush(padding, v);
    }
    return zipCommon(vm, iters, nexts, padding, keys.asValue(), opts.mode);
}

fn zipStep(vm: *Vm, d: *HelperData) Error!?Value {
    const iters = asObject(d.inner);
    const nexts = asObject(d.inner_next);
    const padding = asObject(d.aux);
    const count = Vm.arrayLength(iters);
    if (count == 0) return null;
    var results: std.ArrayList(Value) = .empty;
    defer results.deinit(vm.meta);
    var i: u32 = 0;
    while (i < count) : (i += 1) {
        const it = iters.elements.?.items()[i];
        var result: Value = undefined;
        if (it.isNull()) {
            result = padding.elements.?.items()[i];
        } else {
            var rec = IteratorRecord{ .iterator = it, .next = nexts.elements.?.items()[i] };
            const r = vm.iteratorStepValue(&rec) catch |e| {
                iters.elements.?.items()[i] = Value.null_;
                return closeAllErr(vm, d, e);
            };
            if (r) |v| {
                result = v;
            } else {
                iters.elements.?.items()[i] = Value.null_;
                switch (d.mode) {
                    .shortest => {
                        try closeAll(vm, d, null);
                        return null;
                    },
                    .strict => {
                        if (i != 0) return closeAllErr(vm, d, vm.throwTypeError("Iterator.zip: iterators have different lengths"));
                        var k: u32 = 1;
                        while (k < count) : (k += 1) {
                            var other = IteratorRecord{ .iterator = iters.elements.?.items()[k], .next = nexts.elements.?.items()[k] };
                            const open = vm.iteratorStepValue(&other) catch |e| {
                                iters.elements.?.items()[k] = Value.null_;
                                return closeAllErr(vm, d, e);
                            };
                            if (open != null) return closeAllErr(vm, d, vm.throwTypeError("Iterator.zip: iterators have different lengths"));
                            iters.elements.?.items()[k] = Value.null_;
                        }
                        return null;
                    },
                    .longest => {
                        var any_open = false;
                        for (iters.elements.?.items()[0..count]) |x| if (!x.isNull()) {
                            any_open = true;
                        };
                        if (!any_open) return null;
                        result = padding.elements.?.items()[i];
                    },
                }
            }
        }
        try results.append(vm.meta, result);
    }
    // finishResults: an array for zip, an object for zipKeyed.
    if (d.func.isUndefined()) return (try vm.arrayFromList(results.items)).asValue();
    const keys = asObject(d.func);
    const out = try vm.objects.create(Value.null_, .ordinary, 0);
    for (results.items, 0..) |v, n| {
        const k = try vm.toPropertyKey(keys.elements.?.items()[n]);
        try vm.createDataPropertyOrThrow(out, k, v);
    }
    return out.asValue();
}
