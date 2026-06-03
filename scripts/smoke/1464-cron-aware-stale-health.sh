#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1464-cron-aware-stale-health.sh — issue #1464.
#
# bridge-status.py's classify_stale produced a constant false-positive
# `health crit=N` for static agents whose work is entirely scheduled-cron
# driven (the owning interactive session is idle while the cron child does the
# work). PR #1465 added a cron-activity signal so those agents stop reading
# crit. The first cut, however, masked GENUINELY-overdue cron agents: ANY
# recent cron run returned `ok`, so an hourly job whose last run was 35h ago
# (badly overdue) still read healthy.
#
# This smoke pins the cadence-aware contract:
#   (a) a schedule-driven idle static agent whose cron fired WITHIN its cadence
#       classifies healthy (`ok`) — the false-crit #1464 set out to fix.
#   (b) a schedule-driven static agent whose cron is OVERDUE relative to its
#       cadence (hourly job last run 35h ago) is STILL stale, not masked `ok`.
#   TEETH: reverting to the blanket "any recent cron run -> ok" makes case (b)
#       wrongly read `ok`; the teeth mode asserts the blanket logic genuinely
#       produces that wrong answer, so a cadence-gate revert is caught.
#
# Drives bridge-status.py's last_cron_run_by_agent / add_cron_activity_to_metrics
# / classify_agent_stale directly against throwaway BRIDGE_HOME fixtures (no
# daemon, no queue, no live runtime). The python body is carried in a file-as-
# argv helper — never heredoc-stdin (lint-heredoc-ban / footgun #11).

set -euo pipefail

SMOKE_NAME="1464-cron-aware-stale-health"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

STATUS_PY="$SMOKE_REPO_ROOT/bridge-status.py"
HELPER_PY="$SCRIPT_DIR/1464-cron-aware-stale-health-helper.py"

smoke_log "A: bridge-status.py compiles"
python3 -c "import py_compile; py_compile.compile('$STATUS_PY', doraise=True)" || \
  smoke_fail "bridge-status.py failed py_compile"

smoke_log "B: cadence-aware classification — within-cadence ok + overdue still stale"
python3 "$HELPER_PY" classify "$STATUS_PY" || \
  smoke_fail "cadence-aware staleness classification failed"

smoke_log "C: teeth — blanket revert wrongly marks the overdue hourly agent ok"
python3 "$HELPER_PY" teeth "$STATUS_PY" || \
  smoke_fail "teeth check failed (smoke would not catch a cadence-gate revert)"

smoke_log "D: bridge-status.py keeps the cadence gate symbols (no silent revert)"
grep -q 'cron_in_cadence' "$STATUS_PY" || \
  smoke_fail "bridge-status.py lost the cron_in_cadence cadence gate"
grep -q 'cron_run_in_cadence' "$STATUS_PY" || \
  smoke_fail "bridge-status.py lost the cadence-aware overdue check"

smoke_log "PASS: $SMOKE_NAME"
