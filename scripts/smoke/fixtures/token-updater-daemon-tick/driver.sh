#!/usr/bin/env bash
# args: <action: due|tick|checkin|state-file>
#
# Drives the extracted token-updater lease daemon functions against the
# bridge-auth.sh lease shim + the REAL bridge-daemon-helpers.py parse
# commands. Stubs the daemon-side helpers (daemon_info/daemon_warn/
# bridge_audit_log/bridge_with_timeout) so the smoke can assert audit rows.
set -uo pipefail

: "${SHIM_DIR:?}"
: "${BRIDGE_STATE_DIR:?}"
: "${FUNCS_SH:?}"
: "${AUDIT_FILE:?}"

# The function bodies reference "$SCRIPT_DIR/bridge-auth.sh" and
# "$SCRIPT_DIR/bridge-daemon-helpers.py" — point that at our shim dir.
SCRIPT_DIR="$SHIM_DIR"
BRIDGE_BASH_BIN="${BASH:-bash}"
export BRIDGE_STATE_DIR

daemon_info() { printf '[info] %s\n' "$*" >&2; }
daemon_warn() { printf '[warn] %s\n' "$*" >&2; }

# Capture every bridge_audit_log call as one line in $AUDIT_FILE.
bridge_audit_log() {
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

# bridge_with_timeout — pass-through (no real timeout binary needed). When
# WITH_TIMEOUT_ARGV_LOG is set, record the FULL subprocess argv (post shift-2)
# it is about to exec, so a smoke can assert a secret-bearing envelope never
# reaches a parser positionally (codex #2248 finding 2 regression guard). Real
# `timeout(1)`/gtimeout would exec the same argv, so this proxy is faithful.
bridge_with_timeout() {
  shift 2 || true
  if [[ -n "${WITH_TIMEOUT_ARGV_LOG:-}" ]]; then
    printf '%s\n' "$*" >>"$WITH_TIMEOUT_ARGV_LOG"
  fi
  "$@"
}

# shellcheck source=/dev/null
source "$FUNCS_SH"

action="${1:-}"
case "$action" in
  due)
    if bridge_daemon_token_lease_due; then echo "DUE"; else echo "NOT-DUE"; fi
    ;;
  tick)
    if bridge_daemon_token_lease_tick; then echo "TICK-OK"; else echo "TICK-FAIL"; fi
    ;;
  checkin)
    # Never exits non-zero by contract; echo a marker unconditionally.
    bridge_daemon_token_lease_checkin_on_exit
    echo "CHECKIN-DONE"
    ;;
  state-file)
    bridge_daemon_token_lease_state_file
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 2
    ;;
esac
