/* A bare-metal EL1 guest image: raw binary loaded by the VMM at the
 * guest's RAM base (IPA 0x40000000), entered at its first byte. */

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
    . = ALIGN(4096);
    __stack_bottom = .;
    . = . + 0x4000;
    __stack_top = .;

    /DISCARD/ : { *(.eh_frame*) *(.ARM.exidx*) *(.comment) }
}
