#!/usr/bin/env bash
# =============================================================================
# tests/smoke.sh — End-to-end smoke test in a throw-away sandbox.
# Never touches the real data/state: every path is redirected to a temp dir.
# Scenarios: normal run + clean stop, kill -9 + recovery, CSV safety, report.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
export DATA_DIR="$SANDBOX/data" STATE_DIR="$SANDBOX/state" REPORTS_DIR="$SANDBOX/reports"
export CONSENT_FILE="$SANDBOX/consent" INTERVAL_SEC=1 MIN_DURATION_SEC=1
MAIN="$ROOT/main.sh"
FAILS=0

pass() { printf '  PASS  %s\n' "$1"; }
fail() { printf '  FAIL  %s\n' "$1"; FAILS=$(( FAILS + 1 )); }
check() { # check DESCRIPTION COMMAND...
    local d=$1; shift
    if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d"; fi
}
cleanup() {
    "$MAIN" stop >/dev/null 2>&1 || true
    if [[ -n ${LONG:-} ]]; then kill "$LONG" 2>/dev/null || true; fi
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

echo "== consent gate =="
if "$MAIN" daemon >/dev/null 2>&1; then fail "daemon refuses to run without consent"; else pass "daemon refuses to run without consent"; fi
"$MAIN" consent --accept >/dev/null

echo "== normal run =="
"$MAIN" start >/dev/null
check "daemon is running" "$MAIN" status
sleep 2
cp /bin/sleep "$SANDBOX/My App"        # a name with a space
"$SANDBOX/My App" 3 &
sleep 1 && sleep 3 &
wait
sleep 2
"$MAIN" stop >/dev/null
PFILE=$(ls "$DATA_DIR"/processes_*.csv 2>/dev/null | head -n1)
SFILE=$(ls "$DATA_DIR"/sessions_*.csv 2>/dev/null | head -n1)
check "processes CSV exists" test -s "${PFILE:-/nonexistent}"
check "CSV starts with UTF-8 BOM" bash -c "head -c3 '${PFILE:-/x}' | od -An -tx1 | grep -q 'ef bb bf'"
check "process with a space in its name was logged" grep -q 'My App' "${PFILE:-/x}"
check "session closed with reason logout" grep -q 'logout' "${SFILE:-/x}"
check "state files removed after clean stop" test ! -e "$STATE_DIR/session.state"

echo "== crash recovery (kill -9) =="
"$MAIN" start >/dev/null
sleep 4242 & LONG=$!
sleep 3
kill -9 "$(cat "$STATE_DIR/daemon.pid")"
sleep 1
check "stale session file remains after kill -9" test -s "$STATE_DIR/session.state"
"$MAIN" start >/dev/null
sleep 2
check "session recovered as crash_recovered" grep -q 'crash_recovered' "$DATA_DIR"/sessions_*.csv
kill "$LONG" 2>/dev/null; sleep 2
"$MAIN" stop >/dev/null
check "long process logged after it ended" grep -q '"sleep"' "$DATA_DIR"/processes_*.csv

echo "== analysis & report =="
check "stats runs" "$MAIN" stats
check "report runs" "$MAIN" report
check "report has 5 files" bash -c "[ \$(ls '$REPORTS_DIR'/report_*/ | wc -l) -eq 5 ]"
check "kernel threads are not logged" bash -c "! grep -qE 'kthreadd|kworker' '$DATA_DIR'/processes_*.csv"
check "no command-line arguments leaked" bash -c "! grep -rq 4242 '$DATA_DIR'"

echo
if (( FAILS == 0 )); then echo "ALL SMOKE TESTS PASSED"; else echo "$FAILS TEST(S) FAILED"; fi
exit "$FAILS"
