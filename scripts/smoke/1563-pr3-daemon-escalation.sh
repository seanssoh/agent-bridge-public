#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1563-pr3-daemon-escalation.sh — #9819 A/B (rc2 #1563 PR-3):
# daemon T2 "escalate, don't self-heal".
#
# This PR adds admin-liveness escalation to the daemon: when the daemon's
# mechanical liveness check determines the ADMIN AGENT itself is down (no
# live tmux session AND the daemon heartbeat is stale past a grace
# threshold), it ESCALATES — enqueues a durable created_by=daemon task to
# the admin's codex pair (patch-dev) — rather than restarting the admin
# itself. It also routes an MCP-liveness give-up to an admin task and
# replaces the swallowed `|| true` on the escalation task-create with a
# visible `daemon_escalation_task_create_failed` audit + retained retry
# state.
#
# THE CRUX — the flapping-monitor irony is the #1 risk. The admin-liveness
# predicate (bridge_daemon_admin_liveness_class) is deliberately conservative:
# a BUSY / long-turn admin (activity_state `working`) or an IDLE admin with a
# live session is NEVER classified down. "down" requires no live session AND a
# stale daemon heartbeat. Reverting the predicate to "patch claimed work" /
# "patch not idle" must FAIL the negative-control test (P2).
#
# Test plan (all in an isolated BRIDGE_HOME; never touches live runtime):
#   P1  admin-down → escalate. activity_state `stopped` + heartbeat stale past
#       threshold + dev pair exists → bridge_daemon_admin_liveness_class
#       returns `down`; process_daemon_admin_liveness_escalation files exactly
#       one durable task to patch-dev + emits daemon_admin_down_escalated.
#   P2  busy-admin → NO escalate (NEGATIVE CONTROL / teeth). activity_state
#       `working` (and separately `idle`) → class `alive`, NO task, NO audit
#       escalation row. (Also: fresh/stale-but-active variants stay non-down.)
#   P3  task-create-fail → audit + retain retry. mock the CLI to rc!=0 → a
#       daemon_escalation_task_create_failed audit row is emitted, the cooldown
#       marker is NOT written (retry retained), and a second tick re-attempts
#       (no hot-loop — cooldown gates only AFTER a success).
#   P4  patch-dev routing only after admin-down: a fresh admin (no heartbeat
#       state) stays `unknown` (grace) so no escalation fires even with a dev
#       pair present.
#   P5  MCP-liveness giveup → admin task: bridge_daemon_mcp_giveup_escalate_admin
#       files an admin task + emits plugin_mcp_liveness_giveup_escalated;
#       task-create-fail retains retry; admin==affected agent is audit-only.
#   P_teeth: structural reverts (claimed-work predicate; swallowed || true)
#       are pinned to fail.
#
# Footgun #11 / heredoc-ban: this smoke uses ZERO `bash -s <<TAG` /
# `python3 - <<PY` heredoc-stdin. Function bodies are extracted with awk
# (the functions under test contain no inner heredocs — their body files are
# written with `{ printf ...; } >file`, whose closing `}` is indented and so
# never collides with the column-0 `^}$` function terminator). Inline python
# is `python3 -c '<script>' argv` only.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash" "${BASH4_BIN:-}"; do
    if [[ -n "$_candidate" && -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1563-pr3-daemon-escalation] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1563-pr3-daemon-escalation"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"

ADMIN="patch"
ADMIN_DEV="patch-dev"

# Tight thresholds so we exercise the staleness + cooldown logic without
# minute-scale sleeps. The defaults (900 / 1800) are asserted structurally.
export BRIDGE_ADMIN_AGENT_ID="$ADMIN"
export BRIDGE_DAEMON_ADMIN_DOWN_STALE_SECS=300
export BRIDGE_DAEMON_ADMIN_DOWN_COOLDOWN_SECS=1800
export BRIDGE_DAEMON_MCP_GIVEUP_ADMIN_COOLDOWN_SECS=1800

# ---------------------------------------------------------------------------
# Extract the functions under test from bridge-daemon.sh via awk (no
# heredoc-stdin). Each function spans `^name() {` to the first column-0 `^}$`.
# ---------------------------------------------------------------------------
extract_fn() {
  local name="$1"
  awk -v fn="$name" '
    $0 ~ "^"fn"\\(\\) \\{" { capture=1 }
    capture { print }
    capture && /^}$/ { capture=0; exit }
  ' "$REPO_ROOT/bridge-daemon.sh"
}

FUNCS_FILE="$SMOKE_TMP_ROOT/daemon-funcs.sh"
: >"$FUNCS_FILE"
for fn in \
  bridge_daemon_admin_liveness_escalation_state_dir \
  bridge_daemon_admin_liveness_marker_file \
  bridge_daemon_resolve_admin_dev_agent \
  bridge_daemon_admin_liveness_class \
  process_daemon_admin_liveness_escalation \
  bridge_daemon_mcp_giveup_escalate_admin
do
  body="$(extract_fn "$fn")"
  [[ -n "$body" ]] || smoke_fail "could not extract ${fn} from bridge-daemon.sh"
  printf '%s\n\n' "$body" >>"$FUNCS_FILE"
done

# ---------------------------------------------------------------------------
# Stub primitives the extracted functions call. Defined BEFORE sourcing so
# the helpers bind against these.
# ---------------------------------------------------------------------------
AUDIT_LOG="$SMOKE_TMP_ROOT/audit.jsonl"
: >"$AUDIT_LOG"

bridge_audit_log() {
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_csv=""
  while (( $# )); do
    case "$1" in
      --detail)
        [[ -n "$detail_csv" ]] && detail_csv+=";"
        detail_csv+="$2"
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '{"action":"%s","target":"%s","detail":"%s"}\n' \
    "$action" "$target" "$detail_csv" >>"$AUDIT_LOG"
}
audit_count() { grep -c "\"action\":\"$1\"" "$AUDIT_LOG" 2>/dev/null || true; }
audit_reset() { : >"$AUDIT_LOG"; }

daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
daemon_info() { printf '[stub-info] %s\n' "$*"; }
daemon_log_event() { printf '[stub-log] %s\n' "$*"; }

# Minimal source-the-file stub (the real helper validates; the smoke only
# needs the source semantics so HEARTBEAT_UPDATED_TS lands in caller scope).
daemon_source_state_file() {
  local file="$1"
  [[ -f "$file" ]] || return 1
  # shellcheck source=/dev/null
  source "$file" 2>/dev/null || return 1
  return 0
}

# Roster predicate: only ADMIN + ADMIN_DEV exist (unless a test overrides).
declare -gA _SMOKE_AGENT_EXISTS=()
_SMOKE_AGENT_EXISTS["$ADMIN"]=1
_SMOKE_AGENT_EXISTS["$ADMIN_DEV"]=1
bridge_agent_exists() {
  [[ "${_SMOKE_AGENT_EXISTS[$1]:-0}" == "1" ]]
}

# activity_state — driven by a single global so each test pins the predicate
# input directly without a live tmux session.
_SMOKE_ACTIVITY_STATE="stopped"
bridge_agent_heartbeat_activity_state() {
  printf '%s' "$_SMOKE_ACTIVITY_STATE"
}

# Heartbeat state file path under the isolated state dir.
bridge_agent_heartbeat_state_file() {
  printf '%s/heartbeat/%s.env' "$BRIDGE_STATE_DIR" "$1"
}
# Seed / clear HEARTBEAT_UPDATED_TS for the admin.
seed_heartbeat() {
  local agent="$1" updated_ts="$2"
  local f
  f="$(bridge_agent_heartbeat_state_file "$agent")"
  mkdir -p "$(dirname "$f")"
  {
    printf 'HEARTBEAT_UPDATED_TS=%s\n' "$updated_ts"
    printf 'HEARTBEAT_NEXT_TS=%s\n' "$((updated_ts + 300))"
  } >"$f"
}
clear_heartbeat() {
  rm -f "$(bridge_agent_heartbeat_state_file "$1")" 2>/dev/null || true
}

# Mock the `agent-bridge` CLI under BRIDGE_HOME so target_bridge resolves to
# it. Its `task create` rc is controlled by a sentinel file so a test can
# force a transient failure.
MOCK_BIN="$BRIDGE_HOME/agent-bridge"
TASK_LOG="$SMOKE_TMP_ROOT/task-create.log"
RC_FILE="$SMOKE_TMP_ROOT/task-create.rc"
: >"$TASK_LOG"
printf '0' >"$RC_FILE"
{
  printf '#!/usr/bin/env bash\n'
  printf 'if [[ "${1:-}" == "task" && "${2:-}" == "create" ]]; then\n'
  printf '  printf "%%s\\n" "$*" >>"%s"\n' "$TASK_LOG"
  printf '  exit "$(cat "%s" 2>/dev/null || printf 0)"\n' "$RC_FILE"
  printf 'fi\n'
  printf 'exit 0\n'
} >"$MOCK_BIN"
chmod 0755 "$MOCK_BIN"
task_create_count() { grep -c . "$TASK_LOG" 2>/dev/null || true; }
task_log_reset() { : >"$TASK_LOG"; }
set_task_rc() { printf '%s' "$1" >"$RC_FILE"; }

# process_daemon_admin_liveness_escalation reads $SCRIPT_DIR for the fallback
# CLI — pin it so the BRIDGE_HOME mock is the resolved target.
export SCRIPT_DIR="$REPO_ROOT"

# Source the extracted helpers into THIS shell.
# shellcheck source=/dev/null
source "$FUNCS_FILE"

reset_state() {
  audit_reset
  task_log_reset
  set_task_rc 0
  rm -rf "$BRIDGE_STATE_DIR/admin-liveness-escalations" 2>/dev/null || true
}

# ===========================================================================
# P1 — admin-down → escalate
# ===========================================================================
step_p1_admin_down_escalates() {
  smoke_log "P1: admin down (no session + stale heartbeat) → escalate to patch-dev"
  reset_state
  _SMOKE_ACTIVITY_STATE="stopped"
  local now stale
  now="$(date +%s)"
  stale=$(( now - 600 ))   # 600s > 300s threshold
  seed_heartbeat "$ADMIN" "$stale"

  # Predicate classifies down.
  local class
  class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
  smoke_assert_eq "down" "$class" "P1: predicate must classify a stopped+stale admin as down"

  process_daemon_admin_liveness_escalation || true

  smoke_assert_eq "1" "$(task_create_count)" "P1: exactly one durable task enqueued"
  smoke_assert_contains "$(cat "$TASK_LOG")" "--to $ADMIN_DEV" "P1: task routed to patch-dev"
  smoke_assert_contains "$(cat "$TASK_LOG")" "--from daemon" "P1: task created_by=daemon"
  smoke_assert_contains "$(cat "$TASK_LOG")" "--force" "P1: task uses --force (stopped recipient wake)"
  smoke_assert_eq "1" "$(audit_count daemon_admin_down_escalated)" "P1: daemon_admin_down_escalated audit row emitted"

  # Cooldown: a second immediate tick does NOT re-escalate.
  process_daemon_admin_liveness_escalation || true
  smoke_assert_eq "1" "$(task_create_count)" "P1: cooldown suppresses a second escalation within the window"

  smoke_log "P1 PASS — admin-down escalates once, routed to patch-dev, cooldown honored"
}

# ===========================================================================
# P2 — busy-admin → NO escalate (NEGATIVE CONTROL / teeth)
# ===========================================================================
step_p2_busy_admin_no_escalate() {
  smoke_log "P2: busy/idle admin → class alive → NO escalation (the flapping-monitor guard)"
  local now stale
  now="$(date +%s)"
  stale=$(( now - 9999 ))   # heartbeat VERY stale — but session is live, so NOT down

  # A long-turn admin deep in a tool call: activity_state working.
  for state in working starting picker_blocked idle; do
    reset_state
    _SMOKE_ACTIVITY_STATE="$state"
    seed_heartbeat "$ADMIN" "$stale"
    local class
    class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
    smoke_assert_eq "alive" "$class" "P2: activity_state=$state must classify alive (NEVER down), even with a stale heartbeat"

    process_daemon_admin_liveness_escalation || true
    smoke_assert_eq "0" "$(task_create_count)" "P2: activity_state=$state → NO escalation task"
    smoke_assert_eq "0" "$(audit_count daemon_admin_down_escalated)" "P2: activity_state=$state → NO escalation audit row"
  done

  smoke_log "P2 PASS — a busy/long-turn or idle-but-alive admin is never escalated"
}

# ===========================================================================
# P2-teeth — reverting the predicate to a non-conservative signal must break.
# We simulate the "claimed work / not idle" reversion by asserting the
# CURRENT predicate treats `working` as alive. A predicate that classified
# `working` (busy) as down would fire P1-style on the busy case — the assert
# above is the teeth. Here we add a structural pin: the source must NOT key
# the down decision on a "claimed"/"not idle" token.
# ===========================================================================
step_p2_teeth_source_shape() {
  smoke_log "P2-teeth: predicate source must not gate down on claimed/not-idle"
  local body
  body="$(extract_fn bridge_daemon_admin_liveness_class)"
  # The conservative predicate keys on activity_state stopped/unknown + a
  # heartbeat staleness compare. A reversion to claim-state would introduce a
  # `claimed`/`idle != ` style gate as the DOWN trigger. Pin that the down
  # path is driven by the heartbeat-staleness compare, not a claim token.
  smoke_assert_contains "$body" "stale_secs" "P2-teeth: predicate must use a heartbeat staleness threshold"
  smoke_assert_contains "$body" "HEARTBEAT_UPDATED_TS" "P2-teeth: predicate must read the daemon heartbeat timestamp"
  smoke_assert_not_contains "$body" "claimed" "P2-teeth: predicate must NOT key the down decision on a 'claimed' token"
  smoke_log "P2-teeth PASS — predicate is heartbeat-staleness driven, not claim-state driven"
}

# ===========================================================================
# P3 — task-create-fail → audit + retain retry (teeth for the swallowed ||true)
# ===========================================================================
step_p3_task_create_fail_retains_retry() {
  smoke_log "P3: escalation task-create failure → audit + retained retry (no marker, no hot-loop)"
  reset_state
  _SMOKE_ACTIVITY_STATE="stopped"
  local now stale
  now="$(date +%s)"
  stale=$(( now - 600 ))
  seed_heartbeat "$ADMIN" "$stale"
  set_task_rc 1   # force a transient queue failure

  process_daemon_admin_liveness_escalation || true

  smoke_assert_eq "1" "$(task_create_count)" "P3: one create attempt was made"
  smoke_assert_eq "1" "$(audit_count daemon_escalation_task_create_failed)" "P3: daemon_escalation_task_create_failed audit row emitted"
  smoke_assert_eq "0" "$(audit_count daemon_admin_down_escalated)" "P3: NO success audit row on failure"

  # Retry state retained: the cooldown marker must NOT exist, so the next tick
  # re-attempts (the swallowed-|| true bug would have just dropped it; the
  # cooldown marker would only be written on success).
  local marker="$BRIDGE_STATE_DIR/admin-liveness-escalations/${ADMIN}.ts"
  [[ ! -f "$marker" ]] || smoke_fail "P3: cooldown marker must NOT be written on task-create failure (retry must be retained)"

  # Next tick (still failing) re-attempts — proves no silent drop. This is
  # bounded by the caller's tick cadence (no hot-loop inside one tick).
  process_daemon_admin_liveness_escalation || true
  smoke_assert_eq "2" "$(task_create_count)" "P3: next tick re-attempts the escalation (retry retained)"

  # Now let it succeed: the marker is written and a third tick is suppressed.
  set_task_rc 0
  process_daemon_admin_liveness_escalation || true
  smoke_assert_eq "3" "$(task_create_count)" "P3: the succeeding attempt fires"
  [[ -f "$marker" ]] || smoke_fail "P3: cooldown marker must be written AFTER a successful escalation"
  smoke_assert_eq "1" "$(audit_count daemon_admin_down_escalated)" "P3: success audit row emitted once on success"

  smoke_log "P3 PASS — failure is visible + retained; success arms the cooldown"
}

# ===========================================================================
# P3-teeth — the source must NOT swallow the task-create result.
# ===========================================================================
step_p3_teeth_no_swallow() {
  smoke_log "P3-teeth: escalation task-create must not be swallowed with || true"
  local body
  body="$(extract_fn process_daemon_admin_liveness_escalation)"
  smoke_assert_contains "$body" "daemon_escalation_task_create_failed" "P3-teeth: failure branch must emit daemon_escalation_task_create_failed"
  # The task create must be gated by an `if ... task create ...; then` so the
  # failure path is reachable — a `task create ... || true` would make the
  # else-branch dead. Pin the if-create shape.
  smoke_assert_contains "$body" "task create" "P3-teeth: must call task create"
  smoke_assert_not_contains "$body" "task create --to \"\$dev_target\" --priority high --from daemon --title" "P3-teeth: guard against a one-line swallowed create"
  smoke_log "P3-teeth PASS — failure visibility branch is present"
}

# ===========================================================================
# P4 — fresh admin (no heartbeat state) stays unknown (grace) → no escalate
# ===========================================================================
step_p4_fresh_admin_grace() {
  smoke_log "P4: fresh admin with no heartbeat state → unknown (grace), no escalation"
  reset_state
  _SMOKE_ACTIVITY_STATE="stopped"
  clear_heartbeat "$ADMIN"
  local now class
  now="$(date +%s)"
  class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
  smoke_assert_eq "unknown" "$class" "P4: no heartbeat state → unknown (do not false-positive on a host the daemon just started watching)"

  process_daemon_admin_liveness_escalation || true
  smoke_assert_eq "0" "$(task_create_count)" "P4: grace window → NO escalation task"

  # A recent-but-stopped heartbeat (within the grace window) is also not down.
  seed_heartbeat "$ADMIN" "$(( now - 60 ))"   # 60s < 300s threshold
  class="$(bridge_daemon_admin_liveness_class "$ADMIN" "$now" 300)"
  smoke_assert_eq "unknown" "$class" "P4: stopped but heartbeat fresh-within-grace → unknown, not down"

  smoke_log "P4 PASS — grace window suppresses false positives"
}

# ===========================================================================
# P4b — no dev pair provisioned → audit-only, retry retained (no marker)
# ===========================================================================
step_p4b_no_dev_pair_audit_only() {
  smoke_log "P4b: admin down but no codex pair provisioned → audit-only, no task, retry retained"
  reset_state
  _SMOKE_ACTIVITY_STATE="stopped"
  local now
  now="$(date +%s)"
  seed_heartbeat "$ADMIN" "$(( now - 600 ))"
  # Remove the dev pair from the roster for this case.
  unset '_SMOKE_AGENT_EXISTS[patch-dev]'

  process_daemon_admin_liveness_escalation || true
  smoke_assert_eq "0" "$(task_create_count)" "P4b: no dev pair → no task created"
  smoke_assert_eq "1" "$(audit_count daemon_admin_down_no_dev_pair)" "P4b: daemon_admin_down_no_dev_pair audit emitted"
  local marker="$BRIDGE_STATE_DIR/admin-liveness-escalations/${ADMIN}.ts"
  [[ ! -f "$marker" ]] || smoke_fail "P4b: must NOT arm cooldown when there is nowhere to route (retry retained)"

  # Restore the dev pair for subsequent tests.
  _SMOKE_AGENT_EXISTS["$ADMIN_DEV"]=1
  smoke_log "P4b PASS — missing pair surfaces audit-only and retains retry"
}

# ===========================================================================
# P5 — MCP-liveness giveup → admin task
# ===========================================================================
step_p5_mcp_giveup_escalates() {
  smoke_log "P5: MCP-liveness giveup → admin task + audit; failure retains retry; admin-self is audit-only"
  reset_state
  local now="$(date +%s)"

  bridge_daemon_mcp_giveup_escalate_admin "worker-a" "plugin:teams@agent-bridge" "$now" || true
  smoke_assert_eq "1" "$(task_create_count)" "P5: one admin task enqueued on giveup"
  smoke_assert_contains "$(cat "$TASK_LOG")" "--to $ADMIN" "P5: routed to admin"
  smoke_assert_contains "$(cat "$TASK_LOG")" "[mcp-giveup]" "P5: task titled [mcp-giveup]"
  smoke_assert_eq "1" "$(audit_count plugin_mcp_liveness_giveup_escalated)" "P5: plugin_mcp_liveness_giveup_escalated audit emitted"

  # Cooldown: a second giveup for the same agent within the window is silent.
  bridge_daemon_mcp_giveup_escalate_admin "worker-a" "plugin:teams@agent-bridge" "$now" || true
  smoke_assert_eq "1" "$(task_create_count)" "P5: cooldown suppresses a second giveup escalation for the same agent"

  # Failure path retains retry (no marker) for a DIFFERENT agent.
  reset_state
  set_task_rc 1
  bridge_daemon_mcp_giveup_escalate_admin "worker-b" "plugin:ms365@agent-bridge" "$now" || true
  smoke_assert_eq "1" "$(audit_count daemon_escalation_task_create_failed)" "P5: giveup task-create failure emits daemon_escalation_task_create_failed"
  local gmarker="$BRIDGE_STATE_DIR/admin-liveness-escalations/mcp-giveup/worker-b.ts"
  [[ ! -f "$gmarker" ]] || smoke_fail "P5: giveup marker must NOT be written on failure (retry retained)"
  set_task_rc 0
  bridge_daemon_mcp_giveup_escalate_admin "worker-b" "plugin:ms365@agent-bridge" "$now" || true
  [[ -f "$gmarker" ]] || smoke_fail "P5: giveup marker must be written after a successful escalation"

  # admin==affected agent: feedback-loop guard → audit-only, no task.
  reset_state
  bridge_daemon_mcp_giveup_escalate_admin "$ADMIN" "plugin:teams@agent-bridge" "$now" || true
  smoke_assert_eq "0" "$(task_create_count)" "P5: admin==affected agent → no self-task"
  smoke_assert_eq "1" "$(audit_count plugin_mcp_liveness_giveup_admin_self)" "P5: admin-self giveup is audit-only"

  smoke_log "P5 PASS — MCP giveup escalates to admin, retains retry on failure, feedback-loop guarded"
}

# ===========================================================================
# P6 — wiring: the tick is registered in cmd_sync_cycle (no real daemon boot).
# A bare-home real-daemon boot is intentionally NOT attempted here (clean-Linux
# bridge_load_roster under set -e cannot boot in a bare BRIDGE_HOME). We assert
# the tick wiring statically instead — skip-loud, never fail.
# ===========================================================================
step_p6_tick_wired() {
  smoke_log "P6: admin-liveness tick is wired into cmd_sync_cycle"
  if grep -q 'process_daemon_admin_liveness_escalation' "$REPO_ROOT/bridge-daemon.sh" \
     && grep -q 'BRIDGE_DAEMON_LAST_STEP="admin_liveness_escalation"' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_log "P6 PASS — tick registered with a BRIDGE_DAEMON_LAST_STEP marker"
  else
    smoke_fail "P6: process_daemon_admin_liveness_escalation tick is not wired into cmd_sync_cycle"
  fi
  # MCP-giveup escalation is invoked from the giveup arm.
  if grep -q 'bridge_daemon_mcp_giveup_escalate_admin "\$agent" "\$missing" "\$now_ts"' "$REPO_ROOT/bridge-daemon.sh"; then
    smoke_log "P6 PASS — MCP-giveup escalation invoked from the giveup arm"
  else
    smoke_fail "P6: bridge_daemon_mcp_giveup_escalate_admin is not invoked from the giveup arm"
  fi
}

# ===========================================================================
# P6b — giveup-arm placement teeth (codex r1 finding). The escalation call
# MUST live in the OUTER `restart_attempts >= max_restarts` branch, NOT inside
# the one-shot `restart_attempts == max_restarts` block. The sentinel bump to
# max+1 means the one-shot block fires exactly once; if the escalation were
# nested there, a transient task-create failure on that single tick would
# NEVER be retried (the retry-retention would be dead). Pin that the call is
# OUTSIDE the one-shot block so the latched-giveup re-tick can retry.
# ===========================================================================
step_p6b_giveup_placement() {
  smoke_log "P6b: MCP-giveup escalation call is in the OUTER latched-giveup branch (retry survives the sentinel bump)"
  # Extract the bridge_report_plugin_liveness_miss body and locate the giveup
  # block. The one-shot inner block opens at `if (( restart_attempts == max_restarts )); then`
  # and closes at the next `fi`. The escalation call must appear AFTER that
  # closing `fi` (i.e., still inside the outer `restart_attempts >= max` block
  # but not gated by the one-shot).
  local body
  body="$(extract_fn bridge_report_plugin_liveness_miss)"
  [[ -n "$body" ]] || smoke_fail "P6b: could not extract bridge_report_plugin_liveness_miss"

  # Line of the one-shot close `fi` (the first `fi` after the
  # `== max_restarts` open) vs the escalation call line.
  local oneshot_close_line escalate_line
  oneshot_close_line="$(printf '%s\n' "$body" | awk '
    /restart_attempts == max_restarts \)\); then/ { inblk=1; next }
    inblk && /^[[:space:]]*fi[[:space:]]*$/ { print NR; exit }
  ')"
  escalate_line="$(printf '%s\n' "$body" | grep -n 'bridge_daemon_mcp_giveup_escalate_admin "\$agent" "\$missing" "\$now_ts"' | head -n1 | cut -d: -f1)"

  [[ -n "$oneshot_close_line" ]] || smoke_fail "P6b: could not locate the one-shot 'attempts == max' close fi"
  [[ -n "$escalate_line" ]] || smoke_fail "P6b: could not locate the giveup escalation call"
  if (( escalate_line > oneshot_close_line )); then
    smoke_log "P6b PASS — escalation call (line $escalate_line) is AFTER the one-shot close fi (line $oneshot_close_line): retry survives the sentinel bump"
  else
    smoke_fail "P6b: escalation call (line $escalate_line) is INSIDE the one-shot 'attempts == max' block (close fi line $oneshot_close_line) — a first-tick task-create failure would never be retried"
  fi
}

smoke_run "P1 admin-down → escalate"            step_p1_admin_down_escalates
smoke_run "P2 busy-admin → NO escalate"          step_p2_busy_admin_no_escalate
smoke_run "P2-teeth predicate shape"             step_p2_teeth_source_shape
smoke_run "P3 task-create-fail retains retry"    step_p3_task_create_fail_retains_retry
smoke_run "P3-teeth no-swallow"                  step_p3_teeth_no_swallow
smoke_run "P4 fresh-admin grace"                 step_p4_fresh_admin_grace
smoke_run "P4b no-dev-pair audit-only"           step_p4b_no_dev_pair_audit_only
smoke_run "P5 MCP-giveup → admin task"           step_p5_mcp_giveup_escalates
smoke_run "P6 tick wiring"                       step_p6_tick_wired
smoke_run "P6b giveup-arm placement teeth"       step_p6b_giveup_placement

smoke_log "ALL PASS — 1563-pr3-daemon-escalation"
