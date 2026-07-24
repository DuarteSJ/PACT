/* mb - minimal random-access microbenchmark for PACT pipeline smoke tests.
 *
 * Allocates <GB> gigabytes (default 80), first-touches every page, then loops
 * random 64B-strided reads over the whole region forever. With node0 sized
 * below <GB> (e.g. ~48GB), first-touch fills the fast tier and the overflow
 * spills to the slow tier, so PACT sees slow-tier PEBS samples and migrates.
 *
 * Build:  cc -O2 -o mb mb.c
 * Run:    ./mb [GB]      (needs a working set > fast-tier size to do anything)
 */
#include <stdio.h>
#include <stdlib.h>
#include <stdint.h>
#include <unistd.h>

int main(int argc, char **argv)
{
    size_t gb = argc > 1 ? (size_t)atol(argv[1]) : 80;
    size_t n = gb << 30;
    char *p = malloc(n);
    if (!p) {
        perror("malloc");
        return 1;
    }
    for (size_t i = 0; i < n; i += 4096) /* first-touch every page */
        p[i] = 1;
    printf("pid=%d  %zuGB allocated, random-touching\n", getpid(), gb);
    fflush(stdout);

    uint64_t x = 88172645463325252ULL; /* xorshift PRNG, deterministic */
    volatile uint64_t sink = 0;
    for (;;) {
        x ^= x << 13;
        x ^= x >> 7;
        x ^= x << 17;
        sink += p[(x % (n / 64)) * 64];
    }
    return 0;
}
