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
    open: struct { off: u64, len: u64, flags: u64 },
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
    // Commands, in answer to `next`.
    /// Navigate to the URL at data[off..off+len].
    load: struct { off: u64, len: u64 },
    /// Scroll by `dy` document pixels (an i64).
    scroll: struct { dy: u64 },
    /// The pointer: `kind` is a `PointerKind`, at viewport (x, y).
    pointer: struct { kind: u64, x: u64, y: u64 },
    key: struct { code: u64, ch: u64 },
    /// Write the document out into the data buffer (`what` is a `Dump`);
    /// the page answers with a `dumped` event.
    dump: struct { what: u64 },
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
};

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
};

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
