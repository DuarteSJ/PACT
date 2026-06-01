# PAC modeling

Scripts for collecting the perf counters used in the Figure 3 correlation
plots, which motivate the LLC-miss/MLP metric across three memory tiers.

---

## Directory structure

```
modeling/
├── run-models.sh        # collect perf counters → CSV
├── raw/                 # created at runtime - perf stat output + models.csv
├── skx/                 # Skylake-X reference data + gnuplot
│   ├── dat/
│   │   └── r-l3_stall_skx.csv   # gnuplot input (complete SKX reference)
│   ├── eps/             # created at runtime - gnuplot writes corr.pdf here
│   └── plot/
│       └── corr.plot    # gnuplot script for Figure 3
└── README.md
```

---

## What is being measured

Each workload runs three times - once per memory tier - under `numactl --membind`:

| Tier | Latency | Node variable |
|------|---------|--------------|
| Tier 1 | ~90ns  | `LOCAL_NODE` - local DRAM |
| Tier 2 | ~140ns | `NUMA_NODE`  - remote NUMA |
| Tier 3 | ~190ns | `CXL_NODE`   - CXL-emulated |

Four hardware counters collected per run (single `perf stat` pass):

| Counter | Role |
|---------|------|
| `CYCLE_ACTIVITY.STALLS_L3_MISS` | `l3_stall` |
| `MEM_LOAD_RETIRED.L3_MISS` | `l3_miss` |
| `OFFCORE_REQUESTS_OUTSTANDING.DEMAND_DATA_RD` | MLP numerator |
| `OFFCORE_REQUESTS_OUTSTANDING.CYCLES_WITH_DEMAND_DATA_RD` | MLP denominator |

Derived metrics written to CSV:


> **Note:** Counter names and the model constants in `corr.plot` are calibrated
> for Intel Skylake-X (SKX). See `skx/` for the complete reference dataset.

---

## Previously gathered data - Intel Skylake-X

`skx/dat/r-l3_stall_skx.csv` contains the complete reference dataset
collected on an Intel Skylake-X server (95 workloads × 3 tiers).  
To regenerate Figure 3 from this data:

```bash
cd skx
gnuplot plot/corr.plot
# output → eps/corr.pdf
```

Newly collected data is written to `raw/models.csv` by `run-models.sh`. Copy it to `skx/dat/r-l3_stall_skx.csv` before plotting.

---

## Running workloads

### 1. Verify NUMA topology

```bash
numactl --hardware
```

Edit `CPU_NODE`, `LOCAL_NODE`, `NUMA_NODE`, `CXL_NODE` at the top of `run-models.sh`
to match your server.

### 2. Run SPEC CPU 2017 workloads

```bash
sudo ./run-models.sh --spec
```

Runs every workload in `SPEC_WORKLOADS` × 3 tiers.

### 3. Run GAPBS workloads

```bash
sudo ./run-models.sh --gapbs
```

Runs every workload in `GAPBS_WORKLOADS` × 3 tiers.  
Graph is preloaded into the target NUMA node's page cache via `vmtouch` before each tier run.



### 5. Plot

Copy the collected CSV to the gnuplot data folder, then run the plot:

```bash
cp raw/models.csv skx/dat/r-l3_stall_skx.csv
cd skx && gnuplot plot/corr.plot
# output → skx/eps/corr.pdf
```

---


## Adding or changing workloads

Workloads are defined at the top of `run-models.sh` in two separate arrays.

**SPEC CPU 2017** - format `"NAME|COMMAND"`:

```bash
SPEC_DIR="/path/to/cpu2017/run"

SPEC_WORKLOADS=(
    "505.mcf_r|cd ${SPEC_DIR}/505.mcf_r && ./mcf_r_base.mytest-m64 inp.in"
    "502.gcc_r|cd ${SPEC_DIR}/502.gcc_r  && ./cpugcc_r_base.mytest gcc-pp.c ..."
    # add more SPEC workloads here
)
```

**GAPBS** - just the workload name; the run command is inside `func_run_gapbs_tier`:

```bash
GAPBS_WORKLOADS=(
    "bc-kron"
    # add more GAPBS workloads here (requires matching func_run_gapbs_tier logic)
)
```

Each workload runs under `numactl --cpunodebind --membind` automatically -
no need to add `numactl` inside the command.


---

## Prerequisites

- `numactl` - `apt install numactl`
- `vmtouch` - `apt install vmtouch` (GAPBS graph preloading)
- `perf` - patched perf built by `setup/perf/install-perf.sh`; override its location with `PERF=/path/to/perf ./run-models.sh` (defaults to `perf` in `$PATH`)
- `gnuplot` - required only for plotting, not for data collection
- Workload binaries installed and paths configured in `run-models.sh`
