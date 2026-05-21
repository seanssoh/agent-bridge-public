#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/agent-env-no-stale-bridge-layout.sh — regression for
# issue #1014 sub-bug B (2026-05-22).
#
# `bridge_write_linux_agent_env_file` (lib/bridge-agents.sh) wrote
# `BRIDGE_LAYOUT=${BRIDGE_LAYOUT:-legacy}` into the per-agent launch
# envelope (`runtime/agent-env.sh`). When the ambient BRIDGE_LAYOUT was
# unset or a stale `legacy` value, the writer baked `legacy` into the
# env file. On a v2-migrated install the marker at
# state/layout-marker.sh is authoritative — but the baked value made the
# stale layout SELF-PERPETUATE through the daemon -> agent-env -> CLI
# process tree, so every agent restart re-injected it and the layout
# resolver's "stale pre-v0.8.0 env override" warning never cleared.
#
# Fix: when a valid v2 layout marker exists the writer normalizes
# BRIDGE_LAYOUT to the marker value (`v2`) instead of baking a stale
# `legacy`. With no valid marker it only propagates a BRIDGE_LAYOUT the
# caller actually set — it never invents a `legacy` default.
#
# This test pins:
#   T1. With a valid v2 marker AND BRIDGE_LAYOUT=legacy in the ambient
#       env, the generated agent-env.sh carries BRIDGE_LAYOUT=v2 — never
#       `legacy`.
#   T2. With a valid v2 marker AND a stale BRIDGE_LAYOUT=v1, the
#       generated file is likewise normalized to v2 — never `v1`/`legacy`
#       (the bug's self-perpetuation seed for any stale pre-v2 value).

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays (macOS ships 3.2).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:agent-env-no-stale-bridge-layout] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="agent-env-no-stale-bridge-layout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

REPO_ROOT="$SMOKE_REPO_ROOT"

# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

if ! declare -F bridge_write_linux_agent_env_file >/dev/null; then
  smoke_fail "bridge_write_linux_agent_env_file not defined (sanity check)"
fi
if ! declare -F bridge_agent_linux_env_file >/dev/null; then
  smoke_fail "bridge_agent_linux_env_file not defined (sanity check)"
fi
if ! declare -F bridge_isolation_v2_marker_validate >/dev/null; then
  smoke_fail "bridge_isolation_v2_marker_validate not defined (sanity check)"
fi

bridge_reset_roster_maps

# Confirm smoke_setup_bridge_home seeded a valid v2 marker — the test
# only has meaning on the marker-present branch of the fix.
marker_path="$(bridge_isolation_v2_marker_path)"
if [[ ! -f "$marker_path" ]] || ! bridge_isolation_v2_marker_validate "$marker_path" >/dev/null 2>&1; then
  smoke_fail "expected a valid v2 layout marker at $marker_path"
fi

# Seed a minimal in-memory agent record (mirrors 989-isolated-agent-env-
# state-dir.sh). The writer reads ~25 BRIDGE_AGENT_* maps.
seed_agent() {
  local agent="$1"
  BRIDGE_AGENT_IDS=("$agent")
  BRIDGE_AGENT_DESC["$agent"]="$agent smoke fixture"
  BRIDGE_AGENT_ENGINE["$agent"]="claude"
  BRIDGE_AGENT_SESSION["$agent"]="$agent"
  BRIDGE_AGENT_WORKDIR["$agent"]=""
  BRIDGE_AGENT_PROFILE_HOME["$agent"]=""
  BRIDGE_AGENT_LAUNCH_CMD["$agent"]="claude --dangerously-skip-permissions"
  BRIDGE_AGENT_SOURCE["$agent"]="static"
  BRIDGE_AGENT_LOOP["$agent"]="1"
  BRIDGE_AGENT_CONTINUE["$agent"]="1"
  BRIDGE_AGENT_SESSION_ID["$agent"]=""
  BRIDGE_AGENT_HISTORY_KEY["$agent"]=""
  BRIDGE_AGENT_CREATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_UPDATED_AT["$agent"]="$(date +%s)"
  BRIDGE_AGENT_IDLE_TIMEOUT["$agent"]="600"
  BRIDGE_AGENT_NOTIFY_KIND["$agent"]=""
  BRIDGE_AGENT_NOTIFY_TARGET["$agent"]=""
  BRIDGE_AGENT_NOTIFY_ACCOUNT["$agent"]=""
  BRIDGE_AGENT_DISCORD_CHANNEL_ID["$agent"]=""
  BRIDGE_AGENT_CHANNELS["$agent"]=""
  BRIDGE_AGENT_ISOLATION_MODE["$agent"]="linux-user"
  BRIDGE_AGENT_OS_USER["$agent"]="agent-bridge-$agent"
}

# Run the writer in a sub-shell so neither an ambient BRIDGE_LAYOUT
# export nor the platform stub below leaks across cases. Echoes the
# BRIDGE_LAYOUT assignment line from the produced agent-env.sh (empty
# string if the writer omitted it).
generate_and_extract_layout() {
  local agent="$1"
  local layout_env="$2"   # stale value to export as BRIDGE_LAYOUT
  (
    seed_agent "$agent"
    export BRIDGE_LAYOUT="$layout_env"
    # Host-portability: bridge_write_linux_agent_env_file has a
    # Linux-only `chgrp ab-agent-<name>` / `chmod 0640` branch
    # (lib/bridge-agents.sh) gated on `bridge_host_platform == Linux`.
    # That per-agent group does not exist in this in-memory smoke
    # fixture, so on the Linux CI runner the chgrp fails and the
    # writer bridge_die()s. Stub bridge_host_platform to a non-Linux
    # value so the chgrp/chmod branch is skipped on every host —
    # mirrors the predicate-stub convention in
    # scripts/smoke/989-isolated-agent-env-state-dir.sh and
    # scripts/smoke/857-pr1-isolation-write-helper.sh. This is
    # host-independent: the chgrp/chmod branch is the ONLY code in
    # bridge_write_linux_agent_env_file gated on bridge_host_platform
    # == Linux, and B-B's BRIDGE_LAYOUT=v2 assertion depends only on
    # the marker resolver (bridge_isolation_v2_marker_*), which does
    # not consult bridge_host_platform — so the stub cannot weaken
    # what this smoke verifies.
    # shellcheck disable=SC2329  # invoked indirectly by the real writer
    bridge_host_platform() { printf 'Darwin\n'; }
    env_file="$(bridge_agent_linux_env_file "$agent")"
    mkdir -p "$(dirname "$env_file")"
    bridge_write_linux_agent_env_file "$agent" "$env_file" >/dev/null
    grep -E '^BRIDGE_LAYOUT=' "$env_file" | head -n 1 || true
  )
}

failed=0

# --- T1: stale BRIDGE_LAYOUT=legacy in env -> file carries v2 ----------
t1_line="$(generate_and_extract_layout "iso-1014-t1" "legacy")"
if [[ "$t1_line" == *legacy* ]]; then
  echo "  FAIL  T1 agent-env.sh baked stale BRIDGE_LAYOUT=legacy" >&2
  echo "        line: ${t1_line}" >&2
  failed=1
elif [[ "$t1_line" == *v2* ]]; then
  echo "  PASS  T1 stale BRIDGE_LAYOUT=legacy normalized to marker value v2"
else
  echo "  FAIL  T1 expected BRIDGE_LAYOUT=v2 in agent-env.sh, got: ${t1_line}" >&2
  failed=1
fi

# --- T2: stale BRIDGE_LAYOUT=v1 -> file normalized to v2, never v1 ----
t2_line="$(generate_and_extract_layout "iso-1014-t2" "v1")"
if [[ "$t2_line" == *v1* || "$t2_line" == *legacy* ]]; then
  echo "  FAIL  T2 agent-env.sh propagated a stale pre-v2 BRIDGE_LAYOUT" >&2
  echo "        line: ${t2_line}" >&2
  failed=1
elif [[ "$t2_line" == *v2* ]]; then
  echo "  PASS  T2 stale BRIDGE_LAYOUT=v1 normalized to marker value v2"
else
  echo "  FAIL  T2 expected BRIDGE_LAYOUT=v2 in agent-env.sh, got: ${t2_line}" >&2
  failed=1
fi

if (( failed )); then
  smoke_fail "one or more #1014-B checks failed"
fi
smoke_log "passed"
