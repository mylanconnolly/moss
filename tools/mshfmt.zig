//! mshfmt — the formatter for mshl, built on the tree-sitter grammar in
//! tools/tree-sitter-mshl (one definition of the syntax for every tool).
//! It keeps the author's line breaks and comments and normalizes the
//! rest: one space between tokens, none inside `()` and `[]`, spaces
//! inside `{ }`, `key: value`, spaced operators and pipes, indentation
//! by nesting depth, at most one blank line, no trailing whitespace —
//! and in a record written one field per line, the values of
//! neighbouring one-line fields aligned (as gofmt aligns). A file that
//! does not parse is left alone and reported. Usage:
//!
//!   mshfmt FILE...          rewrite in place
//!   mshfmt --check FILE...  exit 1 if any file would change
//!   mshfmt --stdin          format standard input to standard output
//!
//! The formatter's own tests format every .msh file in the tree, check
//! that formatting is idempotent, and that the formatted text parses to
//! the same tree as the original.

const std = @import("std");
const c = @cImport({
    @cInclude("tree_sitter/api.h");
});

extern fn tree_sitter_mshl() callconv(.c) *const c.TSLanguage;

pub const Error = error{ OutOfMemory, ParseError };

/// A leaf of the tree in source order: what to print, and what kind of
/// thing it is (the kinds decide the spacing between neighbours).
const Leaf = struct {
    text: []const u8,
    kind: Kind,
    /// Lines between this leaf and the previous one in the source.
    newlines: u32,
    /// Extra spaces after this leaf: a record key padded so the values
    /// of neighbouring one-line fields line up.
    pad: u32 = 0,

    const Kind = enum { open, close, comma, semi, pipe, op, assign, arrow, dot, unwrap, key, word, comment, string, dollar_immediate, redirect };
};

const Formatter = struct {
    a: std.mem.Allocator,
    src: []const u8,
    leaves: std.ArrayList(Leaf) = .empty,
    out: std.ArrayList(u8) = .empty,
    /// Padding decided per record key, by the key's start byte.
    pads: std.AutoHashMapUnmanaged(u32, u32) = .empty,

    /// Collect the leaves in order. Some named nodes are atomic — their
    /// text is copied whole — so a string's insides or a `$name` are
    /// never re-spaced.
    fn collect(f: *Formatter, node: c.TSNode) Error!void {
        const kind_z = c.ts_node_type(node);
        const kind = std.mem.span(kind_z);
        const atomic = std.mem.eql(u8, kind, "string") or std.mem.eql(u8, kind, "variable") or
            std.mem.eql(u8, kind, "number") or std.mem.eql(u8, kind, "record_key") or
            std.mem.eql(u8, kind, "comment") or std.mem.eql(u8, kind, "identifier") or
            std.mem.eql(u8, kind, "wildcard_pattern") or std.mem.eql(u8, kind, "boolean") or
            std.mem.eql(u8, kind, "null") or std.mem.eql(u8, kind, "rest_pattern");
        const n = c.ts_node_child_count(node);
        if (n == 0 or atomic) {
            const s = c.ts_node_start_byte(node);
            const e = c.ts_node_end_byte(node);
            if (e <= s) return;
            const text = f.src[s..e];
            try f.leaves.append(f.a, .{
                .text = text,
                .kind = leafKind(kind, text, c.ts_node_is_named(node)),
                .newlines = f.newlinesBefore(s),
                .pad = if (f.pads.get(s)) |pad| pad else 0,
            });
            return;
        }
        if (std.mem.eql(u8, kind, "record")) try f.alignFields(node);
        var i: u32 = 0;
        while (i < n) : (i += 1) try f.collect(c.ts_node_child(node, i));
    }

    /// In a record written one field per line, a run of one-line fields
    /// on consecutive lines gets its values aligned: every key in the
    /// run is padded to the longest. A field that spans lines, a blank
    /// line or a comment on its own line ends the run (as gofmt does).
    fn alignFields(f: *Formatter, node: c.TSNode) Error!void {
        const n = c.ts_node_child_count(node);
        var run_start: u32 = 0;
        var run_len: u32 = 0;
        var run_max: u32 = 0;
        var last_row: u32 = 0;
        var i: u32 = 0;
        while (i <= n) : (i += 1) {
            var ends_run = true;
            if (i < n) {
                const ch = c.ts_node_child(node, i);
                if (std.mem.eql(u8, std.mem.span(c.ts_node_type(ch)), "record_field")) {
                    const key = c.ts_node_child_by_field_name(ch, "key", 3);
                    const row = c.ts_node_start_point(ch).row;
                    if (ownLine(node, i) and (run_len == 0 or row == last_row + 1)) {
                        if (run_len == 0) run_start = i;
                        run_len += 1;
                        run_max = @max(run_max, c.ts_node_end_byte(key) - c.ts_node_start_byte(key));
                        last_row = row;
                        ends_run = false;
                    }
                } else if (!c.ts_node_is_named(ch)) ends_run = false; // `,` `;` and the line breaks between fields
            }
            if (!ends_run) continue;
            if (run_len > 1) {
                var j = run_start;
                while (j < i) : (j += 1) {
                    const ch = c.ts_node_child(node, j);
                    if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(ch)), "record_field")) continue;
                    const key = c.ts_node_child_by_field_name(ch, "key", 3);
                    const len = c.ts_node_end_byte(key) - c.ts_node_start_byte(key);
                    try f.pads.put(f.a, c.ts_node_start_byte(key), run_max - len);
                }
            }
            run_len = 0;
            run_max = 0;
            // A field that broke the run (not on the next line) may start a new one.
            if (i < n and ownLine(node, i)) {
                const ch = c.ts_node_child(node, i);
                const key = c.ts_node_child_by_field_name(ch, "key", 3);
                run_start = i;
                run_len = 1;
                run_max = c.ts_node_end_byte(key) - c.ts_node_start_byte(key);
                last_row = c.ts_node_start_point(ch).row;
            }
        }
    }

    /// Child `i` of a record is a field that has a line to itself: it
    /// spans one line and no sibling field shares it.
    fn ownLine(node: c.TSNode, i: u32) bool {
        const n = c.ts_node_child_count(node);
        const ch = c.ts_node_child(node, i);
        if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(ch)), "record_field")) return false;
        const row = c.ts_node_start_point(ch).row;
        if (row != c.ts_node_end_point(ch).row) return false;
        var j = i;
        while (j > 0) {
            j -= 1;
            const o = c.ts_node_child(node, j);
            if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(o)), "record_field")) continue;
            if (c.ts_node_end_point(o).row == row) return false;
            break;
        }
        j = i + 1;
        while (j < n) : (j += 1) {
            const o = c.ts_node_child(node, j);
            if (!std.mem.eql(u8, std.mem.span(c.ts_node_type(o)), "record_field")) continue;
            if (c.ts_node_start_point(o).row == row) return false;
            break;
        }
        return true;
    }

    fn newlinesBefore(f: *Formatter, at: u32) u32 {
        var i = at;
        var n: u32 = 0;
        while (i > 0) : (i -= 1) {
            const ch = f.src[i - 1];
            if (ch == '\n') n += 1 else if (ch != ' ' and ch != '\t' and ch != '\r') break;
        }
        return n;
    }

    fn leafKind(node_kind: []const u8, text: []const u8, named: bool) Leaf.Kind {
        if (std.mem.eql(u8, node_kind, "comment")) return .comment;
        if (std.mem.eql(u8, node_kind, "string")) return .string;
        if (std.mem.eql(u8, node_kind, "record_key")) return .key;
        if (std.mem.eql(u8, node_kind, "rest_pattern")) return .word;
        if (named) return .word;
        if (text.len == 1) switch (text[0]) {
            '(', '[', '{' => return .open,
            ')', ']', '}' => return .close,
            ',' => return .comma,
            ';' => return .semi,
            '|' => return .pipe,
            '.' => return .dot,
            '?' => return .unwrap,
            '=' => return .assign,
            '>' => return .redirect,
            '\n' => return .semi,
            else => {},
        };
        if (std.mem.eql(u8, text, "=>")) return .arrow;
        if (std.mem.eql(u8, text, "==") or std.mem.eql(u8, text, "!=") or std.mem.eql(u8, text, "<") or std.mem.eql(u8, text, "<=") or
            std.mem.eql(u8, text, ">=") or std.mem.eql(u8, text, "+") or std.mem.eql(u8, text, "-") or std.mem.eql(u8, text, "*") or
            std.mem.eql(u8, text, "/") or std.mem.eql(u8, text, "%")) return .op;
        return .word; // keywords: let, def, if, and, or, not, ok, err …
    }

    /// Emit the leaves with the spacing rules.
    fn emit(f: *Formatter) Error!void {
        var depth: usize = 0;
        var at_line_start = true;
        var prev: ?Leaf = null;
        var i: usize = 0;
        while (i < f.leaves.items.len) : (i += 1) {
            const leaf = f.leaves.items[i];
            if (leaf.kind == .semi and std.mem.eql(u8, leaf.text, "\n")) continue; // separators are the newlines we keep
            if (leaf.kind == .close) depth -|= 1;
            // Line breaks: keep the author's, at most one blank line; a
            // closing bracket on its own line; a comment where it was.
            const breaks: u32 = if (prev == null) 0 else @min(leaf.newlines, 2);
            if (breaks > 0) {
                try f.trimTrailing();
                var k: u32 = 0;
                while (k < breaks) : (k += 1) try f.out.append(f.a, '\n');
                at_line_start = true;
            }
            if (at_line_start) {
                try f.out.appendNTimes(f.a, ' ', depth * 2);
                at_line_start = false;
            } else if (prev != null and needSpace(prev.?, leaf)) {
                try f.out.append(f.a, ' ');
            }
            try f.out.appendSlice(f.a, leaf.text);
            try f.out.appendNTimes(f.a, ' ', leaf.pad);
            if (leaf.kind == .open) depth += 1;
            prev = leaf;
        }
        try f.trimTrailing();
        try f.out.append(f.a, '\n');
    }

    fn trimTrailing(f: *Formatter) Error!void {
        while (f.out.items.len > 0 and (f.out.items[f.out.items.len - 1] == ' ' or f.out.items[f.out.items.len - 1] == '\t')) _ = f.out.pop();
    }

    /// One space between most neighbours; none inside brackets, before
    /// punctuation that closes, around a glued `.` or `?`, after `$`.
    fn needSpace(p: Leaf, n: Leaf) bool {
        if (n.kind == .comment) return true;
        if (p.kind == .comment) return true;
        if (p.kind == .dot or n.kind == .dot) return false;
        if (n.kind == .unwrap) return false;
        if (n.kind == .comma or n.kind == .semi) return false;
        if (p.kind == .open) return std.mem.eql(u8, p.text, "{"); // `{ a: 1 }`, `[1]`, `(x)`
        if (n.kind == .close) return std.mem.eql(u8, n.text, "}");
        if (p.kind == .dollar_immediate) return false;
        return true;
    }
};

/// Format `src`; null if it does not parse.
pub fn format(a: std.mem.Allocator, src: []const u8) Error!?[]u8 {
    const parser = c.ts_parser_new() orelse return Error.OutOfMemory;
    defer c.ts_parser_delete(parser);
    if (!c.ts_parser_set_language(parser, tree_sitter_mshl())) return Error.ParseError;
    const tree = c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse return Error.OutOfMemory;
    defer c.ts_tree_delete(tree);
    const root = c.ts_tree_root_node(tree);
    if (c.ts_node_has_error(root)) return null;
    var f = Formatter{ .a = a, .src = src };
    try f.collect(root);
    try f.emit();
    return f.out.items;
}

/// The tree's shape as an S-expression without positions, to compare
/// the formatted text's parse with the original's.
pub fn sexp(a: std.mem.Allocator, src: []const u8) Error![]u8 {
    const parser = c.ts_parser_new() orelse return Error.OutOfMemory;
    defer c.ts_parser_delete(parser);
    _ = c.ts_parser_set_language(parser, tree_sitter_mshl());
    const tree = c.ts_parser_parse_string(parser, null, src.ptr, @intCast(src.len)) orelse return Error.OutOfMemory;
    defer c.ts_tree_delete(tree);
    const s = c.ts_node_string(c.ts_tree_root_node(tree));
    defer std.c.free(s);
    return a.dupe(u8, std.mem.span(s));
}

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const a = init.arena.allocator();
    var files: std.ArrayList([]const u8) = .empty;
    var check = false;
    var stdin = false;
    var it = std.process.Args.Iterator.init(init.minimal.args);
    _ = it.next(); // the program
    while (it.next()) |arg| {
        if (std.mem.eql(u8, arg, "--check")) check = true else if (std.mem.eql(u8, arg, "--stdin")) stdin = true else try files.append(a, try a.dupe(u8, arg));
    }
    const cwd = std.Io.Dir.cwd();
    if (stdin) {
        var rbuf: [4096]u8 = undefined;
        var reader = std.Io.File.stdin().reader(io, &rbuf);
        const src = try reader.interface.allocRemaining(a, .unlimited);
        const out = (try format(a, src)) orelse {
            std.debug.print("mshfmt: input does not parse\n", .{});
            return 2;
        };
        var wbuf: [4096]u8 = undefined;
        var w = std.Io.File.stdout().writer(io, &wbuf);
        try w.interface.writeAll(out);
        try w.interface.flush();
        return 0;
    }
    if (files.items.len == 0) {
        std.debug.print("usage: mshfmt [--check] FILE...  |  mshfmt --stdin\n", .{});
        return 2;
    }
    var changed: usize = 0;
    var bad: usize = 0;
    for (files.items) |path| {
        const src = cwd.readFileAlloc(io, path, a, .limited(16 << 20)) catch {
            std.debug.print("mshfmt: cannot read {s}\n", .{path});
            bad += 1;
            continue;
        };
        const out = (try format(a, src)) orelse {
            std.debug.print("mshfmt: {s} does not parse; left alone\n", .{path});
            bad += 1;
            continue;
        };
        if (std.mem.eql(u8, out, src)) continue;
        changed += 1;
        if (check) {
            std.debug.print("mshfmt: {s} would change\n", .{path});
        } else {
            try cwd.writeFile(io, .{ .sub_path = path, .data = out });
            std.debug.print("mshfmt: {s} formatted\n", .{path});
        }
    }
    return if (bad > 0 or (check and changed > 0)) 1 else 0;
}

// ------------------------------------------------------------------ tests

fn expectFormat(src: []const u8, expected: []const u8) !void {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const out = (try format(a, src)) orelse return error.DidNotParse;
    try std.testing.expectEqualStrings(expected, out);
    // Idempotent, and the same tree as the source.
    const again = (try format(a, out)) orelse return error.DidNotParse;
    try std.testing.expectEqualStrings(out, again);
    try std.testing.expectEqualStrings(try sexp(a, src), try sexp(a, out));
}

test "spacing: tokens, brackets, pipes, operators" {
    try expectFormat("ls   data|where  size>1kb  |get name\n", "ls data | where size > 1kb | get name\n");
    try expectFormat("let x=( 1 + 2 )*3;$x\n", "let x = (1 + 2) * 3; $x\n");
    // A word is a word: `1+2` unspaced is the string "1+2", in the language and here.
    try expectFormat("echo 1+2   a-b\n", "echo 1+2 a-b\n");
    try expectFormat("[ 1,2 ,3 ]|map{ $it * 2 }\n", "[1, 2, 3] | map { $it * 2 }\n");
    try expectFormat("{a:1,b:two}.b\n", "{ a: 1, b: two }.b\n");
    try expectFormat("(stat data).type==dir\n", "(stat data).type == dir\n");
    try expectFormat("let s=(connect 10.0.2.100 9000)?\n", "let s = (connect 10.0.2.100 9000)?\n");
    try expectFormat("echo hello   world>data/hello.txt\n", "echo hello world > data/hello.txt\n");
    try expectFormat("$m.double   4\n", "$m.double 4\n");
}

test "lines: the author's breaks, indentation by depth, comments kept" {
    try expectFormat(
        \\def handler [req] {
        \\match $req.path {
        \\"/hello" => "hello from moss"   # a comment
        \\_ => { status: 404, body: "no such page" }
        \\}
        \\}
        \\
        \\
        \\
        \\# trailing comment
    ,
        \\def handler [req] {
        \\  match $req.path {
        \\    "/hello" => "hello from moss" # a comment
        \\    _ => { status: 404, body: "no such page" }
        \\  }
        \\}
        \\
        \\# trailing comment
        \\
    );
    try expectFormat(
        \\{
        \\  image:  fs
        \\  give: [
        \\    { tag: buf,  shm: 1 }
        \\  ]
        \\}
    ,
        \\{
        \\  image: fs
        \\  give: [
        \\    { tag: buf, shm: 1 }
        \\  ]
        \\}
        \\
    );
}

test "records: one-line fields on consecutive lines align their values" {
    try expectFormat(
        \\{
        \\  image:     shell
        \\  budget: { user: 8mb }
        \\  essential: true
        \\  give: [
        \\    { tag: console,  unit: cons }
        \\    { tag: view, fs: "", ro: false }
        \\  ]
        \\  a: 1
        \\
        \\  bb: 2
        \\  # a comment ends a run too
        \\  ccc: 3
        \\  d: 4
        \\}
        \\{ image: users, run: true,
        \\  give: [ { tag: view } ] }
    ,
        \\{
        \\  image:     shell
        \\  budget:    { user: 8mb }
        \\  essential: true
        \\  give: [
        \\    { tag: console, unit: cons }
        \\    { tag: view, fs: "", ro: false }
        \\  ]
        \\  a: 1
        \\
        \\  bb: 2
        \\  # a comment ends a run too
        \\  ccc: 3
        \\  d:   4
        \\}
        \\{ image: users, run: true,
        \\  give: [{ tag: view }] }
        \\
    );
}

test "strings are copied whole" {
    try expectFormat("send $c \"GET /raw?x=1 HTTP/1.1\\r\\nHost:   moss\"\n", "send $c \"GET /raw?x=1 HTTP/1.1\\r\\nHost:   moss\"\n");
    try expectFormat("echo \"hello $name!\"\n", "echo \"hello $name!\"\n");
}

test "what does not parse is left alone" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    try std.testing.expect((try format(arena.allocator(), "if true { echo x\n")) == null);
}
