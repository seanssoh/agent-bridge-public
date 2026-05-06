#!/usr/bin/env bash
# Issue #614 — scheduler deferred-retry regression smoke.
#
# Runs the Python unit tests in test_pending_retries.py against the
# repo's bridge-cron-scheduler.py. Three scenarios assert the new
# enumerate_pending_retries + cmd_sync dedup logic:
#
#   1. daily cron deferred at 06:00 with nextRunAtMs=06:15 → retry at 06:15
#   2. deferred `at` job → same retry behaviour
#   3. retry + next natural occurrence both due → both enqueue exactly once
#
# Usage: ./tests/cron-deferred-retry/smoke.sh
# Exit 0 = pass, exit 1 = fail.

set -uo pipefail

THIS_DIR="$(cd "$(dirname "$0")" && pwd)"

python3 "$THIS_DIR/test_pending_retries.py"
