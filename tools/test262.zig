//! The test262 runner (`zig build test262 -- [test/language/...]`): every
//! `.js` under the given directories of tools/testdata/test262 (fetched
//! at its pinned commit by tools/fetch-test262.sh), executed by the
//! engine as the harness would: the front matter's includes (after
//! assert.js and sta.js) run first in a fresh realm, then the test, in
//! sloppy and strict mode unless a flag says one. A file passes when
//! every mode completes without an exception — or, for a `negative`
//! file, when it fails in the phase and with the error type the front
//! matter names. Counts print per top-level directory under `test/`,
//! the numbers DESIGN.md records. Files needing features beyond the
//! current stage (modules, async, ...) are counted, not hidden: the
//! number is the number.
//!
//! `TEST262_VERBOSE=1` prints each failure and why; `TEST262_FILTER=s`
//! runs only paths containing `s`; `TEST262_GC_STRESS=1` collects at
//! every safe point (slow: a missing root shows up as a crash).
const std = @import("std");
const mosslib = @import("mosslib");
const js = mosslib.js;
const Vm = js.vm.Vm;
const Value = js.vm.Value;

var io: std.Io = undefined;

const Meta = struct {
    negative_phase: enum { none, parse, resolution, runtime } = .none,
    negative_type: []const u8 = "",
    module: bool = false,
    raw: bool = false,
    only_strict: bool = false,
    no_strict: bool = false,
    async_: bool = false,
    includes: [8][]const u8 = undefined,
    n_includes: usize = 0,
};

/// The YAML front matter between `/*---` and `---*/`, read for the keys
/// the runner needs.
fn readMeta(src: []const u8) Meta {
    var m: Meta = .{};
    const start = std.mem.indexOf(u8, src, "/*---") orelse return m;
    const end = std.mem.indexOfPos(u8, src, start, "---*/") orelse return m;
    const fm = src[start..end];
    if (std.mem.indexOf(u8, fm, "negative:")) |neg| {
        const rest = fm[neg..];
        if (std.mem.indexOf(u8, rest, "phase: parse") != null) m.negative_phase = .parse;
        if (std.mem.indexOf(u8, rest, "phase: resolution") != null) m.negative_phase = .resolution;
        if (std.mem.indexOf(u8, rest, "phase: runtime") != null) m.negative_phase = .runtime;
        if (std.mem.indexOf(u8, rest, "type: ")) |t| {
            const ts = rest[t + 6 ..];
            const te = std.mem.indexOfAny(u8, ts, "\n\r ") orelse ts.len;
            m.negative_type = ts[0..te];
        }
    }
    if (std.mem.indexOf(u8, fm, "flags:")) |fl| {
        const line_end = std.mem.indexOfScalarPos(u8, fm, fl, '\n') orelse fm.len;
        const line = fm[fl..line_end];
        if (std.mem.indexOf(u8, line, "module") != null) m.module = true;
        if (std.mem.indexOf(u8, line, "raw") != null) m.raw = true;
        if (std.mem.indexOf(u8, line, "onlyStrict") != null) m.only_strict = true;
        if (std.mem.indexOf(u8, line, "noStrict") != null) m.no_strict = true;
        if (std.mem.indexOf(u8, line, "async") != null) m.async_ = true;
    }
    if (std.mem.indexOf(u8, fm, "includes:")) |inc| {
        const line_end = std.mem.indexOfScalarPos(u8, fm, inc, '\n') orelse fm.len;
        var line = fm[inc + 9 .. line_end];
        line = std.mem.trim(u8, line, " []");
        var it = std.mem.splitScalar(u8, line, ',');
        while (it.next()) |name| {
            const n = std.mem.trim(u8, name, " ");
            if (n.len == 0) continue;
            if (m.n_includes < m.includes.len) {
                m.includes[m.n_includes] = n;
                m.n_includes += 1;
            }
        }
    }
    return m;
}

const Tally = struct { pass: usize = 0, fail: usize = 0 };

/// Harness files, read once.
const Harness = struct {
    gpa: std.mem.Allocator,
    dir: std.Io.Dir,
    files: std.StringHashMapUnmanaged([]const u8) = .empty,

    fn get(h: *Harness, name: []const u8) ![]const u8 {
        if (h.files.get(name)) |f| return f;
        const path = try std.fmt.allocPrint(h.gpa, "harness/{s}", .{name});
        defer h.gpa.free(path);
        const src = try h.dir.readFileAlloc(io, path, h.gpa, .limited(4 << 20));
        try h.files.put(h.gpa, try h.gpa.dupe(u8, name), src);
        return src;
    }
};

const Outcome = struct { ok: bool, why: []const u8 = "" };

const Runner = struct {
    gpa: std.mem.Allocator,
    region: []u8,
    harness: *Harness,
    why_buf: [512]u8 = undefined,
    printed: std.ArrayList(u8) = .empty,
    /// `TEST262_GC_STRESS=1`: collect at every safe point (slow; finds
    /// missing roots).
    gc_stress: bool = false,

    /// Run one file in every applicable mode.
    fn judge(r: *Runner, src: []const u8, meta: Meta) Outcome {
        if (meta.module) {
            // Modules are stage c: parse-negative files still judge by the parser.
            var arena = std.heap.ArenaAllocator.init(r.gpa);
            defer arena.deinit();
            const ok = if (js.parser.parse(arena.allocator(), src, .{ .module = true })) |_| true else |_| false;
            if (meta.negative_phase == .parse) return .{ .ok = !ok, .why = "module parsed" };
            return .{ .ok = false, .why = "modules are not supported yet" };
        }
        if (!meta.only_strict) {
            const o = r.runMode(src, meta, false);
            if (!o.ok) return o;
        }
        if (!meta.no_strict and !meta.raw) {
            const o = r.runMode(src, meta, true);
            if (!o.ok) return o;
        }
        return .{ .ok = true };
    }

    fn runMode(r: *Runner, src: []const u8, meta: Meta, strict: bool) Outcome {
        const vm = r.gpa.create(Vm) catch return .{ .ok = false, .why = "oom" };
        defer r.gpa.destroy(vm);
        vm.init(r.region, r.gpa) catch return .{ .ok = false, .why = "vm init failed" };
        defer vm.deinit();
        r.printed.clearRetainingCapacity();
        vm.step_limit = 20_000_000;
        vm.heap.stress = r.gc_stress;
        vm.print_fn = printHook;
        vm.host_data = r;
        installHost(vm) catch return .{ .ok = false, .why = "host install failed" };
        // The harness.
        if (!meta.raw) {
            const preludes = [_][]const u8{ "assert.js", "sta.js" };
            for (preludes) |p| {
                const hs = r.harness.get(p) catch return .{ .ok = false, .why = "harness missing" };
                if (!r.runSource(vm, hs, false, p)) return .{ .ok = false, .why = r.lastWhy(vm, "harness") };
            }
            if (meta.async_) {
                const hs = r.harness.get("doneprintHandle.js") catch return .{ .ok = false, .why = "harness missing" };
                if (!r.runSource(vm, hs, false, "doneprintHandle.js")) return .{ .ok = false, .why = r.lastWhy(vm, "harness") };
            }
            for (meta.includes[0..meta.n_includes]) |inc| {
                const hs = r.harness.get(inc) catch return .{ .ok = false, .why = "include missing" };
                if (!r.runSource(vm, hs, false, inc)) return .{ .ok = false, .why = r.lastWhy(vm, inc) };
            }
        }
        // The test itself.
        var text = src;
        var strict_buf: []u8 = &.{};
        defer if (strict_buf.len > 0) r.gpa.free(strict_buf);
        if (strict) {
            strict_buf = std.fmt.allocPrint(r.gpa, "\"use strict\";\n{s}", .{src}) catch return .{ .ok = false, .why = "oom" };
            text = strict_buf;
        }
        const code = js.compiler.compile(r.gpa, &vm.heap, &vm.strings, text, .{ .name = "test" }) catch |e| switch (e) {
            error.OutOfMemory => return .{ .ok = false, .why = "out of memory compiling" },
            error.SyntaxError => {
                if (meta.negative_phase == .parse) return .{ .ok = true };
                return .{ .ok = false, .why = std.fmt.bufPrint(&r.why_buf, "SyntaxError: {s}", .{js.compiler.last_error}) catch "SyntaxError" };
            },
        };
        if (meta.negative_phase == .parse) return .{ .ok = false, .why = "expected a SyntaxError, parsed" };
        const result = js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_);
        if (result) |_| {
            vm.runJobs() catch {};
            if (meta.negative_phase == .runtime) return .{ .ok = false, .why = "expected an exception, completed" };
            if (meta.async_) {
                if (std.mem.indexOf(u8, r.printed.items, "Test262:AsyncTestComplete") != null) return .{ .ok = true };
                if (std.mem.indexOf(u8, r.printed.items, "Test262:AsyncTestFailure") != null) return .{ .ok = false, .why = r.printedWhy() };
                return .{ .ok = false, .why = "async test did not complete" };
            }
            return .{ .ok = true };
        } else |e| switch (e) {
            error.OutOfMemory => return .{ .ok = false, .why = "out of memory" },
            error.Exception => {
                if (meta.negative_phase == .runtime) {
                    const name = r.exceptionName(vm);
                    if (std.mem.eql(u8, name, meta.negative_type)) return .{ .ok = true };
                    return .{ .ok = false, .why = std.fmt.bufPrint(&r.why_buf, "expected {s}, got {s}", .{ meta.negative_type, name }) catch "wrong exception" };
                }
                return .{ .ok = false, .why = r.lastWhy(vm, "test") };
            },
        }
    }

    fn runSource(r: *Runner, vm: *Vm, src: []const u8, strict: bool, name: []const u8) bool {
        const code = js.compiler.compile(r.gpa, &vm.heap, &vm.strings, src, .{ .strict = strict, .name = name }) catch return false;
        _ = js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_) catch return false;
        return true;
    }

    fn printedWhy(r: *Runner) []const u8 {
        const n = @min(r.printed.items.len, r.why_buf.len);
        @memcpy(r.why_buf[0..n], r.printed.items[0..n]);
        return r.why_buf[0..n];
    }

    /// The constructor name of the pending exception.
    fn exceptionName(r: *Runner, vm: *Vm) []const u8 {
        const e = vm.exception;
        vm.exception = Value.undefined_;
        if (!e.isObject()) return "(non-object)";
        const ctor = vm.get(Vm.asObject(e), .{ .atom = vm.atoms.constructor }, e) catch return "?";
        if (!ctor.isObject()) return "?";
        const name = vm.get(Vm.asObject(ctor), .{ .atom = vm.atoms.name }, ctor) catch return "?";
        if (!name.isString()) return "?";
        const s = vm.utf8(Vm.asString(name), r.gpa) catch return "?";
        defer r.gpa.free(s);
        const n = @min(s.len, r.why_buf.len);
        @memcpy(r.why_buf[0..n], s[0..n]);
        return r.why_buf[0..n];
    }

    fn lastWhy(r: *Runner, vm: *Vm, where: []const u8) []const u8 {
        const e = vm.exception;
        vm.exception = Value.undefined_;
        var msg: []const u8 = "?";
        var buf: [400]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        if (vm.toString(e)) |s| {
            msg = vm.utf8(s, fba.allocator()) catch "?";
        } else |_| {
            if (js.compiler.last_error.len > 0) msg = js.compiler.last_error;
        }
        return std.fmt.bufPrint(&r.why_buf, "{s}: {s}", .{ where, msg }) catch "?";
    }
};

fn printHook(vm: *Vm, s: []const u8) void {
    const r: *Runner = @ptrCast(@alignCast(vm.host_data.?));
    r.printed.appendSlice(r.gpa, s) catch {};
    r.printed.append(r.gpa, '\n') catch {};
}

/// `print` and the `$262` host object.
fn installHost(vm: *Vm) !void {
    _ = try vm.defineNative(vm.global, "print", 1, hostPrint);
    const h = try vm.newObject();
    try vm.defineValue(vm.global, "$262", h.asValue(), .hidden);
    try vm.defineValue(h, "global", vm.global.asValue(), .hidden);
    _ = try vm.defineNative(h, "evalScript", 1, hostEvalScript);
    _ = try vm.defineNative(h, "gc", 0, hostGc);
    _ = try vm.defineNative(h, "createRealm", 0, hostUnsupported);
    _ = try vm.defineNative(h, "detachArrayBuffer", 1, hostUnsupported);
    const agent = try vm.newObject();
    try vm.defineValue(h, "agent", agent.asValue(), .hidden);
}

fn hostPrint(vm: *Vm, _: Value, args: []const Value, _: Value) js.vm.Error!Value {
    const s = try vm.toString(if (args.len > 0) args[0] else Value.undefined_);
    const u = try vm.utf8(s, vm.meta);
    defer vm.meta.free(u);
    if (vm.print_fn) |f| f(vm, u) else std.debug.print("{s}\n", .{u});
    return Value.undefined_;
}

fn hostEvalScript(vm: *Vm, _: Value, args: []const Value, _: Value) js.vm.Error!Value {
    const s = try vm.toString(if (args.len > 0) args[0] else Value.undefined_);
    const src = try vm.utf8(s, vm.meta);
    defer vm.meta.free(src);
    const code = js.compiler.compile(vm.meta, &vm.heap, &vm.strings, src, .{ .name = "evalScript" }) catch |e| switch (e) {
        error.OutOfMemory => return error.OutOfMemory,
        error.SyntaxError => return vm.throwSyntaxError(js.compiler.last_error),
    };
    return js.interp.runScript(vm, code, vm.global.asValue(), null, null, Value.undefined_);
}

fn hostGc(vm: *Vm, _: Value, _: []const Value, _: Value) js.vm.Error!Value {
    _ = vm;
    return Value.undefined_;
}

fn hostUnsupported(vm: *Vm, _: Value, _: []const Value, _: Value) js.vm.Error!Value {
    return vm.throwTypeError("$262 feature not supported by this host");
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    const gpa = init.gpa;
    const cwd = std.Io.Dir.cwd();
    var args: std.ArrayList([]const u8) = .empty;
    var ait = std.process.Args.Iterator.init(init.minimal.args);
    while (ait.next()) |a| try args.append(gpa, try gpa.dupe(u8, a));
    const root = "tools/testdata/test262";
    var dirs: std.ArrayList([]const u8) = .empty;
    if (args.items.len > 1) {
        for (args.items[1..]) |a| try dirs.append(gpa, a);
    } else {
        try dirs.append(gpa, "test/language");
    }
    const verbose = std.c.getenv("TEST262_VERBOSE") != null;
    const trace = std.c.getenv("TEST262_TRACE") != null;
    const filter: ?[]const u8 = if (std.c.getenv("TEST262_FILTER")) |f| std.mem.span(f) else null;
    var root_dir = cwd.openDir(io, root, .{}) catch {
        std.debug.print("test262: cannot open {s} — run tools/fetch-test262.sh\n", .{root});
        return 1;
    };
    defer root_dir.close(io);
    var harness = Harness{ .gpa = gpa, .dir = root_dir };
    const region = try gpa.alloc(u8, 96 << 20);
    defer gpa.free(region);
    var runner = Runner{ .gpa = gpa, .region = region, .harness = &harness, .gc_stress = std.c.getenv("TEST262_GC_STRESS") != null };
    var by_dir: std.StringArrayHashMapUnmanaged(Tally) = .empty;
    var total: Tally = .{};
    for (dirs.items) |sub| {
        const path = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ root, sub });
        var dir = cwd.openDir(io, path, .{ .iterate = true }) catch {
            std.debug.print("test262: cannot open {s} — run tools/fetch-test262.sh\n", .{path});
            return 1;
        };
        defer dir.close(io);
        var walker = try dir.walk(gpa);
        defer walker.deinit();
        while (try walker.next(io)) |entry| {
            if (entry.kind != .file) continue;
            if (!std.mem.endsWith(u8, entry.path, ".js")) continue;
            if (std.mem.endsWith(u8, entry.path, "_FIXTURE.js")) continue;
            if (filter) |f| if (std.mem.indexOf(u8, entry.path, f) == null) continue;
            const src = dir.readFileAlloc(io, entry.path, gpa, .limited(8 << 20)) catch continue;
            defer gpa.free(src);
            const meta = readMeta(src);
            if (trace) std.debug.print("RUN {s}/{s}\n", .{ sub, entry.path });
            // The tally's key: the first path component under the given
            // directory (`expressions`, `statements`, ...).
            const slash = std.mem.indexOfScalar(u8, entry.path, '/') orelse entry.path.len;
            const key = try std.fmt.allocPrint(gpa, "{s}/{s}", .{ sub, entry.path[0..slash] });
            const g = try by_dir.getOrPut(gpa, key);
            if (!g.found_existing) g.value_ptr.* = .{};
            const o = runner.judge(src, meta);
            if (o.ok) {
                g.value_ptr.pass += 1;
                total.pass += 1;
            } else {
                g.value_ptr.fail += 1;
                total.fail += 1;
                if (verbose) std.debug.print("  FAIL {s}/{s}: {s}\n", .{ sub, entry.path, o.why });
            }
        }
    }
    var it = by_dir.iterator();
    while (it.next()) |e| std.debug.print("test262: {s}: {d}/{d}\n", .{ e.key_ptr.*, e.value_ptr.pass, e.value_ptr.pass + e.value_ptr.fail });
    std.debug.print("test262: total {d}/{d} pass\n", .{ total.pass, total.pass + total.fail });
    return 0;
}
