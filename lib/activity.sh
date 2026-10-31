#!/usr/bin/env bash
# =============================================================================
# lib/activity.sh — Activity Analyzer
# -----------------------------------------------------------------------------
# Reads sessions.csv, processes.csv and process_details.csv (READ-ONLY — the raw
# data is never modified) and computes usage statistics with awk / sort / uniq.
#
# Different measures, kept apart on purpose
#   Session time        login -> logout of the user's sessions (closed ones).
#                       This is "Total Usage Duration".
#   Application time    for one application: the UNION of the intervals of all its
#                       processes ("Active_Seconds"). Ten browser processes running
#                       together for one hour are one hour, not ten.
#   Process-seconds     the plain SUM of process durations. Concurrent processes add
#                       up, so it is NOT usage time; it is only reported (clearly
#                       labelled) for transparency.
#
# Incomplete data is never presented as a normal result
#   COMPLETED     the end was seen: a natural end.
#   SESSION_END   monitoring stopped while it was still running -> duration is a
#                 lower bound, not a natural end.
#   RECOVERED     the monitor had died -> the end is an estimate.
#   Averages ("Average Process Duration", "Average Instance Duration") use
#   COMPLETED items only; the others are counted separately, and every section
#   says how many were left out. Sessions that are ACTIVE or INTERRUPTED have no
#   duration and are counted but never added to the totals.
#
# Application = what a user would call an application
#   process_details.csv records, for each process, the application instance it
#   belongs to (children join their parent's group, see detector.sh), so one
#   browser with twelve processes is one launch. Rows without details are kept as
#   class "Unknown" and are never merged into an application by guesswork.
#   A "launch" is an application root that was started while monitoring (not one
#   merely found already running).
#
# Time rules
#   * Everything is UTC. --utc-offset only moves the DAY BOUNDARIES (for daily
#     statistics and period filters); it never rewrites stored data.
#   * Counts (sessions, processes, launches) belong to the day they STARTED.
#     Durations are clipped to the requested period and split at midnight.
#   * A process that was already running when monitoring began is measured from
#     the moment monitoring first saw it, not from its real start.
# =============================================================================

ACT_FROM="" ACT_TO="" ACT_OFFSET=0
ACT_FROM_TS=0 ACT_TO_TS=4102444800        # 2100-01-01: "no upper bound"
ACT_ROWS=""                               # normalised process rows ("R"/"Q" lines)
ACT_SESS=""                               # normalised session rows ("S"/"Q" lines)

# --- small helpers -------------------------------------------------------------

# _act_lines VALUE — print VALUE followed by a newline, but print nothing at all
# when it is empty (a here-string of "" would inject a blank line).
_act_lines() { if [[ -n $1 ]]; then printf '%s\n' "$1"; fi; }

# _act_union — stdin: key<TAB>start<TAB>end ; stdout: key<TAB>union_seconds.
# Overlapping intervals of the same key are merged, so concurrency is not counted twice.
_act_union() {
    LC_ALL=C sort -t $'\t' -k1,1 -k2,2n | LC_ALL=C awk -F'\t' '
        function flush() { if (cur != "") printf "%s\t%.0f\n", cur, u }
        { if ($1 != cur) { flush(); cur = $1; u = 0; ce = 0 }
          if ($3 > $2) { if ($2 >= ce) { u += $3 - $2; ce = $3 } else if ($3 > ce) { u += $3 - ce; ce = $3 } } }
        END { flush() }'
}

# activity_prepare FROM TO OFFSET_SECONDS — load and validate the data once.
# Must be called before any other activity_* function.
activity_prepare() {
    local from=${1-} to=${2-} off=${3:-0} e
    ACT_FROM=$from; ACT_TO=$to; ACT_OFFSET=$off
    ACT_FROM_TS=0; ACT_TO_TS=4102444800
    if [[ -n $from ]] && common_utc_to_epoch e "$from" "00:00:00"; then ACT_FROM_TS=$(( e - off )); fi
    if [[ -n $to ]] && common_utc_to_epoch e "$to" "00:00:00"; then ACT_TO_TS=$(( e + 86400 - off )); fi
    ACT_ROWS=$(_act_load_processes)
    ACT_SESS=$(_act_load_sessions)
}

# --- loaders: validate, normalise, clip --------------------------------------------

# _act_load_processes — join processes.csv with process_details.csv and emit
#   R  app class root pre status session pid name start end dur counted cs ce day instance cpu start_str end_str
#   Q  reason count                       (data-quality counters)
# `counted`=1 when the process STARTED inside the period. cs..ce is the part of
# its life that counts as usage: clipped to the period and, for processes found
# already running, to the moment monitoring first saw them.
_act_load_processes() {
    local -a files=()
    if [[ -s $PROCESS_DETAILS_FILE ]]; then files+=("$PROCESS_DETAILS_FILE"); fi
    if [[ -s $PROCESSES_FILE ]]; then files+=("$PROCESSES_FILE"); fi
    if (( ${#files[@]} == 0 )); then return 0; fi
    LC_ALL=C awk -v off="$ACT_OFFSET" -v from_ts="$ACT_FROM_TS" -v to_ts="$ACT_TO_TS" -v pfile="$PROCESSES_FILE" "$AWK_LIB"'
        function clean(s) { gsub(/[\t\r\n]/, " ", s); return s }
        FNR == 1 { next }
        FILENAME != pfile {                                           # ---- process_details.csv
            if (csv_split($0, d) != 20) { q["details_rows_malformed"]++; next }
            k = d[1] "|" d[2] "|" d[3]
            if (k in dseen) { q["details_rows_duplicate"]++; next }
            dseen[k] = 1
            dcls[k] = d[6]; dapp[k] = d[7]; dinst[k] = d[8]; droot[k] = d[9]; dpre[k] = d[10]
            ddet[k] = epoch(d[11]); dcpu[k] = d[14] + 0
            dse[k] = (d[19] ~ /^[0-9]+$/) ? d[19] + 0 : -1
            next
        }
        {                                                             # ---- processes.csv
            if (csv_split($0, f) != 8) { q["process_rows_malformed"]++; next }
            k = f[1] "|" f[2] "|" f[5]
            if (k in pseen) { q["process_rows_duplicate"]++; next }
            pseen[k] = 1
            s = (k in dse && dse[k] >= 0) ? dse[k] : epoch(f[5])
            if (s < 0) { q["process_rows_invalid_start_time"]++; next }
            st = f[8]
            if (st !~ /^(COMPLETED|SESSION_END|RECOVERED)$/) { q["process_rows_unknown_status_treated_as_incomplete"]++; st = "UNKNOWN" }
            e2 = epoch(f[6])
            if (f[7] ~ /^[0-9]+$/) dur = f[7] + 0
            else {
                if (e2 < s) { q["process_rows_without_usable_duration_skipped"]++; next }
                dur = e2 - s; q["process_duration_recomputed_from_times"]++
            }
            if (e2 >= 0 && (e2 - s - dur > 2 || s + dur - e2 > 2)) q["process_duration_differs_from_end_time"]++
            e = s + dur
            if (k in dcls) { cl = dcls[k]; ap = dapp[k]; rt = droot[k]; pre = dpre[k]; ins = dinst[k]; cpu = dcpu[k]; det = ddet[k] }
            else { q["process_rows_without_details"]++; cl = "Unknown"; ap = f[3]; rt = "yes"; pre = "unknown"; ins = "u-" f[2] "-" s; cpu = 0; det = -1 }
            if (cl != "User_Application" && cl != "Background_Process") cl = "Unknown"
            cs = s; ce = e
            if (pre == "yes" && det > cs) cs = det            # only the monitored part of a pre-existing process
            if (cs < from_ts) cs = from_ts
            if (ce > to_ts) ce = to_ts
            if (ce <= cs) { cs = 0; ce = 0 }
            counted = (s >= from_ts && s < to_ts) ? 1 : 0
            printf "R\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%.0f\t%.0f\t%.0f\t%d\t%.0f\t%.0f\t%s\t%s\t%.0f\t%s\t%s\n",
                clean(ap), cl, rt, pre, st, f[1], f[2], clean(f[3]), s, e, dur, counted, cs, ce, daykey(s, off), clean(ins), cpu, fmt_ts(s), fmt_ts(e)
        }
        END {
            for (k in dseen) if (!(k in pseen)) q["details_rows_without_process_row"]++
            for (r in q) printf "Q\t%s\t%d\n", r, q[r]
        }' "${files[@]}"
}

# _act_load_sessions — sessions.csv normalised:
#   S  id user login_epoch status duration(-1 = unknown) counted cs ce day login_str logout_str
_act_load_sessions() {
    if [[ ! -s $SESSIONS_FILE ]]; then return 0; fi
    LC_ALL=C awk -v off="$ACT_OFFSET" -v from_ts="$ACT_FROM_TS" -v to_ts="$ACT_TO_TS" "$AWK_LIB"'
        function clean(s) { gsub(/[\t\r\n]/, " ", s); return s }
        FNR == 1 { next }
        {
            if (csv_split($0, f) != 9) { q["session_rows_malformed"]++; next }
            id = f[1]
            if (id in seen) { q["session_rows_duplicate"]++; next }
            seen[id] = 1
            ls = epoch(f[4] " " f[5])
            if (ls < 0) { q["session_rows_invalid_login_time"]++; next }
            st = f[9]
            if (st !~ /^(ACTIVE|COMPLETED|ABORTED|CRASHED|POWER_LOSS|INTERRUPTED)$/) { q["session_rows_unknown_status"]++; next }
            dur = -1                                   # ACTIVE / INTERRUPTED: no duration, never totalled
            if (st ~ /^(COMPLETED|ABORTED|CRASHED|POWER_LOSS)$/) {
                if (f[8] ~ /^[0-9]+$/) dur = f[8] + 0
                else {
                    le = epoch(f[6] " " f[7])
                    if (le >= ls) { dur = le - ls; q["session_duration_recomputed_from_times"]++ }
                    else q["session_closed_without_usable_duration"]++
                }
            }
            cs = ls; ce = (dur >= 0) ? ls + dur : ls
            if (cs < from_ts) cs = from_ts
            if (ce > to_ts) ce = to_ts
            if (ce <= cs) { cs = 0; ce = 0 }
            counted = (ls >= from_ts && ls < to_ts) ? 1 : 0
            printf "S\t%s\t%s\t%.0f\t%s\t%.0f\t%d\t%.0f\t%.0f\t%s\t%s\t%s\n",
                clean(id), clean(f[2]), ls, st, dur, counted, cs, ce, daykey(ls, off), fmt_ts(ls), (dur >= 0 ? fmt_ts(ls + dur) : "")
        }
        END { for (r in q) printf "Q\t%s\t%d\n", r, q[r] }' "$SESSIONS_FILE"
}

# --- totals used by several reports ------------------------------------------------

# _act_session_seconds — total session time in the period: union of the closed
# sessions' intervals, clipped to the period.
_act_session_seconds() {
    local r
    r=$(LC_ALL=C awk -F'\t' '$1 == "S" && $9 > $8 { print "ALL\t" $8 "\t" $9 }' <<<"$ACT_SESS" | _act_union | cut -f2)
    printf '%s\n' "${r:-0}"
}

# _act_ua_seconds — time during which AT LEAST ONE user application was running.
_act_ua_seconds() {
    local r
    r=$(LC_ALL=C awk -F'\t' '$1 == "R" && $3 == "User_Application" && $15 > $14 { print "ALL\t" $14 "\t" $15 }' <<<"$ACT_ROWS" | _act_union | cut -f2)
    printf '%s\n' "${r:-0}"
}

# --- Applications -----------------------------------------------------------------

# activity_apps CLASS TOP — applications ranked by Active_Seconds (CSV).
#   CLASS = User_Application (default) | Background_Process
#   Launches          application instances started while monitoring (roots only)
#   Already_Running   instances that were found running when monitoring began
#   Processes         process rows of the application (helpers included)
#   Active_Seconds    union of all its processes' intervals  (usage time)
#   Pct_Of_Session_Time  Active_Seconds / total session time
#   Avg_Instance_Seconds mean length of instances whose start AND natural end were
#                     seen (root COMPLETED, not found-running); Completed_Instances = how many
#   Process_Seconds   plain sum of process durations (concurrent processes add up;
#                     NOT usage time)
activity_apps() {
    local class=${1:-User_Application} top=${2:-10} total a_union i_union
    total=$(_act_session_seconds)
    a_union=$(LC_ALL=C awk -F'\t' -v c="$class" '$1 == "R" && $3 == c && $15 > $14 { print $2 "\t" $14 "\t" $15 }' <<<"$ACT_ROWS" | _act_union)
    i_union=$(LC_ALL=C awk -F'\t' -v c="$class" '$1 == "R" && $3 == c && $15 > $14 { print $2 "\034" $17 "\t" $14 "\t" $15 }' <<<"$ACT_ROWS" | _act_union)
    printf 'Rank,App_Name,Launches,Already_Running,Processes,Completed_Processes,Incomplete_Processes,Active_Seconds,Active_HMS,Pct_Of_Session_Time,Avg_Instance_Seconds,Avg_Instance_HMS,Completed_Instances,Process_Seconds,CPU_Seconds\n'
    {
        LC_ALL=C awk -F'\t' -v c="$class" '$1 == "R" && $3 == c' <<<"$ACT_ROWS"
        _act_lines "$a_union" | sed 's/^/U\t/'
        _act_lines "$i_union" | sed 's/^/N\t/'
    } | LC_ALL=C awk -F'\t' -v total="$total" "$AWK_LIB"'
        $1 == "R" {
            a = $2; apps[a] = 1; key = a SUBSEP $17
            psec[a] += ($15 > $14) ? $15 - $14 : 0
            if ($13 == 1) {
                procs[a]++; cpu[a] += $18
                if ($6 == "COMPLETED") comp[a]++; else inc[a]++
            }
            if ($4 == "yes") {                                  # the root row defines the instance
                if ($13 == 1) { if ($5 == "no") launches[a]++; else if ($5 == "yes") already[a]++ }
                if ($13 == 1 && $5 == "no" && $6 == "COMPLETED") full[key] = 1
            }
        }
        $1 == "U" { active[$2] = $3 }
        $1 == "N" { split($2, kk, "\034"); key = kk[1] SUBSEP kk[2]; if (key in full) { ninst[kk[1]]++; isum[kk[1]] += $3 } }
        END {
            for (a in apps) {
                act = (a in active) ? active[a] : 0
                if (act == 0 && procs[a] == 0 && psec[a] == 0) continue
                pct = (total > 0) ? sprintf("%.2f", 100 * act / total) : ""
                avg = ""; avgh = ""
                if (ninst[a] > 0) { avg = sprintf("%.1f", isum[a] / ninst[a]); avgh = hms(isum[a] / ninst[a] + 0.5) }
                printf "%.0f\t%d\t%s\t%s,%d,%d,%d,%d,%d,%.0f,%s,%s,%s,%s,%d,%.0f,%d\n", act, launches[a], tolower(a), csvq(a),
                    launches[a], already[a], procs[a], comp[a], inc[a], act, hms(act), pct, avg, avgh, ninst[a], psec[a], cpu[a]
            }
        }' \
    | LC_ALL=C sort -t $'\t' -k1,1nr -k2,2nr -k3,3 \
    | LC_ALL=C awk -F'\t' '{ printf "%d,%s\n", NR, $4 }' | head -n "$top"
}

# --- Daily -------------------------------------------------------------------------

# activity_daily — one row per calendar day (UTC, or UTC+offset) with any activity.
#   Sessions / Processes / launches are counted on the day they STARTED.
#   Session_Seconds, App_Active_Seconds are split at midnight.
#   App_Active_Seconds = time with at least one user application running
#                        (concurrent apps are NOT added together).
#   Avg_Process_Seconds = mean of the COMPLETED processes that started that day.
activity_daily() {
    local s_union u_union d_apps
    s_union=$(LC_ALL=C awk -F'\t' -v off="$ACT_OFFSET" "$AWK_LIB"'
        $1 == "S" && $9 > $8 { n = day_segments($8, $9, off); for (i = 1; i <= n; i++) printf "%s\t%.0f\t%.0f\n", segd[i], sega[i], segb[i] }' <<<"$ACT_SESS" | _act_union)
    u_union=$(LC_ALL=C awk -F'\t' -v off="$ACT_OFFSET" "$AWK_LIB"'
        $1 == "R" && $3 == "User_Application" && $15 > $14 { n = day_segments($14, $15, off); for (i = 1; i <= n; i++) printf "%s\t%.0f\t%.0f\n", segd[i], sega[i], segb[i] }' <<<"$ACT_ROWS" | _act_union)
    d_apps=$(LC_ALL=C awk -F'\t' -v off="$ACT_OFFSET" "$AWK_LIB"'
        $1 == "R" && $3 == "User_Application" && $15 > $14 { n = day_segments($14, $15, off); for (i = 1; i <= n; i++) printf "%s\t%s\n", segd[i], $2 }' <<<"$ACT_ROWS" \
        | LC_ALL=C sort -u | cut -f1 | LC_ALL=C uniq -c | LC_ALL=C awk '{ print $2 "\t" $1 }')
    printf 'Date,Sessions,Session_Seconds,Session_HMS,Processes,User_App_Launches,Background_Processes,Completed_Processes,Incomplete_Processes,Avg_Process_Seconds,App_Active_Seconds,App_Active_HMS,Distinct_User_Apps\n'
    {
        LC_ALL=C awk -F'\t' '$1 == "S" && $7 == 1 { print "SC\t" $10 }
                             $1 == "R" && $13 == 1 { print "R\t" $0 }' <<<"$ACT_SESS"$'\n'"$ACT_ROWS"
        _act_lines "$s_union" | sed 's/^/SU\t/'
        _act_lines "$u_union" | sed 's/^/UU\t/'
        _act_lines "$d_apps"  | sed 's/^/DA\t/'
    } | LC_ALL=C awk -F'\t' "$AWK_LIB"'
        $1 == "SC" { days[$2] = 1; sess[$2]++ }
        $1 == "SU" { days[$2] = 1; ssec[$2] = $3 }
        $1 == "UU" { days[$2] = 1; usec[$2] = $3 }
        $1 == "DA" { days[$2] = 1; dapps[$2] = $3 }
        $1 == "R" {                                        # $2.. = the R row
            d = $17; days[d] = 1; np[d]++
            if ($4 == "User_Application" && $5 == "yes" && $6 == "no") launch[d]++
            if ($4 == "Background_Process") bg[d]++
            if ($7 == "COMPLETED") { comp[d]++; csum[d] += $13 } else inc[d]++
        }
        END {
            for (d in days)
                printf "%s,%d,%.0f,%s,%d,%d,%d,%d,%d,%s,%.0f,%s,%d\n", d, sess[d], ssec[d], hms(ssec[d]), np[d], launch[d], bg[d], comp[d], inc[d],
                    (comp[d] > 0 ? sprintf("%.1f", csum[d] / comp[d]) : ""), usec[d], hms(usec[d]), dapps[d]
        }' | LC_ALL=C sort -t, -k1,1
}

# --- Sessions ----------------------------------------------------------------------

# activity_sessions — one row per session with its process totals.
#   Duration_Quality: EXACT (clean close) · ESTIMATED (crash / power loss: end =
#   last heartbeat) · UNKNOWN (still ACTIVE, or INTERRUPTED with no end known).
#   Processes are attributed by Session_ID (the session in which they were first
#   seen). Process Session_IDs that have no session row appear as MISSING_SESSION.
activity_sessions() {
    printf 'Session_ID,Login_UTC,Logout_UTC,Status,Duration_Quality,Duration_Seconds,Duration_Minutes,Duration_HMS,Processes,User_App_Launches,Background_Processes,Completed_Processes,Incomplete_Processes,Distinct_User_Apps\n'
    {
        _act_lines "$ACT_SESS" | LC_ALL=C awk -F'\t' '$1 == "S" && $7 == 1'
        _act_lines "$ACT_ROWS" | LC_ALL=C awk -F'\t' '$1 == "R"'
    } | LC_ALL=C awk -F'\t' "$AWK_LIB"'
        $1 == "S" { sid[$2] = 1; order[$2] = $4; st[$2] = $5; dur[$2] = $6; li[$2] = $11; lo[$2] = $12 }
        $1 == "R" {
            s = $7; used[s] = 1
            if ($13 == 1 || ($7 in sid)) {
                np[s]++
                if ($3 == "User_Application" && $4 == "yes" && $5 == "no") launch[s]++
                if ($3 == "Background_Process") bg[s]++
                if ($6 == "COMPLETED") comp[s]++; else inc[s]++
                if ($3 == "User_Application") apps[s SUBSEP $2] = 1
            }
        }
        END {
            for (k in apps) { split(k, kk, SUBSEP); napps[kk[1]]++ }
            for (s in sid) {
                q = (st[s] ~ /^(COMPLETED|ABORTED)$/) ? "EXACT" : (st[s] ~ /^(CRASHED|POWER_LOSS)$/) ? "ESTIMATED" : "UNKNOWN"
                d = dur[s]
                printf "%.0f\t%s,%s,%s,%s,%s,%s,%s,%s,%d,%d,%d,%d,%d,%d\n", order[s], idq(s), li[s], lo[s], st[s], q,
                    (d >= 0 ? sprintf("%.0f", d) : ""), (d >= 0 ? sprintf("%d.%02d", d / 60, (d % 60) * 100 / 60) : ""), (d >= 0 ? hms(d) : ""),
                    np[s], launch[s], bg[s], comp[s], inc[s], napps[s]
            }
            for (s in used) if (!(s in sid) && np[s] > 0)
                printf "99999999999\t%s,,,MISSING_SESSION,UNKNOWN,,,,%d,%d,%d,%d,%d,%d\n", idq(s), np[s], launch[s], bg[s], comp[s], inc[s], napps[s]
        }' | LC_ALL=C sort -t $'\t' -k1,1n -k2,2 | cut -f2-
}

# --- Per-process durations ----------------------------------------------------------

# activity_processes — the duration of every process that started in the period.
#   Natural_End = yes only for COMPLETED. For the others Duration_Seconds is a
#   lower bound (SESSION_END) or an estimate (RECOVERED), and Note says so.
activity_processes() {
    printf 'Session_ID,PID,Process_Name,Application,Class,Start_Time_UTC,End_Time_UTC,Duration_Seconds,Duration_HMS,Status,Natural_End,Started_Before_Monitoring,Note\n'
    LC_ALL=C awk -F'\t' "$AWK_LIB"'
        $1 == "R" && $13 == 1 {
            note = ""
            if ($6 == "SESSION_END") note = "still running when monitoring stopped: duration is a lower bound"
            else if ($6 == "RECOVERED") note = "monitor had died: end time is an estimate (last heartbeat)"
            else if ($6 == "UNKNOWN") note = "unrecognised status: treated as incomplete"
            if ($5 == "yes") note = note (note != "" ? "; " : "") "already running when monitoring began (true start shown)"
            printf "%.0f\t%d\t%s,%s,%s,%s,%s,%s,%s,%d,%s,%s,%s,%s,%s\n", $10, $8, idq($7), $8, csvq($9), csvq($2), $3, $19, $20, $12, hms($12), $6,
                ($6 == "COMPLETED" ? "yes" : "no"), ($5 == "yes" ? "yes" : ($5 == "no" ? "no" : "unknown")), csvq(note)
        }' <<<"$ACT_ROWS" | LC_ALL=C sort -t $'\t' -k1,1n -k2,2n | cut -f3-
}

# --- Summary -----------------------------------------------------------------------

# _act_kv — headline numbers as "key<TAB>value" lines (used by the summary CSV and
# the text report).
_act_kv() {
    local apps_all kv_stats
    apps_all=$(activity_apps User_Application 1000000)
    kv_stats=$({ _act_lines "$ACT_SESS" | LC_ALL=C awk -F'\t' '$1 == "S"'; _act_lines "$ACT_ROWS" | LC_ALL=C awk -F'\t' '$1 == "R"'; } \
        | LC_ALL=C awk -F'\t' '
        $1 == "S" && $7 == 1 {
            ns++; sc[$5]++
            if ($6 >= 0) { nclosed++; dsum += $6; if ($5 == "CRASHED" || $5 == "POWER_LOSS") nest++ }
        }
        $1 == "R" {
            pclip += ($15 > $14) ? $15 - $14 : 0
            if ($13 != 1) next
            np++
            if ($3 == "User_Application") nua++; else if ($3 == "Background_Process") nbg++; else nunk++
            if ($6 == "COMPLETED") { nc++; csum += $12; if ($12 > cmax) { cmax = $12; cname = $9 " (PID " $8 ")" } }
            else if ($6 == "SESSION_END") nse++; else if ($6 == "RECOVERED") nrec++; else nothr++
            if ($3 == "User_Application" && $4 == "yes") { if ($5 == "no") nl++; else if ($5 == "yes") nal++ }
        }
        END {
            printf "sessions_total\t%d\nsessions_closed\t%d\nsessions_active\t%d\nsessions_interrupted\t%d\nsessions_estimated_end\t%d\n", ns, nclosed, sc["ACTIVE"], sc["INTERRUPTED"], nest
            printf "avg_session_seconds\t%s\n", (nclosed > 0 ? sprintf("%.1f", dsum / nclosed) : "")
            printf "processes_total\t%d\nprocesses_completed\t%d\nprocesses_session_end\t%d\nprocesses_recovered\t%d\nprocesses_other_incomplete\t%d\n", np, nc, nse, nrec, nothr
            printf "processes_user_app\t%d\nprocesses_background\t%d\nprocesses_unclassified\t%d\n", nua, nbg, nunk
            printf "avg_process_seconds\t%s\n", (nc > 0 ? sprintf("%.1f", csum / nc) : "")
            printf "longest_process\t%s\nlongest_process_seconds\t%.0f\n", cname, cmax
            printf "app_launches\t%d\napps_already_running\t%d\nprocess_seconds_sum\t%.0f\n", nl, nal, pclip
        }')
    printf '%s\n' "$kv_stats"
    printf 'period_from\t%s\nperiod_to\t%s\nutc_offset_seconds\t%s\n' "${ACT_FROM:-all}" "${ACT_TO:-all}" "$ACT_OFFSET"
    printf 'usage_seconds\t%s\nua_active_seconds\t%s\n' "$(_act_session_seconds)" "$(_act_ua_seconds)"
    _act_lines "$apps_all" | LC_ALL=C awk "$AWK_LIB"'
        NR == 1 { next }
        { csv_split($0, f); n++
          if (n == 1) { top = f[2]; topsec = f[8] }
          ci += f[13]; cisum += f[11] * f[13] }
        END { printf "distinct_user_apps\t%d\nmost_used_app\t%s\nmost_used_app_seconds\t%.0f\ncompleted_instances\t%d\navg_instance_seconds\t%s\n",
                n, top, topsec, ci, (ci > 0 ? sprintf("%.1f", cisum / ci) : "") }'
    activity_daily | LC_ALL=C awk -F, 'NR == 1 { next } { n++; if ($11 + 0 > best) { best = $11 + 0; bd = $1 } }
        END { printf "days_with_activity\t%d\nbusiest_day\t%s\nbusiest_day_seconds\t%.0f\n", n, bd, best }'
    local running=0
    if daemon_is_running && [[ -s $ACTIVE_FILE ]]; then running=$(grep -c '' "$ACTIVE_FILE"); fi
    printf 'processes_running_now_excluded\t%s\n' "$running"
}

# _act_load_kv — fill the caller's associative array K (declared `local -A K`) from _act_kv,
# with an empty default for every key so `set -u` can never trip on a missing one.
_act_load_kv() {
    local k v
    for k in sessions_total sessions_closed sessions_active sessions_interrupted sessions_estimated_end avg_session_seconds \
        processes_total processes_completed processes_session_end processes_recovered processes_other_incomplete \
        processes_user_app processes_background processes_unclassified avg_process_seconds longest_process \
        longest_process_seconds app_launches apps_already_running process_seconds_sum period_from period_to \
        utc_offset_seconds usage_seconds ua_active_seconds distinct_user_apps most_used_app most_used_app_seconds \
        completed_instances avg_instance_seconds days_with_activity busiest_day busiest_day_seconds \
        processes_running_now_excluded; do
        K[$k]=""
    done
    while IFS=$'\t' read -r k v; do K[$k]=$v; done < <(_act_kv)
}

# activity_summary — the headline report as CSV: Metric,Value,Note.
activity_summary() {
    local -A K=()
    local k v hms avg
    _act_load_kv
    _row() { csv_row rtt "$1" "$2" "$3"; printf '%s\n' "$REPLY"; }
    _hms() { if [[ ${1-} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then common_fmt_hms hms "${1%.*}"; printf '%s' "$hms"; fi; }
    printf 'Metric,Value,Note\n'
    _row Period_From "${K[period_from]}" "inclusive, UTC calendar days (moved by the UTC offset)"
    _row Period_To "${K[period_to]}" ""
    _row UTC_Offset_Seconds "${K[utc_offset_seconds]}" "only moves day boundaries; stored data is UTC"
    _row Total_Sessions "${K[sessions_total]}" "sessions that STARTED in the period"
    _row Sessions_Closed "${K[sessions_closed]}" "have a logout time and a duration"
    _row Sessions_Active "${K[sessions_active]}" "still open: no duration, not in any total"
    _row Sessions_Interrupted "${K[sessions_interrupted]}" "end unknown: no duration, not in any total"
    _row Sessions_With_Estimated_End "${K[sessions_estimated_end]}" "crash or power loss: end = last heartbeat"
    _row Total_Usage_Duration_Seconds "${K[usage_seconds]}" "login to logout of closed sessions, overlaps merged, clipped to the period"
    _row Total_Usage_Duration_HMS "$(_hms "${K[usage_seconds]}")" ""
    _row Average_Session_Duration_Seconds "${K[avg_session_seconds]}" "closed sessions only"
    _row Total_Processes "${K[processes_total]}" "process rows that STARTED in the period"
    _row Processes_Completed "${K[processes_completed]}" "end observed: natural end"
    _row Processes_Session_End "${K[processes_session_end]}" "still running when monitoring stopped: NOT a natural end"
    _row Processes_Recovered "${K[processes_recovered]}" "monitor died: end is an estimate, NOT a natural end"
    _row Processes_User_Application "${K[processes_user_app]}" "application processes, helpers included"
    _row Processes_Background "${K[processes_background]}" ""
    _row Processes_Unclassified "${K[processes_unclassified]}" "no details row: never merged into an application"
    _row Average_Process_Duration_Seconds "${K[avg_process_seconds]}" "COMPLETED processes only; empty = none to average"
    avg=${K[avg_process_seconds]}
    _row Average_Process_Duration_HMS "$(_hms "$avg")" ""
    _row Longest_Completed_Process "${K[longest_process]}" "${K[longest_process_seconds]} s"
    _row User_Application_Launches "${K[app_launches]}" "application instances started while monitoring (found-running ones excluded)"
    _row Applications_Already_Running "${K[apps_already_running]}" "found running when monitoring began: not launches"
    _row Distinct_User_Applications "${K[distinct_user_apps]}" ""
    _row Most_Used_Application "${K[most_used_app]}" "highest Active_Seconds"
    _row Most_Used_Application_Seconds "${K[most_used_app_seconds]}" "union of its processes' intervals"
    _row Average_Application_Instance_Seconds "${K[avg_instance_seconds]}" "instances whose start and natural end were both seen (${K[completed_instances]} of them)"
    _row User_App_Active_Time_Seconds "${K[ua_active_seconds]}" "time with at least one user application running (concurrent apps NOT added together)"
    _row Process_Seconds_Sum "${K[process_seconds_sum]}" "plain sum of process durations: concurrent processes add up, so this is NOT usage time"
    _row Days_With_Activity "${K[days_with_activity]}" ""
    _row Busiest_Day "${K[busiest_day]}" "most user-application active time (${K[busiest_day_seconds]} s)"
    _row Processes_Still_Running_Excluded "${K[processes_running_now_excluded]}" "being tracked right now; they appear after they end"
    unset -f _row _hms
}

# activity_quality — how much of the data could not be used or is not a natural result.
activity_quality() {
    printf 'Check,Count,Meaning\n'
    { _act_lines "$ACT_ROWS" | LC_ALL=C awk -F'\t' '$1 == "Q"'; _act_lines "$ACT_SESS" | LC_ALL=C awk -F'\t' '$1 == "Q"'; } \
    | LC_ALL=C awk -F'\t' "$AWK_LIB"'
        BEGIN {
            m["process_rows_malformed"] = "processes.csv lines with the wrong number of fields (skipped)"
            m["process_rows_duplicate"] = "repeated (Session_ID, PID, Start_Time): counted once"
            m["process_rows_invalid_start_time"] = "unreadable Start_Time (skipped)"
            m["process_rows_without_usable_duration_skipped"] = "Duration_Seconds not numeric and End_Time unusable (skipped)"
            m["process_duration_recomputed_from_times"] = "Duration_Seconds not numeric: recomputed from Start/End_Time"
            m["process_duration_differs_from_end_time"] = "Duration_Seconds disagrees with End - Start by more than 2 s (Duration_Seconds used)"
            m["process_rows_without_details"] = "no process_details row: class Unknown, not merged into any application"
            m["process_rows_unknown_status_treated_as_incomplete"] = "Status not recognised: treated as incomplete"
            m["details_rows_malformed"] = "process_details.csv lines with the wrong number of fields (skipped)"
            m["details_rows_duplicate"] = "repeated details key: first one used"
            m["details_rows_without_process_row"] = "details row whose processes.csv row is missing (ignored)"
            m["session_rows_malformed"] = "sessions.csv lines with the wrong number of fields (skipped)"
            m["session_rows_duplicate"] = "repeated Session_ID: counted once"
            m["session_rows_invalid_login_time"] = "unreadable login time (skipped)"
            m["session_rows_unknown_status"] = "unknown Status (skipped)"
            m["session_duration_recomputed_from_times"] = "Duration_Seconds missing on a closed session: recomputed from Login/Logout"
            m["session_closed_without_usable_duration"] = "closed session with no usable duration: left out of the totals"
        }
        { c[$2] += $3 }
        END { for (r in c) printf "%s,%d,%s\n", r, c[r], csvq((r in m) ? m[r] : r) }' | LC_ALL=C sort -t, -k1,1
}

# --- Text report ---------------------------------------------------------------------

# activity_pretty — align CSV (from stdin) into a readable table.
activity_pretty() {
    LC_ALL=C awk "$AWK_LIB"'
        { n = csv_split($0, f); if (n > nc) nc = n; for (i = 1; i <= n; i++) { cell[NR, i] = f[i]; if (length(f[i]) > w[i]) w[i] = length(f[i]) } rows = NR }
        END {
            for (r = 1; r <= rows; r++) {
                line = ""
                for (i = 1; i <= nc; i++) line = line sprintf("%-" w[i] "s  ", cell[r, i])
                sub(/ +$/, "", line); print "  " line
                if (r == 1) { sep = ""; for (i = 1; i <= nc; i++) { x = ""; for (j = 0; j < w[i]; j++) x = x "-"; sep = sep x "  " }; sub(/ +$/, "", sep); print "  " sep }
            }
        }'
}

# activity_text_report TOP — the complete human-readable report.
activity_text_report() {
    local top=${1:-10} k v hms avg tz
    local -A K=()
    _act_load_kv
    _h() { if [[ ${1-} =~ ^[0-9]+(\.[0-9]+)?$ ]]; then common_fmt_hms hms "${1%.*}"; printf '%s' "$hms"; else printf 'n/a'; fi; }
    printf -v tz 'UTC%+d:%02d' $(( ACT_OFFSET / 3600 )) $(( (ACT_OFFSET < 0 ? -ACT_OFFSET : ACT_OFFSET) % 3600 / 60 ))
    echo "=============================================================="
    echo " ACTIVITY REPORT   user: $CAL_USER"
    echo " Period: ${K[period_from]} .. ${K[period_to]}   Days: $tz"
    echo "=============================================================="
    printf ' %-28s %s   (%s closed, %s active, %s interrupted)\n' "Total Sessions" "${K[sessions_total]}" \
        "${K[sessions_closed]}" "${K[sessions_active]}" "${K[sessions_interrupted]}"
    printf ' %-28s %s   (%s finished normally, %s incomplete)\n' "Total Processes" "${K[processes_total]}" \
        "${K[processes_completed]}" "$(( K[processes_session_end] + K[processes_recovered] + K[processes_other_incomplete] ))"
    printf ' %-28s %s  (%s s)  closed sessions only\n' "Total Usage Duration" "$(_h "${K[usage_seconds]}")" "${K[usage_seconds]}"
    avg=${K[avg_process_seconds]}
    printf ' %-28s %s  (%s s)  over %s processes that ended normally\n' "Average Process Duration" "$(_h "$avg")" "${avg:-n/a}" "${K[processes_completed]}"
    printf ' %-28s %s  (%s s)\n' "Average Session Duration" "$(_h "${K[avg_session_seconds]}")" "${K[avg_session_seconds]:-n/a}"
    printf ' %-28s %s launches, %s distinct applications\n' "User Applications" "${K[app_launches]}" "${K[distinct_user_apps]}"
    printf ' %-28s %s  (at least one app running; apps are not added together)\n' "Application Active Time" "$(_h "${K[ua_active_seconds]}")"
    echo
    echo "Most Used Applications  (ranked by active time; helpers merged into their application)"
    activity_apps User_Application "$top" | activity_pretty
    echo
    echo "Daily Usage Statistics"
    activity_daily | activity_pretty
    echo
    echo "Notes"
    printf '  - %s process(es) did not end normally and are NOT in the averages:\n' "$(( K[processes_session_end] + K[processes_recovered] + K[processes_other_incomplete] ))"
    printf '    %s still running when monitoring stopped (lower bound), %s with an estimated end (monitor died).\n' "${K[processes_session_end]}" "${K[processes_recovered]}"
    printf '  - %s session(s) have no duration (active/interrupted) and are not in Total Usage Duration; %s have an estimated end.\n' \
        "$(( K[sessions_total] - K[sessions_closed] ))" "${K[sessions_estimated_end]}"
    printf '  - Process-seconds (sum of all process durations) = %s s. It exceeds usage time because concurrent processes add up; it is not a usage measure.\n' "${K[process_seconds_sum]}"
    if (( K[processes_running_now_excluded] > 0 )); then printf '  - %s process(es) are running right now and will be counted after they end.\n' "${K[processes_running_now_excluded]}"; fi
    printf '  - Resolution: end times are detection times (up to one scan interval late); processes shorter than a scan may be missed.\n'
    printf '  - Data checks: see 07_data_quality.csv in a report, or run: ./main.sh stats --quality\n'
    unset -f _h
}
