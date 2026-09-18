//! The page domain: the one place untrusted web content runs. Spawned
//! by a host with a single capability — a badged calling end of the
//! host's channel — it asks the host for its data buffer, its viewport
//! pixels and the fonts it may rasterize, then serves the host's
//! commands one `next` at a time: load a URL (bytes come through the
//! host, the broker that owns the network), scroll, the pointer, a
//! dump of the document. Every byte it reads is parsed here, laid out
//! here, painted here into the buffer the host granted, and the host
//! learns what changed by the events the page calls back with. It
//! holds no filesystem, no network, no font service; when its arena
//! runs out the page says so and dies, and the host sees a dead client.
const std = @import("std");
const shared = @import("shared");
const mosslib = @import("mosslib");
const usys = @import("usys.zig");
const web = mosslib.web;
const font = mosslib.font;
const ui = mosslib.ui;
const wire = shared.web;
const dom = web.dom;

comptime {
    asm (usys.imageHeaderStack("webpage", 128));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    var line: [200]u8 = undefined;
    const text = std.fmt.bufPrint(&line, "webpage: panic: {s}", .{msg}) catch "webpage: panic";
    _ = usys.log(glog, text);
    usys.exit(255);
}

var glog: u64 = 0;
var host: u64 = 0;

// ---------------------------------------------------------------- memory

/// The document arena: the bytes, the tree, the styles, the layout of
/// the page being shown — reset on every navigation. Its size is the
/// page's budget for a document; a page that needs more dies of it.
var heap: [20 << 20]u8 = undefined;
var arena_fba: std.heap.FixedBufferAllocator = undefined;
/// Rasterized glyphs, kept across navigations.
var glyph_heap: [2 << 20]u8 = undefined;
var glyph_fba: std.heap.FixedBufferAllocator = undefined;
/// The user-agent stylesheet, parsed once.
var ua_heap: [512 << 10]u8 = undefined;
var ua_sheet: ?web.style.Sheet = null;

fn outOfMemory() noreturn {
    _ = usys.log(glog, "webpage: out of memory: the document outgrew the page's arena");
    usys.exit(137);
}

// ------------------------------------------------------------ the host

var data: [*]u8 = undefined;
var data_len: usize = 0;
var px: [*]u32 = undefined;
var has_pixels = false;
var vw: usize = 0;
var vh: usize = 0;

fn call(req: wire.PageReq) wire.HostResp {
    return switch (usys.callTyped(wire.PageReq, wire.HostResp, host, req, 0)) {
        .ok => |rep| rep,
        .err => |e| {
            var line: [96]u8 = undefined;
            _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: host call failed: {s}", .{@tagName(e)}) catch "webpage: host call failed");
            usys.exit(0); // the host is gone: so are we
        },
    };
}

fn callCap(req: wire.PageReq) struct { rep: wire.HostResp, cap: u64 } {
    return switch (usys.callTypedCap(wire.PageReq, wire.HostResp, host, req, 0)) {
        .ok => |ok| .{ .rep = ok.rep, .cap = ok.cap },
        .err => usys.exit(0),
    };
}

fn event(kind: wire.Event, a: u64, b: u64) void {
    _ = call(.{ .event = .{ .kind = @intFromEnum(kind), .a = a, .b = b } });
}

fn eventText(kind: wire.Event, text: []const u8) void {
    const n = @min(text.len, data_len);
    @memcpy(data[0..n], text[0..n]);
    event(kind, n, 0);
}

fn attach() void {
    const d = callCap(.attach_data);
    if (d.rep != .data_buf or d.cap == 0) {
        _ = usys.log(glog, "webpage: no data buffer from the host");
        usys.exit(3);
    }
    const dm = usys.shmMap(d.cap);
    _ = usys.capDrop(d.cap);
    if (dm.err != .ok) usys.exit(3);
    data = @ptrFromInt(dm.data[0]);
    data_len = dm.data[1] * 4096;

    const p = callCap(.attach_pixels);
    switch (p.rep) {
        .pixels => |pp| {
            if (p.cap == 0) usys.exit(4);
            const pm = usys.shmMap(p.cap);
            _ = usys.capDrop(p.cap);
            if (pm.err != .ok) usys.exit(4);
            if (pp.w * pp.h * 4 > pm.data[1] * 4096) usys.exit(4);
            px = @ptrFromInt(pm.data[0]);
            has_pixels = true;
            vw = pp.w;
            vh = pp.h;
        },
        else => {
            // Headless: a nominal viewport to lay out for, no pixels.
            if (p.cap != 0) _ = usys.capDrop(p.cap);
            vw = 1024;
            vh = 768;
        },
    }

    const f = callCap(.attach_fonts);
    switch (f.rep) {
        .fonts => |ff| {
            if (f.cap != 0) {
                const fm = usys.shmMap(f.cap);
                _ = usys.capDrop(f.cap);
                if (fm.err == .ok) {
                    const pack = @as([*]const u8, @ptrFromInt(fm.data[0]))[0..@min(ff.len, fm.data[1] * 4096)];
                    page_fonts.load(pack);
                }
            }
        },
        else => if (f.cap != 0) {
            _ = usys.capDrop(f.cap);
        },
    }
}

// ------------------------------------------------------------- fonts

/// Text for layout and paint: the faces the host packed (sans first,
/// mono second), rasterized by `lib/font` into a bounded glyph cache;
/// without any, fixed cells, so a headless page still lays out.
const PageFonts = struct {
    faces: [2]?font.Font = .{ null, null },
    cache: [512]Entry = undefined,
    cache_len: usize = 0,
    fixed: web.layout.FixedFonts = .{},

    const Entry = struct { face: u8, gid: u16, size: u16, glyph: font.Glyph };

    fn load(self: *PageFonts, pack: []const u8) void {
        for (0..2) |i| {
            const bytes = wire.FontPack.file(pack, i) orelse continue;
            self.faces[i] = font.Font.parse(bytes) catch null;
        }
        if (self.faces[0] == null) self.faces[0] = self.faces[1];
    }

    fn fonts(self: *PageFonts) web.layout.Fonts {
        if (self.faces[0] == null) return self.fixed.fonts();
        return .{ .ctx = @ptrCast(self), .vtable = &vtable };
    }

    const vtable: web.layout.Fonts.VTable = .{ .advance = adv, .metrics = met, .draw = draw };

    fn faceFor(self: *PageFonts, f: web.layout.Font) struct { face: *const font.Font, idx: u8 } {
        if (f.monospace) if (self.faces[1]) |*m| return .{ .face = m, .idx = 1 };
        return .{ .face = &self.faces[0].?, .idx = 0 };
    }

    fn scaleOf(face: *const font.Font, size: f64) f64 {
        return size / @as(f64, @floatFromInt(face.units_per_em));
    }

    fn adv(ctx: *anyopaque, f: web.layout.Font, text: []const u8) f64 {
        const self: *PageFonts = @ptrCast(@alignCast(ctx));
        const face = self.faceFor(f);
        const scale = scaleOf(face.face, f.size);
        var total: f64 = 0;
        var it = CodePoints{ .s = text };
        while (it.next()) |cp| {
            const gid = face.face.glyphIndex(cp);
            total += @as(f64, @floatFromInt(face.face.advance(gid))) * scale;
        }
        return total;
    }

    fn met(ctx: *anyopaque, f: web.layout.Font) web.layout.FontMetrics {
        const self: *PageFonts = @ptrCast(@alignCast(ctx));
        const face = self.faceFor(f);
        const scale = scaleOf(face.face, f.size);
        const asc = @as(f64, @floatFromInt(face.face.ascent)) * scale;
        const desc = -@as(f64, @floatFromInt(face.face.descent)) * scale;
        return .{ .ascent = @round(@max(asc, f.size * 0.6)), .descent = @round(@max(desc, f.size * 0.15)) };
    }

    fn glyph(self: *PageFonts, idx: u8, face: *const font.Font, gid: u16, size: f64) ?*const font.Glyph {
        const size_q: u16 = @intFromFloat(@min(65535, @max(0, size * 4)));
        for (self.cache[0..self.cache_len]) |*e| {
            if (e.face == idx and e.gid == gid and e.size == size_q) return &e.glyph;
        }
        if (self.cache_len == self.cache.len) {
            // Full: start over. A page rarely uses this many glyph
            // shapes at once; when it does, the miss is a rasterization.
            self.cache_len = 0;
            glyph_fba.reset();
        }
        const g = font.rasterize(face, glyph_fba.allocator(), gid, @floatCast(size)) catch |e| switch (e) {
            error.OutOfMemory => blk: {
                self.cache_len = 0;
                glyph_fba.reset();
                break :blk font.rasterize(face, glyph_fba.allocator(), gid, @floatCast(size)) catch return null;
            },
            else => return null,
        };
        self.cache[self.cache_len] = .{ .face = idx, .gid = gid, .size = size_q, .glyph = g };
        self.cache_len += 1;
        return &self.cache[self.cache_len - 1].glyph;
    }

    fn draw(ctx: *anyopaque, canvas: *const ui.Canvas, f: web.layout.Font, x: f64, baseline: f64, text: []const u8, color: u32) void {
        const self: *PageFonts = @ptrCast(@alignCast(ctx));
        const face = self.faceFor(f);
        const scale = scaleOf(face.face, f.size);
        var pen = x;
        var it = CodePoints{ .s = text };
        while (it.next()) |cp| {
            const gid = face.face.glyphIndex(cp);
            const advance = @as(f64, @floatFromInt(face.face.advance(gid))) * scale;
            if (cp != ' ' and cp != 0xa0) if (self.glyph(face.idx, face.face, gid, f.size)) |g| {
                const gx: i64 = @as(i64, @intFromFloat(@round(pen))) + g.left;
                // `top` is the bitmap's top from the baseline, downward
                // (negative above it), as the toolkit reads it.
                const gy: i64 = @as(i64, @intFromFloat(@round(baseline))) + g.top;
                for (0..g.h) |row| {
                    const y = gy + @as(i64, @intCast(row));
                    if (y < 0) continue;
                    for (0..g.w) |col| {
                        const xx = gx + @as(i64, @intCast(col));
                        if (xx < 0) continue;
                        canvas.blend(@intCast(xx), @intCast(y), color, g.cov[row * g.w + col]);
                    }
                }
            };
            pen += advance;
        }
    }
};

const CodePoints = struct {
    s: []const u8,
    i: usize = 0,

    fn next(it: *CodePoints) ?u21 {
        if (it.i >= it.s.len) return null;
        const len = std.unicode.utf8ByteSequenceLength(it.s[it.i]) catch {
            it.i += 1;
            return 0xfffd;
        };
        if (it.i + len > it.s.len) {
            it.i = it.s.len;
            return 0xfffd;
        }
        const cp = std.unicode.utf8Decode(it.s[it.i .. it.i + len]) catch 0xfffd;
        it.i += len;
        return cp;
    }
};

var page_fonts: PageFonts = .{};

// ------------------------------------------------------------- the page

const Page = struct {
    doc: ?*dom.Document = null,
    sheets: []const web.style.Sheet = &.{},
    /// The arena's fill after the parse: a relayout resets to here.
    parsed_mark: usize = 0,
    styles: ?*web.style.Styles = null,
    layout: ?*web.layout.Layout = null,
    base: ?web.url.Url = null,
    scroll_y: f64 = 0,
    extent: f64 = 0,
    url_buf: [2048]u8 = undefined,
    url_len: usize = 0,
    type_buf: [256]u8 = undefined,
    type_len: usize = 0,
    hover_buf: [2048]u8 = undefined,
    hover_len: usize = 0,
    pressed: ?dom.NodeId = null,

    fn url(p: *const Page) []const u8 {
        return p.url_buf[0..p.url_len];
    }
};

var page: Page = .{};

fn arena() std.mem.Allocator {
    return arena_fba.allocator();
}

fn uaSheet(env: web.style.Env) web.style.Sheet {
    if (ua_sheet) |s| return s;
    var fba = std.heap.FixedBufferAllocator.init(&ua_heap);
    ua_sheet = web.style.parseSheet(fba.allocator(), web.style.ua_sheet, .user_agent, env) catch outOfMemory();
    return ua_sheet.?;
}

/// Fetch through the host into the arena: the whole resource, or why not.
const Fetched = union(enum) { body: []u8, refused: wire.RefuseCode, status: u64 };

fn fetch(url_text: []const u8) Fetched {
    if (url_text.len > data_len) return .{ .refused = .bad_url };
    @memcpy(data[0..url_text.len], url_text);
    const opened = switch (call(.{ .open = .{ .off = 0, .len = url_text.len, .flags = 0 } })) {
        .opened => |o| o,
        .refused => |r| return .{ .refused = std.enums.fromInt(wire.RefuseCode, r.code) orelse .protocol },
        else => return .{ .refused = .protocol },
    };
    page.url_len = @min(opened.url_len, page.url_buf.len);
    @memcpy(page.url_buf[0..page.url_len], data[0..page.url_len]);
    page.type_len = @min(opened.type_len, page.type_buf.len);
    @memcpy(page.type_buf[0..page.type_len], data[opened.url_len .. opened.url_len + page.type_len]);
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        const chunk = switch (call(.{ .read = .{ .max = data_len } })) {
            .chunk => |c| c,
            else => return .{ .refused = .protocol },
        };
        const n = @min(chunk.len, data_len);
        if (body.items.len + n > wire.max_resource) {
            _ = call(.cancel);
            return .{ .refused = .too_large };
        }
        body.appendSlice(arena(), data[0..n]) catch outOfMemory();
        switch (std.enums.fromInt(wire.ChunkEnd, chunk.done) orelse .failed) {
            .more => {},
            .done => break,
            .failed => return .{ .refused = .protocol },
        }
    }
    if (opened.status >= 400) return .{ .status = opened.status };
    return .{ .body = body.items };
}

/// The document's markup from what arrived: HTML as it is, plain text
/// wrapped in `<pre>`, anything else a line saying what it was.
fn markupOf(body: []const u8) []const u8 {
    const ct = page.type_buf[0..page.type_len];
    const mime = std.mem.trim(u8, if (std.mem.indexOfScalar(u8, ct, ';')) |i| ct[0..i] else ct, " ");
    const enc = web.encoding.detect(body, ct);
    const text = web.encoding.decode(arena(), enc, body) catch outOfMemory();
    if (mime.len == 0 or std.ascii.eqlIgnoreCase(mime, "text/html") or std.ascii.eqlIgnoreCase(mime, "application/xhtml+xml")) return text;
    var out: std.ArrayList(u8) = .empty;
    if (std.ascii.startsWithIgnoreCase(mime, "text/")) {
        out.appendSlice(arena(), "<!DOCTYPE html><pre style=\"white-space:pre-wrap;word-wrap:break-word\">") catch outOfMemory();
        for (text) |ch| switch (ch) {
            '&' => out.appendSlice(arena(), "&amp;") catch outOfMemory(),
            '<' => out.appendSlice(arena(), "&lt;") catch outOfMemory(),
            else => out.append(arena(), ch) catch outOfMemory(),
        };
        out.appendSlice(arena(), "</pre>") catch outOfMemory();
    } else {
        out.print(arena(), "<!DOCTYPE html><title>{s}</title><p>This resource is <code>{s}</code>, which this page cannot show.</p>", .{ page.url(), mime }) catch outOfMemory();
    }
    return out.items;
}

fn load(url_text: []const u8) void {
    // Everything of the old page goes; the URL text may live in the
    // arena, so it is copied out first.
    var keep: [2048]u8 = undefined;
    const n = @min(url_text.len, keep.len);
    @memcpy(keep[0..n], url_text[0..n]);
    const target = keep[0..n];
    page = .{};
    arena_fba.reset();
    event(.load, @intFromEnum(wire.LoadState.loading), 0);
    const got = fetch(target);
    const body: []const u8 = switch (got) {
        .body => |b| b,
        .refused => |code| {
            @memcpy(page.url_buf[0..n], target);
            page.url_len = n;
            showError(code);
            return;
        },
        .status => |st| {
            showStatus(st);
            return;
        },
    };
    present(markupOf(body), 0);
}

fn showError(code: wire.RefuseCode) void {
    var buf: [512]u8 = undefined;
    const markup = std.fmt.bufPrint(&buf, "<!DOCTYPE html><title>Cannot open</title><h1>Cannot open the page</h1><p>{s}: <code>{s}</code></p>", .{ @tagName(code), page.url() }) catch "<p>Cannot open the page</p>";
    present(markup, @intFromEnum(code));
}

fn showStatus(status: u64) void {
    var buf: [512]u8 = undefined;
    const markup = std.fmt.bufPrint(&buf, "<!DOCTYPE html><title>{d}</title><h1>{d}</h1><p>The server answered {d} for <code>{s}</code>.</p>", .{ status, status, status, page.url() }) catch "<p>The server refused</p>";
    present(markup, status);
}

/// Parse, style, lay out and paint markup; `failure` is 0 for a page
/// that loaded, else the code or status the load event reports.
fn present(markup: []const u8, failure: u64) void {
    const a = arena();
    const doc = web.html.parse(a, markup, .{}) catch outOfMemory();
    page.doc = doc;
    page.base = web.url.parse(a, page.url(), null) catch null;
    // The title, then the URL, before the layout that may take a while.
    var title: []const u8 = "";
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "title")) {
        title = doc.textContent(id, a) catch outOfMemory();
        break;
    };
    eventText(.title, std.mem.trim(u8, title, " \t\r\n"));
    eventText(.url, page.url());
    const env: web.style.Env = .{ .width = @floatFromInt(vw), .height = @floatFromInt(vh) };
    page.sheets = web.style.collectDocumentSheetsWith(a, doc, env, uaSheet(env)) catch outOfMemory();
    page.parsed_mark = arena_fba.end_index;
    relayout();
    event(.load, @intFromEnum(if (failure == 0) wire.LoadState.done else wire.LoadState.failed), failure);
}

/// Style, lay out and paint the parsed document for the viewport as it
/// is now; everything after the parse is redone from the arena's mark.
/// (`@media` rules were flattened at parse for the viewport of that
/// time — a resize keeps them; the cascade's other viewport units are
/// computed here.)
fn relayout() void {
    const a = arena();
    const doc = page.doc orelse return;
    arena_fba.end_index = page.parsed_mark;
    page.layout = null;
    const env: web.style.Env = .{ .width = @floatFromInt(vw), .height = @floatFromInt(vh) };
    const styles = a.create(web.style.Styles) catch outOfMemory();
    styles.* = web.style.compute(a, doc, page.sheets, env) catch outOfMemory();
    page.styles = styles;
    const l = web.layout.layoutDocument(a, doc, styles, page_fonts.fonts(), @floatFromInt(vw), @floatFromInt(vh)) catch outOfMemory();
    page.layout = l;
    page.extent = l.get(l.root).h;
    const max_y = @max(0, page.extent - @as(f64, @floatFromInt(vh)));
    page.scroll_y = @min(page.scroll_y, max_y);
    event(.extent, @intFromFloat(@max(0, page.extent)), 0);
    paintAll();
}

/// The host's viewport changed: let the old pixels go, take the new
/// buffer (none when hidden), and lay out for it.
fn resize(w: u64, h: u64) void {
    if (has_pixels) {
        _ = usys.shmUnmap(@intFromPtr(px));
        has_pixels = false;
    }
    vw = @intCast(w);
    vh = @intCast(h);
    if (w > 0 and h > 0) {
        const p = callCap(.attach_pixels);
        switch (p.rep) {
            .pixels => |pp| if (p.cap != 0) {
                const pm = usys.shmMap(p.cap);
                _ = usys.capDrop(p.cap);
                if (pm.err == .ok and pp.w * pp.h * 4 <= pm.data[1] * 4096) {
                    px = @ptrFromInt(pm.data[0]);
                    has_pixels = true;
                    vw = @intCast(pp.w);
                    vh = @intCast(pp.h);
                }
            },
            else => if (p.cap != 0) {
                _ = usys.capDrop(p.cap);
            },
        }
    } else {
        // Hidden: lay out for the last real size so the extent stays
        // meaningful; nothing is painted.
        vw = 1024;
        vh = 768;
    }
    relayout();
}

fn paintAll() void {
    const l = page.layout orelse return;
    if (!has_pixels) return;
    const canvas = ui.Canvas.init(px, vw, vh);
    canvas.fillAll(0xffffff);
    web.paint.paint(l, &canvas, page.scroll_y) catch outOfMemory();
    event(.commit, shared.packPair(0, 0), shared.packPair(@intCast(vw), @intCast(vh)));
}

fn scrollBy(dy: f64) void {
    const max_y = @max(0, page.extent - @as(f64, @floatFromInt(vh)));
    const y = @min(max_y, @max(0, page.scroll_y + dy));
    if (y == page.scroll_y) return;
    page.scroll_y = y;
    paintAll();
}

/// The link under a viewport point: its href resolved against the
/// page, or null.
fn linkAt(x: u64, y: u64) ?[]const u8 {
    const l = page.layout orelse return null;
    const doc = page.doc orelse return null;
    var id = web.layout.hitTest(l, @floatFromInt(x), @as(f64, @floatFromInt(y)) + page.scroll_y) orelse return null;
    while (true) {
        if (doc.isHtml(id, "a")) if (doc.getAttr(id, "href")) |href| {
            const base = &(page.base orelse return null);
            const u = web.url.resolve(arena(), href, base) catch return null;
            return u.href(arena()) catch outOfMemory();
        };
        id = doc.get(id).parent orelse return null;
    }
}

fn pointer(kind: wire.PointerKind, x: u64, y: u64) void {
    switch (kind) {
        .move => {
            const link = linkAt(x, y) orelse "";
            if (std.mem.eql(u8, link, page.hover_buf[0..page.hover_len])) return;
            page.hover_len = @min(link.len, page.hover_buf.len);
            @memcpy(page.hover_buf[0..page.hover_len], link[0..page.hover_len]);
            eventText(.hover, page.hover_buf[0..page.hover_len]);
        },
        .down => {
            const l = page.layout orelse return;
            page.pressed = web.layout.hitTest(l, @floatFromInt(x), @as(f64, @floatFromInt(y)) + page.scroll_y);
        },
        .up => {
            const was = page.pressed;
            page.pressed = null;
            const l = page.layout orelse return;
            const now = web.layout.hitTest(l, @floatFromInt(x), @as(f64, @floatFromInt(y)) + page.scroll_y);
            if (was == null or now == null or was.? != now.?) return;
            if (linkAt(x, y)) |link| load(link);
        },
    }
}

fn dump(what: wire.Dump) void {
    _ = what;
    const doc = page.doc orelse {
        event(.dumped, 0, 0);
        return;
    };
    var out: std.ArrayList(u8) = .empty;
    web.html.serialize(arena(), doc, dom.document_id, &out) catch outOfMemory();
    const n = @min(out.items.len, data_len);
    @memcpy(data[0..n], out.items[0..n]);
    event(.dumped, n, if (n < out.items.len) 1 else 0);
}

fn serve() noreturn {
    while (true) {
        switch (call(.next)) {
            .load => |c| {
                const off = @min(c.off, data_len);
                const len = @min(c.len, data_len - off);
                load(data[off .. off + len]);
            },
            .scroll => |s| scrollBy(@floatFromInt(@as(i64, @bitCast(s.dy)))),
            .pointer => |p| pointer(std.enums.fromInt(wire.PointerKind, p.kind) orelse .move, p.x, p.y),
            .key => {},
            .dump => |d| dump(std.enums.fromInt(wire.Dump, d.what) orelse .html),
            .resize => |r| resize(r.w, r.h),
            .stop => usys.exit(0),
            else => {},
        }
    }
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, _: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    host = chan_h;
    if (arg != wire.page_arg) {
        _ = usys.log(glog, "webpage: spawned without a host to serve");
        usys.exit(2);
    }
    arena_fba = std.heap.FixedBufferAllocator.init(&heap);
    glyph_fba = std.heap.FixedBufferAllocator.init(&glyph_heap);
    attach();
    _ = usys.log(glog, "webpage: up");
    serve();
}
