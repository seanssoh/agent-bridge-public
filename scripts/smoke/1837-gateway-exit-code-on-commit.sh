#!/usr/bin/env bash
#
# Issue #1837 (keystone) + #1834 — queue-gateway CLIENT contract regression smoke.
#
# Under the file-transport queue gateway (socket_listener=off, the default), the
# daemon polls request/response files every ~5s, renames each request to
# <id>.working.json before processing, and ALWAYS writes a responses/<id>.json
# carrying the queue child's REAL exit code (idempotent "already done" -> 0
# included). Under burst load that response arrives late, so the CLIENT's read
# timed out and cmd_client raised "queue gateway timed out" + exit 1 even though
# the write committed. Autonomous callers treated the committed write as a
# failure and RETRIED -> a self-reinforcing thrash (#1837). #1834 is the same
# surface: transient 1-6x per-call timeouts against a live daemon, no built-in
# retry.
#
# CRITICAL: cmd_client runs ONLY as an isolated-agent UID with
# BRIDGE_TASK_DB=/dev/null and BRIDGE_GATEWAY_PROXY=1 — it has NO direct task-DB
# access (the whole reason the gateway exists). So the daemon's response file is
# the only authoritative outcome signal. The fix waits LONGER for that real
# response (bounded retry) and returns its real exit code; it never fabricates a
# success, and never tries to read the DB (impossible here).
#
# This smoke proves the client contract A1 owns:
#   1. (#1834) A transient flap whose response lands after the 1s base-timeout
#      floor but inside the bounded retry window -> exit 0, no caller loop.
#   2. (#1837) The client returns the daemon's REAL exit code — a late NONZERO
#      response stays nonzero (never masked into 0).
#   3. (#1837 keystone) A late idempotent-success response (exit 0) returns 0,
#      NOT a false exit 1 that would trigger the retry storm.
#   4. A truly unresponsive daemon -> honest nonzero timeout + no stale request
#      left behind (re-queue / thrash guard).
#   5. The client works with NO DB access (BRIDGE_TASK_DB=/dev/null + proxy env,
#      the real iso shape) — the fix never depends on a direct DB read.
#   6. (#1837 fix 4) The daemon-down primitive gateway_daemon_liveness():
#      `unknown` (NOT `down`) when daemon.pid is unreadable/absent (the primitive
#      A3/#1833 consumes), `up`/`down` for a readable pid.
#
# Every Python step is driven through the file-as-argv sidecar
# scripts/smoke/1837-gateway-exit-code-on-commit-helper.py (footgun #11 / C1:
# NO `python3 - <<'PY'` heredoc-stdin to a subprocess anywhere in this smoke).

set -euo pipefail

SMOKE_NAME="1837-gateway-exit-code-on-commit"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/${SMOKE_NAME}-helper.py"

trap smoke_cleanup_temp_root EXIT

run_helper() {
  local subcmd="$1"
  local out
  out="$(GW_ROOT="$GW_ROOT" python3 "$HELPER" "$subcmd" 2>&1 || true)"
  printf '%s' "$out"
}

retry_absorbs_flap() {
  local out
  out="$(run_helper retry-absorbs-flap)"
  smoke_assert_contains "$out" "ok-retry-absorbs-flap" \
    "#1834: a transient flap is absorbed by the bounded read-side retry (exit 0, no caller loop)"
}

returns_real_exit_code() {
  local out
  out="$(run_helper returns-real-exit-code)"
  smoke_assert_contains "$out" "ok-returns-real-exit-code" \
    "#1837: the client returns the daemon's REAL exit code (a late nonzero stays nonzero)"
}

idempotent_success_returns_zero() {
  local out
  out="$(run_helper idempotent-success-returns-zero)"
  smoke_assert_contains "$out" "ok-idempotent-success-returns-zero" \
    "#1837 keystone: a late idempotent-success response returns 0, not a false exit 1"
}

genuine_timeout_nonzero() {
  local out
  out="$(run_helper genuine-timeout-nonzero)"
  smoke_assert_contains "$out" "ok-genuine-timeout-nonzero" \
    "#1837: an unresponsive daemon yields an honest nonzero timeout + no stale request (no re-queue)"
}

no_db_access_required() {
  local out
  out="$(run_helper no-db-access-required)"
  smoke_assert_contains "$out" "ok-no-db-access-required" \
    "#1837: the client works under the real iso shape (BRIDGE_TASK_DB=/dev/null) — no direct DB read"
}

daemon_liveness_primitive() {
  local out
  out="$(run_helper daemon-liveness-primitive)"
  smoke_assert_contains "$out" "ok-daemon-liveness-primitive" \
    "#1837: daemon-down primitive reports unknown (not down) when daemon.pid is unreadable"
}

main() {
  smoke_require_cmd python3
  smoke_assert_file_exists "$HELPER" "1837 helper sidecar present"
  smoke_setup_bridge_home "$SMOKE_NAME"
  python3 "$SMOKE_REPO_ROOT/bridge-queue.py" init >/dev/null

  # A short gateway root under the isolated bridge home (per-agent
  # requests/responses dirs are created by the helper).
  GW_ROOT="$BRIDGE_STATE_DIR/queue-gateway"
  export GW_ROOT
  mkdir -p "$GW_ROOT"

  smoke_run "transient flap absorbed by bounded retry (#1834)" retry_absorbs_flap
  smoke_run "client returns the daemon's real exit code (#1837)" returns_real_exit_code
  smoke_run "late idempotent-success response -> exit 0 (keystone)" idempotent_success_returns_zero
  smoke_run "unresponsive daemon -> honest nonzero + no re-queue" genuine_timeout_nonzero
  smoke_run "works under /dev/null-DB iso shape (no direct DB read)" no_db_access_required
  smoke_run "daemon-down primitive: unknown not down across iso boundary" daemon_liveness_primitive

  smoke_log "passed"
}

main "$@"
