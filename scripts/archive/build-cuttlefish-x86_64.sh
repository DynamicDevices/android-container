#!/usr/bin/env bash
#
# Build the Cuttlefish x86_64 virtual Android device FROM SOURCE, reusing the
# locally-synced NXP imx-android-16.0.0_1.2.0 tree (Android 16) which already
# contains device/google/cuttlefish and the aosp_cf_x86_64_phone target.
#
# Heavy, long-running (~1.5-4h). Runs under nice/ionice so it yields to
# interactive desktop work (repo low-priority build rule). Builds into a
# dedicated OUT_DIR so the existing i.MX95 (evk_95) build in ./out is untouched.
#
# Usage:   ./scripts/build-cuttlefish-x86_64.sh [jobs]
#   jobs   parallelism for `m` (default: nproc)

set -euo pipefail

# Resolve workspace root from this script's location (keep paths relative).
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
WORKSPACE_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

ANDROID_TREE="${WORKSPACE_ROOT}/downloads/extracted-android-16.0.0_1.2.0/imx-android-16.0.0_1.2.0/android_build"
LUNCH_TARGET="aosp_cf_x86_64_phone-bp2a-userdebug"
JOBS="${1:-$(nproc)}"

NICE_LEVEL="${NICE_LEVEL:-15}"
IONICE_CLASS="${IONICE_CLASS:-2}"
IONICE_LEVEL="${IONICE_LEVEL:-7}"

export OUT_DIR="${OUT_DIR:-out_cf}"

# This is an NXP imx-android tree. Soong analyses ALL Android.bp in the tree,
# including vendor/nxp/* modules that are i.MX-only. For the x86_64 cuttlefish
# vendor variant some NXP HALs (e.g. android.hardware.media.c2.service.imx)
# are enabled but depend on i.MX-gated modules that are disabled on x86_64,
# which makes soong bootstrap fail. Downgrade those to stubs so the cuttlefish
# product can build without touching the NXP sources.
export ALLOW_MISSING_DEPENDENCIES="${ALLOW_MISSING_DEPENDENCIES:-true}"

if [ ! -f "${ANDROID_TREE}/build/envsetup.sh" ]; then
    echo "ERROR: AOSP tree not found at: ${ANDROID_TREE}" >&2
    exit 1
fi

echo "== Cuttlefish x86_64 from-source build =="
echo "  tree    : ${ANDROID_TREE}"
echo "  target  : ${LUNCH_TARGET}"
echo "  OUT_DIR : ${OUT_DIR}  (keeps existing ./out i.MX95 build intact)"
echo "  jobs    : ${JOBS}"
echo "  nice/io : nice -n ${NICE_LEVEL} ionice -c${IONICE_CLASS} -n${IONICE_LEVEL}"
echo

df -h "${ANDROID_TREE}" | sed 's/^/  df  /'
echo

cd "${ANDROID_TREE}"

LOG="${WORKSPACE_ROOT}/logs/cuttlefish-x86_64-build-$(date +%Y%m%d-%H%M%S).log"
mkdir -p "${WORKSPACE_ROOT}/logs"
echo "  log     : ${LOG}"
echo

# shellcheck disable=SC1091
source build/envsetup.sh
lunch "${LUNCH_TARGET}"

nice -n "${NICE_LEVEL}" ionice -c"${IONICE_CLASS}" -n"${IONICE_LEVEL}" \
    m -j"${JOBS}" 2>&1 | tee "${LOG}"

echo
echo "== Build finished =="
echo "  images      : ${ANDROID_TREE}/${OUT_DIR}/target/product/vsoc_x86_64/*.img"
echo "  host package: ${ANDROID_TREE}/${OUT_DIR}/host/linux-x86/cvd-host_package.tar.gz"
