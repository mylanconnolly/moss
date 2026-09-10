//! Locale-aware formatting commands for the shell and scripts: fmt-number,
//! fmt-int, fmt-money, fmt-date, fmt-time, `locales`, and the session-locale
//! controls (sessionlocale / locale-default). They are a thin client of the
//! shared locale service (localesvc): the values and locale tag go over the
//! service's request buffer and the formatted string comes back, so the
//! whole session formats against one CLDR parse and one shared locale — set
//! `sessionlocale de-DE` in one program and every program's `fmt-*` follows,
//! the way a font-scale push reaches every text client through fontsvc.
//!
//! No formatting or CLDR parsing lives here any more; it is all in localesvc
//! (over the pure `lib/locale` the host tests cover). This module only
//! marshals a request and hands back the string the service produced.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;

var chan: u64 = 0; // the localesvc channel (badged after register)
var buf: [*]u8 = undefined; // our request/response buffer, shared with localesvc
var buf_len: usize = 0;
var buf_ok = false;
var log_h: u64 = 0;

pub fn setup(locale_chan: u64, glog: u64) void {
    chan = locale_chan;
    log_h = glog;
    if (chan == 0) return;
    // Register for a badged channel so our buffer is our own (concurrent
    // clients on one localesvc otherwise trample a shared buffer — the same
    // reason fontsvc registers its clients).
    switch (usys.callTypedCap(shared.LocaleReq, shared.LocaleResp, chan, .register, 0)) {
        .ok => |ok| if (ok.rep == .registered and ok.cap != 0) {
            chan = ok.cap;
        },
        .err => {},
    }
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) return;
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) return;
    buf = @ptrFromInt(m.data[0]);
    buf_len = m.data[1] * 4096;
    switch (usys.callTypedCap(shared.LocaleReq, shared.LocaleResp, chan, .attach_buf, sh.data[0])) {
        .ok => |ok| buf_ok = ok.rep == .ok,
        .err => {},
    }
}

pub fn on() bool {
    return chan != 0 and buf_ok;
}

// -------------------------------------------------------------- arguments

fn numOf(v: Value) ?f64 {
    return switch (v) {
        .int => |x| @floatFromInt(x),
        .float => |x| x,
        else => null,
    };
}

fn strAt(args: []const Value, i: usize) ?[]const u8 {
    if (i < args.len and args[i] == .str) return args[i].str;
    return null;
}

fn strValue(it: *mshl.Interp, s: []const u8) mshl.Error!Value {
    return .{ .str = try it.arena.dupe(u8, s) };
}

/// Send one `fmt` to localesvc: stage the tag (and, for money, the currency
/// code) in the buffer, ask for `kind`, and return the formatted string in
/// the buffer, or a loc_err code. `tag` empty = the session default.
const FmtOut = union(enum) { s: []const u8, err: u64 };
fn fmtCall(kind: u64, arg: u64, tag: []const u8, currency: []const u8, width: u64) FmtOut {
    if (!on()) return .{ .err = 0 };
    if (tag.len + currency.len > buf_len) return .{ .err = 0 };
    @memcpy(buf[0..tag.len], tag);
    if (currency.len > 0) @memcpy(buf[tag.len .. tag.len + currency.len], currency);
    // `extra`: the currency length for money, the width for date/time.
    const extra: u64 = if (kind == 2) currency.len else width;
    const meta: u64 = (kind & 0xff) | (@as(u64, tag.len) << 8) | (extra << 32);
    return switch (usys.callTyped(shared.LocaleReq, shared.LocaleResp, chan, .{ .fmt = .{ .arg = arg, .meta = meta } }, 0)) {
        .ok => |rep| switch (rep) {
            .formatted => |f| .{ .s = buf[0..@intCast(@min(f.len, buf_len))] },
            .loc_err => |e| .{ .err = e.code },
            else => .{ .err = 0 },
        },
        .err => .{ .err = 0 },
    };
}

// -------------------------------------------------------------- dispatch

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, _: ?Value) mshl.Error!?Value {
    if (!on()) return null;

    if (std.mem.eql(u8, name, "fmt-number")) {
        const v = numOf(args[0]) orelse return it.fail("fmt-number: a number expected", .{});
        return switch (fmtCall(0, @bitCast(v), strAt(args, 1) orelse "", "", 0)) {
            .s => |s| try strValue(it, s),
            .err => it.fail("fmt-number: no locale data", .{}),
        };
    }
    if (std.mem.eql(u8, name, "fmt-int")) {
        if (args[0] != .int) return it.fail("fmt-int: an integer expected", .{});
        return switch (fmtCall(1, @bitCast(args[0].int), strAt(args, 1) orelse "", "", 0)) {
            .s => |s| try strValue(it, s),
            .err => it.fail("fmt-int: no locale data", .{}),
        };
    }
    if (std.mem.eql(u8, name, "fmt-money")) {
        const v = numOf(args[0]) orelse return it.fail("fmt-money: a number expected", .{});
        if (args[1] != .str) return it.fail("fmt-money: a currency code expected", .{});
        return switch (fmtCall(2, @bitCast(v), strAt(args, 2) orelse "", args[1].str, 0)) {
            .s => |s| try strValue(it, s),
            .err => it.fail("fmt-money: no locale data", .{}),
        };
    }
    if (std.mem.eql(u8, name, "fmt-date") or std.mem.eql(u8, name, "fmt-time")) {
        const is_time = name[4] == 't';
        const tag = strAt(args, 0) orelse "";
        const width: u64 = if (strAt(args, 1)) |w| (if (std.mem.eql(u8, w, "long")) 1 else 0) else 0;
        return switch (fmtCall(if (is_time) 4 else 3, 0, tag, "", width)) {
            .s => |s| try it.mkResult(true, try strValue(it, s)),
            .err => |code| try it.mkResult(false, .{ .str = if (code == 10) "no_clock" else "no_locale" }),
        };
    }
    if (std.mem.eql(u8, name, "sessionlocale")) {
        const tag = strAt(args, 0) orelse "";
        if (tag.len > buf_len) return it.fail("sessionlocale: tag too long", .{});
        @memcpy(buf[0..tag.len], tag);
        return switch (usys.callTyped(shared.LocaleReq, shared.LocaleResp, chan, .{ .set_default = .{ .taglen = tag.len } }, 0)) {
            .ok => |rep| switch (rep) {
                .ok => try it.mkResult(true, try strValue(it, if (tag.len > 0) tag else "en-US")),
                else => try it.mkResult(false, try strValue(it, "no_locale")),
            },
            .err => it.fail("sessionlocale: the locale service did not answer", .{}),
        };
    }
    if (std.mem.eql(u8, name, "locale-default")) {
        return switch (usys.callTyped(shared.LocaleReq, shared.LocaleResp, chan, .get_default, 0)) {
            .ok => |rep| switch (rep) {
                .formatted => |f| try strValue(it, buf[0..@intCast(@min(f.len, buf_len))]),
                else => try strValue(it, "en-US"),
            },
            .err => try strValue(it, "en-US"),
        };
    }
    if (std.mem.eql(u8, name, "locales")) {
        const len: usize = switch (usys.callTyped(shared.LocaleReq, shared.LocaleResp, chan, .locales, 0)) {
            .ok => |rep| switch (rep) {
                .formatted => |f| @intCast(@min(f.len, buf_len)),
                else => return it.fail("locales: no locale data", .{}),
            },
            .err => return it.fail("locales: the locale service did not answer", .{}),
        };
        // "rel\ntag1\ntag2..." — the release on the first line, then the tags.
        var lines = std.mem.splitScalar(u8, buf[0..len], '\n');
        const rel = lines.first();
        var rows: std.ArrayList(Value) = .empty;
        while (lines.next()) |tag| {
            if (tag.len == 0) continue;
            try rows.append(it.arena, try strValue(it, tag));
        }
        const keys = try it.arena.alloc([]const u8, 2);
        keys[0] = "cldr";
        keys[1] = "locales";
        const vals = try it.arena.alloc(Value, 2);
        vals[0] = try strValue(it, rel);
        vals[1] = .{ .list = try rows.toOwnedSlice(it.arena) };
        return .{ .record = .{ .keys = keys, .vals = vals } };
    }
    return null;
}

// ------------------------------------------------------------- signatures

const num_or_int: mshl.Shape = .{ .one_of = &.{ .int, .float } };
const loc_param: mshl.Param = .{ .name = "locale", .shape = .string, .optional = true };
const dt_result = mshl.resultShape(.string, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "fmt-number"))
        return .{ .params = &.{ .{ .name = "value", .shape = num_or_int }, loc_param }, .ret = .string };
    if (std.mem.eql(u8, name, "fmt-int"))
        return .{ .params = &.{ .{ .name = "value", .shape = .int }, loc_param }, .ret = .string };
    if (std.mem.eql(u8, name, "fmt-money"))
        return .{ .params = &.{ .{ .name = "value", .shape = num_or_int }, .{ .name = "currency", .shape = .string }, loc_param }, .ret = .string };
    if (std.mem.eql(u8, name, "fmt-date"))
        return .{ .params = &.{ loc_param, .{ .name = "width", .shape = .string, .optional = true } }, .ret = dt_result };
    if (std.mem.eql(u8, name, "fmt-time"))
        return .{ .params = &.{loc_param}, .ret = dt_result };
    if (std.mem.eql(u8, name, "locales"))
        return .{ .ret = .record };
    if (std.mem.eql(u8, name, "sessionlocale"))
        return .{ .params = &.{.{ .name = "tag", .shape = .string, .optional = true }}, .ret = dt_result };
    if (std.mem.eql(u8, name, "locale-default"))
        return .{ .ret = .string };
    return null;
}

pub const command_names = [_][]const u8{ "fmt-number", "fmt-int", "fmt-money", "fmt-date", "fmt-time", "locales", "sessionlocale", "locale-default" };
