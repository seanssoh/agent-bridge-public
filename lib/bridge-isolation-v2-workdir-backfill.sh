#!/usr/bin/env bash
# shellcheck shell=bash
#
# bridge-isolation-v2-workdir-backfill.sh — issue #1113.
#
# Back-fill the canonical per-agent identity markers from the tracked
# profile tree (`$BRIDGE_HOME/agents/<agent>/`) into the v2 runtime
# workspace (`$BRIDGE_DATA_ROOT/agents/<agent>/workdir/`) for every
# roster-active agent whose workspace is missing those markers.
#
# Why this exists
# ---------------
# v0.14.5-beta6 / PR #1109 anchored `bridge-watchdog.py`'s per-agent
# scan on the v2 runtime workspace dir resolved via
# `bridge_agent_workdir`. That fix unblocks fresh-install agents
# (created post-#1108 via the normal `agent create` path, which
# materializes the identity markers into the workspace via
# `bridge_layout_materialize_identity`).
#
# Two upgrade vintages do NOT get the markers in the workspace:
#
#   1. agents scaffolded BEFORE #1108 landed (older installs) — their
#      identity files were authored only into the tracked profile tree
#      at `$BRIDGE_HOME/agents/<agent>/`; nothing was ever copied into
#      `$BRIDGE_DATA_ROOT/agents/<agent>/workdir/`.
#
#   2. agents migrated via the marker-only v2 fast-path
#      (`bridge_isolation_v2_migrate_apply_for_upgrade` →
#      `bridge_isolation_v2_migrate_marker_write_minimal`, PR #897
#      Track A, v0.13.10). That path writes the v2 layout marker but
#      intentionally does NOT replay the full mirror/rsync of legacy →
#      v2 directories, so identity markers stay in the tracked tree.
#
# Post-#1108 the watchdog now scans the workspace tree, sees no
# CLAUDE.md / SOUL.md / SESSION-TYPE.md / MEMORY-SCHEMA.md / MEMORY.md,
# and reports `status: error` + `missing_files: …` on every legacy
# agent on every cron tick. This back-fill closes that gap once, at
# upgrade time, by copying the markers from the tracked profile tree
# into the workspace.
#
# Contract
# --------
#   * Idempotent — safe to run repeatedly. We only copy a marker when
#     the workspace target is MISSING that exact file; pre-existing
#     workspace markers are left alone (the operator or the runtime
#     may have updated them post-migration; we never overwrite).
#   * Roster-active only — we enumerate `BRIDGE_AGENT_IDS` (populated
#     by `bridge_load_roster`). Agents that exist on disk but are not
#     in the roster (orphans) are NOT touched.
#   * No template re-render — we do NOT replay `scaffold_agent_home`,
#     hooks render, settings render. The only operation is a
#     content-preserving file copy.
#   * Respects v2 ownership — when the agent runs under linux-user
#     isolation and passwordless sudo is available, the workspace tree
#     is owned by `ab-agent-<slug>:ab-agent-<slug>` and the controller
#     UID cannot write into it directly. In that case we delegate to
#     `bridge_isolation_write_file_as_agent_user_via_bash`. For
#     non-isolated agents (shared mode, macOS, single-OS-user installs)
#     a controller-side `cp -p` is correct.
#   * Non-fatal — every failure is warned via `bridge_warn` but never
#     aborts the caller. The watchdog can still surface the residual
#     `missing_files` row on the next tick; the operator's workaround
#     (manual `cp`) keeps working.
#
# Safety notes
# ------------
#   * The markers we copy are the same set the watchdog asserts
#     (`bridge-watchdog.py:CLAUDE_REQUIRED_FILES`). Keeping these two
#     sets in lockstep is a regression vector — the smoke
#     `1113-watchdog-legacy-backfill.sh` asserts the watchdog status
#     against the back-fill output so a drift fails CI.
#   * We deliberately do NOT delete from the tracked tree. The tracked
#     tree is still the authoritative source for repeat upgrades and
#     for the migrator-export path; the workspace copy is the read
#     target the runtime / watchdog actually scans.
#   * Footgun #11 (Bash 5.3.9 heredoc deadlock class): this body uses
#     only `printf` / `cp` / direct redirection. No heredocs anywhere.
#     The isolated write path goes through
#     `bridge_isolation_write_file_as_agent_user_via_bash` which itself
#     uses `cat -` (also heredoc-free).

# Canonical identity files the watchdog requires (see
# bridge-watchdog.py:CLAUDE_REQUIRED_FILES). Kept as an array — not a
# string — so callers can iterate and so a drift between sets shows up
# as a structural diff in `git log` rather than a quoted-string blob.
BRIDGE_ISOLATION_V2_BACKFILL_IDENTITY_FILES=(
  CLAUDE.md
  SOUL.md
  SESSION-TYPE.md
  MEMORY-SCHEMA.md
  MEMORY.md
)

# bridge_isolation_v2_backfill_workdir_identity [--target-root <path>] [--json]
#
# Back-fill identity markers for every roster-active agent. Returns 0
# on best-effort completion (including all-no-op runs); returns 2 on
# pre-flight failure (e.g. resolver primitives unavailable).
#
# When `--json` is passed, emits a single-line JSON summary on stdout
# describing per-agent outcomes. The shape is:
#   {
#     "mode": "isolation-v2-workdir-backfill",
#     "status": "ok",
#     "agents_examined": N,
#     "agents_with_writes": M,
#     "markers_copied": K,
#     "agents": [
#       { "id": "...", "writes": ["CLAUDE.md", ...], "errors": [...] }
#     ]
#   }
#
# When `--target-root <path>` is passed, the resolver is pinned to that
# bridge-home root regardless of `$BRIDGE_HOME`. This is the shape the
# upgrade helper invokes — the target_root has already been resolved by
# `bridge_upgrade_with_target_env` so the env is consistent.
bridge_isolation_v2_backfill_workdir_identity() {
  local target_root=""
  local emit_json=0
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-root) target_root="$2"; shift 2 ;;
      --json) emit_json=1; shift ;;
      *)
        if declare -F bridge_warn >/dev/null 2>&1; then
          bridge_warn "backfill_workdir_identity: unknown arg: $1"
        else
          printf 'backfill_workdir_identity: unknown arg: %s\n' "$1" >&2
        fi
        return 2
        ;;
    esac
  done

  # The roster array must be loaded. Callers from bridge-upgrade.sh's
  # helper path (lib/upgrade-helpers/) explicitly source bridge-lib.sh
  # + call bridge_load_roster before invoking us; direct callers must
  # do the same. Guard rather than auto-loading so we never silently
  # operate on a wrong-home roster.
  if ! declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    if declare -F bridge_warn >/dev/null 2>&1; then
      bridge_warn "backfill_workdir_identity: BRIDGE_AGENT_IDS not loaded; caller must run bridge_load_roster first"
    else
      printf 'backfill_workdir_identity: BRIDGE_AGENT_IDS not loaded\n' >&2
    fi
    return 2
  fi

  local agents_examined=0
  local agents_with_writes=0
  local markers_copied=0
  local -a per_agent_rows=()

  local agent
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ -n "$agent" ]] || continue
    agents_examined=$(( agents_examined + 1 ))

    local profile_dir workspace_dir
    profile_dir="$(_bridge_isolation_v2_backfill_profile_dir "$agent")"
    workspace_dir="$(_bridge_isolation_v2_backfill_workspace_dir "$agent")"

    # Profile source missing → nothing to copy from. This is the common
    # case for dynamic agents whose canonical tree is `data/agents/<a>/home/`
    # rather than `agents/<a>/`. Skip silently.
    if [[ -z "$profile_dir" || ! -d "$profile_dir" ]]; then
      continue
    fi

    # Workspace path unresolvable → can happen on a controller without
    # the v2 marker. Warn and skip; the apply-for-upgrade step normally
    # writes the marker before we run, so an empty workspace_dir here
    # usually means the controller is operating on a legacy-only host
    # where this back-fill is a no-op by design.
    if [[ -z "$workspace_dir" ]]; then
      continue
    fi

    # Same path → nothing to materialize (legacy / identity-source-is-
    # workspace topology, mirroring bridge_layout_materialize_identity's
    # no-op branch).
    if [[ "$profile_dir" == "$workspace_dir" ]]; then
      continue
    fi

    # Ensure the workspace dir itself exists. If creation fails (parent
    # missing, perms), warn and skip — we never want to silently invent
    # a workspace tree behind the layout resolver's back.
    if [[ ! -d "$workspace_dir" ]]; then
      mkdir -p "$workspace_dir" 2>/dev/null || {
        if declare -F bridge_warn >/dev/null 2>&1; then
          bridge_warn "backfill_workdir_identity: cannot create workspace dir for $agent: $workspace_dir"
        fi
        continue
      }
    fi

    local -a writes_for_agent=()
    local -a errors_for_agent=()
    local marker src dst
    for marker in "${BRIDGE_ISOLATION_V2_BACKFILL_IDENTITY_FILES[@]}"; do
      src="$profile_dir/$marker"
      dst="$workspace_dir/$marker"

      # Skip when the source marker is absent — we never invent content.
      [[ -f "$src" ]] || continue
      # Skip when the workspace already holds the marker — idempotency
      # contract, and operator-post-migration edits stay sacred.
      [[ ! -e "$dst" ]] || continue

      if _bridge_isolation_v2_backfill_copy_one "$agent" "$src" "$dst"; then
        writes_for_agent+=("$marker")
        markers_copied=$(( markers_copied + 1 ))
      else
        errors_for_agent+=("$marker")
      fi
    done

    if (( ${#writes_for_agent[@]} > 0 )); then
      agents_with_writes=$(( agents_with_writes + 1 ))
      if declare -F bridge_warn >/dev/null 2>&1; then
        bridge_warn "backfill_workdir_identity: $agent: materialized ${#writes_for_agent[@]} marker(s) into $workspace_dir (${writes_for_agent[*]})"
      fi
    fi

    if (( emit_json == 1 )); then
      per_agent_rows+=(
        "$(_bridge_isolation_v2_backfill_emit_agent_row "$agent" \
            "${#writes_for_agent[@]}" "${writes_for_agent[*]:-}" \
            "${#errors_for_agent[@]}" "${errors_for_agent[*]:-}")"
      )
    fi
  done

  if (( emit_json == 1 )); then
    _bridge_isolation_v2_backfill_emit_summary_json \
      "$agents_examined" "$agents_with_writes" "$markers_copied" \
      "${per_agent_rows[@]}"
  fi

  # Silence the unused-target_root warning. We accept --target-root so
  # the upgrade helper's `--target-root "$TARGET_ROOT"` invocation
  # stays symmetric with the v2-migrate apply call shape, but the
  # resolver primitives we delegate to (bridge_layout_*_dir) already
  # honor BRIDGE_HOME / BRIDGE_DATA_ROOT from the env the upgrade
  # helper set up via bridge_upgrade_with_target_env. Asserting that
  # the env matches target_root would just duplicate the helper's own
  # invariant.
  : "${target_root:=}"

  return 0
}

# _bridge_isolation_v2_backfill_profile_dir <agent>
#
# Resolve the tracked profile-source dir (`$BRIDGE_HOME/agents/<agent>/`)
# for the given agent. Prefers the typed resolver
# `bridge_layout_profile_source_dir` when available; falls back to the
# canonical env-derived path for direct-source consumers.
_bridge_isolation_v2_backfill_profile_dir() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  if declare -F bridge_layout_profile_source_dir >/dev/null 2>&1; then
    bridge_layout_profile_source_dir "$agent"
    return 0
  fi
  printf '%s/agents/%s' "${BRIDGE_HOME:-$HOME/.agent-bridge}" "$agent"
}

# _bridge_isolation_v2_backfill_workspace_dir <agent>
#
# Resolve the v2 runtime workspace dir
# (`$BRIDGE_DATA_ROOT/agents/<agent>/workdir/`). Prefers
# `bridge_layout_workspace_dir` (wraps `bridge_agent_workdir`); falls
# back to the v2 layout default when the typed resolver is not loaded.
_bridge_isolation_v2_backfill_workspace_dir() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  if declare -F bridge_layout_workspace_dir >/dev/null 2>&1; then
    bridge_layout_workspace_dir "$agent" 2>/dev/null
    return 0
  fi
  if [[ -n "${BRIDGE_AGENT_ROOT_V2:-}" ]]; then
    printf '%s/%s/workdir' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  printf ''
}

# _bridge_isolation_v2_backfill_copy_one <agent> <src> <dst>
#
# Copy one identity marker from <src> to <dst>. On a linux-user-isolated
# agent the destination dir is owned by `ab-agent-<slug>` and the
# controller UID cannot write there directly — delegate to the
# isolation-helpers write path. For shared-mode agents (and the
# macOS-no-isolation case) a controller-side `cp -p` is correct.
_bridge_isolation_v2_backfill_copy_one() {
  local agent="$1" src="$2" dst="$3"
  [[ -n "$agent" && -f "$src" && -n "$dst" ]] || return 1

  local _iso_effective_rc=0
  if declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then
    bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
      || _iso_effective_rc=$?
  else
    _iso_effective_rc=1
  fi

  if [[ $_iso_effective_rc -eq 0 ]] \
      && declare -F bridge_isolation_write_file_as_agent_user_via_bash >/dev/null 2>&1; then
    # Isolated path — stream the source bytes through the sudo'd write
    # helper. mode 0644 mirrors the tracked-tree default.
    local _wrc=0
    bridge_isolation_write_file_as_agent_user_via_bash \
      "$agent" "$dst" "0644" < "$src" >/dev/null 2>&1 \
      || _wrc=$?
    case "$_wrc" in
      0) return 0 ;;
      1)
        # Agent claimed linux-user isolation but the helper says it
        # isn't actually isolated (rc=1 == fall back to controller
        # write). Drop through to the cp -p path below.
        ;;
      2)
        if declare -F bridge_warn >/dev/null 2>&1; then
          bridge_warn "backfill_workdir_identity: $agent: passwordless sudo unavailable, cannot back-fill $(basename "$dst") into isolated workspace; operator must sync this marker manually or rerun upgrade with sudo available"
        fi
        return 1
        ;;
      *)
        if declare -F bridge_warn >/dev/null 2>&1; then
          bridge_warn "backfill_workdir_identity: $agent: isolated-write helper rc=$_wrc copying $(basename "$dst")"
        fi
        return 1
        ;;
    esac
  fi

  # Non-isolated (shared mode / macOS single-OS-user / no helper
  # loaded) → direct controller-side copy. `cp -p` preserves mtime so
  # an idempotent re-run leaves the file unchanged byte-for-byte.
  if cp -p -- "$src" "$dst" 2>/dev/null; then
    return 0
  fi
  if declare -F bridge_warn >/dev/null 2>&1; then
    bridge_warn "backfill_workdir_identity: $agent: cp -p $src -> $dst failed"
  fi
  return 1
}

# _bridge_isolation_v2_backfill_emit_agent_row <agent> <n_writes> <writes>
#                                              <n_errors> <errors>
#
# Emit one JSON object describing the per-agent outcome. Used by the
# summary emitter to assemble the agents[] array. All shell-quoted
# values are JSON-escaped through python3 so embedded backslashes /
# quotes in agent ids cannot break the JSON envelope (defense in depth
# — agent ids are slug-validated upstream).
_bridge_isolation_v2_backfill_emit_agent_row() {
  local agent="$1"
  local n_writes="$2"
  local writes="$3"
  local n_errors="$4"
  local errors="$5"
  python3 -c '
import json, sys
agent = sys.argv[1]
n_writes = int(sys.argv[2] or "0")
writes = sys.argv[3].split() if sys.argv[3] else []
n_errors = int(sys.argv[4] or "0")
errors = sys.argv[5].split() if sys.argv[5] else []
print(json.dumps({
  "id": agent,
  "writes": writes[:n_writes],
  "errors": errors[:n_errors],
}))
' "$agent" "$n_writes" "$writes" "$n_errors" "$errors"
}

# _bridge_isolation_v2_backfill_emit_summary_json <examined> <with_writes>
#                                                 <markers_copied> [rows...]
_bridge_isolation_v2_backfill_emit_summary_json() {
  local examined="$1"
  local with_writes="$2"
  local copied="$3"
  shift 3
  python3 -c '
import json, sys
examined = int(sys.argv[1])
with_writes = int(sys.argv[2])
copied = int(sys.argv[3])
agents = []
for row in sys.argv[4:]:
    row = row.strip()
    if not row:
        continue
    try:
        agents.append(json.loads(row))
    except Exception:
        # Defense in depth — a malformed per-agent row should not break
        # the envelope. Skip the row but keep the summary parsable.
        continue
print(json.dumps({
  "mode": "isolation-v2-workdir-backfill",
  "status": "ok",
  "agents_examined": examined,
  "agents_with_writes": with_writes,
  "markers_copied": copied,
  "agents": agents,
}))
' "$examined" "$with_writes" "$copied" "$@"
}
