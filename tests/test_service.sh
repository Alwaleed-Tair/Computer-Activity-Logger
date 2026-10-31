#!/usr/bin/env bash
# =============================================================================
# tests/test_service.sh — Automatic startup (systemd user service) tests
# -----------------------------------------------------------------------------
# Part A: no systemd needed — unit rendering, escaping, exit codes, install without a manager.
# Part B: a REAL `systemd --user` manager (tests/usermgr.sh): install, enable, start, status,
#         safe stop, restart, kill -9, watchdog, start limit, single instance, consent,
#         login emulation (manager restart), uninstall. Skipped (loudly) when none can be had.
# Everything happens in temp dirs / a throw-away user; real data is never touched.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
FAILS=0 TOTAL=0 SKIPPED=0

pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]  actual: [$3]"; fi; }
expect_has() { if [[ $3 == *"$2"* ]]; then pass "$1"; else fail "$1" "missing [$2] in: ${3:0:400}"; fi; }
expect_lacks() { if [[ $3 != *"$2"* ]]; then pass "$1"; else fail "$1" "unexpected [$2] in: ${3:0:400}"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# shellcheck source=/dev/null
source "$ROOT/tests/usermgr.sh"

cleanup() {
    um_cleanup
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

# =============================================================================
# Part A — no systemd manager needed
# =============================================================================
# Each A-case runs main.sh in a sandbox through env overrides. The unit dir is inside the
# sandbox and XDG_RUNTIME_DIR points nowhere, so no real user manager is ever reached.
A="$SANDBOX/a"; mkdir -p "$A"
aenv() {
    env DATA_DIR="$A/data" STATE_DIR="$A/state" REPORTS_DIR="$A/reports" CONSENT_FILE="$A/consent" \
        SERVICE_UNIT_DIR="$A/units" SERVICE_NAME=cal-atest INTERVAL_SEC=1 \
        XDG_RUNTIME_DIR="$A/no-runtime" DBUS_SESSION_BUS_ADDRESS= "$@"
}
am() { aenv "$ROOT/main.sh" "$@"; }

section "A1. the rendered unit file"
unit=$(am service show-unit); rc=$?
expect_eq "show-unit succeeds" 0 "$rc"
expect_has "WantedBy=default.target (starts with the user manager = login)" "WantedBy=default.target" "$unit"
expect_has "runs main.sh daemon" "ExecStart=\"$ROOT/main.sh\" daemon" "$unit"
expect_has "restarts on failure" "Restart=on-failure" "$unit"
expect_has "restart delay" "RestartSec=5" "$unit"
expect_has "start limit: 5 starts / 300 s" "StartLimitBurst=5" "$unit"
expect_has "3 and 4 are never retried" "RestartPreventExitStatus=3 4" "$unit"
expect_has "safe stop: SIGTERM first" "KillSignal=SIGTERM" "$unit"
expect_has "stop timeout is STOP_TIMEOUT_SEC + 5" "TimeoutStopSec=" "$unit"
expect_has "own error file, not the journal" "StandardError=append:$A/state/service-error.log" "$unit"
expect_has "needs recorded consent" "ConditionPathExists=$A/consent" "$unit"
expect_has "no privilege gain" "NoNewPrivileges=yes" "$unit"
expect_has "private files" "UMask=0077" "$unit"
expect_has "watchdog (when systemd-notify exists)" "WatchdogSec=" "$unit"
expect_has "Type=notify" "Type=notify" "$unit"
expect_lacks "never runs as another user (no User=)" $'\nUser=' "$unit"
expect_lacks "no system-wide target" "multi-user.target" "$unit"
expect_lacks "no sudo / root anywhere" "sudo" "$unit"
if [[ $unit =~ @[A-Z_]+@ ]]; then fail "no unreplaced @PLACEHOLDER@" "${BASH_REMATCH[0]}"; else pass "no unreplaced @PLACEHOLDER@"; fi
if command -v systemd-analyze >/dev/null 2>&1; then
    printf '%s\n' "$unit" >"$A/cal-atest.service"
    if out=$(systemd-analyze verify "$A/cal-atest.service" 2>&1); then pass "systemd-analyze verify accepts the unit"; else fail "systemd-analyze verify" "$out"; fi
else
    echo "  skip  systemd-analyze not installed"
fi

section "A2. paths with spaces, % and \$ stay literal; unsafe paths are refused"
P="$SANDBOX/we ird %h \$HOME dir"
mkdir -p "$P"; cp -r "$ROOT/main.sh" "$ROOT/config.sh" "$ROOT/lib" "$ROOT/conf" "$ROOT/install" "$P/"
unit2=$(env DATA_DIR="$A/d2" STATE_DIR="$A/s2" CONSENT_FILE="$A/c2" "$P/main.sh" service show-unit); rc=$?
expect_eq "render works for an awkward path" 0 "$rc"
expect_has "% doubled, \$ literal, spaces quoted" "ExecStart=\"$SANDBOX/we ird %%h \$HOME dir/main.sh\" daemon" "$unit2"
if command -v systemd-analyze >/dev/null 2>&1; then
    printf '%s\n' "$unit2" >"$A/awk.service"
    if out=$(systemd-analyze verify "$A/awk.service" 2>&1); then pass "systemd-analyze accepts the awkward-path unit"; else fail "verify awkward path" "$out"; fi
fi
Q="$SANDBOX/qu\"ote"; mkdir -p "$Q"; cp -r "$ROOT/main.sh" "$ROOT/config.sh" "$ROOT/lib" "$ROOT/conf" "$ROOT/install" "$Q/"
out=$(env DATA_DIR="$A/d2" STATE_DIR="$A/s2" CONSENT_FILE="$A/c2" "$Q/main.sh" service show-unit 2>&1); rc=$?
if (( rc != 0 )); then pass "a path containing a quote is refused (rc=$rc)"; else fail "quote path refused" "$out"; fi
expect_has "...with an explanation" "refusing" "$out"
N="$SANDBOX/new
line"; mkdir -p "$N"; cp -r "$ROOT/main.sh" "$ROOT/config.sh" "$ROOT/lib" "$ROOT/conf" "$ROOT/install" "$N/"
out=$(env DATA_DIR="$A/d2" STATE_DIR="$A/s2" CONSENT_FILE="$A/c2" "$N/main.sh" service show-unit 2>&1); rc=$?
if (( rc != 0 )); then pass "a path containing a newline is refused"; else fail "newline path refused" "$out"; fi

section "A3. exit codes of the daemon (what the unit's restart policy relies on)"
out=$(am daemon 2>&1); rc=$?
expect_eq "no consent => exit 4 (never retried)" 4 "$rc"
expect_has "no consent => says how to give it" "consent" "$out"
am consent --accept >/dev/null 2>&1
( am daemon >"$A/d1.out" 2>&1 ) &
d1=$!
for (( i = 0; i < 50; i++ )); do [[ -s $A/state/daemon.pid ]] && break; sleep 0.2; done
out=$(am daemon 2>&1); rc=$?
expect_eq "second instance => exit 3 (never retried)" 3 "$rc"
expect_has "second instance explains itself" "already running" "$out"
expect_eq "the first instance is still alive" 1 "$(kill -0 "$d1" 2>/dev/null && echo 1 || echo 0)"
expect_eq "exactly one lock holder" 1 "$(( $(grep -c '^' "$A/state/daemon.pid") ))"
dpid=$(cat "$A/state/daemon.pid"); kill -TERM "$dpid" 2>/dev/null; wait "$d1" 2>/dev/null; rc=$?
expect_eq "SIGTERM => clean exit 0" 0 "$rc"
expect_eq "session closed COMPLETED by the clean stop" 1 "$(grep -c ',COMPLETED$' "$A/data/sessions.csv" 2>/dev/null || true)"

section "A4. install without a user manager"
am consent --revoke >/dev/null 2>&1
out=$(am service install 2>&1); rc=$?
if (( rc != 0 )); then pass "install refuses without consent"; else fail "install without consent" "$out"; fi
expect_eq "...and writes no unit" 0 "$([[ -e $A/units/cal-atest.service ]] && echo 1 || echo 0)"
am consent --accept >/dev/null 2>&1
out=$(am service install 2>&1); rc=$?
expect_eq "install succeeds with consent but no manager" 0 "$rc"
expect_has "install says where the file is" "$A/units/cal-atest.service" "$out"
expect_has "install explains the manager is unreachable" "no systemd user manager" "$out"
expect_eq "unit file exists" 1 "$([[ -f $A/units/cal-atest.service ]] && echo 1 || echo 0)"
expect_eq "no half-written .install.* leftovers" 0 "$(find "$A/units" -name '.install.*' | wc -l)"
out=$(am service status 2>&1); rc=$?
expect_eq "status without a manager => rc 4" 4 "$rc"
expect_has "status says why" "not reachable" "$out"
for c in start stop restart enable; do
    out=$(am service "$c" 2>&1); rc=$?
    if (( rc != 0 )); then pass "service $c without a manager fails clearly"; else fail "service $c without a manager" "$out"; fi
    expect_has "service $c names the manual fallback" "./main.sh start" "$out"
done
out=$(am service bogus 2>&1); rc=$?
if (( rc != 0 )); then pass "unknown service command rejected"; else fail "unknown command" "$out"; fi
out=$(am service uninstall 2>&1); rc=$?
expect_eq "uninstall works without a manager" 0 "$rc"
expect_eq "...and removes the unit" 0 "$([[ -e $A/units/cal-atest.service ]] && echo 1 || echo 0)"
expect_has "...and keeps the data" "data was kept" "$out"

section "A5. rotate-logs"
head -c 3000 /dev/zero | tr '\0' 'x' >"$A/state/service-error.log"
aenv LOG_MAX_BYTES=1000 "$ROOT/main.sh" rotate-logs >/dev/null 2>&1
expect_eq "oversized error log is rotated" 1 "$([[ -f $A/state/service-error.log.1 ]] && echo 1 || echo 0)"
expect_eq "...and the new one is empty or absent" 0 "$(stat -c %s "$A/state/service-error.log" 2>/dev/null || echo 0)"

section "A6. install scripts"
out=$(bash "$ROOT/install/install.sh" --bogus 2>&1); rc=$?
if (( rc != 0 )); then pass "install.sh rejects an unknown option"; else fail "install.sh --bogus" "$out"; fi
expect_has "install.sh shows usage" "Usage" "$out"

# =============================================================================
# Part B — a real systemd user manager
# =============================================================================
section "B0. real systemd user manager"
if ! um_detect; then
    echo "  SKIP  Part B: $UM_WHY"
    SKIPPED=1
else
    echo "  mode: $UM_MODE"
    if ! um_setup "$SANDBOX"; then
        fail "start a systemd user manager ($UM_MODE)" "$(tail -n 5 "$UM_LOG" 2>/dev/null)"
        SKIPPED=1
    else
        pass "a real 'systemd --user' manager is running ($UM_MODE mode, systemd $(um_ctl --version | head -n1))"
    fi
fi

if (( SKIPPED == 0 )); then
UNAME=cal-btest
PROJ="$UM_HOME/cal proj"           # a path with a space, on purpose
um_install_project "$PROJ" "$UNAME" "$ROOT" || fail "copy the project"
M()  { um_run "$PROJ/main.sh" "$@"; }
Q()  { um_ctl "$@"; }
SESS="$PROJ/data/sessions.csv"
PROC="$PROJ/data/processes.csv"
ERRLOG="$PROJ/state/service-error.log"
UNITF="$UM_HOME/.config/systemd/user/$UNAME.service"
mainpid() { Q show "$UNAME.service" -p MainPID --value 2>/dev/null; }
lastrow() { tail -n 1 "$SESS" 2>/dev/null; }
wait_for() { local i; for (( i = 0; i < ${2:-100}; i++ )); do if eval "$1"; then return 0; fi; sleep 0.2; done; return 1; }
daemon_up() { um_run test -s "$PROJ/state/daemon.pid" && um_run flock -n "$PROJ/state/daemon.lock" true 2>/dev/null && return 1; um_run test -s "$PROJ/state/daemon.pid"; }
nrows() { local n; n=$(grep -c '' "$SESS" 2>/dev/null || true); echo $(( ${n:-1} - 1 )); }

section "B1. install / enable / start"
out=$(M service status 2>&1); rc=$?
expect_eq "before install: status rc 4 (not installed)" 4 "$rc"
out=$(M service install 2>&1); rc=$?
expect_eq "install without consent is refused" 1 "$rc"
expect_has "...and says why" "consent" "$out"
M consent --accept >/dev/null 2>&1
out=$(M service install 2>&1); rc=$?
expect_eq "install succeeds" 0 "$rc"
expect_eq "unit installed in the user's own config dir" 1 "$([[ -f $UNITF ]] && echo 1 || echo 0)"
expect_eq "unit file mode is not world-writable" 0 "$(( 0$(stat -c %a "$UNITF") & 0002 ))"
out=$(M service enable 2>&1); rc=$?
expect_eq "enable succeeds" 0 "$rc"
expect_eq "enabled => symlink in default.target.wants" 1 "$([[ -L $UM_HOME/.config/systemd/user/default.target.wants/$UNAME.service ]] && echo 1 || echo 0)"
expect_eq "is-enabled says enabled" enabled "$(Q is-enabled "$UNAME.service" 2>&1)"
out=$(M service status 2>&1); rc=$?
expect_eq "installed but stopped: status rc 3" 3 "$rc"
out=$(M service start 2>&1); rc=$?
expect_eq "start succeeds" 0 "$rc"
expect_has "start reports the session" "session " "$out"
expect_eq "unit is active" active "$(Q is-active "$UNAME.service")"
expect_eq "Type=notify reached READY" "session" "$(Q show "$UNAME.service" -p StatusText --value | cut -d' ' -f1)"
pid=$(mainpid)
expect_eq "main process runs as the unprivileged user (not root)" "$UM_USER" "$(ps -o user= -p "$pid" | tr -d ' ')"
expect_eq "NoNewPrivs is set" 1 "$(awk '/^NoNewPrivs/ {print $2}' "/proc/$pid/status")"
expect_eq "umask 077 => state files are 600" 600 "$(stat -c %a "$PROJ/state/daemon.pid")"
expect_eq "session row is ACTIVE" ACTIVE "$(lastrow | awk -F, '{print $NF}')"
expect_eq "visible: listed by systemctl --user" 1 "$(Q list-units --type=service --no-legend | grep -c "$UNAME.service")"
out=$(M service status 2>&1); rc=$?
expect_eq "running: status rc 0" 0 "$rc"
expect_has "status: state active" "active (running)" "$out"
expect_has "status: enabled" "enabled" "$out"
expect_has "status: logger running" "Logger      : RUNNING" "$out"
expect_has "status: login-vs-boot" "Machine boot" "$out"
expect_has "status: starts at login, not boot" "Starts at" "$out"
expect_has "status: error log path" "service-error.log" "$out"
expect_eq "exactly one daemon process" 1 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"

section "B2. single instance"
n0=$(nrows)
out=$(M service start 2>&1); rc=$?
expect_eq "service start while running: rc 0, 'Already running'" 0 "$rc"
expect_has "...says so" "Already running" "$out"
out=$(M start 2>&1); rc=$?
if (( rc == 0 )) && [[ $out == *[Aa]lready* ]] || (( rc != 0 )); then pass "./main.sh start while the service runs does not start a second one"; else fail "main.sh start duplicate" "rc=$rc $out"; fi
out=$(M daemon 2>&1); rc=$?
expect_eq "a direct 'main.sh daemon' is turned away with exit 3" 3 "$rc"
expect_eq "still the same main pid" "$pid" "$(mainpid)"
expect_eq "no extra session was created" "$n0" "$(nrows)"
expect_eq "still exactly one daemon" 1 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"

section "B3. it really records, and the safe stop saves everything"
um_run bash -c 'cp /bin/sleep "$HOME/caltool_marker" && "$HOME/caltool_marker" 300' >/dev/null 2>&1 &
wait_for "grep -q 'caltool_marker' '$PROJ/state/active.tsv' 2>/dev/null" 40
expect_eq "the monitor sees a new process" 1 "$(grep -c caltool_marker "$PROJ/state/active.tsv" 2>/dev/null | head -n1)"
sid=$(lastrow | cut -d, -f1)
t0=$(date +%s.%N)
out=$(M service stop 2>&1); rc=$?
t1=$(date +%s.%N)
expect_eq "stop succeeds" 0 "$rc"
if awk -v a="$t0" -v b="$t1" 'BEGIN{exit !(b-a < 5)}'; then pass "stop finished in < 5 s (not a SIGKILL timeout)"; else fail "stop was slow" "$t0 -> $t1"; fi
expect_eq "unit inactive" inactive "$(Q is-active "$UNAME.service" 2>&1)"
expect_eq "result success (clean exit, not killed)" success "$(Q show "$UNAME.service" -p Result --value)"
expect_eq "session closed as COMPLETED" COMPLETED "$(grep "^$sid," "$SESS" | awk -F, '{print $NF}')"
expect_eq "tracked process saved with SESSION_END" 1 "$(grep caltool_marker "$PROC" | grep -c SESSION_END)"
expect_eq "active.tsv cleared" 0 "$(um_run bash -c "[[ -s '$PROJ/state/active.tsv' ]] && echo 1 || echo 0")"
expect_eq "no logger left" 0 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
expect_eq "lock is free" 1 "$(um_run flock -n "$PROJ/state/daemon.lock" true && echo 1 || echo 0)"
out=$(M sessions --check 2>&1); expect_eq "sessions.csv is valid" 0 "$?"
out=$(M processes --check 2>&1); expect_eq "processes.csv is valid" 0 "$?"
um_run pkill -x caltool_marker 2>/dev/null || true
out=$(M service stop 2>&1); rc=$?
expect_eq "stopping a stopped service is a harmless rc 0" 0 "$rc"
expect_eq "stopped: status rc 3" 3 "$(M service status >/dev/null 2>&1; echo $?)"

section "B4. restart"
M service start >/dev/null 2>&1
s1=$(lastrow | cut -d, -f1); p1=$(mainpid); n1=$(nrows)
out=$(M service restart 2>&1); rc=$?
expect_eq "restart succeeds" 0 "$rc"
expect_has "restart says a new session begins" "NEW session" "$out"
s2=$(lastrow | cut -d, -f1); p2=$(mainpid)
if [[ $p1 != "$p2" && -n $p2 ]]; then pass "new main process after restart"; else fail "restart pid" "$p1 -> $p2"; fi
if [[ $s1 != "$s2" ]]; then pass "new session after restart"; else fail "restart session" "$s1 == $s2"; fi
expect_eq "old session closed COMPLETED" COMPLETED "$(grep "^$s1," "$SESS" | awk -F, '{print $NF}')"
expect_eq "new session ACTIVE" ACTIVE "$(grep "^$s2," "$SESS" | awk -F, '{print $NF}')"
expect_eq "exactly one new row" "$(( n1 + 1 ))" "$(nrows)"
expect_eq "exactly one daemon" 1 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
out=$(M service restart 2>&1)
M service stop >/dev/null 2>&1
out=$(M service restart 2>&1); rc=$?
expect_eq "restart of a stopped service starts it" 0 "$rc"
expect_has "...and says so" "has been started" "$out"

section "B5. healthy watchdog does not cause restarts"
wd=$(Q show "$UNAME.service" -p WatchdogUSec --value)
expect_has "watchdog configured" "s" "$wd"
p=$(mainpid)
sleep 6
expect_eq "no restarts while healthy" 0 "$(Q show "$UNAME.service" -p NRestarts --value)"
expect_eq "same main pid" "$p" "$(mainpid)"

section "B6. kill -9 => systemd restarts it, recovery repairs the session"
p=$(mainpid); sk=$(lastrow | cut -d, -f1)
kill -KILL "$p"
wait_for "[[ \$(mainpid) != '$p' && \$(Q is-active $UNAME.service) == active ]]" 100
np=$(mainpid)
if [[ $np != "$p" && -n $np && $np != 0 ]]; then pass "restarted automatically with a new pid"; else fail "no auto-restart" "old=$p new=$np state=$(Q is-active "$UNAME.service")"; fi
expect_eq "the killed session is marked as crashed" 1 "$(grep "^$sk," "$SESS" | grep -c -E 'CRASHED|RECOVERED|INTERRUPTED')"
expect_eq "a fresh ACTIVE session exists" ACTIVE "$(lastrow | awk -F, '{print $NF}')"
expect_eq "exactly one daemon after the crash" 1 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
expect_eq "restart counter is 1 (or reset by the new run)" 1 "$([[ $(Q show "$UNAME.service" -p NRestarts --value) -le 1 ]] && echo 1 || echo 0)"

section "B7. a hung monitor is killed and restarted by the watchdog"
mkdir -p "$UM_HOME/.config/systemd/user/$UNAME.service.d"
printf '[Service]\nWatchdogSec=3\nRestartSec=1\nTimeoutAbortSec=3\n' >"$UM_HOME/.config/systemd/user/$UNAME.service.d/test.conf"
[[ $UM_MODE == private ]] && chown -R "$UM_USER" "$UM_HOME/.config"
Q daemon-reload
M service restart >/dev/null 2>&1
p=$(mainpid)
kill -STOP "$p"
wait_for "[[ \$(mainpid) != '$p' && \$(Q is-active $UNAME.service) == active ]]" 100
np=$(mainpid)
if [[ $np != "$p" && -n $np && $np != 0 ]]; then pass "SIGSTOPped (hung) logger replaced by the watchdog"; else fail "watchdog did not restart" "old=$p new=$np"; fi
expect_eq "systemd counted it as a restart" 1 "$([[ $(Q show "$UNAME.service" -p NRestarts --value) -ge 1 ]] && echo 1 || echo 0)"
rm -rf -- "$UM_HOME/.config/systemd/user/$UNAME.service.d"
Q daemon-reload
M service restart >/dev/null 2>&1

section "B8. restart storm is stopped by the start limit, and 'service start' recovers"
mkdir -p "$UM_HOME/.config/systemd/user/$UNAME.service.d"
printf '[Service]\nRestartSec=1\n' >"$UM_HOME/.config/systemd/user/$UNAME.service.d/test.conf"
[[ $UM_MODE == private ]] && chown -R "$UM_USER" "$UM_HOME/.config"
Q daemon-reload
for (( i = 0; i < 8; i++ )); do
    p=$(mainpid)
    if [[ $(Q is-active "$UNAME.service") == failed ]]; then break; fi
    [[ -n $p && $p != 0 ]] && kill -KILL "$p" 2>/dev/null
    sleep 2
done
wait_for "[[ \$(Q is-active $UNAME.service) == failed ]]" 40
expect_eq "after 5 quick failures the unit stays failed (no endless flapping)" failed "$(Q is-active "$UNAME.service")"
out=$(M service status 2>&1); rc=$?
expect_eq "status of a failed unit: rc 3" 3 "$rc"
expect_has "status shows the failure" "failed" "$out"
rm -rf -- "$UM_HOME/.config/systemd/user/$UNAME.service.d"
Q daemon-reload
out=$(M service start 2>&1); rc=$?
expect_eq "'service start' clears the start limit and starts" 0 "$rc"
expect_eq "active again" active "$(Q is-active "$UNAME.service")"

section "B9. conflict with a hand-started logger"
M service stop >/dev/null 2>&1
out=$(M start 2>&1); rc=$?
expect_eq "manual ./main.sh start works" 0 "$rc"
mp=$(um_run cat "$PROJ/state/daemon.pid")
out=$(M service start 2>&1); rc=$?
expect_eq "service start refuses while a manual logger runs" 1 "$rc"
expect_has "...and explains" "outside the service" "$out"
expect_eq "the manual logger is untouched" "$mp" "$(um_run cat "$PROJ/state/daemon.pid")"
# systemd itself (not our CLI) starts the unit anyway, e.g. at login: the daemon must turn it away
: >"$ERRLOG"
Q start "$UNAME.service" >/dev/null 2>&1; rc=$?
if (( rc != 0 )); then pass "systemctl start fails honestly (Type=notify never reached READY)"; else fail "systemctl start should fail" "rc=0"; fi
sleep 1
expect_eq "the unit is not left running/restarting" 0 "$([[ $(Q is-active "$UNAME.service") == active || $(Q is-active "$UNAME.service") == activating ]] && echo 1 || echo 0)"
expect_eq "NOT retried: exit status 3 is final (NRestarts 0)" 0 "$(Q show "$UNAME.service" -p NRestarts --value)"
expect_has "the dedicated error log says why" "already running" "$(cat "$ERRLOG" 2>/dev/null)"
expect_eq "manual logger still the single instance" "$mp" "$(um_run cat "$PROJ/state/daemon.pid")"
expect_eq "exactly one daemon" 1 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
M stop >/dev/null 2>&1
expect_eq "manual stop works" 0 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
Q reset-failed "$UNAME.service" 2>/dev/null

section "B10. consent"
M consent --revoke >/dev/null 2>&1
out=$(M service start 2>&1); rc=$?
expect_eq "service start refuses without consent" 1 "$rc"
expect_has "...and says so" "consent" "$out"
Q start "$UNAME.service" >/dev/null 2>&1
expect_eq "systemd itself skips the unit (ConditionPathExists)" inactive "$(Q is-active "$UNAME.service")"
expect_eq "nothing is logging" 0 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
out=$(M daemon 2>&1); rc=$?
expect_eq "daemon without consent exits 4" 4 "$rc"
M consent --accept >/dev/null 2>&1

section "B11. error log and 'service logs'"
expect_eq "the error log exists" 1 "$([[ -f $ERRLOG ]] && echo 1 || echo 0)"
expect_eq "error log is private (600)" 600 "$(stat -c %a "$ERRLOG")"
out=$(M service logs 5 2>&1); rc=$?
expect_eq "service logs works" 0 "$rc"
expect_has "service logs shows the file" "service-error.log" "$out"
expect_has "service logs shows the journal section" "journal" "$out"

section "B12. login / logout emulation (the user manager restarts)"
M service stop >/dev/null 2>&1
M service enable >/dev/null 2>&1
um_stop_manager
expect_eq "logout: no logger left" 0 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
um_start_manager; rc=$?
expect_eq "login: user manager is back" 0 "$rc"
wait_for "[[ \$(Q is-active $UNAME.service) == active ]]" 100
expect_eq "ENABLED: starts by itself at login, nothing typed" active "$(Q is-active "$UNAME.service")"
expect_eq "exactly one daemon" 1 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
sl=$(lastrow | cut -d, -f1)
um_stop_manager
expect_eq "logout stops the service safely: session COMPLETED" COMPLETED "$(grep "^$sl," "$SESS" | awk -F, '{print $NF}')"
um_start_manager
sleep 1
M service stop >/dev/null 2>&1
M service disable >/dev/null 2>&1
um_stop_manager
um_start_manager
sleep 3
expect_eq "DISABLED: does not start at login" inactive "$(Q is-active "$UNAME.service")"
expect_eq "nothing is logging" 0 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"

section "B13. uninstall"
M service enable >/dev/null 2>&1
M service start >/dev/null 2>&1
sr=$(grep -c '' "$SESS")
out=$(M service uninstall 2>&1); rc=$?
expect_eq "uninstall succeeds" 0 "$rc"
expect_eq "service stopped" 0 "$(pgrep -f -c -- "$PROJ/main.sh daemon" || true)"
expect_eq "unit file removed" 0 "$([[ -e $UNITF ]] && echo 1 || echo 0)"
expect_eq "enable symlink removed" 0 "$([[ -L $UM_HOME/.config/systemd/user/default.target.wants/$UNAME.service ]] && echo 1 || echo 0)"
expect_eq "data kept (no row lost)" 1 "$([[ $(grep -c '' "$SESS") -ge $sr ]] && echo 1 || echo 0)"
expect_eq "last session was closed properly" COMPLETED "$(lastrow | awk -F, '{print $NF}')"
M service status >/dev/null 2>&1; expect_eq "status after uninstall: rc 4" 4 "$?"
fi

# =============================================================================
printf '\n%d checks, %d failed' "$TOTAL" "$FAILS"
if (( SKIPPED )); then printf ' (Part B skipped: no systemd user manager)'; fi
printf '\n'
exit $(( FAILS > 0 ))
