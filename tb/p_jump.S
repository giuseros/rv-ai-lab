# p_jump.S — jal/jalr, the return-address link, and the jalr LSB mask.
    .text
    .globl _start
_start:
    addi x10, x0, 0
    jal  x1, func              # x1 <- address of the next instruction (8)
    addi x10, x10, 1           # return lands here
    jal  x0, cont
func:
    addi x10, x10, 8
    jalr x0, 0(x1)             # return
cont:
    addi x10, x10, 16
    la   x6, target            # auipc + addi
    addi x6, x6, 1             # deliberately ODD
    jalr x0, 0(x6)             # spec requires clearing bit 0
    addi x10, x10, 100         # must be skipped
target:
    addi x10, x10, 32          # x10 = 8+1+16+32 = 57
loop:
    jal  x0, loop
