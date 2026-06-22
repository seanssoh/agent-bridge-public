#!/usr/bin/env bash
# scripts/smoke/2073-autojoin-stale-peer-selfheal-post-hook.sh —
# BRIDGE_ROOMS_TEST_POST_HOOK target for the #2073 self-heal smoke.
#
# Delegates to the helper's `seq-post-hook`, which captures each in-process POST
# to $SEQ_CAPTURE_DIR/post-<n>.json and returns a SEQUENCED verdict from
# $SEQ_POST_STATUSES (comma list of reject/accept). This lets the smoke exercise
# the ACCEPTANCE-ANCHORED self-heal retry: reject the stale-key attempt, accept
# the candidate-key retry. File-as-argv ($1), never stdin (footgun #11).
set -euo pipefail
HERE="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
exec python3 "$HERE/2073-autojoin-stale-peer-selfheal-helper.py" seq-post-hook "$1"
