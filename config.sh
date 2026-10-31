#!/usr/bin/env bash
# =============================================================================
# config.sh — Central configuration for Computer Activity Logger
# -----------------------------------------------------------------------------
# This file is *sourced* by main.sh (never executed directly).
# Every value can be overridden from the environment, e.g.:
#     INTERVAL_SEC=2 ./main.sh start
# or permanently in an optional, git-ignored file: config.local.sh
# =============================================================================

# CAL_ROOT is set by main.sh before sourcing this file.
: "${CAL_ROOT:?config.sh must be sourced from main.sh (CAL_ROOT is not set)}"

# --- Identity / version ------------------------------------------------------
CAL_VERSION="0.6.1"
CAL_USER="${CAL_USER:-$(whoami)}"   # current user name (whoami)
CAL_UID="${CAL_UID:-$EUID}"                # numeric user id (UID)
CAL_HOST="${CAL_HOST:-$(hostname 2>/dev/null || echo unknown)}"

# --- Monitoring behaviour ----------------------------------------------------
# Seconds between process scans (1..60) — THE scan-period setting. Lower = more
# accurate end times and fewer missed short-lived processes, but more CPU.
# Processes that start AND end between two scans may be missed: this is a
# documented limitation of the polling approach.
INTERVAL_SEC="${INTERVAL_SEC:-5}"

# Processes observed for less than this many seconds are not written (0 = write
# every process that was caught, however short-lived).
MIN_DURATION_SEC="${MIN_DURATION_SEC:-0}"

# --- Paths -------------------------------------------------------------------
DATA_DIR="${DATA_DIR:-$CAL_ROOT/data}"           # raw CSV logs
REPORTS_DIR="${REPORTS_DIR:-$CAL_ROOT/reports}"  # generated reports
STATE_DIR="${STATE_DIR:-$CAL_ROOT/state}"        # runtime state (pid, heartbeat...)
CONF_DIR="${CONF_DIR:-$CAL_ROOT/conf}"           # ignore list / app map

# User lists: the real file wins, otherwise the shipped *.example is used.
IGNORE_FILE="${IGNORE_FILE:-$CONF_DIR/ignore.list}"
APPS_MAP_FILE="${APPS_MAP_FILE:-$CONF_DIR/apps.map}"
if [[ ! -r $IGNORE_FILE ]]; then IGNORE_FILE="$CONF_DIR/ignore.list.example"; fi
if [[ ! -r $APPS_MAP_FILE ]]; then APPS_MAP_FILE="$CONF_DIR/apps.map.example"; fi

# Proof of the user's explicit consent. Without it the daemon refuses to run.
CONSENT_FILE="${CONSENT_FILE:-$CAL_ROOT/.consent}"

# --- Runtime state files -----------------------------------------------------
LOCK_FILE="$STATE_DIR/daemon.lock"       # flock => single instance
PID_FILE="$STATE_DIR/daemon.pid"
SESSION_FILE="$STATE_DIR/session.state"  # the currently open session
ACTIVE_FILE="$STATE_DIR/active.tsv"      # processes currently being tracked
HEARTBEAT_FILE="$STATE_DIR/heartbeat"    # last time the daemon was alive
LOG_FILE="$STATE_DIR/cal.log"            # the program's own diagnostic log
LOG_MAX_BYTES="${LOG_MAX_BYTES:-1048576}"

# `./main.sh stop` waits this long for a clean stop, then forces it (SIGKILL). A forced
# stop is safe: the open session and processes are finished by recovery at the next start.
STOP_TIMEOUT_SEC="${STOP_TIMEOUT_SEC:-10}"

# --- Session log (sessions.csv) ----------------------------------------------
# ONE file for all sessions. A row is written when a session starts and is
# updated in place when it ends. Everything stored in it is UTC.
# Concurrent writers are serialised with flock on SESSIONS_LOCK.
SESSIONS_FILE="${SESSIONS_FILE:-$DATA_DIR/sessions.csv}"
SESSIONS_LOCK="${SESSIONS_LOCK:-$DATA_DIR/.sessions.lock}"

# --- Reports -----------------------------------------------------------------
# Excel stops at 1,048,576 rows per sheet. Longer reports are split into _part1, _part2...
REPORT_MAX_ROWS="${REPORT_MAX_ROWS:-1000000}"
REPORT_TOP="${REPORT_TOP:-20}"                         # rows in the "most used applications" list
REPORT_UTC_OFFSET_SEC="${REPORT_UTC_OFFSET_SEC:-0}"    # day boundaries of reports (0 = UTC; 10800 = +03:00)

# --- Automatic start (systemd --user service) --------------------------------
# The service runs as YOU (never root) and only while you have a systemd user manager
# (see README: this is "your login", not "the machine's boot").
SERVICE_NAME="${SERVICE_NAME:-cal}"                                   # unit name: cal.service
SERVICE_UNIT_DIR="${SERVICE_UNIT_DIR:-${XDG_CONFIG_HOME:-$HOME/.config}/systemd/user}"
SERVICE_ERROR_LOG="${SERVICE_ERROR_LOG:-$STATE_DIR/service-error.log}"  # stderr of the service, its own file
# Exit codes of `main.sh daemon` that systemd must NOT retry (see install/cal.service.template).
EXIT_ALREADY_RUNNING=3     # another instance holds the lock
EXIT_NO_CONSENT=4          # no consent on record

# --- Process log -------------------------------------------------------------
# processes.csv         : exactly 8 columns, one row per finished process
#                         (Session_ID,PID,Process_Name,Username,Start_Time,End_Time,
#                         Duration_Seconds,Status). Append-only: never rewritten, so a
#                         monitor crash cannot lose earlier rows.
# process_details.csv   : companion file with the rest (PPID, command name, class,
#                         application group, CPU, memory...), joined by
#                         Session_ID + PID + Start_Time.
PROCESSES_FILE="${PROCESSES_FILE:-$DATA_DIR/processes.csv}"
PROCESS_DETAILS_FILE="${PROCESS_DETAILS_FILE:-$DATA_DIR/process_details.csv}"

# .desktop directories used to recognise graphical applications (read-only).
DESKTOP_DIRS="${DESKTOP_DIRS:-/usr/share/applications:/usr/local/share/applications:$HOME/.local/share/applications}"

# --- Safety ------------------------------------------------------------------
MIN_FREE_MB="${MIN_FREE_MB:-50}"         # warn when free disk space drops below
RETENTION_DAYS="${RETENTION_DAYS:-365}"  # informational; purge is manual

# --- Optional local overrides (git-ignored) ----------------------------------
# config.local.sh is SOURCED (it runs as you): only accept it if you own it and nobody else can
# write to it, otherwise another user could run commands with your rights.
if [[ -r $CAL_ROOT/config.local.sh ]]; then
    _cfg_mode=$(stat -c %a -- "$CAL_ROOT/config.local.sh" 2>/dev/null || echo 777)
    if [[ -O $CAL_ROOT/config.local.sh && $(( 8#$_cfg_mode & 8#022 )) -eq 0 ]]; then
        # shellcheck source=/dev/null
        source "$CAL_ROOT/config.local.sh"
    else
        echo "config: ignoring $CAL_ROOT/config.local.sh (must be owned by you and not group/world-writable: chmod 600)" >&2
    fi
    unset _cfg_mode
fi

# -----------------------------------------------------------------------------
# config_validate — reject nonsensical values early (returns 1 on error).
# -----------------------------------------------------------------------------
config_validate() {
    local ok=0 _v
    # Plain decimal numbers only: "08" would be octal (an error) in arithmetic.
    for _v in INTERVAL_SEC MIN_DURATION_SEC STOP_TIMEOUT_SEC MIN_FREE_MB LOG_MAX_BYTES; do
        if [[ ${!_v-} =~ ^[0-9]+$ ]]; then printf -v "$_v" '%s' $(( 10#${!_v} )); fi
    done
    if ! [[ ${LOG_MAX_BYTES-} =~ ^[0-9]+$ ]]; then
        echo "config: LOG_MAX_BYTES must be a non-negative integer (got '${LOG_MAX_BYTES-}')" >&2
        ok=1
    fi
    if ! [[ $INTERVAL_SEC =~ ^[0-9]+$ ]] || (( INTERVAL_SEC < 1 || INTERVAL_SEC > 60 )); then
        echo "config: INTERVAL_SEC must be an integer between 1 and 60 (got '$INTERVAL_SEC')" >&2
        ok=1
    fi
    if ! [[ $MIN_DURATION_SEC =~ ^[0-9]+$ ]]; then
        echo "config: MIN_DURATION_SEC must be a non-negative integer (got '$MIN_DURATION_SEC')" >&2
        ok=1
    fi
    if ! [[ $REPORT_MAX_ROWS =~ ^[0-9]+$ ]] || (( REPORT_MAX_ROWS < 2 || REPORT_MAX_ROWS > 1048575 )); then
        echo "config: REPORT_MAX_ROWS must be between 2 and 1048575 (got '$REPORT_MAX_ROWS')" >&2
        ok=1
    fi
    if ! [[ $REPORT_TOP =~ ^[0-9]+$ ]] || ! [[ $REPORT_UTC_OFFSET_SEC =~ ^-?[0-9]+$ ]] || (( REPORT_UTC_OFFSET_SEC > 50400 || REPORT_UTC_OFFSET_SEC < -50400 )); then
        echo "config: REPORT_TOP must be a number and REPORT_UTC_OFFSET_SEC within +-50400" >&2
        ok=1
    fi
    if ! [[ $SERVICE_NAME =~ ^[A-Za-z0-9_.-]{1,60}$ ]]; then
        echo "config: SERVICE_NAME may only contain letters, digits, . _ - (got '$SERVICE_NAME')" >&2
        ok=1
    fi
    if ! [[ $STOP_TIMEOUT_SEC =~ ^[0-9]+$ ]] || (( STOP_TIMEOUT_SEC < 1 )); then
        echo "config: STOP_TIMEOUT_SEC must be a positive integer (got '$STOP_TIMEOUT_SEC')" >&2
        ok=1
    fi
    if ! [[ $MIN_FREE_MB =~ ^[0-9]+$ ]]; then
        echo "config: MIN_FREE_MB must be a non-negative integer (got '$MIN_FREE_MB')" >&2
        ok=1
    fi
    return "$ok"
}
