#!/usr/bin/env bash
# =============================================================================
# tests/test_processes.sh — Process Monitor tests (processes.csv)
# -----------------------------------------------------------------------------
# Part A: deterministic unit tests. Fake `ps` snapshots are fed straight into
#         the detector, so PID reuse, hostile process names, application groups,
#         metrics and crash-recovery logic can be asserted exactly.
# Part B: the real daemon (./main.sh) watching real processes: new / closed /
#         many at once / SIGKILL / very short-lived / monitor death and restart
#         / clean restart / duplicate check.
# Everything runs in a temp dir; the real data/ is never touched.
# =============================================================================
set -u -o pipefail

ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
SANDBOX="$(mktemp -d)"
mkdir -p "$SANDBOX/bin" "$SANDBOX/desktop"
export DATA_DIR="$SANDBOX/data" STATE_DIR="$SANDBOX/state" REPORTS_DIR="$SANDBOX/reports"
export CONSENT_FILE="$SANDBOX/consent" INTERVAL_SEC=1 MIN_DURATION_SEC=0
export DESKTOP_DIRS="$SANDBOX/desktop" CAL_ROOT="$ROOT"
export APPS_MAP_FILE="$SANDBOX/apps.map" IGNORE_FILE="$SANDBOX/ignore.list"
CAL_BOOT_ID_FILE="$SANDBOX/boot"; export CAL_BOOT_ID_FILE; echo "boot-test-0000-aaaa" >"$CAL_BOOT_ID_FILE"
: >"$APPS_MAP_FILE"; : >"$IGNORE_FILE"      # must exist before config.sh is sourced (it falls back to conf/*.example otherwise)
FAILS=0 TOTAL=0
BGPIDS=()

dump_diagnostics() {
    if (( FAILS > 0 )); then
        echo; echo "---- diagnostics (a check failed) ----"
        echo "daemon pid file: $(cat "$STATE_DIR/daemon.pid" 2>/dev/null || echo none)   alive: $(kill -0 "$(cat "$STATE_DIR/daemon.pid" 2>/dev/null)" 2>/dev/null && echo yes || echo NO)"
        echo "heartbeat: $(cat "$HEARTBEAT_FILE" 2>/dev/null || echo none)   now: $(date +%s)"
        echo "---- WARN/ERROR lines of cal.log (whole run) ----"; grep -E "WARN|ERROR" "$STATE_DIR/cal.log" 2>/dev/null | tail -n 40
        echo "---- last 12 lines of cal.log ----"; tail -n 12 "$STATE_DIR/cal.log" 2>/dev/null
    fi
}
cleanup() {
    dump_diagnostics
    "$ROOT/main.sh" stop >/dev/null 2>&1 || true
    local p; for p in "${BGPIDS[@]}"; do kill -9 "$p" 2>/dev/null || true; done
    rm -rf -- "$SANDBOX"
}
trap cleanup EXIT

pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; if [[ -n ${2-} ]]; then printf '        %s\n' "$2"; fi; }
expect_eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected: [$2]  actual: [$3]"; fi; }
expect_ok() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi; }
expect_fail() { local d=$1; shift; if "$@" >/dev/null 2>&1; then fail "$d" "command unexpectedly succeeded: $*"; else pass "$d"; fi; }
# expect_between DESCRIPTION LOW HIGH ACTUAL
expect_between() { if [[ $4 =~ ^-?[0-9]+$ ]] && (( $4 >= $2 && $4 <= $3 )); then pass "$1 ($4)"; else fail "$1" "expected $2..$3, got [$4]"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# --- load the modules under test --------------------------------------------
# shellcheck source=/dev/null
source "$ROOT/config.sh"
for m in common consent storage sessionlog collector detector session recovery daemon analyzer activity; do
    # shellcheck source=/dev/null
    source "$ROOT/lib/$m.sh"
done
# Safety: this test writes to these files — they MUST be inside the sandbox, never the repo.
for _f in "$APPS_MAP_FILE" "$IGNORE_FILE" "$DATA_DIR" "$STATE_DIR"; do
    case $_f in "$SANDBOX"/*) ;; *) echo "ABORT: $_f is outside the sandbox"; exit 2 ;; esac
done
storage_init; storage_prepare_all
printf '%s\n' 'browserx|Browser X|browser' 'editorx|Editor X|editor' 'bgsvc|BG Service|background' >"$APPS_MAP_FILE"

T0=1793445277            # 2026-10-31 11:14:37 UTC
UP0=100000
reset_files() { rm -f -- "$PROCESSES_FILE"* "$PROCESS_DETAILS_FILE"* ; storage_prepare_all; }
# prow NAME — rows of processes.csv whose Process_Name is NAME
prow()   { grep ",\"$1\"," "$PROCESSES_FILE" || true; }
pcol()   { awk -F, -v c="$2" '{ if (c=="start") print $(NF-3); else if (c=="end") print $(NF-2); else if (c=="dur") print $(NF-1); else if (c=="status") print $NF; else if (c=="sid") print $1; else if (c=="pid") print $2 }' <<<"$1"; }
detail() { grep "^[^,]*,$1," "$PROCESS_DETAILS_FILE" || true; }

# --- fake snapshots ---------------------------------------------------------
declare -gA FAKE_EXE=()
collector_exe_names() { local p; for p in "$@"; do if [[ -n ${FAKE_EXE[$p]+x} ]]; then printf '%s\t%s\n' "$p" "${FAKE_EXE[$p]}"; fi; done; }
scan_begin() {   # UPTIME EPOCH
    CUR_START=(); CUR_ETIMES=(); CUR_PPID=(); CUR_TTY=(); CUR_USER=(); CUR_COMM=(); CUR_CPU=(); CUR_RSS=(); _OWN=()
    COLLECTOR_UPTIME=$1; COLLECTOR_EPOCH=$2
}
scan_add() {     # PID PPID ETIMES TTY COMM [CPU] [RSS]
    CUR_START[$1]=$(( COLLECTOR_UPTIME - $3 )); CUR_ETIMES[$1]=$3; CUR_PPID[$1]=$2; CUR_TTY[$1]=$4
    CUR_USER[$1]=tester; CUR_COMM[$1]=$5; CUR_CPU[$1]=${6:-0}; CUR_RSS[$1]=${7:-0}
}
scan_end() {     # run detector + write finished rows (COMPLETED)
    detector_diff
    daemon_flush_ended "$COLLECTOR_UPTIME" "$COLLECTOR_EPOCH" COMPLETED
}
fresh_unit() {   # clean detector state
    ACTIVE=(); ACTIVE_START=(); MET_CPU=(); MET_RSS=(); MET_PEAK=(); STARTED=(); ENDED=()
    DETECTOR_FIRST_CYCLE=1; SESSION_ID=UT-SESSION; SESSION_PROC_COUNT=0; FAKE_EXE=()
    detector_load_lists; reset_files
}

# =============================================================================
section "A1. a new process is detected, then its end is detected"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end                                  # first scan: empty
scan_begin $(( UP0 + 5 )) $(( T0 + 5 )); scan_add 40001 1 2 '?' worker; detector_diff
expect_eq "new process appears in STARTED" "40001" "${STARTED[*]}"
expect_eq "it is tracked" "1" "${#ACTIVE[@]}"
record_unpack "${ACTIVE[40001]}"
expect_eq "Start_Time comes from the OS (now - elapsed), not from detection" "$(( T0 + 3 ))" "$R_START_EPOCH"
expect_eq "it started during monitoring (not pre-session)" "no" "$R_PRE"
expect_eq "linked to the current session" "UT-SESSION" "$R_SESSION"
expect_eq "username captured" "tester" "$R_USER"
daemon_flush_ended "$COLLECTOR_UPTIME" "$COLLECTOR_EPOCH" COMPLETED
expect_eq "nothing written while it is still running" "" "$(prow worker)"
scan_begin $(( UP0 + 15 )) $(( T0 + 15 )); scan_end                # gone
row=$(prow worker)
expect_eq "end detected -> one row" "1" "$(grep -c '' <<<"$row")"
expect_eq "row: session, pid, name, user, start, end, duration, status" \
    'UT-SESSION,40001,"worker","tester",2026-10-31 11:14:40,2026-10-31 11:14:52,12,COMPLETED' "$row"
expect_eq "End_Time - Start_Time == Duration_Seconds" "12" "$(( $(date -u -d "$(pcol "$row" end)" +%s) - $(date -u -d "$(pcol "$row" start)" +%s) ))"
expect_eq "processes.csv has exactly the 8 required columns" \
    "Session_ID,PID,Process_Name,Username,Start_Time,End_Time,Duration_Seconds,Status" \
    "$(head -n1 "$PROCESSES_FILE" | LC_ALL=C sed 's/^\xEF\xBB\xBF//')"
expect_eq "tracking table is empty again" "0" "${#ACTIVE[@]}"

section "A2. PID reuse: the same PID is NOT the same process"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 10 )) $(( T0 + 10 )); scan_add 40010 1 8 '?' firstproc; detector_diff
scan_begin $(( UP0 + 20 )) $(( T0 + 20 )); scan_add 40010 1 3 '?' secondproc; scan_end   # same PID, much younger
expect_eq "old process closed when its PID got a different start time" "1" "$(grep -c ',"firstproc",' "$PROCESSES_FILE")"
expect_eq "new process with the same PID is tracked separately" "secondproc" "$(record_unpack "${ACTIVE[40010]}"; echo "$R_COMM")"
scan_begin $(( UP0 + 30 )) $(( T0 + 30 )); scan_end
expect_eq "two distinct rows for PID 40010" "2" "$(grep -c ',40010,' "$PROCESSES_FILE")"
expect_eq "different Start_Time for each" "2" "$(grep ',40010,' "$PROCESSES_FILE" | awk -F, '{print $(NF-3)}' | sort -u | wc -l)"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 10 )) $(( T0 + 10 )); scan_add 40011 1 8 '?' steady; detector_diff
scan_begin $(( UP0 + 11 )) $(( T0 + 11 )); scan_add 40011 1 10 '?' steady; detector_diff        # rounding jitter of 1 s
expect_eq "1-second rounding jitter is NOT mistaken for a new process" "1" "${#ACTIVE[@]}"
expect_eq "...and nothing was finished" "0" "${#ENDED[@]}"

section "A3. found-running vs started: the first scan proves nothing"
fresh_unit
scan_begin "$UP0" "$T0"; scan_add 40020 1 7200 '?' oldproc; scan_add 40021 1 1 '?' justborn; detector_diff
record_unpack "${ACTIVE[40020]}"
expect_eq "already-running process keeps its REAL start time" "$(( T0 - 7200 ))" "$R_START_EPOCH"
expect_eq "...and is flagged as started before monitoring" "yes" "$R_PRE"
expect_eq "detection time is recorded separately" "$T0" "$R_SEEN"
record_unpack "${ACTIVE[40021]}"
expect_eq "even a 1-second-old process in the FIRST scan is not called 'new'" "yes" "$R_PRE"
scan_begin $(( UP0 + 5 )) $(( T0 + 5 )); scan_add 40020 1 7205 '?' oldproc; scan_add 40021 1 6 '?' justborn; scan_add 40022 1 1 '?' laterproc; detector_diff
record_unpack "${ACTIVE[40022]}"
expect_eq "a process first seen in a LATER scan is a real start" "no" "$R_PRE"

section "A4. several applications at once, different lifetimes"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 2 )) $(( T0 + 2 )); scan_add 41001 1 1 '?' app_a; scan_add 41002 1 1 '?' app_b; scan_add 41003 1 1 '?' app_c; detector_diff
expect_eq "three processes started in the same scan" "3" "${#STARTED[@]}"
scan_begin $(( UP0 + 6 )) $(( T0 + 6 )); scan_add 41002 1 5 '?' app_b; scan_add 41003 1 5 '?' app_c; scan_end
scan_begin $(( UP0 + 9 )) $(( T0 + 9 )); scan_add 41003 1 8 '?' app_c; scan_end
scan_begin $(( UP0 + 12 )) $(( T0 + 12 )); scan_end
expect_eq "durations: app_a 5, app_b 8, app_c 11" "5 8 11" "$(pcol "$(prow app_a)" dur) $(pcol "$(prow app_b)" dur) $(pcol "$(prow app_c)" dur)"
expect_eq "all three linked to the session" "UT-SESSION" "$(cut -d, -f1 "$PROCESSES_FILE" | tail -n +2 | sort -u)"

section "A5. User Applications vs Background Processes"
fresh_unit
DESK_NAME=([deskapp]="Desk App"); DESK_CAT=([deskapp]=utility)
cls() { detector_classify_root "$@"; echo "$CLS_CLASS|$CLS_APP|$CLS_CAT"; }
expect_eq "apps.map entry -> application" "User_Application|Browser X|browser" "$(cls browserx browserx '?' '')"
expect_eq "apps.map 'background' category forces background" "Background_Process|BG Service|background" "$(cls bgsvc bgsvc pts/1 '/user.slice/app.slice/')"
expect_eq ".desktop launcher -> application" "User_Application|Desk App|utility" "$(cls deskapp deskapp '?' '')"
expect_eq "systemd app scope -> application" "User_Application|thing|application" "$(cls thing thing '?' '0::/user.slice/user@1000.service/app.slice/app-gnome-thing-42.scope')"
expect_eq "systemd service -> background" "Background_Process|thing|background" "$(cls thing thing '?' '0::/system.slice/thing.service')"
expect_eq "cgroup v1 text with several lines is understood" "Background_Process|thing|background" "$(cls thing thing '?' '9:name=systemd:/system.slice/x.service 8:pids:/ ')"
expect_eq "owning a terminal -> interactive program" "User_Application|vimish|terminal" "$(cls vimish vimish pts/3 '0::/user.slice/session-2.scope')"
expect_eq "no signal at all -> background (not assumed to be an app)" "Background_Process|mystery|background" "$(cls mystery mystery '?' '0::/')"
unset 'DESK_NAME[deskapp]' 'DESK_CAT[deskapp]'

section "A6. one application = many processes"
fresh_unit
FAKE_EXE=([50000]=browserx [50001]=browserx [50002]=gpuhelper [50003]=browserx [50100]=daemonx [50101]=daemonx [50102]=tool)
scan_begin "$UP0" "$T0"; scan_end
# child 49999 has a LOWER pid than its parent 50000 (wrap-around) and a hostile-looking shared start
scan_begin $(( UP0 + 4 )) $(( T0 + 4 ))
scan_add 50000 1 4 '?' browserx 3 90000; scan_add 50001 50000 3 '?' "Web Content" 2 40000
scan_add 50002 50000 3 '?' gpuhelper 1 30000; scan_add 50003 50001 2 '?' "Isolated Web Co" 1 10000
scan_add 50100 1 4 '?' daemonx; scan_add 50101 50100 3 '?' daemonx; scan_add 50102 50100 3 '?' toolworker
detector_diff
g() { record_unpack "${ACTIVE[$1]}"; echo "$R_CLASS|$R_ROOT|$R_GROUP"; }
root_group=$(g 50000)
expect_eq "browser main process is the ROOT application instance" "User_Application|yes|50000-$(( T0 ))" "$root_group"
expect_eq "its renderer (parent=root) joins the group" "User_Application|no|50000-$T0" "$(g 50001)"
expect_eq "helper with another executable name still joins (parent is an app)" "User_Application|no|50000-$T0" "$(g 50002)"
expect_eq "grandchild joins the same instance" "User_Application|no|50000-$T0" "$(g 50003)"
expect_eq "unrelated background daemon is its own root" "Background_Process|yes|50100-$T0" "$(g 50100)"
expect_eq "same-program worker joins its parent's group" "Background_Process|no|50100-$T0" "$(g 50101)"
expect_eq "different program under a background parent is NOT merged" "Background_Process|yes|50102-$(( T0 + 1 ))" "$(g 50102)"
expect_eq "process names with spaces are kept whole" "Web Content" "$(record_unpack "${ACTIVE[50001]}"; echo "$R_COMM")"
expect_eq "command name comes from the executable" "browserx" "$(record_unpack "${ACTIVE[50001]}"; echo "$R_CMD")"
expect_eq "app name for the helpers is the application's" "Browser X" "$(record_unpack "${ACTIVE[50002]}"; echo "$R_APP")"
scan_begin $(( UP0 + 14 )) $(( T0 + 14 )); scan_add 50000 1 14 '?' browserx 20 95000; scan_add 50001 50000 13 '?' "Web Content" 9 41000; scan_end
scan_begin $(( UP0 + 20 )) $(( T0 + 20 )); scan_end
activity_prepare "" "" 0
top=$(activity_apps User_Application 10 | tail -n +2)     # Rank,App,Launches,Already,Processes,Completed,Incomplete,Active_Seconds,...
expect_eq "stats: launches counts roots only" "1" "$(awk -F, '{print $3}' <<<"$top")"
expect_eq "stats: process count" "4" "$(awk -F, '{print $5}' <<<"$top")"
expect_eq "stats: union of overlapping intervals (not 20+13+...)" "20" "$(awk -F, '{print $8}' <<<"$top")"
expect_eq "background class listed separately" "daemonx" "$(activity_apps Background_Process 10 | tail -n +2 | awk -F, '{print $2}' | tr -d '"' | sort | head -1)"
expect_eq "details: the 4 browser rows share one App_Instance" "1" "$(grep -h "^UT-SESSION,5000[0-3]," "$PROCESS_DETAILS_FILE" | awk -F, '{print $(NF-12)}' | sort -u | wc -l)"
expect_eq "details: exactly one of them is the root" "1" "$(grep -h "^UT-SESSION,5000[0-3]," "$PROCESS_DETAILS_FILE" | awk -F, '{print $(NF-11)}' | grep -c '^yes$')"

section "A7. CPU and memory"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 5 )) $(( T0 + 5 )); scan_add 42000 1 1 '?' cruncher 1 1000; detector_diff
scan_begin $(( UP0 + 10 )) $(( T0 + 10 )); scan_add 42000 1 6 '?' cruncher 5 5000; detector_diff
scan_begin $(( UP0 + 15 )) $(( T0 + 15 )); scan_add 42000 1 11 '?' cruncher 9 2000; detector_diff
scan_begin $(( UP0 + 21 )) $(( T0 + 21 )); scan_end
d=$(detail 42000)
expect_eq "details: CPU seconds = last observed (9)" "9" "$(awk -F, '{print $(NF-6)}' <<<"$d")"
expect_eq "details: peak memory = 5000 KiB, last = 2000 KiB" "5000 2000" "$(awk -F, '{print $(NF-4), $(NF-3)}' <<<"$d")"
expect_eq "details: average CPU % over its 17 s lifetime (9 s / 17 s = 52.9)" "52.9" "$(awk -F, '{print $(NF-5)}' <<<"$d")"

section "A8. hostile / odd process names cannot break anything"
fresh_unit
touch_target="$SANDBOX/PWNED"
names=('a]b' '$(touch '"$touch_target"')' 'x"y,z' '=cmd|calc' '`touch '"$touch_target"'`' 'back\slash' '@SUM(A1)' '-bash' "it's" 'a b  c')
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 3 )) $(( T0 + 3 ))
i=0; for n in "${names[@]}"; do i=$(( i + 1 )); scan_add $(( 43000 + i )) 1 2 '?' "$n"; done
detector_diff
expect_eq "all ${#names[@]} odd names are tracked" "${#names[@]}" "${#ACTIVE[@]}"
scan_begin $(( UP0 + 8 )) $(( T0 + 8 )); scan_end
expect_eq "all of them were written" "${#names[@]}" "$(( $(grep -c '' "$PROCESSES_FILE") - 1 ))"
expect_eq "no command inside a process name was executed" "no" "$([[ -e $touch_target ]] && echo yes || echo no)"
expect_ok "files still verify (field counts, quoting)" storage_verify_processes
expect_eq "a name starting with = is stored with a leading quote" "1" "$(grep -c "\"'=cmd|calc\"" "$PROCESSES_FILE")"
expect_eq "embedded quote/comma is escaped" "1" "$(grep -c '"x""y,z"' "$PROCESSES_FILE")"

section "A9. never track the logger itself or its children"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 3 )) $(( T0 + 3 ))
scan_add "$$" 1 100 '?' main.sh; scan_add 44001 "$$" 1 '?' awk; scan_add 44002 44001 1 '?' grandchild; scan_add 44003 1 1 '?' stranger
detector_diff
expect_eq "only the unrelated process is tracked" "44003" "${!ACTIVE[*]}"

section "A10. MIN_DURATION_SEC is honoured"
fresh_unit
scan_begin "$UP0" "$T0"; scan_end
scan_begin $(( UP0 + 2 )) $(( T0 + 2 )); scan_add 45001 1 1 '?' blink; detector_diff
MIN_DURATION_SEC=5; scan_begin $(( UP0 + 4 )) $(( T0 + 4 )); scan_end
expect_eq "3 s process dropped when the minimum is 5 s" "" "$(prow blink)"
MIN_DURATION_SEC=0
scan_begin $(( UP0 + 10 )) $(( T0 + 10 )); scan_add 45002 1 1 '?' blink; detector_diff
scan_begin $(( UP0 + 13 )) $(( T0 + 13 )); scan_end
expect_eq "kept when the minimum is 0" "1" "$(prow blink | grep -c '')"

section "A11. recovery logic: continue, close, never duplicate"
fresh_unit; rm -f -- "$STATE_DIR"/* "$SESSIONS_FILE"*
BOOT8=$(head -c8 "$CAL_BOOT_ID_FILE")
mkrec() {   # PID START_MONO START_EPOCH COMM PRE
    R_PID=$1; R_PPID=1; R_START_MONO=$2; R_START_EPOCH=$3; R_SEEN=$3; R_TTY='?'; R_USER=tester; R_PAUSED=0
    R_PRE=$5; R_SESSION=S-OLD; R_CLASS=Background_Process; R_CAT=background; R_GROUP="$1-$3"; R_ROOT=yes; R_APP=$4; R_CMD=$4; R_COMM=$4
    record_pack
}
SESSION_ID=S-OLD; SESSION_BOOT=$BOOT8; SESSION_START_EPOCH=$T0; SESSION_START_MONO=$UP0
sessionlog_start S-OLD "$T0" tester 1000; session_write_state
{ mkrec 46001 $(( UP0 + 10 )) $(( T0 + 10 )) alive no; echo "$REPLY"
  mkrec 46002 $(( UP0 + 12 )) $(( T0 + 12 )) vanished no; echo "$REPLY"
  mkrec 46003 $(( UP0 + 14 )) $(( T0 + 14 )) already no; echo "$REPLY"
  mkrec 46004 $(( UP0 + 16 )) $(( T0 + 16 )) reused no; echo "$REPLY"
  mkrec 46005 $(( UP0 + 1 ))  $(( T0 + 1 ))  oldtimer yes; echo "$REPLY"; } >"$ACTIVE_FILE"
storage_write_heartbeat $(( T0 + 60 )) $(( UP0 + 60 )) "$BOOT8" S-OLD 0 0
# the old daemon had ALREADY written the row for 'already' (died before saving state)
csv_row rnttrrnr S-OLD 46003 already tester "2026-10-31 11:14:51" "2026-10-31 11:15:30" 39 COMPLETED
storage_append processes "$REPLY"
# state of the machine at restart: alive still there; reused PID has a new start time; oldtimer alive
scan_begin $(( UP0 + 90 )) $(( T0 + 90 ))
scan_add 46001 1 80 '?' alive; scan_add 46004 1 5 '?' impostor; scan_add 46005 1 89 '?' oldtimer
recovery_run
expect_eq "alive process is re-attached, not re-logged" "46001 46005" "$(printf '%s\n' "${!ACTIVE[@]}" | sort -n | paste -sd' ')"
record_unpack "${ACTIVE[46001]}"
expect_eq "re-attached process keeps its ORIGINAL session" "S-OLD" "$R_SESSION"
expect_eq "...its original start time" "$(( T0 + 10 ))" "$R_START_EPOCH"
expect_eq "...and is still 'started during monitoring'" "no" "$R_PRE"
record_unpack "${ACTIVE[46005]}"
expect_eq "a process that predated monitoring stays flagged" "yes" "$R_PRE"
expect_eq "vanished process: one RECOVERED row" "RECOVERED" "$(pcol "$(prow vanished)" status)"
expect_eq "...ended at the last heartbeat (T0+60)" "2026-10-31 11:15:37" "$(pcol "$(prow vanished)" end)"
expect_eq "reused PID: old process closed as RECOVERED" "RECOVERED" "$(pcol "$(prow reused)" status)"
expect_eq "...and the impostor was NOT attached to it" "no" "$([[ -n ${ACTIVE[46004]+x} ]] && echo yes || echo no)"
expect_eq "already-written process is NOT written a second time" "1" "$(prow already | grep -c '')"
expect_eq "alive processes produced no row" "" "$(prow alive)$(prow oldtimer)"
expect_eq "interrupted session closed as CRASHED" "CRASHED" "$(awk -F, '/^S-OLD,/ {print $NF}' "$SESSIONS_FILE")"
expect_eq "state was saved immediately with the survivors" "2" "$(grep -c '' "$ACTIVE_FILE")"
expect_ok "no duplicate keys in the files" storage_verify_processes

section "A12. verify detects duplicates and damage"
cp "$PROCESSES_FILE" "$SANDBOX/p.bak"
tail -n1 "$PROCESSES_FILE" >>"$PROCESSES_FILE"                       # exact duplicate
echo 'S,xx,"n","u",2026-10-31 11:00:00,2026-10-31 10:00:00,5,BOGUS' >>"$PROCESSES_FILE"
echo 'S,1,"n"' >>"$PROCESSES_FILE"
out=$(storage_verify_processes); rc=$?
expect_eq "verify fails" "1" "$rc"
for needle in DUPLICATE "PID is not numeric" "End_Time is before" "invalid Status" "expected 8 fields"; do
    if grep -q "$needle" <<<"$out"; then pass "verify reports: $needle"; else fail "verify reports: $needle" "$out"; fi
done
cp "$SANDBOX/p.bak" "$PROCESSES_FILE"
printf 'T,1,"torn' >>"$PROCESSES_FILE"                               # torn last line, no newline
storage_prepare_csv "$PROCESSES_FILE" "$PROCESSES_HEADER"
expect_eq "torn last line: next append starts on a fresh line" "" "$(tail -c1 "$PROCESSES_FILE")"
printf 'other,header\n1,2\n' >"$SANDBOX/foreign.csv"
storage_prepare_csv "$SANDBOX/foreign.csv" "$PROCESSES_HEADER"
expect_eq "foreign file moved aside, not overwritten" "other,header" "$(head -n1 "$SANDBOX"/foreign.csv.invalid.* | head -n1)"

section "A13. regression: a process dying while its cgroup is read must not freeze the monitor"
FP="$SANDBOX/fakeproc"; mkdir -p "$FP/700" "$FP/701"; printf "%s\n" "9:name=systemd:/user.slice/a" "0::/user.slice/user@1.service/app.slice/app-x.scope" >"$FP/700/cgroup"
CAL_PROC_ROOT=$FP detector_read_cgroup 700
expect_eq "cgroup text is read from every line" "9:name=systemd:/user.slice/a 0::/user.slice/user@1.service/app.slice/app-x.scope" "$CG"
CAL_PROC_ROOT=$FP detector_read_cgroup 999; expect_eq "a process that is already gone gives an empty result, not an error" "" "$CG"
# Simulate ESRCH: a `read` that succeeds once, then fails and leaves its variable untouched.
SHIM='read() { if (( ${_RN:-0} == 0 )); then _RN=1; builtin read "$@"; else return 1; fi; }'
old_idiom='old() { local line CG=; while IFS= read -r line || [[ -n $line ]]; do CG+="$line "; done <"$1"; }'
timeout 3 bash -c "$SHIM; $old_idiom; old \"$FP/700/cgroup\"" >/dev/null 2>&1; rc_old=$?
expect_eq "control: the OLD read-loop idiom spins forever under that failure (timeout, rc 124)" "124" "$rc_old"
timeout 5 bash -c "$SHIM; export CAL_PROC_ROOT=$FP; source \"$ROOT/lib/detector.sh\"; detector_read_cgroup 700; [[ -n \\$CG || 1 ]]" >/dev/null 2>&1; rc_new=$?
expect_eq "the new reader finishes even when read fails mid-file" "0" "$rc_new"
expect_eq "static check: no code reads a /proc file in a while-read loop" "0" "$(grep -cE 'done *< */proc' "$ROOT"/lib/*.sh | awk -F: '{s+=$2} END {print s+0}')"


# =============================================================================
# Part B — the real daemon watching real processes
# =============================================================================
MAIN="$ROOT/main.sh"
cp /bin/sleep "$SANDBOX/bin/newapp"; cp /bin/sleep "$SANDBOX/bin/app_a"; cp /bin/sleep "$SANDBOX/bin/app_b"
cp /bin/sleep "$SANDBOX/bin/app_c"; cp /bin/sleep "$SANDBOX/bin/childhelper"; cp /bin/sleep "$SANDBOX/bin/deskapp"
cp /bin/sleep "$SANDBOX/bin/survivor1"; cp /bin/sleep "$SANDBOX/bin/survivor2"; cp /bin/sleep "$SANDBOX/bin/casualty"
cp /bin/bash "$SANDBOX/bin/parentapp"
printf '%s\n' '[Desktop Entry]' 'Type=Application' 'Name=Desk Application' "Exec=$SANDBOX/bin/deskapp %U" 'Categories=Utility;' >"$SANDBOX/desktop/deskapp.desktop"
printf '%s\n' 'parentapp|Parent App|editor' 'editorx|Editor X|editor' >"$APPS_MAP_FILE"

bg() { "$@" >/dev/null 2>&1 & BGPIDS+=("$!"); LASTBG=$!; }
daemon_pid() { cat "$STATE_DIR/daemon.pid" 2>/dev/null; }
# wait_for TIMEOUT_S COMMAND...
wait_for() { local t=$1 i; shift; for (( i = 0; i < t * 4; i++ )); do if "$@" >/dev/null 2>&1; then return 0; fi; sleep 0.25; done; return 1; }
running_row() { "$MAIN" processes --running | awk -F'\t' -v n="$1" '$2 == n'; }
is_running() { [[ -n $(running_row "$1") ]]; }
not_running() { [[ -z $(running_row "$1") ]]; }
has_row() { grep -q ",\"$1\"," "$PROCESSES_FILE" 2>/dev/null; }
sid_now() { awk -F, 'NR>1 {print $1}' "$SESSIONS_FILE" | tail -n1; }

rm -rf -- "$DATA_DIR" "$STATE_DIR"; mkdir -p "$DATA_DIR" "$STATE_DIR"; reset_files 2>/dev/null
"$MAIN" consent --accept >/dev/null

section "B1. launch an application, then close it"
"$MAIN" start >/dev/null; sleep 2
SID=$(sid_now)
bg "$SANDBOX/bin/newapp" 7; P1=$LASTBG
expect_ok "new application is noticed while running" wait_for 4 is_running newapp
expect_eq "it is listed with the real PID" "$P1" "$(running_row newapp | cut -f1)"
expect_eq "no row yet (it has not ended)" "" "$(prow newapp)"
expect_ok "closing it produces a row" wait_for 12 has_row newapp
row=$(prow newapp)
expect_eq "row belongs to the current session" "$SID" "$(pcol "$row" sid)"
expect_eq "PID matches" "$P1" "$(pcol "$row" pid)"
expect_eq "status COMPLETED" "COMPLETED" "$(pcol "$row" status)"
expect_between "duration ~ 7 s (+ up to one scan late)" 6 10 "$(pcol "$row" dur)"
expect_eq "End_Time - Start_Time == Duration" "$(pcol "$row" dur)" "$(( $(date -u -d "$(pcol "$row" end)" +%s) - $(date -u -d "$(pcol "$row" start)" +%s) ))"
d=$(detail "$P1")
expect_eq "details: command name = executable base name" "newapp" "$(awk -F, '{print $5}' <<<"$d" | tr -d '"')"
expect_eq "details: it started while monitoring" "no" "$(awk -F, '{print $(NF-10)}' <<<"$d")"
expect_eq "details: PPID recorded" "$$" "$(awk -F, '{print $4}' <<<"$d")"
expect_eq "no map/desktop/tty/cgroup signal -> Background_Process" "Background_Process" "$(awk -F, '{print $6}' <<<"$d")"
expect_eq "state matches: gone from the running list" "0" "$(running_row newapp | wc -l)"

section "B2. several applications at the same time"
bg "$SANDBOX/bin/app_a" 4; PA=$LASTBG; bg "$SANDBOX/bin/app_b" 7; PB=$LASTBG; bg "$SANDBOX/bin/app_c" 10; PC=$LASTBG
expect_ok "all three are tracked together" wait_for 4 bash -c "[ \$('$MAIN' processes --running | awk -F'\t' '\$2 ~ /^app_[abc]\$/' | wc -l) -eq 3 ]"
expect_ok "all three eventually produce rows" wait_for 16 bash -c "[ \$(grep -cE ',\"app_[abc]\",' '$PROCESSES_FILE') -eq 3 ]"
expect_between "app_a ~4 s" 3 7 "$(pcol "$(prow app_a)" dur)"
expect_between "app_b ~7 s" 6 10 "$(pcol "$(prow app_b)" dur)"
expect_between "app_c ~10 s" 9 13 "$(pcol "$(prow app_c)" dur)"
expect_eq "each has its own PID" "$PA $PB $PC" "$(pcol "$(prow app_a)" pid) $(pcol "$(prow app_b)" pid) $(pcol "$(prow app_c)" pid)"
expect_eq "all linked to the same session" "1" "$(cut -d, -f1 <<<"$(prow app_a; prow app_b; prow app_c)" | sort -u | wc -l)"

section "B3. a process killed with SIGKILL"
bg "$SANDBOX/bin/casualty" 60; PK=$LASTBG
wait_for 4 is_running casualty
kill -9 "$PK"; sleep 0.2; wait "$PK" 2>/dev/null
expect_ok "the forced kill is detected" wait_for 6 has_row casualty
expect_eq "recorded as COMPLETED (an exit cannot be told from a kill)" "COMPLETED" "$(pcol "$(prow casualty)" status)"
expect_between "killed after ~3 s" 1 7 "$(pcol "$(prow casualty)" dur)"

section "B4. very short-lived processes"
before_lines=$(grep -c '' "$PROCESSES_FILE")
for i in $(seq 1 60); do /bin/true; "$SANDBOX/bin/newapp" 0.05; done
bg "$SANDBOX/bin/newapp" 2; wait_for 8 bash -c "[ \$(grep -c ',\"newapp\",' '$PROCESSES_FILE') -ge 2 ]"
sleep 2
expect_ok "daemon survived the burst" kill -0 "$(daemon_pid)"
expect_ok "files are valid after the burst" "$MAIN" processes --check
short=$(prow newapp | awk -F, '{print $(NF-1)}' | sort -n | head -1)
expect_between "the 2 s process was caught with a sane duration" 1 6 "$(pcol "$(prow newapp | tail -n1)" dur)"
extra=$(( $(grep -c '' "$PROCESSES_FILE") - before_lines ))
echo "      (60 sub-100ms processes: ${extra} row(s) written in total; sub-interval ones are only seen if a scan hits them)"
expect_eq "no bogus rows (every duration is a sane number)" "0" "$(awk -F, 'NR>1 && ($(NF-1) !~ /^[0-9]+$/ || $(NF-1) > 100000)' "$PROCESSES_FILE" | wc -l)"

section "B5. application classes with real processes (apps.map, .desktop)"
bg "$SANDBOX/bin/deskapp" 6; PD=$LASTBG
expect_ok "desktop-launcher program tracked" wait_for 4 is_running deskapp
expect_eq ".desktop entry -> User_Application named from the launcher" "User_Application|Desk Application" "$(running_row deskapp | awk -F'\t' '{print $3 "|" $4}')"
expect_ok "parent+children: application with helper processes" bash -c "
    '$SANDBOX/bin/parentapp' -c '$SANDBOX/bin/childhelper 7 & $SANDBOX/bin/childhelper 7 & wait' >/dev/null 2>&1 &"
sleep 0.5
expect_ok "parent and two helpers are tracked" wait_for 5 bash -c "[ \$('$MAIN' processes --running | awk -F'\t' '\$2==\"childhelper\"' | wc -l) -eq 2 ] && [ \$('$MAIN' processes --running | awk -F'\t' '\$2==\"parentapp\"' | wc -l) -eq 1 ]"
expect_eq "helpers are not roots" "no" "$(running_row childhelper | awk -F'\t' '{print $5}' | sort -u)"
expect_eq "the parent is the root" "yes" "$(running_row parentapp | awk -F'\t' '{print $5}')"
wait_for 14 bash -c "[ \$(grep -c ',\"childhelper\",' '$PROCESSES_FILE') -ge 2 ] && grep -q ',\"parentapp\",' '$PROCESSES_FILE'"
activity_prepare "" "" 0
apps=$(activity_apps User_Application 10)
expect_eq "stats count Parent App as ONE launch of THREE processes" "Parent App,1,3" "$(awk "$AWK_LIB"'NR > 1 { csv_split($0, f); if (f[2] == "Parent App") print f[2] "," f[3] "," f[5] }' <<<"$apps")"
expect_eq "...and helpers are not listed as applications" "0" "$(grep -c childhelper <<<"$apps")"
expect_ok "...the CLI shows the same table" bash -c "'$MAIN' processes --apps | grep -q 'Parent App'"

section "B6. the monitor DIES (kill -9) while processes are running"
bg "$SANDBOX/bin/survivor1" 40; S1=$LASTBG; bg "$SANDBOX/bin/survivor2" 40; S2=$LASTBG; bg "$SANDBOX/bin/casualty" 6; CD=$LASTBG
wait_for 5 bash -c "[ \$('$MAIN' processes --running | awk -F'\t' '\$2 ~ /^(survivor[12]|casualty)\$/' | wc -l) -eq 3 ]"
OLD_SID=$(sid_now)
st1_before=$(running_row survivor1 | cut -f6); st2_before=$(running_row survivor2 | cut -f6)
rows_before=$(grep -c '' "$PROCESSES_FILE")
cas_rows_before=$(grep -c ',"casualty",' "$PROCESSES_FILE")
kill -9 "$(daemon_pid)"; DEAD_AT=$(date +%s)
expect_eq "earlier records survive the monitor's death" "$rows_before" "$(grep -c '' "$PROCESSES_FILE")"
expect_ok "files are still valid after the crash" "$MAIN" processes --check
sleep 8                                               # 'casualty' (6 s) dies while nobody is watching
"$MAIN" start >/dev/null; RESTART_AT=$(date +%s); sleep 2.5
expect_ok "survivor1 is still tracked" is_running survivor1
expect_ok "survivor2 is still tracked" is_running survivor2
expect_eq "survivor1 keeps its TRUE start time (not 'now')" "$st1_before" "$(running_row survivor1 | cut -f6)"
expect_eq "survivor2 keeps its TRUE start time" "$st2_before" "$(running_row survivor2 | cut -f6)"
expect_eq "survivors stay linked to the session they started in" "$OLD_SID $OLD_SID" "$(running_row survivor1 | cut -f8) $(running_row survivor2 | cut -f8)"
expect_eq "survivors are NOT flagged as found-running (they were seen starting)" "no no" "$(running_row survivor1 | cut -f7) $(running_row survivor2 | cut -f7)"
expect_eq "no row was written for processes that are still alive" "0" "$(grep -cE ',"survivor[12]",' "$PROCESSES_FILE")"
cas=$(prow casualty | tail -n1)
expect_eq "process that died during the outage: one new RECOVERED row" "$(( cas_rows_before + 1 ))" "$(grep -c ',"casualty",' "$PROCESSES_FILE")"
expect_eq "...status RECOVERED" "RECOVERED" "$(pcol "$cas" status)"
cas_end=$(date -u -d "$(pcol "$cas" end)" +%s)
if (( cas_end <= DEAD_AT + 1 && cas_end >= DEAD_AT - 6 )); then pass "...End_Time is the last heartbeat (just before the crash)"; else fail "...End_Time is the last heartbeat" "end=$cas_end crash=$DEAD_AT"; fi
expect_eq "the dead monitor's session is CRASHED" "CRASHED" "$(awk -F, -v s="$OLD_SID" '$1==s {print $NF}' "$SESSIONS_FILE")"
kill "$S1" 2>/dev/null; wait "$S1" 2>/dev/null
expect_ok "survivor1 later ends: one row" wait_for 6 has_row survivor1
expect_eq "...attributed to the ORIGINAL session, status COMPLETED" "$OLD_SID COMPLETED" "$(pcol "$(prow survivor1)" sid) $(pcol "$(prow survivor1)" status)"
expect_eq "...with its true start time" "$(date -u -d "$st1_before" +%s)" "$(date -u -d "$(pcol "$(prow survivor1)" start)" +%s)"
"$MAIN" stop >/dev/null
expect_eq "survivor2 was still running at clean stop -> SESSION_END" "SESSION_END" "$(pcol "$(prow survivor2)" status)"
expect_eq "survivor2 appears exactly ONCE" "1" "$(grep -c ',"survivor2",' "$PROCESSES_FILE")"
expect_eq "survivor1 appears exactly ONCE" "1" "$(grep -c ',"survivor1",' "$PROCESSES_FILE")"

section "B7. clean stop and start with a process still running"
kill "$S2" 2>/dev/null; wait "$S2" 2>/dev/null
"$MAIN" start >/dev/null; sleep 1.5
bg "$SANDBOX/bin/survivor1" 14; SX=$LASTBG
wait_for 4 is_running survivor1
S_A=$(sid_now); sx_start=$(running_row survivor1 | cut -f6)
"$MAIN" stop >/dev/null
expect_eq "stop closes it for the first session: SESSION_END" "SESSION_END" "$(prow survivor1 | awk -F, -v p="$SX" '$2==p {print $NF}')"
"$MAIN" start >/dev/null; sleep 2
S_B=$(sid_now)
expect_eq "a new session was opened" "1" "$([[ $S_A != "$S_B" ]] && echo 1 || echo 0)"
expect_ok "the still-running process is picked up again" wait_for 4 is_running survivor1
expect_eq "...flagged as FOUND RUNNING (not 'started now')" "yes" "$(running_row survivor1 | cut -f7)"
# Start_Time is derived from "now - elapsed" at each first sighting; both are whole seconds,
# so the same process seen in two sessions can differ by 1 s (documented precision: +-1 s).
expect_between "...with its real start time (+-1 s: whole-second resolution)" -1 1 "$(( $(date -u -d "$(running_row survivor1 | cut -f6)" +%s) - $(date -u -d "$sx_start" +%s) ))"
kill "$SX" 2>/dev/null; wait "$SX" 2>/dev/null
expect_ok "second row appears when it ends" wait_for 6 bash -c "[ \$(grep -c ',$SX,' '$PROCESSES_FILE') -eq 2 ]"
expect_eq "two rows: different sessions (one per monitoring session)" "2" "$(grep ",$SX," "$PROCESSES_FILE" | cut -d, -f1 | sort -u | wc -l)"
expect_eq "statuses SESSION_END then COMPLETED" "COMPLETED SESSION_END" "$(grep ",$SX," "$PROCESSES_FILE" | awk -F, '{print $NF}' | sort | paste -sd' ')"

section "B8. no duplicates anywhere"
"$MAIN" stop >/dev/null
dups=$(awk -F, 'NR>1 {print $1 "|" $2 "|" $(NF-3)}' "$PROCESSES_FILE" | sort | uniq -d | wc -l)
expect_eq "no duplicate (Session_ID, PID, Start_Time) in processes.csv" "0" "$dups"
dups=$(awk -F, 'NR>1 {print $1 "|" $2 "|" $3}' "$PROCESS_DETAILS_FILE" | sort | uniq -d | wc -l)
expect_eq "no duplicate keys in process_details.csv" "0" "$dups"
expect_eq "every process row has its details row" "$(( $(grep -c '' "$PROCESSES_FILE") ))" "$(grep -c '' "$PROCESS_DETAILS_FILE")"
expect_ok "processes --check passes" "$MAIN" processes --check
expect_ok "sessions --check passes" "$MAIN" sessions --check
echo "      sessions: $(awk -F, 'NR>1 {print $NF}' "$SESSIONS_FILE" | paste -sd' ')"

section "B9. configuration, privacy, permissions"
for v in 0 61 abc; do expect_fail "INTERVAL_SEC=$v is rejected" env INTERVAL_SEC=$v "$MAIN" status; done
INTERVAL_SEC=3 "$MAIN" start >/dev/null; sleep 1
expect_ok "scan period is configurable (status shows 3s)" bash -c "INTERVAL_SEC=3 '$MAIN' status | grep -q 'Interval : 3s'"
# Sample the heartbeat for ~8 s: every CHANGE must be one scan period (3 s +-1) apart.
# (Comparing two reads a fixed time apart is phase-dependent and flaky.)
hb_vals=(); for _ in $(seq 1 17); do hb_vals+=("$(cut -d' ' -f1 "$HEARTBEAT_FILE")"); sleep 0.5; done
mapfile -t hb_uniq < <(printf '%s\n' "${hb_vals[@]}" | awk '!seen[$0]++')
hb_bad=0; for (( _i = 1; _i < ${#hb_uniq[@]}; _i++ )); do d=$(( hb_uniq[_i] - hb_uniq[_i-1] )); if (( d < 2 || d > 4 )); then hb_bad=1; fi; done
expect_eq "heartbeat advances once per scan period (3 s, +-1) across ${#hb_uniq[@]} distinct values" "0" "$hb_bad"
if (( ${#hb_uniq[@]} >= 3 )); then pass "...and it advanced at least twice in 8 s"; else fail "...and it advanced at least twice in 8 s" "${hb_uniq[*]}"; fi
"$MAIN" stop >/dev/null
expect_eq "no sudo anywhere in the code" "0" "$(grep -rwn 'sudo' "$ROOT/lib" "$ROOT/main.sh" "$ROOT/config.sh" | grep -v '^\S*:[0-9]*:\s*#' | grep -vc 'no sudo\|never\|without sudo\|not use sudo')"
expect_eq "only the current user's processes are requested from ps" "1" "$(grep -c 'ps -u "\$EUID"' "$ROOT/lib/collector.sh")"
expect_eq "command-line arguments / environment are never read" "0" "$(grep -hE '/proc/[^ ]*(cmdline|environ)|ps .*-o [^ ]*(args|cmd=|command)' "$ROOT/lib/collector.sh" "$ROOT/lib/detector.sh" | grep -vc '^[[:space:]]*#')"
expect_eq "data files are private (600)" "" "$(find "$DATA_DIR" -maxdepth 1 -type f \( -name '*.csv' \) ! -perm 600)"

section "B10. a frozen monitor is still stoppable (stop forces it) and recovery works afterwards"
"$MAIN" start >/dev/null; sleep 2
FROZEN=$(daemon_pid); SID_F=$(sid_now)
kill -STOP "$FROZEN"
t0=$(date +%s); out=$(STOP_TIMEOUT_SEC=2 "$MAIN" stop 2>&1); rc=$?; t1=$(date +%s)
expect_eq "stop exits 0 even though the monitor was frozen" "0" "$rc"
expect_eq "...and says it had to force it" "1" "$(grep -c 'forcing it' <<<"$out")"
expect_between "...within the configured timeout (2 s) plus a little" 2 8 "$(( t1 - t0 ))"
st_f=$(ps -o stat= -p "$FROZEN" 2>/dev/null | tr -d ' ')     # a killed process may linger as an unreaped zombie (Z): that is dead
expect_eq "the frozen process is really dead (gone, or only an unreaped zombie)" "dead" "$([[ -z $st_f || $st_f == Z* ]] && echo dead || echo "alive ($st_f)")"
"$MAIN" start >/dev/null; sleep 2
expect_eq "the forced session is closed by recovery as CRASHED" "CRASHED" "$(awk -F, -v s="$SID_F" '$1==s {print $NF}' "$SESSIONS_FILE")"
"$MAIN" stop >/dev/null
expect_ok "files are consistent after the forced stop and recovery" "$MAIN" processes --check
expect_ok "STOP_TIMEOUT_SEC=0 is rejected" bash -c "! STOP_TIMEOUT_SEC=0 '$MAIN' status >/dev/null 2>&1"

printf '\n%d checks, %d failed\n' "$TOTAL" "$FAILS"
if (( FAILS == 0 )); then echo "ALL PROCESS TESTS PASSED"; fi
exit "$FAILS"
