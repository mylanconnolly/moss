//! The web engine's face in the shell: `html-parse` (a page's markup as
//! a tree of records — `{ tag, attrs, children }`, `{ text }`,
//! `{ comment }`, `{ doctype }` — the DOM as data, acyclic, so it is a
//! value like any other), `html-select SELECTOR` (the elements a CSS
//! selector matches, as such records), and `html-text` (what a page
//! says, without its markup). Each takes markup as a string, or the
//! tree `html-parse` made, from an argument or the pipeline. Parsing runs
//! here in the caller's process — a parser over untrusted bytes, bounded
//! by the interpreter's arena and the domain's budget, and host-tested
//! against the html5lib corpora; nothing here executes a page.
const std = @import("std");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const web = mosslib.web;
const Value = mshl.Value;
const Shape = mshl.Shape;
const dom = web.dom;

pub const command_names = [_][]const u8{ "html-parse", "html-select", "html-text" };

const string_or_tree = blk: {
    const alts = [_]Shape{ .string, .record, .list };
    break :blk Shape{ .one_of = &alts };
};
const select_result = mshl.resultShape(.list, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    const is = std.mem.eql;
    if (is(u8, name, "html-parse")) return .{ .params = &.{.{ .name = "html", .shape = .string, .optional = true }}, .input = .{ .optional = .string }, .ret = .record };
    if (is(u8, name, "html-select")) return .{ .params = &.{ .{ .name = "selector", .shape = .string }, .{ .name = "html", .shape = string_or_tree, .optional = true } }, .input = .{ .optional = string_or_tree }, .ret = select_result };
    if (is(u8, name, "html-text")) return .{ .params = &.{.{ .name = "html", .shape = string_or_tree, .optional = true }}, .input = .{ .optional = string_or_tree }, .ret = .string };
    return null;
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "html-parse")) {
        const src = try source(it, "html-parse", args, 0, input);
        const doc = try documentOf(it, src);
        return try toData(it, doc, dom.document_id);
    }
    if (is(u8, name, "html-select")) {
        const src = try source(it, "html-select", args, 1, input);
        const doc = try documentOf(it, src);
        const sel = web.selectors.Selector.parse(it.arena, args[0].str) catch |e| switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Invalid => return try it.mkResult(false, .{ .str = try std.fmt.allocPrint(it.arena, "not a selector: {s}", .{args[0].str}) }),
        };
        var ids: std.ArrayList(dom.NodeId) = .empty;
        sel.queryAll(doc, dom.document_id, it.arena, &ids) catch return mshl.Error.OutOfMemory;
        const out = try it.arena.alloc(Value, ids.items.len);
        for (ids.items, 0..) |id, i| out[i] = try toData(it, doc, id);
        return try it.mkResult(true, .{ .list = out });
    }
    if (is(u8, name, "html-text")) {
        const src = try source(it, "html-text", args, 0, input);
        const doc = try documentOf(it, src);
        return .{ .str = try web.text.extract(it.arena, doc, dom.document_id) };
    }
    return null;
}

/// The markup or tree a command works on: the argument at `index` if
/// given, else the pipeline's input.
fn source(it: *mshl.Interp, cmd: []const u8, args: []const Value, index: usize, input: ?Value) mshl.Error!Value {
    if (args.len > index) return args[index];
    return input orelse it.fail("{s}: give it markup or a parsed tree, as an argument or through the pipe", .{cmd});
}

/// A document from markup (parsed) or from a tree `html-parse` made
/// (rebuilt; a list of such trees becomes siblings under the document).
fn documentOf(it: *mshl.Interp, v: Value) mshl.Error!*dom.Document {
    switch (v) {
        .str => |s| return web.html.parse(it.arena, s, .{}) catch return mshl.Error.OutOfMemory,
        .record, .list => {
            const doc = try it.arena.create(dom.Document);
            doc.* = dom.Document.init(it.arena) catch return mshl.Error.OutOfMemory;
            try fromData(it, doc, dom.document_id, v);
            return doc;
        },
        else => return it.fail("html: markup must be a string or a parsed tree", .{}),
    }
}

// ---------------------------------------------------------- tree <-> data

fn toData(it: *mshl.Interp, doc: *const dom.Document, id: dom.NodeId) mshl.Error!Value {
    const n = doc.get(id);
    switch (n.kind) {
        .text => return record(it, &.{"text"}, &.{.{ .str = n.text.items }}),
        .comment => return record(it, &.{"comment"}, &.{.{ .str = n.text.items }}),
        .doctype => return record(it, &.{"doctype"}, &.{.{ .str = n.name }}),
        .document, .fragment, .element => {
            const tag: []const u8 = switch (n.kind) {
                .document => "#document",
                .fragment => "#fragment",
                else => n.name,
            };
            const akeys = try it.arena.alloc([]const u8, n.attrs.items.len);
            const avals = try it.arena.alloc(Value, n.attrs.items.len);
            for (n.attrs.items, 0..) |at, i| {
                akeys[i] = if (at.prefix) |pre| try std.mem.concat(it.arena, u8, &.{ pre, ":", at.name }) else at.name;
                avals[i] = .{ .str = at.value };
            }
            var children: std.ArrayList(Value) = .empty;
            // A template's contents stand in for its (always empty) children.
            const from: dom.NodeId = if (n.template_contents) |tc| tc else id;
            var c = doc.get(from).first_child;
            while (c) |cid| : (c = doc.get(cid).next) try children.append(it.arena, try toData(it, doc, cid));
            return record(it, &.{ "tag", "attrs", "children" }, &.{
                .{ .str = tag },
                .{ .record = .{ .keys = akeys, .vals = avals } },
                .{ .list = children.items },
            });
        },
    }
}

fn fromData(it: *mshl.Interp, doc: *dom.Document, parent: dom.NodeId, v: Value) mshl.Error!void {
    switch (v) {
        .list => |items| for (items) |item| try fromData(it, doc, parent, item),
        .record => |r| {
            if (r.get("text")) |t| {
                if (t != .str) return it.fail("html: a text node's text must be a string", .{});
                const id = doc.createText(t.str) catch return mshl.Error.OutOfMemory;
                doc.appendChild(parent, id);
                return;
            }
            if (r.get("comment")) |t| {
                if (t != .str) return it.fail("html: a comment's text must be a string", .{});
                const id = doc.createComment(t.str) catch return mshl.Error.OutOfMemory;
                doc.appendChild(parent, id);
                return;
            }
            if (r.get("doctype")) |t| {
                if (t != .str) return it.fail("html: a doctype's name must be a string", .{});
                const id = doc.createDoctype(t.str, null, null) catch return mshl.Error.OutOfMemory;
                doc.appendChild(parent, id);
                return;
            }
            const tag = r.get("tag") orelse return it.fail("html: a node needs a tag, text, comment or doctype", .{});
            if (tag != .str) return it.fail("html: a tag must be a string", .{});
            var target = parent;
            if (!std.mem.eql(u8, tag.str, "#document") and !std.mem.eql(u8, tag.str, "#fragment")) {
                const id = doc.createElement(.html, tag.str) catch return mshl.Error.OutOfMemory;
                if (r.get("attrs")) |at| {
                    if (at != .record) return it.fail("html: attrs must be a record", .{});
                    for (at.record.keys, at.record.vals) |k, av| {
                        if (av != .str) return it.fail("html: attribute {s} must be a string", .{k});
                        doc.setAttr(id, k, av.str) catch return mshl.Error.OutOfMemory;
                    }
                }
                doc.appendChild(parent, id);
                target = id;
            }
            if (r.get("children")) |ch| {
                if (ch != .list) return it.fail("html: children must be a list", .{});
                for (ch.list) |child| try fromData(it, doc, target, child);
            }
        },
        else => return it.fail("html: a tree is records and lists", .{}),
    }
}

fn record(it: *mshl.Interp, keys: []const []const u8, vals: []const Value) mshl.Error!Value {
    return .{ .record = .{ .keys = try it.arena.dupe([]const u8, keys), .vals = try it.arena.dupe(Value, vals) } };
}
