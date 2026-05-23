#!/usr/bin/env bash
# shellcheck shell=bash
#
# scripts/python-helpers/migrate-layout-shim.sh — canonical layout resolver
# bridge for the legacy-install migrator (issue #1087).
#
# The migrator's apply and verify subcommands need to compute target-side
# per-agent paths (home / workspace / memory) that match the live resolver
# in `lib/bridge-agent-layout.sh`. Hardcoding those paths inside the Python
# helper means any future change to the typed-path contract drifts silently.
#
# This shim sources the real resolver with BRIDGE_HOME repointed at the
# target install and emits the canonical paths as a TAB-separated key=value
# stream on stdout. The Python helper parses the stream and never computes
# layout paths itself.
#
# Usage:
#   migrate-layout-shim.sh <target-bridge-home> [<agent-id>...]
#
# Output (stdout): one record per line. Records are TAB-separated key=value
# pairs. Records of type `top` carry installation-level data; records of
# type `agent` carry per-agent paths. Field values are bytes between TAB
# delimiters; no JSON escaping in shell. Layout invariant: the path
# resolver guarantees no NUL/TAB in paths because BRIDGE_HOME / agent ID
# do not contain TAB and the resolver only joins with `/`.
#
#   type=top<TAB>layout=v2|legacy<TAB>target=<abs><TAB>data_root=<abs|empty><TAB>agent_root_v2=<abs|empty><TAB>agent_home_root=<abs>
#   type=agent<TAB>id=<agent><TAB>home_dir=<abs><TAB>workspace_dir=<abs><TAB>memory_dir=<abs>
#
# Errors go to stderr and exit non-zero. No heredoc-stdin to subprocess —
# footgun #11 safe.

set -euo pipefail

SHIM_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SHIM_DIR/../.." && pwd -P)"

_die() {
  printf '[migrate-layout-shim][error] %s\n' "$*" >&2
  exit 1
}

[[ $# -ge 1 ]] || _die "usage: migrate-layout-shim.sh <target-bridge-home> [<agent-id>...]"

TARGET_HOME="$1"
shift
AGENT_IDS=("$@")

[[ -d "$TARGET_HOME" ]] || _die "target BRIDGE_HOME does not exist: $TARGET_HOME"

# r2 (codex #5723 BLOCKING #2): fail-closed when the target's marker
# disagrees with v2. The migrator only produces v2 installs; if the
# target carries a legacy or unknown marker, the shim must NOT silently
# override it (that's how a malformed target slipped past verify in r1).
EXISTING_MARKER="$(cd -P "$TARGET_HOME" && pwd -P)/state/layout-marker.sh"
if [[ -f "$EXISTING_MARKER" ]]; then
  # Parse BRIDGE_LAYOUT= line conservatively without sourcing untrusted
  # input. Accept both quoted and bare forms.
  MARKER_LAYOUT="$(grep -E '^[[:space:]]*BRIDGE_LAYOUT=' "$EXISTING_MARKER" 2>/dev/null \
                   | tail -n1 \
                   | sed -E 's/^[[:space:]]*BRIDGE_LAYOUT=["'\'']?([^"'\'']*)["'\'']?[[:space:]]*$/\1/')"
  if [[ -n "$MARKER_LAYOUT" && "$MARKER_LAYOUT" != "v2" ]]; then
    _die "target marker reports BRIDGE_LAYOUT='$MARKER_LAYOUT' (expected 'v2'); refusing to force v2 override on a non-v2 install"
  fi
fi

# Repoint BRIDGE_HOME at the target install so the resolver computes
# target-side paths. Clear inherited layout vars so bridge-lib's
# marker-bootstrap + layout-resolver decides fresh against the target,
# then pin the layout to v2 via env-override. v0.8.0 hard-cut: the
# resolver only honors v2 installs, and a fresh-target migrator run is
# by definition markerless until the migrator (or `bridge-init`) writes
# the marker. The env-override path (`BRIDGE_LAYOUT=v2` +
# `BRIDGE_DATA_ROOT=...`) is the documented escape hatch for callers
# that need the canonical paths against a fresh tree (see
# `bridge_resolve_layout` step 1). This is read-only: the shim never
# writes the marker file itself; the migrator's apply step is the
# code path that authors marker-writes against the target.
export BRIDGE_HOME
BRIDGE_HOME="$(cd -P "$TARGET_HOME" && pwd -P)"
unset BRIDGE_AGENT_ROOT_V2 \
      BRIDGE_AGENT_HOME_ROOT \
      BRIDGE_LAYOUT_MARKER_DIR \
      BRIDGE_STATE_DIR \
      BRIDGE_SHARED_ROOT \
      BRIDGE_CONTROLLER_STATE_ROOT \
      BRIDGE_ROSTER_FILE \
      BRIDGE_ROSTER_LOCAL_FILE \
      BRIDGE_TASK_DB
export BRIDGE_LAYOUT="v2"
export BRIDGE_DATA_ROOT="$BRIDGE_HOME/data"

# Source the canonical lib. bridge-lib.sh loads marker-bootstrap +
# layout-resolver + bridge-agents.sh + bridge-agent-layout.sh, so all
# typed-path accessors are available afterward. Send any chatty
# bootstrap output to stderr so only the structured stream lands on
# stdout.
# shellcheck source=/dev/null
source "$REPO_ROOT/bridge-lib.sh" 1>&2

declare -F bridge_layout_agent_home >/dev/null \
  || _die "bridge_layout_agent_home not loaded (bridge-agent-layout.sh missing?)"

# Initialize roster maps so bridge_agent_workdir's
# `BRIDGE_AGENT_WORKDIR[$agent]-` lookup does not trip set -u against an
# uninitialized associative array. The migrator works against a fresh
# target with no roster, so an empty roster is the correct state.
if declare -F bridge_reset_roster_maps >/dev/null; then
  bridge_reset_roster_maps
fi

LAYOUT="legacy"
if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
  LAYOUT="v2"
fi

# Emit top record.
printf 'type=top\tlayout=%s\ttarget=%s\tdata_root=%s\tagent_root_v2=%s\tagent_home_root=%s\n' \
  "$LAYOUT" \
  "$BRIDGE_HOME" \
  "${BRIDGE_DATA_ROOT:-}" \
  "${BRIDGE_AGENT_ROOT_V2:-}" \
  "${BRIDGE_AGENT_HOME_ROOT:-}"

# Emit per-agent records.
for agent in "${AGENT_IDS[@]}"; do
  [[ -n "$agent" ]] || continue
  home_dir="$(bridge_layout_agent_home "$agent")"
  workspace_dir="$(bridge_layout_workspace_dir "$agent")"
  memory_dir="$(bridge_layout_memory_dir "$agent")"
  printf 'type=agent\tid=%s\thome_dir=%s\tworkspace_dir=%s\tmemory_dir=%s\n' \
    "$agent" "$home_dir" "$workspace_dir" "$memory_dir"
done
