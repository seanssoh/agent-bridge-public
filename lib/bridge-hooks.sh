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

# Issue #1574: pin the interpreter baked into generated hook commands to the
# platform's *system* python rather than a bare `python3`. On a Homebrew-python
# macOS host, Claude Code's hook-execution PATH puts the Homebrew interpreter
# first, so a bare `python3` resolves to e.g. Homebrew 3.14 — which surfaces
# stricter SyntaxWarnings and a per-call "hook error … Traceback" wrapper even
# though the command runs fine. `/usr/bin/python3` is the system interpreter on
# both macOS and the supported Linux targets and matches the pin already used
# by the tracked scaffold (agents/.claude/settings.json). Fall back to the
# PATH-resolved python3 only when `/usr/bin/python3` is genuinely absent (e.g.
# a minimal container) so the pin stays portable and never emits an empty bin.
bridge_hook_pinned_python_bin() {
  if [[ -x /usr/bin/python3 ]]; then
    printf '/usr/bin/python3'
    return 0
  fi
  command -v python3 || printf '/usr/bin/python3'
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

# Queue request #11901 (operator-approved Option 1, 2026-06-10): resolve the
# operator's REAL system-global Claude settings file. SHARED (non-isolated)
# static agents inherit its safety-filtered contents as the bottom-most
# render layer so operator changes to `~/.claude/settings.json` propagate.
#
# Resolution MUST use the operator/controller HOME — NOT $CLAUDE_CONFIG_DIR
# (per-agent-contaminated: `…/agents/<name>/home/.claude`) and NOT
# $BRIDGE_AGENT_HOME_ROOT (the bridge base). `bridge_agent_operator_home_dir`
# is the canonical resolver (BRIDGE_CONTROLLER_HOME test seam ->
# isolation-v2 controller user -> SUDO_USER/USER passwd home -> $HOME). When
# it cannot resolve (no controller home, empty $HOME) we print nothing so
# the Python renderer's `--operator-global-settings-file ""` triggers the
# fail-safe degrade to the bridge base.
bridge_hook_operator_global_settings_file() {
  local operator_home=""
  if command -v bridge_agent_operator_home_dir >/dev/null 2>&1; then
    operator_home="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
  fi
  [[ -n "$operator_home" ]] || return 0
  printf '%s/.claude/settings.json' "$operator_home"
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
  # Issue #1820: on a v2 install the per-agent effective settings — the link
  # target every v2 workdir `.claude/settings.json` symlink points at — must
  # live at the v2 layout-resolved agent home (`<data_root>/agents/<a>/home/
  # .claude/settings.effective.json`), NOT the legacy v1
  # `$BRIDGE_AGENT_HOME_ROOT/<a>/.claude/...`. Rendering+linking to v1 is what
  # kept the v1 tree load-bearing for every session launch (the workdir symlink
  # resolved into v1). `bridge_agent_default_home` is the canonical v2-aware
  # resolver (returns `$BRIDGE_AGENT_ROOT_V2/<a>/home` when v2 is active, the
  # legacy `$BRIDGE_AGENT_HOME_ROOT/<a>` otherwise) — use it so the primary
  # render and the first symlink takeover both land on v2 from the start. The
  # v1 file is still rendered separately as non-load-bearing rollback evidence
  # (see bridge_hook_per_agent_settings_effective_file_v1 below); it is NOT
  # removed in this migration.
  if command -v bridge_agent_default_home >/dev/null 2>&1; then
    local v2_home
    v2_home="$(bridge_agent_default_home "$agent" 2>/dev/null || true)"
    if [[ -n "$v2_home" ]]; then
      printf '%s/.claude/settings.effective.json' "$v2_home"
      return 0
    fi
  fi
  printf '%s/%s/.claude/settings.effective.json' "$BRIDGE_AGENT_HOME_ROOT" "$agent"
}

# Issue #1820: the legacy v1 effective-settings path. Kept as a discrete helper
# so the migration can render it as rollback evidence (non-load-bearing) and so
# the reconcile/invariant smokes can assert the symlink resolves OUTSIDE this
# tree. `bridge_agent_default_home` returns this exact path on a legacy install,
# so the two helpers coincide on v1 and diverge only under v2.
bridge_hook_per_agent_settings_effective_file_v1() {
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

# Issue #1890: resolve the local-mode bridge-hook settings target for
# <workdir> [<agent>]. For a DYNAMIC VANILLA CLAUDE agent (engine==claude &&
# source==dynamic && !iso) the bridge comms hooks go in
# `<workdir>/.claude/settings.local.json` (project-LOCAL scope) — NOT the managed
# `<workdir>/.claude/settings.json`. Claude Code merges user→project→project-
# local and merges hooks additively, so the operator-global ~/.claude
# (settings/model/plugins/MCP) is inherited while the bridge layer rides the
# local overlay. Echoes the settings.local.json path for a dynamic Claude agent;
# echoes nothing otherwise (callers keep the bridge-hooks.py `--workdir` default
# = settings.json, so static managed rendering is unchanged).
#
# Decision keys on the CURRENT agent's predicate (codex review finding 3): when
# the caller passes the agent id (every start/upgrade/run caller does), route on
# THAT agent only — a static/admin agent sharing a workdir with a dynamic agent
# is NEVER redirected. The workdir-scan fallback (no agent id given) is retained
# only for back-compat callers, and it still requires a dynamic-vanilla match.
bridge_claude_dynamic_local_settings_target() {
  local workdir="$1"
  local explicit_agent="${2-}"
  local agent="" agent_workdir=""
  [[ -n "$workdir" ]] || return 0
  command -v bridge_agent_is_dynamic_vanilla_claude >/dev/null 2>&1 || return 0

  if [[ -n "$explicit_agent" ]]; then
    if bridge_agent_is_dynamic_vanilla_claude "$explicit_agent"; then
      printf '%s/.claude/settings.local.json' "$workdir"
    fi
    return 0
  fi

  # Back-compat: no agent id. Fall back to a workdir scan, still gated on the
  # dynamic-vanilla predicate so a static-only workdir is never redirected.
  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 0
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    bridge_agent_is_dynamic_vanilla_claude "$agent" || continue
    agent_workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
    [[ -n "$agent_workdir" ]] || continue
    if [[ "$(bridge_hook_paths_equal "$workdir" "$agent_workdir")" == "1" ]]; then
      printf '%s/.claude/settings.local.json' "$workdir"
      return 0
    fi
  done
  return 0
}

# Issue #1890 (constraints #6): prepare `<workdir>/.claude/settings.local.json`
# before the bridge merges its hook entries into it. The merge itself (in
# bridge-hooks.py) is additive + marker/predicate-based and preserves operator
# keys, so this helper only handles the file-level guards:
#   - LOUD FAIL if the file is already git-TRACKED (refuse to silently modify a
#     committed operator file — return 1 so the caller aborts the hook write).
#   - git-ignore guard: ensure `.claude/settings.local.json` is ignored via
#     `.git/info/exclude` (local-only; never a committed repo .gitignore change)
#     so the bridge-created file does not show up as an untracked change in the
#     operator's repo.
#   - Outside a git repo: create the parent + an empty `{}` file at 0600.
# Idempotent. Returns 0 when the target is safe to write, 1 to abort.
bridge_claude_prepare_dynamic_local_settings() {
  local target="$1"
  local workdir="" claude_dir="" rel="" git_top="" exclude_file=""
  [[ -n "$target" ]] || return 0
  claude_dir="$(dirname "$target")"
  workdir="$(dirname "$claude_dir")"

  # Resolve the enclosing git worktree (if any) from the workdir.
  git_top="$(git -C "$workdir" rev-parse --show-toplevel 2>/dev/null || true)"

  if [[ -n "$git_top" ]]; then
    # LOUD FAIL: refuse to modify a tracked settings.local.json.
    if git -C "$workdir" ls-files --error-unmatch -- "$target" >/dev/null 2>&1; then
      bridge_warn "[#1890] $target is git-TRACKED — refusing to write bridge hooks into a committed operator file. Move it aside (or 'git rm --cached') and restart the agent."
      return 1
    fi
    # git-ignore guard via .git/info/exclude (local-only). Compute the path
    # relative to the worktree top via `git rev-parse --show-prefix` (robust to
    # macOS /private vs /var symlink differences between $workdir and the
    # realpath'd $git_top) + the fixed `.claude/settings.local.json` suffix.
    local _prefix=""
    _prefix="$(git -C "$workdir" rev-parse --show-prefix 2>/dev/null || true)"
    rel="${_prefix}.claude/settings.local.json"
    exclude_file="$git_top/.git/info/exclude"
    # In a linked worktree .git is a file pointer; resolve the real git dir.
    if [[ -f "$git_top/.git" ]]; then
      local real_gitdir=""
      real_gitdir="$(git -C "$workdir" rev-parse --git-common-dir 2>/dev/null || true)"
      [[ -n "$real_gitdir" ]] && exclude_file="$real_gitdir/info/exclude"
    fi
    if [[ -n "$rel" && -n "$exclude_file" ]]; then
      mkdir -p "$(dirname "$exclude_file")" 2>/dev/null || true
      if [[ ! -f "$exclude_file" ]] || ! grep -qxF "$rel" "$exclude_file" 2>/dev/null; then
        printf '%s\n' "$rel" >> "$exclude_file" 2>/dev/null || true
      fi
    fi
  fi

  # Create the parent + a seed file if absent. Outside git (and in git too) the
  # bridge owns this file; seed an empty object at 0600 so the python merge has
  # a valid JSON root to fold its hook entries into, and so an operator who runs
  # vanilla `claude` here does not inherit a stray world-readable file.
  mkdir -p "$claude_dir" 2>/dev/null || true
  if [[ ! -e "$target" ]]; then
    ( umask 0177; printf '{}\n' > "$target" ) 2>/dev/null || true
  fi
  return 0
}

# Issue #1890: resolve the local-mode bridge-hooks.py target args for <workdir>
# into the caller-named array (arg $2, default BRIDGE_LOCAL_HOOK_TARGET_ARGS).
# For a dynamic vanilla Claude workdir the array becomes
# (--settings-file <workdir>/.claude/settings.local.json) after the file-level
# prepare guard runs; for every other workdir it is the unchanged
# (--workdir <workdir>) (bridge-hooks.py default = settings.json). Returns
# non-zero ONLY when the dynamic target is git-tracked and must not be clobbered
# — the caller then skips the hook write loudly. Each ensure/status helper's
# local branch routes through this so the dynamic redirect lives in ONE place
# and static managed rendering is byte-for-byte unchanged.
bridge_claude_local_hook_target_args() {
  local workdir="$1"
  local _outvar="${2:-BRIDGE_LOCAL_HOOK_TARGET_ARGS}"
  local explicit_agent="${3-}"
  local target=""
  target="$(bridge_claude_dynamic_local_settings_target "$workdir" "$explicit_agent")"
  if [[ -n "$target" ]]; then
    bridge_claude_prepare_dynamic_local_settings "$target" || return 1
    # shellcheck disable=SC2086 # eval-assign a 2-element array to the named out var
    eval "$_outvar=(--settings-file \"\$target\")"
    return 0
  fi
  # shellcheck disable=SC2086
  eval "$_outvar=(--workdir \"\$workdir\")"
  return 0
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
  local channels_csv=""
  local agent_claude_config_dir=""
  local agent_claude_home=""
  local agent_effective_file=""
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
    # Issue #1453: resolve the agent's effective channels CSV
    # (BRIDGE_AGENT_CHANNELS SSOT) and thread it to the renderer. The stored
    # launch command does NOT carry the composed `--channels` flag for
    # normally-created channel agents, so without this the renderer cannot
    # tell which channel plugins the agent runs with → managed defaults
    # never assert them enabled and a stale enabledPlugins=false silently
    # drops inbound. Gate on BRIDGE_AGENT_CHANNELS actually being declared
    # (same pattern as the BRIDGE_AGENT_SOURCE guard above): callers that
    # haven't loaded the roster (smoke fixtures, back-compat callers) leave
    # the assoc-array undeclared, and `bridge_agent_channels_csv` would then
    # trip the `${BRIDGE_AGENT_CHANNELS[$agent]-}` undeclared-assoc-array
    # arithmetic-subscript footgun under `set -u`. When undeclared, leave
    # channels_csv empty → the renderer falls back to launch-cmd flag
    # parsing (prior behavior).
    if declare -p BRIDGE_AGENT_CHANNELS >/dev/null 2>&1 \
        && command -v bridge_agent_channels_csv >/dev/null 2>&1; then
      channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
    fi
  else
    effective_file="$(bridge_hook_shared_settings_effective_file)"
  fi
  # #11901: thread the operator's system-global settings file so the SHARED
  # renderer inherits its safety-filtered contents as the bottom-most layer.
  # Scope: SHARED (non-isolated) agents only. A v2 linux-user-isolated agent
  # also reaches this helper (its workdir is under $BRIDGE_AGENT_HOME_ROOT, so
  # bridge_claude_settings_mode == "shared"), but its CANONICAL settings are
  # rendered separately by cmd_render_isolated_home_settings into the isolated
  # home — global inheritance is NOT the iso contract (AC5). So we leave the
  # operator-global EMPTY for isolated agents (defense in depth: the shared
  # effective file an iso agent never reads also stays free of global keys).
  local operator_global_file=""
  if [[ -z "$agent" ]] \
      || ! command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      || ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    operator_global_file="$(bridge_hook_operator_global_settings_file 2>/dev/null || true)"
  fi
  # Issue #1945 (cm-prod F7) ORDERING: this #1145 deferral guard is lifted to run
  # BEFORE the iso-UID render + #1766 group-publish below, where it previously sat
  # AFTER both (gating only the link step). #1945 added a root-escalated iso-UID
  # render; on a pre-Step-A workdir that escalation would write into a tree Step A
  # is about to (re)materialize — the very race #1145 guards against — and in the
  # controller-cannot-escalate shape it would `return 1` (fail-loud) exactly where
  # the deferral contract expects a clean `return 0`. The deferral is the single
  # gate for EVERY controller-side iso-tree mutation (render, #1766 publish, link);
  # an unnormalized workdir defers all three and agent start re-triggers the hook
  # after Step A, so each runs once the tree is owned correctly (NOT permanently
  # skipped). The predicate and its full r1-r3 rationale are unchanged:
  #
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
  # to the agent's resolved OS user. The pre-r2 existence-only guard
  # therefore did NOT fire in the canonical production shape — the race
  # remained.
  #
  # r3 (codex BLOCKING): the prefix glob `agent-bridge-*` is both too loose
  # AND too tight. False-positive: any workdir owned by some other
  # `agent-bridge-<other>` user (e.g. a sibling agent's tree mounted into
  # view) matches the prefix and is treated as Step-A-complete for THIS
  # agent. False-negative: `bridge-agent.sh:111-113` documents `--os-user
  # <user>` as a supported linux-user isolation option, parsed at
  # `bridge-agent.sh:2791-2794` and retained for linux-user mode at
  # `:3000-3001` / `:3036-3050`; Step A chowns the v2 subdirs to that exact
  # value at `lib/bridge-agents.sh:3766-3770` and `:3802`. A valid agent
  # created with `--os-user svc-foo` would be normalized to owner `svc-foo`
  # by Step A, but the prefix glob would never match → defer forever.
  #
  # Fix: cross-check workdir ownership against `bridge_agent_os_user
  # "$agent"` (the roster source of truth — the same value Step A passes to
  # chown). Both fail-closed conditions: empty `_wd_owner` (stat unable to
  # read), empty `_expected_owner` (roster lookup failed), or mismatch →
  # defer. `stat -c %U` is GNU/Linux; `stat -f %Su` is BSD/macOS; the
  # chained fallback keeps the guard portable. v2 isolation is Linux-only
  # in practice, but this hook runs on every platform, so we still defend
  # against missing `stat` flavors.
  # Issue #1151 (v0.14.5-beta10): predicate lifted to
  # `bridge_agent_workdir_step_a_complete` in `lib/bridge-agents.sh` so the
  # same race-safe gate can be applied at every controller-side helper that
  # mutates `$workdir/.claude/*` (4 more sites in addition to this one — see
  # the issue body for the full list). Behavior here is unchanged: when v2
  # isolation is effective for the agent AND the workdir hasn't been
  # normalized to the agent's expected OS user yet, defer; otherwise proceed.
  # The shared helper preserves all r1-r3 properties (existence check,
  # stat-flavor fallback, exact-match against roster `os_user`).
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      && ! bridge_agent_workdir_step_a_complete "$agent" "$workdir"; then
    return 0
  fi
  # Issue #1945 (cm-prod F7): on a v2 linux-user-isolated install
  # `$effective_file` resolves to `$BRIDGE_AGENT_ROOT_V2/<agent>/home/.claude/
  # settings.effective.json`, and that `home/` tree is owned by the ISOLATED
  # UID per the prepare contract (lib/bridge-agents.sh — `home/` mode 2770
  # owner=isolated). `render-shared-settings` (→ bridge-hooks.py save_json)
  # is a bare controller-UID pathlib write (`parent.mkdir` + open `.tmp` +
  # rename); when the controller is not the owner and lacks a LIVE
  # supplementary-group cache for `ab-agent-<a>` (KNOWN_ISSUES §28 / #1207),
  # that write raises `PermissionError [Errno 13]` on
  # `settings.effective.json.tmp` — `agent restart <iso-bot>` then aborts the
  # reseed. Mirror the existing controller→iso publish pattern used by
  # `bridge_install_isolated_home_settings`: render into a controller-owned
  # stage, then `bridge_linux_sudo_root install`/`mv` the result into the
  # final path under root, matching `save_json`'s mode 0600 (the #1766
  # group-publish below then makes it iso-readable). Fail loud — do NOT fall
  # back to a controller-direct write that re-denies. Shared / non-isolated
  # agents keep the direct render below (byte-for-byte unchanged).
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    if ! command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_warn "isolation v2 (#1945): bridge_linux_sudo_root unavailable; cannot render isolated effective settings for '$agent'"
      return 1
    fi
    # Preflight escalation availability BEFORE staging (codex r2). On Linux as a
    # non-root caller, `bridge_linux_sudo_root` `bridge_die`s (process `exit`)
    # when the `sudo` binary is absent — and a process `exit` would skip the
    # explicit stage cleanup below, leaking the temp dir. Refuse here (fail-loud
    # `return 1`, never `exit`) so every post-mktemp escalation can only `return`,
    # keeping each return path's `rm -rf "$_eff_stage_root"` reachable. Off-Linux
    # / as root, `bridge_linux_sudo_root` runs direct and never dies — a no-op.
    if [[ "$(uname -s 2>/dev/null)" == "Linux" ]] \
        && [[ "$(id -u)" != "0" ]] \
        && ! command -v sudo >/dev/null 2>&1; then
      bridge_warn "isolation v2 (#1945): sudo unavailable; cannot escalate to render isolated effective settings for '$agent'"
      return 1
    fi
    local _eff_dir_iso="${effective_file%/*}"
    local _eff_tmp_iso="${effective_file}.tmp.$$"
    local _eff_stage_root="" _eff_stage_file=""
    _eff_stage_root="$(mktemp -d "${TMPDIR:-/tmp}/bridge-shared-settings.XXXXXX")" || {
      bridge_warn "isolation v2 (#1945): mktemp failed staging shared settings for '$agent'"
      return 1
    }
    _eff_stage_file="$_eff_stage_root/settings.effective.json"
    # The controller-owned stage is removed on EVERY post-mktemp return path
    # below via an explicit `rm -rf "$_eff_stage_root"`. A `trap … RETURN` was
    # rejected (codex r3): it persists past this function into the caller's shell
    # and would fire on later returns; and it would not fire on a `bridge_die`
    # `exit` anyway — which the sudo preflight above now makes unreachable, so
    # explicit per-path cleanup is both complete and leak-free.
    # Symlink-redirect guard (codex review, #1945): the iso UID OWNS
    # `$BRIDGE_AGENT_ROOT_V2/<agent>/home/` (mode 2770), so it can swap `.claude`
    # or `settings.effective.json` for a symlink and aim the upcoming root-backed
    # mkdir/install/mv at an arbitrary target (root would follow it). Refuse if
    # either the target dir or the final file is a symlink. The probe is
    # sudo-backed (`bridge_linux_sudo_root test -L`) so it has the SAME privilege
    # as the write it guards — a stale controller group cache cannot mask an
    # attacker-planted link. Mirrors the install-block / normalize-contract
    # symlink anchoring (`bridge_install_isolated_home_settings`,
    # `bridge_linux_normalize_isolated_home_contract`).
    if bridge_linux_sudo_root test -L "$_eff_dir_iso" 2>/dev/null \
        || bridge_linux_sudo_root test -L "$effective_file" 2>/dev/null; then
      bridge_warn "isolation v2 (#1945): refusing root write — symlink at '$_eff_dir_iso' or '$effective_file' for '$agent' (iso-UID redirect attempt). Repair with \`agent-bridge isolate $agent --reapply\`."
      rm -rf "$_eff_stage_root"
      return 1
    fi
    if ! bridge_hooks_python render-shared-settings \
        --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
        --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
        --effective-settings-file "$_eff_stage_file" \
        --operator-global-settings-file "$operator_global_file" \
        --launch-cmd "$launch_cmd" \
        --agent-class "$agent_class" \
        --channels-csv "$channels_csv" >/dev/null; then
      bridge_warn "isolation v2 (#1945): shared settings render failed for '$agent'"
      rm -rf "$_eff_stage_root"
      return 1
    fi
    if ! bridge_linux_sudo_root mkdir -p "$_eff_dir_iso" 2>/dev/null; then
      bridge_warn "isolation v2 (#1945): cannot ensure '$_eff_dir_iso' for '$agent'"
      rm -rf "$_eff_stage_root"
      return 1
    fi
    if ! bridge_linux_sudo_root install -m 0600 "$_eff_stage_file" "$_eff_tmp_iso" 2>/dev/null; then
      bridge_warn "isolation v2 (#1945): staged install of effective settings failed for '$effective_file'"
      bridge_linux_sudo_root rm -f "$_eff_tmp_iso" 2>/dev/null || true
      rm -rf "$_eff_stage_root"
      return 1
    fi
    if ! bridge_linux_sudo_root mv -f "$_eff_tmp_iso" "$effective_file" 2>/dev/null; then
      bridge_warn "isolation v2 (#1945): atomic mv of effective settings failed for '$effective_file'"
      bridge_linux_sudo_root rm -f "$_eff_tmp_iso" 2>/dev/null || true
      rm -rf "$_eff_stage_root"
      return 1
    fi
    rm -rf "$_eff_stage_root"
  else
    bridge_hooks_python render-shared-settings \
      --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
      --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
      --effective-settings-file "$effective_file" \
      --operator-global-settings-file "$operator_global_file" \
      --launch-cmd "$launch_cmd" \
      --agent-class "$agent_class" \
      --channels-csv "$channels_csv" >/dev/null
  fi
  # Issue #1766: the per-agent effective file just rendered (the link target
  # the workdir `.claude/settings.json` symlink points at) is controller-owned
  # mode 0600 — `bridge-hooks.py:save_json` writes it `os.chmod(... 0o600)`. On
  # a v2 linux-user-isolated agent the iso UID `agent-bridge-<a>` is NOT the
  # controller, so it cannot read its own `workdir/.claude/settings.json` target
  # and Claude renders a blocking "Settings Error" picker on every (re)start.
  # Publish the effective file group-readable to the agent's OWN group only:
  # `chgrp ab-agent-<a>` + mode 0640 (group READ, no group write — the file
  # stays controller-owned so the iso UID can never rewrite the hook contract,
  # the same integrity boundary cmd_render_isolated_home_settings keeps), and
  # the parent `.claude/` dir group-traversable at 0750. Never `ab-shared`,
  # never world. Gated on v2 isolation being effective for this agent; on
  # shared/macOS installs the enforce gate inside each helper makes this a
  # no-op (byte-for-byte unchanged). The chgrp helpers are defined in
  # lib/bridge-isolation-v2.sh (sourced after this module but available at
  # runtime); command -v guards keep legacy/partial source-orders safe.
  if [[ -n "$agent" ]] \
      && command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
      && bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      && command -v bridge_isolation_v2_chgrp_file_iso_group >/dev/null 2>&1; then
    local _eff_dir="${effective_file%/*}"
    if [[ -d "$_eff_dir" ]] \
        && command -v bridge_isolation_v2_chgrp_dir_iso_group >/dev/null 2>&1; then
      bridge_isolation_v2_chgrp_dir_iso_group "$agent" "$_eff_dir" 0750 \
        || bridge_warn "isolation v2 (#1766): could not publish settings dir '$_eff_dir' to the agent group for '$agent' (non-fatal); the iso UID may EACCES on its own settings.json until \`agent-bridge isolate $agent --reapply\`."
    fi
    if [[ -f "$effective_file" ]]; then
      bridge_isolation_v2_chgrp_file_iso_group "$agent" "$effective_file" 0640 \
        || bridge_warn "isolation v2 (#1766): could not group-publish the effective settings file '$effective_file' for '$agent' (non-fatal); the iso UID may EACCES on its own project settings until \`agent-bridge isolate $agent --reapply\`."
    fi
  fi
  # #1756 r2: thread the launched channel context so the adoption fold repairs
  # a sticky-false launched-channel enabledPlugins entry (#1453) instead of
  # re-disabling inbound delivery at symlink takeover. Same vars the
  # render-shared-settings call above passes.
  #
  # Issue #1820: `$effective_file` now resolves to the v2 agent home on a v2
  # install (see bridge_hook_per_agent_settings_effective_file), so this
  # link-shared-settings call atomically retargets the workdir
  # `.claude/settings.json` symlink AWAY from the legacy v1
  # `$BRIDGE_AGENT_HOME_ROOT/<a>/.claude/settings.effective.json` and toward the
  # v2 effective file — making the v1 tree no longer load-bearing for session
  # launch. The link op is itself atomic (cmd_link_shared_settings replaces the
  # symlink via a relative-target `symlink_to`).
  bridge_hooks_python link-shared-settings --workdir "$workdir" --shared-settings-file "$effective_file" \
    --launch-cmd "$launch_cmd" \
    --channels-csv "$channels_csv"

  # Issue #1820 (rollback evidence): on a v2 install, also render the legacy v1
  # effective file so it stays a readable, current snapshot operators can fall
  # back to if a v2 rollback is needed. It is intentionally NON-load-bearing —
  # no symlink points at it after the takeover above — and it is NOT removed by
  # this migration (the verdict's safe-removal conditions are enforced
  # elsewhere). Skipped when v1 and v2 paths coincide (legacy install) or for
  # iso agents (their canonical render is cmd_render_isolated_home_settings).
  if [[ -n "$agent" ]] \
      && { ! command -v bridge_agent_linux_user_isolation_effective >/dev/null 2>&1 \
           || ! bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; }; then
    local v1_effective_file
    v1_effective_file="$(bridge_hook_per_agent_settings_effective_file_v1 "$agent")"
    if [[ "$(bridge_hook_paths_equal "$effective_file" "$v1_effective_file")" != "1" ]]; then
      local v1_eff_dir="${v1_effective_file%/*}"
      mkdir -p "$v1_eff_dir" 2>/dev/null || true
      bridge_hooks_python render-shared-settings \
        --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
        --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
        --effective-settings-file "$v1_effective_file" \
        --operator-global-settings-file "$operator_global_file" \
        --launch-cmd "$launch_cmd" \
        --agent-class "$agent_class" \
        --channels-csv "$channels_csv" >/dev/null 2>&1 || true
    fi
  fi

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
      agent_claude_home="${agent_claude_config_dir%/.claude}"
      if [[ "$(bridge_hook_paths_equal "$effective_file" "$agent_effective_file")" == "1" ]]; then
        # Issue #1820: after the writer-3 fix the PRIMARY effective render above
        # already targets this v2 config-dir effective file
        # (bridge_hook_per_agent_settings_effective_file now resolves to the v2
        # home, which coincides with bridge_agent_claude_config_dir for a v2
        # non-iso agent). Do NOT re-render — that would be redundant work — but
        # the launched Claude CLAUDE_CONFIG_DIR still needs its own
        # `settings.json -> settings.effective.json` symlink, so ensure that
        # link here. (Pre-#1820 this branch was the "paths already equal, skip
        # entirely" no-op; the config-dir link was created by the render+link
        # in the else branch which no longer runs once the paths coincide.)
        bridge_hooks_python link-shared-settings --workdir "$agent_claude_home" --shared-settings-file "$agent_effective_file" \
          --launch-cmd "$launch_cmd" \
          --channels-csv "$channels_csv" >/dev/null
      else
        bridge_hooks_python render-shared-settings \
          --base-settings-file "$(bridge_hook_shared_settings_base_file)" \
          --overlay-settings-file "$(bridge_hook_shared_settings_overlay_file)" \
          --effective-settings-file "$agent_effective_file" \
          --operator-global-settings-file "$operator_global_file" \
          --launch-cmd "$launch_cmd" \
          --agent-class "$agent_class" \
          --channels-csv "$channels_csv" >/dev/null
        bridge_hooks_python link-shared-settings --workdir "$agent_claude_home" --shared-settings-file "$agent_effective_file" \
          --launch-cmd "$launch_cmd" \
          --channels-csv "$channels_csv" >/dev/null
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
  local agent="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-stop-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python status-stop-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_claude_session_start_hook_status() {
  local workdir="$1"
  local agent="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python status-session-start-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_claude_prompt_hook_status() {
  local workdir="$1"
  local agent="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python status-prompt-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_claude_prompt_guard_hook_status() {
  local workdir="$1"
  local agent="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-prompt-guard-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python status-prompt-guard-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  fi
}

bridge_claude_tool_policy_hooks_status() {
  local workdir="$1"
  local agent="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-tool-policy-hooks --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python status-tool-policy-hooks "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
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
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-stop-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN"
  fi
}

bridge_ensure_claude_session_start_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-session-start-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-session-start-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)"
  fi
}

bridge_ensure_claude_prompt_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --bash-bin bash --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-prompt-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --bash-bin "$BRIDGE_BASH_BIN" --python-bin "$(bridge_hook_pinned_python_bin)"
  fi
}

bridge_ensure_claude_prompt_guard_hook() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-prompt-guard-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-prompt-guard-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)"
  fi
}

bridge_ensure_claude_tool_policy_hooks() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-tool-policy-hooks --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-tool-policy-hooks "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)"
  fi
}

# Issue #1923: hard-ban AskUserQuestion for EVERY Claude agent. Installs the
# dedicated PreToolUse deny hook (the guaranteed mechanism under
# `--dangerously-skip-permissions`) + the scoped `AskUserQuestion(*)` deny.
# Same shared/local routing as the helpers above: shared mode mutates the
# shared base file then relinks; local mode routes through
# bridge_claude_local_hook_target_args so a dynamic-vanilla agent writes the
# ban into <workdir>/.claude/settings.local.json (#1890 comms-only target) and
# a static-local agent writes settings.json. This is the ONE AskUserQuestion
# surface a vanilla agent gets — it does NOT depend on full tool-policy.
bridge_ensure_claude_askuserquestion_ban() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-askuserquestion-ban --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-askuserquestion-ban "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)"
  fi
}

bridge_claude_askuserquestion_ban_status() {
  local workdir="$1"
  local agent="${2-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python status-askuserquestion-ban --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python status-askuserquestion-ban "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)"
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
    bridge_hooks_python ensure-pre-compact-hook --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-pre-compact-hook "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)"
  fi
}

# Patch the HUD statusLine command to pipe through hud-usage-tap.py so
# bridge-usage.py keeps receiving .usage-cache.json data even after
# claude-hud v0.0.12+ removed background OAuth polling.  When the
# statusLine slot is EMPTY (absent / {} / empty command) the tap is
# installed standalone so live sessions still produce the real measured
# usage cache.  No-op when: (a) the statusLine is a foreign non-HUD
# command (never clobbered), or (b) the tap is already present.
# Idempotent.
bridge_ensure_hud_usage_tap() {
  local workdir="$1"
  local launch_cmd="${2-}"
  local agent="${3-}"
  if [[ "$(bridge_claude_settings_mode "$workdir")" == "shared" ]]; then
    bridge_hooks_python ensure-hud-usage-tap --settings-file "$(bridge_hook_shared_settings_base_file)" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)" >/dev/null
    bridge_link_claude_settings_to_shared "$workdir" "$launch_cmd" "$agent"
    # bridge_link_claude_settings_to_shared skips linux-user isolated agents
    # (the mirror is under a foreign UID). Re-render the isolated home so the
    # patched shared base propagates there too. No-op for non-isolated agents.
    if [[ -n "$agent" ]] && command -v bridge_install_isolated_home_settings >/dev/null 2>&1; then
      bridge_install_isolated_home_settings "$agent" "$launch_cmd" >/dev/null 2>&1 || true
    fi
  else
    local -a _ta=(); bridge_claude_local_hook_target_args "$workdir" _ta "$agent" || return 1
    bridge_hooks_python ensure-hud-usage-tap "${_ta[@]}" --bridge-home "$BRIDGE_HOME" --python-bin "$(bridge_hook_pinned_python_bin)"
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
  # Issue #1453: resolve the agent's effective channels CSV
  # (BRIDGE_AGENT_CHANNELS SSOT) and thread it to the isolated-home renderer
  # — the stored launch command does not carry the composed `--channels`
  # flag, so the CSV is the only signal for the launched channel plugin set
  # (see bridge_link_claude_settings_to_shared for the full rationale). Gate
  # on BRIDGE_AGENT_CHANNELS being declared so an unloaded roster does not
  # trip the undeclared-assoc-array footgun under `set -u`.
  local channels_csv=""
  if declare -p BRIDGE_AGENT_CHANNELS >/dev/null 2>&1 \
      && command -v bridge_agent_channels_csv >/dev/null 2>&1; then
    channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
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
  # UID gets group rwx via group=ab-agent-<agent> + mode 3770 (sticky +
  # setgid + group rwx). Sticky blocks unlink-by-non-owner so the
  # root-owned `settings.json` / `settings.effective.json` cannot be
  # removed by the isolated UID, even though it can write its own
  # files inside (`projects/`, `session-env/`).
  #
  # ARCHITECTURAL ROOT OF FAMILY 3 (Phase 3 acceptance gap H — patch
  # 2026-05-24): this block previously chowned `.claude` to
  # `root:$os_user` mode `0750`, which directly contradicted the
  # prepare contract (`root:ab-agent-<agent>` mode `3770`/`2770`).
  # Every restart silently reverted the directory back to a state
  # where the isolated UID could not mkdir `.claude/session-env/`
  # from the supplementary-group path (the hook's effective UID in
  # practice — see lib/bridge-agents.sh #1165 Gap 2 comment). The
  # beta14 #1165 Gap 2 smoke only verified prepare set 2770; it did
  # not verify restart preserved it.
  #
  # Phase 3 fix: route through the shared helper
  # `bridge_linux_normalize_isolated_home_contract` so prepare,
  # restart, and credential-prepare all converge on the same contract
  # for HOME / .claude / .claude/plugins / .claude/session-env.
  #
  # Codex r1 needs-more on PR #561 (historical): previously this dir
  # was chowned to the isolated UID directly, so even though the
  # inner files were root-owned, the isolated UID could rm/replace
  # them via the parent's write bit. Switching to root-owned + sticky
  # + setgid + group rwx (3770) closes that gap while still letting
  # the isolated UID's hook process create its own subdirs.
  #
  # Internal failure (helper/render/install/mv): return 1 so the
  # caller can flag the rerender row as failed. The early
  # predicate-style returns above (lines ~368-379) stay `return 0`
  # because they mean "this agent is not in scope for isolated
  # install" — not a failure. Callers in the migration path
  # (`lib/bridge-migration.sh`) already handle nonzero with
  # `|| bridge_warn …` so they continue best-effort while surfacing
  # the failure. The rerender path (`bridge-agent.sh`, PR #673)
  # catches rc and increments `failed_count`. (Issue #669 r2: codex
  # BLOCKING — silent `return 0` was the same silent-failure
  # pattern as #666.)
  # ALLOW_RUNNING=1: this code path is called from
  # `bridge_ensure_hud_usage_tap` (mid-session) and the restart path
  # (just after `--replace` stop, before the next start). In both
  # cases the controller is the legitimate writer and the helper's
  # external-caller race guard is not the right safety mechanism
  # here. The reconciler `--apply` path (operator-invoked from CLI)
  # keeps the default `BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=0` and
  # refuses on a running session, because the operator must stop the
  # agent first.
  local _isolated_home="$isolated_home"
  if ! BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1 \
        bridge_linux_normalize_isolated_home_contract "$agent" "$os_user" "$_isolated_home" >/dev/null; then
    bridge_warn "isolated home settings install: home contract normalize failed for $agent (sudo unavailable or symlink injection); skipping render"
    return 1
  fi

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
        --agent-class "$agent_class" \
        --channels-csv "$channels_csv" >"$stage_root/render.out" 2>&1; then
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

# bridge_codex_config_file_for_hooks <hooks_file>
#
# Issue #2007: Codex reads its trust store from `config.toml` in the SAME
# CODEX_HOME directory as the `hooks.json` it loads. The pretrust wrapper writes
# trust into that sibling config — `<dirname hooks.json>/config.toml` — which is
# exactly what the launched codex will read (for `~/.codex/hooks.json` the
# sibling is `~/.codex/config.toml`; for a per-agent `<agent_home>/.codex/
# hooks.json` it is `<agent_home>/.codex/config.toml`).
bridge_codex_config_file_for_hooks() {
  local hooks_file="$1"
  [[ -n "$hooks_file" ]] || return 1
  printf '%s/config.toml' "$(dirname "$hooks_file")"
}

# bridge_codex_pretrust_first_party_hooks <hooks_file> [bridge_home]
#
# Issue #2007 (prevention layer): pre-trust ONLY the bridge's own first-party
# Codex hooks in the sibling config.toml so a hook-changing upgrade never wedges
# a managed Codex agent at Codex's startup hook-trust gate. STRICT first-party
# boundary + fail-closed inside bridge-hooks.py (never
# --dangerously-bypass-hook-trust; foreign/plugin/operator entries left
# untrusted for the #1992/#2007 detector). Non-fatal here: a pretrust failure
# downgrades to the detector path — it must NEVER block the launch/render.
bridge_codex_pretrust_first_party_hooks() {
  local hooks_file="$1"
  local bridge_home="${2:-${BRIDGE_HOME:-$BRIDGE_SCRIPT_DIR}}"
  local config_file=""
  [[ -n "$hooks_file" ]] || return 0
  config_file="$(bridge_codex_config_file_for_hooks "$hooks_file")" || return 0
  # Suppress only the shell-parseable STDOUT fields (the caller does not consume
  # them here); let STDERR flow so the helper's fail-closed warn line ("leaving
  # hooks UNtrusted for the detector to surface ...") reaches the start/upgrade
  # log — the detector relies on that signal, not the exit code alone (codex
  # review #2007 r1, Finding 3). Non-fatal regardless.
  bridge_hooks_python ensure-codex-hook-trust \
    --codex-hooks-file "$hooks_file" \
    --codex-config-file "$config_file" \
    --bridge-home "$bridge_home" \
    --python-bin "$(command -v python3 || printf '/usr/bin/python3')" \
    >/dev/null || true
  return 0
}

bridge_ensure_codex_hooks() {
  local hooks_file rc=0
  hooks_file="$(bridge_codex_hooks_file)"
  bridge_hooks_python ensure-codex-hooks --codex-hooks-file "$hooks_file" --bridge-home "$BRIDGE_HOME" --python-bin "$(command -v python3)" || rc=$?
  # The render exit code is load-bearing (the caller bridge_die's on failure),
  # so capture it BEFORE the pretrust step and return it unchanged.
  if [[ $rc -eq 0 ]]; then
    # Issue #2007: pre-trust the bridge's own hooks AFTER a successful render so
    # the managed launch does not wedge at Codex's hook-trust gate (prevention).
    # Non-fatal: a pretrust failure downgrades to the detector path.
    bridge_codex_pretrust_first_party_hooks "$hooks_file" "$BRIDGE_HOME"
  fi
  return "$rc"
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
  # Issue #2007: pre-trust the per-agent first-party hooks so a fresh codex
  # agent (or a partially-upgraded host) does not wedge at the hook-trust gate.
  bridge_codex_pretrust_first_party_hooks "$hook_config_path" "${BRIDGE_HOME:-$BRIDGE_SCRIPT_DIR}"
}

# Issue #1899: a dynamic vanilla Codex agent runs as vanilla Codex CLI against
# the operator-global ~/.codex, so the bridge must NOT write its comms hooks to
# ~/.codex/hooks.json (operator-global pollution) NOR to <agent_home>/.codex/
# hooks.json (the managed per-agent path the agent never reads in this mode).
# Instead it installs them PROJECT-LOCAL at <workdir>/.codex/hooks.json — a
# layer Codex merges on top of the user layer (all sources run; higher layers
# don't replace lower hooks). Returns the resolved path.
bridge_codex_dynamic_project_hooks_file() {
  local workdir="$1"
  [[ -n "$workdir" ]] || return 1
  printf '%s/.codex/hooks.json' "$workdir"
}

# bridge_ensure_codex_dynamic_project_hooks <agent> <workdir>
#
# Issue #1899: install/update the bridge comms hooks into the project-local
# <workdir>/.codex/hooks.json for a dynamic vanilla Codex agent, then DETECT +
# REPORT (operator-visible warning + audit row) when Codex project trust would
# prevent those hooks from firing. We do NOT establish trust and do NOT blanket
# `--dangerously-bypass-hook-trust` (it bypasses trust for ALL enabled hooks —
# too broad as a default); the fail-closed comms guarantee is the forced
# `-c features.hooks=true` on the launch command (lib/bridge-state.sh). rc 0 on
# a successful write even when trust is unresolved — the launch must proceed and
# the operator decides on trust; rc non-zero only on a hard write failure.
bridge_ensure_codex_dynamic_project_hooks() {
  local agent="$1"
  local workdir="$2"
  local hook_file=""
  local operator_home=""
  local codex_config=""
  local trust_out=""
  [[ -n "$agent" && -n "$workdir" ]] || return 0

  hook_file="$(bridge_codex_dynamic_project_hooks_file "$workdir")" || return 0
  mkdir -p "$(dirname "$hook_file")" 2>/dev/null || return 1

  if ! bridge_hooks_python ensure-codex-hooks \
       --codex-hooks-file "$hook_file" \
       --bridge-home "${BRIDGE_HOME:-$BRIDGE_SCRIPT_DIR}" \
       --python-bin "$(command -v python3 || printf '/usr/bin/python3')" \
       >/dev/null 2>&1; then
    bridge_warn "Codex dynamic project hooks 설치 실패: $hook_file"
    return 1
  fi

  # Detect + report trust state against the SAME config.toml the launched codex
  # will read. The dynamic vanilla launch pins CODEX_HOME = <operator_home>/.codex
  # (bridge_run_export_codex_launch_env), so trust must be checked there — NOT
  # against this controller process's ambient CODEX_HOME, which may point
  # elsewhere and would mis-report trust for the launched child.
  if command -v bridge_agent_operator_home_dir >/dev/null 2>&1; then
    operator_home="$(bridge_agent_operator_home_dir 2>/dev/null || true)"
  fi
  [[ -n "$operator_home" ]] || operator_home="$HOME"
  codex_config="$operator_home/.codex/config.toml"

  trust_out="$(bridge_hooks_python status-codex-project-trust \
    --workdir "$workdir" --codex-config-file "$codex_config" 2>/dev/null || true)"
  local _blocked="" _trust=""
  if [[ -n "$trust_out" ]]; then
    _blocked="$(printf '%s\n' "$trust_out" | sed -n 's/^CODEX_PROJECT_HOOKS_COMMS_BLOCKED=//p' | tr -d "'\"")"
    _trust="$(printf '%s\n' "$trust_out" | sed -n 's/^CODEX_PROJECT_TRUST_LEVEL=//p' | tr -d "'\"")"
  fi
  if [[ "$_blocked" == "1" ]]; then
    bridge_warn "Codex dynamic agent '$agent': project '$workdir' is UNTRUSTED — the bridge comms hooks at $hook_file will NOT run until you trust the project (run 'codex' once in $workdir and accept, or set trust_level=\"trusted\" for it in $codex_config). Bridge queue/inbox delivery is degraded until then."
    bridge_audit_log state codex_dynamic_project_hooks_untrusted "$agent" \
      --field "workdir=$workdir" \
      --field "hooks_file=$hook_file" \
      --field "trust_level=${_trust:-untrusted}" \
      2>/dev/null || true
  elif [[ "$_trust" == "unknown" ]]; then
    bridge_warn "Codex dynamic agent '$agent': could not confirm Codex project trust for '$workdir' (config: $codex_config). If bridge queue hooks do not fire, trust the project in Codex (run 'codex' once in $workdir and accept)."
    bridge_audit_log state codex_dynamic_project_hooks_trust_unknown "$agent" \
      --field "workdir=$workdir" \
      --field "hooks_file=$hook_file" \
      2>/dev/null || true
  fi
  return 0
}
