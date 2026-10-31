#!/usr/bin/env bash
# =============================================================================
# install/install.sh — Enable automatic start for the current user (no root)
# -----------------------------------------------------------------------------
# 1. shows the consent notice and records consent (or use --accept)
# 2. installs the systemd *user* service (preferred), enables it and starts it —
#    all through './main.sh service …', which you can also run step by step —
#    or, when no systemd user manager is available, an XDG autostart entry
# 3. optionally installs a systemd user TIMER that writes the daily reports
# Usage: install/install.sh [--accept] [--with-daily-reports]
#   --with-daily-reports  generate the daily Excel reports shortly after midnight
#                         (Persistent: a day missed while the computer was off is
#                         produced as soon as it is on again). systemd only.
# =============================================================================
set -u -o pipefail

INSTALL_DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
export CAL_ROOT="${INSTALL_DIR%/install}"
MAIN="$CAL_ROOT/main.sh"

usage() {
    echo "Usage: install/install.sh [--accept] [--with-daily-reports]"
    echo "  --accept              record consent without asking (you have read './main.sh consent')"
    echo "  --with-daily-reports  also install the daily report timer (systemd only)"
}

ACCEPT=0
DAILY=0
for _arg in "$@"; do
    case $_arg in
        --accept) ACCEPT=1 ;;
        --with-daily-reports) DAILY=1 ;;
        -h|--help) usage; exit 0 ;;
        *) echo "unknown option: $_arg" >&2; usage >&2; exit 1 ;;
    esac
done

# Consent first: nothing is installed or started without it.
if (( ACCEPT == 1 )); then
    "$MAIN" consent --accept || exit 1
else
    "$MAIN" consent || exit 1
fi

# render TEMPLATE OUTPUT — literal substitution of @CAL_ROOT@ ('%' doubled for systemd specifiers).
render() {
    local text root
    root=${CAL_ROOT//%/%%}
    case $CAL_ROOT in *\"*|*\\*|*$'\n'*) echo "unsupported characters in the install path: $CAL_ROOT" >&2; return 1 ;; esac
    text=$(<"$1")
    printf '%s\n' "${text//@CAL_ROOT@/$root}" >"$2"
}

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    "$MAIN" service install || exit 1
    "$MAIN" service enable || exit 1
    "$MAIN" service start || exit 1
    echo
    echo "Installed. It starts at YOUR LOGIN (not at machine boot) and stops at your last logout."
    echo "(Optional: 'loginctl enable-linger $USER' makes your user manager start at boot.)"
    echo "Status: './main.sh service status'   ·   Stop: './main.sh service stop'"
    if (( DAILY == 1 )); then
        unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
        render "$INSTALL_DIR/cal-report.service.template" "$unit_dir/cal-report.service" || exit 1
        render "$INSTALL_DIR/cal-report.timer.template" "$unit_dir/cal-report.timer" || exit 1
        systemctl --user daemon-reload
        systemctl --user enable --now cal-report.timer
        echo "Installed the daily report timer: $unit_dir/cal-report.timer"
        echo "Reports are written to $CAL_ROOT/reports/daily/  (check them with: ./main.sh report verify)"
    fi
else
    auto_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
    mkdir -p "$auto_dir"
    render "$INSTALL_DIR/cal.desktop.template" "$auto_dir/cal.desktop" || exit 1
    "$MAIN" start
    echo "systemd --user not available: installed XDG autostart entry $auto_dir/cal.desktop"
    if (( DAILY == 1 )); then
        echo "Daily reports need systemd --user. Run './main.sh report daily' yourself, or from cron."
    fi
fi
