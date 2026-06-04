#!/usr/bin/env bash
# scripts/smoke/rooms-p4-5-polish.sh — A2A Rooms P4.5 polish (two follow-ups
# from the P4.4 two-VM acceptance, design docs/design/a2a-rooms-design.md §11).
#
# FIX 1 (UX completeness): on a NON-leader node that has JOINED + been approved
#   into a room, `agb room show <id>` / `room list` must surface the room from
#   the member-side `room_roster_cache` (the same cache `room talk` reads),
#   instead of "room not found" / omitting it. A leader-led room must still show
#   exactly as before (additive role/source fields only). A room with NEITHER a
#   local `rooms` row NOR a cache row is still "not found".
#
# FIX 2 (info-hygiene, peer-facing): a cross-node enqueue to a target that
#   passes the inbound allowlist but is NOT in the local roster fails at the
#   `bridge-task.sh create` boundary, which prints the FULL `agb list` roster
#   dump (agent names/engines/workdirs/sources) on stderr. The receiver MUST
#   return a TERSE 422 detail ("unknown target '<agent>'") to the remote peer —
#   the roster dump goes to the LOCAL audit/log ONLY, never the HTTP response.
#   The rejection status + the local audit detail are unchanged.
#
# TEETH (each proven below):
#   F1a  member-side `room show <id>` surfaces cached members/epoch/leader
#        (not "not found").
#   F1b  member-side `room list` includes the joined-but-not-led room, marked
#        role=member.
#   F1c  a leader-led room still shows/lists as before (no regression).
#   F1d  a room with no `rooms` row AND no cache row -> still "not found".
#   F2a  an unknown-but-allowlisted enqueue target -> 422 (still rejected).
#   F2b  the 422 HTTP body does NOT contain the `agb list` workdir/engine/source
#        columns (the roster dump is absent from the peer-facing response).
#   F2c  the 422 HTTP body carries the terse "unknown target '<agent>'" detail.
#   F2d  the LOCAL audit/log still records the full reason (roster dump present
#        in the local enqueue_permanent_fail audit line).
#   F2e  a VALID (rostered + allowlisted) target still enqueues normally (200).

set -euo pipefail

SMOKE_NAME="rooms-p4-5-polish"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"
ROOMS_COMMON="$SMOKE_REPO_ROOT/bridge_rooms_common.py"
XBRIDGE_HELPER="$SCRIPT_DIR/a2a-cross-bridge-helper.py"

HANDOFFD_PID=""

cleanup() {
  if [[ -n "$HANDOFFD_PID" ]]; then
    kill "$HANDOFFD_PID" >/dev/null 2>&1 || true
    wait "$HANDOFFD_PID" >/dev/null 2>&1 || true
  fi
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# ===========================================================================
# FIX 1 — member-node room show/list reads room_roster_cache
# ===========================================================================
MEMBER_DB="$SMOKE_TMP_ROOT/member-rooms.db"
JOINED_ROOM="room-joined-001"
JOINED_EPOCH=7

# Seed a member-side roster cache row (the applied leader-MAC roster from P4.2)
# directly, with NO matching `rooms` row — exactly the non-leader node state.
seed_member_cache() {
  env "BRIDGE_A2A_ROOMS_DB=$MEMBER_DB" python3 "$SCRIPT_DIR/rooms-p4-5-helper.py" \
    seed-cache "$MEMBER_DB" "$JOINED_ROOM" "$JOINED_EPOCH" "nodeLeader" \
    "alice@nodeLeader:leader,bob@nodeMember:member"
}

room_cli_member() {
  env "BRIDGE_A2A_ROOMS_DB=$MEMBER_DB" python3 "$ROOMS_CLI" "$@"
}

test_F1a_member_show_from_cache() {
  local out
  out="$(room_cli_member show "$JOINED_ROOM" --json)"
  smoke_assert_contains "$out" "\"room_id\": \"$JOINED_ROOM\"" \
    "F1a: member-side show returns the joined room (not 'not found')"
  smoke_assert_contains "$out" "\"epoch\": $JOINED_EPOCH" \
    "F1a: the cached epoch is surfaced"
  smoke_assert_contains "$out" "\"leader\": \"alice@nodeLeader\"" \
    "F1a: the cached leader is surfaced"
  smoke_assert_contains "$out" "\"source\": \"roster-cache\"" \
    "F1a: the view is marked as a member-side cached view"
  smoke_assert_contains "$out" "\"role\": \"member\"" \
    "F1a: the view is marked role=member"
  smoke_assert_contains "$out" "\"agent\": \"bob\"" \
    "F1a: the cached members list is surfaced"
}

test_F1b_member_list_includes_joined() {
  local out
  out="$(room_cli_member list --json)"
  smoke_assert_contains "$out" "\"room_id\": \"$JOINED_ROOM\"" \
    "F1b: member-side list includes the joined-but-not-led room"
  smoke_assert_contains "$out" "\"source\": \"roster-cache\"" \
    "F1b: the joined room is marked as a cached/member entry"
  # Human-readable form marks it as a cached member room.
  local hout
  hout="$(room_cli_member list)"
  smoke_assert_contains "$hout" "role=member (cached)" \
    "F1b: the human list marks the joined room role=member (cached)"
}

# F1c/F1d run against a SEPARATE leader db (a node that LEADS a room).
LEADER_DB="$SMOKE_TMP_ROOT/leader-rooms.db"
LED_ROOM=""

room_cli_leader() {
  env "BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-carol" \
      "BRIDGE_A2A_ROOMS_DB=$LEADER_DB" \
    python3 "$ROOMS_CLI" "$@"
}

test_F1c_leader_room_unchanged() {
  local created
  created="$(room_cli_leader create --name "led-room" --json)"
  LED_ROOM="$(printf '%s\n' "$created" | sed -n 's/.*"room_id": "\([^"]*\)".*/\1/p' | head -n 1)"
  smoke_assert_match "$LED_ROOM" '^room-' "F1c: a led room was created"

  local sout
  sout="$(room_cli_leader show "$LED_ROOM" --json)"
  # The full leader payload is preserved (name/status/pending + role=leader).
  smoke_assert_contains "$sout" "\"name\": \"led-room\"" \
    "F1c: a led room still shows its name (leader-only field preserved)"
  smoke_assert_contains "$sout" "\"status\":" \
    "F1c: a led room still shows its status"
  smoke_assert_contains "$sout" "\"pending_join_requests\":" \
    "F1c: a led room still shows its pending-join queue"
  smoke_assert_contains "$sout" "\"source\": \"rooms\"" \
    "F1c: a led room is sourced from the local rooms table, not the cache"
  smoke_assert_contains "$sout" "\"role\": \"leader\"" \
    "F1c: a led room is marked role=leader"

  local lout
  lout="$(room_cli_leader list)"
  smoke_assert_contains "$lout" "$LED_ROOM" \
    "F1c: a led room still appears in list"
  smoke_assert_contains "$lout" "name='led-room'" \
    "F1c: the led-room list row is unchanged (name + status columns)"
}

test_F1d_no_room_no_cache_not_found() {
  local out rc
  set +e
  out="$(room_cli_leader show "room-does-not-exist" --json 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || smoke_fail "F1d: an unknown room (no rooms row, no cache) must exit non-zero"
  smoke_assert_contains "$out" "room not found" \
    "F1d: an unknown room with neither a rooms row nor a cache row is still 'not found'"
}

# ===========================================================================
# FIX 2 — peer-facing enqueue 422 detail is terse (no roster leak)
# ===========================================================================
A2A_PORT=""
A2A_SECRET="smoke-shared-secret-do-not-use-in-prod-0123456789"
UNKNOWN_TARGET="ghost-agent"
VALID_TARGET="reviewer"
REVIEWER_SESSION_NAME="a2a-p45-$$-${RANDOM}"

helper() { python3 "$XBRIDGE_HELPER" "$@"; }
base_url() { printf 'http://127.0.0.1:%s' "$A2A_PORT"; }

# A roster that has 'reviewer' (a real, rostered agent) but NOT 'ghost-agent'.
# The roster intentionally carries the leaky columns (engine/workdir/source) so
# a roster dump would be obvious if it leaked.
write_a2a_roster() {
  local workdir="$BRIDGE_AGENT_HOME_ROOT/reviewer"
  mkdir -p "$workdir"
  cat >"$BRIDGE_ROSTER_LOCAL_FILE" <<EOF
BRIDGE_ADMIN_AGENT_ID="reviewer"
bridge_add_agent_id_if_missing "reviewer"
BRIDGE_AGENT_DESC["reviewer"]="A2A P4.5 polish smoke reviewer"
BRIDGE_AGENT_ENGINE["reviewer"]="shell"
BRIDGE_AGENT_SESSION["reviewer"]="$REVIEWER_SESSION_NAME"
BRIDGE_AGENT_WORKDIR["reviewer"]="$workdir"
BRIDGE_AGENT_LAUNCH_CMD["reviewer"]="bash -lc 'echo reviewer'"
BRIDGE_AGENT_LOOP["reviewer"]=0
BRIDGE_AGENT_CONTINUE["reviewer"]=0
EOF
}

# Both the unknown AND the valid target are in the inbound allowlist so the
# allowlist preamble admits each — the unknown one then fails at bridge-task.sh
# (the roster gate), the valid one enqueues.
write_a2a_config() {
  local port="$1"
  cat >"$BRIDGE_HOME/handoff.local.json" <<EOF
{
  "bridge_id": "bridge-b",
  "listen": { "address": "127.0.0.1", "port": ${port}, "enqueue_path": "/enqueue" },
  "timestamp_skew_seconds": 300,
  "peers": [
    {
      "id": "bridge-a",
      "address": "127.0.0.1",
      "port": ${port},
      "secret": "${A2A_SECRET}",
      "inbound_allowlist": ["${VALID_TARGET}", "${UNKNOWN_TARGET}"],
      "caps": { "max_body_bytes": 262144, "max_title_bytes": 1024 }
    }
  ]
}
EOF
  chmod 0600 "$BRIDGE_HOME/handoff.local.json"
}

start_receiver() {
  A2A_PORT="$(helper free-port)"
  write_a2a_config "$A2A_PORT"
  BRIDGE_A2A_ALLOW_TEST_BIND=1 \
    python3 "$SMOKE_REPO_ROOT/bridge-handoffd.py" serve \
      --config "$BRIDGE_HOME/handoff.local.json" \
      >"$SMOKE_TMP_ROOT/handoffd.log" 2>&1 &
  HANDOFFD_PID=$!
  local waited=0
  while (( waited < 50 )); do
    if helper wait-port "$A2A_PORT" 2>/dev/null; then
      return 0
    fi
    sleep 0.1
    waited=$((waited + 1))
  done
  smoke_fail "receiver did not start; log: $(cat "$SMOKE_TMP_ROOT/handoffd.log")"
}

test_F2_unknown_target_terse_no_leak() {
  local out
  out="$(helper unknown-target "$(base_url)" bridge-a "$A2A_SECRET" "$UNKNOWN_TARGET")"
  # F2a: still rejected with 422 (the rejection itself is unchanged).
  smoke_assert_contains "$out" "STATUS=422" \
    "F2a: an unknown-but-allowlisted target is still rejected (422)"
  # F2b: the peer-facing body must NOT contain the agb-list roster columns.
  smoke_assert_not_contains "$out" "engine=" \
    "F2b: the 422 body does NOT leak the roster 'engine=' column"
  smoke_assert_not_contains "$out" "workdir=" \
    "F2b: the 422 body does NOT leak the roster 'workdir=' column"
  smoke_assert_not_contains "$out" "source=" \
    "F2b: the 422 body does NOT leak the roster 'source=' column"
  smoke_assert_not_contains "$out" "$BRIDGE_AGENT_HOME_ROOT" \
    "F2b: the 422 body does NOT leak agent workdir paths"
  # F2c: the terse detail names only the target the peer already chose.
  smoke_assert_contains "$out" "unknown target '$UNKNOWN_TARGET'" \
    "F2c: the 422 body carries the terse 'unknown target' detail"
}

test_F2d_local_audit_has_full_reason() {
  # The local audit log must still record the full reason (the roster dump) —
  # redaction is peer-facing ONLY. The audit truncates to 200 chars (pre-existing
  # behavior), so the roster dump's leading column marker is present locally.
  local audit_log="$BRIDGE_HOME/logs/a2a-handoff.jsonl"
  smoke_assert_file_exists "$audit_log" \
    "F2d: the local a2a audit log exists"
  local perm_lines
  perm_lines="$(grep "enqueue_permanent_fail" "$audit_log" || true)"
  smoke_assert_contains "$perm_lines" "enqueue_permanent_fail" \
    "F2d: the rejection is recorded as a permanent-fail audit event locally"
  # The roster-dump fingerprint (engine= ... column) must be present LOCALLY in
  # the audit detail even though it is redacted from the peer response.
  smoke_assert_contains "$perm_lines" "engine=" \
    "F2d: the local audit detail still records the full reason (roster dump kept locally)"
}

test_F2e_valid_target_still_enqueues() {
  local out task_id inbox_out
  out="$(helper ok "$(base_url)" bridge-a "$A2A_SECRET")"
  smoke_assert_contains "$out" "STATUS=200" \
    "F2e: a valid, rostered + allowlisted target still enqueues normally (200)"
  task_id="$(printf '%s\n' "$out" | sed -n 's/.*"task_id"[^0-9]*\([0-9][0-9]*\).*/\1/p' | head -n 1)"
  smoke_assert_match "$task_id" '^[0-9]+$' \
    "F2e: the valid enqueue returned a local task id"
  inbox_out="$("$SMOKE_REPO_ROOT/agent-bridge" inbox "$VALID_TARGET")"
  smoke_assert_contains "$inbox_out" "a2a smoke ok" \
    "F2e: the valid handoff is visible in the target's inbox"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "FIX1 setup: seed a member-side roster cache (joined, not led)" seed_member_cache
smoke_run "F1a: member-side room show surfaces the joined room from the cache" test_F1a_member_show_from_cache
smoke_run "F1b: member-side room list includes the joined-but-not-led room" test_F1b_member_list_includes_joined
smoke_run "F1c: a leader-led room still shows/lists as before (no regression)" test_F1c_leader_room_unchanged
smoke_run "F1d: a room with no rooms row and no cache row is still 'not found'" test_F1d_no_room_no_cache_not_found

smoke_run "FIX2 setup: write roster (reviewer rostered, ghost-agent not)" write_a2a_roster
smoke_run "FIX2 setup: start loopback receiver (test-bind)" start_receiver
smoke_run "F2a-c: unknown target -> terse 422, no roster leak in the peer body" test_F2_unknown_target_terse_no_leak
smoke_run "F2d: the local audit still records the full reason" test_F2d_local_audit_has_full_reason
smoke_run "F2e: a valid target still enqueues normally" test_F2e_valid_target_still_enqueues

smoke_log "passed"
