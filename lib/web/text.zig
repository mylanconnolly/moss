//! The readable text of a document: what a page says, without its
//! markup. Text nodes are walked in order; `script`, `style`, `template`,
//! `noscript` and `head` say nothing; block-level elements start and end
//! lines, `br` breaks one, `li` is marked, table cells are separated by
//! a tab; runs of whitespace collapse to one space as on screen, except
//! inside `pre`, `textarea` and `listing`, whose text is kept as written.
//! This is `html-text` in the shell and a reader's view of a page — not
//! layout, which comes with the box tree and its own whitespace rules.
const std = @import("std");
const dom = @import("dom.zig");

pub const Error = error{OutOfMemory};

const block_names = [_][]const u8{ "address", "article", "aside", "blockquote", "body", "caption", "center", "dd", "details", "dialog", "dir", "div", "dl", "dt", "fieldset", "figcaption", "figure", "footer", "form", "h1", "h2", "h3", "h4", "h5", "h6", "header", "hgroup", "hr", "html", "legend", "li", "main", "menu", "nav", "ol", "option", "p", "section", "summary", "table", "tbody", "tfoot", "thead", "title", "tr", "ul" };
const silent_names = [_][]const u8{ "script", "style", "template", "noscript", "head", "iframe", "object", "svg", "math" };
const pre_names = [_][]const u8{ "pre", "textarea", "listing", "plaintext", "xmp" };

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, name, l)) return true;
    return false;
}

const Writer = struct {
    a: std.mem.Allocator,
    out: std.ArrayList(u8) = .empty,
    /// A space is owed before the next non-space character.
    pending_space: bool = false,
    /// A line break is owed (at most one blank line between blocks).
    pending_breaks: u8 = 0,
    at_line_start: bool = true,

    fn breakLine(w: *Writer, n: u8) void {
        w.pending_breaks = @max(w.pending_breaks, n);
        w.pending_space = false;
    }

    fn flushBreaks(w: *Writer) Error!void {
        if (w.pending_breaks == 0) return;
        if (w.out.items.len > 0) {
            var k: u8 = 0;
            while (k < w.pending_breaks) : (k += 1) try w.out.append(w.a, '\n');
        }
        w.pending_breaks = 0;
        w.at_line_start = true;
        w.pending_space = false;
    }

    fn collapsed(w: *Writer, s: []const u8) Error!void {
        for (s) |c| {
            if (c == ' ' or c == '\t' or c == '\n' or c == '\r' or c == 0x0c) {
                w.pending_space = true;
                continue;
            }
            try w.flushBreaks();
            if (w.pending_space and !w.at_line_start) try w.out.append(w.a, ' ');
            w.pending_space = false;
            w.at_line_start = false;
            try w.out.append(w.a, c);
        }
    }

    fn verbatim(w: *Writer, s: []const u8) Error!void {
        if (s.len == 0) return;
        try w.flushBreaks();
        try w.out.appendSlice(w.a, s);
        w.at_line_start = s[s.len - 1] == '\n';
        w.pending_space = false;
    }
};

/// The readable text under `root`, trimmed.
pub fn extract(a: std.mem.Allocator, doc: *const dom.Document, root: dom.NodeId) Error![]const u8 {
    var w: Writer = .{ .a = a };
    try walk(&w, doc, root, false);
    return std.mem.trim(u8, w.out.items, " \n\t");
}

fn walk(w: *Writer, doc: *const dom.Document, id: dom.NodeId, pre: bool) Error!void {
    const n = doc.get(id);
    switch (n.kind) {
        .text => return if (pre) w.verbatim(n.text.items) else w.collapsed(n.text.items),
        .element => {},
        .document, .fragment => {
            var c = n.first_child;
            while (c) |cid| : (c = doc.get(cid).next) try walk(w, doc, cid, pre);
            return;
        },
        else => return,
    }
    const name = n.name;
    if (n.namespace == .html and inList(name, &silent_names)) return;
    if (n.namespace == .html and std.mem.eql(u8, name, "br")) {
        try w.flushBreaks();
        try w.out.append(w.a, '\n');
        w.at_line_start = true;
        w.pending_space = false;
        return;
    }
    const is_block = n.namespace == .html and inList(name, &block_names);
    const is_pre = n.namespace == .html and inList(name, &pre_names);
    const is_cell = n.namespace == .html and (std.mem.eql(u8, name, "td") or std.mem.eql(u8, name, "th"));
    if (is_block or is_pre) w.breakLine(if (std.mem.eql(u8, name, "p") or (name.len == 2 and name[0] == 'h' and std.ascii.isDigit(name[1]))) 2 else 1);
    if (n.namespace == .html and std.mem.eql(u8, name, "li")) try w.collapsed("\u{2022} ");
    if (is_cell and !w.at_line_start and w.pending_breaks == 0) {
        try w.out.append(w.a, '\t');
        w.pending_space = false;
    }
    var c = n.first_child;
    while (c) |cid| : (c = doc.get(cid).next) try walk(w, doc, cid, pre or is_pre);
    if (is_block or is_pre) w.breakLine(if (std.mem.eql(u8, name, "p") or (name.len == 2 and name[0] == 'h' and std.ascii.isDigit(name[1]))) 2 else 1);
}

const html = @import("html.zig");

test "text: blocks, inline, pre, silence" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try html.parse(a, "<title>T</title><style>p{}</style><h1>Hi   there</h1><p>one <b>two</b>\n three<br>four</p><ul><li>a<li>b</ul><pre>  x\n y</pre><script>1</script><table><tr><td>1<td>2</table>", .{});
    const t = try extract(a, doc, dom.document_id);
    try std.testing.expectEqualStrings("Hi there\n\none two three\nfour\n\n\u{2022} a\n\u{2022} b\n  x\n y\n1\t2", t);
}
