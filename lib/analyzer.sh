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


# analyzer_files KIND — print the monthly data files of KIND (processes).
analyzer_files() {
    local f
    for f in "$DATA_DIR/${1}"_*.csv; do
        if [[ -f $f ]]; then printf '%s\n' "$f"; fi
    done
}

# analyzer_top_apps FROM TO TOP
# union_sec merges overlapping intervals of the same app, so an app made of
# many parallel processes (a browser) is not counted several times.
analyzer_top_apps() {
    local from=${1-} to=${2-} top=${3:-10}
    local -a files
    mapfile -t files < <(analyzer_files processes)
    printf 'app_name,launches,active_sec,active_hms,union_sec,union_hms\n'
    if (( ${#files[@]} == 0 )); then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != 17) next
            if (!in_range(substr(f[8], 1, 10))) next
            printf "%s\t%d\t%d\t%d\n", f[5], f[10], f[11], f[15]
        }' "${files[@]}" \
    | LC_ALL=C sort -t $'\t' -k1,1 -k2,2n \
    | LC_ALL=C awk -F'\t' "$AWK_LIB"'
        function flush() {
            if (cur == "") return
            printf "%d\t%s,%d,%d,%s,%d,%s\n", union, csvq(cur), launches, act, hms(act), union, hms(union)
        }
        {
            if ($1 != cur) { flush(); cur = $1; ce = 0; union = 0; launches = 0; act = 0 }
            launches++; act += $4
            if ($2 >= ce) { union += $3 - $2; ce = $3 }
            else if ($3 > ce) { union += $3 - ce; ce = $3 }
        }
        END { flush() }' \
    | LC_ALL=C sort -t $'\t' -k1,1nr | cut -f2- | head -n "$top"
}

# analyzer_daily FROM TO — launches and active time per start date.
analyzer_daily() {
    local from=${1-} to=${2-}
    local -a files
    mapfile -t files < <(analyzer_files processes)
    printf 'date,launches,active_sec,active_hms\n'
    if (( ${#files[@]} == 0 )); then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != 17) next
            d = substr(f[8], 1, 10)
            if (!in_range(d)) next
            n[d]++; a[d] += f[15]
        }
        END { for (d in n) printf "%s,%d,%d,%s\n", d, n[d], a[d], hms(a[d]) }' "${files[@]}" \
    | LC_ALL=C sort -t, -k1,1
}

# analyzer_summary FROM TO — headline numbers for the period.
# Dates are UTC (the stored timezone). ACTIVE / INTERRUPTED sessions have no
# duration, so they are counted but not included in the time totals.
analyzer_summary() {
    local from=${1-} to=${2-}
    local -a pf
    mapfile -t pf < <(analyzer_files processes)
    printf 'metric,value\n'
    printf 'period_from,%s\nperiod_to,%s\n' "${from:-all}" "${to:-all}"
    printf 'timezone,UTC\n'
    printf 'sampling_interval_sec,%s\n' "$INTERVAL_SEC"
    printf 'accuracy_note,"end times are detection times (up to one interval late)"\n'
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
    if (( ${#pf[@]} > 0 )); then
        LC_ALL=C awk -v from="$from" -v to="$to" "$AWK_LIB"'
            FNR > 1 {
                if (csv_split($0, f) != 17) next
                if (!in_range(substr(f[8], 1, 10))) next
                n++; act += f[15]; apps[f[5]] = 1
            }
            END {
                for (a in apps) distinct++
                printf "process_rows,%d\ndistinct_apps,%d\ntotal_active_hms,%s\n", n, distinct, hms(act)
            }' "${pf[@]}"
    else
        printf 'process_rows,0\n'
    fi
}

# analyzer_raw KIND FROM TO — header + rows of the period (used by reports).
#   KIND = processes | sessions   (sessions are filtered on Login_Date, UTC)
analyzer_raw() {
    local kind=$1 from=${2-} to=${3-} header cols datecol
    local -a files
    if [[ $kind == processes ]]; then
        header=$PROCESSES_HEADER; cols=17; datecol=8
        mapfile -t files < <(analyzer_files processes)
    else
        header=$SESSIONS_HEADER; cols=9; datecol=4
        files=()
        if [[ -s $SESSIONS_FILE ]]; then files=("$SESSIONS_FILE"); fi
    fi
    printf '%s\n' "$header"
    if (( ${#files[@]} == 0 )); then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" -v cols="$cols" -v dc="$datecol" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != cols) next
            if (in_range(substr(f[dc], 1, 10))) print $0
        }' "${files[@]}"
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
