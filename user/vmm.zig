//! The virtual machine monitor: a userspace program that owns a VM. It
//! is handed the hypervisor capability and the boot archive, builds a
//! VM with 8M of RAM, copies the guest image into it, and runs the
//! vCPU, answering every exit: stores to the guest's UART (IPA
//! 0x09000000) become log lines, loads from it read as zero, WFI sleeps
//! a tick, HVC is logged, and PSCI power-off ends the run. It exits 0
//! only if the guest counted its three ticks and powered off — the
//! whole VM story in one program the kernel merely supervises.

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
        \\        .ascii  "vmm"
        \\        .space  13
        \\.global _ustart
        \\_ustart:
        \\        b       umain
    );
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// Grants: log in x0, the hypervisor cap at slot 1, the archive in x3/x4.
const hyp_h: u64 = @bitCast(shared.Handle{ .slot = 1, .generation = 1 });
const guest_image = "img/guest-hello";
const guest_uart: u64 = 0x0900_0000;
const ram_pages: u64 = 2048; // 8M

var line: [120]u8 = undefined;
var line_len: usize = 0;
var ticks_seen: u64 = 0;

export fn umain(log_h: u64, _: u64, _: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    const blob: []const u8 = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    const image = shared.marcFind(blob, guest_image) orelse {
        _ = usys.log(log_h, "vmm: guest image missing from the boot archive");
        usys.exit(130);
    };

    const c = usys.vmCreate(hyp_h, ram_pages);
    if (c.err != .ok) {
        _ = usys.log(log_h, "vmm: vm_create refused");
        usys.exit(131);
    }
    const vm_h = c.data[0];
    const ram: [*]u8 = @ptrFromInt(c.data[1]);
    @memcpy(ram[0..image.len], image);
    if (usys.vmSet(vm_h, shared.vm_ram_ipa, 0) != .ok) usys.exit(132);
    _ = usys.log(log_h, "vmm: guest loaded at IPA 0x40000000; entering EL1");

    var value: u64 = 0;
    var exits: u64 = 0;
    while (true) {
        const r = usys.vmRun(vm_h, value);
        if (r.err != .ok) usys.exit(133);
        exits += 1;
        value = 0;
        const kind: shared.VmExit = @enumFromInt(r.data[0]);
        switch (kind) {
            .mmio_write => {
                if (r.data[1] == guest_uart) {
                    uartByte(log_h, @truncate(r.data[3]));
                } else {
                    _ = usys.log(log_h, "vmm: guest wrote an address it does not have; ignored");
                }
            },
            .mmio_read => value = 0,
            .wfi => usys.sleep(1),
            .hvc => _ = usys.log(log_h, "vmm: guest hypercall (ignored)"),
            .interrupted => {},
            .poweroff => {
                _ = usys.log(log_h, "vmm: guest asked PSCI to power off; VM done");
                break;
            },
            .fault, .none => {
                _ = usys.log(log_h, "vmm: guest faulted; killing the VM");
                usys.exit(134);
            },
        }
    }
    _ = usys.capDrop(vm_h);
    if (ticks_seen != 3) usys.exit(135);
    usys.exit(0);
}

fn uartByte(log_h: u64, b: u8) void {
    if (b == '\n') {
        var out: [128]u8 = undefined;
        const prefix = "guest> ";
        @memcpy(out[0..prefix.len], prefix);
        @memcpy(out[prefix.len .. prefix.len + line_len], line[0..line_len]);
        _ = usys.log(log_h, out[0 .. prefix.len + line_len]);
        if (startsWith(line[0..line_len], "guest: tick ")) ticks_seen += 1;
        line_len = 0;
        return;
    }
    if (line_len < line.len) {
        line[line_len] = b;
        line_len += 1;
    }
}

fn startsWith(hay: []const u8, prefix: []const u8) bool {
    return hay.len >= prefix.len and eql(hay[0..prefix.len], prefix);
}

fn eql(a: []const u8, b: []const u8) bool {
    if (a.len != b.len) return false;
    for (a, b) |x, y| {
        if (x != y) return false;
    }
    return true;
}
