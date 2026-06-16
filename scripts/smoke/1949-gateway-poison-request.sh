#!/usr/bin/env bash
#
# Issue #1949 (F8) — queue-gateway serve-once poison-request batch-crash smoke.
#
# A single poison request silently killed the WHOLE fleet's queue gateway:
# `cmd_serve_once` called `handle_request` with NO per-request try/except, and
# `run_queue` did `subprocess.run(cwd=<client-recorded cwd>)`. An iso agent that
# ran `agb` from inside a 0700 iso-owned dir (e.g. `.teams/attachments/<id>`)
# recorded a path the controller-run gateway server could not chdir into →
# PermissionError aborted the entire batch, and the request — already promoted
# to `<id>.working.json` — re-crashed every tick (permanent loop). Every other
# agent's queued request then timed out forever (the real root of the #1944/F6
# nudge churn).
#
# The fix: (A) run_queue falls back to a controller-safe cwd when the recorded
# cwd is missing/inaccessible (queue ops key off BRIDGE_* env + the DB, not cwd),
# and (B) cmd_serve_once wraps each handle_request in a per-request try/except
# that dead-letters the poison out of the drain and CONTINUES the batch.
#
# This smoke proves the batch SURVIVES: serve-once with a poison-cwd request +
# a malformed `.working.json` + a healthy sibling exits 0, drains the healthy
# request, and retires both poisons out of the drain — where the OLD code exited
# 1 on the first poison and left a re-crashing `.working.json`.
#
# Every Python step is driven through the file-as-argv sidecar
# scripts/smoke/1949-gateway-poison-request-helper.py (footgun #11 / C1: NO
# `python3 - <<'PY'` heredoc-stdin to a subprocess anywhere in this smoke).

set -euo pipefail

SMOKE_NAME="1949-gateway-poison-request"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/${SMOKE_NAME}-helper.py"

trap smoke_cleanup_temp_root EXIT

smoke_make_temp_root
GW_ROOT="$SMOKE_TMP_ROOT/gw"
mkdir -p "$GW_ROOT"

run_helper() {
  python3 "$HELPER" "$1" "$GW_ROOT" 2>&1 || true
}

main() {
  local out

  out="$(run_helper setup)"
  case $'\n'"$out"$'\n' in
    *$'\nok-setup\n'*) smoke_log "$SMOKE_NAME: setup (poison-cwd + malformed + healthy) ok" ;;
    *) smoke_fail "$SMOKE_NAME: setup failed: $out" ;;
  esac

  out="$(run_helper run)"
  case $'\n'"$out"$'\n' in
    *$'\nok-run '*) smoke_log "$SMOKE_NAME: serve-once survived the poison batch (exit 0)" ;;
    *) smoke_fail "$SMOKE_NAME: serve-once aborted on a poison request: $out" ;;
  esac

  out="$(run_helper assert)"
  case $'\n'"$out"$'\n' in
    *$'\nok-assert'*) smoke_log "$SMOKE_NAME: healthy drained; poisons retired out of the drain" ;;
    *) smoke_fail "$SMOKE_NAME: post-batch state wrong: $out" ;;
  esac

  smoke_log "$SMOKE_NAME: passed"
}

main "$@"
