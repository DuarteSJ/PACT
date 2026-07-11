# PACT kernel setup (Linux 6.3)

This folder builds the kernel PACT runs on and the **two out-of-tree modules
the tiering subsystem needs to work**:

- `setup_kernel.sh` - builds a **vanilla Linux 6.3** kernel.
- `tierinit/`, `kswapdrst/` - required kernel modules (details below).

> **Important:** PACT runs on a *vanilla* (unpatched) Linux 6.3, but the
> kernel's NUMA-tiering subsystem will not behave correctly out of the box for
> our two-node (DRAM + CXL-like) setup. The two modules below configure it.
> **Load both before running PACT** - `run-pact.sh` refuses to start if either
> is missing.

## Required kernel modules

### `tierinit` - register the slow tier and demotion targets
On a stock 6.3 kernel, the far-memory NUMA node (node 1) is treated as just
another DRAM node, so the memory-tiering subsystem builds no demotion path
between the fast tier (node 0) and the slow tier. `tierinit` fixes this at
load time: it assigns the far node a higher abstract distance
(`FARMEM_ADISTANCE`), registers it as a lower memory tier, and re-establishes
the demotion targets - **without any kernel patch**, using `kprobes` to
resolve the internal `memory-tiers` symbols (hence the `CONFIG_KPROBES` /
`CONFIG_KALLSYMS_ALL` requirement below). Without `tierinit`, PACT has no
tier structure to demote/promote pages across.

### `kswapdrst` - keep demotion alive under sustained pressure
The kernel's reclaim/demotion daemon (`kswapd`) increments a per-node
`kswapd_failures` counter and **permanently backs off** once it gives up,
which stalls demotion during long tiering runs. `kswapdrst` periodically
resets `kswapd_failures` on the fast-tier node (every 5 s) so demotion keeps
making progress. (Derived from the Colloid memory-tiering artifact.) Without
`kswapdrst`, demotion can silently stop partway through a workload.

## Requirements

These need a kernel built with the following options (the provided
`setup_kernel.sh` enables them automatically):


- `CONFIG_INTEL_UNCORE_FREQ_CONTROL=y` - uncore-frequency control (used by
  `../env/modify-uncore-freq.sh`).
- `CONFIG_KPROBES=y`, `CONFIG_KALLSYMS_ALL=y`


## 1. Build and install the 6.3 kernel

`setup_kernel.sh` does everything - clone vanilla v6.3, configure, build,
`modules_install`, `install`, and `update-grub` - and then arms a **one-shot**
boot of the new kernel via `grub-reboot`, keeping your current kernel as the
persistent default. So if 6.3 fails to boot (e.g. a missing built-in driver),
the next reboot automatically falls back to the known-good kernel.

```bash
./setup_kernel.sh        # build + install + arm one-shot boot of 6.3
sudo reboot              # boot into 6.3 once; confirm with: uname -r
```

> Do **not** run `update-grub` / `grub-set-default` yourself here - that would
> overwrite the one-shot fallback the script set up. Only make 6.3 the
> persistent default (`grub-set-default ...`) once you have confirmed it boots.

## 2. After rebooting into 6.3, build the modules

Each module has its own Makefile. Build them either way:

```bash
./build_modules.sh
```

or build each separately (from `setup/kernel/`):

```bash
make -C tierinit          # -> tierinit/tierinit.ko
make -C kswapdrst         # -> kswapdrst/kswapdrst.ko
```

## 3. Load the modules

`run-pact.sh` loads them automatically: if a module is already loaded it is
kept, if its `.ko` is built it is `insmod`ed, and if it is missing the run
aborts and asks you to build it (step 2). To load them manually (from
`setup/kernel/`):

```bash
sudo insmod tierinit/tierinit.ko
sudo insmod kswapdrst/kswapdrst.ko
```

Verify and inspect logs:

```bash
lsmod | grep -E 'tierinit|kswapdrst'
sudo dmesg | grep -E 'tierinit|kswapdrst'
```

Unload (reverse order):

```bash
sudo rmmod kswapdrst tierinit
```
