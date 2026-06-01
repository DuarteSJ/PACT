#!/bin/bash

# Clones Linux v5.15, applies the PAC perf patch, and builds the perf binary.
# Result: <install_dir>/perf
#
# usage: ./install-perf.sh [install_dir]
#   install_dir  where to clone and build (default: ./linux-5.15-pact)

set -e

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
PATCH="${SCRIPT_DIR}/pac_perf.patch"
INSTALL_DIR="${1:-${SCRIPT_DIR}/linux-5.15-pact}"
KERNEL_TAG="v5.15"
KERNEL_REPO="https://git.kernel.org/pub/scm/linux/kernel/git/stable/linux.git"

# ── checks ─────────────────────────────────────────────────────────────────────
[[ ! -f "${PATCH}" ]] && echo "patch not found: ${PATCH}" && exit 1

if [[ -d "${INSTALL_DIR}" ]]; then
    echo "==> ${INSTALL_DIR} already exists — skipping clone"
else
    echo "==> cloning Linux ${KERNEL_TAG} into ${INSTALL_DIR} (shallow)"
    git clone --depth 1 --branch "${KERNEL_TAG}" "${KERNEL_REPO}" "${INSTALL_DIR}"
fi

# ── apply patch ────────────────────────────────────────────────────────────────
PERF_DIR="${INSTALL_DIR}/tools/perf"

echo "==> applying PAC patch"
cd "${PERF_DIR}"
if patch --dry-run -p1 -R --quiet < "${PATCH}" 2>/dev/null; then
    echo "    patch already applied — skipping"
else
    patch -p1 < "${PATCH}"
fi

# ── build ──────────────────────────────────────────────────────────────────────
echo "==> building perf (target: perf only)"
make -j"$(nproc)" perf

BINARY="${PERF_DIR}/perf"
echo ""
echo "==> done: ${BINARY}"
echo "    version: $("${BINARY}" --version)"
echo ""
echo "    update PERF in run-microbenchmark.sh:"
echo "      PERF=${BINARY}"
