#!/usr/bin/env bash
# shellcheck shell=bash

bridge_agent_project_root() {
  local agent="$1"
  bridge_project_root_for_path "$(bridge_agent_workdir "$agent")"
}

bridge_history_file_for_agent() {
  local agent="$1"
  bridge_history_file_for "$(bridge_agent_engine "$agent")" "$agent" "$(bridge_agent_workdir "$agent")"
}

bridge_agent_history_exists() {
  local agent="$1"
  local file

  file="$(bridge_history_file_for_agent "$agent")"
  [[ -f "$file" ]]
}

bridge_worktree_slug_for_project() {
  local project_root="$1"
  local base
  local hash

  base="$(basename "$project_root")"
  base="${base//[^A-Za-z0-9._-]/-}"
  hash="$(bridge_sha1 "$project_root")"
  printf '%s-%s' "$base" "${hash:0:8}"
}

bridge_worktree_branch_for_agent() {
  local agent="$1"
  local branch

  branch="$agent"
  branch="${branch//[^A-Za-z0-9._-]/-}"
  printf 'agent-bridge/%s' "$branch"
}

bridge_worktree_root_for() {
  local project_root="$1"
  local agent="$2"
  local slug

  slug="$(bridge_worktree_slug_for_project "$project_root")"
  printf '%s/%s/%s' "$BRIDGE_WORKTREE_ROOT" "$slug" "$agent"
}

bridge_worktree_launch_dir_for() {
  local source_workdir="$1"
  local agent="$2"
  local project_root relpath worktree_root

  project_root="$(bridge_project_root_for_path "$source_workdir")"
  relpath="$(bridge_path_relative_to_root "$source_workdir" "$project_root")"
  worktree_root="$(bridge_worktree_root_for "$project_root" "$agent")"

  if [[ "$relpath" == "." ]]; then
    printf '%s' "$worktree_root"
  else
    printf '%s/%s' "$worktree_root" "$relpath"
  fi
}

bridge_worktree_meta_key() {
  local project_root="$1"
  local agent="$2"
  bridge_sha1 "${project_root}|${agent}"
}

bridge_worktree_meta_file_for() {
  local project_root="$1"
  local agent="$2"
  local key

  key="$(bridge_worktree_meta_key "$project_root" "$agent")"
  printf '%s/%s--%s.env' "$BRIDGE_WORKTREE_META_DIR" "$agent" "${key:0:12}"
}

bridge_write_worktree_metadata() {
  local engine="$1"
  local agent="$2"
  local source_workdir="$3"
  local project_root="$4"
  local worktree_root="$5"
  local worktree_workdir="$6"
  local branch="$7"
  local meta_file
  local relpath
  local created_at
  local updated_at

  meta_file="$(bridge_worktree_meta_file_for "$project_root" "$agent")"
  relpath="$(bridge_path_relative_to_root "$source_workdir" "$project_root")"
  created_at="$(date +%s)"
  updated_at="$(bridge_now_iso)"

  mkdir -p "$(dirname "$meta_file")"
  cat >"$meta_file" <<EOF
WORKTREE_AGENT=$(printf '%q' "$agent")
WORKTREE_ENGINE=$(printf '%q' "$engine")
WORKTREE_SOURCE_WORKDIR=$(printf '%q' "$source_workdir")
WORKTREE_PROJECT_ROOT=$(printf '%q' "$project_root")
WORKTREE_RELATIVE_DIR=$(printf '%q' "$relpath")
WORKTREE_ROOT=$(printf '%q' "$worktree_root")
WORKTREE_WORKDIR=$(printf '%q' "$worktree_workdir")
WORKTREE_BRANCH=$(printf '%q' "$branch")
WORKTREE_CREATED_AT=$(printf '%q' "$created_at")
WORKTREE_UPDATED_AT=$(printf '%q' "$updated_at")
EOF
}

bridge_list_worktrees() {
  local file
  local WORKTREE_AGENT=""
  local WORKTREE_ENGINE=""
  local WORKTREE_PROJECT_ROOT=""
  local WORKTREE_ROOT=""
  local WORKTREE_WORKDIR=""
  local WORKTREE_BRANCH=""
  local active
  local printed=0

  shopt -s nullglob
  for file in "$BRIDGE_WORKTREE_META_DIR"/*.env; do
    WORKTREE_AGENT=""
    WORKTREE_ENGINE=""
    WORKTREE_PROJECT_ROOT=""
    WORKTREE_ROOT=""
    WORKTREE_WORKDIR=""
    WORKTREE_BRANCH=""
    # shellcheck source=/dev/null
    source "$file"
    [[ -z "$WORKTREE_AGENT" ]] && continue
    printed=1
    active="no"
    if bridge_agent_exists "$WORKTREE_AGENT" && bridge_agent_is_active "$WORKTREE_AGENT"; then
      active="yes"
    fi
    printf '%s | engine=%s | active=%s | branch=%s | repo=%s | root=%s | workdir=%s\n' \
      "$WORKTREE_AGENT" \
      "${WORKTREE_ENGINE:-unknown}" \
      "$active" \
      "${WORKTREE_BRANCH:--}" \
      "${WORKTREE_PROJECT_ROOT:--}" \
      "${WORKTREE_ROOT:--}" \
      "${WORKTREE_WORKDIR:--}"
  done
  shopt -u nullglob

  if [[ "$printed" == "0" ]]; then
    echo "(등록된 agent-bridge worktree 없음)"
  fi
}

bridge_static_agents_for_project_engine() {
  local project_root="$1"
  local engine="$2"
  local agent
  local agent_root

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
    [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
    agent_root="$(bridge_agent_project_root "$agent")"
    [[ "$agent_root" == "$project_root" ]] || continue
    printf '%s\n' "$agent"
  done
}

bridge_source_repo_is_dirty() {
  local project_root="$1"
  [[ -n "$(git -C "$project_root" status --short 2>/dev/null || true)" ]]
}

bridge_prepare_isolated_worktree() {
  local engine="$1"
  local agent="$2"
  local source_workdir="$3"
  local project_root worktree_root worktree_workdir branch

  project_root="$(bridge_project_root_for_path "$source_workdir")"
  if ! git -C "$project_root" rev-parse --show-toplevel >/dev/null 2>&1; then
    bridge_die "git 프로젝트에서만 isolated worktree를 만들 수 있습니다: $source_workdir"
  fi

  worktree_root="$(bridge_worktree_root_for "$project_root" "$agent")"
  worktree_workdir="$(bridge_worktree_launch_dir_for "$source_workdir" "$agent")"
  branch="$(bridge_worktree_branch_for_agent "$agent")"

  if [[ -d "$worktree_root/.git" || -f "$worktree_root/.git" ]]; then
    bridge_write_worktree_metadata "$engine" "$agent" "$source_workdir" "$project_root" "$worktree_root" "$worktree_workdir" "$branch"
    printf '%s' "$worktree_workdir"
    return 0
  fi

  mkdir -p "$(dirname "$worktree_root")"
  if bridge_source_repo_is_dirty "$project_root"; then
    bridge_warn "원본 작업트리에 미커밋 변경이 있습니다. 새 worktree는 현재 HEAD 기준으로 생성됩니다: $project_root"
  fi

  if git -C "$project_root" show-ref --verify --quiet "refs/heads/$branch"; then
    git -C "$project_root" worktree add "$worktree_root" "$branch" >/dev/null
  else
    git -C "$project_root" worktree add -b "$branch" "$worktree_root" HEAD >/dev/null
  fi

  bridge_write_worktree_metadata "$engine" "$agent" "$source_workdir" "$project_root" "$worktree_root" "$worktree_workdir" "$branch"
  printf '%s' "$worktree_workdir"
}

bridge_infer_current_agent() {
  local session=""
  local current_dir
  local agent
  local match=""

  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || return 1

  if [[ -n "${BRIDGE_AGENT_ID:-}" ]] && bridge_agent_exists "$BRIDGE_AGENT_ID"; then
    printf '%s' "$BRIDGE_AGENT_ID"
    return 0
  fi

  if [[ -n "${TMUX:-}" ]]; then
    session="$(tmux display-message -p '#S' 2>/dev/null || true)"
    if [[ -n "$session" ]] && bridge_agent_exists "$session"; then
      printf '%s' "$session"
      return 0
    fi
  fi

  current_dir="$(pwd -P)"
  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_workdir "$agent")" == "$current_dir" ]]; then
      if [[ -n "$match" ]]; then
        return 1
      fi
      match="$agent"
    fi
  done

  if [[ -n "$match" ]]; then
    printf '%s' "$match"
    return 0
  fi

  return 1
}

bridge_resolve_agent() {
  local requested="${1:-}"
  local resolved=""

  if [[ -n "$requested" ]]; then
    bridge_require_agent "$requested"
    printf '%s' "$requested"
    return 0
  fi

  if resolved="$(bridge_infer_current_agent)"; then
    printf '%s' "$resolved"
    return 0
  fi

  bridge_die "에이전트를 자동 추론할 수 없습니다. --agent 또는 명시적 agent 인자를 사용하세요."
}

bridge_admin_agent_id() {
  printf '%s' "${BRIDGE_ADMIN_AGENT_ID:-}"
}

bridge_agent_is_admin() {
  local agent="$1"
  local admin_agent=""

  admin_agent="$(bridge_admin_agent_id)"
  [[ -n "$admin_agent" && "$agent" == "$admin_agent" ]]
}

bridge_agent_exists() {
  local agent="$1"
  declare -p BRIDGE_AGENT_SESSION >/dev/null 2>&1 || return 1
  [[ -n "${BRIDGE_AGENT_SESSION[$agent]+x}" ]]
}

bridge_agent_is_static() {
  local agent="$1"
  [[ "$(bridge_agent_source "$agent")" == "static" ]]
}

bridge_agent_is_launchable_static() {
  local agent="$1"
  bridge_agent_exists "$agent" && bridge_agent_is_static "$agent"
}

bridge_agent_is_cron_delivery_target() {
  local agent="$1"

  bridge_agent_exists "$agent" || return 1
  if bridge_agent_is_static "$agent"; then
    return 0
  fi
  bridge_profile_has_source "$agent"
}

bridge_require_agent() {
  local agent="$1"

  if bridge_agent_exists "$agent"; then
    return 0
  fi

  echo "등록된 에이전트:"
  bridge_list_agents >&2
  bridge_die "'$agent'은(는) 등록된 에이전트가 아닙니다."
}

bridge_require_static_agent() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_static "$agent"; then
    bridge_die "'$agent'은(는) 정적 역할이 아닙니다. 관리자 에이전트는 정적 역할로 설정하세요."
  fi
}

bridge_require_launchable_static_agent() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_launchable_static "$agent"; then
    bridge_die "'$agent'은(는) cron delivery 대상이 될 수 있는 정적 역할이 아닙니다."
  fi
}

bridge_require_cron_delivery_target() {
  local agent="$1"

  bridge_require_agent "$agent"
  if ! bridge_agent_is_cron_delivery_target "$agent"; then
    bridge_die "'$agent'은(는) cron delivery 대상이 될 수 있는 등록된 장기 역할이 아닙니다."
  fi
}

bridge_require_admin_agent() {
  local agent

  agent="$(bridge_admin_agent_id)"
  if [[ -z "$agent" ]]; then
    bridge_die "관리자 에이전트가 설정되지 않았습니다. 'agent-bridge setup admin <agent>' 또는 BRIDGE_ADMIN_AGENT_ID를 설정하세요."
  fi

  bridge_require_static_agent "$agent"
  printf '%s' "$agent"
}

bridge_agent_id_for_session() {
  local requested_session="$1"
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if [[ "$(bridge_agent_session "$agent")" == "$requested_session" ]]; then
      printf '%s' "$agent"
      return 0
    fi
  done

  return 1
}

bridge_agent_desc() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_DESC[$agent]-}"
}

bridge_agent_engine() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_ENGINE[$agent]-unknown}"
}

bridge_agent_source() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SOURCE[$agent]-static}"
}

# Issue #539: agent class is the privilege boundary consumed by
# hooks/tool-policy.py. The closed value space is {user, system}; any
# unknown value (including the empty string written by older roster
# snapshots) is normalized to "user" so the default-deny posture for
# cross-agent reads is preserved on rosters that predate this field.
# Validation of operator-supplied class= values happens at roster-load
# time via bridge_validate_agent_class — this getter is the read-side
# fallback.
bridge_agent_class() {
  local agent="$1"
  local cls="${BRIDGE_AGENT_CLASS[$agent]-user}"
  case "$cls" in
    user|system) ;;
    *) cls="user" ;;
  esac
  printf '%s' "$cls"
}

# Validate every BRIDGE_AGENT_CLASS entry currently present in the roster
# maps. Called from bridge_load_roster after sourcing the roster files so
# typos like `class=admin` or `class=System` surface as a hard error
# rather than silently falling back to user-class. The closed value space
# matches bridge_agent_class above; future classes must extend both the
# value list AND the tool-policy gate.
bridge_validate_agent_classes() {
  declare -p BRIDGE_AGENT_CLASS >/dev/null 2>&1 || return 0
  local agent cls
  for agent in "${!BRIDGE_AGENT_CLASS[@]}"; do
    cls="${BRIDGE_AGENT_CLASS[$agent]}"
    [[ -n "$cls" ]] || continue
    case "$cls" in
      user|system) ;;
      *) bridge_die "unknown agent class '$cls' for agent '$agent'; valid: user, system" ;;
    esac
  done
}

bridge_agent_session() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SESSION[$agent]-}"
}

bridge_agent_isolation_mode() {
  # Issue #412 Track A: cross-check roster vs runtime evidence and
  # normalize the value space to {shared, linux-user, unknown}. When the
  # agent has an os_user set, the launcher (bridge-run.sh) wraps the
  # session in `sudo -n -u agent-bridge-<slug>` and the runtime is
  # genuinely linux-user-isolated regardless of what the roster declares
  # — return linux-user so `agent show` and downstream consumers reflect
  # the runtime, not stale roster intent. Otherwise normalize the
  # roster-declared value: empty/shared → shared; linux-user → linux-user;
  # anything else → unknown (was previously rendered as the raw value or
  # `-`, leading to `no` / `-` / `shared` drift across same-install agents).
  local agent="$1"
  local roster_mode="${BRIDGE_AGENT_ISOLATION_MODE[$agent]-}"
  local os_user="${BRIDGE_AGENT_OS_USER[$agent]-}"
  if [[ -n "$os_user" ]]; then
    printf 'linux-user'
    return 0
  fi
  case "$roster_mode" in
    linux-user) printf 'linux-user' ;;
    shared|"") printf 'shared' ;;
    *) printf 'unknown' ;;
  esac
}

bridge_agent_os_user() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_OS_USER[$agent]-}"
}

bridge_agent_os_user_display() {
  # Issue #412 Track A: stable display value for the `os_user` field in
  # `agent show` output. Always print the actual value when set, or `-`
  # when unset — never `no`, never empty. The legacy renderer used
  # `${os_user:--}` which collapsed empty to `-` but other callers
  # passed `no` through unchanged, producing the three-different-shapes
  # drift the issue documents.
  local agent="$1"
  local v="${BRIDGE_AGENT_OS_USER[$agent]-}"
  if [[ -n "$v" ]]; then
    printf '%s' "$v"
  else
    printf '%s' '-'
  fi
}

bridge_agent_default_os_user() {
  local agent="$1"

  bridge_require_python
  python3 - "$agent" <<'PY'
import re
import sys

agent = sys.argv[1].strip().lower()
slug = re.sub(r"[^a-z0-9_-]+", "-", agent).strip("-")
slug = slug or "agent"
prefix = "agent-bridge-"
max_len = 32
keep = max_len - len(prefix)
if keep < 1:
    keep = 1
print(prefix + slug[:keep])
PY
}

bridge_agent_linux_user_isolation_requested() {
  local agent="$1"
  [[ "$(bridge_agent_isolation_mode "$agent")" == "linux-user" ]]
}

bridge_host_platform() {
  if [[ -n "${BRIDGE_HOST_PLATFORM_OVERRIDE:-}" ]]; then
    printf '%s' "$BRIDGE_HOST_PLATFORM_OVERRIDE"
    return 0
  fi
  uname -s 2>/dev/null || printf 'unknown'
}

bridge_agent_linux_user_isolation_effective() {
  local agent="$1"

  bridge_agent_linux_user_isolation_requested "$agent" || return 1
  [[ "$(bridge_host_platform)" == "Linux" ]] || return 1
  [[ -n "$(bridge_agent_os_user "$agent")" ]] || return 1
  return 0
}

bridge_current_user() {
  id -un
}

bridge_agent_linux_user_home() {
  local os_user="$1"
  printf '%s/%s' "$BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT" "$os_user"
}

bridge_agent_linux_env_file() {
  local agent="$1"
  # Scoped per-agent roster snapshot at a stable controller-owned path.
  # Must NOT live under the workdir — workdir is chowned to $os_user, which
  # would make the file writable by the isolated UID. Placing it under
  # $runtime_state_dir keeps controller ownership while still letting the
  # isolated UID read it (via u:$os_user:r-- ACL). The path is derivable
  # from BRIDGE_AGENT_ID alone, so bridge_load_roster can find it without
  # a roster lookup — closes issue #116.
  printf '%s/agent-env.sh' "$(bridge_agent_runtime_state_dir "$agent")"
}

bridge_linux_sudo_root() {
  if [[ "$(id -u)" == "0" ]]; then
    "$@"
    return $?
  fi

  command -v sudo >/dev/null 2>&1 || bridge_die "linux-user isolation requires sudo"
  sudo -n "$@"
}

bridge_linux_can_sudo_to() {
  local os_user="$1"

  [[ -n "$os_user" ]] || return 1
  if [[ "$(id -u)" == "0" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1 || return 1
  # Probe via `bash -c 'exit 0'` — matches the sudoers entry installed by
  # bridge_migration_sudoers_entry (which whitelists tmux + bash only, not
  # /usr/bin/true). Using the canonical BRIDGE_BASH_BIN when available so
  # the path also matches the entry's `command -v bash`.
  local bash_bin="${BRIDGE_BASH_BIN:-$(command -v bash 2>/dev/null || printf '/bin/bash')}"
  sudo -n -u "$os_user" -- "$bash_bin" -c 'exit 0' 2>/dev/null
}

# Internal: non-fatal sudo presence probe. Returns 0 if the helper can
# safely call bridge_linux_sudo_root, 1 if sudo is absent (so the helper
# must early-return and the daemon is not killed by bridge_die).
bridge_linux_have_sudo_or_skip() {
  if [[ "$(id -u)" == "0" ]]; then
    return 0
  fi
  command -v sudo >/dev/null 2>&1
}

bridge_agent_preserved_env_vars() {
  # Intentionally conservative: the ENV_PREFIX inlined in the SESSION_CMD
  # re-exports all BRIDGE_* runtime paths inside the bash -c child, so sudo
  # only needs to pass through the terminal/locale bits and the two
  # launch-time markers that are not in ENV_PREFIX.
  printf '%s' "TERM,LANG,LC_ALL,BRIDGE_AGENT_ENV_FILE,BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS"
}

bridge_linux_require_setfacl() {
  if command -v setfacl >/dev/null 2>&1; then
    return 0
  fi
  bridge_linux_sudo_root bash -lc 'command -v setfacl >/dev/null 2>&1' || bridge_die "linux-user isolation requires setfacl"
}

bridge_linux_user_exists() {
  local os_user="$1"
  id -u "$os_user" >/dev/null 2>&1
}

bridge_linux_ensure_os_user() {
  local os_user="$1"
  local user_home="$2"

  bridge_linux_user_exists "$os_user" && return 0
  bridge_linux_sudo_root useradd -r -d "$user_home" -s /bin/bash "$os_user"
}

bridge_linux_ensure_user_home() {
  local os_user="$1"
  local user_home="$2"

  bridge_linux_sudo_root mkdir -p "$user_home"
  bridge_linux_sudo_root chown "$os_user" "$user_home"
  bridge_linux_sudo_root chmod 700 "$user_home"
}

bridge_linux_install_agent_bridge_symlink() {
  local os_user="$1"
  local user_home="$2"
  local bridge_home="$3"
  local target="$user_home/.agent-bridge"
  local current=""

  # Issue #403 P0: NEVER rm -rf a path that resolves to the controller's
  # own BRIDGE_HOME. The realpath check catches both literal-equality
  # and symlink-to-controller-home cases. Any caller passing
  # os_user==<controller-login> hits this gate, which is the right
  # behavior — the controller's login is not an isolated agent and
  # should never have its ~/.agent-bridge wiped.
  local _resolved_target _resolved_bridge_home _controller_user
  _resolved_target="$(readlink -f "$target" 2>/dev/null || printf '%s' "$target")"
  _resolved_bridge_home="$(readlink -f "$bridge_home" 2>/dev/null || printf '%s' "${bridge_home:-}")"
  if [[ -n "$_resolved_bridge_home" && "$_resolved_target" == "$_resolved_bridge_home" ]]; then
    bridge_die "install_agent_bridge_symlink: refusing to rm -rf controller BRIDGE_HOME at $target (would wipe live install — issue #403). Caller must pass an isolated UID's os_user, not the controller login."
  fi
  # Also reject when os_user is empty or matches the controller's login
  # directly, even if BRIDGE_HOME isn't yet set in this scope.
  _controller_user="$(id -un 2>/dev/null || printf '%s' "${USER:-}")"
  if [[ -z "$os_user" || "$os_user" == "$_controller_user" ]]; then
    bridge_die "install_agent_bridge_symlink: os_user '$os_user' equals controller login or is empty — refusing to operate on controller-side path $target (issue #403)."
  fi

  current="$(bridge_linux_sudo_root python3 - "$target" <<'PY'
from pathlib import Path
import os
import sys

path = Path(sys.argv[1])
if not path.exists() and not path.is_symlink():
    print("")
elif path.is_symlink():
    print(os.readlink(path))
else:
    print("__nonlink__")
PY
)"

  if [[ "$current" == "$bridge_home" ]]; then
    return 0
  fi

  bridge_linux_sudo_root rm -rf "$target"
  bridge_linux_sudo_root ln -s "$bridge_home" "$target"
  bridge_linux_sudo_root chown -h "$os_user" "$target" >/dev/null 2>&1 || true
}

bridge_linux_acl_add() {
  local spec="$1"
  shift || true
  (($# > 0)) || return 0
  # PR-E: in v2 mode the per-agent group + setgid layout (PR-A/B/C) covers
  # what named-user ACLs used to cover, so this primitive is a no-op when
  # bridge_isolation_v2_active. The Claude credential exception
  # (bridge_linux_grant_claude_credentials_access) calls setfacl directly
  # and does not route through this primitive — see r6 plan-ok.
  if bridge_isolation_v2_active; then
    return 0
  fi
  bridge_linux_sudo_root setfacl -m "$spec" "$@"
}

# Resolve the absolute path of an engine CLI (claude/codex) on the
# controller's PATH. Returns empty string if not found.
bridge_resolve_engine_cli() {
  local engine="$1"
  case "$engine" in
    claude|codex) command -v "$engine" 2>/dev/null || true ;;
    *) printf '' ;;
  esac
}

# Engine binaries are typically installed under the operator's home
# (e.g. ~/.local/bin/claude -> ~/.local/share/claude/versions/X). The
# isolated UID has no PATH entry pointing there and no traverse/read
# perms on the chain, so `claude --continue` fails with "command not
# found" inside the sudo wrap. Grant the isolated UID exec on both the
# symlink path and its realpath, plus traverse on every parent dir of
# both. PATH injection happens in bridge_write_linux_agent_env_file.
bridge_linux_grant_engine_cli_access() {
  local os_user="$1"
  local engine="$2"
  local cli_path=""
  local cli_real=""
  local stop_path=""

  cli_path="$(bridge_resolve_engine_cli "$engine")"
  [[ -n "$cli_path" ]] || return 0
  cli_real="$(readlink -f "$cli_path" 2>/dev/null || printf '%s' "$cli_path")"

  # PR-E: in v2 mode the engine CLI must be in a base-readable path
  # (`other::r-x`), because the v2 group contract has no path INTO the
  # operator's home for the isolated UID. Reject controller-home paths
  # for both the symlink path AND its readlink target — a base-readable
  # symlink (e.g. /usr/local/bin/claude → ~/.local/share/claude/...) can
  # otherwise resolve into a private dir and fail at runtime.
  if bridge_isolation_v2_active; then
    local _bad=""
    if [[ -n "$(bridge_linux_traverse_stop_for "$cli_path")" ]]; then
      _bad="$cli_path (under controller home)"
    elif [[ -n "$cli_real" && "$cli_real" != "$cli_path" \
            && -n "$(bridge_linux_traverse_stop_for "$cli_real")" ]]; then
      _bad="$cli_real (realpath of $cli_path under controller home)"
    fi
    if [[ -n "$_bad" ]]; then
      bridge_die "isolation v2 requires engine CLI ('$engine') in a base-readable path; got: $_bad. Move '$engine' to /usr/local/bin or another path with 'other::r-x'."
    fi
    # Optional execute probe — only if direct sudo to os_user is wired
    # up. nested sudo (sudo -n -u $os_user via bridge_linux_sudo_root)
    # would mask probe failures behind the wrapper, so probe directly.
    # Probe failure is fail-fast because PR-E's v2 contract assumes the
    # isolated UID can launch the engine without any ACL help.
    if [[ -n "$os_user" ]] && bridge_linux_can_sudo_to "$os_user"; then
      sudo -n -u "$os_user" -- test -x "$cli_real" \
        || bridge_die "isolation v2: '$os_user' cannot exec '$cli_real' (base perms or ancestor traversal blocks). Re-check engine CLI install."
    fi
    return 0
  fi

  # Only chain-grant when the CLI lives inside the operator's home
  # (chmod 0700 blocks base-perm traversal there). System paths like
  # /usr/bin/claude already have `r-x` for `other` so the isolated UID
  # can open them without any ACL help. Walking all the way to `/` for
  # those was pure noise and the trigger for issue #233's ACL residue.
  stop_path="$(bridge_linux_traverse_stop_for "$cli_path")"
  if [[ -n "$stop_path" ]]; then
    bridge_linux_grant_traverse_chain "$os_user" "$cli_path" "$stop_path"
  fi
  bridge_linux_acl_add "u:${os_user}:r-x" "$cli_path" >/dev/null 2>&1 || true
  if [[ -n "$cli_real" && "$cli_real" != "$cli_path" ]]; then
    stop_path="$(bridge_linux_traverse_stop_for "$cli_real")"
    if [[ -n "$stop_path" ]]; then
      bridge_linux_grant_traverse_chain "$os_user" "$cli_real" "$stop_path"
    fi
    bridge_linux_acl_add "u:${os_user}:r-x" "$cli_real" >/dev/null 2>&1 || true
  fi
}

# Grant the isolated UID r-x on the curated $BRIDGE_HOME/bin directory and
# the agb shim inside it (issue #544 PR1). Mirrors the engine-cli grant:
# best-effort, idempotent, and re-applied via `agent-bridge isolate <agent>
# --reapply`. PATH injection happens in bridge_write_linux_agent_env_file.
#
# Out of scope: broader subcommand allowlist/denylist enforcement (issue
# #544 PR4 design). This helper is a discovery/delivery grant only.
bridge_linux_grant_bin_dir_access() {
  local os_user="$1"
  local bin_dir="$BRIDGE_HOME/bin"
  [[ -n "$os_user" ]] || return 0
  [[ -d "$bin_dir" ]] || return 0
  bridge_linux_acl_add "u:${os_user}:r-x" "$bin_dir" >/dev/null 2>&1 || true
  if [[ -e "$bin_dir/agb" ]]; then
    bridge_linux_acl_add "u:${os_user}:r-x" "$bin_dir/agb" >/dev/null 2>&1 || true
  fi
}

bridge_linux_traverse_stop_for() {
  # Return a safe stop_path for traversing ancestors of $target. Prefers
  # the operator's home when $target sits under it (that's the case that
  # actually needs traversal help — chmod 0700 on the controller home
  # blocks base-perm search for everyone else). Returns empty for system
  # paths (/usr/bin/..., /opt/..., etc.) so callers can skip the grant
  # entirely — `other::r-x` already covers those.
  local target="$1"
  local controller_user="${2:-$(bridge_current_user)}"
  local controller_home=""
  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "$controller_home" && "$target" == "$controller_home"/* ]]; then
    printf '%s' "$controller_home"
    return 0
  fi
  # No safe stop_path — caller must skip the grant. Never return '/',
  # '/home', or similar shared roots (issue #233).
  return 0
}

# Restore the controller read lens on an isolated Claude home. The memory-daily
# harvester runs in the controller context and scans the isolated UID's
# ~/.claude/projects tree through this lens.
bridge_linux_repair_isolated_claude_read_lens() {
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local isolated_claude_dir=""
  local isolated_projects_dir=""

  [[ -n "$os_user" && -n "$user_home" && -n "$controller_user" ]] || return 0
  if bridge_isolation_v2_active; then
    return 0
  fi

  isolated_claude_dir="$user_home/.claude"
  isolated_projects_dir="$isolated_claude_dir/projects"

  bridge_linux_sudo_root test -d "$isolated_claude_dir" || return 0
  bridge_linux_sudo_root setfacl \
    -m "u:${controller_user}:r-x" \
    -m "m::r-x" \
    "$isolated_claude_dir" >/dev/null 2>&1 || true
  bridge_linux_sudo_root setfacl \
    -d -m "u:${controller_user}:r-X" \
    -d -m "m::r-X" \
    "$isolated_claude_dir" >/dev/null 2>&1 || true

  bridge_linux_sudo_root test -d "$isolated_projects_dir" || return 0
  bridge_linux_sudo_root find "$isolated_projects_dir" -type d \
    -exec setfacl -m "u:${controller_user}:r-X" -m "m::r-X" {} + >/dev/null 2>&1 || true
  bridge_linux_sudo_root find "$isolated_projects_dir" -type d \
    -exec setfacl -d -m "u:${controller_user}:r-X" -d -m "m::r-X" {} + >/dev/null 2>&1 || true
  bridge_linux_sudo_root find "$isolated_projects_dir" -type f \
    -exec setfacl -m "u:${controller_user}:r--" -m "m::r--" {} + >/dev/null 2>&1 || true
}

# Claude Code reads its auth from $CLAUDE_CONFIG_DIR/.credentials.json
# (default $HOME/.claude/.credentials.json). Under linux-user isolation
# the agent runs as a dedicated UID whose $HOME is /home/<os_user>/,
# and the operator's `.credentials.json` is not present there — Claude
# falls back to the first-launch login picker and the agent cannot
# process work. Fix (#125):
#
# - Symlink /home/<os_user>/.claude/.credentials.json to the
#   controller's credentials file so Claude on the isolated UID resolves
#   `$HOME/.claude/.credentials.json` to the operator's file.
# - Grant the isolated UID traverse + read-exec ACL on the controller's
#   `.claude/` and r-- on the file itself.
# - Set a default ACL (u:<os_user>:r--) on the controller's `.claude/`
#   so a re-auth — which Claude performs via atomic rename, producing a
#   new inode — still inherits the grant without another `isolate` run.
#
# Intentionally does NOT share the whole `.claude/` via
# `CLAUDE_CONFIG_DIR`: projects/, sessions/, plugins/, and
# settings.json benefit from per-agent write isolation. Only the
# credentials file is shared across the controller's agents, matching
# the reality that there is one Claude account per controller.
bridge_linux_grant_claude_credentials_access() {
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local engine="$4"
  local controller_home=""
  local controller_claude_dir=""
  local controller_cred_file=""
  local isolated_claude_dir=""
  local isolated_cred_link=""
  local current_target=""

  [[ "$engine" == "claude" ]] || return 0
  [[ -n "$os_user" && -n "$user_home" && -n "$controller_user" ]] || return 0

  controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$controller_home" && -d "$controller_home" ]] || return 0

  controller_claude_dir="$controller_home/.claude"
  controller_cred_file="$controller_claude_dir/.credentials.json"
  isolated_claude_dir="$user_home/.claude"
  isolated_cred_link="$isolated_claude_dir/.credentials.json"

  if [[ ! -f "$controller_cred_file" ]]; then
    bridge_warn "claude credentials not found at $controller_cred_file — run 'claude login' as the operator, then re-run 'agent-bridge isolate <agent>' to wire them into the isolated UID"
    return 0
  fi

  # PR-E: in v2 mode, the v2 layout has no path INTO the operator's
  # ~/.claude. C1 transitional exception — keep ACL access to the single
  # controller credential file via the unguarded traverse helper +
  # direct setfacl. This is the *only* v2 surface that retains
  # named-user ACLs; all other v2 helpers route through the ACL
  # primitives which short-circuit. C2 (per-agent `claude login`) is
  # the eventual replacement and lives in a future PR.
  #
  # Helper-level setfacl gate so silent failures cannot reach the
  # symlink-plant step below — `bridge_linux_require_setfacl` is the
  # sudo-aware presence check used elsewhere in linux-user isolation.
  if bridge_isolation_v2_active; then
    bridge_linux_require_setfacl
  fi

  bridge_linux_sudo_root mkdir -p "$isolated_claude_dir"
  bridge_linux_sudo_root chown "$os_user" "$isolated_claude_dir"
  if ! bridge_isolation_v2_active; then
    bridge_linux_sudo_root chmod 0700 "$isolated_claude_dir"
    bridge_linux_repair_isolated_claude_read_lens "$os_user" "$user_home" "$controller_user"
  fi

  if bridge_isolation_v2_active; then
    # C1 exception: bypass the v2-noop public traverse chain and apply
    # the grant directly. Same safety body via _bridge_linux_grant_traverse_paths.
    #
    # Scope is intentionally narrow per PR #399 r1 FAIL #13 — only what
    # the kernel needs to resolve the symlink at
    # `$user_home/.claude/.credentials.json` to
    # `$controller_home/.claude/.credentials.json`:
    #   1. traverse `--x` along every ancestor up to controller_home
    #      (the unguarded helper above grants this on each ancestor,
    #      including controller_claude_dir itself).
    #   2. read `r--` on the credential file inode.
    # No directory `r-x` (would let the isolated UID list ~/.claude/),
    # no default ACL on ~/.claude/ (would extend grants to every new
    # inode under there). Re-auth's atomic-rename produces a new inode
    # without an inherited ACL, so start/daemon preflights call this helper
    # again and explicitly restore both the named-user grant and ACL mask.
    _bridge_linux_grant_traverse_chain_unguarded "$os_user" "$controller_claude_dir" "$controller_home"
    # PR-E r2 P1#3 fix: load-bearing setfacl call must fail-loud. The
    # `|| true` of the prior version masked filesystem-ACL-disabled
    # mounts, sudo failures, and missing-kernel-feature errors and let
    # the symlink-plant step below succeed against an unreadable target —
    # producing the exact runtime login-picker / EACCES failure this
    # surface is meant to make fail-fast. This is the only v2 surface
    # that retains a named-user ACL (KNOWN_ISSUES.md §16).
    bridge_linux_sudo_root setfacl -m "u:${os_user}:r--" "$controller_cred_file" \
      || bridge_die "claude cred ACL: setfacl r-- on $controller_cred_file failed (v2+claude requires functional ACLs on this surface; see KNOWN_ISSUES.md §16)"
    bridge_linux_sudo_root setfacl -m "m::r--" "$controller_cred_file" \
      || bridge_die "claude cred ACL: setfacl mask r-- on $controller_cred_file failed (v2+claude requires the ACL mask to preserve the isolated UID read grant)"
  else
    bridge_linux_grant_traverse_chain "$os_user" "$controller_claude_dir" "$controller_home"
    bridge_linux_acl_add "u:${os_user}:r-x" "$controller_claude_dir" >/dev/null 2>&1 || true
    bridge_linux_acl_add "u:${os_user}:r--" "$controller_cred_file" >/dev/null 2>&1 || true
    bridge_linux_sudo_root setfacl -m "m::r--" "$controller_cred_file" >/dev/null 2>&1 || true
    bridge_linux_sudo_root setfacl -d -m "u:${os_user}:r--" "$controller_claude_dir" >/dev/null 2>&1 || true
  fi

  if [[ -L "$isolated_cred_link" ]]; then
    current_target="$(readlink "$isolated_cred_link" 2>/dev/null || printf '')"
    if [[ "$current_target" == "$controller_cred_file" ]]; then
      return 0
    fi
    bridge_linux_sudo_root rm -f "$isolated_cred_link"
  elif [[ -e "$isolated_cred_link" ]]; then
    bridge_linux_sudo_root rm -f "$isolated_cred_link"
  fi
  bridge_linux_sudo_root ln -s "$controller_cred_file" "$isolated_cred_link"
  bridge_linux_sudo_root chown -h "$os_user" "$isolated_cred_link" >/dev/null 2>&1 || true
}

bridge_linux_repair_claude_credentials_access() {
  local agent="$1"
  local os_user=""
  local user_home=""
  local controller_user=""
  local engine=""

  [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] || return 0
  bridge_agent_linux_user_isolation_effective "$agent" || return 0
  engine="$(bridge_agent_engine "$agent")"
  [[ "$engine" == "claude" ]] || return 0

  # Item 13 (PR #442 r2): repair is best-effort. Skip cleanly when sudo is
  # unavailable (CI without sudo, dev shell without sudo) — without this
  # guard, the inner bridge_linux_sudo_root would bridge_die on the start /
  # daemon-health path even when the repair would otherwise be a no-op.
  bridge_linux_have_sudo_or_skip || return 0

  os_user="$(bridge_agent_os_user "$agent")"
  [[ -n "$os_user" ]] || return 0
  user_home="$(getent passwd "$os_user" 2>/dev/null | cut -d: -f6 || true)"
  [[ -n "$user_home" ]] || return 0
  controller_user="$(bridge_current_user)"
  [[ -n "$controller_user" ]] || return 0

  bridge_linux_grant_claude_credentials_access "$os_user" "$user_home" "$controller_user" "$engine"
}

bridge_linux_acl_add_recursive() {
  local spec="$1"
  shift || true
  (($# > 0)) || return 0
  if bridge_isolation_v2_active; then
    return 0
  fi
  bridge_linux_sudo_root setfacl -R -m "$spec" "$@"
}

bridge_linux_acl_remove_recursive() {
  local spec="$1"
  shift || true
  (($# > 0)) || return 0
  if bridge_isolation_v2_active; then
    return 0
  fi
  bridge_linux_sudo_root setfacl -R -x "$spec" "$@" >/dev/null 2>&1 || true
}

bridge_linux_acl_add_default_dirs_recursive() {
  local spec="$1"
  shift || true
  local path=""

  if bridge_isolation_v2_active; then
    return 0
  fi
  for path in "$@"; do
    [[ -d "$path" ]] || continue
    bridge_linux_sudo_root find "$path" -type d -exec setfacl -d -m "$spec" {} +
  done
}

# Iterate the agent's declared channel state .env files and re-apply the
# controller named-user ACL plus mask::rwX. Recovers from two observed
# failure modes in v0.6.17:
#   - POSIX ACL mask drifted to `---` after an unrelated chmod elsewhere
#     reset the mask to the file's group bits (group is 0 on these .env
#     files), which silently nullifies all named-user entries' effective
#     bits. Daemon's grep against the file then returns EACCES, the
#     channel status reads "miss", and a noisy channel-health task is
#     enqueued every cycle.
#   - The controller named-user entry was lost entirely (a fresh write
#     of the file by an external tool dropped the named-user ACL).
#
# Scope is intentionally narrow: known channel state .env files for one
# isolated agent. Other files and other agents are out of scope so the
# blast radius stays bounded. Helper is best-effort throughout (any
# setfacl failure is swallowed) so the caller can still fall through to
# the existing miss/credentials path on a real credentials problem.
#
# bridge_plugin_channel_state_dir lookup is sidestepped here so this
# helper works whether or not PR #363's ms365 case has merged into the
# tree being deployed: each declared `plugin:<id>` channel is mapped
# directly to `${workdir}/.<id>` for the four channel kinds we ship.
bridge_linux_acl_repair_channel_env_files() {
  local agent="$1"

  # PR-E: v2 mode does not use named-user ACLs on channel state files
  # (the per-agent group + 2770 channel target dir + umask 007 covers
  # both isolated and controller access), so the ACL mask drift class
  # this helper exists to recover from cannot occur. Early-return before
  # any sudo/controller/workdir resolve so the daemon stays cheap.
  if bridge_isolation_v2_active; then
    return 0
  fi

  bridge_linux_have_sudo_or_skip || return 0

  local controller_user
  controller_user="$(bridge_current_user 2>/dev/null || true)"
  [[ -n "$controller_user" ]] || return 0

  local workdir
  workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -n "$workdir" ]] || return 0

  local channels_csv
  channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  [[ -n "$channels_csv" ]] || return 0

  local IFS=',' tokens=()
  read -ra tokens <<<"$channels_csv"

  local token id state_dir env_file
  for token in "${tokens[@]}"; do
    token="${token// /}"
    [[ "$token" == plugin:* ]] || continue
    id="${token#plugin:}"
    id="${id%%@*}"
    case "$id" in
      discord|telegram|teams|ms365) ;;
      *) continue ;;
    esac
    state_dir="$workdir/.$id"

    # Use sudo test, not bash `[[ -d ... ]]`, because the controller
    # named-user traverse on the workdir may have drifted too — the
    # check needs to succeed via root.
    bridge_linux_sudo_root test -d "$state_dir" || continue

    # Repair the state dir's ACL too (small hardening — mask drift on
    # the dir would make file-level repair unreachable on the next
    # daemon read).
    bridge_linux_sudo_root setfacl \
      -m "u:${controller_user}:rwX" \
      -m "m::rwX" \
      "$state_dir" >/dev/null 2>&1 || true

    env_file="$state_dir/.env"
    bridge_linux_sudo_root test -f "$env_file" || continue

    bridge_linux_sudo_root setfacl \
      -m "u:${controller_user}:rw-" \
      -m "m::rwX" \
      "$env_file" >/dev/null 2>&1 || true
  done
}

# Emit ACL metadata (not file contents) for each declared channel state
# dir + its .env, suitable for inclusion in a channel-health miss task
# body. Bounded by design:
#   - declared channels only (discord/telegram/teams/ms365);
#   - per-target output capped at 12 lines via head;
#   - never reads .env content; only `getfacl -p` metadata;
#   - graceful when getfacl is missing, target is missing, or sudo fails.
bridge_agent_channel_acl_diagnostics_text() {
  local agent="$1"

  if ! bridge_linux_have_sudo_or_skip; then
    printf '_ACL diagnostics unavailable: sudo not present_\n'
    return 0
  fi

  command -v getfacl >/dev/null 2>&1 || {
    printf '_getfacl unavailable; skipping ACL diagnostics_\n'
    return 0
  }

  local workdir
  workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -n "$workdir" ]] || return 0

  local channels_csv
  channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  [[ -n "$channels_csv" ]] || return 0

  local IFS=',' tokens=()
  read -ra tokens <<<"$channels_csv"

  local token id state_dir env_file
  local emitted=0
  for token in "${tokens[@]}"; do
    token="${token// /}"
    [[ "$token" == plugin:* ]] || continue
    id="${token#plugin:}"
    id="${id%%@*}"
    case "$id" in
      discord|telegram|teams|ms365) ;;
      *) continue ;;
    esac
    state_dir="$workdir/.$id"
    env_file="$state_dir/.env"

    if ! bridge_linux_sudo_root test -d "$state_dir" 2>/dev/null; then
      printf '_state_dir missing: %s_\n\n' "$state_dir"
      emitted=1
      continue
    fi

    printf '### %s state-dir ACL\n\n' "$id"
    printf '```\n'
    ( bridge_linux_sudo_root getfacl -p "$state_dir" 2>&1 || true ) | head -12
    printf '```\n\n'
    emitted=1

    if bridge_linux_sudo_root test -f "$env_file" 2>/dev/null; then
      printf '### %s .env ACL\n\n' "$id"
      printf '```\n'
      ( bridge_linux_sudo_root getfacl -p "$env_file" 2>&1 || true ) | head -12
      printf '```\n\n'
    fi
  done

  if (( emitted == 0 )); then
    printf '_no declared channel state dirs to diagnose_\n'
  fi
}

# PR-E refactor: emit the traversal path list (one per line, root-to-leaf
# order). Owns the `/` reject, missing-stop reject, Python normalization,
# and ancestor-of-target check. Public + private wrappers below share this
# emitter so the v2 credential exception cannot drift away from the
# traversal safety guards.
_bridge_linux_grant_traverse_paths() {
  local target="$1"
  local stop_path="${2:-}"

  if [[ -z "$stop_path" ]]; then
    bridge_warn "_bridge_linux_grant_traverse_paths: missing stop_path for target=$target (skipping grant to avoid ancestor poisoning)"
    return 0
  fi
  case "$stop_path" in
    "/"|"")
      bridge_warn "_bridge_linux_grant_traverse_paths: refusing stop_path=\"$stop_path\" for target=$target (would poison filesystem root)"
      return 0
      ;;
  esac

  python3 - "$target" "$stop_path" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1]).expanduser().resolve()
stop_raw = Path(sys.argv[2]).expanduser().resolve()

# Stop can be a file — walk terminates at its parent directory.
stop = stop_raw if stop_raw.is_dir() else stop_raw.parent

if target != stop and stop not in target.parents:
    sys.exit(0)

items = []
current = target
while True:
    items.append(str(current))
    if current == stop:
        break
    if current.parent == current:
        break
    current = current.parent

for item in reversed(items):
    print(item)
PY
}

bridge_linux_grant_traverse_chain() {
  # Grant `u:${os_user}:--x` on every directory from $target up to
  # (and including) $stop_path. Callers must pass an explicit stop_path
  # — it used to default to `/`, which is how issue #233 happened.
  # `/` is always rejected as a stop_path so an accidental empty-string
  # or regressed caller cannot reinstate the bug.
  #
  # PR-E: in v2 mode this is a no-op via bridge_linux_acl_add. The
  # Claude credential exception uses _bridge_linux_grant_traverse_chain_unguarded
  # below, which shares the path emitter but bypasses the v2 guard.
  local os_user="$1"
  local target="$2"
  local stop_path="${3:-}"
  local path=""

  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    bridge_linux_acl_add "u:${os_user}:--x" "$path"
  done < <(_bridge_linux_grant_traverse_paths "$target" "$stop_path")
}

# PR-E private helper — grant traversal directly via setfacl, bypassing
# the public v2 short-circuit. ONLY for use by the Claude credential
# exception (bridge_linux_grant_claude_credentials_access). Shares the
# safety body above so the `/` reject, missing-stop reject, Python
# normalization, and ancestor check stay in lockstep with the public path.
_bridge_linux_grant_traverse_chain_unguarded() {
  local os_user="$1"
  local target="$2"
  local stop_path="${3:-}"
  local path=""

  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    bridge_linux_sudo_root setfacl -m "u:${os_user}:--x" "$path" >/dev/null 2>&1 || true
  done < <(_bridge_linux_grant_traverse_paths "$target" "$stop_path")
}

bridge_linux_revoke_traverse_chain() {
  # Mirror of bridge_linux_grant_traverse_chain: remove `u:${os_user}` from
  # every directory between $target and $stop_path (inclusive). Stop_path
  # follows the same `/` and empty-string guards as the grant function so
  # an accidental call cannot strip ACLs from filesystem ancestors.
  #
  # PR-E: v2 mode has no named-user ACLs to revoke (group-setgid contract),
  # so this is a no-op when bridge_isolation_v2_active.
  if bridge_isolation_v2_active; then
    return 0
  fi
  local os_user="$1"
  local target="$2"
  local stop_path="${3:-}"

  if [[ -z "$stop_path" ]]; then
    bridge_warn "bridge_linux_revoke_traverse_chain: missing stop_path for target=$target (skipping)"
    return 0
  fi
  case "$stop_path" in
    "/"|"")
      bridge_warn "bridge_linux_revoke_traverse_chain: refusing stop_path=\"$stop_path\" for target=$target"
      return 0
      ;;
  esac

  bridge_require_python
  local path=""
  while IFS= read -r path; do
    [[ -d "$path" ]] || continue
    bridge_linux_sudo_root setfacl -x "u:${os_user}" "$path" >/dev/null 2>&1 || true
  done < <(python3 - "$target" "$stop_path" <<'PY'
from pathlib import Path
import sys

target = Path(sys.argv[1]).expanduser().resolve()
stop_raw = Path(sys.argv[2]).expanduser().resolve()
stop = stop_raw if stop_raw.is_dir() else stop_raw.parent
if target != stop and stop not in target.parents:
    sys.exit(0)
items = []
current = target
while True:
    items.append(str(current))
    if current == stop:
        break
    if current.parent == current:
        break
    current = current.parent
for item in reversed(items):
    print(item)
PY
)
}

bridge_resolve_plugin_install_path() {
  # Resolve <plugin>@<marketplace> to its on-disk install directory.
  # Tries installed_plugins.json's installPath first; falls back to the
  # marketplace's source.path/plugins/<plugin> for directory-source
  # marketplaces (used by Agent Bridge's own teams/ms365 plugins, where
  # installed_plugins.json may carry a stale cache path). The fallback
  # is only used for directory-source marketplaces — non-directory
  # sources (git, http, etc.) resolve solely via installed_plugins.json
  # so we don't accidentally synthesise a path that does not match how
  # the controller actually fetched the plugin (Risk 2 in PR #302 r1).
  local plugin_id="$1"
  local plugins_root="$2"
  local manifest="$plugins_root/installed_plugins.json"
  local marketplaces_json="$plugins_root/known_marketplaces.json"

  bridge_require_python
  python3 - "$plugin_id" "$manifest" "$marketplaces_json" <<'PY'
import json, os, sys

plugin_id = sys.argv[1]
manifest_path = sys.argv[2]
marketplaces_path = sys.argv[3]


def warn(msg):
    sys.stderr.write("[bridge-isolate] " + msg + "\n")


resolved = ""

if os.path.isfile(manifest_path):
    try:
        with open(manifest_path) as f:
            manifest = json.load(f)
    except (OSError, ValueError) as exc:
        # Loud failure: corrupt controller manifest is operator-actionable
        # state. Refuse to resolve from it and let the caller fall back to
        # the directory marketplace path (which is independent of the
        # broken manifest); if that also fails the caller will skip the
        # grant rather than silently degrade.
        warn(
            "controller installed_plugins.json unreadable (%s): %s — refusing to resolve %s from manifest"
            % (type(exc).__name__, manifest_path, plugin_id)
        )
        manifest = None
    if isinstance(manifest, dict):
        for entry in manifest.get("plugins", {}).get(plugin_id, []):
            ip = entry.get("installPath")
            if ip and os.path.isdir(ip):
                resolved = ip
                break

if not resolved and "@" in plugin_id and os.path.isfile(marketplaces_path):
    try:
        with open(marketplaces_path) as f:
            markets = json.load(f)
    except (OSError, ValueError) as exc:
        # known_marketplaces.json is not strictly required (manifest path
        # already failed; the directory-marketplace fallback only applies
        # when this file is parseable). Log it but don't escalate.
        warn(
            "controller known_marketplaces.json unreadable (%s): %s — directory-marketplace fallback skipped for %s"
            % (type(exc).__name__, marketplaces_path, plugin_id)
        )
        markets = None
    if isinstance(markets, dict):
        plugin_name, marketplace = plugin_id.split("@", 1)
        entry = markets.get(marketplace, {})
        if isinstance(entry, dict):
            src = entry.get("source")
            candidate = ""
            # Risk 2 (PR #302 r1): the installLocation/plugins/<name>
            # fallback only matches reality for directory-source
            # marketplaces. For git/http/etc. sources, installLocation
            # is the cache root, not the source-of-truth, so synthesising
            # a path there would mis-grant ACLs.
            if isinstance(src, dict) and src.get("source") == "directory":
                candidate = src.get("path", "") or entry.get("installLocation", "")
            if candidate:
                guess = os.path.join(candidate, "plugins", plugin_name)
                if os.path.isdir(guess):
                    resolved = guess

print(resolved or "")
PY
}

bridge_known_marketplaces_lookup() {
  # Inspect `known_marketplaces.json` and return whether a marketplace is
  # registered. Mirrors the lookup shape used by the manifest writer's
  # `:1092` block (and the directory-source fallback at `:894` in
  # bridge_resolve_plugin_install_path) so the symlink path in
  # bridge_linux_share_plugin_catalog gates on the same source-of-truth.
  #
  # Output protocol — exactly one line:
  #   present:directory   — registered with a directory source
  #   present:git         — registered with a git source
  #   present:other       — registered with another source kind (http, etc.)
  #   missing             — not registered (caller should silently skip)
  #   unparseable         — JSON missing / unreadable / not an object
  #                         (caller should skip the whole 5b' block;
  #                          this helper stays silent because the
  #                          manifest writer at :1183 already emitted
  #                          the canonical warning earlier in the same
  #                          share pass — see #348 r3).
  #
  # The `<source-kind>` half of `present:*` is informational — current
  # callers symlink `<plugins_root>/marketplaces/<mkt>` regardless of
  # source kind because that mirror tree is what Claude actually reads
  # at runtime; the source-kind disclosure exists so a future caller
  # that wants to special-case directory vs git can do so without
  # re-parsing the JSON. (#348 r2.)
  local marketplace_id="$1"
  local plugins_root="$2"
  local marketplaces_json="$plugins_root/known_marketplaces.json"

  bridge_require_python
  python3 - "$marketplace_id" "$marketplaces_json" <<'PY'
import json, os, sys

marketplace_id = sys.argv[1]
marketplaces_path = sys.argv[2]


if not os.path.isfile(marketplaces_path):
    # Treat missing as unparseable for caller-side simplicity: the
    # whole 5b' block is a no-op without it. Mirrors the manifest
    # writer's behaviour (it also short-circuits the directory-
    # marketplace fallback when the JSON is absent).
    print("unparseable")
    sys.exit(0)

try:
    with open(marketplaces_path) as f:
        markets = json.load(f)
    if not isinstance(markets, dict):
        raise ValueError("expected JSON object at root, got %r" % type(markets).__name__)
except (OSError, ValueError):
    # Stay silent on the corrupt-JSON branch: the manifest writer
    # (`bridge_write_isolated_installed_plugins_manifest`, step 4 of
    # bridge_linux_share_plugin_catalog) always runs before this
    # helper (step 5b') and already emitted the canonical
    # `[bridge-isolate] controller known_marketplaces.json unparseable …`
    # warning at :1183-1186 for the same file. Re-emitting here would
    # log the same condition twice (once per share pass, plus once per
    # `_mkt_id` iteration before the 5b' loop short-circuits on
    # `unparseable`). Returning `unparseable` is sufficient — the
    # caller's `case` arm sets `_mkt_block_disabled=1` and skips the
    # symlink path silently. (#348 r3.)
    print("unparseable")
    sys.exit(0)

entry = markets.get(marketplace_id)
if not isinstance(entry, dict):
    print("missing")
    sys.exit(0)

src = entry.get("source")
if isinstance(src, dict):
    kind = src.get("source")
    if kind == "directory":
        print("present:directory")
        sys.exit(0)
    if kind == "git":
        print("present:git")
        sys.exit(0)
print("present:other")
PY
}

bridge_isolated_plugin_grants_state_dir() {
  # Controller-owned ledger root for plugin-share ACL grants. Keep this out
  # of $BRIDGE_ACTIVE_AGENT_DIR/<agent>: in legacy mode that path is also the
  # runtime state directory, which needs the normal isolated/controller write
  # ACL contract for agent-env.sh and session state.
  printf '%s/isolated-plugin-grants' "$BRIDGE_STATE_DIR"
}

bridge_isolated_plugin_grants_state_file() {
  # State file recording the channel set last granted plugin-share ACLs to an
  # isolated agent. Used by bridge_linux_share_plugin_catalog (to compute
  # added/removed channels across reapply) and by bridge_migration_unisolate
  # (to revoke channels the live roster may already have dropped).
  local agent="$1"
  printf '%s/%s.json' "$(bridge_isolated_plugin_grants_state_dir)" "$agent"
}

bridge_isolated_plugin_grants_legacy_state_file() {
  # v0.6.28 wrote the grant ledger under the agent runtime state directory.
  # Keep a fallback reader/remover so upgrades can revoke stale grants and
  # migrate the ledger without leaving the old file behind.
  local agent="$1"
  printf '%s/%s/isolated-plugin-grants.json' "$BRIDGE_ACTIVE_AGENT_DIR" "$agent"
}

bridge_isolated_plugin_grants_read() {
  # Read the persisted plugin-channel set for $1. Emits a CSV (channel
  # ids without the `plugin:` prefix would lose round-trip fidelity, so
  # we store the full `plugin:<id>` form). Returns the empty string when
  # the file is missing or unreadable. Channels are deduped + sorted on
  # write so callers can rely on stable ordering.
  local agent="$1"
  local state_file=""
  local legacy_state_file=""
  state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
  legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$agent")"
  if bridge_linux_sudo_root test -e "$state_file"; then
    :
  elif bridge_linux_sudo_root test -e "$legacy_state_file"; then
    state_file="$legacy_state_file"
  else
    printf ''
    return 0
  fi
  bridge_require_python
  bridge_linux_sudo_root python3 - "$state_file" <<'PY'
import json, os, sys
path = sys.argv[1]
try:
    with open(path) as f:
        data = json.load(f)
except (OSError, ValueError) as exc:
    sys.stderr.write(
        "[bridge-isolate] isolated-plugin-grants.json unreadable (%s): %s — treating as empty grant set\n"
        % (type(exc).__name__, path)
    )
    sys.exit(0)
channels = data.get("channels", []) if isinstance(data, dict) else []
print(",".join(c for c in channels if isinstance(c, str)))
PY
}

bridge_isolated_plugin_grants_write() {
  # Persist the channel set as JSON, root-owned 0640 so the isolated UID
  # cannot tamper with the recorded grant set (a tamper there could trick
  # a future unisolate into skipping a still-granted channel).
  local agent="$1"
  local channels_csv="$2"
  local state_file=""
  local state_dir=""
  local legacy_state_file=""
  local tmp_file=""
  state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
  state_dir="$(dirname "$state_file")"
  legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$agent")"
  bridge_linux_sudo_root mkdir -p "$state_dir"
  # Place the temp file in the destination dir so the mv is always within
  # one filesystem (atomic rename); see Blocking 2 in PR #302 r1.
  tmp_file="$(bridge_linux_sudo_root mktemp "${state_file}.tmp.XXXXXX")"
  bridge_require_python
  bridge_linux_sudo_root python3 - "$tmp_file" "$channels_csv" <<'PY'
import json, sys
out_path, csv = sys.argv[1], sys.argv[2]
channels = sorted({c.strip() for c in csv.split(",") if c.strip()})
with open(out_path, "w") as f:
    json.dump({"channels": channels}, f, indent=2)
PY
  bridge_linux_sudo_root mv "$tmp_file" "$state_file"
  bridge_linux_sudo_root chown root:root "$state_file"
  bridge_linux_sudo_root chmod 0640 "$state_file"
  bridge_linux_sudo_root chown root:root "$state_dir" >/dev/null 2>&1 || true
  bridge_linux_sudo_root chmod 0750 "$state_dir" >/dev/null 2>&1 || true
  if [[ "$legacy_state_file" != "$state_file" ]]; then
    bridge_linux_sudo_root rm -f "$legacy_state_file" >/dev/null 2>&1 || true
  fi
}

bridge_isolated_plugin_grants_remove() {
  # Delete the persisted grant-set file (called from unisolate after the
  # ACL strip completes successfully).
  local agent="$1"
  local state_file=""
  local legacy_state_file=""
  state_file="$(bridge_isolated_plugin_grants_state_file "$agent")"
  legacy_state_file="$(bridge_isolated_plugin_grants_legacy_state_file "$agent")"
  if bridge_linux_sudo_root test -e "$state_file"; then
    bridge_linux_sudo_root rm -f "$state_file" >/dev/null 2>&1 || true
  fi
  if [[ "$legacy_state_file" != "$state_file" ]] \
      && bridge_linux_sudo_root test -e "$legacy_state_file"; then
    bridge_linux_sudo_root rm -f "$legacy_state_file" >/dev/null 2>&1 || true
  fi
}

bridge_linux_revoke_plugin_channel_grants() {
  # Strip the per-channel install-path ACL + traverse-chain + isolated
  # catalog symlink for one plugin channel. Mirror of the per-channel
  # grant block in bridge_linux_share_plugin_catalog and the per-channel
  # strip block in bridge_migration_unisolate; factored here so both
  # reapply (when a channel is removed mid-run) and unisolate (full
  # teardown) share one implementation.
  #
  # PR-E: in v2 mode there are no named-user ACL grants to revoke
  # (the v2 group-setgid contract handles isolation via group membership),
  # so this is a no-op when bridge_isolation_v2_active.
  if bridge_isolation_v2_active; then
    return 0
  fi
  local os_user="$1"
  local plugin_id="$2"
  local controller_plugins="$3"
  local controller_home="$4"
  local install_path=""
  install_path="$(bridge_resolve_plugin_install_path "$plugin_id" "$controller_plugins")"
  if [[ -n "$install_path" && -d "$install_path" ]]; then
    bridge_linux_sudo_root setfacl -Rx "u:${os_user}" "$install_path" >/dev/null 2>&1 || true
    bridge_linux_revoke_traverse_chain "$os_user" "$install_path" "$controller_home"
  fi
}

bridge_write_isolated_installed_plugins_manifest() {
  # Write a per-isolated-UID installed_plugins.json containing only the
  # plugins this agent declared via BRIDGE_AGENT_CHANNELS (transport
  # plugins) and BRIDGE_AGENT_PLUGINS (#272 per-agent allowlist of
  # non-channel domain plugins), with installPath rewritten to the
  # actually-existing location resolved by
  # bridge_resolve_plugin_install_path. The file is owned by root so the
  # isolated UID cannot tamper with which plugins it loads.
  #
  # Arguments:
  #   os_user             — isolated UID
  #   isolated_plugins    — destination ~/.claude/plugins root for the UID
  #   controller_plugins  — controller's ~/.claude/plugins (read-only source)
  #   channels_csv        — CSV of `plugin:<id>` (and other) channel tokens
  #   plugins_csv         — CSV of bare `<id>` (or `<id>@<mkt>`) tokens from
  #                         BRIDGE_AGENT_PLUGINS["<agent>"]; may be empty.
  #   agent               — agent id (PR-E: required to resolve the v2 group
  #                         for chgrp ab-agent-<name>). Optional in legacy
  #                         mode for backwards compatibility.
  local os_user="$1"
  local isolated_plugins="$2"
  local controller_plugins="$3"
  local channels_csv="$4"
  local plugins_csv="${5-}"
  local agent="${6-}"
  local manifest="$isolated_plugins/installed_plugins.json"
  local manifest_tmp=""

  bridge_require_python
  # Place the temp file in the destination dir so the subsequent mv is
  # always within one filesystem and therefore an atomic rename. Plain
  # mktemp(1) honours $TMPDIR, which can land on /tmp while $manifest is
  # under /home/<user>/.claude/plugins/ — across mounts mv degrades to
  # copy+unlink and a concurrent reader can see a half-written or
  # transiently missing manifest. (Blocking 2 in PR #302 r1.)
  manifest_tmp="$(bridge_linux_sudo_root mktemp "${manifest}.tmp.XXXXXX")"
  if ! bridge_linux_sudo_root python3 - "$controller_plugins" "$channels_csv" "$manifest_tmp" "$plugins_csv" <<'PY'
import json, os, sys

controller_plugins, channels_csv, out_path, plugins_csv = sys.argv[1:]
controller_manifest = os.path.join(controller_plugins, "installed_plugins.json")
markets_path = os.path.join(controller_plugins, "known_marketplaces.json")


def warn(msg):
    sys.stderr.write("[bridge-isolate] " + msg + "\n")


# Distinguish "controller manifest exists but is corrupt" (operator-
# actionable; refuse to proceed for that plugin entry) from "controller
# manifest absent" (legitimate — fresh install or pre-plugin Claude;
# directory-marketplace fallback is acceptable).
source = {}
manifest_present = os.path.isfile(controller_manifest)
if manifest_present:
    try:
        with open(controller_manifest) as f:
            source = json.load(f)
        if not isinstance(source, dict):
            raise ValueError("expected JSON object at root, got %r" % type(source).__name__)
    except (OSError, ValueError) as exc:
        warn(
            "controller installed_plugins.json unparseable (%s): %s — refusing to write per-UID manifest"
            % (type(exc).__name__, controller_manifest)
        )
        sys.exit(2)

markets = {}
if os.path.isfile(markets_path):
    try:
        with open(markets_path) as f:
            markets = json.load(f)
        if not isinstance(markets, dict):
            raise ValueError("expected JSON object at root, got %r" % type(markets).__name__)
    except (OSError, ValueError) as exc:
        # Marketplace data missing/corrupt is informational: the manifest
        # write can still succeed for entries whose installPath is valid
        # in the controller manifest. The directory-marketplace fallback
        # is the only thing we lose.
        warn(
            "controller known_marketplaces.json unparseable (%s): %s — directory-marketplace fallback disabled"
            % (type(exc).__name__, markets_path)
        )
        markets = {}


def directory_marketplace_path(plugin_id):
    if "@" not in plugin_id:
        return ""
    plugin_name, marketplace = plugin_id.split("@", 1)
    entry = markets.get(marketplace, {})
    if not isinstance(entry, dict):
        return ""
    candidate = ""
    src = entry.get("source")
    # Risk 2 (PR #302 r1): match bridge_resolve_plugin_install_path —
    # only fall back for directory-source marketplaces.
    if isinstance(src, dict) and src.get("source") == "directory":
        candidate = src.get("path", "") or entry.get("installLocation", "")
    if not candidate:
        return ""
    guess = os.path.join(candidate, "plugins", plugin_name)
    return guess if os.path.isdir(guess) else ""


def resolve(plugin_id):
    # Preserve controller entry metadata (version, gitCommitSha, etc.) when
    # we can; only rewrite installPath if it is missing or stale.
    for entry in source.get("plugins", {}).get(plugin_id, []):
        ip = entry.get("installPath")
        if ip and os.path.isdir(ip):
            return entry, ip
        fallback = directory_marketplace_path(plugin_id)
        if fallback:
            return entry, fallback
    fallback = directory_marketplace_path(plugin_id)
    if fallback:
        return {"scope": "user", "installPath": fallback}, fallback
    return None, None


declared = set()
for chan in channels_csv.split(","):
    chan = chan.strip()
    if chan.startswith("plugin:"):
        declared.add(chan[len("plugin:"):])

# BRIDGE_AGENT_PLUGINS allowlist (#272) — bare plugin ids, optionally
# `<plugin>@<marketplace>`. Merged here so the isolated manifest covers
# the union of channel-declared transport plugins AND domain plugins
# the operator allowlisted per-agent. Dedupe via the shared `declared`
# set so an entry that lives in both arrays appears once. (#348)
for token in plugins_csv.split(","):
    token = token.strip()
    if token.startswith("plugin:"):
        token = token[len("plugin:"):]
    if token:
        declared.add(token)

out = {"version": source.get("version", 2), "plugins": {}}
for plugin_id in sorted(declared):
    entry, real_path = resolve(plugin_id)
    if not entry or not real_path:
        continue
    new_entry = dict(entry)
    new_entry["installPath"] = real_path
    out["plugins"][plugin_id] = [new_entry]

with open(out_path, "w") as f:
    json.dump(out, f, indent=2)
PY
  then
    bridge_linux_sudo_root rm -f "$manifest_tmp" >/dev/null 2>&1 || true
    bridge_warn "bridge_write_isolated_installed_plugins_manifest: refused to write per-UID manifest for $os_user (controller state unparseable)"
    return 1
  fi

  # Set final ownership/perm/ACL on the temp file BEFORE the atomic rename
  # so the destination never exists with the wrong metadata even
  # momentarily. Readers see either the previous manifest or the new one
  # with correct ownership/perm/ACL — never an in-between state.
  # (Blocking 2 in PR #302 r2.)
  bridge_linux_sudo_root chown root:root "$manifest_tmp"
  bridge_linux_sudo_root chmod 0640 "$manifest_tmp"
  if bridge_isolation_v2_active; then
    # PR-E: replace the named-user ACL with chgrp ab-agent-<name>. The
    # isolated UID is a member of that group (PR-C ensure_user_in_group)
    # and the manifest mode 0640 grants group r--. Owner stays root so
    # the agent cannot tamper with which plugins it loads.
    if [[ -n "$agent" ]]; then
      local _v2_grp
      _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
        || _v2_grp=""
      if [[ -n "$_v2_grp" ]]; then
        bridge_linux_sudo_root chgrp "$_v2_grp" "$manifest_tmp" \
          || bridge_die "isolation v2: chgrp '$_v2_grp' on manifest '$manifest_tmp' failed"
      else
        bridge_die "isolation v2: cannot resolve agent group for manifest '$manifest_tmp'"
      fi
    else
      bridge_die "isolation v2: bridge_write_isolated_installed_plugins_manifest requires agent id (PR-E signature change)"
    fi
  else
    bridge_linux_acl_add "u:${os_user}:r--" "$manifest_tmp"
  fi
  bridge_linux_sudo_root mv "$manifest_tmp" "$manifest"
}

bridge_linux_share_plugin_catalog() {
  # Channel-ownership-aware plugin sharing for an isolated agent.
  # Grants the isolated UID read-only access to:
  #   - the controller's catalog metadata files (audit-level disclosure),
  #   - a per-UID generated installed_plugins.json that only lists the
  #     plugins declared in BRIDGE_AGENT_CHANNELS for this agent,
  #   - each declared plugin's install-path tree, with a traverse chain
  #     up to the controller home (#233 stop guard).
  # Leaves the isolated UID's plugins/ root and the per-UID manifest
  # root-owned (the agent cannot tamper with what it loads), and leaves
  # plugins/data/ writable so plugins can persist runtime state.
  #
  # Reapply contract: the helper is rerun on every isolate refresh. To
  # keep the isolation boundary tight, the previously-granted channel
  # set is persisted under a root-owned controller ledger and diffed
  # against the current channels — channels removed from the roster
  # have their ACLs and catalog symlinks revoked here, not just at
  # unisolate. (Blocking 1 in PR #302 r1.)
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local agent="$4"

  local controller_home=""
  # Test-only seam: BRIDGE_CONTROLLER_HOME_OVERRIDE replaces the getent
  # passwd lookup so the regression test in tests/isolation-plugin-sharing.sh
  # can drive the helper against a fake controller plugin tree without
  # touching the operator's real ~/.claude/plugins/. The override is
  # ignored unless BRIDGE_HOME points under a recognised tempdir prefix
  # (/tmp, /var/tmp, or $TMPDIR), which guards against accidental
  # production use.
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
      controller_home="$BRIDGE_CONTROLLER_HOME_OVERRIDE"
    else
      bridge_warn "bridge_linux_share_plugin_catalog: ignoring BRIDGE_CONTROLLER_HOME_OVERRIDE because BRIDGE_HOME is not under a tempdir prefix (got '${BRIDGE_HOME:-<unset>}')"
    fi
  fi
  if [[ -z "$controller_home" ]]; then
    controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  fi

  # Resolve the canonical Claude plugins root for this share pass:
  #   1. v2 layout (BRIDGE_LAYOUT=v2 + populated BRIDGE_SHARED_ROOT/plugins-cache)
  #      takes precedence — migrated installs may have no controller_home/.claude/plugins
  #      directory at all, so the legacy-only guard would silently no-op the
  #      whole isolated-share pipeline (manifest write, marketplace symlinks,
  #      per-plugin grants) and the agent would start with no MCP servers.
  #   2. Legacy controller_home/.claude/plugins as fallback.
  #   3. Neither present → no-op (return 0).
  #
  # The v2 root contract is encapsulated in
  # `bridge_isolation_v2_shared_plugins_root` (see lib/bridge-isolation-v2.sh).
  # This function consumes that helper directly so the path lives in one
  # place. controller_home is still recorded for the traverse-chain helper
  # below — for v2 paths that live outside controller_home the traverse
  # walk no-ops, which is intentional (group-mediated access takes over
  # from named-ACL traversal once the operator migrates).
  local controller_plugins=""
  if controller_plugins="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null)"; then
    :
  elif bridge_isolation_v2_active; then
    # PR-E r3 P2#4 (narrow): in v2 mode the legacy controller_home
    # fallback is unsafe — traverse_chain and acl_add no-op, so
    # symlinks under controller_home would be unreadable for the
    # isolated UID. BUT: if the agent has nothing to share (empty
    # channel-plugin union and empty plugin allowlist), there is no
    # symlink to plant and no manifest to write. Codex / no-plugin
    # Claude agents must not be blocked by an empty cache. Compute the
    # union here and short-circuit before failing loud.
    local _v2_pcg_channels="" _v2_pcg_plugins=""
    _v2_pcg_channels="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
    _v2_pcg_plugins="$(bridge_agent_plugins_csv "$agent" 2>/dev/null || true)"
    # plugin-shaped channels are `plugin:<id>`; non-plugin channels
    # (discord, telegram, ms365) do not need this catalog at all.
    if [[ "$_v2_pcg_channels" != *plugin:* ]] \
        && [[ -z "$_v2_pcg_plugins" ]]; then
      return 0
    fi
    bridge_die "isolation v2 plugin catalog: \$BRIDGE_SHARED_ROOT/plugins-cache is not populated (no installed_plugins.json) but agent '$agent' declares plugin: channels or BRIDGE_AGENT_PLUGINS allowlist entries. The legacy controller_home/.claude/plugins fallback is unsafe in v2 mode because the traverse/ACL helpers no-op and would plant unreadable symlinks. Populate the shared plugins cache (\`agb bundle install\` or seed installed_plugins.json into \$BRIDGE_SHARED_ROOT/plugins-cache) before starting v2-isolated agents that require plugins."
  elif [[ -n "$controller_home" && -d "$controller_home/.claude/plugins" ]]; then
    controller_plugins="$controller_home/.claude/plugins"
  else
    return 0
  fi

  local isolated_plugins="$user_home/.claude/plugins"

  # PR-E: resolve the v2 agent group once for plugin root + marketplaces +
  # manifest writer. Empty in legacy mode.
  local _v2_grp=""
  if bridge_isolation_v2_active; then
    _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
      || _v2_grp=""
    [[ -n "$_v2_grp" ]] || bridge_die "isolation v2: cannot resolve agent group for plugin catalog of '$agent'"
  fi

  # 1. plugins/ root: root-owned, group-traversable.
  #    - legacy: chmod 0750 + named-user ACL grants the isolated UID r-x.
  #    - v2:     chown root:ab-agent-<name>, chmod 2750. setgid bit means
  #              new children inherit ab-agent-<name>; the isolated UID
  #              reaches the dir via group r-x (no ACL needed).
  bridge_linux_sudo_root mkdir -p "$isolated_plugins"
  if bridge_isolation_v2_active; then
    bridge_linux_sudo_root chown "root:${_v2_grp}" "$isolated_plugins" \
      || bridge_die "isolation v2: chown root:${_v2_grp} on '$isolated_plugins' failed"
    bridge_linux_sudo_root chmod 2750 "$isolated_plugins" \
      || bridge_die "isolation v2: chmod 2750 on '$isolated_plugins' failed"
  else
    bridge_linux_sudo_root chown root:root "$isolated_plugins"
    bridge_linux_sudo_root chmod 0750 "$isolated_plugins"
    bridge_linux_acl_add "u:${os_user}:r-x" "$isolated_plugins"
  fi

  # 2. plugins/data/: isolated UID owns this so plugin runtime state writes work.
  bridge_linux_sudo_root mkdir -p "$isolated_plugins/data"
  bridge_linux_sudo_root chown "$os_user" "$isolated_plugins/data"
  bridge_linux_sudo_root chmod 0700 "$isolated_plugins/data"

  # 3. Read-only catalog metadata symlinks. Always remove the prior dst
  #    first (independent of source presence) so a controller-side delete
  #    invalidates the isolated symlink rather than leaving it dangling at
  #    a now-stale target. (Risk 1 in PR #302 r1.)
  local catalog_file=""
  local src=""
  local dst=""
  for catalog_file in "${BRIDGE_ISOLATION_SHARED_CATALOG_READ_FILES[@]}"; do
    src="$controller_plugins/$catalog_file"
    dst="$isolated_plugins/$catalog_file"
    bridge_linux_sudo_root rm -f "$dst" >/dev/null 2>&1 || true
    [[ -e "$src" ]] || continue
    bridge_linux_sudo_root ln -s "$src" "$dst"
    bridge_linux_sudo_root chown -h root:root "$dst" >/dev/null 2>&1 || true
    bridge_linux_grant_traverse_chain "$os_user" "$src" "$controller_home"
    bridge_linux_acl_add "u:${os_user}:r--" "$src"
  done

  # 4. Per-UID installed_plugins.json — declared plugins only (union of
  #    BRIDGE_AGENT_CHANNELS plugin entries and BRIDGE_AGENT_PLUGINS allowlist
  #    per #348 / #272), real install paths.
  local channels_csv=""
  local plugins_csv=""
  channels_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  plugins_csv="$(bridge_agent_plugins_csv "$agent" 2>/dev/null || true)"
  bridge_write_isolated_installed_plugins_manifest \
    "$os_user" "$isolated_plugins" "$controller_plugins" \
    "$channels_csv" "$plugins_csv" "$agent"

  # 5. Compute the channel diff against the persisted grant set so we can
  #    revoke channels that were previously granted but are no longer in
  #    the roster (Blocking 1 in PR #302 r1). The "current" set is the
  #    union of BRIDGE_AGENT_CHANNELS `plugin:<id>` tokens and
  #    BRIDGE_AGENT_PLUGINS bare ids (#348). Allowlist entries are
  #    promoted to `plugin:<id>` form here so they share the same
  #    persisted-state shape and revoke pipeline as channel-declared
  #    plugins. Non-plugin channel tokens are ignored on both sides.
  local prior_channels_csv=""
  prior_channels_csv="$(bridge_isolated_plugin_grants_read "$agent" 2>/dev/null || true)"
  local -a _current_plugin_channels=()
  local -a _prior_plugin_channels=()
  local _seen_marker=$'\x1f'
  local _seen=""
  if [[ -n "$channels_csv" ]]; then
    local _cur_split=()
    local _cur_chan=""
    IFS=',' read -ra _cur_split <<<"$channels_csv"
    for _cur_chan in "${_cur_split[@]}"; do
      _cur_chan="${_cur_chan// /}"
      [[ "$_cur_chan" == plugin:* ]] || continue
      case "$_seen" in
        *"${_seen_marker}${_cur_chan}${_seen_marker}"*) continue ;;
      esac
      _seen="${_seen}${_seen_marker}${_cur_chan}${_seen_marker}"
      _current_plugin_channels+=("$_cur_chan")
    done
  fi
  if [[ -n "$plugins_csv" ]]; then
    local _plg_split=()
    local _plg_token=""
    local _plg_full=""
    IFS=',' read -ra _plg_split <<<"$plugins_csv"
    for _plg_token in "${_plg_split[@]}"; do
      _plg_token="${_plg_token// /}"
      [[ -n "$_plg_token" ]] || continue
      _plg_full="plugin:${_plg_token}"
      case "$_seen" in
        *"${_seen_marker}${_plg_full}${_seen_marker}"*) continue ;;
      esac
      _seen="${_seen}${_seen_marker}${_plg_full}${_seen_marker}"
      _current_plugin_channels+=("$_plg_full")
    done
  fi
  if [[ -n "$prior_channels_csv" ]]; then
    local _prior_split=()
    local _prior_chan=""
    IFS=',' read -ra _prior_split <<<"$prior_channels_csv"
    for _prior_chan in "${_prior_split[@]}"; do
      _prior_chan="${_prior_chan// /}"
      [[ "$_prior_chan" == plugin:* ]] || continue
      _prior_plugin_channels+=("$_prior_chan")
    done
  fi

  # 5a. Revoke removed entries (in prior set but not in current set).
  #     This covers both channel removals and BRIDGE_AGENT_PLUGINS
  #     removals — both are persisted in the same `plugin:<id>` form.
  local _prior_entry=""
  local _cur_entry=""
  local _found=0
  for _prior_entry in "${_prior_plugin_channels[@]+"${_prior_plugin_channels[@]}"}"; do
    _found=0
    for _cur_entry in "${_current_plugin_channels[@]+"${_current_plugin_channels[@]}"}"; do
      [[ "$_cur_entry" == "$_prior_entry" ]] && { _found=1; break; }
    done
    if [[ "$_found" -eq 0 ]]; then
      bridge_linux_revoke_plugin_channel_grants \
        "$os_user" "${_prior_entry#plugin:}" "$controller_plugins" "$controller_home"
    fi
  done

  # 5b. Grant current plugin install paths + traverse chain (channel-declared
  #     plus BRIDGE_AGENT_PLUGINS allowlist entries).
  local channel=""
  local plugin_id=""
  local install_path=""
  for channel in "${_current_plugin_channels[@]+"${_current_plugin_channels[@]}"}"; do
    plugin_id="${channel#plugin:}"
    install_path="$(bridge_resolve_plugin_install_path "$plugin_id" "$controller_plugins")"
    [[ -n "$install_path" && -d "$install_path" ]] || continue
    # Order matters: traverse_chain stamps `--x` on every node from target up
    # to controller_home (including target). The recursive r-X grant must run
    # AFTER so target/<file> entries end up with r--/r-x rather than --x.
    bridge_linux_grant_traverse_chain "$os_user" "$install_path" "$controller_home"
    bridge_linux_acl_add_recursive "u:${os_user}:r-X" "$install_path"
  done

  # 5b'. Marketplace symlinks (#348). For every union plugin in
  #     `<plugin>@<marketplace>` form whose marketplace is registered
  #     in the controller's `known_marketplaces.json` AND whose mirror
  #     tree exists at `~/.claude/plugins/marketplaces/<marketplace>`,
  #     plant a read-only symlink under the isolated UID's plugins root
  #     so Claude can resolve the marketplace reference recorded in
  #     installed_plugins.json. The `known_marketplaces.json` lookup is
  #     the source-of-truth gate (matches the issue spec wording and the
  #     manifest writer's :1092 / `:894` directory-source fallback);
  #     the on-disk `marketplaces/<mkt>` dir is the symlink target, so
  #     git-source marketplaces whose tree has not been cached yet
  #     silently skip rather than synthesising a broken symlink.
  #     Symlink + traverse + recursive r-X mirrors the channel install-
  #     path pattern (5b). (#348 r2.)
  local _isolated_marketplaces="$isolated_plugins/marketplaces"
  local _marketplaces_root_created=0
  local _mkt_seen=""
  local _channel_full=""
  local _mkt_id=""
  local _mkt_src=""
  local _mkt_dst=""
  local _mkt_lookup=""
  local _mkt_block_disabled=0
  for _channel_full in "${_current_plugin_channels[@]+"${_current_plugin_channels[@]}"}"; do
    (( _mkt_block_disabled == 0 )) || break
    plugin_id="${_channel_full#plugin:}"
    [[ "$plugin_id" == *@* ]] || continue
    _mkt_id="${plugin_id#*@}"
    [[ -n "$_mkt_id" ]] || continue
    case "$_mkt_seen" in
      *"${_seen_marker}${_mkt_id}${_seen_marker}"*) continue ;;
    esac
    _mkt_seen="${_mkt_seen}${_seen_marker}${_mkt_id}${_seen_marker}"
    # Source-of-truth gate: marketplace must be registered in
    # known_marketplaces.json. On `unparseable` we abandon the whole
    # 5b' block; the manifest writer at :1183-1186 already logged the
    # canonical warning earlier in the same share pass, so the helper
    # itself stays silent (no duplicate stderr line per share pass —
    # #348 r3).
    _mkt_lookup="$(bridge_known_marketplaces_lookup "$_mkt_id" "$controller_plugins")"
    case "$_mkt_lookup" in
      unparseable)
        _mkt_block_disabled=1
        break
        ;;
      missing|"")
        # marketplace not registered → silent skip, no broken symlink.
        continue
        ;;
      present:*) ;;  # fall through to the symlink path
      *) continue ;;
    esac
    _mkt_src="$controller_plugins/marketplaces/$_mkt_id"
    # Even when known_marketplaces.json carries an entry, the on-disk
    # mirror tree may not yet exist (common for git-source marketplaces
    # on a fresh checkout, or directory-source marketplaces whose cache
    # has been pruned). Surface a warn so operators can act on the
    # diagnostic — the alternative is silent plugin drop at session
    # start with zero log signal (#362).
    if [[ ! -d "$_mkt_src" ]]; then
      bridge_warn "marketplace ${_mkt_id} is in known_marketplaces.json but the controller-side tree at ${_mkt_src} is missing — declared plugins from this marketplace will not load. Operator must run \`/plugin marketplace add\` once with credentials, then re-run isolation prepare."
      continue
    fi
    if (( _marketplaces_root_created == 0 )); then
      bridge_linux_sudo_root mkdir -p "$_isolated_marketplaces"
      if bridge_isolation_v2_active; then
        # PR-E: same group-mode contract as the plugins/ root above —
        # root:ab-agent-<name> 2750 + setgid for new children.
        bridge_linux_sudo_root chown "root:${_v2_grp}" "$_isolated_marketplaces" \
          || bridge_die "isolation v2: chown root:${_v2_grp} on '$_isolated_marketplaces' failed"
        bridge_linux_sudo_root chmod 2750 "$_isolated_marketplaces" \
          || bridge_die "isolation v2: chmod 2750 on '$_isolated_marketplaces' failed"
      else
        bridge_linux_sudo_root chown root:root "$_isolated_marketplaces"
        bridge_linux_sudo_root chmod 0750 "$_isolated_marketplaces"
        bridge_linux_acl_add "u:${os_user}:r-x" "$_isolated_marketplaces"
      fi
      _marketplaces_root_created=1
    fi
    _mkt_dst="$_isolated_marketplaces/$_mkt_id"
    bridge_linux_sudo_root rm -f "$_mkt_dst" >/dev/null 2>&1 || true
    bridge_linux_sudo_root ln -s "$_mkt_src" "$_mkt_dst"
    bridge_linux_sudo_root chown -h root:root "$_mkt_dst" >/dev/null 2>&1 || true
    # r#362: end-to-end readability for the symlinked marketplace tree.
    # Without all three steps, the symlink is planted but EACCES on first
    # read and Claude silently drops the plugin from the session. Order
    # matters: traverse_chain stamps `--x` on every node from target up
    # to controller_home (including target). The recursive r-X grant
    # must run AFTER so target/<file> entries end up with r--/r-x rather
    # than --x. Default-ACL inheritance covers files added on the next
    # marketplace refresh. Fail-loud throughout: a partially-applied ACL
    # leaves the symlink planted but unusable, which defeats the fix.
    bridge_linux_grant_traverse_chain "$os_user" "$_mkt_src" "$controller_home" || \
      bridge_die "marketplace tree: failed to grant traverse chain to $_mkt_src"
    bridge_linux_acl_add_recursive "u:${os_user}:r-X" "$_mkt_src" || \
      bridge_die "marketplace tree: failed to grant recursive r-X ACL on $_mkt_src"
    bridge_linux_acl_add_default_dirs_recursive "u:${os_user}:r-X" "$_mkt_src" || \
      bridge_die "marketplace tree: failed to set default ACL inheritance on $_mkt_src"
  done

  # 5c. Persist the new grant set so the next reapply / unisolate sees
  #     exactly what we touched here. Persisted entries cover both the
  #     channel-derived and BRIDGE_AGENT_PLUGINS-derived plugins (both
  #     stored in `plugin:<id>` form), so the unisolate revoke loop in
  #     bridge_migration_unisolate strips the union without further
  #     wiring.
  local _persist_csv=""
  if [[ "${#_current_plugin_channels[@]}" -gt 0 ]]; then
    _persist_csv="$(IFS=','; printf '%s' "${_current_plugin_channels[*]}")"
  fi
  bridge_isolated_plugin_grants_write "$agent" "$_persist_csv"

  # 5d. Audit row so operators can confirm exactly which plugins landed
  #     on the isolated UID after each reapply (#348). The detail rows
  #     carry the union list (channel + allowlist) and its size so a
  #     follow-up `bridge-audit` query can surface domain-plugin
  #     propagation gaps without a manual sudo into the UID's home.
  local _audit_csv="$_persist_csv"
  local _audit_count="${#_current_plugin_channels[@]}"
  bridge_audit_log daemon isolated_plugin_manifest_written "$agent" \
    --detail os_user="$os_user" \
    --detail plugin_count="$_audit_count" \
    --detail plugins="$_audit_csv" >/dev/null 2>&1 || true
}

bridge_linux_unshare_plugin_catalog() {
  # Tear down the isolated-side artifacts created by
  # bridge_linux_share_plugin_catalog: catalog symlinks under
  # $user_home/.claude/plugins/, the per-UID installed_plugins.json,
  # and the plugins/ directory itself if it ends up empty after the
  # symlink + manifest cleanup. plugins/data/ is preserved on purpose —
  # it is owned by the isolated UID and contains plugin-runtime state
  # the agent has produced; resetting that is a separate concern. The
  # function is dry-run aware so it can compose with
  # bridge_migration_unisolate's existing dry_run gate. (Blocking 4 in
  # PR #302 r1.)
  local os_user="$1"
  local user_home="$2"
  local dry_run="$3"

  local isolated_plugins="$user_home/.claude/plugins"
  [[ -n "$user_home" ]] || return 0
  [[ -d "$isolated_plugins" ]] || return 0

  local catalog_file=""
  local link=""
  for catalog_file in "${BRIDGE_ISOLATION_SHARED_CATALOG_READ_FILES[@]}"; do
    link="$isolated_plugins/$catalog_file"
    [[ -e "$link" || -L "$link" ]] || continue
    bridge_migration_print_step "$dry_run" "rm $link (isolated catalog symlink)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root rm -f "$link" >/dev/null 2>&1 || true
    fi
  done

  local manifest="$isolated_plugins/installed_plugins.json"
  if [[ -e "$manifest" ]]; then
    bridge_migration_print_step "$dry_run" "rm $manifest (per-UID installed_plugins.json)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root rm -f "$manifest" >/dev/null 2>&1 || true
    fi
  fi

  # Marketplaces/ symlinks (#348) — created by share for plugins in
  # `<plugin>@<marketplace>` form whose marketplace tree exists at the
  # controller. Strip the symlinks the share path planted, then rmdir the
  # marketplaces/ dir if it ends up empty so the outer rmdir below can
  # also tear down plugins/. plugins/data/ remains untouched.
  local isolated_marketplaces="$isolated_plugins/marketplaces"
  if [[ -d "$isolated_marketplaces" || -L "$isolated_marketplaces" ]]; then
    bridge_migration_print_step "$dry_run" "rm $isolated_marketplaces/* symlinks (isolated marketplace symlinks)"
    if [[ "$dry_run" != "1" ]]; then
      bridge_linux_sudo_root bash -c "shopt -s nullglob dotglob; for entry in \"$isolated_marketplaces\"/*; do [[ -L \"\$entry\" ]] && rm -f \"\$entry\"; done" >/dev/null 2>&1 || true
      bridge_linux_sudo_root rmdir "$isolated_marketplaces" >/dev/null 2>&1 || true
    fi
  fi

  # Only rmdir plugins/ when it ends up empty after the strip. If
  # plugins/data/ (or anything else the agent has produced) still
  # exists, leave the directory alone — its contents belong to the
  # isolated UID, not to bridge isolation.
  if [[ "$dry_run" != "1" ]]; then
    if bridge_linux_sudo_root bash -c "shopt -s nullglob dotglob; entries=(\"$isolated_plugins\"/*); ((\${#entries[@]} == 0))" >/dev/null 2>&1; then
      bridge_migration_print_step "$dry_run" "rmdir $isolated_plugins (empty)"
      bridge_linux_sudo_root rmdir "$isolated_plugins" >/dev/null 2>&1 || true
    else
      bridge_migration_print_step "$dry_run" "$isolated_plugins not empty (preserving plugins/data/ etc.)"
    fi
  else
    bridge_migration_print_step "$dry_run" "rmdir $isolated_plugins if empty (skipped in dry-run)"
  fi
}

bridge_tmp_ephemeral_path_is() {
  local path="${1:-}"
  local tmpdir="${TMPDIR:-}"
  local tmpdir_real=""

  [[ -n "$path" ]] || return 1
  case "$path" in
    /tmp/tmp.*|/tmp/tmp.*/*|/var/tmp/tmp.*|/var/tmp/tmp.*/*|/private/tmp/tmp.*|/private/tmp/tmp.*/*)
      return 0
      ;;
  esac
  if [[ -n "$tmpdir" ]]; then
    tmpdir="${tmpdir%/}"
    case "$path" in
      "$tmpdir"/tmp.*|"$tmpdir"/tmp.*/*)
        return 0
        ;;
    esac
    if [[ -d "$tmpdir" ]]; then
      tmpdir_real="$(cd -P "$tmpdir" 2>/dev/null && pwd -P || true)"
      tmpdir_real="${tmpdir_real%/}"
      if [[ -n "$tmpdir_real" && "$tmpdir_real" != "$tmpdir" ]]; then
        case "$path" in
          "$tmpdir_real"/tmp.*|"$tmpdir_real"/tmp.*/*)
            return 0
            ;;
        esac
      fi
    fi
  fi
  return 1
}

bridge_reject_ephemeral_controller_env_for_agent_env() {
  local name=""
  local value=""
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
  )

  [[ "${BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV:-0}" == "1" ]] && return 0

  for name in "${path_vars[@]}"; do
    value="${!name:-}"
    [[ -n "$value" ]] || continue
    if bridge_tmp_ephemeral_path_is "$value"; then
      bridge_die "refusing to write isolated agent-env.sh from ephemeral controller path ${name}=${value}; unset stale BRIDGE_* variables before running isolate/start, or set BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1 for a deliberate temp test install"
    fi
  done
}

bridge_write_linux_agent_env_file() {
  local agent="$1"
  local file="${2:-$(bridge_agent_linux_env_file "$agent")}"
  local description=""
  local engine=""
  local session=""
  local workdir=""
  local profile_home=""
  local launch_cmd=""
  local channels=""
  local discord_channel=""
  local notify_kind=""
  local notify_target=""
  local notify_account=""
  local loop_mode=""
  local continue_mode=""
  local idle_timeout=""
  local session_id=""
  local history_key=""
  local created_at=""
  local updated_at=""
  local isolation_mode=""
  local os_user=""
  local admin_agent=""
  local agent_log_dir=""
  local agent_audit_log=""

  description="$(bridge_agent_desc "$agent")"
  engine="$(bridge_agent_engine "$agent")"
  session="$(bridge_agent_session "$agent")"
  workdir="$(bridge_agent_workdir "$agent")"
  profile_home="$(bridge_agent_profile_home "$agent")"
  launch_cmd="$(bridge_agent_launch_cmd_raw "$agent")"
  channels="$(bridge_agent_channels_csv "$agent")"
  discord_channel="$(bridge_agent_discord_channel_id "$agent")"
  notify_kind="$(bridge_agent_notify_kind "$agent")"
  notify_target="$(bridge_agent_notify_target "$agent")"
  notify_account="$(bridge_agent_notify_account "$agent")"
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  idle_timeout="$(bridge_agent_idle_timeout "$agent")"
  session_id="$(bridge_agent_session_id "$agent")"
  history_key="${BRIDGE_AGENT_HISTORY_KEY[$agent]-}"
  created_at="${BRIDGE_AGENT_CREATED_AT[$agent]-}"
  updated_at="${BRIDGE_AGENT_UPDATED_AT[$agent]-}"
  isolation_mode="$(bridge_agent_isolation_mode "$agent")"
  os_user="$(bridge_agent_os_user "$agent")"
  admin_agent="$(bridge_admin_agent_id)"
  agent_log_dir="$(bridge_agent_log_dir "$agent")"
  agent_audit_log="$(bridge_agent_audit_log_file "$agent")"

  bridge_reject_ephemeral_controller_env_for_agent_env

  mkdir -p "$(dirname "$file")"
  # Self-heal ownership: when an earlier isolate cycle chowned the file to the
  # isolated os_user, `cat >` preserves ownership and the trailing `chmod 600`
  # fails with EPERM for the operator. Drop the stale inode (via sudo when
  # linux-user isolation is active) so the redirect creates a fresh one owned
  # by the current UID. See issue #112 retest.
  if [[ -e "$file" && ! -O "$file" ]]; then
    if [[ "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]] \
        && command -v bridge_linux_sudo_root >/dev/null 2>&1; then
      bridge_linux_sudo_root rm -f "$file" 2>/dev/null || rm -f "$file"
    else
      rm -f "$file"
    fi
  fi
  cat >"$file" <<EOF
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_HOME=$(printf '%q' "$BRIDGE_HOME")
BRIDGE_STATE_DIR=$(printf '%q' "$BRIDGE_STATE_DIR")
BRIDGE_ACTIVE_AGENT_DIR=$(printf '%q' "$BRIDGE_ACTIVE_AGENT_DIR")
BRIDGE_HISTORY_DIR=$(printf '%q' "$BRIDGE_HISTORY_DIR")
BRIDGE_WORKTREE_META_DIR=$(printf '%q' "$BRIDGE_WORKTREE_META_DIR")
BRIDGE_ACTIVE_ROSTER_TSV=$(printf '%q' "$BRIDGE_ACTIVE_ROSTER_TSV")
BRIDGE_ACTIVE_ROSTER_MD=$(printf '%q' "$BRIDGE_ACTIVE_ROSTER_MD")
BRIDGE_DAEMON_PID_FILE=$(printf '%q' "$BRIDGE_DAEMON_PID_FILE")
BRIDGE_DAEMON_LOG=$(printf '%q' "$BRIDGE_DAEMON_LOG")
BRIDGE_DAEMON_CRASH_LOG=$(printf '%q' "$BRIDGE_DAEMON_CRASH_LOG")
# BRIDGE_TASK_DB is sentineled (not the live path) for isolated UIDs: every
# queue read/write must route through the gateway proxy when
# BRIDGE_GATEWAY_PROXY=1. Emitting the real path would disclose operator state
# layout (#287 / #294 r1 finding 4) and re-open a direct-DB code path. Setting
# /dev/null fails loudly if any caller bypasses the gateway and tries sqlite.
BRIDGE_TASK_DB=/dev/null
BRIDGE_PROFILE_STATE_DIR=$(printf '%q' "$BRIDGE_PROFILE_STATE_DIR")
BRIDGE_CRON_STATE_DIR=$(printf '%q' "$BRIDGE_CRON_STATE_DIR")
BRIDGE_CRON_HOME_DIR=$(printf '%q' "$BRIDGE_CRON_HOME_DIR")
BRIDGE_WORKTREE_ROOT=$(printf '%q' "$BRIDGE_WORKTREE_ROOT")
BRIDGE_AGENT_HOME_ROOT=$(printf '%q' "$BRIDGE_AGENT_HOME_ROOT")
BRIDGE_RUNTIME_ROOT=$(printf '%q' "$BRIDGE_RUNTIME_ROOT")
BRIDGE_RUNTIME_SCRIPTS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SCRIPTS_DIR")
BRIDGE_RUNTIME_SKILLS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SKILLS_DIR")
BRIDGE_RUNTIME_SHARED_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_DIR")
BRIDGE_RUNTIME_SHARED_TOOLS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_TOOLS_DIR")
BRIDGE_RUNTIME_SHARED_REFERENCES_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SHARED_REFERENCES_DIR")
BRIDGE_RUNTIME_MEMORY_DIR=$(printf '%q' "$BRIDGE_RUNTIME_MEMORY_DIR")
BRIDGE_RUNTIME_CREDENTIALS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_CREDENTIALS_DIR")
BRIDGE_RUNTIME_SECRETS_DIR=$(printf '%q' "$BRIDGE_RUNTIME_SECRETS_DIR")
BRIDGE_RUNTIME_CONFIG_FILE=$(printf '%q' "$BRIDGE_RUNTIME_CONFIG_FILE")
BRIDGE_HOOKS_DIR=$(printf '%q' "$BRIDGE_HOOKS_DIR")
BRIDGE_SHARED_DIR=$(printf '%q' "$BRIDGE_SHARED_DIR")
BRIDGE_LAYOUT=$(printf '%q' "${BRIDGE_LAYOUT:-legacy}")
BRIDGE_DATA_ROOT=$(printf '%q' "${BRIDGE_DATA_ROOT:-}")
BRIDGE_SHARED_ROOT=$(printf '%q' "${BRIDGE_SHARED_ROOT:-}")
BRIDGE_AGENT_ROOT_V2=$(printf '%q' "${BRIDGE_AGENT_ROOT_V2:-}")
BRIDGE_CONTROLLER_STATE_ROOT=$(printf '%q' "${BRIDGE_CONTROLLER_STATE_ROOT:-}")
BRIDGE_SHARED_GROUP=$(printf '%q' "${BRIDGE_SHARED_GROUP:-ab-shared}")
BRIDGE_CONTROLLER_GROUP=$(printf '%q' "${BRIDGE_CONTROLLER_GROUP:-ab-controller}")
BRIDGE_AGENT_GROUP_PREFIX=$(printf '%q' "${BRIDGE_AGENT_GROUP_PREFIX:-ab-agent-}")
# Marker dir is anchored separately so children resolve the marker even if
# BRIDGE_STATE_DIR is rebased (controller-state relocation, future PR).
BRIDGE_LAYOUT_MARKER_DIR=$(printf '%q' "${BRIDGE_LAYOUT_MARKER_DIR:-${BRIDGE_HOME}/state}")
export BRIDGE_LAYOUT BRIDGE_DATA_ROOT BRIDGE_SHARED_ROOT BRIDGE_AGENT_ROOT_V2 BRIDGE_CONTROLLER_STATE_ROOT BRIDGE_SHARED_GROUP BRIDGE_CONTROLLER_GROUP BRIDGE_AGENT_GROUP_PREFIX BRIDGE_LAYOUT_MARKER_DIR
BRIDGE_LOG_DIR=$(printf '%q' "$agent_log_dir")
BRIDGE_AUDIT_LOG=$(printf '%q' "$agent_audit_log")
BRIDGE_ROSTER_FILE=""
BRIDGE_ROSTER_LOCAL_FILE=""
BRIDGE_ADMIN_AGENT_ID=$(printf '%q' "$admin_agent")
BRIDGE_AGENT_ID=$(printf '%q' "$agent")
export BRIDGE_AGENT_ID
BRIDGE_AGENT_IDS=()
declare -g -A BRIDGE_AGENT_DESC=()
declare -g -A BRIDGE_AGENT_ENGINE=()
declare -g -A BRIDGE_AGENT_SESSION=()
declare -g -A BRIDGE_AGENT_WORKDIR=()
declare -g -A BRIDGE_AGENT_PROFILE_HOME=()
declare -g -A BRIDGE_AGENT_LAUNCH_CMD=()
declare -g -A BRIDGE_AGENT_SOURCE=()
declare -g -A BRIDGE_AGENT_LOOP=()
declare -g -A BRIDGE_AGENT_CONTINUE=()
declare -g -A BRIDGE_AGENT_SESSION_ID=()
declare -g -A BRIDGE_AGENT_HISTORY_KEY=()
declare -g -A BRIDGE_AGENT_CREATED_AT=()
declare -g -A BRIDGE_AGENT_UPDATED_AT=()
declare -g -A BRIDGE_AGENT_IDLE_TIMEOUT=()
declare -g -A BRIDGE_AGENT_NOTIFY_KIND=()
declare -g -A BRIDGE_AGENT_NOTIFY_TARGET=()
declare -g -A BRIDGE_AGENT_NOTIFY_ACCOUNT=()
declare -g -A BRIDGE_AGENT_DISCORD_CHANNEL_ID=()
declare -g -A BRIDGE_AGENT_CHANNELS=()
declare -g -A BRIDGE_AGENT_PLUGINS=()
declare -g -A BRIDGE_AGENT_ISOLATION_MODE=()
declare -g -A BRIDGE_AGENT_OS_USER=()
declare -g -A BRIDGE_AGENT_MODEL=()
declare -g -A BRIDGE_AGENT_EFFORT=()
declare -g -A BRIDGE_AGENT_PERMISSION_MODE=()
declare -g -A BRIDGE_AGENT_PROMPT_GUARD=()
declare -g -A BRIDGE_AGENT_CLASS=()
EOF
  # Self entry first: full record including LAUNCH_CMD (the calling agent's
  # own launch command may legitimately carry tokens; ACLs already restrict
  # the file to the calling UID + controller).
  cat >>"$file" <<EOF
bridge_add_agent_id_if_missing $(printf '%q' "$agent")
BRIDGE_AGENT_DESC[$(printf '%q' "$agent")]=$(printf '%q' "$description")
BRIDGE_AGENT_ENGINE[$(printf '%q' "$agent")]=$(printf '%q' "$engine")
BRIDGE_AGENT_SESSION[$(printf '%q' "$agent")]=$(printf '%q' "$session")
BRIDGE_AGENT_WORKDIR[$(printf '%q' "$agent")]=$(printf '%q' "$workdir")
BRIDGE_AGENT_PROFILE_HOME[$(printf '%q' "$agent")]=$(printf '%q' "$profile_home")
BRIDGE_AGENT_LAUNCH_CMD[$(printf '%q' "$agent")]=$(printf '%q' "$launch_cmd")
BRIDGE_AGENT_SOURCE[$(printf '%q' "$agent")]="static"
BRIDGE_AGENT_LOOP[$(printf '%q' "$agent")]=$(printf '%q' "$loop_mode")
BRIDGE_AGENT_CONTINUE[$(printf '%q' "$agent")]=$(printf '%q' "$continue_mode")
BRIDGE_AGENT_SESSION_ID[$(printf '%q' "$agent")]=$(printf '%q' "$session_id")
BRIDGE_AGENT_HISTORY_KEY[$(printf '%q' "$agent")]=$(printf '%q' "$history_key")
BRIDGE_AGENT_CREATED_AT[$(printf '%q' "$agent")]=$(printf '%q' "$created_at")
BRIDGE_AGENT_UPDATED_AT[$(printf '%q' "$agent")]=$(printf '%q' "$updated_at")
BRIDGE_AGENT_IDLE_TIMEOUT[$(printf '%q' "$agent")]=$(printf '%q' "$idle_timeout")
BRIDGE_AGENT_NOTIFY_KIND[$(printf '%q' "$agent")]=$(printf '%q' "$notify_kind")
BRIDGE_AGENT_NOTIFY_TARGET[$(printf '%q' "$agent")]=$(printf '%q' "$notify_target")
BRIDGE_AGENT_NOTIFY_ACCOUNT[$(printf '%q' "$agent")]=$(printf '%q' "$notify_account")
BRIDGE_AGENT_DISCORD_CHANNEL_ID[$(printf '%q' "$agent")]=$(printf '%q' "$discord_channel")
BRIDGE_AGENT_CHANNELS[$(printf '%q' "$agent")]=$(printf '%q' "$channels")
BRIDGE_AGENT_ISOLATION_MODE[$(printf '%q' "$agent")]=$(printf '%q' "$isolation_mode")
BRIDGE_AGENT_OS_USER[$(printf '%q' "$agent")]=$(printf '%q' "$os_user")
BRIDGE_AGENT_PROMPT_GUARD[$(printf '%q' "$agent")]=$(printf '%q' "${BRIDGE_AGENT_PROMPT_GUARD[$agent]-}")
BRIDGE_AGENT_CLASS[$(printf '%q' "$agent")]=$(printf '%q' "$(bridge_agent_class "$agent")")
EOF
  # Peer entries: id + non-secret metadata. NEVER emit a peer's LAUNCH_CMD
  # (token-bearing) or PROMPT_GUARD policy (canary tokens at
  # lib/bridge-guard.sh:123 are sensitive — see #294 r1 finding 3). The empty
  # LAUNCH_CMD / PROMPT_GUARD entries are written explicitly so the array shape
  # stays consistent across map keys; downstream callers that require the
  # launch command for a peer must fall through to the controller (queue
  # gateway path). Client-side guard parity for peers is intentionally dropped:
  # gateway-side enforcement remains, and a follow-up issue covers the case if
  # peer-targeted prompt blocking before queue submission is actually needed.
  local peer=""
  for peer in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$peer" == "$agent" ]] && continue
    [[ "$(bridge_agent_source "$peer")" == "static" ]] || continue
    local peer_desc peer_engine peer_session peer_workdir peer_isolation
    local peer_source
    peer_desc="$(bridge_agent_desc "$peer")"
    peer_engine="$(bridge_agent_engine "$peer")"
    peer_session="$(bridge_agent_session "$peer")"
    peer_workdir="$(bridge_agent_workdir "$peer")"
    peer_isolation="$(bridge_agent_isolation_mode "$peer")"
    peer_source="$(bridge_agent_source "$peer")"
    cat >>"$file" <<EOF
bridge_add_agent_id_if_missing $(printf '%q' "$peer")
BRIDGE_AGENT_DESC[$(printf '%q' "$peer")]=$(printf '%q' "$peer_desc")
BRIDGE_AGENT_ENGINE[$(printf '%q' "$peer")]=$(printf '%q' "$peer_engine")
BRIDGE_AGENT_SESSION[$(printf '%q' "$peer")]=$(printf '%q' "$peer_session")
BRIDGE_AGENT_WORKDIR[$(printf '%q' "$peer")]=$(printf '%q' "$peer_workdir")
BRIDGE_AGENT_SOURCE[$(printf '%q' "$peer")]=$(printf '%q' "$peer_source")
BRIDGE_AGENT_ISOLATION_MODE[$(printf '%q' "$peer")]=$(printf '%q' "$peer_isolation")
BRIDGE_AGENT_LAUNCH_CMD[$(printf '%q' "$peer")]=''
BRIDGE_AGENT_PROMPT_GUARD[$(printf '%q' "$peer")]=''
EOF
  done
  # Explicit gateway-proxy signal for isolated agents. Decouples gateway
  # routing from `${#BRIDGE_AGENT_IDS[@]}` so the peer-id additions above do
  # not accidentally drop the agent off the gateway. See issue #294 +
  # bridge_queue_gateway_proxy_agent.
  #
  # BRIDGE_CONTROLLER_UID is the writer's UID (this function runs in the
  # controller context). The bin/agb shim uses it to confirm a strict UID
  # mismatch before applying the isolated-CLI allowlist (issue #544 PR4) —
  # the gateway-proxy flag alone could be spoofed by an operator who
  # manually exports it in their own shell.
  if [[ "$isolation_mode" == "linux-user" ]]; then
    local _controller_uid
    _controller_uid="$(id -u)"
    cat >>"$file" <<EOF
BRIDGE_GATEWAY_PROXY=1
export BRIDGE_GATEWAY_PROXY
BRIDGE_CONTROLLER_UID=$(printf '%q' "$_controller_uid")
export BRIDGE_CONTROLLER_UID
EOF
  fi
  # Inject engine CLI directory into PATH for sudo-wrapped launchers when
  # isolation is active. Under sudo, PATH falls back to secure_path which
  # almost never contains the operator's per-user bin (e.g.
  # ~/.local/bin/claude), so the launcher's bare `claude` / `codex` call
  # would die with "command not found". Resolving on every start picks up
  # CLI upgrades automatically; the matching ACL grant lives in
  # bridge_linux_grant_engine_cli_access (one-shot at isolate time).
  if [[ "$isolation_mode" == "linux-user" ]]; then
    if [[ -n "$engine" ]]; then
      local _engine_cli _engine_dir
      _engine_cli="$(bridge_resolve_engine_cli "$engine" 2>/dev/null || printf '')"
      if [[ -n "$_engine_cli" ]]; then
        _engine_dir="$(dirname "$_engine_cli")"
        printf '\nexport PATH=%s:"${PATH:-/usr/local/bin:/usr/bin:/bin}"\n' \
          "$(printf '%q' "$_engine_dir")" >>"$file"
      fi
    fi
    # Curated bridge bin dir (issue #544 PR1). Lets the isolated UID call
    # `agb` bare from a Bash tool subprocess. Only the curated shim at
    # ${BRIDGE_HOME}/bin/agb is exposed here — broader agent-bridge
    # subcommand surface stays gated behind PR4's default-deny design.
    # Matching ACL grant lives in bridge_linux_grant_bin_dir_access
    # (one-shot at isolate time).
    printf '\nexport PATH=%s:"${PATH:-/usr/local/bin:/usr/bin:/bin}"\n' \
      "$(printf '%q' "$BRIDGE_HOME/bin")" >>"$file"
  fi
  chmod 600 "$file"
  # PR-E: in v2 mode, replace the named-user ACL grant pair with a
  # group-mode contract — chgrp ab-agent-<name> + chmod 0640. The agent
  # group has both the isolated UID (read) and the controller (read+
  # owner write) as members per PR-C, so 0640 covers both without ACL.
  # Owner stays controller (the redirect just above set up that owner
  # already; the stale-inode drop earlier in this function self-heals
  # any prior chowned-to-os_user state).
  if [[ "$isolation_mode" == "linux-user" \
        && -n "$os_user" \
        && "$(bridge_host_platform 2>/dev/null || printf '')" == "Linux" ]]; then
    if bridge_isolation_v2_active; then
      local _v2_grp
      _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
        || _v2_grp=""
      if [[ -n "$_v2_grp" ]]; then
        bridge_linux_sudo_root chgrp "$_v2_grp" "$file" \
          || bridge_die "isolation v2: chgrp '$_v2_grp' on env file '$file' failed"
        bridge_linux_sudo_root chmod 0640 "$file" \
          || bridge_die "isolation v2: chmod 0640 on env file '$file' failed"
      else
        bridge_die "isolation v2: cannot resolve agent group for env file '$file'"
      fi
    else
      # `chmod 600` maps to mask::--- on a file that already carries named-user
      # ACLs (POSIX ACL: chmod's group bits drive the mask when named entries
      # exist). isolate originally grants the isolated UID `u:<os_user>:r--` so
      # it can read agent-env.sh under sudo-wrap, but the mask wipe makes that
      # entry effective `---`, so subsequent `agent start` cycles fail silently
      # — bridge-run.sh sources nothing, sees an empty roster, and exits before
      # tmux is created. Re-apply the named-user ACL so setfacl recomputes the
      # mask back to rw- (or whatever covers the named entries).
      if command -v bridge_linux_acl_add >/dev/null 2>&1; then
        local _controller_user
        _controller_user="$(bridge_current_user 2>/dev/null || printf '')"
        bridge_linux_acl_add "u:${os_user}:r--" "$file" >/dev/null 2>&1 || true
        if [[ -n "$_controller_user" ]]; then
          bridge_linux_acl_add "u:${_controller_user}:rw-" "$file" >/dev/null 2>&1 || true
        fi
      fi
    fi
  fi
}

bridge_linux_prepare_agent_isolation() {
  local agent="$1"
  local os_user="$2"
  local workdir="$3"
  local controller_user="${4:-$(bridge_current_user)}"
  local user_home=""
  local env_file=""
  local runtime_state_dir=""
  local log_dir=""
  local audit_file=""
  local history_file=""
  local request_dir=""
  local response_dir=""
  local other=""
  local other_workdir=""
  local other_queue_dir=""
  local -a recursive_read_paths=()
  local -a recursive_write_paths=()
  local -a hidden_paths=()

  [[ "$(bridge_host_platform)" == "Linux" ]] || return 0
  [[ -n "$os_user" ]] || bridge_die "linux-user isolation requires os_user"

  # PR-E r2 P1#2 fix: in v2 mode, the channel symlink + workdir mutations
  # downstream perform check-then-mutate sequences on paths whose parent
  # is owned by the isolated UID. A running agent could win a swap race
  # between guard and mutation. Require the agent's tmux session to be
  # quiesced before prepare/reapply so the isolated UID cannot race.
  # Install path (fresh agent) has no session yet → loop no-ops.
  # Reapply / migration path (running agent) → operator must stop first.
  # BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING is an opt-out for sandboxed
  # smoke fixtures that simulate isolation prepare without a real tmux
  # binary on the host.
  if bridge_isolation_v2_active && [[ "${BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING:-0}" != "1" ]]; then
    local _quiesce_session=""
    _quiesce_session="$(bridge_agent_session "$agent" 2>/dev/null || printf '')"
    if [[ -n "$_quiesce_session" ]] \
        && command -v tmux >/dev/null 2>&1 \
        && bridge_tmux_session_exists "$_quiesce_session"; then
      bridge_die "isolation v2 prepare requires the agent session to be stopped: tmux session '$_quiesce_session' is alive (channel/workdir mutations are not race-safe on a live isolated UID). Run \`agb agent stop $agent\` first, then retry."
    fi
  fi

  # PR-E: setfacl is the legacy-mode prerequisite. v2 mode replaces named-
  # user ACLs with group setgid except for the Claude credential exception
  # (bridge_linux_grant_claude_credentials_access), so v2 still requires
  # setfacl when engine=claude. v2 + non-claude can skip the package.
  if ! bridge_isolation_v2_active; then
    bridge_linux_require_setfacl
  elif [[ "$(bridge_agent_engine "$agent")" == "claude" ]]; then
    bridge_linux_require_setfacl
  fi
  user_home="$(bridge_agent_linux_user_home "$os_user")"
  env_file="$(bridge_agent_linux_env_file "$agent")"
  runtime_state_dir="$(bridge_agent_runtime_state_dir "$agent")"
  log_dir="$(bridge_agent_log_dir "$agent")"
  audit_file="$(bridge_agent_audit_log_file "$agent")"
  history_file="$(bridge_history_file_for_agent "$agent")"
  request_dir="$(bridge_queue_gateway_requests_dir "$agent")"
  response_dir="$(bridge_queue_gateway_responses_dir "$agent")"
  local queue_gateway_root=""
  local queue_gateway_agent_dir=""
  queue_gateway_root="$(bridge_queue_gateway_root)"
  queue_gateway_agent_dir="$(bridge_queue_gateway_agent_dir "$agent")"

  bridge_linux_ensure_os_user "$os_user" "$user_home"
  bridge_linux_ensure_user_home "$os_user" "$user_home"
  bridge_linux_install_agent_bridge_symlink "$os_user" "$user_home" "$BRIDGE_HOME"

  # v2 layout: lay down the per-agent private root before any ACL grants
  # touch its children. The contract is:
  #   $BRIDGE_AGENT_ROOT_V2/<agent>            owner=root, group=ab-agent-<name>, mode 2750
  #   ├── home/, workdir/, runtime/, logs/,
  #   │   requests/, responses/                 owner=isolated, group=ab-agent-<name>, mode 2770
  #   └── credentials/                          owner=controller, group=ab-agent-<name>, mode 2750
  #       └── launch-secrets.env                owner=controller, group=ab-agent-<name>, mode 0640
  # The root mode 2750 means unrelated UIDs cannot traverse/list the
  # private root; the isolated UID enters via group r-x but cannot write
  # at the root level — so it cannot rm/mv `credentials/` or its file.
  if bridge_isolation_v2_active; then
    local _v2_agent_group _v2_agent_root _v2_credentials_dir _v2_subdir
    _v2_agent_group="$(bridge_isolation_v2_agent_group_name "$agent")" \
      || bridge_die "isolation v2: invalid agent name '$agent' for group composition"
    bridge_isolation_v2_ensure_group "$_v2_agent_group" \
      || bridge_die "isolation v2: cannot ensure group '$_v2_agent_group'"
    bridge_isolation_v2_ensure_user_in_group "$os_user" "$_v2_agent_group" \
      || bridge_die "isolation v2: cannot add '$os_user' to '$_v2_agent_group'"
    bridge_isolation_v2_ensure_user_in_group "$controller_user" "$_v2_agent_group" \
      || bridge_die "isolation v2: cannot add controller '$controller_user' to '$_v2_agent_group'"

    # PR-E: shared-group membership. PR-C migration adds existing agents
    # to ab-shared, but a new/reapplied agent through prepare must also
    # join so bridge_linux_share_plugin_catalog can read the shared
    # plugin cache. ensure_group is idempotent. Controller missing from
    # ab-shared is recoverable iff the operator's own context can still
    # read the shared plugin cache (group bit on a session that already
    # had ab-shared, or shared-group home with `other` bit), so escalate
    # the warn to die only when readability fails.
    local _v2_shared_grp="${BRIDGE_SHARED_GROUP:-ab-shared}"
    bridge_isolation_v2_ensure_group "$_v2_shared_grp" \
      || bridge_die "isolation v2: cannot ensure shared group '$_v2_shared_grp'"
    bridge_isolation_v2_ensure_user_in_group "$os_user" "$_v2_shared_grp" \
      || bridge_die "isolation v2: cannot add '$os_user' to shared group '$_v2_shared_grp'"
    if ! bridge_isolation_v2_ensure_user_in_group "$controller_user" "$_v2_shared_grp"; then
      bridge_warn "isolation v2: controller '$controller_user' membership update for '$_v2_shared_grp' failed; verifying shared plugin cache readability"
      local _v2_shared_plugins_root
      _v2_shared_plugins_root="$(bridge_isolation_v2_shared_plugins_root 2>/dev/null || printf '')"
      if [[ -n "$_v2_shared_plugins_root" && -e "$_v2_shared_plugins_root" \
            && ! -r "$_v2_shared_plugins_root" ]]; then
        bridge_die "isolation v2: controller cannot read shared plugin cache '$_v2_shared_plugins_root'; group membership update for '$_v2_shared_grp' must succeed (re-login the controller after manual usermod, then retry)"
      fi
    fi

    _v2_agent_root="$(bridge_isolation_v2_agent_root "$agent")" \
      || bridge_die "isolation v2: cannot resolve per-agent root for '$agent'"
    bridge_linux_sudo_root mkdir -p "$_v2_agent_root"
    bridge_linux_sudo_root chown root: "$_v2_agent_root"
    bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_agent_root"
    bridge_linux_sudo_root chmod 2750 "$_v2_agent_root"
    for _v2_subdir in home workdir runtime logs requests responses; do
      bridge_linux_sudo_root mkdir -p "$_v2_agent_root/$_v2_subdir"
      bridge_linux_sudo_root chown "$os_user" "$_v2_agent_root/$_v2_subdir"
      bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_agent_root/$_v2_subdir"
      bridge_linux_sudo_root chmod 2770 "$_v2_agent_root/$_v2_subdir"
    done
    _v2_credentials_dir="$(bridge_isolation_v2_agent_credentials_dir "$agent")"
    bridge_linux_sudo_root mkdir -p "$_v2_credentials_dir"
    bridge_linux_sudo_root chown "$controller_user" "$_v2_credentials_dir"
    bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_credentials_dir"
    bridge_linux_sudo_root chmod 2750 "$_v2_credentials_dir"
    # If a launch-secrets.env already exists (carried over from a previous
    # prepare cycle or seeded by migration), normalize its ownership/mode.
    # We do not create it here — the operator/migration tool plants it.
    local _v2_secrets_file
    _v2_secrets_file="$(bridge_isolation_v2_agent_secret_env_file "$agent")"
    if bridge_linux_sudo_root test -f "$_v2_secrets_file"; then
      bridge_linux_sudo_root chown "$controller_user" "$_v2_secrets_file"
      bridge_linux_sudo_root chgrp "$_v2_agent_group" "$_v2_secrets_file"
      bridge_linux_sudo_root chmod 0640 "$_v2_secrets_file"
    fi
  fi

  recursive_read_paths+=("$BRIDGE_HOOKS_DIR" "$BRIDGE_SHARED_DIR")
  [[ -d "$BRIDGE_RUNTIME_ROOT" ]] && recursive_read_paths+=("$BRIDGE_RUNTIME_ROOT")
  [[ -d "$BRIDGE_HOME/.claude" ]] && recursive_read_paths+=("$BRIDGE_HOME/.claude")
  [[ -d "$BRIDGE_HOME/lib" ]] && recursive_read_paths+=("$BRIDGE_HOME/lib")
  # Note: $BRIDGE_HOME/plugins (directory-marketplace source for agent-bridge
  # plugins like teams/ms365) is intentionally NOT in the broad recursive_read
  # set. bridge_linux_share_plugin_catalog grants r-X to declared plugin code
  # paths only, keyed off BRIDGE_AGENT_CHANNELS, so each isolated UID sees
  # only its own plugins.
  [[ -d "$BRIDGE_HOME/scripts" ]] && recursive_read_paths+=("$BRIDGE_HOME/scripts")
  [[ -d "$BRIDGE_AGENT_HOME_ROOT/.claude" ]] && recursive_read_paths+=("$BRIDGE_AGENT_HOME_ROOT/.claude")
  bridge_linux_acl_remove_recursive "u:${os_user}" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"
  bridge_linux_sudo_root mkdir -p "$runtime_state_dir" "$log_dir" "$queue_gateway_root" "$queue_gateway_agent_dir" "$request_dir" "$response_dir" "$(dirname "$history_file")"
  bridge_linux_sudo_root touch "$audit_file" "$history_file"

  # memory-daily state trees for the harvester (issue #219):
  #   <state>/memory-daily/                         — traverse only (r-x)
  #   <state>/memory-daily/<agent>/                 — per-agent rwX
  #   <state>/memory-daily/shared/aggregate/        — shared rwX (all isolated
  #     agents write to the fcntl.flock-guarded aggregate files; no cross-agent
  #     directory-entry tampering because peer <agent>/ dirs remain un-ACL'd)
  local memory_daily_root memory_daily_agent_dir memory_daily_shared_aggregate_dir
  if bridge_isolation_v2_active; then
    # v2 layout: per-agent memory-daily lives inside the per-agent root
    # (group-isolated), shared aggregate lives under BRIDGE_SHARED_ROOT
    # so other agents' harvesters can read it via ab-shared. The legacy
    # `memory_daily_root` aggregate (BRIDGE_STATE_DIR/memory-daily) is no
    # longer the source of truth in v2 — we keep an empty value so any
    # later legacy-only ACL grant on it short-circuits below.
    memory_daily_root=""
    memory_daily_agent_dir="$(bridge_isolation_v2_agent_memory_daily_root "$agent")"
    memory_daily_shared_aggregate_dir="$(bridge_isolation_v2_memory_daily_shared_aggregate_dir)"
  else
    memory_daily_root="$BRIDGE_STATE_DIR/memory-daily"
    memory_daily_agent_dir="$memory_daily_root/$agent"
    memory_daily_shared_aggregate_dir="$memory_daily_root/shared/aggregate"
  fi
  bridge_linux_sudo_root mkdir -p "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"

  # One-shot legacy aggregate migration — runs as sudo-root here so it has
  # write access on the memory-daily root even though the new ACL contract
  # only grants isolated UIDs r-x on the root. Idempotent + safe to re-run.
  # In v2 layout the legacy `<state>/memory-daily/` root is no longer the
  # source of truth, so this one-shot is skipped.
  if [[ -n "$memory_daily_root" ]]; then
    local _agg_name
    for _agg_name in admin-aggregate-skip.json admin-aggregate-escalated.json; do
      if [[ -f "$memory_daily_root/$_agg_name" && ! -f "$memory_daily_shared_aggregate_dir/$_agg_name" ]]; then
        bridge_linux_sudo_root mv "$memory_daily_root/$_agg_name" "$memory_daily_shared_aggregate_dir/$_agg_name"
      fi
      if [[ -f "$memory_daily_root/$_agg_name.lock" && ! -f "$memory_daily_shared_aggregate_dir/$_agg_name.lock" ]]; then
        bridge_linux_sudo_root mv "$memory_daily_root/$_agg_name.lock" "$memory_daily_shared_aggregate_dir/$_agg_name.lock"
      fi
    done
  fi

  if bridge_isolation_v2_active; then
    # v2 split: the per-agent root (= queue_gateway_agent_dir in v2) is
    # root-owned mode 2750 and MUST stay outside the isolated UID's
    # rwX grant set; only the writable subtrees are listed. The isolated
    # UID still reaches requests/responses through ab-agent-<name> group
    # traverse on the parent root.
    #
    # PR-C r3 review P2: $memory_daily_shared_aggregate_dir is removed
    # from the v2 write set. The shared aggregate sits under ab-shared
    # (read-only public per the v2 contract) and the harvester writes it
    # in controller context — isolated UIDs only need read/execute, not
    # write/delete. Granting rwX recursively here would let any isolated
    # agent corrupt the shared admin aggregate.
    recursive_read_paths+=("$memory_daily_shared_aggregate_dir")
    recursive_write_paths+=("$workdir" "$runtime_state_dir" "$log_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir")
  else
    recursive_write_paths+=("$workdir" "$runtime_state_dir" "$log_dir" "$queue_gateway_agent_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir")
  fi
  # Issue: per-agent queue-gateway dir was missing isolated/controller ACLs
  # because only its children (requests/, responses/) were granted. The
  # daemon's controller-side glob of the queue-gateway root and the
  # isolated UID's own inbox traversal both fail without these grants.
  # Root traverse-only on the gateway root for the isolated UID prevents
  # cross-agent dir-name enumeration while keeping its own subtree reachable.
  bridge_linux_acl_add "u:${os_user}:--x" "$queue_gateway_root" >/dev/null 2>&1 || true

  # Issue #412 Track B: grant the isolated UID r-- on its own queue body
  # files. Bodies live under $BRIDGE_STATE_DIR/queue/bodies/ and are
  # written by bridge-queue.py with mode 0600, owner = controller. The
  # queue CLI emits the body path back to callers via TASK_BODY_PATH, and
  # downstream flows (e.g. agb claim wrappers) cat the file directly from
  # the isolated UID context. Without an ACL grant the read fails with
  # EACCES even after agb claim succeeds, leaving the agent with no way
  # to read the body of its own claimed task.
  #
  # Default ACL inheritance grants the same r-- on bodies created later
  # by the controller. Legacy ACL only — under v2 (group setgid) the
  # bridge_linux_acl_add primitive short-circuits to a no-op, and the
  # state/queue/bodies tree inherits the ab-controller group from the
  # state/ parent (which the isolated UID is not a member of). v2 needs
  # a follow-up to extend the queue body share semantics to the per-agent
  # group; until then, v2 installs see the same EACCES as before.
  local _queue_bodies_dir
  _queue_bodies_dir="$BRIDGE_STATE_DIR/queue/bodies"
  bridge_linux_sudo_root mkdir -p "$_queue_bodies_dir"
  if [[ -d "$_queue_bodies_dir" ]]; then
    bridge_linux_acl_add "u:${os_user}:r-x" "$_queue_bodies_dir" >/dev/null 2>&1 || true
    bridge_linux_acl_add_default_dirs_recursive \
      "u:${os_user}:r--" "$_queue_bodies_dir" >/dev/null 2>&1 || true
    bridge_linux_acl_add_recursive \
      "u:${os_user}:r-X" "$_queue_bodies_dir" >/dev/null 2>&1 || true
  fi

  hidden_paths+=("$BRIDGE_ROSTER_FILE" "$BRIDGE_ROSTER_LOCAL_FILE" "$BRIDGE_RUNTIME_CREDENTIALS_DIR" "$BRIDGE_RUNTIME_SECRETS_DIR" "$BRIDGE_RUNTIME_CONFIG_FILE" "$BRIDGE_TASK_DB" "${BRIDGE_LOG_DIR}/audit.jsonl")

  # Issue #233: every traverse_chain call used to climb unconditionally
  # to `/` and stamp `u:${os_user}:--x` on each ancestor, including
  # `/home` and `/`. Pass an explicit stop_path so the walk terminates
  # inside the controller's home. Ancestors above that (`/home`, `/`)
  # already have base `r-x` for `other`, so no named entry is needed —
  # and inserting one would strip the operator's own read access via
  # POSIX ACL override, which is exactly the #233 regression.
  #
  # The $user_home chain is intentionally dropped here: the isolated
  # UID owns its own home outright, and the ancestors `/home` + `/`
  # are already reachable via base permissions.
  local controller_home_for_traverse=""
  controller_home_for_traverse="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
  if [[ -n "$controller_home_for_traverse" && -d "$controller_home_for_traverse" ]]; then
    bridge_linux_grant_traverse_chain "$os_user" "$BRIDGE_HOME" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$workdir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$runtime_state_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$log_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$history_file" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$request_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$response_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$memory_daily_agent_dir" "$controller_home_for_traverse"
    bridge_linux_grant_traverse_chain "$os_user" "$memory_daily_shared_aggregate_dir" "$controller_home_for_traverse"
  else
    bridge_warn "controller_user=$controller_user has no passwd entry / home; traverse grants skipped (isolated agent may hit EACCES)"
  fi
  if [[ -n "$memory_daily_root" ]]; then
    bridge_linux_acl_add "u:${os_user}:r-x" "$memory_daily_root" "$memory_daily_root/shared" >/dev/null 2>&1 || true
  fi

  bridge_linux_acl_add "u:${os_user}:r-x" "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT"
  bridge_linux_acl_add "u:${os_user}:r-x" "$BRIDGE_HOME/agent-bridge" "$BRIDGE_HOME/agb" "$BRIDGE_HOME/VERSION" >/dev/null 2>&1 || true
  # Root-level Bash and Python helpers (bridge-*.sh, bridge-*.py) live next
  # to agent-bridge/agb. lib/scripts/ are already covered by recursive_read_paths,
  # but root helpers like bridge-dev-plugin-cache.py default to mode 600 and
  # have no ACL grant, so things like dev-plugin-cache sync fail with EACCES
  # under the sudo wrap during agent start.
  local _bridge_root_helper
  shopt -s nullglob
  for _bridge_root_helper in "$BRIDGE_HOME"/bridge-*.sh "$BRIDGE_HOME"/bridge-*.py; do
    bridge_linux_acl_add "u:${os_user}:r-x" "$_bridge_root_helper" >/dev/null 2>&1 || true
  done
  shopt -u nullglob
  bridge_linux_grant_engine_cli_access "$os_user" "$(bridge_agent_engine "$agent")"
  bridge_linux_grant_bin_dir_access "$os_user"
  bridge_linux_grant_claude_credentials_access "$os_user" "$user_home" "$controller_user" "$(bridge_agent_engine "$agent")"
  bridge_linux_acl_add_recursive "u:${os_user}:r-X" "${recursive_read_paths[@]}"
  bridge_linux_acl_add_recursive "u:${os_user}:rwX" "${recursive_write_paths[@]}"
  if bridge_isolation_v2_active; then
    # Match the recursive_write_paths v2 split: queue_gateway_agent_dir
    # (= per-agent root, root-owned 2750) is intentionally absent so the
    # isolated UID never inherits a default rwX over its credentials/.
    # $memory_daily_shared_aggregate_dir is also absent here (PR-C r3 P2):
    # default rwX would let new files inside the shared aggregate inherit
    # isolated UID write, defeating the read-only-shared contract.
    bridge_linux_acl_add_default_dirs_recursive "u:${os_user}:rwX" "$runtime_state_dir" "$log_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir"
  else
    bridge_linux_acl_add_default_dirs_recursive "u:${os_user}:rwX" "$runtime_state_dir" "$log_dir" "$queue_gateway_agent_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"
  fi
  bridge_linux_acl_add "u:${os_user}:rw-" "$history_file"

  for other in "${BRIDGE_AGENT_IDS[@]}"; do
    [[ "$other" == "$agent" ]] && continue
    other_workdir="$(bridge_agent_workdir "$other")"
    other_queue_dir="$(bridge_queue_gateway_agent_dir "$other")"
    [[ "$other_workdir" == "$workdir" ]] && continue
    [[ -d "$other_workdir" ]] || continue
    bridge_linux_acl_remove_recursive "u:${os_user}" "$other_workdir"
    [[ -d "$other_queue_dir" ]] && bridge_linux_acl_remove_recursive "u:${os_user}" "$other_queue_dir"
  done

  for other in "${hidden_paths[@]}"; do
    [[ -e "$other" ]] || continue
    bridge_linux_acl_remove_recursive "u:${os_user}" "$other"
  done

  bridge_linux_sudo_root chown -R "$os_user" "$workdir"
  bridge_linux_sudo_root chown -R "$os_user" "$runtime_state_dir" "$log_dir"
  bridge_linux_sudo_root chown "$os_user" "$audit_file" "$history_file"
  bridge_linux_acl_add_recursive "u:${controller_user}:rwX" "$workdir"
  bridge_linux_acl_add_default_dirs_recursive "u:${controller_user}:rwX" "$workdir"
  # Controller (daemon) needs to glob the queue-gateway root to find
  # per-agent requests; r-x on the root + rwX on the agent dir + default
  # ACLs on both keep the daemon's pathlib glob working without exposing
  # other agents' dir contents to isolated UIDs.
  bridge_linux_acl_add "u:${controller_user}:r-x" "$queue_gateway_root"
  # PR-E: in v2 mode the queue-gateway root + per-agent dir live under
  # the v2 group-setgid contract (controller is in the agent group),
  # so the named-user default ACL is redundant and the recursive grant
  # bodies short-circuit via the v2-noop primitives. Skip the lone
  # direct setfacl that bypasses those primitives.
  if ! bridge_isolation_v2_active; then
    bridge_linux_sudo_root setfacl -d -m "u:${controller_user}:r-X" "$queue_gateway_root" >/dev/null 2>&1 || true
  fi
  bridge_linux_acl_add_recursive "u:${controller_user}:rwX" "$runtime_state_dir" "$log_dir" "$queue_gateway_agent_dir" "$request_dir" "$response_dir" "$memory_daily_agent_dir" "$memory_daily_shared_aggregate_dir"
  bridge_linux_acl_add_default_dirs_recursive "u:${controller_user}:rwX" "$queue_gateway_agent_dir" "$request_dir" "$response_dir"

  # memory-daily transcripts read-access (issue #219 v1.3): grant the
  # controller user r-X on the isolated user's ~/.claude/projects/ so the
  # (controller-UID) harvester can _scan_transcripts under the target.
  # We intentionally do NOT grant write — this is a strict read lens.
  #
  # We pre-create $user_home/.claude (owned by the isolated UID, 0700) so
  # the default ACL lands before the first Claude session runs. Otherwise a
  # fresh agent's first `.claude/projects/` directory would be created
  # without the controller r-X inheritance, and the next harvester run
  # would fall back to --skipped-permission until the next reapply.
  local isolated_claude_dir="$user_home/.claude"
  local isolated_projects_dir="$isolated_claude_dir/projects"
  bridge_linux_sudo_root mkdir -p "$isolated_claude_dir"
  bridge_linux_sudo_root chown "$os_user" "$isolated_claude_dir" >/dev/null 2>&1 || true
  # PR-E r2 (FAIL #15): under v2 the legacy ACL grant on this dir is
  # no-op'd (`bridge_linux_acl_add` short-circuits in v2), but the dir
  # itself was still chmod 0700 — group has no traverse, so the
  # controller (group member of ab-agent-<name>) cannot reach
  # ~/.claude/projects/ for the memory-daily harvester. Mirror the
  # group-mode replacements applied to ~/.claude/plugins (lines around
  # 1666-1670) and ~/.claude/plugins/marketplaces: chgrp the v2 agent
  # group + chmod 2750 (setgid so new subdirs like projects/ inherit
  # the group). Legacy keeps 0700 + named-user ACL.
  if bridge_isolation_v2_active; then
    local _claude_v2_grp=""
    _claude_v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')"
    [[ -n "$_claude_v2_grp" ]] \
      || bridge_die "isolation v2: cannot resolve agent group for ~/.claude of '$agent'"
    bridge_linux_sudo_root chgrp "$_claude_v2_grp" "$isolated_claude_dir" \
      || bridge_die "isolation v2: chgrp $_claude_v2_grp on '$isolated_claude_dir' failed"
    bridge_linux_sudo_root chmod 2750 "$isolated_claude_dir" \
      || bridge_die "isolation v2: chmod 2750 on '$isolated_claude_dir' failed"
  else
    bridge_linux_sudo_root chmod 0700 "$isolated_claude_dir" >/dev/null 2>&1 || true
  fi
  # Channel-ownership-aware plugin sharing. Without this the isolated UID's
  # ~/.claude/plugins/ is empty and Claude starts with no MCP servers loaded
  # (Teams/ms365/cosmax-* all silently missing). The helper writes a per-UID
  # installed_plugins.json that lists only this agent's declared channel
  # plugins, grants r-X on each declared plugin's install path, and exposes
  # catalog metadata read-only. plugins/data/ stays writable by the isolated
  # UID so plugin runtime state still works.
  bridge_linux_share_plugin_catalog "$os_user" "$user_home" "$controller_user" "$agent"

  # Channel state-dir symlinks. Without this, MCP plugin servers running
  # under the isolated UID write to a brand-new empty `~/.<channel>` tree
  # and the controller-side webhook dispatcher (which writes to the
  # controller-side `$workdir/.<channel>/`) never reaches the plugin.
  # Symptom: inbound Teams/Discord/Telegram/ms365 messages silently disappear
  # and operators discover the gap only by trying to send a test message.
  #
  # For each declared `plugin:<id>[@<mkt>]` channel in the agent's roster
  # entry that has a known state-dir helper, plant a root-owned symlink at
  # `$user_home/.claude/channels/<id>` -> `$workdir/.<id>/`. The symlink
  # itself is root-owned (the isolated UID cannot relink it elsewhere); the
  # target dir is owned by the isolated UID and ACL'd for the controller via
  # the existing workdir grants (see recursive_write_paths above), so file
  # contents written through the link are visible to both sides.
  local _ch_csv=""
  local _ch_token=""
  local _ch_id=""
  local _ch_target=""
  _ch_csv="$(bridge_agent_channels_csv "$agent" 2>/dev/null || true)"
  if [[ -n "$_ch_csv" ]]; then
    local -a _ch_split=()
    IFS=',' read -ra _ch_split <<<"$_ch_csv"
    for _ch_token in "${_ch_split[@]}"; do
      _ch_token="${_ch_token// /}"
      [[ "$_ch_token" == plugin:* ]] || continue
      _ch_id="${_ch_token#plugin:}"
      _ch_id="${_ch_id%%@*}"
      case "$_ch_id" in
        discord)  _ch_target="$(bridge_agent_default_discord_state_dir "$agent")"  ;;
        telegram) _ch_target="$(bridge_agent_default_telegram_state_dir "$agent")" ;;
        teams)    _ch_target="$(bridge_agent_default_teams_state_dir "$agent")"    ;;
        ms365)    _ch_target="$(bridge_agent_default_ms365_state_dir "$agent")"    ;;
        *) continue ;;
      esac
      if ! bridge_linux_install_isolated_channel_symlink \
              "$os_user" "$user_home" "$controller_user" "$_ch_id" "$_ch_target" "$agent"; then
        bridge_die "isolation channel symlink: failed to install '$_ch_id' symlink for agent '$agent'; inspect/quarantine $user_home/.claude/channels/ before retrying"
      fi
    done
  fi

  # Issue #233: the previous `bridge_linux_grant_traverse_chain
  # $controller_user $isolated_claude_dir` call walked from
  # /home/agent-bridge-<agent>/.claude all the way up to / and left
  # `user:<controller>:--x` entries on `/home` and `/`. Under POSIX ACL
  # that named entry *reduced* the operator's own read access, because
  # the named entry overrides `other::r-x`. That's the exact mechanism
  # that silenced bun-based plugins. Grant search access only on the
  # two directories the controller actually needs to traverse: the
  # isolated user's home and its .claude subdirectory. `/home` and `/`
  # stay untouched — the controller reaches them via base perms.
  bridge_linux_acl_add "u:${controller_user}:--x" "$user_home" >/dev/null 2>&1 || true
  bridge_linux_repair_isolated_claude_read_lens "$os_user" "$user_home" "$controller_user" >/dev/null 2>&1 || true
  # Default ACL on .claude/ so any subdirectory (projects/, sessions/, ...)
  # created later by the isolated UID inherits controller read access.
  # PR-E: in v2 mode the per-agent group + setgid contract covers
  # controller access; skip the direct named-user default ACL.
  if ! bridge_isolation_v2_active; then
    bridge_linux_sudo_root setfacl -d -m "u:${controller_user}:r-X" "$isolated_claude_dir" >/dev/null 2>&1 || true
  fi
  if [[ -d "$isolated_projects_dir" ]]; then
    bridge_linux_acl_add_recursive "u:${controller_user}:r-X" "$isolated_projects_dir" >/dev/null 2>&1 || true
    bridge_linux_acl_add_default_dirs_recursive "u:${controller_user}:r-X" "$isolated_projects_dir" >/dev/null 2>&1 || true
  fi
  bridge_linux_acl_add "u:${controller_user}:rw-" "$history_file" "$audit_file"
  bridge_write_linux_agent_env_file "$agent" "$env_file"
  # Leave env_file owned by the controller so subsequent starts can chmod it.
  # Previously we chowned it to $os_user, which made the operator-run start
  # path hit EPERM on the trailing `chmod 600` (file ownership is an
  # owner-only op; rwX ACL doesn't cover it). Grant the isolated user read
  # access via ACL instead — the agent only needs to read this file.
  bridge_linux_acl_add "u:${os_user}:r--" "$env_file"
  bridge_linux_acl_add "u:${controller_user}:rw-" "$env_file"
}
bridge_linux_install_isolated_channel_symlink() {
  # Plant a root-owned symlink at $user_home/.claude/channels/<channel>
  # pointing to the controller-side per-agent state dir for that channel.
  # Idempotent: replaces a stale symlink at the link path; refuses to clobber
  # a real file/directory at either the parent root or the link itself, and
  # creates the controller-side target dir (chowned to the isolated UID, ACL
  # granted to the controller user) when it does not yet exist.
  #
  # Returns non-zero on any unsafe state so the caller (
  # bridge_linux_prepare_agent_isolation) can bridge_die instead of leaving
  # a split-state isolated-local channel dir behind.
  local os_user="$1"
  local user_home="$2"
  local controller_user="$3"
  local channel="$4"
  local target="$5"
  local agent="${6-}"

  [[ -n "$os_user" && -n "$user_home" && -n "$controller_user" && -n "$channel" && -n "$target" ]] \
    || { bridge_warn "bridge_linux_install_isolated_channel_symlink: missing arg"; return 1; }
  if bridge_isolation_v2_active && [[ -z "$agent" ]]; then
    bridge_warn "bridge_linux_install_isolated_channel_symlink: v2 mode requires the agent argument (PR-E signature change)"
    return 1
  fi

  local channels_root="$user_home/.claude/channels"
  local link_path="$channels_root/$channel"

  # Parent guard: refuse to follow a pre-existing symlink at $channels_root,
  # and refuse to clobber a non-directory there. Without this, a malicious
  # or stale `~/.claude/channels` symlink would let the subsequent
  # `mkdir/chown/chmod` walk into an attacker-chosen target.
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_warn "isolation channel symlink: $channels_root is a symlink, refusing to follow"
    return 1
  fi
  if bridge_linux_sudo_root test -e "$channels_root" \
      && ! bridge_linux_sudo_root test -d "$channels_root"; then
    bridge_warn "isolation channel symlink: $channels_root exists and is not a directory, refusing to clobber"
    return 1
  fi

  # Critical install steps explicitly propagate non-zero. The caller
  # (bridge_linux_prepare_agent_isolation) is invoked under `||`-disabled
  # errexit on the migration/reapply path, so silent `|| true` suffixes
  # would cause the helper to report success while a stale or partial
  # symlink remains. ACL add is best-effort because earlier helpers
  # (recursive_read_paths/recursive_write_paths) already cover access.
  bridge_linux_sudo_root mkdir -p "$channels_root" || {
    bridge_warn "isolation channel symlink: mkdir $channels_root failed"
    return 1
  }
  # r2 TOCTOU re-check: the initial guard only proves the path was not a
  # symlink at guard time. Between the guard and each mutation below, the
  # isolated UID could race a symlink swap if it owns the parent (`.claude`).
  # bridge_die hard-stops the isolation prepare loop, which is correct: we
  # cannot proceed if the path was tampered with mid-setup.
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_die "channels parent: raced into a symlink between guard and mkdir at $channels_root"
  fi
  bridge_linux_sudo_root chown root:root "$channels_root" || {
    bridge_warn "isolation channel symlink: chown $channels_root failed"
    return 1
  }
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_die "channels parent: raced into a symlink after chown at $channels_root"
  fi
  bridge_linux_sudo_root chmod 0755 "$channels_root" || {
    bridge_warn "isolation channel symlink: chmod $channels_root failed"
    return 1
  }
  if bridge_linux_sudo_root test -L "$channels_root"; then
    bridge_die "channels parent: raced into a symlink after chmod at $channels_root"
  fi
  bridge_linux_acl_add "u:${os_user}:r-x" "$channels_root" >/dev/null 2>&1 || true

  # Target dir: create on demand for declared channels whose `.<channel>`
  # has not yet been initialized (typical for fresh isolated agents that
  # never opened the channel). Owned by the isolated UID so the plugin
  # server can write its own state; controller user gets rwX so the
  # webhook dispatcher and channel-health probe can see it.
  #
  # Reject a non-directory at the target path: a stray file there means
  # something else owns the path and we must not chmod/chown it or symlink
  # to it. The caller bridge_die's on our return 1, so the operator has to
  # quarantine the file before reapply continues.
  if bridge_linux_sudo_root test -e "$target" \
      && ! bridge_linux_sudo_root test -d "$target"; then
    bridge_warn "isolation channel symlink: target $target exists and is not a directory, refusing to clobber"
    return 1
  fi
  if ! bridge_linux_sudo_root test -d "$target"; then
    bridge_linux_sudo_root mkdir -p "$target" || {
      bridge_warn "isolation channel symlink: mkdir target $target failed"
      return 1
    }
    # PR-E r4.4: TOCTOU re-check after mkdir. mkdir -p on an existing
    # symlink succeeds and walks into the symlink target; reject before
    # any further chown/chmod/chgrp.
    if bridge_linux_sudo_root test -L "$target"; then
      bridge_warn "isolation channel symlink: $target became a symlink between guard and mkdir, refusing to mutate"
      return 1
    fi
    bridge_linux_sudo_root chown "$os_user" "$target" || {
      bridge_warn "isolation channel symlink: chown target $target failed"
      return 1
    }
    if bridge_isolation_v2_active; then
      :  # v2 mode/group is normalized in the dedicated block below.
    else
      bridge_linux_sudo_root chmod 0700 "$target" || {
        bridge_warn "isolation channel symlink: chmod target $target failed"
        return 1
      }
      # r2: target ACLs are load-bearing for the symlink to be useful. A
      # best-effort silent-skip leaves the symlink planted but the controller
      # can't read through it -- exactly the failure mode this PR set out to
      # fix. Fail loud so the operator quarantines the partial state instead
      # of getting a runtime that pretends to work.
      bridge_linux_acl_add "u:${controller_user}:rwX" "$target" >/dev/null 2>&1 \
        || bridge_die "channel target dir: failed to grant controller rwX ACL on $target"
      bridge_linux_acl_add_default_dirs_recursive "u:${controller_user}:rwX" "$target" >/dev/null 2>&1 \
        || bridge_die "channel target dir: failed to set default ACL inheritance on $target"
    fi
  fi

  # PR-E v2 normalize block — applies whether $target was just created or
  # already existed. setgid (2770) ensures new files inside inherit
  # ab-agent-<name>; combined with the agent-launch umask 007 wired into
  # bridge-run.sh (`bridge_run_apply_v2_umask_if_needed`), files created
  # by the isolated process land at 0660/group=ab-agent-<name>, giving
  # both controller and isolated UID rw access through the group contract.
  if bridge_isolation_v2_active; then
    # r4.4 TOCTOU guard: refuse to mutate a symlink even though `test -d`
    # earlier passed (a symlink-to-dir slips through that check).
    if bridge_linux_sudo_root test -L "$target"; then
      bridge_warn "isolation v2 channel target: $target is a symlink, refusing to chgrp/chmod (target may be attacker-controlled)"
      return 1
    fi
    if ! bridge_linux_sudo_root test -d "$target"; then
      bridge_warn "isolation v2 channel target: $target disappeared between checks"
      return 1
    fi
    local _v2_grp
    _v2_grp="$(bridge_isolation_v2_agent_group_name "$agent" 2>/dev/null || printf '')" \
      || _v2_grp=""
    [[ -n "$_v2_grp" ]] || bridge_die "isolation v2: cannot resolve agent group for channel target '$target'"
    bridge_linux_sudo_root chown "$os_user" "$target" \
      || bridge_die "isolation v2: chown $os_user on channel target '$target' failed"
    bridge_linux_sudo_root chgrp "$_v2_grp" "$target" \
      || bridge_die "isolation v2: chgrp $_v2_grp on channel target '$target' failed"
    bridge_linux_sudo_root chmod 2770 "$target" \
      || bridge_die "isolation v2: chmod 2770 on channel target '$target' failed"
  fi

  # Link path: only replace a pre-existing symlink. A real file or directory
  # at this path likely contains uncommitted state (e.g. an isolated-local
  # `.<channel>/` that the plugin started writing into before the operator
  # noticed the missing symlink) and silently overwriting it would lose
  # that state. Bail and require manual quarantine.
  if bridge_linux_sudo_root test -L "$link_path"; then
    bridge_linux_sudo_root rm -f "$link_path" || {
      bridge_warn "isolation channel symlink: rm stale link $link_path failed"
      return 1
    }
  elif bridge_linux_sudo_root test -e "$link_path"; then
    bridge_warn "isolation channel symlink: $link_path is not a symlink, refusing to clobber (move it aside and rerun)"
    return 1
  fi

  bridge_linux_sudo_root ln -s "$target" "$link_path" || {
    bridge_warn "isolation channel symlink: ln -s $target $link_path failed"
    return 1
  }
  bridge_linux_sudo_root chown -h root:root "$link_path" >/dev/null 2>&1 || true
}

bridge_agent_default_home() {
  local agent="$1"
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" && -n "$agent" ]]; then
    printf '%s/%s/home' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  printf '%s/%s' "$BRIDGE_AGENT_HOME_ROOT" "$agent"
}

bridge_agent_onboarding_state() {
  local agent="$1"
  local path=""
  local line=""

  for path in "$(bridge_agent_workdir "$agent")/SESSION-TYPE.md" "$(bridge_agent_default_home "$agent")/SESSION-TYPE.md"; do
    [[ -f "$path" ]] || continue
    line="$(grep -E 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$path" 2>/dev/null | head -n 1 || true)"
    if [[ "$line" =~ Onboarding[[:space:]]+State:[[:space:]]*([A-Za-z0-9._-]+) ]]; then
      printf '%s' "${BASH_REMATCH[1]}"
      return 0
    fi
  done

  printf '%s' "missing"
}

bridge_agent_onboarding_complete() {
  local agent="$1"
  [[ "$(bridge_agent_onboarding_state "$agent")" == "complete" ]]
}

bridge_agent_should_stop_on_attached_clean_exit() {
  local agent="$1"

  bridge_agent_is_admin "$agent" || return 1
  bridge_agent_onboarding_complete "$agent" && return 1
  return 0
}

bridge_agent_default_profile_home() {
  local agent="$1"
  # v2: profile lives under workdir, not home. Every runtime resolver
  # (bridge-skills.sh:230, bridge-setup.sh:90/823, bridge-agent.sh:1275)
  # reads CLAUDE.md from workdir, so the deploy target (this function)
  # must point at workdir too, otherwise `agent-bridge profile deploy`
  # would land in v2 home/ where nothing reads it. PR-A/B/C made
  # bridge_agent_default_home v2-aware but left this profile alias
  # passing through to it. PR-D closes that gap.
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" && -n "$agent" ]]; then
    printf '%s/%s/workdir' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi
  bridge_agent_default_home "$agent"
}

bridge_agent_default_discord_state_dir() {
  local agent="$1"
  printf '%s/.discord' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_discord_state_dir() {
  local agent="$1"
  bridge_agent_default_discord_state_dir "$agent"
}

bridge_agent_default_telegram_state_dir() {
  local agent="$1"
  printf '%s/.telegram' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_telegram_state_dir() {
  local agent="$1"
  bridge_agent_default_telegram_state_dir "$agent"
}

bridge_agent_default_teams_state_dir() {
  local agent="$1"
  printf '%s/.teams' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_teams_state_dir() {
  local agent="$1"
  bridge_agent_default_teams_state_dir "$agent"
}

bridge_agent_default_ms365_state_dir() {
  local agent="$1"
  printf '%s/.ms365' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_ms365_state_dir() {
  local agent="$1"
  bridge_agent_default_ms365_state_dir "$agent"
}

bridge_agent_default_mattermost_state_dir() {
  local agent="$1"
  printf '%s/.mattermost' "$(bridge_agent_workdir "$agent")"
}

bridge_agent_mattermost_state_dir() {
  local agent="$1"
  bridge_agent_default_mattermost_state_dir "$agent"
}

bridge_agent_workdir() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_WORKDIR[$agent]-}"

  # v2 takes precedence over explicit roster workdirs: the per-agent private
  # root (root-owned, group r-x, mode 2750) IS the isolation contract. An
  # explicit workdir outside that root would launch the agent into a
  # directory the per-agent group cannot reach — or worse, a directory that
  # other isolated UIDs can reach — silently breaking PR-C's per-agent
  # privacy. Static rosters that need a non-default location should set
  # BRIDGE_DATA_ROOT (which moves the v2 anchor for every agent), not
  # BRIDGE_AGENT_WORKDIR per-agent.
  if bridge_isolation_v2_active && [[ -n "$BRIDGE_AGENT_ROOT_V2" && -n "$agent" ]]; then
    printf '%s/%s/workdir' "$BRIDGE_AGENT_ROOT_V2" "$agent"
    return 0
  fi

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  bridge_agent_default_home "$agent"
}

bridge_agent_profile_home() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PROFILE_HOME[$agent]-}"
}

bridge_agent_launch_cmd_raw() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_LAUNCH_CMD[$agent]-}"
}

bridge_trim_whitespace() {
  local raw="${1-}"
  raw="${raw#"${raw%%[![:space:]]*}"}"
  raw="${raw%"${raw##*[![:space:]]}"}"
  printf '%s' "$raw"
}

bridge_append_csv_unique() {
  local csv="${1-}"
  local value="${2-}"
  local item=""

  value="$(bridge_trim_whitespace "$value")"
  [[ -n "$value" ]] || {
    printf '%s' "$csv"
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "$value" ]]; then
      printf '%s' "$csv"
      return 0
    fi
  done

  if [[ -n "$csv" ]]; then
    printf '%s,%s' "$csv" "$value"
  else
    printf '%s' "$value"
  fi
}

bridge_merge_channels_csv() {
  local base="${1-}"
  local extra="${2-}"
  local merged="$base"
  local item=""
  local -a items=()

  [[ -n "$extra" ]] || {
    printf '%s' "$base"
    return 0
  }

  IFS=',' read -r -a items <<<"$extra"
  for item in "${items[@]}"; do
    merged="$(bridge_append_csv_unique "$merged" "$item")"
  done

  printf '%s' "$merged"
}

bridge_qualify_channel_item() {
  local item="${1-}"
  local plugin_name=""

  item="$(bridge_trim_whitespace "$item")"
  [[ -n "$item" ]] || {
    printf '%s' ""
    return 0
  }

  case "$item" in
    plugin:discord@claude-plugins-official|plugin:telegram@claude-plugins-official)
      printf '%s' "$item"
      return 0
      ;;
  esac

  if [[ "$item" == plugin:* && "$item" != *@* ]]; then
    plugin_name="${item#plugin:}"
    case "$plugin_name" in
      telegram|discord)
        printf 'plugin:%s@claude-plugins-official' "$plugin_name"
        return 0
        ;;
      teams)
        printf 'plugin:%s@agent-bridge' "$plugin_name"
        return 0
        ;;
    esac
  fi

  printf '%s' "$item"
}

bridge_channel_item_marketplace() {
  local item="${1-}"

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || {
    printf '%s' ""
    return 0
  }

  printf '%s' "${item#*@}"
}

bridge_channel_item_is_development() {
  local item="${1-}"
  local marketplace=""

  item="$(bridge_qualify_channel_item "$item")"
  [[ "$item" == plugin:*@* ]] || return 1
  marketplace="$(bridge_channel_item_marketplace "$item")"
  [[ -n "$marketplace" && "$marketplace" != "claude-plugins-official" ]]
}

bridge_normalize_channels_csv() {
  local raw="${1:-}"
  local normalized=""
  local chunk=""
  local item=""
  local -a chunks=()

  raw="${raw//$'\n'/,}"
  IFS=',' read -r -a chunks <<<"$raw"
  for chunk in "${chunks[@]}"; do
    item="$(bridge_qualify_channel_item "$chunk")"
    normalized="$(bridge_append_csv_unique "$normalized" "$item")"
  done

  printf '%s' "$normalized"
}

bridge_extract_channels_from_command() {
  local command="${1:-}"
  local rest="$command"
  local value=""
  local csv=""

  while [[ "$rest" =~ --channels=([^[:space:]]+) ]]; do
    value="${BASH_REMATCH[1]}"
    csv="$(bridge_merge_channels_csv "$csv" "$(bridge_normalize_channels_csv "$value")")"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  rest="$command"
  while [[ "$rest" =~ --channels[[:space:]]+([^[:space:]]+) ]]; do
    value="${BASH_REMATCH[1]}"
    csv="$(bridge_merge_channels_csv "$csv" "$(bridge_normalize_channels_csv "$value")")"
    rest="${rest#*"${BASH_REMATCH[0]}"}"
  done

  printf '%s' "$csv"
}

bridge_extract_development_channels_from_command() {
  local command="${1:-}"

  bridge_require_python
  python3 - "$command" <<'PY'
import shlex
import sys

command = sys.argv[1]

def normalize(raw: str):
    values = []
    seen = set()
    for chunk in raw.split(","):
        item = chunk.strip()
        if not item or item in seen:
            continue
        seen.add(item)
        values.append(item)
    return values

try:
    tokens = shlex.split(command)
except ValueError:
    print("")
    raise SystemExit(0)

items = []
seen = set()
i = 0
while i < len(tokens):
    token = tokens[i]
    if token == "--dangerously-load-development-channels":
        i += 1
        while i < len(tokens) and not tokens[i].startswith("-"):
            for item in normalize(tokens[i]):
                if item not in seen:
                    seen.add(item)
                    items.append(item)
            i += 1
        continue
    if token.startswith("--dangerously-load-development-channels="):
        for item in normalize(token.split("=", 1)[1]):
            if item not in seen:
                seen.add(item)
                items.append(item)
    i += 1

print(",".join(items))
PY
}

bridge_channel_csv_contains() {
  local csv="${1:-}"
  local needle="${2:-}"
  local item=""
  local -a items=()

  [[ -n "$csv" && -n "$needle" ]] || return 1

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if [[ "$item" == "$needle" || "$item" == "$needle@"* ]]; then
      return 0
    fi
  done

  return 1
}

bridge_channel_item_requires_claude_plugin() {
  local item="${1:-}"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:*|server:*)
      return 0
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_filter_claude_plugin_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if bridge_channel_item_requires_claude_plugin "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_filter_development_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if bridge_channel_item_is_development "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_filter_approved_channels_csv() {
  local csv="${1:-}"
  local item=""
  local filtered=""
  local -a items=()

  [[ -n "$csv" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$csv"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    item="$(bridge_qualify_channel_item "$item")"
    if ! bridge_channel_item_is_development "$item"; then
      filtered="$(bridge_append_csv_unique "$filtered" "$item")"
    fi
  done

  printf '%s' "$filtered"
}

bridge_channel_csv_is_subset() {
  local required_csv="${1:-}"
  local actual_csv="${2:-}"
  local need=""
  local have=""
  local matched=0

  IFS=',' read -r -a required_items <<<"$required_csv"
  IFS=',' read -r -a actual_items <<<"$actual_csv"

  for need in "${required_items[@]}"; do
    need="$(bridge_trim_whitespace "$need")"
    [[ -n "$need" ]] || continue
    matched=1
    for have in "${actual_items[@]}"; do
      have="$(bridge_trim_whitespace "$have")"
      [[ -n "$have" ]] || continue
      if [[ "$have" == "$need" || "$have" == "$need@"* || "$need" == "$have@"* ]]; then
        matched=0
        break
      fi
    done
    (( matched == 0 )) || return 1
  done

  return 0
}

bridge_agent_channels_csv() {
  local agent="$1"
  local explicit=""
  local inferred=""
  local inferred_dev=""

  explicit="${BRIDGE_AGENT_CHANNELS[$agent]-}"
  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  inferred="$(bridge_extract_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  inferred_dev="$(bridge_extract_development_channels_from_command "$(bridge_agent_launch_cmd_raw "$agent")")"
  inferred="$(bridge_merge_channels_csv "$inferred" "$inferred_dev")"
  if [[ -n "$inferred" ]]; then
    printf '%s' "$inferred"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_dev_channels_csv() {
  local agent="$1"
  bridge_filter_development_channels_csv "$(bridge_agent_channels_csv "$agent")"
}

bridge_agent_plugins_csv() {
  # Emit the per-agent BRIDGE_AGENT_PLUGINS allowlist (#272) as a normalized
  # CSV of plugin ids (no `plugin:` prefix). Tokens in the roster value may be
  # space- or comma-separated and may carry an optional `plugin:` prefix; both
  # forms are accepted and normalised here so isolation helpers can treat the
  # output as a flat plugin-id list (`<plugin>` or `<plugin>@<marketplace>`).
  # Returns the empty string when the entry is unset or contains no tokens.
  local agent="$1"
  local raw="${BRIDGE_AGENT_PLUGINS[$agent]-}"
  [[ -n "$raw" ]] || { printf ''; return 0; }

  local -a tokens=()
  local seen_marker=$'\x1f'
  local seen=""
  local token=""
  # shellcheck disable=SC2206 # split on whitespace+comma is intentional here.
  local IFS_orig="$IFS"
  IFS=$' \t\n,'
  read -ra _split <<<"$raw"
  IFS="$IFS_orig"
  for token in "${_split[@]}"; do
    token="${token## }"
    token="${token%% }"
    [[ -n "$token" ]] || continue
    # Accept `plugin:<id>` and `<id>` interchangeably; normalise to `<id>`.
    [[ "$token" == plugin:* ]] && token="${token#plugin:}"
    [[ -n "$token" ]] || continue
    case "$seen" in
      *"${seen_marker}${token}${seen_marker}"*) continue ;;
    esac
    seen="${seen}${seen_marker}${token}${seen_marker}"
    tokens+=("$token")
  done

  if (( ${#tokens[@]} == 0 )); then
    printf ''
    return 0
  fi
  (IFS=','; printf '%s' "${tokens[*]}")
}

bridge_agent_auto_accept_dev_channels_csv() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_AUTO_ACCEPT_DEV_CHANNELS[$agent]-}"

  if [[ -n "$explicit" ]]; then
    bridge_normalize_channels_csv "$explicit"
    return 0
  fi

  bridge_normalize_channels_csv "${BRIDGE_AUTO_ACCEPT_DEV_CHANNELS_DEFAULT:-plugin:teams@agent-bridge,plugin:mattermost@agent-bridge}"
}

bridge_agent_uses_discord_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:discord"
}

bridge_agent_uses_teams_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:teams"
}

bridge_agent_uses_mattermost_plugin() {
  local agent="$1"
  bridge_channel_csv_contains "$(bridge_agent_channels_csv "$agent")" "plugin:mattermost"
}

bridge_agent_discord_channel_from_access() {
  local agent="$1"
  local access_file=""

  access_file="$(bridge_agent_workdir "$agent")/.discord/access.json"
  [[ -f "$access_file" ]] || return 1

  bridge_require_python
  python3 - "$access_file" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    raise SystemExit(1)

groups = payload.get("groups") or {}
for key in groups.keys():
    if key:
        print(str(key))
        raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_agent_discord_channel_id() {
  local agent="$1"
  local explicit=""
  local inferred=""

  explicit="${BRIDGE_AGENT_DISCORD_CHANNEL_ID[$agent]-}"
  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  if bridge_agent_uses_discord_plugin "$agent"; then
    inferred="$(bridge_agent_discord_channel_from_access "$agent" 2>/dev/null || true)"
    if [[ -n "$inferred" ]]; then
      printf '%s' "$inferred"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_env_file_has_any_nonempty_key() {
  local file="$1"
  shift || true
  local key=""

  [[ -f "$file" ]] || return 1
  for key in "$@"; do
    if grep -Eq "^[[:space:]]*(export[[:space:]]+)?${key}=[^[:space:]#].*" "$file"; then
      return 0
    fi
  done

  return 1
}

# Issue #534: isolation-aware readiness probe for channel `.env` files.
#
# Returns one of "present" | "missing" | "unreadable" via stdout. Suppresses
# raw grep stderr (which previously leaked `Permission denied` to the daemon
# log on every channel-health cycle in linux-user isolation when the
# controller-side ACL had drifted). Distinguishes:
#
#   - "present"    — file readable and at least one of the requested keys
#                    has a non-empty value.
#   - "missing"    — file absent OR file readable but no requested key is
#                    present with a non-empty value.
#   - "unreadable" — file exists but the controller cannot read it (EACCES);
#                    in linux-user isolation this triggers a bounded ACL
#                    repair retry via bridge_linux_acl_repair_channel_env_files
#                    before giving up.
#
# rc=1 vs rc=2 from grep:
#   The internal grep helper returns 1 on "no match" and 2 on file/permission
#   error. Bash conflates these into a single non-zero exit, so we
#   distinguish via a `[[ -r "$file" ]]` probe after the helper fails.
#
# Usage:
#   case "$(bridge_channel_env_file_readiness <agent> <item> <file> <key>...)" in
#     present)    ... ;;
#     missing)    ... ;;
#     unreadable) ... ;;   # caller may then call bridge_channel_env_file_acl_diagnostic
#   esac
bridge_channel_env_file_readiness() {
  local agent="$1"
  local item="$2"
  local file="$3"
  shift 3 || true
  local rc=0

  if [[ ! -e "$file" ]]; then
    printf 'missing'
    return 0
  fi

  # First read attempt as the controller; suppress stderr so EACCES does
  # not leak to the daemon log. rc captured separately.
  rc=0
  bridge_env_file_has_any_nonempty_key "$file" "$@" >/dev/null 2>&1 || rc=$?
  if [[ $rc -eq 0 ]]; then
    printf 'present'
    return 0
  fi

  if [[ -r "$file" ]]; then
    # File readable; helper just didn't find a non-empty matching key.
    printf 'missing'
    return 0
  fi

  # Unreadable. In linux-user isolation, attempt bounded ACL repair.
  local repair_attempts="${BRIDGE_ENV_READINESS_REPAIR_ATTEMPTS:-2}"
  local attempt=0
  if [[ "$(bridge_agent_isolation_mode "$agent" 2>/dev/null || printf '')" == "linux-user" ]]; then
    while (( attempt < repair_attempts )); do
      bridge_linux_acl_repair_channel_env_files "$agent" >/dev/null 2>&1 || true
      attempt=$((attempt + 1))
      if [[ -r "$file" ]]; then
        rc=0
        bridge_env_file_has_any_nonempty_key "$file" "$@" >/dev/null 2>&1 || rc=$?
        if [[ $rc -eq 0 ]]; then
          printf 'present'
          return 0
        fi
        # File now readable but key not present — treat as missing rather
        # than leaving in unreadable.
        printf 'missing'
        return 0
      fi
    done
  fi

  # Suppress unused-warning shellcheck when item is reserved for future
  # per-channel scoped repair; ms365/teams currently share the agent-wide
  # repair surface so item is logged rather than dispatched on.
  : "${item}"
  printf 'unreadable'
  return 0
}

# Issue #534: produce a single-line diagnostic blob for an unreadable
# channel `.env` file. Composed from `stat` and `getfacl` (Linux only;
# Darwin lacks both POSIX named-user ACLs and a compatible getfacl).
# Suppresses all stderr — output is one line so it fits in the existing
# status_reason format.
#
# Output shape (single line):
#   {"mode":"600","owner":"<uid>:<gid>","getfacl":"...","repair_attempts":N}
#
# When the file is missing or running on macOS, emits a minimal blob with
# what is available; never returns non-zero.
bridge_channel_env_file_acl_diagnostic() {
  local file="$1"
  local repair_attempts="${2:-${BRIDGE_ENV_READINESS_REPAIR_ATTEMPTS:-2}}"
  local mode="-" owner="-" facl="-"

  if [[ -e "$file" ]]; then
    case "$(uname -s 2>/dev/null || printf '')" in
      Linux)
        mode="$(stat -c '%a' "$file" 2>/dev/null || printf -- '-')"
        owner="$(stat -c '%U:%G' "$file" 2>/dev/null || printf -- '-')"
        if command -v getfacl >/dev/null 2>&1; then
          facl="$(getfacl --omit-header --no-effective "$file" 2>/dev/null \
            | tr '\n' '/' | sed 's:/$::' || printf -- '-')"
          [[ -n "$facl" ]] || facl="-"
        fi
        ;;
      Darwin)
        mode="$(stat -f '%Lp' "$file" 2>/dev/null || printf -- '-')"
        owner="$(stat -f '%Su:%Sg' "$file" 2>/dev/null || printf -- '-')"
        facl="darwin-acl-not-applicable"
        ;;
      *)
        ;;
    esac
  fi

  printf '{"mode":"%s","owner":"%s","getfacl":"%s","repair_attempts":%s}' \
    "$mode" "$owner" "$facl" "$repair_attempts"
}

bridge_agent_channel_runtime_ready_for_item() {
  local agent="$1"
  local item="$2"
  local dir=""

  item="$(bridge_trim_whitespace "$item")"
  [[ -n "$item" ]] || return 1

  # Issue #534: route through the readiness enum so unreadable .env (linux-user
  # ACL drift) does not collapse into the same "not ready" signal as missing
  # keys. Both unreadable and missing return 1 here (downstream readiness is
  # boolean), but the structured reason path uses the same helper to emit a
  # distinct status_reason.
  case "$item" in
    plugin:discord|plugin:discord@*)
      dir="$(bridge_agent_discord_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN)" == "present" ]]
      ;;
    plugin:telegram|plugin:telegram@*)
      dir="$(bridge_agent_telegram_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN)" == "present" ]]
      ;;
    plugin:teams|plugin:teams@*)
      dir="$(bridge_agent_teams_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_ID MicrosoftAppId)" == "present" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword)" == "present" ]]
      ;;
    plugin:ms365|plugin:ms365@*)
      dir="$(bridge_agent_ms365_state_dir "$agent")"
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_ID)" == "present" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_SECRET)" == "present" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_TENANT_ID)" == "present" ]]
      ;;
    plugin:mattermost|plugin:mattermost@*)
      dir="$(bridge_agent_mattermost_state_dir "$agent")"
      [[ -f "$dir/access.json" ]] || return 1
      [[ "$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MATTERMOST_BOT_TOKEN MATTERMOST_PERSONAL_TOKEN)" == "present" ]]
      ;;
    *)
      return 0
      ;;
  esac
}

bridge_channel_provider_for_item() {
  local item="$1"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      printf '%s' "discord"
      ;;
    plugin:telegram|plugin:telegram@*)
      printf '%s' "telegram"
      ;;
    plugin:teams|plugin:teams@*)
      printf '%s' "teams"
      ;;
    plugin:ms365|plugin:ms365@*)
      printf '%s' "ms365"
      ;;
    plugin:*)
      printf '%s' "${item#plugin:}"
      ;;
    server:*)
      printf '%s' "${item#server:}"
      ;;
    *)
      printf '%s' "unknown"
      ;;
  esac
}

bridge_channel_state_dir_for_item() {
  local agent="$1"
  local item="$2"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      bridge_agent_discord_state_dir "$agent"
      ;;
    plugin:telegram|plugin:telegram@*)
      bridge_agent_telegram_state_dir "$agent"
      ;;
    plugin:teams|plugin:teams@*)
      bridge_agent_teams_state_dir "$agent"
      ;;
    plugin:ms365|plugin:ms365@*)
      bridge_agent_ms365_state_dir "$agent"
      ;;
    plugin:mattermost|plugin:mattermost@*)
      bridge_agent_mattermost_state_dir "$agent"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_channel_credentials_status_for_item() {
  local agent="$1"
  local item="$2"
  local dir=""
  local r1="" r2="" r3=""

  item="$(bridge_qualify_channel_item "$item")"
  dir="$(bridge_channel_state_dir_for_item "$agent" "$item")"
  # Issue #534: surface "unreadable" distinctly from "missing". When ANY
  # required key probe reports unreadable, the overall status is unreadable
  # (operators need to know the controller cannot read the file at all,
  # which is actionable via ACL repair, vs. truly missing keys).
  case "$item" in
    plugin:discord|plugin:discord@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN)"
      printf '%s' "$r1"
      ;;
    plugin:telegram|plugin:telegram@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN)"
      printf '%s' "$r1"
      ;;
    plugin:teams|plugin:teams@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_ID MicrosoftAppId)"
      r2="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword)"
      if [[ "$r1" == "unreadable" || "$r2" == "unreadable" ]]; then
        printf '%s' "unreadable"
      elif [[ "$r1" == "present" && "$r2" == "present" ]]; then
        printf '%s' "present"
      else
        printf '%s' "missing"
      fi
      ;;
    plugin:ms365|plugin:ms365@*)
      r1="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_ID)"
      r2="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_CLIENT_SECRET)"
      r3="$(bridge_channel_env_file_readiness "$agent" "$item" "$dir/.env" MS365_TENANT_ID)"
      if [[ "$r1" == "unreadable" || "$r2" == "unreadable" || "$r3" == "unreadable" ]]; then
        printf '%s' "unreadable"
      elif [[ "$r1" == "present" && "$r2" == "present" && "$r3" == "present" ]]; then
        printf '%s' "present"
      else
        printf '%s' "missing"
      fi
      ;;
    *)
      printf '%s' "n/a"
      ;;
  esac
}

bridge_channel_access_status_for_item() {
  local agent="$1"
  local item="$2"
  local provider=""
  local dir=""
  local access_file=""

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:ms365|plugin:ms365@*)
      printf '%s' "n/a"
      return 0
      ;;
  esac
  provider="$(bridge_channel_provider_for_item "$item")"
  dir="$(bridge_channel_state_dir_for_item "$agent" "$item")"
  [[ -n "$dir" ]] || {
    printf '%s' "n/a"
    return 0
  }

  access_file="$dir/access.json"
  [[ -f "$access_file" ]] || {
    printf '%s' "missing"
    return 0
  }

  bridge_require_python
  python3 - "$access_file" "$provider" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
provider = sys.argv[2]

try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("invalid")
    raise SystemExit(0)

def nonempty_list(value):
    if not isinstance(value, list):
        return 0
    return sum(1 for item in value if str(item).strip())

def nonempty_groups(value):
    if not isinstance(value, dict):
        return 0
    return sum(1 for key in value.keys() if str(key).strip())

count = 0
if provider == "discord":
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))
elif provider == "telegram":
    count += nonempty_list(payload.get("allowFrom"))
    if str(payload.get("defaultChatId") or "").strip():
        count += 1
elif provider == "teams":
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))
else:
    count += nonempty_groups(payload.get("groups"))
    count += nonempty_list(payload.get("allowFrom"))

print("present" if count > 0 else "empty")
PY
}

bridge_agent_channel_launch_allowlisted_for_item() {
  local agent="$1"
  local item="$2"
  local generated=""
  local effective=""
  local effective_dev=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' "n/a"
    return 0
  }

  item="$(bridge_qualify_channel_item "$item")"
  # Mirror the real launch-builder path: bridge_agent_launch_cmd() applies
  # bridge_claude_launch_with_channels then bridge_claude_launch_with_development_channels
  # using bridge_agent_required_dev_channels_csv. Use the same arg here so the
  # diagnostic surface (launch_allowlisted) matches what `claude` actually receives.
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  generated="$(bridge_claude_launch_with_development_channels "$generated" "$(bridge_agent_required_dev_channels_csv "$agent")")"
  effective="$(bridge_extract_channels_from_command "$generated")"
  effective_dev="$(bridge_extract_development_channels_from_command "$generated")"
  if bridge_channel_item_is_development "$item"; then
    if bridge_channel_csv_is_subset "$item" "$effective_dev"; then
      printf '%s' "yes"
      return 0
    fi
    printf '%s' "no"
    return 0
  fi

  if bridge_channel_csv_is_subset "$item" "$effective"; then
    printf '%s' "yes"
    return 0
  fi

  printf '%s' "no"
}

bridge_agent_channel_diagnostics_tsv() {
  local agent="$1"
  local required=""
  local item=""
  local provider=""
  local plugin_spec=""
  local plugin_status=""
  local plugin_installed=""
  local plugin_enabled=""
  local launch_allowlisted=""
  local access_status=""
  local credentials_status=""
  local runtime_ready=""
  local state_dir_status=""
  local -a items=()

  printf 'channel\tprovider\tplugin_spec\tplugin_status\tplugin_installed\tplugin_enabled\tlaunch_allowlisted\taccess_status\tcredentials_status\truntime_ready\tstate_dir\n'

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_qualify_channel_item "$item")"
    [[ -n "$item" ]] || continue

    provider="$(bridge_channel_provider_for_item "$item")"
    plugin_spec="-"
    plugin_status="n/a"
    plugin_installed="n/a"
    plugin_enabled="n/a"
    if [[ "$item" == plugin:* ]]; then
      plugin_spec="${item#plugin:}"
      plugin_status="$(bridge_claude_plugin_status "$plugin_spec")"
      case "$plugin_status" in
        enabled)
          plugin_installed="yes"
          plugin_enabled="yes"
          ;;
        disabled)
          plugin_installed="yes"
          plugin_enabled="no"
          ;;
        *)
          plugin_installed="no"
          plugin_enabled="no"
          ;;
      esac
    fi

    launch_allowlisted="$(bridge_agent_channel_launch_allowlisted_for_item "$agent" "$item")"
    access_status="$(bridge_channel_access_status_for_item "$agent" "$item")"
    credentials_status="$(bridge_channel_credentials_status_for_item "$agent" "$item")"
    if bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      runtime_ready="yes"
    else
      runtime_ready="no"
    fi
    state_dir_status="n/a"
    if [[ -n "$(bridge_channel_state_dir_for_item "$agent" "$item")" ]]; then
      if [[ -d "$(bridge_channel_state_dir_for_item "$agent" "$item")" ]]; then
        state_dir_status="present"
      else
        state_dir_status="missing"
      fi
    fi

    printf '%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\t%s\n' \
      "$item" \
      "$provider" \
      "$plugin_spec" \
      "$plugin_status" \
      "$plugin_installed" \
      "$plugin_enabled" \
      "$launch_allowlisted" \
      "$access_status" \
      "$credentials_status" \
      "$runtime_ready" \
      "$state_dir_status"
  done
}

bridge_agent_channel_diagnostics_json() {
  local agent="$1"
  local tsv=""

  tsv="$(bridge_agent_channel_diagnostics_tsv "$agent")"
  bridge_require_python
  python3 - "$tsv" <<'PY'
import csv
import io
import json
import sys

rows = list(csv.DictReader(io.StringIO(sys.argv[1]), delimiter="\t"))

def yn(value):
    if value == "yes":
        return True
    if value == "no":
        return False
    return None

payload = []
for row in rows:
    payload.append({
        "channel": row["channel"],
        "provider": row["provider"],
        "plugin_spec": None if row["plugin_spec"] == "-" else row["plugin_spec"],
        "plugin_status": row["plugin_status"],
        "plugin_installed": yn(row["plugin_installed"]),
        "plugin_enabled": yn(row["plugin_enabled"]),
        "launch_allowlisted": yn(row["launch_allowlisted"]),
        "access_status": row["access_status"],
        "credentials_status": row["credentials_status"],
        "runtime_ready": yn(row["runtime_ready"]),
        "state_dir": row["state_dir"],
    })

print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

bridge_agent_channel_diagnostics_text() {
  local agent="$1"
  local tsv=""
  local row_count=0

  tsv="$(bridge_agent_channel_diagnostics_tsv "$agent")"
  while IFS=$'\t' read -r channel provider plugin_spec plugin_status plugin_installed plugin_enabled launch_allowlisted access_status credentials_status runtime_ready state_dir; do
    [[ "$channel" == "channel" ]] && continue
    [[ -n "$channel" ]] || continue
    row_count=$((row_count + 1))
    printf -- '- channel: %s\n' "$channel"
    printf '  provider: %s\n' "$provider"
    printf '  plugin: installed=%s enabled=%s status=%s spec=%s\n' "$plugin_installed" "$plugin_enabled" "$plugin_status" "$plugin_spec"
    printf '  launch_allowlisted: %s\n' "$launch_allowlisted"
    printf '  runtime: state_dir=%s access=%s credentials=%s ready=%s\n' "$state_dir" "$access_status" "$credentials_status" "$runtime_ready"
  done <<<"$tsv"

  if [[ "$row_count" == "0" ]]; then
    printf '%s\n' "- channels: (none)"
  fi
}

bridge_agent_broken_launch_file() {
  local agent="$1"
  printf '%s/agents/%s/broken-launch' "$BRIDGE_STATE_DIR" "$agent"
}

bridge_agent_session_health_json() {
  local agent="$1"
  local session=""
  local active="no"
  local loop_mode=""
  local continue_mode=""
  local onboarding_state=""
  local attached_exit_behavior="exit"
  local restart_readiness="not-looped"
  local broken_launch_file=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  broken_launch_file="$(bridge_agent_broken_launch_file "$agent")"

  if [[ -f "$broken_launch_file" ]]; then
    restart_readiness="broken-launch"
  elif [[ "$loop_mode" == "1" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
      attached_exit_behavior="stop-until-next-admin-command"
      restart_readiness="onboarding-pending"
    else
      attached_exit_behavior="detach-client-and-restart-loop"
      if bridge_agent_channel_setup_complete "$agent"; then
        restart_readiness="ready"
      else
        restart_readiness="channel-setup-incomplete"
      fi
    fi
  fi

  bridge_require_python
  python3 - "$agent" "$session" "$active" "$loop_mode" "$continue_mode" "$onboarding_state" "$attached_exit_behavior" "$restart_readiness" "$broken_launch_file" <<'PY'
import json
import sys

agent, session, active, loop_mode, continue_mode, onboarding_state, attached_exit_behavior, restart_readiness, broken_launch_file = sys.argv[1:]
payload = {
    "session": session or None,
    "tmux_active": active == "yes",
    "loop": loop_mode == "1",
    "continue": continue_mode == "1",
    "onboarding_state": onboarding_state,
    "attached_exit_behavior": attached_exit_behavior,
    "restart_readiness": restart_readiness,
    "detach_hint": "Ctrl-b then d",
    "stop_command": f"agent-bridge kill {agent}",
}
if broken_launch_file:
    payload["broken_launch_file"] = broken_launch_file
if session:
    payload["attach_command"] = f"tmux attach -t ={session}"
print(json.dumps(payload, ensure_ascii=False, separators=(",", ":")))
PY
}

bridge_agent_session_guidance_text() {
  local agent="$1"
  local session=""
  local active="no"
  local loop_mode=""
  local continue_mode=""
  local onboarding_state=""
  local exit_behavior=""
  local restart_readiness=""
  local broken_launch_file=""

  session="$(bridge_agent_session "$agent")"
  if bridge_agent_is_active "$agent"; then
    active="yes"
  fi
  loop_mode="$(bridge_agent_loop "$agent")"
  continue_mode="$(bridge_agent_continue "$agent")"
  onboarding_state="$(bridge_agent_onboarding_state "$agent")"
  broken_launch_file="$(bridge_agent_broken_launch_file "$agent")"
  exit_behavior="exit"
  restart_readiness="not-looped"
  if [[ -f "$broken_launch_file" ]]; then
    restart_readiness="broken-launch"
  elif [[ "$loop_mode" == "1" ]]; then
    if bridge_agent_should_stop_on_attached_clean_exit "$agent"; then
      exit_behavior="stop-until-next-admin-command"
      restart_readiness="onboarding-pending"
    else
      exit_behavior="detach-client-and-restart-loop"
      if bridge_agent_channel_setup_complete "$agent"; then
        restart_readiness="ready"
      else
        restart_readiness="channel-setup-incomplete"
      fi
    fi
  fi

  printf -- '- tmux_session: %s\n' "${session:--}"
  printf -- '- tmux_active: %s\n' "$active"
  printf -- '- loop: %s\n' "$loop_mode"
  printf -- '- continue: %s\n' "$continue_mode"
  printf -- '- onboarding_state: %s\n' "$onboarding_state"
  printf -- '- attached_exit_behavior: %s\n' "$exit_behavior"
  printf -- '- restart_readiness: %s\n' "$restart_readiness"
  if [[ -f "$broken_launch_file" ]]; then
    printf -- '- broken_launch_file: %s\n' "$broken_launch_file"
    printf -- '- recovery: agent-bridge agent safe-mode %s\n' "$agent"
  fi
  if [[ -n "$session" ]]; then
    printf -- '- attach: tmux attach -t =%s\n' "$session"
  fi
  printf -- '- detach_to_shell: Ctrl-b then d\n'
  printf -- '- fully_stop: agent-bridge kill %s\n' "$agent"
}

bridge_agent_ready_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local ready=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      ready="$(bridge_append_csv_unique "$ready" "$item")"
    fi
  done

  printf '%s' "$ready"
}

bridge_agent_missing_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local missing=""
  local -a items=()

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    if ! bridge_agent_channel_runtime_ready_for_item "$agent" "$item"; then
      missing="$(bridge_append_csv_unique "$missing" "$item")"
    fi
  done

  printf '%s' "$missing"
}

bridge_agent_channel_runtime_drift_reason() {
  local agent="$1"
  local required=""
  local missing=""
  local ready=""

  required="$(bridge_agent_channels_csv "$agent")"
  [[ -n "$required" ]] || {
    printf '%s' ""
    return 0
  }

  missing="$(bridge_agent_missing_channels_csv "$agent")"
  [[ -n "$missing" ]] || {
    printf '%s' ""
    return 0
  }

  ready="$(bridge_agent_ready_channels_csv "$agent")"
  printf 'declared channels (%s) do not match configured runtime (ready=%s missing=%s)' \
    "$required" \
    "${ready:--}" \
    "$missing"
}

bridge_agent_launch_channels_csv() {
  local agent="$1"
  local channels=""

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    channels="$(bridge_filter_approved_channels_csv "$(bridge_agent_ready_channels_csv "$agent")")"
  else
    channels="$(bridge_filter_approved_channels_csv "$(bridge_agent_channels_csv "$agent")")"
  fi
  bridge_filter_claude_plugin_channels_csv "$channels"
}

bridge_agent_effective_dev_channels_csv() {
  local agent="$1"

  if [[ "${BRIDGE_AGENT_SUPPRESS_MISSING_CHANNELS:-0}" == "1" ]]; then
    bridge_filter_development_channels_csv "$(bridge_agent_ready_channels_csv "$agent")"
    return 0
  fi

  bridge_agent_dev_channels_csv "$agent"
}

bridge_agent_effective_launch_plugin_channels_csv() {
  local agent="$1"
  local merged=""

  merged="$(bridge_merge_channels_csv "$(bridge_agent_launch_channels_csv "$agent")" "$(bridge_agent_effective_dev_channels_csv "$agent")")"
  bridge_filter_claude_plugin_channels_csv "$merged"
}

bridge_plugin_mcp_identity_for_item() {
  local item="$1"

  item="$(bridge_qualify_channel_item "$item")"
  case "$item" in
    plugin:discord|plugin:discord@*)
      printf '%s' "discord"
      ;;
    plugin:telegram|plugin:telegram@*)
      printf '%s' "telegram"
      ;;
    plugin:teams|plugin:teams@*)
      printf '%s' "teams"
      ;;
    plugin:mattermost|plugin:mattermost@*)
      printf '%s' "mattermost"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

# Returns 0 if the channel item has a probeable plugin MCP identity
# (currently the 4 chat providers we ship a `ps`-descendant probe for).
# Returns 1 for plugins we ship without a probe (HTTP MCPs, marketplace
# plugins, ms365 / generic command-MCPs, etc.) — these are reported as
# unknown/skipped rather than missing so they cannot drive restart loops.
# See issue #542; per-plugin-class probes (command-MCP, HTTP MCP) are
# tracked as follow-ups and will extend this classifier.
bridge_plugin_mcp_is_probeable_item() {
  local item="$1"
  local identity=""

  identity="$(bridge_plugin_mcp_identity_for_item "$item")"
  [[ -n "$identity" ]]
}

# NOTE: an empty identity from bridge_plugin_mcp_identity_for_item means
# the plugin is *unprobeable* (we have no descendant probe for it), not
# that it is missing. Callers should gate on bridge_plugin_mcp_is_probeable_item
# *before* invoking this probe so unprobeable plugins do not get flagged
# as missing and trigger restart loops (issue #542).
bridge_plugin_mcp_descendant_ready_for_item() {
  local root_pid="$1"
  local item="$2"
  local identity=""

  [[ "$root_pid" =~ ^[0-9]+$ ]] || return 1
  identity="$(bridge_plugin_mcp_identity_for_item "$item")"
  [[ -n "$identity" ]] || return 1

  bridge_require_python
  python3 - "$root_pid" "$identity" <<'PY'
import re
import subprocess
import sys
from collections import defaultdict

root_pid = int(sys.argv[1])
identity = sys.argv[2].strip().lower()

try:
    completed = subprocess.run(
        ["ps", "-axo", "pid=,ppid=,command="],
        check=True,
        text=True,
        capture_output=True,
    )
except subprocess.CalledProcessError:
    raise SystemExit(1)

procs = {}
children = defaultdict(list)
for raw in completed.stdout.splitlines():
    parts = raw.strip().split(None, 2)
    if len(parts) < 3:
        continue
    try:
        pid = int(parts[0])
        ppid = int(parts[1])
    except ValueError:
        continue
    command = parts[2]
    procs[pid] = (ppid, command)
    children[ppid].append(pid)

descendants = set()
stack = list(children.get(root_pid, []))
while stack:
    pid = stack.pop()
    if pid in descendants:
        continue
    descendants.add(pid)
    stack.extend(children.get(pid, []))

def command_has_identity_path_segment(command: str, identity: str) -> bool:
    for match in re.finditer(r"/[^\s]+", command):
        token = match.group(0)
        segments = [segment for segment in token.split("/") if segment]
        if identity in segments:
            return True
    return False

for pid in descendants:
    _ppid, command = procs.get(pid, (None, ""))
    lowered = command.lower()
    if "bun" not in lowered:
        continue
    if command_has_identity_path_segment(lowered, identity):
        raise SystemExit(0)

raise SystemExit(1)
PY
}

bridge_agent_plugin_mcp_alive_for_item() {
  local agent="$1"
  local item="$2"
  local session=""
  local pane_pid=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1
  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || return 1
  bridge_tmux_session_exists "$session" || return 1
  pane_pid="$(bridge_tmux_session_pane_pid "$session")"
  [[ "$pane_pid" =~ ^[0-9]+$ ]] || return 1
  bridge_plugin_mcp_descendant_ready_for_item "$pane_pid" "$item"
}

bridge_agent_missing_plugin_mcp_channels_csv() {
  local agent="$1"
  local required=""
  local item=""
  local missing=""
  local -a items=()

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0

  IFS=',' read -r -a items <<<"$required"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    # Skip plugins we cannot probe (HTTP MCPs, marketplace plugins, ms365,
    # etc.). They are reported as unknown/skipped — not missing — so they
    # cannot drive restart loops. See issue #542.
    bridge_plugin_mcp_is_probeable_item "$item" || continue
    if ! bridge_agent_plugin_mcp_alive_for_item "$agent" "$item"; then
      missing="$(bridge_merge_channels_csv "$missing" "$item")"
    fi
  done

  printf '%s' "$missing"
}

bridge_agent_required_launch_channels_csv() {
  local agent="$1"

  bridge_filter_claude_plugin_channels_csv "$(bridge_filter_approved_channels_csv "$(bridge_agent_channels_csv "$agent")")"
}

bridge_agent_required_dev_channels_csv() {
  local agent="$1"

  bridge_filter_claude_plugin_channels_csv "$(bridge_agent_dev_channels_csv "$agent")"
}

bridge_agent_required_runtime_channels_csv() {
  local agent="$1"

  bridge_agent_channels_csv "$agent"
}

bridge_claude_channel_banner_present_from_text() {
  local channels="$1"
  local recent="$2"
  local item=""
  local found=0
  local -a items=()

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  [[ "$recent" == *"Listening for channel messages from:"* ]] || return 1

  IFS=',' read -r -a items <<<"$channels"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ -n "$item" ]] || continue
    [[ "$recent" == *"$item"* ]] || return 1
    found=1
  done

  [[ "$found" == "1" ]]
}

bridge_tmux_session_has_claude_channel_banner() {
  local session="$1"
  local channels="$2"
  local recent=""

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  recent="$(bridge_capture_recent "$session" 80 2>/dev/null || true)"
  [[ -n "$recent" ]] || return 1
  bridge_claude_channel_banner_present_from_text "$channels" "$recent"
}

bridge_tmux_wait_for_claude_channel_banner() {
  local session="$1"
  local channels="$2"
  local timeout="${3:-12}"
  local start_ts=0
  local elapsed=0

  channels="$(bridge_filter_claude_plugin_channels_csv "$channels")"
  [[ -n "$channels" ]] || return 0
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=12
  (( timeout > 0 )) || timeout=12

  if bridge_tmux_session_has_claude_channel_banner "$session" "$channels"; then
    return 0
  fi

  start_ts="$(date +%s)"
  while true; do
    if bridge_tmux_session_has_claude_channel_banner "$session" "$channels"; then
      return 0
    fi
    sleep 0.2
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

# bridge_tmux_wait_for_claude_plugin_mcp_alive — descendant-based readiness
# verifier for required Claude plugin MCP channels. Issue #143.
#
# The banner-based verifier (bridge_tmux_wait_for_claude_channel_banner)
# scans the last 80 tmux lines for a startup-only banner; busy sessions
# scroll the banner off-window in seconds, so restart verify keeps
# failing even when every plugin bun process is healthy. The daemon's
# steady-state liveness already uses a descendant process probe
# (bridge_agent_missing_plugin_mcp_channels_csv → *_alive_for_item →
# bridge_plugin_mcp_descendant_ready_for_item); route restart verify
# through the same signal for consistency.
#
# Polls until every required plugin MCP is alive under the pane PID or
# timeout elapses. Returns 0 when no channels are required, when
# liveness is already clean, or when the loop observes it cleanly.
# Returns 1 if timeout expires with at least one channel still missing.
bridge_tmux_wait_for_claude_plugin_mcp_alive() {
  local agent="$1"
  local timeout="${2:-12}"
  local required=""
  local missing=""
  local start_ts=0
  local elapsed=0

  [[ -n "$agent" ]] || return 0
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  required="$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
  [[ -n "$required" ]] || return 0
  [[ "$timeout" =~ ^[0-9]+$ ]] || timeout=12
  (( timeout > 0 )) || timeout=12

  missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent")"
  [[ -z "$missing" ]] && return 0

  start_ts="$(date +%s)"
  while true; do
    sleep 0.5
    missing="$(bridge_agent_missing_plugin_mcp_channels_csv "$agent")"
    [[ -z "$missing" ]] && return 0
    elapsed=$(( $(date +%s) - start_ts ))
    if (( elapsed >= timeout )); then
      return 1
    fi
  done
}

bridge_agent_launch_channel_status_reason() {
  local agent="$1"
  local required=""
  local required_dev=""
  local effective=""
  local effective_dev=""
  local generated=""

  required="$(bridge_agent_required_launch_channels_csv "$agent")"
  required_dev="$(bridge_agent_required_dev_channels_csv "$agent")"
  generated="$(bridge_claude_launch_with_channels "$agent" "$(bridge_agent_launch_cmd_raw "$agent")")"
  generated="$(bridge_claude_launch_with_development_channels "$generated" "$required_dev")"
  effective_dev="$(bridge_extract_development_channels_from_command "$generated")"
  [[ -n "$required" ]] || {
    if [[ -z "$required_dev" ]]; then
      printf '%s' ""
      return 0
    fi
  }

  effective="$(bridge_extract_channels_from_command "$generated")"
  if [[ -n "$required" ]] && ! bridge_channel_csv_is_subset "$required" "$effective"; then
    printf 'launch command missing required Claude --channels (%s)' "$required"
    return 0
  fi
  if [[ -n "$required_dev" ]] && ! bridge_channel_csv_is_subset "$required_dev" "$effective_dev"; then
    printf 'launch command missing required development channels (%s)' "$required_dev"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_runtime_channel_status_reason() {
  local agent="$1"
  local required=""
  local discord_dir=""
  local telegram_dir=""
  local teams_dir=""
  local readiness=""
  local repair_attempts="${BRIDGE_ENV_READINESS_REPAIR_ATTEMPTS:-2}"

  required="$(bridge_agent_required_runtime_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' ""
    return 0
  fi

  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    discord_dir="$(bridge_agent_discord_state_dir "$agent")"
    if [[ ! -f "$discord_dir/access.json" ]]; then
      printf 'missing Discord access file under %s (access.json required)' "$discord_dir"
      return 0
    fi
    # Issue #534: route through readiness enum so unreadable .env emits a
    # distinct, actionable status_reason instead of the false-negative
    # "missing token" message.
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:discord" "$discord_dir/.env" DISCORD_BOT_TOKEN BOT_TOKEN TOKEN)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Discord .env under %s (ACL repair failed %s times; %s)' \
        "$discord_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$discord_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Discord bot token under %s (.env with DISCORD_BOT_TOKEN required)' "$discord_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    telegram_dir="$(bridge_agent_telegram_state_dir "$agent")"
    if [[ ! -f "$telegram_dir/access.json" ]]; then
      printf 'missing Telegram access file under %s (access.json required)' "$telegram_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:telegram" "$telegram_dir/.env" TELEGRAM_BOT_TOKEN BOT_TOKEN TOKEN)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Telegram .env under %s (ACL repair failed %s times; %s)' \
        "$telegram_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$telegram_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Telegram bot token under %s (.env with TELEGRAM_BOT_TOKEN required)' "$telegram_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:teams"; then
    teams_dir="$(bridge_agent_teams_state_dir "$agent")"
    if [[ ! -f "$teams_dir/access.json" ]]; then
      printf 'missing Teams access file under %s (access.json required)' "$teams_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:teams" "$teams_dir/.env" TEAMS_APP_ID MicrosoftAppId)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Teams .env under %s (ACL repair failed %s times; %s)' \
        "$teams_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$teams_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Teams app id under %s (.env with TEAMS_APP_ID required)' "$teams_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:teams" "$teams_dir/.env" TEAMS_APP_PASSWORD MicrosoftAppPassword)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Teams .env under %s (ACL repair failed %s times; %s)' \
        "$teams_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$teams_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Teams app password under %s (.env with TEAMS_APP_PASSWORD required)' "$teams_dir"
      return 0
    fi
  fi

  # Issue #534: ms365 branch added here. Previously absent — meant ACL
  # diagnostics for ms365 channels could never surface even with the
  # readiness enum in place.
  if bridge_channel_csv_contains "$required" "plugin:ms365"; then
    local ms365_dir=""
    ms365_dir="$(bridge_agent_ms365_state_dir "$agent")"
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:ms365" "$ms365_dir/.env" MS365_CLIENT_ID)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: MS365 .env under %s (ACL repair failed %s times; %s)' \
        "$ms365_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing MS365 client id under %s (.env with MS365_CLIENT_ID required)' "$ms365_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:ms365" "$ms365_dir/.env" MS365_CLIENT_SECRET)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: MS365 .env under %s (ACL repair failed %s times; %s)' \
        "$ms365_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing MS365 client secret under %s (.env with MS365_CLIENT_SECRET required)' "$ms365_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:ms365" "$ms365_dir/.env" MS365_TENANT_ID)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: MS365 .env under %s (ACL repair failed %s times; %s)' \
        "$ms365_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$ms365_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing MS365 tenant id under %s (.env with MS365_TENANT_ID required)' "$ms365_dir"
      return 0
    fi
  fi

  if bridge_channel_csv_contains "$required" "plugin:mattermost"; then
    local mattermost_dir=""
    mattermost_dir="$(bridge_agent_mattermost_state_dir "$agent")"
    if [[ ! -f "$mattermost_dir/access.json" ]]; then
      printf 'missing Mattermost access file under %s (access.json required)' "$mattermost_dir"
      return 0
    fi
    readiness="$(bridge_channel_env_file_readiness "$agent" "plugin:mattermost" "$mattermost_dir/.env" MATTERMOST_BOT_TOKEN MATTERMOST_PERSONAL_TOKEN)"
    if [[ "$readiness" == "unreadable" ]]; then
      printf 'unreadable: Mattermost .env under %s (ACL repair failed %s times; %s)' \
        "$mattermost_dir" "$repair_attempts" "$(bridge_channel_env_file_acl_diagnostic "$mattermost_dir/.env" "$repair_attempts")"
      return 0
    fi
    if [[ "$readiness" != "present" ]]; then
      printf 'missing Mattermost bot token under %s (.env with MATTERMOST_BOT_TOKEN required)' "$mattermost_dir"
      return 0
    fi
  fi

  printf '%s' ""
}

bridge_agent_channel_setup_guidance() {
  local agent="$1"
  local reason="${2:-$(bridge_agent_channel_status_reason "$agent")}"
  local required=""
  local cli="$BRIDGE_HOME/agent-bridge"
  local roster_local="$BRIDGE_HOME/agent-roster.local.sh"

  required="$(bridge_agent_channels_csv "$agent")"
  printf "Channel runtime is not configured for '%s': %s" "$agent" "$reason"
  if bridge_channel_csv_contains "$required" "plugin:discord"; then
    printf "\nRun: %s setup discord %s --token <DISCORD_BOT_TOKEN> --channel <DISCORD_CHANNEL_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:telegram"; then
    printf "\nRun: %s setup telegram %s --token <TELEGRAM_BOT_TOKEN> --allow-from <TELEGRAM_USER_ID> --default-chat <TELEGRAM_CHAT_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:teams"; then
    printf "\nRun: %s setup teams %s --app-id <TEAMS_APP_ID> --app-password <TEAMS_APP_PASSWORD> --allow-from <TEAMS_USER_ID>" "$cli" "$agent"
  fi
  if bridge_channel_csv_contains "$required" "plugin:mattermost"; then
    printf "\nRun: %s setup mattermost %s --url <MATTERMOST_URL> --bot-token <BOT_TOKEN> --allow-from <USER_ID>" "$cli" "$agent"
  fi
  printf "\nIf this agent intentionally runs with fewer channels, update %s so BRIDGE_AGENT_CHANNELS[\"%s\"] matches the live runtime before restarting." "$roster_local" "$agent"
}

bridge_agent_channel_status_reason() {
  local agent="$1"
  local reason=""

  reason="$(bridge_agent_launch_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
  fi

  reason="$(bridge_agent_runtime_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "$reason"
    return 0
  fi

  printf '%s' ""
}

bridge_agent_restart_preflight_reason() {
  local agent="$1"
  local session=""
  local reason=""
  local drift=""

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || {
    printf '%s' ""
    return 0
  }

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] || {
    printf '%s' ""
    return 0
  }
  bridge_tmux_session_exists "$session" || {
    printf '%s' ""
    return 0
  }

  reason="$(bridge_agent_channel_status_reason "$agent")"
  [[ -n "$reason" ]] || {
    printf '%s' ""
    return 0
  }

  drift="$(bridge_agent_channel_runtime_drift_reason "$agent")"
  if [[ -n "$drift" ]]; then
    printf '%s' "$drift"
    return 0
  fi

  printf '%s' "$reason"
}

bridge_agent_restart_preflight_guidance() {
  local agent="$1"
  local reason="${2:-$(bridge_agent_restart_preflight_reason "$agent")}"

  [[ -n "$reason" ]] || {
    printf '%s' ""
    return 0
  }

  printf "Restart is blocked for '%s': %s" "$agent" "$reason"
  printf "\nThe running session was left intact to avoid downtime."
  printf "\n%s" "$(bridge_agent_channel_setup_guidance "$agent" "$reason")"
}

bridge_agent_channel_status() {
  local agent="$1"
  local required=""
  local reason=""

  required="$(bridge_agent_channels_csv "$agent")"
  if [[ -z "$required" ]]; then
    printf '%s' "-"
    return 0
  fi

  reason="$(bridge_agent_channel_status_reason "$agent")"
  if [[ -n "$reason" ]]; then
    printf '%s' "miss"
    return 0
  fi

  printf '%s' "ok"
}

bridge_claude_plugin_status() {
  local plugin_spec="$1"
  local registry="${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}"
  local default_manifest=""
  local manifest_owner=""
  local output=""

  if [[ -n "$registry" && -f "$registry" ]]; then
    bridge_require_python
    python3 - "$registry" "$plugin_spec" <<'PY'
import json
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("missing")
    raise SystemExit(0)

plugins = payload.get("plugins") or {}
print("enabled" if spec in plugins else "missing")
PY
    return 0
  fi

  # #346 isolate: when bridge-run.sh executes under an isolated linux-user
  # UID and the per-UID installed_plugins.json is root-owned, that file
  # was written by bridge_write_isolated_installed_plugins_manifest as the
  # authoritative declared-plugin-only catalog. Trusting it here lets a
  # third-party marketplace plugin (whose marketplace metadata is not
  # exposed inside the isolated home) pass preflight without an install
  # attempt that would otherwise crash bridge-run.sh and trigger a tmux
  # respawn loop. Controller (non-root) UIDs do not match the
  # owner==root guard, so the existing claude-plugin-list fallback
  # remains in effect for the controller side.
  default_manifest="${HOME:-}/.claude/plugins/installed_plugins.json"
  if [[ -n "${HOME:-}" && "$(id -u 2>/dev/null || echo 0)" != "0" && -f "$default_manifest" ]]; then
    manifest_owner="$(stat -c '%u' "$default_manifest" 2>/dev/null || echo -1)"
    if [[ "$manifest_owner" == "0" ]]; then
      bridge_require_python
      python3 - "$default_manifest" "$plugin_spec" <<'PY'
import json
import os
import sys
from pathlib import Path

path = Path(sys.argv[1])
spec = sys.argv[2]
try:
    payload = json.loads(path.read_text(encoding="utf-8"))
except Exception:
    print("missing")
    raise SystemExit(0)

entries = (payload.get("plugins") or {}).get(spec) or []
for entry in entries:
    install_path = entry.get("installPath", "")
    if install_path and os.access(install_path, os.R_OK | os.X_OK):
        print("enabled")
        raise SystemExit(0)
print("missing")
PY
      return 0
    fi
  fi

  if ! command -v claude >/dev/null 2>&1; then
    printf '%s' "missing"
    return 0
  fi

  output="$(claude plugin list 2>/dev/null || true)"
  bridge_require_python
  BRIDGE_PLUGIN_LIST_OUTPUT="$output" python3 - "$plugin_spec" <<'PY'
import os
import sys

spec = sys.argv[1]
lines = os.environ.get("BRIDGE_PLUGIN_LIST_OUTPUT", "").splitlines()
current = False

for raw in lines:
    line = raw.strip()
    if spec in line:
        current = True
        continue
    if current and line.startswith("Status:"):
        if "enabled" in line:
            print("enabled")
        elif "disabled" in line:
            print("disabled")
        else:
            print("missing")
        raise SystemExit(0)
    if current and line.startswith("❯ "):
        break

print("missing")
PY
}

bridge_claude_plugin_marketplace() {
  local plugin_spec="$1"

  if [[ "$plugin_spec" == *@* ]]; then
    printf '%s' "${plugin_spec#*@}"
  else
    printf '%s' ""
  fi
}

bridge_claude_marketplace_source() {
  local marketplace="$1"

  case "$marketplace" in
    claude-plugins-official)
      printf '%s' "anthropics/claude-plugins-official"
      ;;
    agent-bridge)
      printf '%s' "$BRIDGE_SCRIPT_DIR"
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_claude_plugin_install_missing_from_marketplace() {
  local output="$1"

  [[ "$output" == *"not found in marketplace"* || "$output" == *"not found"* ]]
}

bridge_force_refresh_claude_marketplace() {
  local marketplace="$1"
  local source=""

  [[ -n "$marketplace" ]] || return 1
  source="$(bridge_claude_marketplace_source "$marketplace")"
  [[ -n "$source" ]] || return 1

  bridge_info "[info] Refreshing Claude plugin marketplace: $marketplace"
  claude plugin marketplace remove "$marketplace" >/dev/null 2>&1 || true
  claude plugin marketplace add "$source" >/dev/null
}

bridge_ensure_claude_plugin_enabled() {
  local plugin_spec="$1"
  local status=""
  local output=""
  local marketplace=""

  status="$(bridge_claude_plugin_status "$plugin_spec")"
  case "$status" in
    enabled)
      bridge_info "[info] Claude plugin ready: $plugin_spec"
      return 0
      ;;
    disabled)
      if [[ -n "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]]; then
        bridge_die "Claude plugin registry marks '$plugin_spec' disabled/missing in test mode."
      fi
      bridge_info "[info] Enabling Claude plugin: $plugin_spec"
      claude plugin enable --scope user "$plugin_spec" >/dev/null
      ;;
    missing)
      if [[ -n "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]]; then
        bridge_die "Claude plugin registry is missing '$plugin_spec' in test mode."
      fi
      bridge_info "[info] Installing Claude plugin: $plugin_spec"
      if ! output="$(claude plugin install --scope user "$plugin_spec" 2>&1)"; then
        marketplace="$(bridge_claude_plugin_marketplace "$plugin_spec")"
        if bridge_claude_plugin_install_missing_from_marketplace "$output" && bridge_force_refresh_claude_marketplace "$marketplace"; then
          bridge_info "[info] Retrying Claude plugin install after marketplace refresh: $plugin_spec"
          claude plugin install --scope user "$plugin_spec" >/dev/null
        else
          printf '%s\n' "$output" >&2
          bridge_die "Claude plugin install failed: $plugin_spec"
        fi
      fi
      ;;
    *)
      bridge_die "Unknown Claude plugin status for '$plugin_spec': $status"
      ;;
  esac

  status="$(bridge_claude_plugin_status "$plugin_spec")"
  [[ "$status" == "enabled" ]] || bridge_die "Claude plugin '$plugin_spec' is not enabled after install/setup (status=$status). Run: claude plugin install --scope user $plugin_spec"
}

bridge_claude_channel_plugins_ready_for_csv() {
  local channels="$1"
  local item=""
  local plugin_spec=""
  local status=""
  local -a items=()

  [[ -n "$channels" ]] || return 0

  IFS=',' read -r -a items <<<"$(bridge_filter_claude_plugin_channels_csv "$channels")"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    status="$(bridge_claude_plugin_status "$plugin_spec")"
    [[ "$status" == "enabled" ]] || return 1
  done

  return 0
}

bridge_agent_channel_setup_complete() {
  local agent="$1"
  local plugins=""

  [[ "$(bridge_agent_channel_status "$agent")" == "ok" || "$(bridge_agent_channel_status "$agent")" == "-" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  plugins="$(bridge_merge_channels_csv "$(bridge_agent_required_launch_channels_csv "$agent")" "$(bridge_agent_required_dev_channels_csv "$agent")")"
  bridge_claude_channel_plugins_ready_for_csv "$plugins"
}

bridge_ensure_agent_bridge_claude_marketplace() {
  local output=""

  [[ -z "${BRIDGE_CLAUDE_INSTALLED_PLUGINS_FILE:-}" ]] || return 0
  command -v claude >/dev/null 2>&1 || return 0

  output="$(claude plugin marketplace list 2>/dev/null || true)"
  if printf '%s\n' "$output" | grep -Fq "agent-bridge"; then
    return 0
  fi

  bridge_info "[info] Adding Claude plugin marketplace: agent-bridge"
  claude plugin marketplace add --scope user "$BRIDGE_SCRIPT_DIR" >/dev/null
}

bridge_ensure_claude_channel_plugins_for_csv() {
  local channels="$1"
  local item=""
  local plugin_spec=""
  local -a items=()

  [[ -n "$channels" ]] || return 0

  IFS=',' read -r -a items <<<"$(bridge_filter_claude_plugin_channels_csv "$channels")"
  for item in "${items[@]}"; do
    item="$(bridge_trim_whitespace "$item")"
    [[ "$item" == plugin:* ]] || continue
    plugin_spec="${item#plugin:}"
    if [[ "$plugin_spec" == *@agent-bridge ]]; then
      bridge_ensure_agent_bridge_claude_marketplace
    fi
    bridge_ensure_claude_plugin_enabled "$plugin_spec"
  done
}

bridge_ensure_claude_channel_plugins() {
  local agent="$1"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_channels_csv "$agent")"
}

bridge_ensure_claude_launch_channel_plugins() {
  local agent="$1"

  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 0
  bridge_ensure_claude_channel_plugins_for_csv "$(bridge_agent_effective_launch_plugin_channels_csv "$agent")"
}

bridge_agent_notify_kind() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_KIND[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  if [[ -n "$(bridge_agent_discord_channel_id "$agent")" ]]; then
    printf 'discord'
    return 0
  fi

  printf '%s' ""
}

bridge_agent_notify_target() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_TARGET[$agent]-}"

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  printf '%s' "$(bridge_agent_discord_channel_id "$agent")"
}

bridge_agent_notify_account() {
  local agent="$1"
  local explicit="${BRIDGE_AGENT_NOTIFY_ACCOUNT[$agent]-}"
  local kind

  if [[ -n "$explicit" ]]; then
    printf '%s' "$explicit"
    return 0
  fi

  kind="$(bridge_agent_notify_kind "$agent")"
  case "$kind" in
    discord)
      printf '%s' "${BRIDGE_DISCORD_RELAY_ACCOUNT:-default}"
      ;;
    telegram)
      printf 'default'
      ;;
    *)
      printf '%s' ""
      ;;
  esac
}

bridge_agent_requires_notify_transport() {
  local agent="$1"
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]]
}

bridge_agent_has_notify_transport() {
  local agent="$1"
  local kind
  local target

  kind="$(bridge_agent_notify_kind "$agent")"
  target="$(bridge_agent_notify_target "$agent")"
  [[ -n "$kind" && -n "$target" ]]
}

bridge_agent_notify_status() {
  local agent="$1"

  if ! bridge_agent_requires_notify_transport "$agent"; then
    printf '%s' "-"
    return 0
  fi

  if bridge_agent_has_notify_transport "$agent"; then
    printf '%s' "ok"
    return 0
  fi

  printf '%s' "miss"
}

bridge_agent_requires_wake_channel() {
  local agent="$1"
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]]
}

bridge_agent_has_wake_channel() {
  local agent="$1"

  if ! bridge_agent_requires_wake_channel "$agent"; then
    return 1
  fi

  [[ -n "$(bridge_agent_session "$agent")" ]]
}

bridge_agent_wake_status() {
  local agent="$1"
  local session=""

  if ! bridge_agent_requires_wake_channel "$agent"; then
    printf '%s' "-"
    return 0
  fi

  session="$(bridge_agent_session "$agent")"
  if [[ -n "$session" ]] && bridge_tmux_session_exists "$session"; then
    case "$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || true)" in
      trust|summary)
        printf '%s' "block"
        return 0
        ;;
    esac
  fi

  if bridge_agent_has_wake_channel "$agent"; then
    printf '%s' "ok"
    return 0
  fi

  printf '%s' "miss"
}

bridge_agent_loop() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_LOOP[$agent]-1}"
}

bridge_agent_continue() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_CONTINUE[$agent]-1}"
}

bridge_agent_model() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_MODEL[$agent]-}"
}

bridge_agent_effort() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_EFFORT[$agent]-}"
}

bridge_agent_permission_mode() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_PERMISSION_MODE[$agent]-}"
}

# Returns 0 (true) when none of model/effort/permission_mode have been set
# for $agent and permission_mode is not explicitly "legacy". In that case the
# launch builders MUST emit the historical command shape (no --model /
# --effort / --permission-mode flags, --dangerously-skip-permissions kept) so
# rosters that predate these fields keep launching byte-for-byte the same.
bridge_agent_uses_legacy_launch_flags() {
  local agent="$1"
  local pm model effort
  pm="$(bridge_agent_permission_mode "$agent")"
  model="$(bridge_agent_model "$agent")"
  effort="$(bridge_agent_effort "$agent")"
  if [[ "$pm" == "legacy" ]]; then
    return 0
  fi
  [[ -z "$pm" && -z "$model" && -z "$effort" ]]
}

bridge_agent_session_id() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_SESSION_ID[$agent]-}"
}

bridge_agent_meta_file() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_META_FILE[$agent]-}"
}

bridge_agent_history_key() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_HISTORY_KEY[$agent]-}"
}

bridge_agent_action() {
  local agent="$1"
  local action="$2"
  printf '%s' "${BRIDGE_AGENT_ACTION["$agent:$action"]-}"
}

bridge_agent_idle_timeout() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_IDLE_TIMEOUT[$agent]-0}"
}

bridge_agent_idle_timeout_configured() {
  local agent="$1"
  [[ -v "BRIDGE_AGENT_IDLE_TIMEOUT[$agent]" ]]
}

bridge_agent_is_always_on() {
  local agent="$1"
  local timeout

  bridge_agent_idle_timeout_configured "$agent" || return 1
  timeout="$(bridge_agent_idle_timeout "$agent")"
  [[ "$timeout" =~ ^[0-9]+$ ]] || return 1
  (( timeout == 0 ))
}

bridge_agent_memory_daily_refresh_enabled() {
  local agent="$1"
  local configured=""

  [[ "$(bridge_agent_source "$agent")" == "static" ]] || return 1
  [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || return 1

  if [[ -v "BRIDGE_AGENT_MEMORY_DAILY_REFRESH[$agent]" ]]; then
    configured="${BRIDGE_AGENT_MEMORY_DAILY_REFRESH[$agent]-}"
    case "$configured" in
      1|true|yes|on)
        return 0
        ;;
      0|false|no|off)
        return 1
        ;;
    esac
  fi

  return 0
}

bridge_agent_inject_timestamp() {
  local agent="$1"
  printf '%s' "${BRIDGE_AGENT_INJECT_TIMESTAMP[$agent]-1}"
}

bridge_agent_skills_csv() {
  local agent="$1"
  local configured="${BRIDGE_AGENT_SKILLS[$agent]-}"
  local normalized=""
  local skill=""

  configured="${configured//,/ }"
  for skill in $configured; do
    skill="$(bridge_trim_whitespace "$skill")"
    [[ -n "$skill" ]] || continue
    normalized+="${normalized:+ }$skill"
  done

  printf '%s' "$normalized"
}

bridge_list_actions() {
  local agent="$1"
  local key

  for key in "${!BRIDGE_AGENT_ACTION[@]}"; do
    if [[ "$key" == "$agent:"* ]]; then
      printf '%s\n' "${key#*:}"
    fi
  done | sort -u
}

bridge_agent_is_active() {
  local agent="$1"
  local session

  session="$(bridge_agent_session "$agent")"
  [[ -n "$session" ]] && bridge_tmux_session_exists "$session"
}

bridge_list_agents() {
  local agent
  local actions
  local active

  declare -p BRIDGE_AGENT_IDS >/dev/null 2>&1 || {
    echo "  (등록된 정적 에이전트 없음)"
    return 0
  }

  if [[ ${#BRIDGE_AGENT_IDS[@]} -eq 0 ]]; then
    echo "  (등록된 정적 에이전트 없음)"
    return 0
  fi

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    actions=$(bridge_list_actions "$agent" | paste -sd ',' -)
    if [[ -z "$actions" ]]; then
      actions="-"
    fi

    if bridge_agent_is_active "$agent"; then
      active="yes"
    else
      active="no"
    fi

    printf '  %s — %s\n' "$agent" "$(bridge_agent_desc "$agent")"
    printf '    engine=%s | session=%s | workdir=%s | source=%s | active=%s | loop=%s | actions=%s\n' \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_session "$agent")" \
      "$(bridge_agent_workdir "$agent")" \
      "$(bridge_agent_source "$agent")" \
      "$active" \
      "$(bridge_agent_loop "$agent")" \
      "$actions"
  done
}

bridge_active_agent_ids() {
  local agent

  for agent in "${BRIDGE_AGENT_IDS[@]}"; do
    if bridge_agent_is_active "$agent"; then
      printf '%s\n' "$agent"
    fi
  done
}

bridge_active_agent_id_by_index() {
  local target_index="$1"
  local current_index=0
  local agent

  [[ "$target_index" =~ ^[0-9]+$ ]] || return 1
  (( target_index >= 1 )) || return 1

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    current_index=$((current_index + 1))
    if [[ "$current_index" == "$target_index" ]]; then
      printf '%s' "$agent"
      return 0
    fi
  done < <(bridge_active_agent_ids)

  return 1
}

bridge_list_active_agents_numbered() {
  local index=0
  local agent
  local session_id
  local printed=0
  local summary_output=""
  local -A queue_counts=()
  local -A claimed_counts=()

  if summary_output="$(bridge_queue_cli summary --format tsv 2>/dev/null)"; then
    while IFS=$'\t' read -r agent_name queued claimed _blocked _active _idle _last_seen _last_nudge _session _engine _workdir; do
      [[ -z "$agent_name" ]] && continue
      queue_counts["$agent_name"]="$queued"
      claimed_counts["$agent_name"]="$claimed"
    done <<<"$summary_output"
  fi

  while IFS= read -r agent; do
    [[ -z "$agent" ]] && continue
    index=$((index + 1))
    printed=1
    session_id="$(bridge_agent_session_id "$agent")"
    if [[ -z "$session_id" ]]; then
      session_id="-"
    fi

    # Issue #305 Track C: flag stale registrations whose workdir no longer
    # exists on disk so a leaked smoke fixture or deleted-repo agent is
    # visible in `agent-bridge list` without inspecting the roster file.
    local _workdir
    _workdir="$(bridge_agent_workdir "$agent")"
    if [[ -n "$_workdir" && ! -d "$_workdir" ]]; then
      _workdir="$_workdir [missing]"
    fi

    printf '%d. %s | engine=%s | tmux=%s | cwd=%s | source=%s | loop=%s | inbox=%s | claimed=%s | session_id=%s\n' \
      "$index" \
      "$agent" \
      "$(bridge_agent_engine "$agent")" \
      "$(bridge_agent_session "$agent")" \
      "$_workdir" \
      "$(bridge_agent_source "$agent")" \
      "$(bridge_agent_loop "$agent")" \
      "${queue_counts[$agent]-0}" \
      "${claimed_counts[$agent]-0}" \
      "$session_id"
  done < <(bridge_active_agent_ids)

  if [[ "$printed" == "0" ]]; then
    echo "(활성 bridge 에이전트 세션 없음)"
  fi
}

bridge_refresh_runtime_state() {
  if [[ -f "$BRIDGE_HOME/bridge-sync.sh" ]]; then
    "$BRIDGE_BASH_BIN" "$BRIDGE_HOME/bridge-sync.sh" >/dev/null 2>&1 || true
  else
    bridge_render_active_roster
  fi
}

bridge_agent_plugin_port_from_env_file() {
  # Read a single <KEY>=<value> line from a plugin .env file and echo the
  # value if it parses as a port. Empty output on miss.
  local env_file="$1"
  local key="$2"
  local line=""
  local value=""

  [[ -n "$env_file" && -f "$env_file" ]] || return 0
  [[ -n "$key" ]] || return 0
  # Grab the last occurrence — plugin .env files are append-style in places.
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#${key}=}"
  # Strip optional surrounding quotes and whitespace.
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

bridge_agent_plugin_ports() {
  # Enumerate known plugin ports for an agent. Currently only teams binds
  # a long-lived port inside the tmux pane tree, but the helper is built
  # to grow: each entry is "<port>\t<binary-name>\t<plugin-label>".
  local agent="$1"
  local teams_env=""
  local port=""

  teams_env="$(bridge_agent_teams_state_dir "$agent")/.env"
  port="$(bridge_agent_plugin_port_from_env_file "$teams_env" "TEAMS_WEBHOOK_PORT" 2>/dev/null || true)"
  if [[ -n "$port" ]]; then
    printf '%s\t%s\t%s\n' "$port" "bun" "teams"
  fi

  # Mattermost plugin uses an outbound WebSocket connection (no listener),
  # so it has no port to advertise here. Inbound HTTP listener was removed
  # when the channel migrated from Outgoing Webhook to /api/v4/websocket.
}

bridge_kill_port_holder_if_orphan() {
  # Port-aware fallback to the generic orphan cleanup: if $port is still
  # bound after session stop, find the pid holding it, confirm it is
  # rooted at pid 1 (reparented to init) and that its command matches the
  # plugin binary name, then SIGTERM → wait → SIGKILL it specifically.
  # See issue #69 Defect A.
  local port="$1"
  local binary_name="$2"
  local plugin_label="$3"
  local -a holders=()
  local pid=""
  local ppid_value=""
  local cmd=""
  local attempt=0

  [[ "$port" =~ ^[0-9]+$ ]] || return 0
  [[ -n "$binary_name" ]] || return 0

  # Enumerate PIDs holding the port. Prefer ss -tlnp, fall back to lsof.
  if command -v ss >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && holders+=("$pid")
    done < <(
      ss -H -tlnp "sport = :${port}" 2>/dev/null \
        | grep -oE 'pid=[0-9]+' \
        | awk -F= '{print $2}' \
        | sort -u
    )
  fi
  if [[ ${#holders[@]} -eq 0 ]] && command -v lsof >/dev/null 2>&1; then
    while IFS= read -r pid; do
      [[ -n "$pid" ]] && holders+=("$pid")
    done < <(lsof -ti ":${port}" 2>/dev/null | sort -u)
  fi

  [[ ${#holders[@]} -gt 0 ]] || return 0

  for pid in "${holders[@]}"; do
    [[ "$pid" =~ ^[0-9]+$ ]] || continue
    # Only touch processes that have been reparented to init/launchd (ppid=1
    # or 0). A live session's bun child still parented to a tmux pane
    # process must not be killed from under it.
    ppid_value="$(ps -o ppid= -p "$pid" 2>/dev/null | tr -d '[:space:]' || true)"
    [[ "$ppid_value" =~ ^[0-9]+$ ]] || continue
    (( ppid_value == 0 || ppid_value == 1 )) || continue
    cmd="$(ps -o command= -p "$pid" 2>/dev/null || true)"
    # Require the recognized binary name in the command line to avoid
    # killing an unrelated process that happened to bind the same port.
    [[ "$cmd" == *"${binary_name}"* ]] || continue

    bridge_info "[info] killing reparented ${plugin_label} port holder pid=${pid} port=${port} cmd='${cmd}' (issue #69)"
    kill -TERM "$pid" >/dev/null 2>&1 || true
    for attempt in {1..20}; do
      if ! kill -0 "$pid" >/dev/null 2>&1; then
        break
      fi
      sleep 0.1
    done
    if kill -0 "$pid" >/dev/null 2>&1; then
      kill -KILL "$pid" >/dev/null 2>&1 || true
    fi
  done
}

bridge_agent_port_aware_orphan_cleanup_after_session_stop() {
  # Complement to bridge_mcp_orphan_cleanup_after_session_stop: walk the
  # plugin ports this agent reserves and make sure nothing is still
  # holding them after the tmux tree comes down. Belt-and-suspenders for
  # issue #69 Defect A, where reparented bun processes have been observed
  # to survive the pattern-based cleanup.
  local agent="$1"
  local port=""
  local binary=""
  local label=""

  [[ "${BRIDGE_PLUGIN_PORT_ORPHAN_CLEANUP_ENABLED:-1}" == "1" ]] || return 0

  while IFS=$'\t' read -r port binary label; do
    [[ -n "$port" ]] || continue
    bridge_kill_port_holder_if_orphan "$port" "$binary" "$label" \
      >/dev/null 2>&1 || true
  done < <(bridge_agent_plugin_ports "$agent" 2>/dev/null || true)
}

bridge_kill_agent_session() {
  local agent="$1"
  local session
  local attempt

  session="$(bridge_agent_session "$agent")"
  if [[ -z "$session" ]]; then
    bridge_warn "tmux 세션 정보가 없습니다: $agent"
    return 1
  fi

  if ! bridge_tmux_session_exists "$session"; then
    bridge_warn "이미 종료된 세션입니다: $agent/$session"
    return 1
  fi

  bridge_tmux_kill_session "$session"
  for attempt in {1..10}; do
    if ! bridge_tmux_session_exists "$session"; then
      break
    fi
    sleep 0.1
  done
  if bridge_tmux_session_exists "$session"; then
    bridge_warn "tmux 세션이 종료되지 않았습니다: $agent/$session"
    return 1
  fi
  sleep 0.2
  bridge_mcp_orphan_cleanup_after_session_stop "$agent" >/dev/null 2>&1 || true
  bridge_agent_port_aware_orphan_cleanup_after_session_stop "$agent" \
    >/dev/null 2>&1 || true
  bridge_agent_clear_idle_marker "$agent"
  bridge_info "[info] killed ${agent}/${session}"
}

bridge_manual_stop_agent_session() {
  local agent="$1"
  local source

  source="$(bridge_agent_source "$agent")"
  if [[ "$source" == "static" ]]; then
    bridge_agent_mark_manual_stop "$agent"
  fi

  if ! bridge_kill_agent_session "$agent"; then
    if [[ "$source" == "static" ]]; then
      bridge_agent_clear_manual_stop "$agent"
    fi
    return 1
  fi

  if [[ "$source" == "static" ]]; then
    bridge_info "[info] manual stop armed for ${agent}; use 'agent-bridge agent start ${agent}' to resume"
  fi
}

bridge_kill_active_agent_by_index() {
  local index="$1"
  local agent

  if ! agent="$(bridge_active_agent_id_by_index "$index")"; then
    bridge_die "활성 에이전트 번호가 올바르지 않습니다: $index"
  fi

  bridge_manual_stop_agent_session "$agent"
  bridge_refresh_runtime_state
}

bridge_kill_all_active_agents() {
  local -a agents=()
  local agent

  mapfile -t agents < <(bridge_active_agent_ids)
  if [[ ${#agents[@]} -eq 0 ]]; then
    echo "[info] 종료할 활성 bridge 에이전트 세션이 없습니다."
    return 0
  fi

  for agent in "${agents[@]}"; do
    bridge_manual_stop_agent_session "$agent" || true
  done

  bridge_refresh_runtime_state
}

bridge_plugin_port_range_start() {
  printf '%s' "${BRIDGE_PLUGIN_PORT_RANGE_START:-39800}"
}

bridge_plugin_port_range_end() {
  printf '%s' "${BRIDGE_PLUGIN_PORT_RANGE_END:-39999}"
}

bridge_plugin_channel_state_dir() {
  local agent="$1"
  local label="$2"

  case "$label" in
    teams)
      bridge_agent_teams_state_dir "$agent"
      ;;
    discord)
      bridge_agent_discord_state_dir "$agent"
      ;;
    telegram)
      bridge_agent_telegram_state_dir "$agent"
      ;;
    ms365)
      bridge_agent_ms365_state_dir "$agent"
      ;;
    mattermost)
      bridge_agent_mattermost_state_dir "$agent"
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_plugin_port_env_key() {
  local label="$1"

  case "$label" in
    teams)
      printf 'TEAMS_WEBHOOK_PORT'
      ;;
    discord)
      printf 'DISCORD_WEBHOOK_PORT'
      ;;
    telegram)
      printf 'TELEGRAM_WEBHOOK_PORT'
      ;;
    *)
      return 1
      ;;
  esac
}

bridge_read_port_from_env_file() {
  local env_file="$1"
  local key="$2"
  local line=""
  local value=""

  [[ -f "$env_file" ]] || return 0
  [[ -n "$key" ]] || return 0
  line="$(grep -E "^${key}=" "$env_file" 2>/dev/null | tail -n 1 || true)"
  [[ -n "$line" ]] || return 0
  value="${line#"${key}="}"
  value="${value%\"}"
  value="${value#\"}"
  value="${value%\'}"
  value="${value#\'}"
  value="${value//[[:space:]]/}"
  [[ "$value" =~ ^[0-9]+$ ]] || return 0
  printf '%s' "$value"
}

bridge_port_is_free() {
  local port="$1"

  [[ "$port" =~ ^[0-9]+$ ]] || return 1
  python3 - "$port" <<'PY' 2>/dev/null
import socket
import sys

port = int(sys.argv[1])
sock = socket.socket(socket.AF_INET, socket.SOCK_STREAM)
try:
    sock.bind(("127.0.0.1", port))
except OSError:
    sys.exit(1)
finally:
    sock.close()
sys.exit(0)
PY
}

bridge_allocate_channel_port() {
  local agent="$1"
  local label="$2"
  local state_dir=""
  local env_file=""
  local env_key=""
  local range_start range_end span
  local current=""
  local candidate=""
  local hash_hex
  local -i offset=0
  local -i attempts=0
  local -i max_attempts=0
  local -i allocated=0

  if [[ -z "$agent" || -z "$label" ]]; then
    bridge_warn "bridge_allocate_channel_port: agent와 plugin label이 필요합니다"
    return 1
  fi

  if ! state_dir="$(bridge_plugin_channel_state_dir "$agent" "$label")"; then
    bridge_warn "bridge_allocate_channel_port: 지원하지 않는 plugin label: $label"
    return 1
  fi
  if ! env_key="$(bridge_plugin_port_env_key "$label")"; then
    bridge_warn "bridge_allocate_channel_port: plugin label에 대한 port env key를 결정하지 못했습니다: $label"
    return 1
  fi

  env_file="$state_dir/.env"
  range_start="$(bridge_plugin_port_range_start)"
  range_end="$(bridge_plugin_port_range_end)"

  if ! [[ "$range_start" =~ ^[0-9]+$ && "$range_end" =~ ^[0-9]+$ ]] || (( range_start <= 0 || range_end <= 0 || range_end < range_start )); then
    bridge_warn "BRIDGE_PLUGIN_PORT_RANGE_* 가 유효하지 않습니다: ${range_start}-${range_end}"
    return 1
  fi
  span=$(( range_end - range_start + 1 ))

  if [[ -f "$env_file" ]]; then
    current="$(bridge_read_port_from_env_file "$env_file" "$env_key" 2>/dev/null || true)"
  fi
  if [[ "$current" =~ ^[0-9]+$ ]] && (( current >= range_start && current <= range_end )); then
    if bridge_port_is_free "$current"; then
      printf '%s' "$current"
      return 0
    fi
  fi

  hash_hex="$(bridge_sha1 "${agent}|${label}")"
  hash_hex="${hash_hex:0:8}"
  if [[ -z "$hash_hex" ]]; then
    offset=0
  else
    offset=$(( 16#${hash_hex} % span ))
  fi

  max_attempts="$span"
  attempts=0
  while (( attempts < max_attempts )); do
    candidate=$(( range_start + ( offset + attempts ) % span ))
    if bridge_port_is_free "$candidate"; then
      allocated="$candidate"
      break
    fi
    attempts=$(( attempts + 1 ))
  done

  if (( allocated == 0 )); then
    bridge_warn "bridge_allocate_channel_port: ${range_start}-${range_end} 범위에서 사용 가능한 포트를 찾지 못했습니다 (agent=${agent}, label=${label})"
    return 1
  fi

  mkdir -p "$state_dir"
  bridge_upsert_env_value "$env_file" "$env_key" "$allocated"
  printf '%s' "$allocated"
}

bridge_upsert_env_value() {
  local env_file="$1"
  local key="$2"
  local value="$3"
  local tmp_file=""

  if [[ -z "$env_file" || -z "$key" ]]; then
    return 1
  fi

  mkdir -p "$(dirname "$env_file")"
  if [[ ! -f "$env_file" ]]; then
    printf '%s=%s\n' "$key" "$value" >"$env_file"
    return 0
  fi

  tmp_file="$(mktemp "${env_file}.XXXXXX")" || return 1
  if grep -Eq "^${key}=" "$env_file" 2>/dev/null; then
    awk -v key="$key" -v value="$value" '
      BEGIN { replaced = 0 }
      {
        if ($0 ~ "^" key "=") {
          if (!replaced) {
            print key "=" value
            replaced = 1
          }
        } else {
          print $0
        }
      }
      END {
        if (!replaced) {
          print key "=" value
        }
      }
    ' "$env_file" >"$tmp_file"
  else
    cat "$env_file" >"$tmp_file"
    printf '%s=%s\n' "$key" "$value" >>"$tmp_file"
  fi
  mv "$tmp_file" "$env_file"
}
