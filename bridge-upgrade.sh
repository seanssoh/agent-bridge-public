#!/usr/bin/env bash
# bridge-upgrade.sh — update a live Agent Bridge install from a repo checkout

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# v0.8.0 T3 — the layout resolver fails fast on markerless / legacy
# installs. The upgrader is the migration vehicle for those installs,
# so we MUST be able to source the v0.8.0 lib stack against a v0.7.x
# target. Set the resolver bypass before sourcing bridge-lib.sh; the
# migration call below clears it once the v2 marker has been written.
# Operators never set this directly — it's an internal upgrader handshake.
#
# Bypass scope is defended by a process-tree check (r2 review fix):
# the bypass value carries a unique nonce, and the resolver only honors
# it when the calling process is a descendant of the upgrade owner PID.
# A leaked or copied env var alone is therefore not enough to disarm the
# v0.8.0 fail-fast guard from outside the upgrade flow.
_BRIDGE_UPGRADE_BYPASS_NONCE="$(date -u '+%Y%m%dT%H%M%SZ')-$$-${RANDOM}${RANDOM}"
export BRIDGE_LAYOUT_RESOLVER_BYPASS="upgrade-migrate:${_BRIDGE_UPGRADE_BYPASS_NONCE}"
export BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID=$$
# Always clear the bypass at exit so a crashed / interrupted upgrade
# can never leave the env in a state that disarms the resolver for
# subsequent shells in the same process tree.
# Issue #682: emit a JSON failure envelope on stdout when --json is set
# and the script is exiting non-zero without having already emitted JSON
# (bridge_die, set -e abort, external helper rc!=0). The emit body is
# defined later (`bridge_upgrade_emit_failure_json`); the trap is
# installed up here so very-early bridge_die calls (option parsing, dirty
# source check) still produce a JSON envelope when --json was passed.
_bridge_upgrade_exit_handler() {
  local rc=$?
  unset BRIDGE_LAYOUT_RESOLVER_BYPASS BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID
  if [[ $rc -ne 0 \
        && "${JSON:-0}" == "1" \
        && "${_BRIDGE_UPGRADE_JSON_EMITTED:-0}" != "1" ]] \
      && declare -F bridge_upgrade_emit_failure_json >/dev/null 2>&1; then
    bridge_upgrade_emit_failure_json "$rc" || true
  fi
  return "$rc"
}
trap _bridge_upgrade_exit_handler EXIT
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
# shellcheck source=lib/bridge-cleanup.sh
source "$SCRIPT_DIR/lib/bridge-cleanup.sh"
ORIGINAL_ARGS=("$@")

SOURCE_ROOT="$SCRIPT_DIR"
TARGET_ROOT="$HOME/.agent-bridge"
SUBCOMMAND="apply"
PULL=0
PULL_EXPLICIT=0
SOURCE_EXPLICIT=0
CHANNEL="${AGENT_BRIDGE_UPGRADE_CHANNEL:-stable}"
CHANNEL_EXPLICIT=0
REQUESTED_VERSION=""
REQUESTED_REF=""
CHECK_ONLY=0
DRY_RUN=0
RESTART_DAEMON=1
RESTART_AGENTS=1
RESTART_AGENTS_EXPLICIT=0
JSON=0
ALLOW_DIRTY=0
ALLOW_DIRTY_SOURCE=0
STRICT_MERGE=0
BACKUP=1
MIGRATE_AGENTS=1
BACKUP_ROOT=""
ANALYSIS_JSON='{}'
TARGET_REF=""
TARGET_VERSION=""
TARGET_HEAD=""
SOURCE_VERSION=""
SOURCE_REF=""
SOURCE_HEAD=""
SOURCE_RECLASSIFY_JSON='{}'
SHARED_SETTINGS_RERENDER_JSON='{"mode":"skipped","count":0,"failed_count":0,"candidates":[]}'
ISOLATION_V2_MIGRATION_JSON=""

# Issue #752 W3d (M10/M11/M12): partial-failure surfacing for late
# upgrade subsystems (shared rerender / channel-policy refresh / profile
# relink). Each site appends a stable name when its post-step probe
# reports failures so the final --json envelope can emit
# `status:"partial"` with `partial_failures:[...]`. These are not
# upgrade-fatal — operators must see them, but the rest of the upgrade
# (daemon restart, [upgrade-complete] task, etc.) still runs. Mirrors the
# post-#754 `apply_for_upgrade` consumer pattern (see
# lib/bridge-isolation-v2-migrate.sh:1709).
_upgrade_partial_failures=()

# Issue #682: every exit path from `apply` must emit a single valid JSON
# document on stdout when --json is set. The success/dry-run paths emit
# at the bottom of the script (search for `mode": "upgrade"`); the
# bridge_die / set -e / external-helper-rc!=0 paths previously dropped
# straight to text on stderr and an empty stdout, breaking the contract
# for programmatic operators (issue #682 Finding 1, surfaced by the
# v0.7.7 → v0.8.4 OrbStack VM E2E retest, task #4195 Scenario C).
#
# `_BRIDGE_UPGRADE_JSON_EMITTED` flips to 1 once the success-path
# envelope prints; the EXIT trap emits a `rc != 0 + error{...}` envelope
# only when the flag is still 0. `_BRIDGE_UPGRADE_DIE_REASON` /
# `_BRIDGE_UPGRADE_DIE_DETAIL` / `_BRIDGE_UPGRADE_DIE_REMEDIATION` are
# populated by the migration block so the emitted envelope carries
# actionable detail rather than just "rc=1".
_BRIDGE_UPGRADE_JSON_EMITTED=0
_BRIDGE_UPGRADE_DIE_REASON=""
_BRIDGE_UPGRADE_DIE_DETAIL=""
_BRIDGE_UPGRADE_DIE_REMEDIATION=""

usage() {
  cat <<EOF
Usage:
  $(basename "$0") [--source <repo-dir>] [--target <bridge-home>] [--apply] [--check] [--channel stable|dev|current] [--version <semver>] [--ref <git-ref>] [--pull|--no-pull] [--restart-daemon|--no-restart-daemon] [--restart-agents|--no-restart-agents] [--dry-run] [--json] [--allow-dirty] [--allow-dirty-source] [--strict-merge] [--no-backup] [--no-migrate-agents]
  $(basename "$0") analyze [--source <repo-dir>] [--target <bridge-home>] [--json]
  $(basename "$0") rollback [--target <bridge-home>] [--backup-root <dir>] [--restart-daemon|--no-restart-daemon] [--restart-agents|--no-restart-agents] [--dry-run] [--json]
  $(basename "$0") conflicts list [--target <bridge-home>] [--json]

Updates a live Agent Bridge install from a repo checkout while preserving user-owned
customizations such as:
- agent-roster.local.sh
- state/, logs/, shared/
- backups/, worktrees/
- live agent homes under agents/<agent>/

The repo checkout remains source of truth for core code. Live-only operator changes are preserved.
When run from an installed live copy without --source, the last recorded source checkout is reused and pulled automatically.
Default channel is stable: the latest vX.Y.Z tag is used when one exists. Use --channel dev to track main, or --channel current/--source to deploy the current checkout.
EOF
}

# Issue #682: emit a single valid JSON envelope on stdout when --json is
# set and the script is exiting non-zero before the success/dry-run JSON
# emission point. Idempotent: the EXIT trap calls this only when
# `_BRIDGE_UPGRADE_JSON_EMITTED` is still 0. Best-effort: any internal
# failure falls back to a hardcoded minimal envelope so the caller
# always gets parseable JSON.
#
# Args:
#   $1  exit code (rc)
bridge_upgrade_emit_failure_json() {
  local rc="${1:-1}"
  local reason="${_BRIDGE_UPGRADE_DIE_REASON:-}"
  local detail="${_BRIDGE_UPGRADE_DIE_DETAIL:-}"
  local remediation="${_BRIDGE_UPGRADE_DIE_REMEDIATION:-}"
  if [[ -z "$reason" ]]; then
    reason="upgrade aborted (rc=${rc})"
  fi
  if [[ -z "$detail" ]]; then
    detail="agent-bridge upgrade exited with rc=${rc} before reaching the success/dry-run JSON emission point. See stderr for the textual error."
  fi
  if [[ -z "$remediation" ]]; then
    remediation="re-run with --json --dry-run to inspect the planned changes; consult agent-bridge logs / stderr for the underlying failure."
  fi
  # Pass values via argv (escapes safely for any input — newlines, quotes,
  # unicode). Empty strings are forwarded as-is and rendered as null in the
  # envelope when the corresponding bash var was empty.
  if ! python3 - \
        "$rc" \
        "$reason" \
        "$detail" \
        "$remediation" \
        "${SOURCE_VERSION:-}" \
        "${SOURCE_ROOT:-}" \
        "${SOURCE_REF:-}" \
        "${SOURCE_HEAD:-}" \
        "${TARGET_ROOT:-}" \
        "${CHANNEL:-}" \
        "${TARGET_REF:-}" \
        "${TARGET_VERSION:-}" \
        "${TARGET_HEAD:-}" \
        "${DRY_RUN:-0}" \
        "${ISOLATION_V2_MIGRATION_JSON:-}" \
        <<'PY' 2>/dev/null
import json, sys

(rc, reason, detail, remediation,
 source_version, source_root, source_ref, source_head,
 target_root, channel, target_ref, target_version, target_head,
 dry_run, iso_v2_json) = sys.argv[1:16]

def _or_none(s):
    return s if s else None

def _load_json_str(s):
    if not s:
        return None
    try:
        return json.loads(s)
    except (ValueError, TypeError):
        return {"_raw": s, "_parse_error": True}

payload = {
    "mode": "upgrade",
    "rc": int(rc),
    "error": {
        "reason": reason,
        "detail": detail,
        "remediation": remediation,
    },
    "version": _or_none(source_version),
    "source_root": _or_none(source_root),
    "source_ref": _or_none(source_ref),
    "source_head": _or_none(source_head),
    "target_root": _or_none(target_root),
    "channel": _or_none(channel),
    "target_ref": _or_none(target_ref),
    "target_version": _or_none(target_version),
    "target_head": _or_none(target_head),
    "dry_run": dry_run == "1",
    "isolation_v2_migration": _load_json_str(iso_v2_json),
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  then
    # Fallback: minimal hand-rolled JSON if python invocation fails
    # entirely. Operators still get a parseable envelope.
    printf '{"mode":"upgrade","rc":%d,"error":{"reason":"emit-helper-failed","detail":"python3 emission of bridge_upgrade_emit_failure_json failed","remediation":"inspect bridge-upgrade stderr"}}\n' "$rc"
  fi
  _BRIDGE_UPGRADE_JSON_EMITTED=1
}

bridge_upgrade_version_from_file() {
  local root="$1"
  if [[ -f "$root/VERSION" ]]; then
    head -n 1 "$root/VERSION" | tr -d '[:space:]'
    return 0
  fi
  printf '0.0.0-dev'
}

bridge_upgrade_current_ref() {
  local root="$1"
  git -C "$root" describe --tags --exact-match HEAD 2>/dev/null \
    || git -C "$root" rev-parse --abbrev-ref HEAD 2>/dev/null \
    || printf '-'
}

bridge_upgrade_latest_stable_tag() {
  local root="$1"
  local tags
  tags="$(git -C "$root" tag --list 'v[0-9]*.[0-9]*.[0-9]*')"
  python3 -c '
import re
import sys

tags = [line.strip() for line in sys.stdin if re.fullmatch(r"v\d+\.\d+\.\d+", line.strip())]
tags.sort(key=lambda tag: tuple(int(part) for part in tag[1:].split(".")))
print(tags[-1] if tags else "")
' <<<"$tags"
}

bridge_upgrade_normalize_version_tag() {
  local version="$1"
  version="${version#v}"
  if [[ ! "$version" =~ ^[0-9]+[.][0-9]+[.][0-9]+$ ]]; then
    bridge_die "--version 값은 semver 형식이어야 합니다. 예: 0.1.0"
  fi
  printf 'v%s' "$version"
}

bridge_upgrade_head_for_ref() {
  local root="$1"
  local ref="$2"
  git -C "$root" rev-parse "${ref}^{commit}" 2>/dev/null || true
}

bridge_upgrade_version_at_ref() {
  local root="$1"
  local ref="$2"
  local version=""
  version="$(git -C "$root" show "${ref}:VERSION" 2>/dev/null | head -n 1 | tr -d '[:space:]' || true)"
  if [[ -n "$version" ]]; then
    printf '%s' "$version"
  else
    bridge_upgrade_version_from_file "$root"
  fi
}

bridge_upgrade_with_target_env() {
  local target_root="$1"
  shift

  env -i \
    HOME="${HOME:-}" \
    PATH="${PATH:-/usr/bin:/bin}" \
    TMPDIR="${TMPDIR:-/tmp}" \
    USER="${USER:-}" \
    SHELL="${SHELL:-}" \
    TERM="${TERM:-dumb}" \
    BRIDGE_HOME="$target_root" \
    BRIDGE_ROSTER_FILE="$target_root/agent-roster.sh" \
    BRIDGE_ROSTER_LOCAL_FILE="$target_root/agent-roster.local.sh" \
    BRIDGE_STATE_DIR="$target_root/state" \
    BRIDGE_ACTIVE_AGENT_DIR="$target_root/state/agents" \
    BRIDGE_HISTORY_DIR="$target_root/state/history" \
    BRIDGE_WORKTREE_META_DIR="$target_root/state/worktrees" \
    BRIDGE_ACTIVE_ROSTER_TSV="$target_root/state/active-roster.tsv" \
    BRIDGE_ACTIVE_ROSTER_MD="$target_root/state/active-roster.md" \
    BRIDGE_DAEMON_PID_FILE="$target_root/state/daemon.pid" \
    BRIDGE_DAEMON_LOG="$target_root/state/daemon.log" \
    BRIDGE_DAEMON_CRASH_LOG="$target_root/state/daemon-crash.log" \
    BRIDGE_TASK_DB="$target_root/state/tasks.db" \
    BRIDGE_PROFILE_STATE_DIR="$target_root/state/profiles" \
    BRIDGE_CRON_STATE_DIR="$target_root/state/cron" \
    BRIDGE_CRON_HOME_DIR="$target_root/cron" \
    BRIDGE_NATIVE_CRON_JOBS_FILE="$target_root/cron/jobs.json" \
    BRIDGE_CRON_DISPATCH_WORKER_DIR="$target_root/state/cron/workers" \
    BRIDGE_WORKTREE_ROOT="$target_root/worktrees" \
    BRIDGE_AGENT_HOME_ROOT="$target_root/agents" \
    BRIDGE_RUNTIME_ROOT="$target_root/runtime" \
    BRIDGE_RUNTIME_SCRIPTS_DIR="$target_root/runtime/scripts" \
    BRIDGE_RUNTIME_SKILLS_DIR="$target_root/runtime/skills" \
    BRIDGE_RUNTIME_SHARED_DIR="$target_root/runtime/shared" \
    BRIDGE_RUNTIME_SHARED_TOOLS_DIR="$target_root/runtime/shared/tools" \
    BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="$target_root/runtime/shared/references" \
    BRIDGE_RUNTIME_MEMORY_DIR="$target_root/runtime/memory" \
    BRIDGE_RUNTIME_CREDENTIALS_DIR="$target_root/runtime/credentials" \
    BRIDGE_RUNTIME_SECRETS_DIR="$target_root/runtime/secrets" \
    BRIDGE_RUNTIME_CONFIG_FILE="$target_root/runtime/bridge-config.json" \
    BRIDGE_HOOKS_DIR="$target_root/hooks" \
    BRIDGE_LOG_DIR="$target_root/logs" \
    BRIDGE_AUDIT_LOG="$target_root/logs/audit.jsonl" \
    BRIDGE_SHARED_DIR="$target_root/shared" \
    BRIDGE_TASK_NOTE_DIR="$target_root/shared/tasks" \
    BRIDGE_DASHBOARD_STATE_FILE="$target_root/state/dashboard.json" \
    BRIDGE_DISCORD_RELAY_STATE_FILE="$target_root/state/discord-relay.json" \
    BRIDGE_LAYOUT_RESOLVER_BYPASS="${BRIDGE_LAYOUT_RESOLVER_BYPASS:-}" \
    BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID="${BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID:-}" \
    "$@"
}

bridge_upgrade_propagate_claude_hooks() {
  local target_root="$1"

  # Re-register every Claude hook (Stop / SessionStart / UserPromptSubmit /
  # PromptGuard / ToolPolicy) onto the shared base settings.json before the
  # subsequent rerender-settings call merges the result into per-agent
  # effective settings. Without this, a release that adds a new hook event
  # ships the new script in `hooks/` but the existing per-agent settings.json
  # never registers it — only fresh installs pick up the new hook.
  #
  # The ensure helpers are idempotent: an already-registered hook is left in
  # place, missing entries are appended. They write to
  # ~/.agent-bridge/.claude/settings.json (the shared base file), which means
  # a single pass per upgrade is enough — every Claude agent's effective
  # settings then inherits the new hook list via the rerender step.
  bridge_upgrade_with_target_env "$target_root" "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    source "$1/bridge-lib.sh"
    bridge_load_roster
    BRIDGE_AGENT_HOME_ROOT="$1/agents"
    workdir=""
    launch_cmd=""
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent" 2>/dev/null || true)" == "claude" ]] || continue
      workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
      [[ -n "$workdir" ]] || continue
      # Issue #570: managed autoCompactWindow default is unconditionally
      # 1_000_000; launch_cmd is forwarded for caller-signature parity with
      # helpers that still accept it (no longer consulted by the renderer).
      launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || true)"
      # Issue #555: forward agent id so each ensure-*-hook helper relinks
      # the per-agent effective file (not the install-wide one). Mixed-
      # model installs no longer last-rerender-wins on per-agent managed
      # defaults like `autoCompactWindow`.
      bridge_ensure_claude_stop_hook "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
      bridge_ensure_claude_session_start_hook "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
      bridge_ensure_claude_prompt_hook "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
      bridge_ensure_claude_prompt_guard_hook "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
      bridge_ensure_claude_tool_policy_hooks "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
      # Issue #509 / PR #510 deployment gap: PreCompact was the one event
      # the propagation loop never re-registered, so hosts that upgraded
      # without restarting agents shipped hooks/pre-compact.py code with
      # no settings.json wire. Adding it here closes that gap on every
      # subsequent upgrade.
      bridge_ensure_claude_pre_compact_hook "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
    done
  ' -- "$target_root"
}

bridge_upgrade_propagate_claude_shared_settings() {
  local target_root="$1"

  # Hook ensure must run BEFORE rerender so the rendered effective settings
  # include any newly-added hook entries that the release shipped (#2303 Gap 3).
  bridge_upgrade_propagate_claude_hooks "$target_root" >/dev/null 2>&1 || true

  bridge_upgrade_with_target_env "$target_root" \
    "$BRIDGE_BASH_BIN" "$target_root/bridge-agent.sh" rerender-settings --apply --json
}

bridge_upgrade_collect_agent_restart_report() {
  local target_root="$1"
  local dry_run="${2:-0}"
  local source_root="${3:-$SOURCE_ROOT}"

  # Tuple format (tab-separated, 7 columns — grew from 5 to capture
  # restart-failure diagnostics per issue #256 Gap 1):
  #   <agent>\t<status>\t<reason>\t<attached>\t<session>\t<exit_code>\t<log_tail_b64>
  #
  # - exit_code is the return of `bridge-agent.sh restart <agent>` and is
  #   only meaningful when status == "failed"; empty otherwise.
  # - log_tail_b64 is the base64-encoded last ~5 lines of the agent's
  #   most recently modified `.err.log`, or the `.log` when `.err.log`
  #   is empty (the silent-exit common case). Base64 keeps newlines from
  #   breaking the tab framing. Empty when status != "failed" or the
  #   agent has no log directory yet. See `bridge_agent_log_dir`.
  #
  # Issue 3 (v0.11.0): each `bridge-agent.sh restart` is now wrapped by
  # `bridge_with_timeout` so a hung per-agent restart cannot block the
  # whole upgrade. Default timeout 60s, overridable via
  # BRIDGE_UPGRADE_RESTART_TIMEOUT_SECONDS. A 124/137 exit-code from the
  # timeout helper is mapped to reason="restart-timeout" so the operator
  # summary distinguishes timeout from ordinary failure without
  # inspecting the audit log.
  local restart_timeout="${BRIDGE_UPGRADE_RESTART_TIMEOUT_SECONDS:-60}"
  bridge_upgrade_with_target_env "$target_root" "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    target_root="$1"
    dry_run="$2"
    source_root="$3"
    restart_timeout="$4"
    source "$source_root/bridge-lib.sh"
    bridge_load_roster

    agent=""
    session=""
    attached=0
    status=""
    reason=""
    exit_code=""
    log_tail_b64=""

    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue

      session="$(bridge_agent_session "$agent")"
      attached=0
      status="skipped"
      reason="inactive"
      exit_code=""
      log_tail_b64=""

      if [[ "$(bridge_agent_loop "$agent")" != "1" ]]; then
        reason="not-loop"
      elif bridge_agent_manual_stop_active "$agent"; then
        reason="manual-stop"
      elif [[ -z "$session" ]]; then
        reason="no-session"
      elif ! bridge_tmux_session_exists "$session"; then
        reason="inactive"
      else
        attached="$(bridge_tmux_session_attached_count "$session" 2>/dev/null || printf "0")"
        [[ "$attached" =~ ^[0-9]+$ ]] || attached=0
        if (( attached > 0 )); then
          reason="attached"
        elif [[ "$dry_run" == "1" ]]; then
          status="would-restart"
          reason="eligible"
        elif bridge_with_timeout "$restart_timeout" "upgrade_agent_restart:$agent" \
             "$BRIDGE_BASH_BIN" "$target_root/bridge-agent.sh" restart "$agent" \
             >/dev/null 2>&1; then
          status="restarted"
          reason="eligible"
          exit_code=0
        else
          exit_code=$?
          status="failed"
          if [[ "$exit_code" == "124" || "$exit_code" == "137" ]]; then
            reason="restart-timeout"
          else
            reason="restart-failed"
          fi
          # Capture last ~5 log lines for the summary. Prefer .err.log;
          # fall back to .log when .err.log is empty (silent-exit case).
          # All subshell errors are tolerated so a missing log dir does
          # not mask the original restart failure.
          log_dir="$(bridge_agent_log_dir "$agent" 2>/dev/null || true)"
          log_tail=""
          if [[ -n "${log_dir:-}" && -d "$log_dir" ]]; then
            err_latest="$(ls -t "$log_dir"/*.err.log 2>/dev/null | head -n 1 || true)"
            if [[ -n "${err_latest:-}" && -s "$err_latest" ]]; then
              log_tail="$(tail -n 5 "$err_latest" 2>/dev/null || true)"
            else
              log_latest="$(ls -t "$log_dir"/*.log 2>/dev/null | head -n 1 || true)"
              if [[ -n "${log_latest:-}" ]]; then
                log_tail="$(tail -n 5 "$log_latest" 2>/dev/null || true)"
              fi
            fi
          fi
          if [[ -n "$log_tail" ]]; then
            log_tail_b64="$(printf "%s" "$log_tail" | base64 | tr -d "\n")"
          fi
        fi
      fi

      printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
        "$agent" "$status" "$reason" "$attached" "$session" \
        "${exit_code:-}" "${log_tail_b64:-}"
    done
  ' -- "$target_root" "$dry_run" "$source_root" "$restart_timeout"
}

# Issue 4 (v0.11.0): reconcile the initial restart report with the
# daemon's subsequent launch cycle. A `failed`/`restart-timeout` row
# whose agent ends up active+session-running after a bounded settle
# window is reclassified to `recovered_by_daemon`, with the original
# reason preserved as `daemon-recovered:was=<reason>` so the operator
# can still triage the underlying issue from the JSON detail.
#
# The settle is poll-based (1s interval, capped at
# BRIDGE_UPGRADE_RECOVERY_SETTLE_SECONDS, default 20s) and skipped
# entirely when the report contains no `failed` rows or when dry_run=1.
bridge_upgrade_reconcile_agent_restart_recovery() {
  local target_root="$1"
  local report="$2"
  local dry_run="${3:-0}"
  local source_root="${4:-$SOURCE_ROOT}"
  local settle_seconds="${5:-${BRIDGE_UPGRADE_RECOVERY_SETTLE_SECONDS:-20}}"
  # Defensive normalization, matches the style of bridge_with_timeout.
  # An invalid override (e.g. BRIDGE_UPGRADE_RECOVERY_SETTLE_SECONDS=abc)
  # would otherwise reach the inner `set -u` arithmetic and crash the
  # reconcile pass — task #2067 review hardening.
  [[ "$settle_seconds" =~ ^[0-9]+$ ]] || settle_seconds=20

  if [[ -z "$report" ]]; then
    printf '%s' "$report"
    return 0
  fi
  if [[ "$dry_run" == "1" ]]; then
    printf '%s' "$report"
    return 0
  fi
  # Skip the wait entirely when there is nothing to reconcile.
  if ! grep -qE $'\t''failed'$'\t' <<<"$report"; then
    printf '%s' "$report"
    return 0
  fi

  bridge_upgrade_with_target_env "$target_root" "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    target_root="$1"
    source_root="$2"
    settle_seconds="$3"
    report="$4"
    source "$source_root/bridge-lib.sh"
    bridge_load_roster

    # Tab-separated read inside this -lc body: $'\t' is awkward to embed
    # in a single-quoted -lc heredoc, so materialise the tab into a
    # variable. printf is portable across the bash versions we support.
    TAB="$(printf "\t")"

    # Collect the agents that need a recovery probe up front so the
    # poll loop can short-circuit as soon as all of them are active.
    failed_agents=()
    while IFS="$TAB" read -r agent status _reason _attached _session _exit_code _log_tail; do
      [[ -n "$agent" ]] || continue
      if [[ "$status" == "failed" ]]; then
        failed_agents+=("$agent")
      fi
    done <<<"$report"

    declare -A recovered=()
    if (( ${#failed_agents[@]} > 0 )); then
      elapsed=0
      interval=1
      while (( elapsed < settle_seconds )); do
        all_recovered=1
        for agent in "${failed_agents[@]}"; do
          if [[ -n "${recovered[$agent]:-}" ]]; then
            continue
          fi
          if bridge_agent_is_active "$agent"; then
            recovered[$agent]=1
          else
            all_recovered=0
          fi
        done
        if (( all_recovered == 1 )); then
          break
        fi
        sleep "$interval"
        elapsed=$(( elapsed + interval ))
      done
      # Final probe in case the last sleep elapsed without re-checking.
      for agent in "${failed_agents[@]}"; do
        if [[ -n "${recovered[$agent]:-}" ]]; then
          continue
        fi
        if bridge_agent_is_active "$agent"; then
          recovered[$agent]=1
        fi
      done
    fi

    # Rewrite the report, reclassifying recovered rows. The 7-column
    # tab-separated shape is preserved exactly; log_tail_b64 is NOT
    # decoded/re-encoded.
    while IFS="$TAB" read -r agent status reason attached session exit_code log_tail_b64; do
      [[ -n "$agent" ]] || continue
      if [[ "$status" == "failed" && -n "${recovered[$agent]:-}" ]]; then
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$agent" "recovered_by_daemon" "daemon-recovered:was=$reason" \
          "$attached" "$session" "$exit_code" "$log_tail_b64"
      else
        printf "%s\t%s\t%s\t%s\t%s\t%s\t%s\n" \
          "$agent" "$status" "$reason" "$attached" "$session" \
          "$exit_code" "$log_tail_b64"
      fi
    done <<<"$report"
  ' -- "$target_root" "$source_root" "$settle_seconds" "$report"
}

bridge_upgrade_agent_restart_json() {
  local report="$1"
  local enabled="$2"
  local dry_run="${3:-0}"

  # JSON key contract (post-#257): dry-run reports *eligibility*, not success;
  # apply reports the `bridge-agent.sh restart` exit-0 count, not agent health.
  #   - restart_eligible / restart_eligible_agents: dry-run candidates. This
  #     is what we would attempt; it does NOT predict whether the agent will
  #     stay stably up after launch (plugin resolution, settings corruption,
  #     dependency outages can still surface at apply).
  #   - restart_attempted_ok / restart_attempted_ok_agents: apply tally of
  #     `bridge-agent.sh restart` commands that returned exit 0. Does NOT
  #     prove the agent survived the first few seconds after launch; that
  #     requires post-restart health reconciliation (tracked in #256).
  # The prior keys `would_restart`/`restarted` over-promised at both layers
  # and caused the #253→#254 misdiagnosis. Renamed here per issue #257.
  python3 - "$enabled" "$dry_run" "$report" <<'PY'
import base64
import json
import sys

enabled = sys.argv[1] == "1"
dry_run = sys.argv[2] == "1"
report = sys.argv[3]
payload = {
    "enabled": enabled,
    "dry_run": dry_run,
    "considered": 0,
    "eligible": 0,
    "restart_eligible": 0,
    "restart_attempted_ok": 0,
    "recovered_by_daemon": 0,
    "failed": 0,
    "skipped": 0,
    "restart_attempted_ok_agents": [],
    "restart_eligible_agents": [],
    "recovered_by_daemon_agents": [],
    "failed_agents": [],
    "failed_details": [],
    "recovered_by_daemon_details": [],
    "skipped_reasons": {},
}


def _decode_log_tail(raw_b64):
    """Return the decoded log-tail string or None when absent/corrupt.

    Deliberately plain-Python (no PEP 604 annotation) because the
    reference install's system python is 3.9.6 — `str | None` would
    raise `TypeError` at function-definition time before the summary
    ever ran. See PR #261 round-1 review.
    """
    if not raw_b64:
        return None
    try:
        decoded = base64.b64decode(raw_b64, validate=False)
    except Exception:  # noqa: BLE001 — b64 is operator-captured log; failing open with None is fine
        return None
    return decoded.decode("utf-8", errors="replace")


for raw in report.splitlines():
    raw = raw.rstrip("\n")
    if not raw:
        continue
    # Tuple format (see bridge_upgrade_collect_agent_restart_report): 7 cols.
    # Older builds may emit 5 cols (pre-#256); tolerate that shape so a
    # half-upgraded host doesn't crash the aggregator.
    parts = (raw.split("\t", 6) + ["", "", "", "", "", "", ""])[:7]
    agent, status, reason, _attached, _session, exit_code, log_tail_b64 = parts
    payload["considered"] += 1
    if reason == "eligible":
        payload["eligible"] += 1
    if status == "would-restart":
        payload["restart_eligible"] += 1
        payload["restart_eligible_agents"].append(agent)
    elif status == "restarted":
        payload["restart_attempted_ok"] += 1
        payload["restart_attempted_ok_agents"].append(agent)
    elif status == "failed":
        payload["failed"] += 1
        payload["failed_agents"].append(agent)
        detail = {"agent": agent, "reason": reason}
        try:
            detail["exit_code"] = int(exit_code) if exit_code else None
        except ValueError:
            detail["exit_code"] = None
        detail["last_log_tail"] = _decode_log_tail(log_tail_b64)
        payload["failed_details"].append(detail)
    elif status == "recovered_by_daemon":
        # Issue 4 (v0.11.0): daemon launched the agent after our initial
        # restart attempt failed/timed-out. Counted separately so the
        # operator-facing summary stops over-reporting "failed" when the
        # daemon cycle absorbed the transient. Preserves the original
        # reason (encoded as `daemon-recovered:was=<original>`) plus the
        # exit_code + log_tail so the underlying issue is still
        # diagnosable from the JSON.
        payload["recovered_by_daemon"] += 1
        payload["recovered_by_daemon_agents"].append(agent)
        detail = {"agent": agent, "was_reason": reason.split("was=", 1)[-1] if "was=" in reason else reason}
        try:
            detail["exit_code"] = int(exit_code) if exit_code else None
        except ValueError:
            detail["exit_code"] = None
        detail["last_log_tail"] = _decode_log_tail(log_tail_b64)
        payload["recovered_by_daemon_details"].append(detail)
    else:
        payload["skipped"] += 1
        payload["skipped_reasons"][reason] = payload["skipped_reasons"].get(reason, 0) + 1

print(json.dumps(payload, ensure_ascii=False))
PY
}

bridge_upgrade_print_agent_restart_summary() {
  local payload="$1"

  # Text-summary labels align with the JSON contract above: eligibility
  # vs restart-attempted-ok. A dry-run-only disclaimer warns that the
  # count is pre-launch eligibility; runtime failures (plugin resolution,
  # settings corruption, dependency outages) only surface at apply. See
  # issue #257 for why the prior "would_restart/restarted" labels misled
  # operators into reading accurate planning where none existed.
  python3 - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
print(f"agent_restart_enabled: {'yes' if payload.get('enabled') else 'no'}")
print(f"agent_restart_considered: {payload.get('considered', 0)}")
print(f"agent_restart_eligible: {payload.get('eligible', 0)}")
print(f"agent_restart_attempted_ok: {payload.get('restart_attempted_ok', 0)}")
print(f"agent_restart_recovered_by_daemon: {payload.get('recovered_by_daemon', 0)}")
print(f"agent_restart_failed: {payload.get('failed', 0)}")
print(f"agent_restart_skipped: {payload.get('skipped', 0)}")
if payload.get("restart_eligible"):
    print(f"agent_restart_eligible_count: {payload.get('restart_eligible', 0)}")
if payload.get("restart_attempted_ok_agents"):
    print(f"agent_restart_attempted_ok_agents: {','.join(payload['restart_attempted_ok_agents'])}")
if payload.get("restart_eligible_agents"):
    print(f"agent_restart_eligible_agents: {','.join(payload['restart_eligible_agents'])}")
if payload.get("failed_agents"):
    print(f"agent_restart_failed_agents: {','.join(payload['failed_agents'])}")
if payload.get("recovered_by_daemon_agents"):
    print(f"agent_restart_recovered_by_daemon_agents: {','.join(payload['recovered_by_daemon_agents'])}")
# #256 Gap 1: surface per-agent exit code + last log tail when a restart
# failed, so the operator can triage without hand-grepping log dirs.
for detail in payload.get("failed_details", []) or []:
    agent_id = detail.get("agent") or "unknown"
    exit_code = detail.get("exit_code")
    exit_label = str(exit_code) if isinstance(exit_code, int) else "n/a"
    tail = detail.get("last_log_tail") or ""
    # Flatten newlines + cap to keep the summary one line per agent;
    # the full decoded tail is always available in the JSON payload.
    tail_flat = " ".join(tail.split())
    if len(tail_flat) > 240:
        tail_flat = tail_flat[:237] + "..."
    if tail_flat:
        print(f"agent_restart_failed_detail_{agent_id}: exit={exit_label} tail={tail_flat}")
    else:
        print(f"agent_restart_failed_detail_{agent_id}: exit={exit_label} tail=<no log tail captured>")
# Issue 4 (v0.11.0): surface the same shape for recovered_by_daemon rows
# so the operator can still triage the original failure even though the
# daemon absorbed the transient.
for detail in payload.get("recovered_by_daemon_details", []) or []:
    agent_id = detail.get("agent") or "unknown"
    exit_code = detail.get("exit_code")
    exit_label = str(exit_code) if isinstance(exit_code, int) else "n/a"
    was_reason = detail.get("was_reason") or "unknown"
    tail = detail.get("last_log_tail") or ""
    tail_flat = " ".join(tail.split())
    if len(tail_flat) > 240:
        tail_flat = tail_flat[:237] + "..."
    if tail_flat:
        print(f"agent_restart_recovered_detail_{agent_id}: was={was_reason} exit={exit_label} tail={tail_flat}")
    else:
        print(f"agent_restart_recovered_detail_{agent_id}: was={was_reason} exit={exit_label} tail=<no log tail captured>")
if payload.get("recovered_by_daemon", 0) > 0 and not payload.get("dry_run"):
    print(
        "agent_restart_note: agent(s) above failed the in-upgrade "
        "restart but the daemon subsequently launched them. They are "
        "not failures from the operator's perspective; verify with "
        "`agent-bridge status`."
    )
for reason in sorted(payload.get("skipped_reasons", {})):
    print(f"agent_restart_skipped_{reason}: {payload['skipped_reasons'][reason]}")
if payload.get("dry_run") and payload.get("restart_eligible"):
    print(
        "agent_restart_note: dry-run reports pre-launch eligibility only. "
        "Runtime failures (plugin resolution, settings corruption, "
        "dependency outages) will surface only in the actual apply run."
    )
PY
}

bridge_upgrade_channel_guard_report() {
  local source_root="$1"
  local target_root="$2"

  bridge_upgrade_with_target_env "$target_root" "$BRIDGE_BASH_BIN" -s -- "$source_root" "$target_root" <<'EOF'
set -euo pipefail
source_root="$1"
target_root="$2"
source "$source_root/bridge-lib.sh"
bridge_load_roster

agent=""
session=""
active="no"
reason=""
required=""

for agent in "${BRIDGE_AGENT_IDS[@]}"; do
  if [[ "$(bridge_agent_channel_status "$agent")" != "miss" ]]; then
    continue
  fi
  session="$(bridge_agent_session "$agent")"
  active="no"
  if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
    active="yes"
  fi
  reason="$(bridge_agent_channel_runtime_drift_reason "$agent")"
  if [[ -z "$reason" ]]; then
    reason="$(bridge_agent_channel_status_reason "$agent")"
  fi
  reason="${reason//$'\t'/ }"
  reason="${reason//$'\n'/ }"
  required="$(bridge_agent_channels_csv "$agent")"
  printf "%s\t%s\t%s\t%s\n" "$agent" "$active" "$required" "$reason"
done
EOF
}

bridge_upgrade_channel_guard_json() {
  local report="$1"

  python3 - "$report" <<'PY'
import json
import sys

items = []
active_count = 0
for raw in sys.argv[1].splitlines():
    raw = raw.rstrip("\n")
    if not raw:
        continue
    agent, active, required, reason = (raw.split("\t", 3) + ["", "", "", ""])[:4]
    is_active = active == "yes"
    if is_active:
        active_count += 1
    items.append(
        {
            "agent": agent,
            "active": is_active,
            "required_channels": required,
            "reason": reason,
        }
    )

print(json.dumps({"count": len(items), "active_count": active_count, "agents": items}, ensure_ascii=False))
PY
}

bridge_upgrade_print_channel_guard_summary() {
  local payload="$1"

  python3 - "$payload" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
items = payload.get("agents", [])
if not items:
    raise SystemExit(0)

print(f"channel_guard_miss: {payload.get('count', 0)}")
print(f"channel_guard_active_miss: {payload.get('active_count', 0)}")
print("[warn] live roster has channel/runtime mismatches that can block restart:")
for item in items[:10]:
    suffix = " (active)" if item.get("active") else ""
    print(f"  - {item.get('agent')}{suffix}: {item.get('reason')}")
if len(items) > 10:
    print(f"  ... +{len(items) - 10} more")
PY
}

bridge_upgrade_installed_field() {
  local target_root="$1"
  local field="$2"
  python3 - "$target_root/state/upgrade/last-upgrade.json" "$field" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
field = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)
value = payload.get(field, "")
print("" if value is None else str(value))
PY
}

bridge_upgrade_conflicts_dispatch() {
  # Issue #394: thin shell dispatcher for the `conflicts` lifecycle
  # subcommands. Delegates to bridge-upgrade.py so list/diff/adopt/
  # discard/archive/reconcile share one implementation and one
  # at-write-hash record format. The earlier PR-1 shell `list` is
  # superseded; the python-side `list` adds the
  # `live_target_hash_changed_since_write` column needed by the new
  # reconcile contract.
  local sub="${1:-list}"
  shift || true
  local target="${BRIDGE_HOME:-$HOME/.agent-bridge}"
  local -a forward=()
  local seen_target=0
  while (( $# > 0 )); do
    case "$1" in
      --target)
        [[ $# -lt 2 ]] && bridge_die "agb upgrade conflicts: --target 뒤에 값을 지정하세요."
        target="$2"
        seen_target=1
        shift 2
        ;;
      --target=*)
        target="${1#--target=}"
        seen_target=1
        shift
        ;;
      -h|--help|help)
        cat <<'USAGE'
Usage:
  agb upgrade conflicts list     [--target <bridge-home>] [--json]
  agb upgrade conflicts diff     [--target <bridge-home>] <conflict-path>
  agb upgrade conflicts adopt    [--target <bridge-home>] [--yes] <conflict-path>
  agb upgrade conflicts discard  [--target <bridge-home>] [--yes] <conflict-path>
  agb upgrade conflicts archive  [--target <bridge-home>] [--yes] <conflict-path>
  agb upgrade conflicts reconcile [--target <bridge-home>] [--auto-archive]
USAGE
        return 0
        ;;
      *)
        forward+=("$1")
        shift
        ;;
    esac
  done
  (( seen_target )) || true
  [[ -d "$target" ]] || bridge_die "agb upgrade conflicts: 대상 디렉터리를 찾을 수 없습니다: $target"
  bridge_require_python
  case "$sub" in
    list|diff|adopt|discard|archive|reconcile)
      python3 "$SOURCE_ROOT/bridge-upgrade.py" "conflicts-$sub" --target-root "$target" "${forward[@]}"
      ;;
    *)
      bridge_die "agb upgrade conflicts: 지원하지 않는 하위 명령입니다: $sub (list|diff|adopt|discard|archive|reconcile)"
      ;;
  esac
}

if [[ $# -gt 0 ]]; then
  case "$1" in
    conflicts)
      shift
      bridge_upgrade_conflicts_dispatch "$@"
      exit $?
      ;;
    analyze|rollback)
      SUBCOMMAND="$1"
      shift
      ;;
  esac
fi

while [[ $# -gt 0 ]]; do
  case "$1" in
    --source)
      [[ $# -lt 2 ]] && bridge_die "--source 뒤에 값을 지정하세요."
      SOURCE_ROOT="$2"
      SOURCE_EXPLICIT=1
      shift 2
      ;;
    --target)
      [[ $# -lt 2 ]] && bridge_die "--target 뒤에 값을 지정하세요."
      TARGET_ROOT="$2"
      shift 2
      ;;
    --backup-root)
      [[ $# -lt 2 ]] && bridge_die "--backup-root 뒤에 값을 지정하세요."
      BACKUP_ROOT="$2"
      shift 2
      ;;
    --pull)
      PULL=1
      PULL_EXPLICIT=1
      shift
      ;;
    --no-pull)
      PULL=0
      PULL_EXPLICIT=1
      shift
      ;;
    --check)
      CHECK_ONLY=1
      DRY_RUN=1
      RESTART_DAEMON=0
      shift
      ;;
    --channel)
      [[ $# -lt 2 ]] && bridge_die "--channel 뒤에 stable|dev|current 중 하나를 지정하세요."
      CHANNEL="$2"
      CHANNEL_EXPLICIT=1
      shift 2
      ;;
    --version)
      [[ $# -lt 2 ]] && bridge_die "--version 뒤에 버전을 지정하세요."
      REQUESTED_VERSION="$2"
      CHANNEL="stable"
      CHANNEL_EXPLICIT=1
      shift 2
      ;;
    --ref)
      [[ $# -lt 2 ]] && bridge_die "--ref 뒤에 git ref를 지정하세요."
      REQUESTED_REF="$2"
      CHANNEL="ref"
      CHANNEL_EXPLICIT=1
      shift 2
      ;;
    --restart-daemon)
      RESTART_DAEMON=1
      shift
      ;;
    --no-restart-daemon)
      RESTART_DAEMON=0
      shift
      ;;
    --restart-agents)
      RESTART_AGENTS=1
      RESTART_AGENTS_EXPLICIT=1
      shift
      ;;
    --no-restart-agents)
      RESTART_AGENTS=0
      RESTART_AGENTS_EXPLICIT=1
      shift
      ;;
    --apply)
      [[ "$SUBCOMMAND" == "apply" ]] || bridge_die "--apply는 기본 upgrade 적용 경로에서만 사용할 수 있습니다."
      shift
      ;;
    --dry-run)
      DRY_RUN=1
      shift
      ;;
    --json)
      JSON=1
      shift
      ;;
    --allow-dirty)
      ALLOW_DIRTY=1
      shift
      ;;
    --allow-dirty-source)
      ALLOW_DIRTY_SOURCE=1
      shift
      ;;
    --strict-merge)
      STRICT_MERGE=1
      shift
      ;;
    --no-backup)
      BACKUP=0
      shift
      ;;
    --backup)
      BACKUP=1
      shift
      ;;
    --no-migrate-agents)
      MIGRATE_AGENTS=0
      shift
      ;;
    --migrate-agents)
      MIGRATE_AGENTS=1
      shift
      ;;
    -h|--help|help)
      usage
      exit 0
      ;;
    *)
      bridge_die "지원하지 않는 upgrade 옵션입니다: $1"
      ;;
  esac
done

TARGET_ROOT="$(cd -P "$(dirname "$TARGET_ROOT")" && pwd -P)/$(basename "$TARGET_ROOT")"
SOURCE_ROOT="$(cd -P "$SOURCE_ROOT" && pwd -P)"

if [[ $SOURCE_EXPLICIT -eq 0 && "$SOURCE_ROOT" == "$TARGET_ROOT" ]]; then
  RECORDED_SOURCE_ROOT="$(
    python3 - "$TARGET_ROOT/state/upgrade/last-upgrade.json" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except (FileNotFoundError, json.JSONDecodeError):
    print("")
    raise SystemExit(0)

source = str(payload.get("source_root") or "").strip()
print(source)
PY
  )"
  if [[ -n "$RECORDED_SOURCE_ROOT" && -d "$RECORDED_SOURCE_ROOT/.git" ]]; then
    SOURCE_ROOT="$(cd -P "$RECORDED_SOURCE_ROOT" && pwd -P)"
    if [[ "$SUBCOMMAND" == "apply" && $PULL_EXPLICIT -eq 0 ]]; then
      PULL=1
    fi
  else
    for CANDIDATE_SOURCE_ROOT in \
      "${AGENT_BRIDGE_SOURCE_DIR:-}" \
      "$HOME/.agent-bridge-source" \
      "$HOME/Projects/agent-bridge-public" \
      "$HOME/agent-bridge-public" \
      "$HOME/agent-bridge"
    do
      [[ -n "$CANDIDATE_SOURCE_ROOT" ]] || continue
      if [[ -d "$CANDIDATE_SOURCE_ROOT/.git" ]]; then
        SOURCE_ROOT="$(cd -P "$CANDIDATE_SOURCE_ROOT" && pwd -P)"
        if [[ "$SUBCOMMAND" == "apply" && $PULL_EXPLICIT -eq 0 ]]; then
          PULL=1
        fi
        break
      fi
    done
  fi
fi

if [[ "${BRIDGE_UPGRADE_SOURCE_REEXEC:-0}" != "1" \
  && "$SCRIPT_DIR" == "$TARGET_ROOT" \
  && "$SOURCE_ROOT" != "$SCRIPT_DIR" \
  && -f "$SOURCE_ROOT/bridge-upgrade.sh" ]]; then
  export BRIDGE_UPGRADE_SOURCE_REEXEC=1
  exec "$BRIDGE_BASH_BIN" "$SOURCE_ROOT/bridge-upgrade.sh" "${ORIGINAL_ARGS[@]}" --target "$TARGET_ROOT"
fi

TIMESTAMP="$(date '+%Y%m%d-%H%M%S')"
if [[ -z "$BACKUP_ROOT" && "$SUBCOMMAND" != "rollback" ]]; then
  BACKUP_ROOT="$TARGET_ROOT/backups/upgrade-$TIMESTAMP"
fi
ADMIN_AGENT_ID=""
BACKUP_JSON='{}'
MIGRATION_JSON='{}'
MIGRATION_PREVIEW_JSON='{}'
APPLY_JSON='{}'

if ! git -C "$SOURCE_ROOT" rev-parse --show-toplevel >/dev/null 2>&1; then
  if [[ $SOURCE_EXPLICIT -eq 0 && "$SOURCE_ROOT" == "$TARGET_ROOT" ]]; then
    bridge_die "live install은 git repo가 아니고 source checkout 기록도 없습니다: $TARGET_ROOT
복구: git clone https://github.com/SYRS-AI/agent-bridge-public \"\$HOME/.agent-bridge-source\" 후 다시 실행하거나,
AGENT_BRIDGE_SOURCE_DIR를 설정하거나,
명시적으로 실행하세요: $TARGET_ROOT/agent-bridge upgrade --source /path/to/agent-bridge-public"
  fi
  bridge_die "git repo가 아닙니다: $SOURCE_ROOT"
fi

if [[ $SOURCE_EXPLICIT -eq 1 && $CHANNEL_EXPLICIT -eq 0 ]]; then
  CHANNEL="current"
fi
if [[ "$SUBCOMMAND" != "apply" && $CHANNEL_EXPLICIT -eq 0 ]]; then
  CHANNEL="current"
fi

case "$CHANNEL" in
  stable|dev|current|ref)
    ;;
  *)
    bridge_die "--channel 값은 stable|dev|current 중 하나여야 합니다: $CHANNEL"
    ;;
esac

if [[ "$SUBCOMMAND" == "apply" ]]; then
  if [[ $PULL -eq 1 || $CHECK_ONLY -eq 1 || "$CHANNEL" != "current" ]]; then
    if git -C "$SOURCE_ROOT" remote get-url origin >/dev/null 2>&1; then
      git -C "$SOURCE_ROOT" fetch --tags --prune origin >/dev/null
      if [[ "$CHANNEL" == "dev" ]]; then
        git -C "$SOURCE_ROOT" fetch origin main >/dev/null 2>&1 || true
      fi
    fi
  fi

  case "$CHANNEL" in
    current)
      TARGET_REF=""
      ;;
    stable)
      if [[ -n "$REQUESTED_VERSION" ]]; then
        TARGET_REF="$(bridge_upgrade_normalize_version_tag "$REQUESTED_VERSION")"
      else
        TARGET_REF="$(bridge_upgrade_latest_stable_tag "$SOURCE_ROOT")"
      fi
      if [[ -n "$TARGET_REF" ]] && ! git -C "$SOURCE_ROOT" rev-parse --verify "${TARGET_REF}^{commit}" >/dev/null 2>&1; then
        bridge_die "요청한 stable 릴리즈 태그를 찾을 수 없습니다: $TARGET_REF"
      fi
      ;;
    dev)
      if git -C "$SOURCE_ROOT" rev-parse --verify main >/dev/null 2>&1; then
        TARGET_REF="main"
      elif git -C "$SOURCE_ROOT" rev-parse --verify origin/main >/dev/null 2>&1; then
        TARGET_REF="origin/main"
      else
        TARGET_REF=""
      fi
      ;;
    ref)
      TARGET_REF="$REQUESTED_REF"
      if ! git -C "$SOURCE_ROOT" rev-parse --verify "${TARGET_REF}^{commit}" >/dev/null 2>&1; then
        bridge_die "git ref를 찾을 수 없습니다: $TARGET_REF"
      fi
      ;;
  esac

  if [[ -n "$TARGET_REF" ]]; then
    TARGET_VERSION="$(bridge_upgrade_version_at_ref "$SOURCE_ROOT" "$TARGET_REF")"
    TARGET_HEAD="$(bridge_upgrade_head_for_ref "$SOURCE_ROOT" "$TARGET_REF")"
  else
    TARGET_VERSION="$(bridge_upgrade_version_from_file "$SOURCE_ROOT")"
    TARGET_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
  fi

  if [[ $CHECK_ONLY -eq 1 ]]; then
    INSTALLED_VERSION="$(bridge_upgrade_installed_field "$TARGET_ROOT" version)"
    INSTALLED_HEAD="$(bridge_upgrade_installed_field "$TARGET_ROOT" source_head)"
    UPDATE_AVAILABLE=0
    if [[ -z "$INSTALLED_VERSION" || "$INSTALLED_VERSION" != "$TARGET_VERSION" || -z "$INSTALLED_HEAD" || "$INSTALLED_HEAD" != "$TARGET_HEAD" ]]; then
      UPDATE_AVAILABLE=1
    fi

    if [[ $JSON -eq 1 ]]; then
      python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$CHANNEL" "$TARGET_REF" "$TARGET_VERSION" "$TARGET_HEAD" "$INSTALLED_VERSION" "$INSTALLED_HEAD" "$UPDATE_AVAILABLE" <<'PY'
import json
import sys

source_root, target_root, channel, target_ref, target_version, target_head, installed_version, installed_head, update_available = sys.argv[1:]
payload = {
    "mode": "upgrade-check",
    "source_root": source_root,
    "target_root": target_root,
    "channel": channel,
    "target_ref": target_ref,
    "target_version": target_version,
    "target_head": target_head,
    "installed_version": installed_version,
    "installed_head": installed_head,
    "update_available": update_available == "1",
}
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
    else
      echo "== Agent Bridge upgrade check =="
      echo "channel: $CHANNEL"
      echo "target_ref: ${TARGET_REF:-current}"
      echo "target_version: $TARGET_VERSION"
      echo "installed_version: ${INSTALLED_VERSION:-unknown}"
      echo "update_available: $([[ $UPDATE_AVAILABLE -eq 1 ]] && printf yes || printf no)"
    fi
    exit 0
  fi

  # Pre-flight: when the target ref is a tag (v*) or a release/* branch, the
  # operator's expectation (per --check / --dry-run output `target_ref: vX.Y.Z`)
  # is that the tag's content drives the merge. The merge resolution actually
  # uses the source checkout's working tree, so any uncommitted edits or a
  # non-release feature branch get silently folded in. Refuse to proceed for
  # release-style targets when the source is dirty so dry-run/apply produce
  # the same surprise-free abort. Fires for both dry-run and apply (issue #380).
  if [[ -n "$TARGET_REF" ]] \
    && [[ "$TARGET_REF" =~ ^v[0-9] || "$TARGET_REF" == release/* ]] \
    && [[ $ALLOW_DIRTY_SOURCE -eq 0 && $ALLOW_DIRTY -eq 0 ]]; then
    if [[ -n "$(git -C "$SOURCE_ROOT" status --porcelain)" ]]; then
      cat >&2 <<EOF
error: source checkout at $SOURCE_ROOT has uncommitted changes (or is on a non-release branch).
The current behavior would fold those changes into the merge source, producing
surprise conflicts on core files even though the $TARGET_REF release ref is clean.

Resolve one of:
  1. Commit or stash your changes:
       (cd $SOURCE_ROOT && git stash push -u)
     ... then re-run \`agent-bridge upgrade --apply\`. After the upgrade:
       (cd $SOURCE_ROOT && git stash pop)
  2. Point AGENT_BRIDGE_SOURCE_DIR at a clean checkout:
       AGENT_BRIDGE_SOURCE_DIR=/path/to/clean/checkout agent-bridge upgrade --apply
  3. If you genuinely want to fold the working-tree changes in (uncommon —
     usually only maintainers testing a release candidate locally):
       agent-bridge upgrade --apply --allow-dirty-source
EOF
      exit 64
    fi
  fi

  if [[ $ALLOW_DIRTY -eq 0 && $DRY_RUN -eq 0 ]]; then
    if [[ -n "$(git -C "$SOURCE_ROOT" status --short)" ]]; then
      bridge_die "working tree가 dirty 합니다. 먼저 커밋/정리하거나 --allow-dirty 를 사용하세요."
    fi
  fi

  if [[ -n "$TARGET_REF" && $DRY_RUN -eq 0 ]]; then
    git -C "$SOURCE_ROOT" checkout -q "$TARGET_REF"
  fi

  if [[ $PULL -eq 1 && $DRY_RUN -eq 0 ]]; then
    if [[ "$CHANNEL" == "dev" ]]; then
      if git -C "$SOURCE_ROOT" rev-parse --verify main >/dev/null 2>&1; then
        git -C "$SOURCE_ROOT" checkout -q main
      else
        git -C "$SOURCE_ROOT" checkout -q -B main origin/main
      fi
      git -C "$SOURCE_ROOT" pull --ff-only origin main
    elif [[ "$CHANNEL" == "current" ]]; then
      git -C "$SOURCE_ROOT" pull --ff-only
    fi
  fi
fi

SOURCE_VERSION="$(bridge_upgrade_version_from_file "$SOURCE_ROOT")"
SOURCE_REF="$(bridge_upgrade_current_ref "$SOURCE_ROOT")"
SOURCE_HEAD="$(git -C "$SOURCE_ROOT" rev-parse HEAD 2>/dev/null || true)"
if [[ $DRY_RUN -eq 0 || -z "$TARGET_VERSION" ]]; then
  TARGET_VERSION="$SOURCE_VERSION"
  TARGET_HEAD="$SOURCE_HEAD"
fi

if [[ $RESTART_DAEMON -eq 0 && $RESTART_AGENTS_EXPLICIT -eq 0 ]]; then
  RESTART_AGENTS=0
fi
if [[ $CHECK_ONLY -eq 1 ]]; then
  RESTART_AGENTS=0
fi

ANALYSIS_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" analyze-live --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT")"
CHANNEL_GUARD_REPORT="$(bridge_upgrade_channel_guard_report "$SOURCE_ROOT" "$TARGET_ROOT")"
CHANNEL_GUARD_JSON="$(bridge_upgrade_channel_guard_json "$CHANNEL_GUARD_REPORT")"

if [[ "$SUBCOMMAND" == "analyze" ]]; then
  if [[ $JSON -eq 1 ]]; then
    python3 - "$ANALYSIS_JSON" "$CHANNEL_GUARD_JSON" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["channel_guard"] = json.loads(sys.argv[2])
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print("== Agent Bridge upgrade analyze ==")
print(f"source_root: {payload.get('source_root')}")
print(f"target_root: {payload.get('target_root')}")
print(f"base_ref: {payload.get('base_ref') or '-'}")
for key in ("missing_live", "upstream_only", "live_only", "merge_required", "unknown_base_live_diff"):
    print(f"{key}: {counts.get(key, 0)}")
PY
    bridge_upgrade_print_channel_guard_summary "$CHANNEL_GUARD_JSON"
  fi
  exit 0
fi

if [[ "$SUBCOMMAND" == "rollback" ]]; then
  ROLLBACK_AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "" 0 "$DRY_RUN")"
  rollback_args=(rollback-live --target-root "$TARGET_ROOT")
  if [[ -n "$BACKUP_ROOT" ]]; then
    rollback_args+=(--backup-root "$BACKUP_ROOT")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    rollback_args+=(--dry-run)
  fi
  ROLLBACK_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${rollback_args[@]}")"
  if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
    # --force: the upgrader is the sanctioned daemon stop+restart path
    # (issue #314 Layer 3 / #315 Track 3). Bypass the active-agent guard.
    bash "$TARGET_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || true
    bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
  fi
  if [[ $RESTART_AGENTS -eq 1 ]]; then
    ROLLBACK_AGENT_RESTART_REPORT="$(bridge_upgrade_collect_agent_restart_report "$TARGET_ROOT" "$DRY_RUN")"
    # Issue 4 (v0.11.0): reconcile failed rows against the daemon's
    # subsequent launch cycle so the rollback summary does not over-
    # report failures the daemon already absorbed. No-op when dry-run
    # or when no `failed` rows are present.
    ROLLBACK_AGENT_RESTART_REPORT="$(bridge_upgrade_reconcile_agent_restart_recovery "$TARGET_ROOT" "$ROLLBACK_AGENT_RESTART_REPORT" "$DRY_RUN")"
    ROLLBACK_AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "$ROLLBACK_AGENT_RESTART_REPORT" 1 "$DRY_RUN")"
  fi
  if [[ $JSON -eq 1 ]]; then
    python3 - "$ROLLBACK_JSON" "$ROLLBACK_AGENT_RESTART_JSON" "$RESTART_DAEMON" "$RESTART_AGENTS" <<'PY'
import json
import sys

payload = json.loads(sys.argv[1])
payload["restart_daemon"] = sys.argv[3] == "1"
payload["restart_agents"] = sys.argv[4] == "1"
payload["agent_restart"] = json.loads(sys.argv[2])
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    python3 - "$ROLLBACK_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print("== Agent Bridge rollback ==")
print(f"target_root: {payload.get('target_root')}")
print(f"backup_root: {payload.get('backup_root')}")
print(f"restored: {'yes' if payload.get('restored') else 'no'}")
print(f"removed_entries: {payload.get('removed_entries', 0)}")
PY
    bridge_upgrade_print_agent_restart_summary "$ROLLBACK_AGENT_RESTART_JSON"
  fi
  exit 0
fi

if [[ -f "$TARGET_ROOT/agent-roster.local.sh" ]]; then
  if ADMIN_AGENT_ID="$(bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    source "$1/bridge-lib.sh"
    bridge_load_roster
    printf "%s" "${BRIDGE_ADMIN_AGENT_ID:-}"
  ' -- "$SOURCE_ROOT" 2>/dev/null)"; then
    :
  else
    ADMIN_AGENT_ID=""
  fi
fi

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  MIGRATION_PREVIEW_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID" --dry-run)"
fi

if [[ $BACKUP -eq 1 ]]; then
  backup_args=(backup-live --target-root "$TARGET_ROOT" --backup-root "$BACKUP_ROOT" --source-root "$SOURCE_ROOT")
  _backup_payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-backup-json.XXXXXX")"
  if [[ "$ANALYSIS_JSON" != "{}" ]]; then
    printf '%s' "$ANALYSIS_JSON" >"$_backup_payload_dir/analysis.json"
    backup_args+=(--analysis-json-file "$_backup_payload_dir/analysis.json")
  fi
  if [[ "$MIGRATION_PREVIEW_JSON" != "{}" ]]; then
    printf '%s' "$MIGRATION_PREVIEW_JSON" >"$_backup_payload_dir/migration.json"
    backup_args+=(--migration-json-file "$_backup_payload_dir/migration.json")
  fi
  if [[ $DRY_RUN -eq 1 ]]; then
    backup_args+=(--dry-run)
  fi
  BACKUP_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${backup_args[@]}")"
  rm -rf "$_backup_payload_dir"
fi

reclassify_args=(reclassify --json)
if [[ $DRY_RUN -eq 0 ]]; then
  reclassify_args+=(--apply)
fi
SOURCE_RECLASSIFY_JSON="$(bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" "$SOURCE_ROOT/bridge-agent.sh" "${reclassify_args[@]}")"

BASE_REF="$(printf '%s' "$ANALYSIS_JSON" | python3 -c '
import json
import sys
payload = json.load(sys.stdin)
print(payload.get("base_ref", ""))
')"

# Issue #394: stamp this upgrade run with a deterministic id and run a
# pre-apply reconcile pass that auto-archives any prior `.upgrade-conflict`
# whose live target hash hasn't changed since the conflict was written.
# Skipped on dry-run (would print the report but not mutate). The
# reconcile call is best-effort: if `state/upgrade-conflicts/` is empty
# or unreadable we still continue with apply.
UPGRADE_RUN_ID="$(date -u '+%Y%m%dT%H%M%SZ')-$$"
RECONCILE_JSON='{"mode":"upgrade-conflicts-reconcile","skipped":true,"archived_count":0}'
if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  RECONCILE_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" conflicts-reconcile \
    --target-root "$TARGET_ROOT" --auto-archive 2>/dev/null)"
  _reconcile_rc=$?
  set -e
  if [[ $_reconcile_rc -ne 0 ]]; then
    RECONCILE_JSON='{"mode":"upgrade-conflicts-reconcile","error":"reconcile failed","archived_count":0}'
  fi
fi

# v0.8.0 T3 — isolation-v2 migration. Runs between reconcile and apply-live
# so any markerless v0.7.x install is migrated forward as part of the
# standard upgrade path. Skipped on dry-run; idempotent (skipped when
# the v2 marker is already present + valid). Failure aborts the upgrade
# before apply-live touches the install — the `no_v080_code_installed=yes`
# remediation hint tells the operator they can safely retry.
ISOLATION_V2_MIGRATION_JSON='{"mode":"isolation-v2-migrate","skipped":true,"reason":"dry-run"}'
if [[ $DRY_RUN -eq 0 ]]; then
  # Run the migration in a child shell whose env is scoped to TARGET_ROOT
  # via bridge_upgrade_with_target_env. This guarantees BRIDGE_HOME,
  # BRIDGE_STATE_DIR, BRIDGE_AGENT_HOME_ROOT, and the marker dir all
  # resolve to the install we are upgrading — even if this upgrader was
  # invoked from a different live install (per-controller workstations,
  # multi-install operator boxes). bridge_upgrade_with_target_env
  # forwards BRIDGE_LAYOUT_RESOLVER_BYPASS{,_OWNER_PID} explicitly so
  # the resolver inside the child still validates the handshake — the
  # process-tree walk traverses env → bash → upgrade.sh and matches.
  set +e
  ISOLATION_V2_MIGRATION_JSON="$(
    bridge_upgrade_with_target_env "$TARGET_ROOT" \
      "$BRIDGE_BASH_BIN" -s -- "$SOURCE_ROOT" "$TARGET_ROOT" <<'EOF'
set -euo pipefail
source_root="$1"
target_root="$2"
# shellcheck source=/dev/null
source "$source_root/bridge-lib.sh"
bridge_load_roster
# shellcheck source=lib/bridge-isolation-v2-migrate.sh
source "$source_root/lib/bridge-isolation-v2-migrate.sh"
bridge_isolation_v2_migrate_apply_for_upgrade --target-root "$target_root" --json
EOF
  )"
  _migrate_rc=$?
  set -e
  if [[ $_migrate_rc -ne 0 ]]; then
    # Issue #682: populate structured failure fields so the EXIT trap's
    # --json emit carries actionable detail (apply-live did NOT run at
    # this point; live VERSION + installed_version both still match the
    # pre-upgrade state).
    _BRIDGE_UPGRADE_DIE_REASON="isolation-v2 migration failed (rc=${_migrate_rc})"
    _BRIDGE_UPGRADE_DIE_DETAIL="${ISOLATION_V2_MIGRATION_JSON}"
    _BRIDGE_UPGRADE_DIE_REMEDIATION="see ${TARGET_ROOT}/state/migration/isolation-v2/last-error.json; apply-live did NOT run, safe to retry after fix"
    bridge_die "isolation-v2 migration failed during upgrade
  rc=${_migrate_rc}
  detail: ${ISOLATION_V2_MIGRATION_JSON}
  remediation: see ${TARGET_ROOT}/state/migration/isolation-v2/last-error.json
  no_v080_code_installed=yes  (apply-live did NOT run; safe to retry after fix)"
  fi
  # Surface the macOS supplemental-group cache caveat to the operator.
  # The migration JSON carries `migration_requires_relogin` regardless of
  # success — we only print on success because failure already aborts.
  _relogin_required="$(printf '%s' "$ISOLATION_V2_MIGRATION_JSON" | python3 -c '
import json, sys
try:
  data = json.loads(sys.stdin.read().splitlines()[-1])
  print("yes" if data.get("migration_requires_relogin") else "no")
except Exception:
  print("no")
' 2>/dev/null || printf 'no')"
  if [[ "$_relogin_required" == "yes" ]]; then
    bridge_warn "isolation-v2 migration: macOS supplemental group cache requires re-login. Log out + back in for ab-agent-* group membership to take effect for already-running shells."
  fi
  # Migration succeeded — the v2 marker is now on disk. Drop the resolver
  # bypass so any subprocesses spawned by the rest of the upgrade flow
  # (apply-live, daemon restart, agent restart) take the normal `marker`
  # source path. Leaving the bypass set would re-enter the deferred
  # state and BRIDGE_LAYOUT would stay empty, which downstream v2
  # helpers treat as legacy.
  unset BRIDGE_LAYOUT_RESOLVER_BYPASS BRIDGE_LAYOUT_RESOLVER_BYPASS_OWNER_PID
fi

apply_args=(apply-live --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --run-id "$UPGRADE_RUN_ID")
if [[ -n "$BASE_REF" ]]; then
  apply_args+=(--base-ref "$BASE_REF")
fi
if [[ $DRY_RUN -eq 1 ]]; then
  apply_args+=(--dry-run)
fi
if [[ $STRICT_MERGE -eq 1 ]]; then
  apply_args+=(--strict-merge)
fi
APPLY_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" "${apply_args[@]}")"

# Issue #682 Finding 2: advance the `installed_version` / `installed_ref`
# / `installed_head` metadata atomically with the live VERSION write.
# apply-live above writes the live VERSION file (plus every other tracked
# release file) by treating it as a normal text merge target; subsequent
# steps (shared-settings rerender, migrate-agents, daemon restart) can
# fail under `set -e` after VERSION has already advanced. write-state
# previously sat at the very end of the apply path, which produced the
# observed "live VERSION=0.8.4 + installed_version=0.7.7" mismatch when a
# downstream helper exited non-zero. Running it here pins the invariant:
# if the live VERSION file moved, last-upgrade.json moved with it. The
# call is itself a single small JSON write (state/upgrade/last-upgrade.json)
# and is safe to re-run — re-invoking the upgrader idempotently re-writes
# the same payload.
if [[ $DRY_RUN -eq 0 ]]; then
  _write_state_payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-state-json.XXXXXX")"
  printf '%s' "$ANALYSIS_JSON" >"$_write_state_payload_dir/analysis.json"
  python3 "$SOURCE_ROOT/bridge-upgrade.py" write-state \
    --source-root "$SOURCE_ROOT" \
    --target-root "$TARGET_ROOT" \
    --backup-root "$BACKUP_ROOT" \
    --analysis-json-file "$_write_state_payload_dir/analysis.json" \
    --version "$SOURCE_VERSION" \
    --source-ref "$SOURCE_REF" \
    --channel "$CHANNEL" >/dev/null
  rm -rf "$_write_state_payload_dir"
fi

AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "" 0 "$DRY_RUN")"

if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  SHARED_SETTINGS_RERENDER_JSON="$(bridge_upgrade_propagate_claude_shared_settings "$TARGET_ROOT")"
  _shared_settings_rerender_rc=$?
  set -e
  if [[ $_shared_settings_rerender_rc -ne 0 ]]; then
    echo "[bridge-upgrade] WARN: shared Claude settings rerender reported failures" >&2
    _upgrade_partial_failures+=("shared_rerender")
  fi
  if ! python3 - "$SHARED_SETTINGS_RERENDER_JSON" <<'PY'
import json
import sys
# Issue #731: empty/non-JSON payload happens when an isolated agent's
# canonical_dir lookup fails (controller can't traverse mode-2750 workdir)
# and the rerender helper hands back nothing for that agent. Treat it as
# a non-fatal skip with a named diagnostic instead of dumping a raw
# JSONDecodeError traceback into the upgrade log.
raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw:
    print("[bridge-upgrade] WARN: shared-settings rerender returned empty payload (likely isolated agent canonical_dir failure — see #731)", file=sys.stderr)
    sys.exit(0)
try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"[bridge-upgrade] WARN: shared-settings rerender returned non-JSON payload: {exc}", file=sys.stderr)
    print(f"[bridge-upgrade] payload preview: {raw[:200]!r}", file=sys.stderr)
    sys.exit(0)
raise SystemExit(0 if int(payload.get("failed_count") or 0) == 0 else 1)
PY
  then
    echo "[bridge-upgrade] WARN: shared Claude settings rerender verification failed for one or more agents" >&2
    _upgrade_partial_failures+=("shared_rerender")
  fi
fi

# v0.7.0 → v0.7.1 transition cleanup. Idempotent best-effort removal of
# residual telegram-relay state (env vars, channel entries, state files,
# per-agent relay-token files). Was the manual job described by
# docs/proposals/v0.7.0-install-cleanup-verification-prompt.md and
# docs/proposals/jjujju-migration-prompt.md before v0.7.1.
#
# Two-phase to satisfy the rollback contract: dry-run first to learn
# which paths the helper would touch, extend the upgrade backup
# manifest with those paths via `backup-extend-live` (mirrors the
# bridge-docs apply step a few sections below), then apply. Without
# the manifest extension a subsequent `upgrade rollback` would not
# restore the pre-cleanup roster line / state file content because the
# primary backup is built only from the tracked-file analysis.
RELAY_CLEANUP_JSON=""
if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  RELAY_CLEANUP_PREVIEW_JSON="$(python3 "$SOURCE_ROOT/bridge-relay-cleanup.py" \
    --target-root "$TARGET_ROOT" --dry-run --json 2>/dev/null)"
  _relay_cleanup_preview_rc=$?
  set -e
  if [[ $_relay_cleanup_preview_rc -eq 0 && -n "$RELAY_CLEANUP_PREVIEW_JSON" ]]; then
    if python3 - "$RELAY_CLEANUP_PREVIEW_JSON" <<'PY' >/dev/null 2>&1
import json, sys
raise SystemExit(0 if json.loads(sys.argv[1]).get("any_changes") else 1)
PY
    then
      if [[ -n "$BACKUP_ROOT" ]]; then
        python3 "$SOURCE_ROOT/bridge-upgrade.py" backup-extend-live \
          --target-root "$TARGET_ROOT" \
          --backup-root "$BACKUP_ROOT" \
          --paths-json "$RELAY_CLEANUP_PREVIEW_JSON" >/dev/null 2>&1 || true
      fi
      set +e
      # `--no-backup`: the upgrader already extended the upgrade backup
      # manifest with `changed_paths` from the preview JSON above
      # (including the new `removed:<abs>/lib/telegram-relay.py` etc.
      # entries). A second standalone backup under
      # `<target>/backups/relay-cleanup-*/` would be redundant noise on
      # every upgrade. Standalone (non-upgrade) invocations of
      # `bridge-relay-cleanup.py` still produce their own backup by
      # default; only this in-upgrade caller opts out.
      RELAY_CLEANUP_JSON="$(python3 "$SOURCE_ROOT/bridge-relay-cleanup.py" \
        --target-root "$TARGET_ROOT" --no-backup --json 2>/dev/null)"
      _relay_cleanup_rc=$?
      set -e
      if [[ $_relay_cleanup_rc -ne 0 ]]; then
        echo "[bridge-upgrade] WARN: telegram-relay residue cleanup helper exited non-zero ($_relay_cleanup_rc); manual cleanup may still be required (see docs/proposals/v0.7.0-install-cleanup-verification-prompt.md)" >&2
        RELAY_CLEANUP_JSON=""
      fi
      if [[ -n "$RELAY_CLEANUP_JSON" ]]; then
        bridge_audit_log upgrade telegram_relay_residue_cleanup_applied "$TARGET_VERSION" \
          --detail summary="$RELAY_CLEANUP_JSON" >/dev/null 2>&1 || true
      fi
    fi
  elif [[ $_relay_cleanup_preview_rc -ne 0 ]]; then
    echo "[bridge-upgrade] WARN: telegram-relay residue cleanup preview exited non-zero ($_relay_cleanup_preview_rc); skipping cleanup, manual procedure may be required (see docs/proposals/v0.7.0-install-cleanup-verification-prompt.md)" >&2
  fi
fi

if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  if [[ $DRY_RUN -eq 1 ]]; then
    MIGRATION_JSON="$MIGRATION_PREVIEW_JSON"
  else
    MIGRATION_JSON="$(python3 "$SOURCE_ROOT/bridge-upgrade.py" migrate-agents --source-root "$SOURCE_ROOT" --target-root "$TARGET_ROOT" --admin-agent "$ADMIN_AGENT_ID")"
  fi
  bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" -lc '
    set -euo pipefail
    source "$1/bridge-lib.sh"
    bridge_load_roster
    dry_run="$2"
    for agent in "${BRIDGE_AGENT_IDS[@]}"; do
      [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
      bridge_sync_claude_runtime_skills "$agent" "$(bridge_agent_workdir "$agent")" "$dry_run" >/dev/null 2>&1 || true
      # Issue #544 PR3 — refresh bridge-native skills under each
      # isolated agent HOME on upgrade. No-op for non-isolated agents.
      # Honors --dry-run: only run the live sync when dry_run != 1.
      if [[ "$dry_run" != "1" ]] \
          && command -v bridge_sync_isolated_home_claude_skills >/dev/null 2>&1; then
        bridge_sync_isolated_home_claude_skills "$agent" >/dev/null 2>&1 || true
      fi
    done
  ' -- "$SOURCE_ROOT" "$DRY_RUN"

  # Issue #517: backfill the admin's sibling codex dev pair (`<admin>-dev`).
  # Idempotent — skipped when the pair already exists. The admin CLAUDE.md
  # managed pair-programming block is refreshed by `migrate-agents` above
  # (admin session_type branch in migrate_agent_home), so this step only
  # owns the agent registration. Tolerant on failure: warn and continue.
  if [[ -n "$ADMIN_AGENT_ID" ]]; then
    if [[ $DRY_RUN -eq 1 ]]; then
      echo "[bridge-upgrade] plan: ensure admin codex pair ${ADMIN_AGENT_ID}-dev (idempotent)" >&2
    else
      _admin_pair_output=""
      if ! _admin_pair_output="$(
        bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" -lc '
          set -euo pipefail
          # bridge-admin-pair.sh:bridge_ensure_admin_codex_pair invokes
          # "$BRIDGE_BASH_BIN" "$SCRIPT_DIR/agent-bridge" agent create ...,
          # so SCRIPT_DIR must be bound before sourcing the helper. Without
          # this the heredocs subshells set -u aborts as
          # "SCRIPT_DIR: unbound variable" and admin-pair backfill fails on
          # every upgrade. (Issue #517 r1 review finding 1.)
          SCRIPT_DIR="$1"
          source "$SCRIPT_DIR/bridge-lib.sh"
          source "$SCRIPT_DIR/lib/bridge-admin-pair.sh"
          bridge_load_roster
          bridge_ensure_admin_codex_pair "$2"
        ' -- "$SOURCE_ROOT" "$ADMIN_AGENT_ID" 2>&1
      )"; then
        echo "[bridge-upgrade] WARN: admin-pair backfill failed: $_admin_pair_output" >&2
      else
        [[ -n "$_admin_pair_output" ]] && printf '%s\n' "$_admin_pair_output" >&2
      fi
    fi
  fi

  # Issue #833 r2: backfill the picker-sweep cron on every upgrade.
  # bridge-init.sh registers it on fresh install, but existing installs that
  # upgraded into this version (especially host_profile=dev, the v0.11.0
  # prompt-guard workaround path) never get the cron and stay in the
  # original #833 state. bridge_init_register_default_picker_sweep is itself
  # idempotent (skips when the cron entry already exists), so re-running on
  # every upgrade is safe. Tolerant on failure: warn and continue so an
  # unexpected error never blocks the upgrade.
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[bridge-upgrade] plan: backfill picker-sweep cron (idempotent; closes #833 for upgraded installs)" >&2
  elif [[ -z "${ADMIN_AGENT_ID:-}" ]]; then
    # picker-sweep cron requires an admin agent (the helper targets
    # `<admin>-dev` for the codex-pair cron — see
    # bridge_init_register_default_picker_sweep's docstring). If the install
    # has no admin agent, the helper's own no-op skip is correct, but doing
    # it inline avoids invoking a sub-shell that would fail with the missing
    # arg under `set -u`.
    echo "[bridge-upgrade] picker-sweep cron backfill skipped — install has no admin agent" >&2
  else
    _picker_sweep_output=""
    if ! _picker_sweep_output="$(
      bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" -lc '
        set -euo pipefail
        SCRIPT_DIR="$1"
        TARGET_ROOT_INNER="$2"
        ADMIN_AGENT_ID_INNER="$3"
        source "$SCRIPT_DIR/bridge-lib.sh"
        source "$SCRIPT_DIR/lib/bridge-init-default-crons.sh"
        bridge_load_roster
        # bridge_init_register_default_picker_sweep requires
        # ($cli_path, $admin_agent_id) at $1/$2 and runs under set -u, so
        # bare invocation aborts before idempotency can short-circuit.
        # The CLI path is the live target tree (TARGET_ROOT/agent-bridge).
        bridge_init_register_default_picker_sweep \
          "${TARGET_ROOT_INNER}/agent-bridge" \
          "${ADMIN_AGENT_ID_INNER}"
      ' -- "$SOURCE_ROOT" "$TARGET_ROOT" "$ADMIN_AGENT_ID" 2>&1
    )"; then
      echo "[bridge-upgrade] WARN: picker-sweep cron backfill failed: $_picker_sweep_output" >&2
      _upgrade_partial_failures+=("picker_sweep_cron_backfill")
    else
      [[ -n "$_picker_sweep_output" ]] && printf '%s\n' "$_picker_sweep_output" >&2
    fi
  fi

  # Also propagate per-agent doc sync (bridge-docs.py apply) so
  # MEMORY-SCHEMA.md / SKILLS.md / CLAUDE.md managed blocks track the
  # canonical runtime on every upgrade. Before 2026-04-19 this hook was
  # only reachable via bridge_sync_skill_docs which had no upstream
  # caller — agents silently drifted from the template. See
  # bridge-docs.sync_memory_schema_from_template.
  #
  # Before mutating, preview the changes via a dry-run and extend the
  # upgrade backup manifest so `upgrade rollback` can restore each
  # touched file. Without this step MEMORY-SCHEMA.md etc. would be
  # overwritten but NOT captured by bridge-upgrade.py's targeted
  # backup — rollback would leave the v0.4.0 doc payload in place
  # instead of restoring the pre-upgrade content. See codex review
  # of the v0.3.8 -> v0.4.0 diff.
  if [[ $DRY_RUN -eq 0 ]]; then
    DOCS_PREVIEW_JSON="$(bridge_upgrade_with_target_env "$TARGET_ROOT" \
      python3 "$SOURCE_ROOT/bridge-docs.py" apply --all --dry-run --json \
      --bridge-home "$TARGET_ROOT" \
      --target-root "$TARGET_ROOT/agents" 2>/dev/null || printf '{"changed_paths":[]}')"
    python3 "$SOURCE_ROOT/bridge-upgrade.py" backup-extend-live \
      --target-root "$TARGET_ROOT" \
      --backup-root "$BACKUP_ROOT" \
      --paths-json "$DOCS_PREVIEW_JSON" >/dev/null 2>&1 || true
    bridge_upgrade_with_target_env "$TARGET_ROOT" \
      python3 "$SOURCE_ROOT/bridge-docs.py" apply --all \
      --bridge-home "$TARGET_ROOT" \
      --target-root "$TARGET_ROOT/agents" >/dev/null 2>&1 || true
  fi

  # Enforce the singleton channel plugin policy (closes #244). Running this
  # on every upgrade is idempotent — it only writes the overlay when an
  # entry would change. `--quiet` keeps upgrade output terse; failures are
  # tolerated so an unexpected overlay error never blocks the upgrade.
  policy_args=(--quiet)
  if [[ $DRY_RUN -eq 1 ]]; then
    policy_args+=(--dry-run)
  fi
  if ! bridge_upgrade_with_target_env "$TARGET_ROOT" \
      "$BRIDGE_BASH_BIN" "$SOURCE_ROOT/scripts/apply-channel-policy.sh" "${policy_args[@]}" \
      >/dev/null 2>&1; then
    # post-#759 (Wave-2 M5) `apply-channel-policy.sh` exits non-zero on
    # all-fail. Surface the signal so operators see "singleton plugins
    # may be misrouted" instead of the silent `|| true` swallow.
    echo "[bridge-upgrade] WARN: channel-policy refresh failed (apply-channel-policy.sh exited non-zero) — singleton plugins may be misrouted" >&2
    _upgrade_partial_failures+=("channel_policy_refresh")
  fi
fi

# Issue #730 — repair v0.8 layout shared-doc/skill profile symlinks. Pre-v0.8
# installs created links like `agents/<agent>/workdir/COMMON-INSTRUCTIONS.md ->
# ../shared/COMMON-INSTRUCTIONS.md` that resolve to a non-existent path after
# the home/workdir split. `bridge-hooks.py relink-profile-paths` re-resolves
# each known link site to the correct relative target and replaces only the
# broken ones (real files are skipped, no clobber). Runs before daemon
# restart so the next session sees the corrected profile view immediately.
# Skipped on --dry-run; failures are non-fatal (warn only) so an unexpected
# error in the relinker never blocks the upgrade.
RELINK_PROFILE_JSON='{"mode":"skipped","count":0}'
if [[ $DRY_RUN -eq 0 ]]; then
  RELINK_PROFILE_JSON="$(python3 "$TARGET_ROOT/bridge-hooks.py" relink-profile-paths --all-agents --json --bridge-home "$TARGET_ROOT" 2>&1 || true)"
  # Issue #752 W3d M12: capture relink failed_count separately so a
  # non-zero count surfaces as `partial_failures.profile_relink` in the
  # final JSON envelope. The summary heredoc below still runs (with
  # `|| true`) for the operator-facing log line.
  _profile_relink_failed_count="$(printf '%s' "$RELINK_PROFILE_JSON" | python3 -c '
import json, sys
try:
    payload = json.loads(sys.stdin.read())
except (ValueError, TypeError):
    print(0); sys.exit(0)
agents = payload.get("agents", []) or []
print(sum(len(a.get("failed", []) or []) for a in agents))
' 2>/dev/null || printf 0)"
  if [[ "${_profile_relink_failed_count:-0}" != "0" ]]; then
    echo "[bridge-upgrade] WARN: profile relink reported failed_count=${_profile_relink_failed_count} — see embedded JSON for per-agent details" >&2
    _upgrade_partial_failures+=("profile_relink")
  fi
  python3 - "$RELINK_PROFILE_JSON" <<'PY' || true
import json, sys
raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw or not raw.startswith("{"):
    print(
        "[bridge-upgrade] WARN: relink-profile-paths returned non-JSON; "
        f"raw preview: {raw[:200]}",
        file=sys.stderr,
    )
    sys.exit(0)
try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    print(
        f"[bridge-upgrade] WARN: relink-profile-paths JSON decode error: {exc}",
        file=sys.stderr,
    )
    sys.exit(0)
agents = payload.get("agents", []) or []
total_repaired = sum(len(a.get("repaired", []) or []) for a in agents)
total_skipped = sum(len(a.get("skipped", []) or []) for a in agents)
total_failed = sum(len(a.get("failed", []) or []) for a in agents)
print(
    f"[bridge-upgrade] profile symlinks repaired: {total_repaired} "
    f"(skipped={total_skipped}, failed={total_failed}, "
    f"agents={len(agents)})",
    file=sys.stderr,
)
PY
fi

if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
  # --force: the upgrader is the sanctioned daemon stop+restart path
  # (issue #314 Layer 3 / #315 Track 3). Bypass the active-agent guard.
  bash "$TARGET_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || true
  bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
fi


# Bug #507 — auto-cleanup of daily-backup residue on every successful
# `agb upgrade --apply`. Idempotent; reports failures via cleanup_failures
# array. Skipped on dry-runs (no live state to mutate). Always runs before
# the [upgrade-complete] task is filed so the summary can ride along.
CLEANUP_JSON=""
CLEANUP_SUMMARY_MD=""
CLEANUP_FAILURES_COUNT=0
if [[ $DRY_RUN -eq 0 ]]; then
  _cleanup_no_backup_mode=0
  if [[ $BACKUP -eq 0 ]]; then
    _cleanup_no_backup_mode=1
  fi
  if BRIDGE_CLEANUP_TARGET_ROOT="$TARGET_ROOT" \
     BRIDGE_CLEANUP_SOURCE_ROOT="$SOURCE_ROOT" \
     BRIDGE_CLEANUP_CURRENT_BACKUP_ROOT="$BACKUP_ROOT" \
     BRIDGE_CLEANUP_NO_BACKUP_MODE="$_cleanup_no_backup_mode" \
     CLEANUP_JSON="$(bridge_cleanup_daily_backup_residue 2>/dev/null)"; then
    CLEANUP_FAILURES_COUNT="$(printf '%s' "$CLEANUP_JSON" \
      | python3 -c 'import json,sys; d=json.load(sys.stdin); print(len(d.get("cleanup_failures") or []))' 2>/dev/null \
      || printf '0')"
    CLEANUP_SUMMARY_MD="$(printf '%s' "$CLEANUP_JSON" | bridge_cleanup_render_summary 2>/dev/null || true)"
    if [[ "$CLEANUP_FAILURES_COUNT" != "0" ]]; then
      {
        echo "[bridge-upgrade] WARN: backup residue cleanup completed with ${CLEANUP_FAILURES_COUNT} failure(s)."
        echo "[bridge-upgrade] WARN: Inspect the [upgrade-complete] task body or re-run manually:"
        echo "[bridge-upgrade] WARN:   python3 $TARGET_ROOT/bridge-upgrade.py cleanup-residue --target-root $TARGET_ROOT"
      } >&2
    fi
  else
    {
      echo "[bridge-upgrade] WARN: backup residue cleanup helper failed to run."
      echo "[bridge-upgrade] WARN: Manual recovery:"
      echo "[bridge-upgrade] WARN:   python3 $TARGET_ROOT/bridge-upgrade.py cleanup-residue --target-root $TARGET_ROOT"
    } >&2
    CLEANUP_SUMMARY_MD="## Backup residue cleanup

Cleanup helper did not run (helper invocation failed). Run manually:

\`\`\`bash
python3 $TARGET_ROOT/bridge-upgrade.py cleanup-residue --target-root $TARGET_ROOT
\`\`\`"
    CLEANUP_FAILURES_COUNT=1
  fi
fi

# Post-upgrade admin signal: file a [upgrade-complete] task with a
# ready-to-execute checklist. Without this the admin has to know to
# go read docs/agent-runtime/wiki-onboarding.md; the task makes the
# first run self-announcing. Skipped on dry-runs and when no admin
# agent is configured.
if [[ $DRY_RUN -eq 0 ]]; then
  # Resolve admin id: explicit upgrade override → grep the target roster → skip.
  # We grep instead of sourcing because the roster files reference
  # bridge-lib arrays/functions that are not loaded in this scope;
  # `source` would error out and leave _post_admin empty.
  _post_admin="${BRIDGE_ADMIN_AGENT:-}"
  if [[ -z "$_post_admin" ]]; then
    for _roster in "$TARGET_ROOT/agent-roster.local.sh" "$TARGET_ROOT/agent-roster.sh"; do
      if [[ -r "$_roster" ]]; then
        _admin_line="$(grep -E '^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=' "$_roster" 2>/dev/null | head -n 1 | sed -E 's/^[[:space:]]*(export[[:space:]]+)?BRIDGE_ADMIN_AGENT_ID=//; s/^"([^"]*)".*/\1/; s/^'"'"'([^'"'"']*)'"'"'.*/\1/; s/[[:space:]]*#.*$//' || true)"
        if [[ -n "$_admin_line" ]]; then
          _post_admin="$_admin_line"
          break
        fi
      fi
    done
  fi
  if [[ -n "$_post_admin" && -x "$TARGET_ROOT/agent-bridge" ]]; then
    _post_body="$(mktemp -t bridge-upgrade-post.XXXXXX)"
    cat >"$_post_body" <<POST_EOF
# Agent Bridge upgrade completed

- from_version: ${INSTALLED_VERSION:-unknown}
- to_version: $SOURCE_VERSION
- ref: $SOURCE_REF
- channel: $CHANNEL
- upgraded_at: $(date -Iseconds 2>/dev/null || date)

## Immediate action

The v0.4.0 wiki-graph pipeline requires a one-time bootstrap on this
host. The following sequence is idempotent — re-running produces no
drift if the state is already converged.

1. \`$TARGET_ROOT/bootstrap-memory-system.sh --apply\`
   Registers all wiki + librarian crons, provisions the dynamic
   librarian agent, and installs the Phase 1/2 scripts into
   \`$TARGET_ROOT/scripts/\`.

2. \`$TARGET_ROOT/scripts/wiki-mention-scan.py --full-rebuild\`
   Builds the initial L1 observation index
   (\`$TARGET_ROOT/shared/wiki/_index/mentions.db\`) and generates
   today's distribution report.

3. Review the distribution report at
   \`$TARGET_ROOT/shared/wiki/_index/distribution-report-<date>.md\`.
   - §1 cross-agent reach (how entities are connected).
   - §2 L2 hub candidates (the weekly cron resurfaces these as
     \`[wiki-hub-candidates]\` tasks; trigger now with the full
     command below).
   - §3 unresolved wikilinks (stubs to create or link typos to
     fix via \`agb wiki repair-links --apply\`).
   - §4 orphan entity slugs (delete candidates per
     \`wiki-entity-lifecycle.md\` §3.6).

4. Trigger the first L2 sweep manually (cron will run weekly from now on):
   \`\`\`
   $TARGET_ROOT/scripts/wiki-hub-audit.py \\
     --emit-task --admin-agent "$_post_admin" \\
     --bridge-bin "$TARGET_ROOT/agent-bridge" \\
     --out "$TARGET_ROOT/shared/wiki/_audit/hub-candidates-\$(date +%Y-%m-%d).md"
   \`\`\`

## Upstream issue triage

After bootstrap completes, skim the upgrade log and the most recent
bootstrap report for anomalies. Any failed step, unexpected warning,
\`set -e\` abort, or missing artifact should become an upstream issue
rather than a silent local workaround.

- Read the latest report:
  \`ls -t $TARGET_ROOT/state/bootstrap-memory/report-*.json | head -n 1\`
- If the upgrade console output contained warnings or the report shows
  failed steps, draft an issue and ask the user before filing:
  \`\`\`
  $TARGET_ROOT/agent-bridge upstream draft \\
    --title "<one-line symptom>" \\
    --symptom "<what the user sees>" \\
    --why "<why this looks like an upstream bug, not local config>" \\
    --reproduction-file <log-or-report-path> \\
    --output /tmp/upgrade-issue.md
  \`\`\`
- On user approval, file it:
  \`$TARGET_ROOT/agent-bridge upstream propose --title "<title>" --body-file /tmp/upgrade-issue.md --yes\`
- If a local workaround was applied to get the upgrade through,
  record the workaround in the issue body so a future regression test
  can cover it.

Reference: \`docs/agent-runtime/admin-protocol.md\` — "Post-Upgrade
Issue Triage" section, and \`docs/agent-runtime/common-instructions.md\`
— "Upstream Issue Policy" for the approval flow.

## Workaround reconciliation

Inspect known local-workaround surfaces and, for any workaround that
was in place purely to avoid a now-CLOSED upstream issue, revert it so
this host follows upstream again. Leave intentional local policy
alone.

Surfaces to check:

- \`~/.tmux.conf\` — bridge-related overrides.
- Shell rc (\`~/.zshrc\`, \`~/.bashrc\`, etc.) — bridge-related
  \`export\` lines added to paper over a past bug.
- \`~/.claude/settings.json\` — local overrides of Claude Code
  settings that the upgrade may now ship correctly.
- \`$TARGET_ROOT/agent-roster.local.sh\` — temporary env entries
  added as a workaround (intentional local roster policy stays).

Decision rule for each item:

1. Identify the upstream issue the workaround was avoiding (check the
   workaround's inline comment or the PR/issue it referenced).
2. If that upstream issue is now CLOSED and shipped in this upgrade,
   remove the workaround and record the reason in a note or commit
   message (\`"upstream fix in v$SOURCE_VERSION, issue #NNN"\`).
3. If the upstream issue is still open, or the surface reflects
   intentional local policy (custom keybindings, private team
   settings, etc.), leave it in place.

Do not touch a workaround when the reason for it is unclear — open an
issue asking about it instead of deleting behavior the user depends
on.

## Full onboarding

- \`docs/agent-runtime/wiki-onboarding.md\` — complete v0.4.0 admin walkthrough
- \`docs/agent-runtime/admin-protocol.md\` — Wiki Canonical Hub Curation section (weekly ritual)
- \`docs/agent-runtime/wiki-mention-index.md\` — L1 observation layer spec
- \`docs/agent-runtime/wiki-entity-lifecycle.md\` — entity schema + dedup rules
- \`docs/agent-runtime/wiki-graph-rules.md\` — graph edge policy

## What's already automatic

- MEMORY-SCHEMA.md sync to every agent home (just ran via \`bridge-docs.py apply --all\`)
- Librarian CLAUDE.md template propagation
- PreCompact hook registration on active claude agents (from bootstrap)

## Operator actions pending (per-release admin checklist)

Read \`$TARGET_ROOT/OPERATOR_ACTIONS_PENDING.md\` and execute every section
whose \`applies_when_upgrading_from\` covers the previous installed version
(${INSTALLED_VERSION:-unknown} → $SOURCE_VERSION). Each section is either a
concrete action to run on this host or a clearly-marked skip rule. Close
this task only after each applicable section is either executed or noted as
"not applicable here because <reason>" in the done note. Sections that ship
with no operator action (most release bumps) need no follow-up.

## Done note format

When you finish the three steps above and processed every applicable section
of OPERATOR_ACTIONS_PENDING.md, close this task with:
\`agb done <task_id> --note "bootstrap OK; first-scan <N> files / <M> entities; distribution report at <path>; operator-actions: <summary>"\`
POST_EOF

    # Bug #507: append the cleanup summary + verification block to the
    # post-upgrade task body. The summary is what auto-cleanup actually
    # did; the verification block is the agent-safe self-check the admin
    # runs to confirm everything is back to normal. If cleanup failed,
    # the recovery snippet inside CLEANUP_SUMMARY_MD points the operator
    # at the manual command.
    if [[ -n "$CLEANUP_SUMMARY_MD" ]]; then
      printf '\n%s\n' "$CLEANUP_SUMMARY_MD" >>"$_post_body"
    fi
    {
      printf '\n'
      bridge_cleanup_render_verification_block "$TARGET_ROOT"
    } >>"$_post_body"
    # Persist the task body in state/ so the recovery command the
    # WARN block prints is actually rerunnable. Tempfiles vanish on
    # exit and leave the operator with guidance instead of a command
    # that would copy-paste into "no such file". The persistent copy
    # is deleted only on successful task create.
    _post_body_persist_dir="$TARGET_ROOT/state/bridge-upgrade/post-task"
    mkdir -p "$_post_body_persist_dir"
    _post_body_persist="$_post_body_persist_dir/upgrade-complete-$(date -u +%Y%m%dT%H%M%SZ).md"
    cp "$_post_body" "$_post_body_persist"
    _post_task_log="$(mktemp -t bridge-upgrade-post-task.XXXXXX.log)"
    if bridge_upgrade_with_target_env "$TARGET_ROOT" "$TARGET_ROOT/agent-bridge" task create \
        --to "$_post_admin" --priority normal --from "$_post_admin" \
        --title "[upgrade-complete] Agent Bridge $SOURCE_VERSION — run bootstrap" \
        --body-file "$_post_body_persist" >"$_post_task_log" 2>&1; then
      # Task created successfully — queue kept a durable copy of the
      # body; the persist file in state/ is redundant.
      rm -f "$_post_body_persist"
    else
      # Surface failure on stderr so the operator sees it on upgrade.
      # A silent `|| true` here was the R9 reliability gap — the
      # entire post-upgrade signal chain is anchored on this task
      # actually being delivered. The rest of the upgrade succeeded;
      # the notification specifically did not. Re-running agb upgrade
      # retries the task emission. The persistent body stays on disk
      # so the printed recovery command is literally rerunnable.
      {
        echo "[bridge-upgrade] WARN: could not file [upgrade-complete] task for admin=$_post_admin"
        echo "[bridge-upgrade] WARN: admin inbox will not be auto-notified. Re-run 'agb upgrade' to retry, or"
        echo "[bridge-upgrade] WARN: queue manually:"
        echo "[bridge-upgrade] WARN:   $TARGET_ROOT/agent-bridge task create --to $_post_admin \\"
        echo "[bridge-upgrade] WARN:     --priority normal --from $_post_admin \\"
        echo "[bridge-upgrade] WARN:     --title '[upgrade-complete] Agent Bridge $SOURCE_VERSION — run bootstrap' \\"
        echo "[bridge-upgrade] WARN:     --body-file $_post_body_persist"
        echo "[bridge-upgrade] WARN: task create stderr follows:"
        sed 's/^/[bridge-upgrade] WARN:   /' "$_post_task_log"
      } >&2
    fi
    rm -f "$_post_body" "$_post_task_log"
  fi
fi

if [[ $RESTART_AGENTS -eq 1 ]]; then
  AGENT_RESTART_REPORT="$(bridge_upgrade_collect_agent_restart_report "$TARGET_ROOT" "$DRY_RUN")"
  # Issue 4 (v0.11.0): reconcile failed rows against the daemon's
  # subsequent launch cycle so the upgrade summary does not over-report
  # failures the daemon already absorbed. No-op when dry-run or when no
  # `failed` rows are present.
  AGENT_RESTART_REPORT="$(bridge_upgrade_reconcile_agent_restart_recovery "$TARGET_ROOT" "$AGENT_RESTART_REPORT" "$DRY_RUN")"
  AGENT_RESTART_JSON="$(bridge_upgrade_agent_restart_json "$AGENT_RESTART_REPORT" 1 "$DRY_RUN")"
fi

if [[ $JSON -eq 1 ]]; then
  _json_payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-json.XXXXXX")"
  printf '%s' "$BACKUP_JSON" >"$_json_payload_dir/backup.json"
  printf '%s' "$MIGRATION_JSON" >"$_json_payload_dir/migration.json"
  printf '%s' "$APPLY_JSON" >"$_json_payload_dir/apply.json"
  printf '%s' "$ANALYSIS_JSON" >"$_json_payload_dir/analysis.json"
  printf '%s' "$AGENT_RESTART_JSON" >"$_json_payload_dir/agent-restart.json"
  printf '%s' "$CHANNEL_GUARD_JSON" >"$_json_payload_dir/channel-guard.json"
  printf '%s' "$SOURCE_RECLASSIFY_JSON" >"$_json_payload_dir/source-reclassify.json"
  printf '%s' "$SHARED_SETTINGS_RERENDER_JSON" >"$_json_payload_dir/shared-settings-rerender.json"
  # PR #508 r2: surface the daily-backup cleanup payload in --json output
  # so operators / monitoring can read `cleanup_failures` programmatically
  # (matches the OPERATIONS.md contract). Empty file when cleanup didn't
  # run (e.g. dry-run paths that bypass the cleanup block above).
  printf '%s' "${CLEANUP_JSON:-}" >"$_json_payload_dir/cleanup.json"
  # Issue #668 (r2): surface the isolation-v2 migration payload in --json
  # output so operators reading the JSON envelope can detect the macOS
  # supplemental-group cache caveat (`migration_requires_relogin`) and the
  # Linux daemon-restart deferred path. The payload is emitted by
  # lib/bridge-isolation-v2-migrate.sh:1578 on apply, and a dry-run-shaped
  # placeholder on dry-run. Always-present so JSON consumers can branch on
  # the field's contents instead of having to handle missing-key vs value.
  printf '%s' "${ISOLATION_V2_MIGRATION_JSON:-}" >"$_json_payload_dir/isolation-v2-migration.json"
  # Issue #752 W3d: emit dedup'd partial-failure subsystem names as a
  # JSON array file so the python envelope below can branch
  # `status:"partial"` + `partial_failures:[...]`. Empty array on the
  # all-clear path keeps `status:"ok"` semantics intact.
  if (( ${#_upgrade_partial_failures[@]} > 0 )); then
    printf '%s\n' "${_upgrade_partial_failures[@]}" \
      | python3 -c 'import json,sys; print(json.dumps(sorted(set(line.strip() for line in sys.stdin if line.strip()))))' \
      >"$_json_payload_dir/partial-failures.json"
  else
    printf '[]' >"$_json_payload_dir/partial-failures.json"
  fi
  set +e
  python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$PULL" "$DRY_RUN" "$RESTART_DAEMON" "$RESTART_AGENTS" "$BACKUP" "$MIGRATE_AGENTS" "$BACKUP_ROOT" "$STRICT_MERGE" "$CHANNEL" "$SOURCE_VERSION" "$SOURCE_REF" "$SOURCE_HEAD" "$TARGET_REF" "$TARGET_VERSION" "$TARGET_HEAD" "$_json_payload_dir/backup.json" "$_json_payload_dir/migration.json" "$_json_payload_dir/apply.json" "$_json_payload_dir/analysis.json" "$_json_payload_dir/agent-restart.json" "$_json_payload_dir/channel-guard.json" "$_json_payload_dir/source-reclassify.json" "$_json_payload_dir/shared-settings-rerender.json" "$_json_payload_dir/cleanup.json" "$_json_payload_dir/isolation-v2-migration.json" "$_json_payload_dir/partial-failures.json" <<'PY'
import json, sys
source_root, target_root, pull, dry_run, restart_daemon, restart_agents, backup_enabled, migrate_agents, backup_root, strict_merge, channel, source_version, source_ref, source_head, target_ref, target_version, target_head, backup_json_file, migration_json_file, apply_json_file, analysis_json_file, agent_restart_json_file, channel_guard_json_file, source_reclassify_json_file, shared_settings_rerender_json_file, cleanup_json_file, isolation_v2_migration_json_file, partial_failures_json_file = sys.argv[1:]

def load_json(path):
    with open(path, encoding="utf-8") as fh:
        return json.load(fh)

def load_optional_json(path):
    try:
        with open(path, encoding="utf-8") as fh:
            text = fh.read().strip()
    except FileNotFoundError:
        return None
    if not text:
        return None
    try:
        return json.loads(text)
    except json.JSONDecodeError:
        return {"_raw": text, "_parse_error": True}

backup_payload = load_json(backup_json_file)
migration_payload = load_json(migration_json_file)
apply_payload = load_json(apply_json_file)
analysis_payload = load_json(analysis_json_file)
agent_restart_payload = load_json(agent_restart_json_file)
channel_guard_payload = load_json(channel_guard_json_file)
source_reclassify_payload = load_json(source_reclassify_json_file)
shared_settings_rerender_payload = load_json(shared_settings_rerender_json_file)
cleanup_payload = load_optional_json(cleanup_json_file)
# Always include the isolation-v2 migration field so JSON consumers can
# branch on the contents (status="applied" + migration_requires_relogin,
# skipped="dry-run", etc.) without missing-key handling. Falls back to
# null when the variable was empty (defensive — current code paths always
# set ISOLATION_V2_MIGRATION_JSON before reaching the JSON envelope).
isolation_v2_migration_payload = load_optional_json(isolation_v2_migration_json_file)
# Issue #752 W3d: late-stage subsystems (shared rerender / channel-policy
# refresh / profile relink) append their stable name to this list when
# their post-step probe reports failures. `status:"partial"` surfaces the
# failure to operators / CI without aborting the upgrade — the rest of
# the upgrade (daemon restart, [upgrade-complete] task) still ran.
try:
    with open(partial_failures_json_file, encoding="utf-8") as fh:
        partial_failures = json.loads(fh.read() or "[]")
except (FileNotFoundError, ValueError):
    partial_failures = []
status = "partial" if partial_failures else "ok"
payload = {
    "mode": "upgrade",
    "status": status,
    "partial_failures": partial_failures,
    "version": source_version,
    "source_root": source_root,
    "source_ref": source_ref,
    "source_head": source_head,
    "target_root": target_root,
    "channel": channel,
    "target_ref": target_ref,
    "target_version": target_version,
    "target_head": target_head,
    "pull": pull == "1",
    "dry_run": dry_run == "1",
    "restart_daemon": restart_daemon == "1",
    "restart_agents": restart_agents == "1",
    "backup_enabled": backup_enabled == "1",
    "migrate_agents": migrate_agents == "1",
    "strict_merge": strict_merge == "1",
    "backup_root": backup_root,
    "preserved_paths": [
        "agent-roster.local.sh",
        "state/",
        "logs/",
        "shared/",
        "backups/",
        "worktrees/",
        "agents/<agent>/",
    ],
    "backup": backup_payload,
    "apply": apply_payload,
    "analysis": analysis_payload,
    "channel_guard": channel_guard_payload,
    "agent_restart": agent_restart_payload,
    "agent_migration": migration_payload,
    "isolation_v2_migration": isolation_v2_migration_payload,
    "source_reclassify": source_reclassify_payload,
    "shared_settings_rerender": shared_settings_rerender_payload,
    "cleanup": cleanup_payload,
  }
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  _json_rc=$?
  set -e
  rm -rf "$_json_payload_dir"
  # Issue #682: mark the success-path JSON envelope as emitted so the
  # EXIT trap does not double-print a failure envelope when `exit
  # "$_json_rc"` itself is non-zero (rare — the python heredoc above
  # already produced output; a second envelope would corrupt the
  # contract). On _json_rc != 0, the trap fires, sees the flag=1, and
  # skips emit; operator still gets the raw python stderr.
  _BRIDGE_UPGRADE_JSON_EMITTED=1
  exit "$_json_rc"
fi

echo "== Agent Bridge upgrade =="
echo "version: $SOURCE_VERSION"
echo "channel: $CHANNEL"
echo "source_ref: $SOURCE_REF"
echo "source_head: ${SOURCE_HEAD:0:12}"
echo "target_ref: ${TARGET_REF:-current}"
echo "source_root: $SOURCE_ROOT"
echo "target_root: $TARGET_ROOT"
echo "preserved_customizations: agent-roster.local.sh, state/, logs/, shared/, backups/, worktrees/, agents/<agent>/"
echo "strict_merge: $([[ $STRICT_MERGE -eq 1 ]] && printf yes || printf no)"
echo "restart_agents: $([[ $RESTART_AGENTS -eq 1 ]] && printf yes || printf no)"
if [[ $BACKUP -eq 1 ]]; then
  echo "backup_root: $BACKUP_ROOT"
  python3 - "$BACKUP_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(f"backup_created: {'yes' if payload.get('created') else 'no'}")
PY
fi
python3 - "$ANALYSIS_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
counts = payload.get("counts", {})
print(f"analysis_base_ref: {payload.get('base_ref') or '-'}")
print(f"analysis_missing_live: {counts.get('missing_live', 0)}")
print(f"analysis_upstream_only: {counts.get('upstream_only', 0)}")
print(f"analysis_live_only: {counts.get('live_only', 0)}")
print(f"analysis_merge_required: {counts.get('merge_required', 0)}")
print(f"analysis_unknown_base_live_diff: {counts.get('unknown_base_live_diff', 0)}")
PY
bridge_upgrade_print_channel_guard_summary "$CHANNEL_GUARD_JSON"
python3 - "$SOURCE_RECLASSIFY_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
count = int(payload.get("count") or 0)
mode = payload.get("mode") or "dry-run"
print(f"source_reclassify: {count} candidate(s) ({mode})")
for item in payload.get("candidates") or []:
    print(f"  - {item.get('action')}: {item.get('agent')} old_source={item.get('old_source')} new_source={item.get('new_source')} reason={item.get('reason')}")
PY
python3 - "$SHARED_SETTINGS_RERENDER_JSON" <<'PY'
import json, sys
# Issue #731: same defensive guard as the verification heredoc above —
# empty/non-JSON SHARED_SETTINGS_RERENDER_JSON should not raise a raw
# traceback in the post-upgrade summary, just emit a named WARN.
raw = (sys.argv[1] if len(sys.argv) > 1 else "").strip()
if not raw:
    print("[bridge-upgrade] WARN: shared-settings rerender returned empty payload (likely isolated agent canonical_dir failure — see #731)", file=sys.stderr)
    sys.exit(0)
try:
    payload = json.loads(raw)
except json.JSONDecodeError as exc:
    print(f"[bridge-upgrade] WARN: shared-settings rerender returned non-JSON payload: {exc}", file=sys.stderr)
    print(f"[bridge-upgrade] payload preview: {raw[:200]!r}", file=sys.stderr)
    sys.exit(0)
count = int(payload.get("count") or 0)
failed = int(payload.get("failed_count") or 0)
mode = payload.get("mode") or "skipped"
print(f"shared_settings_rerender: {count} target(s) ({mode}), failed={failed}")
for item in payload.get("candidates") or []:
    status = item.get("status") or "unknown"
    agent = item.get("agent") or "-"
    changes = item.get("before", item).get("changes") or item.get("changes") or []
    change_keys = ",".join(str(change.get("key")) for change in changes) or "-"
    print(f"  - {status}: {agent} changes={change_keys}")
PY
python3 - "$APPLY_JSON" "$RECONCILE_JSON" "$UPGRADE_RUN_ID" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
reconcile = json.loads(sys.argv[2])
run_id = sys.argv[3]
counts = payload.get("counts", {})
print(f"files_copied: {counts.get('files_copied', 0)}")
print(f"files_merged_clean: {counts.get('files_merged_clean', 0)}")
print(f"files_merged_conflict: {counts.get('files_merged_conflict', 0)}")
print(f"files_preserved_live: {counts.get('files_preserved_live', 0)}")
conflicts = payload.get("conflict_backups") or []
print(f"conflict_backups: {len(conflicts)}")
if conflicts:
    print("[warn] unresolved merge conflicts were backed up; review these files:")
    for path in conflicts[:10]:
        print(f"  - {path}")
    if len(conflicts) > 10:
        print(f"  ... +{len(conflicts) - 10} more")
# Issue #394: end-of-run summary. Reports the auto-archive count from
# the start-of-run reconcile pass and the new-conflict count from this
# run, plus the run-id pointer to state/upgrade-conflicts/<run-id>.json
# so operators can find the structured record and inspect at-write
# hashes without grepping the live tree.
auto_archived = int(reconcile.get("archived_count") or 0)
if auto_archived:
    print(f"auto_archived_stale_conflicts: {auto_archived}")
print(
    f"[bridge-upgrade] wrote {len(conflicts)} .upgrade-conflict file(s) "
    f"(run-id={run_id}); review with: agent-bridge upgrade conflicts list"
)
PY
if [[ $MIGRATE_AGENTS -eq 1 ]]; then
  python3 - "$MIGRATION_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
print(f"agents_migrated: {payload.get('agents_with_additions', 0)}")
print(f"migrated_files: {payload.get('added_files', 0)}")
PY
fi
bridge_upgrade_print_agent_restart_summary "$AGENT_RESTART_JSON"
