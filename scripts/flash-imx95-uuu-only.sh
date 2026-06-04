#!/usr/bin/env bash
# Minimal FRDM-IMX95 Foundries flash: one uuu script, no USB heuristics, no serial capture.
#
#   ./scripts/flash-imx95-uuu-only.sh check 2735
#   ./scripts/flash-imx95-uuu-only.sh prep 2735
#   ./scripts/flash-imx95-uuu-only.sh run 2735              # uncompressed .wic (default on imx95)
#   ./scripts/flash-imx95-uuu-only.sh run-bootloader 2745   # imx-boot only (keep WIC/rootfs)
#   ./scripts/flash-imx95-uuu-only.sh run 2735 --wic-compressed   # .wic.gz (breaks GPT on FRDM)
#
# imx95: uuu/fastboot does NOT gunzip. Use full_image-nxp-boot-wic-uncompressed.uuu (see docs/lmp-frdm-workflow.md).
# Manual:
#   cd downloads/target-2735/flash-bundle
#   sudo -n uuu -pp 100 full_image-nxp-boot-wic-uncompressed.uuu
set -euo pipefail

# shellcheck source=flash-imx95-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)/flash-imx95-common.sh"
ROOT_DIR="${IMX95_REPO_ROOT}"
PREP_SCRIPT="${ROOT_DIR}/scripts/archive/flash-imx95-foundries.full.sh"
FACTORY="${FACTORY:-dynamic-devices}"
# Default: uncompressed — Foundries .wic.gz writes gzip magic to eMMC (no GPT) on imx95 fastboot.
WIC_MODE="${WIC_MODE:-uncompressed}"
UUU_SCRIPT_COMPRESSED="full_image-nxp-boot.uuu"
UUU_SCRIPT_UNCOMPRESSED="full_image-nxp-boot-wic-uncompressed.uuu"
UUU_SCRIPT="${UUU_SCRIPT_UNCOMPRESSED}"
UUU_BOOTLOADER_ONLY="bootloader-only.uuu"
NXP_FLASH_ALL="imx-boot-imx95-15x15-lpddr4x-frdm-sd.bin-flash_all"
PROD_BOOT="imx-boot-imx95-frdm-evk"
WIC_GZ="lmp-factory-image-imx95-frdm-evk.wic.gz"
WIC_IMG="lmp-factory-image-imx95-frdm-evk.wic"
NXP_BUNDLE_DEFAULT="${HOME}/Downloads/LF_v6.18.2-1.0.0_images_IMX95"

apply_wic_mode() {
    case "${WIC_MODE}" in
        uncompressed) UUU_SCRIPT="${UUU_SCRIPT_UNCOMPRESSED}" ;;
        compressed)   UUU_SCRIPT="${UUU_SCRIPT_COMPRESSED}" ;;
        *) die "WIC_MODE=${WIC_MODE} (use uncompressed or compressed)" ;;
    esac
}

parse_wic_flags() {
    while [[ $# -gt 0 ]]; do
        case "$1" in
            --wic-uncompressed) WIC_MODE="uncompressed"; shift ;;
            --wic-compressed)     WIC_MODE="compressed"; shift ;;
            *) break ;;
        esac
    done
    apply_wic_mode
    printf '%s\n' "$@"
}

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    sed -n '2,12p' "$0" | sed 's/^# \?//'
    exit "${1:-0}"
}

bundle_dir() {
    imx95_migrate_legacy_downloads "$1"
    imx95_flash_bundle_dir "$1"
}

cmd_prep() {
    local target="$1"
    [[ -x "${PREP_SCRIPT}" ]] || die "Missing ${PREP_SCRIPT}"
    exec "${PREP_SCRIPT}" --prepare-only --emmc "${target}" "${FACTORY}"
}

check_bundle() {
    local target="$1"
    local dir flash_all wic prod uuu
    dir="$(bundle_dir "${target}")"
    [[ -d "${dir}" ]] || die "Missing ${dir}. Run: $(basename "$0") prep ${target}"

    uuu="${dir}/${UUU_SCRIPT}"
    flash_all="${dir}/${NXP_FLASH_ALL}"
    wic="${dir}/${WIC_GZ}"
    wic_un="${dir}/${WIC_IMG}"
    prod="${dir}/${PROD_BOOT}"

    local ok=1
    [[ -f "${uuu}" ]] || { warn "Missing ${uuu}"; ok=0; }
    [[ -e "${flash_all}" ]] || { warn "Missing ${NXP_FLASH_ALL} (need NXP LF bundle; see prep)"; ok=0; }
    [[ -s "${wic}" ]] || { warn "Missing ${wic}"; ok=0; }
    [[ -s "${prod}" ]] || { warn "Missing ${prod}"; ok=0; }
    if [[ "${WIC_MODE}" == "uncompressed" ]] && [[ ! -s "${wic_un}" ]]; then
        warn "Missing ${WIC_IMG} — run: $(basename "$0") prep ${target} (or gunzip -k ${wic} in flash-bundle)"
        ok=0
    fi

    if [[ -L "${flash_all}" ]] && [[ ! -s "${flash_all}" ]]; then
        warn "flash_all symlink broken: ${flash_all}"
        ok=0
    fi

    if [[ "${ok}" -eq 0 ]]; then
        die "Bundle incomplete. Run: $(basename "$0") prep ${target}"
    fi

    log "Bundle OK: ${dir} (WIC_MODE=${WIC_MODE})"
    log "  ${UUU_SCRIPT}"
    log "  ${NXP_FLASH_ALL} -> $(readlink -f "${flash_all}" 2>/dev/null || readlink "${flash_all}" 2>/dev/null || echo '?')"
    log "  ${WIC_GZ} ($(stat -c%s "${wic}") bytes)"
    [[ -s "${wic_un}" ]] && log "  ${WIC_IMG} ($(stat -c%s "${wic_un}") bytes)"
    log "  ${PROD_BOOT} ($(stat -c%s "${prod}") bytes)"
    printf '\n'
    sed 's/^/  /' "${uuu}"
    printf '\n'
    log "Manual run (board SW1 0,1 Serial Download):"
    printf '  cd %s && sudo -n uuu -pp 100 %s\n' "${dir}" "${UUU_SCRIPT}"
    return 0
}

check_bundle_quiet() {
    check_bundle "$1" >/dev/null
}

check_bootloader_bundle() {
    local target="$1"
    local dir prod uuu
    dir="$(bundle_dir "${target}")"
    [[ -d "${dir}" ]] || die "Missing ${dir}. Run: $(basename "$0") prep ${target}"
    prod="${dir}/${PROD_BOOT}"
    uuu="${dir}/${UUU_BOOTLOADER_ONLY}"
    [[ -s "${prod}" ]] || die "Missing ${prod}. Run: $(basename "$0") prep ${target}"
    [[ -f "${uuu}" ]] || die "Missing ${uuu}. Re-run: $(basename "$0") prep ${target}"
    log "Bootloader-only bundle OK: ${dir}"
    log "  ${UUU_BOOTLOADER_ONLY} → ${PROD_BOOT} ($(stat -c%s "${prod}") bytes)"
    sed 's/^/  /' "${uuu}"
    printf '\n'
    log "Manual (SW1 0,1 Serial Download, board at fastboot 0152 or full_image first):"
    printf '  cd %s && sudo -n uuu -pp 100 %s\n' "${dir}" "${UUU_BOOTLOADER_ONLY}"
}

check_bootloader_bundle_quiet() {
    check_bootloader_bundle "$1" >/dev/null
}

run_uuu_script() {
    local target="$1" script_name="$2"
    local dir uuu_bin log_file
    dir="$(bundle_dir "${target}")"
    uuu_bin="$(command -v uuu 2>/dev/null || true)"
    [[ -n "${uuu_bin}" ]] || die "uuu not on PATH (apt install uuu)"

    if systemctl is-active --quiet ser2net 2>/dev/null; then
        log "Stopping ser2net ..."
        sudo -n systemctl stop ser2net || warn "Could not stop ser2net — close port 2000 / ttyACM0"
    fi

    log "Flashing target ${target} — uuu -pp 100 ${script_name}"
    log "Board: SW1 (0,1) Serial Download or fastboot, USB J3. Timeout 1800s."
    mkdir -p "${ROOT_DIR}/logs"
    log_file="${ROOT_DIR}/logs/uuu-flash-${target}-$(date +%Y%m%d-%H%M%S).log"
    log "Logging to ${log_file}"
    set +e
    (cd "${dir}" && timeout 1800 sudo -n "${uuu_bin}" -pp 100 "${script_name}" 2>&1 | tee "${log_file}")
    local rc=${PIPESTATUS[0]}
    set -e
    tail -5 "${log_file}" | sed 's/^/  /'

    if systemctl list-unit-files ser2net.service &>/dev/null; then
        sudo -n systemctl start ser2net 2>/dev/null || true
    fi

    if [[ "${rc}" -ne 0 ]]; then
        die "uuu failed (exit ${rc}) — see ${log_file}"
    fi
    if ! grep -qE 'Success 1' "${log_file}"; then
        die "uuu exit 0 but no Success 1 in ${log_file} — flash incomplete or failed"
    fi
    log "Flash OK (exit 0, Success 1). Set SW1 (1,0) eMMC boot, power-cycle, then: ./scripts/capture-frdm-serial.sh"
    return 0
}

cmd_run() {
    local target="$1"
    check_bundle_quiet "${target}"
    run_uuu_script "${target}" "${UUU_SCRIPT}"
}

cmd_run_bootloader() {
    local target="$1"
    check_bootloader_bundle_quiet "${target}"
    run_uuu_script "${target}" "${UUU_BOOTLOADER_ONLY}"
}

main() {
    apply_wic_mode
    local cmd="${1:-}"
    shift || true
    case "${cmd}" in
        check|run|run-bootloader)
            set -- $(parse_wic_flags "$@")
            local target="${1:-2735}"
            case "${cmd}" in
                check) check_bundle "${target}" ;;
                run)   cmd_run "${target}" ;;
                run-bootloader) cmd_run_bootloader "${target}" ;;
            esac
            ;;
        prep)
            local target="${1:-2735}"
            cmd_prep "${target}"
            ;;
        -h|--help|"") usage ;;
        *) die "Unknown: ${cmd} (try check|prep|run)" ;;
    esac
}

main "$@"
