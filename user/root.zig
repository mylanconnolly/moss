//! The root task: deliberately near-finished. It receives the boot grants
//! (debug log + spawn authority), starts the init service, supervises only
//! init, and otherwise stays out of the way. Init crashing must never take
//! the system's resource ledger with it — so the ledger-holder does nothing
//! else.
//!
//! Grant layout (fresh table, insert order log→spawner→entropy→windows):
//! log arrives in x0; spawner at slot 1; entropy at slot 2; the ECAM and
//! MMIO windows at slots 3 and 4 (when the machine has a PCI host). Root
//! hands the windows to the enumerator (pcisvc), collects the device
//! capabilities it registers, and forwards them to init over init's
//! boot channel, each filed by kind — root never uses them.

const shared = @import("shared");
const usys = @import("usys.zig");
const loader = @import("loader.zig");
const boot = @import("boot.zig");

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
const entropy_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });
const ecam_h: u64 = @bitCast(shared.Handle{ .slot = 3, .generation = 1 });
const mmio_h: u64 = @bitCast(shared.Handle{ .slot = 4, .generation = 1 });
const max_devices = 16;
var devices: [max_devices]struct { cap: u64, kind: u64 } = undefined;
var ndevices: usize = 0;
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

    enumerate(log_h);
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
    const ch = usys.chanCreate();
    if (ch.err != .ok) usys.exit(106);
    const r = usys.spawn(
        spawner,
        stage.handle,
        arg,
        ch.data[0],
        shared.SpawnFlags.grant_log | shared.SpawnFlags.grant_spawner | shared.SpawnFlags.grant_bootfs | shared.SpawnFlags.chan_side_a,
        usys.kbLimits(12 << 10, 64 << 10), // init's slice: 12MB kobj, 64MB user (its units nest inside)
    );
    _ = usys.capDrop(ch.data[0]);
    if (r.err != .ok) {
        _ = usys.log(log_h, "root: failed to spawn init");
        usys.exit(103);
    }
    // The devices go to init, which hands them to drivers per unit file.
    const b = ch.data[1];
    var ok = boot.giveCap(b, .entropy, entropy_h);
    for (devices[0..ndevices]) |dev| {
        if (!ok) break;
        ok = boot.giveDevice(b, dev.cap, dev.kind);
    }
    ok = ok and boot.give(b, .go, 0);
    if (!ok) {
        _ = usys.log(log_h, "root: init did not take its boot setup");
        usys.exit(107);
    }
    _ = usys.capDrop(b);
    return r.data[0];
}

/// Firmware's job, in a program: spawn the enumerator with the platform
/// windows and collect the device capabilities it registers. A machine
/// without a PCI host has no windows, and no devices.
fn enumerate(log_h: u64) void {
    if (usys.windowMap(ecam_h, 0, 0).err != .ok) return;
    if (!stage.load(blob_va, blob_len, .pcisvc)) {
        _ = usys.log(log_h, "root: pcisvc image missing from the boot archive");
        usys.exit(108);
    }
    const ch = usys.chanCreate();
    if (ch.err != .ok) usys.exit(109);
    const r = usys.spawn(spawner, stage.handle, 0, ch.data[0], shared.SpawnFlags.grant_log | shared.SpawnFlags.chan_side_a, usys.kbLimits(1 << 10, 2 << 10));
    _ = usys.capDrop(ch.data[0]);
    if (r.err != .ok) usys.exit(110);
    const b = ch.data[1];
    if (!(boot.giveCap(b, .ecam, ecam_h) and boot.giveCap(b, .mmio, mmio_h) and boot.give(b, .go, 0))) usys.exit(111);
    while (ndevices < max_devices) {
        switch (usys.callTypedCap(shared.PciReq, shared.PciResp, b, .next, 0)) {
            .ok => |ok| switch (ok.rep) {
                .device => |dv| {
                    if (ok.cap == 0) break;
                    devices[ndevices] = .{ .cap = ok.cap, .kind = dv.kind };
                    ndevices += 1;
                },
                .done => break,
            },
            .err => break,
        }
    }
    _ = usys.capDrop(b);
    _ = usys.capDrop(r.data[0]);
}
