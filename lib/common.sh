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

# common_rotate_file FILE — when FILE has grown beyond LOG_MAX_BYTES, keep it as FILE.1
# (one generation) and let the next writer start a fresh one.
common_rotate_file() {
    local f=${1-} size
    if [[ -n $f && -f $f ]]; then
        size=$(stat -c %s "$f" 2>/dev/null || echo 0)
        if (( size > LOG_MAX_BYTES )); then
            mv -f "$f" "$f.1" 2>/dev/null || true
        fi
    fi
    return 0
}

# Rotate the diagnostic log (cal.log).
common_rotate_log() { common_rotate_file "${LOG_FILE:-}"; }

# --- Time helpers (all write into the variable named by $1) -------------------

# common_now_epoch VAR  — wall-clock seconds since 1970.
common_now_epoch() { printf -v "$1" '%(%s)T' -1; }

# common_uptime VAR — whole seconds since boot (monotonic, unaffected by NTP).
common_uptime() {
    local _up _rest
    read -r _up _rest </proc/uptime || _up=0
    printf -v "$1" '%s' "${_up%.*}"
}

# common_fmt_ts VAR EPOCH — "YYYY-MM-DD HH:MM:SS" in UTC (Excel reads it as a date).
common_fmt_ts() { local _d _t; common_utc_date_time _d _t "$2"; printf -v "$1" "%s %s" "$_d" "$_t"; }

# --- UTC time (pure Bash arithmetic: no fork, no dependence on TZ) -------------
# All persisted timestamps are UTC. Local time is only a *display* concern
# (see `./main.sh sessions --local`).

# common_utc_date_time DATE_VAR TIME_VAR EPOCH
#   -> DATE_VAR="YYYY-MM-DD", TIME_VAR="HH:MM:SS" (UTC)
common_utc_date_time() {
    local __e=$3 __days __rem __z __era __doe __yoe __y __doy __mp __d __m
    if (( __e < 0 )); then __e=0; fi
    __days=$(( __e / 86400 )); __rem=$(( __e % 86400 ))
    # Civil-from-days (H. Hinnant's algorithm), valid for the whole Unix era.
    __z=$(( __days + 719468 )); __era=$(( __z / 146097 )); __doe=$(( __z - __era * 146097 ))
    __yoe=$(( (__doe - __doe / 1460 + __doe / 36524 - __doe / 146096) / 365 ))
    __y=$(( __yoe + __era * 400 ))
    __doy=$(( __doe - (365 * __yoe + __yoe / 4 - __yoe / 100) ))
    __mp=$(( (5 * __doy + 2) / 153 ))
    __d=$(( __doy - (153 * __mp + 2) / 5 + 1 ))
    if (( __mp < 10 )); then __m=$(( __mp + 3 )); else __m=$(( __mp - 9 )); fi
    if (( __m <= 2 )); then __y=$(( __y + 1 )); fi
    printf -v "$1" '%04d-%02d-%02d' "$__y" "$__m" "$__d"
    printf -v "$2" '%02d:%02d:%02d' $(( __rem / 3600 )) $(( __rem % 3600 / 60 )) $(( __rem % 60 ))
}

# common_utc_to_epoch VAR "YYYY-MM-DD" "HH:MM:SS" — inverse of the above (UTC).
# Returns 1 (VAR untouched) when the text is not a valid date/time.
common_utc_to_epoch() {
    local __y __m __d __hh __mm __ss __era __yoe __doy __doe __days __mp
    if ! [[ $2 =~ ^([0-9]{4})-([0-9]{2})-([0-9]{2})$ ]]; then return 1; fi
    __y=$(( 10#${BASH_REMATCH[1]} )); __m=$(( 10#${BASH_REMATCH[2]} )); __d=$(( 10#${BASH_REMATCH[3]} ))
    if ! [[ $3 =~ ^([0-9]{2}):([0-9]{2}):([0-9]{2})$ ]]; then return 1; fi
    __hh=$(( 10#${BASH_REMATCH[1]} )); __mm=$(( 10#${BASH_REMATCH[2]} )); __ss=$(( 10#${BASH_REMATCH[3]} ))
    if (( __m < 1 || __m > 12 || __d < 1 || __d > 31 || __hh > 23 || __mm > 59 || __ss > 59 )); then return 1; fi
    if (( __m <= 2 )); then __y=$(( __y - 1 )); fi
    __era=$(( __y / 400 )); __yoe=$(( __y - __era * 400 ))
    if (( __m > 2 )); then __mp=$(( __m - 3 )); else __mp=$(( __m + 9 )); fi
    __doy=$(( (153 * __mp + 2) / 5 + __d - 1 ))
    __doe=$(( __yoe * 365 + __yoe / 4 - __yoe / 100 + __doy ))
    __days=$(( __era * 146097 + __doe - 719468 ))
    printf -v "$1" '%s' $(( __days * 86400 + __hh * 3600 + __mm * 60 + __ss ))
}

# common_fmt_minutes VAR SECONDS — minutes with two decimals ("2.08").
common_fmt_minutes() {
    local _s=$2
    if (( _s < 0 )); then _s=0; fi
    printf -v "$1" '%d.%02d' $(( _s / 60 )) $(( (_s % 60) * 100 / 60 ))
}

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

# --- Awk helpers (shared by analyzer.sh and sessionlog.sh) ---------------------
# Prepended to every awk program: CSV parsing, hms formatting, date-range filter.
read -r -d '' AWK_LIB <<'AWK' || true
# Split one RFC-4180 CSV line into out[1..n]; returns n.
function csv_split(line, out,    n, i, len, c, f, inq) {
    split("", out); n = 0; f = ""; inq = 0; len = length(line)
    for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (inq) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { f = f "\""; i++ } else inq = 0
            } else f = f c
        } else if (c == "\"") inq = 1
        else if (c == ",") { out[++n] = f; f = "" }
        else f = f c
    }
    out[++n] = f
    return n
}
function hms(s) { return sprintf("%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
# Quote a text field for CSV output (and block formula injection).
function csvq(s) {
    if (s ~ /^[=+@-]/) s = "'" s
    gsub(/"/, "\"\"", s)
    return "\"" s "\""
}
# Safe identifiers (Session_ID) stay unquoted, exactly as in sessions.csv; anything else is quoted.
function idq(s) { return (s ~ /^[A-Za-z0-9._-]+$/) ? s : csvq(s) }
function in_range(d) { return !((from != "" && d < from) || (to != "" && d > to)) }
# --- UTC date arithmetic (pure integer maths: mawk has no mktime/strftime) ----
# days_from_civil(y, m, d) -> days since 1970-01-01   (y >= 1970 assumed)
function days_from_civil(y, m, d,   era, yoe, doy, doe) {
    if (m <= 2) y -= 1
    era = int(y / 400); yoe = y - era * 400
    doy = int((153 * (m > 2 ? m - 3 : m + 9) + 2) / 5) + d - 1
    doe = yoe * 365 + int(yoe / 4) - int(yoe / 100) + doy
    return era * 146097 + doe - 719468
}
# epoch("YYYY-MM-DD[ HH:MM:SS]") -> seconds since 1970 (UTC), or -1 if not a valid date
function epoch(s,   y, m, d, hh, mm, ss) {
    if (s !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]( [0-9][0-9]:[0-9][0-9]:[0-9][0-9])?$/) return -1
    y = substr(s, 1, 4) + 0; m = substr(s, 6, 2) + 0; d = substr(s, 9, 2) + 0
    if (y < 1970 || m < 1 || m > 12 || d < 1 || d > 31) return -1
    hh = 0; mm = 0; ss = 0
    if (length(s) == 19) { hh = substr(s, 12, 2) + 0; mm = substr(s, 15, 2) + 0; ss = substr(s, 18, 2) + 0 }
    if (hh > 23 || mm > 59 || ss > 59) return -1
    return days_from_civil(y, m, d) * 86400 + hh * 3600 + mm * 60 + ss
}
# dayname(days since 1970-01-01) -> "YYYY-MM-DD"
function dayname(di,   z, era, doe, yoe, y, doy, mp, d, m) {
    z = di + 719468; era = int(z / 146097); doe = z - era * 146097
    yoe = int((doe - int(doe / 1460) + int(doe / 36524) - int(doe / 146096)) / 365)
    y = yoe + era * 400; doy = doe - (365 * yoe + int(yoe / 4) - int(yoe / 100))
    mp = int((5 * doy + 2) / 153); d = doy - int((153 * mp + 2) / 5) + 1
    m = (mp < 10 ? mp + 3 : mp - 9); if (m <= 2) y += 1
    return sprintf("%04d-%02d-%02d", y, m, d)
}
# fmt_ts(epoch) -> "YYYY-MM-DD HH:MM:SS" (UTC)
function fmt_ts(e,   di, r) {
    di = int(e / 86400); r = e - di * 86400
    return dayname(di) sprintf(" %02d:%02d:%02d", int(r / 3600), int((r % 3600) / 60), r % 60)
}
# daykey(epoch, offset_seconds) -> the calendar day of that instant at UTC+offset
function daykey(e, off) { return dayname(int((e + off) / 86400)) }
# day_segments(a, b, off): split [a,b) at day boundaries (UTC+off). Fills the global
# arrays segd[] (day), sega[], segb[] and returns how many pieces there are.
function day_segments(a, b, off,   d0, d1, d, n, lo, hi) {
    n = 0
    if (b <= a) return 0
    d0 = int((a + off) / 86400); d1 = int((b - 1 + off) / 86400)
    if (d1 - d0 > 4000) return 0                      # absurd interval: ignore
    for (d = d0; d <= d1; d++) {
        lo = d * 86400 - off; hi = lo + 86400
        n++; segd[n] = dayname(d); sega[n] = (a > lo ? a : lo); segb[n] = (b < hi ? b : hi)
    }
    return n
}
AWK
