# count.S — print the digits 0..9, then exit with code 0.
#
# A minimal program to copy from. Run it with:   make run PROG=count
#
# The console is at 0x1000_0000 (store a byte = print it) and the exit
# register at 0x1000_0004 (store a word = the exit code); see rtl/soc_map.vh.
    .text
    .globl _start
_start:
    lui   x5, 0x10000          # x5 = 0x1000_0000, the console; 4(x5) is exit
    li    x6, '0'              # the character to print next
    li    x7, '9' + 1          # stop when we get here
next:
    sb    x6, 0(x5)            # print it
    addi  x6, x6, 1
    bne   x6, x7, next
    li    x6, '\n'
    sb    x6, 0(x5)
    sw    x0, 4(x5)            # exit code 0
loop:
    jal   x0, loop             # nothing left to do: wait here
