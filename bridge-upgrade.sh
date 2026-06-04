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
# Beta20 L2 Variant 3A — bridge_host_profile_is_dev is defined in
# lib/bridge-host-profile.sh (not pulled in by bridge-lib.sh). The
# upgrade-time sudoers regeneration gate at line ~2243 depends on it.
# shellcheck source=lib/bridge-host-profile.sh
source "$SCRIPT_DIR/lib/bridge-host-profile.sh"
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
ALLOW_DOWNGRADE=0
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
  $(basename "$0") [--source <repo-dir>] [--target <bridge-home>] [--apply] [--check] [--channel stable|dev|current] [--version <semver>] [--ref <git-ref>] [--allow-downgrade] [--pull|--no-pull] [--restart-daemon|--no-restart-daemon] [--restart-agents|--no-restart-agents] [--dry-run] [--json] [--allow-dirty] [--allow-dirty-source] [--strict-merge] [--no-backup] [--no-migrate-agents]
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

The default stable channel skips pre-release (beta/rc) tags. On a pre-release install
a bare \`upgrade --apply\` would otherwise resolve to a LOWER stable version and silently
downgrade the install; the upgrader now refuses such a backward move. Pin the intended
version with \`--ref <tag>\`, or pass \`--allow-downgrade\` to force the backward move.
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
  # envelope when the corresponding bash var was empty. Footgun #11 third
  # variant (task #4538 codex r1 catch): body moved to
  # lib/upgrade-helpers/emit-failure-json.py so the EXIT trap path no longer
  # has a heredoc-stdin-to-python wedge candidate when the leap aborts
  # pre-apply (e.g. isolation-v2 failure at lines ~1457-1469). The fallback
  # printf below still fires if the helper script is missing or python is
  # broken on the host. SOURCE_ROOT may be unset when this runs very early
  # (before the source-root resolution block); fall back to SCRIPT_DIR which
  # is set at script entry so the helper path always resolves.
  local _emit_helper="${SOURCE_ROOT:-${SCRIPT_DIR:-}}/lib/upgrade-helpers/emit-failure-json.py"
  if ! python3 "$_emit_helper" \
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
        2>/dev/null
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
  # Footgun #11 (heredoc/here-string deadlock — refs #265 / #800 / #815):
  # piping `git tag` output directly into python3 avoids the
  # `python3 ... <<<"$tags"` here-string that wedges Bash 5.3.9 in
  # `read_comsub` during a v0.7.x → v0.13.x upgrade --apply leap.
  git -C "$root" tag --list 'v[0-9]*.[0-9]*.[0-9]*' | python3 -c '
import re
import sys

tags = [line.strip() for line in sys.stdin if re.fullmatch(r"v\d+\.\d+\.\d+", line.strip())]
tags.sort(key=lambda tag: tuple(int(part) for part in tag[1:].split(".")))
print(tags[-1] if tags else "")
'
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

# Issue #1516: full semver 2.0.0 ordering of two version strings, so the
# apply path can detect a backward (downgrade) target before mutating the
# install. Echoes "-1"/"0"/"1" (installed <, ==, > target) on stdout, or
# nothing when either side is unparseable. Delegates to
# `bridge-release.py compare`, reusing the exact comparator the
# release-notification path uses so the two never disagree (a beta of
# 0.16.0 is NEWER than 0.15.4 but OLDER than 0.16.0 final). Uses
# `python3 <script> compare a b` (file-as-argv) — never a heredoc on
# stdin — to stay clear of the Bash 5.3.9 read_comsub deadlock (footgun
# #11).
bridge_upgrade_compare_versions() {
  local source_root="$1"
  local lhs="$2"
  local rhs="$3"
  python3 "$source_root/bridge-release.py" compare "$lhs" "$rhs" 2>/dev/null || true
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
    BRIDGE_UPGRADE_CONTEXT="${BRIDGE_UPGRADE_CONTEXT:-}" \
    "$@"
}

# Footgun #11 (refs #265 / #800 / #815 / #890): Bash 5.3.9 deadlocks in
# `read_comsub` when a parent `$()` command substitution captures the stdout
# of a child whose own stdin is fed by a heredoc (the `python3 - <<'PY' …`
# and `bash -s -- … <<'EOF' …` shapes used by several helpers in this file).
# v0.13.7 fixed the `<<<` here-string variants of the same class; v0.13.8
# closes the heredoc-stdin variant by staging stdout through a tempfile and
# reading it back with the `$(< file)` bash builtin form, which does NOT
# fork a subshell and therefore cannot wedge `read_comsub`.
#
# Usage: bridge_upgrade_capture_to_var <varname> <cmd> [args...]
#
# Exit status reflects <cmd>'s exit status. The tempfile is removed on both
# success and failure paths; nothing persists on disk after the call returns.
bridge_upgrade_capture_to_var() {
  local _bucv_var="$1"
  shift
  local _bucv_tmp _bucv_rc=0
  _bucv_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-capture.XXXXXX")" || return 1
  # The `|| _bucv_rc=$?` idiom disarms `set -e` AND captures the real exit
  # status. A bare `if ! "$@"; then ... $? ... fi` would lose the original
  # rc because the `!` resets `$?` inside the then-branch to 0 (the inverted
  # pipeline status), so the caller would see success even when "$@" failed.
  "$@" >"$_bucv_tmp" || _bucv_rc=$?
  if (( _bucv_rc != 0 )); then
    rm -f -- "$_bucv_tmp"
    return "$_bucv_rc"
  fi
  # `$(< file)` is the bash builtin shortcut for reading a file's contents
  # without forking a subshell — safe under Bash 5.3.9. Trailing-newline
  # stripping matches the semantics of the original `$()` capture it
  # replaces, so callers that compared the value to a non-newline-terminated
  # constant behave identically.
  printf -v "$_bucv_var" '%s' "$(<"$_bucv_tmp")"
  rm -f -- "$_bucv_tmp"
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
      # Patch HUD statusLine to include hud-usage-tap.py so bridge-usage.py
      # keeps receiving .usage-cache.json data after claude-hud v0.0.12+
      # removed background OAuth polling. No-op for agents without a HUD
      # statusLine or those already patched.
      bridge_ensure_hud_usage_tap "$workdir" "$launch_cmd" "$agent" >/dev/null 2>&1 || true
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

# bridge_upgrade_propagate_codex_hooks <target_root>
#
# Issue #1067 S08: re-render Codex hooks for every codex-engine agent during
# upgrade. Mirrors bridge_upgrade_propagate_claude_hooks but for the Codex
# hook surface. Writes to the descriptor-owned per-agent path
# (<agent_home>/.codex/hooks.json), not the shared $HOME/.codex/hooks.json.
#
# The body lives in lib/upgrade-helpers/codex-hooks-propagate.sh (file-as-
# argv pattern) to avoid the Bash 5.3.9 heredoc-stdin deadlock (footgun #11).
# No-op when no codex-engine agents are registered.
bridge_upgrade_propagate_codex_hooks() {
  local target_root="$1"
  local _helper="$SOURCE_ROOT/lib/upgrade-helpers/codex-hooks-propagate.sh"
  [[ -f "$_helper" ]] || return 0
  bridge_upgrade_with_target_env "$target_root" \
    "$BRIDGE_BASH_BIN" "$_helper" "$SOURCE_ROOT" "$target_root" >/dev/null 2>&1 || true
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
  # Footgun #11 (refs #265 / #800 / #815): pipe instead of here-string
  # to keep Bash 5.3.9 from wedging in `read_comsub` during apply leaps.
  if ! printf '%s\n' "$report" | grep -qE $'\t''failed'$'\t'; then
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

    # Tab-separated read inside this -lc body: the ANSI-C tab escape
    # sequence is awkward to embed in a single-quoted -lc heredoc
    # because the apostrophes terminate the outer quote, so we
    # materialise the tab into a variable. printf is portable across
    # the bash versions we support.
    TAB="$(printf "\t")"

    # Footgun #11 (refs #265 / #800 / #815): stage the report through a
    # tempfile and stream `< $tempfile` instead of `done <<<"$report"`.
    # The here-string form wedges Bash 5.3.9 in `read_comsub` /
    # `heredoc_write` during a v0.7.x → v0.13.x upgrade --apply leap.
    _rep_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-rep.XXXXXX")"
    # shellcheck disable=SC2064
    trap "rm -f -- \"$_rep_tmp\"" EXIT
    # Trailing newline matches the original `<<<` semantics so the last
    # row is delivered to read. Command substitution strips trailing
    # newlines from the caller report, so we re-add one here.
    printf "%s\n" "$report" > "$_rep_tmp"

    # Collect the agents that need a recovery probe up front so the
    # poll loop can short-circuit as soon as all of them are active.
    failed_agents=()
    while IFS="$TAB" read -r agent status _reason _attached _session _exit_code _log_tail; do
      [[ -n "$agent" ]] || continue
      if [[ "$status" == "failed" ]]; then
        failed_agents+=("$agent")
      fi
    done < "$_rep_tmp"

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
    done < "$_rep_tmp"
  ' -- "$target_root" "$source_root" "$settle_seconds" "$report"
}

bridge_upgrade_agent_restart_json() {
  local report="$1"
  local enabled="$2"
  local dry_run="${3:-0}"

  # JSON key contract documented at the top of
  # lib/upgrade-helpers/agent-restart-json.py (#253/#254/#257). Footgun #11
  # (task #4538): the python heredoc body was moved into that file because
  # `python3 - <<'PY' … PY` heredoc-stdin wedges Bash 5.3.9 (producer-side).
  python3 "$SOURCE_ROOT/lib/upgrade-helpers/agent-restart-json.py" \
    "$enabled" "$dry_run" "$report"
}

# Issue #980: extract the agent IDs that an agent-restart report skipped
# with reason="attached" (the operator's own live tmux session was attached
# so the restart was declined). Echoes one agent ID per line; empty output
# when no agent was attached-skipped. The report argument is the 7-column
# tab-separated tuple from `bridge_upgrade_collect_agent_restart_report`.
#
# Footgun #11 (refs #265 / #800 / #815): the report is streamed through a
# pipe into `while read`, never a here-string, to keep Bash 5.3.9 out of
# the `read_comsub` wedge during apply leaps.
bridge_upgrade_attached_skipped_agents() {
  local report="$1"
  local _tab agent status reason
  _tab="$(printf '\t')"
  [[ -n "$report" ]] || return 0
  printf '%s\n' "$report" | while IFS="$_tab" read -r agent status reason _; do
    [[ -n "$agent" ]] || continue
    if [[ "$status" == "skipped" && "$reason" == "attached" ]]; then
      printf '%s\n' "$agent"
    fi
  done
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
# Issue #980: an `attached`-skipped agent is the operator's own live
# session — the upgrade (correctly) declined to restart it, but that
# agent is now running the OLD code. A bare `agent_restart_skipped_attached`
# count is easy to miss, so surface an explicit manual-restart notice with
# the exact agent IDs and the command to run.
attached_skipped = payload.get("skipped_attached_agents") or []
if attached_skipped:
    print(
        "agent_restart_warning: the following agent(s) are running OLD "
        "code and need a manual restart:"
    )
    for agent_id in attached_skipped:
        print(f"  {agent_id}  (skipped: active tmux session attached)")
    print(
        "agent_restart_warning: when ready, run: "
        f"agent-bridge agent restart {' '.join(attached_skipped)}"
    )
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

  # Footgun #11 third variant (task #4538): the heredoc body that used to
  # live here wedges Bash 5.3.9 in `heredoc_write -> write()` (producer-side
  # mirror of the read_comsub bug fixed in v0.13.7 and v0.13.8). The
  # script body now lives in lib/upgrade-helpers/channel-guard-report.sh and
  # is invoked as a regular file argument — no heredoc-stdin anywhere on
  # this path.
  bridge_upgrade_with_target_env "$target_root" "$BRIDGE_BASH_BIN" \
    "$source_root/lib/upgrade-helpers/channel-guard-report.sh" \
    "$source_root" "$target_root"
}

bridge_upgrade_channel_guard_json() {
  local report="$1"

  # Footgun #11 (task #4538): the python heredoc body that used to live here
  # is now lib/upgrade-helpers/channel-guard-json.py — invoked with file-as-
  # argv so no heredoc-stdin path remains.
  python3 "$SOURCE_ROOT/lib/upgrade-helpers/channel-guard-json.py" "$report"
}

bridge_upgrade_print_channel_guard_summary() {
  local payload="$1"

  # Spool payload to tempfile and pass filename — see r1/r2 rationale at line 2313.
  local _guard_dir
  _guard_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-guard-json.XXXXXX")"
  printf '%s' "$payload" >"$_guard_dir/payload.json"
  python3 - "$_guard_dir/payload.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
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
  rm -rf "$_guard_dir"
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

# #8945 Track D: record the Codex CLI version across upgrades and surface a
# NON-FATAL operator advisory when the MAJOR or MINOR component changes.
# Codex CLI capability (hooks, AGENTS.md, slash commands, permission
# profiles) grows between minor releases; an operator who jumped Codex
# versions should re-check the bridge's Codex provisioning (hook list,
# AGENTS.md protocol, `codex doctor`) against the new CLI.
#
# Strictly advisory + best-effort:
#   - Missing codex CLI → skip silently (same non-fatal precedent as the
#     admin codex-pair auto-provisioning, lib/bridge-init-codex-pair.sh).
#   - First time we ever see a codex version → record it, no advisory
#     (there is no prior version to compare against).
#   - MAJOR.MINOR unchanged → record (patch bumps are quiet), no advisory.
#   - MAJOR or MINOR changed → print the advisory to stderr, then record
#     the new version so the advisory fires once per major/minor change.
# Never fails the upgrade: every branch returns 0.
#
# State file: $TARGET_ROOT/state/upgrade/codex-version.last (a single line,
# the raw `codex --version` token, e.g. "codex-cli 0.135.0"). Parsing is
# pure shell + awk — NO heredoc-stdin to a subprocess (bridge-upgrade.sh is
# at the lint-heredoc-ban ceiling; footgun #11). The advisory text uses a
# `cat >&2 <<` fd-redirect heredoc, which is NOT a subprocess interpreter
# site and is not counted by the ratchet.
bridge_upgrade_emit_codex_version_advisory() {
  local target_root="$1"
  local dry_run="${2:-0}"
  local advisory_mode="${BRIDGE_CODEX_VERSION_ADVISORY:-1}"

  if [[ "$advisory_mode" == "0" ]]; then
    return 0
  fi

  if ! command -v codex >/dev/null 2>&1; then
    # Non-fatal: a codex-less host has nothing to advise on.
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "[bridge-upgrade] plan: record codex --version + advise on a major/minor change (non-fatal, one-shot per change)" >&2
    return 0
  fi

  # Capture the raw version token. Best-effort: a codex that errors on
  # --version is treated as unknown and skipped.
  #
  # errexit safety (codex internal-review r1): bridge-upgrade.sh runs under
  # `set -euo pipefail`. Every capture below MUST carry a `|| var=""`
  # fallback so a nonzero in the command substitution (codex --version
  # exiting nonzero, a no-match `grep -oE` returning 1, or a pipefail
  # member failing) does NOT abort the whole upgrade. The advisory is
  # strictly non-fatal — an unparseable / failing codex is "unknown and
  # skipped", never an upgrade blocker.
  local current_raw=""
  current_raw="$(codex --version 2>/dev/null | head -n 1 | tr -d '\r')" || current_raw=""
  [[ -n "$current_raw" ]] || return 0

  # Extract the first dotted numeric token (e.g. "0.135.0") from the raw
  # line, then its MAJOR.MINOR. grep -oE keeps this portable across the
  # "codex-cli 0.135.0" / "codex 0.135.0" surface variants. `grep -oE`
  # exits 1 on no-match — the `|| current_ver=""` keeps that from tripping
  # errexit, and the empty-guard below then returns 0.
  local current_ver=""
  current_ver="$(printf '%s\n' "$current_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)" || current_ver=""
  [[ -n "$current_ver" ]] || return 0
  local current_mm=""
  current_mm="$(printf '%s\n' "$current_ver" | awk -F. '{print $1"."$2}')" || current_mm=""

  local state_dir="$target_root/state/upgrade"
  local state_file="$state_dir/codex-version.last"

  local prev_raw=""
  if [[ -f "$state_file" ]]; then
    prev_raw="$(head -n 1 "$state_file" 2>/dev/null | tr -d '\r')" || prev_raw=""
  fi

  # Record helper (best-effort; failure to record is non-fatal — the next
  # upgrade just re-evaluates).
  mkdir -p "$state_dir" 2>/dev/null || true

  if [[ -z "$prev_raw" ]]; then
    # First observation — no baseline to compare. Record silently.
    printf '%s\n' "$current_raw" >"$state_file" 2>/dev/null || true
    return 0
  fi

  local prev_ver=""
  prev_ver="$(printf '%s\n' "$prev_raw" | grep -oE '[0-9]+\.[0-9]+(\.[0-9]+)?' | head -n 1)" || prev_ver=""
  local prev_mm=""
  prev_mm="$(printf '%s\n' "$prev_ver" | awk -F. '{print $1"."$2}')" || prev_mm=""

  if [[ -n "$prev_mm" && "$prev_mm" != "$current_mm" ]]; then
    cat >&2 <<ADVISORY
[bridge-upgrade] ADVISORY: Codex CLI changed ${prev_ver:-$prev_raw} -> ${current_ver:-$current_raw} (major/minor).
[bridge-upgrade] Codex capabilities (hooks, AGENTS.md protocol, slash commands, permission profiles) can change across minor releases.
[bridge-upgrade] Recommended: re-check Codex agents with 'codex doctor', and confirm the bridge's Codex hook list + AGENTS.md protocol still match the new CLI.
[bridge-upgrade] This advisory fires once per major/minor change. Suppress with BRIDGE_CODEX_VERSION_ADVISORY=0.
ADVISORY
  fi

  # Record the new version regardless of whether the advisory fired so a
  # patch-only bump updates the baseline and a major/minor advisory does
  # not repeat on the next upgrade.
  printf '%s\n' "$current_raw" >"$state_file" 2>/dev/null || true
  return 0
}

# Issue #4769 (reverts #517): when a host carries the auto-created
# `admin` + `admin-dev` pair from a previous v0.14.x upgrade, emit a
# non-destructive advisory describing the explicit-setup contract and
# the retire/setup recipe to restore the operator's intended admin id
# (typically `patch`). Strictly read-only: no roster mutation, no agent
# removal. Dry-run prints a plan line instead of probing the live
# install.
#
# Idempotency: the advisory is one-shot. After printing, drop a marker
# at $TARGET_ROOT/state/admin-pair-advisory-acknowledged.ts so the next
# upgrade short-circuits. Operators who keep admin/admin-dev never see
# the advisory after the first upgrade. Operators who want to re-read
# the recipe can `rm $BRIDGE_HOME/state/admin-pair-advisory-acknowledged.ts`
# or set BRIDGE_ADMIN_PAIR_ADVISORY=force. Hard-suppress with
# BRIDGE_ADMIN_PAIR_ADVISORY=0.
bridge_upgrade_emit_admin_pair_advisory() {
  local target_root="$1"
  local admin_id="$2"
  local dry_run="${3:-0}"
  local advisory_mode="${BRIDGE_ADMIN_PAIR_ADVISORY:-1}"

  if [[ "$advisory_mode" == "0" ]]; then
    return 0
  fi

  if [[ "$dry_run" == "1" ]]; then
    echo "[bridge-upgrade] plan: advise on auto-created admin/admin-dev (one-shot; no-op when absent or acknowledged)" >&2
    return 0
  fi

  # Heuristic for "auto-created by removed admin-pair feature":
  #   - $BRIDGE_ADMIN_AGENT_ID resolves to literal "admin"
  #   - both `admin/` and `admin-dev/` agent homes exist
  # An operator who explicitly chose admin/admin-dev as their pair gets
  # the advisory ONCE — the recipe is non-destructive and they can
  # ignore it. The marker prevents repeat noise on subsequent upgrades.
  [[ "$admin_id" == "admin" ]] || return 0
  local agent_root="$target_root/agents"
  [[ -d "$agent_root/admin" ]] || return 0
  [[ -d "$agent_root/admin-dev" ]] || return 0

  local marker="$target_root/state/admin-pair-advisory-acknowledged.ts"
  if [[ -f "$marker" && "$advisory_mode" != "force" ]]; then
    return 0
  fi

  cat >&2 <<'ADVISORY'
[bridge-upgrade] ADVISORY: admin/admin-dev appear to be auto-created by the removed admin-pair feature.
[bridge-upgrade] To restore the recommended patch-only contract:
[bridge-upgrade]   agent-bridge agent retire admin-dev
[bridge-upgrade]   agent-bridge agent retire admin
[bridge-upgrade]   agent-bridge setup admin patch
[bridge-upgrade] (Skip if you intentionally created admin/admin-dev.)
[bridge-upgrade] This advisory will not repeat. Re-show with BRIDGE_ADMIN_PAIR_ADVISORY=force, suppress with =0.
ADVISORY

  # Best-effort marker write. state/ should already exist on a live
  # install; mkdir -p is a safety net for malformed targets. Failure
  # to write the marker is non-fatal — the next upgrade re-emits the
  # advisory, which is harmless.
  mkdir -p "$target_root/state" 2>/dev/null || true
  date -u '+%Y-%m-%dT%H:%M:%SZ' >"$marker" 2>/dev/null || true
}

bridge_upgrade_conflicts_dispatch() {
  # Issue #394: thin shell dispatcher for the `conflicts` lifecycle
  # subcommands. Delegates to bridge-upgrade.py so list/diff/adopt/
  # discard/archive/reconcile share one implementation and one
  # at-write-hash record format. The earlier PR-1 shell `list` is
  # superseded; the python-side `list` adds the
  # `live_target_hash_changed_since_write` column needed by the new
  # reconcile contract.
  #
  # Issue #1114: short-circuit -h/--help/help BEFORE binding $sub so
  # `agb upgrade conflicts --help` prints the same usage block the
  # mid-loop --help branch already prints instead of falling through
  # to the "지원하지 않는 하위 명령" error path.
  case "${1:-}" in
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
  esac
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
    --allow-downgrade)
      ALLOW_DOWNGRADE=1
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
  # Footgun #11 third variant (task #4538): replace the inline `python3 -
  # <<'PY' …` heredoc-stdin with an invocation of the standalone helper at
  # lib/upgrade-helpers/recorded-source-root.py. The v0.13.8 tempfile-capture
  # only fixed the consumer-side `$()` deadlock; the inner heredoc-stdin to
  # python still wedges Bash 5.3.9 in `heredoc_write -> write()`.
  RECORDED_SOURCE_ROOT="$(python3 "$SOURCE_ROOT/lib/upgrade-helpers/recorded-source-root.py" "$TARGET_ROOT/state/upgrade/last-upgrade.json")"
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
복구: git clone https://github.com/seanssoh/agent-bridge-public \"\$HOME/.agent-bridge-source\" 후 다시 실행하거나,
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

  # Issue #1144: capture the pre-apply VERSION (the installed version we are
  # upgrading FROM) BEFORE any SOURCE_ROOT checkout/pull below can mutate
  # TARGET_ROOT/VERSION. The post-upgrade [upgrade-complete] task body
  # downstream (line ~2210) reads ${INSTALLED_VERSION} for its
  # `from_version:` field and for the OPERATOR_ACTIONS_PENDING
  # `applies_when_upgrading_from` lookup. The variable was previously only
  # assigned inside the --check branch, so the normal apply path always
  # rendered `from_version: unknown`.
  #
  # r2 (issue #1144 follow-up): placement must precede the
  # `git -C "$SOURCE_ROOT" checkout -q "$TARGET_REF"` below. On a git-clone
  # install (UPGRADING.md §97-105) SOURCE_ROOT == TARGET_ROOT, so that
  # checkout rewrites the live VERSION file in place. Capturing AFTER the
  # checkout would yield the target release version and the task body
  # would render `from_version: <new>` instead of the previous installed
  # version.
  #
  # Prefer the live VERSION file at TARGET_ROOT (source of truth for the
  # currently-installed code); fall back to bridge_upgrade_installed_field
  # (state/upgrade/last-upgrade.json) when the VERSION file is missing or
  # zero-length on legacy installs.
  if [[ -z "${INSTALLED_VERSION:-}" ]]; then
    INSTALLED_VERSION="$(bridge_upgrade_version_from_file "$TARGET_ROOT")"
    if [[ -z "$INSTALLED_VERSION" || "$INSTALLED_VERSION" == "0.0.0-dev" ]]; then
      INSTALLED_VERSION="$(bridge_upgrade_installed_field "$TARGET_ROOT" version)"
    fi
  fi
  # END: Issue #1144 INSTALLED_VERSION capture block

  # Issue #1516: refuse a SILENT BACKWARD downgrade. The default `stable`
  # channel resolves to the latest vX.Y.Z tag and SKIPS pre-release tags,
  # so a bare `upgrade --apply` on a pre-release install (e.g.
  # 0.16.0-beta2) would resolve TARGET_VERSION to a LOWER stable version
  # (e.g. 0.15.4) and apply it with no warning — discarding the beta under
  # test. Compare the resolved TARGET to the currently-INSTALLED version
  # BEFORE any checkout/merge below mutates the tree; if the target is
  # strictly LOWER (a backward move) abort unless the operator explicitly
  # opts in with --allow-downgrade. Forward upgrades (-1) and the
  # same-version no-op (0) are untouched, as is an unparseable comparison
  # (empty result → proceed; a malformed VERSION file must not block a
  # legitimate forward upgrade). Fires for both --apply and --dry-run (so
  # the dry-run preview is honest) but never for --check, which has
  # already exited above.
  #
  # SCOPE (codex r1): only the `stable` and `ref` channels resolve an
  # AUTHORITATIVE TARGET_VERSION at this point — stable reads a fixed tag
  # (latest stable or --version) via bridge_upgrade_version_at_ref, and ref
  # reads the pinned --ref tag's VERSION directly; neither is touched by a
  # later pull. The `dev` and `current` channels instead resolve
  # TARGET_VERSION from the PRE-pull local main / working tree, and the
  # actual `git pull --ff-only` that determines the applied version runs
  # AFTER this guard (see below). Comparing the stale pre-pull value there
  # would false-block a legitimate forward `dev`/`current --pull` upgrade
  # (e.g. local main behind origin/main), so the guard skips those moving-
  # line channels — they are "advance to the tracked line" by design and
  # are not the silent stable-revert this issue reports.
  if [[ $ALLOW_DOWNGRADE -eq 0 \
        && ( "$CHANNEL" == "stable" || "$CHANNEL" == "ref" ) \
        && -n "${INSTALLED_VERSION:-}" && -n "${TARGET_VERSION:-}" ]]; then
    _downgrade_cmp="$(bridge_upgrade_compare_versions "$SOURCE_ROOT" "$INSTALLED_VERSION" "$TARGET_VERSION")"
    if [[ "$_downgrade_cmp" == "1" ]]; then
      cat >&2 <<EOF
error: refusing to DOWNGRADE the install (installed $INSTALLED_VERSION → target $TARGET_VERSION).

The default 'stable' channel skips pre-release (beta/rc) tags, so a bare
\`upgrade --apply\` on a pre-release install resolves to a LOWER stable version
and would silently move the install BACKWARD — discarding the version under test.

Proceed intentionally with one of:
  1. Pin the version you actually want:
       agent-bridge upgrade --apply --ref v$INSTALLED_VERSION   # stay on the current line
       agent-bridge upgrade --apply --ref <tag>                 # a specific release
  2. Track main (the development line):
       agent-bridge upgrade --apply --channel dev
  3. If you genuinely want the backward move to $TARGET_VERSION, force it:
       agent-bridge upgrade --apply --allow-downgrade
EOF
      exit 64
    fi
  fi
  # END: Issue #1516 downgrade guard

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
# Footgun #11 (refs #890 / task #4532): both helpers below feed their inner
# command stdin from a heredoc (`bash -s … <<'EOF'`, `python3 - … <<'PY'`).
# Capturing them with a bare `$()` wedges Bash 5.3.9 in `read_comsub` during
# a v0.7.x → v0.13.x leap. Stage stdout through a tempfile via the
# `bridge_upgrade_capture_to_var` helper instead — same value, no deadlock.
bridge_upgrade_capture_to_var CHANNEL_GUARD_REPORT \
  bridge_upgrade_channel_guard_report "$SOURCE_ROOT" "$TARGET_ROOT"
bridge_upgrade_capture_to_var CHANNEL_GUARD_JSON \
  bridge_upgrade_channel_guard_json "$CHANNEL_GUARD_REPORT"

if [[ "$SUBCOMMAND" == "analyze" ]]; then
  # Linux ARG_MAX overflow: same hazard as the post-upgrade status block below
  # (see comment at line ~2304). ANALYSIS_JSON / CHANNEL_GUARD_JSON can grow
  # past argv limits on large installs, so spool to a tempfile and pass the
  # filename rather than embedding the payload in argv.
  _analyze_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-analyze-json.XXXXXX")"
  printf '%s' "$ANALYSIS_JSON" >"$_analyze_dir/analysis.json"
  printf '%s' "$CHANNEL_GUARD_JSON" >"$_analyze_dir/channel-guard.json"
  if [[ $JSON -eq 1 ]]; then
    python3 - "$_analyze_dir/analysis.json" "$_analyze_dir/channel-guard.json" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    payload["channel_guard"] = json.load(fh)
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    python3 - "$_analyze_dir/analysis.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
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
  rm -rf "$_analyze_dir"
  exit 0
fi

if [[ "$SUBCOMMAND" == "rollback" ]]; then
  # Footgun #11: same heredoc-stdin pattern as the --apply path above.
  bridge_upgrade_capture_to_var ROLLBACK_AGENT_RESTART_JSON \
    bridge_upgrade_agent_restart_json "" 0 "$DRY_RUN"
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
    bridge_upgrade_capture_to_var ROLLBACK_AGENT_RESTART_JSON \
      bridge_upgrade_agent_restart_json "$ROLLBACK_AGENT_RESTART_REPORT" 1 "$DRY_RUN"
  fi
  # Linux ARG_MAX: ROLLBACK_JSON / ROLLBACK_AGENT_RESTART_JSON may grow with
  # restart reports; spool to tempfiles instead of passing via argv.
  _rollback_payload_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-rollback-json.XXXXXX")"
  printf '%s' "$ROLLBACK_JSON" >"$_rollback_payload_dir/rollback.json"
  printf '%s' "$ROLLBACK_AGENT_RESTART_JSON" >"$_rollback_payload_dir/agent-restart.json"
  if [[ $JSON -eq 1 ]]; then
    python3 - "$_rollback_payload_dir/rollback.json" "$_rollback_payload_dir/agent-restart.json" "$RESTART_DAEMON" "$RESTART_AGENTS" <<'PY'
import json
import sys

with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    agent_restart = json.load(fh)
payload["restart_daemon"] = sys.argv[3] == "1"
payload["restart_agents"] = sys.argv[4] == "1"
payload["agent_restart"] = agent_restart
print(json.dumps(payload, ensure_ascii=False, indent=2))
PY
  else
    python3 - "$_rollback_payload_dir/rollback.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
print("== Agent Bridge rollback ==")
print(f"target_root: {payload.get('target_root')}")
print(f"backup_root: {payload.get('backup_root')}")
print(f"restored: {'yes' if payload.get('restored') else 'no'}")
print(f"removed_entries: {payload.get('removed_entries', 0)}")
PY
    bridge_upgrade_print_agent_restart_summary "$ROLLBACK_AGENT_RESTART_JSON"
  fi
  rm -rf "$_rollback_payload_dir"
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
  # Footgun #11 third variant (task #4538): the v0.13.8 hotfix moved the
  # `$()` capture to a tempfile but left the inner `bash -s -- … <<'EOF' …`
  # heredoc-stdin in place. Bash 5.3.9 still wedges the parent in
  # `heredoc_write -> write()` when the bash -s subprocess is slow to drain
  # (sourcing bridge-lib.sh + lib/bridge-isolation-v2-migrate.sh before the
  # heredoc write completes). The migration body now lives at
  # lib/upgrade-helpers/isolation-v2-migrate.sh and is invoked with the file
  # as argv — no heredoc-stdin anywhere on this path. The tempfile + `$(<)`
  # capture is kept for symmetry with the failure-handling frame and so
  # `_migrate_rc=$?` captures the bash exit code, not mktemp/rm.
  set +e
  _iso_v2_migrate_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-isov2.XXXXXX")"
  # v0.13.10: BRIDGE_UPGRADE_CONTEXT=1 signals
  # `bridge_isolation_v2_migrate_apply_for_upgrade` that the caller is the
  # upgrader (vs. a direct `agent-bridge migrate isolation v2 --apply` run)
  # so it can take the markerless-existing-install + no-isolated-roster
  # marker-only fast-path. The env var must be propagated through
  # `bridge_upgrade_with_target_env`'s `env -i` filter.
  BRIDGE_UPGRADE_CONTEXT=1 \
  bridge_upgrade_with_target_env "$TARGET_ROOT" \
    "$BRIDGE_BASH_BIN" \
    "$SOURCE_ROOT/lib/upgrade-helpers/isolation-v2-migrate.sh" \
    "$SOURCE_ROOT" "$TARGET_ROOT" >"$_iso_v2_migrate_tmp"
  _migrate_rc=$?
  ISOLATION_V2_MIGRATION_JSON="$(<"$_iso_v2_migrate_tmp")"
  rm -f -- "$_iso_v2_migrate_tmp"
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

  # Issue #1113: v0.14.5-beta6 anchored bridge-watchdog.py's scan on the
  # v2 runtime workspace (`$BRIDGE_DATA_ROOT/agents/<a>/workdir/`), but
  # for two upgrade vintages that workspace is missing the canonical
  # identity markers:
  #   1. agents scaffolded BEFORE #1108 landed — identity files live
  #      only under the tracked profile tree `$BRIDGE_HOME/agents/<a>/`;
  #   2. agents migrated via the marker-only v2 fast-path (PR #897
  #      Track A, v0.13.10) — marker-only-no-isolated-roster writes the
  #      v2 layout marker but does NOT replay the legacy → v2 mirror.
  # The post-beta6 watchdog scans the workspace, sees no CLAUDE.md /
  # SOUL.md / SESSION-TYPE.md / MEMORY-SCHEMA.md / MEMORY.md, and
  # reports `status: error` on every legacy agent every cron tick.
  #
  # Back-fill the identity markers from the tracked profile tree into
  # the workspace once, at upgrade time. Idempotent (existence-checks),
  # never overwrites operator edits, never invents files when the
  # tracked tree is empty. Runs after the v2 migrate step so the
  # markerless-existing-install fast-path has already written the
  # layout marker — the back-fill resolver's `bridge_layout_workspace_dir`
  # call depends on the marker being valid to return the v2 workspace
  # path. Skipped on dry-run for symmetry with the migrate step.
  #
  # Failure mode: non-fatal. The helper logs a `bridge_warn` line per
  # failed marker and continues to the next; the back-fill JSON
  # summary is captured for the upgrade audit trail. apply-live
  # proceeds regardless — the watchdog will surface any residual
  # `missing_files` row on the next tick, which is the same fallback
  # behavior the operator's manual `cp` workaround was already
  # producing on every upgrade prior to this step.
  #
  # Footgun #11: the helper body lives at
  # lib/upgrade-helpers/isolation-v2-workdir-backfill.sh and is invoked
  # with the file as argv (no heredoc-stdin anywhere on this path).
  WORKDIR_BACKFILL_JSON='{"mode":"isolation-v2-workdir-backfill","status":"skipped","reason":"helper-not-invoked"}'
  set +e
  _wd_backfill_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-wdbf.XXXXXX")"
  # Stderr destination resolution. Preferred destination is the target
  # install's logs/ tree so an operator debugging a back-fill warning
  # can grep the right tree. The parent shell's `BRIDGE_LOG_DIR` is NOT
  # initialized at this point in the upgrade flow (bridge_load_roster —
  # which seeds it — runs in the `bridge_upgrade_with_target_env`
  # child, not the parent), so resolve the path explicitly against
  # `$TARGET_ROOT/logs`.
  #
  # Resilience contract (codex r2 finding): if the target logs/ dir
  # cannot be created/opened (e.g. parent is read-only, disk full, NFS
  # mount stale), the redirect `2>>"$file"` would itself fail BEFORE
  # the bash invocation runs — leaving WORKDIR_BACKFILL_JSON at the
  # skipped-default. Probe writability first via an explicit append
  # attempt; on failure fall back to `/dev/null` so the helper still
  # runs and the JSON envelope still records the actual outcome. The
  # back-fill itself stays non-fatal, but the upgrade must not become
  # "silently degraded" because a log file's parent is unwritable.
  _wd_backfill_stderr="$TARGET_ROOT/logs/upgrade-workdir-backfill.stderr"
  mkdir -p "$TARGET_ROOT/logs" 2>/dev/null
  if ! { : >>"$_wd_backfill_stderr"; } 2>/dev/null; then
    _wd_backfill_stderr="/dev/null"
  fi
  bridge_upgrade_with_target_env "$TARGET_ROOT" \
    "$BRIDGE_BASH_BIN" \
    "$SOURCE_ROOT/lib/upgrade-helpers/isolation-v2-workdir-backfill.sh" \
    "$SOURCE_ROOT" "$TARGET_ROOT" >"$_wd_backfill_tmp" 2>>"$_wd_backfill_stderr" || true
  if [[ -s "$_wd_backfill_tmp" ]]; then
    WORKDIR_BACKFILL_JSON="$(<"$_wd_backfill_tmp")"
  fi
  rm -f -- "$_wd_backfill_tmp"
  set -e
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

# Issue #864 R2: `apply-live` above creates new live `scripts/` subdirs
# via `Path.parent.mkdir(parents=True, exist_ok=True)`, which inherits
# the controller shell's `umask=077` and produces directories at mode
# 0700. Files inside land at mode 0644 (the explicit `target_mode`
# argument). The isolated agent UID (sudo -u agent-bridge-<name>) then
# cannot traverse the new dirs, and step-3 of bridge-run.sh fails with
# `python3: can't open file '.../scripts/python-helpers/sha1-batch.py':
# [Errno 13] Permission denied`. Normalize directory perms to a+rX
# (typical 0755) after the overlay completes. `-type d` keeps file modes
# untouched (the 0644 from apply-live is correct for the script bodies);
# `a+rX` is the idempotent form — uppercase X applies +x only to dirs
# or already-executable files, so the chmod is safe to run repeatedly
# on a clean tree. Skip when --dry-run because no files moved.
#
# PR #953 r3 (refs #4807, codex r2 P2 #2): queue task #4807 introduced
# `lib/cron-helpers/` (13 helpers) and `lib/daemon-helpers/` (7
# helpers). On a fresh upgrade `apply-live` creates these new directory
# subtrees under the same controller umask=077, so the isolated agent
# UID hits `[Errno 13] Permission denied` opening
# `lib/cron-helpers/write-request.py` (cron dispatch) or
# `lib/daemon-helpers/format-epoch-iso.py` (daemon backup). Extend the
# normalize pass to walk every helper subtree under `lib/`. The
# `lib/upgrade-helpers/` carry from v0.13.9 needs the same treatment
# during a controller-umask upgrade, so include it too. Idempotent
# (`a+rX` on already-0755 dirs is a no-op).
for _helper_dir in scripts lib/cron-helpers lib/daemon-helpers lib/upgrade-helpers; do
  if [[ $DRY_RUN -eq 0 && -d "$TARGET_ROOT/$_helper_dir" ]]; then
    find "$TARGET_ROOT/$_helper_dir" -type d -exec chmod a+rX {} + 2>/dev/null || true
  fi
done
unset _helper_dir

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

# Phase 2 (post-v0.14.5-beta16): re-apply the declarative install-tree
# reconciler on every `upgrade --apply` so existing installs (beta9-16)
# converge to the canonical group/mode contract that v2 isolation
# demands. The reconciler is idempotent — a clean tree shows zero
# changes — and protected paths (agent-roster*, handoff.local*,
# secrets) are refused by the per-row protected guard. Non-zero exit
# surfaces as a warning (not bridge_die): the operator can run
# `agent-bridge isolation reconcile --check` manually to inspect drift
# and `--apply` to repair, without blocking the rest of the upgrade
# from completing. Skip on dry-run for symmetry with shared-settings
# rerender.
if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  _iso_reconcile_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-iso-recon.XXXXXX")"
  # Footgun #11: invoke the helper as a standalone script with args via
  # argv (no heredoc-stdin into a subprocess). The helper sources
  # bridge-lib.sh from $TARGET_ROOT so the reconciler module loads
  # against the upgraded install tree.
  bridge_upgrade_with_target_env "$TARGET_ROOT" \
    "$BRIDGE_BASH_BIN" \
    "$SOURCE_ROOT/lib/upgrade-helpers/isolation-v2-reconcile.sh" \
    "$SOURCE_ROOT" "$TARGET_ROOT" >"$_iso_reconcile_tmp" 2>&1
  _iso_reconcile_rc=$?
  set -e
  if [[ $_iso_reconcile_rc -ne 0 ]]; then
    echo "[bridge-upgrade] WARN: install-tree reconciler reported drift or partial apply (rc=$_iso_reconcile_rc)" >&2
    echo "[bridge-upgrade] WARN: run 'agent-bridge isolation reconcile --check' on the target install to inspect, then '--apply' to converge" >&2
    _upgrade_partial_failures+=("iso_reconcile")
    # Tail the reconciler output into the upgrade log for the audit
    # trail. Cap at 50 lines so a noisy run doesn't flood stderr.
    tail -n 50 "$_iso_reconcile_tmp" >&2 || true
  fi
  rm -f -- "$_iso_reconcile_tmp"

  # L1 beta19 (codex r1 design 2026-05-25): in-place upgrade is the
  # beta19 acceptance path. patch may not rerun `agb setup teams`, so
  # the bun-traverse helper has to fire here too — otherwise an upgrade
  # from beta18 to beta19 leaves $HOME/.bun at the operator's umask
  # (0750 on Debian/Ubuntu) and isolated Teams MCP startup hits EACCES
  # on exec even though every install-tree row above converged.
  #
  # Best-effort, non-fatal: the bun-traverse helper emits bridge_warn on
  # chmod failures but returns non-zero. Wrap in set +e so the upgrade
  # does not abort. Linux + $HOME/.bun gating is internal to the helper
  # (no-op elsewhere).
  #
  # Footgun #11: invoke via standalone helper in lib/upgrade-helpers/
  # rather than -c with embedded script. Keeps the pattern symmetrical
  # with isolation-v2-reconcile.sh and avoids any future heredoc-stdin
  # temptation in this file.
  set +e
  _bun_traverse_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-bun-traverse.XXXXXX")"
  bridge_upgrade_with_target_env "$TARGET_ROOT" \
    "$BRIDGE_BASH_BIN" \
    "$SOURCE_ROOT/lib/upgrade-helpers/bun-traverse-chmod.sh" \
    "$SOURCE_ROOT" "$TARGET_ROOT" >"$_bun_traverse_tmp" 2>&1
  _bun_traverse_rc=$?
  set -e
  if [[ $_bun_traverse_rc -ne 0 ]]; then
    echo "[bridge-upgrade] WARN: bun-runtime traverse chmod reported failure (rc=$_bun_traverse_rc) — isolated agents may fail to exec bun. Run 'chmod o+x \$HOME/.bun \$HOME/.bun/bin' manually or set BRIDGE_BUN_CHMOD_OPT_OUT=1 to suppress." >&2
    _upgrade_partial_failures+=("bun_traverse")
    tail -n 20 "$_bun_traverse_tmp" >&2 || true
  fi
  rm -f -- "$_bun_traverse_tmp"

  # L1-J (beta20, 2026-05-25): every bundled plugin with a package.json
  # needs node_modules at install/upgrade time. The teams plugin path
  # (`agb setup teams`) does this for plugins/teams/ specifically; this
  # helper generalizes to ms365 + any future bundled plugin so the iso
  # UID's MCP spawn does not hit "Cannot find module" on first start.
  #
  # Best-effort, non-fatal — mirrors the bun-traverse helper. The
  # helper logs per-plugin status and the overall upgrade continues
  # even when one plugin's install fails (operator can re-run
  # `agb setup <plugin> <agent>` or fix bun availability and retry).
  #
  # Footgun #11: file-as-argv via standalone helper (no heredoc-stdin).
  set +e
  _bundled_plugins_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-upg-bundled-plugins.XXXXXX")"
  bridge_upgrade_with_target_env "$TARGET_ROOT" \
    "$BRIDGE_BASH_BIN" \
    "$SOURCE_ROOT/lib/upgrade-helpers/bundled-plugins-bun-install.sh" \
    "$SOURCE_ROOT" "$TARGET_ROOT" >"$_bundled_plugins_tmp" 2>&1
  _bundled_plugins_rc=$?
  set -e
  # Surface info lines (per-plugin status) regardless of rc — the
  # operator wants to see "ms365: node_modules installed + widened"
  # in the upgrade log.
  if [[ -s "$_bundled_plugins_tmp" ]]; then
    tail -n 50 "$_bundled_plugins_tmp" >&2 || true
  fi
  if [[ $_bundled_plugins_rc -ne 0 ]]; then
    echo "[bridge-upgrade] WARN: one or more bundled plugins failed bun install (rc=$_bundled_plugins_rc). Affected MCPs will not start until deps resolve — re-run \`agb setup <plugin> <agent>\` or check bun availability." >&2
    _upgrade_partial_failures+=("bundled_plugins_bun_install")
  fi
  rm -f -- "$_bundled_plugins_tmp"
fi

# Footgun #11: `bridge_upgrade_agent_restart_json` feeds python via heredoc;
# `$()` capture would deadlock under Bash 5.3.9 once a real report ships
# enough output to fill the pipe (the leap path traverses this twice).
bridge_upgrade_capture_to_var AGENT_RESTART_JSON \
  bridge_upgrade_agent_restart_json "" 0 "$DRY_RUN"

if [[ $DRY_RUN -eq 0 ]]; then
  set +e
  SHARED_SETTINGS_RERENDER_JSON="$(bridge_upgrade_propagate_claude_shared_settings "$TARGET_ROOT")"
  _shared_settings_rerender_rc=$?
  set -e
  if [[ $_shared_settings_rerender_rc -ne 0 ]]; then
    echo "[bridge-upgrade] WARN: shared Claude settings rerender reported failures" >&2
    _upgrade_partial_failures+=("shared_rerender")
  fi
  # Linux ARG_MAX: SHARED_SETTINGS_RERENDER_JSON grows with agent count;
  # spool to tempfile instead of argv.
  _shared_rerender_verify_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-shared-rerender-verify-json.XXXXXX")"
  printf '%s' "$SHARED_SETTINGS_RERENDER_JSON" >"$_shared_rerender_verify_dir/payload.json"
  if ! python3 - "$_shared_rerender_verify_dir/payload.json" <<'PY'
import json
import sys
# Issue #731: empty/non-JSON payload happens when an isolated agent's
# canonical_dir lookup fails (controller can't traverse mode-2750 workdir)
# and the rerender helper hands back nothing for that agent. Treat it as
# a non-fatal skip with a named diagnostic instead of dumping a raw
# JSONDecodeError traceback into the upgrade log.
with open(sys.argv[1], encoding="utf-8") as fh:
    raw = fh.read().strip()
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
  rm -rf "$_shared_rerender_verify_dir"
fi

# Issue #1067 S08: propagate Codex hooks to every codex-engine agent.
# Runs after Claude shared-settings rerender so the two hook-surface
# propagations stay in the same upgrade phase. Non-fatal: a missing
# codex agent home or hooks.py error produces a WARN but does not abort
# the upgrade (same posture as bridge_upgrade_propagate_claude_hooks).
if [[ $DRY_RUN -eq 0 ]]; then
  bridge_upgrade_propagate_codex_hooks "$TARGET_ROOT" 2>/dev/null || true
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
    # Linux ARG_MAX: spool preview payload to tempfile.
    _relay_cleanup_preview_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-relay-cleanup-preview-json.XXXXXX")"
    printf '%s' "$RELAY_CLEANUP_PREVIEW_JSON" >"$_relay_cleanup_preview_dir/payload.json"
    if python3 - "$_relay_cleanup_preview_dir/payload.json" <<'PY' >/dev/null 2>&1
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
raise SystemExit(0 if payload.get("any_changes") else 1)
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
        # Issue #989: bridge-relay-cleanup.py rewrote BRIDGE_AGENT_CHANNELS
        # / BRIDGE_AGENT_LAUNCH_CMD in agent-roster.local.sh (dropping the
        # legacy telegram-relay channel + dev-channel loader). For a
        # linux-user isolated agent the cached runtime/agent-env.sh now
        # carries a stale launch cmd — and isolation-v2-migrate already
        # ran earlier in this upgrade, so nothing downstream regenerates
        # it. Refresh every isolated agent's cache via the shared helper
        # so the next start does not bind a pre-v2 channel state path
        # (#771-class silent inbound delivery failure). NO-OP for
        # non-isolated agents; tolerant on failure so cleanup success is
        # not downgraded by a per-agent regen hiccup.
        bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" -lc '
          set -euo pipefail
          source "$1/bridge-lib.sh"
          bridge_load_roster
          for agent in "${BRIDGE_AGENT_IDS[@]}"; do
            command -v bridge_refresh_isolated_agent_env_after_channel_mutation \
              >/dev/null 2>&1 || continue
            bridge_refresh_isolated_agent_env_after_channel_mutation "$agent" \
              >/dev/null 2>&1 || true
          done
        ' -- "$SOURCE_ROOT" >/dev/null 2>&1 || true
      fi
    fi
    rm -rf "$_relay_cleanup_preview_dir"
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

  # Issue #4769 (reverts #517): no auto-backfill of `<admin>-dev` codex pair
  # on upgrade. The post-upgrade advisory below points operators of hosts
  # where the removed feature already auto-created admin/admin-dev to the
  # explicit setup/retire recipe — but no destructive action runs here.

  bridge_upgrade_emit_admin_pair_advisory "$TARGET_ROOT" "$ADMIN_AGENT_ID" "$DRY_RUN"

  # #8945 Track D: record codex --version + surface a non-fatal advisory on
  # a major/minor change. No-op when codex is absent (non-fatal precedent).
  bridge_upgrade_emit_codex_version_advisory "$TARGET_ROOT" "$DRY_RUN"

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

  # Issue #1328 (v0.15.0-beta5-2 Lane μ M5): verify the cron-state-dir
  # anchor and migrate the old tree if `BRIDGE_CRON_STATE_DIR` moved.
  # Idempotent — when the anchor matches the live env, the helper is a
  # no-op. The full edge-case matrix lives in
  # `bridge_cron_state_dir_verify_and_migrate`'s docstring (lib/bridge-cron.sh).
  # Run at upgrade time so the operator never observes a stale cron tree
  # after a `BRIDGE_CRON_STATE_DIR` override change; the daemon's `sync`
  # tick also calls the same helper for the steady-state path.
  if [[ $DRY_RUN -eq 1 ]]; then
    echo "[bridge-upgrade] plan: verify cron-state-dir anchor (idempotent; migrates stale tree if BRIDGE_CRON_STATE_DIR moved)" >&2
  else
    _cron_state_dir_verify_output=""
    if ! _cron_state_dir_verify_output="$(
      bridge_upgrade_with_target_env "$TARGET_ROOT" "$BRIDGE_BASH_BIN" -lc '
        set -euo pipefail
        SCRIPT_DIR="$1"
        source "$SCRIPT_DIR/bridge-lib.sh"
        # bridge-lib.sh sources lib/bridge-cron.sh transitively; the
        # verify helper lives in lib/bridge-cron.sh.
        bridge_cron_state_dir_verify_and_migrate
      ' -- "$SOURCE_ROOT" 2>&1
    )"; then
      echo "[bridge-upgrade] WARN: cron-state-dir verify failed: $_cron_state_dir_verify_output" >&2
      _upgrade_partial_failures+=("cron_state_dir_verify")
    elif [[ -n "$_cron_state_dir_verify_output" ]]; then
      # Helper emits human-readable bridge_warn lines on migrate/conflict;
      # surface them to the upgrade summary so the operator sees them
      # without grepping the audit log.
      printf '%s\n' "$_cron_state_dir_verify_output" >&2
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
  # Linux ARG_MAX: RELINK_PROFILE_JSON grows with per-agent symlink lists;
  # spool to tempfile instead of argv.
  _relink_profile_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-relink-profile-json.XXXXXX")"
  printf '%s' "$RELINK_PROFILE_JSON" >"$_relink_profile_dir/payload.json"
  python3 - "$_relink_profile_dir/payload.json" <<'PY' || true
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    raw = fh.read().strip()
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
  rm -rf "$_relink_profile_dir"
fi

if [[ $RESTART_DAEMON -eq 1 && $DRY_RUN -eq 0 ]]; then
  # --force: the upgrader is the sanctioned daemon stop+restart path
  # (issue #314 Layer 3 / #315 Track 3). Bypass the active-agent guard.
  bash "$TARGET_ROOT/bridge-daemon.sh" stop --force >/dev/null 2>&1 || true
  bash "$TARGET_ROOT/bridge-daemon.sh" ensure >/dev/null
fi

# Patch #4798 — tmux server-env cleanup. Pre-PR-#926 installs leaked
# BRIDGE_LAYOUT / BRIDGE_DATA_ROOT into the tmux server's global env
# via inheritance from the original `agent-bridge` invocation that
# started the server. Once leaked, every new pane inherits the stale
# value and the layout resolver fires its "stale pre-v0.8.0 env
# override" warning on every CLI command. PR #926 stopped the export
# prefix from re-forwarding the vars but did NOT clean the existing
# tmux server-level entries.  `tmux setenv -u -g` is idempotent — when
# the server has no entry the call is a no-op. Suppress all output so
# operators without a running tmux server don't see error noise.
if [[ $DRY_RUN -eq 0 ]] && command -v tmux >/dev/null 2>&1; then
  tmux setenv -u -g BRIDGE_LAYOUT 2>/dev/null || true
  tmux setenv -u -g BRIDGE_DATA_ROOT 2>/dev/null || true
fi


# Beta20 L2 Variant 3A — regenerate the daemon-refresh sudoers drop-in
# so an upgrade that changes BRIDGE_BASH_BIN or BRIDGE_HOME (rare but
# possible when operators relocate) lands a matching authorized command
# in the sudoers entry. Idempotent: the helper skips the install when
# the existing file is byte-equal to a fresh render. Linux + server
# profile only; failure is logged but does NOT abort the upgrade (the
# operator can re-run `agent-bridge init sudoers daemon-refresh --apply`
# afterwards).
if [[ $DRY_RUN -eq 0 ]] \
   && [[ "$(uname -s 2>/dev/null)" == "Linux" ]] \
   && ! bridge_host_profile_is_dev \
   && command -v bridge_daemon_control_install_sudoers >/dev/null 2>&1; then
  _upgrade_sudoers_path=""
  _upgrade_sudoers_install_ok=0
  if _upgrade_sudoers_path="$(BRIDGE_HOME="$TARGET_ROOT" bridge_daemon_control_install_sudoers 2>&1)"; then
    if [[ -n "$_upgrade_sudoers_path" ]]; then
      # >&2 — info goes to stderr so --json mode's stdout stays parseable
      echo "[bridge-upgrade] daemon-refresh sudoers: at $_upgrade_sudoers_path" >&2
      _upgrade_sudoers_install_ok=1
    fi
  else
    echo "[bridge-upgrade] WARN: daemon-refresh sudoers regen failed; automatic supp-groups refresh may fall back to manual-required." >&2
    echo "[bridge-upgrade] WARN: re-run: $TARGET_ROOT/agent-bridge init sudoers daemon-refresh --apply" >&2
  fi

  # Beta20 L2 Variant 3A r4 — regenerate the systemd-user unit so its
  # ExecStart picks up the (possibly updated) sudo-wrapped shape. The
  # install-daemon-systemd.sh helper auto-detects the sudoers drop-in
  # and renders accordingly; we just re-apply + daemon-reload +
  # restart-if-active. Without this step, an operator who upgrades
  # from a pre-r4 install still has the legacy direct unit ExecStart,
  # and `Restart=always` would keep defeating the r3 ad-hoc sudo
  # restart at runtime.
  if (( _upgrade_sudoers_install_ok == 1 )) \
     && command -v systemctl >/dev/null 2>&1; then
    _upgrade_systemd_rc=0
    # install-daemon-systemd.sh emits [info] lines to stdout (designed
    # for standalone CLI use). When invoked from inside `agent-bridge
    # upgrade --json`, that chatter must not pollute the JSON envelope
    # on our stdout. Redirect to stderr so --json callers (smokes, CI)
    # get a clean JSON document; operator-facing terminal still sees
    # the messages.
    "$BRIDGE_BASH_BIN" "$TARGET_ROOT/scripts/install-daemon-systemd.sh" \
      --bridge-home "$TARGET_ROOT" --apply >&2 \
      || _upgrade_systemd_rc=$?
    if (( _upgrade_systemd_rc == 0 )); then
      if systemctl --user is-active --quiet agent-bridge-daemon.service 2>/dev/null; then
        systemctl --user daemon-reload || true
        if systemctl --user restart agent-bridge-daemon.service 2>/dev/null; then
          echo "[bridge-upgrade] systemd-user unit regenerated (sudo-self) and restarted" >&2
        else
          echo "[bridge-upgrade] WARN: systemctl --user restart agent-bridge-daemon.service failed after unit regen — retry manually" >&2
        fi
      else
        echo "[bridge-upgrade] systemd-user unit regenerated (sudo-self) — service not active, will pick up on next start" >&2
      fi
    else
      echo "[bridge-upgrade] WARN: install-daemon-systemd.sh --apply returned rc=$_upgrade_systemd_rc — unit may carry legacy ExecStart" >&2
      echo "[bridge-upgrade] WARN: re-run: $TARGET_ROOT/scripts/install-daemon-systemd.sh --bridge-home $TARGET_ROOT --apply" >&2
    fi
  fi
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
    _post_body="$(mktemp "${TMPDIR:-/tmp}/bridge-upgrade-post.XXXXXX")"
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
    # Issue #980: when --restart-agents was requested but one or more
    # static agents were skipped because the operator's own tmux session
    # was attached, those agents are still running the OLD code. Append an
    # explicit manual-restart notice to the post-upgrade task body so the
    # admin sees it without having to re-derive it from the restart
    # summary, and queue a dedicated [restart-required] task below so it
    # is not forgotten. A dry-run-style collection (dry_run=1) is used:
    # it reads roster + tmux state to compute reason="attached" without
    # ever invoking `bridge-agent.sh restart`, so it is side-effect free.
    _attached_skipped_agents=""
    if [[ $RESTART_AGENTS -eq 1 ]]; then
      _attached_skip_report="$(bridge_upgrade_collect_agent_restart_report "$TARGET_ROOT" 1 2>/dev/null || true)"
      _attached_skipped_agents="$(bridge_upgrade_attached_skipped_agents "$_attached_skip_report" || true)"
    fi
    if [[ -n "$_attached_skipped_agents" ]]; then
      # Footgun #11 (refs #265 / #800 / #815): stream the agent list
      # through a pipe into `while read`, never a here-string, to keep
      # Bash 5.3.9 out of the `read_comsub` wedge on the apply leap path.
      _attached_restart_cmd="agent-bridge agent restart $(printf '%s' "$_attached_skipped_agents" | tr '\n' ' ' | sed 's/ *$//')"
      {
        printf '\n## Agents needing a manual restart (issue #980)\n\n'
        printf '%s\n\n' '`--restart-agents` skipped the agent(s) below because your live tmux session was attached. They are still running the OLD code from before this upgrade:'
        printf '%s\n' "$_attached_skipped_agents" | while IFS= read -r _att_agent; do
          [[ -n "$_att_agent" ]] || continue
          printf -- '- `%s` (skipped: active tmux session attached)\n' "$_att_agent"
        done
        printf '\nWhen ready, restart them with:\n\n'
        printf '```\n%s\n```\n' "$_attached_restart_cmd"
      } >>"$_post_body"
    fi
    # Persist the task body in state/ so the recovery command the
    # WARN block prints is actually rerunnable. Tempfiles vanish on
    # exit and leave the operator with guidance instead of a command
    # that would copy-paste into "no such file".
    #
    # Issue #1144: keep the persistent copy on disk even on successful
    # task creation. `bridge-queue.py` stores the body_file path in the
    # task row's `body_path` column verbatim (paths under bridge-managed
    # roots are NOT relocated to state/queue/bodies/ by stabilize_body_file).
    # The admin runbook and `agb show <id>` both surface `body_file:` for
    # the consumer to open — deleting the file post-create regresses that
    # path to ENOENT (the issue #1144 symptom).
    _post_body_persist_dir="$TARGET_ROOT/state/bridge-upgrade/post-task"
    mkdir -p "$_post_body_persist_dir"
    _post_body_persist="$_post_body_persist_dir/upgrade-complete-$(date -u +%Y%m%dT%H%M%SZ).md"
    cp "$_post_body" "$_post_body_persist"
    _post_task_log="$(mktemp "${TMPDIR:-/tmp}/bridge-upgrade-post-task.log.XXXXXX")"
    if bridge_upgrade_with_target_env "$TARGET_ROOT" "$TARGET_ROOT/agent-bridge" task create \
        --to "$_post_admin" --priority normal --from "$_post_admin" \
        --title "[upgrade-complete] Agent Bridge $SOURCE_VERSION — run bootstrap" \
        --body-file "$_post_body_persist" >"$_post_task_log" 2>&1; then
      # Task created successfully — the persistent body file remains on
      # disk so the task row's body_path reference is openable by the
      # admin runbook and by `agb show <id>` consumers. The queue row
      # additionally carries an inline copy of the body text for fast
      # access, but the file-on-disk contract is what the post-upgrade
      # body_file path advertises (issue #1144).
      :
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

    # Issue #980: file a dedicated [restart-required] task per
    # attached-skipped agent so the manual restart is not lost in the
    # body of the larger [upgrade-complete] task. The title carries the
    # agent ID + target version so a genuinely new upgrade gets its own
    # distinct task.
    #
    # Dedupe (PR #996 r2): the queue layer does NOT dedupe — every
    # `task create` unconditionally INSERTs a row — so an operator who
    # re-runs `upgrade --restart-agents` while staying attached (common:
    # they are attached *because* they are working) would otherwise get
    # the admin inbox spammed with duplicate [restart-required] tasks.
    # Before creating, probe the target install's queue for an already-
    # open task with the exact same title (`find-open --title-prefix`
    # over queued|claimed|blocked rows — the same primitive
    # bridge-task.sh uses for [task-blocked] idempotency) and skip the
    # create when one is present. Exact-title match is sufficient: the
    # title pins both agent id and target version.
    #
    # Failure to file is non-fatal — the notice is already in the
    # [upgrade-complete] body and the upgrade summary — so a WARN on
    # stderr is sufficient.
    if [[ -n "$_attached_skipped_agents" ]]; then
      printf '%s\n' "$_attached_skipped_agents" | while IFS= read -r _rr_agent; do
        [[ -n "$_rr_agent" ]] || continue
        _rr_title="[restart-required] $_rr_agent — upgrade to $SOURCE_VERSION"
        # Skip when an open [restart-required] task for this agent+version
        # already exists in the target queue. `find-open` exits 0 and
        # prints the id on a match, exits non-zero with no output when
        # none is open; the `|| true` keeps `set -e` from aborting on the
        # no-match exit.
        _rr_existing="$(bridge_upgrade_with_target_env "$TARGET_ROOT" \
          python3 "$TARGET_ROOT/bridge-queue.py" find-open \
          --agent "$_post_admin" --title-prefix "$_rr_title" --format id \
          2>/dev/null || true)"
        if [[ -n "$_rr_existing" ]]; then
          echo "[bridge-upgrade] restart-required task already queued for $_rr_agent (task #$_rr_existing) — not re-filing"
          continue
        fi
        _rr_body="$(mktemp "${TMPDIR:-/tmp}/bridge-upgrade-restart-req.XXXXXX")"
        {
          printf '# Manual agent restart required\n\n'
          printf -- '- agent: `%s`\n' "$_rr_agent"
          printf -- '- to_version: %s\n' "$SOURCE_VERSION"
          printf -- '- reason: `--restart-agents` skipped this agent during the upgrade because its tmux session was attached (the operator was using it). It is still running the OLD code.\n\n'
          printf 'When ready, restart it with:\n\n'
          printf '```\nagent-bridge agent restart %s\n```\n\n' "$_rr_agent"
          printf 'Close this task once the agent has been restarted.\n'
        } >"$_rr_body"
        if ! bridge_upgrade_with_target_env "$TARGET_ROOT" "$TARGET_ROOT/agent-bridge" task create \
            --to "$_post_admin" --priority normal --from "$_post_admin" \
            --title "$_rr_title" \
            --body-file "$_rr_body" >/dev/null 2>&1; then
          echo "[bridge-upgrade] WARN: could not file [restart-required] task for agent=$_rr_agent (notice still present in [upgrade-complete] body and upgrade summary)" >&2
        fi
        rm -f "$_rr_body"
      done
    fi
  fi
fi

if [[ $RESTART_AGENTS -eq 1 ]]; then
  AGENT_RESTART_REPORT="$(bridge_upgrade_collect_agent_restart_report "$TARGET_ROOT" "$DRY_RUN")"
  # Issue 4 (v0.11.0): reconcile failed rows against the daemon's
  # subsequent launch cycle so the upgrade summary does not over-report
  # failures the daemon already absorbed. No-op when dry-run or when no
  # `failed` rows are present.
  AGENT_RESTART_REPORT="$(bridge_upgrade_reconcile_agent_restart_recovery "$TARGET_ROOT" "$AGENT_RESTART_REPORT" "$DRY_RUN")"
  # Footgun #11: `agent_restart_json` heredoc + populated report = wedge
  # candidate under Bash 5.3.9. Stage via tempfile.
  bridge_upgrade_capture_to_var AGENT_RESTART_JSON \
    bridge_upgrade_agent_restart_json "$AGENT_RESTART_REPORT" 1 "$DRY_RUN"

  # Issue #978 (closes #978, refs #879): post-restart agents — especially
  # codex-engine agents — frequently land on an interactive picker that
  # the controller-side auto-accept watcher does not arm for. The picker-
  # sweep cron (`*/10 * * * *`) eventually unsticks them, but that leaves
  # an operator-visible 10-minute window where the codex pane sits at
  # "Press enter to continue" and inbox/queue progress stalls.
  #
  # Run picker-sweep one-shot synchronously now so codex pickers (and any
  # Claude pickers the cold-start watcher missed) are cleared before the
  # upgrade returns. This is the reactive primitive that already handles
  # BOTH engines (see scripts/picker-sweep.sh's _PICKER_CODEX_CONFIRM_RE
  # added 2026-05-16); we just invoke it earlier than the next cron tick.
  #
  # Skip when dry-run (no actual restart happened), when no agent reached
  # status="restarted" (avoids running against an all-attached install),
  # and when no admin agent is configured (the cron payload uses the
  # admin for SELF/NOTIFY; same contract here).
  if [[ $DRY_RUN -ne 1 ]] \
      && printf '%s\n' "$AGENT_RESTART_REPORT" | grep -qE $'\t''restarted'$'\t' \
      && [[ -n "${ADMIN_AGENT_ID:-}" ]]; then
    if [[ -x "$TARGET_ROOT/scripts/picker-sweep.sh" || -r "$TARGET_ROOT/scripts/picker-sweep.sh" ]]; then
      _picker_sweep_post_restart_output=""
      # Run picker-sweep under bridge_upgrade_with_target_env so the
      # sweep's children (bridge-task, bridge-auth, bridge-queue) see a
      # clean target-rooted env and never inherit the caller's source-
      # checkout BRIDGE_* paths or any agent-scoped BRIDGE_AGENT_ID /
      # BRIDGE_ACTIVE_AGENT_DIR. Without this wrap, picker-sweep's
      # task-create notification could write to the wrong BRIDGE_TASK_DB
      # or under the wrong agent scope.
      #
      # bridge_with_timeout can't be invoked directly from a target-env
      # subprocess we exec'd with `env -i` (it's a shell function defined
      # in bridge-lib.sh, not a binary). Source bridge-lib.sh inside the
      # target-env bash -c body and call bridge_with_timeout from there
      # — that preserves both target-env isolation AND bridge_with_timeout's
      # portable Tier 2 (python3 subprocess.run) fallback for hosts
      # without GNU timeout/gtimeout (notably bare macOS). The `*/10`
      # picker-sweep cron remains as the hard backstop.
      if _picker_sweep_post_restart_output="$(
        bridge_upgrade_with_target_env "$TARGET_ROOT" \
          "$BRIDGE_BASH_BIN" -c '
            set -u
            target_root="$1"
            admin_id="$2"
            # shellcheck disable=SC1091
            source "$target_root/bridge-lib.sh"
            bridge_with_timeout 15 "upgrade_post_restart_picker_sweep" \
              env BRIDGE_PICKER_SWEEP_ENABLED=1 \
                  BRIDGE_PICKER_SWEEP_SELF="$admin_id" \
                  BRIDGE_PICKER_SWEEP_NOTIFY="$admin_id" \
              bash "$target_root/scripts/picker-sweep.sh"
          ' bridge_upgrade_picker_sweep "$TARGET_ROOT" "$ADMIN_AGENT_ID" 2>&1
      )"; then
        if [[ -n "$_picker_sweep_post_restart_output" ]]; then
          printf '%s\n' "$_picker_sweep_post_restart_output" >&2
        fi
      else
        # Sweep failure (timeout, non-zero exit) is non-fatal — the
        # */10 cron will retry and any stuck pane is still operator-
        # actionable. Surface the failure to stderr without aborting.
        echo "[bridge-upgrade] WARN: post-restart picker-sweep failed (non-fatal — cron will retry): $_picker_sweep_post_restart_output" >&2
      fi
    fi
  fi
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
  # Issue #1113: surface the workdir-identity back-fill payload in --json
  # output so operators / monitoring can read `agents_with_writes` and
  # `markers_copied` programmatically. Empty string when the back-fill
  # never ran (dry-run paths) — load_optional_json then yields null and
  # the consumer branches accordingly.
  printf '%s' "${WORKDIR_BACKFILL_JSON:-}" >"$_json_payload_dir/workdir-backfill.json"
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
  python3 - "$SOURCE_ROOT" "$TARGET_ROOT" "$PULL" "$DRY_RUN" "$RESTART_DAEMON" "$RESTART_AGENTS" "$BACKUP" "$MIGRATE_AGENTS" "$BACKUP_ROOT" "$STRICT_MERGE" "$CHANNEL" "$SOURCE_VERSION" "$SOURCE_REF" "$SOURCE_HEAD" "$TARGET_REF" "$TARGET_VERSION" "$TARGET_HEAD" "$_json_payload_dir/backup.json" "$_json_payload_dir/migration.json" "$_json_payload_dir/apply.json" "$_json_payload_dir/analysis.json" "$_json_payload_dir/agent-restart.json" "$_json_payload_dir/channel-guard.json" "$_json_payload_dir/source-reclassify.json" "$_json_payload_dir/shared-settings-rerender.json" "$_json_payload_dir/cleanup.json" "$_json_payload_dir/isolation-v2-migration.json" "$_json_payload_dir/workdir-backfill.json" "$_json_payload_dir/partial-failures.json" <<'PY'
import json, sys
source_root, target_root, pull, dry_run, restart_daemon, restart_agents, backup_enabled, migrate_agents, backup_root, strict_merge, channel, source_version, source_ref, source_head, target_ref, target_version, target_head, backup_json_file, migration_json_file, apply_json_file, analysis_json_file, agent_restart_json_file, channel_guard_json_file, source_reclassify_json_file, shared_settings_rerender_json_file, cleanup_json_file, isolation_v2_migration_json_file, workdir_backfill_json_file, partial_failures_json_file = sys.argv[1:]

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
# Issue #1113: post-marker back-fill of canonical identity markers from
# the tracked profile tree into the v2 runtime workspace for legacy /
# marker-only-migrated agents. Null when the back-fill step did not run
# (dry-run, helper not invoked). Populated as `agents_with_writes`,
# `markers_copied` so JSON consumers can audit the post-upgrade state.
workdir_backfill_payload = load_optional_json(workdir_backfill_json_file)
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
    "workdir_backfill": workdir_backfill_payload,
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
# Linux ARG_MAX overflow: large JSON payloads (BACKUP/ANALYSIS/SOURCE_RECLASSIFY)
# must not be passed as argv — Oracle 9 / Ubuntu hit `python3: Argument list too
# long` (E2BIG) on big upgrade manifests, silently dropping status visibility
# even when the upgrade itself succeeds. Spool each payload to a tempfile and
# pass the filename instead, mirroring the --json envelope pattern at line
# ~2156. Filename-via-argv is the only option that works here: heredoc-stdin
# (`python3 <<PY ... PY`) is forbidden (footgun #11, Bash 5.3.9 deadlock) and
# `printf '%s' "$JSON" | python3 - <<'PY'` trips SC2259 because the heredoc
# overrides the piped stdin.
_status_print_dir="$(mktemp -d "${TMPDIR:-/tmp}/bridge-upgrade-status-json.XXXXXX")"
printf '%s' "$ANALYSIS_JSON" >"$_status_print_dir/analysis.json"
printf '%s' "$SOURCE_RECLASSIFY_JSON" >"$_status_print_dir/source-reclassify.json"
printf '%s' "$SHARED_SETTINGS_RERENDER_JSON" >"$_status_print_dir/shared-settings-rerender.json"
printf '%s' "$APPLY_JSON" >"$_status_print_dir/apply.json"
printf '%s' "$RECONCILE_JSON" >"$_status_print_dir/reconcile.json"
if [[ $BACKUP -eq 1 ]]; then
  echo "backup_root: $BACKUP_ROOT"
  printf '%s' "$BACKUP_JSON" >"$_status_print_dir/backup.json"
  python3 - "$_status_print_dir/backup.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
print(f"backup_created: {'yes' if payload.get('created') else 'no'}")
PY
fi
python3 - "$_status_print_dir/analysis.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
counts = payload.get("counts", {})
print(f"analysis_base_ref: {payload.get('base_ref') or '-'}")
print(f"analysis_missing_live: {counts.get('missing_live', 0)}")
print(f"analysis_upstream_only: {counts.get('upstream_only', 0)}")
print(f"analysis_live_only: {counts.get('live_only', 0)}")
print(f"analysis_merge_required: {counts.get('merge_required', 0)}")
print(f"analysis_unknown_base_live_diff: {counts.get('unknown_base_live_diff', 0)}")
PY
bridge_upgrade_print_channel_guard_summary "$CHANNEL_GUARD_JSON"
python3 - "$_status_print_dir/source-reclassify.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
count = int(payload.get("count") or 0)
mode = payload.get("mode") or "dry-run"
print(f"source_reclassify: {count} candidate(s) ({mode})")
for item in payload.get("candidates") or []:
    print(f"  - {item.get('action')}: {item.get('agent')} old_source={item.get('old_source')} new_source={item.get('new_source')} reason={item.get('reason')}")
PY
python3 - "$_status_print_dir/shared-settings-rerender.json" <<'PY'
import json, sys
# Issue #731: same defensive guard as the verification heredoc above —
# empty/non-JSON SHARED_SETTINGS_RERENDER_JSON should not raise a raw
# traceback in the post-upgrade summary, just emit a named WARN.
with open(sys.argv[1], encoding="utf-8") as fh:
    raw = fh.read().strip()
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
python3 - "$_status_print_dir/apply.json" "$_status_print_dir/reconcile.json" "$UPGRADE_RUN_ID" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
with open(sys.argv[2], encoding="utf-8") as fh:
    reconcile = json.load(fh)
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
  printf '%s' "$MIGRATION_JSON" >"$_status_print_dir/migration.json"
  python3 - "$_status_print_dir/migration.json" <<'PY'
import json, sys
with open(sys.argv[1], encoding="utf-8") as fh:
    payload = json.load(fh)
print(f"agents_migrated: {payload.get('agents_with_additions', 0)}")
print(f"migrated_files: {payload.get('added_files', 0)}")
PY
fi
rm -rf "$_status_print_dir"
bridge_upgrade_print_agent_restart_summary "$AGENT_RESTART_JSON"
