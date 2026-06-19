#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1970-idle-reclaim-lease-aware.sh
#
# Issue #1970 — idle-agent claim reclaim must honor the task lease.
#
# The daemon stale-claim idle-reclaim (bridge-queue.py cmd_daemon_step)
# requeued every `status='claimed' AND claimed_ts < now - max_claim_age`
# claim from an idle/inactive agent, ignoring lease_until_ts AND updated_ts.
# A live agent on a long multi-turn task goes prompt-idle (>120s) between
# turns and gets its in-progress claim yanked → the [unclaimed-task]
# watchdog false-escalates ~30min later. ~12 false escalations/day on
# sean-mac (v0.16.15).
#
# The fix (agb-dev-codex-converged 4-part design):
#   1. idle stale-claim branch is lease-aware — a LIVE-idle claimant's task
#      is NOT requeued while lease_until_ts >= current_ts. inactive branch
#      UNCHANGED. NULL lease still reclaimable (legacy / upgrade window).
#   2. `agb update` renews the lease for the CLAIMANT/assignee only, while
#      the task stays claimed (no creator/admin lease spoof).
#   3. daemon auto-renewal stays activity-tied (NOT changed by this smoke).
#   4. unclaimed-watchdog grace via max(created_ts, updated_ts).
#
# 7-case matrix (mutation-test non-vacuous):
#   T1 — long multi-turn claim NOT reclaimed (the false-positive shape).
#   T2 — worker progress renews lease; creator update does NOT (actor guard).
#   T3 — live abandoned claim reclaimed in bound (exactly ONE lease_expired);
#        legacy NULL-lease idle subcase → stale_claim_requeued.
#   T4 — down-agent claim reclaims even with a future lease.
#   T5 — recent tmux activity renews; stale liveness does not.
#   T6 — post-requeue unclaimed-watchdog grace (max(created_ts, updated_ts)).
#   T7 — #14837 live-repro oracle: a DEFAULT-path `agb update` by the claimant
#        (no --lease-seconds) renews the lease end-to-end, so the lease-aware
#        idle-reclaim does NOT requeue a long claim that was just updated.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` at a python3 subprocess. All
# DB seeding/reads go through file-as-argv helpers under
# 1970-idle-reclaim-lease-aware-helpers/.

set -euo pipefail

# Re-exec under Bash 4+ for the snapshot TSV / assoc handling parity.
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1970-idle-reclaim-lease-aware] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1970-idle-reclaim-lease-aware"
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
HELPERS="$SCRIPT_DIR/1970-idle-reclaim-lease-aware-helpers"
UNCLAIMED_FILTER="$REPO_ROOT/lib/daemon-helpers/unclaimed-task-filter.py"

smoke_require_cmd python3

DB="$BRIDGE_TASK_DB"
python3 "$QUEUE" init >/dev/null

NOW="$(date +%s)"

# --- Fixtures -----------------------------------------------------------
# Create one queued task per case, then seed exact claim fields.
new_task() {
  local to="$1" title="$2" out task_id
  out="$(
    python3 "$QUEUE" create \
      --to "$to" --from requester \
      --title "$title" --body "body" --format shell
  )"
  task_id="$(smoke_shell_field TASK_ID "$out")"
  smoke_assert_match "$task_id" '^[0-9]+$' "create returned task id ($title)"
  printf '%s' "$task_id"
}

seed_claim() {
  # <task-id> <claimed-by> <claimed-ts> <lease-until-ts|NULL> <updated-ts>
  python3 "$HELPERS/seed-claim-fields.py" "$DB" "$1" "$2" "$3" "$4" "$5"
}

field() {
  # <task-id> <KEY>  -> prints the value
  local task_id="$1" key="$2"
  smoke_shell_field "$key" "$(python3 "$HELPERS/read-task-fields.py" "$DB" "$task_id")"
}

count_events() {
  # <task-id> <event-type> -> prints integer count
  python3 "$HELPERS/count-events.py" "$DB" "$1" "$2"
}

write_snapshot() {
  # writes a daemon-step snapshot TSV from "agent active session_activity_ts
  # activity_state" quadruples passed as 4-tuples on argv.
  local path="$1"; shift
  {
    printf 'agent\tactive\tsession\tengine\tsession_activity_ts\tactivity_state\n'
    while (( $# >= 4 )); do
      printf '%s\t%s\t%s-session\tclaude\t%s\t%s\n' "$1" "$2" "$1" "$3" "$4"
      shift 4
    done
  } >"$path"
}

run_daemon_step() {
  # maintenance-only (skip nudges → no ready-agents file needed). Defaults
  # match the live thresholds: idle=120, max-claim-age=900, lease=900,
  # heartbeat-window=300.
  local snapshot="$1"
  python3 "$QUEUE" daemon-step \
    --snapshot "$snapshot" \
    --idle-threshold 120 \
    --max-claim-age 900 \
    --lease-seconds 900 \
    --heartbeat-window 300 \
    --skip-nudges \
    --format text >/dev/null
}

# =======================================================================
# T1 — long multi-turn claim NOT reclaimed (the false-positive shape).
#   claimed, claimed_ts=now-2000, lease_until_ts=now+600, active snapshot
#   session_activity_ts=now-200 (idle: >120s, not picker_blocked), valid
#   lease → daemon-step → still claimed, NO stale_claim_requeued.
# =======================================================================
T1="$(new_task worker-a "T1 long multi-turn claim")"
seed_claim "$T1" worker-a "$((NOW - 2000))" "$((NOW + 600))" "$((NOW - 200))"
SNAP="$SMOKE_TMP_ROOT/snap-t1.tsv"
write_snapshot "$SNAP" worker-a 1 "$((NOW - 200))" idle
run_daemon_step "$SNAP"
smoke_assert_eq "claimed" "$(field "$T1" TASK_STATUS)" "T1 idle valid-lease claim stays claimed"
smoke_assert_eq "worker-a" "$(field "$T1" TASK_CLAIMED_BY)" "T1 claim owner preserved"
smoke_assert_eq "0" "$(count_events "$T1" stale_claim_requeued)" "T1 NO stale_claim_requeued"
smoke_assert_eq "0" "$(count_events "$T1" lease_expired)" "T1 NO lease_expired (valid lease)"

# =======================================================================
# T2 — worker progress renews lease; creator update does NOT (actor guard).
# =======================================================================
T2="$(new_task worker-b "T2 worker progress renews lease")"
seed_claim "$T2" worker-b "$((NOW - 100))" "$((NOW + 60))" "$((NOW - 100))"
# Claimant update with --status claimed extends the lease to >= now+900.
python3 "$QUEUE" update "$T2" --actor worker-b --status claimed --lease-seconds 900 \
  --note "still working" >/dev/null
T2_LEASE="$(field "$T2" TASK_LEASE_UNTIL_TS)"
T2_UPDATED="$(field "$T2" TASK_UPDATED_TS)"
smoke_assert_eq "claimed" "$(field "$T2" TASK_STATUS)" "T2 stays claimed after claimant update"
[[ "$T2_LEASE" =~ ^[0-9]+$ ]] || smoke_fail "T2 lease not numeric: $T2_LEASE"
(( T2_LEASE >= NOW + 900 )) || smoke_fail "T2 claimant update did NOT extend lease (lease=$T2_LEASE, want >= $((NOW + 900)))"
[[ "$T2_UPDATED" =~ ^[0-9]+$ ]] || smoke_fail "T2 updated_ts not numeric: $T2_UPDATED"
(( T2_UPDATED >= NOW )) || smoke_fail "T2 updated_ts not touched (updated=$T2_UPDATED)"
# Negative (actor guard): a creator/admin update edits the note but must NOT
# extend the lease. Re-seed a short lease, then update as a non-owner actor.
seed_claim "$T2" worker-b "$((NOW - 100))" "$((NOW + 60))" "$((NOW - 100))"
python3 "$QUEUE" update "$T2" --actor requester --status claimed --lease-seconds 900 \
  --note "creator metadata edit" >/dev/null
T2_LEASE2="$(field "$T2" TASK_LEASE_UNTIL_TS)"
smoke_assert_eq "$((NOW + 60))" "$T2_LEASE2" "T2 creator update does NOT extend the claimant's lease"

# Mutation guard: an update that moves the task OUT of claimed must not
# extend a lease (handoff/blocked own that transition).
seed_claim "$T2" worker-b "$((NOW - 100))" "$((NOW + 60))" "$((NOW - 100))"
python3 "$QUEUE" update "$T2" --actor worker-b --status blocked --lease-seconds 900 \
  --note "blocked now" >/dev/null
smoke_assert_eq "$((NOW + 60))" "$(field "$T2" TASK_LEASE_UNTIL_TS)" "T2 status-leaving-claimed update does NOT extend lease"

# =======================================================================
# T3 — live abandoned claim reclaimed in bound (exactly ONE lease_expired).
#   claimed, active, session_activity_ts=now-2000 (stale liveness → no
#   renewal, and idle), old claimed_ts, lease_until_ts=now-1 (expired) →
#   daemon-step → queued, fields cleared, exactly one lease_expired.
# =======================================================================
T3="$(new_task worker-c "T3 live abandoned claim")"
seed_claim "$T3" worker-c "$((NOW - 2000))" "$((NOW - 1))" "$((NOW - 2000))"
SNAP="$SMOKE_TMP_ROOT/snap-t3.tsv"
write_snapshot "$SNAP" worker-c 1 "$((NOW - 2000))" idle
run_daemon_step "$SNAP"
smoke_assert_eq "queued" "$(field "$T3" TASK_STATUS)" "T3 expired-lease live claim requeued"
smoke_assert_eq "NULL" "$(field "$T3" TASK_CLAIMED_BY)" "T3 claimed_by cleared"
smoke_assert_eq "NULL" "$(field "$T3" TASK_LEASE_UNTIL_TS)" "T3 lease cleared"
smoke_assert_eq "1" "$(count_events "$T3" lease_expired)" "T3 exactly ONE lease_expired event"
smoke_assert_eq "0" "$(count_events "$T3" stale_claim_requeued)" "T3 NO double-requeue via stale_claim_requeued"

# T3 legacy subcase: NULL lease + idle snapshot → stale_claim_requeued
# (the legacy / upgrade-window row still releases here).
T3B="$(new_task worker-c "T3b legacy null-lease idle claim")"
seed_claim "$T3B" worker-c "$((NOW - 2000))" NULL "$((NOW - 2000))"
SNAP="$SMOKE_TMP_ROOT/snap-t3b.tsv"
write_snapshot "$SNAP" worker-c 1 "$((NOW - 2000))" idle
run_daemon_step "$SNAP"
smoke_assert_eq "queued" "$(field "$T3B" TASK_STATUS)" "T3b legacy null-lease idle claim requeued"
smoke_assert_eq "1" "$(count_events "$T3B" stale_claim_requeued)" "T3b exactly ONE stale_claim_requeued"
smoke_assert_eq "0" "$(count_events "$T3B" lease_expired)" "T3b NO lease_expired (null lease)"

# =======================================================================
# T4 — down-agent claim reclaims even with a future lease (NOT lease-aware).
#   claimed, claimed_ts=now-2000, lease_until_ts=now+600 (future), snapshot
#   inactive → daemon-step → queued, note says inactive.
# =======================================================================
T4="$(new_task worker-d "T4 down-agent future-lease claim")"
seed_claim "$T4" worker-d "$((NOW - 2000))" "$((NOW + 600))" "$((NOW - 2000))"
SNAP="$SMOKE_TMP_ROOT/snap-t4.tsv"
# inactive: active=0 → not in active_agents; lease-aware gate does NOT apply.
write_snapshot "$SNAP" worker-d 0 "$((NOW - 2000))" idle
run_daemon_step "$SNAP"
smoke_assert_eq "queued" "$(field "$T4" TASK_STATUS)" "T4 down-agent future-lease claim requeued"
smoke_assert_eq "1" "$(count_events "$T4" stale_claim_requeued)" "T4 exactly ONE stale_claim_requeued"
T4_NOTE="$(python3 "$QUEUE" show "$T4" --format text | grep -A1 'stale_claim_requeued' | tail -1)"
smoke_assert_contains "$T4_NOTE" "inactive" "T4 requeue note says inactive"

# =======================================================================
# T5 — recent tmux activity renews; stale liveness does not.
#   A) active session_activity_ts=now-10 (within heartbeat_window) →
#      daemon-step extends lease to >= now+lease_seconds.
#   B) active session_activity_ts=now-1000 (stale) → no extend; an expired
#      lease requeues (the deadman).
# =======================================================================
# A — recent activity renews the lease (claim stays claimed; valid lease).
T5A="$(new_task worker-e "T5A recent activity renews lease")"
seed_claim "$T5A" worker-e "$((NOW - 2000))" "$((NOW + 60))" "$((NOW - 2000))"
SNAP="$SMOKE_TMP_ROOT/snap-t5a.tsv"
write_snapshot "$SNAP" worker-e 1 "$((NOW - 10))" working
run_daemon_step "$SNAP"
T5A_LEASE="$(field "$T5A" TASK_LEASE_UNTIL_TS)"
smoke_assert_eq "claimed" "$(field "$T5A" TASK_STATUS)" "T5A recent-activity claim stays claimed"
[[ "$T5A_LEASE" =~ ^[0-9]+$ ]] || smoke_fail "T5A lease not numeric: $T5A_LEASE"
(( T5A_LEASE >= NOW + 900 )) || smoke_fail "T5A recent activity did NOT renew lease (lease=$T5A_LEASE)"

# B — stale liveness does not renew; expired lease requeues (deadman).
T5B="$(new_task worker-f "T5B stale liveness no renew")"
seed_claim "$T5B" worker-f "$((NOW - 2000))" "$((NOW - 1))" "$((NOW - 2000))"
SNAP="$SMOKE_TMP_ROOT/snap-t5b.tsv"
write_snapshot "$SNAP" worker-f 1 "$((NOW - 1000))" idle
run_daemon_step "$SNAP"
smoke_assert_eq "queued" "$(field "$T5B" TASK_STATUS)" "T5B stale-liveness expired-lease claim requeued"
smoke_assert_eq "1" "$(count_events "$T5B" lease_expired)" "T5B exactly ONE lease_expired (no renewal)"

# =======================================================================
# T6 — post-requeue unclaimed-watchdog grace via max(created_ts, updated_ts).
#   The unclaimed-task-filter ages a queued task from the most recent of
#   created_ts / updated_ts. A just-requeued task (fresh updated_ts) does
#   NOT escalate; a genuinely-stale one does.
# =======================================================================
# Drive the helper directly with a synthetic find-open --all payload. Build
# the JSON via a file-as-argv helper (no heredoc-stdin to a python3 subproc).
build_payload() {
  # <created_ts> <updated_ts> -> JSON list on stdout
  python3 "$HELPERS/emit-queued-row.py" "$1" "$2"
}

# 6a — fresh requeue: created_ts old (now-7200) but updated_ts=now → max is
# fresh → age < threshold → NOT escalated (filter emits no row).
PAYLOAD_FRESH="$(build_payload "$((NOW - 7200))" "$NOW")"
OUT_FRESH="$(
  BRIDGE_QUE_AGE_THRESHOLD=1800 \
  BRIDGE_QUE_NOW_TS="$NOW" \
  BRIDGE_QUE_INPUT_JSON="$PAYLOAD_FRESH" \
  python3 "$UNCLAIMED_FILTER"
)"
smoke_assert_eq "" "$OUT_FRESH" "T6 fresh-requeue (updated_ts=now) NOT escalated"

# 6b — stale requeue: backdate updated_ts to now-1900 (> 1800 threshold) →
# qualifies → exactly one row emitted (the once-latch downstream caps admin
# tasks at one; this asserts the filter contract that feeds it).
PAYLOAD_STALE="$(build_payload "$((NOW - 7200))" "$((NOW - 1900))")"
OUT_STALE="$(
  BRIDGE_QUE_AGE_THRESHOLD=1800 \
  BRIDGE_QUE_NOW_TS="$NOW" \
  BRIDGE_QUE_INPUT_JSON="$PAYLOAD_STALE" \
  python3 "$UNCLAIMED_FILTER"
)"
STALE_LINES="$(printf '%s\n' "$OUT_STALE" | grep -c . || true)"
smoke_assert_eq "1" "$STALE_LINES" "T6 stale-requeue (updated_ts past threshold) qualifies (one row)"

# 6c — legacy row without updated_ts: defaults to created_ts (unchanged
# behavior for the bash↔python upgrade window).
PAYLOAD_LEGACY="$(python3 "$HELPERS/emit-queued-row.py" "$((NOW - 7200))" --no-updated)"
OUT_LEGACY="$(
  BRIDGE_QUE_AGE_THRESHOLD=1800 \
  BRIDGE_QUE_NOW_TS="$NOW" \
  BRIDGE_QUE_INPUT_JSON="$PAYLOAD_LEGACY" \
  python3 "$UNCLAIMED_FILTER"
)"
LEGACY_LINES="$(printf '%s\n' "$OUT_LEGACY" | grep -c . || true)"
smoke_assert_eq "1" "$LEGACY_LINES" "T6 legacy row (no updated_ts) ages from created_ts (unchanged)"

# =======================================================================
# T7 — #14837 live-repro regression oracle for #1970 (reclaimed 2m24s after
#   a claimant `agb update`). The existing T2 renews via an EXPLICIT
#   `update --lease-seconds 900`; the live repro used a PLAIN `agb update`
#   (no --lease-seconds) and the renewal MUST fire on that DEFAULT path —
#   AND the actor must resolve to the CLAIMANT, not the OS USER (the #1933
#   class). This case proves the default-update-by-claimant path end-to-end:
#   the renewed lease keeps a long claim out of the idle reclaim.
#
#   Live timeline (crm-dev task #14837):
#     08:31:57 claimed by crm-dev
#     09:29:51 updated by crm-dev          <- plain `agb update` (active work)
#     09:32:13 stale_claim_requeued        <- BUG: reclaimed 2m24s later
#     09:33:01 done by crm-dev (work fine; pure noise + false escalation)
# =======================================================================
# 7a — DEFAULT-path renewal at the queue layer: a claimant `update` with NO
# --lease-seconds and NO --status renews the lease to now+default(900). A
# non-claimant (creator) default update does NOT renew (actor guard holds on
# the default path too).
T7A="$(new_task worker-g "T7a default-path update renews lease")"
seed_claim "$T7A" worker-g "$((NOW - 100))" "$((NOW + 60))" "$((NOW - 100))"
python3 "$QUEUE" update "$T7A" --actor worker-g --note "still working" >/dev/null
T7A_LEASE="$(field "$T7A" TASK_LEASE_UNTIL_TS)"
[[ "$T7A_LEASE" =~ ^[0-9]+$ ]] || smoke_fail "T7a lease not numeric: $T7A_LEASE"
(( T7A_LEASE >= NOW + 900 )) || smoke_fail "T7a default-path update did NOT apply the 900s default (lease=$T7A_LEASE, want >= $((NOW + 900)))"
smoke_assert_eq "claimed" "$(field "$T7A" TASK_STATUS)" "T7a stays claimed after default update"
# Non-claimant default update must NOT extend the claimant's lease.
seed_claim "$T7A" worker-g "$((NOW - 100))" "$((NOW + 60))" "$((NOW - 100))"
python3 "$QUEUE" update "$T7A" --actor requester --note "creator metadata edit" >/dev/null
smoke_assert_eq "$((NOW + 60))" "$(field "$T7A" TASK_LEASE_UNTIL_TS)" "T7a non-claimant default update does NOT renew the lease"

# 7b — END-TO-END actor resolution: drive the REAL `bridge-task.sh update` the
# way a live agent does (no --actor; BRIDGE_AGENT_ID set), so the actor flows
# through infer_actor_if_possible → bridge_infer_current_agent and resolves to
# the CLAIMANT (the #1933 OS-USER-fallback class), then the default lease
# renewal fires. Register the claimant in the isolated roster so the inference
# can recognize it.
printf 'BRIDGE_AGENT_ENGINE["worker-g"]="claude"\nBRIDGE_AGENT_SESSION["worker-g"]="worker-g"\n' >>"$BRIDGE_ROSTER_LOCAL_FILE"
seed_claim "$T7A" worker-g "$((NOW - 100))" "$((NOW + 60))" "$((NOW - 100))"
BRIDGE_AGENT_ID=worker-g bash "$REPO_ROOT/bridge-task.sh" update "$T7A" --note "still working" >/dev/null 2>&1
T7B_LEASE="$(field "$T7A" TASK_LEASE_UNTIL_TS)"
[[ "$T7B_LEASE" =~ ^[0-9]+$ ]] || smoke_fail "T7b lease not numeric: $T7B_LEASE"
(( T7B_LEASE >= NOW + 900 )) || smoke_fail "T7b bridge-task.sh default update did NOT renew via the inferred claimant actor (lease=$T7B_LEASE, want >= $((NOW + 900)))"
smoke_assert_eq "worker-g" "$(field "$T7A" TASK_CLAIMED_BY)" "T7b claim owner preserved through default-path update"

# 7c — THE ORACLE: the live #14837 condition. A long claim (claimed_ts older
# than max_claim_age → reclaim-eligible by age) whose ORIGINAL lease already
# expired (NULL = the exact live shape) gets a plain default `agb update` from
# the claimant (the 09:29:51 step), then the daemon idle-reclaim runs with the
# agent active-but-prompt-IDLE and a STALE session_activity_ts (> heartbeat
# window, so the snapshot auto-renewal does NOT fire — the UPDATE's lease is
# the sole protection, exactly the 09:32:13 condition). It must STAY claimed
# with NO stale_claim_requeued. Mutation note: revert the cmd_update renewal
# (so the default update leaves the lease NULL) and this requeues with
# stale_claim_requeued=1 — the live bug — confirming the oracle is non-vacuous.
T7="$(new_task worker-g "T7 #14837 live-repro oracle")"
python3 "$QUEUE" claim "$T7" --agent worker-g >/dev/null
seed_claim "$T7" worker-g "$((NOW - 2000))" NULL "$((NOW - 2000))"
BRIDGE_AGENT_ID=worker-g bash "$REPO_ROOT/bridge-task.sh" update "$T7" --note "still working" >/dev/null 2>&1
T7_LEASE="$(field "$T7" TASK_LEASE_UNTIL_TS)"
[[ "$T7_LEASE" =~ ^[0-9]+$ ]] || smoke_fail "T7 oracle: default update left lease unrenewed ($T7_LEASE) — the live #14837 gap"
(( T7_LEASE >= NOW + 900 )) || smoke_fail "T7 oracle: default update did NOT renew (lease=$T7_LEASE, want >= $((NOW + 900)))"
SNAP="$SMOKE_TMP_ROOT/snap-t7.tsv"
# active=1, idle (>120s), session_activity_ts=now-500 (> heartbeat_window 300
# → no snapshot auto-renewal): only the update-renewed lease can protect it.
write_snapshot "$SNAP" worker-g 1 "$((NOW - 500))" idle
run_daemon_step "$SNAP"
smoke_assert_eq "claimed" "$(field "$T7" TASK_STATUS)" "T7 oracle: default-update-renewed long claim stays claimed (#14837)"
smoke_assert_eq "worker-g" "$(field "$T7" TASK_CLAIMED_BY)" "T7 oracle: claim owner preserved"
smoke_assert_eq "0" "$(count_events "$T7" stale_claim_requeued)" "T7 oracle: NO stale_claim_requeued (the live #14837 false requeue)"
smoke_assert_eq "0" "$(count_events "$T7" lease_expired)" "T7 oracle: NO lease_expired (lease renewed by the update)"

smoke_log "all tests passed: $SMOKE_NAME (T1-T7)"
