//! The desktop's dock: a resident strip along the bottom edge whose pills
//! launch the session's applications and restore their windows, with a
//! running dot polled from init. A `gui { dock: true }` app in mshl runs
//! here. Split out of guicmds.zig, which keeps the window runtime, the
//! widget painters and the input loop.
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
const dockHeight = core.dockHeight;
const dock_vpad = core.dock_vpad;
const drawIconLabel = core.drawIconLabel;
const fillAll = core.fillAll;
const fillDot = core.fillDot;
const fillRect = core.fillRect;
const fillRoundRect = core.fillRoundRect;
const iconLabelWidth = core.iconLabelWidth;
const isDone = core.isDone;
const item_vpad = core.item_vpad;
const lineOf = core.lineOf;
const pal = core.pal;
const strField = core.strField;

// ----------------------------------------------------------- the dock

const dock_hpad = 16;
const dock_gap = 10;

const DockHit = struct { unit: []const u8, title: []const u8, running: bool = false, bx: usize, bw: usize };
var dock_items: [12]DockHit = undefined;
var dock_nitems: usize = 0;
var dock_running_known = false; // false until the first render logs a baseline

/// Draw the dock — a resident bottom bar of app buttons (rounded pills),
/// laid out centred across the width. An item is
/// `{ title, unit, running? }`; a running app gets the primary fill and a
/// dot below it. Each pill's hit box is recorded for the click router.
fn renderDock(tree: Value) void {
    dock_nitems = 0;
    fillAll(pal.surface);
    fillRect(0, 0, wf.win_w, pal.border_w, pal.border); // the rule against the desktop
    if (tree != .record) return;
    const items: []const Value = if (tree.record.get("items")) |iv| (if (iv == .list) iv.list else &.{}) else &.{};
    var total: usize = 0;
    var n: usize = 0;
    for (items) |item| {
        if (item != .record) continue;
        total += iconLabelWidth(item.record, "title") + 2 * dock_hpad;
        n += 1;
    }
    const natural_width = total;
    const gaps = (n -| 1) * dock_gap;
    const available = wf.win_w -| (2 * dock_gap + gaps);
    const fitted = @min(natural_width, available);
    total = fitted + gaps;
    var before: usize = 0;
    const pill_h = lineOf(R_UI) + 2 * item_vpad;
    const py = if (wf.win_h > pill_h) (wf.win_h - pill_h) / 2 else 0;
    var x: usize = if (wf.win_w > total) (wf.win_w - total) / 2 else dock_gap;
    for (items) |item| {
        if (item != .record) continue;
        const r = item.record;
        const title = strField(r, "title");
        const unit = strField(r, "unit");
        const running = r.get("running") != null and (r.get("running").?).asBool();
        const natural = iconLabelWidth(r, "title") + 2 * dock_hpad;
        const w = ui.flow.trackWidth(fitted, natural_width, before, natural);
        before += natural;
        const fill = if (running) pal.primary else pal.surface_hi;
        const ink = if (running) pal.primary_ink else pal.text;
        fillRoundRect(x, py, w, pill_h, 10, fill);
        drawIconLabel(r, "title", x + dock_hpad, py, w -| (2 * dock_hpad), pill_h, ink, fill);
        if (running and wf.win_h > 4) fillDot(x + w / 2, wf.win_h - 4, 2, pal.primary);
        if (dock_nitems < dock_items.len) {
            // Log a pill's running state only when it flips (never the
            // first render's baseline), so a launch lights the dot and an
            // exit clears it observably (the view polls `unit-up` each tick)
            // without spamming every tick.
            if (dock_running_known and dock_items[dock_nitems].running != running) {
                var rb: [64]u8 = undefined;
                _ = usys.log(core.log_h, std.fmt.bufPrint(&rb, "dock: running {s}={}", .{ unit, running }) catch "dock: running");
            }
            dock_items[dock_nitems] = .{ .unit = unit, .title = if (strField(r, "window").len > 0) strField(r, "window") else title, .running = running, .bx = x, .bw = w };
            dock_nitems += 1;
        }
        x += w + dock_gap;
    }
    dock_running_known = true;
}

/// The dock item under a click (surface-local x), or null.
fn dockItemAt(lx: usize) ?usize {
    for (dock_items[0..dock_nitems], 0..) |d, i| {
        if (lx >= d.bx and lx < d.bx + d.bw) return i;
    }
    return null;
}

/// The `{ item, unit, title }` event a dock click fires into `update`
/// (the app's update restores the window by `title` or launches `unit`).
fn mkDockEvent(it: *mshl.Interp, unit: []const u8, title: []const u8) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 3);
    keys[0] = "item";
    keys[1] = "unit";
    keys[2] = "title";
    const vals = try it.arena.alloc(Value, 3);
    vals[0] = .{ .str = try it.arena.dupe(u8, unit) };
    vals[1] = .{ .str = try it.arena.dupe(u8, unit) };
    vals[2] = .{ .str = try it.arena.dupe(u8, title) };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// The resident dock loop (`gui { dock: true, ... }`): a bottom bar of app
/// buttons, pinned full-width, chrome-less — not a window. view(state)
/// returns `{ items: [ { title, unit, running? } ] }`; clicking a pill
/// fires update(state, { item, unit, title }), whose update restores the
/// app if it is already up (`restore-window $ev.title`) or launches it
/// otherwise (`launch $ev.unit` reaches init through this process's init
/// front channel). `done: true` ends it.
pub fn runDock(it: *mshl.Interp, view: Value, update: Value, init_state: Value, dismissible: bool) mshl.Error!Value {
    const old_rounded = wf.rounded;
    wf.rounded = false;
    defer wf.rounded = old_rounded;
    var epoch: @import("guieval.zig").Epoch = .{};
    try epoch.begin(it, .{ .list = &.{ view, update, init_state } });
    defer epoch.deinit();
    wf.fontReady();
    wf.refreshAppearance();
    wf.useOrdinaryChannel();
    const pill_h = lineOf(R_UI) + 2 * item_vpad;
    wf.win_w = wf.scanout_w;
    wf.win_h = pill_h + 2 * dock_vpad + pal.border_w;
    wf.win_x = 0;
    wf.win_y = if (wf.scanout_h > wf.win_h) wf.scanout_h - wf.win_h else 0;
    wf.dragging = false;
    wf.ptr_down = false;
    if (!wf.openSurface(false)) return it.fail("gui: cannot open the dock surface", .{});
    declareStrut(1, wf.win_h);
    defer wf.closeSurface();

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    var evaluated = true;
    while (true) {
        if (evaluated) {
            try epoch.checkpoint(&state, &tree);
            evaluated = false;
        }
        const output_changed = wf.refreshOutput();
        if (wf.refreshFontMetrics() or output_changed) {
            wf.closeSurface();
            wf.win_w = wf.scanout_w;
            wf.win_h = dockHeight();
            wf.win_y = wf.scanout_h - wf.win_h;
            if (!wf.openSurfaceFocused(false, false)) return it.fail("gui: cannot resize desktop chrome", .{});
            declareStrut(1, wf.win_h);
            announced = false; // hit boxes moved with the new scale
        }
        renderDock(tree);
        if (!wf.commitSurface()) return it.fail("gui: dock commit failed", .{});
        if (!announced) {
            var lb: [64]u8 = undefined;
            _ = usys.log(core.log_h, std.fmt.bufPrint(&lb, "dock: ready n={d}", .{dock_nitems}) catch "dock: ready n=0");
            // The click router needs each pill's centre; log them so a drill
            // can aim precisely (like the top bar's popup geometry).
            for (dock_items[0..dock_nitems], 0..) |d, i| {
                var ib: [64]u8 = undefined;
                _ = usys.log(core.log_h, std.fmt.bufPrint(&ib, "dock: item {d} cx={d} cy={d}", .{ i, d.bx + d.bw / 2, wf.win_y + wf.win_h / 2 }) catch "dock: item");
            }
            announced = true;
        }
        var fired: ?usize = null;
        var quit = false;
        input: while (true) {
            const ev = wf.nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2 or ev.kind == 7) {
                tree = try it.callValue(view, &.{state}, null, null); // tick refresh
                evaluated = true;
                break :input;
            }
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !wf.ptr_down;
                wf.ptr_down = down;
                if (press and ev.surface == wf.surf) {
                    if (dockItemAt(ev.x)) |idx| {
                        fired = idx;
                        break :input;
                    }
                }
                continue :input;
            }
            if (ev.kind == 0 and ev.ch == 27 and dismissible) { // only the standalone drill permits dismissal
                quit = true;
                break :input;
            }
        }
        if (quit) break;
        if (fired) |idx| {
            const unit = dock_items[idx].unit;
            var lb: [64]u8 = undefined;
            _ = usys.log(core.log_h, std.fmt.bufPrint(&lb, "dock: activate {s}", .{unit}) catch "dock: activate");
            const ev = try mkDockEvent(it, unit, dock_items[idx].title);
            state = try it.callValue(update, &.{ state, ev }, null, null);
            tree = try it.callValue(view, &.{state}, null, null);
            evaluated = true;
            if (isDone(state)) break;
        }
    }
    _ = usys.log(core.log_h, "dock: closed");
    return epoch.finish(state);
}
