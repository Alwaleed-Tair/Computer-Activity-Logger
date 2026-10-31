#!/usr/bin/env bash
# =============================================================================
# lib/recovery.sh — Repair after a crash, kill -9 or power loss
# -----------------------------------------------------------------------------
# A leftover $SESSION_FILE means the previous daemon never closed its session.
# We use the last heartbeat as the best estimate of "when it died":
#   * boot id changed  -> reboot / power loss  => Status POWER_LOSS
#   * boot id same     -> the daemon itself died => Status CRASHED
# The ACTIVE row in sessions.csv is UPDATED (end time = heartbeat), not
# duplicated. Any other ACTIVE row we cannot explain (state file lost) is
# marked INTERRUPTED with an empty end time.
# Tracked processes (active.tsv) are either:
#   * still alive (same boot, same start time) -> carried into the new session
#   * gone                                      -> closed at the heartbeat time
# Must run AFTER collector_snapshot (needs CUR) and BEFORE session_begin.
# =============================================================================

recovery_run() {
    local hb_epoch hb_up hb_boot hb_session hb_count hb_paused
    local same_boot=0 reason status rec dur c_start now_boot kept=0 closed=0

    if [[ ! -f $SESSION_FILE ]]; then
        storage_clear_state          # stray files without a session: discard
        sessionlog_reap_orphans ""   # ACTIVE rows nobody owns any more
        return 0
    fi
    if ! session_load_state; then
        log_warn "unreadable $SESSION_FILE — discarding"
        storage_clear_state
        sessionlog_reap_orphans ""
        return 0
    fi

    # Last sign of life (fall back to the session start if no heartbeat yet).
    hb_epoch=$RS_START_EPOCH; hb_up=$RS_START_MONO; hb_boot=$RS_BOOT
    hb_session=$RS_ID; hb_count=0; hb_paused=0
    if [[ -r $HEARTBEAT_FILE ]]; then
        read -r hb_epoch hb_up hb_boot hb_session hb_count hb_paused <"$HEARTBEAT_FILE" || true
    fi

    common_boot_id now_boot
    now_boot=${now_boot:0:8}
    if [[ $RS_BOOT == "$now_boot" ]]; then same_boot=1; reason=crash_recovered; else reason=power_loss_recovered; fi
    status=$(session_status_for "$reason")
    log_warn "recovering session $RS_ID (status=$status, last heartbeat epoch=$hb_epoch)"

    # 1) Tracked processes.
    if [[ -r $ACTIVE_FILE ]]; then
        while IFS= read -r rec || [[ -n $rec ]]; do
            if [[ -z $rec ]]; then continue; fi
            record_unpack "$rec"
            if (( same_boot == 1 )) && [[ -n ${CUR[$R_PID]+x} ]]; then
                IFS=$'\t' read -r _ _ c_start _ <<<"${CUR[$R_PID]}"
                if detector_same_process "$R_START_MONO" "$c_start"; then
                    R_PRE=yes                       # it predates the new session
                    record_pack
                    ACTIVE[$R_PID]=$REPLY
                    kept=$(( kept + 1 ))
                    continue
                fi
            fi
            dur=$(( hb_epoch - R_START_EPOCH ))     # wall clock: works across reboots
            if (( dur < 0 )); then dur=0; fi
            if (( dur >= MIN_DURATION_SEC )); then
                SESSION_ID=$RS_ID                   # attribute the row to the old session
                storage_append_process "$rec" "$hb_epoch" "$dur" recovered
                closed=$(( closed + 1 ))
            fi
        done <"$ACTIVE_FILE"
    fi

    # 2) The interrupted session: update its ACTIVE row in sessions.csv.
    dur=$(( hb_epoch - RS_START_EPOCH ))
    if (( dur < 0 )); then dur=0; fi
    sessionlog_close "$RS_ID" "$status" "$hb_epoch" "$RS_START_EPOCH" "$dur" \
        "${RS_USER:-$CAL_USER}" "${RS_UID:-$CAL_UID}" \
        || log_err "could not update interrupted session $RS_ID"

    storage_clear_state
    # 3) Anything else still ACTIVE has no owner.
    sessionlog_reap_orphans ""
    log_info "recovery done: $closed process rows closed, $kept still running"
    return 0
}
