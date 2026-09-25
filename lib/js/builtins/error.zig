//! Error and the native error types (§20.5), with `cause` and
//! AggregateError.
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const asString = b.asString;
const strValue = b.strValue;
const arg = b.arg;

const Kind = vmod.ErrorKind;

pub fn install(vm: *Vm) Error!void {
    const proto = vm.intrinsics.error_prototype;
    const ctor = try b.installConstructor(vm, "Error", 1, makeCtor(.Error), proto);
    try vm.defineValue(proto, "name", strValue(try vm.atom("Error")), .hidden);
    try vm.defineValue(proto, "message", strValue(vm.atoms.empty), .hidden);
    _ = try vm.defineNative(proto, "toString", 0, toString);
    _ = try vm.defineNative(ctor, "captureStackTrace", 1, captureStackTrace);
    _ = try vm.defineNative(ctor, "isError", 1, isError);
    inline for (.{
        .{ "TypeError", Kind.TypeError, "type_error_prototype" },
        .{ "RangeError", Kind.RangeError, "range_error_prototype" },
        .{ "ReferenceError", Kind.ReferenceError, "reference_error_prototype" },
        .{ "SyntaxError", Kind.SyntaxError, "syntax_error_prototype" },
        .{ "EvalError", Kind.EvalError, "eval_error_prototype" },
        .{ "URIError", Kind.URIError, "uri_error_prototype" },
    }) |e| {
        const p = @field(vm.intrinsics, e[2]);
        const c = try b.installConstructor(vm, e[0], 1, makeCtor(e[1]), p);
        _ = try vm.objects.setProto(c, ctor.asValue());
        try vm.defineValue(p, "name", strValue(try vm.atom(e[0])), .hidden);
        try vm.defineValue(p, "message", strValue(vm.atoms.empty), .hidden);
    }
    const ap = vm.intrinsics.aggregate_error_prototype;
    const ac = try b.installConstructor(vm, "AggregateError", 2, aggregateCtor, ap);
    _ = try vm.objects.setProto(ac, ctor.asValue());
    try vm.defineValue(ap, "name", strValue(try vm.atom("AggregateError")), .hidden);
    try vm.defineValue(ap, "message", strValue(vm.atoms.empty), .hidden);
}

fn defaultProto(vm: *Vm, kind: Kind) *Object {
    return switch (kind) {
        .Error => vm.intrinsics.error_prototype,
        .TypeError => vm.intrinsics.type_error_prototype,
        .RangeError => vm.intrinsics.range_error_prototype,
        .ReferenceError => vm.intrinsics.reference_error_prototype,
        .SyntaxError => vm.intrinsics.syntax_error_prototype,
        .EvalError => vm.intrinsics.eval_error_prototype,
        .URIError => vm.intrinsics.uri_error_prototype,
        .AggregateError => vm.intrinsics.aggregate_error_prototype,
    };
}

/// The shared constructor body: message, options.cause.
fn constructError(vm: *Vm, kind: Kind, message: Value, options: Value, new_target: Value, ctor_self: Value) Error!*Object {
    const nt = if (new_target.isUndefined()) ctor_self else new_target;
    const o = try vm.createFromConstructor(nt, defaultProto(vm, kind), .error_, @sizeOf(vmod.ErrorData));
    const ed = o.internal(vmod.ErrorData);
    ed.* = .{ .pos = 0, .code = null };
    if (vm.frames.items.len > 0) {
        const f = vm.frames.items[vm.frames.items.len - 1];
        ed.pos = f.code.data.posOf(f.pc);
        ed.code = f.code;
    }
    if (!message.isUndefined()) {
        const m = try vm.toString(message);
        _ = try vm.createDataProperty(o, .{ .atom = vm.atoms.message }, strValue(m));
        _ = try vm.defineOwnProperty(o, .{ .atom = vm.atoms.message }, .{ .enumerable = false }, false);
    }
    if (options.isObject() and try vm.hasProperty(asObject(options), .{ .atom = vm.atoms.cause })) {
        const cause = try vm.get(asObject(options), .{ .atom = vm.atoms.cause }, options);
        _ = try vm.defineOwnProperty(o, .{ .atom = vm.atoms.cause }, .{ .value = cause, .writable = true, .enumerable = false, .configurable = true }, true);
    }
    return o;
}

fn makeCtor(comptime kind: Kind) vmod.NativeFn {
    return struct {
        fn f(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
            // Without `new`, the active function is the constructor itself.
            const self = if (new_target.isUndefined()) blk: {
                const name = @tagName(kind);
                break :blk try vm.get(vm.global, .{ .atom = try vm.atom(name) }, vm.global.asValue());
            } else new_target;
            return (try constructError(vm, kind, arg(args, 0), arg(args, 1), new_target, self)).asValue();
        }
    }.f;
}

fn aggregateCtor(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    const self = if (new_target.isUndefined()) try vm.get(vm.global, .{ .atom = try vm.atom("AggregateError") }, vm.global.asValue()) else new_target;
    const o = try constructError(vm, .AggregateError, arg(args, 1), arg(args, 2), new_target, self);
    var list: std.ArrayList(Value) = .empty;
    defer list.deinit(vm.meta);
    try vm.iterableToList(arg(args, 0), &list);
    const errs = try vm.arrayFromList(list.items);
    _ = try vm.defineOwnProperty(o, .{ .atom = vm.atoms.errors }, .{ .value = errs.asValue(), .writable = true, .enumerable = false, .configurable = true }, true);
    return o.asValue();
}

fn toString(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    if (!this.isObject()) return vm.throwTypeError("Error.prototype.toString called on non-object");
    const o = asObject(this);
    const name_v = try vm.get(o, .{ .atom = vm.atoms.name }, this);
    const name = if (name_v.isUndefined()) try vm.atom("Error") else try vm.toString(name_v);
    const msg_v = try vm.get(o, .{ .atom = vm.atoms.message }, this);
    const msg = if (msg_v.isUndefined()) vm.atoms.empty else try vm.toString(msg_v);
    if (name.len == 0) return strValue(msg);
    if (msg.len == 0) return strValue(name);
    const sep = try vm.strings.fromUtf8(": ");
    return strValue(try vm.concatStrings(try vm.concatStrings(name, sep), msg));
}

fn isError(_: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const v = arg(args, 0);
    return Value.fromBool(v.isObject() and asObject(v).class == .error_);
}

fn captureStackTrace(_: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    return Value.undefined_;
}
