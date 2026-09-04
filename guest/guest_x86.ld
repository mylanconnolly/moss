/* A bare-metal 64-bit guest image: raw binary loaded by the VMM at the
 * guest's RAM base (GPA 0x40000000), entered at its first byte, on page
 * tables and a stack the VMM built at the top of that RAM. */

ENTRY(_start)

SECTIONS
{
    . = 0x40000000;

    .text : {
        KEEP(*(.text.boot))
        *(.text*)
    }
    .rodata : { *(.rodata*) }
    .data : { *(.data*) }
    . = ALIGN(16);
    .bss : { *(.bss*) *(COMMON) }

    /DISCARD/ : { *(.eh_frame*) *(.comment) *(.note*) }
}
