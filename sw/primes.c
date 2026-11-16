// primes.c — the primes below 1000 (sieve of Eratosthenes), ten to a line.
//   make run PROG=primes
//
// main returns their sum, 76127 = 0x1295F, so the result is also the exit code:
// on the DE10-Lite (boards/de10-lite/soc_top.v) the displays show 01295F.
//
// The sieve is in .bss, which crt0 zeroes on every start: the program gives the
// same answer when it is rerun after a reset without reloading the RAM. (An
// initialised global it modified would keep its modified value.)

#include "soc.h"

#define N 1000

static unsigned char composite[N];

int main(void)
{
    int count = 0, sum = 0;

    for (int i = 2; i * i < N; i++)
        if (!composite[i])
            for (int j = i * i; j < N; j += i)
                composite[j] = 1;

    printf("primes below %d:\n", N);
    for (int p = 2; p < N; p++) {
        if (composite[p])
            continue;
        printf("%4d", p);
        count++;
        sum += p;
        if (count % 10 == 0)
            printf("\n");
    }
    printf("\n%d primes, sum %d\n", count, sum);
    return sum;
}
