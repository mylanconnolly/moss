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

pub const command_names = [_][]const u8{ "html-parse", "html-select", "html-text", "html-style", "css-parse" };

const string_or_tree = blk: {
    const alts = [_]Shape{ .string, .record, .list };
    break :blk Shape{ .one_of = &alts };
};
const select_result = mshl.resultShape(.list, .string);
const style_result = mshl.resultShape(.list, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    const is = std.mem.eql;
    if (is(u8, name, "html-parse")) return .{ .params = &.{.{ .name = "html", .shape = .string, .optional = true }}, .input = .{ .optional = .string }, .ret = .record };
    if (is(u8, name, "html-select")) return .{ .params = &.{ .{ .name = "selector", .shape = .string }, .{ .name = "html", .shape = string_or_tree, .optional = true } }, .input = .{ .optional = string_or_tree }, .ret = select_result };
    if (is(u8, name, "html-text")) return .{ .params = &.{.{ .name = "html", .shape = string_or_tree, .optional = true }}, .input = .{ .optional = string_or_tree }, .ret = .string };
    if (is(u8, name, "html-style")) return .{ .params = &.{ .{ .name = "selector", .shape = .string }, .{ .name = "html", .shape = string_or_tree, .optional = true } }, .input = .{ .optional = string_or_tree }, .ret = style_result };
    if (is(u8, name, "css-parse")) return .{ .params = &.{.{ .name = "css", .shape = string_or_tree, .optional = true }}, .input = .{ .optional = string_or_tree }, .ret = .list };
    return null;
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    const is = std.mem.eql;
    if (is(u8, name, "html-parse")) {
        const src = try source(it, "html-parse", args, 0, input);
        const doc = try documentOf(it, it.arena, src);
        return try toData(it, doc, dom.document_id);
    }
    if (is(u8, name, "html-select")) {
        const src = try source(it, "html-select", args, 1, input);
        // The document is rebuilt in scratch that goes when the call
        // does; only the matches, copied, stay in the line heap (a
        // script's whole run shares it, and a drill that selected eight
        // times from a rendered page filled it).
        var scratch = std.heap.ArenaAllocator.init(it.heap);
        defer scratch.deinit();
        const sa = scratch.allocator();
        const doc = try documentOf(it, sa, src);
        const sel = web.selectors.Selector.parse(sa, args[0].str) catch |e| switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Invalid => return try it.mkResult(false, .{ .str = try std.fmt.allocPrint(it.arena, "not a selector: {s}", .{args[0].str}) }),
        };
        var ids: std.ArrayList(dom.NodeId) = .empty;
        sel.queryAll(doc, dom.document_id, sa, &ids) catch return mshl.Error.OutOfMemory;
        const out = try it.arena.alloc(Value, ids.items.len);
        for (ids.items, 0..) |id, i| out[i] = try toDataFrom(it, doc, id, true);
        return try it.mkResult(true, .{ .list = out });
    }
    if (is(u8, name, "html-text")) {
        const src = try source(it, "html-text", args, 0, input);
        var scratch = std.heap.ArenaAllocator.init(it.heap);
        defer scratch.deinit();
        const doc = try documentOf(it, scratch.allocator(), src);
        return .{ .str = try it.arena.dupe(u8, try web.text.extract(scratch.allocator(), doc, dom.document_id)) };
    }
    if (is(u8, name, "html-style")) {
        const src = try source(it, "html-style", args, 1, input);
        const doc = try documentOf(it, it.arena, src);
        const sel = web.selectors.Selector.parse(it.arena, args[0].str) catch |e| switch (e) {
            error.OutOfMemory => return mshl.Error.OutOfMemory,
            error.Invalid => return try it.mkResult(false, .{ .str = try std.fmt.allocPrint(it.arena, "not a selector: {s}", .{args[0].str}) }),
        };
        // The cascade for a desktop-sized page in the light theme: what
        // a script asks is "what would this element be", not the session's
        // window — that comes with the page domain.
        const env: web.style.Env = .{ .width = 1280, .height = 1024 };
        const ua = uaSheet(env) orelse return it.fail("html-style: the user-agent stylesheet did not fit its heap", .{});
        const sheets = try web.style.collectDocumentSheetsWith(it.arena, doc, env, ua);
        const styles = try web.style.compute(it.arena, doc, sheets, env);
        var ids: std.ArrayList(dom.NodeId) = .empty;
        sel.queryAll(doc, dom.document_id, it.arena, &ids) catch return mshl.Error.OutOfMemory;
        const out = try it.arena.alloc(Value, ids.items.len);
        for (ids.items, 0..) |id, i| out[i] = try styleRecord(it, styles.get(id));
        return try it.mkResult(true, .{ .list = out });
    }
    if (is(u8, name, "css-parse")) {
        const src = try source(it, "css-parse", args, 0, input);
        // A stylesheet's text, or a page: every `<style>` in it, in order.
        const text: []const u8 = if (src == .str) src.str else blk: {
            const doc = try documentOf(it, it.arena, src);
            var out: std.ArrayList(u8) = .empty;
            var w = doc.walk(dom.document_id);
            while (w.next()) |id| if (doc.isHtml(id, "style")) {
                try out.appendSlice(it.arena, doc.textContent(id, it.arena) catch return mshl.Error.OutOfMemory);
                try out.append(it.arena, '\n');
            };
            break :blk out.items;
        };
        var p = web.css.Parser.init(it.arena, text, false) catch return mshl.Error.OutOfMemory;
        const rules = p.parseStylesheet() catch return mshl.Error.OutOfMemory;
        return .{ .list = try rulesData(it, rules) };
    }
    return null;
}

// The user-agent sheet, parsed once on first use into a heap of its
// own: its forty-odd rules cost a third of the line heap to parse, and
// they never change. Media queries in it are evaluated for a desktop
// viewport; it has none today.
var ua_heap: [512 << 10]u8 = undefined;
var ua_cache: ?web.style.Sheet = null;

fn uaSheet(env: web.style.Env) ?web.style.Sheet {
    if (ua_cache) |c| return c;
    var fba = std.heap.FixedBufferAllocator.init(&ua_heap);
    ua_cache = web.style.parseSheet(fba.allocator(), web.style.ua_sheet, .user_agent, env) catch return null;
    return ua_cache;
}

/// A stylesheet's rules as data: `{ selector, declarations: { name:
/// "value" } }` for a style rule, `{ at, prelude, rules | block }` for
/// an at-rule (a `@media` block's rules nested as data too).
fn rulesData(it: *mshl.Interp, rules: []const web.css.Rule) mshl.Error![]Value {
    var out: std.ArrayList(Value) = .empty;
    for (rules) |r| switch (r) {
        .err => {},
        .qualified => |q| {
            const sel = web.css.valuesText(it.arena, q.prelude) catch return mshl.Error.OutOfMemory;
            const block = web.css.valuesText(it.arena, q.block) catch return mshl.Error.OutOfMemory;
            var bp = web.css.Parser.init(it.arena, block, false) catch return mshl.Error.OutOfMemory;
            const items = bp.parseBlockContents() catch return mshl.Error.OutOfMemory;
            var keys: std.ArrayList([]const u8) = .empty;
            var vals: std.ArrayList(Value) = .empty;
            for (items) |item| if (item == .declaration) {
                var text = web.css.valuesText(it.arena, item.declaration.value) catch return mshl.Error.OutOfMemory;
                if (item.declaration.important) text = try std.mem.concat(it.arena, u8, &.{ text, " !important" });
                try keys.append(it.arena, item.declaration.name);
                try vals.append(it.arena, .{ .str = text });
            };
            try out.append(it.arena, try record(it, &.{ "selector", "declarations" }, &.{ .{ .str = sel }, .{ .record = .{ .keys = keys.items, .vals = vals.items } } }));
        },
        .at => |at| {
            const prelude = web.css.valuesText(it.arena, at.prelude) catch return mshl.Error.OutOfMemory;
            if (at.block) |b| {
                const block = web.css.valuesText(it.arena, b) catch return mshl.Error.OutOfMemory;
                if (std.ascii.eqlIgnoreCase(at.name, "media") or std.ascii.eqlIgnoreCase(at.name, "supports")) {
                    var bp = web.css.Parser.init(it.arena, block, false) catch return mshl.Error.OutOfMemory;
                    const inner = bp.parseListOfRules() catch return mshl.Error.OutOfMemory;
                    try out.append(it.arena, try record(it, &.{ "at", "prelude", "rules" }, &.{ .{ .str = at.name }, .{ .str = prelude }, .{ .list = try rulesData(it, inner) } }));
                } else {
                    try out.append(it.arena, try record(it, &.{ "at", "prelude", "block" }, &.{ .{ .str = at.name }, .{ .str = prelude }, .{ .str = block } }));
                }
            } else try out.append(it.arena, try record(it, &.{ "at", "prelude" }, &.{ .{ .str = at.name }, .{ .str = prelude } }));
        },
    };
    return out.items;
}

fn percentText(it: *mshl.Interp, x: f64) mshl.Error!Value {
    return .{ .str = try std.fmt.allocPrint(it.arena, "{d}%", .{x}) };
}

fn lengthAutoValue(it: *mshl.Interp, l: web.style.LengthAuto) mshl.Error!Value {
    return switch (l) {
        .px => |x| .{ .float = x },
        .percent => |x| try percentText(it, x),
        .calc => |m| .{ .str = try std.fmt.allocPrint(it.arena, "calc({d}% + {d}px)", .{ m.pct, m.px }) },
        .auto => .{ .str = "auto" },
    };
}

fn lengthPercentValue(it: *mshl.Interp, l: web.style.LengthPercent) mshl.Error!Value {
    return switch (l) {
        .px => |x| .{ .float = x },
        .percent => |x| try percentText(it, x),
        .calc => |m| .{ .str = try std.fmt.allocPrint(it.arena, "calc({d}% + {d}px)", .{ m.pct, m.px }) },
    };
}

fn sidesAuto(it: *mshl.Interp, arr: [4]web.style.LengthAuto) mshl.Error!Value {
    const out = try it.arena.alloc(Value, 4);
    for (arr, 0..) |l, i| out[i] = try lengthAutoValue(it, l);
    return .{ .list = out };
}

fn sidesPercent(it: *mshl.Interp, arr: [4]web.style.LengthPercent) mshl.Error!Value {
    const out = try it.arena.alloc(Value, 4);
    for (arr, 0..) |l, i| out[i] = try lengthPercentValue(it, l);
    return .{ .list = out };
}

/// The computed values a script can read, with CSS's spellings.
fn styleRecord(it: *mshl.Interp, c: *const web.style.Computed) mshl.Error!Value {
    const fams = try it.arena.alloc(Value, c.font_family.len);
    for (c.font_family, 0..) |f, i| fams[i] = .{ .str = f };
    const widths = try it.arena.alloc(Value, 4);
    for (0..4) |i| widths[i] = .{ .float = c.borderWidth(i) };
    const lh: Value = switch (c.line_height) {
        .normal => .{ .str = "normal" },
        .number => |n| .{ .float = n },
        .px => |x| .{ .float = x },
    };
    return record(it, &.{ "display", "position", "float", "color", "background-color", "font-size", "font-weight", "font-style", "font-family", "line-height", "text-align", "text-decoration", "white-space", "list-style-type", "width", "height", "margin", "padding", "border-width", "visibility", "opacity" }, &.{
        .{ .str = cssName(@tagName(c.display)) },
        .{ .str = @tagName(c.position) },
        .{ .str = @tagName(c.float) },
        .{ .str = c.color.serialize(it.arena) catch return mshl.Error.OutOfMemory },
        .{ .str = c.background_color.serialize(it.arena) catch return mshl.Error.OutOfMemory },
        .{ .float = c.font_size },
        .{ .int = c.font_weight },
        .{ .str = @tagName(c.font_style) },
        .{ .list = fams },
        lh,
        .{ .str = @tagName(c.text_align) },
        .{ .str = if (c.text_decoration.underline) "underline" else if (c.text_decoration.line_through) "line-through" else if (c.text_decoration.overline) "overline" else "none" },
        .{ .str = cssName(@tagName(c.white_space)) },
        .{ .str = cssName(@tagName(c.list_style_type)) },
        try lengthAutoValue(it, c.width),
        try lengthAutoValue(it, c.height),
        try sidesAuto(it, c.margin),
        try sidesPercent(it, c.padding),
        .{ .list = widths },
        .{ .str = @tagName(c.visibility) },
        .{ .float = c.opacity },
    });
}

/// An enum tag as CSS spells it (`inline_block` is `inline-block`).
fn cssName(tag: []const u8) []const u8 {
    for (tag) |c| if (c == '_') {
        // Map through a small static table of the names that have one.
        const known = [_][2][]const u8{ .{ "inline_block", "inline-block" }, .{ "list_item", "list-item" }, .{ "inline_flex", "inline-flex" }, .{ "inline_grid", "inline-grid" }, .{ "inline_table", "inline-table" }, .{ "table_row", "table-row" }, .{ "table_cell", "table-cell" }, .{ "table_row_group", "table-row-group" }, .{ "table_header_group", "table-header-group" }, .{ "table_footer_group", "table-footer-group" }, .{ "table_caption", "table-caption" }, .{ "table_column", "table-column" }, .{ "table_column_group", "table-column-group" }, .{ "flow_root", "flow-root" }, .{ "pre_wrap", "pre-wrap" }, .{ "pre_line", "pre-line" }, .{ "break_spaces", "break-spaces" }, .{ "lower_alpha", "lower-alpha" }, .{ "upper_alpha", "upper-alpha" }, .{ "lower_roman", "lower-roman" }, .{ "upper_roman", "upper-roman" } };
        for (known) |k| if (std.mem.eql(u8, k[0], tag)) return k[1];
        return tag;
    };
    return tag;
}

/// The markup or tree a command works on: the argument at `index` if
/// given, else the pipeline's input.
fn source(it: *mshl.Interp, cmd: []const u8, args: []const Value, index: usize, input: ?Value) mshl.Error!Value {
    if (args.len > index) return args[index];
    return input orelse it.fail("{s}: give it markup or a parsed tree, as an argument or through the pipe", .{cmd});
}

/// A document from markup (parsed) or from a tree `html-parse` made
/// (rebuilt; a list of such trees becomes siblings under the document).
fn documentOf(it: *mshl.Interp, a: std.mem.Allocator, v: Value) mshl.Error!*dom.Document {
    switch (v) {
        .str => |s| return web.html.parse(a, s, .{}) catch return mshl.Error.OutOfMemory,
        .record, .list => {
            const doc = try a.create(dom.Document);
            doc.* = dom.Document.init(a) catch return mshl.Error.OutOfMemory;
            try fromData(it, doc, dom.document_id, v);
            return doc;
        },
        else => return it.fail("html: markup must be a string or a parsed tree", .{}),
    }
}

// ---------------------------------------------------------- tree <-> data

pub fn toData(it: *mshl.Interp, doc: *const dom.Document, id: dom.NodeId) mshl.Error!Value {
    return toDataFrom(it, doc, id, false);
}

/// The tree as data; with `copy`, every string is copied into the line
/// heap (the document is in memory that will not outlive the call).
pub fn toDataFrom(it: *mshl.Interp, doc: *const dom.Document, id: dom.NodeId, copy: bool) mshl.Error!Value {
    const n = doc.get(id);
    const keep = struct {
        fn f(i: *mshl.Interp, c: bool, s: []const u8) mshl.Error![]const u8 {
            return if (c) try i.arena.dupe(u8, s) else s;
        }
    }.f;
    switch (n.kind) {
        .text => return record(it, &.{"text"}, &.{.{ .str = try keep(it, copy, n.text.items) }}),
        .comment => return record(it, &.{"comment"}, &.{.{ .str = try keep(it, copy, n.text.items) }}),
        .doctype => return record(it, &.{"doctype"}, &.{.{ .str = try keep(it, copy, n.name) }}),
        .document, .fragment, .element => {
            const tag: []const u8 = switch (n.kind) {
                .document => "#document",
                .fragment => "#fragment",
                else => try keep(it, copy, n.name),
            };
            const akeys = try it.arena.alloc([]const u8, n.attrs.items.len);
            const avals = try it.arena.alloc(Value, n.attrs.items.len);
            for (n.attrs.items, 0..) |at, i| {
                akeys[i] = if (at.prefix) |pre| try std.mem.concat(it.arena, u8, &.{ pre, ":", at.name }) else try keep(it, copy, at.name);
                avals[i] = .{ .str = try keep(it, copy, at.value) };
            }
            var children: std.ArrayList(Value) = .empty;
            // A template's contents stand in for its (always empty) children.
            const from: dom.NodeId = if (n.template_contents) |tc| tc else id;
            var c = doc.get(from).first_child;
            while (c) |cid| : (c = doc.get(cid).next) try children.append(it.arena, try toDataFrom(it, doc, cid, copy));
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
