#!/usr/bin/env bash
# scripts/smoke/1617-pending-attention-arrival-stale.sh — regression for
# issue #1617 (generalizes #1952 / follows #1425).
#
# The deferred pending-attention flush re-validates staleness with ONE
# type-agnostic gate over `task #N`-bearing notifications. Before #1617 the
# matcher required the literal `[task-complete]` after the `task #N:` header,
# so a new-task ARRIVAL notification —
#   [Agent Bridge] task #<id>: <title>
#   agb inbox <agent>
# — matched NEITHER the queue-nudge branch (#1425) NOR the completion branch
# (#1952). It replayed verbatim even after the referenced task was already
# claimed+done during the busy window → a stale `[deferred]` nudge for a
# done task.
#
# The #1617 fix generalizes the matcher to ANY producer-shaped `task #N`
# header (arrival OR completion, priority variants included), anchored to the
# FIRST LINE only (never a body substring — the #1952 safety rationale). The
# flush then drops the entry ONLY when a bounded DB read CONFIRMS the
# referenced task is `done`. FAIL-SAFE: a queued/missing/read-failure/timeout
# status is KEEP (replay), never a silent drop.
#
# This smoke drives the REAL bridge_tmux_pending_attention_flush loop with a
# recording send stub and asserts the observable effect:
#   A1 — DONE arrival notification → DROPPED (no send). TEETH: reverting the
#        matcher generalization (re-adding the `[task-complete]` requirement)
#        makes the arrival fall through to verbatim replay → this fails.
#   A2 — QUEUED (open) arrival notification → REPLAYED (control: a NOT-done
#        task must keep firing).
#   A3 — DONE arrival with a PRIORITY header (`high task #N:`) → DROPPED
#        (the optional priority group must still match the unified gate).
#   A4 — MISSING/unknown arrival task → REPLAYED (fail-safe preserve).
#   A5 — task-status READ FAILURE (corrupt DB) → REPLAYED (fail-safe preserve;
#        a transient read failure must never look like done).
#   A6 — body-quoted arrival header (real header is a benign first line) →
#        REPLAYED (header-anchored: a quoted `task #N:` in the body must not
#        trip the drop, even if that body task is done).
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at the point of a
# python3 subprocess. DB seeding uses bridge-queue.py + tempfile source;
# fixtures use printf (matches 1425-spool-rederive).

set -euo pipefail

SMOKE_NAME="1617-pending-attention-arrival-stale"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1617-arrival.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

# ============================================================
# Real-flush teeth (sourced lib stack)
# ============================================================
# Set up the isolated v2 BRIDGE_HOME (env + layout marker) BEFORE sourcing
# bridge-lib.sh so a clean CI runner with no inherited v2 env/marker does not
# abort with the isolation-v2 markerless error. scripts/smoke/lib.sh::
# smoke_setup_bridge_home is the canonical helper (writes
# state/layout-marker.sh with BRIDGE_LAYOUT=v2 and exports the isolated env).
# Mirrors scripts/smoke/1425-spool-rederive.sh.
#
# Footgun #11: stage the inner script in a tempfile and run it by path rather
# than piping a heredoc into `bash -s` stdin.
ARRIVAL_UT="$TMP_DIR/arrival-ut.sh"
cat > "$ARRIVAL_UT" <<'ARRIVAL_UT_BODY'
set -u
repo="$1"
scratch="$2"
export SMOKE_NAME="1617-pending-attention-arrival-stale"
# shellcheck disable=SC1090
source "$repo/scripts/smoke/lib.sh"
# Isolated v2 BRIDGE_HOME + layout marker — MUST run before bridge-lib.sh.
smoke_setup_bridge_home "1617-pending-attention-arrival-stale"
trap 'smoke_cleanup_temp_root' EXIT
# shellcheck disable=SC1090
source "$repo/bridge-lib.sh"

fail() { printf '[smoke][error] arrival: %s\n' "$*" >&2; exit 1; }

agent="arrival-agent"

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

close_task() {
  local tid="$1"
  python3 "$repo/bridge-queue.py" claim "$tid" --agent "$agent" >/dev/null
  python3 "$repo/bridge-queue.py" done "$tid" --agent "$agent" --note "seen" >/dev/null
}

# A corrupt DB stands in for a wedged/timed-out queue read.
corrupt_db="$scratch/corrupt.db"
printf 'this is not a sqlite database' > "$corrupt_db"

# Record what the flusher hands to send_and_submit (no real tmux). Returning 0
# means the entry is NOT re-spooled, so a recorded send == a replay and an
# empty log == a drop.
sent_log="$scratch/arrival-sent.log"
bridge_tmux_send_and_submit() {
  # $1=session $2=engine $3=decoded payload.
  printf '%s\n' "$3" >> "$sent_log"
  return 0
}
flush_agent="arrival-flush-agent"
reset_spool() {
  : > "$sent_log"
  local sf
  sf="$(bridge_agent_pending_attention_file "$flush_agent")"
  mkdir -p "$(dirname "$sf")"
  : > "$sf"
}
sent_count() { awk 'END{print NR+0}' "$sent_log"; }
sent_contains() { grep -qF -- "$1" "$sent_log"; }

# ---- A1: DONE arrival notification → DROPPED -------------------------------
# The exact producer shape for a new-task arrival (no `[task-complete]`):
#   [Agent Bridge] task #<id>: <title>\nagb inbox <agent>
reset_spool
done_id="$(create_task "fix docs typo" normal)"
[[ -n "$done_id" ]] || fail "A1: arrival task id empty"
close_task "$done_id"
done_arrival="[Agent Bridge] task #${done_id}: fix docs typo"$'\n'"agb inbox ${agent}"
bridge_tmux_pending_attention_append "$flush_agent" "$done_arrival"
bridge_tmux_pending_attention_flush "arrival-session" claude "$flush_agent" || true
if (( "$(sent_count)" != 0 )); then
  fail "A1: a DONE ARRIVAL notification was REPLAYED (send_and_submit called $(sent_count)x) — the unified stale gate did not fire. This is exactly the #1617 leak: re-adding the [task-complete] requirement to the matcher reproduces it."
fi
printf '[smoke]   [ok] A1: DONE task-arrival notification is DROPPED by the real flush (no send)\n'

# ---- A2: QUEUED (open) arrival → REPLAYED (control) ------------------------
reset_spool
open_id="$(create_task "still open arrival" normal)"
[[ -n "$open_id" ]] || fail "A2: open arrival task id empty"
open_arrival="[Agent Bridge] task #${open_id}: still open arrival"$'\n'"agb inbox ${agent}"
bridge_tmux_pending_attention_append "$flush_agent" "$open_arrival"
bridge_tmux_pending_attention_flush "arrival-session" claude "$flush_agent" || true
(( "$(sent_count)" >= 1 )) || fail "A2: a QUEUED arrival notification was DROPPED — a not-done task must keep firing (control)"
sent_contains "still open arrival" || fail "A2: queued arrival payload not handed to send_and_submit: $(cat "$sent_log")"
printf '[smoke]   [ok] A2: QUEUED task-arrival notification is REPLAYED by the real flush (control: not-done keeps)\n'

# ---- A3: DONE arrival with PRIORITY header → DROPPED -----------------------
# `[Agent Bridge] high task #N: <title>` — the optional priority group must
# still resolve through the unified gate.
reset_spool
prio_id="$(create_task "priority arrival" high)"
[[ -n "$prio_id" ]] || fail "A3: priority arrival task id empty"
close_task "$prio_id"
prio_arrival="[Agent Bridge] high task #${prio_id}: priority arrival"$'\n'"agb inbox ${agent}"
bridge_tmux_pending_attention_append "$flush_agent" "$prio_arrival"
bridge_tmux_pending_attention_flush "arrival-session" claude "$flush_agent" || true
if (( "$(sent_count)" != 0 )); then
  fail "A3: a DONE priority arrival ('high task #N:') was REPLAYED (send called $(sent_count)x) — the optional priority group must match the unified gate"
fi
printf '[smoke]   [ok] A3: DONE priority task-arrival ('"'"'high task #N:'"'"') is DROPPED by the real flush\n'

# ---- A4: MISSING/unknown arrival task → REPLAYED (fail-safe) ---------------
reset_spool
missing_arrival="[Agent Bridge] task #99999999: unknown arrival"$'\n'"agb inbox ${agent}"
bridge_tmux_pending_attention_append "$flush_agent" "$missing_arrival"
bridge_tmux_pending_attention_flush "arrival-session" claude "$flush_agent" || true
(( "$(sent_count)" >= 1 )) || fail "A4: a MISSING-task arrival was DROPPED — an unconfirmable status must preserve (replay), never drop"
sent_contains "unknown arrival" || fail "A4: missing-task arrival payload not handed to send_and_submit: $(cat "$sent_log")"
printf '[smoke]   [ok] A4: MISSING task-arrival notification is REPLAYED (fail-safe preserve)\n'

# ---- A5: task-status READ FAILURE (corrupt DB) → REPLAYED (fail-safe) ------
# A done task whose status read cannot complete must NEVER look like done.
reset_spool
readfail_arrival="[Agent Bridge] task #${done_id}: read failure arrival"$'\n'"agb inbox ${agent}"
bridge_tmux_pending_attention_append "$flush_agent" "$readfail_arrival"
BRIDGE_TASK_DB="$corrupt_db" \
  bridge_tmux_pending_attention_flush "arrival-session" claude "$flush_agent" || true
(( "$(sent_count)" >= 1 )) || fail "A5: a task-status READ-FAILURE arrival was DROPPED — a read failure must FAIL-SAFE to replay, never be mistaken for done"
sent_contains "read failure arrival" || fail "A5: read-failure arrival payload not handed to send_and_submit: $(cat "$sent_log")"
printf '[smoke]   [ok] A5: task-status READ-FAILURE arrival is REPLAYED (fail-safe preserve)\n'

# ---- A6: body-quoted arrival header → REPLAYED (header-anchored) -----------
# The real first line is a benign send; the DONE task's arrival header appears
# only on a SUBSEQUENT body line. The matcher is anchored to the first line,
# so it must NOT classify this as a task-ref drop even though the quoted task
# is done — otherwise an unrelated send could be silently dropped.
reset_spool
quoted_payload="[Agent Bridge] urgent: heads up from ops"$'\n'"please handle: [Agent Bridge] task #${done_id}: fix docs typo"
bridge_tmux_pending_attention_append "$flush_agent" "$quoted_payload"
bridge_tmux_pending_attention_flush "arrival-session" claude "$flush_agent" || true
(( "$(sent_count)" >= 1 )) || fail "A6: a body-quoted arrival header was DROPPED — the gate is header-anchored; a quoted task #N in the body must NEVER trip the drop"
sent_contains "heads up from ops" || fail "A6: body-quoted payload not handed to send_and_submit: $(cat "$sent_log")"
printf '[smoke]   [ok] A6: body-quoted arrival header is REPLAYED (header-anchored, no body-substring drop)\n'

unset -f bridge_tmux_send_and_submit
printf '[smoke]   [ok] arrival flush-teeth block passed\n'
ARRIVAL_UT_BODY

failed=0
if "${BASH:-bash}" "$ARRIVAL_UT" "$REPO_ROOT" "$TMP_DIR"; then
  :
else
  echo "[smoke][error] ${SMOKE_NAME}: arrival flush-teeth block FAILED" >&2
  failed=1
fi

# ============================================================
# S1 — in-source wiring (static grep)
# ============================================================
# The flusher is coupled to the daemon main loop (same pattern as
# 1425-spool-rederive S1 / 1106-nudge-shell-recheck S1): assert the unified
# task-ref gate is wired into bridge_tmux_pending_attention_flush so a refactor
# cannot silently regress the arrival drop back to a per-type matcher.
tmux_sh="$REPO_ROOT/lib/bridge-tmux.sh"
flush_body="$(awk '/^bridge_tmux_pending_attention_flush\(\)/{f=1} f{print} /^}/{if(f)exit}' "$tmux_sh")"

if ! grep -q "bridge_tmux_pending_attention_task_ref_id" "$tmux_sh"; then
  echo "[smoke][error] S1: lib/bridge-tmux.sh does not define the unified task-ref detector" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: unified task-ref detector is defined in lib/bridge-tmux.sh"
fi

if ! printf '%s' "$flush_body" | grep -q "bridge_tmux_pending_attention_task_ref_id"; then
  echo "[smoke][error] S1: flusher does not gate non-nudge task #N payloads on the unified detector" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: flusher gates non-nudge task #N payloads on the unified task-ref detector"
fi

if ! printf '%s' "$flush_body" | grep -q "bridge_tmux_pending_attention_task_ref_is_done"; then
  echo "[smoke][error] S1: flusher does not call the unified task-ref stale checker" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: flusher gates task-ref drops on the unified stale checker (bounded task-status read)"
fi

# The unified matcher must NOT have re-grown a `[task-complete]`-only literal
# requirement (that would reintroduce the #1617 arrival gap). The detector body
# anchors on `task[[:space:]]#` and must not require `[task-complete]`.
detector_body="$(awk '/^bridge_tmux_pending_attention_task_ref_id\(\)/{f=1} f{print} /^}/{if(f)exit}' "$tmux_sh")"
if printf '%s' "$detector_body" | grep -q 'task-complete'; then
  echo "[smoke][error] S1: the unified task-ref matcher still requires [task-complete] — arrival headers would leak (#1617 regression)" >&2
  failed=1
else
  echo "[smoke]   [ok] S1: the unified task-ref matcher does not require [task-complete] (arrival headers covered)"
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
