#!/usr/bin/env bash
# Verify ser2net matches minicom (/dev/ttyACM0 @ 115200). Run from android-container/.
set -euo pipefail

PORT="${SER2NET_PORT:-2000}"
DEV="/dev/ttyACM0"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARNING: %s\n' "$*" >&2; }
fail() { printf 'FAIL: %s\n' "$*" >&2; exit 1; }

log "ser2net check (expect same as minicom: ${DEV} @ 115200 8N1)"

if pgrep -x minicom >/dev/null; then
    fail "minicom is running — quit minicom first (only one process can use ${DEV})"
fi

systemctl is-active --quiet ser2net || fail "ser2net not active (sudo systemctl start ser2net)"

ss -tln | grep -q ":${PORT} " || fail "nothing listening on TCP ${PORT}"

[[ -e "${DEV}" ]] || fail "${DEV} missing — plug FRDM USB J3"

log "Installed drop-in:"
grep -E 'connector|accepter|enable' /etc/ser2net.d/imx95-ttyACM0.yaml 2>/dev/null | sed 's/^/  /'

log "Connect: nc localhost ${PORT}   (or telnet localhost ${PORT})"
log "Capturing 12s — power-cycle board now if console is quiet ..."
bytes=$(timeout 12 nc localhost "${PORT}" 2>/dev/null | wc -c | tr -d ' ')
log "Received ${bytes} bytes"

if [[ "${bytes}" -lt 20 ]]; then
    warn "Very little data — board idle, wrong port, or minicom held the device recently."
    warn "Compare: minicom -D ${DEV} -b 115200 (must be closed before ser2net works)."
    exit 1
fi

log "ser2net path looks OK."
