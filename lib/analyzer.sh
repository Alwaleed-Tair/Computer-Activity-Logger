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

# Awk helpers shared by every program below (prepended to each script).
read -r -d '' AWK_LIB <<'AWK' || true
# Split one RFC-4180 CSV line into out[1..n]; returns n.
function csv_split(line, out,    n, i, len, c, f, inq) {
    split("", out); n = 0; f = ""; inq = 0; len = length(line)
    for (i = 1; i <= len; i++) {
        c = substr(line, i, 1)
        if (inq) {
            if (c == "\"") {
                if (substr(line, i + 1, 1) == "\"") { f = f "\""; i++ } else inq = 0
            } else f = f c
        } else if (c == "\"") inq = 1
        else if (c == ",") { out[++n] = f; f = "" }
        else f = f c
    }
    out[++n] = f
    return n
}
function hms(s) { return sprintf("%02d:%02d:%02d", s / 3600, (s % 3600) / 60, s % 60) }
# Quote a text field for CSV output (and block formula injection).
function csvq(s) {
    if (s ~ /^[=+@-]/) s = "'" s
    gsub(/"/, "\"\"", s)
    return "\"" s "\""
}
function in_range(d) { return !((from != "" && d < from) || (to != "" && d > to)) }
AWK

# analyzer_files KIND — print matching data files (processes | sessions).
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
analyzer_summary() {
    local from=${1-} to=${2-}
    local -a pf sf
    mapfile -t pf < <(analyzer_files processes)
    mapfile -t sf < <(analyzer_files sessions)
    printf 'metric,value\n'
    printf 'period_from,%s\nperiod_to,%s\n' "${from:-all}" "${to:-all}"
    printf 'sampling_interval_sec,%s\n' "$INTERVAL_SEC"
    printf 'accuracy_note,"end times are detection times (up to one interval late)"\n'
    if (( ${#sf[@]} > 0 )); then
        LC_ALL=C awk -v from="$from" -v to="$to" "$AWK_LIB"'
            FNR > 1 {
                if (csv_split($0, f) != 15) next
                if (!in_range(substr(f[5], 1, 10))) next
                n++; total += f[9]; if (f[9] > longest) longest = f[9]
            }
            END {
                printf "sessions,%d\nsessions_total_hms,%s\nlongest_session_hms,%s\navg_session_hms,%s\n",
                    n, hms(total), hms(longest), hms(n ? total / n : 0)
            }' "${sf[@]}"
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
analyzer_raw() {
    local kind=$1 from=${2-} to=${3-} header cols datecol
    local -a files
    mapfile -t files < <(analyzer_files "$kind")
    if [[ $kind == processes ]]; then header=$PROCESSES_HEADER; cols=17; datecol=8
    else header=$SESSIONS_HEADER; cols=15; datecol=5; fi
    printf '%s\n' "$header"
    if (( ${#files[@]} == 0 )); then return 0; fi
    LC_ALL=C awk -v from="$from" -v to="$to" -v cols="$cols" -v dc="$datecol" "$AWK_LIB"'
        FNR > 1 {
            if (csv_split($0, f) != cols) next
            if (in_range(substr(f[dc], 1, 10))) print $0
        }' "${files[@]}"
}
