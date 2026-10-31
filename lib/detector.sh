#!/usr/bin/env bash
# =============================================================================
# lib/detector.sh — Compare snapshots: which processes started / ended?
# -----------------------------------------------------------------------------
# ACTIVE holds the processes we are tracking (already filtered & classified).
# Each cycle:  CUR (collector)  vs  ACTIVE  =>  STARTED[] and ENDED[].
#
# Record layout (TAB separated; no field is ever empty):
#   pid  ppid  start_mono  start_epoch  tty  paused  pre  category  app  comm
# =============================================================================

declare -gA ACTIVE=()          # pid -> record
declare -ga STARTED=()         # pids that appeared this cycle
declare -ga ENDED=()           # records of processes that disappeared
declare -gA IGNORE=()          # comm -> 1   (from ignore.list)
declare -gA APPS_NAME=()       # comm -> friendly name (from apps.map)
declare -gA APPS_CAT=()        # comm -> category
DETECTOR_FIRST_CYCLE=1         # first diff: everything found is "pre-session"
DETECTOR_TOLERANCE=2           # seconds of jitter allowed in start_mono

# --- Records -----------------------------------------------------------------

# record_unpack RECORD — fills R_* variables.
record_unpack() {
    IFS=$'\t' read -r R_PID R_PPID R_START_MONO R_START_EPOCH R_TTY \
        R_PAUSED R_PRE R_CAT R_APP R_COMM <<<"$1"
}

# record_pack — build a record from the R_* variables into REPLY.
record_pack() {
    printf -v REPLY '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$R_PID" "$R_PPID" "$R_START_MONO" "$R_START_EPOCH" "$R_TTY" \
        "$R_PAUSED" "$R_PRE" "$R_CAT" "$R_APP" "$R_COMM"
}

# --- Configuration lists -----------------------------------------------------

# detector_load_lists — read ignore.list and apps.map (comments with '#').
#   ignore.list : one process name per line
#   apps.map    : comm|Friendly Name|category
detector_load_lists() {
    local line comm name cat
    IGNORE=(); APPS_NAME=(); APPS_CAT=()
    if [[ -r $IGNORE_FILE ]]; then
        while IFS= read -r line || [[ -n $line ]]; do
            line=${line%%#*}
            common_trim "$line"
            if [[ -n $REPLY ]]; then IGNORE[$REPLY]=1; fi
        done <"$IGNORE_FILE"
    fi
    if [[ -r $APPS_MAP_FILE ]]; then
        while IFS='|' read -r comm name cat || [[ -n $comm ]]; do
            comm=${comm%%#*}
            common_trim "$comm"; comm=$REPLY
            if [[ -z $comm ]]; then continue; fi
            common_trim "${name:-$comm}"; APPS_NAME[$comm]=$REPLY
            common_trim "${cat:-other}"; APPS_CAT[$comm]=$REPLY
        done <"$APPS_MAP_FILE"
    fi
    return 0
}

# detector_classify COMM TTY — sets CLASS_APP and CLASS_CAT.
detector_classify() {
    local comm=$1 tty=$2
    if [[ -n ${APPS_NAME[$comm]+x} ]]; then
        CLASS_APP=${APPS_NAME[$comm]}
        CLASS_CAT=${APPS_CAT[$comm]}
    else
        CLASS_APP=$comm
        if [[ $tty == pts/* || $tty == tty* ]]; then CLASS_CAT=terminal; else CLASS_CAT=other; fi
    fi
}

# --- Diff --------------------------------------------------------------------

# detector_same_process A B — true when two start_mono values are the same
# process (within DETECTOR_TOLERANCE seconds).
detector_same_process() {
    local d=$(( $1 - $2 ))
    if (( d < 0 )); then d=$(( -d )); fi
    (( d <= DETECTOR_TOLERANCE ))
}

# detector_diff — compare CUR against ACTIVE; update ACTIVE, STARTED, ENDED.
detector_diff() {
    local pid rec c_start now_pre
    local ppid start_mono start_epoch tty comm
    STARTED=(); ENDED=()

    # 1) Ended: tracked but gone (or the PID was reused by a different process).
    for pid in "${!ACTIVE[@]}"; do
        rec=${ACTIVE[$pid]}
        record_unpack "$rec"
        if [[ -z ${CUR[$pid]+x} ]]; then
            ENDED+=("$rec"); unset 'ACTIVE[$pid]'
        else
            IFS=$'\t' read -r _ _ c_start _ <<<"${CUR[$pid]}"
            if ! detector_same_process "$R_START_MONO" "$c_start"; then
                ENDED+=("$rec"); unset 'ACTIVE[$pid]'
            fi
        fi
    done

    # 2) Started: present now, not tracked yet, not ignored.
    if (( DETECTOR_FIRST_CYCLE == 1 )); then now_pre=yes; else now_pre=no; fi
    for pid in "${!CUR[@]}"; do
        if [[ -n ${ACTIVE[$pid]+x} ]]; then continue; fi
        IFS=$'\t' read -r _ ppid start_mono start_epoch tty comm <<<"${CUR[$pid]}"
        if [[ -n ${IGNORE[$comm]+x} ]]; then continue; fi
        detector_classify "$comm" "$tty"
        R_PID=$pid; R_PPID=$ppid; R_START_MONO=$start_mono; R_START_EPOCH=$start_epoch
        R_TTY=$tty; R_PAUSED=0; R_PRE=$now_pre; R_CAT=$CLASS_CAT; R_APP=$CLASS_APP; R_COMM=$comm
        record_pack
        ACTIVE[$pid]=$REPLY
        STARTED+=("$pid")
    done
    DETECTOR_FIRST_CYCLE=0
    return 0
}

# detector_add_pause SECONDS — credit a suspend/stop gap to every tracked process.
detector_add_pause() {
    local pid secs=$1
    for pid in "${!ACTIVE[@]}"; do
        record_unpack "${ACTIVE[$pid]}"
        R_PAUSED=$(( R_PAUSED + secs ))
        record_pack
        ACTIVE[$pid]=$REPLY
    done
    return 0
}

# detector_close_all — move every tracked process into ENDED (shutdown path).
detector_close_all() {
    local pid
    ENDED=()
    for pid in "${!ACTIVE[@]}"; do
        ENDED+=("${ACTIVE[$pid]}")
    done
    ACTIVE=()
    return 0
}
