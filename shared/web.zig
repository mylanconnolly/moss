//! The web's seam: the protocol between a page domain (`webpage`, the
//! one place untrusted content runs) and its host — the program that
//! spawned it, which is also its fetch broker. A page holds exactly one
//! capability, a badged calling end to its host, so every message here
//! is the page's call and the host's reply: the page asks for its
//! buffers, asks for the next command, opens and reads resources by
//! URL, and reports events. A host never calls a page; it answers, and
//! parks a `next` until it has a command. Pixels are the boundary: the
//! page paints into the buffer the host granted and reports the rect
//! it changed; what the host does with those pixels is the host's.
//!
//! Wire rules as everywhere in shared/: a message is a tag and up to
//! three words; text and bytes ride in the page's data buffer, named by
//! offset and length.
const std = @import("std");

/// The spawn argument that tells `webpage` to serve a host on its
/// channel (no boot handshake: the channel and what arrives on it are
/// its whole world).
pub const page_arg: u64 = 7;

/// The data buffer's size: URLs, resource chunks and document dumps
/// pass through it, so a chunk is at most this.
pub const data_pages: u64 = 64;

/// The largest resource a host serves a page, and the largest document
/// a page keeps: past it a page is refused, or dies of its own arena.
pub const max_resource: u64 = 24 << 20;

pub const PageReq = union(enum(u64)) {
    /// The page's data buffer: the reply carries the shm cap.
    attach_data: void,
    /// The viewport's pixel buffer (XRGB, `w` × `h`); the reply carries
    /// the cap, or `none` for a host that wants no pixels.
    attach_pixels: void,
    /// The fonts the page may rasterize: a buffer of font files (see
    /// `FontPack`), or `none` when the host has none to give.
    attach_fonts: void,
    /// The next command; the host parks the call until it has one.
    next: void,
    /// Open the resource at data[off..off+len] (an absolute URL).
    /// `flags`: bit 0 = POST, with a body of `(flags >> 8) & 0xffffff`
    /// bytes following the URL in the data buffer (form-urlencoded);
    /// bits 32..47 = the length of the page's origin following the body,
    /// for a script's cross-origin request: the broker sends `Origin`
    /// and admits the answer only if `Access-Control-Allow-Origin` does.
    open: struct { off: u64, len: u64, flags: u64 },
    /// Per-origin storage (`localStorage`), kept by the host under a
    /// quota: `op` is a `StorageOp`; the key is data[0..key_len], the
    /// value data[key_len..key_len+value_len]; for `key_at`, `key_len`
    /// is the index. The origin is the page's, as the host knows it.
    storage: struct { op: u64, key_len: u64, value_len: u64 },
    /// The next chunk of the open resource, at most `max` bytes, into
    /// data[0..].
    read: struct { max: u64 },
    /// Drop the open resource.
    cancel: void,
    /// Something happened; `kind` is an `Event`, text (when the event
    /// carries one) at data[0..a].
    event: struct { kind: u64, a: u64, b: u64 },
};

pub const HostResp = union(enum(u64)) {
    ok: void,
    none: void,
    data_buf: struct { pages: u64 },
    pixels: struct { w: u64, h: u64 },
    fonts: struct { len: u64 },
    /// The resource is open: its status, and at data[0..] the final URL
    /// (after redirects) then the content type, by length.
    opened: struct { status: u64, url_len: u64, type_len: u64 },
    refused: struct { code: u64 },
    /// `len` bytes at data[0..]; `done` is a `ChunkEnd`.
    chunk: struct { len: u64, done: u64 },
    /// A count (a storage's length).
    count: struct { n: u64 },
    /// `len` bytes at data[0..]: a storage value or key.
    text: struct { len: u64 },
    // Commands, in answer to `next`.
    /// Navigate to the URL at data[off..off+len].
    load: struct { off: u64, len: u64 },
    /// Time passed (the `wake` the page asked for): run what is due.
    tick: void,
    /// Whether the pages loaded from now on run their scripts (`on` = 1).
    scripts: struct { on: u64 },
    /// Scroll by `dy` document pixels (an i64).
    scroll: struct { dy: u64 },
    /// The pointer: `kind` is a `PointerKind`, at viewport (x, y).
    pointer: struct { kind: u64, x: u64, y: u64 },
    key: struct { code: u64, ch: u64 },
    /// Write the document out into the data buffer (`what` is a `Dump`);
    /// the page answers with a `dumped` event.
    /// `what` is a `Dump`; for `selected`, the selector is data[0..len].
    dump: struct { what: u64, len: u64 },
    /// The viewport is now `w` × `h`: the page asks `attach_pixels`
    /// again for the new buffer (0 × 0 = hidden: no buffer, no paint;
    /// the document stays) and lays out afresh.
    resize: struct { w: u64, h: u64 },
    /// Find the text at data[0..len] (empty clears): highlights every
    /// match, scrolls to the `index`th, and answers with `found`.
    find: struct { len: u64, index: u64 },
    /// Text zoom, in percent of the page's own sizes.
    zoom: struct { percent: u64 },
    /// Nothing has happened for a while: a good time for the work that
    /// can wait (pictures near the viewport).
    idle: void,
    /// The session's appearance: `flags` bit 0 = dark, bit 1 = high
    /// contrast (the page's `prefers-color-scheme` and forced colours).
    theme: struct { flags: u64 },
    stop: void,
};

pub const Event = enum(u64) {
    /// The document's title, as text.
    title = 1,
    /// The document's URL (the final one), as text.
    url = 2,
    /// `a` is a `LoadState`; for `failed`, `b` is a `RefuseCode` or an
    /// HTTP status.
    load = 3,
    /// The pixels changed in the rect (x, y) = unpack(a), (w, h) = unpack(b).
    commit = 4,
    /// The pointer is over a link whose URL is the text (empty = none).
    hover = 5,
    /// The dump is in data[0..a]; `b` = 1 when it was cut to fit.
    dumped = 6,
    /// The document's laid-out height in pixels (`a`) — what a host may
    /// scroll through.
    extent = 7,
    /// The resource opened is not a document: its URL is data[0..a] and
    /// its type data[a..a+b]; the page left it unread for the host to
    /// save (a download is the host's grant, never the page's write).
    download = 8,
    /// A find: `a` matches, the `b`th shown (0-based; a = 0 for none).
    found = 9,
    /// The text selected by a drag, data[0..a].
    selection = 10,
    /// The focused element changed: its kind name is data[0..a] (empty
    /// for none); `b` packs its viewport rect as (x, y) in the high and
    /// (w, h) in the low word, each pair 16 bits.
    focus = 11,
    /// More of the work that waits for quiet remains (pictures near the
    /// viewport past one idle's budget): another `idle` is welcome.
    want_idle = 12,
    /// The page's scripts have a timer or an animation frame due in `a`
    /// ms (0 = now): a `tick` then, please. The page cannot wait on a
    /// clock and its host at once, so the host keeps the clock.
    wake = 13,
};

pub const ThemeFlags = struct {
    pub const dark: u64 = 1;
    pub const high_contrast: u64 = 2;
};

/// A rect packed into a word: x, y, w, h as 16 bits each.
pub fn packRect(x: u64, y: u64, w: u64, h: u64) u64 {
    return ((x & 0xffff) << 48) | ((y & 0xffff) << 32) | ((w & 0xffff) << 16) | (h & 0xffff);
}
pub fn unpackRect(v: u64) [4]u64 {
    return .{ (v >> 48) & 0xffff, (v >> 32) & 0xffff, (v >> 16) & 0xffff, v & 0xffff };
}

pub const LoadState = enum(u64) { loading = 0, done = 1, failed = 2 };

pub const PointerKind = enum(u64) { move = 0, down = 1, up = 2 };

/// What a dump carries: the whole document as markup, or only the
/// elements a selector matches (their outer markup, one after another)
/// — a host that wants one part of a big page pays for that part; or
/// the value of a script expression the host sends (`eval`: data[0..len]
/// is the source, the dump its completion value as text — a headless
/// render asking the page what its scripts concluded).
pub const Dump = enum(u64) { html = 0, selected = 1, eval = 2 };

pub const ChunkEnd = enum(u64) { more = 0, done = 1, failed = 2 };

/// Why a broker refused to open a URL.
pub const RefuseCode = enum(u64) {
    bad_url = 1,
    scheme = 2,
    resolve = 3,
    connect = 4,
    protocol = 5,
    too_large = 6,
    redirects = 7,
    busy = 8,
    policy = 9,
    memory = 10,
    /// A storage write past the origin's quota.
    quota = 11,
};

/// `PageReq.storage` operations.
pub const StorageOp = enum(u64) { get = 0, set = 1, remove = 2, clear = 3, key_at = 4, length = 5 };

/// The font buffer: `count` files, each a `[]u8` of `len` bytes, packed
/// as a header of little-endian u32s (count, then each length) and the
/// files in order. The first is the sans face, the second the mono.
pub const FontPack = struct {
    pub const max_files = 4;

    pub fn headerLen(count: usize) usize {
        return 4 * (1 + count);
    }

    /// Slice file `i` out of a pack, or null past the end.
    pub fn file(pack: []const u8, i: usize) ?[]const u8 {
        if (pack.len < 4) return null;
        const count = std.mem.readInt(u32, pack[0..4], .little);
        if (i >= count or count > max_files) return null;
        if (pack.len < headerLen(count)) return null;
        var off = headerLen(count);
        for (0..count) |k| {
            const len = std.mem.readInt(u32, pack[4 + 4 * k ..][0..4], .little);
            if (off + len > pack.len) return null;
            if (k == i) return pack[off .. off + len];
            off += len;
        }
        return null;
    }

    /// Start a pack for `count` files in `out`; the files follow in order
    /// via `put`. Returns the offset the first file goes at.
    pub fn begin(out: []u8, count: usize) ?usize {
        if (count > max_files or out.len < headerLen(count)) return null;
        std.mem.writeInt(u32, out[0..4], @intCast(count), .little);
        return headerLen(count);
    }

    pub fn put(out: []u8, i: usize, off: usize, bytes: []const u8) ?usize {
        if (off + bytes.len > out.len) return null;
        std.mem.writeInt(u32, out[4 + 4 * i ..][0..4], @intCast(bytes.len), .little);
        @memcpy(out[off .. off + bytes.len], bytes);
        return off + bytes.len;
    }
};

// ------------------------------------------------------------ the relay
//
// A page on another node (stage 12 of the browser arc). Node 2 runs a
// durable `webnode` service that hosts the page domain there, in the
// host code's relay mode; node 1's window dials it by name and drives
// it by polling: a `pump` call carries the commands and resource bytes
// the page is owed in the session buffer, and the reply carries what
// the page produced since — its events, its fetch and storage requests
// (the broker stays on node 1: a page on node 2 still holds nothing),
// and LZ4-packed rows of the viewport rect it repainted. Nothing parks:
// a remote call held longer than the fabric's timeout drops the peer
// link, so the relay answers at once and the window polls while a page
// is busy. Each side reads and writes the one 32 KB session buffer the
// fabric ships as a byte diff; both directions are *records* in it.

/// The service unit's name on the fabric (`dial NODE "webnode"`).
pub const relay_name = "webnode";

pub const RelayReq = union(enum(u64)) {
    /// Spawn a page here with a `w` × `h` viewport; the call carries the
    /// session buffer cap (the fabric makes its twin). Reply `page`.
    hello: struct { w: u64, h: u64, flags: u64 },
    /// data[0..len] holds host→relay records; the reply's data holds
    /// relay→host records. `key` is the page's key from `page`.
    pump: struct { page: u64, len: u64, key: u64 },
    /// Destroy the page.
    bye: struct { page: u64, key: u64 },
};

pub const RelayResp = union(enum(u64)) {
    page: struct { id: u64, key: u64 },
    /// `len` bytes of records at data[0..]; `more` = 1 when the relay
    /// has more to send than fit (poll again at once).
    out: struct { len: u64, more: u64 },
    refused: struct { code: u64 },
};

/// Why a relay refused: no page slot, no memory, an unknown page.
pub const RelayRefuse = enum(u64) { full = 1, memory = 2, unknown = 3, spawn = 4 };

/// A record in the session buffer: a tag, a u16 length, the payload.
pub const Rec = enum(u8) {
    // host → relay: the commands (as `HostResp` answers `next`)
    load = 1, // url
    scroll = 2, // i64
    pointer = 3, // kind u8, x u16, y u16
    key = 4, // code u32, ch u32
    dump = 5, // what u8, selector
    resize = 6, // w u16, h u16
    find = 7, // index u32, text
    zoom = 8, // percent u16
    theme = 9, // flags u64
    idle = 10,
    tick = 11,
    scripts = 12, // on u8
    stop = 13,
    // host → relay: the broker's answers to the page's requests
    opened = 20, // status u16, url_len u16, url, content type
    refused = 21, // code u8
    chunk = 22, // done u8, bytes
    s_ok = 23,
    s_none = 24,
    s_count = 25, // n u32
    s_text = 26, // bytes
    s_refused = 27, // code u8
    // relay → host: what the page did
    event = 40, // kind u8, a u64, b u64, text
    pixels = 41, // x u16, y u16, w u16, rows u16, raw_len u32, lz4 (or raw when raw_len == payload)
    open = 42, // flags u64, url_len u16, body_len u16, url, body, origin
    read = 43, // max u32
    cancel = 44,
    storage = 45, // op u8, key_len u16, key, value
    dump_part = 46, // off u32, bytes (a dump's text, into the host's buffer)
};

pub const rec_head = 3;

/// Append records to a buffer; `fail` is set when one did not fit (the
/// caller sends what fit and tries again).
pub const RecWriter = struct {
    buf: []u8,
    len: usize = 0,
    /// Where the record last begun starts (for `shrink`).
    last: usize = 0,

    pub fn room(w: *const RecWriter) usize {
        return w.buf.len -| (w.len + rec_head);
    }

    /// Reserve a record of `n` payload bytes: the payload slice to fill,
    /// or null when it does not fit.
    pub fn begin(w: *RecWriter, tag: Rec, n: usize) ?[]u8 {
        if (n > 0xffff or w.len + rec_head + n > w.buf.len) return null;
        w.last = w.len;
        w.buf[w.len] = @intFromEnum(tag);
        std.mem.writeInt(u16, w.buf[w.len + 1 ..][0..2], @intCast(n), .little);
        const out = w.buf[w.len + rec_head .. w.len + rec_head + n];
        w.len += rec_head + n;
        return out;
    }

    /// The record last begun turned out shorter: `actual` payload bytes.
    pub fn shrink(w: *RecWriter, actual: usize) void {
        std.mem.writeInt(u16, w.buf[w.last + 1 ..][0..2], @intCast(actual), .little);
        w.len = w.last + rec_head + actual;
    }

    pub fn put(w: *RecWriter, tag: Rec, payload: []const u8) bool {
        const out = w.begin(tag, payload.len) orelse return false;
        @memcpy(out, payload);
        return true;
    }

    /// Two or three parts in one record.
    pub fn put2(w: *RecWriter, tag: Rec, a: []const u8, b: []const u8) bool {
        const out = w.begin(tag, a.len + b.len) orelse return false;
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len..], b);
        return true;
    }
    pub fn put3(w: *RecWriter, tag: Rec, a: []const u8, b: []const u8, c: []const u8) bool {
        const out = w.begin(tag, a.len + b.len + c.len) orelse return false;
        @memcpy(out[0..a.len], a);
        @memcpy(out[a.len .. a.len + b.len], b);
        @memcpy(out[a.len + b.len ..], c);
        return true;
    }
};

pub const Record = struct { tag: Rec, payload: []const u8 };

/// Walk the records of a buffer; a malformed tail ends the walk.
pub const RecReader = struct {
    buf: []const u8,
    at: usize = 0,

    pub fn next(r: *RecReader) ?Record {
        if (r.at + rec_head > r.buf.len) return null;
        const tag = std.enums.fromInt(Rec, r.buf[r.at]) orelse return null;
        const n = std.mem.readInt(u16, r.buf[r.at + 1 ..][0..2], .little);
        if (r.at + rec_head + n > r.buf.len) return null;
        const p = r.buf[r.at + rec_head .. r.at + rec_head + n];
        r.at += rec_head + n;
        return .{ .tag = tag, .payload = p };
    }
};

// Little-endian field helpers for record payloads.
pub fn putU16(b: []u8, v: u64) void {
    std.mem.writeInt(u16, b[0..2], @intCast(v & 0xffff), .little);
}
pub fn putU32(b: []u8, v: u64) void {
    std.mem.writeInt(u32, b[0..4], @intCast(v & 0xffff_ffff), .little);
}
pub fn putU64(b: []u8, v: u64) void {
    std.mem.writeInt(u64, b[0..8], v, .little);
}
pub fn getU16(b: []const u8) u64 {
    return std.mem.readInt(u16, b[0..2], .little);
}
pub fn getU32(b: []const u8) u64 {
    return std.mem.readInt(u32, b[0..4], .little);
}
pub fn getU64(b: []const u8) u64 {
    return std.mem.readInt(u64, b[0..8], .little);
}

// -------------------------------------------------------- the exit node
//
// A broker on another node (the other half of stage 12): a window's
// fetches leave through a peer's network. Node 2 runs `webexit`, a
// durable service dialed by name; the window says `hello` with a
// session buffer and then asks it to open and read — but a fetch can
// stall past the fabric's call limit, so every call answers at once:
// `open` and `read` *start* the work on the exit's worker for that
// client and reply `pending`, and the window polls for the outcome.
// The texts and bytes ride in the session buffer: a request's URL, body
// and origin down, the final URL and content type or a chunk up.

pub const exit_name = "webexit";

pub const ExitReq = union(enum(u64)) {
    /// Become a client (the call carries the session buffer cap). Reply
    /// `client`.
    hello: void,
    /// Start opening: data[0..6] = url_len, body_len, origin_len (u16
    /// each), then the three texts; `flags` bit 0 = POST. Reply
    /// `pending` (poll for `opened`/`refused`), or `refused` at once.
    open: struct { client: u64, flags: u64, key: u64 },
    /// Start reading up to `max` bytes of the open resource into
    /// data[0..]. Reply `pending` (poll for `chunk`).
    read: struct { client: u64, max: u64, key: u64 },
    /// The outcome of the open or read under way, or `pending` still.
    poll: struct { client: u64, key: u64 },
    /// Drop what is open.
    cancel: struct { client: u64, key: u64 },
    bye: struct { client: u64, key: u64 },
};

pub const ExitResp = union(enum(u64)) {
    client: struct { id: u64, key: u64 },
    pending: void,
    /// The final URL then the content type at data[0..].
    opened: struct { status: u64, url_len: u64, type_len: u64 },
    refused: struct { code: u64 },
    chunk: struct { len: u64, done: u64 },
    ok: void,
};

test "relay records round trip" {
    var buf: [64]u8 = undefined;
    var w: RecWriter = .{ .buf = &buf };
    try std.testing.expect(w.put(.load, "http://a/"));
    try std.testing.expect(w.put(.idle, ""));
    try std.testing.expect(w.put2(.opened, "\x00\x01", "xy"));
    try std.testing.expect(!w.put(.chunk, &[_]u8{0} ** 60)); // does not fit
    const big = w.begin(.chunk, 20).?;
    big[0] = 7;
    w.shrink(1);
    var r: RecReader = .{ .buf = buf[0..w.len] };
    const a = r.next().?;
    try std.testing.expectEqual(Rec.load, a.tag);
    try std.testing.expectEqualStrings("http://a/", a.payload);
    try std.testing.expectEqual(Rec.idle, r.next().?.tag);
    const c = r.next().?;
    try std.testing.expectEqual(Rec.opened, c.tag);
    try std.testing.expectEqualStrings("\x00\x01xy", c.payload);
    const d = r.next().?;
    try std.testing.expectEqual(Rec.chunk, d.tag);
    try std.testing.expectEqualStrings("\x07", d.payload);
    try std.testing.expect(r.next() == null);
}

test "font pack round trip" {
    var buf: [64]u8 = undefined;
    var off = FontPack.begin(&buf, 2).?;
    off = FontPack.put(&buf, 0, off, "abc").?;
    off = FontPack.put(&buf, 1, off, "de").?;
    try std.testing.expectEqualStrings("abc", FontPack.file(buf[0..off], 0).?);
    try std.testing.expectEqualStrings("de", FontPack.file(buf[0..off], 1).?);
    try std.testing.expect(FontPack.file(buf[0..off], 2) == null);
}
