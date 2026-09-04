//! mshls — the language server for mshl, on the same parser as mshfmt
//! and mshlint (tools/mshtree.zig): diagnostics are the lint's, hover,
//! go-to-definition and completion come from its scopes, formatting is
//! the formatter's. LSP over stdio (Content-Length framing, JSON-RPC),
//! whole-document sync — a script is small, and re-analysis is cheap.
//!
//!   initialize / initialized / shutdown / exit
//!   textDocument/didOpen, didChange (full), didClose → publishDiagnostics
//!   textDocument/hover        what a `$name` or a command's name is bound to
//!   textDocument/definition   where that binding is
//!   textDocument/formatting   one edit replacing the document with mshfmt's
//!   textDocument/documentSymbol   the file's `def`s and `let`s
//!   textDocument/completion   the names in scope, and the builtins
//!
//! `Server.handle` takes one message and appends any replies to `out`,
//! so the tests drive it without a transport; `main` is the framing.

const std = @import("std");
const mshlint = @import("mshlint");
const mshfmt = @import("mshfmt");
const mshl = @import("mshl");
const json = std.json;

const version = "0.1";

/// LSP positions: a line, and a column in UTF-16 code units.
const Position = struct { line: u32, character: u32 };
const Range = struct { start: Position, end: Position };

fn byteToPos(src: []const u8, at: usize) Position {
    const to = @min(at, src.len);
    var line: u32 = 0;
    var line_start: usize = 0;
    for (src[0..to], 0..) |ch, i| if (ch == '\n') {
        line += 1;
        line_start = i + 1;
    };
    var col: u32 = 0;
    var i = line_start;
    while (i < to) {
        const n = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        col += if (n == 4) 2 else 1;
        i += n;
    }
    return .{ .line = line, .character = col };
}

fn posToByte(src: []const u8, pos: Position) usize {
    var line: u32 = 0;
    var i: usize = 0;
    while (line < pos.line and i < src.len) : (i += 1) if (src[i] == '\n') {
        line += 1;
    };
    var col: u32 = 0;
    while (i < src.len and src[i] != '\n' and col < pos.character) {
        const n = std.unicode.utf8ByteSequenceLength(src[i]) catch 1;
        col += if (n == 4) 2 else 1;
        i += n;
    }
    return i;
}

fn rangeOf(src: []const u8, start: usize, end: usize) Range {
    return .{ .start = byteToPos(src, start), .end = byteToPos(src, end) };
}

// ------------------------------------------------------------ messages

const Diagnostic = struct { range: Range, severity: u8, source: []const u8 = "mshlint", message: []const u8 };
const Location = struct { uri: []const u8, range: Range };
const TextEdit = struct { range: Range, newText: []const u8 };
const MarkupContent = struct { kind: []const u8 = "markdown", value: []const u8 };
const Hover = struct { contents: MarkupContent, range: Range };
const DocumentSymbol = struct { name: []const u8, detail: []const u8, kind: u8, range: Range, selectionRange: Range };
const CompletionItem = struct { label: []const u8, kind: u8, detail: []const u8 };

const symbol_function = 12;
const symbol_variable = 13;
const completion_function = 3;
const completion_variable = 6;

const Capabilities = struct {
    textDocumentSync: u8 = 1, // full
    hoverProvider: bool = true,
    definitionProvider: bool = true,
    documentFormattingProvider: bool = true,
    documentSymbolProvider: bool = true,
    completionProvider: struct { triggerCharacters: []const []const u8 = &.{"$"} } = .{},
};

const InitializeResult = struct {
    capabilities: Capabilities = .{},
    serverInfo: struct { name: []const u8 = "mshls", version: []const u8 = version } = .{},
};

pub const Server = struct {
    gpa: std.mem.Allocator,
    docs: std.StringHashMapUnmanaged(Doc) = .empty,
    /// Framed messages to send, in order.
    out: std.ArrayList(u8) = .empty,
    shutdown: bool = false,
    exit: bool = false,

    const Doc = struct { text: []u8 };

    pub fn deinit(s: *Server) void {
        var it = s.docs.iterator();
        while (it.next()) |e| {
            s.gpa.free(e.key_ptr.*);
            s.gpa.free(e.value_ptr.text);
        }
        s.docs.deinit(s.gpa);
        s.out.deinit(s.gpa);
    }

    /// One message in; replies and notifications appended to `out`.
    pub fn handle(s: *Server, msg: []const u8) !void {
        var arena = std.heap.ArenaAllocator.init(s.gpa);
        defer arena.deinit();
        const a = arena.allocator();
        const parsed = json.parseFromSliceLeaky(json.Value, a, msg, .{}) catch return s.replyError(a, .null, -32700, "parse error");
        if (parsed != .object) return s.replyError(a, .null, -32600, "invalid request");
        const id: json.Value = parsed.object.get("id") orelse .null;
        const method = switch (parsed.object.get("method") orelse @as(json.Value, .null)) {
            .string => |m| m,
            else => return s.replyError(a, id, -32600, "invalid request"),
        };
        const params = parsed.object.get("params") orelse @as(json.Value, .null);
        s.dispatch(a, id, method, params) catch |e| switch (e) {
            error.BadParams => try s.replyError(a, id, -32602, "invalid params"),
            else => return e,
        };
    }

    const DispatchError = error{ BadParams, OutOfMemory, ParseError, WriteFailed };

    fn dispatch(s: *Server, a: std.mem.Allocator, id: json.Value, method: []const u8, params: json.Value) DispatchError!void {
        const eql = std.mem.eql;
        if (eql(u8, method, "initialize")) return s.reply(a, id, InitializeResult{});
        if (eql(u8, method, "initialized")) return;
        if (eql(u8, method, "shutdown")) {
            s.shutdown = true;
            return s.reply(a, id, @as(json.Value, .null));
        }
        if (eql(u8, method, "exit")) {
            s.exit = true;
            return;
        }
        if (eql(u8, method, "textDocument/didOpen")) {
            const td = try field(params, "textDocument");
            try s.setDoc(try str(td, "uri"), try str(td, "text"));
            return s.publish(a, try str(td, "uri"));
        }
        if (eql(u8, method, "textDocument/didChange")) {
            const uri = try str(try field(params, "textDocument"), "uri");
            const changes = try field(params, "contentChanges");
            if (changes != .array or changes.array.items.len == 0) return error.BadParams;
            // Full sync: the last change is the whole text.
            try s.setDoc(uri, try str(changes.array.items[changes.array.items.len - 1], "text"));
            return s.publish(a, uri);
        }
        if (eql(u8, method, "textDocument/didClose")) {
            const uri = try str(try field(params, "textDocument"), "uri");
            if (s.docs.fetchRemove(uri)) |kv| {
                s.gpa.free(kv.key);
                s.gpa.free(kv.value.text);
            }
            return s.notify(a, "textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = &[_]Diagnostic{} });
        }
        if (eql(u8, method, "textDocument/hover")) return s.reply(a, id, try s.hover(a, params));
        if (eql(u8, method, "textDocument/definition")) return s.reply(a, id, try s.definition(a, params));
        if (eql(u8, method, "textDocument/formatting")) return s.reply(a, id, try s.formatting(a, params));
        if (eql(u8, method, "textDocument/documentSymbol")) return s.reply(a, id, try s.symbols(a, params));
        if (eql(u8, method, "textDocument/completion")) return s.reply(a, id, try s.completion(a, params));
        if (id != .null) return s.replyError(a, id, -32601, "method not found");
        // An unknown notification is ignored, as the protocol says.
    }

    // ---------------------------------------------------------- documents

    fn setDoc(s: *Server, uri: []const u8, text: []const u8) !void {
        const copy = try s.gpa.dupe(u8, text);
        if (s.docs.getPtr(uri)) |d| {
            s.gpa.free(d.text);
            d.text = copy;
            return;
        }
        try s.docs.put(s.gpa, try s.gpa.dupe(u8, uri), .{ .text = copy });
    }

    fn doc(s: *Server, params: json.Value) DispatchError!struct { uri: []const u8, text: []const u8 } {
        const uri = try str(try field(params, "textDocument"), "uri");
        const d = s.docs.get(uri) orelse return error.BadParams;
        return .{ .uri = uri, .text = d.text };
    }

    fn position(params: json.Value, text: []const u8) DispatchError!usize {
        const p = try field(params, "position");
        return posToByte(text, .{ .line = try int(p, "line"), .character = try int(p, "character") });
    }

    fn publish(s: *Server, a: std.mem.Allocator, uri: []const u8) DispatchError!void {
        const d = s.docs.get(uri) orelse return;
        var an = try mshlint.analyze(a, uri, d.text);
        defer an.deinit();
        const out = try a.alloc(Diagnostic, an.diags.len);
        for (an.diags, out) |dg, *o| o.* = .{
            .range = rangeOf(d.text, dg.start, dg.end),
            .severity = if (dg.severity == .err) 1 else 2,
            .message = dg.msg,
        };
        try s.notify(a, "textDocument/publishDiagnostics", .{ .uri = uri, .diagnostics = out });
    }

    // ----------------------------------------------------------- queries

    /// The binding under the cursor: a reference, or the definition itself.
    fn bindingUnder(an: *const mshlint.Analysis, at: usize) ?*mshlint.Binding {
        return an.refAt(@intCast(at)) orelse an.bindingAt(@intCast(at));
    }

    fn hover(s: *Server, a: std.mem.Allocator, params: json.Value) DispatchError!?Hover {
        const d = try s.doc(params);
        const at = try position(params, d.text);
        var an = try mshlint.analyze(a, d.uri, d.text);
        defer an.deinit();
        const span = wordAt(d.text, at);
        if (bindingUnder(&an, at)) |b| {
            return .{ .contents = .{ .value = try describe(a, d.text, b) }, .range = rangeOf(d.text, span.start, span.end) };
        }
        // A builtin command's name.
        const word = d.text[span.start..span.end];
        for (mshl.builtin_names) |n| if (std.mem.eql(u8, n, word)) {
            return .{ .contents = .{ .value = try std.fmt.allocPrint(a, "```msh\n{s}\n```\nbuiltin", .{n}) }, .range = rangeOf(d.text, span.start, span.end) };
        };
        return null;
    }

    fn describe(a: std.mem.Allocator, src: []const u8, b: *mshlint.Binding) ![]const u8 {
        return switch (b.kind) {
            .let, .for_ => try std.fmt.allocPrint(a, "```msh\n{s}\n```", .{firstLine(src[b.at..b.stmt_end])}),
            .def => blk: {
                // The header: up to the body's brace.
                const stmt = src[b.at..b.stmt_end];
                const head = if (std.mem.indexOfScalar(u8, stmt, '{')) |i| std.mem.trimEnd(u8, stmt[0..i], " ") else stmt;
                break :blk try std.fmt.allocPrint(a, "```msh\n{s}\n```", .{head});
            },
            .param => try std.fmt.allocPrint(a, "`${s}` — a parameter", .{b.name}),
            .pattern => try std.fmt.allocPrint(a, "`${s}` — bound by a pattern", .{b.name}),
            .implicit => try std.fmt.allocPrint(a, "`${s}` — {s}", .{ b.name, implicitDoc(b.name) }),
        };
    }

    fn implicitDoc(name: []const u8) []const u8 {
        const eql = std.mem.eql;
        if (eql(u8, name, "it")) return "the item a block argument is called with (a row, under `where`)";
        if (eql(u8, name, "in")) return "the pipeline's input to this stage or script";
        if (eql(u8, name, "acc")) return "the accumulator, in a `reduce` block";
        if (eql(u8, name, "req")) return "the request record `serve` calls a handler with";
        return "an implicit name";
    }

    fn firstLine(s: []const u8) []const u8 {
        return if (std.mem.indexOfScalar(u8, s, '\n')) |i| s[0..i] else s;
    }

    /// The `$name` or word under a byte offset.
    fn wordAt(src: []const u8, at: usize) struct { start: usize, end: usize } {
        var start = @min(at, src.len);
        var end = start;
        while (start > 0 and isWord(src[start - 1])) start -= 1;
        if (start > 0 and src[start - 1] == '$') start -= 1;
        while (end < src.len and isWord(src[end])) end += 1;
        return .{ .start = start, .end = end };
    }

    fn isWord(ch: u8) bool {
        return std.ascii.isAlphanumeric(ch) or ch == '_' or ch == '-';
    }

    fn definition(s: *Server, a: std.mem.Allocator, params: json.Value) DispatchError!?Location {
        const d = try s.doc(params);
        const at = try position(params, d.text);
        var an = try mshlint.analyze(a, d.uri, d.text);
        defer an.deinit();
        const b = bindingUnder(&an, at) orelse return null;
        if (b.kind == .implicit) return null;
        return .{ .uri = d.uri, .range = rangeOf(d.text, b.name_start, b.name_end) };
    }

    fn formatting(s: *Server, a: std.mem.Allocator, params: json.Value) DispatchError!?[]const TextEdit {
        const d = try s.doc(params);
        const out = (try mshfmt.format(a, d.text)) orelse return null; // does not parse: no edit
        if (std.mem.eql(u8, out, d.text)) return &[_]TextEdit{};
        const edits = try a.alloc(TextEdit, 1);
        edits[0] = .{ .range = rangeOf(d.text, 0, d.text.len), .newText = out };
        return edits;
    }

    fn symbols(s: *Server, a: std.mem.Allocator, params: json.Value) DispatchError![]const DocumentSymbol {
        const d = try s.doc(params);
        var an = try mshlint.analyze(a, d.uri, d.text);
        defer an.deinit();
        var out: std.ArrayList(DocumentSymbol) = .empty;
        for (an.scopes[0].names.items) |b| {
            if (b.kind != .let and b.kind != .def) continue;
            try out.append(a, .{
                .name = b.name,
                .detail = if (b.kind == .def) "def" else "let",
                .kind = if (b.kind == .def) symbol_function else symbol_variable,
                .range = rangeOf(d.text, b.at, b.stmt_end),
                .selectionRange = rangeOf(d.text, b.name_start, b.name_end),
            });
        }
        return out.items;
    }

    fn completion(s: *Server, a: std.mem.Allocator, params: json.Value) DispatchError![]const CompletionItem {
        const d = try s.doc(params);
        const at = try position(params, d.text);
        var an = try mshlint.analyze(a, d.uri, d.text);
        defer an.deinit();
        var out: std.ArrayList(CompletionItem) = .empty;
        for (try an.visible(a, @intCast(at))) |b| try out.append(a, .{
            .label = b.name,
            .kind = if (b.kind == .def) completion_function else completion_variable,
            .detail = @tagName(b.kind),
        });
        for (mshl.builtin_names) |n| try out.append(a, .{ .label = n, .kind = completion_function, .detail = "builtin" });
        return out.items;
    }

    // ------------------------------------------------------------ output

    fn reply(s: *Server, a: std.mem.Allocator, id: json.Value, result: anytype) DispatchError!void {
        // A response carries `result` even when it is null (an optional
        // would be omitted by the stringifier), so unwrap here.
        if (@typeInfo(@TypeOf(result)) == .optional) {
            if (result) |r| return s.send(a, .{ .jsonrpc = "2.0", .id = id, .result = r });
            return s.send(a, .{ .jsonrpc = "2.0", .id = id, .result = @as(json.Value, .null) });
        }
        try s.send(a, .{ .jsonrpc = "2.0", .id = id, .result = result });
    }

    fn replyError(s: *Server, a: std.mem.Allocator, id: json.Value, code: i32, message: []const u8) !void {
        try s.send(a, .{ .jsonrpc = "2.0", .id = id, .@"error" = .{ .code = code, .message = message } });
    }

    fn notify(s: *Server, a: std.mem.Allocator, method: []const u8, params: anytype) DispatchError!void {
        try s.send(a, .{ .jsonrpc = "2.0", .method = method, .params = params });
    }

    fn send(s: *Server, a: std.mem.Allocator, msg: anytype) DispatchError!void {
        const body = try json.Stringify.valueAlloc(a, msg, .{ .emit_null_optional_fields = false });
        const header = try std.fmt.allocPrint(a, "Content-Length: {d}\r\n\r\n", .{body.len});
        try s.out.appendSlice(s.gpa, header);
        try s.out.appendSlice(s.gpa, body);
    }
};

// ------------------------------------------------------- JSON accessors

fn field(v: json.Value, name: []const u8) error{BadParams}!json.Value {
    if (v != .object) return error.BadParams;
    return v.object.get(name) orelse error.BadParams;
}

fn str(v: json.Value, name: []const u8) error{BadParams}![]const u8 {
    return switch (try field(v, name)) {
        .string => |x| x,
        else => error.BadParams,
    };
}

fn int(v: json.Value, name: []const u8) error{BadParams}!u32 {
    return switch (try field(v, name)) {
        .integer => |x| if (x < 0) error.BadParams else @intCast(x),
        else => error.BadParams,
    };
}

// ------------------------------------------------------------ transport

pub fn main(init: std.process.Init) !u8 {
    const io = init.io;
    const gpa = std.heap.c_allocator;
    var s = Server{ .gpa = gpa };
    defer s.deinit();
    var rbuf: [1 << 16]u8 = undefined;
    var reader = std.Io.File.stdin().reader(io, &rbuf);
    var wbuf: [1 << 16]u8 = undefined;
    var writer = std.Io.File.stdout().writer(io, &wbuf);
    while (!s.exit) {
        // Headers, then a body of Content-Length bytes.
        var len: ?usize = null;
        while (true) {
            const line = reader.interface.takeDelimiterInclusive('\n') catch |e| switch (e) {
                error.EndOfStream => return if (s.shutdown) 0 else 1,
                else => return e,
            };
            const trimmed = std.mem.trimEnd(u8, line, "\r\n");
            if (trimmed.len == 0) break;
            if (std.ascii.startsWithIgnoreCase(trimmed, "content-length:")) {
                len = std.fmt.parseInt(usize, std.mem.trim(u8, trimmed["content-length:".len..], " "), 10) catch return 1;
            }
        }
        const n = len orelse continue;
        const body = try gpa.alloc(u8, n);
        defer gpa.free(body);
        reader.interface.readSliceAll(body) catch |e| switch (e) {
            error.EndOfStream => return 1,
            else => return e,
        };
        try s.handle(body);
        try writer.interface.writeAll(s.out.items);
        try writer.interface.flush();
        s.out.clearRetainingCapacity();
    }
    return 0;
}

// ------------------------------------------------------------------ tests

const testing = std.testing;

/// Drive the server with a message; the replies parsed back, framing
/// checked, in order.
const Harness = struct {
    s: Server,
    arena: std.heap.ArenaAllocator,

    fn init() Harness {
        return .{ .s = .{ .gpa = testing.allocator }, .arena = std.heap.ArenaAllocator.init(testing.allocator) };
    }

    fn deinit(h: *Harness) void {
        h.s.deinit();
        h.arena.deinit();
    }

    fn send(h: *Harness, msg: []const u8) ![]json.Value {
        h.s.out.clearRetainingCapacity();
        try h.s.handle(msg);
        var replies: std.ArrayList(json.Value) = .empty;
        var rest: []const u8 = h.s.out.items;
        while (rest.len > 0) {
            const hdr = "Content-Length: ";
            try testing.expect(std.mem.startsWith(u8, rest, hdr));
            const nl = std.mem.indexOf(u8, rest, "\r\n\r\n").?;
            const n = try std.fmt.parseInt(usize, rest[hdr.len..nl], 10);
            const body = rest[nl + 4 .. nl + 4 + n];
            try replies.append(h.arena.allocator(), try json.parseFromSliceLeaky(json.Value, h.arena.allocator(), body, .{}));
            rest = rest[nl + 4 + n ..];
        }
        return replies.items;
    }

    fn open(h: *Harness, uri: []const u8, text: []const u8) ![]json.Value {
        const msg = try json.Stringify.valueAlloc(h.arena.allocator(), .{
            .jsonrpc = "2.0",
            .method = "textDocument/didOpen",
            .params = .{ .textDocument = .{ .uri = uri, .languageId = "msh", .version = 1, .text = text } },
        }, .{});
        return h.send(msg);
    }

    fn at(h: *Harness, id: u32, method: []const u8, uri: []const u8, line: u32, character: u32) !json.Value {
        const msg = try json.Stringify.valueAlloc(h.arena.allocator(), .{
            .jsonrpc = "2.0",
            .id = id,
            .method = method,
            .params = .{ .textDocument = .{ .uri = uri }, .position = .{ .line = line, .character = character } },
        }, .{});
        const r = try h.send(msg);
        try testing.expectEqual(@as(usize, 1), r.len);
        return r[0].object.get("result").?;
    }
};

test "positions: lines and UTF-16 columns both ways" {
    const src = "ab\ncd é🙂x\n";
    try testing.expectEqual(Position{ .line = 1, .character = 0 }, byteToPos(src, 3));
    const x = std.mem.indexOfScalar(u8, src, 'x').?;
    try testing.expectEqual(Position{ .line = 1, .character = 6 }, byteToPos(src, x)); // é is 1 unit, 🙂 is 2
    try testing.expectEqual(x, posToByte(src, .{ .line = 1, .character = 6 }));
    try testing.expectEqual(@as(usize, 3), posToByte(src, .{ .line = 1, .character = 0 }));
    try testing.expectEqual(src.len, posToByte(src, .{ .line = 9, .character = 9 }));
}

test "initialize, then diagnostics on open and change" {
    var h = Harness.init();
    defer h.deinit();
    const r = try h.send(
        \\{"jsonrpc":"2.0","id":1,"method":"initialize","params":{"capabilities":{}}}
    );
    try testing.expectEqual(@as(usize, 1), r.len);
    const caps = r[0].object.get("result").?.object.get("capabilities").?;
    try testing.expectEqual(@as(i64, 1), caps.object.get("textDocumentSync").?.integer);
    try testing.expect(caps.object.get("hoverProvider").?.bool);

    const d = try h.open("file:///t.msh", "let x = 1\necho $y\n");
    try testing.expectEqual(@as(usize, 1), d.len);
    try testing.expectEqualStrings("textDocument/publishDiagnostics", d[0].object.get("method").?.string);
    const diags = d[0].object.get("params").?.object.get("diagnostics").?.array.items;
    try testing.expectEqual(@as(usize, 1), diags.len);
    try testing.expectEqualStrings("$y is not bound anywhere in scope", diags[0].object.get("message").?.string);
    const start = diags[0].object.get("range").?.object.get("start").?;
    try testing.expectEqual(@as(i64, 1), start.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 5), start.object.get("character").?.integer);
    try testing.expectEqual(@as(i64, 1), diags[0].object.get("severity").?.integer);

    const c = try h.send(
        \\{"jsonrpc":"2.0","method":"textDocument/didChange","params":{"textDocument":{"uri":"file:///t.msh","version":2},"contentChanges":[{"text":"let x = 1\necho $x\n"}]}}
    );
    try testing.expectEqual(@as(usize, 0), c[0].object.get("params").?.object.get("diagnostics").?.array.items.len);
}

test "hover, definition, symbols and completion from the scopes" {
    var h = Harness.init();
    defer h.deinit();
    const uri = "file:///s.msh";
    _ = try h.open(uri,
        \\let greeting = "hi"
        \\def shout [what] { echo "$what!" }
        \\shout $greeting
        \\ls | map { $it.name }
        \\
    );
    // hover on `$greeting` in line 2
    const hv = try h.at(1, "textDocument/hover", uri, 2, 8);
    try testing.expectEqualStrings("```msh\nlet greeting = \"hi\"\n```", hv.object.get("contents").?.object.get("value").?.string);
    // hover on the command `shout`: the def's header
    const hd = try h.at(2, "textDocument/hover", uri, 2, 1);
    try testing.expectEqualStrings("```msh\ndef shout [what]\n```", hd.object.get("contents").?.object.get("value").?.string);
    // hover on `$it`: the implicit name; on `map`: a builtin
    const hi = try h.at(3, "textDocument/hover", uri, 3, 13);
    try testing.expect(std.mem.indexOf(u8, hi.object.get("contents").?.object.get("value").?.string, "block argument") != null);
    const hm = try h.at(4, "textDocument/hover", uri, 3, 6);
    try testing.expect(std.mem.endsWith(u8, hm.object.get("contents").?.object.get("value").?.string, "builtin"));
    // definition of `$what` inside shout: its parameter
    const def = try h.at(5, "textDocument/definition", uri, 1, 27);
    const sel = def.object.get("range").?.object.get("start").?;
    try testing.expectEqual(@as(i64, 1), sel.object.get("line").?.integer);
    try testing.expectEqual(@as(i64, 11), sel.object.get("character").?.integer);
    // nothing under the cursor
    const none = try h.at(6, "textDocument/hover", uri, 0, 16);
    try testing.expect(none == .null);
    // symbols: the file's let and def
    const syms = (try h.send(
        \\{"jsonrpc":"2.0","id":7,"method":"textDocument/documentSymbol","params":{"textDocument":{"uri":"file:///s.msh"}}}
    ))[0].object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 2), syms.len);
    try testing.expectEqualStrings("greeting", syms[0].object.get("name").?.string);
    try testing.expectEqualStrings("shout", syms[1].object.get("name").?.string);
    // completion inside shout: `what` is visible, `greeting` too, and the builtins
    const items = (try h.at(8, "textDocument/completion", uri, 1, 20)).array.items;
    var seen_what = false;
    var seen_map = false;
    for (items) |it| {
        const l = it.object.get("label").?.string;
        seen_what = seen_what or std.mem.eql(u8, l, "what");
        seen_map = seen_map or std.mem.eql(u8, l, "map");
    }
    try testing.expect(seen_what and seen_map);
}

test "formatting: one edit, or none when the text is already formatted" {
    var h = Harness.init();
    defer h.deinit();
    const uri = "file:///f.msh";
    _ = try h.open(uri, "ls   |   get name\n");
    const r = (try h.send(
        \\{"jsonrpc":"2.0","id":1,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///f.msh"},"options":{"tabSize":2,"insertSpaces":true}}}
    ))[0].object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 1), r.len);
    try testing.expectEqualStrings("ls | get name\n", r[0].object.get("newText").?.string);
    try testing.expectEqual(@as(i64, 1), r[0].object.get("range").?.object.get("end").?.object.get("line").?.integer);
    _ = try h.open(uri, "ls | get name\n");
    const r2 = (try h.send(
        \\{"jsonrpc":"2.0","id":2,"method":"textDocument/formatting","params":{"textDocument":{"uri":"file:///f.msh"}}}
    ))[0].object.get("result").?.array.items;
    try testing.expectEqual(@as(usize, 0), r2.len);
}

test "errors: unknown method, bad params, shutdown and exit" {
    var h = Harness.init();
    defer h.deinit();
    const r = try h.send(
        \\{"jsonrpc":"2.0","id":9,"method":"textDocument/rename","params":{}}
    );
    try testing.expectEqual(@as(i64, -32601), r[0].object.get("error").?.object.get("code").?.integer);
    const bad = try h.send(
        \\{"jsonrpc":"2.0","id":10,"method":"textDocument/hover","params":{"textDocument":{"uri":"file:///nope.msh"},"position":{"line":0,"character":0}}}
    );
    try testing.expectEqual(@as(i64, -32602), bad[0].object.get("error").?.object.get("code").?.integer);
    const sd = try h.send(
        \\{"jsonrpc":"2.0","id":11,"method":"shutdown"}
    );
    try testing.expect(sd[0].object.get("result").? == .null);
    try testing.expect(h.s.shutdown);
    _ = try h.send(
        \\{"jsonrpc":"2.0","method":"exit"}
    );
    try testing.expect(h.s.exit);
}
