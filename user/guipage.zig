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
const tlscmds = @import("tlscmds.zig");
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
    /// What the page was last told: its zoom, the appearance, the find,
    /// whether scripts run.
    scripts: ?bool = null,
    zoom: u32 = 0,
    theme: u64 = std.math.maxInt(u64),
    find: [256]u8 = undefined,
    find_len: usize = 0,
    find_nav: i64 = 0,
    find_sent: bool = false,
    /// When the page was last commanded, and whether it has been told
    /// the input went quiet since (once).
    last_cmd_ms: u64 = 0,
    idle_sent: bool = true,
    /// The last selection the page reported (what Copy takes).
    sel: [2048]u8 = undefined,
    sel_len: usize = 0,
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

    fn touched(s: *Slot) void {
        s.last_cmd_ms = usys.nowMs();
        s.idle_sent = false;
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

    pub const Kind = enum { title, url, load, hover, crashed, unavailable, download, found, selection, focus };

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
/// The serving thread's stack. The broker fetches on this thread, and a
/// TLS handshake alone needs >120 KB of it (kernel/domain.zig sizes the
/// main stacks by the same lesson): at 64 KB the first https page
/// overflowed the array into whatever the linker placed below it — once
/// the GUI epoch's allocator, so the browser died of "unreachable" in a
/// resize with the wrong buffer bounds (2026-09-18). The stack is
/// painted at start so `stackHighWater` can report how much was used.
const thread_stack_size = 512 << 10;
const stack_paint: u8 = 0xa5;
var thread_stack: [thread_stack_size]u8 align(16) = undefined;

/// How deep the serving thread's stack has ever been, in bytes.
pub fn stackHighWater() usize {
    if (!thread_up) return 0;
    var i: usize = 0;
    while (i < thread_stack.len and thread_stack[i] == stack_paint) : (i += 1) {}
    return thread_stack.len - i;
}

pub fn setup(spawner_cap: u64, n: *netcmds.Net, view_chan: u64, buf: [*]u8, assets_view: bool, s: []const ?fscmds.Store, log: u64) void {
    spawner = spawner_cap;
    net = n;
    view = view_chan;
    view_buf = buf;
    view_is_assets = assets_view;
    stores = s;
    log_h = log;
}

/// Where the pages' `localStorage` persists: a directory of the
/// session's home, given by the program that has the view.
pub fn setStorageDir(view_chan: u64, buf: [*]u8, dir: []const u8) void {
    host.setStorageDir(view_chan, buf, dir);
}

/// Whether this program can host pages at all (a spawner and a net view).
pub fn available() bool {
    if (spawner == 0) return false;
    const n = net orelse return false;
    return n.chan != 0;
}

/// Why a page cannot be hosted, for the app's event: the step of
/// `ensureHost` that refused, named (every one read as "the webpage
/// image is not in the store" until 2026-09-28, when a desktop booted
/// on an old disk showed that message for a stale image).
pub fn unavailableReason() []const u8 {
    if (spawner == 0) return "this program holds no spawner";
    if (net == null or net.?.chan == 0) return "this program holds no network view";
    return host_refusal;
}

var host_refusal: []const u8 = "the page host is not set up";
var refusal_buf: [160]u8 = undefined;

/// Keep the reason (a copy: the loader's may live in a call scope) and
/// log it when it changes, not at every render that asks again.
fn refuse(why: []const u8) bool {
    const n = @min(why.len, refusal_buf.len);
    const changed = !std.mem.eql(u8, host_refusal, why[0..n]);
    @memcpy(refusal_buf[0..n], why[0..n]);
    host_refusal = refusal_buf[0..n];
    if (changed) webhost.logf(log_h, "page host: {s}", .{host_refusal});
    return false;
}

fn ensureHost(it: *mshl.Interp) bool {
    if (!available()) return false;
    if (!host_ready) {
        host.reset(log_h, spawner, net.?);
        if (!host.init()) return refuse("no channel for the pages");
        if (view != 0) _ = host.loadFontsFrom(view, view_buf, if (view_is_assets) "" else "assets/");
        tlscmds.warmRoots(); // before the first page's handshake
        host_ready = true;
    }
    if (stage == null) stage = loader.Stage.init(loader.Stage.default_pages) orelse return refuse("no memory for the program stage");
    if (!staged) {
        _ = progload.loadImage(it, "webpage", stores, &stage.?) orelse return refuse(progload.last_refusal);
        staged = true;
    }
    if (!thread_up) {
        @memset(&thread_stack, stack_paint);
        if (usys.threadCreate(serve, 0, &thread_stack) != .ok) return refuse("no thread for the pages");
        thread_up = true;
    }
    return true;
}

/// The serving thread: every message a page sends, forever; what the
/// app must hear is queued.
fn serve(_: u64) callconv(.c) void {
    while (true) {
        const step = host.step();
        if (thread_stack[0] != stack_paint or thread_stack[64] != stack_paint) {
            // Past the end: whatever lies below the array is corrupt now.
            webhost.logf(log_h, "page thread: stack overflow ({d} KB); exiting", .{thread_stack.len / 1024});
            usys.exit(254);
        }
        switch (step) {
            .idle, .failed => usys.sleepMs(20),
            .event => |e| {
                const p = host.page(e.page);
                switch (std.enums.fromInt(wire.Event, @intFromEnum(e.kind)) orelse .commit) {
                    .title => {
                        push(e.page, .title, 0, p.titleText());
                        if (slotOfPage(e.page)) |i| webhost.logf(log_h, "page {s}: title \"{s}\"", .{ slots[i].idText(), p.titleText() });
                    },
                    .url => {
                        push(e.page, .url, 0, p.urlText());
                        if (slotOfPage(e.page)) |i| webhost.logf(log_h, "page {s}: url \"{s}\"", .{ slots[i].idText(), p.urlText() });
                    },
                    .load => {
                        push(e.page, .load, e.b | (e.a << 32), "");
                        if (slotOfPage(e.page)) |i| webhost.logf(log_h, "page {s}: load {s} {d}", .{ slots[i].idText(), @tagName(std.enums.fromInt(wire.LoadState, e.a) orelse .failed), e.b });
                    },
                    .hover => push(e.page, .hover, 0, p.hoverText()),
                    .download => {
                        push(e.page, .download, 0, p.noteText());
                        if (slotOfPage(e.page)) |i| webhost.logf(log_h, "page {s}: download {s}", .{ slots[i].idText(), p.noteText() });
                    },
                    .found => {
                        push(e.page, .found, e.a | (e.b << 32), "");
                        if (slotOfPage(e.page)) |i| webhost.logf(log_h, "page {s}: found {d} showing {d}", .{ slots[i].idText(), e.a, e.b });
                    },
                    .selection => {
                        if (slotOfPage(e.page)) |i| {
                            const s = &slots[i];
                            s.sel_len = @min(p.noteText().len, s.sel.len);
                            @memcpy(s.sel[0..s.sel_len], p.noteText()[0..s.sel_len]);
                        }
                        push(e.page, .selection, e.a, p.noteText());
                    },
                    .focus => push(e.page, .focus, e.b, p.noteText()),
                    // The page wants another idle: the next tick sends one
                    // unless input arrives first.
                    .want_idle => if (slotOfPage(e.page)) |i| {
                        slots[i].idle_sent = false;
                        slots[i].last_cmd_ms = 0;
                    },
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
    if (thread_up) webhost.logf(log_h, "page thread: stack high-water {d} of {d} KB", .{ stackHighWater() / 1024, thread_stack.len / 1024 });
}

/// What a leaf says beyond its URL: the text zoom (percent), the
/// session's appearance, and a find (its text and a nonce that asks
/// for the next match).
pub const Extras = struct {
    zoom: u32 = 100,
    theme: u64 = 0,
    find: []const u8 = "",
    find_nav: i64 = 0,
};

/// The rest of a leaf's word, after `sync`.
pub fn syncExtras(s: *Slot, x: Extras) void {
    if (x.zoom != s.zoom) {
        s.zoom = x.zoom;
        _ = host.send(s.page, .{ .zoom = x.zoom });
    }
    if (x.theme != s.theme) {
        s.theme = x.theme;
        _ = host.send(s.page, .{ .theme = x.theme });
    }
    const changed = !std.mem.eql(u8, s.find[0..s.find_len], x.find) or x.find_nav != s.find_nav;
    if (changed or (!s.find_sent and x.find.len > 0)) {
        s.find_len = @min(x.find.len, s.find.len);
        @memcpy(s.find[0..s.find_len], x.find[0..s.find_len]);
        s.find_nav = x.find_nav;
        s.find_sent = true;
        _ = host.send(s.page, .{ .find = .{ .text = s.find[0..s.find_len], .index = @intCast(@max(0, x.find_nav)) } });
        s.touched(); // a find scrolls to its match: pictures there follow on idle
    }
}

/// The last selection a page reported, for the clipboard.
pub fn selectionOf(s: *Slot) []const u8 {
    return s.sel[0..s.sel_len];
}

/// What the page domain holds, for a "Site" view: its memory against
/// its budget, in KB, and whether it is alive.
pub const Info = struct { used_kb: u64 = 0, limit_kb: u64 = 0, alive: bool = false };

pub fn info(s: *Slot) Info {
    host.lock.acquire();
    defer host.lock.release();
    const p = host.page(s.page);
    if (!p.used or p.dead or p.ctl == 0) return .{};
    const st = usys.domainStat(p.ctl);
    if (st.err != .ok) return .{};
    return .{ .used_kb = st.data[3] >> 32, .limit_kb = st.data[3] & 0xffff_ffff, .alive = st.data[0] != @intFromEnum(shared.DomainState.dead) };
}

/// Bring a page to what its leaf says: the viewport (a hidden leaf has
/// none), then the URL and `nav` nonce.
pub fn sync(s: *Slot, url: []const u8, nav: i64, w: u32, h: u32, scripts: bool) void {
    // Scripts on or off goes before the load it applies to.
    if (s.scripts != scripts) {
        s.scripts = scripts;
        _ = host.send(s.page, .{ .scripts = scripts });
    }
    if (s.w != w or s.h != h) {
        if (host.resize(s.page, w, h)) {
            s.w = w;
            s.h = h;
            s.blitted = 0;
        }
    }
    // A leaf whose URL is what the page already reports (the app took
    // the page's final URL into its state) asks for nothing new — and
    // that URL is the commanded one from here on. Without that, a page
    // reached by a redirect and then navigated by a link reloaded
    // forever: the app takes one page event a tick, so the render for
    // the `title` before the `url` event found a leaf matching neither
    // the page's new URL nor the URL typed, and loaded the old one; the
    // app then adopted the new one, and the same test loaded that
    // (wikipedia.org → English, 2026-09-24).
    host.lock.acquire();
    const shown = std.mem.eql(u8, host.page(s.page).urlText(), url);
    host.lock.release();
    if (shown and !std.mem.eql(u8, s.urlText(), url)) {
        s.url_len = @min(url.len, s.url.len);
        @memcpy(s.url[0..s.url_len], url[0..s.url_len]);
    }
    const changed = (!std.mem.eql(u8, s.urlText(), url) and !shown) or nav != s.nav;
    if (url.len > 0 and (changed or !s.loaded_once)) {
        s.url_len = @min(url.len, s.url.len);
        @memcpy(s.url[0..s.url_len], url[0..s.url_len]);
        s.nav = nav;
        s.loaded_once = true;
        _ = host.send(s.page, .{ .load = s.urlText() });
        s.touched();
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
    s.touched();
}

pub fn scroll(s: *Slot, dy: i64) void {
    _ = host.send(s.page, .{ .scroll = dy });
    s.touched();
}

pub fn key(s: *Slot, ch: u8) void {
    _ = host.send(s.page, .{ .key = .{ .code = ch, .ch = ch } });
    s.touched();
}

/// How long the input must be quiet before a page is told so.
const idle_after_ms: u64 = 250;

/// Every tick: a page whose input has been quiet for a while is told
/// `idle`, once — its cue for the work that must not slow a scroll
/// (fetching the pictures that came into view).
pub fn tick() void {
    host.tickWakes(); // the pages' timers: the host keeps the clock
    const now = usys.nowMs();
    for (&slots) |*s| {
        if (!s.used or s.idle_sent) continue;
        if (now - s.last_cmd_ms < idle_after_ms) continue;
        s.idle_sent = true;
        _ = host.send(s.page, .idle);
    }
}

/// A page's own state for the app: the state the broker last reported.
pub fn loadState(s: *Slot) wire.LoadState {
    host.lock.acquire();
    defer host.lock.release();
    return host.page(s.page).load_state;
}
