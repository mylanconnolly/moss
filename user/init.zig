//! The init service: capability wiring + channel activation + supervision.
//! An ordinary restartable process — no special kernel status.
//!
//! - The service topology is a typed constant compiled into this binary.
//! - Services spawn lazily: the first connect() for a service starts it
//!   (channel activation, one level up: the connect blocks until the fresh
//!   instance can serve).
//! - Supervision is one-for-one with a restart budget and backoff: a death
//!   notification interrupts init's blocked recv (Errno.interrupted), the
//!   dead service is respawned on a fresh channel, and dependents re-wire
//!   by asking init to connect them again.
//!
//! Grant layout (insert order log→chan→spawner): log in x0; without a
//! channel grant spawner sits at slot 1 (demo boot), with one it shifts
//! to slot 2 (shell boot, serveFront mode).

const std = @import("std");
const shared = @import("shared");
const usys = @import("usys.zig");
const loader = @import("loader.zig");
const fsc = @import("fsclient.zig");

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

// Grant insert order is log -> chan -> spawner: without a channel grant
// (the demo boot) spawner sits at slot 1; with one (the shell boot,
// serveFront) it shifts to slot 2. Set at startup.
var spawner: u64 = @bitCast(shared.Handle{ .slot = 1, .generation = 1 });

/// The topology: what init can activate, and how stubborn it is about
/// keeping each entry alive. This is the compiled-in typed constant; it
/// loads from disk in Phase 9 with the same type.
const Entry = struct {
    service: shared.ServiceId,
    image: shared.ImageId,
    arg: u64,
    max_restarts: u64,
};

const default_topology = [_]Entry{
    .{ .service = .logsvc, .image = .services, .arg = 1, .max_restarts = 5 },
    .{ .service = .greeter, .image = .services, .arg = 2, .max_restarts = 5 },
};

/// Live topology: the compiled-in default, unless the boot filesystem
/// carries topology.txt — the same typed entries, loaded from disk.
var topology: [8]Entry = undefined;
var topology_len: usize = 0;

/// topology.txt: one "service image arg max_restarts" line per entry, all
/// numeric (shared.ServiceId / shared.ImageId values).
fn loadTopology(blob_va: u64, blob_len: u64) void {
    for (default_topology, 0..) |e, i| topology[i] = e;
    topology_len = default_topology.len;
    if (blob_len < 4) return;
    const blob = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    if (!eqBytes(blob[0..4], shared.marc_magic)) return;

    var off: usize = 4;
    while (off + 8 <= blob.len) {
        const plen = leu32(blob[off..]);
        const dlen = leu32(blob[off + 4 ..]);
        off += 8;
        if (off + plen + dlen > blob.len) return;
        const path = blob[off .. off + plen];
        const data = blob[off + plen .. off + plen + dlen];
        off += plen + dlen;
        if (!eqBytes(path, "conf/init.topology")) continue;

        var n: usize = 0;
        var lines = data;
        while (lines.len > 0 and n < topology.len) {
            var eol: usize = 0;
            while (eol < lines.len and lines[eol] != '\n') eol += 1;
            const line = lines[0..eol];
            lines = if (eol == lines.len) "" else lines[eol + 1 ..];
            var nums: [4]u64 = undefined;
            if (!parseNums(line, &nums)) continue;
            topology[n] = .{
                .service = @enumFromInt(nums[0]),
                .image = @enumFromInt(nums[1]),
                .arg = nums[2],
                .max_restarts = nums[3],
            };
            n += 1;
        }
        if (n > 0) {
            topology_len = n;
            _ = usys.log(glog, "init: topology loaded from boot filesystem");
        }
        return;
    }
}

fn parseNums(line: []const u8, out: *[4]u64) bool {
    var i: usize = 0;
    for (out) |*v| {
        while (i < line.len and line[i] == ' ') i += 1;
        if (i >= line.len or line[i] < '0' or line[i] > '9') return false;
        v.* = 0;
        while (i < line.len and line[i] >= '0' and line[i] <= '9') : (i += 1) {
            v.* = v.* * 10 + (line[i] - '0');
        }
    }
    return true;
}

fn eqBytes(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}

fn leu32(b: []const u8) u32 {
    return @as(u32, b[0]) | (@as(u32, b[1]) << 8) | (@as(u32, b[2]) << 16) | (@as(u32, b[3]) << 24);
}

const Instance = struct {
    ctl: u64 = 0, // domain_ctl handle, 0 = never started
    chan_b: u64 = 0, // our keep-alive B cap for handing to clients
    chan_a_dropped: bool = true,
    restarts: u64 = 0,
    up: bool = false,
    /// Deliberately stopped: supervision leaves it down; connect revives.
    stopped: bool = false,
};

var instances: [8]Instance = @splat(.{});
var glog: u64 = 0;
var stage: loader.Stage = undefined;
var boot_va: u64 = 0;
var boot_len: u64 = 0;

const svc_limits = usys.kbLimits(1 << 10, 4 << 10); // 1MB kobj, 4MB user per service

export fn umain(log_h: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;
    boot_va = blob_va;
    boot_len = blob_len;
    stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(118);

    const notif = usys.notifyCreate();
    if (notif.err != .ok) usys.exit(110);
    if (usys.watchDeaths(notif.data[0]) != .ok) usys.exit(111);

    // arg 1: the flapping-service drill instead of the normal topology.
    if (arg == 1) flapDrill(notif.data[0]);

    loadTopology(blob_va, blob_len);
    _ = usys.log(log_h, "init: up; topology present, nothing started (lazy)");

    if (chan_h != 0) spawner = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });

    // Granted-channel mode: a spawner (the shell boot) hands init its
    // front channel's serving side; init serves it until every client cap
    // dies, then revokes its services and exits — no demo worker.
    if (chan_h != 0) serveFront(chan_h, notif.data[0]);

    // Front channel: workers call here. We keep both ends; worker gets a
    // copy of B at spawn.
    const front = usys.chanCreate();
    if (front.err != .ok) usys.exit(112);
    const front_a = front.data[0];
    const front_b = front.data[1];

    if (!stage.load(boot_va, boot_len, .services)) usys.exit(119);
    const worker = usys.spawn(spawner, stage.handle, 3, front_b, shared.SpawnFlags.grant_log, svc_limits);
    if (worker.err != .ok) usys.exit(113);

    var workers_done = false;
    while (true) {
        const r = usys.recvMsg(front_a);
        switch (r.err) {
            .interrupted => {
                _ = usys.notifyWait(notif.data[0]);
                superviseDeaths();
                if (workerFinished(worker.data[0])) {
                    workers_done = true;
                    break;
                }
            },
            .ok => handleRequest(front_a, r),
            else => usys.exit(114),
        }
    }

    // Crash-only for everyone else, orderly exit for init: revoke what we
    // started and report.
    for (instances[0..topology_len]) |*inst| {
        if (inst.up) _ = usys.domainDestroy(inst.ctl);
    }
    _ = usys.log(glog, "init: worker finished; services revoked; exiting");
    usys.exit(0);
}

fn serveFront(front_a: u64, notif: u64) noreturn {
    while (true) {
        const r = usys.recvMsg(front_a);
        switch (r.err) {
            .interrupted => {
                _ = usys.notifyWait(notif);
                superviseDeaths();
            },
            .ok => handleRequest(front_a, r),
            .peer_dead => break,
            else => usys.exit(117),
        }
    }
    for (instances[0..topology_len]) |*inst| {
        if (inst.up) _ = usys.domainDestroy(inst.ctl);
    }
    _ = usys.log(glog, "init: front channel closed; services revoked; exiting");
    usys.exit(0);
}

fn handleRequest(front_a: u64, r: usys.IpcResult) void {
    const req = shared.decodeMsg(shared.InitRequest, r.data) orelse {
        _ = usys.replyTyped(shared.InitReply, front_a, .{
            .failed = .{ .err = @intFromEnum(shared.Errno.bad_arg) },
        }, 0);
        return;
    };
    switch (req) {
        .connect => |c| {
            const idx = findService(c.service) orelse {
                _ = usys.replyTyped(shared.InitReply, front_a, .{
                    .failed = .{ .err = @intFromEnum(shared.Errno.bad_arg) },
                }, 0);
                return;
            };
            const inst = &instances[idx];
            // Never hand out a channel to a corpse: a death we have not yet
            // processed shows up here as a dead instance.
            if (inst.up and inst.ctl != 0) {
                const st = usys.domainStat(inst.ctl);
                if (st.err == .ok and st.data[0] == @intFromEnum(shared.DomainState.dead)) {
                    inst.up = false;
                    inst.restarts += 1;
                }
            }
            if (!inst.up) {
                if (!activate(idx)) {
                    _ = usys.replyTyped(shared.InitReply, front_a, .{
                        .failed = .{ .err = @intFromEnum(shared.Errno.no_space) },
                    }, 0);
                    return;
                }
            }
            inst.stopped = false; // connect doubles as (re)start
            _ = usys.replyTyped(shared.InitReply, front_a, .connected, inst.chan_b);
        },
        .status => |q| {
            const idx = findService(q.service) orelse {
                _ = usys.replyTyped(shared.InitReply, front_a, .{
                    .failed = .{ .err = @intFromEnum(shared.Errno.bad_arg) },
                }, 0);
                return;
            };
            const inst = &instances[idx];
            // Refresh liveness so status never reports a corpse as up.
            if (inst.up and inst.ctl != 0) {
                const st = usys.domainStat(inst.ctl);
                if (st.err == .ok and st.data[0] == @intFromEnum(shared.DomainState.dead)) {
                    inst.up = false;
                }
            }
            _ = usys.replyTyped(shared.InitReply, front_a, .{ .svc_status = .{
                .up = @intFromBool(inst.up),
                .restarts = inst.restarts,
                .max_restarts = topology[idx].max_restarts,
            } }, 0);
        },
        .install => {
            if (r.cap == 0) {
                _ = usys.replyTyped(shared.InitReply, front_a, .{
                    .failed = .{ .err = @intFromEnum(shared.Errno.bad_arg) },
                }, 0);
                return;
            }
            const n = installImages(r.cap);
            _ = usys.replyTyped(shared.InitReply, front_a, .{ .installed = .{ .n = n } }, 0);
        },
        .stop => |q| {
            const idx = findService(q.service) orelse {
                _ = usys.replyTyped(shared.InitReply, front_a, .{
                    .failed = .{ .err = @intFromEnum(shared.Errno.bad_arg) },
                }, 0);
                return;
            };
            const inst = &instances[idx];
            if (inst.up and inst.ctl != 0) _ = usys.domainDestroy(inst.ctl);
            inst.up = false;
            inst.stopped = true;
            _ = usys.replyTyped(shared.InitReply, front_a, .stopped, 0);
        },
    }
}

/// The image store installer: every program in the boot archive lands in
/// the granted `img/` view as a content-addressed file (skipped when
/// already present — the name IS the content), and `index` maps catalog
/// names to digests. Init is the installer because init is the thing
/// that already holds the archive and knows the catalog; fssvc knows
/// nothing about programs and msh only reads.
fn installImages(view: u64) u64 {
    const b = fsc.attachBuf(view);
    const buf: [*]u8 = @ptrFromInt(b.va);
    const blob = @as([*]const u8, @ptrFromInt(boot_va))[0..boot_len];
    var index: [2048]u8 = undefined;
    var ilen: usize = 0;
    var installed: u64 = 0;
    inline for (std.enums.values(shared.ImageId)) |id| {
        if (shared.marcFind(blob, shared.imagePath(id))) |image| {
            const digest = loader.digestHex(image);
            if (fsc.fsStat(view, buf, &digest) == null) {
                if (writeFile(view, buf, &digest, image)) installed += 1;
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
    _ = writeFile(view, buf, "index", index[0..ilen]);
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

/// Channel activation: first use starts the service.
fn activate(idx: usize) bool {
    const entry = topology[idx];
    const inst = &instances[idx];

    const ch = usys.chanCreate();
    if (ch.err != .ok) return false;
    if (!stage.load(boot_va, boot_len, entry.image)) {
        _ = usys.log(glog, "init: service image missing from the boot archive");
        return false;
    }
    const r = usys.spawn(
        spawner,
        stage.handle,
        entry.arg,
        ch.data[0],
        shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a,
        svc_limits,
    );
    if (r.err != .ok) return false;
    // The service serves side A; we keep B for wiring clients, and drop our
    // own A cap so the service's death closes the channel.
    _ = usys.capDrop(ch.data[0]);
    if (inst.ctl != 0) _ = usys.capDrop(inst.ctl);
    if (inst.chan_b != 0) _ = usys.capDrop(inst.chan_b);
    inst.ctl = r.data[0];
    inst.chan_b = ch.data[1];
    inst.up = true;
    if (inst.restarts == 0) {
        _ = usys.log(glog, "init: lazily started a service on first use");
    }
    return true;
}

/// One-for-one supervision with budget + backoff.
fn superviseDeaths() void {
    for (instances[0..topology_len], 0..) |*inst, idx| {
        if (!inst.up or inst.ctl == 0 or inst.stopped) continue;
        const st = usys.domainStat(inst.ctl);
        if (st.err != .ok) continue;
        if (st.data[0] != @intFromEnum(shared.DomainState.dead)) continue;

        inst.up = false;
        if (inst.restarts >= topology[idx].max_restarts) {
            _ = usys.log(glog, "init: service exceeded restart budget; leaving it down");
            continue;
        }
        inst.restarts += 1;
        usys.sleep(inst.restarts); // linear backoff, one tick per prior death
        if (activate(idx)) {
            _ = usys.log(glog, "init: service died; restarted it (one-for-one)");
        }
    }
}

fn workerFinished(worker_ctl: u64) bool {
    const st = usys.domainStat(worker_ctl);
    if (st.err != .ok) return false;
    return st.data[0] == @intFromEnum(shared.DomainState.dead);
}

fn findService(id: u64) ?usize {
    for (topology[0..topology_len], 0..) |e, i| {
        if (@intFromEnum(e.service) == id) return i;
    }
    return null;
}

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
    const r = usys.spawn(spawner, stage.handle, 4, 0, shared.SpawnFlags.grant_log, svc_limits);
    if (r.err != .ok) usys.exit(116);
    return r.data[0];
}
