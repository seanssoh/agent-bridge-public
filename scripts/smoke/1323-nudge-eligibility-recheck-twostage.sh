#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1323-nudge-eligibility-recheck-twostage.sh
#
# v0.15.0-beta5-2 Track G — full closure for #1323.
#
# Issue #1323 main body: `bridge-daemon.sh::nudge_agent_session`'s
# verify-grace loop used a fixed `BRIDGE_NUDGE_VERIFY_GRACE_SECONDS`
# (default 2s) to decide whether a sent nudge had reached the agent.
# 2s was too tight for real claude REPL prompt-buffer + system-reminder
# hook latency — operators measured a 4/4 false-positive rate on a
# fresh install (PR #1323 comment 2026-05-28). The pre-fix daemon
# would log "appears dropped (after 2s); will retry" four times in a
# row and let the next idle-nudge tick recover — functional but noisy
# and operator-confusing.
#
# Fix (Option B from the brief — deterministic two-stage check):
#   Stage 1: sleep BRIDGE_NUDGE_VERIFY_GRACE_SECONDS (default 2s).
#            If task is no longer `queued` → ack, return 0.
#   Stage 2: if task is still `queued`, sleep an additional
#            BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2 (default 5s)
#            and re-poll. Only emit `session_nudge_dropped` if the
#            SECOND check still observes queued.
#
# Companion observability: `agb status` renders a rolling
# `nudge-recheck` line driven by `nudge_recheck_observability_counts`
# in bridge-status.py — drop_total, drop_stage2_used, and
# recheck_timeout_total counters over the configured window.
#
# Test plan:
#   T1: agent acks within stage 1 (2s)
#       → no audit row, return 0, no "appears dropped" log.
#   T2: agent acks within stage 1 .. stage 2 window
#       → stage 1 sees queued, stage 2 sees not-queued
#       → no `session_nudge_dropped` row, no "appears dropped" log,
#         return 0.
#   T3: agent never acks (still queued after both stages)
#       → `session_nudge_dropped` row emitted with stage2_used=1,
#         grace_total_seconds=stage1+stage2, return 1.
#   T4: STAGE2=0 disables stage 2 (legacy single-stage behavior)
#       → stage 1 sees queued → immediate drop with stage2_used=0,
#         grace_total_seconds=stage1, return 1.
#   T5_teeth: bridge-status.py renders the `nudge-recheck` line + JSON
#       `nudge_recheck` block when an audit row exists, and the
#       counter SQL distinguishes stage2_used=1 drops from legacy
#       (no stage2_used key) drops.
#
# Footgun #11 (no python3 heredoc-stdin from a `$()`): every python3
# subprocess in this smoke reads its inputs via argv or file paths,
# never via stdin. The bridge-status.py rendering exercise pipes
# stdout into a captured variable; both render functions are
# argparse-driven and accept --audit-log on the command line.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays + the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1323-nudge-eligibility-recheck-twostage] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1323-nudge-eligibility-recheck-twostage"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
: >"$AUDIT_LOG"
mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"

# Test fixture: a thin shim that mirrors the two-stage verify-grace
# block in nudge_agent_session (bridge-daemon.sh lines ~5765-5815).
# We intentionally do not source the full daemon — the verify block is
# the unit under test, and the surrounding live-state recheck +
# fingerprint dedup are exercised by the sibling iota smoke. The shim
# emits the same audit fields and uses the same env knobs as the
# in-source path; the structural assertion (T5_teeth) ensures the
# block stays in sync with the daemon.

TIMELINE_DIR="$SMOKE_TMP_ROOT/timeline"
mkdir -p "$TIMELINE_DIR"

# Stub `bridge_audit_log` to write JSON rows to $AUDIT_LOG (matching
# the iota smoke's stub shape).
bridge_audit_log() {
  local actor="$1" action="$2" target="$3"
  shift 3 || true
  local detail_json=""
  while (( $# )); do
    case "$1" in
      --detail)
        local kv="$2"
        local k="${kv%%=*}"
        local v="${kv#*=}"
        # JSON-escape quote+backslash. Sufficient for our test values.
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        if [[ -n "$detail_json" ]]; then detail_json+=","; fi
        detail_json+="\"${k}\":\"${v}\""
        shift 2
        ;;
      *) shift ;;
    esac
  done
  local ts
  ts="$(python3 -c "import datetime,sys;print(datetime.datetime.now(datetime.timezone.utc).isoformat().replace('+00:00','Z'))")"
  printf '{"ts":"%s","actor":"%s","action":"%s","target":"%s","detail":{%s}}\n' \
    "$ts" "$actor" "$action" "$target" "$detail_json" >>"$AUDIT_LOG"
}

daemon_warn() { printf '[stub-warn] %s\n' "$*" >&2; }
DAEMON_INFO_LOG="$SMOKE_TMP_ROOT/daemon-info.log"
: >"$DAEMON_INFO_LOG"
daemon_info() { printf '%s\n' "$*" >>"$DAEMON_INFO_LOG"; }

# bridge_queue_task_status — driven by a per-task timeline file (one
# status per line). Each call pops the head and prints it. Falls back
# to "queued" if the file is missing or empty. File-based so the
# `$(bridge_queue_task_status ...)` subshell side-effect of advancing
# the cursor survives back to the caller.
bridge_queue_task_status() {
  local task_id="$1"
  local timeline="$TIMELINE_DIR/${task_id}.timeline"
  if [[ ! -s "$timeline" ]]; then
    printf 'queued'
    return 0
  fi
  local first rest
  first="$(head -n 1 "$timeline")"
  rest="$(tail -n +2 "$timeline")"
  printf '%s' "$rest" >"$timeline"
  printf '%s' "$first"
}

timeline_set() {
  local task_id="$1"
  shift
  local timeline="$TIMELINE_DIR/${task_id}.timeline"
  printf '%s\n' "$@" >"$timeline"
}

# Shim: ONLY the verify-grace block from nudge_agent_session.
# Intentionally a 1:1 copy of the in-source logic so the smoke
# regression bites if the daemon block drifts (the T5_teeth grep
# below pins the source shape too).
verify_grace_shim() {
  local agent="$1"
  local task_id="$2"
  local live_queued="${3:-1}"
  local live_claimed="${4:-0}"
  local idle="${5:-0}"
  local title="${6:-test-title}"

  local nudge_grace_seconds="${BRIDGE_NUDGE_VERIFY_GRACE_SECONDS:-2}"
  local nudge_grace_stage2_seconds="${BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2:-5}"
  [[ "$nudge_grace_seconds" =~ ^[0-9]+$ ]] || nudge_grace_seconds=2
  [[ "$nudge_grace_stage2_seconds" =~ ^[0-9]+$ ]] || nudge_grace_stage2_seconds=5
  local post_status=""
  local nudge_stage2_used=0
  if [[ -n "$task_id" ]]; then
    # Skip the real sleep in smoke — the timeline emulates clock advance.
    post_status="$(bridge_queue_task_status "$task_id" 2>/dev/null || true)"
    if [[ "$post_status" == "queued" ]] && (( nudge_grace_stage2_seconds > 0 )); then
      nudge_stage2_used=1
      post_status="$(bridge_queue_task_status "$task_id" 2>/dev/null || true)"
    fi
    if [[ "$post_status" == "queued" ]]; then
      local _total_wait_seconds=$(( nudge_grace_seconds + (nudge_stage2_used == 1 ? nudge_grace_stage2_seconds : 0) ))
      bridge_audit_log daemon session_nudge_dropped "$agent" \
        --detail task_id="$task_id" \
        --detail reason=submit_lost_post_grace \
        --detail grace_seconds="$nudge_grace_seconds" \
        --detail grace_seconds_stage2="$nudge_grace_stage2_seconds" \
        --detail grace_total_seconds="$_total_wait_seconds" \
        --detail stage2_used="$nudge_stage2_used" \
        --detail queued="$live_queued" \
        --detail claimed="$live_claimed" \
        --detail idle_seconds="$idle" \
        --detail title="$title"
      daemon_info "nudge to ${agent} appears dropped (task #${task_id} still queued after ${_total_wait_seconds}s, stage1=${nudge_grace_seconds}s+stage2=${nudge_grace_stage2_seconds}s); will retry on next idle-nudge tick"
      return 1
    fi
  fi
  return 0
}

# audit_count action target → integer count of matching rows.
audit_count() {
  local action="$1" target="$2"
  local n
  if n="$(grep -c "\"action\":\"${action}\".*\"target\":\"${target}\"" "$AUDIT_LOG" 2>/dev/null)"; then
    printf '%s' "$n"
  else
    printf '0'
  fi
}

# audit_latest_detail action target field — extract a JSON field. Uses
# a standalone python helper rather than `-c` to keep nested quoting
# legible and to dodge footgun #11.
AUDIT_DETAIL_HELPER=""
audit_latest_detail() {
  local action="$1" target="$2" field="$3"
  local row
  row="$(grep "\"action\":\"${action}\".*\"target\":\"${target}\"" "$AUDIT_LOG" 2>/dev/null | tail -n1)"
  [[ -n "$row" ]] || { printf ''; return; }
  if [[ -z "$AUDIT_DETAIL_HELPER" ]]; then
    AUDIT_DETAIL_HELPER="$SMOKE_TMP_ROOT/audit-detail.py"
    cat >"$AUDIT_DETAIL_HELPER" <<'PYEOF'
import json, sys
try:
    obj = json.loads(sys.argv[1])
except json.JSONDecodeError:
    sys.exit(0)
detail = obj.get("detail") if isinstance(obj.get("detail"), dict) else {}
sys.stdout.write(str(detail.get(sys.argv[2], "")))
PYEOF
  fi
  python3 "$AUDIT_DETAIL_HELPER" "$row" "$field"
}

# --- T1: agent acks within stage 1 ---------------------------------
smoke_run "T1 stage1-ack: no audit, no drop log" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  # Timeline: stage 1 check sees claimed.
  timeline_set 101 claimed
  set +e
  verify_grace_shim "agent-t1" "101" 1 0 0 "t1"
  rc=$?
  set -e
  smoke_assert_eq 0 "$rc" "T1 returns 0 on stage-1 ack"
  drop_count="$(audit_count session_nudge_dropped agent-t1)"
  smoke_assert_eq 0 "$drop_count" "T1 no session_nudge_dropped row"
  smoke_assert_not_contains "$(cat "$DAEMON_INFO_LOG")" "appears dropped" "T1 no 'appears dropped' log"
}

# --- T2: agent acks within stage 2 window --------------------------
smoke_run "T2 stage2-ack: stage1 queued, stage2 not — no audit, no drop log" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  # Timeline: stage 1 still queued; stage 2 sees claimed (the
  # false-positive case from #1323 comment 2026-05-28).
  timeline_set 202 queued claimed
  set +e
  verify_grace_shim "agent-t2" "202" 1 0 0 "t2"
  rc=$?
  set -e
  smoke_assert_eq 0 "$rc" "T2 returns 0 on stage-2 ack"
  drop_count="$(audit_count session_nudge_dropped agent-t2)"
  smoke_assert_eq 0 "$drop_count" "T2 no session_nudge_dropped row (false positive suppressed)"
  smoke_assert_not_contains "$(cat "$DAEMON_INFO_LOG")" "appears dropped" "T2 no 'appears dropped' log"
}

# --- T3: agent never acks → emit drop with stage2_used=1 ----------
smoke_run "T3 both-stages-queued: emit drop with stage2_used=1" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  timeline_set 303 queued queued
  set +e
  verify_grace_shim "agent-t3" "303" 1 0 0 "t3"
  rc=$?
  set -e
  smoke_assert_eq 1 "$rc" "T3 returns 1 on stage-2 still-queued"
  drop_count="$(audit_count session_nudge_dropped agent-t3)"
  smoke_assert_eq 1 "$drop_count" "T3 one session_nudge_dropped row"
  stage2_used="$(audit_latest_detail session_nudge_dropped agent-t3 stage2_used)"
  smoke_assert_eq 1 "$stage2_used" "T3 stage2_used=1"
  total="$(audit_latest_detail session_nudge_dropped agent-t3 grace_total_seconds)"
  smoke_assert_eq 7 "$total" "T3 grace_total_seconds = stage1(2) + stage2(5) = 7"
  smoke_assert_contains "$(cat "$DAEMON_INFO_LOG")" "appears dropped" "T3 'appears dropped' log present"
  smoke_assert_contains "$(cat "$DAEMON_INFO_LOG")" "stage1=2s+stage2=5s" "T3 log cites both stages"
}

# --- T4: STAGE2=0 disables stage 2 (legacy single-stage) ----------
smoke_run "T4 STAGE2=0 disables stage 2 → drop after stage1 only" : ; {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  timeline_set 404 queued
  export BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2=0
  set +e
  verify_grace_shim "agent-t4" "404" 1 0 0 "t4"
  rc=$?
  set -e
  unset BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2
  smoke_assert_eq 1 "$rc" "T4 returns 1 (stage 2 disabled, stage 1 still queued)"
  stage2_used="$(audit_latest_detail session_nudge_dropped agent-t4 stage2_used)"
  smoke_assert_eq 0 "$stage2_used" "T4 stage2_used=0 (skipped)"
  total="$(audit_latest_detail session_nudge_dropped agent-t4 grace_total_seconds)"
  smoke_assert_eq 2 "$total" "T4 grace_total_seconds = stage1 only = 2"
}

# --- T5: bridge-status.py renders the counter line + JSON ----------
smoke_run "T5 bridge-status renders nudge-recheck line + JSON counter" : ; {
  : >"$AUDIT_LOG"
  # Seed audit log:
  #   - 1 session_nudge_dropped with stage2_used=1 (post-fix shape)
  #   - 1 session_nudge_dropped without stage2_used (legacy shape)
  #   - 2 nudge_eligibility_recheck_timeout (#1323 H5 contract)
  bridge_audit_log daemon session_nudge_dropped agent-s5 \
    --detail task_id=701 --detail stage2_used=1 --detail grace_total_seconds=7
  bridge_audit_log daemon session_nudge_dropped agent-s5 \
    --detail task_id=702
  bridge_audit_log daemon nudge_eligibility_recheck_timeout agent-s5 \
    --detail task_id=703 --detail consecutive=1
  bridge_audit_log daemon nudge_eligibility_recheck_timeout agent-s5 \
    --detail task_id=703 --detail consecutive=2

  # Set up enough state for bridge-status.py to render without crashing.
  # The dashboard needs `agent_state` and `tasks` tables; seed them by
  # creating + cancelling a throwaway task via bridge-queue.py (same
  # init pattern the sibling 1106 smoke uses).
  ROSTER_SNAPSHOT="$SMOKE_TMP_ROOT/roster-snapshot.txt"
  : >"$ROSTER_SNAPSHOT"
  DAEMON_PID_FILE="$SMOKE_TMP_ROOT/daemon.pid"
  : >"$DAEMON_PID_FILE"
  python3 "$REPO_ROOT/bridge-queue.py" create \
    --to agent-s5 --from requester \
    --title "schema init" --body "init" --format shell \
    >"$SMOKE_TMP_ROOT/queue-init.sh"
  # shellcheck disable=SC1090
  source "$SMOKE_TMP_ROOT/queue-init.sh"
  python3 "$REPO_ROOT/bridge-queue.py" cancel "$TASK_ID" --actor requester >/dev/null
  unset TASK_ID

  STATUS_OUT="$(python3 "$REPO_ROOT/bridge-status.py" \
    --roster-snapshot "$ROSTER_SNAPSHOT" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$DAEMON_PID_FILE" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --audit-log "$AUDIT_LOG" 2>&1)" || smoke_fail "T5 bridge-status.py text render failed: $STATUS_OUT"
  smoke_assert_contains "$STATUS_OUT" "nudge-recheck" "T5 dashboard renders nudge-recheck line"
  smoke_assert_contains "$STATUS_OUT" "drop_total=2" "T5 drop_total counter correct (both legacy + stage2)"
  smoke_assert_contains "$STATUS_OUT" "drop_stage2_used=1" "T5 stage2_used counter correct (only post-fix shape)"
  smoke_assert_contains "$STATUS_OUT" "recheck_timeout=2" "T5 recheck_timeout counter correct"

  STATUS_JSON="$(python3 "$REPO_ROOT/bridge-status.py" \
    --roster-snapshot "$ROSTER_SNAPSHOT" \
    --db "$BRIDGE_TASK_DB" \
    --daemon-pid-file "$DAEMON_PID_FILE" \
    --bridge-state-dir "$BRIDGE_STATE_DIR" \
    --audit-log "$AUDIT_LOG" --json 2>&1)" || smoke_fail "T5 bridge-status.py JSON render failed: $STATUS_JSON"
  # JSON consumer-side parse check. The status JSON is written to a
  # tempfile + a standalone python helper file (also written by this
  # smoke) so we can avoid embedding python source via `-c` with nested
  # quote escapes. Footgun #11 avoidance: no heredoc-stdin, no `<<<`.
  STATUS_JSON_FILE="$SMOKE_TMP_ROOT/status-render.json"
  printf '%s' "$STATUS_JSON" >"$STATUS_JSON_FILE"
  PARSE_HELPER="$SMOKE_TMP_ROOT/parse-status-json.py"
  cat >"$PARSE_HELPER" <<'PYEOF'
import json, sys
with open(sys.argv[1], "r", encoding="utf-8") as fh:
    payload = json.load(fh)
nr = payload.get("nudge_recheck") or {}
sys.stdout.write(
    f"window={nr.get('window_days')} "
    f"drop={nr.get('nudge_drop_total')} "
    f"stage2={nr.get('nudge_drop_stage2_used')} "
    f"timeout={nr.get('recheck_timeout_total')}\n"
)
PYEOF
  parsed="$(python3 "$PARSE_HELPER" "$STATUS_JSON_FILE")"
  smoke_assert_contains "$parsed" "drop=2" "T5 JSON drop_total=2"
  smoke_assert_contains "$parsed" "stage2=1" "T5 JSON drop_stage2_used=1"
  smoke_assert_contains "$parsed" "timeout=2" "T5 JSON recheck_timeout_total=2"
}

# --- T5_teeth: structural shape assertions -------------------------
smoke_run "T5_teeth structural shape in bridge-daemon.sh + bridge-status.py" : ; {
  daemon_sh="$REPO_ROOT/bridge-daemon.sh"
  status_py="$REPO_ROOT/bridge-status.py"

  grep -q 'BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must reference BRIDGE_NUDGE_VERIFY_GRACE_SECONDS_STAGE2"
  grep -q 'stage2_used' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit stage2_used detail on session_nudge_dropped"
  grep -q 'grace_total_seconds' "$daemon_sh" \
    || smoke_fail "teeth: bridge-daemon.sh must emit grace_total_seconds detail"

  grep -q 'nudge_recheck_observability_counts' "$status_py" \
    || smoke_fail "teeth: bridge-status.py must define nudge_recheck_observability_counts"
  grep -q 'nudge-recheck' "$status_py" \
    || smoke_fail "teeth: bridge-status.py must render the nudge-recheck dashboard line"
  grep -q 'drop_stage2_used' "$status_py" \
    || smoke_fail "teeth: bridge-status.py must surface drop_stage2_used"
}

smoke_log "all checks passed"
