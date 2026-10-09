//! The desktop's top bar: a resident, titleless strip along the top edge
//! that hosts the system menu, the focused application's global menus
//! (published by the compositor) and the clock, with popup surfaces for
//! open menus — a dropdown and, beside it, one nested submenu — and
//! keyboard navigation through them. A `gui { bar: true }` app in mshl
//! runs here; the layout of its items is data, the popups and the menu
//! protocol are this file's. Split out of guicmds.zig, which keeps the
//! window runtime, the widget painters and the input loop.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mshl = @import("mosslib").mshl;
const ui = @import("mosslib").ui;
const wf = @import("windowframe.zig");
const menuctl = @import("menuctl.zig");
const core = @import("guicmds.zig");
const R_UI = core.R_UI;
const Value = core.Value;
const declareStrut = core.declareStrut;
const drawIconLabel = core.drawIconLabel;
const drawStr = core.drawStr;
const drawStrTrunc = core.drawStrTrunc;
const fillAll = core.fillAll;
const fillRect = core.fillRect;
const iconLabelWidth = core.iconLabelWidth;
const isDone = core.isDone;
const lineOf = core.lineOf;
const pal = core.pal;
const panel = core.panel;
const strField = core.strField;
const strW = core.strW;

// -------------------------------------------------------------- the top bar
//
// A resident menu bar pinned at the top of the scanout: menu titles at the
// left, right-aligned items (a live clock) at the right. A menu opens a
// DROPDOWN — a second, transient surface, because moss surfaces are opaque,
// so a menu overlaying windows must be its own surface; it is dismissed on a
// selection, a click elsewhere, or Escape. An item that opens a nested
// menu opens a third surface beside the dropdown. The bar's `view(state)`
// returns `{ left: [...], right: [...] }` of `{kind:menu,...}` /
// `{kind:label,...}`; a selected item fires `update(state, { menu, item })`.
// Windows open below the bar (a strut it declares to the compositor), so it
// is never covered.
//
// Three kinds of menu share the popups: the script's own (declarative,
// labels are events), an application's catalog profile (shared/menus.zig,
// items are keys the compositor routes), and an application's custom
// menus (titles and labels read back from the compositor, items are
// application keys routed the same way — the only kind with submenus).

pub const bar_vpad = 8;
const menu_hpad = 12;

const MenuHit = struct {
    id: []const u8,
    bx: usize,
    bw: usize,
    items: []const Value = &.{},
    app_items: []const shared.menus.Item = &.{},
    /// A custom menu's slot (its items come from `bar_custom`).
    slot: ?u8 = null,
};
var bar_menus: [12]MenuHit = undefined;
var bar_nmenus: usize = 0;
var bar_app: menuctl.ActiveMenu = .{};
var bar_app_name: [shared.window_title_bytes]u8 = @splat(0);

/// The focused application's custom menus, read from the compositor when
/// its token changes and owned here (a popup never borrows wire data).
const CustomCache = struct {
    token: u64 = 0,
    titles: [shared.menus.max_menus][shared.menus.title_bytes]u8 = @splat(@splat(0)),
    title_len: [shared.menus.max_menus]u8 = @splat(0),
    /// Slots some item opens: not top-level titles.
    is_sub: [shared.menus.max_menus]bool = @splat(false),
    items: [shared.menus.max_app_items]menuctl.CustomItem = @splat(.{}),
};
var bar_custom: CustomCache = .{};
fn loadCustom(token: u64) void {
    bar_custom = .{ .token = token };
    for (0..shared.menus.max_menus) |slot| {
        bar_custom.titles[slot] = menuctl.menuSlot(token, @intCast(slot));
        bar_custom.title_len[slot] = @intCast(std.mem.sliceTo(&bar_custom.titles[slot], 0).len);
    }
    var slots: usize = 0;
    var items: usize = 0;
    for (0..shared.menus.max_menus) |slot| slots += @intFromBool(bar_custom.title_len[slot] > 0);
    for (0..shared.menus.max_app_items) |i| {
        bar_custom.items[i] = menuctl.menuItem(token, @intCast(i));
        const sub = bar_custom.items[i].sub;
        if (bar_custom.items[i].used and sub > 0 and sub <= shared.menus.max_menus) bar_custom.is_sub[sub - 1] = true;
        items += @intFromBool(bar_custom.items[i].used);
    }
    var lb: [80]u8 = undefined;
    _ = usys.log(core.log_h, std.fmt.bufPrint(&lb, "topbar: custom menus slots={d} items={d}", .{ slots, items }) catch "topbar: custom menus");
}

// Popup labels are owned: refreshing the script view must never leave a
// dropdown referring to a reclaimed interpreter value.
const PopupItem = struct {
    label: [128]u8 = @splat(0),
    len: usize = 0,
    shortcut: []const u8 = "",
    key: u8 = 0,
    enabled: bool = true,
    separator: bool = false,
    /// A declarative bar item's runtime action (`{ text, action }`), not
    /// an event for the script: today only "launcher".
    launcher: bool = false,
    /// The custom menu slot this row opens (1-based), 0 for none.
    sub: u8 = 0,
};
/// One popup surface: the dropdown (level 0) or a submenu beside its
/// parent (levels 1 and up). Rows beyond the room scroll: `first` is the
/// top row shown, with arrow strips above and below when there is more.
/// Rows a popup can hold: a custom menu's 32 items, or a declarative
/// menu's (the long ones scroll).
const max_rows = 64;
const Popup = struct {
    entries: [max_rows]PopupItem = undefined,
    count: usize = 0,
    selected: ?usize = null,
    first: usize = 0,
    surf: u64 = 0,
    px: [*]volatile u32 = undefined,
    cap: u64 = 0,
    va: u64 = 0,
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,
    open: bool = false,
    menu_id: []const u8 = "",
    /// The row of the level-0 popup this submenu hangs off.
    parent: usize = 0,
};
/// The dropdown and up to three nested submenus beside it.
const max_levels = 4;
var pops: [max_levels]Popup = @splat(.{});
/// Which popup the keyboard drives: the deepest open submenu.
var active_level: usize = 0;
var pop_app_token: u64 = 0;
var pop_focus_token: u64 = 0;
var pop_item_h: usize = 0;

fn barItemWidth(item: Value) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const menu = std.mem.eql(u8, strField(rec, "kind"), "menu");
    return (if (menu) iconLabelWidth(rec, "title") else strW(R_UI, strField(rec, "text"))) + 2 * menu_hpad;
}

fn anyOpen() bool {
    return pops[0].open;
}
fn openMenuIs(id: []const u8) bool {
    return pops[0].open and std.mem.eql(u8, pops[0].menu_id, id);
}

fn drawBarItem(item: Value, x: usize, cy: usize) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const width = barItemWidth(item);
    if (std.mem.eql(u8, strField(rec, "kind"), "menu")) {
        const id = strField(rec, "id");
        const bg = if (openMenuIs(id)) pal.surface_hi else pal.surface;
        fillRect(x, 0, width, wf.win_h - pal.border_w, bg);
        drawIconLabel(rec, "title", x + menu_hpad, 0, width - 2 * menu_hpad, wf.win_h - pal.border_w, pal.title, bg);
        if (bar_nmenus < bar_menus.len) {
            const items: []const Value = if (rec.get("items")) |iv| (if (iv == .list) iv.list else &.{}) else &.{};
            bar_menus[bar_nmenus] = .{ .id = id, .bx = x, .bw = width, .items = items };
            bar_nmenus += 1;
        }
    } else {
        const muted = if (rec.get("muted")) |v| v.asBool() else false;
        drawStr(x + menu_hpad, cy, R_UI, strField(rec, "text"), if (muted) pal.text_muted else pal.text, pal.surface);
    }
    return width;
}

/// A menu title cell for an application menu (catalog or custom).
fn drawTitleCell(title: []const u8, x: usize, cy: usize) usize {
    const width = strW(R_UI, title) + 2 * menu_hpad;
    const bg = if (openMenuIs(title)) pal.surface_hi else pal.surface;
    fillRect(x, 0, width, wf.win_h - pal.border_w, bg);
    drawStr(x + menu_hpad, cy, R_UI, title, pal.text, bg);
    return width;
}

fn renderBar(tree: Value) void {
    bar_nmenus = 0;
    fillAll(pal.surface);
    fillRect(0, wf.win_h - pal.border_w, wf.win_w, pal.border_w, pal.border);
    const cy = (wf.win_h -| lineOf(R_UI)) / 2;
    if (tree != .record) return;
    const rec = tree.record;
    var x: usize = menu_hpad / 2;
    // App commands take precedence over transient system-menu status text.
    if (rec.get("left")) |lv| if (lv == .list) for (lv.list) |item| {
        if (item != .record) continue;
        if (bar_app.token != 0 and !std.mem.eql(u8, strField(item.record, "kind"), "menu")) continue;
        x += drawBarItem(item, x, cy);
    };
    if (bar_app.token != 0) {
        const menus = shared.menus.catalog(bar_app.profile);
        var menu_width: usize = 0;
        if (bar_app.profile == .custom) for (0..shared.menus.max_menus) |slot| {
            if (bar_custom.title_len[slot] > 0 and !bar_custom.is_sub[slot]) menu_width += strW(R_UI, bar_custom.titles[slot][0..bar_custom.title_len[slot]]) + 2 * menu_hpad;
        };
        for (menus) |menu| menu_width += strW(R_UI, menu.title) + 2 * menu_hpad;
        const name = std.mem.sliceTo(&bar_app_name, 0);
        const available = wf.win_w -| (x + menu_width + menu_hpad);
        const name_width = @min(strW(R_UI, name) + 2 * menu_hpad, available);
        if (name_width > 2 * menu_hpad) drawStrTrunc(x + menu_hpad, cy, R_UI, name, name_width - 2 * menu_hpad, pal.title, pal.surface);
        x += name_width;
        // The app's own menus first (its top-level slots, in slot order),
        // then the catalog's (Window) for a custom profile.
        if (bar_app.profile == .custom) for (0..shared.menus.max_menus) |slot| {
            if (bar_custom.title_len[slot] == 0 or bar_custom.is_sub[slot]) continue;
            const title = bar_custom.titles[slot][0..bar_custom.title_len[slot]];
            const width = strW(R_UI, title) + 2 * menu_hpad;
            if (x + width > wf.win_w or bar_nmenus == bar_menus.len) break;
            _ = drawTitleCell(title, x, cy);
            bar_menus[bar_nmenus] = .{ .id = title, .bx = x, .bw = width, .slot = @intCast(slot) };
            bar_nmenus += 1;
            x += width;
        };
        for (menus) |menu| {
            const width = strW(R_UI, menu.title) + 2 * menu_hpad;
            if (x + width > wf.win_w or bar_nmenus == bar_menus.len) break;
            _ = drawTitleCell(menu.title, x, cy);
            bar_menus[bar_nmenus] = .{ .id = menu.title, .bx = x, .bw = width, .app_items = menu.items };
            bar_nmenus += 1;
            x += width;
        }
    }
    // Drop the date first, then the clock, instead of overlapping menus
    // when large text or a narrow display leaves insufficient space.
    if (rec.get("right")) |rv| if (rv == .list) {
        var rx = wf.win_w -| menu_hpad;
        var i = rv.list.len;
        while (i > 0) {
            i -= 1;
            const width = barItemWidth(rv.list[i]);
            if (rx < x + width + menu_hpad) break;
            rx -= width;
            _ = drawBarItem(rv.list[i], rx, cy);
        }
    };
}

fn menuAt(lx: usize) ?usize {
    for (bar_menus[0..bar_nmenus], 0..) |m, i| {
        if (lx >= m.bx and lx < m.bx + m.bw) return i;
    }
    return null;
}

// ------------------------------------------------------------- popups

const pop_margin: usize = 4;
fn arrowHeight() usize {
    return pop_item_h / 2;
}
fn popEntryHeight(p: *const Popup, index: usize) usize {
    return if (p.entries[index].separator) ui.paint.menuSeparatorHeight(wf.brush()) else pop_item_h;
}
/// Rows from `first` that fit the popup's height (its surface is sized
/// once; scrolling changes which rows show, not the surface).
fn popVisible(p: *const Popup) usize {
    var y: usize = pop_margin + (if (p.first > 0) arrowHeight() else 0);
    var n: usize = 0;
    while (p.first + n < p.count) : (n += 1) {
        const more_after = p.first + n + 1 < p.count;
        const tail = pop_margin + (if (more_after) arrowHeight() else 0);
        if (y + popEntryHeight(p, p.first + n) + tail > p.h) break;
        y += popEntryHeight(p, p.first + n);
    }
    return n;
}
/// A shown row's top, popup-local.
fn popEntryY(p: *const Popup, index: usize) usize {
    var y: usize = pop_margin + (if (p.first > 0) arrowHeight() else 0);
    for (p.first..index) |i| y += popEntryHeight(p, i);
    return y;
}
const PopHit = union(enum) { none, up, down, entry: usize };
fn popHitAt(p: *const Popup, ly: usize) PopHit {
    const visible = popVisible(p);
    if (p.first > 0 and ly < pop_margin + arrowHeight()) return .up;
    var y: usize = pop_margin + (if (p.first > 0) arrowHeight() else 0);
    for (p.first..p.first + visible) |i| {
        const height = popEntryHeight(p, i);
        if (ly >= y and ly < y + height) return if (p.entries[i].enabled and !p.entries[i].separator) .{ .entry = i } else .none;
        y += height;
    }
    if (p.first + visible < p.count and ly >= y) return .down;
    return .none;
}
/// The whole height the rows want (no scrolling).
fn popNaturalHeight(p: *const Popup) usize {
    var h: usize = 2 * pop_margin;
    for (0..p.count) |i| h += popEntryHeight(p, i);
    return h;
}

fn drawArrow(x: usize, y: usize, w: usize, h: usize, down: bool) void {
    // A small triangle, centred: rows of growing width.
    const size = @min(h -| 2, 8);
    const cx = x + w / 2;
    const top = y + (h -| size) / 2;
    for (0..size) |i| {
        const half = if (down) size - i else i + 1;
        fillRect(cx -| half, top + i, 2 * half, 1, pal.text_muted);
    }
}

fn renderPopup(p: *Popup) void {
    // The popup is its own surface: its own size and its own clip. (Painting
    // it through the bar's clip left every row below the bar's height black.)
    const saved = wf.retarget(p.px, p.w, p.h);
    defer wf.restoreTarget(saved);
    panel(0, 0, p.w, p.h, 8, pal.surface, pal.border, pal.border_w);
    // The rows are the toolkit's (`paint.menuItem`), so a popup here and
    // any other menu a program paints are the same rows.
    const b = wf.brush();
    const visible = popVisible(p);
    if (p.first > 0) drawArrow(0, pop_margin, p.w, arrowHeight(), false);
    for (p.first..p.first + visible) |i| {
        const entry = p.entries[i];
        const row: ui.Rect = .{ .x = 0, .y = popEntryY(p, i), .w = p.w, .h = popEntryHeight(p, i) };
        if (entry.separator) {
            ui.paint.menuSeparator(b, row);
            continue;
        }
        ui.paint.menuItem(b, row, entry.label[0..entry.len], entry.shortcut, .{ .selected = p.selected == i, .enabled = entry.enabled, .submenu = entry.sub != 0 });
    }
    if (p.first + visible < p.count) drawArrow(0, p.h -| (pop_margin + arrowHeight()), p.w, arrowHeight(), true);
}

fn commitPopup(p: *Popup) void {
    if (!p.open) return;
    renderPopup(p);
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .commit = .{ .surface = p.surf, .xy = 0, .wh = shared.packPair(@intCast(p.w), @intCast(p.h)) } }, 0);
}

/// Scroll so the selected row is shown.
fn revealSelection(p: *Popup) void {
    const sel = p.selected orelse return;
    const before = p.first;
    if (sel < p.first) p.first = sel;
    while (p.first < sel and sel >= p.first + popVisible(p)) p.first += 1;
    if (p.first != before) logScroll(p);
}
fn moveSelection(p: *Popup, forward: bool) void {
    if (p.count == 0) return;
    var idx = p.selected orelse (if (forward) p.count - 1 else 0);
    for (0..p.count) |_| {
        idx = (idx + (if (forward) @as(usize, 1) else p.count - 1)) % p.count;
        if (p.entries[idx].enabled and !p.entries[idx].separator) {
            p.selected = idx;
            break;
        }
    }
    revealSelection(p);
    commitPopup(p);
}
fn scrollPopup(p: *Popup, delta: isize) void {
    const max_first = p.count -| 1;
    const next: isize = @as(isize, @intCast(p.first)) + delta;
    p.first = @intCast(std.math.clamp(next, 0, @as(isize, @intCast(max_first))));
    // Never scroll past the point where the last row shows.
    while (p.first > 0 and p.first + popVisible(p) >= p.count and popVisible(p) < p.count) {
        var probe = p.*;
        probe.first -= 1;
        if (probe.first + popVisible(&probe) < p.count) break;
        p.first -= 1;
    }
    logScroll(p);
    commitPopup(p);
}
fn logScroll(p: *const Popup) void {
    var lb: [64]u8 = undefined;
    _ = usys.log(core.log_h, std.fmt.bufPrint(&lb, "topbar: scrolled first={d} of {d}", .{ p.first, p.count }) catch "topbar: scrolled");
}

fn setEntryLabel(entry: *PopupItem, label: []const u8) void {
    entry.len = @min(label.len, entry.label.len);
    @memcpy(entry.label[0..entry.len], label[0..entry.len]);
}

/// Fill a popup's rows from a bar menu: a custom slot, a catalog menu, or
/// the script's declarative items.
fn fillFromMenu(p: *Popup, m: MenuHit) void {
    p.count = 0;
    p.selected = null;
    p.first = 0;
    if (m.slot) |slot| {
        fillFromSlot(p, slot);
        return;
    }
    const n = @min(if (m.app_items.len > 0) m.app_items.len else m.items.len, p.entries.len);
    for (0..n) |i| {
        var entry: PopupItem = .{};
        // A bar item is a string (an event for the script) or a record
        // `{ text, action }` whose action the runtime performs itself.
        const label = if (m.app_items.len > 0) m.app_items[i].label else if (m.items[i] == .str) m.items[i].str else if (m.items[i] == .record) strField(m.items[i].record, "text") else "";
        if (m.app_items.len == 0 and m.items[i] == .record) entry.launcher = std.mem.eql(u8, strField(m.items[i].record, "action"), "launcher");
        if (m.app_items.len == 0 and std.mem.eql(u8, label, "-")) entry.separator = true; // a rule between groups
        setEntryLabel(&entry, label);
        if (m.app_items.len > 0) {
            const item = m.app_items[i];
            entry.key = item.key;
            entry.shortcut = item.shortcut;
            entry.separator = item.key == 0;
            entry.enabled = shared.menus.allows(bar_app.profile, bar_app.enabled, item.key);
        }
        p.entries[p.count] = entry;
        p.count += 1;
    }
}
/// A custom menu slot's rows, in published order: a key item, a rule, or
/// a submenu header.
fn fillFromSlot(p: *Popup, slot: u8) void {
    for (&bar_custom.items) |*item| {
        if (!item.used or item.menu != slot or p.count == p.entries.len) continue;
        var entry: PopupItem = .{ .key = item.key, .sub = item.sub };
        setEntryLabel(&entry, item.label[0..item.label_len]);
        entry.shortcut = item.shortcut[0..item.shortcut_len]; // the owned cache outlives the popup
        entry.separator = item.key == 0 and item.sub == 0;
        entry.enabled = item.sub != 0 or (item.key != 0 and shared.menus.allows(.custom, bar_app.enabled, item.key));
        p.entries[p.count] = entry;
        p.count += 1;
    }
}

/// Create the popup's surface at (x, y) with the rows it holds, sized to
/// them or to `avail_h` when they overflow (then they scroll).
fn openPopupAt(p: *Popup, level: usize, x: usize, y_wanted: usize, avail_h: usize) void {
    if (p.open) closePopup(p);
    if (p.count == 0) return;
    for (0..p.count) |i| if (p.selected == null and p.entries[i].enabled and !p.entries[i].separator) {
        p.selected = i;
    };
    var maxw: usize = 80;
    for (p.entries[0..p.count]) |entry| {
        const extra: usize = if (entry.sub != 0) lineOf(R_UI) else if (entry.shortcut.len > 0) strW(R_UI, entry.shortcut) + 24 else 0;
        maxw = @max(maxw, strW(R_UI, entry.label[0..entry.len]) + extra);
    }
    p.w = @min(maxw + 2 * menu_hpad, wf.scanout_w);
    const natural = popNaturalHeight(p);
    p.h = @min(natural, @max(avail_h, 2 * pop_margin + 2 * arrowHeight() + pop_item_h));
    if (p.h < 2 * pop_margin + pop_item_h) return;
    p.x = @min(x, wf.scanout_w -| p.w);
    p.y = @min(y_wanted, wf.scanout_h -| p.h);
    // The submenu never takes the focus: the dropdown keeps the keyboard
    // (a focus loss on a popup is how a click elsewhere dismisses them, so
    // a focused submenu would dismiss its own parent).
    const flags: u64 = shared.gpu_pointer_tracking | (if (level > 0) shared.gpu_no_focus else @as(u64, 0));
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, wf.chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(p.x), @intCast(p.y)), .wh = shared.packPair(@intCast(p.w), @intCast(p.h)), .flags = flags } }, 0)) {
        .ok => |ok| ok,
        .err => return,
    };
    p.surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return,
    };
    if (cs.cap == 0) {
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = p.surf } }, 0);
        return;
    }
    const mp = usys.shmMap(cs.cap);
    if (mp.err != .ok) {
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = p.surf } }, 0);
        _ = usys.capDrop(cs.cap);
        return;
    }
    p.cap = cs.cap;
    p.va = mp.data[0];
    p.px = @ptrFromInt(mp.data[0]);
    p.open = true;
    active_level = level;
    commitPopup(p);
    logPopup(p, level);
}
fn logPopup(p: *const Popup, level: usize) void {
    var lb: [96]u8 = undefined;
    _ = usys.log(core.log_h, std.fmt.bufPrint(&lb, "topbar: popup at {d},{d} ih={d} n={d} level={d}", .{ p.x, p.y, pop_item_h, p.count, level }) catch "topbar: popup");
    // Each shown row, so a host can click one by its label.
    const visible = popVisible(p);
    for (p.first..p.first + visible) |i| {
        const entry = p.entries[i];
        if (entry.separator) continue;
        var il: [160]u8 = undefined;
        _ = usys.log(core.log_h, std.fmt.bufPrint(&il, "topbar: item y={d} h={d} {s}", .{ p.y + popEntryY(p, i), popEntryHeight(p, i), entry.label[0..entry.len] }) catch continue);
    }
}

/// Open a bar menu's dropdown under its title.
fn openPopup(m: MenuHit) void {
    closeLevelsFrom(0);
    const p = &pops[0];
    pop_item_h = ui.paint.menuRowHeight(wf.brush());
    fillFromMenu(p, m);
    if (p.count == 0) return;
    p.menu_id = m.id;
    pop_app_token = if (m.app_items.len > 0 or m.slot != null) bar_app.token else 0;
    pop_focus_token = bar_app.token;
    const y = wf.win_y + wf.win_h;
    openPopupAt(p, 0, wf.win_x + m.bx, y, wf.scanout_h -| y);
}
/// Close every popup from `level` up (a deeper one first).
fn closeLevelsFrom(level: usize) void {
    var l: usize = max_levels;
    while (l > level) {
        l -= 1;
        if (pops[l].open) closePopup(&pops[l]);
    }
    if (active_level >= level) active_level = level -| 1;
}
/// Open the submenu a row of `level` names, beside that popup at the row;
/// anything deeper closes first.
fn openSubmenu(level: usize, row: usize) void {
    if (level + 1 >= max_levels) return;
    const parent = &pops[level];
    if (!parent.open or row >= parent.count or parent.entries[row].sub == 0) return;
    closeLevelsFrom(level + 1);
    const p = &pops[level + 1];
    p.count = 0;
    p.selected = null;
    p.first = 0;
    fillFromSlot(p, parent.entries[row].sub - 1);
    if (p.count == 0) return;
    p.menu_id = parent.entries[row].label[0..parent.entries[row].len];
    p.parent = row;
    parent.selected = row;
    commitPopup(parent);
    const y = parent.y + popEntryY(parent, row);
    openPopupAt(p, level + 1, parent.x + parent.w -| pop_margin, y, wf.scanout_h -| (wf.win_y + wf.win_h));
}

fn closePopup(p: *Popup) void {
    if (!p.open) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = p.surf } }, 0);
    if (p.va != 0) _ = usys.shmUnmap(p.va);
    if (p.cap != 0) _ = usys.capDrop(p.cap);
    p.surf = 0;
    p.cap = 0;
    p.va = 0;
    p.open = false;
    p.menu_id = "";
}
/// Close the deepest submenu, the keyboard back on its parent.
fn closeSubmenu() void {
    if (active_level == 0 or !pops[active_level].open) return;
    closePopup(&pops[active_level]);
    active_level -= 1;
    _ = usys.log(core.log_h, "topbar: submenu closed");
}

fn dismissPopup(restore: bool) void {
    const token = pop_focus_token;
    closeLevelsFrom(0);
    active_level = 0;
    wf.ptr_down = false;
    if (restore and token != 0) _ = menuctl.restoreMenuFocus(core.output_control, token);
    _ = usys.log(core.log_h, "topbar: dismissed");
}

fn popupOf(surface: u64) ?*Popup {
    for (&pops) |*p| if (p.open and p.surf == surface) return p;
    return null;
}
fn levelOf(p: *const Popup) usize {
    for (&pops, 0..) |*q, i| if (q == p) return i;
    return 0;
}

fn mkMenuEvent(it: *mshl.Interp, menu: []const u8, item: []const u8) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "menu";
    keys[1] = "item";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = .{ .str = try it.arena.dupe(u8, menu) };
    vals[1] = .{ .str = try it.arena.dupe(u8, item) };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// The desktop's ground is the palette's: declared to the compositor
/// with the strut (per-session chrome authority), and again whenever the
/// appearance changes, so a high-contrast or light session is one to the
/// edges of the scanout rather than a set of windows on a fixed slate.
fn declareGround() void {
    if (core.output_control == 0) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, core.output_control, .{ .set_ground = .{ .word = pal.desktop } }, 0);
}

/// A selected row: the popup level and the row.
const Selected = struct { level: usize, idx: usize };

/// The resident top-bar loop (`gui { bar: true, ... }`): render the bar,
/// tick the clock, open/close dropdowns, and fire the selected menu item.
pub fn runBar(it: *mshl.Interp, view: Value, update: Value, init_state: Value) mshl.Error!Value {
    const old_rounded = wf.rounded;
    wf.rounded = false;
    defer wf.rounded = old_rounded;
    var epoch: @import("guieval.zig").Epoch = .{};
    try epoch.begin(it, .{ .list = &.{ view, update, init_state } });
    defer epoch.deinit();
    wf.fontReady();
    _ = wf.refreshAppearance();
    wf.useOrdinaryChannel();
    menuctl.control_chan = core.output_control; // the menus are read through the seat's control endpoint
    wf.pointer_tracking = true;
    wf.tick_ms = 100; // focus/menu state follows the compositor promptly
    wf.win_x = 0;
    wf.win_y = 0;
    wf.win_w = wf.scanout_w;
    wf.win_h = lineOf(R_UI) + 2 * bar_vpad + pal.border_w;
    wf.dragging = false;
    wf.ptr_down = false;
    pops = @splat(.{});
    bar_app = .{};
    if (!wf.openSurface(false)) return it.fail("gui: cannot open the bar surface", .{});
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, core.output_control, .{ .menu_bar = .{ .surface = wf.surf } }, 0);
    declareStrut(0, wf.win_h);
    declareGround();
    defer wf.closeSurface();
    defer closeLevelsFrom(0);

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    var bar_dirty = true;
    var evaluated = true;
    var clock_ticks: usize = 0;
    while (true) {
        const output_changed = wf.refreshOutput();
        if (wf.refreshFontMetrics() or output_changed) {
            dismissPopup(true);
            wf.closeSurface();
            wf.ptr_down = false; // the old surface's queue went with it
            wf.win_w = wf.scanout_w;
            wf.win_h = lineOf(R_UI) + 2 * bar_vpad + pal.border_w;
            if (!wf.openSurfaceFocused(false, false)) return it.fail("gui: cannot resize desktop chrome", .{});
            _ = usys.callTyped(shared.GpuReq, shared.GpuResp, core.output_control, .{ .menu_bar = .{ .surface = wf.surf } }, 0);
            declareStrut(0, wf.win_h);
            announced = false;
            bar_dirty = true;
        }
        const app = menuctl.activeMenu();
        if (app.token != bar_app.token) {
            if (anyOpen()) dismissPopup(false);
            bar_app = app;
            bar_app_name = menuctl.menuTitle(app.token);
            if (app.profile == .custom) loadCustom(app.token);
            var msg: [80]u8 = undefined;
            _ = usys.log(core.log_h, std.fmt.bufPrint(&msg, "topbar: active {s} token={d}", .{ std.mem.sliceTo(&bar_app_name, 0), app.token }) catch "topbar: active");
            announced = false;
            bar_dirty = true;
        }
        if (bar_dirty) {
            // An open popup borrows this tree. Compact only when it closes;
            // pointer/keyboard popup navigation creates no evaluation data —
            // and neither does a hover, so only an evaluated turn checkpoints.
            if (!anyOpen() and evaluated) {
                try epoch.checkpoint(&state, &tree);
                evaluated = false;
            }
            renderBar(tree);
            if (!wf.commitSurface()) return it.fail("gui: bar commit failed", .{});
            bar_dirty = false;
        }
        if (!announced) {
            _ = usys.log(core.log_h, "topbar: ready");
            for (bar_menus[0..bar_nmenus]) |m| {
                var mb: [64]u8 = undefined;
                _ = usys.log(core.log_h, std.fmt.bufPrint(&mb, "topbar: menu {s} cx={d} cy={d}", .{ m.id, m.bx + m.bw / 2, wf.win_h / 2 }) catch "topbar: menu");
            }
            announced = true;
        }
        var selected: ?Selected = null;
        input: while (true) {
            const ev = wf.nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2 or ev.kind == 7) {
                clock_ticks += 1;
                // The appearance tick: re-resolve the palette, repaint, and
                // hand the compositor the new ground.
                if (wf.refreshAppearance()) {
                    if (anyOpen()) dismissPopup(true);
                    declareGround();
                    bar_dirty = true;
                    break :input;
                }
                if (!anyOpen() and clock_ticks >= 10) {
                    tree = try it.callValue(view, &.{state}, null, null);
                    evaluated = true;
                    clock_ticks = 0;
                    bar_dirty = true;
                }
                break :input;
            }
            if (ev.kind == 4) {
                if (ev.ch == 0) {
                    wf.ptr_down = false;
                    // The dropdown losing the focus is a click elsewhere: the
                    // menus close. The submenu is never focused (it is created
                    // without activation), so the "not focused" it is told on
                    // creation is not that.
                    if (popupOf(ev.surface)) |p| if (levelOf(p) == 0) {
                        dismissPopup(false);
                        bar_dirty = true;
                        break :input;
                    };
                }
                continue;
            }
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !wf.ptr_down;
                wf.ptr_down = down;
                const wheel = shared.ptrWheel(ev.btn);
                if (popupOf(ev.surface)) |p| {
                    const local_y = if (ev.screen_y) |sy| sy -| p.y else ev.y;
                    if (wheel != 0) {
                        scrollPopup(p, if (wheel > 0) -1 else 1);
                        continue;
                    }
                    switch (popHitAt(p, local_y)) {
                        .entry => |idx| {
                            if (p.selected != idx) {
                                p.selected = idx;
                                commitPopup(p);
                            }
                            if (press) {
                                if (p.entries[idx].sub != 0) {
                                    openSubmenu(levelOf(p), idx);
                                } else {
                                    selected = .{ .level = levelOf(p), .idx = idx };
                                    break :input;
                                }
                            }
                        },
                        .up => if (press) scrollPopup(p, -1),
                        .down => if (press) scrollPopup(p, 1),
                        .none => {},
                    }
                } else if (ev.surface == wf.surf and (press or (anyOpen() and !down))) {
                    if (menuAt(ev.x)) |mi| {
                        const was_this = openMenuIs(bar_menus[mi].id);
                        if (was_this) {
                            if (press) dismissPopup(true);
                        } else openPopup(bar_menus[mi]);
                    } else if (anyOpen() and press) dismissPopup(true);
                    bar_dirty = true;
                    break :input;
                }
                continue;
            }
            if (ev.kind == 0 and ev.ch == shared.keyboard.launcher) {
                if (anyOpen()) dismissPopup(false);
                if (@import("applauncher.zig").run(core.output_control, core.log_h) and bar_nmenus > 0) openPopup(bar_menus[0]);
                bar_dirty = true;
                break :input;
            }
            if (ev.kind == 0 and ev.ch == shared.keyboard.menu_focus) {
                if (anyOpen()) dismissPopup(true) else if (bar_nmenus > 0) openPopup(bar_menus[0]);
                bar_dirty = true;
                break :input;
            }
            if (ev.kind != 0 or !anyOpen()) continue;
            const p = &pops[active_level];
            switch (ev.ch) {
                27 => {
                    if (active_level > 0) {
                        closeSubmenu();
                        continue;
                    }
                    dismissPopup(true);
                    bar_dirty = true;
                    break :input;
                },
                shared.keyboard.up => moveSelection(p, false),
                shared.keyboard.down => moveSelection(p, true),
                shared.keyboard.home => {
                    p.selected = null;
                    moveSelection(p, true);
                },
                shared.keyboard.end => {
                    p.selected = null;
                    moveSelection(p, false);
                },
                shared.keyboard.right => {
                    // Right opens the selected row's submenu; otherwise the
                    // next bar menu (from the dropdown only).
                    if (p.selected) |idx| if (p.entries[idx].sub != 0) {
                        openSubmenu(active_level, idx);
                        continue;
                    };
                    if (active_level > 0) continue;
                    for (bar_menus[0..bar_nmenus], 0..) |m, idx| {
                        if (std.mem.eql(u8, m.id, pops[0].menu_id)) {
                            openPopup(bar_menus[(idx + 1) % bar_nmenus]);
                            bar_dirty = true;
                            break;
                        }
                    }
                    break :input;
                },
                shared.keyboard.left => {
                    if (active_level > 0) {
                        closeSubmenu();
                        continue;
                    }
                    for (bar_menus[0..bar_nmenus], 0..) |m, idx| {
                        if (std.mem.eql(u8, m.id, pops[0].menu_id)) {
                            openPopup(bar_menus[(idx + bar_nmenus - 1) % bar_nmenus]);
                            bar_dirty = true;
                            break;
                        }
                    }
                    break :input;
                },
                '\n', '\r' => {
                    if (p.selected) |idx| {
                        if (p.entries[idx].sub != 0) {
                            openSubmenu(active_level, idx);
                            continue;
                        }
                        selected = .{ .level = active_level, .idx = idx };
                    }
                    break :input;
                },
                else => {},
            }
        }
        if (selected) |sel| {
            bar_dirty = true;
            const entry = pops[sel.level].entries[sel.idx];
            if (pop_app_token != 0) {
                const accepted = menuctl.invokeMenu(core.output_control, pop_app_token, entry.key);
                var msg: [80]u8 = undefined;
                _ = usys.log(core.log_h, std.fmt.bufPrint(&msg, "topbar: action {d} accepted={}", .{ entry.key, accepted }) catch "topbar: action");
                dismissPopup(false);
            } else {
                // Copy event values before disposing of the popup and its
                // borrowed menu ID; the interpreter owns the new event.
                if (entry.launcher) {
                    dismissPopup(false);
                    if (@import("applauncher.zig").run(core.output_control, core.log_h) and bar_nmenus > 0) openPopup(bar_menus[0]);
                    continue;
                }
                var sl: [160]u8 = undefined;
                _ = usys.log(core.log_h, std.fmt.bufPrint(&sl, "topbar: selected {s} {s}", .{ pops[0].menu_id, entry.label[0..entry.len] }) catch "topbar: selected");
                const ev = try mkMenuEvent(it, pops[0].menu_id, entry.label[0..entry.len]);
                dismissPopup(true);
                state = try it.callValue(update, &.{ state, ev }, null, null);
                tree = try it.callValue(view, &.{state}, null, null);
                evaluated = true;
                if (isDone(state)) break;
            }
        }
    }
    _ = usys.log(core.log_h, "topbar: closed");
    return epoch.finish(state);
}
