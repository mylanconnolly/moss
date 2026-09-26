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
const js = mosslib.js;
const script = web.script;

comptime {
    asm (usys.imageHeaderStack("webpage", 128));
}

pub const panic = std.debug.FullPanic(uPanic);

/// The panic line carries the faulting address and a walk up the frame
/// chain (each aarch64 frame is [fp, lr]); symbolize against the build's
/// `webpage.elf` with `nm -n` / `objdump -d -l` (HACKING.md).
fn uPanic(msg: []const u8, ret_addr: ?usize) noreturn {
    var line: [240]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: panic: {s} (at 0x{x})", .{ msg, ret_addr orelse 0 }) catch "webpage: panic");
    var fp: usize = @frameAddress();
    var depth: usize = 0;
    while (fp != 0 and depth < 12) : (depth += 1) {
        const frame: *const [2]usize = @ptrFromInt(fp);
        _ = usys.log(glog, std.fmt.bufPrint(&line, "  frame {d}: 0x{x}", .{ depth, frame[1] }) catch "?");
        if (frame[0] <= fp) break;
        fp = frame[0];
    }
    usys.exit(255);
}

var glog: u64 = 0;
var host: u64 = 0;

// ---------------------------------------------------------------- memory

/// The page's memory for a document, one region used from both ends.
/// From the bottom, the document arena: the bytes, the tree and its
/// kept sheets, and what the user changes in it (a typed value, a
/// ticked box) — reset on every navigation. From the top, the layout
/// arena: sheets being parsed, the computed styles and the box tree,
/// reset whole on every relayout (a resize, a keystroke, a zoom). A page
/// dies only when the two together outgrow it: GitHub keeps 12 MB of
/// document and sheets, the Python docs lay out 30,000 nodes, and two
/// fixed halves fit neither (2026-09-23).
var region: [40 << 20]u8 align(16) = undefined;
/// The document arena is [0, lo); the layout arena [hi, len).
var reg_lo: usize = 0;
var reg_hi: usize = region.len;

fn regionOffset(p: [*]u8) usize {
    return @intFromPtr(p) - @intFromPtr(&region);
}

const doc_vtable: std.mem.Allocator.VTable = .{ .alloc = docAlloc, .resize = docResize, .remap = docRemap, .free = docFree };

fn docAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const base = @intFromPtr(&region);
    const start = alignment.forward(base + reg_lo) - base;
    if (start + len > reg_hi) return null;
    reg_lo = start + len;
    return region[start..].ptr;
}

fn docResize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    const start = regionOffset(mem.ptr);
    // Only the last allocation grows in place; any may shrink.
    if (start + mem.len != reg_lo) return new_len <= mem.len;
    if (start + new_len > reg_hi) return false;
    reg_lo = start + new_len;
    return true;
}

fn docRemap(ctx: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, ra: usize) ?[*]u8 {
    return if (docResize(ctx, mem, alignment, new_len, ra)) mem.ptr else null;
}

fn docFree(_: *anyopaque, mem: []u8, _: std.mem.Alignment, _: usize) void {
    const start = regionOffset(mem.ptr);
    if (start + mem.len == reg_lo) reg_lo = start;
}

const layout_vtable: std.mem.Allocator.VTable = .{ .alloc = layoutAlloc, .resize = layoutResize, .remap = layoutRemap, .free = layoutFree };

fn layoutAlloc(_: *anyopaque, len: usize, alignment: std.mem.Alignment, _: usize) ?[*]u8 {
    const base = @intFromPtr(&region);
    if (len > reg_hi) return null;
    const start = alignment.backward(base + reg_hi - len) - base;
    if (start < reg_lo) return null;
    reg_hi = start;
    return region[start..].ptr;
}

fn layoutResize(_: *anyopaque, mem: []u8, _: std.mem.Alignment, new_len: usize, _: usize) bool {
    // Growing downward cannot keep the address: only shrinking holds.
    return new_len <= mem.len;
}

/// The most recent allocation grows by moving down, so the arena stays
/// dense — what a bump allocator growing upward does in place. Without
/// it every list growth was a fresh block and a dead one: the cascade
/// of a 1.2 MB article, 2 MB on the host, was 29 MB here (2026-09-24).
fn layoutRemap(_: *anyopaque, mem: []u8, alignment: std.mem.Alignment, new_len: usize, _: usize) ?[*]u8 {
    if (new_len <= mem.len) return mem.ptr;
    const base = @intFromPtr(&region);
    const start = regionOffset(mem.ptr);
    if (start != reg_hi or new_len > reg_hi + mem.len) return null;
    const new_start = alignment.backward(base + reg_hi + mem.len - new_len) - base;
    if (new_start < reg_lo) return null;
    std.mem.copyForwards(u8, region[new_start .. new_start + mem.len], region[start .. start + mem.len]);
    reg_hi = new_start;
    return region[new_start..].ptr;
}

fn layoutFree(_: *anyopaque, mem: []u8, _: std.mem.Alignment, _: usize) void {
    const start = regionOffset(mem.ptr);
    if (start == reg_hi) reg_hi = start + mem.len;
}

fn layoutArena() std.mem.Allocator {
    return .{ .ptr = @ptrCast(&region), .vtable = &layout_vtable };
}

fn resetLayout() void {
    reg_hi = region.len;
    web.layout.in_progress = null; // a failed layout's struct lived here
}

fn resetDocument() void {
    reg_lo = 0;
}
/// The script engine: the cells' heap and its bookkeeping (shapes,
/// atoms, compiled code, the wrapper table), both reset per navigation
/// — a document's scripts die with the document.
var js_region: [8 << 20]u8 align(16) = undefined;
/// 16 MB: compiling a 180 KB script (Acid3's) holds its parse tree
/// here until the code is out, and a real site's script is larger.
var js_meta_buf: [16 << 20]u8 align(16) = undefined;
var js_meta: mosslib.heapalloc.Allocator = undefined;
var vm: js.vm.Vm = undefined;
var scripts: script.Page = undefined;
var scripts_up = false;
/// Scripts run by default; the host may turn them off per site (`scripting`).
var scripting = true;

fn scriptLog(_: *anyopaque, level: script.Level, text: []const u8) void {
    var line: [1200]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: {s}: {s}", .{ switch (level) {
        .log => "console",
        .warn => "console warn",
        .err => "console error",
    }, text }) catch "webpage: console: (a line too long to log)");
}

fn scriptFetch(_: *anyopaque, abs_url: []const u8) ?[]const u8 {
    return fetchResource(abs_url, 4 << 20);
}

fn scriptNow() f64 {
    return @floatFromInt(usys.nowMs());
}

/// A script asks where an element is: the layout is brought up to date
/// first (a browser flushes layout on such a read), then the box in CSS
/// pixels relative to the viewport.
fn scriptRect(_: *anyopaque, id: dom.NodeId) ?[4]f64 {
    if (scripts_up and scripts.takeDirty()) relayout(scripts.takeSheetsDirty() or page.sheets.len == 0);
    const r = nodeRect(id) orelse return null;
    const s = zoomScale();
    return .{ r[0] / s, (r[1] - page.scroll_y) / s, r[2] / s, r[3] / s };
}

fn scriptComputed(_: *anyopaque, id: dom.NodeId, name: []const u8, buf: []u8) ?[]const u8 {
    if (scripts_up and scripts.takeDirty()) relayout(scripts.takeSheetsDirty() or page.sheets.len == 0);
    const styles = page.styles orelse return null;
    if (id >= styles.computed.len) return null;
    return web.style.propertyText(styles.get(id), name, buf);
}

/// A script's request: the resource whole through the host's broker,
/// any status (a 404 is an answer, not a refusal), capped at 4 MB.
fn scriptRequest(_: *anyopaque, a: std.mem.Allocator, url_text: []const u8, post: bool, body: []const u8, origin: []const u8, out: *script.Response) bool {
    switch (openUrlFrom(url_text, post, body, origin)) {
        .ok => |st| out.status = @intCast(@min(st, 999)),
        .refused => |code| {
            out.refused = @tagName(code);
            return false;
        },
    }
    out.url = a.dupe(u8, res_url[0..res_url_len]) catch return false;
    out.content_type = a.dupe(u8, res_type[0..res_type_len]) catch return false;
    var bytes: std.ArrayList(u8) = .empty;
    while (true) {
        const chunk = switch (call(.{ .read = .{ .max = data_len } })) {
            .chunk => |c| c,
            else => {
                out.refused = "protocol";
                return false;
            },
        };
        const n = @min(chunk.len, data_len);
        if (bytes.items.len + n > (4 << 20)) {
            _ = call(.cancel);
            out.refused = "too_large";
            return false;
        }
        bytes.appendSlice(a, data[0..n]) catch {
            _ = call(.cancel);
            out.refused = "memory";
            return false;
        };
        switch (std.enums.fromInt(wire.ChunkEnd, chunk.done) orelse .failed) {
            .more => {},
            .done => {
                out.body = bytes.items;
                return true;
            },
            .failed => {
                out.refused = "the body was cut short";
                return false;
            },
        }
    }
}

/// A script's navigation is taken once the script is done: a page
/// cannot tear its own document down under a running script.
var nav_pending = false;
var nav_url: [2048]u8 = undefined;
var nav_len: usize = 0;

fn scriptNavigate(_: *anyopaque, abs_url: []const u8) void {
    nav_len = @min(abs_url.len, nav_url.len);
    @memcpy(nav_url[0..nav_len], abs_url[0..nav_len]);
    nav_pending = true;
}

fn runPendingNavigation() void {
    if (!nav_pending) return;
    nav_pending = false;
    load(nav_url[0..nav_len], false, "");
}

/// The document's URL or title changed under script: the host's chrome
/// follows (the address bar, the tab's title).
fn scriptChanged(_: *anyopaque, what: script.Changed, text: []const u8) void {
    switch (what) {
        .url => {
            page.url_len = @min(text.len, page.url_buf.len);
            @memcpy(page.url_buf[0..page.url_len], text[0..page.url_len]);
            eventText(.url, page.url());
        },
        .title => eventText(.title, text),
    }
}

fn scriptSubmit(_: *anyopaque, form: dom.NodeId) void {
    submitFormOf(form, null);
}

fn scriptActivate(_: *anyopaque, id: dom.NodeId) void {
    activate(id, false);
}

/// `localStorage`: the host keeps it per origin; one call per operation.
fn scriptStorage(_: *anyopaque, op: script.StorageOp, k: []const u8, v: []const u8, buf: []u8) script.StorageResult {
    if (k.len + v.len > data_len) return .quota;
    const wop: wire.StorageOp = switch (op) {
        .get => .get,
        .set => .set,
        .remove => .remove,
        .clear => .clear,
        .key_at => .key_at,
        .length => .length,
    };
    var key_len: u64 = k.len;
    if (op == .key_at) {
        key_len = std.fmt.parseInt(u64, k, 10) catch return .none;
    } else {
        @memcpy(data[0..k.len], k);
        @memcpy(data[k.len .. k.len + v.len], v);
    }
    switch (call(.{ .storage = .{ .op = @intFromEnum(wop), .key_len = key_len, .value_len = v.len } })) {
        .ok => return .ok,
        .none => return .none,
        .text => |t| {
            const n = @min(@min(t.len, data_len), buf.len);
            @memcpy(buf[0..n], data[0..n]);
            return .{ .text = buf[0..n] };
        },
        .count => |c| return .{ .count = @intCast(@min(c.n, std.math.maxInt(u32))) },
        .refused => |r| return if (r.code == @intFromEnum(wire.RefuseCode.quota)) .quota else .none,
        else => return .none,
    }
}

fn scriptScroll(_: *anyopaque, _: f64, y: f64) void {
    if (scrollTo(y * zoomScale())) paintAll();
    if (scripts_up) scripts.setScroll(0, page.scroll_y / zoomScale());
}

/// Bring the engine up for the current document and run its scripts.
fn runScripts(doc: *dom.Document) void {
    if (!scripting) return;
    js_meta = mosslib.heapalloc.Allocator.init(&js_meta_buf);
    // A page's scripts get a shallower stack than the runner's: 64K
    // values and 4,000 frames (the defaults cost 4 MB of the 8 here).
    vm.initWith(&js_region, js_meta.allocator(), .{ .stack_values = 1 << 16, .max_frames = 4000 }) catch {
        _ = usys.log(glog, "webpage: the script engine did not fit its heap");
        return;
    };
    vm.host_now = scriptNow;
    scripts_up = true;
    scripts.init(&vm, doc, js_meta.allocator(), .{ .ctx = @ptrCast(&page), .log = scriptLog, .fetch = scriptFetch, .rect = scriptRect, .computed = scriptComputed, .scroll = scriptScroll, .request = scriptRequest, .storage = scriptStorage, .navigate = scriptNavigate, .changed = scriptChanged, .submit = scriptSubmit, .activate = scriptActivate }) catch {
        _ = usys.log(glog, "webpage: the bindings did not fit");
        return;
    };
    scripts.setViewport(@intCast(vw), @intCast(vh));
    scripts.setUrl(page.url()) catch {};
    scripts.runScripts();
    scheduleWake();
}

fn stopScripts() void {
    if (!scripts_up) return;
    scripts.deinit();
    vm.deinit();
    scripts_up = false;
}

/// After a script ran: if it changed the document, lay out and paint
/// again; and if a timer is pending, ask the host for the wake.
fn afterScript() void {
    if (!scripts_up) return;
    // The sheets are read again only when a script touched one (or they
    // were never read: a script running before the first layout): a
    // relayout that recollects them parses them into the document arena
    // (Acid3's thousand mutations grew it to 40 MB, 2026-09-26).
    if (scripts.takeDirty()) relayout(scripts.takeSheetsDirty() or page.sheets.len == 0);
    scheduleWake();
    runPendingNavigation();
}

/// The page cannot wait on a clock and its host at once, so the host
/// keeps the clock: tell it when the next timer or frame is due.
fn scheduleWake() void {
    if (!scripts_up) return;
    const due = scripts.nextDue() orelse return;
    const now: f64 = @floatFromInt(usys.nowMs());
    const delay: u64 = if (due > now) @intFromFloat(due - now) else 0;
    event(.wake, delay, 0);
}

/// The host's `tick`: run what is due, then what follows from it.
fn tick() void {
    if (!scripts_up) return;
    _ = scripts.runDue(@floatFromInt(usys.nowMs()));
    afterScript();
}

/// Rasterized glyphs, kept across navigations.
var glyph_heap: [2 << 20]u8 = undefined;
/// The user-agent stylesheet, parsed once.
var ua_heap: [512 << 10]u8 = undefined;
var ua_sheet: ?web.style.Sheet = null;
/// The pictures: their decoded pixels live in the store until the next
/// navigation (the cap is `max_picture_bytes`); a picture's file bytes
/// and its decoder's working memory pass through the scratch, reset per
/// picture, so a site's images cannot outgrow the document's arena
/// (Wikipedia's front page did, 2026-09-18).
var picture_heap: [6 << 20]u8 = undefined;
var picture_fba: std.heap.FixedBufferAllocator = undefined;
var picture_scratch: [6 << 20]u8 = undefined;
var picture_scratch_fba: std.heap.FixedBufferAllocator = undefined;

/// What the page is doing, for the out-of-memory line.
var phase: []const u8 = "loading";

fn outOfMemory() noreturn {
    var line: [256]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: out of memory while {s} (document {d} KB and layout {d} KB of {d} KB; viewport {d}x{d} at {d}%)", .{ phase, reg_lo / 1024, (region.len - reg_hi) / 1024, region.len / 1024, vw, vh, zoom_pct }) catch "webpage: out of memory");
    // How far a layout got: the counts say whether the page is big or
    // the layout is wasteful.
    if (web.layout.in_progress) |l| {
        _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: the layout so far: {d} boxes, {d} fragments, {d} nodes", .{ l.boxes.len, l.fragments.len, l.doc.nodes.len }) catch "webpage: layout so far");
    }
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
                    loadPack(pack);
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
/// mono second, then fallbacks for the scripts those lack) plus the
/// page's own `@font-face` faces, over `lib/web/fonts`; without any,
/// fixed cells, so a headless page still lays out.
const max_web_faces = web.fonts.max_web;

fn loadPack(pack: []const u8) void {
    for (0..web.fonts.max_system) |i| {
        const bytes = wire.FontPack.file(pack, i) orelse continue;
        page_fonts.setSystem(i, font.Font.parse(bytes) catch null);
    }
}

fn webFaceUsed(name: []const u8) void {
    logLine("webpage: web face in use: ", name);
}

var page_fonts: web.fonts.FaceFonts = undefined;

// ------------------------------------------------------------- the page

const max_highlights = 256;
const max_pictures = 64;
/// Decoded pixels a page keeps at most (RGBA bytes); past it, pictures
/// stay placeholders.
const max_picture_bytes: usize = 6 << 20;

const Picture = struct { node: dom.NodeId, state: enum { loaded, failed }, bm: web.layout.Bitmap };

/// A `background-image` picture, by the URL it resolved to; `url` and
/// `base` are the slices the style held when it was last looked up (a
/// relayout keeps them, so the lookup is by identity first).
const max_backgrounds = 48;
const Background = struct {
    /// In the picture store (a `data:` URL can be long).
    href: []const u8 = "",
    url_ptr: usize = 0,
    url_len: usize = 0,
    base_ptr: usize = 0,
    state: enum { loaded, failed } = .failed,
    bm: web.layout.Bitmap = .{ .w = 0, .h = 0, .rgba = &.{} },
};

const Page = struct {
    doc: ?*dom.Document = null,
    sheets: []const web.style.Sheet = &.{},
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
    press_x: u64 = 0,
    press_y: u64 = 0,
    /// The focused element (a link or a control), keyboard-driven.
    focus: ?dom.NodeId = null,
    /// A drag's selection: fragment indices, ends inclusive.
    sel_from: ?usize = null,
    sel_to: ?usize = null,
    dragging: bool = false,
    /// Find: the needle, its matches as highlights, and the one shown.
    find_buf: [256]u8 = undefined,
    find_len: usize = 0,
    matches: [max_highlights]web.paint.Highlight = undefined,
    n_matches: usize = 0,
    match_index: usize = 0,
    /// The pictures fetched and decoded so far (or refused), by node.
    pictures: [max_pictures]Picture = undefined,
    n_pictures: usize = 0,
    backgrounds: [max_backgrounds]Background = undefined,
    n_backgrounds: usize = 0,
    picture_bytes: usize = 0,
    fonts_loaded: bool = false,

    fn url(p: *const Page) []const u8 {
        return p.url_buf[0..p.url_len];
    }
    fn findText(p: *const Page) []const u8 {
        return p.find_buf[0..p.find_len];
    }
};

var page: Page = .{};
/// Page zoom in percent (CSS pixels to device pixels), and the
/// session's appearance: kept across navigations.
var zoom_pct: u64 = 100;
var theme_flags: u64 = 0;

fn arena() std.mem.Allocator {
    return .{ .ptr = @ptrCast(&region), .vtable = &doc_vtable };
}

fn uaSheet(e: web.style.Env) web.style.Sheet {
    if (ua_sheet) |s| return s;
    var fba = std.heap.FixedBufferAllocator.init(&ua_heap);
    ua_sheet = web.style.parseSheet(fba.allocator(), web.style.ua_sheet, .user_agent, e) catch outOfMemory();
    return ua_sheet.?;
}

/// Device pixels per CSS pixel: the page zoom (the host seeds it from
/// the user's scale, so "100%" reads like the rest of the desktop).
fn zoomScale() f64 {
    return @as(f64, @floatFromInt(@max(25, zoom_pct))) / 100;
}

/// The viewport as media queries and viewport units see it: in CSS
/// pixels.
fn env() web.style.Env {
    return .{
        .width = @as(f64, @floatFromInt(vw)) / zoomScale(),
        .height = @as(f64, @floatFromInt(vh)) / zoomScale(),
        .dark = theme_flags & wire.ThemeFlags.dark != 0,
        .high_contrast = theme_flags & wire.ThemeFlags.high_contrast != 0,
    };
}

// ----------------------------------------------------------- fetching

/// What `open` answered: the resource's status and, in the page's own
/// buffers, its final URL and content type.
const Opened = union(enum) { ok: u64, refused: wire.RefuseCode };

/// What the last `open` answered with: the resource's final URL and
/// its content type (a document's become the page's; a picture's or
/// font's are just read).
var res_url: [2048]u8 = undefined;
var res_url_len: usize = 0;
var res_type: [256]u8 = undefined;
var res_type_len: usize = 0;

fn openUrl(url_text: []const u8, post: bool, body: []const u8) Opened {
    return openUrlFrom(url_text, post, body, "");
}

/// `openUrl` with the page's origin, for a script's cross-origin
/// request (the broker does the CORS check).
fn openUrlFrom(url_text: []const u8, post: bool, body: []const u8, origin: []const u8) Opened {
    if (url_text.len + body.len + origin.len > data_len or body.len > 0xffffff or origin.len > 0xffff) return .{ .refused = .bad_url };
    @memcpy(data[0..url_text.len], url_text);
    @memcpy(data[url_text.len .. url_text.len + body.len], body);
    @memcpy(data[url_text.len + body.len .. url_text.len + body.len + origin.len], origin);
    const flags: u64 = (if (post) @as(u64, 1) else 0) | (@as(u64, body.len) << 8) | (@as(u64, origin.len) << 32);
    const opened = switch (call(.{ .open = .{ .off = 0, .len = url_text.len, .flags = flags } })) {
        .opened => |o| o,
        .refused => |r| return .{ .refused = std.enums.fromInt(wire.RefuseCode, r.code) orelse .protocol },
        else => return .{ .refused = .protocol },
    };
    res_url_len = @min(opened.url_len, res_url.len);
    @memcpy(res_url[0..res_url_len], data[0..res_url_len]);
    res_type_len = @min(opened.type_len, res_type.len);
    @memcpy(res_type[0..res_type_len], data[opened.url_len .. opened.url_len + res_type_len]);
    return .{ .ok = opened.status };
}

/// A resource of the page (a picture, a font) fetched whole into the
/// document's arena: its bytes, or null when refused, failed or too big.
fn fetchResource(url_text: []const u8, max: usize) ?[]u8 {
    return fetchResourceInto(arena(), url_text, max);
}

/// A resource through the host, whole, into `a` (up to `max` bytes); a
/// `data:` URL is decoded here, with no host involved.
fn fetchResourceInto(a: std.mem.Allocator, url_text: []const u8, max: usize) ?[]u8 {
    if (web.url.decodeData(a, url_text) catch null) |d| {
        if (d.bytes.len > max) return null;
        res_type_len = @min(d.mime.len, res_type.len);
        @memcpy(res_type[0..res_type_len], d.mime[0..res_type_len]);
        return @constCast(d.bytes);
    }
    switch (openUrl(url_text, false, "")) {
        .ok => |st| if (st >= 400) {
            _ = call(.cancel);
            return null;
        },
        .refused => return null,
    }
    var body: std.ArrayList(u8) = .empty;
    while (true) {
        const chunk = switch (call(.{ .read = .{ .max = data_len } })) {
            .chunk => |c| c,
            else => return null,
        };
        const n = @min(chunk.len, data_len);
        if (body.items.len + n > max) {
            _ = call(.cancel);
            return null;
        }
        body.appendSlice(a, data[0..n]) catch {
            // Too big for where it was to go: skipped, never fatal.
            _ = call(.cancel);
            return null;
        };
        switch (std.enums.fromInt(wire.ChunkEnd, chunk.done) orelse .failed) {
            .more => {},
            .done => return body.items,
            .failed => return null,
        }
    }
}

/// The whole body of the open resource into the arena, or why not.
const Read = union(enum) { body: []u8, refused: wire.RefuseCode };

fn readAll() Read {
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
    return .{ .body = body.items };
}

fn mimeOf(ct: []const u8) []const u8 {
    return std.mem.trim(u8, if (std.mem.indexOfScalar(u8, ct, ';')) |i| ct[0..i] else ct, " ");
}

/// A document this page can show: HTML, or text it wraps.
fn renderable(mime: []const u8) bool {
    return mime.len == 0 or std.ascii.eqlIgnoreCase(mime, "text/html") or std.ascii.eqlIgnoreCase(mime, "application/xhtml+xml") or std.ascii.startsWithIgnoreCase(mime, "text/");
}

/// The document's markup from what arrived: HTML as it is, plain text
/// wrapped in `<pre>`.
fn markupOf(body: []const u8) []const u8 {
    const ct = page.type_buf[0..page.type_len];
    const mime = mimeOf(ct);
    const enc = web.encoding.detect(body, ct);
    const text = web.encoding.decode(arena(), enc, body) catch outOfMemory();
    if (mime.len == 0 or std.ascii.eqlIgnoreCase(mime, "text/html") or std.ascii.eqlIgnoreCase(mime, "application/xhtml+xml")) return text;
    var out: std.ArrayList(u8) = .empty;
    out.appendSlice(arena(), "<!DOCTYPE html><pre style=\"white-space:pre-wrap;word-wrap:break-word\">") catch outOfMemory();
    for (text) |ch| switch (ch) {
        '&' => out.appendSlice(arena(), "&amp;") catch outOfMemory(),
        '<' => out.appendSlice(arena(), "&lt;") catch outOfMemory(),
        else => out.append(arena(), ch) catch outOfMemory(),
    };
    out.appendSlice(arena(), "</pre>") catch outOfMemory();
    return out.items;
}

var url_keep: [2048]u8 = undefined;
var body_keep: [8192]u8 = undefined;

/// Navigate: open first — a resource that is not a document is left
/// unread and reported as a download, the page shown staying as it is
/// — then the old page goes and the new one is read and presented.
fn load(url_text: []const u8, post: bool, body_text: []const u8) void {
    const n = @min(url_text.len, url_keep.len);
    @memcpy(url_keep[0..n], url_text[0..n]);
    const target = url_keep[0..n];
    const bn = @min(body_text.len, body_keep.len);
    @memcpy(body_keep[0..bn], body_text[0..bn]);
    const body = body_keep[0..bn];
    event(.load, @intFromEnum(wire.LoadState.loading), 0);
    load_t0 = usys.nowMs();
    const status: u64 = switch (openUrl(target, post, body)) {
        .ok => |st| st,
        .refused => |code| {
            fresh();
            @memcpy(page.url_buf[0..n], target);
            page.url_len = n;
            showError(code);
            return;
        },
    };
    if (status < 400 and !renderable(mimeOf(res_type[0..res_type_len]))) {
        _ = call(.cancel);
        // The download's URL and type, for the host; this page stays.
        @memcpy(data[0..res_url_len], res_url[0..res_url_len]);
        @memcpy(data[res_url_len .. res_url_len + res_type_len], res_type[0..res_type_len]);
        event(.download, res_url_len, res_type_len);
        event(.load, @intFromEnum(wire.LoadState.done), 0);
        return;
    }
    fresh();
    page.url_len = res_url_len;
    @memcpy(page.url_buf[0..res_url_len], res_url[0..res_url_len]);
    page.type_len = res_type_len;
    @memcpy(page.type_buf[0..res_type_len], res_type[0..res_type_len]);
    const got = switch (readAll()) {
        .body => |b| b,
        .refused => |code| {
            showError(code);
            return;
        },
    };
    fetch_ms = usys.nowMs() - load_t0;
    if (status >= 400) {
        showStatus(status);
        return;
    }
    present(markupOf(got), 0);
    runPendingNavigation();
}

/// The last load's timings, for the log line `present` writes.
var load_t0: u64 = 0;
var fetch_ms: u64 = 0;

/// Everything of the old page goes.
fn fresh() void {
    stopScripts();
    nav_pending = false;
    page = .{};
    resetDocument();
    resetLayout();
    picture_fba.reset();
    n_sheet_cache = 0;
    page_fonts.forgetWebFaces();
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
    phase = "parsing the document";
    const t_parse = usys.nowMs();
    const doc = web.html.parse(a, markup, .{ .scripting = scripting and failure == 0 }) catch outOfMemory();
    const t_parsed = usys.nowMs();
    page.doc = doc;
    page.base = web.url.parse(a, page.url(), null) catch null;
    eventText(.url, page.url());
    // Scripts run before the first layout, as the parser would have run
    // them: what they build is what is laid out.
    phase = "running its scripts";
    if (failure == 0) runScripts(doc);
    const t_scripts = usys.nowMs();
    var title: []const u8 = "";
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (doc.isHtml(id, "title")) {
        title = doc.textContent(id, a) catch outOfMemory();
        break;
    };
    eventText(.title, std.mem.trim(u8, title, " \t\r\n"));
    phase = "collecting its style sheets";
    page.sheets = collectSheets(doc);
    const t_sheets = usys.nowMs();
    phase = "loading its web fonts";
    loadFontFaces();
    const t_fonts = usys.nowMs();
    phase = "laying it out";
    relayout(false);
    const t_laid = usys.nowMs();
    phase = "loading its pictures";
    loadPictures(std.math.maxInt(usize));
    const t_pictures = usys.nowMs();
    phase = "editing it";
    if (failure == 0) {
        var line: [256]u8 = undefined;
        _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: loaded in {d} ms: fetch {d}, parse {d}, scripts {d}, sheets {d}, fonts {d}, style+layout {d}, paint {d}, pictures {d} ({d} nodes; document {d} KB, layout {d} KB of {d}; {d} scripts, {d} errors, script heap {d} KB)", .{ t_pictures - load_t0, fetch_ms, t_parsed - t_parse, t_scripts - t_parsed, t_sheets - t_scripts, t_fonts - t_sheets, last_layout_ms, last_paint_ms, t_pictures - t_laid, doc.nodes.len, reg_lo / 1024, (region.len - reg_hi) / 1024, region.len / 1024, if (scripts_up) scripts.scripts_run else 0, if (scripts_up) scripts.script_errors else 0, if (scripts_up) js_meta.live / 1024 else 0 }) catch "webpage: loaded");
    }
    event(.load, @intFromEnum(if (failure == 0) wire.LoadState.done else wire.LoadState.failed), failure);
}

/// The sheets' `@font-face` rules: each face fetched through the host,
/// normalised to SFNT (WOFF and WOFF2 decompress into the arena) and
/// parsed by `lib/font` into a face the layout picks by family.
fn loadFontFaces() void {
    if (page.fonts_loaded) return;
    page.fonts_loaded = true;
    const base = &(page.base orelse return);
    var loaded: usize = 0;
    for (page.sheets) |sheet| for (sheet.font_faces) |ff| {
        if (loaded == max_web_faces) return;
        // A face declared by a fetched sheet resolves against that sheet.
        const face_base: web.url.Url = if (ff.base) |b| (web.url.parse(arena(), b, null) catch base.*) else base.*;
        const u = web.url.resolve(arena(), ff.src, &face_base) catch continue;
        const href = u.href(arena()) catch outOfMemory();
        const bytes = fetchResource(href, 4 << 20) orelse {
            logLine("webpage: font-face not loaded: ", ff.family);
            continue;
        };
        // WOFF and WOFF2 state the SFNT's size at the same place.
        var out_len: usize = bytes.len;
        if (bytes.len >= 20 and (std.mem.eql(u8, bytes[0..4], "wOFF") or std.mem.eql(u8, bytes[0..4], "wOF2"))) out_len = @min(4 << 20, std.mem.readInt(u32, bytes[16..20], .big));
        const out = arena().alloc(u8, @max(out_len, bytes.len)) catch outOfMemory();
        const sfnt = font.toSfnt(arena(), bytes, out) catch {
            logLine("webpage: font-face unreadable: ", ff.family);
            continue;
        };
        const face = font.Font.parse(sfnt) catch {
            logLine("webpage: font-face unreadable: ", ff.family);
            continue;
        };
        if (page_fonts.addWebFace(ff.family, face)) {
            loaded += 1;
            logLine("webpage: font-face loaded: ", ff.family);
        }
    };
}

// ------------------------------------------------------- linked sheets

/// A linked sheet's text, fetched through the host once per page: the
/// cascade is collected again on a theme change and must not pay the
/// network twice. Reset with the document.
const max_sheets = 32;
const max_sheet_bytes = 1 << 20;
const CachedSheet = struct { url: []const u8, text: []const u8 };
var sheet_cache: [max_sheets]CachedSheet = undefined;
var n_sheet_cache: usize = 0;

fn sheetFetch(_: *anyopaque, href: []const u8, base_text: ?[]const u8) ?web.style.Loader.Loaded {
    const a = arena();
    const page_base = &(page.base orelse return null);
    const rel_base: web.url.Url = if (base_text) |b| (web.url.parse(a, b, null) catch page_base.*) else page_base.*;
    const u = web.url.resolve(a, href, &rel_base) catch return null;
    const url_text = u.href(a) catch return null;
    for (sheet_cache[0..n_sheet_cache]) |c| if (std.mem.eql(u8, c.url, url_text)) return .{ .text = c.text, .url = c.url };
    if (n_sheet_cache == max_sheets) return null;
    const bytes = fetchResourceInto(a, url_text, max_sheet_bytes) orelse {
        logLine("webpage: sheet not loaded: ", url_text);
        return null;
    };
    const text = web.encoding.decode(a, web.encoding.detect(bytes, res_type[0..res_type_len]), bytes) catch return null;
    sheet_cache[n_sheet_cache] = .{ .url = url_text, .text = text };
    n_sheet_cache += 1;
    logLine("webpage: sheet loaded: ", url_text);
    return .{ .text = text, .url = url_text };
}

/// The document's sheets, parsed through the layout arena — empty here,
/// reset by the relayout that follows — and kept as deep copies in the
/// document arena: a parse holds ten times what it keeps.
fn collectSheets(doc: *dom.Document) []const web.style.Sheet {
    resetLayout();
    const scratch = layoutArena();
    const keep: web.style.Keep = .{ .ctx = @ptrCast(&region), .a = arena(), .keep = keepSheet };
    const kept = web.style.collectDocumentSheetsKept(scratch, doc, env(), uaSheet(env()), sheetLoader(), keep) catch outOfMemory();
    resetLayout();
    return kept;
}

/// A parsed sheet deep-copied into the document arena; the scratch is
/// then reset, so each sheet's parse starts from an empty one.
fn keepSheet(_: *anyopaque, sheet: web.style.Sheet) web.style.Error!web.style.Sheet {
    const kept = try web.style.cloneSheet(arena(), sheet);
    resetLayout();
    return kept;
}

fn sheetLoader() web.style.Loader {
    return .{ .ctx = @ptrCast(&sheet_cache), .fetch = sheetFetch };
}

fn logLine(prefix: []const u8, text: []const u8) void {
    var line: [160]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&line, "{s}{s}", .{ prefix, text[0..@min(text.len, 100)] }) catch prefix);
}

fn pictureOf(node: dom.NodeId) ?*Picture {
    for (page.pictures[0..page.n_pictures]) |*p| if (p.node == node) return p;
    return null;
}

/// A picture's pixels from its file: SVG rasterized at the zoom (so it
/// paints pixel for pixel; its density says so), anything else decoded.
fn decodePicture(scratch: std.mem.Allocator, bytes: []const u8) ?web.layout.Bitmap {
    if (mosslib.svg.sniff(bytes)) {
        const img = mosslib.svg.render(scratch, bytes, zoomScale()) catch |e| {
            logLine("webpage: svg not drawn: ", @errorName(e));
            return null;
        };
        return .{ .w = img.w, .h = img.h, .rgba = img.rgba, .density = zoomScale() };
    }
    const img = mosslib.image.decode(scratch, bytes) catch |e| {
        logLine("webpage: image not decoded: ", @errorName(e));
        return null;
    };
    return .{ .w = img.w, .h = img.h, .rgba = img.rgba };
}

/// Keep a decoded picture's pixels in the store, within its budget.
fn keepPixels(bm: web.layout.Bitmap) ?web.layout.Bitmap {
    const len = @as(usize, bm.w) * bm.h * 4;
    if (page.picture_bytes + len > max_picture_bytes) return null;
    const kept = picture_fba.allocator().dupe(u8, bm.rgba[0..len]) catch return null;
    page.picture_bytes += kept.len;
    return .{ .w = bm.w, .h = bm.h, .rgba = kept, .density = bm.density };
}

/// A background url resolved against its sheet (or the page).
fn backgroundHref(a: std.mem.Allocator, url_text: []const u8, base_text: ?[]const u8) ?[]const u8 {
    const page_base = &(page.base orelse return null);
    const b: web.url.Url = if (base_text) |bt| (web.url.parse(a, bt, null) catch page_base.*) else page_base.*;
    const u = web.url.resolve(a, url_text, &b) catch return null;
    return u.href(a) catch null;
}

/// Pictures fetched on one `idle`: enough to keep the serve loop
/// answering a scroll between them; the page asks for another idle
/// while more remain.
const idle_picture_budget: usize = 4;

/// The pictures near the viewport (a screen above and two below) —
/// `img` boxes' and `background-image`s' — fetched and decoded lazily,
/// at most `budget` of them; a relayout follows when any arrived, since
/// their sizes are now known, and a `want_idle` event when the budget
/// ran out with more to fetch.
fn loadPictures(budget: usize) void {
    var fetched: usize = 0;
    var more = false;
    defer if (more) event(.want_idle, 0, 0);
    var rounds: usize = 0;
    while (rounds < 3) : (rounds += 1) {
        const l = page.layout orelse return;
        const doc = page.doc orelse return;
        const base = &(page.base orelse return);
        const top = page.scroll_y - @as(f64, @floatFromInt(vh));
        const bottom = page.scroll_y + 3 * @as(f64, @floatFromInt(vh));
        var got: usize = 0;
        var got_bg: usize = 0;
        for (0..l.boxes.len) |bi| {
            const b = l.boxes.get(bi);
            if (b.y + b.h < top or b.y > bottom) continue;
            if (fetched >= budget) {
                more = true;
                break;
            }
            if (b.kind != .text and b.style.background_image == .url and page.n_backgrounds < max_backgrounds) {
                if (loadBackground(b.style.background_image.url, b.style.background_base)) {
                    got_bg += 1;
                    fetched += 1;
                }
            }
            if (b.kind != .text and b.style.mask_image == .url and page.n_backgrounds < max_backgrounds) {
                if (loadBackground(b.style.mask_image.url, b.style.mask_base)) {
                    got_bg += 1;
                    fetched += 1;
                }
            }
            const node = b.node orelse continue;
            if (b.kind != .text and doc.get(node).namespace == .svg and std.mem.eql(u8, doc.get(node).name, "svg")) {
                if (pictureOf(node) == null and page.n_pictures < max_pictures) {
                    if (inlineSvg(doc, node, b)) got += 1;
                }
                continue;
            }
            if (!doc.isHtml(node, "img")) continue;
            if (pictureOf(node) != null) continue;
            if (page.n_pictures == max_pictures) continue;
            const slot = &page.pictures[page.n_pictures];
            slot.* = .{ .node = node, .state = .failed, .bm = .{ .w = 0, .h = 0, .rgba = &.{} } };
            page.n_pictures += 1;
            const src = doc.getAttr(node, "src") orelse continue;
            fetched += 1;
            // The file and the decoder's working memory in the scratch,
            // reset per picture; only the pixels are kept, in the store.
            picture_scratch_fba.reset();
            const scratch = picture_scratch_fba.allocator();
            const u = web.url.resolve(scratch, src, base) catch continue;
            const href = u.href(scratch) catch continue;
            const bytes = fetchResourceInto(scratch, href, 2 << 20) orelse continue;
            const bm = decodePicture(scratch, bytes) orelse continue;
            slot.bm = keepPixels(bm) orelse continue;
            slot.state = .loaded;
            var line: [200]u8 = undefined;
            _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: image {s} {d}x{d}", .{ src[0..@min(src.len, 120)], bm.w, bm.h }) catch "webpage: image");
            got += 1;
        }
        // A background changes no size: a repaint shows it.
        if (got == 0) {
            if (got_bg > 0) paintAll();
            return;
        }
        relayout(false);
    }
}

/// The fill page CSS gives an inline `<svg>`, as the renderer takes it.
fn svgFill(st: *const web.style.Computed) ?[4]f64 {
    const f = st.fill orelse return null;
    return switch (f) {
        .none => .{ 0, 0, 0, 0 },
        .current => .{ st.color.r, st.color.g, st.color.b, st.color.a },
        .color => |c| .{ c.r, c.g, c.b, c.a },
    };
}

/// An inline `<svg>`: its own markup drawn at its box's content size
/// in its element's colour (for `currentColor`). True when drawn.
fn inlineSvg(doc: *const dom.Document, node: dom.NodeId, b: *const web.layout.Box) bool {
    const slot = &page.pictures[page.n_pictures];
    slot.* = .{ .node = node, .state = .failed, .bm = .{ .w = 0, .h = 0, .rgba = &.{} } };
    page.n_pictures += 1;
    const cw = b.w - b.border[1] - b.border[3] - b.padding[1] - b.padding[3];
    const ch = b.h - b.border[0] - b.border[2] - b.padding[0] - b.padding[2];
    if (cw < 1 or ch < 1) return false;
    picture_scratch_fba.reset();
    const scratch = picture_scratch_fba.allocator();
    var markup: std.ArrayList(u8) = .empty;
    web.html.serializeOuter(scratch, doc, node, &markup) catch return false;
    const c = b.style.color;
    const w: usize = @intFromFloat(@round(cw));
    const h: usize = @intFromFloat(@round(ch));
    const img = mosslib.svg.renderSize(scratch, markup.items, w, h, .{ c.r, c.g, c.b, c.a }, svgFill(b.style)) catch |e| {
        logLine("webpage: inline svg not drawn: ", @errorName(e));
        return false;
    };
    // Its density makes its size in CSS pixels the box's: a relayout
    // keeps the box as it was.
    const bm: web.layout.Bitmap = .{ .w = img.w, .h = img.h, .rgba = img.rgba, .density = @as(f64, @floatFromInt(img.w)) / cw * zoomScale() };
    slot.bm = keepPixels(bm) orelse return false;
    slot.state = .loaded;
    return true;
}

/// Fetch and decode one background picture unless it is known; true
/// when a new one arrived.
fn loadBackground(url_text: []const u8, base_text: ?[]const u8) bool {
    if (findBackground(url_text, base_text) != null) return false;
    picture_scratch_fba.reset();
    const scratch = picture_scratch_fba.allocator();
    const href = backgroundHref(scratch, url_text, base_text) orelse return false;
    for (page.backgrounds[0..page.n_backgrounds]) |*bg| if (std.mem.eql(u8, bg.href, href)) {
        // The same picture under another spelling (or sheet).
        bg.url_ptr = @intFromPtr(url_text.ptr);
        bg.url_len = url_text.len;
        bg.base_ptr = if (base_text) |bt| @intFromPtr(bt.ptr) else 0;
        return false;
    };
    const slot = &page.backgrounds[page.n_backgrounds];
    slot.* = .{};
    slot.href = picture_fba.allocator().dupe(u8, href) catch return false;
    slot.url_ptr = @intFromPtr(url_text.ptr);
    slot.url_len = url_text.len;
    slot.base_ptr = if (base_text) |bt| @intFromPtr(bt.ptr) else 0;
    page.n_backgrounds += 1;
    const bytes = fetchResourceInto(scratch, href, 2 << 20) orelse return false;
    const bm = decodePicture(scratch, bytes) orelse return false;
    slot.bm = keepPixels(bm) orelse return false;
    slot.state = .loaded;
    logLine("webpage: background ", href[0..@min(href.len, 100)]);
    return true;
}

fn findBackground(url_text: []const u8, base_text: ?[]const u8) ?*Background {
    const bp: usize = if (base_text) |bt| @intFromPtr(bt.ptr) else 0;
    for (page.backgrounds[0..page.n_backgrounds]) |*bg| {
        if (bg.url_ptr == @intFromPtr(url_text.ptr) and bg.url_len == url_text.len and bg.base_ptr == bp) return bg;
    }
    return null;
}

fn imagesBackground(_: *anyopaque, url_text: []const u8, base_text: ?[]const u8) ?web.layout.Bitmap {
    const bg = findBackground(url_text, base_text) orelse blk: {
        // The sheets were read again (a theme or zoom change): the same
        // url is a new slice. Matched by what it resolves to, and
        // rebound so the next lookup is by identity.
        var buf: [4096]u8 = undefined;
        var fba = std.heap.FixedBufferAllocator.init(&buf);
        const href = backgroundHref(fba.allocator(), url_text, base_text) orelse return null;
        for (page.backgrounds[0..page.n_backgrounds]) |*b| if (std.mem.eql(u8, b.href, href)) {
            b.url_ptr = @intFromPtr(url_text.ptr);
            b.url_len = url_text.len;
            b.base_ptr = if (base_text) |bt| @intFromPtr(bt.ptr) else 0;
            break :blk b;
        };
        return null;
    };
    return if (bg.state == .loaded) bg.bm else null;
}

fn imagesGet(_: *anyopaque, node: dom.NodeId) ?web.layout.Bitmap {
    const p = pictureOf(node) orelse return null;
    return if (p.state == .loaded) p.bm else null;
}

const images_vtable: web.layout.Images.VTable = .{ .get = imagesGet, .background = imagesBackground };

fn imagesProvider() web.layout.Images {
    return .{ .ctx = @ptrCast(&page), .vtable = &images_vtable };
}

/// Style, lay out and paint the parsed document for the viewport as it
/// is now, in the layout arena, reset whole first. `recollect` re-reads
/// the document's sheets too (the appearance changed, so `@media` may
/// decide differently).
fn relayout(recollect: bool) void {
    const doc = page.doc orelse return;
    resetLayout();
    page.layout = null;
    page.styles = null;
    if (recollect) page.sheets = collectSheets(doc);
    const a = layoutArena();
    web.style.px_scale = zoomScale();
    const t_layout = usys.nowMs();
    const styles = a.create(web.style.Styles) catch outOfMemory();
    styles.* = web.style.compute(a, doc, page.sheets, env()) catch outOfMemory();
    page.styles = styles;
    const l = web.layout.layoutDocumentWith(a, doc, styles, page_fonts.fonts(), imagesProvider(), @floatFromInt(vw), @floatFromInt(vh)) catch outOfMemory();
    page.layout = l;
    page.extent = l.get(l.root).h;
    const max_y = @max(0, page.extent - @as(f64, @floatFromInt(vh)));
    page.scroll_y = @min(page.scroll_y, max_y);
    event(.extent, @intFromFloat(@max(0, page.extent)), 0);
    if (page.find_len > 0) collectMatches();
    last_layout_ms = usys.nowMs() - t_layout;
    paintAll();
}

/// The last relayout's layout time and the last paint's, for the log.
var last_layout_ms: u64 = 0;
var last_paint_ms: u64 = 0;

/// The host's viewport changed: let the old pixels go, take the new
/// buffer (none when hidden), and lay out for it.
fn resize(w: u64, h: u64) void {
    if (has_pixels) {
        _ = usys.shmUnmap(@intFromPtr(px));
        has_pixels = false;
    }
    vw = @intCast(w);
    vh = @intCast(h);
    if (scripts_up) scripts.setViewport(@intCast(vw), @intCast(vh));
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
        vw = 1024;
        vh = 768;
    }
    relayout(false);
}

// ------------------------------------------------------------ painting

var paint_highlights: [max_highlights + 64]web.paint.Highlight = undefined;

fn paintAll() void {
    const l = page.layout orelse return;
    if (!has_pixels) return;
    const t_paint = usys.nowMs();
    defer last_paint_ms = usys.nowMs() - t_paint;
    const canvas = ui.Canvas.init(px, vw, vh);
    // White unless the page says otherwise: a page that knows nothing
    // of dark mode keeps black text, so the session's theme reaches it
    // only as `prefers-color-scheme`, never as a canvas it did not ask for.
    canvas.fillAll(0xffffff);
    web.fonts.rasterized = 0;
    web.paint.paintWith(l, &canvas, page.scroll_y, .{ .highlights = highlightsNow(), .focus = page.focus }) catch outOfMemory();
    last_glyphs = web.fonts.rasterized;
    commitAll();
}

/// Scroll: the pixels already painted move by the distance, and only
/// the band that came into view is painted (a whole viewport a wheel
/// notch was 50 ms under emulation, and the pictures it fetched 700).
/// Pictures wait for `idle`.
fn scrollBy(dy: f64) void {
    const before = page.scroll_y;
    if (!scrollTo(page.scroll_y + dy)) return;
    if (scripts_up) scripts.setScroll(0, page.scroll_y / zoomScale());
    const moved: i64 = @intFromFloat(@round(page.scroll_y - before));
    if (!has_pixels or moved == 0 or @abs(moved) >= @as(i64, @intCast(vh))) {
        paintAll();
    } else {
        const n: usize = @intCast(@abs(moved));
        const rows = vh - n;
        const canvas = ui.Canvas.init(px, vw, vh);
        if (moved > 0) {
            // Down: rows move up; the bottom band is new.
            std.mem.copyForwards(u32, px[0 .. rows * vw], px[n * vw .. vh * vw]);
            paintBand(rows, vh, &canvas);
        } else {
            std.mem.copyBackwards(u32, px[n * vw .. vh * vw], px[0 .. rows * vw]);
            paintBand(0, n, &canvas);
        }
    }
    if (last_paint_ms > 40) {
        var line: [128]u8 = undefined;
        _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: scroll repaint {d} ms ({d} of {d} rows, {d} glyphs rasterized, commit {d} ms)", .{ last_paint_ms, @min(@abs(moved), vh), vh, last_glyphs, last_commit_ms }) catch "webpage: scroll");
    }
}

/// What the last paint cost in glyph rasterizations and in the commit
/// round trip to the host, for the log.
var last_glyphs: usize = 0;
var last_commit_ms: u64 = 0;

fn commitAll() void {
    const t = usys.nowMs();
    event(.commit, shared.packPair(0, 0), shared.packPair(@intCast(vw), @intCast(vh)));
    last_commit_ms = usys.nowMs() - t;
}

/// Paint the viewport's rows [y0, y1) and commit them.
fn paintBand(y0: usize, y1: usize, canvas_in: *const ui.Canvas) void {
    const l = page.layout orelse return;
    const t_paint = usys.nowMs();
    defer last_paint_ms = usys.nowMs() - t_paint;
    var canvas = canvas_in.*;
    canvas.clip_y0 = y0;
    canvas.clip_y1 = y1;
    canvas.fillRect(0, y0, vw, y1 - y0, 0xffffff);
    web.fonts.rasterized = 0;
    web.paint.paintWith(l, &canvas, page.scroll_y, .{ .highlights = highlightsNow(), .focus = page.focus }) catch outOfMemory();
    last_glyphs = web.fonts.rasterized;
    commitAll();
}

fn highlightsNow() []const web.paint.Highlight {
    var n: usize = 0;
    for (page.matches[0..page.n_matches], 0..) |m, i| {
        paint_highlights[n] = m;
        paint_highlights[n].color = if (i == page.match_index) 0xff9a00 else 0xffe066;
        n += 1;
    }
    n += selectionHighlights(paint_highlights[n..]);
    return paint_highlights[0..n];
}

fn scrollTo(y_in: f64) bool {
    // Whole pixels: a scroll moves rows, and a band painted at a
    // fraction would sit a row off the rows it joins.
    const max_y = @floor(@max(0, page.extent - @as(f64, @floatFromInt(vh))));
    const y = @floor(@min(max_y, @max(0, y_in)));
    if (y == page.scroll_y) return false;
    page.scroll_y = y;
    return true;
}

// ------------------------------------------------------- geometry help

/// The element's rect in document pixels: its box, or the union of its
/// fragments for an inline one.
fn nodeRect(id: dom.NodeId) ?[4]f64 {
    const l = page.layout orelse return null;
    var have = false;
    var r: [4]f64 = .{ 0, 0, 0, 0 };
    for (0..l.boxes.len) |i| {
        const b = l.boxes.get(i);
        if (b.node != id) continue;
        switch (b.kind) {
            .inline_box, .text => for (0..l.fragments.len) |fi| {
                const f = l.fragments.get(fi);
                if (f.dead) continue;
                if (f.box != @as(web.layout.BoxId, @intCast(i))) continue;
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

fn hitNode(x: u64, y: u64) ?dom.NodeId {
    const l = page.layout orelse return null;
    return web.layout.hitTest(l, @floatFromInt(x), @as(f64, @floatFromInt(y)) + page.scroll_y);
}

/// The text fragment under a viewport point, else the nearest by line.
fn hitFragment(x: u64, y: u64) ?usize {
    const l = page.layout orelse return null;
    const fx: f64 = @floatFromInt(x);
    const fy = @as(f64, @floatFromInt(y)) + page.scroll_y;
    var best: ?usize = null;
    var best_d: f64 = 1e18;
    for (0..l.fragments.len) |i| {
        const f = l.fragments.get(i);
        if (f.dead) continue;
        if (f.kind != .text) continue;
        const dx = if (fx < f.x) f.x - fx else if (fx > f.x + f.w) fx - (f.x + f.w) else 0;
        const dy = if (fy < f.y) f.y - fy else if (fy > f.y + f.h) fy - (f.y + f.h) else 0;
        const d = dy * 1000 + dx;
        if (d < best_d) {
            best_d = d;
            best = i;
        }
    }
    return best;
}

fn linkOf(start: dom.NodeId) ?[]const u8 {
    const doc = page.doc orelse return null;
    var id = start;
    while (true) {
        if (doc.isHtml(id, "a")) if (doc.getAttr(id, "href")) |href| {
            const base = &(page.base orelse return null);
            const u = web.url.resolve(arena(), href, base) catch return null;
            return u.href(arena()) catch outOfMemory();
        };
        id = doc.get(id).parent orelse return null;
    }
}

fn linkAt(x: u64, y: u64) ?[]const u8 {
    return linkOf(hitNode(x, y) orelse return null);
}

// ------------------------------------------------------------- focus

fn isFocusable(doc: *const dom.Document, id: dom.NodeId) bool {
    if (doc.get(id).kind != .element) return false;
    if (doc.isHtml(id, "a")) return doc.hasAttr(id, "href");
    return web.paint.controlOf(doc, id) != null;
}

fn kindName(doc: *const dom.Document, id: dom.NodeId) []const u8 {
    if (doc.isHtml(id, "a")) return "link";
    return if (web.paint.controlOf(doc, id)) |k| @tagName(k) else "element";
}

/// Move focus to the next (or previous) focusable in document order,
/// wrapping around.
fn moveFocus(backwards: bool) void {
    const doc = page.doc orelse return;
    var list: [512]dom.NodeId = undefined;
    var n: usize = 0;
    var w = doc.walk(dom.document_id);
    while (w.next()) |id| if (isFocusable(doc, id) and nodeRect(id) != null) {
        if (n < list.len) {
            list[n] = id;
            n += 1;
        }
    };
    if (n == 0) return;
    var at: ?usize = null;
    if (page.focus) |f| for (list[0..n], 0..) |id, i| if (id == f) {
        at = i;
    };
    const next = if (at) |i| (if (backwards) (i + n - 1) % n else (i + 1) % n) else (if (backwards) n - 1 else 0);
    setFocus(list[next]);
}

fn setFocus(target: ?dom.NodeId) void {
    page.focus = target;
    const doc = page.doc orelse return;
    var name: []const u8 = "";
    var rect: u64 = 0;
    if (target) |id| {
        name = kindName(doc, id);
        if (doc.getAttr(id, "name")) |nm| name = nm;
        if (nodeRect(id)) |r| {
            // Keep it in view.
            if (r[1] + r[3] > page.scroll_y + @as(f64, @floatFromInt(vh))) _ = scrollTo(r[1] + r[3] - @as(f64, @floatFromInt(vh)) + 8);
            if (r[1] < page.scroll_y) _ = scrollTo(r[1] - 8);
            const vy = r[1] - page.scroll_y;
            rect = wire.packRect(@intFromFloat(@max(0, r[0])), @intFromFloat(@max(0, vy)), @intFromFloat(@max(0, r[2])), @intFromFloat(@max(0, r[3])));
            var line: [160]u8 = undefined;
            _ = usys.log(glog, std.fmt.bufPrint(&line, "webpage: focus {s} at {d},{d} size {d}x{d}", .{ name, @as(i64, @intFromFloat(r[0])), @as(i64, @intFromFloat(vy)), @as(i64, @intFromFloat(r[2])), @as(i64, @intFromFloat(r[3])) }) catch "webpage: focus");
        }
    }
    const n = @min(name.len, data_len);
    @memcpy(data[0..n], name[0..n]);
    event(.focus, n, rect);
    paintAll();
}

// -------------------------------------------------------------- forms

fn setValue(id: dom.NodeId, value: []const u8) void {
    const doc = page.doc orelse return;
    // The DOM keeps the slice it is given: a copy in the document's arena.
    const kept = arena().dupe(u8, value) catch outOfMemory();
    doc.setAttr(id, "value", kept) catch outOfMemory();
}

fn typeInto(id: dom.NodeId, ch: u8) void {
    const doc = page.doc orelse return;
    const cur = doc.getAttr(id, "value") orelse (if (doc.isHtml(id, "textarea")) (doc.textContent(id, arena()) catch "") else "");
    var buf: [4096]u8 = undefined;
    const n = @min(cur.len, buf.len);
    @memcpy(buf[0..n], cur[0..n]);
    var len = n;
    if (ch == 8 or ch == 127) {
        // Backspace: the last code point goes.
        while (len > 0) {
            len -= 1;
            if (buf[len] & 0xc0 != 0x80) break;
        }
    } else if (len < buf.len) {
        buf[len] = ch;
        len += 1;
    }
    setValue(id, buf[0..len]);
    relayout(false);
    if (scripts_up) {
        scripts.fireInput(id);
        afterScript();
    }
}

fn toggle(id: dom.NodeId) void {
    toggleRaw(id);
    if (scripts_up) {
        scripts.fireChange(id);
        afterScript();
    }
}

fn toggleRaw(id: dom.NodeId) void {
    const doc = page.doc orelse return;
    const kind = web.paint.controlOf(doc, id) orelse return;
    switch (kind) {
        .checkbox => if (doc.hasAttr(id, "checked")) doc.removeAttr(id, "checked") else doc.setAttr(id, "checked", "") catch outOfMemory(),
        .radio => {
            // One of a name: the others of the group let go.
            const name = doc.getAttr(id, "name") orelse "";
            var w = doc.walk(dom.document_id);
            while (w.next()) |o| if (o != id and doc.isHtml(o, "input") and std.mem.eql(u8, doc.getAttr(o, "name") orelse "", name)) doc.removeAttr(o, "checked");
            doc.setAttr(id, "checked", "") catch outOfMemory();
        },
        .select => {
            // Cycle the chosen option (no popup here).
            var first: ?dom.NodeId = null;
            var chosen: ?dom.NodeId = null;
            var next: ?dom.NodeId = null;
            var take_next = false;
            var w = doc.walk(id);
            while (w.next()) |o| if (doc.isHtml(o, "option")) {
                if (first == null) first = o;
                if (take_next and next == null) next = o;
                if (doc.hasAttr(o, "selected")) {
                    chosen = o;
                    take_next = true;
                }
            };
            if (chosen) |c| doc.removeAttr(c, "selected");
            const pick = next orelse first orelse return;
            doc.setAttr(pick, "selected", "") catch outOfMemory();
        },
        else => return,
    }
    relayout(false);
}

fn urlEncode(out: *std.ArrayList(u8), s: []const u8) void {
    for (s) |c| {
        if (std.ascii.isAlphanumeric(c) or c == '-' or c == '_' or c == '.' or c == '~') {
            out.append(arena(), c) catch outOfMemory();
        } else if (c == ' ') {
            out.append(arena(), '+') catch outOfMemory();
        } else {
            out.print(arena(), "%{X:0>2}", .{c}) catch outOfMemory();
        }
    }
}

fn addPair(out: *std.ArrayList(u8), name: []const u8, value: []const u8) void {
    if (out.items.len > 0) out.append(arena(), '&') catch outOfMemory();
    urlEncode(out, name);
    out.append(arena(), '=') catch outOfMemory();
    urlEncode(out, value);
}

/// Submit the form holding `from` (the activated control): its
/// successful controls form-urlencoded, sent with the form's method to
/// its action.
fn submitForm(from: dom.NodeId) void {
    const doc = page.doc orelse return;
    var form: ?dom.NodeId = null;
    var id: ?dom.NodeId = from;
    while (id) |i| : (id = doc.get(i).parent) if (doc.isHtml(i, "form")) {
        form = i;
        break;
    };
    const f = form orelse return;
    // The script sees `submit` first; a listener may prevent it.
    if (scripts_up) {
        const go_on = scripts.fireSubmit(f);
        afterScript();
        if (!go_on) return;
    }
    submitFormOf(f, from);
}

/// Submit form `f`: its successful controls form-urlencoded, sent with
/// the form's method to its action. `submitter` is the button that did
/// it (its name and value count), null for a script's `submit()`.
fn submitFormOf(f: dom.NodeId, submitter: ?dom.NodeId) void {
    const doc = page.doc orelse return;
    var query: std.ArrayList(u8) = .empty;
    var w = doc.walk(f);
    while (w.next()) |c| {
        const name = doc.getAttr(c, "name") orelse continue;
        if (name.len == 0) continue;
        if (doc.isHtml(c, "input")) {
            const t = doc.getAttr(c, "type") orelse "text";
            const eq = std.ascii.eqlIgnoreCase;
            if (eq(t, "checkbox") or eq(t, "radio")) {
                if (doc.hasAttr(c, "checked")) addPair(&query, name, doc.getAttr(c, "value") orelse "on");
            } else if (eq(t, "submit") or eq(t, "button") or eq(t, "reset")) {
                if (submitter == c) addPair(&query, name, doc.getAttr(c, "value") orelse "");
            } else addPair(&query, name, doc.getAttr(c, "value") orelse "");
        } else if (doc.isHtml(c, "textarea")) {
            addPair(&query, name, doc.getAttr(c, "value") orelse (doc.textContent(c, arena()) catch ""));
        } else if (doc.isHtml(c, "select")) {
            var chosen: ?dom.NodeId = null;
            var first: ?dom.NodeId = null;
            var ow = doc.walk(c);
            while (ow.next()) |o| if (doc.isHtml(o, "option")) {
                if (first == null) first = o;
                if (doc.hasAttr(o, "selected")) chosen = o;
            };
            if (chosen orelse first) |o| addPair(&query, name, doc.getAttr(o, "value") orelse web.paint.selectedOption(doc, c));
        } else if (doc.isHtml(c, "button") and submitter == c) {
            addPair(&query, name, doc.getAttr(c, "value") orelse "");
        }
    }
    const method = doc.getAttr(f, "method") orelse "get";
    const post = std.ascii.eqlIgnoreCase(method, "post");
    const base = &(page.base orelse return);
    const action_text = doc.getAttr(f, "action") orelse "";
    var action = web.url.resolve(arena(), action_text, base) catch return;
    if (!post) {
        action.query = query.items;
        action.fragment = null;
    }
    const target = action.href(arena()) catch outOfMemory();
    load(target, post, if (post) query.items else "");
}

/// A control or link activated (a click, Enter, Space).
fn activate(id: dom.NodeId, from_keyboard: bool) void {
    const doc = page.doc orelse return;
    if (linkOf(id)) |link| {
        load(link, false, "");
        return;
    }
    const kind = web.paint.controlOf(doc, id) orelse return;
    switch (kind) {
        .checkbox, .radio, .select => toggle(id),
        .button => {
            const t = doc.getAttr(id, "type") orelse (if (doc.isHtml(id, "button")) "submit" else "submit");
            if (std.ascii.eqlIgnoreCase(t, "reset") or std.ascii.eqlIgnoreCase(t, "button")) return;
            submitForm(id);
        },
        .text, .password => if (from_keyboard) submitForm(id),
        .textarea => {},
    }
}

/// The page's key codes (`shared.keyboard`'s above 127) as the DOM
/// names them; a plain byte is the library's.
fn keyInfo(ch: u8) script.KeyInfo {
    const kb = shared.keyboard;
    return switch (ch) {
        kb.back_tab => script.keyNamed("Tab", 9, true),
        kb.up => script.keyNamed("ArrowUp", 38, false),
        kb.down => script.keyNamed("ArrowDown", 40, false),
        kb.left => script.keyNamed("ArrowLeft", 37, false),
        kb.right => script.keyNamed("ArrowRight", 39, false),
        kb.home => script.keyNamed("Home", 36, false),
        kb.end => script.keyNamed("End", 35, false),
        kb.delete => script.keyNamed("Delete", 46, false),
        0x1e => script.keyNamed("PageUp", 33, false),
        0x1f => script.keyNamed("PageDown", 34, false),
        else => script.keyFromByte(ch),
    };
}

fn key(ch: u8) void {
    const doc = page.doc orelse return;
    const kb = shared.keyboard;
    // The script sees the key first: a listener that prevents the
    // default keeps it from typing, moving focus or scrolling.
    if (scripts_up) {
        const go_on = scripts.fireKey(page.focus, keyInfo(ch));
        afterScript();
        if (!go_on) return;
    }
    switch (ch) {
        '\t' => return moveFocus(false),
        kb.back_tab => return moveFocus(true),
        else => {},
    }
    if (page.focus) |f| {
        const kind = web.paint.controlOf(doc, f);
        if (kind == .text or kind == .password or kind == .textarea) {
            if (ch == '\n') {
                if (kind == .textarea) typeInto(f, ch) else activate(f, true);
                return;
            }
            if ((ch >= 0x20 and ch < 0x7f) or ch == 8 or ch == 127 or ch >= 0x80 and ch < 0xc0 or ch >= 0xc0) {
                if (ch < 0x80 or ch >= 0xc0 or true) typeInto(f, ch);
                return;
            }
        }
        if (ch == '\n' or ch == ' ') {
            activate(f, true);
            return;
        }
    }
    switch (ch) {
        kb.up => scrollBy(-40),
        kb.down => scrollBy(40),
        0x1e => scrollBy(-@as(f64, @floatFromInt(vh)) * 0.9),
        0x1f => scrollBy(@as(f64, @floatFromInt(vh)) * 0.9),
        kb.home => if (scrollTo(0)) paintAll(),
        kb.end => if (scrollTo(page.extent)) paintAll(),
        ' ' => scrollBy(@as(f64, @floatFromInt(vh)) * 0.9),
        else => {},
    }
}

// ---------------------------------------------------------- selection

fn selectionHighlights(out: []web.paint.Highlight) usize {
    const l = page.layout orelse return 0;
    const from = page.sel_from orelse return 0;
    const to = page.sel_to orelse return 0;
    const lo = @min(from, to);
    const hi = @max(from, to);
    var n: usize = 0;
    var i = lo;
    while (i <= hi and i < l.fragments.len and n < out.len) : (i += 1) {
        const f = l.fragments.get(i);
        if (f.kind != .text or f.dead) continue;
        out[n] = .{ .x = f.x, .y = f.y, .w = f.w, .h = f.h, .color = 0x3b82f6 };
        n += 1;
    }
    return n;
}

/// The selected text: the fragments between the ends, a space between
/// fragments on one line and a newline across lines.
fn selectionText(out: []u8) usize {
    const l = page.layout orelse return 0;
    const from = page.sel_from orelse return 0;
    const to = page.sel_to orelse return 0;
    const lo = @min(from, to);
    const hi = @max(from, to);
    var n: usize = 0;
    var last_y: ?f64 = null;
    var i = lo;
    while (i <= hi and i < l.fragments.len) : (i += 1) {
        const f = l.fragments.get(i);
        if (f.kind != .text or f.dead) continue;
        if (last_y) |ly| {
            const sep: u8 = if (f.y != ly) '\n' else ' ';
            if (n < out.len) {
                out[n] = sep;
                n += 1;
            }
        }
        const take = @min(f.text.len, out.len - n);
        @memcpy(out[n .. n + take], f.text[0..take]);
        n += take;
        last_y = f.y;
    }
    return n;
}

fn pointer(kind: wire.PointerKind, x: u64, y: u64) void {
    switch (kind) {
        .move => {
            if (page.dragging) {
                const dx = @as(i64, @intCast(x)) - @as(i64, @intCast(page.press_x));
                const dy = @as(i64, @intCast(y)) - @as(i64, @intCast(page.press_y));
                if (@abs(dx) + @abs(dy) > 3) if (hitFragment(x, y)) |fi| {
                    if (page.sel_to != fi) {
                        page.sel_to = fi;
                        paintAll();
                    }
                };
                return;
            }
            const link = linkAt(x, y) orelse "";
            if (std.mem.eql(u8, link, page.hover_buf[0..page.hover_len])) return;
            page.hover_len = @min(link.len, page.hover_buf.len);
            @memcpy(page.hover_buf[0..page.hover_len], link[0..page.hover_len]);
            eventText(.hover, page.hover_buf[0..page.hover_len]);
        },
        .down => {
            page.pressed = hitNode(x, y);
            page.press_x = x;
            page.press_y = y;
            page.dragging = true;
            const had = page.sel_from != null;
            page.sel_from = hitFragment(x, y);
            page.sel_to = null;
            if (had) paintAll();
        },
        .up => {
            const was = page.pressed;
            page.pressed = null;
            page.dragging = false;
            if (page.sel_to != null and page.sel_from != null) {
                // A drag: the selection is the news, not a click.
                var text: [2048]u8 = undefined;
                const n = selectionText(&text);
                @memcpy(data[0..n], text[0..n]);
                event(.selection, n, 0);
                return;
            }
            page.sel_from = null;
            const now = hitNode(x, y);
            if (was == null or now == null or was.? != now.?) return;
            const doc = page.doc orelse return;
            // The script sees the click first: a listener that prevents
            // the default keeps the link unfollowed and the box untoggled.
            if (scripts_up) {
                const go_on = scripts.click(now.?);
                afterScript();
                if (!go_on) return;
            }
            // A click: focus what takes focus, then act on it.
            var target: ?dom.NodeId = now;
            while (target) |t| : (target = doc.get(t).parent) if (isFocusable(doc, t)) break;
            if (target) |t| {
                if (page.focus != t) setFocus(t);
                activate(t, false);
            } else if (page.focus != null) setFocus(null);
        },
    }
}

// --------------------------------------------------------------- find

fn collectMatches() void {
    page.n_matches = 0;
    const l = page.layout orelse return;
    const needle = page.findText();
    if (needle.len == 0) return;
    for (0..l.fragments.len) |fi| {
        const f = l.fragments.get(fi);
        if (f.dead) continue;
        if (f.kind != .text) continue;
        var start: usize = 0;
        while (std.ascii.indexOfIgnoreCasePos(f.text, start, needle)) |at| {
            if (page.n_matches == max_highlights) return;
            const fnt = web.layout.fontOf(l.get(f.box).style);
            const x0 = f.x + l.fonts.advance(fnt, f.text[0..at]);
            const w = l.fonts.advance(fnt, f.text[at .. at + needle.len]);
            page.matches[page.n_matches] = .{ .x = x0, .y = f.y, .w = w, .h = f.h, .color = 0xffe066 };
            page.n_matches += 1;
            start = at + needle.len;
        }
    }
}

fn find(text: []const u8, index: u64) void {
    page.find_len = @min(text.len, page.find_buf.len);
    @memcpy(page.find_buf[0..page.find_len], text[0..page.find_len]);
    collectMatches();
    if (page.n_matches == 0) {
        page.match_index = 0;
        event(.found, 0, 0);
        paintAll();
        return;
    }
    page.match_index = @intCast(index % page.n_matches);
    const m = page.matches[page.match_index];
    const vhf: f64 = @floatFromInt(vh);
    if (m.y < page.scroll_y or m.y + m.h > page.scroll_y + vhf) _ = scrollTo(m.y - vhf / 3);
    event(.found, page.n_matches, page.match_index);
    paintAll();
}

fn dump(what: wire.Dump, selector: []const u8) void {
    const doc = page.doc orelse {
        event(.dumped, 0, 0);
        return;
    };
    // Serialized in the layout arena's scratch: a dump is not the document's.
    var scratch = std.heap.ArenaAllocator.init(layoutArena());
    defer scratch.deinit();
    const sa = scratch.allocator();
    var out: std.ArrayList(u8) = .empty;
    switch (what) {
        .html => web.html.serialize(sa, doc, dom.document_id, &out) catch outOfMemory(),
        .selected => {
            const sel = web.selectors.Selector.parse(sa, selector) catch {
                event(.dumped, 0, 0);
                return;
            };
            var ids: std.ArrayList(dom.NodeId) = .empty;
            sel.queryAll(doc, dom.document_id, sa, &ids) catch outOfMemory();
            for (ids.items) |id| web.html.serializeOuter(sa, doc, id, &out) catch outOfMemory();
        },
    }
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
                load(data[off .. off + len], false, "");
            },
            .scroll => |s| scrollBy(@floatFromInt(@as(i64, @bitCast(s.dy)))),
            .pointer => |p| pointer(std.enums.fromInt(wire.PointerKind, p.kind) orelse .move, p.x, p.y),
            .key => |k| key(@truncate(k.ch)),
            .dump => |d| {
                var sel: [512]u8 = undefined;
                const n = @min(@min(d.len, data_len), sel.len);
                @memcpy(sel[0..n], data[0..n]);
                dump(std.enums.fromInt(wire.Dump, d.what) orelse .html, sel[0..n]);
            },
            .resize => |r| resize(r.w, r.h),
            .find => |f| {
                var text: [256]u8 = undefined;
                const n = @min(@min(f.len, data_len), text.len);
                @memcpy(text[0..n], data[0..n]);
                find(text[0..n], f.index);
            },
            .idle => loadPictures(idle_picture_budget),
            .tick => tick(),
            .scripts => |s| scripting = s.on != 0,
            .zoom => |z| {
                const pct = @min(400, @max(25, z.percent));
                if (pct != zoom_pct) {
                    zoom_pct = pct;
                    // The viewport in CSS pixels changed: `@media` may
                    // decide differently, so the sheets are read again.
                    relayout(true);
                }
            },
            .theme => |t| if (t.flags != theme_flags) {
                theme_flags = t.flags;
                relayout(true);
            },
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
    picture_fba = std.heap.FixedBufferAllocator.init(&picture_heap);
    picture_scratch_fba = std.heap.FixedBufferAllocator.init(&picture_scratch);
    page_fonts = web.fonts.FaceFonts.init(&glyph_heap);
    page_fonts.on_web_face_used = webFaceUsed;
    attach();
    _ = usys.log(glog, "webpage: up");
    // The user-agent sheet parsed now, while nothing is typed yet: it
    // cost the first page 600 ms under emulation.
    _ = uaSheet(env());
    serve();
}
