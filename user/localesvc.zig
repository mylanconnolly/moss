//! localesvc — the system locale service. It parses the CLDR database once
//! (`assets/locale/cldr.db`, read through a view and live-reloaded when an
//! updater swaps it), holds the session's current locale, and formats
//! numbers, integers, money, dates and times on request. Every text client
//! goes through it, so a single locale choice drives the whole session's
//! formatting at once — the clock in the top bar, a sample in the settings
//! app, a shell's `fmt-*` — the way fontsvc makes type consistent.
//!
//! Like fontsvc, a client `register`s for a badged channel and attaches its
//! own request/response buffer; strings (the tag, a currency code, the
//! formatted result) cross through it, keyed by badge so concurrent clients
//! never trample one buffer. No formatting logic lives here; it is all in
//! the pure `lib/locale` the host tests cover.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");
const mosslib = @import("mosslib");
const locale = mosslib.locale;
const civil = shared.civil;

comptime {
    asm (usys.imageHeader("localesvc"));
}

pub const panic = std.debug.FullPanic(uPanic);
fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

var glog: u64 = 0;

// The CLDR database, read through the assets/locale view and reloaded when
// its mtime/size changes (an updater dropped a fresher one) — the same
// self-owned-asset, live-reload pattern the consumers used before this
// service centralised it.
var view: u64 = 0;
var vbuf: [*]u8 = undefined;
var vbuf_ok = false;
var db_store: [64 << 10]u8 = undefined;
var db: locale.Db = .{};
var db_ok = false;
var db_mtime: u64 = 0;
var db_size: u64 = 0;

// The session's current default locale — what a bare format (no tag) uses.
// Set by a session's push (set_default), reverting to the built-in default
// on logout, the way fontsvc's effective scale is pushed and reverted.
const fallback_tag = "en-US";
var default_buf: [24]u8 = undefined;
var default_len: usize = 0;

fn defaultTag() []const u8 {
    return if (default_len > 0) default_buf[0..default_len] else fallback_tag;
}

fn ensureDb() bool {
    if (!vbuf_ok) return db_ok;
    const st = fsc.fsStat(view, vbuf, "cldr.db") orelse return db_ok;
    if (db_ok and st.mtime == db_mtime and st.size == db_size) return true;
    const bytes = fsc.readWhole(view, vbuf, "cldr.db", &db_store) orelse return db_ok;
    db = locale.Db.parse(bytes) catch return db_ok;
    db_ok = true;
    db_mtime = st.mtime;
    db_size = st.size;
    return true;
}

fn localeFor(tag: []const u8) ?*const locale.Locale {
    if (!ensureDb()) return null;
    return db.find(tag);
}

fn setDefault(tag: []const u8) bool {
    if (tag.len == 0) {
        default_len = 0;
        return true;
    }
    if (tag.len > default_buf.len) return false;
    if (localeFor(tag) == null) return false;
    @memcpy(default_buf[0..tag.len], tag);
    default_len = tag.len;
    return true;
}

fn nowDt() ?locale.DateTime {
    const ms = usys.wallMs() orelse return null;
    const c = civil.fromUnix(@intCast(ms / 1000));
    return .{
        .year = c.year,
        .month = @intCast(c.month),
        .day = @intCast(c.day),
        .hour = @intCast(c.hour),
        .minute = @intCast(c.minute),
        .second = @intCast(c.second),
        .weekday = @intCast(c.weekday),
    };
}

// Per-client request/response buffers, keyed by the invoking badge — the
// same model fontsvc uses (see its per-client-buffer note). A client
// registers for a fresh badge (2..); an unregistered client keeps badge 0,
// one shared slot (the single-client legacy).
const max_clients = 8;
const LClient = struct { used: bool = false, badge: u64 = 0, req_va: u64 = 0, req_len: usize = 0 };
var clients: [max_clients]LClient = @splat(.{});
var next_badge: u64 = 2;
const max_badge: u64 = 250;

fn clientFor(badge: u64) ?*LClient {
    for (&clients) |*c| if (c.used and c.badge == badge) return c;
    return null;
}
fn clientAlloc(badge: u64) ?*LClient {
    if (clientFor(badge)) |c| return c;
    for (&clients) |*c| if (!c.used) {
        c.* = .{ .used = true, .badge = badge };
        return c;
    };
    return null;
}

fn f64Of(bits: u64) f64 {
    return @bitCast(bits);
}

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    _ = arg;
    _ = blob_va;
    _ = blob_len;
    glog = log_h;
    const setup = boot.take(chan_h);
    view = if (setup.has(.view)) setup.cap(.view) else 0;
    if (view != 0) {
        const ab = fsc.attachBuf(view);
        if (ab.va != 0) {
            vbuf = @ptrFromInt(ab.va);
            vbuf_ok = true;
            _ = ensureDb();
        }
    }
    if (!db_ok) {
        _ = usys.log(glog, "localesvc: no locale data");
        usys.exit(166);
    }
    _ = usys.log(glog, "localesvc: up");

    var scratch: [256]u8 = undefined;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) continue;
        const req = shared.decodeMsg(shared.LocaleReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 1 } }, 0);
            continue;
        };
        switch (req) {
            .register => {
                if (next_badge > max_badge) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 2 } }, 0);
                    continue;
                }
                const minted = usys.chanMint(chan_h, next_badge);
                if (minted.err != .ok) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 3 } }, 0);
                    continue;
                }
                next_badge += 1;
                _ = usys.replyTyped(shared.LocaleResp, chan_h, .registered, minted.data[1]);
            },
            .attach_buf => {
                if (r.cap == 0) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 4 } }, 0);
                    continue;
                }
                const cm = usys.shmMap(r.cap);
                _ = usys.capDrop(r.cap);
                if (cm.err != .ok) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 5 } }, 0);
                    continue;
                }
                const c = clientAlloc(r.badge) orelse {
                    _ = usys.shmUnmap(cm.data[0]);
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 6 } }, 0);
                    continue;
                };
                if (c.req_va != 0) _ = usys.shmUnmap(c.req_va);
                c.req_va = cm.data[0];
                c.req_len = cm.data[1] * 4096;
                _ = usys.replyTyped(shared.LocaleResp, chan_h, .ok, 0);
            },
            .fmt => |q| {
                const c = clientFor(r.badge);
                if (c == null or c.?.req_va == 0) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 7 } }, 0);
                    continue;
                }
                const kind = q.meta & 0xff;
                const taglen: usize = @intCast((q.meta >> 8) & 0xffffff);
                const extra: usize = @intCast(q.meta >> 32);
                const cbuf: [*]u8 = @ptrFromInt(c.?.req_va);
                const clen = c.?.req_len;
                if (taglen > clen or taglen + extra > clen) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 8 } }, 0);
                    continue;
                }
                const tag: []const u8 = if (taglen > 0) cbuf[0..taglen] else defaultTag();
                const loc = localeFor(tag) orelse {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 9 } }, 0);
                    continue;
                };
                var s: []const u8 = "";
                switch (kind) {
                    0 => s = loc.formatNumber(&scratch, f64Of(q.arg), loc.dec_min_frac, loc.dec_max_frac),
                    1 => s = loc.formatInt(&scratch, @as(i64, @bitCast(q.arg))),
                    2 => s = loc.formatMoney(&scratch, f64Of(q.arg), cbuf[taglen .. taglen + extra]),
                    3, 4 => {
                        const dt = nowDt() orelse {
                            _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 10 } }, 0);
                            continue;
                        };
                        const w: locale.Width = if (extra == 1) .long else .medium;
                        s = if (kind == 4) loc.formatTime(&scratch, dt) else loc.formatDate(&scratch, dt, w);
                    },
                    else => {
                        _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 11 } }, 0);
                        continue;
                    },
                }
                const n = @min(s.len, clen);
                @memcpy(cbuf[0..n], s[0..n]);
                _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .formatted = .{ .len = n } }, 0);
            },
            .locales => {
                const c = clientFor(r.badge);
                if (c == null or c.?.req_va == 0 or !ensureDb()) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 12 } }, 0);
                    continue;
                }
                const cbuf: [*]u8 = @ptrFromInt(c.?.req_va);
                const clen = c.?.req_len;
                var n: usize = 0;
                n += copyInto(cbuf, clen, n, db.rel);
                for (db.locales[0..db.n]) |*l| {
                    n += copyInto(cbuf, clen, n, "\n");
                    n += copyInto(cbuf, clen, n, l.tag);
                }
                _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .formatted = .{ .len = n } }, 0);
            },
            .set_default => |q| {
                const c = clientFor(r.badge);
                if (c == null or c.?.req_va == 0 or q.taglen > c.?.req_len) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 13 } }, 0);
                    continue;
                }
                const cbuf: [*]u8 = @ptrFromInt(c.?.req_va);
                const tag: []const u8 = if (q.taglen > 0) cbuf[0..@intCast(q.taglen)] else "";
                if (!setDefault(tag)) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 14 } }, 0);
                    continue;
                }
                // Log the applied default (the session-wide locale is now set):
                // a durable trace, and what a drill keys on.
                var b: [48]u8 = undefined;
                const cur = defaultTag();
                const pre = "locale: ";
                @memcpy(b[0..pre.len], pre);
                const k = @min(cur.len, b.len - pre.len);
                @memcpy(b[pre.len .. pre.len + k], cur[0..k]);
                _ = usys.log(glog, b[0 .. pre.len + k]);
                _ = usys.replyTyped(shared.LocaleResp, chan_h, .ok, 0);
            },
            .get_default => {
                const c = clientFor(r.badge);
                if (c == null or c.?.req_va == 0) {
                    _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .loc_err = .{ .code = 15 } }, 0);
                    continue;
                }
                const cbuf: [*]u8 = @ptrFromInt(c.?.req_va);
                const cur = defaultTag();
                const n = @min(cur.len, c.?.req_len);
                @memcpy(cbuf[0..n], cur[0..n]);
                _ = usys.replyTyped(shared.LocaleResp, chan_h, .{ .formatted = .{ .len = n } }, 0);
            },
        }
    }
}

fn copyInto(buf: [*]u8, cap: usize, at: usize, s: []const u8) usize {
    if (at >= cap) return 0;
    const n = @min(s.len, cap - at);
    @memcpy(buf[at .. at + n], s[0..n]);
    return n;
}
