#!/usr/bin/env bash
# Verify GUI sudo askpass setup for agent / Cursor integrated terminals.
set -euo pipefail

ROOT_DIR="$(cd "$(dirname "${BASH_SOURCE[0]}")/.." && pwd)"
ASKPASS="${ROOT_DIR}/scripts/sudo-askpass-gui.sh"

log() { printf '==> %s\n' "$*"; }
warn() { printf 'WARN: %s\n' "$*" >&2; }

usage() {
    cat <<EOF
Usage: install-sudo-askpass.sh [--check]

  Ensures scripts/sudo-askpass-gui.sh is executable and reports GUI askpass backends.

  Cursor / VS Code: terminal env is set in imx95-frdm.code-workspace (SUDO_ASKPASS).
  Shell-wide (optional): add to ~/.bashrc:

    export SUDO_ASKPASS="${ASKPASS}"
    export SSH_ASKPASS="${ASKPASS}"

  Agents and scripts must use:  sudo -A command   (not plain sudo)

  Limits:
    - Needs DISPLAY or WAYLAND_DISPLAY (GUI session). No dialog over pure SSH.
    - Fingerprint / polkit prompts are separate; askpass supplies password only.

  Optional passwordless ser2net (lab serial proxy):
    sudo cp config/sudoers.d/android-container-ser2net /etc/sudoers.d/
    sudo chmod 0440 /etc/sudoers.d/android-container-ser2net
    sudo visudo -cf /etc/sudoers.d/android-container-ser2net

  Test (expect a zenity password box):  sudo -A true
EOF
}

CHECK_ONLY=0
while [[ $# -gt 0 ]]; do
    case "$1" in
        --check) CHECK_ONLY=1; shift ;;
        -h|--help) usage; exit 0 ;;
        *) printf 'Unknown option: %s\n' "$1" >&2; usage; exit 1 ;;
    esac
done

[[ -f "${ASKPASS}" ]] || { printf 'Missing %s\n' "${ASKPASS}" >&2; exit 1; }
chmod +x "${ASKPASS}"

log "Askpass wrapper: ${ASKPASS}"
log "GUI backends on this host:"
found=0
for cmd in zenity ksshaskpass ssh-askpass-gnome yad; do
    if command -v "${cmd}" >/dev/null 2>&1; then
        log "  ${cmd}: $(command -v "${cmd}")"
        found=1
    else
        log "  ${cmd}: not installed"
    fi
done
[[ "${found}" -eq 1 ]] || warn "Install zenity: sudo apt install zenity"

log "Session display:"
log "  DISPLAY=${DISPLAY:-unset}"
log "  WAYLAND_DISPLAY=${WAYLAND_DISPLAY:-unset}"

if [[ -f "${ROOT_DIR}/imx95-frdm.code-workspace" ]]; then
    if grep -q 'SUDO_ASKPASS' "${ROOT_DIR}/imx95-frdm.code-workspace" 2>/dev/null; then
        log "Workspace already sets SUDO_ASKPASS in imx95-frdm.code-workspace"
    else
        warn "Add terminal.integrated.env.linux SUDO_ASKPASS to imx95-frdm.code-workspace"
    fi
fi

log ""
log "Use sudo -A for elevated commands from agents (example: sudo -A systemctl restart ser2net)"
log "Test: sudo -A true"

[[ "${CHECK_ONLY}" -eq 1 ]] && exit 0
