// soc.h — what a C program needs to know about the rv-ai-lab SoC
//
// There is no operating system and no C library: this is the whole "standard
// library" a program gets. The console's registers are reached by loading
// from and storing to their addresses, through volatile pointers so that the
// compiler performs every access exactly as written (never merges, drops or
// reorders them: each one is an action, not a memory update; loading RX_DATA
// takes a byte, so even a load whose value is unused must happen).

#ifndef SOC_H
#define SOC_H

#include <stdint.h>     // freestanding headers: these come with the compiler
#include <stddef.h>

// Memory map. Keep in sync with rtl/soc_map.vh.
#define CONSOLE_ADDR 0x10000000u    // store a byte: print it
#define EXIT_ADDR    0x10000004u    // store a word: end the program with that code
#define RX_DATA_ADDR 0x10000008u    // load: the oldest byte received, or < 0 if none
#define RX_STAT_ADDR 0x1000000Cu    // load: receiver status; store: clear flags

#define CONSOLE (*(volatile uint8_t  *)CONSOLE_ADDR)
#define EXIT    (*(volatile uint32_t *)EXIT_ADDR)
#define RX_DATA (*(volatile int32_t  *)RX_DATA_ADDR)
#define RX_STAT (*(volatile uint32_t *)RX_STAT_ADDR)

// RX_STAT bits. WAITING is live; DROPPED and FRAMING are sticky: they stay set
// until a 1 is stored to them ("write 1 to clear"). Loading RX_STAT changes
// nothing, so it is safe to poll. To handle errors: s = RX_STAT, act on it,
// then RX_STAT = s clears exactly the flags that were seen.
#define RX_WAITING   1u     // a byte is waiting (RX_DATA would return it)
#define RX_DROPPED   2u     // a byte arrived with the FIFO full and was lost
#define RX_FRAMING   4u     // a byte arrived with a stop bit of 0 (kept anyway)

// Received bytes wait in a FIFO of this many bytes (console.v's RX_DEPTH):
// the program may fall this far behind the line before bytes are lost.
#define RX_FIFO_BYTES 16

// The character also goes out of the serial line. The line is slow, so a
// store that finds it still sending the previous character waits (the CPU
// stalls) until it is free: printing costs time, but nothing is ever lost.
static inline void putchar(int c) { CONSOLE = (uint8_t)c; }

// Wait for a byte from the serial line and return it (0..255). One load both
// asks and takes: RX_DATA is negative while nothing has arrived. Unlike the
// standard getchar there is no EOF: it waits for as long as it takes.
static inline int getchar(void)
{
    int32_t c;
    do c = RX_DATA; while (c < 0);
    return (int)c;
}

// End the program now (returning from main does the same). The store waits
// until the serial line has sent everything printed.
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
