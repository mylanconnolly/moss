//! gui — the mshl GUI runtime, a hosted command family (like net/fs/http)
//! wired into a host that holds a `display` cap. A GUI is a *service*
//! written as two pure mshl functions and a declarative view:
//!
//!   gui {
//!     init:   { count: 0 }
//!     view:   (fn [state] { { kind: column, children: [
//!               { kind: label,  text: $"count ($state.count)" }
//!               { kind: button, id: "inc",  label: "increment" }
//!               { kind: button, id: "quit", label: "quit" }
//!             ] } })
//!     update: (fn [state, ev] { match $ev.id {
//!               "inc"  => { $state | merge { count: ($state.count + 1) } }
//!               "quit" => { $state | merge { done: true } }
//!               _      => $state
//!             } })
//!   }
//!
//! The runtime owns the surface: it renders `view state`, routes input
//! (the keyboard — Tab moves focus between the focusable widgets, Enter
//! fires the focused one — and the pointer — a click focuses the widget
//! under it and fires a button), and on each fire calls `update state {id}`, threads
//! the returned state forward, and re-renders. The app never loops and
//! never blocks — it is a pure function of state and event, so it is a
//! supervised, crash-only, fabric-shippable service in the making (only
//! data — the view, the event id, the state — ever crosses). `update`
//! returning a state with `done: true` closes the window; `gui` answers
//! with the final state.

const std = @import("std");
const shared = @import("shared");
const ui = @import("mosslib").ui;
const usys = @import("usys.zig");
const workcmds = @import("workcmds.zig");
const fabcmds = @import("fabcmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
pub const Value = mshl.Value;
const wf = @import("windowframe.zig");
const widgets = @import("widgets.zig");

// The window frame — the chrome, the compositor surface, the drawing
// primitives and the system font — lives in windowframe.zig, shared with
// the terminal so both wear the same window. This module is the mshl GUI
// *content*: the widget tree, the resident top bar and dock, and the run
// loops that route input through the frame. These aliases let the widget
// code read as it did before the split (the frame owns the module state
// behind them, so a redraw of the popup surface, say, is `wf.px = ...`).
pub const pal = &wf.pal;
pub const fillAll = wf.fillAll;
pub const fillRect = wf.fillRect;
pub const fillRoundRect = wf.fillRoundRect;
pub const fillDot = wf.fillDot;
pub const panel = wf.panel;
const shade = wf.shade;
pub const drawStr = wf.drawStr;
pub const drawStrTrunc = wf.drawStrTrunc;
pub const strW = wf.strW;
pub const lineOf = wf.lineOf;
const clipReset = wf.clipReset;
pub const R_UI = wf.R_UI;
const R_TITLE = wf.R_TITLE;
const win_w_default = wf.win_w_default;
const win_h_min = wf.win_h_min;
pub const item_vpad = 8; // a dock/menu item's vertical padding
pub const dock_vpad = 8; // the dock's outer vertical padding
pub fn dockHeight() usize {
    return lineOf(R_UI) + 2 * item_vpad + 2 * dock_vpad + pal.border_w;
}
/// The work area once the desktop chrome has caught up with a scale
/// change. The bar and the dock re-declare their struts a tick after
/// their metrics change; a window opening in that gap would centre
/// against the old ones. They are this same runtime, so their heights
/// are known here: wait briefly for the compositor's answer to match.
fn settledWorkArea() wf.Geom {
    const bar_h = lineOf(R_UI) + 2 * guibar.bar_vpad + pal.border_w;
    var wa = wf.workArea();
    var tries: usize = 0;
    while (tries < 8) : (tries += 1) {
        const top_ok = wa.y == 0 or wa.y == bar_h;
        const bottom_ok = wa.y + wa.h == wf.scanout_h or wa.y + wa.h + dockHeight() == wf.scanout_h;
        if (top_ok and bottom_ok) break;
        usys.sleepMs(40);
        wa = wf.workArea();
    }
    return wa;
}
/// Tell the compositor the edge this chrome reserves, so every window's
/// work area (maximize, snap, centring) follows the real bar and dock.
pub fn declareStrut(edge: u64, size: usize) void {
    if (output_control == 0 or wf.surf == 0) return;
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, output_control, .{ .set_strut = .{ .surface = wf.surf, .edge = edge, .size = size } }, 0);
}

pub var output_control: u64 = 0;
pub var log_h: u64 = 0; // for the run loops' `gui:`/`topbar:`/`dock:` logging

// Crash-isolation of `update` (opt-in `gui { isolate: true }`): the app's
// `update` runs in a worker domain, so a fault or panic in it kills only
// that domain — the runtime detects the dead worker, re-spawns it, drops
// the offending event, and carries on. `iso_src` is the reconstructed
// worker script (kept for re-spawn); `iso_conn` the live worker, if any.
var iso_conn: ?workcmds.Conn = null;
var iso_src: []const u8 = "";

// A `gui { node: N }` runs the whole app on node N: `remote_node` is N and
// `app_src` is the reconstructed worker (update+view over `$in`) shipped
// there each event. 0 = run in-process, as usual.
var remote_node: u64 = 0;
var app_src: []const u8 = "";
// The persistent remote stage: spawned once on node `remote_node` when the
// GUI opens, run per event, torn down when it closes — so the app's domain
// is spawned on the host once, not per event.
var remote_stage: ?fabcmds.Stage = null;

// The fabric, when the host holds one: a `gui { node: N }` runs the app
// (its update+view) on node N — the fabric-transparent GUI. The runtime
// stays a pure viewer here: it renders the view tree the remote returns
// and ships each event, only data crossing.
var fab_chan: u64 = 0;

pub fn setup(display_cap: u64, log: u64, secret: []const u8, font_cap: u64, fabric_cap: u64) void {
    log_h = log;
    fab_chan = fabric_cap;
    wf.setup(display_cap, log, secret, font_cap);
}

/// Whether the host holds a display — `gui` is offered only then.
pub fn on() bool {
    return wf.display != 0;
}

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "apps")) return .{ .ret = .list };
    if (std.mem.eql(u8, name, "display-info")) return .{ .ret = .record };
    if (std.mem.eql(u8, name, "display-modes")) return .{ .ret = .list };
    if (std.mem.eql(u8, name, "display-preview")) return .{ .params = &.{.{ .name = "mode", .shape = .string }}, .ret = .bool };
    if (std.mem.eql(u8, name, "display-confirm") or std.mem.eql(u8, name, "display-revert")) return .{ .ret = .bool };
    if (std.mem.eql(u8, name, "gui")) {
        return .{ .params = &.{.{ .name = "spec", .shape = .record }}, .input = .{ .optional = .record }, .ret = .any };
    }
    // `sessionfont TEXT` pushes a user font layer (the text of a font.msh)
    // to the shared font service for this session; no arg / "" reverts.
    if (std.mem.eql(u8, name, "sessionfont")) {
        return .{ .params = &.{.{ .name = "layer", .shape = .string, .optional = true }}, .input = .{ .optional = .string }, .ret = .any };
    }
    // `appearance` reports the EFFECTIVE theme/contrast/colours the font
    // service is applying now (after locked keys), for a settings app to
    // display or a drill to check what a push actually took.
    if (std.mem.eql(u8, name, "appearance")) {
        return .{ .ret = .record };
    }
    // `restore-window TITLE` brings a running window with that title
    // forward (unhiding a minimized one) — the dock uses it so a pill for
    // an already-running app restores it instead of relaunching. `ok` when
    // one matched, an error otherwise (nothing by that title is up).
    if (std.mem.eql(u8, name, "restore-window")) {
        return .{ .params = &.{.{ .name = "title", .shape = .string }}, .ret = restore_result };
    }
    return null;
}

const restore_result = mshl.resultShape(.string, .string);

// ------------------------------------------------------------ rendering
//
// The drawing primitives, the system font (fontsvc) and the semantic
// palette are the frame's — see windowframe.zig. What stays here is the
// widget *content*: the layout of the view tree over the frame's content
// area, plus the field/list interaction state the runtime owns.

const pad = ui.space.inset; // window inset for content

// The laid-out content height, from the measuring pass — the frame's
// window is sized to it before the surface is created (`sizeToContent`).
var content_h: usize = 0;

// A focusable widget: its id, whether it is a text field (which eats
// typing) or a button (which fires on Enter), and its clickable box on
// the surface (so a pointer press can hit-test which widget it landed on).
const Focus = struct { crumb: ?*Crumb = null, sy: isize = 0, cy0: usize = 0, cy1: usize = 0, cx0: usize = 0, cx1: usize = 0, owner: usize = 0, id: []const u8, is_field: bool, is_list: bool = false, bx: usize = 0, by: usize = 0, bw: usize = 0, bh: usize = 0 };
var focusables: [64]Focus = undefined;

// Every window has an implicit viewport; explicit `scroll` nodes can nest.
const ScrollState = struct {
    id: [64]u8 = @splat(0),
    len: usize = 0,
    used: bool = false,
    seen: bool = false,
    state: ui.scroll.Scroll = .{},
    parent: usize = 0,
    x: usize = 0,
    top: isize = 0,
    w: usize = 0,
    h: usize = 0,
    cy0: usize = 0,
    cy1: usize = 0,
    depth: usize = 0,
};
var scrolls: [16]ScrollState = @splat(.{});
var scroll_owner: usize = 0;
var reveal_focus = true;
var layout_overflow = false;
var scroll_dirty = false;
fn containsScroll(node: Value, id: []const u8) bool {
    if (node != .record) return false;
    const rec = node.record;
    if (std.mem.eql(u8, strField(rec, "kind"), "scroll") and std.mem.eql(u8, strField(rec, "id"), id)) return true;
    for (nodeChildren(rec)) |child| if (containsScroll(child, id)) return true;
    for ([_][]const u8{ "child", "left", "right" }) |key| {
        if (rec.get(key)) |child| if (containsScroll(child, id)) return true;
    }
    return false;
}
fn scrollFor(id: []const u8) usize {
    for (scrolls[1..], 1..) |st, i| if (st.used and std.mem.eql(u8, st.id[0..st.len], id)) {
        if (st.seen) {
            layout_overflow = true;
            return 0;
        }
        return i;
    };
    for (scrolls[1..], 1..) |*st, i| if (!st.used) {
        st.* = .{ .used = true, .len = @min(id.len, st.id.len) };
        @memcpy(st.id[0..st.len], id[0..st.len]);
        return i;
    };
    layout_overflow = true;
    return 0;
}
fn recordFocus(f: Focus) void {
    if (nfoc == focusables.len) {
        layout_overflow = true;
        return;
    }
    focusables[nfoc] = f;
    const out = &focusables[nfoc];
    out.sy = wf.screenY(f.by);
    out.by = wf.clipY(f.by);
    out.cy0 = wf.clip_y0;
    out.cy1 = wf.clip_y1;
    out.cx0 = wf.clip_x0;
    out.cx1 = wf.clip_x1;
    out.owner = scroll_owner;
    nfoc += 1;
}
fn revealWidget(index: usize) bool {
    if (index >= nfoc) return false;
    const f = focusables[index];
    var owner = f.owner;
    var top = f.sy;
    var h = f.bh;
    var changed = false;
    for (0..scrolls.len) |_| {
        const st = &scrolls[owner];
        const local: usize = @intCast(@max(0, top - st.top + @as(isize, @intCast(st.state.offset))));
        const old = st.state.offset;
        changed = st.state.reveal(local, h) or changed;
        top += @as(isize, @intCast(old)) - @as(isize, @intCast(st.state.offset));
        if (owner == 0) break;
        h = @min(h, st.h);
        top = @max(st.top, top);
        owner = st.parent;
    }
    scroll_dirty = scroll_dirty or changed;
    return changed;
}
fn scrollAt(x: usize, y: usize) usize {
    var result: usize = 0;
    // Nested viewports are encountered after parents during painting.
    for (scrolls[1..], 1..) |st, i| {
        if (st.seen and st.depth >= scrolls[result].depth and x >= st.x and x < st.x + st.w and y >= st.cy0 and y < st.cy1) result = i;
    }
    return result;
}
fn scrollStep(owner_in: usize, delta: isize) bool {
    var owner = owner_in;
    for (0..scrolls.len) |_| {
        if (scrolls[owner].state.step(delta)) {
            scroll_dirty = true;
            return true;
        }
        if (owner == 0) break;
        owner = scrolls[owner].parent;
    }
    return false;
}
fn paintViewport(node: Value, x: usize, y: usize, width: usize, height: usize, owner: usize) Size {
    const st = &scrolls[owner];
    st.seen = true;
    st.parent = scroll_owner;
    st.depth = if (owner == 0) 0 else scrolls[scroll_owner].depth + 1;
    st.x = x;
    st.top = wf.screenY(y);
    st.w = width;
    st.h = height;
    const old_y0 = wf.clip_y0;
    const old_y1 = wf.clip_y1;
    const old_offset = wf.draw_offset_y;
    const old_owner = scroll_owner;
    wf.clip_y0 = @max(old_y0, wf.clipY(y));
    wf.clip_y1 = @min(old_y1, wf.clipY(y + height));
    st.cy0 = wf.clip_y0;
    st.cy1 = wf.clip_y1;
    var size = layoutNode(node, 0, 0, width, false);
    const overflow = size.h > height;
    const content_w = width -| (if (overflow) @as(usize, 14) else 0);
    if (overflow) size = layoutNode(node, 0, 0, content_w, false);
    st.state.fit(size.h, height);
    scroll_owner = owner;
    wf.draw_offset_y -= @intCast(st.state.offset);
    _ = drawNode(node, x, y, content_w);
    wf.draw_offset_y = old_offset;
    scroll_owner = old_owner;
    if (overflow and height > 0 and width >= 8) {
        const thumb = @min(height, @max(20, height * height / @max(1, size.h)));
        const at = (height - thumb) * st.state.offset / @max(1, st.state.limit());
        fillRoundRect(x + width - 8, y, 6, height, 3, pal.surface);
        fillRoundRect(x + width - 8, y + at, 6, thumb, 3, pal.text_muted);
    }
    wf.clip_y0 = old_y0;
    wf.clip_y1 = old_y1;
    return .{ .w = width, .h = height };
}

// A scrollable list's interaction state — its scroll offset and selected
// row — is owned by the runtime and keyed by the widget's id (like a text
// field's edit buffer), so the mshl app stays declarative: it emits the
// rows, we remember where the user is in them. `key` resets scroll and
// selection when the list's content changes (a new directory, say).
const max_lists = 4;
const ListState = struct {
    used: bool = false,
    id: [32]u8 = undefined,
    id_len: usize = 0,
    key: [48]u8 = undefined,
    key_len: usize = 0,
    scroll: usize = 0, // index of the first visible row
    sel: usize = 0, // selected row index
    nrows: usize = 0, // rows the last render laid out (for clamping)
    vis: usize = 0, // rows that fit the viewport (for paging)
    click: ui.pointer.DoubleClick = .{},
};
var list_states: [max_lists]ListState = @splat(.{});

fn resetLists() void {
    list_states = @splat(.{});
}

/// The interaction state for a list id, created on first sight. `key` is
/// the content identity; when it changes, scroll and selection reset to the
/// top so a new directory does not inherit the old one's cursor.
fn listFor(id: []const u8, key: []const u8) *ListState {
    var slot: ?*ListState = null;
    for (&list_states) |*l| {
        if (l.used and std.mem.eql(u8, l.id[0..l.id_len], id)) {
            slot = l;
            break;
        }
    }
    if (slot == null) {
        for (&list_states) |*l| if (!l.used) {
            l.* = .{ .used = true };
            l.id_len = @min(id.len, l.id.len);
            @memcpy(l.id[0..l.id_len], id[0..l.id_len]);
            slot = l;
            break;
        };
    }
    const l = slot orelse &list_states[0];
    if (!std.mem.eql(u8, l.key[0..l.key_len], key)) {
        l.key_len = @min(key.len, l.key.len);
        @memcpy(l.key[0..l.key_len], key[0..l.key_len]);
        l.scroll = 0;
        l.sel = 0;
        l.click = .{};
    }
    return l;
}

/// The focusable whose box contains (x, y) — surface-local, the pointer's
/// coordinates — or null. Topmost-last wins (widgets do not overlap).
fn hitWidget(n: usize, x: usize, y: usize) ?usize {
    var i: usize = 0;
    while (i < n and i < focusables.len) : (i += 1) {
        const f = focusables[i];
        if (x >= f.cx0 and x < f.cx1 and y >= f.cy0 and y < f.cy1 and x >= f.bx and x < f.bx + f.bw and @as(isize, @intCast(y)) >= f.sy and @as(isize, @intCast(y)) < f.sy + @as(isize, @intCast(f.bh))) return i;
    }
    return null;
}

// The runtime owns the live text of each field (keyed by id), seeded from
// the view's `value` when the field first appears. The app's `update`
// sees the committed text only when a button fires (in the event's
// `fields`), so it stays a pure function of coarse events, not keystrokes.
const max_fields = 8;
const FieldBuf = struct {
    used: bool = false,
    id: [32]u8 = undefined,
    id_len: usize = 0,
    edit: ui.text.Editor = .{},
    secret: bool = false,
};
var field_bufs: [max_fields]FieldBuf = @splat(.{});

fn resetFields() void {
    field_bufs = @splat(.{});
    field_drag = null;
}

/// The edit buffer for a field id, created (seeded from `seed`) on first sight.
fn fieldFor(id: []const u8, seed: []const u8) *FieldBuf {
    for (&field_bufs) |*f| {
        if (f.used and std.mem.eql(u8, f.id[0..f.id_len], id)) return f;
    }
    for (&field_bufs) |*f| {
        if (!f.used) {
            f.used = true;
            f.id_len = @min(id.len, f.id.len);
            @memcpy(f.id[0..f.id_len], id[0..f.id_len]);
            f.edit.seed(seed);
            return f;
        }
    }
    return &field_bufs[0]; // more than max_fields: reuse the first slot
}

var field_drag: ?usize = null;
fn fieldClick(focus: Focus, x: usize, select: bool) void {
    const f = fieldFor(focus.id, "");
    const ed = &f.edit;
    var dots: [64]u8 = @splat('*');
    const shown = if (f.secret) dots[0..ed.len] else ed.buf[0..ed.len];
    const local = x -| (focus.bx + fpx);
    const room = focus.bw -| (2 * fpx + 3);
    var pos = ed.first;
    while (pos < ed.len) {
        const next = ed.next(pos);
        const left = strW(R_UI, shown[ed.first..pos]);
        const right = strW(R_UI, shown[ed.first..next]);
        if (local < (left + right) / 2 or left > room) break;
        pos = next;
    }
    ed.move(pos, select);
}

// Arrow keys arrive as private control bytes (inputsvc maps them); a
// focused scrollable list uses them to move its selection.
const key_up: u8 = shared.keyboard.up;
const key_down: u8 = shared.keyboard.down;
const key_left: u8 = shared.keyboard.left;
const key_right: u8 = shared.keyboard.right;

/// Render one view tree. Fills the window, draws the title and each child
/// of the (single, column) layout, highlighting the focused button, and
/// returns the focusable widgets' ids in order (into `ids_buf`).
pub fn strField(rec: mshl.Record, key: []const u8) []const u8 {
    return if (rec.get(key)) |v| (if (v == .str) v.str else "") else "";
}

/// Render one view tree into `focusables`, highlight the focused widget,
/// and return the number of focusable widgets.
const Size = ui.Size;
var content_bg: u32 = 0;
var hovered: ?usize = null;
var pressed: ?usize = null;

const gap = ui.space.medium; // vertical/horizontal space between siblings
const bpx = ui.control.button_x; // button horizontal padding
const bpy = ui.control.button_y; // button vertical padding
const fpx = ui.control.field_x; // field horizontal padding
const fpy = ui.control.field_y; // field vertical padding
const r_btn = ui.control.radius; // button corner radius
const r_field = ui.control.radius; // field corner radius

// Focus recording during a layout pass (draw order over the tree).
var nfoc: usize = 0;
var sel_focus: usize = 0;

/// Draw the widget tree and return the number of focusable widgets. The
/// window is a titlebar over a content area laid out by `drawNode`
/// (columns stack, rows flow), everything coloured from `pal`.
fn renderTree(tree: Value, title: []const u8, focus: usize) usize {
    file_crumb = null;
    clipReset();
    fillAll(pal.bg);
    content_bg = pal.bg;
    sel_focus = focus;
    nfoc = 0;
    nlisthit = 0;
    // The frame paints the titlebar (bar, traffic-light dots, title) and
    // sets `wf.title_h` — the content area starts below it.
    wf.drawChrome(title);
    // Content area below the titlebar. Record the full height it wants so
    // the window can be sized to fit before its surface is created.
    for (scrolls[1..]) |*st| if (st.used and !containsScroll(tree, st.id[0..st.len])) {
        st.* = .{};
    };
    for (&scrolls) |*st| st.seen = false;
    scroll_owner = 0;
    layout_overflow = false;
    _ = paintViewport(tree, pad, wf.title_h + pad, wf.win_w -| (2 * pad), wf.win_h -| (wf.title_h + 2 * pad), 0);
    return nfoc;
}

/// Lay the tree out without drawing, to find the window height its content
/// needs (clamped to the scanout), and centre the window at it.
fn sizeToContent(it: *mshl.Interp, view: Value, state: Value, title: []const u8) void {
    const tree = it.callValue(view, &.{state}, null, null) catch return;
    wf.measuring = true;
    wf.drawChrome(title);
    content_h = wf.title_h + 2 * pad + layoutNode(tree, 0, 0, wf.win_w - 2 * pad, false).h;
    wf.measuring = false;
    // Centre inside the desktop work area the compositor publishes (between
    // the bar and the dock). Using the whole scanout placed tall windows
    // underneath the dock.
    const wa = settledWorkArea();
    const work_top = wa.y + 8;
    const work_bottom = (wa.y + wa.h) -| 8;
    const available = work_bottom -| work_top;
    wf.win_h = @min(@max(win_h_min, content_h), @min(wf.win_h_max, available));
    wf.win_y = work_top + (available - wf.win_h) / 2;
}

/// Children remain ordinary mshl data, shared by measurement and painting.
fn nodeChildren(rec: mshl.Record) []const Value {
    const c = rec.get("children") orelse return &.{};
    return if (c == .list) c.list else &.{};
}

fn nodeGap(rec: mshl.Record) usize {
    return @intCast(std.math.clamp(intField(rec, "gap", gap), 0, 64));
}

fn drawNode(node: Value, x: usize, y: usize, avail_w: usize) Size {
    const old_x0 = wf.clip_x0;
    const old_x1 = wf.clip_x1;
    wf.clip_x0 = @max(old_x0, x);
    wf.clip_x1 = @min(old_x1, x + avail_w);
    defer {
        wf.clip_x0 = old_x0;
        wf.clip_x1 = old_x1;
    }
    return layoutNode(node, x, y, avail_w, true);
}

/// The tree layout is the toolkit's (lib/ui/layout.zig): this is the mshl
/// record tree seen through its node interface. Leaves and viewports keep
/// their painters here, because they own runtime state (fields, lists,
/// scroll owners, focus targets); everything about *where* things go is
/// the engine's, so measurement and painting cannot disagree.
const MshlTree = struct {
    pub const Node = Value;
    pub fn kind(_: *MshlTree, n: Node) ui.layout.Kind {
        if (n != .record) return .none;
        const rec = n.record;
        const k = strField(rec, "kind");
        if (std.mem.eql(u8, k, "scroll")) return .scroll;
        if (std.mem.eql(u8, k, "row")) return .row;
        if (std.mem.eql(u8, k, "section")) return .section;
        if (std.mem.eql(u8, k, "column") or nodeChildren(rec).len != 0) return .column;
        if (std.mem.eql(u8, k, "split")) return .split;
        return .leaf; // icon, breadcrumbs, label, button, field, list — or unknown (empty)
    }
    pub fn children(_: *MshlTree, n: Node) []const Node {
        return nodeChildren(n.record);
    }
    pub fn gap(_: *MshlTree, n: Node) usize {
        return nodeGap(n.record);
    }
    pub fn flex(_: *MshlTree, n: Node) usize {
        return flexWeight(n);
    }
    pub fn scrollHeight(_: *MshlTree, n: Node) usize {
        return @intCast(std.math.clamp(intField(n.record, "h", 240), 40, 4096));
    }
    pub fn scrollChild(_: *MshlTree, n: Node) ?Node {
        return n.record.get("child");
    }
    pub fn splitLeft(_: *MshlTree, n: Node) ?Node {
        return n.record.get("left");
    }
    pub fn splitRight(_: *MshlTree, n: Node) ?Node {
        return n.record.get("right");
    }
    pub fn splitLeftWidth(_: *MshlTree, n: Node) usize {
        return @intCast(@max(intField(n.record, "left_w", 220), 0));
    }
    pub fn leafMeasure(_: *MshlTree, n: Node, avail_w: usize) Size {
        return leafLayout(n.record, 0, 0, avail_w, false);
    }
    pub fn leafPaint(_: *MshlTree, n: Node, x: usize, y: usize, avail_w: usize) Size {
        return leafLayout(n.record, x, y, avail_w, true);
    }
    pub fn childPaint(_: *MshlTree, n: Node, x: usize, y: usize, avail_w: usize) Size {
        return drawNode(n, x, y, avail_w);
    }
    pub fn viewportPaint(_: *MshlTree, n: Node, child: Node, x: usize, y: usize, w: usize, h: usize) Size {
        const id = strField(n.record, "id");
        if (id.len == 0 or id.len > 64) {
            layout_overflow = true;
            return .{};
        }
        const owner = scrollFor(id);
        if (owner == 0) return .{};
        return paintViewport(child, x, y, w, h, owner);
    }
    pub fn sectionBegin(_: *MshlTree, x: usize, y: usize, w: usize, h: usize) void {
        if (section_depth < section_bg_saved.len) section_bg_saved[section_depth] = content_bg;
        section_depth += 1;
        panel(x, y, w, h, r_field, pal.surface, pal.border, pal.border_w);
        content_bg = pal.surface;
    }
    pub fn sectionEnd(_: *MshlTree) void {
        section_depth -= 1;
        if (section_depth < section_bg_saved.len) content_bg = section_bg_saved[section_depth];
    }
    pub fn dividerPaint(_: *MshlTree, x: usize, y: usize, h: usize) void {
        fillRect(x, y, pal.border_w, h, pal.border);
    }
};
var mshl_tree: MshlTree = .{};
var section_bg_saved: [16]u32 = undefined; // nested sections restore the text ground
var section_depth: usize = 0;
const Engine = ui.layout.Engine(MshlTree);

/// Measurement never creates edit buffers, focus targets, or list state.
/// Both passes use the same layout decisions, including wrapped rows.
fn layoutNode(node: Value, x: usize, y: usize, avail_w: usize, paint: bool) Size {
    return if (paint) Engine.paint(&mshl_tree, node, x, y, avail_w) else Engine.measure(&mshl_tree, node, avail_w);
}

/// A leaf's own size and paint: the widgets that own runtime state.
fn leafLayout(rec: mshl.Record, x: usize, y: usize, avail_w: usize, paint: bool) Size {
    const kind = strField(rec, "kind");
    if (std.mem.eql(u8, kind, "icon")) {
        const size = @min(avail_w, if (rec.get("size") != null) wf.scaledIconSize(@intCast(std.math.clamp(intField(rec, "size", 20), 12, 64))) else wf.iconSize());
        if (paint) wf.drawIcon(x, y, size, strField(rec, "name"), pal.text);
        return .{ .w = size, .h = size };
    }
    if (std.mem.eql(u8, kind, "breadcrumbs")) return layoutBreadcrumb(rec, x, y, avail_w, paint);
    if (std.mem.eql(u8, kind, "label")) {
        return layoutLabel(rec, x, y, avail_w, paint);
    }
    if (std.mem.eql(u8, kind, "button")) {
        if (paint) return drawButton(rec, x, y, avail_w);
        return .{ .w = @min(avail_w, iconLabelWidth(rec, "label") + 2 * bpx), .h = @max(lineOf(R_UI), wf.iconSize()) + 2 * bpy };
    }
    if (std.mem.eql(u8, kind, "field")) {
        if (paint) return drawField(rec, x, y, avail_w);
        return .{ .w = avail_w, .h = lineOf(R_UI) + 2 * fpy + (if (strField(rec, "label").len > 0) lineOf(R_UI) + 6 else @as(usize, 0)) };
    }
    if (std.mem.eql(u8, kind, "list")) {
        if (paint) return drawList(rec, x, y, avail_w);
        return .{ .w = avail_w, .h = @intCast(@max(intField(rec, "h", 240), 40)) };
    }
    return .{};
}

fn flexWeight(node: Value) usize {
    if (node != .record) return 0;
    return @intCast(std.math.clamp(intField(node.record, "flex", 0), 0, 64));
}
fn layoutLabel(rec: mshl.Record, x: usize, y: usize, avail_w: usize, paint: bool) Size {
    const text = strField(rec, "text");
    const muted = rec.get("muted") != null and (rec.get("muted").?).asBool();
    const strong = std.mem.eql(u8, strField(rec, "role"), "title");
    const role: u64 = if (strong) R_TITLE else R_UI;
    const ink = if (strong) pal.title else if (muted) pal.text_muted else pal.text;
    if (!(if (rec.get("wrap")) |v| v.asBool() else false) or avail_w == 0) {
        if (paint) drawStrTrunc(x, y, role, text, avail_w, ink, content_bg);
        return .{ .w = @min(avail_w, strW(role, text)), .h = lineOf(role) };
    }
    var start: usize = 0;
    var lines: usize = 0;
    var width: usize = 0;
    while (start < text.len) {
        const line_end = if (std.mem.indexOfScalarPos(u8, text, start, '\n')) |at| at else text.len;
        var end = line_end;
        if (strW(role, text[start..end]) > avail_w) {
            var lo = start;
            var hi = end;
            while (lo < hi) {
                var mid = lo + (hi - lo + 1) / 2;
                while (mid < line_end and text[mid] & 0xc0 == 0x80) mid += 1;
                if (strW(role, text[start..mid]) <= avail_w) lo = mid else {
                    hi = mid - 1;
                    while (hi > start and text[hi] & 0xc0 == 0x80) hi -= 1;
                }
            }
            end = lo;
            if (end == start) end = @min(line_end, start + (std.unicode.utf8ByteSequenceLength(text[start]) catch 1));
            if (end < line_end) {
                if (std.mem.lastIndexOfScalar(u8, text[start..end], ' ')) |at| if (at > 0) {
                    end = start + at;
                };
            }
        }
        if (paint) drawStr(x, y + lines * lineOf(role), role, text[start..end], ink, content_bg);
        width = @max(width, @min(avail_w, strW(role, text[start..end])));
        lines += 1;
        start = end;
        if (start < text.len and text[start] == '\n') start += 1 else while (start < text.len and text[start] == ' ') {
            start += 1;
        }
    }
    return .{ .w = width, .h = @max(1, lines) * lineOf(role) };
}

/// A raised button: a filled box with a lighter top edge and a darker
/// bottom edge (a little depth, not flat), a border, and — when focused —
/// a bright ring. `variant` gives it semantic colour: primary
/// (the accent), danger (destructive), or the neutral surface default.
fn hasIcon(rec: mshl.Record) bool {
    return ui.icons.parse(strField(rec, "icon")) != null;
}
fn iconOnly(rec: mshl.Record) bool {
    return hasIcon(rec) and (if (rec.get("icon_only")) |v| v.asBool() else false);
}
pub fn iconLabelWidth(rec: mshl.Record, field: []const u8) usize {
    const text = if (iconOnly(rec)) "" else strField(rec, field);
    return strW(R_UI, text) + (if (hasIcon(rec)) wf.iconSize() + (if (text.len > 0) @as(usize, 8) else 0) else 0);
}
pub fn drawIconLabel(rec: mshl.Record, field: []const u8, x: usize, y: usize, w: usize, h: usize, ink: u32, bg: u32) void {
    const size = wf.iconSize();
    const text = if (iconOnly(rec)) "" else strField(rec, field);
    const inset = if (hasIcon(rec)) size + (if (text.len > 0) @as(usize, 8) else 0) else 0;
    if (hasIcon(rec) and w >= size) wf.drawIcon(x, y + (h -| size) / 2, size, strField(rec, "icon"), ink);
    drawStrTrunc(x + inset, y + (h -| lineOf(R_UI)) / 2, R_UI, text, w -| inset, ink, bg);
}

const Crumb = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    path: [256]u8 = undefined,
    path_len: usize = 0,
    root: []const u8 = "",
    selected: usize = 0,
    can_lock: bool = false,
    can_leave: bool = false,
    fn model(self: *const Crumb) ui.breadcrumbs.Model {
        return ui.breadcrumbs.Model.init(self.path[0..self.path_len]).?;
    }
};
var crumbs: [16]Crumb = @splat(.{});
var file_crumb: ?*Crumb = null;
/// What the `files` menu profile's items mean to this app: the event ids
/// the script handles and the widget ids it lays out, declared in its
/// spec (`bindings: { up, lock, leave, refresh, home, open, location }`)
/// rather than known here. An item without a binding is disabled.
const Binding = struct {
    buf: [32]u8 = undefined,
    len: usize = 0,
    fn set(self: *Binding, s: []const u8) void {
        self.len = @min(s.len, self.buf.len);
        @memcpy(self.buf[0..self.len], s[0..self.len]);
    }
    fn get(self: *const Binding) []const u8 {
        return self.buf[0..self.len];
    }
    fn is(self: *const Binding, id: []const u8) bool {
        return self.len > 0 and std.mem.eql(u8, self.get(), id);
    }
};
const FilesBindings = struct { up: Binding = .{}, lock: Binding = .{}, leave: Binding = .{}, refresh: Binding = .{}, home: Binding = .{}, open: Binding = .{}, location: Binding = .{} };
var files_bindings: FilesBindings = .{};
fn loadBindings(spec: mshl.Record) void {
    files_bindings = .{};
    const b = spec.get("bindings") orelse return;
    if (b != .record) return;
    inline for (@typeInfo(FilesBindings).@"struct".fields) |f| @field(files_bindings, f.name).set(strField(b.record, f.name));
}
var crumb_pressed: ?usize = null;
fn crumbFor(id: []const u8, path: []const u8) ?*Crumb {
    if (id.len == 0 or id.len > 64) return null;
    var empty: ?*Crumb = null;
    for (&crumbs) |*c| {
        if (c.id_len == id.len and std.mem.eql(u8, c.id[0..c.id_len], id)) {
            if (!std.mem.eql(u8, c.path[0..c.path_len], path)) {
                @memcpy(c.path[0..path.len], path);
                c.path_len = path.len;
                c.selected = 0;
            }
            return c;
        }
        if (c.id_len == 0 and empty == null) empty = c;
    }
    const c = empty orelse return null;
    c.* = .{};
    @memcpy(c.id[0..id.len], id);
    c.id_len = id.len;
    @memcpy(c.path[0..path.len], path);
    c.path_len = path.len;
    return c;
}
fn crumbWidth(part: ui.breadcrumbs.Part, last: bool, width: usize) usize {
    return @min(width, strW(R_UI, part.label) + 20 + (if (last) @as(usize, 0) else 24));
}
fn layoutBreadcrumb(rec: mshl.Record, x: usize, y: usize, width: usize, paint: bool) Size {
    if (width == 0) return .{};
    const path = strField(rec, "path");
    const model = ui.breadcrumbs.Model.init(path) orelse return layoutLabel(rec, x, y, width, paint);
    const root = strField(rec, "root");
    const h = lineOf(R_UI) + 16;
    const state = if (paint) crumbFor(strField(rec, "id"), path) else null;
    if (paint and state == null) {
        layout_overflow = true;
        return .{};
    }
    if (state) |c| {
        c.root = root;
        c.can_lock = if (rec.get("can_lock")) |v| v.asBool() else false;
        c.can_leave = if (rec.get("can_leave")) |v| v.asBool() else false;
        c.selected = @min(c.selected, model.count -| 2);
        if (files_bindings.location.is(strField(rec, "id"))) file_crumb = c;
    }
    var flow: ui.flow.Flow = .{ .width = width, .gap = 4 };
    for (0..model.count) |i| {
        const part = model.at(i, root).?;
        const last = i + 1 == model.count;
        const place = flow.put(.{ .w = crumbWidth(part, last, width), .h = h });
        if (paint) {
            const c = state.?;
            const focused = wf.win_focused and nfoc == sel_focus and c.selected == i and !last;
            const label_w = place.w -| (if (last) @as(usize, 0) else 24);
            if (focused) panel(x + place.x, y + place.y, label_w, h, 4, pal.surface_hi, pal.focus, pal.focus_w);
            drawStrTrunc(x + place.x + 10, y + place.y + 8, R_UI, part.label, label_w -| 20, if (last) pal.text else pal.focus, pal.bg);
            if (!last and place.w >= 24) drawStr(x + place.x + place.w - 19, y + place.y + 8, R_UI, "›", pal.text_muted, pal.bg);
        }
    }
    const size = flow.size();
    if (paint and model.count > 1) recordFocus(.{ .id = strField(rec, "id"), .is_field = false, .crumb = state, .bx = x, .by = y, .bw = width, .bh = size.h });
    return .{ .w = width, .h = size.h };
}
fn crumbHit(f: Focus, x: usize, y: usize) ?usize {
    const c = f.crumb orelse return null;
    const model = c.model();
    const yy = @as(isize, @intCast(y)) - f.sy;
    if (x < f.bx or yy < 0) return null;
    const xx = x - f.bx;
    var flow: ui.flow.Flow = .{ .width = f.bw, .gap = 4 };
    const h = lineOf(R_UI) + 16;
    for (0..model.count) |i| {
        const last = i + 1 == model.count;
        const place = flow.put(.{ .w = crumbWidth(model.at(i, c.root).?, last, f.bw), .h = h });
        if (!last and xx >= place.x and xx < place.x + (place.w -| 24) and yy >= place.y and yy < place.y + h) return i;
    }
    return null;
}

fn drawButton(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const variant = strField(rec, "variant");
    const disabled = if (rec.get("disabled")) |v| v.asBool() else false;
    const focused = !disabled and wf.win_focused and nfoc == sel_focus;
    const w = @min(avail_w, iconLabelWidth(rec, "label") + 2 * bpx);
    const h = @max(lineOf(R_UI), wf.iconSize()) + 2 * bpy;

    var fill: u32 = pal.surface_hi;
    var ink: u32 = pal.text;
    if (std.mem.eql(u8, variant, "primary")) {
        fill = pal.primary;
        ink = pal.primary_ink;
    } else if (std.mem.eql(u8, variant, "danger")) {
        fill = pal.danger;
        ink = pal.danger_ink;
    }
    if (disabled) {
        fill = pal.surface;
        ink = pal.text_muted;
    }
    // A rounded panel. Focus is a double cue (never colour alone): the
    // border becomes a bright, thicker ring. Hover and press change the fill.
    const ring = if (focused) pal.focus else pal.border;
    const ring_w = if (focused) pal.focus_w else pal.border_w;
    if (!disabled and hovered == nfoc) fill = shade(fill, 9, 8);
    if (!disabled and pressed == nfoc and hovered == nfoc) fill = shade(fill, 4, 5);
    panel(x, y, w, h, r_btn, fill, ring, ring_w);
    // A soft top highlight inside the rounded fill — a hint of depth, not
    // a hard bar (kept clear of the corners so it never pokes past them).
    fillRect(x + r_btn, y + ring_w, w -| (2 * r_btn), 1, shade(fill, 6, 5));
    drawIconLabel(rec, "label", x + bpx, y, w -| (2 * bpx), h, ink, fill);
    if (!disabled and nfoc < focusables.len) {
        recordFocus(.{ .id = strField(rec, "id"), .is_field = false, .bx = x, .by = y, .bw = w, .bh = h });
    }
    return .{ .w = w, .h = h };
}

/// A text field: a muted label over an inset value box (a darker fill with
/// a bright caret when focused). A `secret` field shows dots.
fn drawField(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const label = strField(rec, "label");
    const id = strField(rec, "id");
    const fb = fieldFor(id, strField(rec, "value"));
    const focused = wf.win_focused and nfoc == sel_focus;
    var yy = y;
    if (label.len > 0) {
        drawStr(x, yy, R_UI, label, pal.text_muted, content_bg);
        yy += lineOf(R_UI) + 6;
    }
    const bh = lineOf(R_UI) + 2 * fpy;
    const ring = if (focused) pal.focus else pal.border;
    const ring_w = if (focused) pal.focus_w else pal.border_w;
    panel(x, yy, avail_w, bh, r_field, pal.field_bg, ring, ring_w);
    const tx = x + fpx;
    const ty = yy + fpy;
    const secret = rec.get("secret") != null and (rec.get("secret").?).asBool();
    fb.secret = secret;
    var dots: [64]u8 = undefined;
    const shown: []const u8 = if (secret) blk: {
        const mlen = @min(fb.edit.len, dots.len);
        for (0..mlen) |i| dots[i] = '*';
        break :blk dots[0..mlen];
    } else fb.edit.buf[0..fb.edit.len];
    const ed = &fb.edit;
    const room = avail_w -| (2 * fpx + 3);
    ed.first = @min(ed.first, ed.cursor);
    while (ed.first < ed.cursor and strW(R_UI, shown[ed.first..ed.cursor]) > room) ed.first = ed.next(ed.first);
    var last = ed.first;
    while (last < ed.len) {
        const next = ed.next(last);
        if (strW(R_UI, shown[ed.first..next]) > room) break;
        last = next;
    }
    const lo = @max(ed.first, ed.low());
    const hi = @min(last, ed.high());
    if (focused and hi > lo) {
        const sx = tx + strW(R_UI, shown[ed.first..lo]);
        const sw = strW(R_UI, shown[lo..hi]);
        fillRect(sx, ty, sw, lineOf(R_UI), pal.focus);
        drawStr(tx, ty, R_UI, shown[ed.first..lo], pal.text, pal.field_bg);
        drawStr(sx, ty, R_UI, shown[lo..hi], pal.bg, pal.focus);
        drawStr(sx + sw, ty, R_UI, shown[hi..last], pal.text, pal.field_bg);
    } else drawStr(tx, ty, R_UI, shown[ed.first..last], pal.text, pal.field_bg);
    if (focused) fillRect(tx + strW(R_UI, shown[ed.first..ed.cursor]), ty, 2, lineOf(R_UI), pal.focus);
    if (nfoc < focusables.len) {
        recordFocus(.{ .id = id, .is_field = true, .bx = x, .by = yy, .bw = avail_w, .bh = bh });
    }
    return .{ .w = avail_w, .h = (yy - y) + bh };
}

fn intField(rec: mshl.Record, key: []const u8, dflt: i64) i64 {
    return if (rec.get(key)) |v| (if (v == .int) v.int else dflt) else dflt;
}

// A rendered list's geometry, so a click maps to a row (and the scrollbar
// to a page). Recorded each render, like `focusables`.
const ListHit = struct {
    id: []const u8,
    x: usize = 0,
    rows_top: usize = 0,
    offset_y: isize = 0,
    rows_w: usize = 0,
    row_h: usize = 0,
    sb_x: usize = 0, // scrollbar centre (surface-local), 0 = no scrollbar
    st: *ListState = undefined,
};
var list_hits: [max_lists]ListHit = undefined;
var nlisthit: usize = 0;

const list_row_vpad = 6; // vertical padding within a list row
const list_cell_pad = 10; // left inset of the first cell

// A list's `rows` come as either a plain list of `{id, cells}` records or —
// when built with `map`, which tableizes uniform records — a table with
// those fields as columns. These read both shapes the same way.
fn rowsLen(rv: Value) usize {
    return switch (rv) {
        .list => |l| l.len,
        .table => |t| t.rows.len,
        else => 0,
    };
}
fn colIndex(cols: []const []const u8, name: []const u8) ?usize {
    for (cols, 0..) |c, i| if (std.mem.eql(u8, c, name)) return i;
    return null;
}
fn rowField(rv: Value, i: usize, name: []const u8) Value {
    switch (rv) {
        .list => |l| if (i < l.len and l[i] == .record) return l[i].record.get(name) orelse .nothing,
        .table => |t| if (i < t.rows.len) {
            if (colIndex(t.cols, name)) |ci| if (ci < t.rows[i].len) return t.rows[i][ci];
        },
        else => {},
    }
    return .nothing;
}
fn cellAt(cellsv: Value, ci: usize) []const u8 {
    if (cellsv == .list and ci < cellsv.list.len and cellsv.list[ci] == .str) return cellsv.list[ci].str;
    return "";
}

/// A scrollable, selectable list. Record fields: `id` (interaction key),
/// `key` (content identity — a new value resets scroll/selection), `h`
/// (viewport height in px), optional `cols` [{title, w, right?}] for a
/// header + column layout, and `rows` [{id, cells:[str], icon?}]. `fit`
/// treats column widths as weights; `empty` supplies a placeholder and
/// `active` controls selection highlighting. The runtime owns
/// the scroll offset and selection (see `ListState`); the app just emits
/// the rows. Registers one focusable (the whole list), so its rows never
/// eat the focusable budget.
fn drawList(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const id = strField(rec, "id");
    const key = strField(rec, "key");
    const rowsv: Value = rec.get("rows") orelse Value.nothing;
    const nrows = rowsLen(rowsv);
    const cols: []const Value = if (rec.get("cols")) |cv| (if (cv == .list) cv.list else &.{}) else &.{};
    const box_h: usize = @intCast(@max(intField(rec, "h", 240), 40));
    const w = avail_w;
    const line = lineOf(R_UI);
    const row_h = line + 2 * list_row_vpad;
    const header_h: usize = if (cols.len > 0) line + 2 * list_row_vpad else 0;

    const focused = wf.win_focused and nfoc == sel_focus;
    const active = if (rec.get("active")) |v| v.asBool() else true;
    const fit = if (rec.get("fit")) |v| v.asBool() else false;
    var total_weight: usize = 0;
    for (cols) |cv| if (cv == .record) {
        total_weight += @intCast(std.math.clamp(intField(cv.record, "w", 80), 1, 4096));
    };
    const tracks_w = w -| (2 * list_cell_pad + 8);
    panel(x, y, w, box_h, r_field, pal.field_bg, if (focused) pal.focus else pal.border, if (focused) pal.focus_w else pal.border_w);

    // Header: muted column titles + a rule beneath them.
    if (cols.len > 0) {
        var hx = x + list_cell_pad;
        var before: usize = 0;
        for (cols) |cv| {
            if (cv != .record) continue;
            const weight: usize = @intCast(std.math.clamp(intField(cv.record, "w", 80), 1, 4096));
            const cw = if (fit) ui.flow.trackWidth(tracks_w, total_weight, before, weight) else weight;
            before += weight;
            const text = strField(cv.record, "title");
            const right = if (cv.record.get("right")) |v| v.asBool() else false;
            const offset = if (right) (cw -| 8) -| strW(R_UI, text) else 0;
            drawStrTrunc(hx + offset, y + list_row_vpad, R_UI, text, cw -| 8, pal.text_muted, pal.field_bg);
            hx += cw;
        }
        fillRect(x + pal.border_w, y + header_h, w -| (2 * pal.border_w), pal.border_w, pal.border);
    }

    const rows_top = y + header_h;
    const inner_h = if (box_h > header_h + pal.border_w) box_h - header_h - pal.border_w else 0;
    var vis = inner_h / row_h;
    if (vis == 0) vis = 1;

    const st = listFor(id, key);
    st.nrows = nrows;
    st.vis = vis;
    if (nrows == 0) st.sel = 0 else if (st.sel >= nrows) st.sel = nrows - 1;
    // Only clamp the scroll to the last page here; following the selection
    // into view is done when the selection *moves* (a click or arrow key),
    // so a free scroll (the scrollbar) is not undone by a stale selection.
    const max_scroll = if (nrows > vis) nrows - vis else 0;
    if (st.scroll > max_scroll) st.scroll = max_scroll;

    const has_sb = nrows > vis;
    const sb_w: usize = if (has_sb) 8 else 0;
    const rows_w = if (w > 2 * pal.border_w + sb_w) w - 2 * pal.border_w - sb_w else 0;

    // Clip the rows to the viewport (below the header, above the bottom edge,
    // left of the scrollbar), so a partial bottom row is cut cleanly.
    const sx0 = wf.clip_x0;
    const sy0 = wf.clip_y0;
    const sx1 = wf.clip_x1;
    const sy1 = wf.clip_y1;
    wf.clip_x0 = @max(wf.clip_x0, x + pal.border_w);
    wf.clip_y0 = @max(wf.clip_y0, wf.clipY(rows_top));
    wf.clip_x1 = @min(wf.clip_x1, x + pal.border_w + rows_w);
    wf.clip_y1 = @min(wf.clip_y1, wf.clipY(y + box_h - pal.border_w));

    if (nrows == 0) {
        const message = strField(rec, "empty");
        drawStrTrunc(x + list_cell_pad, rows_top + list_row_vpad + 8, R_UI, message, rows_w -| (2 * list_cell_pad), pal.text_muted, pal.field_bg);
    }
    var i = st.scroll;
    var ry = rows_top;
    while (i < nrows and i < st.scroll + vis) : (i += 1) {
        const selected = active and i == st.sel;
        const cell_bg = if (selected) (if (focused) pal.primary else pal.surface_hi) else pal.field_bg;
        if (selected) fillRect(x + pal.border_w, ry, rows_w, row_h, cell_bg);
        const ink = if (selected and focused) pal.primary_ink else pal.text;
        const iconv = rowField(rowsv, i, "icon");
        const icon = if (iconv == .str) iconv.str else "";
        const icon_size = wf.iconSize();
        const known_icon = ui.icons.parse(icon) != null;
        const icon_pad: usize = if (known_icon) icon_size + 8 else 0;
        if (known_icon) {
            const color = if (selected and focused) pal.primary_ink else pal.primary;
            wf.drawIcon(x + list_cell_pad, ry + (row_h -| icon_size) / 2, icon_size, icon, color);
        }
        const ty = ry + list_row_vpad;
        const cellsv = rowField(rowsv, i, "cells");
        if (cols.len > 0) {
            var cx = x + list_cell_pad;
            var before: usize = 0;
            for (cols, 0..) |cv, ci| {
                if (cv != .record) continue;
                const weight: usize = @intCast(std.math.clamp(intField(cv.record, "w", 80), 1, 4096));
                const cw = if (fit) ui.flow.trackWidth(tracks_w, total_weight, before, weight) else weight;
                before += weight;
                const text = cellAt(cellsv, ci);
                const inset = if (ci == 0) icon_pad else 0;
                const right = if (cv.record.get("right")) |v| v.asBool() else false;
                const offset = if (right) (cw -| 8) -| strW(R_UI, text) else inset;
                drawStrTrunc(cx + offset, ty, R_UI, text, cw -| (8 + offset), if (ci > 0 and !selected) pal.text_muted else ink, cell_bg);
                cx += cw;
            }
        } else {
            drawStrTrunc(x + list_cell_pad + icon_pad, ty, R_UI, cellAt(cellsv, 0), rows_w -| (2 * list_cell_pad + icon_pad), ink, cell_bg);
        }
        ry += row_h;
    }
    wf.clip_x0 = sx0;
    wf.clip_y0 = sy0;
    wf.clip_x1 = sx1;
    wf.clip_y1 = sy1;

    // Scrollbar: a track and a proportional thumb on the right edge.
    if (has_sb) {
        const track_x = x + w - sb_w - pal.border_w;
        const track_top = rows_top;
        const track_h = inner_h;
        fillRect(track_x, track_top, sb_w, track_h, shade(pal.field_bg, 5, 4));
        const thumb_h = @max(track_h * vis / nrows, 16);
        const span = track_h -| thumb_h;
        const thumb_y = track_top + (if (max_scroll > 0) span * st.scroll / max_scroll else 0);
        fillRect(track_x + 1, thumb_y, sb_w -| 2, thumb_h, pal.text_muted);
    }

    if (nlisthit < list_hits.len) {
        const sb_x = if (has_sb) x + w - sb_w / 2 - pal.border_w else 0;
        list_hits[nlisthit] = .{ .id = id, .x = x, .rows_top = rows_top, .offset_y = wf.draw_offset_y, .rows_w = rows_w, .row_h = row_h, .sb_x = sb_x, .st = st };
        nlisthit += 1;
    }
    if (nfoc < focusables.len) {
        recordFocus(.{ .id = id, .is_field = false, .is_list = true, .bx = x, .by = y, .bw = w, .bh = box_h });
    }
    return .{ .w = w, .h = box_h };
}

/// Find the `rows` value (a list or a tableized list) of the `list` widget
/// with this id anywhere in the tree (searching children and split panes) —
/// so a fired list event can carry the selected row's own id.
fn findListRows(node: Value, id: []const u8) ?Value {
    if (node != .record) return null;
    const rec = node.record;
    if (std.mem.eql(u8, strField(rec, "kind"), "list") and std.mem.eql(u8, strField(rec, "id"), id)) {
        return rec.get("rows") orelse Value.nothing;
    }
    if (rec.get("children")) |c| if (c == .list) for (c.list) |ch| {
        if (findListRows(ch, id)) |r| return r;
    };
    if (rec.get("child")) |c| if (findListRows(c, id)) |r| return r;
    if (rec.get("left")) |l| if (findListRows(l, id)) |r| return r;
    if (rec.get("right")) |r2| if (findListRows(r2, id)) |r| return r;
    return null;
}

fn listRowId(tree: Value, id: []const u8, idx: usize) []const u8 {
    const rowsv = findListRows(tree, id) orelse return "";
    const idv = rowField(rowsv, idx, "id");
    return if (idv == .str) idv.str else "";
}

fn listStateById(id: []const u8) ?*ListState {
    for (&list_states) |*l| {
        if (l.used and std.mem.eql(u8, l.id[0..l.id_len], id)) return l;
    }
    return null;
}

/// Scroll a list so its selection is on screen — called when the selection
/// moves (a click or an arrow key), never on a plain render, so free
/// scrolling (the scrollbar) is not clamped back to the selection.
fn keepSelVisible(st: *ListState) void {
    if (st.sel < st.scroll) st.scroll = st.sel;
    if (st.vis > 0 and st.sel >= st.scroll + st.vis) st.scroll = st.sel + 1 - st.vis;
}

const ListClick = struct { fire: bool = false, activated: bool = false, row: usize = 0 };

/// Route a click at (x, y) inside the list `id`: a row click moves the
/// selection (a reclick on the same row activates it); a scrollbar-track
/// click pages. Returns whether to fire a list event and for which row.
fn listClick(id: []const u8, x: usize, screen_y: usize) ListClick {
    for (list_hits[0..nlisthit]) |lh| {
        if (!std.mem.eql(u8, lh.id, id)) continue;
        const st = lh.st;
        const y: usize = @intCast(@max(0, @as(isize, @intCast(screen_y)) - lh.offset_y));
        // The scrollbar sits to the right of the rows: click the upper or
        // lower half of the track to page up or down.
        if (x >= lh.x + lh.rows_w) {
            const mid = lh.rows_top + lh.row_h * st.vis / 2;
            if (y < mid) st.scroll = st.scroll -| st.vis else st.scroll += st.vis;
            return .{};
        }
        if (y < lh.rows_top) return .{};
        const row = st.scroll + (y - lh.rows_top) / lh.row_h;
        if (row >= st.nrows) return .{};
        const activated = st.click.press(row, usys.nowMs());
        st.sel = row;
        keepSelVisible(st);
        return .{ .fire = true, .activated = activated, .row = row };
    }
    return .{};
}

// ------------------------------------------------------------ the app

/// The event for a fired button: `{ id, fields: { <field id>: <text> } }`.
/// The field values are the runtime's live buffers — this is where the
/// text a user typed reaches the app, and the only place it does.
fn mkEvent(it: *mshl.Interp, id: []const u8) mshl.Error!Value {
    var nf: usize = 0;
    for (field_bufs) |f| {
        if (f.used) nf += 1;
    }
    const fkeys = try it.arena.alloc([]const u8, nf);
    const fvals = try it.arena.alloc(Value, nf);
    var i: usize = 0;
    for (field_bufs) |f| {
        if (!f.used) continue;
        fkeys[i] = try it.arena.dupe(u8, f.id[0..f.id_len]);
        fvals[i] = .{ .str = try it.arena.dupe(u8, f.edit.buf[0..f.edit.len]) };
        i += 1;
    }
    const fields = Value{ .record = .{ .keys = fkeys, .vals = fvals } };

    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "id";
    keys[1] = "fields";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = .{ .str = try it.arena.dupe(u8, id) };
    vals[1] = fields;
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// The event a list fires: `{ id: <listId>, row: <rowId>, activated: bool }`
/// — `activated` true for Enter or a reclick (open), false for a plain
/// selection (the app updates a preview). The app maps `row` to its data.
fn mkListEvent(it: *mshl.Interp, id: []const u8, row: []const u8, activated: bool) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 3);
    keys[0] = "id";
    keys[1] = "row";
    keys[2] = "activated";
    const vals = try it.arena.alloc(Value, 3);
    vals[0] = .{ .str = try it.arena.dupe(u8, id) };
    vals[1] = .{ .str = try it.arena.dupe(u8, row) };
    vals[2] = .{ .bool = activated };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

pub fn isDone(state: Value) bool {
    if (state != .record) return false;
    const d = state.record.get("done") orelse return false;
    return d.asBool();
}

// The desktop chrome — the top bar with its menus and the dock — lives in
// guibar.zig and guidock.zig; they are `gui` apps with a fixed place on
// the output rather than windows.
const guibar = @import("guibar.zig");
const guidock = @import("guidock.zig");

// ------------------------------------------------- crash-isolated update

/// Reconstruct `update` (a `fn [stateParam, evParam] body`) as a worker
/// script that reads `$in`: bind each param, by position, from the
/// `{ state, ev }` record the runtime sends, then run the body verbatim.
/// Only data crosses — no captures — so the worker is a pure function of
/// the pair, exactly the GUI-as-a-service contract. The two params are
/// bound from the input's fixed `state`/`ev` fields regardless of how the
/// app named them. Returns null if `update` is not the expected 2-arg
/// shape (then the caller runs it in-process, unisolated). Arena-held, so
/// it survives across re-spawns within this `gui` call.
fn buildUpdateSrc(it: *mshl.Interp, cl: *const mshl.Closure) mshl.Error!?[]const u8 {
    if (cl.params.len != 2) return null;
    const in_keys = [_][]const u8{ "state", "ev" };
    var s: std.ArrayList(u8) = .empty;
    for (cl.params, in_keys) |p, key| {
        try s.appendSlice(it.arena, "let ");
        try s.appendSlice(it.arena, p);
        try s.appendSlice(it.arena, " = $in.");
        try s.appendSlice(it.arena, key);
        try s.append(it.arena, '\n');
    }
    try s.appendSlice(it.arena, cl.src);
    return s.items;
}

/// Reconstruct the whole app — `update` and `view` — as one worker script
/// that reads `$in = { state, ev, apply }` and returns `{ state, tree }`:
/// apply the event (when `apply`), then render the new state. Only data
/// crosses, so this runs anywhere — the fabric-transparent GUI. Returns
/// null unless update is 2-arg and view is 1-arg (then the caller stays
/// in-process). Arena-held.
fn buildAppSrc(it: *mshl.Interp, update: *const mshl.Closure, view: *const mshl.Closure) mshl.Error!?[]const u8 {
    if (update.params.len != 2 or view.params.len != 1) return null;
    var s: std.ArrayList(u8) = .empty;
    try s.appendSlice(it.arena, "let ");
    try s.appendSlice(it.arena, update.params[0]);
    try s.appendSlice(it.arena, " = $in.state\n");
    try s.appendSlice(it.arena, "let ");
    try s.appendSlice(it.arena, update.params[1]);
    try s.appendSlice(it.arena, " = $in.ev\n");
    try s.appendSlice(it.arena, "let __ns = match $in.apply {\n  true => ");
    try s.appendSlice(it.arena, update.src);
    try s.appendSlice(it.arena, "\n  _ => $in.state\n}\n");
    try s.appendSlice(it.arena, "let ");
    try s.appendSlice(it.arena, view.params[0]);
    try s.appendSlice(it.arena, " = $__ns\n");
    try s.appendSlice(it.arena, "{ state: $__ns, tree: ");
    try s.appendSlice(it.arena, view.src);
    try s.appendSlice(it.arena, " }\n");
    return s.items;
}

/// The `{ state, ev, apply }` record the remote app worker reads as `$in`.
fn wrapStep(it: *mshl.Interp, state: Value, ev: Value, apply: bool) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 3);
    keys[0] = "state";
    keys[1] = "ev";
    keys[2] = "apply";
    const vals = try it.arena.alloc(Value, 3);
    vals[0] = state;
    vals[1] = ev;
    vals[2] = .{ .bool = apply };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// One step of the remote app: ship `{ state, ev, apply }` to node
/// `remote_node`, which runs update+view and returns `{ state, tree }`.
/// Updates `state.*` and returns the view tree, or null on a fabric/app
/// failure (the caller keeps the last good tree). Only data crosses.
fn stepRemote(it: *mshl.Interp, state: *Value, ev: Value, apply: bool) mshl.Error!?Value {
    if (remote_stage == null) return null;
    const in = try wrapStep(it, state.*, ev, apply);
    const res = (try remote_stage.?.call(it, app_src, in)) orelse {
        _ = usys.log(log_h, "gui: the remote app failed");
        return null;
    };
    if (res != .record) return null;
    const rec = res.record;
    const ns = rec.get("state") orelse return null;
    const tree = rec.get("tree") orelse return null;
    state.* = ns;
    return tree;
}

/// The `{ state, ev }` record a worker update reads as `$in`.
fn wrapStateEv(it: *mshl.Interp, state: Value, ev: Value) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 2);
    keys[0] = "state";
    keys[1] = "ev";
    const vals = try it.arena.alloc(Value, 2);
    vals[0] = state;
    vals[1] = ev;
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// Run `update state ev`. Isolated in a worker when one is live: a clean
/// reply is the new state; if the app's update misbehaves — raises an
/// error, or faults its whole domain — the runtime logs it, drops the
/// offending event, keeps the state as it was, and (on a dead domain)
/// re-spawns a fresh worker, so it survives and keeps rendering. That is
/// the let-it-crash contract: an app bug takes down only the worker.
/// With no worker (isolation off, or a re-spawn that failed) it runs
/// `update` in-process, the old behaviour.
fn callUpdate(it: *mshl.Interp, update: Value, state: Value, ev: Value) mshl.Error!Value {
    if (iso_conn) |c| {
        const in = try wrapStateEv(it, state, ev);
        const good: ?Value = switch (try workcmds.callConn(it, c, in)) {
            .value => |v| v,
            .raised, .crashed => null,
        };
        if (good) |v| return v;
        // The update misbehaved (raised, or faulted its domain). Tear the
        // worker down and start a fresh one — a runaway leaves the old
        // worker's heap spent, so we never reuse it — drop the offending
        // event, and keep the last good state. The runtime lives on.
        _ = usys.log(log_h, "gui: update crashed — recovering");
        workcmds.close(c);
        iso_conn = workcmds.spawnBlock(it, iso_src);
        if (iso_conn == null) _ = usys.log(log_h, "gui: could not re-spawn the update worker; running in-process");
        return state;
    }
    return it.callValue(update, &.{ state, ev }, null, null);
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (std.mem.eql(u8, name, "apps")) {
        const ac = @import("appsclient.zig");
        var catalog: ac.Catalog = .{};
        if (!catalog.refresh()) return it.fail("apps: session catalog unavailable", .{});
        const rows = try it.arena.alloc(Value, catalog.len);
        for (catalog.records[0..catalog.len], rows) |*app, *row| {
            row.* = try mshl.toValue(it.arena, .{
                .title = try it.arena.dupe(u8, std.mem.sliceTo(&app.name, 0)),
                .description = try it.arena.dupe(u8, std.mem.sliceTo(&app.description, 0)),
                .icon = try it.arena.dupe(u8, std.mem.sliceTo(&app.icon, 0)),
                .unit = try it.arena.dupe(u8, std.mem.sliceTo(&app.unit, 0)),
                .window = try it.arena.dupe(u8, std.mem.sliceTo(&app.window, 0)),
                .running = app.flags & shared.apps.running != 0,
                .dock = app.flags & shared.apps.dock != 0,
            });
        }
        return Value{ .list = rows };
    }
    if (std.mem.eql(u8, name, "display-info")) {
        const out = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, wf.display, .output_info, 0)) {
            .ok => |r| switch (r) {
                .output => |v| v,
                else => return it.fail("display: output information unavailable", .{}),
            },
            .err => return it.fail("display: output information unavailable", .{}),
        };
        var idbuf: [24]u8 = undefined;
        const monitor: []const u8 = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, wf.display, .output_monitor, 0)) {
            .ok => |r| switch (r) {
                .monitor => |m| try it.arena.dupe(u8, shared.wordsToStr(&idbuf, .{ m.a, m.b, m.c })),
                else => "",
            },
            .err => "",
        };
        return try mshl.toValue(it.arena, .{ .mode = try std.fmt.allocPrint(it.arena, "{d}x{d}", .{ shared.unpackHi(out.wh), shared.unpackLo(out.wh) }), .width = shared.unpackHi(out.wh), .height = shared.unpackLo(out.wh), .preferred_width = shared.unpackHi(out.preferred), .preferred_height = shared.unpackLo(out.preferred), .seconds = out.seconds, .can_change = output_control != 0, .monitor = monitor });
    }
    if (std.mem.eql(u8, name, "display-modes")) {
        var rows: std.ArrayList(Value) = .empty;
        var i: u64 = 0;
        var last: u64 = 0;
        while (i < 32) : (i += 1) {
            const rep = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.display, .{ .output_mode = .{ .index = i } }, 0);
            const wh = switch (rep) {
                .ok => |r| switch (r) {
                    .mode => |v| v.wh,
                    else => break,
                },
                .err => break,
            };
            if (wh == last) continue;
            last = wh;
            const w = shared.unpackHi(wh);
            const h = shared.unpackLo(wh);
            const label = try std.fmt.allocPrint(it.arena, "{d} × {d}", .{ w, h });
            const id = try std.fmt.allocPrint(it.arena, "{d}x{d}", .{ w, h });
            const cells = try it.arena.alloc(Value, 1);
            cells[0] = .{ .str = label };
            try rows.append(it.arena, try mshl.toValue(it.arena, .{ .id = id, .cells = Value{ .list = cells } }));
        }
        return .{ .list = rows.items };
    }
    if (std.mem.startsWith(u8, name, "display-")) {
        var request: shared.GpuReq = undefined;
        if (std.mem.eql(u8, name, "display-preview")) {
            var parts = std.mem.splitScalar(u8, args[0].str, 'x');
            const w = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return .{ .bool = false };
            const h = std.fmt.parseInt(u32, parts.next() orelse "", 10) catch return .{ .bool = false };
            if (parts.next() != null) return .{ .bool = false };
            request = .{ .preview_mode = .{ .wh = shared.packPair(w, h) } };
        } else if (std.mem.eql(u8, name, "display-confirm")) {
            request = .confirm_mode;
        } else if (std.mem.eql(u8, name, "display-revert")) {
            request = .revert_mode;
        } else return null;
        if (output_control == 0) return .{ .bool = false };
        const accepted = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, output_control, request, 0)) {
            .ok => |r| r == .ok,
            .err => false,
        };
        if (accepted and request == .confirm_mode) _ = usys.log(log_h, "display: mode confirmed");
        return .{ .bool = accepted };
    }

    if (std.mem.eql(u8, name, "sessionfont")) {
        const text: []const u8 = if (args.len > 0 and args[0] == .str)
            args[0].str
        else if (input != null and input.? == .str)
            input.?.str
        else
            "";
        wf.applyUserLayer(text);
        return Value.nothing;
    }
    if (std.mem.eql(u8, name, "appearance")) {
        var theme: shared.Theme = .dark;
        var contrast: shared.Contrast = .normal;
        var colors: shared.ColorMode = .default;
        var locked: u64 = 0;
        const flags = wf.appearanceFlags();
        theme = shared.apTheme(flags);
        contrast = shared.apContrast(flags);
        colors = shared.apColors(flags);
        locked = shared.apLocked(flags);
        // { theme, contrast, colors, and a *_locked bool per axis the system
        // layer locks — so a settings UI renders that control non-editable }.
        const keys = try it.arena.alloc([]const u8, 6);
        keys[0] = "theme";
        keys[1] = "contrast";
        keys[2] = "colors";
        keys[3] = "theme_locked";
        keys[4] = "contrast_locked";
        keys[5] = "colors_locked";
        const vals = try it.arena.alloc(Value, 6);
        vals[0] = .{ .str = @tagName(theme) };
        vals[1] = .{ .str = @tagName(contrast) };
        vals[2] = .{ .str = if (colors == .cb_safe) "cb-safe" else "default" };
        vals[3] = .{ .bool = locked & 1 != 0 };
        vals[4] = .{ .bool = locked & 2 != 0 };
        vals[5] = .{ .bool = locked & 4 != 0 };
        return Value{ .record = .{ .keys = keys, .vals = vals } };
    }
    if (std.mem.eql(u8, name, "restore-window")) {
        if (wf.display == 0) return it.fail("restore-window: no display", .{});
        if (args.len == 0 or args[0] != .str) return it.fail("restore-window: a window title expected", .{});
        const w = shared.strToWords(args[0].str);
        const ok = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, wf.display, .{ .restore_titled = .{ .a = w[0], .b = w[1] } }, 0)) {
            .ok => |r| r == .ok,
            .err => false,
        };
        return if (ok)
            try it.mkResult(true, .{ .str = try it.arena.dupe(u8, args[0].str) })
        else
            try it.mkResult(false, .{ .str = "not running" });
    }
    if (!std.mem.eql(u8, name, "gui")) return null;
    const spec: mshl.Record = if (args.len > 0 and args[0] == .record)
        args[0].record
    else if (input != null and input.? == .record)
        input.?.record
    else
        return it.fail("gui: a record {{ init, update, view }} expected", .{});

    const view = spec.get("view") orelse return it.fail("gui: `view` (a fn) is required", .{});
    const update = spec.get("update") orelse return it.fail("gui: `update` (a fn) is required", .{});
    if (view != .func or update != .func) return it.fail("gui: `view` and `update` must be functions", .{});
    var state = spec.get("init") orelse Value.nothing;
    const title = if (spec.get("title")) |t| (if (t == .str) t.str else "") else "";
    const want_trusted = spec.get("trusted") != null and (spec.get("trusted").?).asBool();
    const want_isolate = spec.get("isolate") != null and (spec.get("isolate").?).asBool();
    // `tick: <ms>` (or `tick: true` → 1s) asks the loop to re-render on a
    // timer so a `view` that reads the clock updates on its own.
    wf.tick_ms = if (spec.get("tick")) |t| switch (t) {
        .int => if (t.int > 0) @intCast(t.int) else 0,
        .bool => if (t.bool) 1000 else 0,
        else => 0,
    } else 0;
    // `bar: true` is the resident top menu bar — a distinct render/loop
    // (pinned, chrome-less, with dropdown menus), not a window.
    if (spec.get("bar") != null and (spec.get("bar").?).asBool()) {
        return try guibar.runBar(it, view, update, state);
    }
    // `dock: true` is the resident bottom dock — a bar of app buttons that
    // launch their units on a click, pinned full-width, not a window.
    if (spec.get("dock") != null and (spec.get("dock").?).asBool()) {
        return try guidock.runDock(it, view, update, state, if (spec.get("dismissible")) |v| v.asBool() else false);
    }

    // `node: N` runs the whole app on node N over the fabric — the runtime
    // becomes a pure viewer, shipping each event and rendering the view
    // tree that comes back. Needs a fabric cap and a 2-arg update / 1-arg
    // view (so we can reconstruct the worker); otherwise it runs locally.
    remote_node = 0;
    remote_stage = null;
    if (fab_chan != 0) {
        if (spec.get("node")) |n| if (n == .int and n.int > 0) {
            if (try buildAppSrc(it, update.func, view.func)) |src| {
                app_src = src;
                // Spawn the stage once; every event reuses it. If the node
                // is unreachable, fall back to running the app in-process
                // (its closures are here) — a graceful degradation.
                remote_stage = fabcmds.Stage.open(fab_chan, @intCast(n.int));
                if (remote_stage != null) {
                    remote_node = @intCast(n.int);
                    _ = usys.log(log_h, "gui: running the app on the fabric");
                } else {
                    _ = usys.log(log_h, "gui: the app's node is unreachable; running in-process");
                }
            }
        };
    }
    defer if (remote_stage) |*s| s.close();

    // Crash-isolate `update` in a worker domain when asked and able (and
    // not already remote): an app fault then kills only the worker, not
    // the display runtime. The worker lives for the whole session;
    // `callUpdate` re-spawns it if it dies. Best-effort — no spawner, or a
    // 2-arg `update` we cannot reconstruct, and we run it in-process.
    iso_conn = null;
    if (remote_node == 0 and want_isolate and workcmds.canSpawn()) {
        if (try buildUpdateSrc(it, update.func)) |src| {
            iso_src = src;
            iso_conn = workcmds.spawnBlock(it, iso_src);
            if (iso_conn == null) _ = usys.log(log_h, "gui: could not spawn the update worker; running in-process");
        }
    }
    defer if (iso_conn) |c| workcmds.close(c);

    // A `trusted: true` GUI is a login greeter: claim the trusted path so
    // the compositor makes this the login surface — the secure strip is
    // shown while it holds focus and its keystrokes reach nobody else. It
    // needs the boot-provisioned token (a `secret` give); without it the
    // compositor refuses, and so do we.
    if (want_trusted) {
        if (!wf.attachTrusted()) return it.fail("gui: the trusted path was refused (no token, or the wrong one)", .{});
    } else {
        // An ordinary window: register once for a unique badge so the
        // compositor tells this process's surfaces and input apart from
        // other windows'. Cached across `gui` calls (a reopening shell
        // keeps its badge). Falls back to badge 0 if the compositor is old.
        wf.useOrdinaryChannel();
    }

    resetFields();
    resetLists();
    scrolls = @splat(.{});
    scroll_dirty = false;
    reveal_focus = true;
    hovered = null;
    pressed = null;
    // A fresh window: no drag in flight (module state persists across
    // `gui` calls in one process), and it opens focused (the compositor
    // sets a new surface as focused; a later `kind` 4 corrects us if not).
    wf.dragging = false;
    wf.ptr_down = false;
    wf.pending_dot = null;
    crumbs = @splat(.{});
    crumb_pressed = null;
    wf.win_focused = true;
    wf.win_trusted = want_trusted;
    wf.maximized = false;
    // Width: `width: N` narrows the window (a desktop lays out several
    // smaller windows); default is the roomy single-window width.
    wf.win_w = @min(win_w_default, wf.scanout_w);
    if (spec.get("width")) |wv| {
        if (wv == .int and wv.int >= 200) wf.win_w = @min(@as(usize, @intCast(wv.int)), wf.scanout_w);
    }
    wf.win_x = (wf.scanout_w - wf.win_w) / 2;
    wf.fontReady(); // attach the system font once (bitmap fallback if absent)
    wf.refreshAppearance(); // resolve the palette from the system/user settings
    var epoch: @import("guieval.zig").Epoch = .{};
    try epoch.begin(it, .{ .record = spec });
    defer epoch.deinit();
    sizeToContent(it, view, state, title); // fit the window to its content
    // `at: { x, y }` places the window instead of centring it (a desktop
    // that lays several windows out uses this).
    if (spec.get("at")) |a| {
        if (a == .record) {
            if (a.record.get("x")) |xv| {
                if (xv == .int and xv.int >= 0) wf.win_x = @min(@as(usize, @intCast(xv.int)), wf.scanout_w - wf.win_w);
            }
            if (a.record.get("y")) |yv| {
                if (yv == .int and yv.int >= 0) wf.win_y = @min(@as(usize, @intCast(yv.int)), wf.scanout_h - wf.win_h);
            }
        }
    }

    wf.pointer_tracking = true;
    if (!wf.openSurface(true)) return it.fail("gui: cannot open a surface", .{});
    defer wf.closeSurface();
    // Name the surface so the dock can restore this window by its title
    // after the amber traffic-light minimizes it.
    if (title.len > 0) wf.setSurfaceTitle(title);
    const menu_profile: shared.menus.Profile = if (std.mem.eql(u8, strField(spec, "menus"), "files")) .files else .generic;
    loadBindings(spec);

    var focus: usize = 0;
    var focus_id: [64]u8 = undefined;
    var focus_len: usize = 0;
    var action_id: [64]u8 = undefined;
    var action_len: usize = 0;
    var minimized = false; // the amber dot hid us; a restore event brings us back
    var announced = false;
    var relog_geom = false; // a resize moved the traffic lights; re-log them
    // The current view tree: the initial view of the initial state, then
    // recomputed after each fired event — locally (update then view) or,
    // for a `node: N` app, on that node in one round trip.
    var tree: Value = if (remote_node != 0)
        (try stepRemote(it, &state, Value.nothing, false)) orelse
            return it.fail("gui: the remote app did not answer", .{})
    else
        try it.callValue(view, &.{state}, null, null);
    // A checkpoint copies state and tree out of scratch and resets it — the
    // right thing after an evaluation, and pure waste after a hover or a
    // drag that evaluated nothing (peak 2x of the tree in a 512 KiB pool,
    // on every pointer move). Only turns that ran script code pay it.
    var evaluated = true;
    while (true) {
        if (evaluated) {
            // Snapshot live state before discarding callback scratch allocations.
            try epoch.checkpoint(&state, &tree);
            evaluated = false;
        }
        var nfocus = renderTree(tree, title, focus);
        if (!want_trusted) {
            var enabled = shared.menus.offered(menu_profile);
            if (menu_profile == .files) {
                const fb = &files_bindings;
                if (fb.up.len == 0 or file_crumb == null or file_crumb.?.path_len == 0) enabled &= ~shared.menus.bit(shared.menus.up);
                if (fb.lock.len == 0 or file_crumb == null or !file_crumb.?.can_lock) enabled &= ~shared.menus.bit(shared.menus.readonly_view);
                if (fb.leave.len == 0 or file_crumb == null or !file_crumb.?.can_leave) enabled &= ~shared.menus.bit(shared.menus.leave_view);
                if (fb.refresh.len == 0) enabled &= ~shared.menus.bit(shared.menus.refresh);
                if (fb.home.len == 0) enabled &= ~shared.menus.bit(shared.menus.home);
                const list = if (fb.open.len > 0) listStateById(fb.open.get()) else null;
                if (list == null or list.?.nrows == 0) enabled &= ~shared.menus.bit(shared.keyboard.open_document);
            }
            wf.setMenuProfile(menu_profile, enabled);
        }
        if (focus_len > 0) {
            for (focusables[0..nfocus], 0..) |f, i| if (std.mem.eql(u8, f.id, focus_id[0..focus_len])) {
                if (focus != i) {
                    focus = i;
                    nfocus = renderTree(tree, title, focus);
                }
                break;
            };
        }
        if (reveal_focus) {
            for (0..scrolls.len) |_| {
                if (!revealWidget(focus)) break;
                nfocus = renderTree(tree, title, focus);
            }
            reveal_focus = false;
        }
        if (layout_overflow) return it.fail("gui: too many widgets or invalid scroll id", .{});
        if (nfocus > 0 and focus >= nfocus) {
            focus = nfocus - 1;
            nfocus = renderTree(tree, title, focus);
        }
        if (!wf.commitSurface()) return it.fail("gui: commit failed", .{});
        if (!announced or action_len > 0) {
            for (focusables[0..nfocus]) |f| if (f.crumb) |c| {
                const model = c.model();
                var flow: ui.flow.Flow = .{ .width = f.bw, .gap = 4 };
                for (0..model.count) |index| {
                    const last = index + 1 == model.count;
                    const place = flow.put(.{ .w = crumbWidth(model.at(index, c.root).?, last, f.bw), .h = lineOf(R_UI) + 16 });
                    if (last) continue;
                    const sy = f.sy + @as(isize, @intCast(place.y + (lineOf(R_UI) + 16) / 2));
                    if (sy < f.cy0 or sy >= f.cy1) continue;
                    var line: [128]u8 = undefined;
                    _ = usys.log(log_h, std.fmt.bufPrint(&line, "gui: breadcrumb {s} index={d} at {d},{d}", .{ f.id, index, wf.win_x + f.bx + place.x + (place.w -| 24) / 2, wf.win_y + @as(usize, @intCast(sy)) }) catch continue);
                }
            };
        }
        if (action_len > 0) {
            var line: [96]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&line, "gui: action {s}", .{action_id[0..action_len]}) catch "gui: action");
            action_len = 0;
        }
        if (scroll_dirty) {
            _ = usys.log(log_h, "gui: scrolled");
            scroll_dirty = false;
        }
        // The traffic-light dot centres in scanout coordinates, so a host
        // can click close/minimize/maximize precisely. Logged on the first
        // render, and again after a resize (maximize) moves them.
        if (!announced or relog_geom) {
            relog_geom = false;
            var dl: [96]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&dl, "gui: dots close={d},{d} min={d},{d} max={d},{d}", .{ wf.win_x + wf.dots_cx[0], wf.win_y + wf.dots_cy, wf.win_x + wf.dots_cx[1], wf.win_y + wf.dots_cy, wf.win_x + wf.dots_cx[2], wf.win_y + wf.dots_cy }) catch "gui: dots");
        }
        if (!announced) {
            _ = usys.log(log_h, "gui: ready");
            // Log each focusable widget's clickable centre in scanout
            // coordinates, so a host driving the pointer can click it.
            for (0..nfocus) |i| {
                const f = focusables[i];
                var l: [96]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: widget {s} at {d},{d}", .{ f.id, wf.win_x + f.bx + f.bw / 2, wf.win_y + f.by + f.bh / 2 }) catch continue);
            }
            // Each list's row geometry in scanout coordinates, so a host can
            // click a specific row (rows_top + row * row_h) and the scrollbar.
            for (list_hits[0..nlisthit]) |lh| {
                var l: [128]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: list {s} cx={d} rows_top={d} row_h={d} sb={d} count={d}", .{ lh.id, wf.win_x + lh.x + lh.rows_w / 2, wf.win_y + lh.rows_top, lh.row_h, if (lh.sb_x > 0) wf.win_x + lh.sb_x else 0, lh.st.nrows }) catch continue);
            }
            announced = true;
        }

        // Wait for a key. Tab moves focus; a printable key or backspace
        // edits the focused field; Enter fires a focused button (with the
        // fields' text) or advances past a focused field. Each break
        // re-renders — the buffer, the focus, or the new state.
        var fired: ?[]const u8 = null;
        // A list fire carries the selected row id and whether it was
        // activated (Enter / reclick) vs merely selected — see mkListEvent.
        var fired_list = false;
        var fired_row: []const u8 = "";
        var fired_activated = false;
        var ticked = false;
        var closed = false;
        input: while (true) {
            const ev = wf.nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 7) {
                if (!wf.outputChanged(ev, title, minimized)) _ = usys.log(log_h, "gui: output resize failed; keeping the window");
                hovered = null;
                pressed = null;
                reveal_focus = true;
                announced = false;
                break :input;
            }
            // A focus change: the compositor tells us we gained or lost the
            // keyboard (arg 1/0). Re-render so the chrome dims or brightens.
            if (ev.kind == 4) {
                const now = ev.ch != 0;
                if (now == wf.win_focused) continue :input;
                wf.win_focused = now;
                if (!now) {
                    field_drag = null;
                    pressed = null;
                    hovered = null;
                }
                _ = usys.log(log_h, if (now) "gui: focused" else "gui: unfocused");
                if (minimized) continue :input; // nothing on screen to redraw
                break :input;
            }
            // A restore: the dock brought this minimized window back. Clear
            // the minimized state and re-render so its content repaints.
            if (ev.kind == 3) {
                minimized = false;
                _ = usys.log(log_h, "gui: restored");
                break :input;
            }
            // A timer tick: re-render so a `view` reading the time updates
            // — but never mid-drag (a ticking clock must not drop a drag),
            // and never while minimized (nothing is on screen to update).
            if (ev.kind == 2) {
                if (wf.dragging or minimized or pressed != null) continue :input;
                ticked = true;
                break :input;
            }
            // Pointer. The frame owns the titlebar — the traffic-light
            // dots (close / minimize / maximize) and the drag-to-move /
            // edge-snap gesture — and tells us, per event, what it did; a
            // press in the content area comes back as `.content` for the
            // widgets. The chrome logging stays here, so it reads the same
            // as before the frame was split out.
            if (ev.kind == 1) {
                const wheel = shared.ptrWheel(ev.btn);
                if (wheel != 0) {
                    if (hitWidget(nfocus, ev.x, ev.y)) |wi| if (focusables[wi].is_list) {
                        if (listStateById(focusables[wi].id)) |list| {
                            const old = list.scroll;
                            list.scroll = @intCast(std.math.clamp(@as(isize, @intCast(old)) - @as(isize, wheel) * 3, 0, @as(isize, @intCast(list.nrows -| list.vis))));
                            if (list.scroll != old) break :input;
                        }
                    };
                    if (ev.y >= wf.title_h + pad and ev.y < wf.win_h -| pad and ev.x >= pad and ev.x < wf.win_w -| pad and scrollStep(scrollAt(ev.x, ev.y), -@as(isize, wheel) * @as(isize, @intCast(lineOf(R_UI) * 3)))) {
                        hovered = null;
                        pressed = null;
                        field_drag = null;
                        _ = usys.log(log_h, "gui: wheel scrolled");
                        break :input;
                    }
                    continue :input;
                }
                if (field_drag) |wi| {
                    if (ev.btn & 1 == 0) field_drag = null else {
                        if (wi < nfocus) fieldClick(focusables[wi], ev.x, true);
                        break :input;
                    }
                }
                const old_hover = hovered;
                hovered = hitWidget(nfocus, ev.x, ev.y);
                const pointer = wf.onPointer(ev, title);
                if (pressed) |wi| {
                    if (ev.btn & 1 == 0) {
                        pressed = null;
                        if (hovered == wi and wi < nfocus) {
                            const f = focusables[wi];
                            if (f.crumb) |c| {
                                const hit = crumbHit(f, ev.x, ev.y);
                                if (hit != null and hit == crumb_pressed) {
                                    fired = f.id;
                                    fired_list = true;
                                    fired_row = c.model().at(hit.?, c.root).?.path;
                                    fired_activated = true;
                                }
                            } else fired = f.id;
                        }
                        crumb_pressed = null;
                        break :input;
                    }
                }
                switch (pointer) {
                    .none => {},
                    .content => |cev| {
                        const owner = scrollAt(cev.x, cev.y);
                        const st = &scrolls[owner];
                        if (st.state.limit() > 0 and cev.x >= st.x + st.w -| 12 and cev.x < st.x + st.w and cev.y >= st.cy0 and cev.y < st.cy1) {
                            const delta: isize = @intCast(@max(1, st.h -| lineOf(R_UI)));
                            _ = st.state.step(if (@as(isize, @intCast(cev.y)) < st.top + @as(isize, @intCast(st.h / 2))) -delta else delta);
                            break :input;
                        }
                        if (hitWidget(nfocus, cev.x, cev.y)) |wi| {
                            focus = wi;
                            if (focusables[wi].crumb) |c| {
                                if (crumbHit(focusables[wi], cev.x, cev.y)) |index| {
                                    c.selected = index;
                                    crumb_pressed = index;
                                    pressed = wi;
                                }
                                break :input;
                            }
                            if (focusables[wi].is_list) {
                                const lc = listClick(focusables[wi].id, cev.x, cev.y);
                                if (lc.fire) {
                                    fired = focusables[wi].id;
                                    fired_list = true;
                                    fired_row = listRowId(tree, focusables[wi].id, lc.row);
                                    fired_activated = lc.activated;
                                }
                                break :input; // re-render (selection or scroll moved)
                            }
                            if (!focusables[wi].is_field) {
                                pressed = wi;
                                break :input;
                            }
                            // Place the caret using the same font metrics as rendering.
                            fieldClick(focusables[wi], cev.x, false);
                            field_drag = wi;
                            break :input;
                        }
                    },
                    .moved => {
                        var lb: [96]u8 = undefined;
                        _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: {s} moved to {d},{d}", .{ title, wf.win_x, wf.win_y }) catch "gui: moved");
                    },
                    .minimized => {
                        minimized = true; // stay parked until a restore
                        _ = usys.log(log_h, "gui: minimized");
                    },
                    .close => {
                        closed = true; // red: close the window
                        break :input;
                    },
                    .resized => |zone| {
                        reveal_focus = true;
                        relog_geom = true; // the dots moved with the window
                        _ = usys.log(log_h, switch (zone) {
                            .left => "gui: snapped left",
                            .right => "gui: snapped right",
                            .max => "gui: maximized",
                            .none => "gui: unmaximized",
                        });
                        break :input; // re-render into the new surface
                    },
                    .resize_failed => {
                        _ = usys.log(log_h, "gui: resize failed; keeping the window");
                        break :input; // repaint into the surface we kept
                    },
                }
                if (old_hover != hovered) break :input;
                continue :input;
            }
            pressed = null;
            const ch = ev.ch;
            if (!want_trusted and (ch == shared.keyboard.close_window or ch == shared.keyboard.close_all)) {
                closed = true;
                break :input;
            }
            if (!want_trusted and ch == shared.menus.minimize) {
                wf.setSurfaceVisible(false);
                minimized = true;
                _ = usys.log(log_h, "gui: minimized");
                break :input;
            }
            if (menu_profile == .files) {
                switch (ch) {
                    shared.menus.up => {
                        if (files_bindings.up.len > 0) fired = files_bindings.up.get();
                        break :input;
                    },
                    shared.menus.readonly_view => {
                        if (files_bindings.lock.len > 0 and file_crumb != null and file_crumb.?.can_lock) fired = files_bindings.lock.get();
                        break :input;
                    },
                    shared.menus.leave_view => {
                        if (files_bindings.leave.len > 0 and file_crumb != null and file_crumb.?.can_leave) fired = files_bindings.leave.get();
                        break :input;
                    },
                    shared.menus.refresh => {
                        if (files_bindings.refresh.len > 0) fired = files_bindings.refresh.get();
                        break :input;
                    },
                    shared.menus.home => {
                        if (files_bindings.home.len > 0) {
                            fired = files_bindings.home.get();
                            fired_list = true;
                            fired_row = "";
                        }
                        break :input;
                    },
                    shared.keyboard.open_document => {
                        if (files_bindings.open.len > 0) if (listStateById(files_bindings.open.get())) |st| if (st.nrows > 0) {
                            fired = files_bindings.open.get();
                            fired_list = true;
                            fired_row = listRowId(tree, files_bindings.open.get(), st.sel);
                            fired_activated = true;
                            break :input;
                        };
                    },
                    else => {},
                }
            }
            const cur: ?Focus = if (nfocus > 0) focusables[focus] else null;
            if (cur) |f| if (f.crumb) |c| {
                const model = c.model();
                switch (ch) {
                    shared.keyboard.left => {
                        c.selected -|= 1;
                        break :input;
                    },
                    shared.keyboard.right => {
                        c.selected = @min(c.selected + 1, model.count -| 2);
                        break :input;
                    },
                    shared.keyboard.home => {
                        c.selected = 0;
                        break :input;
                    },
                    shared.keyboard.end => {
                        c.selected = model.count -| 2;
                        break :input;
                    },
                    '\n' => {
                        fired = f.id;
                        fired_list = true;
                        fired_row = model.at(c.selected, c.root).?.path;
                        fired_activated = true;
                        break :input;
                    },
                    else => {},
                }
            };
            if (cur) |c| if (c.is_field) {
                const f = fieldFor(c.id, "");
                if (widgets.fieldKeyOpts(&f.edit, ch, .{ .secret = f.secret })) {
                    reveal_focus = true;
                    break :input;
                }
            };
            if (ch == 0x1e or ch == 0x1f or ch == shared.keyboard.home or ch == shared.keyboard.end) {
                const owner = if (cur) |c| c.owner else 0;
                const delta: isize = @intCast(if (ch == shared.keyboard.home or ch == shared.keyboard.end) scrolls[owner].state.extent else @max(1, scrolls[owner].h -| lineOf(R_UI)));
                if (scrollStep(owner, if (ch == 0x1e or ch == shared.keyboard.home) -delta else delta)) break :input;
            }
            switch (ch) {
                '\t', shared.keyboard.back_tab => {
                    reveal_focus = true;
                    if (cur) |c| if (c.is_field) {
                        fieldFor(c.id, "").edit.typing = false;
                    };
                    if (nfocus > 0) focus = (focus + (if (ch == '\t') @as(usize, 1) else nfocus - 1)) % nfocus;
                    break :input;
                },
                '\n' => {
                    if (cur) |c| {
                        if (c.is_field) {
                            reveal_focus = true;
                            focus = (focus + 1) % nfocus; // advance past a field
                        } else if (c.is_list) {
                            if (listStateById(c.id)) |st| {
                                fired = c.id;
                                fired_list = true;
                                fired_row = listRowId(tree, c.id, st.sel);
                                fired_activated = true; // Enter opens the selection
                            }
                        } else {
                            fired = c.id; // a button submits
                        }
                        break :input;
                    }
                },
                key_up, key_down => {
                    // Move a focused list's selection; a preview follows it
                    // (fired but not activated). Keyboard motion breaks the
                    // reclick pairing so the next click just selects.
                    if (cur) |c| if (c.is_list) {
                        if (listStateById(c.id)) |st| {
                            if (ch == key_up) st.sel = st.sel -| 1 else if (st.sel + 1 < st.nrows) st.sel += 1;
                            keepSelVisible(st);
                            st.click = .{};
                            fired = c.id;
                            fired_list = true;
                            fired_row = listRowId(tree, c.id, st.sel);
                            fired_activated = false;
                            break :input;
                        }
                    };
                    if (scrollStep(if (cur) |c| c.owner else 0, (if (ch == key_up) -@as(isize, @intCast(lineOf(R_UI))) else @as(isize, @intCast(lineOf(R_UI)))))) break :input;
                },
                else => {},
            }
        }
        if (focus < nfocus) {
            focus_len = @min(focusables[focus].id.len, focus_id.len);
            @memcpy(focus_id[0..focus_len], focusables[focus].id[0..focus_len]);
        } else focus_len = 0;
        // The close box was clicked: end the app (its `gui` call returns
        // the last state, like a `done`).
        if (closed) break;
        if (ticked and remote_node == 0) {
            // Recompute the view from the unchanged state — no `update` on
            // a tick — so a clock or other time-driven view refreshes.
            tree = try it.callValue(view, &.{state}, null, null);
            evaluated = true;
        }
        if (fired) |id| {
            evaluated = true;
            reveal_focus = true;
            action_len = @min(id.len, action_id.len);
            @memcpy(action_id[0..action_len], id[0..action_len]);
            const ev = if (fired_list) try mkListEvent(it, id, fired_row, fired_activated) else try mkEvent(it, id);
            if (remote_node != 0) {
                // The app runs on the fabric: ship the event, render the
                // tree that comes back. A dropped round trip keeps the last
                // good tree and state (let-it-crash across the wire).
                if (try stepRemote(it, &state, ev, true)) |t| {
                    tree = t;
                    if (isDone(state)) break;
                }
            } else {
                state = try callUpdate(it, update, state, ev);
                tree = try it.callValue(view, &.{state}, null, null);
                if (isDone(state)) break;
            }
        }
    }
    _ = usys.log(log_h, "gui: closed");
    return try epoch.finish(state);
}
