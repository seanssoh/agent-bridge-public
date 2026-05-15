#!/usr/bin/env bash
#
# scripts/smoke/daemon-periodic-token-sync.sh — v0.13.6 hotfix regression.
#
# Operator-observed context (2026-05-15 patch host on Linux): three static
# cron-only Claude agents (dev_mun / sales_choi / mgt_ahn) carried a 5/12
# claude-token while the controller (patch) refreshed to 5/15 via its own
# Claude Code refresh. mgt_ahn hit a 429 because the stale token was still
# pinned. Daemon log showed zero rotation / sync / usage events between
# 5/12 and 5/15 — process_claude_token_recovery's sync branch only fires
# when `sync_recommended=1`, which never happens for cron-only agents.
#
# Fix (v0.13.6): bridge-daemon.sh now exposes
# `bridge_daemon_periodic_token_sync_due` + `bridge_daemon_periodic_token_sync_tick`
# wired into the main poll loop. Every N seconds (env override
# BRIDGE_CLAUDE_TOKEN_SYNC_INTERVAL_SECONDS, default 3600) the tick calls
# `bridge-auth.sh claude-token sync --agents <scope>` regardless of any
# rotation / recovery event, writes a `claude_token_periodic_sync` audit
# row, and updates the last-sync timestamp.
#
# This smoke exercises four cases (A1-A4) directly against the two
# extracted functions, using a shim `bridge-auth.sh` so we never touch the
# real sync path. We intentionally do not boot the daemon — those cases
# are covered by the live-tmux-daemon smoke. The unit-level coverage
# proves the cadence + audit + state-file contract.
#
# Cases:
#   A1. First call after fresh BRIDGE_STATE_DIR — `_due` returns 0 (no
#       state file yet), `_tick` fires, writes last-sync, emits audit row,
#       and exits rc=0.
#   A2. Immediate second call — `_due` returns 1 (elapsed=0 < interval),
#       `_tick` no-ops, audit row count unchanged, last-sync timestamp
#       unchanged.
#   A3. Backdate last-sync to (now - interval - margin) — `_due` returns 0
#       again, `_tick` fires a second time, audit row count increments,
#       last-sync timestamp is refreshed.
#   A4. Shim bridge-auth.sh returns non-zero — `_tick` records the attempt
#       (so we do not hot-loop), writes a status=failed audit row, returns
#       rc=1. The status-failed branch is the operator's visibility into
#       persistent sync breakage.
#
# Footgun #11 mitigation: every helper body in this smoke is written to a
# tempfile (`cat > "$path" <<'EOF' ... EOF`) and invoked via `bash <path>`
# rather than passed through `bash -s <<<` here-strings or `python3 - <<'PY'`
# heredoc-stdin. This mirrors the post-#800 / post-PR #801 convention.

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
  echo "[smoke:daemon-periodic-token-sync] requires Bash 4+; install homebrew bash or set BASH4_BIN." >&2
  exit 1
fi

set -euo pipefail

SMOKE_NAME="daemon-periodic-token-sync"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3
smoke_require_cmd awk
smoke_setup_bridge_home "$SMOKE_NAME"

DAEMON_SRC="$SMOKE_REPO_ROOT/bridge-daemon.sh"
[[ -f "$DAEMON_SRC" ]] || smoke_fail "bridge-daemon.sh not found at $DAEMON_SRC"

# Extract the two functions under test. The state-file helper is also
# pulled because _due and _tick both call it.
FUNCS_SH="$SMOKE_TMP_ROOT/periodic-sync-functions.sh"
{
  awk '/^bridge_daemon_periodic_token_sync_state_file\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_periodic_token_sync_due\(\) \{/,/^}/' "$DAEMON_SRC"
  printf '\n'
  awk '/^bridge_daemon_periodic_token_sync_tick\(\) \{/,/^}/' "$DAEMON_SRC"
} >"$FUNCS_SH"

# Sanity-check the extraction so a future refactor that renames the
# functions surfaces here rather than in a confusing downstream failure.
for fn in bridge_daemon_periodic_token_sync_state_file \
          bridge_daemon_periodic_token_sync_due \
          bridge_daemon_periodic_token_sync_tick; do
  if ! grep -q "^${fn}() {" "$FUNCS_SH"; then
    smoke_fail "could not extract function: $fn (check bridge-daemon.sh for rename)"
  fi
done

# Shim directory for bridge-auth.sh + the daemon-helpers script. We put
# the shim path in $SCRIPT_DIR so the function body finds the right
# bridge-auth.sh / bridge-daemon-helpers.py via "$SCRIPT_DIR/...".
SHIM_DIR="$SMOKE_TMP_ROOT/shim"
mkdir -p "$SHIM_DIR"

# bridge-auth.sh shim: by default prints a valid `claude-token sync --json`
# envelope and exits 0. The A4 case rewrites this to exit non-zero.
make_auth_shim_success() {
  cat >"$SHIM_DIR/bridge-auth.sh" <<'EOF'
#!/usr/bin/env bash
# Test shim for bridge-auth.sh — emits a minimal `claude-token sync --json`
# envelope so the daemon helper's sync-status-parse subcommand returns "ok".
set -euo pipefail
# Drain argv; we only honor `claude-token sync --json` shape but do not
# enforce it here — the daemon callsite passes a fixed shape.
printf '{"status": "ok", "synced_agents": ["test-agent"]}\n'
EOF
  chmod +x "$SHIM_DIR/bridge-auth.sh"
}

make_auth_shim_failure() {
  cat >"$SHIM_DIR/bridge-auth.sh" <<'EOF'
#!/usr/bin/env bash
# Test shim for bridge-auth.sh — simulates the bridge-auth.sh sync command
# failing (e.g. controller token missing). Exit non-zero so the tick takes
# the status=failed branch.
exit 7
EOF
  chmod +x "$SHIM_DIR/bridge-auth.sh"
}

# bridge-daemon-helpers.py shim: re-uses the real helper. We only need to
# expose `sync-status-parse`, which the real helper provides. We symlink
# rather than re-implement so any future schema change in the real helper
# automatically applies to this smoke.
ln -sf "$SMOKE_REPO_ROOT/bridge-daemon-helpers.py" "$SHIM_DIR/bridge-daemon-helpers.py"

# Driver runs in a subshell with stubs for daemon_info / daemon_warn /
# bridge_audit_log / bridge_with_timeout, points SCRIPT_DIR at the shim,
# sources the extracted function bodies, and invokes the requested action.
DRIVER="$SMOKE_TMP_ROOT/driver.sh"
cat >"$DRIVER" <<'EOF'
#!/usr/bin/env bash
# args: <action: due|tick> [extra args ignored]
set -uo pipefail

# Required env (caller sets all):
#   SHIM_DIR, BRIDGE_STATE_DIR, FUNCS_SH, AUDIT_FILE
: "${SHIM_DIR:?}"
: "${BRIDGE_STATE_DIR:?}"
: "${FUNCS_SH:?}"
: "${AUDIT_FILE:?}"

# Daemon function bodies reference "$SCRIPT_DIR/bridge-auth.sh" and
# "$SCRIPT_DIR/bridge-daemon-helpers.py" — point that at our shim dir.
SCRIPT_DIR="$SHIM_DIR"
BRIDGE_BASH_BIN="${BASH:-bash}"
export BRIDGE_STATE_DIR

# Stubs for daemon-side helpers the function body calls. We capture every
# bridge_audit_log call as one line per row in $AUDIT_FILE so the smoke
# can grep the action + status fields after the call.
daemon_info()  { printf '[info] %s\n' "$*" >&2; }
daemon_warn()  { printf '[warn] %s\n' "$*" >&2; }
bridge_audit_log() {
  # signature: <actor> <action> <target> [--detail k=v ...]
  local actor="$1" action="$2" target="$3"; shift 3 || true
  local row="action=$action actor=$actor target=$target"
  while (( $# )); do
    if [[ "$1" == "--detail" ]]; then
      shift
      row+=" $1"
    fi
    shift || true
  done
  printf '%s\n' "$row" >>"$AUDIT_FILE"
}
# bridge_with_timeout — pass-through (no real timeout binary needed; the
# shim helper returns instantly). Mirrors the test-double in
# tests/codex-composer/smoke.sh.
bridge_with_timeout() {
  # <secs> <label> <cmd> [args...]
  shift 2 || true
  "$@"
}

# Source the extracted function bodies.
# shellcheck source=/dev/null
source "$FUNCS_SH"

action="${1:-}"
case "$action" in
  due)
    if bridge_daemon_periodic_token_sync_due; then
      echo "DUE"
    else
      echo "NOT-DUE"
    fi
    ;;
  tick)
    if bridge_daemon_periodic_token_sync_tick; then
      echo "TICK-OK"
    else
      echo "TICK-FAIL"
    fi
    ;;
  state-file)
    echo "$(bridge_daemon_periodic_token_sync_state_file)"
    ;;
  *)
    echo "unknown action: $action" >&2
    exit 2
    ;;
esac
EOF
chmod +x "$DRIVER"

AUDIT_FILE="$SMOKE_TMP_ROOT/audit.log"
: >"$AUDIT_FILE"

run_driver() {
  # Returns the driver's stdout marker on its own line. The driver exit
  # code is intentionally ignored — the markers (DUE/NOT-DUE, TICK-OK/
  # TICK-FAIL) are the authoritative outcome signal because the driver's
  # final `echo` always exits 0. We use `tail -n 1` to discard stub-side
  # info/warn output that some bash builds emit on stdout when redirected.
  local action="$1"
  local interval="${2:-3600}"
  env \
      SHIM_DIR="$SHIM_DIR" \
      BRIDGE_STATE_DIR="$BRIDGE_STATE_DIR" \
      FUNCS_SH="$FUNCS_SH" \
      AUDIT_FILE="$AUDIT_FILE" \
      BRIDGE_CLAUDE_TOKEN_SYNC_INTERVAL_SECONDS="$interval" \
      BRIDGE_CLAUDE_TOKEN_SYNC_AGENTS="static" \
      bash "$DRIVER" "$action" 2>/dev/null | tail -n 1
}

# Exact-marker assertion helper. `smoke_assert_contains "$out" "DUE"` would
# match "NOT-DUE", so we equality-check the trimmed marker instead.
assert_marker() {
  local marker="$1"
  local expected="$2"
  local ctx="$3"
  smoke_assert_eq "$expected" "$marker" "$ctx"
}

# Resolve the state file path from the production function so the smoke
# stays decoupled from a future state-file-path refactor.
STATE_FILE="$(run_driver state-file)"
[[ -n "$STATE_FILE" ]] || smoke_fail "could not resolve state file path from driver"

# Ensure clean slate.
rm -f "$STATE_FILE"

audit_row_count() {
  grep -c '^action=claude_token_periodic_sync ' "$AUDIT_FILE" 2>/dev/null || true
}

audit_last_row() {
  grep '^action=claude_token_periodic_sync ' "$AUDIT_FILE" 2>/dev/null | tail -n 1
}

# Case A1 — first call from fresh state: due and tick fire, audit + state file.
step_a1_first_call_fires() {
  smoke_log "A1: first call from fresh BRIDGE_STATE_DIR — due + tick + audit"
  make_auth_shim_success
  rm -f "$STATE_FILE"
  : >"$AUDIT_FILE"

  assert_marker "$(run_driver due 3600)" "DUE" "A1 due-check (no state file → must be due)"
  assert_marker "$(run_driver tick 3600)" "TICK-OK" "A1 tick"

  [[ -f "$STATE_FILE" ]] || smoke_fail "A1: state file should be written after tick: $STATE_FILE"
  local count
  count="$(audit_row_count)"
  smoke_assert_eq "1" "$count" "A1: exactly one audit row after first tick"
  local row
  row="$(audit_last_row)"
  smoke_assert_contains "$row" "status=ok" "A1: audit row reflects success"
  smoke_assert_contains "$row" "trigger=periodic" "A1: audit row tags trigger"
  smoke_assert_contains "$row" "agent_scope=static" "A1: audit row tags scope"
  smoke_assert_contains "$row" "interval_seconds=3600" "A1: audit row tags interval"
}

# Case A2 — immediate second call: not due, tick no-ops.
step_a2_immediate_second_call_skips() {
  smoke_log "A2: immediate second call — not-due, tick is a no-op"
  local before_ts before_count
  before_ts="$(cat "$STATE_FILE" 2>/dev/null || printf '0')"
  before_count="$(audit_row_count)"
  [[ -n "$before_ts" && "$before_ts" -gt 0 ]] || smoke_fail "A2 precondition: state file should carry a ts > 0"

  assert_marker "$(run_driver due 3600)" "NOT-DUE" "A2 due-check (elapsed << interval)"
  assert_marker "$(run_driver tick 3600)" "TICK-FAIL" "A2 tick (not-due → no-op)"

  local after_ts after_count
  after_ts="$(cat "$STATE_FILE" 2>/dev/null || printf '0')"
  after_count="$(audit_row_count)"
  smoke_assert_eq "$before_ts" "$after_ts" "A2: state file timestamp must NOT advance when not-due"
  smoke_assert_eq "$before_count" "$after_count" "A2: no new audit row when not-due"
}

# Case A3 — backdate last-sync past interval: due fires again, tick refreshes.
step_a3_overdue_fires_again() {
  smoke_log "A3: backdate last-sync past interval — due + tick + audit row count increments"
  local before_count
  before_count="$(audit_row_count)"
  local backdated
  backdated="$(( $(date +%s) - 10000 ))"   # well past default 3600s
  printf '%s\n' "$backdated" >"$STATE_FILE"

  assert_marker "$(run_driver due 3600)" "DUE" "A3 due-check (elapsed > interval)"
  assert_marker "$(run_driver tick 3600)" "TICK-OK" "A3 tick (overdue → fires)"

  local after_count after_ts
  after_count="$(audit_row_count)"
  after_ts="$(cat "$STATE_FILE" 2>/dev/null || printf '0')"
  (( after_count == before_count + 1 )) || smoke_fail "A3: audit row count should increment by exactly 1 (before=$before_count after=$after_count)"
  (( after_ts > backdated )) || smoke_fail "A3: state file timestamp should refresh past backdated value (backdated=$backdated after=$after_ts)"
}

# Case A4 — bridge-auth.sh failure: status=failed audit row, rc=1, state still updated.
step_a4_sync_failure_records_status_failed() {
  smoke_log "A4: bridge-auth.sh failure — status=failed audit row, no hot-loop"
  make_auth_shim_failure
  # Make it due again.
  local backdated
  backdated="$(( $(date +%s) - 10000 ))"
  printf '%s\n' "$backdated" >"$STATE_FILE"

  local before_count after_count
  before_count="$(audit_row_count)"

  assert_marker "$(run_driver tick 3600)" "TICK-FAIL" "A4 tick (sync failure → rc=1)"

  after_count="$(audit_row_count)"
  (( after_count == before_count + 1 )) || smoke_fail "A4: audit row count should increment by exactly 1 (before=$before_count after=$after_count)"
  local row
  row="$(audit_last_row)"
  smoke_assert_contains "$row" "status=failed" "A4: audit row tags failure"
  smoke_assert_contains "$row" "trigger=periodic" "A4: audit row tags trigger"

  # state-file is refreshed even on failure so a persistent breakage does
  # not hot-loop the daemon. The next due-check should return NOT-DUE.
  local after_ts
  after_ts="$(cat "$STATE_FILE" 2>/dev/null || printf '0')"
  (( after_ts > backdated )) || smoke_fail "A4: state file timestamp should refresh even on failure (backdated=$backdated after=$after_ts)"

  assert_marker "$(run_driver due 3600)" "NOT-DUE" "A4 follow-up due-check (next tick deferred, not hot-looped)"

  # Restore success shim for any subsequent assertions / future steps.
  make_auth_shim_success
}

# Case A5 — interval=0 disables the tick entirely.
step_a5_interval_zero_disables() {
  smoke_log "A5: interval=0 disables the periodic tick"
  # Even a missing state file does not flip due to true when interval=0.
  rm -f "$STATE_FILE"
  assert_marker "$(run_driver due 0)" "NOT-DUE" "A5 due-check with interval=0 must be NOT-DUE"
  assert_marker "$(run_driver tick 0)" "TICK-FAIL" "A5 tick with interval=0 must no-op"
  [[ ! -f "$STATE_FILE" ]] || smoke_fail "A5: disabled tick must not create state file"
}

smoke_run "A1 first call from fresh state fires + writes audit + state file" step_a1_first_call_fires
smoke_run "A2 immediate second call is a no-op" step_a2_immediate_second_call_skips
smoke_run "A3 overdue last-sync triggers another tick" step_a3_overdue_fires_again
smoke_run "A4 sync failure records status=failed and avoids hot-loop" step_a4_sync_failure_records_status_failed
smoke_run "A5 interval=0 disables the periodic tick" step_a5_interval_zero_disables

smoke_log "PASS"
