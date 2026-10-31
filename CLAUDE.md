# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**Computer Activity Logger** — a Bash-only tool that, with the user's explicit consent, runs in the background after login and logs process start/end times and durations to CSV files, then produces statistics and Excel-openable reports.

**Status:** v0.1 — base skeleton implemented and smoke-tested. The full spec is in `docs/DESIGN.md` — read it before changing or adding anything, and keep it in sync with the code.

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
lib/*.sh           modules (common, consent, collector, detector, session,
                   storage, recovery, daemon, analyzer, report)
conf/              *.example lists (ignore.list, apps.map)
data/              raw CSV logs (git-ignored)    reports/  generated reports (git-ignored)
state/             runtime state (git-ignored)
install/           install.sh, uninstall.sh, systemd/autostart templates
tests/             run_all.sh, smoke.sh
docs/              DESIGN.md
```

## Commands

```bash
bash tests/run_all.sh        # bash -n + shellcheck (if installed) + sandboxed smoke test
bash tests/smoke.sh          # smoke test only
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
