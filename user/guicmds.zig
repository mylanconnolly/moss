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
const guipage = @import("guipage.zig");

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
    // The chrome is woken to re-declare the moment the appearance changes
    // (`appearance_changed`), so this is a short backstop, not the plan;
    // if it runs out, the log says so and the window centres in what the
    // compositor has (the guishellro drill once caught it 8 px off).
    while (tries < 12) : (tries += 1) {
        const top_ok = wa.y == 0 or wa.y == bar_h;
        const bottom_ok = wa.y + wa.h == wf.scanout_h or wa.y + wa.h + dockHeight() == wf.scanout_h;
        if (top_ok and bottom_ok) break;
        usys.sleepMs(50);
        wa = wf.workArea();
    }
    if (tries == 12) _ = usys.log(log_h, "gui: work area unsettled; placing anyway");
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
/// The host's retained-value pool occupancy (chunks busy), logged when it
/// climbs a step past the last mark: which turn fills it.
pub var pool_busy: ?*const fn () usize = null;
var pool_mark: usize = 0;
fn notePool(what: []const u8) void {
    const f = pool_busy orelse return;
    const busy = f();
    if (busy < pool_mark + 256) return;
    pool_mark = busy;
    var line: [120]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&line, "gui: pool {d} chunks busy after {s}", .{ busy, what }) catch "gui: pool");
}

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

/// What the `page` leaf needs to host page domains (a spawner, the
/// network view its broker fetches over, a view for fonts, the stores
/// the `webpage` image is staged from); without them a page leaf shows
/// nothing and says why.
pub fn setupPages(spawner: u64, n: *@import("netcmds.zig").Net, view_chan: u64, view_buf: [*]u8, assets_view: bool, stores: []const ?@import("fscmds.zig").Store, log: u64, fabric: u64) void {
    guipage.setup(spawner, n, view_chan, view_buf, assets_view, stores, log, fabric);
}

/// The pages' `localStorage` persists under the program's own view (a
/// session app's home), in `state/browser/storage`.
pub fn setStorageView(view_chan: u64, view_buf: [*]u8) void {
    guipage.setStorageDir(view_chan, view_buf, "state/browser/storage");
}

fn boolField(rec: mshl.Record, key: []const u8, dflt: bool) bool {
    const v = rec.get(key) orelse return dflt;
    return switch (v) {
        .bool => |b| b,
        else => dflt,
    };
}

/// Whether the host holds a display — `gui` is offered only then.
pub fn on() bool {
    return wf.display != 0;
}

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "apps")) return .{ .ret = .list };
    // `page-info ID`: what the page domain behind a `page` leaf holds —
    // its memory against its budget, and whether it is alive.
    if (std.mem.eql(u8, name, "page-info")) return .{ .params = &.{.{ .name = "id", .shape = .string }}, .ret = .record };
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
    // `toggle-window TITLE` is the dock pill's click on a running app:
    // a hidden window comes back, the focused one hides, one behind
    // others comes forward. `ok` when one matched, else an error.
    if (std.mem.eql(u8, name, "toggle-window")) {
        return .{ .params = &.{.{ .name = "title", .shape = .string }}, .ret = restore_result };
    }
    // `quit-window TITLE` asks the running window with that title to close
    // itself — the close_window key its app handles like the red dot or
    // Cmd-W, so an editor may ask about unsaved work. Needs the display
    // control cap (the task manager's Quit, before Force Quit). `ok` when
    // the request was accepted; the app decides what happens next.
    if (std.mem.eql(u8, name, "quit-window")) {
        return .{ .params = &.{.{ .name = "title", .shape = .string }}, .ret = restore_result };
    }
    return null;
}

const restore_result = mshl.resultShape(.string, .string);

/// `restore-window` and `toggle-window`: the titled window through the
/// given endpoint; `ok TITLE` when one matched, else `err "not running"`.
fn windowByTitle(it: *mshl.Interp, name: []const u8, args: []const Value, chan: u64, what: enum { restore, toggle }) mshl.Error!?Value {
    if (chan == 0) return it.fail("{s}: this program holds no display for it", .{name});
    if (args.len == 0 or args[0] != .str) return it.fail("{s}: a window title expected", .{name});
    const w = shared.strToWords(args[0].str);
    const req: shared.GpuReq = switch (what) {
        .restore => .{ .restore_titled = .{ .a = w[0], .b = w[1] } },
        .toggle => .{ .toggle_titled = .{ .a = w[0], .b = w[1] } },
    };
    const ok = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, chan, req, 0)) {
        .ok => |r| r == .ok,
        .err => false,
    };
    return if (ok)
        try it.mkResult(true, .{ .str = try it.arena.dupe(u8, args[0].str) })
    else
        try it.mkResult(false, .{ .str = "not running" });
}

// ------------------------------------------------------------ rendering
//
// The drawing primitives, the system font (fontsvc) and the semantic
// palette are the frame's — see windowframe.zig. What stays here is the
// widget *content*: the layout of the view tree over the frame's content
// area, plus the field/list interaction state the runtime owns.

const pad = ui.space.inset; // window inset for content

/// How often the loop looks in on live pages (their commits and news).
const page_tick_ms: u64 = 40;

// The laid-out content height, from the measuring pass — the frame's
// window is sized to it before the surface is created (`sizeToContent`).
var content_h: usize = 0;

// A focusable widget: its id, whether it is a text field (which eats
// typing) or a button (which fires on Enter), and its clickable box on
// the surface (so a pointer press can hit-test which widget it landed on).
const Focus = struct { crumb: ?*Crumb = null, sy: isize = 0, cy0: usize = 0, cy1: usize = 0, cx0: usize = 0, cx1: usize = 0, owner: usize = 0, id: []const u8, is_field: bool, submit: []const u8 = "", is_list: bool = false, is_page: bool = false, is_button: bool = false, is_toggle: bool = false, page_slot: usize = 0, bx: usize = 0, by: usize = 0, bw: usize = 0, bh: usize = 0 };
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
/// Counts renders: a widget's runtime state (an edit buffer, a list's
/// scroll, a breadcrumb's selection) remembers the render it was last
/// painted in, which is its *lifetime* — present in the latest render, or
/// absent and evictable when its table is full. Identity is the id.
var render_serial: u32 = 0;
/// A limit was hit: name it (which table, which id) at the point, rather
/// than failing the window with a message that could mean six things.
fn limitHit(what: []const u8, id: []const u8) void {
    layout_overflow = true;
    warn(what, id);
}
/// The same line for a limit the window survives (a shared slot, a tab
/// strip that cannot be clicked): named, not fatal.
fn warn(what: []const u8, id: []const u8) void {
    var lb: [128]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: limit: {s} ({s})", .{ what, id }) catch "gui: limit");
}
/// The entry to evict when a keyed table is full: one absent from the
/// latest render, the longest absent first; null when every entry is in
/// the view right now (then nothing can give way).
fn evictable(comptime T: type, entries: []T) ?*T {
    var pick: ?*T = null;
    for (entries) |*e| {
        if (e.last_seen >= render_serial) continue;
        if (pick == null or e.last_seen < pick.?.last_seen) pick = e;
    }
    return pick;
}
fn logEvict(what: []const u8, old: []const u8, new: []const u8) void {
    var lb: [128]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: {s} {s} evicted for {s}", .{ what, old, new }) catch "gui: evicted");
}
var scroll_dirty = false;
fn containsScroll(node: Value, id: []const u8) bool {
    if (node != .record) return false;
    const rec = node.record;
    if (std.mem.eql(u8, strField(rec, "kind"), "scroll") and std.mem.eql(u8, strField(rec, "id"), id)) return true;
    for (nodeChildren(rec)) |child| if (containsScroll(child, id)) return true;
    for ([_][]const u8{ "child", "left", "right", "dialog" }) |key| {
        if (rec.get(key)) |child| if (containsScroll(child, id)) return true;
    }
    return false;
}
fn scrollFor(id: []const u8) usize {
    for (scrolls[1..], 1..) |st, i| if (st.used and std.mem.eql(u8, st.id[0..st.len], id)) {
        if (st.seen) {
            limitHit("duplicate scroll id", id);
            return 0;
        }
        return i;
    };
    for (scrolls[1..], 1..) |*st, i| if (!st.used) {
        st.* = .{ .used = true, .len = @min(id.len, st.id.len) };
        @memcpy(st.id[0..st.len], id[0..st.len]);
        return i;
    };
    limitHit("scroll viewports", id);
    return 0;
}
fn recordFocus(f: Focus) void {
    if (nfoc == focusables.len) {
        limitHit("focusable widgets", f.id);
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
    // The viewport's height is the offer: content that grows fills it,
    // content that does not is measured natural and may scroll.
    var size = layoutNode(node, 0, 0, width, height, false);
    const overflow = size.h > height;
    const content_w = width -| (if (overflow) @as(usize, 14) else 0);
    if (overflow) size = layoutNode(node, 0, 0, content_w, height, false);
    st.state.fit(size.h, height);
    scroll_owner = owner;
    wf.draw_offset_y -= @intCast(st.state.offset);
    _ = drawNode(node, x, y, content_w, height);
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
const max_lists = 8;
const ListState = struct {
    used: bool = false,
    last_seen: u32 = 0,
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
            slot = l;
            break;
        };
        // Full: a list that left the view gives its slot up; one still in
        // the view cannot, and the newcomer shares the first slot (said so).
        if (slot == null) if (evictable(ListState, &list_states)) |e| {
            logEvict("list", e.id[0..e.id_len], id);
            slot = e;
        } else {
            warn("lists; the newcomer shares the first slot", id);
            slot = &list_states[0];
        };
        slot.?.* = .{ .used = true };
        slot.?.id_len = @min(id.len, slot.?.id.len);
        @memcpy(slot.?.id[0..slot.?.id_len], id[0..slot.?.id_len]);
    }
    const l = slot.?;
    l.last_seen = render_serial;
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
const max_fields = 16;
const FieldBuf = struct {
    used: bool = false,
    last_seen: u32 = 0,
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
        if (f.used and std.mem.eql(u8, f.id[0..f.id_len], id)) {
            f.last_seen = render_serial;
            return f;
        }
    }
    var slot: ?*FieldBuf = null;
    for (&field_bufs) |*f| if (!f.used) {
        slot = f;
        break;
    };
    // Full: a field that left the view gives its buffer up (its text was
    // ephemeral — the committed value is the app's); one still in the
    // view cannot, and the newcomer shares the first slot (said so).
    if (slot == null) if (evictable(FieldBuf, &field_bufs)) |e| {
        logEvict("field", e.id[0..e.id_len], id);
        slot = e;
    } else {
        warn("fields; the newcomer shares the first slot", id);
        return &field_bufs[0];
    };
    const f = slot.?;
    f.* = .{ .used = true, .last_seen = render_serial };
    f.id_len = @min(id.len, f.id.len);
    @memcpy(f.id[0..f.id_len], id[0..f.id_len]);
    f.edit.seed(seed);
    return f;
}

var field_drag: ?usize = null;
/// Clicks on one field in quick succession: the second selects the word
/// under the pointer, the third the line, the fourth everything.
var field_clicks: ui.pointer.MultiClick = .{};
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
    render_serial +%= 1;
    file_crumb = null;
    clipReset();
    fillAll(pal.bg);
    content_bg = pal.bg;
    sel_focus = focus;
    nfoc = 0;
    nlisthit = 0;
    ntabhit = 0;
    // The frame paints the titlebar (bar, traffic-light dots, title) and
    // sets `wf.title_h` — the content area starts below it.
    wf.drawChrome(title);
    // A tab bar is chrome too: flush under the titlebar, edge to edge,
    // and the padded body — the selected tab's page — begins below it.
    tabbar_h = 0;
    const body = if (topBar(tree)) |bar| paintTopBar(tree.record, bar) else tree;
    const top = wf.title_h + tabbar_h;
    // Content area below the chrome. Record the full height it wants so
    // the window can be sized to fit before its surface is created.
    for (scrolls[1..]) |*st| if (st.used and !containsScroll(tree, st.id[0..st.len])) {
        st.* = .{};
    };
    for (&scrolls) |*st| st.seen = false;
    // Page domains live as long as their leaves: one not in this tree is
    // reaped before the paint that would have shown it.
    reap_tree = tree;
    guipage.reap(pagePresent);
    guipage.beginRender();
    scroll_owner = 0;
    layout_overflow = false;
    _ = paintViewport(body, pad, top + pad, wf.win_w -| (2 * pad), wf.win_h -| (top + 2 * pad), 0);
    paintDialog(tree, top);
    return nfoc;
}

/// `view` may return its root with `dialog: { id, title, cancel, w,
/// children… }`: a modal sheet over the content. The sheet is any node
/// (a column of a message and buttons, usually) under a title, centred on
/// a scrim that dims the body; while it is up only its widgets can take
/// focus or a click, Escape fires `cancel` (an event id) if it names one,
/// and the body keeps its scroll and its fields. The runtime holds no
/// dialog state: the app opens one by putting it in the view and closes
/// it by leaving it out, as with every other widget.
var dialog_cancel: [64]u8 = undefined;
var dialog_cancel_len: usize = 0;
var dialog_shown: bool = false;
fn paintDialog(tree: Value, top: usize) void {
    dialog_cancel_len = 0;
    const d = if (tree == .record) tree.record.get("dialog") orelse Value.nothing else Value.nothing;
    if (d != .record) {
        if (dialog_shown and !wf.measuring) _ = usys.log(log_h, "gui: dialog closed");
        dialog_shown = false;
        return;
    }
    const rec = d.record;
    const cancel = strField(rec, "cancel");
    dialog_cancel_len = @min(cancel.len, dialog_cancel.len);
    @memcpy(dialog_cancel[0..dialog_cancel_len], cancel[0..dialog_cancel_len]);
    const body_focus = nfoc;
    const inset = ui.paint.sheet_inset;
    const area_h = wf.win_h -| top;
    const w = @min(@as(usize, @intCast(std.math.clamp(intField(rec, "w", 420), 160, 4096))), wf.win_w -| 2 * pad);
    const inner = w -| 2 * inset;
    const title = strField(rec, "title");
    const title_h = if (title.len > 0) lineOf(R_TITLE) + ui.space.medium else 0;
    const want = title_h + layoutNode(d, 0, 0, inner, 0, false).h + 2 * inset;
    const h = @min(want, area_h -| 2 * pad);
    const sx = (wf.win_w -| w) / 2;
    const sy = top + (area_h -| h) / 2;
    const b = wf.brush();
    ui.paint.scrim(b, .{ .x = 0, .y = top, .w = wf.win_w, .h = area_h });
    ui.paint.sheet(b, .{ .x = sx, .y = sy, .w = w, .h = h });
    const saved_bg = content_bg;
    content_bg = pal.surface;
    defer content_bg = saved_bg;
    // The dialog's widgets are recorded after the body's and moved to the
    // front below, so the focus, hover and press indices (which name the
    // front list) are shifted while they paint, or none would ever match.
    const saved_sel = sel_focus;
    const saved_hover = hovered;
    const saved_press = pressed;
    sel_focus += body_focus;
    if (hovered) |hi| hovered = hi + body_focus;
    if (pressed) |pi| pressed = pi + body_focus;
    defer {
        sel_focus = saved_sel;
        hovered = saved_hover;
        pressed = saved_press;
    }
    if (title.len > 0) drawStrTrunc(sx + inset, sy + inset, R_TITLE, title, inner, pal.title, content_bg);
    // The sheet clips its content, so a dialog taller than the window
    // still ends inside its outline.
    const old = [4]usize{ wf.clip_x0, wf.clip_y0, wf.clip_x1, wf.clip_y1 };
    wf.clip_x0 = @max(old[0], sx);
    wf.clip_y0 = @max(old[1], sy);
    wf.clip_x1 = @min(old[2], sx + w);
    wf.clip_y1 = @min(old[3], sy + h);
    _ = drawNode(d, sx + inset, sy + inset + title_h, inner, 0);
    wf.clip_x0 = old[0];
    wf.clip_y0 = old[1];
    wf.clip_x1 = old[2];
    wf.clip_y1 = old[3];
    // Modal: the body's widgets are not there to Tab to or click while
    // the sheet is up — only the dialog's own, moved to the front.
    const n = nfoc - body_focus;
    std.mem.copyForwards(Focus, focusables[0..n], focusables[body_focus..nfoc]);
    nfoc = n;
    if (!dialog_shown and !wf.measuring) {
        var lb: [96]u8 = undefined;
        _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: dialog {s} open", .{strField(rec, "id")}) catch "gui: dialog open");
    }
    dialog_shown = !wf.measuring;
}

var reap_tree: Value = .nothing;
fn pagePresent(id: []const u8) bool {
    return containsPage(reap_tree, id);
}
fn containsPage(node: Value, id: []const u8) bool {
    if (node != .record) return false;
    const rec = node.record;
    if (std.mem.eql(u8, strField(rec, "kind"), "page") and std.mem.eql(u8, strField(rec, "id"), id)) return true;
    for (nodeChildren(rec)) |child| if (containsPage(child, id)) return true;
    for ([_][]const u8{ "child", "left", "right", "dialog" }) |key| {
        if (rec.get(key)) |child| if (containsPage(child, id)) return true;
    }
    return false;
}

/// An application's own menus: `gui { menus: { File: [ { text, id,
/// disabled }, "-", { text, items: [ … ] } ], … } }` — each key a menu
/// title (in record order), each entry an item that fires `{ id }` from
/// the bar, a `"-"` rule, or a nested menu one level deep. The titles and
/// labels are published to the compositor for the bar to read back; the
/// keys are application keys (shared/menus.zig) the compositor routes
/// like any catalog key, so the bar cannot invoke what the app did not
/// publish or disabled. A record here replaces the `menus: "files"`
/// profile string; the generic Window menu follows the app's own.
const CustomItem = struct {
    label: [shared.menus.label_bytes]u8 = @splat(0),
    label_len: u8 = 0,
    menu: u8 = 0,
    key: u8 = 0,
    sub: u8 = 0,
    id: [32]u8 = @splat(0),
    id_len: u8 = 0,
    /// The shortcut hint shown beside the label; a chord the registry
    /// produces (`shared.menus.shortcutKey`) also fires the item here.
    shortcut: [shared.menus.shortcut_bytes]u8 = @splat(0),
    shortcut_len: u8 = 0,
    chord: u8 = 0,
};
const CustomMenus = struct {
    titles: [shared.menus.max_menus][shared.menus.title_bytes]u8 = @splat(@splat(0)),
    title_len: [shared.menus.max_menus]u8 = @splat(0),
    nslots: usize = 0,
    items: [shared.menus.max_app_items]CustomItem = @splat(.{}),
    nitems: usize = 0,
    disabled: u64 = 0,
};
var custom_menus: CustomMenus = .{};
/// Nested menus go this deep (a header's slot, its header's slot…);
/// eight slots bound it too.
const max_menu_depth = 3;
fn customSlot(c: *CustomMenus, title: []const u8) ?u8 {
    if (c.nslots == shared.menus.max_menus) {
        warn("custom menus (8); this one is dropped", title);
        return null;
    }
    const n = @min(title.len, shared.menus.title_bytes);
    @memcpy(c.titles[c.nslots][0..n], title[0..n]);
    c.title_len[c.nslots] = @intCast(n);
    c.nslots += 1;
    return @intCast(c.nslots - 1);
}
fn customItem(c: *CustomMenus, slot: u8, label: []const u8, key: u8, sub: u8, id: []const u8, shortcut: []const u8) void {
    if (c.nitems == shared.menus.max_app_items) {
        warn("custom menu items (32); this one is dropped", label);
        return;
    }
    var item: CustomItem = .{ .menu = slot, .key = key, .sub = sub };
    item.shortcut_len = @intCast(@min(shortcut.len, item.shortcut.len));
    @memcpy(item.shortcut[0..item.shortcut_len], shortcut[0..item.shortcut_len]);
    if (key != 0) item.chord = shared.menus.shortcutKey(shortcut) orelse 0;
    item.label_len = @intCast(@min(label.len, item.label.len));
    @memcpy(item.label[0..item.label_len], label[0..item.label_len]);
    item.id_len = @intCast(@min(id.len, item.id.len));
    @memcpy(item.id[0..item.id_len], id[0..item.id_len]);
    c.items[c.nitems] = item;
    c.nitems += 1;
}
fn customItems(c: *CustomMenus, slot: u8, list: []const Value, depth: usize) void {
    for (list) |entry| switch (entry) {
        .str => |str| if (std.mem.eql(u8, str, "-")) customItem(c, slot, "", 0, 0, "", ""),
        .record => |r| {
            const text = strField(r, "text");
            const nested = if (r.get("items")) |v| (if (v == .list) v.list else null) else null;
            if (nested) |sub_list| {
                if (depth + 1 >= max_menu_depth) {
                    warn("custom menus nest three deep; this submenu is dropped", text);
                    continue;
                }
                const sub = customSlot(c, text) orelse continue;
                customItem(c, slot, text, 0, sub + 1, "", "");
                customItems(c, sub, sub_list, depth + 1);
                continue;
            }
            // The item's key is its index in the table: the compositor
            // routes it back as that application key.
            const key = shared.menus.appItemKey(c.nitems);
            if (c.nitems < shared.menus.max_app_items and (if (r.get("disabled")) |d| d.asBool() else false)) c.disabled |= shared.menus.bit(key);
            customItem(c, slot, text, key, 0, strField(r, "id"), strField(r, "shortcut"));
        },
        else => {},
    };
}
/// Build the table from a `menus` record (the spec's, or a view root's).
fn buildMenusInto(c: *CustomMenus, menus: mshl.Record) void {
    c.* = .{};
    for (menus.keys, menus.vals) |title, items| {
        if (items != .list) continue;
        const slot = customSlot(c, title) orelse break;
        customItems(c, slot, items.list, 0);
    }
}
/// True when the spec declares its own menus (a record under `menus`).
fn buildCustomMenus(spec: mshl.Record) bool {
    custom_menus = .{};
    const v = spec.get("menus") orelse return false;
    if (v != .record) return false;
    buildMenusInto(&custom_menus, v.record);
    return custom_menus.nslots > 0;
}
/// A view root's `menus` record: the menus for this render, replacing
/// the spec's — so labels, enabled items and whole menus follow the
/// state (a "Show sidebar" that reads "Hide sidebar"). Compared with
/// what is published; a change publishes again (the compositor bumps
/// the bar's token, which re-reads).
fn rootMenus(tree: Value) ?mshl.Record {
    if (tree != .record) return null;
    const v = tree.record.get("menus") orelse return null;
    return if (v == .record) v.record else null;
}
var view_menus_scratch: CustomMenus = .{};
fn followViewMenus(tree: Value) void {
    const menus = rootMenus(tree) orelse return;
    buildMenusInto(&view_menus_scratch, menus);
    if (std.meta.eql(view_menus_scratch, custom_menus)) return;
    custom_menus = view_menus_scratch;
    wf.republishMenu();
    _ = usys.log(log_h, "gui: menus changed");
}
fn publishCustomMenus() void {
    const c = &custom_menus;
    var titles: [shared.menus.max_menus][]const u8 = undefined;
    for (0..c.nslots) |i| titles[i] = c.titles[i][0..c.title_len[i]];
    var items: [shared.menus.max_app_items]wf.MenuItemSpec = undefined;
    for (0..c.nitems) |i| items[i] = .{ .menu = c.items[i].menu, .key = c.items[i].key, .sub = c.items[i].sub, .label = c.items[i].label[0..c.items[i].label_len], .shortcut = c.items[i].shortcut[0..c.items[i].shortcut_len] };
    if (wf.publishMenu(titles[0..c.nslots], items[0..c.nitems])) {
        var lb: [80]u8 = undefined;
        _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: menus published slots={d} items={d}", .{ c.nslots, c.nitems }) catch "gui: menus published");
        if (wf.menu_publish_refused) warn("menu publication refused by the compositor", "custom menus");
    }
}

/// The interpreter of the running `gui`, for staging the page image.
var page_it: ?*mshl.Interp = null;

/// `{ kind: "page", id, url, nav, visible, h, node, exit }`: a page
/// domain's viewport. The leaf takes the height offered (or `h`, 300
/// by default); a `visible: false` leaf takes no room and its page
/// keeps its document without a pixel buffer; `node` (0, the default:
/// this machine) hosts the page on that fabric node, this window its
/// broker; `exit` (0: this machine) sends the page's fetches out
/// through that node's network. The page's pixels are blitted
/// inside the rect and nowhere else — the chrome above it is this
/// window's, whatever the page paints.
fn layoutPage(rec: mshl.Record, x: usize, y: usize, avail_w: usize, avail_h: usize, paint: bool) Size {
    const id = strField(rec, "id");
    const visible = if (rec.get("visible")) |v| v.asBool() else true;
    const url = strField(rec, "url");
    const nav: i64 = if (rec.get("nav")) |n| (if (n == .int) n.int else 0) else 0;
    const node: u64 = @intCast(std.math.clamp(intField(rec, "node", 0), 0, 0xffff));
    const exit: u64 = @intCast(std.math.clamp(intField(rec, "exit", 0), 0, 0xffff));
    if (!visible) {
        if (paint) if (page_it) |it| if (guipage.slotFor(it, id, node)) |s| guipage.sync(s, url, nav, 0, 0, boolField(rec, "scripts", true), exit);
        return .{};
    }
    const h = @max(@as(usize, @intCast(std.math.clamp(intField(rec, "h", 300), 40, 4000))), avail_h);
    if (!paint) return .{ .w = avail_w, .h = h };
    const it = page_it orelse return .{ .w = avail_w, .h = h };
    const s = guipage.slotFor(it, id, node) orelse {
        fillRect(x, y, avail_w, h, pal.bg);
        guipage.pushFor(id, .unavailable, 0, guipage.last_refusal);
        return .{ .w = avail_w, .h = h };
    };
    s.x = x;
    s.y = y;
    s.sy = wf.screenY(y);
    guipage.sync(s, url, nav, @intCast(avail_w), @intCast(h), boolField(rec, "scripts", true), exit);
    guipage.syncExtras(s, pageExtras(rec));
    if (s.sy >= 0 and (s.logged_x != wf.win_x + x or s.logged_y != wf.win_y + @as(usize, @intCast(s.sy)) or s.logged_w != avail_w or s.logged_h != h)) {
        s.logged_x = wf.win_x + x;
        s.logged_y = wf.win_y + @as(usize, @intCast(s.sy));
        s.logged_w = @intCast(avail_w);
        s.logged_h = @intCast(h);
        var line: [128]u8 = undefined;
        _ = usys.log(log_h, std.fmt.bufPrint(&line, "gui: page {s} at {d},{d} size {d}x{d}", .{ id, s.logged_x, s.logged_y, avail_w, h }) catch "gui: page");
    }
    // Clip to the rect, blit, restore.
    const sx0 = wf.clip_x0;
    const sy0 = wf.clip_y0;
    const sx1 = wf.clip_x1;
    const sy1 = wf.clip_y1;
    wf.clip_x0 = @max(wf.clip_x0, x);
    wf.clip_y0 = @max(wf.clip_y0, wf.clipY(y));
    wf.clip_x1 = @min(wf.clip_x1, x + avail_w);
    wf.clip_y1 = @min(wf.clip_y1, wf.clipY(y + h));
    var ctx: BlitCtx = .{ .x = x, .y = y };
    if (!guipage.blit(s, @ptrCast(&ctx), blitRow)) fillRect(x, y, avail_w, h, pal.bg);
    wf.clip_x0 = sx0;
    wf.clip_y0 = sy0;
    wf.clip_x1 = sx1;
    wf.clip_y1 = sy1;
    recordFocus(.{ .id = id, .is_field = false, .is_page = true, .page_slot = @intFromPtr(s), .bx = x, .by = y, .bw = avail_w, .bh = h });
    return .{ .w = avail_w, .h = h };
}

/// A leaf's zoom (percent, over the user's font scale), the session's
/// appearance for the page's media queries, and its find.
fn pageExtras(rec: mshl.Record) guipage.Extras {
    const leaf_zoom: u64 = @intCast(std.math.clamp(intField(rec, "zoom", 100), 25, 400));
    const seed: u64 = wf.scaledIconSize(100); // the user's scale, in percent
    const flags = wf.appearanceFlags();
    var theme: u64 = 0;
    if (shared.apTheme(flags) == .dark) theme |= shared.web.ThemeFlags.dark;
    if (shared.apContrast(flags) == .high) theme |= shared.web.ThemeFlags.high_contrast;
    return .{ .zoom = @intCast(@max(25, leaf_zoom * seed / 100)), .theme = theme, .find = strField(rec, "find"), .find_nav = if (rec.get("find_nav")) |n| (if (n == .int) n.int else 0) else 0 };
}

const BlitCtx = struct { x: usize, y: usize };

/// One row of a page into the surface: clipped to the window's clip
/// rect (already narrowed to the leaf), copied whole where it shows.
fn blitRow(ctx: *anyopaque, index: usize, src: []const u32) void {
    const c: *BlitCtx = @ptrCast(@alignCast(ctx));
    const sy = wf.screenY(c.y + index);
    if (sy < 0) return;
    const yy: usize = @intCast(sy);
    if (yy < wf.clip_y0 or yy >= wf.clip_y1 or yy >= wf.win_h) return;
    const x0 = @max(c.x, wf.clip_x0);
    const x1 = @min(@min(c.x + src.len, wf.clip_x1), wf.win_w);
    if (x1 <= x0) return;
    const row = wf.px[yy * wf.win_w .. yy * wf.win_w + wf.win_w];
    for (x0..x1) |xx| row[xx] = src[xx - c.x];
}

fn pageOf(f: Focus) *guipage.Slot {
    return @ptrFromInt(f.page_slot);
}

/// The event for a page: `{ id, kind, text, code }` — `kind` one of
/// title, url, load (text: loading / done / failed; code: why), hover
/// (text: the link under the pointer, or empty), crashed, unavailable.
fn mkPageEvent(it: *mshl.Interp, pe: guipage.Event) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 4);
    keys[0] = "id";
    keys[1] = "kind";
    keys[2] = "text";
    keys[3] = "code";
    const vals = try it.arena.alloc(Value, 4);
    vals[0] = .{ .str = try it.arena.dupe(u8, pe.idText()) };
    vals[1] = .{ .str = @tagName(pe.kind) };
    var code: u64 = pe.code;
    var text: []const u8 = pe.textOf();
    if (pe.kind == .load) {
        const st = std.enums.fromInt(shared.web.LoadState, pe.code >> 32) orelse .failed;
        text = @tagName(st);
        code = pe.code & 0xffff_ffff;
    }
    // `found`: code is the count, text the index shown ("2" of 5).
    var found_buf: [16]u8 = undefined;
    if (pe.kind == .found) {
        text = std.fmt.bufPrint(&found_buf, "{d}", .{pe.code >> 32}) catch "0";
        code = pe.code & 0xffff_ffff;
    }
    vals[2] = .{ .str = try it.arena.dupe(u8, text) };
    vals[3] = .{ .int = @intCast(code) };
    return .{ .record = .{ .keys = keys, .vals = vals } };
}

/// The height of the window's tab bar this render (0 without one): the
/// body's viewport starts below the titlebar and it.
var tabbar_h: usize = 0;

/// The tab strip a window shows as chrome, if its tree is a column whose
/// first child is `{ kind: "tabs", bar: true, … }` — no inset around it,
/// the page it selects gets the inset instead.
fn topBar(tree: Value) ?mshl.Record {
    if (tree != .record) return null;
    const children = nodeChildren(tree.record);
    if (children.len == 0 or children[0] != .record) return null;
    const first = children[0].record;
    if (!std.mem.eql(u8, strField(first, "kind"), "tabs")) return null;
    const bar = if (first.get("bar")) |v| v.asBool() else false;
    if (!bar or tree.record.keys.len > body_keys.len) return null;
    return first;
}

// The body record a tab bar leaves: the root column without its first
// child. Built in place for one render, since a record is two slices.
var body_keys: [16][]const u8 = undefined;
var body_vals: [16]Value = undefined;

/// Paint `bar` flush under the titlebar, full width, with a rule beneath
/// it, set `tabbar_h`, and return the tree's body: `root` without its first
/// child (its other fields, gap and the like, kept).
fn paintTopBar(root: mshl.Record, bar: mshl.Record) Value {
    const y = wf.title_h + pal.border_w;
    const size = layoutTabs(bar, 0, y, wf.win_w, !wf.measuring);
    if (!wf.measuring) fillRect(0, y + size.h, wf.win_w, pal.border_w, pal.border);
    tabbar_h = pal.border_w + size.h + pal.border_w;
    const n = root.keys.len;
    for (root.keys, root.vals, 0..) |k, v, i| {
        body_keys[i] = k;
        body_vals[i] = if (std.mem.eql(u8, k, "children")) Value{ .list = nodeChildren(root)[1..] } else v;
    }
    return .{ .record = .{ .keys = body_keys[0..n], .vals = body_vals[0..n] } };
}

/// Lay the tree out without drawing, to find the window height its content
/// needs (clamped to the scanout), and centre the window at it.
fn sizeToContent(it: *mshl.Interp, view: Value, state: Value, title: []const u8) void {
    const tree = it.callValue(view, &.{state}, null, null) catch return;
    wf.measuring = true;
    wf.drawChrome(title);
    tabbar_h = 0;
    const body = if (topBar(tree)) |bar| paintTopBar(tree.record, bar) else tree;
    content_h = wf.title_h + tabbar_h + 2 * pad + layoutNode(body, 0, 0, wf.win_w - 2 * pad, 0, false).h;
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
    // How the window was sized and where it went, so a drill that finds a
    // window somewhere unexpected can see which work area it centred in.
    var l: [96]u8 = undefined;
    _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: placed y={d} h={d} content={d} work={d}+{d}", .{ wf.win_y, wf.win_h, content_h, wa.y, wa.h }) catch "gui: placed");
}

/// Children remain ordinary mshl data, shared by measurement and painting.
fn nodeChildren(rec: mshl.Record) []const Value {
    const c = rec.get("children") orelse return &.{};
    return if (c == .list) c.list else &.{};
}

fn nodeGap(rec: mshl.Record) usize {
    return @intCast(std.math.clamp(intField(rec, "gap", gap), 0, 64));
}

fn drawNode(node: Value, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
    const old_x0 = wf.clip_x0;
    const old_x1 = wf.clip_x1;
    wf.clip_x0 = @max(old_x0, x);
    wf.clip_x1 = @min(old_x1, x + avail_w);
    defer {
        wf.clip_x0 = old_x0;
        wf.clip_x1 = old_x1;
    }
    return layoutNode(node, x, y, avail_w, avail_h, true);
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
        if (std.mem.eql(u8, k, "grid")) return .grid;
        if (std.mem.eql(u8, k, "column") or nodeChildren(rec).len != 0) return .column;
        if (std.mem.eql(u8, k, "split")) return .split;
        return .leaf; // icon, breadcrumbs, label, button, toggle, field, list — or unknown (empty)
    }
    pub fn children(_: *MshlTree, n: Node) []const Node {
        return nodeChildren(n.record);
    }
    pub fn gap(_: *MshlTree, n: Node) usize {
        return nodeGap(n.record);
    }
    pub fn alignTop(_: *MshlTree, n: Node) bool {
        return n == .record and std.mem.eql(u8, strField(n.record, "align"), "top");
    }
    pub fn flex(_: *MshlTree, n: Node) usize {
        return flexWeight(n);
    }
    /// `grow: true` (or a weight): this child takes the column's spare
    /// height — a table that fills a maximized window.
    pub fn grow(_: *MshlTree, n: Node) usize {
        if (n != .record) return 0;
        const v = n.record.get("grow") orelse return 0;
        return switch (v) {
            .bool => |b| @intFromBool(b),
            .int => |i| @intCast(std.math.clamp(i, 0, 64)),
            else => 0,
        };
    }
    /// `align: "center" | "end"` on a child: where it sits when narrower
    /// than its track (a row's flex track, a column's width, a grid cell).
    pub fn alignOf(_: *MshlTree, n: Node) ui.layout.Align {
        if (n != .record) return .start;
        const a = strField(n.record, "align");
        if (std.mem.eql(u8, a, "center")) return .center;
        if (std.mem.eql(u8, a, "end")) return .end;
        return .start;
    }
    /// `{ kind: "grid", cols: 3 }` (equal tracks) or `cols: [1, 2]`
    /// (weights, like a row's flex): the column tracks a grid fills.
    pub fn gridTracks(_: *MshlTree, n: Node, buf: *[ui.layout.max_tracks]usize) []const usize {
        const v = n.record.get("cols") orelse return buf[0..0];
        switch (v) {
            .int => |count| {
                const c: usize = @intCast(std.math.clamp(count, 1, @as(i64, ui.layout.max_tracks)));
                @memset(buf[0..c], 1);
                return buf[0..c];
            },
            .list => |items| {
                var c: usize = 0;
                for (items) |item| {
                    if (c == buf.len) break;
                    buf[c] = if (item == .int) @intCast(std.math.clamp(item.int, 0, 64)) else 0;
                    c += 1;
                }
                return buf[0..c];
            },
            else => return buf[0..0],
        }
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
    pub fn leafMeasure(_: *MshlTree, n: Node, avail_w: usize, avail_h: usize) Size {
        return leafLayout(n.record, 0, 0, avail_w, avail_h, false);
    }
    pub fn leafPaint(_: *MshlTree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
        return leafLayout(n.record, x, y, avail_w, avail_h, true);
    }
    pub fn childPaint(_: *MshlTree, n: Node, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
        return drawNode(n, x, y, avail_w, avail_h);
    }
    pub fn viewportPaint(_: *MshlTree, n: Node, child: Node, x: usize, y: usize, w: usize, h: usize) Size {
        const id = strField(n.record, "id");
        if (id.len == 0 or id.len > 64) {
            limitHit("scroll id length", id);
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
/// `avail_h` is the height offered (0 = natural); see the engine.
fn layoutNode(node: Value, x: usize, y: usize, avail_w: usize, avail_h: usize, paint: bool) Size {
    return if (paint) Engine.paint(&mshl_tree, node, x, y, avail_w, avail_h) else Engine.measure(&mshl_tree, node, avail_w, avail_h);
}

/// A leaf's own size and paint: the widgets that own runtime state. A
/// list or a chart offered more height than its own takes the offer.
fn leafLayout(rec: mshl.Record, x: usize, y: usize, avail_w: usize, avail_h: usize, paint: bool) Size {
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
    if (std.mem.eql(u8, kind, "toggle") or std.mem.eql(u8, kind, "checkbox")) return layoutToggle(rec, x, y, avail_w, paint);
    if (std.mem.eql(u8, kind, "field")) {
        if (paint) return drawField(rec, x, y, avail_w);
        return .{ .w = avail_w, .h = lineOf(R_UI) + 2 * fpy + (if (strField(rec, "label").len > 0) lineOf(R_UI) + 6 else @as(usize, 0)) };
    }
    if (std.mem.eql(u8, kind, "list")) {
        if (paint) return drawList(rec, x, y, avail_w, avail_h);
        return .{ .w = avail_w, .h = listBoxHeight(rec, avail_h) };
    }
    if (std.mem.eql(u8, kind, "chart")) return layoutChart(rec, x, y, avail_w, avail_h, paint);
    if (std.mem.eql(u8, kind, "tabs")) return layoutTabs(rec, x, y, avail_w, paint);
    if (std.mem.eql(u8, kind, "meter")) return layoutMeter(rec, x, y, avail_w, paint);
    if (std.mem.eql(u8, kind, "page")) return layoutPage(rec, x, y, avail_w, avail_h, paint);
    return .{};
}

const max_tabs = 8;
const max_tab_strips = 4;
/// A painted tab strip, for the click that follows: its rect (surface-
/// local, with the scroll offset it was painted under) and its labels.
const TabHit = struct {
    id: []const u8,
    x: usize = 0,
    y: usize = 0,
    w: usize = 0,
    h: usize = 0,
    offset_y: isize = 0,
    items: [max_tabs]ui.paint.TabItem = undefined,
    n: usize = 0,
    state: ui.tabs.State = .{},
};
var tab_hits: [max_tab_strips]TabHit = undefined;
var ntabhit: usize = 0;

/// `{ kind: "tabs", id, items: ["A", "B"], selected }`: the toolkit's
/// tab strip (no close glyphs), one focusable. A click fires the list
/// event shape with `col` = the tab's index and `row` = its label; the
/// app keeps which tab is selected in its state. As the first child of
/// the window's root column with `bar: true`, the strip is chrome: flush
/// under the titlebar edge to edge, the padded body below it.
fn layoutTabs(rec: mshl.Record, x: usize, y: usize, avail_w: usize, paint: bool) Size {
    const h = ui.paint.controlHeight(wf.brush());
    if (!paint) return .{ .w = avail_w, .h = h };
    const id = strField(rec, "id");
    var hit: TabHit = .{ .id = id, .x = x, .y = y, .w = avail_w, .h = h, .offset_y = wf.draw_offset_y };
    if (rec.get("items")) |iv| if (iv == .list) for (iv.list) |item| {
        if (hit.n == max_tabs or item != .str) continue;
        hit.items[hit.n] = .{ .label = item.str, .closable = false };
        hit.n += 1;
    };
    const selected: usize = @intCast(std.math.clamp(intField(rec, "selected", 0), 0, @as(i64, @intCast(hit.n -| 1))));
    ui.paint.tabStrip(wf.brush(), .{ .x = x, .y = y, .w = avail_w, .h = h }, hit.items[0..hit.n], selected, &hit.state);
    if (ntabhit < max_tab_strips) {
        tab_hits[ntabhit] = hit;
        ntabhit += 1;
    } else {
        warn("tab strips; this one cannot be clicked", id);
    }
    if (nfoc < focusables.len) recordFocus(.{ .id = id, .is_field = false, .bx = x, .by = y, .bw = avail_w, .bh = h });
    return .{ .w = avail_w, .h = h };
}

/// The tab under a click in strip `id`, as (index, label), or null.
fn tabClick(id: []const u8, x: usize, screen_y: usize) ?struct { index: usize, label: []const u8 } {
    for (tab_hits[0..ntabhit]) |*th| {
        if (!std.mem.eql(u8, th.id, id)) continue;
        const y: usize = @intCast(@max(0, @as(isize, @intCast(screen_y)) - th.offset_y));
        switch (ui.paint.tabStripHit(wf.brush(), .{ .x = th.x, .y = th.y, .w = th.w, .h = th.h }, th.items[0..th.n], th.state, x, y)) {
            .select => |i| return .{ .index = i, .label = th.items[i].label },
            else => return null,
        }
    }
    return null;
}

/// The permille samples of a `values:` list, clamped to 0..1000.
fn sampleAt(values: Value, i: usize) usize {
    if (values != .list or i >= values.list.len or values.list[i] != .int) return 0;
    return @intCast(std.math.clamp(values.list[i].int, 0, 1000));
}
fn sampleCount(values: Value) usize {
    return if (values == .list) values.list.len else 0;
}

/// `{ kind: "chart", h, title, caption, values: [permille…] }`: a history
/// graph — newest sample at the right edge, a filled area under a line,
/// a light grid at quarters — with the title and the current reading
/// above it. The area a chart takes is its own: `h` tall, the width
/// offered. Loads over 80% paint in the danger colour, like a meter.
fn layoutChart(rec: mshl.Record, x: usize, y: usize, avail_w: usize, avail_h: usize, paint: bool) Size {
    const h: usize = @max(@as(usize, @intCast(std.math.clamp(intField(rec, "h", 100), 40, 400))), avail_h);
    const w = avail_w;
    if (!paint or w < 24) return .{ .w = w, .h = h };
    // The toolkit paints it; the samples are copied out of the script's list.
    const values = rec.get("values") orelse Value.nothing;
    var samples: [max_chart_samples]u16 = undefined;
    const n = @min(sampleCount(values), max_chart_samples);
    for (0..n) |i| samples[i] = @intCast(@min(sampleAt(values, i), 1000));
    ui.paint.chart(wf.brush(), .{ .x = x, .y = y, .w = w, .h = h }, strField(rec, "title"), strField(rec, "caption"), samples[0..n]);
    return .{ .w = w, .h = h };
}
/// Samples a chart keeps (the newest); Activity's histories are 60–120.
const max_chart_samples = 240;

/// `{ kind: "meter", label, value }` or `{ kind: "meter", labels: "C",
/// values: [permille…] }`: one bar per value, its label at the left and
/// its percentage at the right, the fill in the primary colour and in
/// the danger colour past 80%. Rows stack; each is a text line tall.
fn layoutMeter(rec: mshl.Record, x: usize, y: usize, avail_w: usize, paint: bool) Size {
    const row_h = ui.paint.meterRowHeight(wf.brush());
    const values = rec.get("values") orelse Value.nothing;
    const n = if (values == .list) @min(values.list.len, max_meters) else 1;
    const h = n * row_h;
    if (!paint or avail_w < 40) return .{ .w = avail_w, .h = h };
    // The rows as the toolkit sees them: a label (the prefix + index for a
    // list of values) and a permille reading.
    const prefix = strField(rec, "labels");
    var labels: [max_meters][16]u8 = undefined;
    var rows: [max_meters]ui.paint.Meter = undefined;
    for (0..n) |i| {
        const v: usize = if (values == .list) sampleAt(values, i) else @intCast(std.math.clamp(intField(rec, "value", 0), 0, 1000));
        const label = if (values == .list) (std.fmt.bufPrint(&labels[i], "{s}{d}", .{ prefix, i }) catch "") else strField(rec, "label");
        rows[i] = .{ .label = label, .value = @intCast(@min(v, 1000)) };
    }
    ui.paint.meters(wf.brush(), .{ .x = x, .y = y, .w = avail_w, .h = h }, rows[0..n], content_bg);
    return .{ .w = avail_w, .h = h };
}
/// Meter rows a widget stacks (one per core; the machine has few).
const max_meters = 64;

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

/// A button's icon: `icon: "name"` from the catalog, `icon_only: true`
/// to drop the label (the label still names the button for a drill).
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
    last_seen: u32 = 0,
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
            c.last_seen = render_serial;
            return c;
        }
        if (c.id_len == 0 and empty == null) empty = c;
    }
    if (empty == null) if (evictable(Crumb, &crumbs)) |e| {
        logEvict("breadcrumbs", e.id[0..e.id_len], id);
        empty = e;
    };
    const c = empty orelse return null;
    c.* = .{ .last_seen = render_serial };
    @memcpy(c.id[0..id.len], id);
    c.id_len = id.len;
    @memcpy(c.path[0..path.len], path);
    c.path_len = path.len;
    return c;
}
/// The trail's labels for the toolkit's breadcrumb painter: each ancestor
/// of the path, the view's root first.
fn crumbLabels(model: ui.breadcrumbs.Model, root: []const u8, out: *[max_crumb_parts][]const u8) []const []const u8 {
    const n = @min(model.count, max_crumb_parts);
    for (0..n) |i| out[i] = model.at(i, root).?.label;
    return out[0..n];
}
const max_crumb_parts = 32;
fn layoutBreadcrumb(rec: mshl.Record, x: usize, y: usize, width: usize, paint: bool) Size {
    if (width == 0) return .{};
    const path = strField(rec, "path");
    const model = ui.breadcrumbs.Model.init(path) orelse return layoutLabel(rec, x, y, width, paint);
    const root = strField(rec, "root");
    const state = if (paint) crumbFor(strField(rec, "id"), path) else null;
    if (paint and state == null) {
        limitHit("breadcrumbs", strField(rec, "id"));
        return .{};
    }
    if (state) |c| {
        c.root = root;
        c.can_lock = if (rec.get("can_lock")) |v| v.asBool() else false;
        c.can_leave = if (rec.get("can_leave")) |v| v.asBool() else false;
        c.selected = @min(c.selected, model.count -| 2);
        if (files_bindings.location.is(strField(rec, "id"))) file_crumb = c;
    }
    var buf: [max_crumb_parts][]const u8 = undefined;
    const labels = crumbLabels(model, root, &buf);
    const b = wf.brush();
    // Measure by placing the last crumb (the painter and the hit test use
    // the same flow); paint through the toolkit when asked.
    const last = ui.paint.crumbPlace(b, width, labels, labels.len -| 1);
    const h = last.y + ui.paint.crumbHeight(b);
    if (paint) {
        const c = state.?;
        const focused = wf.win_focused and nfoc == sel_focus;
        _ = ui.paint.breadcrumbs(b, .{ .x = x, .y = y, .w = width, .h = h }, labels, if (focused) c.selected else null, content_bg);
        if (model.count > 1) recordFocus(.{ .id = strField(rec, "id"), .is_field = false, .crumb = state, .bx = x, .by = y, .bw = width, .bh = h });
    }
    return .{ .w = width, .h = h };
}
fn crumbHit(f: Focus, x: usize, y: usize) ?usize {
    const c = f.crumb orelse return null;
    const model = c.model();
    const yy = @as(isize, @intCast(y)) - f.sy;
    if (x < f.bx or yy < 0) return null;
    var buf: [max_crumb_parts][]const u8 = undefined;
    const labels = crumbLabels(model, c.root, &buf);
    return ui.paint.breadcrumbHit(wf.brush(), f.bw, labels, x - f.bx, @intCast(yy));
}

fn drawButton(rec: mshl.Record, x: usize, y: usize, avail_w: usize) Size {
    const variant = strField(rec, "variant");
    const disabled = if (rec.get("disabled")) |v| v.asBool() else false;
    const focused = !disabled and wf.win_focused and nfoc == sel_focus;
    const w = @min(avail_w, iconLabelWidth(rec, "label") + 2 * bpx);
    const h = @max(lineOf(R_UI), wf.iconSize()) + 2 * bpy;
    // The toolkit paints it (lib/ui/paint.zig); this is the binding: the
    // record's fields and the runtime's focus/hover/press state as a style.
    ui.paint.button(wf.brush(), .{ .x = x, .y = y, .w = w, .h = h }, if (iconOnly(rec)) "" else strField(rec, "label"), ui.icons.parse(strField(rec, "icon")), .{
        .focused = focused,
        .primary = std.mem.eql(u8, variant, "primary"),
        .danger = std.mem.eql(u8, variant, "danger"),
        .disabled = disabled,
        .hovered = !disabled and hovered == nfoc,
        .pressed = !disabled and pressed == nfoc,
    });
    if (!disabled and nfoc < focusables.len) {
        recordFocus(.{ .id = strField(rec, "id"), .is_field = false, .is_button = true, .bx = x, .by = y, .bw = w, .bh = h });
    }
    return .{ .w = w, .h = h };
}

/// `{ kind: "toggle" | "checkbox", id, label, on, disabled }`: a switch
/// (or a box) whose state the app owns — a click, Enter or Space fires
/// `{ id }` and the app flips `on` in its state. The runtime keeps no
/// toggle state, so the view is the whole truth of the control, and the
/// same tree renders on a remote viewer unchanged.
fn layoutToggle(rec: mshl.Record, x: usize, y: usize, avail_w: usize, paint: bool) Size {
    const check = std.mem.eql(u8, strField(rec, "kind"), "checkbox");
    const label = strField(rec, "label");
    const size = ui.paint.toggleSize(wf.brush(), label, check);
    const w = @min(avail_w, size.w);
    if (!paint) return .{ .w = w, .h = size.h };
    const disabled = if (rec.get("disabled")) |v| v.asBool() else false;
    const is_on = if (rec.get("on")) |v| v.asBool() else false;
    const focused = !disabled and wf.win_focused and nfoc == sel_focus;
    ui.paint.toggle(wf.brush(), .{ .x = x, .y = y, .w = w, .h = size.h }, label, .{
        .on = is_on,
        .focused = focused,
        .hovered = !disabled and hovered == nfoc,
        .disabled = disabled,
        .check = check,
        .ground = content_bg,
    });
    if (!disabled) recordFocus(.{ .id = strField(rec, "id"), .is_field = false, .is_toggle = true, .bx = x, .by = y, .bw = w, .bh = size.h });
    return .{ .w = w, .h = size.h };
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
        // `submit: "go"`: Enter in the field presses that button.
        recordFocus(.{ .id = id, .is_field = true, .submit = strField(rec, "submit"), .bx = x, .by = yy, .bw = avail_w, .bh = bh });
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
    /// The column header above the rows: its height and each column's
    /// right edge (surface-local), so a header click can name a column.
    header_h: usize = 0,
    col_edge: [max_list_cols]usize = @splat(0),
    ncols: usize = 0,
    st: *ListState = undefined,
};
const max_list_cols = 8;
var list_hits: [max_lists]ListHit = undefined;
var nlisthit: usize = 0;

const list_row_vpad = ui.paint.list_row_vpad; // vertical padding within a list row
const list_cell_pad = ui.paint.list_cell_pad; // left inset of the first cell

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
/// (viewport height in px; with `auto` the most it may take, the box
/// sizing itself to its rows), optional `cols` [{title, w, right?}] for a
/// header + column layout, and `rows` [{id, cells:[str | [int…]], icon?}]
/// (a cell that is a list of permille samples draws as a sparkline); `tail`
/// keeps the newest row in view as rows arrive. `fit`
/// treats column widths as weights; `empty` supplies a placeholder and
/// `active` controls selection highlighting. The runtime owns
/// the scroll offset and selection (see `ListState`); the app just emits
/// the rows. Registers one focusable (the whole list), so its rows never
/// eat the focusable budget.
/// The height a list takes: `h` (or the offer, if taller); with `auto:
/// true` the box sizes itself to its rows (at least one, for the
/// placeholder) and `h` is the most it may take — a short table that must
/// show every row, whatever the text scale, with no scrollbar hiding the
/// second one. Measure and paint share it, so the layout reserves what
/// is drawn.
fn listBoxHeight(rec: mshl.Record, avail_h: usize) usize {
    const h_field: usize = @intCast(@max(intField(rec, "h", 240), 40));
    const auto = if (rec.get("auto")) |v| v.asBool() else false;
    if (!auto) return @max(h_field, avail_h);
    const line = lineOf(R_UI);
    const row_h = line + 2 * list_row_vpad;
    const has_cols = if (rec.get("cols")) |cv| cv == .list and cv.list.len > 0 else false;
    const header_h: usize = if (has_cols) row_h else 0;
    const nrows = rowsLen(rec.get("rows") orelse Value.nothing);
    return @max(@min(header_h + @max(nrows, 1) * row_h + pal.border_w, h_field), avail_h);
}

fn drawList(rec: mshl.Record, x: usize, y: usize, avail_w: usize, avail_h: usize) Size {
    const id = strField(rec, "id");
    const key = strField(rec, "key");
    const rowsv: Value = rec.get("rows") orelse Value.nothing;
    const nrows = rowsLen(rowsv);
    const colsv: []const Value = if (rec.get("cols")) |cv| (if (cv == .list) cv.list else &.{}) else &.{};
    const w = avail_w;
    const b = wf.brush();
    const row_h = ui.paint.listRowHeight(b);
    const header_h: usize = if (colsv.len > 0) row_h else 0;
    const box_h = listBoxHeight(rec, avail_h);

    const focused = wf.win_focused and nfoc == sel_focus;
    const active = if (rec.get("active")) |v| v.asBool() else true;
    const fit = if (rec.get("fit")) |v| v.asBool() else false;
    // The columns as the toolkit sees them: title, weight, alignment —
    // and their pixel widths, which the header click needs as edges.
    var cols: [max_list_cols]ui.paint.Column = undefined;
    var ncols: usize = 0;
    for (colsv) |cv| {
        if (cv != .record or ncols == max_list_cols) continue;
        cols[ncols] = .{ .title = strField(cv.record, "title"), .weight = @intCast(std.math.clamp(intField(cv.record, "w", 80), 1, 4096)), .right = if (cv.record.get("right")) |v| v.asBool() else false };
        ncols += 1;
    }
    var widths: [max_list_cols]usize = undefined;
    const tracks_w = w -| (2 * list_cell_pad + 8);
    ui.paint.columnWidths(cols[0..ncols], fit, tracks_w, widths[0..ncols]);
    panel(x, y, w, box_h, r_field, pal.field_bg, if (focused) pal.focus else pal.border, if (focused) pal.focus_w else pal.border_w);

    var col_edge: [max_list_cols]usize = @splat(0);
    if (ncols > 0) {
        const sort_col: ?usize = if (rec.get("sort")) |sv| (if (sv == .int and sv.int >= 0) @intCast(sv.int) else null) else null;
        ui.paint.listHeader(b, .{ .x = x + pal.border_w, .y = y, .w = w -| (2 * pal.border_w), .h = header_h + pal.border_w }, cols[0..ncols], widths[0..ncols], sort_col, pal.field_bg);
        var hx = x + list_cell_pad;
        for (0..ncols) |ci| {
            hx += widths[ci];
            col_edge[ci] = hx;
        }
    }

    const rows_top = y + header_h;
    const inner_h = if (box_h > header_h + pal.border_w) box_h - header_h - pal.border_w else 0;
    var vis = inner_h / row_h;
    if (vis == 0) vis = 1;

    const st = listFor(id, key);
    const rows_before = st.nrows;
    st.nrows = nrows;
    st.vis = vis;
    // `selected: ID` pins the selection to a row by its id, so a list
    // whose rows reorder between renders (a live table sorted by CPU)
    // keeps the highlight on the same item, not the same index.
    if (rec.get("selected")) |sv| if (sv == .str and sv.str.len > 0) {
        var i: usize = 0;
        while (i < nrows) : (i += 1) {
            const idv = rowField(rowsv, i, "id");
            if (idv == .str and std.mem.eql(u8, idv.str, sv.str)) {
                st.sel = i;
                break;
            }
        }
    };
    if (nrows == 0) st.sel = 0 else if (st.sel >= nrows) st.sel = nrows - 1;
    // Only clamp the scroll to the last page here; following the selection
    // into view is done when the selection *moves* (a click or arrow key),
    // so a free scroll (the scrollbar) is not undone by a stale selection.
    const max_scroll = if (nrows > vis) nrows - vis else 0;
    // `tail: true`: a list that follows its end — a log — scrolls to the
    // newest row whenever rows arrive; between arrivals it scrolls freely.
    const tail = if (rec.get("tail")) |v| v.asBool() else false;
    if (tail and nrows != rows_before) st.scroll = max_scroll;
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
        const iconv = rowField(rowsv, i, "icon");
        const icon = if (iconv == .str) ui.icons.parse(iconv.str) else null;
        // The row's cells as the toolkit sees them: text, or a sparkline's
        // permille samples copied out of the script's list.
        const cellsv = rowField(rowsv, i, "cells");
        var cells: [max_list_cols]ui.paint.Cell = undefined;
        var samples: [max_list_cols][max_samples]u16 = undefined;
        const ncells = if (ncols == 0) 1 else ncols;
        for (0..ncells) |ci| {
            if (cellsv == .list and ci < cellsv.list.len and cellsv.list[ci] == .list) {
                const n = @min(sampleCount(cellsv.list[ci]), max_samples);
                for (0..n) |si| samples[ci][si] = @intCast(@min(sampleAt(cellsv.list[ci], si), 1000));
                cells[ci] = .{ .samples = samples[ci][0..n] };
            } else cells[ci] = .{ .text = cellAt(cellsv, ci) };
        }
        ui.paint.listRow(wf.brush(), .{ .x = x + pal.border_w, .y = ry, .w = rows_w, .h = row_h }, cols[0..ncols], widths[0..ncols], cells[0..ncells], .{ .selected = selected, .focused = focused, .icon = icon, .ground = pal.field_bg });
        ry += row_h;
    }
    wf.clip_x0 = sx0;
    wf.clip_y0 = sy0;
    wf.clip_x1 = sx1;
    wf.clip_y1 = sy1;

    // Scrollbar: a track and a proportional thumb on the right edge.
    if (has_sb) ui.paint.listScrollbar(wf.brush(), .{ .x = x + w - sb_w - pal.border_w, .y = rows_top, .w = sb_w, .h = inner_h }, vis, nrows, st.scroll, pal.field_bg);

    if (nlisthit < list_hits.len) {
        const sb_x = if (has_sb) x + w - sb_w / 2 - pal.border_w else 0;
        list_hits[nlisthit] = .{ .id = id, .x = x, .rows_top = rows_top, .offset_y = wf.draw_offset_y, .rows_w = rows_w, .row_h = row_h, .sb_x = sb_x, .header_h = header_h, .col_edge = col_edge, .ncols = ncols, .st = st };
        nlisthit += 1;
    }
    if (nfoc < focusables.len) {
        recordFocus(.{ .id = id, .is_field = false, .is_list = true, .bx = x, .by = y, .bw = w, .bh = box_h });
    }
    return .{ .w = w, .h = box_h };
}
/// Samples a sparkline cell keeps (the newest; the History column keeps 60).
const max_samples = 120;

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

const ListClick = struct { fire: bool = false, activated: bool = false, row: usize = 0, header: ?usize = null };

/// Route a click at (x, y) inside the list `id`: a row click moves the
/// selection (a reclick on the same row activates it); a scrollbar-track
/// click pages; a column-header click fires with that column (`header`)
/// and no row — the app decides what a column click means (a sort).
/// Returns whether to fire a list event and for which row.
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
        if (y < lh.rows_top) {
            if (lh.ncols == 0 or y < lh.rows_top -| lh.header_h) return .{};
            var ci: usize = 0;
            while (ci < lh.ncols) : (ci += 1) if (x < lh.col_edge[ci]) break;
            if (ci == lh.ncols) return .{};
            return .{ .fire = true, .header = ci };
        }
        const row = st.scroll + (y - lh.rows_top) / lh.row_h;
        if (row >= st.nrows) return .{};
        const now_ms = usys.nowMs();
        const prev_row = st.click.row();
        const prev_at = st.click.atMs();
        const activated = st.click.press(row, now_ms);
        // One line per click, so a drill can see why a double-click did or
        // did not activate (the two clocks, the two rows).
        var cl: [96]u8 = undefined;
        _ = usys.log(log_h, std.fmt.bufPrint(&cl, "gui: click {s} row={d} now={d} prev_row={?} prev_at={d} activated={}", .{ id, row, now_ms, prev_row, prev_at, activated }) catch "gui: click");
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
/// The event for a list: `{ id, row, activated, col }` — `row` the
/// selected row's id and `activated` whether it was opened (Enter, a
/// reclick); or, for a column-header click, `row` empty and `col` the
/// column's index (-1 otherwise).
fn mkListEvent(it: *mshl.Interp, id: []const u8, row: []const u8, activated: bool, col: ?usize) mshl.Error!Value {
    const keys = try it.arena.alloc([]const u8, 4);
    keys[0] = "id";
    keys[1] = "row";
    keys[2] = "activated";
    keys[3] = "col";
    const vals = try it.arena.alloc(Value, 4);
    vals[0] = .{ .str = try it.arena.dupe(u8, id) };
    vals[1] = .{ .str = try it.arena.dupe(u8, row) };
    vals[2] = .{ .bool = activated };
    vals[3] = .{ .int = if (col) |c| @intCast(c) else -1 };
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
    if (std.mem.eql(u8, name, "page-info")) {
        if (args.len < 1 or args[0] != .str) return it.fail("page-info: a page id is needed", .{});
        var used: i64 = 0;
        var limit: i64 = 0;
        var alive = false;
        var node: i64 = 0;
        var exit: i64 = 0;
        if (guipage.slotById(args[0].str)) |s| {
            const inf = guipage.info(s);
            used = @intCast(inf.used_kb);
            limit = @intCast(inf.limit_kb);
            alive = inf.alive;
            node = @intCast(inf.node);
            exit = @intCast(inf.exit);
        }
        const keys = try it.arena.dupe([]const u8, &.{ "alive", "used_kb", "limit_kb", "node", "exit" });
        const vals = try it.arena.dupe(Value, &.{ .{ .bool = alive }, .{ .int = used }, .{ .int = limit }, .{ .int = node }, .{ .int = exit } });
        return .{ .record = .{ .keys = keys, .vals = vals } };
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
        // Chrome re-declares its struts on its next wake; give it one now.
        if (output_control != 0) _ = usys.callTyped(shared.GpuReq, shared.GpuResp, output_control, .appearance_changed, 0);
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
    if (std.mem.eql(u8, name, "restore-window")) return windowByTitle(it, name, args, wf.display, .restore);
    // A toggle can hide: the display control endpoint, the desktop's own.
    if (std.mem.eql(u8, name, "toggle-window")) return windowByTitle(it, name, args, output_control, .toggle);
    if (std.mem.eql(u8, name, "quit-window")) {
        if (output_control == 0) return it.fail("quit-window: this program holds no display control", .{});
        if (args.len == 0 or args[0] != .str) return it.fail("quit-window: a window title expected", .{});
        const w = shared.strToWords(args[0].str);
        const why: []const u8 = switch (usys.callTyped(shared.GpuReq, shared.GpuResp, output_control, .{ .close_titled = .{ .a = w[0], .b = w[1] } }, 0)) {
            .ok => |r| switch (r) {
                .ok => "",
                .gpu_err => |e| switch (e.code) {
                    14 => "not running",
                    22 => "already asked",
                    else => "not allowed",
                },
                else => "not allowed",
            },
            .err => "no display",
        };
        var l: [64]u8 = undefined;
        _ = usys.log(log_h, std.fmt.bufPrint(&l, "activity: quit {s} ok={}", .{ args[0].str, why.len == 0 }) catch "activity: quit");
        return if (why.len == 0)
            try it.mkResult(true, .{ .str = try it.arena.dupe(u8, args[0].str) })
        else
            try it.mkResult(false, .{ .str = why });
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
    const app_tick_ms = wf.tick_ms;
    page_it = it;
    defer page_it = null;
    defer guipage.reapAll();
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
    _ = wf.refreshAppearance(); // resolve the palette from the system/user settings
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
    var menu_profile: shared.menus.Profile = if (buildCustomMenus(spec)) .custom else if (std.mem.eql(u8, strField(spec, "menus"), "files")) .files else .generic;
    loadBindings(spec);

    var focus: usize = 0;
    var focus_id: [64]u8 = undefined;
    var focus_len: usize = 0;
    var action_id: [64]u8 = undefined;
    var action_len: usize = 0;
    var minimized = false; // the amber dot hid us; a restore event brings us back
    var announced = false;
    var announced_layout: u64 = 0;
    var relog_geom = false; // a resize moved the traffic lights; re-log them
    // The current view tree: the initial view of the initial state, then
    // recomputed after each fired event — locally (update then view) or,
    // for a `node: N` app, on that node in one round trip.
    var tree: Value = if (remote_node != 0)
        (try stepRemote(it, &state, Value.nothing, false)) orelse
            return it.fail("gui: the remote app did not answer", .{})
    else
        try it.callValue(view, &.{state}, null, null);
    // A view that carries its menus makes the window a custom-menu one
    // even when the spec declared none.
    if (menu_profile == .generic and rootMenus(tree) != null) menu_profile = .custom;
    // A checkpoint copies state and tree out of scratch and resets it — the
    // right thing after an evaluation, and pure waste after a hover or a
    // drag that evaluated nothing (peak 2x of the tree in a 512 KiB pool,
    // on every pointer move). Only turns that ran script code pay it.
    var evaluated = true;
    // Where the focus was when a dialog opened, to hand it back on close.
    var dialog_was = false;
    var dialog_return: [64]u8 = undefined;
    var dialog_return_len: usize = 0;
    while (true) {
        if (evaluated) {
            // Snapshot live state before discarding callback scratch allocations.
            try epoch.checkpoint(&state, &tree);
            notePool(action_id[0..action_len]);
            evaluated = false;
        }
        var nfocus = renderTree(tree, title, focus);
        // A dialog opening takes the focus to its first control and
        // remembers where it was; closing hands it back to that widget.
        if (dialog_shown and !dialog_was) {
            dialog_return_len = focus_len;
            @memcpy(dialog_return[0..focus_len], focus_id[0..focus_len]);
            focus = 0;
            focus_len = 0;
            nfocus = renderTree(tree, title, focus);
        } else if (!dialog_shown and dialog_was) {
            focus_len = dialog_return_len;
            @memcpy(focus_id[0..focus_len], dialog_return[0..focus_len]);
            focus = 0;
            nfocus = renderTree(tree, title, focus);
        } else if (focus >= nfocus) {
            focus = 0; // the focused widget left the view
            nfocus = renderTree(tree, title, focus);
        }
        dialog_was = dialog_shown;
        // With a page alive the loop ticks fast: its commits are blitted
        // and its events delivered from the tick.
        wf.tick_ms = if (guipage.live()) (if (app_tick_ms == 0) page_tick_ms else @min(app_tick_ms, page_tick_ms)) else app_tick_ms;
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
            if (menu_profile == .custom) {
                followViewMenus(tree);
                publishCustomMenus();
                enabled &= ~custom_menus.disabled;
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
        if (layout_overflow) return it.fail("gui: a widget limit was hit; the log names it", .{});
        if (nfocus > 0 and focus >= nfocus) {
            focus = nfocus - 1;
            nfocus = renderTree(tree, title, focus);
        }
        if (!wf.commitSurface()) return it.fail("gui: commit failed", .{});
        if (!announced or action_len > 0) {
            for (focusables[0..nfocus]) |f| if (f.crumb) |c| {
                const model = c.model();
                var buf: [max_crumb_parts][]const u8 = undefined;
                const labels = crumbLabels(model, c.root, &buf);
                const crumb_h = ui.paint.crumbHeight(wf.brush());
                for (0..labels.len) |index| {
                    const last = index + 1 == labels.len;
                    const place = ui.paint.crumbPlace(wf.brush(), f.bw, labels, index);
                    if (last) continue;
                    const sy = f.sy + @as(isize, @intCast(place.y + crumb_h / 2));
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
        // The widgets change with the state (a confirm step's buttons appear
        // when it opens): announce the set again whenever it differs from
        // the last announced one, so a host finds the new buttons' centres.
        var layout_hash: u64 = 0xcbf29ce484222325;
        for (0..nfocus) |i| {
            const f = focusables[i];
            for (f.id) |c| layout_hash = (layout_hash ^ c) *% 0x100000001b3;
            layout_hash = (layout_hash ^ (f.bx + f.by * 7919 + f.bw * 104729)) *% 0x100000001b3;
        }
        if (!announced or layout_hash != announced_layout) {
            announced_layout = layout_hash;
            if (!announced) _ = usys.log(log_h, "gui: ready");
            // Log each focusable widget's clickable centre in scanout
            // coordinates, so a host driving the pointer can click it.
            for (0..nfocus) |i| {
                const f = focusables[i];
                var l: [96]u8 = undefined;
                _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: widget {s} at {d},{d}", .{ f.id, wf.win_x + f.bx + f.bw / 2, wf.win_y + f.by + f.bh / 2 }) catch continue);
            }
            // Each tab strip's tabs, by index, for the same host.
            for (tab_hits[0..ntabhit]) |*th| {
                for (0..th.n) |i| {
                    const span = ui.paint.tabSpan(wf.brush(), .{ .x = th.x, .y = th.y, .w = th.w, .h = th.h }, th.items[0..th.n], th.state, i) orelse continue;
                    var l: [96]u8 = undefined;
                    _ = usys.log(log_h, std.fmt.bufPrint(&l, "gui: tab {s} {d} at {d},{d}", .{ th.id, i, wf.win_x + th.x + span.x + span.w / 2, wf.win_y + th.y + th.h / 2 }) catch continue);
                }
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
        var fired_col: ?usize = null; // a column-header click, by index
        var fired_page: ?guipage.Event = null;
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
            // The dock hid this window (its pill, clicked while focused):
            // park as after the amber dot until a restore.
            if (ev.kind == 5) {
                minimized = true;
                _ = usys.log(log_h, "gui: minimized");
                continue :input;
            }
            // A timer tick: re-render so a `view` reading the time updates
            // — but never mid-drag (a ticking clock must not drop a drag),
            // and never while minimized (nothing is on screen to update).
            if (ev.kind == 2) {
                guipage.tick();
                // A page's news first: an event for `update`, or a fresh
                // commit to blit.
                if (guipage.take()) |pe| {
                    fired_page = pe;
                    fired = pe.idText();
                    break :input;
                }
                if (guipage.dirty() and !minimized and !wf.dragging) break :input;
                // The appearance tick reaches every parked window: a theme
                // or contrast change repaints an open window live, not
                // when it is next opened.
                if (wf.refreshAppearance()) {
                    hovered = null;
                    pressed = null;
                    break :input;
                }
                if (app_tick_ms == 0) continue :input;
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
                if (wheel != 0 and dialog_shown) continue :input; // the body is behind a sheet
                if (wheel != 0) {
                    if (hitWidget(nfocus, ev.x, ev.y)) |wi| if (focusables[wi].is_page) {
                        guipage.scroll(pageOf(focusables[wi]), -@as(i64, wheel) * 3 * @as(i64, @intCast(lineOf(R_UI))));
                        continue :input;
                    };
                    if (hitWidget(nfocus, ev.x, ev.y)) |wi| if (focusables[wi].is_list) {
                        if (listStateById(focusables[wi].id)) |list| {
                            const old = list.scroll;
                            list.scroll = @intCast(std.math.clamp(@as(isize, @intCast(old)) - @as(isize, wheel) * 3, 0, @as(isize, @intCast(list.nrows -| list.vis))));
                            if (list.scroll != old) break :input;
                        }
                    };
                    if (ev.y >= wf.title_h + tabbar_h + pad and ev.y < wf.win_h -| pad and ev.x >= pad and ev.x < wf.win_w -| pad and scrollStep(scrollAt(ev.x, ev.y), -@as(isize, wheel) * @as(isize, @intCast(lineOf(R_UI) * 3)))) {
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
                if (hovered) |wi| if (focusables[wi].is_page and ev.btn & 1 == 0 and pressed == null) {
                    const f = focusables[wi];
                    guipage.pointer(pageOf(f), .move, @intCast(ev.x - f.bx), @intCast(@as(isize, @intCast(ev.y)) - f.sy));
                    continue :input; // the page's own hover is its news
                };
                // A drag that began on a page: its moves are the page's (a
                // selection), wherever the pointer is now.
                if (pressed) |pw| if (pw < nfocus and focusables[pw].is_page and ev.btn & 1 != 0) {
                    const f = focusables[pw];
                    const rx: i64 = @as(i64, @intCast(ev.x)) - @as(i64, @intCast(f.bx));
                    const ry: i64 = @as(i64, @intCast(ev.y)) - @as(i64, @intCast(f.sy));
                    guipage.pointer(pageOf(f), .move, @intCast(@max(0, rx)), @intCast(@max(0, ry)));
                    continue :input;
                };
                const pointer = wf.onPointer(ev, title);
                if (pressed) |wi| {
                    if (ev.btn & 1 == 0) {
                        pressed = null;
                        if (hovered == wi and wi < nfocus) {
                            const f = focusables[wi];
                            if (f.is_page) {
                                guipage.pointer(pageOf(f), .up, @intCast(ev.x - f.bx), @intCast(@as(isize, @intCast(ev.y)) - f.sy));
                            } else if (f.crumb) |c| {
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
                            if (tabClick(focusables[wi].id, cev.x, cev.y)) |tc| {
                                fired = focusables[wi].id;
                                fired_list = true;
                                fired_row = tc.label;
                                fired_col = tc.index;
                                break :input;
                            }
                            if (focusables[wi].is_list) {
                                const lc = listClick(focusables[wi].id, cev.x, cev.y);
                                if (lc.fire) {
                                    fired = focusables[wi].id;
                                    fired_list = true;
                                    fired_row = if (lc.header != null) "" else listRowId(tree, focusables[wi].id, lc.row);
                                    fired_activated = lc.activated;
                                    fired_col = lc.header;
                                }
                                break :input; // re-render (selection or scroll moved)
                            }
                            if (focusables[wi].is_page) {
                                const f = focusables[wi];
                                guipage.pointer(pageOf(f), .down, @intCast(cev.x - f.bx), @intCast(@as(isize, @intCast(cev.y)) - f.sy));
                                pressed = wi;
                                break :input;
                            }
                            if (!focusables[wi].is_field) {
                                pressed = wi;
                                break :input;
                            }
                            // Place the caret using the same font metrics as rendering;
                            // a repeated click widens the selection.
                            fieldClick(focusables[wi], cev.x, false);
                            const clicks = field_clicks.press(wi, usys.nowMs());
                            if (clicks >= 2) {
                                const ed = &fieldFor(focusables[wi].id, "").edit;
                                if (clicks == 2) ed.selectWordAt(ed.cursor) else ed.selectLine();
                                var lb: [128]u8 = undefined;
                                _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: field {s} click {d} selected {d}..{d}", .{ focusables[wi].id, clicks, ed.low(), ed.high() }) catch "gui: field clicks");
                            }
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
            // An application key from the bar: the custom menu item it names
            // fires its event id, like a button press.
            if (menu_profile == .custom) if (shared.menus.appItemIndex(ch)) |i| {
                if (i < custom_menus.nitems and custom_menus.items[i].id_len > 0 and (custom_menus.disabled & shared.menus.bit(ch)) == 0) {
                    fired = custom_menus.items[i].id[0..custom_menus.items[i].id_len];
                    var lb: [96]u8 = undefined;
                    _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: menu item {s}", .{fired.?}) catch "gui: menu item");
                }
                break :input;
            };
            // A chord a custom item names as its shortcut (Cmd S for an
            // "Apply" item): the hint is the truth, the chord fires it.
            if (menu_profile == .custom and ch != 0) for (custom_menus.items[0..custom_menus.nitems]) |item| {
                if (item.chord == ch and item.id_len > 0 and (custom_menus.disabled & shared.menus.bit(item.key)) == 0) {
                    fired = item.id[0..item.id_len];
                    var lb: [96]u8 = undefined;
                    _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: shortcut {s}", .{fired.?}) catch "gui: shortcut");
                    break :input;
                }
            };
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
            if (ch == 27 and dialog_cancel_len > 0) {
                fired = dialog_cancel[0..dialog_cancel_len]; // Escape: the dialog's way out
                break :input;
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
            // A focused page takes printable keys, editing keys, the arrows
            // and Tab (its own links and fields); Escape hands focus back to
            // the chrome, and Copy takes the page's selection.
            if (cur) |c| if (c.is_page) {
                if (ch == 27) {
                    focus = 0;
                    reveal_focus = true;
                    break :input;
                }
                if (ch == shared.keyboard.copy) {
                    const sel = guipage.selectionOf(pageOf(c));
                    if (sel.len > 0) _ = @import("clipboard.zig").set(sel);
                    continue :input;
                }
                if ((ch >= 0x20 and ch != 0x7f) or ch == key_up or ch == key_down or ch == 0x1e or ch == 0x1f or ch == '\n' or ch == '\t' or ch == shared.keyboard.back_tab or ch == 8 or ch == 0x7f or ch == shared.keyboard.home or ch == shared.keyboard.end) {
                    guipage.key(pageOf(c), ch);
                    continue :input;
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
                        if (c.is_field and c.submit.len > 0) {
                            fired = c.submit; // Enter submits the field's button
                        } else if (c.is_field) {
                            // Enter in a form submits it: the next button after the
                            // field in focus order (wrapping), as `submit:` would name
                            // it; a form with no button advances the focus instead.
                            var k: usize = 1;
                            while (k < nfocus) : (k += 1) {
                                const cand = focusables[(focus + k) % nfocus];
                                if (cand.is_button) break;
                            }
                            if (k < nfocus) {
                                const button = focusables[(focus + k) % nfocus].id;
                                fired = button;
                                var lb: [128]u8 = undefined;
                                _ = usys.log(log_h, std.fmt.bufPrint(&lb, "gui: enter in {s} submits {s}", .{ c.id, button }) catch "gui: enter submits");
                            } else {
                                reveal_focus = true;
                                focus = (focus + 1) % nfocus; // advance past a field
                            }
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
                ' ' => {
                    // Space flips a toggle or presses a button, as a hand expects.
                    if (cur) |c| if (c.is_toggle or c.is_button) {
                        fired = c.id;
                        break :input;
                    };
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
            const ev = if (fired_page) |pe| try mkPageEvent(it, pe) else if (fired_list) try mkListEvent(it, id, fired_row, fired_activated, fired_col) else try mkEvent(it, id);
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
