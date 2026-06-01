```
 ____      _      ____  _____
|  _ \    / \    / ___||_   _|
| |_) |  / _ \  | |     | |
|  __/  / ___ \ | |___  | |
|_|    /_/   \_\ \____| |_|
```
# PACT - Runner

Run a workload under the PACT runtime. This directory assumes the host is
already prepared and the runtime is built:

1. Host set up - see [`../setup/`](../setup/) (Linux 6.3 + modules + env prep).
2. PACT runtime built - see [`../src/`](../src/) (`cd ../src && make`).

## Contents

| File | Description |
|------|-------------|
| [`run-pact.sh`](run-pact.sh) | Main runner - run a single workload under PACT |
| [`workloads.sh`](workloads.sh) | Workload definitions (sourced by `run-pact.sh`) |

## Running a workload

```bash
./run-pact.sh <workload_name>
```

Example:

```bash
./run-pact.sh bc_kron_8t        # any workload name defined in workloads.sh
```

What the script does:
- Loads the PACT kernel modules from [`../setup/kernel/`](../setup/kernel/)
  (or aborts, telling you to build them).
- Preloads the workload's data into the slow tier with `vmtouch`.
- Caps the workload's fast-tier (DRAM) footprint with a cgroup v2 `memory.high`
  set to `<workload>_rss * FAST_TIER_RATIO` - this is what creates the
  fast/slow split (see below).
- Pins the PACT runtime to CPU 1 and the workload to the other CPU cores.
- Launches `../src/pact` (under `sudo`; PACT needs root for PEBS/PMU) with the
  default PEBS / migration / binning parameters.
- Saves logs to `results/<workload>/pact/`.

### How the tiering experiment works (read this)

PACT only has work to do when the workload's **hot pages start on the slow
tier** - then PACT samples the remote-DRAM accesses (PEBS), scores their
performance-criticality, and promotes the hot ones to the fast tier. For a run
to exercise PACT you therefore need a genuine fast/slow split:

- **Fast-tier ratio.** `FAST_TIER_RATIO` (default `0.5` = a **1:1 split**) and
  `<workload>_rss` (peak RSS in MB, in `workloads.sh`) set the cgroup
  `memory.high = rss * ratio`. With `0.5`, half the working set fits in DRAM and
  the rest spills to the slow tier. Override per run, e.g.
  `FAST_TIER_RATIO=0.33 ./run-pact.sh bc_kron_8t` for a 1:2 split. (You can also
  set an absolute `FAST_TIER_MB`.)
- **`_rss` is the ANON working set, and is graph/input dependent.** Re-measure
  for your graph: `/usr/bin/time -v ./bc -f kron.sg -i1 -n1` → "Maximum
  resident set size" (kbytes/1024 = MB). If `_rss` is unset the run is
  **uncapped** (no split, nothing to migrate) and prints a warning.
- **Permissions.** `perf_event_paranoid` must be `<= 0` or PACT collects **zero
  PEBS samples** even as root. `setup/env/prepare_environment.sh` sets it to
  `-1`; if you skip env prep, do `sudo sysctl kernel.perf_event_paranoid=-1`.
- **Checking it worked.** A healthy run shows, in `results/<wl>/pact/pact_debug.log`,
  `pebs_samples` climbing into the millions and non-zero `Promotions
  (successful)`, and `numastat -p <bc-pid>` shows the workload's node-0 (fast)
  footprint growing over time. If `pebs_samples=0`, the hot set never reached
  the slow tier (cap too loose, or run too short) or paranoid is too high.

### Tunables (environment variables)

`FAST_TIER_RATIO` / `FAST_TIER_MB` (the split, see above), `pebs_period`,
`migration_limit`, `bin_count`, `bin_width`, `PACT`, `VMTOUCH`,
`run_setup_config`, `enable_thp`. Example:

```bash
pebs_period=200 bin_count=32 ./run-pact.sh bc_kron_8t
enable_thp=true ./run-pact.sh bc_kron_8t      # switch the system THP policy
```

### Workload data paths

Dataset locations come from environment variables (no machine-specific paths
are baked in). Set them to match your node before running, e.g.:

```bash
export GAPBS_DIR=/path/to/gapbs        # ./bc and graphs
export SPEC_DIR=/path/to/cpu2017       # licensed SPEC CPU 2017
export SILO_DIR=/path/to/silo
export UBENCH_DIR=/path/to/microbenchmarks
```

See [`workloads.sh`](workloads.sh) for the full list of predefined workloads
and the variables each one expects.

### Obtaining the datasets

The artifact does not bundle workload data (some is licensed; the graphs are
large). Build/obtain each from its upstream source:

- **GAPBS** ([github.com/sbeamer/gapbs](https://github.com/sbeamer/gapbs)) -
  `make` produces `bc` and `converter`. The `bc_kron_*` workloads read a
  serialized Kronecker graph at `${GAPBS_GRAPH_DIR}/kron.sg`; generate it with
  the `converter`:

  ```bash
  cd gapbs && make
  # -g <scale>: 2^scale vertices, -k <degree>: avg degree, -b: serialized .sg
  ./converter -g 25 -k 16 -b benchmark/graphs/kron.sg
  export GAPBS_DIR=$PWD
  ```

  Pick `scale`/`degree` so the graph's resident size matches your fast-tier
  budget (the paper uses a Kronecker graph sized to exceed local DRAM so it
  spills to the slow tier). `-g 25 -k 16` is the Graph500 default starting
  point; adjust to your node.

- **SPEC CPU 2017** (`603.bwaves_s`, `649.fotonik3d_s`) - a **licensed**
  benchmark; install it yourself and point `SPEC_DIR` at the run tree. The
  workloads invoke the per-benchmark run command / `cmd.sh` inside each
  benchmark directory.

- **Silo** ([github.com/stephentu/silo](https://github.com/stephentu/silo)) -
  build the `out-perf.masstree` target; `SILO_DIR` points at the build root
  (the runner expects `out-perf.masstree/benchmarks/dbtest`).

- **Microbenchmarks** (`ptr_chase`, `seq_array`) - point `UBENCH_DIR` at the
  directory containing those two binaries.

### Full machine preparation

For controlled measurements, prepare the machine first (uncore-frequency
pinning, CXL/NUMA layout, governor, disable turbo/THP/KSM/NUMA-balancing) -
see [`../setup/env/`](../setup/env/). You can also fold it into a run:

```bash
run_setup_config=true ./run-pact.sh bc_kron_8t
```

## Verifying a run (kick-the-tires)

A run writes to `results/<workload>/pact/`:

| File | What it shows |
|------|---------------|
| `vmstat.txt` | `pgpromote*` / `pgdemote*` / `pgmigrate*` counters sampled each second |
| `numastat.log` | the workload's per-node (node0 = fast, node1 = slow) resident memory over time |
| `pact_debug.log` | PACT runtime log (PAC sampling, binning, migration decisions) |
| `workload.output` | the workload's own stdout/stderr |

You don't need a golden number to confirm the pipeline works - confirm
**movement** instead. During a healthy run:

```bash
# promotion/demotion counters should be increasing (pages moving between tiers):
tail -f results/bc_kron_8t/pact/vmstat.txt

# the workload's node0 (fast-tier) footprint should grow as PACT promotes
# hot pages (data starts on node1 after the vmtouch preload):
tail -f results/bc_kron_8t/pact/numastat.log
```

If `pgpromote`/`pgmigrate` stay flat at zero, tiering is not active - re-check
the kernel modules (`lsmod | grep -E 'tierinit|kswapdrst'`) and the CXL
topology (`numactl --hardware`; node1 should be CPU-less). Absolute slowdown
numbers depend on the graph size, tier latency, and DRAM budget, so compare
PACT against a baseline run on the *same* machine rather than to a fixed
target.
