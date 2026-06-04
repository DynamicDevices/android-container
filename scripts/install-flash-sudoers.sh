#!/usr/bin/env bash
# Install passwordless-sudo rules for uuu (Foundries imx95 flash).
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SRC="${ROOT_DIR}/config/sudoers.d/android-container-flash"
DST="/etc/sudoers.d/android-container-flash"

log() { printf '==> %s\n' "$*"; }
die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<'EOF'
Usage: install-flash-sudoers.sh [--link-bundled-uuu]

  Installs config/sudoers.d/android-container-flash to /etc/sudoers.d/
  and validates with visudo.

  --link-bundled-uuu  If downloads/.../uuu exists, symlink to /usr/local/bin/imx95-uuu
                      (stable path; optional if wildcard sudoers entry is enough).
EOF
}

uuu_nopasswd_ok() {
    local uuu_bin="$1" out
    [[ -x "${uuu_bin}" ]] || return 1
    out="$(env TERMINFO="${TERMINFO:-/usr/share/terminfo}" sudo -n "${uuu_bin}" -V 2>&1)" || true
    if [[ "${out}" == *"a password is required"* ]] || [[ "${out}" == *"password is required"* ]]; then
        return 1
    fi
    [[ "${out}" == *"Universal Update Utility"* ]] || [[ "${out}" == *"uuu ("* ]]
}

test_uuu_paths() {
    local -a candidates=()
    if command -v uuu >/dev/null 2>&1; then
        candidates+=("$(command -v uuu)")
    fi
    [[ -x /usr/local/bin/imx95-uuu ]] && candidates+=("/usr/local/bin/imx95-uuu")
    while IFS= read -r -d '' f; do
        candidates+=("$(readlink -f "${f}")")
    done < <(find "${ROOT_DIR}/downloads" -path '*/mfgtool-files-imx95-frdm-evk/uuu' -type f -executable -print0 2>/dev/null || true)
    while IFS= read -r -d '' f; do
        candidates+=("$(readlink -f "${f}")")
    done < <(find "${ROOT_DIR}/downloads" -path '*/flash-bundle/uuu' -type f -executable -print0 2>/dev/null || true)
    local meta_uuu="${ROOT_DIR}/../meta-dynamicdevices/build/tmp/deploy/images/imx95-frdm-evk/mfgtool-files/uuu"
    [[ -x "${meta_uuu}" ]] && candidates+=("$(readlink -f "${meta_uuu}")")

    local any_ok=0 u
    for u in "${candidates[@]}"; do
        [[ -n "${u}" ]] || continue
        if uuu_nopasswd_ok "${u}"; then
            log "OK: passwordless sudo for ${u}"
            any_ok=1
        else
            log "WARN: passwordless sudo failed for ${u} (not listed or wrong user?)"
        fi
    done
    [[ "${any_ok}" -eq 1 ]] || log "No uuu binary passed NOPASSWD test; check ${DST}"
}

LINK_BUNDLED=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --link-bundled-uuu) LINK_BUNDLED=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) die "Unknown option: $1" ;;
    esac
done

[[ -f "${SRC}" ]] || die "Missing ${SRC}"

if ! visudo -c -f "${SRC}" >/dev/null 2>&1; then
    log "Checking sudoers syntax (local file)..."
    visudo -c -f "${SRC}" || die "Invalid sudoers syntax in ${SRC}"
fi

log "Installing ${DST} (requires sudo password once)..."
sudo cp "${SRC}" "${DST}"
sudo chmod 0440 "${DST}"
sudo visudo -cf "${DST}" || die "visudo rejected ${DST}"

if [[ "${LINK_BUNDLED}" -eq 1 ]]; then
    bundled="$(find "${ROOT_DIR}/downloads" -path '*/mfgtool-files-imx95-frdm-evk/uuu' -type f -executable 2>/dev/null | head -1 || true)"
    if [[ -n "${bundled}" ]]; then
        bundled="$(readlink -f "${bundled}")"
        log "Linking ${bundled} -> /usr/local/bin/imx95-uuu"
        sudo ln -sf "${bundled}" /usr/local/bin/imx95-uuu
    else
        log "No bundled uuu found under downloads/; skip --link-bundled-uuu"
    fi
fi

log "Testing NOPASSWD for known uuu paths..."
test_uuu_paths

log "Done. Re-run ./scripts/flash-imx95-uuu-only.sh run TARGET without a sudo password prompt."
