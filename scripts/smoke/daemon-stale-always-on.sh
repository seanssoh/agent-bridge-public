#!/usr/bin/env bash
#
# scripts/smoke/daemon-stale-always-on.sh — issue #4795 regression.
#
# Operator-observed context (2026-05-17 patch host on Linux): after
# removing smoke-fixture agents (`codex-cli-agent-44220`,
# `requester-agent-44220`, `roster-reload-agent-44220`) via
# `agent delete --purge-home`, the daemon log emitted
# `auto-start backoff <agent> ... reason=start-command-failed` on every
# sync tick following a daemon restart. `agent list` was clean but the
# per-agent state file
# `$BRIDGE_STATE_DIR/daemon-autostart/<agent>.env` persisted, so the
# backoff machinery kept treating the agents as candidates whenever a
# matching summary row leaked through (live-tmux or agent_state union).
#
# Fix (this PR): add `bridge_daemon_sweep_orphan_autostart_state` to
# bridge-daemon.sh, called from cmd_sync_cycle before
# process_on_demand_agents. It enumerates the daemon-autostart directory
# and removes any `<agent>.env` whose agent is no longer in the roster
# registry. Also clear the state file explicitly from `agent delete` and
# `agent retire` so the next tick observes a clean slate.
#
# Cases (all run in an isolated BRIDGE_HOME — never touches live runtime):
#
#   C1. Sweep removes orphan state files for agents that are NOT in the
#       roster, and keeps state files for agents that ARE in the roster.
#       Asserts the kept-file path AND the swept-file path.
#
#   C2. Daemon restart simulation: a daemon process loading a clean
#       roster (no codex-cli-agent-44220, etc.) and running one sync cycle
#       must not retain orphan state files. We seed orphan state files,
#       invoke the sweep, and assert the daemon-autostart directory is
#       empty.
#
#   C3. The sweep is idempotent — calling it twice in a row does not
#       error and emits no further audit rows after the orphan set is
#       drained.
#
# Footgun #11 mitigation: this smoke does not heredoc-stdin into any
# subprocess. Helper bodies are written via `Write`-equivalent file
# creation, not `cat <<EOF | bash`.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon-periodic-token-sync.sh).
_SMOKE_REEXEC_TARGET="${BASH_SOURCE[0]}"
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  if [[ -f "$_SMOKE_REEXEC_TARGET" ]]; then
    for smoke_candidate_bash in /opt/homebrew/bin/bash /usr/local/bin/bash "${BASH4_BIN:-}"; do
      [[ -n "$smoke_candidate_bash" && -x "$smoke_candidate_bash" ]] || continue
      if "$smoke_candidate_bash" -lc '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
        exec "$smoke_candidate_bash" "$_SMOKE_REEXEC_TARGET" "$@"
      fi
    done
  fi
  echo "[smoke:daemon-stale-always-on] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="daemon-stale-always-on"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd awk
smoke_setup_bridge_home "$SMOKE_NAME"

DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
[[ -f "$DAEMON_SRC" ]] || smoke_fail "bridge-daemon.sh not found at $DAEMON_SRC"

# Seed an autostart state file for an agent (mirrors the format
# bridge_daemon_note_autostart_failure writes).
seed_autostart_state() {
  local agent="$1"
  local dir="$BRIDGE_STATE_DIR/daemon-autostart"
  mkdir -p "$dir"
  local now
  now="$(date +%s)"
  {
    printf 'AUTO_START_FAIL_COUNT=%s\n' "1"
    printf 'AUTO_START_NEXT_RETRY_TS=%s\n' "$(( now + 5 ))"
    printf "AUTO_START_LAST_REASON=%q\n" "start-command-failed"
  } >"$dir/$agent.env"
}

count_autostart_files() {
  local dir="$BRIDGE_STATE_DIR/daemon-autostart"
  [[ -d "$dir" ]] || { printf '0'; return 0; }
  # shellcheck disable=SC2012
  ls -1 "$dir"/*.env 2>/dev/null | wc -l | awk '{print $1}'
}

# Build a minimal driver that:
#   - sources the extracted bridge_daemon_sweep_orphan_autostart_state +
#     bridge_daemon_autostart_state_file
#   - stubs bridge_agent_exists to consult a colon-separated allowlist
#     (BRIDGE_TEST_REGISTRY) so we do not need to materialise the whole
#     roster loader for this unit
#   - stubs daemon_info / bridge_audit_log to write to files we can grep
#   - invokes the sweep and prints a numeric marker (count of files left)
DRIVER="$SMOKE_TMP_ROOT/sweep-driver.sh"

# Extract the production helper bodies. Awk's BEGIN/END-style range match
# stops at the next top-level closing brace so we get exactly one
# function. If the extraction sees zero matches we bail with a clear
# refactor-detection error.
FUNCS_SH="$SMOKE_TMP_ROOT/sweep-functions.sh"
{
  awk '/^bridge_daemon_autostart_state_file\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_sweep_orphan_autostart_state\(\) \{/,/^}/' "$DAEMON_SRC"
} >"$FUNCS_SH"

for fn in bridge_daemon_autostart_state_file \
          bridge_daemon_sweep_orphan_autostart_state; do
  if ! grep -q "^${fn}() {" "$FUNCS_SH"; then
    smoke_fail "could not extract function: $fn (check bridge-daemon.sh for rename)"
  fi
done

# Driver stubs the agent-existence + logging helpers and sources the
# extracted production functions. This keeps the smoke decoupled from
# the full roster loader while still exercising the real sweep logic.
{
  printf '#!/usr/bin/env bash\n'
  printf 'set -euo pipefail\n'
  printf '\n'
  printf 'BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR"\n'
  printf '\n'
  printf '# Allowlist registry: colon-separated agent ids.\n'
  printf 'BRIDGE_TEST_REGISTRY="${BRIDGE_TEST_REGISTRY:-}"\n'
  printf '\n'
  printf 'bridge_agent_exists() {\n'
  printf '  local agent="$1"\n'
  printf '  case ":${BRIDGE_TEST_REGISTRY}:" in\n'
  printf '    *":${agent}:"*) return 0 ;;\n'
  printf '  esac\n'
  printf '  return 1\n'
  printf '}\n'
  printf '\n'
  printf 'daemon_info() {\n'
  printf '  printf "info: %%s\\n" "$*" >>"$DAEMON_LOG"\n'
  printf '}\n'
  printf '\n'
  printf 'bridge_audit_log() {\n'
  printf '  # action=$2 target=$3 detail=$5 (rest ignored)\n'
  printf '  printf "audit %%s %%s\\n" "${2:-}" "${3:-}" >>"$AUDIT_FILE"\n'
  printf '}\n'
  printf '\n'
  printf 'source "$FUNCS_SH"\n'
  printf '\n'
  printf 'rc=0\n'
  printf 'bridge_daemon_sweep_orphan_autostart_state || rc=$?\n'
  printf 'echo "SWEEP-RC=$rc"\n'
} >"$DRIVER"
chmod +x "$DRIVER"

DAEMON_LOG="$SMOKE_TMP_ROOT/daemon.log"
AUDIT_FILE="$SMOKE_TMP_ROOT/audit.log"
: >"$DAEMON_LOG"
: >"$AUDIT_FILE"

run_sweep() {
  local registry="$1"
  env \
    BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
    FUNCS_SH="$FUNCS_SH" \
    DAEMON_LOG="$DAEMON_LOG" \
    AUDIT_FILE="$AUDIT_FILE" \
    BRIDGE_TEST_REGISTRY="$registry" \
    bash "$DRIVER"
}

# ---------------------------------------------------------------------------
# C1 — sweep removes orphan files, keeps live ones.
# ---------------------------------------------------------------------------
step_c1_sweep_orphans_keep_live() {
  smoke_log "C1: sweep removes orphan state, preserves live state"
  rm -rf "$BRIDGE_STATE_DIR/daemon-autostart"
  : >"$DAEMON_LOG"
  : >"$AUDIT_FILE"

  seed_autostart_state "codex-cli-agent-44220"
  seed_autostart_state "requester-agent-44220"
  seed_autostart_state "roster-reload-agent-44220"
  seed_autostart_state "agb-dev-claude"

  smoke_assert_eq "4" "$(count_autostart_files)" "C1 precondition: 4 state files seeded"

  # Only agb-dev-claude is in the live registry.
  local out
  out="$(run_sweep "agb-dev-claude")"
  smoke_assert_contains "$out" "SWEEP-RC=0" "C1 sweep reports rc=0 (changes happened)"

  smoke_assert_eq "1" "$(count_autostart_files)" "C1 only the live agent's state file remains"

  [[ -f "$BRIDGE_STATE_DIR/daemon-autostart/agb-dev-claude.env" ]] || \
    smoke_fail "C1: live agent state file must survive sweep"
  [[ ! -f "$BRIDGE_STATE_DIR/daemon-autostart/codex-cli-agent-44220.env" ]] || \
    smoke_fail "C1: orphan codex-cli-agent-44220 state file must be removed"
  [[ ! -f "$BRIDGE_STATE_DIR/daemon-autostart/requester-agent-44220.env" ]] || \
    smoke_fail "C1: orphan requester-agent-44220 state file must be removed"
  [[ ! -f "$BRIDGE_STATE_DIR/daemon-autostart/roster-reload-agent-44220.env" ]] || \
    smoke_fail "C1: orphan roster-reload-agent-44220 state file must be removed"

  # Audit log: one row per orphan swept.
  local audit_count
  audit_count="$(grep -c '^audit autostart_state_orphan_swept ' "$AUDIT_FILE" 2>/dev/null || true)"
  smoke_assert_eq "3" "$audit_count" "C1 audit logged exactly 3 orphan-sweep rows"

  # daemon_info: matching count of operator-facing log lines.
  local info_count
  info_count="$(grep -c 'auto-start state cleared for orphan agent' "$DAEMON_LOG" 2>/dev/null || true)"
  smoke_assert_eq "3" "$info_count" "C1 daemon_info logged exactly 3 orphan clears"
}

# ---------------------------------------------------------------------------
# C2 — daemon restart simulation: orphan state does not persist across
# a sync cycle when the roster no longer carries those agents.
# ---------------------------------------------------------------------------
step_c2_restart_drops_orphans() {
  smoke_log "C2: simulated daemon restart with empty registry drops every orphan"
  rm -rf "$BRIDGE_STATE_DIR/daemon-autostart"
  : >"$DAEMON_LOG"
  : >"$AUDIT_FILE"

  seed_autostart_state "codex-cli-agent-44220"
  seed_autostart_state "requester-agent-44220"
  smoke_assert_eq "2" "$(count_autostart_files)" "C2 precondition: 2 state files seeded"

  # Empty registry — every state file should be swept.
  local out
  out="$(run_sweep "")"
  smoke_assert_contains "$out" "SWEEP-RC=0" "C2 sweep reports rc=0"
  smoke_assert_eq "0" "$(count_autostart_files)" "C2: no state files remain after sweep with empty registry"
}

# ---------------------------------------------------------------------------
# C3 — sweep is idempotent: second pass produces no changes / no audit rows.
# ---------------------------------------------------------------------------
step_c3_sweep_idempotent() {
  smoke_log "C3: sweep is idempotent on an already-clean directory"
  # C2 left the directory empty — run sweep again with no registry.
  : >"$AUDIT_FILE"
  : >"$DAEMON_LOG"

  local out
  out="$(run_sweep "")"
  # rc=1 (no changes) is the expected idempotent return.
  smoke_assert_contains "$out" "SWEEP-RC=1" "C3 second sweep reports rc=1 (no changes)"

  local audit_count
  audit_count="$(grep -c '^audit autostart_state_orphan_swept ' "$AUDIT_FILE" 2>/dev/null || true)"
  smoke_assert_eq "0" "$audit_count" "C3: no audit rows on second sweep"

  # Also handle the missing-directory case (after a fresh install, before
  # the daemon has noted any failures, the directory does not exist yet).
  rm -rf "$BRIDGE_STATE_DIR/daemon-autostart"
  out="$(run_sweep "")"
  smoke_assert_contains "$out" "SWEEP-RC=1" "C3 sweep with missing directory still returns rc=1"
}

step_c1_sweep_orphans_keep_live
step_c2_restart_drops_orphans
step_c3_sweep_idempotent

smoke_log "PASS: daemon-stale-always-on sweep cleans orphan state (refs #4795)"
