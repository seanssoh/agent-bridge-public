#!/usr/bin/env bash
# bridge-telegram-relay.sh - Telegram polling relay CLI

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-telegram-relay.sh start --token-file <path> [--foreground]
  bash $SCRIPT_DIR/bridge-telegram-relay.sh stop --token-hash <hash>
  bash $SCRIPT_DIR/bridge-telegram-relay.sh status
  bash $SCRIPT_DIR/bridge-telegram-relay.sh health --token-hash <hash>
EOF
}

telegram_relay_state_root() {
  printf '%s/channels/telegram' "$BRIDGE_STATE_DIR"
}

cmd="${1:-}"
case "$cmd" in
  start)
    shift
    bridge_require_python
    exec python3 "$SCRIPT_DIR/lib/telegram-relay.py" start --state-root "$(telegram_relay_state_root)" "$@"
    ;;
  stop)
    shift
    bridge_require_python
    exec python3 "$SCRIPT_DIR/lib/telegram-relay.py" stop --state-root "$(telegram_relay_state_root)" "$@"
    ;;
  status)
    shift
    [[ $# -eq 0 ]] || bridge_die "Usage: bash $SCRIPT_DIR/bridge-telegram-relay.sh status"
    bridge_require_python
    exec python3 "$SCRIPT_DIR/lib/telegram-relay.py" status --state-root "$(telegram_relay_state_root)"
    ;;
  health)
    shift
    bridge_require_python
    exec python3 "$SCRIPT_DIR/lib/telegram-relay.py" health --state-root "$(telegram_relay_state_root)" "$@"
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage
    exit 1
    ;;
esac
