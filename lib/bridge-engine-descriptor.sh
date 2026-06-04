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

# ─────────────────────────────────────────────────────────────────────
# Fleet-credential auth seam (L0 → L1, #1470 Phase 1)
#
# These accessors are the engine-auth descriptor: the single source for
# per-engine branching of credential operations so `bridge-auth.sh` /
# `bridge-auth.py` dispatch BY ENGINE instead of hardcoding Claude.
#
# Phase 1 is a behavior-preserving refactor — every Claude value below
# is exactly what the auth stack already hardcodes today (the
# `claudeAiOauth` payload key, the `claude-oauth-tokens.json` registry,
# the `.claude/.credentials.json` dest, the native-oauth usage probe,
# rotation-supported). Codex/Gemini get descriptor slots only; the
# adapters that fill them (`register`/`sync`/`verify` for Codex) are
# Phase 2. Any engine that is not credential-managed answers
# `auth_supported = no` so callers degrade cleanly rather than error.
#
# The accessors are pure case-tables (no external deps) so they can be
# sourced and called from a bare subshell exactly like the layout/hook
# accessors above. They never touch the network or the filesystem.

# bridge_engine_auth_supported <engine>
#
# Whether the bridge centrally manages this engine's credential. claude
# (rotating OAT pool + controller-fallback) and codex (single-source
# auth.json fleet-sync, Phase 2) are managed; antigravity has no stable
# auth contract yet (deferred). Returns 0 (supported) / 1 (unsupported
# or unknown engine).
bridge_engine_auth_supported() {
  case "${1:-}" in
    claude|codex) return 0 ;;
    antigravity) return 1 ;;
    *) return 1 ;;
  esac
}

# bridge_engine_auth_model <engine>
#
# The credential-management model for the engine, on stdout:
#   claude       → rotating-pool      (multi-token registry, one active)
#   codex        → single-source-sync (one source auth.json fanned out)
#   antigravity  → none
# Returns 1 for unknown engines (prints nothing).
bridge_engine_auth_model() {
  case "${1:-}" in
    claude) printf 'rotating-pool' ;;
    codex) printf 'single-source-sync' ;;
    antigravity) printf 'none' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_cred_dest_path <agent> <engine>
#
# The per-agent path the engine runtime reads its credential from,
# relative to the agent's home:
#   claude → <agent_home>/.claude/.credentials.json
#   codex  → <agent_home>/.codex/auth.json
# antigravity has no managed dest (returns 1).
#
# This is the *home-relative tail*; the auth stack resolves the agent's
# real (iso-aware) home separately via
# `bridge_auth_resolved_user_home_for_agent`. Keeping the tail in the
# descriptor means a future engine layout change lands here, not inline
# in the sync writer.
bridge_engine_cred_dest_path() {
  local agent="$1"
  local engine="$2"
  [[ -n "$agent" && -n "$engine" ]] || return 1
  case "$engine" in
    claude) printf '.claude/.credentials.json' ;;
    codex) printf '.codex/auth.json' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_cred_source <engine>
#
# Where the credential to fan out comes from, on stdout:
#   claude → registry            (the claude-oauth-tokens.json pool, with
#                                 controller-credentials fallback)
#   codex  → agent-source        (a designated source agent's auth.json;
#                                 the concrete binding is Phase 2 config,
#                                 NOT hardcoded here — Q1 resolution)
#   antigravity → none
# Returns 1 for unknown engines.
bridge_engine_cred_source() {
  case "${1:-}" in
    claude) printf 'registry' ;;
    codex) printf 'agent-source' ;;
    antigravity) printf 'none' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_supports_rotation <engine>
#
# Whether the engine supports multi-credential rotation/failover.
# claude:yes (the OAT pool). codex:no (single subscription login the
# binary self-refreshes — `rotate`/`recover`/`activate` are clean
# no-ops on the Codex adapter). antigravity:no. Returns 0/1.
bridge_engine_supports_rotation() {
  case "${1:-}" in
    claude) return 0 ;;
    codex|antigravity) return 1 ;;
    *) return 1 ;;
  esac
}

# bridge_engine_usage_source <engine>
#
# The usage/quota signal source the rotation policy keys on, on stdout:
#   claude → native-oauth-probe  (#1437/#1468 GET + 429 positive signal)
#   codex  → codex-snapshots     (observe-only; not actionable — there
#                                 is no rotation to drive)
#   antigravity → none
# Returns 1 for unknown engines.
bridge_engine_usage_source() {
  case "${1:-}" in
    claude) printf 'native-oauth-probe' ;;
    codex) printf 'codex-snapshots' ;;
    antigravity) printf 'none' ;;
    *) return 1 ;;
  esac
}

# bridge_engine_cred_payload_key <engine>
#
# The JSON object key the engine's credential file is keyed under, on
# stdout. For claude this is `claudeAiOauth` — the key that today lives
# inline in `claude_oauth_credentials_payload` / the controller-fallback
# read in bridge-auth.py. For codex the credential file is an
# opaque-copy (whole-file write-through, no key extraction) so this
# returns empty with rc=0 to signal "no payload key — copy verbatim".
# antigravity returns 1 (no managed credential).
bridge_engine_cred_payload_key() {
  case "${1:-}" in
    claude) printf 'claudeAiOauth' ;;
    codex) printf '' ;;
    antigravity) return 1 ;;
    *) return 1 ;;
  esac
}
