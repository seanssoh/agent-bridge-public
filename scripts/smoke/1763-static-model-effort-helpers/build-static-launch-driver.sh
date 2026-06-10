#!/usr/bin/env bash
# scripts/smoke/1763-static-model-effort-helpers/build-static-launch-driver.sh
#
# Issue #1763 — driver for the static-Claude model/effort injection smoke.
# Loads the production bridge-lib.sh against a hermetic BRIDGE_HOME,
# composes a roster-local file that defines a single static claude agent
# with a baked LAUNCH_CMD plus the (optional) BRIDGE_AGENT_MODEL /
# BRIDGE_AGENT_EFFORT lines that `agent update --model/--effort`
# materializes, then invokes the real `bridge_build_static_claude_launch_cmd`
# and prints the rendered launch command on stdout behind a sentinel the
# parent smoke parses.
#
# This exercises the exact production builder reached for source=static +
# engine=claude + non-empty BRIDGE_AGENT_LAUNCH_CMD — the path that, pre
# #1763, ignored the roster model/effort entirely (silent no-op). We call
# the builder directly (not the full bridge_agent_launch_cmd dispatcher) so
# the assertion is byte-precise and does not depend on channel/webhook
# injection wrappers.
#
# The roster maps (BRIDGE_AGENT_*) are `declare -g -A` GLOBALS created and
# populated by bridge_load_roster; the roster-local file is sourced from
# inside that function, so the per-agent assignments here resolve against a
# declared associative array (NOT an arithmetic subscript under `set -u`).
# We therefore compose the agent definition into the roster-local file and
# let bridge_load_roster parse it — the same shape as
# scripts/smoke/835-static-admin-launch-helpers/static-admin-roster.sh.
#
# Shipped as a tracked file (rather than a heredoc-to-file body inside the
# smoke wrapper). The roster-local file is assembled with line-at-a-time
# `printf >>` appends — no heredoc-stdin, no heredoc-to-file. (Forbidden
# pattern strings intentionally omitted from this comment so the footgun #11
# self-audit grep recipe does not flag a textual mention as a real callsite.)
#
# Invocation:
#   bash build-static-launch-driver.sh \
#     <repo_root> <bridge_home> <agent_id> <continue_mode> \
#     <launch_cmd> <model> <effort>
#
# Output (on success, stdout):
#   LAUNCH_CMD=<rendered>
#
# Exits non-zero on internal failure.

set -euo pipefail

repo_root="$1"
bridge_home="$2"
agent_id="$3"
continue_mode="$4"
launch_cmd="$5"
model="$6"
effort="$7"

# Re-export the hermetic BRIDGE_HOME so bridge-lib.sh sees the temp tree
# (the parent smoke set it via smoke_setup_bridge_home, but it lives in its
# own shell — we are a fresh subprocess).
export BRIDGE_HOME="$bridge_home"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_AGENT_ENV_FILE=""   # force the file-based roster path, not the
                                  # isolated agent env path.

mkdir -p "$BRIDGE_AGENT_HOME_ROOT/$agent_id"

# Compose the roster-local file line-at-a-time. Each assignment targets a
# BRIDGE_AGENT_* map that bridge_load_roster declares before sourcing this
# file. The MODEL/EFFORT lines are emitted ONLY when non-empty — an absent
# line is exactly the legacy-launch (pre-materialize) shape, and that
# empty/present distinction is what the static builder keys off.
: >"$BRIDGE_ROSTER_LOCAL_FILE"
{
  # BRIDGE_AGENT_MODEL / BRIDGE_AGENT_EFFORT are declared by the main
  # agent-roster.sh in a live install (not by bridge_reset_roster_maps, which
  # is why bridge_agent_model/effort carry the #1627 is-assoc guard). Our
  # hermetic BRIDGE_ROSTER_FILE is empty, so declare them here before the
  # per-agent assignment — otherwise `BRIDGE_AGENT_MODEL[<a>]=` is an
  # arithmetic subscript that aborts under `set -u`.
  printf 'declare -gA BRIDGE_AGENT_MODEL >/dev/null 2>&1 || true\n'
  printf 'declare -gA BRIDGE_AGENT_EFFORT >/dev/null 2>&1 || true\n'
  printf 'bridge_add_agent_id_if_missing %q\n' "$agent_id"
  printf 'BRIDGE_AGENT_ENGINE[%q]=%q\n' "$agent_id" "claude"
  printf 'BRIDGE_AGENT_SESSION[%q]=%q\n' "$agent_id" "${agent_id}-session"
  printf 'BRIDGE_AGENT_WORKDIR[%q]=%q\n' "$agent_id" "$BRIDGE_AGENT_HOME_ROOT/$agent_id"
  printf 'BRIDGE_AGENT_LAUNCH_CMD[%q]=%q\n' "$agent_id" "$launch_cmd"
  printf 'BRIDGE_AGENT_LOOP[%q]=%q\n' "$agent_id" "0"
  printf 'BRIDGE_AGENT_CONTINUE[%q]=%q\n' "$agent_id" "$continue_mode"
  if [[ -n "$model" ]]; then
    printf 'BRIDGE_AGENT_MODEL[%q]=%q\n' "$agent_id" "$model"
  fi
  if [[ -n "$effort" ]]; then
    printf 'BRIDGE_AGENT_EFFORT[%q]=%q\n' "$agent_id" "$effort"
  fi
} >>"$BRIDGE_ROSTER_LOCAL_FILE"

# Source the production library exactly the way bridge-start.sh does.
# shellcheck source=../../../bridge-lib.sh
source "$repo_root/bridge-lib.sh"

# bridge-lib.sh sources every module; trigger roster load so the in-memory
# agent maps declare + populate from the roster-local file above.
bridge_load_roster

if ! bridge_agent_exists "$agent_id"; then
  printf 'build-static-launch-driver: synthesized agent %s missing after bridge_load_roster\n' "$agent_id" >&2
  exit 2
fi

rendered="$(bridge_build_static_claude_launch_cmd "$agent_id")"
printf 'LAUNCH_CMD=%s\n' "$rendered"
