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

# _bridge_layout_canon_dir <path>
#
# Print a best-effort canonical form of <path> for comparison. Falls back to
# the literal value when the directory cannot be canonicalized (e.g. an iso
# workdir the controller cannot traverse) so the caller compares like-for-like
# without a hard dependency on the path existing.
_bridge_layout_canon_dir() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  local canon=""
  canon="$(cd -P -- "$path" 2>/dev/null && pwd -P)" || canon=""
  if [[ -n "$canon" ]]; then
    printf '%s' "$canon"
  else
    printf '%s' "$path"
  fi
}

# bridge_layout_workspace_foreign_owned <agent> <target_dir>
#
# Issue #1750 — fail-safe shared-workspace guard for the WORKDIR identity
# delivery paths (materialize + sync-on-start). Returns 0 (TRUE — foreign /
# do-not-stamp) when <target_dir> is a workspace that is SHARED with at least
# one OTHER roster agent AND the identity already present there does NOT belong
# to <agent>. Returns 1 (FALSE — this agent may deliver its identity) otherwise.
#
# Why this exists, beyond the marker-text + BRIDGE_LAYOUT_WORKSPACE_SHARED env
# guards already in materialize/sync:
#
#   On a managed-project install the admin (e.g. `patch`, claude) is created
#   FIRST into its workdir, then its codex pair (`patch-dev`) is auto-provisioned
#   with `--workdir <admin-workdir> --allow-shared-workdir` (bridge-init-codex-
#   pair.sh). The create-time materialize is correctly suppressed for the pair
#   via BRIDGE_LAYOUT_WORKSPACE_SHARED=1, so home stays correct. But the
#   START-time sync (`bridge_layout_sync_identity_from_home`, bridge-start.sh)
#   carries NEITHER guard: the env flag is create-time-only, and the admin's
#   correct workdir CLAUDE.md (`# patch — …`) holds no "shared workdir" marker
#   text. So when the pair starts, the unguarded sync copies the PAIR's home
#   identity (SOUL/SESSION-TYPE/CLAUDE.md — codex / `Session Type: static-codex`)
#   over the ADMIN's workdir copies, and the runtime (which reads identity from
#   the workdir cwd) boots the admin as the codex pair. That is the #1750 drift
#   (home @10:45 correct, workdir @10:47 overwritten with the pair template).
#
# The reliable signal at start time — with no persisted shared-workdir flag —
# is the roster itself: another agent shares this workdir, AND the identity
# physically present in the workdir is NOT this agent's (it matches the other
# sharer, or simply differs from this agent's authored home copy). In that case
# this agent is a non-owning sharer (the pair) and MUST NOT stamp its identity
# over the owner's copy. Fail-safe: when in doubt (shared + foreign identity
# present) we DECLINE to write rather than fall back to the sibling/pair
# template — exactly the #1750 fail-safe contract.
#
# Ownership test (when the workdir IS shared with another agent):
#   * No identity present in the workdir yet  → not foreign (return 1): the
#     first writer legitimately materializes (the empty-workspace create case).
#   * Workdir identity is byte-identical to THIS agent's authored home copy
#     (SOUL.md or the engine entrypoint) → this agent owns it (return 1):
#     a legitimate #1417 HOME→WORKDIR refresh of the owner's own copy.
#   * Workdir identity differs from this agent's home copy → foreign owner
#     (return 0): decline. The pair hits this branch because the workdir holds
#     the admin's SOUL/CLAUDE.md, which differ from the pair's home copies.
#
# Roster-free / single-agent installs (no other agent shares the workdir) always
# return 1 — this guard changes nothing for the common case, only for the
# admin+pair shared-workdir topology that produced #1750.
bridge_layout_workspace_foreign_owned() {
  local agent="$1" target_dir="$2"
  [[ -n "$agent" && -n "$target_dir" ]] || return 1

  # Test-only teeth hatch (#1750 smoke): when set, the guard short-circuits to
  # "not foreign" so the smoke can reproduce the pre-fix divergence WITHOUT
  # editing source. Never set in production; the var is undocumented operator
  # surface and defaults off.
  [[ -n "${BRIDGE_LAYOUT_DISABLE_FOREIGN_GUARD_1750:-}" ]] && return 1

  # Cannot enumerate the roster → cannot prove a shared workspace; do not block.
  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 1
  declare -F bridge_agent_workdir >/dev/null 2>&1 || return 1

  local target_canon
  target_canon="$(_bridge_layout_canon_dir "$target_dir")"

  # Is this workdir shared with at least one OTHER roster agent?
  local other shared=0 other_wd other_canon
  for other in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$other" ]] || continue
    [[ "$other" == "$agent" ]] && continue
    other_wd="$(bridge_agent_workdir "$other" 2>/dev/null || true)"
    [[ -n "$other_wd" ]] || continue
    other_canon="$(_bridge_layout_canon_dir "$other_wd")"
    if [[ "$other_canon" == "$target_canon" ]]; then
      shared=1
      break
    fi
  done
  # Not shared with anyone else → ordinary managed-project workdir; allow.
  (( shared == 1 )) || return 1

  # Shared workspace. Decide ownership by comparing the identity physically
  # present in the workdir against THIS agent's authored home copy. The engine
  # entrypoint and SOUL.md both embed the agent identity; either match proves
  # ownership.
  local source_dir
  source_dir="$(bridge_layout_agent_home "$agent" 2>/dev/null || true)"

  local engine_entry=""
  if declare -F bridge_engine_entrypoint_filename >/dev/null 2>&1; then
    # The sync/materialize callers know the engine; resolve a best-effort
    # entrypoint for the ownership probe. CLAUDE.md is the universal fallback.
    engine_entry="$(bridge_engine_entrypoint_filename "${BRIDGE_LAYOUT_FOREIGN_PROBE_ENGINE:-claude}" 2>/dev/null || printf '')"
  fi
  [[ -n "$engine_entry" ]] || engine_entry="CLAUDE.md"

  local probe present_any=0 name
  for name in SOUL.md "$engine_entry" CLAUDE.md; do
    [[ -n "$name" ]] || continue
    probe="$target_dir/$name"
    [[ -f "$probe" ]] || continue
    present_any=1
    # Workdir copy matches THIS agent's authored home copy → this agent owns it.
    if [[ -n "$source_dir" && -f "$source_dir/$name" ]] \
        && cmp -s -- "$source_dir/$name" "$probe" 2>/dev/null; then
      return 1
    fi
  done

  # Shared workspace with NO identity present yet → first writer (owner) may
  # materialize; not foreign.
  (( present_any == 1 )) || return 1

  # Shared workspace, identity present, and it does NOT match this agent's
  # authored home copy → foreign-owned. Decline (fail-safe).
  return 0
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
  # Issue #1750 — defense in depth: even when the caller forgets to set
  # BRIDGE_LAYOUT_WORKSPACE_SHARED (the env flag is create-path-only), decline
  # to stamp this agent's identity over a workdir that is shared with another
  # roster agent and already holds that agent's identity. Keeps the pair's
  # codex template out of the admin's workdir regardless of the call site.
  if declare -F bridge_layout_workspace_foreign_owned >/dev/null 2>&1; then
    if BRIDGE_LAYOUT_FOREIGN_PROBE_ENGINE="$engine" \
        bridge_layout_workspace_foreign_owned "$agent" "$target_dir"; then
      bridge_layout_log_note "materialize: $agent — shared workspace owned by another agent ($target_dir); per-agent identity kept in agent_home (#1750)"
      return 0
    fi
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

  # Issue #1332 L2 (v0.14.5-beta5-2 Lane ξ): atomic per-file
  # write-then-normalize for the iso v2 layout. The controller-side
  # ``cp -f`` below writes each file as controller-owned mode 0600 — the
  # iso UID cannot read controller-owned 0600 files, so any concurrent
  # iso-side reader observing the gap between the cp and the bulk
  # post-materialize normalize (caller invokes
  # ``bridge_isolation_v2_normalize_workdir_profile_group`` at
  # bridge-agent.sh:3419) sees ``Permission denied``. The bulk
  # normalize remains as a final safety net for failure paths and for
  # the upgrade-time backfill loop in
  # ``lib/bridge-isolation-v2-workdir-backfill.sh``, but pulling the
  # per-file chgrp+chmod into the cp loop itself closes the per-file
  # race window — each materialized file lands at ``iso-uid:ab-agent-<a>
  # 0660`` before the loop advances to the next entry.
  #
  # Contract preserved: the chgrp helper
  # (``bridge_isolation_v2_chgrp_file_iso_group``) is itself idempotent
  # (stat-skip on already-correct ``%G:%a``), non-fatal on failure
  # (returns nonzero but does not bridge_die), and a no-op outside of
  # Linux iso v2 (gates on ``bridge_isolation_v2_enforce``). Legacy
  # shared-mode + macOS callers see zero behavioral change because the
  # helper short-circuits to 0 without touching the file.
  #
  # declare -F probe keeps the agent-layout layer loosely coupled to the
  # isolation-v2 module — when the helper is not loaded (e.g. older
  # bridge-lib.sh source order, or a future repackaging where layout
  # ships standalone) the per-file normalize is skipped and the caller's
  # bulk normalize alone keeps the invariant.
  local _ml_can_per_file_normalize=0
  if declare -F bridge_isolation_v2_chgrp_file_iso_group >/dev/null 2>&1; then
    _ml_can_per_file_normalize=1
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
    if (( _ml_can_per_file_normalize == 1 )) && [[ -f "$target_dir/$name" ]]; then
      # Atomic per-file: chgrp+chmod immediately after cp so the file is
      # group-readable to the iso UID before the next loop iteration.
      # 4th arg = $target_dir engages the ancestor symlink walk +
      # canonical containment check (PR #1335 r3, codex r2 BLOCKING).
      bridge_isolation_v2_chgrp_file_iso_group \
        "$agent" "$target_dir/$name" 0660 "$target_dir" \
        >/dev/null 2>&1 || true
    fi
  done
  if [[ "$wants_claude_compat" == "1" && "$engine_entry" != "CLAUDE.md" ]]; then
    # Engine wants the CLAUDE.md compat copy alongside its native entrypoint
    # (e.g. Codex with AGENTS.md as native + CLAUDE.md as compat).
    if [[ -f "$source_dir/CLAUDE.md" ]]; then
      cp -f "$source_dir/CLAUDE.md" "$target_dir/CLAUDE.md" 2>/dev/null || true
      if (( _ml_can_per_file_normalize == 1 )) && [[ -f "$target_dir/CLAUDE.md" ]]; then
        # Same per-file atomic normalize as the main loop above (#1332 L2).
        bridge_isolation_v2_chgrp_file_iso_group \
          "$agent" "$target_dir/CLAUDE.md" 0660 "$target_dir" \
          >/dev/null 2>&1 || true
      fi
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

# The canonical identity files the sync-on-start reconciliation considers.
# Deliberately the AUTHORED identity surface only — the same set the
# materialize loop copies (SOUL/SESSION-TYPE/MEMORY*/HEARTBEAT/…) PLUS the
# engine entrypoint resolved at call time. NOT included, on purpose:
#   * `.claude/` — workspace-scoped engine/hook state wired directly into
#     the target by the create + start flows, never bulk-synced.
#   * `memory/` — resolver-rooted at the identity source
#     (`bridge_layout_memory_dir`), the agent's own append-only store.
#   * session.lock / `*.result.json` / watchdog runtime state — these are
#     deliberately workdir-anchored runtime artifacts (#1108/#1109). The
#     sync MUST NOT touch them; scoping to this explicit list is the guard.
BRIDGE_LAYOUT_IDENTITY_SYNC_FILES=(
  SOUL.md
  SESSION-TYPE.md
  MEMORY.md
  MEMORY-SCHEMA.md
  HEARTBEAT.md
  CHANGE-POLICY.md
  TOOLS.md
)

# _bridge_layout_file_mtime <path>
#
# Print the integer mtime (epoch seconds) of <path>, or empty on failure.
# Handles both GNU (`stat -c`) and BSD/macOS (`stat -f`) stat. Used by the
# sync guard to decide direction without clobbering a newer workdir copy.
_bridge_layout_file_mtime() {
  local path="$1"
  [[ -n "$path" ]] || return 1
  local mt=""
  mt="$(stat -c '%Y' -- "$path" 2>/dev/null)" \
    || mt="$(stat -f '%m' -- "$path" 2>/dev/null)" \
    || mt=""
  [[ "$mt" =~ ^[0-9]+$ ]] || { printf ''; return 1; }
  printf '%s' "$mt"
}

# _bridge_layout_sha256 <path>
#
# Print the sha256 hex of <path> using whichever tool is present, or empty.
_bridge_layout_sha256() {
  local path="$1"
  [[ -f "$path" ]] || return 1
  if command -v sha256sum >/dev/null 2>&1; then
    sha256sum -- "$path" 2>/dev/null | awk '{print $1}'
  elif command -v shasum >/dev/null 2>&1; then
    shasum -a 256 -- "$path" 2>/dev/null | awk '{print $1}'
  else
    return 1
  fi
}

# bridge_layout_sync_identity_from_home <agent> <engine> [target_dir]
#
# Issue #1417 — sync-on-start reconciliation of the WORKDIR identity copy
# FROM the HOME identity source (the authored SSOT). `agent create` runs
# `bridge_layout_materialize_identity` once; a later hand-edit of the HOME
# copy never reaches the workdir copy the runtime reads workdir-first
# (`bridge_agent_onboarding_state`), so the two drift and the HOME edit
# silently has no runtime effect. This helper closes the drift on every
# start WITHOUT flipping the workdir-first read order #1416 pinned.
#
# It is intentionally NOT the same as materialize, which unconditionally
# `cp -f`-overwrites every target file (correct at create, wrong on start —
# it would stomp a deliberate workdir runtime value, e.g. the agent
# updating its own onboarding line mid-session). The contract here:
#
#   * Identity files ONLY (`BRIDGE_LAYOUT_IDENTITY_SYNC_FILES` + the engine
#     entrypoint). Never `.claude/`, `memory/`, session.lock, `*.result.json`
#     or any workdir-anchored watchdog state (#1108/#1109).
#   * Copy a file HOME→WORKDIR only when (a) the two copies DIFFER in
#     content AND (b) the HOME copy is the newer one (mtime strictly newer
#     than the workdir copy). If the workdir copy is the newer one, the
#     agent/runtime wrote it deliberately → we leave it alone. This is the
#     "don't stomp a deliberate workdir runtime value" guard.
#   * Fail-CLOSED + non-fatal: any read/compare/copy uncertainty (e.g. an
#     iso UID workdir the controller cannot read with no probe available)
#     is skipped with at most a note; it NEVER bridge_die's the start path.
#   * No-op when source == target (legacy / shared-mode home == workdir),
#     or for a shared project workspace (same guard as materialize).
#   * iso v2 stays controller-published: copies route through the same
#     sudo-as-iso write helper the create-time materialize / upgrade
#     backfill use, then chgrp+chmod to `ab-agent-<a> 0660`.
bridge_layout_sync_identity_from_home() {
  local agent="$1"
  local engine="$2"
  local explicit_target="${3:-}"
  [[ -n "$agent" && -n "$engine" ]] || return 0

  local source_dir target_dir
  source_dir="$(bridge_layout_agent_home "$agent")"
  if [[ -n "$explicit_target" ]]; then
    target_dir="$explicit_target"
  elif declare -F bridge_engine_materialization_target >/dev/null 2>&1; then
    target_dir="$(bridge_engine_materialization_target "$agent" "$engine")"
  else
    return 0
  fi

  [[ -n "$source_dir" && -n "$target_dir" ]] || return 0
  # Shared-mode / identity-source-is-target: single physical copy, nothing
  # can drift — the bug is structurally absent (issue scope note).
  [[ "$source_dir" == "$target_dir" ]] && return 0
  [[ -d "$source_dir" ]] || return 0

  # Shared-workspace guard — identical to materialize: do not stamp
  # per-agent identity into a shared project tree.
  local entry
  for entry in "$target_dir/CLAUDE.md" "$target_dir/AGENTS.md"; do
    [[ -f "$entry" ]] || continue
    if grep -qiE "shared[- ]workdir|shared project" "$entry" 2>/dev/null; then
      return 0
    fi
  done
  [[ -n "${BRIDGE_LAYOUT_WORKSPACE_SHARED:-}" ]] && return 0

  # Issue #1750 — fail-safe roster-aware shared-workspace guard. The two guards
  # above are create-time signals: the marker text appears only in a project
  # tree that explicitly declares itself shared, and BRIDGE_LAYOUT_WORKSPACE_
  # SHARED is set only by the `agent create --allow-shared-workdir` path. The
  # START path (this function) carries neither. On a managed-project admin+pair
  # install the admin's correct workdir CLAUDE.md (`# patch — …`) holds no
  # marker text and the env flag is unset, so without this guard the pair's
  # start-time sync stamps the PAIR (codex / `Session Type: static-codex`)
  # identity over the ADMIN's workdir copies — the exact #1750 drift. Decline
  # when the workdir is shared with another roster agent and the identity there
  # is not this agent's (fail-safe: never stamp a sibling/pair template over the
  # owner's copy).
  if declare -F bridge_layout_workspace_foreign_owned >/dev/null 2>&1; then
    if BRIDGE_LAYOUT_FOREIGN_PROBE_ENGINE="$engine" \
        bridge_layout_workspace_foreign_owned "$agent" "$target_dir"; then
      bridge_layout_log_note "sync-identity: $agent — shared workspace owned by another agent ($target_dir); per-agent identity kept in agent_home (#1750)"
      return 0
    fi
  fi

  # Resolve the engine entrypoint + claude-compat copy the same way
  # materialize does, so the synced fileset matches the create-time set.
  local engine_entry=""
  local wants_claude_compat=0
  if declare -F bridge_engine_entrypoint_filename >/dev/null 2>&1; then
    engine_entry="$(bridge_engine_entrypoint_filename "$engine" 2>/dev/null || printf '')"
  fi
  if declare -F bridge_engine_wants_claude_compat_copy >/dev/null 2>&1; then
    bridge_engine_wants_claude_compat_copy "$engine" 2>/dev/null \
      && wants_claude_compat=1
  fi

  # iso v2: is the agent linux-user isolated AND does the controller need
  # the sudo-as-iso write path? Probe once.
  local _iso_effective=0
  if declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then
    bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      && _iso_effective=1
  fi
  local _can_iso_write=0
  if (( _iso_effective == 1 )) \
      && declare -F bridge_isolation_write_file_as_agent_user_via_bash >/dev/null 2>&1; then
    _can_iso_write=1
  fi
  local _can_per_file_normalize=0
  if declare -F bridge_isolation_v2_chgrp_file_iso_group >/dev/null 2>&1; then
    _can_per_file_normalize=1
  fi

  local -a sync_names=("${BRIDGE_LAYOUT_IDENTITY_SYNC_FILES[@]}")
  [[ -n "$engine_entry" ]] && sync_names+=("$engine_entry")
  if [[ "$wants_claude_compat" == "1" && "$engine_entry" != "CLAUDE.md" ]]; then
    sync_names+=("CLAUDE.md")
  fi

  local name src dst synced=0
  for name in "${sync_names[@]}"; do
    [[ -n "$name" ]] || continue
    src="$source_dir/$name"
    dst="$target_dir/$name"
    # HOME (source) is the authored SSOT — if it has no copy of this file
    # there is nothing to propagate. We never DELETE a workdir copy.
    [[ -f "$src" ]] || continue
    if _bridge_layout_sync_one_identity_file \
        "$agent" "$src" "$dst" "$target_dir" \
        "$_iso_effective" "$_can_iso_write" "$_can_per_file_normalize"; then
      synced=$((synced + 1))
    fi
  done

  if (( synced > 0 )); then
    bridge_layout_log_note "sync-identity: $agent — propagated $synced HOME identity edit(s) to workdir copy"
  fi
  return 0
}

# _bridge_layout_sync_one_identity_file <agent> <src> <dst> <target_dir>
#                                       <iso_effective> <can_iso_write>
#                                       <can_per_file_normalize>
#
# Reconcile one identity file HOME(src)→WORKDIR(dst), honoring the
# differ-AND-home-is-newer guard. Returns 0 ONLY when it actually wrote
# the workdir copy; returns 1 (non-fatal) when it skipped (identical,
# workdir newer, or fail-closed unreadable). Never bridge_die's.
_bridge_layout_sync_one_identity_file() {
  local agent="$1" src="$2" dst="$3" target_dir="$4"
  local iso_effective="$5" can_iso_write="$6" can_per_file_normalize="$7"

  # --- read the current workdir copy + decide whether to overwrite -------
  #
  # On an iso v2 agent the controller is NOT in `ab-agent-<a>` and cannot
  # traverse the 0750/2770 workdir parent, so a controller-side `[[ -e ]]` /
  # `[[ -r ]]` on $dst FALSE-NEGATES even when the file exists (codex r1
  # BLOCKING 1: trusting that false negative jumped straight to the "absent
  # → safe to write" path and blind-overwrote a possibly-newer workdir
  # value). So: when iso is effective, route the entire existence + differ +
  # mtime decision through the iso UID, which CAN read its own workdir. The
  # probe's inner script handles the genuinely-absent case (`[[ -e ]] ||
  # exit 0`, "safe to write") AND the differ+home-newer guard. Anything but
  # a confirmed HOME-newer-differ (or absent) fails closed.
  if (( iso_effective == 1 )); then
    if declare -F bridge_isolation_run_as_agent_user_via_bash >/dev/null 2>&1; then
      if ! _bridge_layout_iso_dst_differs_and_older "$agent" "$src" "$dst"; then
        # iso UID says identical, workdir-newer, or unverifiable → skip.
        return 1
      fi
      # iso UID confirmed absent OR HOME-newer differ → propagate below.
    else
      # iso agent but no probe available → cannot establish direction with
      # confidence, and the controller's own `[[ -e ]]` is unreliable here.
      # Fail closed (never blind-overwrite an iso workdir copy).
      return 1
    fi
  else
    # Non-isolated (shared mode / macOS / single-OS-user): the controller
    # CAN stat + read the workdir copy directly.
    if [[ -e "$dst" ]]; then
      if [[ ! -r "$dst" ]]; then
        # Exists but unreadable to the controller, and not an iso agent we
        # can probe → fail closed rather than blind-overwrite.
        return 1
      fi
      # Identical content → nothing to do (the common steady-state).
      if cmp -s -- "$src" "$dst" 2>/dev/null; then
        return 1
      fi
      # Differ. Direction guard: only overwrite when HOME is the NEWER
      # copy. A strictly-newer workdir copy is a deliberate runtime write
      # (the agent edited its own onboarding line / memory mid-session) —
      # leave it untouched so we never stomp it (#1108/#1109 anchor).
      local src_mt dst_mt
      src_mt="$(_bridge_layout_file_mtime "$src" 2>/dev/null || true)"
      dst_mt="$(_bridge_layout_file_mtime "$dst" 2>/dev/null || true)"
      if [[ -z "$src_mt" || -z "$dst_mt" ]]; then
        # Could not establish direction with confidence → fail-closed,
        # do not overwrite a workdir copy on an ambiguous mtime read.
        return 1
      fi
      if (( src_mt <= dst_mt )); then
        # Workdir copy is same-age-or-newer than HOME → do not clobber.
        return 1
      fi
      # HOME is strictly newer → propagate below.
    fi
    # Destination absent (non-iso) → safe to materialize (no runtime value).
  fi

  # --- write the workdir copy -------------------------------------------
  #
  # iso v2 (effective) and non-iso are split into two strictly-separate write
  # paths — they must NEVER cross. (codex r2 BLOCKING 1+2.)
  if (( iso_effective == 1 )); then
    # ISO PATH — controller-published ONLY.
    #
    # BLOCKING 1: do NOT `mkdir -p "$(dirname "$dst")"` here. The controller
    # is not in `ab-agent-<a>` and cannot traverse the 0750/2770 workdir
    # parent, so a controller-side mkdir would fail with `Permission denied`
    # and abort the propagation for exactly the iso agents #1417 targets.
    # The workdir leaf always exists at start (bridge-start.sh guarantees
    # WORK_DIR_PRESENT), and `bridge_isolation_write_file_as_agent_user_via_bash`
    # itself validates the dest dir + writes atomically AS the iso UID.
    #
    # BLOCKING 2: once iso is effective the ONLY acceptable outcomes are
    # "published via the helper" or "fail loud" — NEVER a controller `cp -f`
    # into the iso workdir (that drops a controller-owned file across the
    # boundary). A helper rc=1 ("predicate says not actually isolated") is
    # NOT proof a controller write is safe, so we fail closed on it too
    # (mirrors `agent set-onboarding`, which dies on an unexpected rc).
    if (( can_iso_write == 0 )); then
      # iso effective but the sudo-as-iso writer is unavailable → cannot
      # publish, and a controller write is forbidden → fail closed.
      return 1
    fi
    local _wrc=0
    bridge_isolation_write_file_as_agent_user_via_bash \
      "$agent" "$dst" "0660" < "$src" >/dev/null 2>&1 || _wrc=$?
    if (( _wrc == 0 )); then
      if (( can_per_file_normalize == 1 )); then
        bridge_isolation_v2_chgrp_file_iso_group \
          "$agent" "$dst" 0660 "$target_dir" >/dev/null 2>&1 || true
      fi
      return 0
    fi
    # Any nonzero helper rc (sudo unavailable, predicate disagreement, IO
    # error) → fail closed. Never fall through to a controller write.
    return 1
  fi

  # NON-ISO PATH — controller can write directly (shared mode / macOS /
  # single-OS-user). The differ guard above already ensured we only reach
  # here when HOME is the authoritative newer copy (or the dst is absent).
  mkdir -p "$(dirname "$dst")" 2>/dev/null || return 1
  cp -f -- "$src" "$dst" 2>/dev/null || return 1
  return 0
}

# _bridge_layout_iso_dst_differs_and_older <agent> <src> <dst>
#
# iso-UID-routed variant of the differ-AND-home-is-newer guard, for the
# case where the controller cannot read the iso-owned workdir copy. Hashes
# the HOME copy controller-side and passes the hash + mtime to a tiny
# script run AS the iso UID, which hashes/stats the workdir copy it CAN
# read and compares. Returns 0 ONLY when the iso UID confirms the workdir
# copy is absent OR (differs AND is older than HOME) → safe to overwrite;
# returns 1 on identical / workdir-newer / any unverifiable state
# (fail-closed). Never bridge_die's.
_bridge_layout_iso_dst_differs_and_older() {
  local agent="$1" src="$2" dst="$3"
  local src_mt src_hash
  src_mt="$(_bridge_layout_file_mtime "$src" 2>/dev/null || true)"
  [[ -n "$src_mt" ]] || return 1
  src_hash="$(_bridge_layout_sha256 "$src" 2>/dev/null || true)"
  [[ -n "$src_hash" ]] || return 1
  local rc=0
  # shellcheck disable=SC2016  # single-quoted on purpose: $1/$2/$3 are args
  bridge_isolation_run_as_agent_user_via_bash "$agent" '
dst="$1"; src_hash="$2"; src_mt="$3"
[[ -e "$dst" ]] || exit 0   # absent → safe to write (no runtime value)
[[ -r "$dst" ]] || exit 2   # iso UID cannot read either → unverifiable
dst_hash=""
if command -v sha256sum >/dev/null 2>&1; then
  dst_hash="$(sha256sum -- "$dst" 2>/dev/null | awk "{print \$1}")"
elif command -v shasum >/dev/null 2>&1; then
  dst_hash="$(shasum -a 256 -- "$dst" 2>/dev/null | awk "{print \$1}")"
else
  exit 2
fi
[[ -n "$dst_hash" ]] || exit 2
[[ "$dst_hash" == "$src_hash" ]] && exit 1   # identical → no-op
dst_mt="$(stat -c "%Y" -- "$dst" 2>/dev/null || stat -f "%m" -- "$dst" 2>/dev/null || printf "")"
[[ "$dst_mt" =~ ^[0-9]+$ ]] || exit 2        # cannot establish direction
if (( src_mt <= dst_mt )); then exit 1; fi   # workdir same-age-or-newer → keep
exit 0                                        # HOME strictly newer + differs
' "$dst" "$src_hash" "$src_mt" >/dev/null 2>&1 || rc=$?
  # The helper shifts the inner script rc into a higher band on the sudo
  # path; only an unambiguous rc 0 (inner exit 0, "safe to write") is
  # honored. Everything else (identical, workdir-newer, unverifiable, or a
  # shifted band) fails closed.
  [[ $rc -eq 0 ]]
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
