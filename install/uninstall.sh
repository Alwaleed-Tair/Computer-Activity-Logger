#!/usr/bin/env bash
# =============================================================================
# install/uninstall.sh — Stop the logger and remove automatic start.
# Collected data (data/, reports/) is kept; delete it with: ./main.sh purge --all
# =============================================================================
set -u -o pipefail

INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
CAL_ROOT="${INSTALL_DIR%/install}"
CFG="${XDG_CONFIG_HOME:-$HOME/.config}"

# The service: stops it safely (saving the open session), disables and removes the unit.
"$CAL_ROOT/main.sh" service uninstall || true

# The optional daily-report timer and the autostart fallback.
if command -v systemctl >/dev/null 2>&1; then
    systemctl --user disable --now cal-report.timer 2>/dev/null || true
fi
rm -f -- "$CFG/systemd/user/cal-report.service" "$CFG/systemd/user/cal-report.timer" "$CFG/autostart/cal.desktop"
if command -v systemctl >/dev/null 2>&1; then systemctl --user daemon-reload 2>/dev/null || true; fi

# A logger started by hand (or by the autostart entry) is stopped too.
"$CAL_ROOT/main.sh" stop || true
echo "Automatic start removed. Your data was kept (see ./main.sh purge)."
