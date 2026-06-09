#!/usr/bin/env bash
# scripts/smoke/v0165-l5-relay-post-hook.sh — BRIDGE_ROOMS_TEST_RELAY_HOOK target.
#
# The leader's receiver leader-relay seam (`_relay_invoke_test_post_hook` in
# bridge-handoffd.py) invokes this with the RE-SIGNED leader->target relay leg
# JSON as $1 (file-as-argv, never stdin — footgun #11). We delegate to the
# helper's `relay-hook` subcommand, which writes the captured request to
# $CAPTURE_FILE and echoes a stub response. Kept as a separate executable so the
# hook contract (`[hook, payload]`) is satisfied with a real argv[0].
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/v0165-l5-relay-roster-helper.py" relay-hook "$1"
