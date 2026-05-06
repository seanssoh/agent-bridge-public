#!/usr/bin/env bash
# scripts/smoke/cron-scheduler-self-test.sh — Issues #581 / #614 regression.
#
# Routes the in-process Python regression suite at the bottom of
# `bridge-cron-scheduler.py` (`_self_test_581` + `_self_test_614`) to CI by
# invoking `python3 bridge-cron-scheduler.py --self-test` and propagating
# the exit code.
#
# The self-test entry point is fully self-contained — it constructs its
# own in-memory cron state and asserts the deferred-slot retry contract
# (#614) plus the cursor-boundary contract (#581). No isolated BRIDGE_HOME
# fixture is required: the suite never touches disk, the queue, or any
# live runtime surface.

set -euo pipefail

SMOKE_NAME="cron-scheduler-self-test"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

PY_BIN="${PYTHON3:-python3}"
SCHEDULER="$SMOKE_REPO_ROOT/bridge-cron-scheduler.py"

smoke_require_cmd "$PY_BIN"
smoke_assert_file_exists "$SCHEDULER" "bridge-cron-scheduler.py present in repo root"

smoke_log "running bridge-cron-scheduler.py --self-test"
if ! "$PY_BIN" "$SCHEDULER" --self-test; then
  smoke_fail "bridge-cron-scheduler.py --self-test failed (issues #581 / #614)"
fi

smoke_log "passed"
