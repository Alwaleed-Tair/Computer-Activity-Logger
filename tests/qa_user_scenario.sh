#!/usr/bin/env bash
# =============================================================================
# tests/qa_user_scenario.sh — independent QA, end-user point of view
# -----------------------------------------------------------------------------
# Follows the README like a new user would, on a throw-away Linux user with a real
# `systemd --user` manager (tests/usermgr.sh), DEFAULT settings (INTERVAL_SEC=5, no
# config.local.sh), the project cloned from GitHub, real GUI programs on a virtual
# display (Xvfb). It only OBSERVES and records; verdicts are in QA_REPORT.md.
#   usage: bash tests/qa_user_scenario.sh OUTDIR       (artifacts: events.tsv, qa.log, copies of CSV/reports)
# Substitutions (not installed here): Firefox -> Google Chrome for Testing; VS Code -> NOT TESTED.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT=${1:?usage: qa_user_scenario.sh OUTDIR}
mkdir -p "$OUT"; OUT=$(cd "$OUT" && pwd -P)
EV="$OUT/events.tsv"; : >"$EV"
LOGF="$OUT/qa.log"; : >"$LOGF"
exec > >(tee -a "$LOGF") 2>&1

# shellcheck source=/dev/null
source "$ROOT/tests/usermgr.sh"
cleanup() { um_run pkill -KILL -u "$UM_USER" 2>/dev/null; um_cleanup; }
trap cleanup EXIT

ev()  { printf '%s\t%s\n' "$1" "$(date +%s)" >>"$EV"; printf '[%s] EVENT %s\n' "$(date +%T)" "$1"; }
say() { printf '\n[%s] %s\n' "$(date +%T)" "$*"; }
nproc_daemon() { pgrep -f -c -- "^(/usr/bin/)?bash .*/main\\.sh daemon\$" || true; }

um_detect || { echo "no user manager possible: $UM_WHY"; exit 2; }
um_setup "$OUT" || { echo "cannot start the user manager"; tail -n 5 "$UM_LOG"; exit 2; }
echo "mode=$UM_MODE user=$UM_USER uid=$UM_UID home=$UM_HOME"
U()  { um_run "$@"; }
P="$UM_HOME/Computer-Activity-Logger"
M()  { um_run "$P/main.sh" "$@"; }
SESS="$P/data/sessions.csv"; PROC="$P/data/processes.csv"

say "1. INSTALL — clone from GitHub exactly as the README says (as root: the sandbox proxy is not passed to the user), then hand it to the user"
git clone -q https://github.com/Alwaleed-Tair/Computer-Activity-Logger.git "$P" || { echo "clone failed"; exit 2; }
chown -R "$UM_USER" "$P"
git -C "$P" log --oneline | head -1
M doctor; echo "doctor rc=$?"

say "2. AUTOSTART SETUP — consent, install.sh --accept (README: install/install.sh)"
ev install_begin
U "$P/install/install.sh" --accept; echo "install.sh rc=$?"
ev install_end
M service status; echo "status rc=$?"
echo "--- enabled symlink:"; ls -l "$UM_HOME/.config/systemd/user/default.target.wants/" 2>&1 | tail -n 2

say "3. LOGOUT then LOGIN (user manager stops / starts, as logind does)"
sleep 8
ev logout
um_stop_manager
echo "logger processes after logout: $(nproc_daemon)"
sleep 3
ev login
um_start_manager
for ((i = 0; i < 60; i++)); do [[ $(um_ctl is-active cal.service 2>/dev/null) == active ]] && break; sleep 0.5; done
ev autostart_seen_active
echo "service after login (nothing typed): $(um_ctl is-active cal.service)   loggers: $(nproc_daemon)"
echo "--- sessions.csv after logout+login:"; cat "$SESS"

say "4. GUI programs on a virtual display"
U bash -c 'setsid nohup Xvfb :99 -screen 0 1280x800x24 >/dev/null 2>&1 &'
sleep 2
echo "Xvfb running: $(U pgrep -c Xvfb)"
launch() {   # launch LABEL CMD... -> pid in $LPID
    local label=$1; shift
    LPID=$(U env DISPLAY=:99 bash -c 'setsid nohup "$@" >/dev/null 2>&1 & echo $!' _ "$@")
    ev "start_$label"; echo "  $label pid=$LPID"
}
sleep 7
launch chrome google-chrome --no-sandbox --no-first-run --disable-gpu --user-data-dir="$UM_HOME/chrome-prof" about:blank;  CH=$LPID
sleep 5
launch xterm_short xterm -e sleep 45;                                                                                    XS=$LPID
sleep 3
launch xterm_long xterm -e sleep 600;                                                                                    XL=$LPID
echo "  (VS Code: not installed here -> NOT TESTED; Firefox: not installed -> Chrome used instead)"
sleep 20
say "5. MID-SESSION SNAPSHOT (apps still open)"
M processes --running | head -n 12
echo "total tracked now: $(M processes --running | tail -n +2 | wc -l)"
DP=$(U cat "$P/state/daemon.pid")
echo "--- daemon cost with Chrome running (30 s, default INTERVAL_SEC=5):"
tck=$(getconf CLK_TCK); a=$(awk '{print $14+$15+$16+$17}' /proc/$DP/stat); t0=$(date +%s.%N); sleep 30
b=$(awk '{print $14+$15+$16+$17}' /proc/$DP/stat); t1=$(date +%s.%N)
awk -v a=$a -v b=$b -v t0=$t0 -v t1=$t1 -v tck=$tck 'BEGIN{printf "  CPU %.2f %%\n",(b-a)/tck/(t1-t0)*100}'
echo "  RSS $(awk '/VmRSS/{print $2}' /proc/$DP/status) KB, user processes now: $(U ps -u "$UM_USER" --no-headers | wc -l)"
sleep 10
say "6. CLOSE SOME, LEAVE OTHERS"
ev kill_chrome; U kill -TERM "$CH"
sleep 12
echo "xterm_short should have exited by itself: alive=$(U kill -0 "$XS" 2>/dev/null && echo yes || echo no)"
ev xterm_short_gone_seen
sleep 10
echo "tracked before stop:"; M processes --running | grep -c .

say "7. STOP THE SESSION (README: ./main.sh service stop)"
ev stop_begin
M service stop; echo "stop rc=$?"
ev stop_end
echo "loggers left: $(nproc_daemon)"
sleep 1
M sessions
echo "--- processes.csv (apps only):"; M processes --tail 400 | grep -i -E "chrome|xterm|sleep" | head -n 20

say "8. REPORTS"
M report period --name qa; echo "report rc=$?"
M report daily; echo "daily rc=$?"
M report verify; echo "verify rc=$?"
M report list
echo "--- stats:"; M stats --top 8 | head -n 60

say "9. SAVE ARTIFACTS"
cp "$SESS" "$PROC" "$P/data/process_details.csv" "$OUT/" 2>/dev/null
cp -r "$P/reports" "$OUT/reports" 2>/dev/null
cp "$P/state/cal.log" "$OUT/cal.log" 2>/dev/null; cp "$P/state/service-error.log" "$OUT/service-error.log" 2>/dev/null
echo "saved to $OUT"

say "10. MACHINE POWER-CUT EMULATION — start, run an app, SIGKILL everything of the user at once, 'boot' with another boot id, login"
M service start >/dev/null; sleep 3
launch xterm_precrash xterm -e sleep 600; XP=$LPID
sleep 12
ev power_cut
um_kill_user_processes; sleep 2
echo "boot-b-2222" >"$UM_HOME/boot.id"; chown "$UM_USER" "$UM_HOME/boot.id"
printf 'export CAL_BOOT_ID_FILE=%s\n' "$UM_HOME/boot.id" >>"$P/config.local.sh"; chmod 600 "$P/config.local.sh"; chown "$UM_USER" "$P/config.local.sh"
ev machine_back
um_start_manager
for ((i = 0; i < 60; i++)); do [[ $(um_ctl is-active cal.service 2>/dev/null) == active ]] && break; sleep 0.5; done
echo "service after 'reboot' (nothing typed): $(um_ctl is-active cal.service)"
sleep 6
cat "$SESS" | cut -d, -f1,5,7,9 | tail -n 4
grep xterm "$PROC" | tail -n 2

say "11. RELIABILITY — kill -9 the logger three times, then log out/in once more"
for n in 1 2 3; do
    p=$(U cat "$P/state/daemon.pid"); U kill -KILL "$p"; sleep 9
    echo "  kill #$n: service=$(um_ctl is-active cal.service) new_pid=$(U cat "$P/state/daemon.pid")"
done
um_stop_manager; um_start_manager
for ((i = 0; i < 60; i++)); do [[ $(um_ctl is-active cal.service 2>/dev/null) == active ]] && break; sleep 0.5; done
sleep 4
M service stop >/dev/null
M sessions
echo "--- checks:"; M sessions --check; M processes --check
cp "$SESS" "$OUT/sessions_final.csv"; cp "$PROC" "$OUT/processes_final.csv"; cp "$P/data/process_details.csv" "$OUT/details_final.csv"
echo "DONE"
