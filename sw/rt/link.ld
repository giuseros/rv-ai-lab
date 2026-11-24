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
 *
 * Three numbers can be changed from the command line (-Wl,--defsym=NAME=value);
 * the defaults are the layout above:
 *   PROG_ORIGIN  where the program starts (0). The bootloader (sw/boot.c) sits at
 *                0, so programs it loads are linked at 0x800 (make load).
 *   STACK_TOP    where the stack starts (0x4000, the top of RAM). The bootloader
 *                uses 0x800: its stack stays inside its own 2 KiB, below
 *                anything it loads.
 *   STACK_MIN    the least room the link must leave for the stack (1024 bytes)
 */

OUTPUT_ARCH(riscv)
ENTRY(_start)

MEMORY
{
    RAM (rwx) : ORIGIN = 0x00000000, LENGTH = 16K
}

SECTIONS
{
    .text (DEFINED(PROG_ORIGIN) ? PROG_ORIGIN : ORIGIN(RAM)) : {
        KEEP(*(.text.start))            /* crt0's _start, first: the entry point */
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

    /* Variables that must survive reset (the bootloader's record of the last
       load): neither in the image nor cleared by crt0. */
    .noinit (NOLOAD) : {
        . = ALIGN(4);
        *(.noinit .noinit.*)
    } > RAM

    __end = .;                          /* first free byte after the program */
    __stack_top = DEFINED(STACK_TOP) ? STACK_TOP : ORIGIN(RAM) + LENGTH(RAM);
}

/* Fail at link time rather than at run time: with no memory protection, a
   stack that runs into the program silently corrupts it. */
/* Written as a sum, not a difference: a program that ran past the stack top
   would make __stack_top - __end wrap around to a huge number, and pass. */
ASSERT(__end + (DEFINED(STACK_MIN) ? STACK_MIN : 1024) <= __stack_top,
       "program too large: not enough RAM left for the stack")
ASSERT(__stack_top <= ORIGIN(RAM) + LENGTH(RAM), "stack top outside RAM")
