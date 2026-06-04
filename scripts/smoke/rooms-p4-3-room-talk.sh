#!/usr/bin/env bash
# scripts/smoke/rooms-p4-3-room-talk.sh — A2A Rooms P4.3 room-scoped TALK
# (cross-node member messaging).
#
# Exercises the THIRD cross-node rooms phase (design docs/design/
# a2a-rooms-design.md §11): once a member node holds a leader-MAC'd roster in
# room_roster_cache (from P4.2), members on DIFFERENT nodes exchange room-scoped
# messages WITHOUT the leader online — each member validates membership against
# its OWN local cache + the envelope's room_epoch, fail-closed. The transport is
# STUBBED end-to-end (no real Tailscale / live socket): the sender's `room talk`
# enqueue POST is captured by the paired-flag test hook, then replayed through
# the REAL receiver `do_POST` handler (the enqueue boundary is monkeypatched in
# the helper to capture delivery, so no bridge-task.sh shell-out / live queue).
#
# THE 9 REQUIRED TEETH (each proven below):
#   T1  A room message from a roster MEMBER (correct room_id + matching epoch) IS
#       delivered.
#   T2  A room message from a NON-member (sender not in the local roster cache)
#       is REJECTED, no delivery.
#   T3  A room message with a MISMATCHED room_epoch (both stale AND ahead) is
#       REJECTED fail-closed.
#   T4  A room message for an UNKNOWN room_id (no local roster cache) is REJECTED
#       fail-closed.
#   T5  A room message MISSING room_id or room_epoch -> 422 (no delivery).
#   T6  A PLAIN non-room message is NOT treated as room talk (doesn't hit the
#       room gate, IS delivered as a normal message) AND does not grant
#       membership.
#   T7  A hostile --from/env cannot impersonate another member (OS-actor/node
#       anchoring holds; a wire sender_agent that is not a cached member fails).
#   T8  A replayed room message (same peer+message_id) is deduped/idempotent;
#       same-id/diff-body is NOT double-delivered (409).
#   T9  Auth-preamble parity: the room-talk delivery is unreachable pre-auth (bad
#       HMAC / remote_addr / allowlist -> 401/403 BEFORE any room logic).
#   T10 (codex review) inbox_dedupe is scoped to the authenticated peer (composite
#       PK): a second peer reusing another peer's message_id does NOT collide, so
#       room talk's replay protection (which rides this dedupe) is peer-isolated.

set -euo pipefail

SMOKE_NAME="rooms-p4-3-room-talk"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/rooms-p4-3-room-talk-helper.py"
POST_HOOK="$SCRIPT_DIR/rooms-p4-3-post-hook.sh"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

NODE_A="nodeA"   # the SENDER's node (alice talks)
NODE_B="nodeB"   # the RECEIVER / member node (bob receives)
SECRET="test-pair-secret-aaaaaaaaaaaaaaaaaaaa"
ADDR="127.0.0.1"
ROOM="room-talk-001"
EPOCH=4

# The canonical cached roster the receiver gate reads (alice@nodeA leader +
# bob@nodeB member). Same bytes seeded on BOTH nodes (mirrors a leader broadcast
# already applied on each via P4.2).
MEMBERS_CSV="alice@${NODE_A}:leader,bob@${NODE_B}:member"

# Node-A (sender) config: bridge_id=nodeA, peer nodeB (the delivery target).
CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"
python3 "$HELPER" make-config "$CFG_A" "$NODE_A" "$NODE_B" "$SECRET" "$ADDR" "bob" >/dev/null
# Sender-side rooms.db (node A) — alice's own cache, so `room talk` can resolve
# the epoch + confirm alice is a member before sending.
SENDER_DB="$SMOKE_TMP_ROOT/sender-rooms.db"
python3 "$HELPER" seed-cache "$SENDER_DB" "$ROOM" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null

# Node-B (receiver) config: bridge_id=nodeB, peer nodeA (the authenticated
# sender). The inbound allowlist permits delivery to bob (the room talk target).
CFG_B="$SMOKE_TMP_ROOT/handoff-B.json"
python3 "$HELPER" make-config "$CFG_B" "$NODE_B" "$NODE_A" "$SECRET" "$ADDR" "bob" >/dev/null
CFG_B_JSON="$(cat "$CFG_B")"

# Member-local receiver rooms.db (node B) — the leader-MAC cache the gate reads.
MEMBER_DB="$SMOKE_TMP_ROOT/member-rooms.db"
python3 "$HELPER" seed-cache "$MEMBER_DB" "$ROOM" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null

CAPTURE="$SMOKE_TMP_ROOT/captured-talk.json"

TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# talk_as <agent> <sender_db> [extra room-talk args...] — run `room talk` as
# iso-user agent-bridge-<agent> on node A, capturing the signed enqueue POST to
# $CAPTURE. Echoes the CLI JSON.
talk_as() {
  local who="$1" sdb="$2"; shift 2
  : >"$CAPTURE" || true
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
      "BRIDGE_A2A_ROOMS_DB=$sdb" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" \
    python3 "$ROOMS_CLI" talk "$ROOM" "$@" --json 2>/dev/null
}

# deliver_talk <cfg_json> [overrides_json] [member_db] — replay $CAPTURE through
# the REAL receiver do_POST handler against <member_db> (default $MEMBER_DB).
deliver_talk() {
  local cfg_json="$1" overrides="${2:-}" mdb="${3:-$MEMBER_DB}"
  [[ -n "$overrides" ]] || overrides='{}'
  env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-talk-to-receiver "$SMOKE_REPO_ROOT" \
      "$cfg_json" "$CAPTURE" "$overrides"
}

# ---------------------------------------------------------------------------
# setup + T1: a member sends; the receiver delivers (matching epoch + roster).
# ---------------------------------------------------------------------------
test_T1_member_talk_delivered() {
  local out
  out="$(talk_as alice "$SENDER_DB" --title "hello room" --body "from alice")"
  smoke_assert_contains "$out" "\"epoch\": $EPOCH" "T1: sender stamped its locally-cached epoch"
  smoke_assert_contains "$out" "\"from\": \"alice@$NODE_A\"" "T1: sender identity is OS-actor anchored (alice@nodeA)"
  smoke_assert_file_exists "$CAPTURE" "T1: the signed room-talk enqueue was captured"

  # The captured POST carries the room scope + targets bob over the enqueue path.
  local proto room_in_body epoch_in_body target_in_body path_in
  proto="$(python3 "$HELPER" captured-field "$CAPTURE" "header:X-AGB-Protocol")"
  smoke_assert_eq "a2a-enqueue-v1" "$proto" "T1: room talk routes over the normal enqueue protocol"
  path_in="$(python3 "$HELPER" captured-field "$CAPTURE" "path")"
  smoke_assert_eq "/enqueue" "$path_in" "T1: room talk posts to the enqueue path (not a new endpoint)"
  room_in_body="$(python3 "$HELPER" captured-field "$CAPTURE" "body:room_id")"
  smoke_assert_eq "$ROOM" "$room_in_body" "T1: the envelope carries the room id"
  epoch_in_body="$(python3 "$HELPER" captured-field "$CAPTURE" "body:room_epoch")"
  smoke_assert_eq "$EPOCH" "$epoch_in_body" "T1: the envelope carries the cached room epoch"
  target_in_body="$(python3 "$HELPER" captured-field "$CAPTURE" "body:target_agent")"
  smoke_assert_eq "bob" "$target_in_body" "T1: the envelope targets the other-node member bob"

  # The receiver delivers it (member sender + member target + matching epoch).
  local res
  res="$(deliver_talk "$CFG_B_JSON")"
  smoke_assert_contains "$res" "status=200" "T1: a member room message is accepted (200)"
  smoke_assert_contains "$res" "delivered=True" "T1: the room message is DELIVERED into the queue"
  smoke_assert_contains "$res" "\"task_id\": \"9999\"" "T1: delivery created a task"
}

# ---------------------------------------------------------------------------
# T2: a NON-member sender (not in the local roster cache) is rejected.
# A member db that does NOT list the sender's agent → the gate denies. We mutate
# the captured envelope's sender.agent to a non-member, re-signing so it passes
# the HMAC gate and reaches the membership gate.
# ---------------------------------------------------------------------------
# deliver_mutated <cfg_json> <mutate_op> [mutate_arg] [member_db] — replay the
# captured talk through the receiver with the envelope body mutated by the
# helper (no inline heredocs — heredoc-ban hygiene), re-signed so it passes HMAC.
deliver_mutated() {
  local cfg_json="$1" op="$2" arg="${3:-}" mdb="${4:-$MEMBER_DB}"
  local mutated quoted overrides
  mutated="$(python3 "$HELPER" mutate-body "$CAPTURE" "$op" "$arg")"
  quoted="$(python3 "$HELPER" json-quote "$mutated")"
  overrides="{\"body\":$quoted,\"resign\":true}"
  deliver_talk "$cfg_json" "$overrides" "$mdb"
}

test_T2_non_member_sender_rejected() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  # Rewrite sender.agent → "mallory" (not in the cached roster). Node stays nodeA
  # (the authenticated peer), so this is the pure "agent not a member" case.
  local res
  res="$(deliver_mutated "$CFG_B_JSON" set-sender-agent mallory)"
  smoke_assert_contains "$res" "status=403" "T2: a non-member sender is 403"
  smoke_assert_contains "$res" "sender_not_member" "T2: refusal reason is sender_not_member"
  smoke_assert_contains "$res" "delivered=False" "T2: a non-member message is NEVER delivered"
}

# ---------------------------------------------------------------------------
# T3: a MISMATCHED room_epoch (both stale AND ahead) is rejected fail-closed.
# ---------------------------------------------------------------------------
test_T3_epoch_mismatch_rejected() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  # stale: deliver against a member cache pinned at a HIGHER epoch.
  local mdb_ahead="$SMOKE_TMP_ROOT/member-epoch-ahead.db"
  python3 "$HELPER" seed-cache "$mdb_ahead" "$ROOM" $((EPOCH+1)) "$NODE_A" "$MEMBERS_CSV" >/dev/null
  local res_stale
  res_stale="$(deliver_talk "$CFG_B_JSON" '{}' "$mdb_ahead")"
  smoke_assert_contains "$res_stale" "status=403" "T3: a STALE epoch (cache ahead) is 403"
  smoke_assert_contains "$res_stale" "epoch_mismatch" "T3: stale refusal reason is epoch_mismatch"
  smoke_assert_contains "$res_stale" "delivered=False" "T3: a stale-epoch message is not delivered"
  # ahead: deliver against a member cache pinned at a LOWER epoch.
  local mdb_behind="$SMOKE_TMP_ROOT/member-epoch-behind.db"
  python3 "$HELPER" seed-cache "$mdb_behind" "$ROOM" $((EPOCH-1)) "$NODE_A" "$MEMBERS_CSV" >/dev/null
  local res_ahead
  res_ahead="$(deliver_talk "$CFG_B_JSON" '{}' "$mdb_behind")"
  smoke_assert_contains "$res_ahead" "status=403" "T3: an AHEAD epoch (cache behind) is 403"
  smoke_assert_contains "$res_ahead" "epoch_mismatch" "T3: ahead refusal reason is epoch_mismatch"
  smoke_assert_contains "$res_ahead" "delivered=False" "T3: an ahead-epoch message is not delivered"
}

# ---------------------------------------------------------------------------
# T4: an UNKNOWN room_id (no local roster cache) is rejected fail-closed.
# ---------------------------------------------------------------------------
test_T4_unknown_room_rejected() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  # A member db with a cache for a DIFFERENT room only → the talk's room has no
  # cache here → no_roster_cache fail-closed.
  local mdb_other="$SMOKE_TMP_ROOT/member-otherroom.db"
  python3 "$HELPER" seed-cache "$mdb_other" "room-different" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null
  local res
  res="$(deliver_talk "$CFG_B_JSON" '{}' "$mdb_other")"
  smoke_assert_contains "$res" "status=403" "T4: an unknown room (no cache) is 403"
  smoke_assert_contains "$res" "no_roster_cache" "T4: refusal reason is no_roster_cache"
  smoke_assert_contains "$res" "delivered=False" "T4: an unknown-room message is not delivered"
}

# ---------------------------------------------------------------------------
# T5: a room message MISSING room_id or room_epoch -> 422 (no delivery).
# parse_envelope rejects a half-room envelope at the wire boundary.
# ---------------------------------------------------------------------------
test_T5_missing_room_fields_422() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  # Drop room_epoch but keep room_id → a malformed room-scoped envelope.
  local res_no_epoch
  res_no_epoch="$(deliver_mutated "$CFG_B_JSON" drop-room-epoch)"
  smoke_assert_contains "$res_no_epoch" "status=422" "T5: room_id present without room_epoch is 422"
  smoke_assert_contains "$res_no_epoch" "delivered=False" "T5: a 422 half-room envelope is not delivered"
  # Drop room_id but keep room_epoch → also malformed.
  local res_no_id
  res_no_id="$(deliver_mutated "$CFG_B_JSON" drop-room-id)"
  smoke_assert_contains "$res_no_id" "status=422" "T5: room_epoch present without room_id is 422"
  smoke_assert_contains "$res_no_id" "delivered=False" "T5: a 422 half-room envelope is not delivered"
}

# ---------------------------------------------------------------------------
# T6: a PLAIN non-room message is NOT treated as room talk — it IS delivered via
# the normal path and does NOT touch the room gate or grant membership.
# ---------------------------------------------------------------------------
test_T6_plain_send_not_room_talk() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  # Strip BOTH room fields → a plain v1 envelope. It must deliver (allowlist has
  # bob) WITHOUT the room gate (no room_id), and must not depend on/seed any
  # cache. Deliver against a member db that has NO cache for the talk's room to
  # prove the plain path is independent of room state.
  local mdb_empty="$SMOKE_TMP_ROOT/member-nocache.db"
  python3 "$HELPER" seed-cache "$mdb_empty" "room-unrelated" 1 "$NODE_A" "alice@$NODE_A" >/dev/null
  local res
  res="$(deliver_mutated "$CFG_B_JSON" drop-both "" "$mdb_empty")"
  smoke_assert_contains "$res" "status=200" "T6: a plain non-room message is accepted via the normal path"
  smoke_assert_contains "$res" "delivered=True" "T6: a plain message IS delivered (not gated by room membership)"
  smoke_assert_not_contains "$res" "room-scoped enqueue denied" "T6: a plain message never hits the room gate"
}

# ---------------------------------------------------------------------------
# T7: a hostile --from/env cannot impersonate another member. The recorded
# sender is the OS-actor (BRIDGE_ROOMS_TEST_ISO_USER), so --as/--from is ignored;
# and a wire sender_agent that is not a cached member fails the gate (T2 proves
# the latter). Here we prove the SENDER side: `room talk --as <other-member>`
# from carl's iso uid still sends as carl (OS-anchored), and since carl is not a
# member, the CLI refuses to send at all.
# ---------------------------------------------------------------------------
test_T7_hostile_from_cannot_impersonate() {
  # carl is NOT in the room. Even passing --as alice (a real member) the OS actor
  # resolves to carl → the CLI refuses (carl not a cached member). A hostile
  # --as/--from cannot make carl's send go out as alice.
  local out rc
  set +e
  out="$(env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-carl" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
      "BRIDGE_A2A_ROOMS_DB=$SENDER_DB" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" \
    python3 "$ROOMS_CLI" talk "$ROOM" --as alice --title hi --body x --json 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || smoke_fail "T7: carl (non-member) impersonating alice must FAIL to send"
  smoke_assert_contains "$out" "is not a member" "T7: the OS actor carl is not a member; --as alice is ignored (no impersonation)"
}

# ---------------------------------------------------------------------------
# T8: a replayed room message (same peer+message_id) is deduped/idempotent;
# same-id/diff-body is NOT double-delivered (409).
# ---------------------------------------------------------------------------
test_T8_replay_dedupe() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  local mdb="$SMOKE_TMP_ROOT/member-dedupe.db"
  python3 "$HELPER" seed-cache "$mdb" "$ROOM" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null
  # first delivery → 200 delivered.
  local first
  first="$(deliver_talk "$CFG_B_JSON" '{}' "$mdb")"
  smoke_assert_contains "$first" "status=200" "T8: first room message is delivered (200)"
  smoke_assert_contains "$first" "delivered=True" "T8: first delivery enqueues a task"
  # byte-identical replay (same id + same body) → idempotent 200, NOT re-delivered.
  local replay
  replay="$(deliver_talk "$CFG_B_JSON" '{}' "$mdb")"
  smoke_assert_contains "$replay" "status=200" "T8: a byte-identical replay is an idempotent 200"
  smoke_assert_contains "$replay" "\"duplicate\": true" "T8: the replay is flagged duplicate"
  smoke_assert_contains "$replay" "delivered=False" "T8: a replay does NOT enqueue a second task"
  # same id + DIFFERENT body → 409 conflict, not delivered.
  local conflict
  conflict="$(deliver_mutated "$CFG_B_JSON" set-body "a different body for the same message id" "$mdb")"
  smoke_assert_contains "$conflict" "status=409" "T8: same-id/different-body is a 409 conflict"
  smoke_assert_contains "$conflict" "delivered=False" "T8: a conflicting replay is not double-delivered"
}

# ---------------------------------------------------------------------------
# T9: auth-preamble parity — the room-talk delivery is unreachable pre-auth.
# Bad HMAC / remote_addr / allowlist all reject BEFORE any room logic runs.
# ---------------------------------------------------------------------------
test_T9_auth_preamble_unweakened() {
  talk_as alice "$SENDER_DB" --title "t" --body "b" >/dev/null
  # bad HMAC → 401 (auth gate), room gate never reached.
  local res_hmac
  res_hmac="$(deliver_talk "$CFG_B_JSON" '{"headers":{"X-AGB-Signature":"v1=deadbeefdeadbeef"}}')"
  smoke_assert_contains "$res_hmac" "status=401" "T9: a bad pairwise HMAC is 401 (auth gate intact)"
  smoke_assert_contains "$res_hmac" "delivered=False" "T9: an HMAC-rejected room message is never delivered"
  # remote_addr mismatch → 403 before the body/room logic.
  local res_addr
  res_addr="$(deliver_talk "$CFG_B_JSON" '{"client_ip":"10.9.9.9"}')"
  smoke_assert_contains "$res_addr" "status=403" "T9: a source-address mismatch is 403"
  smoke_assert_contains "$res_addr" "delivered=False" "T9: an addr-rejected room message is never delivered"
  # unknown peer → 403.
  local res_peer
  res_peer="$(deliver_talk "$CFG_B_JSON" '{"headers":{"X-AGB-Peer":"nodeZ"}}')"
  smoke_assert_contains "$res_peer" "status=403" "T9: an unknown peer is 403"
  smoke_assert_contains "$res_peer" "delivered=False" "T9: an unknown-peer room message is never delivered"
  # allowlist miss → a room message targeting an agent NOT in the inbound
  # allowlist is 403 (the existing allowlist gate runs BEFORE the room gate).
  local cfg_noallow res_allow
  cfg_noallow="$SMOKE_TMP_ROOT/handoff-B-noallow.json"
  python3 "$HELPER" make-config "$cfg_noallow" "$NODE_B" "$NODE_A" "$SECRET" "$ADDR" "" >/dev/null
  res_allow="$(deliver_talk "$(cat "$cfg_noallow")")"
  smoke_assert_contains "$res_allow" "status=403" "T9: a target not in the inbound allowlist is 403"
  smoke_assert_contains "$res_allow" "delivered=False" "T9: an allowlist-rejected room message is never delivered"
}

# ---------------------------------------------------------------------------
# unit: the membership gate decision surface (deterministic, no HTTP).
# ---------------------------------------------------------------------------
test_membership_gate_unit() {
  local udb="$SMOKE_TMP_ROOT/membership-unit.db"
  local out
  out="$(python3 "$HELPER" membership-unit "$udb" 2>&1)" \
    || smoke_fail "membership-unit helper must not raise: $out"
  smoke_assert_contains "$out" "member_ok=members_ok" "unit: a member sender+target at the matching epoch passes"
  smoke_assert_contains "$out" "nonmember_sender=sender_not_member" "unit: a non-member sender is rejected"
  smoke_assert_contains "$out" "member_wrong_node=sender_not_member" "unit: a member on the wrong (unauth) node is rejected"
  smoke_assert_contains "$out" "target_not_member=target_not_member" "unit: a non-member target is rejected"
  smoke_assert_contains "$out" "epoch_stale=epoch_mismatch" "unit: a stale epoch is rejected fail-closed"
  smoke_assert_contains "$out" "epoch_ahead=epoch_mismatch" "unit: an ahead epoch is rejected fail-closed"
  smoke_assert_contains "$out" "no_cache=no_roster_cache" "unit: an unknown room (no cache) is rejected fail-closed"
}

# ---------------------------------------------------------------------------
# T10 (codex review): the inbox_dedupe ledger is scoped to the AUTHENTICATED
# peer (composite PK). A second peer reusing another peer's sender-chosen
# message_id does NOT collide — room talk rides this dedupe, so contract 6's
# peer-scoped replay protection holds for room messages too.
# ---------------------------------------------------------------------------
test_T10_cross_peer_dedupe_isolation() {
  local idb="$SMOKE_TMP_ROOT/inbox-isolation.db"
  local out
  out="$(python3 "$HELPER" dedupe-isolation-unit "$idb" 2>&1)" \
    || smoke_fail "dedupe-isolation-unit helper must not raise: $out"
  smoke_assert_contains "$out" "peerC_insert_ok=True" \
    "T10: a second peer reusing another peer's message_id is a FRESH row (no PK collision)"
  smoke_assert_contains "$out" "peerC_sees=hC" \
    "T10: the second peer's dedupe lookup sees ITS OWN body, not the first peer's"
  smoke_assert_contains "$out" "peerA_sees=hA" \
    "T10: the first peer's row is untouched by the second peer's reuse"
}

# ---------------------------------------------------------------------------
# T11 (codex r2): open_inbox FAILS CLOSED if the legacy->composite-PK migration
# did not take — it must NOT hand back a global-PK ledger on which a cross-peer
# same-id message could pass the peer-scoped lookup yet collide at enqueue.
# ---------------------------------------------------------------------------
test_T11_migration_fail_closed() {
  local idb="$SMOKE_TMP_ROOT/inbox-failclosed.db"
  local out
  out="$(python3 "$HELPER" migration-failclosed-unit "$idb" 2>&1)" \
    || smoke_fail "migration-failclosed-unit helper must not raise itself: $out"
  smoke_assert_contains "$out" "failclosed=yes:inbox_dedupe_legacy_pk" \
    "T11: a failed inbox migration makes open_inbox fail closed (no global-PK dedupe served)"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "T1: a member room message (matching epoch) IS delivered" test_T1_member_talk_delivered
smoke_run "T2: a NON-member sender room message is REJECTED, no delivery" test_T2_non_member_sender_rejected
smoke_run "T3: a MISMATCHED room_epoch (stale AND ahead) is REJECTED fail-closed" test_T3_epoch_mismatch_rejected
smoke_run "T4: an UNKNOWN room_id (no local cache) is REJECTED fail-closed" test_T4_unknown_room_rejected
smoke_run "T5: a room message MISSING room_id or room_epoch -> 422" test_T5_missing_room_fields_422
smoke_run "T6: a PLAIN non-room message is NOT room talk (delivered, no gate, no membership)" test_T6_plain_send_not_room_talk
smoke_run "T7: a hostile --from/env cannot impersonate another member" test_T7_hostile_from_cannot_impersonate
smoke_run "T8: a replayed room message is deduped/idempotent; same-id/diff-body 409" test_T8_replay_dedupe
smoke_run "T9: auth-preamble parity — room talk is unreachable pre-auth" test_T9_auth_preamble_unweakened
smoke_run "T10: inbox dedupe is peer-scoped — cross-peer message_id reuse does not collide" test_T10_cross_peer_dedupe_isolation
smoke_run "T11: open_inbox fails closed if the dedupe-PK migration did not take" test_T11_migration_fail_closed
smoke_run "unit: the roster-cache membership gate decision surface" test_membership_gate_unit

smoke_log "passed"
