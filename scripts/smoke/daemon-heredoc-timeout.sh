#!/usr/bin/env bash
#
# scripts/smoke/daemon-heredoc-timeout.sh — issue #800 Track A regression.
#
# Proves that the daemon-loop subprocess helpers (bridge-daemon-helpers.py)
# are correctly wrapped by bridge_with_timeout so a deliberately-stalling
# helper cannot wedge the main loop the way the unwrapped
# `$(python3 - <<'PY')` heredoc-stdin pattern did on v0.7.6 (cf. #800).
#
# What we exercise (in order):
#
#   1. bridge_with_timeout(2, …) around a python helper that sleeps forever
#      must terminate the child within the budget + small margin and exit
#      with rc=124. This is the core wrapping correctness check.
#   2. A `daemon_subprocess_timeout` row must be appended to the audit log
#      with our call-site label so the operator can see which step hung.
#   3. A second invocation immediately after must still succeed (the loop
#      is not wedged — recovery is automatic on next tick). We swap the
#      helper for a no-op to simulate "next tick, helper recovered".
#   4. bridge-daemon-helpers.py exposes all 9 subcommands Track A relies on.
#
# We do NOT need real claude/codex binaries — we test only the daemon's
# subprocess wrapping correctness via the bridge_with_timeout helper that
# bridge-daemon.sh uses for every callsite touched by Track A.

# Bash 4+ re-exec (mirrors scripts/smoke/daemon.sh).
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
  echo "[smoke:daemon-heredoc-timeout] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="daemon-heredoc-timeout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
# bridge_with_timeout falls back to a plain exec on hosts without timeout(1),
# which would silently skip the actual coverage we are testing. Insist on
# either timeout or gtimeout so the smoke is meaningful.
if ! command -v timeout >/dev/null 2>&1 && ! command -v gtimeout >/dev/null 2>&1; then
  smoke_fail "neither timeout(1) nor gtimeout(1) available; bridge_with_timeout cannot enforce the ceiling and this smoke would silently pass without coverage. install coreutils."
fi

smoke_setup_bridge_home "$SMOKE_NAME"

# Use the in-tree bridge-state.sh so we exercise the real bridge_with_timeout.
export BRIDGE_REPO_ROOT="$SMOKE_REPO_ROOT"
export BRIDGE_SCRIPT_DIR="$BRIDGE_REPO_ROOT"
# bridge_audit_log appends to $BRIDGE_AUDIT_LOG — lib.sh sets this for us.
: >"$BRIDGE_AUDIT_LOG"

# Synthesize the two helpers we need.
STALL_HELPER="$SMOKE_TMP_ROOT/sleeps-forever.py"
cat >"$STALL_HELPER" <<'PY'
#!/usr/bin/env python3
"""Deliberately-stalling helper for the #800 Track A smoke. Sleeps
indefinitely so bridge_with_timeout has to kill us via SIGTERM/SIGKILL."""
import time
import sys
# Drain stdin if anything is piped in (the real heredoc-stdin pattern
# from before Track A would block here forever; we just discard).
try:
    sys.stdin.read()
except Exception:
    pass
while True:
    time.sleep(60)
PY
chmod +x "$STALL_HELPER"

NOOP_HELPER="$SMOKE_TMP_ROOT/noop.py"
cat >"$NOOP_HELPER" <<'PY'
#!/usr/bin/env python3
"""Recovered helper — returns the same shape nudge-live-state would."""
print("0\t0\t")
PY
chmod +x "$NOOP_HELPER"

# Driver script that sources bridge_with_timeout and invokes it on argv.
# Written to disk so we avoid layered quoting around `bash -c`.
DRIVER="$SMOKE_TMP_ROOT/with-timeout-driver.sh"
cat >"$DRIVER" <<'EOF'
#!/usr/bin/env bash
# args: <secs> <label> <cmd> [cmd_args...]
set -uo pipefail
SCRIPT_DIR="${BRIDGE_REPO_ROOT:?}"
# shellcheck source=/dev/null
source "$BRIDGE_REPO_ROOT/lib/bridge-state.sh"
secs="$1"
label="$2"
shift 2
bridge_with_timeout "$secs" "$label" "$@"
EOF
chmod +x "$DRIVER"

run_with_timeout_subshell() {
  local label="$1"
  local secs="$2"
  shift 2
  local rc=0
  local started ended elapsed
  started="$(date +%s)"
  set +e
  "$DRIVER" "$secs" "$label" "$@" >/dev/null 2>&1
  rc=$?
  set -e
  ended="$(date +%s)"
  elapsed=$(( ended - started ))
  printf 'rc=%d elapsed=%d\n' "$rc" "$elapsed"
}

step_wrapping_terminates_stalled_helper() {
  smoke_log "step 1: bridge_with_timeout 2s must terminate the stalling helper"
  local output rc elapsed
  output="$(run_with_timeout_subshell nudge_live_state 2 python3 "$STALL_HELPER")"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ -n "$rc" ]] || smoke_fail "could not parse rc from: $output"
  [[ -n "$elapsed" ]] || smoke_fail "could not parse elapsed from: $output"
  # timeout(1) returns 124 on hit, 137 if KILL was needed.
  if [[ "$rc" != "124" && "$rc" != "137" ]]; then
    smoke_fail "expected rc=124 or 137 from timeout, got rc=$rc (elapsed=${elapsed}s, output=$output)"
  fi
  # Budget = 2s + generous 5s slack for cold python startup + fork on slow CI.
  if (( elapsed > 8 )); then
    smoke_fail "wrapping did NOT enforce the 2s ceiling (elapsed=${elapsed}s); the heredoc-write deadlock class would still be possible"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s (within budget)"
}

step_audit_row_written() {
  smoke_log "step 2: daemon_subprocess_timeout audit row must be present"
  if [[ ! -s "$BRIDGE_AUDIT_LOG" ]]; then
    smoke_fail "audit log is empty after timeout fired: $BRIDGE_AUDIT_LOG"
  fi
  # bridge_audit_log writes JSONL via bridge-audit.py — grep is sufficient
  # to confirm both the action and the call-site label.
  if ! grep -q 'daemon_subprocess_timeout' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing 'daemon_subprocess_timeout' row: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  if ! grep -q 'nudge_live_state' "$BRIDGE_AUDIT_LOG"; then
    smoke_fail "audit log missing 'nudge_live_state' call-site tag: $(cat "$BRIDGE_AUDIT_LOG")"
  fi
  smoke_log "  audit row present with call_site=nudge_live_state"
}

step_loop_recovers_next_tick() {
  smoke_log "step 3: a follow-up invocation must succeed (loop not wedged)"
  local output rc elapsed
  output="$(run_with_timeout_subshell nudge_live_state 5 python3 "$NOOP_HELPER")"
  rc="$(printf '%s\n' "$output" | sed -n 's/.*rc=\([0-9]*\).*/\1/p')"
  elapsed="$(printf '%s\n' "$output" | sed -n 's/.*elapsed=\([0-9]*\).*/\1/p')"
  [[ "$rc" == "0" ]] || smoke_fail "follow-up invocation should succeed but rc=$rc (output=$output)"
  if (( elapsed > 5 )); then
    smoke_fail "follow-up invocation should be fast but elapsed=${elapsed}s"
  fi
  smoke_log "  rc=$rc elapsed=${elapsed}s — daemon loop recovers naturally"
}

step_helper_subcommands_resolve() {
  smoke_log "step 4: bridge-daemon-helpers.py exposes the expected subcommands"
  local help_out
  help_out="$(python3 "$BRIDGE_REPO_ROOT/bridge-daemon-helpers.py" --help 2>&1 || true)"
  local sub
  for sub in usage-alert-parse release-alert-parse backup-parse stall-iso-format \
             permission-expire-scan watchdog-problem-count nudge-live-state \
             memory-daily-orphan-scan mcp-orphan-cleanup-parse; do
    smoke_assert_contains "$help_out" "$sub" "helper --help should list $sub"
  done
}

smoke_run "stalling helper terminates within budget" step_wrapping_terminates_stalled_helper
smoke_run "daemon_subprocess_timeout audit row written" step_audit_row_written
smoke_run "next tick recovers without intervention" step_loop_recovers_next_tick
smoke_run "all 9 Track-A subcommands wired up" step_helper_subcommands_resolve

smoke_log "PASS"
