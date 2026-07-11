# NBT

NBT tiering baseline.

## Contents
- `nbt.patch` - kernel patch applied on top of Linux `v5.18`.
- `compile.sh` - checks out `v5.18` in a sibling `linux/` git tree, applies
  `nbt.patch`, builds, installs modules, runs `make install` and
  `update-grub`.

## Build
`compile.sh` expects a Linux git checkout in `./linux` (not bundled). Clone it
first, then build (kernel install + `update-grub` need root):

```bash
cd nbt
git clone https://github.com/torvalds/linux.git linux   # v5.18 is a mainline tag
sudo ./compile.sh
```

The script runs: `git checkout v5.18` → `git apply nbt.patch` →
`make olddefconfig` → `make -j` → `make modules_install` → `make install` →
`update-grub`.

## Running a workload
Kernel patch only; no NBT-specific run wrapper is shipped. Boot into the
patched kernel and drive a workload with your own launcher.
