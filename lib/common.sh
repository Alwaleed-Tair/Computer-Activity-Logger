#!/usr/bin/env bash
# =============================================================================
# lib/common.sh — Shared helpers (logging, time, CSV, sleep, directories)
# -----------------------------------------------------------------------------
# Design notes:
#   * Hot-path helpers write their result into a *named variable* (printf -v)
#     instead of echoing, so the daemon loop never forks a subshell.
#   * CSV helpers escape quotes and neutralise spreadsheet formula injection.
# =============================================================================

if [[ -n ${_CAL_COMMON_LOADED:-} ]]; then return 0; fi
_CAL_COMMON_LOADED=1

# --- Environment checks ------------------------------------------------------

# Require Bash >= 4.3 (associative arrays, printf %()T, nameref-free design).
common_require_bash() {
    if (( BASH_VERSINFO[0] < 4 )) || { (( BASH_VERSINFO[0] == 4 )) && (( BASH_VERSINFO[1] < 3 )); }; then
        echo "Bash >= 4.3 is required (found ${BASH_VERSION})" >&2
        return 1
    fi
    return 0
}

# --- Logging -----------------------------------------------------------------

# log_msg LEVEL MESSAGE...  — append to LOG_FILE; ERROR is also sent to stderr.
# CAL_VERBOSE=1 mirrors every message to stderr (useful in foreground mode).
log_msg() {
    local level=$1 ts line
    shift
    printf -v ts '%(%F %T)T' -1
    line="$ts [$level] [$$] $*"
    if [[ -n ${LOG_FILE:-} && -d ${LOG_FILE%/*} ]]; then
        printf '%s\n' "$line" >>"$LOG_FILE" 2>/dev/null || true
    fi
    if [[ ${CAL_VERBOSE:-0} == 1 || $level == ERROR ]]; then
        printf '%s\n' "$line" >&2
    fi
    return 0
}
log_info() { log_msg INFO "$@"; }
log_warn() { log_msg WARN "$@"; }
log_err()  { log_msg ERROR "$@"; }

# ERR trap handler: log only. It must never abort the daemon (no data loss).
common_on_err() {
    log_msg WARN "command failed (rc=$1) at line $2: $3"
    return 0
}

# Rotate the diagnostic log when it grows beyond LOG_MAX_BYTES.
common_rotate_log() {
    local size
    if [[ -f ${LOG_FILE:-} ]]; then
        size=$(stat -c %s "$LOG_FILE" 2>/dev/null || echo 0)
        if (( size > LOG_MAX_BYTES )); then
            mv -f "$LOG_FILE" "$LOG_FILE.1" 2>/dev/null || true
        fi
    fi
    return 0
}

# --- Time helpers (all write into the variable named by $1) -------------------

# common_now_epoch VAR  — wall-clock seconds since 1970.
common_now_epoch() { printf -v "$1" '%(%s)T' -1; }

# common_uptime VAR — whole seconds since boot (monotonic, unaffected by NTP).
common_uptime() {
    local _up _rest
    read -r _up _rest </proc/uptime || _up=0
    printf -v "$1" '%s' "${_up%.*}"
}

# common_fmt_ts VAR EPOCH — "YYYY-MM-DD HH:MM:SS" (recognised by Excel as a date).
common_fmt_ts() { printf -v "$1" '%(%F %T)T' "$2"; }

# common_fmt_hms VAR SECONDS — "HH:MM:SS" (hours may exceed 24).
common_fmt_hms() {
    local _s=$2
    if (( _s < 0 )); then _s=0; fi
    printf -v "$1" '%02d:%02d:%02d' $(( _s / 3600 )) $(( (_s % 3600) / 60 )) $(( _s % 60 ))
}

# common_boot_id VAR — kernel boot id (test hook: CAL_BOOT_ID_FILE).
common_boot_id() {
    local _id=unknown
    read -r _id <"${CAL_BOOT_ID_FILE:-/proc/sys/kernel/random/boot_id}" 2>/dev/null || true
    printf -v "$1" '%s' "$_id"
}

# --- Strings -----------------------------------------------------------------

# common_trim STRING — result in REPLY (leading/trailing whitespace removed).
common_trim() {
    local s=$1
    s="${s#"${s%%[![:space:]]*}"}"
    s="${s%"${s##*[![:space:]]}"}"
    REPLY=$s
}

# --- CSV ---------------------------------------------------------------------

# csv_row TYPES VALUE...  — build one CSV line into REPLY.
#   TYPES has one letter per value:
#     t = text   : control chars removed, quotes doubled, always quoted, and a
#                  leading = + - @ is prefixed with ' (blocks formula injection)
#     r = raw    : control chars removed, not quoted (dates, HH:MM:SS, fixed words)
#     n = number : must be an integer, otherwise replaced by 0
csv_row() {
    local types=$1 out="" i t v
    shift
    local -a vals=("$@")
    for (( i = 0; i < ${#types}; i++ )); do
        t=${types:i:1}
        v=${vals[i]-}
        case $t in
            n) if ! [[ $v =~ ^-?[0-9]+$ ]]; then v=0; fi ;;
            r) v=${v//[[:cntrl:]]/ } ;;
            *)
                v=${v//[[:cntrl:]]/ }
                case $v in [=+@-]*) v="'$v" ;; esac
                v=${v//\"/\"\"}
                v="\"$v\""
                ;;
        esac
        out+="${out:+,}$v"
    done
    REPLY=$out
}

# --- Filesystem / sleeping ---------------------------------------------------

# common_ensure_dir DIR... — create private directories (mode 700).
common_ensure_dir() {
    local d
    for d in "$@"; do
        mkdir -p -m 700 "$d" || return 1
    done
}

# common_sleep_init — open a private pipe so we can sleep with `read -t`
# (no fork, and it returns immediately when a signal trap fires).
common_sleep_init() {
    _CAL_SLEEP_FD=""
    if { exec {_CAL_SLEEP_FD}<> <(:); } 2>/dev/null; then
        return 0
    fi
    _CAL_SLEEP_FD=""
    return 0
}

# common_sleep SECONDS — interruptible sleep.
common_sleep() {
    if [[ -n ${_CAL_SLEEP_FD:-} ]]; then
        read -r -t "$1" -u "$_CAL_SLEEP_FD" _ || true
    else
        sleep "$1" &
        wait $! || true
    fi
    return 0
}
