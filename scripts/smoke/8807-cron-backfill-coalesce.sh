#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/8807-cron-backfill-coalesce.sh — incident #8807 P1.
#
# After daemon downtime, enumerate_due_runs() in bridge-cron-scheduler.py
# replayed up to BRIDGE_CRON_MAX_CATCHUP_OCCURRENCES_PER_JOB (default 12)
# missed occurrences PER JOB as a single enqueue burst — the "inbox flooding"
# the incident report flagged. For idempotent / picker-sweep families (where
# running the latest occurrence subsumes the missed ones), P1 coalesces the
# catch-up backlog to the most recent occurrence(s) BEFORE enqueue.
#
# This smoke drives bridge-cron-scheduler.py's enumerate_due_runs() directly
# (no daemon, no queue) and asserts the coalesce behaviour + that
# distinct-occurrence families are NOT coalesced + the env overrides + that the
# kept occurrence is the latest. It also pins the scheduler-state.json
# canonical / native-scheduler-state.json compat-copy documentation in
# bridge-cron.sh.

set -euo pipefail

SMOKE_NAME="8807-cron-backfill-coalesce"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

SCHED_PY="$SMOKE_REPO_ROOT/bridge-cron-scheduler.py"
CRON_SH="$SMOKE_REPO_ROOT/bridge-cron.sh"
# Helper carries the python body file-as-argv (no heredoc-stdin — lint-
# heredoc-ban C3 ban; see KNOWN_ISSUES.md §26). Its test-only os.environ
# override lines carry `# noqa: iso-helper-boundary` (the ratchet's `\.env`
# pattern matches the `environ` substring; these are env manipulation, not an
# iso-boundary file access).
HELPER_PY="$SCRIPT_DIR/8807-cron-backfill-coalesce-helper.py"

smoke_log "A1: bridge-cron-scheduler.py compiles"
python3 -c "import py_compile; py_compile.compile('$SCHED_PY', doraise=True)" || \
  smoke_fail "bridge-cron-scheduler.py failed py_compile"

smoke_log "B: catch-up coalescing for idempotent / picker-sweep families"
python3 "$HELPER_PY" coalesce "$SCHED_PY" || \
  smoke_fail "catch-up coalesce behaviour failed"

smoke_log "C: scheduler-state.json canonical / native-scheduler-state.json compat-copy documented"
grep -q 'scheduler-state.json' "$CRON_SH" || smoke_fail "bridge-cron.sh lost the scheduler-state.json reference"
grep -qi 'COMPAT COPY' "$CRON_SH" || \
  smoke_fail "bridge-cron.sh does not document native-scheduler-state.json as a compat copy"
grep -qi 'NOT two active schedulers' "$CRON_SH" || \
  smoke_fail "bridge-cron.sh does not clarify there is a single active scheduler"

smoke_log "PASS: $SMOKE_NAME"
