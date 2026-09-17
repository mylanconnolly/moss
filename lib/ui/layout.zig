//! The tree layout engine: how a declarative view — rows, columns,
//! sections, splits, scroll viewports and leaves — measures and places
//! itself, as an algorithm over a *node interface* rather than over any
//! particular tree. The mshl runtime plugs in its record tree; a test
//! plugs in a struct tree and asserts placements. Nothing here knows a
//! record key, a pixel or a font: leaves report their size for a width
//! and paint themselves when asked, through the tree.
//!
//! The same code runs the measuring pass and the painting pass, so the
//! two can never disagree: a paint pass returns exactly the size the
//! measure pass predicted.
//!
//! The `Tree` a program supplies is a type with (all `pub`):
//!   const Node = …;                          // a node handle (copyable)
//!   fn kind(t: *Tree, n: Node) Kind;
//!   fn children(t: *Tree, n: Node) []const Node;
//!   fn gap(t: *Tree, n: Node) usize;          // between siblings
//!   fn flex(t: *Tree, n: Node) usize;         // row track weight, 0 = natural width
//!   fn alignTop(t: *Tree, n: Node) bool;      // a row's children sit on its top edge, not centred
//!   fn grow(t: *Tree, n: Node) usize;         // a column child's share of spare height, 0 = natural
//!   fn scrollHeight(t: *Tree, n: Node) usize; // a scroll viewport's height
//!   fn scrollChild(t: *Tree, n: Node) ?Node;
//!   fn splitLeft(t: *Tree, n: Node) ?Node;    fn splitRight(t: *Tree, n: Node) ?Node;
//!   fn splitLeftWidth(t: *Tree, n: Node) usize;
//!   fn leafMeasure(t: *Tree, n: Node, avail_w: usize, avail_h: usize) Size;
//!   fn leafPaint(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size;
//!   fn childPaint(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size;
//!       // paint a child: clip to its allocation, then call Engine.paint
//!
//! Heights flow down as an *offer*: `avail_h` is the height a node may
//! take, 0 meaning "your natural height". A column keeps its fixed
//! children natural and splits what is left of its offer among the
//! children that `grow`; rows and splits hand their offer through; a
//! leaf that grows (a list, a chart) stretches to the offer. A window
//! sizes itself with no offer, then paints with its content height, so
//! a maximized window's table grows into the room instead of scrolling.
//!   fn viewportPaint(t: *Tree, n: Node, child: Node, x: usize, y: usize, w: usize, h: usize) Size;
//!   fn sectionBegin(t: *Tree, x: usize, y: usize, w: usize, h: usize) void; // the panel
//!   fn sectionEnd(t: *Tree) void;
//!   fn dividerPaint(t: *Tree, x: usize, y: usize, h: usize) void;          // a split's rule
const std = @import("std");
const geometry = @import("geometry.zig");
const Size = geometry.Size;
const space = geometry.space;
const flow = @import("flow.zig");

pub const Kind = enum { none, row, column, section, scroll, split, leaf };

/// A section's inner inset (clamped to half the width).
pub const section_inset: usize = space.large;
/// A split's rule: a hairline plus breathing room each side.
pub const split_gap: usize = space.medium;
/// Below this much room for the right pane, a split stacks its panes.
pub const split_min_right: usize = 160;
/// A split's left pane is never narrower than this.
pub const split_min_left: usize = 80;

pub fn Engine(comptime Tree: type) type {
    return struct {
        const Node = Tree.Node;

        pub fn measure(t: *Tree, n: Node, avail_w: usize, avail_h: usize) Size {
            return layout(t, n, 0, 0, avail_w, avail_h, false);
        }
        pub fn paint(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
            return layout(t, n, x, y, avail_w, avail_h, true);
        }

        /// The row's two modes: with any flex child and room for the
        /// fixed ones, proportional tracks on one line; otherwise a
        /// greedy wrapping flow. Children centre vertically on their line
        /// unless the row is top-aligned (two panels of unequal height
        /// side by side read better sharing a top edge).
        fn row(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize, do_paint: bool) Size {
            const children = t.children(n);
            const g = t.gap(n);
            const top = t.alignTop(n);
            var total: usize = 0;
            var fixed: usize = g * (children.len -| 1);
            for (children) |child| {
                const weight = t.flex(child);
                total += weight;
                if (weight == 0) fixed += layout(t, child, 0, 0, avail_w, avail_h, false).w;
            }
            if (total > 0 and fixed < avail_w) {
                var before: usize = 0;
                var height: usize = 0;
                for (children) |child| {
                    const weight = t.flex(child);
                    const width = if (weight == 0) layout(t, child, 0, 0, avail_w, avail_h, false).w else flow.trackWidth(avail_w - fixed, total, before, weight);
                    height = @max(height, layout(t, child, 0, 0, width, avail_h, false).h);
                    before += weight;
                }
                before = 0;
                var xx = x;
                for (children) |child| {
                    const weight = t.flex(child);
                    const width = if (weight == 0) layout(t, child, 0, 0, avail_w, avail_h, false).w else flow.trackWidth(avail_w - fixed, total, before, weight);
                    const size = layout(t, child, 0, 0, width, avail_h, false);
                    if (do_paint) _ = t.childPaint(child, xx, if (top) y else y + (height - size.h) / 2, width, avail_h);
                    xx += width + g;
                    before += weight;
                }
                return .{ .w = avail_w, .h = height };
            }
            var line = flow.Flow{ .width = avail_w, .gap = g };
            var row_h: usize = 0;
            for (children) |child| row_h = @max(row_h, layout(t, child, 0, 0, avail_w, avail_h, false).h);
            for (children) |child| {
                const sz = layout(t, child, 0, 0, avail_w, avail_h, false);
                const place = line.put(.{ .w = sz.w, .h = row_h });
                if (do_paint) _ = t.childPaint(child, x + place.x, if (top) y + place.y else y + place.y + (row_h - sz.h) / 2, place.w, avail_h);
            }
            return line.size();
        }

        /// A column stacks its children with the gap between; a section
        /// is a column inset inside a panel.
        fn column(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize, do_paint: bool, section: bool) Size {
            const children = t.children(n);
            const g = t.gap(n);
            const inset: usize = if (section) @min(section_inset, avail_w / 2) else 0;
            const width = avail_w - 2 * inset;
            // Natural heights first; the growing children share what is
            // left of the offer, proportionally, and never shrink below
            // their natural height.
            var fixed: usize = g * (children.len -| 1);
            var grow_total: usize = 0;
            for (children) |child| {
                const weight = t.grow(child);
                if (weight == 0) fixed += layout(t, child, 0, 0, width, 0, false).h else grow_total += weight;
            }
            const offer = avail_h -| 2 * inset;
            const spare = if (grow_total > 0 and offer > fixed) offer - fixed else 0;
            var height: usize = 0;
            var before: usize = 0;
            for (children, 0..) |child, i| {
                if (i > 0) height += g;
                const weight = t.grow(child);
                const share = if (weight == 0) 0 else flow.trackWidth(spare, grow_total, before, weight);
                height += layout(t, child, 0, 0, width, share, false).h;
                before += weight;
            }
            if (do_paint) {
                if (section) t.sectionBegin(x, y, avail_w, height + 2 * inset);
                defer if (section) t.sectionEnd();
                var yy = y + inset;
                before = 0;
                for (children, 0..) |child, i| {
                    if (i > 0) yy += g;
                    const weight = t.grow(child);
                    const share = if (weight == 0) 0 else flow.trackWidth(spare, grow_total, before, weight);
                    yy += t.childPaint(child, x + inset, yy, width, share).h;
                    before += weight;
                }
            }
            return .{ .w = avail_w, .h = height + 2 * inset };
        }

        /// A fixed-width left pane, a rule, and a right pane filling the
        /// rest — or, when the right pane would be too narrow, the two
        /// stacked.
        fn split(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize, do_paint: bool) Size {
            const left = t.splitLeft(n);
            const right = t.splitRight(n);
            const left_w = @min(avail_w, @max(t.splitLeftWidth(n), split_min_left));
            if (avail_w < left_w + split_gap + split_min_right) {
                const l = if (left) |v| (if (do_paint) t.childPaint(v, x, y, avail_w, 0) else layout(t, v, 0, 0, avail_w, 0, false)) else Size{};
                const r = if (right) |v| (if (do_paint) t.childPaint(v, x, y + l.h + split_gap, avail_w, 0) else layout(t, v, 0, 0, avail_w, 0, false)) else Size{};
                return .{ .w = avail_w, .h = l.h + split_gap + r.h };
            }
            const div = 1 + split_gap;
            const rw = avail_w -| (left_w + div);
            const l = if (left) |v| (if (do_paint) t.childPaint(v, x, y, left_w, avail_h) else layout(t, v, 0, 0, left_w, avail_h, false)) else Size{};
            const r = if (right) |v| (if (do_paint) t.childPaint(v, x + left_w + div, y, rw, avail_h) else layout(t, v, 0, 0, rw, avail_h, false)) else Size{};
            const h = @max(l.h, r.h);
            if (do_paint) t.dividerPaint(x + left_w + split_gap / 2, y, h);
            return .{ .w = avail_w, .h = h };
        }

        fn layout(t: *Tree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize, do_paint: bool) Size {
            return switch (t.kind(n)) {
                .none => .{},
                .row => row(t, n, x, y, avail_w, avail_h, do_paint),
                .column => column(t, n, x, y, avail_w, avail_h, do_paint, false),
                .section => column(t, n, x, y, avail_w, avail_h, do_paint, true),
                .scroll => blk: {
                    const h = t.scrollHeight(n);
                    if (!do_paint) break :blk .{ .w = avail_w, .h = h };
                    const child = t.scrollChild(n) orelse break :blk .{};
                    break :blk t.viewportPaint(n, child, x, y, avail_w, h);
                },
                .split => split(t, n, x, y, avail_w, avail_h, do_paint),
                .leaf => if (do_paint) t.leafPaint(n, x, y, avail_w, avail_h) else t.leafMeasure(n, avail_w, avail_h),
            };
        }
    };
}

// ------------------------------------------------------------------ tests

const TestNode = struct {
    kind: Kind = .leaf,
    w: usize = 0,
    h: usize = 0,
    gap: usize = 0,
    flex: usize = 0,
    top: bool = false,
    grow: usize = 0,
    children: []const *const TestNode = &.{},
    scroll_h: usize = 0,
    left: ?*const TestNode = null,
    right: ?*const TestNode = null,
    left_w: usize = 0,
};
const Paint = struct { node: *const TestNode, x: usize, y: usize, w: usize };
const TestTree = struct {
    pub const Node = *const TestNode;
    paints: [32]Paint = undefined,
    n: usize = 0,
    sections: [8][4]usize = undefined,
    nsections: usize = 0,
    dividers: usize = 0,
    viewports: usize = 0,
    const Eng = Engine(TestTree);
    fn kind(_: *TestTree, n: Node) Kind {
        return n.kind;
    }
    fn children(_: *TestTree, n: Node) []const Node {
        return n.children;
    }
    fn alignTop(_: *TestTree, n: Node) bool {
        return n.top;
    }
    fn grow(_: *TestTree, n: Node) usize {
        return n.grow;
    }
    fn gap(_: *TestTree, n: Node) usize {
        return n.gap;
    }
    fn flex(_: *TestTree, n: Node) usize {
        return n.flex;
    }
    fn scrollHeight(_: *TestTree, n: Node) usize {
        return n.scroll_h;
    }
    fn scrollChild(_: *TestTree, n: Node) ?Node {
        return if (n.children.len > 0) n.children[0] else null;
    }
    fn splitLeft(_: *TestTree, n: Node) ?Node {
        return n.left;
    }
    fn splitRight(_: *TestTree, n: Node) ?Node {
        return n.right;
    }
    fn splitLeftWidth(_: *TestTree, n: Node) usize {
        return n.left_w;
    }
    fn leafMeasure(_: *TestTree, n: Node, avail_w: usize, avail_h: usize) Size {
        return .{ .w = @min(n.w, avail_w), .h = if (n.grow > 0) @max(n.h, avail_h) else n.h };
    }
    fn leafPaint(t: *TestTree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
        t.paints[t.n] = .{ .node = n, .x = x, .y = y, .w = avail_w };
        t.n += 1;
        return .{ .w = @min(n.w, avail_w), .h = if (n.grow > 0) @max(n.h, avail_h) else n.h };
    }
    fn childPaint(t: *TestTree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
        return Eng.paint(t, n, x, y, avail_w, avail_h);
    }
    fn viewportPaint(t: *TestTree, _: Node, child: Node, x: usize, y: usize, w: usize, h: usize) Size {
        t.viewports += 1;
        _ = Eng.paint(t, child, x, y, w, h);
        return .{ .w = w, .h = h };
    }
    fn sectionBegin(t: *TestTree, x: usize, y: usize, w: usize, h: usize) void {
        t.sections[t.nsections] = .{ x, y, w, h };
        t.nsections += 1;
    }
    fn sectionEnd(_: *TestTree) void {}
    fn dividerPaint(t: *TestTree, _: usize, _: usize, _: usize) void {
        t.dividers += 1;
    }
};
const E = Engine(TestTree);

test "a row wraps into lines of uniform height and centres children on them" {
    const a: TestNode = .{ .w = 60, .h = 20 };
    const b: TestNode = .{ .w = 50, .h = 30 };
    const c: TestNode = .{ .w = 40, .h = 10 };
    const r: TestNode = .{ .kind = .row, .gap = 10, .children = &.{ &a, &b, &c } };
    var t: TestTree = .{};
    // a+b fill line 1, c wraps; every line is as tall as the tallest child (30).
    try std.testing.expectEqual(Size{ .w = 120, .h = 70 }, E.measure(&t, &r, 120, 0));
    try std.testing.expectEqual(Size{ .w = 120, .h = 70 }, E.paint(&t, &r, 0, 100, 120, 0));
    try std.testing.expectEqual(@as(usize, 3), t.n);
    try std.testing.expectEqual(@as(usize, 105), t.paints[0].y); // a centred on the 30-tall line
    try std.testing.expectEqual(@as(usize, 70), t.paints[1].x);
    try std.testing.expectEqual(@as(usize, 150), t.paints[2].y); // c on line 2 (100 + 30 + gap 10), centred on its 30-tall line
}

test "flex children share the width left by fixed ones without drift" {
    const fixed: TestNode = .{ .w = 40, .h = 10 };
    const f1: TestNode = .{ .w = 10, .h = 12, .flex = 1 };
    const f2: TestNode = .{ .w = 10, .h = 8, .flex = 2 };
    const r: TestNode = .{ .kind = .row, .gap = 5, .children = &.{ &fixed, &f1, &f2 } };
    var t: TestTree = .{};
    try std.testing.expectEqual(Size{ .w = 200, .h = 12 }, E.measure(&t, &r, 200, 0));
    _ = E.paint(&t, &r, 0, 0, 200, 0);
    try std.testing.expectEqual(@as(usize, 40), t.paints[0].w);
    try std.testing.expectEqual(@as(usize, 150), t.paints[1].w + t.paints[2].w); // 200 - 40 - 2 gaps
    try std.testing.expect(t.paints[2].w > t.paints[1].w);
    try std.testing.expectEqual(@as(usize, 45), t.paints[1].x);
    // Too narrow for the fixed children: the row falls back to wrapping.
    try std.testing.expect(E.measure(&t, &r, 30, 0).h > 12);
}

test "columns stack with gaps and sections inset inside a panel" {
    const a: TestNode = .{ .w = 30, .h = 10 };
    const b: TestNode = .{ .w = 30, .h = 20 };
    const col: TestNode = .{ .kind = .column, .gap = 4, .children = &.{ &a, &b } };
    const sec: TestNode = .{ .kind = .section, .gap = 4, .children = &.{ &a, &b } };
    var t: TestTree = .{};
    try std.testing.expectEqual(Size{ .w = 100, .h = 34 }, E.measure(&t, &col, 100, 0));
    try std.testing.expectEqual(Size{ .w = 100, .h = 34 + 2 * section_inset }, E.measure(&t, &sec, 100, 0));
    _ = E.paint(&t, &sec, 10, 10, 100, 0);
    try std.testing.expectEqual(@as(usize, 1), t.nsections);
    try std.testing.expectEqual([4]usize{ 10, 10, 100, 34 + 2 * section_inset }, t.sections[0]);
    try std.testing.expectEqual(@as(usize, 10 + section_inset), t.paints[0].x);
    try std.testing.expectEqual(@as(usize, 10 + section_inset + 10 + 4), t.paints[1].y);
    try std.testing.expectEqual(@as(usize, 100 - 2 * section_inset), t.paints[1].w);
    // A section narrower than two insets halves the inset rather than underflowing.
    try std.testing.expectEqual(Size{ .w = 20, .h = 34 + 20 }, E.measure(&t, &sec, 20, 0));
}

test "a split stacks when the right pane would be too narrow and rules otherwise" {
    const l: TestNode = .{ .w = 500, .h = 50 };
    const r: TestNode = .{ .w = 500, .h = 80 };
    const s: TestNode = .{ .kind = .split, .left = &l, .right = &r, .left_w = 200 };
    var t: TestTree = .{};
    try std.testing.expectEqual(Size{ .w = 600, .h = 80 }, E.measure(&t, &s, 600, 0));
    _ = E.paint(&t, &s, 0, 0, 600, 0);
    try std.testing.expectEqual(@as(usize, 200), t.paints[0].w);
    try std.testing.expectEqual(@as(usize, 200 + 1 + split_gap), t.paints[1].x);
    try std.testing.expectEqual(@as(usize, 600 - 200 - 1 - split_gap), t.paints[1].w);
    try std.testing.expectEqual(@as(usize, 1), t.dividers);
    var narrow: TestTree = .{};
    try std.testing.expectEqual(Size{ .w = 300, .h = 50 + split_gap + 80 }, E.measure(&narrow, &s, 300, 0));
    _ = E.paint(&narrow, &s, 0, 0, 300, 0);
    try std.testing.expectEqual(@as(usize, 0), narrow.dividers);
    try std.testing.expectEqual(@as(usize, 50 + split_gap), narrow.paints[1].y);
}

test "a scroll node measures as its viewport and paints through the tree" {
    const tall: TestNode = .{ .w = 100, .h = 900 };
    const sc: TestNode = .{ .kind = .scroll, .scroll_h = 240, .children = &.{&tall} };
    var t: TestTree = .{};
    try std.testing.expectEqual(Size{ .w = 300, .h = 240 }, E.measure(&t, &sc, 300, 0));
    try std.testing.expectEqual(Size{ .w = 300, .h = 240 }, E.paint(&t, &sc, 0, 0, 300, 0));
    try std.testing.expectEqual(@as(usize, 1), t.viewports);
    try std.testing.expectEqual(@as(usize, 1), t.n);
}

test "measure and paint agree on a nested tree" {
    const a: TestNode = .{ .w = 80, .h = 20 };
    const b: TestNode = .{ .w = 80, .h = 20, .flex = 1 };
    const inner: TestNode = .{ .kind = .row, .gap = 8, .children = &.{ &a, &b, &a } };
    const outer: TestNode = .{ .kind = .column, .gap = 6, .children = &.{ &inner, &a, &inner } };
    var t: TestTree = .{};
    for ([_]usize{ 50, 120, 300, 1000 }) |w| {
        const m = E.measure(&t, &outer, w, 0);
        const p = E.paint(&t, &outer, 7, 9, w, 0);
        try std.testing.expectEqual(m, p);
    }
}

test "a top-aligned row keeps unequal children on one top edge" {
    const a = TestNode{ .w = 40, .h = 30 };
    const b = TestNode{ .w = 40, .h = 10, .flex = 1 };
    const r = TestNode{ .kind = .row, .top = true, .children = &.{ &a, &b } };
    var t = TestTree{};
    const size = TestTree.Eng.paint(&t, &r, 0, 100, 200, 0);
    try std.testing.expectEqual(@as(usize, 30), size.h);
    try std.testing.expectEqual(@as(usize, 100), t.paints[0].y);
    try std.testing.expectEqual(@as(usize, 100), t.paints[1].y); // not centred at 110
}

test "a column offers its spare height to the children that grow" {
    const a = TestNode{ .w = 40, .h = 30 };
    const b = TestNode{ .w = 40, .h = 50, .grow = 1 };
    const c = TestNode{ .w = 40, .h = 20 };
    const col = TestNode{ .kind = .column, .gap = 10, .children = &.{ &a, &b, &c } };
    var t = TestTree{};
    // No offer: natural heights, 30 + 10 + 50 + 10 + 20.
    try std.testing.expectEqual(@as(usize, 120), TestTree.Eng.measure(&t, &col, 200, 0).h);
    // An offer of 300: b takes what is left, 300 - (30 + 20 + 20 gaps) = 230.
    const size = TestTree.Eng.paint(&t, &col, 0, 0, 200, 300);
    try std.testing.expectEqual(@as(usize, 300), size.h);
    try std.testing.expectEqual(@as(usize, 40), t.paints[1].y);
    try std.testing.expectEqual(@as(usize, 40 + 230 + 10), t.paints[2].y);
    // An offer smaller than the natural height changes nothing.
    try std.testing.expectEqual(@as(usize, 120), TestTree.Eng.measure(&t, &col, 200, 100).h);
}
