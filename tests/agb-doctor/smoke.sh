#!/usr/bin/env bash
# agb-doctor smoke — issue #511 read-only stuck-state detector CLI.
#
# Exercises the four detectors via fixture roster JSON (so the test does not
# depend on a live agent-bridge binary or roster) plus a hand-built sqlite
# tasks.db. Every case is independent: each scenario builds its own fixture
# directory, invokes `bridge-doctor.py --json`, and asserts the resulting
# finding list shape against the issue spec.
#
# Cases (mirroring the brief's test plan):
#
#   D1a  empty state                          -> []
#   D1b  one stale-stopped-with-queue agent   -> 1 finding, evidence shape
#   D1c  loop=0 (disabled)                    -> 0 findings (loop required)
#   D1d  queued=0 AND blocked=0               -> 0 findings (backlog required)
#   D2a  blocked task aged 25h, owner idle    -> stale-blocked-task finding
#   D2b  blocked task aged 1h                 -> 0 findings
#   D2c  blocked task aged 25h, owner working -> 0 findings (only idle)
#   D2d  threshold env override (3600s) +     -> stale-blocked-task finding
#        90-min-old blocked task
#   D4   abnormal-session-pane (placeholder)  -> exactly one detector-error
#                                               row; never a hard crash
#   D5   --detectors stale-blocked-task       -> only that kind survives
#   D6   daemon-level finding (agent="")      -> renders cleanly in table
#   D7a  cold-restart-suspect, prior /exit    -> 0 findings (#588 clean exit)
#   D7b  cold-restart-suspect, no exit marker -> 1 finding (real cold restart)
#
# Uses an isolated mktemp BRIDGE_HOME — never touches the live install.

set -uo pipefail

REPO_ROOT="$(cd -P "$(dirname "${BASH_SOURCE[0]}")"/../.. && pwd -P)"
PYTHON="${BRIDGE_PYTHON:-$(command -v python3 || echo /usr/bin/python3)}"
DOCTOR="$REPO_ROOT/bridge-doctor.py"
ASSERT_HELPER="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)/_assert.py"

if [[ ! -x "$PYTHON" && ! -r "$PYTHON" ]]; then
  printf '[smoke][error] python3 not found at %s\n' "$PYTHON" >&2
  exit 2
fi
if [[ ! -f "$DOCTOR" ]]; then
  printf '[smoke][error] bridge-doctor.py not found at %s\n' "$DOCTOR" >&2
  exit 2
fi
if [[ ! -f "$ASSERT_HELPER" ]]; then
  printf '[smoke][error] _assert.py helper missing alongside smoke.sh\n' >&2
  exit 2
fi

ROOT="$(mktemp -d -t agb-doctor-smoke.XXXXXX)"
trap 'rm -rf "$ROOT"' EXIT

PASS=0
FAIL=0
FAILURES=()

pass() {
  PASS=$((PASS + 1))
  printf '[smoke][pass] %s\n' "$1"
}

fail() {
  FAIL=$((FAIL + 1))
  FAILURES+=("$1")
  printf '[smoke][fail] %s\n' "$1" >&2
}

# init_db <path>
# Build an empty queue DB matching bridge-queue.py init_db().
init_db() {
  local db="$1"
  "$PYTHON" - "$db" <<'PY'
import sqlite3, sys
conn = sqlite3.connect(sys.argv[1])
conn.executescript("""
CREATE TABLE tasks (
  id INTEGER PRIMARY KEY AUTOINCREMENT,
  title TEXT NOT NULL,
  assigned_to TEXT NOT NULL,
  created_by TEXT NOT NULL,
  priority TEXT NOT NULL DEFAULT 'normal',
  status TEXT NOT NULL DEFAULT 'queued',
  created_ts INTEGER NOT NULL,
  updated_ts INTEGER NOT NULL,
  body_text TEXT,
  body_path TEXT,
  claimed_by TEXT,
  claimed_ts INTEGER,
  lease_until_ts INTEGER,
  closed_ts INTEGER
);
CREATE TABLE agent_state (
  agent TEXT PRIMARY KEY,
  engine TEXT,
  session TEXT,
  workdir TEXT,
  active INTEGER NOT NULL DEFAULT 0,
  last_seen_ts INTEGER,
  last_heartbeat_ts INTEGER,
  session_activity_ts INTEGER,
  last_nudge_ts INTEGER,
  last_nudge_key TEXT,
  nudge_fail_count INTEGER NOT NULL DEFAULT 0,
  zombie INTEGER NOT NULL DEFAULT 0
);
""")
conn.commit()
conn.close()
PY
}

# write_roster <path> <json>
write_roster() {
  printf '%s\n' "$2" >"$1"
}

# insert_task <db> <id> <assigned_to> <claimed_by> <status> <updated_ts>
insert_task() {
  local db="$1" tid="$2" assigned="$3" owner="$4" status="$5" updated="$6"
  "$PYTHON" - "$db" "$tid" "$assigned" "$owner" "$status" "$updated" <<'PY'
import sqlite3, sys
db, tid, assigned, owner, status, updated = sys.argv[1:7]
conn = sqlite3.connect(db)
conn.execute(
    "INSERT INTO tasks (id, title, assigned_to, created_by, status, "
    "created_ts, updated_ts, claimed_by, claimed_ts) "
    "VALUES (?, ?, ?, ?, ?, ?, ?, ?, ?)",
    (
        int(tid),
        f"smoke task {tid}",
        assigned,
        "smoke",
        status,
        int(updated),
        int(updated),
        owner or None,
        int(updated) if owner else None,
    ),
)
conn.commit()
conn.close()
PY
}

# run_doctor <case-dir> <extra args...>
run_doctor() {
  local dir="$1"
  shift
  local roster="$dir/agents.json"
  local db="$dir/tasks.db"
  "$PYTHON" "$DOCTOR" \
    --json \
    --agent-list-json "$roster" \
    --task-db "$db" \
    --projects-root "$dir/no-such-claude-projects" \
    "$@"
}

# json_assert <payload-string> <check-name> <case-label> [extra args]
# `check-name` is one of the named predicates in tests/agb-doctor/_assert.py.
# Extra args after the label are forwarded to the helper.
json_assert() {
  local payload="$1"
  local check="$2"
  local label="$3"
  shift 3
  if "$PYTHON" "$ASSERT_HELPER" "$check" "$payload" "$@" >/dev/null 2>&1; then
    pass "$label"
  else
    fail "$label — payload=$payload check=$check args=$*"
  fi
}

NOW="$("$PYTHON" -c 'import time; print(int(time.time()))')"

# --- D1a: empty state ---------------------------------------------------
D1a="$ROOT/d1a"
mkdir -p "$D1a"
init_db "$D1a/tasks.db"
write_roster "$D1a/agents.json" "[]"
out_d1a="$(run_doctor "$D1a")"
json_assert "$out_d1a" empty "D1a empty state -> []"

# Table mode: assert the empty-state human string.
out_d1a_tbl="$("$PYTHON" "$DOCTOR" \
  --agent-list-json "$D1a/agents.json" \
  --task-db "$D1a/tasks.db" \
  --projects-root "$D1a/no-such-claude-projects" 2>&1)"
if [[ "$out_d1a_tbl" == *"No stuck-state signals detected."* ]]; then
  pass "D1a table mode -> 'No stuck-state signals detected.'"
else
  fail "D1a table mode wrong output: $out_d1a_tbl"
fi

# --- D1b: one stale-stopped-with-queue ---------------------------------
D1b="$ROOT/d1b"
mkdir -p "$D1b"
init_db "$D1b/tasks.db"
"$PYTHON" - "$D1b/tasks.db" "$NOW" <<'PY'
import sqlite3, sys
db, now = sys.argv[1], int(sys.argv[2])
conn = sqlite3.connect(db)
conn.execute(
    "INSERT INTO agent_state (agent, engine, session, active, last_seen_ts, "
    "session_activity_ts) VALUES (?, ?, ?, ?, ?, ?)",
    ("syrs-calendar", "claude", "syrs-calendar", 0, now - 600000, now - 600000),
)
conn.commit()
conn.close()
PY
write_roster "$D1b/agents.json" '[{"agent":"syrs-calendar","engine":"claude","active":false,"activity_state":"stopped","loop":1,"queue":{"queued":4,"blocked":0,"claimed":0}}]'
out_d1b="$(run_doctor "$D1b")"
json_assert "$out_d1b" stale_stopped_emitted \
  "D1b stale-stopped-with-queue emitted" syrs-calendar
json_assert "$out_d1b" stale_stopped_evidence_shape \
  "D1b evidence shape matches spec"
json_assert "$out_d1b" suggested_action_equals \
  "D1b suggested_action is the restart hint" \
  stale-stopped-with-queue "agent-bridge agent restart syrs-calendar"

# --- D1c: stopped + loop=0 -> NO finding -------------------------------
D1c="$ROOT/d1c"
mkdir -p "$D1c"
init_db "$D1c/tasks.db"
write_roster "$D1c/agents.json" '[{"agent":"loopless","engine":"claude","active":false,"activity_state":"stopped","loop":0,"queue":{"queued":4,"blocked":2,"claimed":0}}]'
out_d1c="$(run_doctor "$D1c")"
json_assert "$out_d1c" kind_absent \
  "D1c loop=0 produces no stale-stopped-with-queue" stale-stopped-with-queue

# --- D1d: stopped, loop=1, queued=0, blocked=0 -> NO finding -----------
D1d="$ROOT/d1d"
mkdir -p "$D1d"
init_db "$D1d/tasks.db"
write_roster "$D1d/agents.json" '[{"agent":"empty-bag","engine":"claude","active":false,"activity_state":"stopped","loop":1,"queue":{"queued":0,"blocked":0,"claimed":0}}]'
out_d1d="$(run_doctor "$D1d")"
json_assert "$out_d1d" kind_absent \
  "D1d empty backlog produces no stale-stopped-with-queue" stale-stopped-with-queue

# --- D2a: blocked aged 25h, owner idle ---------------------------------
D2a="$ROOT/d2a"
mkdir -p "$D2a"
init_db "$D2a/tasks.db"
old="$((NOW - 90000))"  # 25h ago
insert_task "$D2a/tasks.db" 11 "librarian" "librarian" "blocked" "$old"
write_roster "$D2a/agents.json" '[{"agent":"librarian","engine":"claude","active":true,"activity_state":"idle","loop":1,"queue":{"queued":0,"blocked":1,"claimed":0}}]'
out_d2a="$(run_doctor "$D2a")"
json_assert "$out_d2a" stale_blocked_task_id \
  "D2a stale-blocked-task emitted" 11
json_assert "$out_d2a" stale_blocked_suggested_prefix \
  "D2a suggested_action targets task 11" \
  "agent-bridge update 11 --status queued"

# --- D2b: blocked aged 1h -> NO finding --------------------------------
D2b="$ROOT/d2b"
mkdir -p "$D2b"
init_db "$D2b/tasks.db"
recent="$((NOW - 3600))"  # 1h ago
insert_task "$D2b/tasks.db" 12 "librarian" "librarian" "blocked" "$recent"
write_roster "$D2b/agents.json" '[{"agent":"librarian","engine":"claude","active":true,"activity_state":"idle","loop":1,"queue":{"queued":0,"blocked":1,"claimed":0}}]'
out_d2b="$(run_doctor "$D2b")"
json_assert "$out_d2b" kind_absent \
  "D2b 1h-old blocked task does not trip default 24h threshold" stale-blocked-task

# --- D2c: blocked aged 25h but owner working -> NO finding -------------
D2c="$ROOT/d2c"
mkdir -p "$D2c"
init_db "$D2c/tasks.db"
old="$((NOW - 90000))"
insert_task "$D2c/tasks.db" 13 "worker-bee" "worker-bee" "blocked" "$old"
write_roster "$D2c/agents.json" '[{"agent":"worker-bee","engine":"claude","active":true,"activity_state":"working","loop":1,"queue":{"queued":0,"blocked":1,"claimed":0}}]'
out_d2c="$(run_doctor "$D2c")"
json_assert "$out_d2c" kind_absent \
  "D2c working owner blocks the stale-blocked-task signal" stale-blocked-task

# --- D2d: threshold env override --------------------------------------
D2d="$ROOT/d2d"
mkdir -p "$D2d"
init_db "$D2d/tasks.db"
ninety_min="$((NOW - 5400))"  # 90 min ago
insert_task "$D2d/tasks.db" 14 "librarian" "librarian" "blocked" "$ninety_min"
write_roster "$D2d/agents.json" '[{"agent":"librarian","engine":"claude","active":true,"activity_state":"idle","loop":1,"queue":{"queued":0,"blocked":1,"claimed":0}}]'
out_d2d="$(BRIDGE_DOCTOR_BLOCKED_THRESHOLD_SECONDS=3600 \
  "$PYTHON" "$DOCTOR" \
  --json \
  --agent-list-json "$D2d/agents.json" \
  --task-db "$D2d/tasks.db" \
  --projects-root "$D2d/no-such-claude-projects")"
json_assert "$out_d2d" stale_blocked_task_id \
  "D2d threshold env override triggers stale-blocked-task at 90min" 14

# --- D4: abnormal-session-pane placeholder ----------------------------
D4="$ROOT/d4"
mkdir -p "$D4"
init_db "$D4/tasks.db"
write_roster "$D4/agents.json" "[]"
out_d4="$(run_doctor "$D4" --detectors abnormal-session-pane)"
json_assert "$out_d4" abnormal_pane_placeholder \
  "D4 abnormal-session-pane emits a single detector-error placeholder"
# pipefail above guards crash detection; if the CLI had segfaulted run_doctor
# would have failed and we would not have reached this line.
pass "D4 abnormal-session-pane CLI exits cleanly (no hard crash)"

# --- D5: --detectors filter --------------------------------------------
D5="$ROOT/d5"
mkdir -p "$D5"
init_db "$D5/tasks.db"
old="$((NOW - 90000))"
insert_task "$D5/tasks.db" 21 "librarian" "librarian" "blocked" "$old"
write_roster "$D5/agents.json" '[
  {"agent":"librarian","engine":"claude","active":true,"activity_state":"idle","loop":1,"queue":{"queued":0,"blocked":1,"claimed":0}},
  {"agent":"sleeper","engine":"claude","active":false,"activity_state":"stopped","loop":1,"queue":{"queued":3,"blocked":0,"claimed":0}}
]'
# Without filter: 2 kinds expected (stale-blocked-task + stale-stopped-with-queue).
out_d5_all="$(run_doctor "$D5")"
json_assert "$out_d5_all" kinds_superset \
  "D5 baseline emits both detector kinds" \
  stale-blocked-task stale-stopped-with-queue
# With filter: only stale-blocked-task survives, no detector-error rows leak.
out_d5_filter="$(run_doctor "$D5" --detectors stale-blocked-task)"
json_assert "$out_d5_filter" only_kind \
  "D5 --detectors stale-blocked-task isolates the kind" \
  stale-blocked-task

# --- D6: daemon-level finding renders cleanly --------------------------
# The placeholder abnormal-session-pane detector emits a detector-error
# row with agent="". Use it as the daemon-level finding and assert the
# table renderer prints "-" for the agent column without crashing.
D6="$ROOT/d6"
mkdir -p "$D6"
init_db "$D6/tasks.db"
write_roster "$D6/agents.json" "[]"
out_d6_tbl="$("$PYTHON" "$DOCTOR" \
  --agent-list-json "$D6/agents.json" \
  --task-db "$D6/tasks.db" \
  --projects-root "$D6/no-such-claude-projects" \
  --detectors abnormal-session-pane 2>&1)"
if [[ "$out_d6_tbl" == *"detector-error"* ]] && [[ "$out_d6_tbl" == *"-"* ]]; then
  pass "D6 daemon-level finding renders cleanly in table"
else
  fail "D6 table render did not contain expected fields: $out_d6_tbl"
fi

# --- D7: cold-restart-suspect clean-exit skip (#588) -------------------
#
# Each scenario builds:
#   - $dir/workdir            — agent's workdir (slug = "-...workdir")
#   - $dir/projects/<slug>/<current_sid>.jsonl  (stub, present so the
#                                                detector sees current_present)
#   - $dir/projects/<slug>/<prior_sid>.jsonl    (prior; mtime fresh; tail
#                                                may or may not contain a
#                                                clean-exit slash-command)
#
# The roster fixture pins workdir + session_id so the detector locates the
# slug deterministically.

# slug_for(workdir) — mirror workdir_slug_candidates() in bridge-doctor.py
slug_for() {
  printf '%s' "$1" | tr '/' '-'
}

# build_cold_restart_fixture <dir> <prior-tail>
#   <dir>       — case dir; tasks.db + agents.json + projects/ live here
#   <prior-tail>— bytes appended to the prior jsonl (use "" for no marker)
build_cold_restart_fixture() {
  local dir="$1"
  local prior_tail="$2"
  mkdir -p "$dir"
  init_db "$dir/tasks.db"
  local workdir="$dir/workdir"
  mkdir -p "$workdir"
  local slug
  slug="$(slug_for "$workdir")"
  local proj_dir="$dir/projects/$slug"
  mkdir -p "$proj_dir"
  local current_sid="aaaaaaaa-aaaa-aaaa-aaaa-aaaaaaaaaaaa"
  local prior_sid="bbbbbbbb-bbbb-bbbb-bbbb-bbbbbbbbbbbb"
  # Current session jsonl — content irrelevant, just must exist.
  printf '{"type":"user"}\n' >"$proj_dir/$current_sid.jsonl"
  # Prior session jsonl — optionally seeded with the clean-exit marker.
  printf '{"type":"user"}\n%s' "$prior_tail" >"$proj_dir/$prior_sid.jsonl"
  # Make both files mtime fresh (within 7d window).
  touch "$proj_dir/$current_sid.jsonl" "$proj_dir/$prior_sid.jsonl"
  # Roster: one active claude agent with the pinned session_id + workdir.
  "$PYTHON" - "$dir/agents.json" "$workdir" "$current_sid" <<'PY'
import json, sys
out, workdir, sid = sys.argv[1], sys.argv[2], sys.argv[3]
roster = [{
    "agent": "patch",
    "engine": "claude",
    "active": True,
    "activity_state": "idle",
    "loop": 1,
    "session_id": sid,
    "workdir": workdir,
    "queue": {"queued": 0, "blocked": 0, "claimed": 0},
}]
with open(out, "w", encoding="utf-8") as fh:
    json.dump(roster, fh)
PY
}

# run_doctor_with_projects <dir>
run_doctor_with_projects() {
  local dir="$1"
  "$PYTHON" "$DOCTOR" \
    --json \
    --agent-list-json "$dir/agents.json" \
    --task-db "$dir/tasks.db" \
    --projects-root "$dir/projects" \
    --detectors cold-restart-suspect
}

# D7a: prior jsonl ends with /exit -> finding suppressed
D7a="$ROOT/d7a"
build_cold_restart_fixture "$D7a" '{"type":"user","message":{"content":"<command-name>/exit</command-name>"}}'$'\n'
out_d7a="$(run_doctor_with_projects "$D7a")"
json_assert "$out_d7a" kind_absent \
  "D7a clean /exit suppresses cold-restart-suspect (#588)" cold-restart-suspect

# D7b: prior jsonl has no clean-exit marker -> finding still emitted
D7b="$ROOT/d7b"
build_cold_restart_fixture "$D7b" '{"type":"user","message":{"content":"plain user text"}}'$'\n'
out_d7b="$(run_doctor_with_projects "$D7b")"
json_assert "$out_d7b" cold_restart_for_agent \
  "D7b real cold restart still emits finding" patch

# --- Summary ------------------------------------------------------------
printf '\n[smoke] agb-doctor: %d pass, %d fail\n' "$PASS" "$FAIL"
if (( FAIL > 0 )); then
  printf '[smoke] failing scenarios:\n' >&2
  for failure in "${FAILURES[@]}"; do
    printf '  - %s\n' "$failure" >&2
  done
  exit 1
fi
exit 0
