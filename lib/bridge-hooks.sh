#!/usr/bin/env bash
# shellcheck shell=bash

bridge_hooks_python() {
  bridge_require_python
  # #946 L1 (r2): stale-source guard. Hooks helper is reached from many
  # `$(...)` substitutions (status probes, settings render).
  if ! bridge_resolve_script_dir_check; then
    return 1
  fi
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

# Issue #555: per-agent rendering target for managed (non-isolated) agents.
# `bridge_link_claude_settings_to_shared` writes to this path when the caller
# passes the agent id, eliminating the "last rerender wins" mixed-model
# behavior on per-agent managed defaults like `autoCompactWindow`. The base
# (.claude/settings.json) and overlay (.claude/settings.local.json) under
# $BRIDGE_AGENT_HOME_ROOT remain install-wide; only the *effective* output
# is per-agent and lives inside that agent's managed workdir
# ($BRIDGE_AGENT_HOME_ROOT/<agent>/.claude/), next to the symlinked
# settings.json. After migration, the install-wide
# `$BRIDGE_AGENT_HOME_ROOT/.claude/settings.effective.json` becomes orphaned
# but harmless — operators may delete it manually after verifying.
bridge_hook_per_agent_settings_effective_file() {
  local agent="$1"
  printf '%s/%s/.claude/settings.effective.json' "$BRIDGE_AGENT_HOME_ROOT" "$agent"
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
  # the static managed autoCompactWindow default (1_000_000 as of
  # issue #570) — exactly what the original Issue #516 fix tried to
  # prevent.
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
      # Issue #516: only static claude agents inherit the shared managed
      # `autoCompactWindow` default (1_000_000 as of issue #570). Dynamic
      # agents register their workdir in BRIDGE_AGENT_IDS too (see
      # bridge_register_dynamic_agent in agent-bridge), so without a source
      # gate the second branch matched any registered workdir and inflated
      # dynamic-agent context budget against operator intent.
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
  # Issue #555: optional 3rd arg switches to per-agent rendering. Forward
  # it through so callers that already know the agent id (start path,
  # rerender loop, upgrade propagate, admin-pair init) get independent
  # `settings.effective.json` files; callers that don't (back-compat) keep
  # the legacy install-wide render.
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    return 0
  fi
}

bridge_link_claude_settings_to_shared() {
  local workdir="$1"
  # Issue #570: launch_cmd is accepted for backwards compatibility but the
  # managed autoCompactWindow default is no longer derived from it; the
  # renderer keys off --agent-class instead (issue #593).
  local launch_cmd="${2-}"
  # Issue #555: when the caller passes the agent id (3rd arg), render the
  # effective file at the per-agent path so mixed-model installs get
  # independent values for `autoCompactWindow` (and any future per-agent
  # managed default). When omitted (legacy callers), fall back to the
  # install-wide render so the helper remains backwards-compatible.
  local agent="${3-}"
  local effective_file
  local agent_class=""
  local agent_claude_config_dir=""
  local agent_claude_home=""
  local agent_effective_file=""
  local _wd_owner=""
  if [[ -n "$agent" ]]; then
    effective_file="$(bridge_hook_per_agent_settings_effective_file "$agent")"
    # Issue #593: source class drives the managed autoCompactWindow default
    # (static→400_000, dynamic→1_000_000). Gate the lookup behind a
    # declare-check on BRIDGE_AGENT_SOURCE so callers that haven't sourced
    # the roster (smoke fixtures, back-compat callers) keep working — when
    # the array is missing, agent_class stays empty and the renderer falls
    # back to the unknown-class default (1_000_000). Mirrors the same
    # gating bridge_claude_settings_mode uses for BRIDGE_AGENT_IDS above.
    if declare -p BRIDGE_AGENT_SOURCE >/dev/null 2>&1; then
      agent_class="$(bridge_agent_source "$agent" 2>/dev/null || true)"
    fi
  else
    effective_file="$(bridge_hook_shared_settings_effective_file)"
  fi
  bridge_hooks_python render-shared-settings \
    --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
    --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
    --effective-settings-file "$effective_file" \
    --launch-cmd "$launch_cmd" \
    --agent-class "$agent_class" >/dev/null
  # Issue #1145: defer `cmd_link_shared_settings` under v2 isolation when the
  # workdir hasn't been normalized yet by
  # `bridge_linux_prepare_agent_isolation` (Step A). Step B (this controller-
  # side hook, running as awfmanager) cannot `mkdir` into the isolated tree —
  # it would race Step A and create the leaf with the wrong ownership
  # (`awfmanager:awfmanager 0755` under an `agent-bridge-<a>:` workdir),
  # cascading into PermissionErrors on every subsequent round. Agent start
  # re-triggers this hook after Step A has materialized the tree, so the
  # deferral here is correct (NOT permanently skipped). Guarded on `agent`
  # being set so legacy callers (no agent arg → no v2 semantics) keep their
  # current behavior.
  #
  # r2 (codex BLOCKING): Step-A completion is detected by workdir OWNERSHIP,
  # not by existence. The default v2 fresh-create flow scaffolds workdir as
  # the controller user (`_scaffold_v2_sibling` in `bridge-agent.sh:550-557`,
  # pre-created at `:664-670` / `:675-678`) BEFORE
  # `bridge_linux_prepare_agent_isolation` runs at `bridge-agent.sh:3277`. So
  # at this hook site (which fires via the roster-reload path through
  # `bridge_ensure_claude_shared_settings_for_managed_workdir` at `:3273`)
  # the workdir directory already exists but ownership has NOT yet flipped
  # to `agent-bridge-<agent>`. The pre-r2 existence-only guard therefore
  # did NOT fire in the canonical production shape — the race remained.
  # Detect Step A completion by checking whether the workdir owner is an
  # `agent-bridge-*` user. Pre-Step-A: owner = controller (e.g. awfmanager)
  # → defer. Post-Step-A: owner = `agent-bridge-<agent>` → proceed.
  # `stat -c %U` is GNU/Linux; `stat -f %Su` is BSD/macOS; the chained
  # fallback keeps the guard portable. v2 isolation is Linux-only in
  # practice, but this hook runs on every platform, so we still defend
  # against missing `stat` flavors.
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    _wd_owner=""
    if [[ -d "$workdir" ]]; then
      _wd_owner="$(stat -c %U "$workdir" 2>/dev/null || stat -f %Su "$workdir" 2>/dev/null || true)"
    fi
    if [[ -z "$_wd_owner" || "$_wd_owner" != agent-bridge-* ]]; then
      return 0
    fi
  fi
  bridge_hooks_python link-shared-settings --workdir "$workdir" --shared-settings-file "$effective_file"

  # v2 non-isolated agents launch Claude with CLAUDE_CONFIG_DIR under
  # bridge_agent_default_home (<agent>/home/.claude), while the legacy shared
  # settings link above still targets the workdir-side managed settings file.
  # Mirror the rendered file into the launched Claude config dir so runtime
  # hooks do not keep reading stale ~/.agent-bridge commands from agent HOME.
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_claude_config_dir >/dev/null 2>&1 \
      && { ! command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
           || ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; }; then
    agent_claude_config_dir="$(bridge_agent_claude_config_dir "$agent" 2>/dev/null || true)"
    if [[ -n "$agent_claude_config_dir" ]]; then
      agent_effective_file="$agent_claude_config_dir/settings.effective.json"
      if [[ "$(bridge_hook_paths_equal "$effective_file" "$agent_effective_file")" != "1" ]]; then
        agent_claude_home="${agent_claude_config_dir%/.claude}"
        bridge_hooks_python render-shared-settings \
          --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
          --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
          --effective-settings-file "$agent_effective_file" \
          --launch-cmd "$launch_cmd" \
          --agent-class "$agent_class" >/dev/null
        bridge_hooks_python link-shared-settings --workdir "$agent_claude_home" --shared-settings-file "$agent_effective_file" >/dev/null
      fi
    fi
  fi
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
  # Issue #555: optional 3rd arg routes the post-ensure relink to the
  # per-agent effective file when the caller knows the agent id.
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-stop-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    bridge_hooks_python ensure-stop-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_ensure_claude_session_start_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    bridge_hooks_python ensure-session-start-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_prompt_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    bridge_hooks_python ensure-prompt-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_prompt_guard_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-guard-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    bridge_hooks_python ensure-prompt-guard-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_ensure_claude_tool_policy_hooks() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-tool-policy-hooks --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
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
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-pre-compact-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    bridge_hooks_python ensure-pre-compact-hook --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

# Patch the HUD statusLine command to pipe through hud-usage-tap.py so
# bridge-usage.py keeps receiving .usage-cache.json data even after
# claude-hud v0.0.12+ removed background OAuth polling.  No-op when:
# (a) no statusLine is configured, (b) the statusLine is not a HUD
# command, or (c) the tap is already present.  Idempotent.
bridge_ensure_hud_usage_tap() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-hud-usage-tap --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin python3 >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
    # bridge_link_claude_settings_to_shared skips linux-user isolated agents
    # (the mirror is under a foreign UID). Re-render the isolated home so the
    # patched shared base propagates there too. No-op for non-isolated agents.
    if [[ -n "$agent" ]] && command -v bridge_install_isolated_home_settings >/dev/null 2>&1; then
      bridge_install_isolated_home_settings "$agent" "$launch_cmd" >/dev/null 2>&1 || true
    fi
  else
    bridge_hooks_python ensure-hud-usage-tap --workdir "$workdir" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
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
  # Issue #593: pass the agent's source class through to the renderer so
  # the isolated-home effective file matches the per-agent shared render.
  # Gate the lookup so the helper still works when called from contexts
  # that haven't loaded the roster (BRIDGE_AGENT_SOURCE absent → empty
  # agent_class → renderer falls back to the unknown-class default).
  local agent_class=""
  if declare -p BRIDGE_AGENT_SOURCE >/dev/null 2>&1; then
    agent_class="$(bridge_agent_source "$agent" 2>/dev/null || true)"
  fi

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
  # Internal failure (mkdir/render/install/mv): return 1 so the caller
  # can flag the rerender row as failed. The early predicate-style
  # returns above (lines ~368-379) stay `return 0` because they mean
  # "this agent is not in scope for isolated install" — not a failure.
  # Callers in the migration path (`lib/bridge-migration.sh`) already
  # handle nonzero with `|| bridge_warn …` so they continue best-effort
  # while surfacing the failure. The rerender path (`bridge-agent.sh`,
  # PR #673) catches rc and increments `failed_count`. (Issue #669 r2:
  # codex BLOCKING — silent `return 0` was the same silent-failure
  # pattern as #666.)
  bridge_linux_sudo_root mkdir -p "$target_dir" 2>/dev/null || {
    bridge_warn "isolated home settings install: cannot mkdir $target_dir for $agent (sudo unavailable?)"
    return 1
  }
  bridge_linux_sudo_root chown "root:$os_user" "$target_dir" 2>/dev/null || true
  bridge_linux_sudo_root chmod 0750 "$target_dir" 2>/dev/null || true

  # Stage the render in a controller-owned temp directory. The renderer
  # walks `<stage_home>/.claude/`, which mirrors the layout it expects
  # under the live isolated home but lives entirely under the
  # controller UID so the Python writes succeed without sudo.
  stage_root="$(mktemp -d "${TMPDIR:-/tmp}/bridge-isolated-settings.XXXXXX")" || {
    bridge_warn "isolated home settings install: mktemp failed for $agent"
    return 1
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
      bridge_linux_sudo_root cat "$target_effective" 2>/dev/null >"$stage_effective" || true
    fi
  elif bridge_linux_sudo_root test -f "$target_settings" 2>/dev/null; then
    bridge_linux_sudo_root cat "$target_settings" 2>/dev/null >"$stage_settings" || true
  fi

  if ! bridge_hooks_python render-isolated-home-settings \
        --isolated-home "$stage_home" \
        --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
        --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
        --launch-cmd "$launch_cmd" \
        --agent-class "$agent_class" >"$stage_root/render.out" 2>&1; then
    bridge_warn "isolated home settings install: render failed for $agent ($(head -n1 "$stage_root/render.out" 2>/dev/null || true))"
    rm -rf "$stage_root"
    return 1
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
      return 1
    fi
  fi
  if ! bridge_linux_sudo_root mv -f "$target_effective_tmp" "$target_effective" 2>/dev/null; then
    bridge_warn "isolated home settings install: atomic mv failed for $target_effective"
    bridge_linux_sudo_root rm -f "$target_effective_tmp" 2>/dev/null || true
    rm -rf "$stage_root"
    return 1
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
    return 1
  }
  if ! bridge_linux_sudo_root mv -f "$target_settings_tmp" "$target_settings" 2>/dev/null; then
    bridge_warn "isolated home settings install: atomic symlink swap failed for $target_settings"
    bridge_linux_sudo_root rm -f "$target_settings_tmp" 2>/dev/null || true
    rm -rf "$stage_root"
    return 1
  fi
  bridge_linux_sudo_root chown -h "$os_user:$os_user" "$target_settings" 2>/dev/null || true

  rm -rf "$stage_root"
  return 0
}

bridge_codex_hooks_status() {
  bridge_hooks_python status-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)"
}

bridge_ensure_codex_hooks() {
  bridge_hooks_python ensure-codex-hooks --codex-hooks-file "$(bridge_codex_hooks_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
}

# bridge_ensure_codex_agent_hooks <agent> <agent_home>
#
# Issue #1067 S08: render + verify the Codex hook surface for a single
# agent at the descriptor-owned path (<agent_home>/.codex/hooks.json).
# bridge-hooks.py:ensure-codex-hooks is idempotent — already-present
# entries are left in place. Safe to call on upgrade (the descriptor path
# is stable and per-agent, not the shared $HOME/.codex/hooks.json).
#
# The hook config path is <agent_home>/.codex/hooks.json — matching the
# descriptor's contract for the codex engine (`bridge_engine_hook_config_path
# <agent> codex` returns `<agent_home>/.codex/hooks.json`). The caller
# passes the already-resolved agent_home directly so this function works
# correctly even when the agent is not yet in the roster (create flow),
# without re-invoking the descriptor's roster-dependent resolver.
#
# Called from bridge-agent.sh (codex engine create path) and
# lib/upgrade-helpers/codex-hooks-propagate.sh (upgrade path). Exported
# from lib so smoke drivers sourcing bridge-lib.sh can assert S08 directly.
bridge_ensure_codex_agent_hooks() {
  local agent="$1"
  local agent_home="$2"
  [[ -n "$agent" && -n "$agent_home" ]] || return 0
  # Descriptor contract: codex hook config is <agent_home>/.codex/hooks.json.
  # Use the caller-provided agent_home directly rather than re-resolving via
  # bridge_engine_hook_config_path — the resolver calls bridge_layout_agent_home
  # which depends on the roster being loaded, but at create time the agent is
  # not yet registered. The result is identical to the descriptor's resolution
  # for a registered agent on a v2 install.
  local hook_config_path="$agent_home/.codex/hooks.json"
  mkdir -p "$(dirname "$hook_config_path")" 2>/dev/null || return 0
  bridge_hooks_python ensure-codex-hooks \
    --codex-hooks-file "$hook_config_path" \
    --bridge-home "${BRIDGE_HOME:-$BRIDGE_SCRIPT_DIR}" \
    --python-bin "$(command -v python3 || printf '/usr/bin/python3')" \
    >/dev/null 2>&1 || true
}
