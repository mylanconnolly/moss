//! The boot console: a 16550 UART at COM1, reached through port I/O. It is
//! the debug channel QEMU exposes (`-serial`) and what a PCIe serial card
//! speaks; a real machine's console — the framebuffer Limine hands over —
//! is a later step. Polled, no interrupts, usable before the MMU switch.

const cpu = @import("cpu.zig");

const base: u16 = 0x3f8;
const r_data = base + 0;
const r_ier = base + 1;
const r_fcr = base + 2;
const r_lcr = base + 3;
const r_mcr = base + 4;
const r_lsr = base + 5;
const lsr_thre: u8 = 1 << 5;

pub fn init() void {
    cpu.outb(r_ier, 0); // no interrupts
    cpu.outb(r_lcr, 0x80); // divisor latch
    cpu.outb(r_data, 1); // 115200
    cpu.outb(r_ier, 0);
    cpu.outb(r_lcr, 0x03); // 8N1
    cpu.outb(r_fcr, 0xc7); // FIFO on, cleared, 14-byte threshold
    cpu.outb(r_mcr, 0x0b); // DTR | RTS | OUT2
}

pub fn putByte(byte: u8) void {
    while (cpu.inb(r_lsr) & lsr_thre == 0) {}
    cpu.outb(r_data, byte);
}

pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') putByte('\r');
        putByte(byte);
    }
}
