// c_basics.c — regression test: what compiled C needs from the core
//
// Each test exercises something GCC relies on, on a core that only has RV32I:
//
//   multiply/divide  RV32I has no mul/div: GCC calls __mulsi3, __divsi3 ...
//                    in libgcc, i.e. loops of shifts, adds and branches
//   64-bit math      carries between 32-bit halves use sltu
//   recursion        the stack: sp, return addresses, saved registers
//   .data / .bss     initialised globals come from the image; crt0 zeroes .bss
//                    (the SoC runs this with RAM filled with 0xDEADBEEF, so an
//                    uncleared .bss shows)
//   bytes / halves   char/short arrays: lb, lbu, lh, lhu, sb, sh
//   switch           a dense switch compiles to a jump table: a load from
//                    .rodata, then jalr to the loaded address
//   function ptrs    indirect calls: jalr through a register
//   struct copy      GCC may call memcpy itself
//
// Inputs come from volatile globals so -O2 cannot compute the answers at
// compile time. It prints one line per test and exits with the number of
// failures: exit code 0 means everything passed.

#include "soc.h"

static int failures;

static void check(const char *name, uint32_t got, uint32_t want)
{
    if (got == want) {
        puts("  ok  ");
        puts(name);
    } else {
        failures++;
        puts("FAIL  ");
        puts(name);
        puts(": got ");
        print_hex(got);
        puts(", want ");
        print_hex(want);
    }
    putchar('\n');
}

// ---- inputs the compiler cannot see through ----
volatile int32_t  vi_a = 12345, vi_b = 6789, vi_neg = -100, vi_seven = 7;
volatile uint32_t vu_max = 0xFFFFFFFFu, vu_ten = 10;
volatile int      vi_n = 15;

// ---- .data and .bss ----
int32_t data_word = 0x12345678;              // initialised: comes from the image
int32_t bss_words[16];                       // must be zero: crt0's job
uint8_t bss_bytes[13];

// ---- recursion ----
__attribute__((noinline)) static uint32_t fib(uint32_t n)
{
    return n < 2 ? n : fib(n - 1) + fib(n - 2);
}

__attribute__((noinline)) static uint32_t factorial(uint32_t n)
{
    return n <= 1 ? 1 : n * factorial(n - 1);
}

// ---- jump table ----
__attribute__((noinline)) static int classify(int x)
{
    switch (x) {
    case 0: return 100;
    case 1: return 101;
    case 2: return 102;
    case 3: return 103;
    case 4: return 104;
    case 5: return 105;
    case 6: return 106;
    case 7: return 107;
    default: return -1;
    }
}

// ---- function pointers ----
static int add1(int x) { return x + 1; }
static int dbl(int x)  { return x * 2; }
static int neg(int x)  { return -x; }
static int (*const ops[])(int) = { add1, dbl, neg };

struct point { int32_t x, y, z; };

int main(void)
{
    puts("c_basics:\n");

    // multiply and divide, through libgcc
    check("mul",                (uint32_t)(vi_a * vi_b), 83810205u);
    check("mul negative",       (uint32_t)(vi_neg * vi_b), (uint32_t)-678900);
    check("div signed",         (uint32_t)(vi_neg / vi_seven), (uint32_t)-14);
    check("mod signed",         (uint32_t)(vi_neg % vi_seven), (uint32_t)-2);
    check("div unsigned",       vu_max / vu_ten, 429496729u);
    check("mod unsigned",       vu_max % vu_ten, 5u);

    // 64-bit arithmetic: carries and __muldi3
    uint64_t big = (uint64_t)vu_max * vu_max;            // 0xFFFFFFFE_00000001
    check("u64 mul high",       (uint32_t)(big >> 32), 0xFFFFFFFEu);
    check("u64 mul low",        (uint32_t)big, 0x00000001u);
    uint64_t sum = (uint64_t)vu_max + 1u;                // carry into the high half
    check("u64 add carry",      (uint32_t)(sum >> 32), 1u);

    // recursion
    check("fib(15) recursive",  fib((uint32_t)vi_n), 610u);
    check("factorial(10)",      factorial(10u + (uint32_t)vi_n - 15u), 3628800u);

    // initialised and zeroed globals
    check(".data initialised",  (uint32_t)data_word, 0x12345678u);
    data_word += vi_seven;
    check(".data writable",     (uint32_t)data_word, 0x1234567Fu);
    uint32_t or_all = 0;
    for (int i = 0; i < 16; i++) or_all |= (uint32_t)bss_words[i];
    for (int i = 0; i < 13; i++) or_all |= bss_bytes[i];
    check(".bss zeroed by crt0", or_all, 0u);

    // bytes and halfwords, signed and unsigned
    volatile int8_t   sb[4] = { -1, 2, -3, 4 };
    volatile uint8_t  ub[4] = { 0xF0, 0x0F, 0x80, 0x7F };
    volatile int16_t  sh[2] = { -2, 300 };
    volatile uint16_t uh[2] = { 0xFFFE, 0x8000 };
    check("int8 sign-extends",  (uint32_t)(sb[0] + sb[2]), (uint32_t)-4);
    check("uint8 zero-extends", (uint32_t)(ub[0] + ub[2]), 0x170u);
    check("int16 sign-extends", (uint32_t)(sh[0] + sh[1]), 298u);
    check("uint16 zero-extends",(uint32_t)(uh[0] + uh[1]), 0x17FFEu);
    ub[1] = 0xAB;                                        // sb into lane 1
    check("byte store lane 1",  (uint32_t)(ub[0] | ub[1] << 8 | ub[2] << 16 | ub[3] << 24),
                                0x7F80ABF0u);

    // jump table, function pointers, struct copy
    check("switch jump table",  (uint32_t)classify(vi_seven - 2), 105u);
    check("switch default",     (uint32_t)classify(vi_seven + 1), (uint32_t)-1);
    check("function pointers",  (uint32_t)(ops[2](ops[1](ops[0](vi_seven)))), (uint32_t)-16);
    struct point p = { vi_a, vi_b, vi_neg }, q;
    q = p;
    check("struct copy",        (uint32_t)(q.x + q.y + q.z), 19034u);

    // strings and memory helpers
    check("strlen",             (uint32_t)strlen("rv-ai-lab"), 9u);
    char buf[8];
    memset(buf, 'x', sizeof buf);
    memcpy(buf, "abc", 3);
    check("memset/memcpy",      (uint32_t)memcmp(buf, "abcxxxxx", 8), 0u);

    // and the console's own number printing (print_dec divides by 10)
    puts("  print_dec(-2147483648) = ");
    print_dec((int32_t)0x80000000);
    putchar('\n');

    if (failures == 0) puts("c_basics: all passed\n");
    else               puts("c_basics: FAILURES\n");
    return failures;
}
