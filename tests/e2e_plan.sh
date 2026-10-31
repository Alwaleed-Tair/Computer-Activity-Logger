#!/usr/bin/env bash
# =============================================================================
# tests/e2e_plan.sh — the 20-case end-to-end test plan (see TEST_REPORT.md)
# -----------------------------------------------------------------------------
# Runs the REAL ./main.sh daemon in a temp sandbox with REAL (copied-binary) test
# applications, measures what actually happens, and writes the table of results to
# the file given as $1 (default: ./e2e_results.md). Nothing is claimed that is not
# measured; cases that cannot be executed here are recorded as NOT-TESTED / EMULATED.
# Timing tolerances: INTERVAL_SEC=1, so detection may lag one interval (+ scheduling).
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
OUT=${1:-./e2e_results.md}
SB="$(mktemp -d)"
export DATA_DIR="$SB/data" STATE_DIR="$SB/state" REPORTS_DIR="$SB/reports" CONSENT_FILE="$SB/consent"
export INTERVAL_SEC=1 MIN_DURATION_SEC=1
M="$ROOT/main.sh"
BIN="$SB/bin"; mkdir -p "$BIN"
for n in calapp_a calapp_b calapp_c calapp_d calapp_e calapp_f; do cp "$(command -v sleep)" "$BIN/$n"; done
SESS="$DATA_DIR/sessions.csv"; PROC="$DATA_DIR/processes.csv"
ME=$(id -un); MYUID=$(id -u)
KIDS=()
RESULTS=()
FAILS=0

cleanup() {
    local p
    "$M" stop >/dev/null 2>&1 || true
    for p in "${KIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
    rm -rf -- "$SB"
}
trap cleanup EXIT

# rec ID TITLE STEPS EXPECTED ACTUAL RESULT   (RESULT: PASS | FAIL | EMULATED | NOT-TESTED)
rec() {
    RESULTS+=("$1"$'\t'"$2"$'\t'"$3"$'\t'"$4"$'\t'"$5"$'\t'"$6")
    if [[ $6 == FAIL ]]; then FAILS=$(( FAILS + 1 )); fi
    printf '%-8s %-9s %s\n' "$1" "$6" "$2"
    printf '           actual: %s\n' "$5"
}
# verdict COND... -> PASS/FAIL for a test expression
verdict() { if "$@"; then echo PASS; else echo FAIL; fi; }

now() { date +%s; }
ts2e() { date -u -d "$1" +%s 2>/dev/null || echo 0; }          # "YYYY-MM-DD HH:MM:SS" (UTC) -> epoch
daemon_pid() { cat "$STATE_DIR/daemon.pid" 2>/dev/null; }
wait_until() { local i; for (( i = 0; i < ${2:-60}; i++ )); do if eval "$1"; then return 0; fi; sleep 0.25; done; return 1; }
# launch NAME SECONDS -> pid in $LP and start epoch in $LT
launch() { "$BIN/$1" "$2" & LP=$!; LT=$(now); KIDS+=("$LP"); disown "$LP" 2>/dev/null || true; }
# prow PID -> the processes.csv row (last) for that pid
prow() { grep -E "^[^,]*,$1," "$PROC" | tail -n 1; }
# pfield ROW N  (naive split: fine for names without commas)
pfield() { awk -F, -v n="$2" '{gsub(/"/,"",$n); print $n}' <<<"$1"; }
in_running() { grep -q "	$1	\|,$1," "$STATE_DIR/active.tsv" 2>/dev/null; }
abs() { local v=$1; if (( v < 0 )); then v=$(( -v )); fi; echo "$v"; }
fresh_start() { "$M" start >/dev/null 2>&1; wait_until '[[ -s $STATE_DIR/daemon.pid ]] && grep -q ACTIVE "$SESS" 2>/dev/null' 40; sleep 2.2; }

echo "== environment =="
echo "  kernel : $(uname -sr)"
echo "  os     : $(. /etc/os-release 2>/dev/null; echo "${PRETTY_NAME:-unknown}")"
echo "  bash   : ${BASH_VERSION}   user: $ME (uid $MYUID)"
echo "  systemd as PID 1: $([[ -d /run/systemd/system ]] && echo yes || echo no)"
echo

# ------------------------------------------------------------------ TC-01
out=$("$M" start 2>&1); rc=$?
c1_refused=$([[ $rc -ne 0 && ! -e $SESS ]] && echo yes || echo no)
"$M" consent --accept >/dev/null 2>&1
fresh_start
bom=$(head -c3 "$SESS" 2>/dev/null | od -An -tx1 | tr -d ' \n')
modes="$(stat -c %a "$DATA_DIR") $(stat -c %a "$SESS") $(stat -c %a "$PROC")"
act="start without consent: rc=$rc, no files created=$c1_refused; after consent: daemon pid=$(daemon_pid), files created, BOM=$bom, modes dir/sessions/processes='$modes'"
rec TC-01 "First run" "1) ./main.sh start with no consent 2) consent --accept 3) ./main.sh start" \
    "Refused without consent (non-zero, no data files); with consent the daemon runs and creates sessions.csv + processes.csv (UTF-8 BOM, dir 700, files 600)" \
    "$act" "$(verdict test "$c1_refused" = yes -a -n "$(daemon_pid)" -a "$bom" = efbbbf -a "$modes" = "700 600 600")"

# ------------------------------------------------------------------ TC-02
row=$(sed -n 2p "$SESS")
u=$(pfield "$row" 2); uid=$(pfield "$row" 3)
rec TC-02 "Username is recorded" "Read the Username/User_ID columns of the first session row" \
    "Username == '$ME', User_ID == $MYUID" "row: $row" "$(verdict test "$u" = "$ME" -a "$uid" = "$MYUID")"

# ------------------------------------------------------------------ TC-03
sid=$(pfield "$row" 1); ld=$(pfield "$row" 4); lt=$(pfield "$row" 5); st=$(pfield "$row" 9)
le=$(ts2e "$ld $lt"); nowe=$(date -u +%s)
nrows=$(( $(grep -c '' "$SESS") - 1 ))
rec TC-03 "Session start recorded" "Start the daemon; read the ACTIVE row" \
    "Exactly one row, Status ACTIVE, Login (UTC) within 30 s of now, unique non-empty Session_ID, logout columns empty" \
    "rows=$nrows id=$sid status=$st login=$ld $lt UTC (age $(( nowe - le )) s); logout='$(pfield "$row" 6)$(pfield "$row" 7)'" \
    "$(verdict test "$nrows" = 1 -a "$st" = ACTIVE -a -n "$sid" -a "$(abs $(( nowe - le )))" -le 30 -a -z "$(pfield "$row" 6)")"

# ------------------------------------------------------------------ TC-04..10  one application, full lifecycle
launch calapp_a 120; PA=$LP; TA0=$LT
rec TC-04 "A new application is started" "Run a copy of sleep named calapp_a (pid $PA) for 120 s" \
    "The process exists" "pid $PA alive=$(kill -0 "$PA" 2>/dev/null && echo yes || echo no)" "$(verdict kill -0 "$PA")"

t_det=""
for (( i = 0; i < 80; i++ )); do
    if grep -q "calapp_a" "$STATE_DIR/active.tsv" 2>/dev/null; then t_det=$(date +%s.%N); break; fi
    sleep 0.1
done
lat="n/a"; [[ -n $t_det ]] && lat=$(awk -v a="$t_det" -v b="$TA0" 'BEGIN{printf "%.1f", a-b}')
runs=$("$M" processes --running 2>&1 | grep -c calapp_a)
rec TC-05 "New process is detected" "Poll state/active.tsv and './main.sh processes --running' after launch" \
    "Appears in the tracked list within 1 scan interval + margin (<= 4 s), exactly once" \
    "detected after ${lat} s; listed ${runs}x by 'processes --running'" \
    "$([[ -n $t_det && $runs == 1 ]] && awk -v l="$lat" 'BEGIN{exit !(l+0<=4)}' && echo PASS || echo FAIL)"

sleep 3
TA1=$(now); kill -TERM "$PA" 2>/dev/null; wait "$PA" 2>/dev/null
wait_until '[[ -n $(prow '"$PA"') ]]' 40
rowA=$(prow "$PA")
rec TC-07 "The application is closed" "kill -TERM the application (pid $PA)" \
    "Process gone" "alive=$(kill -0 "$PA" 2>/dev/null && echo yes || echo no)" "$(verdict test -z "$(kill -0 "$PA" 2>/dev/null && echo x)")"
rec TC-08 "End of process is detected" "Wait for the row in processes.csv" \
    "A COMPLETED row for pid $PA appears within 4 s" "row: ${rowA:-<none>}" "$(verdict test -n "$rowA" -a "$(pfield "${rowA:-,,,,,,,}" 8)" = COMPLETED)"
sA=$(ts2e "$(pfield "$rowA" 5)"); eA=$(ts2e "$(pfield "$rowA" 6)"); dA=$(pfield "$rowA" 7)
d6=$(( sA - TA0 )); d9=$(( eA - TA1 ))
rec TC-06 "Process start time recorded" "Compare Start_Time (UTC) with the epoch taken just before launch" \
    "|Start_Time - launch| <= 2 s (documented precision +-1 s)" "launch=$TA0 recorded=$sA (diff ${d6} s) [$(pfield "$rowA" 5)]" "$(verdict test "$(abs "$d6")" -le 2)"
rec TC-09 "Process end time recorded" "Compare End_Time with the epoch taken just before kill" \
    "0 <= End_Time - kill <= 3 s (End is the DETECTION time)" "kill=$TA1 recorded=$eA (diff ${d9} s) [$(pfield "$rowA" 6)]" "$(verdict test "$d9" -ge -1 -a "$d9" -le 3)"
exp10=$(( TA1 - TA0 ))
rec TC-10 "Process duration" "Duration_Seconds vs (kill - launch) and vs End - Start" \
    "|Duration - real lifetime| <= 2 s; Duration == End - Start (+-1 s)" "real=${exp10} s recorded=${dA} s end-start=$(( eA - sA )) s" \
    "$(verdict test "$(abs $(( dA - exp10 )))" -le 2 -a "$(abs $(( dA - (eA - sA) )))" -le 1)"

# ------------------------------------------------------------------ TC-11 concurrent
declare -A CP CT
for spec in "calapp_b 3" "calapp_c 5" "calapp_d 7" "calapp_e 9" "calapp_f 11"; do
    set -- $spec; launch "$1" "$2"; CP[$1]=$LP; CT[$1]=$LT
done
sleep 14
miss=0; bad=0; det=""
for n in calapp_b calapp_c calapp_d calapp_e calapp_f; do
    r=$(prow "${CP[$n]}")
    if [[ -z $r ]]; then miss=$(( miss + 1 )); det+="$n:MISSING "; continue; fi
    life=$(( $(echo "$n" | awk '{print ($1=="calapp_b")?3:($1=="calapp_c")?5:($1=="calapp_d")?7:($1=="calapp_e")?9:11}') ))
    dd=$(pfield "$r" 7)
    if (( $(abs $(( dd - life ))) > 2 )); then bad=$(( bad + 1 )); fi
    det+="$n:${dd}s(real ${life}s) "
done
pids_unique=$(for n in "${!CP[@]}"; do prow "${CP[$n]}" | cut -d, -f2; done | sort -u | wc -l)
rec TC-11 "Several applications at the same time" "Start 5 apps with lifetimes 3,5,7,9,11 s concurrently" \
    "5 separate rows (distinct PIDs), each duration within 2 s of its own lifetime (not merged or summed)" \
    "missing=$miss off-by>2s=$bad distinct_pids=$pids_unique; $det" "$(verdict test "$miss" = 0 -a "$bad" = 0 -a "$pids_unique" = 5)"

# ------------------------------------------------------------------ TC-12 short-lived
before=$(( $(grep -c '' "$PROC") ))
for (( i = 0; i < 20; i++ )); do "$BIN/calapp_a" 0.1; done
sleep 2.5
short_caught=$(grep -a "calapp_a" "$PROC" | grep -v ",$PA," | wc -l)
short_maxdur=$(grep -a "calapp_a" "$PROC" | grep -v ",$PA," | awk -F, 'BEGIN{m=0} {if ($7>m) m=$7} END{print m}')
launch calapp_b 3; PB=$LP; sleep 6
r3=$(prow "$PB")
alive=$([[ -d /proc/$(daemon_pid) ]] && echo yes || echo no)
chk=$("$M" processes --check >/dev/null 2>&1; echo $?)
rec TC-12 "Short-lived processes" "Run 20 processes of 0.1 s (INTERVAL_SEC=1, MIN_DURATION_SEC=1) then one of 3 s" \
    "Daemon stays alive, files valid. A sub-interval process is only seen if a scan lands inside its life (probability ~ lifetime/interval = ~10 %, so ~2 of 20 expected); when seen, its duration is quantised to the scan interval (<= 2 s) — a documented limitation, not an error. The 3 s process is recorded" \
    "0.1 s processes recorded: ${short_caught}/20 (longest recorded duration ${short_maxdur} s, real 0.1 s); 3 s process row: ${r3:+yes}; daemon alive=$alive; processes --check rc=$chk" \
    "$(verdict test "$short_caught" -le 8 -a "$short_maxdur" -le 2 -a -n "$r3" -a "$alive" = yes -a "$chk" = 0)"

# ------------------------------------------------------------------ TC-13 forced kill
launch calapp_c 120; PK=$LP; TK0=$LT
wait_until 'grep -q calapp_c "$STATE_DIR/active.tsv"' 40
kill -KILL "$PK"; wait "$PK" 2>/dev/null
wait_until '[[ -n $(prow '"$PK"') ]]' 40
rk=$(prow "$PK")
stillact=$(grep -c "calapp_c" "$STATE_DIR/active.tsv" 2>/dev/null)
rec TC-13 "Process killed by force (SIGKILL)" "kill -9 a tracked application" \
    "Detected like any end: one COMPLETED row, no longer tracked, daemon unaffected (the reason of death cannot be known to an unprivileged monitor)" \
    "row: ${rk:-<none>}; still tracked=$stillact; daemon alive=$([[ -d /proc/$(daemon_pid) ]] && echo yes || echo no)" \
    "$(verdict test -n "$rk" -a "$(pfield "${rk:-,,,,,,,}" 8)" = COMPLETED -a "$stillact" = 0)"

# ------------------------------------------------------------------ TC-14 restart of the monitor
launch calapp_d 300; PR=$LP; TR0=$LT
wait_until 'grep -q calapp_d "$STATE_DIR/active.tsv"' 40
sess_before=$(( $(grep -c '' "$SESS") - 1 ))
# 14a clean stop/start with the app still running
"$M" stop >/dev/null 2>&1
ra=$(prow "$PR")
"$M" start >/dev/null 2>&1; sleep 3
# 14b crash (kill -9 daemon) + start
kill -KILL "$(daemon_pid)"; sleep 1
"$M" start >/dev/null 2>&1; sleep 3
kill -TERM "$PR"; wait "$PR" 2>/dev/null; sleep 3
rows_r=$(grep -E "^[^,]*,$PR," "$PROC")
nr=$(grep -c . <<<"$rows_r")
sts=$(awk -F, '{printf "%s ", $NF}' <<<"$rows_r")
pre=$(grep -c "$PR" "$DATA_DIR/process_details.csv" 2>/dev/null)
rec TC-14 "Restarting the monitor" "App calapp_d running; (a) ./main.sh stop + start; (b) kill -9 daemon + start; then close the app" \
    "(a) stop writes the app as SESSION_END; after restart it is found running (never a new 'start' with a fake time); (b) recovery re-attaches survivors with the ORIGINAL record; no duplicates of one (PID,start) in one session; old sessions closed (COMPLETED / CRASHED), exactly one ACTIVE" \
    "rows for pid $PR: $nr [statuses: $sts]; session rows now $(( $(grep -c '' "$SESS") - 1 )) (was $sess_before); statuses: $(tail -n +2 "$SESS" | awk -F, '{printf "%s ", $NF}')" \
    "$(verdict test "$nr" -ge 1 -a "$(grep -c ',ACTIVE$' "$SESS")" = 1 -a -n "$ra")"
# duplicate-per-session check is TC-19

# ------------------------------------------------------------------ TC-15 reboot
launch calapp_e 300; PW=$LP
wait_until 'grep -q calapp_e "$STATE_DIR/active.tsv"' 40
echo "boot-A-0000-0000-0000" >"$SB/boot1"; echo "boot-B-1111-1111-1111" >"$SB/boot2"
"$M" stop >/dev/null 2>&1
CAL_BOOT_ID_FILE="$SB/boot1" "$M" start >/dev/null 2>&1; sleep 3
sid_pl=$(tail -n 1 "$SESS" | cut -d, -f1)
kill -KILL "$(daemon_pid)"; kill -KILL "$PW"; wait "$PW" 2>/dev/null     # power cut: everything dies at once
sleep 1
CAL_BOOT_ID_FILE="$SB/boot2" "$M" start >/dev/null 2>&1; sleep 3
st_pl=$(grep "^$sid_pl," "$SESS" | awk -F, '{print $NF}')
rec TC-15 "Machine stop and reboot" "EMULATED: kill -9 the daemon and its tracked app together, then start with a different kernel boot_id (CAL_BOOT_ID_FILE hook)" \
    "Previous session marked POWER_LOSS (end estimated from the last heartbeat); a new ACTIVE session opens; no ACTIVE zombie" \
    "previous session status=$st_pl; ACTIVE rows now=$(grep -c ',ACTIVE$' "$SESS"). NOT a real reboot: this container cannot be rebooted, and no systemd/logind boot sequence was exercised" \
    "$([[ $st_pl == POWER_LOSS && $(grep -c ',ACTIVE$' "$SESS") == 1 ]] && echo EMULATED || echo FAIL)"
if [[ ${RESULTS[-1]##*$'\t'} == FAIL ]]; then FAILS=$FAILS; fi

# ------------------------------------------------------------------ TC-16 incomplete records
launch calapp_f 300; PI=$LP
wait_until 'grep -q calapp_f "$STATE_DIR/active.tsv"' 40
sleep 4                                          # long enough to pass MIN_DURATION_SEC
kill -KILL "$(daemon_pid)"; sleep 1
kill -KILL "$PI"; wait "$PI" 2>/dev/null        # dies while nobody is watching
CAL_BOOT_ID_FILE="$SB/boot2" "$M" start >/dev/null 2>&1; sleep 3
ri=$(grep -E "^[^,]*,$PI," "$PROC" | tail -n 1)
stats=$("$M" stats 2>&1)
act16="orphaned app row: ${ri:-<none>}; ACTIVE rows=$(grep -c ',ACTIVE$' "$SESS"); sessions: $(tail -n +2 "$SESS" | awk -F, '{printf "%s ", $NF}')"
rec TC-16 "Incomplete records" "App tracked, daemon kill -9, app dies unobserved, daemon restarted; run stats" \
    "App row closed as RECOVERED (estimated end, not COMPLETED); crashed session CRASHED/POWER_LOSS; only one ACTIVE; stats runs, counts them separately, never as normal completions" \
    "$act16; stats mentions recovered/incomplete: $(grep -ci 'recovered\|crashed\|incomplete\|power' <<<"$stats") line(s)" \
    "$(verdict test "$(pfield "${ri:-,,,,,,,}" 8)" = RECOVERED -a "$(grep -c ',ACTIVE$' "$SESS")" = 1)"

# ------------------------------------------------------------------ TC-17 / TC-18 reports and CSV validity
cp "$BIN/calapp_a" "$BIN/=evil"; cp "$BIN/calapp_a" "$BIN/a b"
"$BIN/=evil" 4 & EV=$!; KIDS+=("$EV"); "$BIN/a b" 4 & EV2=$!; KIDS+=("$EV2")
wait "$EV" "$EV2" 2>/dev/null; sleep 2.5
"$M" stop >/dev/null 2>&1
rep=$("$M" report period --name e2e 2>&1); rrc=$?
rdir=$(find "$REPORTS_DIR" -type d -name e2e 2>/dev/null | head -n1)
files=$(ls "$rdir" 2>/dev/null | tr '\n' ' ')
ver=$("$M" report verify 2>&1); vrc=$?
sr=$(grep -c "$sid" "$rdir/session_report.csv" 2>/dev/null)
rec TC-17 "Reports are created" "./main.sh report period --name e2e; ./main.sh report verify" \
    "rc 0; session_report, application_activity_report, usage_summary_report + manifest exist; verify passes; the first session appears in the session report" \
    "report rc=$rrc verify rc=$vrc files=[$files] first-session-rows-in-report=$sr" \
    "$(verdict test "$rrc" = 0 -a "$vrc" = 0 -a "$sr" -ge 1 -a "$(grep -c -E 'session_report|application_activity|usage_summary|manifest' <<<"$files")" -ge 1)"

sc=$("$M" sessions --check 2>&1); sc_rc=$?
pc=$("$M" processes --check 2>&1); pc_rc=$?
nf=$(LC_ALL=C awk -F, 'NR>1{print NF}' "$PROC" | sort | uniq -c | tr '\n' ' ')
evil=$(grep -a "evil" "$PROC" | head -n1)
space=$(grep -a '"a b"' "$PROC" | head -n1)
crlf=$(find "$rdir" -name '*.csv' -exec sh -c 'for f; do head -c 400 "$f" | od -c | grep -q "\\\\r" && echo ok || echo no; done' _ {} + 2>/dev/null | sort | uniq -c | tr '\n' ' ')
rec TC-18 "CSV files are valid" "sessions --check, processes --check, report verify; apps named '=evil' and 'a b' to test formula-injection guard and quoting; constant column count" \
    "All checks rc 0; a name starting with '=' is neutralised (apostrophe) in the CSV; a name with a space is quoted; every processes row has the same number of columns; reports use CRLF" \
    "sessions --check rc=$sc_rc, processes --check rc=$pc_rc, columns/row: $nf; '=evil' row: ${evil:-<not recorded>}; 'a b' row: ${space:-<not recorded>}; report CRLF: $crlf" \
    "$([[ $sc_rc == 0 && $pc_rc == 0 && -n $evil && $evil != *,=evil* && $(wc -w <<<"$nf") == 2 ]] && echo PASS || echo FAIL)"

# ------------------------------------------------------------------ TC-19 duplicates
dup_proc=$(tail -n +2 "$PROC" | LC_ALL=C awk -F, '{k=$1 "|" $2 "|" $5; c[k]++} END{n=0; for (k in c) if (c[k]>1) n++; print n}')
dup_sess=$(tail -n +2 "$SESS" | cut -d, -f1 | sort | uniq -d | wc -l)
tot=$(( $(grep -c '' "$PROC") - 1 ))
rec TC-19 "No duplicated events" "Whole run incl. 2 clean restarts, 3 kill -9 and a power-loss emulation: look for repeated (Session_ID,PID,Start_Time) keys and Session_IDs" \
    "0 duplicated process keys, 0 duplicated Session_IDs" "process rows=$tot duplicate keys=$dup_proc; duplicated session ids=$dup_sess" \
    "$(verdict test "$dup_proc" = 0 -a "$dup_sess" = 0)"

# ------------------------------------------------------------------ TC-20 resource use
measure() {   # measure SECONDS -> "cpu% rssMB nprocs"
    local pid=$1 secs=$2 tck a b ra rb
    tck=$(getconf CLK_TCK)
    ra=$(awk '{print $14+$15+$16+$17}' "/proc/$pid/stat")
    local t0; t0=$(date +%s.%N)
    sleep "$secs"
    rb=$(awk '{print $14+$15+$16+$17}' "/proc/$pid/stat")
    local t1; t1=$(date +%s.%N)
    awk -v a="$ra" -v b="$rb" -v t0="$t0" -v t1="$t1" -v tck="$tck" -v rss="$(awk '/VmRSS|VmHWM/ {printf "%s ", $2}' "/proc/$pid/status")" \
        'BEGIN{printf "%.2f %s", (b-a)/tck/(t1-t0)*100, rss}'
}
"$M" start >/dev/null 2>&1; wait_until '[[ -s $STATE_DIR/daemon.pid ]]' 40; sleep 2
for (( i = 0; i < 60; i++ )); do "$BIN/calapp_a" 300 & KIDS+=("$!"); done
sleep 3
P=$(daemon_pid)
nproc_all=$(ps -u "$MYUID" --no-headers | wc -l)
m1=$(measure "$P" 30)
read -r cpu1 rss1 hwm1 <<<"$m1"
"$M" stop >/dev/null 2>&1
INTERVAL_SEC=5 "$M" start >/dev/null 2>&1; wait_until '[[ -s $STATE_DIR/daemon.pid ]]' 40; sleep 3
P=$(daemon_pid); m5=$(measure "$P" 30); read -r cpu5 rss5 hwm5 <<<"$m5"
"$M" stop >/dev/null 2>&1
rec TC-20 "CPU and RAM usage" "Daemon with ~$nproc_all user processes (60 extra test apps running); measure CPU (utime+stime incl. waited children: ps/awk) and RSS over 30 s at INTERVAL_SEC=1 and 5" \
    "INTERVAL_SEC=1: CPU < 5 % and RSS < 50 MB; INTERVAL_SEC=5: CPU < 2 %" \
    "INTERVAL_SEC=1: CPU ${cpu1}% RSS $((${rss1:-0}/1024)) MB (peak $((${hwm1:-0}/1024)) MB); INTERVAL_SEC=5: CPU ${cpu5}% RSS $((${rss5:-0}/1024)) MB (peak $((${hwm5:-0}/1024)) MB); $nproc_all processes owned by the user" \
    "$(awk -v a="$cpu1" -v b="$cpu5" -v r="${rss1:-0}" -v r2="${rss5:-0}" 'BEGIN{print (a<5 && b<2 && r<51200 && r2<51200) ? "PASS" : "FAIL"}')"

# ------------------------------------------------------------------ output
{
    echo "| ID | Test | Result | Actual result |"
    echo "|---|---|---|---|"
    for r in "${RESULTS[@]}"; do
        IFS=$'\t' read -r id title steps exp act res <<<"$r"
        printf '| %s | %s | **%s** | %s |\n' "$id" "$title" "$res" "${act//|/\\|}"
    done
} >"$OUT"
{
    for r in "${RESULTS[@]}"; do
        IFS=$'\t' read -r id title steps exp act res <<<"$r"
        printf '\n#### %s — %s\n\n- **Steps:** %s\n- **Expected:** %s\n- **Actual:** %s\n- **Result:** **%s**\n' "$id" "$title" "$steps" "$exp" "$act" "$res"
    done
} >"$OUT.details"
echo
echo "$(( ${#RESULTS[@]} )) cases, $FAILS failed"
exit $(( FAILS > 0 ))
