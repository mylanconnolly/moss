//! webshot: render a real web page on the host with moss's engine —
//! the page domain's pipeline (parse, linked sheets, `@font-face`,
//! pictures, style, layout, paint) over the same system faces — into a
//! PPM, so a site that looks wrong in the Web app can be looked at in a
//! second instead of a boot. Resources are fetched with `curl` (sending
//! the page domain's User-Agent) into a cache directory, so a rerun is
//! offline and deterministic; delete the directory to refetch.
//!
//!   zig build webshot -- URL OUT.ppm [WIDTH] [HEIGHT] [ZOOM%]
//!
//! WIDTH is the viewport (1280), HEIGHT the canvas (the page's extent,
//! at most 6000), ZOOM the page zoom in percent (100). The cache is
//! zig-out/webshot-cache.
//!
//! WEBSHOT_SCRIPTS=1 runs the page's scripts first, as the page domain
//! would — the same engine over the same 16 MB cell heap and 32 MB
//! bookkeeping heap, the bindings' hooks answered from this pipeline
//! (a layout on demand for `getBoundingClientRect` and
//! `getComputedStyle`, scripts and requests from the cache) — and
//! settles the timers on a fake clock (WEBSHOT_SETTLE ms of page time,
//! 3000 by default) before laying out what the scripts left. Every
//! console line and script error prints, with the time each took: the
//! rough edges of a real site's JavaScript, found in a second.
const std = @import("std");
const mosslib = @import("mosslib");
const web = mosslib.web;
const font = mosslib.font;
const ui = mosslib.ui;
const dom = web.dom;

const script = web.script;
const js = mosslib.js;

const cache_dir = "zig-out/webshot-cache";
const user_agent = "moss/0.0 (webpage)";

var io: std.Io = undefined;
var gpa: std.mem.Allocator = undefined;
var page_base: web.url.Url = undefined;

const Fetched = struct { body: []const u8, content_type: []const u8, url: []const u8, status: u32 };

/// A URL's body, from the cache or through curl (then cached).
fn fetch(url_text: []const u8) ?Fetched {
    if (web.url.decodeData(gpa, url_text) catch null) |d| return .{ .body = d.bytes, .content_type = d.mime, .url = url_text, .status = 200 };
    const cwd = std.Io.Dir.cwd();
    var h = std.hash.Fnv1a_64.init();
    h.update(url_text);
    const key = h.final();
    const body_path = std.fmt.allocPrint(gpa, cache_dir ++ "/{x:0>16}.body", .{key}) catch return null;
    const meta_path = std.fmt.allocPrint(gpa, cache_dir ++ "/{x:0>16}.meta", .{key}) catch return null;
    if (cwd.readFileAlloc(io, meta_path, gpa, .limited(1 << 16))) |meta| {
        const body = cwd.readFileAlloc(io, body_path, gpa, .limited(64 << 20)) catch return null;
        return parseMeta(meta, body);
    } else |_| {}
    cwd.createDirPath(io, cache_dir) catch {};
    const r = std.process.run(gpa, io, .{ .argv = &.{ "curl", "-sL", "--max-time", "30", "-A", user_agent, "-o", body_path, "-w", "%{http_code}\n%{content_type}\n%{url_effective}", url_text } }) catch return null;
    if (r.term != .exited or r.term.exited != 0) {
        std.debug.print("webshot: fetch failed: {s}\n", .{url_text});
        return null;
    }
    cwd.writeFile(io, .{ .sub_path = meta_path, .data = r.stdout }) catch {};
    const body = cwd.readFileAlloc(io, body_path, gpa, .limited(64 << 20)) catch return null;
    std.debug.print("webshot: fetched {s} ({d} bytes)\n", .{ url_text, body.len });
    return parseMeta(r.stdout, body);
}

fn parseMeta(meta: []const u8, body: []const u8) ?Fetched {
    var it = std.mem.splitScalar(u8, meta, '\n');
    const status = std.fmt.parseInt(u32, it.next() orelse return null, 10) catch 0;
    const ct = it.next() orelse "";
    const u = it.next() orelse "";
    return .{ .body = body, .content_type = ct, .url = u, .status = status };
}

fn resolve(href: []const u8, base_text: ?[]const u8) ?[]const u8 {
    const b: web.url.Url = if (base_text) |t| (web.url.parse(gpa, t, null) catch page_base) else page_base;
    const u = web.url.resolve(gpa, href, &b) catch return null;
    return u.href(gpa) catch null;
}

fn sheetFetch(_: *anyopaque, href: []const u8, base_text: ?[]const u8) ?web.style.Loader.Loaded {
    const url_text = resolve(href, base_text) orelse return null;
    const f = fetch(url_text) orelse return null;
    if (f.status >= 400) return null;
    const text = web.encoding.decode(gpa, web.encoding.detect(f.body, f.content_type), f.body) catch return null;
    return .{ .text = text, .url = url_text };
}

var page_scratch: std.heap.FixedBufferAllocator = undefined;
var probe_fba: std.heap.FixedBufferAllocator = undefined;
var page_keep: std.heap.FixedBufferAllocator = undefined;
var scratch_peak: usize = 0;

fn keepSheet(_: *anyopaque, sheet: web.style.Sheet) web.style.Error!web.style.Sheet {
    scratch_peak = @max(scratch_peak, page_scratch.end_index);
    const kept = try web.style.cloneSheet(page_keep.allocator(), sheet);
    page_scratch.reset();
    return kept;
}

const Picture = struct { node: dom.NodeId, bm: ?web.layout.Bitmap };
var pictures: std.ArrayList(Picture) = .empty;
const Background = struct { href: []const u8, bm: ?web.layout.Bitmap };
var backgrounds: std.ArrayList(Background) = .empty;
var zoom: f64 = 1;

fn imagesGet(_: *anyopaque, node: dom.NodeId) ?web.layout.Bitmap {
    for (pictures.items) |p| if (p.node == node) return p.bm;
    return null;
}

fn imagesBackground(_: *anyopaque, url_text: []const u8, base: ?[]const u8) ?web.layout.Bitmap {
    const href = resolve(url_text, base) orelse return null;
    for (backgrounds.items) |b| if (std.mem.eql(u8, b.href, href)) return b.bm;
    return null;
}
const images_vtable: web.layout.Images.VTable = .{ .get = imagesGet, .background = imagesBackground };

/// Every allocation of the page-mode probe by size class (`WEBSHOT_PAGE`).
const Histo = struct { count: usize = 0, bytes: usize = 0, freed: usize = 0, resized: usize = 0, grown: usize = 0 };
var histo: [40]Histo = @splat(.{});
var histo_inner: std.mem.Allocator = undefined;
fn bucket(n: usize) usize {
    return if (n == 0) 0 else std.math.log2_int_ceil(usize, n) + 1;
}
fn histoAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const b = &histo[bucket(len)];
    b.count += 1;
    b.bytes += len;
    const p = histo_inner.rawAlloc(len, alignment, ra) orelse return null;
    if (meta_owners_used < meta_owners.len / 2) if (siteOf(ra)) |st| {
        st.live += len;
        st.count += 1;
        const o = ownerSlot(@intFromPtr(p));
        o.* = .{ .ptr = @intFromPtr(p), .site = st, .len = len };
    };
    return p;
}
fn histoResize(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const ok = histo_inner.rawResize(mem, alignment, new_len, ra);
    histo[bucket(mem.len)].resized += 1;
    if (ok and new_len > mem.len) histo[bucket(mem.len)].grown += 1;
    return ok;
}
fn histoRemap(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const p = histo_inner.rawRemap(mem, alignment, new_len, ra);
    histo[bucket(mem.len)].resized += 1;
    if (p != null and new_len > mem.len) histo[bucket(mem.len)].grown += 1;
    return p;
}
fn histoFree(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
    histo[bucket(mem.len)].freed += 1;
    histo_inner.rawFree(mem, alignment, ra);
}
const histo_vtable: std.mem.Allocator.VTable = .{ .alloc = histoAlloc, .resize = histoResize, .remap = histoRemap, .free = histoFree };

/// A picture's pixels, as the page decodes them: SVG at the zoom.
fn decodePicture(bytes: []const u8, href: []const u8) ?web.layout.Bitmap {
    if (mosslib.svg.sniff(bytes)) {
        const img = mosslib.svg.render(gpa, bytes, zoom) catch |e| {
            std.debug.print("webshot: svg not drawn ({s}): {s}\n", .{ @errorName(e), href });
            return null;
        };
        return .{ .w = img.w, .h = img.h, .rgba = img.rgba, .density = zoom };
    }
    const img = mosslib.image.decode(gpa, bytes) catch |e| {
        std.debug.print("webshot: image not decoded ({s}): {s}\n", .{ @errorName(e), href });
        return null;
    };
    return .{ .w = img.w, .h = img.h, .rgba = img.rgba };
}

pub fn main(init: std.process.Init) !u8 {
    io = init.io;
    gpa = init.arena.allocator();
    const cwd = std.Io.Dir.cwd();
    var args: std.ArrayList([]const u8) = .empty;
    var ait = std.process.Args.Iterator.init(init.minimal.args);
    while (ait.next()) |a| try args.append(gpa, try gpa.dupe(u8, a));
    if (args.items.len < 3) {
        std.debug.print("usage: webshot URL OUT.ppm [WIDTH] [HEIGHT] [ZOOM%]\n", .{});
        return 2;
    }
    const url_arg = args.items[1];
    const out_path = args.items[2];
    const vw: usize = if (args.items.len > 3) try std.fmt.parseInt(usize, args.items[3], 10) else 1280;
    const max_h: usize = if (args.items.len > 4) try std.fmt.parseInt(usize, args.items[4], 10) else 6000;
    zoom = if (args.items.len > 5) @as(f64, @floatFromInt(try std.fmt.parseInt(usize, args.items[5], 10))) / 100 else 1;
    const vh: usize = 800;

    // The system faces, as the host packs them for a page.
    var glyph_heap: [8 << 20]u8 = undefined;
    var faces = web.fonts.FaceFonts.init(&glyph_heap);
    for (system_faces, 0..) |path, i| {
        const bytes = cwd.readFileAlloc(io, path, gpa, .limited(32 << 20)) catch continue;
        faces.setSystem(i, font.Font.parse(bytes) catch null);
    }

    const t0 = std.Io.Clock.awake.now(io);
    const doc_f = fetch(url_arg) orelse return 1;
    page_base = try web.url.parse(gpa, doc_f.url, null);
    const text = try web.encoding.decode(gpa, web.encoding.detect(doc_f.body, doc_f.content_type), doc_f.body);
    // WEBSHOT_PAGE=1: the DOM through a fixed region too, so its cost
    // shows (a list that doubles inside a bump allocator leaves its old
    // buffers behind).
    const page_mode = std.c.getenv("WEBSHOT_PAGE") != null;
    const region_mb: usize = if (std.c.getenv("WEBSHOT_REGION")) |v| try std.fmt.parseInt(usize, std.mem.span(v), 10) else 24;
    var dom_fba = std.heap.FixedBufferAllocator.init(if (page_mode) try gpa.alloc(u8, region_mb << 20) else &[_]u8{});
    const scripts_on = std.c.getenv("WEBSHOT_SCRIPTS") != null;
    const doc = try web.html.parse(if (page_mode) dom_fba.allocator() else gpa, text, .{ .scripting = scripts_on });
    if (page_mode) {
        var text_bytes: usize = 0;
        var attr_bytes: usize = 0;
        var attrs_n: usize = 0;
        for (0..doc.nodes.len) |ni| {
            const n = doc.nodes.get(ni);
            text_bytes += n.text.capacity;
            attr_bytes += n.attrs.capacity * @sizeOf(web.dom.Attr);
            attrs_n += n.attrs.items.len;
        }
        std.debug.print("webshot: page memory: markup {d} KB, dom {d} KB for {d} nodes (node {d} B, list capacity {d} = {d} KB, text buffers {d} KB, attribute lists {d} KB for {d} attrs)\n", .{ text.len / 1024, dom_fba.end_index / 1024, doc.nodes.len, @sizeOf(web.dom.Node), doc.nodes.capacity(), doc.nodes.capacity() * @sizeOf(web.dom.Node) / 1024, text_bytes / 1024, attr_bytes / 1024, attrs_n });
    }
    web.style.px_scale = zoom;
    const env: web.style.Env = .{ .width = @as(f64, @floatFromInt(vw)) / zoom, .height = @as(f64, @floatFromInt(vh)) / zoom };
    const ua = try web.style.parseSheet(gpa, web.style.ua_sheet, .user_agent, env);
    if (scripts_on) try runPageScripts(doc, &ua, env, &faces, vw, vh);
    var dummy: u8 = 0;
    const loader: web.style.Loader = .{ .ctx = @ptrCast(&dummy), .fetch = sheetFetch };
    // WEBSHOT_PAGE=1: the page domain's memory — sheets parsed through a
    // scratch and kept (deep-copied) in the document arena, then the
    // cascade and layout in what the region leaves.
    const sheets = if (page_mode) blk: {
        page_scratch = std.heap.FixedBufferAllocator.init(try gpa.alloc(u8, 12 << 20));
        page_keep = std.heap.FixedBufferAllocator.init(try gpa.alloc(u8, 12 << 20));
        const keep: web.style.Keep = .{ .ctx = @ptrCast(&dummy), .a = page_keep.allocator(), .keep = keepSheet };
        const got = web.style.collectDocumentSheetsKept(page_scratch.allocator(), doc, env, ua, loader, keep) catch |e| {
            std.debug.print("webshot: page memory: {s} (scratch peak {d} KB, kept {d} KB)\n", .{ @errorName(e), scratch_peak / 1024, page_keep.end_index / 1024 });
            return 1;
        };
        std.debug.print("webshot: page memory: scratch peak {d} KB, kept {d} KB\n", .{ scratch_peak / 1024, page_keep.end_index / 1024 });
        break :blk got;
    } else try web.style.collectDocumentSheetsLoading(gpa, doc, env, ua, loader);

    // Web fonts, as the page loads them.
    for (sheets) |sheet| for (sheet.font_faces) |ff| {
        const href = resolve(ff.src, ff.base) orelse continue;
        const f = fetch(href) orelse continue;
        var out_len: usize = f.body.len;
        if (f.body.len >= 20 and (std.mem.eql(u8, f.body[0..4], "wOFF") or std.mem.eql(u8, f.body[0..4], "wOF2"))) out_len = std.mem.readInt(u32, f.body[16..20], .big);
        const out = try gpa.alloc(u8, @max(out_len, f.body.len));
        const sfnt = font.toSfnt(gpa, f.body, out) catch {
            std.debug.print("webshot: font-face unreadable: {s}\n", .{ff.family});
            continue;
        };
        const face = font.Font.parse(sfnt) catch continue;
        if (faces.addWebFace(ff.family, face)) std.debug.print("webshot: font-face {s}\n", .{ff.family});
    };

    const images: web.layout.Images = .{ .ctx = @ptrCast(&dummy), .vtable = &images_vtable };
    const t_sheets = std.Io.Clock.awake.now(io);
    if (page_mode) {
        // The cascade and layout in the page's 12 MB layout arena.
        // What the shared 24 MB region leaves after the kept sheets (the
        // DOM and the page's bytes live there too: this is optimistic).
        probe_fba = std.heap.FixedBufferAllocator.init(try gpa.alloc(u8, (region_mb << 20) - page_keep.end_index));
        var fba = &probe_fba;
        // Every allocation by size, to see what the layout arena holds.
        histo_inner = fba.allocator();
        const la: std.mem.Allocator = .{ .ptr = @ptrCast(&dummy), .vtable = &histo_vtable };
        const st = try la.create(web.style.Styles);
        st.* = web.style.compute(la, doc, sheets, env) catch |e| {
            std.debug.print("webshot: page memory: cascade {s} at {d} KB\n", .{ @errorName(e), fba.end_index / 1024 });
            return 1;
        };
        const after_style = fba.end_index;
        const pl = web.layout.layoutDocumentWith(la, doc, st, faces.fonts(), images, @floatFromInt(vw), @floatFromInt(vh)) catch |e| {
            std.debug.print("webshot: page memory: layout {s} (cascade {d} KB, at {d} KB)\n", .{ @errorName(e), after_style / 1024, fba.end_index / 1024 });
            return 1;
        };
        var kids_cap: usize = 0;
        var kids_n: usize = 0;
        var lines_cap: usize = 0;
        var lines_n: usize = 0;
        var dead_boxes: usize = 0;
        for (0..pl.boxes.len) |bi| {
            const b = pl.boxes.get(bi);
            kids_cap += b.children.capacity;
            kids_n += b.children.items.len;
            lines_cap += b.lines.capacity;
            lines_n += b.lines.items.len;
            if (b.style.display == .none) dead_boxes += 1;
        }
        var dead_frags: usize = 0;
        for (0..pl.fragments.len) |fi| if (pl.fragments.get(fi).dead) {
            dead_frags += 1;
        };
        for (histo, 0..) |h, i| if (h.count > 0) {
            std.debug.print("webshot: page memory: allocs <{d} B: {d} for {d} KB (freed {d}, resized {d}, grown in place {d})\n", .{ @as(usize, 1) << @intCast(i), h.count, h.bytes / 1024, h.freed, h.resized, h.grown });
        };
        std.debug.print("webshot: page memory: children lists {d} KB capacity for {d} entries, line lists {d} KB capacity for {d} lines (line {d} B), dead fragments {d}, display-none boxes {d}\n", .{ kids_cap * 4 / 1024, kids_n, lines_cap * @sizeOf(web.layout.Line) / 1024, lines_n, @sizeOf(web.layout.Line), dead_frags, dead_boxes });
        // The dozen callers holding the most of the layout arena.
        var shown: usize = 0;
        while (shown < 12) : (shown += 1) {
            var best: ?*Site = null;
            for (&meta_sites) |*site| if (site.ra != 0 and site.live > 0 and (best == null or site.live > best.?.live)) {
                best = site;
            };
            const bs = best orelse break;
            std.debug.print("webshot: page memory: {d} KB live in {d} blocks from:\n", .{ bs.live / 1024, bs.count });
            dumpSite(bs);
            bs.live = 0;
        }
        std.debug.print("webshot: page memory: {d} inline layouts made {d} lines, {d} into lists without room; scratch peak {d} KB, {d} fallbacks to the arena\n", .{ web.layout.stat_inline_layouts, web.layout.stat_lines, web.layout.stat_line_growth, web.layout.stat_scratch_peak / 1024, web.layout.stat_scratch_fallbacks });
        std.debug.print("webshot: page memory: cascade {d} KB ({d} computed styles of {d} B), layout {d} KB ({d} boxes of {d} B, capacity {d}; {d} fragments of {d} B, capacity {d})\n", .{ after_style / 1024, st.computed.len, @sizeOf(web.style.Computed), (fba.end_index - after_style) / 1024, pl.boxes.len, @sizeOf(web.layout.Box), pl.boxes.capacity(), pl.fragments.len, @sizeOf(web.layout.Fragment), pl.fragments.capacity() });
    }
    var styles = try gpa.create(web.style.Styles);
    styles.* = try web.style.compute(gpa, doc, sheets, env);
    const t_style = std.Io.Clock.awake.now(io);
    var l = try web.layout.layoutDocumentWith(gpa, doc, styles, faces.fonts(), images, @floatFromInt(vw), @floatFromInt(vh));
    const t_layout = std.Io.Clock.awake.now(io);
    std.debug.print("webshot: to sheets {d} ms, style {d} ms, layout {d} ms\n", .{ @divTrunc(t0.durationTo(t_sheets).nanoseconds, std.time.ns_per_ms), @divTrunc(t_sheets.durationTo(t_style).nanoseconds, std.time.ns_per_ms), @divTrunc(t_style.durationTo(t_layout).nanoseconds, std.time.ns_per_ms) });

    // Every picture the layout has a box for, then a relayout.
    for (0..l.boxes.len) |bi| {
        const b = l.boxes.get(bi);
        const node = b.node orelse continue;
        if (b.kind != .text and doc.get(node).namespace == .svg and std.mem.eql(u8, doc.get(node).name, "svg")) {
            const cw = b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3];
            const chh = b.h - b.border[0] - b.border[2] - b.padding[0] - b.padding[2];
            if (cw < 1 or chh < 1) continue;
            var markup: std.ArrayList(u8) = .empty;
            try web.html.serializeOuter(gpa, doc, node, &markup);
            const c = b.style.color;
            const fill: ?[4]f64 = if (b.style.fill) |f| switch (f) {
                .none => .{ 0, 0, 0, 0 },
                .current => .{ c.r, c.g, c.b, c.a },
                .color => |fc| .{ fc.r, fc.g, fc.b, fc.a },
            } else null;
            const img = mosslib.svg.renderSize(gpa, markup.items, @intFromFloat(@round(cw)), @intFromFloat(@round(chh)), .{ c.r, c.g, c.b, c.a }, fill) catch continue;
            try pictures.append(gpa, .{ .node = node, .bm = .{ .w = img.w, .h = img.h, .rgba = img.rgba, .density = @as(f64, @floatFromInt(img.w)) / cw * zoom } });
            continue;
        }
        if (!doc.isHtml(node, "img")) continue;
        if (imagesGet(undefined, node) != null) continue;
        var bm: ?web.layout.Bitmap = null;
        defer pictures.append(gpa, .{ .node = node, .bm = bm }) catch {};
        const src = doc.getAttr(node, "src") orelse continue;
        const href = resolve(src, null) orelse continue;
        const f = fetch(href) orelse continue;
        bm = decodePicture(f.body, href) orelse continue;
        std.debug.print("webshot: image {d}x{d} {s}\n", .{ bm.?.w, bm.?.h, href });
    }
    // Every background picture a box asks for.
    for (0..l.boxes.len) |bi| {
        const b = l.boxes.get(bi);
        for ([_]struct { img: web.style.BackgroundImage, base: ?[]const u8 }{ .{ .img = b.style.background_image, .base = b.style.background_base }, .{ .img = b.style.mask_image, .base = b.style.mask_base } }) |layer| {
            if (b.kind == .text or layer.img != .url) continue;
            const href = resolve(layer.img.url, layer.base) orelse continue;
            var known = false;
            for (backgrounds.items) |k| if (std.mem.eql(u8, k.href, href)) {
                known = true;
            };
            if (known) continue;
            const f = fetch(href) orelse continue;
            const bm = decodePicture(f.body, href);
            try backgrounds.append(gpa, .{ .href = href, .bm = bm });
            if (bm) |x| std.debug.print("webshot: background {d}x{d} {s}\n", .{ x.w, x.h, href[0..@min(href.len, 120)] });
        }
    }
    styles = try gpa.create(web.style.Styles);
    styles.* = try web.style.compute(gpa, doc, sheets, env);
    l = try web.layout.layoutDocumentWith(gpa, doc, styles, faces.fonts(), images, @floatFromInt(vw), @floatFromInt(vh));

    if (std.c.getenv("WEBSHOT_DUMP")) |needle_z| {
        // Every box whose element's id or class holds the needle, with
        // its subtree three deep.
        const needle = std.mem.span(needle_z);
        for (0..l.boxes.len) |i| {
            const b = l.boxes.get(i);
            const node = b.node orelse continue;
            const idv = doc.getAttr(node, "id") orelse "";
            const cls = doc.getAttr(node, "class") orelse "";
            if (std.mem.indexOf(u8, idv, needle) == null and std.mem.indexOf(u8, cls, needle) == null) continue;
            dumpBox(doc, l, @intCast(i), 0);
        }
    }
    if (std.c.getenv("WEBSHOT_BOX")) |bz| {
        const bi = std.fmt.parseInt(u32, std.mem.span(bz), 10) catch 0;
        var q: ?u32 = bi;
        while (q) |qq| : (q = l.get(qq).parent) dumpBox(doc, l, qq, 3);
    }
    if (std.c.getenv("WEBSHOT_AT")) |at_z| {
        // Every box holding the point, outermost first.
        const at = std.mem.span(at_z);
        const comma = std.mem.indexOfScalar(u8, at, ',') orelse 0;
        const px_ = std.fmt.parseFloat(f64, at[0..comma]) catch 0;
        const py_ = std.fmt.parseFloat(f64, at[comma + 1 ..]) catch 0;
        for (0..l.boxes.len) |i| {
            const b = l.boxes.get(i);
            if (b.kind == .text or px_ < b.x or py_ < b.y or px_ >= b.x + b.w or py_ >= b.y + b.h) continue;
            dumpBox(doc, l, @intCast(i), 3);
        }
    }
    if (std.c.getenv("WEBSHOT_SUB")) |sb| {
        const id = std.fmt.parseInt(u32, std.mem.span(sb), 10) catch 0;
        dumpBox(doc, l, id, 0);
    }
    if (std.c.getenv("WEBSHOT_TABLE")) |tb| {
        const id = std.fmt.parseInt(u32, std.mem.span(tb), 10) catch 0;
        try web.layout.debugTableColumns(l, id);
    }
    if (std.c.getenv("WEBSHOT_FRAG")) |needle_z| {
        const needle = std.mem.span(needle_z);
        for (0..l.fragments.len) |i| {
            const f = l.fragments.get(i);
            if (std.mem.indexOf(u8, f.text, needle) == null) continue;
            std.debug.print("frag {d}: box {d} dead={} at {d:.1},{d:.1} text \"{s}\" chain:", .{ i, f.box, f.dead, f.x, f.y, f.text });
            var q: ?u32 = f.box;
            while (q) |qq| : (q = l.get(qq).parent) {
                const bq = l.get(qq);
                std.debug.print(" {d}:{s}{s}", .{ qq, @tagName(bq.kind), if (bq.node) |n| doc.get(n).name else "" });
            }
            std.debug.print("\n", .{});
        }
        // which boxes' lines reach each frag
        for (0..l.boxes.len) |bi| for (l.boxes.get(bi).lines.items) |ln| {
            for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| {
                if (std.mem.indexOf(u8, l.fragments.get(fi).text, needle) != null) std.debug.print("  box {d} line reaches frag {d}\n", .{ bi, fi });
            }
        };
    }
    const extent: usize = @intFromFloat(@max(1, l.get(l.root).h));
    const h = @min(max_h, @max(extent, vh));
    const px = try gpa.alloc(u32, vw * h);
    const canvas = ui.Canvas.init(px.ptr, vw, h);
    canvas.fillAll(0xffffff);
    try web.paint.paint(l, &canvas, 0);
    // WEBSHOT_SCROLL=N: paint the viewport again scrolled to N, timed.
    if (std.c.getenv("WEBSHOT_SCROLL")) |sc| {
        const at = std.fmt.parseFloat(f64, std.mem.span(sc)) catch 0;
        const vpx = try gpa.alloc(u32, vw * vh);
        var vc = ui.Canvas.init(vpx.ptr, vw, vh);
        const t1 = std.Io.Clock.awake.now(io);
        vc.fillAll(0xffffff);
        try web.paint.paint(l, &vc, at);
        const t2 = std.Io.Clock.awake.now(io);
        vc.clip_y0 = vh - 100;
        vc.fillRect(0, vh - 100, vw, 100, 0xffffff);
        try web.paint.paint(l, &vc, at + 100);
        const t3 = std.Io.Clock.awake.now(io);
        std.debug.print("webshot: viewport paint at {d}: {d} ms; a 100-row band: {d} ms\n", .{ at, @divTrunc(t1.durationTo(t2).nanoseconds, std.time.ns_per_ms), @divTrunc(t2.durationTo(t3).nanoseconds, std.time.ns_per_ms) });
        // The scrolled viewport with its band, beside the page: what a
        // band repaint on the target would show.
        var spm: std.ArrayList(u8) = .empty;
        try spm.print(gpa, "P6\n{d} {d}\n255\n", .{ vw, vh });
        for (vpx) |q| try spm.appendSlice(gpa, &.{ @truncate(q >> 16), @truncate(q >> 8), @truncate(q) });
        const scroll_path = try std.fmt.allocPrint(gpa, "{s}.scroll.ppm", .{out_path});
        try cwd.writeFile(io, .{ .sub_path = scroll_path, .data = spm.items });
    }
    const ms = @divTrunc(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms);
    std.debug.print("webshot: {s}: {d} nodes, extent {d}px, {d} ms\n", .{ doc_f.url, doc.nodes.len, extent, ms });

    var ppm: std.ArrayList(u8) = .empty;
    try ppm.print(gpa, "P6\n{d} {d}\n255\n", .{ vw, h });
    try ppm.ensureUnusedCapacity(gpa, vw * h * 3);
    for (px) |p| ppm.appendSliceAssumeCapacity(&.{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) });
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = ppm.items });
    return 0;
}

// ------------------------------------------------------------ scripts

/// The page domain's script memory, sized as there (`user/webpage.zig`):
/// a site that runs out here runs out on the target.
var js_region: []align(16) u8 = &.{};
var js_meta_buf: []align(16) u8 = &.{};
var js_meta: mosslib.heapalloc.Allocator = undefined;

/// The bookkeeping heap's live bytes by request size (WEBSHOT_VERBOSE):
/// what a site's scripts keep there.
const MetaHisto = struct { count: usize = 0, bytes: usize = 0, live_count: usize = 0, live_bytes: usize = 0 };
var meta_histo: [40]MetaHisto = @splat(.{});
fn metaBucket(n: usize) usize {
    return @min(39, if (n == 0) 0 else std.math.log2_int_ceil(usize, n));
}
/// Live bytes by the callers that asked — the four frames above the
/// allocator, since the nearest is often the standard library's own
/// `rawAlloc` — for the top consumers to be named.
const site_frames = 4;
const Site = struct { ra: usize = 0, ras: [site_frames]usize = @splat(0), live: usize = 0, count: usize = 0 };
var meta_sites: [1 << 16]Site = @splat(.{});
var meta_unattributed: usize = 0;
/// The return addresses of the frames above the caller's, by the frame
/// pointer chain (kept in every build mode this tool uses).
fn captureFrames(out: []usize) void {
    @memset(out, 0);
    var fp: usize = @frameAddress();
    var n: usize = 0;
    var skip: usize = 1; // this function's own frame
    while (n < out.len and fp != 0) {
        const prev: usize = @as(*const usize, @ptrFromInt(fp)).*;
        const ra: usize = @as(*const usize, @ptrFromInt(fp + @sizeOf(usize))).*;
        if (ra == 0) break;
        if (skip > 0) {
            skip -= 1;
        } else {
            out[n] = ra;
            n += 1;
        }
        if (prev <= fp) break;
        fp = prev;
    }
}
fn siteOf(_: usize) ?*Site {
    var ras: [site_frames]usize = undefined;
    captureFrames(&ras);
    const key: usize = @truncate(std.hash.Wyhash.hash(0, std.mem.asBytes(&ras)) | 1);
    var i: usize = (key >> 4) % meta_sites.len;
    var n: usize = 0;
    while (n < meta_sites.len) : (n += 1) {
        const s = &meta_sites[i];
        if (s.ra == key) return s;
        if (s.ra == 0) {
            s.ra = key;
            s.ras = ras;
            return s;
        }
        i = (i + 1) % meta_sites.len;
    }
    return null;
}
fn dumpSite(s: *const Site) void {
    var n: usize = 0;
    while (n < site_frames and s.ras[n] != 0) n += 1;
    var addrs: [site_frames]usize = s.ras;
    const st: std.debug.StackTrace = .{ .return_addresses = addrs[0..n], .skipped = .none };
    std.debug.dumpStackTrace(&st);
}
/// The site a block came from, kept in a side table keyed by address
/// (the allocator's blocks have no room for it).
const Owner = struct { ptr: usize = 0, site: ?*Site = null, len: usize = 0 };
var meta_owners: [1 << 22]Owner = @splat(.{});
var meta_owners_used: usize = 0;
fn ownerSlot(ptr: usize) *Owner {
    var i: usize = (ptr >> 4) % meta_owners.len;
    while (meta_owners[i].ptr != 0 and meta_owners[i].ptr != ptr) i = (i + 1) % meta_owners.len;
    if (meta_owners[i].ptr == 0) meta_owners_used += 1;
    return &meta_owners[i];
}
fn metaAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, ra: usize) ?[*]u8 {
    const b = &meta_histo[metaBucket(len)];
    b.count += 1;
    b.bytes += len;
    b.live_count += 1;
    b.live_bytes += len;
    const p = js_meta.allocator().rawAlloc(len, alignment, ra) orelse {
        std.debug.print("webshot: scripts: meta refused {d} bytes (live {d} KB, top {d} KB of {d})\n", .{ len, js_meta.live / 1024, js_meta.top / 1024, js_meta_buf.len / 1024 });
        return null;
    };
    if (meta_owners_used < meta_owners.len / 2) {
        if (siteOf(ra)) |s| {
            s.live += len;
            s.count += 1;
            const o = ownerSlot(@intFromPtr(p));
            o.* = .{ .ptr = @intFromPtr(p), .site = s, .len = len };
        } else meta_unattributed += len;
    } else meta_unattributed += len;
    return p;
}
fn metaForget(ptr: [*]u8) void {
    const o = ownerSlot(@intFromPtr(ptr));
    if (o.ptr == 0) return;
    if (o.site) |s| s.live -= o.len;
    o.site = null;
    // Kept as a tombstone (the probe never clears); a re-used address
    // takes the slot again.
    o.len = 0;
}
fn metaTrack(ptr: [*]u8, new_len: usize) void {
    const o = ownerSlot(@intFromPtr(ptr));
    if (o.ptr == 0) return;
    if (o.site) |s| s.live = s.live - o.len + new_len;
    o.len = new_len;
}
fn metaResize(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) bool {
    const ok = js_meta.allocator().rawResize(mem, alignment, new_len, ra);
    if (ok) {
        metaTrack(mem.ptr, new_len);
        const ob = &meta_histo[metaBucket(mem.len)];
        ob.live_count -= 1;
        ob.live_bytes -= mem.len;
        const nb = &meta_histo[metaBucket(new_len)];
        nb.live_count += 1;
        nb.live_bytes += new_len;
    }
    return ok;
}
fn metaRemap(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    const p = js_meta.allocator().rawRemap(mem, alignment, new_len, ra) orelse return null;
    metaTrack(mem.ptr, new_len);
    const ob = &meta_histo[metaBucket(mem.len)];
    ob.live_count -= 1;
    ob.live_bytes -= mem.len;
    const nb = &meta_histo[metaBucket(new_len)];
    nb.live_count += 1;
    nb.live_bytes += new_len;
    return p;
}
fn metaFree(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, ra: usize) void {
    const b = &meta_histo[metaBucket(mem.len)];
    b.live_count -= 1;
    b.live_bytes -= mem.len;
    metaForget(mem.ptr);
    js_meta.allocator().rawFree(mem, alignment, ra);
}
const meta_vtable: std.mem.Allocator.VTable = .{ .alloc = metaAlloc, .resize = metaResize, .remap = metaRemap, .free = metaFree };
var meta_dummy: u8 = 0;
fn metaAllocator() std.mem.Allocator {
    return .{ .ptr = @ptrCast(&meta_dummy), .vtable = &meta_vtable };
}
var vm: js.vm.Vm = undefined;
var page: script.Page = undefined;
var fake_now: f64 = 0;

/// What the bindings' hooks lay out against: the current document,
/// re-cascaded and re-laid-out when a script changed it and asks.
const ScriptCtx = struct {
    doc: *dom.Document,
    ua: *const web.style.Sheet,
    env: web.style.Env,
    faces: *web.fonts.FaceFonts,
    vw: usize,
    vh: usize,
    styles: ?*web.style.Styles = null,
    layout: ?*web.layout.Layout = null,
    layouts: usize = 0,
    layout_ms: i64 = 0,
    requests: usize = 0,
    errors: usize = 0,
    lines: usize = 0,

    fn layoutNow(c: *ScriptCtx) void {
        if (page.takeDirty() or c.layout == null) {
            _ = page.takeSheetsDirty();
            const t1 = std.Io.Clock.awake.now(io);
            var dummy: u8 = 0;
            const loader: web.style.Loader = .{ .ctx = @ptrCast(&dummy), .fetch = sheetFetch };
            const sheets = web.style.collectDocumentSheetsLoading(gpa, c.doc, c.env, c.ua.*, loader) catch return;
            const st = gpa.create(web.style.Styles) catch return;
            st.* = web.style.compute(gpa, c.doc, sheets, c.env) catch return;
            const images: web.layout.Images = .{ .ctx = @ptrCast(&dummy), .vtable = &images_vtable };
            const l = web.layout.layoutDocumentWith(gpa, c.doc, st, c.faces.fonts(), images, @floatFromInt(c.vw), @floatFromInt(c.vh)) catch return;
            c.styles = st;
            c.layout = l;
            c.layouts += 1;
            c.layout_ms += @intCast(@divTrunc(t1.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms));
        }
    }
};

fn ctxOf(ctx: *anyopaque) *ScriptCtx {
    return @ptrCast(@alignCast(ctx));
}

fn scriptLog(ctx: *anyopaque, level: script.Level, text: []const u8) void {
    const c = ctxOf(ctx);
    c.lines += 1;
    if (level == .err) c.errors += 1;
    std.debug.print("webshot: script {s} [meta {d} KB, heap {d} KB]: {s}\n", .{ switch (level) {
        .log => "console",
        .warn => "warn",
        .err => "error",
    }, js_meta.live / 1024, vm.heap.live_bytes / 1024, text[0..@min(text.len, 400)] });
}

fn scriptFetch(_: *anyopaque, abs_url: []const u8) ?[]const u8 {
    const f = fetch(abs_url) orelse return null;
    if (f.status >= 400) return null;
    return web.encoding.decode(gpa, web.encoding.detect(f.body, f.content_type), f.body) catch null;
}

fn scriptRequest(ctx: *anyopaque, a: std.mem.Allocator, abs_url: []const u8, post: bool, body: []const u8, origin: []const u8, out: *script.Response) bool {
    _ = post;
    _ = body;
    _ = origin;
    ctxOf(ctx).requests += 1;
    const f = fetch(abs_url) orelse {
        out.refused = "network";
        return false;
    };
    out.status = @intCast(@min(f.status, 999));
    out.url = a.dupe(u8, f.url) catch return false;
    out.content_type = a.dupe(u8, f.content_type) catch return false;
    out.body = a.dupe(u8, f.body) catch return false;
    return true;
}

fn scriptRect(ctx: *anyopaque, id: dom.NodeId) ?[4]f64 {
    const c = ctxOf(ctx);
    c.layoutNow();
    const l = c.layout orelse return null;
    var have = false;
    var r: [4]f64 = .{ 0, 0, 0, 0 };
    for (0..l.boxes.len) |i| {
        const b = l.boxes.get(i);
        if (b.node != id) continue;
        switch (b.kind) {
            .inline_box, .text => for (0..l.fragments.len) |fi| {
                const f = l.fragments.get(fi);
                if (f.dead or f.box != @as(web.layout.BoxId, @intCast(i))) continue;
                r = if (have) union4(r, .{ f.x, f.y, f.w, f.h }) else .{ f.x, f.y, f.w, f.h };
                have = true;
            },
            else => {
                r = if (have) union4(r, .{ b.x, b.y, b.w, b.h }) else .{ b.x, b.y, b.w, b.h };
                have = true;
            },
        }
    }
    return if (have) r else null;
}

fn union4(a: [4]f64, b: [4]f64) [4]f64 {
    const x0 = @min(a[0], b[0]);
    const y0 = @min(a[1], b[1]);
    const x1 = @max(a[0] + a[2], b[0] + b[2]);
    const y1 = @max(a[1] + a[3], b[1] + b[3]);
    return .{ x0, y0, x1 - x0, y1 - y0 };
}

fn scriptComputed(ctx: *anyopaque, id: dom.NodeId, name: []const u8, buf: []u8) ?[]const u8 {
    const c = ctxOf(ctx);
    c.layoutNow();
    const st = c.styles orelse return null;
    if (id >= st.computed.len) return null;
    return web.style.propertyText(st.get(id), name, buf);
}

fn scriptNavigate(_: *anyopaque, abs_url: []const u8) void {
    std.debug.print("webshot: script navigates to {s} (not followed)\n", .{abs_url});
}

fn scriptScratch(_: *anyopaque) std.mem.Allocator {
    return gpa;
}

/// The wall clock for the page host's setup line (the page's own clock is faked).
fn hostClock() u64 {
    return @intCast(@divTrunc(std.Io.Clock.awake.now(io).nanoseconds, std.time.ns_per_ms));
}

fn scriptNow() f64 {
    return fake_now;
}

/// Run the document's scripts and settle their timers, as the page
/// domain does after parsing, then report.
fn runPageScripts(doc: *dom.Document, ua: *const web.style.Sheet, env: web.style.Env, faces: *web.fonts.FaceFonts, vw: usize, vh: usize) !void {
    const settle_ms: f64 = if (std.c.getenv("WEBSHOT_SETTLE")) |v| @floatFromInt(try std.fmt.parseInt(u32, std.mem.span(v), 10)) else 3000;
    var ctx: ScriptCtx = .{ .doc = doc, .ua = ua, .env = env, .faces = faces, .vw = vw, .vh = vh };
    // WEBSHOT_META_MB / WEBSHOT_HEAP_MB: the bookkeeping and cell heaps'
    // sizes (the page's: 32 and 16).
    const meta_mb: usize = if (std.c.getenv("WEBSHOT_META_MB")) |v| try std.fmt.parseInt(usize, std.mem.span(v), 10) else 32;
    const heap_mb: usize = if (std.c.getenv("WEBSHOT_HEAP_MB")) |v| try std.fmt.parseInt(usize, std.mem.span(v), 10) else 24;
    js_meta_buf = try gpa.alignedAlloc(u8, .@"16", meta_mb << 20);
    js_region = try gpa.alignedAlloc(u8, .@"16", heap_mb << 20);
    js_meta = mosslib.heapalloc.Allocator.init(js_meta_buf);
    const meta = metaAllocator();
    // A budget (backward jumps and calls), so a script that never ends
    // names itself instead of running the tool forever: `WEBSHOT_STEPS`
    // in millions, 300 by default.
    const steps_mb: u64 = if (std.c.getenv("WEBSHOT_STEPS")) |v| std.fmt.parseInt(u64, std.mem.span(v), 10) catch 300 else 300;
    defer vm.step_limit = std.math.maxInt(u64);
    vm.initWith(js_region, meta, .{ .stack_values = 1 << 16, .max_frames = 4000, .meta_stride = js_meta_buf.len / 8 }) catch {
        std.debug.print("webshot: the script engine did not fit its heap\n", .{});
        return;
    };
    vm.host_now = scriptNow;
    // WEBSHOT_NOSCAN=1: the collector without the native-stack scan (to
    // see what the scan keeps alive; unsafe under natives).
    if (std.c.getenv("WEBSHOT_NOSCAN") != null) vm.heap.stack_hi = 0;
    vm.step_limit = steps_mb * 1_000_000;
    page.init(&vm, doc, meta, .{ .ctx = @ptrCast(&ctx), .log = scriptLog, .fetch = scriptFetch, .rect = scriptRect, .computed = scriptComputed, .request = scriptRequest, .navigate = scriptNavigate, .ua_sheet = ua, .scratch = scriptScratch, .clock = hostClock }) catch {
        std.debug.print("webshot: the bindings did not fit\n", .{});
        return;
    };
    page.verbose = std.c.getenv("WEBSHOT_VERBOSE") != null;
    page.setViewport(@intCast(vw), @intCast(vh));
    const href = try page_base.href(gpa);
    try page.setUrl(href);
    if (std.c.getenv("WEBSHOT_PROBE") != null) {
        var k: usize = 0;
        while (k < 5) : (k += 1) {
            const a0 = std.Io.Clock.awake.now(io);
            page.runSource("var __p = 1;", "probe");
            const a1 = std.Io.Clock.awake.now(io);
            std.debug.print("webshot: probe compile+run {d} us\n", .{@divTrunc(a0.durationTo(a1).nanoseconds, 1000)});
        }
    }
    const t0 = std.Io.Clock.awake.now(io);
    page.runScripts();
    const t_run = std.Io.Clock.awake.now(io);
    // The clock is ours: jump to each due time, as the drill does,
    // until the page is quiet or the settle budget is spent.
    var ticks: usize = 0;
    var last_report: f64 = 0;
    while (page.nextDue()) |due| : (ticks += 1) {
        const at = @max(fake_now + 1, due);
        if (at > settle_ms or ticks > 20_000) break;
        fake_now = at;
        _ = page.runDue(at);
        if (fake_now - last_report >= 1000) {
            last_report = fake_now;
            std.debug.print("webshot: scripts: {d} ms of page time, {d} timers pending, heap {d} KB, meta {d} KB\n", .{ @as(u64, @intFromFloat(fake_now)), page.pendingTimers(), vm.heap.live_bytes / 1024, js_meta.live / 1024 });
        }
    }
    const t_settle = std.Io.Clock.awake.now(io);
    var rbuf: [1024]u8 = undefined;
    std.debug.print("webshot: scripts: meta {s}; cell heap {s}\n", .{ js_meta.report(&rbuf), if (vm.heap.exhausted) "EXHAUSTED" else "fit" });
    std.debug.print("webshot: scripts: {d} documents in the page (frames and made ones live in the bookkeeping heap)\n", .{page.docs.items.len});
    const cs = js.compiler.stats;
    std.debug.print("webshot: scripts: {d} functions compiled with their scripts, {d} left as stubs, {d} stubs compiled on call ({d} KB of source parsed again); not stubs because: {d} methods or class parts, {d} dynamic, {d} in parameter defaults, {d} arrows with super, {d} called at once\n", .{ cs.eager, cs.stubs, cs.lazy_compiles, cs.lazy_source_bytes / 1024, cs.not_normal, cs.dynamic, cs.in_params, cs.super_arrow, cs.called_at_once });
    const ps = js.parser.stats;
    std.debug.print("webshot: scripts: the parser dropped {d} bodies and kept {d} called at once, {d} dynamic, {d} arrows with super\n", .{ ps.dropped, ps.kept_called, ps.kept_dynamic, ps.kept_super });
    if (page.verbose) {
        for (meta_histo, 0..) |h, i| if (h.live_bytes > 0) {
            std.debug.print("webshot: scripts: meta live <{d} B: {d} blocks, {d} KB ({d} allocations in all)\n", .{ @as(usize, 1) << @intCast(i), h.live_count, h.live_bytes / 1024, h.count });
        };
        // The dozen callers holding the most, each named by its source line.
        std.debug.print("webshot: scripts: meta {d} KB allocated without a site (table full)\n", .{meta_unattributed / 1024});
        var shown: usize = 0;
        while (shown < 16) : (shown += 1) {
            var best: ?*Site = null;
            for (&meta_sites) |*s| if (s.ra != 0 and s.live > 0 and (best == null or s.live > best.?.live)) {
                best = s;
            };
            const b = best orelse break;
            std.debug.print("webshot: scripts: meta site {d} KB live in {d} blocks from:\n", .{ b.live / 1024, b.count });
            dumpSite(b);
            b.live = 0;
        }
    }
    std.debug.print("webshot: scripts: {d} scripts ran in {d} ms, {d} errors; settled {d} ticks to {d} ms of page time in {d} ms wall ({d} timers left); {d} layouts for script reads ({d} ms); {d} requests; heap {d} KB of {d}, meta {d} KB of {d}\n", .{ page.scripts_run, @divTrunc(t0.durationTo(t_run).nanoseconds, std.time.ns_per_ms), page.script_errors, ticks, @as(u64, @intFromFloat(fake_now)), @divTrunc(t_run.durationTo(t_settle).nanoseconds, std.time.ns_per_ms), page.pendingTimers(), ctx.layouts, ctx.layout_ms, ctx.requests, vm.heap.live_bytes / 1024, js_region.len / 1024, js_meta.live / 1024, js_meta_buf.len / 1024 });
}

fn dumpBox(doc: *const dom.Document, l: *const web.layout.Layout, id: u32, depth: usize) void {
    const b = l.get(id);
    const st = b.style;
    var ind: [16]u8 = @splat(' ');
    const name = if (b.node) |n| (if (doc.get(n).kind == .element) doc.get(n).name else "#text") else "-";
    const cls = if (b.node) |n| (doc.getAttr(n, "class") orelse doc.getAttr(n, "id") orelse "") else "";
    std.debug.print("{s}[{d}] {s} {s}.{s} at {d:.1},{d:.1} {d:.1}x{d:.1} disp={s} pos={s} order={d} w={any} h={any} minw={any} maxw={any} ws={s} m={any} text=\"{s}\"\n", .{ ind[0..@min(16, depth * 2)], id, @tagName(b.kind), name, cls[0..@min(cls.len, 40)], b.x, b.y, b.w, b.h, @tagName(st.display), @tagName(st.position), st.order, st.width, st.height, st.min_width, st.max_width, @tagName(st.white_space), b.margin, b.text[0..@min(b.text.len, 48)] });
    if (depth >= 3) return;
    for (b.children.items) |c| dumpBox(doc, l, c, depth + 1);
}

const system_faces = [_][]const u8{
    "assets/fonts/IBMPlexSans.ttf",
    "assets/fonts/IBMPlexMono-Regular.ttf",
    "assets/fonts/DroidSansFallbackFull.ttf",
};
