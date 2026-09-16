//! The desktop's top bar: a resident, titleless strip along the top edge
//! that hosts the system menu, the focused application's global menus
//! (published by the compositor) and the clock, with a popup surface for
//! open menus and keyboard navigation through them. A `gui { bar: true }`
//! app in mshl runs here; the layout of its items is data, the popups and
//! the menu protocol are this file's. Split out of guicmds.zig, which
//! keeps the window runtime, the widget painters and the input loop.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mshl = @import("mosslib").mshl;
const ui = @import("mosslib").ui;
const wf = @import("windowframe.zig");
const core = @import("guicmds.zig");
const R_UI = core.R_UI;
const Value = core.Value;
const declareStrut = core.declareStrut;
const drawIconLabel = core.drawIconLabel;
const drawStr = core.drawStr;
const drawStrTrunc = core.drawStrTrunc;
const fillAll = core.fillAll;
const fillRect = core.fillRect;
const fillRoundRect = core.fillRoundRect;
const iconLabelWidth = core.iconLabelWidth;
const isDone = core.isDone;
const item_vpad = core.item_vpad;
const lineOf = core.lineOf;
const pal = core.pal;
const panel = core.panel;
const strField = core.strField;
const strW = core.strW;
const on = core.on;

// -------------------------------------------------------------- the top bar
//
// A resident menu bar pinned at the top of the scanout: menu titles at the
// left, right-aligned items (a live clock) at the right. A menu opens a
// DROPDOWN — a second, transient surface, because moss surfaces are opaque,
// so a menu overlaying windows must be its own surface; it is dismissed on a
// selection, a click elsewhere, or Escape. The bar's `view(state)` returns
// `{ left: [...], right: [...] }` of `{kind:menu,...}` / `{kind:label,...}`;
// a selected item fires `update(state, { menu, item })`. Windows open below
// the bar (a strut it declares to the compositor), so it is never covered.

pub const bar_vpad = 8;
const menu_hpad = 12;

const MenuHit = struct {
    id: []const u8,
    bx: usize,
    bw: usize,
    items: []const Value = &.{},
    app_items: []const shared.menus.Item = &.{},
};
var bar_menus: [8]MenuHit = undefined;
var bar_nmenus: usize = 0;
var bar_app: wf.ActiveMenu = .{};
var bar_app_name: [16]u8 = @splat(0);

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
};
var pop_entries: [32]PopupItem = undefined;
var pop_count: usize = 0;
var pop_selected: ?usize = null;
var pop_app_token: u64 = 0;
var pop_focus_token: u64 = 0;
var pop_surf: u64 = 0;
var pop_px: [*]volatile u32 = undefined;
var pop_cap: u64 = 0;
var pop_va: u64 = 0;
var pop_x: usize = 0;
var pop_y: usize = 0;
var pop_w: usize = 0;
var pop_h: usize = 0;
var pop_open = false;
var pop_menu_id: []const u8 = "";
var pop_item_h: usize = 0;

fn barItemWidth(item: Value) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const menu = std.mem.eql(u8, strField(rec, "kind"), "menu");
    return (if (menu) iconLabelWidth(rec, "title") else strW(R_UI, strField(rec, "text"))) + 2 * menu_hpad;
}

fn drawBarItem(item: Value, x: usize, cy: usize) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const width = barItemWidth(item);
    if (std.mem.eql(u8, strField(rec, "kind"), "menu")) {
        const id = strField(rec, "id");
        const bg = if (pop_open and std.mem.eql(u8, pop_menu_id, id)) pal.surface_hi else pal.surface;
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
        for (menus) |menu| menu_width += strW(R_UI, menu.title) + 2 * menu_hpad;
        const name = std.mem.sliceTo(&bar_app_name, 0);
        const available = wf.win_w -| (x + menu_width + menu_hpad);
        const name_width = @min(strW(R_UI, name) + 2 * menu_hpad, available);
        if (name_width > 2 * menu_hpad) drawStrTrunc(x + menu_hpad, cy, R_UI, name, name_width - 2 * menu_hpad, pal.title, pal.surface);
        x += name_width;
        for (menus) |menu| {
            const width = strW(R_UI, menu.title) + 2 * menu_hpad;
            if (x + width > wf.win_w or bar_nmenus == bar_menus.len) break;
            const bg = if (pop_open and std.mem.eql(u8, pop_menu_id, menu.title)) pal.surface_hi else pal.surface;
            fillRect(x, 0, width, wf.win_h - pal.border_w, bg);
            drawStr(x + menu_hpad, cy, R_UI, menu.title, pal.text, bg);
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

fn popEntryHeight(index: usize) usize {
    return if (pop_entries[index].separator) @max(9, lineOf(R_UI) / 3) else pop_item_h;
}
fn popEntryY(index: usize) usize {
    var y: usize = 4;
    for (0..index) |i| y += popEntryHeight(i);
    return y;
}
fn popItemAt(ly: usize) ?usize {
    var y: usize = 4;
    for (pop_entries[0..pop_count], 0..) |entry, i| {
        const height = popEntryHeight(i);
        if (ly >= y and ly < y + height) return if (entry.enabled and !entry.separator) i else null;
        y += height;
    }
    return null;
}

fn renderPopup() void {
    // The popup is its own surface: its own size and its own clip. (Painting
    // it through the bar's clip left every row below the bar's height black.)
    const saved = wf.retarget(pop_px, pop_w, pop_h);
    defer wf.restoreTarget(saved);
    panel(0, 0, pop_w, pop_h, 8, pal.surface, pal.border, pal.border_w);
    const cyoff = (pop_item_h -| lineOf(R_UI)) / 2;
    for (pop_entries[0..pop_count], 0..) |entry, i| {
        const y = popEntryY(i);
        if (entry.separator) {
            fillRect(menu_hpad, y + popEntryHeight(i) / 2, pop_w -| (2 * menu_hpad), pal.border_w, pal.border);
            continue;
        }
        const selected = pop_selected == i and entry.enabled;
        const bg = if (selected) pal.primary else pal.surface;
        const ink = if (!entry.enabled) pal.text_muted else if (selected) pal.primary_ink else pal.text;
        if (selected) fillRoundRect(4, y, pop_w -| 8, pop_item_h, 4, bg);
        const shortcut_w = strW(R_UI, entry.shortcut);
        const shortcut_gap: usize = if (shortcut_w > 0) 24 else 0;
        drawStrTrunc(menu_hpad, y + cyoff, R_UI, entry.label[0..entry.len], pop_w -| (2 * menu_hpad + shortcut_w + shortcut_gap), ink, bg);
        if (shortcut_w > 0 and shortcut_w + 2 * menu_hpad < pop_w) drawStr(pop_w - menu_hpad - shortcut_w, y + cyoff, R_UI, entry.shortcut, ink, bg);
    }
}

fn commitPopup() void {
    renderPopup();
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .commit = .{ .surface = pop_surf, .xy = 0, .wh = shared.packPair(@intCast(pop_w), @intCast(pop_h)) } }, 0);
}

fn movePopupSelection(forward: bool) void {
    if (pop_count == 0) return;
    var idx = pop_selected orelse (if (forward) pop_count - 1 else 0);
    for (0..pop_count) |_| {
        idx = (idx + (if (forward) @as(usize, 1) else pop_count - 1)) % pop_count;
        if (pop_entries[idx].enabled and !pop_entries[idx].separator) {
            pop_selected = idx;
            break;
        }
    }
    commitPopup();
}

fn openPopup(m: MenuHit) void {
    if (pop_open) closePopup();
    pop_count = @min(if (m.app_items.len > 0) m.app_items.len else m.items.len, pop_entries.len);
    if (pop_count == 0) return;
    pop_menu_id = m.id;
    pop_app_token = if (m.app_items.len > 0) bar_app.token else 0;
    pop_focus_token = bar_app.token;
    pop_selected = null;
    pop_item_h = lineOf(R_UI) + 2 * item_vpad;
    var maxw: usize = 80;
    for (0..pop_count) |i| {
        var entry: PopupItem = .{};
        // A bar item is a string (an event for the script) or a record
        // `{ text, action }` whose action the runtime performs itself.
        const label = if (m.app_items.len > 0) m.app_items[i].label else if (m.items[i] == .str) m.items[i].str else if (m.items[i] == .record) strField(m.items[i].record, "text") else "";
        if (m.app_items.len == 0 and m.items[i] == .record) entry.launcher = std.mem.eql(u8, strField(m.items[i].record, "action"), "launcher");
        if (m.app_items.len == 0 and std.mem.eql(u8, label, "-")) entry.separator = true; // a rule between groups
        entry.len = @min(label.len, entry.label.len);
        @memcpy(entry.label[0..entry.len], label[0..entry.len]);
        if (m.app_items.len > 0) {
            const item = m.app_items[i];
            entry.key = item.key;
            entry.shortcut = item.shortcut;
            entry.separator = item.key == 0;
            entry.enabled = shared.menus.allows(bar_app.profile, bar_app.enabled, item.key);
        }
        pop_entries[i] = entry;
        if (pop_selected == null and entry.enabled and !entry.separator) pop_selected = i;
        maxw = @max(maxw, strW(R_UI, label) + (if (entry.shortcut.len > 0) strW(R_UI, entry.shortcut) + 24 else 0));
    }
    pop_w = @min(maxw + 2 * menu_hpad, wf.scanout_w);
    // All catalog menus fit the minimum output even at the largest text
    // scale; clamp defensively for declarative system menus.
    while (pop_count > 0 and popEntryY(pop_count) + 4 > wf.scanout_h -| wf.win_h) pop_count -= 1;
    if (pop_count == 0) return;
    pop_h = popEntryY(pop_count) + 4;
    pop_x = @min(wf.win_x + m.bx, wf.scanout_w -| pop_w);
    pop_y = wf.win_y + wf.win_h;
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, wf.chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(pop_x), @intCast(pop_y)), .wh = shared.packPair(@intCast(pop_w), @intCast(pop_h)), .flags = shared.gpu_pointer_tracking } }, 0)) {
        .ok => |ok| ok,
        .err => return,
    };
    pop_surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return,
    };
    if (cs.cap == 0) {
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = pop_surf } }, 0);
        return;
    }
    const mp = usys.shmMap(cs.cap);
    if (mp.err != .ok) {
        _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = pop_surf } }, 0);
        _ = usys.capDrop(cs.cap);
        return;
    }
    pop_cap = cs.cap;
    pop_va = mp.data[0];
    pop_px = @ptrFromInt(mp.data[0]);
    pop_open = true;
    commitPopup();
    var lb: [96]u8 = undefined;
    _ = usys.log(core.log_h, std.fmt.bufPrint(&lb, "topbar: popup at {d},{d} ih={d} n={d}", .{ pop_x, pop_y, pop_item_h, pop_count }) catch "topbar: popup");
    // Each item's row, so a host can click one by its label.
    for (pop_entries[0..pop_count], 0..) |entry, i| {
        if (entry.separator) continue;
        var il: [160]u8 = undefined;
        _ = usys.log(core.log_h, std.fmt.bufPrint(&il, "topbar: item y={d} h={d} {s}", .{ pop_y + popEntryY(i), popEntryHeight(i), entry.label[0..entry.len] }) catch continue);
    }
}

fn closePopup() void {
    if (!pop_open) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .destroy_surface = .{ .surface = pop_surf } }, 0);
    if (pop_va != 0) _ = usys.shmUnmap(pop_va);
    if (pop_cap != 0) _ = usys.capDrop(pop_cap);
    pop_surf = 0;
    pop_cap = 0;
    pop_va = 0;
    pop_open = false;
    pop_menu_id = "";
}

fn dismissPopup(restore: bool) void {
    const token = pop_focus_token;
    closePopup();
    wf.ptr_down = false;
    if (restore and token != 0) _ = wf.restoreMenuFocus(core.output_control, token);
    _ = usys.log(core.log_h, "topbar: dismissed");
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
    wf.refreshAppearance();
    wf.useOrdinaryChannel();
    wf.pointer_tracking = true;
    wf.tick_ms = 100; // focus/menu state follows the compositor promptly
    wf.win_x = 0;
    wf.win_y = 0;
    wf.win_w = wf.scanout_w;
    wf.win_h = lineOf(R_UI) + 2 * bar_vpad + pal.border_w;
    wf.dragging = false;
    wf.ptr_down = false;
    pop_open = false;
    bar_app = .{};
    if (!wf.openSurface(false)) return it.fail("gui: cannot open the bar surface", .{});
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, core.output_control, .{ .menu_bar = .{ .surface = wf.surf } }, 0);
    declareStrut(0, wf.win_h);
    defer wf.closeSurface();
    defer closePopup();

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    var bar_dirty = true;
    var clock_ticks: usize = 0;
    while (true) {
        const output_changed = wf.refreshOutput();
        if (wf.refreshFontMetrics() or output_changed) {
            dismissPopup(true);
            wf.closeSurface();
            wf.win_w = wf.scanout_w;
            wf.win_h = lineOf(R_UI) + 2 * bar_vpad + pal.border_w;
            if (!wf.openSurfaceFocused(false, false)) return it.fail("gui: cannot resize desktop chrome", .{});
            _ = usys.callTyped(shared.GpuReq, shared.GpuResp, core.output_control, .{ .menu_bar = .{ .surface = wf.surf } }, 0);
            declareStrut(0, wf.win_h);
            announced = false;
            bar_dirty = true;
        }
        const app = wf.activeMenu();
        if (app.token != bar_app.token) {
            if (pop_open) dismissPopup(false);
            bar_app = app;
            bar_app_name = wf.menuTitle(app.token);
            var msg: [80]u8 = undefined;
            _ = usys.log(core.log_h, std.fmt.bufPrint(&msg, "topbar: active {s} token={d}", .{ std.mem.sliceTo(&bar_app_name, 0), app.token }) catch "topbar: active");
            announced = false;
            bar_dirty = true;
        }
        if (bar_dirty) {
            // An open popup borrows this tree. Compact only when it closes;
            // pointer/keyboard popup navigation creates no evaluation data.
            if (!pop_open) try epoch.checkpoint(&state, &tree);
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
        var selected: ?usize = null;
        input: while (true) {
            const ev = wf.nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2 or ev.kind == 7) {
                clock_ticks += 1;
                if (!pop_open and clock_ticks >= 10) {
                    tree = try it.callValue(view, &.{state}, null, null);
                    clock_ticks = 0;
                    bar_dirty = true;
                }
                break :input;
            }
            if (ev.kind == 4) {
                if (ev.ch == 0) {
                    wf.ptr_down = false;
                    if (pop_open and ev.surface == pop_surf) {
                        dismissPopup(false);
                        bar_dirty = true;
                        break :input;
                    }
                }
                continue;
            }
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !wf.ptr_down;
                wf.ptr_down = down;
                if (pop_open and ev.surface == pop_surf) {
                    const local_y = if (ev.screen_y) |sy| sy -| pop_y else ev.y;
                    if (popItemAt(local_y)) |idx| {
                        if (pop_selected != idx) {
                            pop_selected = idx;
                            commitPopup();
                        }
                        if (press) {
                            selected = idx;
                            break :input;
                        }
                    }
                } else if (ev.surface == wf.surf and (press or (pop_open and !down))) {
                    if (menuAt(ev.x)) |mi| {
                        const was_this = pop_open and std.mem.eql(u8, pop_menu_id, bar_menus[mi].id);
                        if (was_this) {
                            if (press) dismissPopup(true);
                        } else openPopup(bar_menus[mi]);
                    } else if (pop_open and press) dismissPopup(true);
                    bar_dirty = true;
                    break :input;
                }
                continue;
            }
            if (ev.kind == 0 and ev.ch == shared.keyboard.launcher) {
                if (pop_open) dismissPopup(false);
                if (@import("applauncher.zig").run(core.output_control, core.log_h) and bar_nmenus > 0) openPopup(bar_menus[0]);
                bar_dirty = true;
                break :input;
            }
            if (ev.kind == 0 and ev.ch == shared.keyboard.menu_focus) {
                if (pop_open) dismissPopup(true) else if (bar_nmenus > 0) openPopup(bar_menus[0]);
                bar_dirty = true;
                break :input;
            }
            if (ev.kind != 0 or !pop_open) continue;
            switch (ev.ch) {
                27 => {
                    dismissPopup(true);
                    bar_dirty = true;
                    break :input;
                },
                shared.keyboard.up => movePopupSelection(false),
                shared.keyboard.down => movePopupSelection(true),
                shared.keyboard.home => {
                    pop_selected = null;
                    movePopupSelection(true);
                },
                shared.keyboard.end => {
                    pop_selected = null;
                    movePopupSelection(false);
                },
                shared.keyboard.left, shared.keyboard.right => {
                    for (bar_menus[0..bar_nmenus], 0..) |m, idx| {
                        if (std.mem.eql(u8, m.id, pop_menu_id)) {
                            const next = (idx + (if (ev.ch == shared.keyboard.right) @as(usize, 1) else bar_nmenus - 1)) % bar_nmenus;
                            openPopup(bar_menus[next]);
                            bar_dirty = true;
                            break;
                        }
                    }
                    break :input;
                },
                '\n', '\r' => {
                    selected = pop_selected;
                    break :input;
                },
                else => {},
            }
        }
        if (selected) |idx| {
            bar_dirty = true;
            const entry = pop_entries[idx];
            if (pop_app_token != 0) {
                const accepted = wf.invokeMenu(core.output_control, pop_app_token, entry.key);
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
                const ev = try mkMenuEvent(it, pop_menu_id, entry.label[0..entry.len]);
                dismissPopup(true);
                state = try it.callValue(update, &.{ state, ev }, null, null);
                tree = try it.callValue(view, &.{state}, null, null);
                if (isDone(state)) break;
            }
        }
    }
    _ = usys.log(core.log_h, "topbar: closed");
    return epoch.finish(state);
}
