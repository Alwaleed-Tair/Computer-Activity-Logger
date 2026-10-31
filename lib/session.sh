#!/usr/bin/env bash
# =============================================================================
# lib/session.sh — Lifecycle of one usage session
# -----------------------------------------------------------------------------
# A session = one run of the daemon (under systemd --user: first login ->
# last logout). Two things describe an open session:
#   * a row with Status=ACTIVE in sessions.csv      (lib/sessionlog.sh)
#   * $SESSION_FILE, a small private state file     (used by crash recovery)
# When the session ends the SAME csv row is updated to its final Status.
# =============================================================================

SESSION_ID=""
SESSION_BOOT=""
SESSION_START_EPOCH=0
SESSION_START_MONO=0
SESSION_PAUSED_TOTAL=0
SESSION_PROC_COUNT=0
SESSION_OPEN=0

# session_write_state — persist the static description of the open session.
session_write_state() {
    local tmp="$SESSION_FILE.tmp"
    {
        printf 'id=%s\n' "$SESSION_ID"
        printf 'user=%s\n' "$CAL_USER"
        printf 'uid=%s\n' "$CAL_UID"
        printf 'host=%s\n' "$CAL_HOST"
        printf 'boot=%s\n' "$SESSION_BOOT"
        printf 'start_epoch=%s\n' "$SESSION_START_EPOCH"
        printf 'start_mono=%s\n' "$SESSION_START_MONO"
        printf 'interval=%s\n' "$INTERVAL_SEC"
        printf 'pid=%s\n' "$$"
    } >"$tmp" || return 1
    mv -f "$tmp" "$SESSION_FILE"
}

# session_begin — open a new session: unique ID, user, UID, UTC start time.
# Calling it while a session is already open does nothing (no duplicate start).
session_begin() {
    if (( SESSION_OPEN == 1 )); then
        log_warn "session_begin called twice — ignoring (session $SESSION_ID is open)"
        return 0
    fi
    common_boot_id SESSION_BOOT
    SESSION_BOOT=${SESSION_BOOT:0:8}
    common_now_epoch SESSION_START_EPOCH
    common_uptime SESSION_START_MONO
    sessionlog_new_id SESSION_ID "$SESSION_START_EPOCH"
    SESSION_PAUSED_TOTAL=0
    SESSION_PROC_COUNT=0
    # Row first, state file second: if we die in between, the orphan row is
    # reaped (INTERRUPTED) on the next start; the reverse order would be worse.
    if ! sessionlog_start "$SESSION_ID" "$SESSION_START_EPOCH" "$CAL_USER" "$CAL_UID"; then
        log_err "could not record the session start in $SESSIONS_FILE (will retry at close)"
    fi
    session_write_state || { log_err "cannot write $SESSION_FILE"; return 1; }
    SESSION_OPEN=1
    log_info "session $SESSION_ID started (user=$CAL_USER uid=$CAL_UID interval=${INTERVAL_SEC}s)"
}

# session_load_state — read an (old) session file into RS_* variables.
session_load_state() {
    local key val
    RS_ID=""; RS_USER=""; RS_UID=""; RS_HOST=""; RS_BOOT=""; RS_START_EPOCH=0
    RS_START_MONO=0; RS_INTERVAL=$INTERVAL_SEC
    while IFS='=' read -r key val || [[ -n $key ]]; do
        case $key in
            id) RS_ID=$val ;;
            user) RS_USER=$val ;;
            uid) RS_UID=$val ;;
            host) RS_HOST=$val ;;
            boot) RS_BOOT=$val ;;
            start_epoch) RS_START_EPOCH=$val ;;
            start_mono) RS_START_MONO=$val ;;
            interval) RS_INTERVAL=$val ;;
        esac
    done <"$SESSION_FILE"
    [[ -n $RS_ID ]]
}

# session_status_for REASON — map a daemon exit reason to a sessions.csv Status.
session_status_for() {
    case $1 in
        logout|shutdown) echo COMPLETED ;;
        crash_recovered) echo CRASHED ;;
        power_loss_recovered) echo POWER_LOSS ;;
        *) echo ABORTED ;;
    esac
}

# session_end REASON UPTIME EPOCH — close the current session (updates its row).
# The duration comes from the monotonic clock, so it is immune to clock changes.
session_end() {
    local reason=$1 up=$2 now=$3 dur status
    if (( SESSION_OPEN == 0 )); then return 0; fi
    dur=$(( up - SESSION_START_MONO ))
    if (( dur < 0 )); then dur=0; fi
    status=$(session_status_for "$reason")
    sessionlog_close "$SESSION_ID" "$status" "$now" "$SESSION_START_EPOCH" "$dur" "$CAL_USER" "$CAL_UID" \
        || log_err "could not update session $SESSION_ID in $SESSIONS_FILE"
    SESSION_OPEN=0
    log_info "session $SESSION_ID closed (reason=$reason status=$status duration=${dur}s processes=$SESSION_PROC_COUNT)"
}
