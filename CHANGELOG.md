# Changelog

## 0.7.0 — simplified rewrite
The whole project is now one script, `cal.sh` (~270 lines), one test file, `test.sh`, and a README.
Kept: consent, background logging of sessions and processes (PID + start time identity, monotonic durations),
UTC, private files, CSV with BOM, crash recovery (`CRASHED`), single instance, summary + Excel report,
optional login autostart (systemd user service), purge.
Removed (all still in git history, commit `6c1e12d`): the module layout (`lib/`), `config.sh`, application grouping and
classification, `process_details.csv`, daily/period report sets with FINAL/PARTIAL history, the analyzer,
the Type=notify/watchdog service, the installer scripts, 7 documents and ~800 tests.
Tests: `test.sh` (44 checks, plus two mutations verified to fail: no own-process exclusion, no crash recovery).
Bugs found while writing it (fixed): `USER` unset in services/containers; own `ps`/subshells logged as processes;
`running()` fooled by a zombie after `kill -9`; `read ... <file 2>/dev/null` printed its error (redirect order);
`grep -q` in a `pipefail` pipeline made two checks fail by SIGPIPE.

## 0.1.0 – 0.6.1 — the full version
Session logger, process monitor, activity analyzer, report generator, systemd autostart, code review, QA runs.
See `git log` (last full version: `6c1e12d`).
