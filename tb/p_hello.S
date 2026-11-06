# p_hello.S — print a string on the console, then exit with code 42.
#
# The console lives at 0x1000_0000 (store a byte = print it) and the exit
# register at 0x1000_0004 (store a word = the exit code); see rtl/soc_map.vh.
# To the CPU these are ordinary stores: only the bus knows they are not RAM.
    .text
    .globl _start
_start:
    lui   x5, 0x10000          # x5 = 0x1000_0000: console; 4(x5) is exit
    la    x6, msg              # x6 = address of the string (auipc + addi)
next:
    lbu   x7, 0(x6)            # next character, from RAM
    beq   x7, x0, done         # a 0 byte ends the string
    sb    x7, 0(x5)            # print it
    addi  x6, x6, 1
    jal   x0, next
done:
    li    x8, 42
    sw    x8, 4(x5)            # exit code 42
loop:
    jal   x0, loop

    .section .rodata
msg:
    .string "hello\n"          # .string adds the terminating 0 byte
