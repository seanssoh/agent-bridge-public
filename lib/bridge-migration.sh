#!/usr/bin/env bash
# shellcheck shell=bash
#
# Migration helpers for transitioning a static agent between shared and
# linux-user isolation modes on an existing install. See issue #85.
#
# Exposes two entry points used by the `agent-bridge` dispatcher:
#   bridge_migration_isolate_cli
#   bridge_migration_unisolate_cli
#
# Both accept `<agent> [--dry-run]`. The helper is intentionally conservative:
# all destructive operations (useradd, chown, symlink rewrites, roster edits)
# are gated behind an explicit live run; `--dry-run` only prints the planned
# steps. Re-running on an already-converged agent is a no-op.

bridge_migration_platform() {
  uname -s 2>/dev/null || printf 'unknown'
}

bridge_migration_require_linux() {
  local plat
  plat="$(bridge_migration_platform)"
  if [[ "$plat" != "Linux" ]]; then
    bridge_die "per-UID isolation migration is only supported on Linux hosts (current: $plat). macOS scope is tracked in #89; use shared mode + hook hardening there."
  fi
}

bridge_migration_block_if_active() {
  local agent="$1"
  if bridge_agent_is_active "$agent"; then
    bridge_die "'$agent' has a live tmux session. Stop it first with 'agent-bridge agent stop $agent' before migrating."
  fi
}

bridge_migration_user_home() {
  local os_user="$1"
  printf '%s/%s' "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" "$os_user"
}

bridge_migration_print_step() {
  local dry_run="$1"
  shift
  if [[ "$dry_run" == "1" ]]; then
    printf '  [dry-run] %s\n' "$*"
  else
    printf '  [apply]   %s\n' "$*"
  fi
}

bridge_migration_run_step() {
  local dry_run="$1"
  shift
  bridge_migration_print_step "$dry_run" "$*"
  if [[ "$dry_run" != "1" ]]; then
    "$@"
  fi
}

bridge_migration_roster_upsert() {
  # Idempotently append/update isolation metadata lines in the local roster.
  # Uses `BRIDGE_ROSTER_LOCAL_FILE` as the edit target.
  local dry_run="$1"
  local agent="$2"
  local isolation_mode="$3"
  local os_user="$4"
  local file="$BRIDGE_ROSTER_LOCAL_FILE"

  bridge_migration_print_step "$dry_run" "upsert roster metadata in $file: isolation_mode=$isolation_mode os_user=${os_user:-<unset>}"
  if [[ "$dry_run" == "1" ]]; then
    return 0
  fi

  bridge_require_python
  python3 - "$file" "$agent" "$isolation_mode" "$os_user" <<'PY'
import re
import sys
from pathlib import Path

path = Path(sys.argv[1])
agent = sys.argv[2]
isolation_mode = sys.argv[3]
os_user = sys.argv[4]

text = path.read_text(encoding="utf-8") if path.exists() else ""

def upsert(source: str, key: str, value: str) -> str:
    rendered = f'BRIDGE_AGENT_{key}["{agent}"]="{value}"'
    pattern = re.compile(
        rf'^BRIDGE_AGENT_{re.escape(key)}\[\"{re.escape(agent)}\"\]=.*$',
        flags=re.MULTILINE,
    )
    if pattern.search(source):
        return pattern.sub(rendered, source)
    if source and not source.endswith("\n"):
        source += "\n"
    return source + rendered + "\n"

text = upsert(text, "ISOLATION_MODE", isolation_mode)
text = upsert(text, "OS_USER", os_user)
path.write_text(text, encoding="utf-8")
PY
}

bridge_migration_isolate() {
  local agent="$1"
  local dry_run="$2"
  local install_sudoers="${3:-0}"
  local reapply="${4:-0}"
  local os_user current_mode workdir user_home runtime_state_dir log_dir

  bridge_migration_require_linux
  bridge_require_agent "$agent"

  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent' is a dynamic agent; only static agents can be migrated."
  fi

  current_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"

  if [[ "$current_mode" == "linux-user" && -n "$os_user" ]]; then
    if [[ "$reapply" != "1" ]]; then
      printf '[info] %s is already linux-user isolated (os_user=%s); nothing to do.\n' "$agent" "$os_user"
      printf '[hint] use --reapply to re-install ACLs without re-migrating ownership (picks up ACL-contract changes).\n'
      return 0
    fi
    # Reapply branch: skip ownership migration + useradd + sudoers, only
    # re-run the ACL / queue-gateway plumbing via bridge_linux_prepare_agent_isolation.
    # Resolve workdir BEFORE the prepare call — the original first-time flow
    # assigns it below the early-return, so we must hoist that here.
    bridge_migration_block_if_active "$agent"
    workdir="$(bridge_agent_workdir "$agent")"
    printf '[plan] re-applying ACLs for %s (os_user=%s workdir=%s)\n' "$agent" "$os_user" "$workdir"
    if [[ "$dry_run" == "1" ]]; then
      printf '  [plan] bridge_linux_prepare_agent_isolation %s %s %s <controller>\n' "$agent" "$os_user" "$workdir"
      printf '[done] isolation plan (reapply) printed for %s\n' "$agent"
      return 0
    fi
    # Issue #752 H4 — ACL prep is the load-bearing step of --reapply.
    # If it fails, refuse to print [done] / return 0; otherwise the operator
    # sees a clean reapply on top of partially-applied isolation perms.
    if ! bridge_linux_prepare_agent_isolation "$agent" "$os_user" "$workdir" "$(bridge_current_user)"; then
      bridge_warn "bridge_linux_prepare_agent_isolation failed for $agent during --reapply; refusing to mark reapply complete. Address the underlying cause (sudo policy, missing os_user, perm denied on $workdir) and re-run 'agent-bridge isolate $agent --reapply'. See acceptance runbook §2."
      return 1
    fi
    # Issue #544 PR3 — refresh the bridge-native skills under the
    # isolated HOME (.claude/skills/) so existing isolated agents pick
    # up new/changed skills on `--reapply` without unisolate→isolate.
    # Best-effort: warn but don't bail out — the ACL reapply above is
    # the load-bearing step.
    if command -v bridge_sync_isolated_home_claude_skills >/dev/null 2>&1; then
      bridge_sync_isolated_home_claude_skills "$agent" \
        || bridge_warn "isolated-home skills sync returned non-zero for $agent; re-run isolate --reapply or check OPERATIONS.md isolated-agent section"
    fi
    # Issue #544 PR2 — refresh the per-isolated-home Claude
    # settings.json + settings.effective.json so existing isolated
    # agents pick up the bridge hook entries on `--reapply` without an
    # unisolate→isolate cycle.
    # Issue #752 W3c (M8) — settings install is load-bearing on reapply:
    # without it, hooks/policy entries silently fail to re-render and the
    # operator's state file says "done" while the agent runs without
    # bridge hooks. Match H4's contract at line 142-145 — refuse to mark
    # reapply complete if the install fails.
    if command -v bridge_install_isolated_home_settings >/dev/null 2>&1; then
      # Issue #570: managed autoCompactWindow default is unconditionally
      # 1_000_000; launch_cmd is forwarded for caller-signature parity
      # with helpers that still accept it (no longer consulted by the
      # renderer). Match the call shape at run_rerender_settings
      # (bridge-agent.sh:1655-1669).
      local _reapply_launch_cmd=""
      _reapply_launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || printf '')"
      if ! bridge_install_isolated_home_settings "$agent" "$_reapply_launch_cmd"; then
        bridge_warn "bridge_install_isolated_home_settings failed for $agent during --reapply; refusing to mark reapply complete. Address the underlying cause (perm denied on settings.local.json under the isolated HOME, missing renderer deps) and re-run 'agent-bridge isolate $agent --reapply'. See OPERATIONS.md isolated-agent section."
        return 1
      fi
    fi
    printf '[done] ACL reapply complete for %s\n' "$agent"
    return 0
  fi

  bridge_migration_block_if_active "$agent"

  [[ -n "$os_user" ]] || os_user="$(bridge_agent_default_os_user "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  user_home="$(bridge_migration_user_home "$os_user")"
  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"

  printf '[plan] isolate %s -> linux-user mode\n' "$agent"
  printf '       os_user=%s user_home=%s workdir=%s\n' "$os_user" "$user_home" "$workdir"

  # Write the roster metadata FIRST so a mid-run failure leaves unisolate with
  # enough state to roll back; the upsert is idempotent.
  bridge_migration_roster_upsert "$dry_run" "$agent" "linux-user" "$os_user"

  if ! id -u "$os_user" >/dev/null 2>&1; then
    bridge_migration_print_step "$dry_run" "useradd --system --home-dir $user_home --shell /usr/sbin/nologin $os_user"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root useradd --system --home-dir "$user_home" --shell /usr/sbin/nologin "$os_user"
    fi
  else
    printf '  [skip]    os user %s already exists\n' "$os_user"
  fi

  bridge_migration_print_step "$dry_run" "mkdir -p $user_home && chown $os_user:$os_user $user_home && chmod 0700 $user_home"
  if [[ "$dry_run" != "1" ]]; then
    bridge_linux_sudo_root mkdir -p "$user_home"
    bridge_linux_sudo_root chown "$os_user:$os_user" "$user_home"
    bridge_linux_sudo_root chmod 0700 "$user_home"
  fi

  bridge_migration_print_step "$dry_run" "install symlink $user_home/.agent-bridge -> $BRIDGE_HOME"
  if [[ "$dry_run" != "1" ]]; then
    bridge_linux_install_agent_bridge_symlink "$os_user" "$user_home" "$BRIDGE_HOME"
  fi

  if [[ -d "$workdir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $os_user $workdir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$os_user" "$workdir"
    fi
  else
    printf '  [warn]    workdir missing: %s (skipping chown)\n' "$workdir"
  fi

  if [[ -n "$runtime_state_dir" && -d "$runtime_state_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $os_user $runtime_state_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$os_user" "$runtime_state_dir"
    fi
  else
    printf '  [warn]    runtime state dir missing: %s (skipping chown; will be created on first start)\n' "${runtime_state_dir:-<unset>}"
  fi
  if [[ -n "$log_dir" && -d "$log_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $os_user $log_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$os_user" "$log_dir"
    fi
  else
    printf '  [warn]    log dir missing: %s (skipping chown; will be created on first start)\n' "${log_dir:-<unset>}"
  fi

  # Install the ACL / queue-gateway / hidden-path-strip plumbing that the
  # create-time path (bridge_linux_prepare_agent_isolation) would have set up.
  # Without this the acceptance runbook's §2.1/§2.4 cannot pass on migrated
  # agents.
  bridge_migration_print_step "$dry_run" "install per-agent ACLs + queue-gateway dirs + hidden-path strips (bridge_linux_prepare_agent_isolation)"
  if [[ "$dry_run" != "1" ]]; then
    bridge_linux_prepare_agent_isolation "$agent" "$os_user" "$workdir" "$(bridge_current_user)" || \
      bridge_warn "bridge_linux_prepare_agent_isolation returned non-zero for $agent; re-run isolate or check acceptance runbook §2"
    # Issue #544 PR3 — install bridge-native skills into the freshly
    # provisioned isolated HOME so SessionStart/UserPromptSubmit hooks
    # (PR2 surface) and the agent itself can discover the
    # agent-bridge-runtime / cron-manager / memory-wiki /
    # patch-permission-approval skills under the isolated UID.
    # Best-effort: failure here doesn't block migration.
    if command -v bridge_sync_isolated_home_claude_skills >/dev/null 2>&1; then
      bridge_sync_isolated_home_claude_skills "$agent" \
        || bridge_warn "isolated-home skills sync returned non-zero for $agent; re-run isolate --reapply"
    fi
    # Issue #544 PR2 — install bridge hook entries into the freshly
    # provisioned isolated HOME so SessionStart, UserPromptSubmit, Stop,
    # PermissionDenied, PreToolUse/PostToolUse all fire from first
    # session.
    # Issue #752 W3c (M9) — settings install is load-bearing on a fresh
    # isolate: without it, the agent can start under linux-user isolation
    # without bridge hooks rendered into its .claude/settings.local.json.
    # Match H4's contract at line 142-145 — refuse to mark isolation
    # complete if the install fails.
    if command -v bridge_install_isolated_home_settings >/dev/null 2>&1; then
      # Same launch_cmd forward as the --reapply branch above.
      local _isolate_launch_cmd=""
      _isolate_launch_cmd="$(bridge_agent_launch_cmd_raw "$agent" 2>/dev/null || printf '')"
      if ! bridge_install_isolated_home_settings "$agent" "$_isolate_launch_cmd"; then
        bridge_warn "bridge_install_isolated_home_settings failed for $agent during isolate; refusing to mark isolate complete. Address the underlying cause (perm denied on settings.local.json under the isolated HOME, missing renderer deps) and re-run 'agent-bridge isolate $agent --reapply'. See OPERATIONS.md isolated-agent section."
        return 1
      fi
    fi
  fi

  if [[ "$install_sudoers" == "1" ]]; then
    bridge_migration_install_sudoers "$dry_run" "$os_user" || true
  else
    bridge_migration_print_sudoers_hint "$os_user"
  fi

  if [[ "$dry_run" == "1" ]]; then
    printf '[done] isolation plan printed (dry-run) for %s\n' "$agent"
    printf '[note] re-run without --dry-run to apply. You may need to re-provision channel tokens since old per-agent secrets stay owned by the controller user.\n'
  else
    printf '[done] isolation applied for %s\n' "$agent"
    printf '[note] re-provision channel tokens if the agent consumed secrets under its old UID; old files are now owned by %s.\n' "$os_user"
  fi
}

bridge_migration_unisolate() {
  local agent="$1"
  local dry_run="$2"
  local current_mode os_user workdir controller_user runtime_state_dir log_dir user_home

  bridge_migration_require_linux
  bridge_require_agent "$agent"

  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent' is a dynamic agent; only static agents can be migrated."
  fi

  current_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"

  if [[ "$current_mode" != "linux-user" || -z "$os_user" ]]; then
    printf '[info] %s is already in shared mode; nothing to do.\n' "$agent"
    return 0
  fi

  bridge_migration_block_if_active "$agent"

  workdir="$(bridge_agent_workdir "$agent")"
  controller_user="$(bridge_current_user)"
  user_home="$(bridge_migration_user_home "$os_user" 2>/dev/null || true)"

  printf '[plan] unisolate %s -> shared mode\n' "$agent"
  printf '       reverting ownership from os_user=%s back to controller=%s\n' "$os_user" "$controller_user"

  if [[ -d "$workdir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $workdir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$workdir"
    fi
  fi

  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"
  if [[ -n "$runtime_state_dir" && -d "$runtime_state_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $runtime_state_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$runtime_state_dir"
    fi
  fi
  if [[ -n "$log_dir" && -d "$log_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $log_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$log_dir"
    fi
  fi

  # Restore ownership of per-agent sibling files that prepare_agent_isolation
  # chowns to the os_user: history file, audit log, queue-gateway
  # request/response dirs. These live outside $runtime_state_dir and
  # $log_dir, so the chown -R above misses them, leaving the operator
  # unable to start the agent post-rollback (issue #112).
  local audit_file history_file request_dir response_dir
  local queue_gateway_root=""
  local queue_gateway_agent_dir=""
  audit_file="$(bridge_agent_audit_log_file "$agent" 2>/dev/null || true)"
  history_file="$(bridge_history_file_for_agent "$agent" 2>/dev/null || true)"
  queue_gateway_root="$(bridge_queue_gateway_root 2>/dev/null || true)"
  queue_gateway_agent_dir="$(bridge_queue_gateway_agent_dir "$agent" 2>/dev/null || true)"
  request_dir="$(bridge_queue_gateway_requests_dir "$agent" 2>/dev/null || true)"
  response_dir="$(bridge_queue_gateway_responses_dir "$agent" 2>/dev/null || true)"

  if [[ -n "$audit_file" && -e "$audit_file" ]]; then
    bridge_migration_print_step "$dry_run" "chown $controller_user $audit_file"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown "$controller_user" "$audit_file" || true
    fi
  fi
  if [[ -n "$history_file" && -e "$history_file" ]]; then
    bridge_migration_print_step "$dry_run" "chown $controller_user $history_file"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown "$controller_user" "$history_file" || true
    fi
  fi
  if [[ -n "$request_dir" && -d "$request_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $request_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$request_dir" || true
    fi
  fi
  if [[ -n "$response_dir" && -d "$response_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $response_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$response_dir" || true
    fi
  fi
  if [[ -n "$queue_gateway_agent_dir" && -d "$queue_gateway_agent_dir" ]]; then
    bridge_migration_print_step "$dry_run" "chown -R $controller_user $queue_gateway_agent_dir"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root chown -R "$controller_user" "$queue_gateway_agent_dir" || true
    fi
  fi
  # Strip the target os_user from the queue-gateway root (preserve the
  # controller r-x and any other agents' ACLs). The OS user itself is
  # intentionally preserved after rollback, so without this the stale
  # u:<os_user>:--x entry would survive on the shared root.
  if [[ -n "$queue_gateway_root" && -d "$queue_gateway_root" ]]; then
    bridge_migration_print_step "$dry_run" "setfacl -x u:${os_user} $queue_gateway_root"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root setfacl -x "u:${os_user}" "$queue_gateway_root" >/dev/null 2>&1 || true
      bridge_linux_sudo_root setfacl -d -x "u:${os_user}" "$queue_gateway_root" >/dev/null 2>&1 || true
    fi
  fi

  # Strip plugin-share ACLs granted by bridge_linux_share_plugin_catalog.
  # Mirrors the catalog file list and per-channel install path grants, plus
  # the traverse chain that reached up to controller_home.
  #
  # Channel set source-of-truth: the persisted grant-set state file
  # written by bridge_isolated_plugin_grants_write. Reading from the
  # live roster is unsafe here because by the time unisolate runs the
  # operator may have already edited BRIDGE_AGENT_CHANNELS to drop
  # channels, and we still need to revoke the ACLs they earned.
  # Falls back to the live roster only when the state file is missing
  # (older agents that pre-date the grant-set persistence). (Blocking 1
  # in PR #302 r1.)
  local controller_home_for_plugins=""
  # Test-only seam: BRIDGE_CONTROLLER_HOME_OVERRIDE replaces the getent
  # passwd lookup so the regression test in tests/isolation-plugin-sharing.sh
  # can drive unisolate cleanup against the same fake controller plugin
  # tree it uses for the share path. The override is ignored unless
  # BRIDGE_HOME points under a recognised tempdir prefix (/tmp, /var/tmp,
  # or $TMPDIR), which guards against accidental production use. Mirrors
  # the seam in bridge_linux_share_plugin_catalog. (Blocking 5(b) in PR
  # #302 r2.)
  if [[ -n "${BRIDGE_CONTROLLER_HOME_OVERRIDE:-}" ]]; then
    local _override_ok=0
    local _bridge_home_norm="${BRIDGE_HOME:-}"
    case "$_bridge_home_norm" in
      /tmp/*|/var/tmp/*) _override_ok=1 ;;
    esac
    if [[ "$_override_ok" -eq 0 && -n "${TMPDIR:-}" ]]; then
      local _tmpdir_trimmed="${TMPDIR%/}"
      case "$_bridge_home_norm" in
        "$_tmpdir_trimmed"/*) _override_ok=1 ;;
      esac
    fi
    if [[ "$_override_ok" -eq 1 ]]; then
      controller_home_for_plugins="$BRIDGE_CONTROLLER_HOME_OVERRIDE"
    else
      bridge_warn "bridge_migration_unisolate: ignoring BRIDGE_CONTROLLER_HOME_OVERRIDE because BRIDGE_HOME is not under a tempdir prefix (got '${BRIDGE_HOME:-<unset>}')"
    fi
  fi
  if [[ -z "$controller_home_for_plugins" ]]; then
    controller_home_for_plugins="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  fi
  if [[ -n "$controller_home_for_plugins" && -d "$controller_home_for_plugins/.claude/plugins" ]]; then
    local controller_plugins="$controller_home_for_plugins/.claude/plugins"
    local catalog_file=""
    local src=""
    for catalog_file in "${BRIDGE_ISOLATION_SHARED_CATALOG_READ_FILES[@]}"; do
      src="$controller_plugins/$catalog_file"
      [[ -e "$src" ]] || continue
      bridge_migration_print_step "$dry_run" "setfacl -x u:${os_user} $src + revoke traverse chain"
      if [[ "$dry_run" != "1" ]]; then
        bridge_linux_sudo_root setfacl -x "u:${os_user}" "$src" >/dev/null 2>&1 || true
        bridge_linux_revoke_traverse_chain "$os_user" "$src" "$controller_home_for_plugins"
      fi
    done

    local plugin_channels_csv=""
    plugin_channels_csv="$(bridge_isolated_plugin_grants_read "$agent" 2>/dev/null || true)"
    if [[ -z "$plugin_channels_csv" ]]; then
      # No persisted state file (older isolate, or it was hand-removed).
      # Fall back to the live roster's channels — better than skipping
      # the strip entirely, even if it misses channels the operator has
      # since dropped.
      plugin_channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
    fi
    if [[ -n "$plugin_channels_csv" ]]; then
      local _plugin_channels=()
      local _plugin_channel=""
      local _plugin_id=""
      local _plugin_install_path=""
      IFS=',' read -ra _plugin_channels <<<"$plugin_channels_csv"
      for _plugin_channel in "${_plugin_channels[@]}"; do
        [[ "$_plugin_channel" == plugin:* ]] || continue
        _plugin_id="${_plugin_channel#plugin:}"
        _plugin_install_path="$(bridge_resolve_plugin_install_path "$_plugin_id" "$controller_plugins")"
        [[ -n "$_plugin_install_path" && -d "$_plugin_install_path" ]] || continue
        bridge_migration_print_step "$dry_run" "setfacl -Rx u:${os_user} $_plugin_install_path + revoke traverse chain"
        if [[ "$dry_run" != "1" ]]; then
          bridge_linux_sudo_root setfacl -Rx "u:${os_user}" "$_plugin_install_path" >/dev/null 2>&1 || true
          bridge_linux_revoke_traverse_chain "$os_user" "$_plugin_install_path" "$controller_home_for_plugins"
        fi
      done
    fi
  fi

  # Tear down the isolated-side artifacts (catalog symlinks, per-UID
  # installed_plugins.json, plugins/ root if empty) that
  # bridge_linux_share_plugin_catalog created under
  # $user_home/.claude/plugins/. plugins/data/ is preserved on purpose.
  # (Blocking 4 in PR #302 r1.)
  if [[ -n "$user_home" ]]; then
    bridge_linux_unshare_plugin_catalog "$os_user" "$user_home" "$dry_run"
  fi

  # Drop the persisted grant set last so that, on dry-run, the file
  # survives for inspection; on a real run, by this point both the
  # controller-side and isolated-side strips have completed.
  if [[ "$dry_run" != "1" ]]; then
    bridge_isolated_plugin_grants_remove "$agent"
  else
    bridge_migration_print_step "$dry_run" "rm $(bridge_isolated_plugin_grants_state_file "$agent") (persisted grant-set)"
  fi

  # Backward-compat: prior versions broadly granted u:<os_user>:r-X on the
  # entire $BRIDGE_HOME/plugins tree (independent of BRIDGE_AGENT_CHANNELS).
  # Strip any leftover entries for this os_user; only this UID's entries are
  # affected, other agents' grants on the same path are preserved.
  if [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME/plugins" ]]; then
    bridge_migration_print_step "$dry_run" "setfacl -Rx u:${os_user} $BRIDGE_HOME/plugins (legacy cleanup)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root setfacl -Rx "u:${os_user}" "$BRIDGE_HOME/plugins" >/dev/null 2>&1 || true
    fi
  fi

  # Remove the scoped roster snapshot (agent-env.sh). In shared mode the
  # snapshot is stale — it still carries linux-user isolation metadata and
  # would be picked up by bridge_load_roster's BRIDGE_AGENT_ID fallback,
  # making shared-mode launches believe isolation is still active (#116).
  local scoped_env_file=""
  scoped_env_file="$(bridge_agent_linux_env_file "$agent" 2>/dev/null || true)"
  if [[ -n "$scoped_env_file" && -e "$scoped_env_file" ]]; then
    bridge_migration_print_step "$dry_run" "rm $scoped_env_file"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root rm -f "$scoped_env_file" 2>/dev/null || rm -f "$scoped_env_file" || true
    fi
  fi

  # Remove the per-UID Claude credentials symlink (legacy v1 artifact —
  # may exist on installs migrated from pre-v0.8.0). The named-user ACL
  # on the controller's ~/.claude/.credentials.json (also legacy) is left
  # alone here since the entry is per-UID and harmless once this agent's
  # UID is no longer in use.
  local isolated_cred_link=""
  isolated_cred_link="$(bridge_migration_user_home "$os_user")/.claude/.credentials.json"
  if [[ -L "$isolated_cred_link" ]]; then
    bridge_migration_print_step "$dry_run" "rm $isolated_cred_link"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root rm -f "$isolated_cred_link" || true
    fi
  fi

  # Issue #233: the isolate path walked ancestors up to '/' granting
  # `u:${os_user}:--x` search bits for the isolated UID, and separately
  # granted `u:${controller_user}:--x` on parts of that chain. POSIX
  # ACL's named-user override then stripped the operator's own read
  # access on `/` and `/home` (base `other::r-x` was shadowed by
  # `u:ec2-user:--x`). bun 1.3.x's ancestor-walk resolver hit EACCES
  # there and every bun MCP plugin silently died. Unisolate previously
  # left every one of those entries in place, so the poison stayed until
  # a later Claude Code upgrade exposed it days or weeks later.
  #
  # Strip the named-user entries for both the isolated UID and the
  # controller UID from every path the isolate step is known to have
  # touched. Non-recursive on `/`, `/home`, and the controller home
  # (never touch sibling user files); recursive inside BRIDGE_HOME,
  # workdir, and runtime dirs that are scoped to this agent.
  local controller_home=""
  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  local isolated_home=""
  isolated_home="$(bridge_migration_user_home "$os_user")"

  local -a acl_strip_paths_shallow=()
  acl_strip_paths_shallow+=("/")
  acl_strip_paths_shallow+=("/home")
  [[ -n "$controller_home" && -d "$controller_home" ]] && acl_strip_paths_shallow+=("$controller_home")
  [[ -n "$isolated_home" && -d "$isolated_home" ]] && acl_strip_paths_shallow+=("$isolated_home")
  [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME" ]] && acl_strip_paths_shallow+=("$BRIDGE_HOME")
  [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" && -d "$BRIDGE_AGENT_HOME_ROOT" ]] && acl_strip_paths_shallow+=("$BRIDGE_AGENT_HOME_ROOT")

  # Codex rounds 1/2 walked the isolate write set (lib/bridge-agents.sh:985-1017)
  # and flagged every grant that this cleanup still missed:
  #   - line 998: u:<os_user>:r-x on memory_daily_root and memory_daily_root/shared
  #     (the two *parents* of the per-agent + shared/aggregate dirs).
  #   - line 1015: u:<os_user>:r-X recursive on recursive_read_paths — hooks,
  #     shared, runtime, BRIDGE_HOME/{.claude,lib,plugins,scripts},
  #     BRIDGE_AGENT_HOME_ROOT/.claude.
  #   - lines 1000-1011: u:<os_user>:r-x on the root helper files
  #     (agent-bridge, agb, VERSION, bridge-*.sh, bridge-*.py).
  # Every one of those entries survived post-unisolate because the OS
  # user is intentionally preserved. Add them to the sweep. Only ever
  # remove the single u:<os_user> entry on shared paths — do not touch
  # other isolated agents.
  local history_file="" memory_daily_agent_dir="" memory_daily_shared_aggregate_dir=""
  history_file="$(bridge_history_file_for_agent "$agent" 2>/dev/null || true)"
  local memory_daily_root="" memory_daily_shared_root=""
  if bridge_isolation_v2_active; then
    memory_daily_agent_dir="$(bridge_isolation_v2_agent_memory_daily_root "$agent" 2>/dev/null || true)"
    memory_daily_shared_aggregate_dir="$(bridge_isolation_v2_memory_daily_shared_aggregate_dir 2>/dev/null || true)"
    # v2 layout has no legacy memory-daily root/shared parents to ACL-strip
    # — leave those local strings empty so the shallow strip below skips.
  else
    memory_daily_agent_dir="$BRIDGE_STATE_DIR/memory-daily/$agent"
    memory_daily_shared_aggregate_dir="$BRIDGE_STATE_DIR/memory-daily/shared/aggregate"
    memory_daily_root="$BRIDGE_STATE_DIR/memory-daily"
    memory_daily_shared_root="$memory_daily_root/shared"
  fi

  local -a acl_strip_paths_recursive=()
  [[ -n "$workdir" && -d "$workdir" ]] && acl_strip_paths_recursive+=("$workdir")
  [[ -n "$runtime_state_dir" && -d "$runtime_state_dir" ]] && acl_strip_paths_recursive+=("$runtime_state_dir")
  [[ -n "$log_dir" && -d "$log_dir" ]] && acl_strip_paths_recursive+=("$log_dir")
  [[ -n "$queue_gateway_agent_dir" && -d "$queue_gateway_agent_dir" ]] && acl_strip_paths_recursive+=("$queue_gateway_agent_dir")
  [[ -n "$request_dir" && -d "$request_dir" ]] && acl_strip_paths_recursive+=("$request_dir")
  [[ -n "$response_dir" && -d "$response_dir" ]] && acl_strip_paths_recursive+=("$response_dir")
  [[ -n "$memory_daily_agent_dir" && -d "$memory_daily_agent_dir" ]] && acl_strip_paths_recursive+=("$memory_daily_agent_dir")
  [[ -n "$memory_daily_shared_aggregate_dir" && -d "$memory_daily_shared_aggregate_dir" ]] && acl_strip_paths_recursive+=("$memory_daily_shared_aggregate_dir")
  # recursive_read_paths from isolate (line 1015): grants are u:<os_user>:r-X
  # on every file/dir under these trees. Strip the same scope.
  [[ -n "${BRIDGE_HOOKS_DIR:-}" && -d "$BRIDGE_HOOKS_DIR" ]] && acl_strip_paths_recursive+=("$BRIDGE_HOOKS_DIR")
  [[ -n "${BRIDGE_SHARED_DIR:-}" && -d "$BRIDGE_SHARED_DIR" ]] && acl_strip_paths_recursive+=("$BRIDGE_SHARED_DIR")
  [[ -n "${BRIDGE_RUNTIME_ROOT:-}" && -d "$BRIDGE_RUNTIME_ROOT" ]] && acl_strip_paths_recursive+=("$BRIDGE_RUNTIME_ROOT")
  [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME/.claude" ]] && acl_strip_paths_recursive+=("$BRIDGE_HOME/.claude")
  [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME/lib" ]] && acl_strip_paths_recursive+=("$BRIDGE_HOME/lib")
  [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME/plugins" ]] && acl_strip_paths_recursive+=("$BRIDGE_HOME/plugins")
  [[ -n "${BRIDGE_HOME:-}" && -d "$BRIDGE_HOME/scripts" ]] && acl_strip_paths_recursive+=("$BRIDGE_HOME/scripts")
  [[ -n "${BRIDGE_AGENT_HOME_ROOT:-}" && -d "$BRIDGE_AGENT_HOME_ROOT/.claude" ]] && acl_strip_paths_recursive+=("$BRIDGE_AGENT_HOME_ROOT/.claude")

  # Shallow parents that isolate grants u:<os_user>:r-x on but the
  # recursive list above doesn't already cover: the memory-daily root
  # and its shared subdir. Non-recursive so sibling agent dirs stay
  # intact.
  [[ -n "$memory_daily_root" && -d "$memory_daily_root" ]] && acl_strip_paths_shallow+=("$memory_daily_root")
  [[ -n "$memory_daily_shared_root" && -d "$memory_daily_shared_root" ]] && acl_strip_paths_shallow+=("$memory_daily_shared_root")

  # Root-level helper files isolate grants u:<os_user>:r-x on
  # (bridge-agents.sh:1000-1011). These are files, not directories, so
  # handle them separately: a single `setfacl -x` per existing path.
  local -a acl_strip_files=()
  if [[ -n "${BRIDGE_HOME:-}" ]]; then
    [[ -e "$BRIDGE_HOME/agent-bridge" ]] && acl_strip_files+=("$BRIDGE_HOME/agent-bridge")
    [[ -e "$BRIDGE_HOME/agb" ]] && acl_strip_files+=("$BRIDGE_HOME/agb")
    [[ -e "$BRIDGE_HOME/VERSION" ]] && acl_strip_files+=("$BRIDGE_HOME/VERSION")
    local _helper
    shopt -s nullglob
    for _helper in "$BRIDGE_HOME"/bridge-*.sh "$BRIDGE_HOME"/bridge-*.py; do
      [[ -e "$_helper" ]] && acl_strip_files+=("$_helper")
    done
    shopt -u nullglob
  fi

  local _acl_target=""
  for _acl_target in "${acl_strip_paths_shallow[@]}"; do
    [[ -n "$_acl_target" ]] || continue
    bridge_migration_print_step "$dry_run" "setfacl -x u:${os_user} ${_acl_target}"
    bridge_migration_print_step "$dry_run" "setfacl -x u:${controller_user} ${_acl_target}"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root setfacl -x "u:${os_user}" "$_acl_target" 2>/dev/null || true
      bridge_linux_sudo_root setfacl -d -x "u:${os_user}" "$_acl_target" 2>/dev/null || true
      bridge_linux_sudo_root setfacl -x "u:${controller_user}" "$_acl_target" 2>/dev/null || true
      bridge_linux_sudo_root setfacl -d -x "u:${controller_user}" "$_acl_target" 2>/dev/null || true
    fi
  done
  # `setfacl -R -x` strips access entries on every file and directory
  # under the target. It does NOT touch default ACLs — those are a
  # separate attribute stored only on directories (legacy v1 inheritance,
  # may still be present on installs migrated from pre-v0.8.0). Remove
  # them with a `find -type d` sweep so post-unisolate file creations do
  # not keep inheriting the isolated UID's grants.
  for _acl_target in "${acl_strip_paths_recursive[@]}"; do
    [[ -n "$_acl_target" ]] || continue
    bridge_migration_print_step "$dry_run" "setfacl -R -x u:${os_user} ${_acl_target}"
    bridge_migration_print_step "$dry_run" "find ${_acl_target} -type d -print0 | xargs -0 -r setfacl -d -x u:${os_user}"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root setfacl -R -x "u:${os_user}" "$_acl_target" 2>/dev/null || true
      # Default-ACL strip: `find -exec setfacl ... +` was observed to
      # return rc=0 even when individual setfacl calls failed (issue
      # #746 root cause). Pipe through `xargs -0 -r` instead so per-
      # invocation failures propagate via xargs rc. The whole pipeline
      # runs under `sh -c` because `bridge_linux_sudo_root find ... |
      # xargs ...` would only sudo the find half. `xargs -r` is GNU-
      # only but this is a Linux-only path (bridge_migration_require_linux).
      bridge_linux_sudo_root sh -c \
        'find "$1" -type d -print0 | xargs -0 -r setfacl -d -x "u:$2"' \
        _ "$_acl_target" "$os_user" 2>/dev/null || true
      # Post-verify: any surviving named ACL for os_user is a regression
      # (the audit invariant from #752 H1). Retry once sudo-only; if
      # still drifted, warn loudly with the first surviving path.
      # Best-effort — unisolate must not abort on residual ACL.
      if command -v getfacl >/dev/null 2>&1; then
        local _residual
        _residual="$(bridge_linux_sudo_root getfacl --absolute-names --skip-base -R "$_acl_target" 2>/dev/null \
                      | grep -E "^(user|default:user):${os_user}:" | head -n1 || true)"
        if [[ -n "$_residual" ]]; then
          bridge_linux_sudo_root setfacl -R -x "u:${os_user}" "$_acl_target" 2>/dev/null || true
          bridge_linux_sudo_root sh -c \
            'find "$1" -type d -print0 | xargs -0 -r setfacl -d -x "u:$2"' \
            _ "$_acl_target" "$os_user" 2>/dev/null || true
          _residual="$(bridge_linux_sudo_root getfacl --absolute-names --skip-base -R "$_acl_target" 2>/dev/null \
                        | grep -E "^(user|default:user):${os_user}:" | head -n1 || true)"
          if [[ -n "$_residual" ]]; then
            bridge_warn "unisolate: residual ACL after strip on $_acl_target: $_residual (operator: investigate underlying setfacl/sudo failure; rerun unisolate after addressing it)"
          fi
        fi
      fi
    fi
  done
  # history_file is a regular file (not a directory). `-R` is a no-op
  # there and default ACLs do not apply, so strip only the access entry.
  if [[ -n "$history_file" && -e "$history_file" ]]; then
    bridge_migration_print_step "$dry_run" "setfacl -x u:${os_user} ${history_file}"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root setfacl -x "u:${os_user}" "$history_file" 2>/dev/null || true
    fi
  fi
  # Root-level helper file ACLs (agent-bridge, agb, VERSION,
  # bridge-*.sh/*.py). Files, not directories — no default ACL.
  for _acl_target in "${acl_strip_files[@]}"; do
    [[ -n "$_acl_target" ]] || continue
    bridge_migration_print_step "$dry_run" "setfacl -x u:${os_user} ${_acl_target}"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root setfacl -x "u:${os_user}" "$_acl_target" 2>/dev/null || true
    fi
  done

  bridge_migration_roster_upsert "$dry_run" "$agent" "shared" ""

  if [[ "$dry_run" == "1" ]]; then
    printf '[done] unisolate plan printed (dry-run) for %s\n' "$agent"
  else
    printf '[done] unisolate applied for %s\n' "$agent"
  fi
  printf '[note] the OS user %s is intentionally preserved (it may still own unrelated files). To delete it run: sudo userdel %s && sudo rm -rf %s\n' \
    "$os_user" "$os_user" "$(bridge_migration_user_home "$os_user")"
}

bridge_migration_parse_args() {
  BRIDGE_MIGRATION_AGENT=""
  BRIDGE_MIGRATION_DRY_RUN=0
  BRIDGE_MIGRATION_SHOW_HELP=0
  BRIDGE_MIGRATION_INSTALL_SUDOERS=0
  BRIDGE_MIGRATION_REAPPLY=0

  while [[ $# -gt 0 ]]; do
    case "$1" in
      --dry-run)
        BRIDGE_MIGRATION_DRY_RUN=1
        shift
        ;;
      --install-sudoers)
        BRIDGE_MIGRATION_INSTALL_SUDOERS=1
        shift
        ;;
      --reapply)
        BRIDGE_MIGRATION_REAPPLY=1
        shift
        ;;
      -h|--help)
        BRIDGE_MIGRATION_SHOW_HELP=1
        shift
        ;;
      --)
        shift
        break
        ;;
      -*)
        bridge_die "unknown option: $1"
        ;;
      *)
        if [[ -z "$BRIDGE_MIGRATION_AGENT" ]]; then
          BRIDGE_MIGRATION_AGENT="$1"
        else
          bridge_die "unexpected extra argument: $1"
        fi
        shift
        ;;
    esac
  done
}

bridge_migration_sudoers_entry() {
  local operator="$1"
  local os_user="$2"
  local tmux_bin bash_bin
  tmux_bin="$(command -v tmux 2>/dev/null || printf '/usr/bin/tmux')"
  bash_bin="$(command -v bash 2>/dev/null || printf '/bin/bash')"
  # SETENV: required so --preserve-env=... can forward BRIDGE_STATE_DIR /
  # BRIDGE_TASK_DB / CRON_REQUEST_DIR etc. to the isolated child (issue #219
  # memory-daily harvester sudo re-exec). tmux + bash are the only binaries
  # sudo ever invokes directly; Python is spawned as a child of bash -c.
  printf '%s ALL=(%s) NOPASSWD: SETENV: %s, %s\n' "$operator" "$os_user" "$tmux_bin" "$bash_bin"
}

bridge_migration_install_sudoers() {
  local dry_run="$1"
  local os_user="$2"
  local operator="${3:-$(bridge_current_user)}"
  local entry target tmpfile

  [[ -n "$os_user" ]] || return 0
  target="/etc/sudoers.d/agent-bridge-${os_user}"
  entry="$(bridge_migration_sudoers_entry "$operator" "$os_user")"

  printf '[sudoers] planned entry for %s:\n' "$target"
  printf '          %s' "$entry"
  if [[ "$dry_run" == "1" ]]; then
    printf '[dry-run] skipping sudoers install; re-run without --dry-run to apply.\n'
    return 0
  fi

  if ! command -v visudo >/dev/null 2>&1; then
    bridge_warn "visudo not found; skipping sudoers install. Add this entry manually to $target:"
    printf '  %s' "$entry" >&2
    return 1
  fi

  tmpfile="$(mktemp)" || bridge_die "failed to create temp file for sudoers validation"
  printf '%s' "$entry" >"$tmpfile"
  if ! visudo -cf "$tmpfile" >/dev/null 2>&1; then
    rm -f "$tmpfile"
    bridge_die "generated sudoers entry failed visudo -cf validation (operator=$operator os_user=$os_user)"
  fi

  bridge_linux_sudo_root install -m 0440 -o root -g root "$tmpfile" "$target"
  rm -f "$tmpfile"
  printf '[sudoers] installed %s (mode 0440)\n' "$target"
}

bridge_migration_print_sudoers_hint() {
  local os_user="$1"
  local operator="${2:-$(bridge_current_user)}"
  local entry
  entry="$(bridge_migration_sudoers_entry "$operator" "$os_user")"
  printf '[hint] To enable UID switch on agent launch, install a sudoers drop-in at /etc/sudoers.d/agent-bridge-%s containing:\n' "$os_user"
  printf '         %s' "$entry"
  printf '       Re-run this command with --install-sudoers to apply it automatically (after visudo validation).\n'
  printf '       See docs/linux-host-acceptance.md for the full migration runbook.\n'
}

bridge_migration_isolate_cli() {
  bridge_migration_parse_args "$@"
  if [[ "${BRIDGE_MIGRATION_SHOW_HELP:-0}" == "1" ]]; then
    cat <<'EOF'
Usage: agent-bridge isolate <agent> [--dry-run] [--install-sudoers] [--reapply]

Migrate a static agent from shared isolation to linux-user isolation.
On macOS this command refuses with a pointer to #89 for scope.

Steps (planned; --dry-run prints without executing):
  1. Verify agent is declared and currently in shared mode.
  2. Verify no live tmux session is running (operator must stop first).
  3. useradd --system --home-dir <bridge_isolated_user_home_root>/<os_user> --shell /usr/sbin/nologin
  4. Chown the agent workdir, runtime state dir, and log dir to the new OS user.
  5. Install $user_home/.agent-bridge symlink into $BRIDGE_HOME.
  6. Write isolation_mode=linux-user + os_user=<slug> to the local roster.

Options:
  --install-sudoers  Also install /etc/sudoers.d/agent-bridge-<os_user> so
                     'agent-bridge agent start <agent>' can sudo -u the
                     dedicated OS user without a password prompt. The entry
                     is validated with visudo -cf before install. When
                     omitted, the exact required entry is printed so the
                     operator can install it manually (see
                     docs/linux-host-acceptance.md).

  --reapply          Skip the ownership migration and only re-install the
                     per-agent ACLs (idempotent). Required to pick up
                     ACL-contract changes on already-isolated agents without
                     going through unisolate→isolate. Works with --dry-run.

Re-running without --reapply on an already-isolated agent is a no-op.
EOF
    return 0
  fi
  [[ -n "$BRIDGE_MIGRATION_AGENT" ]] || bridge_die "Usage: agent-bridge isolate <agent> [--dry-run] [--install-sudoers] [--reapply]"
  bridge_migration_isolate "$BRIDGE_MIGRATION_AGENT" "$BRIDGE_MIGRATION_DRY_RUN" "$BRIDGE_MIGRATION_INSTALL_SUDOERS" "${BRIDGE_MIGRATION_REAPPLY:-0}"
}

bridge_migration_unisolate_cli() {
  bridge_migration_parse_args "$@"
  if [[ "${BRIDGE_MIGRATION_SHOW_HELP:-0}" == "1" ]]; then
    cat <<'EOF'
Usage: agent-bridge unisolate <agent> [--dry-run]

Revert a static agent from linux-user isolation back to shared mode.

Steps (planned; --dry-run prints without executing):
  1. Verify agent is declared and currently in linux-user mode.
  2. Verify no live tmux session is running (operator must stop first).
  3. Chown workdir, runtime state dir, and log dir back to the controller user.
  4. Clear isolation_mode + os_user from the local roster.

The dedicated OS user is preserved; a cleanup command is printed so the
operator can delete it manually once they have confirmed nothing else
depends on it.
EOF
    return 0
  fi
  [[ -n "$BRIDGE_MIGRATION_AGENT" ]] || bridge_die "Usage: agent-bridge unisolate <agent> [--dry-run]"
  bridge_migration_unisolate "$BRIDGE_MIGRATION_AGENT" "$BRIDGE_MIGRATION_DRY_RUN"
}
