//! The root task: deliberately near-finished. It receives the boot grants
//! (debug log + spawn authority), starts the init service, supervises only
//! init, and otherwise stays out of the way. Init crashing must never take
//! the system's resource ledger with it — so the ledger-holder does nothing
//! else.
//!
//! Grant layout (fresh table, insert order log→spawner): log handle arrives
//! in x0; the spawner cap sits at slot 1, generation 1.

const shared = @import("shared");
const usys = @import("usys.zig");
const loader = @import("loader.zig");

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
        \\        .ascii  "root"
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

const spawner: u64 = @bitCast(shared.Handle{ .slot = 1, .generation = 1 });
const max_init_restarts = 1;

var stage: loader.Stage = undefined;
var blob_va: u64 = 0;
var blob_len: u64 = 0;

export fn umain(log_h: u64, _: u64, arg: u64, bva: u64, blen: u64) callconv(.c) noreturn {
    _ = usys.log(log_h, "root: up; starting init");
    blob_va = bva;
    blob_len = blen;
    stage = loader.Stage.init(loader.Stage.default_pages) orelse usys.exit(104);

    const notif = usys.notifyCreate();
    if (notif.err != .ok) usys.exit(100);
    if (usys.watchDeaths(notif.data[0]) != .ok) usys.exit(101);

    var restarts: u64 = 0;
    var init_ctl = spawnInit(log_h, arg);
    while (true) {
        _ = usys.notifyWait(notif.data[0]);
        const st = usys.domainStat(init_ctl);
        if (st.err != .ok) usys.exit(102);
        if (st.data[0] != @intFromEnum(shared.DomainState.dead)) continue;

        if (st.data[1] == 0) {
            _ = usys.log(log_h, "root: init exited cleanly; done");
            usys.exit(0);
        }
        if (restarts == max_init_restarts) {
            _ = usys.log(log_h, "root: init keeps dying; giving up");
            usys.exit(st.data[1]);
        }
        restarts += 1;
        _ = usys.log(log_h, "root: init died; restarting it");
        _ = usys.capDrop(init_ctl);
        init_ctl = spawnInit(log_h, arg);
    }
}

fn spawnInit(log_h: u64, arg: u64) u64 {
    if (!stage.load(blob_va, blob_len, .init)) {
        _ = usys.log(log_h, "root: init image missing from the boot archive");
        usys.exit(105);
    }
    const r = usys.spawn(
        spawner,
        stage.handle,
        arg,
        0,
        shared.SpawnFlags.grant_log | shared.SpawnFlags.grant_spawner | shared.SpawnFlags.grant_bootfs,
        usys.kbLimits(8 << 10, 24 << 10), // init's slice: 8MB kobj, 24MB user
    );
    if (r.err != .ok) {
        _ = usys.log(log_h, "root: failed to spawn init");
        usys.exit(103);
    }
    return r.data[0];
}
