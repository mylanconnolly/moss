/* The kernel links in the high half: TTBR1 with T1SZ=25 gives a 512GB
 * kernel space at 0xffffff8000000000, and the direct map places
 * virt = phys + 0xffffff8000000000. QEMU virt RAM starts at 0x40000000 and
 * the arm64 Image header (boot.zig) requests loading at RAM base + 0x80000,
 * so the image runs at physical 0x40080000 until boot.zig enables the MMU. */

KERNEL_VIRT_OFFSET = 0xffffff8000000000;

ENTRY(_start)

SECTIONS
{
    . = KERNEL_VIRT_OFFSET + 0x40080000;
    __kernel_start = .;

    .text : {
        KEEP(*(.text.boot))
        . = ALIGN(2048);
        KEEP(*(.text.vectors))
        *(.text*)
    }
    . = ALIGN(4096);
    __text_end = .;

    .rodata : {
        *(.rodata*)
    }
    . = ALIGN(4096);
    __rodata_end = .;

    .data : {
        *(.data*)
    }

    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4096);
        __boot_l1_table = .;
        . += 4096;
        __bss_end = .;
    }

    . = ALIGN(4096);
    __boot_stack_bottom = .;
    . += 64K;
    __boot_stack_top = .;

    __kernel_end = .;
    __image_size = __kernel_end - __kernel_start;
}
