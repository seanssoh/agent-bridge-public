#!/usr/bin/env bash
# scripts/smoke/v0165-l5-relay-roster.sh — v0.16.5 mesh Lane 5 (#1695-P2).
# SECURITY: leader-relay (member->leader->member) + roster anti-entropy / durable
# membership-change broadcast. Drives the REAL receiver (do_POST), the REAL relay
# decision (maybe_relay_room_message / _relay_resolve / _relay_forward_send), the
# durable roster outbox + shared membership-change broadcast, and the reconcile
# heartbeat adapter — WITHOUT a live socket / Tailscale. The relay/roster POSTs
# are captured by paired-flag test hooks and replayed through the real receiver.
#
# THE 7 REQUIRED ADVERSARIAL CASES (each proven below):
#   A1  relay sig-replacement — the target verifies the LEADER's HMAC on a
#       relayed leg, NOT the original sender's; a relayed leg carrying the
#       original sender's peer/signature is rejected at the target.
#   A2  relay allowlist — the leader refuses to relay to a NON-member target
#       (room-derived, fail-closed).
#   A3  relay auth — the leader refuses to relay a message whose sender is NOT an
#       approved room member (the member->leader HMAC is verified by the receiver
#       preamble BEFORE the relay decision; a non-member sender is refused).
#   A4  no relay loop / amplification — a relayed message is NOT re-relayed.
#   A5  roster epoch monotonic — a stale/lower-epoch outbox target is never
#       lowered; membership comes from rooms.db, not the body.
#   A6  kick/leave/deny broadcast — a membership change durably queues + delivers
#       the new roster; the reconcile heartbeat re-broadcasts an un-acked row.
#   A7  no secret leak in relay/roster payloads.

set -euo pipefail

SMOKE_NAME="v0165-l5-relay-roster"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/v0165-l5-relay-roster-helper.py"
RELAY_HOOK="$SCRIPT_DIR/v0165-l5-relay-post-hook.sh"
ROSTER_HOOK="$SCRIPT_DIR/v0165-l5-roster-post-hook.sh"

cleanup() { smoke_cleanup_temp_root; }
trap cleanup EXIT

smoke_require_cmd python3
smoke_setup_bridge_home "$SMOKE_NAME"

# #1728: throwaway per-node / per-case rooms+outbox+reconcile DBs that are opened
# with the test-bind flag (TEST_FLAGS) must live UNDER the active BRIDGE_HOME —
# the state-path guard fails closed on ANY db path resolved outside BRIDGE_HOME
# while BRIDGE_A2A_ALLOW_TEST_BIND=1. These simulate distinct nodes but share
# this isolated test process, so a dir under BRIDGE_HOME keeps the guard a no-op
# (and is correct: a test mesh's state never reaches a live tree).
TEST_DB_DIR="$BRIDGE_HOME/test-dbs"
mkdir -p "$TEST_DB_DIR"

SECRET="test-pair-secret-aaaaaaaaaaaaaaaaaaaa"
ADDR="127.0.0.1"
ROOM="room-l5"

# Paired insecure-test flags (prod-inert). Set INLINE per invocation, never
# exported, so nothing leaks into other processes.
TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# Leader nodeA config: peers = the two member nodes (nodeB sender, nodeC target);
# allowlist = the leader's OWN local agents only (lead, alice). A remote member
# agent (carol@nodeC) is intentionally NOT allowlisted — the relay path is the
# only way it is reached, proving the room-derived (not static-allowlist) gate.
CFG_LEADER="$SMOKE_TMP_ROOT/cfg-leader.json"
python3 "$HELPER" make-config "$CFG_LEADER" nodeA "nodeB,nodeC" "$SECRET" "$ADDR" "lead,alice" >/dev/null

# Leader rooms.db: room led by lead@nodeA; members alice@nodeB (a remote member
# that sends) + carol@nodeC (a remote member that receives). Membership is the
# authoritative rooms.db the relay reads (NEVER a body claim).
LEADER_DB="$TEST_DB_DIR/rooms-leader.db"
python3 "$HELPER" make-leader-db "$LEADER_DB" "$ROOM" lead nodeA \
  "lead@nodeA:leader,alice@nodeB,carol@nodeC" >/dev/null

# Target nodeC config: peer = the LEADER nodeA; allowlist = carol (its own local
# member). The relay leg authenticates as the leader, so this is what it needs.
CFG_TARGET="$SMOKE_TMP_ROOT/cfg-target.json"
python3 "$HELPER" make-config "$CFG_TARGET" nodeC "nodeA" "$SECRET" "$ADDR" "carol" >/dev/null
TARGET_DB="$TEST_DB_DIR/rooms-target.db"
python3 "$HELPER" make-leader-db "$TARGET_DB" "$ROOM" lead nodeA \
  "lead@nodeA:leader,alice@nodeB,carol@nodeC" >/dev/null

INBOUND="$SMOKE_TMP_ROOT/inbound.json"      # member->leader enqueue
RELAY_LEG="$SMOKE_TMP_ROOT/relay-leg.json"  # captured leader->target relay leg

# deliver_to_leader <inbound_json> [overrides] — drive the LEADER's do_POST with
# the relay hook capturing the forwarded leg to $RELAY_LEG. Echoes the result.
deliver_to_leader() {
  local inbound="$1" overrides="${2:-{\}}"
  : >"$RELAY_LEG" || true
  env "${TEST_FLAGS[@]}" "BRIDGE_A2A_ROOMS_DB=$LEADER_DB" \
      "BRIDGE_ROOMS_TEST_RELAY_HOOK=$RELAY_HOOK" "CAPTURE_FILE=$RELAY_LEG" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$CFG_LEADER")" "$inbound" "$overrides"
}

# deliver_to_target <captured> [overrides] — replay a leg through nodeC's do_POST.
deliver_to_target() {
  local captured="$1" overrides="${2:-{\}}"
  env "BRIDGE_A2A_ROOMS_DB=$TARGET_DB" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$CFG_TARGET")" "$captured" "$overrides"
}

# ---------------------------------------------------------------------------
# setup: alice@nodeB sends a room message to carol -> the LEADER relays it.
# ---------------------------------------------------------------------------
test_setup_member_to_leader_relay() {
  python3 "$HELPER" build-member-enqueue "$INBOUND" nodeB alice carol "$ROOM" 1 >/dev/null
  local res
  res="$(deliver_to_leader "$INBOUND" '{"resign":true}')"
  smoke_assert_contains "$res" "status=202" "the leader RELAYS a member->member room message (202)"
  smoke_assert_contains "$res" "relayed=True" "the response marks it relayed"
  smoke_assert_contains "$res" "delivered=False" "the leader does NOT deliver it locally"
  smoke_assert_file_exists "$RELAY_LEG" "the re-signed leader->target relay leg was captured"
  # The relay leg is authenticated as the LEADER (re-signed with the leader pair
  # key), NOT the original sender.
  local peer
  peer="$(python3 "$HELPER" captured-field "$RELAY_LEG" header:X-AGB-Peer)"
  smoke_assert_eq "nodeA" "$peer" "the relay leg's authenticated peer is the LEADER (re-signed)"
  local relayed_via
  relayed_via="$(python3 "$HELPER" captured-field "$RELAY_LEG" body:relayed_via)"
  smoke_assert_eq "nodeA" "$relayed_via" "the relay leg carries the relayed_via loop-guard marker"
}

# ---------------------------------------------------------------------------
# positive: the captured relay leg delivers at the TARGET, validating the
# ORIGINAL author (alice@nodeB) against the target's cached roster.
# ---------------------------------------------------------------------------
test_relay_leg_delivers_at_target() {
  local res
  res="$(deliver_to_target "$RELAY_LEG")"
  smoke_assert_contains "$res" "status=200" "the target accepts the leader-signed relay leg (200)"
  smoke_assert_contains "$res" "delivered=True" "the target delivers it to the local member carol"
  # PROVENANCE (codex P1): the delivered task is attributed to the ORIGINAL AUTHOR
  # (alice@nodeB), NOT the relaying leader — otherwise a relayed task would appear
  # as a2a:<leader>:<author>, a leader-identity spoof when agent names overlap.
  smoke_assert_contains "$res" "\"sender_bridge\": \"nodeB\"" "the delivered task's provenance bridge is the ORIGINAL author node (nodeB), not the leader (nodeA)"
  smoke_assert_contains "$res" "\"sender_agent\": \"alice\"" "the delivered task names the ORIGINAL author agent"
  smoke_assert_contains "$res" "\"target\": \"carol\"" "the delivered task targets the local member carol"
}

# ---------------------------------------------------------------------------
# positive-body (codex Phase-4): the delivered task BODY provenance block must
# AGREE with the queue attribution — it must show the ORIGINAL author's REAL node
# (alice@nodeB), name the relay leader on a SEPARATE `relayed via` line, and the
# Reply-with hint must target the original author's node. It must NEVER present
# the original agent paired with the LEADER node (alice@nodeA).
# ---------------------------------------------------------------------------
test_relay_body_provenance_agrees() {
  # Build a FRESH relay end-to-end (a new inbound -> a new relay leg) so the
  # target delivery is a genuine first delivery (not a dedupe duplicate of the
  # positive test's leg, which would short-circuit before the body is staged).
  local inb="$SMOKE_TMP_ROOT/inbound-body.json"
  local leg="$SMOKE_TMP_ROOT/relay-body.json"
  python3 "$HELPER" build-member-enqueue "$inb" nodeB alice carol "$ROOM" 1 >/dev/null
  env "${TEST_FLAGS[@]}" "BRIDGE_A2A_ROOMS_DB=$LEADER_DB" \
      "BRIDGE_ROOMS_TEST_RELAY_HOOK=$RELAY_HOOK" "CAPTURE_FILE=$leg" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$CFG_LEADER")" "$inb" '{"resign":true}' >/dev/null
  local body="$SMOKE_TMP_ROOT/delivered-body.txt"
  env "BRIDGE_A2A_ROOMS_DB=$TARGET_DB" "DELIVERED_BODY_FILE=$body" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$CFG_TARGET")" "$leg" >/dev/null
  smoke_assert_file_exists "$body" "the delivered task body was captured"
  local body_text
  body_text="$(cat "$body")"
  # The TRUE origin: alice on nodeB, rendered together.
  smoke_assert_contains "$body_text" "remote peer  : nodeB" "body provenance names the ORIGINAL author node (nodeB)"
  smoke_assert_contains "$body_text" "remote agent : alice" "body provenance names the ORIGINAL author agent (alice)"
  # The relay hop is named SEPARATELY (not conflated with the origin).
  smoke_assert_contains "$body_text" "relayed via  : nodeA (room leader)" "body provenance names the relay leader on its OWN line"
  # The Reply-with hint targets the ORIGINAL author's node, not the leader.
  smoke_assert_contains "$body_text" "--peer nodeB --to alice" "the Reply-with hint targets the ORIGINAL author (nodeB), not the leader"
  # THE decisive negatives (the leader-identity ambiguity Lane 5 closes): the body
  # must NEVER pair the original agent with the leader node — not as the `remote
  # peer` origin line, and not in the Reply-with hint.
  smoke_assert_not_contains "$body_text" "remote peer  : nodeA" "the body's ORIGIN peer is never the leader node (nodeA)"
  smoke_assert_not_contains "$body_text" "--peer nodeA --to alice" "the body NEVER pairs the original agent with the leader node in the reply hint"
}

# ---------------------------------------------------------------------------
# A5b: the leader refuses to relay a STALE-epoch message (codex P2). The inbound
# room_epoch must equal the leader's AUTHORITATIVE epoch (rooms.db) — a stale
# (lower) epoch is a 409 and NOT forwarded (never relay against a superseded
# roster). make-leader-db seeds epoch 1; a message claiming epoch 0 is stale.
# ---------------------------------------------------------------------------
test_A5b_relay_stale_epoch_refused() {
  local inb="$SMOKE_TMP_ROOT/inbound-stale.json"
  python3 "$HELPER" build-member-enqueue "$inb" nodeB alice carol "$ROOM" 0 >/dev/null
  : >"$RELAY_LEG" || true
  local res
  res="$(deliver_to_leader "$inb" '{"resign":true}')"
  smoke_assert_contains "$res" "status=409" "A5b: a stale-epoch relay is refused (409, refresh-and-retry)"
  smoke_assert_contains "$res" "relay_stale_epoch" "A5b: the refusal cites the stale epoch"
  smoke_assert_contains "$res" "relayed=False" "A5b: a stale-epoch message is NOT forwarded"
  local cap_size
  cap_size="$(wc -c <"$RELAY_LEG" 2>/dev/null | tr -d ' ' || echo 0)"
  smoke_assert_eq "0" "$cap_size" "A5b: NO relay leg was emitted for a stale-epoch message"
}

# ---------------------------------------------------------------------------
# A1: relay sig-replacement — a relayed leg carrying the ORIGINAL SENDER's peer
# (nodeB) instead of the LEADER (nodeA) is REJECTED at the target. The target
# verifies the LEADER, never the original sender.
# ---------------------------------------------------------------------------
test_A1_relay_sig_replacement_rejected() {
  local res
  res="$(deliver_to_target "$RELAY_LEG" '{"headers":{"X-AGB-Peer":"nodeB"}}')"
  smoke_assert_contains "$res" "status=403" "A1: a relayed leg claiming the original sender's peer is rejected"
  smoke_assert_contains "$res" "unknown peer" "A1: nodeC does not peer with nodeB (the sender) — only the leader"
  smoke_assert_contains "$res" "delivered=False" "A1: nothing is delivered on a sig-replacement"
}

# ---------------------------------------------------------------------------
# A1b: provenance-spoof defense (codex P1 r2) — a NON-room message carrying a
# FORGED relayed_via + relayed_from must NOT have its task provenance rewritten
# to the forged author. A non-room envelope can never be a legitimate relay leg,
# so the receiver keeps the REAL authenticated-peer provenance. The target here
# is on the SAME node delivering locally (nodeC peer=nodeB, allowlist victim).
# ---------------------------------------------------------------------------
test_A1b_nonroom_forged_relay_provenance() {
  local cfg_v="$SMOKE_TMP_ROOT/cfg-victim.json"
  python3 "$HELPER" make-config "$cfg_v" nodeC "nodeB" "$SECRET" "$ADDR" "victim" >/dev/null
  local inb="$SMOKE_TMP_ROOT/forged.json"
  python3 "$HELPER" build-nonroom-forged-relay "$inb" nodeB attacker victim boss admin-node >/dev/null
  local body="$SMOKE_TMP_ROOT/forged-body.txt"
  local res
  res="$(env "BRIDGE_A2A_ROOMS_DB=$TEST_DB_DIR/rooms-victim.db" \
      "DELIVERED_BODY_FILE=$body" \
    python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$cfg_v")" "$inb" '{"resign":true}')"
  smoke_assert_contains "$res" "delivered=True" "A1b: the non-room message is delivered (plain send)"
  smoke_assert_contains "$res" "relayed=False" "A1b: queue attribution correctly treats it as NOT relayed"
  smoke_assert_contains "$res" "\"sender_bridge\": \"nodeB\"" "A1b: provenance stays the REAL authed peer (nodeB), NOT the forged node"
  smoke_assert_contains "$res" "\"sender_agent\": \"attacker\"" "A1b: provenance stays the REAL sender (attacker), NOT the forged 'boss'"
  smoke_assert_not_contains "$res" "admin-node" "A1b: the forged relayed_from.node never reaches the delivered task"
  # codex #11494: the BODY must ALSO not render a forged relay line. A non-room
  # `relayed_via` is unvalidated, so the body renders the NORMAL non-relayed shape
  # showing only the REAL authenticated sender — no `relayed via` line, none of the
  # attacker-chosen forged values.
  smoke_assert_file_exists "$body" "A1b: the delivered task body was captured"
  local body_text
  body_text="$(cat "$body")"
  smoke_assert_contains "$body_text" "remote peer  : nodeB" "A1b: body provenance shows the REAL authed peer (nodeB)"
  smoke_assert_contains "$body_text" "remote agent : attacker" "A1b: body provenance shows the REAL sender (attacker)"
  smoke_assert_not_contains "$body_text" "relayed via" "A1b: the body renders NO 'relayed via' line for a forged non-room relayed_via"
  smoke_assert_not_contains "$body_text" "some-leader-node" "A1b: the attacker-chosen forged relay leader never reaches the body"
  smoke_assert_not_contains "$body_text" "admin-node" "A1b: the forged relayed_from.node never reaches the body"
  smoke_assert_not_contains "$body_text" "room leader" "A1b: no '(room leader)' annotation on a non-relayed message"
}

# ---------------------------------------------------------------------------
# A2: relay allowlist — the leader refuses to relay to a NON-member target
# (room-derived, fail-closed). A message to a non-member (ghost) gets the static
# allowlist 403 (the relay precheck refuses; it is never forwarded).
# ---------------------------------------------------------------------------
test_A2_relay_to_non_member_refused() {
  local inb="$SMOKE_TMP_ROOT/inbound-ghost.json"
  python3 "$HELPER" build-member-enqueue "$inb" nodeB alice ghost "$ROOM" 1 >/dev/null
  : >"$RELAY_LEG" || true
  local res
  res="$(deliver_to_leader "$inb" '{"resign":true}')"
  smoke_assert_contains "$res" "status=403" "A2: the leader refuses to relay to a non-member target (403)"
  smoke_assert_contains "$res" "relayed=False" "A2: nothing was relayed"
  # No relay leg was emitted (the forward never ran).
  local cap_size
  cap_size="$(wc -c <"$RELAY_LEG" 2>/dev/null | tr -d ' ' || echo 0)"
  smoke_assert_eq "0" "$cap_size" "A2: NO relay leg was forwarded to a non-member"
}

# ---------------------------------------------------------------------------
# A3: relay auth — the leader refuses to relay a message whose SENDER is not an
# approved room member (mallory@nodeB is a configured peer but NOT a member).
# ---------------------------------------------------------------------------
test_A3_non_member_sender_refused() {
  local inb="$SMOKE_TMP_ROOT/inbound-mallory.json"
  # mallory is on nodeB (a configured peer, so the member->leader HMAC verifies)
  # but is NOT a room member — the relay must refuse (fail closed).
  python3 "$HELPER" build-member-enqueue "$inb" nodeB mallory carol "$ROOM" 1 >/dev/null
  : >"$RELAY_LEG" || true
  local res
  res="$(deliver_to_leader "$inb" '{"resign":true}')"
  smoke_assert_contains "$res" "status=403" "A3: the leader refuses to relay a NON-member sender's message (403)"
  smoke_assert_contains "$res" "relayed=False" "A3: a non-member sender is never relayed"
  local cap_size
  cap_size="$(wc -c <"$RELAY_LEG" 2>/dev/null | tr -d ' ' || echo 0)"
  smoke_assert_eq "0" "$cap_size" "A3: NO relay leg was forwarded for a non-member sender"
}

# ---------------------------------------------------------------------------
# A4: no relay loop / amplification — an inbound message ALREADY carrying the
# relayed_via marker is REFUSED at the relay decision (never re-relayed).
# ---------------------------------------------------------------------------
test_A4_no_relay_loop() {
  local inb="$SMOKE_TMP_ROOT/inbound-relayed.json"
  # A member crafts a message pre-stamped relayed_via=nodeA to try to bounce it.
  # The leader's relay decision refuses (relay_loop_blocked) — it is NOT
  # forwarded a second time (M links, not M^2).
  python3 "$HELPER" build-member-enqueue "$inb" nodeB alice carol "$ROOM" 1 nodeA >/dev/null
  : >"$RELAY_LEG" || true
  local res
  res="$(deliver_to_leader "$inb" '{"resign":true}')"
  smoke_assert_contains "$res" "status=403" "A4: a pre-stamped relayed message is refused (no re-relay)"
  smoke_assert_contains "$res" "relayed=False" "A4: it is NOT forwarded again"
  local cap_size
  cap_size="$(wc -c <"$RELAY_LEG" 2>/dev/null | tr -d ' ' || echo 0)"
  smoke_assert_eq "0" "$cap_size" "A4: NO second relay leg was emitted (amplification blocked)"
}

# ---------------------------------------------------------------------------
# A4c: relay REPLAY protection — a member->leader message delivered TWICE (same
# message_id + body) is RELAYED once; the replay is an idempotent duplicate, NOT
# re-relayed (the reserve-first dedupe burns the id at the leader).
# ---------------------------------------------------------------------------
test_A4c_relay_replay_not_reforwarded() {
  # A fixed inbound (one message_id). The first delivery relays; the second is a
  # byte-identical replay → duplicate, never a second forward. The persistent
  # inbox.db under $BRIDGE_STATE_DIR carries the dedupe row between the two.
  local inb="$SMOKE_TMP_ROOT/inbound-replay.json"
  python3 "$HELPER" build-member-enqueue "$inb" nodeB alice carol "$ROOM" 1 >/dev/null
  local first second
  first="$(deliver_to_leader "$inb" '{"resign":true}')"
  smoke_assert_contains "$first" "status=202" "A4c: the first delivery is relayed (202)"
  smoke_assert_contains "$first" "relayed=True" "A4c: the first delivery forwarded the leg"
  # Empty the capture so a NEW forward (if it wrongly happened) would re-populate.
  : >"$RELAY_LEG" || true
  second="$(deliver_to_leader "$inb" '{"resign":true}')"
  smoke_assert_contains "$second" "status=200" "A4c: the replay is an idempotent 200"
  smoke_assert_contains "$second" "\"duplicate\": true" "A4c: the replay is flagged a duplicate"
  # The decisive no-re-forward proof: the replay did NOT emit a new relay leg
  # (the leader's reserve-first dedupe 'relayed' sentinel short-circuits before
  # any second forward). A genuine re-relay would have re-written $RELAY_LEG.
  local cap_size
  cap_size="$(wc -c <"$RELAY_LEG" 2>/dev/null | tr -d ' ' || echo 0)"
  smoke_assert_eq "0" "$cap_size" "A4c: the replay emitted NO second relay leg (not re-forwarded)"
}

# ---------------------------------------------------------------------------
# A4b: relay-resolve authorization surface (unit) — covers the decision teeth in
# one deterministic pass (valid / non-member-sender / non-member-target / loop /
# not-room-scoped).
# ---------------------------------------------------------------------------
test_A4b_relay_resolve_unit() {
  local udb="$TEST_DB_DIR/relay-resolve.db"
  python3 "$HELPER" make-leader-db "$udb" room-x lead nodeM \
    "lead@nodeM:leader,alice@nodeM,carol@nodeC,bob@nodeB" >/dev/null
  local cfg="$SMOKE_TMP_ROOT/cfg-resolve.json"
  python3 "$HELPER" make-config "$cfg" nodeM "nodeC,nodeB" "$SECRET" "$ADDR" "lead,alice" >/dev/null
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" relay-resolve-unit "$udb" "$(cat "$cfg")")"
  smoke_assert_contains "$out" "valid=ok:target=nodeC" "A4b: a valid member->member relay resolves to the target node"
  smoke_assert_contains "$out" "nonmember_sender=relay_sender_not_member" "A4b: a non-member sender is refused"
  smoke_assert_contains "$out" "nonmember_target=relay_target_not_member" "A4b: a non-member target is refused"
  smoke_assert_contains "$out" "loop=relay_loop_blocked" "A4b: an already-relayed message is loop-blocked"
  smoke_assert_contains "$out" "plain=not_applicable" "A4b: a non-room message is never a relay case"
}

# ---------------------------------------------------------------------------
# A5: roster epoch monotonic + membership-from-rooms.db (durable outbox unit).
# ---------------------------------------------------------------------------
test_A5_roster_epoch_monotonic() {
  local odb="$TEST_DB_DIR/outbox.db"
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" outbox-unit "$odb")"
  smoke_assert_contains "$out" "targets=nodeB,nodeC" "A5: the outbox targets the REMOTE member nodes (leader's own node excluded; from rooms.db)"
  smoke_assert_contains "$out" "epoch_after_lower=5" "A5: a LOWER epoch never lowers the queued target (monotonic)"
  smoke_assert_contains "$out" "epoch_after_higher=9" "A5: a HIGHER epoch raises the queued target"
  smoke_assert_contains "$out" "low_ack_status=pending" "A5: an ack BELOW the target epoch does not clear the row"
  smoke_assert_contains "$out" "high_ack_status=done" "A5: an ack AT/ABOVE the target epoch clears the row"
  # codex P2: a kicked node (no longer a member) is ALSO enqueued so it converges.
  smoke_assert_contains "$out" "removed_node_queued=True" "A5: a KICKED node is enqueued for convergence (receives the roster that drops it)"
}

# ---------------------------------------------------------------------------
# A6: kick/leave/deny broadcast + reconcile heartbeat re-broadcast converges.
# Driven through roster_epoch_reconcile: no rooms -> noop; a pending durable
# outbox row -> the heartbeat re-broadcasts it (the roster hook acks 200 -> the
# row clears -> the removed/changed member converges).
# ---------------------------------------------------------------------------
test_A6_membership_change_broadcast_heartbeat() {
  local rdb="$TEST_DB_DIR/recon.db"
  local cfg="$SMOKE_TMP_ROOT/cfg-recon.json"
  python3 "$HELPER" make-config "$cfg" nodeA "nodeB" "$SECRET" "$ADDR" "lead,bob" >/dev/null
  local out
  out="$(env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$ROSTER_HOOK" \
      "CAPTURE_FILE=$SMOKE_TMP_ROOT/roster-leg.json" \
    python3 "$HELPER" reconcile-unit "$SMOKE_REPO_ROOT" "$rdb" "$(cat "$cfg")")"
  smoke_assert_contains "$out" "no_rooms=noop" "A6: roster_epoch_reconcile no-ops when there are no rooms (L0 fixture contract)"
  smoke_assert_contains "$out" "pending_outcome=changed" "A6: a pending membership-change broadcast is re-broadcast by the heartbeat"
  smoke_assert_contains "$out" "remaining_after=0" "A6: the acked re-broadcast clears the durable outbox row (member converged)"
  smoke_assert_file_exists "$SMOKE_TMP_ROOT/roster-leg.json" "A6: the heartbeat emitted a roster broadcast leg"
}

# ---------------------------------------------------------------------------
# A6b: durable outbox RETIREMENT (codex P2 r2) — a node that never acks after the
# bounded attempt cap is RETIRED (no permanent zombie pending row); a later
# membership change RE-ARMS it (so a node that returns still converges).
# ---------------------------------------------------------------------------
test_A6b_outbox_retirement() {
  local rdb="$TEST_DB_DIR/retire.db"
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" outbox-retire-unit "$rdb")"
  smoke_assert_contains "$out" "after_cap_status=retired" "A6b: a node that exhausts the retry budget is RETIRED (not retried forever)"
  smoke_assert_contains "$out" "still_pending=0" "A6b: a retired node leaves NO pending zombie row"
  smoke_assert_contains "$out" "rearmed_status=pending:attempts=0" "A6b: a later membership change RE-ARMS the node (converges if it returns)"
}

# ---------------------------------------------------------------------------
# A7: no secret leak in the relay OR the roster broadcast payloads.
# ---------------------------------------------------------------------------
test_A7_no_secret_leak() {
  # Re-establish a fresh relay leg (prior teeth may have left a refusal/empty).
  python3 "$HELPER" build-member-enqueue "$INBOUND" nodeB alice carol "$ROOM" 1 >/dev/null
  deliver_to_leader "$INBOUND" '{"resign":true}' >/dev/null
  smoke_assert_file_exists "$RELAY_LEG" "A7: a relay leg is present to scan"
  local rs
  rs="$(python3 "$HELPER" secret-scan "$RELAY_LEG" 2>&1)" \
    || smoke_fail "A7: the relay leg leaked a secret/token shape: $rs"
  smoke_assert_contains "$rs" "OK secret-scan clean" "A7: the relay payload carries NO secret/token"
  if [[ -s "$SMOKE_TMP_ROOT/roster-leg.json" ]]; then
    local rs2
    rs2="$(python3 "$HELPER" secret-scan "$SMOKE_TMP_ROOT/roster-leg.json" 2>&1)" \
      || smoke_fail "A7: the roster broadcast leg leaked a secret/token shape: $rs2"
    smoke_assert_contains "$rs2" "OK secret-scan clean" "A7: the roster broadcast payload carries NO secret/token"
  fi
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "setup: a member->member room message is RELAYED by the leader" test_setup_member_to_leader_relay
smoke_run "positive: the relay leg delivers at the target (original author validated)" test_relay_leg_delivers_at_target
smoke_run "positive-body: the delivered body provenance agrees (alice@nodeB + relayed via nodeA)" test_relay_body_provenance_agrees
smoke_run "A1: relay sig-replacement is rejected (target verifies the LEADER)" test_A1_relay_sig_replacement_rejected
smoke_run "A1b: a non-room forged-relay message keeps its real provenance" test_A1b_nonroom_forged_relay_provenance
smoke_run "A2: the leader refuses to relay to a non-member target (fail closed)" test_A2_relay_to_non_member_refused
smoke_run "A3: the leader refuses to relay a non-member sender's message" test_A3_non_member_sender_refused
smoke_run "A4: a relayed message is never re-relayed (no loop / amplification)" test_A4_no_relay_loop
smoke_run "A4c: a relay replay is an idempotent duplicate, not re-forwarded" test_A4c_relay_replay_not_reforwarded
smoke_run "A4b: the relay-resolve authorization surface (unit)" test_A4b_relay_resolve_unit
smoke_run "A5: roster epoch is monotonic; membership from rooms.db not body" test_A5_roster_epoch_monotonic
smoke_run "A5b: the leader refuses to relay a stale-epoch message (409)" test_A5b_relay_stale_epoch_refused
smoke_run "A6: kick/leave/deny broadcast + reconcile heartbeat converge" test_A6_membership_change_broadcast_heartbeat
smoke_run "A6b: a never-acked outbox node is retired (no zombie), re-armed on change" test_A6b_outbox_retirement
smoke_run "A7: no secret leak in relay/roster payloads" test_A7_no_secret_leak

smoke_log "passed"
