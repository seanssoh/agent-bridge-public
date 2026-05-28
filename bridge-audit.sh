#!/usr/bin/env bash
# bridge-audit.sh — query Agent Bridge audit logs

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

mode="list"
if [[ $# -gt 0 ]]; then
  case "$1" in
    list|follow|verify)
      mode="$1"
      shift
      ;;
  esac
fi

agent=""
args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agent)
      [[ $# -lt 2 ]] && bridge_die "--agent 뒤에 agent를 지정하세요."
      agent="$2"
      args+=("$1" "$2")
      shift 2
      ;;
    *)
      args+=("$1")
      shift
      ;;
  esac
done

files=("$BRIDGE_AUDIT_LOG")
if [[ -n "$agent" ]]; then
  files+=("$(bridge_agent_audit_log_file "$agent")")
else
  # Issue #1324 (Lane κ v0.15.0-beta5-2): when iso v2 layout is active,
  # per-agent audit logs land under the data-rooted tree
  # `$BRIDGE_HOME/data/agents/<a>/logs/audit.jsonl` (the canonical
  # `bridge_agent_log_dir` resolution at v2). The previous loop only
  # globbed the legacy controller-rooted path
  # `$BRIDGE_HOME/logs/agents/<a>/audit.jsonl`, so `agb audit list`
  # without `--agent` silently MISSED every per-agent audit on iso v2
  # installs — the dashboard-level audit emit kept working (root-level
  # `$BRIDGE_AUDIT_LOG`), but per-agent rows hooked via the agent's
  # `BRIDGE_AUDIT_LOG` env (set by the scoped agent-env writer in
  # lib/bridge-agents.sh:3555 to the v2 canonical path) never surfaced.
  # Fix: walk BOTH the legacy controller-rooted tree AND the v2 data-
  # rooted tree. Each find is `2>/dev/null` so a missing directory
  # (typical on the fresh side of an install pre-v2-migrate) is silent.
  while IFS= read -r candidate; do
    [[ -n "$candidate" ]] || continue
    files+=("$candidate")
  done < <(
    {
      find "$BRIDGE_HOME/logs/agents" -type f -name audit.jsonl 2>/dev/null
      # v2 canonical tree — only walk when BRIDGE_AGENT_ROOT_V2 is set
      # (v2 layout active) or the directory exists (defensive — handles
      # mid-migration installs where the env was loaded with v2 disabled
      # but the data tree was already populated).
      if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" && -d "$BRIDGE_AGENT_ROOT_V2" ]]; then
        find "$BRIDGE_AGENT_ROOT_V2" -mindepth 3 -maxdepth 3 -type f -name audit.jsonl 2>/dev/null
      elif [[ -d "$BRIDGE_HOME/data/agents" ]]; then
        find "$BRIDGE_HOME/data/agents" -mindepth 3 -maxdepth 3 -type f -name audit.jsonl 2>/dev/null
      fi
    } | LC_ALL=C sort -u
  )
fi

cmd=(python3 "$SCRIPT_DIR/bridge-audit.py" "$mode")
for file in "${files[@]}"; do
  cmd+=(--file "$file")
done
cmd+=("${args[@]}")
exec "${cmd[@]}"
