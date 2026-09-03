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
//!   2 "useradmin" — the admin step of the drill: writes two user records
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
const mshl = mosslib.mshl;
const usercred = mosslib.usercred;
const settings = mosslib.settings;
const Value = mshl.Value;

comptime {
    asm (
        \\.section .text.uhdr, "ax"
        \\.global __uhdr
        \\__uhdr:
        \\        .ascii  "MOSS"
        \\        .word   0
        \\        .quad   __utext_size
        \\        .quad   __uload_size
        \\        .quad   __umem_size
        \\        .ascii  "users"
        \\        .space  11
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = std.debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

export fn umain(log_h: u64, chan_h: u64, role: u64, bva: u64, blen: u64) callconv(.c) noreturn {
    glog = log_h;
    switch (role & 0xff) {
        1 => usersvc(chan_h, bva, blen, role),
        2 => useradmin(chan_h),
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
const test_users = [_]struct { name: []const u8, pass: []const u8 }{
    .{ .name = "alice", .pass = "alice-pass" },
    .{ .name = "bob", .pass = "bob-pass" },
};

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
};

const Budget = struct { kobj_kb: u64 = 1 << 10, user_kb: u64 = 4 << 10, cpu_permille: u64 = 0 };

var sessions: [max_sessions]Session = @splat(.{});
var svc_chan: u64 = 0;
var users_view: u64 = 0;
var users_buf: [*]u8 = undefined;
var home_view: u64 = 0;
var home_buf: [*]u8 = undefined;
var app_view: u64 = 0;
var store_view: u64 = 0;
var client_va: u64 = 0;
var client_pages: u64 = 0;
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
    if (users_view == 0 or home_view == 0 or app_view == 0) usys.exit(180);
    users_buf = @ptrFromInt(fsc.attachBuf(users_view).va);
    home_buf = @ptrFromInt(fsc.attachBuf(home_view).va);
    stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(181);
    _ = usys.log(glog, "usersvc: up; sessions are domains, identities are keys");
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
        if (r.err != .ok) usys.exit(182);
        const req = shared.decodeMsg(shared.SessReq, r.data) orelse {
            reply(.{ .sess_err = .{ .code = 1 } });
            continue;
        };
        switch (req) {
            .attach_buf => {
                if (r.cap != 0) {
                    const m = usys.shmMap(r.cap);
                    if (m.err == .ok) {
                        if (client_va != 0) _ = usys.shmUnmap(client_va);
                        client_va = m.data[0];
                        client_pages = m.data[1];
                    }
                    _ = usys.capDrop(r.cap);
                }
                reply(.ok);
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
    s.fs_chan = 0;
    s.fs_ctl = 0;
    s.fs_buf_va = 0;
    s.fs_buf_h = 0;
}

/// A client word: off | len<<32 into the attached buffer.
fn clientSlice(word: u64) ?[]u8 {
    const off = word & 0xffff_ffff;
    const len = word >> 32;
    if (client_va == 0 or len > 256 or off + len > client_pages * 4096) return null;
    return @as([*]u8, @ptrFromInt(client_va))[off .. off + len];
}

/// The protocol's login: name and passphrase from the client's buffer.
fn login(name_w: u64, pass_w: u64) shared.SessResp {
    const name_src = clientSlice(name_w) orelse return .denied;
    const pass_src = clientSlice(pass_w) orelse return .denied;
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
    const rec = readRecord(name, &budget) orelse return refuse("usersvc: login refused");
    var fba = std.heap.FixedBufferAllocator.init(&kdf_heap);
    const kp = usercred.unlock(fba.allocator(), &rec, phrase) catch return refuse("usersvc: login refused");

    const s = &sessions[slot];
    s.* = .{ .used = true, .kp = kp, .name_len = name.len };
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
    return rec;
}

/// The session, under the record's budgets, handed a rw view of
/// home/<name>, the settings layer and its name: on a console, an init
/// instance (mode 3) that runs the session's units with that console;
/// otherwise the session program (role 3).
fn spawnSession(s: *Session, budget: Budget, console: u64) bool {
    const name = s.name[0..s.name_len];
    const view = openHome(s) orelse return false;
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
    var ok = boot.giveCap(b, .view, view) and boot.giveCap(b, .conf, app_view);
    if (ok and store_view != 0) ok = boot.giveCap(b, .store, store_view);
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
fn openHome(s: *Session) ?u64 {
    const name = s.name[0..s.name_len];
    if (!fsc.fsMkdir(home_view, home_buf, name)) return null;
    const voldir = fsc.fsDerive(home_view, home_buf, name, false) orelse return null;
    defer _ = usys.capDrop(voldir);
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

// -------------------------------------------------------------- useradmin

fn useradmin(chan_h: u64) noreturn {
    const setup = boot.take(chan_h);
    const uv = setup.cap(.view);
    const av = setup.cap(.conf);
    if (uv == 0 or av == 0) usys.exit(190);
    const ubuf: [*]u8 = @ptrFromInt(fsc.attachBuf(uv).va);
    const abuf: [*]u8 = @ptrFromInt(fsc.attachBuf(av).va);

    for (test_users) |u| {
        var seed: [usercred.seed_len]u8 = undefined;
        var salt: [usercred.salt_len]u8 = undefined;
        randomOrDie(&seed);
        randomOrDie(&salt);
        var fba = std.heap.FixedBufferAllocator.init(&kdf_heap);
        const rec = usercred.create(fba.allocator(), &seed, &salt, u.pass, drill_kdf) catch usys.exit(191);
        @memset(&seed, 0);
        var text: [1024]u8 = undefined;
        const rendered = renderRecord(&text, rec);
        var path: [max_name + 4]u8 = undefined;
        @memcpy(path[0..u.name.len], u.name);
        @memcpy(path[u.name.len .. u.name.len + 4], ".msh");
        if (!writeFile(uv, ubuf, path[0 .. u.name.len + 4], rendered)) usys.exit(192);
        var line: [96]u8 = undefined;
        var hex: [16]u8 = undefined;
        _ = usys.log(glog, cat3(&line, "useradmin: created user ", u.name, " (key ", usercred.hexEncode(&hex, rec.pk[0..8]), "...)"));
    }
    if (!writeFile(av, abuf, "editor.msh", "{ theme: dark, tab_width: 4, telemetry: false }\n")) usys.exit(193);
    if (!fsc.fsSync(uv)) usys.exit(194);
    _ = usys.log(glog, "useradmin: records and the system settings layer written");
    usys.exit(0);
}

fn randomOrDie(out: []u8) void {
    var tries: usize = 0;
    while (usys.getrandom(out) != .ok) : (tries += 1) {
        if (tries == 100) usys.exit(195); // the pool never seeded
        usys.sleep(1);
    }
}

/// A record as data: the same syntax as a unit file, hex for the bytes.
fn renderRecord(out: *[1024]u8, rec: usercred.Record) []const u8 {
    var n: usize = 0;
    var hex: [2 * usercred.sealed_len]u8 = undefined;
    n = put(out, n, "{ key: \"");
    n = put(out, n, usercred.hexEncode(&hex, &rec.pk));
    n = put(out, n, "\", salt: \"");
    n = put(out, n, usercred.hexEncode(&hex, &rec.salt));
    n = put(out, n, "\", sealed: \"");
    n = put(out, n, usercred.hexEncode(&hex, &rec.sealed));
    n = put(out, n, "\",\n  kdf: { ln: ");
    n = putNum(out, n, rec.kdf.ln);
    n = put(out, n, ", r: ");
    n = putNum(out, n, rec.kdf.r);
    n = put(out, n, ", p: ");
    n = putNum(out, n, rec.kdf.p);
    n = put(out, n, " },\n  budget: { kobj: 2mb, user: 12mb, cpu: 500 } }\n");
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
    for ([_][]const u8{ a, b, c, d, e }) |s| n = put(out, n, s);
    return out[0..n];
}

fn logName(prefix: []const u8, name: []const u8) void {
    var line: [96]u8 = undefined;
    _ = usys.log(glog, cat3(&line, prefix, name, "", "", ""));
}
