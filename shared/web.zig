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
    dump: struct { what: u64 },
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

pub const Dump = enum(u64) { html = 0 };

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

test "font pack round trip" {
    var buf: [64]u8 = undefined;
    var off = FontPack.begin(&buf, 2).?;
    off = FontPack.put(&buf, 0, off, "abc").?;
    off = FontPack.put(&buf, 1, off, "de").?;
    try std.testing.expectEqualStrings("abc", FontPack.file(buf[0..off], 0).?);
    try std.testing.expectEqualStrings("de", FontPack.file(buf[0..off], 1).?);
    try std.testing.expect(FontPack.file(buf[0..off], 2) == null);
}
