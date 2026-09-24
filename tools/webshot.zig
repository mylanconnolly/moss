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
const std = @import("std");
const mosslib = @import("mosslib");
const web = mosslib.web;
const font = mosslib.font;
const ui = mosslib.ui;
const dom = web.dom;

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
    const doc = try web.html.parse(gpa, text, .{});
    web.style.px_scale = zoom;
    const env: web.style.Env = .{ .width = @as(f64, @floatFromInt(vw)) / zoom, .height = @as(f64, @floatFromInt(vh)) / zoom };
    const ua = try web.style.parseSheet(gpa, web.style.ua_sheet, .user_agent, env);
    var dummy: u8 = 0;
    const loader: web.style.Loader = .{ .ctx = @ptrCast(&dummy), .fetch = sheetFetch };
    // WEBSHOT_PAGE=1: the page domain's memory — sheets parsed through a
    // 12 MB scratch and kept (deep-copied) in a 12 MB document arena.
    const page_mode = std.c.getenv("WEBSHOT_PAGE") != null;
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
        probe_fba = std.heap.FixedBufferAllocator.init(try gpa.alloc(u8, (24 << 20) - page_keep.end_index));
        var fba = &probe_fba;
        const la = fba.allocator();
        const st = try la.create(web.style.Styles);
        st.* = web.style.compute(la, doc, sheets, env) catch |e| {
            std.debug.print("webshot: page memory: cascade {s} at {d} KB\n", .{ @errorName(e), fba.end_index / 1024 });
            return 1;
        };
        const after_style = fba.end_index;
        _ = web.layout.layoutDocumentWith(la, doc, st, faces.fonts(), images, @floatFromInt(vw), @floatFromInt(vh)) catch |e| {
            std.debug.print("webshot: page memory: layout {s} (cascade {d} KB, at {d} KB)\n", .{ @errorName(e), after_style / 1024, fba.end_index / 1024 });
            return 1;
        };
        std.debug.print("webshot: page memory: cascade {d} KB, layout {d} KB\n", .{ after_style / 1024, (fba.end_index - after_style) / 1024 });
    }
    var styles = try gpa.create(web.style.Styles);
    styles.* = try web.style.compute(gpa, doc, sheets, env);
    const t_style = std.Io.Clock.awake.now(io);
    var l = try web.layout.layoutDocumentWith(gpa, doc, styles, faces.fonts(), images, @floatFromInt(vw), @floatFromInt(vh));
    const t_layout = std.Io.Clock.awake.now(io);
    std.debug.print("webshot: to sheets {d} ms, style {d} ms, layout {d} ms\n", .{ @divTrunc(t0.durationTo(t_sheets).nanoseconds, std.time.ns_per_ms), @divTrunc(t_sheets.durationTo(t_style).nanoseconds, std.time.ns_per_ms), @divTrunc(t_style.durationTo(t_layout).nanoseconds, std.time.ns_per_ms) });

    // Every picture the layout has a box for, then a relayout.
    for (l.boxes.items) |b| {
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
    for (l.boxes.items) |b| for ([_]struct { img: web.style.BackgroundImage, base: ?[]const u8 }{ .{ .img = b.style.background_image, .base = b.style.background_base }, .{ .img = b.style.mask_image, .base = b.style.mask_base } }) |layer| {
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
    };
    styles = try gpa.create(web.style.Styles);
    styles.* = try web.style.compute(gpa, doc, sheets, env);
    l = try web.layout.layoutDocumentWith(gpa, doc, styles, faces.fonts(), images, @floatFromInt(vw), @floatFromInt(vh));

    if (std.c.getenv("WEBSHOT_DUMP")) |needle_z| {
        // Every box whose element's id or class holds the needle, with
        // its subtree three deep.
        const needle = std.mem.span(needle_z);
        for (l.boxes.items, 0..) |b, i| {
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
        for (l.boxes.items, 0..) |b, i| {
            if (b.kind == .text or px_ < b.x or py_ < b.y or px_ >= b.x + b.w or py_ >= b.y + b.h) continue;
            dumpBox(doc, l, @intCast(i), 3);
        }
    }
    if (std.c.getenv("WEBSHOT_FRAG")) |needle_z| {
        const needle = std.mem.span(needle_z);
        for (l.fragments.items, 0..) |f, i| {
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
        for (l.boxes.items, 0..) |b, bi| for (b.lines.items) |ln| {
            for (ln.first_frag..ln.first_frag + ln.frag_count) |fi| {
                if (std.mem.indexOf(u8, l.fragments.items[fi].text, needle) != null) std.debug.print("  box {d} line reaches frag {d}\n", .{ bi, fi });
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
        try web.paint.paint(l, &vc, at + 100);
        const t3 = std.Io.Clock.awake.now(io);
        std.debug.print("webshot: viewport paint at {d}: {d} ms; a 100-row band: {d} ms\n", .{ at, @divTrunc(t1.durationTo(t2).nanoseconds, std.time.ns_per_ms), @divTrunc(t2.durationTo(t3).nanoseconds, std.time.ns_per_ms) });
    }
    const ms = @divTrunc(t0.durationTo(std.Io.Clock.awake.now(io)).nanoseconds, std.time.ns_per_ms);
    std.debug.print("webshot: {s}: {d} nodes, extent {d}px, {d} ms\n", .{ doc_f.url, doc.nodes.items.len, extent, ms });

    var ppm: std.ArrayList(u8) = .empty;
    try ppm.print(gpa, "P6\n{d} {d}\n255\n", .{ vw, h });
    try ppm.ensureUnusedCapacity(gpa, vw * h * 3);
    for (px) |p| ppm.appendSliceAssumeCapacity(&.{ @truncate(p >> 16), @truncate(p >> 8), @truncate(p) });
    try cwd.writeFile(io, .{ .sub_path = out_path, .data = ppm.items });
    return 0;
}

fn dumpBox(doc: *const dom.Document, l: *const web.layout.Layout, id: u32, depth: usize) void {
    const b = l.get(id);
    const st = b.style;
    var ind: [16]u8 = @splat(' ');
    const name = if (b.node) |n| (if (doc.get(n).kind == .element) doc.get(n).name else "#text") else "-";
    const cls = if (b.node) |n| (doc.getAttr(n, "class") orelse doc.getAttr(n, "id") orelse "") else "";
    std.debug.print("{s}[{d}] {s} {s}.{s} at {d:.1},{d:.1} {d:.1}x{d:.1} disp={s} pos={s} order={d} w={any} h={any} m={any}\n", .{ ind[0..@min(16, depth * 2)], id, @tagName(b.kind), name, cls[0..@min(cls.len, 40)], b.x, b.y, b.w, b.h, @tagName(st.display), @tagName(st.position), st.order, st.width, st.height, b.margin });
    if (depth >= 3) return;
    for (b.children.items) |c| dumpBox(doc, l, c, depth + 1);
}

const system_faces = [_][]const u8{
    "assets/fonts/IBMPlexSans.ttf",
    "assets/fonts/IBMPlexMono-Regular.ttf",
    "assets/fonts/DroidSansFallbackFull.ttf",
};
