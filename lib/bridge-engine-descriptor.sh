#!/usr/bin/env bash
# shellcheck shell=bash
#
# bridge-engine-descriptor.sh — minimal declarative per-engine descriptor
# (issue #1060; consumed later by #1067 CODEX-PROV and #1068 HOOKS-SSOT).
#
# This is the SOLE source for per-engine branching of the small set of
# layout / hook / materialization facts the beta6 tracks need. It is NOT
# the full #1013 engine capability-table refactor — it is intentionally
# minimal: only the fields #1060 / #1067 / #1068 consume, exposed as
# plain accessor functions so a later wave can extend it without a
# rewrite.
#
# Supported engines: `claude`, `codex`, `antigravity`.
#
# Descriptor fields (one accessor each):
#   * instruction entrypoint filename — the engine's primary instruction
#     file. claude → CLAUDE.md; codex → AGENTS.md; antigravity → CLAUDE.md
#     (current behavior preserved).
#   * claude-compat copy — whether the engine also wants a CLAUDE.md copy
#     for a reader that still expects it. codex → yes (some bridge
#     readers still look for CLAUDE.md); others → no.
#   * hook config path — per-agent location of the engine's hook config.
#     claude → per-agent `.claude/settings.json` under the workspace;
#     codex → per-agent `.codex/hooks.json` under the agent home.
#   * hook renderer profile — which renderer profile applies (claude /
#     codex / none).
#   * render-and-verify-on-create — whether `agent create` / upgrade
#     must render + verify the engine's hooks.
#   * identity materialization target — where the engine runtime reads
#     identity from; the destination of bridge_layout_materialize_identity.

# bridge_engine_is_supported <engine>
bridge_engine_is_supported() {
  case "${1:-}" in
    claude|codex|antigravity) return 0 ;;
    *) return 1 ;;
  esac
}

# bridge_engine_binary_name <engine>
#
# Engine → CLI binary name. The engine identifier in the descriptor
# (used by `bridge_agent_engine`, the roster, and the layout helpers)
# is not always the same string as the binary the host PATH resolves.
# Today the asymmetry is `antigravity`, which ships its CLI under
# `agy`; tomorrow more engines may diverge the same way. All callers
# that need to PATH-check or exec an engine binary should route
# through this helper rather than assuming engine-name == binary-name.
#
# Prints the binary name on stdout and returns 0 for known engines;
# prints nothing and returns 1 for unknown engines so callers can
# fall back to legacy bare-engine-name behavior (the current
# autostart gate does exactly that — see bridge-daemon.sh).
bridge_engine_binary_name() {
  local engine="${1:-}"
  case "$engine" in
    claude) printf 'claude' ;;
    codex) printf 'codex' ;;
    antigravity) printf 'agy' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_entrypoint_filename <engine>
#
# The engine's primary instruction-file name.
bridge_engine_entrypoint_filename() {
  case "${1:-}" in
    codex) printf 'AGENTS.md' ;;
    claude|antigravity) printf 'CLAUDE.md' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_wants_claude_compat_copy <engine>
#
# True when the engine's materialization should also drop a CLAUDE.md
# claude-compat copy alongside its native entrypoint, because a bridge
# reader still expects CLAUDE.md. Codex is the case: its native
# entrypoint is AGENTS.md, but several bridge readers (setup / skills /
# doctor) still probe CLAUDE.md.
bridge_engine_wants_claude_compat_copy() {
  case "${1:-}" in
    codex) return 0 ;;
    *) return 1 ;;
  esac
}

# bridge_engine_hook_config_path <agent> <engine>
#
# The per-agent location of the engine's hook config.
#   claude → `<workspace>/.claude/settings.json`
#   codex  → `<agent_home>/.codex/hooks.json` (per-agent target; the
#            legacy `$HOME/.codex/hooks.json` install-wide path in
#            bridge-hooks.sh is what HOOKS-SSOT #1068 migrates away from
#            — the descriptor names the per-agent destination now so
#            #1068 has a single source to consume).
bridge_engine_hook_config_path() {
  local agent="$1"
  local engine="$2"
  [[ -n "$agent" && -n "$engine" ]] || return 1
  case "$engine" in
    claude|antigravity)
      if declare -F bridge_layout_workspace_dir >/dev/null 2>&1; then
        printf '%s/.claude/settings.json' "$(bridge_layout_workspace_dir "$agent")"
        return 0
      fi
      return 1
      ;;
    codex)
      if declare -F bridge_layout_agent_home >/dev/null 2>&1; then
        printf '%s/.codex/hooks.json' "$(bridge_layout_agent_home "$agent")"
        return 0
      fi
      return 1
      ;;
    *)
      return 1
      ;;
  esac
}

# bridge_engine_hook_renderer_profile <engine>
#
# Which hook renderer profile applies. HOOKS-SSOT (#1068) consumes this
# to drive a single render dispatch instead of per-engine if-branches.
bridge_engine_hook_renderer_profile() {
  case "${1:-}" in
    claude|antigravity) printf 'claude' ;;
    codex) printf 'codex' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_render_hooks_on_create <engine>
#
# True when `agent create` / upgrade must render + verify the engine's
# hooks as part of provisioning.
bridge_engine_render_hooks_on_create() {
  case "${1:-}" in
    claude|codex|antigravity) return 0 ;;
    *) return 1 ;;
  esac
}

# bridge_engine_materialization_target <agent> <engine>
#
# Where the engine runtime reads identity from — the destination of
# `bridge_layout_materialize_identity`.
#
# For every currently-supported engine the runtime cwd / read target is
# the workspace dir (the runtime keeps reading where it reads today —
# see lib/bridge-agent-layout.sh "no reader flip"). The descriptor still
# owns the decision so #1067 / #1068 can specialize a per-engine target
# (e.g. a descriptor-owned Codex SessionStart surface) without touching
# the layout resolver.
bridge_engine_materialization_target() {
  local agent="$1"
  local engine="$2"
  [[ -n "$agent" && -n "$engine" ]] || return 1
  bridge_engine_is_supported "$engine" || return 1
  if declare -F bridge_layout_workspace_dir >/dev/null 2>&1; then
    bridge_layout_workspace_dir "$agent"
    return 0
  fi
  return 1
}
