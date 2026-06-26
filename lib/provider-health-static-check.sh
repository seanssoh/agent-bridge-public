#!/usr/bin/env bash
# lib/provider-health-static-check.sh — static-agent validation seam for the
# provider-health outage oracle's FLEET quorum (#2066 P1a, codex d2).
#
# The python oracle (bridge-provider-health.py) is roster-blind (iso-adjacent),
# so it cannot validate that a reported agent name is a REGISTERED STATIC agent.
# Without that binding, a single process reporting twice under two invented names
# would reach fleet quorum. This standalone helper IS the binding: it loads the
# roster and runs the canonical `bridge_agent_is_static` predicate
# (lib/bridge-agents.sh), exiting 0 iff the agent is a registered static agent.
#
# Called file-as-argv by the oracle via BRIDGE_FALLBACK_STATIC_CHECK_CMD:
#   bash lib/provider-health-static-check.sh <agent>
#
# Fail-CLOSED: any error (unknown agent, roster-load failure, missing predicate)
# exits non-zero so an unvalidated name never counts toward fleet promotion. A
# scoped DOWN for the single triggering agent does NOT depend on this check.

set -uo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")/.." 2>/dev/null && pwd -P)"

agent="${1:-}"
[[ -n "$agent" ]] || exit 2

# Source the full lib (provides the roster loader + bridge_agent_is_static).
# Quiet: this is a predicate, not a UX surface.
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh" >/dev/null 2>&1 || exit 3

if ! declare -F bridge_load_roster >/dev/null 2>&1 || ! declare -F bridge_agent_is_static >/dev/null 2>&1; then
  exit 3
fi

bridge_load_roster >/dev/null 2>&1 || exit 3

# bridge_agent_is_static requires the agent to EXIST in the roster (a non-existent
# / invented name is not static). Guard existence first when the predicate is
# available, then the static check.
if declare -F bridge_agent_exists >/dev/null 2>&1; then
  bridge_agent_exists "$agent" >/dev/null 2>&1 || exit 1
fi
bridge_agent_is_static "$agent" >/dev/null 2>&1 || exit 1
exit 0
