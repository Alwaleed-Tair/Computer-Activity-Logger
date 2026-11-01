#!/usr/bin/env bash
# test.sh — tests for cal.sh (sandboxed: uses a temp data dir, never your real data).
#   bash test.sh            (about 2 minutes)
set -u -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
SB="$(mktemp -d)"; mkdir -p "$SB/bin"
export CAL_DATA="$SB/data" CAL_INTERVAL=1
CAL="$ROOT/cal.sh"
S="$CAL_DATA/sessions.csv"; P="$CAL_DATA/processes.csv"
FAILS=0 TOTAL=0
pass() { TOTAL=$((TOTAL + 1)); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$((TOTAL + 1)); FAILS=$((FAILS + 1)); printf '  FAIL  %s\n' "$1"; [[ -n ${2-} ]] && printf '        %s\n' "$2"; }
eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2] actual [$3]"; fi; }
section() { printf '\n== %s ==\n' "$1"; }
cleanup() { local p; "$CAL" stop >/dev/null 2>&1; for p in "${KIDS[@]:-}"; do [[ -n $p ]] && kill -KILL "$p" 2>/dev/null; done; rm -rf -- "$SB"; }
KIDS=(); trap cleanup EXIT
app() { cp "$(command -v sleep)" "$SB/bin/$1"; }
col() { awk -F, -v n="$2" 'NR > 1 { print $n }' "$1"; }         # column n of a CSV (names have no commas)
row() { grep -a ",$2," "$1" | grep -a "$3" | tail -n 1; }        # row for pid in file matching text

section "1. consent is required"
"$CAL" run >/dev/null 2>&1; eq "run without consent is refused (rc 1)" 1 "$?"
echo no | "$CAL" start >/dev/null 2>&1; eq "answering 'no' starts nothing (rc 1)" 1 "$?"
eq "...and creates no data files" 0 "$(ls "$CAL_DATA"/*.csv 2>/dev/null | wc -l)"

section "2. start, one instance only"
echo yes | "$CAL" start >/dev/null; eq "start (answering yes)" 0 "$?"
out=$("$CAL" status); [[ $out == Running* ]] && pass "status says running" || fail "status says running" "$out"
out=$("$CAL" start); case $out in "Already running"*) pass "a second start does not start a second logger" ;; *) fail "second start" "$out" ;; esac
"$CAL" run >/dev/null 2>&1; eq "a second run is refused (rc 1)" 1 "$?"
eq "exactly one logger process" 1 "$(pgrep -fc "^bash $CAL run\$")"

section "3. real programs: concurrent, odd names, killed, left running"
app "برنامج"; app "My App"; app "=a,b"; app killme; app stays
"$SB/bin/برنامج" 6 & KIDS+=($!); p_ar=$!
"$SB/bin/My App" 9 & KIDS+=($!); p_sp=$!
"$SB/bin/=a,b" 5 & KIDS+=($!); p_ev=$!
"$SB/bin/killme" 120 & KIDS+=($!); p_kill=$!
"$SB/bin/stays" 300 & KIDS+=($!); p_stay=$!
t0=$(date +%s)
sleep 4; kill -KILL "$p_kill"; wait "$p_kill" 2>/dev/null; t_kill=$(date +%s)
sleep 9
out=$("$CAL" stop); [[ $out == Stopped* ]] && pass "stop saves and exits" || fail "stop" "$out"
eq "no logger left" 0 "$(pgrep -fc "^bash $CAL run\$")"
for pid in $p_ar $p_sp $p_ev $p_kill $p_stay; do :; done
r=$(row "$P" "$p_ar" ENDED);   [[ $r == *",برنامج,"* ]] && pass "Arabic name logged verbatim" || fail "Arabic name" "$r"
dur=$(cut -d, -f6 <<<"$r");    (( dur >= 5 && dur <= 8 )) && pass "6 s program measured as ${dur} s (+-2)" || fail "duration of the 6 s program" "$r"
r=$(row "$P" "$p_sp" ENDED);   dur=$(cut -d, -f6 <<<"$r"); (( dur >= 8 && dur <= 11 )) && pass "9 s program (name with a space) measured as ${dur} s" || fail "9 s program" "$r"
r=$(row "$P" "$p_ev" ENDED);   [[ $r == *",_a_b,"* ]] && pass "name '=a,b' neutralised (no comma, no leading =)" || fail "hostile name" "$r"
r=$(row "$P" "$p_kill" ENDED); dur=$(cut -d, -f6 <<<"$r"); [[ -n $r ]] && (( dur >= 3 && dur <= 7 )) && pass "kill -9 program recorded as ENDED after ${dur} s" || fail "killed program" "$r"
r=$(row "$P" "$p_stay" STOPPED); [[ -n $r ]] && pass "program still running at stop is saved as STOPPED" || fail "STOPPED row"
start=$(date -u -d "$(cut -d, -f4 <<<"$(row "$P" "$p_ar" ENDED)")" +%s)
d=$((start - t0)); d=${d#-}; (( d <= 4 )) && pass "start time within ${d} s of reality" || fail "start time" "off by $d"
eq "no logger helper (ps/sleep of the daemon) is logged" 0 "$(col "$P" 3 | grep -cx -E 'ps')"
eq "no duplicate (session, pid, start)" 0 "$(awk -F, 'NR>1{k=$1"|"$2"|"$4; c[k]++} END{n=0; for(k in c) if(c[k]>1) n++; print n}' "$P")"
eq "every row has 7 fields" 1 "$(awk -F, 'NR>1{print NF}' "$P" | sort -u | wc -l)"
eq "processes.csv starts with a UTF-8 BOM" efbbbf "$(head -c3 "$P" | od -An -tx1 | tr -d ' \n')"
eq "session closed COMPLETED" 1 "$(grep -c ',COMPLETED$' "$S")"
eq "session user is the real user" "$(id -un)" "$(col "$S" 2 | head -n1)"
eq "data dir is 700, files 600" "700 600 600" "$(stat -c %a "$CAL_DATA") $(stat -c %a "$S") $(stat -c %a "$P")"

section "4. crash recovery"
echo yes | "$CAL" start >/dev/null; sleep 3
kill -KILL "$(<"$CAL_DATA/.pid")"; sleep 1
eq "after kill -9 the logger is seen as stopped" "Stopped." "$("$CAL" status | head -n1)"
"$CAL" start >/dev/null; sleep 2
eq "the next start closes the dead session as CRASHED" 1 "$(grep -c ',CRASHED$' "$S")"
"$CAL" stop >/dev/null
eq "sessions: 1 COMPLETED + 1 CRASHED + 1 COMPLETED" "COMPLETED CRASHED COMPLETED" "$(col "$S" 6 | tr '\n' ' ' | sed 's/ $//')"

section "5. report"
out=$("$CAL" report); rc=$?
eq "report succeeds" 0 "$rc"
case $out in *"Sessions: 3"*) pass "summary counts the 3 sessions" ;; *) fail "session count" "$out" ;; esac
case $out in *"برنامج"*) pass "Arabic program appears in the summary" ;; *) fail "Arabic in summary" ;; esac
eq "report.csv: BOM + 5 columns" "efbbbf 5" "$(head -c3 "$CAL_DATA/report.csv" | od -An -tx1 | tr -d ' \n') $(sed -n 2p "$CAL_DATA/report.csv" | tr -d '\r' | awk -F, '{print NF}')"

section "6. 15 start/stop cycles never crash the logger (regression: a child process inside the TERM trap)"
rm -rf "$CAL_DATA"; echo yes | "$CAL" start >/dev/null; "$CAL" stop >/dev/null
for i in $(seq 15); do "$CAL" start >/dev/null; sleep 1; sleep 1 & sleep 1 & wait; "$CAL" stop >/dev/null; done
eq "all sessions COMPLETED" 16 "$(grep -c ',COMPLETED$' "$S")"
eq "no abort message in cal.log" 0 "$(grep -c . "$CAL_DATA/cal.log" 2>/dev/null)"

section "7. purge"
"$CAL" purge </dev/null >/dev/null 2>&1; [[ -e $S ]] && pass "purge without 'yes' deletes nothing" || fail "purge cancelled"
echo yes | "$CAL" purge >/dev/null; [[ ! -e $S && ! -e $CAL_DATA/.consent ]] && pass "purge deletes data and consent" || fail "purge"

section "8. autostart at login (one line in ~/.profile)"
H="$SB/home"; mkdir -p "$H"; printf 'export KEEP_ME=1\n' >"$H/.profile"
echo yes | "$CAL" start >/dev/null; "$CAL" stop >/dev/null
HOME=$H "$CAL" autostart on >/dev/null
eq "autostart on adds exactly one line" 1 "$(grep -c '# cal-logger' "$H/.profile")"
HOME=$H "$CAL" autostart on >/dev/null; eq "...and doing it twice does not add another" 1 "$(grep -c '# cal-logger' "$H/.profile")"
HOME=$H bash -l -c true; sleep 2
out=$("$CAL" status); [[ $out == Running* ]] && pass "logging in (a login shell) starts the logger by itself" || fail "login shell start" "$out"
HOME=$H bash -l -c true; sleep 1
eq "a second login does not start a second logger" 1 "$(pgrep -fc "^bash $CAL run\$")"
"$CAL" stop >/dev/null
HOME=$H "$CAL" autostart off >/dev/null
eq "autostart off removes the line" 0 "$(grep -c '# cal-logger' "$H/.profile")"
eq "...and leaves your own lines alone" "export KEEP_ME=1" "$(cat "$H/.profile")"

printf '\n%d checks, %d failed\n' "$TOTAL" "$FAILS"
exit $((FAILS > 0))
