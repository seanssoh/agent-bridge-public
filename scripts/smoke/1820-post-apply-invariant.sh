#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1820-post-apply-invariant.sh — Issue #1820 post-apply invariant.
#
# Verdict gate (post-apply invariant): "static/source ratchet or smoke grep
# proves the four named runtime writers no longer use raw
# `$BRIDGE_AGENT_HOME_ROOT/<agent>` / `<bridge_home>/agents/<a>` for runtime
# identity writes on v2."
#
# This is a SOURCE-level invariant: each of the four writer surfaces must route
# its v2 path through a layout-aware resolver (marker / *_RESOLVED env /
# bridge_agent_default_home / --home-subdir) rather than hard-coding the v1
# tree. It runs against the live source files (no fixture) so a future edit that
# re-introduces a raw v1 write trips CI.

set -uo pipefail
SMOKE_NAME="1820-post-apply-invariant"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"
REPO_ROOT="$SMOKE_REPO_ROOT"

FAILS=0
chk() {
  local label="$1"; shift
  if "$@"; then smoke_log "PASS: $label"; else
    printf '[smoke:%s][error] FAIL: %s\n' "$SMOKE_NAME" "$label" >&2
    FAILS=$((FAILS + 1))
  fi
}

# Writer 1 (cron): _shared_agent_claude_config_candidates must source the data
# root from the layout marker (so it resolves v2 from BRIDGE_HOME alone).
chk "cron writer routes via layout marker (_layout_marker_data_root)" \
  grep -q '_layout_marker_data_root' "$REPO_ROOT/bridge-cron-runner.py"
chk "cron bridge_data_root prefers marker over bare bridge_home" \
  grep -q 'marker_data_root = _layout_marker_data_root()' "$REPO_ROOT/bridge-cron-runner.py"

# Writer 2 (PreCompact): _agent_home must read the *_RESOLVED aliases before the
# v1 legacy fallback.
chk "pre-compact reads BRIDGE_AGENT_WORKDIR_RESOLVED" \
  grep -q 'BRIDGE_AGENT_WORKDIR_RESOLVED' "$REPO_ROOT/hooks/pre-compact.py"
chk "pre-compact reads BRIDGE_AGENT_HOME_RESOLVED" \
  grep -q 'BRIDGE_AGENT_HOME_RESOLVED' "$REPO_ROOT/hooks/pre-compact.py"
# The resolved aliases must appear BEFORE the v1 `agents/<agent>` fallback line.
chk "pre-compact resolved-aliases precede the v1 fallback" \
  bash -c '
    f="'"$REPO_ROOT"'/hooks/pre-compact.py"
    resolved=$(grep -n "BRIDGE_AGENT_WORKDIR_RESOLVED" "$f" | head -1 | cut -d: -f1)
    fallback=$(grep -n "\"agents\" / agent" "$f" | head -1 | cut -d: -f1)
    [[ -n "$resolved" && -n "$fallback" && "$resolved" -lt "$fallback" ]]
  '

# Writer 3 (settings): per-agent effective resolver must consult the v2-aware
# bridge_agent_default_home rather than only $BRIDGE_AGENT_HOME_ROOT.
chk "settings effective resolver consults bridge_agent_default_home" \
  bash -c '
    awk "/^bridge_hook_per_agent_settings_effective_file\(\)/{f=1} f&&/bridge_agent_default_home/{print; exit}" \
      "'"$REPO_ROOT"'/lib/bridge-hooks.sh" | grep -q bridge_agent_default_home
  '

# Writer 4 (doc-sync): caller must point target-root at the v2 agents root +
# --home-subdir when v2 is active.
chk "doc-sync caller routes to BRIDGE_AGENT_ROOT_V2 + --home-subdir on v2" \
  bash -c '
    f="'"$REPO_ROOT"'/lib/bridge-skills.sh"
    grep -q "doc_target_root=\"\$BRIDGE_AGENT_ROOT_V2\"" "$f" \
      && grep -q -- "--home-subdir home" "$f"
  '
chk "bridge-docs.py supports --home-subdir" \
  grep -q -- '--home-subdir' "$REPO_ROOT/bridge-docs.py"

if [[ "$FAILS" -ne 0 ]]; then
  smoke_fail "$FAILS post-apply invariant check(s) failed — a writer still targets the v1 tree"
fi
smoke_log "all post-apply invariant checks PASS (#1820): no writer hard-targets v1 on v2"
