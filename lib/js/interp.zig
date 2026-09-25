//! The interpreter: `run` executes frames on the register stack until
//! the entry frame returns. Calls between JS functions push a frame and
//! continue the same loop — no Zig recursion, so JS recursion depth is
//! the stack's, not the machine's; a native that calls back into JS
//! re-enters `run` with a new entry frame. Exceptions unwind through
//! the handler stack (`pushtry`/`poptry`) frame by frame.
//!
//! Property sites carry an inline cache: a hit compares the object's
//! shape with the one the site last saw and reads the slot directly.
//! Global sites cache the global object's shape the same way, guarded
//! by the epoch of the global lexical record.
const std = @import("std");
const builtin = @import("builtin");
const vmod = @import("vm.zig");
const bytecode = @import("bytecode.zig");
const object = @import("object.zig");
const string = @import("string.zig");
const compiler = @import("compiler.zig");
const realm = @import("realm.zig");
const heap = @import("heap.zig");
const modules = @import("module.zig");
const Vm = vmod.Vm;
const Value = vmod.Value;
const Error = vmod.Error;
const Object = vmod.Object;
const String = vmod.String;
const Key = vmod.Key;
const Code = vmod.Code;
const Env = vmod.Env;
const Frame = vmod.Frame;
const Insn = bytecode.Insn;
const Op = bytecode.Op;
const FunctionData = vmod.FunctionData;
const Accessor = vmod.Accessor;
const asObject = Vm.asObject;
const asString = Vm.asString;
const strValue = Vm.strValue;

const max_native_depth = 200;

/// `JS_TRACE=1`: print every instruction executed (debugging).
pub var trace_enabled = false;

/// Run a script's (or eval's) top-level code.
pub fn runScript(vm: *Vm, code: *Code, this: Value, env: ?*Env, func: ?*Object, new_target: Value) Error!Value {
    try pushFrame(vm, code, func, this, new_target, env, vm.sp(), 0, 0, false, true, null);
    return run(vm);
}

/// Call any callable with arguments from Zig.
pub fn callValue(vm: *Vm, f: Value, this: Value, args: []const Value) Error!Value {
    const o = asObject(f);
    switch (o.class) {
        .function => {
            const fd = o.internal(FunctionData);
            if (fd.native) |n| {
                if (vm.depth > max_native_depth) return vm.throwRangeError("Maximum call stack size exceeded");
                vm.depth += 1;
                defer vm.depth -= 1;
                const saved_native = vm.current_native;
                vm.current_native = o;
                defer vm.current_native = saved_native;
                return n(vm, this, args, Value.undefined_);
            }
            if (fd.is_class_constructor) return vm.throwTypeError("Class constructor cannot be invoked without 'new'");
            const code = fd.code.?;
            if (isGeneratorKind(code.data.kind)) return realm.callGenerator(vm, o, this, args);
            // The arguments go to the stack top (unless already there) and run.
            const base = try placeArgs(vm, args);
            if (vm.depth > max_native_depth) return vm.throwRangeError("Maximum call stack size exceeded");
            vm.depth += 1;
            defer vm.depth -= 1;
            try pushFrame(vm, code, o, try coerceThis(vm, fd, this), Value.undefined_, fd.env, base, @intCast(args.len), 0, false, true, null);
            return run(vm);
        },
        .bound_function => {
            const b = o.internal(vmod.BoundData);
            const bound = b.args;
            const n = Vm.arrayLength(bound);
            if (n == 0) return callValue(vm, b.target.asValue(), b.bound_this, args);
            var list: std.ArrayList(Value) = .empty;
            defer list.deinit(vm.meta);
            try list.appendSlice(vm.meta, bound.elements.?.items()[0..n]);
            try list.appendSlice(vm.meta, args);
            return callValue(vm, b.target.asValue(), b.bound_this, list.items);
        },
        .proxy => return realm.proxyCall(vm, o, this, args),
        else => return vm.throwTypeError("is not a function"),
    }
}

/// Construct with arguments from Zig.
pub fn constructValue(vm: *Vm, f: Value, args: []const Value, new_target: Value) Error!Value {
    const o = asObject(f);
    switch (o.class) {
        .function => {
            const fd = o.internal(FunctionData);
            if (fd.native) |n| {
                if (vm.depth > max_native_depth) return vm.throwRangeError("Maximum call stack size exceeded");
                vm.depth += 1;
                defer vm.depth -= 1;
                const saved_native = vm.current_native;
                vm.current_native = o;
                defer vm.current_native = saved_native;
                return n(vm, Value.undefined_, args, new_target);
            }
            const code = fd.code.?;
            const base = try placeArgs(vm, args);
            if (vm.depth > max_native_depth) return vm.throwRangeError("Maximum call stack size exceeded");
            vm.depth += 1;
            defer vm.depth -= 1;
            // The fields initializer may run JS: the arguments stay put
            // (a nested call places its own above them).
            vm.sp_extra = @intCast(args.len);
            const this = constructThis(vm, o, fd, new_target) catch |e| {
                vm.sp_extra = 0;
                return e;
            };
            vm.sp_extra = 0;
            try pushFrame(vm, code, o, this, new_target, fd.env, base, @intCast(args.len), 0, true, true, null);
            return run(vm);
        },
        .bound_function => {
            const b = o.internal(vmod.BoundData);
            const bound = b.args;
            const n = Vm.arrayLength(bound);
            var list: std.ArrayList(Value) = .empty;
            defer list.deinit(vm.meta);
            if (n > 0) try list.appendSlice(vm.meta, bound.elements.?.items()[0..n]);
            try list.appendSlice(vm.meta, args);
            const nt = if (new_target.eqlBits(f)) b.target.asValue() else new_target;
            return constructValue(vm, b.target.asValue(), list.items, nt);
        },
        .proxy => return realm.proxyConstruct(vm, o, args, new_target),
        else => return vm.throwTypeError("is not a constructor"),
    }
}

/// Where `args` sit for a call from Zig: at the stack top, copied there
/// unless they already are (a spread call staged them).
fn placeArgs(vm: *Vm, args: []const Value) Error!u32 {
    const base = vm.sp();
    if (base + args.len + 1 > vm.stack.len) return vm.throwRangeError("Maximum call stack size exceeded");
    if (args.len > 0 and args.ptr != vm.stack.ptr + base) @memcpy(vm.stack[base .. base + args.len], args);
    return @intCast(base);
}

fn isGeneratorKind(k: bytecode.FunctionKind) bool {
    return switch (k) {
        .generator, .async_function, .async_generator, .async_arrow => true,
        else => false,
    };
}

/// The `this` a non-arrow function sees (§10.2.1.2 OrdinaryCallBindThis).
fn coerceThis(vm: *Vm, fd: *FunctionData, this: Value) Error!Value {
    switch (fd.this_mode) {
        .lexical, .strict => return this,
        .sloppy => {
            if (this.isNullish()) return vm.global.asValue();
            if (this.isObject()) return this;
            return (try vm.toObject(this)).asValue();
        },
    }
}

pub fn coerceThisFor(vm: *Vm, fd: *FunctionData, this: Value) Error!Value {
    return coerceThis(vm, fd, this);
}

/// Start a coroutine body: an entry frame with the record attached.
pub fn runCoroutineStart(vm: *Vm, code: *Code, f: ?*Object, this: Value, env: ?*Env, args: []const Value, co: ?*Object) Error!Value {
    const base = try placeArgs(vm, args);
    if (vm.depth > max_native_depth) return vm.throwRangeError("Maximum call stack size exceeded");
    vm.depth += 1;
    defer vm.depth -= 1;
    try pushFrame(vm, code, f, this, Value.undefined_, env, base, @intCast(args.len), 0, false, true, null);
    currentFrame(vm).co = co;
    return run(vm);
}

/// Copy a suspended coroutine's frame back onto the stack and run it.
pub fn resumeCoroutine(vm: *Vm, co_obj: *Object, value: Value, kind: u8) Error!Value {
    const co = co_obj.internal(vmod.CoroutineData);
    const base = vm.sp();
    if (@as(usize, base) + co.nregs + 1 > vm.stack.len or vm.frames.items.len >= Vm.max_frames) return vm.throwRangeError("Maximum call stack size exceeded");
    const regs = vm.stack[base .. base + co.nregs];
    @memcpy(regs, co.savedRegs());
    const frame_index: u32 = @intCast(vm.frames.items.len);
    vm.frames.appendAssumeCapacity(.{
        .code = co.code,
        .func = co.func,
        .co = co_obj,
        .pc = co.pc,
        .base = base,
        .this = co.this,
        .new_target = co.new_target,
        .env = co.env,
        .args_base = base,
        .argc = 0,
        .handlers_base = @intCast(vm.handlers.items.len),
        .ret_dst = 0,
        .is_construct = false,
        .entry = true,
        .saved_sp = base,
    });
    for (co.savedHandlers()) |h| try vm.handlers.append(vm.meta, .{ .pc = h.pc, .reg = h.reg, .env = h.env, .frame = frame_index });
    // A frame suspended at its start takes no value.
    if (co.resume_reg != 0xFFFF) {
        regs[co.resume_reg] = value;
        regs[co.kind_reg] = Value.fromInt(kind);
    }
    if (vm.depth > max_native_depth) return vm.throwRangeError("Maximum call stack size exceeded");
    vm.depth += 1;
    defer vm.depth -= 1;
    return run(vm);
}

/// Save the running frame into its coroutine record and pop it.
fn suspendFrame(vm: *Vm, frame: *Frame, pc: u32, resume_reg: u16, kind_reg: u16) Error!void {
    const co_obj = frame.co.?;
    const co = co_obj.internal(vmod.CoroutineData);
    const nregs = frame.code.data.nregs;
    if (co.regs == null or co.nregs != nregs) {
        co.nregs = nregs;
        co.regs = try vm.heap.alloc(.bytes, 16 + @as(usize, nregs) * @sizeOf(Value));
    }
    @memcpy(co.savedRegs(), vm.stack[frame.base .. frame.base + nregs]);
    const hs = vm.handlers.items[frame.handlers_base..];
    if (hs.len > 0) {
        if (co.handlers == null or co.nhandlers != hs.len) {
            co.nhandlers = @intCast(hs.len);
            co.handlers = try vm.heap.alloc(.bytes, 16 + hs.len * @sizeOf(vmod.Handler));
        }
        @memcpy(co.savedHandlers(), hs);
    } else {
        co.nhandlers = 0;
        co.handlers = null;
    }
    co.pc = pc;
    co.resume_reg = resume_reg;
    co.kind_reg = kind_reg;
    co.env = frame.env;
    co.this = frame.this;
    co.new_target = frame.new_target;
    _ = popFrame(vm);
}

/// The `this` of a [[Construct]]: a fresh object for a base
/// constructor (with its fields run), the hole for a derived one.
fn constructThis(vm: *Vm, f: *Object, fd: *FunctionData, new_target: Value) Error!Value {
    if (fd.derived) return Value.empty;
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.object_prototype, .ordinary, 0);
    try initializeInstanceElements(vm, o, f);
    return o.asValue();
}

/// InitializeInstanceElements: run the class's field initializer.
fn initializeInstanceElements(vm: *Vm, o: *Object, f: *Object) Error!void {
    const fd = f.internal(FunctionData);
    if (fd.fields.isUndefined()) return;
    _ = try vm.call(fd.fields, o.asValue(), &.{});
}

/// Push a frame for `code`: the register window is above the
/// current stack top; parameters are copied from the arguments.
fn pushFrame(vm: *Vm, code: *Code, func: ?*Object, this: Value, new_target: Value, env: ?*Env, args_base: u32, argc: u32, ret_dst: u16, is_construct: bool, entry: bool, saved_sp: ?u32) Error!void {
    const d = code.data;
    const base: u32 = @max(vm.sp(), args_base + argc);
    if (@as(usize, base) + d.nregs + 1 > vm.stack.len or vm.frames.items.len >= Vm.max_frames) return vm.throwRangeError("Maximum call stack size exceeded");
    const regs = vm.stack[base .. base + d.nregs];
    const ncopy = @min(argc, d.nparams);
    if (ncopy > 0) @memcpy(regs[0..ncopy], vm.stack[args_base .. args_base + ncopy]);
    @memset(regs[ncopy..], Value.undefined_);
    vm.frames.appendAssumeCapacity(.{
        .code = code,
        .func = func,
        .pc = 0,
        .base = base,
        .this = this,
        .new_target = new_target,
        .env = env,
        .args_base = args_base,
        .argc = argc,
        .handlers_base = @intCast(vm.handlers.items.len),
        .ret_dst = ret_dst,
        .is_construct = is_construct,
        .entry = entry,
        .saved_sp = saved_sp orelse args_base,
    });
}

/// A frame returns `v`: pops it; the caller's destination gets the
/// value unless it was an entry frame, whose value is returned.
fn popFrame(vm: *Vm) Frame {
    const f = vm.frames.pop().?;
    vm.handlers.shrinkRetainingCapacity(f.handlers_base);
    return f;
}

pub fn currentFrame(vm: *Vm) *Frame {
    return &vm.frames.items[vm.frames.items.len - 1];
}

/// Execute until the current entry frame returns.
pub fn run(vm: *Vm) Error!Value {
    const entry_depth = vm.frames.items.len;
    var frame = currentFrame(vm);
    var code = frame.code.data;
    var regs: [*]Value = vm.stack.ptr + frame.base;
    var pc: u32 = frame.pc;
    while (true) {
        const result = step(vm, &frame, &code, &regs, &pc, entry_depth) catch |e| switch (e) {
            error.Exception => {
                // Unwind to a handler in this run's frames.
                frame.pc = pc;
                while (true) {
                    const cur = currentFrame(vm);
                    if (vm.handlers.items.len > cur.handlers_base) {
                        const h = vm.handlers.pop().?;
                        cur.pc = h.pc;
                        cur.env = h.env;
                        vm.stack[cur.base + h.reg] = vm.exception;
                        frame = cur;
                        code = cur.code.data;
                        regs = vm.stack.ptr + cur.base;
                        pc = cur.pc;
                        break;
                    }
                    const f = popFrame(vm);
                    if (f.entry or vm.frames.items.len < entry_depth) return error.Exception;
                    frame = currentFrame(vm);
                    code = frame.code.data;
                    regs = vm.stack.ptr + frame.base;
                    pc = frame.pc;
                }
                continue;
            },
            error.OutOfMemory => return error.OutOfMemory,
        };
        if (result) |v| return v;
    }
}

/// The dispatch loop proper; returns when an entry frame returns.
fn step(vm: *Vm, frame_p: **Frame, code_p: **bytecode.CodeData, regs_p: *[*]Value, pc_p: *u32, entry_depth: usize) Error!?Value {
    var frame = frame_p.*;
    var code = code_p.*;
    var regs = regs_p.*;
    var pc = pc_p.*;
    defer {
        frame_p.* = frame;
        code_p.* = code;
        regs_p.* = regs;
        pc_p.* = pc;
    }
    while (true) {
        const insn = code.insns[pc];
        if (comptime builtin.os.tag != .freestanding) if (trace_enabled) std.debug.print("[{d}] pc={d} {s} {d} {d} {d} base={d} nregs={d}\n", .{ vm.frames.items.len, pc, insn.op.name(), insn.a, insn.b, insn.c, frame.base, code.nregs });
        pc += 1;
        // Where the frame's pc is needed (calls, errors), it is stored.
        switch (insn.op) {
            .nop, .debugger => {},
            .mov => regs[insn.a] = regs[insn.b],
            .ldc => regs[insn.a] = code.consts[insn.bc()],
            .ldint => regs[insn.a] = Value.fromInt(@bitCast(insn.bc())),
            .ldundef => regs[insn.a] = Value.undefined_,
            .ldnull => regs[insn.a] = Value.null_,
            .ldtrue => regs[insn.a] = Value.true_,
            .ldfalse => regs[insn.a] = Value.false_,
            .ldempty => regs[insn.a] = Value.empty,
            .ldgthis => regs[insn.a] = vm.global.asValue(),
            .ldthis => {
                if (frame.this.isEmpty()) {
                    frame.pc = pc;
                    return vm.throwReferenceError("Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
                }
                regs[insn.a] = frame.this;
            },
            .setthis => {
                if (!frame.this.isEmpty()) {
                    frame.pc = pc;
                    return vm.throwReferenceError("Super constructor may only be called once");
                }
                frame.this = regs[insn.a];
            },
            .ldnewtarget => regs[insn.a] = frame.new_target,
            .ldfunc => regs[insn.a] = if (frame.func) |f| f.asValue() else Value.undefined_,
            .ldhome => regs[insn.a] = if (frame.func) |f| f.internal(FunctionData).home_object else Value.undefined_,

            // -------------------------------------------- operators
            .add => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isInt() and b.isInt()) {
                    const r = @as(i64, a.asInt()) + @as(i64, b.asInt());
                    regs[insn.a] = if (r >= std.math.minInt(i32) and r <= std.math.maxInt(i32)) Value.fromInt(@intCast(r)) else Value.fromF64(@floatFromInt(r));
                } else if (a.isNumber() and b.isNumber()) {
                    regs[insn.a] = Value.fromF64(a.asNumber() + b.asNumber());
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.add(a, b);
                }
            },
            .sub => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isInt() and b.isInt()) {
                    const r = @as(i64, a.asInt()) - @as(i64, b.asInt());
                    regs[insn.a] = if (r >= std.math.minInt(i32) and r <= std.math.maxInt(i32)) Value.fromInt(@intCast(r)) else Value.fromF64(@floatFromInt(r));
                } else if (a.isNumber() and b.isNumber()) {
                    regs[insn.a] = Value.fromF64(a.asNumber() - b.asNumber());
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.arith(.sub, a, b);
                }
            },
            .mul => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isNumber() and b.isNumber()) {
                    regs[insn.a] = Value.fromF64(a.asNumber() * b.asNumber());
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.arith(.mul, a, b);
                }
            },
            .div => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isNumber() and b.isNumber()) {
                    regs[insn.a] = Value.fromF64(a.asNumber() / b.asNumber());
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.arith(.div, a, b);
                }
            },
            .mod => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isInt() and b.isInt() and b.asInt() > 0 and a.asInt() >= 0) {
                    regs[insn.a] = Value.fromInt(@rem(a.asInt(), b.asInt()));
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.arith(.mod, a, b);
                }
            },
            .exp => {
                frame.pc = pc;
                regs[insn.a] = try vm.arith(.exp, regs[insn.b], regs[insn.c]);
            },
            .shl, .shr, .ushr, .band, .bor, .bxor => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isInt() and b.isInt()) {
                    const x = a.asInt();
                    const y: u5 = @truncate(@as(u32, @bitCast(b.asInt())));
                    regs[insn.a] = switch (insn.op) {
                        .shl => Value.fromInt(x << y),
                        .shr => Value.fromInt(x >> y),
                        .ushr => Value.fromF64(@floatFromInt(@as(u32, @bitCast(x)) >> y)),
                        .band => Value.fromInt(x & b.asInt()),
                        .bor => Value.fromInt(x | b.asInt()),
                        else => Value.fromInt(x ^ b.asInt()),
                    };
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.arith(switch (insn.op) {
                        .shl => .shl,
                        .shr => .shr,
                        .ushr => .ushr,
                        .band => .band,
                        .bor => .bor,
                        else => .bxor,
                    }, a, b);
                }
            },
            .lt, .gt, .le, .ge => {
                const a = regs[insn.b];
                const b = regs[insn.c];
                if (a.isNumber() and b.isNumber()) {
                    const x = a.asNumber();
                    const y = b.asNumber();
                    regs[insn.a] = Value.fromBool(switch (insn.op) {
                        .lt => x < y,
                        .gt => x > y,
                        .le => x <= y,
                        else => x >= y,
                    });
                } else {
                    frame.pc = pc;
                    regs[insn.a] = Value.fromBool(switch (insn.op) {
                        .lt => (try vm.isLessThan(a, b, true)) orelse false,
                        .gt => (try vm.isLessThan(b, a, false)) orelse false,
                        .le => blk: {
                            const r = try vm.isLessThan(b, a, false);
                            break :blk !(r orelse true);
                        },
                        else => blk: {
                            const r = try vm.isLessThan(a, b, true);
                            break :blk !(r orelse true);
                        },
                    });
                }
            },
            .eq => {
                frame.pc = pc;
                regs[insn.a] = Value.fromBool(try vm.isLooselyEqual(regs[insn.b], regs[insn.c]));
            },
            .ne => {
                frame.pc = pc;
                regs[insn.a] = Value.fromBool(!try vm.isLooselyEqual(regs[insn.b], regs[insn.c]));
            },
            .seq => regs[insn.a] = Value.fromBool(vm.isStrictlyEqual(regs[insn.b], regs[insn.c])),
            .sne => regs[insn.a] = Value.fromBool(!vm.isStrictlyEqual(regs[insn.b], regs[insn.c])),
            .in => {
                frame.pc = pc;
                const target = regs[insn.c];
                if (!target.isObject()) return vm.throwTypeError("Cannot use 'in' operator to search for a key in a non-object");
                const key = try vm.toPropertyKey(regs[insn.b]);
                regs[insn.a] = Value.fromBool(try vm.hasProperty(asObject(target), key));
            },
            .instanceof => {
                frame.pc = pc;
                regs[insn.a] = Value.fromBool(try vm.instanceOf(regs[insn.b], regs[insn.c]));
            },
            .neg => {
                frame.pc = pc;
                regs[insn.a] = try vm.negate(regs[insn.b]);
            },
            .pos => {
                const v = regs[insn.b];
                if (v.isNumber()) {
                    regs[insn.a] = v;
                } else {
                    frame.pc = pc;
                    regs[insn.a] = Value.fromF64(try vm.toNumber(v));
                }
            },
            .tonumeric => {
                const v = regs[insn.b];
                if (v.isNumber()) {
                    regs[insn.a] = v;
                } else {
                    frame.pc = pc;
                    regs[insn.a] = try vm.toNumeric(v);
                }
            },
            .bnot => {
                frame.pc = pc;
                regs[insn.a] = try vm.bitNot(regs[insn.b]);
            },
            .not => regs[insn.a] = Value.fromBool(!vm.toBoolean(regs[insn.b])),
            .typeof => regs[insn.a] = strValue(vm.typeOf(regs[insn.b])),
            .inc, .dec => {
                const v = regs[insn.b];
                const delta: i32 = if (insn.op == .inc) 1 else -1;
                if (v.isInt() and v.asInt() != std.math.maxInt(i32) and v.asInt() != std.math.minInt(i32)) {
                    regs[insn.a] = Value.fromInt(v.asInt() + delta);
                } else if (v.isNumber()) {
                    regs[insn.a] = Value.fromF64(v.asNumber() + @as(f64, @floatFromInt(delta)));
                } else {
                    frame.pc = pc;
                    const n = try vm.toNumeric(v);
                    const one = if (n.isBigInt()) try realm.bigintFromI64(vm, 1) else Value.fromInt(1);
                    regs[insn.a] = try vm.arith(if (insn.op == .inc) .add else .sub, n, one);
                }
            },
            .tostring => {
                const v = regs[insn.b];
                if (v.isString()) {
                    regs[insn.a] = v;
                } else {
                    frame.pc = pc;
                    regs[insn.a] = strValue(try vm.toString(v));
                }
            },
            .topropkey => {
                const v = regs[insn.b];
                if (!(v.isString() or v.isSymbol() or v.isInt())) {
                    frame.pc = pc;
                    regs[insn.a] = try keyValue(vm, try vm.toPropertyKey(v));
                } else regs[insn.a] = v;
            },
            .toobject => {
                frame.pc = pc;
                regs[insn.a] = (try vm.toObject(regs[insn.b])).asValue();
            },

            // ------------------------------------------------ jumps
            .jmp => {
                const target = insn.bc();
                if (target <= pc) {
                    // A backward jump is a safe point, and where a runaway
                    // loop meets the embedder's budget.
                    if (vm.depth == 0) vm.safePoint();
                    frame.pc = pc;
                    try vm.tick();
                }
                pc = target;
            },
            .jt => if (vm.toBoolean(regs[insn.a])) {
                pc = insn.bc();
            },
            .jf => if (!vm.toBoolean(regs[insn.a])) {
                pc = insn.bc();
            },
            .jundef => if (regs[insn.a].isUndefined()) {
                pc = insn.bc();
            },
            .jnundef => if (!regs[insn.a].isUndefined()) {
                pc = insn.bc();
            },
            .jnullish => if (regs[insn.a].isNullish()) {
                pc = insn.bc();
            },
            .jnnullish => if (!regs[insn.a].isNullish()) {
                pc = insn.bc();
            },
            .jempty => if (regs[insn.a].isEmpty()) {
                pc = insn.bc();
            },
            .jnempty => if (!regs[insn.a].isEmpty()) {
                pc = insn.bc();
            },

            // ------------------------------------------- properties
            .getprop => {
                const obj = regs[insn.b];
                const site = &code.props[insn.c];
                if (obj.isObject()) {
                    const o = asObject(obj);
                    if (@as(*anyopaque, @ptrCast(o.shape)) == site.ic.shape) {
                        if (site.ic.holder) |h| {
                            const ho: *Object = @ptrCast(@alignCast(h));
                            if (@as(*anyopaque, @ptrCast(ho.shape)) == site.ic.holder_shape) {
                                regs[insn.a] = ho.slot(site.ic.slot).*;
                                continue;
                            }
                        } else {
                            regs[insn.a] = o.slot(site.ic.slot).*;
                            continue;
                        }
                    }
                }
                frame.pc = pc;
                regs[insn.a] = try getPropSlow(vm, obj, site);
            },
            .setprop => {
                const obj = regs[insn.a];
                const site = &code.props[insn.b];
                const v = regs[insn.c];
                if (obj.isObject()) {
                    const o = asObject(obj);
                    if (@as(*anyopaque, @ptrCast(o.shape)) == site.ic.shape and site.ic.holder == null) {
                        vm.heap.writeBarrier(&o.header, v);
                        o.slot(site.ic.slot).* = v;
                        continue;
                    }
                }
                frame.pc = pc;
                try setPropSlow(vm, obj, site, v, code.strict);
            },
            .getelem => {
                const obj = regs[insn.b];
                const key = regs[insn.c];
                if (obj.isObject() and key.isInt()) {
                    const o = asObject(obj);
                    const i = key.asInt();
                    if (i >= 0 and o.class == .array) if (o.elements) |e| if (@as(u32, @intCast(i)) < e.cap) {
                        const v = e.items()[@intCast(i)];
                        if (!v.isEmpty()) {
                            regs[insn.a] = v;
                            continue;
                        }
                    };
                }
                frame.pc = pc;
                regs[insn.a] = try getElem(vm, obj, key);
            },
            .setelem => {
                const obj = regs[insn.a];
                const key = regs[insn.b];
                const v = regs[insn.c];
                if (obj.isObject() and key.isInt()) {
                    const o = asObject(obj);
                    const i = key.asInt();
                    if (i >= 0 and o.class == .array and !o.sparse_indexes and o.extensible) if (o.elements) |e| {
                        const ui: u32 = @intCast(i);
                        if (ui < e.cap and (ui < e.len or vm.lengthWritable(o))) {
                            // Within the dense part: a hole may be filled only
                            // when no prototype setter would see it — arrays
                            // whose prototype chain is the intrinsic one.
                            if (!e.items()[ui].isEmpty() or vm.arrayProtoClean()) {
                                vm.heap.writeBarrier(&o.header, v);
                                e.items()[ui] = v;
                                if (ui >= e.len) e.len = ui + 1;
                                continue;
                            }
                        }
                    };
                }
                frame.pc = pc;
                try setElem(vm, obj, key, v, code.strict);
            },
            .delprop => {
                frame.pc = pc;
                const obj = regs[insn.b];
                if (obj.isNullish()) return vm.throwTypeError("Cannot convert undefined or null to object");
                const key = try vm.toPropertyKey(regs[insn.c]);
                const o = try vm.toObject(obj);
                const ok = try vm.deleteProperty(o, key);
                if (!ok and code.strict) return vm.throwTypeErrorFmt("Cannot delete property '{s}'", .{vm.keyDebug(key)});
                regs[insn.a] = Value.fromBool(ok);
            },
            .getsuper => {
                frame.pc = pc;
                const home = regs[insn.b];
                const this = regs[insn.b + 1];
                const key = try vm.toPropertyKey(regs[insn.b + 2]);
                if (!home.isObject()) return vm.throwSyntaxError("'super' keyword unexpected here");
                const proto = try vm.getPrototypeOf(asObject(home));
                if (!proto.isObject()) return vm.throwTypeError("Cannot read properties of null (super)");
                regs[insn.a] = try vm.get(asObject(proto), key, this);
            },
            .setsuper => {
                frame.pc = pc;
                const home = regs[insn.a];
                const this = regs[insn.a + 1];
                const key = try vm.toPropertyKey(regs[insn.a + 2]);
                if (!home.isObject()) return vm.throwSyntaxError("'super' keyword unexpected here");
                const proto = try vm.getPrototypeOf(asObject(home));
                if (!proto.isObject()) return vm.throwTypeError("Cannot set properties of null (super)");
                const ok = try vm.set(asObject(proto), key, regs[insn.c], this);
                if (!ok and code.strict) return vm.throwTypeError("Cannot assign to read only property (super)");
            },
            .defown => {
                frame.pc = pc;
                const o = asObject(regs[insn.a]);
                const site = &code.props[insn.b];
                const v = regs[insn.c];
                try nameAnonymous(vm, v, .{ .atom = site.key }, null);
                _ = try vm.createDataProperty(o, .{ .atom = site.key }, v);
            },
            .defelem => {
                frame.pc = pc;
                const o = asObject(regs[insn.a]);
                const key = try vm.toPropertyKey(regs[insn.b]);
                const v = regs[insn.c];
                try nameAnonymous(vm, v, key, null);
                _ = try vm.createDataProperty(o, key, v);
            },
            .defproto => {
                frame.pc = pc;
                const v = regs[insn.b];
                if (v.isObject() or v.isNull()) _ = try vm.objects.setProto(asObject(regs[insn.a]), v);
            },
            .defgetter, .defsetter, .defgetterc, .defsetterc => {
                frame.pc = pc;
                const o = asObject(regs[insn.a]);
                const key = try vm.toPropertyKey(regs[insn.b]);
                const f = regs[insn.c];
                const is_get = insn.op == .defgetter or insn.op == .defgetterc;
                const enumerable = insn.op == .defgetter or insn.op == .defsetter;
                try nameAnonymous(vm, f, key, if (is_get) "get " else "set ");
                asObject(f).internal(FunctionData).home_object = o.asValue();
                const desc: Vm.Descriptor = if (is_get) .{ .get = f, .enumerable = enumerable, .configurable = true } else .{ .set = f, .enumerable = enumerable, .configurable = true };
                _ = try vm.defineOwnProperty(o, key, desc, true);
            },
            .defmethod, .defmethodc => {
                frame.pc = pc;
                const o = asObject(regs[insn.a]);
                const key = try vm.toPropertyKey(regs[insn.b]);
                const f = regs[insn.c];
                try nameAnonymous(vm, f, key, null);
                asObject(f).internal(FunctionData).home_object = o.asValue();
                _ = try vm.defineOwnProperty(o, key, .{ .value = f, .writable = true, .enumerable = insn.op == .defmethod, .configurable = true }, true);
            },
            .sethome => {
                asObject(regs[insn.a]).internal(FunctionData).home_object = regs[insn.b];
            },
            .spreadobj => {
                frame.pc = pc;
                const excluded: ?*Object = if (insn.c == 0xffff) null else asObject(regs[insn.c]);
                try vm.copyDataProperties(asObject(regs[insn.a]), regs[insn.b], excluded);
            },
            .getpriv => {
                frame.pc = pc;
                regs[insn.a] = try getPrivate(vm, regs[insn.b], regs[insn.c]);
            },
            .setpriv => {
                frame.pc = pc;
                try setPrivate(vm, regs[insn.a], regs[insn.b], regs[insn.c]);
            },
            .haspriv => {
                frame.pc = pc;
                const target = regs[insn.c];
                if (!target.isObject()) return vm.throwTypeError("Cannot use 'in' operator to search for a private field in a non-object");
                regs[insn.a] = Value.fromBool((try vm.objects.getOwn(asObject(target), .{ .symbol = Vm.asSymbol(regs[insn.b]) })) != null);
            },
            .defpriv, .defprivmethod => {
                frame.pc = pc;
                const target = regs[insn.a];
                if (!target.isObject()) return vm.throwTypeError("Cannot define a private member on a non-object");
                const o = asObject(target);
                const sym = Vm.asSymbol(regs[insn.b]);
                if ((try vm.objects.getOwn(o, .{ .symbol = sym })) != null) return vm.throwTypeError("Cannot initialize private member twice on the same object");
                if (!try vm.objects.defineOwn(o, .{ .symbol = sym }, regs[insn.c], .{ .writable = insn.op == .defpriv, .enumerable = false, .configurable = false })) {
                    // Non-extensible objects still take private names.
                    o.extensible = true;
                    _ = try vm.objects.defineOwn(o, .{ .symbol = sym }, regs[insn.c], .{ .writable = insn.op == .defpriv, .enumerable = false, .configurable = false });
                    o.extensible = false;
                }
            },

            // ---------------------------------------------- objects
            .newobj => regs[insn.a] = (try vm.newObject()).asValue(),
            .newarr => regs[insn.a] = (try vm.newArray(0)).asValue(),
            .arrpush => try vm.arrayPush(asObject(regs[insn.a]), regs[insn.b]),
            .arrspread => {
                frame.pc = pc;
                const arr = asObject(regs[insn.a]);
                var rec = try vm.getIterator(regs[insn.b]);
                while (try vm.iteratorStepValue(&rec)) |v| try vm.arrayPush(arr, v);
            },
            .regexp => {
                frame.pc = pc;
                regs[insn.a] = try realm.newRegExp(vm, code.consts[insn.b], code.consts[insn.c]);
            },
            .template => {
                const site = &code.templates[insn.bc()];
                if (site.cached.isUndefined()) site.cached = try templateObject(vm, site);
                regs[insn.a] = site.cached;
            },
            .closure => {
                frame.pc = pc;
                const f = try vm.newFunction(code.functions[insn.bc()], frame.env, Value.undefined_);
                regs[insn.a] = f.asValue();
            },
            .class => {
                frame.pc = pc;
                regs[insn.a] = try makeClass(vm, regs[insn.b], code.functions[insn.c], frame.env);
            },
            .setfields => {
                asObject(regs[insn.a]).internal(FunctionData).fields = regs[insn.b];
            },
            .bigint => {
                frame.pc = pc;
                regs[insn.a] = try realm.bigintFromLiteral(vm, asString(code.consts[insn.bc()]));
            },
            .privname => {
                const desc = asString(code.consts[insn.bc()]);
                const sym = try vm.newSymbol(desc);
                sym.private = true;
                regs[insn.a] = Value.fromCell(&sym.header);
            },

            // ------------------------------------------------ calls
            .call => {
                const f = regs[insn.b];
                const argc = insn.c;
                const args_base: u32 = frame.base + insn.b + 2;
                frame.pc = pc;
                if (f.isObject() and asObject(f).class == .function) {
                    const fo = asObject(f);
                    const fd = fo.internal(FunctionData);
                    if (fd.code) |callee| if (!fd.is_class_constructor and !isGeneratorKind(callee.data.kind)) {
                        const this = try coerceThis(vm, fd, regs[insn.b + 1]);
                        try pushFrame(vm, callee, fo, this, Value.undefined_, fd.env, args_base, argc, insn.a, false, false, null);
                        frame = currentFrame(vm);
                        code = callee.data;
                        regs = vm.stack.ptr + frame.base;
                        pc = 0;
                        continue;
                    };
                }
                regs[insn.a] = try callSlow(vm, f, regs[insn.b + 1], vm.stack[args_base .. args_base + argc], pc);
            },
            .callspread => {
                frame.pc = pc;
                const f = regs[insn.b];
                const arr = asObject(regs[insn.b + 2]);
                const n = Vm.arrayLength(arr);
                const base = vm.sp();
                if (base + n + 1 > vm.stack.len) return vm.throwRangeError("Maximum call stack size exceeded");
                if (n > 0) @memcpy(vm.stack[base .. base + n], arr.elements.?.items()[0..n]);
                if (f.isObject() and asObject(f).class == .function) {
                    const fo = asObject(f);
                    const fd = fo.internal(FunctionData);
                    if (fd.code) |callee| if (!fd.is_class_constructor and !isGeneratorKind(callee.data.kind)) {
                        const this = try coerceThis(vm, fd, regs[insn.b + 1]);
                        try pushFrame(vm, callee, fo, this, Value.undefined_, fd.env, @intCast(base), n, insn.a, false, false, null);
                        frame = currentFrame(vm);
                        code = callee.data;
                        regs = vm.stack.ptr + frame.base;
                        pc = 0;
                        continue;
                    };
                }
                regs[insn.a] = try callSlow(vm, f, regs[insn.b + 1], vm.stack[base .. base + n], pc);
            },
            .new => {
                frame.pc = pc;
                const f = regs[insn.b];
                const argc = insn.c;
                const args_base: u32 = frame.base + insn.b + 1;
                if (!vm.isConstructor(f)) return vm.throwTypeError("is not a constructor");
                if (asObject(f).class == .function) {
                    const fo = asObject(f);
                    const fd = fo.internal(FunctionData);
                    if (fd.code) |callee| {
                        const this = try constructThis(vm, fo, fd, f);
                        try pushFrame(vm, callee, fo, this, f, fd.env, args_base, argc, insn.a, true, false, null);
                        frame = currentFrame(vm);
                        code = callee.data;
                        regs = vm.stack.ptr + frame.base;
                        pc = 0;
                        continue;
                    }
                }
                regs[insn.a] = try vm.construct(f, vm.stack[args_base .. args_base + argc], f);
            },
            .newspread => {
                frame.pc = pc;
                const f = regs[insn.b];
                const arr = asObject(regs[insn.b + 1]);
                const n = Vm.arrayLength(arr);
                const base = vm.sp();
                if (base + n + 1 > vm.stack.len) return vm.throwRangeError("Maximum call stack size exceeded");
                if (n > 0) @memcpy(vm.stack[base .. base + n], arr.elements.?.items()[0..n]);
                if (!vm.isConstructor(f)) return vm.throwTypeError("is not a constructor");
                regs[insn.a] = try vm.construct(f, vm.stack[base .. base + n], f);
            },
            .supercall, .supercallspread => {
                frame.pc = pc;
                const func = regs[insn.b];
                const new_target = regs[insn.b + 1];
                if (!func.isObject()) return vm.throwSyntaxError("'super' keyword unexpected here");
                const parent = try vm.getPrototypeOf(asObject(func));
                if (!vm.isConstructor(parent)) return vm.throwTypeError("Super constructor is not a constructor");
                var result: Value = undefined;
                if (insn.op == .supercall) {
                    const args_base: u32 = frame.base + insn.b + 2;
                    result = try vm.construct(parent, vm.stack[args_base .. args_base + insn.c], new_target);
                } else {
                    const arr = asObject(regs[insn.b + 2]);
                    const n = Vm.arrayLength(arr);
                    const base = vm.sp();
                    if (base + n + 1 > vm.stack.len) return vm.throwRangeError("Maximum call stack size exceeded");
                    if (n > 0) @memcpy(vm.stack[base .. base + n], arr.elements.?.items()[0..n]);
                    result = try vm.construct(parent, vm.stack[base .. base + n], new_target);
                }
                // The frame may have been reallocated by the construct.
                frame = currentFrame(vm);
                regs = vm.stack.ptr + frame.base;
                try initializeInstanceElements(vm, asObject(result), asObject(func));
                frame = currentFrame(vm);
                regs = vm.stack.ptr + frame.base;
                regs[insn.a] = result;
            },
            .ret, .retundef => {
                var v = if (insn.op == .ret) regs[insn.a] else Value.undefined_;
                if (frame.is_construct) {
                    if (!v.isObject()) {
                        const derived = if (frame.func) |fo| fo.internal(FunctionData).derived else false;
                        if (derived) {
                            if (!v.isUndefined()) {
                                frame.pc = pc;
                                return vm.throwTypeError("Derived constructors may only return object or undefined");
                            }
                            if (frame.this.isEmpty()) {
                                frame.pc = pc;
                                return vm.throwReferenceError("Must call super constructor in derived class before accessing 'this' or returning from derived constructor");
                            }
                        }
                        v = frame.this;
                    }
                }
                const done = popFrame(vm);
                if (done.entry or vm.frames.items.len < entry_depth) return v;
                frame = currentFrame(vm);
                code = frame.code.data;
                regs = vm.stack.ptr + frame.base;
                pc = frame.pc;
                regs[done.ret_dst] = v;
                if (vm.depth == 0) vm.safePoint();
            },

            // ----------------------------------------- environments
            .pushenv => {
                const info = code.scopes[insn.bc()];
                frame.env = try newEnv(vm, info, frame.env, frame.code);
            },
            .popenv => frame.env = frame.env.?.parent,
            .copyenv => {
                const e = frame.env.?;
                const ne = try newEnv(vm, e.info, e.parent, e.owner);
                @memcpy(ne.slots(), e.slots());
                frame.env = ne;
            },
            .pushwith => {
                frame.pc = pc;
                const o = try vm.toObject(regs[insn.a]);
                const e = try newEnv(vm, &realm.with_scope_info, frame.env, null);
                e.extra = &o.header;
                frame.env = e;
            },
            .getenv => regs[insn.a] = frame.env.?.up(insn.b).slots()[insn.c],
            .getenvchk => {
                const e = frame.env.?.up(insn.b);
                const v = e.slots()[insn.c];
                if (v.isEmpty()) {
                    frame.pc = pc;
                    return throwTdz(vm, e.info.names[insn.c]);
                }
                regs[insn.a] = v;
            },
            .setenv => {
                const e = frame.env.?.up(insn.b);
                vm.heap.writeBarrier(e.cell(), regs[insn.a]);
                e.slots()[insn.c] = regs[insn.a];
            },
            .setenvchk => {
                const e = frame.env.?.up(insn.b);
                if (e.slots()[insn.c].isEmpty()) {
                    frame.pc = pc;
                    return throwTdz(vm, e.info.names[insn.c]);
                }
                vm.heap.writeBarrier(e.cell(), regs[insn.a]);
                e.slots()[insn.c] = regs[insn.a];
            },
            .chkconst => {
                frame.pc = pc;
                const e = frame.env.?.up(insn.b);
                if (e.slots()[insn.c].isEmpty()) return throwTdz(vm, e.info.names[insn.c]);
                return vm.throwTypeError("Assignment to constant variable.");
            },
            .chktdz => if (regs[insn.a].isEmpty()) {
                frame.pc = pc;
                return throwTdz(vm, asString(code.consts[insn.bc()]));
            },
            .getglobal => {
                const site = &code.globals[insn.bc()];
                if (site.ic.shape == @as(*anyopaque, @ptrCast(vm.global.shape)) and site.ic.holder == @as(?*anyopaque, @ptrFromInt(vm.global_lex_epoch))) {
                    regs[insn.a] = vm.global.slot(site.ic.slot).*;
                    continue;
                }
                frame.pc = pc;
                regs[insn.a] = try getGlobal(vm, site, false);
            },
            .typeofglobal => {
                frame.pc = pc;
                regs[insn.a] = strValue(vm.typeOf(try getGlobal(vm, &code.globals[insn.bc()], true)));
            },
            .setglobal, .setglobalstrict => {
                frame.pc = pc;
                try setGlobal(vm, &code.globals[insn.bc()], regs[insn.a], insn.op == .setglobalstrict);
            },
            .getname => {
                frame.pc = pc;
                regs[insn.a] = (try getName(vm, frame, asString(code.consts[insn.bc()]), false)).v;
            },
            .getnamethis => {
                frame.pc = pc;
                const r = try getName(vm, frame, asString(code.consts[insn.bc()]), false);
                regs[insn.a] = r.v;
                regs[insn.a + 1] = r.this;
            },
            .typeofname => {
                frame.pc = pc;
                regs[insn.a] = strValue(vm.typeOf((try getName(vm, frame, asString(code.consts[insn.bc()]), true)).v));
            },
            .setname => {
                frame.pc = pc;
                try setName(vm, frame, asString(code.consts[insn.bc()]), regs[insn.a], code.strict);
            },
            .initname => {
                frame.pc = pc;
                try initName(vm, frame, asString(code.consts[insn.bc()]), regs[insn.a]);
            },
            .delname => {
                frame.pc = pc;
                regs[insn.a] = Value.fromBool(try deleteName(vm, frame, asString(code.consts[insn.bc()])));
            },
            .declvar => {
                frame.pc = pc;
                try declareVar(vm, frame, asString(code.consts[insn.bc()]), null);
            },
            .declfunc => {
                frame.pc = pc;
                try declareVar(vm, frame, asString(code.consts[insn.b]), regs[insn.c]);
            },
            .decllex => {
                frame.pc = pc;
                try declareGlobalLexical(vm, asString(code.consts[insn.bc()]), insn.a != 0);
            },
            .initglobal => {
                frame.pc = pc;
                const site = &code.globals[insn.bc()];
                if (vm.global_lex.getPtr(site.name)) |lex| {
                    lex.v = regs[insn.a];
                } else {
                    _ = try vm.set(vm.global, .{ .atom = site.name }, regs[insn.a], vm.global.asValue());
                }
            },
            .initargs => {
                frame.pc = pc;
                regs[insn.a] = try realm.createArgumentsObject(vm, frame);
            },
            .initrest => {
                const from = insn.bc();
                const n: u32 = if (frame.argc > from) frame.argc - from else 0;
                const arr = try vm.arrayFromList(vm.stack[frame.args_base + from .. frame.args_base + from + n]);
                regs[insn.a] = arr.asValue();
            },

            // ------------------------------------------- exceptions
            .throw => {
                frame.pc = pc;
                return vm.throwValue(regs[insn.a]);
            },
            .throwref => {
                frame.pc = pc;
                return throwNamed(vm, .ReferenceError, asString(code.consts[insn.bc()]), " is not defined");
            },
            .throwtype => {
                frame.pc = pc;
                var buf: [256]u8 = undefined;
                var fba = std.heap.FixedBufferAllocator.init(&buf);
                const msg = vm.utf8(asString(code.consts[insn.bc()]), fba.allocator()) catch "type error";
                return vm.throwTypeError(msg);
            },
            .pushtry => try vm.handlers.append(vm.meta, .{ .pc = insn.bc(), .reg = insn.a, .env = frame.env, .frame = @intCast(vm.frames.items.len - 1) }),
            .poptry => _ = vm.handlers.pop(),

            // -------------------------------------------- iteration
            .iter => {
                frame.pc = pc;
                const rec = try vm.getIterator(regs[insn.b]);
                regs[insn.a] = rec.iterator;
                regs[insn.a + 1] = rec.next;
            },
            .iterasync => {
                frame.pc = pc;
                const rec = try realm.getAsyncIterator(vm, regs[insn.b]);
                regs[insn.a] = rec.iterator;
                regs[insn.a + 1] = rec.next;
            },
            .iternext => {
                frame.pc = pc;
                const it = regs[insn.b];
                const next = regs[insn.b + 1];
                // The array fast path: the intrinsic array iterator over a
                // plain array with an untouched prototype.
                if (realm.arrayIteratorFast(vm, it, next)) |v| {
                    regs[insn.a] = v;
                    continue;
                }
                var rec = Vm.IteratorRecord{ .iterator = it, .next = next };
                const v = vm.iteratorStepValue(&rec) catch |e| {
                    regs[insn.b + 1] = Value.empty; // done: no close
                    return e;
                };
                if (v) |val| {
                    regs[insn.a] = val;
                } else {
                    regs[insn.b + 1] = Value.empty;
                    regs[insn.a] = Value.empty;
                }
            },
            .iterclose => {
                if (!regs[insn.a + 1].isEmpty()) {
                    frame.pc = pc;
                    regs[insn.a + 1] = Value.empty;
                    try vm.iteratorClose(.{ .iterator = regs[insn.a], .next = Value.undefined_ });
                }
            },
            .iterclosethrow => {
                if (!regs[insn.a + 1].isEmpty()) {
                    regs[insn.a + 1] = Value.empty;
                    vm.iteratorCloseThrow(.{ .iterator = regs[insn.a], .next = Value.undefined_ });
                }
            },
            .forin => {
                frame.pc = pc;
                regs[insn.a] = try realm.createForInIterator(vm, regs[insn.b]);
            },
            .forinnext => {
                frame.pc = pc;
                regs[insn.a] = try realm.forInNext(vm, regs[insn.b]);
            },

            // ------------------------------------------- coroutines
            .genstart => {
                // Parameters are bound: make the generator object (its
                // prototype read now) and hand it back to the caller.
                const co_obj = try realm.createGeneratorObject(vm, frame.func.?);
                frame.co = co_obj;
                try suspendFrame(vm, frame, pc, 0xFFFF, 0xFFFF);
                co_obj.internal(vmod.CoroutineData).state = vmod.CoroutineData.suspended_start;
                return co_obj.asValue();
            },
            .modinit => {
                const co_obj = frame.co.?;
                try suspendFrame(vm, frame, pc, 0xFFFF, 0xFFFF);
                co_obj.internal(vmod.CoroutineData).state = vmod.CoroutineData.suspended_start;
                return Value.undefined_;
            },
            .getimport => {
                frame.pc = pc;
                const e = frame.env.?.up(insn.b);
                regs[insn.a] = try modules.readImport(vm, e.slots()[insn.c], e.info.names[insn.c]);
            },
            .yield, .yieldraw => {
                const co_obj = frame.co.?;
                const co = co_obj.internal(vmod.CoroutineData);
                co.yielded = regs[insn.b];
                co.yield_raw = insn.op == .yieldraw;
                try suspendFrame(vm, frame, pc, insn.a, insn.c);
                co.state = vmod.CoroutineData.suspended_yield;
                return Value.undefined_;
            },
            .await => {
                frame.pc = pc;
                const co_obj = frame.co.?;
                const co = co_obj.internal(vmod.CoroutineData);
                // PromiseResolve first: its errors are thrown here, in the body.
                const p = try realm.promiseResolve(vm, regs[insn.b]);
                co.yielded = p;
                try suspendFrame(vm, frame, pc, insn.a, insn.c);
                co.state = vmod.CoroutineData.suspended_await;
                try realm.awaitValue(vm, co_obj, p);
                return Value.undefined_;
            },
            .ystep => {
                frame.pc = pc;
                regs[insn.a] = try yieldStarStep(vm, regs[insn.b], regs[insn.b + 1], @intCast(regs[insn.b + 2].asInt()), regs[insn.b + 3]);
            },
            .iterstep => {
                frame.pc = pc;
                regs[insn.a] = try vm.call(regs[insn.b + 1], regs[insn.b], &.{});
            },
            .iterresult => {
                frame.pc = pc;
                const r = regs[insn.b];
                if (!r.isObject()) return vm.throwTypeError("Iterator result is not an object");
                const done = vm.toBoolean(try vm.get(asObject(r), .{ .atom = vm.atoms.done }, r));
                regs[insn.a] = if (done) Value.empty else try vm.get(asObject(r), .{ .atom = vm.atoms.value }, r);
            },
            .iterdone => {
                frame.pc = pc;
                const r = regs[insn.b];
                if (!r.isObject()) return vm.throwTypeError("Iterator result is not an object");
                regs[insn.a] = Value.fromBool(vm.toBoolean(try vm.get(asObject(r), .{ .atom = vm.atoms.done }, r)));
            },
            .itervalue => {
                frame.pc = pc;
                const r = regs[insn.b];
                if (!r.isObject()) return vm.throwTypeError("Iterator result is not an object");
                regs[insn.a] = try vm.get(asObject(r), .{ .atom = vm.atoms.value }, r);
            },
            .iterreturn => {
                frame.pc = pc;
                if (regs[insn.b + 1].isEmpty()) {
                    regs[insn.a] = Value.undefined_;
                } else {
                    regs[insn.b + 1] = Value.empty;
                    const ret = try vm.getMethod(regs[insn.b], .{ .atom = vm.atoms.@"return" });
                    regs[insn.a] = if (ret.isUndefined()) Value.undefined_ else try vm.call(ret, regs[insn.b], &.{});
                }
            },
            .chkobj => if (!regs[insn.a].isObject()) {
                frame.pc = pc;
                return vm.throwTypeError("Iterator result is not an object");
            },

            // ------------------------------------------------- misc
            .eval => {
                frame.pc = pc;
                const f = regs[insn.b];
                const args_base: u32 = frame.base + insn.b + 2;
                const args = vm.stack[args_base .. args_base + insn.c];
                if (f.isObject() and asObject(f) == vm.intrinsics.eval) {
                    regs[insn.a] = try directEval(vm, frame, if (args.len > 0) args[0] else Value.undefined_, code.strict);
                } else {
                    regs[insn.a] = try callSlow(vm, f, Value.undefined_, args, pc);
                }
            },
            .importmeta => {
                frame.pc = pc;
                regs[insn.a] = try modules.importMeta(vm, code);
            },
            .importcall => {
                frame.pc = pc;
                regs[insn.a] = try modules.dynamicImport(vm, code, regs[insn.b]);
            },
        }
    }
}

/// One step of yield* (§27.5.3.7 step 7): forward the resumption to
/// the inner iterator's next/throw/return. Returns the inner result
/// object, or the hole when a `return` resumption finds no `return`
/// method (the outer generator then returns the received value).
fn yieldStarStep(vm: *Vm, iterator: Value, next: Value, kind: u8, received: Value) Error!Value {
    switch (kind) {
        0 => return vm.call(next, iterator, &.{received}),
        1 => {
            const thr = try vm.getMethod(iterator, .{ .atom = vm.atoms.throw });
            if (thr.isUndefined()) {
                // No throw method: close the iterator, then a TypeError.
                try vm.iteratorClose(.{ .iterator = iterator, .next = next });
                return vm.throwTypeError("The iterator does not provide a 'throw' method");
            }
            return vm.call(thr, iterator, &.{received});
        },
        else => {
            const ret = try vm.getMethod(iterator, .{ .atom = vm.atoms.@"return" });
            if (ret.isUndefined()) return Value.empty;
            return vm.call(ret, iterator, &.{received});
        },
    }
}

fn throwTdz(vm: *Vm, name: *String) Error {
    return throwNamed(vm, .ReferenceError, name, " before initialization");
}

fn throwNamed(vm: *Vm, kind: vmod.ErrorKind, name: *String, suffix: []const u8) Error {
    var buf: [256]u8 = undefined;
    var fba = std.heap.FixedBufferAllocator.init(&buf);
    const n = vm.utf8(name, fba.allocator()) catch "";
    var out: [300]u8 = undefined;
    const msg = std.fmt.bufPrint(&out, "{s}{s}", .{ n, suffix }) catch "error";
    return vm.throwError(kind, msg);
}

/// A key as a value a register holds (index → int, else string/symbol).
fn keyValue(vm: *Vm, k: Key) Error!Value {
    return switch (k) {
        .index => |i| if (i <= std.math.maxInt(i32)) Value.fromInt(@intCast(i)) else strValue(try vm.toString(Value.fromF64(@floatFromInt(i)))),
        .atom => |s| strValue(s),
        .symbol => |s| Value.fromCell(&s.header),
    };
}

pub fn newEnv(vm: *Vm, info: *const bytecode.ScopeInfo, parent: ?*Env, owner: ?*Code) Error!*Env {
    const n = info.names.len;
    const c = try vm.heap.alloc(.env, @sizeOf(Env) + n * @sizeOf(Value));
    const e = c.as(Env);
    e.parent = parent;
    e.info = info;
    e.extra = null;
    e.owner = owner;
    e.count = @intCast(n);
    for (e.slots(), 0..) |*s, i| s.* = if (info.lexical[i]) Value.empty else Value.undefined_;
    return e;
}

/// A call that is not a plain JS-to-JS call: natives, bound
/// functions, class constructors (an error), generators, proxies.
fn callSlow(vm: *Vm, f: Value, this: Value, args: []const Value, pc: u32) Error!Value {
    _ = pc;
    if (!vm.isCallable(f)) return vm.throwTypeError("is not a function");
    return callValue(vm, f, this, args);
}

/// A slow property read with cache fill.
fn getPropSlow(vm: *Vm, obj: Value, site: *bytecode.PropSite) Error!Value {
    const key: Key = .{ .atom = site.key };
    if (obj.isObject()) {
        const o = asObject(obj);
        // Walk the chain for a cacheable data property.
        var cur: *Object = o;
        var depth: u32 = 0;
        while (true) : (depth += 1) {
            if (cur.class == .proxy or cur.class == .typed_array or cur.class == .namespace) break;
            if (cur.class == .array and site.key == vm.atoms.length) return Value.fromF64(@floatFromInt(Vm.arrayLength(cur)));
            if (cur.class == .arguments and cur == o) break;
            if (try vm.objects.getOwn(cur, key)) |own| {
                if (own.attrs.accessor) {
                    const acc = own.val.asCell().as(Accessor);
                    if (acc.get.isUndefined()) return Value.undefined_;
                    return vm.call(acc.get, obj, &.{});
                }
                if (own.slot) |slot| {
                    if (!cur.shape.dictionary and !o.shape.dictionary) {
                        site.ic.shape = @ptrCast(o.shape);
                        site.ic.slot = slot;
                        if (cur == o) {
                            site.ic.holder = null;
                        } else {
                            site.ic.holder = @ptrCast(cur);
                            site.ic.holder_shape = @ptrCast(cur.shape);
                        }
                    }
                }
                return own.val;
            }
            const p = cur.shape.proto;
            if (!p.isObject()) return Value.undefined_;
            cur = asObject(p);
        }
        return vm.get(o, key, obj);
    }
    if (obj.isString() and site.key == vm.atoms.length) return Value.fromInt(@intCast(asString(obj).len));
    return vm.getV(obj, key);
}

fn setPropSlow(vm: *Vm, obj: Value, site: *bytecode.PropSite, v: Value, strict: bool) Error!void {
    const key: Key = .{ .atom = site.key };
    if (obj.isObject()) {
        const o = asObject(obj);
        if (o.class != .proxy and o.class != .array and o.class != .arguments and o.class != .typed_array) {
            if (try vm.objects.getOwn(o, key)) |own| {
                if (!own.attrs.accessor and own.attrs.writable and own.slot != null) {
                    if (!o.shape.dictionary) {
                        site.ic.shape = @ptrCast(o.shape);
                        site.ic.slot = own.slot.?;
                        site.ic.holder = null;
                    }
                    vm.heap.writeBarrier(&o.header, v);
                    o.slot(own.slot.?).* = v;
                    return;
                }
            }
        }
    }
    try vm.setV(obj, key, v, strict);
}

fn getElem(vm: *Vm, obj: Value, key: Value) Error!Value {
    if (obj.isNullish()) return vm.throwTypeErrorFmt("Cannot read properties of {s}", .{if (obj.isNull()) "null" else "undefined"});
    const k = try vm.toPropertyKey(key);
    return vm.getV(obj, k);
}

fn setElem(vm: *Vm, obj: Value, key: Value, v: Value, strict: bool) Error!void {
    if (obj.isNullish()) return vm.throwTypeErrorFmt("Cannot set properties of {s}", .{if (obj.isNull()) "null" else "undefined"});
    const k = try vm.toPropertyKey(key);
    try vm.setV(obj, k, v, strict);
}

/// SetFunctionName for an anonymous function defined under a key.
fn nameAnonymous(vm: *Vm, v: Value, key: Key, prefix: ?[]const u8) Error!void {
    if (!v.isObject()) return;
    const o = asObject(v);
    if (o.class != .function) return;
    const fd = o.internal(FunctionData);
    const code = fd.code orelse return;
    if (code.data.name != null) return;
    // Already named by an earlier definition.
    if (try vm.objects.getOwn(o, .{ .atom = vm.atoms.name })) |own| {
        if (!own.val.isString() or asString(own.val).len != 0) {
            if (prefix == null) return;
            if (asString(own.val).len != 0) return;
        }
    }
    var name: *String = switch (key) {
        .atom => |s| s,
        .index => |i| try vm.toString(Value.fromF64(@floatFromInt(i))),
        .symbol => |s| blk: {
            if (s.description) |d| {
                const open = try vm.strings.fromUtf8("[");
                const close = try vm.strings.fromUtf8("]");
                break :blk try vm.strings.concat(try vm.strings.concat(open, d), close);
            }
            break :blk vm.atoms.empty;
        },
    };
    if (prefix) |p| name = try vm.strings.concat(try vm.strings.fromUtf8(p), name);
    _ = try vm.objects.defineOwnForce(o, .{ .atom = vm.atoms.name }, strValue(name), .{ .writable = false, .enumerable = false, .configurable = true });
}

fn getPrivate(vm: *Vm, target: Value, key: Value) Error!Value {
    if (!target.isObject()) return vm.throwTypeError("Cannot read private member from a non-object");
    const o = asObject(target);
    const own = (try vm.objects.getOwn(o, .{ .symbol = Vm.asSymbol(key) })) orelse return vm.throwTypeError("Cannot read private member from an object whose class did not declare it");
    if (own.attrs.accessor) {
        const acc = own.val.asCell().as(Accessor);
        if (acc.get.isUndefined()) return vm.throwTypeError("Private accessor was defined without a getter");
        return vm.call(acc.get, target, &.{});
    }
    return own.val;
}

fn setPrivate(vm: *Vm, target: Value, key: Value, v: Value) Error!void {
    if (!target.isObject()) return vm.throwTypeError("Cannot write private member to a non-object");
    const o = asObject(target);
    const k: Key = .{ .symbol = Vm.asSymbol(key) };
    const own = (try vm.objects.getOwn(o, k)) orelse return vm.throwTypeError("Cannot write private member to an object whose class did not declare it");
    if (own.attrs.accessor) {
        const acc = own.val.asCell().as(Accessor);
        if (acc.set.isUndefined()) return vm.throwTypeError("Private accessor was defined without a setter");
        _ = try vm.call(acc.set, target, &.{v});
        return;
    }
    if (!own.attrs.writable) return vm.throwTypeError("Private method is not writable");
    vm.heap.writeBarrier(&o.header, v);
    o.slot(own.slot.?).* = v;
}

/// GetTemplateObject (§13.2.8.4).
fn templateObject(vm: *Vm, site: *bytecode.TemplateSite) Error!Value {
    const cooked = try vm.newArray(0);
    const raw = try vm.newArray(0);
    for (site.cooked, 0..) |cs, i| {
        try vm.arrayPush(cooked, if (cs) |s| strValue(s) else Value.undefined_);
        try vm.arrayPush(raw, strValue(site.raw[i]));
    }
    try realm.freezeArray(vm, raw);
    _ = try vm.objects.defineOwn(cooked, .{ .atom = vm.atoms.raw }, raw.asValue(), .frozen);
    try realm.freezeArray(vm, cooked);
    return cooked.asValue();
}

/// ClassDefinitionEvaluation's constructor and prototype setup.
fn makeClass(vm: *Vm, parent: Value, ctor_code: *Code, env: ?*Env) Error!Value {
    var proto_parent: Value = vm.intrinsics.object_prototype.asValue();
    var ctor_parent: Value = vm.intrinsics.function_prototype.asValue();
    if (!parent.isEmpty()) {
        if (parent.isNull()) {
            proto_parent = Value.null_;
        } else {
            if (!vm.isConstructor(parent)) return vm.throwTypeError("Class extends value is not a constructor or null");
            const pp = try vm.get(asObject(parent), .{ .atom = vm.atoms.prototype }, parent);
            if (!pp.isObject() and !pp.isNull()) return vm.throwTypeError("Class extends value does not have valid prototype property");
            proto_parent = pp;
            ctor_parent = parent;
        }
    }
    const proto = try vm.objects.create(proto_parent, .ordinary, 0);
    const f = try vm.newFunction(ctor_code, env, proto.asValue());
    _ = try vm.objects.setProto(f, ctor_parent);
    // A class's prototype property is not writable.
    _ = try vm.objects.defineOwnForce(f, .{ .atom = vm.atoms.prototype }, proto.asValue(), .frozen);
    _ = try vm.objects.defineOwn(proto, .{ .atom = vm.atoms.constructor }, f.asValue(), .hidden);
    return f.asValue();
}

// ------------------------------------------------------------ globals

fn getGlobal(vm: *Vm, site: *bytecode.GlobalSite, for_typeof: bool) Error!Value {
    if (vm.global_lex.get(site.name)) |lex| {
        if (lex.v.isEmpty()) return throwTdz(vm, site.name);
        return lex.v;
    }
    const key: Key = .{ .atom = site.name };
    if (try vm.objects.getOwn(vm.global, key)) |own| {
        if (!own.attrs.accessor) {
            if (own.slot) |slot| if (!vm.global.shape.dictionary) {
                site.ic.shape = @ptrCast(vm.global.shape);
                site.ic.slot = slot;
                site.ic.holder = @ptrFromInt(vm.global_lex_epoch);
            };
            return own.val;
        }
    }
    if (try vm.hasProperty(vm.global, key)) return vm.get(vm.global, key, vm.global.asValue());
    if (for_typeof) return Value.undefined_;
    return throwNamed(vm, .ReferenceError, site.name, " is not defined");
}

fn setGlobal(vm: *Vm, site: *bytecode.GlobalSite, v: Value, strict: bool) Error!void {
    if (vm.global_lex.getPtr(site.name)) |lex| {
        if (lex.v.isEmpty()) return throwTdz(vm, site.name);
        if (lex.is_const) return vm.throwTypeError("Assignment to constant variable.");
        lex.v = v;
        return;
    }
    const key: Key = .{ .atom = site.name };
    if (strict and !try vm.hasProperty(vm.global, key)) return throwNamed(vm, .ReferenceError, site.name, " is not defined");
    const ok = try vm.set(vm.global, key, v, vm.global.asValue());
    if (!ok and strict) return vm.throwTypeError("Cannot assign to read only property");
}

const NameResult = struct { v: Value, this: Value = Value.undefined_ };

/// Resolve a name through the runtime environment chain (with, eval).
fn getName(vm: *Vm, frame: *Frame, name: *String, for_typeof: bool) Error!NameResult {
    var cur: ?*Env = frame.env;
    while (cur) |e| : (cur = e.parent) {
        if (e.info.is_with) {
            const o: *Object = @ptrCast(@alignCast(e.extra.?));
            if (try withHas(vm, o, name)) return .{ .v = try vm.get(o, .{ .atom = name }, o.asValue()), .this = o.asValue() };
            continue;
        }
        for (e.info.names, 0..) |n, i| if (n == name) {
            const v = e.slots()[i];
            if (v.isEmpty()) return throwTdz(vm, name);
            return .{ .v = v };
        };
        if (e.extra) |x| {
            const o: *Object = @ptrCast(@alignCast(x));
            if (try vm.objects.getOwn(o, .{ .atom = name })) |own| return .{ .v = own.val };
        }
    }
    // Implicit bindings without a slot: the frame's.
    if (name == vm.atoms.this_) {
        if (frame.this.isEmpty()) return vm.throwReferenceError("Must call super constructor in derived class before accessing 'this'");
        return .{ .v = frame.this };
    }
    if (name == vm.atoms.new_target) return .{ .v = frame.new_target };
    if (name == vm.atoms.home) return .{ .v = if (frame.func) |f| f.internal(FunctionData).home_object else Value.undefined_ };
    if (name == vm.atoms.func) return .{ .v = if (frame.func) |f| f.asValue() else Value.undefined_ };
    if (vm.global_lex.get(name)) |lex| {
        if (lex.v.isEmpty()) return throwTdz(vm, name);
        return .{ .v = lex.v };
    }
    const key: Key = .{ .atom = name };
    if (try vm.hasProperty(vm.global, key)) return .{ .v = try vm.get(vm.global, key, vm.global.asValue()) };
    if (for_typeof) return .{ .v = Value.undefined_ };
    return throwNamed(vm, .ReferenceError, name, " is not defined");
}

/// HasBinding of an object environment: the property, minus
/// @@unscopables.
fn withHas(vm: *Vm, o: *Object, name: *String) Error!bool {
    if (!try vm.hasProperty(o, .{ .atom = name })) return false;
    const uns = try vm.get(o, .{ .symbol = vm.symbols.unscopables }, o.asValue());
    if (uns.isObject()) {
        const blocked = try vm.get(asObject(uns), .{ .atom = name }, uns);
        if (vm.toBoolean(blocked)) return false;
    }
    return true;
}

fn setName(vm: *Vm, frame: *Frame, name: *String, v: Value, strict: bool) Error!void {
    var cur: ?*Env = frame.env;
    while (cur) |e| : (cur = e.parent) {
        if (e.info.is_with) {
            const o: *Object = @ptrCast(@alignCast(e.extra.?));
            if (try withHas(vm, o, name)) {
                const ok = try vm.set(o, .{ .atom = name }, v, o.asValue());
                if (!ok and strict) return vm.throwTypeError("Cannot assign to read only property");
                return;
            }
            continue;
        }
        for (e.info.names, 0..) |n, i| if (n == name) {
            if (e.slots()[i].isEmpty()) return throwTdz(vm, name);
            if (e.info.consts[i]) {
                if (strict or !e.info.lexical[i] or true) {
                    // A named function expression's own name is a silent
                    // non-write in sloppy code; consts throw.
                    if (e.info.lexical[i]) return vm.throwTypeError("Assignment to constant variable.");
                    if (strict) return vm.throwTypeError("Assignment to constant variable.");
                    return;
                }
            }
            vm.heap.writeBarrier(e.cell(), v);
            e.slots()[i] = v;
            return;
        };
        if (e.extra) |x| {
            const o: *Object = @ptrCast(@alignCast(x));
            if ((try vm.objects.getOwn(o, .{ .atom = name })) != null) {
                _ = try vm.objects.defineOwn(o, .{ .atom = name }, v, .default);
                return;
            }
        }
    }
    if (name == vm.atoms.this_) {
        if (!frame.this.isEmpty()) return vm.throwReferenceError("Super constructor may only be called once");
        frame.this = v;
        return;
    }
    if (vm.global_lex.getPtr(name)) |lex| {
        if (lex.v.isEmpty()) return throwTdz(vm, name);
        if (lex.is_const) return vm.throwTypeError("Assignment to constant variable.");
        lex.v = v;
        return;
    }
    const key: Key = .{ .atom = name };
    if (strict and !try vm.hasProperty(vm.global, key)) return throwNamed(vm, .ReferenceError, name, " is not defined");
    const ok = try vm.set(vm.global, key, v, vm.global.asValue());
    if (!ok and strict) return vm.throwTypeError("Cannot assign to read only property");
}

/// InitializeBinding by name: the nearest declarative slot, else the
/// global lexical record, else the global object.
fn initName(vm: *Vm, frame: *Frame, name: *String, v: Value) Error!void {
    var cur: ?*Env = frame.env;
    while (cur) |e| : (cur = e.parent) {
        if (e.info.is_with) continue;
        for (e.info.names, 0..) |n, i| if (n == name) {
            vm.heap.writeBarrier(e.cell(), v);
            e.slots()[i] = v;
            return;
        };
        if (e.extra) |x| {
            const o: *Object = @ptrCast(@alignCast(x));
            if ((try vm.objects.getOwn(o, .{ .atom = name })) != null) {
                _ = try vm.objects.defineOwn(o, .{ .atom = name }, v, .default);
                return;
            }
        }
    }
    if (vm.global_lex.getPtr(name)) |lex| {
        lex.v = v;
        return;
    }
    _ = try vm.set(vm.global, .{ .atom = name }, v, vm.global.asValue());
}

fn deleteName(vm: *Vm, frame: *Frame, name: *String) Error!bool {
    var cur: ?*Env = frame.env;
    while (cur) |e| : (cur = e.parent) {
        if (e.info.is_with) {
            const o: *Object = @ptrCast(@alignCast(e.extra.?));
            if (try withHas(vm, o, name)) return vm.deleteProperty(o, .{ .atom = name });
            continue;
        }
        for (e.info.names) |n| if (n == name) return false;
        if (e.extra) |x| {
            const o: *Object = @ptrCast(@alignCast(x));
            if ((try vm.objects.getOwn(o, .{ .atom = name })) != null) return vm.objects.delete(o, .{ .atom = name });
        }
    }
    if (vm.global_lex.contains(name)) return false;
    const key: Key = .{ .atom = name };
    if (try vm.hasOwnProperty(vm.global, key)) return vm.deleteProperty(vm.global, key);
    return true;
}

/// A script's top-level let/const/class: a global lexical binding in
/// its temporal dead zone (GlobalDeclarationInstantiation steps 5–13).
fn declareGlobalLexical(vm: *Vm, name: *String, is_const: bool) Error!void {
    if (vm.global_lex.contains(name)) return throwNamed(vm, .SyntaxError, name, " has already been declared");
    if (try vm.getOwnProperty(vm.global, .{ .atom = name })) |own| {
        if (!own.attrs.configurable) return throwNamed(vm, .SyntaxError, name, " has already been declared");
    }
    try vm.global_lex.put(vm.meta, name, .{ .v = Value.empty, .is_const = is_const });
    vm.global_lex_epoch += 1;
}

/// Eval code's `var`/function declaration: into the nearest function
/// environment's dictionary, or the global object.
fn declareVar(vm: *Vm, frame: *Frame, name: *String, init: ?Value) Error!void {
    var cur: ?*Env = frame.env;
    while (cur) |e| : (cur = e.parent) {
        if (e.info.is_with) continue;
        if (e.info.is_function) {
            // An existing slot binding of the name: the declaration is a no-op
            // (or the function assignment).
            for (e.info.names, 0..) |n, i| if (n == name) {
                if (init) |v| {
                    vm.heap.writeBarrier(e.cell(), v);
                    e.slots()[i] = v;
                }
                return;
            };
            if (e.extra == null) {
                const o = try vm.objects.create(Value.null_, .ordinary, 0);
                e.extra = &o.header;
            }
            const o: *Object = @ptrCast(@alignCast(e.extra.?));
            if (init) |v| {
                _ = try vm.objects.defineOwn(o, .{ .atom = name }, v, .default);
            } else if ((try vm.objects.getOwn(o, .{ .atom = name })) == null) {
                _ = try vm.objects.defineOwn(o, .{ .atom = name }, Value.undefined_, .default);
            }
            return;
        }
    }
    // Global: CreateGlobalVarBinding / CreateGlobalFunctionBinding.
    const key: Key = .{ .atom = name };
    if (vm.global_lex.contains(name)) return vm.throwSyntaxError("Identifier has already been declared");
    if (init) |v| {
        const existing = try vm.getOwnProperty(vm.global, key);
        if (existing == null or existing.?.attrs.configurable) {
            _ = try vm.defineOwnProperty(vm.global, key, .{ .value = v, .writable = true, .enumerable = true, .configurable = true }, true);
        } else {
            _ = try vm.defineOwnProperty(vm.global, key, .{ .value = v }, true);
        }
    } else if (!try vm.hasOwnProperty(vm.global, key)) {
        if (!vm.global.extensible) return vm.throwTypeError("Cannot define global variable");
        _ = try vm.defineOwnProperty(vm.global, key, .{ .value = Value.undefined_, .writable = true, .enumerable = true, .configurable = true }, true);
    }
}

/// PerformEval for a direct eval (§19.2.1.1).
fn directEval(vm: *Vm, frame: *Frame, x: Value, strict_caller: bool) Error!Value {
    if (!x.isString()) return x;
    const src = try vm.utf8(asString(x), vm.meta);
    defer vm.meta.free(src);
    const in_function = frame.func != null;
    const fd: ?*FunctionData = if (frame.func) |f| f.internal(FunctionData) else null;
    const kind: ?bytecode.FunctionKind = if (fd != null and fd.?.code != null) fd.?.code.?.data.kind else null;
    // The enclosing classes' private names, from the environment chain.
    var privates: std.ArrayList([]const u8) = .empty;
    defer {
        for (privates.items) |n| vm.meta.free(n);
        privates.deinit(vm.meta);
    }
    var cur: ?*Env = frame.env;
    while (cur) |e| : (cur = e.parent) {
        for (e.info.names) |n| if (n.latin1()) |bytes| if (bytes.len > 0 and bytes[0] == '#') {
            try privates.append(vm.meta, try vm.meta.dupe(u8, bytes));
        };
    }
    const is_arrow = kind == .arrow or kind == .async_arrow;
    const code = compiler.compile(vm.meta, &vm.heap, &vm.strings, src, .{
        .strict = strict_caller,
        .eval_env = frame.env,
        .eval_ctx = .{
            .eval = true,
            .global = !in_function,
            .strict = strict_caller,
            .has_this_function = in_function and !is_arrow,
            .allow_super = fd != null and fd.?.home_object.isObject(),
            .allow_super_call = kind == .derived_constructor,
            .allow_new_target = in_function and !is_arrow,
            .no_arguments = kind == .field_init or kind == .static_block,
            .private_names = privates.items,
        },
        .name = "<eval>",
    }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return vm.throwSyntaxError(compiler.last_error),
    };
    return runScript(vm, code, frame.this, frame.env, frame.func, frame.new_target);
}

const interp_cases = [_]struct { src: []const u8, want: f64 }{
    .{ .src = "1 + 2 * 3", .want = 7 },
    .{ .src = "var x = 10; function f(a, b) { return a * b + x; } f(2, 3)", .want = 16 },
    .{ .src = "function mk(n) { return function () { return n += 1; }; } var c = mk(5); c(); c()", .want = 7 },
    .{ .src = "let s = 0; for (let i = 0; i < 100; i++) { if (i % 2) continue; s += i; } s", .want = 2450 },
    .{ .src = "try { throw 5; } catch (e) { e * 2 }", .want = 10 },
    .{ .src = "var o = { a: 1, b: { c: 2 } }; o.a + o.b.c + o['a']", .want = 4 },
    .{ .src = "var a = [1, 2, 3]; a.push(4); a.length + a[3]", .want = 8 },
    .{ .src = "class A { constructor(x) { this.x = x; } get dbl() { return this.x * 2; } } class B extends A { constructor() { super(21); } } new B().dbl", .want = 42 },
    .{ .src = "var r = 0; (function () { try { return 1; } finally { r = 2; } })(); r", .want = 2 },
    .{ .src = "var [p, , q = 9, ...rest] = [1, 2, undefined, 4, 5]; p + q + rest.length", .want = 12 },
    .{ .src = "var {m, n: {k}} = {m: 3, n: {k: 4}}; m + k", .want = 7 },
    .{ .src = "var t = 0; for (var k in {a: 1, b: 2}) t += k.length; t", .want = 2 },
    .{ .src = "var t = 0; for (const v of [3, 4]) t += v; t", .want = 7 },
    .{ .src = "var f = (a, ...r) => a + r.length; f(1, 2, 3)", .want = 3 },
    .{ .src = "'abc'.length + `x${1 + 1}y`.length", .want = 6 },
    .{ .src = "switch (3) { case 1: 10; break; case 3: 30; default: 40 }", .want = 40 },
    .{ .src = "var n = 0; label: for (;;) { for (;;) { n++; if (n > 3) break label; } } n", .want = 4 },
    .{ .src = "typeof undefinedVariable === 'undefined' ? 1 : 0", .want = 1 },
    .{ .src = "(function () { 'use strict'; return this === undefined ? 1 : 0; })()", .want = 1 },
    .{ .src = "var g = 0; function h() { eval('var zz = 7'); return zz; } h()", .want = 7 },
    .{ .src = "class P { #x = 3; static make() { return new P(); } get x() { return this.#x; } } P.make().x", .want = 3 },
    .{ .src = "JSON.parse(JSON.stringify({a: [1, {b: 2}]})).a[1].b + Object.keys({p: 1, q: 2}).length", .want = 4 },
    .{ .src = "[3, 1, 2].sort().map(function (v) { return v * 2; }).join('').length + 'héllo'.toUpperCase().indexOf('L')", .want = 5 },
    .{ .src = "function fa(a, b) { arguments[0] = 9; return a; } fa(1)", .want = 9 },
    .{ .src = "var w = 0; with ({v: 5}) { w = v; } w", .want = 5 },
    .{ .src = "var t = 0; for (let i = 0; i < 3; i++) { t += eval('i'); } t", .want = 3 },
    .{ .src = "function* g(a) { var x = yield a; try { yield x * 2; } finally { a = 100; } return a; } var it = g(1); var r = it.next().value * 10 + it.next(5).value; it.return(7); r", .want = 20 },
    .{ .src = "function* g() { yield* [1, 2]; return 3; } function* d() { const r = yield* g(); yield r; } var sum = 0; for (const v of d()) sum += v; sum", .want = 6 },
    .{ .src = "var out = 0; async function f(v) { const a = await v; return a + (await Promise.resolve(1)); } f(1).then(function (v) { out = v; }); out", .want = 0 },
    .{ .src = "var m = new Map([[1, 'a'], [-0, 'z']]); m.set(NaN, 'n'); var st = new Set([1, 1, 2]); st.add(3); var ks = ''; for (const [k] of m) ks += k; m.delete(1); ks.length + m.size + m.get(0).length + st.size + (st.has(2) ? 1 : 0) + new Set([1, 2]).union(new Set([2, 3])).size", .want = 15 },
    .{ .src = "var p = new Proxy({a: 1}, {get(t, k) { return k === 'b' ? 40 : t[k]; }, has() { return true; }}); var r = Proxy.revocable({}, {}); r.revoke(); var rv = 0; try { r.proxy.x; } catch (e) { rv = e instanceof TypeError ? 1 : 0; } p.a + p.b + ('zz' in p ? 1 : 0) + rv", .want = 43 },
    .{ .src = "var b = 2n ** 64n; var q = -7n / 2n; Number(b >> 60n) + Number(q) + Number(BigInt.asIntN(8, 255n)) + Number(BigInt('0x1f') & 0xfn) + (b > 1.8e19 ? 1 : 0) + (5n == 5 ? 1 : 0) + ((b + 1n).toString(16).length)", .want = 46 },
    .{ .src = "var d = new Date(2026, 8, 25, 10, 30, 15, 250); var u = Date.UTC(2000, 0, 1); d.getDay() + d.getMonth() + (d.toISOString() === '2026-09-25T10:30:15.250Z' ? 1 : 0) + (Date.parse(d.toString()) === d.getTime() - 250 ? 1 : 0) + (u === 946684800000 ? 1 : 0) + (Date.parse('Sat, 01 Jan 2000 00:00:00 GMT') === u ? 1 : 0) + (isNaN(new Date(8.64e15 + 1).getTime()) ? 1 : 0)", .want = 18 },
    .{ .src = "/(?<y>\\d{4})-(?<m>\\d\\d)/u.exec('on 2026-09-25').groups.m * 1 + 'a-b_c'.replace(/[-_]/g, ' ').split(' ').length + ('x'.match(/y/) === null ? 1 : 0)", .want = 13 },
    .{ .src = "var acc = 0; for (const x of [1, 2, 3, 4]) { if (x % 2) continue; acc += x; } outer: for (const a of [1, 2]) for (const c of [10, 20, 30]) { if (c === 20) continue outer; acc += c; } acc", .want = 26 },
    .{ .src = "var ta = new Int16Array([1, -2, 300]); var dv = new DataView(ta.buffer); ta.set([5], 2); Uint8Array.from('abc', c => c.charCodeAt(0)).length + ta[2] + dv.getInt16(2, true) + new Float32Array(ta).reduce((a, b) => a + b) + Atomics.add(ta, 0, 1) + ta[0] + new Uint8Array([200]).toBase64().length + (ta['1.5'] === undefined ? 1 : 0) + new Uint8Array(ta.buffer.transfer()).length + (ta.length === 0 ? 1 : 0)", .want = 25 },
    .{ .src = "function* gen() { yield 1; yield 2; yield 3; yield 4; } var closed = 0; var src = { next() { return { value: 7, done: false }; }, return() { closed++; return {}; } }; var h = Iterator.prototype.map.call(src, x => x + 1); h.next(); h.return(); gen().map(x => x * 2).filter(x => x > 2).take(2).toArray().length + gen().flatMap(x => [x, x]).drop(5).reduce((a, b) => a + b, 0) + Iterator.from('ab').toArray().length + Iterator.zip([[1, 2], [3]]).toArray().length + Iterator.concat([1], [2, 3]).toArray().length + gen().chunks(3).toArray()[1][0] + closed + (gen().find(x => x === 3) === 3 ? 1 : 0) + (new (class extends Iterator { next() { return { done: true }; } })().toArray().length)", .want = 25 },
};

fn runCases(vm: *Vm) !void {
    for (interp_cases) |c| {
        const code = compiler.compile(std.testing.allocator, &vm.heap, &vm.strings, c.src, .{}) catch |e| {
            std.debug.print("compile failed: {s}: {s}\n", .{ c.src, compiler.last_error });
            return e;
        };
        const v = runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_) catch |e| {
            if (e == error.Exception) {
                const s = vm.toString(vm.exception) catch unreachable;
                const u = try vm.utf8(s, std.testing.allocator);
                defer std.testing.allocator.free(u);
                std.debug.print("threw: {s}: {s}\n", .{ c.src, u });
            }
            return e;
        };
        if (!v.isNumber() or v.asNumber() != c.want) {
            std.debug.print("case: {s}\n", .{c.src});
            try std.testing.expectEqual(c.want, if (v.isNumber()) v.asNumber() else -1);
        }
    }
}

test "interp: arithmetic, calls, closures, exceptions and objects" {
    const region = try std.testing.allocator.alloc(u8, 8 << 20);
    defer std.testing.allocator.free(region);
    const vm = try std.testing.allocator.create(Vm);
    defer std.testing.allocator.destroy(vm);
    try vm.init(region, std.testing.allocator);
    defer vm.deinit();
    try runCases(vm);
}

test "interp: the same cases collecting at every safe point" {
    const region = try std.testing.allocator.alloc(u8, 8 << 20);
    defer std.testing.allocator.free(region);
    const vm = try std.testing.allocator.create(Vm);
    defer std.testing.allocator.destroy(vm);
    try vm.init(region, std.testing.allocator);
    defer vm.deinit();
    vm.heap.stress = true;
    try runCases(vm);
    try std.testing.expect(vm.heap.collections > 10);
}
