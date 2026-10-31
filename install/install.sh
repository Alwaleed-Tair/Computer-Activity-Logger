#!/usr/bin/env bash
# =============================================================================
# install/install.sh — Enable automatic start for the current user (no root)
# -----------------------------------------------------------------------------
# 1. shows the consent notice and records consent (or use --accept)
# 2. installs a systemd *user* service (preferred) or an XDG autostart entry
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

ACCEPT=0
DAILY=0
for _arg in "$@"; do
    case $_arg in
        --accept) ACCEPT=1 ;;
        --with-daily-reports) DAILY=1 ;;
        *) echo "unknown option: $_arg" >&2; exit 1 ;;
    esac
done

# Consent first: nothing is enabled without it.
if (( ACCEPT == 1 )); then
    "$MAIN" consent --accept || exit 1
else
    "$MAIN" consent || exit 1
fi

render() { sed "s#@CAL_ROOT@#${CAL_ROOT}#g" "$1" >"$2"; }

if command -v systemctl >/dev/null 2>&1 && systemctl --user show-environment >/dev/null 2>&1; then
    unit_dir="${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user"
    mkdir -p "$unit_dir"
    render "$INSTALL_DIR/cal.service.template" "$unit_dir/cal.service"
    if (( DAILY == 1 )); then
        render "$INSTALL_DIR/cal-report.service.template" "$unit_dir/cal-report.service"
        render "$INSTALL_DIR/cal-report.timer.template" "$unit_dir/cal-report.timer"
    fi
    systemctl --user daemon-reload
    systemctl --user enable --now cal.service
    echo "Installed systemd user service: $unit_dir/cal.service"
    echo "It starts at your login and stops at your last logout."
    echo "(Optional: 'loginctl enable-linger $USER' to start at boot without logging in.)"
    if (( DAILY == 1 )); then
        systemctl --user enable --now cal-report.timer
        echo "Installed the daily report timer: $unit_dir/cal-report.timer"
        echo "Reports are written to $CAL_ROOT/reports/daily/  (check them with: ./main.sh report verify)"
    fi
else
    auto_dir="${XDG_CONFIG_HOME:-$HOME/.config}/autostart"
    mkdir -p "$auto_dir"
    render "$INSTALL_DIR/cal.desktop.template" "$auto_dir/cal.desktop"
    "$MAIN" start
    echo "systemd --user not available: installed XDG autostart entry $auto_dir/cal.desktop"
    if (( DAILY == 1 )); then
        echo "Daily reports need systemd --user. Run './main.sh report daily' yourself, or from cron."
    fi
fi
