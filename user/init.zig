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
//! lazily-started services), 1 = the flap drill, 2 = the system boot.
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

const max_units = 16;
const max_gives = 8;

const GiveKind = enum { unit, device, shm, secret, view, netview, self_init };

const Give = struct {
    tag: shared.CapTag,
    kind: GiveKind,
    name: []const u8 = "", // unit name, device name, archive path, fs path
    pages: u64 = 1,
    ro: bool = true,
};

const Certify = struct {
    root: []const u8,
    seed: []const u8,
    node: u64,
    flags: u64,
};

const Unit = struct {
    name: []const u8,
    image: shared.ImageId,
    arg: u64 = 0,
    kobj_kb: u64 = 1 << 10,
    user_kb: u64 = 4 << 10,
    flags: u64 = shared.SpawnFlags.grant_log,
    gives: [max_gives]Give = undefined,
    ngives: usize = 0,
    max_restarts: u64 = 0,
    eager: bool = false,
    essential: bool = false,
    install: bool = false,
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
};

var units: [max_units]Unit = undefined;
var nunits: usize = 0;
var glog: u64 = 0;
var stage: loader.Stage = undefined;
var boot_va: u64 = 0;
var boot_len: u64 = 0;
var front_a: u64 = 0;
var front_b: u64 = 0;
var devices: [shared.cap_tag_count]u64 = @splat(0); // mmio, irq, entropy from root

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
        if (nunits == max_units) break;
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
    if (r.get("budget")) |b| {
        if (b == .record) {
            if (b.record.get("kobj")) |k| u.kobj_kb = @intCast(@divTrunc(int(k) orelse 0, 1024));
            if (b.record.get("user")) |k| u.user_kb = @intCast(@divTrunc(int(k) orelse 0, 1024));
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
            } else if (gr.get("netview")) |x| {
                give.kind = .netview;
                give.name = str(x) orelse continue;
            } else if (gr.get("self") != null) {
                give.kind = .self_init;
            } else continue;
            u.gives[u.ngives] = give;
            u.ngives += 1;
        };
    }
    if (r.get("restart")) |rs| {
        if (rs == .record) {
            if (rs.record.get("max")) |m| u.max_restarts = @intCast(int(m) orelse 0);
        }
    }
    if (r.get("start")) |s| u.eager = std.mem.eql(u8, str(s) orelse "", "eager");
    if (r.get("essential")) |e| u.essential = e.truthy();
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
                .seed = str(c.record.get("seed")) orelse return null,
                .node = @intCast(int(c.record.get("node")) orelse 1),
                .flags = flags,
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
    const r = usys.spawn(spawner, stage.handle, u.arg, ch.data[0], u.flags | shared.SpawnFlags.chan_side_a, usys.kbLimits(u.kobj_kb, u.user_kb));
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
            return boot.giveCap(u.chan_b, g.tag, dep.chan_b);
        },
        .device => {
            const dtag = std.meta.stringToEnum(shared.CapTag, g.name) orelse return false;
            const cap = devices[@intFromEnum(dtag)];
            if (cap == 0) return false;
            return boot.giveCap(u.chan_b, g.tag, cap);
        },
        .shm => {
            const s = usys.shmCreate(g.pages);
            if (s.err != .ok) return false;
            const m = usys.shmMap(s.data[0]);
            if (m.err != .ok) return false;
            if (g.tag == .buf) {
                u.buf_h = s.data[0];
                u.buf_va = m.data[0];
            }
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
            const fs = unitByName("fs") orelse return false;
            if (!ensureUp(fs) or fs.buf_va == 0) return false;
            // A path of `arg` means the unit's argument text (run tools).
            const path = g.name;
            const view = fsc.fsDerive(fs.chan_b, @ptrFromInt(fs.buf_va), path, g.ro) orelse return false;
            const ok = boot.giveCap(u.chan_b, g.tag, view);
            _ = usys.capDrop(view);
            return ok;
        },
        .netview => {
            const net = unitByName(g.name) orelse return false;
            if (!ensureUp(net)) return false;
            switch (usys.callTypedCap(shared.NetReq, shared.NetResp, net.chan_b, .{
                .derive = .{ .ip_hi = 0, .ip_lo = 0, .port = 0 },
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
    }
}

/// Before go: compose the identity secret (node seed + the root's
/// cluster key) into the unit's buffer.
fn certifySecret(u: *Unit) bool {
    const c = u.certify.?;
    const root = unitByName(c.root) orelse return false;
    if (!ensureUp(root) or root.buf_va == 0 or u.buf_va == 0) return false;
    const seed = shared.marcFind(archive(), c.seed) orelse return false;
    if (seed.len != 32) return false;
    switch (usys.callTyped(shared.RootReq, shared.FabResp, root.chan_b, .cluster_key, 0)) {
        .ok => |rep| if (rep != .num) return false,
        .err => return false,
    }
    const dst: [*]volatile u8 = @ptrFromInt(u.buf_va);
    const pk: [*]const volatile u8 = @ptrFromInt(root.buf_va);
    for (0..32) |i| dst[i] = seed[i];
    for (0..32) |i| dst[32 + i] = pk[i];
    return boot.give(u.chan_b, .{ .secret = .{ .off = 0, .len = 64 } }, 0);
}

/// After go: the unit hands back its public key, the root signs it into
/// a certificate with the unit's authorizations, set_cert installs it
/// (opening the network — retried while the entropy pool is still
/// seeding).
fn certifyFinish(u: *Unit) bool {
    const c = u.certify.?;
    const root = unitByName(c.root) orelse return false;
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
    const ub: [*]volatile u8 = @ptrFromInt(u.buf_va);
    for (0..shared.fab_cert_len) |i| ub[i] = rb[i];
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

    // Root hands over the devices on our boot channel.
    const setup = boot.take(chan_h);
    devices = setup.caps;
    _ = usys.capDrop(chan_h);

    const notif = usys.notifyCreate();
    if (notif.err != .ok) usys.exit(110);
    if (usys.watchDeaths(notif.data[0]) != .ok) usys.exit(111);

    // arg 1: the flapping-service drill instead of the normal topology.
    if (arg == 1) flapDrill(notif.data[0]);

    loadUnits();
    const front = usys.chanCreate();
    if (front.err != .ok) usys.exit(112);
    front_a = front.data[0];
    front_b = front.data[1];

    if (arg == 2) system(notif.data[0]);
    demo(notif.data[0]);
}

/// The system boot: eager units start (pulling in everything they
/// need); init then serves its front channel forever, or until an
/// essential unit exits.
fn system(notif: u64) noreturn {
    _ = usys.log(glog, "init: system boot; starting eager units");
    for (units[0..nunits]) |*u| {
        if (u.eager and !ensureUp(u)) logLine("init: eager unit failed to start: ", u.name);
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
/// content), and img/index maps catalog names to digests. Init is the
/// installer because it holds the archive and the catalog; fssvc knows
/// nothing about programs and msh only reads.
fn installImages(view: u64) u64 {
    const b = fsc.attachBuf(view);
    const buf: [*]u8 = @ptrFromInt(b.va);
    const blob = archive();
    if (!fsc.fsMkdir(view, buf, "img")) {
        _ = usys.log(glog, "init: no img/ tier on this volume; store not installed");
        return 0;
    }
    var index: [2048]u8 = undefined;
    var ilen: usize = 0;
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
            const name = @tagName(id);
            @memcpy(index[ilen .. ilen + name.len], name);
            ilen += name.len;
            index[ilen] = ' ';
            ilen += 1;
            @memcpy(index[ilen .. ilen + digest.len], &digest);
            ilen += digest.len;
            index[ilen] = '\n';
            ilen += 1;
        }
    }
    _ = writeFile(view, buf, shared.img_index_path, index[0..ilen]);
    _ = fsc.fsSync(view);
    if (installed > 0) _ = usys.log(glog, "init: installed images into img/ (content-addressed)");
    return installed;
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
