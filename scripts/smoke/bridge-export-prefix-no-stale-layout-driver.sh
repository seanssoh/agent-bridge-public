#!/usr/bin/env bash
# scripts/smoke/bridge-export-prefix-no-stale-layout-driver.sh --
# helper invoked by bridge-export-prefix-no-stale-layout.sh. Kept as a
# standalone file so the smoke driver does not need to embed a
# $()/source pair inline (that nesting failed bash parsing when this
# file was first inlined; the standalone shape avoids that and stays
# resilient to footgun #11 if a future caller wraps the parent driver
# in command substitution).
#
# Usage: bridge-export-prefix-no-stale-layout-driver.sh REPO_ROOT
# Effect: cd into REPO_ROOT, source lib/bridge-core.sh, call
# bridge_export_env_prefix and write the result to stdout.

# Bash 4+ re-exec -- macOS ships /bin/bash 3.2 which cannot source
# lib/bridge-core.sh (needs declare -g and associative arrays). Mirror
# the same prelude used in scripts/smoke/status-engine-detect.sh.
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
  echo "[smoke-driver:bridge-export-prefix-no-stale-layout] needs Bash 4+." >&2
  exit 1
fi

set -euo pipefail

REPO_ROOT="${1:?REPO_ROOT required}"

cd "$REPO_ROOT"
# shellcheck source=/dev/null
source lib/bridge-core.sh

bridge_export_env_prefix
