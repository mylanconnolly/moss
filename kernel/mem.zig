//! Kernel address space constants and the direct map.
//!
//! Layout: user space in the low half, the kernel in the high half at the
//! port's `kvirt_offset` (arch.zig; on aarch64 4K granule, 39-bit VAs on
//! both halves, 0xffffff8000000000 up).
//!
//! The kernel occupies the direct map: virt = phys + kvirt_offset, with the
//! kernel image's own pages re-protected W^X at 4K granularity. Device MMIO
//! is mapped at its direct-map address with device attributes.

pub const page_size: usize = 4096;

pub const kvirt_offset: u64 = @import("arch.zig").kvirt_offset;

pub fn physToVirt(pa: u64) u64 {
    return pa + kvirt_offset;
}

pub fn virtToPhys(va: u64) u64 {
    return va - kvirt_offset;
}

pub fn physToPtr(comptime T: type, pa: u64) T {
    return @ptrFromInt(physToVirt(pa));
}

pub fn alignDown(x: u64, comptime a: u64) u64 {
    return x & ~(a - 1);
}

pub fn alignUp(x: u64, comptime a: u64) u64 {
    return (x + a - 1) & ~(a - 1);
}

// Linker script symbols. Only their addresses are meaningful.
extern const __kernel_start: u8;
extern const __text_end: u8;
extern const __rodata_end: u8;
extern const __kernel_end: u8;

pub fn kernelStart() u64 {
    return @intFromPtr(&__kernel_start);
}

pub fn textEnd() u64 {
    return @intFromPtr(&__text_end);
}

pub fn rodataEnd() u64 {
    return @intFromPtr(&__rodata_end);
}

pub fn kernelEnd() u64 {
    return @intFromPtr(&__kernel_end);
}
