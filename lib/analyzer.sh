#!/usr/bin/env bash
# =============================================================================
# lib/analyzer.sh — Usage statistics computed from the CSV files (awk only)
# -----------------------------------------------------------------------------
# Every analyzer_* function prints CSV (with a header) on stdout and only
# READS the data files, so it is safe to run while the daemon is logging.
# Incomplete trailing lines (wrong field count) are ignored.
#
# Common arguments:  FROM TO  — inclusive YYYY-MM-DD bounds, "" = unbounded.
# =============================================================================


# Dates are UTC (the stored timezone).
#
# Processes are NOT counted as applications one by one. process_details.csv
# says, for every process, its class (User_Application / Background_Process),
# its application name and whether it is the ROOT of an application instance.
# "Launches" therefore counts roots only (a browser with 12 processes = 1
# launch), and the time of an application is the UNION of all its processes'
# intervals (never summed, which would multiply a browser's time by 12).

# _analyzer_rows FROM TO — processes joined with their details, TAB separated:
#   app  start_epoch  end_epoch  class  root(yes|no)  cpu_seconds  day  duration  status
# Rows without a details line (should not happen) get class "Unknown".
# Period filter: Start_Time date (UTC).
_analyzer_rows() {
    local from=${1-} to=${2-}
    if [[ ! -s $PROCESSES_FILE ]]; then return 0; fi
    local -a files=()
    if [[ -s $PROCESS_DETAILS_FILE ]]; then files+=("$PROCESS_DETAILS_FILE"); fi
    files+=("$PROCESSES_FILE")
    LC_ALL=C awk -v from="$from" -v to="$to" -v pfile="$PROCESSES_FILE" "$AWK_LIB"'
        FNR == 1 { next }
        FILENAME != pfile {                                   # process_details.csv
            if (csv_split($0, d) != 20) next
            k = d[1] "|" d[2] "|" d[3]
            cls[k] = d[6]; app[k] = d[7]; root[k] = d[9]; se[k] = d[19]; ee[k] = d[20]; cpu[k] = d[14]
            next
        }
        {                                                     # processes.csv
            if (csv_split($0, f) != 8) next
            day = substr(f[5], 1, 10)
            if (!in_range(day)) next
            k = f[1] "|" f[2] "|" f[5]
            if (k in cls) printf "%s\t%d\t%d\t%s\t%s\t%d\t%s\t%d\t%s\n", app[k], se[k], ee[k], cls[k], root[k], cpu[k], day, f[7], f[8]
            else          printf "%s\t0\t%d\tUnknown\tyes\t0\t%s\t%d\t%s\n", f[3], f[7], day, f[7], f[8]
        }' "${files[@]}"
}

# analyzer_top_apps FROM TO TOP [CLASS]  (CLASS default User_Application)
#   App_Name, Launches (application instances), Processes, Seconds (union), HMS, CPU_Seconds
analyzer_top_apps() {
    local from=${1-} to=${2-} top=${3:-10} class=${4:-User_Application}
    printf 'App_Name,Launches,Processes,Seconds,HMS,CPU_Seconds\n'
    _analyzer_rows "$from" "$to" \
    | LC_ALL=C awk -F'\t' -v want="$class" '$4 == want { printf "%s\t%d\t%d\t%s\t%d\n", $1, $2, $3, $5, $6 }' \
    | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n \
    | LC_ALL=C awk -F'\t' "$AWK_LIB"'
        function flush() {
            if (cur == "") return
            printf "%d\t%s,%d,%d,%d,%s,%d\n", union, csvq(cur), launches, procs, union, hms(union), cpu
        }
        {
            if ($1 != cur) { flush(); cur = $1; ce = 0; union = 0; launches = 0; procs = 0; cpu = 0 }
            procs++; cpu += $5
            if ($4 == "yes") launches++
            if ($2 >= ce) { union += $3 - $2; ce = $3 }
            else if ($3 > ce) { union += $3 - ce; ce = $3 }
        }
        END { flush() }' \
    | LC_ALL=C sort -t $'\t' -k1,1nr | cut -f2- | head -n "$top"
}

# analyzer_daily FROM TO — per start date (UTC):
#   Date, User_App_Launches, Background_Processes, User_App_Seconds (union per app), HMS
analyzer_daily() {
    local from=${1-} to=${2-} rows
    printf 'Date,User_App_Launches,Background_Processes,User_App_Seconds,User_App_HMS\n'
    rows=$(_analyzer_rows "$from" "$to")
    if [[ -z $rows ]]; then return 0; fi
    {
        # user-app interval unions per (day, app) ...
        LC_ALL=C awk -F'\t' '$4 == "User_Application" { printf "%s\t%s\t%d\t%d\n", $7, $1, $2, $3 }' <<<"$rows" \
        | LC_ALL=C sort -t $'\t' -k1,1 -k2,2 -k3,3n \
        | LC_ALL=C awk -F'\t' '
            { k = $1 "\t" $2; if (k != cur) { cur = k; ce = 0 }
              if ($3 >= ce) { u[$1] += $4 - $3; ce = $4 } else if ($4 > ce) { u[$1] += $4 - ce; ce = $4 } }
            END { for (d in u) printf "U\t%s\t%d\n", d, u[d] }'
        # ... plus the launch / background counters
        LC_ALL=C awk -F'\t' '
            { seen[$7] = 1 }
            $4 == "User_Application" && $5 == "yes" { l[$7]++ }
            $4 != "User_Application" { b[$7]++ }
            END { for (d in seen) printf "C\t%s\t%d\t%d\n", d, l[d], b[d] }' <<<"$rows"
    } | LC_ALL=C awk -F'\t' "$AWK_LIB"'
        $1 == "U" { sec[$2] = $3 }
        $1 == "C" { days[$2] = 1; la[$2] = $3; bg[$2] = $4 }
        END { for (d in days) printf "%s,%d,%d,%d,%s\n", d, la[d], bg[d], sec[d], hms(sec[d]) }' \
    | LC_ALL=C sort -t, -k1,1
}

# analyzer_summary FROM TO — headline numbers for the period.
# ACTIVE / INTERRUPTED sessions have no duration: counted, not totalled.
analyzer_summary() {
    local from=${1-} to=${2-}
    printf 'metric,value\n'
    printf 'period_from,%s\nperiod_to,%s\n' "${from:-all}" "${to:-all}"
    printf 'timezone,UTC\n'
    printf 'scan_interval_sec,%s\n' "$INTERVAL_SEC"
    printf 'accuracy_note,"end times are detection times (up to one scan interval late); processes that start and end between two scans are not seen"\n'
    if [[ -s $SESSIONS_FILE ]]; then
        LC_ALL=C awk -v from="$from" -v to="$to" "$AWK_LIB"'
            FNR > 1 {
                if (csv_split($0, f) != 9) next
                if (!in_range(f[4])) next
                n++
                if (f[9] == "ACTIVE") act++
                if (f[8] ~ /^[0-9]+$/) { m++; total += f[8]; if (f[8] > longest) longest = f[8] }
            }
            END {
                printf "sessions,%d\nsessions_active,%d\nsessions_total_hms,%s\nlongest_session_hms,%s\navg_session_hms,%s\n",
                    n, act, hms(total), hms(longest), hms(m ? total / m : 0)
            }' "$SESSIONS_FILE"
    else
        printf 'sessions,0\n'
    fi
    _analyzer_rows "$from" "$to" | LC_ALL=C awk -F'\t' '
        { n++ }
        $4 == "User_Application" { if ($5 == "yes") { ua++; apps[$1] = 1 } else helpers++ }
        $4 != "User_Application" { bg++ }
        $9 == "RECOVERED" { rec++ }
        END {
            for (a in apps) distinct++
            printf "process_rows,%d\nuser_application_launches,%d\nuser_application_helper_processes,%d\nbackground_process_rows,%d\ndistinct_user_applications,%d\nrows_with_estimated_end,%d\n",
                n, ua, helpers, bg, distinct, rec
        }'
}

# analyzer_raw KIND FROM TO — header + rows of the period (used by reports).
#   KIND = processes | details | sessions   (filtered on the start date, UTC)
analyzer_raw() {
    local kind=$1 from=${2-} to=${3-} header cols file datecol
    case $kind in
        processes) header=$PROCESSES_HEADER;       cols=8;  file=$PROCESSES_FILE;       datecol=5 ;;
        details)   header=$DETAILS_HEADER;         cols=20; file=$PROCESS_DETAILS_FILE; datecol=3 ;;
        *)         header=$SESSIONS_HEADER;        cols=9;  file=$SESSIONS_FILE;        datecol=4 ;;
    esac
    printf '%s\n' "$header"
    if [[ ! -s $file ]]; then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" -v cols="$cols" -v dc="$datecol" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != cols) next
            if (in_range(substr(f[dc], 1, 10))) print $0
        }' "$file"
}

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
