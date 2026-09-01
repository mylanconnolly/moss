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
//! Grant layout (insert order log→spawner): log in x0, spawner at slot 1.

const shared = @import("shared");
const usys = @import("usys.zig");

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
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const spawner: u64 = @bitCast(shared.Handle{ .slot = 1, .generation = 1 });

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
};

var instances: [8]Instance = @splat(.{});
var glog: u64 = 0;

const svc_limits = usys.kbLimits(1 << 10, 4 << 10); // 1MB kobj, 4MB user per service

export fn umain(log_h: u64, _: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    glog = log_h;

    const notif = usys.notifyCreate();
    if (notif.err != .ok) usys.exit(110);
    if (usys.watchDeaths(notif.data[0]) != .ok) usys.exit(111);

    // arg 1: the flapping-service drill instead of the normal topology.
    if (arg == 1) flapDrill(notif.data[0]);

    loadTopology(blob_va, blob_len);
    _ = usys.log(log_h, "init: up; topology present, nothing started (lazy)");

    // Front channel: workers call here. We keep both ends; worker gets a
    // copy of B at spawn.
    const front = usys.chanCreate();
    if (front.err != .ok) usys.exit(112);
    const front_a = front.data[0];
    const front_b = front.data[1];

    const worker = usys.spawn(spawner, .services, 3, front_b, shared.SpawnFlags.grant_log, svc_limits);
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
            _ = usys.replyTyped(shared.InitReply, front_a, .connected, inst.chan_b);
        },
    }
}

/// Channel activation: first use starts the service.
fn activate(idx: usize) bool {
    const entry = topology[idx];
    const inst = &instances[idx];

    const ch = usys.chanCreate();
    if (ch.err != .ok) return false;
    const r = usys.spawn(
        spawner,
        entry.image,
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
        if (!inst.up or inst.ctl == 0) continue;
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
    const r = usys.spawn(spawner, .services, 4, 0, shared.SpawnFlags.grant_log, svc_limits);
    if (r.err != .ok) usys.exit(116);
    return r.data[0];
}
