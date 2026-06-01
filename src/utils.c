/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

/* utils.c — small stateless utility functions.
 * _GNU_SOURCE is supplied by the Makefile (-D_GNU_SOURCE); needed here for
 * sched_setaffinity. */

#include <errno.h>
#include <sched.h>
#include <signal.h> /* kill */
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <sys/types.h> /* pid_t */
#include <time.h>
#include <unistd.h> /* usleep */

#include "pact.h" /* pac_metadata_t, pact_context_t */
#include "tsc.h"  /* rdtsc */
#include "utils.h"
#include "error.h"

#ifdef PACT_CGROUP_SUPPORT
uint64_t pact_read_cgroup_demotion_stats(const char *cgroup_path)
{
    char stat_path[512];
    snprintf(stat_path, sizeof(stat_path), "%s/memory.stat", cgroup_path);

    FILE *fp = fopen(stat_path, "r");
    if (!fp) {
        return 0;
    }

    char key[128];
    uint64_t value = 0;
    uint64_t sum = 0;

    while (fscanf(fp, "%127s %lu", key, &value) == 2) {
        if (strcmp(key, "pgsteal_kswapd") == 0 || strcmp(key, "pgsteal_direct") == 0) {
            sum += value;
        }
    }

    fclose(fp);
    return sum;
}
#endif

int pact_compare_uint64(const void *a, const void *b)
{
    uint64_t va = *(const uint64_t *)a;
    uint64_t vb = *(const uint64_t *)b;
    if (va < vb) {
        return -1;
    }
    if (va > vb) {
        return 1;
    }
    return 0;
}

uint64_t pact_calculate_percentile(uint64_t *samples, size_t count, double percentile)
{
    if (count == 0) {
        return 0;
    }
    if (count == 1) {
        return samples[0];
    }

    qsort(samples, count, sizeof(uint64_t), pact_compare_uint64);

    double idx = (percentile / 100.0) * (count - 1);
    size_t lower = (size_t)idx;
    size_t upper = lower + 1;
    if (upper >= count) {
        upper = count - 1;
    }

    double frac = idx - lower;
    return (uint64_t)(samples[lower] * (1 - frac) + samples[upper] * frac);
}

uint64_t pact_detect_tsc_frequency(void)
{
    struct timespec start, end;
    clock_gettime(CLOCK_MONOTONIC, &start);
    uint64_t tsc_start = rdtsc();
    usleep(10000); /* 10 ms calibration window */
    uint64_t tsc_end = rdtsc();
    clock_gettime(CLOCK_MONOTONIC, &end);
    uint64_t elapsed_ns =
        (end.tv_sec - start.tv_sec) * 1000000000ULL + (end.tv_nsec - start.tv_nsec);
    return (tsc_end - tsc_start) * 1000000000ULL / elapsed_ns;
}

int pact_pin_to_cpu(int cpu)
{
    cpu_set_t cpuset;
    CPU_ZERO(&cpuset);
    CPU_SET(cpu, &cpuset);
    if (sched_setaffinity(0, sizeof(cpuset), &cpuset) < 0) {
        log_error("pin_to_cpu", "Failed to set affinity to CPU %d: %s", cpu, strerror(errno));
        return -1;
    }
    log_info("pin_to_cpu", "Pinned to CPU %d", cpu);
    return 0;
}

bool pact_check_all_targets_exited(pact_context_t *ctx)
{
    pid_t pid = ctx->workload->target_pid;
    if (pid <= 0) {
        return true;
    }
    /* kill(pid, 0) probes process existence without sending a signal.
     * EPERM = process exists but we cannot signal it — treat as alive. */
    if (kill(pid, 0) == 0) {
        return false;
    }
    if (errno == EPERM) {
        return false;
    }
    return true;
}
