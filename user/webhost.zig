//! Hosting page domains, and brokering their fetches: the one module
//! behind every program that shows or renders a page — the drill's
//! client, `mshrun`'s `web-render`, and the browser to come. A `Host`
//! serves one channel; each page it spawns gets a badged calling end
//! of it and nothing else, so a page's whole world is what this module
//! answers: its buffers, the next command, the bytes behind a URL
//! (opened here over the host's own network view and trust roots,
//! never the page's), and an `ok` for each event it reports.
//!
//! The broker is deliberately plain in this first form: one connection
//! per open, redirects followed here, `http` and `https` only, no
//! content coding asked for (the page would have to inflate it in its
//! own domain — a later stage), a size cap, and a 10 s stall limit.
//! No cache and no cookie jar yet; they arrive with the window that
//! needs them.
const std = @import("std");
const shared = @import("shared");
const mosslib = @import("mosslib");
const usys = @import("usys.zig");
const netcmds = @import("netcmds.zig");
const tlscmds = @import("tlscmds.zig");
const fsc = @import("fsclient.zig");
const http = mosslib.http;
const web = mosslib.web;
const wire = shared.web;
const Net = netcmds.Net;

pub const max_pages = 4;
pub const PageId = u8;

/// A host may serve its pages from one thread while another thread
/// commands them (a window's GUI loop blocks on the compositor). The
/// lock covers the host's state; the blocking receive is outside it.
pub const Lock = struct {
    held: std.atomic.Value(bool) = std.atomic.Value(bool).init(false),

    pub fn acquire(l: *Lock) void {
        while (l.held.cmpxchgWeak(false, true, .acquire, .monotonic) != null) usys.yield();
    }
    pub fn release(l: *Lock) void {
        l.held.store(false, .release);
    }
};

/// A page's memory: its arenas — the document's (12 MB), the layout's
/// (12), the glyph cache (2), the picture store (6) and the picture
/// scratch (6) — plus the image and its 512K stack. Wikipedia's front
/// page, the first real site opened, died twice of a 28 MB page: of
/// the pictures it decoded into the document arena, then of an 8 MB
/// layout arena a 3900-node page asks 10 MB of (2026-09-18).
pub const page_user_kb: u64 = 44 << 10;
pub const page_kobj_kb: u64 = 2 << 10;

const stall_ms: u64 = 10_000;
const max_redirects = 10;
const head_max = 16 << 10;
const request_max = 4 << 10;

const Conn = union(enum) {
    plain: u64,
    tls: tlscmds.Conn,

    fn send(c: Conn, n: *Net, bytes: []const u8) ?[]const u8 {
        return switch (c) {
            .plain => |s| n.sendAll(s, bytes),
            .tls => |t| tlscmds.sendAll(t, bytes),
        };
    }
    fn recvFor(c: Conn, n: *Net, ms: u64) Net.RecvFor {
        return switch (c) {
            .plain => |s| n.recvSomeFor(s, ms),
            .tls => |t| tlscmds.recvSomeFor(t, ms),
        };
    }
    fn close(c: Conn, n: *Net) void {
        switch (c) {
            .plain => |s| n.closeRaw(s),
            .tls => |t| tlscmds.close(t),
        }
    }
};

/// A resource a page has open: the connection, the framing left to
/// read, and the body bytes that arrived with the head.
const Resource = struct {
    conn: Conn,
    framing: http.Framing,
    remaining: usize = 0,
    chunks: Chunked = .{},
    stash: [shared.net_max_recv]u8 = undefined,
    stash_len: usize = 0,
    stash_off: usize = 0,
    served: usize = 0,
    done: bool = false,
};

/// Chunked transfer coding, decoded as bytes arrive.
const Chunked = struct {
    state: enum { size, data, crlf, trailer } = .size,
    remaining: usize = 0,
    line: [96]u8 = undefined,
    line_len: usize = 0,
    done: bool = false,

    const Fed = struct { consumed: usize, produced: usize, failed: bool };

    /// Decode from `in` into `out`, stopping when either is spent.
    fn feed(d: *Chunked, in: []const u8, out: []u8) Fed {
        var i: usize = 0;
        var o: usize = 0;
        while (i < in.len and !d.done) {
            switch (d.state) {
                .size => {
                    const ch = in[i];
                    i += 1;
                    if (ch != '\n') {
                        if (d.line_len == d.line.len) return .{ .consumed = i, .produced = o, .failed = true };
                        d.line[d.line_len] = ch;
                        d.line_len += 1;
                        continue;
                    }
                    var l: []const u8 = d.line[0..d.line_len];
                    d.line_len = 0;
                    if (l.len > 0 and l[l.len - 1] == '\r') l = l[0 .. l.len - 1];
                    if (std.mem.indexOfScalar(u8, l, ';')) |semi| l = l[0..semi];
                    const size = std.fmt.parseInt(usize, std.mem.trim(u8, l, " \t"), 16) catch return .{ .consumed = i, .produced = o, .failed = true };
                    if (size == 0) d.state = .trailer else {
                        d.remaining = size;
                        d.state = .data;
                    }
                },
                .data => {
                    if (o == out.len) return .{ .consumed = i, .produced = o, .failed = false };
                    const len = @min(d.remaining, @min(in.len - i, out.len - o));
                    @memcpy(out[o .. o + len], in[i .. i + len]);
                    i += len;
                    o += len;
                    d.remaining -= len;
                    if (d.remaining == 0) d.state = .crlf;
                },
                .crlf => {
                    const ch = in[i];
                    i += 1;
                    if (ch == '\n') d.state = .size else if (ch != '\r') return .{ .consumed = i, .produced = o, .failed = true };
                },
                .trailer => {
                    const ch = in[i];
                    i += 1;
                    if (ch != '\n') {
                        if (d.line_len < d.line.len) {
                            d.line[d.line_len] = ch;
                            d.line_len += 1;
                        }
                        continue;
                    }
                    const empty = d.line_len == 0 or (d.line_len == 1 and d.line[0] == '\r');
                    d.line_len = 0;
                    if (empty) d.done = true;
                },
            }
        }
        return .{ .consumed = i, .produced = o, .failed = false };
    }
};

/// A command waiting for a page's next `next`.
pub const Command = union(enum) {
    load: []const u8,
    scroll: i64,
    pointer: struct { kind: wire.PointerKind, x: u32, y: u32 },
    key: struct { code: u32, ch: u32 },
    dump: wire.Dump,
    resize: struct { w: u32, h: u32 },
    /// Find `text` (empty clears), showing match `index`.
    find: struct { text: []const u8, index: u32 },
    zoom: u32,
    theme: u64,
    stop,
};

/// A queued command. The text a `load` or `find` carries lives in the
/// page's own slot for that kind (a newer one supersedes what was queued,
/// so one slot each is enough — sixty-four URL buffers a page once made
/// a host 720 KB, and every mshrun carries two hosts).
const Queued = struct {
    cmd: Command,
};
const text_slots = 2; // 0: the queued load's URL, 1: the queued find's text

pub const Page = struct {
    used: bool = false,
    dead: bool = false,
    badge: u64 = 0,
    ctl: u64 = 0,
    data_shm: u64 = 0,
    data_va: u64 = 0,
    data_len: usize = 0,
    px_shm: u64 = 0,
    px_va: u64 = 0,
    w: u32 = 0,
    h: u32 = 0,
    parked: ?u64 = null,
    /// Commands waiting for the page's `next`: typing outruns a page
    /// that relays out per key, so the queue is deep, and a drop is said.
    queue: [64]Queued = undefined,
    qlen: usize = 0,
    texts: [text_slots][2048]u8 = undefined,
    text_len: [text_slots]usize = @splat(0),
    open: ?Resource = null,
    // What the page reported, kept for the host program.
    title: [256]u8 = undefined,
    title_len: usize = 0,
    url: [2048]u8 = undefined,
    url_len: usize = 0,
    hover: [2048]u8 = undefined,
    hover_len: usize = 0,
    load_state: wire.LoadState = .loading,
    load_code: u64 = 0,
    extent: u64 = 0,
    commits: usize = 0,
    dumped_len: usize = 0,
    dumped_cut: bool = false,
    /// The last download's URL and type, a selection's text, the focused
    /// element's kind: whichever event came last with text.
    note: [2048]u8 = undefined,
    note_len: usize = 0,
    note2_len: usize = 0,
    found_count: u64 = 0,
    found_index: u64 = 0,
    focus_rect: u64 = 0,

    pub fn titleText(p: *const Page) []const u8 {
        return p.title[0..p.title_len];
    }
    pub fn urlText(p: *const Page) []const u8 {
        return p.url[0..p.url_len];
    }
    pub fn hoverText(p: *const Page) []const u8 {
        return p.hover[0..p.hover_len];
    }
    /// The last text-bearing event's text (a download's URL, a
    /// selection, a focused element's kind).
    pub fn noteText(p: *const Page) []const u8 {
        return p.note[0..p.note_len];
    }
    /// A download's type, after its URL.
    pub fn noteType(p: *const Page) []const u8 {
        return p.note[p.note_len .. p.note_len + p.note2_len];
    }
    /// The page's pixels, XRGB rows of `w`.
    pub fn pixels(p: *const Page) []const u32 {
        if (p.px_va == 0) return &.{};
        return @as([*]const u32, @ptrFromInt(p.px_va))[0 .. @as(usize, p.w) * p.h];
    }
    /// The last dump, as it sits in the page's data buffer (valid until
    /// the page's next message).
    pub fn dumped(p: *const Page) []const u8 {
        return @as([*]const u8, @ptrFromInt(p.data_va))[0..p.dumped_len];
    }
    fn data(p: *const Page) []u8 {
        return @as([*]u8, @ptrFromInt(p.data_va))[0..p.data_len];
    }
};

/// What one served message amounted to, for the host program's loop.
pub const Step = union(enum) {
    /// Housekeeping the host handled itself (an attach, an open, a read).
    served: PageId,
    /// The page reported an event; its state is updated.
    event: struct { page: PageId, kind: wire.Event, a: u64, b: u64 },
    /// The page died (its budget, a fault, a panic).
    dead: PageId,
    /// A message about a page already destroyed (its badge's death,
    /// delivered after the fact): nothing to do.
    stale,
    /// Nothing to serve: no live page.
    idle,
    /// The channel itself failed.
    failed: shared.Errno,
};

pub const Host = struct {
    log: u64,
    spawner: u64,
    chan: u64 = 0,
    /// The channel's own calling end, held so the side stays open
    /// between pages (a side whose last cap goes is closed for good).
    chan_b: u64 = 0,
    net: *Net,
    next_badge: u64 = 1,
    pages: [max_pages]Page = @splat(.{}),
    fonts_shm: u64 = 0,
    fonts_va: u64 = 0,
    fonts_len: usize = 0,
    /// The reply token of the call being served.
    cur_token: u64 = 0,
    /// A POST's body, copied out of the page's buffer.
    body: [8192]u8 = undefined,
    lock: Lock = .{},
    scratch: [head_max + request_max]u8 = undefined,

    /// Set up in place: a Host is a few hundred KB (each page keeps a
    /// receive stash), so it lives in a program's static memory, never
    /// on a stack.
    pub fn reset(h: *Host, log: u64, spawner: u64, net: *Net) void {
        h.* = .{ .log = log, .spawner = spawner, .net = net };
    }

    pub fn init(h: *Host) bool {
        const ch = usys.chanCreate();
        if (ch.err != .ok) return false;
        h.chan = ch.data[0];
        h.chan_b = ch.data[1];
        return true;
    }

    /// Read the system faces from a view (`assets/fonts/...` under it)
    /// into a buffer every page is granted. Best effort: a page without
    /// fonts lays out with fixed cells.
    pub fn loadFonts(h: *Host, view: u64, view_buf: [*]u8) bool {
        return h.loadFontsFrom(view, view_buf, "assets/");
    }

    /// The same from a view rooted at `prefix` (an assets view: "").
    pub fn loadFontsFrom(h: *Host, view: u64, view_buf: [*]u8, prefix: []const u8) bool {
        var p0: [64]u8 = undefined;
        var p1: [64]u8 = undefined;
        const files = [_][]const u8{
            std.fmt.bufPrint(&p0, "{s}fonts/IBMPlexSans.ttf", .{prefix}) catch return false,
            std.fmt.bufPrint(&p1, "{s}fonts/IBMPlexMono-Regular.ttf", .{prefix}) catch return false,
        };
        const pages: u64 = 200; // 800 KB: the two faces are 673 KB
        const s = usys.shmCreate(pages);
        if (s.err != .ok) return false;
        const m = usys.shmMap(s.data[0]);
        if (m.err != .ok) {
            _ = usys.capDrop(s.data[0]);
            return false;
        }
        const buf = @as([*]u8, @ptrFromInt(m.data[0]))[0 .. m.data[1] * 4096];
        var off = wire.FontPack.begin(buf, files.len) orelse return false;
        var got: usize = 0;
        for (files, 0..) |path, i| {
            // readWhole fills the pack in place; only the length is recorded.
            const bytes = fsc.readWhole(view, view_buf, path, buf[off..]) orelse "";
            std.mem.writeInt(u32, buf[4 + 4 * i ..][0..4], @intCast(bytes.len), .little);
            off += bytes.len;
            if (bytes.len > 0) got += 1;
        }
        if (got == 0) {
            _ = usys.shmUnmap(m.data[0]);
            _ = usys.capDrop(s.data[0]);
            return false;
        }
        h.fonts_shm = s.data[0];
        h.fonts_va = m.data[0];
        h.fonts_len = off;
        return true;
    }

    /// Spawn a page from a staged `webpage` image with a `w` × `h`
    /// viewport (0 × 0 for a headless page). The page's first messages
    /// (its attaches) are served by `step`.
    pub fn spawn(h: *Host, stage_handle: u64, w: u32, height: u32) ?PageId {
        h.lock.acquire();
        defer h.lock.release();
        var idx: usize = 0;
        while (idx < max_pages and h.pages[idx].used) idx += 1;
        if (idx == max_pages) return null;
        const p = &h.pages[idx];
        const badge = h.next_badge;
        h.next_badge += 1;
        const minted = usys.chanMint(h.chan, badge);
        if (minted.err != .ok) return null;
        // A page just destroyed is reaped asynchronously and its memory
        // charged until then; a refusal for room is retried for a moment
        // before it is real.
        var sp = usys.spawn(h.spawner, stage_handle, wire.page_arg, minted.data[1], shared.SpawnFlags.grant_log, usys.kbLimits(page_kobj_kb, page_user_kb));
        var tries: usize = 0;
        while (sp.err == .no_space and tries < 50) : (tries += 1) {
            usys.sleepMs(20);
            sp = usys.spawn(h.spawner, stage_handle, wire.page_arg, minted.data[1], shared.SpawnFlags.grant_log, usys.kbLimits(page_kobj_kb, page_user_kb));
        }
        _ = usys.capDrop(minted.data[1]);
        if (sp.err != .ok) {
            logf(h.log, "webhost: spawn refused: {s}", .{@tagName(sp.err)});
            return null;
        }
        p.* = .{ .used = true, .badge = badge, .ctl = sp.data[0], .w = w, .h = height };
        const d = usys.shmCreate(wire.data_pages);
        if (d.err != .ok) {
            h.destroy(@intCast(idx));
            return null;
        }
        const dm = usys.shmMap(d.data[0]);
        if (dm.err != .ok) {
            _ = usys.capDrop(d.data[0]);
            h.destroy(@intCast(idx));
            return null;
        }
        p.data_shm = d.data[0];
        p.data_va = dm.data[0];
        p.data_len = dm.data[1] * 4096;
        if (w > 0 and height > 0) {
            const pages = (@as(u64, w) * height * 4 + 4095) / 4096;
            const s = usys.shmCreate(pages);
            if (s.err != .ok) {
                h.destroy(@intCast(idx));
                return null;
            }
            const m = usys.shmMap(s.data[0]);
            if (m.err != .ok) {
                _ = usys.capDrop(s.data[0]);
                h.destroy(@intCast(idx));
                return null;
            }
            p.px_shm = s.data[0];
            p.px_va = m.data[0];
        }
        return @intCast(idx);
    }

    /// Give a page a new viewport: a fresh pixel buffer of `w` × `h`
    /// (none for 0 × 0, a hidden page), the old one let go here — the
    /// page unmaps its side when it takes the `resize` command and asks
    /// for the new buffer.
    pub fn resize(h: *Host, id: PageId, w: u32, height: u32) bool {
        h.lock.acquire();
        defer h.lock.release();
        const p = &h.pages[id];
        if (!p.used or p.dead) return false;
        if (p.w == w and p.h == height) return true;
        if (p.px_va != 0) _ = usys.shmUnmap(p.px_va);
        if (p.px_shm != 0) _ = usys.capDrop(p.px_shm);
        p.px_va = 0;
        p.px_shm = 0;
        p.w = w;
        p.h = height;
        if (w > 0 and height > 0) {
            const pages = (@as(u64, w) * height * 4 + 4095) / 4096;
            const s = usys.shmCreate(pages);
            if (s.err != .ok) return false;
            const m = usys.shmMap(s.data[0]);
            if (m.err != .ok) {
                _ = usys.capDrop(s.data[0]);
                return false;
            }
            p.px_shm = s.data[0];
            p.px_va = m.data[0];
        }
        return h.sendLocked(id, .{ .resize = .{ .w = w, .h = height } });
    }

    /// Destroy a page's domain and drop everything held for it.
    pub fn destroy(h: *Host, id: PageId) void {
        h.lock.acquire();
        defer h.lock.release();
        h.destroyLocked(id);
    }

    fn destroyLocked(h: *Host, id: PageId) void {
        const p = &h.pages[id];
        if (!p.used) return;
        if (p.open) |*r| r.conn.close(h.net);
        if (p.ctl != 0) {
            _ = usys.domainDestroy(p.ctl);
            // Its memory comes back when the kernel reaps it, which is
            // after the control cap goes; waiting for the death first
            // keeps a spawn right after this from being refused for room
            // (and retried) in the common case.
            var polls: usize = 0;
            while (polls < 100) : (polls += 1) {
                const st = usys.domainStat(p.ctl);
                if (st.err != .ok or st.data[0] == @intFromEnum(shared.DomainState.dead)) break;
                usys.sleepMs(10);
            }
        }
        if (p.data_va != 0) _ = usys.shmUnmap(p.data_va);
        if (p.data_shm != 0) _ = usys.capDrop(p.data_shm);
        if (p.px_va != 0) _ = usys.shmUnmap(p.px_va);
        if (p.px_shm != 0) _ = usys.capDrop(p.px_shm);
        if (p.ctl != 0) _ = usys.capDrop(p.ctl);
        p.* = .{};
    }

    pub fn deinit(h: *Host) void {
        h.lock.acquire();
        for (0..max_pages) |i| h.destroyLocked(@intCast(i));
        h.lock.release();
        if (h.fonts_va != 0) _ = usys.shmUnmap(h.fonts_va);
        if (h.fonts_shm != 0) _ = usys.capDrop(h.fonts_shm);
        if (h.chan_b != 0) _ = usys.capDrop(h.chan_b);
        if (h.chan != 0) _ = usys.capDrop(h.chan);
        h.* = .{ .log = h.log, .spawner = h.spawner, .net = h.net };
    }

    pub fn page(h: *Host, id: PageId) *Page {
        return &h.pages[id];
    }

    fn byBadge(h: *Host, badge: u64) ?PageId {
        for (h.pages, 0..) |p, i| if (p.used and p.badge == badge) return @intCast(i);
        return null;
    }

    /// Queue a command for a page; a page waiting on `next` gets it now.
    pub fn send(h: *Host, id: PageId, cmd: Command) bool {
        h.lock.acquire();
        defer h.lock.release();
        return h.sendLocked(id, cmd);
    }

    fn sendLocked(h: *Host, id: PageId, cmd: Command) bool {
        const p = &h.pages[id];
        if (!p.used or p.dead) return false;
        if (p.qlen == p.queue.len) {
            logf(h.log, "webhost: page {d}: command queue full; {s} dropped", .{ id, @tagName(cmd) });
            return false;
        }
        // A command's text lives in the page's slot for its kind, not in
        // the caller's memory; a newer load or find supersedes a queued
        // one, which leaves the queue.
        var stored = cmd;
        if (cmd == .load or cmd == .find) {
            const slot: usize = if (cmd == .load) 0 else 1;
            const text = if (cmd == .load) cmd.load else cmd.find.text;
            var i: usize = 0;
            while (i < p.qlen) {
                if (std.meta.activeTag(p.queue[i].cmd) == std.meta.activeTag(cmd)) {
                    for (i + 1..p.qlen) |j| p.queue[j - 1] = p.queue[j];
                    p.qlen -= 1;
                } else i += 1;
            }
            p.text_len[slot] = @min(text.len, p.texts[slot].len);
            @memcpy(p.texts[slot][0..p.text_len[slot]], text[0..p.text_len[slot]]);
            stored = if (cmd == .load) .{ .load = "" } else .{ .find = .{ .text = "", .index = cmd.find.index } };
        }
        p.queue[p.qlen] = .{ .cmd = stored };
        p.qlen += 1;
        if (p.parked) |token| {
            p.parked = null;
            h.answerNext(id, token);
        }
        return true;
    }

    fn answerNext(h: *Host, id: PageId, token: u64) void {
        const p = &h.pages[id];
        const q = &p.queue[0];
        const rep: wire.HostResp = switch (q.cmd) {
            .load => blk: {
                const url_slice = p.texts[0][0..p.text_len[0]];
                const n = @min(url_slice.len, p.data_len);
                @memcpy(p.data()[0..n], url_slice[0..n]);
                break :blk .{ .load = .{ .off = 0, .len = n } };
            },
            .scroll => |dy| .{ .scroll = .{ .dy = @bitCast(dy) } },
            .pointer => |pt| .{ .pointer = .{ .kind = @intFromEnum(pt.kind), .x = pt.x, .y = pt.y } },
            .key => |k| .{ .key = .{ .code = k.code, .ch = k.ch } },
            .dump => |d| .{ .dump = .{ .what = @intFromEnum(d) } },
            .resize => |r| .{ .resize = .{ .w = r.w, .h = r.h } },
            .find => |f| blk: {
                const text = p.texts[1][0..p.text_len[1]];
                const n = @min(text.len, p.data_len);
                @memcpy(p.data()[0..n], text[0..n]);
                break :blk .{ .find = .{ .len = n, .index = f.index } };
            },
            .zoom => |z| .{ .zoom = .{ .percent = z } },
            .theme => |t| .{ .theme = .{ .flags = t } },
            .stop => .stop,
        };
        // Shift the queue.
        for (1..p.qlen) |i| p.queue[i - 1] = p.queue[i];
        p.qlen -= 1;
        const e = usys.replyTypedTo(wire.HostResp, h.chan, rep, 0, token);
        if (e != .ok) logf(h.log, "webhost: page {d}: answering {s} with token {x} failed: {s}", .{ id, @tagName(rep), token, @tagName(e) });
    }

    fn isResolveFailure(why: []const u8) bool {
        return std.mem.indexOf(u8, why, "resolve") != null or std.mem.indexOf(u8, why, "nxdomain") != null;
    }

    /// Every reply names its caller: with a page parked on `next`, a
    /// reply without a token would answer the wrong call.
    fn reply(h: *Host, rep: wire.HostResp, cap: u64) void {
        _ = usys.replyTypedTo(wire.HostResp, h.chan, rep, cap, h.cur_token);
    }

    /// Serve one message from any page.
    pub fn step(h: *Host) Step {
        var live = false;
        for (h.pages) |p| if (p.used and !p.dead) {
            live = true;
        };
        if (!live) return .idle;
        const r = usys.recvMsg(h.chan);
        h.lock.acquire();
        defer h.lock.release();
        if (r.err == .client_dead) {
            const id = h.byBadge(r.badge) orelse return .stale;
            logf(h.log, "webhost: page {d} died (badge {d})", .{ id, r.badge });
            h.pages[id].dead = true;
            if (h.pages[id].open) |*res| {
                res.conn.close(h.net);
                h.pages[id].open = null;
            }
            return .{ .dead = id };
        }
        if (r.err != .ok) {
            logf(h.log, "webhost: recv failed: {s}", .{@tagName(r.err)});
            return .{ .failed = r.err };
        }
        h.cur_token = r.token;
        const id = h.byBadge(r.badge) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            h.reply(.none, 0);
            return .stale;
        };
        if (r.cap != 0) _ = usys.capDrop(r.cap); // a page sends no caps
        const p = &h.pages[id];
        const req = shared.decodeMsg(wire.PageReq, r.data) orelse {
            h.reply(.none, 0);
            return .{ .served = id };
        };
        switch (req) {
            .attach_data => h.reply(.{ .data_buf = .{ .pages = wire.data_pages } }, p.data_shm),
            .attach_pixels => if (p.px_shm != 0) h.reply(.{ .pixels = .{ .w = p.w, .h = p.h } }, p.px_shm) else h.reply(.none, 0),
            .attach_fonts => if (h.fonts_shm != 0) h.reply(.{ .fonts = .{ .len = h.fonts_len } }, h.fonts_shm) else h.reply(.none, 0),
            .next => {
                if (p.qlen > 0) h.answerNext(id, r.token) else p.parked = r.token;
            },
            .open => |o| h.open(id, o.off, o.len, o.flags),
            .read => |rd| h.read(id, rd.max),
            .cancel => {
                if (p.open) |*res| res.conn.close(h.net);
                p.open = null;
                h.reply(.ok, 0);
            },
            .event => |e| {
                const kind = std.enums.fromInt(wire.Event, e.kind) orelse {
                    h.reply(.ok, 0);
                    return .{ .served = id };
                };
                h.noteEvent(p, kind, e.a, e.b);
                h.reply(.ok, 0);
                return .{ .event = .{ .page = id, .kind = kind, .a = e.a, .b = e.b } };
            },
        }
        return .{ .served = id };
    }

    fn noteEvent(h: *Host, p: *Page, kind: wire.Event, a: u64, b: u64) void {
        _ = h;
        const d = p.data();
        switch (kind) {
            .title => {
                p.title_len = @min(@min(a, d.len), p.title.len);
                @memcpy(p.title[0..p.title_len], d[0..p.title_len]);
            },
            .url => {
                p.url_len = @min(@min(a, d.len), p.url.len);
                @memcpy(p.url[0..p.url_len], d[0..p.url_len]);
            },
            .hover => {
                p.hover_len = @min(@min(a, d.len), p.hover.len);
                @memcpy(p.hover[0..p.hover_len], d[0..p.hover_len]);
            },
            .load => {
                p.load_state = std.enums.fromInt(wire.LoadState, a) orelse .failed;
                p.load_code = b;
            },
            .commit => p.commits += 1,
            .extent => p.extent = a,
            .dumped => {
                p.dumped_len = @min(a, d.len);
                p.dumped_cut = b != 0;
            },
            .download => {
                p.note_len = @min(@min(a, d.len), p.note.len);
                p.note2_len = @min(@min(b, d.len -| a), p.note.len - p.note_len);
                @memcpy(p.note[0 .. p.note_len + p.note2_len], d[0 .. p.note_len + p.note2_len]);
            },
            .selection, .focus => {
                p.note_len = @min(@min(a, d.len), p.note.len);
                p.note2_len = 0;
                @memcpy(p.note[0..p.note_len], d[0..p.note_len]);
                if (kind == .focus) p.focus_rect = b;
            },
            .found => {
                p.found_count = a;
                p.found_index = b;
            },
        }
    }

    // ------------------------------------------------------- the broker

    fn refuse(h: *Host, code: wire.RefuseCode) void {
        h.reply(.{ .refused = .{ .code = @intFromEnum(code) } }, 0);
    }

    fn open(h: *Host, id: PageId, off: u64, len: u64, flags: u64) void {
        const p = &h.pages[id];
        if (p.open) |*res| {
            res.conn.close(h.net);
            p.open = null;
        }
        const d = p.data();
        if (off > d.len or len > d.len - off or len == 0) return h.refuse(.bad_url);
        // The URL (and a POST's body after it) is copied out: the data
        // buffer is about to carry the answer.
        var url_buf: [2048]u8 = undefined;
        if (len > url_buf.len) return h.refuse(.bad_url);
        @memcpy(url_buf[0..len], d[off .. off + len]);
        var url: []const u8 = url_buf[0..len];
        var post = flags & 1 != 0;
        const body_len: usize = @intCast(@min(flags >> 8, h.body.len));
        if (off + len + body_len > d.len) return h.refuse(.bad_url);
        @memcpy(h.body[0..body_len], d[off + len .. off + len + body_len]);
        var body: []const u8 = h.body[0..body_len];
        var fba = std.heap.FixedBufferAllocator.init(&h.scratch);
        var hops: usize = 0;
        while (true) : (hops += 1) {
            if (hops > max_redirects) return h.refuse(.redirects);
            fba.reset();
            const a = fba.allocator();
            const target = http.parseUrl(url) orelse return h.refuse(if (std.mem.indexOf(u8, url, "://") == null) .bad_url else .scheme);
            if (!h.net.attach()) return h.refuse(.connect);
            // A failure to reach the site says why in the log: the word
            // is the network service's or the TLS client's, and a page
            // only hears a code.
            const conn: Conn = if (target.tls) switch (tlscmds.open(h.net, target.host, target.port, target.host)) {
                .conn => |c| .{ .tls = c },
                .failed => |why| {
                    logf(h.log, "webhost: page {d}: {s}: {s}", .{ id, url, why });
                    return h.refuse(if (isResolveFailure(why)) .resolve else .connect);
                },
            } else switch (h.net.connectHost(target.host, target.port)) {
                .sock => |s| .{ .plain = s },
                .failed => |why| {
                    logf(h.log, "webhost: page {d}: {s}: {s}", .{ id, url, why });
                    return h.refuse(if (isResolveFailure(why)) .resolve else .connect);
                },
            };
            var req: std.ArrayList(u8) = .empty;
            var host_hdr: [300]u8 = undefined;
            const host_text = if ((target.tls and target.port == 443) or (!target.tls and target.port == 80))
                target.host
            else
                std.fmt.bufPrint(&host_hdr, "{s}:{d}", .{ target.host, target.port }) catch target.host;
            const headers_get = [_]http.Header{
                .{ .name = "Accept", .value = "text/html,application/xhtml+xml,text/plain;q=0.9,*/*;q=0.5" },
                .{ .name = "Accept-Encoding", .value = "identity" },
                .{ .name = "User-Agent", .value = "moss/0.0 (webpage)" },
            };
            const headers_post = headers_get ++ [_]http.Header{.{ .name = "Content-Type", .value = "application/x-www-form-urlencoded" }};
            http.formatRequest(a, &req, if (post) "POST" else "GET", target.path, host_text, if (post) &headers_post else &headers_get, body, false) catch return h.refuse(.memory);
            if (conn.send(h.net, req.items)) |_| {
                conn.close(h.net);
                return h.refuse(.connect);
            }
            // The head, from as many receives as it takes.
            var head_buf = h.scratch[request_max..];
            var got: usize = 0;
            var head: http.Head = undefined;
            var closed = false;
            while (true) {
                switch (conn.recvFor(h.net, stall_ms)) {
                    .data => |bytes| {
                        if (got + bytes.len > head_buf.len) {
                            conn.close(h.net);
                            logf(h.log, "webhost: page {d}: {s}: the head is longer than {d} KB", .{ id, url, head_buf.len / 1024 });
                            return h.refuse(.protocol);
                        }
                        @memcpy(head_buf[got .. got + bytes.len], bytes);
                        got += bytes.len;
                    },
                    .closed => closed = true,
                    .failed, .timeout => {
                        conn.close(h.net);
                        logf(h.log, "webhost: page {d}: {s}: no head after {d} bytes (the connection failed or stalled)", .{ id, url, got });
                        return h.refuse(.connect);
                    },
                }
                const parsed = http.parseHead(a, head_buf[0..got]) catch |e| {
                    conn.close(h.net);
                    logf(h.log, "webhost: page {d}: {s}: the head does not parse: {s}", .{ id, url, @errorName(e) });
                    return h.refuse(.protocol);
                };
                if (parsed) |hd| {
                    head = hd;
                    break;
                }
                if (closed) {
                    conn.close(h.net);
                    logf(h.log, "webhost: page {d}: {s}: closed before the head ({d} bytes)", .{ id, url, got });
                    return h.refuse(.protocol);
                }
            }
            if (head.status >= 300 and head.status < 400) if (http.headerValue(head.headers, "location")) |loc| {
                conn.close(h.net);
                const base = web.url.parse(a, url, null) catch return h.refuse(.bad_url);
                const next = web.url.resolve(a, loc, &base) catch return h.refuse(.bad_url);
                const text = next.href(a) catch return h.refuse(.memory);
                if (text.len > url_buf.len) return h.refuse(.bad_url);
                @memcpy(url_buf[0..text.len], text);
                url = url_buf[0..text.len];
                // A redirected POST is followed as a GET, as browsers do.
                post = false;
                body = "";
                continue;
            };
            if (head.framing == .length and head.framing.length > wire.max_resource) {
                conn.close(h.net);
                return h.refuse(.too_large);
            }
            p.open = .{ .conn = conn, .framing = if (head.bodiless) .none else head.framing };
            const res = &p.open.?;
            if (head.bodiless) res.done = true;
            if (res.framing == .length) {
                res.remaining = res.framing.length;
                if (res.remaining == 0) res.done = true;
            }
            const rest = head_buf[head.len..got];
            @memcpy(res.stash[0..rest.len], rest);
            res.stash_len = rest.len;
            // A connection already closed delivers only what is in hand.
            if (closed and res.framing == .none) res.done = rest.len == 0;
            if (closed and res.framing == .chunked) res.done = rest.len == 0;
            // The answer: status, then the final URL and the content type
            // in the data buffer.
            const ct = http.headerValue(head.headers, "content-type") orelse "";
            const url_len = @min(url.len, d.len);
            @memcpy(d[0..url_len], url[0..url_len]);
            const ct_len = @min(ct.len, d.len - url_len);
            @memcpy(d[url_len .. url_len + ct_len], ct[0..ct_len]);
            h.reply(.{ .opened = .{ .status = head.status, .url_len = url_len, .type_len = ct_len } }, 0);
            return;
        }
    }

    fn chunkReply(h: *Host, len: usize, end: wire.ChunkEnd) void {
        h.reply(.{ .chunk = .{ .len = len, .done = @intFromEnum(end) } }, 0);
    }

    fn read(h: *Host, id: PageId, max: u64) void {
        const p = &h.pages[id];
        const res: *Resource = if (p.open) |*r| r else return h.chunkReply(0, .failed);
        const out = p.data()[0..@min(max, p.data_len)];
        var produced: usize = 0;
        // Fill the chunk: a page reading a document in 256 KB pieces
        // makes a hundred calls for a large one, not ten thousand.
        while (produced < out.len and !res.done) {
            // Bytes in hand first, then the wire.
            var in: []const u8 = res.stash[res.stash_off..res.stash_len];
            if (in.len == 0) {
                switch (res.conn.recvFor(h.net, stall_ms)) {
                    .data => |bytes| {
                        @memcpy(res.stash[0..bytes.len], bytes);
                        res.stash_off = 0;
                        res.stash_len = bytes.len;
                        in = res.stash[0..bytes.len];
                    },
                    .closed => {
                        // The end of an unframed body; anything else cut short.
                        if (res.framing == .none or (res.framing == .length and res.remaining == 0)) {
                            res.done = true;
                            break;
                        }
                        logf(h.log, "webhost: page {d}: the body was cut short (closed, {s} framing)", .{ id, @tagName(res.framing) });
                        h.finish(p);
                        return h.chunkReply(0, .failed);
                    },
                    .failed => {
                        logf(h.log, "webhost: page {d}: the body's connection failed", .{id});
                        h.finish(p);
                        return h.chunkReply(0, .failed);
                    },
                    .timeout => {
                        logf(h.log, "webhost: page {d}: the body stalled for {d} ms", .{ id, stall_ms });
                        h.finish(p);
                        return h.chunkReply(0, .failed);
                    },
                }
            }
            const room = out[produced..];
            const before = produced;
            switch (res.framing) {
                .length => {
                    const n = @min(@min(in.len, room.len), res.remaining);
                    @memcpy(room[0..n], in[0..n]);
                    res.stash_off += n;
                    res.remaining -= n;
                    produced += n;
                    if (res.remaining == 0) res.done = true;
                },
                .none => {
                    const n = @min(in.len, room.len);
                    @memcpy(room[0..n], in[0..n]);
                    res.stash_off += n;
                    produced += n;
                },
                .chunked => {
                    const fed = res.chunks.feed(in, room);
                    res.stash_off += fed.consumed;
                    produced += fed.produced;
                    if (fed.failed) {
                        h.finish(p);
                        return h.chunkReply(0, .failed);
                    }
                    if (res.chunks.done) res.done = true;
                },
            }
            res.served += produced - before;
            if (res.served > wire.max_resource) {
                h.finish(p);
                return h.chunkReply(0, .failed);
            }
        }
        const end: wire.ChunkEnd = if (res.done) .done else .more;
        if (res.done) h.finish(p);
        h.chunkReply(produced, end);
    }

    fn finish(h: *Host, p: *Page) void {
        if (p.open) |*res| res.conn.close(h.net);
        p.open = null;
    }
};

pub fn logf(log: u64, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = usys.log(log, text);
}
