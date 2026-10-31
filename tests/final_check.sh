#!/usr/bin/env bash
# =============================================================================
# tests/final_check.sh — the acceptance run: a fresh clone of the COMMITTED code, driven
# exactly like the README says (default paths, no test overrides), end to end.
#   1. docs vs code: every ./main.sh command and every script path the docs mention exists
#   2. README "Quick start" flow in the clone: doctor, consent, start, apps, stop, stats, report
#   3. installer flow under a real systemd user manager (tests/usermgr.sh): install.sh,
#      service status, safe stop, uninstall.sh      (skipped loudly if no manager can be had)
#   4. nothing leaked: no daemon, no files with loose permissions
# Usage: bash tests/final_check.sh        (run from any directory; needs a git checkout)
# =============================================================================
set -u -o pipefail

SRC="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
WORK="$(mktemp -d)"
FAILS=0 TOTAL=0
pass() { TOTAL=$(( TOTAL + 1 )); printf '  PASS  %s\n' "$1"; }
fail() { TOTAL=$(( TOTAL + 1 )); FAILS=$(( FAILS + 1 )); printf '  FAIL  %s\n' "$1"; [[ -n ${2-} ]] && printf '        %s\n' "$2"; }
check() { local d=$1; shift; if "$@" >/dev/null 2>&1; then pass "$d"; else fail "$d" "command failed: $*"; fi; }
eq() { if [[ $2 == "$3" ]]; then pass "$1"; else fail "$1" "expected [$2] actual [$3]"; fi; }
section() { printf '\n== %s ==\n' "$1"; }

# shellcheck source=/dev/null
source "$SRC/tests/usermgr.sh"
KIDS=()
cleanup() { local p; for p in "${KIDS[@]}"; do kill -KILL "$p" 2>/dev/null || true; done
            [[ -x ${CLONE-}/main.sh ]] && "$CLONE/main.sh" stop >/dev/null 2>&1; um_cleanup; rm -rf -- "$WORK"; }
trap cleanup EXIT

section "0. fresh clone of the committed code"
CLONE="$WORK/Computer-Activity-Logger"
git clone -q --local "$SRC" "$CLONE" 2>/dev/null && pass "git clone of $(git -C "$SRC" rev-parse --short HEAD)" || { fail "git clone"; exit 1; }
if [[ -n $(git -C "$SRC" status --porcelain) ]]; then echo "  note: the working tree has UNCOMMITTED changes; the clone tests the commit only"; fi
for f in README.md PROJECT_DOCUMENTATION.md TEST_REPORT.md CHANGELOG.md FINAL_SUMMARY.md; do check "$f exists in the clone" test -s "$CLONE/$f"; done
for f in main.sh install/install.sh install/uninstall.sh tests/run_all.sh; do check "$f is executable" test -x "$CLONE/$f"; done

section "1. docs vs code"
usage=$("$CLONE/main.sh" help 2>&1)
cmds=$(grep -ohE '\./main\.sh [a-z][a-z-]*' "$CLONE/README.md" "$CLONE/PROJECT_DOCUMENTATION.md" "$CLONE/FINAL_SUMMARY.md" | awk '{print $2}' | sort -u)
bad=""
for c in $cmds; do
    case $c in
        consent|start|stop|status|daemon|service|sessions|processes|stats|report|purge|doctor|version|help|rotate-logs) ;;
        *) bad+="$c " ;;
    esac
    if [[ $c != rotate-logs && $usage != *"$c"* ]]; then bad+="(not in help: $c) "; fi
done
eq "every './main.sh <command>' named in the docs exists ($(wc -w <<<"$cmds") commands)" "" "$bad"
svc=$(grep -ohE '\./main\.sh service [a-z-]+' "$CLONE/README.md" | awk '{print $3}' | sort -u)
sbad=""; for s in $svc; do "$CLONE/main.sh" service help | grep -q "$s" || sbad+="$s "; done
eq "every './main.sh service <x>' in the README exists" "" "$sbad"
for p in $(grep -ohE 'install/[a-z.-]+\.sh|tests/[a-z_]+\.sh' "$CLONE/README.md" "$CLONE/PROJECT_DOCUMENTATION.md" | sort -u); do check "path mentioned in the docs exists: $p" test -f "$CLONE/$p"; done

section "2. README quick start, default paths, in the clone"
printf 'INTERVAL_SEC=1\nMIN_DURATION_SEC=1\n' >"$CLONE/config.local.sh"; chmod 600 "$CLONE/config.local.sh"
M="$CLONE/main.sh"
check "doctor" "$M" doctor
out=$("$M" start 2>&1); rc=$?; eq "start without consent is refused" 1 "$rc"
check "consent --accept" "$M" consent --accept
check "start" "$M" start
check "status shows the daemon" bash -c "'$M' status | grep -q 'running'"
out=$("$M" start 2>&1); eq "a second start does not start a second daemon" "Already running" "${out:0:15}"
cp "$(command -v sleep)" "$WORK/finalapp"
"$WORK/finalapp" 4 & KIDS+=("$!")
"$WORK/finalapp" 6 & KIDS+=("$!")
sleep 3
check "processes --running lists the test app" bash -c "'$M' processes --running | grep -q finalapp"
sleep 6
check "processes lists the finished apps" bash -c "'$M' processes --tail 30 | grep -q finalapp"
check "sessions shows the ACTIVE session" bash -c "'$M' sessions | grep -q ACTIVE"
check "stop" "$M" stop
eq "no daemon left" 0 "$(pgrep -f -c -- "$CLONE/main.sh daemon" || true)"
eq "session closed COMPLETED" 1 "$(grep -c ',COMPLETED$' "$CLONE/data/sessions.csv")"
eq "both test apps recorded as COMPLETED" 2 "$(grep -c '"finalapp".*COMPLETED$' "$CLONE/data/processes.csv")"
check "sessions --check" "$M" sessions --check
check "processes --check" "$M" processes --check
check "stats runs" "$M" stats
check "report" "$M" report
check "report verify" "$M" report verify
check "report daily" "$M" report daily
check "report list" "$M" report list
eq "report set = 3 CSVs + manifest" 4 "$(find "$CLONE/reports/period" -name '*.csv' | wc -l)"
eq "no file in data/state/reports is looser than 600/700" 0 "$(find "$CLONE/data" "$CLONE/state" "$CLONE/reports" -name .gitkeep -prune -o \( \( -type f -a \! -perm 600 \) -o \( -type d -a \! -perm 700 \) \) -print | wc -l)"
eq "git ignores the runtime data (clone stays clean)" "" "$(git -C "$CLONE" status --porcelain | grep -v 'config.local.sh' || true)"
check "purge --before an old date keeps current data" "$M" purge --before 2000-01-01 --yes
eq "...rows still there" 1 "$([[ $(grep -c '' "$CLONE/data/processes.csv") -gt 2 ]] && echo 1 || echo 0)"
check "purge --all --yes" "$M" purge --all --yes
eq "...data gone" 0 "$([[ -e $CLONE/data/sessions.csv ]] && echo 1 || echo 0)"
check "consent --revoke" "$M" consent --revoke
out=$("$M" start 2>&1); eq "start after revoke is refused" 1 "$?"

section "3. installer under a real systemd user manager"
if ! um_detect; then echo "  SKIP  $UM_WHY"; SKIPPED=1
elif ! um_setup "$WORK"; then fail "start a systemd user manager" "$(tail -n 3 "$UM_LOG" 2>/dev/null)"; SKIPPED=1
else
    SKIPPED=0
    P="$UM_HOME/Computer-Activity-Logger"
    cp -r "$CLONE" "$P"; rm -rf "$P/data" "$P/state" "$P/reports" "$P/.consent"; printf 'INTERVAL_SEC=1\nMIN_DURATION_SEC=1\n' >"$P/config.local.sh"; chmod 600 "$P/config.local.sh"
    [[ $UM_MODE == private ]] && chown -R "$UM_USER" "$P"
    um_run "$P/install/install.sh" --bogus >/dev/null 2>&1; eq "install.sh rejects an unknown option" 1 "$?"
    out=$(um_run "$P/install/install.sh" --accept 2>&1); rc=$?
    eq "install.sh --accept succeeds" 0 "$rc"
    [[ $rc -ne 0 ]] && echo "$out" | tail -n 8
    eq "service is active after install.sh" active "$(um_ctl is-active cal.service)"
    eq "service is enabled" enabled "$(um_ctl is-enabled cal.service)"
    st=$(um_run "$P/main.sh" service status 2>&1); eq "service status rc 0" 0 "$?"
    case $st in *"active (running)"*"Logger      : RUNNING"*) pass "status text shows running" ;; *) fail "status text" "$st" ;; esac
    um_run "$P/main.sh" service restart >/dev/null 2>&1; eq "service restart" 0 "$?"
    um_run "$P/main.sh" service stop >/dev/null 2>&1; eq "service stop" 0 "$?"
    eq "stopped: nothing runs" 0 "$(pgrep -f -c -- "$P/main.sh daemon" || true)"
    eq "sessions closed (no ACTIVE row)" 0 "$(grep -c ',ACTIVE$' "$P/data/sessions.csv")"
    um_run "$P/install/uninstall.sh" >/dev/null 2>&1; eq "uninstall.sh succeeds" 0 "$?"
    eq "unit file removed" 0 "$([[ -e $UM_HOME/.config/systemd/user/cal.service ]] && echo 1 || echo 0)"
    eq "data kept after uninstall" 1 "$([[ -s $P/data/sessions.csv ]] && echo 1 || echo 0)"
fi

section "4. nothing leaked"
eq "no logger process left anywhere" 0 "$(pgrep -f -c -- '^(/usr/bin/)?bash .*/main\.sh daemon$' || true)"

printf '\n%d checks, %d failed' "$TOTAL" "$FAILS"; [[ ${SKIPPED:-0} == 1 ]] && printf ' (section 3 skipped)'; printf '\n'
exit $(( FAILS > 0 ))
