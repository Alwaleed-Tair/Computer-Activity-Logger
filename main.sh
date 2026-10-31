#!/usr/bin/env bash
# =============================================================================
# main.sh — Computer Activity Logger: command-line entry point
# -----------------------------------------------------------------------------
# Usage: ./main.sh <command> [options]      (see ./main.sh help)
#
# This file only parses commands and wires the modules in lib/ together;
# all real work lives in the modules.
#
# Error handling: `set -u -o pipefail` (+ an ERR trap that only LOGS inside the
# daemon). `set -e` is intentionally NOT used: one failing command must never
# stop the logger or lose records that are still in memory.
# =============================================================================
set -u -o pipefail
set -E
umask 077

# Resolve the project root even when called through a symlink or another cwd.
CAL_ROOT="$(cd -- "$(dirname -- "$(readlink -f -- "${BASH_SOURCE[0]}")")" && pwd -P)"
export CAL_ROOT

# --- Load configuration and modules -----------------------------------------
# shellcheck source=config.sh
source "$CAL_ROOT/config.sh"
for _module in common consent storage sessionlog collector detector session recovery daemon analyzer activity report service; do
    # shellcheck source=/dev/null
    source "$CAL_ROOT/lib/${_module}.sh"
done
unset _module

# --- Small helpers -----------------------------------------------------------

main_usage() {
    cat <<EOF
Computer Activity Logger v${CAL_VERSION}

Usage: ./main.sh <command> [options]

Commands:
  consent [--accept|--revoke]   Show the notice and record / withdraw consent
  start                         Start the logger in the background
  stop                          Stop it (open records are saved first)
  service <install|enable|disable|start|stop|restart|status|logs|uninstall>
                                Automatic start at login (systemd user service, no root)
  daemon                        Run in the foreground (this is what the service runs)
  status                        Show state, paths and data size
  processes [--running|--apps|--background|--check] [--tail N] [--class C] [--from D] [--to D]
                                Process log: finished (default) / running now / by application
  sessions [--local|--tz ZONE] [--from D] [--to D] [--status S] [--check]
                                Session log (UTC by default; --local = this machine's zone)
  stats  [--from D] [--to D] [--top N] [--utc-offset +03:00] [--quality]
                                Activity report: sessions, processes, usage, top apps, daily
  report daily  [--date D | --from D --to D] [--utc-offset +03:00] [--refresh|--force]
                                One Excel-ready report set per day (reports/daily/…)
  report period [--from D] [--to D] [--name N] [--utc-offset +03:00]   One set for any period
  report verify [DIR…]          Check report files against their manifests and Excel rules
  report list                   Show the generated report sets
  purge  --all | --before YYYY-MM-DD [--yes]   Delete logged data
  doctor                        Check the environment
  version | help

Dates (D) use the format YYYY-MM-DD.
EOF
}

# main_die MESSAGE — print an error and exit 1.
main_die() { echo "error: $*" >&2; exit 1; }

# main_valid_date D — empty or YYYY-MM-DD.
main_valid_date() {
    # A real calendar date: 2026-13-01 and 2026-02-30 are refused (checked by a round trip).
    local _e _d _t
    if [[ -z $1 ]]; then return 0; fi
    [[ $1 =~ ^[0-9]{4}-[0-9]{2}-[0-9]{2}$ ]] || return 1
    common_utc_to_epoch _e "$1" "00:00:00" || return 1
    common_utc_date_time _d _t "$_e"
    [[ $_d == "$1" ]]
}

# main_parse_offset VALUE — "+03:00", "-0530", "3" ... -> OPT_OFFSET (seconds, max +-14 h).
main_parse_offset() {
    local sign=1 h m
    if [[ ${1-} =~ ^([+-]?)([0-9]{1,2})(:?([0-9]{2}))?$ ]]; then
        if [[ ${BASH_REMATCH[1]} == - ]]; then sign=-1; fi
        h=$(( 10#${BASH_REMATCH[2]} )); m=$(( 10#${BASH_REMATCH[4]:-0} ))
        if (( h > 14 || m > 59 )); then main_die "--utc-offset out of range (+-14:00): $1"; fi
        OPT_OFFSET=$(( sign * (h * 3600 + m * 60) ))
    else
        main_die "invalid --utc-offset (use e.g. +03:00): ${1-}"
    fi
}

# main_parse_range ARGS... — sets OPT_FROM, OPT_TO, OPT_TOP.
main_parse_range() {
    OPT_FROM=""; OPT_TO=""; OPT_TOP=10; OPT_OFFSET=0; OPT_QUALITY=0
    while (( $# > 0 )); do
        case $1 in
            --from) OPT_FROM=${2-}; shift 2 || main_die "--from needs a value" ;;
            --to)   OPT_TO=${2-};   shift 2 || main_die "--to needs a value" ;;
            --top)  OPT_TOP=${2-};  shift 2 || main_die "--top needs a value" ;;
            --utc-offset) main_parse_offset "${2-}"; shift 2 || main_die "--utc-offset needs a value" ;;
            --quality) OPT_QUALITY=1; shift ;;
            *) main_die "unknown option: $1" ;;
        esac
    done
    main_valid_date "$OPT_FROM" || main_die "invalid --from date"
    main_valid_date "$OPT_TO" || main_die "invalid --to date"
    [[ $OPT_TOP =~ ^[0-9]+$ ]] || main_die "--top must be a number"
}

# main_table — pretty-print CSV from stdin as an aligned table.
# main_tsv — align TAB separated text from stdin.
main_tsv() { if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi; }

main_table() {
    if command -v column >/dev/null 2>&1; then tr -d '"' | column -s, -t; else tr -d '"'; fi
}

# --- Commands ----------------------------------------------------------------

cmd_consent() {
    case ${1:-} in
        --accept) consent_notice; consent_grant && echo "Consent recorded in $CONSENT_FILE" ;;
        --revoke) consent_revoke; echo "Consent withdrawn. Logging will not start." ;;
        "")       consent_prompt ;;
        *)        main_die "unknown option: $1" ;;
    esac
}

cmd_start() {
    local i
    consent_require || exit 1
    storage_init || main_die "cannot create directories"
    if daemon_is_running; then echo "Already running (pid $(cat "$PID_FILE" 2>/dev/null))."; return 0; fi
    if command -v setsid >/dev/null 2>&1; then
        nohup setsid "$CAL_ROOT/main.sh" daemon >>"$LOG_FILE" 2>&1 </dev/null &
    else
        nohup "$CAL_ROOT/main.sh" daemon >>"$LOG_FILE" 2>&1 </dev/null &
    fi
    # Poll (up to 5 s): on a loaded machine the daemon needs more than a second to take its lock.
    for (( i = 0; i < 25; i++ )); do
        if daemon_is_running; then break; fi
        sleep 0.2
    done
    if daemon_is_running; then echo "Started (pid $(cat "$PID_FILE" 2>/dev/null))."; else
        main_die "failed to start — see $LOG_FILE"; fi
}

cmd_stop() {
    local pid i tries=$(( STOP_TIMEOUT_SEC * 5 ))
    if ! daemon_is_running; then echo "Not running."; return 0; fi
    pid=$(cat "$PID_FILE" 2>/dev/null) || main_die "pid file missing"
    kill -TERM "$pid" 2>/dev/null || main_die "cannot signal pid $pid"
    for (( i = 0; i < tries; i++ )); do
        if ! daemon_is_running; then echo "Stopped."; return 0; fi
        sleep 0.2
    done
    # A stuck monitor must never be unstoppable. SIGKILL is safe: recovery finishes the
    # session and the tracked processes at the next start (status CRASHED / RECOVERED).
    echo "The logger did not stop within ${STOP_TIMEOUT_SEC}s — forcing it (the session will be closed by recovery at the next start)." >&2
    kill -KILL "$pid" 2>/dev/null || true
    for (( i = 0; i < 25; i++ )); do
        if ! daemon_is_running; then echo "Stopped (forced)."; return 0; fi
        sleep 0.2
    done
    main_die "daemon (pid $pid) could not be stopped"
}

cmd_status() {
    local files size
    echo "Computer Activity Logger v${CAL_VERSION}  (user: $CAL_USER)"
    if consent_is_granted; then echo "Consent  : granted"; else echo "Consent  : NOT granted (run ./main.sh consent)"; fi
    if daemon_is_running; then echo "Daemon   : running (pid $(cat "$PID_FILE" 2>/dev/null))"; else echo "Daemon   : stopped"; fi
    if daemon_is_running && [[ -r $SESSION_FILE ]] && session_load_state; then echo "Session  : $RS_ID (ACTIVE, started $(date -u -d "@$RS_START_EPOCH" "+%F %T") UTC)"; fi
    echo "Interval : ${INTERVAL_SEC}s   Min duration: ${MIN_DURATION_SEC}s"
    echo "Sessions : $SESSIONS_FILE (UTC)"
    echo "Data     : $DATA_DIR"
    echo "Reports  : $REPORTS_DIR"
    files=$(find "$DATA_DIR" -maxdepth 1 -name '*.csv' 2>/dev/null | wc -l)
    size=$(du -sh "$DATA_DIR" 2>/dev/null | cut -f1)
    echo "Files    : ${files} CSV file(s), ${size:-0}"
    echo "Collects : process names + start/end times + durations (no arguments, no content)"
}

cmd_sessions() {
    local zone=utc status="" check=0 from="" to=""
    while (( $# > 0 )); do
        case $1 in
            --local)  zone=local ;;
            --utc)    zone=utc ;;
            --tz)     zone=${2-}; [[ -n $zone ]] || main_die "--tz needs a zone name"; shift ;;
            --from)   from=${2-}; shift ;;
            --to)     to=${2-}; shift ;;
            --status) status=${2-}; shift ;;
            --check)  check=1 ;;
            *) main_die "unknown option: $1" ;;
        esac
        shift
    done
    main_valid_date "$from" || main_die "invalid --from date"
    main_valid_date "$to" || main_die "invalid --to date"
    if (( check == 1 )); then sessionlog_verify; return; fi
    if [[ ! -s $SESSIONS_FILE ]]; then echo "No sessions recorded yet ($SESSIONS_FILE)."; return 0; fi
    analyzer_sessions_view "$from" "$to" "$status" "$zone" | if command -v column >/dev/null 2>&1; then column -t -s $'\t'; else cat; fi
}

cmd_processes() {
    local mode=table class="" tail=20 from="" to="" top=10
    while (( $# > 0 )); do
        case $1 in
            --running)    mode=running ;;
            --apps)       mode=apps ;;
            --background) mode=bg ;;
            --class)      class=${2-}; shift ;;
            --check)      mode=check ;;
            --tail)       tail=${2-}; shift ;;
            --top)        top=${2-}; shift ;;
            --from)       from=${2-}; shift ;;
            --to)         to=${2-}; shift ;;
            *) main_die "unknown option: $1" ;;
        esac
        shift
    done
    main_valid_date "$from" || main_die "invalid --from date"
    main_valid_date "$to" || main_die "invalid --to date"
    [[ $tail =~ ^[0-9]+$ && $top =~ ^[0-9]+$ ]] || main_die "--tail/--top must be numbers"
    case $mode in
        check)   storage_verify_processes ;;
        running) cmd_processes_running ;;
        apps)    activity_prepare "$from" "$to" 0; activity_apps User_Application "$top" | activity_pretty ;;
        bg)      activity_prepare "$from" "$to" 0; activity_apps Background_Process "$top" | activity_pretty ;;
        *)
            if [[ ! -s $PROCESSES_FILE ]]; then echo "No finished processes recorded yet ($PROCESSES_FILE)."; return 0; fi
            analyzer_processes_view "$from" "$to" "$class" "$tail" | main_tsv ;;
    esac
}

# Processes being tracked right now (from the live state file; times in UTC).
cmd_processes_running() {
    local rec st n=0
    if [[ ! -s $ACTIVE_FILE ]]; then echo "Nothing is being tracked (is the logger running?)."; return 0; fi
    {
        printf 'PID\tProcess\tClass\tApplication\tRoot\tStart(UTC)\tBefore_Session\tSession\n'
        while IFS= read -r rec || [[ -n $rec ]]; do
            [[ -n $rec ]] || continue
            record_unpack "$rec"; common_fmt_ts st "$R_START_EPOCH"
            printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' "$R_PID" "$R_COMM" "$R_CLASS" "$R_APP" "$R_ROOT" "$st" "$R_PRE" "$R_SESSION"
        done <"$ACTIVE_FILE"
    } | main_tsv
}

cmd_stats() {
    main_parse_range "$@"
    activity_prepare "$OPT_FROM" "$OPT_TO" "$OPT_OFFSET"
    if (( OPT_QUALITY == 1 )); then activity_quality | activity_pretty; return; fi
    activity_text_report "$OPT_TOP"
}

# main_report_generate KIND OPTIONS... — shared option parsing for `report daily|period`.
main_report_generate() {
    local kind=$1 mode=normal date="" name="" explicit=0
    shift
    OPT_FROM=""; OPT_TO=""; OPT_TOP=$REPORT_TOP; OPT_OFFSET=$REPORT_UTC_OFFSET_SEC
    while (( $# > 0 )); do
        case $1 in
            --date) date=${2-}; shift 2 || main_die "--date needs a value" ;;
            --from) OPT_FROM=${2-}; shift 2 || main_die "--from needs a value" ;;
            --to)   OPT_TO=${2-};   shift 2 || main_die "--to needs a value" ;;
            --top)  OPT_TOP=${2-};  shift 2 || main_die "--top needs a value" ;;
            --name) name=${2-};     shift 2 || main_die "--name needs a value" ;;
            --utc-offset) main_parse_offset "${2-}"; shift 2 || main_die "--utc-offset needs a value" ;;
            --all) shift ;;
            --refresh) mode=refresh; shift ;;
            --force) mode=force; shift ;;
            *) main_die "unknown option: $1" ;;
        esac
    done
    main_valid_date "$OPT_FROM" || main_die "invalid --from date"
    main_valid_date "$OPT_TO" || main_die "invalid --to date"
    main_valid_date "$date" || main_die "invalid --date"
    [[ $OPT_TOP =~ ^[0-9]+$ ]] || main_die "--top must be a number"
    [[ -z $name || $name =~ ^[A-Za-z0-9._-]{1,64}$ ]] || main_die "--name may only contain letters, digits, . _ - (max 64)"
    if [[ -n $date ]]; then
        [[ -z $OPT_FROM && -z $OPT_TO ]] || main_die "use either --date or --from/--to"
        OPT_FROM=$date; OPT_TO=$date; explicit=1
    fi
    if [[ -n $OPT_FROM && -n $OPT_TO && $OPT_FROM > $OPT_TO ]]; then main_die "--from is after --to"; fi
    storage_init || main_die "cannot create directories"
    if [[ $kind == daily ]]; then
        report_run_daily "$OPT_FROM" "$OPT_TO" "$OPT_OFFSET" "$OPT_TOP" "$mode" "$explicit"
    else
        report_run_period "$OPT_FROM" "$OPT_TO" "$OPT_OFFSET" "$OPT_TOP" "$mode" "$name"
    fi
}

cmd_report() {
    local sub=${1:-} d rc=0
    case $sub in
        daily|period) shift; main_report_generate "$sub" "$@" || exit 1 ;;
        verify)
            shift
            if (( $# == 0 )); then report_verify_all || exit 1
            else for d in "$@"; do if report_verify_dir "$d"; then echo "OK        $d"; else echo "PROBLEMS  $d"; rc=1; fi; done; exit "$rc"; fi ;;
        list)  report_list ;;
        ""|-*) main_report_generate period "$@" || exit 1 ;;     # short form: report [--from D] [--to D]
        *) main_die "unknown report command '$sub' (daily | period | verify | list)" ;;
    esac
}

cmd_purge() {
    local mode="" before="" yes=0 ans="" purge_fd
    while (( $# > 0 )); do
        case $1 in
            --all) mode=all ;;
            --before) mode=before; before=${2-}; shift ;;
            --yes) yes=1 ;;
            *) main_die "unknown option: $1" ;;
        esac
        shift
    done
    [[ -n $mode ]] || main_die "purge needs --all or --before YYYY-MM-DD"
    storage_init || main_die "cannot create directories"
    # Hold the daemon lock while rewriting the CSVs: a logger cannot start in the middle of a
    # purge (its appended rows would be lost by the file replacement).
    exec {purge_fd}>"$LOCK_FILE" || main_die "cannot open $LOCK_FILE"
    flock -n "$purge_fd" || main_die "stop the logger first (./main.sh stop)"
    if [[ $mode == before ]]; then
        main_valid_date "$before" && [[ -n $before ]] || main_die "invalid --before date"
        echo "Process rows with Start_Time < $before, and session rows with Login_Date < $before, will be deleted."
    else
        echo "ALL CSV data in $DATA_DIR will be deleted."
    fi
    if (( yes == 0 )); then
        read -r -p "Type 'yes' to confirm: " ans
        [[ $ans == yes ]] || { echo "Cancelled."; return 0; }
    fi
    # processes.csv / process_details.csv: drop everything, or only the rows before the date.
    if [[ $mode == all ]]; then
        rm -f -- "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE" && echo "deleted $PROCESSES_FILE and $PROCESS_DETAILS_FILE"
    else
        echo "removed $(storage_purge_before "$before") process row(s) from $PROCESSES_FILE"
    fi
    # sessions.csv is a single file: drop everything, or only the closed rows before the date.
    if [[ $mode == all ]]; then
        rm -f -- "$SESSIONS_FILE" "$SESSIONS_FILE.bak" && echo "deleted $SESSIONS_FILE"
    else
        echo "removed $(sessionlog_purge_before "$before") session row(s) from $SESSIONS_FILE"
    fi
}

cmd_doctor() {
    local c bad=0
    echo "Bash     : $BASH_VERSION"
    # Everything the logger actually runs (README: "Technologies"). `column` is NOT required.
    for c in ps awk sort uniq cut head tail tr grep sed find stat flock df du date mktemp wc sha256sum timeout; do
        if command -v "$c" >/dev/null 2>&1; then echo "  ok      $c"; else echo "  MISSING $c"; bad=1; fi
    done
    for c in column locale systemctl systemd-notify setsid; do
        if command -v "$c" >/dev/null 2>&1; then echo "  ok      $c (optional)"; else echo "  absent  $c (optional)"; fi
    done
    storage_init && echo "  ok      directories writable" || { echo "  FAIL    directories"; bad=1; }
    if service_available; then echo "  ok      systemd user manager reachable (service commands work)"; else echo "  info    systemd user service unavailable here: $SVC_WHY"; fi
    if consent_is_granted; then echo "  ok      consent"; else echo "  todo    consent not granted"; fi
    config_validate && echo "  ok      configuration" || bad=1
    return "$bad"
}

# --- Dispatcher --------------------------------------------------------------

main() {
    local cmd=${1:-help}
    if (( $# > 0 )); then shift; fi
    common_require_bash || exit 1
    config_validate || exit 1
    case $cmd in
        daemon)  CAL_VERBOSE=${CAL_VERBOSE:-0}; daemon_run ;;           # exit code matters to systemd: see lib/daemon.sh
        service) service_main "$@" ;;
        rotate-logs) common_rotate_file "$SERVICE_ERROR_LOG"; common_rotate_log ;;   # run by the unit before each start
        start)   cmd_start ;;
        stop)    cmd_stop ;;
        status)  cmd_status ;;
        consent) cmd_consent "$@" ;;
        processes) cmd_processes "$@" ;;
        sessions) cmd_sessions "$@" ;;
        stats)   cmd_stats "$@" ;;
        report)  cmd_report "$@" ;;
        purge)   cmd_purge "$@" ;;
        doctor)  cmd_doctor ;;
        version|--version|-V) echo "$CAL_VERSION" ;;
        help|--help|-h) main_usage ;;
        *) echo "unknown command: $cmd" >&2; main_usage >&2; exit 1 ;;
    esac
}

main "$@"
