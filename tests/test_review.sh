#!/usr/bin/env bash
# =============================================================================
# tests/test_review.sh — regression tests for the defects found in the code review
# (see CHANGELOG.md, v0.6.1). Each section names the defect it guards.
# Sandboxed: nothing outside a temp dir is touched.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/bin"
export DATA_DIR="$SANDBOX/data" STATE_DIR="$SANDBOX/state" REPORTS_DIR="$SANDBOX/reports"
export CONSENT_FILE="$SANDBOX/consent" INTERVAL_SEC=1 MIN_DURATION_SEC=0 CAL_ROOT="$ROOT"
export APPS_MAP_FILE="$SANDBOX/apps.map" IGNORE_FILE="$SANDBOX/ignore.list" DESKTOP_DIRS="$SANDBOX/desktop"
: >"$APPS_MAP_FILE"; : >"$IGNORE_FILE"       # must exist before config.sh is sourced
FAILS=0 TOTAL=0
KIDS=()

cleanup() {
    local p
    "$ROOT/main.sh" stop >/dev/null 2>&1 || true
    for p in "${KIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]  actual: [$3]"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# shellcheck source=/dev/null
source "$ROOT/config.sh"
for m in common consent storage sessionlog collector detector session recovery daemon; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$m.sh"
done
storage_init
MAIN="$ROOT/main.sh"

# =============================================================================
section "R1. non-ASCII / hostile process names survive (was: '?' and \$'\\330..' garbage)"
"$MAIN" consent --accept >/dev/null 2>&1
"$MAIN" start >/dev/null 2>&1; sleep 2
ar1="برنامج"; ar2="تطبيقات_عربية_طويلة"; tabname=$(printf 'ab\tcd')
for n in "$ar1" "$ar2" "$tabname"; do cp "$(command -v sleep)" "$SANDBOX/bin/$n"; done
"$SANDBOX/bin/$ar1" 3 & KIDS+=("$!"); "$SANDBOX/bin/$ar2" 3 & KIDS+=("$!"); "$SANDBOX/bin/$tabname" 3 & KIDS+=("$!")
sleep 7
"$MAIN" stop >/dev/null 2>&1
expect_eq "Arabic name recorded in processes.csv (not '???')" 1 "$(grep -c "\"$ar1\"" "$PROCESSES_FILE")"
expect_eq "Arabic name recorded in details.Command_Name verbatim" 1 "$(grep -c ",\"$ar1\",Background_Process,\"$ar1\"," "$PROCESS_DETAILS_FILE")"
expect_eq "no shell-quoting garbage (\$'\\330) in any file" 0 "$(grep -c "\\\\3[0-9][0-9]" "$PROCESS_DETAILS_FILE" "$PROCESSES_FILE" | awk -F: '{s+=$2} END{print s+0}')"
expect_eq "a name cut at the kernel 15-byte limit keeps its readable 15-byte prefix" 1 "$(grep -c '"تطبيقات_"' "$PROCESSES_FILE")"
expect_eq "a name that is cut at 15 bytes does not become all '?'" 0 "$(grep -c '"??????' "$PROCESSES_FILE")"
expect_eq "tab in a name does not break the record layout (name kept, tab neutralised)" 1 "$(grep -c '"ab.cd"' "$PROCESSES_FILE")"
expect_eq "processes --check passes" 0 "$("$MAIN" processes --check >/dev/null 2>&1; echo $?)"
expect_eq "files are valid UTF-8" 0 "$(iconv -f UTF-8 -t UTF-8 "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE" >/dev/null 2>&1; echo $?)"

section "R2. collector_exe_names: raw base names, one find call, control chars neutralised"
cp "$(command -v sleep)" "$SANDBOX/bin/plain"
"$SANDBOX/bin/plain" 20 & KIDS+=("$!"); p1=$!
"$SANDBOX/bin/$ar1" 20 & KIDS+=("$!"); p2=$!
"$SANDBOX/bin/$tabname" 20 & KIDS+=("$!"); p3=$!
sleep 0.3
out=$(collector_exe_names "$p1" "$p2" "$p3" 999999)
expect_eq "plain" "$p1	plain" "$(grep "^$p1	" <<<"$out")"
expect_eq "Arabic verbatim" "$p2	$ar1" "$(grep "^$p2	" <<<"$out")"
expect_eq "tab replaced by ?" "$p3	ab?cd" "$(grep "^$p3	" <<<"$out")"
expect_eq "a vanished pid is simply skipped" 3 "$(grep -c . <<<"$out")"

# =============================================================================
section "R3. an ended process is not lost when the daemon exits mid-cycle (was: ENDED cleared by close_all)"
DATA_DIR="$SANDBOX/d3"; STATE_DIR="$SANDBOX/s3"
SESSIONS_FILE="$DATA_DIR/sessions.csv"; SESSIONS_LOCK="$DATA_DIR/.sessions.lock"
PROCESSES_FILE="$DATA_DIR/processes.csv"; PROCESS_DETAILS_FILE="$DATA_DIR/process_details.csv"
SESSION_FILE="$STATE_DIR/session.state"; ACTIVE_FILE="$STATE_DIR/active.tsv"; HEARTBEAT_FILE="$STATE_DIR/heartbeat"
LOG_FILE="$STATE_DIR/cal.log"; PID_FILE="$STATE_DIR/daemon.pid"; LOCK_FILE="$STATE_DIR/daemon.lock"
storage_init; storage_prepare_all
ACTIVE=(); ACTIVE_START=(); ENDED=()
session_begin
UP=$(( $(cut -d. -f1 /proc/uptime) ))
NOW=$(date +%s)
R_PID=70001; R_PPID=1; R_START_MONO=$(( UP - 30 )); R_START_EPOCH=$(( NOW - 30 )); R_SEEN=$(( NOW - 30 )); R_TTY='?'; R_USER=tester
R_PAUSED=0; R_PRE=no; R_SESSION=$SESSION_ID; R_CLASS=Background_Process; R_CAT=background; R_GROUP=g; R_ROOT=yes; R_APP=lostapp; R_CMD=lostapp; R_COMM=lostapp
record_pack
ENDED=("0"$'\t'"0"$'\t'"0"$'\t'"$REPLY")          # ended in the cycle that got cut short
daemon_finalize
expect_eq "the ended process was written (COMPLETED)" 1 "$(grep -c '"lostapp".*COMPLETED$' "$PROCESSES_FILE")"
expect_eq "its session was closed" 0 "$(grep -c ',ACTIVE$' "$SESSIONS_FILE")"

# =============================================================================
section "R4. storage_save_active never replaces a good table with a truncated one"
ACTIVE=(); ACTIVE_START=()
ACTIVE[1]="rec-one"; ACTIVE[2]="rec-two"
storage_save_active
good=$(<"$ACTIVE_FILE")
ACTIVE[3]="rec-three"
mkdir -p "$ACTIVE_FILE.tmp"                       # the temp file cannot be created -> the write fails
if storage_save_active 2>/dev/null; then fail "failure is reported"; else pass "failure is reported (rc != 0)"; fi
expect_eq "the previous table is intact" "$good" "$(<"$ACTIVE_FILE")"
rmdir "$ACTIVE_FILE.tmp"
storage_save_active
expect_eq "works again afterwards (3 records)" 3 "$(grep -c . "$ACTIVE_FILE")"

section "R5. a torn line is closed before the next row is appended (was: rows glued together)"
f="$SANDBOX/torn.csv"
storage_prepare_csv "$f" "$PROCESSES_HEADER"
printf 'S1,1,"half-written' >>"$f"                  # what a failed write leaves behind
PROCESSES_FILE_BAK=$PROCESSES_FILE; PROCESSES_FILE=$f
STORAGE_DIRTY=1
storage_write_line processes 'S2,2,"next",x'
PROCESSES_FILE=$PROCESSES_FILE_BAK
expect_eq "the next row starts on its own line" 'S2,2,"next",x' "$(tail -n 1 "$f")"
expect_eq "the fragment stays on its own line (not merged)" 'S1,1,"half-written' "$(tail -n 2 "$f" | head -n 1)"

section "R6. CSV files we own are made private (was: left as created by an older umask)"
f2="$SANDBOX/open.csv"
storage_prepare_csv "$f2" "$PROCESSES_HEADER"; chmod 644 "$f2"
storage_prepare_csv "$f2" "$PROCESSES_HEADER"
expect_eq "processes-style CSV re-secured to 600" 600 "$(stat -c %a "$f2")"
chmod 644 "$SESSIONS_FILE"; sessionlog_start R6 "$NOW" tester 1000
expect_eq "sessions.csv re-secured to 600" 600 "$(stat -c %a "$SESSIONS_FILE")"

# =============================================================================
section "R7. purge cannot run while a logger holds (or starts holding) the lock"
DATA_DIR="$SANDBOX/data"; STATE_DIR="$SANDBOX/state"      # back to the real sandbox for CLI calls
"$MAIN" consent --accept >/dev/null 2>&1
printf 'keep-me\n' >/dev/null
"$MAIN" start >/dev/null 2>&1; sleep 2
out=$("$MAIN" purge --all --yes 2>&1); rc=$?
expect_eq "purge refuses while the logger runs" 1 "$rc"
case $out in *"stop the logger first"*) pass "...with the usual message" ;; *) fail "message" "$out" ;; esac
expect_eq "data untouched" 1 "$([[ -s $SANDBOX/data/sessions.csv ]] && echo 1 || echo 0)"
"$MAIN" stop >/dev/null 2>&1
( exec 9>"$SANDBOX/state/daemon.lock"; flock -n 9 && sleep 4 ) & KIDS+=("$!"); sleep 0.5      # another process holds the lock
out=$("$MAIN" purge --all --yes 2>&1); rc=$?
expect_eq "purge refuses while ANY process holds the daemon lock" 1 "$rc"
expect_eq "sessions.csv still there" 1 "$([[ -s $SANDBOX/data/sessions.csv ]] && echo 1 || echo 0)"
wait "$!" 2>/dev/null; sleep 4.5
out=$("$MAIN" purge --all --yes 2>&1); rc=$?
expect_eq "purge works when nobody holds the lock" 0 "$rc"
expect_eq "...and deleted the data" 0 "$([[ -e $SANDBOX/data/sessions.csv ]] && echo 1 || echo 0)"

# =============================================================================
section "R8. the watchdog is pinged every WatchdogSec/4, not at every scan"
pings=0
daemon_notify() { if [[ $1 == WATCHDOG=1 ]]; then pings=$(( pings + 1 )); fi; }
WATCHDOG_USEC=8000000; unset WATCHDOG_PID; DAEMON_LAST_PING=0
for i in 1 2 3 4 5 6 7 8 9 10; do daemon_watchdog_ping; done
expect_eq "10 immediate scans -> 1 ping (first one right away)" 1 "$pings"
DAEMON_LAST_PING=$(( DAEMON_LAST_PING - 3 )); daemon_watchdog_ping
expect_eq "after WatchdogSec/4 (2 s) the next ping is sent" 2 "$pings"
WATCHDOG_USEC=""; pings=0; daemon_watchdog_ping
expect_eq "no WATCHDOG_USEC -> never pings" 0 "$pings"
unset WATCHDOG_USEC

# =============================================================================
section "R9. configuration hardening"
cfg="$SANDBOX/cfgroot"; mkdir -p "$cfg"; cp -r "$ROOT/main.sh" "$ROOT/config.sh" "$ROOT/lib" "$ROOT/conf" "$ROOT/install" "$cfg/"
printf 'touch "%s/PWNED"\n' "$SANDBOX" >"$cfg/config.local.sh"; chmod 666 "$cfg/config.local.sh"
out=$(env -u CAL_ROOT "$cfg/main.sh" version 2>&1)
expect_eq "a world-writable config.local.sh is NOT sourced" 0 "$([[ -e $SANDBOX/PWNED ]] && echo 1 || echo 0)"
case $out in *"ignoring"*) pass "...and the user is told why" ;; *) fail "warning shown" "$out" ;; esac
chmod 600 "$cfg/config.local.sh"; env -u CAL_ROOT "$cfg/main.sh" version >/dev/null 2>&1
expect_eq "a private config.local.sh still works" 1 "$([[ -e $SANDBOX/PWNED ]] && echo 1 || echo 0)"
rm -f "$SANDBOX/PWNED"
out=$(env -u CAL_ROOT INTERVAL_SEC=08 "$ROOT/main.sh" doctor 2>&1 | grep -c "ok      configuration")
expect_eq "INTERVAL_SEC=08 is read as 8, not as a broken octal number" 1 "$out"
out=$(env -u CAL_ROOT LOG_MAX_BYTES=abc "$ROOT/main.sh" doctor 2>&1)
case $out in *"LOG_MAX_BYTES must be"*) pass "LOG_MAX_BYTES is validated" ;; *) fail "LOG_MAX_BYTES validation" "$out" ;; esac

section "R10. doctor: column is optional; default project directories are private"
nocol="$SANDBOX/nocol"; mkdir -p "$nocol"
for f in /usr/bin/* ; do [[ ${f##*/} == column ]] || ln -s "$f" "$nocol/${f##*/}" 2>/dev/null; done
out=$(PATH="$nocol" /usr/bin/bash "$ROOT/main.sh" doctor 2>&1); rc=$?
expect_eq "doctor succeeds without column on the PATH (README: optional)" 0 "$rc"
case $out in *"absent  column (optional)"*) pass "...and reports it as optional" ;; *) fail "column reported as optional" "$out" ;; esac
d10="$SANDBOX/proj10"; mkdir -p -m 755 "$d10/data"
( CAL_ROOT="$d10"; DATA_DIR="$d10/data"; STATE_DIR="$d10/state"; REPORTS_DIR="$d10/reports"; storage_init )
expect_eq "a shipped data/ directory inside the project is tightened to 700" 700 "$(stat -c %a "$d10/data")"
mkdir -m 755 "$SANDBOX/outside"
( CAL_ROOT="$d10"; DATA_DIR="$SANDBOX/outside"; STATE_DIR="$d10/state"; REPORTS_DIR="$d10/reports"; storage_init )
expect_eq "a directory chosen outside the project is NOT chmod-ed" 755 "$(stat -c %a "$SANDBOX/outside")"

# =============================================================================
printf '\n%d checks, %d failed\n' "$TOTAL" "$FAILS"
exit $(( FAILS > 0 ))
