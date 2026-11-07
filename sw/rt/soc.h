// soc.h — what a C program needs to know about the rv-ai-lab SoC
//
// There is no operating system and no C library: this is the whole "standard
// library" a program gets. The console and the exit register are reached by
// storing to their addresses, through volatile pointers so that the compiler
// performs every store exactly as written (never merges, drops or reorders
// them: each one is an action, not a memory update).

#ifndef SOC_H
#define SOC_H

#include <stdint.h>     // freestanding headers: these come with the compiler
#include <stddef.h>

// Memory map. Keep in sync with rtl/soc_map.vh.
#define CONSOLE_ADDR 0x10000000u    // store a byte: print it
#define EXIT_ADDR    0x10000004u    // store a word: end the program with that code

#define CONSOLE (*(volatile uint8_t  *)CONSOLE_ADDR)
#define EXIT    (*(volatile uint32_t *)EXIT_ADDR)

static inline void putchar(int c) { CONSOLE = (uint8_t)c; }

// End the program now (returning from main does the same).
static inline __attribute__((noreturn)) void exit(int code)
{
    EXIT = (uint32_t)code;
    for (;;) { }        // the testbench stops here; real hardware would idle
}

// sw/rt/runtime.c
// printf supports %d %i %u %x %X %c %s %p %%, '-' and '0' flags, a width, and
// l/ll (ll = 64-bit). No precision, no floating point. The format attribute
// makes GCC check the arguments against the format string (-Wformat).
int printf(const char *fmt, ...) __attribute__((format(printf, 1, 2)));
int snprintf(char *buf, size_t size, const char *fmt, ...)
    __attribute__((format(printf, 3, 4)));
// NOTE: unlike the standard puts, this one does NOT add a newline.
void puts(const char *s);                // print s (no newline added)
void print_dec(int32_t v);               // print v in decimal
void print_hex(uint32_t v);              // print v as 0x followed by 8 hex digits

// GCC may call these itself (struct copies, array initialisers), even in
// freestanding code, so every program must have them.
void  *memset(void *dst, int c, size_t n);
void  *memcpy(void *dst, const void *src, size_t n);
void  *memmove(void *dst, const void *src, size_t n);
int    memcmp(const void *a, const void *b, size_t n);
size_t strlen(const char *s);

#endif
