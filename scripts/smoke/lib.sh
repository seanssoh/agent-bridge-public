#!/usr/bin/env bash
# shellcheck shell=bash

SMOKE_LIB_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
SMOKE_REPO_ROOT="$(cd -P "$SMOKE_LIB_DIR/../.." && pwd -P)"
SMOKE_NAME="${SMOKE_NAME:-$(basename "$0" .sh)}"
SMOKE_TMP_ROOT="${SMOKE_TMP_ROOT:-}"

smoke_log() {
  printf '[smoke:%s] %s\n' "$SMOKE_NAME" "$*"
}

smoke_fail() {
  printf '[smoke:%s][error] %s\n' "$SMOKE_NAME" "$*" >&2
  exit 1
}

smoke_require_cmd() {
  local cmd="$1"
  command -v "$cmd" >/dev/null 2>&1 || smoke_fail "missing required command: $cmd"
}

smoke_make_temp_root() {
  local label="${1:-$SMOKE_NAME}"
  SMOKE_TMP_ROOT="$(mktemp -d "${TMPDIR:-/tmp}/agent-bridge-${label}.XXXXXX")"
  SMOKE_TMP_ROOT="$(cd -P "$SMOKE_TMP_ROOT" && pwd -P)"
  export SMOKE_TMP_ROOT
}

smoke_setup_bridge_home() {
  local label="${1:-$SMOKE_NAME}"
  smoke_make_temp_root "$label"

  # Narrowly drop leak-prone vars this helper re-pins, so an inherited value
  # from the operator's shell (e.g. BRIDGE_LAYOUT_MARKER_DIR or the cron state
  # vars) can never survive into the isolated run. A blanket `unset BRIDGE_*`
  # would clobber bridge vars some smoke callers intentionally pass in.
  unset BRIDGE_LAYOUT_MARKER_DIR \
    BRIDGE_CRON_STATE_DIR \
    BRIDGE_CRON_HOME_DIR \
    BRIDGE_NATIVE_CRON_JOBS_FILE \
    BRIDGE_CRON_DISPATCH_WORKER_DIR \
    BRIDGE_SOURCE_CRON_JOBS_FILE \
    BRIDGE_OPENCLAW_CRON_JOBS_FILE \
    BRIDGE_CLAUDE_PLUGINS_ROOT \
    BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT

  export BRIDGE_HOME="$SMOKE_TMP_ROOT/bridge-home"
  export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
  export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
  export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
  export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
  export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
  export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
  export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
  export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
  export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
  export BRIDGE_LAYOUT="v2"
  export BRIDGE_DATA_ROOT="$SMOKE_TMP_ROOT/data"
  export BRIDGE_SHARED_ROOT="$BRIDGE_DATA_ROOT/shared"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_DATA_ROOT/agents"
  export BRIDGE_CONTROLLER_STATE_ROOT="$BRIDGE_DATA_ROOT/state"
  export BRIDGE_RUNTIME_ROOT="$BRIDGE_HOME/runtime"
  export BRIDGE_RUNTIME_CONFIG_FILE="$BRIDGE_RUNTIME_ROOT/bridge-config.json"
  export BRIDGE_HOOKS_DIR="$BRIDGE_HOME/hooks"
  export BRIDGE_AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
  # Pin the layout marker dir + cron state vars under the isolated root, so an
  # isolated daemon's cron-inventory tick / layout resolver never falls back to
  # the operator's live bridge home. Defaults mirror bridge-lib.sh.
  export BRIDGE_LAYOUT_MARKER_DIR="$BRIDGE_STATE_DIR"
  export BRIDGE_CRON_STATE_DIR="$BRIDGE_STATE_DIR/cron"
  export BRIDGE_CRON_HOME_DIR="$BRIDGE_HOME/cron"
  export BRIDGE_NATIVE_CRON_JOBS_FILE="$BRIDGE_CRON_HOME_DIR/jobs.json"
  export BRIDGE_CRON_DISPATCH_WORKER_DIR="$BRIDGE_CRON_STATE_DIR/workers"
  # Legacy/source cron jobs path family — bridge_cron_source_jobs_file()
  # falls back to BRIDGE_SOURCE_CRON_JOBS_FILE when the native jobs file is
  # absent, so an inherited live value must not survive. Pin both under the
  # isolated root (BRIDGE_OPENCLAW_CRON_JOBS_FILE is the same path family).
  export BRIDGE_SOURCE_CRON_JOBS_FILE="$BRIDGE_CRON_HOME_DIR/legacy-jobs.json"
  export BRIDGE_OPENCLAW_CRON_JOBS_FILE="$BRIDGE_SOURCE_CRON_JOBS_FILE"
  # Issue #1857 — pin the Claude plugin catalog roots under the isolated
  # root so a smoke/repro that exercises plugin wiring
  # (bridge-dev-plugin-cache.py sync, `claude plugin marketplace add`, or any
  # known_marketplaces.json / installed_plugins.json writer) can NEVER leak a
  # fixture marketplace into the operator's live `~/.claude/plugins` catalog.
  # bridge-dev-plugin-cache.py resolves both roots from these env vars and
  # only falls back to `~/.claude/plugins` when they are unset, so an
  # inherited live value (or the default HOME-relative path) must be
  # overridden here — the live-state-leak class behind #1857's polluted
  # known_marketplaces.json (`repro-mkt` → /private/tmp fixture).
  export BRIDGE_CLAUDE_PLUGINS_ROOT="$BRIDGE_HOME/claude-plugins"
  export BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT="$BRIDGE_CLAUDE_PLUGINS_ROOT/cache"

  mkdir -p \
    "$BRIDGE_HOME" \
    "$BRIDGE_STATE_DIR" \
    "$BRIDGE_LOG_DIR" \
    "$BRIDGE_SHARED_DIR" \
    "$BRIDGE_ACTIVE_AGENT_DIR" \
    "$BRIDGE_HISTORY_DIR" \
    "$BRIDGE_AGENT_HOME_ROOT" \
    "$BRIDGE_SHARED_ROOT" \
    "$BRIDGE_AGENT_ROOT_V2" \
    "$BRIDGE_CONTROLLER_STATE_ROOT" \
    "$BRIDGE_RUNTIME_ROOT" \
    "$BRIDGE_HOOKS_DIR" \
    "$BRIDGE_CRON_STATE_DIR" \
    "$BRIDGE_CRON_HOME_DIR" \
    "$BRIDGE_CRON_DISPATCH_WORKER_DIR" \
    "$BRIDGE_CLAUDE_PLUGIN_CACHE_ROOT"
  : >"$BRIDGE_ROSTER_FILE"
  : >"$BRIDGE_ROSTER_LOCAL_FILE"
  cat >"$BRIDGE_STATE_DIR/layout-marker.sh" <<EOF
BRIDGE_LAYOUT=v2
BRIDGE_DATA_ROOT=$BRIDGE_DATA_ROOT
EOF
  chmod 0644 "$BRIDGE_STATE_DIR/layout-marker.sh"
}

smoke_cleanup_temp_root() {
  local root="${SMOKE_TMP_ROOT:-}"
  if [[ -n "$root" && -d "$root" ]]; then
    rm -rf "$root" >/dev/null 2>&1 || true
  fi
}

# Issue #1860 defence-in-depth. A smoke that writes a stand-in daemon (or any
# other runtime) script must never let the target resolve to the operator's
# live install or the source checkout — a path-resolution regression once
# overwrote the live ~/.agent-bridge/bridge-daemon.sh with a `sleep 60` stub,
# silently killing the production daemon for ~4h. This guard asserts the write
# target sits under the smoke's own temp root ($SMOKE_TMP_ROOT) or the isolated
# $BRIDGE_HOME before any write, and aborts loudly otherwise.
#
# Usage: smoke_assert_path_in_temp "<target-path>" "<context>"
smoke_assert_path_in_temp() {
  local path="${1:-}"
  local context="${2:-runtime-script write}"
  [[ -n "$path" ]] || smoke_fail "$context: refusing to write to an empty path"

  # Resolve the parent dir (the file itself may not exist yet) so symlinked
  # temp roots (/var/folders -> /private/var/folders on macOS) compare by
  # their real path, matching how SMOKE_TMP_ROOT/BRIDGE_HOME are pinned.
  local dir base resolved_dir
  dir="$(dirname -- "$path")"
  base="$(basename -- "$path")"
  resolved_dir="$(cd -P -- "$dir" 2>/dev/null && pwd -P)" || \
    smoke_fail "$context: cannot resolve parent dir of write target: $path"
  local resolved="$resolved_dir/$base"

  local allowed="" candidate
  for candidate in "${SMOKE_TMP_ROOT:-}" "${BRIDGE_HOME:-}"; do
    [[ -n "$candidate" ]] || continue
    candidate="$(cd -P -- "$candidate" 2>/dev/null && pwd -P)" || continue
    case "$resolved" in
      "$candidate"|"$candidate"/*)
        allowed="$candidate"
        break
        ;;
    esac
  done
  [[ -n "$allowed" ]] || smoke_fail \
    "$context: refusing to write runtime script outside the smoke temp root (target=$resolved; allowed under SMOKE_TMP_ROOT=${SMOKE_TMP_ROOT:-<unset>} or BRIDGE_HOME=${BRIDGE_HOME:-<unset>}). This is the #1860 live-install guard."
}

# Write a stand-in/stub runtime script to <target> with <content>, but only
# after smoke_assert_path_in_temp confirms the target is temp-rooted. Marks it
# executable. Use this instead of a raw `printf ... >"$daemon"` whenever the
# target filename is `bridge-daemon.sh` (or any other live runtime script) so a
# future path-resolution regression fails loud instead of nuking the live
# install (#1860).
smoke_write_runtime_stub() {
  local target="${1:-}"
  local content="${2:-}"
  smoke_assert_path_in_temp "$target" "runtime-stub write"
  printf '%s' "$content" >"$target"
  chmod +x "$target"
}

# Issue #1738 r2: install the match-time-liveness tmux stub for config-caller
# binding smokes. bridge-config.py re-resolves the live `#{pane_pid}` of a
# matched binding's session via an ABSOLUTE tmux (BRIDGE_CONFIG_TMUX_BIN may
# point at a stub) and requires it to equal the bound pane_pid. With no real
# tmux server, this stub answers `display-message -t <SMOKE_LIVE_SESSION> -p
# '#{pane_pid}'` with $SMOKE_LIVE_PANE_PID and exits 1 for any other session.
# Exports SMOKE_LIVE_SESSION (use as the binding's `session`) + SMOKE_LIVE_PANE_PID
# (default $$, the smoke shell = the bound pane_pid's ancestor). Idempotent.
smoke_install_config_caller_tmux_stub() {
  export SMOKE_LIVE_SESSION="${SMOKE_LIVE_SESSION:-sess-live}"
  export SMOKE_LIVE_PANE_PID="${SMOKE_LIVE_PANE_PID:-$$}"
  local stub="$SMOKE_TMP_ROOT/config-caller-fake-tmux"
  smoke_assert_path_in_temp "$stub" "config-caller tmux stub"
  {
    printf '%s\n' '#!/usr/bin/env bash'
    printf '%s\n' 'want_session=""'
    printf '%s\n' 'while [[ $# -gt 0 ]]; do'
    printf '%s\n' '  case "$1" in'
    printf '%s\n' '    -t) want_session="$2"; shift 2 ;;'
    printf '%s\n' '    *) shift ;;'
    printf '%s\n' '  esac'
    printf '%s\n' 'done'
    printf '%s\n' 'if [[ "$want_session" == "'"$SMOKE_LIVE_SESSION"'" && -n "${SMOKE_LIVE_PANE_PID:-}" ]]; then'
    printf '%s\n' '  printf "%s\\n" "$SMOKE_LIVE_PANE_PID"; exit 0'
    printf '%s\n' 'fi'
    printf '%s\n' 'exit 1'
  } >"$stub"
  chmod 0755 "$stub"
  # The override is honored ONLY under the explicit test sentinel; normal
  # operation resolves tmux from fixed absolute paths only (no env hole).
  export BRIDGE_CONFIG_ALLOW_TEST_TMUX="1"
  export BRIDGE_CONFIG_TMUX_BIN="$stub"
}

# Seed a TRUSTED config-caller admin binding for the positive (legit-admin)
# path: live session + a store made non-writable by the caller (the iso,
# controller-owned shape) so Option 1's store-writability gate (#1738 r2) trusts
# it. $1=bindings dir, $2=agent, $3=admin (default = agent). Requires
# smoke_install_config_caller_tmux_stub to have run.
smoke_seed_trusted_admin_binding() {
  local dir="$1" agent="$2" admin="${3:-$2}"
  mkdir -p "$dir"
  chmod 0755 "$dir" 2>/dev/null || true
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":%s,"engine":"claude","updated_at":"now"}\n' \
    "$agent" "$admin" "${SMOKE_LIVE_SESSION:-sess-live}" "${SMOKE_LIVE_PANE_PID:-$$}" \
    >"$dir/$agent.json"
  # Drop the caller's write bit on the dir + record so os.access(W_OK) is False
  # for the owner (just as an iso agent UID cannot write the controller store).
  chmod 0444 "$dir/$agent.json" 2>/dev/null || true
  chmod 0555 "$dir" 2>/dev/null || true
}

# Restore a config-caller bindings dir to writable + empty (undo
# smoke_seed_trusted_admin_binding's chmods so the next seed/rm is unobstructed).
smoke_clear_config_caller_bindings() {
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  chmod 0755 "$dir" 2>/dev/null || true
  chmod 0644 "$dir"/*.json 2>/dev/null || true
  rm -f "$dir"/*.json 2>/dev/null || true
}

smoke_assert_eq() {
  local expected="$1"
  local actual="$2"
  local context="$3"
  [[ "$actual" == "$expected" ]] || smoke_fail "$context: expected '$expected', got '$actual'"
}

smoke_assert_match() {
  local actual="$1"
  local regex="$2"
  local context="$3"
  [[ "$actual" =~ $regex ]] || smoke_fail "$context: expected match /$regex/, got '$actual'"
}

smoke_assert_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  [[ "$haystack" == *"$needle"* ]] || smoke_fail "$context: expected output to contain '$needle', got: $haystack"
}

smoke_assert_not_contains() {
  local haystack="$1"
  local needle="$2"
  local context="$3"
  [[ "$haystack" != *"$needle"* ]] || smoke_fail "$context: expected output not to contain '$needle', got: $haystack"
}

smoke_assert_file_exists() {
  local path="$1"
  local context="$2"
  [[ -f "$path" ]] || smoke_fail "$context: expected file to exist: $path"
}

smoke_shell_field() {
  local key="$1"
  local payload="$2"
  printf '%s\n' "$payload" | sed -n "s/^${key}=//p" | head -n 1 | sed "s/^'//; s/'$//"
}

smoke_run() {
  local label="$1"
  shift
  smoke_log "setup/act/assert: $label"
  "$@"
  smoke_log "ok: $label"
}

smoke_skip() {
  local label="$1"
  local reason="$2"
  smoke_log "skip: $label ($reason)"
}

smoke_is_linux() {
  [[ "$(uname -s 2>/dev/null || printf 'unknown')" == "Linux" ]]
}
