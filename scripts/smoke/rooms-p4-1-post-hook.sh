#!/usr/bin/env bash
# scripts/smoke/rooms-p4-1-post-hook.sh — BRIDGE_ROOMS_TEST_POST_HOOK target.
#
# The cross-node `bridge-rooms.py join` test seam invokes this with the signed
# request JSON as $1 (file-as-argv, never stdin — footgun #11). We delegate to
# the helper's `post-hook` subcommand, which writes the captured request to
# $CAPTURE_FILE and echoes a stub response body. Kept as a separate executable
# so the CLI hook contract (`[hook, payload]`) is satisfied with a real argv[0].
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/rooms-p4-1-cross-node-join-helper.py" post-hook "$1"
