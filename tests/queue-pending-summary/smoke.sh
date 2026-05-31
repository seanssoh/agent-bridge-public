#!/usr/bin/env bash
# queue-pending-summary smoke — issue #509 D1 follow-up, updated for #1199.
#
# Asserts that hooks/bridge_hook_common.queue_summary counts ONLY queued
# tasks in the ACTION REQUIRED `pending`. The Stop/SessionStart hook only
# nudges with `[Agent Bridge] N pending task(s) … ACTION REQUIRED` when at
# least one genuinely-queued task exists:
#   - blocked tasks (issue #509) wait on external unblock; counting them
#     re-fired the nudge after every `bridge-task update --status blocked`.
#   - claimed tasks (issue #1199) are already being handled; counting them
#     re-fired the nudge the instant an agent/operator ran `agb claim` on a
#     just-delivered `[task-complete]` task — the "immediate re-nudge after
#     claim" symptom. The codex Stop-hook anti-abandonment gate ("continue
#     your open claimed work") is preserved separately in check_inbox.py via
#     open_claimed_count / top_claimed_row — it is NOT this ACTION REQUIRED
#     pending count.
#
# Cases:
#   D1a — 1 queued + 1 blocked + 0 claimed → pending=1 (blocked excluded)
#   D1b — 0 queued + 2 blocked + 0 claimed → pending=0 (no nudge, row None)
#   D1c — 0 queued + 1 blocked + 1 claimed → pending=0 (#1199: claimed
#         excluded; no immediate re-nudge after claim, row None)
#   D1d — 2 queued + 0 blocked + 1 claimed → pending=2 (only the queued
#         tasks count; the claimed one does not inflate N)
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
        # Issue #1199: queue_summary now fetches the "Highest priority" row
        # with `find-open --status-filter queued`, so the row exists iff a
        # genuinely-queued task exists. A claimed task never surfaces a row
        # for the ACTION REQUIRED line.
        if "--status-filter" in args:
            sf = args[args.index("--status-filter") + 1]
            available = int(queued) if sf == "queued" else (
                int(claimed) if sf == "claimed" else int(blocked)
            )
        else:
            available = int(queued) + int(claimed) + int(blocked)
        if available > 0:
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

# D1c — 0 queued + 1 blocked + 1 claimed → pending=0, row None (#1199:
# claimed excluded → no immediate re-nudge after claim)
if run_case 0 1 1 0 1 2>err.tmp; then
  pass "D1c: queued=0 blocked=1 claimed=1 → pending=0, no nudge (#1199)"
else
  fail "D1c: $(cat err.tmp)"
fi

# D1d — 2 queued + 0 blocked + 1 claimed → pending=2 (only queued counts;
# the claimed task does not inflate the ACTION REQUIRED N)
if run_case 2 0 1 2 0 2>err.tmp; then
  pass "D1d: queued=2 blocked=0 claimed=1 → pending=2 (claimed not counted)"
else
  fail "D1d: $(cat err.tmp)"
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
