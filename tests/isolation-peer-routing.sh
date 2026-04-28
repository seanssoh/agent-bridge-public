#!/usr/bin/env bash
# tests/isolation-peer-routing.sh
#
# Regression test for issue #294 — isolated peer A2A through the queue gateway.
#
# Verifies (portable, runs on macOS with bash 4+):
#   1. bridge_write_linux_agent_env_file emits BRIDGE_AGENT_IDS for every
#      static peer, plus non-secret metadata (description, engine, session,
#      workdir, isolation_mode, source).
#   2. The scoped env NEVER contains a peer's BRIDGE_AGENT_LAUNCH_CMD value.
#      The peer's LAUNCH_CMD entry is present-but-empty so the array shape
#      stays consistent.
#   3. The scoped env NEVER contains a peer's BRIDGE_AGENT_PROMPT_GUARD
#      policy value (canary tokens leak otherwise — #294 r1 finding 3). The
#      peer's PROMPT_GUARD entry is present-but-empty.
#   4. The scoped env hides the live BRIDGE_TASK_DB path; queue access must
#      route through the gateway proxy (#294 r1 finding 4 / #287 ACL).
#   5. The scoped env emits the explicit BRIDGE_GATEWAY_PROXY=1 flag when the
#      calling agent is in linux-user isolation, and omits it otherwise.
#   6. bridge_queue_gateway_proxy_agent() returns the calling agent when
#      BRIDGE_GATEWAY_PROXY=1, even with multiple BRIDGE_AGENT_IDS — i.e.,
#      decoupled from roster cardinality.
#   7. Shared-mode regression guard: bridge_queue_gateway_proxy_agent returns
#      empty when BRIDGE_GATEWAY_PROXY is unset.
#
# The Linux-only ACL/sudo path lives in tests/isolation-queue-gateway-acl.sh.
# This test focuses on the env-file content + proxy-detection contract.

set -euo pipefail

SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/.." && pwd -P)"

log() { printf '[peer-routing] %s\n' "$*"; }
die() { printf '[peer-routing][error] %s\n' "$*" >&2; exit 1; }
skip() { printf '[peer-routing][skip] %s\n' "$*"; exit 0; }

# Bash 4+ is required for associative arrays (the entire roster API).
if (( BASH_VERSINFO[0] < 4 )); then
  skip "bash 4+ required (have ${BASH_VERSION})"
fi

TMP_ROOT="$(mktemp -d -t peer-routing-test.XXXXXX)"
trap 'rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT
export BRIDGE_ALLOW_EPHEMERAL_CONTROLLER_ENV=1

export BRIDGE_HOME="$TMP_ROOT/bridge-home"
export BRIDGE_AGENT_HOME_ROOT="$BRIDGE_HOME/agents"
export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
export BRIDGE_LOG_DIR="$BRIDGE_HOME/logs"
export BRIDGE_SHARED_DIR="$BRIDGE_HOME/shared"
export BRIDGE_ACTIVE_AGENT_DIR="$BRIDGE_STATE_DIR/agents"
export BRIDGE_HISTORY_DIR="$BRIDGE_STATE_DIR/history"
export BRIDGE_ROSTER_FILE="$BRIDGE_HOME/agent-roster.sh"
export BRIDGE_ROSTER_LOCAL_FILE="$BRIDGE_HOME/agent-roster.local.sh"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_HOME" "$BRIDGE_AGENT_HOME_ROOT" "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR" "$BRIDGE_SHARED_DIR"
: > "$BRIDGE_ROSTER_FILE"

# Two static agents: peer (linux-user isolated) + admin (shared).
ISOLATED_AGENT="peer-a"
ADMIN_AGENT="admin-a"
PEER_LAUNCH_CMD="claude --token=PEER-TOKEN-DO-NOT-LEAK"
ADMIN_LAUNCH_CMD="claude --token=ADMIN-TOKEN-DO-NOT-LEAK"
PEER_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$ISOLATED_AGENT"
ADMIN_WORKDIR="$BRIDGE_AGENT_HOME_ROOT/$ADMIN_AGENT"
mkdir -p "$PEER_WORKDIR" "$ADMIN_WORKDIR"

cat > "$BRIDGE_ROSTER_LOCAL_FILE" <<ROSTER
#!/usr/bin/env bash
# shellcheck shell=bash disable=SC2034
BRIDGE_AGENT_IDS=("$ISOLATED_AGENT" "$ADMIN_AGENT")
BRIDGE_AGENT_DESC[$ISOLATED_AGENT]="peer agent"
BRIDGE_AGENT_DESC[$ADMIN_AGENT]="admin agent"
BRIDGE_AGENT_ENGINE[$ISOLATED_AGENT]=claude
BRIDGE_AGENT_ENGINE[$ADMIN_AGENT]=claude
BRIDGE_AGENT_SESSION[$ISOLATED_AGENT]=$ISOLATED_AGENT
BRIDGE_AGENT_SESSION[$ADMIN_AGENT]=$ADMIN_AGENT
BRIDGE_AGENT_WORKDIR[$ISOLATED_AGENT]=$PEER_WORKDIR
BRIDGE_AGENT_WORKDIR[$ADMIN_AGENT]=$ADMIN_WORKDIR
BRIDGE_AGENT_LAUNCH_CMD[$ISOLATED_AGENT]=$(printf '%q' "$PEER_LAUNCH_CMD")
BRIDGE_AGENT_LAUNCH_CMD[$ADMIN_AGENT]=$(printf '%q' "$ADMIN_LAUNCH_CMD")
BRIDGE_AGENT_SOURCE[$ISOLATED_AGENT]=static
BRIDGE_AGENT_SOURCE[$ADMIN_AGENT]=static
BRIDGE_AGENT_ISOLATION_MODE[$ISOLATED_AGENT]=linux-user
BRIDGE_AGENT_ISOLATION_MODE[$ADMIN_AGENT]=shared
BRIDGE_AGENT_OS_USER[$ISOLATED_AGENT]=agent-bridge-peer-a
BRIDGE_AGENT_PROMPT_GUARD[$ADMIN_AGENT]="enabled:1;task_body_min_block:high;canary:ADMIN-CANARY-DO-NOT-LEAK"
ROSTER

# shellcheck source=../bridge-lib.sh
source "$REPO_ROOT/bridge-lib.sh"
bridge_load_roster

ENV_FILE="$TMP_ROOT/agent-env.sh"

log "writing scoped env for isolated peer"
bridge_write_linux_agent_env_file "$ISOLATED_AGENT" "$ENV_FILE"
[[ -f "$ENV_FILE" ]] || die "env file not written at $ENV_FILE"

log "asserting peer id is present in scoped env"
grep -Fq "bridge_add_agent_id_if_missing $ADMIN_AGENT" "$ENV_FILE" \
  || die "peer id $ADMIN_AGENT missing from scoped env"
grep -Fq "bridge_add_agent_id_if_missing $ISOLATED_AGENT" "$ENV_FILE" \
  || die "self id $ISOLATED_AGENT missing from scoped env"

log "asserting peer non-secret metadata is emitted"
grep -Eq "BRIDGE_AGENT_DESC\[$ADMIN_AGENT\]=" "$ENV_FILE" \
  || die "peer description missing"
grep -Eq "BRIDGE_AGENT_ENGINE\[$ADMIN_AGENT\]=" "$ENV_FILE" \
  || die "peer engine missing"
grep -Eq "BRIDGE_AGENT_SESSION\[$ADMIN_AGENT\]=" "$ENV_FILE" \
  || die "peer session missing"
grep -Eq "BRIDGE_AGENT_WORKDIR\[$ADMIN_AGENT\]=" "$ENV_FILE" \
  || die "peer workdir missing"
grep -Eq "BRIDGE_AGENT_ISOLATION_MODE\[$ADMIN_AGENT\]=" "$ENV_FILE" \
  || die "peer isolation_mode missing"
grep -Eq "BRIDGE_AGENT_SOURCE\[$ADMIN_AGENT\]=" "$ENV_FILE" \
  || die "peer source missing"

log "asserting peer guard policy entry exists but is empty (canary-leak guard, #294 r1 finding 3)"
peer_guard_line="$(grep -E "^BRIDGE_AGENT_PROMPT_GUARD\[$ADMIN_AGENT\]=" "$ENV_FILE" || true)"
[[ -n "$peer_guard_line" ]] || die "peer prompt_guard entry missing (must be present-but-empty)"
case "$peer_guard_line" in
  "BRIDGE_AGENT_PROMPT_GUARD[$ADMIN_AGENT]=''") ;;
  *) die "peer prompt_guard must be empty string, got: $peer_guard_line" ;;
esac

log "asserting peer prompt_guard canary token is NEVER leaked"
if grep -Fq "ADMIN-CANARY-DO-NOT-LEAK" "$ENV_FILE"; then
  die "peer prompt_guard canary leaked into scoped env"
fi

log "asserting peer LAUNCH_CMD entry exists but is empty"
peer_launch_line="$(grep -E "^BRIDGE_AGENT_LAUNCH_CMD\[$ADMIN_AGENT\]=" "$ENV_FILE" || true)"
[[ -n "$peer_launch_line" ]] || die "peer launch_cmd entry missing (must be present-but-empty)"
case "$peer_launch_line" in
  "BRIDGE_AGENT_LAUNCH_CMD[$ADMIN_AGENT]=''") ;;
  *) die "peer launch_cmd must be empty string, got: $peer_launch_line" ;;
esac

log "asserting peer launch_cmd token is NEVER leaked"
if grep -Fq "ADMIN-TOKEN-DO-NOT-LEAK" "$ENV_FILE"; then
  die "peer launch_cmd leaked into scoped env"
fi
# Self launch_cmd should still be present (calling agent's own command).
if ! grep -Fq "PEER-TOKEN-DO-NOT-LEAK" "$ENV_FILE"; then
  die "self launch_cmd missing from scoped env"
fi

log "asserting BRIDGE_TASK_DB live path is hidden from scoped env (#294 r1 finding 4 / #287 ACL)"
# The scoped env must not disclose the operator's queue DB layout. Either
# absent OR explicitly empty OR /dev/null sentinel is acceptable; the live
# path under \$BRIDGE_STATE_DIR/tasks.db is NOT.
if grep -Fq "$BRIDGE_TASK_DB" "$ENV_FILE"; then
  die "BRIDGE_TASK_DB live path leaked into scoped env: $BRIDGE_TASK_DB"
fi
task_db_line="$(grep -E '^BRIDGE_TASK_DB=' "$ENV_FILE" || true)"
if [[ -n "$task_db_line" ]]; then
  case "$task_db_line" in
    'BRIDGE_TASK_DB='|'BRIDGE_TASK_DB=""'|"BRIDGE_TASK_DB=''"|'BRIDGE_TASK_DB=/dev/null'|"BRIDGE_TASK_DB='/dev/null'"|'BRIDGE_TASK_DB="/dev/null"')
      log "  [ok] BRIDGE_TASK_DB sentineled: $task_db_line"
      ;;
    *)
      die "BRIDGE_TASK_DB sentinel violation in scoped env: $task_db_line"
      ;;
  esac
fi

log "asserting no peer BRIDGE_AGENT_PROMPT_GUARD entry carries non-empty value (#294 r1 finding 3)"
# Walk every BRIDGE_AGENT_PROMPT_GUARD["<id>"] line; only the calling agent
# (ISOLATED_AGENT) may carry a non-empty value. Peer entries must be empty.
nonempty_peer_guard="$(
  grep -E '^BRIDGE_AGENT_PROMPT_GUARD\[[^]]+\]=' "$ENV_FILE" \
    | grep -vE "^BRIDGE_AGENT_PROMPT_GUARD\[$ISOLATED_AGENT\]=" \
    | grep -vE "=(''|\"\")\s*\$" \
    || true
)"
if [[ -n "$nonempty_peer_guard" ]]; then
  die "peer BRIDGE_AGENT_PROMPT_GUARD entries are non-empty (potential canary leak): $nonempty_peer_guard"
fi

log "asserting BRIDGE_GATEWAY_PROXY=1 emitted for isolated agent"
grep -Eq '^BRIDGE_GATEWAY_PROXY=1' "$ENV_FILE" \
  || die "BRIDGE_GATEWAY_PROXY=1 not emitted for linux-user isolated agent"

log "asserting BRIDGE_GATEWAY_PROXY is NOT emitted for shared-mode agent"
SHARED_ENV_FILE="$TMP_ROOT/admin-env.sh"
bridge_write_linux_agent_env_file "$ADMIN_AGENT" "$SHARED_ENV_FILE"
if grep -Eq '^BRIDGE_GATEWAY_PROXY=1' "$SHARED_ENV_FILE"; then
  die "BRIDGE_GATEWAY_PROXY=1 must not be emitted for shared-mode agents"
fi

log "asserting bridge_queue_gateway_proxy_agent triggers via the explicit flag"
# Source the scoped env in a subshell so we don't pollute the test process.
# Override BRIDGE_HOST_PLATFORM so this assertion runs identically on macOS:
# bridge_agent_linux_user_isolation_effective normally requires the real
# host to be Linux. The test target here is the proxy-flag contract, not
# the platform gate.
# shellcheck disable=SC2030,SC2031
(
  export BRIDGE_HOST_PLATFORM_OVERRIDE=Linux
  # shellcheck source=/dev/null
  source "$ENV_FILE"
  export BRIDGE_AGENT_ENV_FILE="$ENV_FILE"
  export BRIDGE_AGENT_ID="$ISOLATED_AGENT"
  result="$(bridge_queue_gateway_proxy_agent 2>/dev/null || true)"
  if [[ "$result" != "$ISOLATED_AGENT" ]]; then
    printf '[peer-routing][error] expected proxy_agent=%s, got=%q\n' \
      "$ISOLATED_AGENT" "$result" >&2
    exit 1
  fi
  # Multi-id roster + explicit flag must still trigger proxy mode (the bug
  # before the fix was that `${#BRIDGE_AGENT_IDS[@]} == 1` gated detection).
  if (( ${#BRIDGE_AGENT_IDS[@]} < 2 )); then
    printf '[peer-routing][error] expected multi-id BRIDGE_AGENT_IDS in scoped env, got %d\n' \
      "${#BRIDGE_AGENT_IDS[@]}" >&2
    exit 1
  fi
) || die "proxy detection failed for isolated agent"

log "asserting bridge_queue_gateway_proxy_agent is OFF for shared-mode (regression guard)"
# shellcheck disable=SC2030,SC2031
(
  export BRIDGE_HOST_PLATFORM_OVERRIDE=Linux
  # shellcheck source=/dev/null
  source "$SHARED_ENV_FILE"
  export BRIDGE_AGENT_ENV_FILE="$SHARED_ENV_FILE"
  export BRIDGE_AGENT_ID="$ADMIN_AGENT"
  unset BRIDGE_GATEWAY_PROXY
  result="$(bridge_queue_gateway_proxy_agent 2>/dev/null || true)"
  if [[ -n "$result" ]]; then
    printf '[peer-routing][error] shared-mode must not trigger proxy, got=%q\n' "$result" >&2
    exit 1
  fi
) || die "shared-mode regression guard failed"

# ---------------------------------------------------------------------------
# Issue #436 regressions: bridge_load_roster scoped-env fallback contract.
# ---------------------------------------------------------------------------
#
# Bug 1: When the isolated REPL invokes a roster-loading helper (e.g. via
# `agb inbox`) without a pre-exported BRIDGE_AGENT_ENV_FILE, the function
# discovers the per-agent scoped env via BRIDGE_AGENT_ID +
# BRIDGE_ACTIVE_AGENT_DIR but historically did not export the discovered
# path. bridge_queue_gateway_proxy_agent then saw an empty env-file var,
# returned 1, and the queue CLI fell through to direct bridge-queue.py
# against BRIDGE_TASK_DB=/dev/null — traceback.
#
# Bug 2: bridge_load_roster continued into bridge_load_static_histories and
# bridge_restore_dynamic_agents_from_history even when scoped, which iterate
# every peer's history .env file. Isolated UIDs cannot read those, surfacing
# "Permission denied" from `source` during routine roster loads.

log "[#436] asserting scoped env fallback exports BRIDGE_AGENT_ENV_FILE"
SCOPED_ENV_HOME="$BRIDGE_ACTIVE_AGENT_DIR/$ISOLATED_AGENT"
mkdir -p "$SCOPED_ENV_HOME"
SCOPED_ENV_PATH="$SCOPED_ENV_HOME/agent-env.sh"
bridge_write_linux_agent_env_file "$ISOLATED_AGENT" "$SCOPED_ENV_PATH"
[[ -r "$SCOPED_ENV_PATH" ]] || die "scoped env fixture not readable at $SCOPED_ENV_PATH"

# shellcheck disable=SC2030,SC2031
(
  export BRIDGE_HOST_PLATFORM_OVERRIDE=Linux
  unset BRIDGE_AGENT_ENV_FILE
  export BRIDGE_AGENT_ID="$ISOLATED_AGENT"
  # BRIDGE_ACTIVE_AGENT_DIR already exported in outer test scope.
  bridge_load_roster
  if [[ "${BRIDGE_AGENT_ENV_FILE:-}" != "$SCOPED_ENV_PATH" ]]; then
    printf '[peer-routing][error] expected BRIDGE_AGENT_ENV_FILE=%s, got=%q\n' \
      "$SCOPED_ENV_PATH" "${BRIDGE_AGENT_ENV_FILE:-}" >&2
    exit 1
  fi
  result="$(bridge_queue_gateway_proxy_agent 2>/dev/null || true)"
  if [[ "$result" != "$ISOLATED_AGENT" ]]; then
    printf '[peer-routing][error] expected proxy_agent=%s after fallback, got=%q\n' \
      "$ISOLATED_AGENT" "$result" >&2
    exit 1
  fi
) || die "scoped env fallback failed to export BRIDGE_AGENT_ENV_FILE for proxy detection"

log "[#436] asserting peer history hydration is skipped when scoped env is active"
# Build a peer history file that, if sourced, would import a sentinel agent
# id into the roster. Make it unreadable to mimic the cross-UID denial that
# surfaces on Linux. macOS runs as the test invoker but chmod 000 still
# guarantees that any source attempt errors out — perfect canary for the
# guard.
mkdir -p "$BRIDGE_HISTORY_DIR"
PEER_HISTORY_FILE="$BRIDGE_HISTORY_DIR/sentinel-peer.env"
cat > "$PEER_HISTORY_FILE" <<'PEER_HISTORY'
AGENT_ID="sentinel-peer-from-history"
AGENT_DESC="should never be sourced when scoped"
AGENT_ENGINE=claude
AGENT_SESSION=sentinel-peer-from-history
AGENT_WORKDIR=/tmp/sentinel-peer-from-history
PEER_HISTORY
chmod 000 "$PEER_HISTORY_FILE"
trap 'chmod 600 "$PEER_HISTORY_FILE" >/dev/null 2>&1 || true; rm -rf "$TMP_ROOT" >/dev/null 2>&1 || true' EXIT

# shellcheck disable=SC2030,SC2031
(
  export BRIDGE_HOST_PLATFORM_OVERRIDE=Linux
  unset BRIDGE_AGENT_ENV_FILE
  export BRIDGE_AGENT_ID="$ISOLATED_AGENT"
  # bridge_load_roster must NOT attempt to source the unreadable peer
  # history when the scoped fallback is in play. set -e in the helper would
  # otherwise propagate a non-zero rc from `source`.
  if ! bridge_load_roster 2>/tmp/peer-routing-436-err.log; then
    printf '[peer-routing][error] bridge_load_roster errored under scoped env (peer history not skipped)\n' >&2
    cat /tmp/peer-routing-436-err.log >&2 || true
    exit 1
  fi
  if grep -Fq "Permission denied" /tmp/peer-routing-436-err.log 2>/dev/null; then
    printf '[peer-routing][error] permission-denied surfaced from peer history under scoped env\n' >&2
    cat /tmp/peer-routing-436-err.log >&2 || true
    exit 1
  fi
  # Sentinel must NOT have been hydrated.
  if bridge_agent_exists "sentinel-peer-from-history"; then
    printf '[peer-routing][error] peer history was hydrated despite scoped env active\n' >&2
    exit 1
  fi
) || die "peer history hydration was not skipped under scoped env"

log "[#436] asserting peer history hydration STILL runs in legacy controller path"
# Inverse case: when scoped env is absent (controller / operator UID),
# peer history hydration must continue to run so dashboards keep rebuilding
# dynamic agents from $BRIDGE_HISTORY_DIR. Use a readable history fixture
# matching a synthetic tmux session so the restore path's session-exists
# guard passes (use a bridge_tmux_session_exists override hook for portability).
chmod 600 "$PEER_HISTORY_FILE"
# shellcheck disable=SC2030,SC2031
(
  unset BRIDGE_AGENT_ID BRIDGE_AGENT_ENV_FILE
  # Stub bridge_tmux_session_exists so we don't need a live tmux session;
  # the call site guards on it before applying the history record.
  # shellcheck disable=SC2329  # invoked indirectly via bridge_load_roster
  bridge_tmux_session_exists() { return 0; }
  # shellcheck disable=SC2329  # invoked indirectly via bridge_load_roster
  bridge_claude_session_id_exists() { return 0; }
  bridge_load_roster
  if ! bridge_agent_exists "sentinel-peer-from-history"; then
    printf '[peer-routing][error] legacy path failed to hydrate peer history sentinel\n' >&2
    exit 1
  fi
) || die "legacy controller path lost peer history hydration"
chmod 000 "$PEER_HISTORY_FILE"

# Linux-only: full live-isolation peer-routing roundtrip lives in
# tests/isolation-queue-gateway-acl.sh. Skipping that here keeps this test
# portable across macOS dev hosts.
if [[ "$(uname -s)" != "Linux" ]]; then
  log "macOS host — skipping live linux-user isolation roundtrip"
  log "isolation peer-routing test passed (env-file + proxy-flag contract)"
  exit 0
fi

log "Linux host — sudo+setfacl roundtrip lives in isolation-queue-gateway-acl.sh"
log "isolation peer-routing test passed"
