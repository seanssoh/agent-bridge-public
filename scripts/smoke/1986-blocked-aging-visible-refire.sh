#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1986-blocked-aging-visible-refire.sh
#
# Issue #1986 (cm-prod RCA, A2A from cm-prod:patch) — the [blocked-aging]
# reminder silently in-place-refreshes when the assignee leaves the reminder
# task OPEN. process_blocked_task_aging() re-fires on the correct
# reminder_seconds cadence, but materializes via upsert_open_task() which
# re-binds the SAME open [blocked-aging] task (KNOWN_ISSUES §30 dedupe: open
# re-binds, `done` re-mints). The re-bind is an in-place UPDATE that bumps the
# body/updated_ts but never re-enters the daemon nudge pool — so an agent who
# leaves the reminder open (queued-but-already-nudged, or claimed) gets ZERO
# new visible alert. Only `done`-ing it re-mints a fresh, visible one. Fleet-
# wide silent drop of blocked-aging visibility (crm-dev: 18 cases). Escalation
# was strictly one-shot on top of that.
#
# The fix (#1986 hardening (a)+(b)) re-surfaces the SAME re-bound alert on its
# cadence — without re-minting — by putting the reminder back to `queued` and
# dropping its id from the assignee's last_nudge_key, so the maintain nudge
# scan treats it as a fresh queued trigger and re-nudges. (b) relaxes the
# escalation one-shot to a BOUNDED periodic re-escalation on the
# escalation_seconds cadence. §30 ("one open alert per condition, `done`
# re-mints") stays intact; the cadence gate prevents per-tick churn.
#
# This smoke drives the REAL process_blocked_task_aging via the bridge-queue.py
# `daemon-step` CLI against an isolated BRIDGE_HOME + task DB. The daemon-step
# tsv output IS the visible signal: a nudge candidate line
# `<agent>\t<session>\t<queued>\t<claimed>\t<idle>\t<nudge_key>` means the
# agent gets re-nudged about the re-surfaced reminder.
#
#   T1 — fresh reminder mints + the assignee is a visible nudge candidate.
#   T2 — agent leaves the reminder OPEN + is marked as already-nudged; a
#        WITHIN-cadence re-tick is a SILENT no-op (no new blocked_reminder
#        event, agent NOT a nudge candidate) — the cadence gate still throttles.
#   T3 — after reminder_seconds elapses (backdate the blocked_reminder event),
#        the next daemon-step RE-SURFACES the reminder VISIBLY: the SAME
#        reminder id (no re-mint → §30 intact), back to `queued`, and the
#        assignee is a nudge candidate naming the reminder id.
#   T4 — §30 intact: `done`-ing the open reminder re-mints a FRESH reminder id
#        on the next scan (the dedupe releases on done).
#   T5 — (b) escalation: strictly-one-shot is relaxed to bounded periodic.
#        After escalation_seconds the admin gets a re-escalation visibly, the
#        SAME escalation id (no re-mint), and a WITHIN-cadence re-tick is silent.
#   T_teeth — source shape: revert (drop resurface_open_alert / restore the
#        one-shot `!= 0 → continue`) must fail this smoke.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess; all queue mutation is via the bridge-queue.py CLI + sqlite3.

set -euo pipefail

# Re-exec under Bash 4+ for the bridge libs / smoke harness.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1986-blocked-aging-visible-refire] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1986-blocked-aging-visible-refire"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"
REPO_ROOT="$SMOKE_REPO_ROOT"
QUEUE="$REPO_ROOT/bridge-queue.py"

smoke_require_cmd python3
smoke_require_cmd sqlite3

ASSIGNEE="blocked-agent"
ADMIN="admin-agent"
REQUESTER="requester"

DB="$BRIDGE_STATE_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"
# Disable the nudge-redelivery AGE gate (#1014/#1099) — it is orthogonal to
# this fix and would otherwise require wall-clock sleeps to let a freshly
# minted reminder age past the ~60s window. We assert the re-SURFACE behavior,
# not the age gate.
export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=0
python3 "$QUEUE" init >/dev/null

REMINDER_PREFIX="[blocked-aging] task #"
ESCALATION_PREFIX="[blocked-escalation] task #"

# A short cadence so we can drive elapse by backdating events, not sleeping.
REMINDER_SECS=60
ESCALATE_SECS=120

# Idle threshold the nudge scan compares against: keep small; we backdate
# session_activity_ts well past it.
IDLE_THRESHOLD=10

# --- helpers ----------------------------------------------------------

# Write a daemon-step snapshot. The assignee is active=1 with a STALE
# session_activity_ts (idle past the threshold) so it is nudge-eligible;
# the admin is active=1 and stale too (for the escalation re-surface).
write_snapshot() {
  local path="$1" stale_ts
  stale_ts="$(( $(date +%s) - 600 ))"
  {
    printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\n'
    printf '%s\tclaude\t%s\t%s\t1\t%s\n' "$ASSIGNEE" "sess-$ASSIGNEE" "$SMOKE_TMP_ROOT/$ASSIGNEE" "$stale_ts"
    printf '%s\tclaude\t%s\t%s\t1\t%s\n' "$ADMIN" "sess-$ADMIN" "$SMOKE_TMP_ROOT/$ADMIN" "$stale_ts"
  } >"$path"
}

run_daemon_step() {
  write_snapshot "$SMOKE_TMP_ROOT/snapshot.tsv"
  python3 "$QUEUE" daemon-step \
    --snapshot "$SMOKE_TMP_ROOT/snapshot.tsv" \
    --idle-threshold "$IDLE_THRESHOLD" \
    --nudge-cooldown 5 \
    --blocked-reminder-seconds "$REMINDER_SECS" \
    --blocked-escalate-seconds "$ESCALATE_SECS" \
    --admin-agent "$ADMIN" \
    --format tsv
}

open_reminder_id() {
  python3 "$QUEUE" find-open --agent "$ASSIGNEE" --title-prefix "$REMINDER_PREFIX$1 " --format id 2>/dev/null
}

open_escalation_id() {
  python3 "$QUEUE" find-open --agent "$ADMIN" --title-prefix "$ESCALATION_PREFIX$1 " --format id 2>/dev/null
}

task_status() {
  python3 "$QUEUE" show "$1" --format shell 2>/dev/null | sed -n 's/^TASK_STATUS=//p' | tr -d "'"
}

count_open_with_prefix() {
  local agent="$1" prefix="$2" json
  json="$(python3 "$QUEUE" find-open --agent "$agent" --title-prefix "$prefix" --all --format json 2>/dev/null || printf '[]')"
  python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$json"
}

count_blocked_reminder_events() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM task_events WHERE task_id=$1 AND event_type='blocked_reminder';"
}

count_blocked_escalated_events() {
  sqlite3 "$DB" "SELECT COUNT(*) FROM task_events WHERE task_id=$1 AND event_type='blocked_escalated';"
}

# Backdate the most-recent blocked_reminder / blocked_escalated event so the
# cadence gate sees the window as elapsed (without sleeping).
backdate_last_event() {
  local task_id="$1" event_type="$2" seconds_ago="$3" cutoff
  cutoff="$(( $(date +%s) - seconds_ago ))"
  sqlite3 "$DB" "UPDATE task_events SET created_ts=$cutoff WHERE id=(SELECT id FROM task_events WHERE task_id=$task_id AND event_type='$event_type' ORDER BY created_ts DESC, id DESC LIMIT 1);"
}

# Mark the assignee as already-nudged about a given queued task id (what the
# daemon's note-nudge does after a successful nudge) so the next scan treats
# the reminder as already-seen — the pre-fix silent state.
mark_nudged() {
  local agent="$1" key="$2" now
  now="$(date +%s)"
  sqlite3 "$DB" "UPDATE agent_state SET last_nudge_ts=$now, last_nudge_key='$key', session_activity_ts=$now WHERE agent='$agent';"
}

# Create + block + age a real task so process_blocked_task_aging picks it up.
make_aged_blocked_task() {
  local out task_id old_ts
  out="$(python3 "$QUEUE" create --to "$ASSIGNEE" --from "$REQUESTER" --title "blocked work" --body "blocked body" --format shell)"
  task_id="$(printf '%s\n' "$out" | sed -n 's/^TASK_ID=//p' | tr -d "'")"
  python3 "$QUEUE" update "$task_id" --status blocked --note "waiting on fixture" >/dev/null
  # Age it well past both reminder + escalation windows so both branches engage.
  old_ts="$(( $(date +%s) - (ESCALATE_SECS * 4) ))"
  sqlite3 "$DB" "UPDATE tasks SET updated_ts=$old_ts WHERE id=$task_id;"
  printf '%s' "$task_id"
}

# Does the daemon-step tsv nudge output name this agent + reminder id?
nudge_names() {
  local out="$1" agent="$2" rid="$3" line
  while IFS= read -r line; do
    [[ "$line" == "$agent	"* ]] || continue
    case "$line" in
      *"	$rid"|*"	$rid,"*|*",$rid,"*|*",$rid") return 0 ;;
    esac
  done <<EOF
$out
EOF
  return 1
}

# ======================================================================
# T1 — fresh reminder mints + assignee is a visible nudge candidate
# ======================================================================
smoke_run "T1 fresh reminder mints and the assignee is a visible nudge candidate" : ; {
  task_id="$(make_aged_blocked_task)"
  out="$(run_daemon_step)"

  rid="$(open_reminder_id "$task_id")"
  smoke_assert_match "$rid" '^[0-9]+$' "T1 reminder task minted"
  smoke_assert_eq queued "$(task_status "$rid")" "T1 fresh reminder is queued"
  nudge_names "$out" "$ASSIGNEE" "$rid" \
    || smoke_fail "T1 assignee must be a visible nudge candidate naming reminder #$rid; got: $out"

  # Stash for later phases.
  T1_TASK_ID="$task_id"
  T1_RID="$rid"
}

# ======================================================================
# T2 — within-cadence re-tick is a SILENT no-op (cadence gate throttles)
# ======================================================================
smoke_run "T2 within-cadence re-tick does not re-fire (no churn, no nudge)" : ; {
  task_id="$T1_TASK_ID"; rid="$T1_RID"
  # Simulate the agent having seen + left the reminder open: mark it nudged,
  # which also advances session_activity_ts so the nudge is suppressed.
  mark_nudged "$ASSIGNEE" "$rid"
  before_events="$(count_blocked_reminder_events "$task_id")"

  out="$(run_daemon_step)"

  after_events="$(count_blocked_reminder_events "$task_id")"
  smoke_assert_eq "$before_events" "$after_events" "T2 no new blocked_reminder event within the cadence window"
  if nudge_names "$out" "$ASSIGNEE" "$rid"; then
    smoke_fail "T2 within-cadence re-tick must NOT re-nudge the assignee; got: $out"
  fi
  # Still exactly one open reminder (no re-mint, no churn).
  smoke_assert_eq 1 "$(count_open_with_prefix "$ASSIGNEE" "$REMINDER_PREFIX$task_id ")" "T2 still exactly one open reminder"
}

# ======================================================================
# T3 — after the cadence elapses, the reminder re-surfaces VISIBLY (no re-mint)
# ======================================================================
smoke_run "T3 cadence elapsed → SAME reminder re-surfaces visibly (no re-mint, §30 intact)" : ; {
  task_id="$T1_TASK_ID"; rid="$T1_RID"
  # Agent is still sitting on the open (already-nudged) reminder.
  mark_nudged "$ASSIGNEE" "$rid"
  # Backdate the last blocked_reminder event so the reminder cadence is elapsed.
  backdate_last_event "$task_id" blocked_reminder "$(( REMINDER_SECS * 2 ))"

  out="$(run_daemon_step)"

  rid_after="$(open_reminder_id "$task_id")"
  smoke_assert_eq "$rid" "$rid_after" "T3 re-bound the SAME reminder id (no re-mint — §30 intact)"
  smoke_assert_eq 1 "$(count_open_with_prefix "$ASSIGNEE" "$REMINDER_PREFIX$task_id ")" "T3 still exactly one open reminder (dedupe holds)"
  smoke_assert_eq queued "$(task_status "$rid")" "T3 re-surfaced reminder is back to queued"
  nudge_names "$out" "$ASSIGNEE" "$rid" \
    || smoke_fail "T3 cadence re-fire must re-nudge the assignee about reminder #$rid (the visible re-surface); got: $out"
}

# ======================================================================
# T6 — claimed-alert guard (patch adversarial seed): a CLAIMED reminder is
# NOT clobbered on the cadence tick — no status flip, no claim loss, no re-nudge
# ======================================================================
smoke_run "T6 a CLAIMED reminder is left untouched on cadence (no claim clobber, no re-nudge)" : ; {
  task_id="$T1_TASK_ID"; rid="$T1_RID"
  # Admin claims the open reminder (status=claimed, claimed_by set) — i.e. is
  # actively working it. rid is 'queued' after T3, so claim succeeds.
  python3 "$QUEUE" claim "$rid" --agent "$ASSIGNEE" >/dev/null
  smoke_assert_eq claimed "$(task_status "$rid")" "T6 reminder is claimed before the cadence tick"
  before_claimed_by="$(sqlite3 "$DB" "SELECT claimed_by FROM tasks WHERE id=$rid;")"
  # The cadence elapses while the admin holds the claim.
  mark_nudged "$ASSIGNEE" "$rid"
  backdate_last_event "$task_id" blocked_reminder "$(( REMINDER_SECS * 2 ))"

  out="$(run_daemon_step)"

  # The claim MUST survive: status stays claimed, claimed_by preserved, no
  # re-mint, no re-nudge — resurface_open_alert must skip a claimed alert.
  smoke_assert_eq claimed "$(task_status "$rid")" "T6 claimed reminder stays claimed (NOT clobbered back to queued)"
  smoke_assert_eq "$before_claimed_by" "$(sqlite3 "$DB" "SELECT claimed_by FROM tasks WHERE id=$rid;")" "T6 claimed_by preserved (no claim clobber)"
  smoke_assert_eq "$rid" "$(open_reminder_id "$task_id")" "T6 same reminder id (no re-mint)"
  if nudge_names "$out" "$ASSIGNEE" "$rid"; then
    smoke_fail "T6 a CLAIMED reminder must NOT be re-nudged (admin already has it in hand); got: $out"
  fi
}

# ======================================================================
# T4 — §30: `done`-ing the reminder re-mints a fresh id on the next scan
# ======================================================================
smoke_run "T4 done re-mints a fresh reminder id (§30 dedupe-release intact)" : ; {
  task_id="$T1_TASK_ID"; rid="$T1_RID"
  python3 "$QUEUE" done "$rid" --agent "$ASSIGNEE" --note "ack" >/dev/null
  # The underlying task is still blocked + aged, and the reminder cadence is
  # elapsed, so the next scan must mint a FRESH reminder id.
  backdate_last_event "$task_id" blocked_reminder "$(( REMINDER_SECS * 2 ))"
  run_daemon_step >/dev/null

  rid_new="$(open_reminder_id "$task_id")"
  smoke_assert_match "$rid_new" '^[0-9]+$' "T4 a fresh reminder is minted after done"
  [[ "$rid_new" != "$rid" ]] || smoke_fail "T4 done must RE-MINT a new reminder id (§30), got the same id $rid_new"
}

# ======================================================================
# T5 — (b) escalation: one-shot relaxed to bounded periodic re-escalation
# ======================================================================
smoke_run "T5 escalation re-fires periodically (bounded), not strictly once" : ; {
  # Fresh blocked task aged past the escalation window.
  esc_task_id="$(make_aged_blocked_task)"
  run_daemon_step >/dev/null
  eid="$(open_escalation_id "$esc_task_id")"
  smoke_assert_match "$eid" '^[0-9]+$' "T5 escalation task minted for admin"
  smoke_assert_eq 1 "$(count_blocked_escalated_events "$esc_task_id")" "T5 exactly one escalation so far"

  # Admin leaves it open + already-nudged; a WITHIN-cadence re-tick is silent.
  mark_nudged "$ADMIN" "$eid"
  run_daemon_step >/dev/null
  smoke_assert_eq 1 "$(count_blocked_escalated_events "$esc_task_id")" "T5 within-cadence re-tick does NOT re-escalate (bounded)"

  # After escalation_seconds elapses, it re-escalates — the SAME id (no re-mint).
  mark_nudged "$ADMIN" "$eid"
  backdate_last_event "$esc_task_id" blocked_escalated "$(( ESCALATE_SECS * 2 ))"
  out="$(run_daemon_step)"
  eid_after="$(open_escalation_id "$esc_task_id")"
  smoke_assert_eq "$eid" "$eid_after" "T5 re-escalation re-binds the SAME escalation id (no re-mint)"
  smoke_assert_eq 2 "$(count_blocked_escalated_events "$esc_task_id")" "T5 a second escalation fires after the cadence (one-shot relaxed)"
  nudge_names "$out" "$ADMIN" "$eid" \
    || smoke_fail "T5 admin must be re-nudged about escalation #$eid on the cadence; got: $out"
}

# ======================================================================
# T7 — symmetry (patch adversarial seed): the ESCALATION re-fire shares the
# reminder's claimed-protection. A CLAIMED [blocked-escalation] task is left
# untouched on the escalation cadence — both paths route through the same
# guarded resurface_open_alert, so escalation inherits the no-clobber guard.
# ======================================================================
smoke_run "T7 a CLAIMED escalation is left untouched on cadence (escalation parity, no clobber)" : ; {
  esc_task_id="$(make_aged_blocked_task)"
  run_daemon_step >/dev/null
  eid="$(open_escalation_id "$esc_task_id")"
  smoke_assert_match "$eid" '^[0-9]+$' "T7 escalation task minted for admin"
  # Admin claims the [blocked-escalation] high task — actively working it.
  python3 "$QUEUE" claim "$eid" --agent "$ADMIN" >/dev/null
  smoke_assert_eq claimed "$(task_status "$eid")" "T7 escalation is claimed before the cadence tick"
  before_claimed_by="$(sqlite3 "$DB" "SELECT claimed_by FROM tasks WHERE id=$eid;")"
  # The escalation cadence elapses while the admin holds the claim.
  mark_nudged "$ADMIN" "$eid"
  backdate_last_event "$esc_task_id" blocked_escalated "$(( ESCALATE_SECS * 2 ))"

  out="$(run_daemon_step)"

  smoke_assert_eq claimed "$(task_status "$eid")" "T7 claimed escalation stays claimed (NOT clobbered)"
  smoke_assert_eq "$before_claimed_by" "$(sqlite3 "$DB" "SELECT claimed_by FROM tasks WHERE id=$eid;")" "T7 claimed_by preserved (no claim clobber)"
  smoke_assert_eq "$eid" "$(open_escalation_id "$esc_task_id")" "T7 same escalation id (no re-mint)"
  if nudge_names "$out" "$ADMIN" "$eid"; then
    smoke_fail "T7 a CLAIMED escalation must NOT be re-nudged (admin already has it); got: $out"
  fi
}

# ======================================================================
# T_teeth — source shape so a revert fails this smoke
# ======================================================================
smoke_run "T_teeth visible-refire + bounded-escalation source shape" : ; {
  src="$REPO_ROOT/bridge-queue.py"
  grep -q 'def resurface_open_alert' "$src" \
    || smoke_fail "teeth: resurface_open_alert helper must exist"
  # The reminder branch must re-surface a re-bound (existing-open) reminder.
  grep -q 'resurface_open_alert(' "$src" \
    || smoke_fail "teeth: process_blocked_task_aging must call resurface_open_alert on re-bind"
  # The escalation one-shot must be relaxed to a bounded cadence gate, not the
  # strict `last_escalated_ts != 0 → continue`.
  grep -q 'last_escalated_ts != 0 and current_ts - last_escalated_ts < escalation_seconds' "$src" \
    || smoke_fail "teeth: escalation must use the bounded periodic cadence gate (#1986 (b))"
  if grep -Eq '^[[:space:]]*if last_escalated_ts != 0:[[:space:]]*$' "$src"; then
    smoke_fail "teeth: strict one-shot escalation gate must be gone"
  fi
  # Claimed-alert guard (patch adversarial seed, #1986 review): the resurface
  # status-flip must be scoped to 'blocked' and skip a 'claimed' alert, so a
  # revert to the unconditional `status != 'queued'` flip (which clobbers a
  # claim) fails this teeth.
  grep -q "status = 'blocked'" "$src" \
    || smoke_fail "teeth: resurface status-flip must be scoped to 'blocked' (claimed-alert guard)"
  grep -q "== .claimed." "$src" \
    || smoke_fail "teeth: resurface must skip a claimed alert (no-clobber guard)"
  # Escalation visibility parity (patch symmetry seed): the escalation branch
  # must ALSO route a re-bound escalation through resurface_open_alert, not the
  # old silent in-place re-bind — else (b) would be "bounded but invisible".
  grep -q 'resurface_open_alert(conn, agent=admin_agent' "$src" \
    || smoke_fail "teeth: the escalation re-fire must resurface visibly (parity with the reminder path)"
}

smoke_log "all tests passed: $SMOKE_NAME"
