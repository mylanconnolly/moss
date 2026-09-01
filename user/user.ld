/* Flat MOSS user image: MOSS header first, then text; page-aligned
 * boundaries so the kernel can map text R+X and everything after RW. */

ENTRY(_ustart)

SECTIONS
{
    . = 0x400000;

    .text : {
        KEEP(*(.text.uhdr))
        *(.text*)
    }
    . = ALIGN(4096);
    __utext_end = .;

    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    . = ALIGN(4096);
    __uload_end = .;

    .bss : { *(.bss*) *(COMMON) }
    . = ALIGN(4096);
    __umem_end = .;

    __utext_size = __utext_end - 0x400000;
    __uload_size = __uload_end - 0x400000;
    __umem_size = __umem_end - 0x400000;
}
