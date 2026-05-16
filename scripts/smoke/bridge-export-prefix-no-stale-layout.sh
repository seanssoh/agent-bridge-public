#!/usr/bin/env bash
# scripts/smoke/bridge-export-prefix-no-stale-layout.sh — regression
# for patch ticket #4725 (2026-05-16). On a v2-migrated install the
# operator was seeing the
#   `[경고] BRIDGE_LAYOUT=legacy is a stale pre-v0.8.0 env override...
#    Preferring marker.`
# warning on every CLI invocation, even with a clean shell rc. Root
# cause: `bridge_export_env_prefix` (lib/bridge-core.sh) was
# re-exporting BRIDGE_LAYOUT and BRIDGE_DATA_ROOT from the parent
# process into every spawned child, so once the parent had a stale
# legacy value (e.g. inherited from an old tmux session) every child
# triggered the resolver-demote warning. Fix: remove those two vars
# from the prefix list -- the marker at state/layout-marker.sh is the
# source of truth and the child resolver re-computes the layout
# cleanly.
#
# This test pins:
#   1. Even when BRIDGE_LAYOUT=legacy and BRIDGE_DATA_ROOT=/tmp/x are
#      set in the parent shell, bridge_export_env_prefix does NOT
#      include them in the produced prefix string.
#   2. Other prefix vars (BRIDGE_LAYOUT_MARKER_DIR here as the
#      smoke-friendly probe) continue to be forwarded when set --
#      regression guard against accidentally pruning more than
#      intended.

# Bash 4+ re-exec (sourcing lib/bridge-core.sh needs declare -g and
# associative arrays).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:bridge-export-prefix-no-stale-layout] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="bridge-export-prefix-no-stale-layout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

# Run the prefix computation in a child shell so the smoke harness
# itself is not polluted by sourcing bridge-core. We use a here-doc
# bash invocation (NOT heredoc-stdin to a captured subprocess, so the
# footgun #11 chain is avoided) and write the result to a tmpfile.
TMP_OUT="$(mktemp "${TMPDIR:-/tmp}/agb-prefix.XXXXXX")"
trap 'rm -f "$TMP_OUT"' EXIT

PREFIX_DRIVER="$SCRIPT_DIR/bridge-export-prefix-no-stale-layout-driver.sh"
if [[ ! -x "$PREFIX_DRIVER" ]]; then
  echo "[smoke:${SMOKE_NAME}] missing driver: $PREFIX_DRIVER" >&2
  exit 2
fi

BRIDGE_LAYOUT=legacy \
BRIDGE_DATA_ROOT=/tmp/should-not-be-forwarded \
BRIDGE_LAYOUT_MARKER_DIR=/tmp/marker-fixture \
"$PREFIX_DRIVER" "$REPO_ROOT" >"$TMP_OUT"

PREFIX_OUTPUT="$(cat "$TMP_OUT")"

failed=0

if grep -qE '(^| )BRIDGE_LAYOUT=' <<<"$PREFIX_OUTPUT"; then
  echo "  FAIL  BRIDGE_LAYOUT was forwarded by bridge_export_env_prefix" >&2
  echo "        prefix=${PREFIX_OUTPUT}" >&2
  failed=1
else
  echo "  PASS  BRIDGE_LAYOUT not forwarded"
fi

if grep -qE '(^| )BRIDGE_DATA_ROOT=' <<<"$PREFIX_OUTPUT"; then
  echo "  FAIL  BRIDGE_DATA_ROOT was forwarded by bridge_export_env_prefix" >&2
  echo "        prefix=${PREFIX_OUTPUT}" >&2
  failed=1
else
  echo "  PASS  BRIDGE_DATA_ROOT not forwarded"
fi

if grep -qE '(^| )BRIDGE_LAYOUT_MARKER_DIR=' <<<"$PREFIX_OUTPUT"; then
  echo "  PASS  BRIDGE_LAYOUT_MARKER_DIR forwarded (regression guard)"
else
  echo "  FAIL  BRIDGE_LAYOUT_MARKER_DIR was unexpectedly dropped" >&2
  echo "        prefix=${PREFIX_OUTPUT}" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
