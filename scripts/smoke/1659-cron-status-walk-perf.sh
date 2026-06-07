#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1659-cron-status-walk-perf.sh — issue #1659.
#
# `agb status` (and `--json`) was CPU-bound (~84s wall / ~80s user) on a host
# with a large cron-run-record backlog (5,632 `state/cron/runs/` records). The
# cron cadence-health walk ran one occurrence-walk per historical run record
# (O(run-records x window-minutes x fields)): 45.9M `expand_atom` calls, 51.8s
# self-time. Two-part fix:
#   (1) bridge-cron-scheduler.py memoizes the pure cron matcher
#       (`allowed_values` -> bounded LRU of immutable frozensets); and
#   (2) bridge-status.py's last_cron_run_by_agent reduces the run-dir to the
#       LATEST run per distinct (agent, job-key) BEFORE the cadence check, so
#       render scales with the number of DISTINCT jobs/schedules, not the total
#       number of run rows — while preserving the per-agent aggregation
#       (ANY owned job in cadence -> in_cadence; most-recent run timestamp)
#       bit-for-bit.
#
# This smoke pins both halves:
#   A: scale — a 25x bigger backlog over the SAME few jobs renders in
#      comparable time (NOT 25x slower); a revert to the per-record walk fails.
#   B: multijob — an agent with a healthy weekly job + an overdue hourly job
#      still latches cron_in_cadence=True (the weekly keeps it healthy) and
#      surfaces the NEWER overdue run as last_cron_run_ts. Proves the
#      per-schedule reduction did NOT collapse to latest-run-per-agent.
#
# Drives bridge-status.py's last_cron_run_by_agent / add_cron_activity_to_metrics
# directly against throwaway BRIDGE_HOME fixtures (no daemon, no queue, no live
# runtime). The python body is carried in a file-as-argv helper — never
# heredoc-stdin (lint-heredoc-ban / footgun #11).

set -euo pipefail

SMOKE_NAME="1659-cron-status-walk-perf"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

STATUS_PY="$SMOKE_REPO_ROOT/bridge-status.py"
SCHED_PY="$SMOKE_REPO_ROOT/bridge-cron-scheduler.py"
HELPER_PY="$SCRIPT_DIR/1659-cron-status-walk-perf-helper.py"

smoke_log "A: bridge-status.py + bridge-cron-scheduler.py compile"
python3 -c "import py_compile; py_compile.compile('$STATUS_PY', doraise=True)" || \
  smoke_fail "bridge-status.py failed py_compile"
python3 -c "import py_compile; py_compile.compile('$SCHED_PY', doraise=True)" || \
  smoke_fail "bridge-cron-scheduler.py failed py_compile"

smoke_log "B: scale — render scales with distinct jobs, not total run rows"
python3 "$HELPER_PY" scale "$STATUS_PY" || \
  smoke_fail "cron cadence-health walk did not scale with distinct jobs (O(run-records) regression?)"

smoke_log "C: multijob — per-schedule reduction preserves aggregation"
python3 "$HELPER_PY" multijob "$STATUS_PY" || \
  smoke_fail "multi-job aggregation regressed (latest-run-per-agent collapse?)"

smoke_log "D: matcher memoization symbols present (no silent revert)"
grep -q 'def allowed_values' "$SCHED_PY" || \
  smoke_fail "bridge-cron-scheduler.py lost the memoized allowed_values matcher"
grep -q 'lru_cache' "$SCHED_PY" || \
  smoke_fail "bridge-cron-scheduler.py lost the bounded matcher cache"
grep -q 'matched_cron_key_for_prefix' "$STATUS_PY" || \
  smoke_fail "bridge-status.py lost the per-job-key reduction helper"

smoke_log "PASS: $SMOKE_NAME"
