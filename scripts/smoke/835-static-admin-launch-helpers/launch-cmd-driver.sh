#!/usr/bin/env bash
# scripts/smoke/835-static-admin-launch-helpers/launch-cmd-driver.sh
#
# Issue #835 Wave C — driver for case 1 of the regression smoke. Loads
# the production bridge-lib.sh against a synthesized roster (see
# static-admin-roster.sh in this directory) and invokes the real
# `bridge_agent_launch_cmd` for the synthesized static claude admin.
#
# On Homebrew Bash 5.3.9, the pre-Wave-A implementation of this function
# wedged inside `heredoc_write` during the embedded Python heredoc body
# read when sourced via an absolute path (the static admin path). Wave A
# (PR #845) extracted the heredoc bodies to standalone .py files; Wave A'
# (PR #846) extracted the upstream `bridge_extract_development_channels_from_command`
# heredoc body for the same reason. This driver invokes the post-fix
# call chain end-to-end and prints the rendered launch command + wall
# clock time on stdout, separated by a sentinel so the parent smoke can
# parse them deterministically.
#
# Shipped as a tracked file (rather than a heredoc-to-file body inside
# the smoke wrapper) to match the convention established by
# scripts/smoke/heredoc-regression-helpers/ and to keep the smoke's own
# bytes off the Bash 5.3.9 heredoc-write class. (Forbidden pattern
# strings intentionally omitted from this comment so the footgun #11
# self-audit grep recipe does not flag a textual mention as a real
# callsite.)
#
# Invocation:
#   bash scripts/smoke/835-static-admin-launch-helpers/launch-cmd-driver.sh \
#     <repo_root> <bridge_home> <roster_template> <agent_id>
#
# Output (on success, stdout):
#   LAUNCH_CMD=<rendered>
#   ELAPSED_SECONDS=<float>
#
# Exits non-zero on internal failure; the parent smoke asserts both the
# exit code and the ELAPSED_SECONDS upper bound.

set -euo pipefail

repo_root="$1"
bridge_home="$2"
roster_template="$3"
agent_id="$4"

# Re-export the hermetic BRIDGE_HOME so bridge-lib.sh sees the temp tree
# (the parent smoke set it via smoke_setup_bridge_home, but it lives in
# its own shell — we're a fresh subprocess).
export BRIDGE_HOME="$bridge_home"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_AGENT_ENV_FILE=""   # force the file-based roster path, not the
                                  # isolated agent env path (lib/bridge-state.sh
                                  # bridge_load_roster gates on this var).

# Compose the roster from the tracked template. The template references
# BRIDGE_AGENT_HOME_ROOT so we can drop it into the live roster path
# unchanged. The roster file itself MUST be a single redirection (one
# `cp`) — no heredoc-to-file body, per Wave C's footgun #11 self-audit.
cp "$roster_template" "$BRIDGE_ROSTER_LOCAL_FILE"

# Source the production library exactly the way bridge-start.sh does.
# This re-traces the absolute-path source chain that triggered the
# 2026-05-14 wedge.
# shellcheck source=../../../bridge-lib.sh
source "$repo_root/bridge-lib.sh"

# bridge-lib.sh sources every module; trigger roster load so the
# in-memory agent maps populate.
bridge_load_roster

if ! bridge_agent_exists "$agent_id"; then
  printf 'launch-cmd-driver: synthesized agent %s missing after bridge_load_roster\n' "$agent_id" >&2
  exit 2
fi

# Time the call. SECONDS is monotonic-ish but integer-resolution; for
# a <2s assertion we want sub-second precision so we use date +%s.%N
# where available. macOS BSD `date` lacks %N — fall back to python3.
start_ns=""
end_ns=""
if start_ns="$(date +%s%N 2>/dev/null)" && [[ "$start_ns" =~ ^[0-9]+$ && "$start_ns" != *N* ]]; then
  launch_cmd="$(bridge_agent_launch_cmd "$agent_id")"
  end_ns="$(date +%s%N)"
  elapsed_seconds="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{ printf "%.6f", (e-s)/1000000000 }')"
else
  # BSD date — use python3 for monotonic-ish wall-clock precision.
  start_ns="$(python3 -c 'import time; print(time.time_ns())')"
  launch_cmd="$(bridge_agent_launch_cmd "$agent_id")"
  end_ns="$(python3 -c 'import time; print(time.time_ns())')"
  elapsed_seconds="$(awk -v s="$start_ns" -v e="$end_ns" 'BEGIN{ printf "%.6f", (e-s)/1000000000 }')"
fi

printf 'LAUNCH_CMD=%s\n' "$launch_cmd"
printf 'ELAPSED_SECONDS=%s\n' "$elapsed_seconds"
