#!/usr/bin/env bash
# =============================================================================
# lib/storage.sh — CSV output and atomic state files
# -----------------------------------------------------------------------------
# Guarantees:
#   * CSVs are append-only, one complete line per write, UTF-8 with BOM.
#   * State files are written to <file>.tmp then renamed (atomic).
#   * If a write fails (e.g. disk full) the row is kept in memory and retried
#     on the next call, so a transient error does not lose records.
# =============================================================================

PROCESSES_HEADER='session_id,username,pid,ppid,app_name,process_name,category,start_time,end_time,start_epoch,end_epoch,duration_sec,duration_hms,paused_sec,active_sec,started_before_session,end_reason'
SESSIONS_HEADER='session_id,username,hostname,boot_id,start_time,end_time,start_epoch,end_epoch,duration_sec,duration_hms,paused_sec,end_reason,process_count,interval_sec,version'

# Rows that could not be written yet: entries are "kind<TAB>epoch<TAB>line".
declare -ga STORAGE_PENDING=()
STORAGE_PENDING_MAX=10000

# Create directories with private permissions.
storage_init() {
    umask 077
    common_ensure_dir "$DATA_DIR" "$STATE_DIR" "$REPORTS_DIR"
}

# storage_write_line KIND EPOCH LINE — append to the monthly file of KIND.
# Returns non-zero when the write failed.
storage_write_line() {
    local kind=$1 epoch=$2 line=$3 month file header
    printf -v month '%(%Y-%m)T' "$epoch"
    file="$DATA_DIR/${kind}_${month}.csv"
    if [[ $kind == processes ]]; then header=$PROCESSES_HEADER; else header=$SESSIONS_HEADER; fi
    if [[ ! -s $file ]]; then
        # UTF-8 BOM so Microsoft Excel shows non-ASCII text correctly.
        printf '\xEF\xBB\xBF%s\n' "$header" >"$file" || return 1
    fi
    printf '%s\n' "$line" >>"$file"
}

# storage_flush_pending — retry rows that failed earlier.
storage_flush_pending() {
    local -a still=()
    local entry kind epoch line
    if (( ${#STORAGE_PENDING[@]} == 0 )); then return 0; fi
    for entry in "${STORAGE_PENDING[@]}"; do
        IFS=$'\t' read -r kind epoch line <<<"$entry"
        if ! storage_write_line "$kind" "$epoch" "$line" 2>/dev/null; then
            still+=("$entry")
        fi
    done
    STORAGE_PENDING=()
    if (( ${#still[@]} > 0 )); then STORAGE_PENDING=("${still[@]}"); fi
    return 0
}

# storage_append KIND EPOCH LINE — write now, or queue for retry on failure.
storage_append() {
    local kind=$1 epoch=$2 line=$3
    storage_flush_pending
    if storage_write_line "$kind" "$epoch" "$line" 2>/dev/null; then
        return 0
    fi
    log_err "cannot write $kind row; queued for retry (${#STORAGE_PENDING[@]} pending)"
    if (( ${#STORAGE_PENDING[@]} < STORAGE_PENDING_MAX )); then
        STORAGE_PENDING+=("$kind"$'\t'"$epoch"$'\t'"$line")
    fi
    return 1
}

# storage_append_process RECORD END_EPOCH DURATION REASON
storage_append_process() {
    local rec=$1 end_epoch=$2 dur=$3 reason=$4
    local active st et dh pre=no
    record_unpack "$rec"
    active=$(( dur - R_PAUSED ))
    if (( active < 0 )); then active=0; fi
    common_fmt_ts st "$R_START_EPOCH"
    common_fmt_ts et "$end_epoch"
    common_fmt_hms dh "$dur"
    if [[ $R_PRE == yes ]]; then pre=yes; fi
    csv_row ttnntttrrnnnrnnrr \
        "$SESSION_ID" "$CAL_USER" "$R_PID" "$R_PPID" "$R_APP" "$R_COMM" "$R_CAT" \
        "$st" "$et" "$R_START_EPOCH" "$end_epoch" "$dur" "$dh" "$R_PAUSED" "$active" \
        "$pre" "$reason"
    storage_append processes "$end_epoch" "$REPLY"
}

# storage_append_session ID USER HOST BOOT START_EPOCH END_EPOCH DURATION PAUSED REASON COUNT
storage_append_session() {
    local id=$1 user=$2 host=$3 boot=$4 s_epoch=$5 e_epoch=$6 dur=$7 paused=$8 reason=$9 count=${10}
    local st et dh
    common_fmt_ts st "$s_epoch"
    common_fmt_ts et "$e_epoch"
    common_fmt_hms dh "$dur"
    csv_row ttttrrnnnrnrnnt \
        "$id" "$user" "$host" "$boot" "$st" "$et" "$s_epoch" "$e_epoch" \
        "$dur" "$dh" "$paused" "$reason" "$count" "$INTERVAL_SEC" "$CAL_VERSION"
    storage_append sessions "$e_epoch" "$REPLY"
}

# storage_save_active — atomically persist the tracked-process table.
storage_save_active() {
    local pid tmp="$ACTIVE_FILE.tmp"
    : >"$tmp" || return 1
    for pid in "${!ACTIVE[@]}"; do
        printf '%s\n' "${ACTIVE[$pid]}" >>"$tmp"
    done
    mv -f "$tmp" "$ACTIVE_FILE"
}

# storage_write_heartbeat EPOCH UPTIME BOOT SESSION COUNT PAUSED (atomic)
storage_write_heartbeat() {
    local tmp="$HEARTBEAT_FILE.tmp"
    printf '%s %s %s %s %s %s\n' "$1" "$2" "$3" "$4" "$5" "$6" >"$tmp" || return 1
    mv -f "$tmp" "$HEARTBEAT_FILE"
}

# Remove the live-state files after a clean shutdown / completed recovery.
storage_clear_state() {
    rm -f -- "$SESSION_FILE" "$ACTIVE_FILE" "$HEARTBEAT_FILE" \
        "$ACTIVE_FILE.tmp" "$HEARTBEAT_FILE.tmp" "$SESSION_FILE.tmp"
}

# storage_check_disk — warn when free space is below MIN_FREE_MB.
storage_check_disk() {
    local free_mb
    free_mb=$(df -Pm "$DATA_DIR" 2>/dev/null | awk 'NR==2 {print $4}')
    if [[ $free_mb =~ ^[0-9]+$ ]] && (( free_mb < MIN_FREE_MB )); then
        log_warn "low disk space: ${free_mb} MB free (< ${MIN_FREE_MB} MB)"
    fi
    return 0
}
