#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/2179-idle-nudge-durable-respool.sh — Issue #2179.
#
# Upstream bug (fleet-wide, 0.17.0-beta5): an active + idle claude agent fails
# to claim a queued task. The daemon nudge (nudge_agent_session in
# bridge-daemon.sh) types the ACTION-REQUIRED payload + C-m into a pane that
# momentarily shows a clean prompt while the agent is logically busy mid-turn
# on its already-claimed task (the narrow between-tool-call window). The submit
# never lands, the task stays `queued`, and — because every subsequent
# idle-nudge tick re-hits the same mid-turn race — recovery waits ~30 min for
# the unclaimed-task escalation. The audit records:
#   session_nudge_dropped reason=submit_lost_post_grace notify_status=miss
#   grace_total=5s stage2_used=1 idle_seconds=1-2 claimed=1
# `agent-bridge urgent <agent>` recovers ~100% only because the operator fires
# it once the agent is genuinely idle at a clean prompt.
#
# Fix (codex-agreed Option A, daemon-nudge-scoped, additive): after the
# verify-grace check finds the task STILL `queued` + blocker=`none` for a
# claude agent, capture the live pane and distinguish a mid-turn/false-idle
# drop (bridge_tmux_claude_capture_is_midturn — the banner is the live tail)
# from a clean prompt miss. On the mid-turn case, DURABLY re-spool the nudge
# via the EXISTING pending-attention path (bridge_tmux_pending_attention_
# append) so the daemon flush loop re-delivers on the NEXT genuine idle
# transition — the flush's own busy gate refuses to clobber a still-mid-turn
# session, and it re-derives the payload against the LIVE queue and drops it
# (rederive rc=2) the instant the task is claimed. Idempotency / lease: append
# at most ONE spooled copy per agent (skip when the spool already holds an
# entry) so repeated drop ticks never accumulate duplicate deliveries. The
# task stays `queued`, so the unclaimed-task escalation is never suppressed.
# urgent/general submit semantics are byte-unchanged (this is detection-only —
# NO key-sending in the verification path).
#
# Test plan:
#   T1 — mid-turn drop RE-SPOOLS: blocker=none, claude, live mid-turn banner →
#        the drop block appends exactly ONE pending-attention entry, sets
#        respooled=1 / respool_reason=midturn_respooled on the audit row, and
#        returns 1 (still a drop — the task stays queued for durable delivery).
#   T2 — clean prompt miss does NOT re-spool: blocker=none, claude, NO live
#        banner (clean composer) → no spool entry, respooled=0, legacy behavior.
#   T3 — idempotency / single-copy lease: a SECOND mid-turn drop for the same
#        agent while a spool entry already exists appends NO second copy
#        (respool_reason=midturn_spool_nonempty, respooled=0). Exactly one
#        durable copy survives.
#   T4 — re-spool retries on next genuine idle: draining the spool (what the
#        daemon flush does) yields the durable copy, and it re-renders as a
#        queue-nudge (bridge_tmux_pending_attention_is_queue_nudge) so the
#        flush loop's re-derive-against-live-queue path can pick it up on the
#        next idle transition.
#   T5 — blocker/modal/copy-mode NON-regression: when a modal owns the input
#        (_blocker_state != none) the drop is NEVER re-spooled — the modal
#        reason (modal_<state>) stays operator-actionable and respooled=0.
#   T6 — #22672 compat + escalation not suppressed: the re-spool decision runs
#        only AFTER a nudge was attempted and dropped, keys nothing, and leaves
#        the task `queued` (return 1) — orthogonal to any busy-serial
#        pre-nudge suppression and never claims/mutates the task.
#   T7_teeth — structural shape in bridge-daemon.sh: the drop block routes the
#        mid-turn respool through bridge_tmux_claude_capture_is_midturn, guards
#        on blocker=none + claude engine, uses the single-copy count gate, and
#        emits the respooled / respool_reason audit detail. A refactor that
#        drops any of these trips this.
#
# Footgun #11 (heredoc-stdin deadlock class): this fixture stages every pane
# fixture as a plain string local and passes them by argv; no heredoc-stdin
# into a subprocess and no `<<<` here-string into a bridge function.

set -euo pipefail

# Re-exec under Bash 4+ for associative arrays + the bridge libs.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:2179-idle-nudge-durable-respool] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="2179-idle-nudge-durable-respool"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

# shellcheck disable=SC2329
cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AUDIT_LOG="$BRIDGE_LOG_DIR/audit.jsonl"
: >"$AUDIT_LOG"

DAEMON_SH="$REPO_ROOT/bridge-daemon.sh"
smoke_assert_file_exists "$DAEMON_SH" "bridge-daemon.sh present"

# The real spool + mid-turn + notify helpers come from bridge-lib.sh — the
# durable-delivery invariants (T1/T3/T4) are exercised against production
# code, not a mock.
# shellcheck source=bridge-lib.sh disable=SC1091
source "$REPO_ROOT/bridge-lib.sh"

for _fn in \
  bridge_tmux_claude_capture_is_midturn \
  bridge_tmux_pending_attention_append \
  bridge_tmux_pending_attention_count \
  bridge_tmux_pending_attention_drain \
  bridge_tmux_pending_attention_is_queue_nudge \
  bridge_tmux_spool_enabled \
  bridge_compose_notification_text \
  bridge_queue_attention_title \
  bridge_queue_attention_message; do
  declare -F "$_fn" >/dev/null \
    || smoke_fail "required helper $_fn not defined after sourcing bridge-lib.sh"
done

# ---------------------------------------------------------------------
# Stubs: isolate the drop/respool decision block from a live tmux session.
#   - bridge_capture_recent returns the fixture pane text ($SMOKE_PANE_TEXT).
#   - bridge_tmux_claude_blocker_state returns $SMOKE_BLOCKER (none by default).
#   - bridge_audit_log writes JSON rows to $AUDIT_LOG (same shape as sibling
#     nudge smokes) so the respooled / respool_reason detail is assertable.
#   - daemon_info logs to a file.
# The spool helpers are the REAL bridge-lib.sh ones (they only touch files
# under the isolated BRIDGE_STATE_DIR), so T1/T3/T4 prove the durable path.
# ---------------------------------------------------------------------
SMOKE_PANE_TEXT=""
SMOKE_BLOCKER="none"

# shellcheck disable=SC2329
bridge_capture_recent() { printf '%s\n' "$SMOKE_PANE_TEXT"; }
# shellcheck disable=SC2329
bridge_tmux_claude_blocker_state() { printf '%s' "$SMOKE_BLOCKER"; }

# shellcheck disable=SC2329
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
        v="${v//\\/\\\\}"
        v="${v//\"/\\\"}"
        if [[ -n "$detail_json" ]]; then detail_json+=","; fi
        detail_json+="\"${k}\":\"${v}\""
        shift 2
        ;;
      *) shift ;;
    esac
  done
  printf '{"actor":"%s","action":"%s","target":"%s","detail":{%s}}\n' \
    "$actor" "$action" "$target" "$detail_json" >>"$AUDIT_LOG"
}

DAEMON_INFO_LOG="$SMOKE_TMP_ROOT/daemon-info.log"
: >"$DAEMON_INFO_LOG"
# shellcheck disable=SC2329
daemon_info() { printf '%s\n' "$*" >>"$DAEMON_INFO_LOG"; }

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

# ---------------------------------------------------------------------
# drop_block_shim — a FAITHFUL 1:1 copy of the post-grace drop/respool block
# from nudge_agent_session (bridge-daemon.sh). Intentionally mirrors the
# in-source logic so the smoke bites when the daemon block drifts (the
# T7_teeth grep pins the source shape too). The verify-grace + stage-1/2
# preamble is exercised by the sibling 1323 smoke; this shim assumes the
# task is already CONFIRMED still-queued (post_status=queued) and drives ONLY
# the reason-classification + durable re-spool decision under test.
# ---------------------------------------------------------------------
drop_block_shim() {
  local agent="$1"
  local session="$2"
  local task_id="$3"
  local live_queued="${4:-1}"
  local live_claimed="${5:-1}"
  local idle="${6:-1}"
  local _nudge_engine="${7:-claude}"
  local title
  title="$(bridge_queue_attention_title "$live_queued")"
  local message
  message="$(bridge_queue_attention_message "$agent" "$live_queued" "$task_id" "normal" "")"
  local nudge_grace_seconds=2
  local nudge_grace_stage2_total=5
  local nudge_stage2_used=1
  local _total_wait_seconds=5

  local _nudge_drop_reason="submit_lost_post_grace"
  local _blocker_state="none"
  if [[ -n "$session" ]]; then
    _blocker_state="$(bridge_tmux_claude_blocker_state "$session" 2>/dev/null || printf 'none')"
    if [[ "$_blocker_state" != "none" ]]; then
      _nudge_drop_reason="modal_${_blocker_state}"
    fi
  fi

  local _respooled=0
  local _respool_reason="none"
  if [[ "$_blocker_state" == "none" && "$_nudge_engine" == "claude" && -n "$session" ]]; then
    local _drop_recent=""
    _drop_recent="$(bridge_capture_recent "$session" 40 join 2>/dev/null || true)"
    if bridge_tmux_claude_capture_is_midturn "$_drop_recent"; then
      _respool_reason="midturn_no_spool_needed"
      if bridge_tmux_spool_enabled "$agent"; then
        local _spool_count=0
        _spool_count="$(bridge_tmux_pending_attention_count "$agent" 2>/dev/null || printf '0')"
        [[ "$_spool_count" =~ ^[0-9]+$ ]] || _spool_count=0
        if (( _spool_count == 0 )); then
          local _respool_text=""
          _respool_text="$(bridge_compose_notification_text "$title" "$message" "" "normal")"
          if [[ -n "$_respool_text" ]] \
             && bridge_tmux_pending_attention_append "$agent" "$_respool_text"; then
            _respooled=1
            _respool_reason="midturn_respooled"
          else
            _respool_reason="midturn_respool_failed"
          fi
        else
          _respool_reason="midturn_spool_nonempty"
        fi
      else
        _respool_reason="midturn_spool_disabled"
      fi
    fi
  fi

  bridge_audit_log daemon session_nudge_dropped "$agent" \
    --detail task_id="$task_id" \
    --detail reason="$_nudge_drop_reason" \
    --detail grace_seconds="$nudge_grace_seconds" \
    --detail grace_stage2_total_seconds="$nudge_grace_stage2_total" \
    --detail grace_total_seconds="$_total_wait_seconds" \
    --detail stage2_used="$nudge_stage2_used" \
    --detail queued="$live_queued" \
    --detail claimed="$live_claimed" \
    --detail idle_seconds="$idle" \
    --detail respooled="$_respooled" \
    --detail respool_reason="$_respool_reason" \
    --detail title="$title"
  if (( _respooled == 1 )); then
    daemon_info "nudge to ${agent} appears dropped mid-turn (task #${task_id} still queued after ${_total_wait_seconds}s); re-spooled to pending-attention for durable re-delivery on next idle transition"
  else
    daemon_info "nudge to ${agent} appears dropped (task #${task_id} still queued after ${_total_wait_seconds}s, stage1=${nudge_grace_seconds}s stage2_total=${nudge_grace_stage2_total}s); will retry on next idle-nudge tick"
  fi
  return 1
}

# Fixtures. A live mid-turn banner (banner is the live tail, no clean composer
# below it → is_midturn=0). And a clean idle composer (no banner → is_midturn=1).
BANNER_MIDTURN=$'✻ Working… (3s · ↑ 1.2k tokens)\n  esc to interrupt'
CLEAN_PROMPT=$'╭─────────────────────────╮\n│ > Try "edit <file>"     │\n╰─────────────────────────╯\n  ⏵⏵ bypass permissions on (shift+tab to cycle)'

# --- T1: mid-turn drop re-spools exactly one durable copy ----------
# shellcheck disable=SC2329
test_t1_midturn_respools() {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  # Fresh agent id → empty spool.
  local agent="agent-t1"
  rm -f "$(bridge_agent_pending_attention_file "$agent")" 2>/dev/null || true
  SMOKE_PANE_TEXT="$BANNER_MIDTURN"
  SMOKE_BLOCKER="none"
  local rc=0
  drop_block_shim "$agent" "sess-t1" "9001" 1 1 1 claude || rc=$?
  smoke_assert_eq 1 "$rc" "T1 drop still returns 1 (task stays queued for durable delivery)"
  local count
  count="$(bridge_tmux_pending_attention_count "$agent")"
  smoke_assert_eq 1 "$count" "T1 exactly one durable spool entry appended on mid-turn drop"
  local respooled
  respooled="$(audit_latest_detail session_nudge_dropped "$agent" respooled)"
  smoke_assert_eq 1 "$respooled" "T1 audit respooled=1"
  local reason
  reason="$(audit_latest_detail session_nudge_dropped "$agent" respool_reason)"
  smoke_assert_eq "midturn_respooled" "$reason" "T1 respool_reason=midturn_respooled"
  local drop_reason
  drop_reason="$(audit_latest_detail session_nudge_dropped "$agent" reason)"
  smoke_assert_eq "submit_lost_post_grace" "$drop_reason" "T1 drop reason stays submit_lost_post_grace"
  smoke_assert_contains "$(cat "$DAEMON_INFO_LOG")" "re-spooled to pending-attention" "T1 mid-turn respool log line"
}

# --- T2: clean prompt miss does NOT re-spool -----------------------
# shellcheck disable=SC2329
test_t2_clean_miss_no_respool() {
  : >"$AUDIT_LOG"
  : >"$DAEMON_INFO_LOG"
  local agent="agent-t2"
  rm -f "$(bridge_agent_pending_attention_file "$agent")" 2>/dev/null || true
  SMOKE_PANE_TEXT="$CLEAN_PROMPT"
  SMOKE_BLOCKER="none"
  local rc=0
  drop_block_shim "$agent" "sess-t2" "9002" 1 1 1 claude || rc=$?
  smoke_assert_eq 1 "$rc" "T2 clean-miss drop returns 1 (legacy behavior)"
  local count
  count="$(bridge_tmux_pending_attention_count "$agent")"
  smoke_assert_eq 0 "$count" "T2 no spool entry on a clean prompt miss"
  local respooled
  respooled="$(audit_latest_detail session_nudge_dropped "$agent" respooled)"
  smoke_assert_eq 0 "$respooled" "T2 audit respooled=0 (not mid-turn)"
  local reason
  reason="$(audit_latest_detail session_nudge_dropped "$agent" respool_reason)"
  smoke_assert_eq "none" "$reason" "T2 respool_reason=none (never entered the mid-turn branch)"
  smoke_assert_contains "$(cat "$DAEMON_INFO_LOG")" "will retry on next idle-nudge tick" "T2 legacy retry log line"
}

# --- T3: idempotency / single-copy lease ---------------------------
# shellcheck disable=SC2329
test_t3_single_copy_lease() {
  : >"$AUDIT_LOG"
  local agent="agent-t3"
  rm -f "$(bridge_agent_pending_attention_file "$agent")" 2>/dev/null || true
  SMOKE_PANE_TEXT="$BANNER_MIDTURN"
  SMOKE_BLOCKER="none"
  # First mid-turn drop → one copy.
  drop_block_shim "$agent" "sess-t3" "9003" 1 1 1 claude || true
  local first_reason
  first_reason="$(audit_latest_detail session_nudge_dropped "$agent" respool_reason)"
  smoke_assert_eq "midturn_respooled" "$first_reason" "T3 first drop respools"
  # Second mid-turn drop while a copy still sits in the spool → NO second copy.
  drop_block_shim "$agent" "sess-t3" "9003" 1 1 1 claude || true
  local count
  count="$(bridge_tmux_pending_attention_count "$agent")"
  smoke_assert_eq 1 "$count" "T3 still exactly one durable copy after a repeat drop (lease held)"
  local second_reason
  second_reason="$(audit_latest_detail session_nudge_dropped "$agent" respool_reason)"
  smoke_assert_eq "midturn_spool_nonempty" "$second_reason" "T3 repeat drop reports midturn_spool_nonempty"
  local second_respooled
  second_respooled="$(audit_latest_detail session_nudge_dropped "$agent" respooled)"
  smoke_assert_eq 0 "$second_respooled" "T3 repeat drop respooled=0 (no duplicate delivery)"
}

# --- T4: re-spool retries on next genuine idle ---------------------
# The daemon flush drains the spool and re-derives it against the live queue.
# Prove the durable copy is a recognizable queue-nudge so the flush loop's
# rederive/replay path can re-deliver it on the next idle transition.
# shellcheck disable=SC2329
test_t4_respool_retries_next_idle() {
  : >"$AUDIT_LOG"
  local agent="agent-t4"
  rm -f "$(bridge_agent_pending_attention_file "$agent")" 2>/dev/null || true
  SMOKE_PANE_TEXT="$BANNER_MIDTURN"
  SMOKE_BLOCKER="none"
  drop_block_shim "$agent" "sess-t4" "9004" 1 1 1 claude || true
  smoke_assert_eq 1 "$(bridge_tmux_pending_attention_count "$agent")" "T4 durable copy present pre-drain"
  # Drain like the flush loop does (bridge_tmux_pending_attention_drain), then
  # decode + confirm the payload replays as a queue nudge.
  local drained
  drained="$(bridge_tmux_pending_attention_drain "$agent")"
  smoke_assert_contains "$drained" "$(printf '\t')" "T4 drained entry has the ts<TAB>payload shape"
  local escaped decoded
  escaped="${drained#*$'\t'}"
  decoded="$(bridge_tmux_pending_attention_unescape "$escaped")"
  if bridge_tmux_pending_attention_is_queue_nudge "$decoded"; then
    : # the flush loop will re-derive + replay this on the next idle transition
  else
    smoke_fail "T4 durable copy is not recognized as a queue nudge — the flush loop would not re-derive/replay it"
  fi
  # After a drain the spool is empty → a genuinely-recovered agent leaves no
  # stale durable copy behind.
  smoke_assert_eq 0 "$(bridge_tmux_pending_attention_count "$agent")" "T4 spool empty after drain (self-clearing)"
}

# --- T5: blocker/modal non-regression ------------------------------
# shellcheck disable=SC2329
test_t5_modal_never_respools() {
  : >"$AUDIT_LOG"
  local agent="agent-t5"
  rm -f "$(bridge_agent_pending_attention_file "$agent")" 2>/dev/null || true
  # A modal owns the input AND the pane shows a mid-turn banner — the modal
  # gate must win: never re-spool, keep the operator-actionable modal reason.
  SMOKE_PANE_TEXT="$BANNER_MIDTURN"
  SMOKE_BLOCKER="trust"
  drop_block_shim "$agent" "sess-t5" "9005" 1 1 1 claude || true
  smoke_assert_eq 0 "$(bridge_tmux_pending_attention_count "$agent")" "T5 modal drop never re-spools"
  local reason
  reason="$(audit_latest_detail session_nudge_dropped "$agent" reason)"
  smoke_assert_eq "modal_trust" "$reason" "T5 drop reason stays modal_trust (operator-actionable)"
  local respooled
  respooled="$(audit_latest_detail session_nudge_dropped "$agent" respooled)"
  smoke_assert_eq 0 "$respooled" "T5 respooled=0 for a modal drop"
}

# --- T6: codex engine + escalation-not-suppressed ------------------
# A codex agent must NOT take the claude-only mid-turn respool branch, and the
# drop always returns 1 (task stays queued → unclaimed escalation intact).
# shellcheck disable=SC2329
test_t6_codex_and_no_suppress() {
  : >"$AUDIT_LOG"
  local agent="agent-t6"
  rm -f "$(bridge_agent_pending_attention_file "$agent")" 2>/dev/null || true
  SMOKE_PANE_TEXT="$BANNER_MIDTURN"
  SMOKE_BLOCKER="none"
  local rc=0
  drop_block_shim "$agent" "sess-t6" "9006" 1 1 1 codex || rc=$?
  smoke_assert_eq 1 "$rc" "T6 drop returns 1 (task left queued — escalation not suppressed)"
  smoke_assert_eq 0 "$(bridge_tmux_pending_attention_count "$agent")" "T6 codex engine does not enter the claude respool branch"
  local respooled
  respooled="$(audit_latest_detail session_nudge_dropped "$agent" respooled)"
  smoke_assert_eq 0 "$respooled" "T6 codex respooled=0"
}

# --- T7_teeth: structural shape in bridge-daemon.sh ----------------
# shellcheck disable=SC2329
test_t7_teeth() {
  grep -q 'bridge_tmux_claude_capture_is_midturn "\$_drop_recent"' "$DAEMON_SH" \
    || smoke_fail "teeth: nudge_agent_session drop block must classify mid-turn via bridge_tmux_claude_capture_is_midturn"
  grep -q '_blocker_state" == "none" && "\$_nudge_engine" == "claude"' "$DAEMON_SH" \
    || smoke_fail "teeth: respool must be gated on blocker=none + claude engine"
  grep -q 'bridge_tmux_pending_attention_append "\$agent" "\$_respool_text"' "$DAEMON_SH" \
    || smoke_fail "teeth: mid-turn respool must go through the existing pending-attention append path"
  grep -q '_spool_count == 0' "$DAEMON_SH" \
    || smoke_fail "teeth: single-copy idempotency lease (spool-empty gate) missing from the drop block"
  grep -q -- '--detail respooled=' "$DAEMON_SH" \
    || smoke_fail "teeth: session_nudge_dropped must emit the respooled audit detail"
  grep -q -- '--detail respool_reason=' "$DAEMON_SH" \
    || smoke_fail "teeth: session_nudge_dropped must emit the respool_reason audit detail"
}

smoke_run "T1: mid-turn drop re-spools exactly one durable copy" test_t1_midturn_respools
smoke_run "T2: clean prompt miss does NOT re-spool" test_t2_clean_miss_no_respool
smoke_run "T3: idempotency / single-copy lease" test_t3_single_copy_lease
smoke_run "T4: re-spool retries on next genuine idle (flush re-derive path)" test_t4_respool_retries_next_idle
smoke_run "T5: blocker/modal non-regression (modal never re-spools)" test_t5_modal_never_respools
smoke_run "T6: codex engine + escalation not suppressed" test_t6_codex_and_no_suppress
smoke_run "T7_teeth: structural shape in bridge-daemon.sh" test_t7_teeth

smoke_log "all T1-T7 pass"
exit 0
