#!/usr/bin/env bash
# scripts/smoke/v0165-l5-roster-post-hook.sh — BRIDGE_ROOMS_TEST_POST_HOOK target.
#
# The leader's durable roster-broadcast SENDER (shared `send_roster_broadcast`,
# used by the CLI membership-change path AND the reconcile heartbeat) invokes
# this with the signed roster-broadcast request JSON as $1 (file-as-argv, never
# stdin — footgun #11). We delegate to the helper's `roster-hook` subcommand,
# which writes the captured request to $CAPTURE_FILE and echoes a stub response
# (a 200 ack so the durable outbox row clears).
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/v0165-l5-relay-roster-helper.py" roster-hook "$1"
