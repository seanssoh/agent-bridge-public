#!/usr/bin/env bash
# shellcheck shell=bash
# scripts/smoke/1630-a2a-fresh-arrival-nudge.sh
#
# Issue #1630 (A2A audit R3, HIGH, root cause of #10561): an inbound A2A
# handoff that creates a queue task does NOT reliably wake the controller
# daemon for an immediate nudge. The receiver posts only a best-effort
# create-time push; if that push does not land (target session alive but
# not at a clean prompt), the daemon's periodic nudge emitter suppresses
# the fresh task for ~60s under the redelivery-AGE gate
# (BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS, bridge-queue.py
# cmd_daemon_step), so the task sits un-nudged.
#
# Fix: the A2A enqueue path posts a one-shot "fresh-arrival" marker file
# named <task_id> under $BRIDGE_STATE_DIR/queue/fresh-arrival/
# (bridge-handoffd.py::post_fresh_arrival_marker). The daemon nudge_scan
# step consumes those markers (bridge-queue.py::consume_fresh_arrival_
# markers) and exempts the named task ids from ONLY the redelivery-AGE
# gate for that tick — never any auth/dedupe/queue/idle/cooldown check —
# then deletes the consumed marker (one-shot).
#
# This smoke drives the REAL bridge-queue.py daemon-step and the REAL
# bridge-handoffd.py marker writer end to end against an isolated
# BRIDGE_HOME. No live Claude/Codex, no HTTP receiver — the enqueue +
# marker-post + age-gate decision are the units under test.
#
# Test plan:
#   T1 core fix: idle-eligible agent + FRESH task (< redelivery window) +
#       a fresh-arrival marker present → daemon-step emits the nudge on
#       this tick. (Pre-fix: the age gate suppressed it for ~60s.)
#   T2 no-hole regression: SAME fresh task, NO marker → daemon-step does
#       NOT emit. Proves the marker is what flips eligibility, not a
#       blanket bypass — the ~60s age gate for non-fresh-arrival tasks is
#       unchanged.
#   T3 periodic cadence regression: an AGED task (older than the window),
#       NO marker → daemon-step emits normally. The normal periodic nudge
#       cadence is untouched.
#   T4 one-shot: after T1's tick consumed the marker, a SECOND daemon-step
#       on the still-fresh task (marker now gone) does NOT emit. Proves
#       the exemption is one-shot and the age gate was not permanently
#       disabled.
#   T5 bypass-only-age: a marker for a fresh task on a BUSY agent (active,
#       idle_seconds < idle_threshold, not in the ready set) → daemon-step
#       does NOT emit. The marker bypasses ONLY the age gate; the idle
#       gate (the #1014-A/#1099 anti-spam invariant) is still enforced.
#   T6 writer: bridge-handoffd.py::post_fresh_arrival_marker actually
#       writes a marker the daemon then consumes (real writer → real
#       reader round trip), and a non-numeric/empty task id is a no-op.
#   T7 teeth: the receiver posts the marker and the daemon consumes it;
#       structural greps pin both halves so a future refactor that drops
#       either side fails this smoke.
#
# Footgun #11 (no python3 heredoc-stdin from a $()): every python3
# subprocess here reads its inputs via argv or file paths, never stdin.
# The marker-writer and created_ts-backdate helpers are written to
# standalone files on disk and invoked with file-as-argv.

set -euo pipefail

# Re-exec under Bash 4+ (associative arrays + the bridge libs).
if (( ${BASH_VERSINFO[0]:-0} < 4 )); then
  for _candidate in /opt/homebrew/bin/bash /usr/local/bin/bash "$HOME/.local/bin/bash"; do
    if [[ -x "$_candidate" ]] && "$_candidate" -c '[[ ${BASH_VERSINFO[0]:-0} -ge 4 ]]' >/dev/null 2>&1; then
      exec "$_candidate" "${BASH_SOURCE[0]}" "$@"
    fi
  done
  echo "[smoke:1630-a2a-fresh-arrival-nudge] requires Bash 4+ (host is ${BASH_VERSION})" >&2
  exit 1
fi

SMOKE_NAME="1630-a2a-fresh-arrival-nudge"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
REPO_ROOT="$(cd -P "$SCRIPT_DIR/../.." && pwd -P)"

# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

mkdir -p "$BRIDGE_STATE_DIR" "$BRIDGE_LOG_DIR"

# Pin the real default redelivery window so the FRESH/AGED boundary is the
# published 60s contract regardless of inherited env.
export BRIDGE_DAEMON_NUDGE_REDELIVERY_SECONDS=60
# Idle threshold low enough that an agent aged a couple minutes is clearly
# idle-eligible; cooldown low so a second tick is never cooldown-gated.
export BRIDGE_TASK_IDLE_NUDGE_SECONDS=30
export BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS=1

FRESH_ARRIVAL_DIR="$BRIDGE_STATE_DIR/queue/fresh-arrival"

# --- helpers ---------------------------------------------------------------

# write_snapshot <file> <agent> <session> <active> <activity_ts>
# Emits a single-row TSV snapshot in the bridge_write_agent_snapshot
# column order that load_snapshot()/cmd_daemon_step() consume.
write_snapshot() {
  local file="$1" agent="$2" session="$3" active="$4" activity_ts="$5"
  {
    printf 'agent\tengine\tsession\tworkdir\tactive\tsession_activity_ts\tprompt_ready_ts\tprompt_ready_session\tprompt_ready_source\tactivity_state\n'
    printf '%s\tclaude\t%s\t/tmp/x\t%s\t%s\t\t\t\t\n' "$agent" "$session" "$active" "$activity_ts"
  } >"$file"
}

# create_task <to> <title> -> echoes the new task id
create_task() {
  local to="$1" title="$2"
  local out
  out="$(python3 "$REPO_ROOT/bridge-queue.py" create \
    --to "$to" --from a2a-peer --title "$title" --body "body for $title" \
    --format shell)"
  # Source the shell-format output via a tempfile rather than a here-string
  # (`source /dev/stdin <<<"$out"`), which lint-heredoc-ban flags as an H3
  # here-string site. Tempfile source is equivalent and footgun-#11 clean.
  local _src_tmp
  _src_tmp="$(mktemp "${SMOKE_TMP_ROOT:-/tmp}/fresh-arrival-create.XXXXXX")"
  printf '%s\n' "$out" >"$_src_tmp"
  # shellcheck disable=SC1090
  source "$_src_tmp"
  rm -f "$_src_tmp"
  printf '%s' "$TASK_ID"
  unset TASK_ID
}

# run_daemon_step <snapshot> -> echoes the nudge TSV (empty = no candidate)
run_daemon_step() {
  local snapshot="$1"
  local ready_file="$SMOKE_TMP_ROOT/ready-agents.txt"
  : >"$ready_file"
  python3 "$REPO_ROOT/bridge-queue.py" daemon-step \
    --snapshot "$snapshot" \
    --ready-agents-file "$ready_file" \
    --lease-seconds 900 \
    --heartbeat-window 300 \
    --idle-threshold "$BRIDGE_TASK_IDLE_NUDGE_SECONDS" \
    --nudge-cooldown "$BRIDGE_TASK_NUDGE_COOLDOWN_SECONDS" \
    --admin-agent patch \
    --format tsv 2>/dev/null
}

post_marker() { mkdir -p "$FRESH_ARRIVAL_DIR"; printf '%s\n' "$(date +%s)" >"$FRESH_ARRIVAL_DIR/$1"; }

# backdate_created_ts <task_id> <seconds_ago> — make a task look old enough
# to age past the redelivery window naturally (no marker).
BACKDATE_HELPER="$SMOKE_TMP_ROOT/backdate-created-ts.py"
cat >"$BACKDATE_HELPER" <<'PYEOF'
import sqlite3, sys, time
db, task_id, secs = sys.argv[1], int(sys.argv[2]), int(sys.argv[3])
conn = sqlite3.connect(db)
conn.execute("UPDATE tasks SET created_ts=? WHERE id=?",
             (int(time.time()) - secs, task_id))
conn.commit()
conn.close()
PYEOF
backdate_created_ts() {
  python3 "$BACKDATE_HELPER" "$BRIDGE_TASK_DB" "$1" "$2"
}

# --- T1: core fix — idle-eligible agent, fresh task, marker → nudge fires ---
smoke_run "T1 fresh task + marker on idle-eligible agent → daemon nudges this tick" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID1="$(create_task agent-t1 'fresh A2A handoff')"
  # Agent active but idle past the threshold (parked, not mid-tool-turn) →
  # periodic emitter is eligible; only the age gate would hold the fresh task.
  snap="$SMOKE_TMP_ROOT/snap-t1.tsv"
  write_snapshot "$snap" agent-t1 sess-t1 1 "$(( $(date +%s) - 300 ))"
  post_marker "$TID1"
  out="$(run_daemon_step "$snap")"
  smoke_assert_contains "$out" "agent-t1" "T1 daemon emits a nudge candidate for agent-t1"
  smoke_assert_contains "$out" "$TID1" "T1 nudge key carries the fresh task id $TID1"
  # The marker must have been consumed (one-shot).
  [[ ! -e "$FRESH_ARRIVAL_DIR/$TID1" ]] || smoke_fail "T1 marker $TID1 must be consumed after the tick"
}

# --- T2: no-hole regression — same fresh task WITHOUT a marker → no nudge ---
smoke_run "T2 fresh task, NO marker → daemon suppresses (age gate intact)" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID2="$(create_task agent-t2 'fresh A2A handoff no marker')"
  snap="$SMOKE_TMP_ROOT/snap-t2.tsv"
  write_snapshot "$snap" agent-t2 sess-t2 1 "$(( $(date +%s) - 300 ))"
  # No marker posted.
  out="$(run_daemon_step "$snap")"
  smoke_assert_not_contains "$out" "agent-t2" "T2 no nudge for a fresh task without a marker (age gate holds)"
}

# --- T3: periodic cadence regression — aged task, no marker → nudge fires ---
smoke_run "T3 aged task, NO marker → normal periodic nudge unchanged" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID3="$(create_task agent-t3 'aged handoff')"
  backdate_created_ts "$TID3" 180   # older than the 60s window
  snap="$SMOKE_TMP_ROOT/snap-t3.tsv"
  write_snapshot "$snap" agent-t3 sess-t3 1 "$(( $(date +%s) - 300 ))"
  out="$(run_daemon_step "$snap")"
  smoke_assert_contains "$out" "agent-t3" "T3 aged task still nudged by the periodic emitter (no marker needed)"
  smoke_assert_contains "$out" "$TID3" "T3 nudge key carries the aged task id $TID3"
}

# --- T4: one-shot — second tick on the still-fresh task, marker gone → none -
smoke_run "T4 one-shot: re-run on still-fresh task after marker consumed → no nudge" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID4="$(create_task agent-t4 'fresh handoff oneshot')"
  snap="$SMOKE_TMP_ROOT/snap-t4.tsv"
  write_snapshot "$snap" agent-t4 sess-t4 1 "$(( $(date +%s) - 300 ))"
  post_marker "$TID4"
  out1="$(run_daemon_step "$snap")"
  smoke_assert_contains "$out1" "agent-t4" "T4 first tick nudges (marker present)"
  [[ ! -e "$FRESH_ARRIVAL_DIR/$TID4" ]] || smoke_fail "T4 marker must be consumed after first tick"
  # Second tick: task is STILL fresh (< 60s) but the marker is gone.
  out2="$(run_daemon_step "$snap")"
  smoke_assert_not_contains "$out2" "agent-t4" "T4 second tick: still-fresh task no longer nudged (gate not permanently disabled)"
}

# --- T5: bypass-only-age — marker does NOT override the idle gate -----------
smoke_run "T5 busy agent (idle < threshold) + marker → idle gate still blocks" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID5="$(create_task agent-t5 'fresh handoff busy agent')"
  snap="$SMOKE_TMP_ROOT/snap-t5.tsv"
  # Agent active and RECENTLY active (idle_seconds ~5s << idle_threshold 30s),
  # not in the ready set → the idle gate must skip it regardless of the marker.
  write_snapshot "$snap" agent-t5 sess-t5 1 "$(( $(date +%s) - 5 ))"
  post_marker "$TID5"
  out="$(run_daemon_step "$snap")"
  smoke_assert_not_contains "$out" "agent-t5" "T5 marker bypasses ONLY the age gate, not the idle gate"
}

# --- T6: real writer → real reader round trip ------------------------------
smoke_run "T6 bridge-handoffd post_fresh_arrival_marker writes a marker the daemon consumes" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID6="$(create_task agent-t6 'fresh handoff writer')"
  # Invoke the REAL receiver-side writer via a thin argv helper (no HTTP).
  WRITER_HELPER="$SMOKE_TMP_ROOT/post-marker.py"
  cat >"$WRITER_HELPER" <<'PYEOF'
import importlib.util, sys, pathlib
repo = pathlib.Path(sys.argv[1])
# bridge-handoffd.py imports `bridge_a2a_common` as a sibling module — put the
# repo root on sys.path so the import resolves when loaded by file path.
sys.path.insert(0, str(repo))
spec = importlib.util.spec_from_file_location("bridge_handoffd", repo / "bridge-handoffd.py")
mod = importlib.util.module_from_spec(spec)
spec.loader.exec_module(mod)
mod.post_fresh_arrival_marker(sys.argv[2])
# A non-numeric / empty id must be a no-op (no marker, no crash).
mod.post_fresh_arrival_marker("not-a-number")
mod.post_fresh_arrival_marker("")
PYEOF
  python3 "$WRITER_HELPER" "$REPO_ROOT" "$TID6"
  smoke_assert_file_exists "$FRESH_ARRIVAL_DIR/$TID6" "T6 writer created the marker for $TID6"
  [[ ! -e "$FRESH_ARRIVAL_DIR/not-a-number" ]] || smoke_fail "T6 non-numeric id must NOT create a marker"
  # Daemon consumes the writer's marker and nudges.
  snap="$SMOKE_TMP_ROOT/snap-t6.tsv"
  write_snapshot "$snap" agent-t6 sess-t6 1 "$(( $(date +%s) - 300 ))"
  out="$(run_daemon_step "$snap")"
  smoke_assert_contains "$out" "agent-t6" "T6 daemon consumes the writer's real marker and nudges"
  [[ ! -e "$FRESH_ARRIVAL_DIR/$TID6" ]] || smoke_fail "T6 writer's marker consumed after the tick"
}

# --- T8: claim-by-delete — an un-deletable marker never exempts (codex R1 P1) -
# A marker that the daemon cannot unlink (here: a numeric *directory*, which
# `Path.unlink()` refuses) must NOT exempt its task, otherwise it would keep
# bypassing the age gate on every tick forever. consume_fresh_arrival_markers
# returns an id ONLY after a successful unlink, so an un-deletable marker is a
# no-op for eligibility.
smoke_run "T8 un-deletable marker (numeric dir) never exempts → no nudge" : ; {
  rm -rf "$FRESH_ARRIVAL_DIR"
  TID8="$(create_task agent-t8 'fresh handoff undeletable marker')"
  mkdir -p "$FRESH_ARRIVAL_DIR/$TID8"   # a directory named <id> — unlink() will fail
  snap="$SMOKE_TMP_ROOT/snap-t8.tsv"
  write_snapshot "$snap" agent-t8 sess-t8 1 "$(( $(date +%s) - 300 ))"
  out="$(run_daemon_step "$snap")"
  smoke_assert_not_contains "$out" "agent-t8" "T8 un-claimable marker must NOT exempt the fresh task (claim-by-delete)"
  # A second tick must also not exempt — the marker was never claimed, so the
  # fresh task keeps waiting out the age gate (no perpetual bypass).
  out2="$(run_daemon_step "$snap")"
  smoke_assert_not_contains "$out2" "agent-t8" "T8 still no nudge on the next tick (no perpetual age-gate bypass)"
}

# --- T7: teeth — pin both halves of the wiring -----------------------------
smoke_run "T7 teeth: receiver posts the marker, daemon consumes + age-gate exemption" : ; {
  handoffd="$REPO_ROOT/bridge-handoffd.py"
  queue="$REPO_ROOT/bridge-queue.py"

  grep -q 'def post_fresh_arrival_marker' "$handoffd" \
    || smoke_fail "teeth: bridge-handoffd.py must define post_fresh_arrival_marker"
  grep -q 'post_fresh_arrival_marker(task_id)' "$handoffd" \
    || smoke_fail "teeth: bridge-handoffd.py must call post_fresh_arrival_marker on the accept path"
  grep -q 'post_fresh_arrival_marker(recovered_task_id)' "$handoffd" \
    || smoke_fail "teeth: bridge-handoffd.py must call post_fresh_arrival_marker on the recovered-id path"
  grep -q 'def consume_fresh_arrival_markers' "$queue" \
    || smoke_fail "teeth: bridge-queue.py must define consume_fresh_arrival_markers"
  grep -q 'fresh_arrival_ids = consume_fresh_arrival_markers()' "$queue" \
    || smoke_fail "teeth: cmd_daemon_step must consume the fresh-arrival markers"
  grep -q 'task_id in fresh_arrival_ids' "$queue" \
    || smoke_fail "teeth: the age gate must exempt fresh_arrival_ids (and ONLY the age gate)"
  # Claim-by-delete ordering (codex R1 P1): the id must be added to the set
  # AFTER the unlink, never before. Pin the unlink→add order so a refactor that
  # re-introduces add-before-unlink (the double-claim / perpetual-bypass bug)
  # fails the smoke. Footgun #11: the checker is written to a FILE and invoked
  # with the source path as argv — no heredoc-stdin into a subprocess.
  grep -q 'ids.add(task_id)' "$queue" \
    || smoke_fail "teeth: consume must add the id only after a successful unlink (claim-by-delete)"
  ORDER_HELPER="$SMOKE_TMP_ROOT/claim-by-delete-order.py"
  cat >"$ORDER_HELPER" <<'PYEOF'
import sys, re
src = open(sys.argv[1], encoding="utf-8").read()
m = re.search(r"\ndef consume_fresh_arrival_markers\(.*?\n(?=\ndef )", src, re.S)
if not m:
    print("consume_fresh_arrival_markers not found", file=sys.stderr)
    sys.exit(1)
body = m.group(0)
add_idx = body.index("ids.add(task_id)")
unlink_idx = body.rindex("entry.unlink()", 0, add_idx)
between = body[unlink_idx:add_idx]
if "continue" not in between:
    print("claim-by-delete: a failed unlink must `continue` before ids.add(task_id)", file=sys.stderr)
    sys.exit(1)
PYEOF
  python3 "$ORDER_HELPER" "$queue" \
    || smoke_fail "teeth: claim-by-delete ordering check failed (id must be added only after a successful unlink)"
  # Both sides must resolve the same marker dir name.
  grep -q '"queue" / "fresh-arrival"' "$handoffd" \
    || smoke_fail "teeth: bridge-handoffd.py marker dir must be queue/fresh-arrival"
  grep -q '"queue" / "fresh-arrival"' "$queue" \
    || smoke_fail "teeth: bridge-queue.py marker dir must be queue/fresh-arrival"
}

smoke_log "all checks passed"
