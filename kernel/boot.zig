//! Boot entry: the only assembly between QEMU and kmain.
//!
//! The kernel boots as a raw arm64 Image (Linux boot protocol): the 64-byte
//! header below tells the loader to place us at RAM base + 0x80000 and
//! guarantees x0 = physical address of the devicetree blob, MMU and caches
//! off. QEMU's virt machine only puts a DTB in guest RAM for this protocol —
//! ELF loads get none. Only core 0 runs at boot; secondaries wait for PSCI
//! CPU_ON (Phase 2).
//!
//! The kernel links in the high half, so this code runs below its link
//! address until the MMU is on: it must stay position-independent, converting
//! linker symbols to physical with the KERNEL_VIRT_OFFSET constant and never
//! using adrp. It builds one coarse L1 table — 1GB blocks: [0] device (UART,
//! GIC), [1..3] normal RAM, executable — shared by TTBR0 (identity, for the
//! enable transition) and TTBR1 (direct map; both halves index identically
//! here, so one table serves). kmain later rebuilds TTBR1 with 4K-granular
//! W^X from the real memory map and disables TTBR0 via TCR.EPD0.
//!
//! Cache/TLB invalidation before enable is minimal (QEMU-clean, not yet
//! real-hardware-clean).
//!
//! TCR 0x2b5193519: T0SZ=T1SZ=25 (39-bit), 4K granules both halves, WB WA
//! inner-shareable walks, 40-bit IPS. MAIR: idx0 Device-nGnRnE, idx1 Normal
//! WB WA.

comptime {
    asm (
        \\.section .text.boot, "ax"
        \\.global _image_header
        \\_image_header:
        \\        b       _start                          // code0
        \\        .word   0                               // code1
        \\        .quad   0x80000                         // text_offset from 2M-aligned RAM base
        \\        .quad   __image_size                    // incl. BSS + boot stack (from linker script)
        \\        .quad   2                               // flags: little-endian, 4K pages
        \\        .quad   0
        \\        .quad   0
        \\        .quad   0
        \\        .ascii  "ARM\x64"
        \\        .word   0
        \\.global _start
        \\_start:
        \\        // x0 (DTB pointer) is preserved untouched through to kmain.
        \\        mrs     x1, mpidr_el1
        \\        and     x1, x1, #0xff
        \\        cbz     x1, 2f
        \\1:      wfe
        \\        b       1b
        \\2:
        \\        ldr     x10, =0xffffff8000000000        // KERNEL_VIRT_OFFSET
        \\
        \\        // Clear BSS (physical addresses; boot L1 table lives inside).
        \\        ldr     x1, =__bss_start
        \\        sub     x1, x1, x10
        \\        ldr     x2, =__bss_end
        \\        sub     x2, x2, x10
        \\3:      cmp     x1, x2
        \\        b.hs    4f
        \\        str     xzr, [x1], #8
        \\        b       3b
        \\4:
        \\        // Coarse boot L1: [0] = 1GB device block at PA 0
        \\        //                 [1..3] = 1GB normal RAM blocks
        \\        ldr     x1, =__boot_l1_table
        \\        sub     x1, x1, x10
        \\        ldr     x2, =0x0060000000000401         // device: UXN|PXN|AF|AttrIdx0|block
        \\        str     x2, [x1]
        \\        ldr     x2, =0x0040000000000705         // normal: UXN|AF|SH=inner|AttrIdx1|block
        \\        mov     x3, #1
        \\5:      cmp     x3, #4
        \\        b.hs    6f
        \\        lsl     x4, x3, #30
        \\        orr     x5, x2, x4
        \\        str     x5, [x1, x3, lsl #3]
        \\        add     x3, x3, #1
        \\        b       5b
        \\6:
        \\        ldr     x2, =0xff00
        \\        msr     mair_el1, x2
        \\        ldr     x2, =0x2b5193519
        \\        msr     tcr_el1, x2
        \\        msr     ttbr0_el1, x1
        \\        msr     ttbr1_el1, x1
        \\        dsb     ish
        \\        isb
        \\        mrs     x2, sctlr_el1
        \\        ldr     x3, =0x1005                     // M | C | I
        \\        orr     x2, x2, x3
        \\        msr     sctlr_el1, x2
        \\        isb
        \\
        \\        // High half from here on.
        \\        ldr     x1, =__boot_stack_top
        \\        mov     sp, x1
        \\        ldr     x1, =kmain
        \\        br      x1
    );
}
