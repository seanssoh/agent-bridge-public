#!/usr/bin/env bash
# scripts/smoke/I-beta4-helpers/run-stuck-scan-tick.sh
#
# Test driver for v0.15.0-beta4 Lane I r3 (codex r2 TEST GAP).
#
# Exercises the actual `process_a2a_outbox_stuck_scan_tick` shell function
# from bridge-daemon.sh in isolation, with mocks for:
#   - `bridge-a2a.py outbox list --json` (returns fixture JSON path)
#   - `$BRIDGE_HOME/agent-bridge task create` (rc controlled by
#     `BRIDGE_A2A_TEST_TASK_CREATE_RC` env var)
#
# This driver:
#   1. Extracts the `process_a2a_outbox_stuck_scan_tick` function body
#      verbatim from bridge-daemon.sh (via awk between the `() {` line
#      and the matching `^}` close brace) and `eval`s it in this shell.
#   2. Stubs `daemon_warn` / `daemon_log_event` / `bridge_audit_log`
#      so we can capture warning output and don't need to source the
#      full lib stack.
#   3. Overrides `bridge_with_timeout` so the inner subprocess for
#      `a2a_outbox_list` reads from a fixture file (mock), while the
#      `a2a_stuck_decide` / `a2a_stuck_ack` calls pass through to the
#      real `bridge-daemon-helpers.py`.
#   4. Invokes the function once.
#
# Inputs (env):
#   - SCRIPT_DIR          : repo root (so daemon function can find
#                           bridge-a2a.py + bridge-daemon-helpers.py)
#   - BRIDGE_HOME         : isolated home (smoke_setup_bridge_home)
#   - BRIDGE_STATE_DIR    : ditto
#   - BRIDGE_ADMIN_AGENT_ID : admin agent target (e.g. "patch")
#   - BRIDGE_A2A_TEST_OUTBOX_JSON : path to outbox-list JSON fixture
#   - BRIDGE_A2A_TEST_TASK_CREATE_RC : 0 = success, 1 = failure
#   - BRIDGE_A2A_TEST_WARN_LOG : path to capture daemon_warn output
#   - BRIDGE_A2A_TEST_EVENT_LOG : path to capture daemon_log_event output
#
# Exit code: 0 if function ran (regardless of internal rc); non-zero only
# on driver setup error.

set -uo pipefail

DRIVER_SCRIPT_DIR="${SCRIPT_DIR:-}"
if [[ -z "$DRIVER_SCRIPT_DIR" ]]; then
  echo "[I-beta4-helpers] SCRIPT_DIR not set; cannot locate bridge-daemon.sh" >&2
  exit 2
fi

DAEMON_SH="$DRIVER_SCRIPT_DIR/bridge-daemon.sh"
if [[ ! -f "$DAEMON_SH" ]]; then
  echo "[I-beta4-helpers] missing bridge-daemon.sh at $DAEMON_SH" >&2
  exit 2
fi

# Required env contract (fail-loud if missing).
for var in BRIDGE_HOME BRIDGE_STATE_DIR BRIDGE_ADMIN_AGENT_ID \
           BRIDGE_A2A_TEST_OUTBOX_JSON BRIDGE_A2A_TEST_TASK_CREATE_RC \
           BRIDGE_A2A_TEST_WARN_LOG BRIDGE_A2A_TEST_EVENT_LOG; do
  if [[ -z "${!var:-}" ]]; then
    echo "[I-beta4-helpers] required env var $var is empty" >&2
    exit 2
  fi
done

# Stub helpers normally provided by bridge-lib.sh + lib/bridge-state.sh.
# All four functions below are called INDIRECTLY by the eval'd
# `process_a2a_outbox_stuck_scan_tick` body (extracted from
# bridge-daemon.sh further down). Shellcheck cannot see those indirect
# call sites, so we suppress SC2329 explicitly per stub.

# shellcheck disable=SC2329
daemon_warn() {
  local message="$1"
  printf '[%s] [warn] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" \
    >>"$BRIDGE_A2A_TEST_WARN_LOG"
  # Also echo to stderr so smoke can capture if needed.
  printf '[%s] [warn] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" >&2
}

# shellcheck disable=SC2329
daemon_log_event() {
  local message="$1"
  printf '[%s] %s\n' "$(date '+%Y-%m-%dT%H:%M:%S%z')" "$message" \
    >>"$BRIDGE_A2A_TEST_EVENT_LOG"
}

# shellcheck disable=SC2329
bridge_audit_log() {
  # No-op stub — production audit_log writes to BRIDGE_AUDIT_LOG and has
  # many helper dependencies. Test asserts the warning + ledger state,
  # not audit rows.
  return 0
}

# bridge_with_timeout signature: bridge_with_timeout <secs> <label> <cmd...>
# Production routes label "a2a_outbox_list" to `bridge-a2a.py outbox list
# --json`. The driver swaps in a `cat $fixture` for that label so we don't
# need a real SQLite outbox.
# shellcheck disable=SC2329
bridge_with_timeout() {
  local secs="${1:-}"
  local label="${2:-unknown}"
  shift 2 || true
  case "$label" in
    a2a_outbox_list)
      # Return fixture JSON. Production would invoke
      # `python3 bridge-a2a.py outbox list --json` here.
      cat "$BRIDGE_A2A_TEST_OUTBOX_JSON"
      return 0
      ;;
    a2a_stuck_decide|a2a_stuck_ack)
      # Pass-through to the real python helper — these are the call
      # paths under test.
      "$@"
      return $?
      ;;
    *)
      # Unknown label — pass-through.
      "$@"
      return $?
      ;;
  esac
}

# Extract the production function body verbatim from bridge-daemon.sh.
# Boundary: `^process_a2a_outbox_stuck_scan_tick() \{$` ... first `^\}$`.
FN_SRC="$(awk '/^process_a2a_outbox_stuck_scan_tick\(\) \{/,/^\}$/' "$DAEMON_SH")"
if [[ -z "$FN_SRC" ]] || ! printf '%s' "$FN_SRC" | grep -F 'process_a2a_outbox_stuck_scan_tick' >/dev/null; then
  echo "[I-beta4-helpers] failed to extract function body from $DAEMON_SH" >&2
  exit 2
fi

# shellcheck disable=SC2086
eval "$FN_SRC"

# Sanity-check the function is now defined in this shell.
if ! declare -F process_a2a_outbox_stuck_scan_tick >/dev/null; then
  echo "[I-beta4-helpers] eval did not define process_a2a_outbox_stuck_scan_tick" >&2
  exit 2
fi

# The production function gates on the existence of handoff.local.json.
# Smoke must have created it. Confirm.
HANDOFF_CONFIG="${BRIDGE_A2A_CONFIG:-$BRIDGE_HOME/handoff.local.json}"
if [[ ! -f "$HANDOFF_CONFIG" ]]; then
  echo "[I-beta4-helpers] $HANDOFF_CONFIG missing — smoke must seed it" >&2
  exit 2
fi

# Run the actual production code path.
process_a2a_outbox_stuck_scan_tick || true

exit 0
