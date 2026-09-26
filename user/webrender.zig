//! `web-render URL`: a page loaded the way a window would load it — in
//! a page domain, through a broker — and its document handed back as
//! the tree `html-parse` makes. The domain is spawned from the store's
//! `webpage` image for the one call and destroyed after it; this
//! program is its broker, so the page reaches exactly the network this
//! script's view allows and nothing else. Headless: the page lays out
//! for a nominal viewport and paints nothing. A page that dies (its
//! arena, a fault) is an error here and nothing more.
const std = @import("std");
const shared = @import("shared");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const web = mosslib.web;
const Value = mshl.Value;
const Shape = mshl.Shape;
const usys = @import("usys.zig");
const webhost = @import("webhost.zig");
const webcmds = @import("webcmds.zig");
const progload = @import("progload.zig");
const loader = @import("loader.zig");
const fscmds = @import("fscmds.zig");
const netcmds = @import("netcmds.zig");
const wire = shared.web;

pub const command_names = [_][]const u8{"web-render"};

var spawner: u64 = 0;
var net: ?*netcmds.Net = null;
var view: u64 = 0;
var view_buf: [*]u8 = undefined;
var stores: []const ?fscmds.Store = &.{};
var log_h: u64 = 0;
var host: webhost.Host = undefined;
var host_ready = false;
var stage: ?loader.Stage = null;
var staged = false;

/// The page host, set up on first use; `js-run { net: true }` lends its
/// broker to script domains, so a program's fetches are policed in the
/// one place a page's are. Null without a network view or a channel.
pub fn ensureHost() ?*webhost.Host {
    const n = net orelse return null;
    if (n.chan == 0) return null;
    if (!host_ready) {
        host.reset(log_h, spawner, n);
        if (!host.init()) return null;
        if (view != 0) _ = host.loadFonts(view, view_buf);
        host_ready = true;
    }
    return &host;
}

pub fn setup(spawner_cap: u64, n: *netcmds.Net, view_chan: u64, buf: [*]u8, s: []const ?fscmds.Store, log: u64) void {
    spawner = spawner_cap;
    net = n;
    view = view_chan;
    view_buf = buf;
    stores = s;
    log_h = log;
}

const render_shape = blk: {
    const fields = [_]Shape.Field{
        .{ .key = "url", .shape = .string },
        .{ .key = "title", .shape = .string },
        .{ .key = "dom", .shape = .record },
    };
    break :blk Shape{ .record_of = &fields };
};
const render_result = mshl.resultShape(render_shape, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "web-render")) return .{ .params = &.{.{ .name = "url", .shape = .string }}, .ret = render_result };
    return null;
}

fn errResult(it: *mshl.Interp, comptime fmt: []const u8, args: anytype) mshl.Error!?Value {
    return try it.mkResult(false, .{ .str = try std.fmt.allocPrint(it.arena, fmt, args) });
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    _ = input;
    if (!std.mem.eql(u8, name, "web-render")) return null;
    if (args.len < 1 or args[0] != .str) return it.fail("web-render: a URL is needed", .{});
    const url = args[0].str;
    if (spawner == 0) return errResult(it, "web-render: this program holds no spawner", .{});
    const n = net orelse return errResult(it, "web-render: no network view", .{});
    if (n.chan == 0) return errResult(it, "web-render: no network view", .{});
    const h = ensureHost() orelse return errResult(it, "web-render: out of channels", .{});
    if (stage == null) stage = loader.Stage.init(loader.Stage.default_pages) orelse return errResult(it, "web-render: no room to stage the page image", .{});
    if (!staged) {
        _ = progload.loadImage(it, "webpage", stores, &stage.?) orelse return errResult(it, "web-render: the webpage image is not in the store", .{});
        staged = true;
    }
    const id = h.spawn(stage.?.handle, 0, 0) orelse return errResult(it, "web-render: the page domain could not be spawned", .{});
    defer h.destroy(id);
    if (!h.send(id, .{ .load = url })) return errResult(it, "web-render: the page took no command", .{});
    switch (waitLoad(h, id)) {
        .done => {},
        .failed => |code| return errResult(it, "web-render: the load failed ({s})", .{if (std.enums.fromInt(wire.RefuseCode, code)) |c| @tagName(c) else "the server refused"}),
        .dead => return errResult(it, "web-render: the page died", .{}),
        .stuck => return errResult(it, "web-render: the page never finished", .{}),
    }
    if (!settle(h, id)) return errResult(it, "web-render: the page died", .{});
    if (!h.send(id, .{ .dump = .html })) return errResult(it, "web-render: the page took no command", .{});
    var steps: usize = 0;
    while (steps < 10_000) : (steps += 1) {
        switch (h.step()) {
            .event => |e| if (e.page == id and e.kind == .dumped) break,
            .dead, .failed, .idle => return errResult(it, "web-render: the page died", .{}),
            else => {},
        }
    } else return errResult(it, "web-render: the page never answered", .{});
    const p = h.page(id);
    const markup = try it.arena.dupe(u8, p.dumped());
    const doc = web.html.parse(it.arena, markup, .{}) catch return mshl.Error.OutOfMemory;
    const dom_value = try webcmds.toDataFrom(it, doc, web.dom.document_id, false);
    const keys = try it.arena.dupe([]const u8, &.{ "url", "title", "dom" });
    const vals = try it.arena.dupe(Value, &.{ .{ .str = try it.arena.dupe(u8, p.urlText()) }, .{ .str = try it.arena.dupe(u8, p.titleText()) }, dom_value });
    return try it.mkResult(true, .{ .record = .{ .keys = keys, .vals = vals } });
}

/// A page loaded is not a page finished: its scripts may have timers
/// and frames pending (a page that builds itself after `load`). This
/// program is the page's clock, so it sleeps until each wake is due,
/// ticks the page, and serves it until it parks again — for up to two
/// seconds of wall time, which is a headless render's patience.
fn settle(h: *webhost.Host, id: webhost.PageId) bool {
    const t0 = usys.nowMs();
    var rounds: usize = 0;
    while (rounds < 200) : (rounds += 1) {
        const delay = h.wakeDelay(id) orelse return true;
        if (usys.nowMs() - t0 > 2000) return true;
        if (delay > 0) usys.sleepMs(@min(delay, 250));
        h.tickWakes();
        // Serve until the page has taken the tick and parked on `next`.
        var steps: usize = 0;
        while (steps < 10_000 and h.page(id).parked == null) : (steps += 1) {
            switch (h.step()) {
                .dead, .failed, .idle => return false,
                else => {},
            }
        }
    }
    return true;
}

const LoadEnd = union(enum) { done, failed: u64, dead, stuck };

fn waitLoad(h: *webhost.Host, id: webhost.PageId) LoadEnd {
    var steps: usize = 0;
    while (steps < 100_000) : (steps += 1) {
        switch (h.step()) {
            .event => |e| if (e.page == id and e.kind == .load) {
                const st = std.enums.fromInt(wire.LoadState, e.a) orelse .failed;
                if (st == .done) return .done;
                if (st == .failed) return .{ .failed = e.b };
            },
            .dead, .failed, .idle => return .dead,
            else => {},
        }
    }
    return .stuck;
}
