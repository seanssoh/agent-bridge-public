#!/usr/bin/env bash
# scripts/smoke/tmux-server-bridge-layout-cleanup-driver.sh —
# child-process driver for tmux-server-bridge-layout-cleanup.sh
# C2 check. Kept as a standalone file (per the
# `bridge-export-prefix-no-stale-layout-driver.sh` precedent) so the
# parent smoke does not have to embed a here-doc body that would trip
# the Bash 5.3.9 heredoc-stdin deadlock when sample environments
# happen to nest the smoke inside a `$(...)` capture (footgun #11).
#
# Usage: tmux-server-bridge-layout-cleanup-driver.sh REPO_ROOT
# Effect: sources bridge-lib.sh, then re-sources
#   lib/bridge-layout-resolver.sh TWICE with BRIDGE_LAYOUT=legacy in
#   the env each time. The parent smoke greps the combined output for
#   the resolver's stale-env warning marker to verify the
#   `_BRIDGE_LAYOUT_STALE_ENV_WARNED` once-per-process gate holds.
#
# Both sources run in the SAME process so the sentinel survives.
# Between sources the BRIDGE_LAYOUT_SOURCE / ignored-partial-env state
# vars are blanked so the resolver re-enters the env-override branch
# and would re-emit the warning if the gate were missing.

# Bash 4+ re-exec — bridge-lib.sh requires declare -g + assoc arrays.
_DRIVER_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_DRIVER_TARGET" ]]; then
    for cand in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$cand" && -x "$cand" ]] || continue
      if "$cand" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$cand" "$_DRIVER_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke-driver:tmux-server-bridge-layout-cleanup] needs Bash 4+." >&2
  exit 1
fi

set -euo pipefail

REPO_ROOT="${1:?REPO_ROOT required}"

# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh"

# Re-source the resolver with a freshly-primed stale env value, twice.
# The first call must emit the warning; the second must not.
BRIDGE_LAYOUT_SOURCE=""
BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV=""
export BRIDGE_LAYOUT=legacy
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-layout-resolver.sh"

echo "----second-source----"

BRIDGE_LAYOUT_SOURCE=""
BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV=""
export BRIDGE_LAYOUT=legacy
# shellcheck source=/dev/null
source "$REPO_ROOT/lib/bridge-layout-resolver.sh"
