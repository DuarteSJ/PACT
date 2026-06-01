/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */

/* balance.c — demotion balance check.
 *
 * Open-loop control of /sys/kernel/mm/numa/demotion_enabled, keyed off the
 * "candidates > promoted" relation. Called from the migration thread at
 * ~1Hz.
 */

#include <fcntl.h>
#include <stdio.h>
#include <stdlib.h>
#include <string.h>
#include <unistd.h>

#include "error.h"
#include "pact.h"
#include "balance.h"
#ifdef PACT_CGROUP_SUPPORT
#include "utils.h"
#endif

uint64_t read_migration_stats(const char *stat_names)
{
    FILE *fp = fopen("/proc/vmstat", "r");
    if (!fp) {
        return 0;
    }

    char line[256];
    char word[100];
    uint64_t sum = 0;
    uint64_t value = 0;

    while (fgets(line, sizeof(line), fp)) {
        if (sscanf(line, "%99s %ld", word, &value) == 2) {
            if (strstr(stat_names, word)) {
                sum += value;
            }
        }
    }

    fclose(fp);
    return sum;
}

/* Direct sysfs write to /sys/kernel/mm/numa/demotion_enabled.
 * Avoids the system("echo …") shell-out in the old zone_reclaim_mode path. */
static void write_demotion_enabled(const char *value)
{
    int fd = open("/sys/kernel/mm/numa/demotion_enabled", O_WRONLY);
    if (fd < 0) {
        log_warning("write_demotion_enabled", "Failed to open: %s", strerror(errno));
        return;
    }
    ssize_t n = write(fd, value, strlen(value));
    if (n < 0) {
        log_warning("write_demotion_enabled", "Failed to write '%s': %s", value, strerror(errno));
    }
    close(fd);
}

void check_migration_balance(pact_context_t *pact)
{
    if (pact->demotion_policy != DEMOTION_KERNEL_LRU) {
        return;
    }

#ifdef PACT_CGROUP_SUPPORT
    uint64_t demoted = pact_read_cgroup_demotion_stats(pact->workload->cgroup_path);
#else
    uint64_t demoted = read_migration_stats("pgdemote_kswapd pgdemote_direct");
#endif
    uint64_t new_demotions = demoted - pact->workload->stats.last_demotions_successes;
    pact->workload->stats.last_demotions_successes = demoted;
    pact->workload->stats.new_demotions = new_demotions;
    pact->workload->stats.demotion_successes = demoted;

    /* Open-loop control: keep demotion enabled while we have more
     * candidates than we've successfully promoted. */
    uint64_t candidates = pact->workload->stats.promotion_attempts;
    uint64_t promoted = pact->workload->stats.promotion_successes;
    const char *value = (candidates > promoted) ? "1" : "0";

    log_debug("check_migration_balance",
              "candidates=%lu, promoted=%lu, demoted=%lu, demotion_enabled=%s", candidates,
              promoted, demoted, value);

    write_demotion_enabled(value);
}
