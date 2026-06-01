# NBT

NBT tiering baseline.

## Contents
- `nbt.patch` - kernel patch applied on top of Linux `v5.18`.
- `compile.sh` - checks out `v5.18` in a sibling `linux/` git tree, applies
  `nbt.patch`, builds, installs modules, runs `make install` and
  `update-grub`.

## Build
`compile.sh` expects a Linux git checkout in `./linux` (not bundled):

```bash
cd nbt && ./compile.sh
```

The script runs: `git checkout v5.18` → `git apply nbt.patch` →
`make oldconfig` → `make -j` → `make modules_install` → `make install` →
`update-grub`.

## Running a workload
Kernel patch only; no NBT-specific run wrapper is shipped. Boot into the
patched kernel and drive a workload with your own launcher.
