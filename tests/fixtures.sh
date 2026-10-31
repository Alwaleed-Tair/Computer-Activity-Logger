#!/usr/bin/env bash
# =============================================================================
# tests/fixtures.sh — shared, hand-built test data (sourced by the analyzer and report tests)
# -----------------------------------------------------------------------------
# build_dataset writes sessions.csv / processes.csv / process_details.csv exactly as the
# logger would, plus deliberately damaged lines. The timeline (and therefore every expected
# number in the tests) is documented at the top of tests/test_activity.sh.
# Needs: config.sh and lib/common.sh already sourced (SESSIONS_FILE, AWK_LIB, headers...).
# =============================================================================

# --- fixture builders (they write raw CSV exactly as the logger would) ---------------
ep() { date -u -d "$1" +%s; }
mk_files() {   # fresh headers
    rm -f -- "$SESSIONS_FILE" "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE"
    printf '\xEF\xBB\xBF%s\n' "$SESSIONS_HEADER" >"$SESSIONS_FILE"
    printf '\xEF\xBB\xBF%s\n' "$PROCESSES_HEADER" >"$PROCESSES_FILE"
    printf '\xEF\xBB\xBF%s\n' "$DETAILS_HEADER" >"$PROCESS_DETAILS_FILE"
}
mk_session() {   # ID LOGIN LOGOUT DURATION STATUS      ("" logout/duration for open sessions)
    local ld=${2%% *} lt=${2##* } od="" ot=""
    if [[ -n $3 ]]; then od=${3%% *}; ot=${3##* }; fi
    printf '%s,"tester",1000,%s,%s,%s,%s,%s,%s\n' "$1" "$ld" "$lt" "$od" "$ot" "$4" "$5" >>"$SESSIONS_FILE"
}
mk_proc() {   # SID PID NAME START END STATUS CLASS APP ROOT PRE INST [DETECTED_START] [DURATION_FIELD] [no-details]
    local sid=$1 pid=$2 name=$3 start=$4 end=$5 status=$6 class=$7 app=$8 root=$9 pre=${10} inst=${11}
    local det=${12:-$4} durf=${13:-} nodet=${14:-} s e dur
    name=${name//\"/\"\"}; app=${app//\"/\"\"}      # CSV-escape embedded quotes
    s=$(ep "$start"); e=$(ep "$end"); dur=$(( e - s ))
    printf '%s,%s,"%s","tester",%s,%s,%s,%s\n' "$sid" "$pid" "$name" "$start" "$end" "${durf:-$dur}" "$status" >>"$PROCESSES_FILE"
    if [[ $nodet != no-details ]]; then
        printf '%s,%s,%s,1,"%s",%s,"%s",%s,%s,%s,%s,%s,0,0,0.0,1000,1000,"cat",%s,%s\n' \
            "$sid" "$pid" "$start" "$name" "$class" "$app" "$inst" "$root" "$pre" "$det" "$end" "$s" "$e" >>"$PROCESS_DETAILS_FILE"
    fi
}
UA=User_Application; BG=Background_Process
build_dataset() {
    mk_files
    mk_session S1 "2026-10-01 09:00:00" "2026-10-01 11:00:00" 7200 COMPLETED
    mk_session S2 "2026-10-01 23:30:00" "2026-10-02 00:30:00" 3600 COMPLETED
    mk_session S3 "2026-10-02 08:00:00" "2026-10-02 08:50:00" 3000 CRASHED
    mk_session S4 "2026-10-03 10:00:00" "" "" ACTIVE
    mk_session S5 "2026-10-03 12:00:00" "" "" INTERRUPTED
    mk_proc S1  101 browserx       "2026-10-01 09:10:00" "2026-10-01 10:10:00" COMPLETED   $UA "Browser X" yes no  i1
    mk_proc S1  102 "Web Content"  "2026-10-01 09:12:00" "2026-10-01 09:42:00" COMPLETED   $UA "Browser X" no  no  i1
    mk_proc S1  103 gpuhelper      "2026-10-01 10:00:00" "2026-10-01 10:30:00" COMPLETED   $UA "Browser X" no  no  i1
    mk_proc S1  104 editorx        "2026-10-01 09:30:00" "2026-10-01 10:00:00" COMPLETED   $UA "Editor X"  yes no  i2
    mk_proc S1  105 svc            "2026-10-01 08:00:00" "2026-10-01 11:00:00" SESSION_END $BG "svc"       yes yes i5 "2026-10-01 09:00:05"
    mk_proc S1  106 browserx       "2026-10-01 10:45:00" "2026-10-01 10:55:00" COMPLETED   $UA "Browser X" yes no  i3
    mk_proc S2  107 editorx        "2026-10-01 23:45:00" "2026-10-02 00:15:00" COMPLETED   $UA "Editor X"  yes no  i4
    mk_proc S3  108 browserx       "2026-10-02 08:05:00" "2026-10-02 08:35:00" RECOVERED   $UA "Browser X" yes no  i6
    mk_proc S3  109 worker         "2026-10-02 08:10:00" "2026-10-02 08:12:00" COMPLETED   $BG "worker"    yes no  i7
    mk_proc SX  110 ghost          "2026-10-01 12:00:00" "2026-10-01 12:10:00" COMPLETED   $UA "Ghost"     yes no  i8
    mk_proc S3  111 mystery        "2026-10-02 09:00:00" "2026-10-02 09:00:30" COMPLETED   $UA "mystery"   yes no  i10 "" "" no-details
    mk_proc S1  112 calc           "2026-10-01 10:30:00" "2026-10-01 10:31:40" COMPLETED   $BG "calc"      yes no  i9  "" abc
    # damaged / duplicated / orphan lines
    echo 'S1,113,"bad"' >>"$PROCESSES_FILE"                                                       # wrong field count
    dup_line=$(grep ',104,"editorx"' "$PROCESSES_FILE"); printf '%s\n' "$dup_line" >>"$PROCESSES_FILE"      # exact duplicate of P4
    echo 'S1,114,"garbage","tester",not-a-date,2026-10-01 10:00:00,5,COMPLETED' >>"$PROCESSES_FILE" # unreadable Start_Time
    echo 'S1,999,2026-10-01 09:59:00,1,"orph",Background_Process,"orph",i99,yes,no,2026-10-01 09:59:00,2026-10-01 10:00:00,0,0,0.0,1,1,"cat",1,2' >>"$PROCESS_DETAILS_FILE"
}
checksums() { sha256sum "$SESSIONS_FILE" "$PROCESSES_FILE" "$PROCESS_DETAILS_FILE" 2>/dev/null | awk '{print $1}' | paste -sd' '; }
# csv_field FILE_OR_TEXT KEYCOL KEY COL — first matching row's COL (csv-aware via awk)
cell() {   # TEXT KEYCOL KEY COL
    awk "$AWK_LIB"'{ n = csv_split($0, f); if (f[kc] == k) { print f[c]; exit } }' kc="$2" k="$3" c="$4" <<<"$1"
}
