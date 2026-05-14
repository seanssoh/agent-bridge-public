#!/usr/bin/env bash
# bridge-sync.sh — dynamic agent registry and active roster synchronization

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"

declare -A CLAIMED_SESSION_IDS=()
declare -A PRUNED_DYNAMIC=()

# Issue #826: dynamic agents can be pruned during a slow first start before
# tmux exists. The grace window between AGENT_CREATED_AT and the first
# prune-eligible sweep is now operator-configurable via
# BRIDGE_DYNAMIC_START_GRACE_SECONDS (integer seconds; default 300s = 5 min).
# 300s is the operator's live-recovery hotfix value from 2026-05-14 — it
# absorbs normal Claude / Codex bootstrap + plugin / hook init for slow
# first-start cases (`agb --claude --name <name>` against a cold repo).
# Malformed input falls back to the default so a typo cannot break the
# daemon's sync cycle.
resolve_dynamic_start_grace_seconds() {
  local raw="${BRIDGE_DYNAMIC_START_GRACE_SECONDS-}"
  if [[ "$raw" =~ ^[0-9]+$ ]]; then
    printf '%s\n' "$raw"
  else
    printf '%s\n' "300"
  fi
}

record_claimed_ids() {
  local agent sid

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -z "$agent" ]] && continue
    sid="$(bridge_agent_session_id "$agent")"
    if [[ -n "$sid" ]]; then
      CLAIMED_SESSION_IDS["$sid"]="$agent"
    fi
  done
}

prune_missing_dynamic_agents() {
  local agent sid created_at now_epoch age grace

  grace="$(resolve_dynamic_start_grace_seconds)"

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    if bridge_agent_is_active "$agent"; then
      continue
    fi

    created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-0}"
    now_epoch="$(date +%s)"
    if [[ "$created_at" =~ ^[0-9]+$ ]]; then
      age=$((now_epoch - created_at))
      if (( age >= 0 && age < grace )); then
        continue
      fi
    fi

    sid="$(bridge_agent_session_id "$agent")"
    if [[ -n "$sid" ]]; then
      unset "CLAIMED_SESSION_IDS[$sid]"
    fi

    if ! bridge_archive_dynamic_agent "$agent" 2>/dev/null; then
      bridge_warn "bridge-sync: archive_dynamic_agent failed for agent='$agent' — skipping; next sweep will retry"
      continue
    fi
    if ! bridge_remove_dynamic_agent_file "$agent" 2>/dev/null; then
      bridge_warn "bridge-sync: remove_dynamic_agent_file failed for agent='$agent' — skipping; next sweep will retry"
      continue
    fi
    bridge_agent_clear_idle_marker "$agent" 2>/dev/null || true
    PRUNED_DYNAMIC["$agent"]=1
  done < <(bridge_dynamic_agent_ids)
}

refresh_missing_session_ids() {
  local agent sid exclude_csv created_at detected key _resolved _rc
  local -a excluded

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -z "$agent" ]] && continue
    [[ -n "${PRUNED_DYNAMIC[$agent]+x}" ]] && continue
    if ! bridge_agent_is_active "$agent"; then
      continue
    fi

    sid="$(bridge_agent_session_id "$agent")"
    if [[ -n "$sid" ]]; then
      continue
    fi

    excluded=()
    for key in "${!CLAIMED_SESSION_IDS[@]}"; do
      excluded+=("$key")
    done
    exclude_csv="$(IFS=,; echo "${excluded[*]}")"
    created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-0}"
    if [[ -z "$created_at" ]]; then
      created_at="0"
    fi

    detected="$(bridge_detect_session_id \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$created_at" \
      "$exclude_csv")"

    if [[ -z "$detected" ]]; then
      continue
    fi

    # Round-trip the detected id through the freshness resolver so a stale
    # transcript that bridge_detect_session_id would otherwise re-register
    # (since_epoch can be 0 for never-created agents) is filtered out.
    _resolved=""; _rc=0
    _resolved="$(bridge_resolve_resume_session_id \
      "$(bridge_agent_engine "$agent")" "$agent" \
      "$(bridge_agent_workdir "$agent")" "$detected" 2>/dev/null)" || _rc=$?
    if [[ "$_rc" == 1 || -z "$_resolved" ]]; then
      continue
    fi
    detected="$_resolved"

    # shellcheck disable=SC2034
    BRIDGE_AGENT_SESSION_ID["$agent"]="$detected"
    CLAIMED_SESSION_IDS["$detected"]="$agent"
    if ! bridge_persist_agent_state "$agent" 2>/dev/null; then
      bridge_warn "bridge-sync: persist_agent_state failed for agent='$agent' — skipping; next sweep will retry"
      continue
    fi
  done
}

bridge_sync_main() {
  bridge_load_roster
  record_claimed_ids
  prune_missing_dynamic_agents
  bridge_load_roster
  record_claimed_ids
  refresh_missing_session_ids
  bridge_load_roster
  bridge_reconcile_idle_markers
  bridge_render_active_roster
}

# Run the sync pass when this file is executed directly. When sourced
# (e.g. by `scripts/smoke/dynamic-start-grace.sh`), the smoke can call
# `prune_missing_dynamic_agents` against a stubbed dependency surface
# without driving the full roster-load / reconcile / render pipeline —
# necessary because some of those downstream helpers run python3 via
# heredoc-stdin (`python3 - <<'PY'`), a known Bash 5.3.9 deadlock class
# (#815 / Footgun #11) that is independent of #826's grace fix.
if [[ "${BASH_SOURCE[0]}" == "${0}" ]]; then
  bridge_sync_main
fi
