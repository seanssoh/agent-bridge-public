#!/usr/bin/env bash
# reconcile-iso-onboarding-layer.sh -- Issue #2193: stream a controller-owned,
# already-`complete` SESSION-TYPE.md into ONE iso-owned runtime layer copy AS
# THE AGENT USER during upgrade migration.
#
# Why this exists. The #2084 ratchet (bridge-upgrade.py
# `ratchet_session_type_layer_complete`) is ownership-guarded: it rewrites a
# workdir/home SESSION-TYPE.md copy ONLY when the copy is owned by the
# controller. Under linux-user isolation (iso v2) those copies are owned by the
# agent's dedicated UID, so the ratchet deliberately no-ops there (a controller
# direct-write would strip the file's owner/group and land root-owned drift, a
# WORSE signal). Result: an iso-v2 install still shows the false
# `agent profile drift` watchdog warn after upgrade until the agent's own next
# session self-heals. This helper closes that gap the supported way: it writes
# the iso-owned copy through the isolation-aware `sudo -u <os_user>` path so the
# file lands owned by the agent UID at group ab-agent-<a> mode 0660 — exactly
# the ownership shape `_set_onboarding_critical` (bridge-agent.sh) and
# `_remat_write_refreshed` (rematerialize-agent-identity.sh) already produce.
#
# Invocation (argv only — NO heredoc stdin; footgun #11):
#   reconcile-iso-onboarding-layer.sh \
#       <source_root> <target_root> <agent> <dest_path> <src_content_path>
#
#   * <src_content_path> is the controller-owned SESSION-TYPE.md that migrate
#     already ratcheted to `Onboarding State: complete`. Its bytes are streamed
#     verbatim into <dest_path>.
#   * <dest_path> is the iso-owned runtime layer copy (workdir/home
#     SESSION-TYPE.md).
#
# Emits exactly one JSON object on stdout; warnings/errors may go to stderr.
# Status values:
#   written  — the iso layer copy was (re)written + group-normalized.
#   skipped  — not applicable (agent not iso-isolated, or the write helper is
#              unavailable): the caller falls back to leaving the copy for the
#              agent's own next session, same as the pre-#2193 no-op.
#   error    — isolation was effective but the sudo-to-agent write failed.
#
# One-way + idempotent by construction: the caller only invokes this for a
# foreign-owned layer AFTER the marker/source say `complete`, and the streamed
# content is already `complete`, so a re-run rewrites identical bytes.

set -uo pipefail

source_root="${1:-}"
target_root="${2:-}"
agent="${3:-}"
dest_path="${4:-}"
src_content_path="${5:-}"

_emit_json() {
  local status="$1" detail="${2:-}"
  # Argv-only python; no heredoc.
  python3 -c '
import json
import sys

agent, status, dest_path, detail = sys.argv[1:]
print(json.dumps({
    "agent": agent,
    "status": status,
    "dest_path": dest_path,
    "detail": detail,
}))
' "$agent" "$status" "$dest_path" "$detail"
}

if [[ -z "$source_root" || -z "$target_root" || -z "$agent" \
      || -z "$dest_path" || -z "$src_content_path" ]]; then
  _emit_json "error" "usage: reconcile-iso-onboarding-layer.sh <source_root> <target_root> <agent> <dest_path> <src_content_path>"
  exit 0
fi

if [[ ! -f "$src_content_path" ]]; then
  _emit_json "error" "src_content_path missing: $src_content_path"
  exit 0
fi

# The destination directory must already exist (the write helper does NOT
# mkdir); a missing layer dir is a genuinely-absent v2 layout, not our repair.
dest_dir="$(dirname "$dest_path")"
if [[ ! -d "$dest_dir" ]]; then
  _emit_json "skipped" "dest_dir absent: $dest_dir"
  exit 0
fi

export HOME="${HOME:-}"
export PATH="${PATH:-/usr/bin:/bin}"
export TMPDIR="${TMPDIR:-/tmp}"
export USER="${USER:-}"
export SHELL="${SHELL:-}"
export TERM="${TERM:-dumb}"
export BRIDGE_HOME="$target_root"
export BRIDGE_ROSTER_FILE="$target_root/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$target_root/agent-roster.local.sh"
export BRIDGE_STATE_DIR="$target_root/state"
export BRIDGE_ACTIVE_AGENT_DIR="$target_root/state/agents"
export BRIDGE_AGENT_HOME_ROOT="$target_root/agents"

if [[ ! -f "$source_root/bridge-lib.sh" ]]; then
  _emit_json "error" "bridge-lib.sh missing under source_root=$source_root"
  exit 0
fi

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"

# Test-only iso stub passthrough — mirrors rematerialize-agent-identity.sh so
# the macOS smoke can exercise the iso write path (which cannot run real
# linux-user isolation on a single-UID CI host). When
# BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1, the isolation-effective probe returns
# true and the sudo-to-agent write is simulated with a plain (same-UID) write
# so the reconcile is observable end-to-end.
if [[ "${BRIDGE_REMATERIALIZE_TEST_STUB_ISO:-0}" == "1" ]]; then
  bridge_agent_linux_user_isolation_effective() {
    return 0
  }
  bridge_isolation_write_file_as_agent_user_via_bash() {
    local _agent="$1"
    local _dest_path="$2"
    local _mode="${3:-0600}"
    # Fault-injection: simulate an iso-UID write failure for any dest matching
    # this glob so the smoke can prove the helper reports `error` (never aborts
    # the migration) — the real-world iso EACCES / no-sudo class.
    if [[ -n "${BRIDGE_RECONCILE_TEST_STUB_WRITE_FAIL_GLOB:-}" \
          && "$_dest_path" == *"$BRIDGE_RECONCILE_TEST_STUB_WRITE_FAIL_GLOB"* ]]; then
      return 13
    fi
    local _tmp=""
    _tmp="$(mktemp "$(dirname "$_dest_path")/.stub-iso-write.XXXXXX")" || return 7
    if ! cat - >"$_tmp"; then
      rm -f -- "$_tmp"
      return 7
    fi
    chmod "$_mode" "$_tmp" 2>/dev/null || true
    mv -f "$_tmp" "$_dest_path" || { rm -f -- "$_tmp"; return 9; }
    return 0
  }
  bridge_isolation_v2_chgrp_file_iso_group() {
    return 0
  }
fi

# Only reconcile when linux-user isolation is actually effective for this
# agent. On a shared-mode (macOS / shared-OS-user) install the copies are
# controller-owned and the #2084 in-place ratchet already handled them — this
# helper must never touch them.
_iso_effective=0
if declare -F bridge_agent_linux_user_isolation_effective >/dev/null 2>&1; then
  bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null \
    && _iso_effective=1
fi
if (( _iso_effective == 0 )); then
  _emit_json "skipped" "agent not under linux-user isolation"
  exit 0
fi

if ! declare -F bridge_isolation_write_file_as_agent_user_via_bash >/dev/null 2>&1; then
  _emit_json "skipped" "iso write helper unavailable"
  exit 0
fi

# Controller-published write: stream the already-`complete` controller copy
# into the iso-owned layer AS THE AGENT USER, then group-normalize to
# ab-agent-<a> 0660 (the boundary-readable shape). Mirrors
# _set_onboarding_critical / _remat_write_refreshed exactly.
_wrc=0
bridge_isolation_write_file_as_agent_user_via_bash \
  "$agent" "$dest_path" "0660" <"$src_content_path" >/dev/null 2>&1 || _wrc=$?
case "$_wrc" in
  0)
    if declare -F bridge_isolation_v2_chgrp_file_iso_group >/dev/null 2>&1; then
      bridge_isolation_v2_chgrp_file_iso_group \
        "$agent" "$dest_path" 0660 "$dest_dir" >/dev/null 2>&1 || true
    fi
    _emit_json "written" ""
    ;;
  1|10)
    # Helper reports "agent not isolated" — treat as skip (defensive; the
    # effective-probe above already gated this, but keep the fallback aligned
    # with the write helper's own rc contract).
    _emit_json "skipped" "write helper reports agent not isolated (rc=$_wrc)"
    ;;
  2|20)
    _emit_json "error" "passwordless sudo unavailable — could not reconcile the iso layer copy (rc=$_wrc)"
    ;;
  *)
    _emit_json "error" "iso layer write failed (rc=$_wrc)"
    ;;
esac
exit 0
