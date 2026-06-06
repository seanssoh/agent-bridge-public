#!/usr/bin/env bash
# scripts/smoke/1594-rooms-fanout-local-hook.sh — BRIDGE_ROOMS_TEST_LOCAL_HOOK
# target for the rooms whole-room fan-out smoke.
#
# Invoked with the would-be LOCAL-leg `bridge-task.sh create` request JSON as $1
# (file-as-argv, never stdin — footgun #11). Delegates to the helper's
# `local-hook`, which APPENDS the captured create to $LOCAL_CAPTURE and exits
# non-zero for any target in $LOCAL_FAIL_FOR (to drive the partial-failure
# tooth), so the smoke can assert local delivery WITHOUT a live queue.
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/1594-rooms-fanout-helper.py" local-hook "$1"
