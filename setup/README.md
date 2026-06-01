# Host setup

Bring a fresh machine to a state where PACT can run. Do this **before**
building `../src/` or using `../run/`.

| Subdir | Purpose |
|--------|---------|
| [`kernel/`](kernel/) | Build, install, and boot vanilla **Linux 6.3**, then build and load the two modules the tiering subsystem requires - `tierinit` (registers the slow tier + demotion targets) and `kswapdrst` (keeps `kswapd`/demotion from stalling). |
| [`env/`](env/) | Prepare the machine for controlled runs: uncore-frequency pinning, CXL/NUMA layout, performance governor, and disabling turbo / THP / KSM / NUMA-balancing. |
| [`perf/`](perf/) | Build the PAC-patched `perf` used for PAC sampling (`install-perf.sh` clones Linux v5.15, applies `pac_perf.patch`, and builds the `perf` binary). |

## Order

1. **Kernel** - [`kernel/`](kernel/): `setup_kernel.sh` → reboot into 6.3 →
   `build_modules.sh`.
2. **Environment** - [`env/`](env/): `sudo ./prepare_environment.sh` (or let
   the runner do it via `run_setup_config=true ./run-pact.sh ...`).

The env scripts source each other by their own location, so they can be
invoked from anywhere (e.g. the runner calls
`../setup/env/prepare_environment.sh`).

## Validate the CXL emulation (important)

The slow tier is emulated by a remote NUMA node with its CPUs taken offline
and its uncore frequency pinned low. `check_cxl_conf` now **aborts** if Node 1
still has online CPUs (an unvalidated layout silently produces invalid
results). Two things are *not* auto-validated and you should confirm them:

1. **Topology** - after `prepare_environment.sh`, the slow-tier node must be
   CPU-less:

   ```bash
   numactl --hardware        # 'node 1 cpus:' should be empty
   ```

2. **Latency** - the emulated tiers should land near the paper's targets
   (~90 ns local DRAM, ~140 ns remote NUMA, ~190 ns CXL-emulated; see
   [`../modeling/README.md`](../modeling/README.md)). Measure with a
   pointer-chase latency tool (e.g. Intel MLC `--latency_matrix`, or the
   `ptr_chase` microbenchmark) and adjust the uncore-frequency targets in
   [`env/modify-uncore-freq.sh`](env/modify-uncore-freq.sh) /
   `UNCORE_ARGS` until the slow tier matches. Pinning the frequency without
   checking the resulting latency is the most common source of invalid
   tiering results.

## Set the local (fast-tier) DRAM size

Use `memmap` on the GRUB cmdline to reserve DRAM and shrink the fast tier.

> Example: CloudLab `c220g5` has 96 GB DRAM per socket. Adding
> `memmap=76G!2G` to `GRUB_CMDLINE_LINUX` reserves 76 GB starting at 2 GB.
> After `update-grub` and reboot: `node 0 size: 20730 MB; node 0 free:
> 18746 MB`. The values vary by ~hundreds of MB each boot - tune carefully.

## Notes

- The current scripts assume a **2-NUMA-node** server (one fast tier, one
  CXL-like slow tier).
