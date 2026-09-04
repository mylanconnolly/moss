//! Boot entry: Limine (base revision 5) lands in `_start` in 64-bit mode
//! with the kernel mapped in the high half at its link address, the
//! loader's own direct map at an offset it chose, interrupts off, and a
//! stack in memory the loader owns.
//!
//! Before kmain the entry builds this port's own coarse direct map —
//! 1 GB pages for the first 64 GB at `kvirt_offset` (PML4 slot 256) —
//! next to the loader's kernel mapping (PML4 slot 511, copied), so that
//! every `mem.physToPtr` works from the first line of kmain, exactly as
//! the aarch64 entry's boot L1 does. mmu.init then rebuilds the tables
//! with 4K-granular W^X and drops the loader's. The stack moves into the
//! image (`__boot_stack_top`), so no loader memory is live afterwards.
//!
//! The requests sit in `.limine_requests`, between the start and end
//! markers the linker script keeps in order.

const limine = @import("limine.zig");
const console = @import("console.zig");
const cpu = @import("cpu.zig");

pub const kvirt_offset: u64 = 0xffff_8000_0000_0000;

export var limine_requests_start: [4]u64 linksection(".limine_requests_start") = .{ 0xf6b8f4b39de7d1ae, 0xfab91a6940fcb9cf, 0x785c6ed015d3e316, 0x181e920a7852b9d9 };
export var limine_requests_end: [2]u64 linksection(".limine_requests_end") = .{ 0xadc0e0531bb10d03, 0x9572709f31764c62 };

/// The loader writes [1] (the revision it used) and zeroes [2] when it
/// supports what we asked for.
pub export var limine_base_revision: [3]u64 linksection(".limine_requests") = .{ 0xf9562b2d5c95a6c8, 0x6a7b384944536bdc, 5 };

pub export var memmap_request: limine.MemmapRequest linksection(".limine_requests") = .{};
pub export var hhdm_request: limine.HhdmRequest linksection(".limine_requests") = .{};
pub export var executable_address_request: limine.ExecutableAddressRequest linksection(".limine_requests") = .{};
pub export var cmdline_request: limine.CmdlineRequest linksection(".limine_requests") = .{};
pub export var rsdp_request: limine.RsdpRequest linksection(".limine_requests") = .{};
pub export var tsc_request: limine.TscFrequencyRequest linksection(".limine_requests") = .{};
pub export var mp_request: limine.MpRequest linksection(".limine_requests") = .{};
pub export var bootloader_info_request: limine.BootloaderInfoRequest linksection(".limine_requests") = .{};

extern var __boot_pml4: [512]u64 align(4096);
extern var __boot_pdpt: [512]u64 align(4096);
extern const __boot_stack_top: anyopaque;

const pte_present: u64 = 1 << 0;
const pte_write: u64 = 1 << 1;
const pte_huge: u64 = 1 << 7;
const pte_nx: u64 = 1 << 63;

/// The loader's view of our image (physical base), kept for mmu.init.
pub var image_phys_base: u64 = 0;
pub var image_virt_base: u64 = 0;
pub var hhdm_offset: u64 = 0;

export fn _start() callconv(.c) noreturn {
    console.init();
    if (limine_base_revision[2] != 0) {
        console.write("moss: the loader does not speak Limine base revision 5\n");
        halt();
    }
    const hhdm = hhdm_request.response orelse fail("no HHDM");
    const addr = executable_address_request.response orelse fail("no executable address");
    hhdm_offset = hhdm.offset;
    image_phys_base = addr.physical_base;
    image_virt_base = addr.virtual_base;

    // Our direct map beside the loader's kernel mapping. The loader's
    // tables are reachable through its HHDM.
    const cr3 = cpu.readCr3();
    const loader_pml4: [*]const u64 = @ptrFromInt((cr3 & 0x000f_ffff_ffff_f000) + hhdm.offset);
    for (&__boot_pml4) |*e| e.* = 0;
    __boot_pml4[511] = loader_pml4[511];
    for (&__boot_pdpt, 0..) |*e, i| e.* = (@as(u64, i) << 30) | pte_present | pte_write | pte_huge | pte_nx;
    __boot_pml4[256] = imagePhys(@intFromPtr(&__boot_pdpt)) | pte_present | pte_write;
    cpu.writeCr3(imagePhys(@intFromPtr(&__boot_pml4)));

    // Onto the image's own stack, and into the generic kernel.
    asm volatile (
        \\mov %[sp], %%rsp
        \\xor %%rdi, %%rdi
        \\xor %%rbp, %%rbp
        \\call kmain
        :
        : [sp] "r" (@intFromPtr(&__boot_stack_top)),
        : .{ .memory = true });
    unreachable;
}

/// A virtual address inside the image to its physical one, the way the
/// loader placed it.
pub fn imagePhys(va: u64) u64 {
    return va - image_virt_base + image_phys_base;
}

fn fail(msg: []const u8) noreturn {
    console.write("moss: boot: ");
    console.write(msg);
    console.write("\n");
    halt();
}

fn halt() noreturn {
    while (true) asm volatile ("cli; hlt");
}
