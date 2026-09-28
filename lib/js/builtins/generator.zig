//! Generators, async functions and async generators (§27.3–27.7) as
//! coroutines: a frame is copied to a `CoroutineData` cell on `yield`
//! or `await` and copied back on resumption, so the interpreter's
//! register window is the only stack a suspended body ever needs. An
//! async function's `await` resolves its operand to a promise and
//! continues in a reaction job; an async generator queues requests and
//! settles each one's promise as the body yields.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const bytecode = @import("../bytecode.zig");
const interp = @import("../interp.zig");
const heap = @import("../heap.zig");
const promise = @import("promise.zig");
const function = @import("function.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const strValue = b.strValue;
const arg = b.arg;
const Co = vmod.CoroutineData;
const FunctionData = vmod.FunctionData;

pub fn install(vm: *Vm) Error!void {
    const i = &vm.intrinsics;
    // Generator functions and generators.
    const gfp = i.generator_function_prototype;
    const gp = i.generator_prototype;
    i.generator_function = try vm.newNativeNamed(strValue(try vm.atom("GeneratorFunction")), 1, generatorFunctionCtor, Value.undefined_, true);
    _ = try vm.objects.setProto(i.generator_function, i.function_ctor.asValue());
    _ = try vm.objects.defineOwn(i.generator_function, .{ .atom = vm.atoms.prototype }, gfp.asValue(), .frozen);
    _ = try vm.objects.defineOwn(gfp, .{ .atom = vm.atoms.constructor }, i.generator_function.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try vm.objects.defineOwn(gfp, .{ .atom = vm.atoms.prototype }, gp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try vm.objects.defineOwn(gp, .{ .atom = vm.atoms.constructor }, gfp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    try b.setToStringTag(vm, gfp, "GeneratorFunction");
    try b.setToStringTag(vm, gp, "Generator");
    _ = try vm.defineNative(gp, "next", 1, generatorNext);
    _ = try vm.defineNative(gp, "return", 1, generatorReturn);
    _ = try vm.defineNative(gp, "throw", 1, generatorThrow);
    // Async functions.
    const afp = i.async_function_prototype;
    i.async_function = try vm.newNativeNamed(strValue(try vm.atom("AsyncFunction")), 1, asyncFunctionCtor, Value.undefined_, true);
    _ = try vm.objects.setProto(i.async_function, i.function_ctor.asValue());
    _ = try vm.objects.defineOwn(i.async_function, .{ .atom = vm.atoms.prototype }, afp.asValue(), .frozen);
    _ = try vm.objects.defineOwn(afp, .{ .atom = vm.atoms.constructor }, i.async_function.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    try b.setToStringTag(vm, afp, "AsyncFunction");
    // Async iterators and async generators.
    const aip = i.async_iterator_prototype;
    _ = try vm.defineNativeSymbol(aip, vm.symbols.async_iterator, "[Symbol.asyncIterator]", 0, returnThis);
    const afs = i.async_from_sync_iterator_prototype;
    _ = try vm.defineNative(afs, "next", 1, asyncFromSyncNext);
    _ = try vm.defineNative(afs, "return", 1, asyncFromSyncReturn);
    _ = try vm.defineNative(afs, "throw", 1, asyncFromSyncThrow);
    const agfp = i.async_generator_function_prototype;
    const agp = i.async_generator_prototype;
    i.async_generator_function = try vm.newNativeNamed(strValue(try vm.atom("AsyncGeneratorFunction")), 1, asyncGeneratorFunctionCtor, Value.undefined_, true);
    _ = try vm.objects.setProto(i.async_generator_function, i.function_ctor.asValue());
    _ = try vm.objects.defineOwn(i.async_generator_function, .{ .atom = vm.atoms.prototype }, agfp.asValue(), .frozen);
    _ = try vm.objects.defineOwn(agfp, .{ .atom = vm.atoms.constructor }, i.async_generator_function.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try vm.objects.defineOwn(agfp, .{ .atom = vm.atoms.prototype }, agp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    _ = try vm.objects.defineOwn(agp, .{ .atom = vm.atoms.constructor }, agfp.asValue(), .{ .writable = false, .enumerable = false, .configurable = true });
    try b.setToStringTag(vm, agfp, "AsyncGeneratorFunction");
    try b.setToStringTag(vm, agp, "AsyncGenerator");
    _ = try vm.defineNative(agp, "next", 1, asyncGeneratorNext);
    _ = try vm.defineNative(agp, "return", 1, asyncGeneratorReturn);
    _ = try vm.defineNative(agp, "throw", 1, asyncGeneratorThrow);
}

fn returnThis(_: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    return this;
}

fn generatorFunctionCtor(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    return function.createDynamicFunction(vm, args, .generator, new_target);
}
fn asyncFunctionCtor(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    return function.createDynamicFunction(vm, args, .async, new_target);
}
fn asyncGeneratorFunctionCtor(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    return function.createDynamicFunction(vm, args, .async_generator, new_target);
}

pub fn trace(o: *Object, m: *heap.Marker) void {
    _ = o;
    _ = m;
}
pub fn finalize(vm: *Vm, o: *Object) void {
    _ = vm;
    _ = o;
}

// ------------------------------------------------------- coroutines

fn coKind(kind: bytecode.FunctionKind) u8 {
    return switch (kind) {
        .generator => 0,
        .async_function, .async_arrow => 1,
        .async_generator => 2,
        else => 0,
    };
}

/// Call a generator, async function or async generator (§27.x: the
/// [[Call]] of each): run the frame as an entry frame with a coroutine
/// record attached; `genstart`, `yield` and `await` suspend it.
pub fn call(vm: *Vm, f: *Object, this: Value, args: []const Value) Error!Value {
    const fd = f.internal(FunctionData);
    const code = fd.code.?;
    try interp.ensureCompiled(vm, code, f);
    const kind = coKind(code.data.kind);
    // A generator's object is made by `genstart`, after its parameters
    // are bound (§27.5.3.1: the prototype is read then); an async
    // function's record and promise exist from the start.
    var co_obj: ?*Object = null;
    if (kind == 1) {
        co_obj = try newRecord(vm, f, vm.intrinsics.object_prototype, this);
        const co = co_obj.?.internal(Co);
        const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
        co.promise = cap.promise;
        co.resolve = cap.resolve;
        co.reject = cap.reject;
    }
    const coerced = try interp.coerceThisFor(vm, fd, this);
    const result = interp.runCoroutineStart(vm, code, f, coerced, fd.env, args, co_obj, false);
    switch (kind) {
        1 => {
            try settleAsync(vm, co_obj.?, result);
            return co_obj.?.internal(Co).promise;
        },
        else => return result, // the generator object `genstart` handed back
    }
}

fn newRecord(vm: *Vm, f: *Object, proto: *Object, this: Value) Error!*Object {
    const fd = f.internal(FunctionData);
    const code = fd.code.?;
    const co_obj = try vm.objects.create(proto.asValue(), .generator, @sizeOf(Co));
    const co = co_obj.internal(Co);
    co.* = .{
        .state = Co.executing,
        .kind = coKind(code.data.kind),
        .yield_raw = false,
        .code = code,
        .func = f,
        .this = this,
        .new_target = Value.undefined_,
        .env = fd.env,
        .pc = 0,
        .resume_reg = 0,
        .kind_reg = 0,
        .nregs = code.data.nregs,
        .nhandlers = 0,
        .regs = null,
        .handlers = null,
        .yielded = Value.undefined_,
        .promise = Value.undefined_,
        .resolve = Value.undefined_,
        .reject = Value.undefined_,
        .queue = Value.undefined_,
    };
    if (co.kind == 2) co.queue = (try vm.newArray(0)).asValue();
    return co_obj;
}

/// A module body's record: an async function's, with the module's
/// evaluation promise as its result.
pub fn newModuleRecord(vm: *Vm, code: *bytecode.Code, cap: promise.Capability) Error!*Object {
    const co_obj = try vm.objects.create(vm.intrinsics.object_prototype.asValue(), .generator, @sizeOf(Co));
    const co = co_obj.internal(Co);
    co.* = .{
        .state = Co.executing,
        .kind = 1,
        .yield_raw = false,
        .code = code,
        .func = null,
        .this = Value.undefined_,
        .new_target = Value.undefined_,
        .env = null,
        .pc = 0,
        .resume_reg = 0,
        .kind_reg = 0,
        .nregs = code.data.nregs,
        .nhandlers = 0,
        .regs = null,
        .handlers = null,
        .yielded = Value.undefined_,
        .promise = cap.promise,
        .resolve = cap.resolve,
        .reject = cap.reject,
        .queue = Value.undefined_,
    };
    return co_obj;
}

/// OrdinaryCreateFromConstructor for the generator object at `genstart`.
pub fn createGeneratorObject(vm: *Vm, f: *Object) Error!*Object {
    const fd = f.internal(FunctionData);
    const kind = coKind(fd.code.?.data.kind);
    const default = if (kind == 2) vm.intrinsics.async_generator_prototype else vm.intrinsics.generator_prototype;
    const p = try vm.get(f, .{ .atom = vm.atoms.prototype }, f.asValue());
    const proto = if (p.isObject()) asObject(p) else default;
    return newRecord(vm, f, proto, Value.undefined_);
}

/// Resume a suspended coroutine with `value` and a resumption kind
/// (0 next, 1 throw, 2 return): runs until the next suspension or the
/// end. The result is the returned value when it completed; the yielded
/// value is in the record when it suspended.
pub fn resumeCo(vm: *Vm, co_obj: *Object, value: Value, kind: u8) Error!Value {
    const co = co_obj.internal(Co);
    co.state = Co.executing;
    const r = interp.resumeCoroutine(vm, co_obj, value, kind) catch |e| {
        co.state = Co.completed;
        return e;
    };
    if (co.state == Co.executing) co.state = Co.completed;
    return r;
}

/// After an async function's body ran (from its call or a continuation):
/// settle its promise when the body finished.
pub fn settleAsync(vm: *Vm, co_obj: *Object, result: Error!Value) Error!void {
    const co = co_obj.internal(Co);
    if (result) |r| {
        if (co.state == Co.executing or co.state == Co.completed) {
            co.state = Co.completed;
            _ = try vm.call(co.resolve, Value.undefined_, &.{r});
        }
        // Suspended at an await: the continuation carries on.
    } else |e| switch (e) {
        error.Exception => {
            co.state = Co.completed;
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(co.reject, Value.undefined_, &.{ex});
        },
        else => return e,
    }
}

/// Await (§27.7.5.3): the interpreter has suspended the frame; resolve
/// `value` to a promise and continue in its reactions.
pub fn awaitValue(vm: *Vm, co_obj: *Object, p: Value) Error!void {
    const on_f = try vm.newNative("", 1, awaitFulfilled, co_obj.asValue());
    const on_r = try vm.newNative("", 1, awaitRejected, co_obj.asValue());
    _ = try promise.performThen(vm, p, on_f.asValue(), on_r.asValue(), null);
}

fn awaitFulfilled(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    try continueAfterAwait(vm, asObject(f.internal(FunctionData).data), arg(args, 0), 0);
    return Value.undefined_;
}

fn awaitRejected(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    try continueAfterAwait(vm, asObject(f.internal(FunctionData).data), arg(args, 0), 1);
    return Value.undefined_;
}

fn continueAfterAwait(vm: *Vm, co_obj: *Object, value: Value, kind: u8) Error!void {
    const co = co_obj.internal(Co);
    switch (co.kind) {
        1 => try settleAsync(vm, co_obj, resumeCo(vm, co_obj, value, kind)),
        2 => {
            const r = resumeCo(vm, co_obj, value, kind);
            try asyncGenAfterResume(vm, co_obj, r);
            try asyncGenResumeNext(vm, co_obj);
        },
        else => {},
    }
}

// --------------------------------------------- sync generator prototype

fn thisGenerator(vm: *Vm, this: Value, kind: u8) Error!*Object {
    if (!this.isObject() or asObject(this).class != .generator or asObject(this).internal(Co).kind != kind) return vm.throwTypeError("Generator method called on incompatible receiver");
    return asObject(this);
}

/// GeneratorResume / GeneratorResumeAbrupt (§27.5.3.3–4).
fn generatorResume(vm: *Vm, this: Value, value: Value, kind: u8) Error!Value {
    const co_obj = try thisGenerator(vm, this, 0);
    const co = co_obj.internal(Co);
    switch (co.state) {
        Co.executing => return vm.throwTypeError("Generator is already running"),
        Co.completed => {},
        Co.suspended_start => if (kind != 0) {
            co.state = Co.completed;
        },
        else => {},
    }
    if (co.state == Co.completed) {
        return switch (kind) {
            0 => vm.iterResult(Value.undefined_, true),
            1 => vm.throwValue(value),
            else => vm.iterResult(value, true),
        };
    }
    const r = try resumeCo(vm, co_obj, value, kind);
    if (co.state == Co.suspended_yield) {
        if (co.yield_raw) return co.yielded;
        return vm.iterResult(co.yielded, false);
    }
    return vm.iterResult(r, true);
}

fn generatorNext(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return generatorResume(vm, this, arg(args, 0), 0);
}
fn generatorReturn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return generatorResume(vm, this, arg(args, 0), 2);
}
fn generatorThrow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return generatorResume(vm, this, arg(args, 0), 1);
}

// ------------------------------------------------- async generators

/// A request record: [kind, value, promise, resolve, reject].
fn asyncGenEnqueue(vm: *Vm, this: Value, value: Value, kind: u8) Error!Value {
    const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    if (!this.isObject() or asObject(this).class != .generator or asObject(this).internal(Co).kind != 2) {
        const e = try vm.newError(.TypeError, "AsyncGenerator method called on incompatible receiver");
        _ = try vm.call(cap.reject, Value.undefined_, &.{e.asValue()});
        return cap.promise;
    }
    const co_obj = asObject(this);
    const co = co_obj.internal(Co);
    const rec = try vm.arrayFromList(&.{ Value.fromInt(kind), value, cap.promise, cap.resolve, cap.reject });
    try vm.arrayPush(asObject(co.queue), rec.asValue());
    if (co.state != Co.executing and co.state != Co.suspended_await and co.state != Co.awaiting_return) try asyncGenResumeNext(vm, co_obj);
    return cap.promise;
}

fn asyncGeneratorNext(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return asyncGenEnqueue(vm, this, arg(args, 0), 0);
}
fn asyncGeneratorReturn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return asyncGenEnqueue(vm, this, arg(args, 0), 2);
}
fn asyncGeneratorThrow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    return asyncGenEnqueue(vm, this, arg(args, 0), 1);
}

fn queueFront(co: *Co) ?[]Value {
    const q = asObject(co.queue);
    if (Vm.arrayLength(q) == 0) return null;
    return asObject(q.elements.?.items()[0]).elements.?.items();
}

fn dequeue(vm: *Vm, co: *Co) Error!void {
    const q = asObject(co.queue);
    const n = Vm.arrayLength(q);
    const items = q.elements.?.items();
    std.mem.copyForwards(Value, items[0 .. n - 1], items[1..n]);
    items[n - 1] = Value.empty;
    q.elements.?.len = n - 1;
    _ = vm;
}

/// Settle the front request: resolve with an iterator result, or reject.
fn settleFront(vm: *Vm, co: *Co, value: Value, done: bool, is_reject: bool) Error!void {
    const front = queueFront(co) orelse return;
    const resolve_fn = front[3];
    const reject_fn = front[4];
    try dequeue(vm, co);
    if (is_reject) {
        _ = try vm.call(reject_fn, Value.undefined_, &.{value});
    } else {
        _ = try vm.call(resolve_fn, Value.undefined_, &.{try vm.iterResult(value, done)});
    }
}

/// After a resumption of an async generator body returned to us: a
/// yield settles the front request, completion settles it with done,
/// an exception rejects it, an await leaves it pending.
fn asyncGenAfterResume(vm: *Vm, co_obj: *Object, result: Error!Value) Error!void {
    const co = co_obj.internal(Co);
    if (result) |r| {
        switch (co.state) {
            Co.suspended_yield => try settleFront(vm, co, co.yielded, false, false),
            Co.suspended_await => {},
            else => {
                co.state = Co.completed;
                try settleFront(vm, co, r, true, false);
            },
        }
    } else |e| switch (e) {
        error.Exception => {
            co.state = Co.completed;
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            try settleFront(vm, co, ex, false, true);
        },
        else => return e,
    }
}

/// AsyncGeneratorResumeNext / DrainQueue (§27.6.3.5–6).
fn asyncGenResumeNext(vm: *Vm, co_obj: *Object) Error!void {
    const co = co_obj.internal(Co);
    while (true) {
        if (co.state == Co.executing or co.state == Co.suspended_await or co.state == Co.awaiting_return) return;
        const front = queueFront(co) orelse return;
        const kind: u8 = @intCast(front[0].asInt());
        const value = front[1];
        if (co.state == Co.suspended_start and kind != 0) co.state = Co.completed;
        if (co.state == Co.completed) {
            switch (kind) {
                0 => try settleFront(vm, co, Value.undefined_, true, false),
                1 => try settleFront(vm, co, value, false, true),
                else => {
                    // AsyncGeneratorAwaitReturn: await the value, then settle.
                    co.state = Co.awaiting_return;
                    const p = promise.promiseResolve(vm, vm.intrinsics.promise_ctor.asValue(), value) catch |e| switch (e) {
                        error.Exception => {
                            co.state = Co.completed;
                            const ex = vm.exception;
                            vm.exception = Value.undefined_;
                            try settleFront(vm, co, ex, false, true);
                            continue;
                        },
                        else => return e,
                    };
                    const on_f = try vm.newNative("", 1, awaitReturnFulfilled, co_obj.asValue());
                    const on_r = try vm.newNative("", 1, awaitReturnRejected, co_obj.asValue());
                    _ = try promise.performThen(vm, p, on_f.asValue(), on_r.asValue(), null);
                    return;
                },
            }
            continue;
        }
        // Suspended at start or at a yield: run the body.
        const r = resumeCo(vm, co_obj, value, kind);
        try asyncGenAfterResume(vm, co_obj, r);
    }
}

fn awaitReturnFulfilled(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const co_obj = asObject(f.internal(FunctionData).data);
    const co = co_obj.internal(Co);
    co.state = Co.completed;
    try settleFront(vm, co, arg(args, 0), true, false);
    try asyncGenResumeNext(vm, co_obj);
    return Value.undefined_;
}

fn awaitReturnRejected(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    const co_obj = asObject(f.internal(FunctionData).data);
    const co = co_obj.internal(Co);
    co.state = Co.completed;
    try settleFront(vm, co, arg(args, 0), false, true);
    try asyncGenResumeNext(vm, co_obj);
    return Value.undefined_;
}

// ---------------------------------------------- async-from-sync iterators

/// GetIterator(obj, async) (§7.4.2): @@asyncIterator, or a sync iterator
/// wrapped so its results arrive through promises.
pub fn getAsyncIterator(vm: *Vm, v: Value) Error!Vm.IteratorRecord {
    const m = try vm.getMethod(v, .{ .symbol = vm.symbols.async_iterator });
    if (m.isUndefined()) {
        const sync_m = try vm.getMethod(v, .{ .symbol = vm.symbols.iterator });
        if (sync_m.isUndefined()) return vm.throwTypeError("is not async iterable");
        const sync_rec = try vm.getIteratorFromMethod(v, sync_m);
        const o = try vm.objects.create(vm.intrinsics.async_from_sync_iterator_prototype.asValue(), .iterator, @sizeOf(vmod.StringIteratorData));
        o.internal(vmod.IteratorHead).* = .{ .target = sync_rec.iterator, .extra = sync_rec.next };
        const next = try vm.get(o, .{ .atom = vm.atoms.next }, o.asValue());
        return .{ .iterator = o.asValue(), .next = next };
    }
    return vm.getIteratorFromMethod(v, m);
}

fn syncTarget(vm: *Vm, this: Value) Error!*vmod.IteratorHead {
    if (!this.isObject() or asObject(this).class != .iterator or asObject(this).shape.proto.bits != vm.intrinsics.async_from_sync_iterator_prototype.asValue().bits) return vm.throwTypeError("not an async-from-sync iterator");
    return asObject(this).internal(vmod.IteratorHead);
}

/// AsyncFromSyncIteratorContinuation (§27.1.4.4).
fn continuation(vm: *Vm, result: Value, cap: promise.Capability, sync_iter: Value, close_on_rejection: bool) Error!Value {
    if (!result.isObject()) {
        const e = try vm.newError(.TypeError, "iterator result is not an object");
        _ = try vm.call(cap.reject, Value.undefined_, &.{e.asValue()});
        return cap.promise;
    }
    const inner = asObject(result);
    const done = vm.toBoolean(try vm.get(inner, .{ .atom = vm.atoms.done }, result));
    const value = try vm.get(inner, .{ .atom = vm.atoms.value }, result);
    const wrapper = promise.promiseResolve(vm, vm.intrinsics.promise_ctor.asValue(), value) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            if (!done and close_on_rejection) vm.iteratorCloseThrow(.{ .iterator = sync_iter, .next = Value.undefined_ });
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    const unwrap = try vm.newNative("", 1, unwrapResult, Value.fromBool(done));
    var on_r: Value = Value.undefined_;
    if (!done and close_on_rejection) {
        on_r = (try vm.newNative("", 1, closeAndReject, sync_iter)).asValue();
    }
    _ = try promise.performThen(vm, wrapper, unwrap.asValue(), on_r, cap);
    return cap.promise;
}

fn unwrapResult(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    return vm.iterResult(arg(args, 0), f.internal(FunctionData).data.asBool());
}

fn closeAndReject(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const f = vm.current_native orelse return Value.undefined_;
    vm.iteratorCloseThrow(.{ .iterator = f.internal(FunctionData).data, .next = Value.undefined_ });
    return vm.throwValue(arg(args, 0));
}

fn asyncFromSyncNext(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const head = try syncTarget(vm, this);
    const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    const result = (if (args.len > 0) vm.call(head.extra, head.target, &.{args[0]}) else vm.call(head.extra, head.target, &.{})) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    return continuation(vm, result, cap, head.target, true);
}

fn asyncFromSyncReturn(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const head = try syncTarget(vm, this);
    const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    const ret = vm.getMethod(head.target, .{ .atom = vm.atoms.@"return" }) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    if (ret.isUndefined()) {
        _ = try vm.call(cap.resolve, Value.undefined_, &.{try vm.iterResult(arg(args, 0), true)});
        return cap.promise;
    }
    const result = (if (args.len > 0) vm.call(ret, head.target, &.{args[0]}) else vm.call(ret, head.target, &.{})) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    return continuation(vm, result, cap, head.target, false);
}

fn asyncFromSyncThrow(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const head = try syncTarget(vm, this);
    const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    const thr = vm.getMethod(head.target, .{ .atom = vm.atoms.throw }) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    if (thr.isUndefined()) {
        // No throw method: close the iterator and reject with a TypeError.
        var closed = true;
        vm.iteratorClose(.{ .iterator = head.target, .next = Value.undefined_ }) catch |e| switch (e) {
            error.Exception => {
                closed = false;
                const ex = vm.exception;
                vm.exception = Value.undefined_;
                _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            },
            else => return e,
        };
        if (closed) {
            const e = try vm.newError(.TypeError, "The iterator does not provide a 'throw' method");
            _ = try vm.call(cap.reject, Value.undefined_, &.{e.asValue()});
        }
        return cap.promise;
    }
    const result = (if (args.len > 0) vm.call(thr, head.target, &.{args[0]}) else vm.call(thr, head.target, &.{})) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
            return cap.promise;
        },
        else => return e,
    };
    return continuation(vm, result, cap, head.target, true);
}
