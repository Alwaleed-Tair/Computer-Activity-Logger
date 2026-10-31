#!/usr/bin/env bash
# =============================================================================
# lib/sessionlog.sh — Session Logger: the sessions.csv file
# -----------------------------------------------------------------------------
# One row per usage session. Columns (exact order):
#   Session_ID, Username, User_ID, Login_Date, Login_Time,
#   Logout_Date, Logout_Time, Duration_Seconds, Status
#
# Life of a row
#   start  -> row appended with Status=ACTIVE and empty logout/duration fields
#   end    -> the SAME row is updated in place (never a second row)
#   crash  -> a later run closes the stale ACTIVE row (CRASHED / POWER_LOSS)
#
# Status values
#   ACTIVE        session is open right now
#   COMPLETED     clean logout / shutdown
#   ABORTED       the logger exited on an unexpected error, but saved its state
#   CRASHED       the logger died (kill -9, bug); end time = last heartbeat
#   POWER_LOSS    the machine rebooted/lost power; end time = last heartbeat
#   INTERRUPTED   open row found with no information about its end (times empty)
#
# Safety rules
#   * Every read-modify-write happens under an exclusive flock (SESSIONS_LOCK),
#     so concurrent writers cannot interleave or lose updates.
#   * Updates are written to a temp file in the same directory, checked (same
#     line count), then atomically renamed over the real file; the previous
#     version is kept as sessions.csv.bak.
#   * A file with an unexpected header is moved aside, never overwritten.
#   * Rows are never deleted by start/end/recovery (only `purge` removes rows).
#   * All stored times are UTC; local time is for display only.
# =============================================================================

SESSIONS_HEADER='Session_ID,Username,User_ID,Login_Date,Login_Time,Logout_Date,Logout_Time,Duration_Seconds,Status'
SESSION_STATUS_OK=" ACTIVE COMPLETED ABORTED CRASHED POWER_LOSS INTERRUPTED "

_SLOG_FD=""      # lock file descriptor
_SLOG_DEPTH=0    # re-entrancy counter (the lock is held once per process)

# --- Locking -----------------------------------------------------------------

# sessionlog_lock — take the exclusive lock (waits up to 15 s). Re-entrant.
sessionlog_lock() {
    if (( _SLOG_DEPTH > 0 )); then _SLOG_DEPTH=$(( _SLOG_DEPTH + 1 )); return 0; fi
    common_ensure_dir "${SESSIONS_LOCK%/*}" || return 1
    if ! { exec {_SLOG_FD}>>"$SESSIONS_LOCK"; } 2>/dev/null; then
        log_err "cannot open lock file $SESSIONS_LOCK"
        return 1
    fi
    if ! flock -x -w 15 "$_SLOG_FD"; then
        log_err "timeout waiting for $SESSIONS_LOCK"
        exec {_SLOG_FD}>&-
        return 1
    fi
    _SLOG_DEPTH=1
}

sessionlog_unlock() {
    if (( _SLOG_DEPTH == 0 )); then return 0; fi
    _SLOG_DEPTH=$(( _SLOG_DEPTH - 1 ))
    if (( _SLOG_DEPTH == 0 )); then exec {_SLOG_FD}>&-; fi
    return 0
}

# --- File preparation (call with the lock held) --------------------------------

# True when the first line of FILE is the expected header (BOM/CR tolerated).
sessionlog_header_ok() {
    local first=""
    IFS= read -r first <"$1" || [[ -n $first ]] || return 1
    first=${first#$'\xEF\xBB\xBF'}
    first=${first%$'\r'}
    [[ $first == "$SESSIONS_HEADER" ]]
}

# _sessionlog_prepare — make sure SESSIONS_FILE exists, has the right header
# and ends with a newline, so the next append can never glue onto a torn line.
_sessionlog_prepare() {
    local tmp stamp
    common_ensure_dir "${SESSIONS_FILE%/*}" || return 1
    if [[ -s $SESSIONS_FILE ]]; then
        if sessionlog_header_ok "$SESSIONS_FILE"; then
            chmod 600 -- "$SESSIONS_FILE" 2>/dev/null || true
            if [[ -n $(tail -c1 -- "$SESSIONS_FILE" 2>/dev/null) ]]; then
                log_warn "$SESSIONS_FILE did not end with a newline (torn write?) — repaired"
                printf '\n' >>"$SESSIONS_FILE" || return 1
            fi
            return 0
        fi
        # Unknown content: keep it, start a fresh file.
        printf -v stamp '%(%s)T' -1
        mv -f -- "$SESSIONS_FILE" "$SESSIONS_FILE.invalid.$stamp" || return 1
        log_err "unexpected header in $SESSIONS_FILE — moved to $SESSIONS_FILE.invalid.$stamp"
    fi
    tmp="$SESSIONS_FILE.tmp.$$"
    # UTF-8 BOM so Microsoft Excel shows non-ASCII text correctly.
    printf '\xEF\xBB\xBF%s\n' "$SESSIONS_HEADER" >"$tmp" || { rm -f -- "$tmp"; return 1; }
    mv -f -- "$tmp" "$SESSIONS_FILE"
}

# _sessionlog_has_id ID — true if a row with this Session_ID exists.
_sessionlog_has_id() {
    [[ -s $SESSIONS_FILE ]] || return 1
    LC_ALL=C awk -v id="$1" 'index($0, id ",") == 1 { f = 1; exit } END { exit !f }' "$SESSIONS_FILE"
}

# _sessionlog_append_row ID USER UID START_EPOCH END_EPOCH DURATION STATUS
# END_EPOCH / DURATION may be empty (open session).
_sessionlog_append_row() {
    local id=$1 user=$2 uid=$3 s=$4 e=$5 dur=$6 st=$7 ld lt od="" ot=""
    common_utc_date_time ld lt "$s"
    if [[ -n $e ]]; then common_utc_date_time od ot "$e"; fi
    csv_row rtnrrrrrr "$id" "$user" "$uid" "$ld" "$lt" "$od" "$ot" "$dur" "$st"
    printf '%s\n' "$REPLY" >>"$SESSIONS_FILE" || return 1
    sync -- "$SESSIONS_FILE" 2>/dev/null || true     # best effort: flush to disk
}

# _sessionlog_rewrite AWK_ARGS... — run awk over SESSIONS_FILE into a temp file,
# sanity-check it, keep a .bak, then atomically replace. Set _SLOG_SHRINK=1 to
# allow fewer lines (purge only).
_sessionlog_rewrite() {
    local tmp="$SESSIONS_FILE.tmp.$$" before after
    before=$(wc -l <"$SESSIONS_FILE")
    if ! LC_ALL=C awk "$@" "$SESSIONS_FILE" >"$tmp"; then
        rm -f -- "$tmp"; log_err "awk failed while rewriting $SESSIONS_FILE"; return 1
    fi
    after=$(wc -l <"$tmp")
    if [[ ${_SLOG_SHRINK:-0} != 1 ]] && (( before != after )); then
        rm -f -- "$tmp"
        log_err "refusing to replace $SESSIONS_FILE: line count changed ($before -> $after)"
        return 1
    fi
    cp -p -- "$SESSIONS_FILE" "$SESSIONS_FILE.bak" 2>/dev/null || true
    mv -f -- "$tmp" "$SESSIONS_FILE"
}

# --- Public API ----------------------------------------------------------------

# sessionlog_new_id VAR EPOCH — "20261031T111437Z-<pid>-<4 hex>", unique in the file.
sessionlog_new_id() {
    local _d _t _rnd _cand _try
    common_utc_date_time _d _t "$2"
    for (( _try = 0; _try < 10; _try++ )); do
        printf -v _rnd '%04x' $(( RANDOM ))
        _cand="${_d//-/}T${_t//:/}Z-$$-${_rnd}"
        if ! _sessionlog_has_id "$_cand"; then break; fi
    done
    printf -v "$1" '%s' "$_cand"
}

# sessionlog_start ID EPOCH [USER] [UID]
# Records the session start. Idempotent: an existing ID is never written twice.
sessionlog_start() {
    local id=$1 epoch=$2 user=${3:-$CAL_USER} uid=${4:-$CAL_UID} rc=0
    sessionlog_lock || return 1
    if _sessionlog_prepare; then
        if _sessionlog_has_id "$id"; then
            log_info "session $id is already recorded — start not duplicated"
        elif _sessionlog_append_row "$id" "$user" "$uid" "$epoch" "" "" ACTIVE; then
            log_info "session $id start recorded (ACTIVE)"
        else
            log_err "cannot append session $id to $SESSIONS_FILE"; rc=1
        fi
    else
        rc=1
    fi
    sessionlog_unlock
    return "$rc"
}

# sessionlog_close ID STATUS END_EPOCH [START_EPOCH] [DURATION] [USER] [UID]
# Updates the row of ID (it must be ACTIVE) with the end time, duration and
# final STATUS. DURATION empty => computed from the row's Login_* (UTC).
# If the row is missing, a complete closed row is appended (needs START_EPOCH)
# so the session is never lost. Closing twice is a harmless no-op.
sessionlog_close() {
    local id=$1 status=$2 end=$3 start=${4:-} dur=${5:-} user=${6:-$CAL_USER} uid=${7:-$CAL_UID}
    local info ldate ltime cur lod="" lot="" login_epoch rc=0
    case $SESSION_STATUS_OK in *" $status "*) ;; *) log_err "invalid session status '$status'"; return 1 ;; esac
    if [[ $status == ACTIVE ]]; then log_err "sessionlog_close called with ACTIVE"; return 1; fi

    sessionlog_lock || return 1
    if ! _sessionlog_prepare; then sessionlog_unlock; return 1; fi

    info=$(LC_ALL=C awk -F, -v id="$id" \
        'index($0, id ",") == 1 { print $(NF-5), $(NF-4), $NF; exit }' "$SESSIONS_FILE")

    if [[ $status != INTERRUPTED ]]; then common_utc_date_time lod lot "$end"; fi

    if [[ -z $info ]]; then
        # No row to update: append a complete one instead of losing the session.
        if [[ -z $start ]]; then
            log_err "session $id not found and no start time given — cannot close"; rc=1
        else
            if ! [[ $dur =~ ^[0-9]+$ ]]; then dur=$(( end - start )); fi
            if (( dur < 0 )); then dur=0; fi
            log_warn "session $id had no open row — appending a closed one"
            _sessionlog_append_row "$id" "$user" "$uid" "$start" "$end" "$dur" "$status" || rc=1
        fi
    else
        read -r ldate ltime cur <<<"$info"
        if [[ $cur != ACTIVE ]]; then
            log_info "session $id is already closed ($cur) — nothing to do"
        else
            if [[ $status == INTERRUPTED ]]; then
                dur=""
            elif ! [[ $dur =~ ^[0-9]+$ ]]; then
                if common_utc_to_epoch login_epoch "$ldate" "$ltime"; then dur=$(( end - login_epoch )); else dur=0; fi
                if (( dur < 0 )); then dur=0; fi
            fi
            _sessionlog_rewrite -F, -v OFS=, -v id="$id" -v lod="$lod" -v lot="$lot" \
                -v dur="$dur" -v st="$status" '
                !done && NF >= 9 && index($0, id ",") == 1 && $NF == "ACTIVE" {
                    $(NF-3) = lod; $(NF-2) = lot; $(NF-1) = dur; $NF = st; done = 1
                }
                { print }' || rc=1
            if (( rc == 0 )); then log_info "session $id closed (status=$status duration=${dur:-?}s)"; fi
        fi
    fi
    sessionlog_unlock
    return "$rc"
}

# sessionlog_reap_orphans [KEEP_ID] — every ACTIVE row except KEEP_ID belongs to a
# session that is not running any more (we hold the daemon lock, so nobody else
# can be logging). Mark them INTERRUPTED; their end is unknown, so it stays empty.
sessionlog_reap_orphans() {
    local keep=${1:-} n rc=0
    if [[ ! -s $SESSIONS_FILE ]]; then return 0; fi
    sessionlog_lock || return 1
    if _sessionlog_prepare; then
        n=$(LC_ALL=C awk -F, -v keep="$keep" \
            'NR > 1 && NF >= 9 && $NF == "ACTIVE" && (keep == "" || index($0, keep ",") != 1) { c++ } END { print c + 0 }' \
            "$SESSIONS_FILE")
        if (( n > 0 )); then
            log_warn "found $n orphaned ACTIVE session row(s) — marking INTERRUPTED"
            _sessionlog_rewrite -F, -v OFS=, -v keep="$keep" '
                NR > 1 && NF >= 9 && $NF == "ACTIVE" && (keep == "" || index($0, keep ",") != 1) {
                    $(NF-3) = ""; $(NF-2) = ""; $(NF-1) = ""; $NF = "INTERRUPTED"
                }
                { print }' || rc=1
        fi
    else
        rc=1
    fi
    sessionlog_unlock
    return "$rc"
}

# sessionlog_purge_before YYYY-MM-DD — delete CLOSED rows that logged in before
# the date (ACTIVE rows are always kept). Prints the number of removed rows.
sessionlog_purge_before() {
    local cutoff=$1 n rc=0
    if [[ ! -s $SESSIONS_FILE ]]; then echo 0; return 0; fi
    sessionlog_lock || return 1
    if _sessionlog_prepare; then
        n=$(LC_ALL=C awk -F, -v d="$cutoff" \
            'NR > 1 && NF >= 9 && $NF != "ACTIVE" && $(NF-5) < d { c++ } END { print c + 0 }' "$SESSIONS_FILE")
        if (( n > 0 )); then
            _SLOG_SHRINK=1 _sessionlog_rewrite -F, -v d="$cutoff" \
                'NR == 1 || !(NF >= 9 && $NF != "ACTIVE" && $(NF-5) < d) { print }' || rc=1
        fi
        echo "$n"
    else
        rc=1
    fi
    sessionlog_unlock
    return "$rc"
}

# sessionlog_verify [FILE] — validate the CSV structure. Prints every problem
# ("line N: ...") and a summary; returns 1 if anything is wrong.
sessionlog_verify() {
    local file=${1:-$SESSIONS_FILE}
    if [[ ! -f $file ]]; then echo "no such file: $file"; return 1; fi
    if ! sessionlog_header_ok "$file"; then echo "line 1: header differs from: $SESSIONS_HEADER"; return 1; fi
    LC_ALL=C awk "$AWK_LIB"'
        function bad(msg) { printf "line %d: %s\n", FNR, msg; errors++ }
        function valid_date(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9]$/ }
        function valid_time(s) { return s ~ /^[0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ }
        FNR == 1 { next }
        {
            rows++
            if ($0 == "") { bad("empty line"); next }
            n = csv_split($0, f)
            if (n != 9) { bad("expected 9 fields, found " n); next }
            if (f[1] !~ /^[A-Za-z0-9._-]+$/) bad("invalid Session_ID \"" f[1] "\"")
            if (f[1] in seen) bad("duplicate Session_ID " f[1])
            seen[f[1]] = 1
            if (f[2] == "") bad("empty Username")
            if (f[3] !~ /^[0-9]+$/) bad("User_ID is not numeric")
            if (!valid_date(f[4]) || !valid_time(f[5])) bad("invalid Login_Date/Login_Time")
            if (f[9] !~ /^(ACTIVE|COMPLETED|ABORTED|CRASHED|POWER_LOSS|INTERRUPTED)$/) { bad("invalid Status \"" f[9] "\""); next }
            if (f[9] == "ACTIVE") {
                if (f[6] != "" || f[7] != "" || f[8] != "") bad("ACTIVE row must have empty logout/duration")
                active++
            } else if (f[9] == "INTERRUPTED") {
                if (f[8] != "") bad("INTERRUPTED row must have empty duration")
            } else {
                if (!valid_date(f[6]) || !valid_time(f[7])) bad("invalid Logout_Date/Logout_Time")
                else if ((f[6] " " f[7]) < (f[4] " " f[5])) bad("logout is before login")
                if (f[8] !~ /^[0-9]+$/) bad("Duration_Seconds is not a non-negative integer")
            }
        }
        END {
            printf "%d row(s), %d active, %d problem(s)\n", rows, active + 0, errors + 0
            exit (errors > 0)
        }' "$file"
}
