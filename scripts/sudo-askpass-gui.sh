#!/usr/bin/env bash
# GUI password prompt for sudo -A and SSH_ASKPASS (agent / non-interactive terminals).
# Requires DISPLAY or WAYLAND_DISPLAY; fingerprint auth still needs polkit (see README).
set -euo pipefail

# OpenSSH and some callers pass the prompt as argv
prompt="${1:-${SSH_ASKPASS_PROMPT:-${SUDO_ASKPASS_PROMPT:-Enter your password}}}"
title="${SSH_ASKPASS_TITLE:-${SUDO_ASKPASS_TITLE:-Authentication required}}"

ensure_display() {
    [[ -n "${DISPLAY:-}" || -n "${WAYLAND_DISPLAY:-}" ]] && return 0
    if command -v loginctl >/dev/null 2>&1; then
        local sess_display
        sess_display="$(loginctl show-user "$(id -un)" -p Display --value 2>/dev/null || true)"
        if [[ -n "${sess_display}" ]]; then
            export DISPLAY="${sess_display}"
            return 0
        fi
    fi
    export DISPLAY="${DISPLAY:-:0}"
}

ensure_display

askpass_zenity() {
    zenity --password --title="${title}" --text="${prompt}" 2>/dev/null
}

askpass_yad() {
    yad --title="${title}" --text="${prompt}" --entry-text="" --hide-text --button=OK:0 2>/dev/null
}

askpass_ksshaskpass() {
    SSH_ASKPASS_PROMPT="${prompt}" ksshaskpass 2>/dev/null
}

askpass_gnome() {
    ssh-askpass-gnome "${prompt}" 2>/dev/null
}

for backend in askpass_zenity askpass_ksshaskpass askpass_gnome askpass_yad; do
    case "${backend}" in
        askpass_zenity) command -v zenity >/dev/null || continue ;;
        askpass_ksshaskpass) command -v ksshaskpass >/dev/null || continue ;;
        askpass_gnome) command -v ssh-askpass-gnome >/dev/null || continue ;;
        askpass_yad) command -v yad >/dev/null || continue ;;
    esac
    if password="$("${backend}")"; then
        if [[ -n "${password}" ]]; then
            printf '%s' "${password}"
            exit 0
        fi
    fi
done

printf 'sudo-askpass-gui: no GUI askpass (DISPLAY=%s WAYLAND_DISPLAY=%s)\n' \
    "${DISPLAY:-unset}" "${WAYLAND_DISPLAY:-unset}" >&2
exit 1
