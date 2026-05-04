#!/usr/bin/env bash
# shellcheck shell=bash

bridge_hooks_python() {
  bridge_require_python
  python3 "$BRIDGE_SCRIPT_DIR/bridge-hooks.py" "$@"
}

bridge_hook_mark_idle_path() {
  printf '%s/mark-idle.sh' "$BRIDGE_HOOKS_DIR"
}

bridge_hook_clear_idle_path() {
  printf '%s/clear-idle.sh' "$BRIDGE_HOOKS_DIR"
}

bridge_codex_hooks_file() {
  if [[ -n "${BRIDGE_CODEX_HOOKS_FILE:-}" ]]; then
    printf '%s' "$BRIDGE_CODEX_HOOKS_FILE"
    return 0
  fi
  printf '%s/.codex/hooks.json' "$HOME"
}

bridge_hook_settings_file_for() {
  local workdir="$1"
  printf '%s/.claude/settings.json' "$workdir"
}

bridge_hook_shared_settings_base_file() {
  printf '%s/.claude/settings.json' "$BRIDGE_AGENT_HOME_ROOT"
}

bridge_hook_shared_settings_overlay_file() {
  printf '%s/.claude/settings.local.json' "$BRIDGE_AGENT_HOME_ROOT"
}

bridge_hook_shared_settings_effective_file() {
  printf '%s/.claude/settings.effective.json' "$BRIDGE_AGENT_HOME_ROOT"
}

bridge_hook_paths_equal() {
  local left="$1"
  local right="$2"

  bridge_require_python
  python3 - "$left" "$right" <<'PY'
import os
import sys

left = os.path.realpath(sys.argv[1])
right = os.path.realpath(sys.argv[2])
print("1" if left == right else "0")
PY
}

bridge_claude_settings_mode() {
  local workdir="$1"
  local agent=""
  local agent_workdir=""

  # Issue #516 r2 (codex needs-more on PR #518): the
  # "inside BRIDGE_AGENT_HOME_ROOT means shared" fast-path is NOT
  # static-by-construction. Dynamic spawn defaults to the current
  # directory and accepts arbitrary --workdir, then records
  # source=dynamic with that workdir. If an operator passes
  # --workdir into the home root, the dynamic agent would inherit
  # the static autoCompactWindow=400000 default — exactly what the
  # original Issue #516 fix tried to prevent.
  #
  # Short-circuit registered dynamic claude agents to `local` BEFORE
  # the HOME_ROOT branch. Static agents under HOME_ROOT keep the
  # existing fast path; static agents whose workdir is registered
  # outside HOME_ROOT keep their existing handling in the second
  # loop below.
  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent" 2>/dev/null || true)" == "claude" ]] || continue
      [[ "$(bridge_agent_source "$agent" 2>/dev/null || true)" == "dynamic" ]] || continue
      agent_workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
      [[ -n "$agent_workdir" ]] || continue
      if [[ "$(bridge_hook_paths_equal "$workdir" "$agent_workdir")" == "1" ]]; then
        printf 'local'
        return 0
      fi
    done
  fi

  if [[ "$(bridge_path_is_within_root "$workdir" "$BRIDGE_AGENT_HOME_ROOT")" == "1" ]]; then
    printf 'shared'
    return 0
  fi

  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent" 2>/dev/null || true)" == "claude" ]] || continue
      # Issue #516: only static claude agents inherit the shared
      # `autoCompactWindow=400000` defaults. Dynamic agents register their
      # workdir in BRIDGE_AGENT_IDS too (see bridge_register_dynamic_agent
      # in agent-bridge), so without a source gate the second branch matched
      # any registered workdir and inflated dynamic-agent context budget
      # against operator intent.
      [[ "$(bridge_agent_source "$agent" 2>/dev/null || true)" == "static" ]] || continue
      agent_workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
      [[ -n "$agent_workdir" ]] || continue
      if [[ "$(bridge_hook_paths_equal "$workdir" "$agent_workdir")" == "1" ]]; then
        printf 'shared'
        return 0
      fi
    done
  fi

  printf 'local'
}

bridge_ensure_claude_shared_settings_for_managed_workdir() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    return 0
  fi
}

bridge_link_claude_settings_to_shared() {
  local workdir="$1"
  # Issue #547: launch_cmd substring '[1m]' raises the managed
  # autoCompactWindow default from 400_000 to 1_000_000. The shared
  # settings file is install-wide; on a mixed-model install the last
  # rerender for an agent decides the value. The dominant case is
  # all-Opus-4.7-[1m] (or all-pre-1M), where every rerender agrees.
  local launch_cmd="${2-}"
  bridge_hooks_python render-shared-settings \
    --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
    --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
    --effective-settings-file "$(bridge_hook_shared_settings_effective_file)" \
    --launch-cmd "$launch_cmd" >/dev/null
  bridge_hooks_python link-shared-settings --workdir "$workdir" --shared-settings-file "$(bridge_hook_shared_settings_effective_file)"
}

bridge_ensure_claude_project_trust() {
  local workdir="$1"
  bridge_hooks_python ensure-project-trust --workdir "$workdir"
}

bridge_claude_stop_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-stop-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  else
    bridge_hooks_python status-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_claude_session_start_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    bridge_hooks_python status-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_claude_prompt_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  else
    bridge_hooks_python status-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_claude_prompt_guard_hook_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-prompt-guard-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    bridge_hooks_python status-prompt-guard-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_claude_tool_policy_hooks_status() {
  local workdir="$1"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-tool-policy-hooks --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    bridge_hooks_python status-tool-policy-hooks --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_stop_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-stop-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    bridge_hooks_python ensure-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_ensure_claude_session_start_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    bridge_hooks_python ensure-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_prompt_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    bridge_hooks_python ensure-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_prompt_guard_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-guard-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    bridge_hooks_python ensure-prompt-guard-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_tool_policy_hooks() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-tool-policy-hooks --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    bridge_hooks_python ensure-tool-policy-hooks --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

# Same shape as the five helpers above, but for the PreCompact event.
# Issue #509 / PR #510 added the snapshot-on-pre-compact path; without
# this entry on the upgrade-propagation loop, existing hosts that
# `agent-bridge upgrade --apply` (and never re-create or restart their
# claude agents) would ship the new hooks/pre-compact.py code without ever
# wiring it into per-agent settings.json. Restored Context still works
# (session_start reads canonical files live), but the pre-compact sidecar
# snapshot — the disaster-recovery fallback — never gets written.
bridge_ensure_claude_pre_compact_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-pre-compact-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd"
  else
    bridge_hooks_python ensure-pre-compact-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_codex_hooks_status() {
  bridge_hooks_python status-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)"
}

bridge_ensure_codex_hooks() {
  bridge_hooks_python ensure-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
}
