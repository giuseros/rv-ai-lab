/* link.ld — where a C program goes in the rv-ai-lab SoC's memory
 *
 * The SoC has 16 KiB of RAM at address 0 (rtl/soc_map.vh), holding code, data
 * and the stack together. This script tells the linker that, and lays the
 * program out like this:
 *
 *   0x0000  .text    code: crt0's _start first, because the CPU starts at 0
 *           .rodata  constants and string literals
 *           .data    initialised globals
 *           .bss     zero-initialised globals (crt0 clears them)
 *           ------   end of the program: free space from here up
 *                    (the heap would grow upward from here, later)
 *   0x4000  stack    starts at the top of RAM and grows downward
 *
 * The whole image, .data included, is placed into RAM by $readmemh before the
 * CPU starts, so unlike a real chip booting from flash there is nothing to copy.
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text : {
        KEEP(*(.text.start))            /* crt0's _start, at address 0 */
        *(.text .text.*)
    } > RAM

    .rodata : {
        *(.rodata .rodata.* .srodata .srodata.*)
    } > RAM

    .data : {
        *(.data .data.*)
        /* gp points into the middle of the small-data area, so the linker can
           reach any small global with a single gp-relative instruction */
        __global_pointer$ = . + 0x800;
        *(.sdata .sdata.*)
    } > RAM

    .bss (NOLOAD) : {
        . = ALIGN(4);
        __bss_start = .;
        *(.sbss .sbss.* .bss .bss.* COMMON)
        . = ALIGN(4);
        __bss_end = .;
    } > RAM

    __end = .;                          /* first free byte after the program */
    __stack_top = ORIGIN(RAM) + LENGTH(RAM);
}

/* Fail at link time rather than at run time: with no memory protection, a
   stack that runs into the program silently corrupts it. */
ASSERT(__stack_top - __end >= 1024,
       "program too large: less than 1 KiB of RAM left for the stack")
