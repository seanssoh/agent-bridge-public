#!/usr/bin/env bash
# args: <action: due|tick> [extra args ignored]
set -uo pipefail

# Required env (caller sets all):
#   SHIM_DIR, BRIDGE_STATE_DIR, FUNCS_SH, AUDIT_FILE
: "${SHIM_DIR:?}"
: "${BRIDGE_STATE_DIR:?}"
: "${FUNCS_SH:?}"
: "${AUDIT_FILE:?}"

# Daemon function bodies reference "$SCRIPT_DIR/bridge-auth.sh" and
# "$SCRIPT_DIR/bridge-daemon-helpers.py" — point that at our shim dir.
SCRIPT_DIR="$SHIM_DIR"
BRIDGE_BASH_BIN="${BASH:-bash}"
export BRIDGE_STATE_DIR

# Stubs for daemon-side helpers the function body calls. We capture every
# bridge_audit_log call as one line per row in $AUDIT_FILE so the smoke
# can grep the action + status fields after the call.
daemon_info()  { printf '[info] %s\n' "$*" >&2; }
daemon_warn()  { printf '[warn] %s\n' "$*" >&2; }
bridge_audit_log() {
  # signature: <actor> <action> <target> [--detail k=v ...]
  local actor="$1" action="$2" target="$3"; shift 3 || true
  local row="action=$action actor=$actor target=$target"
  while (( $# )); do
    if [[ "$1" == "--detail" ]]; then
      shift
      row+=" $1"
    fi
    shift || true
  done
  printf '%s\n' "$row" >>"$AUDIT_FILE"
}
# bridge_with_timeout — pass-through (no real timeout binary needed; the
# shim helper returns instantly). Mirrors the test-double in
# tests/codex-composer/smoke.sh.
bridge_with_timeout() {
  # <secs> <label> <cmd> [args...]
  shift 2 || true
  "$@"
}

# Source the extracted function bodies.
# shellcheck source=/dev/null
source "$FUNCS_SH"

action="${1:-}"
case "$action" in
  due)
    if bridge_daemon_periodic_token_sync_due; then
      echo "DUE"
    else
      echo "NOT-DUE"
    fi
    ;;
  tick)
    if bridge_daemon_periodic_token_sync_tick; then
      echo "TICK-OK"
    else
      echo "TICK-FAIL"
    fi
    ;;
  state-file)
    bridge_daemon_periodic_token_sync_state_file
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 2
    ;;
esac
