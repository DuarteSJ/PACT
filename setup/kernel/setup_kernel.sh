#!/bin/bash
# Build script for the PACT Linux 6.3 kernel.
#
# Unlike the 5.15 flow, 6.3 needs NO kernel patch: the PACT tiering hooks are
# provided by the out-of-tree modules in this folder (tierinit/, kswapdrst/),
# which resolve internal symbols via kprobes at load time. This script just
# builds a *vanilla* Linux 6.3 with the config options those modules and the
# uncore-frequency control require.

set -e

# ---------------------------------------------------------------------------
# Paths
# ---------------------------------------------------------------------------
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR/linux"
# Optional: drop a kernel.config next to this script to use it as the base.
BASE_CONFIG="$SCRIPT_DIR/kernel.config"

# ---------------------------------------------------------------------------
# 1. Clone vanilla Linux v6.3
# ---------------------------------------------------------------------------
echo "==> Fetching Linux v6.3 source..."
if [ ! -d "$KERNEL_DIR/.git" ]; then
    git clone --depth=1 --branch v6.3 \
        https://github.com/torvalds/linux.git "$KERNEL_DIR"
else
    echo "    Repo already exists, skipping clone."
fi

cd "$KERNEL_DIR"

# The shallow clone above (--branch v6.3) already fetched the v6.3 tag and left
# HEAD detached at it, so no extra fetch/checkout is needed. We only re-checkout
# defensively when an existing repo was reused and isn't already on v6.3.
echo "==> Ensuring v6.3 is checked out..."
if [ "$(git describe --tags --exact-match 2>/dev/null)" != "v6.3" ]; then
    git checkout v6.3
else
    echo "    Already at v6.3."
fi

# ---------------------------------------------------------------------------
# 2. Base kernel configuration
# ---------------------------------------------------------------------------
if [ -f "$BASE_CONFIG" ]; then
    echo "==> Using provided base config: $BASE_CONFIG"
    cp "$BASE_CONFIG" .config
elif [ -f "/boot/config-$(uname -r)" ]; then
    echo "==> Basing config on the running kernel (/boot/config-$(uname -r))..."
    cp "/boot/config-$(uname -r)" .config
else
    echo "==> No base config found; using 'make defconfig'..."
    make defconfig
fi

echo "==> Running make olddefconfig to resolve symbols for 6.3..."
make olddefconfig

# Trim the module set to what's actually loaded on this machine. A distro base
# config enables ~6000 modules; building+BTF-processing all of them takes ~45
# min. localmodconfig keeps only modules currently loaded (lsmod), cutting the
# build to ~5-10 min. Set PACT_FULL_MODULES=1 to skip this and build everything.
# (The force-enable block below re-adds boot-critical drivers afterward, so the
# trim can't drop the root-disk/NIC drivers.)
if [ "${PACT_FULL_MODULES:-0}" != "1" ]; then
    echo "==> Trimming modules with localmodconfig (set PACT_FULL_MODULES=1 to skip)..."
    yes "" | make LSMOD=/proc/modules localmodconfig || \
        echo "    (localmodconfig failed/skipped; continuing with full config)"
fi

# Skip BTF debug-info generation for modules — it is the single slowest part of
# the build (per-module BTF for the whole tree) and PACT does not need it.
./scripts/config --disable CONFIG_DEBUG_INFO_BTF
./scripts/config --disable CONFIG_DEBUG_INFO_BTF_MODULES

# ---------------------------------------------------------------------------
# 3. Enable the options PACT needs
#    - INTEL_UNCORE_FREQ_CONTROL : uncore freq sysfs (used by modify-uncore-freq.sh)
#    - KPROBES + KALLSYMS_ALL     : required by the tierinit module to
#                                   resolve static mm/memory-tiers symbols at load
#    - MODULES + MODULE_UNLOAD    : load (insmod) and unload (rmmod) the .ko modules
#    (CONFIG_NUMA / CONFIG_MIGRATION are inherited from the base config — MIGRATION
#     is def_bool y whenever NUMA/COMPACTION is on, so there is no need to set them.)
# ---------------------------------------------------------------------------
echo "==> Enabling required kernel options..."
./scripts/config --enable CONFIG_INTEL_UNCORE_FREQ_CONTROL
./scripts/config --enable CONFIG_KPROBES
./scripts/config --enable CONFIG_KALLSYMS_ALL
./scripts/config --enable CONFIG_MODULES
./scripts/config --enable CONFIG_MODULE_UNLOAD

# Clear distro signing-key paths. A distro base config (e.g. Ubuntu's
# /boot/config) sets CONFIG_SYSTEM_TRUSTED_KEYS / CONFIG_SYSTEM_REVOCATION_KEYS
# to Canonical cert files (debian/canonical-*.pem) that do not exist in the
# vanilla torvalds tree, so the 'certs' build step fails with
# "make[1]: *** [certs] Error 2". Blank them and disable module signing so a
# vanilla build succeeds and our out-of-tree modules load without a signature.
echo "==> Clearing distro signing keys (avoid certs build failure)..."
./scripts/config --set-str CONFIG_SYSTEM_TRUSTED_KEYS ""
./scripts/config --set-str CONFIG_SYSTEM_REVOCATION_KEYS ""
./scripts/config --disable CONFIG_MODULE_SIG
./scripts/config --disable CONFIG_MODULE_SIG_ALL



# Boot-critical drivers MUST be built-in (=y), not modules (=m). On a typical
# stock distro/CloudLab config the root-disk and NIC drivers ship as modules;
# a freshly built kernel can then fail to boot because those modules are not in
# the initramfs (no root disk, no network). Force the storage + NIC drivers
# this class of machine needs into the kernel image.
#
# IMPORTANT: a SATA root disk (e.g. /dev/sda on CloudLab c220g5) presents as a
# SCSI "sd" device, so the SCSI disk stack (SCSI, BLK_DEV_SD) and the SATA host
# controllers (SATA_AHCI, ATA_PIIX) must ALL be built-in — enabling SATA_AHCI
# alone is not enough and the kernel drops to an initramfs shell with
# "Gave up waiting for root file system device". NVMe is included for nodes
# whose root is NVMe. Extras are harmless if absent.
echo "==> Forcing boot-critical storage + NIC drivers built-in..."
for opt in \
        SCSI SCSI_MOD BLK_DEV_SD \
        ATA SATA_AHCI ATA_PIIX SATA_MOBILE_LPM_POLICY \
        BLK_DEV_NVME NVME_CORE \
        SCSI_MPT3SAS \
        EXT4_FS \
        IXGBE I40E ICE IGB E1000E MLX5_CORE; do
    ./scripts/config --enable "CONFIG_${opt}"
done

# Pin the kernel release string to a plain "6.3.0" by disabling
# LOCALVERSION_AUTO. With it on, the build appends "-dirty" (via `git describe`)
# whenever the source tree has any uncommitted change, so the kernel boots as
# "6.3.0" but out-of-tree modules build with vermagic "6.3.0-dirty" and the
# kernel then REFUSES to load them ("vermagic mismatch") until a manual
# `make clean && make`. Disabling it keeps module vermagic == running kernel.
./scripts/config --disable CONFIG_LOCALVERSION_AUTO
# Pull in any dependencies the above may require
make olddefconfig

for opt in CONFIG_INTEL_UNCORE_FREQ_CONTROL CONFIG_KPROBES CONFIG_KALLSYMS_ALL \
           CONFIG_MODULES CONFIG_MODULE_UNLOAD; do
    if grep -q "^${opt}=y" .config; then
        echo "    ${opt}=y  confirmed."
    else
        echo "WARNING: ${opt} may not be set — check .config manually."
    fi
done

# ---------------------------------------------------------------------------
# 4. Build
# ---------------------------------------------------------------------------
NPROC=$(nproc)
echo "==> Building kernel with $NPROC parallel jobs..."
echo "    (this will take several minutes)"
make -j"$NPROC"

# ---------------------------------------------------------------------------
# 5. Done
# ---------------------------------------------------------------------------
echo ""
echo "==> Build complete."
echo ""
echo "    Kernel image  : $KERNEL_DIR/arch/x86/boot/bzImage"
echo "    Kernel version: $(make kernelrelease 2>/dev/null)"
echo ""
echo "    To install (requires root):"

echo "      sudo make -C $KERNEL_DIR modules"
sudo make -C "$KERNEL_DIR" modules

echo "      sudo make -C $KERNEL_DIR modules_install"
sudo make -C "$KERNEL_DIR" modules_install

echo "      sudo make -C $KERNEL_DIR install"
sudo make -C "$KERNEL_DIR" install

# ---------------------------------------------------------------------------
# 6. GRUB: test the new kernel SAFELY with a one-shot boot.
#
# `make install` runs update-grub, which makes the newest kernel (6.3) the
# DEFAULT boot entry. On a remote/headless machine that is dangerous: if 6.3
# fails to boot (e.g. a missing built-in driver -> initramfs shell), EVERY
# subsequent reboot lands in the broken kernel. So we keep the current,
# known-good kernel as the persistent default and boot 6.3 exactly ONCE via
# grub-reboot. If that boot fails, the next reboot automatically falls back to
# the known-good kernel.
# ---------------------------------------------------------------------------
RUNNING_KVER="$(uname -r)"
NEW_KVER="$(make -s kernelrelease 2>/dev/null || echo 6.3.0)"
echo ""
echo "==> Configuring GRUB for a SAFE one-shot test of ${NEW_KVER}..."
sudo sed -i 's/^GRUB_DEFAULT=.*/GRUB_DEFAULT=saved/' /etc/default/grub
sudo update-grub >/dev/null 2>&1
# Persistent default stays on the currently-running (known-good) kernel:
sudo grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux ${RUNNING_KVER}" 2>/dev/null || true
# Arm a ONE-SHOT boot of the new kernel for the next reboot only:
sudo grub-reboot "Advanced options for Ubuntu>Ubuntu, with Linux ${NEW_KVER}"

cat <<EOF

==> Build + install complete. The new kernel (${NEW_KVER}) is armed for a
    ONE-SHOT boot; the persistent default remains ${RUNNING_KVER}.

    Next steps:
      1. (Recommended) keep a serial console open in case the boot fails:
             mclab console <experiment>        # CloudLab
      2. Reboot to test the new kernel once:
             sudo reboot
      3. After it comes back, confirm you are on the new kernel:
             uname -r        # expect ${NEW_KVER}
         If the node dropped to an initramfs shell instead, the one-shot has
         already expired, so just reboot again to return to ${RUNNING_KVER}
         and fix the kernel config.
      4. Only once ${NEW_KVER} boots cleanly, make it the default if you want:
             sudo grub-set-default "Advanced options for Ubuntu>Ubuntu, with Linux ${NEW_KVER}"
             sudo update-grub
EOF
