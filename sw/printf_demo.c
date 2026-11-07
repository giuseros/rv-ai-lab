// printf_demo.c — printf on the core.  make run PROG=printf_demo
//
// No floating point (%f) and no precision (%.3d); see sw/rt/soc.h.

#include "soc.h"

int main(void)
{
    volatile int a = 6, b = 7;      // volatile: computed at run time, not by GCC
    printf("%d * %d = %d\n", a, b, a * b);         // multiply via libgcc
    printf("hex: %x  %08X  %p\n", 255, 0xbeef, (void *)&a);   // &a: on the stack
    printf("[%5d] [%-5d] [%05d]\n", 42, 42, 42);
    printf("%s, %c%c%c\n", "and strings", 'a', 'b', 'c');
    printf("64-bit: %lld\n", 9000000000LL);
    return 0;
}
