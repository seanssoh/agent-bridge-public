#!/usr/bin/env bash
# bridge-usage.sh — inspect and monitor Claude/Codex usage windows
#
# Issue #831: status/monitor must read each Claude agent's *own* usage cache
# (under that agent's home), not just the controller's $HOME, so the daemon
# can detect a rotation-worthy usage cliff on an isolated agent. The `--agents`
# flag mirrors the `bridge-auth.sh claude-token sync` convention.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=/dev/null
source "$SCRIPT_DIR/bridge-lib.sh"
bridge_load_roster
bridge_require_python

usage() {
  cat <<EOF
Usage:
  bash $SCRIPT_DIR/bridge-usage.sh <status|monitor|alerts> [options...]

  status/monitor accept --agents <static|all|csv> to scope per-agent cache
  collection (default: static — same convention as bridge-auth.sh).
EOF
}

command="${1:-}"
[[ -n "$command" ]] || {
  usage
  exit 1
}
shift || true

# Default cache path (controller / single-tenant). Per-agent collection below
# overrides this with the agent-specific path when --agents is in effect.
claude_usage_cache="${BRIDGE_CLAUDE_USAGE_CACHE:-$HOME/.claude/plugins/claude-hud/.usage-cache.json}"
codex_sessions_dir="${BRIDGE_CODEX_SESSIONS_DIR:-$HOME/.codex/sessions}"
usage_state_file="${BRIDGE_USAGE_MONITOR_STATE_FILE:-$BRIDGE_STATE_DIR/usage/monitor-state.json}"
rotation_threshold="${BRIDGE_CLAUDE_TOKEN_ROTATION_PERCENT:-99}"
claude_token_registry="${BRIDGE_CLAUDE_TOKEN_REGISTRY:-$BRIDGE_RUNTIME_SECRETS_DIR/claude-oauth-tokens.json}"

if [[ -f "$claude_token_registry" ]]; then
  registry_rotation_threshold="$(python3 - "$claude_token_registry" <<'PY' 2>/dev/null || true
import json
import sys
from pathlib import Path

try:
    payload = json.loads(Path(sys.argv[1]).read_text(encoding="utf-8"))
    value = float(payload.get("rotation_threshold") or 0)
except Exception:
    value = 0
if 0 < value <= 100:
    print(value)
PY
)"
  if [[ "$registry_rotation_threshold" =~ ^[0-9]+([.][0-9]+)?$ ]]; then
    rotation_threshold="$registry_rotation_threshold"
  fi
fi

# bridge_usage_select_claude_agents <spec>
#   spec ∈ {static, all, claude, <csv>}; default `static`. Prints one Claude
#   agent id per line (filters out non-Claude engines). Mirrors
#   bridge_auth_selected_agents in bridge-auth.sh so a single operator-facing
#   `--agents` contract covers sync + monitor.
bridge_usage_select_claude_agents() {
  local spec="${1:-static}"
  local agent="" item=""
  local -a explicit=()

  case "$spec" in
    static|"")
      for agent in "${BRIDGE_AGENT_IDS[@]:-}"; do
        [[ -n "$agent" ]] || continue
        [[ "$(bridge_agent_engine "$agent")" == "claude" ]] || continue
        [[ "$(bridge_agent_source "$agent")" == "static" ]] || continue
        printf '%s\n' "$agent"
      done
      ;;
    all|claude)
      for agent in "${BRIDGE_AGENT_IDS[@]:-}"; do
        [[ -n "$agent" ]] || continue
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

# bridge_usage_resolve_claude_cache_path <agent>
#   Stdout: absolute path the agent's claude-hud usage cache would live at.
#   Isolated agents (linux-user mode) → under $BRIDGE_LINUX_ISOLATED_USER_HOME_ROOT/<os_user>.
#   Non-isolated agents → controller's $HOME (the existing single-tenant path).
bridge_usage_resolve_claude_cache_path() {
  local agent="$1"
  local os_user="" agent_home=""

  if bridge_agent_linux_user_isolation_effective "$agent" 2>/dev/null; then
    os_user="$(bridge_agent_os_user "$agent" 2>/dev/null || printf '')"
    if [[ -n "$os_user" ]]; then
      agent_home="$(bridge_agent_linux_user_home "$os_user")"
      printf '%s/.claude/plugins/claude-hud/.usage-cache.json' "$agent_home"
      return 0
    fi
  fi

  printf '%s/.claude/plugins/claude-hud/.usage-cache.json' "$HOME"
}

# bridge_usage_read_claude_cache_for_agent <agent> <path>
#   Stdout: cache file contents (JSON), empty when unreadable / absent.
#   Returns 0 always — missing cache is not an error, it just means that agent
#   contributes no Claude snapshot this tick (per brief U3).
#
# set-e safety: every helper invocation uses `cmd || rc=$?` capture, mirroring
# the pattern in lib/bridge-agents.sh:bridge_channel_env_file_readiness that
# avoided the PR #836 set-e abort.
bridge_usage_read_claude_cache_for_agent() {
  local agent="$1"
  local path="$2"
  local sudo_rc=0 probe_rc=0
  local probe_script=''

  if [[ -z "$agent" || -z "$path" ]]; then
    return 0
  fi

  # Controller-direct path: non-isolated agent, or we can read the file from
  # the controller's UID. The latter handles the common case where the agent's
  # home is on a shared filesystem with permissive perms (most CI setups).
  if [[ -r "$path" ]]; then
    cat "$path" 2>/dev/null || true
    return 0
  fi

  if ! declare -F bridge_isolation_can_sudo_to_agent >/dev/null 2>&1; then
    return 0
  fi

  sudo_rc=0
  bridge_isolation_can_sudo_to_agent "$agent" 2>/dev/null || sudo_rc=$?
  case "$sudo_rc" in
    0)
      # Isolated and sudo works — read via the isolated UID. Self-contained
      # inline script; does NOT source bridge-lib.sh under the isolated UID
      # (sudoers allowlist is `bash` + `tmux` only).
      probe_script='
file="$1"
[[ -r "$file" ]] || exit 2
cat "$file"
'
      probe_rc=0
      bridge_isolation_run_as_agent_user_via_bash "$agent" "$probe_script" "$path" 2>/dev/null || probe_rc=$?
      if [[ "$probe_rc" -eq 0 ]]; then
        return 0
      fi
      # rc=3 (script exited 1) or rc=4 (script exited 2 — file unreadable to
      # isolated UID) → contribute empty payload for this agent (skip cleanly).
      return 0
      ;;
    2)
      # Isolated agent but no passwordless sudo — degrade silently per brief
      # U4 ("that agent is skipped with a warn-log line; other agents
      # continue"). The warn line lands on the daemon's stderr; the daemon
      # already routes 2>/dev/null on the wrapper invocation, but during ad-hoc
      # `bridge-usage.sh status --agents all` the operator sees it.
      printf '[bridge-usage] skip agent=%s reason=no-passwordless-sudo\n' "$agent" >&2
      return 0
      ;;
    *)
      # rc=1 — not isolated at all. Fall back to controller-direct read.
      cat "$path" 2>/dev/null || true
      return 0
      ;;
  esac
}

# bridge_usage_build_per_agent_payload <agents-newline-stream>
#   Reads agent ids from stdin (one per line), resolves each agent's cache
#   path, reads it (with isolation-aware sudo when needed), and emits a single
#   JSON array of {agent, path, present, payload} entries. Returns the
#   tempfile path on stdout. The tempfile is mode 0600.
bridge_usage_build_per_agent_payload() {
  # Issue #831 r2 (review #2104 finding 2): per-agent cache contents must NOT
  # transit through the python3 argv. Argv is process-table-visible, has
  # ARG_MAX limits that the prior triplet encoding could hit on a large agent
  # roster, and crosses the isolation boundary that the 0600 tempfile was
  # supposed to enforce. Instead, write rows to a separate 0600 intermediate
  # file (`rows_tmp`) using a TAB-delimited <agent><TAB><path><TAB><b64-content>
  # framing, then pass ONLY the two file paths via argv. Python streams the
  # rows file and emits the final JSON array into the output tempfile.
  local tmp="" rows_tmp="" agent="" path="" content=""
  tmp="$(mktemp)"
  rows_tmp="$(mktemp)"
  chmod 600 "$tmp" "$rows_tmp"

  while IFS= read -r agent; do
    [[ -n "$agent" ]] || continue
    path="$(bridge_usage_resolve_claude_cache_path "$agent")"
    content="$(bridge_usage_read_claude_cache_for_agent "$agent" "$path")"
    # Line per agent: <agent><TAB><path><TAB><base64-content>. base64 keeps
    # the encoded value newline-free (tr -d '\n'), so a literal newline
    # terminates the row safely.
    printf '%s\t%s\t%s\n' "$agent" "$path" "$(printf '%s' "$content" | base64 | tr -d '\n')" >>"$rows_tmp"
  done

  python3 - "$tmp" "$rows_tmp" <<'PY'
import base64
import json
import sys
from pathlib import Path

out_path = Path(sys.argv[1])
rows_path = Path(sys.argv[2])
entries = []

with rows_path.open("r", encoding="utf-8") as fh:
    for line in fh:
        line = line.rstrip("\n")
        if not line:
            continue
        parts = line.split("\t", 2)
        agent = parts[0] if len(parts) > 0 else ""
        path = parts[1] if len(parts) > 1 else ""
        b64 = parts[2] if len(parts) > 2 else ""
        raw = ""
        if b64:
            try:
                raw = base64.b64decode(b64).decode("utf-8", errors="replace")
            except Exception:
                raw = ""
        parsed = None
        present = False
        if raw.strip():
            try:
                parsed = json.loads(raw)
                present = True
            except Exception:
                parsed = None
                present = False
        entries.append({
            "agent": agent,
            "path": path,
            "present": present,
            "payload": parsed,
        })

out_path.write_text(json.dumps(entries, ensure_ascii=True), encoding="utf-8")
PY

  # Clean up the intermediate rows file regardless of python3 exit; the final
  # payload file (`tmp`) is the caller's responsibility (returned via stdout).
  rm -f "$rows_tmp" 2>/dev/null || true

  printf '%s' "$tmp"
}

# ---------------------------------------------------------------------------
# Operator-facing arg parsing: we intercept `--agents <spec>` here (so we can
# collect per-agent caches before exec'ing python3) and pass the rest through
# unchanged. Anything else stays a python-side flag, including the existing
# threshold + state-file flags.
# ---------------------------------------------------------------------------
agents_spec=""
agents_explicit=0
forward_args=()
while [[ $# -gt 0 ]]; do
  case "$1" in
    --agents)
      agents_spec="${2:-}"
      agents_explicit=1
      shift 2
      ;;
    --agents=*)
      agents_spec="${1#--agents=}"
      agents_explicit=1
      shift
      ;;
    *)
      forward_args+=("$1")
      shift
      ;;
  esac
done

per_agent_cache_json=""
legacy_single_path=""
# Cleanup any per-agent tempfile we create.
trap '[[ -n "${per_agent_cache_json:-}" ]] && rm -f -- "$per_agent_cache_json"' EXIT

run_python() {
  local subcmd="$1"
  shift
  local -a base_args=(
    "$subcmd"
    --claude-usage-cache "$claude_usage_cache"
    --codex-sessions-dir "$codex_sessions_dir"
  )
  if [[ "$subcmd" == "monitor" ]]; then
    base_args+=(--state-file "$usage_state_file" --rotation-threshold "$rotation_threshold")
  fi
  if [[ -n "$per_agent_cache_json" ]]; then
    base_args+=(--per-agent-cache-json "$per_agent_cache_json")
  fi
  if [[ -n "$legacy_single_path" ]]; then
    base_args+=(--legacy-single-path "$legacy_single_path")
  fi
  base_args+=("$@")
  python3 "$SCRIPT_DIR/bridge-usage.py" "${base_args[@]}"
}

case "$command" in
  status|monitor)
    if [[ "$agents_explicit" -eq 1 ]]; then
      agent_stream=""
      agent_stream="$(bridge_usage_select_claude_agents "$agents_spec")" || exit 1
      if [[ -n "$agent_stream" ]]; then
        per_agent_cache_json="$(printf '%s\n' "$agent_stream" | bridge_usage_build_per_agent_payload)"
        # Back-compat: preserve the single-controller-cache path so any
        # downstream tooling that ignores the per-agent array still sees the
        # legacy field unchanged.
        legacy_single_path="$claude_usage_cache"
      fi
    fi
    run_python "$command" "${forward_args[@]+"${forward_args[@]}"}"
    rc=$?
    exit "$rc"
    ;;
  alerts)
    exec python3 "$SCRIPT_DIR/bridge-usage.py" alerts \
      --audit-file "$BRIDGE_AUDIT_LOG" \
      "${forward_args[@]+"${forward_args[@]}"}"
    ;;
  -h|--help|help)
    usage
    exit 0
    ;;
  *)
    usage >&2
    exit 1
    ;;
esac
