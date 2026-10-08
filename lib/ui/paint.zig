//! Widget painters: a control's look as a pure function of a `Brush` —
//! the canvas to paint on, the typeface to measure and draw with, the
//! palette, and the icon cache — and its model. A program builds one
//! brush from its frame (surface pixels, the font service, the live
//! theme); a test builds one from an array and `typeface.Fixed`, paints,
//! and asserts pixels. Nothing here knows a surface, a service or a key.
const std = @import("std");
const geometry = @import("geometry.zig");
const Rect = geometry.Rect;
const control = geometry.control;
const Canvas = @import("canvas.zig").Canvas;
const typeface = @import("typeface.zig");
const Typeface = typeface.Typeface;
const Palette = @import("palette.zig").Palette;
const icons = @import("icons.zig");
const text = @import("text.zig");
const tabs = @import("tabs.zig");

pub const Brush = struct {
    canvas: *const Canvas,
    face: Typeface,
    pal: *const Palette,
    icons: *icons.Cache,
    /// The icon size that matches the UI text size (a font-scaled 20 px).
    icon_px: usize,

    pub fn line(self: Brush) usize {
        return self.face.line(.ui);
    }
    pub fn width(self: Brush, s: []const u8) usize {
        return self.face.measure(.ui, s);
    }
    pub fn icon(self: Brush, which: icons.Icon, size: usize, x: usize, y: usize, ink: u32) void {
        self.icons.draw(self.canvas, which, size, x, y, ink);
    }
};

/// A control row's height: the taller of a text line and an icon, padded.
pub fn controlHeight(b: Brush) usize {
    return @max(b.line(), b.icon_px) + 16;
}

pub const ButtonStyle = struct {
    focused: bool = false,
    /// The accent fill: the one action a form is for.
    primary: bool = false,
    /// The destructive fill: a button that deletes or discards.
    danger: bool = false,
    disabled: bool = false,
    /// The pointer is over it (the fill lifts) / it is held down over it
    /// (the fill sinks) — the feedback a hand expects before the release
    /// that fires it.
    hovered: bool = false,
    pressed: bool = false,
    /// A pill: fully rounded ends, no outline, no highlight — the dock's
    /// launchers, which read as a row of tokens rather than form buttons.
    pill: bool = false,
};

/// A raised button: a rounded panel with a soft highlight along its top
/// edge, an optional leading icon, a centred (or icon-led) label
/// ellipsized to fit. Primary and danger give it semantic colour;
/// disabled keeps the shape and mutes the ink; focus thickens the
/// outline in the focus colour — never the only cue, the label still
/// says what it is; hover lifts the fill and a press sinks it.
pub fn button(b: Brush, r: Rect, label: []const u8, icon: ?icons.Icon, style: ButtonStyle) void {
    const p = b.pal;
    var bg = if (style.disabled) (if (style.pill) p.surface_hi else p.surface) else if (style.primary) p.primary else if (style.danger) p.danger else p.surface_hi;
    const ink = if (style.disabled) p.text_muted else if (style.primary and !style.disabled) p.primary_ink else if (style.danger) p.danger_ink else p.text;
    if (!style.disabled and style.hovered) bg = palette.shade(bg, 9, 8);
    if (!style.disabled and style.pressed and style.hovered) bg = palette.shade(bg, 4, 5);
    const radius = if (style.pill) r.h / 2 else control.radius;
    // A pill has no outline — unless the palette has no raised surface to
    // show its shape with (high contrast: the surface is the ground), when
    // the outline is what makes it a pill at all.
    const flat = p.surface_hi == p.bg;
    const ring = if (style.focused) p.focus else if (style.pill and !flat) bg else p.border;
    const ring_w = if (style.focused) p.focus_w else if (style.pill and !flat) 0 else p.border_w;
    b.canvas.panel(r.x, r.y, r.w, r.h, radius, bg, ring, ring_w);
    // A soft top highlight inside the rounded fill — a hint of depth, not
    // a hard bar (kept clear of the corners so it never pokes past them).
    if (!style.pill) b.canvas.fillRect(r.x + radius, r.y + ring_w, r.w -| (2 * radius), 1, palette.shade(bg, 6, 5));
    const size = b.icon_px;
    const has_icon = icon != null and r.w >= size + 16 + (if (label.len > 0) b.width(label) + @as(usize, 8) else 0);
    const inset: usize = if (has_icon) size + 8 else 0;
    if (has_icon) b.icon(icon.?, size, r.x + 8, r.y + (r.h -| size) / 2, ink);
    const w = @min(b.width(label), r.w -| (inset + 16));
    const x = if (has_icon) r.x + 8 + inset else r.x + (r.w -| w) / 2;
    b.face.drawTrunc(b.canvas, x, r.y + (r.h -| b.line()) / 2, .ui, label, r.w -| (inset + 16), ink, bg);
}

/// A single-line text field: an inset panel, the visible window of the
/// editor's text scrolled so the caret stays in view (`ed.first` is
/// advanced here and remembered), the selection as an inverted run, and
/// a caret bar when focused.
pub fn field(b: Brush, r: Rect, ed: *text.Editor, focused: bool) void {
    const p = b.pal;
    b.canvas.panel(r.x, r.y, r.w, r.h, control.radius, p.field_bg, if (focused) p.focus else p.border, if (focused) p.focus_w else p.border_w);
    const room = r.w -| 20;
    const shown = ed.buf[0..ed.len];
    ed.first = @min(ed.first, ed.cursor);
    while (ed.first < ed.cursor and b.width(shown[ed.first..ed.cursor]) > room) ed.first = ed.next(ed.first);
    var last = ed.first;
    while (last < ed.len) {
        const next = ed.next(last);
        if (b.width(shown[ed.first..next]) > room) break;
        last = next;
    }
    const x = r.x + 8;
    const y = r.y + (r.h -| b.line()) / 2;
    const lo = @max(ed.first, ed.low());
    const hi = @min(last, ed.high());
    if (focused and hi > lo) {
        const sx = x + b.width(shown[ed.first..lo]);
        const sw = b.width(shown[lo..hi]);
        b.canvas.fillRect(sx, y, sw, b.line(), p.primary);
        b.face.draw(b.canvas, x, y, .ui, shown[ed.first..lo], p.text, p.field_bg);
        b.face.draw(b.canvas, sx, y, .ui, shown[lo..hi], p.primary_ink, p.primary);
        b.face.draw(b.canvas, sx + sw, y, .ui, shown[hi..last], p.text, p.field_bg);
    } else b.face.draw(b.canvas, x, y, .ui, shown[ed.first..last], p.text, p.field_bg);
    if (focused) b.canvas.fillRect(x + b.width(shown[ed.first..ed.cursor]), y, 2, b.line(), p.focus);
}

// --------------------------------------------------------------- toggle

pub const ToggleStyle = struct {
    on: bool,
    focused: bool = false,
    hovered: bool = false,
    disabled: bool = false,
    /// A checkbox (a square with a mark) rather than a switch (a pill
    /// with a knob). Same model, same events; the box reads as "one of a
    /// set of options", the switch as "a setting that takes effect".
    check: bool = false,
    /// The ground the label is drawn over (a section's surface, say).
    ground: u32,
};

/// The control's own box, before its label: a switch is a pill two text
/// heights wide, a checkbox a square — both one UI line tall, so a row
/// of them aligns with text.
pub fn toggleControl(b: Brush, check: bool) geometry.Size {
    const k = b.line();
    return if (check) .{ .w = k, .h = k } else .{ .w = k * 2 - k / 4, .h = k };
}

/// A toggle's footprint: the control, a gap, the label; as tall as a
/// button so it sits on the same line as one.
pub fn toggleSize(b: Brush, label: []const u8, check: bool) geometry.Size {
    const c = toggleControl(b, check);
    return .{ .w = c.w + (if (label.len > 0) 8 + b.width(label) else 0), .h = controlHeight(b) };
}

fn checkMark(c: *const Canvas, x: usize, y: usize, size: usize, ink: u32) void {
    // Two strokes: a short one down to the low point, a long one up to
    // the top right. Stamped as discs so the joint is round at any size.
    const t = @max(1, size / 8);
    const x0 = x + size * 25 / 100;
    const y0 = y + size * 52 / 100;
    const x1 = x + size * 42 / 100;
    const y1 = y + size * 70 / 100;
    const x2 = x + size * 76 / 100;
    const y2 = y + size * 30 / 100;
    stroke(c, x0, y0, x1, y1, t, ink);
    stroke(c, x1, y1, x2, y2, t, ink);
}
fn stroke(c: *const Canvas, x0: usize, y0: usize, x1: usize, y1: usize, t: usize, ink: u32) void {
    const dx: isize = @as(isize, @intCast(x1)) - @as(isize, @intCast(x0));
    const dy: isize = @as(isize, @intCast(y1)) - @as(isize, @intCast(y0));
    const steps: usize = @intCast(@max(@abs(dx), @abs(dy)));
    var i: usize = 0;
    while (i <= steps) : (i += 1) {
        const px: isize = @as(isize, @intCast(x0)) + if (steps == 0) 0 else @divTrunc(dx * @as(isize, @intCast(i)), @as(isize, @intCast(steps)));
        const py: isize = @as(isize, @intCast(y0)) + if (steps == 0) 0 else @divTrunc(dy * @as(isize, @intCast(i)), @as(isize, @intCast(steps)));
        c.fillDot(@intCast(@max(0, px)), @intCast(@max(0, py)), t, ink);
    }
}

/// A switch or a checkbox with its label. On: the primary fill, the knob
/// (or the mark) in the primary ink; off: the raised surface with the knob
/// in the text colour — so the state is read from the knob's side and the
/// fill, never from colour alone. Focus thickens the outline in the focus
/// colour, hover lifts the fill, disabled mutes everything.
pub fn toggle(b: Brush, r: Rect, label: []const u8, style: ToggleStyle) void {
    const p = b.pal;
    const c = toggleControl(b, style.check);
    const cx = r.x;
    const cy = r.y + (r.h -| c.h) / 2;
    const ring = if (style.focused) p.focus else p.border;
    const ring_w = if (style.focused) p.focus_w else p.border_w;
    var fill = if (style.disabled) p.surface else if (style.on) p.primary else p.surface_hi;
    if (style.hovered and !style.disabled) fill = palette.shade(fill, 9, 8);
    const mark_ink = if (style.disabled) p.text_muted else if (style.on) p.primary_ink else p.text;
    if (style.check) {
        b.canvas.panel(cx, cy, c.w, c.h, @max(2, control.radius - 2), fill, ring, ring_w);
        if (style.on) checkMark(b.canvas, cx, cy, c.w, mark_ink);
    } else {
        b.canvas.panel(cx, cy, c.w, c.h, c.h / 2, fill, ring, ring_w);
        const pad = ring_w + 2;
        const d = c.h -| 2 * pad; // the knob's diameter
        const kr = d / 2;
        const kx = if (style.on) cx + c.w -| (pad + kr + 1) else cx + pad + kr;
        if (kr > 0) b.canvas.fillDot(kx, cy + c.h / 2, kr, mark_ink);
    }
    if (label.len > 0) {
        const ink = if (style.disabled) p.text_muted else p.text;
        b.face.drawTrunc(b.canvas, r.x + c.w + 8, r.y + (r.h -| b.line()) / 2, .ui, label, r.w -| (c.w + 8), ink, style.ground);
    }
}

// ---------------------------------------------------------------- sheet

/// A modal sheet's corner radius and the inset of its content.
pub const sheet_radius: usize = 10;
pub const sheet_inset: usize = geometry.space.inset;
/// How much the scrim darkens what is behind a sheet (0..255).
pub const scrim_cov: u32 = 96;

/// The scrim over a window's content and the sheet that floats on it: a
/// raised surface with the window's outline, so a dialog reads as a
/// panel of the same window rather than a second one.
pub fn scrim(b: Brush, r: Rect) void {
    b.canvas.dim(r.x, r.y, r.w, r.h, 0x000000, scrim_cov);
}
pub fn sheet(b: Brush, r: Rect) void {
    const p = b.pal;
    b.canvas.panel(r.x, r.y, r.w, r.h, sheet_radius, p.surface, p.window_border, @max(1, p.border_w));
}

// ------------------------------------------------------------ menu rows

pub const MenuItemStyle = struct {
    selected: bool = false,
    enabled: bool = true,
    /// The row opens a nested menu: a caret at the right says so.
    submenu: bool = false,
};
/// A menu row's height: a text line with the item padding; a separator
/// is a third of a line.
pub fn menuRowHeight(b: Brush) usize {
    return b.line() + 16;
}
pub fn menuSeparatorHeight(b: Brush) usize {
    return @max(9, b.line() / 3);
}
/// A rule between groups, inset from the popup's edges.
pub fn menuSeparator(b: Brush, r: Rect) void {
    b.canvas.fillRect(r.x + 12, r.y + r.h / 2, r.w -| 24, b.pal.border_w, b.pal.border);
}
/// One menu row: the label at the left, a shortcut hint at the right, the
/// selected row lifted on a rounded primary band inset from the popup's
/// edges, a disabled row in muted ink. `r` is the whole row across the
/// popup; the painter knows nothing of which popup.
pub fn menuItem(b: Brush, r: Rect, label: []const u8, shortcut: []const u8, style: MenuItemStyle) void {
    const p = b.pal;
    const selected = style.selected and style.enabled;
    const bg = if (selected) p.primary else p.surface;
    const ink = if (!style.enabled) p.text_muted else if (selected) p.primary_ink else p.text;
    if (selected) b.canvas.fillRoundRect(r.x + 4, r.y, r.w -| 8, r.h, 4, bg);
    const ty = r.y + (r.h -| b.line()) / 2;
    const caret = if (style.submenu) @max(8, b.line() * 3 / 5) else 0;
    const sw = if (style.submenu) caret else b.width(shortcut);
    const gap: usize = if (sw > 0) 24 else 0;
    b.face.drawTrunc(b.canvas, r.x + 12, ty, .ui, label, r.w -| (24 + sw + gap), ink, bg);
    if (style.submenu) {
        if (caret + 24 < r.w) b.icon(.forward, caret, r.x + r.w - 12 - caret, r.y + (r.h -| caret) / 2, ink);
    } else if (sw > 0 and sw + 24 < r.w) b.face.draw(b.canvas, r.x + r.w - 12 - sw, ty, .ui, shortcut, ink, bg);
}

// ------------------------------------------------------------ tab strip

pub const TabItem = struct { label: []const u8, dirty: bool = false, closable: bool = true };

fn tabDesired(b: Brush, item: TabItem, h: usize) usize {
    return @min(@max(b.width(item.label) + 24 + (if (item.dirty) h / 3 else @as(usize, 0)) + (if (item.closable) h else @as(usize, 0)), h * 2), h * 6);
}
fn tabLayout(b: Brush, r: Rect, items: []const TabItem, state: tabs.State) tabs.Layout {
    var total: usize = 0;
    for (items) |item| total +|= tabDesired(b, item, r.h);
    return tabs.Layout.init(r.w, r.h, total > r.w or state.first > 0);
}
fn boundedFirst(state: tabs.State, count: usize) usize {
    return @min(state.first, count -| 1);
}
fn tabArrow(b: Brush, r: Rect, span: tabs.Span, forward: bool, enabled: bool) void {
    if (span.w == 0) return;
    const size = @min(b.icon_px, span.w -| 8);
    if (size < 4) return;
    // The forward arrow is drawn from the same simple stroke geometry as
    // the back arrow, so no new icon asset is required for navigation.
    const ink = if (enabled) b.pal.text else b.pal.text_muted;
    const cx = r.x + span.x + span.w / 2;
    const cy = r.y + r.h / 2;
    if (!forward) {
        b.icon(.back, size, cx -| (size / 2), cy -| (size / 2), ink);
    } else {
        const half = size / 3;
        const thick = @max(1, size / 12);
        b.canvas.fillRect(cx -| half, cy -| (thick / 2), half * 2, thick, ink);
        for (0..half) |i| {
            b.canvas.fillRect(cx + half - i, cy -| i, thick, thick, ink);
            b.canvas.fillRect(cx + half - i, cy + i, thick, thick, ink);
        }
    }
}

/// The tab strip: a row of document tabs with the selected one lifted and
/// underlined in the focus colour, a dirty dot, a close glyph, and
/// overflow arrows. Scrolling state (`state.first`) is the caller's and
/// is advanced here to keep the selection visible when it was.
pub fn tabStrip(b: Brush, r: Rect, items: []const TabItem, selected: usize, state: *tabs.State) void {
    state.resize(r.w, r.h, selected);
    state.first = boundedFirst(state.*, items.len);
    if (r.w == 0 or r.h == 0) return;
    // Labels can grow without a viewport resize (Save As or a dirty badge).
    // Preserve selection only if it was visible before; explicit scrolling
    // is still allowed to put the active document outside the viewport.
    var preview = tabLayout(b, r, items, state.*);
    var visible = false;
    for (items[state.first..], state.first..) |item, index| {
        _ = preview.put(tabDesired(b, item, r.h), item.closable) orelse break;
        if (index == selected) {
            visible = true;
            break;
        }
    }
    state.preserveVisibility(visible, selected);
    var total: usize = 0;
    for (items) |item| total +|= tabDesired(b, item, r.h);
    if (total <= r.w) {
        state.first = 0;
    } else if (state.reveal_pending and items.len > 0) {
        // Fill available space before the newly selected document as well:
        // switching to the last tab should not leave a mostly empty strip.
        const viewport = tabs.Layout.init(r.w, r.h, true).content.w;
        var used = @min(tabDesired(b, items[state.first], r.h), viewport);
        while (state.first > 0) {
            const preceding = tabDesired(b, items[state.first - 1], r.h);
            if (preceding > viewport - used) break;
            used += preceding;
            state.first -= 1;
        }
    }
    state.reveal_pending = false;
    var row = tabLayout(b, r, items, state.*);
    const p = b.pal;
    b.canvas.fillRect(r.x, r.y, r.w, r.h, p.surface_hi);
    var end = state.first;
    for (items[state.first..], state.first..) |item, index| {
        const tab = row.put(tabDesired(b, item, r.h), item.closable) orelse break;
        end = index + 1;
        const bg = if (index == selected) p.surface else p.surface_hi;
        const ink = if (index == selected) p.text else p.text_muted;
        b.canvas.fillRect(r.x + tab.body.x, r.y, tab.body.w, r.h, bg);
        if (index == selected) b.canvas.fillRect(r.x + tab.body.x, r.y + r.h -| 2, tab.body.w, @min(2, r.h), p.focus);
        var inset: usize = @min(12, tab.body.w);
        if (item.dirty and tab.body.w > r.h) {
            const radius = @max(2, r.h / 14);
            b.canvas.fillDot(r.x + tab.body.x + inset + radius, r.y + r.h / 2, radius, ink);
            inset += r.h / 3;
        }
        b.face.drawTrunc(b.canvas, r.x + tab.body.x + inset, r.y + (r.h -| b.line()) / 2, .ui, item.label, tab.body.w -| (inset + tab.close.w + 8), ink, bg);
        if (tab.close.w > 0) {
            const size = @min(b.icon_px, tab.close.w -| 16);
            b.icon(.close, size, r.x + tab.close.x + (tab.close.w - size) / 2, r.y + (r.h -| size) / 2, ink);
        }
    }
    tabArrow(b, r, row.previous, false, state.first > 0);
    tabArrow(b, r, row.next, true, end < items.len);
    state.selection_visible = selected >= state.first and selected < end;
}

/// What a press at (x, y) on the strip means, using the same layout the
/// strip was painted with.
/// Where tab `index` sits in the strip (its body span, strip-relative),
/// or null when it is scrolled out of view — so a host driving the
/// pointer can be told each tab's centre.
pub fn tabSpan(b: Brush, r: Rect, items: []const TabItem, state: tabs.State, index: usize) ?tabs.Span {
    const first = boundedFirst(state, items.len);
    var row = tabLayout(b, r, items, .{ .first = first });
    for (items[first..], first..) |item, i| {
        const tab = row.put(tabDesired(b, item, r.h), item.closable) orelse return null;
        if (i == index) return tab.body;
    }
    return null;
}

pub fn tabStripHit(b: Brush, r: Rect, items: []const TabItem, state: tabs.State, x: usize, y: usize) tabs.Hit {
    if (x < r.x or y < r.y or x - r.x >= r.w or y - r.y >= r.h) return .none;
    const local = x - r.x;
    const first = boundedFirst(state, items.len);
    var row = tabLayout(b, r, items, .{ .first = first });
    if (row.previous.contains(local)) return if (first > 0) .previous else .none;
    var end = first;
    for (items[first..], first..) |item, index| {
        const tab = row.put(tabDesired(b, item, r.h), item.closable) orelse break;
        end = index + 1;
        const result = tab.hit(index, local);
        if (result != .none) return result;
    }
    if (row.next.contains(local) and end < items.len) return .next;
    return .none;
}

// ------------------------------------------------------------------ tests

const palette = @import("palette.zig");

const Bench = struct {
    buf: [200 * 60]u32 = @splat(0x010101),
    canvas: Canvas = undefined,
    fixed: typeface.Fixed = .{},
    pal: Palette = palette.resolve(.dark, .normal, .default),
    cache: icons.Cache = .{},
    fn brush(self: *Bench) Brush {
        self.canvas = Canvas.init(&self.buf, 200, 60);
        return .{ .canvas = &self.canvas, .face = self.fixed.face(), .pal = &self.pal, .icons = &self.cache, .icon_px = 20 };
    }
};

fn countColor(c: *const Canvas, r: Rect, color: u32) usize {
    var n: usize = 0;
    for (r.y..r.y + r.h) |y| for (r.x..r.x + r.w) |x| {
        if (c.at(x, y) == color) n += 1;
    };
    return n;
}

test "a button is a panel in its fill with a legible label, muted when disabled" {
    var bench: Bench = .{};
    const b = bench.brush();
    const r: Rect = .{ .x = 10, .y = 10, .w = 120, .h = controlHeight(b) };
    button(b, r, "Open", null, .{ .primary = true });
    const p = b.pal;
    try std.testing.expectEqual(p.primary, bench.canvas.at(20, r.y + 4)); // inside, off the label
    try std.testing.expectEqual(p.border, bench.canvas.at(r.x + r.w / 2, r.y)); // the top edge
    try std.testing.expectEqual(@as(u32, 0x010101), bench.canvas.at(r.x, r.y)); // a rounded corner leaves the ground
    try std.testing.expect(countColor(&bench.canvas, r, p.primary_ink) > 0); // the label's ink
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, .{ .x = 0, .y = 0, .w = 200, .h = 10 }, p.primary)); // nothing above
    // Disabled: same shape, muted ink, no primary fill.
    button(b, r, "Open", null, .{ .primary = true, .disabled = true });
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, r, p.primary_ink));
    try std.testing.expect(countColor(&bench.canvas, r, p.text_muted) > 0);
    // Focus: the outline is the focus colour, and thicker.
    button(b, r, "Open", null, .{ .focused = true });
    try std.testing.expectEqual(p.focus, bench.canvas.at(r.x + r.w / 2, r.y));
    try std.testing.expectEqual(p.focus, bench.canvas.at(r.x + r.w / 2, r.y + p.focus_w - 1));
    try std.testing.expect(bench.canvas.at(r.x + r.w / 2, r.y + p.focus_w) != p.focus);
}

test "a button with an icon leads with it and a narrow button drops it" {
    var bench: Bench = .{};
    const b = bench.brush();
    const wide: Rect = .{ .x = 0, .y = 0, .w = 160, .h = 32 };
    button(b, wide, "Up", .up, .{});
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 8, .y = 6, .w = 20, .h = 20 }, b.pal.text) > 0); // icon ink at the left
    bench.canvas.fillAll(0x010101);
    button(b, .{ .x = 0, .y = 0, .w = 30, .h = 32 }, "", .up, .{});
    // Too narrow for the icon: nothing but the panel is painted.
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, .{ .x = 0, .y = 0, .w = 30, .h = 32 }, b.pal.text));
}

test "a field paints its text, its selection inverted, and a caret only when focused" {
    var bench: Bench = .{};
    const b = bench.brush();
    var ed: text.Editor = .{};
    ed.seed("hello");
    const r: Rect = .{ .x = 0, .y = 0, .w = 120, .h = 24 };
    field(b, r, &ed, false);
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, r, b.pal.focus)); // no caret, no focus ring
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.text) > 0);
    ed.apply(.select_all);
    field(b, r, &ed, true);
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.primary) > 0); // the selection band
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.primary_ink) > 0); // inverted text
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.focus) > 0); // caret + ring
    // A long text scrolls so the caret stays visible: `first` advances.
    ed.seed("0123456789012345678901234567890123456789");
    field(b, r, &ed, true);
    try std.testing.expect(ed.first > 0);
}

test "the tab strip lifts and underlines the selected tab and hits its close target" {
    var bench: Bench = .{};
    const b = bench.brush();
    var state: tabs.State = .{};
    const items = [_]TabItem{ .{ .label = "one" }, .{ .label = "two", .dirty = true }, .{ .label = "three" } };
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 28 };
    tabStrip(b, r, &items, 1, &state);
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 0, .y = 26, .w = 200, .h = 2 }, b.pal.focus) > 0); // the underline
    // Three tabs overflow 200 px: the first pixels are the leading arrow, not a tab.
    const edge = tabStripHit(b, r, &items, state, 4, 14);
    try std.testing.expect(edge == .none or edge == .previous);
    // Wide enough for all three: the first pixels are the first tab.
    var wide_state: tabs.State = .{};
    const wide: Rect = .{ .x = 0, .y = 0, .w = 400, .h = 28 };
    tabStrip(b, wide, &items, 1, &wide_state);
    try std.testing.expectEqual(tabs.Hit{ .select = 0 }, tabStripHit(b, wide, &items, wide_state, 4, 14));
    try std.testing.expect(state.selection_visible);
    // Some pixel of the strip is a close target.
    var close_found = false;
    var x: usize = 0;
    while (x < 200) : (x += 1) {
        if (tabStripHit(b, r, &items, state, x, 14) == .close) {
            close_found = true;
            break;
        }
    }
    try std.testing.expect(close_found);
    try std.testing.expectEqual(tabs.Hit.none, tabStripHit(b, r, &items, state, 0, 40)); // outside
}

test "a toggle reads its state from the fill and the knob's side, and a checkbox from its mark" {
    var bench: Bench = .{};
    const b = bench.brush();
    const p = b.pal;
    const r: Rect = .{ .x = 10, .y = 10, .w = 150, .h = controlHeight(b) };
    const c = toggleControl(b, false);
    try std.testing.expect(c.w > c.h and c.h == b.line());
    const sz = toggleSize(b, "Dark", false);
    try std.testing.expect(sz.w > c.w and sz.h == r.h);
    // Off: no primary anywhere, the knob (text ink) sits in the left half.
    toggle(b, r, "Dark", .{ .on = false, .ground = 0x010101 });
    const box: Rect = .{ .x = r.x, .y = r.y + (r.h - c.h) / 2, .w = c.w, .h = c.h };
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, box, p.primary));
    const left: Rect = .{ .x = box.x, .y = box.y, .w = box.w / 2, .h = box.h };
    const right: Rect = .{ .x = box.x + box.w / 2, .y = box.y, .w = box.w / 2, .h = box.h };
    try std.testing.expect(countColor(&bench.canvas, left, p.text) > countColor(&bench.canvas, right, p.text));
    try std.testing.expect(countColor(&bench.canvas, .{ .x = box.x + box.w + 8, .y = r.y, .w = 60, .h = r.h }, p.text) > 0); // the label
    // On: the primary fill, the knob (primary ink) in the right half.
    bench.canvas.fillAll(0x010101);
    toggle(b, r, "Dark", .{ .on = true, .ground = 0x010101 });
    try std.testing.expect(countColor(&bench.canvas, box, p.primary) > 0);
    try std.testing.expect(countColor(&bench.canvas, right, p.primary_ink) > countColor(&bench.canvas, left, p.primary_ink));
    // Focus: the outline is the focus colour at the control's top edge.
    bench.canvas.fillAll(0x010101);
    toggle(b, r, "Dark", .{ .on = true, .focused = true, .ground = 0x010101 });
    try std.testing.expectEqual(p.focus, bench.canvas.at(box.x + box.w / 2, box.y));
    // Disabled: muted ink only, no primary.
    bench.canvas.fillAll(0x010101);
    toggle(b, r, "Dark", .{ .on = true, .disabled = true, .ground = 0x010101 });
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, r, p.primary));
    try std.testing.expect(countColor(&bench.canvas, r, p.text_muted) > 0);
    // A checkbox is square; checked, it carries a mark in the primary ink.
    const cb = toggleControl(b, true);
    try std.testing.expectEqual(cb.w, cb.h);
    bench.canvas.fillAll(0x010101);
    toggle(b, r, "", .{ .on = false, .check = true, .ground = 0x010101 });
    const cbox: Rect = .{ .x = r.x, .y = r.y + (r.h - cb.h) / 2, .w = cb.w, .h = cb.h };
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, cbox, p.primary_ink));
    toggle(b, r, "", .{ .on = true, .check = true, .ground = 0x010101 });
    try std.testing.expect(countColor(&bench.canvas, cbox, p.primary_ink) > 0);
    try std.testing.expect(countColor(&bench.canvas, cbox, p.primary) > 0);
}

test "a sheet floats on a scrim that dims what is behind it" {
    var bench: Bench = .{};
    const b = bench.brush();
    bench.canvas.fillAll(0xffffff);
    scrim(b, .{ .x = 0, .y = 0, .w = 200, .h = 60 });
    const dimmed = bench.canvas.at(5, 5);
    try std.testing.expect(dimmed != 0xffffff and dimmed != 0);
    sheet(b, .{ .x = 40, .y = 10, .w = 120, .h = 40 });
    try std.testing.expectEqual(b.pal.surface, bench.canvas.at(100, 30));
    try std.testing.expectEqual(b.pal.window_border, bench.canvas.at(100, 10));
    try std.testing.expectEqual(dimmed, bench.canvas.at(5, 5)); // the scrim outside the sheet stays
}

test "a button's hover lifts and its press sinks the fill; danger and pills have their own look" {
    var bench: Bench = .{};
    const b = bench.brush();
    const p = b.pal;
    const r: Rect = .{ .x = 10, .y = 10, .w = 120, .h = controlHeight(b) };
    button(b, r, "", null, .{});
    const plain = bench.canvas.at(20, r.y + 6);
    try std.testing.expectEqual(p.surface_hi, plain);
    button(b, r, "", null, .{ .hovered = true });
    const lifted = bench.canvas.at(20, r.y + 6);
    try std.testing.expect(lifted != plain);
    button(b, r, "", null, .{ .hovered = true, .pressed = true });
    const sunk = bench.canvas.at(20, r.y + 6);
    try std.testing.expect(sunk != lifted and sunk != plain);
    // A press with the pointer elsewhere is no press (the release will cancel).
    button(b, r, "", null, .{ .pressed = true });
    try std.testing.expectEqual(plain, bench.canvas.at(20, r.y + 6));
    button(b, r, "Delete", null, .{ .danger = true });
    try std.testing.expectEqual(p.danger, bench.canvas.at(20, r.y + 6));
    try std.testing.expect(countColor(&bench.canvas, r, p.danger_ink) > 0);
    // A pill has no outline: its top-edge pixel is the fill, and the corner
    // is fully round (the ground shows at the corner's own pixel).
    bench.canvas.fillAll(0x010101);
    button(b, r, "Files", null, .{ .pill = true });
    try std.testing.expectEqual(p.surface_hi, bench.canvas.at(r.x + r.w / 2, r.y));
    try std.testing.expectEqual(@as(u32, 0x010101), bench.canvas.at(r.x, r.y));
    try std.testing.expectEqual(@as(u32, 0x010101), bench.canvas.at(r.x + 2, r.y + 2));
    // At high contrast the raised surface is the ground, so a pill keeps
    // its shape with an outline instead.
    var hc: Bench = .{ .pal = palette.resolve(.dark, .high, .default) };
    const hb = hc.brush();
    hc.canvas.fillAll(0x010101);
    button(hb, r, "Files", null, .{ .pill = true });
    try std.testing.expectEqual(hb.pal.border, hc.canvas.at(r.x + r.w / 2, r.y));
}

test "a menu row lifts its selection on the primary band, mutes a disabled one, and keeps the shortcut at the right" {
    var bench: Bench = .{};
    const b = bench.brush();
    const p = b.pal;
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = menuRowHeight(b) };
    menuItem(b, r, "Save", "Cmd S", .{});
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, r, p.primary));
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 12, .y = 0, .w = 60, .h = r.h }, p.text) > 0); // the label
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 140, .y = 0, .w = 60, .h = r.h }, p.text) > 0); // the shortcut
    menuItem(b, r, "Save", "Cmd S", .{ .selected = true });
    try std.testing.expectEqual(p.primary, bench.canvas.at(100, 2));
    try std.testing.expectEqual(@as(u32, 0x010101), bench.canvas.at(1, 2)); // the band is inset
    try std.testing.expect(countColor(&bench.canvas, r, p.primary_ink) > 0);
    bench.canvas.fillAll(0x010101);
    menuItem(b, r, "Save", "", .{ .selected = true, .enabled = false });
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, r, p.primary)); // no band for a disabled row
    try std.testing.expect(countColor(&bench.canvas, r, p.text_muted) > 0);
    // A submenu row carries a caret at its right edge instead of a shortcut.
    bench.canvas.fillAll(0x010101);
    menuItem(b, r, "More", "", .{ .submenu = true });
    var caret_ink: usize = 0; // the caret is anti-aliased, so count any ink at the right edge
    for (0..r.h) |y| for (170..200) |x| {
        if (bench.canvas.at(x, y) != 0x010101) caret_ink += 1;
    };
    try std.testing.expect(caret_ink > 0);
    const sep: Rect = .{ .x = 0, .y = 30, .w = 200, .h = menuSeparatorHeight(b) };
    menuSeparator(b, sep);
    try std.testing.expectEqual(p.border, bench.canvas.at(100, 30 + sep.h / 2));
    try std.testing.expectEqual(@as(u32, 0x010101), bench.canvas.at(2, 30 + sep.h / 2));
}
