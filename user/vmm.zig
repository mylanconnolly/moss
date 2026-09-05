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

const is_x86 = @import("builtin").cpu.arch == .x86_64;

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
    if (moss_guest and is_x86) {
        // The moss kernel as a guest on x86_64: an ELF the VMM loads the
        // way Limine would — page tables, the responses to the requests in
        // its image, ACPI tables, parked vCPUs.
        const g = loadMossGuestX86(ram, ram_pages, image, arg == 2) orelse usys.exit(136);
        _ = usys.log(log_h, "vmm: moss guest loaded (Limine protocol from the VMM); entering ring 0");
        if (usys.vmSetX(vm_h, g.entry, 0, g.cr3, g.rsp) != .ok) usys.exit(132);
        for (1..max_vcpus) |i| {
            if (usys.threadCreate(apPoller, i, &vcpu_stacks[i]) != .ok) usys.exit(140);
        }
        runLoop(0);
        _ = usys.capDrop(vm_h);
        usys.exit(0);
    }
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
        _ = usys.log(log_h, if (is_x86) "vmm: guest loaded at GPA 0x40000000; entering ring 0" else "vmm: guest loaded at IPA 0x40000000; entering EL1");
    }
    if (is_x86) {
        // A 64-bit guest cannot run without page tables: identity-map its
        // RAM with 2 MB pages at the top of that RAM, its stack below.
        const ram_bytes = ram_pages * 4096;
        const pml4_off = ram_bytes - 4096;
        const pdpt_off = ram_bytes - 8192;
        const pd_off = ram_bytes - 12288;
        const pml4: [*]u64 = @ptrCast(@alignCast(ram + pml4_off));
        const pdpt: [*]u64 = @ptrCast(@alignCast(ram + pdpt_off));
        const pd: [*]u64 = @ptrCast(@alignCast(ram + pd_off));
        pml4[0] = (shared.vm_ram_ipa + pdpt_off) | 7;
        pdpt[1] = (shared.vm_ram_ipa + pd_off) | 7; // 0x40000000 >> 30
        for (0..(ram_bytes + (2 << 20) - 1) / (2 << 20)) |i| pd[i] = (shared.vm_ram_ipa + i * (2 << 20)) | 7 | (1 << 7);
        if (usys.vmSetX(vm_h, entry, x0, shared.vm_ram_ipa + pml4_off, shared.vm_ram_ipa + pd_off - 16) != .ok) usys.exit(132);
    } else {
        if (usys.vmSet(vm_h, entry, x0) != .ok) usys.exit(132);
    }

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
            // x86_64: the serial port's data register is the console, the
            // ACPI PM1a control register with SLP_EN the power-off.
            .pio_write => {
                if (r.data[1] == 0x3f8) {
                    uartByte(@truncate(r.data[3]));
                } else if (r.data[1] == 0x604 and r.data[3] & (1 << 13) != 0) {
                    _ = usys.log(log_h, "vmm: guest asked ACPI to power off; VM done");
                    return;
                }
            },
            .pio_read => value = if (r.data[1] == 0x3fd) 0x60 else 0, // LSR: transmitter empty
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
    // The line the guest kernel expects for this slot and the device's
    // pin: aarch64's devicetree gives SPI intx_base upward; x86_64's
    // platform swizzles onto vectors 48 + ((slot + pin - 1) % 4).
    const pin: u64 = (cfgRead32(p, 0x3c) >> 8) & 0xff;
    const vintid: u64 = if (is_x86) 48 + ((@as(u64, p.slot) + pin - 1) % 4) else 32 + intx_base + ((@as(u64, p.slot) + 1 - 1) % 4);
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

// ------------------------------------------------ x86_64: the moss guest

/// Where the VMM puts things in the guest's RAM (GPA offsets from the
/// RAM base): the loader's page tables, its data (responses, ACPI, the
/// parked cores' records), the kernel image, and the boot stack at the
/// top.
const g_tables_off: u64 = 0x100000;
const g_tables_len: u64 = 0x40000;
const g_data_off: u64 = 0x140000;
const g_data_len: u64 = 0x40000;
const g_acpi_off: u64 = 0x180000; // its own pages: the guest maps them as ACPI
const g_acpi_len: u64 = 0x10000;
const g_image_off: u64 = 0x200000;
const g_stack_len: u64 = 0x10000;
const g_ap_stack_len: u64 = 0x10000;
const hhdm: u64 = 0xffff_8000_0000_0000;
const kernel_virt: u64 = 0xffff_ffff_8000_0000;

const GuestEntry = struct { entry: u64, cr3: u64, rsp: u64 };

var g_ram: [*]u8 = undefined;
var g_ram_bytes: u64 = 0;
var g_bump: u64 = 0; // next free byte in the tables area
var g_data_bump: u64 = 0;
var g_acpi_bump: u64 = 0;
var g_mp_infos_off: u64 = 0; // GPA offset of the mp_info records
var g_cr3: u64 = 0;

fn gpa(off: u64) u64 {
    return shared.vm_ram_ipa + off;
}

fn gptr(comptime T: type, off: u64) T {
    return @ptrCast(@alignCast(g_ram + off));
}

fn allocTable() u64 {
    const off = g_tables_off + g_bump;
    g_bump += 4096;
    if (g_bump > g_tables_len) usys.exit(141);
    @memset(g_ram[off .. off + 4096], 0);
    return off;
}

fn allocData(len: u64, alignment: u64) u64 {
    g_data_bump = (g_data_bump + alignment - 1) & ~(alignment - 1);
    const off = g_data_off + g_data_bump;
    g_data_bump += len;
    if (g_data_bump > g_data_len) usys.exit(141);
    @memset(g_ram[off .. off + len], 0);
    return off;
}

fn allocAcpi(len: u64) u64 {
    g_acpi_bump = (g_acpi_bump + 15) & ~@as(u64, 15);
    const off = g_acpi_off + g_acpi_bump;
    g_acpi_bump += len;
    if (g_acpi_bump > g_acpi_len) usys.exit(141);
    @memset(g_ram[off .. off + len], 0);
    return off;
}

fn rd(comptime T: type, b: []const u8, off: usize) T {
    var v: T = 0;
    for (0..@sizeOf(T)) |i| v |= @as(T, b[off + i]) << @intCast(i * 8);
    return v;
}

fn wr(comptime T: type, b: []u8, off: usize, v: T) void {
    for (0..@sizeOf(T)) |i| b[off + i] = @truncate(v >> @intCast(i * 8));
}

/// Map one 4K page in the guest's tables (4-level, all levels writable).
fn gmap(va: u64, pa: u64, flags: u64) void {
    var table = g_cr3 - shared.vm_ram_ipa;
    const idx = [_]u6{ 39, 30, 21 };
    for (idx) |shift| {
        const e = gptr([*]u64, table)[(va >> shift) & 0x1ff];
        var next: u64 = undefined;
        if (e & 1 == 0) {
            next = allocTable();
            gptr([*]u64, table)[(va >> shift) & 0x1ff] = gpa(next) | 3;
        } else next = (e & 0x000f_ffff_ffff_f000) - shared.vm_ram_ipa;
        table = next;
    }
    gptr([*]u64, table)[(va >> 12) & 0x1ff] = pa | flags;
}

/// Map a 2 MB page (the HHDM).
fn gmap2m(va: u64, pa: u64) void {
    var table = g_cr3 - shared.vm_ram_ipa;
    const idx = [_]u6{ 39, 30 };
    for (idx) |shift| {
        const e = gptr([*]u64, table)[(va >> shift) & 0x1ff];
        var next: u64 = undefined;
        if (e & 1 == 0) {
            next = allocTable();
            gptr([*]u64, table)[(va >> shift) & 0x1ff] = gpa(next) | 3;
        } else next = (e & 0x000f_ffff_ffff_f000) - shared.vm_ram_ipa;
        table = next;
    }
    gptr([*]u64, table)[(va >> 21) & 0x1ff] = pa | 3 | (1 << 7);
}

fn loadMossGuestX86(ram: [*]u8, ram_pages: u64, image: []const u8, node: bool) ?GuestEntry {
    g_ram = ram;
    g_ram_bytes = ram_pages * 4096;
    g_bump = 0;
    g_data_bump = 0;
    g_acpi_bump = 0;

    // The ELF: every PT_LOAD segment at image_off + (vaddr - kernel_virt).
    if (image.len < 64 or !eql(image[0..4], "\x7fELF")) return null;
    const e_entry = rd(u64, image, 0x18);
    const e_phoff = rd(u64, image, 0x20);
    const e_phentsize = rd(u16, image, 0x36);
    const e_phnum = rd(u16, image, 0x38);
    var image_end: u64 = 0;
    var ph: usize = 0;
    while (ph < e_phnum) : (ph += 1) {
        const p = e_phoff + ph * e_phentsize;
        if (rd(u32, image, p) != 1) continue; // PT_LOAD
        const p_offset = rd(u64, image, p + 8);
        const p_vaddr = rd(u64, image, p + 16);
        const p_filesz = rd(u64, image, p + 32);
        const p_memsz = rd(u64, image, p + 40);
        if (p_vaddr < kernel_virt) return null;
        const dst = g_image_off + (p_vaddr - kernel_virt);
        if (dst + p_memsz > g_ram_bytes - g_stack_len) return null;
        @memcpy(ram[dst .. dst + p_filesz], image[p_offset .. p_offset + p_filesz]);
        @memset(ram[dst + p_filesz .. dst + p_memsz], 0);
        if (dst + p_memsz > image_end) image_end = dst + p_memsz;
    }
    image_end = (image_end + 4095) & ~@as(u64, 4095);

    // Page tables: the image at its link address, the HHDM over all of RAM.
    g_cr3 = gpa(allocTable());
    var off = g_image_off;
    while (off < image_end) : (off += 4096) gmap(kernel_virt + (off - g_image_off), gpa(off), 3);
    off = 0;
    while (off < g_ram_bytes) : (off += 2 << 20) gmap2m(hhdm + gpa(off), gpa(off));

    // ACPI: RSDP -> XSDT -> FADT (+ DSDT), MADT, MCFG for a pool node.
    const rsdp_off = buildAcpi(ram_pages, node);

    // The responses, in loader data.
    const memmap_off = buildMemmap(image_end, ram_pages);
    const hhdm_off = allocData(16, 8);
    gptr([*]u64, hhdm_off)[1] = hhdm;
    const addr_off = allocData(24, 8);
    gptr([*]u64, addr_off)[1] = gpa(g_image_off);
    gptr([*]u64, addr_off)[2] = kernel_virt;
    const cmd: []const u8 = if (node) "node=2" else "profile=guest";
    const cmd_off = allocData(cmd.len + 1, 8);
    @memcpy(ram[cmd_off .. cmd_off + cmd.len], cmd);
    const cmdline_off = allocData(16, 8);
    gptr([*]u64, cmdline_off)[1] = hhdm + gpa(cmd_off);
    const rsdp_resp_off = allocData(16, 8);
    gptr([*]u64, rsdp_resp_off)[1] = hhdm + gpa(rsdp_off);
    const tsc_off = allocData(16, 8);
    gptr([*]u64, tsc_off)[1] = usys.cycleHz();
    const info_name_off = allocData(16, 8);
    @memcpy(ram[info_name_off .. info_name_off + 8], "moss-vmm");
    const info_ver_off = allocData(8, 8);
    ram[info_ver_off] = '1';
    const info_off = allocData(24, 8);
    gptr([*]u64, info_off)[1] = hhdm + gpa(info_name_off);
    gptr([*]u64, info_off)[2] = hhdm + gpa(info_ver_off);
    // MP: one record per vCPU, its stack in the reserved word, the
    // pointer array, the response.
    g_mp_infos_off = allocData(32 * max_vcpus, 16);
    const cpus_off = allocData(8 * max_vcpus, 8);
    for (0..max_vcpus) |i| {
        const rec = g_mp_infos_off + i * 32;
        wr(u32, ram[rec .. rec + 32], 0, @intCast(i)); // processor id
        wr(u32, ram[rec .. rec + 32], 4, @intCast(i)); // lapic id
        // Its stack, as an address in the loader's tables (the direct map).
        wr(u64, ram[rec .. rec + 32], 8, hhdm + gpa(g_ram_bytes - g_stack_len - (i + 1) * g_ap_stack_len));
        gptr([*]u64, cpus_off)[i] = hhdm + gpa(rec);
    }
    const mp_off = allocData(32, 8);
    wr(u32, ram[mp_off .. mp_off + 32], 8, 1); // flags: x2APIC
    wr(u32, ram[mp_off .. mp_off + 32], 12, 0); // bsp lapic id
    wr(u64, ram[mp_off .. mp_off + 32], 16, max_vcpus);
    wr(u64, ram[mp_off .. mp_off + 32], 24, hhdm + gpa(cpus_off));

    // The requests in the image: between the markers, by id.
    const start_marker = [_]u64{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };
    const end_marker = [_]u64{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };
    const words: [*]u64 = @ptrCast(@alignCast(ram + g_image_off));
    const nwords = (image_end - g_image_off) / 8;
    var i: usize = 0;
    var begin: ?usize = null;
    while (i + 4 <= nwords) : (i += 1) {
        if (words[i] == start_marker[0] and words[i + 1] == start_marker[1] and words[i + 2] == start_marker[2] and words[i + 3] == start_marker[3]) begin = i + 4;
    }
    const from = begin orelse return null;
    var found: u32 = 0;
    i = from;
    while (i + 2 <= nwords) : (i += 1) {
        if (words[i] == end_marker[0] and words[i + 1] == end_marker[1]) break;
        if (words[i] == 0xf9562b2d5c95a6c8 and words[i + 1] == 0x6a7b384944536bdc) {
            words[i + 1] = 5; // the revision used
            words[i + 2] = 0; // supported
            found += 1;
            continue;
        }
        if (words[i] != 0xc7b1dd30df4c8b88 or words[i + 1] != 0x0a82e883a194f07b or i + 6 > nwords) continue;
        const a = words[i + 2];
        const b = words[i + 3];
        const resp: ?u64 = if (a == 0x67cf3d9d378a806f and b == 0xe304acdfc50c3c62) memmap_off // memmap
            else if (a == 0x48dcf1cb8ad2b852 and b == 0x63984e959a98244b) hhdm_off else if (a == 0x71ba76863cc55f63 and b == 0xb2644a48c516a487) addr_off else if (a == 0x4b161536e598651e and b == 0xb390ad4a2f1f303a) cmdline_off else if (a == 0xc5e77b6b397e7b43 and b == 0x27637845accdcf3c) rsdp_resp_off else if (a == 0x10f2ee1d87d195e4 and b == 0xf747a2b78f6ddb31) tsc_off else if (a == 0x95a67b819a1b857e and b == 0xa0b61b723b6a73e0) mp_off else if (a == 0xf55038d8e2a1202f and b == 0x279426fcf5f59740) info_off else null;
        if (resp) |r| {
            words[i + 5] = hhdm + gpa(r); // the response pointer
            found += 1;
            i += 5;
        }
    }
    if (found < 6) return null;
    return .{ .entry = e_entry, .cr3 = g_cr3, .rsp = hhdm + gpa(g_ram_bytes) - 16 };
}

/// Limine memory map: the loader's tables and data are reclaimable, the
/// ACPI pages ACPI-reclaimable, the image "executable", the rest usable.
fn buildMemmap(image_end: u64, ram_pages: u64) u64 {
    const bytes = ram_pages * 4096;
    const Entry = struct { base: u64, len: u64, kind: u64 };
    const entries = [_]Entry{
        .{ .base = 0, .len = g_tables_off, .kind = 0 },
        .{ .base = g_tables_off, .len = g_acpi_off - g_tables_off, .kind = 5 },
        .{ .base = g_acpi_off, .len = g_acpi_len, .kind = 2 },
        .{ .base = g_acpi_off + g_acpi_len, .len = g_image_off - g_acpi_off - g_acpi_len, .kind = 0 },
        .{ .base = g_image_off, .len = image_end - g_image_off, .kind = 6 },
        .{ .base = image_end, .len = bytes - g_stack_len - max_vcpus * g_ap_stack_len - image_end, .kind = 0 },
        .{ .base = bytes - g_stack_len - max_vcpus * g_ap_stack_len, .len = g_stack_len + max_vcpus * g_ap_stack_len, .kind = 5 },
    };
    const recs_off = allocData(24 * entries.len, 8);
    const ptrs_off = allocData(8 * entries.len, 8);
    for (entries, 0..) |e, i| {
        const rec = recs_off + i * 24;
        gptr([*]u64, rec)[0] = gpa(e.base);
        gptr([*]u64, rec)[1] = e.len;
        gptr([*]u64, rec)[2] = e.kind;
        gptr([*]u64, ptrs_off)[i] = hhdm + gpa(rec);
    }
    const resp = allocData(24, 8);
    gptr([*]u64, resp)[1] = entries.len;
    gptr([*]u64, resp)[2] = hhdm + gpa(ptrs_off);
    return resp;
}

fn acpiHeader(off: u64, sig: []const u8, len: u32) void {
    const b = g_ram[off .. off + len];
    @memcpy(b[0..4], sig);
    wr(u32, b, 4, len);
    b[8] = 2; // revision
    @memcpy(b[10..16], "MOSSVM");
    @memcpy(b[16..24], "MOSSVMM ");
    wr(u32, b, 24, 1);
    @memcpy(b[28..32], "MOSS");
    wr(u32, b, 32, 1);
}

fn acpiChecksum(off: u64, len: u64, at: u64) void {
    var sum: u8 = 0;
    for (g_ram[off .. off + len]) |c| sum +%= c;
    g_ram[off + at] = 0 -% sum;
}

/// The tables the guest kernel reads: the FADT for PM1a (0x604) and the
/// DSDT; a DSDT whose bytes hold the S5 package and, as a DWordMemory
/// descriptor, the 32-bit window the guest may place BARs in; the MADT
/// with a local APIC per vCPU; the MCFG naming the emulated ECAM for a
/// pool node. Returns the RSDP's GPA offset.
fn buildAcpi(ram_pages: u64, node: bool) u64 {
    _ = ram_pages;
    // DSDT: header + AML.
    const aml = [_]u8{
        0x08, '_', 'S', '5', '_', 0x12, 0x06, 0x04, 0x0a, 0x05, 0x0a, 0x05, 0x00, 0x00, // Name(_S5_, Package(4){5,5,0,0})
        0x87, 0x17, 0x00, 0x00, 0x0c, 0x03, 0x00, 0x00, 0x00, 0x00, // DWordMemory: memory, rw
        0x00, 0x00, 0x00, 0x10, // min 0x10000000
        0xff, 0xff, 0xff, 0x3e, // max 0x3effffff
        0x00, 0x00, 0x00, 0x00, // translation
        0x00, 0x00, 0x00, 0x2f, // length 0x2f000000
    };
    const dsdt_len: u32 = 36 + aml.len;
    const dsdt = allocAcpi(dsdt_len);
    acpiHeader(dsdt, "DSDT", dsdt_len);
    @memcpy(g_ram[dsdt + 36 .. dsdt + 36 + aml.len], &aml);
    acpiChecksum(dsdt, dsdt_len, 9);
    // FADT (rev 6 length).
    const fadt_len: u32 = 276;
    const fadt = allocAcpi(fadt_len);
    acpiHeader(fadt, "FACP", fadt_len);
    const fb = g_ram[fadt .. fadt + fadt_len];
    wr(u32, fb, 40, @truncate(gpa(dsdt))); // DSDT
    wr(u32, fb, 64, 0x604); // PM1a_CNT_BLK
    fb[89] = 2; // PM1_CNT_LEN
    wr(u64, fb, 140, gpa(dsdt)); // X_DSDT
    acpiChecksum(fadt, fadt_len, 9);
    // MADT: local APIC address, flags, one processor entry per vCPU.
    const madt_len: u32 = 44 + 8 * max_vcpus;
    const madt = allocAcpi(madt_len);
    acpiHeader(madt, "APIC", madt_len);
    const mb = g_ram[madt .. madt + madt_len];
    wr(u32, mb, 36, 0xfee0_0000);
    for (0..max_vcpus) |i| {
        const e = 44 + i * 8;
        mb[e] = 0; // processor local APIC
        mb[e + 1] = 8;
        mb[e + 2] = @intCast(i);
        mb[e + 3] = @intCast(i);
        wr(u32, mb, e + 4, 1); // enabled
    }
    acpiChecksum(madt, madt_len, 9);
    // MCFG, for a node with a bus to enumerate.
    var mcfg: u64 = 0;
    if (node) {
        const mcfg_len: u32 = 44 + 16;
        mcfg = allocAcpi(mcfg_len);
        acpiHeader(mcfg, "MCFG", mcfg_len);
        const cb = g_ram[mcfg .. mcfg + mcfg_len];
        wr(u64, cb, 44, ecam_base);
        wr(u16, cb, 52, 0); // segment
        cb[54] = 0; // start bus
        cb[55] = 0; // end bus
        acpiChecksum(mcfg, mcfg_len, 9);
    }
    // XSDT.
    const n: u32 = if (node) 3 else 2;
    const xsdt_len: u32 = 36 + 8 * n;
    const xsdt = allocAcpi(xsdt_len);
    acpiHeader(xsdt, "XSDT", xsdt_len);
    wr(u64, g_ram[xsdt .. xsdt + xsdt_len], 36, gpa(fadt));
    wr(u64, g_ram[xsdt .. xsdt + xsdt_len], 44, gpa(madt));
    if (node) wr(u64, g_ram[xsdt .. xsdt + xsdt_len], 52, gpa(mcfg));
    acpiChecksum(xsdt, xsdt_len, 9);
    // RSDP, revision 2.
    const rsdp = allocAcpi(36);
    const rb = g_ram[rsdp .. rsdp + 36];
    @memcpy(rb[0..8], "RSD PTR ");
    @memcpy(rb[9..15], "MOSSVM");
    rb[15] = 2;
    wr(u32, rb, 20, 36);
    wr(u64, rb, 24, gpa(xsdt));
    acpiChecksum(rsdp, 20, 8);
    acpiChecksum(rsdp, 36, 32);
    return rsdp;
}

/// A parked vCPU's keeper: when the guest's boot core publishes an
/// address in the record's `goto_address`, bring the vCPU online there
/// on the shared tables and the stack the record names, and run it.
fn apPoller(idx: u64) callconv(.c) void {
    const rec = g_mp_infos_off + idx * 32;
    while (true) {
        const target = rd(u64, g_ram[rec .. rec + 32], 16);
        if (target != 0) {
            const ctx = hhdm + gpa(rec);
            const stack = rd(u64, g_ram[rec .. rec + 32], 8);
            if (usys.vmCpuOn(vm_handle, idx, target, ctx) != .ok) usys.exit(142);
            if (usys.vmSetVcpu(vm_handle, idx, target, ctx, g_cr3, stack) != .ok) usys.exit(142);
            var msg: [96]u8 = undefined;
            var n: usize = 0;
            n = put(&msg, n, "vmm: vCPU released at 0x");
            n = putHex(&msg, n, target);
            n = put(&msg, n, ", stack 0x");
            n = putHex(&msg, n, stack);
            _ = usys.log(log_h, msg[0..n]);
            runLoop(idx);
            usys.exit(0);
        }
        usys.sleep(1);
    }
}

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
