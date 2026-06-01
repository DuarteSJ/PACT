/* SPDX-License-Identifier: MIT */
/* Copyright (c) 2026 MoatLab, Virginia Tech. */
/* balance.h — migration balance check. */

#ifndef PACT_BALANCE_H
#define PACT_BALANCE_H

#include <stdint.h>
#include "pact.h"

/* Read a sum of values from /proc/vmstat for any keys appearing in stat_names. */
uint64_t read_migration_stats(const char *stat_names);

/* Check promote/demote balance. Reads kernel demotion counters, computes
 * deltas, optionally toggles zone_reclaim_mode for kernel-LRU demotion
 * policy. Called periodically from main event loop. */
void check_migration_balance(pact_context_t *pact);

#endif /* PACT_BALANCE_H */
