//! Modules (§16.2): source text module records, linking with live
//! bindings, namespace objects, and evaluation with top-level await.
//!
//! A module's top-level bindings live in its environment cell like any
//! captured binding; an import is an `ImportCell` in the importing
//! module's slot that points at the exporting module's slot (or at a
//! namespace), so a read through it is always the current value —
//! the live binding the specification requires. A module body is a
//! coroutine: `modinit` suspends it once the environment exists and
//! its function declarations are instantiated (InitializeEnvironment,
//! at link time), evaluation resumes it, and `await` at the top level
//! is the async function's await. The host supplies sources through
//! `Vm.host_load`; the engine resolves nothing itself.
const std = @import("std");
const vmod = @import("vm.zig");
const heap = @import("heap.zig");
const bytecode = @import("bytecode.zig");
const compiler = @import("compiler.zig");
const interp = @import("interp.zig");
const ast = @import("ast.zig");
const parser = @import("parser.zig");
const scope = @import("scope.zig");
const generator = @import("builtins/generator.zig");
const promise = @import("builtins/promise.zig");
const Vm = vmod.Vm;
const Value = vmod.Value;
const Error = vmod.Error;
const Object = vmod.Object;
const String = vmod.String;
const Key = vmod.Key;
const Env = bytecode.Env;
const Code = bytecode.Code;
const Cell = heap.Cell;
const asObject = Vm.asObject;
const asString = Vm.asString;
const strValue = Vm.strValue;

/// What the host returns for a specifier: the canonical name (the key
/// under which the module is remembered) and the source text.
pub const Loaded = struct { name: []u8, source: []u8 };
pub const HostLoad = *const fn (vm: *Vm, referrer: ?[]const u8, specifier: []const u8) Error!?Loaded;

/// An import binding's indirection (heap kind `.binding`).
pub const ImportCell = extern struct {
    header: Cell,
    env: ?*Env,
    slot: u32,
    _pad: u32 = 0,
    /// A namespace import (env null).
    namespace: Value,

    pub fn trace(c: *ImportCell, m: *heap.Marker) void {
        if (c.env) |e| m.markCell(e.cell());
        m.markValue(c.namespace);
    }
};

pub const NamespaceData = extern struct { module: *Module };

pub const ImportEntry = struct { request: u32, import_name: ?[]const u8, local: []const u8 };
pub const LocalExport = struct { export_name: []const u8, local: []const u8 };
pub const IndirectExport = struct { export_name: []const u8, request: u32, import_name: ?[]const u8 };

/// `evaluating` is the DFS in progress (a dependency in that state is a
/// cycle: not waited for); `evaluating_async` a body suspended at a
/// top-level await, which importers do wait for.
pub const Status = enum { new, linking, linked, evaluating, evaluating_async, evaluated, errored };

/// A resolved export: the module and its binding — a slot in its
/// environment, or its namespace.
pub const Binding = struct { module: *Module, slot: ?u32 };

pub const Module = struct {
    name: []u8,
    source: []u8,
    code: ?*Code = null,
    status: Status = .new,
    requests: std.ArrayList([]const u8) = .empty,
    resolved: std.ArrayList(?*Module) = .empty,
    imports: std.ArrayList(ImportEntry) = .empty,
    local_exports: std.ArrayList(LocalExport) = .empty,
    indirect_exports: std.ArrayList(IndirectExport) = .empty,
    star_exports: std.ArrayList(u32) = .empty,
    env: ?*Env = null,
    /// The coroutine suspended at `modinit` (then running the body).
    co: ?*Object = null,
    namespace: Value = Value.undefined_,
    meta: Value = Value.undefined_,
    eval_error: Value = Value.undefined_,
    /// The evaluation promise (settled with undefined or the error).
    promise: Value = Value.undefined_,
    resolve_fn: Value = Value.undefined_,
    reject_fn: Value = Value.undefined_,
    /// Evaluation progress through the requested modules, and how many
    /// of them are still running (top-level await).
    dep_index: u32 = 0,
    pending: u32 = 0,
    /// Namespace: the sorted export names and their bindings.
    ns_names: std.ArrayList([]const u8) = .empty,
    ns_bindings: std.ArrayList(Binding) = .empty,
    /// The index in the VM's module table (native closures carry it).
    index: u32 = 0,
    arena: std.heap.ArenaAllocator,

    pub fn deinit(m: *Module, a: std.mem.Allocator) void {
        m.requests.deinit(a);
        m.resolved.deinit(a);
        m.imports.deinit(a);
        m.local_exports.deinit(a);
        m.indirect_exports.deinit(a);
        m.star_exports.deinit(a);
        m.ns_names.deinit(a);
        m.ns_bindings.deinit(a);
        m.arena.deinit();
        a.free(m.name);
        a.free(m.source);
    }

    pub fn trace(m: *Module, mk: *heap.Marker) void {
        if (m.code) |c| mk.markCell(c.cell());
        if (m.env) |e| mk.markCell(e.cell());
        if (m.co) |c| mk.markCell(c.cell());
        mk.markValue(m.namespace);
        mk.markValue(m.meta);
        mk.markValue(m.eval_error);
        mk.markValue(m.promise);
        mk.markValue(m.resolve_fn);
        mk.markValue(m.reject_fn);
    }
};

// ------------------------------------------------------------ loading

/// A module from source under `name` (the host's canonical key): parsed
/// into its record, not yet linked.
pub fn create(vm: *Vm, name: []const u8, source: []const u8) Error!*Module {
    if (vm.modules.get(name)) |m| return m;
    const m = try vm.meta.create(Module);
    m.* = .{ .name = try vm.meta.dupe(u8, name), .source = try vm.meta.dupe(u8, source), .arena = std.heap.ArenaAllocator.init(vm.meta) };
    errdefer {
        m.deinit(vm.meta);
        vm.meta.destroy(m);
    }
    // Parse once for the entries (the compiler parses again; the tree
    // is small compared to running it).
    var arena = std.heap.ArenaAllocator.init(vm.compile_scratch orelse vm.meta);
    defer arena.deinit();
    const prog = parser.parse(arena.allocator(), m.source, .{ .module = true }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return vm.throwSyntaxError(compiler.last_error),
    };
    try collectEntries(vm, m, prog);
    m.code = compiler.compile(vm.meta, &vm.heap, &vm.strings, m.source, .{ .module = true, .name = m.name, .module_record = m, .scratch = vm.compile_scratch }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return vm.throwSyntaxError(compiler.last_error),
    };
    // The code keeps the text (a function's `toString`); the record's
    // copy has served (a site's two megabytes of modules were held
    // twice, 2026-09-28).
    vm.meta.free(m.source);
    m.source = &.{};
    // Remembered only once it exists in full: a failed parse leaves no trace.
    m.index = @intCast(vm.modules.count());
    try vm.modules.put(vm.meta, m.name, m);
    return m;
}

fn requestIndex(vm: *Vm, m: *Module, spec: []const u8) Error!u32 {
    for (m.requests.items, 0..) |r, i| if (std.mem.eql(u8, r, spec)) return @intCast(i);
    try m.requests.append(vm.meta, try m.arena.allocator().dupe(u8, spec));
    try m.resolved.append(vm.meta, null);
    return @intCast(m.requests.items.len - 1);
}

fn boundNames(vm: *Vm, m: *Module, n: *ast.Node, kind: enum { local }) Error!void {
    _ = kind;
    switch (n.data) {
        .identifier => |name| {
            const d = try m.arena.allocator().dupe(u8, name);
            try m.local_exports.append(vm.meta, .{ .export_name = d, .local = d });
        },
        .object_pattern => |props| for (props) |p| try boundNames(vm, m, p.value, .local),
        .array_pattern => |els| for (els) |e| if (e) |x| try boundNames(vm, m, x, .local),
        .assign_pattern => |ap| try boundNames(vm, m, ap.target, .local),
        .rest => |r| try boundNames(vm, m, r, .local),
        else => {},
    }
}

/// ParseModule's entry lists (§16.2.1.6.1) from the tree.
fn collectEntries(vm: *Vm, m: *Module, prog: *ast.Node) Error!void {
    const a = m.arena.allocator();
    for (prog.data.program.body) |st| switch (st.data) {
        .import_decl => |im| {
            const req = try requestIndex(vm, m, im.source);
            if (im.default) |d| try m.imports.append(vm.meta, .{ .request = req, .import_name = "default", .local = try a.dupe(u8, d) });
            if (im.namespace) |ns| try m.imports.append(vm.meta, .{ .request = req, .import_name = null, .local = try a.dupe(u8, ns) });
            for (im.named) |nm| try m.imports.append(vm.meta, .{ .request = req, .import_name = try a.dupe(u8, nm.imported), .local = try a.dupe(u8, nm.local) });
        },
        .export_decl => |ex| switch (ex) {
            .declaration => |d| switch (d.data) {
                .var_decl => |vd| for (vd.decls) |dc| try boundNames(vm, m, dc.target, .local),
                .function_decl => |f| {
                    const n = try a.dupe(u8, f.name.?);
                    try m.local_exports.append(vm.meta, .{ .export_name = n, .local = n });
                },
                .class_decl => |c| {
                    const n = try a.dupe(u8, c.name.?);
                    try m.local_exports.append(vm.meta, .{ .export_name = n, .local = n });
                },
                else => {},
            },
            .default => |d| {
                const local: []const u8 = switch (d.data) {
                    .function_decl => |f| f.name orelse "*default*",
                    .class_decl => |c| c.name orelse "*default*",
                    else => "*default*",
                };
                try m.local_exports.append(vm.meta, .{ .export_name = "default", .local = try a.dupe(u8, local) });
            },
            .named => |nm| {
                if (nm.source) |src| {
                    const req = try requestIndex(vm, m, src);
                    for (nm.specifiers) |sp| try m.indirect_exports.append(vm.meta, .{ .export_name = try a.dupe(u8, sp.exported), .request = req, .import_name = try a.dupe(u8, sp.local) });
                } else {
                    for (nm.specifiers) |sp| try m.local_exports.append(vm.meta, .{ .export_name = try a.dupe(u8, sp.exported), .local = try a.dupe(u8, sp.local) });
                }
            },
            .all => |al| {
                const req = try requestIndex(vm, m, al.source);
                if (al.as) |as| {
                    try m.indirect_exports.append(vm.meta, .{ .export_name = try a.dupe(u8, as), .request = req, .import_name = null });
                } else try m.star_exports.append(vm.meta, req);
            },
        },
        else => {},
    };
    // A local export of an imported name is an indirect export.
    var i: usize = 0;
    while (i < m.local_exports.items.len) {
        const le = m.local_exports.items[i];
        var moved = false;
        for (m.imports.items) |ie| if (std.mem.eql(u8, ie.local, le.local)) {
            try m.indirect_exports.append(vm.meta, .{ .export_name = le.export_name, .request = ie.request, .import_name = ie.import_name });
            _ = m.local_exports.orderedRemove(i);
            moved = true;
            break;
        };
        if (!moved) i += 1;
    }
}

/// Load the graph below `m` through the host (HostLoadImportedModule).
fn loadTree(vm: *Vm, m: *Module) Error!void {
    for (m.requests.items, 0..) |spec, i| {
        if (m.resolved.items[i] != null) continue;
        const host = vm.host_load orelse return vm.throwSyntaxError("no module loader");
        const loaded = (try host(vm, m.name, spec)) orelse {
            var buf: [256]u8 = undefined;
            const msg = std.fmt.bufPrint(&buf, "Cannot find module '{s}'", .{spec}) catch "Cannot find module";
            return vm.throwSyntaxError(msg);
        };
        defer {
            vm.meta.free(loaded.name);
            vm.meta.free(loaded.source);
        }
        const dep = try create(vm, loaded.name, loaded.source);
        m.resolved.items[i] = dep;
        if (dep.status == .new) try loadTree(vm, dep);
    }
}

// ------------------------------------------------------------ linking

const ResolveError = error{ Ambiguous, NotFound };

const Seen = struct { module: *Module, name: []const u8 };

/// ResolveExport (§16.2.1.6.3).
pub fn resolveExport(vm: *Vm, m: *Module, name: []const u8, seen: *std.ArrayList(Seen)) (Error || ResolveError)!Binding {
    for (seen.items) |s| if (s.module == m and std.mem.eql(u8, s.name, name)) return error.NotFound; // circular
    try seen.append(vm.meta, .{ .module = m, .name = name });
    for (m.local_exports.items) |le| if (std.mem.eql(u8, le.export_name, name)) {
        return .{ .module = m, .slot = try localSlot(vm, m, le.local) };
    };
    for (m.indirect_exports.items) |ie| if (std.mem.eql(u8, ie.export_name, name)) {
        const imported = m.resolved.items[ie.request].?;
        if (ie.import_name) |iname| return resolveExport(vm, imported, iname, seen);
        return .{ .module = imported, .slot = null };
    };
    if (std.mem.eql(u8, name, "default")) return error.NotFound;
    var star: ?Binding = null;
    for (m.star_exports.items) |req| {
        const imported = m.resolved.items[req].?;
        const r = resolveExport(vm, imported, name, seen) catch |e| switch (e) {
            error.NotFound => continue,
            else => return e,
        };
        if (star) |s| {
            if (s.module != r.module or !std.meta.eql(s.slot, r.slot)) return error.Ambiguous;
        } else star = r;
    }
    return star orelse error.NotFound;
}

/// The environment slot of a module's own binding.
fn localSlot(vm: *Vm, m: *Module, local: []const u8) Error!u32 {
    const env = m.env orelse return vm.throwSyntaxError("module environment missing");
    const atom = try vm.strings.atom(local);
    for (env.info.names, 0..) |n, i| if (n == atom) return @intCast(i);
    return vm.throwSyntaxError("export of an undeclared name");
}

/// GetExportedNames (§16.2.1.6.2).
fn exportedNames(vm: *Vm, m: *Module, out: *std.ArrayList([]const u8), star_set: *std.ArrayList(*Module)) Error!void {
    for (star_set.items) |s| if (s == m) return;
    try star_set.append(vm.meta, m);
    for (m.local_exports.items) |le| try out.append(vm.meta, le.export_name);
    for (m.indirect_exports.items) |ie| try out.append(vm.meta, ie.export_name);
    for (m.star_exports.items) |req| {
        const imported = m.resolved.items[req].?;
        var names: std.ArrayList([]const u8) = .empty;
        defer names.deinit(vm.meta);
        try exportedNames(vm, imported, &names, star_set);
        for (names.items) |n| {
            if (std.mem.eql(u8, n, "default")) continue;
            var dup = false;
            for (out.items) |x| if (std.mem.eql(u8, x, n)) {
                dup = true;
                break;
            };
            if (!dup) try out.append(vm.meta, n);
        }
    }
}

/// Link: load the graph, create every environment (running each body
/// to its `modinit`), then fill the import cells (§16.2.1.5.1 Link and
/// InitializeEnvironment).
pub fn link(vm: *Vm, entry: *Module) Error!void {
    if (entry.status != .new) return;
    try loadTree(vm, entry);
    var list: std.ArrayList(*Module) = .empty;
    defer list.deinit(vm.meta);
    try collectNew(vm, entry, &list);
    for (list.items) |m| m.status = .linking;
    for (list.items) |m| try instantiate(vm, m);
    for (list.items) |m| try checkIndirectExports(vm, m);
    for (list.items) |m| try resolveImports(vm, m);
    for (list.items) |m| m.status = .linked;
}

/// InitializeEnvironment step 1: every indirect export must resolve.
fn checkIndirectExports(vm: *Vm, m: *Module) Error!void {
    for (m.indirect_exports.items) |ie| {
        const iname = ie.import_name orelse continue;
        const imported = m.resolved.items[ie.request] orelse return vm.throwSyntaxError("unresolved module request");
        var seen: std.ArrayList(Seen) = .empty;
        defer seen.deinit(vm.meta);
        _ = resolveExport(vm, imported, iname, &seen) catch |e| switch (e) {
            error.NotFound => {
                var buf: [256]u8 = undefined;
                const msg = std.fmt.bufPrint(&buf, "The requested module '{s}' does not provide an export named '{s}'", .{ m.requests.items[ie.request], iname }) catch "missing export";
                return vm.throwSyntaxError(msg);
            },
            error.Ambiguous => return vm.throwSyntaxError("ambiguous export"),
            else => |x| return x,
        };
    }
}

fn collectNew(vm: *Vm, m: *Module, list: *std.ArrayList(*Module)) Error!void {
    for (list.items) |x| if (x == m) return;
    if (m.status != .new) return;
    try list.append(vm.meta, m);
    for (m.resolved.items) |dep| if (dep) |d| try collectNew(vm, d, list);
}

/// Run the module code to `modinit`: the environment and its hoisted
/// functions exist afterwards.
fn instantiate(vm: *Vm, m: *Module) Error!void {
    const code = m.code.?;
    const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    m.promise = cap.promise;
    m.resolve_fn = cap.resolve;
    m.reject_fn = cap.reject;
    const co = try generator.newModuleRecord(vm, code, cap);
    m.co = co;
    _ = try interp.runCoroutineStart(vm, code, null, Value.undefined_, null, &.{}, co, true);
    m.env = co.internal(vmod.CoroutineData).env;
}

fn resolveImports(vm: *Vm, m: *Module) Error!void {
    const env = m.env orelse return vm.throwSyntaxError("module environment missing");
    for (m.imports.items) |ie| {
        const imported = m.resolved.items[ie.request] orelse return vm.throwSyntaxError("unresolved module request");
        var cell: *ImportCell = undefined;
        if (ie.import_name) |iname| {
            var seen: std.ArrayList(Seen) = .empty;
            defer seen.deinit(vm.meta);
            const r = resolveExport(vm, imported, iname, &seen) catch |e| switch (e) {
                error.NotFound => {
                    var buf: [256]u8 = undefined;
                    const msg = std.fmt.bufPrint(&buf, "The requested module '{s}' does not provide an export named '{s}'", .{ m.requests.items[ie.request], iname }) catch "missing export";
                    return vm.throwSyntaxError(msg);
                },
                error.Ambiguous => return vm.throwSyntaxError("ambiguous export"),
                else => |x| return x,
            };
            cell = try newImportCell(vm, if (r.slot != null) r.module.env else null, r.slot orelse 0, if (r.slot == null) try getNamespace(vm, r.module) else Value.undefined_);
        } else {
            cell = try newImportCell(vm, null, 0, try getNamespace(vm, imported));
        }
        const slot = try localSlot(vm, m, ie.local);
        vm.heap.writeBarrier(env.cell(), Value.fromCell(&cell.header));
        env.slots()[slot] = Value.fromCell(&cell.header);
    }
}

fn newImportCell(vm: *Vm, env: ?*Env, slot: u32, namespace: Value) Error!*ImportCell {
    const c = try vm.heap.alloc(.binding, @sizeOf(ImportCell));
    const cell = c.as(ImportCell);
    cell.env = env;
    cell.slot = slot;
    cell.namespace = namespace;
    return cell;
}

/// Read an import binding (the `getimport` instruction).
pub fn readImport(vm: *Vm, v: Value, name: *String) Error!Value {
    if (!v.isCell() or v.asCell().kind != .binding) return vm.throwReferenceError("import binding is not initialized");
    const cell = v.asCell().as(ImportCell);
    if (cell.env) |e| {
        const val = e.slots()[cell.slot];
        if (val.isEmpty()) {
            var buf: [256]u8 = undefined;
            var fba = std.heap.FixedBufferAllocator.init(&buf);
            const n = vm.utf8(name, fba.allocator()) catch "";
            var out: [300]u8 = undefined;
            const msg = std.fmt.bufPrint(&out, "Cannot access '{s}' before initialization", .{n}) catch "before initialization";
            return vm.throwReferenceError(msg);
        }
        // An import of an import: follow it.
        if (val.isCell() and val.asCell().kind == .binding) return readImport(vm, val, name);
        return val;
    }
    return cell.namespace;
}

// ---------------------------------------------------------- namespaces

fn lessName(_: void, a: []const u8, b: []const u8) bool {
    return std.mem.lessThan(u8, a, b);
}

/// GetModuleNamespace (§16.2.1.10): the exotic object over the sorted,
/// resolvable export names.
pub fn getNamespace(vm: *Vm, m: *Module) Error!Value {
    if (!m.namespace.isUndefined()) return m.namespace;
    var names: std.ArrayList([]const u8) = .empty;
    defer names.deinit(vm.meta);
    var star_set: std.ArrayList(*Module) = .empty;
    defer star_set.deinit(vm.meta);
    try exportedNames(vm, m, &names, &star_set);
    std.mem.sort([]const u8, names.items, {}, lessName);
    const o = try vm.objects.create(Value.null_, .namespace, @sizeOf(NamespaceData));
    o.internal(NamespaceData).module = m;
    m.namespace = o.asValue();
    for (names.items) |n| {
        var seen: std.ArrayList(Seen) = .empty;
        defer seen.deinit(vm.meta);
        const r = resolveExport(vm, m, n, &seen) catch |e| switch (e) {
            error.NotFound, error.Ambiguous => continue,
            else => |x| return x,
        };
        // Sorted by UTF-16 code units: the names are UTF-8 here, which
        // orders the same for the BMP text exports carry.
        try m.ns_names.append(vm.meta, n);
        try m.ns_bindings.append(vm.meta, r);
    }
    _ = try vm.objects.defineOwn(o, .{ .symbol = vm.symbols.to_string_tag }, strValue(try vm.atom("Module")), .frozen);
    o.extensible = false;
    return m.namespace;
}

fn nsIndex(m: *Module, key: Key) ?usize {
    const name: []const u8 = switch (key) {
        .atom => |s| s.latin1() orelse return null,
        .index => return null,
        .symbol => return null,
    };
    for (m.ns_names.items, 0..) |n, i| if (std.mem.eql(u8, n, name)) return i;
    return null;
}

/// The value of a namespace export (live).
fn nsValue(vm: *Vm, m: *Module, i: usize) Error!Value {
    const bnd = m.ns_bindings.items[i];
    if (bnd.slot) |slot| {
        const v = bnd.module.env.?.slots()[slot];
        if (v.isEmpty()) return vm.throwReferenceError("Cannot access an uninitialized export");
        if (v.isCell() and v.asCell().kind == .binding) return readImport(vm, v, vm.atoms.empty);
        return v;
    }
    return getNamespace(vm, bnd.module);
}

fn nsData(o: *Object) *Module {
    return o.internal(NamespaceData).module;
}

pub fn nsGetOwnProperty(vm: *Vm, o: *Object, key: Key) Error!?vmod.Objects.Own {
    if (key == .symbol) return vm.objects.getOwn(o, key);
    const m = nsData(o);
    const i = nsIndex(m, key) orelse return null;
    return .{ .val = try nsValue(vm, m, i), .attrs = .{ .writable = true, .enumerable = true, .configurable = false }, .slot = null };
}

pub fn nsDefineOwnProperty(vm: *Vm, o: *Object, key: Key, desc: Vm.Descriptor) Error!bool {
    if (key == .symbol) return vm.ordinaryDefineOwnProperty(o, key, desc);
    const cur = (try nsGetOwnProperty(vm, o, key)) orelse return false;
    if (desc.configurable orelse false) return false;
    if (desc.enumerable != null and !desc.enumerable.?) return false;
    if (desc.isAccessor()) return false;
    if (desc.writable != null and !desc.writable.?) return false;
    if (desc.value) |v| return vm.sameValue(v, cur.val);
    return true;
}

pub fn nsDelete(vm: *Vm, o: *Object, key: Key) Error!bool {
    if (key == .symbol) return vm.objects.delete(o, key);
    return nsIndex(nsData(o), key) == null;
}

pub fn nsOwnKeys(vm: *Vm, o: *Object, out: *std.ArrayList(Key)) Error!void {
    const m = nsData(o);
    for (m.ns_names.items) |n| try out.append(vm.meta, .{ .atom = try vm.strings.atom(n) });
    try vm.objects.ownKeys(o, out);
}

// ---------------------------------------------------------- evaluation

/// Evaluate (§16.2.1.5.3): dependencies first, in order, waiting on any
/// that is still running (top-level await), then the body. The result
/// is the module's promise.
pub fn evaluate(vm: *Vm, m: *Module) Error!Value {
    if (m.status != .linked) return m.promise;
    m.status = .evaluating;
    m.dep_index = 0;
    try continueEvaluation(vm, m);
    return m.promise;
}

fn continueEvaluation(vm: *Vm, m: *Module) Error!void {
    // Start every dependency in order; a synchronous one finishes before
    // the next begins, an asynchronous one (top-level await) runs on and
    // is waited for once all have started, so it never blocks a sibling.
    while (m.dep_index < m.resolved.items.len) {
        const dep = m.resolved.items[m.dep_index].?;
        m.dep_index += 1;
        const p = try evaluate(vm, dep);
        // A dependency still walking its own dependencies is a cycle back
        // to this module: it counts as done (§16.2.1.5.3.1 step 3).
        if (dep.status == .evaluating) continue;
        const pd = asObject(p).internal(vmod.PromiseData);
        switch (pd.state) {
            1 => continue,
            2 => {
                try failEvaluation(vm, m, pd.result);
                return;
            },
            else => {
                m.pending += 1;
                const on_f = try vm.newNative("", 1, depSettled, Value.fromInt(@intCast(m.index)));
                const on_r = try vm.newNative("", 1, failAfterDep, Value.fromInt(@intCast(m.index)));
                _ = try promise.performThen(vm, p, on_f.asValue(), on_r.asValue(), null);
            },
        }
    }
    if (m.pending > 0) return;
    try runBody(vm, m);
}

fn failEvaluation(vm: *Vm, m: *Module, err: Value) Error!void {
    if (m.status == .errored) return;
    m.status = .errored;
    m.eval_error = err;
    _ = try vm.call(m.reject_fn, Value.undefined_, &.{err});
}

fn runBody(vm: *Vm, m: *Module) Error!void {
    const co = m.co.?;
    const r = generator.resumeCo(vm, co, Value.undefined_, 0);
    try generator.settleAsync(vm, co, r);
    const pd = asObject(m.promise).internal(vmod.PromiseData);
    if (pd.state == 2) {
        m.status = .errored;
        m.eval_error = pd.result;
    } else if (pd.state == 1) {
        m.status = .evaluated;
    } else {
        // An await at the top level: importers wait for the promise.
        m.status = .evaluating_async;
        const on_f = try vm.newNative("", 1, bodySettled, Value.fromInt(@intCast(m.index)));
        const on_r = try vm.newNative("", 1, bodyFailed, Value.fromInt(@intCast(m.index)));
        _ = try promise.performThen(vm, m.promise, on_f.asValue(), on_r.asValue(), null);
    }
}

fn bodySettled(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const m = moduleOf(vm) orelse return Value.undefined_;
    m.status = .evaluated;
    return Value.undefined_;
}

fn bodyFailed(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const m = moduleOf(vm) orelse return Value.undefined_;
    m.status = .errored;
    m.eval_error = if (args.len > 0) args[0] else Value.undefined_;
    return Value.undefined_;
}

fn depSettled(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const m = moduleOf(vm) orelse return Value.undefined_;
    if (m.status == .errored) return Value.undefined_;
    m.pending -= 1;
    if (m.pending == 0 and m.dep_index == m.resolved.items.len) try runBody(vm, m);
    return Value.undefined_;
}

fn moduleOf(vm: *Vm) ?*Module {
    const f = vm.current_native orelse return null;
    const idx: usize = @intCast(f.internal(vmod.FunctionData).data.asInt());
    return vm.modules.values()[idx];
}

fn continueAfterDep(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const m = moduleOf(vm) orelse return Value.undefined_;
    try continueEvaluation(vm, m);
    return Value.undefined_;
}

fn failAfterDep(vm: *Vm, _: Value, args: []const Value, _: Value) Error!Value {
    const m = moduleOf(vm) orelse return Value.undefined_;
    try failEvaluation(vm, m, if (args.len > 0) args[0] else Value.undefined_);
    return Value.undefined_;
}

/// `import.meta` of the module a code belongs to.
pub fn importMeta(vm: *Vm, code: *bytecode.CodeData) Error!Value {
    const mp = code.module orelse return vm.throwSyntaxError("import.meta outside a module");
    const m: *Module = @ptrCast(@alignCast(mp));
    if (m.meta.isUndefined()) {
        const o = try vm.objects.create(Value.null_, .ordinary, 0);
        m.meta = o.asValue();
        if (vm.host_import_meta) |h| try h(vm, m.name, o);
    }
    return m.meta;
}

/// `import(specifier)` (§13.3.10, HostLoadImportedModule): a promise
/// of the namespace; every failure rejects it.
pub fn dynamicImport(vm: *Vm, code: *bytecode.CodeData, specifier: Value) Error!Value {
    const cap = try promise.newCapability(vm, vm.intrinsics.promise_ctor.asValue());
    const referrer: ?[]const u8 = if (code.module) |mp| @as(*Module, @ptrCast(@alignCast(mp))).name else if (code.source) |src| src.name else null;
    dynamicImportInner(vm, referrer, specifier, cap) catch |e| switch (e) {
        error.Exception => {
            const ex = vm.exception;
            vm.exception = Value.undefined_;
            _ = try vm.call(cap.reject, Value.undefined_, &.{ex});
        },
        else => return e,
    };
    return cap.promise;
}

fn dynamicImportInner(vm: *Vm, referrer: ?[]const u8, specifier: Value, cap: promise.Capability) Error!void {
    const spec_s = try vm.toString(specifier);
    const spec = try vm.utf8(spec_s, vm.meta);
    defer vm.meta.free(spec);
    const host = vm.host_load orelse return vm.throwTypeError("no module loader");
    const loaded = (try host(vm, referrer, spec)) orelse {
        var buf: [256]u8 = undefined;
        const msg = std.fmt.bufPrint(&buf, "Cannot find module '{s}'", .{spec}) catch "Cannot find module";
        return vm.throwSyntaxError(msg);
    };
    defer {
        vm.meta.free(loaded.name);
        vm.meta.free(loaded.source);
    }
    const m = try create(vm, loaded.name, loaded.source);
    try link(vm, m);
    const p = try evaluate(vm, m);
    // Resolve with the namespace once evaluation settles.
    const on_f = try vm.newNative("", 1, importFulfilled, Value.fromInt(@intCast(m.index)));
    _ = try promise.performThen(vm, p, on_f.asValue(), cap.reject, cap);
}

fn importFulfilled(vm: *Vm, _: Value, _: []const Value, _: Value) Error!Value {
    const m = moduleOf(vm) orelse return Value.undefined_;
    return getNamespace(vm, m);
}

/// Run a module as the program's entry: link, evaluate, drain jobs.
/// Returns the evaluation promise (the host checks how it settled).
pub fn runEntry(vm: *Vm, name: []const u8, source: []const u8) Error!Value {
    const m = try create(vm, name, source);
    try link(vm, m);
    return evaluate(vm, m);
}
