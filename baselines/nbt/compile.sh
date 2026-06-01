#!/bin/bash
# Build the NBT baseline kernel: Linux v5.18 + nbt.patch.
# Expects a Linux git checkout at ./linux (clone it there first; not bundled).
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
KERNEL_DIR="$SCRIPT_DIR/linux"
PATCH="$SCRIPT_DIR/nbt.patch"
LOGF="$SCRIPT_DIR/log"

[[ -d "$KERNEL_DIR" ]] || { echo "ERROR: kernel tree not found at $KERNEL_DIR (clone Linux there first)"; exit 1; }
[[ -e "$PATCH" ]]      || { echo "ERROR: patch not found: $PATCH"; exit 1; }

cd "$KERNEL_DIR"
git checkout v5.18
echo "Applying $(basename "$PATCH") ..."
git apply "$PATCH"

echo "make oldconfig ..."
yes "" | make oldconfig > "$LOGF" 2>&1
echo "make ..."
make -j "$(nproc)" >> "$LOGF" 2>&1
echo "make INSTALL_MOD_STRIP=1 modules_install ..."
make INSTALL_MOD_STRIP=1 modules_install >> "$LOGF" 2>&1
echo "make install ..."
make install >> "$LOGF" 2>&1
echo "update-grub ..."
update-grub

rm -f "$LOGF"
