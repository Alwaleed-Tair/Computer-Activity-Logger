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
CAL_VERSION="0.3.0"
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

# --- Session log (sessions.csv) ----------------------------------------------
# ONE file for all sessions. A row is written when a session starts and is
# updated in place when it ends. Everything stored in it is UTC.
# Concurrent writers are serialised with flock on SESSIONS_LOCK.
SESSIONS_FILE="${SESSIONS_FILE:-$DATA_DIR/sessions.csv}"
SESSIONS_LOCK="${SESSIONS_LOCK:-$DATA_DIR/.sessions.lock}"

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
if [[ -r $CAL_ROOT/config.local.sh ]]; then
    # shellcheck source=/dev/null
    source "$CAL_ROOT/config.local.sh"
fi

# -----------------------------------------------------------------------------
# config_validate — reject nonsensical values early (returns 1 on error).
# -----------------------------------------------------------------------------
config_validate() {
    local ok=0
    if ! [[ $INTERVAL_SEC =~ ^[0-9]+$ ]] || (( INTERVAL_SEC < 1 || INTERVAL_SEC > 60 )); then
        echo "config: INTERVAL_SEC must be an integer between 1 and 60 (got '$INTERVAL_SEC')" >&2
        ok=1
    fi
    if ! [[ $MIN_DURATION_SEC =~ ^[0-9]+$ ]]; then
        echo "config: MIN_DURATION_SEC must be a non-negative integer (got '$MIN_DURATION_SEC')" >&2
        ok=1
    fi
    if ! [[ $MIN_FREE_MB =~ ^[0-9]+$ ]]; then
        echo "config: MIN_FREE_MB must be a non-negative integer (got '$MIN_FREE_MB')" >&2
        ok=1
    fi
    return "$ok"
}
