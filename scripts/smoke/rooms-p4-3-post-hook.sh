#!/usr/bin/env bash
# scripts/smoke/rooms-p4-3-post-hook.sh — BRIDGE_ROOMS_TEST_POST_HOOK target.
#
# The sender's `bridge-rooms.py talk` room-scoped enqueue test seam invokes this
# with the signed request JSON as $1 (file-as-argv, never stdin — footgun #11).
# We delegate to the helper's `post-hook` subcommand, which writes the captured
# request to $CAPTURE_FILE and echoes a stub response body. Kept as a separate
# executable so the CLI hook contract (`[hook, payload]`) is satisfied with a
# real argv[0].
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/rooms-p4-3-room-talk-helper.py" post-hook "$1"
