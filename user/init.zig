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

const topology = [_]Entry{
    .{ .service = .logsvc, .image = .services, .arg = 1, .max_restarts = 5 },
    .{ .service = .greeter, .image = .services, .arg = 2, .max_restarts = 5 },
};

const Instance = struct {
    ctl: u64 = 0, // domain_ctl handle, 0 = never started
    chan_b: u64 = 0, // our keep-alive B cap for handing to clients
    chan_a_dropped: bool = true,
    restarts: u64 = 0,
    up: bool = false,
};

var instances: [topology.len]Instance = @splat(.{});
var glog: u64 = 0;

const svc_limits = usys.kbLimits(1 << 10, 4 << 10); // 1MB kobj, 4MB user per service

export fn umain(log_h: u64, _: u64, arg: u64) callconv(.c) noreturn {
    glog = log_h;

    const notif = usys.notifyCreate();
    if (notif.err != .ok) usys.exit(110);
    if (usys.watchDeaths(notif.data[0]) != .ok) usys.exit(111);

    // arg 1: the flapping-service drill instead of the normal topology.
    if (arg == 1) flapDrill(notif.data[0]);

    _ = usys.log(log_h, "init: up; topology loaded, nothing started (lazy)");

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
    for (&instances) |*inst| {
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
    for (&instances, 0..) |*inst, idx| {
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
    for (topology, 0..) |e, i| {
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
