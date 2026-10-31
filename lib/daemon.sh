#!/usr/bin/env bash
# =============================================================================
# lib/daemon.sh — The monitoring loop (ties all modules together)
# -----------------------------------------------------------------------------
# Error policy (important):
#   * No blanket `set -e`: a transient failure in one cycle must never kill
#     the daemon. Failures are logged and the cycle is skipped.
#   * An EXIT trap always runs daemon_finalize, so open processes and the open
#     session are written out even on SIGTERM or an unexpected error exit.
# =============================================================================

DAEMON_STOP=0
DAEMON_FINALIZED=0
DAEMON_EXIT_REASON=error_exit   # replaced when we are stopped by a signal
DAEMON_LAST_UP=0
DAEMON_CYCLES=0
DAEMON_LOCK_FD=""

# --- Single-instance lock ----------------------------------------------------

daemon_acquire_lock() {
    exec {DAEMON_LOCK_FD}>"$LOCK_FILE" || return 1
    flock -n "$DAEMON_LOCK_FD" || return 1
    printf '%s\n' "$$" >"$PID_FILE"
}

daemon_release_lock() {
    rm -f -- "$PID_FILE"
    if [[ -n $DAEMON_LOCK_FD ]]; then
        flock -u "$DAEMON_LOCK_FD" 2>/dev/null || true
    fi
    return 0
}

# daemon_is_running — true if another process holds the lock (used by the CLI).
daemon_is_running() {
    [[ -e $LOCK_FILE ]] || return 1
    if ( exec 9>"$LOCK_FILE"; flock -n 9 ) 2>/dev/null; then return 1; fi
    return 0
}

# --- Signals -----------------------------------------------------------------

# TERM/INT/HUP: ask the loop to stop; decide whether this is a system shutdown.
daemon_on_stop() {
    DAEMON_STOP=1
    if [[ $(systemctl is-system-running 2>/dev/null) == stopping ]]; then
        DAEMON_EXIT_REASON=shutdown
    else
        DAEMON_EXIT_REASON=logout
    fi
}

# USR1: persist state immediately (useful before inspecting files).
daemon_on_usr1() {
    storage_save_active || true
}

# --- One cycle ---------------------------------------------------------------

# daemon_flush_ended UPTIME EPOCH STATUS — write rows for everything in ENDED.
# Duration comes from the monotonic clock (start_mono), so it is immune to
# clock changes; End_Time is the detection time.
daemon_flush_ended() {
    local up=$1 now=$2 status=$3 entry dur
    if (( ${#ENDED[@]} == 0 )); then return 0; fi
    for entry in "${ENDED[@]}"; do
        ended_unpack "$entry"
        dur=$(( up - R_START_MONO ))
        if (( dur < 0 )); then dur=0; fi
        if (( dur < MIN_DURATION_SEC )); then continue; fi
        if storage_append_process "$entry" "$now" "$dur" "$status"; then :; fi
        SESSION_PROC_COUNT=$(( SESSION_PROC_COUNT + 1 ))
    done
    ENDED=()
    return 0
}

# daemon_cycle — snapshot, detect suspend gaps, diff, write, heartbeat.
daemon_cycle() {
    local up now delta pause
    if ! collector_snapshot; then
        log_warn "snapshot failed; skipping this cycle"
        return 0
    fi
    up=$COLLECTOR_UPTIME
    now=$COLLECTOR_EPOCH

    # Suspend / SIGSTOP detection: uptime keeps counting while we do not run.
    if (( DAEMON_LAST_UP > 0 )); then
        delta=$(( up - DAEMON_LAST_UP ))
        if (( delta > 3 * INTERVAL_SEC )); then
            pause=$(( delta - INTERVAL_SEC ))
            detector_add_pause "$pause"
            SESSION_PAUSED_TOTAL=$(( SESSION_PAUSED_TOTAL + pause ))
            log_info "gap of ${delta}s detected (suspend?) — ${pause}s counted as paused"
        fi
    fi
    DAEMON_LAST_UP=$up

    detector_diff
    daemon_flush_ended "$up" "$now" COMPLETED
    if (( ${#STARTED[@]} > 0 )) || (( ${#ENDED[@]} > 0 )) || [[ ! -f $ACTIVE_FILE ]]; then
        storage_save_active || log_warn "cannot save $ACTIVE_FILE"
    fi
    storage_write_heartbeat "$now" "$up" "$SESSION_BOOT" "$SESSION_ID" \
        "$SESSION_PROC_COUNT" "$SESSION_PAUSED_TOTAL" || log_warn "cannot write heartbeat"

    DAEMON_CYCLES=$(( DAEMON_CYCLES + 1 ))
    if (( DAEMON_CYCLES % 720 == 0 )); then
        storage_check_disk
        common_rotate_log
    fi
    return 0
}

# --- Shutdown ----------------------------------------------------------------

# daemon_finalize — runs once from the EXIT trap. Never loses open records.
daemon_finalize() {
    local up now
    if (( DAEMON_FINALIZED == 1 )); then return 0; fi
    DAEMON_FINALIZED=1
    trap '' TERM INT HUP USR1
    common_uptime up
    common_now_epoch now
    if (( SESSION_OPEN == 1 )); then
        detector_close_all
        daemon_flush_ended "$up" "$now" SESSION_END
        session_end "$DAEMON_EXIT_REASON" "$up" "$now"
        storage_flush_pending
        storage_clear_state
    fi
    daemon_release_lock
    return 0
}

# daemon_publish_state — write active.tsv + heartbeat right now (not only after the
# first cycle), so a death immediately after start-up still leaves a consistent state.
daemon_publish_state() {
    local up now
    common_uptime up; common_now_epoch now
    storage_save_active || log_warn "cannot save $ACTIVE_FILE"
    storage_write_heartbeat "$now" "$up" "$SESSION_BOOT" "$SESSION_ID" "$SESSION_PROC_COUNT" "$SESSION_PAUSED_TOTAL" || log_warn "cannot write heartbeat"
}

# --- Entry point -------------------------------------------------------------

daemon_run() {
    local tries=0
    consent_require || return 1
    storage_init || { log_err "cannot create data/state directories"; return 1; }
    storage_prepare_all || { log_err "cannot prepare the CSV files in $DATA_DIR"; return 1; }
    if ! daemon_acquire_lock; then
        log_info "another instance is already running — exiting"
        return 0
    fi

    trap 'common_on_err $? $LINENO "$BASH_COMMAND"' ERR
    trap daemon_on_stop TERM INT HUP
    trap daemon_on_usr1 USR1
    trap daemon_finalize EXIT

    common_sleep_init
    detector_load_lists
    detector_load_desktop
    common_rotate_log

    # Recovery needs a first snapshot (to know which old processes survive).
    until collector_snapshot; do
        tries=$(( tries + 1 ))
        if (( tries >= 3 )); then log_err "cannot take the first snapshot"; return 1; fi
        common_sleep 1
    done
    recovery_run
    session_begin || return 1
    daemon_publish_state
    common_uptime DAEMON_LAST_UP

    local t0 t1 delay
    while (( DAEMON_STOP == 0 )); do
        common_uptime t0
        daemon_cycle
        common_uptime t1
        delay=$(( INTERVAL_SEC - (t1 - t0) ))
        if (( delay < 1 )); then delay=1; fi
        if (( DAEMON_STOP == 0 )); then common_sleep "$delay"; fi
    done
    return 0
}
