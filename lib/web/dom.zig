//! The document tree the HTML parser builds and everything above it
//! reads: nodes in one arena-backed list addressed by index (no
//! pointers, no cycles — it serializes, and a subtree is a number), the
//! tree links as indices, an element's attributes as a list beside it,
//! text as a growable buffer the parser appends to. A `Document` owns
//! its nodes through the allocator it was given and frees nothing
//! piecemeal: the arena that made it drops it whole.
const std = @import("std");
const store = @import("store.zig");

pub const Error = error{OutOfMemory};

/// A node's index. Node 0 is always the document.
pub const NodeId = u32;
pub const document_id: NodeId = 0;

/// `other`: an element made by script in a namespace the parser never
/// produces (its URI is the node's `ns_uri`).
pub const Namespace = enum(u8) { html, svg, mathml, other };

/// Element state that is not an attribute: a checkbox or radio's
/// checkedness once the user or a script has set it (the `checked`
/// attribute is only the default until then).
/// `freed`: the slot was reclaimed (`sweep`) and waits in `free_ids`;
/// nothing reaches it until `add` hands it out again.
/// `owns_strings`: the node's name, attribute names and values and
/// namespace URI are its own allocations (a node a script made, or one
/// adopted from a fragment parse), freed with it; a parser's node shares
/// its strings with the token stream and static names.
pub const Flags = packed struct(u8) { checked_set: bool = false, checked: bool = false, freed: bool = false, owns_strings: bool = false, _pad: u4 = 0 };

pub const Kind = enum(u8) { document, doctype, element, text, comment, fragment };

pub const Attr = struct {
    name: []const u8,
    value: []const u8,
    /// A foreign attribute's prefix and namespace (`xlink:href` on an
    /// SVG element); null for the ordinary case.
    prefix: ?[]const u8 = null,
};

pub const QuirksMode = enum(u8) { no_quirks, limited_quirks, quirks };

pub const Node = struct {
    kind: Kind,
    parent: ?NodeId = null,
    first_child: ?NodeId = null,
    last_child: ?NodeId = null,
    prev: ?NodeId = null,
    next: ?NodeId = null,
    /// Elements: the local name (lowercased for HTML; as adjusted for
    /// foreign content). Doctypes: the name.
    name: []const u8 = "",
    namespace: Namespace = .html,
    attrs: std.ArrayList(Attr) = .empty,
    /// Text and comments: the data. Doctypes: unused.
    text: std.ArrayList(u8) = .empty,
    /// Doctypes only.
    public_id: ?[]const u8 = null,
    system_id: ?[]const u8 = null,
    /// Elements in the `other` namespace: its URI.
    ns_uri: ?[]const u8 = null,
    flags: Flags = .{},
    /// A `template` element's contents: a fragment node that is not one
    /// of the element's children.
    template_contents: ?NodeId = null,
};

pub const Document = struct {
    a: std.mem.Allocator,
    /// Chunked: an appended node never moves the others (`store`).
    nodes: store.Chunked(Node, 7) = .{},
    /// Slots a `sweep` reclaimed, for `add` to use again.
    free_ids: std.ArrayList(NodeId) = .empty,
    quirks: QuirksMode = .no_quirks,
    /// The interaction state a host keeps on the document for the
    /// selectors `:hover`, `:active` and `:focus`: the deepest element
    /// under the pointer, the one pressed, the one focused.
    hovered: ?NodeId = null,
    active: ?NodeId = null,
    focused: ?NodeId = null,

    pub fn init(a: std.mem.Allocator) Error!Document {
        var d: Document = .{ .a = a };
        _ = try d.add(.{ .kind = .document });
        return d;
    }

    pub fn node(d: *Document, id: NodeId) *Node {
        return d.nodes.at(id);
    }

    pub fn get(d: *const Document, id: NodeId) *const Node {
        return d.nodes.get(id);
    }

    fn add(d: *Document, n: Node) Error!NodeId {
        if (d.free_ids.pop()) |id| {
            d.nodes.at(id).* = n;
            return id;
        }
        try d.nodes.append(d.a, n);
        return @intCast(d.nodes.len - 1);
    }

    /// Set the bit of every node under `root` (`root` included), and of
    /// every template's contents met on the way.
    pub fn markTree(d: *const Document, root: NodeId, bits: []u8) void {
        // Every kind of node, the root first (`Walker.next` is elements
        // only, and `step` starts below the root).
        bits[root / 8] |= @as(u8, 1) << @intCast(root % 8);
        if (d.get(root).template_contents) |t| if (bits[t / 8] & (@as(u8, 1) << @intCast(t % 8)) == 0) d.markTree(t, bits);
        var w = d.walk(root);
        while (w.step()) |id| {
            bits[id / 8] |= @as(u8, 1) << @intCast(id % 8);
            if (d.get(id).template_contents) |t| if (bits[t / 8] & (@as(u8, 1) << @intCast(t % 8)) == 0) d.markTree(t, bits);
        }
    }

    /// Reclaim every node whose bit is not set: its text and attribute
    /// lists go back to the allocator, the slot waits in `free_ids`, and
    /// `on_freed` hears of it (a host drops what it kept by the id). The
    /// document node itself is never swept. Strings a node names (its
    /// name, an attribute's name and value) may be shared or static and
    /// are left alone.
    pub fn sweep(d: *Document, bits: []const u8, ctx: *anyopaque, on_freed: ?*const fn (ctx: *anyopaque, id: NodeId) void) usize {
        var freed: usize = 0;
        var id: NodeId = 1;
        while (id < d.nodes.len) : (id += 1) {
            if (bits[id / 8] & (@as(u8, 1) << @intCast(id % 8)) != 0) continue;
            const n = d.node(id);
            if (n.flags.freed) continue;
            if (n.flags.owns_strings) {
                if (n.kind == .element or n.kind == .doctype) d.a.free(n.name);
                for (n.attrs.items) |at| {
                    d.a.free(at.name);
                    d.a.free(at.value);
                }
                if (n.ns_uri) |u| d.a.free(u);
                if (n.public_id) |x| d.a.free(x);
                if (n.system_id) |x| d.a.free(x);
            }
            n.text.deinit(d.a);
            n.attrs.deinit(d.a);
            n.* = .{ .kind = .fragment, .flags = .{ .freed = true } };
            d.free_ids.append(d.a, id) catch {};
            if (on_freed) |f| f(ctx, id);
            freed += 1;
        }
        return freed;
    }

    pub fn createElement(d: *Document, ns: Namespace, name: []const u8) Error!NodeId {
        return d.add(.{ .kind = .element, .name = name, .namespace = ns });
    }

    pub fn createText(d: *Document, data: []const u8) Error!NodeId {
        const id = try d.add(.{ .kind = .text });
        try d.node(id).text.appendSlice(d.a, data);
        return id;
    }

    pub fn createComment(d: *Document, data: []const u8) Error!NodeId {
        const id = try d.add(.{ .kind = .comment });
        try d.node(id).text.appendSlice(d.a, data);
        return id;
    }

    pub fn createDoctype(d: *Document, name: []const u8, public_id: ?[]const u8, system_id: ?[]const u8) Error!NodeId {
        return d.add(.{ .kind = .doctype, .name = name, .public_id = public_id, .system_id = system_id });
    }

    pub fn createFragment(d: *Document) Error!NodeId {
        return d.add(.{ .kind = .fragment });
    }

    pub fn setAttr(d: *Document, id: NodeId, name: []const u8, value: []const u8) Error!void {
        const n = d.node(id);
        for (n.attrs.items) |*at| if (std.mem.eql(u8, at.name, name)) {
            // A node that owns its strings gives the old value back (a
            // style attribute set on every frame is the common churn).
            if (n.flags.owns_strings and at.value.ptr != value.ptr) d.a.free(at.value);
            at.value = value;
            return;
        };
        try n.attrs.append(d.a, .{ .name = name, .value = value });
    }

    pub fn getAttr(d: *const Document, id: NodeId, name: []const u8) ?[]const u8 {
        for (d.get(id).attrs.items) |at| if (std.mem.eql(u8, at.name, name)) return at.value;
        return null;
    }

    pub fn removeAttr(d: *Document, id: NodeId, name: []const u8) void {
        const n = d.node(id);
        for (n.attrs.items, 0..) |at, i| if (std.mem.eql(u8, at.name, name)) {
            _ = n.attrs.orderedRemove(i);
            return;
        };
    }

    pub fn hasAttr(d: *const Document, id: NodeId, name: []const u8) bool {
        return d.getAttr(id, name) != null;
    }

    /// Detach `id` from its parent (a no-op when it has none).
    pub fn detach(d: *Document, id: NodeId) void {
        const n = d.node(id);
        const p = n.parent orelse return;
        const parent = d.node(p);
        if (n.prev) |pv| d.node(pv).next = n.next else parent.first_child = n.next;
        if (n.next) |nx| d.node(nx).prev = n.prev else parent.last_child = n.prev;
        n.parent = null;
        n.prev = null;
        n.next = null;
    }

    pub fn appendChild(d: *Document, parent: NodeId, child: NodeId) void {
        d.detach(child);
        const p = d.node(parent);
        const c = d.node(child);
        c.parent = parent;
        c.prev = p.last_child;
        c.next = null;
        if (p.last_child) |l| d.node(l).next = child else p.first_child = child;
        p.last_child = child;
    }

    /// Insert `child` into `parent` before `before` (null: at the end).
    pub fn insertBefore(d: *Document, parent: NodeId, child: NodeId, before: ?NodeId) void {
        const b = before orelse return d.appendChild(parent, child);
        d.detach(child);
        const c = d.node(child);
        const bn = d.node(b);
        c.parent = parent;
        c.next = b;
        c.prev = bn.prev;
        if (bn.prev) |pv| d.node(pv).next = child else d.node(parent).first_child = child;
        bn.prev = child;
    }

    /// Move every child of `from` to the end of `to`, in order.
    pub fn reparentChildren(d: *Document, from: NodeId, to: NodeId) void {
        while (d.node(from).first_child) |c| d.appendChild(to, c);
    }

    pub fn isElement(d: *const Document, id: NodeId, ns: Namespace, name: []const u8) bool {
        const n = d.get(id);
        return n.kind == .element and n.namespace == ns and std.mem.eql(u8, n.name, name);
    }

    pub fn isHtml(d: *const Document, id: NodeId, name: []const u8) bool {
        return d.isElement(id, .html, name);
    }

    /// A checkbox or radio's checkedness: what the user or a script set,
    /// else the `checked` attribute (its default).
    pub fn isChecked(d: *const Document, id: NodeId) bool {
        const n = d.get(id);
        return if (n.flags.checked_set) n.flags.checked else d.hasAttr(id, "checked");
    }

    pub fn setChecked(d: *Document, id: NodeId, on: bool) void {
        const n = d.node(id);
        n.flags.checked_set = true;
        n.flags.checked = on;
    }

    pub fn childCount(d: *const Document, id: NodeId) usize {
        var n: usize = 0;
        var c = d.get(id).first_child;
        while (c) |cid| : (c = d.get(cid).next) n += 1;
        return n;
    }

    /// The concatenated text of a subtree (its descendant text nodes).
    pub fn textContent(d: *const Document, id: NodeId, a: std.mem.Allocator) Error![]u8 {
        var out: std.ArrayList(u8) = .empty;
        try d.appendText(id, a, &out);
        return out.items;
    }

    fn appendText(d: *const Document, id: NodeId, a: std.mem.Allocator, out: *std.ArrayList(u8)) Error!void {
        const n = d.get(id);
        if (n.kind == .text) return out.appendSlice(a, n.text.items);
        var c = n.first_child;
        while (c) |cid| : (c = d.get(cid).next) try d.appendText(cid, a, out);
    }

    /// The elements in document order under `root` (root excluded).
    pub const Walker = struct {
        d: *const Document,
        root: NodeId,
        cur: ?NodeId,

        pub fn next(w: *Walker) ?NodeId {
            while (true) {
                const id = w.step() orelse return null;
                if (w.d.get(id).kind == .element) return id;
            }
        }

        /// The next node in document order, any kind; template contents
        /// are not children and are not entered.
        pub fn step(w: *Walker) ?NodeId {
            const cur = w.cur orelse return null;
            const n = w.d.get(cur);
            if (n.first_child) |c| {
                w.cur = c;
                return c;
            }
            var up: ?NodeId = cur;
            while (up) |u| {
                if (u == w.root) break;
                const un = w.d.get(u);
                if (un.next) |nx| {
                    w.cur = nx;
                    return nx;
                }
                up = un.parent;
            }
            w.cur = null;
            return null;
        }
    };

    pub fn walk(d: *const Document, root: NodeId) Walker {
        return .{ .d = d, .root = root, .cur = root };
    }
};

test "dom: links, detach, and a walk in document order" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    var d = try Document.init(arena.allocator());
    const html = try d.createElement(.html, "html");
    d.appendChild(document_id, html);
    const body = try d.createElement(.html, "body");
    d.appendChild(html, body);
    const p1 = try d.createElement(.html, "p");
    const p2 = try d.createElement(.html, "p");
    d.appendChild(body, p1);
    d.appendChild(body, p2);
    const t = try d.createText("hi");
    d.appendChild(p1, t);
    try d.setAttr(p2, "id", "x");
    try std.testing.expectEqualStrings("x", d.getAttr(p2, "id").?);
    try std.testing.expectEqual(@as(usize, 2), d.childCount(body));
    const before = try d.createElement(.html, "b");
    d.insertBefore(body, before, p2);
    try std.testing.expectEqual(before, d.get(p2).prev.?);
    d.detach(p1);
    try std.testing.expectEqual(before, d.get(body).first_child.?);
    var w = d.walk(document_id);
    var names: [8][]const u8 = undefined;
    var n: usize = 0;
    while (w.next()) |id| : (n += 1) names[n] = d.get(id).name;
    try std.testing.expectEqual(@as(usize, 4), n);
    try std.testing.expectEqualStrings("html", names[0]);
    try std.testing.expectEqualStrings("b", names[2]);
    try std.testing.expectEqualStrings("p", names[3]);
    try std.testing.expectEqualStrings("", try d.textContent(document_id, arena.allocator()));
    try std.testing.expectEqualStrings("hi", try d.textContent(p1, arena.allocator()));
}
