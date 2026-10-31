#!/usr/bin/env bash
# =============================================================================
# tests/run_all.sh — Syntax check (bash -n), optional shellcheck, smoke test.
# =============================================================================
set -u -o pipefail
ROOT="$(cd -- "$(dirname -- "${BASH_SOURCE[0]}")/.." && pwd -P)"
cd "$ROOT" || exit 1

mapfile -t FILES < <(git ls-files '*.sh' 2>/dev/null || find . -name '*.sh' -not -path './.git/*')
if (( ${#FILES[@]} == 0 )); then mapfile -t FILES < <(find . -name '*.sh' -not -path './.git/*'); fi
rc=0

echo "== bash -n (${#FILES[@]} files) =="
for f in "${FILES[@]}"; do
    if bash -n "$f"; then echo "  ok    $f"; else echo "  FAIL  $f"; rc=1; fi
done

if command -v shellcheck >/dev/null 2>&1; then
    echo "== shellcheck =="
    shellcheck -x "${FILES[@]}" || rc=1
else
    echo "== shellcheck not installed — skipped =="
fi

echo "== session logger tests =="
bash tests/test_sessions.sh || rc=1

echo "== process monitor tests =="
bash tests/test_processes.sh || rc=1

echo "== activity analyzer tests =="
bash tests/test_activity.sh || rc=1

echo "== report generator tests =="
bash tests/test_reports.sh || rc=1

echo "== automatic startup (systemd user service) tests =="
bash tests/test_service.sh || rc=1

echo "== smoke test =="
bash tests/smoke.sh || rc=1
exit "$rc"
