#!/usr/bin/env bash
# Setup and build NXP i.MX Android 16 (android-16.0.0_1.2.0) for i.MX95 (evk_95 product).
# Default board variant: 15x15 FRDM (imx95-15x15-lpddr4x-frdm), not 19x19 EVK reference.
# Source bundle: imx-android-16.0.0_1.2.0.tar.gz from NXP (not the EVK flash prebuilt).
# Run from android-container/ or anywhere; paths are relative to this repo.
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"
LOG_DIR="${CONTAINER_ROOT}/logs"
mkdir -p "${LOG_DIR}"

# --- Config (Phase 1) ---
RELEASE_ID="android-16.0.0_1.2.0"
MANIFEST_URL="https://github.com/nxp-imx/imx-manifest.git"
MANIFEST_BRANCH="imx-android-16"
MANIFEST_FILE="${MANIFEST_FILE:-imx-android-16.0.0_1.2.0.xml}"
# Confirm in i.MX Android 16 User's Guide / lunch menu if NXP renames the combo.
LUNCH_TARGET="${LUNCH_TARGET:-evk_95-nxp_stable-userdebug}"
BOARD="evk_95"

# Board / SoC variant within evk_95 (see device/nxp/imx9/evk_95/BoardConfig.mk).
# 15x15-frdm  — i.MX95 15×15 FRDM (e.g. imx95-15x15-lpddr4x-frdm; Foundries imx95-frdm-evk)
# 19x19-evk   — i.MX95 19×19 EVK reference (default NXP demo / image_95evk prebuilts)
BOARD_VARIANT="${BOARD_VARIANT:-15x15-frdm}"
IMX_SOC_FLASH="${IMX_SOC_FLASH:-imx95}"

# uuu_imx_android_flash.sh -u (bootloader). Must match BOARD_VARIANT.
# 15x15 FRDM: 15x15-frdm-uuu (UUU) or trusty-15x15-frdm-dual (A/B + Trusty, production)
# 19x19 EVK:  evk-uuu or trusty-dual
case "${BOARD_VARIANT}" in
  15x15-frdm)
    IMX_UBOOT_FLASH_FEATURE="${IMX_UBOOT_FLASH_FEATURE:-15x15-frdm-uuu}"
    IMX_UBOOT_FLASH_FEATURE_AB="${IMX_UBOOT_FLASH_FEATURE_AB:-trusty-15x15-frdm-dual}"
    IMX_DTB_FEATURE="${IMX_DTB_FEATURE:-15x15-frdm}"
    IMX_DTB_FILE="${IMX_DTB_FILE:-imx95-15x15-frdm-os08a20-isp.dtb}"
    ;;
  19x19-evk)
    IMX_UBOOT_FLASH_FEATURE="${IMX_UBOOT_FLASH_FEATURE:-evk-uuu}"
    IMX_UBOOT_FLASH_FEATURE_AB="${IMX_UBOOT_FLASH_FEATURE_AB:-trusty-dual}"
    IMX_DTB_FEATURE="${IMX_DTB_FEATURE:-}"
    IMX_DTB_FILE="${IMX_DTB_FILE:-imx95-19x19-evk-os08a20-isp-adv7535.dtb}"
    ;;
  *)
    echo "Unknown BOARD_VARIANT=${BOARD_VARIANT} (use 15x15-frdm or 19x19-evk)" >&2
    exit 1
    ;;
esac

# Default tree: sibling of android-container (override with MY_ANDROID).
# imx_android_setup.sh may create imx-android-16.0.0_1.2.0/ — point MY_ANDROID there if needed.
# NXP imx_android_setup.sh creates the repo tree under android_build/ inside the extracted bundle.
DEFAULT_ANDROID_ROOT="${CONTAINER_ROOT}/downloads/extracted-${RELEASE_ID}/imx-android-${RELEASE_ID}/android_build"
MY_ANDROID="${MY_ANDROID:-${DEFAULT_ANDROID_ROOT}}"

# Kernel build pulls clang/rust/build-tools from outside the AOSP tree (User's Guide §3.2).
# NXP ships setup_android_kernel_prebuilts.sh; imx_android_setup.sh does NOT run it.
KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH:-/opt/android-kernel-prebuilts-6.12}"
KERNEL_PREBUILTS_SETUP="${MY_ANDROID}/device/nxp/common/tools/setup_android_kernel_prebuilts.sh"

# U-Boot/ATF/imx-sm/imx-oei need Arm GNU Toolchain 12.3 (User's Guide §3.2; no NXP setup script).
# Reference: device/nxp/common/dockerbuild/Dockerfile
GCC_TOOLCHAIN_ROOT="${GCC_TOOLCHAIN_ROOT:-/opt}"
GCC_TOOLCHAIN_AARCH64_DIR="${GCC_TOOLCHAIN_AARCH64_DIR:-arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu}"
GCC_TOOLCHAIN_AARCH32_DIR="${GCC_TOOLCHAIN_AARCH32_DIR:-arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi}"
GCC_TOOLCHAIN_AARCH64_URL="https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/12.3.rel1/binrel/${GCC_TOOLCHAIN_AARCH64_DIR}.tar.xz"
GCC_TOOLCHAIN_AARCH32_URL="https://armkeil.blob.core.windows.net/developer/Files/downloads/gnu/12.3.rel1/binrel/${GCC_TOOLCHAIN_AARCH32_DIR}.tar.xz"
AARCH64_GCC_CROSS_COMPILE="${AARCH64_GCC_CROSS_COMPILE:-${GCC_TOOLCHAIN_ROOT}/${GCC_TOOLCHAIN_AARCH64_DIR}/bin/aarch64-none-linux-gnu-}"
AARCH32_GCC_CROSS_COMPILE="${AARCH32_GCC_CROSS_COMPILE:-${GCC_TOOLCHAIN_ROOT}/${GCC_TOOLCHAIN_AARCH32_DIR}/bin/arm-none-eabi-}"
ARMGCC_DIR="${ARMGCC_DIR:-${GCC_TOOLCHAIN_ROOT}/${GCC_TOOLCHAIN_AARCH32_DIR}}"

# NXP GA source bundle (portal); Android 16 uses .tar.gz not legacy .tar.bz2 AOSP drops.
TARBALL_DEFAULT="imx-android-16.0.0_1.2.0.tar.gz"
TARBALL_GLOB="imx-android-16.0.0_1.2.0*.tar.gz"
SETUP_SCRIPT_NAME="imx_android_setup.sh"

# Prebuilt EVK flash images (e.g. android-16.0.0_1.2.0_image_95evk.tar.gz) are optional.
# They are demo/reference flash bundles for the 95 EVK — NOT required for source builds.
# Only the imx-android-* source tarball (imx_android_setup.sh + repo manifest) is needed here.

is_source_imx_tarball() {
  local base
  base="$(basename "$1")"
  [[ "${base}" == imx-android-*.tar.gz ]] || [[ "${base}" == imx-android-*.tar.bz2 ]]
}

is_prebuilt_image_tarball() {
  local base
  base="$(basename "$1")"
  [[ "${base}" == *image* ]] && [[ "${base}" == android-* ]] || [[ "${base}" == *_image_*.tar.* ]]
}

find_default_source_tarball() {
  local d
  for d in "${CONTAINER_ROOT}/downloads" "${HOME}/Downloads"; do
    [[ -d "${d}" ]] || continue
    local f
    for f in "${d}"/${TARBALL_GLOB}; do
      [[ -f "${f}" ]] || continue
      if is_source_imx_tarball "${f}"; then
        echo "${f}"
        return 0
      fi
    done
  done
  return 1
}

usage() {
  cat <<EOF
Usage: $(basename "$0") <command>

Commands:
  check       Host disk/RAM/tools check
  install-repo  Install repo to ~/bin (if missing)
  from-tarball <path>  Extract NXP bundle and run imx_android_setup.sh
  init        repo init only (requires empty MY_ANDROID)
  sync        repo sync (long; logs to logs/repo-sync-*.log)
  lunch       source envsetup + lunch ${LUNCH_TARGET}
  setup-kernel-prebuilts  One-time: clone kernel clang/rust/tools (sudo; large download)
  setup-gcc-toolchains  One-time: install Arm GNU 12.3 for U-Boot/ATF/imx-sm (sudo; idempotent)
  setup-host-deps       One-time: gcc toolchains + kernel prebuilts + print env exports
  print-env             Print export lines for required build environment
  build       ./imx-make.sh -j\$(nproc) (run after lunch in same shell: use build-shell)
  build-shell Print commands to run interactive build
  flash-help             UUU/fastboot flags for BOARD_VARIANT (default: 15x15-frdm)
  docker-help NXP container build notes

Environment:
  MY_ANDROID=${MY_ANDROID}  (Android tree root)
  BOARD_VARIANT=${BOARD_VARIANT}  (15x15-frdm | 19x19-evk)
  LUNCH_TARGET=${LUNCH_TARGET}
  MANIFEST_FILE=${MANIFEST_FILE}
  IMX_ANDROID_TARBALL=/path/to/${TARBALL_DEFAULT}

Manual download (EULA — cannot be automated):
  1. Sign in: https://www.nxp.com/
  2. Open i.MX Android 16 GA release page (product: i.MX 9 Series Applications Processors)
  3. Download bundle matching: ${RELEASE_ID} for Linux (often named like:
     ${TARBALL_DEFAULT} / ${TARBALL_GLOB} on the portal)
  4. Accept NXP Software License Agreement (EULA) on download
  5. Place tarball under, e.g.: ${CONTAINER_ROOT}/downloads/
  6. Run: $(basename "$0") from-tarball downloads/${TARBALL_DEFAULT}

Note: NXP image_95evk / android-*_image_*.tar.gz prebuilt flash bundles are OPTIONAL
  for the 95 EVK reference board — not for FRDM i.MX95 and not a substitute for
  this imx-android source tarball when building from source.

Alternative (repo only, after imx_android_setup or manual tool install):
  export MY_ANDROID=${MY_ANDROID}
  $(basename "$0") init && $(basename "$0") sync

Build (standard NXP flow after tree is ready):
  # One-time host setup (not done by imx_android_setup.sh):
  $(basename "$0") setup-host-deps
  eval "\$($(basename "$0") print-env)"
  cd "\${MY_ANDROID}"
  source build/envsetup.sh
  lunch ${LUNCH_TARGET}
  ./imx-make.sh -j\$(nproc)

Artifacts (when build completes):
  out/target/product/evk_95/

Board variant (default ${BOARD_VARIANT}):
  export BOARD_VARIANT=15x15-frdm   # i.MX95 15×15 FRDM (this project)
  export BOARD_VARIANT=19x19-evk    # 19×19 EVK reference

EOF
}

flash_help() {
  local img_dir="${MY_ANDROID}/out/target/product/evk_95"
  cat <<EOF
=== Flash: BOARD_VARIANT=${BOARD_VARIANT} (${IMX_DTB_FILE}) ===

Lunch / product (unchanged for all i.MX95 EVK/FRDM variants):
  lunch ${LUNCH_TARGET}

Build output directory (same for 15×15 FRDM and 19×19 EVK):
  out/target/product/evk_95/

Key artifacts for ${BOARD_VARIANT}:
  U-Boot (UUU):     u-boot-imx95-${IMX_UBOOT_FLASH_FEATURE}.imx  (also copied to u-boot.imx last in build)
  U-Boot (A/B):     bootloader-imx95-${IMX_UBOOT_FLASH_FEATURE_AB}.img
  DTB in vendor_boot: ${IMX_DTB_FILE}  (select via U-Boot fdt_name=${IMX_DTB_FEATURE})

evk_95 uses TARGET_INCLUDE_DTB_TO_VENDOR_BOOT=true — do NOT pass -d to uuu (DTBs are in vendor_boot).
U-Boot default FDT for imx95_15x15_frdm_android_* is imx95-15x15-frdm (see uboot imx_android_dt_mapping.h).

UUU (from android tree, images in out/target/product/evk_95/):
  cd device/nxp/common/tools
  sudo ./uuu_imx_android_flash.sh -f ${IMX_SOC_FLASH} \\
    -u ${IMX_UBOOT_FLASH_FEATURE} \\
    -D ${img_dir} -t emmc -e

A/B + Trusty production flash (dual bootloader slots):
  sudo ./uuu_imx_android_flash.sh -f ${IMX_SOC_FLASH} \\
    -u ${IMX_UBOOT_FLASH_FEATURE_AB} \\
    -D ${img_dir} -t emmc -e

Dual OS08A20 camera FRDM DTB variant: imx95-15x15-frdm-dual-os08a20-isp.dtb
  (set U-Boot fdt_name=imx95-15x15-frdm-dual-os08a20 or fastboot oem set-fdt-name=...)

19×19 EVK reference:
  export BOARD_VARIANT=19x19-evk
  $(basename "$0") flash-help

Note: SharedBoardConfig sets BOARD_OTA_BOOTLOADERIMAGE=bootloader-imx95-trusty-dual.img (19×19).
For FRDM use -u ${IMX_UBOOT_FLASH_FEATURE_AB}, not the default bootloader.img symlink target.

EOF
}

require_cmd() {
  local c="$1"
  command -v "$c" >/dev/null 2>&1 || { echo "Missing required command: $c" >&2; exit 1; }
}

ensure_kernel_prebuilts() {
  export KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH:-/opt/android-kernel-prebuilts-6.12}"
  if [[ -d "${KERNEL_PREBUILTS_PATH}/kernel-build-tools/linux-x86/bin" ]]; then
    return 0
  fi
  echo "KERNEL_PREBUILTS_PATH is missing or incomplete: ${KERNEL_PREBUILTS_PATH}" >&2
  echo "NXP kernel.mk needs external clang/rust/kernel-build-tools (not in the GA tarball)." >&2
  echo "Run once (sudo; clones from android.googlesource.com):" >&2
  echo "  $(basename "$0") setup-kernel-prebuilts" >&2
  echo "Then export and rebuild:" >&2
  echo "  export KERNEL_PREBUILTS_PATH=${KERNEL_PREBUILTS_PATH}" >&2
  exit 1
}

export_gcc_toolchain_env() {
  export GCC_TOOLCHAIN_ROOT="${GCC_TOOLCHAIN_ROOT:-/opt}"
  export GCC_TOOLCHAIN_AARCH64_DIR="${GCC_TOOLCHAIN_AARCH64_DIR:-arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu}"
  export GCC_TOOLCHAIN_AARCH32_DIR="${GCC_TOOLCHAIN_AARCH32_DIR:-arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi}"
  export AARCH64_GCC_CROSS_COMPILE="${AARCH64_GCC_CROSS_COMPILE:-${GCC_TOOLCHAIN_ROOT}/${GCC_TOOLCHAIN_AARCH64_DIR}/bin/aarch64-none-linux-gnu-}"
  export AARCH32_GCC_CROSS_COMPILE="${AARCH32_GCC_CROSS_COMPILE:-${GCC_TOOLCHAIN_ROOT}/${GCC_TOOLCHAIN_AARCH32_DIR}/bin/arm-none-eabi-}"
  export ARMGCC_DIR="${ARMGCC_DIR:-${GCC_TOOLCHAIN_ROOT}/${GCC_TOOLCHAIN_AARCH32_DIR}}"
}

export_host_build_env() {
  export KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH:-/opt/android-kernel-prebuilts-6.12}"
  export_gcc_toolchain_env
}

print_env_exports() {
  export_host_build_env
  cat <<EOF
export MY_ANDROID="${MY_ANDROID}"
export BOARD_VARIANT="${BOARD_VARIANT}"
export LUNCH_TARGET="${LUNCH_TARGET}"
export KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH}"
export AARCH64_GCC_CROSS_COMPILE="${AARCH64_GCC_CROSS_COMPILE}"
export AARCH32_GCC_CROSS_COMPILE="${AARCH32_GCC_CROSS_COMPILE}"
export ARMGCC_DIR="${ARMGCC_DIR}"
EOF
}

ensure_gcc_toolchain() {
  export_gcc_toolchain_env
  local aarch64_gcc="${AARCH64_GCC_CROSS_COMPILE}gcc"
  local aarch32_gcc="${AARCH32_GCC_CROSS_COMPILE}gcc"
  if [[ -x "${aarch64_gcc}" && -x "${aarch32_gcc}" ]]; then
    return 0
  fi
  echo "Arm GNU cross toolchains are missing or incomplete." >&2
  echo "  expected: ${aarch64_gcc}" >&2
  echo "  expected: ${aarch32_gcc}" >&2
  echo "U-Boot/ATF/imx-sm need Arm GNU Toolchain 12.3 (User's Guide §3.2; not apt gcc-aarch64-linux-gnu)." >&2
  echo "Run once:" >&2
  echo "  $(basename "$0") setup-gcc-toolchains" >&2
  echo "Then export and rebuild:" >&2
  echo "  export AARCH64_GCC_CROSS_COMPILE=${AARCH64_GCC_CROSS_COMPILE}" >&2
  echo "  export AARCH32_GCC_CROSS_COMPILE=${AARCH32_GCC_CROSS_COMPILE}" >&2
  echo "  export ARMGCC_DIR=${ARMGCC_DIR}" >&2
  exit 1
}

install_gcc_toolchain() {
  local dest="${GCC_TOOLCHAIN_ROOT:-/opt}"
  local aarch64_dir="${GCC_TOOLCHAIN_AARCH64_DIR:-arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu}"
  local aarch32_dir="${GCC_TOOLCHAIN_AARCH32_DIR:-arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi}"
  require_cmd curl
  require_cmd tar
  mkdir -p "${dest}"
  if [[ ! -x "${dest}/${aarch64_dir}/bin/aarch64-none-linux-gnu-gcc" ]]; then
    echo "Downloading ${aarch64_dir}.tar.xz ..."
    curl -fsSL -o "/tmp/${aarch64_dir}.tar.xz" "${GCC_TOOLCHAIN_AARCH64_URL}"
    tar -xJf "/tmp/${aarch64_dir}.tar.xz" -C "${dest}"
    rm -f "/tmp/${aarch64_dir}.tar.xz"
  else
    echo "Already installed: ${dest}/${aarch64_dir}"
  fi
  if [[ ! -x "${dest}/${aarch32_dir}/bin/arm-none-eabi-gcc" ]]; then
    echo "Downloading ${aarch32_dir}.tar.xz ..."
    curl -fsSL -o "/tmp/${aarch32_dir}.tar.xz" "${GCC_TOOLCHAIN_AARCH32_URL}"
    tar -xJf "/tmp/${aarch32_dir}.tar.xz" -C "${dest}"
    rm -f "/tmp/${aarch32_dir}.tar.xz"
  else
    echo "Already installed: ${dest}/${aarch32_dir}"
  fi
}

cmd_setup_kernel_prebuilts() {
  [[ -f "${KERNEL_PREBUILTS_SETUP}" ]] || {
    echo "Setup script not found: ${KERNEL_PREBUILTS_SETUP}" >&2
    echo "Complete repo sync first (MY_ANDROID=${MY_ANDROID})." >&2
    exit 1
  }
  require_cmd git
  require_cmd sudo
  echo "=== Kernel prebuilts (one-time host install) ==="
  echo "Target: ${KERNEL_PREBUILTS_PATH}"
  echo "Script: ${KERNEL_PREBUILTS_SETUP}"
  echo "This downloads pinned clang/rust/build-tools from android.googlesource.com."
  sudo bash "${KERNEL_PREBUILTS_SETUP}"
  export KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH:-/opt/android-kernel-prebuilts-6.12}"
  ensure_kernel_prebuilts
  echo "Export for current shell (also added to /etc/profile by NXP script):"
  echo "  export KERNEL_PREBUILTS_PATH=${KERNEL_PREBUILTS_PATH}"
}

cmd_setup_gcc_toolchains() {
  if [[ "${EUID}" -ne 0 ]]; then
    require_cmd sudo
    sudo env \
      GCC_TOOLCHAIN_ROOT="${GCC_TOOLCHAIN_ROOT:-/opt}" \
      GCC_TOOLCHAIN_AARCH64_DIR="${GCC_TOOLCHAIN_AARCH64_DIR}" \
      GCC_TOOLCHAIN_AARCH32_DIR="${GCC_TOOLCHAIN_AARCH32_DIR}" \
      "${BASH_SOURCE[0]}" _install_gcc_toolchain_internal
    export_gcc_toolchain_env
    ensure_gcc_toolchain
    echo "Export for current shell:"
    echo "  export AARCH64_GCC_CROSS_COMPILE=${AARCH64_GCC_CROSS_COMPILE}"
    echo "  export AARCH32_GCC_CROSS_COMPILE=${AARCH32_GCC_CROSS_COMPILE}"
    echo "  export ARMGCC_DIR=${ARMGCC_DIR}"
    return
  fi
  echo "=== Arm GNU Toolchain 12.3 (one-time host install) ==="
  echo "Target: ${GCC_TOOLCHAIN_ROOT:-/opt}"
  install_gcc_toolchain
  export_gcc_toolchain_env
  ensure_gcc_toolchain
  echo "Export for current shell:"
  echo "  export AARCH64_GCC_CROSS_COMPILE=${AARCH64_GCC_CROSS_COMPILE}"
  echo "  export AARCH32_GCC_CROSS_COMPILE=${AARCH32_GCC_CROSS_COMPILE}"
  echo "  export ARMGCC_DIR=${ARMGCC_DIR}"
}

cmd_setup_gcc_toolchain() {
  cmd_setup_gcc_toolchains "$@"
}

cmd_setup_host_deps() {
  echo "=== One-time host dependencies (kernel prebuilts + Arm GNU toolchains) ==="
  cmd_setup_gcc_toolchains
  if [[ -f "${KERNEL_PREBUILTS_SETUP}" ]]; then
    cmd_setup_kernel_prebuilts
  else
    echo "Skipping kernel prebuilts: ${KERNEL_PREBUILTS_SETUP} not found." >&2
    echo "Complete repo sync first, then re-run: $(basename "$0") setup-kernel-prebuilts" >&2
  fi
  echo ""
  echo "=== Required build environment (add to shell profile or CI job) ==="
  print_env_exports
}

cmd_print_env() {
  print_env_exports
}

cmd_install_gcc_toolchain_internal() {
  echo "=== Arm GNU Toolchain 12.3 (one-time host install) ==="
  echo "Target: ${GCC_TOOLCHAIN_ROOT:-/opt}"
  install_gcc_toolchain
}


check_apt_package() {
  local pkg="$1"
  if dpkg-query -W -f='${Status}' "${pkg}" 2>/dev/null | grep -qx 'install ok installed'; then
    echo "  OK apt:${pkg}"
  else
    echo "  MISSING apt:${pkg} (sudo apt install -y ${pkg})"
  fi
}

check_libgnutls28_dev() {
  if command -v pkg-config >/dev/null 2>&1 && pkg-config --exists gnutls 2>/dev/null; then
    echo "  OK libgnutls28-dev (pkg-config gnutls)"
  elif dpkg-query -W -f='${Status}' libgnutls28-dev 2>/dev/null | grep -qx 'install ok installed'; then
    echo "  OK libgnutls28-dev (dpkg)"
  else
    echo "  MISSING libgnutls28-dev (sudo apt install -y libgnutls28-dev)"
  fi
}

# Matches device/nxp/common/dockerbuild/Dockerfile apt install (build/U-Boot deps).
NXP_DOCKER_APT_PACKAGES=(
  uuid-dev zlib1g-dev liblz-dev liblzo2-dev lzop u-boot-tools mtd-utils
  android-sdk-libsparse-utils device-tree-compiler gdisk m4 bison flex
  libssl-dev gcc-multilib swig liblz4-tool libdw-dev dwarves bc cpio lz4
  ninja-build clang build-essential libncurses5 xxd unzip
)

cmd_check() {
  echo "=== Host check (NXP recommends ~450GB disk, 64GB RAM) ==="
  df -h / "${MY_ANDROID%/*}" 2>/dev/null || df -h /
  free -h
  echo "MY_ANDROID=${MY_ANDROID}"
  echo "BOARD_VARIANT=${BOARD_VARIANT} (lunch=${LUNCH_TARGET}, DTB=${IMX_DTB_FILE})"
  if [[ -d "${MY_ANDROID}/.repo" ]]; then
    echo "Existing repo tree: YES (${MY_ANDROID})"
  else
    echo "Existing repo tree: NO"
  fi
  echo "Tools:"
  for c in git python3 java gcc make curl bzip2 tar; do
    if command -v "$c" >/dev/null; then echo "  OK $c"; else echo "  MISSING $c"; fi
  done
  if command -v repo >/dev/null; then echo "  OK repo"; else echo "  MISSING repo (run: $0 install-repo)"; fi
  if command -v docker >/dev/null; then echo "  OK docker"; else echo "  MISSING docker (optional)"; fi
  echo "Apt packages (NXP Dockerfile; sudo apt install if MISSING):"
  check_libgnutls28_dev
  local pkg
  for pkg in "${NXP_DOCKER_APT_PACKAGES[@]}"; do
    check_apt_package "${pkg}"
  done
  export KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH:-/opt/android-kernel-prebuilts-6.12}"
  if [[ -d "${KERNEL_PREBUILTS_PATH}/kernel-build-tools/linux-x86/bin" ]]; then
    echo "Kernel prebuilts: OK (${KERNEL_PREBUILTS_PATH})"
  else
    echo "Kernel prebuilts: MISSING — run: $(basename "$0") setup-kernel-prebuilts"
  fi
  export_gcc_toolchain_env
  if [[ -x "${AARCH64_GCC_CROSS_COMPILE}gcc" && -x "${AARCH32_GCC_CROSS_COMPILE}gcc" ]]; then
    echo "GCC toolchains: OK"
    echo "  AARCH64_GCC_CROSS_COMPILE=${AARCH64_GCC_CROSS_COMPILE}"
    echo "  AARCH32_GCC_CROSS_COMPILE=${AARCH32_GCC_CROSS_COMPILE}"
    echo "  ARMGCC_DIR=${ARMGCC_DIR}"
  else
    echo "GCC toolchains: MISSING — run: $(basename "$0") setup-gcc-toolchains"
  fi
  echo "Build env (copy or: $(basename "$0") print-env):"
  print_env_exports | sed 's/^/  /'
}

cmd_install_repo() {
  mkdir -p "${HOME}/bin"
  curl -sL https://storage.googleapis.com/git-repo-downloads/repo -o "${HOME}/bin/repo"
  chmod a+x "${HOME}/bin/repo"
  export PATH="${HOME}/bin:${PATH}"
  echo "Installed repo to ${HOME}/bin/repo"
  repo version || true
}

find_setup_script() {
  local root="$1"
  if [[ -f "${root}/${SETUP_SCRIPT_NAME}" ]]; then
    echo "${root}/${SETUP_SCRIPT_NAME}"
    return 0
  fi
  local found
  found="$(find "${root}" -maxdepth 3 -name "${SETUP_SCRIPT_NAME}" 2>/dev/null | head -1)"
  [[ -n "${found}" ]] && echo "${found}"
}

cmd_from_tarball() {
  local tb="${1:-${IMX_ANDROID_TARBALL:-}}"
  if [[ -z "${tb}" ]]; then
    tb="$(find_default_source_tarball || true)"
  fi
  if [[ -z "${tb}" || ! -f "${tb}" ]]; then
    echo "Source tarball not found (${TARBALL_DEFAULT}). Set path or IMX_ANDROID_TARBALL." >&2
    echo "Optional EVK prebuilts (android-*_image_95evk*.tar.gz) are not used by this script." >&2
    usage
    exit 1
  fi
  if is_prebuilt_image_tarball "${tb}"; then
    echo "Refusing prebuilt image tarball: $(basename "${tb}")" >&2
    echo "Use source bundle ${TARBALL_DEFAULT} only (demo/EVK flash images are optional)." >&2
    exit 1
  fi
  if ! is_source_imx_tarball "${tb}"; then
    echo "Warning: $(basename "${tb}") does not match imx-android-*.tar.gz; continuing anyway." >&2
  fi
  require_cmd tar
  local extract_dir="${CONTAINER_ROOT}/downloads/extracted-${RELEASE_ID}"
  mkdir -p "${extract_dir}"
  echo "Extracting ${tb} -> ${extract_dir} (this takes a while)..."
  case "${tb}" in
    *.tar.gz|*.tgz) tar -xzf "${tb}" -C "${extract_dir}" ;;
    *.tar.bz2|*.tbz2) require_cmd bzip2; tar -xjf "${tb}" -C "${extract_dir}" ;;
    *) tar -xf "${tb}" -C "${extract_dir}" ;;
  esac
  local setup
  setup="$(find_setup_script "${extract_dir}")" || true
  if [[ -z "${setup}" ]]; then
    echo "Could not find ${SETUP_SCRIPT_NAME} under ${extract_dir}" >&2
    exit 1
  fi
  local setup_dir
  setup_dir="$(dirname "${setup}")"
  local android_build="${setup_dir}/android_build"
  echo "Bundle extracted. NXP tree path (set MY_ANDROID): ${android_build}"
  echo "Run NXP setup once (repo init + vendor copy), then repo sync:"
  echo "  export MY_ANDROID="${android_build}""
  echo "  cd ${setup_dir} && ./${SETUP_SCRIPT_NAME}"
  echo "  cd "\${MY_ANDROID}" && repo sync -j\$(nproc) -c"
  echo "Or use: $(basename "$0") init && $(basename "$0") sync  (with MY_ANDROID exported as above)"
}

cmd_init() {
  require_cmd git
  command -v repo >/dev/null || cmd_install_repo
  export PATH="${HOME}/bin:${PATH}"
  mkdir -p "${MY_ANDROID}"
  if [[ -d "${MY_ANDROID}/.repo" ]]; then
    echo "Repo already initialized at ${MY_ANDROID}"
    exit 0
  fi
  echo "repo init -u ${MANIFEST_URL} -b ${MANIFEST_BRANCH} -m ${MANIFEST_FILE}"
  echo "  (in ${MY_ANDROID})"
  # Use default repo tool (googlesource); nxp-imx/git-repo over HTTPS/SSH often needs credentials.
  (
    cd "${MY_ANDROID}"
    repo init -u "${MANIFEST_URL}" -b "${MANIFEST_BRANCH}" -m "${MANIFEST_FILE}"
  )
}

cmd_sync() {
  command -v repo >/dev/null || cmd_install_repo
  export PATH="${HOME}/bin:${PATH}"
  [[ -d "${MY_ANDROID}/.repo" ]] || { echo "Run init first or from-tarball"; exit 1; }
  local log="${LOG_DIR}/repo-sync-$(date +%Y%m%d-%H%M%S).log"
  echo "Starting repo sync in background; log: ${log}"
  echo "  cd ${MY_ANDROID} && repo sync -j\$(nproc) -c"
  (
    cd "${MY_ANDROID}"
    repo sync -j"$(nproc)" -c
  ) >>"${log}" 2>&1 &
  echo $! > "${LOG_DIR}/repo-sync.pid"
  echo "PID: $(cat "${LOG_DIR}/repo-sync.pid")"
}

cmd_lunch() {
  [[ -f "${MY_ANDROID}/build/envsetup.sh" ]] || { echo "No tree at ${MY_ANDROID}"; exit 1; }
  export_host_build_env
  ensure_kernel_prebuilts
  ensure_gcc_toolchain
  # shellcheck disable=SC1091
  set +u
  cd "${MY_ANDROID}"
  source build/envsetup.sh
  lunch "${LUNCH_TARGET}"
  set -u
  echo "Lunch OK. Run build in this shell: ./imx-make.sh -j\$(nproc)"
}

cmd_build() {
  [[ -f "${MY_ANDROID}/build/envsetup.sh" ]] || { echo "No tree at ${MY_ANDROID}"; exit 1; }
  export_host_build_env
  ensure_kernel_prebuilts
  ensure_gcc_toolchain
  local log="${LOG_DIR}/imx-make-$(date +%Y%m%d-%H%M%S).log"
  set +u
  cd "${MY_ANDROID}"
  source build/envsetup.sh
  lunch "${LUNCH_TARGET}"
  echo "Building; log: ${log} (hours on first build)"
  ./imx-make.sh -j"$(nproc)" 2>&1 | tee "${log}"
  set -u
}

cmd_build_shell() {
  export_host_build_env
  cat <<EOF
# One-time (if host deps not installed):
# $(basename "$0") setup-host-deps
# eval "\$($(basename "$0") print-env)"

# Board: 15x15 FRDM (default) or 19x19 EVK — same lunch, flash with matching -u (see flash-help)
export BOARD_VARIANT="${BOARD_VARIANT}"
export MY_ANDROID="${MY_ANDROID}"
export KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH}"
export AARCH64_GCC_CROSS_COMPILE="${AARCH64_GCC_CROSS_COMPILE}"
export AARCH32_GCC_CROSS_COMPILE="${AARCH32_GCC_CROSS_COMPILE}"
export ARMGCC_DIR="${ARMGCC_DIR}"
cd "\${MY_ANDROID}"
source build/envsetup.sh
lunch ${LUNCH_TARGET}
./imx-make.sh -j\$(nproc)

# Background build with log:
nohup env \\
  MY_ANDROID="${MY_ANDROID}" \\
  KERNEL_PREBUILTS_PATH="${KERNEL_PREBUILTS_PATH}" \\
  AARCH64_GCC_CROSS_COMPILE="${AARCH64_GCC_CROSS_COMPILE}" \\
  AARCH32_GCC_CROSS_COMPILE="${AARCH32_GCC_CROSS_COMPILE}" \\
  ARMGCC_DIR="${ARMGCC_DIR}" \\
  bash -c 'cd "${MY_ANDROID}" && source build/envsetup.sh && lunch ${LUNCH_TARGET} && ./imx-make.sh -j\$(nproc)' \\
  > "${LOG_DIR}/imx-make-\$(date +%Y%m%d-%H%M%S).log" 2>&1 &
echo \$! > "${LOG_DIR}/imx-make.pid"
EOF
}

cmd_docker_help() {
  cat <<EOF
NXP documents Docker-based Android builds in the i.MX Android User's Guide (release PDF
inside the downloaded android-16.0.0_1.2.0 / imx-android-16.0.0_1.2.0 bundle, docs/ section).

Reference Dockerfile (matches this script's host deps):
  \${MY_ANDROID}/device/nxp/common/dockerbuild/Dockerfile

Pinned versions in that Dockerfile:
  - Ubuntu 22.04 base + apt packages (git, curl, bison, flex, ninja-build, ...)
  - Arm GNU 12.3: arm-gnu-toolchain-12.3.rel1-x86_64-aarch64-none-linux-gnu
  - Arm GNU 12.3: arm-gnu-toolchain-12.3.rel1-x86_64-arm-none-eabi
  - KERNEL_PREBUILTS_PATH=/opt/android-kernel-prebuilts-6.12 (clang, rust, build-tools, clang-tools)

Typical pattern after extracting the GA package:
  - Build image from device/nxp/common/dockerbuild/Dockerfile
  - Mount MY_ANDROID as a volume with enough disk (>450GB free on host)
  - Export the same env vars as: $(basename "$0") print-env
  - Run imx-make.sh inside the container with lunch ${LUNCH_TARGET}

Host alternative (no Docker): $(basename "$0") setup-host-deps

EOF
}

main() {
  local cmd="${1:-check}"
  shift || true
  case "${cmd}" in
    check) cmd_check ;;
    install-repo) cmd_install_repo ;;
    from-tarball) cmd_from_tarball "$@" ;;
    init) cmd_init ;;
    sync) cmd_sync ;;
    lunch) cmd_lunch ;;
    setup-kernel-prebuilts) cmd_setup_kernel_prebuilts ;;
    setup-gcc-toolchains|setup-gcc-toolchain) cmd_setup_gcc_toolchains ;;
    setup-host-deps) cmd_setup_host_deps ;;
    print-env) cmd_print_env ;;
    _install_gcc_toolchain_internal) cmd_install_gcc_toolchain_internal ;;
    build) cmd_build ;;
    build-shell) cmd_build_shell ;;
    flash-help) flash_help ;;
    docker-help) cmd_docker_help ;;
    -h|--help|help) usage ;;
    *) echo "Unknown command: ${cmd}" >&2; usage; exit 1 ;;
  esac
}

main "$@"
