#!/usr/bin/env bash
# scripts/smoke/1594-rooms-fanout-post-hook.sh — BRIDGE_ROOMS_TEST_POST_HOOK
# target for the rooms whole-room fan-out smoke.
#
# Invoked with the signed REMOTE-leg enqueue request JSON as $1 (file-as-argv,
# never stdin — footgun #11). Delegates to the helper's `post-hook`, which
# APPENDS the captured request to $POST_CAPTURE (one JSON per line) so a fan-out
# that targets multiple remote members captures each hop.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/1594-rooms-fanout-helper.py" post-hook "$1"
