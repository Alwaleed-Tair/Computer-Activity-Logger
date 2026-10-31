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

# Returns 0 = lock taken, 1 = cannot open the lock file, 2 = another instance holds it.
# THE single-instance guarantee: a kernel flock on one file, released automatically when
# the holder dies (even by SIGKILL), so a crashed instance can never block the next one
# and two instances can never both run — whoever started them (service, autostart, shell).
daemon_acquire_lock() {
    exec {DAEMON_LOCK_FD}>"$LOCK_FILE" || return 1
    flock -n "$DAEMON_LOCK_FD" || return 2
    printf '%s\n' "$$" >"$PID_FILE"
}

# --- systemd notification (Type=notify) -----------------------------------------
# Under the systemd service the unit is "started" only when we say READY=1 (so
# `systemctl --user start` fails honestly if the logger refuses to run), and — if the
# unit sets WatchdogSec — we must report once per cycle; a hung loop is then killed and
# restarted by systemd. Outside systemd (NOTIFY_SOCKET unset) all of this is a no-op.
_NOTIFY_BIN=""
daemon_notify_init() {
    _NOTIFY_BIN=""
    if [[ -n ${NOTIFY_SOCKET:-} ]]; then _NOTIFY_BIN=$(command -v systemd-notify || true); fi
}
daemon_notify() { if [[ -n $_NOTIFY_BIN ]]; then "$_NOTIFY_BIN" "$@" >/dev/null 2>&1 || true; fi; return 0; }
# Watchdog heartbeat — only when systemd asked for it (WATCHDOG_USEC set for THIS process).
daemon_watchdog_ping() {
    if [[ -n ${WATCHDOG_USEC:-} && ( -z ${WATCHDOG_PID:-} || ${WATCHDOG_PID:-} == "$$" ) ]]; then
        daemon_notify WATCHDOG=1
    fi
    return 0
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
    daemon_notify --stopping "--status=saving the open session and processes"
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

# Exit status (also the exit code of `main.sh daemon`, which the systemd unit relies on):
#   0 clean stop · 1 failure (systemd restarts it) · EXIT_ALREADY_RUNNING (3) and
#   EXIT_NO_CONSENT (4): "do not retry" — the unit lists them in RestartPreventExitStatus.
daemon_run() {
    local tries=0 lock_rc
    daemon_notify_init
    consent_require || return "$EXIT_NO_CONSENT"
    storage_init || { log_err "cannot create data/state directories"; return 1; }
    # Take the lock BEFORE touching any data file, so a second instance cannot interfere.
    daemon_acquire_lock; lock_rc=$?
    case $lock_rc in
        0) ;;
        2) log_err "another instance of the logger is already running (pid $(cat "$PID_FILE" 2>/dev/null || echo '?')): this one exits and will not be restarted"
           return "$EXIT_ALREADY_RUNNING" ;;
        *) log_err "cannot open the lock file $LOCK_FILE"; return 1 ;;
    esac
    storage_prepare_all || { log_err "cannot prepare the CSV files in $DATA_DIR"; return 1; }

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
    # From here the logger is really recording: only now tell systemd it is READY.
    daemon_notify --ready "--status=session $SESSION_ID is recording (user $CAL_USER)"

    local t0 t1 delay
    while (( DAEMON_STOP == 0 )); do
        common_uptime t0
        daemon_cycle
        daemon_watchdog_ping
        common_uptime t1
        delay=$(( INTERVAL_SEC - (t1 - t0) ))
        if (( delay < 1 )); then delay=1; fi
        if (( DAEMON_STOP == 0 )); then common_sleep "$delay"; fi
    done
    return 0
}
