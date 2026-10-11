# p_mem.S — loads and stores at every width, signed and unsigned.
    .text
    .globl _start
_start:
    addi  x1,  x0, 0x100       # base address (word index 64)
    li    x2,  0xAABBCCDD      # expands to lui + addi
    sw    x2,  0(x1)
    lw    x3,  0(x1)           # 0xAABBCCDD
    lb    x4,  0(x1)           # 0xFFFFFFDD (byte 0, sign-extended)
    lbu   x5,  0(x1)           # 0x000000DD
    lb    x6,  3(x1)           # 0xFFFFFFAA (byte 3)
    lh    x7,  2(x1)           # 0xFFFFAABB (upper half, sign-extended)
    lhu   x8,  2(x1)           # 0x0000AABB
    sb    x0,  1(x1)           # clear byte 1 -> 0xAABB00DD
    lw    x9,  0(x1)
    sh    x0,  2(x1)           # clear upper half -> 0x000000DD
    lw    x10, 0(x1)

    # Sign-extension must use the MSB of the SELECTED byte/half. Every byte of
    # 0xAABBCCDD has its top bit set, so it cannot tell "the right sign bit"
    # from "byte 0's sign bit". These two words disagree with byte 0 on purpose.
    li    x11, 0x8000007F      # byte0=7F (+), byte3=80 (-); low half 007F (+), high 8000 (-)
    sw    x11, 4(x1)
    lb    x12, 7(x1)           # 0xFFFFFF80  (byte 0 would say positive)
    lh    x13, 6(x1)           # 0xFFFF8000  (low half would say positive)
    li    x14, 0x7F0080FF      # byte0=FF (-), byte3=7F (+); low half 80FF (-), high 7F00 (+)
    sw    x14, 8(x1)
    lb    x15, 11(x1)          # 0x0000007F  (byte 0 would say negative)
    lh    x16, 10(x1)          # 0x00007F00  (low half would say negative)
loop:
    jal   x0, loop
