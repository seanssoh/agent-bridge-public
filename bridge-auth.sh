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
  bash $SCRIPT_DIR/bridge-auth.sh claude-token receive --id <id> [--fulfill <request-id>] [--activate] [--replace] [--enable-auto-rotate] [--threshold 99] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token receive --request --id <id> [--agents static|all|csv] [--activate] [--enable-auto-rotate] --json
  bash $SCRIPT_DIR/bridge-auth.sh claude-token list [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token activate <id> [--sync] [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token sync [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token backfill-settings [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token rotate [--if-auto-enabled] [--reason <text>] [--sync] [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token check <id> [--enable-on-ok] [--disable-on-quota] [--timeout <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token classify-output [--stdout-file <path>] [--stderr-file <path>] [--returncode <n>]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token mark-quota <id> [--reset-at <iso>] [--retry-seconds <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token recover-due [--timeout <sec>] [--retry-seconds <sec>] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token auto-rotate <enable|disable|status> [--threshold 99] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh codex-cred register --source <agent> [--json]
  bash $SCRIPT_DIR/bridge-auth.sh codex-cred source [--json]
  bash $SCRIPT_DIR/bridge-auth.sh codex-cred sync [--agents static|all|csv] [--json]
  bash $SCRIPT_DIR/bridge-auth.sh codex-cred verify --file <path> [--json]
EOF
}

# Fleet-credential Phase 1 (#1470): the `claude-token` CLI verb operates
# on the Claude engine's credential registry. The engine is named
# explicitly (rather than as a bare `claude` string literal scattered
# through the selector/sync paths) so a later wave can add a parallel
# verb for another engine by flipping this binding + the descriptor —
# the dispatch shape below stays the same. Phase 1 keeps Claude behavior
# byte-identical: this is `claude`, exactly as before.
BRIDGE_AUTH_CLAUDE_ENGINE="claude"

bridge_auth_registry_path() {
  printf '%s' "${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"
}

# bridge_auth_engine_cred_file_tail <agent> <engine>
#
# Resolve the home-relative credential-file tail for an engine via the
# descriptor seam, with a behavior-preserving Claude fallback so the
# auth path keeps working even if the descriptor is not sourced (e.g. an
# isolated unit test that sources bridge-auth.sh directly). Phase 1 only
# the Claude tail is consumed; the helper exists so the dest path is no
# longer a Claude-hardcoded string in the sync writer.
bridge_auth_engine_cred_file_tail() {
  local agent="$1"
  local engine="${2:-$BRIDGE_AUTH_CLAUDE_ENGINE}"
  local tail=""
  if declare -F bridge_engine_cred_dest_path >/dev/null 2>&1; then
    tail="$(bridge_engine_cred_dest_path "$agent" "$engine" 2>/dev/null || true)"
  fi
  if [[ -z "$tail" ]]; then
    # Descriptor unavailable / unknown engine — preserve the historical
    # Claude tail so the Claude path is never broken by a missing seam.
    tail=".claude/.credentials.json"
  fi
  printf '%s' "$tail"
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
  local cred_tail=""
  user_home="$(bridge_auth_resolved_user_home_for_agent "$agent")" || return 1
  [[ -n "$user_home" ]] || {
    printf '[error] cannot resolve user home for agent: %s\n' "$agent" >&2
    return 1
  }
  bridge_auth_verify_safe_claude_dir "$agent" "$user_home" || return 1
  # Fleet-credential Phase 1 (#1470): resolve the dest tail through the
  # engine-auth descriptor instead of a hardcoded `.claude/.credentials.json`.
  # For the Claude engine this is byte-identical to the old literal.
  cred_tail="$(bridge_auth_engine_cred_file_tail "$agent" "$BRIDGE_AUTH_CLAUDE_ENGINE")"
  printf '%s/%s' "$user_home" "$cred_tail"
}

bridge_auth_prepare_credential_file() {
  local agent="$1"
  local file="$2"
  local dir=""
  local user_home=""
  local os_user=""

  dir="$(dirname "$file")"
  user_home="$(bridge_auth_resolved_user_home_for_agent "$agent")" || return 1
  bridge_auth_verify_safe_claude_dir "$agent" "$user_home" || return 1
  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
    [[ -n "$os_user" ]] || {
      printf '[error] cannot resolve isolated os_user for agent: %s\n' "$agent" >&2
      return 1
    }
    # Phase 3 codex design: route the parent-dir contract through the
    # shared helper so token sync, prepare, and the restart reverter
    # all converge on the same `.claude` contract (root:ab-agent-<agent>
    # mode 3770/2770 with sticky for integrity). The credential file
    # itself (`.credentials.json`) is still owned by the isolated UID
    # with mode 0600, written by the token-sync writer downstream; only
    # the parent-dir contract goes through the helper.
    #
    # Previously this branch ran `mkdir/chown $os_user:$primary_group/
    # chmod 0700`, which set the wrong primary group on `.claude` and
    # locked the controller's harvester out of `~/.claude/projects/`
    # after the next prepare/restart cycle (#1180 sequel: gap E).
    # ALLOW_RUNNING=1: token sync runs against live agents; the helper
    # is internal-caller safe here (no chmod-while-write race because
    # the writer has not yet opened the credential file).
    if ! BRIDGE_PREPARE_ISOLATION_ALLOW_RUNNING=1 \
          bridge_linux_normalize_isolated_home_contract "$agent" "$os_user" "$user_home" >/dev/null; then
      printf '[error] cannot normalize isolated home contract for agent: %s\n' "$agent" >&2
      return 1
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
  # Issue #1238 companion bug: on iso v2 fresh installs, the controller
  # may transiently lack supplementary-group membership for
  # `ab-agent-<a>` (KNOWN_ISSUES §28 — login-cached group set) and the
  # plain `python3 - "$file" "$config_dir" <<'PY'` invocation that used
  # to live here ran as the un-refreshed controller. The Python child's
  # first `path.exists()` then raised `PermissionError: [Errno 13]
  # Permission denied: .../credentials/launch-secrets.env` (parent
  # traversal needs group membership). The unhandled exception aborted
  # `bridge_auth_sync_agents` mid-walk, so registering a setup token
  # only ever populated `patch` (the controller-shared agent) and every
  # iso agent — and every reviewer after the first iso failure — was
  # silently skipped.
  #
  # Catching `PermissionError` and returning `False` would be wrong:
  # that converts an inaccessible existing secret into "absent" and
  # would let the subsequent `path.write_text(...)` clobber a
  # controller-owned credential file. Instead route the read/write
  # through `bridge_auth_run_privileged`, which mirrors the privileged
  # path used by `bridge_auth_sync_agent_python` (:353-355) — direct
  # first (works on non-isolated dev installs and on hosts where the
  # controller already has the group), passwordless sudo otherwise.
  # `bridge_auth_fix_legacy_secret_file_mode` (called below) then
  # normalizes the final ownership / mode regardless of which branch
  # wrote the file.
  #
  # Codex r1 BLOCKING on PR #1239: the original r1 fix used
  # `bridge_auth_run_privileged python3 - "$file" "$config_dir" <<'PY'`,
  # which is unsafe because `bridge_auth_run_privileged` retries on
  # failure (direct first, then `sudo -n`). With heredoc-stdin the
  # FIRST Python child consumes the heredoc fd before raising
  # `PermissionError`; the sudo fallback then reads EOF and silently
  # exits 0 with no script side effect — the wrapper reports success
  # without executing the privileged update. The Python body was
  # therefore extracted to `lib/upgrade-helpers/auth-legacy-claude-
  # config-env.py` and invoked with file-as-argv (no stdin), mirroring
  # the v0.13.9 footgun #11 extraction pattern. Every retry by the
  # wrapper re-reads the script from disk, so the privileged fallback
  # runs the same code as the direct attempt.
  bridge_auth_run_privileged python3 \
      "$SCRIPT_DIR/lib/upgrade-helpers/auth-legacy-claude-config-env.py" \
      "$file" "$config_dir"
  bridge_auth_fix_legacy_secret_file_mode "$agent" "$file"
}

bridge_auth_fix_legacy_secret_file_mode() {
  local agent="$1"
  local file="$2"
  local group=""
  local file_mode="0600"

  # The Claude Code token is a controller-shared secret (one credential,
  # all agents share the same login). The correct isolation primitive is
  # ab-shared (#998 PR A), NOT the per-agent ab-agent-<name> group (#998
  # PR B) which applies only to per-agent secrets such as channel dotenvs.
  #
  # Branch on the agent's effective isolation mode:
  #   - shared-mode: controller and agent are the same UID — no cross-UID
  #     gap to bridge. Apply 0600 and return; chown is a no-op.
  #   - linux-user isolated: chown to <controller>:ab-shared (mode 0640) so
  #     the isolated UID (a member of ab-shared) can read the credential.
  if bridge_isolation_v2_active 2>/dev/null; then
    if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
      group="${BRIDGE_SHARED_GROUP:-ab-shared}"
      if bridge_isolation_v2_group_exists "$group"; then
        file_mode="0640"
        bridge_auth_run_privileged chown "$(id -un):$group" "$file" || return 1
      else
        # Codex r1 BLOCKING: linux-user isolated agent without the
        # shared group means the install is misconfigured. Returning success
        # with mode 0600 here would let sync report status=ok while the next
        # isolated launch fails — `bridge_isolation_v2_load_secret_env`
        # cannot read the controller-owned 0600 secret env file under the
        # isolated UID. Hard-fail so `bridge_auth_sync_agents` records the
        # agent as failed. Shared-mode agents never reach this branch (they
        # short-circuit on the predicate above), so the M2 fix is preserved.
        printf '[error] auth sync: %s group missing for isolated agent %s; install misconfigured\n' "$group" "$agent" >&2
        return 1
      fi
    fi
    # shared-mode agent: same UID as controller — 0600 is correct, no chown needed.
  fi
  chmod "$file_mode" "$file" 2>/dev/null || bridge_auth_run_privileged chmod "$file_mode" "$file"
}

bridge_auth_controller_credentials_path() {
  # #1075 — resolve the controller's ``~/.claude/.credentials.json`` from the
  # same controller-user view that the isolation-v2 layer uses
  # (`bridge_isolation_v2_controller_user`). Returns the path even when the
  # file does not yet exist; ``cmd_sync_agent`` only reads it on the
  # no-active-token fallback branch and surfaces a clean error if missing.
  #
  # Precedence: ``$BRIDGE_CONTROLLER_HOME`` (explicit override, used in tests)
  # → ``bridge_isolation_v2_controller_user`` → ``$SUDO_USER`` → ``$HOME``.
  local controller_user=""
  local controller_home=""
  if [[ -n "${BRIDGE_CONTROLLER_HOME:-}" ]]; then
    controller_home="$BRIDGE_CONTROLLER_HOME"
  fi
  if [[ -z "$controller_home" ]]; then
    if declare -F bridge_isolation_v2_controller_user >/dev/null 2>&1; then
      controller_user="$(bridge_isolation_v2_controller_user 2>/dev/null || true)"
    fi
    if [[ -z "$controller_user" ]]; then
      controller_user="${SUDO_USER:-${USER:-${LOGNAME:-}}}"
    fi
    if [[ -n "$controller_user" ]]; then
      controller_home="$(getent passwd "$controller_user" 2>/dev/null | cut -d: -f6 || true)"
    fi
    if [[ -z "$controller_home" ]]; then
      controller_home="${HOME:-}"
    fi
  fi
  [[ -n "$controller_home" ]] || return 1
  printf '%s/.claude/.credentials.json' "$controller_home"
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
  local controller_cred=""
  local -a workdir_args=()
  local -a owner_args=()
  local -a controller_cred_args=()

  workdir="$(bridge_agent_workdir "$agent" 2>/dev/null || true)"
  [[ -n "$workdir" ]] && workdir_args=(--workdir "$workdir")
  controller_cred="$(bridge_auth_controller_credentials_path 2>/dev/null || true)"
  if [[ -n "$controller_cred" ]]; then
    controller_cred_args=(--controller-credentials "$controller_cred")
  fi

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
      "${workdir_args[@]}" "${owner_args[@]}" "${controller_cred_args[@]}" --json
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
    "${workdir_args[@]}" "${owner_args[@]}" "${controller_cred_args[@]}" --json
}

bridge_auth_selected_agents() {
  local spec="${1:-static}"
  local agent=""
  local item=""
  local -a explicit=()
  # Fleet-credential Phase 1 (#1470): the engine this `claude-token`
  # registry syncs is named via the explicit binding rather than a bare
  # `claude` literal so the selector is an engine-parameterized filter,
  # not a Claude-hardcoded one. Phase 1 value == `claude`, byte-identical.
  local engine="$BRIDGE_AUTH_CLAUDE_ENGINE"

  case "$spec" in
    static|"")
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
        [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    all|claude)
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
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
        [[ "$(bridge_agent_engine "$item")" == "$engine" ]] || {
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
  # Codex r1 BLOCKING #1 (2026-05-27): per-agent aliveness/remaining_ms
  # propagation. Inner ``bridge_auth_sync_agent_python`` (-> bridge-auth.py
  # cmd_sync_agent) emits a JSON envelope on stdout carrying
  # ``aliveness`` + ``remaining_ms`` fields (alongside ``status`` /
  # ``agent`` / ``fingerprint`` etc.). The pre-r2 wrapper captured
  # stdout+stderr into ``output`` and DISCARDED it on the success branch,
  # so the daemon's periodic-sync tick (bridge-daemon.sh:1944-1959) only
  # saw the wrapper's top-level ``status`` field and could not audit
  # which agents were synced with a near-expiry token. We now carry the
  # per-agent payload through into the final wrapper JSON so structured
  # consumers can branch on the per-agent ``aliveness`` value. Stderr
  # ``warning:`` lines (the near-expiry banner emitted by cmd_sync_agent)
  # are forwarded verbatim to OUR stderr so the operator sees them via
  # the daemon's log capture rather than being swallowed.
  local -a synced_payloads=()

  selection_error="$(mktemp "${TMPDIR:-/tmp}/agb-auth-select.XXXXXX" 2>/dev/null || printf '%s' "/tmp/agb-auth-select.$$.$RANDOM")"
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
    # Codex r1 BLOCKING #1: split stdout (JSON payload) from stderr
    # (operator-visible warnings). Stderr lines that begin with
    # ``warning:`` are the near-expiry banner from cmd_sync_agent — we
    # forward them to OUR stderr so the daemon's log capture preserves
    # them; everything else stays attached to the failure path for the
    # ``$agent:error`` row.
    local stderr_tmp=""
    stderr_tmp="$(mktemp "${TMPDIR:-/tmp}/agb-auth-sync.XXXXXX" 2>/dev/null || printf '%s' "/tmp/agb-auth-sync.$$.$RANDOM")"
    if ! output="$(bridge_auth_sync_agent_python "$agent" "$registry" "$file" 2>"$stderr_tmp")"; then
      local stderr_body=""
      stderr_body="$(cat "$stderr_tmp" 2>/dev/null || printf '')"
      rm -f "$stderr_tmp"
      # Stitch stderr into the failure row so the original ``$agent:error``
      # contract carries the underlying message. Newlines are flattened
      # into ' | ' so the colon-separated row stays single-line.
      local combined=""
      if [[ -n "$stderr_body" ]]; then
        combined="${output:+$output | }${stderr_body//$'\n'/ | }"
      else
        combined="$output"
      fi
      failed+=("$agent:${combined:-failed}")
      rc=1
      continue
    fi
    # Forward operator-visible warnings (near-expiry banner from
    # cmd_sync_agent) to our stderr so they remain visible to the daemon
    # log capture; without this the warning is invisible to anything
    # downstream of the wrapper.
    if [[ -s "$stderr_tmp" ]]; then
      cat "$stderr_tmp" >&2 || true
    fi
    rm -f "$stderr_tmp"
    # PR #799 r3 codex finding 1 — Python's ``write_private_file_atomic``
    # writes the tempfile, chmod/chown's it (when --owner-uid/--owner-gid
    # are passed) BEFORE ``os.replace``, so .credentials.json / .claude.json
    # / settings.json land at their final paths already owner-correct and
    # mode 0600. The previous post-sync chown/chmod "defense-in-depth"
    # repair walked the final pathnames without re-lstat after replace,
    # which is a TOCTOU: the agent UID could swap the final path to a
    # symlink between ``os.replace`` and the privileged chown, letting the
    # privileged op follow out of the agent's home. The repair has been
    # removed from the sync hot path. Legacy installs with pre-existing
    # root-owned credential files are fixed by simply re-running
    # ``sync`` — the atomic rewrite replaces the stale file with a
    # correctly-owned one.
    if ! bridge_auth_update_legacy_claude_config_env "$agent" "$legacy_file" "$(dirname "$file")"; then
      failed+=("$agent:legacy_env_update_failed")
      rc=1
      continue
    fi
    synced+=("$agent")
    # Codex r1 BLOCKING #1: capture the inner JSON so the wrapper can
    # surface per-agent aliveness/remaining_ms to the daemon-side audit
    # consumer (bridge-daemon.sh sync-aliveness-parse). Empty / non-JSON
    # is tolerated — wrapper falls back to ``aliveness=""`` for that row.
    synced_payloads+=("${output:-}")
    [[ "$json_mode" == "1" ]] || printf 'synced: %s -> %s\n' "$agent" "$file"
  done

  if [[ "$json_mode" == "1" ]]; then
    # Codex r1 BLOCKING #1 (2026-05-27): wrapper JSON now carries
    # per-agent ``aliveness`` + ``remaining_ms`` so the daemon's
    # periodic-sync tick can audit token freshness per row. The argv
    # contract is:
    #
    #   argv[1..N-1] = synced rows; each row is ``agent\tpayload_json``
    #                  (tab-separated). Empty / unparseable payload is
    #                  tolerated — fields fall back to ``""``.
    #   argv[N]     = literal ``--``
    #   argv[N+1..] = failed rows in ``agent:error`` shape (unchanged).
    #
    # The python helper splits on the tab so the embedded JSON cannot
    # collide with the row separator (the JSON itself contains commas
    # but never tab characters — pretty-printed by cmd_sync_agent with
    # indent=2 but no leading whitespace before the keys).
    local -a synced_args=()
    local idx=0
    for ((idx = 0; idx < ${#synced[@]}; idx++)); do
      # Flatten newlines so the row stays single-line; the helper's
      # json.loads handles internal whitespace before the call.
      local row_payload="${synced_payloads[idx]:-}"
      row_payload="${row_payload//$'\n'/ }"
      synced_args+=("${synced[idx]}"$'\t'"$row_payload")
    done
    if (( ${#synced_args[@]} == 0 )); then
      synced_args=()
    fi
    python3 - "${synced_args[@]}" -- "${failed[@]}" <<'PY'
import json
import sys

items = sys.argv[1:]
sep = items.index("--") if "--" in items else len(items)
synced_raw = items[:sep]
failed_raw = items[sep + 1 :]

# Per-agent rows now carry the inner cmd_sync_agent JSON so the daemon
# can audit aliveness/remaining_ms. Tab-separated to avoid collision
# with the agent name (which is the ``--name`` slug, no whitespace).
agents = []
synced_names = []
for row in synced_raw:
    if "\t" in row:
        agent, payload_text = row.split("\t", 1)
    else:
        agent, payload_text = row, ""
    inner = {}
    aliveness = ""
    remaining_ms = 0
    if payload_text.strip():
        try:
            inner = json.loads(payload_text)
        except Exception:
            inner = {}
    if isinstance(inner, dict):
        aliveness = str(inner.get("aliveness", "") or "")
        try:
            remaining_ms = int(inner.get("remaining_ms", 0) or 0)
        except (TypeError, ValueError):
            remaining_ms = 0
    synced_names.append(agent)
    agents.append({
        "agent": agent,
        "aliveness": aliveness,
        "remaining_ms": remaining_ms,
    })

failed = []
for row in failed_raw:
    if ":" in row:
        agent, error = row.split(":", 1)
    else:
        agent, error = row, "failed"
    failed.append({"agent": agent, "error": error})
status = "ok" if not failed else ("failed" if not synced_names else "partial")
# Backward-compatible: ``agents`` was previously a list[str] of synced
# names. v0.15.0-beta4 Lane F r2 promotes it to list[dict] so per-agent
# aliveness can ride along; consumers that only need the names should
# pull from ``agent_names`` instead. The legacy daemon-helpers
# ``sync-status-parse`` reads ``status`` (top-level) so its contract
# stays intact.
print(json.dumps({
    "status": status,
    "agents": agents,
    "agent_names": synced_names,
    "failed": failed,
}, ensure_ascii=True, indent=2))
PY
  fi
  return "$rc"
}

# bridge_auth_backfill_settings_agents <spec> <json_mode>
#
# Issue #1855: create-if-absent backfill of the keychain-free apiKeyHelper
# contract into each selected Claude agent's per-agent settings.json. The
# secondary half of the #1809-family backfill — pre-#1520 shared admins were
# provisioned before ensure_claude_settings_file wired apiKeyHelper, so their
# settings.json carries no helper and the #1520 keychain-free gate can never
# pass. Reuses the SAME agent selector + iso owner-arg resolution as the sync
# path, then calls the byte-identical writer via `bridge-auth.py
# backfill-settings`. Idempotent: an already-coherent (or non-Darwin / gate-off)
# agent is a no-op. Emits an aggregate JSON envelope.
bridge_auth_backfill_settings_agents() {
  local spec="$1"
  local json_mode="$2"
  local agent=""
  local cred_file=""
  local config_dir=""
  local os_user=""
  local owner_uid=""
  local owner_gid=""
  local user_home=""
  local selection_output=""
  local rc=0
  local -a agents=()
  local -a backfilled=()
  local -a unchanged=()
  local -a failed=()

  if ! selection_output="$(bridge_auth_selected_agents "$spec" 2>&1)"; then
    printf '%s\n' "$selection_output" >&2
    return 1
  fi
  if [[ -n "$selection_output" ]]; then
    mapfile -t agents <<<"$selection_output"
  fi
  if (( ${#agents[@]} == 0 )); then
    [[ "$json_mode" == "1" ]] && printf '{"status": "skipped", "reason": "no_matching_claude_agents", "backfilled": [], "unchanged": [], "failed": []}\n'
    [[ "$json_mode" == "1" ]] || printf 'skipped: no_matching_claude_agents\n'
    return 0
  fi

  for agent in "${agents[@]}"; do
    local -a owner_args=()
    cred_file="$(bridge_auth_claude_credentials_file_for_agent "$agent" 2>/dev/null)" || {
      failed+=("$agent")
      rc=1
      continue
    }
    config_dir="$(dirname "$cred_file")"
    if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
      os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || true)"
      if [[ -n "$os_user" ]]; then
        owner_uid="$(id -u "$os_user" 2>/dev/null || true)"
        owner_gid="$(id -g "$os_user" 2>/dev/null || true)"
        user_home="$(bridge_agent_linux_user_home "$os_user" 2>/dev/null || true)"
        [[ -n "$owner_uid" ]] && owner_args+=(--owner-uid "$owner_uid")
        [[ -n "$owner_gid" ]] && owner_args+=(--owner-gid "$owner_gid")
        [[ -n "$user_home" ]] && owner_args+=(--allowed-root "$user_home")
      fi
      local out=""
      out="$(bridge_linux_sudo_root python3 "$SCRIPT_DIR/bridge-auth.py" \
        backfill-settings --config-dir "$config_dir" --agent "$agent" \
        "${owner_args[@]}" --json 2>/dev/null)" || { failed+=("$agent"); rc=1; continue; }
    else
      user_home="$(bridge_auth_resolved_user_home_for_agent "$agent" 2>/dev/null || true)"
      [[ -n "$user_home" ]] && owner_args+=(--allowed-root "$user_home")
      local out=""
      out="$(python3 "$SCRIPT_DIR/bridge-auth.py" \
        backfill-settings --config-dir "$config_dir" --agent "$agent" \
        "${owner_args[@]}" --json 2>/dev/null)" || { failed+=("$agent"); rc=1; continue; }
    fi
    if printf '%s' "$out" | grep -q '"changed": true'; then
      backfilled+=("$agent")
    else
      unchanged+=("$agent")
    fi
    [[ "$json_mode" == "1" ]] || printf '%s\n' "$out"
  done

  if [[ "$json_mode" == "1" ]]; then
    python3 - "${backfilled[@]}" -- "${unchanged[@]}" --- "${failed[@]}" <<'PY'
import json, sys
items = sys.argv[1:]
a = items.index("--") if "--" in items else len(items)
backfilled = items[:a]
rest = items[a + 1 :]
b = rest.index("---") if "---" in rest else len(rest)
unchanged = rest[:b]
failed = rest[b + 1 :]
status = "ok" if not failed else ("failed" if not (backfilled or unchanged) else "partial")
print(json.dumps({
    "status": status,
    "backfilled": backfilled,
    "unchanged": unchanged,
    "failed": failed,
    "non_clean": bool(backfilled or failed),
}, ensure_ascii=True, indent=2))
PY
  fi
  return "$rc"
}

# ─────────────────────────────────────────────────────────────────────
# Codex fleet-sync adapter (#1470 Phase 2, #1467).
#
# The operator manually `codex login`s on ONE designated source Codex
# agent; the bridge propagates that source's `<home>/.codex/auth.json`
# write-through to every managed Codex agent (INCLUDING Linux iso v2
# homes) so a fleet of Codex agents shares the one subscription without
# each logging in. There is no rotation/registry/failover — Codex auth is
# a single subscription the `codex` binary self-refreshes in place.
#
# Security contracts (codex-agreed, fleet-credential-design.md §6/§7):
#   Q1 source binding — configurable + admin/controller-owned, persisted
#     in protected state (bridge-auth.py codex-register), validated here
#     as an existing, non-stopped Codex agent. Default to `<admin>-dev`
#     when it exists and is a Codex agent. NOT env-overridable.
#   §6.6 delivery — write-through copy via write_private_file_atomic
#     (0600, chown-before-replace), NEVER a symlink. iso dest owner
#     agent-bridge-<a>:ab-agent-<a>; a failed iso write fails loud.
#   §6.3 iso source read — a 0600 source auth.json owned by an iso UID is
#     read via `sudo -n -u <owner> cat`; if that fails → FAIL LOUD, no
#     world-readable fallback.

BRIDGE_AUTH_CODEX_ENGINE="codex"

# bridge_auth_codex_source_binding [--quiet]
#
# Resolve the configured Codex source agent. Precedence:
#   1. The persisted binding (bridge-auth.py codex-source) — the operator-
#      registered source (Q1: protected state, NOT env-overridable).
#   2. The documented `<admin>-dev` co-located codex pair when it exists
#      and is a Codex agent (a sensible default, still persisted on first
#      register so it is auditable).
# Prints the resolved source agent on stdout (empty if none). Never reads
# an env override — the source is operator-owned, not caller-overridable.
bridge_auth_codex_source_binding() {
  local persisted=""
  # `codex-source` (no --json) prints the bare source agent name, or the
  # literal "(no codex source configured)" placeholder when unset.
  persisted="$(python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$(bridge_auth_registry_path)" \
    codex-source 2>/dev/null || true)"
  case "$persisted" in
    ""|"(no codex source configured)") persisted="" ;;
  esac
  if [[ -n "$persisted" ]]; then
    printf '%s' "$persisted"
    return 0
  fi
  # Default candidate: the admin's `<admin>-dev` codex pair, if present.
  local admin=""
  admin="${BRIDGE_ADMIN_AGENT_ID:-}"
  if [[ -n "$admin" ]]; then
    local candidate="${admin}-dev"
    if bridge_agent_exists "$candidate" \
        && [[ "$(bridge_agent_engine "$candidate")" == "$BRIDGE_AUTH_CODEX_ENGINE" ]]; then
      printf '%s' "$candidate"
      return 0
    fi
  fi
  printf ''
  return 0
}

# bridge_auth_codex_validate_source <agent>
#
# Validate a candidate Codex source agent (Q1): must exist, be a Codex
# engine agent, and not be in a stopped/broken state. Returns 0 on
# success, 1 with an [error] on stderr otherwise.
bridge_auth_codex_validate_source() {
  local agent="$1"
  [[ -n "$agent" ]] || {
    printf '[error] codex source: empty agent name\n' >&2
    return 1
  }
  bridge_agent_exists "$agent" || {
    printf '[error] codex source: unknown agent: %s\n' "$agent" >&2
    return 1
  }
  [[ "$(bridge_agent_engine "$agent")" == "$BRIDGE_AUTH_CODEX_ENGINE" ]] || {
    printf '[error] codex source: %s is not a Codex agent\n' "$agent" >&2
    return 1
  }
  # Stopped/quarantined check: a broken-launch marker means the agent's
  # last launches failed — refuse to bind a dead source so the fleet does
  # not pin a credential from an agent that may never have logged in.
  local broken=""
  if declare -F bridge_agent_broken_launch_file >/dev/null 2>&1; then
    broken="$(bridge_agent_broken_launch_file "$agent" 2>/dev/null || true)"
    if [[ -n "$broken" && -f "$broken" ]]; then
      printf '[error] codex source: %s is in a broken-launch (stopped) state — refusing to bind a stopped source\n' "$agent" >&2
      return 1
    fi
  fi
  return 0
}

# bridge_auth_codex_read_source_auth <source_agent> <out_file>
#
# Read the source agent's `.codex/auth.json` into <out_file> (a controller-
# owned 0600 tempfile). Honors the iso boundary (§6.3): an iso-owned 0600
# source is read via `sudo -n -u <owner> cat`; if the direct read AND the
# sudo fallback both fail → FAIL LOUD (return 1), never a world-readable
# fallback. The caller then passes <out_file> as --source-file to Python.
bridge_auth_codex_read_source_auth() {
  local source_agent="$1"
  local out_file="$2"
  local user_home=""
  local src_path=""
  local os_user=""
  user_home="$(bridge_auth_resolved_user_home_for_agent "$source_agent" 2>/dev/null || true)"
  [[ -n "$user_home" ]] || {
    printf '[error] codex source: cannot resolve home for %s\n' "$source_agent" >&2
    return 1
  }
  src_path="$user_home/$(bridge_auth_engine_cred_file_tail "$source_agent" "$BRIDGE_AUTH_CODEX_ENGINE")"
  # codex r1 BLOCKING: an ISO source must be read STRICTLY owner-mediated.
  # The earlier draft did a controller direct `cat` FIRST, which would
  # succeed on a world-readable / controller-readable iso source and thereby
  # bypass the intended `sudo -n -u <owner> cat` boundary (and silently
  # accept a wrongly-permissive source). Branch on isolation up front:
  #   - ISO source  → ONLY `sudo -n -u <owner> cat`; if that fails, FAIL LOUD.
  #   - shared mode → controller direct `cat` (same UID; no boundary to cross).
  if bridge_agent_linux_user_isolation_effective "$source_agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$source_agent" 2>/dev/null || true)"
    [[ -n "$os_user" ]] || {
      printf '[error] codex source: cannot resolve iso os_user for %s\n' "$source_agent" >&2
      return 1
    }
    # SC2024 is INTENTIONAL: only the `cat` READ needs the iso UID's
    # privilege; the `>"$out_file"` redirect stays as the CONTROLLER so the
    # snapshot lands in the controller-owned 0600 tempfile (the documented
    # body-file pattern). A `sudo … | tee` would run tee as the controller
    # anyway, with no security gain.
    # shellcheck disable=SC2024  # redirect-as-controller into the 0600 tempfile is the intended ownership
    if sudo -n -u "$os_user" cat "$src_path" >"$out_file" 2>/dev/null && [[ -s "$out_file" ]]; then
      chmod 0600 "$out_file" 2>/dev/null || true
      return 0
    fi
    # FAIL LOUD — no insecure fallback (§6.3). Never a world-readable copy.
    : >"$out_file" 2>/dev/null || true   # ensure no partial/secret bytes linger
    printf '[error] codex source: iso source %s for %s unreadable via sudo -n -u %s cat — fail loud, no fallback\n' \
      "$src_path" "$source_agent" "$os_user" >&2
    return 1
  fi
  # Shared-mode source: controller and agent are the same UID — a direct
  # read crosses no boundary. chmod 0600 on the controller-owned tempfile.
  if cat "$src_path" >"$out_file" 2>/dev/null && [[ -s "$out_file" ]]; then
    chmod 0600 "$out_file" 2>/dev/null || true
    return 0
  fi
  : >"$out_file" 2>/dev/null || true
  printf '[error] codex source: cannot read shared-mode source %s for %s\n' \
    "$src_path" "$source_agent" >&2
  return 1
}

# bridge_auth_codex_selected_agents <spec>
#
# Codex fleet selector (mirrors bridge_auth_selected_agents but filters to
# the Codex engine). `static` → static Codex agents; `all`/`codex` → every
# Codex agent; csv → explicit Codex agents. The configured source is
# included only if explicitly named — by default the source is NOT a sync
# DESTINATION (it is the source of truth; re-writing it would clobber the
# operator's live login). The caller (sync driver) excludes the source.
bridge_auth_codex_selected_agents() {
  local spec="${1:-static}"
  local agent=""
  local item=""
  local -a explicit=()
  local engine="$BRIDGE_AUTH_CODEX_ENGINE"
  case "$spec" in
    static|"")
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
        [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    all|codex)
      for agent in "${BRIDGE_AGENT_IDS[@]}"; do
        [[ "$(bridge_agent_engine "$agent")" == "$engine" ]] || continue
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
        [[ "$(bridge_agent_engine "$item")" == "$engine" ]] || {
          printf '[error] agent is not a Codex agent: %s\n' "$item" >&2
          return 1
        }
        printf '%s\n' "$item"
      done
      ;;
  esac
}

# bridge_auth_codex_sync_one <source_file> <dest_agent>
#
# Write-through the already-read source auth bytes (<source_file>) into one
# Codex dest agent's `.codex/auth.json`, resolving the dest's iso owner so
# Python chowns-before-replace at 0600. Prints the inner JSON on stdout.
bridge_auth_codex_sync_one() {
  local source_file="$1"
  local dest_agent="$2"
  local dest_home=""
  local dest_file=""
  local os_user=""
  local owner_uid=""
  local owner_gid=""
  local -a owner_args=()

  dest_home="$(bridge_auth_resolved_user_home_for_agent "$dest_agent" 2>/dev/null || true)"
  [[ -n "$dest_home" ]] || {
    printf '[error] codex dest: cannot resolve home for %s\n' "$dest_agent" >&2
    return 1
  }
  dest_file="$dest_home/$(bridge_auth_engine_cred_file_tail "$dest_agent" "$BRIDGE_AUTH_CODEX_ENGINE")"

  if bridge_agent_linux_user_isolation_effective "$dest_agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$dest_agent" 2>/dev/null || true)"
    if [[ -n "$os_user" ]]; then
      owner_uid="$(id -u "$os_user" 2>/dev/null || true)"
      owner_gid="$(id -g "$os_user" 2>/dev/null || true)"
      [[ -n "$owner_uid" ]] && owner_args+=(--owner-uid "$owner_uid")
      [[ -n "$owner_gid" ]] && owner_args+=(--owner-gid "$owner_gid")
    fi
    # The iso dest's .codex dir must exist + be owned by the iso UID before
    # the privileged write. Reuse the prepare-dir contract; Python's
    # chown-before-replace lands the file owner-correct.
    bridge_linux_sudo_root mkdir -p "$(dirname "$dest_file")" 2>/dev/null || true
    # codex r1 BLOCKING: pass --allowed-root so Python's _ensure_claude_dir_safe
    # rejects a symlinked PARENT (.codex) that would redirect the privileged
    # write out of the agent home (the final-name symlink check alone is not
    # enough — the atomic writer replaces THROUGH the parent dir).
    bridge_linux_sudo_root python3 "$SCRIPT_DIR/bridge-auth.py" \
      --registry "$(bridge_auth_registry_path)" codex-sync \
      --agent "$dest_agent" --source-file "$source_file" --file "$dest_file" \
      --engine "$BRIDGE_AUTH_CODEX_ENGINE" "${owner_args[@]}" \
      --allowed-root "$dest_home" --json
    return $?
  fi
  # Non-isolated: caller UID already owns the dest home. Still pass
  # --allowed-root so the symlinked-parent reject applies on dev installs too.
  mkdir -p "$(dirname "$dest_file")" 2>/dev/null || true
  python3 "$SCRIPT_DIR/bridge-auth.py" \
    --registry "$(bridge_auth_registry_path)" codex-sync \
    --agent "$dest_agent" --source-file "$source_file" --file "$dest_file" \
    --engine "$BRIDGE_AUTH_CODEX_ENGINE" --allowed-root "$dest_home" --json
}

# bridge_auth_codex_sync_agents <spec> <json_mode>
#
# Drive the full Codex fleet sync: resolve + validate the source, read its
# auth.json (iso-aware), then write-through to every selected Codex agent
# EXCEPT the source itself. The source bytes live ONLY in a controller-
# owned 0600 tempfile, removed on exit.
bridge_auth_codex_sync_agents() {
  local spec="${1:-static}"
  local json_mode="${2:-0}"
  local source_agent=""
  local source_file=""
  local selection=""
  local rc=0
  local -a agents=()
  local -a synced=()
  local -a unchanged=()
  local -a failed=()

  source_agent="$(bridge_auth_codex_source_binding)"
  if [[ -z "$source_agent" ]]; then
    if [[ "$json_mode" == "1" ]]; then
      printf '%s\n' '{"status":"skipped","reason":"no_codex_source_configured","synced":[],"failed":[]}'
    else
      printf 'skipped: no codex source configured (run: agent-bridge auth codex-cred register --source <agent>)\n' >&2
    fi
    return 0
  fi
  if ! bridge_auth_codex_validate_source "$source_agent"; then
    if [[ "$json_mode" == "1" ]]; then
      printf '{"status":"failed","reason":"source_invalid","source_agent":"%s","synced":[],"failed":[]}\n' "$source_agent"
    fi
    return 1
  fi

  # codex r1 BLOCKING: the source tempfile carries the live subscription
  # secret. The earlier draft fell back to a PREDICTABLE
  # `/tmp/agb-codex-src.$$.$RANDOM` path on mktemp failure and chmod'd
  # AFTER (a window where another process could pre-create/symlink it). Now:
  #   - mktemp is the ONLY creator (no predictable fallback); a mktemp
  #     failure FAILS LOUD before any secret is read.
  #   - the create happens under a 0600 umask so the file is never even
  #     momentarily group/world-readable, and we re-chmod 0600 defensively.
  local _prev_umask
  _prev_umask="$(umask)"
  umask 0077
  source_file="$(mktemp "${TMPDIR:-/tmp}/agb-codex-src.XXXXXX" 2>/dev/null || true)"
  umask "$_prev_umask"
  if [[ -z "$source_file" || ! -f "$source_file" ]]; then
    if [[ "$json_mode" == "1" ]]; then
      printf '{"status":"failed","reason":"tempfile_failed","source_agent":"%s","synced":[],"failed":[]}\n' "$source_agent"
    else
      printf '[error] codex sync: cannot create a private source tempfile (mktemp failed)\n' >&2
    fi
    return 1
  fi
  chmod 0600 "$source_file" 2>/dev/null || true
  # shellcheck disable=SC2064  # expand source_file now for the trap
  trap "rm -f '$source_file' 2>/dev/null || true" RETURN
  if ! bridge_auth_codex_read_source_auth "$source_agent" "$source_file"; then
    if [[ "$json_mode" == "1" ]]; then
      printf '{"status":"failed","reason":"source_unreadable","source_agent":"%s","synced":[],"failed":[]}\n' "$source_agent"
    fi
    return 1
  fi

  if ! selection="$(bridge_auth_codex_selected_agents "$spec" 2>/dev/null)"; then
    return 1
  fi
  [[ -n "$selection" ]] && mapfile -t agents <<<"$selection"

  local agent="" out=""
  for agent in "${agents[@]}"; do
    # Never re-write the source itself (it is the source of truth).
    [[ "$agent" == "$source_agent" ]] && continue
    if out="$(bridge_auth_codex_sync_one "$source_file" "$agent" 2>/dev/null)"; then
      case "$out" in
        *'"status": "unchanged"'*|*'"status":"unchanged"'*) unchanged+=("$agent") ;;
        *) synced+=("$agent") ;;
      esac
      [[ "$json_mode" == "1" ]] || printf 'codex synced: %s\n' "$agent"
    else
      failed+=("$agent")
      rc=1
      [[ "$json_mode" == "1" ]] || printf 'codex FAILED: %s\n' "$agent" >&2
    fi
  done

  if [[ "$json_mode" == "1" ]]; then
    python3 "$SCRIPT_DIR/lib/upgrade-helpers/codex-sync-summary.py" \
      "$source_agent" "$rc" \
      "synced:${synced[*]:-}" "unchanged:${unchanged[*]:-}" "failed:${failed[*]:-}"
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
      receive)
        # #1367 sealed-paste. `--help`/`-h` must print usage with rc=0 so
        # the universal CLI-help gate (#1117) passes. The token-accepting
        # form reads echo-off from the controlling tty INSIDE the Python
        # process, so we `exec` (inherit the terminal) — never capture its
        # stdin/stdout. The token-free `--request` form is also exec'd; it
        # reads no token.
        for arg in "$@"; do
          case "$arg" in
            -h|--help|help)
              usage
              exit 0
              ;;
          esac
        done
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" receive "$@"
        ;;
      list|auto-rotate|check|recover-due|classify-output|mark-quota)
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" "$subcommand" "$@"
        ;;
      sync)
        json_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        bridge_auth_sync_agents "$registry" "$agents_spec" "$json_mode"
        ;;
      backfill-settings)
        # Issue #1855: create-if-absent keychain-free apiKeyHelper backfill for
        # pre-#1520 shared Claude agents. Default scope mirrors `sync`'s
        # static-only default so the daemon/upgrade roster loop only touches
        # static agents unless an explicit --agents CSV is given.
        json_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        bridge_auth_backfill_settings_agents "$agents_spec" "$json_mode"
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
  codex-cred)
    # Fleet-credential Phase 2 (#1470): the Codex register-once → fleet-sync
    # adapter. register/sync/verify/source only — Codex has no rotation.
    subcommand="${1:-}"
    [[ -n "$subcommand" ]] || {
      usage
      exit 1
    }
    shift || true
    registry="$(bridge_auth_registry_path)"
    case "$subcommand" in
      register)
        # Resolve + validate the requested source BEFORE persisting it (Q1).
        source_arg=""
        while [[ $# -gt 0 ]]; do
          case "$1" in
            --source)
              [[ $# -ge 2 ]] || {
                printf '[error] --source requires a value\n' >&2
                exit 1
              }
              source_arg="$2"
              shift 2
              ;;
            *) shift ;;
          esac
        done
        [[ -n "$source_arg" ]] || {
          printf '[error] codex-cred register requires --source <agent>\n' >&2
          exit 1
        }
        bridge_auth_codex_validate_source "$source_arg" || exit 1
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" \
          codex-register --source "$source_arg" "$@"
        ;;
      source)
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" codex-source "$@"
        ;;
      verify)
        exec python3 "$SCRIPT_DIR/bridge-auth.py" --registry "$registry" codex-verify "$@"
        ;;
      sync)
        json_mode=0
        bridge_auth_json_requested "$@" && json_mode=1
        agents_spec="$(bridge_auth_agents_arg "$@")"
        bridge_auth_codex_sync_agents "$agents_spec" "$json_mode"
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
