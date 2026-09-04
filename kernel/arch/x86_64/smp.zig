//! The cores the loader listed (Limine's MP response: parked, waiting for
//! a `goto_address`). Stage 1 runs the boot core only; bring-up is the
//! port's next stage. `currentIndex` maps this core's APIC id to its
//! position in the list, the index the scheduler uses.

const cpu = @import("cpu.zig");
const limine = @import("limine.zig");
const log = @import("../../log.zig");
const mem = @import("../../mem.zig");
const boot = @import("boot.zig");

const max = 8;
var apic_ids: [max]u32 = @splat(0);
var count: usize = 1;

pub fn note(mp: *limine.MpResponse) void {
    const cpus: [*]const u64 = @ptrFromInt(mem.physToVirt(@intFromPtr(mp.cpus) - boot.hhdm_offset));
    count = 0;
    // The boot core first, so it is index 0 whatever the firmware's order.
    apic_ids[0] = mp.bsp_lapic_id;
    count = 1;
    for (0..mp.cpu_count) |i| {
        const info = mem.physToPtr(*const limine.MpInfo, cpus[i] - boot.hhdm_offset);
        if (info.lapic_id == mp.bsp_lapic_id or count == max) continue;
        apic_ids[count] = info.lapic_id;
        count += 1;
    }
}

pub fn currentIndex() u32 {
    const me = cpu.apicId();
    for (apic_ids[0..count], 0..) |a, i| if (a == me) return @intCast(i);
    return 0;
}

pub fn bringUp() void {
    log.info("smp: {d} cores listed by the loader; running the boot core only (x86_64 stage 1)", .{count});
}
