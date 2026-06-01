#!/bin/bash

# Run a single workload with PACT memory tiering.

set -euo pipefail

# --- Argument Parsing ---
WORKLOAD="${1:-}"
skip_setup="${2:-}"

if [ -z "$WORKLOAD" ]; then
    echo "Usage: $0 <workload_name> [skip_setup]"
    exit 1
fi

# --- Source Workload Definitions ---
source ./workloads.sh || exit 1

# --- Load Workload Variables ---
pname_var="${WORKLOAD}_pname"
workload_cmd_var="${WORKLOAD}_workload_cmd"
vmtouch_file_var="${WORKLOAD}_vmtouch_file"
omp_threads_var="${WORKLOAD}_omp_threads"

pname="${!pname_var:-}"
workload_cmd="${!workload_cmd_var:-}"
vmtouch_file="${!vmtouch_file_var:-}"
omp_threads="${!omp_threads_var:-}"

if [ -z "$pname" ] || [ -z "$workload_cmd" ] || [ -z "$omp_threads" ]; then
    echo "Error: Workload '$WORKLOAD' not defined completely in workloads.sh"
    exit 1
fi

# --- CPU Core Allocation ---
if [ "$omp_threads" -gt 8 ]; then
    echo "Error: Workload needs $omp_threads threads but only 8 cores available (2-9)"
    exit 1
fi

AVAILABLE_CORES=(2 3 4 5 6 7 8 9)
cores=()
for ((i = 0; i < omp_threads; i++)); do
    cores+=("${AVAILABLE_CORES[i]}")
done
cpus=$(IFS=,; echo "${cores[*]}")

# --- PACT Configuration (override via env, defaults match config.h) ---
VMTOUCH="${VMTOUCH:-/usr/bin/vmtouch}"
PACT="${PACT:-../src/pact}"
pebs_period="${pebs_period:-400}"
migration_limit="${migration_limit:-4096}"
bin_count="${bin_count:-20}"
bin_width="${bin_width:-1000.0}"

# --- Fast-tier size / split ratio (cgroup v2 memory.max) ---
# A tiering experiment must CONSTRAIN the fast tier (local DRAM), otherwise the
# whole workload fits in DRAM and there is nothing to demote/promote. We cap the
# workload's memory with a cgroup v2 memory.max so that only a fraction of its
# RSS fits in the fast tier and the rest spills to the slow (CXL-like) tier.
#
#   <workload>_rss   : the workload's peak RSS in MB (defined in workloads.sh)
#   FAST_TIER_RATIO  : fraction of RSS allowed in the fast tier (0<r<=1).
#                      0.5 == a 1:1 split (half fast, half slow). Default 0.5.
#   FAST_TIER_MB     : optional absolute override (MB); takes precedence over RSS*ratio.
#
# When neither <workload>_rss nor FAST_TIER_MB is set, the cgroup limit is
# skipped (with a warning) and the run is uncapped (no enforced split).
FAST_TIER_RATIO="${FAST_TIER_RATIO:-0.5}"
rss_var="${WORKLOAD}_rss"
workload_rss="${!rss_var:-}"
CGROUP_NAME="${CGROUP_NAME:-pact_${WORKLOAD}}"

# --- Environment Setup Flag ---
# When "true", run full machine preparation (uncore frequency pinning + CXL
# config via check_cxl_conf) before the run, mirroring run-pact-old.sh's setup
# phase.  Default is "false" so a plain run does NOT touch machine-wide config.
# Override via env:  run_setup_config=true ./run-pact.sh <workload>
run_setup_config="${run_setup_config:-false}"

# --- Transparent Huge Pages toggle ---
# Default "false" leaves the current THP policy
# untouched.  Override via env:  enable_thp=true ./run-pact.sh <workload>
enable_thp="${enable_thp:-false}"

# --- Output Directory ---
OUTDIR="./results/${WORKLOAD}/pact"
mkdir -p "$OUTDIR"
OUTDIR=$(realpath "$OUTDIR")

echo "=== PACT Run: $WORKLOAD ==="
echo "  CPUs: $cpus ($omp_threads threads)"
echo "  PEBS period: $pebs_period"
echo "  Migration limit: $migration_limit"
echo "  Bin count: $bin_count, Bin width: $bin_width"
echo "  Output: $OUTDIR"
echo ""

# --- Cleanup Function ---
clean_up() {
    echo ""
    echo "Cleaning up..."

    if [ -n "${WORKLOAD_PID:-}" ]; then
        echo "  Killing workload PID $WORKLOAD_PID"
        sudo pkill -TERM -P "$WORKLOAD_PID" 2>/dev/null || true
        kill -TERM "$WORKLOAD_PID" 2>/dev/null || true
        sleep 1
        kill -KILL "$WORKLOAD_PID" 2>/dev/null || true
    fi

    if [ -n "${PACT_PID:-}" ]; then
        echo "  Killing PACT PID $PACT_PID"
        # PACT runs under sudo, so a clean SIGINT (for its stats dump on exit)
        # and the final kill both need sudo.
        sudo kill -SIGINT "$PACT_PID" 2>/dev/null || kill -SIGINT "$PACT_PID" 2>/dev/null || true
        sleep 2
        sudo kill -KILL "$PACT_PID" 2>/dev/null || kill -KILL "$PACT_PID" 2>/dev/null || true
        # Also reap the actual pact process (sudo's child) by name as a backstop.
        sudo pkill -KILL -x pact 2>/dev/null || true
    fi

    kill "${pid_vmstat:-}" 2>/dev/null || true
    kill "${pid_numastat:-}" 2>/dev/null || true

    # Remove the workload cgroup (must have no live procs first).
    if [ -n "${CGROUP_PATH:-}" ] && [ -d "$CGROUP_PATH" ]; then
        sudo rmdir "$CGROUP_PATH" 2>/dev/null || true
    fi

    echo "  Disabling demotion_enabled..."
    echo 0 | sudo tee /sys/kernel/mm/numa/demotion_enabled >/dev/null 2>&1 || true

    if [ "$enable_thp" = "true" ]; then
        echo "  Disabling transparent huge pages (THP policy = never)"
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null 2>&1 || true
        echo never | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null 2>&1 || true
    fi

    echo "Cleanup complete"
}
trap clean_up EXIT INT TERM

# --- PACT kernel modules ---
# tierinit sets up NUMA tiering; kswapdrst keeps kswapd from backing off under
# demotion pressure.  Both are out-of-tree modules under setup/kernel/.
# If a module is already loaded we keep it; if its .ko is built we load it;
# otherwise we abort and tell the user to build it.
ensure_kernel_module() {
    local modname=$1 moddir=$2 ko=$3
    if lsmod | grep -qE "^${modname}[[:space:]]"; then
        echo "  module '$modname' already loaded"
        return 0
    fi
    if [ -f "$ko" ]; then
        echo "  loading module '$modname' ($ko)"
        sudo insmod "$ko" || { echo "  ERROR: failed to load $ko"; exit 1; }
    else
        echo "  ERROR: kernel module '$modname' is not loaded and not built ($ko missing)."
        echo "         Build the PACT kernel modules first:"
        echo "             make -C $moddir"
        echo "         See setup/kernel/README.md for details."
        exit 1
    fi
}

# --- System Setup ---
if [ "$run_setup_config" = "true" ]; then
    # Full machine prep: uncore freq + check_cxl_conf + flush (cold start).
    echo "=== Running full environment setup (prepare_environment.sh) ==="
    ../setup/env/prepare_environment.sh
elif [ "$skip_setup" != "skip_setup" ]; then
    echo "=== Flushing caches ==="
    echo 3 | sudo tee /proc/sys/vm/drop_caches >/dev/null
    free
fi

echo "=== Loading PACT kernel modules ==="
ensure_kernel_module tierinit  ../setup/kernel/tierinit  ../setup/kernel/tierinit/tierinit.ko
ensure_kernel_module kswapdrst ../setup/kernel/kswapdrst ../setup/kernel/kswapdrst/kswapdrst.ko

echo "=== Kernel setup ==="
echo 0 | sudo tee /sys/kernel/mm/numa/demotion_enabled >/dev/null
echo 0 | sudo tee /proc/sys/kernel/numa_balancing >/dev/null
echo "  demotion_enabled=0, numa_balancing=0"

# --- Phase 1: vmtouch (preload data to slow tier) ---
if [ "$skip_setup" != "skip_setup" ] && [ -n "$vmtouch_file" ]; then
    echo "=== Phase 1: Loading $vmtouch_file into slow tier ==="
    numactl --membind 1 "$VMTOUCH" -f -t "$vmtouch_file" -m 64G
    sleep 20
fi

# --- Phase 2: Start Monitoring ---
echo "=== Phase 2: Starting monitoring ==="

cat /proc/vmstat >"$OUTDIR/before_vmstat.log"

touch "$OUTDIR/vmstat.txt"
(while true; do
    ts=$(date +%s)
    echo "$ts" >>"$OUTDIR/vmstat.txt"
    grep -E "pgdemote|pgpromote|pgmigrate|thp_migration|numa_pte_updates" /proc/vmstat >>"$OUTDIR/vmstat.txt"
    sleep 1
done) &
pid_vmstat=$!

# --- Phase 2b: Fast-tier limit via cgroup v2 (the split ratio) ---
# Cap the workload's fast-tier (local DRAM) footprint with a cgroup v2
# memory.high. We use memory.high (a SOFT limit) not memory.max (HARD): under
# memory.high the kernel reclaims/demotes the excess to the slow NUMA tier,
# whereas a hard memory.max with no demotion path OOM-kills the workload. PACT
# then migrates pages between tiers (cold->slow, hot->fast). A generous
# memory.max headroom is kept so a transient spike can't OOM the run.
# Skipped if no RSS/limit is known.
CGROUP_PATH=""
fast_tier_mb=""
if [ -n "${FAST_TIER_MB:-}" ]; then
    fast_tier_mb="$FAST_TIER_MB"
elif [ -n "$workload_rss" ]; then
    # fast_tier_mb = workload_rss * FAST_TIER_RATIO  (awk for float ratio)
    fast_tier_mb=$(awk -v r="$workload_rss" -v f="$FAST_TIER_RATIO" 'BEGIN{printf "%d", r*f}')
fi
if [ -n "$fast_tier_mb" ] && [ "$fast_tier_mb" -gt 0 ]; then
    CGROUP_PATH="/sys/fs/cgroup/${CGROUP_NAME}"
    echo "=== Phase 2b: fast-tier cgroup ${CGROUP_NAME}: memory.high=${fast_tier_mb}MB"
    echo "    (workload_rss=${workload_rss:-?}MB, FAST_TIER_RATIO=${FAST_TIER_RATIO})"
    sudo mkdir -p "$CGROUP_PATH"
    # Ensure the memory controller is delegated to the new cgroup's level.
    echo "+memory" | sudo tee /sys/fs/cgroup/cgroup.subtree_control >/dev/null 2>&1 || true
    # Soft cap drives reclaim/demotion of the excess to the slow tier:
    echo $(( fast_tier_mb * 1024 * 1024 )) | sudo tee "$CGROUP_PATH/memory.high" >/dev/null
    # Keep memory.max generous (RSS + 25% headroom) so a spike can't OOM:
    if [ -n "$workload_rss" ]; then
        echo $(( (workload_rss + workload_rss / 4) * 1024 * 1024 )) | \
            sudo tee "$CGROUP_PATH/memory.max" >/dev/null 2>&1 || true
    fi
    echo "    memory.high = $(cat "$CGROUP_PATH/memory.high" 2>/dev/null) bytes"
else
    echo "WARNING: no <workload>_rss or FAST_TIER_MB set — running UNCAPPED"
    echo "         (no enforced fast/slow split; PACT may have nothing to migrate)."
fi

# --- Phase 3: Launch Workload ---
echo "=== Phase 3: Launching workload ==="

if [ "$enable_thp" = "true" ]; then
    echo "  Enabling transparent huge pages (THP policy = always)"
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/enabled >/dev/null
    echo always | sudo tee /sys/kernel/mm/transparent_hugepage/defrag >/dev/null
fi

# CPU-pin the workload but deliberately do NOT --membind it: PACT is the page
# placer. The workload's data is pre-faulted onto the slow tier in Phase 1
# (vmtouch --membind 1) and PACT promotes hot pages up; binding memory here
# would defeat the experiment. Memory is capped by the cgroup above (Phase 2b).
numactl_args="numactl -C ${cpus} --"
echo "  Executing: ${workload_cmd}"

# Launch inside the fast-tier cgroup (if any): the subshell adds its own PID to
# cgroup.procs before exec'ing the workload, so all the workload's memory is
# accounted against memory.max.
if [ -n "$CGROUP_PATH" ]; then
    OMP_NUM_THREADS=${omp_threads} bash -c '
        echo $$ | sudo tee '"$CGROUP_PATH"'/cgroup.procs >/dev/null
        exec '"${workload_cmd}"'' >"$OUTDIR/workload.output" 2>&1 &
else
    OMP_NUM_THREADS=${omp_threads} eval "${workload_cmd}" >"$OUTDIR/workload.output" 2>&1 &
fi
WORKLOAD_PID=$!
sleep 2

if ! ps -p "$WORKLOAD_PID" >/dev/null 2>&1; then
    echo "Error: Workload (PID $WORKLOAD_PID) exited immediately"
    cat "$OUTDIR/workload.output"
    exit 1
fi

# When workload_cmd uses "cd ... && numactl -- binary", $! is the launching
# shell, not the workload binary. Resolve the real target by its process name
# ($pname, defined in workloads.sh) within this launch's process tree, so we
# don't latch onto the wrong child (a plain "first child" guess is racy for
# multi-process or wrapper-launched workloads).
shell_pid="$WORKLOAD_PID"
target_pid=""
# Match on the kernel comm name, which is truncated to 15 chars (TASK_COMM_LEN),
# so compare against the first 15 chars of $pname.
pname_comm="${pname:0:15}"
# Prefer a pname match anywhere under the launching shell's subtree.
for cand in $(pgrep -P "$shell_pid" 2>/dev/null) $shell_pid; do
    for p in $(pgrep -P "$cand" 2>/dev/null) "$cand"; do
        if [ "$(ps -p "$p" -o comm= 2>/dev/null)" = "$pname_comm" ]; then
            target_pid="$p"
            break 2
        fi
    done
done
# Fall back to the first child if no pname match (e.g. comm name differs).
# (Plain '[ -z x ] && y=...' would return nonzero when target_pid is already
# set and trip 'set -e', so use an explicit if.)
if [ -z "$target_pid" ]; then
    target_pid=$(pgrep -P "$shell_pid" 2>/dev/null | head -1 || true)
fi
if [ -n "$target_pid" ] && [ "$target_pid" != "$shell_pid" ]; then
    echo "  Shell PID: $shell_pid, workload PID: $target_pid ($(ps -p "$target_pid" -o comm= 2>/dev/null))"
    WORKLOAD_PID="$target_pid"
fi

echo "  Workload PID: $WORKLOAD_PID"

# Start numastat monitoring now that we have the PID
touch "$OUTDIR/numastat.log"
(while true; do
    ts=$(date +%s)
    numastat="$(numastat -p "$WORKLOAD_PID" 2>/dev/null | tail -n1 | awk '{print $2 "," $3}')"
    echo "$ts, $numastat" >>"$OUTDIR/numastat.log"
    sleep 1
done) &
pid_numastat=$!

# --- Phase 4: Start PACT ---
echo "=== Phase 4: Starting PACT ==="

start_time=$(date +%s)

# PACT needs root (euid 0) to open the CHA/uncore PMU and PEBS counters
# (validate_hardware_access() aborts otherwise). Launch it under sudo; the
# machine is assumed to allow passwordless sudo (CloudLab does).
PACT_CMD="sudo numactl -C 1 $PACT \
    --workload $WORKLOAD_PID \
    --pebs-period $pebs_period \
    --max-migrations-per-cycle $migration_limit \
    --bin-width $bin_width \
    --bin-count $bin_count"


echo "  Executing: $PACT_CMD"
$PACT_CMD >"$OUTDIR/pact_debug.log" 2>&1 &
PACT_PID=$!
sleep 3

if ! ps -p "$PACT_PID" >/dev/null 2>&1; then
    echo "  FAILED: PACT didn't start"
    tail -20 "$OUTDIR/pact_debug.log"
    exit 1
fi
echo "  PACT started (PID $PACT_PID)"

local_mem=$(numastat -p "$WORKLOAD_PID" 2>/dev/null | tail -n1 | awk '{print $2}')
echo "  Initial memory on node 0: $local_mem MB"

# --- Phase 5: Wait for Workload ---
echo "=== Waiting for workload to complete ==="
while ps -p "$WORKLOAD_PID" >/dev/null 2>&1; do
    sleep 0.1
done

end_time=$(date +%s)
runtime=$((end_time - start_time))
echo "Workload finished. Runtime: ${runtime}s"
echo "Runtime: ${runtime}s" >>"$OUTDIR/workload.output"

# --- Cleanup ---
clean_up

cat /proc/vmstat >"$OUTDIR/after_vmstat.log"

echo ""
echo "=== Run complete ==="
echo "  Results: $OUTDIR"
echo "  Debug log: $OUTDIR/pact_debug.log"
exit 0
