#!/usr/bin/env bash
# bridge-auth.sh — manage Agent Bridge authentication material.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-auth.sh claude-token add --id <id> (--stdin|--token-file <path>) [--activate] [--replace] [--sync] [--agents static|all|csv] [--enable-auto-rotate] [--threshold 99] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token list [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token activate <id> [--sync] [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token sync [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token rotate [--if-auto-enabled] [--reason <text>] [--sync] [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token check <id> [--enable-on-ok] [--disable-on-quota] [--timeout <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token recover-due [--timeout <sec>] [--retry-seconds <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token auto-rotate <enable|disable|status> [--threshold 99] [--json]
EOF
}

bridge_auth_registry_path() {
  printf '%s' "${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"
}

bridge_auth_run_privileged() {
  if declare -F _bridge_isolation_v2_run_root_or_sudo >/dev/null 2>&1; then
    _bridge_isolation_v2_run_root_or_sudo "$@"
    return $?
  fi
  "$@" 2>/dev/null && return 0
  bridge_linux_sudo_root "$@"
}

bridge_auth_legacy_secret_env_file_for_agent() {
  local agent="$1"
  local file=""
  if bridge_isolation_v2_active 2>/dev/null; then
    file="$(bridge_isolation_v2_agent_secret_env_file "$agent" 2>/dev/null || true)"
  fi
  if [[ -z "$file" ]]; then
    file="$BRIDGE_AGENT_HOME_ROOT/$agent/credentials/launch-secrets.env"
  fi
  printf '%s' "$file"
}

bridge_auth_resolved_user_home_for_agent() {
  # Resolve the user home that the credential file should live under,
  # following the same rule as bridge_auth_claude_credentials_file_for_agent
  # but without appending the `.claude/.credentials.json` tail. Used as the
  # ``allowed_root`` argument for symlink hardening so the resolved
  # ``.claude`` directory must stay inside the agent's own home.
  local agent="$1"
  local os_user=""
  local user_home=""
  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    if [[ -n "$os_user" ]]; then
      user_home="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || true)"
      if [[ -n "$user_home" ]]; then
        printf '%s' "$user_home"
        return 0
      fi
    fi
  fi
  bridge_agent_default_home "$agent"
}

bridge_auth_verify_safe_claude_dir() {
  # PR #799 r2 codex finding 2 — reject any non-real ``.claude/`` (symlink,
  # file, or path that resolves outside the isolated home). The agent owns
  # its own home, so it can pre-place ``.claude`` as a symlink to anywhere
  # on disk; a privileged write would then clobber the symlink target. This
  # helper rejects those cases before any mkdir / chown / write happens.
  #
  # Both the user-home and the resolved claude dir are passed through
  # ``cd -P`` so per-platform symlink prefixes (e.g. macOS
  # ``/var`` -> ``/private/var``) do not produce false rejections on the
  # prefix match.
  local agent="$1"
  local user_home="$2"
  local claude_dir="$user_home/.claude"
  local resolved_home=""
  local resolved=""
  if [[ ! -e "$claude_dir" && ! -L "$claude_dir" ]]; then
    return 0
  fi
  if [[ -L "$claude_dir" ]]; then
    printf '[error] %s is a symlink — refusing to write through it (agent=%s)\n' \
      "$claude_dir" "$agent" >&2
    return 1
  fi
  if [[ ! -d "$claude_dir" ]]; then
    printf '[error] %s exists but is not a directory (agent=%s)\n' \
      "$claude_dir" "$agent" >&2
    return 1
  fi
  resolved_home="$(cd -P "$user_home" 2>/dev/null && pwd -P)" || {
    printf '[error] cannot resolve agent home: %s (agent=%s)\n' "$user_home" "$agent" >&2
    return 1
  }
  resolved="$(cd -P "$claude_dir" 2>/dev/null && pwd -P)" || {
    printf '[error] cannot resolve %s (agent=%s)\n' "$claude_dir" "$agent" >&2
    return 1
  }
  case "$resolved/" in
    "$resolved_home/"*) : ;;
    *)
      printf '[error] %s resolves outside isolated home: %s (home=%s, agent=%s)\n' \
        "$claude_dir" "$resolved" "$resolved_home" "$agent" >&2
      return 1
      ;;
  esac
  return 0
}

bridge_auth_claude_credentials_file_for_agent() {
  local agent="$1"
  local user_home=""
  user_home="$(bridge_auth_resolved_user_home_for_agent "$agent")" || return 1
  [[ -n "$user_home" ]] || {
    printf '[error] cannot resolve user home for agent: %s\n' "$agent" >&2
    return 1
  }
  bridge_auth_verify_safe_claude_dir "$agent" "$user_home" || return 1
  printf '%s/.claude/.credentials.json' "$user_home"
}

bridge_auth_prepare_credential_file() {
  local agent="$1"
  local file="$2"
  local dir=""
  local user_home=""
  local os_user=""
  local os_group=""

  dir="$(dirname "$file")"
  user_home="$(bridge_auth_resolved_user_home_for_agent "$agent")" || return 1
  bridge_auth_verify_safe_claude_dir "$agent" "$user_home" || return 1
  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    [[ -n "$os_user" ]] || {
      printf '[error] cannot resolve isolated os_user for agent: %s\n' "$agent" >&2
      return 1
    }
    os_group="$(id -gn "$os_user" 2>/dev/null || printf '%s' "$os_user")"
    if ! bridge_auth_run_privileged test -d "$dir"; then
      # PR #799 r2 codex finding 2 — verify_safe_claude_dir above already
      # rejected pre-existing symlinks / non-dirs. The ``mkdir -p`` here is
      # safe because the parent ``$user_home`` is the privileged-owned
      # isolated root and ``.claude`` does not yet exist.
      bridge_auth_run_privileged mkdir -p "$dir" || {
        printf '[error] cannot create Claude credentials dir: %s\n' "$dir" >&2
        return 1
      }
      bridge_auth_run_privileged chown "$os_user:$os_group" "$dir" || return 1
      bridge_auth_run_privileged chmod 0700 "$dir" || return 1
    fi
    return 0
  fi
  if [[ ! -d "$dir" ]]; then
    mkdir -p "$dir" || {
      printf '[error] cannot create Claude credentials dir: %s\n' "$dir" >&2
      return 1
    }
  fi
  chmod 0700 "$dir" 2>/dev/null || true
}

bridge_auth_fix_credential_file_mode() {
  local agent="$1"
  local file="$2"
  local config_file=""
  local settings_file=""
  local os_user=""
  local os_group=""

  config_file="$(dirname "$file")/.claude.json"
  settings_file="$(dirname "$file")/settings.json"
  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    [[ -n "$os_user" ]] || {
      printf '[error] cannot resolve isolated os_user for agent: %s\n' "$agent" >&2
      return 1
    }
    os_group="$(id -gn "$os_user" 2>/dev/null || printf '%s' "$os_user")"
    bridge_auth_run_privileged chown "$os_user:$os_group" "$file" || return 1
    bridge_auth_run_privileged chmod 0600 "$file" || return 1
    if bridge_auth_run_privileged test -f "$config_file"; then
      bridge_auth_run_privileged chown "$os_user:$os_group" "$config_file" || return 1
      bridge_auth_run_privileged chmod 0600 "$config_file" || return 1
    fi
    if bridge_auth_run_privileged test -e "$settings_file"; then
      bridge_auth_run_privileged chown "$os_user:$os_group" "$settings_file" || return 1
    fi
    return 0
  fi
  chmod 0600 "$file" 2>/dev/null || bridge_auth_run_privileged chmod 0600 "$file"
  if [[ -f "$config_file" ]]; then
    chmod 0600 "$config_file" 2>/dev/null || bridge_auth_run_privileged chmod 0600 "$config_file"
  fi
}

bridge_auth_update_legacy_claude_config_env() {
  local agent="$1"
  local file="$2"
  local config_dir="$3"
  local dir=""

  dir="$(dirname "$file")"
  if [[ ! -d "$dir" ]]; then
    bridge_auth_run_privileged mkdir -p "$dir" || {
      printf '[error] cannot create legacy launch env dir: %s\n' "$dir" >&2
      return 1
    }
  fi
  python3 - "$file" "$config_dir" <<'PY'
import os
import sys
import tempfile
from pathlib import Path

path = Path(sys.argv[1])
config_dir = sys.argv[2]
key = "CLAUDE_CODE_OAUTH_TOKEN="
config_key = "CLAUDE_CONFIG_DIR="
lines = path.read_text(encoding="utf-8", errors="ignore").splitlines() if path.exists() else []
filtered = [
    line
    for line in lines
    if not line.strip().startswith(key)
    and not line.strip().startswith(config_key)
]
if "'" in config_dir:
    raise SystemExit("CLAUDE_CONFIG_DIR path cannot contain single quote")
filtered.append(f"CLAUDE_CONFIG_DIR='{config_dir}'")
text = "\n".join(filtered)
if text:
    text += "\n"
fd = -1
tmp_name = ""
try:
    fd, tmp_name = tempfile.mkstemp(prefix=".launch-secrets.", suffix=".tmp", dir=str(path.parent))
    with os.fdopen(fd, "w", encoding="utf-8") as fh:
        fd = -1
        fh.write(text)
        fh.flush()
        os.fsync(fh.fileno())
    os.replace(tmp_name, path)
finally:
    if fd >= 0:
        os.close(fd)
    if tmp_name:
        try:
            os.unlink(tmp_name)
        except FileNotFoundError:
            pass
PY
  bridge_auth_fix_legacy_secret_file_mode "$agent" "$file"
}

bridge_auth_fix_legacy_secret_file_mode() {
  local agent="$1"
  local file="$2"
  local group=""
  local file_mode="0600"

  if bridge_isolation_v2_active 2>/dev/null; then
    group="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || true)"
    if [[ -n "$group" ]] && bridge_isolation_v2_group_exists "$group"; then
      file_mode="0640"
      bridge_auth_run_privileged chown "$(id -un):$group" "$file" || return 1
    elif [[ "${BRIDGE_CLAUDE_TOKEN_SYNC_ALLOW_CURRENT_GROUP_FALLBACK:-0}" != "1" ]]; then
      printf '[error] v2 group missing after legacy secret scrub for %s: %s\n' "$agent" "$group" >&2
      return 1
    fi
  fi
  chmod "$file_mode" "$file" 2>/dev/null || bridge_auth_run_privileged chmod "$file_mode" "$file"
}

bridge_auth_sync_agent_python() {
  local agent="$1"
  local registry="$2"
  local file="$3"
  local workdir=""
  local user_home=""
  local os_user=""
  local owner_uid=""
  local owner_gid=""
  local -a workdir_args=()
  local -a owner_args=()

  workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -n "$workdir" ]] && workdir_args=(--workdir "$workdir")

  # PR #799 r2 codex findings 2 + 3 — pass the isolated UID/GID + allowed
  # filesystem root to Python so:
  #   - the credential / config / settings tempfiles are chowned to the
  #     target UID BEFORE ``os.replace`` (no transient root-owned window);
  #   - the symlink rejection + realpath-stays-inside-home check runs on
  #     the Python side too, not only in the bash wrapper.
  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    if [[ -n "$os_user" ]]; then
      owner_uid="$(id -u "$os_user" 2>/dev/null || true)"
      owner_gid="$(id -g "$os_user" 2>/dev/null || true)"
      user_home="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || true)"
      if [[ -n "$owner_uid" ]]; then
        owner_args+=(--owner-uid "$owner_uid")
      fi
      if [[ -n "$owner_gid" ]]; then
        owner_args+=(--owner-gid "$owner_gid")
      fi
      if [[ -n "$user_home" ]]; then
        owner_args+=(--allowed-root "$user_home")
      fi
    fi
    bridge_linux_sudo_root python3 "$SCRIPT_DIR/bridge-auth.py" \
      --registry "$registry" sync-agent --agent "$agent" --file "$file" \
      "${workdir_args[@]}" "${owner_args[@]}" --json
    return $?
  fi
  # Non-isolated dev install — Python still gets the agent's resolved home as
  # ``--allowed-root`` so the symlink-reject defense applies there too, but
  # no chown args (caller UID already owns the file).
  user_home="$(bridge_auth_resolved_user_home_for_agent "$agent" 2>/dev/null || true)"
  if [[ -n "$user_home" ]]; then
    owner_args+=(--allowed-root "$user_home")
  fi
  python3 "$SCRIPT_DIR/bridge-auth.py" \
    --registry "$registry" sync-agent --agent "$agent" --file "$file" \
    "${workdir_args[@]}" "${owner_args[@]}" --json
}

bridge_auth_selected_agents() {
  local spec="${1:-static}"
  local agent=""
  local item=""
  local -a explicit=()

  case "$spec" in
    static|"")
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    all|claude)
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    *)
      IFS=',' read -r -a explicit <<<"$spec"
      for item in "${explicit[@]}"; do
        item="${item#"${item%%[![:space:]]*}"}"
        item="${item%"${item##*[![:space:]]}"}"
        [[ -n "$item" ]] || continue
        bridge_agent_exists "$item" || {
          printf '[error] unknown agent: %s\n' "$item" >&2
          return 1
        }
        [[ "$(bridge_agent_engine "$item")" == "claude" ]] || {
          printf '[error] agent is not a Claude agent: %s\n' "$item" >&2
          return 1
        }
        printf '%s\n' "$item"
      done
      ;;
  esac
}

bridge_auth_sync_agents() {
  local registry="$1"
  local spec="$2"
  local json_mode="$3"
  local agent=""
  local file=""
  local legacy_file=""
  local output=""
  local selection_output=""
  local selection_error=""
  local rc=0
  local -a agents=()
  local -a synced=()
  local -a failed=()

  selection_error="$(mktemp -t agb-auth-select.XXXXXX 2>/dev/null || printf '%s' "/tmp/agb-auth-select.$$.$RANDOM")"
  if ! selection_output="$(bridge_auth_selected_agents "$spec" 2>"$selection_error")"; then
    if [[ "$json_mode" == "1" ]]; then
      python3 - "$selection_error" <<'PY'
import json
import sys
from pathlib import Path

error = Path(sys.argv[1]).read_text(encoding="utf-8", errors="ignore").strip() or "agent selection failed"
print(json.dumps({"status": "failed", "agents": [], "failed": [{"agent": "", "error": error}]}, ensure_ascii=True, indent=2))
PY
    else
      cat "$selection_error" >&2
    fi
    rm -f "$selection_error"
    return 1
  fi
  rm -f "$selection_error"
  if [[ -n "$selection_output" ]]; then
    mapfile -t agents <<<"$selection_output"
  fi
  if (( ${#agents[@]} == 0 )); then
    if [[ "$json_mode" == "1" ]]; then
      python3 - <<'PY'
import json
print(json.dumps({"status": "skipped", "reason": "no_matching_claude_agents", "agents": [], "failed": []}, indent=2))
PY
    else
      printf 'skipped: no_matching_claude_agents\n'
    fi
    return 0
  fi

  for agent in "${agents[@]}"; do
    file="$(bridge_auth_claude_credentials_file_for_agent "$agent")" || {
      failed+=("$agent:credential_path_rejected")
      rc=1
      continue
    }
    legacy_file="$(bridge_auth_legacy_secret_env_file_for_agent "$agent")"
    if ! bridge_auth_prepare_credential_file "$agent" "$file"; then
      failed+=("$agent:prepare_failed")
      rc=1
      continue
    fi
    if ! output="$(bridge_auth_sync_agent_python "$agent" "$registry" "$file" 2>&1)"; then
      failed+=("$agent:$output")
      rc=1
      continue
    fi
    # PR #799 r2 codex finding 3 — Python wrote the tempfile, chowned it to
    # the isolated UID, then ``os.replace``-d into final path. The file is
    # never root-owned at its final path so the post-sync chown repair
    # below is now a defense-in-depth assertion: it re-applies mode/owner
    # on legacy installs where stale root-owned files may pre-exist. It is
    # no longer load-bearing for fresh rotations.
    if ! bridge_auth_fix_credential_file_mode "$agent" "$file"; then
      failed+=("$agent:mode_failed")
      rc=1
      continue
    fi
    if ! bridge_auth_update_legacy_claude_config_env "$agent" "$legacy_file" "$(dirname "$file")"; then
      failed+=("$agent:legacy_env_update_failed")
      rc=1
      continue
    fi
    synced+=("$agent")
    [[ "$json_mode" == "1" ]] || printf 'synced: %s -> %s\n' "$agent" "$file"
  done

  if [[ "$json_mode" == "1" ]]; then
    python3 - "${synced[@]}" -- "${failed[@]}" <<'PY'
import json
import sys

items = sys.argv[1:]
sep = items.index("--") if "--" in items else len(items)
synced = items[:sep]
failed_raw = items[sep + 1 :]
failed = []
for row in failed_raw:
    if ":" in row:
        agent, error = row.split(":", 1)
    else:
        agent, error = row, "failed"
    failed.append({"agent": agent, "error": error})
status = "ok" if not failed else ("failed" if not synced else "partial")
print(json.dumps({"status": status, "agents": synced, "failed": failed}, ensure_ascii=True, indent=2))
PY
  fi
  return "$rc"
}

bridge_auth_json_requested() {
  local arg=""
  for arg in "$@"; do
    [[ "$arg" == "--json" ]] && return 0
  done
  return 1
}

bridge_auth_sync_requested() {
  local arg=""
  for arg in "$@"; do
    [[ "$arg" == "--sync" ]] && return 0
  done
  return 1
}

bridge_auth_agents_arg() {
  local default="${BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS:-static}"
  while [[ $# -gt 0 ]]; do
    case "$1" in
      --agents)
        [[ $# -ge 2 ]] || {
          printf '[error] --agents requires a value\n' >&2
          return 1
        }
        printf '%s' "$2"
        return 0
        ;;
    esac
    shift
  done
  printf '%s' "$default"
}

bridge_auth_emit_combined_json() {
  local op_json="$1"
  local sync_json="$2"
  python3 - "$op_json" "$sync_json" <<'PY'
import json
import sys

op = json.loads(sys.argv[1])
sync = json.loads(sys.argv[2])
op["sync"] = sync
print(json.dumps(op, ensure_ascii=True, indent=2))
PY
}

command="${1:-}"
[[ -n "$command" ]] || {
  usage
  exit 1
}
shift || true

case "$command" in
  claude-token)
    subcommand="${1:-}"
    [[ -n "$subcommand" ]] || {
      usage
      exit 1
    }
    shift || true
    registry="$(bridge_auth_registry_path)"
    case "$subcommand" in
      add|activate)
        json_mode=0
        sync_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        bridge_auth_sync_requested "$@" && sync_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        op_json=""
        if [[ "$json_mode" == "1" ]]; then
          op_json="$(python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@")"
          if [[ "$sync_mode" == "1" ]]; then
            sync_rc=0
            sync_json="$(bridge_auth_sync_agents "$registry" "$agents_spec" 1)" || sync_rc=$?
            bridge_auth_emit_combined_json "$op_json" "$sync_json"
            exit "$sync_rc"
          else
            printf '%s\n' "$op_json"
          fi
        else
          python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@"
          if [[ "$sync_mode" == "1" ]]; then
            bridge_auth_sync_agents "$registry" "$agents_spec" 0
          fi
        fi
        ;;
      list|auto-rotate|check|recover-due)
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@"
        ;;
      sync)
        json_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        bridge_auth_sync_agents "$registry" "$agents_spec" "$json_mode"
        ;;
      rotate)
        json_mode=0
        sync_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        bridge_auth_sync_requested "$@" && sync_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        if [[ "$json_mode" == "1" ]]; then
          op_json="$(python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" rotate "$@")"
          rotate_status="$(python3 - "$op_json" <<'PY'
import json, sys
try:
    print(json.loads(sys.argv[1]).get("status", ""))
except Exception:
    print("")
PY
)"
          if [[ "$sync_mode" == "1" && "$rotate_status" == "rotated" ]]; then
            sync_rc=0
            sync_json="$(bridge_auth_sync_agents "$registry" "$agents_spec" 1)" || sync_rc=$?
            bridge_auth_emit_combined_json "$op_json" "$sync_json"
            exit "$sync_rc"
          else
            printf '%s\n' "$op_json"
          fi
        else
          python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" rotate "$@"
          if [[ "$sync_mode" == "1" ]]; then
            bridge_auth_sync_agents "$registry" "$agents_spec" 0
          fi
        fi
        ;;
      -h|--help|help)
        usage
        ;;
      *)
        usage >&2
        exit 1
        ;;
    esac
    ;;
  -h|--help|help)
    usage
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
