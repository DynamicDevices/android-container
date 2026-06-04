#!/usr/bin/env bash
# Capture FRDM boot log via ser2net (after flash). You power-cycle the board.
#   ./scripts/capture-frdm-serial.sh [seconds]
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
SEC="${1:-60}"
PORT="${SER2NET_PORT:-2000}"
LOG="${ROOT_DIR}/logs/frdm-serial-$(date +%Y%m%d-%H%M%S).log"

mkdir -p "${ROOT_DIR}/logs"
printf '==> ser2net localhost:%s (115200 on /dev/ttyACM0)\n' "${PORT}"
printf '==> SW1 eMMC boot (1,0). Power-cycle now. Capturing %ss → %s\n' "${SEC}" "${LOG}"
timeout "${SEC}" nc localhost "${PORT}" | tee "${LOG}" || true
printf '==> Saved: %s (%s bytes)\n' "${LOG}" "$(wc -c < "${LOG}" | tr -d ' ')"
