#!/usr/bin/env bash
# =============================================================================
# lib/analyzer.sh — Row views of the session and process logs (awk only)
# -----------------------------------------------------------------------------
# Every analyzer_* function prints CSV (with a header) on stdout and only
# READS the data files, so it is safe to run while the daemon is logging.
# Incomplete trailing lines (wrong field count) are ignored.
#
# Common arguments:  FROM TO  — inclusive YYYY-MM-DD bounds, "" = unbounded.
# =============================================================================


# The statistics (applications, daily, summary, report) live in lib/activity.sh.
# This file keeps the plain row views of the session and process logs.

# analyzer_processes_view FROM TO CLASS TAIL — readable table (TAB separated) of
# the most recent finished processes, with their class and application.
analyzer_processes_view() {
    local from=${1-} to=${2-} class=${3-} tail=${4:-20}
    printf 'PID\tProcess\tClass\tApplication\tRoot\tStart(UTC)\tEnd(UTC)\tSeconds\tStatus\n'
    if [[ ! -s $PROCESSES_FILE ]]; then return 0; fi
    local -a files=()
    if [[ -s $PROCESS_DETAILS_FILE ]]; then files+=("$PROCESS_DETAILS_FILE"); fi
    files+=("$PROCESSES_FILE")
    LC_ALL=C awk -v from="$from" -v to="$to" -v want="$class" -v pfile="$PROCESSES_FILE" "$AWK_LIB"'
        FNR == 1 { next }
        FILENAME != pfile { if (csv_split($0, d) == 20) { k = d[1] "|" d[2] "|" d[3]; cls[k] = d[6]; app[k] = d[7]; root[k] = d[9] } next }
        {
            if (csv_split($0, f) != 8) next
            if (!in_range(substr(f[5], 1, 10))) next
            k = f[1] "|" f[2] "|" f[5]; c = (k in cls) ? cls[k] : "Unknown"
            if (want != "" && c != want) next
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f[2], f[3], c, (k in app) ? app[k] : f[3], (k in root) ? root[k] : "-", f[5], f[6], f[7], f[8]
        }' "${files[@]}" | tail -n "$tail"
}

# analyzer_sessions_rows FROM TO STATUS — one TAB-separated line per session:
#   id user uid login_date login_time logout_date logout_time seconds minutes status
# (stored UTC values; `minutes` has two decimals). STATUS "" = all.
analyzer_sessions_rows() {
    local from=${1-} to=${2-} status=${3-}
    if [[ ! -s $SESSIONS_FILE ]]; then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" -v want="$status" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != 9) next
            if (!in_range(f[4])) next
            if (want != "" && f[9] != want) next
            mins = (f[8] ~ /^[0-9]+$/) ? sprintf("%d.%02d", f[8] / 60, (f[8] % 60) * 100 / 60) : ""
            printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n", f[1], f[2], f[3], f[4], f[5], f[6], f[7], f[8], mins, f[9]
        }' "$SESSIONS_FILE"
}

# analyzer_sessions_csv FROM TO — sessions.csv plus a Duration_Minutes column
# (for Excel reports; still UTC).
analyzer_sessions_csv() {
    local from=${1-} to=${2-}
    printf '%s\n' "${SESSIONS_HEADER/Duration_Seconds,Status/Duration_Seconds,Duration_Minutes,Status}"
    if [[ ! -s $SESSIONS_FILE ]]; then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != 9) next
            if (!in_range(f[4])) next
            mins = (f[8] ~ /^[0-9]+$/) ? sprintf("%d.%02d", f[8] / 60, (f[8] % 60) * 100 / 60) : ""
            line = csvq(f[2])
            printf "%s,%s,%s,%s,%s,%s,%s,%s,%s,%s\n", f[1], line, f[3], f[4], f[5], f[6], f[7], f[8], mins, f[9]
        }' "$SESSIONS_FILE"
}

# analyzer_sessions_view FROM TO STATUS ZONE — pretty table for the terminal.
#   ZONE = utc (default) | local | any TZ name (e.g. Asia/Riyadh)
# The file always stores UTC; conversion happens here, for display only.
analyzer_sessions_view() {
    local from=${1-} to=${2-} status=${3-} zone=${4:-utc}
    local id user uid ld lt od ot secs mins st e le lo_local="" li_local="" label=UTC
    local -a tzenv=()
    case $zone in
        utc) ;;
        local) label=local ;;
        *) tzenv=(env "TZ=$zone"); label=$zone ;;
    esac
    printf 'Session_ID\tUser\tUID\tLogin(%s)\tLogout(%s)\tSeconds\tMinutes\tStatus\n' "$label" "$label"
    while IFS=$'\t' read -r id user uid ld lt od ot secs mins st; do
        li_local="$ld $lt"; lo_local="${od:+$od $ot}"
        if [[ $zone != utc ]]; then
            if common_utc_to_epoch e "$ld" "$lt"; then
                li_local=$("${tzenv[@]}" date -d "@$e" '+%F %T')
            fi
            if [[ -n $od ]] && common_utc_to_epoch le "$od" "$ot"; then
                lo_local=$("${tzenv[@]}" date -d "@$le" '+%F %T')
            fi
        fi
        printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
            "$id" "$user" "$uid" "$li_local" "${lo_local:--}" "${secs:--}" "${mins:--}" "$st"
    done < <(analyzer_sessions_rows "$from" "$to" "$status")
}
