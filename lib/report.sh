#!/usr/bin/env bash
# =============================================================================
# lib/report.sh — Excel-ready reports
# -----------------------------------------------------------------------------
# Produces a folder of CSV files (UTF-8 with BOM) under $REPORTS_DIR. Excel
# opens them directly: dates are recognised, *_sec columns are numeric (use
# them for SUM / Pivot Tables) and *_hms columns are for reading.
# =============================================================================

# report_write FILE COMMAND [ARGS...] — run COMMAND and store its stdout with a BOM.
report_write() {
    local file=$1
    shift
    { printf '\xEF\xBB\xBF'; "$@"; } >"$file" || return 1
    chmod 600 "$file" 2>/dev/null || true
}

# report_write_text FILE COMMAND [ARGS...] — plain UTF-8 text (no BOM).
report_write_text() {
    local file=$1
    shift
    "$@" >"$file" || return 1
    chmod 600 "$file" 2>/dev/null || true
}

# report_build FROM TO TOP OFFSET_SECONDS — create the report folder; prints its path.
# Read-only on the logs: it only runs the Activity Analyzer and writes NEW files.
#   01 summary                  Total Sessions / Processes / Usage Duration / Averages...
#   02 most used applications   ranked by active time (helper processes merged)
#   03 background processes     same ranking for Background_Process
#   04 daily usage              per calendar day
#   05 sessions                 one row per session with its process totals
#   06 process durations        one row per process, natural end or not
#   07 data quality             what was skipped / is incomplete
#   08 report.txt               the complete human-readable report
report_build() {
    local from=${1-} to=${2-} top=${3:-20} off=${4:-0} stamp dir
    printf -v stamp '%(%Y%m%d_%H%M%S)T' -1
    dir="$REPORTS_DIR/report_$stamp"
    common_ensure_dir "$dir" || return 1
    activity_prepare "$from" "$to" "$off"

    report_write "$dir/01_summary.csv"                  activity_summary                          || return 1
    report_write "$dir/02_most_used_applications.csv"   activity_apps User_Application "$top"     || return 1
    report_write "$dir/03_background_processes.csv"     activity_apps Background_Process "$top"   || return 1
    report_write "$dir/04_daily_usage.csv"              activity_daily                            || return 1
    report_write "$dir/05_sessions.csv"                 activity_sessions                         || return 1
    report_write "$dir/06_process_durations.csv"        activity_processes                        || return 1
    report_write "$dir/07_data_quality.csv"             activity_quality                          || return 1
    report_write_text "$dir/08_report.txt"              activity_text_report "$top"               || return 1
    log_info "report written to $dir"
    printf '%s\n' "$dir"
}
