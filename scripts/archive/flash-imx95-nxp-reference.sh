#!/usr/bin/env bash
# Flash NXP Linux LF reference image to FRDM-IMX95 (15x15 LPDDR4x) via uuu.auto.
#
# Uses LF_v6.18.2 bundle: uuu.auto-imx95-15x15-lpddr4x-frdm
#   SDPS + FB only (imx-boot-*-flash_all for SDPS and FB bootloader; imx-image-full-imx95evk.wic)
#   NO SDPV + u-boot-mfgtool.itb — that imx8-style path fails on imx95 SPL.
#
# Bench validation only — not Foundries LmP. For LmP use flash-imx95-foundries.sh.
#
# Usage:
#   ./scripts/flash-imx95-nxp-reference.sh [BUNDLE_DIR]
#   ./scripts/flash-imx95-nxp-reference.sh --timeout 1800 ~/Downloads/LF_v6.18.2-1.0.0_images_IMX95
#
# Default bundle: ~/Downloads/LF_v6.18.2-1.0.0_images_IMX95
# Prerequisites: SW1 Serial Download (0,1), USB J3, stop ModemManager, passwordless sudo for uuu
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: flash-imx95-nxp-reference.sh [--timeout SEC] [BUNDLE_DIR]

  --timeout SEC   Max seconds per uuu invocation (default: 10; production: 1800)

  BUNDLE_DIR  NXP LF images directory (default: ~/Downloads/LF_v6.18.2-1.0.0_images_IMX95)

Runs: sudo uuu uuu.auto-imx95-15x15-lpddr4x-frdm

FRDM SW1: Serial Download 0,1 for flash; eMMC boot 1,0 after.
See docs/imx95-foundries-emmc.md and NXP GS-FRDM-IMX95.
EOF
}

UUU_TIMEOUT="${UUU_TIMEOUT:-10}"
UUU_AUTO="uuu.auto-imx95-15x15-lpddr4x-frdm"
DEFAULT_BUNDLE="${HOME}/Downloads/LF_v6.18.2-1.0.0_images_IMX95"
BUNDLE_DIR=""
MM_WAS_ACTIVE=0

while [[ $# -gt 0 ]]; do
    case "$1" in
        --timeout)
            [[ $# -ge 2 ]] || die "--timeout requires seconds"
            UUU_TIMEOUT="$2"
            shift 2
            ;;
        -h|--help) usage; exit 0 ;;
        -*) die "Unknown option: $1 (try --help)" ;;
        *)
            BUNDLE_DIR="$1"
            shift
            ;;
    esac
done

BUNDLE_DIR="${BUNDLE_DIR:-${DEFAULT_BUNDLE}}"

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

stop_modemmanager() {
    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        MM_WAS_ACTIVE=1
        log "Stopping ModemManager temporarily (ttyACM/uuu interference) ..."
        if ! env -u TERMINFO sudo -n /usr/bin/systemctl stop ModemManager 2>/dev/null \
            && ! env -u TERMINFO sudo -n /bin/systemctl stop ModemManager 2>/dev/null; then
            sudo systemctl stop ModemManager || warn "Could not stop ModemManager; uuu may fail with LIBUSB_ERROR_IO"
        fi
    fi
}

restore_modemmanager() {
    if [[ "${MM_WAS_ACTIVE}" -eq 1 ]]; then
        log "Restarting ModemManager ..."
        env -u TERMINFO sudo -n /usr/bin/systemctl start ModemManager 2>/dev/null \
            || env -u TERMINFO sudo -n /bin/systemctl start ModemManager 2>/dev/null \
            || sudo systemctl start ModemManager 2>/dev/null \
            || true
    fi
}

uuu_sudo_nopasswd() {
    local uuu_bin="$1" out
    [[ "$(id -u)" -eq 0 ]] && return 0
    out="$(env -u TERMINFO sudo -n "${uuu_bin}" -V 2>&1)" || true
    if [[ "${out}" == *"a password is required"* ]] || [[ "${out}" == *"password is required"* ]]; then
        return 1
    fi
    [[ "${out}" == *"Universal Update Utility"* ]] || [[ "${out}" == *"uuu ("* ]]
}

resolve_uuu_bin() {
    local bin=""
    if [[ -n "${UUU_BIN:-}" ]]; then
        bin="${UUU_BIN}"
    elif [[ -x "${BUNDLE_DIR}/uuu" ]]; then
        bin="${BUNDLE_DIR}/uuu"
    else
        bin="$(command -v uuu 2>/dev/null || true)"
        [[ -n "${bin}" ]] || bin="uuu"
    fi
    if [[ -x "${bin}" ]]; then
        readlink -f "${bin}"
    else
        printf '%s\n' "${bin}"
    fi
}

validate_bundle() {
    [[ -d "${BUNDLE_DIR}" ]] || die "NXP bundle directory not found: ${BUNDLE_DIR}

Download LF_v6.18.2-1.0.0_images_IMX95 from NXP and extract to ~/Downloads/, or pass BUNDLE_DIR."

    [[ -f "${BUNDLE_DIR}/${UUU_AUTO}" ]] \
        || die "Missing ${UUU_AUTO} in ${BUNDLE_DIR}"

    local boot_wic="imx-boot-imx95-15x15-lpddr4x-frdm-sd.bin-flash_all"
    local wic="imx-image-full-imx95evk.wic"
    [[ -f "${BUNDLE_DIR}/${boot_wic}" ]] \
        || die "Missing ${boot_wic} in ${BUNDLE_DIR}"
    [[ -f "${BUNDLE_DIR}/${wic}" ]] \
        || die "Missing ${wic} in ${BUNDLE_DIR}"

    log "Bundle OK: ${BUNDLE_DIR}"
    log "  SDPS/FB boot: ${boot_wic}"
    log "  WIC: ${wic}"
}

check_usb() {
    log "USB devices (NXP 1fc9):"
    if lsusb 2>/dev/null | grep -qiE '1fc9:015[0-9a-f]|1fc9:0153'; then
        lsusb 2>/dev/null | grep -iE '1fc9:015[0-9a-f]|1fc9:0153' || true
    else
        warn "No NXP programming USB (1fc9) detected."
        warn "Set FRDM SW1 to Serial Download (BOOT_MODE1=0, BOOT_MODE0=1), connect USB J3, power on."
    fi
}

run_uuu() {
    local uuu_bin log_file rc
    uuu_bin="$(resolve_uuu_bin)"
    need_cmd timeout
    need_cmd "${uuu_bin}"
    log_file="$(mktemp "${TMPDIR:-/tmp}/uuu-nxp-ref.XXXXXX")"
    trap 'rm -f "${log_file}"; restore_modemmanager' EXIT

    log "Using uuu: ${uuu_bin} (timeout ${UUU_TIMEOUT}s, -pp 100)"
    log "Running from ${BUNDLE_DIR}: ${UUU_AUTO}"
    stop_modemmanager
    check_usb

    if [[ "$(id -u)" -eq 0 ]]; then
        (cd "${BUNDLE_DIR}" && timeout "${UUU_TIMEOUT}" "${uuu_bin}" -pp 100 "${UUU_AUTO}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    elif uuu_sudo_nopasswd "${uuu_bin}"; then
        (cd "${BUNDLE_DIR}" && timeout "${UUU_TIMEOUT}" env -u TERMINFO sudo -n "${uuu_bin}" -pp 100 "${UUU_AUTO}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    else
        log "sudo password required for uuu (USB device access)."
        log "One-time: ./scripts/install-flash-sudoers.sh  (see docs/imx95-foundries-emmc.md)"
        (cd "${BUNDLE_DIR}" && timeout "${UUU_TIMEOUT}" env -u TERMINFO sudo "${uuu_bin}" -pp 100 "${UUU_AUTO}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    fi

    if [[ "${rc}" -eq 124 ]]; then
        die "uuu timed out after ${UUU_TIMEOUT}s (use --timeout 1800 for full WIC flash)"
    fi

    if grep -qE 'Success[[:space:]]+[1-9]|Done!' "${log_file}" 2>/dev/null; then
        log "NXP reference flash completed."
        return 0
    fi

    die "uuu failed (exit ${rc}). Last output:
$(tail -40 "${log_file}" 2>/dev/null || true)"
}

main() {
    validate_bundle
    run_uuu
    log "Done. Power off, set SW1 to eMMC boot (1,0), re-power."
    log "NXP Linux demo — serial SPL @ 921600 ttyACM0; Linux console @ 115200."
}

main "$@"
