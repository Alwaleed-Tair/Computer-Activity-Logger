#!/usr/bin/env bash
# =============================================================================
# lib/report.sh — Report Generator (Excel-ready CSV reports)
# -----------------------------------------------------------------------------
# Every report SET is three CSV files plus a manifest:
#   session_report.csv                Session Report            (logins, logouts, durations)
#   application_activity_report.csv   Application Activity      (every process: app, start, end, duration)
#   usage_summary_report.csv          Usage Summary             (totals, most used applications, daily, data quality)
#   report_manifest.csv               what was written, when, hashes, FINAL / PARTIAL
#
# Layout (never mixes time zones; the folder says which day boundaries were used):
#   reports/daily/UTC/2026-10-01/…            one set per calendar day   (UTC+0300 for +03:00)
#   reports/period/UTC/<name>/…               one set for any period
#   reports/<…>/revisions/<created>/…         older versions kept when a FINAL set had to change
#   reports/report_log.csv                    append-only audit log (GENERATED / REPLACED)
#
# Excel compatibility (checked by `report verify`, and opened with a real spreadsheet
# program in the tests): UTF-8 with BOM, CRLF line endings (RFC 4180), one header row,
# a constant number of columns, quotes doubled inside cells, dates as "YYYY-MM-DD
# HH:MM:SS", numbers as plain numbers, cells starting with = + - @ neutralised (no
# formula injection), cells <= 32,767 characters, and at most REPORT_MAX_ROWS rows per
# file (longer reports are split into _part1, _part2… with the header repeated).
#
# History is respected
#   * A FINAL set (the day is over and nothing is still open) is FROZEN: a normal run
#     skips it without even recomputing it. --refresh recomputes it and replaces it only
#     if its content really changed; --force always rewrites it. Whenever a FINAL set is
#     replaced, the old files are kept under revisions/.
#   * A PARTIAL set (today, or a day with an open session) is regenerated whenever its
#     content changes — and left alone when it did not.
#   * Every file carries Report_Created_UTC. An unchanged report keeps its original date.
#
# Safe writing
#   * One generator at a time (flock on reports/.report.lock).
#   * Everything is built in a hidden staging directory on the same filesystem, never in
#     place; each file is flushed (sync) and moved into position with an atomic rename, so
#     a reader sees the old or the new file, never half of one.
#   * The manifest (with SHA-256 of every file) is renamed LAST: a crash mid-publish leaves
#     a manifest that no longer matches, `report verify` reports it and the next run repairs.
#   * Leftover staging directories from a crash are removed on the next run.
# =============================================================================

RG_MANIFEST_NAME="report_manifest.csv"
RG_HDR_SESSION='Report_Created_UTC,Session_ID,Username,User_ID,Login_UTC,Logout_UTC,Status,Duration_Quality,Duration_Seconds,Duration_Minutes,Duration_HMS,Seconds_In_Period,Started_In_Period,Processes,User_App_Launches,Background_Processes,Completed_Processes,Incomplete_Processes,Distinct_User_Apps'
RG_HDR_ACTIVITY='Report_Created_UTC,Session_ID,PID,Process_Name,Application,Class,Is_Group_Root,Start_Time_UTC,End_Time_UTC,Duration_Seconds,Duration_HMS,Seconds_In_Period,Started_In_Period,Status,Natural_End,Started_Before_Monitoring,CPU_Seconds,Note'
RG_HDR_SUMMARY='Report_Created_UTC,Period_From,Period_To,UTC_Offset,Report_Status,Section,Rank,Item,Value,Unit,Launches,Processes,Percent_Of_Session_Time,Note'
RG_HDR_MANIFEST='File,Rows,Bytes,SHA256,Report_Created_UTC,Report_Status,Report_Kind,Period_From,Period_To,UTC_Offset,Content_Fingerprint,Generator_Version'
RG_HDR_LOG='Event_UTC,Event,Kind,Period,UTC_Offset,Report_Status,Path,Content_Fingerprint,Files,Archived_As'
RG_KINDS=(session_report application_activity_report usage_summary_report)

_RG_FD=""; _RG_DEPTH=0          # report lock
RG_FILES=()                     # files produced by the last _rg_emit_all, in manifest order
RG_FINGERPRINT=""

# --- small helpers -------------------------------------------------------------------

# _rg_now VAR — current epoch (tests may pin it with CAL_NOW_EPOCH).
_rg_now() {
    if [[ ${CAL_NOW_EPOCH:-} =~ ^[0-9]+$ ]]; then printf -v "$1" '%s' "$CAL_NOW_EPOCH"; else printf -v "$1" '%(%s)T' -1; fi
}

# report_tz_label OFFSET_SECONDS — "UTC", "UTC+0300", "UTC-0530" (folder-safe, no colon) -> REPLY.
report_tz_label() {
    local o=$1 sign=+ a
    if (( o == 0 )); then REPLY=UTC; return 0; fi
    if (( o < 0 )); then sign=-; a=$(( -o )); else a=$o; fi
    printf -v REPLY 'UTC%s%02d%02d' "$sign" $(( a / 3600 )) $(( a % 3600 / 60 ))
}

# report_offset_text OFFSET_SECONDS — "UTC+03:00" -> REPLY (never a leading + : Excel could read that as a formula).
report_offset_text() {
    local o=$1 sign=+ a
    if (( o < 0 )); then sign=-; a=$(( -o )); else a=$o; fi
    printf -v REPLY 'UTC%s%02d:%02d' "$sign" $(( a / 3600 )) $(( a % 3600 / 60 ))
}

# _rg_lock / _rg_unlock — one generator at a time (re-entrant inside a process).
_rg_lock() {
    if (( _RG_DEPTH > 0 )); then _RG_DEPTH=$(( _RG_DEPTH + 1 )); return 0; fi
    common_ensure_dir "$REPORTS_DIR" || return 1
    if ! { exec {_RG_FD}>>"$REPORTS_DIR/.report.lock"; } 2>/dev/null; then log_err "cannot open the report lock"; return 1; fi
    if ! flock -x -w 120 "$_RG_FD"; then log_err "timeout waiting for the report lock"; exec {_RG_FD}>&-; return 1; fi
    _RG_DEPTH=1
}
_rg_unlock() {
    if (( _RG_DEPTH == 0 )); then return 0; fi
    _RG_DEPTH=$(( _RG_DEPTH - 1 ))
    if (( _RG_DEPTH == 0 )); then exec {_RG_FD}>&-; fi
    return 0
}

# _rg_sha FILE — SHA-256 hex digest.
_rg_sha() { local h; h=$(sha256sum -- "$1") && printf '%s' "${h%% *}"; }

# --- finality ------------------------------------------------------------------------

# report_is_final TO_DATE OFFSET — true when nothing can change the report any more:
# the last day is over, no session that began before its end is still ACTIVE, and no
# tracked process (running now, or left by a crash in active.tsv) started before its end.
report_is_final() {
    local to=${1-} off=${2:-0} e end_ts now
    if [[ -z $to ]]; then return 1; fi
    if ! common_utc_to_epoch e "$to" "00:00:00"; then return 1; fi
    end_ts=$(( e + 86400 - off )); _rg_now now
    if (( now < end_ts )); then return 1; fi
    if _act_lines "$ACT_SESS_RAW" | LC_ALL=C awk -F'\t' -v end="$end_ts" '$1 == "S" && $5 == "ACTIVE" && $4 < end { f = 1 } END { exit !f }'; then return 1; fi
    if [[ -s $ACTIVE_FILE ]] && LC_ALL=C awk -F'\t' -v end="$end_ts" '$4 < end { f = 1 } END { exit !f }' "$ACTIVE_FILE"; then return 1; fi
    return 0
}

# --- encoding --------------------------------------------------------------------------

# _rg_stamp CREATED — stdin: LF CSV body. Prepends the Report_Created_UTC column.
_rg_stamp() {
    LC_ALL=C awk -v c="$1" 'NR == 1 { print "Report_Created_UTC," $0; next } { print c "," $0 }'
}
# _rg_encode — stdin: LF text. stdout: UTF-8 BOM + CRLF line endings (what Excel expects).
_rg_encode() { printf '\xEF\xBB\xBF'; LC_ALL=C awk '{ printf "%s\r\n", $0 }'; }

# --- body generators (LF, no Report_Created_UTC column yet) -----------------------------

# report_summary_body STATUS TOP — the Usage Summary as ONE tidy table: every row has the
# same columns, a Section says what kind of row it is. Overview / Most_Used_Applications /
# Daily_Session_Time / Daily_Application_Active_Time / Data_Quality.
report_summary_body() {
    local status=$1 top=$2 pf pt ot hms apps daily quality
    local -A K=()
    pf=${ACT_FROM:-all}; pt=${ACT_TO:-all}; report_offset_text "$ACT_OFFSET"; ot=$REPLY
    _act_load_kv
    _srow() { csv_row rrrrrrttrrrrt "$pf" "$pt" "$ot" "$status" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"; printf '%s\n' "$REPLY"; }
    _hmsof() { if [[ ${1-} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then common_fmt_hms hms "${1%.*}"; printf '%s' "$hms"; fi; }
    printf 'Period_From,Period_To,UTC_Offset,Report_Status,Section,Rank,Item,Value,Unit,Launches,Processes,Percent_Of_Session_Time,Note\n'
    #       section   rank item                          value                          unit     launches processes pct  note
    _srow Overview "" Total_Sessions "${K[sessions_total]}" count "" "" "" "sessions that started in the period"
    _srow Overview "" Sessions_Closed "${K[sessions_closed]}" count "" "" "" "have a logout time and a duration"
    _srow Overview "" Sessions_Active "${K[sessions_active]}" count "" "" "" "still open: no duration, not in any total"
    _srow Overview "" Sessions_Interrupted "${K[sessions_interrupted]}" count "" "" "" "end unknown: no duration, not in any total"
    _srow Overview "" Sessions_With_Estimated_End "${K[sessions_estimated_end]}" count "" "" "" "crash or power loss: end = last heartbeat"
    _srow Overview "" Total_Usage_Duration "${K[usage_seconds]}" seconds "" "" "" "$(_hmsof "${K[usage_seconds]}") - login to logout of closed sessions, clipped to the period"
    _srow Overview "" Average_Session_Duration "${K[avg_session_seconds]}" seconds "" "" "" "closed sessions only"
    _srow Overview "" Total_Processes "${K[processes_total]}" count "" "" "" "processes that started in the period"
    _srow Overview "" Processes_Completed "${K[processes_completed]}" count "" "" "" "end observed: natural end"
    _srow Overview "" Processes_Session_End "${K[processes_session_end]}" count "" "" "" "still running when monitoring stopped: NOT a natural end"
    _srow Overview "" Processes_Recovered "${K[processes_recovered]}" count "" "" "" "monitor died: end is an estimate, NOT a natural end"
    _srow Overview "" Processes_User_Application "${K[processes_user_app]}" count "" "" "" "application processes, helpers included"
    _srow Overview "" Processes_Background "${K[processes_background]}" count "" "" "" ""
    _srow Overview "" Processes_Unclassified "${K[processes_unclassified]}" count "" "" "" "no details row: never merged into an application"
    _srow Overview "" Average_Process_Duration "${K[avg_process_seconds]}" seconds "" "" "" "COMPLETED processes only; empty = none to average"
    _srow Overview "" Longest_Completed_Process "${K[longest_process]}" name "" "" "" "${K[longest_process_seconds]} seconds"
    _srow Overview "" User_Application_Launches "${K[app_launches]}" count "" "" "" "application instances started while monitoring"
    _srow Overview "" Applications_Already_Running "${K[apps_already_running]}" count "" "" "" "found running when monitoring began: not launches"
    _srow Overview "" Distinct_User_Applications "${K[distinct_user_apps]}" count "" "" "" ""
    _srow Overview "" Most_Used_Application "${K[most_used_app]}" name "" "" "" "${K[most_used_app_seconds]} seconds of activity"
    _srow Overview "" User_Application_Active_Time "${K[ua_active_seconds]}" seconds "" "" "" "time with at least one user application running; concurrent apps are NOT added together"
    _srow Overview "" Process_Seconds_Sum "${K[process_seconds_sum]}" seconds "" "" "" "plain sum of process durations: concurrent processes add up, so this is NOT usage time"
    _srow Overview "" Days_With_Activity "${K[days_with_activity]}" count "" "" "" ""
    _srow Overview "" Busiest_Day "${K[busiest_day]}" date "" "" "" "${K[busiest_day_seconds]} seconds of application activity"
    _srow Overview "" Processes_Still_Running_Excluded "${K[processes_running_now_excluded]}" count "" "" "" "being tracked right now; they are reported after they end"
    unset -f _srow _hmsof

    apps=$(activity_apps User_Application "$top")
    _act_lines "$apps" | LC_ALL=C awk -v pf="$pf" -v pt="$pt" -v ot="$ot" -v st="$status" "$AWK_LIB"'
        NR > 1 { csv_split($0, f)
                 printf "%s,%s,%s,%s,Most_Used_Applications,%s,%s,%s,seconds,%s,%s,%s,%s\n", pf, pt, ot, st, f[1], csvq(f[2]), csvq(f[8]), f[3], f[5], f[10],
                     csvq("active " f[9] "; already running " f[4] "; average instance seconds " (f[11] == "" ? "n/a" : f[11])) }'
    daily=$(activity_daily)
    _act_lines "$daily" | LC_ALL=C awk -v pf="$pf" -v pt="$pt" -v ot="$ot" -v st="$status" "$AWK_LIB"'
        NR > 1 { csv_split($0, f)
                 printf "%s,%s,%s,%s,Daily_Session_Time,,%s,%s,seconds,%s,%s,,%s\n", pf, pt, ot, st, f[1], csvq(f[3]), f[6], f[5], csvq("sessions started " f[2] "; " f[4])
                 printf "%s,%s,%s,%s,Daily_Application_Active_Time,,%s,%s,seconds,,,,%s\n", pf, pt, ot, st, f[1], csvq(f[11]), csvq(f[12] "; distinct applications " f[13]) }'
    quality=$(activity_quality)
    _act_lines "$quality" | LC_ALL=C awk -v pf="$pf" -v pt="$pt" -v ot="$ot" -v st="$status" "$AWK_LIB"'
        NR > 1 { csv_split($0, f)
                 printf "%s,%s,%s,%s,Data_Quality,,%s,%s,count,,,,%s\n", pf, pt, ot, st, csvq(f[1]), csvq(f[2]), csvq("whole log, not only this period: " f[3]) }'
}

# _rg_build FROM TO STATUS TOP STAGE — write the three LF bodies into STAGE/body and set
# RG_FINGERPRINT (SHA-256 of the three bodies; it does not depend on the creation date).
_rg_build() {
    local status=$3 top=$4 stage=$5 b h exp
    mkdir -p -m 700 "$stage/body" || return 1
    activity_sessions 0 >"$stage/body/session_report.body" || return 1
    activity_processes >"$stage/body/application_activity_report.body" || return 1
    report_summary_body "$status" "$top" >"$stage/body/usage_summary_report.body" || return 1
    for b in session_report:"$RG_HDR_SESSION" application_activity_report:"$RG_HDR_ACTIVITY" usage_summary_report:"$RG_HDR_SUMMARY"; do
        IFS= read -r h <"$stage/body/${b%%:*}.body"
        exp=${b#*:}; exp=${exp#Report_Created_UTC,}
        if [[ $h != "$exp" ]]; then log_err "report schema drift in ${b%%:*}: [$h]"; return 1; fi
    done
    # The fingerprint covers the content AND the file layout (REPORT_MAX_ROWS decides the split).
    RG_FINGERPRINT=$({ cat "$stage/body/session_report.body" "$stage/body/application_activity_report.body" "$stage/body/usage_summary_report.body"; printf "layout:max_rows=%s\n" "${REPORT_MAX_ROWS:-1000000}"; } | sha256sum)
    RG_FINGERPRINT=${RG_FINGERPRINT%% *}
}

# _rg_emit_all CREATED STAGE — stamp, split (Excel row limit) and encode every body into
# STAGE; RG_FILES gets the resulting file names in order.
_rg_emit_all() {
    local created=$1 stage=$2 kind body stamped rows max=${REPORT_MAX_ROWS:-1000000} n part f
    RG_FILES=()
    for kind in "${RG_KINDS[@]}"; do
        body="$stage/body/$kind.body"; stamped="$stage/$kind.stamped"
        _rg_stamp "$created" <"$body" >"$stamped" || return 1
        rows=$(( $(grep -c '' "$stamped") - 1 ))
        if (( rows <= max )); then
            _rg_encode <"$stamped" >"$stage/$kind.csv" || return 1
            RG_FILES+=("$kind.csv")
        else
            LC_ALL=C awk -v max="$max" -v base="$stage/$kind" '
                NR == 1 { hdr = $0; next }
                { if (n % max == 0) { if (out != "") close(out); part++; out = base "_part" part ".csv.lf"; print hdr > out }
                  print > out; n++ }' "$stamped" || return 1
            n=0
            for f in "$stage/${kind}"_part*.csv.lf; do n=$(( n + 1 )); done
            for (( part = 1; part <= n; part++ )); do
                _rg_encode <"$stage/${kind}_part$part.csv.lf" >"$stage/${kind}_part$part.csv" || return 1
                RG_FILES+=("${kind}_part$part.csv")
            done
        fi
    done
}

# _rg_write_manifest CREATED STATUS KIND FROM TO OFFSET_TEXT STAGE — manifest into STAGE.
_rg_write_manifest() {
    local created=$1 status=$2 kind=$3 pf=${4:-all} pt=${5:-all} ot=$6 stage=$7 f rows bytes sha
    {
        printf '%s\n' "$RG_HDR_MANIFEST"
        for f in "${RG_FILES[@]}"; do
            rows=$(( $(grep -c '' "$stage/$f") - 1 ))
            bytes=$(wc -c <"$stage/$f"); bytes=${bytes// /}
            sha=$(_rg_sha "$stage/$f")
            csv_row rnnrrrrrrrrr "$f" "$rows" "$bytes" "$sha" "$created" "$status" "$kind" "$pf" "$pt" "$ot" "$RG_FINGERPRINT" "$CAL_VERSION"
            printf '%s\n' "$REPLY"
        done
    } | _rg_encode >"$stage/$RG_MANIFEST_NAME"
}

# _rg_read_manifest DIR — loads the manifest of DIR into M_* variables when it verifies.
#   M_STATE = none (no manifest) | ok | bad (exists but does not match its files)
M_STATE=none M_STATUS="" M_FP="" M_CREATED="" M_FILES=()
_rg_read_manifest() {
    local dir=$1 line f rows bytes sha created status fp
    M_STATE=none; M_STATUS=""; M_FP=""; M_CREATED=""; M_FILES=()
    if [[ ! -f $dir/$RG_MANIFEST_NAME ]]; then return 0; fi
    M_STATE=ok
    # NB: when `read` hits EOF it EMPTIES every variable it was given, so nothing that must
    # outlive the loop may be a read target — copy it inside the body instead.
    while IFS=$'\t' read -r f rows bytes sha created status _ _ _ _ fp _; do
        M_FILES+=("$f"); M_CREATED=$created; M_STATUS=$status; M_FP=$fp
        if [[ ! -f $dir/$f ]] || [[ $(_rg_sha "$dir/$f") != "$sha" ]]; then M_STATE=bad; fi
    done < <(LC_ALL=C awk "$AWK_LIB"'NR > 1 { sub(/\r$/, ""); if (csv_split($0, f) == 12) printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], f[9], f[10], f[11], f[12] }' "$dir/$RG_MANIFEST_NAME")
    if (( ${#M_FILES[@]} == 0 )); then M_STATE=bad; fi
    return 0
}

# _rg_log EVENT KIND PERIOD OFFSET_TEXT STATUS PATH FINGERPRINT FILES ARCHIVED — append to report_log.csv.
_rg_log() {
    local log="$REPORTS_DIR/report_log.csv" now ts
    _rg_now now; common_fmt_ts ts "$now"
    storage_prepare_csv "$log" "$RG_HDR_LOG" || return 1
    csv_row rrrrrrrrnr "$ts" "$1" "$2" "$3" "$4" "$5" "$6" "$7" "$8" "$9"
    printf '%s\n' "$REPLY" >>"$log"
}

# _rg_cleanup_stale — remove staging directories left by a crashed run. Only called while
# holding the lock, so none of them can belong to a live generator.
_rg_cleanup_stale() {
    local d
    shopt -s nullglob
    for d in "$REPORTS_DIR"/.staging.*; do
        if [[ -d $d && $d == "$REPORTS_DIR"/.staging.* ]]; then rm -rf -- "$d"; fi
    done
    shopt -u nullglob
}

# report_is_frozen DIR — true if DIR holds a verified FINAL set (a normal run leaves it alone).
report_is_frozen() {
    _rg_read_manifest "$1"
    [[ $M_STATE == ok && $M_STATUS == FINAL ]]
}

# --- publishing -------------------------------------------------------------------------

# _rg_archive DIR — keep the current files of DIR under revisions/<created>/ (hard links:
# no copy, and the old inode survives the atomic replacement of the live files).
_rg_archive() {
    local dir=$1 tag rev n=1 f
    tag=${M_CREATED//[-: ]/}; tag=${tag:0:8}T${tag:8}Z
    if [[ -z $M_CREATED ]]; then printf -v tag '%(%Y%m%dT%H%M%SZ)T' -1; fi
    rev="$dir/revisions/$tag"
    while [[ -e $rev ]]; do n=$(( n + 1 )); rev="$dir/revisions/${tag}_$n"; done
    mkdir -p -m 700 "$rev" || return 1
    for f in "$dir"/*.csv; do
        [[ -e $f ]] || continue
        [[ -f $f ]] || continue
        ln -f -- "$f" "$rev/${f##*/}" 2>/dev/null || cp -p -- "$f" "$rev/${f##*/}" || return 1
    done
    RG_ARCHIVED="revisions/${rev##*/}"
}

# _rg_publish STAGE DIR — move the new files into DIR atomically, manifest last.
_rg_publish() {
    local stage=$1 dir=$2 f moved=0 old
    mkdir -p -m 700 "$dir" || return 1
    for f in "${RG_FILES[@]}"; do
        sync -- "$stage/$f" 2>/dev/null || true
        mv -f -- "$stage/$f" "$dir/$f" || return 1               # atomic replace
        moved=$(( moved + 1 ))
        if [[ ${CAL_TEST_ABORT_AFTER_FILES:-} == "$moved" ]]; then log_warn "test hook: aborting after $moved file(s)"; exit 99; fi
    done
    sync -- "$stage/$RG_MANIFEST_NAME" 2>/dev/null || true
    mv -f -- "$stage/$RG_MANIFEST_NAME" "$dir/$RG_MANIFEST_NAME" || return 1   # LAST: the set is complete from here
    # Parts that no longer exist (the report got shorter) — already archived if it mattered.
    for old in ${OLD_FILES[@]+"${OLD_FILES[@]}"}; do
        local keep=0; for f in "${RG_FILES[@]}"; do if [[ $f == "$old" ]]; then keep=1; break; fi; done
        if (( keep == 0 )); then rm -f -- "$dir/$old"; fi
    done
}

# report_generate_set KIND LABEL FROM TO OFFSET TOP MODE
#   KIND = daily | period ; MODE = normal | refresh | force
# The activity data must already be loaded with activity_set_period for FROM..TO.
# Prints one line: GENERATED / REPLACED / UNCHANGED / SKIPPED(final) — returns non-zero on error.
report_generate_set() {
    local kind=$1 label=$2 from=$3 to=$4 off=$5 top=$6 mode=${7:-normal}
    local tz dir rel status stage created now ev ot rc=0 had_old=0 archive=0
    RG_ARCHIVED=""; OLD_FILES=()
    report_tz_label "$off"; tz=$REPLY; report_offset_text "$off"; ot=$REPLY
    rel="$kind/$tz/$label"; dir="$REPORTS_DIR/$rel"

    _rg_lock || return 1
    _rg_cleanup_stale
    _rg_read_manifest "$dir"
    OLD_FILES=(); if (( ${#M_FILES[@]} > 0 )); then OLD_FILES=("${M_FILES[@]}"); fi
    if [[ $M_STATE != none ]]; then had_old=1; fi
    if [[ $mode == normal && $M_STATE == ok && $M_STATUS == FINAL ]]; then
        echo "SKIPPED   $rel (final report already exists)"; _rg_unlock; return 0
    fi
    if report_is_final "$to" "$off"; then status=FINAL; else status=PARTIAL; fi

    common_ensure_dir "$REPORTS_DIR" || { _rg_unlock; return 1; }
    stage=$(mktemp -d "$REPORTS_DIR/.staging.XXXXXX") || { _rg_unlock; return 1; }
    if ! _rg_build "$from" "$to" "$status" "$top" "$stage"; then
        log_err "report $rel: could not build the report bodies"; rm -rf -- "$stage"; _rg_unlock; return 1
    fi
    if [[ $M_STATE == ok && $M_FP == "$RG_FINGERPRINT" && $M_STATUS == "$status" && $mode != force ]]; then
        echo "UNCHANGED $rel ($status, created $M_CREATED)"; rm -rf -- "$stage"; _rg_unlock; return 0
    fi

    _rg_now now; common_fmt_ts created "$now"
    if ! _rg_emit_all "$created" "$stage" || ! _rg_write_manifest "$created" "$status" "$kind" "${from:-all}" "${to:-all}" "$ot" "$stage"; then
        log_err "report $rel: could not encode the report files"; rm -rf -- "$stage"; _rg_unlock; return 1
    fi
    # A FINAL (or damaged, or forced) set that is about to change is archived first.
    if (( had_old == 1 )) && [[ $M_STATE == bad || $M_STATUS == FINAL || $mode == force ]]; then archive=1; fi
    if (( archive == 1 )); then _rg_archive "$dir" || { log_err "report $rel: cannot archive the old version"; rm -rf -- "$stage"; _rg_unlock; return 1; }; fi
    if ! _rg_publish "$stage" "$dir"; then rc=1; fi
    rm -rf -- "$stage"
    if (( rc == 0 )); then
        if (( had_old == 1 )); then ev=REPLACED; else ev=GENERATED; fi
        _rg_log "$ev" "$kind" "$label" "$ot" "$status" "$rel" "$RG_FINGERPRINT" "${#RG_FILES[@]}" "$RG_ARCHIVED"
        echo "$ev $rel ($status, ${#RG_FILES[@]} file(s)${RG_ARCHIVED:+, previous version kept in $RG_ARCHIVED})"
    else
        log_err "report $rel: publishing failed"
    fi
    _rg_unlock
    return "$rc"
}

# --- commands -----------------------------------------------------------------------------

# report_run_daily FROM TO OFFSET TOP MODE EXPLICIT — one set per calendar day.
#   FROM/TO empty = every day that has any activity. EXPLICIT=1 (--date): generate even if empty.
report_run_daily() {
    local from=${1-} to=${2-} off=${3:-0} top=${4:-20} mode=${5:-normal} explicit=${6:-0}
    local day tz dir rc=0 n=0
    local -a days=()
    report_tz_label "$off"; tz=$REPLY
    activity_load
    activity_set_period "" "" "$off"
    mapfile -t days < <(activity_days)
    if (( explicit == 1 )); then days=("$from"); else
        local -a keep=()
        for day in "${days[@]}"; do
            if [[ -n $from && $day < $from ]]; then continue; fi
            if [[ -n $to && $day > $to ]]; then continue; fi
            keep+=("$day")
        done
        days=("${keep[@]}")
    fi
    if (( ${#days[@]} == 0 )); then echo "No activity found for the requested days."; return 0; fi
    for day in "${days[@]}"; do
        dir="$REPORTS_DIR/daily/$tz/$day"
        if [[ $mode == normal ]] && report_is_frozen "$dir"; then echo "SKIPPED   daily/$tz/$day (final report already exists)"; continue; fi
        activity_set_period "$day" "$day" "$off"
        report_generate_set daily "$day" "$day" "$day" "$off" "$top" "$mode" || rc=1
        n=$(( n + 1 ))
    done
    return "$rc"
}

# report_run_period FROM TO OFFSET TOP MODE NAME — one set for any period ("" = unbounded).
report_run_period() {
    local from=${1-} to=${2-} off=${3:-0} top=${4:-20} mode=${5:-normal} name=${6-} label
    if [[ -n $name ]]; then label=$name
    elif [[ -z $from && -z $to ]]; then label=all
    elif [[ -n $from && -n $to ]]; then label="${from}_to_${to}"
    elif [[ -n $from ]]; then label="from_${from}"
    else label="until_${to}"; fi
    activity_prepare "$from" "$to" "$off"
    report_generate_set period "$label" "$from" "$to" "$off" "$top" "$mode"
}

# --- verification ----------------------------------------------------------------------------

# report_verify_dir DIR — prints every problem found in one report set; returns 1 if any.
#   manifest vs files (size, SHA-256, row counts) · BOM · CRLF · header · constant column count ·
#   balanced quotes · cell length · date / number formats · chronological order · creation date ·
#   Excel row limit · no unprotected formula-like cells · no stray files.
report_verify_dir() {
    local dir=$1 rc=0 kind f nfiles name exp ncols dtcols numcols ordercol created
    local -a files=()
    if [[ ! -f $dir/$RG_MANIFEST_NAME ]]; then echo "$dir: no $RG_MANIFEST_NAME (incomplete or not a report)"; return 1; fi
    if [[ $(LC_ALL=C awk 'NR == 1 { sub(/^\xef\xbb\xbf/, ""); sub(/\r$/, ""); print }' "$dir/$RG_MANIFEST_NAME") != "$RG_HDR_MANIFEST" ]]; then echo "$dir: manifest header is wrong"; rc=1; fi
    _rg_read_manifest "$dir"
    files=(); if (( ${#M_FILES[@]} > 0 )); then files=("${M_FILES[@]}"); fi; created=$M_CREATED
    # manifest <-> files
    local line mf mrows mbytes msha
    while IFS=$'\t' read -r mf mrows mbytes msha; do
        if [[ ! -f $dir/$mf ]]; then echo "$dir: $mf is listed in the manifest but missing"; rc=1; continue; fi
        if [[ $(_rg_sha "$dir/$mf") != "$msha" ]]; then echo "$dir: $mf does not match its SHA-256 in the manifest (incomplete or modified)"; rc=1; fi
        nfiles=$(wc -c <"$dir/$mf"); if (( ${nfiles// /} != mbytes )); then echo "$dir: $mf has $nfiles bytes, the manifest says $mbytes"; rc=1; fi
        if (( $(grep -c '' "$dir/$mf") - 1 != mrows )); then echo "$dir: $mf has $(( $(grep -c '' "$dir/$mf") - 1 )) rows, the manifest says $mrows"; rc=1; fi
    done < <(LC_ALL=C awk "$AWK_LIB"'NR > 1 { sub(/\r$/, ""); if (csv_split($0, f) == 12) printf "%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4] }' "$dir/$RG_MANIFEST_NAME")
    for f in "$dir"/*.csv; do
        [[ -e $f ]] || continue
        name=${f##*/}
        if [[ $name != "$RG_MANIFEST_NAME" ]]; then
            local listed=0 x; for x in ${files[@]+"${files[@]}"}; do if [[ $x == "$name" ]]; then listed=1; break; fi; done
            if (( listed == 0 )); then echo "$dir: $name is not listed in the manifest (leftover from an interrupted run?)"; rc=1; fi
        fi
    done
    # structure, per report kind (parts of one kind are checked together, in order)
    for kind in "${RG_KINDS[@]}"; do
        local -a kf=(); for f in ${files[@]+"${files[@]}"}; do if [[ $f == "$kind.csv" || $f == "${kind}_part"*.csv ]]; then kf+=("$dir/$f"); fi; done
        if (( ${#kf[@]} == 0 )); then echo "$dir: no file for $kind"; rc=1; continue; fi
        case $kind in
            session_report)                 exp=$RG_HDR_SESSION;  dtcols="5 6";  numcols="4 9 10 12 14 15 16 17 18 19"; ordercol=5 ;;
            application_activity_report)    exp=$RG_HDR_ACTIVITY; dtcols="8 9";  numcols="3 10 12 17";                ordercol=8 ;;
            *)                              exp=$RG_HDR_SUMMARY;  dtcols="";     numcols="7 11 12";                    ordercol=0 ;;
        esac
        ncols=$(awk -F, '{ print NF; exit }' <<<"$exp")
        LC_ALL=C awk -v hdr="$exp" -v ncols="$ncols" -v dtcols="$dtcols" -v numcols="$numcols" -v ordercol="$ordercol" -v created="$created" "$AWK_LIB"'
            BEGIN { split(dtcols, dt, " "); split(numcols, nm, " "); for (i in dt) isdt[dt[i]] = 1; for (i in nm) isnum[nm[i]] = 1 }
            function bad(msg,   nm) { errs++; if (errs > 10) return; nm = FILENAME; sub(/.*\//, "", nm); printf "%s: line %d: %s\n", nm, FNR, msg }
            FNR == 1 { if (substr($0, 1, 3) != "\357\273\277") bad("missing UTF-8 BOM"); else $0 = substr($0, 4) }
            {
                total++
                if ($0 !~ /\r$/) { bad("line does not end with CRLF"); next }
                sub(/\r$/, "")
                if ($0 ~ /\r/) bad("stray carriage return inside a row")
                if (FNR == 1) { if ($0 != hdr) bad("header differs from the documented one"); next }
                q = gsub(/"/, "\"", $0); if (q % 2) { bad("unbalanced quotes"); next }
                n = csv_split($0, f)
                if (n != ncols) { bad("expected " ncols " columns, found " n); next }
                if (f[1] != created) bad("Report_Created_UTC differs from the manifest")
                for (c = 1; c <= n; c++) {
                    if (length(f[c]) > 32767) bad("cell longer than 32,767 characters (Excel limit)")
                    if (f[c] ~ /^[=+@]/ || (f[c] ~ /^-/ && f[c] !~ /^-[0-9]+(\.[0-9]+)?$/)) bad("unprotected formula-like cell: " f[c])
                    if ((c in isdt) && f[c] != "" && f[c] !~ /^[0-9][0-9][0-9][0-9]-[0-9][0-9]-[0-9][0-9] [0-9][0-9]:[0-9][0-9]:[0-9][0-9]$/) bad("column " c " is not YYYY-MM-DD HH:MM:SS: " f[c])
                    if ((c in isnum) && f[c] != "" && f[c] !~ /^[0-9]+(\.[0-9]+)?$/) bad("column " c " is not a number: " f[c])
                }
                if (ordercol > 0 && f[ordercol] != "") { if (f[ordercol] < last) bad("not in chronological order"); last = f[ordercol] }
            }
            END { if (total > 1048576) { print "more than 1,048,576 rows in " (ARGC - 1) " file(s) is not Excel-compatible"; errs++ }
                  if (errs > 10) printf "... and %d more problem(s) of the same kind of file\n", errs - 10
                  exit (errs > 0) }' "${kf[@]}" || rc=1
    done
    return "$rc"
}

# report_verify_all — verify every set under reports/daily and reports/period.
report_verify_all() {
    local m dir rc=0 n=0
    while IFS= read -r m; do
        dir=${m%/*}; n=$(( n + 1 ))
        if report_verify_dir "$dir"; then echo "OK        ${dir#"$REPORTS_DIR"/}"; else echo "PROBLEMS  ${dir#"$REPORTS_DIR"/}"; rc=1; fi
    done < <(find "$REPORTS_DIR/daily" "$REPORTS_DIR/period" -name "$RG_MANIFEST_NAME" -not -path '*/revisions/*' 2>/dev/null | LC_ALL=C sort)
    if (( n == 0 )); then echo "No reports found under $REPORTS_DIR."; fi
    return "$rc"
}

# report_list — one line per set: kind, time zone, label, status, creation date, files.
report_list() {
    local m dir rel st n=0
    printf 'Set,Status,Created_UTC,Files\n'
    while IFS= read -r m; do
        dir=${m%/*}; rel=${dir#"$REPORTS_DIR"/}; _rg_read_manifest "$dir"
        st=${M_STATUS:-?}; if [[ $M_STATE == bad ]]; then st="$st-DAMAGED"; fi
        csv_row rrrn "$rel" "$st" "$M_CREATED" "${#M_FILES[@]}"; printf '%s\n' "$REPLY"
        if [[ $M_STATE == bad ]]; then echo "  ^ $rel does not match its manifest — run: ./main.sh report verify" >&2; fi
        n=$(( n + 1 ))
    done < <(find "$REPORTS_DIR/daily" "$REPORTS_DIR/period" -name "$RG_MANIFEST_NAME" -not -path '*/revisions/*' 2>/dev/null | LC_ALL=C sort)
}
