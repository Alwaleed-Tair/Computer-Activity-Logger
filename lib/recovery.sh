#!/usr/bin/env bash
# =============================================================================
# lib/recovery.sh — Repair after a crash, kill -9 or power loss
# -----------------------------------------------------------------------------
# A leftover $SESSION_FILE means the previous daemon never closed its session.
# The last heartbeat is our best estimate of "when it died":
#   * boot id changed  -> reboot / power loss  => session Status POWER_LOSS
#   * boot id same     -> the daemon itself died => session Status CRASHED
# The ACTIVE row in sessions.csv is UPDATED (end time = heartbeat), not
# duplicated. Any other ACTIVE row we cannot explain is marked INTERRUPTED.
#
# Processes that were being tracked (active.tsv) are NOT treated as new:
#   * still alive (same boot, same PID *and* start time)
#         -> tracking CONTINUES with the original record: same Session_ID, same
#            true Start_Time, same "pre-session" flag. No row is written yet;
#            exactly one row will be written when it finally ends.
#   * gone (or PID now belongs to another process, or the machine rebooted)
#         -> one row, Status RECOVERED, End_Time = last heartbeat.
#   * already in processes.csv (the old daemon died between "row written" and
#     "state saved") -> skipped, so a restart can never duplicate a row.
# Anything that merely shows up in the first scan afterwards and is not in
# active.tsv is "found running", never "just started" (pre-session flag).
#
# Must run AFTER collector_snapshot (needs CUR_*) and BEFORE session_begin.
# =============================================================================

recovery_run() {
    local hb_epoch hb_up hb_boot hb_session hb_count hb_paused
    local same_boot=0 reason status rec dur key start_s now_boot kept=0 closed=0 dup=0
    local -a recs=()
    local -A sids=()

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
        mapfile -t recs <"$ACTIVE_FILE"
        for rec in "${recs[@]}"; do          # which sessions do they belong to?
            if [[ -z $rec ]]; then continue; fi
            record_unpack "$rec"; sids[$R_SESSION]=1
        done
        storage_load_written_keys "${!sids[@]}"
        for rec in "${recs[@]}"; do
            if [[ -z $rec ]]; then continue; fi
            record_unpack "$rec"
            common_fmt_ts start_s "$R_START_EPOCH"
            key="$R_SESSION|$R_PID|$start_s"
            if [[ -n ${WRITTEN_KEYS[$key]+x} ]]; then
                dup=$(( dup + 1 )); continue                # already written before the crash
            fi
            if (( same_boot == 1 )) && [[ -n ${CUR_START[$R_PID]+x} ]] \
                && detector_same_process "$R_START_MONO" "${CUR_START[$R_PID]}"; then
                detector_track_record "$rec"                # still alive: keep tracking, no new row
                kept=$(( kept + 1 ))
                continue
            fi
            dur=$(( hb_epoch - R_START_EPOCH ))             # wall clock: works across reboots
            if (( dur < 0 )); then dur=0; fi
            if (( dur >= MIN_DURATION_SEC )); then
                storage_append_process "0"$'\t'"0"$'\t'"0"$'\t'"$rec" "$hb_epoch" "$dur" RECOVERED
                closed=$(( closed + 1 ))
            fi
        done
    fi

    # 2) The interrupted session: update its ACTIVE row in sessions.csv.
    dur=$(( hb_epoch - RS_START_EPOCH ))
    if (( dur < 0 )); then dur=0; fi
    sessionlog_close "$RS_ID" "$status" "$hb_epoch" "$RS_START_EPOCH" "$dur" \
        "${RS_USER:-$CAL_USER}" "${RS_UID:-$CAL_UID}" \
        || log_err "could not update interrupted session $RS_ID"

    # Persist the re-attached processes IMMEDIATELY (atomic replace). session.state is
    # not deleted: session_begin() replaces it atomically, so at no moment is there a
    # live process table without a session file describing it.
    rm -f -- "$HEARTBEAT_FILE" "$HEARTBEAT_FILE.tmp"
    storage_save_active || log_err "cannot save $ACTIVE_FILE after recovery"
    # 3) Anything else still ACTIVE has no owner.
    sessionlog_reap_orphans ""
    log_info "recovery done: $closed finished (RECOVERED), $kept still running and re-attached, $dup already recorded"
    return 0
}
