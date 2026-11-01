# CLAUDE.md

Guidance for Claude Code when working in this repository.

## Project
**Computer Activity Logger** — one Bash script (`cal.sh`) that, with the user's explicit consent, logs sessions and process start/end/duration to CSV in `data/`, and prints a summary / writes `data/report.csv`. v0.7.0 is a deliberately **minimal** rewrite: keep it simple. The old full version (≈4,000 lines, modules, analyzer, report sets) is in git history at `6c1e12d`; do not bring complexity back unless the user asks.

## Language
Reply to the user in **Arabic** (Gulf dialect is fine); keep code, comments, commands and commit messages in **English**.

## Hard constraints
- **Bash only** (≥ 4.3) + standard Linux tools. No Python/Java/C#. No GUI.
- **Privacy:** never record keystrokes, passwords, window titles, file/screen contents, command-line arguments or `/proc/*/environ`. No network. Logging starts only after explicit consent (`data/.consent`).
- Per-user, no root. Files 600, directory 700 (`umask 077`). All stored times UTC (`export TZ=UTC`).

## Layout
`cal.sh` (everything) · `test.sh` (tests, sandboxed via `CAL_DATA` and a temp HOME) · `README.md` · `CHANGELOG.md`. Autostart = one marked line in `~/.profile` (no systemd).

## Commands
`bash test.sh` (~2 min, never touches real data). Run only one test suite at a time (the logger sees the other's processes).

## Rules learned the hard way
- Process identity = PID + start time (`now_uptime - etimes`), never PID alone; durations from `/proc/uptime`.
- The logger must never log itself: skip its own process tree (`ps`, `sleep`, subshells) and never run an external `sleep`/helper in the CLI path that the daemon could see — use `nap` (builtin `read -t`).
- **Never start a child process inside a `trap` handler** (bash 5.2 aborts with "longjmp causes uninitialized stack frame"); handlers only set a flag.
- Never loop on `read` over a `/proc` file; single reads or `mapfile -n`.
- A killed process lingers as a zombie: judge liveness from `/proc/PID/status`, not `kill -0`.
- Redirect order: `read x 2>/dev/null <file` (error message is printed otherwise). `grep -q` in a `pipefail` pipeline can fail by SIGPIPE: capture first.
- Tests must not leave a daemon running (it would also be logged by the next test run); never run `trap '' TERM` in the test shell (children inherit "ignore").
- An intermittent failure is a real bug until proven otherwise.

## Workflow
Develop on `claude/exciting-maxwell-irr563`; commit with clear messages, gate commits on `bash test.sh` passing; no PR unless asked.
