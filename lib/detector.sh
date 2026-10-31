#!/usr/bin/env bash
# =============================================================================
# lib/detector.sh — Which processes started / ended, and what are they?
# -----------------------------------------------------------------------------
# Each scan: the CUR_* arrays (collector) are compared with the tracked
# processes (ACTIVE). Anything gone is finished (ENDED); anything new is
# classified and tracked.
#
# A process is NOT assumed to be an application. Linux apps are usually many
# processes (a browser = main + renderers + GPU helper...), and most processes
# are background plumbing. Two ideas handle this:
#
#  1. Class:  User_Application  vs  Background_Process
#     Decided for the *root* of each process tree, in this order:
#       a) conf/apps.map entry (category "background" forces Background)
#       b) a graphical .desktop entry for that executable  (read-only lookup)
#       c) cgroup: app.slice / app-*.scope = application; *.service,
#          background.slice, session.slice, system.slice = background
#       d) it owns a terminal (pts/N)  = a program the user runs interactively
#       e) otherwise Background_Process
#  2. Application instance: a child process inherits the group of its tracked
#     parent when that parent is a user application (or runs the same program),
#     so a browser's 12 processes are ONE application instance with one root.
#
# Record layout (TAB separated; no field may be empty):
#   1 pid        2 ppid       3 start_mono  4 start_epoch  5 seen_epoch
#   6 tty        7 user       8 paused      9 pre         10 session
#  11 class     12 category  13 group      14 is_root     15 app
#  16 cmd (command name = executable base name)            17 comm (process name)
# =============================================================================

declare -gA ACTIVE=()          # pid -> record
declare -gA ACTIVE_START=()    # pid -> start_mono (fast identity check)
declare -gA MET_CPU=() MET_RSS=() MET_PEAK=()   # pid -> last CPU s / last RSS / peak RSS (KiB)
declare -ga STARTED=()         # pids that appeared this scan
declare -ga ENDED=()           # finished: "cpu<TAB>rss<TAB>peak<TAB>record"
declare -gA IGNORE=()          # comm -> 1   (conf/ignore.list)
declare -gA APPS_NAME=()       # comm|exe -> friendly name   (conf/apps.map)
declare -gA APPS_CAT=()        # comm|exe -> category
declare -gA DESK_NAME=()       # exe -> friendly name         (.desktop files)
declare -gA DESK_CAT=()        # exe -> first desktop category
declare -gA _NEWSET=() _STATE=() _EXE=()        # per-scan scratch
declare -ga _NEW=()
DETECTOR_FIRST_CYCLE=1         # first scan after (re)start: whatever is found is NOT "new"
DETECTOR_TOLERANCE=2           # seconds of jitter allowed in start_mono

# --- Records -----------------------------------------------------------------

# record_unpack RECORD — fills the R_* variables.
record_unpack() {
    IFS=$'\t' read -r R_PID R_PPID R_START_MONO R_START_EPOCH R_SEEN R_TTY R_USER \
        R_PAUSED R_PRE R_SESSION R_CLASS R_CAT R_GROUP R_ROOT R_APP R_CMD R_COMM <<<"$1"
}

# record_pack — build a record from the R_* variables into REPLY.
record_pack() {
    printf -v REPLY '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s' \
        "$R_PID" "$R_PPID" "$R_START_MONO" "$R_START_EPOCH" "$R_SEEN" "${R_TTY:--}" "${R_USER:--}" \
        "$R_PAUSED" "$R_PRE" "${R_SESSION:--}" "$R_CLASS" "${R_CAT:--}" "$R_GROUP" "$R_ROOT" \
        "${R_APP:--}" "${R_CMD:--}" "${R_COMM:--}"
}

# ended_unpack ENDED_ENTRY — sets R_CPU, R_RSS_LAST, R_RSS_PEAK and the R_* record.
ended_unpack() {
    local rest
    IFS=$'\t' read -r R_CPU R_RSS_LAST R_RSS_PEAK rest <<<"$1"
    record_unpack "$rest"
}

# --- Configuration lists -----------------------------------------------------

# detector_load_lists — read ignore.list and apps.map (comments with '#').
#   ignore.list : one process name per line
#   apps.map    : comm|Friendly name|category      (category "background" = not an app)
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

# detector_load_desktop — learn which executables are graphical applications
# from the system's .desktop launchers (Type=Application, not NoDisplay).
# Read-only, done once at start-up with a single awk.
detector_load_desktop() {
    local dir exe name cat
    local -a files=() dirs=()
    DESK_NAME=(); DESK_CAT=()
    IFS=: read -r -a dirs <<<"${DESKTOP_DIRS:-}"
    shopt -s nullglob
    for dir in "${dirs[@]}"; do files+=("$dir"/*.desktop); done
    shopt -u nullglob
    if (( ${#files[@]} == 0 )); then return 0; fi
    while IFS=$'\t' read -r exe name cat; do
        if [[ -z $exe || -n ${DESK_NAME[$exe]+x} ]]; then continue; fi
        DESK_NAME[$exe]=$name
        DESK_CAT[$exe]=${cat,,}
    done < <(LC_ALL=C awk -F= '
        # Emit "<executable>\t<Name>\t<first category>" for the entry just read.
        function flush(   e, n, a, i, c) {
            if (typ == "Application" && nod != "true" && ex != "") {
                if (ex ~ /^"/) { e = ex; sub(/^"/, "", e); sub(/".*$/, "", e) }
                else {
                    n = split(ex, a, " "); i = 1
                    while (i < n && (a[i] == "env" || a[i] ~ /=/)) i++      # skip "env VAR=x"
                    e = a[i]
                }
                sub(/^.*\//, "", e)
                split(cats, c, ";")
                if (e != "") printf "%s\t%s\t%s\n", e, (nm != "" ? nm : e), (c[1] != "" ? c[1] : "application")
            }
            typ = ""; nod = ""; nm = ""; ex = ""; cats = ""
        }
        FNR == 1 { flush(); inent = 0 }
        /^\[/ { inent = ($0 == "[Desktop Entry]"); next }
        !inent { next }
        $1 == "Type"       && typ == ""  { typ = $2 }
        $1 == "NoDisplay"                { nod = tolower($2) }
        $1 == "Name"       && nm == ""   { nm = substr($0, 6) }
        $1 == "Exec"       && ex == ""   { ex = substr($0, 6) }
        $1 == "Categories" && cats == "" { cats = $2 }
        END { flush() }' "${files[@]}" 2>/dev/null)
    return 0
}

# --- Classification ------------------------------------------------------------

# detector_read_cgroup PID — sets CG to the (flattened) content of /proc/PID/cgroup.
# Only the control-group *paths* are read (no arguments, no environment).
detector_read_cgroup() {
    local line
    CG=""
    if [[ -r /proc/$1/cgroup ]]; then
        while IFS= read -r line || [[ -n $line ]]; do CG+="$line "; done </proc/"$1"/cgroup
    fi
    return 0
}

# detector_classify_root COMM CMD TTY CGROUP — sets CLS_CLASS, CLS_CAT, CLS_APP.
detector_classify_root() {
    local comm=$1 cmd=$2 tty=$3 cg=${4-} key=""
    CLS_APP=$cmd
    if [[ -n ${APPS_NAME[$cmd]+x} ]]; then key=$cmd
    elif [[ -n ${APPS_NAME[$comm]+x} ]]; then key=$comm; fi
    if [[ -n $key ]]; then                                   # a) apps.map
        CLS_APP=${APPS_NAME[$key]}; CLS_CAT=${APPS_CAT[$key]}
        if [[ ${CLS_CAT,,} == background ]]; then CLS_CLASS=Background_Process; else CLS_CLASS=User_Application; fi
        return 0
    fi
    if [[ -n ${DESK_NAME[$cmd]+x} ]]; then key=$cmd          # b) graphical launcher
    elif [[ -n ${DESK_NAME[$comm]+x} ]]; then key=$comm; fi
    if [[ -n $key ]]; then
        CLS_APP=${DESK_NAME[$key]}; CLS_CAT=${DESK_CAT[$key]}; CLS_CLASS=User_Application
        return 0
    fi
    case $cg in                                              # c) systemd cgroup
        *"/app.slice/"*|*"/app-"*) CLS_CLASS=User_Application; CLS_CAT=application; return 0 ;;
        *background.slice*|*"/session.slice/"*|*"/system.slice/"*|*.service*)
            CLS_CLASS=Background_Process; CLS_CAT=background; return 0 ;;
    esac
    if [[ $tty == pts/* || $tty == tty* ]]; then             # d) interactive, owns a terminal
        CLS_CLASS=User_Application; CLS_CAT=terminal; return 0
    fi
    CLS_CLASS=Background_Process; CLS_CAT=background         # e) default
}

# --- Tracking ------------------------------------------------------------------

# detector_same_process A B — two start_mono values are the same process
# (within DETECTOR_TOLERANCE seconds of rounding jitter).
detector_same_process() {
    local d=$(( $1 - $2 ))
    if (( d < 0 )); then d=$(( -d )); fi
    (( d <= DETECTOR_TOLERANCE ))
}

# detector_track_record RECORD — start tracking a record (also used by recovery).
detector_track_record() {
    local rec=$1 pid
    record_unpack "$rec"
    pid=$R_PID
    ACTIVE[$pid]=$rec
    ACTIVE_START[$pid]=$R_START_MONO
    MET_CPU[$pid]=${CUR_CPU[$pid]:-0}
    MET_RSS[$pid]=${CUR_RSS[$pid]:-0}
    MET_PEAK[$pid]=${CUR_RSS[$pid]:-0}
}

# _det_finish PID — move a tracked process to ENDED (with its last metrics).
_det_finish() {
    local pid=$1
    ENDED+=("${MET_CPU[$pid]:-0}"$'\t'"${MET_RSS[$pid]:-0}"$'\t'"${MET_PEAK[$pid]:-0}"$'\t'"${ACTIVE[$pid]}")
    unset 'ACTIVE[$pid]' 'ACTIVE_START[$pid]' 'MET_CPU[$pid]' 'MET_RSS[$pid]' 'MET_PEAK[$pid]'
}

# _det_new_record PID — build, classify and track a newly seen process. Parents
# are handled first so children can join their application group.
_det_new_record() {
    local pid=$1 ppid comm tty cmd start_epoch
    local inherit=0 p_class="" p_cat="" p_group="" p_app=""
    if [[ -n ${_STATE[$pid]+x} ]]; then return 0; fi
    _STATE[$pid]=1
    ppid=${CUR_PPID[$pid]}
    if [[ -n ${_NEWSET[$ppid]+x} ]]; then _det_new_record "$ppid"; fi
    comm=${CUR_COMM[$pid]}; tty=${CUR_TTY[$pid]}; cmd=${_EXE[$pid]:-$comm}
    start_epoch=$(( COLLECTOR_EPOCH - ${CUR_ETIMES[$pid]} ))

    # Join the parent's application instance? Only if the parent is tracked, is
    # really older than the child (guards against a reused PID), and either is an
    # application or runs the same program.
    if [[ -n ${ACTIVE[$ppid]+x} ]] && (( ${ACTIVE_START[$ppid]} <= ${CUR_START[$pid]} + DETECTOR_TOLERANCE )); then
        record_unpack "${ACTIVE[$ppid]}"
        if [[ $R_CLASS == User_Application || $R_CMD == "$cmd" ]]; then
            inherit=1; p_class=$R_CLASS; p_cat=$R_CAT; p_group=$R_GROUP; p_app=$R_APP
        fi
    fi

    R_PID=$pid; R_PPID=$ppid; R_START_MONO=${CUR_START[$pid]}; R_START_EPOCH=$start_epoch
    R_SEEN=$COLLECTOR_EPOCH; R_TTY=$tty; R_USER=${CUR_USER[$pid]}; R_PAUSED=0
    R_SESSION=${SESSION_ID:--}; R_COMM=$comm; R_CMD=$cmd
    if (( DETECTOR_FIRST_CYCLE == 1 )); then R_PRE=yes; else R_PRE=no; fi
    if (( inherit == 1 )); then
        R_CLASS=$p_class; R_CAT=$p_cat; R_GROUP=$p_group; R_ROOT=no; R_APP=$p_app
    else
        detector_read_cgroup "$pid"
        detector_classify_root "$comm" "$cmd" "$tty" "$CG"
        R_CLASS=$CLS_CLASS; R_CAT=$CLS_CAT; R_APP=$CLS_APP
        R_GROUP="$pid-$start_epoch"; R_ROOT=yes
    fi
    record_pack
    detector_track_record "$REPLY"
    STARTED+=("$pid")
}

# --- The scan ------------------------------------------------------------------

# detector_diff — compare CUR_* with ACTIVE; update ACTIVE, STARTED, ENDED.
detector_diff() {
    local pid p n rss
    STARTED=(); ENDED=()

    # 1) Finished: tracked but gone — or the PID now belongs to a different process.
    #    Still running: refresh CPU / memory.
    for pid in "${!ACTIVE_START[@]}"; do
        if [[ -z ${CUR_START[$pid]+x} ]] || ! detector_same_process "${ACTIVE_START[$pid]}" "${CUR_START[$pid]}"; then
            _det_finish "$pid"
        else
            MET_CPU[$pid]=${CUR_CPU[$pid]:-0}
            rss=${CUR_RSS[$pid]:-0}
            MET_RSS[$pid]=$rss
            if (( rss > ${MET_PEAK[$pid]:-0} )); then MET_PEAK[$pid]=$rss; fi
        fi
    done

    # 2) New: present, not tracked, not ignored, not the logger's own children.
    _NEW=(); _NEWSET=()
    for pid in "${!CUR_START[@]}"; do
        if [[ -n ${ACTIVE_START[$pid]+x} ]]; then continue; fi
        if [[ -n ${IGNORE[${CUR_COMM[$pid]}]+x} ]]; then continue; fi
        if collector_is_own "$pid"; then continue; fi
        _NEW+=("$pid"); _NEWSET[$pid]=1
    done
    if (( ${#_NEW[@]} > 0 )); then
        _EXE=(); _STATE=()
        while IFS=$'\t' read -r p n; do _EXE[$p]=$n; done < <(collector_exe_names "${_NEW[@]}")
        for pid in "${_NEW[@]}"; do _det_new_record "$pid"; done
    fi
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

# detector_close_all — move every tracked process into ENDED (clean shutdown).
detector_close_all() {
    local pid
    ENDED=()
    for pid in "${!ACTIVE[@]}"; do _det_finish "$pid"; done
    return 0
}
