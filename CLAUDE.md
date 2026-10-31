# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**Computer Activity Logger** — a Bash-only tool that, with the user's explicit consent, runs in the background after login and logs process start/end times and durations to CSV files, then produces statistics and Excel-openable reports.

**Status:** v0.6 — session logger, process monitor, activity analyzer, report generator and automatic startup (systemd user service) implemented and tested. The full spec is in `docs/DESIGN.md` — read it before changing or adding anything, and keep it in sync with the code.

## Language

- Reply to the user in **Arabic** (they write Arabic); keep code, commands, identifiers, comments and commit messages in **English**.
- `docs/DESIGN.md` is written in Arabic; keep that language when editing it.

## Hard constraints (never violate)

- **Bash only** (≥ 4.3) plus standard Linux tools (`ps`, `awk`, `sort`, `flock`, `systemctl`, `zip`…). **No Python, C#, Java**, or other runtimes for project functionality.
- **No GUI.** Terminal + CSV only.
- **Privacy:** never record keystrokes, passwords, window titles, file/screen contents, command-line arguments, or `/proc/*/environ`. No hidden monitoring; no network access.
- Logging must start only after explicit, recorded user consent (`~/.config/cal/consent`).
- Per-user, no root required. Files `600`, directories `700` (`umask 077`).

## Architecture (summary)

Polling daemon (`lib/daemon.sh`) → `collector.sh` (`ps` snapshot) → `detector.sh` (diff) → `storage.sh` (append-only CSV + atomic state files). `analyzer.sh` / `report.sh` read CSV only. CLI entry point: `main.sh` (settings in `config.sh`).

Key design rules:
- Process identity = `pid + start_mono` (`/proc/uptime` − `etimes`); durations use monotonic time, never wall-clock differences.
- CSV: append-only, UTF-8 **with BOM**, RFC 4180 quoting; `csv_row` (lib/common.sh) guards against formula injection (`= + - @`).
- State files (`active.tsv`, `heartbeat`, `session.state`) are written to `<file>.tmp` then `mv`; crash recovery relies on them (see DESIGN §8).
- Use shell builtins in the main loop (`read`, `printf '%(%s)T'`, arrays); one `ps` call per cycle.

## Layout

```
main.sh            CLI entry point (dispatches commands to lib/)
config.sh          all settings (env vars / config.local.sh override)
lib/*.sh           modules (common, consent, collector, detector, session, sessionlog, activity, service,
                   storage, recovery, daemon, analyzer, report)
conf/              *.example lists (ignore.list, apps.map)
data/              raw CSV logs (git-ignored)    reports/  generated reports (git-ignored)
state/             runtime state (git-ignored)
install/           install.sh, uninstall.sh, systemd/autostart templates
tests/             run_all.sh, test_service.sh, usermgr.sh, test_sessions.sh, test_processes.sh, test_activity.sh, test_reports.sh, fixtures.sh, smoke.sh
docs/              DESIGN.md
```

## Commands

```bash
bash tests/run_all.sh        # bash -n + shellcheck (if installed) + sandboxed smoke test
bash tests/test_sessions.sh   # session logger tests (75 checks)
bash tests/test_processes.sh  # process monitor tests (175 checks)
bash tests/test_activity.sh   # activity analyzer tests (127 checks, known-answer dataset)
bash tests/test_reports.sh    # report generator tests (213 checks; opens files in LibreOffice if installed)
bash tests/test_service.sh    # automatic startup tests (168 checks; real systemd user manager, skipped if none can be had)
bash tests/e2e_plan.sh        # 20-case end-to-end plan with real test apps (writes results to stdout/$1; see TEST_REPORT.md)
bash tests/smoke.sh          # smoke test only
./main.sh sessions --check   # validate data/sessions.csv
./main.sh doctor             # environment check
```

Tests run against a temp sandbox via env overrides (`DATA_DIR`, `STATE_DIR`, `CONSENT_FILE`, `INTERVAL_SEC=1`); never touch the real data. Do not use `pkill -f` in tests (it can match the test runner itself) — kill by PID.


## Coding conventions

- Every script: `#!/usr/bin/env bash`, `set -uo pipefail` (avoid blanket `set -e` in loops; check return codes explicitly), quote all expansions.
- Prefix functions by module (`storage_…`) or follow the names in DESIGN §6; no global state outside documented variables.
- Fail one cycle softly (log a warning, continue); never let the daemon die on a transient error.
- Add a check to `tests/smoke.sh` for every bug you fix (it already guards kernel-thread filtering, BOM, recovery).

## Workflow

- Develop on branch `claude/exciting-maxwell-irr563`; commit with clear messages and push to it.
- Do not open a pull request unless asked.
- Follow the phase order in DESIGN §14 (0 → 1 → 2 → 3 → 4 → 5 → 6) and satisfy each phase's Definition of Done before moving on.

## Session log rules (sessions.csv)

- Exact columns: `Session_ID,Username,User_ID,Login_Date,Login_Time,Logout_Date,Logout_Time,Duration_Seconds,Status`. Don't add columns; derived values (minutes, local time) are computed on display.
- **All stored times are UTC.** Use `common_utc_date_time` / `common_utc_to_epoch` (pure Bash). Never format stored times with `printf '%(…)T'` (depends on an exported `TZ`) or localtime.
- Every write to `sessions.csv` goes through `lib/sessionlog.sh` (flock + temp file + atomic `mv`). Never `>>`/`sed -i` it from elsewhere. Rows are never deleted except by `purge`.
- Helpers that write to a caller-supplied variable via `printf -v "$1"` must name their own locals with a `__` prefix (dynamic scoping would otherwise capture the write).

## Process log rules (processes.csv)

- `processes.csv` has exactly: `Session_ID,PID,Process_Name,Username,Start_Time,End_Time,Duration_Seconds,Status`. Everything else goes in `process_details.csv` (joined by Session_ID+PID+Start_Time). Both are append-only; never rewrite them while the daemon runs.
- **Never identify a process by PID alone** — always PID + `start_mono` (`detector_same_process`).
- Only `ps -u $EUID`; no `sudo`; never read `cmdline`/`environ`. Process names are untrusted text: no `eval`, always quote, and keep them out of arithmetic contexts.
- Anything found in the first scan after a (re)start is "found running" (`pre=yes`), never "started". Recovery re-attaches survivors with their ORIGINAL record; do not create a new record for them.
- Tests that write config files must create them BEFORE sourcing `config.sh` and must assert the paths are inside the sandbox (config falls back to `conf/*.example`, which would otherwise be overwritten).

## Analyzer rules (lib/activity.sh)

- **Read-only.** The analyzer never writes to `data/` or modifies raw CSVs; reports go to `reports/` only.
- **Three different measures — never mix them:** session time (Total Usage Duration), application time (UNION of a process group's intervals, `_act_union`), and process-seconds (plain sum; concurrent processes add up, so it is NOT usage time and must be labelled as such).
- Averages use `COMPLETED` rows only. `SESSION_END` (lower bound) and `RECOVERED` (estimated end) are counted separately; sessions `ACTIVE`/`INTERRUPTED` have no duration and are never totalled. No data to average => empty/`n/a`, never 0.
- A *launch* is an application ROOT that started while monitored; "found running" (`pre=yes`) is `Already_Running`, measured from first sight. Never merge rows without a details row into an application.
- mawk has no `mktime`/`strftime`/`{n}` regex: use the pure-arithmetic helpers in `AWK_LIB` (`epoch`, `fmt_ts`, `dayname`, `day_segments`).
- When testing analysis, work out expected numbers by hand from the dataset's timeline, and check the tests can fail (mutate the analyzer in a copy under the scratchpad).
- GNU `grep` refuses to append a file to itself (`grep x f >> f`): capture into a variable first.

## Hard-won rules (bugs the tests caught)

- **Never loop on `read` over a `/proc` file** (`while read x || [[ -n $x ]]`). If the process exits mid-read, `read` fails with ESRCH and leaves `x` at its previous non-empty value => infinite loop (the daemon froze at 100% CPU and ignored SIGTERM). Use `mapfile` or a single `read -d ''`. `tests/test_processes.sh` A13 holds a control that shows the old idiom spinning.
- `./main.sh stop` must always work: it waits `STOP_TIMEOUT_SEC`, then sends SIGKILL (safe: recovery closes the session at the next start).
- When a test fails intermittently, find the cause before re-running: the failing run's log (`cal.log`, daemon state) is printed by `dump_diagnostics` in `tests/test_processes.sh`. A leftover daemon after the suite means something leaked.
- A killed process can linger as a zombie (`Z`): `kill -0` still succeeds. Judge liveness by the lock (`daemon_is_running`) or `ps -o stat=`.

## Report generator rules (lib/report.sh)

- A report set = `session_report.csv`, `application_activity_report.csv`, `usage_summary_report.csv` + `report_manifest.csv`. Generate with `report_generate_set` only; never write into `reports/` any other way.
- **Safe writing:** hold `reports/.report.lock`; build in a hidden staging dir on the same filesystem; `sync` + `mv -f` every file (atomic); **manifest last**. Never `>` straight into a published file.
- **History:** a `FINAL` set is frozen (normal runs skip it). Replace it only for `--refresh` (if content changed) or `--force`, and ALWAYS archive the old files to `revisions/` first. The content fingerprint excludes `Report_Created_UTC` so an unchanged report keeps its creation date.
- Excel rules enforced by `report_verify_dir`: UTF-8 BOM, CRLF, constant columns, balanced quotes, ISO dates, numbers as numbers, no unprotected `= + - @` cell (never write a cell like `+00:00`), cells <= 32,767 chars, <= `REPORT_MAX_ROWS` rows per file (else `_partN`).
- **`read` at EOF empties every variable it was given.** Never use a variable you need after the loop as a `read` target (`while read ... M_FP _`) — copy it inside the body. This silently broke "don't replace unchanged reports" until a test caught it.
- An `exit` inside an awk rule runs `END`, and an `exit` there replaces the status: set a flag, `exit` once in `END`.
- `main_valid_date` must reject impossible dates (round-trip check); don't validate dates by pattern alone.
- Test hooks: `CAL_NOW_EPOCH` pins the clock, `CAL_TEST_ABORT_AFTER_FILES=N` simulates a crash while publishing. Don't run two test suites at the same time on one machine (the monitor sees the other's processes).

## Automatic startup rules (lib/service.sh, install/cal.service.template)

- **User service only** (`systemctl --user`, unit in `~/.config/systemd/user`). No `User=`, no root/sudo, no system-wide units. Never hide it: it must show in `systemctl --user list-units`.
- **Login is not boot.** The unit starts with the user manager (first login), not with the machine; `Login_Time` = when the logger started. Keep `service status` printing both, and keep this distinction in README.
- `main.sh daemon` exit codes are part of the unit's contract: `0` clean, `1` error (restart), `EXIT_ALREADY_RUNNING=3`, `EXIT_NO_CONSENT=4` (listed in `RestartPreventExitStatus`; never retried). Don't change them without changing the template and `tests/test_service.sh`.
- **Take the flock before touching any data file** (`daemon_run`). The kernel lock is the only single-instance authority; never rely on pid files.
- `Type=notify` + `daemon_notify --ready` only after the session is open; `daemon_watchdog_ping` once per cycle. Without `systemd-notify` the template falls back to `Type=simple`.
- Unit values come from `service_render`: `%` doubled, `$` is NOT escaped, relative/newline/quote/backslash paths refused, no `Documentation=file://` (spaces are invalid there). Overrides go in `config.local.sh` (the service does not inherit the shell env); changing paths or `INTERVAL_SEC` needs `service install` + `restart`.
- `service start/restart` run `reset-failed` first (a start-limit hit would otherwise block them) and refuse while a hand-started daemon runs.
- `tests/usermgr.sh` is test infrastructure only (throw-away user + private mount namespace for a real `systemd --user` in a non-systemd container). Never run two suites at once; a leaked daemon after the suite is a bug (signal the REAL daemon pid from `daemon.pid`, not the subshell that launched it). It can't reproduce logind/PAM/desktop sessions: say so honestly.
