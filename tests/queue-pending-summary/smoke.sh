#!/usr/bin/env bash
# queue-pending-summary smoke — issue #509 D1 follow-up.
#
# Asserts that hooks/bridge_hook_common.queue_summary excludes blocked-state
# tasks from the `pending` count. The SessionStart hook only nudges with
# `[Agent Bridge] N pending task(s) … ACTION REQUIRED` when at least one
# queued or claimed task exists — operator-set blocked-with-reason tasks
# are waiting on external unblock and must not re-fire the nudge after
# every `bridge-task update --status blocked`.
#
# Cases:
#   D1a — 1 queued + 1 blocked + 0 claimed → pending=1 (NOT 2)
#   D1b — 0 queued + 2 blocked + 0 claimed → pending=0 (no nudge, row None)
#   D1c — 0 queued + 1 blocked + 1 claimed → pending=1
#
# Stubs queue_cli via a monkeypatched function in-process so the test does
# not need a real SQLite queue.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
}

# run_case <queued> <blocked> <claimed> <expected_pending> <expected_row_none: 0|1>
run_case() {
  local queued="$1" blocked="$2" claimed="$3" expected_pending="$4" expect_row_none="$5"
  "$PYTHON" - "$REPO_ROOT" "$queued" "$blocked" "$claimed" "$expected_pending" "$expect_row_none" <<'PY'
import json
import subprocess
import sys
from pathlib import Path

repo_root, queued, blocked, claimed, expected_pending, expect_row_none = sys.argv[1:7]
sys.path.insert(0, str(Path(repo_root) / "hooks"))

import bridge_hook_common as bhc

# Stub queue_cli to return canned summary + find-open responses.
calls = []

class FakeProc:
    def __init__(self, stdout, returncode=0):
        self.stdout = stdout
        self.returncode = returncode

def fake_queue_cli(args):
    calls.append(list(args))
    if args[:1] == ["summary"]:
        row = {
            "queued_count": int(queued),
            "blocked_count": int(blocked),
            "claimed_count": int(claimed),
        }
        return FakeProc(json.dumps([row]))
    if args[:1] == ["find-open"]:
        # Return a top-priority queued task only when queued > 0; for
        # claimed-only setups the daemon would still surface a row, so
        # mirror that.
        if int(queued) + int(claimed) > 0:
            return FakeProc(json.dumps({"id": 42, "priority": "normal", "title": "x"}))
        return FakeProc("")
    return FakeProc("", returncode=1)

bhc.queue_cli = fake_queue_cli

pending, row = bhc.queue_summary("tester")
errors = []
if pending != int(expected_pending):
    errors.append(f"pending={pending} (expected {expected_pending})")
if expect_row_none == "1" and row is not None:
    errors.append(f"row should be None, got {row}")
if expect_row_none == "0" and pending > 0 and row is None:
    errors.append("row should be a dict when pending > 0")
if errors:
    print("\n".join(errors), file=sys.stderr)
    sys.exit(1)
sys.exit(0)
PY
}

# D1a — 1 queued + 1 blocked + 0 claimed → pending=1 (blocked excluded)
if run_case 1 1 0 1 0 2>err.tmp; then
  pass "D1a: queued=1 blocked=1 claimed=0 → pending=1"
else
  fail "D1a: $(cat err.tmp)"
fi

# D1b — 0 queued + 2 blocked + 0 claimed → pending=0, row None (no nudge)
if run_case 0 2 0 0 1 2>err.tmp; then
  pass "D1b: queued=0 blocked=2 claimed=0 → pending=0, no nudge"
else
  fail "D1b: $(cat err.tmp)"
fi

# D1c — 0 queued + 1 blocked + 1 claimed → pending=1 (claimed counts)
if run_case 0 1 1 1 0 2>err.tmp; then
  pass "D1c: queued=0 blocked=1 claimed=1 → pending=1"
else
  fail "D1c: $(cat err.tmp)"
fi

rm -f err.tmp

printf '\n[smoke] queue-pending-summary: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
