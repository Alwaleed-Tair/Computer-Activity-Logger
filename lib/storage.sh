#!/usr/bin/env bash
# =============================================================================
# lib/storage.sh — process CSV files and atomic state files
# -----------------------------------------------------------------------------
# processes.csv (exactly these 8 columns, one row per finished process):
#   Session_ID, PID, Process_Name, Username, Start_Time, End_Time,
#   Duration_Seconds, Status
#     Start_Time = the OS start time of the process (UTC), taken from its
#                  elapsed time — accurate even for processes that were already
#                  running when monitoring began.
#     End_Time   = when the monitor DETECTED that the process had ended (UTC);
#                  it can be late by up to one scan interval.
#     Status     = COMPLETED   seen ending while the monitor was running
#                  SESSION_END the monitor was stopped cleanly while it still ran
#                              (End_Time = stop time; the process may live on)
#                  RECOVERED   the monitor had died; at restart the process was
#                              gone (End_Time = last heartbeat, an estimate)
# process_details.csv — one companion row per processes.csv row with everything
#   else (PPID, command name, class, application group, CPU, memory, detection
#   times...). The pair (Session_ID, PID, Start_Time) is the unique key that
#   joins the two files.
#
# Guarantees
#   * Both CSVs are APPEND-ONLY: a row is written once, when the process ends,
#     and never rewritten. If the monitor dies, every earlier row is intact; the
#     processes that were running at that moment are kept in active.tsv and
#     finished by recovery.sh at the next start.
#   * One complete line per write, UTF-8 with BOM, header validated at start-up,
#     torn last lines repaired, foreign files moved aside (never overwritten).
#   * State files are written to <file>.tmp then renamed (atomic).
#   * If a write fails (e.g. disk full) the row is kept in memory and retried.
# =============================================================================

PROCESSES_HEADER='Session_ID,PID,Process_Name,Username,Start_Time,End_Time,Duration_Seconds,Status'
DETAILS_HEADER='Session_ID,PID,Start_Time,PPID,Command_Name,Class,App_Name,App_Instance,App_Root,Started_Before_Session,Detected_Start,Detected_End,Paused_Seconds,CPU_Seconds,Avg_CPU_Percent,Peak_RSS_KB,Last_RSS_KB,Category,Start_Epoch,End_Epoch'
PROCESS_STATUS_OK=" COMPLETED SESSION_END RECOVERED "

# Rows that could not be written yet: entries are "kind<TAB>line" (kind = processes|details).
declare -ga STORAGE_PENDING=()
STORAGE_PENDING_MAX=10000

# Create directories with private permissions.
storage_init() {
    umask 077
    common_ensure_dir "$DATA_DIR" "$STATE_DIR" "$REPORTS_DIR"
}

# --- CSV file hygiene ----------------------------------------------------------

# storage_prepare_csv FILE HEADER — make FILE safe to append to:
#   * missing/empty            -> created with BOM + header
#   * first line is not HEADER -> moved to FILE.invalid.<time> (data kept), new file
#   * last line has no newline -> newline added (so the next row can't glue to it)
storage_prepare_csv() {
    local file=$1 header=$2 first="" stamp
    if [[ -s $file ]]; then
        IFS= read -r first <"$file" || true
        first=${first#$'\xEF\xBB\xBF'}; first=${first%$'\r'}
        if [[ $first == "$header" ]]; then
            if [[ -n $(tail -c1 -- "$file" 2>/dev/null) ]]; then
                log_warn "$file did not end with a newline (torn write?) — repaired"
                printf '\n' >>"$file" || return 1
            fi
            return 0
        fi
        printf -v stamp '%(%s)T' -1
        mv -f -- "$file" "$file.invalid.$stamp" || return 1
        log_err "unexpected header in $file — moved to $file.invalid.$stamp"
    fi
    # UTF-8 BOM so Microsoft Excel shows non-ASCII text correctly.
    printf '\xEF\xBB\xBF%s\n' "$header" >"$file"
}

# storage_prepare_all — called once when the daemon starts.
storage_prepare_all() {
    storage_prepare_csv "$PROCESSES_FILE" "$PROCESSES_HEADER" || return 1
    storage_prepare_csv "$PROCESS_DETAILS_FILE" "$DETAILS_HEADER"
}

# storage_write_line KIND LINE — append one row; returns non-zero on failure.
storage_write_line() {
    local kind=$1 line=$2 file header
    if [[ $kind == processes ]]; then file=$PROCESSES_FILE; header=$PROCESSES_HEADER
    else file=$PROCESS_DETAILS_FILE; header=$DETAILS_HEADER; fi
    if [[ ! -s $file ]]; then storage_prepare_csv "$file" "$header" || return 1; fi
    printf '%s\n' "$line" >>"$file"
}

# storage_flush_pending — retry rows that failed earlier.
storage_flush_pending() {
    local -a still=()
    local entry kind line
    if (( ${#STORAGE_PENDING[@]} == 0 )); then return 0; fi
    for entry in "${STORAGE_PENDING[@]}"; do
        IFS=$'\t' read -r kind line <<<"$entry"
        if ! storage_write_line "$kind" "$line" 2>/dev/null; then still+=("$entry"); fi
    done
    STORAGE_PENDING=()
    if (( ${#still[@]} > 0 )); then STORAGE_PENDING=("${still[@]}"); fi
    return 0
}

# storage_append KIND LINE — write now, or queue for retry on failure.
storage_append() {
    local kind=$1 line=$2
    storage_flush_pending
    if storage_write_line "$kind" "$line" 2>/dev/null; then return 0; fi
    log_err "cannot write $kind row; queued for retry (${#STORAGE_PENDING[@]} pending)"
    if (( ${#STORAGE_PENDING[@]} < STORAGE_PENDING_MAX )); then
        STORAGE_PENDING+=("$kind"$'\t'"$line")
    fi
    return 1
}

# --- Process rows ----------------------------------------------------------------

# storage_append_process ENTRY END_EPOCH DURATION STATUS
#   ENTRY is an "ended" entry (metrics + record) from detector.sh.
storage_append_process() {
    local entry=$1 end_epoch=$2 dur=$3 status=$4
    local st et det seen avg tenths life eff_end rc=0
    case $PROCESS_STATUS_OK in *" $status "*) ;; *) log_err "invalid process status '$status'"; return 1 ;; esac
    ended_unpack "$entry"
    if (( dur < 0 )); then dur=0; fi
    common_fmt_ts st "$R_START_EPOCH"
    eff_end=$(( R_START_EPOCH + dur ))        # End_Time = Start_Time + Duration, always consistent
    common_fmt_ts et "$eff_end"
    common_fmt_ts det "$end_epoch"             # the wall-clock moment the end was detected
    common_fmt_ts seen "$R_SEEN"
    life=$dur; if (( life < 1 )); then life=1; fi
    tenths=$(( ${R_CPU:-0} * 1000 / life ))                 # average CPU %, one decimal
    printf -v avg '%d.%d' $(( tenths / 10 )) $(( tenths % 10 ))

    csv_row rnttrrnr "$R_SESSION" "$R_PID" "$R_COMM" "$R_USER" "$st" "$et" "$dur" "$status"
    storage_append processes "$REPLY" || rc=1
    csv_row rnrntrtrrrrrnnrnntnn \
        "$R_SESSION" "$R_PID" "$st" "$R_PPID" "$R_CMD" "$R_CLASS" "$R_APP" "$R_GROUP" "$R_ROOT" \
        "$R_PRE" "$seen" "$det" "$R_PAUSED" "${R_CPU:-0}" "$avg" "${R_RSS_PEAK:-0}" "${R_RSS_LAST:-0}" \
        "$R_CAT" "$R_START_EPOCH" "$eff_end"
    storage_append details "$REPLY" || rc=1
    return "$rc"
}

# storage_load_written_keys SESSION_ID... — fill WRITTEN_KEYS with the
# "session|pid|start" keys already present in processes.csv for those sessions.
# Used by recovery so a crash between "row written" and "state saved" can never
# produce a duplicate row.
declare -gA WRITTEN_KEYS=()
storage_load_written_keys() {
    local k ids
    WRITTEN_KEYS=()
    if [[ ! -s $PROCESSES_FILE ]] || (( $# == 0 )); then return 0; fi
    ids=$(printf '%s,' "$@")
    # Fields are counted from the END because Process_Name / Username are free text.
    while IFS= read -r k; do WRITTEN_KEYS[$k]=1; done < <(
        LC_ALL=C awk -F, -v ids=",${ids}" 'NR > 1 && NF >= 8 && index(ids, "," $1 ",") { print $1 "|" $2 "|" $(NF-3) }' \
            "$PROCESSES_FILE")
    return 0
}

# storage_purge_before YYYY-MM-DD — delete finished rows whose Start_Time is
# before the date, from both files (call only while the daemon is stopped).
# Prints the number of processes.csv rows removed.
storage_purge_before() {
    local cutoff=$1 n f tmp
    n=0
    if [[ -s $PROCESSES_FILE ]]; then
        n=$(LC_ALL=C awk -F, -v d="$cutoff" 'NR > 1 && NF >= 8 && substr($(NF-3), 1, 10) < d { c++ } END { print c + 0 }' "$PROCESSES_FILE")
        if (( n > 0 )); then
            tmp="$PROCESSES_FILE.tmp.$$"
            LC_ALL=C awk -F, -v d="$cutoff" 'NR == 1 || !(NF >= 8 && substr($(NF-3), 1, 10) < d)' "$PROCESSES_FILE" >"$tmp" \
                && mv -f -- "$tmp" "$PROCESSES_FILE"
        fi
    fi
    f=$PROCESS_DETAILS_FILE
    if [[ -s $f ]]; then
        tmp="$f.tmp.$$"
        LC_ALL=C awk -F, -v d="$cutoff" 'NR == 1 || !(NF >= 15 && substr($3, 1, 10) < d)' "$f" >"$tmp" && mv -f -- "$tmp" "$f"
    fi
    echo "$n"
}

# --- State files -----------------------------------------------------------------

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

# --- Verification ----------------------------------------------------------------

# storage_verify_processes — validate processes.csv and process_details.csv.
# Prints every problem ("<file>:line N: ...") and a summary; returns 1 on problems.
#   * header, field counts, numeric PID/duration, UTC timestamps, End >= Start
#   * Status in {COMPLETED, SESSION_END, RECOVERED}
#   * NO DUPLICATES: each (Session_ID, PID, Start_Time) may appear only once
#   * every details row must have its processes row (the reverse is only a warning)
storage_verify_processes() {
    local f first rc=0 out
    local -a vfiles=()
    for f in "$PROCESSES_FILE:$PROCESSES_HEADER" "$PROCESS_DETAILS_FILE:$DETAILS_HEADER"; do
        if [[ ! -e ${f%%:*} ]]; then continue; fi
        IFS= read -r first <"${f%%:*}" || true
        first=${first#$'\xEF\xBB\xBF'}; first=${first%$'\r'}
        if [[ $first != "${f#*:}" ]]; then echo "${f%%:*}:line 1: unexpected header"; rc=1; fi
    done
    if [[ ! -s $PROCESSES_FILE && ! -s $PROCESS_DETAILS_FILE ]]; then echo "0 process row(s), 0 problem(s)"; return "$rc"; fi
    if [[ -s $PROCESS_DETAILS_FILE ]]; then vfiles+=("$PROCESS_DETAILS_FILE"); fi
    if [[ -s $PROCESSES_FILE ]]; then vfiles+=("$PROCESSES_FILE"); fi
    out=$(LC_ALL=C awk -v pfile="$PROCESSES_FILE" "$AWK_LIB"'
        function bad(msg) { printf "%s:line %d: %s\n", (FILENAME == pfile ? "processes.csv" : "process_details.csv"), FNR, msg; errors++ }
        function dt(s) { return s ~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/ }
        FNR == 1 { next }
        FILENAME == pfile {
            rows++
            n = csv_split($0, f); if (n != 8) { bad("expected 8 fields, found " n); next }
            if (f[1] !~ /^[A-Za-z0-9._-]+$/) bad("invalid Session_ID \"" f[1] "\"")
            if (f[2] !~ /^[0-9]+$/) bad("PID is not numeric")
            if (f[3] == "") bad("empty Process_Name")
            if (f[4] == "") bad("empty Username")
            if (!dt(f[5]) || !dt(f[6])) bad("invalid Start_Time/End_Time")
            else if (f[6] < f[5]) bad("End_Time is before Start_Time")
            if (f[7] !~ /^[0-9]+$/) bad("Duration_Seconds is not a non-negative integer")
            if (f[8] !~ /^(COMPLETED|SESSION_END|RECOVERED)$/) bad("invalid Status \"" f[8] "\"")
            k = f[1] "|" f[2] "|" f[5]
            if (k in pk) bad("DUPLICATE record " k)
            pk[k] = 1
            next
        }
        {
            drows++
            n = csv_split($0, d); if (n != 20) { bad("expected 20 fields, found " n); next }
            k = d[1] "|" d[2] "|" d[3]
            if (k in dk) bad("DUPLICATE details record " k)
            dk[k] = 1
            if (d[6] !~ /^(User_Application|Background_Process)$/) bad("invalid Class \"" d[6] "\"")
            if (d[9] !~ /^(yes|no)$/) bad("invalid App_Root")
        }
        END {
            for (k in dk) if (!(k in pk)) { printf "process_details.csv: details row without a process row: %s\n", k; errors++ }
            for (k in pk) if (!(k in dk)) missing++
            printf "%d process row(s), %d details row(s), %d problem(s)%s\n", rows, drows, errors + 0, (missing ? sprintf(" (warning: %d process row(s) without details)", missing) : "")
            exit (errors > 0)
        }' "${vfiles[@]}" 2>&1) || rc=1
    printf '%s\n' "$out"
    return "$rc"
}
