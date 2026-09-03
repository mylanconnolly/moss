//! A ring of kernel events, recorded without locks or logging (a tick's
//! worth of cost), dumped only when something went wrong — the hang
//! watchdog prints it. Logging in a race's window moves the race;
//! this does not.

const log = @import("log.zig");
const sched = @import("sched.zig");

pub const Event = enum(u8) {
    none,
    /// The reaper finished a domain's teardown and signaled its watcher
    /// (a = domain id, b = slot index).
    reaper_signal,
    /// domain_stat answered (a = target domain id, b = its state).
    domain_stat,
    /// A domain began teardown (a = domain id).
    destroy,
    /// ipc.signal on a notification (a = notif index, b = path: 0 none,
    /// 1 woke a waiter, 2 interrupted a bound recv, 3 bound recv NOT
    /// interrupted — latched for its next recv).
    signal,
    /// A watcher-bearing domain finished teardown but had no watcher to
    /// signal (a = domain id): the death nobody will hear.
    no_watcher,
    /// A domain was spawned (a = domain id, b = 1 if it has a watcher).
    spawn,
};

const Entry = struct {
    seq: u64 = 0,
    tick: u64 = 0,
    event: Event = .none,
    a: u64 = 0,
    b: u64 = 0,
    who: [12]u8 = @splat(0),
};

const size = 1024;
var ring: [size]Entry = @splat(.{});
var next: u64 = 0;

pub fn record(event: Event, a: u64, b: u64) void {
    const i = @atomicRmw(u64, &next, .Add, 1, .monotonic);
    const e = &ring[i % size];
    e.seq = i + 1;
    e.tick = sched.globalTicks();
    e.event = event;
    e.a = a;
    e.b = b;
    const name = sched.currentName();
    const n = @min(name.len, e.who.len);
    e.who = @splat(0);
    @memcpy(e.who[0..n], name[0..n]);
}

/// Oldest to newest.
pub fn dump() void {
    const total = @atomicLoad(u64, &next, .monotonic);
    const first = if (total > size) total - size else 0;
    var i = first;
    while (i < total) : (i += 1) {
        const e = &ring[i % size];
        if (e.seq != i + 1) continue; // being written
        const wl = for (e.who, 0..) |c, k| {
            if (c == 0) break k;
        } else e.who.len;
        log.info("trace[{d}] t={d} {s}: {t} a={d} b={d}", .{ e.seq, e.tick, e.who[0..wl], e.event, e.a, e.b });
    }
}
