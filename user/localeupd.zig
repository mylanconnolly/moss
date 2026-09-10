//! localeupd — the locale-database auto-updater. On a timer it fetches a
//! fresher `cldr.db` from a configured upstream over TLS, validates it, and
//! installs it into the assets tier (`assets/locale/cldr.db`); the locale
//! consumers (localecmds) reload it on their own when its mtime/size change,
//! the way dotd's clients pick up new trust roots. So the locale data stays
//! current without a rebuild or a restart.
//!
//! It fetches the *pre-built blob* (cldrgen's output, served upstream), not
//! raw CLDR — no megabytes of JSON parsed on-device. The TLS client, the
//! roots-from-a-view with hot reload, and the config-from-`data()` are all
//! the dotd model; the whole-file write is the fontcli model. Config
//! (`conf/locale.msh`): `{ upstream, name, roots, interval }`. `interval` 0
//! fetches once and exits (the drill); > 0 loops every that-many seconds.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const netcmds = @import("netcmds.zig");
const fsc = @import("fsclient.zig");
const mosslib = @import("mosslib");
const tls = mosslib.tls;
const http = mosslib.http;
const locale = mosslib.locale;
const mshl = mosslib.mshl;

comptime {
    asm (usys.imageHeader("localeupd"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(msg: []const u8, _: ?usize) noreturn {
    var buf: [200]u8 = undefined;
    const pre = "localeupd: panic: ";
    @memcpy(buf[0..pre.len], pre);
    const n = @min(msg.len, buf.len - pre.len);
    @memcpy(buf[pre.len .. pre.len + n], msg[0..n]);
    _ = usys.log(glog, buf[0 .. pre.len + n]);
    usys.exit(255);
}

var glog: u64 = 0;

fn fail(msg: []const u8) noreturn {
    _ = usys.log(glog, msg);
    usys.exit(1);
}

fn logf(comptime fmt: []const u8, args: anytype) void {
    var b: [160]u8 = undefined;
    _ = usys.log(glog, std.fmt.bufPrint(&b, fmt, args) catch "localeupd: (log too long)");
}

// -------------------------------------------------------------- settings

var url_buf: [256]u8 = undefined;
var url_text: []const u8 = "";
var name_buf: [128]u8 = undefined;
var cert_name: []const u8 = "";
var roots_path_buf: [128]u8 = undefined;
var roots_path: []const u8 = "tls/roots.pem";
var install_path: []const u8 = "locale/cldr.db";
var tmp_path: []const u8 = "locale/cldr.db.new";
var interval_s: u64 = 0;
var settings_mem: [4 << 10]u8 = undefined;

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const mshl.Value, _: ?mshl.Value) mshl.Error!?mshl.Value {
    return null;
}

/// `{ upstream: https://host/cldr.db, name: host, roots: tls/roots.pem,
/// interval: 3600 }`. `name` is the certificate name (default: the URL
/// host); `roots`/`install` are relative to the assets view.
fn readSettings(text: []const u8) void {
    if (text.len == 0) fail("localeupd: no settings (need an upstream)");
    var fba = std.heap.FixedBufferAllocator.init(&settings_mem);
    const a = fba.allocator();
    var ctx: u8 = 0;
    var it = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&ctx), .call = noHost });
    const v = it.parseData(text) catch fail("localeupd: the settings file is not data");
    if (v != .record) fail("localeupd: the settings file is not a record");
    const up = v.record.get("upstream") orelse fail("localeupd: no upstream in the settings");
    if (up != .str or up.str.len > url_buf.len) fail("localeupd: upstream: a URL expected");
    @memcpy(url_buf[0..up.str.len], up.str);
    url_text = url_buf[0..up.str.len];
    if (v.record.get("interval")) |iv| {
        if (iv == .int and iv.int >= 0) interval_s = @intCast(iv.int);
    }
    const parsed = http.parseUrl(url_text) orelse fail("localeupd: upstream is not a valid URL");
    var name = parsed.host;
    if (v.record.get("name")) |nm| {
        if (nm == .str) name = nm.str;
    }
    if (name.len > name_buf.len) fail("localeupd: name: too long");
    @memcpy(name_buf[0..name.len], name);
    cert_name = name_buf[0..name.len];
    if (v.record.get("roots")) |rp| {
        if (rp == .str and rp.str.len <= roots_path_buf.len) {
            @memcpy(roots_path_buf[0..rp.str.len], rp.str);
            roots_path = roots_path_buf[0..rp.str.len];
        }
    }
}

// -------------------------------------------------------------- the wire

var session: tls.Session = .{};
const wire_wait_ms: u64 = 10_000;

const Wire = struct {
    net: *netcmds.Net,
    sock: u64,
    fn send(ctx: *anyopaque, data: []const u8) ?[]const u8 {
        const w: *Wire = @ptrCast(@alignCast(ctx));
        return w.net.sendAll(w.sock, data);
    }
    fn recv(ctx: *anyopaque, buf: []u8) tls.RecvOut {
        const w: *Wire = @ptrCast(@alignCast(ctx));
        return switch (w.net.recvUpToFor(w.sock, buf.len, wire_wait_ms)) {
            .data => |d| blk: {
                @memcpy(buf[0..d.len], d);
                break :blk .{ .n = d.len };
            },
            .closed => .closed,
            .failed => |m| .{ .failed = m },
            .timeout => .{ .failed = "timeout" },
        };
    }
};

// The trust roots, read from the assets view and reloaded when the file
// changes (all BSS, not image bytes: the parse arena and the PEM source).
var roots: tls.Roots = .{};
var roots_mtime: u64 = 0;
var roots_size: u64 = 0;
var roots_ok = false;
var roots_mem: [384 << 10]u8 = undefined;
var roots_pem_buf: [256 << 10]u8 = undefined;
var roots_fba: std.heap.FixedBufferAllocator = undefined;
var view_chan: u64 = 0;
var view_buf: [*]u8 = undefined;

fn ensureRoots(now_ms: u64) ?[]const u8 {
    const st = fsc.fsStat(view_chan, view_buf, roots_path) orelse return "no roots file";
    if (roots_ok and st.mtime == roots_mtime and st.size == roots_size) return null;
    const pem = fsc.readWhole(view_chan, view_buf, roots_path, &roots_pem_buf) orelse return "cannot read roots";
    roots = .{};
    roots_fba = std.heap.FixedBufferAllocator.init(&roots_mem);
    const n = roots.add(roots_fba.allocator(), pem, @intCast(now_ms / 1000)) catch 0;
    if (n == 0) {
        roots_ok = false;
        return "no roots";
    }
    roots_mtime = st.mtime;
    roots_size = st.size;
    roots_ok = true;
    return null;
}

// --------------------------------------------------------------- fetch

var raw_buf: [128 << 10]u8 = undefined; // accumulated HTTP response
var body_buf: [128 << 10]u8 = undefined; // the extracted body (the blob)
var http_mem: [32 << 10]u8 = undefined; // request format + response parse arena

const FetchOut = union(enum) { body: []const u8, failed: []const u8 };

/// GET the upstream over TLS and return the response body (the blob).
fn fetch(net: *netcmds.Net) FetchOut {
    const now = usys.wallMs() orelse return .{ .failed = "no clock" };
    if (ensureRoots(now)) |m| return .{ .failed = m };
    const url = http.parseUrl(url_text) orelse return .{ .failed = "bad url" };
    const sock = switch (net.connectHost(url.host, url.port)) {
        .sock => |s| s,
        .failed => |m| return .{ .failed = m },
    };
    defer net.closeRaw(sock);
    var wire = Wire{ .net = net, .sock = sock };
    var entropy: [tls.entropy_len]u8 = undefined;
    if (usys.getrandom(&entropy) != .ok) return .{ .failed = "no entropy" };
    session.connect(.{ .ctx = @ptrCast(&wire), .send = Wire.send, .recv = Wire.recv }, .{ .host = cert_name, .roots = &roots, .entropy = &entropy, .now_ms = now }) catch {
        return .{ .failed = session.reason() };
    };
    defer session.close();

    var fba = std.heap.FixedBufferAllocator.init(&http_mem);
    const a = fba.allocator();
    var req: std.ArrayList(u8) = .empty;
    http.formatRequest(a, &req, "GET", url.path, cert_name, &.{}, "", false) catch return .{ .failed = "request too large" };
    session.write(req.items) catch return .{ .failed = session.reason() };

    var rawlen: usize = 0;
    var closed = false;
    while (true) {
        fba.reset();
        const parsed = http.parseResponse(a, raw_buf[0..rawlen], closed) catch return .{ .failed = "bad response" };
        switch (parsed) {
            .done => |r| {
                if (r.status != 200) return .{ .failed = "upstream did not return 200" };
                if (r.body.len > body_buf.len) return .{ .failed = "blob too large" };
                @memcpy(body_buf[0..r.body.len], r.body);
                return .{ .body = body_buf[0..r.body.len] };
            },
            .incomplete => {},
        }
        if (closed) return .{ .failed = "closed before the response was complete" };
        if (rawlen == raw_buf.len) return .{ .failed = "response too large" };
        const n = session.read(raw_buf[rawlen..]) catch return .{ .failed = session.reason() };
        if (n == 0) closed = true else rawlen += n;
    }
}

// -------------------------------------------------------------- install

/// True if `blob` is a valid locale database (so we never install garbage
/// that would break every consumer); its release goes in `rel_out`.
fn validate(blob: []const u8, rel_out: *[]const u8) bool {
    const db = locale.Db.parse(blob) catch return false;
    if (db.n == 0) return false;
    rel_out.* = db.rel;
    return true;
}

/// The bytes already installed, or an empty slice if none/unreadable.
var current_buf: [128 << 10]u8 = undefined;
fn currentBlob() []const u8 {
    return fsc.readWhole(view_chan, view_buf, install_path, &current_buf) orelse "";
}

/// Write `blob` to a temp file then rename it over the install path, so a
/// reader never sees a half-written database.
fn install(blob: []const u8) bool {
    const fd = switch (fsc.fsOpen(view_chan, view_buf, tmp_path, 1)) {
        .fd => |f| f,
        .err => return false,
    };
    var off: usize = 0;
    while (off < blob.len) {
        const n = @min(shared.fs_max_io, blob.len - off);
        if (!fsc.fsWriteAt(view_chan, view_buf, fd, off, blob[off .. off + n])) {
            fsc.fsClose(view_chan, fd);
            return false;
        }
        off += n;
    }
    fsc.fsClose(view_chan, fd);
    return fsc.fsRename(view_chan, view_buf, tmp_path, install_path);
}

/// One update cycle: fetch, validate, and install if it differs from what
/// is already there (so an unchanged upstream costs no write, hence no
/// needless reload downstream).
fn update(net: *netcmds.Net) void {
    switch (fetch(net)) {
        .failed => |m| logf("localeupd: fetch failed: {s}", .{m}),
        .body => |blob| {
            var rel: []const u8 = "";
            if (!validate(blob, &rel)) {
                _ = usys.log(glog, "localeupd: fetched blob is not a valid locale database; keeping the current one");
                return;
            }
            if (std.mem.eql(u8, blob, currentBlob())) {
                logf("localeupd: already current (CLDR {s})", .{rel});
                return;
            }
            if (install(blob)) {
                logf("localeupd: installed CLDR {s} ({d} bytes)", .{ rel, blob.len });
            } else {
                _ = usys.log(glog, "localeupd: install failed");
            }
        },
    }
}

export fn umain(log_h: u64, chan_h: u64, _: u64) callconv(.c) noreturn {
    glog = log_h;
    const setup = boot.take(chan_h);
    if (!setup.has(.net)) fail("localeupd: no network view");
    if (!setup.has(.view)) fail("localeupd: no assets view");
    readSettings(setup.data());

    var net = netcmds.Net.init(setup.cap(.net));
    view_chan = setup.cap(.view);
    const ab = fsc.attachBuf(view_chan);
    if (ab.va == 0) fail("localeupd: cannot attach the assets buffer");
    view_buf = @ptrFromInt(ab.va);

    logf("localeupd: checking {s} (interval {d}s)", .{ url_text, interval_s });
    update(&net); // an update on start, then on the interval

    if (interval_s == 0) {
        _ = usys.log(glog, "localeupd: one-shot done");
        usys.exit(0);
    }

    const nc = usys.notifyCreate();
    if (nc.err != .ok) fail("localeupd: cannot create the timer notification");
    const timer = nc.data[0];
    if (usys.notifyBind(timer) != .ok) fail("localeupd: cannot bind the timer");
    _ = usys.timerArm(timer, usys.msToTicks(interval_s * 1000), 1);
    while (true) {
        _ = usys.notifyWait(timer);
        update(&net);
    }
}
