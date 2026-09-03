//! The init service: capability wiring + channel activation + supervision,
//! driven by UNIT FILES. An ordinary restartable process — no special
//! kernel status.
//!
//! Every program init can start is a unit: `conf/units/<name>.msh` in the
//! boot archive, an mshl data literal naming the image, its budget and
//! spawn grants, and `give` lines — what it is handed over its boot
//! channel before `go`: a device (from the caps root forwarded to init),
//! another unit's channel (activating that unit first — capability
//! wiring IS the dependency model; there is no ordering anywhere), a
//! shared buffer, a secret from the archive, a filesystem view, a network
//! view, init's own front channel. `start: eager` units start at boot;
//! everything else starts when something asks for it (channel
//! activation). `essential: true` means the system follows this unit's
//! exit. `certify` runs the fabric's certification against a root of
//! trust unit. `install: true` installs the program store through the
//! filesystem unit once it is up.
//!
//! Supervision is one-for-one with a restart budget and backoff: a death
//! notification interrupts init's blocked recv, the dead unit is respawned
//! and re-wired, and dependents holding init's front channel re-request
//! their dependency. Modes (x2): 0 = the Phase 5 demo (a worker drives
//! lazily-started services), 1 = the flap drill, 2 = the system boot,
//! 3 = a user SESSION: the same orchestrator at another radius. The
//! session manager hands it the user's home view, console and settings
//! view over the boot channel; its units come from `conf/units/` in the
//! home (the user's own) or the archive's `conf/session/` template, views
//! it gives derive from the home, and `{ tag: console, session: true }`
//! hands a unit one of the session's own caps.
//!
//! Grant layout (insert order log→chan→spawner): log in x0, the boot
//! channel from root in x1 (device caps arrive on it), spawner at slot 2.

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const loader = @import("loader.zig");
const fsc = @import("fsclient.zig");
const boot = @import("boot.zig");
const mshl = @import("mosslib").mshl;

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
        \\        .ascii  "init"
        \\        .space  12
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const spawner: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

// ------------------------------------------------------------------ units

const max_units = 32;
const max_gives = 8;

const GiveKind = enum { unit, device, shm, secret, view, netview, self_init, session_cap };

const Give = struct {
    tag: shared.CapTag,
    kind: GiveKind,
    name: []const u8 = "", // unit name, device name, archive path, fs path
    pages: u64 = 1,
    ro: bool = true,
    allow: u32 = 0, // netview: a one-destination allowlist (v4), 0 = none
    port: u64 = 0,
    mkdir: bool = false, // view: create the directory first (idempotent)
    /// Which of several: the i-th device of a kind, or the index the
    /// receiver files the cap under (a program handed two consoles).
    index: u64 = 0,
};

fn parseV4(s: []const u8) ?u32 {
    var v: u32 = 0;
    var octets: usize = 0;
    var cur: u32 = 0;
    var have = false;
    for (s) |c| {
        if (c == '.') {
            if (!have) return null;
            v = (v << 8) | cur;
            octets += 1;
            cur = 0;
            have = false;
        } else if (c >= '0' and c <= '9') {
            cur = cur * 10 + (c - '0');
            if (cur > 255) return null;
            have = true;
        } else return null;
    }
    if (!have or octets != 3) return null;
    return (v << 8) | cur;
}

const Certify = struct {
    root: []const u8,
    node: u64,
    flags: u64,
    /// Where the identity lives across boots (seed + certificate files).
    state: []const u8,
};

const Unit = struct {
    name: []const u8,
    image: shared.ImageId,
    arg: u64 = 0,
    kobj_kb: u64 = 1 << 10,
    user_kb: u64 = 4 << 10,
    /// CPU budget in permille of one core per period (0 = none of its
    /// own) and a partition: cores reserved for this unit alone.
    cpu_permille: u64 = 0,
    cores: u64 = 0,
    flags: u64 = shared.SpawnFlags.grant_log,
    gives: [max_gives]Give = undefined,
    ngives: usize = 0,
    max_restarts: u64 = 0,
    /// Eager under these profiles (bit per shared.BootProfile).
    profiles: u64 = 0,
    essential: bool = false,
    install: bool = false,
    /// One-shot (a drill step): exit 0 starts the units that wait on it
    /// (`after: name`); a non-zero exit takes the system down.
    oneshot: bool = false,
    after: []const u8 = "",
    certify: ?Certify = null,
    // The instance.
    ctl: u64 = 0,
    chan_b: u64 = 0,
    up: bool = false,
    stopped: bool = false,
    activating: bool = false,
    restarts: u64 = 0,
    buf_h: u64 = 0, // its `buf` shm cap, if a give created one
    buf_va: u64 = 0, // ... mapped here (secrets are staged through it)
    identity_restored: bool = false,
};

var units: [max_units]Unit = undefined;
var nunits: usize = 0;
var glog: u64 = 0;
var stage: loader.Stage = undefined;
var boot_va: u64 = 0;
var boot_len: u64 = 0;
var front_a: u64 = 0;
var front_b: u64 = 0;
var devices: [boot.max_device_kinds][boot.max_index]u64 = @splat(@splat(0)); // device caps by kind, from root
var entropy_cap: u64 = 0;
// Session mode: the home view (views derive from it), the session's own
// caps by tag (handed on with `session: true`), and the unit files read
// from the home (they must outlive the parser's arena).
var session_mode = false;
var session_home: u64 = 0;
var session_home_buf: [*]u8 = undefined;
var session_caps: [shared.cap_tag_count]u64 = @splat(0);
var session_text: [32 << 10]u8 = undefined;
var session_text_len: usize = 0;
/// The boot profile's bit: `after` steps start only under a profile they list.
var profile_bit: u64 = 0;

// The unit parser's memory: a small arena, reset per file.
var heap: [256 << 10]u8 = undefined;
var fba: std.heap.FixedBufferAllocator = undefined;
var interp: mshl.Interp = undefined;
var host_ctx: u8 = 0;

fn noHost(_: *anyopaque, _: *mshl.Interp, _: []const u8, _: []const Value, _: ?Value) mshl.Error!?Value {
    return null;
}

const Value = mshl.Value;

fn archive() []const u8 {
    return @as([*]const u8, @ptrFromInt(boot_va))[0..boot_len];
}

/// Read every conf/units/*.msh in the archive into `units`.
fn loadUnits() void {
    var it = shared.marcIter(archive());
    while (it.next()) |e| {
        if (!std.mem.startsWith(u8, e.path, shared.unit_dir) or !std.mem.endsWith(u8, e.path, shared.unit_ext)) continue;
        if (nunits == max_units) {
            logLine("init: TOO MANY UNITS; ignoring ", e.path);
            continue;
        }
        const name = e.path[shared.unit_dir.len .. e.path.len - shared.unit_ext.len];
        fba.reset();
        const v = interp.parseData(e.data) catch {
            logLine("init: unit file refused: ", name);
            continue;
        };
        if (parseUnit(name, v)) |u| {
            units[nunits] = u;
            nunits += 1;
        } else {
            logLine("init: unit file invalid: ", name);
        }
    }
}

fn parseUnit(name: []const u8, v: Value) ?Unit {
    if (v != .record) return null;
    const r = v.record;
    const image_name = str(r.get("image")) orelse return null;
    const image = std.meta.stringToEnum(shared.ImageId, image_name) orelse return null;
    var u: Unit = .{ .name = name, .image = image };
    if (r.get("arg")) |a| u.arg = @intCast(int(a) orelse 0);
    if (r.get("cores")) |cs| {
        if (cs == .list) {
            for (cs.list) |c| {
                if (int(c)) |n| {
                    if (n >= 0 and n < 64) u.cores |= @as(u64, 1) << @intCast(n);
                }
            }
        }
    }
    if (r.get("budget")) |b| {
        if (b == .record) {
            if (b.record.get("kobj")) |k| u.kobj_kb = @intCast(@divTrunc(int(k) orelse 0, 1024));
            if (b.record.get("user")) |k| u.user_kb = @intCast(@divTrunc(int(k) orelse 0, 1024));
            // cpu: 500 (permille of one core) or "50%".
            if (b.record.get("cpu")) |k| {
                if (int(k)) |n| {
                    u.cpu_permille = @intCast(@max(n, 0));
                } else if (str(k)) |txt| {
                    if (txt.len > 1 and txt[txt.len - 1] == '%') {
                        var pct: u64 = 0;
                        for (txt[0 .. txt.len - 1]) |ch| {
                            if (ch >= '0' and ch <= '9') pct = pct * 10 + (ch - '0');
                        }
                        u.cpu_permille = pct * 10;
                    }
                }
            }
        }
    }
    if (r.get("grant")) |g| {
        if (g == .list) for (g.list) |item| {
            const gn = str(item) orelse continue;
            if (std.mem.eql(u8, gn, "log")) u.flags |= shared.SpawnFlags.grant_log;
            if (std.mem.eql(u8, gn, "spawner")) u.flags |= shared.SpawnFlags.grant_spawner;
            if (std.mem.eql(u8, gn, "bootfs")) u.flags |= shared.SpawnFlags.grant_bootfs;
            if (std.mem.eql(u8, gn, "introspect")) u.flags |= shared.SpawnFlags.grant_introspect;
        };
    }
    if (r.get("give")) |g| {
        if (g == .list) for (g.list) |item| {
            if (item != .record or u.ngives == max_gives) continue;
            const gr = item.record;
            // A secret is bytes, not a capability: no tag.
            if (gr.get("secret")) |x| {
                u.gives[u.ngives] = .{ .tag = .buf, .kind = .secret, .name = str(x) orelse continue };
                u.ngives += 1;
                continue;
            }
            const tag = std.meta.stringToEnum(shared.CapTag, str(gr.get("tag")) orelse continue) orelse continue;
            var give: Give = .{ .tag = tag, .kind = .unit };
            if (gr.get("unit")) |x| {
                give.name = str(x) orelse continue;
            } else if (gr.get("device")) |x| {
                give.kind = .device;
                give.name = str(x) orelse continue;
            } else if (gr.get("shm")) |x| {
                give.kind = .shm;
                give.pages = @intCast(int(x) orelse 1);
            } else if (gr.get("fs")) |x| {
                give.kind = .view;
                give.name = str(x) orelse continue;
                if (gr.get("ro")) |ro| give.ro = ro.truthy();
                if (gr.get("mkdir")) |mk| give.mkdir = mk.truthy();
            } else if (gr.get("netview")) |x| {
                give.kind = .netview;
                give.name = str(x) orelse continue;
                if (gr.get("allow")) |al| give.allow = parseV4(str(al) orelse "") orelse continue;
                if (gr.get("port")) |pt| give.port = @intCast(int(pt) orelse 0);
            } else if (gr.get("self") != null) {
                give.kind = .self_init;
            } else if (gr.get("session") != null) {
                give.kind = .session_cap;
            } else continue;
            if (gr.get("index")) |ix| give.index = @intCast(@max(int(ix) orelse 0, 0));
            u.gives[u.ngives] = give;
            u.ngives += 1;
        };
    }
    if (r.get("restart")) |rs| {
        if (rs == .record) {
            if (rs.record.get("max")) |m| u.max_restarts = @intCast(int(m) orelse 0);
        }
    }
    if (r.get("profiles")) |pl| {
        if (pl == .list) for (pl.list) |item| {
            const pn = str(item) orelse continue;
            if (std.meta.stringToEnum(shared.BootProfile, pn)) |bp| u.profiles |= @as(u64, 1) << @intCast(@intFromEnum(bp));
        };
    }
    if (r.get("essential")) |e| u.essential = e.truthy();
    if (r.get("oneshot")) |e| u.oneshot = e.truthy();
    if (r.get("after")) |a| u.after = str(a) orelse "";
    if (r.get("install")) |e| u.install = e.truthy();
    if (r.get("certify")) |c| {
        if (c == .record) {
            var flags: u64 = 0;
            if (c.record.get("gossip")) |x| if (x.truthy()) {
                flags |= shared.fab_flag_gossip;
            };
            if (c.record.get("spawn")) |x| if (x.truthy()) {
                flags |= shared.fab_flag_spawn;
            };
            u.certify = .{
                .root = str(c.record.get("root")) orelse return null,
                .node = @intCast(int(c.record.get("node")) orelse 1),
                .flags = flags,
                .state = str(c.record.get("state")) orelse "state/fabric",
            };
        }
    }
    return u;
}

fn str(v: ?Value) ?[]const u8 {
    const x = v orelse return null;
    return if (x == .str) x.str else null;
}

fn int(v: ?Value) ?i64 {
    const x = v orelse return null;
    return if (x == .int) x.int else null;
}

fn unitByName(name: []const u8) ?*Unit {
    for (units[0..nunits]) |*u| {
        if (std.mem.eql(u8, u.name, name)) return u;
    }
    return null;
}

// ------------------------------------------------------------ activation

/// Make sure a unit is up (starting it, and whatever it needs, first).
fn ensureUp(u: *Unit) bool {
    if (u.up) {
        // Never hand out a channel to a corpse: a death we have not yet
        // processed shows up here as a dead instance.
        const st = usys.domainStat(u.ctl);
        if (st.err == .ok and st.data[0] != @intFromEnum(shared.DomainState.dead)) return true;
        u.up = false;
        u.restarts += 1;
    }
    if (u.activating) return false; // a dependency cycle in the unit files
    return activate(u);
}

/// Spawn a unit and wire it: stage the image, spawn with its grants and
/// budget, hand it every `give` over its boot channel, go, then the
/// post-boot steps (certification, the store install).
fn activate(u: *Unit) bool {
    u.activating = true;
    defer u.activating = false;
    if (!stage.load(boot_va, boot_len, u.image)) {
        logLine("init: image missing from the boot archive for unit ", u.name);
        return false;
    }
    const ch = usys.chanCreate();
    if (ch.err != .ok) return false;
    const r = usys.spawnCpu(spawner, stage.handle, u.arg, ch.data[0], u.flags | shared.SpawnFlags.chan_side_a, usys.kbLimits(u.kobj_kb, u.user_kb), usys.cpuBudget(u.cpu_permille, u.cores));
    _ = usys.capDrop(ch.data[0]); // the unit owns its serving side alone
    if (r.err != .ok) {
        _ = usys.capDrop(ch.data[1]);
        logLine("init: spawn refused for unit ", u.name);
        return false;
    }
    if (u.ctl != 0) _ = usys.capDrop(u.ctl);
    if (u.chan_b != 0) _ = usys.capDrop(u.chan_b);
    u.ctl = r.data[0];
    u.chan_b = ch.data[1];

    var ok = true;
    for (u.gives[0..u.ngives]) |g| {
        if (!ok) break;
        ok = giveOne(u, g);
        if (!ok) logLine("init: give failed: ", @tagName(g.kind));
    }
    if (ok and u.certify != null) {
        ok = certifySecret(u);
        if (!ok) logLine("init: certify secret failed for unit ", u.name);
    }
    if (ok) ok = boot.give(u.chan_b, .go, 0);
    if (!ok) {
        logLine("init: could not wire unit ", u.name);
        _ = usys.domainDestroy(u.ctl);
        return false;
    }
    u.up = true;
    u.stopped = false;
    if (u.certify != null and !certifyFinish(u)) {
        logLine("init: certification failed for unit ", u.name);
    }
    if (u.install) installStore(u);
    if (u.restarts == 0) logLine("init: started unit ", u.name);
    return true;
}

fn giveOne(u: *Unit, g: Give) bool {
    switch (g.kind) {
        .unit => {
            const dep = unitByName(g.name) orelse return false;
            if (!ensureUp(dep)) return false;
            return boot.giveCapAt(u.chan_b, g.tag, g.index, dep.chan_b);
        },
        .device => {
            // `device: entropy` is the one non-PCI "device": the kernel
            // pool's seeding authority.
            if (std.mem.eql(u8, g.name, "entropy")) {
                if (entropy_cap == 0) return false;
                return boot.giveCap(u.chan_b, g.tag, entropy_cap);
            }
            const kind = std.meta.stringToEnum(shared.DeviceKind, g.name) orelse return false;
            if (g.index >= boot.max_index) return false;
            const cap = devices[@intFromEnum(kind)][g.index];
            if (cap == 0) return false;
            return boot.giveDevice(u.chan_b, cap, @intFromEnum(kind));
        },
        .shm => {
            const s = usys.shmCreate(g.pages);
            if (s.err != .ok) return false;
            if (g.tag != .buf) {
                // Nothing to stage through it: the unit's copy is the only one.
                const gave = boot.giveCap(u.chan_b, g.tag, s.data[0]);
                _ = usys.capDrop(s.data[0]);
                return gave;
            }
            const m = usys.shmMap(s.data[0]);
            if (m.err != .ok) return false;
            // A restarted unit gets a fresh buffer; the last life's goes.
            if (u.buf_va != 0) _ = usys.shmUnmap(u.buf_va);
            if (u.buf_h != 0) _ = usys.capDrop(u.buf_h);
            u.buf_h = s.data[0];
            u.buf_va = m.data[0];
            return boot.giveCap(u.chan_b, g.tag, s.data[0]);
        },
        .secret => {
            const bytes = shared.marcFind(archive(), g.name) orelse {
                logLine("init: secret not in the archive: ", g.name);
                return false;
            };
            if (u.buf_va == 0 or bytes.len > boot.max_secret) return false;
            const dst: [*]volatile u8 = @ptrFromInt(u.buf_va);
            for (bytes, 0..) |b, i| dst[i] = b;
            return boot.give(u.chan_b, .{ .secret = .{ .off = 0, .len = bytes.len } }, 0);
        },
        .view => {
            // A session's views derive from its home; the system's from
            // the filesystem unit's root view.
            var chan: u64 = session_home;
            var buf: [*]u8 = session_home_buf;
            if (!session_mode) {
                const fs = unitByName("fs") orelse return false;
                if (!ensureUp(fs) or fs.buf_va == 0) return false;
                chan = fs.chan_b;
                buf = @ptrFromInt(fs.buf_va);
            }
            const path = g.name;
            if (g.mkdir and !fsc.fsMkdir(chan, buf, path)) return false;
            const view = fsc.fsDerive(chan, buf, path, g.ro) orelse return false;
            const ok = boot.giveCap(u.chan_b, g.tag, view);
            _ = usys.capDrop(view);
            return ok;
        },
        .netview => {
            const net = unitByName(g.name) orelse return false;
            if (!ensureUp(net)) return false;
            const words = if (g.allow != 0) shared.v4Words(g.allow) else [2]u64{ 0, 0 };
            switch (usys.callTypedCap(shared.NetReq, shared.NetResp, net.chan_b, .{
                .derive = .{ .ip_hi = words[0], .ip_lo = words[1], .port = if (g.allow != 0) g.port else 0 },
            }, 0)) {
                .ok => |ok| {
                    if (ok.cap == 0) return false;
                    const given = boot.giveCap(u.chan_b, g.tag, ok.cap);
                    _ = usys.capDrop(ok.cap);
                    return given;
                },
                .err => return false,
            }
        },
        .self_init => return boot.giveCap(u.chan_b, g.tag, front_b),
        .session_cap => {
            const cap = session_caps[@intFromEnum(g.tag)];
            if (cap == 0) return false;
            return boot.giveCap(u.chan_b, g.tag, cap);
        },
    }
}

/// Session mode: the units are the user's own (`conf/units/` in the
/// home) when there are any, else the archive's template.
fn loadSessionUnits() void {
    const count = fsc.fsList(session_home, session_home_buf, shared.unit_dir[0 .. shared.unit_dir.len - 1]) orelse 0;
    var names: [1024]u8 = undefined;
    const k = @min(count, names.len);
    @memcpy(names[0..k], session_home_buf[0..k]);
    var it = std.mem.splitScalar(u8, names[0..k], '\n');
    while (it.next()) |fname| {
        if (!std.mem.endsWith(u8, fname, shared.unit_ext) or nunits == max_units) continue;
        var path: [96]u8 = undefined;
        const p = joinPath(@ptrCast(&path), shared.unit_dir[0 .. shared.unit_dir.len - 1], fname);
        const name = fname[0 .. fname.len - shared.unit_ext.len];
        const text = readHome(p) orelse continue;
        const kept_name = keep(name) orelse continue;
        fba.reset();
        const v = interp.parseData(text) catch {
            logLine("init: unit file refused: ", name);
            continue;
        };
        if (parseUnit(kept_name, v)) |u| {
            units[nunits] = u;
            nunits += 1;
        } else logLine("init: unit file invalid: ", name);
    }
    if (nunits > 0) return;
    var ai = shared.marcIter(archive());
    while (ai.next()) |e| {
        if (!std.mem.startsWith(u8, e.path, shared.session_unit_dir) or !std.mem.endsWith(u8, e.path, shared.unit_ext)) continue;
        if (nunits == max_units) break;
        const name = e.path[shared.session_unit_dir.len .. e.path.len - shared.unit_ext.len];
        fba.reset();
        const v = interp.parseData(e.data) catch continue;
        if (parseUnit(name, v)) |u| {
            units[nunits] = u;
            nunits += 1;
        }
    }
}

/// Read a whole small file from the home into the persistent text area.
fn readHome(path: []const u8) ?[]const u8 {
    const fd = switch (fsc.fsOpen(session_home, session_home_buf, path, 0)) {
        .fd => |fd| fd,
        .err => return null,
    };
    defer fsc.fsClose(session_home, fd);
    const n = fsc.fsRead(session_home, fd, 4096) orelse return null;
    return keep(session_home_buf[0..n]);
}

fn keep(text: []const u8) ?[]const u8 {
    if (session_text_len + text.len > session_text.len) return null;
    const out = session_text[session_text_len .. session_text_len + text.len];
    @memcpy(out, text);
    session_text_len += text.len;
    return out;
}

/// Before go: the identity secret — the node's seed (restored from its
/// state, or born now from the kernel pool and kept there) plus the
/// root's cluster key — into the unit's buffer.
fn certifySecret(u: *Unit) bool {
    const c = u.certify.?;
    const root = unitByName(c.root) orelse return false;
    const fs = unitByName("fs") orelse return false;
    if (!ensureUp(fs) or fs.buf_va == 0 or u.buf_va == 0) return false;
    if (!ensureUp(root) or root.buf_va == 0) return false;
    var seed: [32]u8 = undefined;
    var seed_path: [64]u8 = undefined;
    const sp = joinPath(&seed_path, c.state, "identity.seed");
    if (stateRead(fs, sp, &seed)) {
        u.identity_restored = true;
    } else {
        // Born here, from this node's entropy — never handed in.
        var tries: usize = 0;
        while (usys.getrandom(&seed) != .ok) : (tries += 1) {
            if (tries == 50) return false; // rngd never seeded the pool
            usys.sleep(1);
        }
        if (!stateWrite(fs, sp, &seed)) return false;
        u.identity_restored = false;
    }
    switch (usys.callTyped(shared.RootReq, shared.FabResp, root.chan_b, .cluster_key, 0)) {
        .ok => |rep| if (rep != .num) return false,
        .err => return false,
    }
    const dst: [*]volatile u8 = @ptrFromInt(u.buf_va);
    const pk: [*]const volatile u8 = @ptrFromInt(root.buf_va);
    for (0..32) |i| dst[i] = seed[i];
    for (0..32) |i| dst[32 + i] = pk[i];
    @memset(&seed, 0);
    return boot.give(u.chan_b, .{ .secret = .{ .off = 0, .len = 64 } }, 0);
}

/// After go: install the certificate — the one kept in state if the
/// identity was restored, else a fresh one from the root of trust over
/// the public key the unit hands back, kept in state for next time.
/// set_cert opens the network (retried while the entropy pool seeds).
fn certifyFinish(u: *Unit) bool {
    const c = u.certify.?;
    const fs = unitByName("fs") orelse return false;
    var cert_path: [64]u8 = undefined;
    const cp = joinPath(&cert_path, c.state, "identity.cert");
    var cert: [shared.fab_cert_len]u8 = undefined;
    const ub: [*]volatile u8 = @ptrFromInt(u.buf_va);
    if (u.identity_restored and stateRead(fs, cp, &cert)) {
        logLine("init: fabric identity restored from state for unit ", u.name);
    } else {
        const root = unitByName(c.root) orelse return false;
        if (!ensureUp(root) or root.buf_va == 0) return false;
        switch (usys.callTyped(shared.FabReq, shared.FabResp, u.chan_b, .identity_key, 0)) {
            .ok => |rep| if (rep != .num) return false,
            .err => return false,
        }
        const pk: [*]const volatile u8 = @ptrFromInt(u.buf_va);
        const rb: [*]volatile u8 = @ptrFromInt(root.buf_va);
        for (0..32) |i| rb[i] = pk[i];
        switch (usys.callTyped(shared.RootReq, shared.FabResp, root.chan_b, .{ .issue = .{
            .node = c.node,
            .flags_serial = c.flags | (1 << 8),
            .image_mask = ~@as(u64, 0),
        } }, 0)) {
            .ok => |rep| if (rep != .num) return false,
            .err => return false,
        }
        for (0..shared.fab_cert_len) |i| cert[i] = rb[i];
        if (!stateWrite(fs, cp, &cert)) return false;
        logLine("init: fabric identity born and certified for unit ", u.name);
    }
    for (0..shared.fab_cert_len) |i| ub[i] = cert[i];
    var attempt: usize = 0;
    while (attempt < 30) : (attempt += 1) {
        switch (usys.callTyped(shared.FabReq, shared.FabResp, u.chan_b, .{ .set_cert = .{ .off = 0, .len = shared.fab_cert_len } }, 0)) {
            .ok => |rep| switch (rep) {
                .ok => return true,
                .fab_err => |e| {
                    if (e.code != @intFromEnum(shared.FabErr.no_entropy)) return false;
                    usys.sleep(1); // rngd is still seeding the pool
                },
                else => return false,
            },
            .err => return false,
        }
    }
    return false;
}

/// Read a whole small file from the root-of-trust view into `out`
/// (exactly out.len bytes, else false).
fn stateRead(fs: *Unit, path: []const u8, out: []u8) bool {
    const buf: [*]u8 = @ptrFromInt(fs.buf_va);
    const fd = switch (fsc.fsOpen(fs.chan_b, buf, path, 0)) {
        .fd => |fd| fd,
        .err => return false,
    };
    defer fsc.fsClose(fs.chan_b, fd);
    const n = fsc.fsRead(fs.chan_b, fd, out.len + 1) orelse return false;
    if (n != out.len) return false;
    @memcpy(out, buf[0..out.len]);
    return true;
}

fn stateWrite(fs: *Unit, path: []const u8, data: []const u8) bool {
    const buf: [*]u8 = @ptrFromInt(fs.buf_va);
    if (!writeFile(fs.chan_b, buf, path, data)) return false;
    return fsc.fsSync(fs.chan_b);
}

fn joinPath(out: *[64]u8, dir: []const u8, name: []const u8) []const u8 {
    const n = @min(dir.len, out.len - name.len - 1);
    @memcpy(out[0..n], dir[0..n]);
    out[n] = '/';
    @memcpy(out[n + 1 .. n + 1 + name.len], name);
    return out[0 .. n + 1 + name.len];
}

/// The program store: derive the root view from a freshly started
/// filesystem unit and install the archive's images.
fn installStore(u: *Unit) void {
    if (u.buf_va == 0) return;
    const view = fsc.fsDerive(u.chan_b, @ptrFromInt(u.buf_va), "", false) orelse return;
    _ = installImages(view);
    _ = usys.capDrop(view);
}

// ------------------------------------------------------------ supervision

/// One-for-one supervision with budget + backoff; an essential unit's
/// exit takes the system down with its code.
fn superviseDeaths() void {
    for (units[0..nunits]) |*u| {
        if (!u.up or u.ctl == 0 or u.stopped) continue;
        const st = usys.domainStat(u.ctl);
        if (st.err != .ok) continue;
        if (st.data[0] != @intFromEnum(shared.DomainState.dead)) continue;
        u.up = false;
        if (u.essential) {
            logLine("init: essential unit exited; shutting down: ", u.name);
            shutdown(st.data[1]);
        }
        if (u.oneshot) {
            if (st.data[1] != 0) {
                logLine("init: drill step failed: ", u.name);
                shutdown(st.data[1]);
            }
            logLine("init: step done: ", u.name);
            for (units[0..nunits]) |*next| {
                if (!next.up and next.ctl == 0 and std.mem.eql(u8, next.after, u.name) and next.profiles & profile_bit != 0) {
                    if (!ensureUp(next)) logLine("init: step failed to start: ", next.name);
                }
            }
            continue;
        }
        if (u.restarts >= u.max_restarts) {
            logLine("init: unit exceeded its restart budget; leaving it down: ", u.name);
            continue;
        }
        u.restarts += 1;
        usys.sleep(u.restarts); // linear backoff, one tick per prior death
        if (activate(u)) {
            logLine("init: unit died; restarted it (one-for-one): ", u.name);
        }
    }
}

fn shutdown(code: u64) noreturn {
    for (units[0..nunits]) |*u| {
        if (u.up and u.ctl != 0) _ = usys.domainDestroy(u.ctl);
    }
    _ = usys.log(glog, "init: all units revoked; exiting");
    usys.exit(code);
}

// ------------------------------------------------------------------ main

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    boot_va = blob_va;
    boot_len = blob_len;
    stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(118);
    fba = std.heap.FixedBufferAllocator.init(&heap);
    interp = mshl.Interp.init(fba.allocator(), fba.allocator(), .{ .ctx = @ptrCast(&host_ctx), .call = noHost });

    // Root hands over the devices on our boot channel; a session manager
    // hands over the session's world.
    const setup = boot.take(chan_h);
    devices = setup.devices;
    entropy_cap = setup.cap(.entropy);
    _ = usys.capDrop(chan_h);

    const notif = usys.notifyCreate();
    if (notif.err != .ok) usys.exit(110);
    if (usys.watchDeaths(notif.data[0]) != .ok) usys.exit(111);

    // arg 1: the flapping-service drill instead of the normal topology.
    if (arg == 1) flapDrill(notif.data[0]);

    if (arg & 0xff == 3) {
        session_mode = true;
        session_home = setup.cap(.view);
        if (session_home == 0) usys.exit(120);
        session_home_buf = @ptrFromInt(fsc.attachBuf(session_home).va);
        inline for (std.enums.values(shared.CapTag)) |t| session_caps[@intFromEnum(t)] = setup.cap(t);
        loadSessionUnits();
        logLine("init: session for ", setup.arg());
    } else {
        loadUnits();
    }
    const front = usys.chanCreate();
    if (front.err != .ok) usys.exit(112);
    front_a = front.data[0];
    front_b = front.data[1];

    if (arg & 0xff == 2) system(notif.data[0], arg >> 8);
    if (arg & 0xff == 3) system(notif.data[0], @intFromEnum(shared.BootProfile.session));
    demo(notif.data[0]);
}

/// The system boot: eager units start (pulling in everything they
/// need); init then serves its front channel forever, or until an
/// essential unit exits.
fn system(notif: u64, profile: u64) noreturn {
    _ = usys.log(glog, "init: system boot; starting the profile's eager units");
    const bit = @as(u64, 1) << @intCast(profile & 63);
    profile_bit = bit;
    for (units[0..nunits]) |*u| {
        if (u.profiles & bit != 0 and u.after.len == 0 and !ensureUp(u)) logLine("init: eager unit failed to start: ", u.name);
    }
    _ = usys.log(glog, "init: system up");
    while (true) {
        const r = usys.recvMsg(front_a);
        switch (r.err) {
            .interrupted => {
                _ = usys.notifyWait(notif);
                superviseDeaths();
            },
            .ok => handleRequest(front_a, r),
            else => usys.exit(117),
        }
    }
}

/// The Phase 5 demo: a worker drives lazily-started services through the
/// front channel; when it finishes, init revokes them and exits clean.
fn demo(notif: u64) noreturn {
    _ = usys.log(glog, "init: up; units loaded, nothing started (lazy)");
    if (!stage.load(boot_va, boot_len, .services)) usys.exit(119);
    const worker = usys.spawn(spawner, stage.handle, 3, front_b, shared.SpawnFlags.grant_log, usys.kbLimits(1 << 10, 4 << 10));
    if (worker.err != .ok) usys.exit(113);
    while (true) {
        const r = usys.recvMsg(front_a);
        switch (r.err) {
            .interrupted => {
                _ = usys.notifyWait(notif);
                superviseDeaths();
                const st = usys.domainStat(worker.data[0]);
                if (st.err == .ok and st.data[0] == @intFromEnum(shared.DomainState.dead)) break;
            },
            .ok => handleRequest(front_a, r),
            else => usys.exit(114),
        }
    }
    for (units[0..nunits]) |*u| {
        if (u.up and u.ctl != 0) _ = usys.domainDestroy(u.ctl);
    }
    _ = usys.log(glog, "init: worker finished; services revoked; exiting");
    usys.exit(0);
}

fn handleRequest(chan: u64, r: usys.IpcResult) void {
    const req = shared.decodeMsg(shared.InitRequest, r.data) orelse {
        failReply(chan, .bad_arg);
        return;
    };
    switch (req) {
        .connect => |c| {
            const u = unitForService(c.service) orelse return failReply(chan, .bad_arg);
            if (!ensureUp(u)) return failReply(chan, .no_space);
            u.stopped = false; // connect doubles as (re)start
            _ = usys.replyTyped(shared.InitReply, chan, .connected, u.chan_b);
        },
        .status => |q| {
            const u = unitForService(q.service) orelse return failReply(chan, .bad_arg);
            if (u.up and u.ctl != 0) {
                const st = usys.domainStat(u.ctl);
                if (st.err == .ok and st.data[0] == @intFromEnum(shared.DomainState.dead)) u.up = false;
            }
            _ = usys.replyTyped(shared.InitReply, chan, .{ .svc_status = .{
                .up = @intFromBool(u.up),
                .restarts = u.restarts,
                .max_restarts = u.max_restarts,
            } }, 0);
        },
        .stop => |q| {
            const u = unitForService(q.service) orelse return failReply(chan, .bad_arg);
            if (u.up and u.ctl != 0) _ = usys.domainDestroy(u.ctl);
            u.up = false;
            u.stopped = true;
            _ = usys.replyTyped(shared.InitReply, chan, .stopped, 0);
        },
        .install => {
            if (r.cap == 0) return failReply(chan, .bad_arg);
            const n = installImages(r.cap);
            _ = usys.replyTyped(shared.InitReply, chan, .{ .installed = .{ .n = n } }, 0);
        },
    }
}

fn failReply(chan: u64, e: shared.Errno) void {
    _ = usys.replyTyped(shared.InitReply, chan, .{ .failed = .{ .err = @intFromEnum(e) } }, 0);
}

/// Services are units named after shared.ServiceId.
fn unitForService(id: u64) ?*Unit {
    const sid = std.enums.fromInt(shared.ServiceId, id) orelse return null;
    return unitByName(@tagName(sid));
}

// ---------------------------------------------------------- image store

/// Every program in the boot archive lands under img/ in the given view
/// as a content-addressed file (skipped when present — the name IS the
/// content), with its manifest beside it: `img/<name>.msh` names the
/// digest and what the program is handed (grant, give — from the
/// archive's unit file of the same name, when there is one). Init is
/// the installer because it holds the archive and the catalog; fssvc
/// knows nothing about programs and msh only reads.
fn installImages(view: u64) u64 {
    const b = fsc.attachBuf(view);
    const buf: [*]u8 = @ptrFromInt(b.va);
    const blob = archive();
    if (!fsc.fsMkdir(view, buf, "img")) {
        _ = usys.log(glog, "init: no img/ tier on this volume; store not installed");
        return 0;
    }
    var installed: u64 = 0;
    inline for (std.enums.values(shared.ImageId)) |id| {
        if (shared.marcFind(blob, shared.imagePath(id))) |image| {
            const digest = loader.digestHex(image);
            var path: [4 + shared.img_digest_hex_len]u8 = undefined;
            @memcpy(path[0..4], "img/");
            @memcpy(path[4..], &digest);
            if (fsc.fsStat(view, buf, &path) == null) {
                if (writeFile(view, buf, &path, image)) installed += 1;
            }
            writeManifest(view, buf, @tagName(id), &digest);
        }
    }
    _ = fsc.fsSync(view);
    if (installed > 0) _ = usys.log(glog, "init: installed images into img/ (content-addressed)");
    return installed;
}

/// The manifest is a record like a unit file's, with the image named by
/// its digest: `{ image: "<digest>", grant: [..], give: [..] }`. A
/// program without a unit file gets the digest alone — it is handed a
/// log cap and its console, nothing else.
fn writeManifest(view: u64, buf: [*]u8, name: []const u8, digest: *const [shared.img_digest_hex_len]u8) void {
    var scratch: [12 << 10]u8 = undefined;
    var sfba = std.heap.FixedBufferAllocator.init(&scratch);
    const a = sfba.allocator();
    var keys: [3][]const u8 = undefined;
    var vals: [3]Value = undefined;
    keys[0] = "image";
    vals[0] = .{ .str = digest };
    var n: usize = 1;
    var unit_path: [64]u8 = undefined;
    const up = cat3(&unit_path, shared.unit_dir, name, shared.unit_ext);
    if (shared.marcFind(archive(), up)) |text| {
        var mi = mshl.Interp.init(a, a, .{ .ctx = @ptrCast(&host_ctx), .call = noHost });
        if (mi.parseData(text)) |v| {
            if (v == .record) {
                if (v.record.get("grant")) |g| {
                    keys[n] = "grant";
                    vals[n] = g;
                    n += 1;
                }
                if (v.record.get("give")) |g| {
                    keys[n] = "give";
                    vals[n] = g;
                    n += 1;
                }
            }
        } else |_| {}
    }
    const rec: Value = .{ .record = .{ .keys = keys[0..n], .vals = vals[0..n] } };
    var out: std.ArrayList(u8) = .empty;
    mshl.writeData(rec, a, &out) catch return;
    out.append(a, '\n') catch return;
    var mpath: [64]u8 = undefined;
    const mp = cat3(&mpath, "img/", name, shared.img_manifest_ext);
    _ = writeFile(view, buf, mp, out.items);
}

fn cat3(out: []u8, a: []const u8, b: []const u8, c: []const u8) []const u8 {
    @memcpy(out[0..a.len], a);
    @memcpy(out[a.len .. a.len + b.len], b);
    @memcpy(out[a.len + b.len .. a.len + b.len + c.len], c);
    return out[0 .. a.len + b.len + c.len];
}

fn writeFile(view: u64, buf: [*]u8, path: []const u8, data: []const u8) bool {
    const fd = switch (fsc.fsOpen(view, buf, path, 1)) {
        .fd => |fd| fd,
        .err => return false,
    };
    defer fsc.fsClose(view, fd);
    if (!fsc.fsTruncate(view, fd, 0)) return false;
    var off: usize = 0;
    while (off < data.len) {
        const n = @min(shared.fs_max_io, data.len - off);
        if (!fsc.fsWriteAt(view, buf, fd, off, data[off .. off + n])) return false;
        off += n;
    }
    return true;
}

// ------------------------------------------------------------ flap drill

/// The supervision-restart drill: a service that dies on arrival, every
/// time. The budget bounds the restarts, backoff spaces them out, and when
/// the budget is spent init escalates to ITS supervisor by exiting — root
/// then applies its own policy, and the failure travels up the tree
/// instead of spinning at the bottom.
const flap_budget = 3;
const escalate_code = 77;

fn flapDrill(notif: u64) noreturn {
    _ = usys.log(glog, "init: flap drill — supervising a service that always crashes");
    var restarts: u64 = 0;
    var ctl = spawnFlapper();
    while (true) {
        _ = usys.notifyWait(notif);
        const st = usys.domainStat(ctl);
        if (st.err != .ok) usys.exit(115);
        if (st.data[0] != @intFromEnum(shared.DomainState.dead)) continue;

        if (restarts == flap_budget) {
            _ = usys.log(glog, "init: flapper exhausted its restart budget; escalating to my supervisor");
            usys.exit(escalate_code);
        }
        restarts += 1;
        usys.sleep(restarts); // backoff grows with each death
        _ = usys.capDrop(ctl);
        ctl = spawnFlapper();
        _ = usys.log(glog, "init: flapper died; restarted (budget shrinking)");
    }
}

fn spawnFlapper() u64 {
    if (!stage.load(boot_va, boot_len, .services)) usys.exit(119);
    const r = usys.spawn(spawner, stage.handle, 4, 0, shared.SpawnFlags.grant_log, usys.kbLimits(1 << 10, 4 << 10));
    if (r.err != .ok) usys.exit(116);
    return r.data[0];
}

// -------------------------------------------------------------- logging

fn logLine(prefix: []const u8, name: []const u8) void {
    var line: [96]u8 = undefined;
    const n = @min(prefix.len + name.len, line.len);
    @memcpy(line[0..prefix.len], prefix);
    @memcpy(line[prefix.len..n], name[0 .. n - prefix.len]);
    _ = usys.log(glog, line[0..n]);
}
