# p_branch.S — all six branches, each exercised taken and not-taken.
# x10 accumulates a bit per checkpoint; the +100 arms must never execute.
    .text
    .globl _start
_start:
    addi x1,  x0, 5
    addi x2,  x0, 5
    addi x3,  x0, -1           # 0xFFFFFFFF
    addi x10, x0, 0
    beq  x1, x2, b1            # taken   (5 == 5)
    addi x10, x10, 100
b1: addi x10, x10, 1
    bne  x1, x2, b2            # NOT taken
    addi x10, x10, 2
b2: blt  x3, x1, b3            # taken   (-1 < 5 signed)
    addi x10, x10, 100
b3: addi x10, x10, 4
    bltu x3, x1, b4            # NOT taken (0xFFFFFFFF < 5 unsigned is false)
    addi x10, x10, 8
b4: bge  x1, x2, b5            # taken   (5 >= 5)
    addi x10, x10, 100
b5: addi x10, x10, 16
    bgeu x3, x1, b6            # taken   (0xFFFFFFFF >= 5 unsigned)
    addi x10, x10, 100
b6: addi x10, x10, 32          # x10 = 1+2+4+8+16+32 = 63
loop:
    jal  x0, loop
