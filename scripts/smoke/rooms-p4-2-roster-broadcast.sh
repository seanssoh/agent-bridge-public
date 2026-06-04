#!/usr/bin/env bash
# scripts/smoke/rooms-p4-2-roster-broadcast.sh — A2A Rooms P4.2 leader APPROVE +
# roster broadcast.
#
# Exercises the SECOND cross-node rooms phase (design docs/design/
# a2a-rooms-design.md §6 / §11 / §14 R2): on a cross-node `room approve`, the
# leader (node A) admits the member (REQUIRING a P4.1 verified pending row),
# bumps the epoch, and broadcasts the leader-signed canonical roster to every
# member node over the node-link; each member persists it to room_roster_cache.
# The transport is STUBBED end-to-end (no real Tailscale / live socket): the
# leader's broadcast POST is captured by the paired-flag test hook, then replayed
# through the REAL member-side receiver handler.
#
# THE 7 REQUIRED TEETH (each proven below):
#   T1  A cross-approve with NO matching verified pending row is refused (no
#       membership add) — and the LOCAL leader-add path still admits a local
#       agent WITHOUT claiming that gate (the two paths stay distinct).
#   T2  A roster_broadcast from a NON-LEADER authenticated peer is rejected +
#       persists nothing.
#   T3  A roster with an INVALID pairwise HMAC is rejected (401, no persist).
#   T4  A member with NO local pending/approved state for the room REJECTS a
#       FIRST roster (rogue-leader minting prevented).
#   T5  A lower-or-same epoch is ignored; a strictly-higher epoch updates; a
#       byte-identical dup is idempotent.
#   T6  The cache update is ATOMIC (an existing roster is never left partial; a
#       rejected update leaves the PRIOR roster, not a half-written one).
#   T7  The local-leader-add path still works for a LOCAL agent without claiming
#       the token gate (no P4.1 regression).

set -euo pipefail

SMOKE_NAME="rooms-p4-2-roster-broadcast"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/rooms-p4-2-roster-broadcast-helper.py"
P41_HELPER="$SCRIPT_DIR/rooms-p4-1-cross-node-join-helper.py"
POST_HOOK="$SCRIPT_DIR/rooms-p4-2-post-hook.sh"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# The leader's rooms.db (node A) lives under the isolated state dir.
export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

NODE_A="nodeA"   # leader node
NODE_B="nodeB"   # member node (the joiner)
SECRET="test-pair-secret-aaaaaaaaaaaaaaaaaaaa"
ADDR="127.0.0.1"

# Node-A (leader) config: bridge_id=nodeA, peer nodeB. Used by `room create` /
# `room approve` (the broadcast sender) and (for the join capture) the receiver.
CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"
python3 "$HELPER" make-config "$CFG_A" "$NODE_A" "$NODE_B" "$SECRET" "$ADDR" >/dev/null
CFG_A_JSON="$(cat "$CFG_A")"

# Node-B (member) config: bridge_id=nodeB, peer nodeA. Used by the member-side
# receiver replay (it must trust nodeA as the leader peer).
CFG_B="$SMOKE_TMP_ROOT/handoff-B.json"
python3 "$HELPER" make-config "$CFG_B" "$NODE_B" "$NODE_A" "$SECRET" "$ADDR" >/dev/null
CFG_B_JSON="$(cat "$CFG_B")"

# The member-local rooms.db (node B's own db) — the receiver writes its cache
# here. Distinct from the leader's db.
MEMBER_DB="$SMOKE_TMP_ROOT/member-rooms.db"

CAPTURE="$SMOKE_TMP_ROOT/captured-roster.json"
JOIN_CAPTURE="$SMOKE_TMP_ROOT/captured-join.json"

# Paired test-seam flags (gate the OS-user override AND the POST hook). Set
# INLINE per-invocation, never exported, so nothing leaks.
TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

json_field() { python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" json-field "$1" "$2"; }

# room_create_as <agent> — create a room led by iso-user agent-bridge-<a> on
# node A. Echoes the JSON.
room_create_as() {
  local who="$1"
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" create --name team --json 2>/dev/null
}

# Post a P4.1 cross-node join from node B → capture it → replay into the leader's
# node-A receiver so a VERIFIED pending row exists for the approve gate.
seed_verified_join() {
  local who="$1" link="$2"
  : >"$JOIN_CAPTURE" || true
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_B" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$SCRIPT_DIR/rooms-p4-1-post-hook.sh" \
      "CAPTURE_FILE=$JOIN_CAPTURE" \
    python3 "$ROOMS_CLI" join "$link" >/dev/null 2>&1 \
    || smoke_fail "P4.1 cross-node join (sender) should succeed against the stub"
  # Replay the join into the leader-node-A receiver → 200 pending (verified row).
  python3 "$P41_HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$CFG_A_JSON" \
    "$JOIN_CAPTURE" "{}" >/dev/null
}

# approve_as <agent> <room> <target> — run `room approve` as iso-user
# agent-bridge-<a> on node A, with the roster-broadcast POST hook capturing the
# signed broadcast to $CAPTURE. Echoes the CLI JSON output.
approve_as() {
  local who="$1" room="$2" target="$3"
  : >"$CAPTURE" || true
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" \
    python3 "$ROOMS_CLI" approve "$room" "$target" --json 2>/dev/null
}

# deliver_roster <member_cfg_json> <overrides_json> — replay $CAPTURE through the
# REAL member-side receiver, writing the member-local cache into $MEMBER_DB.
deliver_roster() {
  local cfg_json="$1" overrides="${2:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  env "BRIDGE_A2A_ROOMS_DB=$MEMBER_DB" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$cfg_json" "$CAPTURE" "$overrides"
}

ROOM=""
LINK=""

# ---------------------------------------------------------------------------
# setup: a room on node A + a verified pending join from node B + the approve
# that captures the leader-signed roster broadcast.
# ---------------------------------------------------------------------------
test_setup_room_join_approve_capture() {
  local out
  out="$(room_create_as alice)"
  ROOM="$(json_field room_id "$out")"
  LINK="$(json_field invite_link "$out")"
  [[ -n "$ROOM" && -n "$LINK" ]] || smoke_fail "room create did not yield room/link"

  # A P4.1 verified pending row for bob@nodeB so the cross-approve gate is met.
  seed_verified_join bob "$LINK"

  # The leader approves the cross-node member → broadcast captured.
  local ap
  ap="$(approve_as alice "$ROOM" "bob@$NODE_B")"
  smoke_assert_contains "$ap" "\"cross_node\": true" "approve recognized a cross-node admit"
  smoke_assert_file_exists "$CAPTURE" "the leader-signed roster broadcast was captured"

  # The captured broadcast targets nodeB with the canonical roster + leader_node.
  local proto leader_node room_in_body
  proto="$(python3 "$HELPER" captured-field "$CAPTURE" "header:X-AGB-Protocol")"
  smoke_assert_eq "a2a-room-roster-v1" "$proto" "broadcast carries the roster protocol tag"
  leader_node="$(python3 "$HELPER" captured-field "$CAPTURE" "body:leader_node")"
  smoke_assert_eq "$NODE_A" "$leader_node" "broadcast body names nodeA as leader_node"
  room_in_body="$(python3 "$HELPER" captured-field "$CAPTURE" "body:room_id")"
  smoke_assert_eq "$ROOM" "$room_in_body" "broadcast body carries the room id"
}

# ---------------------------------------------------------------------------
# positive: a member with a local binding accepts the broadcast → cache written
# ---------------------------------------------------------------------------
test_member_accepts_first_roster_with_binding() {
  # Seed the member-local binding (its OWN outbound join intent) so the first
  # roster is acceptable (NOT minted from the inbound broadcast alone).
  python3 "$HELPER" make-member-db "$MEMBER_DB" "$ROOM" "$NODE_A" bob "$NODE_B" >/dev/null
  local res
  res="$(deliver_roster "$CFG_B_JSON")"
  smoke_assert_contains "$res" "status=200" "member accepts the leader roster (200)"
  smoke_assert_contains "$res" "\"applied\": true" "the roster cache was applied"
  local rows
  rows="$(python3 "$HELPER" cache-rows "$MEMBER_DB" "$ROOM")"
  smoke_assert_contains "$rows" "\"from_node\": \"$NODE_A\"" "cache records the leader node as source"
  smoke_assert_contains "$rows" "bob" "cache roster contains the admitted member bob"
  smoke_assert_contains "$rows" "alice" "cache roster contains the leader alice"
}

# ---------------------------------------------------------------------------
# CLI end-to-end: the REAL `room join` records the FIRST-ROSTER binding (driven
# off the leader's pending ack), which then lets the member accept the leader's
# first roster — proving the binding is not a test-only seed.
# ---------------------------------------------------------------------------
test_cli_join_records_binding_then_accepts() {
  local mdb="$SMOKE_TMP_ROOT/member-cli.db"
  # Run the REAL member-side cross-node `room join` (post stubbed). The stub
  # returns a pending ack for a room-join post, so cmd_join records the local
  # binding into the member's OWN rooms.db ($mdb).
  : >"$JOIN_CAPTURE" || true
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-bob" \
      "BRIDGE_A2A_CONFIG=$CFG_B" \
      "BRIDGE_A2A_ROOMS_DB=$mdb" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$JOIN_CAPTURE" \
    python3 "$ROOMS_CLI" join "$LINK" >/dev/null 2>&1 \
    || smoke_fail "member-side cross-node join (CLI) should succeed against the stub"
  # The CLI recorded a local pending-intent row naming nodeA as the leader.
  local rows
  rows="$(python3 "$P41_HELPER" pending-rows "$mdb" "$ROOM")"
  smoke_assert_contains "$rows" "\"via_node\": \"$NODE_A\"" \
    "CLI join recorded a local binding naming the leader node"
  # That binding now lets the member accept the leader's FIRST roster broadcast.
  local res
  res="$(deliver_roster_into "$mdb" "$CFG_B_JSON")"
  smoke_assert_contains "$res" "status=200" "CLI-bound member accepts the first roster (200)"
  smoke_assert_contains "$res" "\"applied\": true" "the roster cache was applied for the CLI-bound member"
}

# ---------------------------------------------------------------------------
# T1: a cross-approve with NO verified pending row is refused (no add); plus the
# local-add path admits a local agent with no such requirement (distinct paths).
# ---------------------------------------------------------------------------
test_T1_cross_approve_requires_verified_pending() {
  local gdb="$SMOKE_TMP_ROOT/gate.db"
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" cross-approve-gate "$gdb" 2>&1)" \
    || smoke_fail "cross-approve-gate helper must not raise: $out"
  smoke_assert_contains "$out" "no_row=refused:no_verified_request" \
    "T1: a cross-approve with NO pending row is refused"
  smoke_assert_contains "$out" "unverified_row=refused:no_verified_request" \
    "T1: a cross-approve with an UNVERIFIED (local) pending row is refused"
  smoke_assert_contains "$out" "verified_row=admitted:" \
    "T1: a cross-approve WITH a verified pending row admits the member"
  smoke_assert_contains "$out" "member=True" "T1: the verified member is actually added"
  smoke_assert_contains "$out" "carl_member=False" \
    "T1: no unverified agent was admitted as a side effect"
}

# ---------------------------------------------------------------------------
# T2: a roster_broadcast from a NON-LEADER authenticated peer is rejected.
# ---------------------------------------------------------------------------
test_T2_non_leader_peer_rejected() {
  # A fresh member db with a binding to the leader nodeA, but deliver the
  # broadcast over a config where the authenticated peer is nodeC (NOT the
  # room's leader_node nodeA). The receiver must reject + persist nothing.
  local mdb="$SMOKE_TMP_ROOT/member-t2.db"
  python3 "$HELPER" make-member-db "$mdb" "$ROOM" "$NODE_A" bob "$NODE_B" >/dev/null
  # nodeC config: the member trusts nodeC as a peer (so HMAC/addr pass), but the
  # captured broadcast was signed by nodeA. We re-sign as nodeC so the HMAC gate
  # passes and the test reaches the leader-authority contract (peer != leader).
  local cfg_c="$SMOKE_TMP_ROOT/handoff-Cmember.json"
  python3 "$HELPER" make-config "$cfg_c" "$NODE_B" "nodeC" "$SECRET" "$ADDR" >/dev/null
  local res
  res="$(env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$cfg_c")" "$CAPTURE" \
      '{"headers":{"X-AGB-Peer":"nodeC"},"resign":true}')"
  smoke_assert_contains "$res" "status=403" "T2: a non-leader peer roster is 403"
  smoke_assert_contains "$res" "not the room leader" "T2: refusal reason is non-leader"
  local rows
  rows="$(python3 "$HELPER" cache-rows "$mdb" "$ROOM")"
  smoke_assert_eq "" "$rows" "T2: a non-leader roster persists NOTHING"
}

# ---------------------------------------------------------------------------
# T3: a roster with an INVALID pairwise HMAC is rejected (401, no persist).
# ---------------------------------------------------------------------------
test_T3_invalid_hmac_rejected() {
  local mdb="$SMOKE_TMP_ROOT/member-t3.db"
  python3 "$HELPER" make-member-db "$mdb" "$ROOM" "$NODE_A" bob "$NODE_B" >/dev/null
  local res
  res="$(env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$CFG_B_JSON" "$CAPTURE" \
      '{"headers":{"X-AGB-Signature":"v1=deadbeefdeadbeef"}}')"
  smoke_assert_contains "$res" "status=401" "T3: a bad pairwise HMAC is 401 (auth gate intact)"
  local rows
  rows="$(python3 "$HELPER" cache-rows "$mdb" "$ROOM")"
  smoke_assert_eq "" "$rows" "T3: an HMAC-rejected roster persists NOTHING"
}

# ---------------------------------------------------------------------------
# T4: a member with NO local binding REJECTS a FIRST roster (rogue-leader mint).
# ---------------------------------------------------------------------------
test_T4_first_roster_without_binding_refused() {
  # A member db that has NEVER recorded a local join intent for $ROOM. Even a
  # perfectly-signed roster from the real leader nodeA must be refused — the
  # member never chose this room, so accepting would let a configured peer mint
  # a rogue-leader room cache.
  local mdb="$SMOKE_TMP_ROOT/member-nobind.db"
  # Create the db but with a binding for a DIFFERENT room only, to prove the
  # binding is room-specific (not a blanket "any local row").
  python3 "$HELPER" make-member-db "$mdb" "room-other" "$NODE_A" bob "$NODE_B" >/dev/null
  local res
  res="$(env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$CFG_B_JSON" "$CAPTURE")"
  smoke_assert_contains "$res" "status=403" "T4: a first roster with no local binding is 403"
  smoke_assert_contains "$res" "no local join state" "T4: refusal cites the missing local binding"
  local rows
  rows="$(python3 "$HELPER" cache-rows "$mdb" "$ROOM")"
  smoke_assert_eq "" "$rows" "T4: NO roster cache minted from the inbound broadcast"
}

# ---------------------------------------------------------------------------
# T5: epoch monotonicity (lower/same ignored, higher updates, identical dup).
# Unit-driven across the full contract surface for determinism.
# ---------------------------------------------------------------------------
test_T5_epoch_monotonicity() {
  local udb="$SMOKE_TMP_ROOT/accept-unit.db"
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" member-accept-unit "$udb" 2>&1)" \
    || smoke_fail "member-accept-unit helper must not raise: $out"
  smoke_assert_contains "$out" "first_bind=accepted:epoch=2" \
    "T5: a first bound roster is accepted at its epoch"
  smoke_assert_contains "$out" "higher_epoch=accepted:epoch=3:has_carol=True" \
    "T5: a strictly-higher epoch UPDATES the cache"
  smoke_assert_contains "$out" "lower_epoch=stale_epoch:epoch=3:still_carol=True" \
    "T5: a LOWER epoch is IGNORED (cache unchanged)"
  smoke_assert_contains "$out" "same_epoch_diff=stale_epoch:still_carol=True" \
    "T5: a SAME epoch with DIFFERENT members is IGNORED (forge/replay defense)"
  smoke_assert_contains "$out" "idempotent_dup=duplicate" \
    "T5: a byte-identical re-broadcast is an idempotent duplicate"
  # Leader-pinning: a higher-epoch self-claim by a DIFFERENT peer is refused.
  smoke_assert_contains "$out" "takeover=leader_mismatch:from_node=nodeA:epoch=3:has_mallory=False" \
    "T5/pinning: a higher-epoch leader-TAKEOVER by a different peer is refused (cache stays pinned to nodeA)"
}

# ---------------------------------------------------------------------------
# T2b (codex P4.2 r1 BLOCKING): leader-TAKEOVER of an EXISTING cache through the
# REAL receiver. A configured peer nodeC self-claims leadership (leader_node=
# nodeC, peer=nodeC, valid pairwise HMAC) at a HIGHER epoch against a member
# whose cache for $ROOM is already pinned to nodeA → 403, no cache mutation.
# ---------------------------------------------------------------------------
test_T2b_existing_cache_leader_takeover_refused() {
  local mdb="$SMOKE_TMP_ROOT/member-takeover.db"
  python3 "$HELPER" make-member-db "$mdb" "$ROOM" "$NODE_A" bob "$NODE_B" >/dev/null
  # Establish the legitimate nodeA cache first (the captured leader broadcast).
  local first
  first="$(deliver_roster_into "$mdb" "$CFG_B_JSON")"
  smoke_assert_contains "$first" "status=200" "T2b setup: the legitimate nodeA roster is cached"
  local before
  before="$(python3 "$HELPER" cache-rows "$mdb" "$ROOM")"
  # nodeC self-claims leadership at a higher epoch, signed with a secret nodeC
  # shares with this member. Build a rogue roster body + a member cfg that trusts
  # nodeC, re-sign as nodeC so the HMAC gate passes and we reach the pin check.
  local cfg_c="$SMOKE_TMP_ROOT/handoff-takeover.json"
  python3 "$HELPER" make-config "$cfg_c" "$NODE_B" "nodeC" "$SECRET" "$ADDR" >/dev/null
  local rogue_body
  rogue_body='{"protocol":"agent-bridge.a2a.room-roster.v1","room_id":"'"$ROOM"'","room_epoch":99,"members":[{"agent":"mallory","node":"nodeC","role":"leader"}],"leader_node":"nodeC"}'
  local res
  res="$(env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$cfg_c")" "$CAPTURE" \
      '{"headers":{"X-AGB-Peer":"nodeC"},"body":'"$(python3 -c "import json,sys;print(json.dumps(sys.argv[1]))" "$rogue_body")"',"resign":true}')"
  smoke_assert_contains "$res" "status=403" "T2b: a higher-epoch leader-takeover by nodeC is 403"
  smoke_assert_contains "$res" "takeover refused" "T2b: refusal cites the takeover"
  local after
  after="$(python3 "$HELPER" cache-rows "$mdb" "$ROOM")"
  smoke_assert_eq "$before" "$after" "T2b: the takeover left the nodeA cache byte-for-byte unchanged"
  smoke_assert_not_contains "$after" "mallory" "T2b: no rogue member entered the cache"
}

# ---------------------------------------------------------------------------
# T2c (codex P4.2 r2 BLOCKING): a SINGLE-NODE / local room whose cache from_node
# is EMPTY (leader_node="") cannot be taken over by a remote peer self-claiming
# leadership at a higher epoch — the leader pin rejects even an empty cached
# leader (no truthiness guard).
# ---------------------------------------------------------------------------
test_T2c_empty_leader_takeover_refused() {
  local edb="$SMOKE_TMP_ROOT/empty-leader.db"
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" empty-leader-takeover-unit "$edb" 2>&1)" \
    || smoke_fail "empty-leader-takeover-unit helper must not raise: $out"
  smoke_assert_contains "$out" "empty_takeover=leader_mismatch:from_node='':epoch=0:unchanged=True:has_mallory=False" \
    "T2c: a remote higher-epoch self-claim against an empty-leader local cache is refused (unchanged)"
}

# ---------------------------------------------------------------------------
# T6: the cache update is ATOMIC — a rejected update over an EXISTING roster
# leaves the PRIOR roster intact, never a partial/half-written one.
# ---------------------------------------------------------------------------
test_T6_atomic_no_partial_roster() {
  # Start from the positive-path member db (it holds an applied roster for $ROOM
  # at the approved epoch with bob present). Capture its current state.
  local before after
  before="$(python3 "$HELPER" cache-rows "$MEMBER_DB" "$ROOM")"
  [[ -n "$before" ]] || smoke_fail "T6 precondition: an existing cache row is required"
  # Deliver a roster that will be REJECTED downstream of the cache (a non-leader
  # peer) — the existing roster must be untouched (no partial write).
  local cfg_c="$SMOKE_TMP_ROOT/handoff-Cmember2.json"
  python3 "$HELPER" make-config "$cfg_c" "$NODE_B" "nodeC" "$SECRET" "$ADDR" >/dev/null
  env "BRIDGE_A2A_ROOMS_DB=$MEMBER_DB" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$(cat "$cfg_c")" "$CAPTURE" \
      '{"headers":{"X-AGB-Peer":"nodeC"},"resign":true}' >/dev/null
  after="$(python3 "$HELPER" cache-rows "$MEMBER_DB" "$ROOM")"
  smoke_assert_eq "$before" "$after" \
    "T6: a rejected roster left the PRIOR cache byte-for-byte unchanged (atomic)"
  # Also a stale-epoch update must not partially mutate the existing roster.
  python3 "$HELPER" set-cache-epoch "$MEMBER_DB" "$ROOM" 99 >/dev/null
  local hi
  hi="$(python3 "$HELPER" cache-rows "$MEMBER_DB" "$ROOM")"
  env "BRIDGE_A2A_ROOMS_DB=$MEMBER_DB" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$CFG_B_JSON" "$CAPTURE" >/dev/null
  local hi_after
  hi_after="$(python3 "$HELPER" cache-rows "$MEMBER_DB" "$ROOM")"
  smoke_assert_eq "$hi" "$hi_after" \
    "T6: a stale-epoch broadcast left the higher-epoch cache intact (no partial write)"
}

# ---------------------------------------------------------------------------
# T7: the local-leader-add path admits a LOCAL agent WITHOUT the token gate
# (no P4.1 regression — the two approve paths stay distinct).
# ---------------------------------------------------------------------------
test_T7_local_add_no_token_gate() {
  local ldb="$SMOKE_TMP_ROOT/local-add.db"
  local out
  out="$(env "${TEST_FLAGS[@]}" python3 "$HELPER" local-add-no-gate "$ldb" 2>&1)" \
    || smoke_fail "local-add-no-gate helper must not raise: $out"
  smoke_assert_contains "$out" "local_add=admitted:" \
    "T7: the LOCAL leader-add path admits a local agent with NO verified row"
  smoke_assert_contains "$out" "member=True" "T7: the locally-added agent is a member"
  smoke_assert_contains "$out" "cross_path_for_local=refused:no_verified_request" \
    "T7: the cross-node path STILL requires a verified row (the paths are distinct)"
}

# ---------------------------------------------------------------------------
# auth preamble teeth: unknown peer / wrong source addr are refused (unweakened)
# ---------------------------------------------------------------------------
test_auth_preamble_unweakened() {
  local mdb="$SMOKE_TMP_ROOT/member-auth.db"
  python3 "$HELPER" make-member-db "$mdb" "$ROOM" "$NODE_A" bob "$NODE_B" >/dev/null
  # Wrong source address → 403 (remote_addr gate intact).
  local res
  res="$(env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$CFG_B_JSON" "$CAPTURE" '{"client_ip":"10.9.9.9"}')"
  smoke_assert_contains "$res" "status=403" "auth: a wrong source address is 403"
  # Unknown peer → 403.
  res="$(env "BRIDGE_A2A_ROOMS_DB=$mdb" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$CFG_B_JSON" "$CAPTURE" '{"headers":{"X-AGB-Peer":"nodeZ"}}')"
  smoke_assert_contains "$res" "status=403" "auth: an unknown peer is 403"
}

# ---------------------------------------------------------------------------
# idempotent re-delivery: a byte-identical broadcast replays as an idempotent
# 200 duplicate (peer-scoped dedupe), the cache unchanged.
# ---------------------------------------------------------------------------
test_idempotent_redelivery() {
  local mdb="$SMOKE_TMP_ROOT/member-idem.db"
  python3 "$HELPER" make-member-db "$mdb" "$ROOM" "$NODE_A" bob "$NODE_B" >/dev/null
  local first second
  first="$(deliver_roster_into "$mdb" "$CFG_B_JSON")"
  smoke_assert_contains "$first" "status=200" "idem: first delivery is 200 applied"
  smoke_assert_contains "$first" "\"applied\": true" "idem: first delivery applied the cache"
  second="$(deliver_roster_into "$mdb" "$CFG_B_JSON")"
  smoke_assert_contains "$second" "status=200" "idem: a byte-identical re-delivery is 200"
  smoke_assert_contains "$second" "\"duplicate\": true" "idem: the replay is flagged duplicate"
}

# deliver_roster_into <db> <cfg_json> [overrides]
deliver_roster_into() {
  local db="$1" cfg_json="$2" overrides="${3:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  env "BRIDGE_A2A_ROOMS_DB=$db" \
    python3 "$HELPER" deliver-roster-to-receiver "$SMOKE_REPO_ROOT" \
      "$cfg_json" "$CAPTURE" "$overrides"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "setup: room + verified join + cross-approve broadcast captured" test_setup_room_join_approve_capture
smoke_run "positive: a member with a local binding accepts the first roster" test_member_accepts_first_roster_with_binding
smoke_run "CLI end-to-end: real join records the binding -> member accepts first roster" test_cli_join_records_binding_then_accepts
smoke_run "T1: cross-approve REQUIRES a verified pending row (no add otherwise)" test_T1_cross_approve_requires_verified_pending
smoke_run "T2: a non-leader peer roster is rejected + persists nothing" test_T2_non_leader_peer_rejected
smoke_run "T2b: a higher-epoch leader-TAKEOVER of an existing cache is refused" test_T2b_existing_cache_leader_takeover_refused
smoke_run "T2c: a remote takeover of an empty-leader local cache is refused" test_T2c_empty_leader_takeover_refused
smoke_run "T3: an invalid pairwise HMAC is rejected (401, no persist)" test_T3_invalid_hmac_rejected
smoke_run "T4: a first roster with NO local binding is refused (rogue-leader mint prevented)" test_T4_first_roster_without_binding_refused
smoke_run "T5: epoch monotonicity (lower/same ignored, higher updates, dup idempotent)" test_T5_epoch_monotonicity
smoke_run "T6: the cache update is atomic (a rejected update leaves the prior roster)" test_T6_atomic_no_partial_roster
smoke_run "T7: the local-leader-add path admits a local agent without the token gate" test_T7_local_add_no_token_gate
smoke_run "auth preamble unweakened (remote_addr 403 / unknown peer 403)" test_auth_preamble_unweakened
smoke_run "idempotent re-delivery: a byte-identical broadcast is an idempotent 200" test_idempotent_redelivery

smoke_log "passed"
