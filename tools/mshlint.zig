//! mshlint — what the interpreter would only tell you when the line
//! runs, told before: built on the tree-sitter grammar (tools/mshtree.zig)
//! like mshfmt. The checks:
//!
//!   syntax     a file that does not parse, with where
//!   unbound    `$x` with no `let x`, parameter, `for x`, pattern or
//!              implicit name (`$it`, `$in`, `$acc`, `$req`) in any
//!              enclosing scope; `$x` used before its `let` in the
//!              same scope
//!   unused     a `let` inside a function that nothing reads (the file's
//!              own top level is a module's exports, so not there)
//!   match      not exhaustive (the interpreter's rule: a catch-all, or
//!              `ok _` and `err _`, or `true` and `false`), and an arm
//!              after a catch-all that can never match
//!   record     the same key twice in one literal
//!   def        a `def` that shadows a builtin command
//!   unit       under conf/units/ and conf/session/, a top-level key the
//!              unit loader does not know (it ignores them silently)
//!
//! Usage: mshlint FILE...  |  mshlint --stdin [NAME]. Diagnostics are
//! `path:line:col: message`; the exit code is 1 if there were any.

const std = @import("std");
const ts = @import("mshtree");
const mshl = @import("mshl");
const c = ts.c;

pub const Error = ts.Error;

pub const Diag = struct { line: u32, col: u32, msg: []const u8 };

/// Names a block argument or a function gets without declaring them.
const implicit_names = [_][]const u8{ "it", "in", "acc", "req" };

/// The keys the unit loader (user/init.zig, `parseUnit`) reads.
const unit_keys = [_][]const u8{ "image", "arg", "node", "cores", "budget", "grant", "give", "restart", "profiles", "after", "essential", "oneshot", "script", "certify", "run", "install" };

const Binding = struct {
    name: []const u8,
    kind: enum { let, def, param, for_, pattern, implicit },
    /// Where the first binding of the name starts.
    at: u32,
    uses: u32 = 0,
};

const Scope = struct {
    parent: ?*Scope,
    /// The file's top level: a module's exports, never "unused".
    file_level: bool,
    names: std.ArrayList(Binding) = .empty,

    fn find(s: *Scope, name: []const u8) ?*Binding {
        for (s.names.items) |*b| if (std.mem.eql(u8, b.name, name)) return b;
        return null;
    }

    fn add(s: *Scope, a: std.mem.Allocator, name: []const u8, k: @FieldType(Binding, "kind"), at: u32) Error!void {
        if (s.find(name)) |b| {
            if (at < b.at) b.at = at;
            return;
        }
        try s.names.append(a, .{ .name = name, .kind = k, .at = at });
    }
};

const Linter = struct {
    a: std.mem.Allocator,
    src: []const u8,
    root: c.TSNode,
    diags: std.ArrayList(Diag) = .empty,

    fn report(l: *Linter, node: c.TSNode, comptime fmt: []const u8, args: anytype) Error!void {
        const lc = ts.lineCol(node);
        try l.diags.append(l.a, .{ .line = lc.line, .col = lc.col, .msg = try std.fmt.allocPrint(l.a, fmt, args) });
    }

    // ------------------------------------------------------------ syntax

    fn syntax(l: *Linter, node: c.TSNode) Error!void {
        if (c.ts_node_is_missing(node)) return l.report(node, "syntax error: missing `{s}`", .{ts.kind(node)});
        if (ts.is(node, "ERROR")) {
            const t = ts.text(l.src, node);
            const shown = if (std.mem.indexOfScalar(u8, t, '\n')) |nl| t[0..nl] else t;
            return l.report(node, "syntax error at `{s}`", .{shown});
        }
        var i: u32 = 0;
        while (i < ts.childCount(node)) : (i += 1) try l.syntax(ts.child(node, i));
    }

    // ------------------------------------------------------------ scopes

    /// The names bound in `node`'s scope: what a `let`, `def`, `for`
    /// or pattern anywhere in it binds — anywhere, because a block
    /// under `if`/`for`/`while`/`try`/an arm binds in the enclosing
    /// frame. Function bodies are their own scopes and are skipped.
    fn collect(l: *Linter, node: c.TSNode, s: *Scope) Error!void {
        const k = ts.kind(node);
        if (std.mem.eql(u8, k, "let_statement")) {
            try s.add(l.a, ts.text(l.src, ts.field(node, "name").?), .let, ts.startByte(node));
        } else if (std.mem.eql(u8, k, "def_statement")) {
            try s.add(l.a, ts.text(l.src, ts.field(node, "name").?), .def, ts.startByte(node));
            return; // the body is its own scope
        } else if (std.mem.eql(u8, k, "fn_expression") or std.mem.eql(u8, k, "lambda_block")) {
            return;
        } else if (std.mem.eql(u8, k, "for_statement")) {
            try s.add(l.a, ts.text(l.src, ts.field(node, "name").?), .for_, ts.startByte(node));
        } else if (std.mem.eql(u8, k, "bind_pattern")) {
            try s.add(l.a, varName(ts.text(l.src, node)), .pattern, ts.startByte(node));
            return;
        } else if (std.mem.eql(u8, k, "rest_pattern")) {
            if (ts.childCount(node) > 1) try s.add(l.a, varName(ts.text(l.src, ts.child(node, 1))), .pattern, ts.startByte(node));
            return;
        } else if (std.mem.eql(u8, k, "record_field_pattern")) {
            const key = ts.field(node, "key").?;
            if (ts.is(key, "identifier")) try s.add(l.a, ts.text(l.src, key), .pattern, ts.startByte(node));
        }
        var i: u32 = 0;
        while (i < ts.childCount(node)) : (i += 1) try l.collect(ts.child(node, i), s);
    }

    /// A function scope: its parameters and implicit names, then its
    /// body's bindings, then the checks over the body.
    fn functionScope(l: *Linter, params: ?c.TSNode, body: c.TSNode, implicit: []const []const u8, parent: *Scope) Error!void {
        var s = Scope{ .parent = parent, .file_level = false };
        for (implicit) |n| try s.add(l.a, n, .implicit, 0);
        if (params) |ps| {
            var i: u32 = 0;
            while (i < ts.childCount(ps)) : (i += 1) {
                const p = ts.child(ps, i);
                if (ts.is(p, "identifier")) try s.add(l.a, ts.text(l.src, p), .param, ts.startByte(p));
            }
        }
        try l.collect(body, &s);
        try l.check(body, &s);
        try l.unused(&s);
    }

    fn check(l: *Linter, node: c.TSNode, s: *Scope) Error!void {
        const k = ts.kind(node);
        if (std.mem.eql(u8, k, "def_statement")) {
            const name = ts.text(l.src, ts.field(node, "name").?);
            for (mshl.builtin_names) |b| if (std.mem.eql(u8, b, name)) try l.report(node, "def {s} shadows the builtin `{s}`", .{ name, name });
            return l.functionScope(ts.field(node, "parameters"), ts.field(node, "body").?, &.{"in"}, s);
        }
        if (std.mem.eql(u8, k, "fn_expression")) return l.functionScope(ts.field(node, "parameters"), ts.field(node, "body").?, &.{"in"}, s);
        if (std.mem.eql(u8, k, "lambda_block")) return l.functionScope(null, ts.child(node, 0), &implicit_names, s);
        if (std.mem.eql(u8, k, "bind_pattern") or std.mem.eql(u8, k, "rest_pattern")) return;
        if (std.mem.eql(u8, k, "variable")) return l.use(node, varName(ts.text(l.src, node)), s);
        if (std.mem.eql(u8, k, "interpolation")) return l.use(node, ts.text(l.src, ts.child(node, 1)), s);
        if (std.mem.eql(u8, k, "match_expression")) try l.matchArms(node);
        if (std.mem.eql(u8, k, "record")) try l.recordKeys(node);
        var i: u32 = 0;
        while (i < ts.childCount(node)) : (i += 1) try l.check(ts.child(node, i), s);
    }

    fn use(l: *Linter, node: c.TSNode, name: []const u8, s: *Scope) Error!void {
        var cur: ?*Scope = s;
        while (cur) |sc| : (cur = sc.parent) {
            if (sc.find(name)) |b| {
                b.uses += 1;
                if (sc == s and b.kind == .let and ts.startByte(node) < b.at) {
                    if (s.parent != null and s.parent.?.find(name) != null) return; // the outer one, until then
                    try l.report(node, "${s} is used before `let {s}`", .{ name, name });
                }
                return;
            }
        }
        try l.report(node, "${s} is not bound anywhere in scope", .{name});
    }

    fn unused(l: *Linter, s: *Scope) Error!void {
        if (s.file_level) return;
        for (s.names.items) |b| {
            if (b.kind != .let or b.uses > 0) continue;
            const lc = c.ts_node_start_point(c.ts_node_descendant_for_byte_range(l.root, b.at, b.at));
            try l.diags.append(l.a, .{ .line = lc.row + 1, .col = lc.column + 1, .msg = try std.fmt.allocPrint(l.a, "let {s} is never used", .{b.name}) });
        }
    }

    // ------------------------------------------------------------- match

    fn matchArms(l: *Linter, node: c.TSNode) Error!void {
        var catch_all = false;
        var ok_all = false;
        var err_all = false;
        var true_lit = false;
        var false_lit = false;
        var i: u32 = 0;
        while (i < ts.childCount(node)) : (i += 1) {
            const arm = ts.child(node, i);
            if (!ts.is(arm, "match_arm")) continue;
            if (catch_all) {
                try l.report(arm, "unreachable arm: a catch-all arm comes before it", .{});
                continue;
            }
            if (ts.field(arm, "guard") != null) continue;
            const pat = ts.field(arm, "pattern").?;
            if (irrefutable(pat)) catch_all = true;
            if (ts.is(pat, "result_pattern")) {
                const inner = ts.child(pat, 1);
                if (irrefutable(inner)) {
                    if (std.mem.eql(u8, ts.text(l.src, ts.child(pat, 0)), "ok")) ok_all = true else err_all = true;
                }
            }
            if (ts.is(pat, "boolean")) {
                if (std.mem.eql(u8, ts.text(l.src, pat), "true")) true_lit = true else false_lit = true;
            }
        }
        if (catch_all or (ok_all and err_all) or (true_lit and false_lit)) return;
        if (ok_all) return l.report(node, "match: not exhaustive — no `err _ =>` arm", .{});
        if (err_all) return l.report(node, "match: not exhaustive — no `ok _ =>` arm", .{});
        return l.report(node, "match: not exhaustive — add a `_ =>` arm", .{});
    }

    fn irrefutable(pat: c.TSNode) bool {
        return ts.is(pat, "wildcard_pattern") or ts.is(pat, "bind_pattern");
    }

    // ------------------------------------------------------------ records

    fn recordKeys(l: *Linter, node: c.TSNode) Error!void {
        var seen: std.ArrayList([]const u8) = .empty;
        var i: u32 = 0;
        while (i < ts.childCount(node)) : (i += 1) {
            const f = ts.child(node, i);
            if (!ts.is(f, "record_field")) continue;
            const key = ts.text(l.src, ts.field(f, "key").?);
            for (seen.items) |k| if (std.mem.eql(u8, k, key)) {
                try l.report(f, "record: `{s}` given twice", .{key});
                break;
            };
            try seen.append(l.a, key);
        }
    }

    /// A unit file is one record; its keys are the loader's.
    fn unitKeys(l: *Linter, root: c.TSNode) Error!void {
        const rec = firstRecord(root) orelse return l.report(root, "unit: a record expected", .{});
        var i: u32 = 0;
        while (i < ts.childCount(rec)) : (i += 1) {
            const f = ts.child(rec, i);
            if (!ts.is(f, "record_field")) continue;
            const key = ts.text(l.src, ts.field(f, "key").?);
            const bare = key[0 .. key.len - 1];
            var known = false;
            for (unit_keys) |k| known = known or std.mem.eql(u8, k, bare);
            if (!known) try l.report(f, "unit: `{s}` is not a key the unit loader reads", .{key});
        }
    }

    fn firstRecord(node: c.TSNode) ?c.TSNode {
        if (ts.is(node, "record")) return node;
        var i: u32 = 0;
        while (i < ts.childCount(node)) : (i += 1) {
            const ch = ts.child(node, i);
            if (ts.is(ch, "comment")) continue;
            if (firstRecord(ch)) |r| return r;
        }
        return null;
    }
};

fn varName(v: []const u8) []const u8 {
    return if (v.len > 0 and v[0] == '$') v[1..] else v;
}

fn isUnitPath(path: []const u8) bool {
    return std.mem.indexOf(u8, path, "conf/units/") != null or std.mem.indexOf(u8, path, "conf/session/") != null;
}

/// Lint `src` (from `path`, which decides whether it is a unit file).
/// Diagnostics in source order.
pub fn lint(a: std.mem.Allocator, path: []const u8, src: []const u8) Error![]Diag {
    const tree = try ts.Tree.parse(src);
    defer tree.deinit();
    const root = tree.root();
    var l = Linter{ .a = a, .src = src, .root = root };
    if (c.ts_node_has_error(root)) {
        try l.syntax(root);
        return l.diags.items;
    }
    var top = Scope{ .parent = null, .file_level = true };
    for (implicit_names) |n| try top.add(a, n, .implicit, 0);
    try l.collect(root, &top);
    try l.check(root, &top);
    if (isUnitPath(path)) try l.unitKeys(root);
    std.mem.sort(Diag, l.diags.items, {}, struct {
        fn lt(_: void, x: Diag, y: Diag) bool {
            return x.line < y.line or (x.line == y.line and x.col < y.col);
        }
    }.lt);
    return l.diags.items;
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    var stdin: ?[]const u8 = null;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next();
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--stdin")) {
            stdin = if (it.next()) |n| try a.dupe(u8, n) else "<stdin>";
        } else try files.append(a, try a.dupe(u8, arg));
    }
    if (stdin == null and files.items.len == 0) {
        std.debug.print("usage: mshlint FILE...  |  mshlint --stdin [NAME]\n", .{});
        return 2;
    }
    var wbuf: [4096]u8 = undefined;
    var w = std.Io.File.stdout().writer(io, &wbuf);
    defer w.interface.flush() catch {};
    var count: usize = 0;
    const cwd = std.Io.Dir.cwd();
    if (stdin) |name| {
        var rbuf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &rbuf);
        const src = try reader.interface.allocRemaining(a, .unlimited);
        count += try emit(&w.interface, name, try lint(a, name, src));
    }
    for (files.items) |path| {
        const src = cwd.readFileAlloc(io, path, a, .limited(16 << 20)) catch {
            try w.interface.print("{s}: cannot read\n", .{path});
            count += 1;
            continue;
        };
        count += try emit(&w.interface, path, try lint(a, path, src));
    }
    return if (count > 0) 1 else 0;
}

fn emit(w: *std.Io.Writer, path: []const u8, diags: []const Diag) !usize {
    for (diags) |d| try w.print("{s}:{d}:{d}: {s}\n", .{ path, d.line, d.col, d.msg });
    return diags.len;
}

// ------------------------------------------------------------------ tests

fn expectDiags(src: []const u8, expected: []const []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diags = try lint(arena.allocator(), "test.msh", src);
    var got: std.Io.Writer.Allocating = .init(arena.allocator());
    for (diags) |d| try got.writer.print("{d}:{d}: {s}\n", .{ d.line, d.col, d.msg });
    var want: std.Io.Writer.Allocating = .init(arena.allocator());
    for (expected) |e| try want.writer.print("{s}\n", .{e});
    try std.testing.expectEqualStrings(want.written(), got.written());
}

test "clean code says nothing" {
    try expectDiags(
        \\let n = 3
        \\def double [x] { $x * 2 }
        \\for f in (ls data) { echo $f.name }
        \\ls | where size > 1kb | map { $it.name } | each { echo "$it" }
        \\match (stat data) {
        \\  ok $s => echo $s.type
        \\  err $e => echo $e
        \\}
        \\let m = (use scripts/lib.msh)
        \\$m.double $n
        \\
    , &.{});
}

test "unbound and used-before-let" {
    try expectDiags(
        \\echo $nope
        \\echo $x
        \\let x = 1
        \\def f { echo $later }
        \\let later = 2
        \\echo "hi $who"
        \\
    , &.{
        "1:6: $nope is not bound anywhere in scope",
        "2:6: $x is used before `let x`",
        "6:10: $who is not bound anywhere in scope",
    });
}

test "unused let inside a function, not at the top" {
    try expectDiags(
        \\let exported = 1
        \\def f [a] {
        \\  let unused = $a
        \\  let used = $a
        \\  echo $used
        \\}
        \\
    , &.{"3:3: let unused is never used"});
}

test "match: the interpreter's exhaustiveness, and dead arms" {
    try expectDiags(
        \\let r = 1
        \\match $r { ok $v => echo $v }
        \\match $r { err $e => echo $e }
        \\match $r { 1 => echo one }
        \\match $r { true => echo t; false => echo f }
        \\match $r { $x if $x > 1 => echo big }
        \\match $r { _ => echo any; 1 => echo one }
        \\
    , &.{
        "2:1: match: not exhaustive — no `err _ =>` arm",
        "3:1: match: not exhaustive — no `ok _ =>` arm",
        "4:1: match: not exhaustive — add a `_ =>` arm",
        "6:1: match: not exhaustive — add a `_ =>` arm",
        "7:27: unreachable arm: a catch-all arm comes before it",
    });
}

test "records: duplicate keys; def shadowing a builtin" {
    try expectDiags(
        \\let r = { a: 1, b: 2, a: 3 }
        \\def map [x] { $x }
        \\
    , &.{
        "1:23: record: `a:` given twice",
        "2:1: def map shadows the builtin `map`",
    });
}

test "unit files: the loader's keys" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diags = try lint(arena.allocator(), "boot/conf/units/x.msh",
        \\# a unit
        \\{ image: fs, args: 1, give: [{ tag: view, fs: "" }] }
        \\
    );
    try std.testing.expectEqual(@as(usize, 1), diags.len);
    try std.testing.expectEqualStrings("unit: `args:` is not a key the unit loader reads", diags[0].msg);
    const none = try lint(arena.allocator(), "boot/scripts/x.msh", "{ image: fs, args: 1 }\n");
    try std.testing.expectEqual(@as(usize, 0), none.len);
}

test "syntax errors are located" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const diags = try lint(arena.allocator(), "t.msh", "let x = (1 + \n");
    try std.testing.expect(diags.len >= 1);
    try std.testing.expect(std.mem.startsWith(u8, diags[0].msg, "syntax error"));
}
