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

# Issue #544 PR2 — install bridge-managed Claude hook entries into the
# isolated UID's HOME `.claude/settings.json` (as a controller-owned
# symlink to a controller-owned `settings.effective.json` rendered next
# to it). No-op for non-isolated agents and on non-Linux hosts. Best-
# effort throughout: failures here must not block agent start, since
# the workdir-side shared settings (the path used by non-isolated
# agents) is independent and already wired by the caller.
#
# Why per-home rendered, not cross-UID symlink to controller:
# `<isolated-home>/.claude/settings.json` lives under the isolated UID
# and Claude Code rewrites it on first-run trust + on operator
# `claude config` actions. A symlink across UIDs would let those
# rewrites silently mutate the controller's hook contract. Rendering a
# fresh controller-owned file per isolated home keeps the integrity
# boundary intact while still letting the isolated UID read the file
# (mode 0644) and run the hook commands themselves under its own UID.
#
# Implementation: render to a controller-owned temp directory (the
# isolated home's `.claude/` is mode 0700 under the isolated UID, so
# the controller cannot write there directly), then sudo-install both
# files into the isolated tree under root ownership. Pre-existing user
# keys are preserved by the Python renderer reading the existing
# `<isolated-home>/.claude/settings.json` via a sudo-backed cat into
# the temp staging area first.
bridge_install_isolated_home_settings() {
  local agent="$1"
  local launch_cmd="${2-}"
  local os_user=""
  local isolated_home=""
  local target_dir=""
  local target_effective=""
  local target_settings=""
  local target_effective_tmp=""
  local target_settings_tmp=""
  local stage_root=""
  local stage_home=""
  local stage_dir=""
  local stage_settings=""
  local stage_effective=""

  [[ -n "$agent" ]] || return 0

  # Predicate is fatal-on-zero for non-isolated agents and non-Linux
  # hosts; suppress so this function remains a silent no-op when the
  # caller (run_rerender_settings, the start path, etc.) invokes it
  # unconditionally for every agent.
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null || return 0

  os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
  [[ -n "$os_user" ]] || return 0
  isolated_home="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || true)"
  [[ -n "$isolated_home" ]] || return 0

  target_dir="$isolated_home/.claude"
  target_effective="$target_dir/settings.effective.json"
  target_settings="$target_dir/settings.json"
  # Same-directory tmp siblings keep the rename atomic on POSIX (rename(2)
  # within one filesystem). Use a stable suffix per process so concurrent
  # rerenders cannot collide on the same staging name (PID is unique
  # within a host at any instant).
  target_effective_tmp="${target_effective}.tmp.$$"
  target_settings_tmp="${target_settings}.tmp.$$"

  # Integrity boundary: keep `.claude/` under controller/root ownership so
  # the isolated UID cannot unlink-or-replace the root-owned settings
  # files inside it. The dir owner (root) keeps full rwx; the isolated
  # UID gets group r-x via group=os_user + mode 0750. The hook commands
  # themselves still execute under the isolated UID — Claude Code reads
  # `<isolated-home>/.claude/settings.json` and exec()s the listed
  # commands; we only need *read* on the dir + the file, not write.
  #
  # Codex r1 needs-more on PR #561: previously this dir was chowned to
  # the isolated UID, so even though the inner files were root-owned,
  # the isolated UID could rm/replace them via the parent's write bit.
  # Switching the parent to root-owned + 0750 closes that gap. The
  # isolated UID can still create files at `<isolated-home>/foo` (its
  # own home), just not under `.claude/`.
  bridge_linux_sudo_root mkdir -p "$target_dir" 2>/dev/null || {
    bridge_warn "isolated home settings install: cannot mkdir $target_dir for $agent (sudo unavailable?)"
    return 0
  }
  bridge_linux_sudo_root chown "root:$os_user" "$target_dir" 2>/dev/null || true
  bridge_linux_sudo_root chmod 0750 "$target_dir" 2>/dev/null || true

  # Stage the render in a controller-owned temp directory. The renderer
  # walks `<stage_home>/.claude/`, which mirrors the layout it expects
  # under the live isolated home but lives entirely under the
  # controller UID so the Python writes succeed without sudo.
  stage_root="$(mktemp -d "${TMPDIR:-/tmp}/bridge-isolated-settings.XXXXXX")" || {
    bridge_warn "isolated home settings install: mktemp failed for $agent"
    return 0
  }
  stage_home="$stage_root/home"
  stage_dir="$stage_home/.claude"
  stage_settings="$stage_dir/settings.json"
  stage_effective="$stage_dir/settings.effective.json"
  mkdir -p "$stage_dir"

  # Seed the stage with the live isolated user state so the renderer's
  # preserve-user-keys branch sees it on every run, including re-runs
  # where `settings.json` is already a symlink to `settings.effective.json`.
  #
  # Codex r1 needs-more on PR #561: the previous code only staged when
  # `settings.json` was a regular file. After the first install made it
  # a symlink, the second run re-rendered with no preserved keys and
  # silently dropped `enabledPlugins`, `extraKnownMarketplaces`, and
  # `skipDangerousModePermissionPrompt`. Now we dereference: when
  # `settings.json` is a symlink, copy the live effective file into the
  # stage as `settings.effective.json` (which is the path the renderer's
  # symlink branch reads from). When it is a regular file, copy it to
  # `settings.json` (the renderer's non-symlink branch). cat-fail is
  # fine: the renderer treats a missing source as "no preserved keys".
  if bridge_linux_sudo_root test -L "$target_settings" 2>/dev/null; then
    # Symlink — touch a symlink under stage so the renderer takes the
    # symlink branch, then seed the stage effective from the live one.
    ln -s "settings.effective.json" "$stage_settings" 2>/dev/null || true
    if bridge_linux_sudo_root test -f "$target_effective" 2>/dev/null; then
      bridge_linux_sudo_root cat "$target_effective" >"$stage_effective" 2>/dev/null || true
    fi
  elif bridge_linux_sudo_root test -f "$target_settings" 2>/dev/null; then
    bridge_linux_sudo_root cat "$target_settings" >"$stage_settings" 2>/dev/null || true
  fi

  if ! bridge_hooks_python render-isolated-home-settings \
        --isolated-home "$stage_home" \
        --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
        --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
        --launch-cmd "$launch_cmd" >"$stage_root/render.out" 2>&1; then
    bridge_warn "isolated home settings install: render failed for $agent ($(head -n1 "$stage_root/render.out" 2>/dev/null || true))"
    rm -rf "$stage_root"
    return 0
  fi

  # Atomic install of the effective file. Stage to a same-directory
  # `.tmp.$$` sibling first, then `mv -f` over the final path. POSIX
  # rename(2) within one filesystem is atomic, so any concurrent reader
  # never observes a partial write or a moment where the file is
  # missing. Mirrors PR #559 PR3 (lib/bridge-skills.sh atomic install).
  #
  # The `install -m 0644 -o root -g root` form chowns at the same time;
  # older `install` builds reject `-o`/`-g` even under sudo, so we fall
  # back to plain install + chown. On either failure path, clear the
  # tmp sibling so the isolated tree never carries a stale `.tmp.$$`.
  if ! bridge_linux_sudo_root install -m 0644 -o root -g root "$stage_effective" "$target_effective_tmp" 2>/dev/null; then
    if bridge_linux_sudo_root install -m 0644 "$stage_effective" "$target_effective_tmp" 2>/dev/null; then
      bridge_linux_sudo_root chown root:root "$target_effective_tmp" 2>/dev/null || true
    else
      bridge_warn "isolated home settings install: install failed for $target_effective"
      bridge_linux_sudo_root rm -f "$target_effective_tmp" 2>/dev/null || true
      rm -rf "$stage_root"
      return 0
    fi
  fi
  if ! bridge_linux_sudo_root mv -f "$target_effective_tmp" "$target_effective" 2>/dev/null; then
    bridge_warn "isolated home settings install: atomic mv failed for $target_effective"
    bridge_linux_sudo_root rm -f "$target_effective_tmp" 2>/dev/null || true
    rm -rf "$stage_root"
    return 0
  fi

  # Atomic swap of the symlink. Create a tmp symlink in the same
  # directory, then `mv -f` over `settings.json`. Unlike `ln -sfn`
  # (which momentarily uses unlink+symlink), the rename-over path keeps
  # `settings.json` continuously resolvable for any concurrent reader.
  # If the prior `settings.json` was a regular file, the rename
  # replaces it in one step too — no separate `rm` required.
  bridge_linux_sudo_root ln -s "settings.effective.json" "$target_settings_tmp" 2>/dev/null || {
    bridge_warn "isolated home settings install: symlink staging failed for $target_settings"
    bridge_linux_sudo_root rm -f "$target_settings_tmp" 2>/dev/null || true
    rm -rf "$stage_root"
    return 0
  }
  if ! bridge_linux_sudo_root mv -f "$target_settings_tmp" "$target_settings" 2>/dev/null; then
    bridge_warn "isolated home settings install: atomic symlink swap failed for $target_settings"
    bridge_linux_sudo_root rm -f "$target_settings_tmp" 2>/dev/null || true
    rm -rf "$stage_root"
    return 0
  fi
  bridge_linux_sudo_root chown -h "$os_user:$os_user" "$target_settings" 2>/dev/null || true

  rm -rf "$stage_root"
}

bridge_codex_hooks_status() {
  bridge_hooks_python status-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)"
}

bridge_ensure_codex_hooks() {
  bridge_hooks_python ensure-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
}
