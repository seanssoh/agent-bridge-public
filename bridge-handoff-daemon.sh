#!/usr/bin/env bash
# bridge-handoff-daemon.sh — A2A cross-bridge handoff daemon lifecycle.
#
# Manages the receiver daemon (bridge-handoffd.py) and the sender
# delivery runner (bridge-a2a.py deliver). Thin dispatcher — the
# start/stop/status/tick logic lives in lib/bridge-a2a.sh per the repo
# convention (new logic goes into a lib helper, not a root script).

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=lib/bridge-a2a.sh
source "$SCRIPT_DIR/lib/bridge-a2a.sh"

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-handoff-daemon.sh start        # start the receiver
  bash $SCRIPT_DIR/bridge-handoff-daemon.sh stop         # stop the receiver
  bash $SCRIPT_DIR/bridge-handoff-daemon.sh restart
  bash $SCRIPT_DIR/bridge-handoff-daemon.sh status
  bash $SCRIPT_DIR/bridge-handoff-daemon.sh deliver [--batch N] [--timeout S]
  bash $SCRIPT_DIR/bridge-handoff-daemon.sh tick         # receiver-ensure + deliver

The receiver binds to the configured tailnet IP only and fails closed at
startup otherwise (see docs/a2a-cross-bridge.md). Config lives in the
git-ignored data-only file handoff.local.json (mode 0600).
EOF
}

case "${1:-}" in
  start)
    bridge_a2a_receiver_start
    ;;
  stop)
    bridge_a2a_receiver_stop
    ;;
  restart)
    bridge_a2a_receiver_stop
    bridge_a2a_receiver_start
    ;;
  status)
    bridge_a2a_status
    ;;
  deliver)
    shift
    bridge_a2a_deliver_tick "$@"
    ;;
  tick)
    # Ensure the receiver is up, then drain the outbox. Suitable for a
    # cron-driven cadence on installs without an always-on daemon.
    if ! bridge_a2a_receiver_running; then
      bridge_a2a_receiver_start || true
    fi
    bridge_a2a_deliver_tick
    ;;
  -h|--help|help|"")
    usage
    [[ -z "${1:-}" ]] && exit 1
    exit 0
    ;;
  *)
    echo "bridge-handoff-daemon.sh: unknown subcommand: $1" >&2
    usage >&2
    exit 2
    ;;
esac
