# Environment preparation

Machine-wide configuration for controlled PACT measurements. Run on the host
after booting into the PACT kernel (see [`../kernel/`](../kernel/)).

| Script | Purpose |
|--------|---------|
| `prepare_environment.sh` | One-shot prep: pins uncore frequency, configures the CXL/NUMA layout, and flushes caches. Calls the other two. |
| `modify-uncore-freq.sh` | Pin per-node min/max uncore frequency (fast tier high, slow tier low). |
| `cxl-global.sh` | Helper functions (governor, turbo, THP, KSM, NUMA-balancing, cache flush) sourced by the above. |

## Usage

```bash
# Full one-shot prep (requires root):
sudo ./prepare_environment.sh

# Or just pin uncore frequencies (kHz): node0-min node0-max node1-min node1-max
sudo ./modify-uncore-freq.sh 2000000 2000000 500000 500000
```

Override the default uncore targets via `UNCORE_ARGS`:

```bash
UNCORE_ARGS="2000000 2000000 500000 500000" sudo ./prepare_environment.sh
```

The scripts locate each other by their own directory, so they work regardless
of the current working directory (the runner invokes
`../setup/env/prepare_environment.sh`).
