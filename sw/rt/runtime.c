// runtime.c — the handful of library functions every program gets
//
// Plain C with no assumptions about the hardware beyond putchar(). Note that
// print_dec() divides by 10: on RV32I, which has no divide instruction, GCC
// turns that into calls to __udivsi3/__umodsi3 in libgcc.

#include "soc.h"
#include <stdarg.h>     // freestanding: comes with the compiler, like stdint.h

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

// ---------------------------------------------------------------------------
// printf / snprintf
//
// One formatting engine, format(), writes each character through a callback:
// printf() passes one that stores to the console, snprintf() one that fills a
// buffer. That is also what makes it testable: tb/c_basics.c checks snprintf's
// output, which exercises exactly the code printf uses.
//
// Supported:  %d %i %u %x %X %c %s %p %%
//             flags '-' (left-justify) and '0' (zero-pad), a width (digits or *)
//             l (long: 32 bits here, like int) and ll (64 bits)
// Not supported: precision (%.3d), floating point (%f), %o, %n.
// An unknown conversion is printed as written.
// ---------------------------------------------------------------------------

// Write v in the given base into the END of tmp[24]; return the digit count
// and point *start at the first digit.
static int to_digits(uint64_t v, unsigned base, int upper, char tmp[24],
                     const char **start)
{
    const char *dig = upper ? "0123456789ABCDEF" : "0123456789abcdef";
    char *p = tmp + 24;
    if ((v >> 32) == 0) {           // the usual case: 32-bit division is much
        uint32_t w = (uint32_t)v;   // cheaper than 64-bit (both are libgcc calls)
        do { *--p = dig[w % base]; w /= base; } while (w);
    } else {
        do { *--p = dig[v % base]; v /= base; } while (v);
    }
    *start = p;
    return (int)(tmp + 24 - p);
}

static int format(void (*out)(char, void *), void *ctx, const char *fmt, va_list ap)
{
    int n = 0;
    for (; *fmt; fmt++) {
        if (*fmt != '%') { out(*fmt, ctx); n++; continue; }
        if (*++fmt == '\0')
            break;

        // flags, width, length
        int left = 0, zero = 0, width = 0, lng = 0;
        for (;; fmt++) {
            if (*fmt == '-')      left = 1;
            else if (*fmt == '0') zero = 1;
            else break;
        }
        if (*fmt == '*') {
            width = va_arg(ap, int);
            if (width < 0) { left = 1; width = -width; }
            fmt++;
        } else {
            while (*fmt >= '0' && *fmt <= '9')
                width = width * 10 + (*fmt++ - '0');
        }
        while (*fmt == 'l') { lng++; fmt++; }

        // the conversion: produces an optional prefix ("-", "0x") and a body
        char        tmp[24];
        const char *body   = tmp;
        const char *prefix = "";
        int         len    = 0;
        switch (*fmt) {
        case 'c':
            tmp[0] = (char)va_arg(ap, int);
            len = 1;
            zero = 0;
            break;
        case 's':
            body = va_arg(ap, const char *);
            if (!body)
                body = "(null)";
            len = (int)strlen(body);
            zero = 0;
            break;
        case 'd':
        case 'i': {
            int64_t v = (lng >= 2) ? va_arg(ap, long long) : va_arg(ap, int);
            if (v < 0)
                prefix = "-";
            len = to_digits(v < 0 ? -(uint64_t)v : (uint64_t)v, 10, 0, tmp, &body);
            break;
        }
        case 'u':
        case 'x':
        case 'X': {
            uint64_t v = (lng >= 2) ? va_arg(ap, unsigned long long) : va_arg(ap, unsigned);
            len = to_digits(v, *fmt == 'u' ? 10 : 16, *fmt == 'X', tmp, &body);
            break;
        }
        case 'p':                       // always 0x + 8 hex digits
            prefix = "0x";
            zero = 1;
            width = 10;
            len = to_digits((uintptr_t)va_arg(ap, void *), 16, 0, tmp, &body);
            break;
        case '%':
            tmp[0] = '%';
            len = 1;
            break;
        default:                        // unknown: print it as written
            tmp[0] = '%';
            tmp[1] = *fmt;
            len = 2;
            break;
        }

        // pad to the width: spaces before, zeros after the prefix, or spaces after
        int pad = width - len - (int)strlen(prefix);
        if (!left && !zero) for (; pad > 0; pad--) { out(' ', ctx); n++; }
        for (const char *p = prefix; *p; p++)       { out(*p, ctx);  n++; }
        if (!left && zero)  for (; pad > 0; pad--) { out('0', ctx); n++; }
        for (int i = 0; i < len; i++)               { out(body[i], ctx); n++; }
        if (left)           for (; pad > 0; pad--) { out(' ', ctx); n++; }
    }
    return n;
}

static void to_console(char c, void *ctx)
{
    (void)ctx;
    putchar(c);
}

struct buffer { char *buf; size_t size, len; };

static void to_buffer(char c, void *ctx)
{
    struct buffer *b = ctx;
    if (b->len + 1 < b->size)           // always leave room for the final '\0'
        b->buf[b->len] = c;
    b->len++;
}

int printf(const char *fmt, ...)
{
    va_list ap;
    va_start(ap, fmt);
    int n = format(to_console, 0, fmt, ap);
    va_end(ap);
    return n;
}

int snprintf(char *buf, size_t size, const char *fmt, ...)
{
    struct buffer b = { buf, size, 0 };
    va_list ap;
    va_start(ap, fmt);
    int n = format(to_buffer, &b, fmt, ap);
    va_end(ap);
    if (size)
        buf[b.len < size ? b.len : size - 1] = '\0';
    return n;                           // the length it WOULD have had, like C's
}
