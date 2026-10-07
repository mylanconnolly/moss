//! The page-domain drill's client: a native host that spawns page
//! domains and drives them the way a window would. It loads the
//! fixture's front page through its own broker and checks the page
//! painted it (the heading's colour is in the pixels), finds the link
//! by sweeping the pointer down the page until the page reports a
//! hover, clicks it and sees the second page's commit land with its
//! title and URL, asks for the document and reads it back; then it
//! spawns a second page and sends it after a resource larger than a
//! page's arena, and sees that page die of it while the first page
//! still scrolls; then it tears everything down and exits clean, which
//! the kernel's leak bar checks.
const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");
const netcmds = @import("netcmds.zig");
const tlscmds = @import("tlscmds.zig");
const loader = @import("loader.zig");
const webhost = @import("webhost.zig");
const wire = shared.web;

comptime {
    asm (usys.imageHeaderStack("webpagecli", 128));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    webhost.logf(glog, "webpagecli: panic: {s}", .{msg});
    usys.exit(255);
}

var glog: u64 = 0;
var net: netcmds.Net = undefined;
var host: webhost.Host = undefined;
var stage: loader.Stage = undefined;

const front = "http://www.moss.test:8080/";
const boom = "http://www.moss.test:8080/boom";
const heading: u32 = 0x336699; // index.html's h1 colour

fn fail(comptime why: []const u8, code: u64) noreturn {
    _ = usys.log(glog, "webpagecli: FAIL: " ++ why);
    usys.exit(code);
}

fn demand(ok: bool, comptime why: []const u8, code: u64) void {
    if (!ok) fail(why, code);
}

/// Serve the host until `page` reports a load's end, or dies. Up to
/// `steps` messages: a page that never finishes fails the drill.
const Outcome = enum { done, failed, dead };

fn waitLoad(id: webhost.PageId, steps: usize) Outcome {
    var n: usize = 0;
    while (n < steps) : (n += 1) {
        switch (host.step()) {
            .event => |e| if (e.page == id and e.kind == .load) {
                const st = std.enums.fromInt(wire.LoadState, e.a) orelse .failed;
                if (st == .done) return .done;
                if (st == .failed) return .failed;
            },
            .dead => |d| if (d == id) return .dead,
            .failed => |err| {
                webhost.logf(glog, "webpagecli: channel failed: {s}", .{@tagName(err)});
                fail("the host channel failed", 20);
            },
            .idle => return .dead,
            else => {},
        }
    }
    fail("a load never ended", 21);
}

/// Load, retrying while the fixture server is still coming up (the
/// broker refuses with `connect` or `resolve`).
fn loadPage(id: webhost.PageId, url: []const u8) void {
    var tries: usize = 0;
    while (tries < 60) : (tries += 1) {
        demand(host.send(id, .{ .load = url }), "send load", 22);
        switch (waitLoad(id, 4000)) {
            .done => return,
            .dead => fail("the page died loading", 23),
            .failed => {
                const p = host.page(id);
                const code = std.enums.fromInt(wire.RefuseCode, p.load_code);
                if (code == null or (code.? != .connect and code.? != .resolve)) {
                    webhost.logf(glog, "webpagecli: load failed with code {d}", .{p.load_code});
                    fail("the load failed", 24);
                }
                usys.sleepMs(500);
            },
        }
    }
    fail("the fixture never answered", 25);
}

/// Serve what the page says after a command until it asks for the next.
fn serveUntilParked(id: webhost.PageId) void {
    var n: usize = 0;
    while (n < 400) : (n += 1) {
        switch (host.step()) {
            .dead => fail("the page died", 72),
            .failed, .idle => fail("the host stopped", 73),
            .served => if (host.page(id).parked != null) return,
            else => {},
        }
    }
    fail("the page never parked again", 74);
}

/// Serve until `page` reports event `kind`.
fn waitEvent(id: webhost.PageId, kind: wire.Event, steps: usize) void {
    var n: usize = 0;
    while (n < steps) : (n += 1) {
        switch (host.step()) {
            .event => |e| if (e.page == id and e.kind == kind) return,
            .dead => |d| if (d == id) fail("the page died", 26),
            .failed, .idle => fail("the host stopped", 27),
            else => {},
        }
    }
    fail("an event never came", 28);
}

/// Scroll a page that overflows its strip, and see the repaint land.
fn scrollAndCommit(id: webhost.PageId, dy: i64) void {
    const before = host.page(id).commits;
    demand(host.send(id, .{ .scroll = dy }), "send scroll", 54);
    waitEvent(id, .commit, 100);
    demand(host.page(id).commits == before + 1, "no commit after the scroll", 55);
}

fn countColour(id: webhost.PageId, colour: u32) usize {
    var n: usize = 0;
    for (host.page(id).pixels()) |w| if (w & 0xffffff == colour) {
        n += 1;
    };
    return n;
}

fn endsWith(s: []const u8, suffix: []const u8) bool {
    return std.mem.endsWith(u8, s, suffix);
}

export fn umain(log_h: u64, chan_h: u64, _: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    demand(setup.has(.net) and setup.has(.view), "the unit lacks a network view or a filesystem view", 160);
    const view = setup.cap(.view);
    const view_buf: [*]u8 = @ptrFromInt(fsc.attachBuf(view).va);
    // The spawner is slot 2 (log, channel, then the grants in order).
    const slot2: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });
    demand((usys.capKind(slot2) orelse .none) == .spawner, "no spawner", 161);
    stage = loader.Stage.init(loader.Stage.default_pages) orelse fail("no stage", 162);
    if (!stage.load(blob_va, blob_len, .webpage)) {
        webhost.logf(glog, "webpagecli: webpage image: {s}", .{loader.Stage.last_refusal});
        fail("the page image did not stage", 163);
    }
    net = netcmds.Net.init(setup.cap(.net));
    tlscmds.setRootsView(view, view_buf);
    host.reset(glog, slot2, &net);
    demand(host.init(), "no channel", 164);
    if (host.loadFonts(view, view_buf)) _ = usys.log(glog, "webpagecli: fonts packed for the pages") else _ = usys.log(glog, "webpagecli: no fonts; pages lay out with cells");

    // 1. A page loads the front page and paints it. The viewport is a
    // short strip, so the page overflows it and scrolling is real.
    const a = host.spawn(stage.handle, 640, 100) orelse fail("spawn refused", 165);
    loadPage(a, front);
    const pa = host.page(a);
    demand(std.mem.eql(u8, pa.titleText(), "moss fixture: home"), "front page title", 30);
    demand(std.mem.eql(u8, pa.urlText(), front), "front page url", 31);
    demand(pa.commits >= 1, "no commit after load", 32);
    const painted = countColour(a, heading);
    webhost.logf(glog, "webpagecli: front page painted, {d} heading pixels, extent {d}", .{ painted, pa.extent });
    demand(painted > 20, "the heading was not painted in its colour", 33);
    demand(countColour(a, 0xffffff) > 640 * 100 / 2, "the page background is not white", 34);
    demand(pa.extent > 100, "the front page does not overflow the strip", 29);

    // 2. Scroll the strip down the page (a commit follows), then find the
    // link by hovering down the strip, and click it.
    scrollAndCommit(a, 100);
    var link_y: ?u32 = null;
    var y: u32 = 0;
    while (y < 100 and link_y == null) : (y += 3) {
        demand(host.send(a, .{ .pointer = .{ .kind = .move, .x = 60, .y = y } }), "send move", 35);
        // The page answers a move with a hover only when the link under
        // the pointer changed; serve until it asks for the next command.
        var n: usize = 0;
        while (n < 100) : (n += 1) {
            switch (host.step()) {
                .event => |e| if (e.page == a and e.kind == .hover) {
                    if (endsWith(pa.hoverText(), "/about.html")) link_y = y;
                },
                .dead => fail("the page died hovering", 36),
                .failed, .idle => fail("the host stopped", 37),
                .served => if (pa.parked != null) break,
                .stale => {},
            }
        }
    }
    const ly = link_y orelse fail("no link found by hovering", 38);
    webhost.logf(glog, "webpagecli: link at y={d}", .{ly});
    demand(host.send(a, .{ .pointer = .{ .kind = .down, .x = 60, .y = ly } }), "send down", 39);
    demand(host.send(a, .{ .pointer = .{ .kind = .up, .x = 60, .y = ly } }), "send up", 40);
    demand(waitLoad(a, 4000) == .done, "the click's load did not end", 41);
    demand(endsWith(pa.urlText(), "/about.html"), "the click did not navigate", 42);
    demand(std.mem.eql(u8, pa.titleText(), "moss fixture: about"), "second page title", 43);
    demand(pa.commits >= 2, "no commit for the second page", 44);
    _ = usys.log(glog, "webpagecli: clicked through to the second page");

    // 3. The document, read back.
    demand(host.send(a, .{ .dump = .{ .what = .html } }), "send dump", 45);
    waitEvent(a, .dumped, 100);
    demand(!pa.dumped_cut and std.mem.indexOf(u8, pa.dumped(), "<h1>About the fixtures</h1>") != null, "the dump lacks the heading", 46);

    // 3b. Scripts off: the fixture app loads without its script's marks;
    // on again, with them.
    const app = "http://www.moss.test:8080/app.html";
    demand(host.send(a, .{ .scripts = false }), "send scripts off", 56);
    loadPage(a, app);
    demand(host.send(a, .{ .dump = .{ .what = .html } }), "send dump", 57);
    waitEvent(a, .dumped, 100);
    demand(std.mem.indexOf(u8, pa.dumped(), "data-loaded") == null, "scripts ran while off", 58);
    demand(std.mem.indexOf(u8, pa.dumped(), "Scripts are off.") != null, "noscript content was not shown with scripts off", 59);
    demand(host.send(a, .{ .scripts = true }), "send scripts on", 60);
    loadPage(a, app);
    demand(host.send(a, .{ .dump = .{ .what = .html } }), "send dump", 61);
    waitEvent(a, .dumped, 100);
    demand(std.mem.indexOf(u8, pa.dumped(), "data-loaded=\"complete\"") != null, "scripts did not run when on again", 62);
    // A key goes to the script before the page acts on it.
    demand(host.send(a, .{ .key = .{ .code = 0, .ch = 'k' } }), "send key", 63);
    demand(host.send(a, .{ .dump = .{ .what = .html } }), "send dump", 64);
    waitEvent(a, .dumped, 100);
    demand(std.mem.indexOf(u8, pa.dumped(), "data-key=\"k/KeyK\"") != null, "the key did not reach the script", 65);
    _ = usys.log(glog, "webpagecli: scripts off and on ok");

    // 3c. A page that re-renders on a timer: twenty megabytes of
    // document through a page that reclaims at eight. It lives, because
    // the page reclaims what it no longer shows (the log says how much).
    // The host keeps the pages' clock (`tickWakes`): the page asks to be
    // woken for its timers, and this loop grants every wake as it comes.
    loadPage(a, "http://www.moss.test:8080/churn.html");
    var churn_tries: usize = 0;
    while (true) : (churn_tries += 1) {
        demand(churn_tries < 400, "the churning page never finished", 66);
        usys.sleepMs(20);
        host.tickWakes();
        demand(host.send(a, .{ .dump = .{ .what = .eval, .select = "document.title" } }), "send eval", 67);
        waitEvent(a, .dumped, 2000);
        if (std.mem.startsWith(u8, pa.dumped(), "churned ")) break;
    }
    demand(std.mem.eql(u8, pa.dumped(), "churned 1000"), "the last render is not what shows", 68);
    _ = usys.log(glog, "webpagecli: the churning page lived through twenty megabytes");

    // 4. A page that reads more than its arena dies of it; nothing else does.
    const b = host.spawn(stage.handle, 640, 100) orelse fail("second spawn refused", 47);
    demand(host.send(b, .{ .load = boom }), "send boom", 48);
    switch (waitLoad(b, 20000)) {
        .dead => _ = usys.log(glog, "webpagecli: the page that read past its arena died, as it should"),
        .done => fail("the boom page loaded", 49),
        .failed => {
            webhost.logf(glog, "webpagecli: boom refused with code {d}", .{host.page(b).load_code});
            fail("the boom page was refused instead of dying", 50);
        },
    }
    host.destroy(b);
    // The first page is untouched: it still scrolls and commits.
    demand(pa.extent > 100, "the second page does not overflow the strip", 51);
    scrollAndCommit(a, 40);
    scrollAndCommit(a, -40);

    // 4. A scroll container takes the wheel over it until its end, then
    // the page scrolls; a sticky header holds the top of the viewport
    // while its containing block has room, and goes with it after.
    loadPage(a, "http://www.moss.test:8080/scroll.html");
    demand(countColour(a, 0xff0000) == 0, "the container's tail shows before any scroll", 61);
    demand(host.send(a, .{ .pointer = .{ .kind = .move, .x = 50, .y = 30 } }), "send move over the container", 62);
    scrollAndCommit(a, 340);
    demand(countColour(a, 0xff0000) > 0, "the container did not scroll to its tail", 63);
    demand(countColour(a, 0x000080) > 0, "the sticky header is not at the top", 64);
    scrollAndCommit(a, 340);
    demand(countColour(a, 0x000080) > 0, "the sticky header did not stick while the page scrolled", 65);
    demand(countColour(a, 0xff0000) == 0, "the container did not scroll away with the page", 66);
    scrollAndCommit(a, 400);
    demand(countColour(a, 0x000080) == 0, "the sticky header outlived its containing block", 67);
    _ = usys.log(glog, "webpagecli: the container scrolled and the header stuck");

    // 5. `:hover` restyles the page, and a transition runs on the host's
    // ticks: the box grows from 100 to 200 px over a second of wakes,
    // seen part-way and at its end.
    loadPage(a, "http://www.moss.test:8080/anim.html");
    demand(countColour(a, 0xff0000) == 100 * 20, "the box is not 100 px wide at rest", 68);
    demand(host.send(a, .{ .pointer = .{ .kind = .move, .x = 50, .y = 10 } }), "send move over the box", 69);
    serveUntilParked(a);
    var mid = false;
    const t0 = usys.nowMs();
    while (usys.nowMs() - t0 < 3000) {
        if (host.wakeDelay(a)) |d| if (d > 0) usys.sleepMs(@min(d, 30));
        host.tickWakes();
        if (pa.parked == null) serveUntilParked(a);
        const red = countColour(a, 0xff0000);
        if (red > 100 * 20 and red < 200 * 20) mid = true;
        if (red == 200 * 20) break;
        if (host.wakeDelay(a) == null) usys.sleepMs(20);
    }
    demand(mid, "the width never showed a value between its ends", 70);
    demand(countColour(a, 0xff0000) == 200 * 20, "the transition did not end at 200 px", 71);
    _ = usys.log(glog, "webpagecli: the hover transition ran to its end");

    _ = usys.log(glog, "webpagecli: page domains ok");
    host.deinit();
    usys.exit(0);
}
