#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034

# Resolve the re-exec target before any guard logic, since $0 is unreliable
# under macOS /bin/bash invocations like `bash -lc '...' _ args` (where $0
# is the placeholder `_`). Prefer the caller script that sourced us
# (BASH_SOURCE[1] — e.g. bridge-daemon.sh / agent-bridge), fall back to
# bridge-lib.sh itself if invoked directly. (#576 r4 Finding 3)
_BRIDGE_LIB_REEXEC_TARGET="${BASH_SOURCE[1]:-${BASH_SOURCE[0]}}"

if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  # Re-exec into a Bash 4+ candidate, but ONLY when the resolved target
  # names a regular file we can hand back to the new shell. If the target
  # cannot be resolved (e.g. sourced from `bash -c` with no caller script),
  # fall through to the "requires Bash 4+" message rather than handing the
  # candidate shell a path it cannot open.
  if [[ -f "$_BRIDGE_LIB_REEXEC_TARGET" ]]; then
    for bridge_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "$(command -v bash 2>/dev/null || true)"; do
      [[ -n "$bridge_candidate_bash" && -x "$bridge_candidate_bash" ]] || continue
      if "$bridge_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$bridge_candidate_bash" "$_BRIDGE_LIB_REEXEC_TARGET" "$@"
      fi
    done
  fi

  echo "[bridge-lib] Agent Bridge requires Bash 4+ (current: ${BASH_VERSION:-unknown}). Re-run with a Bash 4+ shell on PATH (e.g. \`/opt/homebrew/bin/bash <script>\`)." >&2
  exit 1
fi

# Keep bridge-owned runtime files private by default.
umask 077

BRIDGE_SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"

bridge_early_ephemeral_tmp_root() {
  local path="${1:-}"
  local tmpdir="${TMPDIR:-}"
  local rest=""
  [[ -n "$path" ]] || return 1
  case "$path" in
    /tmp/tmp.*|/tmp/tmp.*/*)
      rest="${path#/tmp/}"
      printf '/tmp/%s' "${rest%%/*}"
      ;;
    /var/tmp/tmp.*|/var/tmp/tmp.*/*)
      rest="${path#/var/tmp/}"
      printf '/var/tmp/%s' "${rest%%/*}"
      ;;
    /private/tmp/tmp.*|/private/tmp/tmp.*/*)
      rest="${path#/private/tmp/}"
      printf '/private/tmp/%s' "${rest%%/*}"
      ;;
    *)
      if [[ -n "$tmpdir" ]]; then
        tmpdir="${tmpdir%/}"
        case "$path" in
          "$tmpdir"/tmp.*|"$tmpdir"/tmp.*/*)
            rest="${path#"$tmpdir"/}"
            printf '%s/%s' "$tmpdir" "${rest%%/*}"
            ;;
          *)
            return 1
            ;;
        esac
      else
        return 1
      fi
      ;;
  esac
}

bridge_sanitize_stale_ephemeral_controller_env() {
  local name=""
  local value=""
  local root=""
  local -a path_vars=(
    BRIDGE_HOME
    BRIDGE_ROSTER_FILE
    BRIDGE_ROSTER_LOCAL_FILE
    BRIDGE_STATE_DIR
    BRIDGE_LAYOUT_MARKER_DIR
    BRIDGE_ACTIVE_AGENT_DIR
    BRIDGE_HISTORY_DIR
    BRIDGE_WORKTREE_META_DIR
    BRIDGE_ACTIVE_ROSTER_TSV
    BRIDGE_ACTIVE_ROSTER_MD
    BRIDGE_DAEMON_PID_FILE
    BRIDGE_DAEMON_LOG
    BRIDGE_DAEMON_CRASH_LOG
    BRIDGE_TASK_DB
    BRIDGE_PROFILE_STATE_DIR
    BRIDGE_CRON_STATE_DIR
    BRIDGE_CRON_HOME_DIR
    BRIDGE_NATIVE_CRON_JOBS_FILE
    BRIDGE_CRON_DISPATCH_WORKER_DIR
    BRIDGE_WORKTREE_ROOT
    BRIDGE_AGENT_HOME_ROOT
    BRIDGE_RUNTIME_ROOT
    BRIDGE_RUNTIME_SCRIPTS_DIR
    BRIDGE_RUNTIME_SKILLS_DIR
    BRIDGE_RUNTIME_SHARED_DIR
    BRIDGE_RUNTIME_SHARED_TOOLS_DIR
    BRIDGE_RUNTIME_SHARED_REFERENCES_DIR
    BRIDGE_RUNTIME_MEMORY_DIR
    BRIDGE_RUNTIME_CREDENTIALS_DIR
    BRIDGE_RUNTIME_SECRETS_DIR
    BRIDGE_RUNTIME_CONFIG_FILE
    BRIDGE_HOOKS_DIR
    BRIDGE_SHARED_DIR
    BRIDGE_TASK_NOTE_DIR
    BRIDGE_LOG_DIR
    BRIDGE_DATA_ROOT
    BRIDGE_SHARED_ROOT
    BRIDGE_AGENT_ROOT_V2
    BRIDGE_CONTROLLER_STATE_ROOT
    BRIDGE_CLAUDE_CHANNELS_HOME
    BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT
    BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE
  )

  [[ "${BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV:-0}" == "1" ]] && return 0

  for name in "${path_vars[@]}"; do
    value="${!name:-}"
    [[ -n "$value" ]] || continue
    root="$(bridge_early_ephemeral_tmp_root "$value" 2>/dev/null || true)"
    [[ -n "$root" ]] || continue
    [[ -d "$root" ]] && continue
    printf '[bridge-lib] [warn] unsetting stale ephemeral controller env %s=%s (missing root %s)\n' \
      "$name" "$value" "$root" >&2
    unset "$name"
  done
}

bridge_sanitize_stale_ephemeral_controller_env

if [[ -z "${BRIDGE_HOME:-}" ]]; then
  BRIDGE_HOME="$HOME/.agent-bridge"
fi
if [[ -z "${BRIDGE_ROSTER_FILE:-}" ]]; then
  if [[ -f "$BRIDGE_HOME/agent-roster.sh" ]]; then
    BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
  else
    BRIDGE_ROSTER_FILE="$BRIDGE_SCRIPT_DIR/agent-roster.sh"
  fi
fi
BRIDGE_ROSTER_LOCAL_FILE="${BRIDGE_ROSTER_LOCAL_FILE:-$BRIDGE_HOME/agent-roster.local.sh}"
BRIDGE_STATE_DIR="${BRIDGE_STATE_DIR:-$BRIDGE_HOME/state}"
# Layout marker is anchored separately from BRIDGE_STATE_DIR so v2 activation
# never moves marker discovery. Defaults to $BRIDGE_HOME/state and is never
# rebased onto $BRIDGE_DATA_ROOT/state — controller state may relocate in a
# future PR, the marker location must not.
BRIDGE_LAYOUT_MARKER_DIR="${BRIDGE_LAYOUT_MARKER_DIR:-$BRIDGE_HOME/state}"
BRIDGE_ACTIVE_AGENT_DIR="${BRIDGE_ACTIVE_AGENT_DIR:-$BRIDGE_STATE_DIR/agents}"
BRIDGE_HISTORY_DIR="${BRIDGE_HISTORY_DIR:-$BRIDGE_STATE_DIR/history}"
BRIDGE_WORKTREE_META_DIR="${BRIDGE_WORKTREE_META_DIR:-$BRIDGE_STATE_DIR/worktrees}"
BRIDGE_ACTIVE_ROSTER_TSV="${BRIDGE_ACTIVE_ROSTER_TSV:-$BRIDGE_STATE_DIR/active-roster.tsv}"
BRIDGE_ACTIVE_ROSTER_MD="${BRIDGE_ACTIVE_ROSTER_MD:-$BRIDGE_STATE_DIR/active-roster.md}"
BRIDGE_DAEMON_PID_FILE="${BRIDGE_DAEMON_PID_FILE:-$BRIDGE_STATE_DIR/daemon.pid}"
# Issue #590 / PR #599 r2: prefer the installer-written launchagent.config
# marker so custom --label/--plist/--log-path installs resolve correctly.
# The marker's presence is the "launchd-managed" signal — we don't need
# to guess plist filenames or pin to the default label. Linux (systemd/
# nohup) installs simply lack the marker and fall through to daemon.log.
# Operators can still override BRIDGE_DAEMON_LOG via env.
#
# r3 (PR #599): the marker-read is split into __bridge_resolve_launchagent_log
# so bridge-daemon.sh can reuse the same precedence for BRIDGE_LAUNCHAGENT_LOG
# (otherwise the EXIT-trap append at bridge-daemon.sh:147-151 lands in the
# wrong file on custom --log-path installs).
__bridge_resolve_launchagent_log() {
  local config_path="$BRIDGE_STATE_DIR/launchagent.config"
  if [[ ! -f "$config_path" ]]; then
    printf ''
    return
  fi
  (
    set -e
    # shellcheck disable=SC1090
    source "$config_path"
    printf '%s' "${BRIDGE_LAUNCHAGENT_LOG:-}"
  )
}

__bridge_default_daemon_log() {
  local resolved
  resolved="$(__bridge_resolve_launchagent_log)"
  if [[ -n "$resolved" ]]; then
    printf '%s' "$resolved"
  else
    printf '%s' "$BRIDGE_STATE_DIR/daemon.log"
  fi
}
BRIDGE_DAEMON_LOG="${BRIDGE_DAEMON_LOG:-$(__bridge_default_daemon_log)}"
BRIDGE_DAEMON_CRASH_LOG="${BRIDGE_DAEMON_CRASH_LOG:-$BRIDGE_STATE_DIR/daemon-crash.log}"
BRIDGE_DAEMON_INTERVAL="${BRIDGE_DAEMON_INTERVAL:-5}"
BRIDGE_DAEMON_START_WAIT_SECONDS="${BRIDGE_DAEMON_START_WAIT_SECONDS:-3}"
BRIDGE_TASK_DB="${BRIDGE_TASK_DB:-$BRIDGE_STATE_DIR/tasks.db}"
BRIDGE_PROFILE_STATE_DIR="${BRIDGE_PROFILE_STATE_DIR:-$BRIDGE_STATE_DIR/profiles}"
BRIDGE_CRON_STATE_DIR="${BRIDGE_CRON_STATE_DIR:-$BRIDGE_STATE_DIR/cron}"
BRIDGE_CRON_HOME_DIR="${BRIDGE_CRON_HOME_DIR:-$BRIDGE_HOME/cron}"
BRIDGE_NATIVE_CRON_JOBS_FILE="${BRIDGE_NATIVE_CRON_JOBS_FILE:-$BRIDGE_CRON_HOME_DIR/jobs.json}"
BRIDGE_CRON_DISPATCH_WORKER_DIR="${BRIDGE_CRON_DISPATCH_WORKER_DIR:-$BRIDGE_CRON_STATE_DIR/workers}"
# Default 1 (issue #579): serial fan-out is the safe baseline on small-RAM
# hosts. Operators with headroom can lift this by exporting an override.
BRIDGE_CRON_DISPATCH_MAX_PARALLEL="${BRIDGE_CRON_DISPATCH_MAX_PARALLEL:-1}"
BRIDGE_CRON_DISPATCH_LEASE_SECONDS="${BRIDGE_CRON_DISPATCH_LEASE_SECONDS:-7200}"
BRIDGE_WORKTREE_ROOT="${BRIDGE_WORKTREE_ROOT:-$HOME/.agent-bridge/worktrees}"
BRIDGE_AGENT_HOME_ROOT="${BRIDGE_AGENT_HOME_ROOT:-$BRIDGE_HOME/agents}"
BRIDGE_RUNTIME_ROOT="${BRIDGE_RUNTIME_ROOT:-$BRIDGE_HOME/runtime}"
BRIDGE_RUNTIME_SCRIPTS_DIR="${BRIDGE_RUNTIME_SCRIPTS_DIR:-$BRIDGE_RUNTIME_ROOT/scripts}"
BRIDGE_RUNTIME_SKILLS_DIR="${BRIDGE_RUNTIME_SKILLS_DIR:-$BRIDGE_RUNTIME_ROOT/skills}"
BRIDGE_RUNTIME_SHARED_DIR="${BRIDGE_RUNTIME_SHARED_DIR:-$BRIDGE_RUNTIME_ROOT/shared}"
BRIDGE_RUNTIME_SHARED_TOOLS_DIR="${BRIDGE_RUNTIME_SHARED_TOOLS_DIR:-$BRIDGE_RUNTIME_SHARED_DIR/tools}"
BRIDGE_RUNTIME_SHARED_REFERENCES_DIR="${BRIDGE_RUNTIME_SHARED_REFERENCES_DIR:-$BRIDGE_RUNTIME_SHARED_DIR/references}"
BRIDGE_RUNTIME_MEMORY_DIR="${BRIDGE_RUNTIME_MEMORY_DIR:-$BRIDGE_RUNTIME_ROOT/memory}"
BRIDGE_RUNTIME_CREDENTIALS_DIR="${BRIDGE_RUNTIME_CREDENTIALS_DIR:-$BRIDGE_RUNTIME_ROOT/credentials}"
BRIDGE_RUNTIME_SECRETS_DIR="${BRIDGE_RUNTIME_SECRETS_DIR:-$BRIDGE_RUNTIME_ROOT/secrets}"
BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT="${BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT:-/home}"
if [[ -z "${BRIDGE_RUNTIME_CONFIG_FILE:-}" ]]; then
  if [[ -f "$BRIDGE_RUNTIME_ROOT/bridge-config.json" ]]; then
    BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
  elif [[ -f "$BRIDGE_RUNTIME_ROOT/openclaw.json" ]]; then
    BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/openclaw.json"
  else
    BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
  fi
fi
BRIDGE_GATEWAY_TRANSPORT="${BRIDGE_GATEWAY_TRANSPORT:-file}"
BRIDGE_GATEWAY_LISTENER="${BRIDGE_GATEWAY_LISTENER:-auto}"
BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT="${BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT:-/run/agent-bridge}"
BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS="${BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS:-5}"
BRIDGE_TMPFILES_DIR="${BRIDGE_TMPFILES_DIR:-/etc/tmpfiles.d}"
BRIDGE_TMPFILES_DRIVER="${BRIDGE_TMPFILES_DRIVER:-systemd-tmpfiles}"
BRIDGE_HOOKS_DIR="${BRIDGE_HOOKS_DIR:-$BRIDGE_HOME/hooks}"
BRIDGE_CHANNEL_SERVER_NAME="${BRIDGE_CHANNEL_SERVER_NAME:-bridge-webhook}"
BRIDGE_WEBHOOK_PORT_RANGE_START="${BRIDGE_WEBHOOK_PORT_RANGE_START:-9101}"
BRIDGE_WEBHOOK_PORT_RANGE_END="${BRIDGE_WEBHOOK_PORT_RANGE_END:-9199}"
BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS="${BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS:-300}"
BRIDGE_DASHBOARD_WEBHOOK_URL="${BRIDGE_DASHBOARD_WEBHOOK_URL:-}"
BRIDGE_DASHBOARD_STATE_FILE="${BRIDGE_DASHBOARD_STATE_FILE:-$BRIDGE_STATE_DIR/dashboard.json}"
BRIDGE_DASHBOARD_IDLE_SECONDS="${BRIDGE_DASHBOARD_IDLE_SECONDS:-900}"
BRIDGE_DASHBOARD_SUMMARY_SECONDS="${BRIDGE_DASHBOARD_SUMMARY_SECONDS:-3600}"
BRIDGE_LEGACY_HOME="${BRIDGE_LEGACY_HOME:-${BRIDGE_OPENCLAW_HOME:-$HOME/.openclaw}}"
BRIDGE_SOURCE_CRON_JOBS_FILE="${BRIDGE_SOURCE_CRON_JOBS_FILE:-${BRIDGE_OPENCLAW_CRON_JOBS_FILE:-$BRIDGE_LEGACY_HOME/cron/jobs.json}}"
BRIDGE_OPENCLAW_HOME="${BRIDGE_OPENCLAW_HOME:-$BRIDGE_LEGACY_HOME}"
BRIDGE_OPENCLAW_CRON_JOBS_FILE="${BRIDGE_OPENCLAW_CRON_JOBS_FILE:-$BRIDGE_SOURCE_CRON_JOBS_FILE}"
BRIDGE_DISCORD_RELAY_STATE_FILE="${BRIDGE_DISCORD_RELAY_STATE_FILE:-$BRIDGE_STATE_DIR/discord-relay.json}"
BRIDGE_DAEMON_LAUNCHAGENT_LABEL="${BRIDGE_DAEMON_LAUNCHAGENT_LABEL:-ai.agent-bridge.daemon}"
BRIDGE_DAEMON_LAUNCHAGENT_PLIST="${BRIDGE_DAEMON_LAUNCHAGENT_PLIST:-$HOME/Library/LaunchAgents/$BRIDGE_DAEMON_LAUNCHAGENT_LABEL.plist}"
BRIDGE_TMUX_PROMPT_WAIT_SECONDS="${BRIDGE_TMUX_PROMPT_WAIT_SECONDS:-2}"
BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED="${BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED:-1}"
BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS="${BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS:-300}"
BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS="${BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS:-300}"
BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS="${BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS:-0}"
BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD="${BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD:-10}"
BRIDGE_MCP_ORPHAN_PATTERNS="${BRIDGE_MCP_ORPHAN_PATTERNS:-}"
BRIDGE_BASH_BIN="${BRIDGE_BASH_BIN:-${BASH:-$(command -v bash)}}"
export BRIDGE_BASH_BIN
export BRIDGE_HOME BRIDGE_ROSTER_FILE BRIDGE_ROSTER_LOCAL_FILE
export BRIDGE_STATE_DIR BRIDGE_LAYOUT_MARKER_DIR BRIDGE_ACTIVE_AGENT_DIR BRIDGE_HISTORY_DIR BRIDGE_WORKTREE_META_DIR
export BRIDGE_ACTIVE_ROSTER_TSV BRIDGE_ACTIVE_ROSTER_MD
export BRIDGE_DAEMON_PID_FILE BRIDGE_DAEMON_LOG BRIDGE_DAEMON_CRASH_LOG
export BRIDGE_DAEMON_INTERVAL BRIDGE_DAEMON_START_WAIT_SECONDS
export BRIDGE_TASK_DB BRIDGE_PROFILE_STATE_DIR BRIDGE_CRON_STATE_DIR BRIDGE_CRON_HOME_DIR BRIDGE_NATIVE_CRON_JOBS_FILE
export BRIDGE_CRON_DISPATCH_WORKER_DIR BRIDGE_CRON_DISPATCH_MAX_PARALLEL BRIDGE_CRON_DISPATCH_LEASE_SECONDS
export BRIDGE_WORKTREE_ROOT BRIDGE_AGENT_HOME_ROOT
export BRIDGE_RUNTIME_ROOT BRIDGE_RUNTIME_SCRIPTS_DIR BRIDGE_RUNTIME_SKILLS_DIR
export BRIDGE_RUNTIME_SHARED_DIR BRIDGE_RUNTIME_SHARED_TOOLS_DIR BRIDGE_RUNTIME_SHARED_REFERENCES_DIR BRIDGE_RUNTIME_MEMORY_DIR
export BRIDGE_RUNTIME_CREDENTIALS_DIR BRIDGE_RUNTIME_SECRETS_DIR BRIDGE_RUNTIME_CONFIG_FILE
export BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT
export BRIDGE_GATEWAY_TRANSPORT BRIDGE_GATEWAY_LISTENER BRIDGE_QUEUE_GATEWAY_RUNTIME_ROOT
export BRIDGE_QUEUE_GATEWAY_SOCKET_TIMEOUT_SECONDS BRIDGE_TMPFILES_DIR BRIDGE_TMPFILES_DRIVER
export BRIDGE_HOOKS_DIR
export BRIDGE_CHANNEL_SERVER_NAME BRIDGE_WEBHOOK_PORT_RANGE_START BRIDGE_WEBHOOK_PORT_RANGE_END
export BRIDGE_CLAUDE_IDLE_FALLBACK_SECONDS
export BRIDGE_DASHBOARD_WEBHOOK_URL BRIDGE_DASHBOARD_STATE_FILE
export BRIDGE_LEGACY_HOME BRIDGE_SOURCE_CRON_JOBS_FILE BRIDGE_OPENCLAW_HOME BRIDGE_OPENCLAW_CRON_JOBS_FILE
export BRIDGE_DISCORD_RELAY_STATE_FILE BRIDGE_DAEMON_LAUNCHAGENT_LABEL BRIDGE_DAEMON_LAUNCHAGENT_PLIST
export BRIDGE_TMUX_PROMPT_WAIT_SECONDS
export BRIDGE_MCP_ORPHAN_CLEANUP_ENABLED BRIDGE_MCP_ORPHAN_CLEANUP_INTERVAL_SECONDS BRIDGE_MCP_ORPHAN_MIN_AGE_SECONDS
export BRIDGE_MCP_ORPHAN_SESSION_STOP_MIN_AGE_SECONDS BRIDGE_MCP_ORPHAN_NOTIFY_THRESHOLD BRIDGE_MCP_ORPHAN_PATTERNS

bridge_prepend_path_entry() {
  local entry="$1"
  [[ -n "$entry" ]] || return 0
  [[ -d "$entry" ]] || return 0
  case ":$PATH:" in
    *":$entry:"*) ;;
    *) PATH="$entry${PATH:+:$PATH}" ;;
  esac
}

bridge_prepend_path_entry "$HOME/.local/bin"
bridge_prepend_path_entry "$HOME/.nix-profile/bin"
bridge_prepend_path_entry "$HOME/bin"
bridge_prepend_path_entry "/opt/homebrew/bin"
bridge_prepend_path_entry "/usr/local/bin"
export PATH

RED='\033[0;31m'
# shellcheck disable=SC2034
GREEN='\033[0;32m'
YELLOW='\033[0;33m'
CYAN='\033[0;36m'
NC='\033[0m'
BRIDGE_MANAGED_MARKER="Managed by agent-bridge. Regenerated by agent-bridge."

bridge_source_module() {
  local module="$1"
  local path="$BRIDGE_SCRIPT_DIR/lib/$module"

  if [[ ! -f "$path" ]]; then
    echo "[bridge-lib] missing module: $path" >&2
    exit 1
  fi

  # shellcheck source=/dev/null
  source "$path"
}

bridge_source_module "bridge-session-patterns.sh"
bridge_source_module "bridge-core.sh"
# Read the v2 layout marker (state/layout-marker.sh) before any module
# snapshots BRIDGE_LAYOUT/BRIDGE_DATA_ROOT. Sourced after bridge-core.sh
# so bridge_warn is available, before bridge-agents.sh / bridge-isolation-v2.sh
# so v2 helpers see the marker values. Safe no-op when the marker is absent.
bridge_source_module "bridge-marker-bootstrap.sh"
# Resolve layout (env / marker / missing-marker(existing) / fresh-install-
# candidate / invalid-marker(fallback)) before bridge-agents.sh snapshots
# child env defaults. Read-only — never writes the marker.
bridge_source_module "bridge-layout-resolver.sh"
bridge_source_module "bridge-agents.sh"
# Issue #832: small probes for running a snippet as the isolated UID of a
# linux-user-isolated agent. Sourced after bridge-agents.sh because the
# helpers depend on bridge_agent_os_user /
# bridge_agent_linux_user_isolation_effective.
bridge_source_module "bridge-isolation-helpers.sh"
bridge_source_module "bridge-guard.sh"
bridge_source_module "bridge-tmux.sh"
bridge_source_module "bridge-skills.sh"
bridge_source_module "bridge-hooks.sh"
bridge_source_module "bridge-channels.sh"
bridge_source_module "bridge-state.sh"
bridge_source_module "bridge-isolation-v2.sh"
# r12 codex catch (#782) — bridge-isolation-v2-reapply.sh defines
# `bridge_isolation_v2_reapply_eligible_agents`, which the v2 matrix
# apply/check helpers in bridge-isolation-v2.sh need at runtime to
# enumerate the isolated-agent roster. Without it, code paths that
# don't transit bridge-migrate.sh (notably bridge-upgrade.sh's apply
# subprocess and bridge-start.sh's prepare_agent_isolation) silently
# fall back to single-agent behavior and strip other roster agents'
# credential grants during upgrade. Source it here so every entry
# point sees the helper.
bridge_source_module "bridge-isolation-v2-reapply.sh"
# v0.8.0 T5: runtime-only `BRIDGE_DISABLE_ISOLATION=1` escape hatch.
# Sourced after bridge-isolation-v2.sh so bridge_isolation_v2_active is
# already defined (the runtime state helper composes the two).
bridge_source_module "bridge-isolation-runtime.sh"
bridge_source_module "bridge-profiles.sh"
bridge_source_module "bridge-cron.sh"
bridge_source_module "bridge-discord.sh"
bridge_source_module "bridge-notify.sh"
bridge_source_module "bridge-migration.sh"
bridge_source_module "bridge-wave.sh"
# bridge-agent-update.sh is the typed/audited mutation surface for the
# protected agent-roster.local.sh managed-role fields (issue #528).
# Sourced last because it consumes helpers from bridge-agents.sh and
# bridge-core.sh (`bridge_admin_agent_id`, `bridge_require_python`).
bridge_source_module "bridge-agent-update.sh"
