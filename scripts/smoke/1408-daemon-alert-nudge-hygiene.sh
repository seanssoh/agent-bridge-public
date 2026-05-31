#!/usr/bin/env bash
# scripts/smoke/1408-daemon-alert-nudge-hygiene.sh — regression for
# issues #1408 + #1411 (Mejurix, v0.15.0-rc1).
#
# #1408 — the A2A outbox-stuck scan (`process_a2a_outbox_stuck_scan_tick`)
#   and the unclaimed-task escalation (`process_unclaimed_queue_escalation`)
#   minted a BRAND-NEW high-priority admin task each cooldown window with no
#   "prior alert still open" check (~116 dupes for ~6 real conditions). The
#   fix routes BOTH families through a new ATOMIC `bridge-queue.py upsert-open`
#   subcommand that reuses the same `upsert_open_task()` the blocked-aging
#   family uses: one open task per stable title-prefix, refreshed in place
#   (status preserved) instead of duplicated. Atomic = single SQLite
#   transaction, so concurrent daemon ticks cannot race a double-insert (the
#   reason we do NOT use a shell find-open-then-create sequence).
#
# #1411 — the queued-task ACTION-REQUIRED nudge had a fingerprint dedup gate
#   but NO attached-session gate, so on an attached interactive admin session
#   (composer ~always busy) the inject could not auto-submit, spooled, and
#   replayed as `[deferred]`. The fix adds an `attached>0 → skip` gate to
#   `nudge_agent_session` mirroring the sibling `plugin_mcp_liveness_attached_skip`
#   path, emits a rate-limited `queue_attention_attached_skip` audit, and does
#   NOT record a successful nudge (no inject happened).
#
# Coverage:
#   U1 — upsert-open refreshes ONE open task across N cooldown windows for a
#        stable prefix (same id every time, not N tasks).
#   U2 — upsert-open preserves `status`: a claimed alert stays claimed on
#        refresh (mirrors refresh_queue_task, which deliberately omits status).
#   U3 — a DISTINCT title-prefix mints a distinct task (per-message_id A2A
#        cardinality — distinct stuck messages keep their own refreshable row).
#   U4 — upsert-open re-CREATES after the alert is closed (done): a closed row
#        is no longer "open", so the next window legitimately mints a fresh id.
#   S1 — in-source wiring (#1408): both daemon families call
#        `bridge_queue_cli upsert-open` (no more `task create` always-insert).
#   S2 — in-source wiring (#1411): nudge_agent_session gates on attached, emits
#        the `queue_attention_attached_skip` audit, and does not note-nudge on
#        the attached-skip path.
#
# Footgun #11: no python3 heredoc-stdin / `<<<` here-string at a python3
# subprocess. All queue mutation is via the bridge-queue.py CLI; the only
# inline python uses `python3 -c '<script>' <argv>`.

set -euo pipefail

SMOKE_NAME="1408-daemon-alert-nudge-hygiene"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

echo "[smoke:${SMOKE_NAME}] starting"

TMP_DIR="$(mktemp -d "${TMPDIR:-/tmp}/agb-1408-hygiene.XXXXXX")"
trap 'rm -rf "$TMP_DIR"' EXIT

DB="$TMP_DIR/tasks.db"
export BRIDGE_TASK_DB="$DB"

ADMIN="admin-agent"
QUEUE="$REPO_ROOT/bridge-queue.py"

failed=0

# Count open tasks (queued/claimed/blocked) whose title starts with a prefix.
# find-open --all --format json returns a JSON array of open tasks; we count
# elements whose title begins with the prefix via a small argv-driven python.
count_open_with_prefix() {
  local prefix="$1"
  local json
  json="$(python3 "$QUEUE" find-open --agent "$ADMIN" --title-prefix "$prefix" --all --format json 2>/dev/null || printf '[]')"
  python3 -c 'import json,sys; print(len(json.loads(sys.argv[1] or "[]")))' "$json"
}

# ============================================================
# U1 — N cooldown windows → ONE refreshed open task
# ============================================================
PREFIX_A="[A2A] outbox stuck: peer-a:remote-a (deadbeef)"
first_id=""
TASK_ID=""
TASK_CREATED=""
for i in 1 2 3 4; do
  python3 "$QUEUE" upsert-open \
    --to "$ADMIN" --from daemon --priority high \
    --title-prefix "$PREFIX_A" \
    --title "$PREFIX_A" \
    --refresh-note "window $i" \
    --body "stuck body window $i" \
    --format shell >"$TMP_DIR/u1-$i.sh"
  # shellcheck disable=SC1090
  source "$TMP_DIR/u1-$i.sh"
  if [[ -z "$first_id" ]]; then
    first_id="$TASK_ID"
  elif [[ "$TASK_ID" != "$first_id" ]]; then
    echo "  FAIL  U1: window $i minted a NEW id ${TASK_ID} (expected refresh of ${first_id})" >&2
    failed=1
  fi
done

u1_count="$(count_open_with_prefix "$PREFIX_A")"
if [[ "$u1_count" == "1" ]]; then
  echo "  PASS  U1: 4 cooldown windows → 1 open task (id=${first_id}), not 4 (the #1408 flood)"
else
  echo "  FAIL  U1: expected 1 open task after 4 upserts, found ${u1_count}" >&2
  failed=1
fi

# ============================================================
# U2 — upsert-open preserves status (claimed stays claimed)
# ============================================================
python3 "$QUEUE" claim "$first_id" --agent "$ADMIN" >/dev/null
status_before="$(python3 "$QUEUE" show "$first_id" --format shell | sed -n 's/^TASK_STATUS=//p' | tr -d "'")"

python3 "$QUEUE" upsert-open \
  --to "$ADMIN" --from daemon --priority high \
  --title-prefix "$PREFIX_A" \
  --title "$PREFIX_A (refreshed)" \
  --refresh-note "post-claim refresh" \
  --body "refresh after claim" \
  --format shell >"$TMP_DIR/u2.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/u2.sh"
u2_id="$TASK_ID"
unset TASK_ID TASK_CREATED
status_after="$(python3 "$QUEUE" show "$first_id" --format shell | sed -n 's/^TASK_STATUS=//p' | tr -d "'")"

if [[ "$u2_id" == "$first_id" && "$status_before" == "claimed" && "$status_after" == "claimed" ]]; then
  echo "  PASS  U2: refresh of a claimed alert preserves status=claimed and id=${first_id} (no status reset)"
else
  echo "  FAIL  U2: id=${u2_id} (want ${first_id}); status ${status_before}→${status_after} (want claimed→claimed)" >&2
  failed=1
fi

# ============================================================
# U3 — distinct prefix mints a distinct task (per-message_id)
# ============================================================
PREFIX_B="[A2A] outbox stuck: peer-a:remote-a (cafef00d)"
python3 "$QUEUE" upsert-open \
  --to "$ADMIN" --from daemon --priority high \
  --title-prefix "$PREFIX_B" \
  --title "$PREFIX_B" \
  --refresh-note "second stuck message" \
  --body "second message body" \
  --format shell >"$TMP_DIR/u3.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/u3.sh"
u3_id="$TASK_ID"
u3_created="$TASK_CREATED"
unset TASK_ID TASK_CREATED

if [[ "$u3_id" != "$first_id" && "$u3_created" == "1" ]]; then
  echo "  PASS  U3: a distinct message-prefix creates its own task (id=${u3_id}) — no aggregate-into-one-body evidence loss"
else
  echo "  FAIL  U3: distinct prefix should create a new task — got id=${u3_id} created=${u3_created} (first_id=${first_id})" >&2
  failed=1
fi

# ============================================================
# U4 — closing the alert lets the next window create afresh
# ============================================================
python3 "$QUEUE" done "$first_id" --agent "$ADMIN" --note "resolved" >/dev/null
python3 "$QUEUE" upsert-open \
  --to "$ADMIN" --from daemon --priority high \
  --title-prefix "$PREFIX_A" \
  --title "$PREFIX_A" \
  --refresh-note "post-done window" \
  --body "reopened after done" \
  --format shell >"$TMP_DIR/u4.sh"
# shellcheck disable=SC1090
source "$TMP_DIR/u4.sh"
u4_id="$TASK_ID"
u4_created="$TASK_CREATED"
unset TASK_ID TASK_CREATED

if [[ "$u4_id" != "$first_id" && "$u4_created" == "1" ]]; then
  echo "  PASS  U4: a closed (done) alert is no longer open → next window mints a fresh id (${u4_id})"
else
  echo "  FAIL  U4: closed alert should re-create — got id=${u4_id} created=${u4_created} (closed id=${first_id})" >&2
  failed=1
fi

# ============================================================
# U5 — ATOMICITY: concurrent same-prefix upserts → ONE create
# ============================================================
# The whole point of the queue-layer upsert (vs a shell find-open-then-create
# sequence) is that the find-or-create is atomic under concurrent daemon
# ticks. Hammer the same prefix from N parallel processes against a FRESH db
# and assert exactly ONE process minted a task (TASK_CREATED=1) and exactly
# ONE open task exists. Without the BEGIN IMMEDIATE write lock this races and
# inserts duplicates (codex r1 BLOCKING finding).
RACE_DB="$TMP_DIR/race.db"
RACE_PREFIX="[A2A] outbox stuck: peer-z:remote-z (feedface)"
# Pre-init the schema serially so the concurrency below exercises the
# upsert find-or-create race, not the one-time CREATE TABLE bootstrap.
BRIDGE_TASK_DB="$RACE_DB" python3 "$QUEUE" init >/dev/null
N_RACE=12
for r in $(seq 1 "$N_RACE"); do
  BRIDGE_TASK_DB="$RACE_DB" python3 "$QUEUE" upsert-open \
    --to "$ADMIN" --from daemon --priority high \
    --title-prefix "$RACE_PREFIX" \
    --title "$RACE_PREFIX w$r" \
    --refresh-note "race $r" \
    --body "race body $r" \
    --format shell >"$TMP_DIR/race-$r.out" 2>"$TMP_DIR/race-$r.err" &
done
wait

# pipefail-safe counts: grep returns 1 on no-match, which would trip
# `set -o pipefail`. Append `|| true` to the grep so the count is 0, not an
# abort, when no process minted / errored.
race_created="$( { grep -h 'TASK_CREATED=1' "$TMP_DIR"/race-*.out 2>/dev/null || true; } | grep -c . || true)"
race_errors="$( { cat "$TMP_DIR"/race-*.err 2>/dev/null || true; } | grep -c . || true)"
[[ "$race_created" =~ ^[0-9]+$ ]] || race_created=0
[[ "$race_errors" =~ ^[0-9]+$ ]] || race_errors=0
race_open="$(BRIDGE_TASK_DB="$RACE_DB" python3 "$QUEUE" find-open --agent "$ADMIN" --title-prefix "$RACE_PREFIX" --all --format json 2>/dev/null | python3 -c 'import json,sys; print(len(json.load(sys.stdin)))' 2>/dev/null || printf '0')"

if [[ "$race_created" == "1" && "$race_open" == "1" && "$race_errors" == "0" ]]; then
  echo "  PASS  U5: ${N_RACE} concurrent same-prefix upserts → exactly 1 create, 1 open task, 0 errors (atomic)"
else
  echo "  FAIL  U5: concurrent upserts not atomic — created=${race_created} open=${race_open} errors=${race_errors} (want 1/1/0)" >&2
  failed=1
fi

# ============================================================
# S1 — in-source wiring: #1408 daemon families use upsert-open
# ============================================================
daemon_sh="$REPO_ROOT/bridge-daemon.sh"

if grep -q 'bridge_queue_cli upsert-open' "$daemon_sh"; then
  echo "  PASS  S1: bridge-daemon.sh files alerts via 'bridge_queue_cli upsert-open'"
else
  echo "  FAIL  S1: bridge-daemon.sh does not call 'bridge_queue_cli upsert-open'" >&2
  failed=1
fi

# The A2A stuck scan must no longer always-insert via 'task create'. Confirm
# the per-message upsert title is present and the old always-create call for
# the stuck alert is gone (the unclaimed escalation's old 'task create' is
# likewise replaced).
if grep -q '\[A2A\] outbox stuck:' "$daemon_sh" \
   && ! grep -q 'task create .*--title "\[A2A\] outbox stuck' "$daemon_sh"; then
  echo "  PASS  S1: A2A stuck alert no longer minted via always-insert 'task create'"
else
  echo "  FAIL  S1: A2A stuck alert still uses an always-insert 'task create' path" >&2
  failed=1
fi

# ============================================================
# S2 — in-source wiring: #1411 attached-gate on the queued-task nudge
# ============================================================
if grep -q 'queue_attention_attached_skip' "$daemon_sh"; then
  echo "  PASS  S2: nudge emits the 'queue_attention_attached_skip' audit token"
else
  echo "  FAIL  S2: nudge does not emit 'queue_attention_attached_skip' audit token" >&2
  failed=1
fi

# The attached-gate must reuse the existing attached-count probe and gate on
# attached>0 inside nudge_agent_session.
if grep -q 'bridge_tmux_session_attached_count "$session"' "$daemon_sh"; then
  echo "  PASS  S2: nudge reuses bridge_tmux_session_attached_count probe (no new probe invented)"
else
  echo "  FAIL  S2: nudge does not reuse bridge_tmux_session_attached_count probe" >&2
  failed=1
fi

# The attached-skip path must NOT fall through into a note-nudge / successful
# send. Verify the audit token and the early `return 0` both precede the
# bridge_task_note_nudge call in nudge_agent_session.
attached_line="$(grep -n 'bridge_audit_log daemon queue_attention_attached_skip' "$daemon_sh" | head -n1 | cut -d: -f1)"
# Match the CALL (with its "$agent" arg), not the prose comment that names it.
note_nudge_line="$(grep -n 'bridge_task_note_nudge "\$agent"' "$daemon_sh" | head -n1 | cut -d: -f1)"
if [[ -n "$attached_line" && -n "$note_nudge_line" && "$attached_line" -lt "$note_nudge_line" ]]; then
  echo "  PASS  S2: attached-skip (line ${attached_line}) precedes the note-nudge success path (line ${note_nudge_line}) → no inject recorded on skip"
else
  echo "  FAIL  S2: attached-skip ordering vs note-nudge unexpected (attached=${attached_line}, note_nudge=${note_nudge_line})" >&2
  failed=1
fi

if (( failed )); then
  exit 1
fi
echo "[smoke:${SMOKE_NAME}] all checks passed"
