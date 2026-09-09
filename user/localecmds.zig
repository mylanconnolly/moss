//! Locale-aware formatting commands for the shell and scripts: fmt-number,
//! fmt-int, fmt-money, fmt-date, fmt-time, and `locales`. They format
//! against Unicode CLDR data (`lib/locale.zig`) loaded from the compact
//! `assets/locale/cldr.db` the system ships.
//!
//! This module holds its own read-only view of the assets/locale directory
//! (given under `{ tag: locale }`) and reloads the blob when its mtime or
//! size changes — the same self-owned-asset, live-reload pattern dotd uses
//! for trust roots. So the locale auto-updater dropping a fresher db into
//! the assets tier takes effect here with no restart. No formatting logic
//! lives here; it is all in the pure `lib/locale` the tests cover.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const fsc = @import("fsclient.zig");
const mshl = mosslib.mshl;
const locale = mosslib.locale;
const civil = shared.civil;
const Value = mshl.Value;

var view: u64 = 0;
var buf: [*]u8 = undefined; // the view's IPC staging buffer (attachBuf)
var buf_ok = false;
var db_store: [64 << 10]u8 = undefined; // the blob; Db borrows into it
var db: locale.Db = .{};
var db_ok = false;
var db_mtime: u64 = 0;
var db_size: u64 = 0;

/// The locale a bare `fmt-*` uses when none is named. en-US to start; a
/// per-user default can seed this later, the way the font scale does.
const default_tag = "en-US";

pub fn setup(view_cap: u64) void {
    view = view_cap;
    if (view == 0) return;
    const ab = fsc.attachBuf(view);
    if (ab.va == 0) return;
    buf = @ptrFromInt(ab.va);
    buf_ok = true;
    _ = ensureDb();
}

pub fn on() bool {
    return view != 0;
}

/// Load the blob if we have not, or reload it if the file changed on disk
/// (an updater swapped it). Cheap: one stat per call, a read only on change.
fn ensureDb() bool {
    if (!buf_ok) return db_ok;
    const st = fsc.fsStat(view, buf, "cldr.db") orelse return db_ok;
    if (db_ok and st.mtime == db_mtime and st.size == db_size) return true;
    const bytes = fsc.readWhole(view, buf, "cldr.db", &db_store) orelse return db_ok;
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

fn strValue(it: *mshl.Interp, s: []const u8) mshl.Error!Value {
    return .{ .str = try it.arena.dupe(u8, s) };
}

// -------------------------------------------------------------- dispatch

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, _: ?Value) mshl.Error!?Value {
    if (!on()) return null;
    var out: [128]u8 = undefined;

    if (std.mem.eql(u8, name, "fmt-number")) {
        const v = numOf(args[0]) orelse return it.fail("fmt-number: a number expected", .{});
        const loc = localeFor(strAt(args, 1) orelse default_tag) orelse return it.fail("fmt-number: no locale data", .{});
        return try strValue(it, loc.formatNumber(&out, v, loc.dec_min_frac, loc.dec_max_frac));
    }
    if (std.mem.eql(u8, name, "fmt-int")) {
        if (args[0] != .int) return it.fail("fmt-int: an integer expected", .{});
        const loc = localeFor(strAt(args, 1) orelse default_tag) orelse return it.fail("fmt-int: no locale data", .{});
        return try strValue(it, loc.formatInt(&out, args[0].int));
    }
    if (std.mem.eql(u8, name, "fmt-money")) {
        const v = numOf(args[0]) orelse return it.fail("fmt-money: a number expected", .{});
        if (args[1] != .str) return it.fail("fmt-money: a currency code expected", .{});
        const loc = localeFor(strAt(args, 2) orelse default_tag) orelse return it.fail("fmt-money: no locale data", .{});
        return try strValue(it, loc.formatMoney(&out, v, args[1].str));
    }
    if (std.mem.eql(u8, name, "fmt-date") or std.mem.eql(u8, name, "fmt-time")) {
        const is_time = name[4] == 't';
        const tag = strAt(args, 0) orelse default_tag;
        const width: locale.Width = if (strAt(args, 1)) |w|
            (if (std.mem.eql(u8, w, "long")) .long else .medium)
        else
            .medium;
        const loc = localeFor(tag) orelse return try it.mkResult(false, .{ .str = "no_locale" });
        const dt = nowDt() orelse return try it.mkResult(false, .{ .str = "no_clock" });
        const s = if (is_time) loc.formatTime(&out, dt) else loc.formatDate(&out, dt, width);
        return try it.mkResult(true, try strValue(it, s));
    }
    if (std.mem.eql(u8, name, "locales")) {
        if (!ensureDb()) return it.fail("locales: no locale data", .{});
        var rows: std.ArrayList(Value) = .empty;
        for (db.locales[0..db.n]) |*l| try rows.append(it.arena, try strValue(it, l.tag));
        const keys = try it.arena.alloc([]const u8, 2);
        keys[0] = "cldr";
        keys[1] = "locales";
        const vals = try it.arena.alloc(Value, 2);
        vals[0] = try strValue(it, db.rel);
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
    return null;
}

pub const command_names = [_][]const u8{ "fmt-number", "fmt-int", "fmt-money", "fmt-date", "fmt-time", "locales" };
