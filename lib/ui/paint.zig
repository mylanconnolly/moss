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
const flow = @import("flow.zig");
const palette = @import("palette.zig");

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
    return @max(b.line(), b.icon_px) + control.row_pad;
}
/// A button's natural size for its label and icon: the painter's own
/// insets (the icon, its gap, the horizontal padding), so a layout never
/// re-derives them.
pub fn buttonSize(b: Brush, label: []const u8, icon: ?icons.Icon) geometry.Size {
    const inset: usize = if (icon != null) b.icon_px + (if (label.len > 0) @as(usize, 8) else 0) else 0;
    return .{ .w = b.width(label) + inset + 2 * control.button_x, .h = controlHeight(b) };
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

pub const FieldStyle = struct {
    focused: bool = false,
    /// A password: every character shows as a dot.
    secret: bool = false,
};
/// Where a field's text starts inside its box, and the room it has: the
/// hit test that places a caret from a click uses the same two numbers.
pub const field_inset: usize = 8;
pub fn fieldRoom(w: usize) usize {
    return w -| (2 * field_inset + 4);
}
/// A single-line text field: an inset panel, the visible window of the
/// editor's text scrolled so the caret stays in view (`ed.first` is
/// advanced here and remembered), the selection as an inverted run, and
/// a caret bar when focused.
pub fn field(b: Brush, r: Rect, ed: *text.Editor, style: FieldStyle) void {
    const p = b.pal;
    const focused = style.focused;
    b.canvas.panel(r.x, r.y, r.w, r.h, control.radius, p.field_bg, if (focused) p.focus else p.border, if (focused) p.focus_w else p.border_w);
    const room = fieldRoom(r.w);
    var dots: [text.Editor.capacity]u8 = @splat('*');
    const shown: []const u8 = if (style.secret) dots[0..ed.len] else ed.buf[0..ed.len];
    ed.first = @min(ed.first, ed.cursor);
    while (ed.first < ed.cursor and b.width(shown[ed.first..ed.cursor]) > room) ed.first = ed.next(ed.first);
    var last = ed.first;
    while (last < ed.len) {
        const next = ed.next(last);
        if (b.width(shown[ed.first..next]) > room) break;
        last = next;
    }
    const x = r.x + field_inset;
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
        b.canvas.panel(cx, cy, c.w, c.h, control.radius_small, fill, ring, ring_w);
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
    return b.line() + control.row_pad;
}
/// The width a row wants for its label and its shortcut or caret, with
/// the painter's own insets — the popup's width comes from this, not from
/// a second reading of the painter.
pub fn menuItemWidth(b: Brush, label: []const u8, shortcut: []const u8, submenu: bool) usize {
    const extra: usize = if (submenu) @max(8, b.line() * 3 / 5) + 24 else if (shortcut.len > 0) b.width(shortcut) + 24 else 0;
    return b.width(label) + extra + 24;
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
    if (selected) b.canvas.fillRoundRect(r.x + 4, r.y, r.w -| 8, r.h, control.radius_small, bg);
    const ty = r.y + (r.h -| b.line()) / 2;
    const caret = if (style.submenu) @max(8, b.line() * 3 / 5) else 0;
    const sw = if (style.submenu) caret else b.width(shortcut);
    const gap: usize = if (sw > 0) 24 else 0;
    b.face.drawTrunc(b.canvas, r.x + 12, ty, .ui, label, r.w -| (24 + sw + gap), ink, bg);
    if (style.submenu) {
        if (caret + 24 < r.w) b.icon(.forward, caret, r.x + r.w - 12 - caret, r.y + (r.h -| caret) / 2, ink);
    } else if (sw > 0 and sw + 24 < r.w) b.face.draw(b.canvas, r.x + r.w - 12 - sw, ty, .ui, shortcut, ink, bg);
}

// ------------------------------------------------------------ list rows

pub const list_row_vpad: usize = 6; // vertical padding within a list row
pub const list_cell_pad: usize = 10; // left inset of the first cell
pub fn listRowHeight(b: Brush) usize {
    return b.line() + 2 * list_row_vpad;
}
/// A column: its title, its weight (a width in pixels, or a share of the
/// row when the list fits its columns), and whether its cells sit at the
/// right (numbers).
pub const Column = struct { title: []const u8 = "", weight: usize = 80, right: bool = false };
/// A cell: text, or a sparkline of permille samples (newest last).
pub const Cell = union(enum) { text: []const u8, samples: []const u16 };
/// Each column's pixel width: its weight as pixels, or — `fit` — a share
/// of `tracks_w` by weight (drift-free, like a row's flex tracks).
pub fn columnWidths(cols: []const Column, fit: bool, tracks_w: usize, out: []usize) void {
    var total: usize = 0;
    for (cols) |c| total += @max(c.weight, 1);
    var before: usize = 0;
    for (cols, 0..) |c, i| {
        const weight = @max(c.weight, 1);
        if (i < out.len) out[i] = if (fit) flow.trackWidth(tracks_w, total, before, weight) else weight;
        before += weight;
    }
}
/// The column titles, muted, the sorted one in full ink with a small
/// mark after it, over a rule. `r` is the header band across the list's
/// inner width; `widths` from `columnWidths`.
pub fn listHeader(b: Brush, r: Rect, cols: []const Column, widths: []const usize, sort: ?usize, ground: u32) void {
    std.debug.assert(widths.len >= cols.len);
    const p = b.pal;
    var hx = r.x + list_cell_pad;
    for (cols, 0..) |c, i| {
        const cw = widths[i];
        const sorted = sort == i;
        const mark_w: usize = if (sorted) 12 else 0;
        const offset = if (c.right) (cw -| 8) -| (b.width(c.title) + mark_w) else 0;
        b.face.drawTrunc(b.canvas, hx + offset, r.y + list_row_vpad, .ui, c.title, cw -| (8 + mark_w), if (sorted) p.text else p.text_muted, ground);
        if (sorted) {
            // A small triangle after the title.
            const tx = hx + offset + @min(b.width(c.title), cw -| (8 + mark_w)) + 5;
            const ty = r.y + list_row_vpad + b.line() / 2 - 1;
            b.canvas.fillRect(tx, ty, 7, 1, p.text);
            b.canvas.fillRect(tx + 1, ty + 1, 5, 1, p.text);
            b.canvas.fillRect(tx + 2, ty + 2, 3, 1, p.text);
            b.canvas.fillRect(tx + 3, ty + 3, 1, 1, p.text);
        }
        hx += cw;
    }
    b.canvas.fillRect(r.x, r.y + r.h -| p.border_w, r.w, p.border_w, p.border);
}
pub const ListRowStyle = struct {
    selected: bool = false,
    /// The list has the focus: a selected row takes the primary band;
    /// unfocused, the raised surface.
    focused: bool = false,
    icon: ?icons.Icon = null,
    ground: u32,
};
/// One row: the selection band, a leading icon, then the cells in their
/// columns (the first inset by the icon; `right` cells right-aligned;
/// a sparkline cell as bars on the row's ground). With no columns the
/// first cell spans the row.
pub fn listRow(b: Brush, r: Rect, cols: []const Column, widths: []const usize, cells: []const Cell, style: ListRowStyle) void {
    std.debug.assert(widths.len >= cols.len);
    const p = b.pal;
    const bg = if (style.selected) (if (style.focused) p.primary else p.surface_hi) else style.ground;
    if (style.selected) b.canvas.fillRect(r.x, r.y, r.w, r.h, bg);
    const ink = if (style.selected and style.focused) p.primary_ink else p.text;
    const icon_size = b.icon_px;
    const icon_pad: usize = if (style.icon != null) icon_size + 8 else 0;
    if (style.icon) |ic| b.icon(ic, icon_size, r.x + list_cell_pad, r.y + (r.h -| icon_size) / 2, if (style.selected and style.focused) p.primary_ink else p.primary);
    const ty = r.y + list_row_vpad;
    if (cols.len == 0) {
        const first = if (cells.len > 0 and cells[0] == .text) cells[0].text else "";
        b.face.drawTrunc(b.canvas, r.x + list_cell_pad + icon_pad, ty, .ui, first, r.w -| (2 * list_cell_pad + icon_pad), ink, bg);
        return;
    }
    var cx = r.x + list_cell_pad;
    for (cols, 0..) |c, ci| {
        const cw = widths[ci];
        const cell: Cell = if (ci < cells.len) cells[ci] else .{ .text = "" };
        switch (cell) {
            .samples => |samples| {
                // One bar per sample, newest at the right, on the row's ground.
                const n = samples.len;
                const sw = cw -| 12;
                const sh = b.line() -| 2;
                if (n > 0 and sw >= 8) {
                    const bw = @max(sw / @max(n, 30), 1);
                    for (samples, 0..) |sample, si| {
                        const v: usize = @min(sample, 1000); // the permille contract, kept here too
                        const bar = @max(sh * v / 1000, if (v > 0) @as(usize, 1) else 0);
                        if (bar == 0) continue;
                        const bx = cx + 4 + sw -| (n - si) * bw;
                        b.canvas.fillRect(bx, ty + 1 + sh - bar, bw, bar, if (v > 800) p.danger else if (style.selected and style.focused) p.primary_ink else p.primary);
                    }
                }
            },
            .text => |label| {
                const inset = if (ci == 0) icon_pad else 0;
                const offset = if (c.right) (cw -| 8) -| b.width(label) else inset;
                b.face.drawTrunc(b.canvas, cx + offset, ty, .ui, label, cw -| (8 + offset), if (ci > 0 and !style.selected) p.text_muted else ink, bg);
            },
        }
        cx += cw;
    }
}
/// A vertical scrollbar: a track and a thumb proportional to the visible
/// share, at `first` of `total` rows.
pub fn listScrollbar(b: Brush, r: Rect, visible: usize, total: usize, first: usize, ground: u32) void {
    const p = b.pal;
    b.canvas.fillRect(r.x, r.y, r.w, r.h, palette.shade(ground, 5, 4));
    if (total == 0) return;
    const thumb_h = @max(r.h * visible / total, 16);
    const span = r.h -| thumb_h;
    const max_first = total -| visible;
    const thumb_y = r.y + (if (max_first > 0) span * first / max_first else 0);
    b.canvas.fillRect(r.x + 1, thumb_y, r.w -| 2, thumb_h, p.text_muted);
}
/// A viewport's scrollbar, in pixels rather than rows: a rounded track
/// on the surface and a thumb proportional to the visible share, at
/// `offset` of `limit` (the farthest offset). The strip a viewport
/// reserves for it is `scrollbar_w`.
pub const scrollbar_w: usize = 14;
pub fn scrollbar(b: Brush, r: Rect, visible_h: usize, content_h: usize, offset: usize, limit: usize) void {
    const p = b.pal;
    const w: usize = @min(r.w, 6);
    const x = (r.x + r.w) -| (w + 2);
    b.canvas.fillRoundRect(x, r.y, w, r.h, w / 2, p.surface);
    const thumb = @min(r.h, @max(20, r.h * visible_h / @max(1, content_h)));
    const at = (r.h -| thumb) * offset / @max(1, limit);
    b.canvas.fillRoundRect(x, r.y + at, w, thumb, w / 2, p.text_muted);
}

// ---------------------------------------------------------- breadcrumbs

pub fn crumbHeight(b: Brush) usize {
    return b.line() + control.row_pad;
}
pub fn crumbWidth(b: Brush, label: []const u8, last: bool, width: usize) usize {
    return @min(width, b.width(label) + 20 + (if (last) @as(usize, 0) else 24));
}
/// Where each crumb sits in a strip of `width`: the same greedy flow the
/// painter and the hit test share.
pub fn crumbPlace(b: Brush, width: usize, labels: []const []const u8, index: usize) geometry.Placement {
    var line = flow.Flow{ .width = width, .gap = 4 };
    var place: geometry.Placement = .{ .x = 0, .y = 0, .w = 0 };
    for (labels, 0..) |label, i| {
        place = line.put(.{ .w = crumbWidth(b, label, i + 1 == labels.len, width), .h = crumbHeight(b) });
        if (i == index) return place;
    }
    return place;
}
/// The trail: each ancestor as a link in the focus colour with a "›"
/// after it, the last (the current place) in plain ink; the focused
/// ancestor on a raised panel with the focus ring. Returns the strip's
/// size (crumbs wrap when the strip is narrow).
pub fn breadcrumbs(b: Brush, r: Rect, labels: []const []const u8, focused: ?usize, ground: u32) geometry.Size {
    const p = b.pal;
    const h = crumbHeight(b);
    var line = flow.Flow{ .width = r.w, .gap = 4 };
    for (labels, 0..) |label, i| {
        const last = i + 1 == labels.len;
        const place = line.put(.{ .w = crumbWidth(b, label, last, r.w), .h = h });
        const label_w = place.w -| (if (last) @as(usize, 0) else 24);
        if (focused == i and !last) b.canvas.panel(r.x + place.x, r.y + place.y, label_w, h, control.radius_small, p.surface_hi, p.focus, p.focus_w);
        b.face.drawTrunc(b.canvas, r.x + place.x + 10, r.y + place.y + 8, .ui, label, label_w -| 20, if (last) p.text else p.focus, ground);
        if (!last and place.w >= 24) b.face.draw(b.canvas, r.x + place.x + place.w - 19, r.y + place.y + 8, .ui, "›", p.text_muted, ground);
    }
    return line.size();
}
/// The ancestor under (x, y), strip-local, or null (the last crumb is
/// the current place, not a link).
pub fn breadcrumbHit(b: Brush, width: usize, labels: []const []const u8, x: usize, y: usize) ?usize {
    for (labels, 0..) |_, i| {
        if (i + 1 == labels.len) break;
        const place = crumbPlace(b, width, labels, i);
        if (x >= place.x and x < place.x + (place.w -| 24) and y >= place.y and y < place.y + crumbHeight(b)) return i;
    }
    return null;
}

// -------------------------------------------------------- meters, charts

/// One meter row: its label and its reading in permille.
pub const Meter = struct { label: []const u8, value: u16 };
pub fn meterRowHeight(b: Brush) usize {
    return b.line() + 4;
}
/// Stacked meters: the label at the left, a rounded bar filled to the
/// reading in the primary colour (danger past 80%), the percentage at
/// the right. Each row a text line tall; `r.w` is the row width.
pub fn meters(b: Brush, r: Rect, rows: []const Meter, ground: u32) void {
    const p = b.pal;
    const line = b.line();
    const row_h = meterRowHeight(b);
    var label_w: usize = b.width("C00");
    for (rows) |m| label_w = @max(label_w, b.width(m.label));
    label_w += 8;
    const caption_w = b.width("100%") + 6;
    const bar_x = r.x + label_w;
    const bar_w = r.w -| (label_w + caption_w);
    const bar_h = @max(line / 2, 6);
    for (rows, 0..) |m, i| {
        const ry = r.y + i * row_h;
        const v: usize = @min(m.value, 1000);
        b.face.drawTrunc(b.canvas, r.x, ry, .ui, m.label, label_w -| 4, p.text_muted, ground);
        const by = ry + (line -| bar_h) / 2;
        b.canvas.fillRoundRect(bar_x, by, bar_w, bar_h, bar_h / 2, p.surface_hi);
        const filled = bar_w * v / 1000;
        if (filled > 0) b.canvas.fillRoundRect(bar_x, by, @max(filled, bar_h), bar_h, bar_h / 2, if (v > 800) p.danger else p.primary);
        var cb: [8]u8 = undefined;
        const caption = std.fmt.bufPrint(&cb, "{d}%", .{v / 10}) catch "";
        b.face.drawTrunc(b.canvas, bar_x + bar_w + caption_w -| b.width(caption), ry, .ui, caption, caption_w, p.text, ground);
    }
}

/// A history chart: an inset panel with the title (muted) at the left
/// and the current reading at the right, a grid at quarters, and one
/// bar per permille sample, newest at the right edge — a young history
/// grows in from the right (30 slots at least). Loads past 80% paint in
/// the danger colour.
pub fn chart(b: Brush, r: Rect, title: []const u8, caption: []const u8, samples: []const u16) void {
    const p = b.pal;
    const line = b.line();
    b.canvas.panel(r.x, r.y, r.w, r.h, control.radius, p.field_bg, p.border, p.border_w);
    b.face.drawTrunc(b.canvas, r.x + 10, r.y + 6, .ui, title, r.w / 2, p.text_muted, p.field_bg);
    b.face.drawTrunc(b.canvas, r.x + r.w -| (10 + b.width(caption)), r.y + 6, .ui, caption, r.w / 2, p.text, p.field_bg);
    const px = r.x + 10;
    const py = r.y + line + 12;
    const pw = r.w -| 20;
    const ph = (r.y + r.h -| 8) -| py;
    if (ph < 8 or pw < 8) return;
    for (1..4) |q| b.canvas.fillRect(px, py + ph * q / 4, pw, 1, p.border);
    const n = samples.len;
    if (n == 0) return;
    const slots = @max(n, 30);
    const cw = @max(pw / slots, 1);
    const fill = palette.shade(p.primary, 2, 5);
    for (samples, 0..) |sample, i| {
        const v: usize = @min(sample, 1000);
        const bar = ph * v / 1000;
        const cx = px + pw -| (n - i) * cw;
        if (bar > 0) {
            const ink = if (v > 800) p.danger else p.primary;
            b.canvas.fillRect(cx, py + ph - bar, cw, bar, if (v > 800) palette.shade(p.danger, 2, 5) else fill);
            b.canvas.fillRect(cx, py + ph - bar, cw, @min(2, bar), ink);
        }
    }
}

// ------------------------------------------------------------ wrapped text

/// Break `text` into lines no wider than `width`: at newlines, else at
/// the last space that fits, else inside a word on a UTF-8 boundary (a
/// word longer than the line). Each line found is written to `out`;
/// returns how many (capped at `out.len`). The search is a binary one
/// over measured prefixes, so a long paragraph costs logarithmically
/// many measurements per line — a measurement is a font-service round
/// trip in the frame.
pub fn wrapText(b: Brush, s: []const u8, width: usize, out: [][]const u8) usize {
    var n: usize = 0;
    var start: usize = 0;
    while (start < s.len and n < out.len) {
        const line_end = if (std.mem.indexOfScalarPos(u8, s, start, '\n')) |at| at else s.len;
        var end = line_end;
        if (b.width(s[start..end]) > width) {
            var lo = start;
            var hi = end;
            while (lo < hi) {
                var mid = lo + (hi - lo + 1) / 2;
                while (mid < line_end and s[mid] & 0xc0 == 0x80) mid += 1;
                if (b.width(s[start..mid]) <= width) lo = mid else {
                    hi = mid - 1;
                    while (hi > start and s[hi] & 0xc0 == 0x80) hi -= 1;
                }
            }
            end = lo;
            if (end == start) end = @min(line_end, start + (std.unicode.utf8ByteSequenceLength(s[start]) catch 1));
            if (end < line_end) {
                if (std.mem.lastIndexOfScalar(u8, s[start..end], ' ')) |at| if (at > 0) {
                    end = start + at;
                };
            }
        }
        out[n] = s[start..end];
        n += 1;
        start = end;
        if (start < s.len and s[start] == '\n') start += 1 else while (start < s.len and s[start] == ' ') {
            start += 1;
        }
    }
    return n;
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

/// What a press at (x, y) on the strip means, using the same layout the
/// strip was painted with.
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
    field(b, r, &ed, .{});
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, r, b.pal.focus)); // no caret, no focus ring
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.text) > 0);
    ed.apply(.select_all);
    field(b, r, &ed, .{ .focused = true });
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.primary) > 0); // the selection band
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.primary_ink) > 0); // inverted text
    try std.testing.expect(countColor(&bench.canvas, r, b.pal.focus) > 0); // caret + ring
    // A long text scrolls so the caret stays visible: `first` advances.
    ed.seed("0123456789012345678901234567890123456789");
    field(b, r, &ed, .{ .focused = true });
    try std.testing.expect(ed.first > 0);
    // A secret field paints dots, never the text.
    bench.canvas.fillAll(0x010101);
    ed.seed("hunter2");
    field(b, r, &ed, .{ .secret = true });
    const dots_ink = countColor(&bench.canvas, r, b.pal.text);
    bench.canvas.fillAll(0x010101);
    ed.seed("*******");
    field(b, r, &ed, .{});
    try std.testing.expectEqual(dots_ink, countColor(&bench.canvas, r, b.pal.text));
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

test "a list header marks the sorted column and rules below; a row bands its selection and right-aligns" {
    var bench: Bench = .{};
    const b = bench.brush();
    const p = b.pal;
    const cols = [_]Column{ .{ .title = "Name", .weight = 100 }, .{ .title = "Size", .weight = 80, .right = true } };
    var widths: [2]usize = undefined;
    columnWidths(&cols, false, 0, &widths);
    try std.testing.expectEqual([2]usize{ 100, 80 }, widths);
    columnWidths(&cols, true, 180, &widths);
    try std.testing.expectEqual(@as(usize, 180), widths[0] + widths[1]);
    const hr: Rect = .{ .x = 0, .y = 0, .w = 200, .h = listRowHeight(b) };
    listHeader(b, hr, &cols, &widths, 1, 0x010101);
    try std.testing.expectEqual(p.border, bench.canvas.at(100, hr.h - 1)); // the rule
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 0, .y = 0, .w = 100, .h = hr.h }, p.text_muted) > 0); // Name, unsorted
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 100, .y = 0, .w = 100, .h = hr.h }, p.text) > 0); // Size, sorted (+ its mark)
    bench.canvas.fillAll(0x010101);
    const rr: Rect = .{ .x = 0, .y = 0, .w = 200, .h = listRowHeight(b) };
    const cells = [_]Cell{ .{ .text = "notes" }, .{ .text = "12" } };
    listRow(b, rr, &cols, &widths, &cells, .{ .selected = true, .focused = true, .ground = 0x010101 });
    try std.testing.expectEqual(p.primary, bench.canvas.at(5, 2)); // the band
    try std.testing.expect(countColor(&bench.canvas, rr, p.primary_ink) > 0);
    // Right-aligned: the size's ink ends near the right edge of its column.
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 100 + 50, .y = 0, .w = 30, .h = rr.h }, p.primary_ink) > 0);
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, .{ .x = 100 + 8, .y = 0, .w = 20, .h = rr.h }, p.primary_ink));
    // Unselected: text ink on the ground, second column muted.
    bench.canvas.fillAll(0x010101);
    listRow(b, rr, &cols, &widths, &cells, .{ .ground = 0x010101 });
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 0, .y = 0, .w = 100, .h = rr.h }, p.text) > 0);
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 100, .y = 0, .w = 100, .h = rr.h }, p.text_muted) > 0);
    // A sparkline cell draws bars in the primary colour, high ones in danger.
    bench.canvas.fillAll(0x010101);
    const samples = [_]u16{ 100, 500, 900 };
    const spark = [_]Cell{ .{ .text = "cpu" }, .{ .samples = &samples } };
    listRow(b, rr, &cols, &widths, &spark, .{ .ground = 0x010101 });
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 100, .y = 0, .w = 100, .h = rr.h }, p.primary) > 0);
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 100, .y = 0, .w = 100, .h = rr.h }, p.danger) > 0);
    // The scrollbar's thumb is proportional and at the top for `first` 0.
    bench.canvas.fillAll(0x010101);
    listScrollbar(b, .{ .x = 190, .y = 0, .w = 8, .h = 60 }, 10, 40, 0, 0x010101);
    try std.testing.expectEqual(p.text_muted, bench.canvas.at(194, 2));
    try std.testing.expect(bench.canvas.at(194, 50) != p.text_muted);
}

test "breadcrumbs flow, link every ancestor, ring the focused one, and hit-test the same places" {
    var bench: Bench = .{};
    const b = bench.brush();
    const p = b.pal;
    const labels = [_][]const u8{ "Home", "docs", "notes" };
    // The fixed face is 8 px a glyph, so three crumbs need ~220 px: a
    // 300 px strip (wider than the canvas; drawing clips) keeps one line.
    const size = breadcrumbs(b, .{ .x = 0, .y = 0, .w = 300, .h = 60 }, &labels, 0, 0x010101);
    try std.testing.expectEqual(crumbHeight(b), size.h); // one line
    const all: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 60 };
    try std.testing.expect(countColor(&bench.canvas, all, p.focus) > 0); // links + the ring
    const first = crumbPlace(b, 300, &labels, 0);
    try std.testing.expectEqual(p.focus, bench.canvas.at(first.x + first.w / 2, 0)); // the ring's top edge
    try std.testing.expectEqual(@as(?usize, 0), breadcrumbHit(b, 300, &labels, first.x + 4, 4));
    const second = crumbPlace(b, 300, &labels, 1);
    try std.testing.expectEqual(@as(?usize, 1), breadcrumbHit(b, 300, &labels, second.x + 4, 4));
    const last = crumbPlace(b, 300, &labels, 2);
    try std.testing.expectEqual(@as(?usize, null), breadcrumbHit(b, 300, &labels, last.x + 4, 4)); // not a link
    // Too narrow for one line: the strip wraps.
    try std.testing.expect(breadcrumbs(b, .{ .x = 0, .y = 0, .w = 70, .h = 60 }, &labels, null, 0x010101).h > crumbHeight(b));
}

test "meters fill to their reading, turn to danger past 80%, and caption the percentage; a chart bars its history" {
    var bench: Bench = .{};
    const b = bench.brush();
    const p = b.pal;
    const rows = [_]Meter{ .{ .label = "C0", .value = 500 }, .{ .label = "C1", .value = 950 } };
    const r: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 60 };
    meters(b, r, &rows, 0x010101);
    const row_h = meterRowHeight(b);
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 0, .y = 0, .w = 200, .h = row_h }, p.primary) > 0);
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, .{ .x = 0, .y = 0, .w = 200, .h = row_h }, p.danger));
    try std.testing.expect(countColor(&bench.canvas, .{ .x = 0, .y = row_h, .w = 200, .h = row_h }, p.danger) > 0);
    // The half-full bar's fill ends before the track does.
    const track_end = 200 - (b.width("100%") + 6);
    try std.testing.expect(countColor(&bench.canvas, .{ .x = track_end - 20, .y = 0, .w = 10, .h = row_h }, p.surface_hi) > 0);
    try std.testing.expect(countColor(&bench.canvas, r, p.text) > 0); // the captions
    bench.canvas.fillAll(0x010101);
    const samples = [_]u16{ 200, 600, 900 };
    const cr: Rect = .{ .x = 0, .y = 0, .w = 200, .h = 60 };
    chart(b, cr, "cpu", "90%", &samples);
    try std.testing.expectEqual(p.border, bench.canvas.at(100, 0)); // the panel's edge
    try std.testing.expect(countColor(&bench.canvas, cr, p.primary) > 0); // bar tops
    try std.testing.expect(countColor(&bench.canvas, cr, p.danger) > 0); // the 90% sample
    // Bars sit at the right edge: the left half of the plot has none.
    try std.testing.expectEqual(@as(usize, 0), countColor(&bench.canvas, .{ .x = 10, .y = 30, .w = 80, .h = 20 }, p.primary));
}

test "a button's size is the painter's own insets and a menu row's width its own" {
    var bench: Bench = .{};
    const b = bench.brush();
    const plain = buttonSize(b, "Open", null);
    try std.testing.expectEqual(controlHeight(b), plain.h);
    try std.testing.expectEqual(b.width("Open") + 2 * control.button_x, plain.w);
    try std.testing.expectEqual(plain.w + b.icon_px + 8, buttonSize(b, "Open", .up).w);
    try std.testing.expectEqual(b.icon_px + 2 * control.button_x, buttonSize(b, "", .up).w); // icon only: no gap
    try std.testing.expect(menuItemWidth(b, "Save", "Cmd S", false) > menuItemWidth(b, "Save", "", false));
    try std.testing.expect(menuItemWidth(b, "More", "", true) > menuItemWidth(b, "More", "", false));
    // A viewport scrollbar: track on the surface, thumb at the top for offset 0.
    bench.canvas.fillAll(0x010101);
    scrollbar(b, .{ .x = 180, .y = 0, .w = scrollbar_w, .h = 60 }, 30, 120, 0, 90);
    try std.testing.expectEqual(b.pal.text_muted, bench.canvas.at(189, 5));
    try std.testing.expectEqual(b.pal.surface, bench.canvas.at(189, 50));
}

test "wrapped text breaks at spaces, then inside long words on a UTF-8 boundary, and at newlines" {
    var bench: Bench = .{};
    const b = bench.brush(); // 8 px a glyph
    var lines: [8][]const u8 = undefined;
    var n = wrapText(b, "the quick brown fox", 80, &lines); // 10 glyphs a line
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("the quick", lines[0]);
    try std.testing.expectEqualStrings("brown fox", lines[1]);
    n = wrapText(b, "abcdefghijklmnop", 64, &lines); // 8 glyphs: no space to break at
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqualStrings("abcdefgh", lines[0]);
    n = wrapText(b, "a\nb", 800, &lines);
    try std.testing.expectEqual(@as(usize, 2), n);
    n = wrapText(b, "ééééé", 24, &lines); // 3 glyphs a line; é is two bytes
    try std.testing.expectEqualStrings("ééé", lines[0]);
    try std.testing.expectEqual(@as(usize, 2), n);
    try std.testing.expectEqual(@as(usize, 1), wrapText(b, "x", 8, lines[0..1]));
}
