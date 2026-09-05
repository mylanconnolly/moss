//! The PCI enumerator: what firmware would have done, in userspace. It
//! is handed the platform's ECAM window and its 32-bit MMIO window as
//! capabilities (the kernel minted them from the devicetree, nothing
//! more), walks bus 0, sizes and places every memory BAR in the window,
//! enables decoding and bus mastering, finds the BAR the virtio
//! structures live in and the MSI-X capability, and registers each
//! endpoint with the kernel — which answers with a device capability,
//! and with the LPI it routed and the doorbell to aim at, so this
//! program programs the MSI-X entry too. Then it serves the caps to
//! whoever spawned it (`PciReq.next` until `done`), or, told to (arg 1),
//! just exits once everything is registered: the kernel's own drills
//! only need the table filled.
//!
//! Trust: the holder of the ECAM window can describe devices to the
//! kernel however it likes. That holder is root's delegate, at the
//! level that dispenses every device anyway.

const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("pcisvc"));
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

const virtio_vendor = 0x1af4;
const virtio_modern_base = 0x1040;
const max_devices = 16;

var ecam_h: u64 = 0;
var mmio_h: u64 = 0;
var ecam_va: u64 = 0;
var mmio_base: u64 = 0;
var mmio_size: u64 = 0;
var mmio_next: u64 = 0;

const Found = struct { cap: u64 = 0, kind: u64 = 0 };
var found: [max_devices]Found = @splat(.{});
var nfound: usize = 0;

export fn umain(log_h: u64, chan_h: u64, arg: u64) callconv(.c) noreturn {
    const setup = boot.take(chan_h);
    ecam_h = setup.cap(.ecam);
    mmio_h = setup.cap(.mmio);
    if (ecam_h == 0 or mmio_h == 0) {
        _ = usys.log(log_h, "pcisvc: not handed the ECAM and MMIO windows; nothing to enumerate");
        usys.exit(0);
    }
    // Bus 0's config space (32 slots x 8 functions x 4K = 1M).
    const e = usys.windowMap(ecam_h, 0, 256);
    if (e.err != .ok) usys.exit(160);
    ecam_va = e.data[0];
    const m = usys.windowMap(mmio_h, 0, 0);
    if (m.err != .ok) usys.exit(161);
    mmio_base = m.data[1];
    mmio_size = m.data[2];
    mmio_next = mmio_base;

    var slot: u8 = 0;
    while (slot < 32) : (slot += 1) probe(log_h, slot);
    if (nfound == 0) _ = usys.log(log_h, "pcisvc: no endpoints on bus 0");
    if (arg == 1) usys.exit(0);

    // Serve the devices to the spawner, in enumeration order.
    var next: usize = 0;
    while (true) {
        const r = usys.recvMsg(chan_h);
        if (r.err == .peer_dead) usys.exit(0);
        if (r.err != .ok) usys.exit(162);
        const req = shared.decodeMsg(shared.PciReq, r.data) orelse continue;
        switch (req) {
            .next => {
                if (next < nfound) {
                    _ = usys.replyTyped(shared.PciResp, chan_h, .{ .device = .{ .kind = found[next].kind } }, found[next].cap);
                    next += 1;
                } else {
                    _ = usys.replyTyped(shared.PciResp, chan_h, .done, 0);
                }
            },
        }
    }
}

fn cfg(comptime T: type, slot: u8, off: u64) *volatile T {
    return @ptrFromInt(ecam_va + (@as(u64, slot) << 15) + off);
}

fn probe(log_h: u64, slot: u8) void {
    const vendor = cfg(u16, slot, 0).*;
    if (vendor == 0xffff) return;
    const device = cfg(u16, slot, 2).*;
    const class = cfg(u32, slot, 8).* >> 16;
    const header = cfg(u8, slot, 0xe).* & 0x7f;
    if (header != 0 or class == 0x0600) return; // bridges, the host bridge
    if (nfound == max_devices) return;

    // BARs: size by writing all-ones, then place, size-aligned, in the
    // 32-bit window. 64-bit BARs take two slots; I/O BARs are ignored.
    var bars: [6]struct { pa: u64, len: u64 } = @splat(.{ .pa = 0, .len = 0 });
    var i: u64 = 0;
    while (i < 6) {
        const off = 0x10 + i * 4;
        const r = cfg(u32, slot, off);
        const orig = r.*;
        r.* = 0xffff_ffff;
        const mask = r.*;
        r.* = orig;
        if (mask == 0 or mask & 1 != 0) {
            i += 1;
            continue;
        }
        const is64 = (mask >> 1) & 3 == 2;
        var size_mask: u64 = mask & ~@as(u32, 0xf);
        var orig_pa: u64 = orig & ~@as(u32, 0xf);
        if (is64) {
            const rh = cfg(u32, slot, off + 4);
            const origh = rh.*;
            rh.* = 0xffff_ffff;
            size_mask |= @as(u64, rh.*) << 32;
            rh.* = origh;
            orig_pa |= @as(u64, origh) << 32;
        } else {
            size_mask |= 0xffff_ffff_0000_0000;
        }
        const size = ~size_mask + 1;
        const align_to = @max(size, 4096);
        // Firmware's placement stands when it has one inside the window
        // (UEFI assigns every BAR; the display's framebuffer is one of
        // them, and the kernel is already drawing there). A BAR firmware
        // left empty — every BAR on a devicetree machine — is placed
        // here, from the window's base up.
        const keep = orig_pa != 0 and orig_pa % align_to == 0 and orig_pa >= mmio_base and orig_pa + size <= mmio_base + mmio_size;
        const pa = if (keep) orig_pa else (mmio_next + align_to - 1) & ~(align_to - 1);
        if (pa + size > mmio_base + mmio_size) return;
        if (!keep) {
            r.* = @truncate(pa);
            if (is64) cfg(u32, slot, off + 4).* = @truncate(pa >> 32);
            mmio_next = pa + size;
        }
        bars[i] = .{ .pa = pa, .len = size };
        i += if (is64) 2 else 1;
    }
    cfg(u16, slot, 4).* = cfg(u16, slot, 4).* | 0x6; // memory decoding + bus master

    var bar_index: u8 = 0xff;
    var msix_cap: u64 = 0;
    var msix_table: u64 = 0;
    if (cfg(u16, slot, 6).* & 0x10 != 0) {
        var ptr: u64 = cfg(u8, slot, 0x34).* & 0xfc;
        var guard: u32 = 0;
        while (ptr != 0 and guard < 48) : (guard += 1) {
            const id = cfg(u8, slot, ptr).*;
            if (id == 0x09 and cfg(u8, slot, ptr + 3).* == 1 and bar_index == 0xff) {
                bar_index = cfg(u8, slot, ptr + 4).*;
            } else if (id == 0x11) {
                msix_cap = ptr;
                const tab = cfg(u32, slot, ptr + 4).*;
                const bir = tab & 7;
                if (bir < 6 and bars[bir].len != 0) msix_table = bars[bir].pa + (tab & ~@as(u32, 7));
            }
            ptr = cfg(u8, slot, ptr + 1).* & 0xfc;
        }
    }
    const pin = cfg(u8, slot, 0x3d).*;
    const kind: u64 = if (vendor == virtio_vendor and device >= virtio_modern_base and device < virtio_modern_base + shared.device_kind_count)
        device - virtio_modern_base
    else
        0;
    const bar = if (bar_index < 6) bars[bar_index] else bars[0];

    const msix_usable = msix_cap != 0 and msix_table != 0 and msix_table >= mmio_base;
    const reg = usys.deviceRegister(ecam_h, @as(u64, slot) << 3, kind, bar.pa, bar.len, @as(u64, pin) | (@as(u64, if (bar_index < 6) bar_index else 0) << 8) | (@as(u64, @intFromBool(msix_usable)) << 16));
    if (reg.err != .ok) {
        _ = usys.log(log_h, "pcisvc: the kernel refused a device registration");
        return;
    }
    const dev_cap = reg.data[0];
    const lpi = reg.data[1];
    const doorbell = reg.data[2];
    const msi_data = reg.data[3];
    var msi = false;
    if (lpi != 0 and msix_usable) {
        // MSI-X entry 0: the doorbell and the data word the kernel named
        // (the ITS event, or the vector); enable, unmask.
        const page = usys.windowMap(mmio_h, (msix_table - mmio_base) / 4096, 1);
        if (page.err == .ok) {
            const entry: [*]volatile u32 = @ptrFromInt(page.data[0] + (msix_table & 0xfff));
            entry[0] = @truncate(doorbell);
            entry[1] = @truncate(doorbell >> 32);
            entry[2] = @truncate(msi_data);
            entry[3] = 0;
            const mc = cfg(u16, slot, msix_cap + 2);
            mc.* = (mc.* | 0x8000) & ~@as(u16, 0x4000);
            msi = true;
        }
    }
    found[nfound] = .{ .cap = dev_cap, .kind = kind };
    nfound += 1;
    report(log_h, slot, vendor, device, kind, bar.pa, bar.len, if (msi) lpi else 0);
}

fn report(log_h: u64, slot: u8, vendor: u16, device: u16, kind: u64, bar_pa: u64, bar_len: u64, lpi: u64) void {
    var m: [120]u8 = undefined;
    var n: usize = 0;
    n = put(&m, n, "pcisvc: 00:");
    n = putNum(&m, n, slot);
    n = put(&m, n, ".0 ");
    n = putHex(&m, n, vendor);
    n = put(&m, n, ":");
    n = putHex(&m, n, device);
    n = put(&m, n, " ");
    n = put(&m, n, switch (kind) {
        1 => "net",
        2 => "blk",
        3 => "console",
        4 => "rng",
        else => "other",
    });
    n = put(&m, n, " bar=0x");
    n = putHex(&m, n, bar_pa);
    n = put(&m, n, "+");
    n = putNum(&m, n, bar_len >> 10);
    n = put(&m, n, "K ");
    if (lpi != 0) {
        n = put(&m, n, "msi-x lpi ");
        n = putNum(&m, n, lpi);
    } else {
        n = put(&m, n, "intx");
    }
    _ = usys.log(log_h, m[0..n]);
}

fn put(buf: []u8, at: usize, s: []const u8) usize {
    var n = at;
    for (s) |c| {
        if (n == buf.len) break;
        buf[n] = c;
        n += 1;
    }
    return n;
}

fn putNum(buf: []u8, at: usize, v: u64) usize {
    var digits: [20]u8 = undefined;
    var d: usize = 0;
    var x = v;
    while (true) {
        digits[d] = '0' + @as(u8, @intCast(x % 10));
        d += 1;
        x /= 10;
        if (x == 0) break;
    }
    var n = at;
    while (d > 0) {
        d -= 1;
        if (n == buf.len) break;
        buf[n] = digits[d];
        n += 1;
    }
    return n;
}

fn putHex(buf: []u8, at: usize, v: u64) usize {
    var digits: [16]u8 = undefined;
    var d: usize = 0;
    var x = v;
    while (true) {
        const nib: u8 = @truncate(x & 0xf);
        digits[d] = if (nib < 10) '0' + nib else 'a' + nib - 10;
        d += 1;
        x >>= 4;
        if (x == 0) break;
    }
    var n = at;
    while (d > 0) {
        d -= 1;
        if (n == buf.len) break;
        buf[n] = digits[d];
        n += 1;
    }
    return n;
}
