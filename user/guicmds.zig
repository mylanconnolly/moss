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
const usys = @import("usys.zig");
const workcmds = @import("workcmds.zig");
const fabcmds = @import("fabcmds.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;
const wf = @import("windowframe.zig");

// The window frame — the chrome, the compositor surface, the drawing
// primitives and the system font — lives in windowframe.zig, shared with
// the terminal so both wear the same window. This module is the mshl GUI
// *content*: the widget tree, the resident top bar and dock, and the run
// loops that route input through the frame. These aliases let the widget
// code read as it did before the split (the frame owns the module state
// behind them, so a redraw of the popup surface, say, is `wf.px = ...`).
const pal = &wf.pal;
const fillAll = wf.fillAll;
const fillRect = wf.fillRect;
const fillRoundRect = wf.fillRoundRect;
const fillDot = wf.fillDot;
const panel = wf.panel;
const shade = wf.shade;
const drawStr = wf.drawStr;
const drawStrTrunc = wf.drawStrTrunc;
const strW = wf.strW;
const lineOf = wf.lineOf;
const clipReset = wf.clipReset;
const R_UI = wf.R_UI;
const R_TITLE = wf.R_TITLE;
const scanout_w = wf.scanout_w;
const scanout_h = wf.scanout_h;
const win_w_default = wf.win_w_default;
const win_h_min = wf.win_h_min;
const win_h_max = wf.win_h_max;
const item_vpad = wf.item_vpad;
const dock_vpad = wf.dock_vpad;
const top_strut = wf.top_strut;

var log_h: u64 = 0; // for the run loops' `gui:`/`topbar:`/`dock:` logging

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

const pad = 24; // window inset for content

// The laid-out content height, from the measuring pass — the frame's
// window is sized to it before the surface is created (`sizeToContent`).
var content_h: usize = 0;

// A focusable widget: its id, whether it is a text field (which eats
// typing) or a button (which fires on Enter), and its clickable box on
// the surface (so a pointer press can hit-test which widget it landed on).
const Focus = struct { id: []const u8, is_field: bool, is_list: bool = false, bx: usize = 0, by: usize = 0, bw: usize = 0, bh: usize = 0 };
var focusables: [16]Focus = undefined;

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
    last_click: i64 = -1, // last row a click landed on (reclick = activate)
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
    }
    return l;
}

/// The focusable whose box contains (x, y) — surface-local, the pointer's
/// coordinates — or null. Topmost-last wins (widgets do not overlap).
fn hitWidget(n: usize, x: usize, y: usize) ?usize {
    var i: usize = 0;
    while (i < n and i < focusables.len) : (i += 1) {
        const f = focusables[i];
        if (x >= f.bx and x < f.bx + f.bw and y >= f.by and y < f.by + f.bh) return i;
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
    buf: [64]u8 = undefined,
    len: usize = 0,
};
var field_bufs: [max_fields]FieldBuf = @splat(.{});

fn resetFields() void {
    field_bufs = @splat(.{});
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
            f.len = @min(seed.len, f.buf.len);
            @memcpy(f.buf[0..f.len], seed[0..f.len]);
            return f;
        }
    }
    return &field_bufs[0]; // more than max_fields: reuse the first slot
}

fn fieldAppend(id: []const u8, ch: u8) void {
    const f = fieldFor(id, "");
    if (f.len < f.buf.len) {
        f.buf[f.len] = ch;
        f.len += 1;
    }
}

fn fieldBackspace(id: []const u8) void {
    const f = fieldFor(id, "");
    if (f.len > 0) f.len -= 1;
}

// Arrow keys arrive as private control bytes (inputsvc maps them); a
// focused scrollable list uses them to move its selection.
const key_up: u8 = 17;
const key_down: u8 = 18;
const key_left: u8 = 19;
const key_right: u8 = 20;

/// Render one view tree. Fills the window, draws the title and each child
/// of the (single, column) layout, highlighting the focused button, and
/// returns the focusable widgets' ids in order (into `ids_buf`).
fn strField(rec: mshl.Record, key: []const u8) []const u8 {
    return if (rec.get(key)) |v| (if (v == .str) v.str else "") else "";
}

/// Render one view tree into `focusables`, highlight the focused widget,
/// and return the number of focusable widgets.
const Size = struct { w: usize, h: usize };

const gap = 16; // vertical/horizontal space between siblings
const bpx = 20; // button horizontal padding
const bpy = 11; // button vertical padding
const fpx = 14; // field horizontal padding
const fpy = 11; // field vertical padding
const r_btn = 10; // button corner radius
const r_field = 8; // field corner radius

// Focus recording during a layout pass (draw order over the tree).
var nfoc: usize = 0;
var sel_focus: usize = 0;

/// Draw the widget tree and return the number of focusable widgets. The
/// window is a titlebar over a content area laid out by `drawNode`
/// (columns stack, rows flow), everything coloured from `pal`.
fn renderTree(tree: Value, title: []const u8, focus: usize) usize {
    clipReset();
    fillAll(pal.bg);
    sel_focus = focus;
    nfoc = 0;
    nlisthit = 0;
    // The frame paints the titlebar (bar, traffic-light dots, title) and
    // sets `wf.title_h` — the content area starts below it.
    wf.drawChrome(title);
    // Content area below the titlebar. Record the full height it wants so
    // the window can be sized to fit before its surface is created.
    const sz = drawNode(tree, pad, wf.title_h + pad, wf.win_w - 2 * pad);
    content_h = wf.title_h + pad + sz.h + pad;
    return nfoc;
}

/// Lay the tree out without drawing, to find the window height its content
/// needs (clamped to the scanout), and centre the window at it.
fn sizeToContent(it: *mshl.Interp, view: Value, state: Value, title: []const u8) void {
    const tree = it.callValue(view, &.{state}, null, null) catch return;
    wf.measuring = true;
    _ = renderTree(tree, title, 0);
    wf.measuring = false;
    wf.win_h = @max(win_h_min, @min(content_h, win_h_max));
    // Centre in the area below the top-bar strut, so a window never opens
    // under the menu bar.
    wf.win_y = @max(top_strut + 8, top_strut + (scanout_h - top_strut - wf.win_h) / 2);
}

/// Lay out and draw a node at (x, y) within `avail_w`, returning its size.
/// `column` stacks children, `row` flows them left-to-right; leaves are
/// label / button / field.
fn drawNode(node: Value, x: usize, y: usize, avail_w: usize) Size {
    if (node != .record) return .{ .w = 0, .h = 0 };
    const rec = node.record;
    const kind = strField(rec, "kind");
    const children: []const Value = kids: {
        const c = rec.get("children") orelse break :kids &.{};
        break :kids if (c == .list) c.list else &.{};
    };
    if (std.mem.eql(u8, kind, "row")) {
        var xx = x;
        var maxh: usize = 0;
        for (children) |child| {
            const sz = drawNode(child, xx, y, avail_w);
            xx += sz.w + gap;
            if (sz.h > maxh) maxh = sz.h;
        }
        return .{ .w = if (xx > x + gap) xx - x - gap else 0, .h = maxh };
    }
    if (std.mem.eql(u8, kind, "column") or children.len != 0) {
        var yy = y;
        for (children) |child| {
            const sz = drawNode(child, x, yy, avail_w);
            yy += sz.h + gap;
        }
        return .{ .w = avail_w, .h = if (yy > y + gap) yy - y - gap else 0 };
    }
    if (std.mem.eql(u8, kind, "label")) return drawLabel(rec, x, y);
    if (std.mem.eql(u8, kind, "button")) return drawButton(rec, x, y);
    if (std.mem.eql(u8, kind, "field")) return drawField(rec, x, y, avail_w);
    if (std.mem.eql(u8, kind, "list")) return drawList(rec, x, y, avail_w);
    if (std.mem.eql(u8, kind, "split")) return drawSplit(rec, x, y, avail_w);
    return .{ .w = 0, .h = 0 };
}

fn drawLabel(rec: mshl.Record, x: usize, y: usize) Size {
    const text = strField(rec, "text");
    const muted = rec.get("muted") != null and (rec.get("muted").?).asBool();
    const strong = std.mem.eql(u8, strField(rec, "role"), "title");
    const role: u64 = if (strong) R_TITLE else R_UI;
    const ink = if (strong) pal.title else if (muted) pal.text_muted else pal.text;
    drawStr(x, y, role, text, ink, pal.bg);
    return .{ .w = strW(role, text), .h = lineOf(role) };
}

/// A raised button: a filled box with a lighter top edge and a darker
/// bottom edge (a little depth, not flat), a border, and — when focused —
/// a bright ring plus a lift. `variant` gives it semantic colour: primary
/// (the accent), danger (destructive), or the neutral surface default.
fn drawButton(rec: mshl.Record, x: usize, y: usize) Size {
    const label = strField(rec, "label");
    const variant = strField(rec, "variant");
    const focused = nfoc == sel_focus;
    const w = strW(R_UI, label) + 2 * bpx;
    const h = lineOf(R_UI) + 2 * bpy;

    var fill: u32 = pal.surface_hi;
    var ink: u32 = pal.text;
    if (std.mem.eql(u8, variant, "primary")) {
        fill = pal.primary;
        ink = pal.primary_ink;
    } else if (std.mem.eql(u8, variant, "danger")) {
        fill = pal.danger;
        ink = pal.danger_ink;
    }
    // A rounded panel. Focus is a double cue (never colour alone): the
    // border becomes a bright, thicker ring AND the fill lifts a shade.
    const ring = if (focused) pal.focus else pal.border;
    const ring_w = if (focused) pal.focus_w else pal.border_w;
    if (focused) fill = shade(fill, 9, 8);
    panel(x, y, w, h, r_btn, fill, ring, ring_w);
    // A soft top highlight inside the rounded fill — a hint of depth, not
    // a hard bar (kept clear of the corners so it never pokes past them).
    fillRect(x + r_btn, y + ring_w, w - 2 * r_btn, 1, shade(fill, 6, 5));
    drawStr(x + bpx, y + bpy, R_UI, label, ink, fill);
    if (nfoc < focusables.len) {
        focusables[nfoc] = .{ .id = strField(rec, "id"), .is_field = false, .bx = x, .by = y, .bw = w, .bh = h };
        nfoc += 1;
    }
    return .{ .w = w, .h = h };
}

/// A text field: a muted label over an inset value box (a darker fill with
/// a bright caret when focused). A `secret` field shows dots.
fn drawField(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const label = strField(rec, "label");
    const id = strField(rec, "id");
    const fb = fieldFor(id, strField(rec, "value"));
    const focused = nfoc == sel_focus;
    var yy = y;
    if (label.len > 0) {
        drawStr(x, yy, R_UI, label, pal.text_muted, pal.bg);
        yy += lineOf(R_UI) + 6;
    }
    const bh = lineOf(R_UI) + 2 * fpy;
    const ring = if (focused) pal.focus else pal.border;
    const ring_w = if (focused) pal.focus_w else pal.border_w;
    panel(x, yy, avail_w, bh, r_field, pal.field_bg, ring, ring_w);
    const tx = x + fpx;
    const ty = yy + fpy;
    const secret = rec.get("secret") != null and (rec.get("secret").?).asBool();
    var dots: [64]u8 = undefined;
    const shown: []const u8 = if (secret) blk: {
        const mlen = @min(fb.len, dots.len);
        for (0..mlen) |i| dots[i] = '*';
        break :blk dots[0..mlen];
    } else fb.buf[0..fb.len];
    drawStr(tx, ty, R_UI, shown, pal.text, pal.field_bg);
    // The focus ring is already drawn by `panel`; add the caret.
    if (focused) fillRect(tx + strW(R_UI, shown) + 1, ty, 2, lineOf(R_UI), pal.focus);
    if (nfoc < focusables.len) {
        focusables[nfoc] = .{ .id = id, .is_field = true, .bx = x, .by = yy, .bw = avail_w, .bh = bh };
        nfoc += 1;
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
/// header + column layout, and `rows` [{id, cells:[str]}]. The runtime owns
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

    panel(x, y, w, box_h, r_field, pal.field_bg, pal.border, pal.border_w);

    // Header: muted column titles + a rule beneath them.
    if (cols.len > 0) {
        var hx = x + list_cell_pad;
        for (cols) |cv| {
            if (cv != .record) continue;
            const cw: usize = @intCast(@max(intField(cv.record, "w", 80), 8));
            drawStrTrunc(hx, y + list_row_vpad, R_UI, strField(cv.record, "title"), cw -| 8, pal.text_muted, pal.field_bg);
            hx += cw;
        }
        fillRect(x + pal.border_w, y + header_h, w - 2 * pal.border_w, pal.border_w, pal.border);
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
    wf.clip_y0 = @max(wf.clip_y0, rows_top);
    wf.clip_x1 = @min(wf.clip_x1, x + pal.border_w + rows_w);
    wf.clip_y1 = @min(wf.clip_y1, y + box_h - pal.border_w);

    var i = st.scroll;
    var ry = rows_top;
    while (i < nrows and i < st.scroll + vis) : (i += 1) {
        const selected = i == st.sel;
        if (selected) fillRect(x + pal.border_w, ry, rows_w, row_h, pal.primary);
        const ink = if (selected) pal.primary_ink else pal.text;
        const cell_bg = if (selected) pal.primary else pal.field_bg;
        const ty = ry + list_row_vpad;
        const cellsv = rowField(rowsv, i, "cells");
        if (cols.len > 0) {
            var cx = x + list_cell_pad;
            for (cols, 0..) |cv, ci| {
                if (cv != .record) continue;
                const cw: usize = @intCast(@max(intField(cv.record, "w", 80), 8));
                drawStrTrunc(cx, ty, R_UI, cellAt(cellsv, ci), cw -| 8, ink, cell_bg);
                cx += cw;
            }
        } else {
            drawStrTrunc(x + list_cell_pad, ty, R_UI, cellAt(cellsv, 0), rows_w -| (2 * list_cell_pad), ink, cell_bg);
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
        list_hits[nlisthit] = .{ .id = id, .x = x, .rows_top = rows_top, .rows_w = rows_w, .row_h = row_h, .sb_x = sb_x, .st = st };
        nlisthit += 1;
    }
    if (nfoc < focusables.len) {
        focusables[nfoc] = .{ .id = id, .is_field = false, .is_list = true, .bx = x, .by = y, .bw = w, .bh = box_h };
        nfoc += 1;
    }
    return .{ .w = w, .h = box_h };
}

/// A two-pane split: a fixed-width `left` node, a divider, and a `right`
/// node filling the rest. `left_w` sets the sidebar width (default 220).
fn drawSplit(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const left = rec.get("left");
    const right = rec.get("right");
    const left_w: usize = @intCast(@max(intField(rec, "left_w", 220), 80));
    const div = 1 + gap; // a hairline rule plus breathing room each side
    const lh = if (left) |l| drawNode(l, x, y, @min(left_w, avail_w)) else Size{ .w = 0, .h = 0 };
    const rx = x + left_w + div;
    const rw = if (avail_w > left_w + div) avail_w - left_w - div else 0;
    // The divider, as tall as the taller pane (measured from left first).
    const rh = if (right) |r| drawNode(r, rx, y, rw) else Size{ .w = 0, .h = 0 };
    const h = @max(lh.h, rh.h);
    fillRect(x + left_w + gap / 2, y, pal.border_w, h, pal.border);
    return .{ .w = avail_w, .h = h };
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
fn listClick(id: []const u8, x: usize, y: usize) ListClick {
    for (list_hits[0..nlisthit]) |lh| {
        if (!std.mem.eql(u8, lh.id, id)) continue;
        const st = lh.st;
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
        const activated = st.last_click == @as(i64, @intCast(row));
        st.sel = row;
        st.last_click = @intCast(row);
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
        fvals[i] = .{ .str = try it.arena.dupe(u8, f.buf[0..f.len]) };
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

fn isDone(state: Value) bool {
    if (state != .record) return false;
    const d = state.record.get("done") orelse return false;
    return d.asBool();
}

// -------------------------------------------------------------- the top bar
//
// A resident menu bar pinned at the top of the scanout: menu titles at the
// left, right-aligned items (a live clock) at the right. A menu opens a
// DROPDOWN — a second, transient surface, because moss surfaces are opaque,
// so a menu overlaying windows must be its own surface; it is dismissed on a
// selection, a click elsewhere, or Escape. The bar's `view(state)` returns
// `{ left: [...], right: [...] }` of `{kind:menu,...}` / `{kind:label,...}`;
// a selected item fires `update(state, { menu, item })`. Windows open below
// the bar (a reserved strut `wf.top_strut`), so it is never covered.

const bar_vpad = 8;
const menu_hpad = 12;

const MenuHit = struct { id: []const u8, bx: usize, bw: usize, items: []const Value };
var bar_menus: [8]MenuHit = undefined;
var bar_nmenus: usize = 0;

// The dropdown popup — the bar process's second surface.
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
var pop_items: []const Value = &.{};
var pop_item_h: usize = 0;

fn barItemWidth(item: Value) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const kind = strField(rec, "kind");
    const text = if (std.mem.eql(u8, kind, "menu")) strField(rec, "title") else strField(rec, "text");
    return strW(R_UI, text) + 2 * menu_hpad;
}

/// Draw one bar item (a menu title or a label) at (x, cy_top); record a menu
/// title's hit box. Returns the advance width.
fn drawBarItem(item: Value, x: usize, cy: usize) usize {
    if (item != .record) return 0;
    const rec = item.record;
    const kind = strField(rec, "kind");
    if (std.mem.eql(u8, kind, "menu")) {
        const title = strField(rec, "title");
        const w = strW(R_UI, title) + 2 * menu_hpad;
        const id = strField(rec, "id");
        if (pop_open and std.mem.eql(u8, pop_menu_id, id)) fillRect(x, 0, w, wf.win_h - pal.border_w, pal.surface_hi);
        drawStr(x + menu_hpad, cy, R_UI, title, pal.title, pal.surface);
        if (bar_nmenus < bar_menus.len) {
            const items: []const Value = if (rec.get("items")) |iv| (if (iv == .list) iv.list else &.{}) else &.{};
            bar_menus[bar_nmenus] = .{ .id = id, .bx = x, .bw = w, .items = items };
            bar_nmenus += 1;
        }
        return w;
    }
    const text = strField(rec, "text");
    const muted = rec.get("muted") != null and (rec.get("muted").?).asBool();
    drawStr(x + menu_hpad, cy, R_UI, text, if (muted) pal.text_muted else pal.text, pal.surface);
    return strW(R_UI, text) + 2 * menu_hpad;
}

fn renderBar(tree: Value) void {
    bar_nmenus = 0;
    fillAll(pal.surface);
    fillRect(0, wf.win_h - pal.border_w, wf.win_w, pal.border_w, pal.border);
    const cy = if (wf.win_h > lineOf(R_UI)) (wf.win_h - lineOf(R_UI)) / 2 else 0;
    if (tree != .record) return;
    const rec = tree.record;
    var x: usize = menu_hpad / 2;
    if (rec.get("left")) |lv| if (lv == .list) for (lv.list) |item| {
        x += drawBarItem(item, x, cy);
    };
    if (rec.get("right")) |rv| if (rv == .list) {
        var tot: usize = 0;
        for (rv.list) |item| tot += barItemWidth(item);
        var rx = if (wf.win_w > tot + menu_hpad) wf.win_w - tot - menu_hpad else x;
        for (rv.list) |item| rx += drawBarItem(item, rx, cy);
    };
}

/// The menu title under a bar click (surface-local), or null.
fn menuAt(lx: usize) ?usize {
    for (bar_menus[0..bar_nmenus], 0..) |m, i| {
        if (lx >= m.bx and lx < m.bx + m.bw) return i;
    }
    return null;
}

/// The dropdown item under a popup click (surface-local), or null.
fn popItemAt(ly: usize) ?usize {
    if (pop_item_h == 0 or ly < 4) return null;
    const idx = (ly - 4) / pop_item_h;
    if (idx < pop_items.len) return idx;
    return null;
}

fn renderPopup() void {
    // Retarget the frame's drawing primitives at the popup buffer for the
    // duration (the popup is this process's second surface).
    const save_px = wf.px;
    const save_w = wf.win_w;
    const save_h = wf.win_h;
    wf.px = pop_px;
    wf.win_w = pop_w;
    wf.win_h = pop_h;
    panel(0, 0, pop_w, pop_h, 8, pal.surface, pal.border, pal.border_w);
    const cyoff = (pop_item_h - lineOf(R_UI)) / 2;
    for (pop_items, 0..) |it, i| {
        if (it != .str) continue;
        drawStr(menu_hpad, 4 + i * pop_item_h + cyoff, R_UI, it.str, pal.text, pal.surface);
    }
    wf.px = save_px;
    wf.win_w = save_w;
    wf.win_h = save_h;
}

fn openPopup(m: MenuHit) void {
    if (pop_open) closePopup();
    if (m.items.len == 0) return;
    pop_menu_id = m.id;
    pop_items = m.items;
    pop_item_h = lineOf(R_UI) + 2 * item_vpad;
    var maxw: usize = 80;
    for (pop_items) |it| if (it == .str) {
        const w = strW(R_UI, it.str);
        if (w > maxw) maxw = w;
    };
    pop_w = maxw + 2 * menu_hpad;
    pop_h = pop_items.len * pop_item_h + 8;
    pop_x = @min(wf.win_x + m.bx, scanout_w - pop_w);
    pop_y = wf.win_y + wf.win_h;
    const cs = switch (usys.callTypedCap(shared.GpuReq, shared.GpuResp, wf.chan, .{ .create_surface = .{ .xy = shared.packPair(@intCast(pop_x), @intCast(pop_y)), .wh = shared.packPair(@intCast(pop_w), @intCast(pop_h)) } }, 0)) {
        .ok => |ok| ok,
        .err => return,
    };
    pop_surf = switch (cs.rep) {
        .created => |c| c.surface,
        else => return,
    };
    if (cs.cap == 0) return;
    const mp = usys.shmMap(cs.cap);
    if (mp.err != .ok) {
        _ = usys.capDrop(cs.cap);
        return;
    }
    pop_cap = cs.cap;
    pop_va = mp.data[0];
    pop_px = @ptrFromInt(mp.data[0]);
    pop_open = true;
    renderPopup();
    _ = usys.callTyped(shared.GpuReq, shared.GpuResp, wf.chan, .{ .commit = .{ .surface = pop_surf, .xy = 0, .wh = shared.packPair(@intCast(pop_w), @intCast(pop_h)) } }, 0);
    var lb: [96]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&lb, "topbar: popup at {d},{d} ih={d} n={d}", .{ pop_x, pop_y, pop_item_h, pop_items.len }) catch "topbar: popup");
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
fn runBar(it: *mshl.Interp, view: Value, update: Value, init_state: Value) mshl.Error!Value {
    if (!wf.fontOk()) wf.fontReady();
    wf.refreshAppearance();
    wf.useOrdinaryChannel();
    wf.win_x = 0;
    wf.win_y = 0;
    wf.win_w = scanout_w;
    wf.win_h = lineOf(R_UI) + 2 * bar_vpad + pal.border_w;
    wf.dragging = false;
    wf.ptr_down = false;
    pop_open = false;
    if (!wf.openSurface(false)) return it.fail("gui: cannot open the bar surface", .{});
    defer wf.closeSurface();
    defer closePopup();

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    while (true) {
        it.reclaim();
        renderBar(tree);
        if (!wf.commitSurface()) return it.fail("gui: bar commit failed", .{});
        if (!announced) {
            _ = usys.log(log_h, "topbar: ready");
            // Log each menu title's hit-box centre so a drill can click it
            // precisely at any scale (the bar's size follows the font scale),
            // the way the dock logs its pills.
            for (bar_menus[0..bar_nmenus]) |m| {
                var mb: [64]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&mb, "topbar: menu {s} cx={d} cy={d}", .{ m.id, m.bx + m.bw / 2, wf.win_h / 2 }) catch "topbar: menu");
            }
            announced = true;
        }
        var fired_menu: ?[]const u8 = null;
        var fired_item: ?[]const u8 = null;
        input: while (true) {
            const ev = wf.nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2) {
                tree = try it.callValue(view, &.{state}, null, null); // refresh the clock
                break :input;
            }
            if (ev.kind == 1) {
                const down = ev.btn & 1 != 0;
                const press = down and !wf.ptr_down;
                wf.ptr_down = down;
                if (press) {
                    if (pop_open and ev.surface == pop_surf) {
                        if (popItemAt(ev.y)) |idx| {
                            fired_menu = pop_menu_id;
                            fired_item = pop_items[idx].str;
                            closePopup();
                            break :input;
                        }
                    } else if (ev.surface == wf.surf) {
                        if (menuAt(ev.x)) |mi| {
                            const was_this = pop_open and std.mem.eql(u8, pop_menu_id, bar_menus[mi].id);
                            closePopup();
                            if (!was_this) openPopup(bar_menus[mi]);
                            break :input; // re-render the highlight
                        } else if (pop_open) {
                            closePopup();
                            break :input;
                        }
                    }
                }
                continue :input;
            }
            if (ev.ch == 27 and pop_open) { // Escape
                closePopup();
                break :input;
            }
        }
        if (fired_item) |item| {
            const ev = try mkMenuEvent(it, fired_menu orelse "", item);
            state = try it.callValue(update, &.{ state, ev }, null, null);
            tree = try it.callValue(view, &.{state}, null, null);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "topbar: closed");
    return state;
}

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
        total += strW(R_UI, strField(item.record, "title")) + 2 * dock_hpad;
        n += 1;
    }
    if (n > 1) total += (n - 1) * dock_gap;
    const pill_h = lineOf(R_UI) + 2 * item_vpad;
    const py = if (wf.win_h > pill_h) (wf.win_h - pill_h) / 2 else 0;
    var x: usize = if (wf.win_w > total) (wf.win_w - total) / 2 else dock_gap;
    for (items) |item| {
        if (item != .record) continue;
        const r = item.record;
        const title = strField(r, "title");
        const unit = strField(r, "unit");
        const running = r.get("running") != null and (r.get("running").?).asBool();
        const w = strW(R_UI, title) + 2 * dock_hpad;
        const fill = if (running) pal.primary else pal.surface_hi;
        const ink = if (running) pal.primary_ink else pal.text;
        fillRoundRect(x, py, w, pill_h, 10, fill);
        drawStr(x + dock_hpad, py + item_vpad, R_UI, title, ink, fill);
        if (running and wf.win_h > 4) fillDot(x + w / 2, wf.win_h - 4, 2, pal.primary);
        if (dock_nitems < dock_items.len) {
            // Log a pill's running state only when it flips (never the
            // first render's baseline), so a launch lights the dot and an
            // exit clears it observably (the view polls `unit-up` each tick)
            // without spamming every tick.
            if (dock_running_known and dock_items[dock_nitems].running != running) {
                var rb: [64]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&rb, "dock: running {s}={}", .{ unit, running }) catch "dock: running");
            }
            dock_items[dock_nitems] = .{ .unit = unit, .title = title, .running = running, .bx = x, .bw = w };
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
fn runDock(it: *mshl.Interp, view: Value, update: Value, init_state: Value) mshl.Error!Value {
    if (!wf.fontOk()) wf.fontReady();
    wf.refreshAppearance();
    wf.useOrdinaryChannel();
    const pill_h = lineOf(R_UI) + 2 * item_vpad;
    wf.win_w = scanout_w;
    wf.win_h = pill_h + 2 * dock_vpad + pal.border_w;
    wf.win_x = 0;
    wf.win_y = if (scanout_h > wf.win_h) scanout_h - wf.win_h else 0;
    wf.dragging = false;
    wf.ptr_down = false;
    if (!wf.openSurface(false)) return it.fail("gui: cannot open the dock surface", .{});
    defer wf.closeSurface();

    var state = init_state;
    var tree = try it.callValue(view, &.{state}, null, null);
    var announced = false;
    while (true) {
        it.reclaim();
        renderDock(tree);
        if (!wf.commitSurface()) return it.fail("gui: dock commit failed", .{});
        if (!announced) {
            var lb: [64]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&lb, "dock: ready n={d}", .{dock_nitems}) catch "dock: ready n=0");
            // The click router needs each pill's centre; log them so a drill
            // can aim precisely (like the top bar's popup geometry).
            for (dock_items[0..dock_nitems], 0..) |d, i| {
                var ib: [64]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&ib, "dock: item {d} cx={d} cy={d}", .{ i, d.bx + d.bw / 2, wf.win_y + wf.win_h / 2 }) catch "dock: item");
            }
            announced = true;
        }
        var fired: ?usize = null;
        var quit = false;
        input: while (true) {
            const ev = wf.nextInput() orelse return it.fail("gui: the display channel closed", .{});
            if (ev.kind == 2) {
                tree = try it.callValue(view, &.{state}, null, null); // tick refresh
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
            if (ev.ch == 27) { // Escape ends the dock (and the session)
                quit = true;
                break :input;
            }
        }
        if (quit) break;
        if (fired) |idx| {
            const unit = dock_items[idx].unit;
            var lb: [64]u8 = undefined;
            _ = usys.log(log_h, std.fmt.bufPrint(&lb, "dock: activate {s}", .{unit}) catch "dock: activate");
            const ev = try mkDockEvent(it, unit, dock_items[idx].title);
            state = try it.callValue(update, &.{ state, ev }, null, null);
            tree = try it.callValue(view, &.{state}, null, null);
            if (isDone(state)) break;
        }
    }
    _ = usys.log(log_h, "dock: closed");
    return state;
}

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
        return try runBar(it, view, update, state);
    }
    // `dock: true` is the resident bottom dock — a bar of app buttons that
    // launch their units on a click, pinned full-width, not a window.
    if (spec.get("dock") != null and (spec.get("dock").?).asBool()) {
        return try runDock(it, view, update, state);
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
    // A fresh window: no drag in flight (module state persists across
    // `gui` calls in one process), and it opens focused (the compositor
    // sets a new surface as focused; a later `kind` 4 corrects us if not).
    wf.dragging = false;
    wf.ptr_down = false;
    wf.pending_dot = null;
    wf.win_focused = true;
    wf.win_trusted = want_trusted;
    wf.maximized = false;
    // Width: `width: N` narrows the window (a desktop lays out several
    // smaller windows); default is the roomy single-window width.
    wf.win_w = win_w_default;
    if (spec.get("width")) |wv| {
        if (wv == .int and wv.int >= 200) wf.win_w = @min(@as(usize, @intCast(wv.int)), scanout_w);
    }
    wf.win_x = (scanout_w - wf.win_w) / 2;
    if (!wf.fontOk()) wf.fontReady(); // attach the system font once (bitmap fallback if absent)
    wf.refreshAppearance(); // resolve the palette from the system/user settings
    sizeToContent(it, view, state, title); // fit the window to its content
    // `at: { x, y }` places the window instead of centring it (a desktop
    // that lays several windows out uses this).
    if (spec.get("at")) |a| {
        if (a == .record) {
            if (a.record.get("x")) |xv| {
                if (xv == .int and xv.int >= 0) wf.win_x = @min(@as(usize, @intCast(xv.int)), scanout_w - wf.win_w);
            }
            if (a.record.get("y")) |yv| {
                if (yv == .int and yv.int >= 0) wf.win_y = @min(@as(usize, @intCast(yv.int)), scanout_h - wf.win_h);
            }
        }
    }

    if (!wf.openSurface(true)) return it.fail("gui: cannot open a surface", .{});
    defer wf.closeSurface();
    // Name the surface so the dock can restore this window by its title
    // after the amber traffic-light minimizes it.
    if (title.len > 0) wf.setSurfaceTitle(title);

    var focus: usize = 0;
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
    while (true) {
        // Reclaim the previous render's dead boxes: a long-running GUI (or
        // one that reopens per apply, like the settings shell) would
        // otherwise pile up per-render trees until the interpreter runs
        // out of memory.
        it.reclaim();
        const nfocus = renderTree(tree, title, focus);
        if (nfocus > 0 and focus >= nfocus) focus = nfocus - 1;
        if (!wf.commitSurface()) return it.fail("gui: commit failed", .{});
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
                var l: [96]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: list {s} cx={d} rows_top={d} row_h={d} sb={d}", .{ lh.id, wf.win_x + lh.x + lh.rows_w / 2, wf.win_y + lh.rows_top, lh.row_h, if (lh.sb_x > 0) wf.win_x + lh.sb_x else 0 }) catch continue);
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
            // A focus change: the compositor tells us we gained or lost the
            // keyboard (arg 1/0). Re-render so the chrome dims or brightens.
            if (ev.kind == 4) {
                const now = ev.ch != 0;
                if (now == wf.win_focused) continue :input;
                wf.win_focused = now;
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
                if (wf.dragging or minimized) continue :input;
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
                switch (wf.onPointer(ev, title)) {
                    .none => {},
                    .content => |cev| {
                        if (hitWidget(nfocus, cev.x, cev.y)) |wi| {
                            focus = wi;
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
                                fired = focusables[wi].id;
                                break :input;
                            }
                            // A field: focus is set; wait for the next event.
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
                        relog_geom = true; // the dots moved with the window
                        _ = usys.log(log_h, switch (zone) {
                            .left => "gui: snapped left",
                            .right => "gui: snapped right",
                            .max => "gui: maximized",
                            .none => "gui: unmaximized",
                        });
                        break :input; // re-render into the new surface
                    },
                    .resize_failed => return it.fail("gui: cannot resize the window", .{}),
                }
                continue :input;
            }
            const ch = ev.ch;
            const cur: ?Focus = if (nfocus > 0) focusables[focus] else null;
            switch (ch) {
                '\t' => {
                    if (nfocus > 0) focus = (focus + 1) % nfocus;
                    break :input;
                },
                '\n' => {
                    if (cur) |c| {
                        if (c.is_field) {
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
                            st.last_click = -1;
                            fired = c.id;
                            fired_list = true;
                            fired_row = listRowId(tree, c.id, st.sel);
                            fired_activated = false;
                            break :input;
                        }
                    };
                },
                8 => { // backspace
                    if (cur) |c| if (c.is_field) {
                        fieldBackspace(c.id);
                        break :input;
                    };
                },
                else => {
                    if (ch >= 32 and ch < 127) {
                        if (cur) |c| if (c.is_field) {
                            fieldAppend(c.id, ch);
                            break :input;
                        };
                    }
                },
            }
        }
        // The close box was clicked: end the app (its `gui` call returns
        // the last state, like a `done`).
        if (closed) break;
        if (ticked and remote_node == 0) {
            // Recompute the view from the unchanged state — no `update` on
            // a tick — so a clock or other time-driven view refreshes.
            tree = try it.callValue(view, &.{state}, null, null);
        }
        if (fired) |id| {
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
    return state;
}
