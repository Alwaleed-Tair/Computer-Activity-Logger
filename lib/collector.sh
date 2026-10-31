#!/usr/bin/env bash
# =============================================================================
# lib/collector.sh — Take a snapshot of the user's running processes
# -----------------------------------------------------------------------------
# One `ps` call per scan, restricted to the CURRENT user (no sudo, other
# users' processes are never read):
#   ps -u UID -o pid=,ppid=,etimes=,tty=,user:32=,cputimes=,rss=,comm=
#
# What is read, per process:
#   PID, PPID, process name (comm), username, TTY, CPU seconds, resident memory
#   and the elapsed time (-> start time). NEVER the command-line arguments or
#   the environment.
#
# Process identity = PID + start_mono, where
#     start_mono = (uptime now) - etimes
# is monotonic (immune to clock changes) and constant for the life of the
# process. Linux reuses PIDs, but a reused PID always has a different
# start_mono, so two processes are never confused.
#
# The snapshot is stored in parallel associative arrays indexed by PID (cheap
# plain assignments; no per-process string building in the hot path).
# =============================================================================

declare -gA CUR_START=()    # pid -> start_mono (seconds since boot)
declare -gA CUR_ETIMES=()   # pid -> seconds since the process started
declare -gA CUR_PPID=()
declare -gA CUR_TTY=()
declare -gA CUR_USER=()
declare -gA CUR_COMM=()     # process name (kernel comm, max 15 chars)
declare -gA CUR_CPU=()      # cumulative CPU seconds
declare -gA CUR_RSS=()      # resident memory, KiB
declare -gA _OWN=()         # pid -> 1/0 memo for collector_is_own (per scan)
COLLECTOR_UPTIME=0
COLLECTOR_EPOCH=0

# collector_snapshot — fill the CUR_* arrays. Returns 1 (leaving the previous
# state untouched) when ps fails or returns nothing, so a glitch can never
# look like "every process ended".
collector_snapshot() {
    local out pid ppid etimes tty user cpu rss comm up now
    common_uptime up
    common_now_epoch now
    out=$(LC_ALL=C ps -u "$EUID" -o pid=,ppid=,etimes=,tty=,user:32=,cputimes=,rss=,comm= 2>/dev/null) || return 1
    if [[ -z $out ]]; then return 1; fi

    COLLECTOR_UPTIME=$up
    COLLECTOR_EPOCH=$now
    CUR_START=(); CUR_ETIMES=(); CUR_PPID=(); CUR_TTY=(); CUR_USER=(); CUR_COMM=()
    CUR_CPU=(); CUR_RSS=(); _OWN=()
    # `comm` is the LAST column: read puts the remainder (names with spaces,
    # e.g. "Web Content") into it.
    while read -r pid ppid etimes tty user cpu rss comm; do
        if ! [[ $pid =~ ^[0-9]+$ && $etimes =~ ^[0-9]+$ ]]; then continue; fi
        # Skip kernel threads: kthreadd is PID 2 and every kernel thread is its child.
        if [[ $pid == 2 || $ppid == 2 ]]; then continue; fi
        CUR_START[$pid]=$(( up - etimes ))
        CUR_ETIMES[$pid]=$etimes
        CUR_PPID[$pid]=$ppid
        CUR_TTY[$pid]=$tty
        CUR_USER[$pid]=$user
        CUR_COMM[$pid]=${comm//[[:cntrl:]]/?}
        CUR_CPU[$pid]=${cpu//[^0-9]/}
        CUR_RSS[$pid]=${rss//[^0-9]/}
    done <<<"$out"
    return 0
}

# collector_is_own PID — true when PID is the logger itself or one of its
# descendants (ps, awk, flock... that it spawns). Those are never monitored.
# Result is memoised for the current scan.
collector_is_own() {
    local p=$1 depth=0 chain="" r
    while (( depth < 32 )); do
        if [[ -n ${_OWN[$p]+x} ]]; then r=${_OWN[$p]}; break; fi
        if [[ $p == "$$" ]]; then r=1; break; fi
        chain+=" $p"
        p=${CUR_PPID[$p]-}
        if [[ -z $p || $p == 0 || $p == 1 ]]; then r=0; break; fi
        depth=$(( depth + 1 ))
    done
    r=${r:-0}
    for p in $chain; do _OWN[$p]=$r; done
    (( r == 1 ))
}

# collector_load_exe PID... — print "pid<TAB>basename-of-executable" for every PID
# whose /proc/PID/exe link is readable. ONE `stat` call for the whole batch
# (instead of a fork per process). The path is reduced to its base name.
collector_exe_names() {
    local line pid path
    if (( $# == 0 )); then return 0; fi
    local -a args=()
    for pid in "$@"; do args+=("/proc/$pid/exe"); done
    while IFS= read -r line; do
        # shellcheck disable=SC2016  # the quotes below are literal characters of stat's output
        if [[ $line =~ ^\'/proc/([0-9]+)/exe\'\ -\>\ \'(.*)\'$ ]]; then
            pid=${BASH_REMATCH[1]}; path=${BASH_REMATCH[2]}
            path=${path% (deleted)}
            printf '%s\t%s\n' "$pid" "${path##*/}"
        fi
    done < <(stat -c %N "${args[@]}" 2>/dev/null || true)   # unreadable links: simply skipped
}
