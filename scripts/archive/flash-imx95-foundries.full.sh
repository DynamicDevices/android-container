#!/usr/bin/env bash
# Flash Foundries LmP factory image to FRDM-IMX95 (15x15 LPDDR4x) via NXP uuu.
#
# SDPS must use lmp-mfgtool imx-boot-mfgtool (flash_a55), NOT production imx-boot.
# i.MX95 uses SDPS → fastboot (same as imx93). SDPV + u-boot-mfgtool.itb is imx8-style
# and fails on imx95 SPL with "Wrong container, no image found".
#
# FRDM-IMX95 has 32 GB eMMC on USDHC1 (mmc0). LmP boot.cmd uses devnum 0 (eMMC).
#
# Usage:
#   ./scripts/flash-imx95-foundries.sh [--emmc|--sd] [--timeout SECONDS] [TARGET] [FACTORY]
#   ./scripts/flash-imx95-foundries.sh --emmc 2707 dynamic-devices
#   ./scripts/flash-imx95-foundries.sh --emmc 2707 dynamic-devices --sdps-boot PATH/to/imx-boot-mfgtool
#   ./scripts/flash-imx95-foundries.sh --reference-nxp [PATH]   # NXP LF bench validation only
#   ./scripts/flash-imx95-foundries.sh --emmc 2707   # default: NXP flash_all SDPS/SDPV + LmP FB
#   ./scripts/flash-imx95-foundries.sh --foundries-boot --emmc 2707   # debug: Foundries imx-boot-mfgtool only
#   ./scripts/flash-imx95-foundries.sh --uuu-script full_image-nxp-boot.uuu --emmc 2707
#
# Timeouts (defaults): USB wait 15s, uuu per-invocation 10s (quick fail while debugging FB phase).
# Production full WIC flash: --timeout 1800 (and optionally USB_WAIT_MAX=60).
# USB phases: 015d (SDPS ROM), 0151 (SDPV / SPL waiting), 0152 (fastboot).
# Default: full_image-nxp-boot.uuu (NXP flash_all at SDPS/SDPV + Foundries FB) until mfgtool fixed.
# full_image.uuu = Foundries imx-boot-mfgtool at SDPS only + FB (--foundries-boot / --mfgtool-only).
# fb-only.uuu only when already at 0152.
#
# Prerequisites:
#   - Board in Serial Download mode (USB: 1fc9:015d SDPS; may show 0151/0152 during uuu)
#   - fioctl authenticated; uuu on PATH (apt install uuu / bundled in mfgtool tarball)
#   - One-time: ./scripts/install-flash-sudoers.sh
set -euo pipefail

# Repo root via scripts/flash-imx95-common.sh (never one level up — that was scripts/downloads).
# shellcheck source=../flash-imx95-common.sh
source "$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)/flash-imx95-common.sh"
ROOT_DIR="${IMX95_REPO_ROOT}"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: flash-imx95-foundries.sh [--emmc|--sd] [--prepare-only] [--timeout SEC] [--sdps-boot FILE]
       [--uuu-script FILE] [--foundries-boot|--mfgtool-only] [--nxp-boot] [--reference-nxp [DIR]]
       [TARGET] [FACTORY]

  --emmc   Flash onboard eMMC (USDHC1 / mmc0). Default. Matches LmP boot.cmd.
  --sd     Flash microSD (USDHC2 / mmc1). Requires SW1 SD boot (1,1).
  --prepare-only  Download/extract artifacts only; do not run uuu.
  --skip-serial   Do not open /dev/ttyACM* after flash (use ser2net; avoids port conflict).
  --regen-scripts  Regenerate UUU scripts from cached artifacts (no fioctl needed).
  --wic-compressed  FB flash uses Foundries .wic.gz in uuu (default; A/B test vs NXP .wic).
  --wic-uncompressed  Gunzip to .wic in flash-bundle; primary uuu scripts reference .wic.
  --timeout SEC   Max seconds per uuu invocation (default: 1800; use 300 for SDPS-only debug).
  --sdps-boot FILE  SDPS image for full_image.uuu (default: imx-boot-mfgtool from deploy or Foundries mfgtools)
  --uuu-script FILE  Use this uuu script from flash-bundle (default path: full_image-nxp-boot.uuu)
  --foundries-boot, --mfgtool-only  Use Foundries imx-boot-mfgtool SDPS path (full_image.uuu) for debugging
  --nxp-boot  Alias for default (NXP LF flash_all at SDPS/SDPV + Foundries LmP FB); kept for compatibility
  --reference-nxp [DIR]  Run NXP LF uuu.auto bench flash (default: ~/Downloads/LF_v6.18.2-1.0.0_images_IMX95)

  Environment: UUU_TIMEOUT, USB_WAIT_MAX (defaults 1800s / 60s).
  NXP LF bundle: NXP_LF_DIR or NXP_BUNDLE_DIR (default: ~/Downloads/LF_v6.18.2-1.0.0_images_IMX95).

FRDM SW1 (BOOT_MODE1, BOOT_MODE0):
  eMMC boot: 1, 0   (default NXP factory setting)
  SD boot:   1, 1
  Serial Download (UUU): 0, 1

See docs/imx95-foundries-emmc.md for BSP/CI changes.
EOF
}

FLASH_MEDIA="emmc"
PREPARE_ONLY=0
SKIP_SERIAL=0
REGEN_SCRIPTS=0
REFERENCE_NXP=0
REFERENCE_NXP_DIR=""
FOUNTRIES_BOOT=0
UUU_SCRIPT_OVERRIDE=""
SDPS_BOOT=""
# WIC FB variant: compressed (.wic.gz, Foundries default) vs uncompressed (.wic, NXP-style).
WIC_MODE="${WIC_MODE:-compressed}"
WIC_FB_NAME=""
# Default 1800s: full WIC sparse flash (~350 MB gzip / ~1.5 GB raw on eMMC) needs 15–30+ min over USB.
# Override with --timeout 300 only for SDPS-only / fb-only debugging.
UUU_TIMEOUT="${UUU_TIMEOUT:-1800}"
USB_WAIT_MAX="${USB_WAIT_MAX:-60}"
SERIAL_BAUD="${SERIAL_BAUD:-921600}"
POSITIONAL=()

while [[ $# -gt 0 ]]; do
    case "$1" in
        --emmc) FLASH_MEDIA="emmc"; shift ;;
        --sd)   FLASH_MEDIA="sd"; shift ;;
        --prepare-only) PREPARE_ONLY=1; shift ;;
        --skip-serial) SKIP_SERIAL=1; shift ;;
        --regen-scripts) REGEN_SCRIPTS=1; shift ;;
        --reference-nxp)
            REFERENCE_NXP=1
            if [[ $# -ge 2 ]] && [[ "${2}" != -* ]] && [[ ! "${2}" =~ ^[0-9]+$ ]]; then
                REFERENCE_NXP_DIR="$2"
                shift 2
            else
                shift
            fi
            ;;
        --timeout)
            [[ $# -ge 2 ]] || die "--timeout requires seconds"
            UUU_TIMEOUT="$2"
            shift 2
            ;;
        --sdps-boot)
            [[ $# -ge 2 ]] || die "--sdps-boot requires a file path"
            SDPS_BOOT="$2"
            shift 2
            ;;
        --uuu-script)
            [[ $# -ge 2 ]] || die "--uuu-script requires a script name"
            UUU_SCRIPT_OVERRIDE="$2"
            shift 2
            ;;
        --foundries-boot|--mfgtool-only)
            FOUNTRIES_BOOT=1
            shift
            ;;
        --nxp-boot)
            # Default path since 2026-05; kept for scripts/docs compatibility.
            shift
            ;;
        --wic-compressed)
            WIC_MODE="compressed"
            shift
            ;;
        --wic-uncompressed)
            WIC_MODE="uncompressed"
            shift
            ;;
        -h|--help) usage; exit 0 ;;
        --) shift; break ;;
        -*) die "Unknown option: $1 (try --help)" ;;
        *) POSITIONAL+=("$1"); shift ;;
    esac
done
while [[ $# -gt 0 ]]; do POSITIONAL+=("$1"); shift; done

TARGET="${POSITIONAL[0]:-2707}"
FACTORY="${POSITIONAL[1]:-dynamic-devices}"

DL_DIR="${ROOT_DIR}/downloads/target-${TARGET}"
MFG_DIR="${DL_DIR}/mfgtool-files-imx95-frdm-evk"
FLASH_DIR="${DL_DIR}/flash-bundle"
LOCAL_MFG_DIR="${ROOT_DIR}/../meta-dynamicdevices/build/tmp/deploy/images/imx95-frdm-evk/mfgtool-files"
SDPS_BOOT_NAME="imx-boot-mfgtool"
WIC_NAME="lmp-factory-image-imx95-frdm-evk.wic.gz"
WIC_FLASH_NAME="lmp-factory-image-imx95-frdm-evk.wic"
WIC_FLASH_TIMEOUT_MS=600000
PROD_BOOT_NAME="imx-boot-imx95-frdm-evk"
NXP_FLASH_ALL_NAME="imx-boot-imx95-15x15-lpddr4x-frdm-sd.bin-flash_all"
NXP_BUNDLE_DEFAULT="${HOME}/Downloads/LF_v6.18.2-1.0.0_images_IMX95"
NXP_BOOT_UUU="full_image-nxp-boot.uuu"
ANDROID_SDPS_MD5="ee4c7bf3dc6620c4e11af35eb7170ea4"
MM_WAS_ACTIVE=0

need_cmd() {
    command -v "$1" >/dev/null 2>&1 || die "Missing command: $1"
}

human_size() {
    local bytes="$1"
    if command -v numfmt >/dev/null 2>&1; then
        numfmt --to=iec-i --suffix=B "${bytes}" 2>/dev/null || printf '%s bytes' "${bytes}"
    else
        printf '%s bytes' "${bytes}"
    fi
}

download_artifact() {
    local artifact="$1"
    local dest="$2"
    if [[ -s "${dest}" ]] && ! grep -q '<Error>' "${dest}" 2>/dev/null; then
        if [[ "${dest}" == *.gz ]] && ! gzip -t "${dest}" 2>/dev/null; then
            warn "Cached ${dest##*/} is not valid gzip — re-downloading"
            rm -f "${dest}"
        else
            log "Using cached ${dest##*/} ($(human_size "$(stat -c%s "${dest}")"))"
            return 0
        fi
    elif [[ -s "${dest}" ]]; then
        rm -f "${dest}"
    fi
    log "Downloading ${artifact} ..."
    log "  -> ${dest}"
    local start_ts fioctl_pid monitor_pid
    start_ts=$(date +%s)
    fioctl -v targets artifacts "${TARGET}" "${artifact}" --factory "${FACTORY}" >"${dest}" &
    fioctl_pid=$!
    (
        while kill -0 "${fioctl_pid}" 2>/dev/null; do
            if [[ -s "${dest}" ]]; then
                printf '==>   %s: %s\r' "${dest##*/}" "$(human_size "$(stat -c%s "${dest}" 2>/dev/null || echo 0)")" >&2
            fi
            sleep 1
        done
    ) &
    monitor_pid=$!
    wait "${fioctl_pid}"
    local fioctl_rc=$?
    kill "${monitor_pid}" 2>/dev/null || true
    wait "${monitor_pid}" 2>/dev/null || true
    printf '\n' >&2
    [[ "${fioctl_rc}" -eq 0 ]] || die "fioctl download failed for ${artifact} (exit ${fioctl_rc})"
    if grep -q '<Error>' "${dest}" 2>/dev/null; then
        rm -f "${dest}"
        die "Artifact missing on Foundries (${artifact}). Target ${TARGET} CI may have failed — see assert_target_has_flash_artifacts hints."
    fi
    if [[ "${dest}" == *.gz ]] && ! gzip -t "${dest}" 2>/dev/null; then
        rm -f "${dest}"
        die "Downloaded ${dest##*/} is not valid gzip — artifact upload incomplete?"
    fi
    local elapsed size
    elapsed=$(($(date +%s) - start_ts))
    size=$(stat -c%s "${dest}")
    log "Downloaded ${dest##*/}: $(human_size "${size}") in ${elapsed}s"
}

resolve_wic_fb_name() {
    case "${WIC_MODE}" in
        compressed)
            WIC_FB_NAME="${WIC_NAME}"
            ;;
        uncompressed)
            WIC_FB_NAME="${WIC_FLASH_NAME}"
            ;;
        *)
            die "Invalid WIC_MODE=${WIC_MODE} (use compressed or uncompressed)"
            ;;
    esac
}

wic_variant_label() {
    local wic_file="$1"
    if [[ "${wic_file}" == *.gz ]]; then
        printf 'compressed (%s)\n' "${wic_file}"
    else
        printf 'uncompressed (%s)\n' "${wic_file}"
    fi
}

ensure_wic_for_flash() {
    # NXP uuu.auto uses uncompressed *.wic; Foundries ships .wic.gz.
    # fastboot flash -raw2sparse may write gzip magic (1f 8b 08) to eMMC if .wic.gz is used — verify with md.b.
    local gz_src="${1:-${FLASH_DIR}/${WIC_NAME}}"
    local wic_dest="${FLASH_DIR}/${WIC_FLASH_NAME}"
    [[ -s "${gz_src}" ]] || die "WIC archive missing: ${gz_src}"
    if [[ ! -s "${wic_dest}" ]] || [[ "${gz_src}" -nt "${wic_dest}" ]]; then
        log "Decompressing ${WIC_NAME} → ${WIC_FLASH_NAME} (--wic-uncompressed / companion scripts) ..."
        if gunzip -k -f "${gz_src}" 2>/dev/null; then
            [[ -s "${wic_dest}" ]] || die "gunzip -k did not create ${wic_dest}"
        else
            gunzip -c "${gz_src}" >"${wic_dest}.tmp" || die "gunzip failed for ${gz_src}"
            mv -f "${wic_dest}.tmp" "${wic_dest}"
        fi
    fi
    local wic_size gz_size
    wic_size=$(stat -c%s "${wic_dest}")
    gz_size=$(stat -c%s "${gz_src}")
    if [[ "${wic_size}" -lt 100000000 ]]; then
        die "Decompressed WIC too small (${wic_size} bytes) — gunzip corrupt or wrong artifact?"
    fi
    log "WIC decompressed: ${WIC_FLASH_NAME} (${wic_size} bytes, from ${gz_size} byte ${WIC_NAME})"
}

prepare_wic_artifacts() {
    [[ -s "${FLASH_DIR}/${WIC_NAME}" ]] || die "WIC archive missing: ${FLASH_DIR}/${WIC_NAME}"
    if [[ "${WIC_MODE}" == "uncompressed" ]]; then
        ensure_wic_for_flash
    fi
}

imx_usb_ids() {
    lsusb 2>/dev/null | grep -iE '1fc9:015[0-9a-f]|1fc9:0153' || true
}

has_sdps_rom() {
    lsusb 2>/dev/null | grep -qi '1fc9:015d'
}

has_sdpv() {
    lsusb 2>/dev/null | grep -qi '1fc9:0151'
}

has_fastboot() {
    lsusb 2>/dev/null | grep -qi '1fc9:0152'
}

detect_usb_phase() {
    if has_sdps_rom; then
        printf 'sdps_rom\n'
    elif has_fastboot; then
        printf 'fastboot\n'
    elif has_sdpv; then
        printf 'sdpv\n'
    elif imx95_programming_usb_present; then
        printf 'other_imx\n'
    else
        printf 'none\n'
    fi
}

imx95_programming_usb_present() {
    lsusb 2>/dev/null | grep -qiE '1fc9:015[0-9a-f]|1fc9:0153'
}

check_imx_usb_before_flash() {
    log "USB devices (NXP 1fc9):"
    if imx95_programming_usb_present; then
        imx_usb_ids
    else
        warn "No NXP programming USB (1fc9) detected yet."
    fi
}

systemctl_sudo() {
    local action="$1"
    local svc="$2"
    if env -u TERMINFO sudo -n /usr/bin/systemctl "${action}" "${svc}" 2>/dev/null; then
        return 0
    fi
    if env -u TERMINFO sudo -n /bin/systemctl "${action}" "${svc}" 2>/dev/null; then
        return 0
    fi
    # Do NOT fall back to interactive sudo — scripts/CI must not prompt for password.
    # If ModemManager stop is needed, run install-flash-sudoers.sh or stop MM manually.
    warn "Could not run 'sudo ${action} ${svc}' without password. Install sudoers or stop MM manually."
    return 1
}

udev_mm_ignore_configured() {
    # config/udev/99-nxp-mm-ignore.rules sets ID_MM_DEVICE_IGNORE for vendor 1fc9.
    grep -rq 'ID_MM_DEVICE_IGNORE.*1' /etc/udev/rules.d/ 2>/dev/null \
        && grep -rq '1fc9' /etc/udev/rules.d/ 2>/dev/null
}

stop_modemmanager() {
    if udev_mm_ignore_configured; then
        log "NXP udev rule present (ID_MM_DEVICE_IGNORE for 1fc9) — ModemManager will not probe the board."
        return 0
    fi
    if systemctl is-active --quiet ModemManager 2>/dev/null; then
        MM_WAS_ACTIVE=1
        log "Stopping ModemManager temporarily (ttyACM/uuu interference) ..."
        if ! systemctl_sudo stop ModemManager 2>/dev/null; then
            warn "Could not stop ModemManager; uuu may fail with LIBUSB_ERROR_IO"
            warn "Install config/udev/99-nxp-mm-ignore.rules or run: sudo systemctl stop ModemManager"
        fi
    elif pgrep -x ModemManager >/dev/null 2>&1; then
        warn "ModemManager is running (non-systemd). Consider stopping it before uuu."
    fi
}

restore_modemmanager() {
    if [[ "${MM_WAS_ACTIVE}" -eq 1 ]]; then
        log "Restarting ModemManager ..."
        systemctl_sudo start ModemManager 2>/dev/null || true
    fi
}

warn_serial_port_holders() {
    local dev holders=""
    for dev in /dev/ttyACM*; do
        [[ -e "${dev}" ]] || continue
        holders="$(lsof "${dev}" 2>/dev/null | awk 'NR>1 {print $1" (pid "$2")"}' | sort -u | tr '\n' ', ' || true)"
        if [[ -n "${holders}" ]]; then
            warn "${dev} in use by ${holders%,} — close minicom/screen/ser2net before uuu (can cause LIBUSB_ERROR_IO)."
            if [[ "${holders}" == *ser2net* ]]; then
                warn "Stop ser2net during uuu: sudo -n systemctl stop ser2net (lmp-frdm-cycle.sh flash does this)."
            fi
        fi
    done
}

wait_for_programming_usb() {
    local phase waited=0 max_wait="${USB_WAIT_MAX}"
    phase="$(detect_usb_phase)"
    case "${phase}" in
        sdps_rom)
            if [[ "${FOUNTRIES_BOOT}" -eq 1 ]]; then
                log "USB ROM SDPS detected (1fc9:015d) — will use Foundries full_image.uuu"
            else
                log "USB ROM SDPS detected (1fc9:015d) — will use NXP full_image-nxp-boot.uuu"
            fi
            imx_usb_ids
            return 0
            ;;
        sdpv)
            if [[ "${FOUNTRIES_BOOT}" -eq 1 ]]; then
                log "USB SDPV detected (1fc9:0151) — will use Foundries full_image.uuu"
            else
                log "USB SDPV detected (1fc9:0151) — will use NXP full_image-nxp-boot.uuu"
            fi
            imx_usb_ids
            return 0
            ;;
        fastboot)
            log "USB fastboot detected (1fc9:0152) — will use FB-only (fb-only.uuu)"
            imx_usb_ids
            return 0
            ;;
        other_imx)
            imx_usb_ids
            warn "i.MX USB present but not 015d/0151/0152. Will wait briefly or proceed with best guess."
            ;;
    esac
    log "Waiting up to ${max_wait}s for NXP programming USB (1fc9:015d preferred) ..."
    while [[ "${waited}" -lt "${max_wait}" ]]; do
        phase="$(detect_usb_phase)"
        case "${phase}" in
            sdps_rom|sdpv|fastboot|other_imx)
                log "NXP programming USB detected after ${waited}s (phase=${phase})"
                imx_usb_ids
                return 0
                ;;
        esac
        sleep 2
        waited=$((waited + 2))
    done
    warn "No NXP programming USB (1fc9) after ${max_wait}s — proceeding anyway; uuu will wait for enumeration."
    warn "Power-cycle the board now: SW1 Serial Download (0,1), USB J3 connected."
    warn "If stuck at 0152 from a prior attempt, power-cycle back to 015d or re-run for fb-only."
}

pick_uuu_script() {
    if [[ -n "${UUU_SCRIPT_OVERRIDE}" ]]; then
        printf '%s\n' "${UUU_SCRIPT_OVERRIDE}"
        return 0
    fi
    local phase
    phase="$(detect_usb_phase)"
    case "${phase}" in
        fastboot)
            printf 'fb-only.uuu\n'
            ;;
        sdpv)
            if [[ "${FOUNTRIES_BOOT}" -eq 1 ]]; then
                # Foundries path: board at 0151 after SDPS; SPL may not reach fastboot on imx95.
                log "Board at 0151 (Foundries path); trying fb-only.uuu."
                printf 'fb-only.uuu\n'
            else
                log "Board at 0151 — will use NXP full_image-nxp-boot.uuu (SDPV phase)."
                printf '%s\n' "${NXP_BOOT_UUU}"
            fi
            ;;
        sdps_rom|other_imx|none)
            if [[ "${FOUNTRIES_BOOT}" -eq 1 ]]; then
                printf 'full_image.uuu\n'
            else
                printf '%s\n' "${NXP_BOOT_UUU}"
            fi
            ;;
    esac
}

write_fb_only_uuu() {
    local uuu_file="$1"
    if [[ "${FLASH_MEDIA}" == "emmc" ]]; then
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv emmc_dev 0
FB: ucmd setenv mmcdev 0
FB: ucmd mmc dev 0
FB: ucmd mmc dev 0 1; mmc erase 0 0x2000; mmc dev 0 0
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: ucmd if env exists emmc_ack; then ; else setenv emmc_ack 0; fi;
FB: ucmd mmc partconf 0 \${emmc_ack} 1 0
FB: done
UUU
    else
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv mmcdev 1
FB: ucmd mmc dev \${mmcdev}
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: done
UUU
    fi
}

# Fastboot-only: production imx-boot to eMMC boot hwpart — does NOT re-flash WIC/rootfs.
write_bootloader_only_uuu() {
    local uuu_file="$1"
    cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv emmc_dev 0
FB: ucmd setenv mmcdev 0
FB: ucmd mmc dev 0
FB: flash bootloader ${PROD_BOOT_NAME}
FB: ucmd if env exists emmc_ack; then ; else setenv emmc_ack 0; fi;
FB: ucmd mmc partconf 0 \${emmc_ack} 1 0
FB: done
UUU
}

write_sdpv_resume_full_uuu() {
    # Use only in FIT workflow (SPL-only mfgtool + u-boot-mfgtool.itb).
    # Board is at 0151 (SPL started). Write u-boot-mfgtool.itb (FIT) via SDPV to load full U-Boot.
    # Do NOT use with imx-boot-mfgtool (AHAB full container) — SPL can't accept it at SDPV.
    local uuu_file="$1"
    local itb_file="u-boot-mfgtool.itb"
    if [[ "${FLASH_MEDIA}" == "emmc" ]]; then
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDPV: delay 1000
SDPV: write -f ${itb_file}
SDPV: jump

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv emmc_dev 0
FB: ucmd setenv mmcdev 0
FB: ucmd mmc dev 0
FB: ucmd mmc dev 0 1; mmc erase 0 0x2000; mmc dev 0 0
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: ucmd if env exists emmc_ack; then ; else setenv emmc_ack 0; fi;
FB: ucmd mmc partconf 0 \${emmc_ack} 1 0
FB: done
UUU
    else
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDPV: delay 1000
SDPV: write -f ${itb_file}
SDPV: jump

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv mmcdev 1
FB: ucmd mmc dev \${mmcdev}
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: done
UUU
    fi
}

write_sdps_only_uuu() {
    # SDPS only: boots imx-boot-mfgtool, no flash. Board goes 015d -> 0152 (fastboot).
    # Do NOT include SDPV with imx-boot-mfgtool: causes SPL reset loop.
    local uuu_file="$1"
    local sdps_file="$2"
    cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDPS: boot -f ${sdps_file}
UUU
}

link_nxp_flash_all() {
    local bundle_dir="${NXP_LF_DIR:-${NXP_BUNDLE_DIR:-${NXP_BUNDLE_DEFAULT}}}"
    local src="${bundle_dir}/${NXP_FLASH_ALL_NAME}"
    local dest="${FLASH_DIR}/${NXP_FLASH_ALL_NAME}"
    [[ -s "${src}" ]] || die "NXP flash_all not found: ${src} (install LF bundle or set NXP_LF_DIR)"
    ln -sf "${src}" "${dest}"
    log "Linked NXP flash_all: ${dest} -> ${src}"
}

write_full_image_nxp_boot_uuu() {
    local uuu_file="$1"
    if [[ "${FLASH_MEDIA}" == "emmc" ]]; then
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDP: boot -f ${NXP_FLASH_ALL_NAME}
SDPS: boot -f ${NXP_FLASH_ALL_NAME}

SDPU: delay 1000
SDPU: write -f ${NXP_FLASH_ALL_NAME} -offset 0x57c00
SDPU: jump

SDPV: delay 1000
SDPV: write -f ${NXP_FLASH_ALL_NAME} -skipspl
SDPV: jump

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv emmc_dev 0
FB: ucmd setenv mmcdev 0
FB: ucmd mmc dev 0
FB: ucmd mmc dev 0 1; mmc erase 0 0x2000; mmc dev 0 0
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: ucmd if env exists emmc_ack; then ; else setenv emmc_ack 0; fi;
FB: ucmd mmc partconf 0 \${emmc_ack} 1 0
FB: done
UUU
    else
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDP: boot -f ${NXP_FLASH_ALL_NAME}
SDPS: boot -f ${NXP_FLASH_ALL_NAME}

SDPU: delay 1000
SDPU: write -f ${NXP_FLASH_ALL_NAME} -offset 0x57c00
SDPU: jump

SDPV: delay 1000
SDPV: write -f ${NXP_FLASH_ALL_NAME} -skipspl
SDPV: jump

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv mmcdev 1
FB: ucmd mmc dev \${mmcdev}
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: done
UUU
    fi
}

write_full_image_uuu() {
    # i.MX95 Foundries mfgtool (matches meta-dynamicdevices-bsp mfgtool-files/full_image.uuu.in):
    #   imx-boot-mfgtool at SDPS only — SPL loads AHAB container and boots to fastboot (0152).
    #   NO SDPV — i.MX95 SPL uses CONFIG_SPL_LOAD_IMX_CONTAINER, not FIT on SDPV (imx8-style
    #   u-boot-mfgtool.itb at SDPV causes reset loop; NXP uses flash_all -skipspl instead).
    local uuu_file="$1"
    local sdps_file="$2"
    if [[ "${FLASH_MEDIA}" == "emmc" ]]; then
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDPS: boot -f ${sdps_file}

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv emmc_dev 0
FB: ucmd setenv mmcdev 0
FB: ucmd mmc dev 0
FB: ucmd mmc dev 0 1; mmc erase 0 0x2000; mmc dev 0 0
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: ucmd if env exists emmc_ack; then ; else setenv emmc_ack 0; fi;
FB: ucmd mmc partconf 0 \${emmc_ack} 1 0
FB: done
UUU
    else
        cat >"${uuu_file}" <<UUU
uuu_version 1.4.149

SDPS: boot -f ${sdps_file}

FB: ucmd setenv fastboot_dev mmc
FB: ucmd setenv mmcdev 1
FB: ucmd mmc dev \${mmcdev}
FB[-t ${WIC_FLASH_TIMEOUT_MS}]: flash -raw2sparse all ${WIC_FB_NAME}
FB: flash bootloader ${PROD_BOOT_NAME}
FB: done
UUU
    fi
}

validate_uuu_wic_flash() {
    local uuu_file="$1"
    local label="${2:-uuu script}"
    local expected_wic="${3:-}"
    local fb_count flash_line wic_file

    flash_line=$(grep -E '^FB(\[-t [0-9]+\])?: flash -raw2sparse all' "${uuu_file}" || true)
    [[ -n "${flash_line}" ]] || die "${label} missing flash -raw2sparse FB command"
    wic_file=$(echo "${flash_line}" | awk '{print $NF}')
    if [[ -z "${expected_wic}" ]]; then
        expected_wic="${wic_file}"
    fi
    [[ "${wic_file}" == "${expected_wic}" ]] \
        || die "${label} WIC flash line uses ${wic_file}, expected ${expected_wic}"
    log "${label}: WIC variant $(wic_variant_label "${wic_file}")"
    if ! grep -qE '^FB\[-t [0-9]+\]: flash -raw2sparse all' "${uuu_file}"; then
        warn "${label}: WIC flash line has no FB[-t] timeout — long flashes may abort early"
    fi
    fb_count=$(grep -c '^FB' "${uuu_file}" || true)
    [[ "${fb_count}" -ge 10 ]] \
        || die "${label} expected >=10 FB steps (got ${fb_count}) — incomplete emmc flash sequence?"
    log "${label}: ${fb_count} FB steps, WIC flash: $(echo "${flash_line}" | sed 's/^/ /')"
}

validate_full_image_uuu() {
    local uuu_file="$1"
    local expected_wic="${2:-${WIC_FB_NAME}}"
    grep -q '^SDPS: boot -f imx-boot-mfgtool$' "${uuu_file}" \
        || die "full_image.uuu missing 'SDPS: boot -f imx-boot-mfgtool' line"
    # i.MX95: SDPS-only path (no SDPV). FIT/ITB at SDPV fails on this SoC.
    if grep -qE '^SDPV:|^SDPU:' "${uuu_file}"; then
        die "full_image.uuu must not include SDPV/SDPU on i.MX95 (use SDPS-only, then FB)"
    fi
    if grep -qE 'SDPV:.*-skipspl|SDPU:.*-skipspl' "${uuu_file}"; then
        die "full_image.uuu must not use -skipspl (Unknown Image type on imx95 AHAB)"
    fi
    grep -q "flash bootloader ${PROD_BOOT_NAME}" "${uuu_file}" \
        || die "full_image.uuu missing production bootloader flash line"
    validate_uuu_wic_flash "${uuu_file}" "$(basename "${uuu_file}")" "${expected_wic}"
}

validate_nxp_boot_uuu() {
    local uuu_file="$1"
    local expected_wic="${2:-${WIC_FB_NAME}}"
    grep -q "flash bootloader ${PROD_BOOT_NAME}" "${uuu_file}" \
        || die "$(basename "${uuu_file}") missing production bootloader flash line"
    validate_uuu_wic_flash "${uuu_file}" "$(basename "${uuu_file}")" "${expected_wic}"
}

write_uuu_script_set() {
    # suffix: "" for primary names, "-wic-compressed" / "-wic-uncompressed" for A/B companions.
    local suffix="$1"
    local sdps_file="${2:-${SDPS_BOOT_NAME}}"
    local nxp_boot="${NXP_BOOT_UUU}"
    if [[ -n "${suffix}" ]]; then
        nxp_boot="${NXP_BOOT_UUU%.uuu}${suffix}.uuu"
    fi
    write_full_image_uuu "${FLASH_DIR}/full_image${suffix}.uuu" "${sdps_file}"
    validate_full_image_uuu "${FLASH_DIR}/full_image${suffix}.uuu" "${WIC_FB_NAME}"
    write_sdps_only_uuu "${FLASH_DIR}/sdps-only.uuu" "${sdps_file}"
    write_fb_only_uuu "${FLASH_DIR}/fb-only${suffix}.uuu"
    if [[ -z "${suffix}" ]]; then
        write_bootloader_only_uuu "${FLASH_DIR}/bootloader-only.uuu"
    fi
    write_sdpv_resume_full_uuu "${FLASH_DIR}/sdpv-resume-full${suffix}.uuu"
    write_full_image_nxp_boot_uuu "${FLASH_DIR}/${nxp_boot}"
    validate_nxp_boot_uuu "${FLASH_DIR}/${nxp_boot}" "${WIC_FB_NAME}"
}

generate_uuu_scripts() {
    local sdps_file="${1:-${SDPS_BOOT_NAME}}"

    link_nxp_flash_all

    resolve_wic_fb_name
    prepare_wic_artifacts
    log "Primary UUU scripts (WIC variant: $(wic_variant_label "${WIC_FB_NAME}"))"
    write_uuu_script_set "" "${sdps_file}"

    ensure_wic_for_flash

    WIC_FB_NAME="${WIC_NAME}"
    log "Companion UUU scripts (WIC variant: $(wic_variant_label "${WIC_FB_NAME}"))"
    write_uuu_script_set "-wic-compressed" "${sdps_file}"

    WIC_FB_NAME="${WIC_FLASH_NAME}"
    log "Companion UUU scripts (WIC variant: $(wic_variant_label "${WIC_FB_NAME}"))"
    write_uuu_script_set "-wic-uncompressed" "${sdps_file}"

    resolve_wic_fb_name
    log "UUU scripts in ${FLASH_DIR}/ (primary follows --wic-compressed|--wic-uncompressed)"
    log "  Primary fb-only.uuu → $(wic_variant_label "${WIC_FB_NAME}")"
    log "  A/B companions: fb-only-wic-compressed.uuu (.wic.gz), fb-only-wic-uncompressed.uuu (.wic)"
}

artifacts_cached() {
    [[ -s "${DL_DIR}/mfgtool-files.tar.gz" ]] \
        && gzip -t "${DL_DIR}/mfgtool-files.tar.gz" 2>/dev/null \
        && [[ -s "${DL_DIR}/${PROD_BOOT_NAME}" ]] \
        && [[ -s "${DL_DIR}/${WIC_NAME}" ]] \
        && gzip -t "${DL_DIR}/${WIC_NAME}" 2>/dev/null \
        && ! grep -q '<Error>' "${DL_DIR}/${WIC_NAME}" 2>/dev/null
}

assert_target_has_flash_artifacts() {
    local wic_path="imx95-frdm-evk/${WIC_NAME}"
    local published_note=""
    if ! fioctl targets show "${TARGET}" --factory "${FACTORY}" >/dev/null 2>&1; then
        published_note=" (not published to TUF — CI likely failed)"
    fi
    local artifacts_list
    if ! artifacts_list="$(fioctl targets artifacts "${TARGET}" --factory "${FACTORY}" 2>/dev/null)"; then
        artifacts_list=""
    fi
    # Capture before grep: pipefail + grep -q SIGPIPEs fioctl (exit 141) even when the WIC is listed.
    if ! grep -Fq "${wic_path}" <<<"${artifacts_list}"         && ! grep -Fq "${WIC_NAME}" <<<"${artifacts_list}"; then
        die "Target ${TARGET} has no ${WIC_NAME}${published_note}.

CI probably failed before the factory image was uploaded (fioctl would return HTTP 404 on download).
  fioctl targets artifacts ${TARGET} imx95-frdm-evk/console.log --factory ${FACTORY} | tail -40
  fioctl targets list -f ${FACTORY} | grep imx95

Use a published imx95 target, e.g.: $(basename "$0") --prepare-only --emmc 2744 ${FACTORY}"
    fi
}

try_download_sdps_boot() {
    local dest="$1"
    local artifact="imx95-frdm-evk-mfgtools/other/mfgtool-files/imx-boot-mfgtool"
    if [[ -s "${dest}" ]]; then
        return 0
    fi
    log "Trying Foundries mfgtools artifact ${artifact} ..."
    if fioctl targets artifacts "${TARGET}" "${artifact}" --factory "${FACTORY}" >"${dest}" 2>/dev/null \
        && [[ -s "${dest}" ]] \
        && ! grep -q '<Error>' "${dest}" 2>/dev/null; then
        log "Downloaded ${SDPS_BOOT_NAME} from mfgtools target"
        return 0
    fi
    rm -f "${dest}"
    return 1
}

sdps_boot_md5() {
    md5sum "$1" | awk '{print $1}'
}

validate_sdps_boot() {
    local file="$1"
    local prod="${DL_DIR}/${PROD_BOOT_NAME}"
    local tag size md5

    tag=$(xxd -l 4 -p "${file}" 2>/dev/null | tr -d '\n')
    if [[ "${tag}" != "02232087" ]]; then
        die "SDPS boot lacks i.MX9 AHAB container tag 0x87202302 at offset 0 (got 0x${tag:-?}). Need lmp-mfgtool imx-boot-mfgtool (flash_a55)."
    fi

    size=$(stat -c%s "${file}")
    if [[ "${size}" -gt 3000000 ]]; then
        die "SDPS boot is ${size} bytes — unexpectedly large for imx-boot-mfgtool (expect <= ~3 MB)."
    fi
    if [[ "${size}" -lt 500000 ]]; then
        die "SDPS boot is ${size} bytes — too small to be a valid imx-boot-mfgtool."
    fi

    md5="$(sdps_boot_md5 "${file}")"
    if [[ "${md5}" == "${ANDROID_SDPS_MD5}" ]]; then
        die "Refusing Android u-boot-imx95-15x15-frdm-uuu.imx for SDPS (flash_all container; SPL sync-abort). Use lmp-mfgtool imx-boot-mfgtool."
    fi

    if [[ -s "${prod}" ]] && cmp -s "${file}" "${prod}"; then
        die "SDPS boot must not be production ${PROD_BOOT_NAME} (use for FB: flash bootloader only)."
    fi
}

resolve_sdps_boot() {
    local dest="${FLASH_DIR}/${SDPS_BOOT_NAME}"
    local src=""

    if [[ -n "${SDPS_BOOT}" ]]; then
        [[ -s "${SDPS_BOOT}" ]] || die "SDPS boot file not found: ${SDPS_BOOT}"
        src="${SDPS_BOOT}"
        log "Using SDPS boot from --sdps-boot: ${src}"
    elif [[ -s "${LOCAL_MFG_DIR}/${SDPS_BOOT_NAME}" ]]; then
        src="${LOCAL_MFG_DIR}/${SDPS_BOOT_NAME}"
        log "Using SDPS boot from local deploy: ${src}"
    elif [[ -s "${MFG_DIR}/${SDPS_BOOT_NAME}" ]]; then
        src="${MFG_DIR}/${SDPS_BOOT_NAME}"
        log "Using SDPS boot from mfgtool tarball: ${src}"
    elif try_download_sdps_boot "${DL_DIR}/${SDPS_BOOT_NAME}"; then
        src="${DL_DIR}/${SDPS_BOOT_NAME}"
    else
        die "No SDPS boot image (imx-boot-mfgtool). Production imx-boot and Android uuu.imx do not work for SDPS.

Obtain lmp-mfgtool imx-boot-mfgtool (flash_a55, LPDDR4x FRDM):
  1. Local kas: kas build kas/imx95-frdm-evk-mfgtool.yml
     cp ../meta-dynamicdevices/build/tmp/deploy/images/imx95-frdm-evk/mfgtool-files/imx-boot-mfgtool \\
        downloads/target-${TARGET}/
  2. Foundries: rebuild mfg_tools after BSP merge; artifact:
       imx95-frdm-evk-mfgtools/other/mfgtool-files/imx-boot-mfgtool
  3. Flash: ./scripts/flash-imx95-foundries.sh --sdps-boot PATH/to/imx-boot-mfgtool --emmc ${TARGET}

See docs/imx95-foundries-emmc.md"
    fi

    validate_sdps_boot "${src}"
    cp -f "${src}" "${dest}"
    log "SDPS boot: ${dest} ($(stat -c%s "${dest}") bytes)"
}

copy_mfgtool_extras() {
    local src_dir="$1"
    local f
    [[ -d "${src_dir}" ]] || return 0
    for f in u-boot-mfgtool.itb uuu fitImage-imx95-frdm-evk-mfgtool; do
        if [[ -s "${src_dir}/${f}" ]]; then
            cp -f "${src_dir}/${f}" "${FLASH_DIR}/"
            log "Bundled ${f} from ${src_dir##*/}"
        fi
    done
}

regen_uuu_scripts() {
    # Regenerate all UUU scripts from existing flash-bundle artifacts (no download needed).
    local sdps_dest="${FLASH_DIR}/${SDPS_BOOT_NAME}"
    if [[ ! -s "${sdps_dest}" ]]; then
        resolve_sdps_boot
    else
        log "SDPS boot: ${sdps_dest} ($(stat -c%s "${sdps_dest}") bytes) — validating"
        validate_sdps_boot "${sdps_dest}"
    fi
    [[ -s "${FLASH_DIR}/${WIC_NAME}" ]] || die "Missing ${FLASH_DIR}/${WIC_NAME} — run without --regen-scripts first"
    generate_uuu_scripts "${SDPS_BOOT_NAME}"
    log "Default flash script ${NXP_BOOT_UUU}:"
    sed 's/^/  /' "${FLASH_DIR}/${NXP_BOOT_UUU}"
    log "Foundries debug script full_image.uuu (--foundries-boot):"
    sed 's/^/  /' "${FLASH_DIR}/full_image.uuu"
}

prepare_bundle() {
    imx95_migrate_legacy_downloads "${TARGET}"
    mkdir -p "${DL_DIR}" "${FLASH_DIR}"

    if artifacts_cached; then
        log "All artifacts cached in ${DL_DIR} — skipping fioctl download."
    else
        need_cmd fioctl
        assert_target_has_flash_artifacts
        log "Fetching target ${TARGET} from factory ${FACTORY}:"
        log "  1/3 mfgtool-files.tar.gz (~30 MiB)"
        log "  2/3 ${PROD_BOOT_NAME} (~2.5 MiB)"
        log "  3/3 ${WIC_NAME} (~340 MiB — longest step; fioctl bar on stderr, byte count below)"
        download_artifact "imx95-frdm-evk-mfgtools/mfgtool-files.tar.gz" "${DL_DIR}/mfgtool-files.tar.gz"
        download_artifact "imx95-frdm-evk/${PROD_BOOT_NAME}" "${DL_DIR}/${PROD_BOOT_NAME}"
        download_artifact "imx95-frdm-evk/${WIC_NAME}" "${DL_DIR}/${WIC_NAME}"
    fi

    if [[ ! -d "${MFG_DIR}" ]]; then
        tar -xzf "${DL_DIR}/mfgtool-files.tar.gz" -C "${DL_DIR}"
    fi

    if [[ ! -s "${FLASH_DIR}/${PROD_BOOT_NAME}" ]]; then
        cp -f "${DL_DIR}/${PROD_BOOT_NAME}" "${FLASH_DIR}/"
    fi
    if [[ ! -s "${FLASH_DIR}/${WIC_NAME}" ]]; then
        cp -f "${DL_DIR}/${WIC_NAME}" "${FLASH_DIR}/"
    fi
    prepare_wic_artifacts

    copy_mfgtool_extras "${LOCAL_MFG_DIR}"
    copy_mfgtool_extras "${MFG_DIR}"

    resolve_sdps_boot
    generate_uuu_scripts "${SDPS_BOOT_NAME}"

    log "flash-bundle contents:"
    ls -la "${FLASH_DIR}/"
    log "Default ${NXP_BOOT_UUU} (NXP flash_all SDPS/SDPV + LmP FB, WIC $(wic_variant_label "${WIC_FB_NAME}")):"
    sed 's/^/  /' "${FLASH_DIR}/${NXP_BOOT_UUU}"
    log "WIC A/B companions: ${NXP_BOOT_UUU%.uuu}-wic-compressed.uuu (.wic.gz), ${NXP_BOOT_UUU%.uuu}-wic-uncompressed.uuu (.wic)"
    log "Foundries debug full_image.uuu (--foundries-boot):"
    sed 's/^/  /' "${FLASH_DIR}/full_image.uuu"
    log "fb-only.uuu (FB, no SDPS):"
    sed 's/^/  /' "${FLASH_DIR}/fb-only.uuu"
}


canonical_uuu_path() {
    local bin="$1"
    if [[ -x "${bin}" ]]; then
        readlink -f "${bin}"
        return 0
    fi
    printf '%s\n' "${bin}"
}

resolve_uuu_bin() {
    local bin=""
    if [[ -n "${UUU_BIN:-}" ]]; then
        bin="${UUU_BIN}"
    elif command -v uuu >/dev/null 2>&1; then
        # Prefer system uuu: bundled 1.5.179 can fail SDPV at 0151; apt 1.5.141 handles SDPV reliably.
        bin="$(command -v uuu)"
    elif [[ -x "${FLASH_DIR}/uuu" ]]; then
        bin="${FLASH_DIR}/uuu"
    elif [[ -x "${LOCAL_MFG_DIR}/uuu" ]]; then
        bin="${LOCAL_MFG_DIR}/uuu"
    elif [[ -x "${MFG_DIR}/uuu" ]]; then
        bin="${MFG_DIR}/uuu"
    else
        bin="uuu"
    fi
    canonical_uuu_path "${bin}"
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

mm_sudo_nopasswd() {
    # Use sudo -nl (non-interactive list) to check if ModemManager stop is NOPASSWD.
    # The old check used is-active which is NOT in sudoers.
    [[ "$(id -u)" -eq 0 ]] && return 0
    sudo -nl 2>/dev/null | grep -q 'ModemManager'
}

uuu_direct_access_ok() {
    local uuu_bin="$1" out
    [[ "$(id -u)" -eq 0 ]] && return 0
    [[ -x "${uuu_bin}" ]] || return 1
    out="$("${uuu_bin}" -V 2>&1)" || return 1
    [[ "${out}" == *"Universal Update Utility"* ]] || [[ "${out}" == *"uuu ("* ]]
}

check_flash_prerequisites() {
    local uuu_bin="$1"
    if [[ "$(id -u)" -eq 0 ]]; then
        return 0
    fi
    if uuu_direct_access_ok "${uuu_bin}"; then
        log "uuu runs without sudo (uaccess/udev ACL) — OK"
    elif ! uuu_sudo_nopasswd "${uuu_bin}"; then
        die "uuu needs USB access: install udev rules (70-uuu.rules + config/udev/99-nxp-mm-ignore.rules) or run ./scripts/install-flash-sudoers.sh"
    fi
    if udev_mm_ignore_configured; then
        log "NXP MM-ignore udev rule installed — ModemManager will not interfere"
    elif ! mm_sudo_nopasswd; then
        warn "Passwordless sudo for ModemManager is not configured (re-run ./scripts/install-flash-sudoers.sh)."
        warn "Without stopping ModemManager, SDPS may fail at ~36% with LIBUSB_ERROR_IO."
        warn "Or install: sudo cp config/udev/99-nxp-mm-ignore.rules /etc/udev/rules.d/ && sudo udevadm control --reload-rules"
    fi
}

run_uuu_once() {
    local uuu_bin="$1"
    local log_file="$2"
    local uuu_script="$3"
    local rc=0

    log "Running uuu script ${uuu_script} (timeout ${UUU_TIMEOUT}s) ..."
    if [[ "$(id -u)" -eq 0 ]]; then
        (cd "${FLASH_DIR}" && timeout "${UUU_TIMEOUT}" "${uuu_bin}" -pp 100 "${uuu_script}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    elif uuu_direct_access_ok "${uuu_bin}"; then
        (cd "${FLASH_DIR}" && timeout "${UUU_TIMEOUT}" "${uuu_bin}" -pp 100 "${uuu_script}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    elif uuu_sudo_nopasswd "${uuu_bin}"; then
        (cd "${FLASH_DIR}" && timeout "${UUU_TIMEOUT}" env -u TERMINFO sudo -n "${uuu_bin}" -pp 100 "${uuu_script}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    else
        log "sudo password required for uuu (USB device access)."
        log "One-time: ./scripts/install-flash-sudoers.sh  (see docs/imx95-foundries-emmc.md)"
        (cd "${FLASH_DIR}" && timeout "${UUU_TIMEOUT}" env -u TERMINFO sudo "${uuu_bin}" -pp 100 "${uuu_script}") 2>&1 | tee "${log_file}"
        rc="${PIPESTATUS[0]}"
    fi
    if [[ "${rc}" -eq 124 ]]; then
        die "uuu timed out after ${UUU_TIMEOUT}s (script ${uuu_script})"
    fi
    return "${rc}"
}

uuu_output_empty_run() {
    local log_file="$1"
    if grep -qiE 'sudo: a password is required|password is required' "${log_file}" 2>/dev/null; then
        return 0
    fi
    if grep -qE 'Success[[:space:]]+0[[:space:]]+Failure[[:space:]]+0' "${log_file}" 2>/dev/null \
        && ! grep -qE 'Success[[:space:]]+[1-9]|Downloading|Writing|Flashing|Done!' "${log_file}" 2>/dev/null; then
        return 0
    fi
    if grep -qE 'Failure[[:space:]]+[1-9]' "${log_file}" 2>/dev/null; then
        return 0
    fi
    if grep -qiE 'no device|Waiting for Known USB|find any device' "${log_file}" 2>/dev/null \
        && ! grep -qE 'Success[[:space:]]+[1-9]' "${log_file}" 2>/dev/null; then
        return 0
    fi
    return 1
}

uuu_output_success() {
    local log_file="$1"
    uuu_output_empty_run "${log_file}" && return 1
    grep -qE 'Success[[:space:]]+[1-9]|Done!' "${log_file}" 2>/dev/null
}

capture_serial_brief() {
    local serial_dev="${SERIAL_DEV:-/dev/ttyACM0}"
    local serial_log=""
    [[ -e "${serial_dev}" ]] || return 0
    if ! command -v timeout >/dev/null 2>&1; then
        return 0
    fi
    serial_log="$(mktemp "${TMPDIR:-/tmp}/flash-serial.XXXXXX")"
    log "Capturing serial from ${serial_dev} @ ${SERIAL_BAUD} for 30s ..."
    if command -v stty >/dev/null 2>&1; then
        stty -F "${serial_dev}" "${SERIAL_BAUD}" cs8 -cstopb -parenb 2>/dev/null || true
    fi
    timeout 30 cat "${serial_dev}" >"${serial_log}" 2>/dev/null &
    local cat_pid=$!
    wait "${cat_pid}" 2>/dev/null || true
    if [[ -s "${serial_log}" ]]; then
        log "Serial output (${serial_dev}):"
        sed 's/^/  /' "${serial_log}" | tail -50
    else
        log "No serial output on ${serial_dev} (may need dialout group or port in use)."
    fi
    rm -f "${serial_log}"
}

try_uuu_script() {
    local uuu_bin="$1"
    local log_file="$2"
    local uuu_script="$3"
    local rc=0

    if run_uuu_once "${uuu_bin}" "${log_file}" "${uuu_script}"; then
        rc=0
    else
        rc=$?
    fi
    if uuu_output_success "${log_file}"; then
        return 0
    fi
    if uuu_output_empty_run "${log_file}"; then
        warn "uuu empty run (Success 0 Failure 0 or no device) with ${uuu_script}"
        log "Retrying ${uuu_script} after 2s USB settle ..."
        sleep 2
        if run_uuu_once "${uuu_bin}" "${log_file}" "${uuu_script}"; then
            rc=0
        else
            rc=$?
        fi
        if uuu_output_success "${log_file}"; then
            return 0
        fi
    fi
    return "${rc:-1}"
}

uuu_output_retriable() {
    local log_file="$1"
    grep -qiE 'LIBUSB_ERROR_NO_DEVICE|LIBUSB_ERROR_IO|Fail HID\(W\)|error, status -4' "${log_file}" 2>/dev/null
}

run_uuu() {
    local uuu_bin log_file rc uuu_script alt_script
    uuu_bin="$(resolve_uuu_bin)"
    need_cmd timeout
    need_cmd "${uuu_bin}"
    check_flash_prerequisites "${uuu_bin}"
    log_file="$(mktemp "${TMPDIR:-/tmp}/uuu-flash.XXXXXX")"
    trap 'rm -f "${log_file}"; restore_modemmanager' EXIT

    log "Using uuu: ${uuu_bin} (per-invocation timeout ${UUU_TIMEOUT}s)"
    stop_modemmanager
    warn_serial_port_holders
    check_imx_usb_before_flash
    wait_for_programming_usb

    # Brief settle after USB enumeration before uuu (avoids Success 0 / empty run).
    local usb_settle="${USB_SETTLE_DELAY:-1}"
    if [[ "${usb_settle}" -gt 0 ]]; then
        log "USB settle delay ${usb_settle}s before uuu ..."
        sleep "${usb_settle}"
    fi

    uuu_script="$(pick_uuu_script)"
    log "Selected uuu script: ${uuu_script} (USB phase=$(detect_usb_phase))"

    log "Flashing target ${TARGET} (${FACTORY}) to ${FLASH_MEDIA} from ${FLASH_DIR}"
    if [[ "${UUU_TIMEOUT}" -lt 900 ]] && grep -q 'flash -raw2sparse all' "${FLASH_DIR}/${uuu_script}" 2>/dev/null; then
        warn "UUU timeout ${UUU_TIMEOUT}s may be too short for full WIC flash; use --timeout 1800 (default) or expect incomplete eMMC/GPT."
    fi
    if [[ "${FLASH_MEDIA}" == "emmc" ]]; then
        log "Erases onboard eMMC (mmcdev 0 = USDHC1). Set SW1 to eMMC boot (1,0) before normal boot."
    else
        log "Erases microSD (mmcdev 1). Set SW1 to SD boot (1,1). LmP boot.cmd uses devnum 0 — SD boot needs BSP change."
    fi

    if try_uuu_script "${uuu_bin}" "${log_file}" "${uuu_script}"; then
        [[ "${SKIP_SERIAL}" -eq 0 ]] && capture_serial_brief
        return 0
    fi
    rc=$?

    if uuu_output_retriable "${log_file}"; then
        log "USB re-enumeration error (NO_DEVICE/IO); retrying once in 2s ..."
        sleep 2
        uuu_script="$(pick_uuu_script)"
        if try_uuu_script "${uuu_bin}" "${log_file}" "${uuu_script}"; then
            [[ "${SKIP_SERIAL}" -eq 0 ]] && capture_serial_brief
            return 0
        fi
        rc=$?
    fi

    alt_script=""
    if [[ "${uuu_script}" == "${NXP_BOOT_UUU}" || "${uuu_script}" == "full_image.uuu" ]] \
        && [[ -f "${FLASH_DIR}/fb-only.uuu" ]] \
        && [[ "$(detect_usb_phase)" == "fastboot" ]]; then
        alt_script="fb-only.uuu"
    elif [[ "${uuu_script}" == "fb-only.uuu" ]] && [[ "$(detect_usb_phase)" != "fastboot" ]]; then
        if [[ "${FOUNTRIES_BOOT}" -eq 1 ]]; then
            resolve_wic_fb_name
            write_full_image_uuu "${FLASH_DIR}/full_image.uuu" "${SDPS_BOOT_NAME}"
            validate_full_image_uuu "${FLASH_DIR}/full_image.uuu"
            alt_script="full_image.uuu"
        else
            alt_script="${NXP_BOOT_UUU}"
        fi
    fi

    if [[ -n "${alt_script}" ]]; then
        log "Primary ${uuu_script} failed; trying alternate ${alt_script} ..."
        sleep 2
        if try_uuu_script "${uuu_bin}" "${log_file}" "${alt_script}"; then
            [[ "${SKIP_SERIAL}" -eq 0 ]] && capture_serial_brief
            return 0
        fi
        rc=$?
    fi

    [[ "${SKIP_SERIAL}" -eq 0 ]] && capture_serial_brief
    die "uuu failed (exit ${rc}). Last output:
$(tail -40 "${log_file}" 2>/dev/null || true)"
}

run_reference_nxp() {
    local nxp_script="${ROOT_DIR}/scripts/flash-imx95-nxp-reference.sh"
    local bundle_dir="${REFERENCE_NXP_DIR:-${HOME}/Downloads/LF_v6.18.2-1.0.0_images_IMX95}"
    [[ -x "${nxp_script}" ]] || die "Missing ${nxp_script}"
    log "NXP LF reference flash (bench validation, not Foundries LmP)"
    exec "${nxp_script}" --timeout "${UUU_TIMEOUT}" "${bundle_dir}"
}

main() {
    if [[ "${REFERENCE_NXP}" -eq 1 ]]; then
        run_reference_nxp
    fi
    if [[ "${REGEN_SCRIPTS}" -eq 1 ]]; then
        mkdir -p "${FLASH_DIR}"
        log "Regenerating UUU scripts in ${FLASH_DIR} (--regen-scripts; no fioctl needed) ..."
        regen_uuu_scripts
        log "Done. Run without --regen-scripts to flash (or use --prepare-only to review)."
        exit 0
    fi
    if ! artifacts_cached; then
        need_cmd fioctl
    fi
    prepare_bundle
    if [[ "${PREPARE_ONLY}" -eq 1 ]]; then
        log "Prepared ${FLASH_DIR} (--prepare-only; board not required)."
        log "Primary uuu WIC variant: $(wic_variant_label "${WIC_FB_NAME}")"
        log "Default uuu script: ${NXP_BOOT_UUU} (NXP ${NXP_FLASH_ALL_NAME} + LmP FB)."
        log "A/B test: fb-only-wic-compressed.uuu (.wic.gz) vs fb-only-wic-uncompressed.uuu (.wic)"
        log "Foundries debug: full_image.uuu (--foundries-boot); FB bootloader: ${PROD_BOOT_NAME}"
        exit 0
    fi
    run_uuu
    log "Done. Power off, exit Serial Download mode, set SW1 for ${FLASH_MEDIA} boot, re-power."
    if [[ "${FLASH_MEDIA}" == "emmc" ]]; then
        log "SW1: BOOT_MODE1=1, BOOT_MODE0=0 (eMMC). SPL serial: ${SERIAL_BAUD} on ttyACM0 (USB J3); Linux console ttyLP0 @ 115200."
    else
        log "SW1: BOOT_MODE1=1, BOOT_MODE0=1 (SD). Note: factory boot.cmd still targets eMMC (devnum 0)."
    fi
    log "Image: LmP imx95-frdm-evk (15x15 FRDM LPDDR4x), target ${TARGET}."
}

main "$@"
