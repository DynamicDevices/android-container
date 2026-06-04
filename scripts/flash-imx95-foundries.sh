#!/usr/bin/env bash
# Stub — do not use for flashing. See flash-imx95-uuu-only.sh
set -euo pipefail
SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
FULL="${SCRIPT_DIR}/archive/flash-imx95-foundries.full.sh"

die() { printf 'ERROR: %s\n' "$*" >&2; exit 1; }

usage() {
    cat <<EOF
This script no longer runs uuu (it conflicted with ser2net and debugging).

Use instead:
  ./scripts/flash-imx95-uuu-only.sh check TARGET
  ./scripts/flash-imx95-uuu-only.sh prep TARGET
  ./scripts/flash-imx95-uuu-only.sh run TARGET

Bundle download/regen only (calls archived full script):
  $0 --prepare-only --emmc TARGET [FACTORY]
  $0 --regen-scripts --emmc TARGET
EOF
}

[[ -x "${FULL}" ]] || die "Missing ${FULL}"

while [[ $# -gt 0 ]]; do
    case "$1" in
        --prepare-only|--regen-scripts|-h|--help)
            exec "${FULL}" "$@"
            ;;
        --reference-nxp|--foundries-boot|--mfgtool-only)
            die "Archived: use scripts/archive/flash-imx95-foundries.full.sh explicitly if you really need it."
            ;;
    esac
    shift
done

usage
die "Pass --prepare-only or --regen-scripts, or use flash-imx95-uuu-only.sh"
