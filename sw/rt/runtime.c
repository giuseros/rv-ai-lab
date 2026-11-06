// runtime.c — the handful of library functions every program gets
//
// Plain C with no assumptions about the hardware beyond putchar(). Note that
// print_dec() divides by 10: on RV32I, which has no divide instruction, GCC
// turns that into calls to __udivsi3/__umodsi3 in libgcc.

#include "soc.h"

void puts(const char *s)
{
    while (*s)
        putchar(*s++);
}

void print_dec(int32_t v)
{
    char     buf[11];                       // 10 digits for 2^32, plus sign
    int      n = 0;
    uint32_t u = (v < 0) ? -(uint32_t)v : (uint32_t)v;   // INT32_MIN-safe

    do {
        buf[n++] = (char)('0' + u % 10);
        u /= 10;
    } while (u);
    if (v < 0)
        putchar('-');
    while (n)
        putchar(buf[--n]);
}

void print_hex(uint32_t v)
{
    puts("0x");
    for (int shift = 28; shift >= 0; shift -= 4)
        putchar("0123456789abcdef"[(v >> shift) & 0xf]);
}

void *memset(void *dst, int c, size_t n)
{
    uint8_t *d = dst;
    while (n--)
        *d++ = (uint8_t)c;
    return dst;
}

void *memcpy(void *dst, const void *src, size_t n)
{
    uint8_t *d = dst;
    const uint8_t *s = src;
    while (n--)
        *d++ = *s++;
    return dst;
}

void *memmove(void *dst, const void *src, size_t n)
{
    uint8_t *d = dst;
    const uint8_t *s = src;
    if (d < s) {
        while (n--) *d++ = *s++;
    } else {
        d += n; s += n;
        while (n--) *--d = *--s;
    }
    return dst;
}

int memcmp(const void *a, const void *b, size_t n)
{
    const uint8_t *p = a, *q = b;
    for (; n; n--, p++, q++)
        if (*p != *q)
            return *p - *q;
    return 0;
}

size_t strlen(const char *s)
{
    size_t n = 0;
    while (s[n])
        n++;
    return n;
}
