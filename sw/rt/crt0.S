# crt0.S — the C runtime startup: everything that runs before main()
#
# The CPU leaves reset with PC = 0 and every register unspecified. Compiled C
# code assumes more than that, so this sets it up:
#
#   1. gp, the global pointer  (the linker uses it for short global accesses)
#   2. sp, the stack pointer   (C keeps return addresses and locals there)
#   3. .bss is all zeroes      (C promises uninitialised globals start at 0)
#
# then calls main() and hands its return value to the exit register, which is
# how the testbench learns the program's exit code. link.ld puts _start at
# address 0, where the CPU begins.

    .section .text.start, "ax"
    .globl _start
_start:
    # gp must be set with a plain lui/addi: the linker could otherwise "relax"
    # this very instruction into one relative to gp, which is not set yet
    .option push
    .option norelax
    la      gp, __global_pointer$
    .option pop

    la      sp, __stack_top         # top of RAM; the stack grows down

    # zero .bss, one word at a time
    la      t0, __bss_start
    la      t1, __bss_end
1:  bgeu    t0, t1, 2f
    sw      zero, 0(t0)
    addi    t0, t0, 4
    j       1b
2:
    li      a0, 0                   # main(argc = 0, argv = NULL)
    li      a1, 0
    call    main

    # main returned: its result (a0) is the exit code
    lui     t0, 0x10000             # 0x1000_0000; the exit register is at +4
    sw      a0, 4(t0)
3:  j       3b                      # nothing left to run
