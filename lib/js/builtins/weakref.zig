//! WeakRef and FinalizationRegistry (§26.1–26.2). A WeakRef's target and
//! a registry's targets and unregister tokens are weak: the collector's
//! clear pass (`Vm.weakClear` → `clearDead`) empties a WeakRef whose
//! target died and moves a dead target's held value to its registry's
//! ready list, which the cleanup callback receives once the job queue
//! drains (HostEnqueueFinalizationRegistryCleanupJob, in `Vm.runJobs`).
//! A WeakRef's target is kept for the rest of the job it was made or
//! read in (AddToKeptObjects; `Vm.kept`, cleared with each job).
const std = @import("std");
const b = @import("../builtins.zig");
const vmod = @import("../vm.zig");
const heap = @import("../heap.zig");
const map = @import("map.zig");
const Vm = b.Vm;
const Value = b.Value;
const Error = b.Error;
const Object = b.Object;
const asObject = b.asObject;
const arg = b.arg;

pub const WeakRefData = extern struct { target: Value };

/// A registry cell: the target (weak), what the callback gets (strong),
/// the unregister token (weak).
pub const RegCell = struct { target: Value, held: Value, token: Value };
pub const Cells = std.ArrayList(RegCell);
pub const Ready = std.ArrayList(Value);

pub const RegistryData = extern struct {
    cleanup: Value,
    cells: ?*Cells,
    ready: ?*Ready,
};

pub fn install(vm: *Vm) Error!void {
    const i = &vm.intrinsics;
    _ = try b.installConstructor(vm, "WeakRef", 1, weakRefConstruct, i.weak_ref_prototype);
    _ = try vm.defineNative(i.weak_ref_prototype, "deref", 0, weakRefDeref);
    try b.setToStringTag(vm, i.weak_ref_prototype, "WeakRef");
    _ = try b.installConstructor(vm, "FinalizationRegistry", 1, registryConstruct, i.finalization_registry_prototype);
    _ = try vm.defineNative(i.finalization_registry_prototype, "register", 2, registryRegister);
    _ = try vm.defineNative(i.finalization_registry_prototype, "unregister", 1, registryUnregister);
    _ = try vm.defineNative(i.finalization_registry_prototype, "cleanupSome", 0, registryCleanupSome);
    try b.setToStringTag(vm, i.finalization_registry_prototype, "FinalizationRegistry");
}

// ---------------------------------------------------------- WeakRef

fn weakRefConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor WeakRef requires 'new'");
    const target = arg(args, 0);
    if (!map.canBeHeldWeakly(target)) return vm.throwTypeError("WeakRef: target must be an object or a non-registered symbol");
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.weak_ref_prototype, .weak_ref, @sizeOf(WeakRefData));
    o.internal(WeakRefData).* = .{ .target = target };
    try vm.addKept(target);
    try vm.weak_objects.append(vm.meta, o);
    return o.asValue();
}

fn thisWeakRef(vm: *Vm, this: Value, what: []const u8) Error!*WeakRefData {
    if (!this.isObject() or asObject(this).class != .weak_ref) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    return asObject(this).internal(WeakRefData);
}

fn weakRefDeref(vm: *Vm, this: Value, _: []const Value, _: Value) Error!Value {
    const d = try thisWeakRef(vm, this, "WeakRef.prototype.deref");
    if (!d.target.isUndefined()) try vm.addKept(d.target);
    return d.target;
}

// ----------------------------------------------- FinalizationRegistry

fn registryConstruct(vm: *Vm, _: Value, args: []const Value, new_target: Value) Error!Value {
    if (new_target.isUndefined()) return vm.throwTypeError("Constructor FinalizationRegistry requires 'new'");
    const cb = arg(args, 0);
    if (!vm.isCallable(cb)) return vm.throwTypeError("FinalizationRegistry: cleanup callback is not callable");
    const o = try vm.createFromConstructor(new_target, vm.intrinsics.finalization_registry_prototype, .finalization_registry, @sizeOf(RegistryData));
    const cells = try vm.meta.create(Cells);
    cells.* = .empty;
    errdefer vm.meta.destroy(cells);
    const ready = try vm.meta.create(Ready);
    ready.* = .empty;
    o.internal(RegistryData).* = .{ .cleanup = cb, .cells = cells, .ready = ready };
    try vm.weak_objects.append(vm.meta, o);
    return o.asValue();
}

fn thisRegistry(vm: *Vm, this: Value, what: []const u8) Error!*RegistryData {
    if (!this.isObject() or asObject(this).class != .finalization_registry or asObject(this).internal(RegistryData).cells == null) return vm.throwTypeErrorFmt("{s} called on incompatible receiver", .{what});
    return asObject(this).internal(RegistryData);
}

fn registryRegister(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisRegistry(vm, this, "FinalizationRegistry.prototype.register");
    const target = arg(args, 0);
    const held = arg(args, 1);
    const token = arg(args, 2);
    if (!map.canBeHeldWeakly(target)) return vm.throwTypeError("FinalizationRegistry.prototype.register: invalid target");
    if (vm.sameValue(target, held)) return vm.throwTypeError("FinalizationRegistry.prototype.register: target and held value must differ");
    if (!map.canBeHeldWeakly(token) and !token.isUndefined()) return vm.throwTypeError("FinalizationRegistry.prototype.register: invalid unregister token");
    try d.cells.?.append(vm.meta, .{ .target = target, .held = held, .token = token });
    return Value.undefined_;
}

fn registryUnregister(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisRegistry(vm, this, "FinalizationRegistry.prototype.unregister");
    const token = arg(args, 0);
    if (!map.canBeHeldWeakly(token)) return vm.throwTypeError("FinalizationRegistry.prototype.unregister: invalid unregister token");
    const cells = d.cells.?;
    var removed = false;
    var i: usize = 0;
    while (i < cells.items.len) {
        const c = cells.items[i];
        if (!c.token.isUndefined() and vm.sameValue(c.token, token)) {
            _ = cells.orderedRemove(i);
            removed = true;
        } else i += 1;
    }
    return Value.fromBool(removed);
}

/// `cleanupSome(callback)` (the proposal test262 still carries): the
/// ready held values to the callback, or the registry's own.
fn registryCleanupSome(vm: *Vm, this: Value, args: []const Value, _: Value) Error!Value {
    const d = try thisRegistry(vm, this, "FinalizationRegistry.prototype.cleanupSome");
    const cb = arg(args, 0);
    if (!cb.isUndefined() and !vm.isCallable(cb)) return vm.throwTypeError("FinalizationRegistry.prototype.cleanupSome: callback is not callable");
    try runReady(vm, d, if (cb.isUndefined()) d.cleanup else cb);
    return Value.undefined_;
}

fn runReady(vm: *Vm, d: *RegistryData, cb: Value) Error!void {
    const ready = d.ready orelse return;
    while (ready.items.len > 0) {
        const held = ready.orderedRemove(0);
        _ = try vm.call(cb, Value.undefined_, &.{held});
    }
}

// --------------------------------------------------------- collector

pub fn trace(o: *Object, m: *heap.Marker) void {
    switch (o.class) {
        .weak_ref => {}, // the target is weak
        .finalization_registry => {
            const d = o.internal(RegistryData);
            m.markValue(d.cleanup);
            if (d.cells) |cells| for (cells.items) |c| m.markValue(c.held);
            if (d.ready) |ready| for (ready.items) |v| m.markValue(v);
        },
        else => {},
    }
}

pub fn finalize(vm: *Vm, o: *Object) void {
    if (o.class != .finalization_registry) return;
    const d = o.internal(RegistryData);
    if (d.cells) |cells| {
        cells.deinit(vm.meta);
        vm.meta.destroy(cells);
        d.cells = null;
    }
    if (d.ready) |ready| {
        ready.deinit(vm.meta);
        vm.meta.destroy(ready);
        d.ready = null;
    }
}

/// The collector's clear pass for one live weak object: a WeakRef whose
/// target died is empty; a registry cell whose target died moves its
/// held value to the ready list (and asks for a cleanup), one whose
/// token died can no longer be unregistered.
pub fn clearDead(vm: *Vm, o: *Object) void {
    switch (o.class) {
        .weak_ref => {
            const d = o.internal(WeakRefData);
            if (d.target.isCell() and !d.target.asCell().marked) d.target = Value.undefined_;
        },
        .finalization_registry => {
            const d = o.internal(RegistryData);
            const cells = d.cells orelse return;
            var i: usize = 0;
            while (i < cells.items.len) {
                const c = &cells.items[i];
                if (c.token.isCell() and !c.token.asCell().marked) c.token = Value.undefined_;
                if (c.target.isCell() and !c.target.asCell().marked) {
                    if (d.ready) |ready| ready.append(vm.meta, c.held) catch {};
                    _ = cells.orderedRemove(i);
                    vm.cleanup_pending = true;
                } else i += 1;
            }
        },
        else => {},
    }
}

/// HostEnqueueFinalizationRegistryCleanupJob: every registry's ready
/// held values to its callback (a callback's exception is dropped, as
/// a job's is).
pub fn runCleanups(vm: *Vm) Error!void {
    vm.cleanup_pending = false;
    var i: usize = 0;
    while (i < vm.weak_objects.items.len) : (i += 1) {
        const o = vm.weak_objects.items[i];
        if (o.class != .finalization_registry) continue;
        const d = o.internal(RegistryData);
        runReady(vm, d, d.cleanup) catch |e| switch (e) {
            error.Exception => vm.exception = Value.undefined_,
            else => return e,
        };
    }
}
