//! Boot entry: the only assembly between QEMU and kmain.
//!
//! The kernel boots as a raw arm64 Image (Linux boot protocol): the 64-byte
//! header below tells the loader to place us at RAM base + 0x80000 (our link
//! address) and guarantees x0 = physical address of the devicetree blob, MMU
//! and caches off. QEMU's virt machine only puts a DTB in guest RAM for this
//! protocol — ELF loads get none. Only core 0 runs at boot; secondaries wait
//! for PSCI CPU_ON (Phase 2).

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
        \\        adrp    x1, __bss_start
        \\        add     x1, x1, :lo12:__bss_start
        \\        adrp    x2, __bss_end
        \\        add     x2, x2, :lo12:__bss_end
        \\3:      cmp     x1, x2
        \\        b.hs    4f
        \\        str     xzr, [x1], #8
        \\        b       3b
        \\4:
        \\        adrp    x1, __boot_stack_top
        \\        add     x1, x1, :lo12:__boot_stack_top
        \\        mov     sp, x1
        \\        b       kmain
    );
}
