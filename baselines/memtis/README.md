# Memtis - Linux v5.15.19 kernel

This folder builds the Memtis kernel used as a baseline in PACT evaluation. Memtis is a hardware-performance-counter-driven tiered memory management system that profiles per-page access frequency using PEBS and migrates pages between tiers accordingly.

---

## Folder contents

| File | Purpose |
|------|---------|
| `setup_memtis.sh` | One-shot build script - clone, patch, configure, compile |
| `memtis.patch` | Memtis patch applied to clean Linux v5.15.19 |
| `config` | Base `.config` used as the starting configuration |

---

## Requirements

- `git`, `make`, `gcc` (gcc 9+ recommended)
- Kernel build dependencies:

```bash
# Ubuntu / Debian
sudo apt install git build-essential bc bison flex libelf-dev libssl-dev \
     libncurses-dev dwarves pahole

# RHEL / CentOS / Fedora
sudo dnf install git gcc make bc bison flex elfutils-libelf-devel openssl-devel \
     ncurses-devel dwarves
```

- At least **20 GB** free disk space
- At least **8 GB RAM** recommended for parallel build

---

## Usage

```bash
chmod +x setup_memtis.sh
./setup_memtis.sh
```

The script will:
1. Clone `torvalds/linux` at tag `v5.15.19` into `linux/`
2. Apply `memtis.patch` (sets `EXTRAVERSION = -htmm`)
3. Copy `config` as the base `.config`
4. Run `make olddefconfig` to resolve any new symbols
5. Force `CONFIG_INTEL_UNCORE_FREQ_CONTROL=y` (built-in `*`)
6. Build with `make -j$(nproc)`

If the repo is already present the clone step is skipped automatically.

---

## Installation (optional)

```bash
cd linux
sudo make modules_install
sudo make install
sudo reboot
```

Verify after reboot:
```bash
uname -r
# expected: 5.15.19-htmm
```
