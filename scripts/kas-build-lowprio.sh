#!/usr/bin/env bash
# Run kas-container at lower CPU/IO priority so interactive desktop work stays responsive.
#
# Usage (from meta-dynamicdevices checkout — canonical kas path for imx95 mfgtool):
#   ../android-container/scripts/kas-build-lowprio.sh build kas/imx95-frdm-evk-mfgtool.yml
#
# Or from android-container/ (script cds to sibling meta-dynamicdevices when present):
#   ./scripts/kas-build-lowprio.sh build kas/imx95-frdm-evk-mfgtool.yml
#
# Defaults: nice 15, ionice -c2 -n7 (best-effort / idle I/O). Override:
#   NICE_LEVEL=19 IONICE_LEVEL=7 ./scripts/kas-build-lowprio.sh build kas/...
#
# Common kas-container flags (included automatically):
#   --ssh-agent --ssh-dir ${HOME}/.ssh
#   --runtime-args "-v ${HOME}/yocto:/var/cache"
#
# imx95 mfgtool: run from meta-dynamicdevices; kas file is
# meta-dynamicdevices/kas/imx95-frdm-evk-mfgtool.yml (android-container/kas/ is a deprecated mount path).
#
# Already-running bitbake:
#   renice -n 15 -p $(pgrep -f '[b]itbake'); ionice -c2 -n7 -p $(pgrep -f '[b]itbake')
set -euo pipefail

SCRIPT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")" && pwd)"
CONTAINER_ROOT="$(cd "${SCRIPT_DIR}/.." && pwd)"

NICE_LEVEL="${NICE_LEVEL:-15}"
IONICE_CLASS="${IONICE_CLASS:-2}"
IONICE_LEVEL="${IONICE_LEVEL:-7}"
KAS_CACHE="${KAS_CACHE:-${HOME}/yocto}"
KAS_SSH_DIR="${KAS_SSH_DIR:-${HOME}/.ssh}"

META_DD="${META_DYNAMICDEVICES:-${CONTAINER_ROOT}/../meta-dynamicdevices}"
if [[ -d "${META_DD}" ]]; then
  cd "${META_DD}"
fi

if ! command -v kas-container >/dev/null 2>&1; then
  echo "kas-build-lowprio.sh: kas-container not found in PATH" >&2
  exit 1
fi

exec nice -n "${NICE_LEVEL}" ionice -c "${IONICE_CLASS}" -n "${IONICE_LEVEL}" \
  kas-container \
  --ssh-agent --ssh-dir "${KAS_SSH_DIR}" \
  --runtime-args "-v ${KAS_CACHE}:/var/cache" \
  "$@"
