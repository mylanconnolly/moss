//! The system-settings commands (`sysconf-*`): a script's window onto the
//! system configuration layer (`conf/app/<name>.msh`), reached through the
//! one `conf` view its unit or session was handed. The settings app reads
//! the system defaults with `sysconf-read`, and — when its view is
//! read-write, which the session manager grants only to an administrator —
//! writes them with `sysconf-write`. `sysconf-admin` reports whether this
//! session may write (the view's writability is the capability, so there is
//! nothing to spoof): the app renders the system pane editable only then.
//!
//! Everything here goes through the process's own `conf` view, so the
//! authority is exactly what that cap carries — read-only for an ordinary
//! user, read-write for an admin. The commands never widen it.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const fsc = @import("fsclient.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;

var view: u64 = 0;
var buf: [*]u8 = undefined; // the conf view's IPC staging buffer
var buf_ok = false;
var log_h: u64 = 0;

pub fn setup(conf_cap: u64, glog: u64) void {
    view = conf_cap;
    log_h = glog;
    if (view == 0) return;
    const ab = fsc.attachBuf(view);
    if (ab.va == 0) return;
    buf = @ptrFromInt(ab.va);
    buf_ok = true;
}

/// Log a system-settings write's outcome to the kernel log. A GUI script
/// runs its `sysconf-write` inside its event loop, where mshl discards a
/// statement's value, so the shell cannot echo the result itself — the
/// write logs here instead, which is also the durable audit trail for a
/// change to the system's settings.
fn logOutcome(verb: []const u8, name: []const u8) void {
    var b: [96]u8 = undefined;
    var n: usize = 0;
    for ([_][]const u8{ "sysconf: ", verb, " ", name }) |part| {
        const k = @min(part.len, b.len - n);
        @memcpy(b[n .. n + k], part[0..k]);
        n += k;
    }
    _ = usys.log(log_h, b[0..n]);
}

pub fn on() bool {
    return view != 0 and buf_ok;
}

/// A settings name is one path segment of the conf/app tier — letters,
/// digits, '-' and '_'. No slashes or dots: the view is the whole system
/// layer, and a name must not climb out of it.
fn nameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > 32) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= 'A' and c <= 'Z') or
            (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

/// `conf/app/<name>.msh`, relative to the conf view's root (which is
/// conf/app). Written into a caller-owned buffer.
fn pathOf(out: *[40]u8, name: []const u8) []const u8 {
    @memcpy(out[0..name.len], name);
    @memcpy(out[name.len .. name.len + 4], ".msh");
    return out[0 .. name.len + 4];
}

/// True when the conf view is read-write (an admin session). The view's
/// own statfs carries the read-only bit the fs service tracks per badge.
fn writable() bool {
    const st = fsc.fsStatfs(view) orelse return false;
    return !st.read_only;
}

var read_buf: [4 << 10]u8 = undefined;

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value, input: ?Value) mshl.Error!?Value {
    if (!on()) return null;

    if (std.mem.eql(u8, name, "sysconf-admin")) {
        return .{ .bool = writable() };
    }
    if (std.mem.eql(u8, name, "sysconf-read")) {
        if (args.len == 0 or args[0] != .str or !nameOk(args[0].str))
            return it.fail("sysconf-read: a settings name expected", .{});
        var pb: [40]u8 = undefined;
        const p = pathOf(&pb, args[0].str);
        const text = fsc.readWhole(view, buf, p, &read_buf) orelse
            return try it.mkResult(false, .{ .str = "absent" });
        return try it.mkResult(true, .{ .str = try it.arena.dupe(u8, text) });
    }
    if (std.mem.eql(u8, name, "sysconf-write")) {
        if (args.len < 1 or args[0] != .str or !nameOk(args[0].str))
            return it.fail("sysconf-write: a settings name expected", .{});
        const text: []const u8 = if (args.len >= 2 and args[1] == .str)
            args[1].str
        else if (input != null and input.? == .str)
            input.?.str
        else
            return it.fail("sysconf-write: the settings text expected", .{});
        if (text.len > read_buf.len) return it.fail("sysconf-write: too large", .{});
        if (!writable()) {
            logOutcome("read-only", args[0].str);
            return try it.mkResult(false, .{ .str = "read-only" });
        }
        var pb: [40]u8 = undefined;
        const p = pathOf(&pb, args[0].str);
        const fd = switch (fsc.fsOpen(view, buf, p, 1)) {
            .fd => |fd| fd,
            .err => {
                logOutcome("denied", args[0].str);
                return try it.mkResult(false, .{ .str = "denied" });
            },
        };
        defer fsc.fsClose(view, fd);
        if (!fsc.fsTruncate(view, fd, 0) or !fsc.fsWriteAt(view, buf, fd, 0, text)) {
            logOutcome("denied", args[0].str);
            return try it.mkResult(false, .{ .str = "denied" });
        }
        _ = fsc.fsSync(view);
        logOutcome("saved", args[0].str);
        return try it.mkResult(true, .{ .str = try it.arena.dupe(u8, args[0].str) });
    }
    return null;
}

pub const command_names = [_][]const u8{ "sysconf-admin", "sysconf-read", "sysconf-write" };

const str_result = mshl.resultShape(.string, .string);

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "sysconf-admin"))
        return .{ .ret = .bool };
    if (std.mem.eql(u8, name, "sysconf-read"))
        return .{ .params = &.{.{ .name = "name", .shape = .string }}, .ret = str_result };
    if (std.mem.eql(u8, name, "sysconf-write"))
        return .{ .params = &.{ .{ .name = "name", .shape = .string }, .{ .name = "text", .shape = .string, .optional = true } }, .input = .{ .optional = .string }, .ret = str_result };
    return null;
}
