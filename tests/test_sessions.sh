#!/usr/bin/env bash
# =============================================================================
# tests/test_sessions.sh — Session Logger tests (sessions.csv)
# -----------------------------------------------------------------------------
# Part A: calls the sessionlog_* functions directly with FIXED timestamps, so
#         durations and UTC formatting can be asserted exactly.
# Part B: runs the real daemon (./main.sh) in a sandbox: start/stop, kill -9,
#         simulated power loss, lost state file.
# Everything happens in a temp dir; the real data/ is never touched.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
export DATA_DIR="$SANDBOX/data" STATE_DIR="$SANDBOX/state" REPORTS_DIR="$SANDBOX/reports"
export CONSENT_FILE="$SANDBOX/consent" INTERVAL_SEC=1 MIN_DURATION_SEC=1
export CAL_ROOT="$ROOT"
FAILS=0 TOTAL=0

cleanup() {
    "$ROOT/main.sh" stop >/dev/null 2>&1 || true
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi; }
# expect_eq DESCRIPTION EXPECTED ACTUAL
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]  actual: [$3]"; fi; }
# expect_ok DESCRIPTION COMMAND...
expect_ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi; }
expect_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d" "command unexpectedly succeeded: $*"; else pass "$d"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# --- load the modules under test --------------------------------------------
# shellcheck source=/dev/null
source "$ROOT/config.sh"
for m in common storage sessionlog consent analyzer; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$m.sh"
done
storage_init

ME=$(whoami); MYUID=$(id -u)
T=1793445277                       # 2026-10-31 11:14:37 UTC
rows()   { local n; n=$(grep -c '' "$SESSIONS_FILE"); echo $(( n - 1 )); }   # data rows (minus header)
row_of() { grep -m1 "^$1," "$SESSIONS_FILE"; }
reset()  { rm -f -- "$SESSIONS_FILE" "$SESSIONS_FILE".* "$SESSIONS_LOCK"; }

# =============================================================================
section "A1. start a new session"
reset
sessionlog_start A1 "$T" "$ME" "$MYUID"
expect_eq "header is exactly the required columns" \
    "Session_ID,Username,User_ID,Login_Date,Login_Time,Logout_Date,Logout_Time,Duration_Seconds,Status" \
    "$(head -n1 "$SESSIONS_FILE" | LC_ALL=C sed 's/^\xEF\xBB\xBF//')"
expect_eq "file starts with a UTF-8 BOM (Excel)" "efbbbf" "$(head -c3 "$SESSIONS_FILE" | od -An -tx1 | tr -d ' \n')"
expect_eq "row = id, whoami, uid, UTC login, empty logout, ACTIVE" \
    "A1,\"$ME\",$MYUID,2026-10-31,11:14:37,,,,ACTIVE" "$(row_of A1)"
expect_eq "username column matches whoami" "$ME" "$(whoami)"

section "A2. a start is never recorded twice"
sessionlog_start A1 "$T" "$ME" "$MYUID"
sessionlog_start A1 $(( T + 50 )) "$ME" "$MYUID"
expect_eq "still exactly one row" "1" "$(rows)"
expect_eq "original login time was kept" "A1,\"$ME\",$MYUID,2026-10-31,11:14:37,,,,ACTIVE" "$(row_of A1)"

section "A3. end of a session updates the SAME row"
sessionlog_close A1 COMPLETED $(( T + 125 )) "$T" 125
expect_eq "row now holds logout time, duration and status" \
    "A1,\"$ME\",$MYUID,2026-10-31,11:14:37,2026-10-31,11:16:42,125,COMPLETED" "$(row_of A1)"
expect_eq "no extra row was added" "1" "$(rows)"
expect_ok "a .bak of the previous version exists" test -s "$SESSIONS_FILE.bak"

section "A4. duration calculation (seconds and minutes)"
reset
sessionlog_start D1 "$T" "$ME" "$MYUID"
sessionlog_close D1 COMPLETED $(( T + 3725 ))          # no duration given: computed from the row
expect_eq "duration computed from Login_* (1h 2m 5s = 3725 s)" \
    "D1,\"$ME\",$MYUID,2026-10-31,11:14:37,2026-10-31,12:16:42,3725,COMPLETED" "$(row_of D1)"
expect_eq "minutes shown as 62.08" "62.08" "$(analyzer_sessions_rows "" "" "" 2>/dev/null | cut -f9)"
# crossing midnight and a month boundary
sessionlog_start D2 1793491199 "$ME" "$MYUID"            # 2026-10-31 23:59:59
sessionlog_close D2 COMPLETED 1793491262                 # 2026-11-01 00:01:02
expect_eq "session across midnight/month end = 63 s" \
    "D2,\"$ME\",$MYUID,2026-10-31,23:59:59,2026-11-01,00:01:02,63,COMPLETED" "$(row_of D2)"
sessionlog_start D3 951782400 "$ME" "$MYUID"             # 2000-02-29 00:00:00 (leap day)
expect_eq "leap day formats correctly" "2000-02-29" "$(row_of D3 | cut -d, -f4)"

section "A5. closing twice does not change a closed row"
sessionlog_close D1 CRASHED $(( T + 99999 )) "$T" 99999
expect_eq "closed row untouched by a second close" \
    "D1,\"$ME\",$MYUID,2026-10-31,11:14:37,2026-10-31,12:16:42,3725,COMPLETED" "$(row_of D1)"

section "A6. several sessions; earlier records are never deleted"
reset
for i in 1 2 3 4 5; do sessionlog_start "M$i" $(( T + i * 1000 )) "$ME" "$MYUID"; done
sessionlog_close M1 COMPLETED $(( T + 1100 )); sessionlog_close M2 COMPLETED $(( T + 2200 )); sessionlog_close M3 COMPLETED $(( T + 3300 ))
before=$(cat "$SESSIONS_FILE")
sessionlog_start M6 $(( T + 9000 )) "$ME" "$MYUID"      # a new session starts later
after_head=$(head -n "$(grep -c '' <<<"$before")" "$SESSIONS_FILE")
expect_eq "all previous lines are byte-identical after a new start" "$before" "$after_head"
expect_eq "6 sessions recorded" "6" "$(rows)"
expect_eq "all Session_IDs are unique" "6" "$(cut -d, -f1 "$SESSIONS_FILE" | tail -n +2 | sort -u | wc -l)"
sessionlog_close M6 COMPLETED $(( T + 9100 ))
expect_eq "closing the newest leaves the older rows intact" "$before" "$(head -n "$(grep -c '' <<<"$before")" "$SESSIONS_FILE")"
expect_eq "3 COMPLETED among the first five + M6" "4" "$(grep -c ',COMPLETED$' "$SESSIONS_FILE")"
sessionlog_new_id GEN "$T"; sessionlog_new_id GEN2 "$T"
expect_eq "generated IDs have the documented shape" "1" "$(grep -cE '^20261031T111437Z-[0-9]+-[0-9a-f]{4}$' <<<"$GEN")"
if [[ $GEN != "$GEN2" ]]; then pass "two generated IDs differ"; else fail "two generated IDs differ" "$GEN"; fi

section "A7. unclosed (orphaned) sessions"
sessionlog_reap_orphans ""        # M4 and M5 were never closed
expect_eq "M4 becomes INTERRUPTED with empty end/duration" \
    "M4,\"$ME\",$MYUID,2026-10-31,12:21:17,,,,INTERRUPTED" "$(row_of M4)"
expect_eq "no ACTIVE row is left" "0" "$(grep -c ',ACTIVE$' "$SESSIONS_FILE")"
expect_eq "no rows were lost by reaping" "6" "$(rows)"
sessionlog_start K1 "$T" "$ME" "$MYUID"; sessionlog_start K2 "$T" "$ME" "$MYUID"
sessionlog_reap_orphans K2
expect_eq "the kept session stays ACTIVE" "K2,\"$ME\",$MYUID,2026-10-31,11:14:37,,,,ACTIVE" "$(row_of K2)"
expect_eq "the other one is INTERRUPTED" "INTERRUPTED" "$(row_of K1 | awk -F, '{print $NF}')"

section "A8. CSV validity"
reset
sessionlog_start V1 "$T" "$ME" "$MYUID"; sessionlog_close V1 COMPLETED $(( T + 60 ))
sessionlog_start V2 "$T" "$ME" "$MYUID"                       # left ACTIVE
sessionlog_start V3 "$T" 'we,ird "name"' 1001; sessionlog_close V3 COMPLETED $(( T + 5 ))
sessionlog_start V4 "$T" '=cmd|calc' 1002;     sessionlog_close V4 COMPLETED $(( T + 5 ))
expect_ok "verify accepts a healthy file" sessionlog_verify
expect_eq "username with comma and quotes is stored escaped" 'V3,"we,ird ""name""",1001,2026-10-31,11:14:37,2026-10-31,11:14:42,5,COMPLETED' "$(row_of V3)"
expect_eq "formula-looking username is neutralised" "V4,\"'=cmd|calc\"" "$(row_of V4 | cut -d, -f1-2)"
expect_eq "every line parses to 9 fields" "0" "$(LC_ALL=C awk "$AWK_LIB"'FNR>1 && csv_split($0,f)!=9 {bad++} END{print bad+0}' "$SESSIONS_FILE")"
cp "$SESSIONS_FILE" "$SANDBOX/bad.csv"
{ echo 'B1,"x",abc,2026-10-31,11:14:37,,,,ACTIVE'            # non-numeric uid
  echo 'B2,"x",1,2026-10-31,11:14:37,,,,BOGUS'               # unknown status
  echo 'V1,"x",1,2026-10-31,11:14:37,,,,ACTIVE'              # duplicate id
  echo 'B3,"x",1,2026-10-31,11:14:37,2026-10-31,11:00:00,5,COMPLETED'   # logout before login
  echo 'B4,"x",1,2026-10-31,11:14:37,,,10,ACTIVE'            # ACTIVE with duration
  echo 'B5,"x",1,2026-10-31'; } >>"$SANDBOX/bad.csv"         # truncated line
out=$(sessionlog_verify "$SANDBOX/bad.csv")
expect_fail "verify rejects a corrupted file" sessionlog_verify "$SANDBOX/bad.csv"
if grep -q ' 6 problem(s)' <<<"$out"; then pass "verify counts exactly 6 problems"; else fail "verify counts exactly 6 problems" "$out"; fi

section "A9. file damage is handled"
reset
sessionlog_start T1 "$T" "$ME" "$MYUID"
printf 'T2,"partial' >>"$SESSIONS_FILE"                    # torn write: no newline
sessionlog_start T3 "$T" "$ME" "$MYUID"
expect_eq "new row is on its own line after a torn write" "T3,\"$ME\",$MYUID,2026-10-31,11:14:37,,,,ACTIVE" "$(row_of T3)"
expect_eq "the earlier row survived" "T1,\"$ME\",$MYUID,2026-10-31,11:14:37,,,,ACTIVE" "$(row_of T1)"
reset
printf 'something,else\n1,2\n' >"$SESSIONS_FILE"
sessionlog_start H1 "$T" "$ME" "$MYUID"
expect_eq "foreign file kept aside, not overwritten" "something,else" "$(head -n1 "$SESSIONS_FILE".invalid.* | head -n1)"
expect_eq "a fresh valid sessions.csv was created" "1" "$(rows)"
expect_ok "...and it verifies" sessionlog_verify
reset
sessionlog_start N1 "$T" "$ME" "$MYUID"
rm -f -- "$SESSIONS_FILE"                                  # row deleted behind our back
sessionlog_close N1 COMPLETED $(( T + 30 )) "$T" 30 "$ME" "$MYUID"
expect_eq "closing a vanished row re-creates it (session not lost)" \
    "N1,\"$ME\",$MYUID,2026-10-31,11:14:37,2026-10-31,11:15:07,30,COMPLETED" "$(row_of N1)"

section "A10. concurrent writers (flock)"
reset
for i in $(seq 1 30); do ( sessionlog_start "C$i" $(( T + i )) "user$i" "$i" ) & done; wait
expect_eq "30 parallel starts -> 30 rows" "30" "$(rows)"
for i in $(seq 1 30); do ( sessionlog_close "C$i" COMPLETED $(( T + 1000 + i )) ) & done; wait
expect_eq "30 parallel closes -> 30 COMPLETED, none lost" "30" "$(grep -c ',COMPLETED$' "$SESSIONS_FILE")"
expect_eq "still 30 rows" "30" "$(rows)"
expect_ok "file verifies after the race" sessionlog_verify
expect_eq "no temp files left behind" "0" "$(find "$DATA_DIR" -name 'sessions.csv.tmp.*' | wc -l)"
expect_eq "durations are right (C7 = 1000 s)" "1000" "$(row_of C7 | awk -F, '{print $(NF-1)}')"
for i in $(seq 1 10); do
    ( sessionlog_start "R$i" "$T" "u" 1; sessionlog_close "R$i" COMPLETED $(( T + i )) ) &
    ( sessionlog_start "S$i" "$T" "u" 1 ) &
done; wait
expect_eq "mixed parallel start/close: 20 more rows" "50" "$(rows)"
expect_ok "file verifies after mixed race" sessionlog_verify

section "A11. UTC inside, local time only for display"
reset
export TZ='<+03>-3'
sessionlog_start U1 "$T" "$ME" "$MYUID"; sessionlog_close U1 COMPLETED $(( T + 600 ))
expect_eq "stored login time is UTC even when TZ=UTC+3" "2026-10-31,11:14:37" "$(row_of U1 | cut -d, -f4,5)"
expect_eq "UTC view equals the file" "11:14:37" "$(analyzer_sessions_view "" "" "" utc | tail -n1 | cut -f4 | cut -d' ' -f2)"
expect_eq "local view is shifted +3h" "14:14:37" "$(analyzer_sessions_view "" "" "" local | tail -n1 | cut -f4 | cut -d' ' -f2)"
expect_eq "--tz Asia/Riyadh view is +3h too" "14:24:37" "$(analyzer_sessions_view "" "" "" Asia/Riyadh | tail -n1 | cut -f5 | cut -d' ' -f2)"
unset TZ
expect_eq "CSV was not changed by displaying" "2026-10-31,11:14:37" "$(row_of U1 | cut -d, -f4,5)"

# =============================================================================
# Part B — the real daemon
# =============================================================================
MAIN="$ROOT/main.sh"
fresh_daemon_env() { rm -rf -- "$DATA_DIR" "$STATE_DIR"; mkdir -p "$DATA_DIR" "$STATE_DIR"; }
daemon_pid() { cat "$STATE_DIR/daemon.pid" 2>/dev/null; }
statuses() { tail -n +2 "$SESSIONS_FILE" | awk -F, '{print $NF}' | paste -sd' '; }

section "B1. daemon: start -> row ACTIVE; stop -> same row COMPLETED"
fresh_daemon_env
"$MAIN" consent --accept >/dev/null
"$MAIN" start >/dev/null
sleep 3
expect_eq "one ACTIVE row while running" "ACTIVE" "$(statuses)"
SID=$(tail -n1 "$SESSIONS_FILE" | cut -d, -f1)
expect_eq "row has whoami + uid" "\"$ME\",$MYUID" "$(tail -n1 "$SESSIONS_FILE" | cut -d, -f2,3)"
expect_ok "status command shows the session id" bash -c "'$MAIN' status | grep -q '$SID'"
"$MAIN" stop >/dev/null
expect_eq "after stop: still one row, now COMPLETED" "COMPLETED" "$(statuses)"
dur=$(tail -n1 "$SESSIONS_FILE" | awk -F, '{print $(NF-1)}')
if [[ $dur =~ ^[0-9]+$ ]] && (( dur >= 3 && dur <= 12 )); then pass "duration is plausible ($dur s)"; else fail "duration is plausible" "got [$dur]"; fi
ld=$(tail -n1 "$SESSIONS_FILE" | cut -d, -f4,5); utc_now=$(date -u +%F)
if [[ $ld == "$utc_now",* ]]; then pass "Login_Date is today's UTC date"; else fail "Login_Date is today's UTC date" "$ld vs $utc_now"; fi
first_row=$(tail -n1 "$SESSIONS_FILE")

section "B2. second session; first record preserved"
"$MAIN" start >/dev/null; sleep 2
expect_eq "two rows: COMPLETED + ACTIVE" "COMPLETED ACTIVE" "$(statuses)"
expect_eq "first row unchanged by the new session" "$first_row" "$(sed -n 2p "$SESSIONS_FILE")"
expect_eq "the two sessions have different IDs" "2" "$(tail -n +2 "$SESSIONS_FILE" | cut -d, -f1 | sort -u | wc -l)"
expect_ok "start while running does not add a row" bash -c "'$MAIN' start >/dev/null; [ \$(grep -c '' '$SESSIONS_FILE') -eq 3 ]"

section "B3. kill -9 (daemon crash): stale row is closed as CRASHED"
sleep 2
kill -9 "$(daemon_pid)"; sleep 1
expect_eq "right after the crash the row is still ACTIVE" "COMPLETED ACTIVE" "$(statuses)"
"$MAIN" start >/dev/null; sleep 2
expect_eq "restart: crashed row closed, new one opened (3 rows)" "COMPLETED CRASHED ACTIVE" "$(statuses)"
crow=$(sed -n 3p "$SESSIONS_FILE")
if [[ $(awk -F, '{print $(NF-3)}' <<<"$crow") != "" && $(awk -F, '{print $(NF-1)}' <<<"$crow") =~ ^[0-9]+$ ]]; then
    pass "crashed session got an end time (last heartbeat) and duration"; else fail "crashed session got an end time" "$crow"; fi
expect_eq "no duplicate Session_IDs" "3" "$(tail -n +2 "$SESSIONS_FILE" | cut -d, -f1 | sort -u | wc -l)"

section "B4. power loss (boot id changed) -> POWER_LOSS"
"$MAIN" stop >/dev/null
echo "boot-A-0000-0000" >"$SANDBOX/boot1"; echo "boot-B-1111-1111" >"$SANDBOX/boot2"
CAL_BOOT_ID_FILE="$SANDBOX/boot1" "$MAIN" start >/dev/null; sleep 2
kill -9 "$(daemon_pid)"; sleep 1
CAL_BOOT_ID_FILE="$SANDBOX/boot2" "$MAIN" start >/dev/null; sleep 2
expect_eq "previous session marked POWER_LOSS" "POWER_LOSS" "$(sed -n 5p "$SESSIONS_FILE" | awk -F, '{print $NF}')"

section "B5. state file lost -> orphan row becomes INTERRUPTED"
"$MAIN" stop >/dev/null
"$MAIN" start >/dev/null; sleep 2
kill -9 "$(daemon_pid)"; sleep 1
rm -f -- "$STATE_DIR/session.state" "$STATE_DIR/heartbeat" "$STATE_DIR/active.tsv"
"$MAIN" start >/dev/null; sleep 2
last_but_one=$(tail -n2 "$SESSIONS_FILE" | head -n1)
if awk -F, '{exit !($NF=="INTERRUPTED" && $(NF-3)=="" && $(NF-2)=="" && $(NF-1)=="")}' <<<"$last_but_one"; then
    pass "orphan row is INTERRUPTED with empty end/duration"; else fail "orphan row is INTERRUPTED" "$last_but_one"; fi
"$MAIN" stop >/dev/null

section "B6. whole-file checks after all that"
expect_ok "sessions --check passes" "$MAIN" sessions --check
expect_eq "no ACTIVE row remains after the final stop" "0" "$(grep -c ',ACTIVE$' "$SESSIONS_FILE")"
echo "      statuses: $(statuses)"
expect_ok "sessions table renders (UTC)" bash -c "'$MAIN' sessions | grep -q COMPLETED"
expect_ok "sessions --local renders" bash -c "TZ='<+03>-3' '$MAIN' sessions --local | grep -q 'Login(local)'"
expect_ok "sessions --status CRASHED filters" bash -c "[ \$('$MAIN' sessions --status CRASHED | tail -n +2 | wc -l) -eq 1 ]"
expect_ok "report has Duration_Minutes" bash -c "'$MAIN' report >/dev/null && head -n1 '$REPORTS_DIR'/report_*/05_sessions.csv | grep -q 'Duration_Seconds,Duration_Minutes'"
expect_ok "stats runs with the new session file" "$MAIN" stats
expect_ok "purge --before keeps files valid" bash -c "'$MAIN' purge --before 2020-01-01 --yes >/dev/null && '$MAIN' sessions --check >/dev/null"

printf '\n%d checks, %d failed\n' "$TOTAL" "$FAILS"
if (( FAILS == 0 )); then echo "ALL SESSION TESTS PASSED"; fi
exit "$FAILS"
