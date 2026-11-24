// boot.c — the bootloader: receive a program over the serial line, then run it.
//   make fpga BOARD=de10-lite TOP=soc PROG=boot     (once: it is the RAM's contents)
//   make load PROG=<prog>                           (every program after that)
//
// RAM is shared (layout A):
//
//   0x0000  the bootloader: code, data, and its stack, growing down from
//           0x800 (its link: STACK_TOP = the Makefile's LOAD_ORIGIN)
//   0x0800  __load_addr: the program it receives, linked to run there
//           (PROG_ORIGIN = LOAD_ORIGIN), with its own .bss and stack above
//   0x3FFF
//
// so receiving never overwrites the bootloader, and after reset (KEY[0]) the
// CPU, which starts at 0, is back in the bootloader.
//
// After reset (as on an Arduino): it prints "boot: ready" and waits about a
// second for a new program (make load sends one as soon as it sees that line).
// If none comes, it reruns the last program loaded, still in RAM: reset erases
// nothing. It knows there is one from a record of the last load (length and
// CRC) kept where crt0 does not clear it (.noinit), and it reruns it only if
// the RAM still matches that CRC:
//   boot: running the last program
//   boot: last program changed, send it again   (it wrote to its own image:
//       e.g. an initialised global. Rerun, it would start from the values its
//       last run left, not the ones it was built with; .bss and the stack are
//       outside the image, and its crt0 resets those itself)
// At power-on the record is garbage (no valid magic), so it just waits.
//
// What the PC sends:
//   "RVLD"   4 bytes, the magic: a program follows. Found by sliding a window
//            over the last 4 bytes received, so whatever came before (typing,
//            a half-sent frame) is skipped
//   length   4 bytes, little-endian: 1 .. 0x3800 (the RAM above 0x800)
//   program  length bytes, stored from 0x800 up
//   CRC32    4 bytes, little-endian: the CRC of the program bytes, as zlib's
//            crc32 (Python: zlib.crc32(data))
// It answers with one line, then either runs the program or waits for the next
// frame:
//   boot: ok                  the program is in RAM: running it
//   boot: bad length          (nothing stored)
//   boot: bad checksum        the bytes differ from what was sent
//   boot: bytes lost          the receiver dropped a byte or saw a framing error
// A frame cut short leaves it waiting for the missing bytes: press KEY[0].
//
// Speed: storing a byte and updating the CRC take a few dozen cycles, and a
// byte arrives every ~2,170 cycles at 115200 baud and 25 MHz: the line is the
// limit, ~11 KB/s, about a second for a typical program.
//
// It is linked with crt0 only: runtime.c's printf would take most of its 2 KiB.
//
// WAIT_POLLS: how long "about a second" is, in polls of the receiver. There is no
// timer yet, so it is a loop count: each poll is ~5 cycles, so 5,000,000 is about
// a second at 25 MHz. The simulation builds it with a short wait (Makefile).

#include "soc.h"

// Where programs go: a symbol the link defines (the Makefile's LOAD_ORIGIN, the
// same number programs are linked at), so the address is written in one place.
extern volatile uint8_t __load_addr[];

#ifndef WAIT_POLLS
#define WAIT_POLLS 5000000u
#endif

#define RAM_END   0x4000u
#define MAGIC     0x444C5652u           // 'R','V','L','D' read as a little-endian word
#define LAST_OK   0x5453414Cu           // 'L','A','S','T': the record below is valid

// The last program loaded. In .noinit, which crt0 does not zero: it survives
// reset. (Power-on leaves whatever the RAM held: no LAST_OK, no rerun.)
static struct { uint32_t magic, len, crc; } last __attribute__((section(".noinit")));

static void say(const char *s)
{
    while (*s) putchar(*s++);
}

static uint32_t get_word(void)          // 4 bytes, little-endian
{
    uint32_t w = 0;
    for (int i = 0; i < 32; i += 8)
        w |= (uint32_t)getchar() << i;
    return w;
}

// CRC-32 (the zlib/Ethernet one: reflected, polynomial 0xEDB88320), four bits
// at a time from a 16-entry table: two lookups per byte, 64 bytes of table.
static const uint32_t crc_table[16] = {
    0x00000000, 0x1DB71064, 0x3B6E20C8, 0x26D930AC,
    0x76DC4190, 0x6B6B51F4, 0x4DB26158, 0x5005713C,
    0xEDB88320, 0xF00F9344, 0xD6D6A3E8, 0xCB61B38C,
    0x9B64C2B0, 0x86D3D2D4, 0xA00AE278, 0xBDBDF21C,
};

static uint32_t crc_add(uint32_t crc, uint32_t byte)
{
    crc ^= byte;
    crc = (crc >> 4) ^ crc_table[crc & 15];
    crc = (crc >> 4) ^ crc_table[crc & 15];
    return crc;
}

static uint32_t crc_of(volatile uint8_t *p, uint32_t len)
{
    uint32_t crc = 0xFFFFFFFFu;
    for (uint32_t i = 0; i < len; i++)
        crc = crc_add(crc, p[i]);
    return ~crc;
}

static void run(void)
{
    ((void (*)(void))__load_addr)();                    // its crt0 takes it from here
}

int main(void)
{
    say("\nboot: ready\n");

    // A new program within about a second? Otherwise rerun the last one.
    if (last.magic == LAST_OK && last.len > 0 &&
        last.len <= RAM_END - (uint32_t)__load_addr) {
        uint32_t n = 0;
        while (n < WAIT_POLLS && !(RX_STAT & RX_WAITING))
            n++;
        if (n == WAIT_POLLS) {                          // nothing came
            if (crc_of(__load_addr, last.len) == last.crc) {
                say("boot: running the last program\n");
                run();
            }
            say("boot: last program changed, send it again\n");
        }
    }

    for (;;) {
        uint32_t w = 0;
        while (w != MAGIC)                              // the last 4 bytes
            w = (w >> 8) | ((uint32_t)getchar() << 24);

        uint32_t s = RX_STAT;                           // forget anything before
        RX_STAT = s;                                    // this frame

        uint32_t len = get_word();
        if (len == 0 || len > RAM_END - (uint32_t)__load_addr) {
            say("boot: bad length\n");
            continue;
        }

        volatile uint8_t *p = __load_addr;
        uint32_t crc = 0xFFFFFFFFu;
        for (uint32_t i = 0; i < len; i++) {
            uint32_t c = (uint32_t)getchar();
            p[i] = (uint8_t)c;
            crc = crc_add(crc, c);
        }
        crc = ~crc;

        uint32_t want = get_word();
        s = RX_STAT;
        if (s & (RX_DROPPED | RX_FRAMING)) {
            RX_STAT = s;
            say("boot: bytes lost\n");
            continue;
        }
        if (crc != want) {
            say("boot: bad checksum\n");
            continue;
        }
        last.magic = LAST_OK;                           // for the next reset
        last.len   = len;
        last.crc   = crc;
        say("boot: ok\n");
        run();
    }
}
