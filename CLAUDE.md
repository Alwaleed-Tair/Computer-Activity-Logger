# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project

**Computer Activity Logger** — a Bash-only tool that, with the user's explicit consent, runs in the background after login and logs process start/end times and durations to CSV files, then produces statistics and Excel-openable reports.

**Status:** design phase. The full spec is in `docs/DESIGN.md` — read it before changing or adding anything, and keep it in sync with the code.

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

Polling daemon (`lib/daemon.sh`) → `collector.sh` (`ps` snapshot) → `detector.sh` (diff) → `storage.sh` (append-only CSV + atomic state files). `analyzer.sh` / `report.sh` read CSV only. CLI entry point: `bin/cal`.

Key design rules:
- Process identity = `pid + start_mono` (`/proc/uptime` − `etimes`); durations use monotonic time, never wall-clock differences.
- CSV: append-only, UTF-8 **with BOM**, RFC 4180 quoting, `csv_safe` guards against formula injection (`= + - @`).
- State files (`active.tsv`, `heartbeat`, `session.state`) are written via `mktemp` + `mv`; crash recovery relies on them (see DESIGN §8).
- Use shell builtins in the main loop (`read`, `printf '%(%s)T'`, arrays); one `ps` call per cycle.

## Layout

```
bin/cal            CLI dispatcher
lib/*.sh           modules (common, config, consent, session, collector, detector,
                   storage, recovery, daemon, analyzer, report)
conf/              *.example config files
install/           install.sh, uninstall.sh, cal.service, cal.desktop
tests/             unit/ integration/ fixtures/ run_all.sh
docs/              DESIGN.md, PRIVACY.md, CSV_SCHEMA.md
```

## Commands

```bash
shellcheck bin/cal lib/*.sh install/*.sh   # static analysis (must be clean)
shfmt -d .                                 # formatting check
bash tests/run_all.sh                      # all tests (bats-core)
bats tests/unit                            # unit tests only
```

Integration tests must use an isolated temporary `HOME` and `INTERVAL_SEC=1`; never touch the real user's config or data.

## Coding conventions

- Every script: `#!/usr/bin/env bash`, `set -uo pipefail` (avoid blanket `set -e` in loops; check return codes explicitly), quote all expansions.
- Prefix functions by module (`storage_…`) or follow the names in DESIGN §6; no global state outside documented variables.
- Fail one cycle softly (log a warning, continue); never let the daemon die on a transient error.
- Write tests alongside each module; fixtures of `ps` output live in `tests/fixtures/`.

## Workflow

- Develop on branch `claude/exciting-maxwell-irr563`; commit with clear messages and push to it.
- Do not open a pull request unless asked.
- Follow the phase order in DESIGN §14 (0 → 1 → 2 → 3 → 4 → 5 → 6) and satisfy each phase's Definition of Done before moving on.
