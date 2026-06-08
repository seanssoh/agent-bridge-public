#!/usr/bin/env bash
# scripts/smoke/v0165-l4-token-join-post-hook.sh — BRIDGE_ROOMS_TEST_POST_HOOK
# target for the Lane 4 token-bootstrap smoke (#1695).
#
# The cross-node `bridge-rooms.py join` test seam invokes this with the signed
# request JSON as $1 (file-as-argv, never stdin — footgun #11). We delegate to
# the helper's `post-hook` subcommand, which writes the captured request (plus
# the socket CLIENT_IP) to $CAPTURE_FILE and echoes a stub response body.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/v0165-l4-token-join-helper.py" post-hook "$1"
