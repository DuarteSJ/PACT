/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

/* stats.c — comprehensive stats output at exit + periodic. */

#include <stdio.h>
#include <string.h>

#include "constants.h"
#include "obj-pool.h"
#include "pact.h"
#include "config.h" /* PACT_TOP_K_SIZE */
#include "stats.h"
#include "tsc.h"
#include "pebs-aggregator.h"

static void print_basic_stats(pact_context_t *pact)
{
    printf("\n=== PACT Statistics ===\n");
    printf("Time running: %lu cycles\n", pact->workload->stats.time_running);
    printf("LLC Misses (fast): %lu\n", pact->workload->stats.llc_misses_fast);
    printf("LLC Misses (slow): %lu\n", pact->workload->stats.llc_misses_slow);
    printf("PAC Updates: %lu\n", pact->workload->stats.pac_updates);
    printf("Promotions (successful): %lu\n", pact->workload->stats.promotion_successes);
    printf("Demotions (successful): %lu\n", pact->workload->stats.demotion_successes);
}

static void print_pingpong_stats(pact_context_t *pact)
{
    printf("\n=== Ping-Pong Statistics ===\n");
    printf("Total Repromotions (0→1→0): %lu\n", pact->workload->stats.total_repromotions);
    printf("Total Redemotions (1→0→1): %lu\n", pact->workload->stats.total_redemotions);
    printf("Total Ping-Pong Pages: %lu\n",
           pact->workload->stats.total_repromotions + pact->workload->stats.total_redemotions);
}

static void print_promotion_profile(pact_context_t *pact)
{
    printf("\n=== Promotion Profiling ===\n");
    printf("Promotion Attempts: %lu\n", pact->workload->stats.promotion_attempts);
    printf("Promotion Successes: %lu\n", pact->workload->stats.promotion_successes);
    printf("Promotion Failures: %lu\n", pact->workload->stats.promotion_failures);
    if (pact->workload->stats.promotion_attempts > 0) {
        double rate = (double)pact->workload->stats.promotion_successes /
                      pact->workload->stats.promotion_attempts * 100.0;
        printf("Promotion Success Rate: %.1f%%\n", rate);
    }

    printf("\n=== Promotion Policy ===\n");
    printf("Policy: threshold\n");
}

static void print_hash_table_stats(pact_context_t *pact)
{
    pact_workload_t *wl = pact->workload;
    printf("Cooling Decays: %lu\n", wl->stats.cooling_decays);
    printf("Avg PAC Value: %lu\n", wl->stats.avg_pac);
    printf("Hash table entries: %u\n", kh_size(wl->pac_table));
    printf("  WL (%s): hash=%u, Q1=%.2f, Q3=%.2f, bw=%.2f, pebs_samples=%lu\n", wl->name,
           kh_size(wl->pac_table), wl->binning->q1, wl->binning->q3, wl->binning->bin_width,
           wl->total_pebs_samples);
}

/* Overhead analysis converts cycles → ns using the runtime-detected TSC
 * frequency (pact->tsc_freq_hz), so the numbers are correct across CPU
 * families and turbo states. */
static void print_overhead_analysis(pact_context_t *pact)
{
    if (pact->workload->stats.total_operations == 0) {
        return;
    }
    double tsc_ghz = (double)pact->tsc_freq_hz / 1e9;
    if (tsc_ghz <= 0.0) {
        tsc_ghz = PACT_TSC_GHZ_FALLBACK;
    }
    double hash_ns = (double)pact->workload->stats.hash_lookup_cycles /
                     pact->workload->stats.total_operations / tsc_ghz;
    double meta_ns = (double)pact->workload->stats.metadata_update_cycles /
                     pact->workload->stats.total_operations / tsc_ghz;
    double queue_ns = pact->workload->stats.queue_update_cycles > 0
                          ? (double)pact->workload->stats.queue_update_cycles /
                                pact->workload->stats.total_operations / tsc_ghz
                          : 0.0;

    printf("\n=== Overhead Analysis ===\n");
    printf("Total Operations: %lu\n", pact->workload->stats.total_operations);
    printf("Avg Hash Lookup: %.1f ns\n", hash_ns);
    printf("Avg Metadata Update: %.1f ns\n", meta_ns);
    printf("Avg Queue Update: %.1f ns\n", queue_ns);
    printf("Total Avg Overhead: %.1f ns per operation\n", hash_ns + meta_ns + queue_ns);
}

static void print_mlp_and_policy(pact_context_t *pact)
{
    pact_workload_t *wl = pact->workload;
    printf("Workload MLP (PID %d): fast %.2f, slow %.2f\n", wl->target_pid, wl->workload_mlp_fast,
           wl->workload_mlp_slow);
    printf("Cooling Policy: None\n");
    printf("WL Bin width: %.2f, Q1: %.2f, Q3: %.2f\n", wl->binning->bin_width, wl->binning->q1,
           wl->binning->q3);
}

static void print_pool_stats(pact_context_t *pact)
{
    if (!pact->pac_metadata_pool) {
        return;
    }
    size_t cap = get_total_capacity(pact->pac_metadata_pool);
    size_t avail = pool_available(pact->pac_metadata_pool);
    size_t in_use = cap - avail;

    printf("\n=== Memory Pool Statistics ===\n");
    printf("PAC Metadata Pool:\n");
    printf("  Total Capacity: %zu objects\n", cap);
    printf("  Available Objects: %zu\n", avail);
    printf("  Objects In Use: %zu\n", in_use);
    printf("  Total Memory: %zu bytes\n", get_total_memory(pact->pac_metadata_pool));
    printf("  Element Size: %zu bytes\n", get_element_size(pact->pac_metadata_pool));
    printf("  Pool Usage: %.1f%%\n", cap > 0 ? (double)in_use / cap * 100.0 : 0.0);
    if (pact->max_pac_entries > 0) {
        printf("  Max Entries Cap: %zu\n", pact->max_pac_entries);
    }
    printf("  Alloc Skipped (pool full): %lu\n", pact->workload->stats.pool_alloc_skipped);
}

/* Coroutine scheduling stats: per-coroutine resume count + late-resume tally. */
static void print_one_coro_sched(pact_context_t *pact, const char *name, coro_type_t type)
{
    const struct coro_timing *t = &pact->timing[type];
    uint64_t avg_late_ms = (t->late_counts > 0) ? tsc_to_ms(pact, t->late_tsc / t->late_counts) : 0;
    printf("%s Coroutine: %lu resumes, %lu late resumes, avg %lu ms late\n", name, t->counts,
           t->late_counts, avg_late_ms);
}

static void print_coro_sched_stats(pact_context_t *pact)
{
    printf("\n=== Coroutine Scheduling Statistics ===\n");
    /* Display names retained for human-readable stats output ("Sampling"
     * rather than the internal "PEBS"). The Adaptive coroutine is
     * intentionally omitted — pre-existing output convention. */
    print_one_coro_sched(pact, "Sampling", CORO_TYPE_PEBS);
    print_one_coro_sched(pact, "Cooling", CORO_TYPE_COOLING);
    print_one_coro_sched(pact, "Stats", CORO_TYPE_STATS);
}

void print_stats(pact_context_t *pact)
{
    print_basic_stats(pact);
    print_pingpong_stats(pact);
    print_promotion_profile(pact);
    print_hash_table_stats(pact);
    print_overhead_analysis(pact);
    print_mlp_and_policy(pact);
    print_pool_stats(pact);
    print_coro_sched_stats(pact);
}
