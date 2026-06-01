# Tiering systems

This directory contains runtime configuration scripts and run scripts for baseline tiered memory management systems used in PACT evaluation.

## Supported systems

| System | Description |
|--------|-------------|
| **TPP** | Transparent Page Placement - ASPLOS'23 |
| **NBT** | Linux NUMA-Balancing-Tiering (v6.3) |
| **Nomad** | Non-exclusive Memory Tiering - OSDI'24 |
| **Colloid** | Access Latency is Key! - SOSP'24 |
| **Memtis** | Hardware-counter-driven tiered memory using PEBS for per-page access profiling and frequency-based migration - SOSP'23. [memtis/](memtis/) |
| **Soar/Alto** | AOL-based Layered Tiering Orchestrationand and Static Object Allocation based on Ranking - OSDI'25. [Paper](https://www.usenix.org/conference/osdi25/presentation/liu) · [Code](https://github.com/MoatLab/SoarAlto) |
## Per-system directories

Each baseline lives in its own subdirectory with a kernel patch, a
`compile.sh`, and a README describing the exact kernel tag and build steps:

| System | Directory | Kernel base |
|--------|-----------|-------------|
| TPP | [`tpp/`](tpp/) | v5.15 |
| NBT | [`nbt/`](nbt/) | v5.18 |
| Nomad | [`nomad/`](nomad/) | 5.13-rc6 |
| Colloid-tpp | [`colloid-tpp/`](colloid-tpp/) | v6.3 |
| Memtis | [`memtis/`](memtis/) | v5.15.19 |
| Soar/Alto | [`soar-alto/`](soar-alto/) | v6.3 |

## Notes

* `Colloid` in our work refers to `Colloid-tpp`, though the Colloid paper
  actually uses NBT (NUMA-Balancing-Tiering) in Linux v6.3.
* These directories ship the kernel patches and build scripts. They do not
  include per-system workload run wrappers; boot the patched kernel and drive
  workloads with your own launcher (PACT's own runner is in [`../`](../)).
