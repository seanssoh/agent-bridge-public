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

  if [[ -d "$state/runtime" ]]; then
    if compgen -G "$state/runtime/*" >/dev/null 2>&1; then
      return 0
    fi
  fi
  if [[ -d "$state/cron" ]]; then
    if compgen -G "$state/cron/*" >/dev/null 2>&1; then
      return 0
    fi
  fi

  if [[ -d "$home/agents" ]]; then
    local entry
    for entry in "$home/agents"/*/; do
      [[ -d "$entry" ]] || continue
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
    legacy)
      # legacy override — clear any stale v2-derived roots so they don't
      # leak into child env.
      if [[ -n "$data_root" ]]; then
        unset BRIDGE_DATA_ROOT
      fi
      BRIDGE_LAYOUT_SOURCE="env"
      return 0
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
    *)
      bridge_warn "BRIDGE_LAYOUT='$layout' is invalid (expected 'legacy' or 'v2') — ignoring env override"
      BRIDGE_LAYOUT_IGNORED_PARTIAL_ENV="BRIDGE_LAYOUT"
      unset BRIDGE_LAYOUT
      [[ -z "$data_root" ]] || unset BRIDGE_DATA_ROOT
      return 1
      ;;
  esac
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
      if [[ "${BRIDGE_LAYOUT:-}" == "legacy" ]]; then
        BRIDGE_LAYOUT_SOURCE="marker"
        return 0
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
    # Existing markerless install is legacy by invariant.
    BRIDGE_LAYOUT="legacy"
    return 0
  fi

  # Fresh install candidate. BRIDGE_LAYOUT is intentionally NOT set to v2 —
  # bridge_isolation_v2_active must remain false until `agent-bridge init`
  # writes the marker. If we already classified the prior marker as
  # invalid-marker(fallback), preserve that source so status output
  # honestly reports the bad marker instead of pretending the install is
  # fresh; the v2-active state is the same either way.
  if [[ "${BRIDGE_LAYOUT_SOURCE:-}" != "invalid-marker(fallback)" ]]; then
    BRIDGE_LAYOUT_SOURCE="fresh-install-candidate"
  fi
  BRIDGE_DEFAULT_DATA_ROOT="${BRIDGE_HOME:-$HOME/.agent-bridge}/data"
  # BRIDGE_LAYOUT stays whatever bridge-isolation-v2.sh defaults it to
  # (legacy). Do not export v2 here.
  return 0
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
  # supplies BRIDGE_DATA_ROOT (absolute path). The marker is mode 0640 so
  # group-readable controllers can re-read it after PR-E group setgid.
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
  chmod 0750 "$marker_dir" 2>/dev/null || true

  cat >"$tmp" <<EOF
# Agent Bridge v2 layout marker. Written by \`agent-bridge init\`.
# Source-of-truth for v2 activation. Do not hand-edit; use
# \`agent-bridge migrate isolation-v2 ...\` to move between modes.
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT='$data_root'
EOF
  chmod 0640 "$tmp"
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
