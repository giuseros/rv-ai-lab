// c_rx.c — regression test: reading the serial line (the console's receiver)
//
// soc_tb plays the user at the other end of the line. Each time this program
// prints a prompt ("1> ", "2> ", ...), the testbench's typist (rx_typist in
// tb/soc_tb.v) types the next item of a fixed script, so both sides know what
// is coming:
//
//   1> "Hello, RISC-V!\n"  back to back, read with getchar() (the RX_DATA way:
//                          one load asks and takes)
//   2> "31415926\n"        read by polling RX_STAT, then loading RX_DATA (the
//                          other way); the digits add up to 31
//   3> "z"                 an addi whose result is RX_DATA_ADDR takes nothing:
//                          only real loads reach the console (d_valid)
//   4> "ABCDEFGHIJKLMNOPQ" 17 bytes while the program does not read: the FIFO
//                          keeps the first RX_FIFO_BYTES (16), in order, and
//                          the 17th is dropped and flagged
//   5> 'x', stop bit 0     the framing flag; the byte is delivered anyway
//
// After each item nothing may be left over: RX_STAT must read 0 once the
// flags seen have been cleared (s = RX_STAT; RX_STAT = s).
// It exits with the number of failures: exit code 0 means everything passed.
// It waits for input, so `make run PROG=c_rx` (nobody typing) waits forever:
// it is a soc_tb program.

#include "soc.h"

static int failures;

static void check(const char *name, uint32_t got, uint32_t want)
{
    if (got == want) {
        printf("  ok  %s\n", name);
    } else {
        failures++;
        printf("FAIL  %s: got 0x%lx, want 0x%lx\n", name, got, want);
    }
}

static void check_str(const char *name, const char *got, const char *want)
{
    if (memcmp(got, want, strlen(want) + 1) == 0) {
        printf("  ok  %s\n", name);
    } else {
        failures++;
        printf("FAIL  %s: got \"%s\", want \"%s\"\n", name, got, want);
    }
}

// Nothing left in the FIFO, no flags: clear what is set, then it must read 0.
static void check_clean(const char *name)
{
    uint32_t s = RX_STAT;
    RX_STAT = s;                    // write 1 to clear: exactly the flags seen
    check(name, RX_STAT, 0);
}

// The other way to wait: poll the status (no side effect), then take the byte.
static int getchar_polled(void)
{
    while (!(RX_STAT & RX_WAITING)) { }
    return (int)(RX_DATA & 0xFF);
}

// Read up to '\n' (not stored) into buf, at most size-1 characters.
static int read_line(char *buf, int size, int (*get)(void))
{
    int n = 0, c;
    while ((c = get()) != '\n')
        if (n < size - 1) buf[n++] = (char)c;
    buf[n] = '\0';
    return n;
}

static int prompt(int item) { return printf("%d> ", item); }

int main(void)
{
    char line[40];
    int  n, sum;
    uint32_t s;

    puts("c_rx: reading the serial line\n");
    check("nothing has arrived yet: RX_STAT 0", RX_STAT, 0);
    check("RX_DATA empty: 0x80000000", (uint32_t)RX_DATA, 0x80000000u);

    // ---- 1: a line, back to back, with getchar() ----
    prompt(1);
    n = read_line(line, sizeof line, getchar);
    putchar('\n');
    check_str("1 getchar: the line, in order", line, "Hello, RISC-V!");
    check("1 getchar: 14 characters", n, 14);
    check_clean("1 nothing left over");

    // ---- 2: polling RX_STAT ----
    prompt(2);
    n = read_line(line, sizeof line, getchar_polled);
    putchar('\n');
    sum = 0;
    for (int i = 0; i < n; i++) sum += line[i] - '0';
    check_str("2 polled: the digits", line, "31415926");
    check("2 polled: their sum", sum, 31);
    check_clean("2 nothing left over");

    // ---- 3: computing RX_DATA's address is not reading it ----
    prompt(3);
    while (!(RX_STAT & RX_WAITING)) { }
    // The ALU result of this addi, 0x1000_0008, is on the CPU's d_addr for a
    // whole cycle, but d_valid is 0: the console must not see a load.
    __asm__ volatile ("lui  t0, 0x10000\n\t"
                      "addi t0, t0, 8" ::: "t0");
    putchar('\n');
    check("3 after an addi = RX_DATA_ADDR: still waiting", RX_STAT, RX_WAITING);
    check("3 the byte: 'z'", getchar(), 'z');
    check_clean("3 nothing left over");

    // ---- 4: more than the FIFO holds, while not reading ----
    prompt(4);
    for (n = 0; !(RX_STAT & RX_DROPPED) && n < 1000000; n++) { }
    putchar('\n');
    s = RX_STAT;
    check("4 flood: waiting and dropped", s, RX_WAITING | RX_DROPPED);
    n = 0;
    for (int32_t c; (c = RX_DATA) >= 0; )      // take everything there is
        if (n < (int)sizeof line - 1) line[n++] = (char)c;
    line[n] = '\0';
    check("4 flood: the FIFO held 16", n, RX_FIFO_BYTES);
    check_str("4 flood: the first 16, in order", line, "ABCDEFGHIJKLMNOP");
    RX_STAT = s;
    check("4 flood: flag cleared by writing it back", RX_STAT, 0);

    // ---- 5: a framing error ----
    prompt(5);
    while (!(RX_STAT & RX_WAITING)) { }
    putchar('\n');
    s = RX_STAT;
    check("5 bad stop bit: waiting and framing", s, RX_WAITING | RX_FRAMING);
    check("5 the byte delivered anyway: 'x'", getchar(), 'x');
    check("5 the flag stays until cleared", RX_STAT, RX_FRAMING);
    check_clean("5 nothing left over");

    if (failures == 0) puts("c_rx: all passed\n");
    else               printf("c_rx: %d FAILED\n", failures);
    return failures;
}
