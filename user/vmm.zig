//! The virtual machine monitor: a userspace program that owns a VM. It
//! is handed the hypervisor capability and the boot archive, builds a
//! VM, loads a guest into it, and runs the vCPU, answering every exit.
//! Two guests, by argument:
//!   0  the bare-metal hello guest (img/guest-hello): a UART at IPA
//!      0x09000000 whose stores become log lines, PSCI power-off ends
//!      the run; exits 0 only after three timer ticks and the power-off.
//!   1  a moss kernel (img/moss-guest) booted by the Linux Image
//!      protocol: loaded at RAM+0x80000 with a devicetree the VMM writes
//!      (memory, `profile=guest`, PSCI over HVC) and handed a PL011, a
//!      GICv3 distributor and one redistributor — all emulated here as
//!      trapped MMIO — while its timer and CPU interface are the real
//!      virtual ones. Its console lines are relayed as `guest| ...`.
//! Either way the VMM exits 0 only when the guest powered itself off.

const shared = @import("shared");
const usys = @import("usys.zig");
const boot = @import("boot.zig");

comptime {
    asm (usys.imageHeader("vmm"));
}

pub const panic = @import("std").debug.FullPanic(uPanic);

fn uPanic(_: []const u8, _: ?usize) noreturn {
    usys.exit(255);
}

// Grants: log in x0, the boot channel in x1, the hypervisor cap at slot
// 2, the archive in x3/x4; devices to pass through arrive over the boot
// channel.
const hyp_h: u64 = @bitCast(shared.Handle{ .slot = 2, .generation = 1 });
const uart_base: u64 = 0x0900_0000;
const gicd_base: u64 = 0x0800_0000;
const gicr_base: u64 = 0x080a_0000;
/// The guest's PCIe: ECAM and a 32-bit MMIO window, as its devicetree says.
const ecam_base: u64 = 0x3f00_0000;
const intx_base: u32 = 3; // INTA of slot 0 is SPI 3, rotating per slot

/// A device passed through: its real config space (read through the
/// cap's config page), a virtual BAR the guest places, and the virtual
/// SPI its interrupts arrive on. Only the virtio BAR is shown; the
/// others (the MSI-X table's) read as absent. MSI-X itself stays
/// visible and enabled: the guest's transport then points the queues at
/// vector 0, whose message the host already routed to an LPI that the
/// hypervisor injects here.
const PtDev = struct {
    dev_h: u64 = 0,
    cfg: u64 = 0, // config page va
    bar_index: u64 = 0,
    bar_len: u64 = 0,
    bar_low: u32 = 0, // what the guest wrote (address or all-ones)
    bar_high: u32 = 0,
    attached: bool = false,
    slot: u8 = 0,
};
var ptdevs: [2]PtDev = @splat(.{});
var nptdevs: usize = 0;
var vm_handle: u64 = 0;

var log_h: u64 = 0;
var line: [256]u8 = undefined;
var line_len: usize = 0;
var ticks_seen: u64 = 0;
var moss_guest = false;

// The guest's GIC, as a register file: writes are remembered, reads give
// them back; the redistributor's WAKER reports the core awake as soon as
// it asks. Nothing else is needed for a guest that only takes its
// interrupts through the (real, virtual) CPU interface.
var gicd: [0x1_0000]u8 align(8) = @splat(0);
const max_vcpus = 4;
var gicr: [max_vcpus][0x2_0000]u8 align(8) = @splat(@splat(0));
var vcpu_stacks: [max_vcpus][32 * 1024]u8 align(16) = undefined;

export fn umain(log_handle: u64, chan_h: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    log_h = log_handle;
    moss_guest = arg >= 1;
    const setup = boot.take(chan_h);
    _ = usys.capDrop(chan_h);
    if (arg == 2) {
        // A pool node: the devices its spawner handed over, in slots 1, 2.
        for ([_]shared.DeviceKind{ .rng, .net }) |k| {
            const h = setup.device(k);
            if (h == 0) {
                _ = usys.log(log_h, "vmm: a pool node needs an entropy device and a NIC to pass through");
                usys.exit(137);
            }
            const mm = usys.mmioMap(h);
            if (mm.err != .ok) usys.exit(138);
            ptdevs[nptdevs] = .{ .dev_h = h, .cfg = mm.data[2], .bar_index = mm.data[3], .bar_len = mm.data[1], .slot = @intCast(nptdevs + 1) };
            nptdevs += 1;
        }
    }
    const blob: []const u8 = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    const image = shared.marcFind(blob, if (moss_guest) "img/moss-guest" else "img/guest-hello") orelse {
        _ = usys.log(log_h, "vmm: guest image missing from the boot archive");
        usys.exit(130);
    };

    const ram_pages: u64 = if (moss_guest) 32768 else 2048; // 128M / 8M
    const c = usys.vmCreate(hyp_h, ram_pages, if (moss_guest) max_vcpus else 1);
    if (c.err != .ok) {
        _ = usys.log(log_h, "vmm: vm_create refused");
        usys.exit(131);
    }
    const vm_h = c.data[0];
    vm_handle = vm_h;
    const ram: [*]u8 = @ptrFromInt(c.data[1]);
    var entry: u64 = shared.vm_ram_ipa;
    var x0: u64 = 0;
    if (moss_guest) {
        // Linux Image protocol: text at RAM + 0x80000, DTB pointer in x0.
        @memcpy(ram[0x80000 .. 0x80000 + image.len], image);
        const dtb_off = ram_pages * 4096 - 0x1_0000;
        const n = writeDtb(ram[dtb_off .. dtb_off + 0x1000], ram_pages * 4096, arg == 2);
        if (n == 0) usys.exit(136);
        entry = shared.vm_ram_ipa + 0x80000;
        x0 = shared.vm_ram_ipa + dtb_off;
        _ = usys.log(log_h, "vmm: moss guest loaded at IPA 0x40080000 with its devicetree; entering EL1");
    } else {
        @memcpy(ram[0..image.len], image);
        _ = usys.log(log_h, "vmm: guest loaded at IPA 0x40000000; entering EL1");
    }
    if (usys.vmSet(vm_h, entry, x0) != .ok) usys.exit(132);

    runLoop(0);
    _ = usys.capDrop(vm_h);
    if (!moss_guest and ticks_seen != 3) usys.exit(135);
    usys.exit(0);
}

/// A vCPU's thread (vCPU 0 is the main one): the exit loop until the
/// guest powers off.
fn vcpuThread(idx: u64) callconv(.c) void {
    runLoop(idx);
    usys.exit(0); // power-off from any vCPU ends the VMM
}

fn runLoop(vcpu: u64) void {
    var value: u64 = 0;
    while (true) {
        const r = usys.vmRun(vm_handle, vcpu, value);
        if (r.err != .ok) usys.exit(133);
        value = 0;
        const kind: shared.VmExit = @enumFromInt(r.data[0]);
        switch (kind) {
            .mmio_write => mmioWrite(r.data[1], r.data[2], r.data[3]),
            .mmio_read => value = mmioRead(r.data[1], r.data[2]),
            .wfi => usys.sleep(1),
            .hvc, .smc => {
                // The guest's firmware interface is this program: PSCI on
                // this architecture. The answer rides the resume value
                // into the guest's x0; power-off ends the VM.
                // x5 of a vm_run result (the guest's x3) rides the cap slot.
                const ans = psci(r.data[1], r.data[2], r.data[3], r.cap) orelse {
                    _ = usys.log(log_h, "vmm: guest asked PSCI to power off; VM done");
                    return;
                };
                value = ans;
            },
            .interrupted => {},
            .fault, .none => {
                var msg: [160]u8 = undefined;
                var n: usize = 0;
                n = put(&msg, n, "vmm: guest faulted (esr 0x");
                n = putHex(&msg, n, r.data[1]);
                n = put(&msg, n, "; the guest's own elr 0x");
                n = putHex(&msg, n, r.data[2]);
                n = put(&msg, n, " esr 0x");
                n = putHex(&msg, n, r.data[3]);
                n = put(&msg, n, "); killing the VM");
                _ = usys.log(log_h, msg[0..n]);
                usys.exit(134);
            },
        }
    }
}

// ---------------------------------------------------------------- PSCI

const psci_version: u64 = 0x8400_0000;
const psci_cpu_on32: u64 = 0x8400_0003;
const psci_cpu_on64: u64 = 0xc400_0003;
const psci_system_off: u64 = 0x8400_0008;
const psci_system_reset: u64 = 0x8400_0009;
const psci_ok: u64 = 0;
const psci_not_supported: u64 = @bitCast(@as(i64, -1));
const psci_invalid: u64 = @bitCast(@as(i64, -2));
const psci_already_on: u64 = @bitCast(@as(i64, -4));

/// Answer a PSCI call, or null for a power-off. CPU_ON asks the kernel
/// to reset and online the vCPU, then runs it on a thread of its own.
fn psci(fid: u64, x1: u64, x2: u64, x3: u64) ?u64 {
    switch (fid) {
        psci_version => return 0x0001_0002, // PSCI 1.2
        psci_system_off, psci_system_reset => return null,
        psci_cpu_on32, psci_cpu_on64 => {
            const idx = x1 & 0xff;
            if ((x1 >> 8) != 0 or idx >= max_vcpus) return psci_invalid;
            switch (usys.vmCpuOn(vm_handle, idx, x2, x3)) {
                .ok => {},
                .busy => return psci_already_on,
                else => return psci_invalid,
            }
            if (usys.threadCreate(vcpuThread, idx, &vcpu_stacks[idx]) != .ok) {
                _ = usys.log(log_h, "vmm: could not start a vCPU thread");
                usys.exit(140);
            }
            _ = usys.log(log_h, "vmm: guest brought a vCPU online");
            return psci_ok;
        },
        else => {
            if (fid & 0xffff_ffe0 != psci_version and fid & 0xffff_ffe0 != 0xc400_0000) {
                _ = usys.log(log_h, "vmm: guest hypercall outside PSCI (refused)");
            }
            return psci_not_supported;
        },
    }
}

// ------------------------------------------------------------- devices

fn mmioWrite(ipa: u64, size: u64, v: u64) void {
    if (ipa >= uart_base and ipa < uart_base + 0x1000) {
        if (ipa - uart_base == 0) uartByte(@truncate(v));
    } else if (ipa >= gicd_base and ipa < gicd_base + gicd.len) {
        store(&gicd, ipa - gicd_base, size, v);
    } else if (ipa >= gicr_base and ipa < gicr_base + max_vcpus * 0x2_0000) {
        const cpu = (ipa - gicr_base) / 0x2_0000;
        const off = (ipa - gicr_base) % 0x2_0000;
        var val = v;
        if (off == 0x14) val &= ~@as(u64, 4); // WAKER: children awake
        store(&gicr[cpu], off, size, val);
    } else if (ipa >= ecam_base and ipa < ecam_base + 0x100_0000) {
        ecamWrite(ipa - ecam_base, size, v);
    } else {
        var msg: [96]u8 = undefined;
        var n: usize = 0;
        n = put(&msg, n, "vmm: guest wrote an address it does not have (0x");
        n = putHex(&msg, n, ipa);
        n = put(&msg, n, "); ignored");
        _ = usys.log(log_h, msg[0..n]);
    }
}

// ------------------------------------------------ PCI config emulation

fn ptBySlot(slot: u64) ?*PtDev {
    for (ptdevs[0..nptdevs]) |*p| {
        if (p.slot == slot) return p;
    }
    return null;
}

fn cfgRead32(p: *const PtDev, off: u64) u32 {
    return @as(*volatile u32, @ptrFromInt(p.cfg + (off & ~@as(u64, 3)))).*;
}

/// Config space of the emulated bus: the passed-through devices' real
/// registers, except their BARs (virtual: sized from the real one, placed
/// by the guest) and the command register (writes ignored — the host set
/// it up).
fn ecamRead(off: u64, size: u64) u64 {
    const slot = off >> 15;
    const reg = off & 0xfff;
    const p = ptBySlot(slot) orelse return if (size == 8) 0xffff_ffff_ffff_ffff else (@as(u64, 1) << @intCast(size * 8)) - 1;
    var word: u32 = cfgRead32(p, reg);
    if (reg >= 0x10 and reg < 0x28) {
        const bar = (reg - 0x10) / 4;
        if (bar == p.bar_index) {
            const size_mask: u32 = @truncate(~(p.bar_len - 1));
            word = if (p.bar_low == 0xffff_ffff) size_mask | (cfgRead32(p, reg) & 0xf) else p.bar_low | (cfgRead32(p, reg) & 0xf);
        } else if (bar == p.bar_index + 1 and cfgRead32(p, 0x10 + p.bar_index * 4) & 0x4 != 0) {
            word = if (p.bar_low == 0xffff_ffff) 0xffff_ffff else p.bar_high;
        } else {
            word = 0;
        }
    }
    const shift: u6 = @intCast((reg & 3) * 8);
    const v: u64 = @as(u64, word) >> shift;
    return v & ((@as(u64, 1) << @intCast(size * 8)) - 1);
}

fn ecamWrite(off: u64, size: u64, v: u64) void {
    const slot = off >> 15;
    const reg = off & 0xfff;
    const p = ptBySlot(slot) orelse return;
    if (size != 4 or reg < 0x10 or reg >= 0x28) return; // only BARs take effect
    const bar = (reg - 0x10) / 4;
    if (bar == p.bar_index) {
        p.bar_low = @truncate(v);
        // An address, not the sizing pattern nor the flag bits alone.
        if (p.bar_low != 0xffff_ffff and (p.bar_low & ~@as(u32, 0xf)) != 0 and !p.attached) attach(p);
    } else if (bar == p.bar_index + 1) {
        p.bar_high = @truncate(v);
    }
}

/// The guest placed the BAR: map it there in the guest's stage 2, route
/// the device's DMA through that stage 2, and its interrupt to the SPI
/// the guest's devicetree gives this slot.
fn attach(p: *PtDev) void {
    const ipa = (@as(u64, p.bar_high) << 32) | (p.bar_low & ~@as(u32, 0xf));
    const vintid: u64 = 32 + intx_base + ((@as(u64, p.slot) + 1 - 1) % 4);
    if (usys.vmAttachDevice(vm_handle, p.dev_h, ipa, vintid) != .ok) {
        _ = usys.log(log_h, "vmm: passing a device through failed");
        usys.exit(139);
    }
    p.attached = true;
    var msg: [96]u8 = undefined;
    var n: usize = 0;
    n = put(&msg, n, "vmm: device passed through to the guest: BAR at IPA 0x");
    n = putHex(&msg, n, ipa);
    n = put(&msg, n, ", DMA and interrupt routed");
    _ = usys.log(log_h, msg[0..n]);
}

fn mmioRead(ipa: u64, size: u64) u64 {
    if (ipa >= uart_base and ipa < uart_base + 0x1000) {
        return if (ipa - uart_base == 0x18) 0x10 else 0; // FR: RX empty, TX not full
    } else if (ipa >= gicd_base and ipa < gicd_base + gicd.len) {
        return load(&gicd, ipa - gicd_base, size);
    } else if (ipa >= gicr_base and ipa < gicr_base + max_vcpus * 0x2_0000) {
        return load(&gicr[(ipa - gicr_base) / 0x2_0000], (ipa - gicr_base) % 0x2_0000, size);
    } else if (ipa >= ecam_base and ipa < ecam_base + 0x100_0000) {
        return ecamRead(ipa - ecam_base, size);
    }
    return 0;
}

fn store(file: []u8, off: u64, size: u64, v: u64) void {
    if (off + size > file.len) return;
    var i: u64 = 0;
    while (i < size) : (i += 1) file[off + i] = @truncate(v >> @intCast(i * 8));
}

fn load(file: []const u8, off: u64, size: u64) u64 {
    if (off + size > file.len) return 0;
    var v: u64 = 0;
    var i: u64 = 0;
    while (i < size) : (i += 1) v |= @as(u64, file[off + i]) << @intCast(i * 8);
    return v;
}

fn uartByte(b: u8) void {
    if (b == '\r') return;
    if (b == '\n') {
        var out: [264]u8 = undefined;
        const prefix: []const u8 = if (moss_guest) "guest| " else "guest> ";
        @memcpy(out[0..prefix.len], prefix);
        @memcpy(out[prefix.len .. prefix.len + line_len], line[0..line_len]);
        if (line_len > 0) _ = usys.log(log_h, out[0 .. prefix.len + line_len]);
        if (startsWith(line[0..line_len], "guest: tick ")) ticks_seen += 1;
        line_len = 0;
        return;
    }
    if (line_len < line.len) {
        line[line_len] = b;
        line_len += 1;
    }
}

// ---------------------------------------------------------- devicetree

/// A flattened devicetree for the moss guest: memory, bootargs, PSCI
/// over HVC, and for a pool node the PCIe host (ECAM, MMIO window, INTx
/// base) its passed-through devices sit behind. Returns the bytes
/// written (0 = the buffer was too small).
fn writeDtb(buf: []u8, ram_bytes: u64, node: bool) usize {
    const strings = "#address-cells\x00#size-cells\x00reg\x00device_type\x00bootargs\x00compatible\x00method\x00ranges\x00interrupt-map\x00";
    const s_addr = 0;
    const s_size = 15;
    const s_reg = 27;
    const s_devtype = 31;
    const s_bootargs = 43;
    const s_compat = 52;
    const s_method = 63;
    const s_ranges = 70;
    const s_intmap = 77;
    var w = Writer{ .buf = buf, .pos = 40 };
    w.word(1); // BEGIN_NODE
    w.str("");
    w.prop(s_addr, 4);
    w.word(2);
    w.prop(s_size, 4);
    w.word(2);
    w.word(1);
    w.str("memory@40000000");
    w.propStr(s_devtype, "memory");
    w.prop(s_reg, 16);
    w.word(0);
    w.word(@truncate(shared.vm_ram_ipa));
    w.word(@truncate(ram_bytes >> 32));
    w.word(@truncate(ram_bytes));
    w.word(2); // END_NODE
    w.word(1);
    w.str("chosen");
    w.propStr(s_bootargs, if (node) "node=2" else "profile=guest");
    w.word(2);
    if (node) {
        w.word(1);
        w.str("pcie@3f000000");
        w.propStr(s_compat, "pci-host-ecam-generic");
        w.prop(s_reg, 16);
        w.word(0);
        w.word(@truncate(ecam_base));
        w.word(0);
        w.word(0x100_0000);
        // One range: 32-bit memory, 0x10000000 + 0x2eff0000, identity.
        w.prop(s_ranges, 28);
        for ([_]u32{ 0x0200_0000, 0, 0x1000_0000, 0, 0x1000_0000, 0, 0x2eff_0000 }) |c| w.word(c);
        // One interrupt-map entry: slot 0 INTA -> SPI intx_base.
        w.prop(s_intmap, 40);
        for ([_]u32{ 0, 0, 0, 1, 0, 0, 0, 0, intx_base, 4 }) |c| w.word(c);
        w.word(2);
    }
    w.word(1);
    w.str("psci");
    w.propStr(s_compat, "arm,psci-1.0");
    w.propStr(s_method, "hvc");
    w.word(2);
    w.word(2); // END_NODE (root)
    w.word(9); // END
    if (w.overflow) return 0;
    const strings_off = w.pos;
    if (strings_off + strings.len > buf.len) return 0;
    @memcpy(buf[strings_off .. strings_off + strings.len], strings);
    const total = strings_off + strings.len;
    // Header: magic, totalsize, off_dt_struct, off_dt_strings, off_mem_rsvmap,
    // version, last_comp_version, boot_cpuid_phys, size_dt_strings, size_dt_struct.
    const hdr = [_]u32{ 0xd00dfeed, @intCast(total), 40, @intCast(strings_off), @intCast(total), 17, 16, 0, @intCast(strings.len), @intCast(strings_off - 40) };
    for (hdr, 0..) |v, i| {
        buf[i * 4] = @truncate(v >> 24);
        buf[i * 4 + 1] = @truncate(v >> 16);
        buf[i * 4 + 2] = @truncate(v >> 8);
        buf[i * 4 + 3] = @truncate(v);
    }
    return total;
}

const Writer = struct {
    buf: []u8,
    pos: usize,
    overflow: bool = false,

    fn word(w: *Writer, v: u32) void {
        if (w.pos + 4 > w.buf.len) {
            w.overflow = true;
            return;
        }
        w.buf[w.pos] = @truncate(v >> 24);
        w.buf[w.pos + 1] = @truncate(v >> 16);
        w.buf[w.pos + 2] = @truncate(v >> 8);
        w.buf[w.pos + 3] = @truncate(v);
        w.pos += 4;
    }
    fn str(w: *Writer, s: []const u8) void {
        if (w.pos + s.len + 4 > w.buf.len) {
            w.overflow = true;
            return;
        }
        @memcpy(w.buf[w.pos .. w.pos + s.len], s);
        w.pos += s.len;
        w.buf[w.pos] = 0;
        w.pos += 1;
        while (w.pos % 4 != 0) : (w.pos += 1) w.buf[w.pos] = 0;
    }
    fn prop(w: *Writer, name_off: u32, len: u32) void {
        w.word(3); // PROP
        w.word(len);
        w.word(name_off);
    }
    fn propStr(w: *Writer, name_off: u32, s: []const u8) void {
        w.prop(name_off, @intCast(s.len + 1));
        w.str(s);
    }
};

// ------------------------------------------------------------- helpers

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

fn put(buf: []u8, at: usize, s: []const u8) usize {
    var n = at;
    for (s) |c| {
        if (n == buf.len) break;
        buf[n] = c;
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
