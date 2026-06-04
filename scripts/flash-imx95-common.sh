#!/usr/bin/env bash
# Shared paths for imx95 Foundries flash scripts (repo root = android-container).
# Source from scripts/*.sh or scripts/archive/*.sh — do not execute directly.

# Repo root: parent of scripts/ (never scripts/ itself — legacy prep wrote to scripts/downloads).
_imx95_scripts_dir="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
IMX95_REPO_ROOT="$(cd "${_imx95_scripts_dir}/.." && pwd)"
unset _imx95_scripts_dir

imx95_target_dl_dir() {
    printf '%s/downloads/target-%s\n' "${IMX95_REPO_ROOT}" "$1"
}

imx95_flash_bundle_dir() {
    printf '%s/flash-bundle\n' "$(imx95_target_dl_dir "$1")"
}

# One-time move if an older prep used ROOT_DIR=scripts/ (scripts/downloads/target-*).
imx95_migrate_legacy_downloads() {
    local target="$1"
    local legacy="${IMX95_REPO_ROOT}/scripts/downloads/target-${target}"
    local canonical="$(imx95_target_dl_dir "${target}")"
    [[ -d "${legacy}" ]] || return 0
    if [[ -e "${canonical}" ]]; then
        printf 'WARNING: legacy %s ignored (canonical %s exists)\n' "${legacy}" "${canonical}" >&2
        return 0
    fi
    mkdir -p "${IMX95_REPO_ROOT}/downloads"
    mv "${legacy}" "${canonical}"
    printf '==> Migrated %s -> %s\n' "${legacy}" "${canonical}"
}
