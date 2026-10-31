#!/usr/bin/env bash
# =============================================================================
# lib/collector.sh — Take a snapshot of the user's running processes
# -----------------------------------------------------------------------------
# Source of truth: a single `ps` call, restricted to the current user.
#   ps -u UID -o pid=,ppid=,etimes=,tty=,comm=
# Only the process *name* (comm) is read — never arguments or environment.
#
# Process identity = PID + start_mono, where
#     start_mono = (uptime now) - etimes
# is monotonic (immune to clock changes) and stays constant for the life of
# the process, which protects us from PID reuse.
# =============================================================================

# CUR[pid] = "pid<TAB>ppid<TAB>start_mono<TAB>start_epoch<TAB>tty<TAB>comm"
declare -gA CUR=()
COLLECTOR_UPTIME=0
COLLECTOR_EPOCH=0

# collector_snapshot — fill CUR. Returns 1 (leaving the previous state alone)
# when ps fails or returns nothing, so a glitch can never look like
# "every process ended".
collector_snapshot() {
    local out pid ppid etimes tty comm start_mono start_epoch rec
    local up now
    common_uptime up
    common_now_epoch now
    out=$(LC_ALL=C ps -u "$EUID" -o pid=,ppid=,etimes=,tty=,comm= 2>/dev/null) || return 1
    if [[ -z $out ]]; then return 1; fi

    COLLECTOR_UPTIME=$up
    COLLECTOR_EPOCH=$now
    CUR=()
    # `comm` is the LAST column: read puts the remainder (names with spaces,
    # e.g. "Web Content") into it.
    while read -r pid ppid etimes tty comm; do
        if ! [[ $pid =~ ^[0-9]+$ && $etimes =~ ^[0-9]+$ ]]; then continue; fi
        # Skip the logger itself and its direct children (sleep fallback...).
        if [[ $pid == "$$" || $ppid == "$$" ]]; then continue; fi
        # Skip kernel threads: kthreadd is PID 2 and every kernel thread is its child.
        if [[ $pid == 2 || $ppid == 2 ]]; then continue; fi
        # Skip the `ps` we just launched (it is always < 2 s old).
        if [[ $comm == ps ]] && (( etimes <= 1 )); then continue; fi
        comm=${comm//[[:cntrl:]]/?}
        start_mono=$(( up - etimes ))
        start_epoch=$(( now - etimes ))
        printf -v rec '%s\t%s\t%s\t%s\t%s\t%s' \
            "$pid" "$ppid" "$start_mono" "$start_epoch" "$tty" "$comm"
        CUR[$pid]=$rec
    done <<<"$out"
    return 0
}
