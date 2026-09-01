/* QEMU virt: RAM starts at 0x40000000. The kernel links at RAM base +
 * 0x80000, matching text_offset in the arm64 Image header (boot.zig) so the
 * Linux-protocol loader places us exactly at our link address. */
ENTRY(_start)

SECTIONS
{
    . = 0x40080000;
    __kernel_start = .;

    .text : {
        KEEP(*(.text.boot))
        *(.text*)
    }

    .rodata : ALIGN(4096) {
        *(.rodata*)
    }

    .data : ALIGN(4096) {
        *(.data*)
    }

    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(16);
        __bss_end = .;
    }

    . = ALIGN(4096);
    __boot_stack_bottom = .;
    . += 64K;
    __boot_stack_top = .;

    __kernel_end = .;
    __image_size = __kernel_end - __kernel_start;
}
