#!/usr/bin/env bash
# =============================================================================
# tests/test_reports.sh — Report Generator tests
# -----------------------------------------------------------------------------
# Uses the hand-built dataset of tests/fixtures.sh (timeline in tests/test_activity.sh),
# so every expected number is worked out by hand, not copied from program output.
# Time is pinned (CAL_NOW_EPOCH) so "Report_Created_UTC" and FINAL/PARTIAL are exact.
#
# Checks: the three reports' content, daily sets, chronological order, quotes and commas
# in names, Excel rules (BOM, CRLF, columns, formula safety, row limit) including opening
# the files in a real spreadsheet program (LibreOffice, when installed), history protection
# (frozen finals, revisions, no needless replacement), safe writing (atomic replace, crash
# in the middle of publishing, concurrent generators, readers never see half a file).
# Everything runs in a temp dir; the real data/ and reports/ are never touched.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/bin"
export DATA_DIR="$SANDBOX/data" STATE_DIR="$SANDBOX/state" REPORTS_DIR="$SANDBOX/reports"
export CONSENT_FILE="$SANDBOX/consent" INTERVAL_SEC=1 MIN_DURATION_SEC=0 CAL_ROOT="$ROOT"
export APPS_MAP_FILE="$SANDBOX/apps.map" IGNORE_FILE="$SANDBOX/ignore.list" DESKTOP_DIRS="$SANDBOX/none"
: >"$IGNORE_FILE"; printf '%s\n' 'appx|App X|editor' >"$APPS_MAP_FILE"      # BEFORE sourcing config.sh
FAILS=0 TOTAL=0

cleanup() {
    if (( FAILS > 0 )); then echo "(sandbox kept for inspection: $SANDBOX)"; return 0; fi
    "$ROOT/main.sh" stop >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]  actual: [$3]"; fi; }
expect_ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi; }
expect_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d" "command unexpectedly succeeded: $*"; else pass "$d"; fi; }
expect_grep() { if grep -Eq -- "$2" <<<"$3"; then pass "$1"; else fail "$1" "pattern [$2] not found in: ${3:0:200}"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

for _f in "$APPS_MAP_FILE" "$IGNORE_FILE" "$DATA_DIR" "$STATE_DIR" "$REPORTS_DIR"; do
    case $_f in "$SANDBOX"/*) ;; *) echo "ABORT: $_f is outside the sandbox"; exit 2 ;; esac
done
# shellcheck source=/dev/null
source "$ROOT/config.sh"
for m in common consent storage sessionlog collector detector session recovery daemon analyzer activity report; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$m.sh"
done
# shellcheck source=tests/fixtures.sh
source "$ROOT/tests/fixtures.sh"
storage_init
UA=User_Application; BG=Background_Process
MAIN="$ROOT/main.sh"

# --- helpers ------------------------------------------------------------------------------
NOW_T=$(ep "2026-11-05 12:00:00"); export CAL_NOW_EPOCH=$NOW_T        # pinned clock: "after all the data"
CREATED="2026-11-05 12:00:00"
strip()  { sed 's/^\xEF\xBB\xBF//; s/\r$//' "$1"; }                  # report file -> plain LF text
body()   { strip "$1" | sed 's/^[^,]*,//'; }                         # ...without the Report_Created_UTC column
rcell()  { strip "$1" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[kc] == k) { print f[c]; exit } }' kc="$2" k="$3" c="$4"; }   # FILE KEYCOL KEY COL
nrows()  { echo $(( $(grep -c '' "$1") - 1 )); }
ncols()  { strip "$1" | awk "$AWK_LIB"'NR == 1 { print csv_split($0, f); exit }'; }
day()    { echo "$REPORTS_DIR/daily/UTC/$1"; }
logn()   { if [[ -f $REPORTS_DIR/report_log.csv ]]; then grep -c '' "$REPORTS_DIR/report_log.csv"; else echo 0; fi; }
sums()   { ( cd "$1" && sha256sum -- *.csv | awk '{print $1}' | paste -sd' ' ); }
leftovers() { find "$REPORTS_DIR" \( -name '.staging.*' -o -name '*.tmp*' -o -name '*.lf' -o -name '*.stamped' \) 2>/dev/null | wc -l; }

# =============================================================================
section "1. daily reports are generated, one set per day"
build_dataset
raw_before=$(checksums)
out=$(report_run_daily "" "" 0 5 normal 0); rc=$?
expect_eq "report_run_daily succeeds" "0" "$rc"
expect_grep "2026-10-01 generated as FINAL" 'GENERATED daily/UTC/2026-10-01 \(FINAL' "$out"
expect_grep "2026-10-02 generated as FINAL" 'GENERATED daily/UTC/2026-10-02 \(FINAL' "$out"
expect_grep "2026-10-03 is PARTIAL (a session is still ACTIVE)" 'GENERATED daily/UTC/2026-10-03 \(PARTIAL' "$out"
expect_eq "exactly three days (the days that have activity)" "3" "$(ls "$REPORTS_DIR/daily/UTC" | wc -l)"
for d in 2026-10-01 2026-10-02 2026-10-03; do
    expect_eq "$d: 3 reports + manifest" "application_activity_report.csv report_manifest.csv session_report.csv usage_summary_report.csv" "$(ls "$(day $d)" | paste -sd' ')"
done
expect_eq "no staging / temp files left behind" "0" "$(leftovers)"
expect_eq "report files are private (600)" "" "$(find "$REPORTS_DIR" -type f ! -perm 600 ! -name '.report.lock' | head -3)"
expect_eq "report directories are private (700)" "" "$(find "$REPORTS_DIR" -type d ! -perm 700 | head -3)"
expect_ok "all sets verify" report_verify_all

section "2. creation date and clear column names"
for f in session_report application_activity_report usage_summary_report; do
    expect_eq "$f: every row carries the creation date" "$CREATED" "$(strip "$(day 2026-10-01)/$f.csv" | tail -n +2 | cut -d, -f1 | sort -u)"
done
expect_eq "session report columns" "$RG_HDR_SESSION" "$(strip "$(day 2026-10-01)/session_report.csv" | head -n1)"
expect_eq "application activity columns" "$RG_HDR_ACTIVITY" "$(strip "$(day 2026-10-01)/application_activity_report.csv" | head -n1)"
expect_eq "usage summary columns" "$RG_HDR_SUMMARY" "$(strip "$(day 2026-10-01)/usage_summary_report.csv" | head -n1)"
expect_eq "manifest records the same creation date" "$CREATED" "$(strip "$(day 2026-10-01)/report_manifest.csv" | tail -n +2 | cut -d, -f5 | sort -u)"
expect_eq "manifest status of a finished day" "FINAL" "$(strip "$(day 2026-10-01)/report_manifest.csv" | tail -n +2 | cut -d, -f6 | sort -u)"
expect_eq "manifest status of the open day" "PARTIAL" "$(strip "$(day 2026-10-03)/report_manifest.csv" | tail -n +2 | cut -d, -f6 | sort -u)"

section "3. Session Report content (hand-worked)"
SR1="$(day 2026-10-01)/session_report.csv"; SR2="$(day 2026-10-02)/session_report.csv"; SR3="$(day 2026-10-03)/session_report.csv"
expect_eq "10-01 has S1 and S2, oldest first" "S1 S2" "$(body "$SR1" | tail -n +2 | cut -d, -f1 | paste -sd' ')"
expect_eq "S1: login/logout/duration/minutes/HMS and its process totals" 'S1,"tester",1000,2026-10-01 09:00:00,2026-10-01 11:00:00,COMPLETED,EXACT,7200,120.00,02:00:00,7200,yes,7,3,2,6,1,2' "$(body "$SR1" | grep '^S1,')"
expect_eq "S2 on its first day: only the first 30 minutes belong to 10-01" 'S2,"tester",1000,2026-10-01 23:30:00,2026-10-02 00:30:00,COMPLETED,EXACT,3600,60.00,01:00:00,1800,yes,1,1,0,1,0,1' "$(body "$SR1" | grep '^S2,')"
expect_eq "S2 on its second day: it began yesterday (Started_In_Period=no), 30 minutes" 'S2,"tester",1000,2026-10-01 23:30:00,2026-10-02 00:30:00,COMPLETED,EXACT,3600,60.00,01:00:00,1800,no,1,1,0,1,0,1' "$(body "$SR2" | grep '^S2,')"
expect_eq "S3: crash -> ESTIMATED end" 'S3,"tester",1000,2026-10-02 08:00:00,2026-10-02 08:50:00,CRASHED,ESTIMATED,3000,50.00,00:50:00,3000,yes,3,1,1,2,1,1' "$(body "$SR2" | grep '^S3,')"
expect_eq "10-01 usage = sum of Seconds_In_Period (7200 + 1800)" "9000" "$(body "$SR1" | tail -n +2 | awk -F, '{s += $11} END {print s}')"
expect_eq "10-02 usage = 1800 + 3000" "4800" "$(body "$SR2" | tail -n +2 | awk -F, '{s += $11} END {print s}')"
expect_eq "open sessions have no invented duration" "S4,\"tester\",1000,2026-10-03 10:00:00,,ACTIVE,UNKNOWN,,,,,yes,0,0,0,0,0,0|S5,\"tester\",1000,2026-10-03 12:00:00,,INTERRUPTED,UNKNOWN,,,,,yes,0,0,0,0,0,0" "$(body "$SR3" | tail -n +2 | paste -sd'|')"
expect_eq "a process whose session row is missing is not shown as a session" "0" "$(grep -c ',SX,\|^SX,\|,SX$' "$SR1" || true)"
expect_eq "sessions sum over all days = every closed session (13800)" "13800" "$(cat "$SR1" "$SR2" "$SR3" | strip /dev/stdin | grep -v '^Report_Created' | awk -F, '{s += $12} END {print s}')"

section "4. Application Activity Report content (hand-worked)"
AR1="$(day 2026-10-01)/application_activity_report.csv"; AR2="$(day 2026-10-02)/application_activity_report.csv"
expect_eq "10-01: nine processes, chronological (by start, then PID)" "105 101 102 104 103 112 106 110 107" "$(body "$AR1" | tail -n +2 | cut -d, -f2 | paste -sd' ')"
expect_eq "10-02: P7 carried over from yesterday, then P8 P9 P11" "107 108 109 111" "$(strip "$AR2" | tail -n +2 | awk "$AWK_LIB"'{ csv_split($0, f); print f[3] }' | paste -sd' ')"
r() { body "$AR1" | grep "^S1,$1,"; }
expect_eq "P1: application, class, root, start, end, duration, status" 'S1,101,"browserx","Browser X",User_Application,yes,2026-10-01 09:10:00,2026-10-01 10:10:00,3600,01:00:00,3600,yes,COMPLETED,yes,no,0,""' "$(r 101)"
expect_eq "P2: a helper process belongs to the application but is not a root" 'S1,102,"Web Content","Browser X",User_Application,no,2026-10-01 09:12:00,2026-10-01 09:42:00,1800,00:30:00,1800,yes,COMPLETED,yes,no,0,""' "$(r 102)"
case $(r 105) in
    *'"svc","svc",Background_Process,yes,2026-10-01 08:00:00,2026-10-01 11:00:00,10800,03:00:00,7195,yes,SESSION_END,no,yes,0,"still running when monitoring stopped'*) pass "P5: found running -> true start, monitored share 7195 s, not a natural end" ;;
    *) fail "P5 row" "$(r 105)" ;;
esac
expect_eq "P12: duration recomputed from its times (field was 'abc')" '100' "$(rcell "$AR1" 3 112 10)"
expect_eq "P7 (crosses midnight): 900 s on 10-01 ..." "900" "$(rcell "$AR1" 3 107 12)"
expect_eq "... and 900 s on 10-02, not a new start" "900 no" "$(rcell "$AR2" 3 107 12) $(rcell "$AR2" 3 107 13)"
expect_eq "P7's two daily shares add up to its duration (1800)" "1800" "$(( $(rcell "$AR1" 3 107 12) + $(rcell "$AR2" 3 107 12) ))"
expect_eq "P8 (RECOVERED) is flagged: not a natural end" "RECOVERED no" "$(rcell "$AR2" 3 108 14) $(rcell "$AR2" 3 108 15)"
expect_eq "P11 (no details row) is Unknown, not guessed into an app" "Unknown" "$(rcell "$AR2" 3 111 6)"

section "5. Usage Summary Report content (hand-worked)"
US1="$(day 2026-10-01)/usage_summary_report.csv"; US2="$(day 2026-10-02)/usage_summary_report.csv"
ov() { rcell "$1" 8 "$2" 9; }
expect_eq "Total_Sessions on 10-01 (S1, S2)" "2" "$(ov "$US1" Total_Sessions)"
expect_eq "Total_Usage_Duration on 10-01" "9000" "$(ov "$US1" Total_Usage_Duration)"
expect_eq "Total_Processes on 10-01 (those that started that day)" "9" "$(ov "$US1" Total_Processes)"
expect_eq "completed / session-end / recovered" "8 1 0" "$(ov "$US1" Processes_Completed) $(ov "$US1" Processes_Session_End) $(ov "$US1" Processes_Recovered)"
expect_eq "Average_Process_Duration = 12100/8 (COMPLETED only)" "1512.5" "$(ov "$US1" Average_Process_Duration)"
expect_eq "User_Application_Launches (found-running svc excluded)" "5" "$(ov "$US1" User_Application_Launches)"
expect_eq "User_Application_Active_Time (apps not added together)" "6900" "$(ov "$US1" User_Application_Active_Time)"
expect_eq "Most_Used_Application" "Browser X" "$(ov "$US1" Most_Used_Application)"
expect_eq "Busiest_Day" "2026-10-01" "$(ov "$US1" Busiest_Day)"
expect_eq "Report_Status column" "FINAL" "$(strip "$US1" | tail -n +2 | cut -d, -f5 | sort -u)"
expect_eq "Period columns hold the day" "2026-10-01,2026-10-01,UTC+00:00" "$(strip "$US1" | sed -n 2p | cut -d, -f2-4)"
expect_eq "Most_Used_Applications section, ranked by activity" "1:Browser X:5400|2:Editor X:2700|3:Ghost:600" "$(strip "$US1" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[6] == "Most_Used_Applications") printf "%s%s:%s:%s", (n++ ? "|" : ""), f[7], f[8], f[9] }')"
expect_eq "...with launches, processes and share of session time" "Browser X,2,4,60.00" "$(strip "$US1" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[6] == "Most_Used_Applications" && f[7] == 1) print f[8] "," f[11] "," f[12] "," f[13] }')"
expect_eq "Daily_Session_Time row" "9000 launches=5 processes=9" "$(strip "$US1" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[6] == "Daily_Session_Time") print f[9] " launches=" f[11] " processes=" f[12] }')"
expect_eq "Daily_Application_Active_Time row" "6900" "$(strip "$US1" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[6] == "Daily_Application_Active_Time") print f[9] }')"
expect_eq "10-02 summary: usage 4800, active 2700, launches 1" "4800 2700 1" "$(ov "$US2" Total_Usage_Duration) $(ov "$US2" User_Application_Active_Time) $(ov "$US2" User_Application_Launches)"
expect_eq "data-quality findings are listed" "6" "$(strip "$US1" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[6] == "Data_Quality") n++ } END {print n}')"
expect_eq "every summary row has the same number of columns" "14" "$(strip "$US1" | awk "$AWK_LIB"'{ print csv_split($0, f) }' | sort -u)"

section "6. period reports"
out=$(report_run_period 2026-10-01 2026-10-03 0 5 normal "")
expect_grep "period set is stored under reports/period/UTC/<from>_to_<to>" 'GENERATED period/UTC/2026-10-01_to_2026-10-03 \(PARTIAL' "$out"
PD="$REPORTS_DIR/period/UTC/2026-10-01_to_2026-10-03"
expect_eq "period: 5 sessions (S1-S5), oldest first" "S1 S2 S3 S4 S5" "$(body "$PD/session_report.csv" | tail -n +2 | cut -d, -f1 | paste -sd' ')"
expect_eq "period: 12 processes" "12" "$(nrows "$PD/application_activity_report.csv")"
expect_eq "period: total usage 13800, 12 processes, average 1225.0" "13800 12 1225.0" "$(ov "$PD/usage_summary_report.csv" Total_Usage_Duration) $(ov "$PD/usage_summary_report.csv" Total_Processes) $(ov "$PD/usage_summary_report.csv" Average_Process_Duration)"
expect_eq "period: one Daily_Session_Time row per day (9000, 4800, 0)" "9000 4800 0" "$(strip "$PD/usage_summary_report.csv" | awk "$AWK_LIB"'{ csv_split($0, f); if (f[6] == "Daily_Session_Time") printf "%s%s", (n++ ? " " : ""), f[9] }')"
out=$(report_run_period "" "" 0 5 normal "everything")
expect_grep "a named period" 'GENERATED period/UTC/everything' "$out"
expect_ok "period sets verify" report_verify_dir "$PD"

section "7. names with commas, quotes, formulas and non-ASCII text are safe"
mk_files; mk_session H1 "2026-11-01 09:00:00" "2026-11-01 10:00:00" 3600 COMPLETED
mk_proc H1 1 'Evil, "App"'          "2026-11-01 09:01:00" "2026-11-01 09:02:00" COMPLETED $UA 'Evil, "App"' yes no i1
mk_proc H1 2 '=HYPERLINK("http://x")' "2026-11-01 09:02:00" "2026-11-01 09:03:00" COMPLETED $UA '=HYPERLINK("http://x")' yes no i2
mk_proc H1 3 '@SUM(1)'              "2026-11-01 09:03:00" "2026-11-01 09:04:00" COMPLETED $UA '@SUM(1)' yes no i3
mk_proc H1 4 '-bash'                "2026-11-01 09:04:00" "2026-11-01 09:05:00" COMPLETED $BG '-bash' yes no i4
mk_proc H1 5 '+cmd'                 "2026-11-01 09:05:00" "2026-11-01 09:06:00" COMPLETED $BG '+cmd' yes no i5
mk_proc H1 6 "'=already guarded"    "2026-11-01 09:06:00" "2026-11-01 09:07:00" COMPLETED $BG "'=already guarded" yes no i6
mk_proc H1 7 'ملف مهم ünï çödé'      "2026-11-01 09:07:00" "2026-11-01 09:08:00" COMPLETED $UA 'ملف مهم ünï çödé' yes no i7
mk_proc H1 8 '  spaced  '            "2026-11-01 09:08:00" "2026-11-01 09:09:00" COMPLETED $BG '  spaced  ' yes no i8
report_run_period 2026-11-01 2026-11-01 0 10 normal "hostile" >/dev/null
HD="$REPORTS_DIR/period/UTC/hostile"; HA="$HD/application_activity_report.csv"
expect_ok "the set passes every Excel / structure check" report_verify_dir "$HD"
nm() { rcell "$HA" 3 "$1" 4; }
expect_eq "comma + quotes survive intact" 'Evil, "App"' "$(nm 1)"
expect_eq "= is neutralised with a leading apostrophe" "'=HYPERLINK(\"http://x\")" "$(nm 2)"
expect_eq "@ is neutralised" "'@SUM(1)" "$(nm 3)"
expect_eq "- (e.g. a login shell) is neutralised" "'-bash" "$(nm 4)"
expect_eq "+ is neutralised" "'+cmd" "$(nm 5)"
expect_eq "an already-guarded name is not guarded twice" "'=already guarded" "$(nm 6)"
expect_eq "Arabic and accented text is byte-exact UTF-8" 'ملف مهم ünï çödé' "$(nm 7)"
expect_eq "leading / trailing spaces are kept (quoted)" '  spaced  ' "$(nm 8)"
expect_eq "the raw CSV quotes the comma/quote name correctly" 1 "$(grep -c '"Evil, ""App"""' "$HA")"
expect_eq "the file really is valid UTF-8" "0" "$(iconv -f UTF-8 -t UTF-8 "$HA" >/dev/null 2>&1; echo $?)"
expect_eq "no cell in any report starts with an unprotected = + @ -" "0" "$(strip "$HA" | awk "$AWK_LIB"'{ csv_split($0, f); for (i = 1; i <= NF; i++) if (f[i] ~ /^[=+@]/ || f[i] ~ /^-[^0-9]/) bad++ } END {print bad+0}')"

section "8. Excel compatibility: the files open in a real spreadsheet program"
f1="$(day 2026-10-01)/session_report.csv"
expect_eq "starts with the UTF-8 BOM" "efbbbf" "$(head -c3 "$f1" | od -An -tx1 | tr -d ' \n')"
expect_eq "every line ends with CRLF" "$(grep -c '' "$f1")" "$(grep -c $'\r$' "$f1")"
expect_eq "no bare LF / stray CR anywhere in the first line group" "0" "$(strip "$f1" | grep -c $'\r' || true)"
expect_eq "same number of columns on every row" "1" "$(strip "$f1" | awk "$AWK_LIB"'{ print csv_split($0, f) }' | sort -u | wc -l)"
if [[ -z ${SKIP_OFFICE:-} ]] && command -v soffice >/dev/null 2>&1; then
    LO="$SANDBOX/lo"; mkdir -p "$LO/profile" "$LO/in" "$LO/out"
    cp "$f1" "$LO/in/session.csv"; cp "$HA" "$LO/in/hostile.csv"; cp "$(day 2026-10-01)/usage_summary_report.csv" "$LO/in/summary.csv"
    timeout 150 soffice --headless -env:UserInstallation="file://$LO/profile" --convert-to xlsx --outdir "$LO/out" "$LO/in/session.csv" "$LO/in/hostile.csv" "$LO/in/summary.csv" >/dev/null 2>&1
    xl() { unzip -p "$LO/out/$1.xlsx" "$2" 2>/dev/null; }
    expect_eq "LibreOffice opened session.csv: 19 columns x 3 rows (header + S1 + S2)" 'A1:S3' "$(xl session xl/worksheets/sheet1.xml | grep -o '<dimension ref="[^"]*"' | sed 's/.*ref="//;s/"//')"
    expect_eq "...numbers arrive as numbers (User_ID, Duration_Seconds)" "1000 7200" "$(xl session xl/worksheets/sheet1.xml | grep -o '<c r="[DI]2"[^>]*><v>[^<]*</v>' | sed 's/.*<v>//;s/<.*//' | paste -sd' ')"
    expect_eq "...no cell became a formula" "0" "$(xl hostile xl/worksheets/sheet1.xml | grep -c '<f' || true)"
    expect_eq "hostile names: 18 columns x 9 rows" 'A1:R9' "$(xl hostile xl/worksheets/sheet1.xml | grep -o '<dimension ref="[^"]*"' | sed 's/.*ref="//;s/"//')"
    shared=$(xl hostile xl/sharedStrings.xml | sed 's/<[^>]*>//g')     # text only: LibreOffice splits mixed Arabic/Latin text into several runs
    expect_eq "...Arabic text arrived intact" "1" "$(grep -c 'ملف مهم ünï çödé' <<<"$shared")"
    expect_grep "...the comma + quote name arrived as one cell" 'Evil, (&quot;|")App(&quot;|")' "$shared"
    expect_grep "...the formula-looking name arrived as TEXT with its apostrophe guard" "(&apos;|')=HYPERLINK" "$shared"
    expect_eq "summary opens with 14 columns" "A1:N" "$(xl summary xl/worksheets/sheet1.xml | grep -o '<dimension ref="[^"]*"' | sed 's/.*ref="//;s/"//;s/[0-9]*$//')"
else
    echo "  SKIP  no spreadsheet program available (or SKIP_OFFICE set): the real-spreadsheet checks were skipped"
fi

section "9. history is not replaced without a reason"
build_dataset; rm -rf -- "$REPORTS_DIR/daily"; report_run_daily "" "" 0 5 normal 0 >/dev/null
D1=$(day 2026-10-01); D3=$(day 2026-10-03)
inode1=$(stat -c %i "$D1/session_report.csv"); sum1=$(sums "$D1"); sum3=$(sums "$D3"); log0=$(logn)
export CAL_NOW_EPOCH=$(( NOW_T + 86400 * 3 ))          # three days later
out=$(report_run_daily "" "" 0 5 normal 0)
expect_grep "FINAL days are skipped on a normal run" 'SKIPPED +daily/UTC/2026-10-01' "$out"
expect_grep "the open day is recomputed but UNCHANGED" 'UNCHANGED daily/UTC/2026-10-03' "$out"
expect_eq "FINAL files: same bytes" "$sum1" "$(sums "$D1")"
expect_eq "FINAL files: same inode (not even rewritten)" "$inode1" "$(stat -c %i "$D1/session_report.csv")"
expect_eq "the open day's files were not touched either" "$sum3" "$(sums "$D3")"
expect_eq "creation date kept (3 days later it still says when it was made)" "$CREATED" "$(strip "$D1/session_report.csv" | sed -n 2p | cut -d, -f1)"
expect_eq "the audit log gained nothing" "$log0" "$(logn)"
# the data of a frozen day changes afterwards (a late row): a normal run still leaves it alone ...
mk_proc S1 120 latecomer "2026-10-01 10:20:00" "2026-10-01 10:21:00" COMPLETED $BG "latecomer" yes no i20
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 normal 0)
expect_grep "a normal run does not touch a frozen day even if the data changed" 'SKIPPED +daily/UTC/2026-10-01' "$out"
expect_eq "...files unchanged" "$sum1" "$(sums "$D1")"
# ... --refresh recomputes it and replaces it only because the content really changed
old_activity_sha=$(sha256sum "$D1/application_activity_report.csv" | cut -d' ' -f1)
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 refresh 0)
expect_grep "--refresh replaces it (content changed) and says where the old one went" 'REPLACED daily/UTC/2026-10-01 \(FINAL.*previous version kept in revisions/20261105T120000Z' "$out"
rev="$D1/revisions/20261105T120000Z"
expect_eq "the OLD files are preserved byte-for-byte in revisions/" "$old_activity_sha" "$(sha256sum "$rev/application_activity_report.csv" | cut -d' ' -f1)"
expect_eq "the OLD manifest is preserved too" "1" "$(test -f "$rev/report_manifest.csv" && echo 1 || echo 0)"
expect_eq "the live report now has the late row" "1" "$(grep -c 'latecomer' "$D1/application_activity_report.csv")"
expect_eq "...and the new creation date" "2026-11-08 12:00:00" "$(strip "$D1/session_report.csv" | sed -n 2p | cut -d, -f1)"
expect_ok "...and the old revision is itself a valid set" report_verify_dir "$rev"
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 refresh 0)
expect_grep "--refresh with nothing new changes nothing" 'SKIPPED|UNCHANGED' "$out"
export CAL_NOW_EPOCH=$(( NOW_T + 86400 * 4 ))
out=$(report_run_daily 2026-10-02 2026-10-02 0 5 refresh 0)
expect_grep "--refresh on an unchanged final day: UNCHANGED, creation date untouched" 'UNCHANGED daily/UTC/2026-10-02' "$out"
expect_eq "...really untouched" "$CREATED" "$(strip "$(day 2026-10-02)/session_report.csv" | sed -n 2p | cut -d, -f1)"
out=$(report_run_daily 2026-10-02 2026-10-02 0 5 force 0)
expect_grep "--force always rewrites (and keeps the old one)" 'REPLACED daily/UTC/2026-10-02 \(FINAL.*revisions/' "$out"
# the open day: changes are published without archiving (it was never final)
mk_session S6 "2026-10-03 14:00:00" "" "" ACTIVE
out=$(report_run_daily 2026-10-03 2026-10-03 0 5 normal 0)
expect_grep "a PARTIAL day is regenerated when its data changes" 'REPLACED daily/UTC/2026-10-03 \(PARTIAL' "$out"
expect_eq "...with no revisions folder (it was never final)" "0" "$(test -d "$D3/revisions" && echo 1 || echo 0)"
expect_eq "...and the new session is in it" "1" "$(grep -c '^[^,]*,S6,' "$D3/session_report.csv")"
expect_eq "the audit log recorded the replacements" "1" "$(grep -c 'REPLACED,daily,2026-10-01.*revisions/' "$REPORTS_DIR/report_log.csv")"
export CAL_NOW_EPOCH=$NOW_T

section "10. PARTIAL becomes FINAL when the day closes"
build_dataset; rm -rf -- "$REPORTS_DIR/daily"
export CAL_NOW_EPOCH=$(ep "2026-10-01 18:00:00")           # the evening of 10-01
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 normal 1)
expect_grep "while the day is still running its report is PARTIAL" 'GENERATED daily/UTC/2026-10-01 \(PARTIAL' "$out"
export CAL_NOW_EPOCH=$(ep "2026-10-02 00:00:05")           # just after midnight
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 normal 1)
expect_grep "after midnight it becomes FINAL" 'REPLACED daily/UTC/2026-10-01 \(FINAL' "$out"
expect_eq "...with no revisions (the PARTIAL version was not history)" "0" "$(test -d "$(day 2026-10-01)/revisions" && echo 1 || echo 0)"
# a tracked process that started before the end of the day, still in active.tsv, keeps the day PARTIAL
rm -rf -- "$REPORTS_DIR/daily"
printf '4242\t1\t1\t%s\t%s\t?\ttester\t0\tno\tS1\tUser_Application\tother\tg\tyes\tx\tx\tx\n' "$(ep "2026-10-01 20:00:00")" "$(ep "2026-10-01 20:00:00")" >"$ACTIVE_FILE"
export CAL_NOW_EPOCH=$NOW_T
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 normal 1)
expect_grep "a process still being tracked keeps an over day PARTIAL (its row is yet to come)" 'GENERATED daily/UTC/2026-10-01 \(PARTIAL' "$out"
rm -f -- "$ACTIVE_FILE"
rm -rf -- "$REPORTS_DIR/daily"; report_run_daily "" "" 0 5 normal 0 >/dev/null

section "11. safe writing: crash in the middle of publishing"
mk_session S7 "2026-10-04 09:00:00" "2026-10-04 10:00:00" 3600 COMPLETED
( CAL_TEST_ABORT_AFTER_FILES=1 report_run_daily 2026-10-04 2026-10-04 0 5 normal 1 ) >/dev/null 2>&1; rc=$?
expect_eq "the simulated crash really happened (exit 99)" "99" "$rc"
D4=$(day 2026-10-04)
expect_eq "after the crash: no manifest -> the set is visibly incomplete" "no" "$([[ -f $D4/report_manifest.csv ]] && echo yes || echo no)"
expect_eq "...a staging directory was left" "1" "$(find "$REPORTS_DIR" -name '.staging.*' | wc -l)"
vout=$(report_verify_dir "$D4"); vrc=$?
expect_eq "verify reports the interrupted set" "1" "$vrc"
expect_grep "...and says why" 'no report_manifest.csv' "$vout"
out=$(report_run_daily 2026-10-04 2026-10-04 0 5 normal 1)
expect_grep "the next run repairs it" 'GENERATED daily/UTC/2026-10-04' "$out"
expect_ok "...the repaired set verifies" report_verify_dir "$D4"
expect_eq "...and the stale staging directory was cleaned" "0" "$(leftovers)"
expect_eq "the log has exactly one GENERATED for the repaired day" "1" "$(grep -c 'GENERATED,daily,2026-10-04' "$REPORTS_DIR/report_log.csv")"
# crash while REPLACING an existing set: new file 1 in place, old file 2, 3 and old manifest
mk_session S8 "2026-10-04 11:00:00" "2026-10-04 12:00:00" 3600 COMPLETED
export CAL_NOW_EPOCH=$(( NOW_T + 60 ))
( CAL_TEST_ABORT_AFTER_FILES=1 report_run_daily 2026-10-04 2026-10-04 0 5 refresh 1 ) >/dev/null 2>&1
vout=$(report_verify_dir "$D4"); vrc=$?
expect_eq "a half-replaced set is detected" "1" "$vrc"
expect_grep "...by its SHA-256 not matching the manifest" 'does not match its SHA-256' "$vout"
out=$(report_run_daily 2026-10-04 2026-10-04 0 5 normal 1)
expect_grep "a damaged FINAL set is repaired by a normal run (and the damaged one is kept)" 'REPLACED daily/UTC/2026-10-04.*revisions/' "$out"
expect_ok "...and verifies afterwards" report_verify_dir "$D4"
expect_eq "...with the late session in it" "1" "$(grep -c ',S8,' "$D4/session_report.csv")"
export CAL_NOW_EPOCH=$NOW_T

section "12. safe writing: concurrent generators and readers"
mk_session S9 "2026-10-05 09:00:00" "2026-10-05 10:00:00" 3600 COMPLETED
for i in 1 2 3 4 5 6; do "$MAIN" report daily --date 2026-10-05 >"$SANDBOX/par$i.out" 2>&1 & done; wait
gen=$(cat "$SANDBOX"/par*.out | grep -c '^GENERATED')
expect_eq "six simultaneous runs: exactly one generated the set" "1" "$gen"
expect_eq "...the others found it already there" "5" "$(cat "$SANDBOX"/par*.out | grep -cE '^(SKIPPED|UNCHANGED)')"
expect_ok "...and the result is intact" report_verify_dir "$(day 2026-10-05)"
expect_eq "...with no leftovers" "0" "$(leftovers)"
expect_eq "...and one line in the audit log" "1" "$(grep -c 'GENERATED,daily,2026-10-05' "$REPORTS_DIR/report_log.csv")"

# a snapshot of a report file is valid if it has the BOM, CRLF line ends and one column count
snap_ok() {   # FILE
    local t="$SANDBOX/snap.$$"; cp -- "$1" "$t" 2>/dev/null || return 1
    LC_ALL=C awk "$AWK_LIB"'
        FNR == 1 { if (substr($0, 1, 3) != "\357\273\277") bad = 1; $0 = substr($0, 4) }
        { if ($0 !~ /\r$/) bad = 1; sub(/\r$/, ""); n = csv_split($0, f); if (FNR == 1) w = n; else if (n != w) bad = 1 }
        END { exit (bad || FNR < 2) }' "$t"; local rc=$?; rm -f -- "$t"; return "$rc"
}
reader_test() {   # FILE SECONDS -> prints "reads torn"
    local f=$1 end=$(( SECONDS + $2 )) reads=0 torn=0
    while (( SECONDS < end )); do reads=$(( reads + 1 )); if ! snap_ok "$f"; then torn=$(( torn + 1 )); fi; done
    echo "$reads $torn"
}
# control: a NON-atomic writer (truncate, then write) must be caught by the same reader
good="$(day 2026-10-02)/session_report.csv"; ctl="$SANDBOX/control.csv"; cp "$good" "$ctl"
( while :; do : >"$ctl"; sleep 0.003; cat -- "$good" >"$ctl"; done ) & CW=$!
read -r reads torn < <(reader_test "$ctl" 3); kill "$CW" 2>/dev/null; wait "$CW" 2>/dev/null
if (( torn > 0 )); then pass "control: a truncate-then-write writer IS caught by the reader ($torn of $reads reads were torn)"; else fail "control: the torn-read detector can detect a torn read" "reads=$reads torn=$torn"; fi
# the real generator: forced rewrites in a loop while a reader hammers the file
( for i in 1 2 3 4 5 6 7 8; do "$MAIN" report daily --date 2026-10-02 --force >/dev/null 2>&1; done ) & WP=$!
tot=0; bad=0
while kill -0 "$WP" 2>/dev/null; do
    for f in session_report application_activity_report usage_summary_report; do
        tot=$(( tot + 1 )); if ! snap_ok "$(day 2026-10-02)/$f.csv"; then bad=$(( bad + 1 )); fi
    done
done; wait "$WP" 2>/dev/null
expect_eq "readers never saw a torn file during 8 forced rewrites ($tot reads)" "0" "$bad"
expect_ok "the set is still valid after the rewrites" report_verify_dir "$(day 2026-10-02)"
expect_eq "no leftovers after the rewrites" "0" "$(leftovers)"

section "13. verify catches Excel-incompatible or damaged files"
good_dir="$(day 2026-10-01)"; V="$SANDBOX/v"; mkdir -p "$V"
fresh() { rm -rf -- "$V/set"; cp -r "$good_dir" "$V/set"; rm -rf -- "$V/set/revisions"; }
refresh_manifest_hash() {   # recompute the manifest hash of one file so ONLY the structural check can fail
    local f=$1 sha; sha=$(_rg_sha "$V/set/$f")
    local mf="$V/set/report_manifest.csv"; local tmp="$mf.n"
    LC_ALL=C awk -v f="$f" -v sha="$sha" -F, 'BEGIN { OFS = "," } NR > 1 && $1 == f { $4 = sha } { print }' "$mf" >"$tmp"; mv -f -- "$tmp" "$mf"
}
mutate() {   # DESCRIPTION FILE SED_OR_COMMAND... EXPECTED_MESSAGE_REGEX
    local desc=$1 file=$2 expect=$3; shift 3
    fresh; "$@" "$V/set/$file"; refresh_manifest_hash "$file"
    local o; o=$(report_verify_dir "$V/set"); local r=$?
    if (( r != 0 )) && grep -Eq -- "$expect" <<<"$o"; then pass "verify rejects: $desc"; else fail "verify rejects: $desc" "rc=$r out=${o:0:240}"; fi
}
fresh; expect_ok "control: an untouched copy verifies" report_verify_dir "$V/set"
mutate "LF-only line endings" session_report.csv 'CRLF' sed -i 's/\r$//'
mutate "missing BOM" session_report.csv 'BOM' sed -i '1s/^\xEF\xBB\xBF//'
mutate "a ragged row" session_report.csv 'expected 19 columns' sed -i '3s/,[^,\r]*\r$/\r/'
mutate "an unbalanced quote" application_activity_report.csv 'unbalanced quotes' sed -i '2s/"svc"/"svc/'
mutate "an unprotected formula cell" application_activity_report.csv 'formula-like cell' sed -i '2s/"svc"/=1+1/'
mutate "a date Excel would not read" session_report.csv 'not YYYY-MM-DD' sed -i '2s/2026-10-01 09:00:00/01\/10\/2026/'
mutate "rows out of chronological order" session_report.csv 'chronological order' sed -i '2{h;d};3{G}'
mutate "a changed header" usage_summary_report.csv 'header differs' sed -i '1s/Item/Name/'
mutate "a wrong creation date" session_report.csv 'differs from the manifest' sed -i '2s/^2026-11-05 12:00:00/2026-11-06 12:00:00/'
mutate "a non-numeric number" session_report.csv 'not a number' sed -i '2s/,7200,/,seven,/'
long=$(printf 'x%.0s' $(seq 1 33000))
mutate "a cell above Excel's 32,767-character limit" session_report.csv '32,767' sed -i "2s/\"tester\"/\"$long\"/"
fresh; echo "x" >"$V/set/stray.csv"; o=$(report_verify_dir "$V/set"); r=$?
if (( r != 0 )) && grep -q 'not listed in the manifest' <<<"$o"; then pass "verify rejects: a stray file next to the report"; else fail "verify rejects: a stray file" "$o"; fi
fresh; echo "tampered" >>"$V/set/session_report.csv"; o=$(report_verify_dir "$V/set"); r=$?
if (( r != 0 )) && grep -q 'SHA-256' <<<"$o"; then pass "verify rejects: a file modified after it was written (manifest hash)"; else fail "verify rejects: tampering" "$o"; fi
fresh; rm -f "$V/set/usage_summary_report.csv"; o=$(report_verify_dir "$V/set"); r=$?
if (( r != 0 )) && grep -q 'missing' <<<"$o"; then pass "verify rejects: a missing file"; else fail "verify rejects: a missing file" "$o"; fi

section "14. Excel's row limit: long reports are split"
build_dataset; rm -rf -- "$REPORTS_DIR/period"
export REPORT_MAX_ROWS=5
out=$(report_run_period "" "" 0 5 normal "split")
SP="$REPORTS_DIR/period/UTC/split"
expect_eq "12 processes at 5 rows per file -> 3 parts" "application_activity_report_part1.csv application_activity_report_part2.csv application_activity_report_part3.csv" "$(ls "$SP" | grep '^application' | paste -sd' ')"
expect_eq "rows per part: 5 5 2" "5 5 2" "$(for i in 1 2 3; do printf '%s ' "$(nrows "$SP/application_activity_report_part$i.csv")"; done | sed 's/ $//')"
expect_eq "every part repeats the header" "1" "$(for i in 1 2 3; do strip "$SP/application_activity_report_part$i.csv" | head -n1; done | sort -u | wc -l)"
expect_eq "parts are consecutive: concatenated they equal the PIDs in order" "105 101 102 104 103 112 106 110 107 108 109 111" "$(for i in 1 2 3; do body "$SP/application_activity_report_part$i.csv" | tail -n +2 | cut -d, -f2; done | paste -sd' ')"
expect_eq "a short report is NOT split (5 sessions, limit 5)" "1" "$(ls "$SP" | grep -c '^session_report.csv$')"
expect_ok "the split set verifies (order is checked across parts)" report_verify_dir "$SP"
expect_eq "the manifest lists every part" "3" "$(strip "$SP/report_manifest.csv" | grep -c '^application_activity_report_part')"
unset REPORT_MAX_ROWS
out=$(report_run_period "" "" 0 5 normal "split")
expect_grep "changing the layout setting changes the set (not 'unchanged')" 'REPLACED period/UTC/split' "$out"
expect_eq "...the old parts are gone and one file remains" "application_activity_report.csv" "$(ls "$SP" | grep '^application' | paste -sd' ')"
expect_ok "...and it verifies" report_verify_dir "$SP"

section "15. other time zones never overwrite UTC reports"
build_dataset; rm -rf -- "$REPORTS_DIR/daily"; report_run_daily "" "" 0 5 normal 0 >/dev/null
utc_sum=$(sums "$(day 2026-10-01)")
out=$(report_run_daily "" "" 10800 5 normal 0)
expect_grep "+03:00 reports go under UTC+0300" 'GENERATED daily/UTC\+0300/2026-10-0[123]' "$out"
expect_eq "the UTC set is byte-identical" "$utc_sum" "$(sums "$(day 2026-10-01)")"
L2="$REPORTS_DIR/daily/UTC+0300/2026-10-02"
expect_eq "local 10-02: S2 (02:30 local) and S3 started; usage 3600 + 3000" "2 6600" "$(ov "$L2/usage_summary_report.csv" Total_Sessions) $(ov "$L2/usage_summary_report.csv" Total_Usage_Duration)"
expect_eq "the summary says which day boundaries were used" "UTC+03:00" "$(strip "$L2/usage_summary_report.csv" | sed -n 2p | cut -d, -f4)"
expect_eq "local 10-02 application activity = editor 1800 + browser 1800" "3600" "$(ov "$L2/usage_summary_report.csv" User_Application_Active_Time)"
expect_ok "the +03:00 sets verify" report_verify_dir "$L2"

section "16. empty data"
rm -f -- "$SESSIONS_FILE" "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE"; rm -rf -- "$REPORTS_DIR/daily" "$REPORTS_DIR/period"
out=$(report_run_daily "" "" 0 5 normal 0); rc=$?
expect_eq "no data: a daily run says so and succeeds" "0 1" "$rc $(grep -c 'No activity' <<<"$out")"
out=$(report_run_daily 2026-10-01 2026-10-01 0 5 normal 1)
expect_grep "an explicitly requested day is still produced" 'GENERATED daily/UTC/2026-10-01' "$out"
E=$(day 2026-10-01)
expect_eq "empty reports hold just their headers" "0 0" "$(nrows "$E/session_report.csv") $(nrows "$E/application_activity_report.csv")"
expect_eq "the summary shows zeros, and an empty average (not 0)" "0 0 " "$(ov "$E/usage_summary_report.csv" Total_Sessions) $(ov "$E/usage_summary_report.csv" Total_Processes) $(ov "$E/usage_summary_report.csv" Average_Process_Duration)"
expect_ok "empty sets verify" report_verify_dir "$E"

section "17. command line"
build_dataset; rm -rf -- "$REPORTS_DIR/daily" "$REPORTS_DIR/period"
unset CAL_NOW_EPOCH
out=$("$MAIN" report daily); rc=$?
expect_eq "main.sh report daily" "0" "$rc"
expect_grep "...prints one line per day" 'GENERATED daily/UTC/2026-10-01' "$out"
expect_grep "report list shows the sets" 'daily/UTC/2026-10-01,FINAL' "$("$MAIN" report list)"
expect_ok "report verify (all sets)" "$MAIN" report verify
expect_ok "a leap day is accepted (2024-02-29)" bash -c "'$MAIN' report daily --date 2024-02-29 && test -d '$REPORTS_DIR/daily/UTC/2024-02-29'"
expect_ok "report verify DIR" "$MAIN" report verify "$(day 2026-10-01)"
expect_grep "report period (short form 'report' with options)" 'GENERATED period/UTC/2026-10-01_to_2026-10-02' "$("$MAIN" report --from 2026-10-01 --to 2026-10-02)"
for bad in "daily --date 2026-13-01" "daily --date 2026-02-30" "daily --date 2023-02-29" "daily --from 2026-10-05 --to 2026-10-01" "daily --date 2026-10-01 --from 2026-10-01" "period --name ../etc" "daily --utc-offset +15:00" "daily --bogus" "frobnicate"; do
    # shellcheck disable=SC2086
    if "$MAIN" report $bad >/dev/null 2>&1; then fail "rejected: report $bad"; else pass "rejected: report $bad"; fi
done
expect_ok "report verify fails (exit 1) on a damaged set" bash -c "cp -r '$(day 2026-10-02)' '$SANDBOX/dmg' && echo x >>'$SANDBOX/dmg/session_report.csv' && ! '$MAIN' report verify '$SANDBOX/dmg'"
expect_eq "REPORT_MAX_ROWS=1 is refused by the configuration check" "1" "$(REPORT_MAX_ROWS=1 "$MAIN" status >/dev/null 2>&1; echo $?)"

section "18. the raw data is never modified by report generation"
build_dataset
before=$(checksums); names_before=$(ls -A "$DATA_DIR" | paste -sd' ')
rm -rf -- "$REPORTS_DIR/daily" "$REPORTS_DIR/period"
"$MAIN" report daily >/dev/null; "$MAIN" report period >/dev/null; "$MAIN" report daily --force >/dev/null; "$MAIN" report verify >/dev/null
expect_eq "sessions / processes / details: identical checksums" "$before" "$(checksums)"
expect_eq "no new file in data/" "$names_before" "$(ls -A "$DATA_DIR" | paste -sd' ')"

section "19. end to end with the real daemon"
rm -rf -- "$DATA_DIR" "$STATE_DIR" "$REPORTS_DIR"; mkdir -p "$DATA_DIR" "$STATE_DIR"
cp /bin/sleep "$SANDBOX/bin/appx"
"$MAIN" consent --accept >/dev/null; "$MAIN" start >/dev/null; sleep 2
"$SANDBOX/bin/appx" 4 & PX=$!; sleep 6; wait "$PX" 2>/dev/null
"$MAIN" stop >/dev/null
today=$(date -u +%F)
out=$("$MAIN" report daily); rc=$?
expect_eq "the daily report of today is produced" "0" "$rc"
expect_grep "...and is PARTIAL (the day is not over)" "GENERATED daily/UTC/$today \(PARTIAL" "$out"
T="$REPORTS_DIR/daily/UTC/$today"
expect_ok "...and verifies" "$MAIN" report verify "$T"
expect_eq "the session report holds the real session (closed cleanly)" "COMPLETED" "$(body "$T/session_report.csv" | tail -n +2 | awk -F, '{print $6}' | head -1)"
# Judge the app by ITS OWN PID: other processes of this user (e.g. a second test run) can be monitored too.
AR="$T/application_activity_report.csv"
expect_eq "the application report holds the app that ran (by PID): name, application, root, status" "appx App X yes COMPLETED" "$(rcell "$AR" 3 "$PX" 4) $(rcell "$AR" 3 "$PX" 5) $(rcell "$AR" 3 "$PX" 7) $(rcell "$AR" 3 "$PX" 14)"
expect_eq "...exactly one row for that PID" "1" "$(strip "$AR" | awk -F, -v p="$PX" '$3 == p {n++} END {print n+0}')"
v=$(rcell "$AR" 3 "$PX" 10); if [[ $v =~ ^[0-9]+$ ]] && (( v >= 3 && v <= 8 )); then pass "...and its duration is about its 4 s run ($v s)"; else fail "...its duration is about 4 s" "got [$v]"; fi
ua=$(rcell "$T/usage_summary_report.csv" 8 User_Application_Launches 9); if [[ $ua =~ ^[0-9]+$ ]] && (( ua >= 1 )); then pass "...counted as a launch in the summary ($ua)"; else fail "...counted as a launch" "got [$ua]"; fi

section "20. daily automation: the systemd timer templates"
for t in cal-report.service cal-report.timer; do
    sed "s#@CAL_ROOT@#${ROOT}#g" "$ROOT/install/$t.template" >"$SANDBOX/$t"
    expect_eq "$t: every placeholder was replaced" "0" "$(grep -c '@' "$SANDBOX/$t" || true)"
done
exec_line=$(grep '^ExecStart=' "$SANDBOX/cal-report.service" | cut -d= -f2-)
expect_eq "the service runs the daily report command" "$ROOT/main.sh report daily" "$exec_line"
expect_ok "...and that exact command line works (exit 0) — it is what systemd will run" bash -c "$exec_line"
expect_grep "the timer fires shortly after midnight" 'OnCalendar=\*-\*-\* 00:10:00' "$(cat "$SANDBOX/cal-report.timer")"
expect_grep "...and catches up days missed while the computer was off" 'Persistent=true' "$(cat "$SANDBOX/cal-report.timer")"
if command -v systemd-analyze >/dev/null 2>&1; then
    expect_ok "systemd-analyze accepts the unit files" systemd-analyze verify "$SANDBOX/cal-report.service" "$SANDBOX/cal-report.timer"
fi
expect_eq "install.sh refuses an unknown option before doing anything" "1" "$("$ROOT/install/install.sh" --bogus >/dev/null 2>&1; echo $?)"

printf '\n%d checks, %d failed\n' "$TOTAL" "$FAILS"
if (( FAILS == 0 )); then echo "ALL REPORT TESTS PASSED"; fi
exit "$FAILS"
