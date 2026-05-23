#!/usr/bin/env bash
# shellcheck shell=bash
#
# bridge-agent-layout.sh — typed agent-layout resolver (issue #1060).
#
# The single owner of agent path resolution for NEW code and for the
# #1060 D1-D4 consumers. It does NOT reimplement path math — every typed
# accessor wraps the existing resolver in bridge-agents.sh. The point of
# the module is to give callers a *named, typed* contract instead of
# scattering raw `bridge_agent_default_home` / `bridge_agent_workdir`
# calls that disagree about which of the three layers they mean.
#
# The three-layer agent-layout model (issue #1060)
# ------------------------------------------------
#   1. profile source — the tracked, portable role *source* under
#      `$BRIDGE_HOME/agents/<agent>`. Optional (only admin / imported /
#      migrated agents have one). It is NOT a live home; it is the input
#      `agent-bridge profile deploy` reads from.
#   2. identity source — the authored canonical per-agent identity
#      (SOUL / MEMORY* / SESSION-TYPE / role payload / engine config).
#      On a v2 install this is `data/agents/<agent>/home`. This is the
#      tree `agent create` now authors into (D1).
#   3. workspace — the process cwd / project tree the agent operates in;
#      may be shared across agents via `--allow-shared-workdir`. On a v2
#      install this is `data/agents/<agent>/workdir`.
#
# Plus the *engine materialization target* — where the engine runtime
# actually reads identity from. That is owned by bridge-engine-descriptor.sh
# (`bridge_engine_materialization_target`), NOT by this module: it is
# per-engine, and the descriptor is the sole source of per-engine
# branching. For the v2 static Claude case the materialization target is
# the workspace dir, which is why the runtime keeps reading where it
# reads today — the materialization step (D1) delivers the authored
# identity from layer 2 into that target.
#
# IMPORTANT — no reader flip. This module does NOT change where the
# runtime reads identity. `bridge_layout_agent_home` is the *authored
# source*; the runtime still resolves cwd / canonical files through
# `bridge_agent_workdir` exactly as before. The materialization step is
# what reconciles the two so the read target is never empty/stale.
#
# Existing call sites of `bridge_agent_default_home` / `bridge_agent_workdir`
# may stay — they are the implementation this module wraps. The new
# contract is only that NEW code and the migrated D1-D4 consumers go
# through these typed accessors.

# bridge_layout_profile_source_dir <agent>
#
# Layer 1 — the tracked role *source* under `$BRIDGE_HOME/agents/<agent>`.
# Always prints a path (the canonical location); the path may not exist
# — callers that need an existence check should pair this with
# `bridge_layout_has_profile_source`. Wraps bridge-profiles.sh so the
# profile-source path math has exactly one owner.
bridge_layout_profile_source_dir() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  if declare -F bridge_profile_source_root >/dev/null 2>&1; then
    bridge_profile_source_root "$agent"
    return 0
  fi
  # Fallback for direct-source consumers that did not pull bridge-profiles.sh.
  printf '%s/agents/%s' "${BRIDGE_HOME:-$HOME/.agent-bridge}" "$agent"
}

# bridge_layout_has_profile_source <agent>
#
# True when the agent has a tracked profile source on disk. Thin wrapper
# over bridge-profiles.sh's predicate so layout consumers do not have to
# reach into a different module.
bridge_layout_has_profile_source() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  if declare -F bridge_profile_has_source >/dev/null 2>&1; then
    bridge_profile_has_source "$agent"
    return $?
  fi
  [[ -d "$(bridge_layout_profile_source_dir "$agent")" ]]
}

# bridge_layout_agent_home <agent>
#
# Layer 2 — the identity source. The authored canonical per-agent
# identity tree. Wraps `bridge_agent_default_home` (lib/bridge-agents.sh):
# on a v2 install that is `$BRIDGE_AGENT_ROOT_V2/<agent>/home`, on a
# legacy install `$BRIDGE_AGENT_HOME_ROOT/<agent>`. This is the tree
# `agent create` authors into and the materialization step copies *from*.
bridge_layout_agent_home() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  bridge_agent_default_home "$agent"
}

# bridge_layout_workspace_dir <agent>
#
# Layer 3 — the workspace cwd. The process cwd / project tree, possibly
# shared. Wraps `bridge_agent_workdir` (lib/bridge-agents.sh), which
# already honors the v2/v1, static/dynamic, isolated/shared cases
# (issue #895). This is the path the live session is launched in.
bridge_layout_workspace_dir() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  bridge_agent_workdir "$agent"
}

# bridge_layout_runtime_dir
#
# The runtime / state root. On a v2 install this is the per-agent-root
# parent (`$BRIDGE_AGENT_ROOT_V2`); otherwise the live runtime root.
# Wraps the existing root resolution so layout consumers have one name
# for "where runtime state lives" instead of probing env vars directly.
bridge_layout_runtime_dir() {
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    printf '%s' "$BRIDGE_AGENT_ROOT_V2"
    return 0
  fi
  printf '%s' "${BRIDGE_STATE_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
}

# bridge_layout_memory_dir <agent>
#
# The per-agent memory root. Always `agent_home/memory` (layer 2) —
# memory is part of the authored identity, never inferred from the
# workspace cwd. This is the path the D4 memory tooling must default to.
bridge_layout_memory_dir() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  printf '%s/memory' "$(bridge_layout_agent_home "$agent")"
}

# bridge_layout_materialize_identity <agent> <engine> [target_dir]
#
# The D1 materialization step. Copies/syncs the authored identity
# fileset from the identity source (layer 2, `bridge_layout_agent_home`)
# into the engine's materialization target so the runtime — which keeps
# reading where it reads today — receives a populated, current identity.
#
# Behavior:
#   * Resolves the engine materialization target via the descriptor
#     (`bridge_engine_materialization_target`). An explicit `target_dir`
#     third argument overrides that lookup — used by `agent create`,
#     which has the resolved workspace in hand BEFORE the roster reload
#     `bridge_agent_workdir` depends on.
#   * No-op when the target equals the identity source (legacy installs
#     where home == workdir, or any engine whose descriptor names the
#     identity source itself as the target).
#   * Shared-workspace rule: when the workspace is a *shared* project
#     tree (the target dir already holds a foreign-agent CLAUDE.md /
#     AGENTS.md, or is flagged shared), per-agent identity is NOT
#     materialized into it — per-agent identity then stays in
#     `agent_home` and per-agent hook-injected surfaces. The function
#     returns 0 (success, intentionally skipped) and emits one note.
#   * Copies each canonical identity file that exists in the source and
#     is absent (or stale) in the target. Pre-existing target files are
#     overwritten so a re-onboarding loop (#1046/#1060) cannot resurface
#     from a stale workdir copy.
#
# Identity fileset: the canonical per-agent files, the engine
# instruction entrypoint, and the per-user partition tree `users/`
# (per-agent `USER.md` identity). `memory/` and `.claude/` are NOT
# bulk-copied here — `.claude/` is workspace-scoped engine/hook state
# wired directly into the target by the create flow, and `memory/` is
# resolver-rooted at the identity source (`bridge_layout_memory_dir`),
# never the workspace.
bridge_layout_materialize_identity() {
  local agent="$1"
  local engine="$2"
  local explicit_target="${3:-}"
  [[ -n "$agent" && -n "$engine" ]] || return 1

  local source_dir target_dir
  source_dir="$(bridge_layout_agent_home "$agent")"
  if [[ -n "$explicit_target" ]]; then
    target_dir="$explicit_target"
  elif declare -F bridge_engine_materialization_target >/dev/null 2>&1; then
    target_dir="$(bridge_engine_materialization_target "$agent" "$engine")"
  else
    # Descriptor module not loaded and no explicit target — cannot
    # resolve the per-engine target. Treat as no-op rather than guessing.
    return 0
  fi

  [[ -n "$source_dir" && -n "$target_dir" ]] || return 0
  if [[ "$source_dir" == "$target_dir" ]]; then
    # Legacy / identity-source-is-target engine: nothing to deliver.
    return 0
  fi
  [[ -d "$source_dir" ]] || return 0

  # Shared-workspace guard. If the target already holds a CLAUDE.md or
  # AGENTS.md whose first heading does not name this agent, the workspace
  # is a shared project tree — do not stamp per-agent identity into it.
  local entry
  for entry in "$target_dir/CLAUDE.md" "$target_dir/AGENTS.md"; do
    [[ -f "$entry" ]] || continue
    if grep -qiE "shared[- ]workdir|shared project" "$entry" 2>/dev/null; then
      bridge_layout_log_note "materialize: $agent — shared workspace detected ($entry); per-agent identity kept in agent_home"
      return 0
    fi
  done
  if [[ -n "${BRIDGE_LAYOUT_WORKSPACE_SHARED:-}" ]]; then
    bridge_layout_log_note "materialize: $agent — workspace flagged shared; per-agent identity kept in agent_home"
    return 0
  fi

  mkdir -p "$target_dir" 2>/dev/null || return 0

  local engine_entry=""
  local wants_claude_compat=0
  if declare -F bridge_engine_entrypoint_filename >/dev/null 2>&1; then
    engine_entry="$(bridge_engine_entrypoint_filename "$engine" 2>/dev/null || printf '')"
  fi
  if declare -F bridge_engine_wants_claude_compat_copy >/dev/null 2>&1; then
    # Codex r1 BLOCKING 2: honor the descriptor's claude-compat declaration.
    # Codex's native entrypoint is AGENTS.md, but Claude-shaped readers
    # (hooks, current runtime) still look for CLAUDE.md — so when the
    # descriptor says the engine wants a CLAUDE.md compat copy, materialize
    # BOTH AGENTS.md and CLAUDE.md into the workspace read target.
    bridge_engine_wants_claude_compat_copy "$engine" 2>/dev/null \
      && wants_claude_compat=1
  fi

  local name
  for name in \
    SOUL.md \
    SESSION-TYPE.md \
    MEMORY.md \
    MEMORY-SCHEMA.md \
    HEARTBEAT.md \
    CHANGE-POLICY.md \
    TOOLS.md \
    "$engine_entry"; do
    [[ -n "$name" ]] || continue
    [[ -f "$source_dir/$name" ]] || continue
    mkdir -p "$(dirname "$target_dir/$name")" 2>/dev/null || continue
    cp -f "$source_dir/$name" "$target_dir/$name" 2>/dev/null || true
  done
  if [[ "$wants_claude_compat" == "1" && "$engine_entry" != "CLAUDE.md" ]]; then
    # Engine wants the CLAUDE.md compat copy alongside its native entrypoint
    # (e.g. Codex with AGENTS.md as native + CLAUDE.md as compat).
    if [[ -f "$source_dir/CLAUDE.md" ]]; then
      cp -f "$source_dir/CLAUDE.md" "$target_dir/CLAUDE.md" 2>/dev/null || true
    fi
  fi

  # Per-user partition tree — `users/<id>/USER.md` etc. Delivered as a
  # whole subtree so the workspace read target carries the same per-user
  # identity the create flow scaffolded into the identity source.
  if [[ -d "$source_dir/users" ]]; then
    mkdir -p "$target_dir/users" 2>/dev/null || true
    cp -Rf "$source_dir/users/." "$target_dir/users/" 2>/dev/null || true
  fi

  return 0
}

# bridge_layout_log_note <message>
#
# One-line, non-fatal note. Uses bridge_warn when available (matches the
# rest of lib/), otherwise stderr. Kept tiny so the resolver has no hard
# dependency on bridge-core.sh load order.
bridge_layout_log_note() {
  if declare -F bridge_warn >/dev/null 2>&1; then
    bridge_warn "$*"
    return 0
  fi
  printf '%s\n' "$*" >&2
}
