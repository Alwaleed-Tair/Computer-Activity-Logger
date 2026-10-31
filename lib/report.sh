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

# report_build FROM TO TOP — create the report folder; prints its path.
report_build() {
    local from=${1-} to=${2-} top=${3:-20} stamp dir
    printf -v stamp '%(%Y%m%d_%H%M%S)T' -1
    dir="$REPORTS_DIR/report_$stamp"
    common_ensure_dir "$dir" || return 1

    report_write "$dir/01_summary.csv"   analyzer_summary  "$from" "$to"        || return 1
    report_write "$dir/02_top_apps.csv"  analyzer_top_apps "$from" "$to" "$top" || return 1
    report_write "$dir/03_daily.csv"     analyzer_daily    "$from" "$to"        || return 1
    report_write "$dir/05_sessions.csv"  analyzer_sessions_csv "$from" "$to"           || return 1
    report_write "$dir/06_processes.csv" analyzer_raw processes "$from" "$to"   || return 1
    log_info "report written to $dir"
    printf '%s\n' "$dir"
}
