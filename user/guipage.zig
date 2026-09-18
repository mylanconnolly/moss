//! The `page` leaf's machinery for the GUI runtime: page domains as
//! declarative widgets. A `{ kind: "page", id, url, nav, visible }`
//! leaf in the view tree spawns a page domain the first time its id
//! is seen, navigates it when `url` (or the `nav` nonce) changes,
//! gives it a viewport-sized pixel buffer while it is visible and
//! takes it back when it is not, and reaps the domain when the leaf
//! is gone from the tree — lifetime is the tree's, like a scroll slot,
//! so a closed tab is a dead domain and the window's exit takes every
//! page with it. The runtime blits the page's pixels inside the leaf's
//! rect and nowhere else, and routes the pointer, wheel and keys inside
//! that rect to the page.
//!
//! The pages are served on a thread of their own, since the GUI loop
//! blocks on the compositor; what the pages report (title, url, load,
//! hover, a death) queues here and the loop, ticking, turns each into a
//! coarse event for the app's `update`.
const std = @import("std");
const shared = @import("shared");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const usys = @import("usys.zig");
const webhost = @import("webhost.zig");
const progload = @import("progload.zig");
const loader = @import("loader.zig");
const fscmds = @import("fscmds.zig");
const netcmds = @import("netcmds.zig");
const wire = shared.web;

pub const max_slots = webhost.max_pages;

pub const Slot = struct {
    used: bool = false,
    seen: bool = false,
    id: [64]u8 = undefined,
    id_len: usize = 0,
    page: webhost.PageId = 0,
    /// The URL last commanded, and the `nav` nonce it was commanded under.
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    nav: i64 = 0,
    loaded_once: bool = false,
    /// The viewport the page was last given (0 × 0 hidden).
    w: u32 = 0,
    h: u32 = 0,
    /// The rect it was painted at this render (surface-local, and the
    /// screen row of its top), for routing input.
    x: usize = 0,
    y: usize = 0,
    sy: isize = 0,
    /// The page's commit count at the last blit: a newer one is dirty.
    blitted: usize = 0,
    logged_x: usize = 0,
    logged_y: usize = 0,
    logged_w: u32 = 0,
    logged_h: u32 = 0,

    pub fn idText(s: *const Slot) []const u8 {
        return s.id[0..s.id_len];
    }
    pub fn urlText(s: *const Slot) []const u8 {
        return s.url[0..s.url_len];
    }
};

pub var slots: [max_slots]Slot = @splat(.{});

/// What a page reported, for the app: `{ id, kind, text, code }`.
pub const Event = struct {
    id: [64]u8 = undefined,
    id_len: usize = 0,
    kind: Kind,
    code: u64 = 0,
    text: [512]u8 = undefined,
    text_len: usize = 0,

    pub const Kind = enum { title, url, load, hover, crashed, unavailable };

    pub fn idText(e: *const Event) []const u8 {
        return e.id[0..e.id_len];
    }
    pub fn textOf(e: *const Event) []const u8 {
        return e.text[0..e.text_len];
    }
};

var events: [32]Event = undefined;
var ev_head: usize = 0;
var ev_tail: usize = 0;
var ev_lock: webhost.Lock = .{};

// ------------------------------------------------------------ the host

var spawner: u64 = 0;
var net: ?*netcmds.Net = null;
var view: u64 = 0;
var view_buf: [*]u8 = undefined;
var view_is_assets = false;
var stores: []const ?fscmds.Store = &.{};
var log_h: u64 = 0;
pub var host: webhost.Host = undefined;
var host_ready = false;
var stage: ?loader.Stage = null;
var staged = false;
var thread_up = false;
var thread_stack: [64 << 10]u8 align(16) = undefined;

pub fn setup(spawner_cap: u64, n: *netcmds.Net, view_chan: u64, buf: [*]u8, assets_view: bool, s: []const ?fscmds.Store, log: u64) void {
    spawner = spawner_cap;
    net = n;
    view = view_chan;
    view_buf = buf;
    view_is_assets = assets_view;
    stores = s;
    log_h = log;
}

/// Whether this program can host pages at all (a spawner and a net view).
pub fn available() bool {
    if (spawner == 0) return false;
    const n = net orelse return false;
    return n.chan != 0;
}

/// Why a page cannot be hosted, for the app's event.
pub fn unavailableReason() []const u8 {
    if (spawner == 0) return "this program holds no spawner";
    if (net == null or net.?.chan == 0) return "this program holds no network view";
    return "the webpage image is not in the store";
}

fn ensureHost(it: *mshl.Interp) bool {
    if (!available()) return false;
    if (!host_ready) {
        host.reset(log_h, spawner, net.?);
        if (!host.init()) return false;
        if (view != 0) _ = host.loadFontsFrom(view, view_buf, if (view_is_assets) "" else "assets/");
        host_ready = true;
    }
    if (stage == null) stage = loader.Stage.init(loader.Stage.default_pages) orelse return false;
    if (!staged) {
        _ = progload.loadImage(it, "webpage", stores, &stage.?) orelse return false;
        staged = true;
    }
    if (!thread_up) {
        if (usys.threadCreate(serve, 0, &thread_stack) != .ok) return false;
        thread_up = true;
    }
    return true;
}

/// The serving thread: every message a page sends, forever; what the
/// app must hear is queued.
fn serve(_: u64) callconv(.c) void {
    while (true) {
        switch (host.step()) {
            .idle, .failed => usys.sleepMs(20),
            .event => |e| {
                const p = host.page(e.page);
                switch (std.enums.fromInt(wire.Event, @intFromEnum(e.kind)) orelse .commit) {
                    .title => push(e.page, .title, 0, p.titleText()),
                    .url => push(e.page, .url, 0, p.urlText()),
                    .load => {
                        push(e.page, .load, e.b | (e.a << 32), "");
                        if (slotOfPage(e.page)) |i| webhost.logf(log_h, "page {s}: load {s} {d}", .{ slots[i].idText(), @tagName(std.enums.fromInt(wire.LoadState, e.a) orelse .failed), e.b });
                    },
                    .hover => push(e.page, .hover, 0, p.hoverText()),
                    else => {},
                }
            },
            .dead => |d| {
                if (slotOfPage(d)) |i| webhost.logf(log_h, "page {s}: crashed", .{slots[i].idText()});
                push(d, .crashed, 0, "");
            },
            .served, .stale => {},
        }
    }
}

fn push(page: webhost.PageId, kind: Event.Kind, code: u64, text: []const u8) void {
    const slot = slotOfPage(page) orelse return;
    pushFor(slots[slot].idText(), kind, code, text);
}

pub fn pushFor(id: []const u8, kind: Event.Kind, code: u64, text: []const u8) void {
    ev_lock.acquire();
    defer ev_lock.release();
    if (ev_tail -% ev_head == events.len) return; // full: the newest news is dropped
    const e = &events[ev_tail % events.len];
    e.* = .{ .kind = kind, .code = code };
    e.id_len = @min(id.len, e.id.len);
    @memcpy(e.id[0..e.id_len], id[0..e.id_len]);
    e.text_len = @min(text.len, e.text.len);
    @memcpy(e.text[0..e.text_len], text[0..e.text_len]);
    ev_tail +%= 1;
}

/// The next queued page event, if any (the GUI loop drains on each tick).
pub fn take() ?Event {
    ev_lock.acquire();
    defer ev_lock.release();
    if (ev_head == ev_tail) return null;
    const e = events[ev_head % events.len];
    ev_head +%= 1;
    return e;
}

fn slotOfPage(page: webhost.PageId) ?usize {
    for (slots, 0..) |s, i| if (s.used and s.page == page) return i;
    return null;
}

// ------------------------------------------------------------- the slots

/// Any page alive: the GUI loop ticks while one is.
pub fn live() bool {
    for (slots) |s| if (s.used) return true;
    return false;
}

/// A page whose commit is newer than its last blit.
pub fn dirty() bool {
    for (slots) |s| if (s.used and s.w > 0) {
        host.lock.acquire();
        const c = host.page(s.page).commits;
        host.lock.release();
        if (c != s.blitted) return true;
    };
    return false;
}

pub fn slotById(id: []const u8) ?*Slot {
    for (&slots) |*s| if (s.used and std.mem.eql(u8, s.idText(), id)) return s;
    return null;
}

/// The slot for a leaf id: the one it has, or a fresh page. Null when
/// the id is already in this tree (a duplicate), when no page can be
/// hosted, or when the table is full.
pub fn slotFor(it: *mshl.Interp, id: []const u8) ?*Slot {
    if (slotById(id)) |s| {
        if (s.seen) {
            last_refusal = "the same page id twice in one tree";
            return null;
        }
        s.seen = true;
        return s;
    }
    if (!ensureHost(it)) {
        last_refusal = unavailableReason();
        return null;
    }
    for (&slots) |*s| if (!s.used) {
        const page = host.spawn(stage.?.handle, 0, 0) orelse {
            last_refusal = "the page domain could not be spawned";
            return null;
        };
        s.* = .{ .used = true, .seen = true, .page = page, .id_len = @min(id.len, s.id.len) };
        @memcpy(s.id[0..s.id_len], id[0..s.id_len]);
        return s;
    };
    last_refusal = "too many pages at once";
    return null;
}

pub fn beginRender() void {
    for (&slots) |*s| s.seen = false;
}

/// Reap the pages whose leaves are gone: `present(id)` says whether the
/// tree about to be painted still names one.
pub fn reap(present: *const fn (id: []const u8) bool) void {
    for (&slots) |*s| if (s.used and !present(s.idText())) {
        webhost.logf(log_h, "page {s}: reaped", .{s.idText()});
        host.destroy(s.page);
        s.* = .{};
    };
}

pub fn reapAll() void {
    for (&slots) |*s| if (s.used) {
        webhost.logf(log_h, "page {s}: reaped", .{s.idText()});
        host.destroy(s.page);
        s.* = .{};
    };
}

/// Bring a page to what its leaf says: the viewport (a hidden leaf has
/// none), then the URL and `nav` nonce.
pub fn sync(s: *Slot, url: []const u8, nav: i64, w: u32, h: u32) void {
    if (s.w != w or s.h != h) {
        if (host.resize(s.page, w, h)) {
            s.w = w;
            s.h = h;
            s.blitted = 0;
        }
    }
    const changed = !std.mem.eql(u8, s.urlText(), url) or nav != s.nav;
    if (url.len > 0 and (changed or !s.loaded_once)) {
        s.url_len = @min(url.len, s.url.len);
        @memcpy(s.url[0..s.url_len], url[0..s.url_len]);
        s.nav = nav;
        s.loaded_once = true;
        _ = host.send(s.page, .{ .load = s.urlText() });
    }
}

/// Hand the page's pixels to the runtime row by row (it knows its
/// surface and clip); false when the page has painted nothing yet, so
/// the runtime shows its own background instead of a black buffer.
pub fn blit(s: *Slot, ctx: *anyopaque, row: *const fn (ctx: *anyopaque, index: usize, src: []const u32) void) bool {
    if (s.w == 0 or s.h == 0) return false;
    host.lock.acquire();
    defer host.lock.release();
    const p = host.page(s.page);
    if (p.commits == 0) return false;
    const px = p.pixels();
    if (px.len < @as(usize, s.w) * s.h) return false;
    for (0..s.h) |index| row(ctx, index, px[index * s.w .. index * s.w + s.w]);
    s.blitted = p.commits;
    return true;
}

/// Why the last `slotFor` gave nothing (for the app's event).
pub var last_refusal: []const u8 = "";

pub fn pointer(s: *Slot, kind: wire.PointerKind, x: u32, y: u32) void {
    _ = host.send(s.page, .{ .pointer = .{ .kind = kind, .x = x, .y = y } });
}

pub fn scroll(s: *Slot, dy: i64) void {
    _ = host.send(s.page, .{ .scroll = dy });
}

pub fn key(s: *Slot, ch: u8) void {
    _ = host.send(s.page, .{ .key = .{ .code = ch, .ch = ch } });
}

/// A page's own state for the app: the state the broker last reported.
pub fn loadState(s: *Slot) wire.LoadState {
    host.lock.acquire();
    defer host.lock.release();
    return host.page(s.page).load_state;
}
