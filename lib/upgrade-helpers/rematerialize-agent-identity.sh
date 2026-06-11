#!/usr/bin/env bash
# rematerialize-agent-identity.sh -- upgrade-time HOME -> workdir identity sync.
#
# Invocation:
#   rematerialize-agent-identity.sh <source_root> <target_root> <agent> <engine> <dry_run> [changed-file...]
#
# Emits exactly one JSON object on stdout. Warnings/errors may go to stderr.
# No heredoc stdin: this helper is called from bridge-upgrade.py as argv.

set -euo pipefail

source_root="${1:-}"
target_root="${2:-}"
agent="${3:-}"
engine="${4:-}"
dry_run="${5:-0}"
# Issue #1670: capture the changed-file argv as a 6+ POSITIONAL SLICE rather
# than `shift 5`. bridge-lib.sh (sourced below) performs a Bash 3.2 -> 4+
# re-exec via `exec "$cand" -p "$target_script" "$@"` (#1454). The macOS stock
# shebang `#!/usr/bin/env bash` resolves to /bin/bash 3.2 when Homebrew bash is
# not first on PATH, so when bridge-upgrade.py invokes this helper by argv that
# re-exec fires. A `shift 5` BEFORE the source would leave `$@` holding only the
# changed-file tail at re-exec time, so the re-run would land the changed files
# in the <source_root>/<target_root>/<agent>/<engine> slots and blank the
# mandatory args -> `agent=""` + the usage error for every agent in the dry-run
# preview. Slicing leaves `$@` fully intact, so the re-exec carries the original
# argv and the re-run parses identically. `"${@:6}"` is empty-safe under
# `set -u` in both Bash 3.2 and 5.x (verified) when there are zero changed files.
declare -a REMAT_CHANGED_FILE_ARGS=("${@:6}")

declare -a REMAT_UPDATED_PATHS=()
declare -a REMAT_PRESERVED_PATHS=()
declare -a REMAT_SCAFFOLD_PATHS=()
declare -a REMAT_ERRORS=()
declare -a REMAT_CHANGED_FILES=()

# Issue #1781 (DATA-LOSS): `MEMORY.md` is AGENT-WRITTEN state, not a managed
# doc. The memory-daily cron and live sessions append to the WORKDIR copy; the
# identity-source (home) copy is frequently the stale one. Copying home ->
# workdir like the other identity docs silently rolled live memory back to the
# stale home copy on EVERY upgrade (13/22 agents on one host, byte-identical to
# the older home copy). State files are therefore NEVER synced here — they are
# only RECORDED as `preserved_paths` so the upgrade's targeted backup still
# captures the live workdir copy (the recovery anchor the issue credits — keep
# it regardless of the fix). The match is on the basename so it also excludes
# `users/<id>/MEMORY.md` inside the users-tree walk below. Same data-loss
# family as the #1756 PRESERVED_USER_KEYS settings-rerender class.
_remat_is_state_file() {
  case "${1##*/}" in
    MEMORY.md) return 0 ;;
    *) return 1 ;;
  esac
}

status="applied"
skipped_reason=""
source_dir=""
target_dir=""

_remat_tmp_paths=""
_remat_tmp_preserved=""
_remat_tmp_scaffold=""
_remat_tmp_errors=""
_remat_tmp_user_files=""
cleanup() {
  [[ -n "$_remat_tmp_paths" ]] && rm -f -- "$_remat_tmp_paths"
  [[ -n "$_remat_tmp_preserved" ]] && rm -f -- "$_remat_tmp_preserved"
  [[ -n "$_remat_tmp_scaffold" ]] && rm -f -- "$_remat_tmp_scaffold"
  [[ -n "$_remat_tmp_errors" ]] && rm -f -- "$_remat_tmp_errors"
  [[ -n "$_remat_tmp_user_files" ]] && rm -f -- "$_remat_tmp_user_files"
  return 0
}
trap cleanup EXIT

_remat_add_error() {
  REMAT_ERRORS+=("$1")
}

# Emit one named audit line per file the migration writes outside its own
# managed marker block, so the upgrade output shows WHAT moved instead of only
# leaving an mtime trace (Issue #1781 scope item 3). `action` is one of
# `rematerialize` (identity doc home->workdir) or `preserve` (state file kept).
# Best-effort: a logging failure never affects the copy outcome.
_remat_audit_line() {
  local action="$1" target_rel="$2"
  printf '[rematerialize] agent=%s %s %s\n' "$agent" "$action" "$target_rel" >&2
}

_remat_emit_json() {
  _remat_tmp_paths="$(mktemp "${TMPDIR:-/tmp}/agb-remat-paths.XXXXXX")" || {
    printf '{"agent":"%s","status":"error","source_dir":"","target_dir":"","updated_paths":[],"errors":["mktemp failed"]}\n' "$agent"
    return 0
  }
  _remat_tmp_preserved="$(mktemp "${TMPDIR:-/tmp}/agb-remat-preserved.XXXXXX")" || {
    printf '{"agent":"%s","status":"error","source_dir":"","target_dir":"","updated_paths":[],"errors":["mktemp failed"]}\n' "$agent"
    return 0
  }
  _remat_tmp_scaffold="$(mktemp "${TMPDIR:-/tmp}/agb-remat-scaffold.XXXXXX")" || {
    printf '{"agent":"%s","status":"error","source_dir":"","target_dir":"","updated_paths":[],"errors":["mktemp failed"]}\n' "$agent"
    return 0
  }
  _remat_tmp_errors="$(mktemp "${TMPDIR:-/tmp}/agb-remat-errors.XXXXXX")" || {
    printf '{"agent":"%s","status":"error","source_dir":"","target_dir":"","updated_paths":[],"errors":["mktemp failed"]}\n' "$agent"
    return 0
  }
  : >"$_remat_tmp_paths"
  : >"$_remat_tmp_preserved"
  : >"$_remat_tmp_scaffold"
  : >"$_remat_tmp_errors"
  local item=""
  for item in "${REMAT_UPDATED_PATHS[@]}"; do
    printf '%s\n' "$item" >>"$_remat_tmp_paths"
  done
  for item in "${REMAT_PRESERVED_PATHS[@]}"; do
    printf '%s\n' "$item" >>"$_remat_tmp_preserved"
  done
  for item in "${REMAT_SCAFFOLD_PATHS[@]}"; do
    printf '%s\n' "$item" >>"$_remat_tmp_scaffold"
  done
  for item in "${REMAT_ERRORS[@]}"; do
    printf '%s\n' "$item" >>"$_remat_tmp_errors"
  done
  python3 -c '
import json
import sys
from pathlib import Path

agent, status, source_dir, target_dir, skipped_reason, dry_run, paths_file, preserved_file, scaffold_file, errors_file = sys.argv[1:]

def read_lines(path):
    try:
        return [line.rstrip("\n") for line in Path(path).read_text(encoding="utf-8").splitlines() if line.rstrip("\n")]
    except OSError:
        return []

scaffold_paths = read_lines(scaffold_file)
preserved_paths = read_lines(preserved_file)
payload = {
    "agent": agent,
    "status": status,
    "source_dir": source_dir,
    "target_dir": target_dir,
    "dry_run": dry_run == "1",
    "updated_paths": read_lines(paths_file),
    # Issue #1781: agent-written state files (MEMORY.md, users/<id>/MEMORY.md)
    # are NEVER copied home->workdir, but they ARE reported here so the
    # targeted upgrade backup still captures the live workdir copy.
    "preserved_paths": preserved_paths,
    "scaffold_paths": scaffold_paths,
    "scaffold_added": len(scaffold_paths),
}
errors = read_lines(errors_file)
if skipped_reason:
    payload["skipped_reason"] = skipped_reason
if errors:
    payload["errors"] = errors
print(json.dumps(payload, ensure_ascii=False, sort_keys=True))
' "$agent" "$status" "$source_dir" "$target_dir" "$skipped_reason" "$dry_run" "$_remat_tmp_paths" "$_remat_tmp_preserved" "$_remat_tmp_scaffold" "$_remat_tmp_errors"
}

_remat_finish() {
  if [[ ${#REMAT_ERRORS[@]} -gt 0 ]]; then
    status="error"
  elif [[ -n "$skipped_reason" ]]; then
    status="skipped"
  elif [[ "$dry_run" == "1" ]]; then
    status="planned"
  else
    status="applied"
  fi
  _remat_emit_json
}

_remat_normalize_changed_file() {
  local rel="${1:-}"
  while [[ "$rel" == ./* ]]; do
    rel="${rel#./}"
  done
  rel="${rel%/}"
  [[ -n "$rel" ]] || return 1
  [[ "$rel" != /* ]] || return 1
  [[ "$rel" != "." && "$rel" != ".." && "$rel" != ../* && "$rel" != */../* && "$rel" != */.. ]] || return 1
  printf '%s' "$rel"
}

_remat_load_changed_files() {
  local item="" rel=""
  for item in "$@"; do
    rel="$(_remat_normalize_changed_file "$item" 2>/dev/null || true)"
    [[ -n "$rel" ]] || continue
    REMAT_CHANGED_FILES+=("$rel")
  done
}

_remat_changed_file_is_planned() {
  local rel="$1"
  local item=""
  [[ "$dry_run" == "1" ]] || return 1
  for item in "${REMAT_CHANGED_FILES[@]}"; do
    [[ "$item" == "$rel" ]] || continue
    return 0
  done
  return 1
}

if [[ -z "$source_root" || -z "$target_root" || -z "$agent" || -z "$engine" ]]; then
  _remat_add_error "usage: rematerialize-agent-identity.sh <source_root> <target_root> <agent> <engine> <dry_run> [changed-file...]"
  _remat_finish
  exit 0
fi
_remat_load_changed_files ${REMAT_CHANGED_FILE_ARGS[@]+"${REMAT_CHANGED_FILE_ARGS[@]}"}

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
export BRIDGE_HISTORY_DIR="$target_root/state/history"
export BRIDGE_WORKTREE_META_DIR="$target_root/state/worktrees"
export BRIDGE_ACTIVE_ROSTER_TSV="$target_root/state/active-roster.tsv"
export BRIDGE_ACTIVE_ROSTER_MD="$target_root/state/active-roster.md"
export BRIDGE_DAEMON_PID_FILE="$target_root/state/daemon.pid"
export BRIDGE_DAEMON_LOG="$target_root/state/daemon.log"
export BRIDGE_DAEMON_CRASH_LOG="$target_root/state/daemon-crash.log"
export BRIDGE_TASK_DB="$target_root/state/tasks.db"
export BRIDGE_PROFILE_STATE_DIR="$target_root/state/profiles"
export BRIDGE_CRON_STATE_DIR="$target_root/state/cron"
export BRIDGE_CRON_HOME_DIR="$target_root/cron"
export BRIDGE_NATIVE_CRON_JOBS_FILE="$target_root/cron/jobs.json"
export BRIDGE_CRON_DISPATCH_WORKER_DIR="$target_root/state/cron/workers"
export BRIDGE_WORKTREE_ROOT="$target_root/worktrees"
export BRIDGE_AGENT_HOME_ROOT="$target_root/agents"
export BRIDGE_RUNTIME_ROOT="$target_root/runtime"
export BRIDGE_RUNTIME_SCRIPTS_DIR="$target_root/runtime/scripts"
export BRIDGE_RUNTIME_SKILLS_DIR="$target_root/runtime/skills"
export BRIDGE_RUNTIME_SHARED_DIR="$target_root/runtime/shared"
export BRIDGE_RUNTIME_SHARED_TOOLS_DIR="$target_root/runtime/shared/tools"
export BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="$target_root/runtime/shared/references"
export BRIDGE_RUNTIME_MEMORY_DIR="$target_root/runtime/memory"
export BRIDGE_RUNTIME_CREDENTIALS_DIR="$target_root/runtime/credentials"
export BRIDGE_RUNTIME_SECRETS_DIR="$target_root/runtime/secrets"
export BRIDGE_RUNTIME_CONFIG_FILE="$target_root/runtime/bridge-config.json"
export BRIDGE_HOOKS_DIR="$target_root/hooks"
export BRIDGE_LOG_DIR="$target_root/logs"
export BRIDGE_AUDIT_LOG="$target_root/logs/audit.jsonl"
export BRIDGE_SHARED_DIR="$target_root/shared"
export BRIDGE_TASK_NOTE_DIR="$target_root/shared/tasks"
export BRIDGE_DASHBOARD_STATE_FILE="$target_root/state/dashboard.json"
export BRIDGE_DISCORD_RELAY_STATE_FILE="$target_root/state/discord-relay.json"

if [[ ! -f "$source_root/bridge-lib.sh" ]]; then
  _remat_add_error "bridge-lib.sh missing under source_root=$source_root"
  _remat_finish
  exit 0
fi

# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"

if [[ "${BRIDGE_REMATERIALIZE_TEST_STUB_ISO:-0}" == "1" ]]; then
  bridge_agent_linux_user_isolation_effective() {
    return 0
  }
  bridge_isolation_run_as_agent_user_via_bash() {
    local _agent="$1"
    local script="$2"
    shift 2 || true
    bash -c "$script" bridge-isolation "$@"
  }
  bridge_isolation_write_file_as_agent_user_via_bash() {
    local _agent="$1"
    local dest_path="$2"
    local mode="${3:-0600}"
    # Test-only iso-boundary fault injection: simulate a PermissionError on the
    # iso-UID write for any dest matching this substring, so the smoke can prove
    # the helper graceful-skips (records an error, never aborts) instead of
    # exiting non-zero. Mirrors the real-world iso EACCES the controller hits.
    if [[ -n "${BRIDGE_REMATERIALIZE_TEST_STUB_WRITE_FAIL_GLOB:-}" \
          && "$dest_path" == *"$BRIDGE_REMATERIALIZE_TEST_STUB_WRITE_FAIL_GLOB"* ]]; then
      if [[ -n "${BRIDGE_REMATERIALIZE_TEST_STUB_LOG:-}" ]]; then
        printf 'write-fail:%s\n' "$dest_path" >>"$BRIDGE_REMATERIALIZE_TEST_STUB_LOG"
      fi
      return 13
    fi
    mkdir -p -- "$(dirname -- "$dest_path")" || return 5
    cat - >"$dest_path" || return 7
    chmod "$mode" "$dest_path" || return 8
    if [[ -n "${BRIDGE_REMATERIALIZE_TEST_STUB_LOG:-}" ]]; then
      printf 'write:%s:%s\n' "$dest_path" "$mode" >>"$BRIDGE_REMATERIALIZE_TEST_STUB_LOG"
    fi
  }
  bridge_isolation_v2_chgrp_file_iso_group() {
    local _agent="$1"
    local file="$2"
    local mode="${3:-0660}"
    chmod "$mode" "$file" 2>/dev/null || true
    if [[ -n "${BRIDGE_REMATERIALIZE_TEST_STUB_LOG:-}" ]]; then
      printf 'chgrp:%s:%s\n' "$file" "$mode" >>"$BRIDGE_REMATERIALIZE_TEST_STUB_LOG"
    fi
  }
fi

if ! bridge_load_roster >/dev/null 2>&1; then
  _remat_add_error "bridge_load_roster failed"
  _remat_finish
  exit 0
fi

if ! bridge_agent_exists "$agent" 2>/dev/null; then
  skipped_reason="orphan"
  _remat_finish
  exit 0
fi

source_dir="$(bridge_layout_agent_home "$agent" 2>/dev/null || printf '')"
profile_source_dir="$(bridge_layout_profile_source_dir "$agent" 2>/dev/null || printf '')"
engine_entry="$(bridge_engine_entrypoint_filename "$engine" 2>/dev/null || printf '')"
if [[ -z "$target_dir" ]]; then
  target_dir="$(bridge_engine_materialization_target "$agent" "$engine" 2>/dev/null || printf '')"
fi
if [[ -z "$target_dir" ]]; then
  target_dir="$(bridge_agent_workdir "$agent" 2>/dev/null || printf '')"
fi

if [[ -z "$source_dir" || -z "$target_dir" ]]; then
  _remat_add_error "could not resolve source or target (source=$source_dir target=$target_dir)"
  _remat_finish
  exit 0
fi
if [[ -n "$profile_source_dir" && "$profile_source_dir" != "$source_dir" && -n "$engine_entry" ]]; then
  if [[ ! -f "$source_dir/$engine_entry" && -f "$profile_source_dir/$engine_entry" ]]; then
    source_dir="$profile_source_dir"
  fi
fi
if [[ "$source_dir" == "$target_dir" ]]; then
  skipped_reason="source_equals_target"
  _remat_finish
  exit 0
fi

# Issue #1636: the non-identity _template scaffolding is materialized by
# migrate_agent_home into the controller-owned PROFILE SOURCE
# ($BRIDGE_HOME/agents/<agent>), NOT the identity home that source_dir points at
# (on a v2 install that is $BRIDGE_AGENT_ROOT_V2/<agent>/home). Read scaffolding
# from the profile source so the freshly-migrated commands/captures/codex tree is
# actually visible; fall back to source_dir only when the profile source is
# absent on disk (legacy single-tree layouts where they coincide).
scaffold_source_dir="$source_dir"
if [[ -n "$profile_source_dir" && -d "$profile_source_dir" ]]; then
  scaffold_source_dir="$profile_source_dir"
fi

_remat_realpath() {
  python3 -c 'import os,sys; print(os.path.realpath(sys.argv[1]))' "$1"
}

_remat_rel_to_target_root() {
  python3 -c 'import os,sys; print(os.path.relpath(sys.argv[1], sys.argv[2]).replace(os.sep, "/"))' "$1" "$target_root"
}

# _remat_path_under <root> <path>
# True iff the realpath of <path> is <root> itself or a descendant of it.
# Resolves symlinks in both arguments (realpath of a not-yet-existing leaf
# resolves through its existing prefix), so an ancestor symlink that escapes
# <root> fails the check.
_remat_path_under() {
  python3 -c '
import os
import sys

root = os.path.realpath(sys.argv[1])
path = os.path.realpath(sys.argv[2])
try:
    ok = os.path.commonpath([root, path]) == root
except ValueError:
    ok = False
sys.exit(0 if ok else 1)
' "$1" "$2"
}

_remat_path_under_target_root() {
  _remat_path_under "$target_root" "$1"
}

# Issue #1636 (codex pair-review r1 follow-up): per-agent containment. The
# scaffold + identity writes must land inside THIS agent's own workdir
# ($target_dir), not merely somewhere under the global BRIDGE_HOME. A symlink
# from one agent's workdir into ANOTHER agent's workdir stays under target_root
# yet escapes target_dir — that is a cross-agent write escape. Gate writes on
# the tighter per-agent boundary.
_remat_path_under_target_dir() {
  _remat_path_under "$target_dir" "$1"
}

if ! _remat_path_under_target_root "$target_dir"; then
  skipped_reason="target_outside_root"
  _remat_finish
  exit 0
fi

_remat_identity_owner_token() {
  local entry="" heading="" token=""
  for entry in "$target_dir/CLAUDE.md" "$target_dir/AGENTS.md"; do
    [[ -f "$entry" ]] || continue
    if grep -qiE "shared[- ]workdir|shared project" "$entry" 2>/dev/null; then
      printf '%s' "__shared_marker__"
      return 0
    fi
    heading="$(sed -n 's/^#[#[:space:]]*//p' "$entry" 2>/dev/null | head -n 1 || true)"
    [[ -n "$heading" ]] || continue
    token="${heading%%[[:space:]]*}"
    [[ -n "$token" ]] || continue
    printf '%s' "$token"
    return 0
  done
  return 1
}

_remat_shared_workspace_guard() {
  if [[ -n "${BRIDGE_LAYOUT_WORKSPACE_SHARED:-}" ]]; then
    skipped_reason="shared_workspace"
    return 1
  fi

  local owner_token=""
  owner_token="$(_remat_identity_owner_token 2>/dev/null || true)"
  if [[ "$owner_token" == "__shared_marker__" ]]; then
    skipped_reason="shared_workspace"
    return 1
  fi

  local target_real=""
  target_real="$(_remat_realpath "$target_dir" 2>/dev/null || true)"
  [[ -n "$target_real" ]] || return 0

  local other="" other_workdir="" other_real=""
  for other in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$other" != "$agent" ]] || continue
    other_workdir="$(bridge_agent_workdir "$other" 2>/dev/null || printf '')"
    [[ -n "$other_workdir" ]] || continue
    other_real="$(_remat_realpath "$other_workdir" 2>/dev/null || true)"
    [[ -n "$other_real" && "$other_real" == "$target_real" ]] || continue
    if [[ -n "$owner_token" && "$owner_token" != "$agent" ]]; then
      skipped_reason="shared_workspace"
      return 1
    fi
  done
  return 0
}

if ! _remat_shared_workspace_guard; then
  _remat_finish
  exit 0
fi

iso_effective=0
if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
  iso_effective=1
fi

_remat_ensure_parent() {
  local dst="$1"
  local parent=""
  parent="$(dirname -- "$dst")"
  if (( iso_effective == 1 )); then
    local script='mkdir -p "$1"'
    bridge_isolation_run_as_agent_user_via_bash "$agent" "$script" "$parent" >/dev/null 2>&1
    return $?
  fi
  mkdir -p -- "$parent" 2>/dev/null
}

_remat_target_differs_or_missing() {
  local src="$1"
  local dst="$2"
  if [[ ! -e "$dst" ]]; then
    return 0
  fi
  if [[ -L "$dst" ]]; then
    return 0
  fi
  if [[ -r "$dst" ]] && cmp -s -- "$src" "$dst" 2>/dev/null; then
    return 1
  fi
  return 0
}

_remat_copy_one_file() {
  local rel="$1"
  local src="$source_dir/$rel"
  local dst="$target_dir/$rel"
  local target_rel=""
  local force_plan=0
  target_rel="$(_remat_rel_to_target_root "$dst")"

  # Issue #1781 (DATA-LOSS): agent-written state files must never be OVERWRITTEN
  # home->workdir (that silently rolled live memory back to the stale home copy
  # on every upgrade). But create-if-absent is still required: a fresh/legacy
  # workdir with no MEMORY.md yet must receive the initial copy from the profile
  # seed, or the runtime contract that Claude requires MEMORY.md
  # (bridge-watchdog.py) breaks. So:
  #   - dst present (file or symlink) -> PRESERVE: record the LIVE workdir copy
  #     as a preserved path (so the upgrade backup still captures it) and never
  #     touch it.
  #   - dst absent -> fall through to the normal copy gate below, which
  #     materializes the initial file when src exists (recording updated_paths +
  #     auditing `rematerialize`) and no-ops when src is also absent.
  # Reached for both the named-file loop and the users-tree walk, so
  # `users/<id>/MEMORY.md` is covered by the same basename guard.
  if _remat_is_state_file "$rel" && { [[ -e "$dst" ]] || [[ -L "$dst" ]]; }; then
    REMAT_PRESERVED_PATHS+=("$target_rel")
    _remat_audit_line preserve "$target_rel"
    return 0
  fi

  if _remat_changed_file_is_planned "$rel"; then
    force_plan=1
  fi
  if [[ ! -f "$src" ]]; then
    if (( force_plan == 1 )); then
      REMAT_UPDATED_PATHS+=("$target_rel")
    fi
    return 0
  fi
  if (( force_plan == 0 )) && ! _remat_target_differs_or_missing "$src" "$dst"; then
    return 0
  fi
  REMAT_UPDATED_PATHS+=("$target_rel")
  _remat_audit_line rematerialize "$target_rel"
  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi
  if [[ -L "$dst" ]]; then
    _remat_add_error "refusing to overwrite symlink: $target_rel"
    return 1
  fi
  # Per-agent containment (Issue #1636 codex r1 follow-up): refuse a write whose
  # parent realpath escapes THIS agent's own workdir via an ancestor symlink —
  # an in-root symlink into another agent's workdir would otherwise let the
  # identity write cross into a sibling's tree. Shares the scaffold-write guard.
  if ! _remat_path_under_target_dir "$(dirname -- "$dst")"; then
    _remat_add_error "refusing identity write outside agent workdir: $target_rel"
    return 1
  fi
  if ! _remat_ensure_parent "$dst"; then
    _remat_add_error "failed to create parent for $target_rel"
    return 1
  fi
  if (( iso_effective == 1 )); then
    local write_rc=0
    bridge_isolation_write_file_as_agent_user_via_bash "$agent" "$dst" "0660" <"$src" >/dev/null 2>&1 || write_rc=$?
    if (( write_rc != 0 )); then
      _remat_add_error "iso write failed for $target_rel (rc=$write_rc)"
      return 1
    fi
    bridge_isolation_v2_chgrp_file_iso_group "$agent" "$dst" 0660 "$target_dir" >/dev/null 2>&1 || true
    return 0
  fi
  cp -f -- "$src" "$dst" 2>/dev/null || {
    _remat_add_error "copy failed for $target_rel"
    return 1
  }
  return 0
}

# Issue #1636: add-missing-only propagation of the non-identity _template
# scaffolding (slash commands, capture/session scaffolds, codex extras) from
# the controller-owned profile source to the agent workdir. Unlike the identity
# files above, scaffolding is SKIP-EXISTING: a user may have customized a slash
# command, so an existing workdir file is never overwritten (a changed-upstream
# command will not refresh — the safe trade-off for user-editable scaffolding).
# Reuses the SAME iso-UID write path as the identity files; an iso PermissionError
# graceful-skips per file (records an error, never aborts the upgrade).
_remat_copy_scaffold_file() {
  local rel="$1"
  local src="$scaffold_source_dir/$rel"
  local dst="$target_dir/$rel"
  local target_rel=""
  target_rel="$(_remat_rel_to_target_root "$dst")"

  [[ -f "$src" ]] || return 0
  # Skip-existing: never clobber a (possibly user-customized) workdir file.
  if [[ -e "$dst" || -L "$dst" ]]; then
    return 0
  fi
  # Containment (checked BEFORE recording the path, so a refused write is never
  # reported as applied/planned): scaffolding creates NEW deep directory trees
  # (.claude/commands, raw/captures/..., codex/) under the workdir. If any
  # EXISTING ancestor of the destination is (or resolves through) a symlink that
  # escapes THIS agent's own workdir, creating dirs / writing the file would land
  # in another agent's tree (a cross-agent write escape — the symlink target can
  # still be under the global BRIDGE_HOME). Verify the realpath of the
  # destination's parent stays under target_dir BEFORE creating any parent dir or
  # recording the path; skip + record a structured error otherwise rather than
  # follow the symlink out of the agent's workdir. realpath of a not-yet-existing
  # path resolves through its existing prefix, so this catches an escaping
  # ancestor even when the leaf dirs are still absent (apply AND dry-run).
  if ! _remat_path_under_target_dir "$(dirname -- "$dst")"; then
    _remat_add_error "refusing scaffold write outside agent workdir: $target_rel"
    return 1
  fi
  REMAT_SCAFFOLD_PATHS+=("$target_rel")
  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi
  if ! _remat_ensure_parent "$dst"; then
    _remat_add_error "failed to create parent for $target_rel"
    return 1
  fi
  if (( iso_effective == 1 )); then
    local write_rc=0
    bridge_isolation_write_file_as_agent_user_via_bash "$agent" "$dst" "0660" <"$src" >/dev/null 2>&1 || write_rc=$?
    if (( write_rc != 0 )); then
      _remat_add_error "iso scaffold write failed for $target_rel (rc=$write_rc)"
      return 1
    fi
    bridge_isolation_v2_chgrp_file_iso_group "$agent" "$dst" 0660 "$target_dir" >/dev/null 2>&1 || true
    return 0
  fi
  cp -f -- "$src" "$dst" 2>/dev/null || {
    _remat_add_error "scaffold copy failed for $target_rel"
    return 1
  }
  return 0
}

# Walk a scaffolding subtree under the profile source and add-missing-only copy
# every regular file to the workdir, mirroring the tree structure. Files matching
# any path in REMAT_SCAFFOLD_EXCLUDE (relative to scaffold_source_dir) are never
# handled here (e.g. codex/AGENTS.md, already materialized as the engine entry).
_remat_propagate_scaffold_tree() {
  local root="$1"
  local src_root="$scaffold_source_dir/$root"
  [[ -d "$src_root" ]] || return 0
  local files_tmp=""
  files_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-remat-scaffold-walk.XXXXXX")" || {
    _remat_add_error "mktemp failed for scaffold inventory ($root)"
    return 0
  }
  find "$src_root" -type f -print >"$files_tmp" 2>/dev/null || true
  local scaffold_file="" rel="" excluded="" excl=""
  while IFS= read -r scaffold_file; do
    [[ -n "$scaffold_file" ]] || continue
    rel="${scaffold_file#"$scaffold_source_dir/"}"
    excluded=0
    for excl in "${REMAT_SCAFFOLD_EXCLUDE[@]}"; do
      [[ "$rel" == "$excl" ]] || continue
      excluded=1
      break
    done
    (( excluded == 0 )) || continue
    _remat_copy_scaffold_file "$rel" || true
  done <"$files_tmp"
  rm -f -- "$files_tmp"
}

# Scaffolding roots under the profile source to propagate (Issue #1636). These
# mirror the non-identity _template tree; the identity files + engine entry +
# CLAUDE.md + users/ are handled separately above and intentionally excluded.
declare -a REMAT_SCAFFOLD_ROOTS=(
  ".claude/commands"
  "raw/captures/inbox"
  "raw/captures/ingested"
  "session-type-files"
  "codex"
)
# codex/AGENTS.md is already materialized as the codex engine entry — never
# double-handle it here.
declare -a REMAT_SCAFFOLD_EXCLUDE=(
  "codex/AGENTS.md"
)

# Identity files synced home -> workdir. `MEMORY.md` stays in this list so the
# loop visits it and records the live workdir copy in `preserved_paths` for
# backup coverage — but `_remat_copy_one_file` short-circuits it (Issue #1781):
# it is agent-written STATE and is never overwritten. Every other entry is a
# managed DOC the migration owns and may refresh from the identity source.
declare -a remat_names=(
  "SOUL.md"
  "SESSION-TYPE.md"
  "MEMORY.md"
  "MEMORY-SCHEMA.md"
  "HEARTBEAT.md"
  "CHANGE-POLICY.md"
  "TOOLS.md"
)

if [[ ! -d "$source_dir" ]]; then
  skipped_reason="source_missing"
  _remat_finish
  exit 0
fi
if [[ -n "$engine_entry" ]]; then
  remat_names+=("$engine_entry")
fi
if bridge_engine_wants_claude_compat_copy "$engine" 2>/dev/null && [[ "$engine_entry" != "CLAUDE.md" ]]; then
  remat_names+=("CLAUDE.md")
fi

for name in "${remat_names[@]}"; do
  _remat_copy_one_file "$name" || true
done

if [[ -d "$source_dir/users" ]]; then
  _remat_tmp_user_files="$(mktemp "${TMPDIR:-/tmp}/agb-remat-users.XXXXXX")" || {
    _remat_add_error "mktemp failed for users inventory"
    _remat_finish
    exit 0
  }
  find "$source_dir/users" -type f -print >"$_remat_tmp_user_files" 2>/dev/null || true
  while IFS= read -r user_file; do
    [[ -n "$user_file" ]] || continue
    rel="${user_file#"$source_dir/"}"
    _remat_copy_one_file "$rel" || true
  done <"$_remat_tmp_user_files"
fi

# Issue #1636: propagate the non-identity _template scaffolding (add-missing-only).
for scaffold_root in "${REMAT_SCAFFOLD_ROOTS[@]}"; do
  _remat_propagate_scaffold_tree "$scaffold_root"
done

_remat_finish
