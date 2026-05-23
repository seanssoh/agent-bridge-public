#!/usr/bin/env bash
# bridge-layout-resolver.sh — explicit resolver for the v2/legacy layout
# decision. Replaces the implicit "BRIDGE_LAYOUT defaults to legacy" rule
# with a state machine that distinguishes:
#
#   - env (explicit BRIDGE_LAYOUT/BRIDGE_DATA_ROOT override, valid)
#   - marker (state/layout-marker.sh present and valid)
#   - missing-marker(existing) — markerless install with clear evidence of
#     prior use (existing legacy install). MUST stay legacy.
#   - fresh-install-candidate — markerless install with no evidence. NOT
#     active until `agent-bridge init` writes the marker.
#   - invalid-marker(fallback) — marker present but rejected by validator.
#     Falls back to missing-marker(existing) semantics + warn.
#
# This module is sourced from bridge-lib.sh after bridge-core.sh and
# bridge-marker-bootstrap.sh, before bridge-isolation-v2.sh, so the resolver
# result is in the environment when bridge-isolation-v2.sh snapshots
# BRIDGE_LAYOUT/BRIDGE_DATA_ROOT.
#
# The resolver is read-only by contract: it never writes the marker, never
# creates directories, never mutates state files. Marker writes are the
# responsibility of `agent-bridge init` (fresh install) or
# `agent-bridge migrate isolation-v2 apply` (existing legacy install).
# shellcheck shell=bash disable=SC2034

# ---------------------------------------------------------------------------
# Public state — set by bridge_resolve_layout. Callers read these.
# ---------------------------------------------------------------------------

# Resolver source classification. One of:
#   env, marker, missing-marker(existing), fresh-install-candidate,
#   invalid-marker(fallback)
BRIDGE_LAYOUT_SOURCE="${BRIDGE_LAYOUT_SOURCE:-}"

# When the env override was partial (BRIDGE_LAYOUT set but BRIDGE_DATA_ROOT
# missing/invalid for v2), this lists the variables that were ignored. Status
# output surfaces this so operators can fix their export.
BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV="${BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV:-}"

# For fresh-install-candidate state, a default BRIDGE_DATA_ROOT computed from
# BRIDGE_HOME. Init reads this when --data-root is not specified. NOT
# exported as BRIDGE_DATA_ROOT — that would make bridge_isolation_v2_active
# return true before the marker is written.
BRIDGE_DEFAULT_DATA_ROOT="${BRIDGE_DEFAULT_DATA_ROOT:-}"

# ---------------------------------------------------------------------------
# Existing-install evidence
# ---------------------------------------------------------------------------

bridge_layout_resolver_has_existing_evidence() {
  # Returns 0 (existing) when ANY of:
  #   - state/agents/ exists and is non-empty
  #   - state/tasks.db exists
  #   - agent-roster.local.sh exists
  #   - any agents/<x>/ directory is non-empty (real agent home)
  #   - state/runtime/ or state/cron/ have content (active controller state)
  #
  # An empty $BRIDGE_HOME/state directory is NOT evidence — bridge_init_dirs
  # creates it on roster load, so a probe like `agent-bridge status` on a
  # fresh install would otherwise classify it as existing.
  local home="${BRIDGE_HOME:-$HOME/.agent-bridge}"
  local state="${BRIDGE_STATE_DIR:-$home/state}"

  [[ -f "$state/tasks.db" ]] && return 0
  [[ -f "$home/agent-roster.local.sh" ]] && return 0

  if [[ -d "$state/agents" ]]; then
    if compgen -G "$state/agents/*" >/dev/null 2>&1; then
      return 0
    fi
  fi

  # File-only probe: empty auto-created subdirs (e.g. state/cron/workers/) must NOT trip evidence — same class as PR #897.
  if [[ -d "$state/runtime" ]]; then
    if find "$state/runtime" -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  fi
  if [[ -d "$state/cron" ]]; then
    if find "$state/cron" -mindepth 1 -type f -print -quit 2>/dev/null | grep -q .; then
      return 0
    fi
  fi

  if [[ -d "$home/agents" ]]; then
    local entry name
    for entry in "$home/agents"/*/; do
      [[ -d "$entry" ]] || continue
      # Skip non-agent reserved entries — names starting with `_` or `.`
      # are documentation / template dirs (e.g. `_template/` for fresh
      # agent scaffolding, `_shared/` for cross-agent assets) that ship
      # with every fresh source checkout. Clean install would otherwise
      # be misclassified as `markerless(existing-install)` and hard-die
      # on first bootstrap.
      name="$(basename "${entry%/}")"
      case "$name" in
        _*|.*) continue ;;
      esac
      # Non-empty agent home directory (CLAUDE.md, settings.json, etc.).
      if compgen -G "$entry"'*' >/dev/null 2>&1; then
        return 0
      fi
    done
  fi

  return 1
}

# ---------------------------------------------------------------------------
# Env override validation
# ---------------------------------------------------------------------------

bridge_layout_resolver_validate_env() {
  # Reads $BRIDGE_LAYOUT / $BRIDGE_DATA_ROOT from the calling environment.
  # Sets BRIDGE_LAYOUT_SOURCE / BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV when the
  # override is recognized.
  #
  # Returns 0 when env is a valid explicit override (and exports are kept),
  # 1 when env is partial/invalid (and exports are cleaned).
  local layout="${BRIDGE_LAYOUT:-}"
  local data_root="${BRIDGE_DATA_ROOT:-}"

  case "$layout" in
    "")
      # No env override at all — let marker / evidence flow handle it.
      return 1
      ;;
    v2)
      if [[ -z "$data_root" ]]; then
        # Partial — ignore the v2 hint, fall through.
        BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV="BRIDGE_LAYOUT"
        unset BRIDGE_LAYOUT
        return 1
      fi
      if [[ "${data_root:0:1}" != "/" ]]; then
        bridge_warn "BRIDGE_DATA_ROOT must be absolute (got '$data_root') — ignoring env override"
        BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV="BRIDGE_LAYOUT,BRIDGE_DATA_ROOT"
        unset BRIDGE_LAYOUT
        unset BRIDGE_DATA_ROOT
        return 1
      fi
      BRIDGE_LAYOUT_SOURCE="env"
      return 0
      ;;
    legacy|v1)
      # S2 stale-env unblock: if a valid v2 marker exists, the env value
      # is a leftover from pre-v0.8.0 (e.g., an old shell rc, a stale
      # tmux session, an operator script). Demote the hard-die to a
      # warning and let the marker step run — the marker is authoritative
      # for installs already migrated to v2. This is the codex-flagged
      # operator-visible blocker (audit doc B17) where even the resolver
      # consensus check trips on its own.
      #
      # Codex r1 catch (#904): only demote when the marker actually
      # pins BRIDGE_LAYOUT=v2. A marker still pinned to v1 (un-migrated
      # install) must fall through to the hard-die without the false
      # "preferring marker" warning — that warning is part of the
      # operator-visible contract and only correct when the marker
      # is v2.
      local _stale_marker_path
      _stale_marker_path="$(bridge_isolation_v2_marker_path 2>/dev/null || true)"
      if [[ -n "$_stale_marker_path" && -f "$_stale_marker_path" ]] \
         && bridge_isolation_v2_marker_validate "$_stale_marker_path" >/dev/null 2>&1; then
        local _marker_layout
        _marker_layout="$(
          grep -E '^[[:space:]]*BRIDGE_LAYOUT[[:space:]]*=' "$_stale_marker_path" 2>/dev/null \
            | tail -1 \
            | sed -E "s/^[[:space:]]*BRIDGE_LAYOUT[[:space:]]*=//; s/^[\"']//; s/[\"']$//"
        )"
        if [[ "$_marker_layout" == "v2" ]]; then
          # Patch #4798: gate the warning behind a once-per-process
          # sentinel. When the stale BRIDGE_LAYOUT lives at the tmux
          # server-env level (operator hit by a pre-PR-#926 install
          # that leaked it via setenv -g), every spawned child inherits
          # the value and the resolver re-fires the warning for every
          # `agent-bridge` / `agb` call — drowning the operator in
          # noise. Export the sentinel so any child shell that
          # re-sources bridge-lib.sh inside the same process tree
          # stays quiet too; the parent upgrade flow has a one-shot
          # `tmux setenv -u -g` cleanup that actually removes the
          # server-level leak (bridge-upgrade.sh).
          if [[ -z "${_BRIDGE_LAYOUT_STALE_ENV_WARNED:-}" ]]; then
            bridge_warn "BRIDGE_LAYOUT=${layout} is a stale pre-v0.8.0 env override; marker ${_stale_marker_path} pins this install to v2. Preferring marker. To silence permanently: (1) \`unset BRIDGE_LAYOUT\` in your shell rc; (2) stop and restart the bridge daemon from a clean shell (\`bash bridge-daemon.sh stop\` then \`bash bridge-daemon.sh start\`) so the next pane launch envelope is clean; (3) restart any long-running agent panes that pre-date this fix — those panes inherited the stale value into their own process tree and a daemon restart does NOT reach back to clear it (use \`agb agent restart <name>\` per agent, or restart all panes via \`bash bridge-start.sh <name> --replace\`). A leftover tmux server-level leak is cleared by \`agent-bridge upgrade --apply\`. Issue #1101 has the full propagation chain."
            export _BRIDGE_LAYOUT_STALE_ENV_WARNED=1
          fi
          BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV="BRIDGE_LAYOUT (stale ${layout} override; marker=v2)"
          unset BRIDGE_LAYOUT
          unset BRIDGE_DATA_ROOT
          return 1
        fi
      fi
      # No valid v2 marker on disk — operator hasn't migrated. Keep the
      # original hard-die so the migration prompt surfaces.
      bridge_die "Agent Bridge v0.8.0 requires isolation-v2 (POSIX group + setgid).
  current_layout=${layout}
  remediation: run \`agent-bridge upgrade --apply\` to migrate, or roll back to v0.7.x.
  background: ACL-based isolation (v1) was removed in v0.8.0. See https://github.com/SYRS-AI/agent-bridge-public/blob/main/docs/isolation-migration-guide.md for details."
      ;;
    *)
      bridge_die "Agent Bridge v0.8.0 requires isolation-v2 (POSIX group + setgid).
  current_layout=${layout}
  remediation: unset BRIDGE_LAYOUT or set BRIDGE_LAYOUT=v2 (only accepted value).
  background: ACL-based isolation (v1) was removed in v0.8.0. See https://github.com/SYRS-AI/agent-bridge-public/blob/main/docs/isolation-migration-guide.md for details."
      ;;
  esac
}

# ---------------------------------------------------------------------------
# T3 bypass handshake — verifies the upgrade migration is actually the
# entity that armed the resolver bypass. Both parts have to match:
#
#   1. BRIDGE_LAYOUT_RESOLVER_BYPASS starts with `upgrade-migrate:<nonce>`
#      so a static env value (e.g. someone documenting the var in a
#      shell rc) cannot pose as the upgrader.
#   2. Current process is a descendant of BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID
#      (the upgrade.sh's $$). A leaked env crossing into a sibling
#      process tree therefore fails — only the upgrade chain wins.
#
# Returns 0 when the bypass is honored, non-zero otherwise. The non-zero
# case falls through to normal resolution (and the v0.8.0 fail-fast).
# ---------------------------------------------------------------------------

_bridge_layout_resolver_bypass_active() {
  local val="${BRIDGE_LAYOUT_RESOLVER_BYPASS:-}"
  [[ "$val" == upgrade-migrate:* ]] || return 1
  # Reject the empty-suffix form so a stale "upgrade-migrate:" without
  # a nonce body cannot disarm the resolver.
  [[ "${val#upgrade-migrate:}" != "" ]] || return 1
  # v0.8.6 hotfix: `agent-bridge` accepted as owner in addition to
  # `bridge-upgrade.sh` / `bridge-migrate.sh` so the public CLI wrapper
  # can arm the bypass before `bridge-lib.sh` source for `upgrade` /
  # `migrate` subcommands. Pre-hotfix the wrapper would source
  # `bridge-lib.sh` (firing the resolver) and die at the v0.8.0
  # fail-fast on a markerless v0.7.x install before its dispatch
  # `case` could exec the underlying scripts that arm the bypass
  # themselves. The descendant-walk in `_bridge_layout_resolver_handshake_check`
  # still gates on the owner-PID, so a leaked env crossing into a
  # sibling process tree fails as before.
  _bridge_layout_resolver_handshake_check "bridge-upgrade.sh" "bridge-migrate.sh" "agent-bridge"
}

# Fresh-install bypass — same handshake shape as the upgrade bypass but
# armed by `bridge-init.sh` / `bridge-bootstrap.sh`. Differs in two ways:
#   - The bypass only activates AFTER evidence-based classification, so an
#     existing-install (any of: tasks.db, agent-roster.local.sh, populated
#     state/agents, populated agents/<x>) still trips the v0.8.0 fail-fast
#     and sends the operator to `agent-bridge upgrade --apply`.
#   - The bypass does not set BRIDGE_LAYOUT/BRIDGE_DATA_ROOT itself; the
#     init script is responsible for writing the v2 marker and re-resolving.
# This keeps the resolver read-only by contract — the bypass just defers
# the die so the init flow gets a chance to write the marker before the
# next boot takes the marker branch.
_bridge_layout_resolver_fresh_install_bypass_active() {
  local val="${BRIDGE_LAYOUT_RESOLVER_BYPASS:-}"
  [[ "$val" == fresh-install:* ]] || return 1
  [[ "${val#fresh-install:}" != "" ]] || return 1
  # `agent-bridge` accepted in addition to the underlying scripts because the
  # public CLI wrapper sources bridge-lib.sh (which fires the resolver)
  # BEFORE it execs to bridge-init.sh / bridge-bootstrap.sh. The wrapper
  # arms the bypass for fresh-install-creating subcommands so that first
  # resolver call passes; subsequent boots inside bridge-init.sh /
  # bridge-bootstrap.sh re-arm with their own argv and still match.
  _bridge_layout_resolver_handshake_check "bridge-init.sh" "bridge-bootstrap.sh" "agent-bridge"
}

_bridge_layout_resolver_handshake_check() {
  # Shared owner-PID + descendant walk used by both the upgrade-migrate
  # and fresh-install bypasses. Accepts one or more allowed argv-substring
  # patterns for the owner process command. Returns 0 when the handshake
  # passes, 1 otherwise.
  local owner_pid="${BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID:-}"
  [[ -n "$owner_pid" ]] || return 1
  # Owner pid must be a positive integer >= 2. Anything else is hostile —
  # PID 1 (init) is the universal ancestor of every process, so accepting
  # it as owner would let a forged env pass the descendant walk trivially.
  [[ "$owner_pid" =~ ^[0-9]+$ ]] || return 1
  (( owner_pid >= 2 )) || return 1
  # Owner pid must point at a live process whose command line reveals it
  # really IS one of the allowed callers. A leaked env crossing into
  # another process tree (or a re-used PID after the owner exited) fails
  # this check because the unrelated process's argv won't match. Both ps
  # variants are tried (Linux ps -o args=, macOS ps -o command=) so the
  # check works on both platforms.
  local owner_cmd=""
  owner_cmd="$(ps -o args= -p "$owner_pid" 2>/dev/null | head -n 1)"
  if [[ -z "$owner_cmd" ]]; then
    owner_cmd="$(ps -o command= -p "$owner_pid" 2>/dev/null | head -n 1)"
  fi
  [[ -n "$owner_cmd" ]] || return 1
  local pat matched=0
  for pat in "$@"; do
    if [[ "$owner_cmd" == *"$pat"* ]]; then
      matched=1
      break
    fi
  done
  (( matched == 1 )) || return 1
  # Caller must be a descendant of owner_pid. Walk up the process tree
  # bounded to 64 levels — well above any realistic shell-nesting depth
  # and prevents a pathological tree from trapping us in a loop.
  local p=$$ steps=0
  while (( steps < 64 )); do
    if [[ "$p" == "$owner_pid" ]]; then
      return 0
    fi
    [[ "$p" == "1" || "$p" == "0" ]] && return 1
    local parent
    parent="$(ps -o ppid= -p "$p" 2>/dev/null | tr -d ' ')"
    [[ -n "$parent" && "$parent" != "0" ]] || return 1
    [[ "$parent" =~ ^[0-9]+$ ]] || return 1
    p="$parent"
    steps=$((steps + 1))
  done
  return 1
}

# ---------------------------------------------------------------------------
# Main resolver
# ---------------------------------------------------------------------------

bridge_resolve_layout() {
  # Decides BRIDGE_LAYOUT_SOURCE (and therefore whether v2 is active).
  # Inputs (in order of precedence):
  #   1. explicit env: BRIDGE_LAYOUT + BRIDGE_DATA_ROOT
  #   2. marker file at $BRIDGE_LAYOUT_MARKER_DIR/layout-marker.sh
  #   3. existing-install evidence -> missing-marker(existing) (legacy)
  #   4. otherwise -> fresh-install-candidate (legacy until init)
  #
  # The marker_load function (already invoked from bridge-marker-bootstrap.sh)
  # exports BRIDGE_LAYOUT/BRIDGE_DATA_ROOT when a valid marker is read. We
  # detect that here by comparing the env state to the pre-resolver snapshot.

  # T3 bypass: `agent-bridge upgrade --apply` from a v0.7.x install must be
  # able to source the v0.8.0 lib stack to reach the migration tool, but
  # the install is by definition still markerless at that point. Without
  # this bypass the resolver would fail-fast before the migration ever
  # runs (T1 ↔ T3 chicken-and-egg). The bypass is opt-in via env var,
  # never via marker, so a stale runtime cannot accidentally enter the
  # deferred state. Caller (bridge-upgrade.sh) is responsible for
  # invoking the migration tool itself; once the migration writes the v2
  # marker, subsequent boots take the normal `marker` source branch and
  # this bypass becomes a no-op.
  #
  # r2 review fix: the bypass is gated behind a process-tree handshake.
  # Just owning the env var is not sufficient — the resolver requires
  # the value to start with `upgrade-migrate:<nonce>` and the current
  # process to be a descendant of BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID
  # (set by bridge-upgrade.sh to its own $$). A leaked / copied env that
  # crosses out of the upgrade process tree therefore fails the check,
  # restoring the v0.8.0 hard-cut for everything but the upgrade flow.
  if _bridge_layout_resolver_bypass_active; then
    BRIDGE_LAYOUT_SOURCE="upgrade-migrate-deferred"
    BRIDGE_DEFAULT_DATA_ROOT="${BRIDGE_HOME:-$HOME/.agent-bridge}/data"
    return 0
  fi

  local marker_path
  marker_path="$(bridge_isolation_v2_marker_path)"

  # Step 1 — env override. If the caller exported a valid BRIDGE_LAYOUT
  # before sourcing bridge-lib.sh, honor it; downstream marker_load will
  # not be invoked (env wins).
  if bridge_layout_resolver_validate_env; then
    BRIDGE_LAYOUT_SOURCE="env"
    return 0
  fi

  # Step 2 — explicit marker_load. We deliberately invoke this here (not via
  # auto-load in bridge-marker-bootstrap.sh) so that values it exports are
  # attributable to source=marker, not source=env.
  if [[ -f "$marker_path" ]]; then
    if bridge_isolation_v2_marker_validate "$marker_path"; then
      bridge_isolation_v2_marker_load
      if [[ "${BRIDGE_LAYOUT:-}" == "v2" && -n "${BRIDGE_DATA_ROOT:-}" ]]; then
        BRIDGE_LAYOUT_SOURCE="marker"
        return 0
      fi
      if [[ "${BRIDGE_LAYOUT:-}" == "legacy" || "${BRIDGE_LAYOUT:-}" == "v1" ]]; then
        # v0.8.0 hard-cut: a marker pinning the install to the legacy/v1
        # layout is no longer a valid runtime state. The migration tool
        # (T3) rewrites the marker to v2; surface the same remediation as
        # the env-override path so operators don't silently run on a
        # half-removed code path.
        bridge_die "Agent Bridge v0.8.0 requires isolation-v2 (POSIX group + setgid).
  current_layout=${BRIDGE_LAYOUT}
  marker=${marker_path}
  remediation: run \`agent-bridge upgrade --apply\` to migrate, or roll back to v0.7.x.
  background: ACL-based isolation (v1) was removed in v0.8.0. See https://github.com/SYRS-AI/agent-bridge-public/blob/main/docs/isolation-migration-guide.md for details."
      fi
    fi
    # Marker is on disk but failed validation — bridge_warn already fired
    # in marker_validate. Fall through to evidence-based classification
    # with invalid-marker(fallback) source so status output is honest.
    BRIDGE_LAYOUT_SOURCE="invalid-marker(fallback)"
  fi

  # Step 3/4 — no env, no valid marker. Evidence-based classification.
  if bridge_layout_resolver_has_existing_evidence; then
    [[ -n "${BRIDGE_LAYOUT_SOURCE:-}" ]] || BRIDGE_LAYOUT_SOURCE="missing-marker(existing)"
    # v0.8.0 hard-cut: existing markerless installs were previously pinned
    # to the legacy layout. With v1 removed, there is no longer a runtime
    # path that can serve them — the operator must run the migration tool
    # exactly once. Operators upgrading from v0.7.x will hit this on the
    # first invocation after the upgrade, and the migration tool (T3)
    # writes the v2 marker so subsequent boots take the marker branch.
    bridge_die "Agent Bridge v0.8.0 requires isolation-v2 (POSIX group + setgid).
  current_layout=markerless(existing-install)
  remediation: run \`agent-bridge upgrade --apply\` to migrate this install to v2, or roll back to v0.7.x.
  background: ACL-based isolation (v1) was removed in v0.8.0. See https://github.com/SYRS-AI/agent-bridge-public/blob/main/docs/isolation-migration-guide.md for details."
  fi

  # Fresh install candidate. Pre-v0.8.0 this branch left BRIDGE_LAYOUT
  # unset until `agent-bridge init` wrote the marker; with v1 removed,
  # the only honest behavior is to refuse unless the caller is the
  # init/bootstrap flow that will write the marker before any other
  # subsystem reads it. Without the bypass, even `bridge-init.sh` itself
  # cannot run on a clean home — the resolver auto-fires while sourcing
  # bridge-lib.sh and dies before the init's own marker-write reaches
  # line 348.
  if [[ "${BRIDGE_LAYOUT_SOURCE:-}" != "invalid-marker(fallback)" ]]; then
    BRIDGE_LAYOUT_SOURCE="fresh-install-candidate"
  fi
  BRIDGE_DEFAULT_DATA_ROOT="${BRIDGE_HOME:-$HOME/.agent-bridge}/data"

  # Issue #665: armed by bridge-init.sh / bridge-bootstrap.sh before they
  # source bridge-lib.sh. The handshake (nonce + descendant of init/bootstrap
  # PID + matching argv) keeps a leaked / forged env from disarming the
  # v0.8.0 fail-fast for unrelated callers. The bypass only fires when
  # classification is fresh-install-candidate — invalid-marker(fallback)
  # is a corrupted existing install, not a fresh one, so it must still
  # die so the operator runs `agent-bridge upgrade --apply`. The init
  # flow takes over and writes the v2 marker; subsequent process boots
  # take the marker branch and this bypass becomes a no-op.
  if [[ "$BRIDGE_LAYOUT_SOURCE" == "fresh-install-candidate" ]] \
      && _bridge_layout_resolver_fresh_install_bypass_active; then
    return 0
  fi

  bridge_die "Agent Bridge v0.8.0 requires isolation-v2 (POSIX group + setgid).
  current_layout=markerless(${BRIDGE_LAYOUT_SOURCE})
  remediation: run \`agent-bridge upgrade --apply\` to migrate this install to v2, or roll back to v0.7.x.
  background: ACL-based isolation (v1) was removed in v0.8.0. See https://github.com/SYRS-AI/agent-bridge-public/blob/main/docs/isolation-migration-guide.md for details."
}

# ---------------------------------------------------------------------------
# Status helper
# ---------------------------------------------------------------------------

bridge_layout_status_summary() {
  # Single-line layout summary for `agent-bridge status` and similar surfaces.
  # Intentionally avoids leaking marker file contents — only the resolved
  # BRIDGE_LAYOUT and source enum.
  local layout="${BRIDGE_LAYOUT:-legacy}"
  local source="${BRIDGE_LAYOUT_SOURCE:-unknown}"
  local out
  out="layout=${layout} source=${source}"
  if [[ "$layout" == "v2" && -n "${BRIDGE_DATA_ROOT:-}" ]]; then
    out+=" data_root=${BRIDGE_DATA_ROOT}"
  fi
  if [[ -n "${BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV:-}" ]]; then
    out+=" ignored_partial_env=${BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV}"
  fi
  printf '%s\n' "$out"
}

# ---------------------------------------------------------------------------
# Marker writer — used by `agent-bridge init` (fresh install) only.
# ---------------------------------------------------------------------------

bridge_layout_write_v2_marker() {
  # Write a minimal v2 layout marker into $BRIDGE_LAYOUT_MARKER_DIR. Caller
  # supplies BRIDGE_DATA_ROOT (absolute path). The marker is mode 0644 so
  # every isolated UID can read it without depending on `ab-shared` group
  # membership (#1161). Marker content is non-secret (BRIDGE_LAYOUT=v2 +
  # BRIDGE_DATA_ROOT=<abs-path>); the validator's mode check rejects only
  # group/world WRITE bits (mode_int & 0022), so 0644 stays valid against
  # the existing gate.
  #
  # Safety:
  #   - data_root must be absolute.
  #   - parent directory is created with mode 0750.
  #   - file is written atomically via mv.
  local data_root="${1:-}"
  if [[ -z "$data_root" || "${data_root:0:1}" != "/" ]]; then
    bridge_die "bridge_layout_write_v2_marker: data_root must be absolute (got '$data_root')"
  fi
  # Reject characters the marker grammar will reject later. Catching here
  # means a fresh `init` cannot leave a syntactically invalid marker on
  # disk and then claim source=marker. Marker grammar allows
  # [A-Za-z0-9_./@:+-]; anything else (space, $, `, *, etc.) is rejected.
  if [[ ! "$data_root" =~ ^[A-Za-z0-9_./@:+-]+$ ]]; then
    bridge_die "bridge_layout_write_v2_marker: data_root contains characters not permitted by the marker grammar (allowed: letters, digits, _ . / @ : + -)"
  fi

  local marker_dir="${BRIDGE_LAYOUT_MARKER_DIR:-${BRIDGE_HOME:-$HOME/.agent-bridge}/state}"
  local marker_path="$marker_dir/layout-marker.sh"
  local tmp="$marker_path.tmp.$$"

  mkdir -p "$marker_dir"
  # #1161 r2: parent dir gets mode 0711 (others --x) so isolated UIDs
  # that are NOT members of `ab-shared` can traverse INTO state/ and
  # `open()` the marker file by name. With 0750 the marker file's mode
  # 0644 grant was useless — POSIX traversal fails at the parent before
  # the file mode is consulted. Dir contents stay non-listable; only
  # specific files reachable by full path. See sibling sites in
  # lib/bridge-isolation-v2-migrate.sh for the full rationale.
  chmod 0711 "$marker_dir" 2>/dev/null || true

  cat >"$tmp" <<EOF
# Agent Bridge v2 layout marker. Written by \`agent-bridge init\`.
# Source-of-truth for v2 activation. Do not hand-edit; use
# \`agent-bridge migrate isolation-v2 ...\` to move between modes.
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT='$data_root'
EOF
  chmod 0644 "$tmp"
  # Validate before publishing. If the just-written marker would be
  # rejected on the next process boot, unlink and die rather than leave
  # a poison artifact that the resolver would later attribute to
  # source=invalid-marker(fallback).
  if ! bridge_isolation_v2_marker_validate "$tmp"; then
    rm -f "$tmp"
    bridge_die "bridge_layout_write_v2_marker: written marker failed self-validation; refusing to publish"
  fi
  mv "$tmp" "$marker_path"
}

# Auto-resolve when sourced. Marker has already been loaded by
# bridge-marker-bootstrap.sh, so any v2 exports we observe came from there.
bridge_resolve_layout
