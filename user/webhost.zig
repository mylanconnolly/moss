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

/// A page's memory: its arenas — the document-and-layout region (40 MB),
/// the glyph cache (2), the picture store (6) and the picture scratch
/// (6), the user-agent sheet (0.5), the script engine's heap (8) and its
/// bookkeeping (16) — plus the image and its 512K stack: 78.5 MB of
/// statics under an 84 MB budget, 5 MB of headroom. Wikipedia's front page,
/// the first real site opened, died twice of a 28 MB page: of the
/// pictures it decoded into the document arena, then of an 8 MB layout
/// arena a 3900-node page asks 10 MB of (2026-09-18); a 1.2 MB article
/// died of a 24 MB region a 17,800-node page asks 29 MB of, once its
/// lists stopped leaving their old buffers behind (2026-09-24).
pub const page_user_kb: u64 = 116 << 10;
/// A connection key: scheme|host|port, a host name's worst case.
const conn_key_max = 320;
pub const page_kobj_kb: u64 = 2 << 10;
/// The storage buffer per host and each origin's share of it.
pub const storage_bytes: usize = 128 << 10;
pub const storage_quota: usize = 32 << 10;
/// Relay mode: the records a page produces between the window's polls
/// (events, its fetch and storage requests) wait here.
const out_bytes: usize = 16 << 10;
/// The most raw pixel bytes in one shipped piece (LZ4's input cap, and
/// the scratch each side keeps for it).
const lz_max: usize = 60_000;
/// How often the window polls a remote page that has nothing in flight.
const pump_idle_ms: u64 = 30;
/// The pump thread's stack (the broker's TLS handshakes run on it).
const pump_stack_pages: u64 = 64;
/// A remote page the window has not polled for this long is dead to
/// the relay (the window's node went away without a `bye`).
pub const relay_stale_ms: u64 = 15_000;

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
    opened_ms: u64 = 0,
    got_bytes: usize = 0,
    /// The response allows the connection to carry another request.
    keep: bool = false,
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
    /// A dump: the whole document, or the elements `select` matches.
    dump: struct { what: wire.Dump, select: []const u8 = "" },
    resize: struct { w: u32, h: u32 },
    /// Find `text` (empty clears), showing match `index`.
    find: struct { text: []const u8, index: u32 },
    zoom: u32,
    theme: u64,
    idle,
    /// Time passed: the page runs its due timers and frames.
    tick,
    /// Scripts on or off for the loads that follow.
    scripts: bool,
    stop,
};

/// A queued command. The text a `load` or `find` carries lives in the
/// page's own slot for that kind (a newer one supersedes what was queued,
/// so one slot each is enough — sixty-four URL buffers a page once made
/// a host 720 KB, and every mshrun carries two hosts).
const Queued = struct {
    cmd: Command,
};
const text_slots = 3; // 0: the queued load's URL, 1: the queued find's text, 2: a dump's selector

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
    /// The broker's state for this page: what it has open and parks.
    client: Client = .{},
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
    /// When the page asked to be woken (its next timer), or null.
    wake_at: ?u64 = null,
    // Relay mode: this host serves the page for a window on another
    // node (stage 12). The request the page is parked on until the
    // window's broker answers it; the records the window has not taken;
    // the viewport rows it has not seen (against a shadow of the frame
    // it last got, so a hover ships a few rows, not the page); a dump
    // on its way; the window's session buffer (the fabric's twin here).
    pending: Pending = .none,
    pending_token: u64 = 0,
    /// The records FIFO, `out_bytes` mapped when the window attaches.
    out_va: u64 = 0,
    out_len: usize = 0,
    dmg: ?Rect = null,
    dmg_row: u32 = 0,
    dump_off: usize = 0,
    twin_va: u64 = 0,
    twin_len: usize = 0,
    shadow_va: u64 = 0,
    shadow_len: usize = 0,
    key: u64 = 0,
    last_pump_ms: u64 = 0,
    /// Window side: the page lives on another node.
    remote: ?Remote = null,

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
    fn outBuf(p: *const Page) []u8 {
        if (p.out_va == 0) return &.{};
        return @as([*]u8, @ptrFromInt(p.out_va))[0..out_bytes];
    }
};

/// A viewport rect.
pub const Rect = struct { x: u32, y: u32, w: u32, h: u32 };

/// Relay mode: the call of the page's that waits for the window's
/// answer (its broker opens and reads, its storage; a dump streams out
/// before the page may overwrite its buffer).
pub const Pending = enum { none, open, read, storage, dump };

/// Window side: the broker's answer owed to the relay's page, carried
/// in the next poll.
const Feed = union(enum) {
    none,
    /// The final URL then the content type, in `feed_text`.
    opened: struct { status: u64, url_len: usize, ct_len: usize },
    refused: wire.RefuseCode,
    s_ok,
    s_none,
    s_count: u64,
    /// A storage value or key, `len` bytes in `feed_text`.
    s_text: usize,
    s_refused: wire.RefuseCode,
};

/// Window side: a page hosted on another node — the dialed session and
/// its buffer, and what the broker owes the page.
pub const Remote = struct {
    chan: u64 = 0,
    node: u64 = 0,
    buf_va: u64 = 0,
    buf_len: usize = 0,
    page_id: u64 = 0,
    key: u64 = 0,
    feed: Feed = .none,
    feed_text: [4096]u8 = undefined,
    /// The page asked for a chunk of this many bytes.
    want_read: ?u64 = null,
    /// The relay said more waits: poll again at once.
    more: bool = false,
    /// The pump is between the call and its reply: a destroy then waits
    /// for it (`closing`), since two calls on one session would race on
    /// its buffer.
    in_call: bool = false,
    closing: bool = false,
    dead: bool = false,

    fn buf(r: *const Remote) []u8 {
        return @as([*]u8, @ptrFromInt(r.buf_va))[0..r.buf_len];
    }
};

/// A broker client's state: the resource it has open and the
/// connection it parks between requests. A page has one; a script
/// domain lent the network has one.
pub const Client = struct {
    open: ?Resource = null,
    /// A connection kept open after a response that allowed it, for the
    /// next request to the same host (a site's pictures came one fresh
    /// TLS handshake each, ~400 ms under emulation, 2026-09-23).
    kept: ?Conn = null,
    /// The parked connection's scheme|host|port — written when a
    /// connection opens (it is the resource's until `finish` parks it),
    /// so a reuse test always pairs with `kept != null`.
    kept_key: [conn_key_max]u8 = undefined,
    kept_key_len: usize = 0,
    kept_ms: u64 = 0,
};

/// An event of a remote page, posted by the pump for `step`; `kind`
/// null means the page died.
const Posted = struct { page: PageId, kind: ?wire.Event, a: u64, b: u64 };

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
    /// The URL being opened (redirects rewrite it), the broker's copy.
    url_buf: [2048]u8 = undefined,
    /// A script request's origin, copied out of the page's buffer.
    origin_buf: [512]u8 = undefined,
    /// Per-origin storage for every page of this host (`localStorage`):
    /// records of (origin, key, value), one per live key, in one buffer;
    /// an origin may hold `storage_quota` bytes of keys and values. Held
    /// while the host lives — a browser's pages share it, a headless
    /// render's too.
    storage: [storage_bytes]u8 = undefined,
    storage_len: usize = 0,
    /// Where the storage persists (a view and a directory under it), or
    /// 0: memory only. Origins are loaded on first touch and written on
    /// every change, one file per origin named by a hash of the origin.
    store_view: u64 = 0,
    store_buf: [*]u8 = undefined,
    store_dir: [128]u8 = undefined,
    store_dir_len: usize = 0,
    store_dir_made: bool = false,
    loaded: [32]u64 = @splat(0),
    n_loaded: usize = 0,
    lock: Lock = .{},
    scratch: [head_max + request_max]u8 = undefined,
    /// Relay mode: pages are served here for windows on other nodes
    /// (the `webnode` service); their opens, reads and storage are
    /// recorded for the window's broker instead of fetched.
    relay: bool = false,
    next_key: u64 = 0x5eed_0f_a_b1e,
    /// LZ4 scratch for the pixel pieces (rows gathered or decoded, then
    /// the packed bytes), mapped when a host first relays or hosts a
    /// remote page — never static: every mshrun carries two hosts, and
    /// the statics of the first cut took the image past the 8 MB a
    /// script unit spawns under (2026-10-06). Pieces are made and taken
    /// under the lock, so one set per host.
    lz_tbl: mosslib.lz4.EncTable = undefined,
    lz_va: u64 = 0,
    /// Window side: the thread that polls the remote pages, started
    /// with the first one, on a stack mapped then (the broker's TLS
    /// handshakes run on it: over 120 KB) and kept for the host's life.
    pump_up: bool = false,
    pump_stack_va: u64 = 0,
    /// What the pump heard from the remote pages, for `step` to hand to
    /// the host program as it hands a local page's events (a thread
    /// cannot call a channel its own domain serves, so the pump cannot
    /// speak as the page would): a queue, and a notification bound to
    /// the serving thread that interrupts its receive.
    notif: u64 = 0,
    bound: bool = false,
    posted: [64]Posted = undefined,
    posted_head: usize = 0,
    posted_tail: usize = 0,

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
        const n = usys.notifyCreate();
        if (n.err == .ok) h.notif = n.data[0];
        return true;
    }

    /// Persist the pages' storage under `dir` of `view` (the session's
    /// home): what is there is read as an origin is first touched, and
    /// every change is written back.
    pub fn setStorageDir(h: *Host, view: u64, buf: [*]u8, dir: []const u8) void {
        h.store_view = view;
        h.store_buf = buf;
        h.store_dir_len = @min(dir.len, h.store_dir.len);
        @memcpy(h.store_dir[0..h.store_dir_len], dir[0..h.store_dir_len]);
    }

    fn storePath(h: *Host, origin: []const u8, buf: []u8) ?[]const u8 {
        const hash = std.hash.Wyhash.hash(0, origin);
        return std.fmt.bufPrint(buf, "{s}/{x:0>16}.dat", .{ h.store_dir[0..h.store_dir_len], hash }) catch null;
    }

    /// The origin's file into the buffer, once per host life.
    fn storageLoad(h: *Host, origin: []const u8) void {
        if (h.store_view == 0) return;
        const hash = std.hash.Wyhash.hash(0, origin);
        for (h.loaded[0..h.n_loaded]) |x| if (x == hash) return;
        if (h.n_loaded < h.loaded.len) {
            h.loaded[h.n_loaded] = hash;
            h.n_loaded += 1;
        }
        var pbuf: [192]u8 = undefined;
        const path = h.storePath(origin, &pbuf) orelse return;
        const dst = h.storage[h.storage_len..];
        const got = fsc.readWhole(h.store_view, h.store_buf, path, dst) orelse return;
        // Only whole records of this origin, none already present.
        var at: usize = 0;
        var kept: usize = 0;
        while (at + Rec.head <= got.len) {
            const r = got[at..];
            const size = Rec.size(r);
            if (at + size > got.len) break;
            if (!std.mem.eql(u8, Rec.origin(r[0..size]), origin) or h.storageFind(origin, Rec.key(r[0..size])) != null) {
                at += size;
                continue;
            }
            if (kept != at) std.mem.copyForwards(u8, dst[kept .. kept + size], got[at .. at + size]);
            kept += size;
            h.storage_len += size;
            at += size;
        }
        logf(h.log, "webhost: storage: loaded {s} ({d} bytes)", .{ origin, kept });
    }

    /// The origin's records to its file (rewritten whole).
    fn storageSave(h: *Host, origin: []const u8) void {
        if (h.store_view == 0) return;
        if (!h.store_dir_made) {
            _ = fsc.fsMkdir(h.store_view, h.store_buf, h.store_dir[0..h.store_dir_len]);
            h.store_dir_made = true;
        }
        var pbuf: [192]u8 = undefined;
        const path = h.storePath(origin, &pbuf) orelse return;
        const fd = switch (fsc.fsOpen(h.store_view, h.store_buf, path, 1)) {
            .fd => |fd| fd,
            .err => |e| {
                logf(h.log, "webhost: storage: cannot open {s}: {s}", .{ path, @tagName(e) });
                return;
            },
        };
        defer fsc.fsClose(h.store_view, fd);
        _ = fsc.fsTruncate(h.store_view, fd, 0);
        var off: u64 = 0;
        var at: usize = 0;
        while (at < h.storage_len) {
            const r = h.storage[at..h.storage_len];
            const size = Rec.size(r);
            if (std.mem.eql(u8, Rec.origin(r), origin)) {
                if (!fsc.fsWriteAt(h.store_view, h.store_buf, fd, off, r[0..size])) {
                    logf(h.log, "webhost: storage: writing {s} failed", .{path});
                    return;
                }
                off += size;
            }
            at += size;
        }
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
        var p2: [64]u8 = undefined;
        // Sans, mono, then the fallback for Han, kana and Hangul.
        const files = [_][]const u8{
            std.fmt.bufPrint(&p0, "{s}fonts/IBMPlexSans.ttf", .{prefix}) catch return false,
            std.fmt.bufPrint(&p1, "{s}fonts/IBMPlexMono-Regular.ttf", .{prefix}) catch return false,
            std.fmt.bufPrint(&p2, "{s}fallback/DroidSansFallbackFull.ttf", .{prefix}) catch return false,
        };
        const pages: u64 = 1200; // 4.7 MB: the faces are 673 KB + 4.0 MB
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
        if (!h.pageBuffers(p)) {
            h.destroyLocked(@intCast(idx));
            return null;
        }
        return @intCast(idx);
    }

    /// A page's data buffer and, for a `w` × `h` viewport, its pixel
    /// buffer (and in relay mode the shadow of the frame the window last
    /// got). False when memory refused; what was made is the caller's to
    /// drop with the page.
    fn pageBuffers(h: *Host, p: *Page) bool {
        if (p.data_va == 0) {
            const d = usys.shmCreate(wire.data_pages);
            if (d.err != .ok) return false;
            const dm = usys.shmMap(d.data[0]);
            if (dm.err != .ok) {
                _ = usys.capDrop(d.data[0]);
                return false;
            }
            p.data_shm = d.data[0];
            p.data_va = dm.data[0];
            p.data_len = dm.data[1] * 4096;
        }
        if (p.w > 0 and p.h > 0) {
            const pages = (@as(u64, p.w) * p.h * 4 + 4095) / 4096;
            const s = usys.shmCreate(pages);
            if (s.err != .ok) return false;
            const m = usys.shmMap(s.data[0]);
            if (m.err != .ok) {
                _ = usys.capDrop(s.data[0]);
                return false;
            }
            p.px_shm = s.data[0];
            p.px_va = m.data[0];
            if (h.relay) {
                const sh = usys.shmCreate(pages);
                if (sh.err != .ok) return false;
                const sm = usys.shmMap(sh.data[0]);
                _ = usys.capDrop(sh.data[0]); // the mapping keeps its own ref
                if (sm.err != .ok) return false;
                p.shadow_va = sm.data[0];
                p.shadow_len = pages * 4096;
            }
        }
        return true;
    }

    /// Give a page a new viewport: a fresh pixel buffer of `w` × `h`
    /// (none for 0 × 0, a hidden page), the old one let go here — the
    /// page unmaps its side when it takes the `resize` command and asks
    /// for the new buffer.
    pub fn resize(h: *Host, id: PageId, w: u32, height: u32) bool {
        h.lock.acquire();
        defer h.lock.release();
        return h.resizeLocked(id, w, height);
    }

    fn resizeLocked(h: *Host, id: PageId, w: u32, height: u32) bool {
        const p = &h.pages[id];
        if (!p.used or p.dead) return false;
        if (p.w == w and p.h == height) return true;
        if (p.px_va != 0) _ = usys.shmUnmap(p.px_va);
        if (p.px_shm != 0) _ = usys.capDrop(p.px_shm);
        if (p.shadow_va != 0) _ = usys.shmUnmap(p.shadow_va);
        p.px_va = 0;
        p.px_shm = 0;
        p.shadow_va = 0;
        p.shadow_len = 0;
        p.dmg = null;
        p.w = w;
        p.h = height;
        if (!h.pageBuffers(p)) return false;
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
        h.brokerCancel(&p.client);
        h.dropParked(&p.client);
        if (p.remote) |*r| {
            // The pump is mid-call on the session: it closes the page
            // when the reply comes (the slot stays taken until then).
            if (r.in_call) {
                r.closing = true;
                return;
            }
            h.remoteClose(id);
            return;
        }
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
        if (p.shadow_va != 0) _ = usys.shmUnmap(p.shadow_va);
        if (p.twin_va != 0) _ = usys.shmUnmap(p.twin_va);
        if (p.out_va != 0) _ = usys.shmUnmap(p.out_va);
        if (p.ctl != 0) _ = usys.capDrop(p.ctl);
        p.* = .{};
    }

    pub fn deinit(h: *Host) void {
        h.lock.acquire();
        for (0..max_pages) |i| h.destroyLocked(@intCast(i));
        h.lock.release();
        if (h.fonts_va != 0) _ = usys.shmUnmap(h.fonts_va);
        if (h.fonts_shm != 0) _ = usys.capDrop(h.fonts_shm);
        if (h.lz_va != 0) _ = usys.shmUnmap(h.lz_va);
        h.lz_va = 0;
        // The pump's stack stays: its thread may be running on it.
        if (h.chan_b != 0) _ = usys.capDrop(h.chan_b);
        if (h.chan != 0) _ = usys.capDrop(h.chan);
        if (h.notif != 0) _ = usys.capDrop(h.notif);
        h.* = .{ .log = h.log, .spawner = h.spawner, .net = h.net };
    }

    pub fn page(h: *Host, id: PageId) *Page {
        return &h.pages[id];
    }

    /// Map `pages` pages for the host's life (a buffer, a stack).
    fn mapPages(pages: u64) u64 {
        const sh = usys.shmCreate(pages);
        if (sh.err != .ok) return 0;
        const m = usys.shmMap(sh.data[0]);
        _ = usys.capDrop(sh.data[0]); // the mapping keeps its own ref
        return if (m.err == .ok) m.data[0] else 0;
    }

    fn ensureLz(h: *Host) bool {
        if (h.lz_va == 0) h.lz_va = mapPages((2 * lz_max + 4095) / 4096);
        return h.lz_va != 0;
    }
    fn lzIn(h: *Host) []u8 {
        return @as([*]u8, @ptrFromInt(h.lz_va))[0..lz_max];
    }
    fn lzOut(h: *Host) []u8 {
        return @as([*]u8, @ptrFromInt(h.lz_va))[lz_max .. 2 * lz_max];
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
        // Input the page has not taken yet folds together: scrolls add up
        // and a pointer move replaces the move before it — a wheel under a
        // slow repaint filled the queue and dropped what came after
        // (2026-09-23).
        if (cmd == .scroll or (cmd == .pointer and cmd.pointer.kind == .move) or cmd == .idle or cmd == .tick) {
            var i = p.qlen;
            while (i > 0) {
                i -= 1;
                const q = &p.queue[i].cmd;
                if (cmd == .scroll and q.* == .scroll) {
                    q.scroll += cmd.scroll;
                    return true;
                }
                if (cmd == .pointer and q.* == .pointer and q.pointer.kind == .move) {
                    q.* = cmd;
                    return true;
                }
                if (cmd == .idle and q.* == .idle) return true;
                if (cmd == .tick and q.* == .tick) return true;
                // Anything else in between — a press, a load, a resize, a
                // key — keeps its place: input folds only across input
                // that folds.
                if (q.* != .scroll and q.* != .idle and q.* != .tick and !(q.* == .pointer and q.pointer.kind == .move)) break;
            }
        }
        if (p.qlen == p.queue.len) {
            logf(h.log, "webhost: page {d}: command queue full; {s} dropped", .{ id, @tagName(cmd) });
            return false;
        }
        // A command's text lives in the page's slot for its kind, not in
        // the caller's memory; a newer load or find supersedes a queued
        // one, which leaves the queue.
        var stored = cmd;
        if (cmd == .load or cmd == .find or cmd == .dump) {
            const slot: usize = if (cmd == .load) 0 else if (cmd == .find) 1 else 2;
            const text = if (cmd == .load) cmd.load else if (cmd == .find) cmd.find.text else cmd.dump.select;
            var i: usize = 0;
            while (i < p.qlen) {
                if (std.meta.activeTag(p.queue[i].cmd) == std.meta.activeTag(cmd)) {
                    for (i + 1..p.qlen) |j| p.queue[j - 1] = p.queue[j];
                    p.qlen -= 1;
                } else i += 1;
            }
            p.text_len[slot] = @min(text.len, p.texts[slot].len);
            @memcpy(p.texts[slot][0..p.text_len[slot]], text[0..p.text_len[slot]]);
            stored = if (cmd == .load) .{ .load = "" } else if (cmd == .find) .{ .find = .{ .text = "", .index = cmd.find.index } } else .{ .dump = .{ .what = cmd.dump.what, .select = "" } };
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
            .dump => |d| blk: {
                const text = p.texts[2][0..p.text_len[2]];
                const n = @min(text.len, p.data_len);
                @memcpy(p.data()[0..n], text[0..n]);
                break :blk .{ .dump = .{ .what = @intFromEnum(d.what), .len = n } };
            },
            .resize => |r| .{ .resize = .{ .w = r.w, .h = r.h } },
            .find => |f| blk: {
                const text = p.texts[1][0..p.text_len[1]];
                const n = @min(text.len, p.data_len);
                @memcpy(p.data()[0..n], text[0..n]);
                break :blk .{ .find = .{ .len = n, .index = f.index } };
            },
            .zoom => |z| .{ .zoom = .{ .percent = z } },
            .theme => |t| .{ .theme = .{ .flags = t } },
            .idle => .idle,
            .tick => .tick,
            .scripts => |on| .{ .scripts = .{ .on = if (on) 1 else 0 } },
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

    /// Serve one message from any page — or hand over what the pump
    /// posted for a remote page, which the pump's notification wakes
    /// this thread for.
    pub fn step(h: *Host) Step {
        if (h.takePosted()) |e| return e;
        var live = false;
        for (h.pages) |p| if (p.used and !p.dead) {
            live = true;
        };
        if (!live) return .idle;
        if (!h.bound and h.notif != 0) {
            // Bound to this thread, the serving one: `step` runs here only.
            h.bound = usys.notifyBind(h.notif) == .ok;
        }
        const r = usys.recvMsg(h.chan);
        if (r.err == .interrupted) {
            _ = usys.notifyWait(h.notif); // take the bits
            return h.takePosted() orelse .{ .served = 0 };
        }
        h.lock.acquire();
        defer h.lock.release();
        if (r.err == .client_dead) {
            const id = h.byBadge(r.badge) orelse return .stale;
            logf(h.log, "webhost: page {d} died (badge {d})", .{ id, r.badge });
            h.pages[id].dead = true;
            h.brokerCancel(&h.pages[id].client);
            h.dropParked(&h.pages[id].client); // a dead page keeps no socket open
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
            .open => |o| if (h.relay) h.relayOpen(id, o.off, o.len, o.flags) else h.open(id, o.off, o.len, o.flags),
            .read => |rd| if (h.relay) h.relayRead(p, rd.max) else h.read(id, rd.max),
            .cancel => {
                if (h.relay) _ = h.outPut(p, .cancel, "", "") else h.brokerCancel(&p.client);
                h.reply(.ok, 0);
            },
            .storage => |s| if (h.relay) h.relayStorage(p, s.op, s.key_len, s.value_len) else h.storageReq(p, s.op, s.key_len, s.value_len),
            .event => |e| {
                const kind = std.enums.fromInt(wire.Event, e.kind) orelse {
                    h.reply(.ok, 0);
                    return .{ .served = id };
                };
                h.noteEvent(p, kind, e.a, e.b);
                // In relay mode a dump holds the page's call until the
                // text has streamed to the window.
                if (!(h.relay and h.relayEvent(p, kind, e.a, e.b))) h.reply(.ok, 0);
                return .{ .event = .{ .page = id, .kind = kind, .a = e.a, .b = e.b } };
            },
        }
        return .{ .served = id };
    }

    // ------------------------------------------------------- storage

    /// A record: origin, key and value lengths, then the three texts.
    const Rec = struct {
        const head = 8;
        fn olen(b: []const u8) usize {
            return std.mem.readInt(u16, b[0..2], .little);
        }
        fn klen(b: []const u8) usize {
            return std.mem.readInt(u16, b[2..4], .little);
        }
        fn vlen(b: []const u8) usize {
            return std.mem.readInt(u32, b[4..8], .little);
        }
        fn size(b: []const u8) usize {
            return head + olen(b) + klen(b) + vlen(b);
        }
        fn origin(b: []const u8) []const u8 {
            return b[head .. head + olen(b)];
        }
        fn key(b: []const u8) []const u8 {
            return b[head + olen(b) .. head + olen(b) + klen(b)];
        }
        fn value(b: []const u8) []const u8 {
            const o = head + olen(b) + klen(b);
            return b[o .. o + vlen(b)];
        }
    };

    /// The record for (origin, key): its offset, or null.
    fn storageFind(h: *Host, origin: []const u8, key: []const u8) ?usize {
        var at: usize = 0;
        while (at < h.storage_len) {
            const r = h.storage[at..h.storage_len];
            if (std.mem.eql(u8, Rec.origin(r), origin) and std.mem.eql(u8, Rec.key(r), key)) return at;
            at += Rec.size(r);
        }
        return null;
    }

    fn storageDrop(h: *Host, at: usize) void {
        const n = Rec.size(h.storage[at..h.storage_len]);
        std.mem.copyForwards(u8, h.storage[at .. h.storage_len - n], h.storage[at + n .. h.storage_len]);
        h.storage_len -= n;
    }

    /// Bytes of keys and values the origin holds.
    fn storageUsed(h: *Host, origin: []const u8) usize {
        var used: usize = 0;
        var at: usize = 0;
        while (at < h.storage_len) {
            const r = h.storage[at..h.storage_len];
            if (std.mem.eql(u8, Rec.origin(r), origin)) used += Rec.klen(r) + Rec.vlen(r);
            at += Rec.size(r);
        }
        return used;
    }

    /// The `n`th key of the origin, in record order.
    fn storageKeyAt(h: *Host, origin: []const u8, n: usize) ?[]const u8 {
        var i: usize = 0;
        var at: usize = 0;
        while (at < h.storage_len) {
            const r = h.storage[at..h.storage_len];
            if (std.mem.eql(u8, Rec.origin(r), origin)) {
                if (i == n) return Rec.key(r);
                i += 1;
            }
            at += Rec.size(r);
        }
        return null;
    }

    /// The page's origin, from the URL it reported (the host's truth,
    /// not the page's word), into `buf`.
    fn pageOrigin(p: *Page, buf: []u8) ?[]const u8 {
        var fba = std.heap.FixedBufferAllocator.init(buf);
        const u = web.url.parse(fba.allocator(), p.urlText(), null) catch return null;
        const o = u.origin(fba.allocator()) catch return null;
        if (std.mem.eql(u8, o, "null")) return null;
        return o;
    }

    fn storageReq(h: *Host, p: *Page, op_raw: u64, key_len_raw: u64, value_len_raw: u64) void {
        const d = p.data();
        var obuf: [1024]u8 = undefined;
        const origin = pageOrigin(p, &obuf);
        const key_len: usize = @intCast(@min(key_len_raw, d.len));
        const value_len: usize = @intCast(@min(value_len_raw, d.len - key_len));
        const key_at = op_raw == @intFromEnum(wire.StorageOp.key_at);
        // The key and value are copied out: the buffer carries the answer.
        var kv: [4096]u8 = undefined;
        if (!key_at and key_len + value_len > kv.len) return h.refuse(.quota);
        const key: []const u8 = if (key_at) "" else blk: {
            @memcpy(kv[0..key_len], d[0..key_len]);
            break :blk kv[0..key_len];
        };
        const value: []const u8 = if (key_at) "" else blk: {
            @memcpy(kv[key_len .. key_len + value_len], d[key_len .. key_len + value_len]);
            break :blk kv[key_len .. key_len + value_len];
        };
        switch (h.storageOp(origin, op_raw, key_len_raw, key, value, d)) {
            .ok => h.reply(.ok, 0),
            .none => h.reply(.none, 0),
            .count => |n| h.reply(.{ .count = .{ .n = n } }, 0),
            .text => |n| h.reply(.{ .text = .{ .len = n } }, 0),
            .refused => |code| h.refuse(code),
        }
    }

    pub const StorageOut = union(enum) { ok, none, count: u64, text: usize, refused: wire.RefuseCode };

    /// One `localStorage` operation for `origin` (null: no origin, so
    /// refused): the answer, with a value or key written to `out`. The
    /// page's path and the relay's share it (a remote page's storage is
    /// the window's, like its network).
    fn storageOp(h: *Host, origin_opt: ?[]const u8, op_raw: u64, key_len_raw: u64, key: []const u8, value: []const u8, out: []u8) StorageOut {
        const origin = origin_opt orelse return .{ .refused = .policy };
        const op = std.enums.fromInt(wire.StorageOp, op_raw) orelse return .{ .refused = .bad_url };
        h.storageLoad(origin);
        switch (op) {
            .get => {
                const at = h.storageFind(origin, key) orelse return .none;
                const v = Rec.value(h.storage[at..h.storage_len]);
                const n = @min(v.len, out.len);
                @memcpy(out[0..n], v[0..n]);
                return .{ .text = n };
            },
            .set => {
                if (origin.len > 0xffff or key.len > 0xffff) return .{ .refused = .quota };
                if (h.storageFind(origin, key)) |at| h.storageDrop(at);
                if (h.storageUsed(origin) + key.len + value.len > storage_quota) return .{ .refused = .quota };
                const size = Rec.head + origin.len + key.len + value.len;
                if (h.storage_len + size > h.storage.len) return .{ .refused = .quota };
                const r = h.storage[h.storage_len .. h.storage_len + size];
                std.mem.writeInt(u16, r[0..2], @intCast(origin.len), .little);
                std.mem.writeInt(u16, r[2..4], @intCast(key.len), .little);
                std.mem.writeInt(u32, r[4..8], @intCast(value.len), .little);
                @memcpy(r[Rec.head .. Rec.head + origin.len], origin);
                @memcpy(r[Rec.head + origin.len .. Rec.head + origin.len + key.len], key);
                @memcpy(r[Rec.head + origin.len + key.len ..], value);
                h.storage_len += size;
                h.storageSave(origin);
                return .ok;
            },
            .remove => {
                if (h.storageFind(origin, key)) |at| {
                    h.storageDrop(at);
                    h.storageSave(origin);
                }
                return .ok;
            },
            .clear => {
                var at: usize = 0;
                while (at < h.storage_len) {
                    const r = h.storage[at..h.storage_len];
                    if (std.mem.eql(u8, Rec.origin(r), origin)) h.storageDrop(at) else at += Rec.size(r);
                }
                h.storageSave(origin);
                return .ok;
            },
            .key_at => {
                const k = h.storageKeyAt(origin, @intCast(key_len_raw)) orelse return .none;
                const n = @min(k.len, out.len);
                @memcpy(out[0..n], k[0..n]);
                return .{ .text = n };
            },
            .length => {
                var n: u64 = 0;
                var at: usize = 0;
                while (at < h.storage_len) {
                    const r = h.storage[at..h.storage_len];
                    if (std.mem.eql(u8, Rec.origin(r), origin)) n += 1;
                    at += Rec.size(r);
                }
                return .{ .count = n };
            },
        }
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
            .want_idle => {}, // the host's runtime answers it, not the record
            .wake => p.wake_at = usys.nowMs() + a,
        }
    }

    /// The clock the pages cannot hold: every page whose wake is due gets
    /// a `tick`. A host's loop calls this on its own tick.
    pub fn tickWakes(h: *Host) void {
        h.lock.acquire();
        defer h.lock.release();
        const now = usys.nowMs();
        for (&h.pages, 0..) |*p, i| {
            if (!p.used or p.dead) continue;
            const at = p.wake_at orelse continue;
            if (at > now) continue;
            p.wake_at = null;
            _ = h.sendLocked(@intCast(i), .tick);
        }
    }

    /// How long until the page's wake is due (0 = now), or null with none
    /// asked for.
    pub fn wakeDelay(h: *Host, id: PageId) ?u64 {
        h.lock.acquire();
        defer h.lock.release();
        const at = h.pages[id].wake_at orelse return null;
        const now = usys.nowMs();
        return if (at > now) at - now else 0;
    }

    // ------------------------------------------------- the relay (node 2)
    //
    // Relay mode: this host runs pages for a window on another node.
    // The page's calls are served as ever — its buffers are local, its
    // `next` parks here — but an open, a read or a storage operation is
    // recorded for the window's broker and the page's call is held
    // until the window answers; events and repainted rows are recorded
    // too, and the window's polls take them (`relayPump`).

    fn outPut(h: *Host, p: *Page, tag: wire.Rec, a: []const u8, b: []const u8) bool {
        _ = h;
        var w: wire.RecWriter = .{ .buf = p.outBuf(), .len = p.out_len };
        if (!w.put2(tag, a, b)) return false;
        p.out_len = w.len;
        return true;
    }

    fn relayOpen(h: *Host, id: PageId, off: u64, len: u64, flags: u64) void {
        const p = &h.pages[id];
        const d = p.data();
        if (off > d.len or len > d.len - off or len == 0 or len > 0xffff) return h.refuse(.bad_url);
        const body_len: usize = @intCast(@min((flags >> 8) & 0xffffff, h.body.len));
        const origin_len: usize = @intCast(@min((flags >> 32) & 0xffff, h.origin_buf.len));
        if (off + len + body_len + origin_len > d.len) return h.refuse(.bad_url);
        var head: [12]u8 = undefined;
        wire.putU64(head[0..8], flags);
        wire.putU16(head[8..10], len);
        wire.putU16(head[10..12], body_len);
        if (!h.outPut(p, .open, &head, d[off .. off + len + body_len + origin_len])) return h.refuse(.busy);
        p.pending = .open;
        p.pending_token = h.cur_token;
    }

    fn relayRead(h: *Host, p: *Page, max: u64) void {
        var head: [4]u8 = undefined;
        wire.putU32(&head, @min(max, p.data_len));
        if (!h.outPut(p, .read, &head, "")) return h.chunkReply(0, .failed);
        p.pending = .read;
        p.pending_token = h.cur_token;
    }

    fn relayStorage(h: *Host, p: *Page, op_raw: u64, key_len_raw: u64, value_len_raw: u64) void {
        const d = p.data();
        const key_at = op_raw == @intFromEnum(wire.StorageOp.key_at);
        const key_len: usize = if (key_at) 0 else @intCast(@min(key_len_raw, d.len));
        const value_len: usize = if (key_at) 0 else @intCast(@min(value_len_raw, d.len - key_len));
        var head: [7]u8 = undefined;
        head[0] = @intCast(op_raw & 0xff);
        wire.putU32(head[1..5], key_len_raw);
        wire.putU16(head[5..7], key_len);
        if (!h.outPut(p, .storage, &head, d[0 .. key_len + value_len])) return h.refuse(.busy);
        p.pending = .storage;
        p.pending_token = h.cur_token;
    }

    /// Relay mode: what the page reported, as a record for the window.
    /// True when the page's call stays open (a dump streams first).
    fn relayEvent(h: *Host, p: *Page, kind: wire.Event, a: u64, b: u64) bool {
        const d = p.data();
        switch (kind) {
            .commit => {
                // The page commits its whole viewport; the rows that
                // changed are found against the shadow as they ship.
                p.dmg = .{ .x = 0, .y = 0, .w = p.w, .h = p.h };
                p.dmg_row = 0;
                return false;
            },
            .dumped => {
                p.dump_off = 0;
                p.pending = .dump;
                p.pending_token = h.cur_token;
                return true;
            },
            else => {},
        }
        const n: usize = switch (kind) {
            .title, .url, .hover, .selection, .focus => @intCast(@min(a, d.len)),
            .download => @intCast(@min(a + b, d.len)),
            else => 0,
        };
        var head: [17]u8 = undefined;
        head[0] = @intCast(@intFromEnum(kind));
        wire.putU64(head[1..9], a);
        wire.putU64(head[9..17], b);
        if (!h.outPut(p, .event, &head, d[0..n])) logf(h.log, "webhost: page {d}: event {s} dropped (the window has not polled)", .{ p.badge, @tagName(kind) });
        return false;
    }

    /// The window's session buffer arrived with its `hello`: map it as
    /// the page's twin and mint the page's key. False: the page dies.
    pub fn relayAttach(h: *Host, id: PageId, twin_cap: u64) ?u64 {
        h.lock.acquire();
        defer h.lock.release();
        const p = &h.pages[id];
        const m = usys.shmMap(twin_cap);
        _ = usys.capDrop(twin_cap);
        if (m.err != .ok) return null;
        p.twin_va = m.data[0];
        p.twin_len = m.data[1] * 4096;
        if (p.out_va == 0) p.out_va = mapPages(out_bytes / 4096);
        if (p.out_va == 0 or !h.ensureLz()) return null;
        h.next_key = (h.next_key ^ usys.nowMs()) *% 0x9E37_79B9_7F4A_7C15 +% p.badge;
        p.key = h.next_key | 1;
        p.last_pump_ms = usys.nowMs();
        return p.key;
    }

    /// Relay mode: one poll from the window — its records applied (the
    /// commands, the broker's answers), then the twin filled with what
    /// the page produced. Null for a page that is not this window's.
    pub const Drained = struct { len: usize, more: bool };

    pub fn relayPump(h: *Host, id: PageId, key: u64, in_len: u64) ?Drained {
        h.lock.acquire();
        defer h.lock.release();
        if (id >= max_pages) return null;
        const p = &h.pages[id];
        if (!p.used or p.key != key or p.twin_va == 0) return null;
        p.last_pump_ms = usys.nowMs();
        const twin = @as([*]u8, @ptrFromInt(p.twin_va))[0..p.twin_len];
        h.relayApply(id, twin[0..@min(in_len, twin.len)]);
        if (p.dead) {
            // The page died: the window hears it as an event and reaps.
            var head: [17]u8 = undefined;
            head[0] = @intFromEnum(wire.Event.load);
            wire.putU64(head[1..9], @intFromEnum(wire.LoadState.failed));
            wire.putU64(head[9..17], @intFromEnum(wire.RefuseCode.memory));
            var w: wire.RecWriter = .{ .buf = twin };
            _ = w.put(.event, &head);
            return .{ .len = w.len, .more = false };
        }
        return h.relayDrain(id);
    }

    pub fn relayBye(h: *Host, id: PageId, key: u64) bool {
        h.lock.acquire();
        defer h.lock.release();
        if (id >= max_pages) return false;
        const p = &h.pages[id];
        if (!p.used or p.key != key) return false;
        h.destroyLocked(id);
        return true;
    }

    /// Relay mode: pages whose window stopped polling are destroyed; the
    /// count destroyed.
    pub fn relayStale(h: *Host) usize {
        h.lock.acquire();
        defer h.lock.release();
        const now = usys.nowMs();
        var n: usize = 0;
        for (&h.pages, 0..) |*p, i| {
            if (!p.used or p.twin_va == 0) continue;
            if (now - p.last_pump_ms < relay_stale_ms) continue;
            logf(h.log, "webhost: page {d}: its window stopped polling; destroyed", .{i});
            h.destroyLocked(@intCast(i));
            n += 1;
        }
        return n;
    }

    /// Relay mode: the window's records — commands for the page, and the
    /// broker's answers to what the page asked (which release its call).
    fn relayApply(h: *Host, id: PageId, bytes: []const u8) void {
        const p = &h.pages[id];
        var r: wire.RecReader = .{ .buf = bytes };
        while (r.next()) |rec| {
            const pl = rec.payload;
            switch (rec.tag) {
                .load => _ = h.sendLocked(id, .{ .load = pl }),
                .scroll => if (pl.len >= 8) {
                    _ = h.sendLocked(id, .{ .scroll = @bitCast(wire.getU64(pl)) });
                },
                .pointer => if (pl.len >= 5) {
                    _ = h.sendLocked(id, .{ .pointer = .{ .kind = std.enums.fromInt(wire.PointerKind, pl[0]) orelse .move, .x = @intCast(wire.getU16(pl[1..])), .y = @intCast(wire.getU16(pl[3..])) } });
                },
                .key => if (pl.len >= 8) {
                    _ = h.sendLocked(id, .{ .key = .{ .code = @intCast(wire.getU32(pl)), .ch = @intCast(wire.getU32(pl[4..])) } });
                },
                .dump => if (pl.len >= 1) {
                    _ = h.sendLocked(id, .{ .dump = .{ .what = std.enums.fromInt(wire.Dump, pl[0]) orelse .html, .select = pl[1..] } });
                },
                .resize => if (pl.len >= 4) {
                    _ = h.resizeLocked(id, @intCast(wire.getU16(pl)), @intCast(wire.getU16(pl[2..])));
                },
                .find => if (pl.len >= 4) {
                    _ = h.sendLocked(id, .{ .find = .{ .text = pl[4..], .index = @intCast(wire.getU32(pl)) } });
                },
                .zoom => if (pl.len >= 2) {
                    _ = h.sendLocked(id, .{ .zoom = @intCast(wire.getU16(pl)) });
                },
                .theme => if (pl.len >= 8) {
                    _ = h.sendLocked(id, .{ .theme = wire.getU64(pl) });
                },
                .idle => _ = h.sendLocked(id, .idle),
                .tick => _ = h.sendLocked(id, .tick),
                .scripts => if (pl.len >= 1) {
                    _ = h.sendLocked(id, .{ .scripts = pl[0] != 0 });
                },
                .stop => _ = h.sendLocked(id, .stop),
                .opened => if (p.pending == .open and pl.len >= 4) {
                    const d = p.data();
                    const status = wire.getU16(pl);
                    const url_len: usize = @intCast(@min(wire.getU16(pl[2..]), pl.len - 4));
                    const url = pl[4 .. 4 + url_len];
                    const ct = pl[4 + url_len ..];
                    const un = @min(url.len, d.len);
                    @memcpy(d[0..un], url[0..un]);
                    const cn = @min(ct.len, d.len - un);
                    @memcpy(d[un .. un + cn], ct[0..cn]);
                    h.relayAnswer(p, .{ .opened = .{ .status = status, .url_len = un, .type_len = cn } });
                },
                .refused => if ((p.pending == .open or p.pending == .read) and pl.len >= 1) {
                    h.relayAnswer(p, .{ .refused = .{ .code = pl[0] } });
                },
                .chunk => if (p.pending == .read and pl.len >= 1) {
                    const d = p.data();
                    const n = @min(pl.len - 1, d.len);
                    @memcpy(d[0..n], pl[1 .. 1 + n]);
                    h.relayAnswer(p, .{ .chunk = .{ .len = n, .done = pl[0] } });
                },
                .s_ok => if (p.pending == .storage) h.relayAnswer(p, .ok),
                .s_none => if (p.pending == .storage) h.relayAnswer(p, .none),
                .s_count => if (p.pending == .storage and pl.len >= 4) h.relayAnswer(p, .{ .count = .{ .n = wire.getU32(pl) } }),
                .s_text => if (p.pending == .storage) {
                    const d = p.data();
                    const n = @min(pl.len, d.len);
                    @memcpy(d[0..n], pl[0..n]);
                    h.relayAnswer(p, .{ .text = .{ .len = n } });
                },
                .s_refused => if (p.pending == .storage and pl.len >= 1) h.relayAnswer(p, .{ .refused = .{ .code = pl[0] } }),
                else => {},
            }
        }
    }

    fn relayAnswer(h: *Host, p: *Page, rep: wire.HostResp) void {
        p.pending = .none;
        _ = usys.replyTypedTo(wire.HostResp, h.chan, rep, 0, p.pending_token);
    }

    /// Relay mode: fill the window's twin with what the page produced —
    /// its records in order, a dump's text, then the viewport rows that
    /// differ from the frame the window last got, LZ4-packed. `more`
    /// when the twin filled before it all went.
    fn relayDrain(h: *Host, id: PageId) Drained {
        const p = &h.pages[id];
        var w: wire.RecWriter = .{ .buf = @as([*]u8, @ptrFromInt(p.twin_va))[0..p.twin_len] };
        // 1. The records, whole ones, in order.
        const fifo = p.outBuf();
        var r: wire.RecReader = .{ .buf = fifo[0..p.out_len] };
        var taken: usize = 0;
        while (r.next()) |rec| {
            if (!w.put(rec.tag, rec.payload)) break;
            taken = r.at;
        }
        if (taken > 0) {
            std.mem.copyForwards(u8, fifo[0 .. p.out_len - taken], fifo[taken..p.out_len]);
            p.out_len -= taken;
        }
        if (p.out_len > 0) return .{ .len = w.len, .more = true };
        // 2. A dump on its way: parts into the window's buffer, then the
        // event; the page's call is released when the last part went.
        if (p.pending == .dump) {
            const d = p.data();
            const total = @min(p.dumped_len, d.len);
            while (p.dump_off < total) {
                const n = @min(total - p.dump_off, w.room() -| 4);
                if (n == 0) return .{ .len = w.len, .more = true };
                const out = w.begin(.dump_part, 4 + n).?;
                wire.putU32(out[0..4], p.dump_off);
                @memcpy(out[4..], d[p.dump_off .. p.dump_off + n]);
                p.dump_off += n;
            }
            var head: [17]u8 = undefined;
            head[0] = @intFromEnum(wire.Event.dumped);
            wire.putU64(head[1..9], total);
            wire.putU64(head[9..17], if (p.dumped_cut) 1 else 0);
            if (!w.put(.event, &head)) return .{ .len = w.len, .more = true };
            h.relayAnswer(p, .ok);
        }
        // 3. The pixels: runs of rows that differ from the shadow.
        if (p.dmg) |dmg| {
            if (p.px_va == 0 or p.shadow_va == 0 or h.lz_va == 0 or dmg.w == 0 or dmg.x + dmg.w > p.w or dmg.y + dmg.h > p.h) {
                p.dmg = null;
            } else {
                const lz_in = h.lzIn();
                const lz_out = h.lzOut();
                const px = @as([*]const u8, @ptrFromInt(p.px_va));
                const sh = @as([*]u8, @ptrFromInt(p.shadow_va));
                const row_bytes: usize = @as(usize, dmg.w) * 4;
                const max_rows: u32 = @intCast(@max(1, lz_max / row_bytes));
                while (p.dmg_row < dmg.h) {
                    const y0: usize = dmg.y + p.dmg_row;
                    const at0 = (y0 * p.w + dmg.x) * 4;
                    if (std.mem.eql(u8, px[at0 .. at0 + row_bytes], sh[at0 .. at0 + row_bytes])) {
                        p.dmg_row += 1;
                        continue;
                    }
                    // The run of changed rows from here, up to a piece.
                    var n: u32 = 1;
                    while (n < max_rows and p.dmg_row + n < dmg.h) : (n += 1) {
                        const at = ((y0 + n) * p.w + dmg.x) * 4;
                        if (std.mem.eql(u8, px[at .. at + row_bytes], sh[at .. at + row_bytes])) break;
                    }
                    while (true) {
                        const raw = n * row_bytes;
                        for (0..n) |i| {
                            const at = ((y0 + i) * p.w + dmg.x) * 4;
                            @memcpy(lz_in[i * row_bytes .. (i + 1) * row_bytes], px[at .. at + row_bytes]);
                        }
                        const room = w.room() -| 12;
                        if (room == 0) return .{ .len = w.len, .more = true };
                        const packed_len = mosslib.lz4.compress(lz_in[0..raw], lz_out[0..@min(room, lz_out.len)], &h.lz_tbl);
                        const payload: ?[]const u8 = if (packed_len) |pl| lz_out[0..pl] else if (raw <= room) lz_in[0..raw] else null;
                        if (payload) |pl| {
                            const out = w.begin(.pixels, 12 + pl.len).?;
                            wire.putU16(out[0..2], dmg.x);
                            wire.putU16(out[2..4], y0);
                            wire.putU16(out[4..6], dmg.w);
                            wire.putU16(out[6..8], n);
                            wire.putU32(out[8..12], raw);
                            @memcpy(out[12..], pl);
                            for (0..n) |i| {
                                const at = ((y0 + i) * p.w + dmg.x) * 4;
                                @memcpy(sh[at .. at + row_bytes], lz_in[i * row_bytes .. (i + 1) * row_bytes]);
                            }
                            p.dmg_row += n;
                            break;
                        }
                        if (n == 1) return .{ .len = w.len, .more = true };
                        n = (n + 1) / 2;
                    }
                }
                p.dmg = null;
            }
        }
        return .{ .len = w.len, .more = false };
    }

    // ------------------------------------------- remote pages (node 1)
    //
    // Window side: a page hosted by a `webnode` relay on another node.
    // To this host it is a page like any other — commands queue for it,
    // its events reach the host program through `step`, its pixels sit
    // in a buffer here — except that a pump thread carries the queue to
    // the relay in polls and plays what comes back as the page would
    // have: events noted and posted for the serving thread, pixel rows
    // into the buffer, and the page's opens and reads through this
    // host's broker (the relay's node sees no network, only pixels out
    // and bytes in).

    /// Dial `node`'s relay through `fab` and spawn a page there with a
    /// `w` × `h` viewport; null with why in the log.
    pub fn spawnRemote(h: *Host, fab: u64, node: u64, w: u32, height: u32) ?PageId {
        const words = shared.strToWords(wire.relay_name);
        const chan: u64 = switch (usys.callTypedCap(shared.FabReq, shared.FabResp, fab, .{ .remote_connect = .{ .node = node, .a = words[0], .b = words[1] } }, 0)) {
            .ok => |ok| switch (ok.rep) {
                .found => ok.cap,
                .fab_err => |e| {
                    logf(h.log, "webhost: node {d}: dialing {s} refused: {s}", .{ node, wire.relay_name, @tagName(std.enums.fromInt(shared.FabErr, e.code) orelse .refused) });
                    return null;
                },
                else => return null,
            },
            .err => |e| {
                logf(h.log, "webhost: node {d}: the fabric did not answer: {s}", .{ node, @tagName(e) });
                return null;
            },
        };
        if (chan == 0) return null;
        const sh = usys.shmCreate(shared.fab_bulk_pages);
        if (sh.err != .ok) {
            _ = usys.capDrop(chan);
            return null;
        }
        const m = usys.shmMap(sh.data[0]);
        if (m.err != .ok) {
            _ = usys.capDrop(sh.data[0]);
            _ = usys.capDrop(chan);
            return null;
        }
        // The cap goes with the hello (the fabric makes its twin on the
        // relay's node and keeps its own reference); the mapping is ours.
        const hello = usys.callTyped(wire.RelayReq, wire.RelayResp, chan, .{ .hello = .{ .w = w, .h = height, .flags = 0 } }, sh.data[0]);
        const page_rep = switch (hello) {
            .ok => |rep| switch (rep) {
                .page => |pg| pg,
                .refused => |rf| {
                    logf(h.log, "webhost: node {d}: the relay refused a page: {s}", .{ node, @tagName(std.enums.fromInt(wire.RelayRefuse, rf.code) orelse .full) });
                    _ = usys.shmUnmap(m.data[0]);
                    _ = usys.capDrop(chan);
                    return null;
                },
                else => {
                    _ = usys.shmUnmap(m.data[0]);
                    _ = usys.capDrop(chan);
                    return null;
                },
            },
            .err => |e| {
                logf(h.log, "webhost: node {d}: the relay did not answer the hello: {s}", .{ node, @tagName(e) });
                _ = usys.shmUnmap(m.data[0]);
                _ = usys.capDrop(chan);
                return null;
            },
        };
        h.lock.acquire();
        defer h.lock.release();
        var idx: usize = 0;
        while (idx < max_pages and h.pages[idx].used) idx += 1;
        if (idx == max_pages) {
            h.lock.release();
            _ = usys.callTyped(wire.RelayReq, wire.RelayResp, chan, .{ .bye = .{ .page = page_rep.id, .key = page_rep.key } }, 0);
            h.lock.acquire();
            _ = usys.shmUnmap(m.data[0]);
            _ = usys.capDrop(chan);
            return null;
        }
        const p = &h.pages[idx];
        const badge = h.next_badge;
        h.next_badge += 1;
        p.* = .{ .used = true, .badge = badge, .w = w, .h = height, .remote = .{
            .chan = chan,
            .node = node,
            .buf_va = m.data[0],
            .buf_len = @intCast(m.data[1] * 4096),
            .page_id = page_rep.id,
            .key = page_rep.key,
        } };
        if (!h.pageBuffers(p)) {
            h.destroyLocked(@intCast(idx));
            return null;
        }
        if (!h.ensureLz()) {
            h.destroyLocked(@intCast(idx));
            return null;
        }
        if (!h.pump_up) {
            if (h.pump_stack_va == 0) h.pump_stack_va = mapPages(pump_stack_pages);
            const stack: []u8 = if (h.pump_stack_va != 0) @as([*]u8, @ptrFromInt(h.pump_stack_va))[0 .. pump_stack_pages * 4096] else &.{};
            if (stack.len == 0 or usys.threadCreate(pumpMain, @intFromPtr(h), stack) != .ok) {
                logf(h.log, "webhost: no thread for the remote pages", .{});
                h.destroyLocked(@intCast(idx));
                return null;
            }
            h.pump_up = true;
        }
        logf(h.log, "webhost: page {d}: hosted on node {d} (remote page {d})", .{ idx, node, page_rep.id });
        return @intCast(idx);
    }

    /// Which node hosts the page (0: this one).
    pub fn nodeOf(h: *Host, id: PageId) u64 {
        h.lock.acquire();
        defer h.lock.release();
        const p = &h.pages[id];
        if (!p.used) return 0;
        return if (p.remote) |r| r.node else 0;
    }

    /// Window side: say goodbye to the relay and drop everything held
    /// for a remote page. Under the lock throughout, the goodbye too: a
    /// pump poll slipping in between would race the session's buffer
    /// and find the page gone (it did, 2026-10-06).
    fn remoteClose(h: *Host, id: PageId) void {
        const p = &h.pages[id];
        if (p.remote == null) return;
        const r = &p.remote.?;
        if (!r.dead) _ = usys.callTyped(wire.RelayReq, wire.RelayResp, r.chan, .{ .bye = .{ .page = r.page_id, .key = r.key } }, 0);
        if (r.chan != 0) _ = usys.capDrop(r.chan);
        if (r.buf_va != 0) _ = usys.shmUnmap(r.buf_va);
        if (p.data_va != 0) _ = usys.shmUnmap(p.data_va);
        if (p.data_shm != 0) _ = usys.capDrop(p.data_shm);
        if (p.px_va != 0) _ = usys.shmUnmap(p.px_va);
        if (p.px_shm != 0) _ = usys.capDrop(p.px_shm);
        p.* = .{};
    }

    fn pumpMain(arg: u64) callconv(.c) void {
        const h: *Host = @ptrFromInt(arg);
        while (true) {
            var busy = false;
            for (0..max_pages) |i| {
                if (h.pumpOne(@intCast(i))) busy = true;
            }
            if (!busy) usys.sleepMs(pump_idle_ms);
        }
    }

    /// One poll of a remote page: the queue and the broker's answers go
    /// down, what came back is played. True when something moved (the
    /// next poll follows at once).
    fn pumpOne(h: *Host, id: PageId) bool {
        h.lock.acquire();
        const p = &h.pages[id];
        if (!p.used or p.remote == null) {
            h.lock.release();
            return false;
        }
        const r = &p.remote.?;
        if (r.dead) {
            h.lock.release();
            return false;
        }
        if (r.closing) {
            h.remoteClose(id);
            h.lock.release();
            return false;
        }
        var w: wire.RecWriter = .{ .buf = r.buf() };
        while (p.qlen > 0) {
            if (!h.packCommand(p, &w)) break;
        }
        var tag_buf: [24]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "page {d}", .{id}) catch "page";
        switch (r.feed) {
            .none => {},
            .opened => |o| {
                var head: [4]u8 = undefined;
                wire.putU16(head[0..2], o.status);
                wire.putU16(head[2..4], o.url_len);
                if (w.put2(.opened, &head, r.feed_text[0 .. o.url_len + o.ct_len])) r.feed = .none;
            },
            .refused => |code| if (w.put(.refused, &[_]u8{@intCast(@intFromEnum(code))})) {
                r.feed = .none;
            },
            .s_ok => if (w.put(.s_ok, "")) {
                r.feed = .none;
            },
            .s_none => if (w.put(.s_none, "")) {
                r.feed = .none;
            },
            .s_count => |n| {
                var head: [4]u8 = undefined;
                wire.putU32(&head, n);
                if (w.put(.s_count, &head)) r.feed = .none;
            },
            .s_text => |n| if (w.put(.s_text, r.feed_text[0..n])) {
                r.feed = .none;
            },
            .s_refused => |code| if (w.put(.s_refused, &[_]u8{@intCast(@intFromEnum(code))})) {
                r.feed = .none;
            },
        }
        if (r.want_read) |max| if (r.feed == .none) {
            const n: usize = @intCast(@min(max, w.room() -| 1));
            if (n >= 1024 or n >= max) {
                const out = w.begin(.chunk, 1 + n).?;
                const rd = h.brokerRead(&p.client, out[1..], tag);
                out[0] = @intCast(@intFromEnum(rd.end));
                w.shrink(1 + rd.len);
                r.want_read = null;
            }
        };
        const sent = w.len;
        const had_more = r.more;
        r.in_call = true;
        h.lock.release();
        const res = usys.callTyped(wire.RelayReq, wire.RelayResp, r.chan, .{ .pump = .{ .page = r.page_id, .len = sent, .key = r.key } }, 0);
        h.lock.acquire();
        r.in_call = false;
        if (r.closing) {
            h.remoteClose(id);
            h.lock.release();
            return false;
        }
        const out = switch (res) {
            .ok => |rep| switch (rep) {
                .out => |o| o,
                .refused => |rf| blk: {
                    logf(h.log, "webhost: page {d}: the relay refused the poll: {s}", .{ id, @tagName(std.enums.fromInt(wire.RelayRefuse, rf.code) orelse .unknown) });
                    break :blk null;
                },
                else => null,
            },
            .err => |e| blk: {
                logf(h.log, "webhost: page {d}: the relay on node {d} is gone: {s}", .{ id, r.node, @tagName(e) });
                break :blk null;
            },
        } orelse {
            // The page is dead to us; the host program hears it as it
            // would a local page's death.
            r.dead = true;
            p.dead = true;
            h.postEvent(id, null, 0, 0);
            h.lock.release();
            return false;
        };
        r.more = out.more != 0;
        const got = r.buf()[0..@min(out.len, r.buf_len)];
        h.lock.release();
        // The records, without the lock: the buffer is ours between
        // calls, and an event goes through the serving thread, which
        // takes the lock itself.
        var rd: wire.RecReader = .{ .buf = got };
        var played = false;
        while (rd.next()) |rec| {
            played = true;
            h.remoteRecord(id, rec);
        }
        return sent > 0 or had_more or played or r.more;
    }

    /// Pack the page's first queued command as a record; false when it
    /// does not fit (it stays queued).
    fn packCommand(h: *Host, p: *Page, w: *wire.RecWriter) bool {
        _ = h;
        const q = &p.queue[0];
        const ok = switch (q.cmd) {
            .load => w.put(.load, p.texts[0][0..p.text_len[0]]),
            .scroll => |dy| blk: {
                var b: [8]u8 = undefined;
                wire.putU64(&b, @bitCast(dy));
                break :blk w.put(.scroll, &b);
            },
            .pointer => |pt| blk: {
                var b: [5]u8 = undefined;
                b[0] = @intCast(@intFromEnum(pt.kind));
                wire.putU16(b[1..3], pt.x);
                wire.putU16(b[3..5], pt.y);
                break :blk w.put(.pointer, &b);
            },
            .key => |k| blk: {
                var b: [8]u8 = undefined;
                wire.putU32(b[0..4], k.code);
                wire.putU32(b[4..8], k.ch);
                break :blk w.put(.key, &b);
            },
            .dump => |d| w.put2(.dump, &[_]u8{@intCast(@intFromEnum(d.what))}, p.texts[2][0..p.text_len[2]]),
            .resize => |rs| blk: {
                var b: [4]u8 = undefined;
                wire.putU16(b[0..2], rs.w);
                wire.putU16(b[2..4], rs.h);
                break :blk w.put(.resize, &b);
            },
            .find => |f| blk: {
                var b: [4]u8 = undefined;
                wire.putU32(&b, f.index);
                break :blk w.put2(.find, &b, p.texts[1][0..p.text_len[1]]);
            },
            .zoom => |z| blk: {
                var b: [2]u8 = undefined;
                wire.putU16(&b, z);
                break :blk w.put(.zoom, &b);
            },
            .theme => |t| blk: {
                var b: [8]u8 = undefined;
                wire.putU64(&b, t);
                break :blk w.put(.theme, &b);
            },
            .idle => w.put(.idle, ""),
            .tick => w.put(.tick, ""),
            .scripts => |on| w.put(.scripts, &[_]u8{if (on) 1 else 0}),
            .stop => w.put(.stop, ""),
        };
        if (!ok) return false;
        for (1..p.qlen) |i| p.queue[i - 1] = p.queue[i];
        p.qlen -= 1;
        return true;
    }

    /// Play one record from the relay as the page would have acted.
    fn remoteRecord(h: *Host, id: PageId, rec: wire.Record) void {
        const p = &h.pages[id];
        if (p.remote == null) return;
        const r = &p.remote.?;
        const pl = rec.payload;
        var tag_buf: [24]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "page {d}", .{id}) catch "page";
        switch (rec.tag) {
            .event => if (pl.len >= 17) {
                const kind = std.enums.fromInt(wire.Event, pl[0]) orelse return;
                const d = p.data();
                const text = pl[17..];
                const n = @min(text.len, d.len);
                h.lock.acquire();
                defer h.lock.release();
                @memcpy(d[0..n], text[0..n]);
                h.postEvent(id, kind, wire.getU64(pl[1..]), wire.getU64(pl[9..]));
            },
            .dump_part => if (pl.len >= 4) {
                const d = p.data();
                const off: usize = @intCast(wire.getU32(pl));
                const bytes = pl[4..];
                if (off < d.len) {
                    const n = @min(bytes.len, d.len - off);
                    @memcpy(d[off .. off + n], bytes[0..n]);
                }
            },
            .pixels => if (pl.len >= 12) {
                const x: usize = @intCast(wire.getU16(pl));
                const y: usize = @intCast(wire.getU16(pl[2..]));
                const w: usize = @intCast(wire.getU16(pl[4..]));
                const rows: usize = @intCast(wire.getU16(pl[6..]));
                const raw: usize = @intCast(wire.getU32(pl[8..]));
                const packed_bytes = pl[12..];
                if (raw == 0 or raw > lz_max or w == 0 or h.lz_va == 0) return;
                h.lock.acquire();
                const lz_in = h.lzIn();
                const got: usize = if (packed_bytes.len == raw) blk: {
                    @memcpy(lz_in[0..raw], packed_bytes);
                    break :blk raw;
                } else mosslib.lz4.decompress(packed_bytes, lz_in[0..raw]) catch 0;
                if (got == raw and p.px_va != 0 and x + w <= p.w and y + rows <= p.h and rows * w * 4 == raw) {
                    const px = @as([*]u8, @ptrFromInt(p.px_va));
                    for (0..rows) |i| {
                        const at = ((y + i) * p.w + x) * 4;
                        @memcpy(px[at .. at + w * 4], lz_in[i * w * 4 .. (i + 1) * w * 4]);
                    }
                    h.postEvent(id, .commit, shared.packPair(@intCast(x), @intCast(y)), shared.packPair(@intCast(w), @intCast(rows)));
                }
                h.lock.release();
            },
            .open => if (pl.len >= 12) {
                const flags = wire.getU64(pl);
                const url_len: usize = @intCast(@min(wire.getU16(pl[8..]), pl.len - 12));
                const body_len: usize = @intCast(@min(wire.getU16(pl[10..]), pl.len - 12 - url_len));
                const url = pl[12 .. 12 + url_len];
                const body = pl[12 + url_len .. 12 + url_len + body_len];
                const origin = pl[12 + url_len + body_len ..];
                h.lock.acquire();
                defer h.lock.release();
                switch (h.brokerOpenFrom(&p.client, url, flags & 1 != 0, body, origin, tag)) {
                    .refused => |code| r.feed = .{ .refused = code },
                    .opened => |op| {
                        const un = @min(op.url.len, r.feed_text.len);
                        @memcpy(r.feed_text[0..un], op.url[0..un]);
                        const cn = @min(op.ct.len, r.feed_text.len - un);
                        @memcpy(r.feed_text[un .. un + cn], op.ct[0..cn]);
                        r.feed = .{ .opened = .{ .status = op.status, .url_len = un, .ct_len = cn } };
                    },
                }
            },
            .read => if (pl.len >= 4) {
                h.lock.acquire();
                r.want_read = wire.getU32(pl);
                h.lock.release();
            },
            .cancel => {
                h.lock.acquire();
                h.brokerCancel(&p.client);
                r.want_read = null;
                h.lock.release();
            },
            .storage => if (pl.len >= 7) {
                const op_raw: u64 = pl[0];
                const klen_raw = wire.getU32(pl[1..]);
                const klen: usize = @intCast(@min(wire.getU16(pl[5..]), pl.len - 7));
                const key = pl[7 .. 7 + klen];
                const value = pl[7 + klen ..];
                h.lock.acquire();
                defer h.lock.release();
                var obuf: [1024]u8 = undefined;
                const origin = pageOrigin(p, &obuf);
                r.feed = switch (h.storageOp(origin, op_raw, klen_raw, key, value, &r.feed_text)) {
                    .ok => .s_ok,
                    .none => .s_none,
                    .count => |n| .{ .s_count = n },
                    .text => |n| .{ .s_text = n },
                    .refused => |code| .{ .s_refused = code },
                };
            },
            else => {},
        }
    }

    /// A remote page's event, as the page's own would have been served:
    /// noted on the record (under the lock, by the pump) and posted for
    /// `step` to hand over; the serving thread is woken.
    fn postEvent(h: *Host, id: PageId, kind: ?wire.Event, a: u64, b: u64) void {
        const p = &h.pages[id];
        if (kind) |k| h.noteEvent(p, k, a, b);
        if (h.posted_tail -% h.posted_head == h.posted.len) {
            logf(h.log, "webhost: page {d}: event queue full; {s} dropped", .{ id, if (kind) |k| @tagName(k) else "death" });
            return;
        }
        h.posted[h.posted_tail % h.posted.len] = .{ .page = id, .kind = kind, .a = a, .b = b };
        h.posted_tail +%= 1;
        if (h.notif != 0) _ = usys.notifySignal(h.notif, 1);
    }

    fn takePosted(h: *Host) ?Step {
        h.lock.acquire();
        defer h.lock.release();
        if (h.posted_head == h.posted_tail) return null;
        const e = h.posted[h.posted_head % h.posted.len];
        h.posted_head +%= 1;
        if (e.kind) |k| return .{ .event = .{ .page = e.page, .kind = k, .a = e.a, .b = e.b } };
        return .{ .dead = e.page };
    }

    // ------------------------------------------------------- the broker

    fn refuse(h: *Host, code: wire.RefuseCode) void {
        h.reply(.{ .refused = .{ .code = @intFromEnum(code) } }, 0);
    }

    /// A connection's identity for reuse: scheme, host and port.
    fn connKey(buf: []u8, target: anytype) []const u8 {
        return std.fmt.bufPrint(buf, "{s}|{s}|{d}", .{ if (target.tls) "https" else "http", target.host, target.port }) catch buf[0..0];
    }

    /// How long a parked connection is trusted before being dropped
    /// unused (servers close idle ones after a few seconds).
    const park_ms: u64 = 8_000;

    pub fn dropParked(h: *Host, c: *Client) void {
        if (c.kept) |k| k.close(h.net);
        c.kept = null;
        c.kept_key_len = 0;
    }

    /// OpenOut/ReadOut: what the broker answers, for the caller to put on
    /// its wire. `url` and `ct` are the broker's until its next open.
    pub const OpenOut = union(enum) { refused: wire.RefuseCode, opened: struct { status: u64, url: []const u8, ct: []const u8 } };
    pub const ReadOut = struct { len: usize, end: wire.ChunkEnd };

    /// Open `url_in` for `c` (a GET, or a POST of `body_in`): redirects
    /// followed, a parked connection tried first, the head parsed; the
    /// body is then read by `brokerRead`. `tag` names the client in the log.
    pub fn brokerOpen(h: *Host, c: *Client, url_in: []const u8, post_in: bool, body_in: []const u8, tag: []const u8) OpenOut {
        return h.brokerOpenFrom(c, url_in, post_in, body_in, "", tag);
    }

    /// `brokerOpen` for a script's cross-origin request: `origin` (the
    /// page's) goes as the `Origin` header, and the answer is admitted
    /// only if its `Access-Control-Allow-Origin` names it or is `*` —
    /// the simple CORS case (no credentials, no preflight).
    pub fn brokerOpenFrom(h: *Host, c: *Client, url_in: []const u8, post_in: bool, body_in: []const u8, origin: []const u8, tag: []const u8) OpenOut {
        if (c.open) |*res| {
            res.conn.close(h.net);
            c.open = null;
        }
        // The URL is copied: the caller's buffer may carry the answer.
        if (url_in.len == 0 or url_in.len > h.url_buf.len) return .{ .refused = .bad_url };
        @memcpy(h.url_buf[0..url_in.len], url_in);
        var url: []const u8 = h.url_buf[0..url_in.len];
        var post = post_in;
        var body: []const u8 = body_in;
        var fba = std.heap.FixedBufferAllocator.init(&h.scratch);
        var hops: usize = 0;
        // A parked connection is tried first; when it turns out dead (the
        // server closed it), the request goes again on a fresh one — the
        // same hop, not a redirect (counting it down from zero was the
        // browser drill's first integer overflow, 2026-09-23).
        var retry_fresh = false;
        while (true) {
            if (hops > max_redirects) return .{ .refused = .redirects };
            fba.reset();
            const a = fba.allocator();
            const target = http.parseUrl(url) orelse return .{ .refused = if (std.mem.indexOf(u8, url, "://") == null) .bad_url else .scheme };
            if (!h.net.attach()) return .{ .refused = .connect };
            var key_buf: [conn_key_max]u8 = undefined;
            const key = connKey(&key_buf, target);
            var reused = false;
            if (c.kept != null and !retry_fresh and usys.nowMs() - c.kept_ms < park_ms and std.mem.eql(u8, c.kept_key[0..c.kept_key_len], key)) {
                reused = true;
            } else h.dropParked(c);
            retry_fresh = false;
            // A failure to reach the site says why in the log: the word
            // is the network service's or the TLS client's, and a page
            // only hears a code.
            const t_open = usys.nowMs();
            const conn: Conn = if (reused) blk: {
                const kept = c.kept.?;
                c.kept = null;
                c.kept_key_len = 0;
                break :blk kept;
            } else if (target.tls) switch (tlscmds.open(h.net, target.host, target.port, target.host)) {
                .conn => |tc| .{ .tls = tc },
                .failed => |why| {
                    logf(h.log, "webhost: {s}: {s}: {s}", .{ tag, url, why });
                    return .{ .refused = if (isResolveFailure(why)) .resolve else .connect };
                },
            } else switch (h.net.connectHost(target.host, target.port)) {
                .sock => |s| .{ .plain = s },
                .failed => |why| {
                    logf(h.log, "webhost: {s}: {s}: {s}", .{ tag, url, why });
                    return .{ .refused = if (isResolveFailure(why)) .resolve else .connect };
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
            const origin_hdr = [_]http.Header{.{ .name = "Origin", .value = origin }};
            const hdrs: []const http.Header = if (origin.len == 0) (if (post) &headers_post else &headers_get) else if (post) &(headers_post ++ origin_hdr) else &(headers_get ++ origin_hdr);
            http.formatRequest(a, &req, if (post) "POST" else "GET", target.path, host_text, hdrs, body, true) catch return .{ .refused = .memory };
            if (conn.send(h.net, req.items)) |_| {
                conn.close(h.net);
                if (reused) {
                    retry_fresh = true;
                    continue;
                }
                return .{ .refused = .connect };
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
                            logf(h.log, "webhost: {s}: {s}: the head is longer than {d} KB", .{ tag, url, head_buf.len / 1024 });
                            return .{ .refused = .protocol };
                        }
                        @memcpy(head_buf[got .. got + bytes.len], bytes);
                        got += bytes.len;
                    },
                    .closed => closed = true,
                    .failed => {
                        conn.close(h.net);
                        if (reused and got == 0) {
                            retry_fresh = true;
                            break;
                        }
                        logf(h.log, "webhost: {s}: {s}: no head after {d} bytes (the connection failed)", .{ tag, url, got });
                        return .{ .refused = .connect };
                    },
                    .timeout => {
                        conn.close(h.net);
                        // A parked connection that answers nothing is retried
                        // on a fresh one for a GET; a POST is not — after a
                        // stall the server may have taken the form, and it
                        // must not be sent twice.
                        if (reused and got == 0 and !post) {
                            retry_fresh = true;
                            break;
                        }
                        logf(h.log, "webhost: {s}: {s}: no head after {d} bytes (the connection stalled)", .{ tag, url, got });
                        return .{ .refused = .connect };
                    },
                }
                if (closed and got == 0 and reused) {
                    // The server had let the parked connection go.
                    conn.close(h.net);
                    retry_fresh = true;
                    break;
                }
                const parsed = http.parseHead(a, head_buf[0..got]) catch |e| {
                    conn.close(h.net);
                    logf(h.log, "webhost: {s}: {s}: the head does not parse: {s}", .{ tag, url, @errorName(e) });
                    return .{ .refused = .protocol };
                };
                if (parsed) |hd| {
                    head = hd;
                    break;
                }
                if (closed) {
                    conn.close(h.net);
                    logf(h.log, "webhost: {s}: {s}: closed before the head ({d} bytes)", .{ tag, url, got });
                    return .{ .refused = .protocol };
                }
            }
            if (retry_fresh) continue;
            if (head.status >= 300 and head.status < 400) if (http.headerValue(head.headers, "location")) |loc| {
                // A redirect's body is left unread: the connection goes.
                conn.close(h.net);
                const base = web.url.parse(a, url, null) catch return .{ .refused = .bad_url };
                const next = web.url.resolve(a, loc, &base) catch return .{ .refused = .bad_url };
                const text = next.href(a) catch return .{ .refused = .memory };
                if (text.len > h.url_buf.len) return .{ .refused = .bad_url };
                @memcpy(h.url_buf[0..text.len], text);
                url = h.url_buf[0..text.len];
                // A redirected POST is followed as a GET, as browsers do.
                post = false;
                body = "";
                hops += 1;
                continue;
            };
            if (head.framing == .length and head.framing.length > wire.max_resource) {
                conn.close(h.net);
                return .{ .refused = .too_large };
            }
            if (origin.len > 0) {
                const allow = http.headerValue(head.headers, "access-control-allow-origin") orelse "";
                const trimmed = std.mem.trim(u8, allow, " \t");
                if (!std.mem.eql(u8, trimmed, "*") and !std.mem.eql(u8, trimmed, origin)) {
                    conn.close(h.net);
                    logf(h.log, "webhost: {s}: {s}: cross-origin answer not allowed for {s} (Access-Control-Allow-Origin: \"{s}\")", .{ tag, url, origin, trimmed });
                    return .{ .refused = .policy };
                }
            }
            // Where the time went: the timings are what a slow page is
            // measured by (resolve+connect, the TLS handshake, the head).
            if (reused) {
                logf(h.log, "webhost: {s}: {s}: reused connection, head {d} ms", .{ tag, url, usys.nowMs() - t_open });
            } else if (target.tls) {
                logf(h.log, "webhost: {s}: {s}: resolve+connect {d} ms, handshake {d} ms, head {d} ms", .{ tag, url, tlscmds.last_open_ms.resolve_connect, tlscmds.last_open_ms.handshake, usys.nowMs() - t_open - tlscmds.last_open_ms.resolve_connect - tlscmds.last_open_ms.handshake });
            } else {
                logf(h.log, "webhost: {s}: {s}: connect+head {d} ms", .{ tag, url, usys.nowMs() - t_open });
            }
            c.open = .{ .conn = conn, .framing = if (head.bodiless) .none else head.framing, .opened_ms = usys.nowMs(), .keep = head.keep };
            @memcpy(c.kept_key[0..key.len], key);
            c.kept_key_len = key.len;
            const res = &c.open.?;
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
            return .{ .opened = .{ .status = head.status, .url = url, .ct = http.headerValue(head.headers, "content-type") orelse "" } };
        }
    }

    fn open(h: *Host, id: PageId, off: u64, len: u64, flags: u64) void {
        const p = &h.pages[id];
        const d = p.data();
        if (off > d.len or len > d.len - off or len == 0) return h.refuse(.bad_url);
        // A POST's body follows the URL in the data buffer; copied out,
        // since the buffer is about to carry the answer.
        const body_len: usize = @intCast(@min((flags >> 8) & 0xffffff, h.body.len));
        const origin_len: usize = @intCast(@min((flags >> 32) & 0xffff, h.origin_buf.len));
        if (off + len + body_len + origin_len > d.len) return h.refuse(.bad_url);
        @memcpy(h.body[0..body_len], d[off + len .. off + len + body_len]);
        @memcpy(h.origin_buf[0..origin_len], d[off + len + body_len .. off + len + body_len + origin_len]);
        var tag_buf: [24]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "page {d}", .{id}) catch "page";
        switch (h.brokerOpenFrom(&p.client, d[off .. off + len], flags & 1 != 0, h.body[0..body_len], h.origin_buf[0..origin_len], tag)) {
            .refused => |code| h.refuse(code),
            .opened => |op| {
                // The answer: status, then the final URL and the content
                // type in the data buffer.
                const url_len = @min(op.url.len, d.len);
                @memcpy(d[0..url_len], op.url[0..url_len]);
                const ct_len = @min(op.ct.len, d.len - url_len);
                @memcpy(d[url_len .. url_len + ct_len], op.ct[0..ct_len]);
                h.reply(.{ .opened = .{ .status = op.status, .url_len = url_len, .type_len = ct_len } }, 0);
            },
        }
    }

    fn chunkReply(h: *Host, len: usize, end: wire.ChunkEnd) void {
        h.reply(.{ .chunk = .{ .len = len, .done = @intFromEnum(end) } }, 0);
    }

    pub fn brokerRead(h: *Host, c: *Client, out: []u8, tag: []const u8) ReadOut {
        const res: *Resource = if (c.open) |*r| r else return .{ .len = 0, .end = .failed };
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
                        logf(h.log, "webhost: {s}: the body was cut short (closed, {s} framing)", .{ tag, @tagName(res.framing) });
                        h.finish(c);
                        return .{ .len = 0, .end = .failed };
                    },
                    .failed => {
                        logf(h.log, "webhost: {s}: the body's connection failed", .{tag});
                        h.finish(c);
                        return .{ .len = 0, .end = .failed };
                    },
                    .timeout => {
                        logf(h.log, "webhost: {s}: the body stalled for {d} ms", .{ tag, stall_ms });
                        h.finish(c);
                        return .{ .len = 0, .end = .failed };
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
                        h.finish(c);
                        return .{ .len = 0, .end = .failed };
                    }
                    if (res.chunks.done) res.done = true;
                },
            }
            res.served += produced - before;
            if (res.served > wire.max_resource) {
                h.finish(c);
                return .{ .len = 0, .end = .failed };
            }
        }
        const end: wire.ChunkEnd = if (res.done) .done else .more;
        if (res.done) h.finish(c);
        return .{ .len = produced, .end = end };
    }

    /// A finished response: its connection is parked for the next
    /// request when it may be (read to its end, and the server said
    /// keep-alive), else closed.
    fn read(h: *Host, id: PageId, max: u64) void {
        const p = &h.pages[id];
        var tag_buf: [24]u8 = undefined;
        const tag = std.fmt.bufPrint(&tag_buf, "page {d}", .{id}) catch "page";
        const r = h.brokerRead(&p.client, p.data()[0..@min(max, p.data_len)], tag);
        h.chunkReply(r.len, r.end);
    }

    /// Drop what `c` has open (a cancel, a teardown).
    pub fn brokerCancel(h: *Host, c: *Client) void {
        if (c.open) |*res| res.conn.close(h.net);
        c.open = null;
    }

    fn finish(h: *Host, c: *Client) void {
        if (c.open) |*res| {
            if (res.done and res.keep and res.framing != .none) {
                if (c.kept) |k| k.close(h.net);
                c.kept = res.conn;
                c.kept_ms = usys.nowMs();
            } else {
                res.conn.close(h.net);
                c.kept_key_len = 0;
            }
        }
        c.open = null;
    }
};

pub fn logf(log: u64, comptime fmt: []const u8, args: anytype) void {
    var buf: [256]u8 = undefined;
    const text = std.fmt.bufPrint(&buf, fmt, args) catch return;
    _ = usys.log(log, text);
}
