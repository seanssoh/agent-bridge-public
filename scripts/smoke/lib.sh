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
  # Tear down any private config-caller tmux server (#1738 r3 live-session
  # positive path) before removing the temp root. No-op when none was started.
  if declare -F smoke_config_caller_stop_live_session >/dev/null 2>&1; then
    smoke_config_caller_stop_live_session
  fi
  local root="${SMOKE_TMP_ROOT:-}"
  if [[ -n "$root" && -d "$root" ]]; then
    # A foreign-owned (sudo-chowned) config-caller store would block a plain
    # rm -rf; reclaim ownership best-effort first.
    if [[ "${SMOKE_CONFIG_CALLER_ISO_OK:-0}" == "1" ]] && command -v sudo >/dev/null 2>&1; then
      sudo -n chown -R "$(id -u):$(id -g)" "$root" 2>/dev/null || true
    fi
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

# Issue #1738 r3: config-caller binding smokes drive liveness against a REAL
# tmux session (no env stub — the agent-settable `BRIDGE_CONFIG_TMUX_BIN` /
# `BRIDGE_CONFIG_ALLOW_TEST_TMUX` seam was REMOVED because an agent owns its env
# and could point liveness at a lying stub). The wrapper resolves tmux only from
# fixed absolute paths and re-resolves the LIVE `#{pane_pid}` of the bound
# session, so the smoke must run the wrapper INSIDE a real pane (the pane process
# is then a genuine ancestor of the wrapper, and its pane_pid is the bound one).
#
# smoke_config_caller_start_live_session: start a detached tmux session on a
# PRIVATE socket under the smoke temp root (never the operator's default server).
# Exports SMOKE_LIVE_SESSION, SMOKE_LIVE_PANE_PID (the REAL pane pid), and
# SMOKE_LIVE_TMUX_SOCKET. Registers cleanup via a global var the smoke's EXIT
# trap (smoke_cleanup_temp_root) tears down. Skips with a clear message + sets
# SMOKE_CONFIG_CALLER_LIVE_OK=0 if tmux is unavailable.
SMOKE_CONFIG_CALLER_LIVE_NAME=""
smoke_config_caller_start_live_session() {
  export SMOKE_CONFIG_CALLER_LIVE_OK=0
  local tmux_bin=""
  tmux_bin="$(command -v tmux 2>/dev/null || true)"
  if [[ -z "$tmux_bin" ]]; then
    smoke_log "config-caller: tmux unavailable — live-session positive path skipped"
    return 1
  fi
  # Start the session on the DEFAULT tmux server (no -S), with a unique name. The
  # wrapper (#1738 r3 FIX 2) STRIPS $TMUX/$TMUX_PANE from its liveness probe so it
  # always queries the default server — exactly where the controller publishes in
  # production. A private -S socket would therefore NOT be found by the wrapper.
  # We kill ONLY our own session (never kill-server) so a co-resident operator
  # tmux is untouched.
  local session="agb-cc-live-$$-$RANDOM"
  if ! "$tmux_bin" new-session -d -s "$session" 2>/dev/null; then
    smoke_log "config-caller: tmux new-session (default server) failed — live-session positive path skipped"
    return 1
  fi
  SMOKE_CONFIG_CALLER_LIVE_NAME="$session"
  # Give the pane shell a moment to spawn so #{pane_pid} resolves.
  sleep 0.4
  local pane_pid=""
  pane_pid="$("$tmux_bin" display-message -t "$session" -p '#{pane_pid}' 2>/dev/null || true)"
  if [[ ! "$pane_pid" =~ ^[0-9]+$ ]]; then
    "$tmux_bin" kill-session -t "$session" 2>/dev/null || true
    SMOKE_CONFIG_CALLER_LIVE_NAME=""
    smoke_log "config-caller: could not resolve real pane_pid — live-session positive path skipped"
    return 1
  fi
  export SMOKE_LIVE_SESSION="$session"
  export SMOKE_LIVE_PANE_PID="$pane_pid"
  export SMOKE_CONFIG_CALLER_LIVE_OK=1
  return 0
}

# Tear down ONLY the smoke's own config-caller session (kill-session, never
# kill-server, so a co-resident operator tmux on the default server is left
# alone). Called from the smoke's EXIT cleanup; idempotent and silent.
smoke_config_caller_stop_live_session() {
  local tmux_bin=""
  tmux_bin="$(command -v tmux 2>/dev/null || true)"
  if [[ -n "$tmux_bin" && -n "$SMOKE_CONFIG_CALLER_LIVE_NAME" ]]; then
    "$tmux_bin" kill-session -t "$SMOKE_CONFIG_CALLER_LIVE_NAME" 2>/dev/null || true
  fi
  SMOKE_CONFIG_CALLER_LIVE_NAME=""
}

# Run a config-caller wrapper invocation INSIDE the live tmux pane so the wrapper
# is a genuine descendant of the bound pane process (its pane_pid is in the
# wrapper's ancestry). $1=wrapper-path; remaining args = wrapper argv. The caller
# pre-sets any env it wants visible to the wrapper via the SMOKE_CC_ENV array
# (NAME=VALUE entries) — we export it into the pane before running. rc/out/err
# land in $SMOKE_TMP_ROOT/wrap.{out,err}; rc is echoed. Requires
# smoke_config_caller_start_live_session (SMOKE_CONFIG_CALLER_LIVE_OK=1).
smoke_config_caller_run_in_pane() {
  local wrapper="$1"; shift
  local tmux_bin="" session="$SMOKE_LIVE_SESSION"
  local out="$SMOKE_TMP_ROOT/wrap.out" err="$SMOKE_TMP_ROOT/wrap.err" rcf="$SMOKE_TMP_ROOT/wrap.rc"
  tmux_bin="$(command -v tmux 2>/dev/null || true)"
  rm -f "$out" "$err" "$rcf" 2>/dev/null || true
  if [[ -z "$tmux_bin" || -z "$session" ]]; then
    printf '127' >"$rcf"; printf '127'; return 0
  fi
  # Build an `export` line for any caller-provided env, then the wrapper call.
  local export_line="" pair=""
  if declare -p SMOKE_CC_ENV >/dev/null 2>&1; then
    for pair in "${SMOKE_CC_ENV[@]}"; do
      export_line+="export $(smoke_config_caller_shquote_pair "$pair"); "
    done
  fi
  # quote argv safely (printf %q) so paths with spaces survive send-keys.
  local cmd="$export_line" a=""
  cmd+="python3 $(printf '%q' "$wrapper")"
  for a in "$@"; do
    cmd+=" $(printf '%q' "$a")"
  done
  cmd+=" >$(printf '%q' "$out") 2>$(printf '%q' "$err"); printf '%s' \$? >$(printf '%q' "$rcf")"
  "$tmux_bin" send-keys -t "$session" "$cmd" Enter 2>/dev/null || true
  # Poll for the rc file (the in-pane command writes it last).
  local waited=0
  while [[ ! -s "$rcf" && "$waited" -lt 100 ]]; do
    sleep 0.1
    waited=$((waited + 1))
  done
  local rc=""
  rc="$(cat "$rcf" 2>/dev/null || true)"
  [[ -n "$rc" ]] || rc="124"   # timed out -> distinct non-zero
  printf '%s' "$rc"
}

# Helper: split a NAME=VALUE pair and re-emit it as NAME='value' for the export
# line (single-quote the value, escaping embedded single quotes).
smoke_config_caller_shquote_pair() {
  local pair="$1" name="${1%%=*}" value="${1#*=}"
  value="${value//\'/\'\\\'\'}"
  printf "%s='%s'" "$name" "$value"
}

# Try to make a config-caller bindings store FOREIGN-OWNED (a different uid than
# the caller) so the iso, controller-owned positive path can be exercised: under
# #1738 r3 the writability gate keys on OWNERSHIP, not mode bits, so a
# caller-owned store ALWAYS fail-closes (shared-UID) regardless of chmod. The
# only way to drive the trusted-binding WRITE path is a store owned by a
# different uid — which needs `sudo chown` (passwordless on CI / Linux). When
# sudo is unavailable (typical macOS dev) we set SMOKE_CONFIG_CALLER_ISO_OK=0 so
# the caller SKIPS the positive WRITE assertion (the deny-side teeth still run
# single-UID). $1=bindings dir. Idempotent.
smoke_config_caller_make_store_foreign() {
  local dir="$1"
  export SMOKE_CONFIG_CALLER_ISO_OK=0
  [[ -n "$dir" && -d "$dir" ]] || return 1
  if ! command -v sudo >/dev/null 2>&1 || ! sudo -n true 2>/dev/null; then
    smoke_log "config-caller: passwordless sudo unavailable — iso (foreign-owned store) positive path skipped"
    return 1
  fi
  # Pick a foreign owner: prefer 'nobody', else uid 1 (daemon). The store only
  # needs to be owned by someone OTHER than the caller and NOT group/other
  # writable, matching the controller-owned 0711 dir / 0644 file iso shape.
  local owner="nobody"
  id nobody >/dev/null 2>&1 || owner="1"
  if ! sudo -n chown -R "$owner" "$dir" 2>/dev/null; then
    smoke_log "config-caller: sudo chown failed — iso positive path skipped"
    return 1
  fi
  sudo -n chmod 0711 "$dir" 2>/dev/null || true
  sudo -n chmod 0644 "$dir"/*.json 2>/dev/null || true
  export SMOKE_CONFIG_CALLER_ISO_OK=1
  return 0
}

# Seed a config-caller admin binding using the REAL live session + REAL pane_pid
# (so the wrapper's match-time liveness check passes when run in-pane).
# $1=bindings dir, $2=agent, $3=admin (default=agent), $4=session (default=live).
# Does NOT make the store foreign-owned — call
# smoke_config_caller_make_store_foreign for the iso positive path, or leave the
# store caller-owned for the shared-UID (deny) cases.
smoke_seed_trusted_admin_binding() {
  local dir="$1" agent="$2" admin="${3:-$2}" session="${4:-${SMOKE_LIVE_SESSION:-sess-live}}"
  mkdir -p "$dir"
  chmod 0755 "$dir" 2>/dev/null || true
  printf '{"version":1,"agent_id":"%s","admin_agent_id":"%s","session":"%s","pane_pid":%s,"engine":"claude","updated_at":"now"}\n' \
    "$agent" "$admin" "$session" "${SMOKE_LIVE_PANE_PID:-$$}" \
    >"$dir/$agent.json"
}

# Restore a config-caller bindings dir to writable + empty. Handles a
# foreign-owned store left by smoke_config_caller_make_store_foreign (sudo rm)
# and a plain caller-owned store alike. Idempotent.
smoke_clear_config_caller_bindings() {
  local dir="$1"
  [[ -n "$dir" ]] || return 0
  if [[ "${SMOKE_CONFIG_CALLER_ISO_OK:-0}" == "1" ]] && command -v sudo >/dev/null 2>&1; then
    sudo -n chown -R "$(id -u):$(id -g)" "$dir" 2>/dev/null || true
    export SMOKE_CONFIG_CALLER_ISO_OK=0
  fi
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
