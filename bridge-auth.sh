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
  bash $SCRIPT_DIR/bridge-auth.sh claude-token classify-output [--stdout-file <path>] [--stderr-file <path>] [--returncode <n>]
  bash $SCRIPT_DIR/bridge-auth.sh claude-token mark-quota <id> [--reset-at <iso>] [--retry-seconds <sec>] [--json]
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
      list|auto-rotate|check|recover-due|classify-output|mark-quota)
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
