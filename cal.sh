#!/usr/bin/env bash
# =============================================================================
# cal.sh — Computer Activity Logger (simple version)
# -----------------------------------------------------------------------------
# With your consent it logs, in the background:
#   * sessions  : when the logger started/stopped, and for how long   -> data/sessions.csv
#   * processes : name, start, end and duration of every program      -> data/processes.csv
# and turns them into a summary / Excel-ready report.
# NEVER recorded: keystrokes, passwords, window titles, file or screen contents,
# command-line arguments. Nothing leaves the computer. No root needed.
#
#   ./cal.sh start | stop | status | report | autostart on|off | purge | help
# =============================================================================
set -u -o pipefail
umask 077
export TZ=UTC LC_ALL=C.UTF-8          # every stored time is UTC; UTF-8 so non-Latin names survive
USER=${USER:-$(id -un)}                  # not set in some environments (containers, services)

if (( BASH_VERSINFO[0] < 4 || (BASH_VERSINFO[0] == 4 && BASH_VERSINFO[1] < 3) )); then
    echo "Bash >= 4.3 is required (found $BASH_VERSION)" >&2; exit 1
fi

DIR="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")" && pwd -P)"
DATA="${CAL_DATA:-$DIR/data}"              # all files live here (mode 700)
INTERVAL="${CAL_INTERVAL:-5}"              # seconds between scans (1..60)
SESSIONS="$DATA/sessions.csv"
PROCESSES="$DATA/processes.csv"
REPORT="$DATA/report.csv"
STATE="$DATA/.session"                     # "id start_epoch last_seen_epoch": lets us repair a crash
LOCK="$DATA/.lock"                         # flock: only one logger at a time
PIDFILE="$DATA/.pid"
CONSENT="$DATA/.consent"

[[ $INTERVAL =~ ^[0-9]+$ ]] && (( INTERVAL >= 1 && INTERVAL <= 60 )) || { echo "CAL_INTERVAL must be 1..60" >&2; exit 1; }

# Plumbing that is always there and not interesting (override: CAL_IGNORE="name1 name2 ...").
IGNORE=" ${CAL_IGNORE:-bash sh dash zsh fish systemd (sd-pam) dbus-daemon dbus-broker ssh-agent gpg-agent} "

SESSIONS_HEADER="Session,User,Start_UTC,End_UTC,Seconds,Status"
PROCESSES_HEADER="Session,PID,Name,Start_UTC,End_UTC,Seconds,Status"

# --- small helpers -----------------------------------------------------------------
stamp()  { printf -v "$1" '%(%Y-%m-%d %H:%M:%S)T' "$2"; }          # epoch -> "YYYY-MM-DD HH:MM:SS" (UTC)
epoch()  { printf -v "$1" '%(%s)T' -1; }
uptime_s() { local u _; read -r u _ </proc/uptime; printf -v "$1" '%s' "${u%.*}"; }
new_csv() { [[ -s $1 ]] || printf '\xEF\xBB\xBF%s\n' "$2" >"$1"; }   # UTF-8 BOM: Excel shows Arabic correctly
# A name must not be able to break the CSV or become an Excel formula.
clean()  { local s=${1//[^[:alnum:]_.+ -]/_}; case $s in [=+@-]*) s="'$s" ;; esac; printf -v "$2" '%s' "$s"; }
# Is the logger alive? pid file + /proc check (no child process: an external helper would itself be logged).
# A killed logger can linger as a zombie until it is reaped: that is not "running".
running() {
    local p l
    read -r p 2>/dev/null <"$PIDFILE" || return 1
    [[ $p =~ ^[0-9]+$ ]] && mapfile -t -n 4 l 2>/dev/null <"/proc/$p/status" && [[ ${l[0]:-} == *[[:space:]]bash && "${l[*]}" != *zombie* ]]
}
# Waiting without an external `sleep` (the logger would record that sleep as a process).
nap()    { [[ -n ${NAPFD:-} ]] || exec {NAPFD}<> <(:); read -r -t "$1" -u "$NAPFD" _ || true; }

# =============================================================================
# The background logger (what `start` launches; run it yourself with `./cal.sh run`)
# =============================================================================
declare -A T_MONO=() T_EPOCH=() T_NAME=()   # tracked processes, by pid: start (uptime s), start (epoch), name
SID="" S_EPOCH=0 STOP=0 FINISHED=0

log_session() {   # log_session ID START END STATUS
    local a b
    stamp a "$2"; stamp b "$3"
    printf '%s,%s,%s,%s,%s,%s\n' "$1" "$USER" "$a" "$b" "$(( $3 - $2 ))" "$4" >>"$SESSIONS"
}

log_process() {   # log_process PID STATUS NOW_MONO
    local pid=$1 dur a b
    dur=$(( $3 - T_MONO[$pid] )); (( dur < 0 )) && dur=0
    stamp a "${T_EPOCH[$pid]}"; stamp b $(( T_EPOCH[$pid] + dur ))
    printf '%s,%s,%s,%s,%s,%s,%s\n' "$SID" "$pid" "${T_NAME[$pid]}" "$a" "$b" "$dur" "$2" >>"$PROCESSES"
    unset 'T_MONO[$pid]' 'T_EPOCH[$pid]' 'T_NAME[$pid]'
}

scan() {
    local out up now pid ppid et comm name d p n
    local -A c_mono=() c_name=() c_ppid=() c_comm=()
    out=$(ps -u "$EUID" -o pid=,ppid=,etimes=,comm= 2>/dev/null) || return 0
    [[ -n $out ]] || return 0                         # a failed scan must never look like "everything ended"
    uptime_s up; epoch now
    while read -r pid ppid et comm; do
        [[ $pid =~ ^[0-9]+$ && $et =~ ^[0-9]+$ ]] || continue
        (( pid == 2 || ppid == 2 )) && continue       # kernel threads
        clean "$comm" name
        c_mono[$pid]=$(( up - et )); c_name[$pid]=$name; c_ppid[$pid]=$ppid; c_comm[$pid]=$comm
    done <<<"$out"
    for pid in "${!c_mono[@]}"; do                    # drop ourselves, everything we spawned (ps, sleep, subshells) and the ignored plumbing
        p=$pid; n=0
        while (( p != $$ && n++ < 10 )) && [[ -n ${c_ppid[$p]:-} ]]; do p=${c_ppid[$p]}; done
        if (( p == $$ )) || [[ $IGNORE == *" ${c_comm[$pid]} "* ]]; then unset 'c_mono[$pid]' 'c_name[$pid]'; fi
    done
    # 1) tracked processes that are gone (or whose PID now belongs to another process) -> one row each
    for pid in "${!T_MONO[@]}"; do
        if [[ -z ${c_mono[$pid]+x} ]]; then log_process "$pid" ENDED "$up"; continue; fi
        d=$(( c_mono[$pid] - T_MONO[$pid] )); (( d < 0 )) && d=$(( -d ))
        (( d > 2 )) && log_process "$pid" ENDED "$up"   # identity = PID + start time (2 s of rounding jitter allowed)
    done
    # 2) new processes -> start tracking (the real start time comes from the OS: now - elapsed)
    for pid in "${!c_mono[@]}"; do
        [[ -n ${T_MONO[$pid]+x} ]] && continue
        T_MONO[$pid]=${c_mono[$pid]}; T_NAME[$pid]=${c_name[$pid]}
        T_EPOCH[$pid]=$(( now - (up - c_mono[$pid]) ))
    done
    printf '%s %s %s\n' "$SID" "$S_EPOCH" "$now" >"$STATE"   # "last seen": used to repair the session after a crash
}

finish() {   # runs on exit: save everything that is still open
    local up now pid
    (( FINISHED )) && return; FINISHED=1
    uptime_s up; epoch now
    for pid in "${!T_MONO[@]}"; do log_process "$pid" STOPPED "$up"; done   # still running when we stopped
    [[ -n $SID ]] && log_session "$SID" "$S_EPOCH" "$now" COMPLETED
    rm -f -- "$STATE" "$PIDFILE"
}

run_daemon() {
    local id start last
    mkdir -p -m 700 "$DATA"
    [[ -e $CONSENT ]] || { echo "No consent recorded: run ./cal.sh start first." >&2; exit 1; }
    exec 9>"$LOCK"
    flock -n 9 || { echo "Another logger is already running." >&2; exit 1; }
    echo $$ >"$PIDFILE"
    new_csv "$SESSIONS" "$SESSIONS_HEADER"; new_csv "$PROCESSES" "$PROCESSES_HEADER"
    if read -r id start last 2>/dev/null <"$STATE" && [[ $start =~ ^[0-9]+$ && $last =~ ^[0-9]+$ ]]; then
        log_session "$id" "$start" "$last" CRASHED       # the previous run died: its end is the last time it was seen
    fi
    epoch S_EPOCH
    SID="$(printf '%(%Y%m%dT%H%M%SZ)T' "$S_EPOCH")-$$"
    trap 'STOP=1' TERM INT HUP                           # handlers only set a flag (nothing else is safe inside a trap)
    trap finish EXIT
    while (( STOP == 0 )); do
        scan
        sleep "$INTERVAL" 9>&- & SLEEP_PID=$!            # 9>&- : the sleep must not inherit the lock
        wait "$SLEEP_PID" || true
        (( STOP )) && kill "$SLEEP_PID" 2>/dev/null
    done
    exit 0
}

# =============================================================================
# Commands
# =============================================================================
ask_consent() {
    cat <<EOF
This program will record, for user '$USER' only:
  - when each logging session starts and ends
  - the NAME of each program you run, with its start time, end time and duration
It will NEVER record keystrokes, passwords, window titles, file/screen contents or command-line arguments,
and it sends nothing over the network. Data lives in: $DATA
Stop any time: ./cal.sh stop     Delete everything: ./cal.sh purge
EOF
    local ans; read -r -p "Do you agree? Type 'yes' to continue: " ans
    [[ $ans == yes ]] || { echo "No consent given: nothing was started."; return 1; }
    mkdir -p -m 700 "$DATA"; date -u +%FT%TZ >"$CONSENT"
}

cmd_start() {
    local i
    mkdir -p -m 700 "$DATA"
    [[ -e $CONSENT ]] || ask_consent || exit 1
    if running; then echo "Already running (pid $(<"$PIDFILE"))."; return 0; fi
    nohup setsid "$DIR/cal.sh" run >>"$DATA/cal.log" 2>&1 </dev/null &
    for (( i = 0; i < 25; i++ )); do running && break; nap 0.2; done
    if running; then echo "Started (pid $(<"$PIDFILE"))."; else echo "Failed to start: see $DATA/cal.log" >&2; exit 1; fi
}

cmd_stop() {
    local pid i
    running || { echo "Not running."; return 0; }
    pid=$(<"$PIDFILE"); kill -TERM "$pid" 2>/dev/null
    for (( i = 0; i < 75; i++ )); do running || { echo "Stopped (everything saved)."; return 0; }; nap 0.2; done
    kill -KILL "$pid" 2>/dev/null; echo "Did not stop in 15 s: killed. The unfinished session is repaired at the next start." >&2
}

cmd_status() {
    local id start last
    if running; then
        echo "Running (pid $(<"$PIDFILE"))."
        if read -r id start last 2>/dev/null <"$STATE"; then stamp start "$start"; echo "Session $id since $start UTC."; fi
    else
        echo "Stopped."
    fi
    grep -qs "# cal-logger" "$HOME/.profile" "$HOME/.bash_profile" && echo "Autostart: on (starts when you log in)." || echo "Autostart: off."
    [[ -s $PROCESSES ]] && echo "Logged so far: $(( $(grep -c '' "$PROCESSES") - 1 )) processes, $(( $(grep -c '' "$SESSIONS") - 1 )) sessions in $DATA"
}

cmd_report() {
    [[ -s $PROCESSES ]] || { echo "Nothing logged yet. Run ./cal.sh start first."; return 0; }
    printf '\xEF\xBB\xBF%s\r\n' "Name,Runs,Total_Seconds,Longest_Seconds,Average_Seconds" >"$REPORT"
    LC_ALL=C awk -F, 'NR > 1 { n[$3]++; t[$3] += $6; if ($6 > m[$3]) m[$3] = $6 }
        END { for (k in n) printf "%s,%d,%d,%d,%.1f\r\n", k, n[k], t[k], m[k], t[k] / n[k] }' "$PROCESSES" \
        | LC_ALL=C sort -t, -k3,3nr >>"$REPORT"
    LC_ALL=C awk -F, 'NR > 1 { s++; t += $5; if ($6 == "CRASHED") c++ }
        END { printf "Sessions: %d   total logged time: %d s (%d min)%s\n", s, t, t / 60, c ? "   (" c " ended by a crash: end time estimated)" : "" }' "$SESSIONS"
    LC_ALL=C awk -F, 'NR > 1 { p++ } END { printf "Processes logged: %d\n", p }' "$PROCESSES"
    echo "Top programs by total seconds (processes that run at the same time add up, so this is not usage time):"
    tail -n +2 "$REPORT" | tr -d '\r' | head -n 10 | LC_ALL=C awk -F, 'BEGIN { printf "  %-28s %6s %12s %10s\n", "Name", "Runs", "Total_s", "Longest_s" }
        { printf "  %-28s %6d %12d %10d\n", $1, $2, $3, $4 }'
    echo "Excel file: $REPORT"
}

# Start at login = one line in your login script (~/.profile). `start` does nothing if it is already running.
cmd_autostart() {
    local f="$HOME/.profile"; [[ -e $HOME/.bash_profile ]] && f="$HOME/.bash_profile"
    case ${1:-} in
        on)
            [[ -e $CONSENT ]] || { echo "Run ./cal.sh start once first (it asks for your consent)." >&2; exit 1; }
            case $DIR in *[\"\$\`\\]*) echo "Unsupported characters in the installation path." >&2; exit 1 ;; esac
            grep -qs '# cal-logger' "$f" || printf '"%s/cal.sh" start </dev/null >/dev/null 2>&1   # cal-logger\n' "$DIR" >>"$f"
            echo "Autostart on: it starts when you log in (line added to $f)." ;;
        off)
            [[ -e $f ]] && sed -i '/# cal-logger$/d' "$f"
            echo "Autostart off." ;;
        *) echo "usage: ./cal.sh autostart on|off" >&2; exit 1 ;;
    esac
}

cmd_purge() {
    local ans
    running && { echo "Stop it first: ./cal.sh stop" >&2; exit 1; }
    read -r -p "Delete ALL logged data and your consent in $DATA ? Type 'yes': " ans
    [[ $ans == yes ]] || { echo "Cancelled."; return 0; }
    rm -f -- "$SESSIONS" "$PROCESSES" "$REPORT" "$STATE" "$PIDFILE" "$CONSENT" "$LOCK" "$DATA/cal.log"
    rmdir "$DATA" 2>/dev/null; echo "Deleted."
}

usage() {
    cat <<'EOF'
Computer Activity Logger — logs which programs you run and for how long (with your consent).

  ./cal.sh start        start logging in the background (asks for consent the first time)
  ./cal.sh stop         stop (everything is saved)
  ./cal.sh status       is it running?
  ./cal.sh report       summary in the terminal + data/report.csv for Excel
  ./cal.sh autostart on|off   start automatically when you log in (adds one line to ~/.profile)
  ./cal.sh purge        delete all logged data and the consent
Files: data/sessions.csv, data/processes.csv   Scan interval: CAL_INTERVAL=5 (seconds)
EOF
}

case ${1:-help} in
    run)       run_daemon ;;
    start)     cmd_start ;;
    stop)      cmd_stop ;;
    status)    cmd_status ;;
    report)    cmd_report ;;
    autostart) shift; cmd_autostart "${1:-}" ;;
    purge)     cmd_purge ;;
    help|-h|--help) usage ;;
    *) echo "unknown command: $1" >&2; usage >&2; exit 1 ;;
esac
