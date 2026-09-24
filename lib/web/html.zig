//! The HTML Standard's tree construction (§13.2.6): the insertion modes,
//! the stack of open elements and the list of active formatting elements,
//! the adoption agency algorithm, foster parenting, templates, foreign
//! content (SVG and MathML with their case and attribute adjustments), and
//! the fragment case — over the tokenizer beside it, into the DOM beside
//! that. `parse` takes a whole document's text (already UTF-8) and gives
//! back a `dom.Document` whose every node lives in the caller's arena;
//! `parseFragment` is `innerHTML`'s parser. Scripting is a flag: with it
//! off (the default, and what a browser without a script engine is)
//! `noscript` content is parsed as markup, as the standard says.
//!
//! The host test runs the html5lib tree-construction corpus and prints
//! its count. Parse errors are not reported; the tree is the product.
const std = @import("std");
const dom = @import("dom.zig");
const tokenizer = @import("tokenizer.zig");

pub const Error = error{OutOfMemory};
const Document = dom.Document;
const NodeId = dom.NodeId;
const Tag = tokenizer.Tag;

const Mode = enum {
    initial,
    before_html,
    before_head,
    in_head,
    in_head_noscript,
    after_head,
    in_body,
    text,
    in_table,
    in_table_text,
    in_caption,
    in_column_group,
    in_table_body,
    in_row,
    in_cell,
    in_template,
    after_body,
    in_frameset,
    after_frameset,
    after_after_body,
    after_after_frameset,
};

/// The tokenizer's runs, cut where the modes care: whitespace, NUL, and
/// everything else.
const Tok = union(enum) {
    doctype: tokenizer.Doctype,
    start: Tag,
    end: Tag,
    comment: []const u8,
    ws: []const u8,
    text: []const u8,
    nul,
    eof,
};

/// An entry in the list of active formatting elements: the element and
/// the token it was made from (to remake it), or a marker.
const Formatting = struct {
    node: NodeId,
    name: []const u8,
    attrs: []const tokenizer.Attr,
    marker: bool = false,
};

const Place = struct { parent: NodeId, before: ?NodeId = null };

pub const Options = struct {
    scripting: bool = false,
};

pub const Parser = struct {
    a: std.mem.Allocator,
    doc: *Document,
    tok: tokenizer.Tokenizer,
    mode: Mode = .initial,
    original_mode: Mode = .initial,
    open: std.ArrayList(NodeId) = .empty,
    afe: std.ArrayList(Formatting) = .empty,
    template_modes: std.ArrayList(Mode) = .empty,
    head: ?NodeId = null,
    form: ?NodeId = null,
    scripting: bool,
    frameset_ok: bool = true,
    foster: bool = false,
    pending_table_text: std.ArrayList(u8) = .empty,
    pending_table_nonws: bool = false,
    context: ?NodeId = null,
    ignore_lf: bool = false,
    stopped: bool = false,

    // ------------------------------------------------------------ driving

    pub fn run(p: *Parser) Error!void {
        while (!p.stopped) {
            const t = try p.tok.next();
            try p.dispatchToken(t);
            if (t == .eof) break;
        }
    }

    fn dispatchToken(p: *Parser, t: tokenizer.Token) Error!void {
        // A newline right after <pre>, <listing> or <textarea> is not content.
        const ignore_lf = p.ignore_lf;
        p.ignore_lf = false;
        switch (t) {
            .doctype => |d| try p.dispatch(.{ .doctype = d }),
            .start_tag => |s| try p.dispatch(.{ .start = s }),
            .end_tag => |e| try p.dispatch(.{ .end = e }),
            .comment => |c| try p.dispatch(.{ .comment = c }),
            .eof => try p.dispatch(.eof),
            .chars => |run0| {
                const run_ = if (ignore_lf and run0.len > 0 and run0[0] == '\n') run0[1..] else run0;
                var i: usize = 0;
                while (i < run_.len) {
                    const c = run_[i];
                    if (c == 0) {
                        try p.dispatch(.nul);
                        i += 1;
                        continue;
                    }
                    const ws = isWs(c);
                    var j = i + 1;
                    while (j < run_.len and run_[j] != 0 and isWs(run_[j]) == ws) j += 1;
                    if (ws) try p.dispatch(.{ .ws = run_[i..j] }) else try p.dispatch(.{ .text = run_[i..j] });
                    i = j;
                }
            },
        }
        p.tok.allow_cdata = blk: {
            const n = p.adjustedCurrentNode() orelse break :blk false;
            break :blk p.doc.get(n).namespace != .html;
        };
    }

    fn isWs(c: u8) bool {
        return c == '\t' or c == '\n' or c == 0x0c or c == '\r' or c == ' ';
    }

    /// The tree construction dispatcher: the current mode, or the rules
    /// for foreign content.
    fn dispatch(p: *Parser, t: Tok) Error!void {
        const adj = p.adjustedCurrentNode();
        const use_html = blk: {
            const n = adj orelse break :blk true;
            const node = p.doc.get(n);
            if (node.namespace == .html) break :blk true;
            if (p.isMathmlTextIntegrationPoint(n)) {
                if (t == .start and !eq(t.start.name, "mglyph") and !eq(t.start.name, "malignmark")) break :blk true;
                if (t == .text or t == .ws or t == .nul) break :blk true;
            }
            if (node.namespace == .mathml and eq(node.name, "annotation-xml") and t == .start and eq(t.start.name, "svg")) break :blk true;
            if (p.isHtmlIntegrationPoint(n)) {
                if (t == .start or t == .text or t == .ws or t == .nul) break :blk true;
            }
            if (t == .eof) break :blk true;
            break :blk false;
        };
        if (use_html) try p.process(t, p.mode) else try p.foreign(t);
    }

    // ------------------------------------------------------- the stack

    fn current(p: *const Parser) ?NodeId {
        if (p.open.items.len == 0) return null;
        return p.open.items[p.open.items.len - 1];
    }

    fn adjustedCurrentNode(p: *const Parser) ?NodeId {
        if (p.context != null and p.open.items.len == 1) return p.context;
        return p.current();
    }

    fn contextIs(p: *const Parser, name: []const u8) bool {
        const c = p.context orelse return false;
        return p.doc.isHtml(c, name);
    }

    fn pop(p: *Parser) ?NodeId {
        if (p.open.items.len == 0) return null;
        return p.open.pop();
    }

    fn popUntilHtml(p: *Parser, name: []const u8) void {
        while (p.pop()) |n| if (p.doc.isHtml(n, name)) return;
    }

    fn popUntilOneOf(p: *Parser, names: []const []const u8) void {
        while (p.pop()) |n| {
            const nd = p.doc.get(n);
            if (nd.namespace == .html and inList(nd.name, names)) return;
        }
    }

    fn removeFromOpen(p: *Parser, id: NodeId) void {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            if (p.open.items[i] == id) {
                _ = p.open.orderedRemove(i);
                return;
            }
        }
    }

    fn indexInOpen(p: *const Parser, id: NodeId) ?usize {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            if (p.open.items[i] == id) return i;
        }
        return null;
    }

    fn inOpen(p: *const Parser, id: NodeId) bool {
        return p.indexInOpen(id) != null;
    }

    // --------------------------------------------------------- scopes

    const default_scope_html = [_][]const u8{ "applet", "caption", "html", "table", "td", "th", "marquee", "object", "select", "template" };
    const scope_mathml = [_][]const u8{ "mi", "mo", "mn", "ms", "mtext", "annotation-xml" };
    const scope_svg = [_][]const u8{ "foreignObject", "desc", "title" };

    const ScopeKind = enum { default, list_item, button, table };

    fn isScopeBoundary(p: *const Parser, id: NodeId, kind: ScopeKind) bool {
        const n = p.doc.get(id);
        switch (kind) {
            .table => return n.namespace == .html and inList(n.name, &.{ "html", "table", "template" }),
            else => {},
        }
        switch (n.namespace) {
            .html => {
                if (inList(n.name, &default_scope_html)) return true;
                if (kind == .list_item and (eq(n.name, "ol") or eq(n.name, "ul"))) return true;
                if (kind == .button and eq(n.name, "button")) return true;
                return false;
            },
            .mathml => return inList(n.name, &scope_mathml),
            .svg => return inList(n.name, &scope_svg),
        }
    }

    /// Whether an HTML element named `name` is in the given scope.
    fn inScope(p: *const Parser, name: []const u8, kind: ScopeKind) bool {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            const id = p.open.items[i];
            if (p.doc.isHtml(id, name)) return true;
            if (p.isScopeBoundary(id, kind)) return false;
        }
        return false;
    }

    fn inScopeAny(p: *const Parser, names: []const []const u8, kind: ScopeKind) bool {
        for (names) |n| if (p.inScope(n, kind)) return true;
        return false;
    }

    fn nodeInScope(p: *const Parser, id: NodeId, kind: ScopeKind) bool {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            const x = p.open.items[i];
            if (x == id) return true;
            if (p.isScopeBoundary(x, kind)) return false;
        }
        return false;
    }

    // ------------------------------------------------------- insertion

    fn lastInOpen(p: *const Parser, name: []const u8) ?struct { id: NodeId, index: usize } {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            if (p.doc.isHtml(p.open.items[i], name)) return .{ .id = p.open.items[i], .index = i };
        }
        return null;
    }

    /// The appropriate place for inserting a node.
    fn insertionPlace(p: *Parser, override: ?NodeId) Place {
        const target = override orelse p.current().?;
        var place: Place = .{ .parent = target };
        const tn = p.doc.get(target);
        if (p.foster and tn.namespace == .html and inList(tn.name, &.{ "table", "tbody", "tfoot", "thead", "tr" })) {
            const last_template = p.lastInOpen("template");
            const last_table = p.lastInOpen("table");
            if (last_template != null and (last_table == null or last_template.?.index > last_table.?.index)) {
                place = .{ .parent = p.doc.get(last_template.?.id).template_contents.? };
            } else if (last_table == null) {
                place = .{ .parent = p.open.items[0] };
            } else if (p.doc.get(last_table.?.id).parent) |tp| {
                place = .{ .parent = tp, .before = last_table.?.id };
            } else {
                place = .{ .parent = p.open.items[last_table.?.index - 1] };
            }
        }
        const pn = p.doc.get(place.parent);
        if (pn.kind == .element and pn.namespace == .html and eq(pn.name, "template")) {
            place = .{ .parent = pn.template_contents.? };
        }
        return place;
    }

    fn insertAt(p: *Parser, place: Place, id: NodeId) void {
        p.doc.insertBefore(place.parent, id, place.before);
    }

    fn createElementFor(p: *Parser, t: Tag, ns: dom.Namespace) Error!NodeId {
        const id = try p.doc.createElement(ns, t.name);
        const n = p.doc.node(id);
        // A fresh HTML element takes the token's attribute list as its
        // own (the tokenizer made an exact copy with no duplicates);
        // otherwise room for every attribute at once — a list that grows
        // by doubling in a bump arena leaves its old buffers behind.
        if (ns == .html and n.attrs.items.len == 0) {
            n.attrs = .fromOwnedSlice(@constCast(t.attrs));
        } else try n.attrs.ensureTotalCapacityPrecise(p.a, n.attrs.items.len + t.attrs.len);
        for (t.attrs) |at| {
            if (n.attrs.items.ptr == t.attrs.ptr) break; // adopted whole
            var dup = false;
            for (n.attrs.items) |have| if (eq(have.name, at.name) and have.prefix == null) {
                dup = true;
            };
            if (dup) continue;
            // Foreign attributes split into a prefix and a local name on a
            // foreign element (the "adjust foreign attributes" table).
            if (ns != .html) if (foreignAttrPrefix(at.name)) |cut| {
                try n.attrs.append(p.a, .{ .name = at.name[cut + 1 ..], .value = at.value, .prefix = at.name[0..cut] });
                continue;
            };
            try n.attrs.append(p.a, .{ .name = at.name, .value = at.value });
        }
        if (ns == .html and eq(t.name, "template")) {
            // Creating the fragment grows the node list: take the pointer again.
            const frag = try p.doc.createFragment();
            p.doc.node(id).template_contents = frag;
        }
        return id;
    }

    fn insertElement(p: *Parser, t: Tag, ns: dom.Namespace) Error!NodeId {
        const place = p.insertionPlace(null);
        const id = try p.createElementFor(t, ns);
        p.insertAt(place, id);
        try p.open.append(p.a, id);
        return id;
    }

    fn insertHtmlElement(p: *Parser, t: Tag) Error!NodeId {
        return p.insertElement(t, .html);
    }

    fn insertHtmlNamed(p: *Parser, name: []const u8) Error!NodeId {
        return p.insertElement(.{ .name = name }, .html);
    }

    fn insertComment(p: *Parser, data: []const u8, at: ?Place) Error!void {
        const place = at orelse p.insertionPlace(null);
        const id = try p.doc.createComment(data);
        p.insertAt(place, id);
    }

    fn insertText(p: *Parser, data: []const u8) Error!void {
        const place = p.insertionPlace(null);
        if (p.doc.get(place.parent).kind == .document) return;
        // The text node before the insertion point, if there is one.
        const prev: ?NodeId = if (place.before) |b| p.doc.get(b).prev else p.doc.get(place.parent).last_child;
        if (prev) |pv| if (p.doc.get(pv).kind == .text) {
            try p.doc.node(pv).text.appendSlice(p.a, data);
            return;
        };
        const id = try p.doc.createText(data);
        p.insertAt(place, id);
    }

    // ------------------------------------------- formatting elements

    fn pushFormatting(p: *Parser, id: NodeId, t: Tag) Error!void {
        // Noah's Ark: three matching entries since the last marker at most.
        var count: usize = 0;
        var i = p.afe.items.len;
        var earliest: ?usize = null;
        while (i > 0) {
            i -= 1;
            const f = p.afe.items[i];
            if (f.marker) break;
            if (eq(f.name, t.name) and p.doc.get(f.node).namespace == p.doc.get(id).namespace and sameAttrs(f.attrs, t.attrs)) {
                count += 1;
                earliest = i;
            }
        }
        if (count >= 3) _ = p.afe.orderedRemove(earliest.?);
        try p.afe.append(p.a, .{ .node = id, .name = t.name, .attrs = t.attrs });
    }

    fn sameAttrs(x: []const tokenizer.Attr, y: []const tokenizer.Attr) bool {
        if (x.len != y.len) return false;
        for (x) |ax| {
            var found = false;
            for (y) |ay| if (eq(ax.name, ay.name) and eq(ax.value, ay.value)) {
                found = true;
            };
            if (!found) return false;
        }
        return true;
    }

    fn pushMarker(p: *Parser) Error!void {
        try p.afe.append(p.a, .{ .node = 0, .name = "", .attrs = &.{}, .marker = true });
    }

    fn clearToMarker(p: *Parser) void {
        while (p.afe.items.len > 0) {
            const f = p.afe.pop().?;
            if (f.marker) return;
        }
    }

    fn afeIndexOf(p: *const Parser, id: NodeId) ?usize {
        var i = p.afe.items.len;
        while (i > 0) {
            i -= 1;
            if (!p.afe.items[i].marker and p.afe.items[i].node == id) return i;
        }
        return null;
    }

    /// The active formatting element with this name after the last
    /// marker, if any.
    fn afeFind(p: *const Parser, name: []const u8) ?usize {
        var i = p.afe.items.len;
        while (i > 0) {
            i -= 1;
            const f = p.afe.items[i];
            if (f.marker) return null;
            if (eq(f.name, name)) return i;
        }
        return null;
    }

    fn reconstructFormatting(p: *Parser) Error!void {
        if (p.afe.items.len == 0) return;
        var i = p.afe.items.len - 1;
        var last = p.afe.items[i];
        if (last.marker or p.inOpen(last.node)) return;
        // Rewind to the first entry that is a marker or open.
        while (i > 0) {
            i -= 1;
            last = p.afe.items[i];
            if (last.marker or p.inOpen(last.node)) {
                i += 1;
                break;
            }
        }
        // Advance, remaking each.
        while (i < p.afe.items.len) : (i += 1) {
            const f = p.afe.items[i];
            const id = try p.insertHtmlElement(.{ .name = f.name, .attrs = f.attrs });
            p.afe.items[i].node = id;
        }
    }

    // ---------------------------------------------- implied end tags

    const implied_end = [_][]const u8{ "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc" };
    const implied_end_thorough = [_][]const u8{ "caption", "colgroup", "dd", "dt", "li", "optgroup", "option", "p", "rb", "rp", "rt", "rtc", "tbody", "td", "tfoot", "th", "thead", "tr" };

    fn generateImpliedEndTags(p: *Parser, except: ?[]const u8) void {
        while (p.current()) |c| {
            const n = p.doc.get(c);
            if (n.namespace != .html or !inList(n.name, &implied_end)) return;
            if (except) |e| if (eq(n.name, e)) return;
            _ = p.pop();
        }
    }

    fn generateImpliedEndTagsThoroughly(p: *Parser) void {
        while (p.current()) |c| {
            const n = p.doc.get(c);
            if (n.namespace != .html or !inList(n.name, &implied_end_thorough)) return;
            _ = p.pop();
        }
    }

    fn closePElement(p: *Parser) void {
        p.generateImpliedEndTags("p");
        p.popUntilHtml("p");
    }

    // ---------------------------------------------------- categories

    const special = [_][]const u8{ "address", "applet", "area", "article", "aside", "base", "basefont", "bgsound", "blockquote", "body", "br", "button", "caption", "center", "col", "colgroup", "dd", "details", "dir", "div", "dl", "dt", "embed", "fieldset", "figcaption", "figure", "footer", "form", "frame", "frameset", "h1", "h2", "h3", "h4", "h5", "h6", "head", "header", "hgroup", "hr", "html", "iframe", "img", "input", "keygen", "li", "link", "listing", "main", "marquee", "menu", "meta", "nav", "noembed", "noframes", "noscript", "object", "ol", "p", "param", "plaintext", "pre", "script", "search", "section", "select", "source", "style", "summary", "table", "tbody", "td", "template", "textarea", "tfoot", "th", "thead", "title", "tr", "track", "ul", "wbr", "xmp" };
    const formatting_names = [_][]const u8{ "a", "b", "big", "code", "em", "font", "i", "nobr", "s", "small", "strike", "strong", "tt", "u" };

    fn isSpecial(p: *const Parser, id: NodeId) bool {
        const n = p.doc.get(id);
        return switch (n.namespace) {
            .html => inList(n.name, &special),
            .mathml => inList(n.name, &scope_mathml),
            .svg => inList(n.name, &scope_svg),
        };
    }

    fn isMathmlTextIntegrationPoint(p: *const Parser, id: NodeId) bool {
        const n = p.doc.get(id);
        return n.namespace == .mathml and inList(n.name, &.{ "mi", "mo", "mn", "ms", "mtext" });
    }

    fn isHtmlIntegrationPoint(p: *const Parser, id: NodeId) bool {
        const n = p.doc.get(id);
        if (n.namespace == .mathml and eq(n.name, "annotation-xml")) {
            const enc = p.doc.getAttr(id, "encoding") orelse return false;
            return std.ascii.eqlIgnoreCase(enc, "text/html") or std.ascii.eqlIgnoreCase(enc, "application/xhtml+xml");
        }
        return n.namespace == .svg and inList(n.name, &.{ "foreignObject", "desc", "title" });
    }

    // ------------------------------------------------- reset the mode

    fn resetInsertionMode(p: *Parser) void {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            var node = p.open.items[i];
            const last = i == 0;
            if (last and p.context != null) node = p.context.?;
            const n = p.doc.get(node);
            if (n.namespace != .html) continue;
            if ((eq(n.name, "td") or eq(n.name, "th")) and !last) {
                p.mode = .in_cell;
                return;
            }
            if (eq(n.name, "tr")) {
                p.mode = .in_row;
                return;
            }
            if (inList(n.name, &.{ "tbody", "thead", "tfoot" })) {
                p.mode = .in_table_body;
                return;
            }
            if (eq(n.name, "caption")) {
                p.mode = .in_caption;
                return;
            }
            if (eq(n.name, "colgroup")) {
                p.mode = .in_column_group;
                return;
            }
            if (eq(n.name, "table")) {
                p.mode = .in_table;
                return;
            }
            if (eq(n.name, "template")) {
                p.mode = p.template_modes.items[p.template_modes.items.len - 1];
                return;
            }
            if (eq(n.name, "head") and !last) {
                p.mode = .in_head;
                return;
            }
            if (eq(n.name, "body")) {
                p.mode = .in_body;
                return;
            }
            if (eq(n.name, "frameset")) {
                p.mode = .in_frameset;
                return;
            }
            if (eq(n.name, "html")) {
                p.mode = if (p.head == null) .before_head else .after_head;
                return;
            }
            if (last) {
                p.mode = .in_body;
                return;
            }
        }
        p.mode = .in_body;
    }

    // ------------------------------------------------------ the modes

    fn process(p: *Parser, t: Tok, mode: Mode) Error!void {
        switch (mode) {
            .initial => try p.modeInitial(t),
            .before_html => try p.modeBeforeHtml(t),
            .before_head => try p.modeBeforeHead(t),
            .in_head => try p.modeInHead(t),
            .in_head_noscript => try p.modeInHeadNoscript(t),
            .after_head => try p.modeAfterHead(t),
            .in_body => try p.modeInBody(t),
            .text => try p.modeText(t),
            .in_table => try p.modeInTable(t),
            .in_table_text => try p.modeInTableText(t),
            .in_caption => try p.modeInCaption(t),
            .in_column_group => try p.modeInColumnGroup(t),
            .in_table_body => try p.modeInTableBody(t),
            .in_row => try p.modeInRow(t),
            .in_cell => try p.modeInCell(t),
            .in_template => try p.modeInTemplate(t),
            .after_body => try p.modeAfterBody(t),
            .in_frameset => try p.modeInFrameset(t),
            .after_frameset => try p.modeAfterFrameset(t),
            .after_after_body => try p.modeAfterAfterBody(t),
            .after_after_frameset => try p.modeAfterAfterFrameset(t),
        }
    }

    fn modeInitial(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => return,
            .comment => |c| return p.insertComment(c, .{ .parent = dom.document_id }),
            .doctype => |d| {
                const name = d.name orelse "";
                const id = try p.doc.createDoctype(name, d.public_id, d.system_id);
                p.doc.appendChild(dom.document_id, id);
                p.doc.quirks = quirksFor(d);
                p.mode = .before_html;
                return;
            },
            else => {},
        }
        if (p.context == null) p.doc.quirks = .quirks;
        p.mode = .before_html;
        try p.process(t, .before_html);
    }

    fn quirksFor(d: tokenizer.Doctype) dom.QuirksMode {
        const name = d.name orelse "";
        const pub_id = d.public_id;
        const sys_id = d.system_id;
        const quirky_prefixes = [_][]const u8{ "+//silmaril//dtd html pro v0r11 19970101//", "-//as//dtd html 3.0 aswedit + extensions//", "-//advasoft ltd//dtd html 3.0 aswedit + extensions//", "-//ietf//dtd html 2.0 level 1//", "-//ietf//dtd html 2.0 level 2//", "-//ietf//dtd html 2.0 strict level 1//", "-//ietf//dtd html 2.0 strict level 2//", "-//ietf//dtd html 2.0 strict//", "-//ietf//dtd html 2.0//", "-//ietf//dtd html 2.1e//", "-//ietf//dtd html 3.0//", "-//ietf//dtd html 3.2 final//", "-//ietf//dtd html 3.2//", "-//ietf//dtd html 3//", "-//ietf//dtd html level 0//", "-//ietf//dtd html level 1//", "-//ietf//dtd html level 2//", "-//ietf//dtd html level 3//", "-//ietf//dtd html strict level 0//", "-//ietf//dtd html strict level 1//", "-//ietf//dtd html strict level 2//", "-//ietf//dtd html strict level 3//", "-//ietf//dtd html strict//", "-//ietf//dtd html//", "-//metrius//dtd metrius presentational//", "-//microsoft//dtd internet explorer 2.0 html strict//", "-//microsoft//dtd internet explorer 2.0 html//", "-//microsoft//dtd internet explorer 2.0 tables//", "-//microsoft//dtd internet explorer 3.0 html strict//", "-//microsoft//dtd internet explorer 3.0 html//", "-//microsoft//dtd internet explorer 3.0 tables//", "-//netscape comm. corp.//dtd html//", "-//netscape comm. corp.//dtd strict html//", "-//o'reilly and associates//dtd html 2.0//", "-//o'reilly and associates//dtd html extended 1.0//", "-//o'reilly and associates//dtd html extended relaxed 1.0//", "-//sq//dtd html 2.0 hotmetal + extensions//", "-//softquad software//dtd hotmetal pro 6.0::19990601::extensions to html 4.0//", "-//softquad//dtd hotmetal pro 4.0::19971010::extensions to html 4.0//", "-//spyglass//dtd html 2.0 extended//", "-//sun microsystems corp.//dtd hotjava html//", "-//sun microsystems corp.//dtd hotjava strict html//", "-//w3c//dtd html 3 1995-03-24//", "-//w3c//dtd html 3.2 draft//", "-//w3c//dtd html 3.2 final//", "-//w3c//dtd html 3.2//", "-//w3c//dtd html 3.2s draft//", "-//w3c//dtd html 4.0 frameset//", "-//w3c//dtd html 4.0 transitional//", "-//w3c//dtd html experimental 19960712//", "-//w3c//dtd html experimental 970421//", "-//w3c//dtd w3 html//", "-//w3o//dtd w3 html 3.0//", "-//webtechs//dtd mozilla html 2.0//", "-//webtechs//dtd mozilla html//" };
        if (d.force_quirks or !eq(name, "html")) return .quirks;
        if (pub_id) |pi| {
            if (std.ascii.eqlIgnoreCase(pi, "-//W3O//DTD W3 HTML Strict 3.0//EN//") or std.ascii.eqlIgnoreCase(pi, "-/W3C/DTD HTML 4.0 Transitional/EN") or std.ascii.eqlIgnoreCase(pi, "HTML")) return .quirks;
            for (quirky_prefixes) |pre| if (std.ascii.startsWithIgnoreCase(pi, pre)) return .quirks;
            if (sys_id == null and (std.ascii.startsWithIgnoreCase(pi, "-//w3c//dtd html 4.01 frameset//") or std.ascii.startsWithIgnoreCase(pi, "-//w3c//dtd html 4.01 transitional//"))) return .quirks;
            if (std.ascii.startsWithIgnoreCase(pi, "-//w3c//dtd xhtml 1.0 frameset//") or std.ascii.startsWithIgnoreCase(pi, "-//w3c//dtd xhtml 1.0 transitional//")) return .limited_quirks;
            if (sys_id != null and (std.ascii.startsWithIgnoreCase(pi, "-//w3c//dtd html 4.01 frameset//") or std.ascii.startsWithIgnoreCase(pi, "-//w3c//dtd html 4.01 transitional//"))) return .limited_quirks;
        }
        if (sys_id) |si| if (std.ascii.eqlIgnoreCase(si, "http://www.ibm.com/data/dtd/v11/ibmxhtml1-transitional.dtd")) return .quirks;
        return .no_quirks;
    }

    fn modeBeforeHtml(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .doctype => return,
            .comment => |c| return p.insertComment(c, .{ .parent = dom.document_id }),
            .ws => return,
            .start => |s| if (eq(s.name, "html")) {
                const id = try p.createElementFor(s, .html);
                p.doc.appendChild(dom.document_id, id);
                try p.open.append(p.a, id);
                p.mode = .before_head;
                return;
            },
            .end => |e| if (!inList(e.name, &.{ "head", "body", "html", "br" })) return,
            else => {},
        }
        const id = try p.doc.createElement(.html, "html");
        p.doc.appendChild(dom.document_id, id);
        try p.open.append(p.a, id);
        p.mode = .before_head;
        try p.process(t, .before_head);
    }

    fn modeBeforeHead(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => return,
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                if (eq(s.name, "html")) return p.modeInBody(t);
                if (eq(s.name, "head")) {
                    p.head = try p.insertHtmlElement(s);
                    p.mode = .in_head;
                    return;
                }
            },
            .end => |e| if (!inList(e.name, &.{ "head", "body", "html", "br" })) return,
            else => {},
        }
        p.head = try p.insertHtmlNamed("head");
        p.mode = .in_head;
        try p.process(t, .in_head);
    }

    fn modeInHead(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => |w| return p.insertText(w),
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                const n = s.name;
                if (eq(n, "html")) return p.modeInBody(t);
                if (inList(n, &.{ "base", "basefont", "bgsound", "link", "meta" })) {
                    _ = try p.insertHtmlElement(s);
                    _ = p.pop();
                    return;
                }
                if (eq(n, "title")) return p.genericRcdata(s);
                if (eq(n, "noscript") and p.scripting) return p.genericRawtext(s);
                if (eq(n, "noframes") or eq(n, "style")) return p.genericRawtext(s);
                if (eq(n, "noscript")) {
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_head_noscript;
                    return;
                }
                if (eq(n, "script")) {
                    const place = p.insertionPlace(null);
                    const id = try p.createElementFor(s, .html);
                    p.insertAt(place, id);
                    try p.open.append(p.a, id);
                    p.tok.state = .script_data;
                    p.original_mode = p.mode;
                    p.mode = .text;
                    return;
                }
                if (eq(n, "template")) {
                    _ = try p.insertHtmlElement(s);
                    try p.pushMarker();
                    p.frameset_ok = false;
                    p.mode = .in_template;
                    try p.template_modes.append(p.a, .in_template);
                    return;
                }
                if (eq(n, "head")) return;
            },
            .end => |e| {
                const n = e.name;
                if (eq(n, "head")) {
                    _ = p.pop();
                    p.mode = .after_head;
                    return;
                }
                if (eq(n, "template")) {
                    if (p.lastInOpen("template") == null) return;
                    p.generateImpliedEndTagsThoroughly();
                    p.popUntilHtml("template");
                    p.clearToMarker();
                    _ = p.template_modes.pop();
                    p.resetInsertionMode();
                    return;
                }
                if (!inList(n, &.{ "body", "html", "br" })) return;
            },
            else => {},
        }
        _ = p.pop();
        p.mode = .after_head;
        try p.process(t, .after_head);
    }

    fn genericRcdata(p: *Parser, s: Tag) Error!void {
        _ = try p.insertHtmlElement(s);
        p.tok.state = .rcdata;
        p.original_mode = p.mode;
        p.mode = .text;
    }

    fn genericRawtext(p: *Parser, s: Tag) Error!void {
        _ = try p.insertHtmlElement(s);
        p.tok.state = .rawtext;
        p.original_mode = p.mode;
        p.mode = .text;
    }

    fn modeInHeadNoscript(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .doctype => return,
            .start => |s| {
                if (eq(s.name, "html")) return p.modeInBody(t);
                if (inList(s.name, &.{ "basefont", "bgsound", "link", "meta", "noframes", "style" })) return p.modeInHead(t);
                if (eq(s.name, "head") or eq(s.name, "noscript")) return;
            },
            .end => |e| {
                if (eq(e.name, "noscript")) {
                    _ = p.pop();
                    p.mode = .in_head;
                    return;
                }
                if (!eq(e.name, "br")) return;
            },
            .ws, .comment => return p.modeInHead(t),
            else => {},
        }
        _ = p.pop();
        p.mode = .in_head;
        try p.process(t, .in_head);
    }

    fn modeAfterHead(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => |w| return p.insertText(w),
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                const n = s.name;
                if (eq(n, "html")) return p.modeInBody(t);
                if (eq(n, "body")) {
                    _ = try p.insertHtmlElement(s);
                    p.frameset_ok = false;
                    p.mode = .in_body;
                    return;
                }
                if (eq(n, "frameset")) {
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_frameset;
                    return;
                }
                if (inList(n, &.{ "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title" })) {
                    try p.open.append(p.a, p.head.?);
                    try p.modeInHead(t);
                    p.removeFromOpen(p.head.?);
                    return;
                }
                if (eq(n, "head")) return;
            },
            .end => |e| {
                if (eq(e.name, "template")) return p.modeInHead(t);
                if (!inList(e.name, &.{ "body", "html", "br" })) return;
            },
            else => {},
        }
        _ = try p.insertHtmlNamed("body");
        p.mode = .in_body;
        try p.process(t, .in_body);
    }

    // ----------------------------------------------------- in body

    const headings = [_][]const u8{ "h1", "h2", "h3", "h4", "h5", "h6" };

    fn modeInBody(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .nul => return,
            .ws => |w| {
                try p.reconstructFormatting();
                try p.insertText(w);
            },
            .text => |x| {
                try p.reconstructFormatting();
                try p.insertText(x);
                p.frameset_ok = false;
            },
            .comment => |c| try p.insertComment(c, null),
            .doctype => return,
            .start => |s| try p.inBodyStart(t, s),
            .end => |e| try p.inBodyEnd(t, e),
            .eof => {
                if (p.template_modes.items.len > 0) return p.modeInTemplate(t);
                p.stopped = true;
            },
        }
    }

    fn inBodyStart(p: *Parser, t: Tok, s: Tag) Error!void {
        const n = s.name;
        if (eq(n, "html")) {
            if (p.lastInOpen("template") != null) return;
            const html = p.open.items[0];
            for (s.attrs) |at| if (!p.doc.hasAttr(html, at.name)) try p.doc.setAttr(html, at.name, at.value);
            return;
        }
        if (inList(n, &.{ "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title" })) return p.modeInHead(t);
        if (eq(n, "body")) {
            if (p.open.items.len < 2 or !p.doc.isHtml(p.open.items[1], "body") or p.lastInOpen("template") != null) return;
            p.frameset_ok = false;
            const body = p.open.items[1];
            for (s.attrs) |at| if (!p.doc.hasAttr(body, at.name)) try p.doc.setAttr(body, at.name, at.value);
            return;
        }
        if (eq(n, "frameset")) {
            if (p.open.items.len < 2 or !p.doc.isHtml(p.open.items[1], "body") or !p.frameset_ok) return;
            const body = p.open.items[1];
            p.doc.detach(body);
            p.open.items.len = 1;
            _ = try p.insertHtmlElement(s);
            p.mode = .in_frameset;
            return;
        }
        if (inList(n, &.{ "address", "article", "aside", "blockquote", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "main", "menu", "nav", "ol", "p", "search", "section", "summary", "ul" })) {
            if (p.inScope("p", .button)) p.closePElement();
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (inList(n, &headings)) {
            if (p.inScope("p", .button)) p.closePElement();
            if (p.current()) |c| {
                const cn = p.doc.get(c);
                if (cn.namespace == .html and inList(cn.name, &headings)) _ = p.pop();
            }
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "pre") or eq(n, "listing")) {
            if (p.inScope("p", .button)) p.closePElement();
            _ = try p.insertHtmlElement(s);
            p.ignore_lf = true;
            p.frameset_ok = false;
            return;
        }
        if (eq(n, "form")) {
            if (p.form != null and p.lastInOpen("template") == null) return;
            if (p.inScope("p", .button)) p.closePElement();
            const id = try p.insertHtmlElement(s);
            if (p.lastInOpen("template") == null) p.form = id;
            return;
        }
        if (eq(n, "li")) {
            p.frameset_ok = false;
            var i = p.open.items.len;
            while (i > 0) {
                i -= 1;
                const node = p.open.items[i];
                const nd = p.doc.get(node);
                if (p.doc.isHtml(node, "li")) {
                    p.generateImpliedEndTags("li");
                    p.popUntilHtml("li");
                    break;
                }
                if (p.isSpecial(node) and !(nd.namespace == .html and inList(nd.name, &.{ "address", "div", "p" }))) break;
            }
            if (p.inScope("p", .button)) p.closePElement();
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "dd") or eq(n, "dt")) {
            p.frameset_ok = false;
            var i = p.open.items.len;
            while (i > 0) {
                i -= 1;
                const node = p.open.items[i];
                const nd = p.doc.get(node);
                if (p.doc.isHtml(node, "dd")) {
                    p.generateImpliedEndTags("dd");
                    p.popUntilHtml("dd");
                    break;
                }
                if (p.doc.isHtml(node, "dt")) {
                    p.generateImpliedEndTags("dt");
                    p.popUntilHtml("dt");
                    break;
                }
                if (p.isSpecial(node) and !(nd.namespace == .html and inList(nd.name, &.{ "address", "div", "p" }))) break;
            }
            if (p.inScope("p", .button)) p.closePElement();
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "plaintext")) {
            if (p.inScope("p", .button)) p.closePElement();
            _ = try p.insertHtmlElement(s);
            p.tok.state = .plaintext;
            return;
        }
        if (eq(n, "button")) {
            if (p.inScope("button", .default)) {
                p.generateImpliedEndTags(null);
                p.popUntilHtml("button");
            }
            try p.reconstructFormatting();
            _ = try p.insertHtmlElement(s);
            p.frameset_ok = false;
            return;
        }
        if (eq(n, "a")) {
            if (p.afeFind("a")) |idx| {
                const el = p.afe.items[idx].node;
                try p.adoptionAgency("a");
                if (p.afeIndexOf(el)) |again| _ = p.afe.orderedRemove(again);
                p.removeFromOpen(el);
            }
            try p.reconstructFormatting();
            const id = try p.insertHtmlElement(s);
            try p.pushFormatting(id, s);
            return;
        }
        if (inList(n, &.{ "b", "big", "code", "em", "font", "i", "s", "small", "strike", "strong", "tt", "u" })) {
            try p.reconstructFormatting();
            const id = try p.insertHtmlElement(s);
            try p.pushFormatting(id, s);
            return;
        }
        if (eq(n, "nobr")) {
            try p.reconstructFormatting();
            if (p.inScope("nobr", .default)) {
                try p.adoptionAgency("nobr");
                try p.reconstructFormatting();
            }
            const id = try p.insertHtmlElement(s);
            try p.pushFormatting(id, s);
            return;
        }
        if (inList(n, &.{ "applet", "marquee", "object" })) {
            try p.reconstructFormatting();
            _ = try p.insertHtmlElement(s);
            try p.pushMarker();
            p.frameset_ok = false;
            return;
        }
        if (eq(n, "table")) {
            if (p.doc.quirks != .quirks and p.inScope("p", .button)) p.closePElement();
            _ = try p.insertHtmlElement(s);
            p.frameset_ok = false;
            p.mode = .in_table;
            return;
        }
        if (inList(n, &.{ "area", "br", "embed", "img", "keygen", "wbr" })) {
            try p.reconstructFormatting();
            _ = try p.insertHtmlElement(s);
            _ = p.pop();
            p.frameset_ok = false;
            return;
        }
        if (eq(n, "input")) {
            if (p.contextIs("select")) return;
            if (p.inScope("select", .default)) p.popUntilHtml("select");
            try p.reconstructFormatting();
            const id = try p.insertHtmlElement(s);
            _ = p.pop();
            const typ = p.doc.getAttr(id, "type");
            if (typ == null or !std.ascii.eqlIgnoreCase(typ.?, "hidden")) p.frameset_ok = false;
            return;
        }
        if (inList(n, &.{ "param", "source", "track" })) {
            _ = try p.insertHtmlElement(s);
            _ = p.pop();
            return;
        }
        if (eq(n, "hr")) {
            if (p.inScope("p", .button)) p.closePElement();
            if (p.inScope("select", .default)) p.generateImpliedEndTags(null);
            _ = try p.insertHtmlElement(s);
            _ = p.pop();
            p.frameset_ok = false;
            return;
        }
        if (eq(n, "image")) return p.inBodyStart(t, .{ .name = "img", .attrs = s.attrs, .self_closing = s.self_closing });
        if (eq(n, "textarea")) {
            _ = try p.insertHtmlElement(s);
            p.ignore_lf = true;
            p.tok.state = .rcdata;
            p.original_mode = p.mode;
            p.frameset_ok = false;
            p.mode = .text;
            return;
        }
        if (eq(n, "xmp")) {
            if (p.inScope("p", .button)) p.closePElement();
            try p.reconstructFormatting();
            p.frameset_ok = false;
            return p.genericRawtext(s);
        }
        if (eq(n, "iframe")) {
            p.frameset_ok = false;
            return p.genericRawtext(s);
        }
        if (eq(n, "noembed") or (eq(n, "noscript") and p.scripting)) return p.genericRawtext(s);
        if (eq(n, "select")) {
            if (p.contextIs("select")) return;
            if (p.inScope("select", .default)) {
                p.popUntilHtml("select");
                return;
            }
            try p.reconstructFormatting();
            _ = try p.insertHtmlElement(s);
            p.frameset_ok = false;
            return;
        }
        if (eq(n, "option")) {
            if (p.inScope("select", .default)) {
                p.generateImpliedEndTags("optgroup");
            } else if (p.current()) |c| if (p.doc.isHtml(c, "option")) {
                _ = p.pop();
            };
            try p.reconstructFormatting();
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "optgroup")) {
            if (p.inScope("select", .default)) {
                p.generateImpliedEndTags(null);
            } else if (p.current()) |c| if (p.doc.isHtml(c, "option")) {
                _ = p.pop();
            };
            try p.reconstructFormatting();
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "rb") or eq(n, "rtc")) {
            if (p.inScope("ruby", .default)) p.generateImpliedEndTags(null);
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "rp") or eq(n, "rt")) {
            if (p.inScope("ruby", .default)) p.generateImpliedEndTags("rtc");
            _ = try p.insertHtmlElement(s);
            return;
        }
        if (eq(n, "math")) {
            try p.reconstructFormatting();
            const adjusted = try p.adjustMathmlAttrs(s);
            _ = try p.insertElement(adjusted, .mathml);
            if (s.self_closing) _ = p.pop();
            return;
        }
        if (eq(n, "svg")) {
            try p.reconstructFormatting();
            const adjusted = try p.adjustSvgAttrs(s);
            _ = try p.insertElement(adjusted, .svg);
            if (s.self_closing) _ = p.pop();
            return;
        }
        if (inList(n, &.{ "caption", "col", "colgroup", "frame", "head", "tbody", "td", "tfoot", "th", "thead", "tr" })) return;
        try p.reconstructFormatting();
        _ = try p.insertHtmlElement(s);
    }

    fn inBodyEnd(p: *Parser, t: Tok, e: Tag) Error!void {
        const n = e.name;
        if (eq(n, "template")) return p.modeInHead(t);
        if (eq(n, "body") or eq(n, "html")) {
            if (!p.inScope("body", .default)) return;
            p.mode = .after_body;
            if (eq(n, "html")) try p.modeAfterBody(t);
            return;
        }
        if (inList(n, &.{ "address", "article", "aside", "blockquote", "button", "center", "details", "dialog", "dir", "div", "dl", "fieldset", "figcaption", "figure", "footer", "header", "hgroup", "listing", "main", "menu", "nav", "ol", "pre", "search", "section", "summary", "ul" })) {
            if (!p.inScope(n, .default)) return;
            p.generateImpliedEndTags(null);
            p.popUntilHtml(n);
            return;
        }
        if (eq(n, "form")) {
            if (p.lastInOpen("template") == null) {
                const node = p.form;
                p.form = null;
                if (node == null or !p.nodeInScope(node.?, .default)) return;
                p.generateImpliedEndTags(null);
                p.removeFromOpen(node.?);
            } else {
                if (!p.inScope("form", .default)) return;
                p.generateImpliedEndTags(null);
                p.popUntilHtml("form");
            }
            return;
        }
        if (eq(n, "p")) {
            if (!p.inScope("p", .button)) _ = try p.insertHtmlNamed("p");
            p.closePElement();
            return;
        }
        if (eq(n, "li")) {
            if (!p.inScope("li", .list_item)) return;
            p.generateImpliedEndTags("li");
            p.popUntilHtml("li");
            return;
        }
        if (eq(n, "dd") or eq(n, "dt")) {
            if (!p.inScope(n, .default)) return;
            p.generateImpliedEndTags(n);
            p.popUntilHtml(n);
            return;
        }
        if (inList(n, &headings)) {
            if (!p.inScopeAny(&headings, .default)) return;
            p.generateImpliedEndTags(null);
            p.popUntilOneOf(&headings);
            return;
        }
        if (inList(n, &formatting_names)) return p.adoptionAgency(n);
        if (inList(n, &.{ "applet", "marquee", "object" })) {
            if (!p.inScope(n, .default)) return;
            p.generateImpliedEndTags(null);
            p.popUntilHtml(n);
            p.clearToMarker();
            return;
        }
        if (eq(n, "br")) return p.inBodyStart(t, .{ .name = "br" });
        // Any other end tag.
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            const node = p.open.items[i];
            const nd = p.doc.get(node);
            if (nd.namespace == .html and eq(nd.name, n)) {
                p.generateImpliedEndTags(n);
                p.open.items.len = i;
                return;
            }
            if (p.isSpecial(node)) return;
        }
    }

    /// The adoption agency algorithm (§13.2.6.4.7, "in body", any end
    /// tag whose tag name is one of the formatting elements).
    fn adoptionAgency(p: *Parser, subject: []const u8) Error!void {
        if (p.current()) |c| if (p.doc.isHtml(c, subject) and p.afeIndexOf(c) == null) {
            _ = p.pop();
            return;
        };
        var outer: usize = 0;
        while (outer < 8) : (outer += 1) {
            const fe_idx = p.afeFind(subject) orelse return p.anyOtherEndTag(subject);
            const fe = p.afe.items[fe_idx].node;
            if (!p.inOpen(fe)) {
                _ = p.afe.orderedRemove(fe_idx);
                return;
            }
            if (!p.nodeInScope(fe, .default)) return;
            const fe_open = p.indexInOpen(fe).?;
            // The furthest block: the topmost special element below the
            // formatting element in the stack.
            var furthest: ?usize = null;
            var k = fe_open + 1;
            while (k < p.open.items.len) : (k += 1) {
                if (p.isSpecial(p.open.items[k])) {
                    furthest = k;
                    break;
                }
            }
            if (furthest == null) {
                p.open.items.len = fe_open;
                _ = p.afe.orderedRemove(fe_idx);
                return;
            }
            const fb = p.open.items[furthest.?];
            const common = p.open.items[fe_open - 1];
            var bookmark = fe_idx;
            var node_idx = furthest.?;
            var node = fb;
            var last_node = fb;
            var inner: usize = 0;
            while (true) {
                inner += 1;
                node_idx -= 1;
                node = p.open.items[node_idx];
                if (node == fe) break;
                var node_afe = p.afeIndexOf(node);
                if (inner > 3 and node_afe != null) {
                    _ = p.afe.orderedRemove(node_afe.?);
                    if (node_afe.? < bookmark) bookmark -= 1;
                    node_afe = null;
                }
                if (node_afe == null) {
                    _ = p.open.orderedRemove(node_idx);
                    continue;
                }
                // Remake the node from its formatting entry.
                const f = p.afe.items[node_afe.?];
                const fresh = try p.createElementFor(.{ .name = f.name, .attrs = f.attrs }, .html);
                p.afe.items[node_afe.?].node = fresh;
                p.open.items[node_idx] = fresh;
                node = fresh;
                if (last_node == fb) bookmark = node_afe.? + 1;
                p.doc.appendChild(node, last_node);
                last_node = node;
            }
            // Insert last node at the appropriate place for the common
            // ancestor (foster parenting applies).
            const place = p.insertionPlace(common);
            p.doc.detach(last_node);
            p.insertAt(place, last_node);
            const fe_entry = p.afe.items[fe_idx];
            const fresh_fe = try p.createElementFor(.{ .name = fe_entry.name, .attrs = fe_entry.attrs }, .html);
            p.doc.reparentChildren(fb, fresh_fe);
            p.doc.appendChild(fb, fresh_fe);
            // Move the formatting entry to the bookmark.
            _ = p.afe.orderedRemove(fe_idx);
            if (fe_idx < bookmark) bookmark -= 1;
            try p.afe.insert(p.a, @min(bookmark, p.afe.items.len), .{ .node = fresh_fe, .name = fe_entry.name, .attrs = fe_entry.attrs });
            // And in the stack: remove the old, insert the new below the
            // furthest block.
            p.removeFromOpen(fe);
            const fb_idx = p.indexInOpen(fb).?;
            try p.open.insert(p.a, fb_idx + 1, fresh_fe);
        }
    }

    fn anyOtherEndTag(p: *Parser, n: []const u8) Error!void {
        var i = p.open.items.len;
        while (i > 0) {
            i -= 1;
            const node = p.open.items[i];
            const nd = p.doc.get(node);
            if (nd.namespace == .html and eq(nd.name, n)) {
                p.generateImpliedEndTags(n);
                p.open.items.len = i;
                return;
            }
            if (p.isSpecial(node)) return;
        }
    }

    fn modeText(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => |w| try p.insertText(w),
            .text => |x| try p.insertText(x),
            .nul => try p.insertText("\u{fffd}"),
            .eof => {
                _ = p.pop();
                p.mode = p.original_mode;
                try p.process(t, p.mode);
            },
            .end => {
                _ = p.pop();
                p.mode = p.original_mode;
            },
            else => {},
        }
    }

    // ------------------------------------------------------- tables

    fn modeInTable(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws, .text, .nul => {
                if (p.current()) |c| if (p.doc.get(c).namespace == .html and inList(p.doc.get(c).name, &.{ "table", "tbody", "template", "tfoot", "thead", "tr" })) {
                    p.pending_table_text.clearRetainingCapacity();
                    p.pending_table_nonws = false;
                    p.original_mode = p.mode;
                    p.mode = .in_table_text;
                    return p.modeInTableText(t);
                };
                return p.inTableAnything(t);
            },
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                const n = s.name;
                if (eq(n, "caption")) {
                    p.clearStackToTableContext();
                    try p.pushMarker();
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_caption;
                    return;
                }
                if (eq(n, "colgroup")) {
                    p.clearStackToTableContext();
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_column_group;
                    return;
                }
                if (eq(n, "col")) {
                    p.clearStackToTableContext();
                    _ = try p.insertHtmlNamed("colgroup");
                    p.mode = .in_column_group;
                    return p.modeInColumnGroup(t);
                }
                if (inList(n, &.{ "tbody", "tfoot", "thead" })) {
                    p.clearStackToTableContext();
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_table_body;
                    return;
                }
                if (inList(n, &.{ "td", "th", "tr" })) {
                    p.clearStackToTableContext();
                    _ = try p.insertHtmlNamed("tbody");
                    p.mode = .in_table_body;
                    return p.modeInTableBody(t);
                }
                if (eq(n, "table")) {
                    if (!p.inScope("table", .table)) return;
                    p.popUntilHtml("table");
                    p.resetInsertionMode();
                    return p.dispatch(t);
                }
                if (inList(n, &.{ "style", "script", "template" })) return p.modeInHead(t);
                if (eq(n, "input")) {
                    var hidden = false;
                    for (s.attrs) |at| if (eq(at.name, "type") and std.ascii.eqlIgnoreCase(at.value, "hidden")) {
                        hidden = true;
                    };
                    if (!hidden) return p.inTableAnything(t);
                    _ = try p.insertHtmlElement(s);
                    _ = p.pop();
                    return;
                }
                if (eq(n, "form")) {
                    if (p.lastInOpen("template") != null or p.form != null) return;
                    p.form = try p.insertHtmlElement(s);
                    _ = p.pop();
                    return;
                }
                return p.inTableAnything(t);
            },
            .end => |e| {
                const n = e.name;
                if (eq(n, "table")) {
                    if (!p.inScope("table", .table)) return;
                    p.popUntilHtml("table");
                    p.resetInsertionMode();
                    return;
                }
                if (inList(n, &.{ "body", "caption", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr" })) return;
                if (eq(n, "template")) return p.modeInHead(t);
                return p.inTableAnything(t);
            },
            .eof => return p.modeInBody(t),
        }
    }

    fn inTableAnything(p: *Parser, t: Tok) Error!void {
        p.foster = true;
        try p.modeInBody(t);
        p.foster = false;
    }

    fn clearStackToTableContext(p: *Parser) void {
        while (p.current()) |c| {
            const n = p.doc.get(c);
            if (n.namespace == .html and inList(n.name, &.{ "table", "template", "html" })) return;
            _ = p.pop();
        }
    }

    fn clearStackToTableBodyContext(p: *Parser) void {
        while (p.current()) |c| {
            const n = p.doc.get(c);
            if (n.namespace == .html and inList(n.name, &.{ "tbody", "tfoot", "thead", "template", "html" })) return;
            _ = p.pop();
        }
    }

    fn clearStackToTableRowContext(p: *Parser) void {
        while (p.current()) |c| {
            const n = p.doc.get(c);
            if (n.namespace == .html and inList(n.name, &.{ "tr", "template", "html" })) return;
            _ = p.pop();
        }
    }

    fn modeInTableText(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .nul => return,
            .ws => |w| return p.pending_table_text.appendSlice(p.a, w),
            .text => |x| {
                p.pending_table_nonws = true;
                return p.pending_table_text.appendSlice(p.a, x);
            },
            else => {},
        }
        const text = try p.a.dupe(u8, p.pending_table_text.items);
        if (p.pending_table_nonws) {
            // Whitespace and text alike, fostered, as "in body" would.
            p.foster = true;
            try p.reconstructFormatting();
            try p.insertText(text);
            p.frameset_ok = false;
            p.foster = false;
        } else if (text.len > 0) try p.insertText(text);
        p.mode = p.original_mode;
        try p.process(t, p.mode);
    }

    fn modeInCaption(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .start => |s| if (inList(s.name, &.{ "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr" })) {
                if (!p.inScope("caption", .table)) return;
                p.generateImpliedEndTags(null);
                p.popUntilHtml("caption");
                p.clearToMarker();
                p.mode = .in_table;
                return p.modeInTable(t);
            },
            .end => |e| {
                if (eq(e.name, "caption")) {
                    if (!p.inScope("caption", .table)) return;
                    p.generateImpliedEndTags(null);
                    p.popUntilHtml("caption");
                    p.clearToMarker();
                    p.mode = .in_table;
                    return;
                }
                if (eq(e.name, "table")) {
                    if (!p.inScope("caption", .table)) return;
                    p.generateImpliedEndTags(null);
                    p.popUntilHtml("caption");
                    p.clearToMarker();
                    p.mode = .in_table;
                    return p.modeInTable(t);
                }
                if (inList(e.name, &.{ "body", "col", "colgroup", "html", "tbody", "td", "tfoot", "th", "thead", "tr" })) return;
            },
            else => {},
        }
        try p.modeInBody(t);
    }

    fn modeInColumnGroup(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => |w| return p.insertText(w),
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                if (eq(s.name, "html")) return p.modeInBody(t);
                if (eq(s.name, "col")) {
                    _ = try p.insertHtmlElement(s);
                    _ = p.pop();
                    return;
                }
                if (eq(s.name, "template")) return p.modeInHead(t);
            },
            .end => |e| {
                if (eq(e.name, "colgroup")) {
                    if (p.current() == null or !p.doc.isHtml(p.current().?, "colgroup")) return;
                    _ = p.pop();
                    p.mode = .in_table;
                    return;
                }
                if (eq(e.name, "col")) return;
                if (eq(e.name, "template")) return p.modeInHead(t);
            },
            .eof => return p.modeInBody(t),
            else => {},
        }
        if (p.current() == null or !p.doc.isHtml(p.current().?, "colgroup")) return;
        _ = p.pop();
        p.mode = .in_table;
        try p.modeInTable(t);
    }

    fn modeInTableBody(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .start => |s| {
                if (eq(s.name, "tr")) {
                    p.clearStackToTableBodyContext();
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_row;
                    return;
                }
                if (eq(s.name, "th") or eq(s.name, "td")) {
                    p.clearStackToTableBodyContext();
                    _ = try p.insertHtmlNamed("tr");
                    p.mode = .in_row;
                    return p.modeInRow(t);
                }
                if (inList(s.name, &.{ "caption", "col", "colgroup", "tbody", "tfoot", "thead" })) {
                    if (!p.inScopeAny(&.{ "tbody", "thead", "tfoot" }, .table)) return;
                    p.clearStackToTableBodyContext();
                    _ = p.pop();
                    p.mode = .in_table;
                    return p.modeInTable(t);
                }
            },
            .end => |e| {
                if (inList(e.name, &.{ "tbody", "tfoot", "thead" })) {
                    if (!p.inScope(e.name, .table)) return;
                    p.clearStackToTableBodyContext();
                    _ = p.pop();
                    p.mode = .in_table;
                    return;
                }
                if (eq(e.name, "table")) {
                    if (!p.inScopeAny(&.{ "tbody", "thead", "tfoot" }, .table)) return;
                    p.clearStackToTableBodyContext();
                    _ = p.pop();
                    p.mode = .in_table;
                    return p.modeInTable(t);
                }
                if (inList(e.name, &.{ "body", "caption", "col", "colgroup", "html", "td", "th", "tr" })) return;
            },
            else => {},
        }
        try p.modeInTable(t);
    }

    fn modeInRow(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .start => |s| {
                if (eq(s.name, "th") or eq(s.name, "td")) {
                    p.clearStackToTableRowContext();
                    _ = try p.insertHtmlElement(s);
                    p.mode = .in_cell;
                    try p.pushMarker();
                    return;
                }
                if (inList(s.name, &.{ "caption", "col", "colgroup", "tbody", "tfoot", "thead", "tr" })) {
                    if (!p.inScope("tr", .table)) return;
                    p.clearStackToTableRowContext();
                    _ = p.pop();
                    p.mode = .in_table_body;
                    return p.modeInTableBody(t);
                }
            },
            .end => |e| {
                if (eq(e.name, "tr")) {
                    if (!p.inScope("tr", .table)) return;
                    p.clearStackToTableRowContext();
                    _ = p.pop();
                    p.mode = .in_table_body;
                    return;
                }
                if (eq(e.name, "table")) {
                    if (!p.inScope("tr", .table)) return;
                    p.clearStackToTableRowContext();
                    _ = p.pop();
                    p.mode = .in_table_body;
                    return p.modeInTableBody(t);
                }
                if (inList(e.name, &.{ "tbody", "tfoot", "thead" })) {
                    if (!p.inScope(e.name, .table)) return;
                    if (!p.inScope("tr", .table)) return;
                    p.clearStackToTableRowContext();
                    _ = p.pop();
                    p.mode = .in_table_body;
                    return p.modeInTableBody(t);
                }
                if (inList(e.name, &.{ "body", "caption", "col", "colgroup", "html", "td", "th" })) return;
            },
            else => {},
        }
        try p.modeInTable(t);
    }

    fn modeInCell(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .start => |s| if (inList(s.name, &.{ "caption", "col", "colgroup", "tbody", "td", "tfoot", "th", "thead", "tr" })) {
                if (!p.inScope("td", .table) and !p.inScope("th", .table)) return;
                p.closeCell();
                return p.modeInRow(t);
            },
            .end => |e| {
                if (eq(e.name, "td") or eq(e.name, "th")) {
                    if (!p.inScope(e.name, .table)) return;
                    p.generateImpliedEndTags(null);
                    p.popUntilHtml(e.name);
                    p.clearToMarker();
                    p.mode = .in_row;
                    return;
                }
                if (inList(e.name, &.{ "body", "caption", "col", "colgroup", "html" })) return;
                if (inList(e.name, &.{ "table", "tbody", "tfoot", "thead", "tr" })) {
                    if (!p.inScope(e.name, .table)) return;
                    p.closeCell();
                    return p.modeInRow(t);
                }
            },
            else => {},
        }
        try p.modeInBody(t);
    }

    fn closeCell(p: *Parser) void {
        p.generateImpliedEndTags(null);
        p.popUntilOneOf(&.{ "td", "th" });
        p.clearToMarker();
        p.mode = .in_row;
    }

    fn modeInTemplate(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws, .text, .nul, .comment, .doctype => return p.modeInBody(t),
            .start => |s| {
                const n = s.name;
                if (inList(n, &.{ "base", "basefont", "bgsound", "link", "meta", "noframes", "script", "style", "template", "title" })) return p.modeInHead(t);
                const next: Mode = if (inList(n, &.{ "caption", "colgroup", "tbody", "tfoot", "thead" })) .in_table else if (eq(n, "col")) .in_column_group else if (eq(n, "tr")) .in_table_body else if (eq(n, "td") or eq(n, "th")) .in_row else .in_body;
                _ = p.template_modes.pop();
                try p.template_modes.append(p.a, next);
                p.mode = next;
                return p.process(t, next);
            },
            .end => |e| {
                if (eq(e.name, "template")) return p.modeInHead(t);
                return;
            },
            .eof => {
                if (p.lastInOpen("template") == null) {
                    p.stopped = true;
                    return;
                }
                p.popUntilHtml("template");
                p.clearToMarker();
                _ = p.template_modes.pop();
                p.resetInsertionMode();
                return p.dispatch(t);
            },
        }
    }

    fn modeAfterBody(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => return p.modeInBody(t),
            .comment => |c| return p.insertComment(c, .{ .parent = p.open.items[0] }),
            .doctype => return,
            .start => |s| if (eq(s.name, "html")) return p.modeInBody(t),
            .end => |e| if (eq(e.name, "html")) {
                if (p.context != null) return;
                p.mode = .after_after_body;
                return;
            },
            .eof => {
                p.stopped = true;
                return;
            },
            else => {},
        }
        p.mode = .in_body;
        try p.modeInBody(t);
    }

    fn modeInFrameset(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => |w| return p.insertText(w),
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                if (eq(s.name, "html")) return p.modeInBody(t);
                if (eq(s.name, "frameset")) {
                    _ = try p.insertHtmlElement(s);
                    return;
                }
                if (eq(s.name, "frame")) {
                    _ = try p.insertHtmlElement(s);
                    _ = p.pop();
                    return;
                }
                if (eq(s.name, "noframes")) return p.modeInHead(t);
            },
            .end => |e| if (eq(e.name, "frameset")) {
                if (p.current() != null and p.doc.isHtml(p.current().?, "html")) return;
                _ = p.pop();
                if (p.context == null and p.current() != null and !p.doc.isHtml(p.current().?, "frameset")) p.mode = .after_frameset;
                return;
            },
            .eof => {
                p.stopped = true;
                return;
            },
            else => {},
        }
    }

    fn modeAfterFrameset(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .ws => |w| return p.insertText(w),
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                if (eq(s.name, "html")) return p.modeInBody(t);
                if (eq(s.name, "noframes")) return p.modeInHead(t);
            },
            .end => |e| if (eq(e.name, "html")) {
                p.mode = .after_after_frameset;
                return;
            },
            .eof => {
                p.stopped = true;
                return;
            },
            else => {},
        }
    }

    fn modeAfterAfterBody(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .comment => |c| return p.insertComment(c, .{ .parent = dom.document_id }),
            .doctype, .ws => return p.modeInBody(t),
            .start => |s| if (eq(s.name, "html")) return p.modeInBody(t),
            .eof => {
                p.stopped = true;
                return;
            },
            else => {},
        }
        p.mode = .in_body;
        try p.modeInBody(t);
    }

    fn modeAfterAfterFrameset(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .comment => |c| return p.insertComment(c, .{ .parent = dom.document_id }),
            .doctype, .ws => return p.modeInBody(t),
            .start => |s| {
                if (eq(s.name, "html")) return p.modeInBody(t);
                if (eq(s.name, "noframes")) return p.modeInHead(t);
            },
            .eof => {
                p.stopped = true;
                return;
            },
            else => {},
        }
    }

    // ------------------------------------------------ foreign content

    fn foreign(p: *Parser, t: Tok) Error!void {
        switch (t) {
            .nul => return p.insertText("\u{fffd}"),
            .ws => |w| return p.insertText(w),
            .text => |x| {
                try p.insertText(x);
                p.frameset_ok = false;
            },
            .comment => |c| return p.insertComment(c, null),
            .doctype => return,
            .start => |s| {
                const n = s.name;
                const breakout = inList(n, &.{ "b", "big", "blockquote", "body", "br", "center", "code", "dd", "div", "dl", "dt", "em", "embed", "h1", "h2", "h3", "h4", "h5", "h6", "head", "hr", "i", "img", "li", "listing", "menu", "meta", "nobr", "ol", "p", "pre", "ruby", "s", "small", "span", "strong", "strike", "sub", "sup", "table", "tt", "u", "ul", "var" }) or (eq(n, "font") and hasAnyAttr(s, &.{ "color", "face", "size" }));
                if (breakout) {
                    while (p.current()) |c| {
                        if (p.doc.get(c).namespace == .html or p.isMathmlTextIntegrationPoint(c) or p.isHtmlIntegrationPoint(c)) break;
                        _ = p.pop();
                    }
                    return p.process(t, p.mode);
                }
                const adj = p.adjustedCurrentNode().?;
                const ns = p.doc.get(adj).namespace;
                var tag = s;
                if (ns == .mathml) tag = try p.adjustMathmlAttrs(s);
                if (ns == .svg) {
                    tag = try p.adjustSvgAttrs(s);
                    tag.name = adjustSvgTagName(tag.name);
                }
                _ = try p.insertElement(tag, ns);
                if (s.self_closing) {
                    _ = p.pop();
                }
                return;
            },
            .end => |e| {
                const n = e.name;
                if (eq(n, "br") or eq(n, "p")) {
                    while (p.current()) |c| {
                        if (p.doc.get(c).namespace == .html or p.isMathmlTextIntegrationPoint(c) or p.isHtmlIntegrationPoint(c)) break;
                        _ = p.pop();
                    }
                    return p.process(t, p.mode);
                }
                // A script end tag in SVG would run the script; here it
                // pops like any other.
                var i = p.open.items.len - 1;
                var node = p.open.items[i];
                if (!std.ascii.eqlIgnoreCase(p.doc.get(node).name, n)) {
                    // parse error
                }
                while (true) {
                    if (i == 0) return;
                    if (std.ascii.eqlIgnoreCase(p.doc.get(node).name, n)) {
                        p.open.items.len = i;
                        return;
                    }
                    i -= 1;
                    node = p.open.items[i];
                    if (p.doc.get(node).namespace == .html) break;
                }
                try p.process(t, p.mode);
            },
            .eof => return p.process(t, p.mode),
        }
    }

    fn hasAnyAttr(s: Tag, names: []const []const u8) bool {
        for (s.attrs) |at| if (inList(at.name, names)) return true;
        return false;
    }

    fn adjustMathmlAttrs(p: *Parser, s: Tag) Error!Tag {
        const out = try p.a.dupe(tokenizer.Attr, s.attrs);
        for (out) |*at| {
            if (eq(at.name, "definitionurl")) at.name = "definitionURL";
            at.name = adjustForeignAttr(at.name);
        }
        return .{ .name = s.name, .attrs = out, .self_closing = s.self_closing };
    }

    fn adjustSvgAttrs(p: *Parser, s: Tag) Error!Tag {
        const out = try p.a.dupe(tokenizer.Attr, s.attrs);
        for (out) |*at| {
            at.name = adjustSvgAttrName(at.name);
            at.name = adjustForeignAttr(at.name);
        }
        return .{ .name = s.name, .attrs = out, .self_closing = s.self_closing };
    }

    /// Foreign attributes keep their prefix in the name until the
    /// element is made; the split happens there.
    fn adjustForeignAttr(name: []const u8) []const u8 {
        return name;
    }

    const foreign_prefixed = [_][]const u8{ "xlink:actuate", "xlink:arcrole", "xlink:href", "xlink:role", "xlink:show", "xlink:title", "xlink:type", "xml:lang", "xml:space", "xmlns:xlink" };

    /// Where the prefix ends for a name in the adjust-foreign-attributes
    /// table, else null.
    fn foreignAttrPrefix(name: []const u8) ?usize {
        if (!inList(name, &foreign_prefixed)) return null;
        return std.mem.indexOfScalar(u8, name, ':');
    }

    const svg_attr_names = [_][]const u8{ "attributeName", "attributeType", "baseFrequency", "baseProfile", "calcMode", "clipPathUnits", "diffuseConstant", "edgeMode", "filterUnits", "glyphRef", "gradientTransform", "gradientUnits", "kernelMatrix", "kernelUnitLength", "keyPoints", "keySplines", "keyTimes", "lengthAdjust", "limitingConeAngle", "markerHeight", "markerUnits", "markerWidth", "maskContentUnits", "maskUnits", "numOctaves", "pathLength", "patternContentUnits", "patternTransform", "patternUnits", "pointsAtX", "pointsAtY", "pointsAtZ", "preserveAlpha", "preserveAspectRatio", "primitiveUnits", "refX", "refY", "repeatCount", "repeatDur", "requiredExtensions", "requiredFeatures", "specularConstant", "specularExponent", "spreadMethod", "startOffset", "stdDeviation", "stitchTiles", "surfaceScale", "systemLanguage", "tableValues", "targetX", "targetY", "textLength", "viewBox", "viewTarget", "xChannelSelector", "yChannelSelector", "zoomAndPan" };
    const svg_tag_names = [_][]const u8{ "altGlyph", "altGlyphDef", "altGlyphItem", "animateColor", "animateMotion", "animateTransform", "clipPath", "feBlend", "feColorMatrix", "feComponentTransfer", "feComposite", "feConvolveMatrix", "feDiffuseLighting", "feDisplacementMap", "feDistantLight", "feDropShadow", "feFlood", "feFuncA", "feFuncB", "feFuncG", "feFuncR", "feGaussianBlur", "feImage", "feMerge", "feMergeNode", "feMorphology", "feOffset", "fePointLight", "feSpecularLighting", "feSpotLight", "feTile", "feTurbulence", "foreignObject", "glyphRef", "linearGradient", "radialGradient", "textPath" };

    fn adjustSvgAttrName(name: []const u8) []const u8 {
        for (svg_attr_names) |cased| if (std.ascii.eqlIgnoreCase(cased, name)) return cased;
        return name;
    }

    fn adjustSvgTagName(name: []const u8) []const u8 {
        for (svg_tag_names) |cased| if (std.ascii.eqlIgnoreCase(cased, name)) return cased;
        return name;
    }
};

// ------------------------------------------------------------- helpers

fn eq(x: []const u8, y: []const u8) bool {
    return std.mem.eql(u8, x, y);
}

fn inList(name: []const u8, list: []const []const u8) bool {
    for (list) |l| if (std.mem.eql(u8, name, l)) return true;
    return false;
}

// ----------------------------------------------------------- the API

/// Parse a whole document. Every node lives in `a`.
pub fn parse(a: std.mem.Allocator, input: []const u8, opts: Options) Error!*Document {
    const doc = try a.create(Document);
    doc.* = try Document.init(a);
    var p: Parser = .{ .a = a, .doc = doc, .tok = try tokenizer.Tokenizer.init(a, input), .scripting = opts.scripting };
    try p.run();
    try mirrorSelectedContent(doc);
    return doc;
}

/// A `selectedcontent` element shows a clone of its select's selected
/// option's contents (the first option with `selected`, else the first
/// option) — the standard's option insertion steps, applied once the
/// tree is complete.
fn mirrorSelectedContent(doc: *Document) Error!void {
    var i: NodeId = 1;
    while (i < doc.nodes.len) : (i += 1) {
        if (!doc.isHtml(i, "selectedcontent")) continue;
        var sel: ?NodeId = doc.get(i).parent;
        while (sel) |s| : (sel = doc.get(s).parent) if (doc.isHtml(s, "select")) break;
        const select = sel orelse continue;
        var chosen: ?NodeId = null;
        var first: ?NodeId = null;
        var w = doc.walk(select);
        while (w.next()) |el| {
            if (!doc.isHtml(el, "option")) continue;
            if (first == null) first = el;
            if (doc.hasAttr(el, "selected")) {
                chosen = el;
                break;
            }
        }
        const opt = chosen orelse first orelse continue;
        while (doc.node(i).first_child) |c| doc.detach(c);
        try cloneChildren(doc, opt, i);
    }
}

fn cloneChildren(doc: *Document, from: NodeId, to: NodeId) Error!void {
    var c = doc.get(from).first_child;
    while (c) |cid| : (c = doc.get(cid).next) {
        const src = doc.get(cid).*;
        const copy: NodeId = switch (src.kind) {
            .text => try doc.createText(src.text.items),
            .comment => try doc.createComment(src.text.items),
            .element => blk: {
                const e = try doc.createElement(src.namespace, src.name);
                for (src.attrs.items) |at| try doc.node(e).attrs.append(doc.a, at);
                break :blk e;
            },
            else => continue,
        };
        doc.appendChild(to, copy);
        if (src.kind == .element) try cloneChildren(doc, cid, copy);
    }
}

/// The fragment case: parse `input` as the children of an element
/// named `context_name` in `context_ns`; the result's children are the
/// fragment (under the document's `html` root element).
pub fn parseFragment(a: std.mem.Allocator, input: []const u8, context_name: []const u8, context_ns: dom.Namespace, opts: Options) Error!*Document {
    const doc = try a.create(Document);
    doc.* = try Document.init(a);
    var p: Parser = .{ .a = a, .doc = doc, .tok = try tokenizer.Tokenizer.init(a, input), .scripting = opts.scripting };
    const context = try doc.createElement(context_ns, context_name);
    if (context_ns == .html and eq(context_name, "template")) {
        const frag = try doc.createFragment();
        doc.node(context).template_contents = frag;
    }
    p.context = context;
    if (context_ns == .html) {
        if (eq(context_name, "title") or eq(context_name, "textarea")) {
            p.tok.state = .rcdata;
        } else if (inList(context_name, &.{ "style", "xmp", "iframe", "noembed", "noframes" })) {
            p.tok.state = .rawtext;
        } else if (eq(context_name, "script")) {
            p.tok.state = .script_data;
        } else if (eq(context_name, "noscript") and opts.scripting) {
            p.tok.state = .rawtext;
        } else if (eq(context_name, "plaintext")) {
            p.tok.state = .plaintext;
        }
    }
    const root = try doc.createElement(.html, "html");
    doc.appendChild(dom.document_id, root);
    try p.open.append(a, root);
    if (context_ns == .html and eq(context_name, "template")) try p.template_modes.append(a, .in_template);
    p.resetInsertionMode();
    p.tok.allow_cdata = context_ns != .html;
    try p.run();
    try mirrorSelectedContent(doc);
    return doc;
}

// ------------------------------------------------------- serialization

/// The tree in the html5lib corpus's notation, for the tests and for
/// looking at a parse: one line per node, `| ` and two spaces per level.
pub fn serializeForTest(a: std.mem.Allocator, doc: *const Document, root: NodeId) Error![]u8 {
    var out: std.ArrayList(u8) = .empty;
    var c = doc.get(root).first_child;
    while (c) |cid| : (c = doc.get(cid).next) try writeNode(a, doc, cid, 0, &out);
    return out.items;
}

fn writeNode(a: std.mem.Allocator, doc: *const Document, id: NodeId, depth: usize, out: *std.ArrayList(u8)) Error!void {
    const n = doc.get(id);
    try out.appendSlice(a, "| ");
    try out.appendNTimes(a, ' ', depth * 2);
    switch (n.kind) {
        .doctype => {
            try out.appendSlice(a, "<!DOCTYPE ");
            try out.appendSlice(a, n.name);
            if (n.public_id != null or n.system_id != null) {
                try out.print(a, " \"{s}\" \"{s}\"", .{ n.public_id orelse "", n.system_id orelse "" });
            }
            try out.appendSlice(a, ">\n");
        },
        .comment => try out.print(a, "<!-- {s} -->\n", .{n.text.items}),
        .text => try out.print(a, "\"{s}\"\n", .{n.text.items}),
        .element => {
            try out.append(a, '<');
            switch (n.namespace) {
                .html => {},
                .svg => try out.appendSlice(a, "svg "),
                .mathml => try out.appendSlice(a, "math "),
            }
            try out.appendSlice(a, n.name);
            try out.appendSlice(a, ">\n");
            const attrs = try a.dupe(dom.Attr, n.attrs.items);
            for (attrs) |*at| if (at.prefix) |pre| {
                at.name = try std.mem.concat(a, u8, &.{ pre, " ", at.name });
            };
            std.mem.sort(dom.Attr, attrs, {}, struct {
                fn f(_: void, x: dom.Attr, y: dom.Attr) bool {
                    return std.mem.order(u8, x.name, y.name) == .lt;
                }
            }.f);
            for (attrs) |at| {
                try out.appendSlice(a, "| ");
                try out.appendNTimes(a, ' ', depth * 2 + 2);
                try out.print(a, "{s}=\"{s}\"\n", .{ at.name, at.value });
            }
            if (n.template_contents) |tc| {
                try out.appendSlice(a, "| ");
                try out.appendNTimes(a, ' ', depth * 2 + 2);
                try out.appendSlice(a, "content\n");
                var c = doc.get(tc).first_child;
                while (c) |cid| : (c = doc.get(cid).next) try writeNode(a, doc, cid, depth + 2, out);
            }
            var c = n.first_child;
            while (c) |cid| : (c = doc.get(cid).next) try writeNode(a, doc, cid, depth + 1, out);
        },
        else => {},
    }
}

// ------------------------------------------------------------------ tests

test "html: a small document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a, "<!DOCTYPE html><title>T</title><p class=x>Hi <b>there<i>!</b>?</i>", .{});
    const s = try serializeForTest(a, doc, dom.document_id);
    try std.testing.expectEqualStrings(
        \\| <!DOCTYPE html>
        \\| <html>
        \\|   <head>
        \\|     <title>
        \\|       "T"
        \\|   <body>
        \\|     <p>
        \\|       class="x"
        \\|       "Hi "
        \\|       <b>
        \\|         "there"
        \\|         <i>
        \\|           "!"
        \\|       <i>
        \\|         "?"
        \\
    , s);
}

// The html5lib tree-construction corpus: every `.dat` file's tests,
// each parsed (as a document, or as a fragment in its context element,
// with scripting as the test says) and serialized in the corpus's own
// notation; the count printed.
const verbose = false;

test "html: the html5lib corpus, counted" {
    const io = std.testing.io;
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const dir_path = "tools/testdata/web/html5lib-tests/tree-construction";
    var dir = std.Io.Dir.cwd().openDir(io, dir_path, .{ .iterate = true }) catch return error.SkipZigTest;
    defer dir.close(io);
    var names: std.ArrayList([]const u8) = .empty;
    var it = dir.iterate();
    while (try it.next(io)) |entry| {
        if (entry.kind == .file and std.mem.endsWith(u8, entry.name, ".dat")) try names.append(a, try a.dupe(u8, entry.name));
    }
    std.mem.sort([]const u8, names.items, {}, struct {
        fn f(_: void, x: []const u8, y: []const u8) bool {
            return std.mem.order(u8, x, y) == .lt;
        }
    }.f);
    var total: usize = 0;
    var passed: usize = 0;
    for (names.items) |name| {
        const text = try dir.readFileAlloc(io, name, a, .limited(8 << 20));
        var blocks = std.mem.splitSequence(u8, text, "\n#data\n");
        var first = true;
        while (blocks.next()) |raw| {
            var block = raw;
            if (first) {
                first = false;
                if (!std.mem.startsWith(u8, block, "#data\n")) continue;
                block = block["#data\n".len..];
            }
            const tc = parseDat(block) orelse continue;
            total += 1;
            var ctx_name: []const u8 = "";
            var ctx_ns: dom.Namespace = .html;
            if (tc.fragment) |f| {
                if (std.mem.startsWith(u8, f, "svg ")) {
                    ctx_ns = .svg;
                    ctx_name = f[4..];
                } else if (std.mem.startsWith(u8, f, "math ")) {
                    ctx_ns = .mathml;
                    ctx_name = f[5..];
                } else ctx_name = f;
            }
            const opts: Options = .{ .scripting = tc.scripting };
            const doc = if (tc.fragment != null) try parseFragment(a, tc.input, ctx_name, ctx_ns, opts) else try parse(a, tc.input, opts);
            const root: NodeId = if (tc.fragment != null) doc.get(dom.document_id).first_child.? else dom.document_id;
            const got = try serializeForTest(a, doc, root);
            const got_trim = std.mem.trimEnd(u8, got, "\n");
            if (std.mem.eql(u8, got_trim, tc.expected)) passed += 1 else if (verbose) std.debug.print("--- {s}\n{s}\n=== got\n{s}\n=== want\n{s}\n", .{ name, tc.input, got_trim, tc.expected });
        }
    }
    std.debug.print("tree construction: {d}/{d} of the html5lib corpus agree\n", .{ passed, total });
    // The floor is the count as of 2026-09-18 (all of them); `verbose`
    // lists any that regress.
    try std.testing.expect(passed >= 1791);
}

const DatCase = struct { input: []const u8, fragment: ?[]const u8, scripting: bool, expected: []const u8 };

/// One `#data … #document …` block, already stripped of its `#data`
/// line. Sections come in a fixed order; the document runs to the end.
fn parseDat(block: []const u8) ?DatCase {
    const errors_at = std.mem.indexOf(u8, block, "\n#errors\n") orelse return null;
    const input = block[0..errors_at];
    var rest = block[errors_at + 1 ..];
    var fragment: ?[]const u8 = null;
    var scripting = false;
    const doc_at = std.mem.indexOf(u8, rest, "#document\n") orelse return null;
    const between = rest[0..doc_at];
    var lines = std.mem.splitScalar(u8, between, '\n');
    while (lines.next()) |line| {
        if (std.mem.eql(u8, line, "#script-on")) scripting = true;
        if (std.mem.eql(u8, line, "#document-fragment")) fragment = lines.next() orelse "";
    }
    rest = rest[doc_at + "#document\n".len ..];
    const expected = std.mem.trimEnd(u8, rest, "\n");
    return .{ .input = input, .fragment = fragment, .scripting = scripting, .expected = expected };
}

// ------------------------------------------------ serialization, as HTML

const void_elements = [_][]const u8{ "area", "base", "basefont", "bgsound", "br", "col", "embed", "frame", "hr", "img", "input", "keygen", "link", "meta", "param", "source", "track", "wbr" };
const raw_text_elements = [_][]const u8{ "style", "script", "xmp", "iframe", "noembed", "noframes", "plaintext" };

fn nameIn(name: []const u8, list: []const []const u8) bool {
    for (list) |n| if (std.mem.eql(u8, n, name)) return true;
    return false;
}

/// The children of `root` as HTML markup — the standard's "HTML
/// fragment serialization algorithm": void elements without an end
/// tag, raw text elements' text as it is, everything else's text with
/// `&`, `<`, `>` and no-break spaces escaped, attribute values with
/// `&`, `"` and no-break spaces. What a page domain hands its host
/// when asked for the document, and what the host parses back.
pub fn serialize(a: std.mem.Allocator, doc: *const Document, root: NodeId, out: *std.ArrayList(u8)) Error!void {
    var c = doc.get(root).first_child;
    while (c) |cid| : (c = doc.get(cid).next) try serializeNode(a, doc, cid, out);
}

/// An element with its own tags: its outer markup (an inline `<svg>`
/// handed to the SVG renderer as a document of its own).
pub fn serializeOuter(a: std.mem.Allocator, doc: *const Document, id: NodeId, out: *std.ArrayList(u8)) Error!void {
    try serializeNode(a, doc, id, out);
}

fn serializeNode(a: std.mem.Allocator, doc: *const Document, id: NodeId, out: *std.ArrayList(u8)) Error!void {
    const n = doc.get(id);
    switch (n.kind) {
        .doctype => {
            try out.appendSlice(a, "<!DOCTYPE ");
            try out.appendSlice(a, n.name);
            try out.append(a, '>');
        },
        .comment => {
            try out.appendSlice(a, "<!--");
            try out.appendSlice(a, n.text.items);
            try out.appendSlice(a, "-->");
        },
        .text => {
            const parent = if (n.parent) |p| doc.get(p) else null;
            if (parent != null and parent.?.kind == .element and parent.?.namespace == .html and nameIn(parent.?.name, &raw_text_elements)) {
                try out.appendSlice(a, n.text.items);
            } else try escapeText(a, n.text.items, false, out);
        },
        .element => {
            try out.append(a, '<');
            try out.appendSlice(a, n.name);
            for (n.attrs.items) |at| {
                try out.append(a, ' ');
                if (at.prefix) |pre| {
                    try out.appendSlice(a, pre);
                    try out.append(a, ':');
                }
                try out.appendSlice(a, at.name);
                try out.appendSlice(a, "=\"");
                try escapeText(a, at.value, true, out);
                try out.append(a, '"');
            }
            try out.append(a, '>');
            if (n.namespace == .html and nameIn(n.name, &void_elements)) return;
            const contents = if (n.template_contents) |tc| tc else id;
            var c = doc.get(contents).first_child;
            while (c) |cid| : (c = doc.get(cid).next) try serializeNode(a, doc, cid, out);
            try out.appendSlice(a, "</");
            try out.appendSlice(a, n.name);
            try out.append(a, '>');
        },
        else => {},
    }
}

fn escapeText(a: std.mem.Allocator, s: []const u8, attribute: bool, out: *std.ArrayList(u8)) Error!void {
    var i: usize = 0;
    while (i < s.len) : (i += 1) {
        const ch = s[i];
        if (ch == '&') {
            try out.appendSlice(a, "&amp;");
        } else if (ch == 0xc2 and i + 1 < s.len and s[i + 1] == 0xa0) {
            try out.appendSlice(a, "&nbsp;");
            i += 1;
        } else if (attribute and ch == '"') {
            try out.appendSlice(a, "&quot;");
        } else if (!attribute and ch == '<') {
            try out.appendSlice(a, "&lt;");
        } else if (!attribute and ch == '>') {
            try out.appendSlice(a, "&gt;");
        } else try out.append(a, ch);
    }
}

test "html: serialize round trips a small document" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const doc = try parse(a, "<!DOCTYPE html><title>T &amp; U</title><p class=\"x\">a<br>b &lt; c</p><style>a>b{}</style>", .{});
    var out: std.ArrayList(u8) = .empty;
    try serialize(a, doc, dom.document_id, &out);
    try std.testing.expectEqualStrings("<!DOCTYPE html><html><head><title>T &amp; U</title></head><body><p class=\"x\">a<br>b &lt; c</p><style>a>b{}</style></body></html>", out.items);
    const again = try parse(a, out.items, .{});
    var out2: std.ArrayList(u8) = .empty;
    try serialize(a, again, dom.document_id, &out2);
    try std.testing.expectEqualStrings(out.items, out2.items);
}
