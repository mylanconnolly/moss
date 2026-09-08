//! sess — the mshl login command, for a host that holds a `sess` cap
//! (the session manager, usersvc). `login NAME PASS` authenticates the
//! credentials and runs the session to completion, returning `ok { who }`
//! or `err`. Only data — the name and the passphrase — crosses. This is
//! how a GUI greeter turns credentials collected in a form into a real,
//! authenticated, home-isolated session, instead of a hardcoded check;
//! usersvc unseals the identity, spawns a session domain under the user's
//! budgets with a view of their home, and nobody here sees the key.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const mosslib = @import("mosslib");
const mshl = mosslib.mshl;
const Value = mshl.Value;

var sess_chan: u64 = 0;
var sess_buf: [*]u8 = undefined;
var attached = false;
/// A terminal to hand the session as its console: with it, `login` opens
/// an interactive session (a shell on that console). Sent once.
var console_cap: u64 = 0;

pub fn setup(sess_cap: u64, console: u64) void {
    sess_chan = sess_cap;
    console_cap = console;
}

/// Whether the host holds a session manager — `login` is offered only then.
pub fn on() bool {
    return sess_chan != 0;
}

pub fn signature(name: []const u8) ?mshl.Signature {
    if (std.mem.eql(u8, name, "login")) {
        return .{ .params = &.{ .{ .name = "name", .shape = .string }, .{ .name = "pass", .shape = .string } }, .ret = .any };
    }
    return null;
}

/// One shared buffer with usersvc, attached on first use (badge 0 — the
/// unbadged holder of the channel).
fn ensureBuf() bool {
    if (attached) return true;
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) return false;
    const sm = usys.shmMap(sh.data[0]);
    if (sm.err != .ok) return false;
    sess_buf = @ptrFromInt(sm.data[0]);
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .attach_buf, sh.data[0])) {
        .ok => {
            attached = true;
            return true;
        },
        .err => return false,
    }
}

fn sessWord(off: usize, s: []const u8) u64 {
    @memcpy(sess_buf[off .. off + s.len], s);
    return @as(u64, off) | (@as(u64, s.len) << 32);
}

fn errResult(it: *mshl.Interp, msg: []const u8) mshl.Error!Value {
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = false, .val = .{ .str = msg } };
    return .{ .result = r };
}

pub fn call(it: *mshl.Interp, name: []const u8, args: []const Value) mshl.Error!?Value {
    if (!std.mem.eql(u8, name, "login")) return null;
    if (args.len != 2 or args[0] != .str or args[1] != .str) return it.fail("login: NAME and PASS (strings) expected", .{});
    const user = args[0].str;
    const pass = args[1].str;
    if (user.len == 0 or user.len > 16 or pass.len == 0 or pass.len > 256) {
        return it.fail("login: a name is 1..16 bytes and a passphrase 1..256", .{});
    }
    if (!ensureBuf()) return it.fail("login: cannot attach a buffer to the session manager", .{});

    const nw = sessWord(0, user);
    const pw = sessWord(512, pass);
    defer @memset(sess_buf[0..1024], 0); // the passphrase leaves this buffer wiped

    const console = console_cap;
    console_cap = 0; // sent once — it becomes the session's
    const rep = switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .login = .{ .name = nw, .pass = pw } }, console)) {
        .ok => |r| r,
        .err => return it.fail("login: the session manager did not answer", .{}),
    };
    const sid = switch (rep) {
        .session => |s| s.sid,
        .denied => return try errResult(it, "denied"),
        else => return try errResult(it, "refused"),
    };
    // Run the session to completion and tear it down. The console-less
    // session is the verifier program: it does its home I/O and exits.
    _ = usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .wait = .{ .sid = sid } }, 0);

    const keys = try it.arena.alloc([]const u8, 1);
    keys[0] = "who";
    const vals = try it.arena.alloc(Value, 1);
    vals[0] = .{ .str = try it.arena.dupe(u8, user) };
    const r = try it.arena.create(mshl.Result);
    r.* = .{ .ok = true, .val = .{ .record = .{ .keys = keys, .vals = vals } } };
    return .{ .result = r };
}
