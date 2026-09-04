//! Users, by x2. A user is not a kernel concept: the kernel has domains,
//! budgets and capabilities, and everything below composes them.
//!   1 "usersvc"   — the session manager and key custodian. Holds a view
//!                   of the user records (conf/users, ro), the home tier
//!                   (home/, rw) and the system settings layer (conf/app,
//!                   ro), plus spawn authority. `login` unseals a record's
//!                   identity with the passphrase (lib/usercred.zig) and
//!                   spawns a SESSION: a domain under the user's budgets
//!                   handed a rw view of home/<name> and the settings
//!                   layer — nothing else. The unlocked key stays here for
//!                   the session's lifetime; `wait`/`logout` destroy the
//!                   domain, which is the whole logout.
//!   2 "apply"     — the desired-state tool: makes the volume match
//!                   conf/system.msh (users created for those without a
//!                   record, the settings layer written where it differs);
//!                   the drills' admin step, and `run apply` from the shell.
//!                   (was: "useradmin" — the admin step of the drill: writes two user records
//!                   (fresh seeds and salts from the kernel pool, sealed
//!                   under compiled-in test passphrases) and the system
//!                   settings file. Records are mshl data, like unit
//!                   files; an installer writes the same thing.
//!   3 "session"   — what a login runs: writes into its home, proves that
//!                   nothing above the home is nameable, and computes its
//!                   effective settings from the system and user layers
//!                   with a locked key (lib/settings.zig).
//!   4 "drill"     — the users drill: refused logins (wrong passphrase,
//!                   unknown user), two sessions open at once, and, after
//!                   both ended, each home holding exactly its own user's
//!                   work.
//! usersvc's x2 also carries flags: bit 8 = run a login prompt on every
//! console it was handed (a session opened there is an init instance —
//! mode 3 — with the console, the home view and the settings view, so
//! msh in it holds the console until the user leaves); bit 9 = the login
//! drill: exit 0 once every console has had a session end and none is
//! open, so the boot can report.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");
const fsc = @import("fsclient.zig");
const loader = @import("loader.zig");
const mosslib = @import("mosslib");
const result = @import("result.zig");
const mshl = mosslib.mshl;
const usercred = mosslib.usercred;
const fabcert = mosslib.fabcert;
const settings = mosslib.settings;
const Value = mshl.Value;

comptime {
    asm (usys.imageHeader("users"));
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

export fn umain(log_h: u64, chan_h: u64, role: u64, bva: u64, blen: u64) callconv(.c) noreturn {
    glog = log_h;
    blob_va = bva; // the archive, for roles granted bootfs (apply reads its default from it)
    blob_len = blen;
    switch (role & 0xff) {
        1 => usersvc(chan_h, bva, blen, role),
        2 => apply(chan_h),
        3 => session(chan_h),
        4 => drill(chan_h),
        else => usys.exit(250),
    }
}

var glog: u64 = 0;

// The KDF's work area: 128 * 2^ln * r bytes. Static, so it sizes every
// role's domain (BSS is mapped at spawn) — the drill's records use ln 11
// (2 MiB); a deployment raises the cost and this area together.
const kdf_heap_len = (2 << 20) + (64 << 10);
var kdf_heap: [kdf_heap_len]u8 = undefined;
var text_heap: [64 << 10]u8 = undefined; // the data parser's arena
var host_ctx: u8 = 0;

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const Value, _: ?Value) mshl.Error!?Value {
    return null;
}

const drill_kdf: usercred.Kdf = .{ .ln = 11, .r = 8, .p = 1 };

/// The drill's users: name, passphrase.
const max_name = 16;

/// A user name is a directory name and a domain argument: short, plain.
fn nameOk(name: []const u8) bool {
    if (name.len == 0 or name.len > max_name) return false;
    for (name) |c| {
        const ok = (c >= 'a' and c <= 'z') or (c >= '0' and c <= '9') or c == '-' or c == '_';
        if (!ok) return false;
    }
    return true;
}

// ------------------------------------------------------------ the service

const max_sessions = 4;

const Session = struct {
    used: bool = false,
    ctl: u64 = 0,
    /// The session's home filesystem service (its volume's only key
    /// holder) and the buffer we share with it.
    fs_ctl: u64 = 0,
    fs_buf_h: u64 = 0,
    fs_buf_va: u64 = 0,
    fs_chan: u64 = 0,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,
    /// The user's identity, unlocked for the session's lifetime.
    kp: usercred.Ed25519.KeyPair = undefined,
    /// A remote home: the lease cap on the holder's manager (dropped at
    /// logout, which ends the lease there) and the node it lives on.
    lease: u64 = 0,
    home_node: u64 = 0,
};

/// A record's budgets, and the node its home lives on (0: here).
const Budget = struct { kobj_kb: u64 = 1 << 10, user_kb: u64 = 4 << 10, cpu_permille: u64 = 0, home_node: u64 = 0 };

/// Homes leased to sessions on other nodes: one lease or one local
/// session per home at a time. A lease is born at the challenge (so
/// its badge can carry the proof) and held once the proof verifies.
const max_leases = 4;
const Lease = struct {
    used: bool = false,
    held: bool = false,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,
    nonce: [24]u8 = @splat(0),
};
var leases: [max_leases]Lease = @splat(.{});

var sessions: [max_sessions]Session = @splat(.{});
var svc_chan: u64 = 0;
var users_view: u64 = 0;
var users_buf: [*]u8 = undefined;
var home_view: u64 = 0;
var home_buf: [*]u8 = undefined;
var app_view: u64 = 0;
var app_buf: [*]u8 = undefined;
var store_view: u64 = 0;
var store_buf: [*]u8 = undefined;
/// One attached buffer per caller identity: badge 0 (the drill or an
/// admin holding the unbadged channel) and one per session (badge =
/// its slot + 1, minted at spawn).
const ClientBuf = struct { va: u64 = 0, pages: u64 = 0 };
var client_bufs: [max_sessions + 2 + max_leases]ClientBuf = @splat(.{});
/// The badge our published channel carries: a caller through the fabric,
/// allowed to ask for a record and for a home lease.
const remote_badge: u64 = max_sessions + 1;
/// Lease caps: badge = lease_badge0 + slot.
const lease_badge0: u64 = max_sessions + 2;

fn leaseOf(badge: u64) ?*Lease {
    if (badge < lease_badge0 or badge - lease_badge0 >= max_leases) return null;
    const l = &leases[badge - lease_badge0];
    return if (l.used) l else null;
}

fn leaseHeld(name: []const u8) bool {
    for (&leases) |*l| {
        if (l.used and l.held and std.mem.eql(u8, l.name[0..l.name_len], name)) return true;
    }
    return false;
}

fn sessionOpen(name: []const u8) bool {
    for (&sessions) |*x| {
        if (x.used and std.mem.eql(u8, x.name[0..x.name_len], name)) return true;
    }
    return false;
}
/// The fabric, when this manager has one: it publishes itself under
/// ServiceId.usersvc, and a login for a user without a local record asks
/// the other members for theirs.
var fab_chan: u64 = 0;
var fab_buf: [*]u8 = undefined;

// ------------------------------------------------------------- sharing
//
// A share is a view the owner's session derived from its home, offered
// under a name to one user; the manager brokers it and revokes it
// through the owner's root view. It lives while the owner's session
// does (the home service dies with the session, and the view with it).
const max_shares = 8;
const Share = struct {
    used: bool = false,
    name: [max_name]u8 = @splat(0),
    name_len: usize = 0,
    from: [max_name]u8 = @splat(0),
    from_len: usize = 0,
    to: [max_name]u8 = @splat(0),
    to_len: usize = 0,
    /// The view's badge on the owner's home filesystem: revoke's name for it.
    fs_badge: u64 = 0,
    /// The offered cap, held here until accepted (0 afterwards).
    cap: u64 = 0,
    accepted: bool = false,
};
var shares: [max_shares]Share = @splat(.{});
var stage: loader.Stage = undefined;
var blob_va: u64 = 0;
var blob_len: u64 = 0;
const spawner: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

fn usersvc(chan_h: u64, va: u64, len: u64, flags: u64) noreturn {
    svc_chan = chan_h;
    blob_va = va;
    blob_len = len;
    const setup = boot.take(chan_h);
    users_view = setup.cap(.view);
    home_view = setup.cap(.home);
    app_view = setup.cap(.conf);
    store_view = setup.cap(.store); // the system program store, for every session
    app_buf = @ptrFromInt(fsc.attachBuf(app_view).va);
    if (store_view != 0) store_buf = @ptrFromInt(fsc.attachBuf(store_view).va);
    if (users_view == 0 or home_view == 0 or app_view == 0) usys.exit(180);
    users_buf = @ptrFromInt(fsc.attachBuf(users_view).va);
    home_buf = @ptrFromInt(fsc.attachBuf(home_view).va);
    stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(181);
    _ = usys.log(glog, "usersvc: up; sessions are domains, identities are keys");
    fab_chan = setup.cap(.fabric);
    if (fab_chan != 0) joinPool();
    if (flags & 0x100 != 0) {
        login_drill = flags & 0x200 != 0;
        for (0..max_consoles) |i| {
            const cap = setup.capAt(.console, i);
            if (cap == 0) continue;
            console_caps[ncons] = cap;
            if (usys.threadCreate(consoleThread, ncons, &console_stacks[ncons]) != .ok) usys.exit(183);
            ncons += 1;
        }
        var line: [64]u8 = undefined;
        var n = put(&line, 0, "usersvc: login prompts on ");
        n = putNum(&line, n, ncons);
        n = put(&line, n, " consoles");
        _ = usys.log(glog, line[0..n]);
    }

    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err == .client_dead) {
            // A session's badged channel died with it: its buffer goes.
            if (r.badge < client_bufs.len and client_bufs[r.badge].va != 0) {
                _ = usys.shmUnmap(client_bufs[r.badge].va);
                client_bufs[r.badge] = .{};
            }
            // A lease cap died with the remote session: the home is free.
            if (leaseOf(r.badge)) |l| {
                if (l.held) logName("usersvc: lease released on the home of ", l.name[0..l.name_len]);
                l.* = .{};
            }
            continue;
        }
        if (r.err != .ok) usys.exit(182);
        const req = shared.decodeMsg(shared.SessReq, r.data) orelse {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            reply(.{ .sess_err = .{ .code = 1 } });
            continue;
        };
        const badge = r.badge;
        // Badge 0 (the unbadged channel: the drill, an admin) may open
        // and end sessions; a session (its own badge) may only share; a
        // caller through the fabric (the published channel's badge) may
        // only ask for a record.
        const admin_only = switch (req) {
            .login, .wait, .logout => true,
            else => false,
        };
        const remote_ok = req == .record or req == .home_challenge;
        const lease_ok = req == .attach_buf or req == .home_lease;
        const allowed = if (badge == remote_badge) remote_ok else if (leaseOf(badge) != null) lease_ok else if (badge == 0) (admin_only or req == .attach_buf or req == .record) else (!admin_only and req != .record and req != .home_challenge and req != .home_lease);
        if (!allowed) {
            if (r.cap != 0) _ = usys.capDrop(r.cap);
            reply(.{ .sess_err = .{ .code = 5 } });
            continue;
        }
        switch (req) {
            .record => |q| reply(doRecord(q.name_a, q.name_b, q.chunk)),
            .home_challenge => |q| doHomeChallenge(q.name_a, q.name_b),
            .home_lease => |q| doHomeLease(badge, q.sig_off),
            .attach_buf => {
                if (r.cap != 0 and badge < client_bufs.len) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        if (client_bufs[badge].va != 0) _ = usys.shmUnmap(client_bufs[badge].va);
                        client_bufs[badge] = .{ .va = m.data[0], .pages = m.data[1] };
                    }
                    _ = usys.capDrop(r.cap);
                } else if (r.cap != 0) _ = usys.capDrop(r.cap);
                reply(.ok);
            },
            .share => |sh| {
                lock();
                const res = doShare(badge, sh.name, sh.user, sh.badge, r.cap);
                unlock();
                if (res != .ok and r.cap != 0) _ = usys.capDrop(r.cap);
                reply(res);
            },
            .unshare => |us| {
                lock();
                const res = doUnshare(badge, us.name);
                unlock();
                reply(res);
            },
            .shares => {
                lock();
                const res = doShares(badge);
                unlock();
                reply(res);
            },
            .accept => |ac| {
                lock();
                doAccept(badge, ac.name);
                unlock();
            },
            .login => |l| {
                lock();
                const res = login(l.name, l.pass);
                unlock();
                reply(res);
            },
            .wait => |w| {
                lock();
                const s = sessionOf(w.sid) orelse {
                    unlock();
                    reply(.{ .sess_err = .{ .code = 2 } });
                    continue;
                };
                const ctl = s.ctl;
                unlock();
                var code: u64 = 0;
                while (true) {
                    const st = usys.domainStat(ctl);
                    if (st.err != .ok) break;
                    if (st.data[0] == @intFromEnum(shared.DomainState.dead)) {
                        code = st.data[1];
                        break;
                    }
                    usys.sleep(2);
                }
                lock();
                if (sessionOf(w.sid)) |still| close(still);
                unlock();
                reply(.{ .exited = .{ .code = code } });
            },
            .logout => |lo| {
                lock();
                defer unlock();
                const s = sessionOf(lo.sid) orelse {
                    reply(.{ .sess_err = .{ .code = 2 } });
                    continue;
                };
                close(s);
                reply(.ok);
            },
        }
    }
}

fn reply(resp: shared.SessResp) void {
    _ = usys.replyTyped(shared.SessResp, svc_chan, resp, 0);
}

fn sessionOf(sid: u64) ?*Session {
    if (sid >= max_sessions or !sessions[sid].used) return null;
    return &sessions[sid];
}

/// Logout is one operation: the domain tree goes, and the key with it;
/// the home volume's service goes too, and its key with that.
fn close(s: *Session) void {
    _ = usys.domainDestroy(s.ctl);
    _ = usys.capDrop(s.ctl);
    // Logout is a durability barrier: what the session was told is
    // written reaches the disk before its filesystem service goes.
    if (s.fs_chan != 0) _ = fsc.fsSync(s.fs_chan);
    releaseHome(s);
    forgetShares(s.name[0..s.name_len]);
    @memset(std.mem.asBytes(&s.kp), 0);
    logName("usersvc: session closed for ", s.name[0..s.name_len]);
    s.* = .{};
}

/// The home service, our view of it and the buffer shared with it go —
/// at logout, or when a login fails after the home was opened. The
/// buffer is unmapped, not merely dropped: a manager that kept a
/// mapping per login would run out of window after 64 of them.
fn releaseHome(s: *Session) void {
    if (s.fs_chan != 0) _ = usys.capDrop(s.fs_chan);
    if (s.fs_ctl != 0) {
        _ = usys.domainDestroy(s.fs_ctl);
        _ = usys.capDrop(s.fs_ctl);
    }
    if (s.fs_buf_va != 0) _ = usys.shmUnmap(s.fs_buf_va);
    if (s.fs_buf_h != 0) _ = usys.capDrop(s.fs_buf_h);
    // A remote home: dropping the lease cap ends the lease there.
    if (s.lease != 0) _ = usys.capDrop(s.lease);
    s.lease = 0;
    s.fs_chan = 0;
    s.fs_ctl = 0;
    s.fs_buf_va = 0;
    s.fs_buf_h = 0;
}

/// A client word: off | len<<32 into the attached buffer.
fn clientSlice(badge: u64, word: u64) ?[]u8 {
    if (badge > max_sessions) return null;
    const cb = client_bufs[badge];
    const off = word & 0xffff_ffff;
    const len = word >> 32;
    if (cb.va == 0 or len > 256 or off + len > cb.pages * 4096) return null;
    return @as([*]u8, @ptrFromInt(cb.va))[off .. off + len];
}

/// The session behind a badge (1..max_sessions), if it is open.
fn callerSession(badge: u64) ?*Session {
    if (badge == 0 or badge > max_sessions or !sessions[badge - 1].used) return null;
    return &sessions[badge - 1];
}

fn shareNameOk(name: []const u8) bool {
    return nameOk(name);
}

fn userExists(name: []const u8) bool {
    if (!nameOk(name)) return false;
    var path: [max_name + 4]u8 = undefined;
    @memcpy(path[0..name.len], name);
    @memcpy(path[name.len .. name.len + 4], ".msh");
    return fsc.fsStat(users_view, users_buf, path[0 .. name.len + 4]) != null;
}

fn findShare(from: []const u8, name: []const u8) ?*Share {
    for (&shares) |*sh| {
        if (sh.used and std.mem.eql(u8, sh.from[0..sh.from_len], from) and std.mem.eql(u8, sh.name[0..sh.name_len], name)) return sh;
    }
    return null;
}

fn findOffer(to: []const u8, name: []const u8) ?*Share {
    for (&shares) |*sh| {
        if (sh.used and std.mem.eql(u8, sh.to[0..sh.to_len], to) and std.mem.eql(u8, sh.name[0..sh.name_len], name)) return sh;
    }
    return null;
}

/// `share`: record the offer and keep the cap until someone accepts.
fn doShare(badge: u64, name_w: u64, user_w: u64, fs_badge: u64, cap: u64) shared.SessResp {
    const me = callerSession(badge) orelse return .{ .sess_err = .{ .code = 5 } };
    const name = clientSlice(badge, name_w) orelse return .{ .sess_err = .{ .code = 6 } };
    const user = clientSlice(badge, user_w) orelse return .{ .sess_err = .{ .code = 6 } };
    if (cap == 0 or !shareNameOk(name) or !userExists(user)) return .{ .sess_err = .{ .code = 6 } };
    const owner = me.name[0..me.name_len];
    if (findShare(owner, name) != null) return .{ .sess_err = .{ .code = 7 } };
    for (&shares) |*sh| {
        if (sh.used) continue;
        sh.* = .{ .used = true, .name_len = name.len, .from_len = owner.len, .to_len = user.len, .fs_badge = fs_badge, .cap = cap };
        @memcpy(sh.name[0..name.len], name);
        @memcpy(sh.from[0..owner.len], owner);
        @memcpy(sh.to[0..user.len], user);
        return .ok;
    }
    return .{ .sess_err = .{ .code = 3 } };
}

/// `unshare`: the owner's home filesystem withdraws the view (every
/// call through it fails from now on), and the offer is forgotten.
fn doUnshare(badge: u64, name_w: u64) shared.SessResp {
    const me = callerSession(badge) orelse return .{ .sess_err = .{ .code = 5 } };
    const name = clientSlice(badge, name_w) orelse return .{ .sess_err = .{ .code = 6 } };
    const sh = findShare(me.name[0..me.name_len], name) orelse return .{ .sess_err = .{ .code = 2 } };
    if (sh.cap != 0) _ = usys.capDrop(sh.cap);
    _ = fsc.fsRevoke(me.fs_chan, sh.fs_badge);
    sh.* = .{};
    return .ok;
}

/// `shares`: what I offered and what was offered to me, as a data
/// literal in my buffer.
fn doShares(badge: u64) shared.SessResp {
    const me = callerSession(badge) orelse return .{ .sess_err = .{ .code = 5 } };
    const cb = client_bufs[badge];
    if (cb.va == 0) return .{ .sess_err = .{ .code = 6 } };
    const out = @as([*]u8, @ptrFromInt(cb.va))[0 .. cb.pages * 4096];
    const mine = me.name[0..me.name_len];
    var n: usize = 0;
    n = putStr(out, n, "[\n");
    for (&shares) |*sh| {
        if (!sh.used) continue;
        const from = sh.from[0..sh.from_len];
        const to = sh.to[0..sh.to_len];
        if (!std.mem.eql(u8, from, mine) and !std.mem.eql(u8, to, mine)) continue;
        n = putStr(out, n, "  { name: \"");
        n = putStr(out, n, sh.name[0..sh.name_len]);
        n = putStr(out, n, "\", from: \"");
        n = putStr(out, n, from);
        n = putStr(out, n, "\", to: \"");
        n = putStr(out, n, to);
        n = putStr(out, n, if (sh.accepted) "\", accepted: true }\n" else "\", accepted: false }\n");
    }
    n = putStr(out, n, "]\n");
    return .{ .data = .{ .len = n } };
}

fn putStr(out: []u8, n: usize, s: []const u8) usize {
    if (n + s.len > out.len) return n;
    @memcpy(out[n .. n + s.len], s);
    return n + s.len;
}

/// `accept`: hand the offered cap to the caller; ours goes with it.
fn doAccept(badge: u64, name_w: u64) void {
    const me = callerSession(badge) orelse return reply(.{ .sess_err = .{ .code = 5 } });
    const name = clientSlice(badge, name_w) orelse return reply(.{ .sess_err = .{ .code = 6 } });
    const sh = findOffer(me.name[0..me.name_len], name) orelse return reply(.{ .sess_err = .{ .code = 2 } });
    if (sh.accepted or sh.cap == 0) return reply(.{ .sess_err = .{ .code = 8 } });
    _ = usys.replyTyped(shared.SessResp, svc_chan, .ok, sh.cap);
    _ = usys.capDrop(sh.cap); // the transferred copy carries the ref
    sh.cap = 0;
    sh.accepted = true;
}

/// A session ended: its offers die with its home service, and what it
/// accepted died with its domain.
fn forgetShares(user: []const u8) void {
    for (&shares) |*sh| {
        if (!sh.used) continue;
        const owned = std.mem.eql(u8, sh.from[0..sh.from_len], user);
        const taken = sh.accepted and std.mem.eql(u8, sh.to[0..sh.to_len], user);
        if (owned or taken) {
            if (sh.cap != 0) _ = usys.capDrop(sh.cap);
            sh.* = .{};
        }
    }
}

/// The protocol's login: name and passphrase from the client's buffer.
fn login(name_w: u64, pass_w: u64) shared.SessResp {
    const name_src = clientSlice(0, name_w) orelse return .denied;
    const pass_src = clientSlice(0, pass_w) orelse return .denied;
    var pass: [256]u8 = undefined;
    defer @memset(&pass, 0);
    @memcpy(pass[0..pass_src.len], pass_src);
    @memset(pass_src, 0); // the passphrase now lives only here
    return authenticate(name_src, pass[0..pass_src.len], 0);
}

/// Authenticate and open a session (with `console`, an init instance
/// on that console; without, the session program). Caller holds the lock.
fn authenticate(name_src: []const u8, phrase: []const u8, console: u64) shared.SessResp {
    var name_buf: [max_name]u8 = undefined;
    if (!nameOk(name_src)) return refuse("usersvc: login refused (bad name)");
    @memcpy(name_buf[0..name_src.len], name_src);
    const name = name_buf[0..name_src.len];

    var slot: usize = 0;
    while (slot < max_sessions and sessions[slot].used) slot += 1;
    if (slot == max_sessions) return .{ .sess_err = .{ .code = 3 } };

    var budget: Budget = .{};
    const rec = readRecord(name, &budget) orelse (if (fab_chan != 0 and fetchRecord(name)) readRecord(name, &budget) else null) orelse return refuse("usersvc: login refused");
    var fba = std.heap.FixedBufferAllocator.init(&kdf_heap);
    const kp = usercred.unlock(fba.allocator(), &rec, phrase) catch return refuse("usersvc: login refused");
    // One server per home: a home leased to a session elsewhere, or
    // already open here, is not opened again.
    if (leaseHeld(name) or sessionOpen(name)) {
        logName("usersvc: login refused: the home is in use for ", name);
        return .{ .sess_err = .{ .code = 6 } };
    }

    const s = &sessions[slot];
    s.* = .{ .used = true, .kp = kp, .name_len = name.len, .home_node = budget.home_node };
    @memcpy(s.name[0..name.len], name);
    if (!spawnSession(s, budget, console)) {
        releaseHome(s);
        @memset(std.mem.asBytes(&s.kp), 0);
        s.* = .{};
        return .{ .sess_err = .{ .code = 4 } };
    }
    logName("usersvc: session opened for ", name);
    return .{ .session = .{ .sid = slot } };
}

/// One answer for every refusal, after a pause: the reply never says
/// whether the name or the passphrase was wrong, and guessing is slow.
// -------------------------------------------------------------- the pool
//
// A user is the same identity on every node: the record (a public key
// and a seed sealed under the passphrase) is safe to copy anywhere, so
// a login on a node without it fetches it from a member that has it,
// caches it (remembering which node has the home), and unseals locally.
// The home stays where it was born: a session elsewhere leases its
// ciphertext directory through the fabric and serves the volume itself,
// so the key never leaves the session's node and the home's node ships
// only ciphertext.

/// Publish our channel to the pool under ServiceId.usersvc: a badged
/// copy, so requests from the wire are known for what they are.
fn joinPool() void {
    const s = usys.shmCreate(1);
    if (s.err != .ok) return;
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) return;
    fab_buf = @ptrFromInt(m.data[0]);
    switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .attach_buf, s.data[0])) {
        .ok => {},
        .err => return,
    }
    const minted = usys.chanMint(svc_chan, remote_badge);
    if (minted.err != .ok) return;
    switch (usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .{ .publish = .{ .service = @intFromEnum(shared.ServiceId.usersvc) } }, minted.data[1])) {
        .ok => |rep| {
            if (rep == .ok) _ = usys.log(glog, "usersvc: published to the pool");
        },
        .err => {},
    }
    _ = usys.capDrop(minted.data[1]);
}

/// A member's request for a record: 24 bytes per chunk from the file.
fn doRecord(name_a: u64, name_b: u64, chunk: u64) shared.SessResp {
    var name_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, name_bytes[0..8], name_a, .little);
    std.mem.writeInt(u64, name_bytes[8..16], name_b, .little);
    var n: usize = 0;
    while (n < 16 and name_bytes[n] != 0) n += 1;
    const name = name_bytes[0..n];
    if (!nameOk(name)) return .denied;
    var path: [max_name + 4]u8 = undefined;
    @memcpy(path[0..name.len], name);
    @memcpy(path[name.len .. name.len + 4], ".msh");
    var text: [1024]u8 = undefined;
    const rec = readInto(users_view, users_buf, path[0 .. name.len + 4], &text) orelse return .denied;
    const off = chunk * 24;
    if (off >= rec.len) return .{ .data = .{ .len = rec.len } };
    var bytes: [24]u8 = @splat(0);
    const k = @min(24, rec.len - off);
    @memcpy(bytes[0..k], rec[off .. off + k]);
    return .{ .chunk = .{
        .a = std.mem.readInt(u64, bytes[0..8], .little),
        .b = std.mem.readInt(u64, bytes[8..16], .little),
        .c = std.mem.readInt(u64, bytes[16..24], .little),
    } };
}

/// Ask every live member (not ourselves) for the record; the first to
/// have it wins, and the record is cached in conf/users here.
fn fetchRecord(name: []const u8) bool {
    const mres = usys.callTyped(shared.FabReq, shared.FabResp, fab_chan, .members, 0);
    const count: u64 = switch (mres) {
        .ok => |rep| if (rep == .num) rep.num.n else 0,
        .err => 0,
    };
    var i: u64 = 0;
    while (i < count and i < 16) : (i += 1) {
        const rec = fab_buf[i * shared.fab_member_size .. (i + 1) * shared.fab_member_size];
        const node: u64 = std.mem.readInt(u16, rec[0..2], .little);
        const up = rec[2] != 0;
        const self = rec[3] != 0;
        if (!up or self) continue;
        if (fetchFrom(node, name)) return true;
    }
    return false;
}

fn fetchFrom(node: u64, name: []const u8) bool {
    const lres = usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{ .lookup = .{ .node = node, .service = @intFromEnum(shared.ServiceId.usersvc) } }, 0);
    const chan: u64 = switch (lres) {
        .ok => |ok| if (ok.rep == .found and ok.cap != 0) ok.cap else return false,
        .err => return false,
    };
    defer _ = usys.capDrop(chan);
    const w = shared.strToWords(name);
    var text: [1024]u8 = undefined;
    var len: usize = 0;
    var chunk: u64 = 0;
    while (chunk < 48) : (chunk += 1) {
        switch (usys.callTyped(shared.SessReq, shared.SessResp, chan, .{ .record = .{ .name_a = w[0], .name_b = w[1], .chunk = chunk } }, 0)) {
            .ok => |rep| switch (rep) {
                .chunk => |c| {
                    if (len + 24 > text.len) return false;
                    std.mem.writeInt(u64, text[len..][0..8], c.a, .little);
                    std.mem.writeInt(u64, text[len + 8 ..][0..8], c.b, .little);
                    std.mem.writeInt(u64, text[len + 16 ..][0..8], c.c, .little);
                    len += 24;
                },
                .data => |d| {
                    if (d.len > len or d.len > text.len) return false;
                    var path: [max_name + 4]u8 = undefined;
                    @memcpy(path[0..name.len], name);
                    @memcpy(path[name.len .. name.len + 4], ".msh");
                    // The cached copy remembers where the home lives: the
                    // record's closing brace gains `home: <node>`.
                    var end = d.len;
                    while (end > 0 and (text[end - 1] == ' ' or text[end - 1] == '\n' or text[end - 1] == '\r')) end -= 1;
                    if (end == 0 or text[end - 1] != '}' or end + 24 > text.len) return false;
                    var nb2: [24]u8 = undefined;
                    const tail = cat3(text[end - 1 ..], ", home: ", decimal(&nb2, node), " }\n", "", "");
                    const total = end - 1 + tail.len;
                    if (!writeFile(users_view, users_buf, path[0 .. name.len + 4], text[0..total])) return false;
                    _ = fsc.fsSync(users_view);
                    var line: [96]u8 = undefined;
                    var nb: [24]u8 = undefined;
                    _ = usys.log(glog, cat3(&line, "usersvc: record for ", name, " fetched from node ", decimal(&nb, node), ""));
                    return true;
                },
                else => return false,
            },
            .err => return false,
        }
    }
    return false;
}

fn refuse(msg: []const u8) shared.SessResp {
    usys.sleep(20);
    _ = usys.log(glog, msg);
    return .denied;
}

/// `<name>.msh` through the records view, parsed as data.
fn readRecord(name: []const u8, budget: *Budget) ?usercred.Record {
    var path: [max_name + 4]u8 = undefined;
    @memcpy(path[0..name.len], name);
    @memcpy(path[name.len .. name.len + 4], ".msh");
    var text: [2048]u8 = undefined;
    const n = readFile(users_view, users_buf, path[0 .. name.len + 4], &text) orelse return null;
    var fba = std.heap.FixedBufferAllocator.init(&text_heap);
    var interp = mshl.Interp.init(fba.allocator(), fba.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = noHost });
    const v = interp.parseData(text[0..n]) catch return null;
    if (v != .record) return null;
    const r = v.record;
    var rec: usercred.Record = .{ .pk = undefined, .salt = undefined, .sealed = undefined, .kdf = .{} };
    _ = usercred.hexDecode(&rec.pk, str(r.get("key")) orelse return null) orelse return null;
    _ = usercred.hexDecode(&rec.salt, str(r.get("salt")) orelse return null) orelse return null;
    _ = usercred.hexDecode(&rec.sealed, str(r.get("sealed")) orelse return null) orelse return null;
    if (r.get("kdf")) |k| {
        if (k != .record) return null;
        rec.kdf.ln = @intCast(@min(int(k.record.get("ln")) orelse 12, 63));
        rec.kdf.r = @intCast(@max(int(k.record.get("r")) orelse 8, 1));
        rec.kdf.p = @intCast(@max(int(k.record.get("p")) orelse 1, 1));
    }
    if (rec.kdf.memoryBytes() + (64 << 10) > kdf_heap_len) return null; // a cost this custodian cannot pay
    if (r.get("budget")) |b| {
        if (b == .record) {
            if (int(b.record.get("kobj"))) |x| budget.kobj_kb = @intCast(@divTrunc(x, 1024));
            if (int(b.record.get("user"))) |x| budget.user_kb = @intCast(@divTrunc(x, 1024));
            if (int(b.record.get("cpu"))) |x| budget.cpu_permille = @intCast(@max(x, 0));
        }
    }
    if (int(r.get("home"))) |h| budget.home_node = @intCast(@max(h, 0));
    return rec;
}

/// The session, under the record's budgets, handed a rw view of
/// home/<name>, the settings layer and its name: on a console, an init
/// instance (mode 3) that runs the session's units with that console;
/// otherwise the session program (role 3).
fn spawnSession(s: *Session, budget: Budget, console: u64) bool {
    const name = s.name[0..s.name_len];
    // The home's backing: home/<name> on this node's volume, or, for a
    // home that lives on another node, its ciphertext directory there,
    // reached through a lease — the key stays here either way.
    const backing = if (s.home_node != 0) mountRemoteHome(s) else localHomeDir(name);
    const voldir = backing orelse return false;
    const view = openHome(s, voldir) orelse {
        _ = usys.capDrop(voldir);
        return false;
    };
    _ = usys.capDrop(voldir);
    defer _ = usys.capDrop(view); // the session's copy is the only one left
    const image: shared.ImageId = if (console != 0) .init else .users;
    const arg: u64 = 3;
    var flags: u64 = shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a;
    if (console != 0) flags |= shared.SpawnFlags.grant_spawner | shared.SpawnFlags.grant_bootfs;
    if (!stage.load(blob_va, blob_len, image)) return false;
    const ch = usys.chanCreate();
    if (ch.err != .ok) return false;
    const r = usys.spawnCpu(spawner, stage.handle, arg, ch.data[0], flags, usys.kbLimits(budget.kobj_kb, budget.user_kb), usys.cpuBudget(budget.cpu_permille, 0));
    _ = usys.capDrop(ch.data[0]);
    if (r.err != .ok) {
        _ = usys.capDrop(ch.data[1]);
        return false;
    }
    s.ctl = r.data[0];
    const b = ch.data[1];
    defer _ = usys.capDrop(b);
    const w = shared.strToWords(name);
    // The settings layer and the system store are views of the session's
    // own — derived per session, never copies of ours: a view's badge
    // carries one attached buffer on the service, so two sessions on
    // one badge would trample each other's, and a dead session's would
    // linger until the badge died with us.
    const conf_view = fsc.fsDerive(app_view, app_buf, "", true) orelse return false;
    defer _ = usys.capDrop(conf_view);
    const sess_store: u64 = if (store_view != 0) (fsc.fsDerive(store_view, store_buf, "", true) orelse return false) else 0;
    defer if (sess_store != 0) {
        _ = usys.capDrop(sess_store);
    };
    var ok = boot.giveCap(b, .view, view) and boot.giveCap(b, .conf, conf_view);
    if (ok and sess_store != 0) ok = boot.giveCap(b, .store, sess_store);
    // The session's own channel to us, badged with its slot: sharing
    // requests name their caller by badge, never by a word they send.
    if (ok) {
        const sid = (@intFromPtr(s) - @intFromPtr(&sessions[0])) / @sizeOf(Session);
        const minted = usys.chanMint(svc_chan, sid + 1);
        ok = minted.err == .ok and boot.giveCap(b, .sess, minted.data[1]);
        if (minted.err == .ok) _ = usys.capDrop(minted.data[1]);
    }
    if (ok and console != 0) ok = boot.giveCap(b, .console, console);
    if (ok) ok = boot.give(b, .{ .arg = .{ .a = w[0], .b = w[1], .c = w[2] } }, 0) and boot.give(b, .go, 0);
    if (!ok) {
        _ = usys.domainDestroy(s.ctl);
        _ = usys.capDrop(s.ctl);
        return false;
    }
    return true;
}

/// The user's home volume: a mossfs volume in `home/<name>/vol` on the
/// system volume, served by a home filesystem service spawned for this
/// session and keyed from the unlocked identity. Returns the session's
/// root view of it. The system volume only ever sees ciphertext.
fn localHomeDir(name: []const u8) ?u64 {
    if (!fsc.fsMkdir(home_view, home_buf, name)) return null;
    return fsc.fsDerive(home_view, home_buf, name, false);
}

/// The lease dance with the manager that holds the home (see SessReq):
/// look it up, take the challenge and the lease cap, prove the identity
/// with a signature through the lease's buffer, and get the ciphertext
/// directory's view back. The lease cap stays with the session.
fn mountRemoteHome(s: *Session) ?u64 {
    const name = s.name[0..s.name_len];
    var nb: [24]u8 = undefined;
    var line: [96]u8 = undefined;
    if (fab_chan == 0) return null;
    const lres = usys.callTypedCap(shared.FabReq, shared.FabResp, fab_chan, .{ .lookup = .{ .node = s.home_node, .service = @intFromEnum(shared.ServiceId.usersvc) } }, 0);
    const mgr: u64 = switch (lres) {
        .ok => |ok| if (ok.rep == .found and ok.cap != 0) ok.cap else {
            _ = usys.log(glog, cat3(&line, "usersvc: the home of ", name, " lives on node ", decimal(&nb, s.home_node), ", which is not reachable"));
            return null;
        },
        .err => return null,
    };
    defer _ = usys.capDrop(mgr);
    const w = shared.strToWords(name);
    // The challenge, and the lease cap that carries the proof.
    const cres = usys.callTypedCap(shared.SessReq, shared.SessResp, mgr, .{ .home_challenge = .{ .name_a = w[0], .name_b = w[1] } }, 0);
    var nonce: [24]u8 = undefined;
    const lease: u64 = switch (cres) {
        .ok => |ok| switch (ok.rep) {
            .chunk => |c| blk: {
                std.mem.writeInt(u64, nonce[0..8], c.a, .little);
                std.mem.writeInt(u64, nonce[8..16], c.b, .little);
                std.mem.writeInt(u64, nonce[16..24], c.c, .little);
                break :blk ok.cap;
            },
            .sess_err => |e| {
                if (e.code == 6) _ = usys.log(glog, cat3(&line, "usersvc: the home of ", name, " is in use on node ", decimal(&nb, s.home_node), ""));
                if (ok.cap != 0) _ = usys.capDrop(ok.cap);
                return null;
            },
            else => {
                if (ok.cap != 0) _ = usys.capDrop(ok.cap);
                return null;
            },
        },
        .err => return null,
    };
    if (lease == 0) return null;
    errdefer _ = usys.capDrop(lease);
    // The proof travels through a buffer on the lease (the bulk
    // transport carries it): the identity's signature over the nonce.
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) {
        _ = usys.capDrop(lease);
        return null;
    }
    defer _ = usys.capDrop(sh.data[0]);
    const m = usys.shmMap(sh.data[0]);
    if (m.err != .ok) {
        _ = usys.capDrop(lease);
        return null;
    }
    defer _ = usys.shmUnmap(m.data[0]);
    switch (usys.callTyped(shared.SessReq, shared.SessResp, lease, .attach_buf, sh.data[0])) {
        .ok => |rep| if (rep != .ok) {
            _ = usys.capDrop(lease);
            return null;
        },
        .err => {
            _ = usys.capDrop(lease);
            return null;
        },
    }
    const sig = fabcert.signLabeled(s.kp, shared.home_lease_label, &nonce) catch {
        _ = usys.capDrop(lease);
        return null;
    };
    const dst: [*]u8 = @ptrFromInt(m.data[0]);
    @memcpy(dst[0..64], &sig);
    const vres = usys.callTypedCap(shared.SessReq, shared.SessResp, lease, .{ .home_lease = .{ .sig_off = 0 } }, 0);
    const view: u64 = switch (vres) {
        .ok => |ok| if (ok.rep == .ok and ok.cap != 0) ok.cap else {
            if (ok.cap != 0) _ = usys.capDrop(ok.cap);
            _ = usys.capDrop(lease);
            return null;
        },
        .err => {
            _ = usys.capDrop(lease);
            return null;
        },
    };
    s.lease = lease;
    _ = usys.log(glog, cat3(&line, "usersvc: the home of ", name, " mounted from node ", decimal(&nb, s.home_node), " (the key stays here)"));
    return view;
}

/// The holder's side of a lease: the challenge (a lease slot and its
/// badged cap are born here, so the proof can arrive on it).
fn doHomeChallenge(name_a: u64, name_b: u64) void {
    var name_bytes: [16]u8 = undefined;
    std.mem.writeInt(u64, name_bytes[0..8], name_a, .little);
    std.mem.writeInt(u64, name_bytes[8..16], name_b, .little);
    var n: usize = 0;
    while (n < 16 and name_bytes[n] != 0) n += 1;
    const name = name_bytes[0..n];
    if (!nameOk(name)) return reply(.denied);
    var budget: Budget = .{};
    if (readRecord(name, &budget) == null) return reply(.denied);
    if (leaseHeld(name) or sessionOpen(name)) {
        logName("usersvc: lease refused, the home is in use: ", name);
        return reply(.{ .sess_err = .{ .code = 6 } });
    }
    var slot: usize = 0;
    while (slot < max_leases and leases[slot].used) slot += 1;
    if (slot == max_leases) return reply(.{ .sess_err = .{ .code = 3 } });
    const l = &leases[slot];
    l.* = .{ .used = true, .name_len = name.len };
    @memcpy(l.name[0..name.len], name);
    if (usys.getrandom(&l.nonce) != .ok) {
        l.* = .{};
        return reply(.{ .sess_err = .{ .code = 4 } });
    }
    const minted = usys.chanMint(svc_chan, lease_badge0 + slot);
    if (minted.err != .ok) {
        l.* = .{};
        return reply(.{ .sess_err = .{ .code = 3 } });
    }
    _ = usys.replyTyped(shared.SessResp, svc_chan, .{ .chunk = .{
        .a = std.mem.readInt(u64, l.nonce[0..8], .little),
        .b = std.mem.readInt(u64, l.nonce[8..16], .little),
        .c = std.mem.readInt(u64, l.nonce[16..24], .little),
    } }, minted.data[1]);
    _ = usys.capDrop(minted.data[1]);
}

/// The proof on a lease cap: the signature at buf[sig_off..+64] under
/// the record's public key. Verified, the lease is held and the home's
/// ciphertext directory goes out as a rw view.
fn doHomeLease(badge: u64, sig_off: u64) void {
    const l = leaseOf(badge) orelse return reply(.{ .sess_err = .{ .code = 5 } });
    const name = l.name[0..l.name_len];
    if (l.held) return reply(.{ .sess_err = .{ .code = 6 } });
    const cb = client_bufs[badge];
    if (cb.va == 0 or sig_off + 64 > cb.pages * 4096) return reply(.{ .sess_err = .{ .code = 7 } });
    var budget: Budget = .{};
    const rec = readRecord(name, &budget) orelse return reply(.denied);
    const sig = @as([*]const u8, @ptrFromInt(cb.va))[sig_off .. sig_off + 64];
    fabcert.verifyLabeled(rec.pk, shared.home_lease_label, &l.nonce, sig) catch {
        logName("usersvc: lease refused, bad proof for ", name);
        return reply(.{ .sess_err = .{ .code = 7 } });
    };
    if (leaseHeld(name) or sessionOpen(name)) return reply(.{ .sess_err = .{ .code = 6 } });
    const dir = localHomeDir(name) orelse return reply(.{ .sess_err = .{ .code = 4 } });
    l.held = true;
    @memset(&l.nonce, 0);
    logName("usersvc: home leased to a session on another node: ", name);
    _ = usys.replyTyped(shared.SessResp, svc_chan, .ok, dir);
    _ = usys.capDrop(dir);
}

/// The home service over `voldir` (the ciphertext directory, local or
/// remote), keyed from the unlocked identity. Returns the session's
/// root view of the volume; `voldir` stays the caller's to drop.
fn openHome(s: *Session, voldir: u64) ?u64 {
    // The service's root-view buffer, shared with us: the key is staged
    // through it, and derive requests travel through it.
    const sh = usys.shmCreate(1);
    if (sh.err != .ok) return null;
    const sm = usys.shmMap(sh.data[0]);
    if (sm.err != .ok) return null;
    s.fs_buf_h = sh.data[0];
    s.fs_buf_va = sm.data[0];
    const fbuf: [*]u8 = @ptrFromInt(sm.data[0]);
    if (!stage.load(blob_va, blob_len, .fs)) return null;
    const ch = usys.chanCreate();
    if (ch.err != .ok) return null;
    const r = usys.spawn(spawner, stage.handle, 4, ch.data[0], shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a, usys.kbLimits(1 << 10, 4 << 10));
    _ = usys.capDrop(ch.data[0]);
    if (r.err != .ok) {
        _ = usys.capDrop(ch.data[1]);
        return null;
    }
    s.fs_ctl = r.data[0];
    const b = ch.data[1];
    s.fs_chan = b; // kept for the logout sync
    var key = usercred.homeKey(s.kp);
    defer @memset(&key, 0);
    var ok = boot.giveCap(b, .buf, s.fs_buf_h);
    if (ok) {
        const dst: [*]volatile u8 = @ptrFromInt(sm.data[0]);
        for (key, 0..) |kb, i| dst[i] = kb;
        ok = boot.give(b, .{ .secret = .{ .off = 0, .len = 32 } }, 0);
        for (0..32) |i| dst[i] = 0;
    }
    if (ok) ok = boot.giveCap(b, .view, voldir) and boot.give(b, .go, 0);
    if (!ok) return null;
    // The session's view of its own home: the volume's root.
    return fsc.fsDerive(b, fbuf, "", false);
}

// --------------------------------------------------------------- consoles
//
// Console login: one thread per console the manager was handed, each
// running prompt, passphrase, session, wait, prompt again. While a
// session is open the console is its shell's; the thread only watches
// the session's domain.

const max_consoles = boot.max_index;
var console_caps: [max_consoles]u64 = @splat(0);
var console_stacks: [max_consoles][32 << 10]u8 align(16) = undefined;
var console_done: [max_consoles]bool = @splat(false);
var ncons: usize = 0;
var login_drill = false;
var svc_lock = std.atomic.Value(bool).init(false);

fn lock() void {
    while (svc_lock.swap(true, .acquire)) usys.yield();
}

fn unlock() void {
    svc_lock.store(false, .release);
}

const Console = struct {
    chan: u64,
    shm_h: u64,
    buf: [*]volatile u8,

    /// (Re)bind our byte buffer: a shell that had the console bound its own.
    fn bind(c: *Console) void {
        _ = usys.callTyped(shared.ConsReq, shared.ConsResp, c.chan, .setup, c.shm_h);
    }

    fn write(c: *Console, s: []const u8) void {
        var off: usize = 0;
        while (off < s.len) {
            const chunk = @min(s.len - off, 2048);
            for (0..chunk) |i| c.buf[i] = s[off + i];
            _ = usys.callTyped(shared.ConsReq, shared.ConsResp, c.chan, .{ .write = .{ .len = chunk } }, 0);
            off += chunk;
        }
    }

    /// A line, with backspace; echoed only when asked (never a passphrase).
    fn readLine(c: *Console, out: []u8, echo: bool) usize {
        var n: usize = 0;
        while (true) {
            const got = switch (usys.callTyped(shared.ConsReq, shared.ConsResp, c.chan, .{ .read = .{ .max = 64 } }, 0)) {
                .ok => |rep| switch (rep) {
                    .n => |x| x.n,
                    else => return n,
                },
                .err => return n,
            };
            for (0..got) |i| {
                const b = c.buf[i];
                if (b == '\r' or b == '\n') return n;
                if (b == 0x7f or b == 0x08) {
                    if (n > 0) {
                        n -= 1;
                        if (echo) c.write("\x08 \x08");
                    }
                } else if (n < out.len and b >= 0x20) {
                    out[n] = b;
                    n += 1;
                    if (echo) c.write(&[_]u8{b});
                }
            }
        }
    }
};

fn consoleThread(i: u64) callconv(.c) void {
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(184);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(185);
    var c: Console = .{ .chan = console_caps[i], .shm_h = s.data[0], .buf = @ptrFromInt(m.data[0]) };
    while (true) {
        c.bind();
        c.write("\r\nmoss login: ");
        var name: [64]u8 = undefined;
        const nl = c.readLine(&name, true);
        c.write("\r\npassphrase: ");
        var pass: [256]u8 = undefined;
        const pl = c.readLine(&pass, false);
        c.write("\r\n");
        lock();
        const res = authenticate(name[0..nl], pass[0..pl], c.chan);
        unlock();
        @memset(&pass, 0);
        switch (res) {
            .session => |x| {
                // The console is the session's shell's now; watch the domain.
                lock();
                const ctl = if (sessionOf(x.sid)) |sess| sess.ctl else 0;
                unlock();
                while (ctl != 0) {
                    const st = usys.domainStat(ctl);
                    if (st.err != .ok or st.data[0] == @intFromEnum(shared.DomainState.dead)) break;
                    usys.sleep(5);
                }
                lock();
                if (sessionOf(x.sid)) |sess| close(sess);
                console_done[i] = true;
                unlock();
                if (login_drill) maybeFinish();
            },
            else => c.write("login refused\r\n"),
        }
    }
}

/// The login drill's end: every console has had a session, none is open.
fn maybeFinish() void {
    lock();
    defer unlock();
    for (console_done[0..ncons]) |d| if (!d) return;
    for (sessions) |s| if (s.used) return;
    _ = usys.log(glog, "usersvc: every console had its session and logged out; drill done");
    usys.exit(0);
}

// ------------------------------------------------------------------ apply
//
// The desired-state tool. `conf/system.msh` — the volume's copy, else
// the archive's — says which users exist (with a bootstrap passphrase
// and budgets) and what the system settings layer holds; apply makes
// it so, idempotently: a user with a record is kept as is (nothing
// here can change a passphrase), a settings file is rewritten only
// when it differs. Every action is a row of the value it returns to
// the shell: { kind, name, action }.

var apply_heap: [96 << 10]u8 = undefined;

fn apply(chan_h: u64) noreturn {
    const setup = boot.take(chan_h);
    const cv = setup.cap(.view); // conf/, read-write
    if (cv == 0) usys.exit(190);
    const cbuf: [*]u8 = @ptrFromInt(fsc.attachBuf(cv).va);

    var text_buf: [8192]u8 = undefined;
    const text = readInto(cv, cbuf, "system.msh", &text_buf) orelse
        (shared.marcFind(@as([*]const u8, @ptrFromInt(blob_va))[0..blob_len], "conf/system.msh") orelse {
            _ = usys.log(glog, "apply: no desired state: neither conf/system.msh nor the archive's");
            usys.exit(198);
        });
    var fba = std.heap.FixedBufferAllocator.init(&apply_heap);
    const a = fba.allocator();
    var interp = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&host_ctx), .call = noHost });
    const desired = interp.parseData(text) catch {
        _ = usys.log(glog, "apply: conf/system.msh does not parse");
        usys.exit(196);
    };
    if (desired != .record) usys.exit(196);

    var res = result.Result.init();
    var rows: std.ArrayList([]const Value) = .empty;
    var created: u64 = 0;
    var written: u64 = 0;

    if (desired.record.get("users")) |users| {
        if (users != .list) usys.exit(196);
        _ = fsc.fsMkdir(cv, cbuf, "users");
        for (users.list) |u| {
            if (u != .record) continue;
            const name = str(u.record.get("name")) orelse continue;
            if (!nameOk(name)) {
                logName("apply: bad user name: ", name);
                continue;
            }
            var path: [max_name + 10]u8 = undefined;
            const p = cat3(&path, "users/", name, ".msh", "", "");
            if (fsc.fsStat(cv, cbuf, p) != null) {
                row(&res, &rows, "user", name, "kept");
                continue;
            }
            const pass = str(u.record.get("passphrase")) orelse {
                logName("apply: no passphrase to create a record for ", name);
                row(&res, &rows, "user", name, "no passphrase");
                continue;
            };
            var kdf: usercred.Kdf = .{ .ln = 11 };
            if (u.record.get("kdf")) |k| {
                if (k == .record) {
                    if (int(k.record.get("ln"))) |ln| kdf.ln = @intCast(@min(@max(ln, 1), 63));
                    if (int(k.record.get("r"))) |r| kdf.r = @intCast(@max(r, 1));
                    if (int(k.record.get("p"))) |pp| kdf.p = @intCast(@max(pp, 1));
                }
            }
            if (kdf.memoryBytes() + (64 << 10) > kdf_heap_len) {
                logName("apply: kdf cost beyond this tool's memory for ", name);
                row(&res, &rows, "user", name, "kdf too costly");
                continue;
            }
            var budget: Budget = .{ .kobj_kb = 2 << 10, .user_kb = 12 << 10, .cpu_permille = 500 };
            if (u.record.get("budget")) |b| {
                if (b == .record) {
                    if (int(b.record.get("kobj"))) |x| budget.kobj_kb = @intCast(@max(@divTrunc(x, 1024), 0));
                    if (int(b.record.get("user"))) |x| budget.user_kb = @intCast(@max(@divTrunc(x, 1024), 0));
                    if (int(b.record.get("cpu"))) |x| budget.cpu_permille = @intCast(@max(x, 0));
                }
            }
            var seed: [usercred.seed_len]u8 = undefined;
            var salt: [usercred.salt_len]u8 = undefined;
            randomOrDie(&seed);
            randomOrDie(&salt);
            var kfba = std.heap.FixedBufferAllocator.init(&kdf_heap);
            const rec = usercred.create(kfba.allocator(), &seed, &salt, pass, kdf) catch {
                @memset(&seed, 0);
                usys.exit(191);
            };
            @memset(&seed, 0);
            var rtext: [1024]u8 = undefined;
            const rendered = renderRecord(&rtext, rec, budget);
            if (!writeFile(cv, cbuf, p, rendered)) usys.exit(192);
            var line: [96]u8 = undefined;
            var hex: [16]u8 = undefined;
            _ = usys.log(glog, cat3(&line, "apply: created user ", name, " (key ", usercred.hexEncode(&hex, rec.pk[0..8]), "...)"));
            row(&res, &rows, "user", name, "created");
            created += 1;
        }
    }

    if (desired.record.get("settings")) |wanted| {
        if (wanted != .record) usys.exit(196);
        _ = fsc.fsMkdir(cv, cbuf, "app");
        for (wanted.record.keys, wanted.record.vals) |key, val| {
            if (!nameOk(key)) continue;
            var out: std.ArrayList(u8) = .empty;
            mshl.writeData(val, a, &out) catch usys.exit(196);
            out.append(a, '\n') catch usys.exit(196);
            var path: [max_name + 10]u8 = undefined;
            const p = cat3(&path, "app/", key, ".msh", "", "");
            var cur: [4096]u8 = undefined;
            if (readInto(cv, cbuf, p, &cur)) |existing| {
                if (std.mem.eql(u8, existing, out.items)) {
                    row(&res, &rows, "settings", key, "kept");
                    continue;
                }
            }
            if (!writeFile(cv, cbuf, p, out.items)) usys.exit(193);
            logName("apply: settings written: ", key);
            row(&res, &rows, "settings", key, "written");
            written += 1;
        }
    }

    if (!fsc.fsSync(cv)) usys.exit(194);
    var line: [96]u8 = undefined;
    var nb: [24]u8 = undefined;
    var nb2: [24]u8 = undefined;
    _ = usys.log(glog, cat3(&line, "apply: done: users created ", decimal(&nb, created), ", settings written ", decimal(&nb2, written), ""));
    _ = res.deliver(&setup, .{ .table = .{ .cols = &.{ "kind", "name", "action" }, .rows = rows.items } });
    usys.exit(0);
}

fn row(res: *result.Result, rows: *std.ArrayList([]const Value), kind: []const u8, name: []const u8, action: []const u8) void {
    const a = res.allocator();
    const r = a.alloc(Value, 3) catch usys.exit(197);
    r[0] = .{ .str = kind };
    r[1] = .{ .str = a.dupe(u8, name) catch usys.exit(197) };
    r[2] = .{ .str = action };
    rows.append(a, r) catch usys.exit(197);
}

fn decimal(out: *[24]u8, v: u64) []const u8 {
    var tmp: [24]u8 = undefined;
    var n: usize = 0;
    var x = v;
    if (x == 0) {
        out[0] = '0';
        return out[0..1];
    }
    while (x > 0) : (x /= 10) {
        tmp[n] = @intCast('0' + x % 10);
        n += 1;
    }
    for (0..n) |i| out[i] = tmp[n - 1 - i];
    return out[0..n];
}

/// A whole file into `buf`, or null when it is absent or too big.
fn readInto(view: u64, vbuf: [*]u8, path: []const u8, buf: []u8) ?[]const u8 {
    const fd = switch (fsc.fsOpen(view, vbuf, path, 0)) {
        .fd => |fd| fd,
        .err => return null,
    };
    defer fsc.fsClose(view, fd);
    var off: usize = 0;
    while (off < buf.len) {
        const n = fsc.fsReadAt(view, fd, off, @min(shared.fs_max_io, buf.len - off)) orelse return null;
        if (n == 0) break;
        @memcpy(buf[off .. off + n], vbuf[0..n]);
        off += n;
    }
    if (off == buf.len) return null;
    return buf[0..off];
}

fn randomOrDie(out: []u8) void {
    var tries: usize = 0;
    while (usys.getrandom(out) != .ok) : (tries += 1) {
        if (tries == 100) usys.exit(195); // the pool never seeded
        usys.sleep(1);
    }
}

/// A record as data: the same syntax as a unit file, hex for the bytes.
fn renderRecord(out: *[1024]u8, rec: usercred.Record, budget: Budget) []const u8 {
    var n: usize = 0;
    var hex: [2 * usercred.sealed_len]u8 = undefined;
    n = putStr(out, n, "{ key: \"");
    n = putStr(out, n, usercred.hexEncode(&hex, &rec.pk));
    n = putStr(out, n, "\", salt: \"");
    n = putStr(out, n, usercred.hexEncode(&hex, &rec.salt));
    n = putStr(out, n, "\", sealed: \"");
    n = putStr(out, n, usercred.hexEncode(&hex, &rec.sealed));
    n = putStr(out, n, "\",\n  kdf: { ln: ");
    n = putNum(out, n, rec.kdf.ln);
    n = putStr(out, n, ", r: ");
    n = putNum(out, n, rec.kdf.r);
    n = putStr(out, n, ", p: ");
    n = putNum(out, n, rec.kdf.p);
    n = putStr(out, n, " },\n  budget: { kobj: ");
    n = putNum(out, n, budget.kobj_kb);
    n = putStr(out, n, "kb, user: ");
    n = putNum(out, n, budget.user_kb);
    n = putStr(out, n, "kb, cpu: ");
    n = putNum(out, n, budget.cpu_permille);
    n = putStr(out, n, " } }\n");
    return out[0..n];
}

// ---------------------------------------------------------------- session

const editor_locked = [_][]const u8{"telemetry"};

fn session(chan_h: u64) noreturn {
    const setup = boot.take(chan_h);
    const name = setup.arg();
    const home = setup.cap(.view);
    const conf = setup.cap(.conf);
    if (home == 0 or conf == 0 or name.len == 0) usys.exit(160);
    const hbuf: [*]u8 = @ptrFromInt(fsc.attachBuf(home).va);
    const cbuf: [*]u8 = @ptrFromInt(fsc.attachBuf(conf).va);
    var line: [160]u8 = undefined;

    // Work in the home — and notice earlier work: the volume persists
    // across sessions, opened each time with the key the login derives.
    switch (fsc.fsOpen(home, hbuf, "notes/secret.txt", 0)) {
        .fd => |fd| {
            fsc.fsClose(home, fd);
            _ = usys.log(glog, cat3(&line, "session(", name, "): earlier work found: the home persisted across sessions", "", ""));
        },
        .err => {},
    }
    if (!fsc.fsMkdir(home, hbuf, "notes")) usys.exit(161);
    var secret: [64]u8 = undefined;
    const secret_text = cat3(&secret, name, "'s secret", "", "", "");
    if (!writeFile(home, hbuf, "notes/secret.txt", secret_text)) usys.exit(162);

    // Nothing above the home has a name here: the credential store, the
    // other homes, the system settings are unreachable, not forbidden.
    switch (fsc.fsOpen(home, hbuf, "../bob/notes/secret.txt", 0)) {
        .fd => usys.exit(163),
        .err => |e| if (e != .bad_path) usys.exit(164),
    }
    switch (fsc.fsOpen(home, hbuf, "conf/users/alice.msh", 0)) {
        .fd => usys.exit(165),
        .err => |e| if (e != .not_found) usys.exit(166),
    }
    _ = usys.log(glog, cat3(&line, "session(", name, "): nothing above the home is nameable (bad_path), the credential store is not here (not_found)", "", ""));

    // Settings: the system layer through the conf view, the user layer
    // in the home — this user turns telemetry on and picks a theme; the
    // schema locks telemetry, so only the theme takes.
    if (!fsc.fsMkdir(home, hbuf, "conf")) usys.exit(167);
    if (!writeFile(home, hbuf, "conf/editor.msh", "{ theme: light, telemetry: true }\n")) usys.exit(168);
    var sys_text: [512]u8 = undefined;
    var usr_text: [512]u8 = undefined;
    const sn = readFile(conf, cbuf, "editor.msh", &sys_text) orelse usys.exit(169);
    const un = readFile(home, hbuf, "conf/editor.msh", &usr_text) orelse usys.exit(170);
    var fba = std.heap.FixedBufferAllocator.init(&text_heap);
    var interp = mshl.Interp.init(fba.allocator(), fba.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = noHost });
    const sys = interp.parseData(sys_text[0..sn]) catch usys.exit(171);
    const usr = interp.parseData(usr_text[0..un]) catch usys.exit(172);
    if (sys != .record or usr != .record) usys.exit(173);
    const eff = settings.merge(fba.allocator(), sys.record, usr.record, &editor_locked) catch usys.exit(174);
    const theme = str(eff.get("theme")) orelse usys.exit(175);
    const width = int(eff.get("tab_width")) orelse usys.exit(176);
    const telemetry = eff.get("telemetry") orelse usys.exit(177);
    if (!std.mem.eql(u8, theme, "light") or width != 4 or telemetry != .bool or telemetry.bool) usys.exit(178);
    _ = usys.log(glog, cat3(&line, "session(", name, "): effective settings: theme light (user), tab_width 4 (system), telemetry false (locked by the system layer)", "", ""));
    if (!fsc.fsSync(home)) usys.exit(179);
    usys.exit(0);
}

// ------------------------------------------------------------------ drill

var client_buf_va: u64 = 0;
var sess_chan: u64 = 0;

fn drill(chan_h: u64) noreturn {
    const setup = boot.take(chan_h);
    sess_chan = setup.cap(.sess);
    const home = setup.cap(.view);
    if (sess_chan == 0 or home == 0) usys.exit(140);
    const s = usys.shmCreate(1);
    if (s.err != .ok) usys.exit(141);
    const m = usys.shmMap(s.data[0]);
    if (m.err != .ok) usys.exit(142);
    client_buf_va = m.data[0];
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .attach_buf, s.data[0])) {
        .ok => |rep| if (rep != .ok) usys.exit(143),
        .err => usys.exit(144),
    }

    // Refusals first: the wrong passphrase and a user that does not exist
    // get the same answer.
    if (tryLogin("alice", "wrong-pass") != .denied) usys.exit(145);
    _ = usys.log(glog, "users-drill: wrong passphrase refused");
    if (tryLogin("mallory", "alice-pass") != .denied) usys.exit(146);
    _ = usys.log(glog, "users-drill: unknown user refused");

    // Two sessions at once, each a domain under its user's budgets.
    const a = switch (tryLogin("alice", "alice-pass")) {
        .session => |x| x.sid,
        else => usys.exit(147),
    };
    const b = switch (tryLogin("bob", "bob-pass")) {
        .session => |x| x.sid,
        else => usys.exit(148),
    };
    if (a == b) usys.exit(149);
    _ = usys.log(glog, "users-drill: two sessions open at once (alice, bob)");
    if (waitSession(a) != 0) usys.exit(150);
    if (waitSession(b) != 0) usys.exit(151);
    _ = usys.log(glog, "users-drill: both sessions exited clean and were torn down");

    // Through the drill's own view of the home tier (read-only), each
    // home is one file: the user's volume, and it is ciphertext — the
    // session's plaintext appears nowhere on the system volume.
    const hbuf: [*]u8 = @ptrFromInt(fsc.attachBuf(home).va);
    for ([_][]const u8{ "alice", "bob" }) |who| {
        const listed = fsc.fsList(home, hbuf, who) orelse usys.exit(152);
        if (!std.mem.eql(u8, hbuf[0..listed], "vol\n")) usys.exit(153);
    }
    if (!volumeFree(home, hbuf, "alice/vol", "alice's secret")) usys.exit(154);
    if (!volumeFree(home, hbuf, "bob/vol", "bob's secret")) usys.exit(155);
    _ = usys.log(glog, "users-drill: homes isolated: each home is one encrypted volume, and the system volume holds only ciphertext");

    // Alice again: her volume opens with the key her login derives and
    // her earlier work is there (the session logs it).
    const again = switch (tryLogin("alice", "alice-pass")) {
        .session => |x| x.sid,
        else => usys.exit(156),
    };
    if (waitSession(again) != 0) usys.exit(157);

    // A session logged out early is gone too.
    const c = switch (tryLogin("alice", "alice-pass")) {
        .session => |x| x.sid,
        else => usys.exit(158),
    };
    switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .logout = .{ .sid = c } }, 0)) {
        .ok => |rep| if (rep != .ok) usys.exit(159),
        .err => usys.exit(159),
    }
    _ = usys.log(glog, "users-drill: PASS — identities are keys, sessions are domains, homes are views: two users at once, nothing shared");
    usys.exit(0);
}

/// True when `needle` occurs nowhere in the file (scanned in windows
/// that overlap by the needle's length).
fn volumeFree(view: u64, buf: [*]u8, path: []const u8, needle: []const u8) bool {
    const fd = switch (fsc.fsOpen(view, buf, path, 0)) {
        .fd => |fd| fd,
        .err => return false,
    };
    defer fsc.fsClose(view, fd);
    var off: u64 = 0;
    var total: u64 = 0;
    while (true) {
        const n = fsc.fsReadAt(view, fd, off, shared.fs_max_io) orelse return false;
        if (n == 0) break;
        if (std.mem.indexOf(u8, buf[0..n], needle) != null) return false;
        total += n;
        if (n < needle.len) break;
        off += n - (needle.len - 1);
    }
    return total > 0;
}

fn tryLogin(name: []const u8, pass: []const u8) shared.SessResp {
    const buf: [*]u8 = @ptrFromInt(client_buf_va);
    @memcpy(buf[0..name.len], name);
    @memcpy(buf[64 .. 64 + pass.len], pass);
    defer @memset(buf[0..320], 0);
    return switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .login = .{
        .name = @as(u64, name.len) << 32,
        .pass = 64 | @as(u64, pass.len) << 32,
    } }, 0)) {
        .ok => |rep| rep,
        .err => .{ .sess_err = .{ .code = 99 } },
    };
}

fn waitSession(sid: u64) u64 {
    return switch (usys.callTyped(shared.SessReq, shared.SessResp, sess_chan, .{ .wait = .{ .sid = sid } }, 0)) {
        .ok => |rep| switch (rep) {
            .exited => |e| e.code,
            else => 255,
        },
        .err => 255,
    };
}

// -------------------------------------------------------------- utilities

fn readFile(view: u64, buf: [*]u8, path: []const u8, out: []u8) ?usize {
    const fd = switch (fsc.fsOpen(view, buf, path, 0)) {
        .fd => |fd| fd,
        .err => return null,
    };
    defer fsc.fsClose(view, fd);
    const n = fsc.fsRead(view, fd, out.len) orelse return null;
    if (n > out.len) return null;
    @memcpy(out[0..n], buf[0..n]);
    return n;
}

fn writeFile(view: u64, buf: [*]u8, path: []const u8, data: []const u8) bool {
    const fd = switch (fsc.fsOpen(view, buf, path, 1)) {
        .fd => |fd| fd,
        .err => return false,
    };
    defer fsc.fsClose(view, fd);
    if (!fsc.fsTruncate(view, fd, 0)) return false;
    return fsc.fsWriteAt(view, buf, fd, 0, data);
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .str) x.str else null;
}

fn int(v: ?Value) ?i64 {
    const x = v orelse return null;
    return if (x == .int) x.int else null;
}

fn put(out: []u8, n: usize, s: []const u8) usize {
    const k = @min(s.len, out.len - n);
    @memcpy(out[n .. n + k], s[0..k]);
    return n + k;
}

fn putNum(out: []u8, n: usize, v: u64) usize {
    var ds: [20]u8 = undefined;
    var d: usize = 0;
    var x = v;
    while (true) {
        ds[d] = '0' + @as(u8, @intCast(x % 10));
        d += 1;
        x /= 10;
        if (x == 0) break;
    }
    var m = n;
    while (d > 0) {
        d -= 1;
        m = put(out, m, ds[d .. d + 1]);
    }
    return m;
}

fn cat3(out: []u8, a: []const u8, b: []const u8, c: []const u8, d: []const u8, e: []const u8) []const u8 {
    var n: usize = 0;
    for ([_][]const u8{ a, b, c, d, e }) |s| n = putStr(out, n, s);
    return out[0..n];
}

fn logName(prefix: []const u8, name: []const u8) void {
    var line: [96]u8 = undefined;
    _ = usys.log(glog, cat3(&line, prefix, name, "", "", ""));
}
