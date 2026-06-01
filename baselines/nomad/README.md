# Nomad (OSDI '24)

Nomad tiering baseline, with its asynchronous-promotion kernel module.

## Contents
- `nomad.patch`, `nomad-alto.patch` - kernel patches applied on top of Linux
  `5.13-rc6`.
- `compile.sh` - checks out `5.13-rc6` in a sibling `linux/` git tree, applies
  both patches, builds, installs modules, runs `make install` and
  `update-grub`.
- `nomad_module/` - out-of-tree `async_promote` kernel module.

## Build (kernel)
`compile.sh` expects a Linux git checkout in `./linux` (not bundled):

```bash
cd nomad && ./compile.sh
```

The script runs: `git checkout 5.13-rc6` → `git apply nomad.patch` →
`git apply nomad-alto.patch` → `make oldconfig` → `make -j` →
`make modules_install` → `make install` → `update-grub`.

## Build (async_promote module)
`async_promote_main.c` includes the kernel-private header `mm/internal.h`,
so the module must be built against the matching kernel source tree. Point
`KERNEL_SRC` at that tree:

```bash
cd nomad_module
make KERNEL_SRC=/path/to/linux-5.13-rc6
```

`KERNEL_SRC` defaults to `/lib/modules/$(uname -r)/build`.

## Running a workload
Kernel + module only; no Nomad-specific run wrapper is shipped. Boot into the
patched kernel, load the module, and drive a workload with your own launcher.
