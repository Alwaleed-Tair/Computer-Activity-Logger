#!/usr/bin/env bash
# =============================================================================
# install/install.sh — Enable automatic start for the current user (no root)
# -----------------------------------------------------------------------------
# 1. shows the consent notice and records consent (or use --accept)
# 2. installs a systemd *user* service (preferred) or an XDG autostart entry
# Usage: install/install.sh [--accept]
# =============================================================================
set -u -o pipefail

INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export CAL_ROOT="${INSTALL_DIR%/install}"
MAIN="$CAL_ROOT/main.sh"

# Consent first: nothing is enabled without it.
if [[ ${1:-} == --accept ]]; then
    "$MAIN" consent --accept || exit 1
else
    "$MAIN" consent || exit 1
fi

render() { sed "s#@CAL_ROOT@#${CAL_ROOT}#g" "$1" >"$2"; }

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$unit_dir"
    render "$INSTALL_DIR/cal.service.template" "$unit_dir/cal.service"
    systemctl --user daemon-reload
    systemctl --user enable --now cal.service
    echo "Installed systemd user service: $unit_dir/cal.service"
    echo "It starts at your login and stops at your last logout."
    echo "(Optional: 'loginctl enable-linger $USER' to start at boot without logging in.)"
else
    auto_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
    mkdir -p "$auto_dir"
    render "$INSTALL_DIR/cal.desktop.template" "$auto_dir/cal.desktop"
    "$MAIN" start
    echo "systemd --user not available: installed XDG autostart entry $auto_dir/cal.desktop"
fi
