//! CSS transitions and animations, as the page host drives them: a
//! pure engine over computed styles. After every restyle the host
//! hands it the new styles beside a snapshot of the old ones; a
//! transitionable property that changed on an element with a
//! `transition` starts (or retargets) a transition from the value it
//! was showing, and an element whose `animation-name` names a
//! `@keyframes` starts an animation. At each frame the host asks for
//! the running values: the engine interpolates (`style.interpolate`)
//! and writes the overrides into the styles — fresh computed values in
//! the frame's arena — and says whether another frame is due. The
//! engine keeps its ends in copies of its own (`Computed` is a flat
//! struct whose slices live in the document's arenas; a transition's
//! ends outlive a restyle, so they are copied here), in fixed slots: a
//! page animates a bounded number of elements at once.
const std = @import("std");
const dom = @import("dom.zig");
const style = @import("style.zig");
const Computed = style.Computed;
const NodeId = dom.NodeId;

pub const max_transitions = 48;
pub const max_animations = 24;
pub const max_snapshot = 64;
/// A frame's length when something runs.
pub const frame_ms: f64 = 16;

const Transition = struct {
    node: NodeId = 0,
    prop: style.Prop = .color,
    from: Computed = .{},
    to: Computed = .{},
    start_ms: f64 = 0,
    duration_ms: f64 = 0,
    timing: style.TimingFn = .ease,

    fn progress(t: *const Transition, now_ms: f64) f64 {
        if (t.duration_ms <= 0) return 1;
        return @max(0, @min(1, (now_ms - t.start_ms) / t.duration_ms));
    }
};

const Animation = struct {
    node: NodeId = 0,
    name: []const u8 = "",
    start_ms: f64 = 0,
    spec: Computed = .{},
    /// The element's base style at the last restyle (the frames apply
    /// over it).
    base: Computed = .{},
    done: bool = false,
};

const Snap = struct { node: NodeId, computed: Computed };

pub const Engine = struct {
    // The slots are `undefined` with their `used` flags beside them: a
    // slot's defaults are not zero (a computed style's never are), and
    // 400 KB of them in the data segment took the page image past its
    // staging buffer (2026-10-07). An unused slot is never read.
    transitions: [max_transitions]Transition = undefined,
    t_used: [max_transitions]bool = @splat(false),
    animations: [max_animations]Animation = undefined,
    a_used: [max_animations]bool = @splat(false),
    /// What the elements with transitions looked like before the restyle.
    snap: [max_snapshot]Snap = undefined,
    n_snap: usize = 0,

    /// Before a restyle: remember the computed style of every element
    /// that declares transitions, so the restyle's result can be held
    /// against it.
    pub fn snapshot(e: *Engine, doc: *const dom.Document, styles: *const style.Styles) void {
        e.n_snap = 0;
        // The tree, not the node ids: an element a script made and never
        // inserted has no computed style (its slot is undefined).
        var w = doc.walk(dom.document_id);
        while (w.next()) |id| {
            if (id >= styles.computed.len or doc.get(id).kind != .element) continue;
            const c = styles.get(id);
            if (!hasTransitions(c)) continue;
            if (e.n_snap == max_snapshot) break;
            e.snap[e.n_snap] = .{ .node = id, .computed = c.* };
            e.n_snap += 1;
        }
    }

    fn hasTransitions(c: *const Computed) bool {
        if (c.transition_none) return false;
        for (c.transition_duration) |d| if (d > 0) return true;
        return false;
    }

    fn snapOf(e: *Engine, id: NodeId) ?*const Computed {
        for (e.snap[0..e.n_snap]) |*s| if (s.node == id) return &s.computed;
        return null;
    }

    /// After a restyle (the styles are the cascade's, not yet animated):
    /// start transitions for what changed, and animations for what names
    /// keyframes. The snapshot is consumed.
    pub fn onRestyle(e: *Engine, a: std.mem.Allocator, doc: *const dom.Document, sheets: []const style.Sheet, styles: *const style.Styles, now_ms: f64) void {
        var w = doc.walk(dom.document_id);
        while (w.next()) |id| {
            if (id >= styles.computed.len or doc.get(id).kind != .element) continue;
            const c = styles.get(id);
            if (hasTransitions(c)) if (e.snapOf(id)) |old| e.startTransitions(a, id, old, c, now_ms);
            e.syncAnimation(id, sheets, c, now_ms);
        }
        // An element gone from the document ends its runs.
        for (e.transitions[0..], 0..) |*t, i| if (e.t_used[i] and !attached(doc, t.node)) {
            e.t_used[i] = false;
        };
        for (e.animations[0..], 0..) |*an, i| if (e.a_used[i] and !attached(doc, an.node)) {
            e.a_used[i] = false;
        };
        e.n_snap = 0;
    }

    /// The properties a transition can carry, held against each other.
    const transitionable = [_]style.Prop{ .width, .height, .min_width, .min_height, .max_width, .max_height, .margin_top, .margin_right, .margin_bottom, .margin_left, .padding_top, .padding_right, .padding_bottom, .padding_left, .border_top_width, .border_right_width, .border_bottom_width, .border_left_width, .top, .right, .bottom, .left, .color, .background_color, .border_top_color, .border_right_color, .border_bottom_color, .border_left_color, .font_size, .opacity, .transform, .line_height, .border_top_left_radius, .border_top_right_radius, .border_bottom_right_radius, .border_bottom_left_radius, .flex_grow, .flex_shrink, .z_index };

    fn startTransitions(e: *Engine, a: std.mem.Allocator, id: NodeId, old: *const Computed, new: *const Computed, now_ms: f64) void {
        for (transitionable) |prop| {
            if (propEql(old, new, prop)) continue;
            const spec = transitionFor(new, prop) orelse continue;
            if (spec.duration <= 0) continue;
            // The value shown now is where it starts from: a transition
            // already running is retargeted from its current value.
            var from = old.*;
            if (e.transitionOf(id, prop)) |ti| {
                const t = &e.transitions[ti];
                if (style.interpolate(a, &t.from, &t.to, t.timing.at(t.progress(now_ms)))) |cur| {
                    style.copyProp(&from, &cur, prop);
                } else |_| {}
                e.t_used[ti] = false;
            }
            if (propEql(&from, new, prop)) continue;
            const si = e.freeTransition() orelse return;
            e.transitions[si] = .{ .node = id, .prop = prop, .from = from, .to = new.*, .start_ms = now_ms + spec.delay, .duration_ms = spec.duration, .timing = spec.timing };
            e.t_used[si] = true;
        }
    }

    fn freeTransition(e: *Engine) ?usize {
        for (e.t_used, 0..) |u, i| if (!u) return i;
        return null;
    }

    fn transitionOf(e: *Engine, id: NodeId, prop: style.Prop) ?usize {
        for (e.transitions[0..], 0..) |*t, i| if (e.t_used[i] and t.node == id and t.prop == prop) return i;
        return null;
    }

    const Spec = struct { duration: f64, delay: f64, timing: style.TimingFn };

    /// The transition an element declares for a property: the entry
    /// naming it, else an `all`, each taking the duration, delay and
    /// timing at its index (the lists repeating).
    fn transitionFor(c: *const Computed, prop: style.Prop) ?Spec {
        if (c.transition_none) return null;
        var idx: ?usize = null;
        if (c.transition_property.len == 0) {
            idx = 0;
        } else for (c.transition_property, 0..) |p, i| {
            if (p == null or p.? == prop or shorthandCovers(p.?, prop)) idx = i;
        }
        const i = idx orelse return null;
        const dur = if (c.transition_duration.len > 0) c.transition_duration[i % c.transition_duration.len] else 0;
        const delay = if (c.transition_delay.len > 0) c.transition_delay[i % c.transition_delay.len] else 0;
        const timing = if (c.transition_timing.len > 0) c.transition_timing[i % c.transition_timing.len] else .ease;
        return .{ .duration = dur, .delay = delay, .timing = timing };
    }

    /// `transition-property: margin` covers `margin-top` and the rest.
    fn shorthandCovers(named: style.Prop, prop: style.Prop) bool {
        const n = @tagName(named);
        const p = @tagName(prop);
        return p.len > n.len and std.mem.startsWith(u8, p, n) and p[n.len] == '_';
    }

    fn syncAnimation(e: *Engine, id: NodeId, sheets: []const style.Sheet, c: *const Computed, now_ms: f64) void {
        const cur = e.animationOf(id);
        if (c.animation_name.len == 0 or c.animation_duration <= 0) {
            if (cur) |ai| e.a_used[ai] = false;
            return;
        }
        if (cur) |ai| {
            const an = &e.animations[ai];
            if (std.mem.eql(u8, an.name, c.animation_name)) {
                an.base = c.*;
                an.spec = c.*;
                return;
            }
            e.a_used[ai] = false;
        }
        if (style.keyframesNamed(sheets, c.animation_name) == null) return;
        const si = blk: {
            for (e.a_used, 0..) |u, i| if (!u) break :blk i;
            return;
        };
        e.animations[si] = .{ .node = id, .name = c.animation_name, .start_ms = now_ms + c.animation_delay, .spec = c.*, .base = c.* };
        e.a_used[si] = true;
    }

    fn animationOf(e: *Engine, id: NodeId) ?usize {
        for (e.animations[0..], 0..) |*an, i| if (e.a_used[i] and an.node == id) return i;
        return null;
    }

    /// Whether anything is running (another frame is due).
    pub fn running(e: *const Engine) bool {
        for (e.t_used) |u| if (u) return true;
        for (e.animations[0..], 0..) |*an, i| if (e.a_used[i] and !an.done) return true;
        return false;
    }

    /// Write the running values into the styles for this moment: each
    /// animated element gets a fresh computed value in `a`. True when
    /// something is still running after this frame.
    pub fn apply(e: *Engine, a: std.mem.Allocator, doc: *const dom.Document, sheets: []const style.Sheet, styles: *style.Styles, env: style.Env, now_ms: f64) !bool {
        var any = false;
        for (e.transitions[0..], 0..) |*t, ti| {
            if (!e.t_used[ti]) continue;
            if (t.node >= styles.computed.len or !attached(doc, t.node)) {
                e.t_used[ti] = false;
                continue;
            }
            const p = t.progress(now_ms);
            const base = styles.get(t.node);
            const mix = try style.interpolate(a, &t.from, &t.to, t.timing.at(p));
            const out = try a.create(Computed);
            out.* = base.*;
            style.copyProp(out, &mix, t.prop);
            styles.computed[t.node] = out;
            if (p >= 1) e.t_used[ti] = false else any = true;
        }
        for (e.animations[0..], 0..) |*an, ai| {
            if (!e.a_used[ai] or an.done) continue;
            if (an.node >= styles.computed.len or !attached(doc, an.node)) {
                e.a_used[ai] = false;
                continue;
            }
            const kf = style.keyframesNamed(sheets, an.name) orelse {
                e.a_used[ai] = false;
                continue;
            };
            const spec = &an.spec;
            const elapsed = now_ms - an.start_ms;
            var finished = false;
            var p: f64 = 0;
            if (elapsed < 0) {
                if (spec.animation_fill != .backwards and spec.animation_fill != .both) {
                    any = true;
                    continue;
                }
                p = 0;
            } else {
                const iter = elapsed / spec.animation_duration;
                if (iter >= spec.animation_iterations) {
                    finished = true;
                    p = 1;
                    const last_odd = @mod(@ceil(spec.animation_iterations), 2) == 1;
                    const reversed = spec.animation_direction == .reverse or (spec.animation_direction == .alternate and !last_odd) or (spec.animation_direction == .alternate_reverse and last_odd);
                    if (reversed) p = 0;
                } else {
                    const k = @floor(iter);
                    p = iter - k;
                    const odd = @mod(k, 2) == 1;
                    const reversed = spec.animation_direction == .reverse or (spec.animation_direction == .alternate and odd) or (spec.animation_direction == .alternate_reverse and !odd);
                    if (reversed) p = 1 - p;
                }
            }
            if (finished and spec.animation_fill != .forwards and spec.animation_fill != .both) {
                an.done = true;
                continue;
            }
            // The two keyframes around p, their values over the base.
            const parent_id = doc.get(an.node).parent;
            const parent: *const Computed = if (parent_id) |pid| (if (pid < styles.computed.len) styles.get(pid) else &an.base) else &an.base;
            var lo: ?style.Keyframe = null;
            var hi: ?style.Keyframe = null;
            for (kf.frames) |fr| {
                if (fr.offset <= p and (lo == null or fr.offset >= lo.?.offset)) lo = fr;
                if (fr.offset >= p and (hi == null or fr.offset < hi.?.offset)) hi = fr;
            }
            const base = &an.base;
            const from = if (lo) |fr| try style.applyKeyframe(a, base, parent, fr.declarations, env) else base.*;
            const to = if (hi) |fr| try style.applyKeyframe(a, base, parent, fr.declarations, env) else base.*;
            const lo_off: f64 = if (lo) |fr| fr.offset else 0;
            const hi_off: f64 = if (hi) |fr| fr.offset else 1;
            const local = if (hi_off > lo_off) (p - lo_off) / (hi_off - lo_off) else 1;
            const out = try a.create(Computed);
            out.* = try style.interpolate(a, &from, &to, spec.animation_timing.at(local));
            // What the keyframes do not touch stays the element's.
            out.animation_name = base.animation_name;
            styles.computed[an.node] = out;
            if (finished) an.done = true else any = true;
        }
        return any;
    }

    pub fn reset(e: *Engine) void {
        e.t_used = @splat(false);
        e.a_used = @splat(false);
        e.n_snap = 0;
    }
};

/// Whether an element is in the document (its parent chain reaches the
/// document node): only those have a computed style.
fn attached(doc: *const dom.Document, id: NodeId) bool {
    if (id >= doc.nodes.len) return false;
    var cur: ?NodeId = id;
    while (cur) |c| : (cur = doc.get(c).parent) if (c == dom.document_id) return true;
    return false;
}

/// Whether a transitionable property reads the same on two styles.
fn propEql(x: *const Computed, y: *const Computed, prop: style.Prop) bool {
    var ax: Computed = .{};
    var ay: Computed = .{};
    style.copyProp(&ax, x, prop);
    style.copyProp(&ay, y, prop);
    return std.meta.eql(ax, ay);
}

const html = @import("html.zig");

test "animate: a transition interpolates a width over its duration" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: style.Env = .{ .width = 400, .height = 300 };
    const doc = try html.parse(a, "<style>.b { width: 100px; transition: width 1s linear; } .b.wide { width: 300px; }</style><div class=b></div>", .{});
    const sheets = try style.collectDocumentSheets(a, doc, env);
    var styles = try style.compute(a, doc, sheets, env);
    var e: Engine = .{};
    var div: NodeId = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "div")) {
        div = id;
    };
    e.snapshot(doc, &styles);
    try doc.setAttr(div, "class", "b wide");
    var styles2 = try style.compute(a, doc, sheets, env);
    e.onRestyle(a, doc, sheets, &styles2, 1000);
    try std.testing.expect(e.running());
    var s3 = styles2;
    s3.computed = try a.dupe(*const Computed, styles2.computed);
    try std.testing.expect(try e.apply(a, doc, sheets, &s3, env, 1500));
    try std.testing.expectApproxEqAbs(@as(f64, 200), s3.computed[div].width.px, 0.01);
    var s4 = styles2;
    s4.computed = try a.dupe(*const Computed, styles2.computed);
    try std.testing.expect(!try e.apply(a, doc, sheets, &s4, env, 2100));
    try std.testing.expectApproxEqAbs(@as(f64, 300), s4.computed[div].width.px, 0.01);
    try std.testing.expect(!e.running());
}

test "animate: keyframes drive an animation through its frames" {
    var arena = std.heap.ArenaAllocator.init(std.testing.allocator);
    defer arena.deinit();
    const a = arena.allocator();
    const env: style.Env = .{ .width = 400, .height = 300 };
    const doc = try html.parse(a, "<style>@keyframes grow { from { width: 0px } 50% { width: 100px } to { width: 200px } } .b { width: 10px; animation: grow 2s linear 1 forwards; }</style><div class=b></div>", .{});
    const sheets = try style.collectDocumentSheets(a, doc, env);
    try std.testing.expect(style.keyframesNamed(sheets, "grow") != null);
    try std.testing.expectEqual(@as(usize, 3), style.keyframesNamed(sheets, "grow").?.frames.len);
    var styles = try style.compute(a, doc, sheets, env);
    var div: NodeId = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "div")) {
        div = id;
    };
    try std.testing.expectApproxEqAbs(@as(f64, 2000), styles.get(div).animation_duration, 0.01);
    var e: Engine = .{};
    e.onRestyle(a, doc, sheets, &styles, 0);
    try std.testing.expect(e.running());
    var s1 = styles;
    s1.computed = try a.dupe(*const Computed, styles.computed);
    try std.testing.expect(try e.apply(a, doc, sheets, &s1, env, 500));
    try std.testing.expectApproxEqAbs(@as(f64, 50), s1.computed[div].width.px, 0.01);
    var s2 = styles;
    s2.computed = try a.dupe(*const Computed, styles.computed);
    try std.testing.expect(try e.apply(a, doc, sheets, &s2, env, 1500));
    try std.testing.expectApproxEqAbs(@as(f64, 150), s2.computed[div].width.px, 0.01);
    var s3 = styles;
    s3.computed = try a.dupe(*const Computed, styles.computed);
    try std.testing.expect(!try e.apply(a, doc, sheets, &s3, env, 2500));
    try std.testing.expectApproxEqAbs(@as(f64, 200), s3.computed[div].width.px, 0.01); // forwards: holds the end
}
