#!/usr/bin/env bash
# =============================================================================
# lib/service.sh — Automatic start through a systemd USER service
# -----------------------------------------------------------------------------
# Everything here runs as the current user. Nothing needs root, sudo or system-wide
# files: the unit lives in ~/.config/systemd/user/ and is driven with `systemctl --user`.
#
#   ./main.sh service install     write the unit file          (does not enable or start)
#   ./main.sh service enable      start it automatically at your login
#   ./main.sh service start|stop|restart
#   ./main.sh service status      state, restarts, last result, logs, login-vs-boot
#   ./main.sh service logs        the dedicated error log + the journal
#   ./main.sh service disable | uninstall
#
# Login is NOT boot. A user service is started by YOUR systemd user manager, which
# systemd starts at your first login (and stops at your last logout, unless lingering is
# on). So "the logger started" means "your user manager started" (or you started it) —
# not "the computer was switched on". `service status` prints both moments.
#
# Single instance: the daemon's kernel flock (daemon.lock) is the only authority. The
# service, autostart, and a shell `./main.sh start` all go through it, so two instances
# can never run; a second one exits with code 3, which the unit never retries.
# =============================================================================

SVC_WHY=""

# --- plumbing ------------------------------------------------------------------------

_svc_ctl() { systemctl --user "$@"; }
_svc_unit_name() { REPLY="$SERVICE_NAME.service"; }
_svc_unit_file() { REPLY="$SERVICE_UNIT_DIR/$SERVICE_NAME.service"; }

# service_available — can we talk to a systemd USER manager right now? Sets SVC_WHY if not.
service_available() {
    local out
    SVC_WHY=""
    if ! command -v systemctl >/dev/null 2>&1; then
        SVC_WHY="systemctl is not installed: this system does not use systemd"
        return 1
    fi
    if ! out=$(systemctl --user show-environment 2>&1); then
        SVC_WHY="no systemd user manager is reachable (${out%%$'\n'*}). A user manager exists only inside a login session; from 'su', a container or cron you may need: export XDG_RUNTIME_DIR=/run/user/$(id -u)"
        return 1
    fi
    return 0
}

# service_require — like service_available but prints the reason and the fallbacks.
service_require() {
    if service_available; then return 0; fi
    {
        echo "Cannot use the systemd user service: $SVC_WHY"
        echo "Alternatives that need no systemd: run it by hand with './main.sh start' (stop: './main.sh stop'),"
        echo "or use the desktop autostart entry created by install/install.sh when systemd is not available."
    } >&2
    return 1
}

_svc_installed() { local f; _svc_unit_file; f=$REPLY; [[ -f $f ]]; }
_svc_is_active() { _svc_ctl is-active --quiet "$SERVICE_NAME.service" 2>/dev/null; }

# --- rendering ---------------------------------------------------------------------------

# A path may contain spaces but nothing that cannot be written safely into a unit file.
_svc_check_path() {
    case $1 in
        /*) ;;
        *) echo "refusing a relative path in the unit file: $1" >&2; return 1 ;;
    esac
    if [[ $1 == *$'\n'* || $1 == *'"'* || $1 == *\\* ]]; then
        echo "refusing a path with a newline, quote or backslash in the unit file: $1" >&2
        return 1
    fi
}
# systemd expands %-specifiers in unit settings: double them so the path stays literal. (A "$" needs no
# escaping: variable substitution applies only to command ARGUMENTS, and we pass none that hold paths.) -> REPLY.
_svc_escape() { local p=$1; p=${p//%/%%}; REPLY=$p; }
# _svc_subst TEXT MARK VALUE -> REPLY — plain-text replacement (no regex, no & surprises).
_svc_subst() {
    local t=$1 m=$2 v=$3 out=""
    while [[ $t == *"$m"* ]]; do out+="${t%%"$m"*}$v"; t=${t#*"$m"}; done
    REPLY="$out$t"
}

# service_render — print the unit file for this installation.
service_render() {
    local tpl="$CAL_ROOT/install/cal.service.template" text root err consent types stop wd
    if [[ ! -r $tpl ]]; then echo "unit template not found: $tpl" >&2; return 1; fi
    _svc_check_path "$CAL_ROOT" && _svc_check_path "$SERVICE_ERROR_LOG" && _svc_check_path "$CONSENT_FILE" || return 1
    _svc_escape "$CAL_ROOT"; root=$REPLY
    _svc_escape "$SERVICE_ERROR_LOG"; err=$REPLY
    _svc_escape "$CONSENT_FILE"; consent=$REPLY
    stop=$(( STOP_TIMEOUT_SEC + 5 ))
    if command -v systemd-notify >/dev/null 2>&1; then
        # Ready only when really recording; a hung loop is killed and restarted by systemd.
        wd=$(( INTERVAL_SEC * 3 + 30 ))
        types=$'Type=notify\nNotifyAccess=all\nWatchdogSec='$wd
    else
        types="Type=simple"
    fi
    text=$(<"$tpl")
    _svc_subst "$text" "@TYPE_LINES@" "$types"; text=$REPLY
    _svc_subst "$text" "@CAL_ROOT@" "$root"; text=$REPLY
    _svc_subst "$text" "@ERROR_LOG@" "$err"; text=$REPLY
    _svc_subst "$text" "@CONSENT_FILE@" "$consent"; text=$REPLY
    _svc_subst "$text" "@STOP_TIMEOUT@" "$stop"; text=$REPLY
    _svc_subst "$text" "@SERVICE_NAME@" "$SERVICE_NAME"; text=$REPLY
    printf '%s\n' "$text"
}

# --- install / uninstall ------------------------------------------------------------------

service_install() {
    local unit tmpd rc=0 out
    if ! consent_is_granted; then
        echo "No consent on record for '$CAL_USER'. Run './main.sh consent' first: the service refuses to run without it." >&2
        return 1
    fi
    storage_init || return 1
    mkdir -p "$SERVICE_UNIT_DIR" || return 1
    _svc_unit_file; unit=$REPLY
    # Build and check the unit in a hidden directory next to its final place, then rename:
    # systemd never sees a half-written file.
    tmpd=$(mktemp -d "$SERVICE_UNIT_DIR/.install.XXXXXX") || return 1
    if ! service_render >"$tmpd/$SERVICE_NAME.service"; then rm -rf -- "$tmpd"; return 1; fi
    if command -v systemd-analyze >/dev/null 2>&1; then
        if ! out=$(systemd-analyze verify "$tmpd/$SERVICE_NAME.service" 2>&1); then
            echo "The generated unit file did not pass 'systemd-analyze verify':" >&2
            printf '%s\n' "$out" >&2
            rm -rf -- "$tmpd"; return 1
        fi
    fi
    mv -f -- "$tmpd/$SERVICE_NAME.service" "$unit" || rc=1
    rm -rf -- "$tmpd"
    if (( rc != 0 )); then return 1; fi
    echo "Installed: $unit"
    if service_available; then
        _svc_ctl daemon-reload
        if _svc_is_active; then echo "(The service is running with the previous unit file: './main.sh service restart' applies the new one.)"; fi
    else
        echo "Note: no systemd user manager is reachable now ($SVC_WHY)."
        echo "The file is in place and will be picked up by your user manager at your next login."
    fi
    # install.sh runs enable + start itself: do not tell the user to type them again.
    if [[ -z ${CAL_FROM_INSTALLER:-} ]]; then
        echo "Next: './main.sh service enable' (start automatically at login) and './main.sh service start'."
    fi
}

service_uninstall() {
    local unit
    _svc_unit_file; unit=$REPLY
    if service_available; then
        if _svc_is_active; then
            echo "Stopping the service first (it saves the open session)…"
            _svc_ctl stop "$SERVICE_NAME.service" || true
        fi
        _svc_ctl disable "$SERVICE_NAME.service" >/dev/null 2>&1 || true
        _svc_ctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    fi
    rm -f -- "$unit" "$SERVICE_UNIT_DIR/default.target.wants/$SERVICE_NAME.service"
    if service_available; then _svc_ctl daemon-reload || true; fi
    if daemon_is_running; then
        echo "A logger instance is still running (started by hand, pid $(cat "$PID_FILE" 2>/dev/null)): stop it with './main.sh stop'."
    fi
    echo "Uninstalled the service ($unit removed). Your data was kept in $DATA_DIR (delete it with './main.sh purge --all')."
}

service_enable() {
    service_require || return 1
    if ! _svc_installed; then echo "The service is not installed. Run: ./main.sh service install" >&2; return 1; fi
    _svc_ctl enable "$SERVICE_NAME.service" || return 1
    echo "Enabled: it will start whenever your systemd user manager starts (your login)."
    if [[ -z ${CAL_FROM_INSTALLER:-} ]]; then echo "It is not running yet in this session: './main.sh service start'."; fi
}

service_disable() {
    service_require || return 1
    _svc_ctl disable "$SERVICE_NAME.service" || return 1
    echo "Disabled: it will no longer start at login. A running instance keeps running until you stop it."
}

# --- start / stop / restart ----------------------------------------------------------------

# _svc_preflight — the checks shared by start and restart.
_svc_preflight() {
    service_require || return 1
    if ! _svc_installed; then echo "The service is not installed. Run: ./main.sh service install" >&2; return 1; fi
    if ! consent_is_granted; then
        echo "No consent on record for '$CAL_USER': the service would refuse to run. Run './main.sh consent' first." >&2
        return 1
    fi
    if ! _svc_is_active && daemon_is_running; then
        echo "A logger instance is already running outside the service (pid $(cat "$PID_FILE" 2>/dev/null || echo '?'), started with './main.sh start')." >&2
        echo "Stop it first with './main.sh stop' (it saves its data), then start the service. Two instances can never run at once." >&2
        return 1
    fi
    storage_init
}

# _svc_last_session — one line about the most recent session in sessions.csv.
_svc_last_session() {
    if [[ ! -s $SESSIONS_FILE ]]; then echo "no session recorded yet"; return 0; fi
    LC_ALL=C awk "$AWK_LIB"'NR > 1 { last = $0 } END { if (last == "") print "no session recorded yet"; else { csv_split(last, f); printf "session %s: %s%s", f[1], f[9], (f[8] != "" ? ", " f[8] " s" : "") } }' "$SESSIONS_FILE"
}

_svc_show_failure() {
    echo "--- last lines of the service error log ($SERVICE_ERROR_LOG):" >&2
    if [[ -s $SERVICE_ERROR_LOG ]]; then tail -n 8 "$SERVICE_ERROR_LOG" >&2; else echo "(empty)" >&2; fi
    echo "--- unit state:" >&2
    _svc_ctl show "$SERVICE_NAME.service" -p ActiveState -p SubState -p Result -p ExecMainStatus 2>&1 | sed 's/^/  /' >&2
    echo "More: './main.sh service logs'  ·  'journalctl --user -u $SERVICE_NAME'" >&2
}

service_start() {
    local out i
    _svc_preflight || return 1
    if _svc_is_active; then echo "Already running ($(_svc_last_session))."; return 0; fi
    _svc_ctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true      # clears a start-limit hit from earlier failures
    if ! out=$(_svc_ctl start "$SERVICE_NAME.service" 2>&1); then
        echo "Failed to start the service: $out" >&2
        _svc_show_failure
        return 1
    fi
    # Type=notify waits for READY; with Type=simple give the daemon a moment to take the lock.
    for (( i = 0; i < 50; i++ )); do
        if daemon_is_running; then break; fi
        sleep 0.2
    done
    if ! _svc_is_active || ! daemon_is_running; then
        echo "The service did not stay up." >&2
        _svc_show_failure
        return 1
    fi
    echo "Started: the logger is running as a user service ($(_svc_last_session))."
}

service_stop() {
    local pid
    service_require || return 1
    if ! _svc_is_active; then
        echo "The service is not running."
        if daemon_is_running; then echo "(A logger started by hand is running: './main.sh stop' stops that one.)"; fi
        return 0
    fi
    echo "Stopping (the open session and all tracked processes are saved first)…"
    if ! _svc_ctl stop "$SERVICE_NAME.service"; then
        echo "systemctl could not stop the service." >&2
        _svc_show_failure
        return 1
    fi
    if daemon_is_running; then
        pid=$(cat "$PID_FILE" 2>/dev/null || echo '?')
        echo "The service stopped, but a logger is still running (pid $pid) — it was not started by the service." >&2
        return 1
    fi
    echo "Stopped. $(_svc_last_session)"
}

service_restart() {
    local was_active=0
    _svc_preflight || return 1
    if _svc_is_active; then was_active=1; echo "Restarting: the current session is saved and closed, a NEW session starts."; fi
    _svc_ctl reset-failed "$SERVICE_NAME.service" >/dev/null 2>&1 || true
    if ! _svc_ctl restart "$SERVICE_NAME.service"; then
        echo "Restart failed." >&2
        _svc_show_failure
        return 1
    fi
    if ! _svc_is_active || ! daemon_is_running; then
        echo "The service did not come back." >&2
        _svc_show_failure
        return 1
    fi
    if (( was_active == 0 )); then echo "(It was not running; it has been started.)"; fi
    echo "Running: $(_svc_last_session)"
}

# --- status / logs --------------------------------------------------------------------------

# _svc_ago SECONDS -> REPLY "3 min 4 s"
_svc_ago() {
    local s=$1
    if (( s < 60 )); then REPLY="${s} s"
    elif (( s < 3600 )); then REPLY="$(( s / 60 )) min $(( s % 60 )) s"
    elif (( s < 86400 )); then REPLY="$(( s / 3600 )) h $(( s % 3600 / 60 )) min"
    else REPLY="$(( s / 86400 )) d $(( s % 86400 / 3600 )) h"; fi
}

# service_status — exit status like systemctl: 0 running · 3 installed but not running ·
# 4 not installed / no user manager.
service_status() {
    local unit k v since boot_epoch up now linger errn
    local -A S=()
    _svc_unit_file; unit=$REPLY
    echo "Computer Activity Logger — service status (user: $CAL_USER, uid $CAL_UID)"
    if [[ -f $unit ]]; then echo "  Unit file   : $unit"; else echo "  Unit file   : NOT installed (run: ./main.sh service install)"; fi
    if ! service_available; then
        echo "  systemd     : not reachable — $SVC_WHY"
        if daemon_is_running; then echo "  Logger      : RUNNING, pid $(cat "$PID_FILE" 2>/dev/null) (started by hand)"; else echo "  Logger      : not running"; fi
        return 4
    fi
    while IFS='=' read -r k v; do S[$k]=$v; done < <(_svc_ctl show "$SERVICE_NAME.service" \
        -p LoadState -p ActiveState -p SubState -p MainPID -p NRestarts -p Result -p ExecMainStatus -p ActiveEnterTimestamp -p UnitFileState 2>/dev/null)
    echo "  Enabled     : ${S[UnitFileState]:-unknown}$([[ ${S[UnitFileState]:-} == enabled ]] && echo '  (starts when your systemd user manager starts)')"
    echo "  State       : ${S[ActiveState]:-unknown} (${S[SubState]:-?})${S[ActiveEnterTimestamp]:+, since ${S[ActiveEnterTimestamp]}}"
    if [[ ${S[ActiveState]:-} == active && ${S[MainPID]:-0} != 0 ]]; then echo "  Main PID    : ${S[MainPID]}"; fi
    echo "  Restarts    : ${S[NRestarts]:-0} since the service was last started   ·   last result: ${S[Result]:-?} (exit status ${S[ExecMainStatus]:-?})"
    if daemon_is_running; then
        echo "  Logger      : RUNNING (pid $(cat "$PID_FILE" 2>/dev/null)); $(_svc_last_session)"
    else
        echo "  Logger      : not running; $(_svc_last_session)"
    fi
    if consent_is_granted; then echo "  Consent     : granted"; else echo "  Consent     : NOT granted (the service will not run)"; fi
    linger=$(loginctl show-user "$CAL_USER" -p Linger --value 2>/dev/null || true)
    case $linger in
        yes) echo "  Starts at   : BOOT (lingering is on: your user manager starts with the machine)" ;;
        no)  echo "  Starts at   : YOUR LOGIN (lingering is off) — not at machine boot, and it stops at your last logout" ;;
        *)   echo "  Starts at   : when your systemd user manager starts (normally your first login); lingering state unknown" ;;
    esac
    boot_epoch=$(awk '/^btime/ {print $2}' /proc/stat 2>/dev/null || true)
    if [[ $boot_epoch =~ ^[0-9]+$ ]]; then
        common_fmt_ts since "$boot_epoch"
        echo "  Machine boot: $since UTC  — a session's Login time is when the logger STARTED, which can be much later"
    fi
    errn=0; if [[ -f $SERVICE_ERROR_LOG ]]; then errn=$(grep -c "" "$SERVICE_ERROR_LOG" 2>/dev/null || true); fi; errn=${errn:-0}
    echo "  Error log   : $SERVICE_ERROR_LOG ($errn line(s))   ·   diagnostic log: $LOG_FILE"
    if [[ ${S[LoadState]:-} == not-found ]]; then return 4; fi
    if [[ ${S[ActiveState]:-} == active ]]; then return 0; fi
    return 3
}

service_logs() {
    local n=${1:-30}
    [[ $n =~ ^[0-9]+$ ]] || n=30
    echo "=== $SERVICE_ERROR_LOG (last $n lines)"
    if [[ -s $SERVICE_ERROR_LOG ]]; then tail -n "$n" "$SERVICE_ERROR_LOG"; else echo "(empty — no errors recorded)"; fi
    echo
    echo "=== journal of $SERVICE_NAME.service (last $n lines)"
    if command -v journalctl >/dev/null 2>&1 && journalctl --user -u "$SERVICE_NAME.service" -n "$n" --no-pager 2>/dev/null | grep -q .; then
        journalctl --user -u "$SERVICE_NAME.service" -n "$n" --no-pager 2>&1
    else
        echo "(no journal entries available for this user)"
    fi
}

# --- dispatcher -----------------------------------------------------------------------------

service_usage() {
    cat <<EOF
Usage: ./main.sh service <command>

  install     write the systemd user unit (~/.config/systemd/user/$SERVICE_NAME.service)
  enable      start automatically at your login        disable   stop doing that
  start       start now                                 stop      stop now (saves the data)
  restart     stop + start (a new session begins)       status    state, restarts, logs, login-vs-boot
  logs [N]    the service error log and the journal     show-unit print the unit file that would be installed
  uninstall   stop, disable and remove the unit (your data is kept)
EOF
}

service_main() {
    local cmd=${1:-help}
    if (( $# > 0 )); then shift; fi
    case $cmd in
        install)   service_install ;;
        uninstall) service_uninstall ;;
        enable)    service_enable ;;
        disable)   service_disable ;;
        start)     service_start ;;
        stop)      service_stop ;;
        restart)   service_restart ;;
        status)    service_status ;;
        logs)      service_logs "$@" ;;
        show-unit) service_render ;;
        help|--help|-h) service_usage ;;
        *) echo "unknown service command: $cmd" >&2; service_usage >&2; return 1 ;;
    esac
}
