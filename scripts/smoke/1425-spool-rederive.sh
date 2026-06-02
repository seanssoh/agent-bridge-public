#!/usr/bin/env bash
# scripts/smoke/1425-spool-rederive.sh — regression for issue #1425
# (#1411 follow-up, deferred secondary 1: stale pending-attention spool
# snapshots).
#
# The pending-attention spooler freezes the RENDERED queued-task nudge text
# at spool time — the `(N)` count and `#<task-id>` never re-derive from the
# live queue. The flusher used to replay that frozen text verbatim, so a
# `[deferred]` replay could show a stale count/id after the queue drained.
#
# The #1425 fix re-derives the live count + highest-priority task from the
# queue at flush time and re-renders the nudge — FAIL-SAFE:
#   - the live-count read is timeout-bounded (bridge_with_timeout);
#   - on ANY rederive failure (timeout / query error / unresolvable) the
#     original frozen entry is PRESERVED (never silently dropped);
#   - the entry is DROPPED only when the live queue is CONFIRMED count==0.
#
# This smoke covers the rederive helper contract directly:
#   R1 — live queue has N>0 queued tasks → rederive returns rc=0 and the
#        re-rendered nudge carries the LIVE count and the top task id.
#   R2 — live count differs from a stale snapshot → rederive reflects the
#        LIVE count, not the frozen one.
#   R3 — drained queue (count==0) → rederive returns rc=2 (drop).
#   R4 — simulated read failure (corrupt DB) → rederive returns rc=1
#        (preserve), NOT rc=2. A transient failure must never look like
#        count==0.
#   R5 — non-nudge payload → is_queue_nudge returns false (verbatim replay).
#   R6 — task-complete detection is anchored to the producer header and
#        extracts only the notification task id.
#   R7 — stale task-complete status check drops only confirmed done rows and
#        preserves on queued/missing/read-failure cases.
#   S1 — in-source wiring: the flusher calls the rederive, drops on rc=2,
#        preserves on rc=1, and gates task-complete stale drops on a bounded
#        task-status read. Static grep (the flusher is coupled to the daemon
#        main loop, same pattern as 1106-nudge-shell-recheck S1).
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at the point of
# a python3 subprocess. DB seeding uses bridge-queue.py --format shell +
# tempfile source (matches 1106-nudge-shell-recheck).

set -euo pipefail

SMOKE_NAME="1425-spool-rederive"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1425-rederive.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

failed=0

# ============================================================
# R1–R4 — rederive helper contract (sourced lib stack)
# ============================================================
# Set up the isolated v2 BRIDGE_HOME (env + layout marker) BEFORE sourcing
# bridge-lib.sh, so on a clean CI runner with no inherited v2 env/marker the
# source does not abort with the isolation-v2 markerless error
# ("requires isolation-v2 ... markerless(fresh-install-candidate)") — r3
# codex CI fix. scripts/smoke/lib.sh::smoke_setup_bridge_home is the
# canonical helper (writes state/layout-marker.sh with BRIDGE_LAYOUT=v2 and
# exports the full isolated env); a passing sibling like
# scripts/smoke/1409-claude-midturn-busy-gate.sh sources lib.sh BEFORE
# bridge-lib.sh for exactly this reason. The rederive helper's dependencies
# (bridge_with_timeout, bridge_queue_cli, bridge_queue_attention_*,
# bridge_compose_notification_text) are defined by bridge-lib.sh; its
# nudge-live-state subprocess reads the BRIDGE_TASK_DB the helper sets.
#
# Footgun #11: stage the inner script in a tempfile and run it by path
# rather than piping a heredoc into `bash -s` stdin (avoids the Bash 5.3.9
# heredoc_write deadlock class — KNOWN_ISSUES.md §26).
REDERIVE_UT="$TMP_DIR/rederive-ut.sh"
cat > "$REDERIVE_UT" <<'REDERIVE_UT_BODY'
set -u
repo="$1"
scratch="$2"
export SMOKE_NAME="1425-spool-rederive"
# shellcheck disable=SC1090
source "$repo/scripts/smoke/lib.sh"
# Isolated v2 BRIDGE_HOME + layout marker — MUST run before bridge-lib.sh.
smoke_setup_bridge_home "1425-spool-rederive"
trap 'smoke_cleanup_temp_root' EXIT
# shellcheck disable=SC1090
source "$repo/bridge-lib.sh"

fail() { printf '[smoke][error] rederive: %s\n' "$*" >&2; exit 1; }

agent="rederive-agent"

create_task() {
  local title="$1" priority="${2:-normal}"
  local out
  out="$(python3 "$repo/bridge-queue.py" create \
    --to "$agent" --from requester \
    --title "$title" --body "b" --priority "$priority" \
    --format shell)"
  local tmp
  tmp="$(mktemp)"
  printf '%s\n' "$out" > "$tmp"
  # shellcheck disable=SC1090
  source "$tmp"
  rm -f "$tmp"
  printf '%s' "${TASK_ID:-}"
  unset TASK_ID
}

# Seed: 2 queued tasks, the higher-priority one is the expected top.
id_low="$(create_task "low one" low)"
id_top="$(create_task "urgent one" urgent)"
[[ -n "$id_low" && -n "$id_top" ]] || fail "seed: task ids empty (low=$id_low top=$id_top)"

# ---- R1: rederive against a live N=2 queue --------------------------------
set +e
rendered="$(bridge_tmux_pending_attention_rederive_queue_nudge "$agent")"
rc=$?
set -e
if (( rc != 0 )); then
  fail "R1: expected rc=0 for live queue, got rc=$rc"
fi
# Default (legacy) render carries the count title and the top task id.
case "$rendered" in
  *"queued tasks (2)"*) : ;;
  *) fail "R1: re-rendered nudge missing live count '(2)': $rendered" ;;
esac
case "$rendered" in
  *"#${id_top}"*|*"Task #${id_top}"*) : ;;
  *) fail "R1: re-rendered nudge missing top task id #${id_top}: $rendered" ;;
esac
# Round-trip: the re-rendered output must itself be header-detectable as a
# queue nudge — proving the anchored detector matches the real producer
# output (and would re-derive again on a subsequent flush rather than replay
# stale text).
if ! bridge_tmux_pending_attention_is_queue_nudge "$rendered"; then
  fail "R1: re-rendered nudge is not recognized by the header-anchored detector: $rendered"
fi
printf '[smoke]   [ok] R1: rederive returns rc=0 and carries live count (2) + top task #%s (header round-trips)\n' "$id_top"

# ---- R2: live count reflects the queue, not a stale snapshot ---------------
# Add a third queued task; rederive must now report (3), proving it reads the
# LIVE queue rather than any frozen number.
id_extra="$(create_task "extra one" normal)"
[[ -n "$id_extra" ]] || fail "R2: extra task id empty"
set +e
rendered3="$(bridge_tmux_pending_attention_rederive_queue_nudge "$agent")"
rc3=$?
set -e
(( rc3 == 0 )) || fail "R2: expected rc=0, got rc=$rc3"
case "$rendered3" in
  *"queued tasks (3)"*) : ;;
  *) fail "R2: re-rendered nudge did not reflect new live count '(3)': $rendered3" ;;
esac
printf '[smoke]   [ok] R2: rederive reflects LIVE count (3) after a task is added\n'

# ---- R2b: top-task metadata comes from ONE bounded read --------------------
# r2 codex BLOCKING: the rederive must not do a SECOND, unbounded queue read
# for the top-task header. nudge-live-state with_top_task=1 returns the count
# AND the highest-priority queued task in the SAME bounded call. Assert the
# 6-column shape and that the top task is the urgent one (highest priority),
# and that the legacy 2-arg call still yields exactly 3 columns (backward
# compat for the daemon's existing nudge_agent_session caller).
live6="$(python3 "$repo/bridge-daemon-helpers.py" nudge-live-state "$BRIDGE_TASK_DB" "$agent" 1)"
col_count6="$(printf '%s' "$live6" | awk -F'\t' '{print NF}')"
[[ "$col_count6" == "6" ]] || fail "R2b: with_top_task=1 must emit 6 cols, got ${col_count6}: ${live6}"
top_id6="$(printf '%s' "$live6" | awk -F'\t' '{print $4}')"
top_pri6="$(printf '%s' "$live6" | awk -F'\t' '{print $5}')"
[[ "$top_id6" == "$id_top" ]] || fail "R2b: top_id must be the urgent task #${id_top}, got #${top_id6}"
[[ "$top_pri6" == "urgent" ]] || fail "R2b: top_priority must be urgent, got ${top_pri6}"
live3="$(python3 "$repo/bridge-daemon-helpers.py" nudge-live-state "$BRIDGE_TASK_DB" "$agent")"
col_count3="$(printf '%s' "$live3" | awk -F'\t' '{print NF}')"
[[ "$col_count3" == "3" ]] || fail "R2b: legacy 2-arg call must stay 3 cols, got ${col_count3}: ${live3}"
# Structural: the rederive helper must call nudge-live-state with the
# with_top_task flag and must NOT issue a second find-open / bridge_queue_cli
# queue read (which would be unbounded on the daemon/flusher path).
tmux_src="$repo/lib/bridge-tmux.sh"
helper_body="$(awk '/^bridge_tmux_pending_attention_rederive_queue_nudge\(\)/{f=1} f{print} /^}/{if(f)exit}' "$tmux_src")"
case "$helper_body" in
  *'nudge-live-state'*'"$agent" 1'*) : ;;
  *) fail "R2b: rederive helper does not call nudge-live-state with with_top_task=1" ;;
esac
if printf '%s' "$helper_body" | grep -q "bridge_queue_cli\|find-open"; then
  fail "R2b: rederive helper still issues an unbounded second queue read (find-open/bridge_queue_cli)"
fi
printf '[smoke]   [ok] R2b: top-task folded into ONE bounded read (6 cols, urgent top), legacy 3-col preserved, no 2nd unbounded read\n'

# ---- R3: drained queue → rc=2 (drop) --------------------------------------
# Close every queued task; a CONFIRMED count==0 must return rc=2 so the
# flusher drops the spooled entry.
for tid in "$id_low" "$id_top" "$id_extra"; do
  python3 "$repo/bridge-queue.py" claim "$tid" --agent "$agent" >/dev/null
  python3 "$repo/bridge-queue.py" done "$tid" --agent "$agent" --note "resolved" >/dev/null
done
set +e
bridge_tmux_pending_attention_rederive_queue_nudge "$agent" >/dev/null
rc_empty=$?
set -e
(( rc_empty == 2 )) || fail "R3: confirmed-empty queue must return rc=2 (drop), got rc=$rc_empty"
printf '[smoke]   [ok] R3: confirmed count==0 returns rc=2 (drop)\n'

# ---- R4: simulated read wedge/failure → rc=1 (preserve), NOT rc=2 ----------
# Point the single bounded read (nudge-live-state with_top_task=1) at a
# corrupt DB so it exits non-zero — this stands in for a wedged/timed-out
# queue read. Because the count AND the top-task metadata now come from that
# ONE bounded call, a failure of EITHER part is covered here: it must FAIL
# SAFE (rc=1 preserve), never be mistaken for count==0 (rc=2 drop).
corrupt_db="$scratch/corrupt.db"
printf 'this is not a sqlite database' > "$corrupt_db"
set +e
BRIDGE_TASK_DB="$corrupt_db" \
  bridge_tmux_pending_attention_rederive_queue_nudge "$agent" >/dev/null
rc_fail=$?
set -e
if (( rc_fail == 2 )); then
  fail "R4: a read failure was treated as count==0 (rc=2 drop) — FAIL-SAFE violated"
fi
(( rc_fail == 1 )) || fail "R4: expected rc=1 (preserve) on read failure, got rc=$rc_fail"
printf '[smoke]   [ok] R4: bounded read wedge/failure (count+top-task) returns rc=1 (preserve), never rc=2\n'

# ---- R5: nudge detection is anchored to the producer header ----------------
# Positive: the two real producer shapes must be recognized.
if ! bridge_tmux_pending_attention_is_queue_nudge "[Agent Bridge] event=inbox agent=x count=2 top=7"; then
  fail "R5: a metadata-only inbox nudge was NOT recognized"
fi
if ! bridge_tmux_pending_attention_is_queue_nudge $'[Agent Bridge]: ACTION REQUIRED — queued tasks (2)\n[Agent Bridge] 2 pending task(s) for x.'; then
  fail "R5: a legacy queued-tasks nudge was NOT recognized"
fi
# Negative: a plain non-nudge inject must not match.
if bridge_tmux_pending_attention_is_queue_nudge "[Agent Bridge] urgent: a human typed this"; then
  fail "R5: an urgent/non-nudge payload was misclassified as a queue nudge"
fi
# Negative (codex r1 BLOCKING): an urgent send whose own TITLE/BODY quotes a
# nudge string must NOT match — the detector is header-anchored, so a quoted
# string in the message body or a non-matching header cannot trip it.
# Otherwise the flusher could DROP this non-nudge on a confirmed-empty
# rederive (rc=2), violating the never-silently-drop guarantee.
if bridge_tmux_pending_attention_is_queue_nudge $'[Agent Bridge]: heads up from ops\nplease handle: ACTION REQUIRED — queued tasks (5) per the runbook'; then
  fail "R5: a non-nudge whose BODY quotes 'ACTION REQUIRED — queued tasks (' was misclassified"
fi
if bridge_tmux_pending_attention_is_queue_nudge "[Agent Bridge] urgent: see [Agent Bridge] event=inbox example in the docs"; then
  fail "R5: a non-nudge that MENTIONS 'event=inbox ' mid-text was misclassified"
fi
# event=inbox-bootstrap must NOT match (distinct producer, bridge-run.sh).
if bridge_tmux_pending_attention_is_queue_nudge "[Agent Bridge] event=inbox-bootstrap agent=x top=7"; then
  fail "R5: event=inbox-bootstrap was wrongly matched as a queue nudge"
fi
printf '[smoke]   [ok] R5: header-anchored detection — recognizes real nudges, rejects body-quoted false positives + inbox-bootstrap\n'

# ---- R6: task-complete detection is anchored to the producer header --------
complete_id="$(create_task "[task-complete] worker finished" high)"
[[ -n "$complete_id" ]] || fail "R6: completion task id empty"
complete_high_payload="[Agent Bridge] high task #${complete_id}: [task-complete] worker finished"$'\n'"agb inbox ${agent}"
parsed_complete_id="$(bridge_tmux_pending_attention_task_complete_id "$complete_high_payload")" \
  || fail "R6: high-priority task-complete payload was not recognized"
[[ "$parsed_complete_id" == "$complete_id" ]] \
  || fail "R6: parsed high-priority completion id ${parsed_complete_id}, expected ${complete_id}"
complete_normal_payload="[Agent Bridge] task #${complete_id}: [task-complete] worker finished"$'\n'"agb inbox ${agent}"
parsed_normal_id="$(bridge_tmux_pending_attention_task_complete_id "$complete_normal_payload")" \
  || fail "R6: normal-priority task-complete payload was not recognized"
[[ "$parsed_normal_id" == "$complete_id" ]] \
  || fail "R6: parsed normal-priority completion id ${parsed_normal_id}, expected ${complete_id}"
if bridge_tmux_pending_attention_task_complete_id $'[Agent Bridge]: heads up from ops\n[Agent Bridge] high task #777: [task-complete] quoted in the body' >/dev/null; then
  fail "R6: body-quoted task-complete payload was misclassified"
fi
if bridge_tmux_pending_attention_task_complete_id "[Agent Bridge] high task #${complete_id}: ordinary title" >/dev/null; then
  fail "R6: non-completion task header was misclassified"
fi
printf '[smoke]   [ok] R6: task-complete detector extracts header task id and rejects body/title false positives\n'

# ---- R7: stale task-complete status check is done-only and fail-safe -------
if bridge_tmux_pending_attention_task_complete_is_done "$complete_id"; then
  fail "R7: queued task-complete notification was treated as stale/done"
fi
python3 "$repo/bridge-queue.py" claim "$complete_id" --agent "$agent" >/dev/null
if bridge_tmux_pending_attention_task_complete_is_done "$complete_id"; then
  fail "R7: claimed task-complete notification was treated as stale/done"
fi
python3 "$repo/bridge-queue.py" done "$complete_id" --agent "$agent" --note "seen" >/dev/null
if ! bridge_tmux_pending_attention_task_complete_is_done "$complete_id"; then
  fail "R7: done task-complete notification was not classified as stale/done"
fi
if bridge_tmux_pending_attention_task_complete_is_done "99999999"; then
  fail "R7: missing task id was treated as stale/done"
fi
if BRIDGE_TASK_DB="$corrupt_db" bridge_tmux_pending_attention_task_complete_is_done "$complete_id"; then
  fail "R7: corrupt DB/read failure was treated as stale/done"
fi
task_status="$(python3 "$repo/bridge-daemon-helpers.py" task-status "$BRIDGE_TASK_DB" "$complete_id")" \
  || fail "R7: task-status helper failed for completed task"
[[ "$task_status" == "done" ]] || fail "R7: task-status helper returned ${task_status}, expected done"
printf '[smoke]   [ok] R7: task-complete stale check drops only confirmed done rows and preserves on open/missing/read failure\n'

printf '[smoke]   [ok] rederive helper block passed\n'
REDERIVE_UT_BODY

if "${BASH:-bash}" "$REDERIVE_UT" "$REPO_ROOT" "$TMP_DIR"; then
  :
else
  echo "[smoke][error] ${SMOKE_NAME}: rederive helper block FAILED" >&2
  failed=1
fi

# ============================================================
# S1 — in-source wiring (static grep)
# ============================================================
tmux_sh="$REPO_ROOT/lib/bridge-tmux.sh"
flush_body="$(awk '/^bridge_tmux_pending_attention_flush\(\)/{f=1} f{print} /^}/{if(f)exit}' "$tmux_sh")"

if ! grep -q "bridge_tmux_pending_attention_rederive_queue_nudge" "$tmux_sh"; then
  echo "[smoke][error] S1: flusher does not define/call the rederive helper" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: rederive helper is defined in lib/bridge-tmux.sh"
fi

# The flusher must drop on rc=2 (continue) and fall through to preserve on
# rc=1 — assert the flush loop references the rederive helper and the
# drop/preserve branches.
if ! printf '%s' "$flush_body" | grep -q "bridge_tmux_pending_attention_is_queue_nudge"; then
  echo "[smoke][error] S1: flusher does not gate the rederive on the nudge detector" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: flusher gates rederive on is_queue_nudge"
fi

if ! printf '%s' "$flush_body" | grep -Eq 'rederive_rc == 2'; then
  echo "[smoke][error] S1: flusher does not drop on confirmed-empty (rc=2)" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: flusher drops the entry on rc=2 (confirmed count==0)"
fi

if ! grep -q "bridge_tmux_pending_attention_task_complete_id" "$tmux_sh"; then
  echo "[smoke][error] S1: lib/bridge-tmux.sh does not define the task-complete detector" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: task-complete detector is defined in lib/bridge-tmux.sh"
fi

if ! printf '%s' "$flush_body" | grep -q "bridge_tmux_pending_attention_task_complete_id"; then
  echo "[smoke][error] S1: flusher does not gate on the task-complete detector" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: flusher gates non-nudge completion payloads on task-complete detector"
fi

if ! printf '%s' "$flush_body" | grep -q "bridge_tmux_pending_attention_task_complete_is_done"; then
  echo "[smoke][error] S1: flusher does not call the task-complete stale checker" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: flusher gates task-complete drops on the stale checker"
fi

if ! grep -q "task-status" "$REPO_ROOT/bridge-daemon-helpers.py"; then
  echo "[smoke][error] S1: bridge-daemon-helpers.py is missing the bounded task-status helper" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: task-status helper is registered for bounded status reads"
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
