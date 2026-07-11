/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */
/*
 * pact.h — PACT runtime context, workload state, and PEBS sample encoding.
 */

#ifndef PACT_H
#define PACT_H

#include <stdint.h>
#include <stdbool.h>
#include <stdio.h>
#include <pthread.h>
#include "pmu.h"
#include "obj-pool.h"
#include "khashl.h"
#include "ring-buffer.h"

/* Mark a function parameter as deliberately unused (e.g. only referenced in
 * one branch of an #ifdef). Attaches the attribute at the parameter so no
 * `(void)param;` statements are needed in the body. */
#ifndef PACT_UNUSED
#if defined(__GNUC__) || defined(__clang__)
#define PACT_UNUSED __attribute__((unused))
#else
#define PACT_UNUSED
#endif
#endif

/* Forward declarations */
typedef struct mco_coro mco_coro;
/* pact_context_t is forward-declared in pmu.h (included above) */

/* PAC metadata structure - must be defined here for SIMD header */
typedef struct pac_metadata {
    uint64_t page_addr;             /* Page virtual address */
    pid_t pid;                      /* Owner process ID */
    uint64_t pac_value;             /* Accumulated PAC score */
    uint32_t access_count;          /* Access frequency */
    uint32_t tier : 2;              /* Current memory tier */
    uint32_t migrating : 1;         /* Migration in progress */
    uint32_t promoted_by_pact : 1;  /* Whether the page was promoted by PACT */
    uint32_t promoted_by_other : 1; /* Promoted by non-PACT mechanism (currently unused) */
    uint32_t demoted_by_pact : 1;   /* Whether the page was demoted by PACT */
    uint32_t demoted_by_other : 1;  /* Whether the page was demoted */
    uint32_t sampled_on_fast : 1;   /* Whether we've sampled this page on fast tier */
    uint32_t sampled_on_slow : 1;   /* Whether we've sampled this page on slow tier */
    uint32_t prev_tier : 2;         /* Previous tier location for ping-pong detection */
    uint32_t reserved : 21;         /* Reserved bits */
    uint64_t last_reset_tsc;        /* Last cooling reset timestamp */
    uint64_t last_reset_count;      /* # of sampled pages when the page was last cooling-reset */
} pac_metadata_t;

/* Hash map type declarations - must be here for khash_t(pac) to work */
KHASHL_MAP_INIT(KH_LOCAL, pac_table_t, pac_table, uint64_t, pac_metadata_t *, kh_hash_uint64,
                kh_eq_generic)

/* Cooling policies. */
typedef enum { COOLING_NONE = 0 } cooling_policy_t;

/* Demotion policies. */
typedef enum {
    DEMOTION_DISABLED = 0,   /* Disable demotion entirely */
    DEMOTION_KERNEL_LRU = 1, /* Use the kernel's LRU-based demotion (default) */
} demotion_policy_t;

/* Migration policies. */
typedef enum {
    MIGRATION_PAC_BASED = 0, /* Use PAC values for migration decisions */
} migration_policy_t;

/* Promotion policies. */
typedef enum {
    PROMOTION_THRESHOLD = 0, /* Bin-based threshold (default) */
} promotion_policy_t;

/* Coroutine types */
typedef enum {
    CORO_TYPE_PEBS,    /* sampling */
    CORO_TYPE_PAC,     /* adaptive */
    CORO_TYPE_COOLING, /* cooling */
    CORO_TYPE_STATS,   /* stats */
    CORO_TYPE_MAX
} coro_type_t;

/*
 * Single page migration entry for thread-based migration
 * Passed through ring buffer from main thread to migration thread
 */
typedef struct migration_entry {
    pac_metadata_t *meta; /* Page metadata pointer (contains pid, page_addr) */
    int target_node;      /* Target NUMA node (0=fast, 1=slow) */
    uint64_t enqueue_tsc; /* Timestamp for sojourn time measurement */
} migration_entry_t;

/* PEBS event encoding: assume 57 bits virtual addr, we use:
 * - 63-57, 7 bits: pac value (high)
 * - 56-12, 45 bits: page address (page-aligned)
 * - 11-3, 9 bits: pac value (low)
 * - 2-1, 2 bits: unused
 * - 0, 1 bit: tier (0=fast, 1=slow)
 * Total: 7+9=16 bits for PAC value, max value 65535 (sufficient for per-sample stalls)
 */
#define PEBS_ENCODE_PAC(pac, page_addr, tier)                                                      \
    ({                                                                                             \
        uint32_t _pac = (uint32_t)(pac);                                                           \
        uint64_t _addr = ((uint64_t)(page_addr)) & PAGE_MASK;                                      \
        uint64_t _tier = (uint64_t)(tier) & 0x1ULL; /* 1 bit */                                    \
                                                                                                   \
        uint64_t _pac_high = (_pac >> 9) & 0x7FULL; /* 7 bits */                                   \
        uint64_t _pac_low = _pac & 0x1FFULL;        /* 9 bits */                                   \
                                                                                                   \
        ((_pac_high << 57) | ((_addr >> PAGE_SHIFT) << 12) | /* Bits 56-12: page address */        \
         (_pac_low << 3) |                                   /* Bits 11-3: pac_low */              \
         _tier);                                             /* Bit 0: tier */                     \
    })

#define PEBS_DECODE_PAC(encoded)                                                                   \
    ({                                                                                             \
        uint32_t _pac_high = ((encoded) >> 57) & 0x7FULL; /* 7 bits */                             \
        uint32_t _pac_low = ((encoded) >> 3) & 0x1FFULL;  /* 9 bits */                             \
        (_pac_high << 9) | _pac_low;                                                               \
    })

/* PEBS address encoding: low 3 bits for metadata (addresses are page-aligned) */
#define PEBS_ENCODE_ADDR_TIER(addr, tier)                                                          \
    (((addr) & PAGE_MASK) | /* Preserve page address */                                            \
     ((tier) & 0x1ULL)      /* Bit 0: tier */                                                      \
    )

#define PEBS_DECODE_ADDR(encoded) ((encoded) & ~0x7ULL) /* Clear bits 2-0 */
#define PEBS_DECODE_PAGE(encoded) ((encoded) & PAGE_MASK)
#define PEBS_DECODE_TIER(encoded) ((encoded) & 0x1ULL)

/* Fast PRNG for reservoir sampling */
typedef struct {
    uint64_t state;
} fast_prng_t;

/* Reservoir sampling state */
typedef struct {
    double *samples;
    size_t capacity;
    size_t count;
    uint64_t total_seen;
    fast_prng_t prng;
} reservoir_t;

/* Binning state for adaptive thresholds */
typedef struct {
    double bin_width;
    double inv_bin_width; /* Precomputed 1.0/bin_width to avoid per-sample division */
    size_t bin_count;
    double q1, q3; /* Quartiles */
    uint64_t last_update;
} binning_state_t;

/* Comprehensive statistics structure */
typedef struct {
    /* Migration statistics */
    uint64_t last_promotions_successes;
    uint64_t last_demotions_successes;
    uint64_t promotion_attempts;
    uint64_t promotion_successes;
    uint64_t promotion_failures;
    uint64_t demotion_successes;
    uint64_t new_demotions;

    /* PAC and memory access statistics */
    uint64_t last_time_running;
    uint64_t time_running;
    uint64_t llc_misses_fast;
    uint64_t llc_misses_slow;
    uint64_t pac_updates;
    uint64_t avg_pac;

    /* Cooling statistics */
    uint64_t cooling_decays;

    /* Performance counters */
    uint64_t hash_lookup_cycles;
    uint64_t metadata_update_cycles;
    uint64_t queue_update_cycles;
    uint64_t total_operations;

    /* PEBS sampling */
    uint64_t pebs_events_processed;

    /* ping-pong effect logging - repromotions (demoted then promoted) */
    uint64_t repromotions_pact_pact;   /* PACT demoted → PACT promoted */
    uint64_t repromotions_pact_other;  /* PACT demoted → other promoted */
    uint64_t repromotions_other_pact;  /* other demoted → PACT promoted */
    uint64_t repromotions_other_other; /* other demoted → other promoted */

    /* ping-pong effect logging - redemotions (promoted then demoted) */
    uint64_t redemotions_pact_pact;   /* PACT promoted → PACT demoted */
    uint64_t redemotions_pact_other;  /* PACT promoted → other demoted */
    uint64_t redemotions_other_pact;  /* other promoted → PACT demoted */
    uint64_t redemotions_other_other; /* other promoted → other demoted */

    /* Simple ping-pong tracking (tier history-based) */
    uint64_t total_repromotions; /* Total 0→1→0 patterns */
    uint64_t total_redemotions;  /* Total 1→0→1 patterns */

    /* Pool capacity tracking */
    uint64_t pool_alloc_skipped; /* Pages skipped because PAC metadata pool is full */
    uint64_t pool_warn_last_tsc; /* TSC of last "pool full" log warning (rate-limit) */
} pact_stats_t;

/* khash for PAC table defined in pact_minicoro.h */

DEFINE_RING_BUFFER(uint64_t, uint64)

/* Ring buffer for migration entries (thread-based migration, single-page) */
DEFINE_RING_BUFFER(migration_entry_t, migration_entry)

/* Per-coroutine scheduling + lateness state. Indexed by enum coro_type so
 * adding a new coroutine costs one enum entry, not five new field names. */
struct coro_timing {
    uint64_t next_tsc;    /* deadline: when this coroutine should next fire */
    uint64_t prev_tsc;    /* TSC at the start of its most recent tick */
    uint64_t late_tsc;    /* cumulative late-by (lag past deadline) */
    uint64_t late_counts; /* # of late ticks */
    uint64_t counts;      /* total # of ticks */
};

/*
 * Per-workload structure
 * Holds workload-specific configuration, PMU state, and statistics
 */
typedef struct pact_workload {
    /* Process identification */
    pid_t target_pid; /* Process ID */
    char name[64];    /* Optional workload name/label */

    /* CPU configuration */
    int *target_cpus;   /* Array of CPU IDs this workload runs on */
    int nr_target_cpus; /* Number of CPUs */
    uint64_t cpu_mask;  /* Bitmask of CPUs (for quick checks) */

    /* Per-workload counting events (LLC misses). Single fd per event opened
     * with pid=target_pid, cpu=-1, inherit=1, mmap=0 — kernel auto-attributes
     * across all threads of the workload. Replaces the per-TID setup that
     * required /proc/<pid>/task polling. */
    perf_event_t counting_leader;
    perf_event_t counting_events[CORE_EVENT_COUNT];

    /* Per-workload CHA PMUs for MLP measurement */
    cha_pmu_info_t cha_pmus[MAX_CHAS]; /* CHA PMU configurations */
    int nr_cha;                        /* Number of CHAs for this workload */

    /* Per-tier MLP for the current window (ΔT1/ΔT2 over the workload's
     * CHAs, Algorithm 1). */
    double workload_mlp_fast;
    double workload_mlp_slow;

    /* Per-workload statistics */
    pact_stats_t stats;          /* Workload-specific statistics */
    uint64_t total_pebs_samples; /* Cumulative PEBS samples attributed to this workload */

    /* Workload data structures (PAC tracking + migration plumbing). */
    pac_table_t *pac_table;
    reservoir_t *reservoir;
    binning_state_t *binning;
    ring_buffer_migration_entry_t *migration_ring;
} pact_workload_t;

/* PACT runtime context — single instance per process; owns the workload. */
struct pact_context {
    /* ===== Core Data Structures ===== */
    ring_buffer_uint64_t *pac_update_ring; /* PEBS -> PAC updates ring buffer */

    /* The workload — owned by the context; always non-NULL once
     * initialize_workloads() succeeds. */
    pact_workload_t *workload;

    /* CPU set the workload runs on (sched_getaffinity result, capped to 64). */
    uint64_t all_cpus_mask;
    int *all_cpus;
    int nr_all_cpus;

    /* ===== Per-CPU States ===== */
    per_cpu_state_t *cpu_states; /* Array of per-CPU PMU states for all workload CPUs */
    int nr_cpus;                 /* Number of CPUs in the system */

    /* ===== Coroutine Management ===== */
    mco_coro *coroutines[CORO_TYPE_MAX]; /* Coroutine array */

    /* Coroutine scheduling timestamps, indexed by coro_type_t. */
    struct coro_timing timing[CORO_TYPE_MAX];
    uint64_t start_tsc;

    /* Deadline (TSC) for the next 1Hz check_targets_alive() tick. Lives on
     * the context so the event loop can fold it into next_deadline_tsc(). */
    uint64_t targets_alive_next_tsc;

    /* ===== Adaptive Components — initial config; the live state lives
     * on ctx->workload. ===== */
    double bin_width;
    size_t bin_count;

    /* ===== PEBS and PMU ===== */
    struct pebs_aggregator *pebs_aggregator; /* PEBS aggregator */
    bool pebs_available;                     /* PEBS availability flag */

    /* ===== Configuration ===== */
    /* Policies */
    cooling_policy_t cooling_policy;
    demotion_policy_t demotion_policy;
    migration_policy_t migration_policy;
    promotion_policy_t promotion_policy;

    /* Timing intervals (ms) */
    uint32_t sampling_interval_ms;
    uint32_t cooling_interval_ms;
    uint32_t adaptive_interval_ms;
    uint32_t stats_interval_ms;

    /* PEBS sampling period */
    uint64_t pebs_sampling_period;

    uint32_t max_migrations_per_cycle;

    /* Cooling factor + trigger (Algorithm 1 α-decay). */
    double cooling_alpha;             /* 1.0 = no cooling (default) */
    uint64_t cooling_trigger_samples; /* global sample-count threshold */

    /* Cooling-related stats */
    uint64_t sample_counts;

    /* Hardware constants */
    uint64_t k_constant_dram; /* DRAM latency constant (238) */
    uint64_t k_constant_cxl;  /* CXL latency constant (771) */
    uint64_t tsc_freq_hz;     /* TSC frequency for time calculations */

    /* ===== Logging ===== */
#ifdef PACT_ENABLE_LOGGING
    bool enable_logging;
    FILE *log_file;
    char log_format[16]; /* "csv" or "json" */
#else
    bool enable_logging; /* Keep for compatibility, but unused */
#endif

    /* ===== Memory Pools ===== */
    object_pool *pac_metadata_pool; /* Object pool for metadata */
    size_t max_pac_entries;         /* Cap on PAC metadata entries (0 = unlimited) */

    /* ===== Control Flags ===== */
    volatile bool running;

    /* ===== Coroutine scheduling state ===== */
    uint64_t coro_ready_mask; /* Bitmask of ready coroutines */

    /* ===== Migration Thread ===== */
    pthread_t migration_thread;             /* Migration thread handle */
    volatile bool migration_thread_running; /* Thread control flag */

    /* CPU affinity configuration */
    int monitor_cpu;   /* CPU for main event loop (-1 = no pinning) */
    int migration_cpu; /* CPU for migration thread (-1 = no pinning) */
};

/* Global context pointer for compatibility */
extern pact_context_t *g_pact_ctx;

/* Helper macros for easy migration */
#define pact_system_t pact_context_t
#define g_pact g_pact_ctx

/* Coroutine management functions */
void mark_coro_ready(pact_context_t *ctx, int type);
void clear_coro_ready(pact_context_t *ctx, int type);

void print_stats(pact_context_t *ctx);


/* TGID filter: exact match against the workload's target_pid. */
static inline bool is_target_pid(const pact_context_t *ctx, pid_t pid)
{
    return ctx->workload->target_pid == pid;
}

/* Interval (in ms) for the given coroutine type. Looks up the configured
 * value from the per-subsystem config field. */
static inline uint32_t pact_coro_interval_ms(const pact_context_t *ctx, coro_type_t type)
{
    switch (type) {
    case CORO_TYPE_PEBS:
        return ctx->sampling_interval_ms;
    case CORO_TYPE_PAC:
        return ctx->adaptive_interval_ms;
    case CORO_TYPE_COOLING:
        return ctx->cooling_interval_ms;
    case CORO_TYPE_STATS:
        return ctx->stats_interval_ms;
    default:
        return 0;
    }
}

/* Human-readable name for a coroutine type. Used in log messages and the
 * stats summary. */
static inline const char *pact_coro_name(coro_type_t type)
{
    switch (type) {
    case CORO_TYPE_PEBS:
        return "PEBS";
    case CORO_TYPE_PAC:
        return "Adaptive";
    case CORO_TYPE_COOLING:
        return "Cooling";
    case CORO_TYPE_STATS:
        return "Stats";
    default:
        return "?";
    }
}

#endif /* PACT_H */
