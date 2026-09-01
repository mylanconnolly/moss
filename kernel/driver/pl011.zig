//! PL011 UART on QEMU virt, driven with the MMU off. QEMU's model needs no
//! init for transmit: poll the flag register and write the data register.
//!
//! This lives in the kernel only for boot logging and panic output; real
//! serial ownership moves to a userspace driver in Phase 7.

const mem = @import("../mem.zig");

// Accessed through the direct map: Zig code only ever runs with the MMU on.
const base: usize = mem.kvirt_offset + 0x0900_0000;

const dr: *volatile u32 = @ptrFromInt(base + 0x00);
const fr: *volatile u32 = @ptrFromInt(base + 0x18);

const fr_txff: u32 = 1 << 5;

pub fn putByte(byte: u8) void {
    while (fr.* & fr_txff != 0) {}
    dr.* = byte;
}

pub fn write(bytes: []const u8) void {
    for (bytes) |byte| {
        if (byte == '\n') putByte('\r');
        putByte(byte);
    }
}
