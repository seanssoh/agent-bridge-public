#!/usr/bin/env bash
# scripts/smoke/1623-a2a-backpressure-failopen.sh
#
# Issue #1623: the A2A inbound backpressure check must FAIL OPEN when the
# open-task COUNT cannot be computed. The per-peer max_open_tasks cap is an
# optional throttle, NOT a security gate; a sqlite3.DatabaseError from
# count_open_remote_tasks (e.g. the read-only WAL open of tasks.db transiently
# raising "unable to open database file") must skip the cap and proceed to
# enqueue an already-authenticated handoff (loud backpressure_count_skip audit),
# NOT 503-bounce it. The genuine over-cap case keeps its 429.
#
# Also pins the secondary hardening: _open_queue_db_readonly survives a WAL-mode
# tasks.db across daemon write/idle cycles without surfacing a hard error.
#
# Security invariants (HMAC / tailnet bind / remote_addr / allowlist / dedupe /
# room-scope) are untouched by this change and are exercised by the existing
# A2A smokes; this smoke covers ONLY the capacity-count failure mode.

set -euo pipefail

SMOKE_NAME="1623-a2a-backpressure-failopen"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

run_unit() {
  python3 "$SCRIPT_DIR/1623-a2a-backpressure-failopen-helper.py" "$SMOKE_REPO_ROOT"
}

main() {
  smoke_require_cmd python3
  smoke_setup_bridge_home "$SMOKE_NAME"
  smoke_run "#1623 A2A backpressure fails OPEN on count error" run_unit
  smoke_log "passed"
}

main "$@"
