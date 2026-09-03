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
const uart_base: u64 = 0x0900_0000;
const gicd_base: u64 = 0x0800_0000;
const gicr_base: u64 = 0x080a_0000;

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
var gicr: [0x2_0000]u8 align(8) = @splat(0);

export fn umain(log_handle: u64, _: u64, arg: u64, blob_va: u64, blob_len: u64) callconv(.c) noreturn {
    log_h = log_handle;
    moss_guest = arg == 1;
    const blob: []const u8 = @as([*]const u8, @ptrFromInt(blob_va))[0..blob_len];
    const image = shared.marcFind(blob, if (moss_guest) "img/moss-guest" else "img/guest-hello") orelse {
        _ = usys.log(log_h, "vmm: guest image missing from the boot archive");
        usys.exit(130);
    };

    const ram_pages: u64 = if (moss_guest) 16384 else 2048; // 64M / 8M
    const c = usys.vmCreate(hyp_h, ram_pages);
    if (c.err != .ok) {
        _ = usys.log(log_h, "vmm: vm_create refused");
        usys.exit(131);
    }
    const vm_h = c.data[0];
    const ram: [*]u8 = @ptrFromInt(c.data[1]);
    var entry: u64 = shared.vm_ram_ipa;
    var x0: u64 = 0;
    if (moss_guest) {
        // Linux Image protocol: text at RAM + 0x80000, DTB pointer in x0.
        @memcpy(ram[0x80000 .. 0x80000 + image.len], image);
        const dtb_off = ram_pages * 4096 - 0x1_0000;
        const n = writeDtb(ram[dtb_off .. dtb_off + 0x1000], ram_pages * 4096);
        if (n == 0) usys.exit(136);
        entry = shared.vm_ram_ipa + 0x80000;
        x0 = shared.vm_ram_ipa + dtb_off;
        _ = usys.log(log_h, "vmm: moss guest loaded at IPA 0x40080000 with its devicetree; entering EL1");
    } else {
        @memcpy(ram[0..image.len], image);
        _ = usys.log(log_h, "vmm: guest loaded at IPA 0x40000000; entering EL1");
    }
    if (usys.vmSet(vm_h, entry, x0) != .ok) usys.exit(132);

    var value: u64 = 0;
    while (true) {
        const r = usys.vmRun(vm_h, value);
        if (r.err != .ok) usys.exit(133);
        value = 0;
        const kind: shared.VmExit = @enumFromInt(r.data[0]);
        switch (kind) {
            .mmio_write => mmioWrite(r.data[1], r.data[2], r.data[3]),
            .mmio_read => value = mmioRead(r.data[1], r.data[2]),
            .wfi => usys.sleep(1),
            .hvc => _ = usys.log(log_h, "vmm: guest hypercall (ignored)"),
            .interrupted => {},
            .poweroff => {
                _ = usys.log(log_h, "vmm: guest asked PSCI to power off; VM done");
                break;
            },
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
    _ = usys.capDrop(vm_h);
    if (!moss_guest and ticks_seen != 3) usys.exit(135);
    usys.exit(0);
}

// ------------------------------------------------------------- devices

fn mmioWrite(ipa: u64, size: u64, v: u64) void {
    if (ipa >= uart_base and ipa < uart_base + 0x1000) {
        if (ipa - uart_base == 0) uartByte(@truncate(v));
    } else if (ipa >= gicd_base and ipa < gicd_base + gicd.len) {
        store(&gicd, ipa - gicd_base, size, v);
    } else if (ipa >= gicr_base and ipa < gicr_base + gicr.len) {
        var val = v;
        if (ipa - gicr_base == 0x14) val &= ~@as(u64, 4); // WAKER: children awake
        store(&gicr, ipa - gicr_base, size, val);
    } else {
        _ = usys.log(log_h, "vmm: guest wrote an address it does not have; ignored");
    }
}

fn mmioRead(ipa: u64, size: u64) u64 {
    if (ipa >= uart_base and ipa < uart_base + 0x1000) {
        return if (ipa - uart_base == 0x18) 0x10 else 0; // FR: RX empty, TX not full
    } else if (ipa >= gicd_base and ipa < gicd_base + gicd.len) {
        return load(&gicd, ipa - gicd_base, size);
    } else if (ipa >= gicr_base and ipa < gicr_base + gicr.len) {
        return load(&gicr, ipa - gicr_base, size);
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
/// over HVC. Returns the bytes written (0 = the buffer was too small).
fn writeDtb(buf: []u8, ram_bytes: u64) usize {
    const strings = "#address-cells\x00#size-cells\x00reg\x00device_type\x00bootargs\x00compatible\x00method\x00";
    const s_addr = 0;
    const s_size = 15;
    const s_reg = 27;
    const s_devtype = 31;
    const s_bootargs = 43;
    const s_compat = 52;
    const s_method = 63;
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
    w.propStr(s_bootargs, "profile=guest");
    w.word(2);
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
