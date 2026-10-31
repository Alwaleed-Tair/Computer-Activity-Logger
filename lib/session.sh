#!/usr/bin/env bash
# =============================================================================
# lib/session.sh — Lifecycle of one usage session
# -----------------------------------------------------------------------------
# A session = one run of the daemon (under systemd --user: first login ->
# last logout). While open it is described by $SESSION_FILE; when it closes
# (cleanly or via recovery) one row is appended to sessions_YYYY-MM.csv.
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
        printf 'host=%s\n' "$CAL_HOST"
        printf 'boot=%s\n' "$SESSION_BOOT"
        printf 'start_epoch=%s\n' "$SESSION_START_EPOCH"
        printf 'start_mono=%s\n' "$SESSION_START_MONO"
        printf 'interval=%s\n' "$INTERVAL_SEC"
        printf 'pid=%s\n' "$$"
    } >"$tmp" || return 1
    mv -f "$tmp" "$SESSION_FILE"
}

# session_begin — open a new session (records user + start time).
session_begin() {
    common_boot_id SESSION_BOOT
    SESSION_BOOT=${SESSION_BOOT:0:8}
    common_now_epoch SESSION_START_EPOCH
    common_uptime SESSION_START_MONO
    printf -v SESSION_ID '%(%Y%m%d-%H%M%S)T-%s' -1 "$$"
    SESSION_PAUSED_TOTAL=0
    SESSION_PROC_COUNT=0
    session_write_state || { log_err "cannot write $SESSION_FILE"; return 1; }
    SESSION_OPEN=1
    log_info "session $SESSION_ID started (user=$CAL_USER interval=${INTERVAL_SEC}s)"
}

# session_load_state — read an (old) session file into RS_* variables.
session_load_state() {
    local key val
    RS_ID=""; RS_USER=""; RS_HOST=""; RS_BOOT=""; RS_START_EPOCH=0
    RS_START_MONO=0; RS_INTERVAL=$INTERVAL_SEC
    while IFS='=' read -r key val || [[ -n $key ]]; do
        case $key in
            id) RS_ID=$val ;;
            user) RS_USER=$val ;;
            host) RS_HOST=$val ;;
            boot) RS_BOOT=$val ;;
            start_epoch) RS_START_EPOCH=$val ;;
            start_mono) RS_START_MONO=$val ;;
            interval) RS_INTERVAL=$val ;;
        esac
    done <"$SESSION_FILE"
    [[ -n $RS_ID ]]
}

# session_end REASON UPTIME EPOCH — close the current session and write its row.
session_end() {
    local reason=$1 up=$2 now=$3 dur
    if (( SESSION_OPEN == 0 )); then return 0; fi
    dur=$(( up - SESSION_START_MONO ))
    if (( dur < 0 )); then dur=0; fi
    storage_append_session "$SESSION_ID" "$CAL_USER" "$CAL_HOST" "$SESSION_BOOT" \
        "$SESSION_START_EPOCH" "$now" "$dur" "$SESSION_PAUSED_TOTAL" "$reason" "$SESSION_PROC_COUNT"
    SESSION_OPEN=0
    log_info "session $SESSION_ID closed (reason=$reason duration=${dur}s processes=$SESSION_PROC_COUNT)"
}
