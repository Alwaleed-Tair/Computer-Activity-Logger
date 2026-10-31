#!/usr/bin/env bash
# =============================================================================
# tests/test_activity.sh — Activity Analyzer tests
# -----------------------------------------------------------------------------
# A hand-built dataset with KNOWN answers (every expected number below was worked
# out by hand from the timeline in the comments, not copied from program output):
#
#   Sessions (UTC)
#     S1 2026-10-01 09:00-11:00  COMPLETED   7200 s
#     S2 2026-10-01 23:30 -> 10-02 00:30  COMPLETED 3600 s   (crosses midnight)
#     S3 2026-10-02 08:00-08:50  CRASHED     3000 s   (estimated end)
#     S4 2026-10-03 10:00        ACTIVE        (no duration)
#     S5 2026-10-03 12:00        INTERRUPTED   (no duration)
#   Processes  (start -> end, status, class/app, instance)
#     P1  S1 browserx   10-01 09:10-10:10 COMPLETED  UA Browser X root  i1
#     P2  S1 Web Content10-01 09:12-09:42 COMPLETED  UA Browser X child i1
#     P3  S1 gpuhelper  10-01 10:00-10:30 COMPLETED  UA Browser X child i1
#     P4  S1 editorx    10-01 09:30-10:00 COMPLETED  UA Editor X  root  i2
#     P5  S1 svc        10-01 08:00-11:00 SESSION_END BG svc root, FOUND RUNNING
#                       (monitoring first saw it at 09:00:05)
#     P6  S1 browserx   10-01 10:45-10:55 COMPLETED  UA Browser X root  i3
#     P7  S2 editorx    10-01 23:45 -> 10-02 00:15 COMPLETED UA Editor X root i4
#     P8  S3 browserx   10-02 08:05-08:35 RECOVERED  UA Browser X root  i6
#     P9  S3 worker     10-02 08:10-08:12 COMPLETED  BG worker root
#     P10 SX ghost      10-01 12:00-12:10 COMPLETED  UA Ghost root  (session SX has no row)
#     P11 S3 mystery    10-02 09:00:00-09:00:30 COMPLETED  (NO details row)
#     P12 S1 calc       10-01 10:30:00-10:31:40 COMPLETED BG calc (Duration field is "abc")
#   plus: a malformed line, an exact duplicate of P4, a garbage Start_Time, and a
#         details row whose process row does not exist.
# Everything runs in a temp dir; the real data/ is never touched.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/bin"
export DATA_DIR="$SANDBOX/data" STATE_DIR="$SANDBOX/state" REPORTS_DIR="$SANDBOX/reports"
export CONSENT_FILE="$SANDBOX/consent" INTERVAL_SEC=1 MIN_DURATION_SEC=0 CAL_ROOT="$ROOT"
export APPS_MAP_FILE="$SANDBOX/apps.map" IGNORE_FILE="$SANDBOX/ignore.list" DESKTOP_DIRS="$SANDBOX/none"
: >"$IGNORE_FILE"; printf '%s\n' 'appx|App X|editor' 'appy|App Y|editor' >"$APPS_MAP_FILE"   # BEFORE sourcing config.sh
FAILS=0 TOTAL=0

cleanup() { "$ROOT/main.sh" stop >/dev/null 2>&1 || true; rm -rf -- "$SANDBOX"; }
trap cleanup EXIT

pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]  actual: [$3]"; fi; }
expect_ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi; }
expect_between() { if [[ $4 =~ ^-?[0-9.]+$ ]] && awk -v v="$4" -v lo="$2" -v hi="$3" 'BEGIN { exit !(v >= lo && v <= hi) }'; then pass "$1 ($4)"; else fail "$1" "expected $2..$3, got [$4]"; fi; }
expect_grep() { if grep -Eq -- "$2" <<<"$3"; then pass "$1"; else fail "$1" "pattern [$2] not found"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

for _f in "$APPS_MAP_FILE" "$IGNORE_FILE" "$DATA_DIR" "$STATE_DIR"; do
    case $_f in "$SANDBOX"/*) ;; *) echo "ABORT: $_f is outside the sandbox"; exit 2 ;; esac
done
# shellcheck source=/dev/null
source "$ROOT/config.sh"
for m in common consent storage sessionlog collector detector session recovery daemon analyzer activity report; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$m.sh"
done
storage_init

# --- fixture builders (they write raw CSV exactly as the logger would) ---------------
ep() { date -u -d "$1" +%s; }
mk_files() {   # fresh headers
    rm -f -- "$SESSIONS_FILE" "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE"
    printf '\xEF\xBB\xBF%s\n' "$SESSIONS_HEADER" >"$SESSIONS_FILE"
    printf '\xEF\xBB\xBF%s\n' "$PROCESSES_HEADER" >"$PROCESSES_FILE"
    printf '\xEF\xBB\xBF%s\n' "$DETAILS_HEADER" >"$PROCESS_DETAILS_FILE"
}
mk_session() {   # ID LOGIN LOGOUT DURATION STATUS      ("" logout/duration for open sessions)
    local ld=${2%% *} lt=${2##* } od="" ot=""
    if [[ -n $3 ]]; then od=${3%% *}; ot=${3##* }; fi
    printf '%s,"tester",1000,%s,%s,%s,%s,%s,%s\n' "$1" "$ld" "$lt" "$od" "$ot" "$4" "$5" >>"$SESSIONS_FILE"
}
mk_proc() {   # SID PID NAME START END STATUS CLASS APP ROOT PRE INST [DETECTED_START] [DURATION_FIELD] [no-details]
    local sid=$1 pid=$2 name=$3 start=$4 end=$5 status=$6 class=$7 app=$8 root=$9 pre=${10} inst=${11}
    local det=${12:-$4} durf=${13:-} nodet=${14:-} s e dur
    name=${name//\"/\"\"}; app=${app//\"/\"\"}      # CSV-escape embedded quotes
    s=$(ep "$start"); e=$(ep "$end"); dur=$(( e - s ))
    printf '%s,%s,"%s","tester",%s,%s,%s,%s\n' "$sid" "$pid" "$name" "$start" "$end" "${durf:-$dur}" "$status" >>"$PROCESSES_FILE"
    if [[ $nodet != no-details ]]; then
        printf '%s,%s,%s,1,"%s",%s,"%s",%s,%s,%s,%s,%s,0,0,0.0,1000,1000,"cat",%s,%s\n' \
            "$sid" "$pid" "$start" "$name" "$class" "$app" "$inst" "$root" "$pre" "$det" "$end" "$s" "$e" >>"$PROCESS_DETAILS_FILE"
    fi
}
UA=User_Application; BG=Background_Process
build_dataset() {
    mk_files
    mk_session S1 "2026-10-01 09:00:00" "2026-10-01 11:00:00" 7200 COMPLETED
    mk_session S2 "2026-10-01 23:30:00" "2026-10-02 00:30:00" 3600 COMPLETED
    mk_session S3 "2026-10-02 08:00:00" "2026-10-02 08:50:00" 3000 CRASHED
    mk_session S4 "2026-10-03 10:00:00" "" "" ACTIVE
    mk_session S5 "2026-10-03 12:00:00" "" "" INTERRUPTED
    mk_proc S1  101 browserx       "2026-10-01 09:10:00" "2026-10-01 10:10:00" COMPLETED   $UA "Browser X" yes no  i1
    mk_proc S1  102 "Web Content"  "2026-10-01 09:12:00" "2026-10-01 09:42:00" COMPLETED   $UA "Browser X" no  no  i1
    mk_proc S1  103 gpuhelper      "2026-10-01 10:00:00" "2026-10-01 10:30:00" COMPLETED   $UA "Browser X" no  no  i1
    mk_proc S1  104 editorx        "2026-10-01 09:30:00" "2026-10-01 10:00:00" COMPLETED   $UA "Editor X"  yes no  i2
    mk_proc S1  105 svc            "2026-10-01 08:00:00" "2026-10-01 11:00:00" SESSION_END $BG "svc"       yes yes i5 "2026-10-01 09:00:05"
    mk_proc S1  106 browserx       "2026-10-01 10:45:00" "2026-10-01 10:55:00" COMPLETED   $UA "Browser X" yes no  i3
    mk_proc S2  107 editorx        "2026-10-01 23:45:00" "2026-10-02 00:15:00" COMPLETED   $UA "Editor X"  yes no  i4
    mk_proc S3  108 browserx       "2026-10-02 08:05:00" "2026-10-02 08:35:00" RECOVERED   $UA "Browser X" yes no  i6
    mk_proc S3  109 worker         "2026-10-02 08:10:00" "2026-10-02 08:12:00" COMPLETED   $BG "worker"    yes no  i7
    mk_proc SX  110 ghost          "2026-10-01 12:00:00" "2026-10-01 12:10:00" COMPLETED   $UA "Ghost"     yes no  i8
    mk_proc S3  111 mystery        "2026-10-02 09:00:00" "2026-10-02 09:00:30" COMPLETED   $UA "mystery"   yes no  i10 "" "" no-details
    mk_proc S1  112 calc           "2026-10-01 10:30:00" "2026-10-01 10:31:40" COMPLETED   $BG "calc"      yes no  i9  "" abc
    # damaged / duplicated / orphan lines
    echo 'S1,113,"bad"' >>"$PROCESSES_FILE"                                                       # wrong field count
    dup_line=$(grep ',104,"editorx"' "$PROCESSES_FILE"); printf '%s\n' "$dup_line" >>"$PROCESSES_FILE"      # exact duplicate of P4
    echo 'S1,114,"garbage","tester",not-a-date,2026-10-01 10:00:00,5,COMPLETED' >>"$PROCESSES_FILE" # unreadable Start_Time
    echo 'S1,999,2026-10-01 09:59:00,1,"orph",Background_Process,"orph",i99,yes,no,2026-10-01 09:59:00,2026-10-01 10:00:00,0,0,0.0,1,1,"cat",1,2' >>"$PROCESS_DETAILS_FILE"
}
checksums() { sha256sum "$SESSIONS_FILE" "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE" 2>/dev/null | awk '{print $1}' | paste -sd' '; }
# csv_field FILE_OR_TEXT KEYCOL KEY COL — first matching row's COL (csv-aware via awk)
cell() {   # TEXT KEYCOL KEY COL
    awk "$AWK_LIB"'{ n = csv_split($0, f); if (f[kc] == k) { print f[c]; exit } }' kc="$2" k="$3" c="$4" <<<"$1"
}

# =============================================================================
section "1. date arithmetic used by the analyzer (awk, no mktime)"
bad=0
for e in 0 86399 86400 951782400 1709164799 1709164800 1793445277 1798761600 2147483648 4102444799; do
    want=$(date -u -d "@$e" '+%F %T'); got=$(awk "$AWK_LIB"" BEGIN { print fmt_ts($e) }"); back=$(awk "$AWK_LIB"" BEGIN { printf \"%.0f\", epoch(\"$want\") }")
    if [[ $want != "$got" || $back != "$e" ]]; then bad=1; echo "      mismatch at $e: [$want] [$got] [$back]"; fi
done
expect_eq "fmt_ts / epoch agree with GNU date on 10 instants (leap day, 2038, 2100)" "0" "$bad"
expect_eq "invalid dates are rejected (-1)" "-1 -1 -1" "$(awk "$AWK_LIB"' BEGIN { print epoch("2026-13-01"), epoch("garbage"), epoch("2026-02-30 25:00:00") }')"

# =============================================================================
build_dataset
before=$(checksums); names_before=$(ls -A "$DATA_DIR" | paste -sd" ")

section "2. summary: the headline numbers"
activity_prepare "" "" 0
sumcsv=$(activity_summary)
m() { cell "$sumcsv" 1 "$1" 2; }
expect_eq "Total Sessions" "5" "$(m Total_Sessions)"
expect_eq "closed / active / interrupted" "3 1 1" "$(m Sessions_Closed) $(m Sessions_Active) $(m Sessions_Interrupted)"
expect_eq "sessions with an estimated end (crash)" "1" "$(m Sessions_With_Estimated_End)"
expect_eq "Total Usage Duration = 7200+3600+3000 (closed sessions only)" "13800" "$(m Total_Usage_Duration_Seconds)"
expect_eq "...as HH:MM:SS" "03:50:00" "$(m Total_Usage_Duration_HMS)"
expect_eq "Average session duration = 13800/3" "4600.0" "$(m Average_Session_Duration_Seconds)"
expect_eq "Total Processes (12 valid rows)" "12" "$(m Total_Processes)"
expect_eq "completed / session_end / recovered" "10 1 1" "$(m Processes_Completed) $(m Processes_Session_End) $(m Processes_Recovered)"
expect_eq "user-application / background / unclassified" "8 3 1" "$(m Processes_User_Application) $(m Processes_Background) $(m Processes_Unclassified)"
expect_eq "Average Process Duration = 12250/10 (COMPLETED only)" "1225.0" "$(m Average_Process_Duration_Seconds)"
expect_eq "...as HH:MM:SS" "00:20:25" "$(m Average_Process_Duration_HMS)"
expect_eq "longest completed process" "browserx (PID 101)" "$(m Longest_Completed_Process)"
expect_eq "launches (found-running svc excluded)" "6" "$(m User_Application_Launches)"
expect_eq "distinct user applications (Browser X, Editor X, Ghost; unclassified mystery is not one)" "3" "$(m Distinct_User_Applications)"
expect_eq "most used application" "Browser X" "$(m Most_Used_Application)"
expect_eq "its active seconds" "7200" "$(m Most_Used_Application_Seconds)"
expect_eq "average instance duration = (4800+1800+600+1800+600)/5" "1920.0" "$(m Average_Application_Instance_Seconds)"
expect_eq "time with >=1 user app running (apps NOT added together)" "9600" "$(m User_App_Active_Time_Seconds)"
expect_eq "Process_Seconds_Sum (concurrent adds up)" "21245" "$(m Process_Seconds_Sum)"
expect_eq "busiest day" "2026-10-01" "$(m Busiest_Day)"
expect_eq "days with activity" "3" "$(m Days_With_Activity)"

section "3. concurrent processes are NOT usage time"
usage=$(m Total_Usage_Duration_Seconds); psum=$(m Process_Seconds_Sum); uaact=$(m User_App_Active_Time_Seconds)
if (( psum > usage )); then pass "sum of process durations ($psum) is larger than session time ($usage): different measures"; else fail "process-seconds vs usage" "$psum vs $usage"; fi
if (( uaact < psum )); then pass "application active time ($uaact) is NOT the process sum ($psum)"; else fail "active time must not be the process sum"; fi
expect_eq "Browser X: 5 processes, 9600 process-seconds, but only 7200 s of activity" "9600/7200" "$(activity_apps User_Application 10 | awk -F, '$2=="\"Browser X\"" {print $14 "/" $8}')"

section "4. incomplete data is not presented as a normal result"
expect_eq "SESSION_END process is not in the average (avg would differ)" "1225.0" "$(m Average_Process_Duration_Seconds)"
procs=$(activity_processes)
expect_eq "per-process list has all 12 rows" "12" "$(( $(grep -c '' <<<"$procs") - 1 ))"
expect_eq "P5 (SESSION_END): Natural_End = no" "no" "$(cell "$procs" 2 105 11)"
expect_eq "P8 (RECOVERED): Natural_End = no" "no" "$(cell "$procs" 2 108 11)"
expect_eq "P1 (COMPLETED): Natural_End = yes" "yes" "$(cell "$procs" 2 101 11)"
case $(cell "$procs" 2 105 13) in *"lower bound"*"already running"*) pass "P5 note explains: lower bound + found running" ;; *) fail "P5 note" "$(cell "$procs" 2 105 13)" ;; esac
case $(cell "$procs" 2 108 13) in *estimate*) pass "P8 note explains: estimated end" ;; *) fail "P8 note" "$(cell "$procs" 2 108 13)" ;; esac
expect_eq "P5 keeps its real duration (08:00-11:00 = 10800)" "10800" "$(cell "$procs" 2 105 8)"
expect_eq "P12 duration recomputed from its times (field was 'abc')" "100" "$(cell "$procs" 2 112 8)"
expect_eq "P2 duration" "1800" "$(cell "$procs" 2 102 8)"

section "5. applications: ranking, launches, grouping, totals, averages"
apps=$(activity_apps User_Application 10)
expect_eq "header" "Rank,App_Name,Launches,Already_Running,Processes,Completed_Processes,Incomplete_Processes,Active_Seconds,Active_HMS,Pct_Of_Session_Time,Avg_Instance_Seconds,Avg_Instance_HMS,Completed_Instances,Process_Seconds,CPU_Seconds" "$(head -n1 <<<"$apps")"
expect_eq "ranked by active time" "Browser X|Editor X|Ghost" "$(tail -n +2 <<<"$apps" | awk "$AWK_LIB"'{ csv_split($0, f); printf "%s%s", (NR>1 ? "|" : ""), f[2] }')"
expect_eq "Browser X row" '1,"Browser X",3,0,5,4,1,7200,02:00:00,52.17,2700.0,00:45:00,2,9600,0' "$(sed -n 2p <<<"$apps")"
expect_eq "Editor X row" '2,"Editor X",2,0,2,2,0,3600,01:00:00,26.09,1800.0,00:30:00,2,3600,0' "$(sed -n 3p <<<"$apps")"
expect_eq "Ghost row (session has no sessions.csv row)" '3,"Ghost",1,0,1,1,0,600,00:10:00,4.35,600.0,00:10:00,1,600,0' "$(sed -n 4p <<<"$apps")"
expect_eq "helpers (Web Content, gpuhelper) are NOT separate applications" "0" "$(grep -c 'Web Content\|gpuhelper' <<<"$apps")"
expect_eq "unclassified 'mystery' is not guessed into an application" "0" "$(grep -c mystery <<<"$apps")"
bgapps=$(activity_apps Background_Process 10)
expect_eq "background: svc first, found running -> Already_Running=1, Launches=0" '1,"svc",0,1,1,0,1,7195,01:59:55,52.14,,,0,7195,0' "$(sed -n 2p <<<"$bgapps")"
expect_eq "background: worker, calc follow" '"worker","calc"' "$(tail -n +3 <<<"$bgapps" | awk "$AWK_LIB"'{ csv_split($0, f); printf "%s%s", (NR>1 ? "," : ""), "\"" f[2] "\"" }')"
expect_eq "found-running process is measured from when monitoring saw it (09:00:05), not 08:00" "7195" "$(cell "$bgapps" 2 svc 8)"
expect_eq "top N limits the list" "2" "$(( $(activity_apps User_Application 2 | grep -c '') - 1 ))"

section "6. per-session totals"
sess=$(activity_sessions)
expect_eq "header" "Session_ID,Login_UTC,Logout_UTC,Status,Duration_Quality,Duration_Seconds,Duration_Minutes,Duration_HMS,Processes,User_App_Launches,Background_Processes,Completed_Processes,Incomplete_Processes,Distinct_User_Apps" "$(head -n1 <<<"$sess")"
expect_eq "S1: 7 processes (3 launches, 2 background, 6 completed, 1 incomplete, 2 apps)" 'S1,2026-10-01 09:00:00,2026-10-01 11:00:00,COMPLETED,EXACT,7200,120.00,02:00:00,7,3,2,6,1,2' "$(grep '^S1,' <<<"$sess")"
expect_eq "S2 (crosses midnight): 1 process" 'S2,2026-10-01 23:30:00,2026-10-02 00:30:00,COMPLETED,EXACT,3600,60.00,01:00:00,1,1,0,1,0,1' "$(grep '^S2,' <<<"$sess")"
expect_eq "S3 (crash): duration is ESTIMATED; includes the no-details process" 'S3,2026-10-02 08:00:00,2026-10-02 08:50:00,CRASHED,ESTIMATED,3000,50.00,00:50:00,3,1,1,2,1,1' "$(grep '^S3,' <<<"$sess")"
expect_eq "S4 ACTIVE: no duration, zero processes" 'S4,2026-10-03 10:00:00,,ACTIVE,UNKNOWN,,,,0,0,0,0,0,0' "$(grep '^S4,' <<<"$sess")"
expect_eq "S5 INTERRUPTED: no duration" 'S5,2026-10-03 12:00:00,,INTERRUPTED,UNKNOWN,,,,0,0,0,0,0,0' "$(grep '^S5,' <<<"$sess")"
expect_eq "process whose session row is missing is reported, not lost" 'SX,,,MISSING_SESSION,UNKNOWN,,,,1,1,0,1,0,1' "$(grep '^SX,' <<<"$sess")"
expect_eq "sum of per-session process counts equals Total Processes" "12" "$(tail -n +2 <<<"$sess" | awk "$AWK_LIB"'{ csv_split($0, f); s += f[9] } END { print s }')"
expect_eq "sessions are in chronological order" "S1 S2 S3 S4 S5 SX" "$(tail -n +2 <<<"$sess" | cut -d, -f1 | paste -sd' ')"

section "7. daily statistics (UTC)"
daily=$(activity_daily)
expect_eq "header" "Date,Sessions,Session_Seconds,Session_HMS,Processes,User_App_Launches,Background_Processes,Completed_Processes,Incomplete_Processes,Avg_Process_Seconds,App_Active_Seconds,App_Active_HMS,Distinct_User_Apps" "$(head -n1 <<<"$daily")"
expect_eq "2026-10-01 (S2's first 30 min counted here)" '2026-10-01,2,9000,02:30:00,9,5,2,8,1,1512.5,6900,01:55:00,3' "$(grep '^2026-10-01' <<<"$daily")"
expect_eq "2026-10-02 (S2's last 30 min + S3; editor tail + P8)" '2026-10-02,1,4800,01:20:00,3,1,1,2,1,75.0,2700,00:45:00,2' "$(grep '^2026-10-02' <<<"$daily")"
expect_eq "2026-10-03 (two open sessions, no time, no processes)" '2026-10-03,2,0,00:00:00,0,0,0,0,0,,0,00:00:00,0' "$(grep '^2026-10-03' <<<"$daily")"
expect_eq "daily session seconds add up to the total (9000+4800)" "13800" "$(tail -n +2 <<<"$daily" | awk -F, '{s += $3} END {print s}')"
expect_eq "daily active seconds add up to the total (6900+2700)" "9600" "$(tail -n +2 <<<"$daily" | awk -F, '{s += $11} END {print s}')"

section "8. UTC offset moves the day boundaries (+03:00)"
activity_prepare "" "" 10800
daily3=$(activity_daily)
expect_eq "local 10-01: only S1 started, 7200 s; user-app time 6000" '2026-10-01,1,7200,02:00:00' "$(grep '^2026-10-01' <<<"$daily3" | cut -d, -f1-4)"
expect_eq "local 10-02: S2 (02:30 local) and S3; 3600+3000 s" '2026-10-02,2,6600,01:50:00' "$(grep '^2026-10-02' <<<"$daily3" | cut -d, -f1-4)"
expect_eq "local 10-01 user-app active time = 4800+600+600" "6000" "$(cell "$daily3" 1 2026-10-01 11)"
expect_eq "local 10-02 user-app active time = 1800+1800" "3600" "$(cell "$daily3" 1 2026-10-02 11)"
expect_eq "the offset does not change totals" "13800" "$(cell "$(activity_summary)" 1 Total_Usage_Duration_Seconds 2)"

section "9. period filter"
activity_prepare "2026-10-02" "2026-10-02" 0
ps_sum=$(activity_summary)
expect_eq "sessions that STARTED on 10-02" "1" "$(cell "$ps_sum" 1 Total_Sessions 2)"
expect_eq "usage clipped to the day: S2 tail 1800 + S3 3000" "4800" "$(cell "$ps_sum" 1 Total_Usage_Duration_Seconds 2)"
expect_eq "processes started on 10-02" "3" "$(cell "$ps_sum" 1 Total_Processes 2)"
expect_eq "launches on 10-02" "1" "$(cell "$ps_sum" 1 User_Application_Launches 2)"
pa=$(activity_apps User_Application 10)
expect_eq "Browser X clipped to the day: 1 launch, 1800 s" '1,"Browser X",1,0,1,0,1,1800,00:30:00,37.50,,,0,1800,0' "$(sed -n 2p <<<"$pa")"
expect_eq "Editor X: started yesterday -> no launch today, 900 s of tail" '2,"Editor X",0,0,0,0,0,900,00:15:00,18.75,,,0,900,0' "$(sed -n 3p <<<"$pa")"
expect_eq "Ghost (10-01) is outside the period" "0" "$(grep -c Ghost <<<"$pa")"
expect_eq "user-app active time in the period" "2700" "$(cell "$ps_sum" 1 User_App_Active_Time_Seconds 2)"
activity_prepare "" "" 0

section "10. data quality is reported, bad rows never break the numbers"
q=$(activity_quality)
expect_eq "malformed process line counted" "1" "$(cell "$q" 1 process_rows_malformed 2)"
expect_eq "duplicate process row counted once, not twice" "1" "$(cell "$q" 1 process_rows_duplicate 2)"
expect_eq "unreadable Start_Time skipped" "1" "$(cell "$q" 1 process_rows_invalid_start_time 2)"
expect_eq "non-numeric Duration recomputed" "1" "$(cell "$q" 1 process_duration_recomputed_from_times 2)"
expect_eq "row without details flagged" "1" "$(cell "$q" 1 process_rows_without_details 2)"
expect_eq "orphan details row flagged" "1" "$(cell "$q" 1 details_rows_without_process_row 2)"
expect_eq "the duplicate of P4 did not inflate Editor X launches" "2" "$(cell "$apps" 2 "Editor X" 3)"

section "11. the raw data is never modified"
after=$(checksums)
expect_eq "sessions/processes/details checksums unchanged after all analysis" "$before" "$after"
activity_text_report 5 >/dev/null; report_build "" "" 5 0 >/dev/null
expect_eq "...and after building a full report" "$before" "$(checksums)"
expect_eq "no file was created in data/ by the analysis" "$names_before" "$(ls -A "$DATA_DIR" | paste -sd" ")"

section "12. the report"
rd=$(ls -d "$REPORTS_DIR"/report_*/ | head -n1)
expect_eq "8 files in the report folder" "8" "$(ls "$rd" | wc -l)"
for f in 01_summary.csv 02_most_used_applications.csv 03_background_processes.csv 04_daily_usage.csv 05_sessions.csv 06_process_durations.csv 07_data_quality.csv 08_report.txt; do
    expect_ok "report file exists and is not empty: $f" test -s "$rd/$f"
done
for h in "Total Sessions" "Total Processes" "Most Used Applications" "Total Usage Duration" "Average Process Duration" "Daily Usage Statistics"; do
    expect_ok "report.txt contains: $h" grep -q "$h" "$rd/08_report.txt"
done
expect_eq "CSV files start with a UTF-8 BOM (Excel)" "efbbbf" "$(head -c3 "$rd/01_summary.csv" | od -An -tx1 | tr -d ' \n')"
expect_ok "05_sessions.csv has the minutes column" bash -c "head -n1 '$rd/05_sessions.csv' | grep -q 'Duration_Seconds,Duration_Minutes'"
expect_eq "summary CSV: Total_Sessions row" 'Total_Sessions,"5","sessions that STARTED in the period"' "$(grep '^Total_Sessions' "$rd/01_summary.csv")"
text=$(activity_text_report 5)
expect_grep "text report shows Total Sessions = 5" 'Total Sessions +5 ' "$text"
expect_grep "text report shows the average process duration 00:20:25" 'Average Process Duration +00:20:25' "$text"
expect_grep "text report warns that incomplete processes are excluded" 'did not end normally and are NOT in the averages' "$text"
expect_grep "text report explains process-seconds is not usage" 'not a usage measure' "$text"

section "13. CLI"

out=$("$ROOT/main.sh" stats --top 3); rc=$?
expect_eq "main.sh stats exits 0" "0" "$rc"
expect_grep "stats prints the report" 'Most Used Applications' "$out"
expect_ok "stats --utc-offset +03:00 works" "$ROOT/main.sh" stats --utc-offset +03:00
expect_ok "stats --from/--to works" "$ROOT/main.sh" stats --from 2026-10-02 --to 2026-10-02
expect_ok "stats --quality prints the checks" bash -c "'$ROOT/main.sh' stats --quality | grep -q process_rows_duplicate"
for bad in "+15:00" "abc" "3:7"; do
    if "$ROOT/main.sh" stats --utc-offset "$bad" >/dev/null 2>&1; then fail "bad --utc-offset '$bad' rejected"; else pass "bad --utc-offset '$bad' rejected"; fi
done
expect_ok "processes --apps uses the new analyzer" bash -c "'$ROOT/main.sh' processes --apps | grep -q 'Browser X'"
expect_eq "the CLI did not change the data either" "$before" "$(checksums)"

section "14. empty and missing data"
rm -f -- "$SESSIONS_FILE" "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE"
activity_prepare "" "" 0
e=$(activity_summary)
expect_eq "no files: Total_Sessions = 0" '0' "$(cell "$e" 1 Total_Sessions 2 | tr -d '"')"
expect_eq "no files: Total_Processes = 0" '0' "$(cell "$e" 1 Total_Processes 2 | tr -d '"')"
expect_eq "no files: average process duration is empty (n/a), not 0" "" "$(cell "$e" 1 Average_Process_Duration_Seconds 2)"
expect_eq "no files: app table is just a header" "1" "$(activity_apps User_Application 5 | grep -c '')"
activity_text_report 5 >/dev/null 2>&1 && pass "no files: text report runs" || fail "no files: text report runs"
expect_ok "no files: full report builds" report_build "" "" 5 0
mk_files; activity_prepare "" "" 0
expect_eq "headers only: Total_Sessions = 0" '0' "$(cell "$(activity_summary)" 1 Total_Sessions 2 | tr -d '"')"
expect_eq "headers only: daily is just a header" "1" "$(activity_daily | grep -c '')"
# only incomplete processes -> there is nothing to average
mk_files; mk_session S1 "2026-10-01 09:00:00" "2026-10-01 10:00:00" 3600 COMPLETED
mk_proc S1 1 stuck "2026-10-01 09:10:00" "2026-10-01 09:50:00" SESSION_END $UA "Stuck" yes no i1
activity_prepare "" "" 0
o=$(activity_summary)
expect_eq "only an incomplete process: average is empty, not 2400" "" "$(cell "$o" 1 Average_Process_Duration_Seconds 2)"
expect_eq "...but it is still counted as a process" "1" "$(cell "$o" 1 Total_Processes 2 | tr -d '"')"
expect_eq "...and its time is still application time (lower bound)" "2400" "$(cell "$o" 1 User_App_Active_Time_Seconds 2 | tr -d '"')"
expect_eq "text report says n/a" "1" "$(activity_text_report 5 | grep -cE 'Average Process Duration +n/a')"
# a user APPLICATION that was already running when monitoring began is not a launch
mk_files; mk_session S1 "2026-10-01 09:00:00" "2026-10-01 10:00:00" 3600 COMPLETED
mk_proc S1 1 oldapp "2026-10-01 07:00:00" "2026-10-01 09:30:00" COMPLETED $UA "Old App" yes yes i1 "2026-10-01 09:00:03"
mk_proc S1 2 newapp "2026-10-01 09:10:00" "2026-10-01 09:20:00" COMPLETED $UA "New App" yes no  i2
activity_prepare "" "" 0
o=$(activity_summary); fr=$(activity_apps User_Application 5)
expect_eq "found-running application is NOT a launch (1 of 2)" "1" "$(cell "$o" 1 User_Application_Launches 2)"
expect_eq "...it is reported as already running" "1" "$(cell "$o" 1 Applications_Already_Running 2)"
expect_eq "Old App row: 0 launches, 1 already running; measured from 09:00:03 (1797 s), not from 07:00" '2,"Old App",0,1,1,1,0,1797,00:29:57,49.92,,,0,1797,0' "$(grep Old <<<"$fr" | sed 's/^[0-9]*/2/')"
expect_eq "New App row: launch, 600 s, average instance 600.0" '"New App",1,0,1,1,0,600,00:10:00,16.67,600.0,00:10:00,1,600,0' "$(grep New <<<"$fr" | cut -d, -f2-)"
expect_eq "its full lifetime still counts for Average Process Duration ((9000+600)/2)" "4800.0" "$(cell "$o" 1 Average_Process_Duration_Seconds 2)"

# names with commas / quotes / formula characters
mk_files; mk_session S1 "2026-10-01 09:00:00" "2026-10-01 10:00:00" 3600 COMPLETED
mk_proc S1 1 'x' "2026-10-01 09:10:00" "2026-10-01 09:20:00" COMPLETED $UA 'Evil, "App"' yes no i1
mk_proc S1 2 'y' "2026-10-01 09:30:00" "2026-10-01 09:40:00" COMPLETED $UA '=HYPERLINK("x")' yes no i2
activity_prepare "" "" 0
ap=$(activity_apps User_Application 5)
expect_eq "app name with comma and quotes is escaped CSV-style" "1" "$(grep -c '"Evil, ""App"""' <<<"$ap")"
expect_eq "both applications present and the CSV still has 15 columns" "2 15" "$(( $(grep -c '' <<<"$ap") - 1 )) $(tail -n +2 <<<"$ap" | awk "$AWK_LIB"'{ print csv_split($0, f) }' | sort -u)"
expect_eq "formula-looking app name is neutralised" "1" "$(grep -c "\"'=HYPERLINK" <<<"$ap")"

# =============================================================================
section "15. end to end with the real daemon: concurrent apps are not summed"
rm -rf -- "$DATA_DIR" "$STATE_DIR"; mkdir -p "$DATA_DIR" "$STATE_DIR"
cp /bin/sleep "$SANDBOX/bin/appx"; cp /bin/sleep "$SANDBOX/bin/appy"
"$ROOT/main.sh" consent --accept >/dev/null; "$ROOT/main.sh" start >/dev/null; sleep 2
"$SANDBOX/bin/appx" 8 & PX=$!; "$SANDBOX/bin/appy" 8 & PY=$!
sleep 11; wait "$PX" "$PY" 2>/dev/null
"$ROOT/main.sh" stop >/dev/null
rep=$("$ROOT/main.sh" stats --top 5)
expect_grep "e2e: one session recorded" 'Total Sessions +1 ' "$rep"
expect_grep "e2e: App X ranked" 'App X' "$rep"
expect_grep "e2e: App Y ranked" 'App Y' "$rep"
activity_prepare "" "" 0
e2e=$(activity_summary)
ps2=$(cell "$e2e" 1 Process_Seconds_Sum 2 | tr -d '"'); ua2=$(cell "$e2e" 1 User_App_Active_Time_Seconds 2 | tr -d '"')
expect_between "e2e: two simultaneous 8 s apps -> about 8-11 s of application time" 8 11 "$ua2"
if awk -v p="$ps2" -v u="$ua2" 'BEGIN { exit !(p >= u + 6) }'; then pass "e2e: process-seconds ($ps2) clearly exceeds application time ($ua2) — not summed"; else fail "e2e: process-seconds must exceed app time" "ps=$ps2 ua=$ua2"; fi
expect_between "e2e: each app ran ~8 s" 7 11 "$(activity_apps User_Application 5 | awk -F, '$2=="\"App X\"" {print $8}')"
expect_eq "e2e: both are launches (not 'found running')" "2" "$(cell "$e2e" 1 User_Application_Launches 2 | tr -d '"')"
expect_ok "e2e: processes --check and sessions --check pass" bash -c "'$ROOT/main.sh' processes --check >/dev/null && '$ROOT/main.sh' sessions --check >/dev/null"

printf '\n%d checks, %d failed\n' "$TOTAL" "$FAILS"
if (( FAILS == 0 )); then echo "ALL ACTIVITY TESTS PASSED"; fi
exit "$FAILS"
