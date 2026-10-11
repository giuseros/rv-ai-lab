# p_arith.S — arithmetic, logic, shifts, comparisons, upper immediates.
    .text
    .globl _start
_start:
    addi  x1,  x0, 5           # x1 = 5
    addi  x2,  x0, -3          # x2 = 0xFFFFFFFD
    add   x3,  x1, x2          # 2
    sub   x4,  x1, x2          # 8
    and   x5,  x1, x2          # 5
    or    x6,  x1, x2          # 0xFFFFFFFD
    xor   x7,  x1, x2          # 0xFFFFFFF8
    slli  x8,  x1, 4           # 0x50
    srli  x9,  x2, 28          # 0xF        (logical: zero-fill)
    srai  x10, x2, 1           # 0xFFFFFFFE (arithmetic: sign-fill)
    slt   x11, x2, x1          # 1  (-3 < 5 signed)
    sltu  x12, x2, x1          # 0  (0xFFFFFFFD < 5 unsigned is false)
    slti  x13, x1, 10          # 1
    xori  x14, x1, -1          # 0xFFFFFFFA
    lui   x15, 0x12345         # 0x12345000
    auipc x17, 1               # pc + 0x1000
    auipc x18, 0               # pc + 0
    sub   x19, x17, x18        # 0xFFC  (PC-independent, so easy to predict)
    addi  x0,  x0, 99          # write to x0 must be discarded
    add   x20, x0,  x0         # 0 -- proves x0 still reads as zero
loop:
    jal   x0, loop
