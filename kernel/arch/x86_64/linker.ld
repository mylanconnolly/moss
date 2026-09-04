/* The kernel links in the top 2 GB (the x86_64 "kernel" code model), where
 * Limine maps it at its link address; the direct map is a separate PML4
 * slot the boot entry builds (boot.zig). The Limine requests keep their
 * order — start marker, requests, end marker — inside .data. */

KERNEL_VIRT_BASE = 0xffffffff80000000;

ENTRY(_start)

PHDRS
{
    text   PT_LOAD FLAGS(5);
    rodata PT_LOAD FLAGS(4);
    data   PT_LOAD FLAGS(6);
}

SECTIONS
{
    . = KERNEL_VIRT_BASE;
    __kernel_start = .;

    .text : {
        *(.text*)
    } :text
    . = ALIGN(4096);
    __text_end = .;

    .rodata : {
        *(.rodata*)
    } :rodata
    . = ALIGN(4096);
    __rodata_end = .;

    .data : {
        *(.data*)
        . = ALIGN(8);
        KEEP(*(.limine_requests_start))
        KEEP(*(.limine_requests))
        KEEP(*(.limine_requests_end))
    } :data

    .bss : ALIGN(4096) {
        __bss_start = .;
        *(.bss*)
        *(COMMON)
        . = ALIGN(4096);
        __boot_pml4 = .;
        . += 4096;
        __boot_pdpt = .;
        . += 4096;
        __boot_stack_bottom = .;
        . += 64K;
        __boot_stack_top = .;
        __bss_end = .;
    } :data

    __kernel_end = .;
    __image_size = __kernel_end - __kernel_start;

    /DISCARD/ : { *(.eh_frame*) *(.note*) *(.comment) }
}
