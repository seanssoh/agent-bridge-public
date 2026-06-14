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

    created_at="$(bridge_agent_created_at "$agent" 0)"
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
    # Issue #848 (codex r2 Vector 2): bridge_archive_dynamic_agent has just
    # written the agent's history env to disk via
    # bridge_write_agent_state_file (lib/bridge-state.sh:2755-2761). That
    # write alone is sufficient to make the in-process roster cache stale,
    # so flag the agent for invalidation BEFORE the cleanup half runs.
    # Without this early flag, an archive-succeeds-but-remove-fails path
    # falls through the bridge_remove_dynamic_agent_file `continue` below
    # with the on-disk roster already mutated and the cache flag never set
    # — bridge_render_active_roster downstream then mis-reports the
    # pruned-and-archived agent as active.
    # Rule: track mutation immediately after each successful writer call,
    # not only after full prune success.
    PRUNED_DYNAMIC["$agent"]=1
    if ! bridge_remove_dynamic_agent_file "$agent" 2>/dev/null; then
      bridge_warn "bridge-sync: remove_dynamic_agent_file failed for agent='$agent' — skipping; next sweep will retry"
      continue
    fi
    bridge_agent_clear_idle_marker "$agent" 2>/dev/null || true
  done < <(bridge_dynamic_agent_ids)

  # Issue #848 (codex r1 Vector 2): bridge_archive_dynamic_agent and
  # bridge_remove_dynamic_agent_file above mutate the roster files on
  # disk (history env + dynamic .env removal). The Issue #848 per-process
  # roster memoization in lib/bridge-state.sh means the next
  # bridge_load_roster call no-ops unless we drop the cache flag here.
  # Without this invalidate, pruned agents linger in BRIDGE_AGENT_IDS /
  # BRIDGE_AGENT_* maps for the rest of the sync pass and the downstream
  # bridge_render_active_roster reports them as active.
  if [[ ${#PRUNED_DYNAMIC[@]} -gt 0 ]]; then
    bridge_roster_cache_invalidate
  fi
}

refresh_missing_session_ids() {
  local agent sid exclude_csv created_at detected key _resolved _rc
  local _claude_config_dir
  # Issue #1299 (v0.15.0-beta5 Lane β): per-agent iso v2 os_user resolved
  # per iteration so the detect helper can read 0600-jsonl via sudo-as-user.
  local _iso_sudo_user=""
  local -a excluded
  local persisted_any=0

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -z "$agent" ]] && continue
    [[ -n "${PRUNED_DYNAMIC[$agent]+x}" ]] && continue
    if ! bridge_agent_is_active "$agent"; then
      continue
    fi

    # #1890: a dynamic vanilla Claude agent never carries a bridge-managed
    # session id — it resumes via native `claude -c` against the operator-
    # global ~/.claude. This daemon backfill sweep calls the detector
    # directly (bypassing bridge_refresh_agent_session_id's guard), and the
    # config-dir resolver returns empty for this class, so without this gate
    # the detector falls back to $HOME/.claude and would persist the
    # OPERATOR's live session id. Skip detection + persistence entirely.
    if command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 \
       && bridge_agent_is_dynamic_vanilla_claude "$agent"; then
      continue
    fi
    # #1899: same for dynamic vanilla Codex — this sweep calls the codex detector
    # directly (scanning the operator-global ~/.codex/sessions), bypassing
    # bridge_refresh_agent_session_id's guard. Without this gate it would persist
    # the OPERATOR's live Codex session id. Skip detection + persistence entirely.
    if command -v bridge_agent_is_dynamic_vanilla_codex >/dev/null 2>&1 \
       && bridge_agent_is_dynamic_vanilla_codex "$agent"; then
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
    created_at="$(bridge_agent_created_at "$agent" 0)"
    if [[ -z "$created_at" ]]; then
      created_at="0"
    fi

    # Issue #1015: pass the agent's CLAUDE_CONFIG_DIR so isolation-v2
    # agents are detected against their own `<agent-home>/.claude/`. The
    # resolver returns empty for unregistered / non-isolated agents so the
    # helper keeps its daemon-HOME fallback.
    _claude_config_dir="$(bridge_resolve_agent_claude_config_dir "$agent" 2>/dev/null || true)"
    # Issue #1299 (v0.15.0-beta5 Lane β): pass the agent's iso v2 os_user
    # so the detect helper can read `0600 <iso-uid>:ab-agent-<a>` jsonl
    # files via sudo-as-user. Empty for non-isolated/unregistered agents
    # (direct-as-controller invocation is the back-compat path).
    _iso_sudo_user="$(bridge_resolve_agent_iso_sudo_user "$agent" 2>/dev/null || true)"
    detected="$(bridge_detect_session_id \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$created_at" \
      "$exclude_csv" \
      "$_claude_config_dir" \
      "$_iso_sudo_user")"

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
    persisted_any=1
  done

  # Issue #848 (codex r1 Vector 2): bridge_persist_agent_state writes the
  # AGENT_SESSION_ID / AGENT_UPDATED_AT fields to the history env (and
  # the dynamic .env for dynamic agents). With the Issue #848 per-process
  # roster memoization in place, the caller's next bridge_load_roster
  # would otherwise no-op and leave BRIDGE_AGENT_SESSION_ID stale for the
  # downstream bridge_reconcile_idle_markers / bridge_render_active_roster
  # pass.
  if [[ "$persisted_any" -eq 1 ]]; then
    bridge_roster_cache_invalidate
  fi
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
  # Issue #848 (codex r1 Vector 6): defensive invalidate immediately
  # before the active-roster render. The prune/refresh helpers above
  # invalidate after their own mutations, so the bridge_load_roster
  # right above this comment already reloaded fresh maps in the normal
  # path. The defensive invalidate here guarantees that ANY future
  # mutation slipped into bridge_reconcile_idle_markers (or a helper it
  # transitively calls) cannot strand bridge_render_active_roster on
  # stale BRIDGE_AGENT_* maps, which would mis-report pruned dynamic
  # agents as still-active in the rendered TSV/MD snapshot.
  bridge_roster_cache_invalidate
  bridge_load_roster
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
