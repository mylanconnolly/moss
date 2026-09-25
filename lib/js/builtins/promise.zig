//! Promise (§27.2): states, reactions as records in arrays, jobs on
//! the VM's queue as native functions closing over their record, and
//! the constructor's combinators.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const strValue = b.strValue;
const arg = b.arg;
const PromiseData = vmod.PromiseData;

pub const Capability = struct { promise: Value, resolve: Value, reject: Value };

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.promise_prototype;
    const ctor = try b.installConstructor(vm, "Promise", 1, construct, proto);
    vm.intrinsics.promise_ctor = ctor;
    _ = try vm.defineNative(ctor, "all", 1, all);
    _ = try vm.defineNative(ctor, "allSettled", 1, allSettled);
    _ = try vm.defineNative(ctor, "any", 1, any);
    _ = try vm.defineNative(ctor, "race", 1, race);
    _ = try vm.defineNative(ctor, "reject", 1, reject);
    _ = try vm.defineNative(ctor, "resolve", 1, resolve);
    _ = try vm.defineNative(ctor, "withResolvers", 0, withResolvers);
    _ = try vm.defineNative(ctor, "try", 1, tryFn);
    const species = try vm.newNative("get [Symbol.species]", 0, speciesGetter, Value.undefined_);
    try vm.defineAccessor(ctor, .{ .symbol = vm.symbols.species }, species, null, .{ .enumerable = false, .configurable = true });
    _ = try vm.defineNative(proto, "catch", 1, catchFn);
    _ = try vm.defineNative(proto, "finally", 1, finallyFn);
    _ = try vm.defineNative(proto, "then", 2, then);
    try b.setToStringTag(vm, proto, "Promise");
}

fn speciesGetter(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

pub fn isPromise(v: Value) bool {
    return v.isObject() and asObject(v).class == .promise;
}

fn data(v: Value) *PromiseData {
    return asObject(v).internal(PromiseData);
}

/// A pending promise with the given prototype.
fn newPromiseObject(vm: *Vm, proto: *Object) Error!*Object {
    const o = try vm.objects.create(proto.asValue(), .promise, @sizeOf(PromiseData));
    o.internal(PromiseData).* = .{ .state = 0, .is_handled = false, .result = Value.undefined_, .fulfill_reactions = (try vm.newArray(0)).asValue(), .reject_reactions = (try vm.newArray(0)).asValue() };
    return o;
}

/// CreateResolvingFunctions: a pair sharing an "already resolved" flag
/// (index 1 of their record).
fn resolvingFunctions(vm: *Vm, promise: Value) Error!struct { resolve: Value, reject: Value } {
    const record = try vm.arrayFromList(&.{ promise, Value.false_ });
    const res = try vm.newNative("", 1, resolveFunction, record.asValue());
    const rej = try vm.newNative("", 1, rejectFunction, record.asValue());
    return .{ .resolve = res.asValue(), .reject = rej.asValue() };
}

fn recordOf(vm: *Vm, args_fn: Value) *Object {
    _ = vm;
    return asObject(asObject(args_fn).internal(vmod.FunctionData).data);
}

fn resolveFunction(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const record = asObject(f.internal(vmod.FunctionData).data);
    const items = record.elements.?.items();
    if (items[1].asBool()) return Value.undefined_;
    items[1] = Value.true_;
    const promise = items[0];
    try resolvePromise(vm, promise, arg(args, 0));
    return Value.undefined_;
}

fn rejectFunction(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const record = asObject(f.internal(vmod.FunctionData).data);
    const items = record.elements.?.items();
    if (items[1].asBool()) return Value.undefined_;
    items[1] = Value.true_;
    try rejectPromise(vm, items[0], arg(args, 0));
    return Value.undefined_;
}

/// The resolve function's body (§27.2.1.3.2 steps 7–16).
pub fn resolvePromise(vm: *Vm, promise: Value, resolution: Value) Error!void {
    if (resolution.eqlBits(promise)) {
        const e = try vm.newError(.TypeError, "Chaining cycle detected for promise");
        return rejectPromise(vm, promise, e.asValue());
    }
    if (!resolution.isObject()) return fulfillPromise(vm, promise, resolution);
    const then_v = vm.get(asObject(resolution), .{ .atom = vm.atoms.then }, resolution) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            return rejectPromise(vm, promise, ex);
        },
        else => return e,
    };
    if (!vm.isCallable(then_v)) return fulfillPromise(vm, promise, resolution);
    // NewPromiseResolveThenableJob.
    const record = try vm.arrayFromList(&.{ promise, resolution, then_v });
    const job = try vm.newNative("", 0, thenableJob, record.asValue());
    try vm.jobs.append(vm.meta, .{ .func = job.asValue(), .args = .{ Value.undefined_, Value.undefined_, Value.undefined_ }, .argc = 0 });
}

fn thenableJob(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const record = asObject(f.internal(vmod.FunctionData).data);
    const items = record.elements.?.items();
    const promise = items[0];
    const fns = try resolvingFunctions(vm, promise);
    _ = vm.call(items[2], items[1], &.{ fns.resolve, fns.reject }) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(fns.reject, Value.undefined_, &.{ex});
        },
        else => return e,
    };
    return Value.undefined_;
}

fn fulfillPromise(vm: *Vm, promise: Value, value: Value) Error!void {
    const d = data(promise);
    const reactions = d.fulfill_reactions;
    d.result = value;
    d.fulfill_reactions = Value.undefined_;
    d.reject_reactions = Value.undefined_;
    d.state = 1;
    try triggerReactions(vm, reactions, value);
}

pub fn rejectPromise(vm: *Vm, promise: Value, reason: Value) Error!void {
    const d = data(promise);
    const reactions = d.reject_reactions;
    d.result = reason;
    d.fulfill_reactions = Value.undefined_;
    d.reject_reactions = Value.undefined_;
    d.state = 2;
    try triggerReactions(vm, reactions, reason);
}

fn triggerReactions(vm: *Vm, reactions: Value, argument: Value) Error!void {
    if (!reactions.isObject()) return;
    const arr = asObject(reactions);
    const n = Vm.arrayLength(arr);
    var i: u32 = 0;
    while (i < n) : (i += 1) try enqueueReactionJob(vm, arr.elements.?.items()[i], argument);
}

/// A reaction record: [capability promise (or undefined), resolve,
/// reject, type (0 fulfill / 1 reject), handler].
fn newReaction(vm: *Vm, cap: ?Capability, kind: u8, handler: Value) Error!Value {
    const rec = try vm.arrayFromList(&.{ if (cap) |c| c.promise else Value.undefined_, if (cap) |c| c.resolve else Value.undefined_, if (cap) |c| c.reject else Value.undefined_, Value.fromInt(kind), handler });
    return rec.asValue();
}

fn enqueueReactionJob(vm: *Vm, reaction: Value, argument: Value) Error!void {
    const job = try vm.newNative("", 1, reactionJob, reaction);
    try vm.jobs.append(vm.meta, .{ .func = job.asValue(), .args = .{ argument, Value.undefined_, Value.undefined_ }, .argc = 1 });
}

/// NewPromiseReactionJob's body.
fn reactionJob(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const rec = asObject(f.internal(vmod.FunctionData).data).elements.?.items();
    const cap_promise = rec[0];
    const handler = rec[4];
    const kind = rec[3].asInt();
    const argument = arg(args, 0);
    var result: Value = undefined;
    var is_abrupt = false;
    if (handler.isUndefined()) {
        result = argument;
        is_abrupt = kind == 1;
    } else {
        result = vm.call(handler, Value.undefined_, &.{argument}) catch |e| switch (e) {
            error.Exception => blk: {
                is_abrupt = true;
                const ex = vm.exception;
                vm.exception = Value.undefined_;
                break :blk ex;
            },
            else => return e,
        };
    }
    if (cap_promise.isUndefined()) return Value.undefined_;
    _ = try vm.call(if (is_abrupt) rec[2] else rec[1], Value.undefined_, &.{result});
    return Value.undefined_;
}

/// NewPromiseCapability(C) (§27.2.1.5).
pub fn newCapability(vm: *Vm, c: Value) Error!Capability {
    if (c.eqlBits(vm.intrinsics.promise_ctor.asValue())) {
        const p = try newPromiseObject(vm, vm.intrinsics.promise_prototype);
        const fns = try resolvingFunctions(vm, p.asValue());
        return .{ .promise = p.asValue(), .resolve = fns.resolve, .reject = fns.reject };
    }
    if (!vm.isConstructor(c)) return vm.throwTypeError("Promise capability constructor is not a constructor");
    // The executor stores its resolve/reject into a record.
    const record = try vm.arrayFromList(&.{ Value.undefined_, Value.undefined_ });
    const executor = try vm.newNative("", 2, capabilityExecutor, record.asValue());
    const promise = try vm.construct(c, &.{executor.asValue()}, c);
    const items = record.elements.?.items();
    if (!vm.isCallable(items[0])) return vm.throwTypeError("Promise resolve function is not callable");
    if (!vm.isCallable(items[1])) return vm.throwTypeError("Promise reject function is not callable");
    return .{ .promise = promise, .resolve = items[0], .reject = items[1] };
}

fn capabilityExecutor(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const items = asObject(f.internal(vmod.FunctionData).data).elements.?.items();
    if (!items[0].isUndefined()) return vm.throwTypeError("Promise executor has already been invoked with non-undefined arguments");
    if (!items[1].isUndefined()) return vm.throwTypeError("Promise executor has already been invoked with non-undefined arguments");
    items[0] = arg(args, 0);
    items[1] = arg(args, 1);
    return Value.undefined_;
}

/// PromiseResolve(C, x) (§27.2.4.7.1).
pub fn promiseResolve(vm: *Vm, c: Value, x: Value) Error!Value {
    if (isPromise(x)) {
        const xc = try vm.get(asObject(x), .{ .atom = vm.atoms.constructor }, x);
        if (xc.eqlBits(c)) return x;
    }
    const cap = try newCapability(vm, c);
    _ = try vm.call(cap.resolve, Value.undefined_, &.{x});
    return cap.promise;
}

/// PerformPromiseThen (§27.2.5.4.1).
pub fn performThen(vm: *Vm, promise: Value, on_fulfilled: Value, on_rejected: Value, cap: ?Capability) Error!Value {
    const d = data(promise);
    const f = if (vm.isCallable(on_fulfilled)) on_fulfilled else Value.undefined_;
    const r = if (vm.isCallable(on_rejected)) on_rejected else Value.undefined_;
    const fr = try newReaction(vm, cap, 0, f);
    const rr = try newReaction(vm, cap, 1, r);
    switch (d.state) {
        0 => {
            try vm.arrayPush(asObject(d.fulfill_reactions), fr);
            try vm.arrayPush(asObject(d.reject_reactions), rr);
        },
        1 => try enqueueReactionJob(vm, fr, d.result),
        else => try enqueueReactionJob(vm, rr, d.result),
    }
    d.is_handled = true;
    return if (cap) |c| c.promise else Value.undefined_;
}

// ------------------------------------------------------ constructor

fn construct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Promise constructor cannot be invoked without 'new'");
    const executor = arg(args, 0);
    if (!vm.isCallable(executor)) return vm.throwTypeError("Promise resolver is not a function");
    const proto = try vm.prototypeFromConstructor(new_target, vm.intrinsics.promise_prototype);
    const p = try newPromiseObject(vm, proto);
    const fns = try resolvingFunctions(vm, p.asValue());
    _ = vm.call(executor, Value.undefined_, &.{ fns.resolve, fns.reject }) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(fns.reject, Value.undefined_, &.{ex});
        },
        else => return e,
    };
    return p.asValue();
}

fn thisPromise(vm: *Vm, this: Value) Error!Value {
    if (!isPromise(this)) return vm.throwTypeError("Promise.prototype method called on incompatible receiver");
    return this;
}

fn then(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const p = try thisPromise(vm, this);
    const c = try vm.speciesConstructor(asObject(p), vm.intrinsics.promise_ctor.asValue());
    const cap = try newCapability(vm, c);
    return performThen(vm, p, arg(args, 0), arg(args, 1), cap);
}

fn catchFn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return vm.invoke(this, .{ .atom = vm.atoms.then }, &.{ Value.undefined_, arg(args, 0) });
}

fn finallyFn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Promise.prototype.finally called on non-object");
    const c = try vm.speciesConstructor(asObject(this), vm.intrinsics.promise_ctor.asValue());
    const on_finally = arg(args, 0);
    if (!vm.isCallable(on_finally)) return vm.invoke(this, .{ .atom = vm.atoms.then }, &.{ on_finally, on_finally });
    const record = try vm.arrayFromList(&.{ c, on_finally });
    const then_finally = try vm.newNative("", 1, thenFinally, record.asValue());
    const catch_finally = try vm.newNative("", 1, catchFinally, record.asValue());
    return vm.invoke(this, .{ .atom = vm.atoms.then }, &.{ then_finally.asValue(), catch_finally.asValue() });
}

fn thenFinally(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const rec = asObject(f.internal(vmod.FunctionData).data).elements.?.items();
    const result = try vm.call(rec[1], Value.undefined_, &.{});
    const p = try promiseResolve(vm, rec[0], result);
    const value_thunk = try vm.newNative("", 0, returnData, arg(args, 0));
    return vm.invoke(p, .{ .atom = vm.atoms.then }, &.{value_thunk.asValue()});
}

fn catchFinally(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const rec = asObject(f.internal(vmod.FunctionData).data).elements.?.items();
    const result = try vm.call(rec[1], Value.undefined_, &.{});
    const p = try promiseResolve(vm, rec[0], result);
    const thrower = try vm.newNative("", 0, throwData, arg(args, 0));
    return vm.invoke(p, .{ .atom = vm.atoms.then }, &.{thrower.asValue()});
}

fn returnData(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    return f.internal(vmod.FunctionData).data;
}

fn throwData(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    return vm.throwValue(f.internal(vmod.FunctionData).data);
}

// ------------------------------------------------------- statics

fn resolve(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Promise.resolve called on non-object");
    return promiseResolve(vm, this, arg(args, 0));
}

fn reject(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const cap = try newCapability(vm, this);
    _ = try vm.call(cap.reject, Value.undefined_, &.{arg(args, 0)});
    return cap.promise;
}

/// Promise.try (ES2025): call the function, settling with its outcome.
fn tryFn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Promise.try called on non-object");
    const cap = try newCapability(vm, this);
    const r = vm.call(arg(args, 0), Value.undefined_, if (args.len > 1) args[1..] else &.{}) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    _ = try vm.call(cap.resolve, Value.undefined_, &.{r});
    return cap.promise;
}

fn withResolvers(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const cap = try newCapability(vm, this);
    const o = try vm.newObject();
    try vm.defineValue(o, "promise", cap.promise, .default);
    try vm.defineValue(o, "resolve", cap.resolve, .default);
    try vm.defineValue(o, "reject", cap.reject, .default);
    return o.asValue();
}

/// GetPromiseResolve: C.resolve, callable.
fn getResolve(vm: *Vm, c: Value) Error!Value {
    const r = try vm.get(asObject(c), .{ .atom = try vm.atom("resolve") }, c);
    if (!vm.isCallable(r)) return vm.throwTypeError("Promise resolve is not a function");
    return r;
}

const Combinator = enum { all, all_settled, any };

/// Promise.all / allSettled / any share the iteration: each element goes
/// through C.resolve, then `then` with element functions closing over a
/// shared record [values array, remaining count, capability resolve,
/// capability reject, index, already-called flag].
fn combinator(vm: *Vm, this: Value, iterable: Value, kind: Combinator) Error!Value {
    const c = this;
    const cap = try newCapability(vm, c);
    const body = combinatorBody(vm, c, iterable, cap, kind) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    _ = body;
    return cap.promise;
}

fn combinatorBody(vm: *Vm, c: Value, iterable: Value, cap: Capability, kind: Combinator) Error!void {
    const resolve_fn = try getResolve(vm, c);
    var rec = try vm.getIterator(iterable);
    const values = try vm.newArray(0);
    // shared: [values, remaining, cap.resolve, cap.reject]
    const shared = try vm.arrayFromList(&.{ values.asValue(), Value.fromInt(1), cap.resolve, cap.reject });
    var index: u32 = 0;
    while (true) {
        const next = vm.iteratorStepValue(&rec) catch |e| return e;
        const v = next orelse break;
        try vm.arrayPush(values, Value.undefined_);
        const next_promise = vm.call(resolve_fn, c, &.{v}) catch |e| {
            if (e == error.Exception and !rec.done) vm.iteratorCloseThrow(rec);
            return e;
        };
        // element record: [shared, index, already-called]
        const elem = try vm.arrayFromList(&.{ shared.asValue(), Value.fromInt(@intCast(index)), Value.false_ });
        shared.elements.?.items()[1] = Value.fromInt(shared.elements.?.items()[1].asInt() + 1);
        var on_f: Value = cap.resolve;
        var on_r: Value = cap.reject;
        switch (kind) {
            .all => on_f = (try vm.newNative("", 1, allResolveElement, elem.asValue())).asValue(),
            .all_settled => {
                on_f = (try vm.newNative("", 1, allSettledFulfilled, elem.asValue())).asValue();
                on_r = (try vm.newNative("", 1, allSettledRejected, elem.asValue())).asValue();
            },
            .any => on_r = (try vm.newNative("", 1, anyRejectElement, elem.asValue())).asValue(),
        }
        _ = vm.invoke(next_promise, .{ .atom = vm.atoms.then }, &.{ on_f, on_r }) catch |e| {
            if (e == error.Exception and !rec.done) vm.iteratorCloseThrow(rec);
            return e;
        };
        index += 1;
    }
    // The initial count.
    const items = shared.elements.?.items();
    items[1] = Value.fromInt(items[1].asInt() - 1);
    if (items[1].asInt() == 0) {
        if (kind == .any) {
            const errs = try vm.newError(.AggregateError, "All promises were rejected");
            _ = try vm.defineOwnProperty(errs, .{ .atom = vm.atoms.errors }, .{ .value = values.asValue(), .writable = true, .enumerable = false, .configurable = true }, true);
            _ = try vm.call(cap.reject, Value.undefined_, &.{errs.asValue()});
        } else {
            _ = try vm.call(cap.resolve, Value.undefined_, &.{values.asValue()});
        }
    }
}

/// Settle one element: store, decrement, resolve/reject when all done.
fn settleElement(vm: *Vm, elem: []Value, value: Value, reject_all: bool) Error!void {
    if (elem[2].asBool()) return;
    elem[2] = Value.true_;
    const shared = asObject(elem[0]).elements.?.items();
    const values = asObject(shared[0]);
    _ = try vm.createDataProperty(values, .{ .index = @intCast(elem[1].asInt()) }, value);
    shared[1] = Value.fromInt(shared[1].asInt() - 1);
    if (shared[1].asInt() == 0) {
        if (reject_all) {
            const errs = try vm.newError(.AggregateError, "All promises were rejected");
            _ = try vm.defineOwnProperty(errs, .{ .atom = vm.atoms.errors }, .{ .value = values.asValue(), .writable = true, .enumerable = false, .configurable = true }, true);
            _ = try vm.call(shared[3], Value.undefined_, &.{errs.asValue()});
        } else {
            _ = try vm.call(shared[2], Value.undefined_, &.{values.asValue()});
        }
    }
}

fn elemOf(vm: *Vm) ?[]Value {
    const f = vm.current_native orelse return null;
    return asObject(f.internal(vmod.FunctionData).data).elements.?.items();
}

fn allResolveElement(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const elem = elemOf(vm) orelse return Value.undefined_;
    try settleElement(vm, elem, arg(args, 0), false);
    return Value.undefined_;
}

fn allSettledFulfilled(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const elem = elemOf(vm) orelse return Value.undefined_;
    const o = try vm.newObject();
    try vm.defineValue(o, "status", try vm.str("fulfilled"), .default);
    try vm.defineValue(o, "value", arg(args, 0), .default);
    try settleElement(vm, elem, o.asValue(), false);
    return Value.undefined_;
}

fn allSettledRejected(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const elem = elemOf(vm) orelse return Value.undefined_;
    const o = try vm.newObject();
    try vm.defineValue(o, "status", try vm.str("rejected"), .default);
    try vm.defineValue(o, "reason", arg(args, 0), .default);
    try settleElement(vm, elem, o.asValue(), false);
    return Value.undefined_;
}

fn anyRejectElement(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const elem = elemOf(vm) orelse return Value.undefined_;
    try settleElement(vm, elem, arg(args, 0), true);
    return Value.undefined_;
}

fn all(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return combinator(vm, this, arg(args, 0), .all);
}
fn allSettled(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return combinator(vm, this, arg(args, 0), .all_settled);
}
fn any(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return combinator(vm, this, arg(args, 0), .any);
}

fn race(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const c = this;
    const cap = try newCapability(vm, c);
    raceBody(vm, c, arg(args, 0), cap) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
        },
        else => return e,
    };
    return cap.promise;
}

fn raceBody(vm: *Vm, c: Value, iterable: Value, cap: Capability) Error!void {
    const resolve_fn = try getResolve(vm, c);
    var rec = try vm.getIterator(iterable);
    while (try vm.iteratorStepValue(&rec)) |v| {
        const next_promise = vm.call(resolve_fn, c, &.{v}) catch |e| {
            if (e == error.Exception and !rec.done) vm.iteratorCloseThrow(rec);
            return e;
        };
        _ = vm.invoke(next_promise, .{ .atom = vm.atoms.then }, &.{ cap.resolve, cap.reject }) catch |e| {
            if (e == error.Exception and !rec.done) vm.iteratorCloseThrow(rec);
            return e;
        };
    }
}
