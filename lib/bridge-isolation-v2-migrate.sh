#!/usr/bin/env bash
# bridge-isolation-v2-migrate.sh — Operator tooling for migrating a legacy
# Agent Bridge install onto the v2 layout (BRIDGE_LAYOUT=v2, BRIDGE_DATA_ROOT=...).
#
# Public entrypoint: bridge_isolation_v2_migrate_cli (dispatched from
# bridge-migrate.sh). Subcommands:
#   dry-run --data-root <path>            print plan + manifest preview, no mutation
#   apply   --data-root <path> --yes      stop, mirror, normalize, marker flip, restart
#   rollback --yes                        marker remove + restart legacy
#   commit  --yes                         delete legacy paths recorded in manifest
#   status                                print current marker + manifest summary
#
# Contracts (agreed via 9 dev-codex review rounds):
#   * --apply / --rollback refuse to run when invoked from inside a managed
#     agent session whose own id appears in the active snapshot.
#   * Active-agent stop uses real CLI primitives (per-agent `bridge-agent.sh
#     stop <agent>`, then plain `bridge-daemon.sh stop` after active=0).
#   * Daemon presence/absence is verified via process-based polling
#     (`bridge_daemon_all_pids`), bounded with an integer attempt counter.
#   * Mirror is real copy (rsync -aHX --numeric-ids --no-links). No hardlinks
#     so subsequent chgrp/chmod can not mutate legacy inodes.
#   * Manifest schema (TSV, 9 columns):
#       ts  mapping_id  legacy_src_abs  v2_dst_abs  bytes  sha256_legacy
#       sha256_v2  verify_status  delete_eligible
#     commit candidate filter: $8 == "ok" && $9 == "1".
#   * Profile/memory/skills mirror to v2 workdir with delete_eligible=0 —
#     install-root retained as frozen snapshot, runtime reads from v2 workdir.
#   * Plugin catalog: only controller-managed (~/.claude/plugins/
#     installed_plugins.json + known_marketplaces.json + marketplaces/)
#     copied to $BRIDGE_DATA_ROOT/shared/plugins-cache/. Per-UID plugins/data
#     never merged into shared.
#   * Marker file written via tmpfile + atomic mv; loaded only after strict
#     validation in lib/bridge-marker-bootstrap.sh.
#   * Explicit BRIDGE_AGENT_PROFILE_HOME override that does not match the
#     v2 workdir is treated as roster intent — preflight prints a remediation
#     warning in dry-run and dies in apply, never silently rewrites roster.
#   * Group changes use sudo metadata ops; current shell's id -nG is
#     untrusted (warm-cache problem). Postflight probes each agent UID and
#     the controller via fresh `sudo -u <user> id -nG`.
#   * Self-cleanup in this module never installs a long-lived EXIT trap
#     (would clobber the existing COPY_JSON trap conventions in scripts/).
#
# shellcheck shell=bash disable=SC2034

# ---------------------------------------------------------------------------
# 0. helper: paths and constants
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_state_dir() {
  printf '%s/migration' "${BRIDGE_STATE_DIR}"
}

bridge_isolation_v2_migrate_active_snapshot_path() {
  printf '%s/active-agents.snapshot' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_lock_path() {
  printf '%s/migrate-isolation-v2.lock' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_manifest_path() {
  # Single rolling manifest. apply truncates + appends; commit reads.
  printf '%s/manifest.tsv' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_backup_tarball_path() {
  local stamp="$1"
  printf '%s/legacy-backup-%s.tar.zst' "$(bridge_isolation_v2_migrate_state_dir)" "$stamp"
}

bridge_isolation_v2_migrate_mkstate() {
  install -d -m 0750 "$(bridge_isolation_v2_migrate_state_dir)" 2>/dev/null \
    || mkdir -p "$(bridge_isolation_v2_migrate_state_dir)"
}

# ---------------------------------------------------------------------------
# 1. self-stop guard
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_self_stop_guard() {
  local self="${BRIDGE_AGENT_ID:-}"
  [[ -n "$self" ]] || return 0

  local snapshot_path="$1"
  [[ -f "$snapshot_path" ]] || return 0

  local line
  while IFS= read -r line; do
    if [[ "$line" == "$self" ]]; then
      bridge_die "self-stop guard: '$self' is in the active snapshot. \
Run this command from an out-of-band controller shell (unset BRIDGE_AGENT_ID), \
not from inside an Agent Bridge agent session. No state has been mutated."
    fi
  done < "$snapshot_path"
  return 0
}

# ---------------------------------------------------------------------------
# 2. lock + active-agent snapshot
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_acquire_lock() {
  # mkdir-based atomic lock + PID stale-owner detection.
  #
  # macOS does not ship `flock(1)` by default (it's Linux util-linux); we
  # also can't require Homebrew `flock` as an upgrade prerequisite. mkdir
  # is atomic on every supported FS and works in Bash 3.2 baseline with
  # no external deps. The owner-pid file gives us crash-recovery: if the
  # previous holder died without rmdir'ing, the next acquirer detects the
  # stale pid (via `kill -0`), removes the lock dir, and retries once.
  #
  # Lock layout:
  #   $BRIDGE_STATE_DIR/migration/migrate-isolation-v2.lock.d/   (dir)
  #   $BRIDGE_STATE_DIR/migration/migrate-isolation-v2.lock.d/owner.pid
  bridge_isolation_v2_migrate_mkstate
  local lock_path lock_dir owner_pid_file existing_pid
  lock_path="$(bridge_isolation_v2_migrate_lock_path)"
  lock_dir="${lock_path}.d"
  owner_pid_file="${lock_dir}/owner.pid"

  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$owner_pid_file" 2>/dev/null || true
    BRIDGE_ISOLATION_V2_MIGRATE_LOCK_DIR="$lock_dir"
    trap 'bridge_isolation_v2_migrate_release_lock' EXIT
    return 0
  fi

  # mkdir failed → either another live process holds the lock, or a stale
  # lock dir is left behind from a crashed prior run. Inspect owner.pid.
  existing_pid=""
  if [[ -f "$owner_pid_file" ]]; then
    existing_pid="$(cat "$owner_pid_file" 2>/dev/null | tr -d '[:space:]' || true)"
  fi
  if [[ -n "$existing_pid" ]] && [[ "$existing_pid" =~ ^[0-9]+$ ]] \
      && kill -0 "$existing_pid" 2>/dev/null; then
    bridge_die "another isolation-v2 migrate operation is in progress (lock=$lock_dir, owner_pid=$existing_pid)"
  fi

  # Stale: pid file missing, unreadable, malformed, or pointing at a dead
  # process. Remove the dir + retry once. Failure to rmdir means a live
  # writer raced us between the readdir and rmdir — treat as live owner.
  if ! rm -rf -- "$lock_dir" 2>/dev/null; then
    bridge_die "another isolation-v2 migrate operation is in progress (lock=$lock_dir, stale-cleanup-failed)"
  fi
  if mkdir "$lock_dir" 2>/dev/null; then
    printf '%s\n' "$$" >"$owner_pid_file" 2>/dev/null || true
    BRIDGE_ISOLATION_V2_MIGRATE_LOCK_DIR="$lock_dir"
    trap 'bridge_isolation_v2_migrate_release_lock' EXIT
    return 0
  fi
  bridge_die "another isolation-v2 migrate operation is in progress (lock=$lock_dir, race-after-cleanup)"
}

bridge_isolation_v2_migrate_release_lock() {
  # Idempotent: trap may fire after explicit release in normal flow.
  local lock_dir="${BRIDGE_ISOLATION_V2_MIGRATE_LOCK_DIR:-}"
  [[ -n "$lock_dir" ]] || return 0
  rm -rf -- "$lock_dir" 2>/dev/null || true
  BRIDGE_ISOLATION_V2_MIGRATE_LOCK_DIR=""
}

bridge_isolation_v2_migrate_capture_active_snapshot() {
  bridge_isolation_v2_migrate_mkstate
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"
  bridge_active_agent_ids > "$snapshot"
}

bridge_isolation_v2_migrate_all_agents_snapshot_path() {
  printf '%s/all-agents.snapshot' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_capture_all_agents_snapshot() {
  # Q3 spec: enumerate roster ∪ $TARGET_ROOT/agents/*/home, NOT
  # active-only. Every agent that has ever existed needs migration even
  # if currently inactive — otherwise a stopped agent would re-launch
  # against unmigrated paths and get kicked by the v2 fail-fast guard.
  #
  # Reads BRIDGE_AGENT_IDS (roster) and the agents/<n>/home directory
  # listing under the v1 install root ($BRIDGE_AGENT_HOME_ROOT). The
  # union is deduplicated via sort -u; output is one agent id per line.
  bridge_isolation_v2_migrate_mkstate
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_all_agents_snapshot_path)"

  # v0.8.3: build a roster lookup so the dir-walk pass can distinguish
  # v1-layout agents (in roster, no home/ yet — will migrate) from
  # genuinely orphan dirs (not in roster, no home/ — operator scratch).
  # The former should be silent; only the latter should warn.
  local roster_lookup
  roster_lookup="$(bridge_isolation_v2_migrate_state_dir)/roster.lookup.$$"
  : > "$roster_lookup"
  if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
    local _rid
    for _rid in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ -n "$_rid" ]] || continue
      printf '%s\n' "$_rid" >> "$roster_lookup"
    done
  fi

  {
    if declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1; then
      local id
      for id in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ -n "$id" ]] || continue
        printf '%s\n' "$id"
      done
    fi
    if [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" && -d "$BRIDGE_AGENT_HOME_ROOT" ]]; then
      local entry name
      for entry in "$BRIDGE_AGENT_HOME_ROOT"/*/; do
        [[ -d "$entry" ]] || continue
        name="$(basename "$entry")"
        # Skip dotfiles and well-known non-agent dirs. r2 review fix:
        # `agents-archive` was missing from the denylist. The filter
        # also requires a `home/` child to confirm this really is an
        # agent root — orphan dirs (e.g. half-deleted agents, operator
        # scratch) get skipped instead of accidentally enrolled into
        # the v2 group/perm pass.
        case "$name" in
          .*|backups|state|logs|shared|worktrees|agents-archive)
            continue
            ;;
        esac
        if [[ ! -d "$entry/home" ]]; then
          # v0.8.3: silent for v1-layout agents in roster (they will
          # migrate via the roster path above and emit_plan rows). Warn
          # only for genuinely orphan dirs that are NOT in BRIDGE_AGENT_IDS.
          if ! grep -qFx "$name" "$roster_lookup" 2>/dev/null; then
            bridge_warn "isolation-v2 migration: skipping orphan dir $entry (not in roster, no home/ subdir)"
          fi
          continue
        fi
        printf '%s\n' "$name"
      done
    fi
  } | sort -u >"$snapshot"

  rm -f "$roster_lookup" 2>/dev/null || true
}

bridge_isolation_v2_migrate_per_agent_marker_dir() {
  printf '%s/isolation-v2/agents' "$(bridge_isolation_v2_migrate_state_dir)"
}

bridge_isolation_v2_migrate_per_agent_marker_path() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  printf '%s/%s.env' "$(bridge_isolation_v2_migrate_per_agent_marker_dir)" "$agent"
}

bridge_isolation_v2_migrate_per_agent_marker_present() {
  local agent="$1"
  [[ -n "$agent" ]] || return 1
  local marker
  marker="$(bridge_isolation_v2_migrate_per_agent_marker_path "$agent")"
  [[ -f "$marker" ]]
}

bridge_isolation_v2_migrate_per_agent_marker_write() {
  # Write a per-agent completion marker after the agent's group +
  # path-perms pass. Atomic write via tmpfile + mv. Format:
  #   ISOLATION_V2_MIGRATED_AT=<iso8601>
  #   ISOLATION_V2_GROUP=<group_name>
  #   ISOLATION_V2_GID=<gid>           (optional; empty when query fails)
  #   ISOLATION_V2_RELOGIN_REQUIRED=<0|1>
  local agent="$1"
  local group="$2"
  local relogin_required="${3:-0}"
  [[ -n "$agent" && -n "$group" ]] || {
    bridge_warn "per_agent_marker_write: agent and group required"
    return 1
  }

  local dir
  dir="$(bridge_isolation_v2_migrate_per_agent_marker_dir)"
  install -d -m 0750 "$dir" 2>/dev/null || mkdir -p "$dir"

  local marker tmp gid ts
  marker="$(bridge_isolation_v2_migrate_per_agent_marker_path "$agent")"
  tmp="${marker}.tmp.$$"
  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"

  if [[ "$(uname)" == "Darwin" ]]; then
    gid="$(bridge_isolation_v2_darwin_group_gid "$group" 2>/dev/null || true)"
  else
    gid="$(getent group "$group" 2>/dev/null | awk -F: '{print $3}')"
  fi

  {
    printf 'ISOLATION_V2_MIGRATED_AT=%s\n' "$ts"
    printf 'ISOLATION_V2_GROUP=%s\n' "$group"
    printf 'ISOLATION_V2_GID=%s\n' "${gid:-}"
    printf 'ISOLATION_V2_RELOGIN_REQUIRED=%s\n' "$relogin_required"
  } > "$tmp"
  chmod 0640 "$tmp" 2>/dev/null || true
  mv -f "$tmp" "$marker" || {
    rm -f "$tmp"
    bridge_warn "per_agent_marker_write: mv failed for $marker"
    return 1
  }
  return 0
}

bridge_isolation_v2_migrate_all_per_agent_markers_present() {
  # Returns 0 when every id in $1 (newline-separated snapshot) has its
  # per-agent completion marker present. Used by the upgrade wrapper to
  # gate the global marker write.
  local snapshot_path="$1"
  [[ -f "$snapshot_path" ]] || return 1
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    bridge_isolation_v2_migrate_per_agent_marker_present "$agent" || return 1
  done < "$snapshot_path"
  return 0
}

# ---------------------------------------------------------------------------
# 3. profile_home override preflight
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_check_profile_home_overrides() {
  # Returns 0 when no agent in the snapshot has a misaligned explicit
  # BRIDGE_AGENT_PROFILE_HOME. Returns 1 otherwise; warns to stderr.
  # Caller is responsible for the dry-run-vs-apply policy decision.
  local snapshot_path="$1"
  local data_root="$2"
  [[ -f "$snapshot_path" && -n "$data_root" ]] || return 0

  local agent override expected mismatch=0
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    override="${BRIDGE_AGENT_PROFILE_HOME[$agent]-}"
    [[ -n "$override" ]] || continue
    override="$(bridge_expand_user_path "$override")"
    expected="$data_root/agents/$agent/workdir"
    if [[ "$override" != "$expected" ]]; then
      bridge_warn "agent '$agent' has explicit BRIDGE_AGENT_PROFILE_HOME=$override which is not the v2 workdir ($expected). agent-bridge profile deploy will land in the wrong location after marker flip. Edit roster (agent-roster.local.sh or agent-roster.sh) to unset or align this entry, then re-run --apply."
      mismatch=1
    fi
  done < "$snapshot_path"
  return $(( mismatch ))
}

# ---------------------------------------------------------------------------
# 4. mirror map enumeration
# ---------------------------------------------------------------------------

# Print one TSV row per planned mirror op:
#   <mapping_id> TAB <legacy_src> TAB <v2_dst> TAB <delete_eligible>
# Only paths whose legacy src exists are emitted. v2 dst dirs are created
# at mirror time, not here.
bridge_isolation_v2_migrate_emit_plan() {
  local data_root="$1"
  local snapshot_path="$2"
  local controller_user="${SUDO_USER:-${USER:-}}"
  local controller_home
  controller_home="$(bridge_linux_resolve_user_home "$controller_user" 2>/dev/null \
    || printf '%s' "$HOME")"

  # ---- per-agent rows ----
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    local legacy_root="$BRIDGE_AGENT_HOME_ROOT/$agent"
    local v2_agent_root="$data_root/agents/$agent"

    # runtime, delete_eligible=1
    bridge_isolation_v2_migrate_emit_row \
      "agent_claude:$agent" "$legacy_root/.claude" "$v2_agent_root/home/.claude" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_discord:$agent" "$legacy_root/.discord" "$v2_agent_root/workdir/.discord" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_telegram:$agent" "$legacy_root/.telegram" "$v2_agent_root/workdir/.telegram" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_teams:$agent" "$legacy_root/.teams" "$v2_agent_root/workdir/.teams" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_ms365:$agent" "$legacy_root/.ms365" "$v2_agent_root/workdir/.ms365" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_credentials:$agent" "$legacy_root/credentials" "$v2_agent_root/credentials" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_workdir:$agent" "$legacy_root/workdir" "$v2_agent_root/workdir" 1
    bridge_isolation_v2_migrate_emit_row \
      "agent_logs:$agent" "$legacy_root/logs" "$v2_agent_root/logs" 1

    # dual-read (delete_eligible=0)
    bridge_isolation_v2_migrate_emit_row \
      "agent_session_type:$agent" "$legacy_root/SESSION-TYPE.md" "$v2_agent_root/workdir/SESSION-TYPE.md" 0
    bridge_isolation_v2_migrate_emit_row \
      "agent_next_session:$agent" "$legacy_root/NEXT-SESSION.md" "$v2_agent_root/workdir/NEXT-SESSION.md" 0

    # profile / instruction (delete_eligible=0)
    local pf
    for pf in CLAUDE.md MEMORY.md SKILLS.md SOUL.md HEARTBEAT.md \
              MEMORY-SCHEMA.md COMMON-INSTRUCTIONS.md CHANGE-POLICY.md TOOLS.md; do
      bridge_isolation_v2_migrate_emit_row \
        "agent_profile_${pf}:$agent" "$legacy_root/$pf" "$v2_agent_root/workdir/$pf" 0
    done

    # profile / skills / memory subtrees (delete_eligible=0)
    local sd
    for sd in .agents memory users references skills; do
      bridge_isolation_v2_migrate_emit_row \
        "agent_subtree_${sd}:$agent" "$legacy_root/$sd" "$v2_agent_root/workdir/$sd" 0
    done
  done < "$snapshot_path"

  # ---- global rows ----
  bridge_isolation_v2_migrate_emit_row \
    "runtime_root" "$BRIDGE_RUNTIME_ROOT" "$data_root/state/runtime" 1
  bridge_isolation_v2_migrate_emit_row \
    "runtime_shared" "$BRIDGE_RUNTIME_SHARED_DIR" "$data_root/shared" 1
  if [[ "$BRIDGE_WORKTREE_ROOT" == "$BRIDGE_HOME"/* ]]; then
    bridge_isolation_v2_migrate_emit_row \
      "worktree_root" "$BRIDGE_WORKTREE_ROOT" "$data_root/worktrees" 1
  fi

  # ---- plugin catalog (controller-managed only) ----
  if [[ -n "$controller_home" ]]; then
    local plugins_root="$controller_home/.claude/plugins"
    if [[ -f "$plugins_root/installed_plugins.json" ]]; then
      bridge_isolation_v2_migrate_emit_row \
        "plugin_installed_json" \
        "$plugins_root/installed_plugins.json" \
        "$data_root/shared/plugins-cache/installed_plugins.json" 1
    fi
    if [[ -f "$plugins_root/known_marketplaces.json" ]]; then
      bridge_isolation_v2_migrate_emit_row \
        "plugin_known_markets_json" \
        "$plugins_root/known_marketplaces.json" \
        "$data_root/shared/plugins-cache/known_marketplaces.json" 1
    fi
    if [[ -d "$plugins_root/marketplaces" ]]; then
      bridge_isolation_v2_migrate_emit_row \
        "plugin_marketplaces_tree" \
        "$plugins_root/marketplaces" \
        "$data_root/shared/plugins-cache/marketplaces" 1
    fi
  fi
}

bridge_isolation_v2_migrate_emit_row() {
  local mapping_id="$1" legacy_src="$2" v2_dst="$3" delete_eligible="$4"
  # v0.8.3 amend: existence check tolerates linux-user-isolated paths.
  # Without sudo, sean can't traverse `agents/<bob>/` (mode 2750 owned
  # by agent-bridge-<bob>:ab-agent-<bob>) on a fresh migration since
  # supplementary group membership from ensure_groups isn't yet active
  # in the controller's process. Fall back to `sudo -n test -e` so
  # isolated agents' rows still get emitted; mirror_one's sudo wrap
  # handles the actual rsync.
  if [[ ! -e "$legacy_src" ]]; then
    sudo -n test -e "$legacy_src" 2>/dev/null || return 0
  fi
  # v0.8.3: src==dst guard. When BRIDGE_DATA_ROOT == TARGET_ROOT
  # (markerless default) some v1 paths coincide with v2 paths
  # (e.g. agents/<n>/credentials → agents/<n>/credentials). Emitting
  # those would queue a no-op rsync that pollutes the manifest and,
  # combined with delete_eligible=1 cleanup, would delete the very
  # content we just "mirrored" to itself.
  [[ "$legacy_src" == "$v2_dst" ]] && return 0
  # v0.8.3 amend: skip empty-tree global rows. The runtime_shared
  # mapping (runtime/shared -> shared) emits even when runtime/shared
  # is empty subdirs only and dst already populated; rsync hits
  # transient partial-transfer (rc=23) edge cases that abort the
  # migration despite zero load-bearing data. Recursive find for any
  # regular file or symlink: if absent, the row contributes nothing
  # and is safe to skip.
  if [[ -d "$legacy_src" ]]; then
    local _has_content
    _has_content="$(sudo -n find "$legacy_src" -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null \
                    || find "$legacy_src" -mindepth 1 \( -type f -o -type l \) -print -quit 2>/dev/null \
                    || printf '')"
    [[ -n "$_has_content" ]] || return 0
  fi
  printf '%s\t%s\t%s\t%s\n' "$mapping_id" "$legacy_src" "$v2_dst" "$delete_eligible"
}

# ---------------------------------------------------------------------------
# 5. mirror execution + manifest
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_sha256_of() {
  # Print sha256 of a path. For regular files, hash the bytes. For
  # symlinks, hash the link kind + readlink target. For directories,
  # walk every regular file AND symlink so a tree containing symlinks
  # is verified — the previous `-type f` filter let symlink drops
  # under `rsync -a` slip through as verify_status=ok.
  local target="$1"
  if [[ -L "$target" ]]; then
    printf 'symlink:%s' "$(readlink "$target" 2>/dev/null || printf 'unreadable')" \
      | sha256sum | awk '{print $1}'
    return
  fi
  if [[ -f "$target" ]]; then
    sha256sum "$target" 2>/dev/null | awk '{print $1}'
    return
  fi
  if [[ -d "$target" ]]; then
    (
      cd "$target" 2>/dev/null || exit 0
      find . \( -type f -o -type l \) -print0 2>/dev/null \
        | sort -z \
        | while IFS= read -r -d '' p; do
            if [[ -L "$p" ]]; then
              printf 'symlink:%s\t%s\n' "$p" \
                "$(readlink "$p" 2>/dev/null || printf 'unreadable')"
            elif [[ -f "$p" ]]; then
              printf 'file:%s\t%s\n' "$p" \
                "$(sha256sum "$p" 2>/dev/null | awk '{print $1}')"
            fi
          done
    ) | sha256sum | awk '{print $1}'
    return
  fi
  printf 'absent'
}

bridge_isolation_v2_migrate_bytes_of() {
  local target="$1"
  if [[ -f "$target" && ! -L "$target" ]]; then
    stat -c '%s' "$target" 2>/dev/null || printf '0'
    return
  fi
  if [[ -d "$target" ]]; then
    du -sb "$target" 2>/dev/null | awk '{print $1}'
    return
  fi
  printf '0'
}

bridge_isolation_v2_migrate_mirror_one() {
  local mapping_id="$1" legacy_src="$2" v2_dst="$3" delete_eligible="$4"
  local manifest_path="$5"
  local ts bytes sha_legacy sha_v2 verify

  ts="$(date -u +%Y-%m-%dT%H:%M:%SZ)"
  bytes="$(bridge_isolation_v2_migrate_bytes_of "$legacy_src")"
  sha_legacy="$(bridge_isolation_v2_migrate_sha256_of "$legacy_src")"

  # Detect cross-UID source FIRST (used both for mkdir + rsync).
  local src_uid current_uid use_sudo=0
  current_uid="$(id -u)"
  src_uid="$(stat -c '%u' "$legacy_src" 2>/dev/null \
              || stat -f '%u' "$legacy_src" 2>/dev/null \
              || sudo -n stat -c '%u' "$legacy_src" 2>/dev/null \
              || sudo -n stat -f '%u' "$legacy_src" 2>/dev/null \
              || printf '%s' "$current_uid")"
  if [[ -n "$src_uid" && "$src_uid" != "$current_uid" ]]; then
    use_sudo=1
  fi

  # Make destination parent. v0.8.3 amend: when src is cross-UID
  # (linux-user-isolated), the dst parent (e.g. agents/<bob>/) is
  # owned by the isolated UID, so sean's mkdir fails with EACCES.
  # Use sudo when escalation is needed.
  local dst_parent
  if [[ -d "$legacy_src" ]]; then
    if (( use_sudo == 1 )); then
      sudo -n mkdir -p "$v2_dst" 2>/dev/null
    else
      mkdir -p "$v2_dst" 2>/dev/null
    fi
  else
    dst_parent="$(dirname "$v2_dst")"
    if (( use_sudo == 1 )); then
      sudo -n mkdir -p "$dst_parent" 2>/dev/null
    else
      mkdir -p "$dst_parent" 2>/dev/null
    fi
  fi

  # Real copy. -a preserves perm/owner/time AND symlinks (-l is part of
  # -a). -H preserves hardlinks. -X preserves xattrs. --numeric-ids
  # skips name lookups on the destination side. NOTE: do not use
  # --no-links — it disables symlink copying entirely, which previously
  # let symlink-bearing trees pass verify_status=ok with the symlinks
  # silently dropped (caught by the dev-codex r1 review).
  #
  # v0.8.3 amend: detect linux-user-isolated paths (src owned by a
  # different uid than the current process) and run rsync via sudo so
  # the mirror can read the isolated tree. Without this, an isolated
  # agent's `agents/<n>/CLAUDE.md` (mode 0600 owned by agent-bridge-<n>)
  # is invisible to the controller's rsync — emit_row's `[[ -e ... ]]`
  # passes if the parent dir is traversable but rsync fails to read
  # the actual content. The migration already requires sudo via the
  # privilege_preflight gate so this doesn't add new prerequisites.
  #
  # v0.8.3 amend: drop --delete-excluded — without an --exclude pattern
  # the flag is a no-op for per-agent rows but pairs destructively
  # with the global runtime_shared mapping where dst contains content
  # not present in src (rsync_fail_23 in v0.7.8 -> v0.8.3 VM repro).
  # use_sudo + src_uid already detected above (shared with mkdir).
  local rc=0
  if [[ -d "$legacy_src" ]]; then
    if (( use_sudo == 1 )); then
      sudo -n rsync -aHX --numeric-ids \
        "$legacy_src/" "$v2_dst/" >/dev/null 2>&1 || rc=$?
    else
      rsync -aHX --numeric-ids \
        "$legacy_src/" "$v2_dst/" >/dev/null 2>&1 || rc=$?
    fi
  else
    if (( use_sudo == 1 )); then
      sudo -n rsync -aHX --numeric-ids \
        "$legacy_src" "$v2_dst" >/dev/null 2>&1 || rc=$?
    else
      rsync -aHX --numeric-ids \
        "$legacy_src" "$v2_dst" >/dev/null 2>&1 || rc=$?
    fi
  fi
  if (( rc != 0 )); then
    verify="rsync_fail_$rc"
    sha_v2="absent"
  else
    sha_v2="$(bridge_isolation_v2_migrate_sha256_of "$v2_dst")"
    if [[ "$sha_legacy" == "$sha_v2" ]]; then
      verify="ok"
    else
      verify="checksum_mismatch"
    fi
  fi

  printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
    "$ts" "$mapping_id" "$legacy_src" "$v2_dst" "$bytes" \
    "$sha_legacy" "$sha_v2" "$verify" "$delete_eligible" \
    >> "$manifest_path"

  [[ "$verify" == "ok" ]] || return 1

  # v0.8.3: delete legacy_src after a verified mirror when the row is
  # delete_eligible=1. Previously commit was a separate operator-invoked
  # phase (`migrate isolation-v2 commit`), but the upgrade hot path
  # needs immediate cleanup so runtime does not double-read v1+v2 paths
  # for the same logical resource. Manifest still records the row so
  # rollback can reverse it.
  if [[ "$delete_eligible" == "1" && "$legacy_src" != "$v2_dst" ]]; then
    rm -rf -- "$legacy_src" 2>/dev/null \
      || bridge_warn "mirror_one: failed to remove $legacy_src after successful mirror"
  fi
  return 0
}

bridge_isolation_v2_migrate_mirror_all() {
  local data_root="$1" snapshot_path="$2" manifest_path="$3"
  : > "$manifest_path"

  local row mapping_id legacy_src v2_dst delete_eligible
  local fail=0
  while IFS=$'\t' read -r mapping_id legacy_src v2_dst delete_eligible; do
    [[ -n "$mapping_id" ]] || continue
    if ! bridge_isolation_v2_migrate_mirror_one \
        "$mapping_id" "$legacy_src" "$v2_dst" "$delete_eligible" "$manifest_path"; then
      fail=$(( fail + 1 ))
    fi
  done < <(bridge_isolation_v2_migrate_emit_plan "$data_root" "$snapshot_path")

  if (( fail > 0 )); then
    bridge_warn "mirror: $fail row(s) failed (see $manifest_path verify_status column)"
    return 1
  fi
  return 0
}

# ---------------------------------------------------------------------------
# 6. group ensure + post-flight probe
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_ensure_groups_and_memberships() {
  # Group creation + user membership additions only. Honors
  # BRIDGE_SHARED_GROUP / BRIDGE_CONTROLLER_GROUP / BRIDGE_AGENT_GROUP_PREFIX
  # overrides; defaults match lib/bridge-isolation-v2.sh.
  # Path ownership/mode normalization is a SEPARATE step
  # (`bridge_isolation_v2_migrate_normalize_layout`) run AFTER mirror_all
  # creates the destination tree — calling it here would no-op because
  # the dirs do not exist yet. r2 review (P1 #1).
  local snapshot_path="$1"
  local controller_user="${SUDO_USER:-${USER:-}}"
  local shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  local ctrl_grp="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"

  bridge_isolation_v2_ensure_group "$shared_grp" || return 1
  bridge_isolation_v2_ensure_group "$ctrl_grp" || return 1

  if [[ -n "$controller_user" ]]; then
    bridge_isolation_v2_ensure_user_in_group "$controller_user" "$shared_grp" || return 1
    bridge_isolation_v2_ensure_user_in_group "$controller_user" "$ctrl_grp" || return 1
  fi

  local agent agent_grp os_user
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    agent_grp="$(bridge_isolation_v2_agent_group_name "$agent")"
    bridge_isolation_v2_ensure_group "$agent_grp" || return 1
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    if [[ -n "$os_user" ]]; then
      bridge_isolation_v2_ensure_user_in_group "$os_user" "$shared_grp" || return 1
      bridge_isolation_v2_ensure_user_in_group "$os_user" "$agent_grp" || return 1
    fi
    if [[ -n "$controller_user" ]]; then
      bridge_isolation_v2_ensure_user_in_group "$controller_user" "$agent_grp" || return 1
    fi
  done < "$snapshot_path"

  return 0
}

bridge_isolation_v2_migrate_normalize_layout() {
  # chgrp + setgid + mode normalization on migrated trees. Called AFTER
  # mirror_all so the destination paths actually exist. Each
  # bridge_isolation_v2_chgrp_setgid_recursive call uses the helper's
  # actual signature: (group, dir_mode, file_mode, root).
  # Failures propagate so apply dies with a clear error — silent
  # `2>/dev/null || true` was the r2 P1 #1 root cause.
  local snapshot_path="$1"
  local data_root="$2"
  local shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  local ctrl_grp="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"

  if [[ -d "$data_root/shared" ]]; then
    bridge_isolation_v2_chgrp_setgid_recursive \
      "$shared_grp" 2750 0640 "$data_root/shared" \
      || { bridge_warn "normalize_layout: shared/ chgrp_setgid_recursive failed"; return 1; }
  fi

  if [[ -d "$data_root/state" ]]; then
    bridge_isolation_v2_chgrp_setgid_recursive \
      "$ctrl_grp" 2750 0640 "$data_root/state" \
      || { bridge_warn "normalize_layout: state/ chgrp_setgid_recursive failed"; return 1; }
  fi

  # Per-agent root must be 2750 (isolated UID enters via group r-x but
  # MUST NOT have group write at the root, otherwise it could rename or
  # delete credentials/ even though credentials/ itself is 2750). r3
  # review caught the broad recursive 2770 pass making the root
  # writable. Spec: lib/bridge-isolation-v2.sh:45-59 +
  # lib/bridge-agents.sh:2116-2152 (`# 2750 — isolated UID r-x at root`).
  local agent agent_grp agent_root sub
  local writable_subs=(home workdir runtime logs requests responses)
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    agent_grp="$(bridge_isolation_v2_agent_group_name "$agent")"
    agent_root="$data_root/agents/$agent"
    [[ -d "$agent_root" ]] || continue

    # Per-agent root: SINGLE-DIR normalize at 2750. No recursion.
    bridge_isolation_v2_chgrp_setgid_dir "$agent_grp" 2750 "$agent_root" \
      || { bridge_warn "normalize_layout: agents/$agent root chgrp_setgid_dir failed"; return 1; }

    # Writable children: 2770/0660 recursive (group rwx + setgid +
    # files group-rw so the isolated UID can write its runtime state).
    for sub in "${writable_subs[@]}"; do
      [[ -d "$agent_root/$sub" ]] || continue
      bridge_isolation_v2_chgrp_setgid_recursive \
        "$agent_grp" 2770 0660 "$agent_root/$sub" \
        || { bridge_warn "normalize_layout: agents/$agent/$sub chgrp_setgid_recursive failed"; return 1; }
    done

    # credentials/: tighter modes — controller writes, isolated UID
    # gets group r-x dir + group r files only.
    if [[ -d "$agent_root/credentials" ]]; then
      bridge_isolation_v2_chgrp_setgid_recursive \
        "$agent_grp" 2750 0640 "$agent_root/credentials" \
        || { bridge_warn "normalize_layout: agents/$agent/credentials chgrp_setgid_recursive failed"; return 1; }
    fi
  done < "$snapshot_path"

  return 0
}

bridge_isolation_v2_migrate_postflight_groups() {
  local snapshot_path="$1"
  local controller_user="${SUDO_USER:-${USER:-}}"
  local shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
  local ctrl_grp="${BRIDGE_CONTROLLER_GROUP:-ab-controller}"
  local agent groups os_user
  local mismatch=0

  # Controller fresh probe — must be in shared+controller groups.
  if [[ -n "$controller_user" ]]; then
    groups="$(sudo -n -u "$controller_user" id -nG 2>/dev/null || true)"
    if [[ -z "$groups" ]]; then
      bridge_warn "postflight: cannot fresh-probe controller groups for $controller_user"
      mismatch=1
    else
      if ! grep -qw "$shared_grp" <<<"$groups"; then
        bridge_warn "postflight: controller $controller_user missing group $shared_grp; got: $groups"
        mismatch=1
      fi
      if ! grep -qw "$ctrl_grp" <<<"$groups"; then
        bridge_warn "postflight: controller $controller_user missing group $ctrl_grp; got: $groups"
        mismatch=1
      fi
    fi
  fi

  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    [[ -n "$os_user" ]] || continue
    groups="$(sudo -n -u "$os_user" id -nG 2>/dev/null || true)"
    if [[ -z "$groups" ]]; then
      bridge_warn "postflight: cannot fresh-probe groups for $os_user (agent $agent)"
      mismatch=1
      continue
    fi
    local agent_group
    agent_group="$(bridge_isolation_v2_agent_group_name "$agent")"
    if ! grep -qw "$agent_group" <<<"$groups"; then
      bridge_warn "postflight: $os_user (agent $agent) missing group $agent_group; got: $groups"
      mismatch=1
    fi
    if ! grep -qw "$shared_grp" <<<"$groups"; then
      bridge_warn "postflight: $os_user (agent $agent) missing group $shared_grp; got: $groups"
      mismatch=1
    fi
  done < "$snapshot_path"

  return $(( mismatch ))
}

# ---------------------------------------------------------------------------
# 7. daemon poll (process-based, bounded, integer attempts)
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_wait_daemon_gone() {
  local timeout_s="${1:-10}"
  local interval_s=0.2
  local max_attempts=$(( timeout_s * 5 ))
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    if [[ -z "$(bridge_daemon_all_pids 2>/dev/null || true)" ]]; then
      return 0
    fi
    sleep "$interval_s"
  done
  bridge_die "daemon stop verification failed: still running PIDs after ${timeout_s}s"
}

bridge_isolation_v2_migrate_wait_daemon_present() {
  local timeout_s="${1:-10}"
  local interval_s=0.2
  local max_attempts=$(( timeout_s * 5 ))
  local attempt
  for (( attempt = 0; attempt < max_attempts; attempt++ )); do
    if [[ -n "$(bridge_daemon_all_pids 2>/dev/null || true)" ]]; then
      return 0
    fi
    sleep "$interval_s"
  done
  bridge_die "daemon failed to come up within ${timeout_s}s after restart"
}

# ---------------------------------------------------------------------------
# 8. orchestrate stop / restart
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_orchestrate_stop() {
  local snapshot_path="$1"

  # Per-agent stop.
  local agent
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-agent.sh" stop "$agent" >/dev/null 2>&1 \
      || bridge_warn "stop failed for agent '$agent' — continuing; will be skipped at restart"
  done < "$snapshot_path"

  # Verify zero active.
  local remaining
  remaining="$(bridge_active_agent_ids | wc -l | tr -d ' ')"
  if [[ "$remaining" =~ ^[0-9]+$ ]] && (( remaining > 0 )); then
    bridge_die "agents still active after per-agent stop loop: $remaining"
  fi

  # Plain daemon stop (active=0 now → no --force needed).
  "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-daemon.sh" stop >/dev/null 2>&1 \
    || bridge_die "daemon stop returned non-zero"
  bridge_isolation_v2_migrate_wait_daemon_gone 10
}

bridge_isolation_v2_migrate_orchestrate_restart() {
  local snapshot_path="$1"

  "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-daemon.sh" start >/dev/null 2>&1 \
    || bridge_die "daemon restart failed"
  bridge_isolation_v2_migrate_wait_daemon_present 10

  # v0.8.3: skip restart for agents whose tmux session has an attached
  # operator. The dry-run pass in bridge-upgrade.sh already reports these
  # as `agent_restart_skipped_attached`; mirroring the same predicate
  # here prevents the apply step from yanking the rug out from under a
  # live operator session.
  local agent session attached
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    session=""
    attached=0
    if declare -F bridge_agent_session >/dev/null 2>&1; then
      session="$(bridge_agent_session "$agent" 2>/dev/null || printf '')"
    fi
    if [[ -n "$session" ]] && declare -F bridge_tmux_session_attached_count >/dev/null 2>&1; then
      attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf '0')"
      [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
    fi
    if (( attached > 0 )); then
      bridge_warn "restart skipped for agent '$agent' (operator attached to session '$session') — restart manually after detaching"
      continue
    fi
    "$BRIDGE_BASH_BIN" "$BRIDGE_SCRIPT_DIR/bridge-agent.sh" start "$agent" >/dev/null 2>&1 \
      || bridge_warn "restart failed for agent '$agent' — operator will need to start manually"
  done < "$snapshot_path"
}

# ---------------------------------------------------------------------------
# 9. marker write (atomic, validated content)
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_marker_write() {
  local data_root="$1"
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"

  bridge_isolation_v2_migrate_mkstate
  install -d -m 0750 "$(dirname "$marker_path")" 2>/dev/null \
    || mkdir -p "$(dirname "$marker_path")"

  local tmp="${marker_path}.tmp.$$"
  {
    printf 'BRIDGE_LAYOUT=%s\n' "$(printf %q "v2")"
    printf 'BRIDGE_DATA_ROOT=%s\n' "$(printf %q "$data_root")"
  } > "$tmp"

  chmod 0640 "$tmp" || { rm -f "$tmp"; bridge_die "marker chmod failed"; }
  # Owner: leave as caller (controller). Group bit 0 prevents group write
  # already; ownership is inherited from caller process which is the
  # controller running the migration.
  mv -f "$tmp" "$marker_path" || bridge_die "marker mv failed"

  if ! bridge_isolation_v2_marker_validate "$marker_path"; then
    rm -f "$marker_path"
    bridge_die "marker validation failed after write — refusing to leave half-formed marker on disk"
  fi
}

bridge_isolation_v2_migrate_marker_remove() {
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"
  rm -f "$marker_path"
}

# ---------------------------------------------------------------------------
# 10. legacy data path enumeration (commit candidate filter)
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_legacy_data_paths() {
  local manifest_path
  manifest_path="$(bridge_isolation_v2_migrate_manifest_path)"
  [[ -f "$manifest_path" ]] || return 0
  awk -F'\t' '$8 == "ok" && $9 == "1" { print $3 }' "$manifest_path"
}

# ---------------------------------------------------------------------------
# 11. entrypoints
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_dry_run() {
  local data_root="$1"
  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"

  local active_count
  active_count="$(wc -l < "$snapshot" | tr -d ' ')"

  printf '== isolation-v2 migrate dry-run ==\n'
  printf 'data_root: %s\n' "$data_root"
  printf 'BRIDGE_LAYOUT: %s\n' "${BRIDGE_LAYOUT:-legacy}"
  printf 'active agents: %s\n' "$active_count"
  if [[ "${BRIDGE_LAYOUT:-legacy}" != "v2" ]]; then
    printf '(BRIDGE_LAYOUT currently %s — would migrate %s agents; set BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT=<path> before --apply)\n' \
      "${BRIDGE_LAYOUT:-legacy}" "$active_count"
  fi
  printf '\n-- mirror plan (mapping_id  src  dst  delete_eligible) --\n'
  bridge_isolation_v2_migrate_emit_plan "$data_root" "$snapshot"

  printf '\n-- profile_home overrides --\n'
  if bridge_isolation_v2_migrate_check_profile_home_overrides "$snapshot" "$data_root"; then
    printf '(none misaligned)\n'
  else
    printf '(see warnings above; --apply will refuse until roster is aligned)\n'
  fi
}

bridge_isolation_v2_migrate_apply() {
  local data_root="$1"
  [[ -n "$data_root" && "${data_root:0:1}" == "/" ]] \
    || bridge_die "--apply requires --data-root <absolute-path>"

  # Fail-fast on legacy installs. Operators must opt in to v2 before
  # running the mutation paths; otherwise the marker flip lands on an
  # install whose runtime is still wired to legacy paths.
  if [[ "${BRIDGE_LAYOUT:-legacy}" != "v2" ]]; then
    bridge_die "migrate apply requires BRIDGE_LAYOUT=v2 (currently: ${BRIDGE_LAYOUT:-legacy}). Set BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT=<path> in the controller environment before running the migration tool."
  fi

  if bridge_isolation_v2_active; then
    bridge_warn "v2 already active — apply is idempotent only when --data-root matches; proceeding will re-mirror."
  fi

  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  bridge_isolation_v2_migrate_capture_all_agents_snapshot
  local snapshot all_snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"
  all_snapshot="$(bridge_isolation_v2_migrate_all_agents_snapshot_path)"

  # Empty active snapshot — no-op cleanly rather than silently mirroring
  # zero rows. Operators expect a clear signal when there are no active
  # claude agents to migrate.
  if [[ ! -s "$snapshot" ]]; then
    printf '[migrate] no active claude agents to migrate; nothing to do.\n'
    return 0
  fi

  bridge_isolation_v2_migrate_self_stop_guard "$snapshot"

  if ! bridge_isolation_v2_migrate_check_profile_home_overrides "$snapshot" "$data_root"; then
    bridge_die "explicit BRIDGE_AGENT_PROFILE_HOME override(s) misaligned; see warnings above; align roster and retry"
  fi

  install -d -m 0755 "$data_root" 2>/dev/null || mkdir -p "$data_root"

  bridge_isolation_v2_migrate_orchestrate_stop "$snapshot"

  bridge_isolation_v2_migrate_ensure_groups_and_memberships "$all_snapshot" \
    || bridge_die "group ensure / membership failed"

  # v0.8.3: mirror across the FULL agent set (active + inactive). Using
  # active-only previously left inactive agents' v1 content stranded
  # while the marker still flipped — silent context loss. emit_row
  # short-circuits when legacy_src is absent so no spurious rows.
  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  if ! bridge_isolation_v2_migrate_mirror_all "$data_root" "$all_snapshot" "$manifest"; then
    bridge_warn "mirror reported failures — marker NOT written; legacy tree intact; restarting agents on legacy"
    bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"
    bridge_die "apply aborted at mirror step (manifest=$manifest)"
  fi

  if ! bridge_isolation_v2_migrate_normalize_layout "$all_snapshot" "$data_root"; then
    bridge_warn "layout normalize failed — marker NOT written; legacy tree intact; restarting agents on legacy"
    bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"
    bridge_die "apply aborted at normalize step (manifest=$manifest)"
  fi

  bridge_isolation_v2_migrate_marker_write "$data_root"

  bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"

  if ! bridge_isolation_v2_migrate_postflight_groups "$snapshot"; then
    bridge_die "post-flight group probe reported missing memberships — v2 plugin/share path will be broken; rollback before retrying"
  fi

  printf 'apply ok: marker=%s manifest=%s\n' \
    "$(bridge_isolation_v2_marker_path)" "$manifest"
}

bridge_isolation_v2_migrate_rollback() {
  # Fail-fast on legacy installs. Rollback removes the v2 marker; if the
  # install was never v2 there is nothing to roll back, and silent
  # daemon stop/restart cycles on a legacy install would surprise the
  # operator.
  if [[ "${BRIDGE_LAYOUT:-legacy}" != "v2" ]]; then
    bridge_die "migrate rollback requires BRIDGE_LAYOUT=v2 (currently: ${BRIDGE_LAYOUT:-legacy}). Rollback only makes sense on a v2-active install."
  fi

  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  local snapshot
  snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"

  bridge_isolation_v2_migrate_self_stop_guard "$snapshot"

  bridge_isolation_v2_migrate_orchestrate_stop "$snapshot"
  bridge_isolation_v2_migrate_marker_remove

  # v0.8.3: reverse the file relocation. Iterate manifest in reverse so
  # nested-dir rows undo in dependency order (children before parents).
  # Only restore rows that succeeded the original mirror+delete cycle:
  # verify_status=ok AND delete_eligible=1. Skip rows where legacy_src
  # already exists (operator likely retried) or v2_dst is gone.
  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  if [[ -f "$manifest" ]]; then
    local ts mapping_id legacy_src v2_dst bytes sha_legacy sha_v2 verify_status delete_eligible
    while IFS=$'\t' read -r ts mapping_id legacy_src v2_dst bytes sha_legacy sha_v2 verify_status delete_eligible; do
      [[ "$verify_status" == "ok" && "$delete_eligible" == "1" ]] || continue
      [[ -n "$legacy_src" && -n "$v2_dst" ]] || continue
      [[ "$legacy_src" == "$v2_dst" ]] && continue
      [[ -e "$v2_dst" ]] || continue
      [[ -e "$legacy_src" ]] && continue

      mkdir -p -- "$(dirname "$legacy_src")" 2>/dev/null || true
      if mv -- "$v2_dst" "$legacy_src" 2>/dev/null; then
        :
      elif [[ -d "$v2_dst" ]]; then
        if rsync -aHX --numeric-ids -- "$v2_dst/" "$legacy_src/" >/dev/null 2>&1; then
          rm -rf -- "$v2_dst" 2>/dev/null \
            || bridge_warn "rollback: failed to remove $v2_dst after rsync to $legacy_src"
        else
          bridge_warn "rollback: failed to reverse $v2_dst -> $legacy_src"
        fi
      else
        if rsync -aHX --numeric-ids -- "$v2_dst" "$legacy_src" >/dev/null 2>&1; then
          rm -f -- "$v2_dst" 2>/dev/null \
            || bridge_warn "rollback: failed to remove $v2_dst after rsync to $legacy_src"
        else
          bridge_warn "rollback: failed to reverse $v2_dst -> $legacy_src"
        fi
      fi
    done < <(tac "$manifest" 2>/dev/null || tail -r "$manifest" 2>/dev/null)
  fi

  bridge_isolation_v2_migrate_orchestrate_restart "$snapshot"

  printf 'rollback ok: marker removed; legacy tree intact\n'
}

bridge_isolation_v2_migrate_commit() {
  # Fail-fast on legacy installs. Commit deletes legacy paths recorded in
  # the manifest; running on a legacy install would either no-op
  # confusingly or — worse, if a stale manifest is around — delete data
  # the runtime is still reading.
  if [[ "${BRIDGE_LAYOUT:-legacy}" != "v2" ]]; then
    bridge_die "migrate commit requires BRIDGE_LAYOUT=v2 (currently: ${BRIDGE_LAYOUT:-legacy}). Commit deletes legacy data and is only safe after apply has succeeded and the marker is active."
  fi

  bridge_isolation_v2_migrate_acquire_lock

  if ! bridge_isolation_v2_active; then
    bridge_die "commit requires v2 active (marker present + valid)"
  fi

  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  [[ -f "$manifest" ]] || bridge_die "no manifest at $manifest — apply must have run first"

  local stamp tarball candidate
  stamp="$(date -u +%Y%m%dT%H%M%SZ)"
  tarball="$(bridge_isolation_v2_migrate_backup_tarball_path "$stamp")"

  local -a candidates=()
  while IFS= read -r candidate; do
    [[ -n "$candidate" && -e "$candidate" ]] || continue
    candidates+=("$candidate")
  done < <(bridge_isolation_v2_migrate_legacy_data_paths)

  if (( ${#candidates[@]} == 0 )); then
    printf 'commit: nothing to delete (no manifest rows with verify_status=ok && delete_eligible=1)\n'
    return 0
  fi

  printf 'commit candidates (%d):\n' "${#candidates[@]}"
  printf '  %s\n' "${candidates[@]}"

  if [[ "${BRIDGE_ISOLATION_V2_MIGRATE_YES:-0}" != "1" ]]; then
    bridge_die "refusing to delete without --yes"
  fi

  # Backup tarball first.
  if command -v zstd >/dev/null 2>&1; then
    tar --zstd -cf "$tarball" "${candidates[@]}" 2>/dev/null \
      || bridge_die "backup tarball creation failed"
  else
    tarball="${tarball%.zst}"
    tar -cf "$tarball" "${candidates[@]}" 2>/dev/null \
      || bridge_die "backup tarball creation failed"
  fi
  chmod 0640 "$tarball" || true

  # Delete.
  local cand
  for cand in "${candidates[@]}"; do
    rm -rf -- "$cand" || bridge_warn "delete failed: $cand"
  done

  printf 'commit ok: deleted %d path(s); backup at %s\n' "${#candidates[@]}" "$tarball"
}

bridge_isolation_v2_migrate_status() {
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"
  printf 'marker: %s\n' "$marker_path"
  if [[ -f "$marker_path" ]]; then
    if bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
      printf 'marker_valid: yes\n'
    else
      printf 'marker_valid: no\n'
    fi
    printf '%s\n' '---'
    # Issue #418 codex r2 item 2: per-key value-level redaction (not just
    # key-level). The earlier grep allowlist filtered keys but still
    # echoed arbitrary `=.*` values verbatim — a tampered marker with
    # `BRIDGE_DATA_ROOT=$(rm -rf /)` would surface attacker bytes in
    # operator-visible output. Validate each value against an allowlist
    # regex; drop any line whose value does not match. If nothing
    # survives, fall back to `invalid-marker(redacted)`.
    python3 - "$marker_path" <<'PY' || printf 'invalid-marker(redacted)\n'
import re
import sys

path = sys.argv[1]
allowed = {
    "BRIDGE_LAYOUT_MARKER_VERSION": r'^[0-9]+$',
    "BRIDGE_LAYOUT": r'^(legacy|v2)$',
    # Path values: alphanumerics plus `_./-` only; explicitly excludes
    # `$`, backticks, spaces, and other shell metacharacters.
    "BRIDGE_DATA_ROOT": r'^[A-Za-z0-9_./-]+$',
    # ISO-8601-ish timestamp (digits, `T`, `:`, `+`, `-`, `Z`).
    "BRIDGE_LAYOUT_MARKER_CREATED_AT": r'^[0-9T:+\-Z]+$',
}
emitted = False
try:
    with open(path) as f:
        for line in f:
            line = line.rstrip("\n")
            if "=" not in line:
                continue
            key, _, value = line.partition("=")
            if key not in allowed:
                continue
            if not re.match(allowed[key], value):
                continue
            print(f"{key}={value}")
            emitted = True
except FileNotFoundError:
    pass
if not emitted:
    print("invalid-marker(redacted)")
PY
    printf '%s\n' '---'
  else
    printf 'marker_valid: absent\n'
  fi
  printf 'isolation_v2_active: %s\n' \
    "$(bridge_isolation_v2_active && echo yes || echo no)"

  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  if [[ -f "$manifest" ]]; then
    local total ok delete_elig
    total="$(wc -l < "$manifest" | tr -d ' ')"
    ok="$(awk -F'\t' '$8 == "ok"' "$manifest" | wc -l | tr -d ' ')"
    delete_elig="$(awk -F'\t' '$8 == "ok" && $9 == "1"' "$manifest" | wc -l | tr -d ' ')"
    printf 'manifest: %s  total=%s  ok=%s  delete_eligible=%s\n' \
      "$manifest" "$total" "$ok" "$delete_elig"
  else
    printf 'manifest: (none)\n'
  fi
}

# ---------------------------------------------------------------------------
# 11b. Upgrade-integrated wrapper
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_apply_for_upgrade() {
  # Wrapper called from `bridge-upgrade.sh` between RECONCILE and
  # APPLY_JSON. Differs from `bridge_isolation_v2_migrate_apply` in that
  # it:
  #   1. Skips no-op when v2 is already active (existing marker valid +
  #      agent-class memberships in place) — re-running `agent-bridge
  #      upgrade --apply` after a successful migration is a no-op.
  #   2. Auto-derives BRIDGE_DATA_ROOT (defaults to TARGET_ROOT —
  #      markerless installs keep the existing canonical path).
  #   3. Runs in unattended mode (no --yes prompt; the operator has
  #      already confirmed via `agent-bridge upgrade --apply`).
  #   4. Emits a single JSON object on stdout summarizing the outcome,
  #      and writes detailed per-step state under
  #      $BRIDGE_STATE_DIR/migration/isolation-v2/.
  #
  # Args:
  #   --target-root <path>   absolute path to the live bridge home (TARGET_ROOT)
  #   --json                 (currently ignored; output is always JSON)
  #
  # Exit code:
  #   0 — applied or skipped (idempotent)
  #   non-zero — fatal; caller should die with the JSON body's
  #              `last_error` field as remediation.
  local target_root=""
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --target-root) target_root="$2"; shift 2 ;;
      --json) shift ;;  # accepted for forward-compat
      *) bridge_warn "apply_for_upgrade: unknown arg: $1"; return 2 ;;
    esac
  done
  [[ -n "$target_root" && "${target_root:0:1}" == "/" ]] || {
    bridge_warn "apply_for_upgrade: --target-root <abs-path> required"
    return 2
  }

  local data_root="${BRIDGE_DATA_ROOT:-$target_root}"
  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path 2>/dev/null || \
    printf '%s/state/layout-marker.sh' "$target_root")"

  # Idempotent skip: marker already present + valid -> already migrated.
  if [[ -f "$marker_path" ]] \
      && bridge_isolation_v2_marker_validate "$marker_path" 2>/dev/null; then
    printf '{"mode":"isolation-v2-migrate","skipped":true,"reason":"marker-present","marker":"%s","data_root":"%s"}\n' \
      "$marker_path" "$data_root"
    return 0
  fi

  # Privilege preflight before any mutation.
  if ! bridge_isolation_v2_privilege_preflight; then
    local err
    err='isolation-v2 migration requires root or passwordless sudo'
    printf '{"mode":"isolation-v2-migrate","status":"error","reason":"privilege","last_error":"%s","remediation":"rerun agent-bridge upgrade --apply as root or configure passwordless sudo","no_v080_code_installed":"yes"}\n' \
      "$err"
    return 1
  fi

  # Lock + capture both snapshots. Active = stop/restart subset; All =
  # group/perm/marker subset.
  bridge_isolation_v2_migrate_acquire_lock
  bridge_isolation_v2_migrate_capture_active_snapshot
  bridge_isolation_v2_migrate_capture_all_agents_snapshot

  local active_snapshot all_snapshot
  active_snapshot="$(bridge_isolation_v2_migrate_active_snapshot_path)"
  all_snapshot="$(bridge_isolation_v2_migrate_all_agents_snapshot_path)"

  local active_count all_count
  active_count="$(wc -l < "$active_snapshot" 2>/dev/null | tr -d ' ' || printf 0)"
  all_count="$(wc -l < "$all_snapshot" 2>/dev/null | tr -d ' ' || printf 0)"

  # Set BRIDGE_LAYOUT=v2 + BRIDGE_DATA_ROOT in the function-local env so
  # the existing apply path's preconditions are satisfied. Caller env
  # is unaffected.
  local _saved_layout="${BRIDGE_LAYOUT:-}"
  local _saved_data_root="${BRIDGE_DATA_ROOT:-}"
  BRIDGE_LAYOUT="v2"
  BRIDGE_DATA_ROOT="$data_root"
  export BRIDGE_LAYOUT BRIDGE_DATA_ROOT

  local err_log
  err_log="$(bridge_isolation_v2_migrate_state_dir)/last-error.json"

  # Run the existing apply pipeline. We do NOT call
  # bridge_isolation_v2_migrate_apply directly because it acquires its
  # own lock (we already hold one) and re-captures the active snapshot;
  # instead inline the post-lock steps. This stays within the
  # established review boundaries — same primitives, same order.
  install -d -m 0755 "$data_root" 2>/dev/null || mkdir -p "$data_root"

  if [[ "$active_count" -gt 0 ]]; then
    bridge_isolation_v2_migrate_self_stop_guard "$active_snapshot" || {
      printf '{"mode":"isolation-v2-migrate","status":"error","reason":"self-stop-guard","last_error":"caller is one of the active agents — re-run from an out-of-band controller shell","no_v080_code_installed":"yes"}\n' >"$err_log"
      cat "$err_log"
      return 1
    }
    bridge_isolation_v2_migrate_orchestrate_stop "$active_snapshot"
  fi

  # Group + membership ensure for the FULL agent set, not active-only.
  if ! bridge_isolation_v2_migrate_ensure_groups_and_memberships "$all_snapshot"; then
    {
      printf '{"mode":"isolation-v2-migrate","status":"error","reason":"groups-ensure",'
      printf '"last_error":"group create / membership ensure failed",'
      printf '"remediation":"check sudo / dseditgroup permissions and rerun",'
      printf '"no_v080_code_installed":"yes"}\n'
    } >"$err_log"
    [[ "$active_count" -gt 0 ]] && bridge_isolation_v2_migrate_orchestrate_restart "$active_snapshot"
    cat "$err_log"
    return 1
  fi

  # Mirror legacy -> v2 paths for ALL agents (active + inactive). v0.8.3:
  # previously this used $active_snapshot, which meant inactive agents'
  # files (CLAUDE.md, memory/, .claude/, etc.) were never relocated —
  # marker flipped, runtime pointed at empty v2 workdir, silent context
  # loss. emit_row in emit_plan already returns 0 when legacy_src is
  # absent, so this is a no-op for agents with nothing to mirror.
  local manifest
  manifest="$(bridge_isolation_v2_migrate_manifest_path)"
  if [[ "$all_count" -gt 0 ]]; then
    if ! bridge_isolation_v2_migrate_mirror_all "$data_root" "$all_snapshot" "$manifest"; then
      {
        printf '{"mode":"isolation-v2-migrate","status":"error","reason":"mirror",'
        printf '"last_error":"mirror reported failures","manifest":"%s",' "$manifest"
        printf '"remediation":"inspect manifest verify_status column and rerun",'
        printf '"no_v080_code_installed":"yes"}\n'
      } >"$err_log"
      [[ "$active_count" -gt 0 ]] && bridge_isolation_v2_migrate_orchestrate_restart "$active_snapshot"
      cat "$err_log"
      return 1
    fi
  else
    : > "$manifest"
  fi

  # ACL scrub + chgrp+setgid+chmod on data_root tree (the all-snapshot
  # writes correct group ownership for every agent root, mirrored or
  # not). Run scrub first so leftover v1 ACLs don't override the new
  # POSIX group bits.
  #
  # r2 review fix: scrub failures are no longer swallowed. A failed
  # scrub means leftover ACLs may still override the v2 group bits —
  # writing the global marker on top of that would silently break the
  # isolation contract. Treat as fatal and bail BEFORE the marker is
  # advanced; idempotent re-run remains safe because no new state was
  # written past this point.
  if ! bridge_isolation_v2_acl_scrub "$data_root"; then
    {
      printf '{"mode":"isolation-v2-migrate","status":"error","reason":"acl-scrub",'
      printf '"last_error":"ACL scrub failed at %s; marker NOT advanced",' "$data_root"
      printf '"remediation":"inspect bridge_warn output (chmod -P -N / setfacl -bR rc) and rerun once the underlying ACL state is correctable",'
      printf '"no_v080_code_installed":"yes"}\n'
    } >"$err_log"
    [[ "$active_count" -gt 0 ]] && bridge_isolation_v2_migrate_orchestrate_restart "$active_snapshot"
    cat "$err_log"
    return 1
  fi
  if ! bridge_isolation_v2_migrate_normalize_layout "$all_snapshot" "$data_root"; then
    {
      printf '{"mode":"isolation-v2-migrate","status":"error","reason":"normalize",'
      printf '"last_error":"layout normalize failed","manifest":"%s",' "$manifest"
      printf '"remediation":"verify chgrp/chmod permissions on %s and rerun",' "$data_root"
      printf '"no_v080_code_installed":"yes"}\n'
    } >"$err_log"
    [[ "$active_count" -gt 0 ]] && bridge_isolation_v2_migrate_orchestrate_restart "$active_snapshot"
    cat "$err_log"
    return 1
  fi

  # Per-agent completion markers — all_snapshot, one marker each.
  # macOS supplemental group cache: dseditgroup-driven membership only
  # takes effect after re-login, so flag every Darwin-side agent.
  local relogin_flag=0
  [[ "$(uname)" == "Darwin" ]] && relogin_flag=1
  local agent agent_grp
  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    agent_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
    [[ -n "$agent_grp" ]] || continue
    bridge_isolation_v2_migrate_per_agent_marker_write \
      "$agent" "$agent_grp" "$relogin_flag" || true
  done < "$all_snapshot"

  # Global marker only after all per-agent markers landed.
  if ! bridge_isolation_v2_migrate_all_per_agent_markers_present "$all_snapshot"; then
    {
      printf '{"mode":"isolation-v2-migrate","status":"error","reason":"per-agent-marker-incomplete",'
      printf '"last_error":"one or more per-agent markers missing under %s/isolation-v2/agents/",' \
        "$(bridge_isolation_v2_migrate_state_dir)"
      printf '"remediation":"inspect bridge_warn output and rerun",'
      printf '"no_v080_code_installed":"yes"}\n'
    } >"$err_log"
    [[ "$active_count" -gt 0 ]] && bridge_isolation_v2_migrate_orchestrate_restart "$active_snapshot"
    cat "$err_log"
    return 1
  fi

  bridge_isolation_v2_migrate_marker_write "$data_root"

  if [[ "$active_count" -gt 0 ]]; then
    bridge_isolation_v2_migrate_orchestrate_restart "$active_snapshot"
  fi

  # Success — JSON. relogin field surfaces the macOS supplemental-group
  # cache caveat to the upgrade output so operators don't get
  # confusing "permission denied" until they re-login.
  printf '{"mode":"isolation-v2-migrate","status":"applied","data_root":"%s","manifest":"%s","active_agents":%s,"all_agents":%s,"migration_requires_relogin":%s}\n' \
    "$data_root" "$manifest" "$active_count" "$all_count" \
    "$([[ "$relogin_flag" -eq 1 ]] && printf 'true' || printf 'false')"

  # Restore caller env (no-op when caller had nothing).
  if [[ -z "$_saved_layout" ]]; then unset BRIDGE_LAYOUT; else BRIDGE_LAYOUT="$_saved_layout"; fi
  if [[ -z "$_saved_data_root" ]]; then unset BRIDGE_DATA_ROOT; else BRIDGE_DATA_ROOT="$_saved_data_root"; fi
  return 0
}

# ---------------------------------------------------------------------------
# 12. CLI dispatch
# ---------------------------------------------------------------------------

bridge_isolation_v2_migrate_cli() {
  local sub="${1:-}"
  shift || true

  case "$sub" in
    dry-run)
      local data_root=""
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --data-root) data_root="$2"; shift 2 ;;
          *) bridge_die "unknown dry-run option: $1" ;;
        esac
      done
      [[ -n "$data_root" ]] || bridge_die "Usage: agent-bridge migrate isolation-v2 dry-run --data-root <path>"
      bridge_isolation_v2_migrate_dry_run "$data_root"
      ;;
    apply)
      local data_root=""
      local yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --data-root) data_root="$2"; shift 2 ;;
          --yes) yes=1; shift ;;
          *) bridge_die "unknown apply option: $1" ;;
        esac
      done
      (( yes == 1 )) || bridge_die "Usage: agent-bridge migrate isolation-v2 apply --data-root <path> --yes"
      bridge_isolation_v2_migrate_apply "$data_root"
      ;;
    rollback)
      local yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1; shift ;;
          *) bridge_die "unknown rollback option: $1" ;;
        esac
      done
      (( yes == 1 )) || bridge_die "Usage: agent-bridge migrate isolation-v2 rollback --yes"
      bridge_isolation_v2_migrate_rollback
      ;;
    commit)
      local yes=0
      while [[ $# -gt 0 ]]; do
        case "$1" in
          --yes) yes=1; shift ;;
          *) bridge_die "unknown commit option: $1" ;;
        esac
      done
      (( yes == 1 )) || bridge_die "Usage: agent-bridge migrate isolation-v2 commit --yes"
      BRIDGE_ISOLATION_V2_MIGRATE_YES=1 bridge_isolation_v2_migrate_commit
      ;;
    status)
      # status is read-only and works on any layout; reject extra
      # positional args so typos like `status --json` (unsupported) don't
      # silently succeed.
      if (( $# > 0 )); then
        bridge_die "migrate isolation-v2 status: unexpected extra args: $*"
      fi
      bridge_isolation_v2_migrate_status
      ;;
    ""|-h|--help|help)
      cat <<'USAGE'
Usage: agent-bridge migrate isolation-v2 <subcommand> [options]
Subcommands:
  dry-run --data-root <path>       Print the legacy→v2 mirror plan + profile_home preflight (no mutation).
  apply   --data-root <path> --yes Stop active agents+daemon, mirror, ensure groups, write marker, restart.
  rollback --yes                   Stop, remove marker, restart on legacy. Idempotent on absent marker.
  commit  --yes                    Tar-zst backup + delete legacy paths recorded in manifest as
                                   verify_status=ok && delete_eligible=1.
  status                           Print marker + manifest summary.

Notes:
  - apply/rollback refuse when invoked from inside an Agent Bridge agent
    session whose own id is in the active snapshot (self-stop guard).
  - Run from an out-of-band controller shell with sudo available.
USAGE
      ;;
    *)
      bridge_die "unknown isolation-v2 subcommand: $sub"
      ;;
  esac
}
