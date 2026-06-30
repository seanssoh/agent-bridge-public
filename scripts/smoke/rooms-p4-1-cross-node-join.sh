#!/usr/bin/env bash
# scripts/smoke/rooms-p4-1-cross-node-join.sh — A2A Rooms P4.1 cross-node JOIN.
#
# Exercises the FIRST cross-node rooms phase (design docs/design/
# a2a-rooms-design.md §11 / §14 R3): a member on node B posts a signed
# room-join-request to the leader's node A over the node-link; node A verifies
# (node-link HMAC + token-hash + TTL + revocation) and persists a PENDING row
# (no auto-admit — approve is P4.2). The transport is STUBBED end-to-end (no
# real Tailscale / live socket): the sender's POST is captured by the paired-
# flag test hook, then replayed through the REAL receiver handler.
#
# THE 5 REQUIRED TEETH (each proven below):
#   T1  Hostile --from / BRIDGE_AGENT_ID / USER CANNOT change the recorded
#       joiner — the joiner id is OS-actor-anchored (resolve_os_actor).
#   T2  A process on node B cannot post a join-request as a *different* B agent
#       (the joiner is the OS-uid-derived agent; the node is the HMAC-authed
#       peer, never a wire field).
#   T3  An expired (TTL) OR revoked (rotated) token is REFUSED — no pending row.
#   T4  The raw token AND its hash never appear in any queue / task / audit /
#       staged file.
#   T5  A malformed / duplicate join-request is handled (no crash; dedupe).
#
# Plus a positive path: a valid cross-node request persists a verified=1 pending
# row anchored to <joiner-os-agent>@<authenticated-peer-node>.

set -euo pipefail

SMOKE_NAME="rooms-p4-1-cross-node-join"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/rooms-p4-1-cross-node-join-helper.py"
POST_HOOK="$SCRIPT_DIR/rooms-p4-1-post-hook.sh"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# The leader's rooms.db (node A) lives under the isolated state dir. Node B (the
# joiner) never writes it — the cross-node path posts over the node-link.
export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

NODE_A="nodeA"
NODE_B="nodeB"
SECRET="test-pair-secret-aaaaaaaaaaaaaaaaaaaa"
ADDR="127.0.0.1"     # literal peer address → resolve_peer_address returns it (no Tailscale)

# Node-A receiver config (bridge_id=nodeA, peer nodeB) — used by deliver-to-receiver.
CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"
python3 "$HELPER" make-config "$CFG_A" "$NODE_A" "$NODE_B" "$SECRET" "$ADDR" >/dev/null
CFG_A_JSON="$(cat "$CFG_A")"

# Node-B sender config (bridge_id=nodeB, peer nodeA) — used by `room join`.
CFG_B="$SMOKE_TMP_ROOT/handoff-B.json"
python3 "$HELPER" make-config "$CFG_B" "$NODE_B" "$NODE_A" "$SECRET" "$ADDR" >/dev/null

CAPTURE="$SMOKE_TMP_ROOT/captured-request.json"

# Paired test-seam flags (gate the OS-user override AND the POST hook). Set
# INLINE per-invocation, never exported, so nothing leaks. Mirrors P1a.
TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# room_create_as <agent> <ttl> — create a room led by iso-user agent-bridge-<a>
# on node A. Echoes the JSON. Runs against the node-A config so leader_node=nodeA.
room_create_as() {
  local who="$1" ttl="$2"
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" create --name team --ttl "$ttl" --json 2>/dev/null
}

# join_cross_node_as <os-agent> [extra env...] -- <join-args...>
# Runs `room join` as iso-user agent-bridge-<os-agent> on node B, with the POST
# hook capturing the signed request to $CAPTURE. Extra env (the hostile
# --from/BRIDGE_AGENT_ID/USER spoof) is passed through. Returns the CLI rc.
join_cross_node_as() {
  local who="$1"; shift
  local extra=()
  while [[ "${1:-}" != "--" ]]; do extra+=("$1"); shift; done
  shift  # drop the --
  : >"$CAPTURE" || true
  # `${extra[@]+...}` guards the empty-array-under-`set -u` footgun (a no-op on
  # bash 5.x; required so bash 3.2 does not error on an empty TEST_FLAGS/extra).
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_B" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "CAPTURE_FILE=$CAPTURE" \
      ${extra[@]+"${extra[@]}"} \
    python3 "$ROOMS_CLI" join "$@"
}

json_field() { python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" json-field "$1" "$2"; }

# deliver <overrides_json> — replay $CAPTURE through the real node-A receiver.
deliver() {
  local overrides="${1:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$CFG_A_JSON" \
    "$CAPTURE" "$overrides"
}

ROOM=""
LINK=""
RAW_TOKEN=""
TOKEN_HASH=""

# ---------------------------------------------------------------------------
# setup: a room on node A + capture a baseline valid cross-node join from B
# ---------------------------------------------------------------------------
test_setup_room_and_capture() {
  local out
  out="$(room_create_as alice 0)"
  ROOM="$(json_field room_id "$out")"
  LINK="$(json_field invite_link "$out")"
  [[ -n "$ROOM" && -n "$LINK" ]] || smoke_fail "room create did not yield room/link"
  smoke_assert_contains "$LINK" "leader=$NODE_A" "invite link carries leader=nodeA"
  RAW_TOKEN="$(python3 "$SCRIPT_DIR/a2a-rooms-p1a-helper.py" token-from-link "$LINK")"
  [[ -n "$RAW_TOKEN" ]] || smoke_fail "could not extract raw token from link"
  TOKEN_HASH="$(python3 -c "import hashlib,sys;print(hashlib.sha256(sys.argv[1].encode()).hexdigest())" "$RAW_TOKEN")"
}

# ---------------------------------------------------------------------------
# positive: a valid cross-node join persists a verified pending row
# ---------------------------------------------------------------------------
test_valid_cross_node_join_persists_pending() {
  join_cross_node_as bob -- "$LINK" >/dev/null 2>&1 \
    || smoke_fail "cross-node join (sender side) should succeed against the stub"
  smoke_assert_file_exists "$CAPTURE" "the signed cross-node request was captured"
  # Deliver to the real receiver → 200 pending.
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=200" "valid cross-node join → 200 at the leader"
  smoke_assert_contains "$res" "\"status\": \"pending\"" "leader records it as pending"
  # The persisted row: verified=1, agent=bob (OS-actor), node=nodeB (authed peer).
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_contains "$rows" "\"agent\": \"bob\"" "pending row joiner agent is the OS-actor (bob)"
  smoke_assert_contains "$rows" "\"node\": \"$NODE_B\"" "pending row joiner node is the AUTHENTICATED peer (nodeB)"
  smoke_assert_contains "$rows" "\"verified\": 1" "pending row is marked verified (post node-link auth)"
  smoke_assert_contains "$rows" "\"via_node\": \"$NODE_B\"" "via_node bound to the authenticated node-link peer"
}

# ---------------------------------------------------------------------------
# T1: hostile --from / BRIDGE_AGENT_ID / USER cannot change the joiner
# ---------------------------------------------------------------------------
test_T1_hostile_from_env_cannot_change_joiner() {
  # bob's iso uid joins, but the process screams "I am mallory" three ways.
  join_cross_node_as bob \
      "BRIDGE_AGENT_ID=mallory" "USER=mallory" \
      -- "$LINK" --as mallory >/dev/null 2>&1 \
    || smoke_fail "join should still succeed (the spoof is ignored, not fatal)"
  # The WIRE joiner_agent must be bob (the OS-actor), NEVER mallory.
  local wire_agent
  wire_agent="$(python3 "$HELPER" captured-field "$CAPTURE" "body:joiner_agent")"
  smoke_assert_eq "bob" "$wire_agent" \
    "T1: wire joiner_agent is the OS-actor (bob), NOT the hostile --from/env (mallory)"
  # And the receiver records bob, not mallory.
  deliver >/dev/null
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_not_contains "$rows" "mallory" \
    "T1: no 'mallory' row — the OS-actor anchor held end-to-end"
}

# ---------------------------------------------------------------------------
# T2: a node-B process cannot join as a *different* node-B agent
# ---------------------------------------------------------------------------
test_T2_cannot_join_as_a_different_B_agent() {
  # carol's iso uid joins while claiming to be bob every spoofable way.
  join_cross_node_as carol \
      "BRIDGE_AGENT_ID=bob" "USER=bob" \
      -- "$LINK" --as bob >/dev/null 2>&1 \
    || smoke_fail "join should succeed (claim ignored, not fatal)"
  local wire_agent
  wire_agent="$(python3 "$HELPER" captured-field "$CAPTURE" "body:joiner_agent")"
  smoke_assert_eq "carol" "$wire_agent" \
    "T2: a node-B process is bound to its OWN OS-actor (carol), cannot claim 'bob'"
  # The wire carries NO joiner_node field at all — the node is the authed peer.
  local wire_node
  wire_node="$(python3 "$HELPER" captured-field "$CAPTURE" "body:joiner_node" 2>/dev/null || true)"
  smoke_assert_eq "" "$wire_node" \
    "T2: there is NO wire-asserted joiner_node (the node is bound to the HMAC peer)"
  deliver >/dev/null
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_contains "$rows" "\"agent\": \"carol\"" "T2: carol recorded as herself"
}

# ---------------------------------------------------------------------------
# T3: expired (TTL) OR revoked token is REFUSED — no pending row
# ---------------------------------------------------------------------------
test_T3a_expired_token_refused() {
  # A room with a 1-second TTL; backdate the token ts so it is already expired.
  local out room link
  out="$(room_create_as dora 1)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  python3 "$HELPER" set-token-ts "$BRIDGE_A2A_ROOMS_DB" "$room" 1 >/dev/null
  join_cross_node_as erin -- "$link" >/dev/null 2>&1 \
    || smoke_fail "sender side should succeed (the leader decides validity)"
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=403" "T3: an EXPIRED token is refused (403)"
  smoke_assert_contains "$res" "expired" "T3: refusal reason is 'expired'"
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$room")"
  smoke_assert_not_contains "$rows" "erin" "T3: NO pending row for an expired-token join"
  # codex P4.1 r1 regression: a REPLAY of the rejected expired request must STILL
  # be 403 (it left NO dedupe row), never an idempotent 200.
  local replay
  replay="$(deliver)"
  smoke_assert_contains "$replay" "status=403" \
    "T3: a REPLAYED expired-token request is STILL 403 (no idempotent-200 bypass)"
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$room")"
  smoke_assert_not_contains "$rows" "erin" "T3: replay still leaves NO pending row"
}

test_T3b_revoked_token_refused() {
  # Rotate the lifecycle room's invite → the OLD captured token (from $LINK,
  # already captured for $ROOM) is now revoked. Re-capture an old-token request
  # then rotate, and deliver: the leader must refuse (hash no longer matches).
  join_cross_node_as fred -- "$LINK" >/dev/null 2>&1 \
    || smoke_fail "capture an old-token request before rotating"
  # Leader rotates the invite (revokes the old token).
  env "${TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-alice" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
    python3 "$ROOMS_CLI" rotate-invite "$ROOM" --json >/dev/null 2>&1 \
    || smoke_fail "leader rotate-invite should succeed"
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=403" "T3: a REVOKED (rotated-away) token is refused"
  smoke_assert_contains "$res" "mismatch" "T3: revoked token reads as a hash mismatch"
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_not_contains "$rows" "fred" "T3: NO pending row for a revoked-token join"
}

# ---------------------------------------------------------------------------
# T4: the raw token AND its hash never appear in any queue/task/audit/staged file
# ---------------------------------------------------------------------------
test_T4_no_token_or_hash_persisted_anywhere() {
  # After the positive path persisted a verified row, scan every persistence
  # surface for BOTH the raw token and its sha256 hash.
  [[ -n "$RAW_TOKEN" && -n "$TOKEN_HASH" ]] || smoke_fail "token/hash not set up"

  # 1) rooms.db — the row carries metadata only, NEVER the reusable hash.
  if python3 "$HELPER" db-contains "$BRIDGE_A2A_ROOMS_DB" "$RAW_TOKEN"; then
    smoke_fail "T4: raw token must NEVER appear in rooms.db"
  fi
  # The rooms.db stores invite_token_sha256 in the ROOMS table (that is correct
  # and 0600-scoped). The contract is that the hash must not leak into the
  # join-REQUEST row / audit / staged files. Assert the join_request row text
  # contains neither.
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$ROOM")"
  smoke_assert_not_contains "$rows" "$RAW_TOKEN" "T4: raw token not in a pending row"
  smoke_assert_not_contains "$rows" "$TOKEN_HASH" "T4: token HASH not in a pending row (bearer-equivalent)"
  # The P4.1 cross-node dedupe ledger (room_join_dedupe in rooms.db, codex r2)
  # stores sha256(WIRE BODY) + message_id + peer — NOT the token or its hash.
  local dledger
  dledger="$(python3 "$HELPER" dedupe-rows "$BRIDGE_A2A_ROOMS_DB")"
  smoke_assert_not_contains "$dledger" "$RAW_TOKEN" "T4: raw token not in the dedupe ledger"
  smoke_assert_not_contains "$dledger" "$TOKEN_HASH" "T4: token HASH not in the dedupe ledger"

  # 2) audit log — never the token or its hash.
  local audit="$BRIDGE_LOG_DIR/a2a-handoff.jsonl"
  if [[ -f "$audit" ]]; then
    if grep -qF "$RAW_TOKEN" "$audit"; then smoke_fail "T4: raw token leaked into the audit log"; fi
    if grep -qF "$TOKEN_HASH" "$audit"; then smoke_fail "T4: token hash leaked into the audit log"; fi
  fi

  # 3) inbox dedupe db (the queue-adjacent ledger) — never the token/hash.
  local inbox="$BRIDGE_STATE_DIR/handoff/inbox.db"
  if [[ -f "$inbox" ]]; then
    if python3 "$HELPER" db-contains "$inbox" "$RAW_TOKEN"; then smoke_fail "T4: raw token in inbox.db"; fi
    if python3 "$HELPER" db-contains "$inbox" "$TOKEN_HASH"; then smoke_fail "T4: token hash in inbox.db"; fi
  fi

  # 4) any staged file under the handoff/incoming tree — never the token/hash.
  if python3 "$HELPER" file-tree-contains "$BRIDGE_STATE_DIR/handoff" "$RAW_TOKEN"; then
    smoke_fail "T4: raw token found in a staged handoff file"
  fi
  if python3 "$HELPER" file-tree-contains "$BRIDGE_STATE_DIR/handoff" "$TOKEN_HASH"; then
    # NOTE: rooms.db is UNDER handoff/ and legitimately holds the ROOM hash in
    # the rooms table; the file-tree scan reads text, and the sqlite db is
    # binary so the hex may or may not surface. To keep this assertion precise
    # we only fail if the hash is in a STAGED .md/.json file, not the db blob.
    if python3 "$HELPER" file-tree-contains "$BRIDGE_STATE_DIR/handoff/incoming" "$TOKEN_HASH" 2>/dev/null; then
      smoke_fail "T4: token hash found in a staged incoming file"
    fi
  fi

  # 5) no queue task was created at all (no leader task carrying a token).
  if [[ -f "$BRIDGE_TASK_DB" ]]; then
    if python3 "$HELPER" db-contains "$BRIDGE_TASK_DB" "$RAW_TOKEN"; then smoke_fail "T4: raw token in tasks.db"; fi
    if python3 "$HELPER" db-contains "$BRIDGE_TASK_DB" "$TOKEN_HASH"; then smoke_fail "T4: token hash in tasks.db"; fi
  fi
}

# ---------------------------------------------------------------------------
# T5: malformed / duplicate join-request handled (no crash; dedupe)
# ---------------------------------------------------------------------------
test_T5a_malformed_body_refused_no_crash() {
  # Capture a valid signed request, then deliver MALFORMED bodies that are
  # LEGITIMATELY RE-SIGNED (resign:true) — so the test exercises the receiver's
  # body PARSER (downstream of the HMAC + dedupe gates), not the signature gate.
  # Each malformed delivery uses a UNIQUE message_id so it passes dedupe ("new")
  # and reaches the parser (the dedupe gate runs BEFORE parse by design).
  local freshout freshlink
  freshout="$(room_create_as helen 0)"
  freshlink="$(json_field invite_link "$freshout")"
  join_cross_node_as ivan -- "$freshlink" >/dev/null 2>&1 \
    || smoke_fail "capture a valid request to mutate"
  local res
  # not-JSON body.
  res="$(deliver '{"headers":{"X-AGB-Message-Id":"nodeB:malformed-1"},"body":"{not json","resign":true}')"
  smoke_assert_contains "$res" "status=422" "T5: a non-JSON body is a 422 (parser refused, no crash)"
  # codex P4.1 r1 regression: a REPLAY of the rejected malformed request must
  # STILL be 422 (no dedupe row was reserved for a reject), never 200.
  res="$(deliver '{"headers":{"X-AGB-Message-Id":"nodeB:malformed-1"},"body":"{not json","resign":true}')"
  smoke_assert_contains "$res" "status=422" "T5: a REPLAYED malformed body is STILL 422 (no idempotent-200 bypass)"
  # missing required fields.
  res="$(deliver '{"headers":{"X-AGB-Message-Id":"nodeB:malformed-2"},"body":"{\"protocol\":\"agent-bridge.a2a.room-join.v1\"}","resign":true}')"
  smoke_assert_contains "$res" "status=422" "T5: a missing-field body is a 422"
  # bad token-hash shape (not 64 hex) → 422 at the parser.
  res="$(deliver '{"headers":{"X-AGB-Message-Id":"nodeB:malformed-3"},"body":"{\"protocol\":\"agent-bridge.a2a.room-join.v1\",\"room_id\":\"r\",\"join_token_sha256\":\"xyz\",\"joiner_agent\":\"a\"}","resign":true}')"
  smoke_assert_contains "$res" "status=422" "T5: a malformed token-hash is a 422"
}

test_T5b_duplicate_idempotent() {
  # Capture one valid request; deliver it twice. Second is an idempotent dup.
  local out room link
  out="$(room_create_as jane 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  join_cross_node_as kara -- "$link" >/dev/null 2>&1 \
    || smoke_fail "capture a valid request for the dup test"
  local first second
  first="$(deliver)"
  smoke_assert_contains "$first" "status=200" "T5: first delivery is 200"
  second="$(deliver)"
  smoke_assert_contains "$second" "status=200" "T5: a duplicate (same id+body) is idempotent 200"
  smoke_assert_contains "$second" "\"duplicate\": true" "T5: the duplicate is flagged"
  # codex P4.1 r2 atomicity: an idempotent-200 duplicate MUST correspond to a
  # REAL pending row (dedupe row ⟺ pending row, committed atomically) — never a
  # bogus 200 with no row.
  local drows
  drows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$room")"
  smoke_assert_contains "$drows" "\"agent\": \"kara\"" \
    "T5 atomicity: the duplicate-200 corresponds to a REAL pending row (kara)"
  # Same id (the captured one), DIFFERENT but VALIDLY-SIGNED body → 409 conflict
  # (security event), still no crash. resign keeps the HMAC valid so the
  # conflict is detected at the dedupe ledger, not the signature gate.
  local hex64
  hex64="$(python3 -c "print('a'*64)")"
  local conflict
  conflict="$(deliver '{"body":"{\"protocol\":\"agent-bridge.a2a.room-join.v1\",\"room_id\":\"'"$room"'\",\"join_token_sha256\":\"'"$hex64"'\",\"joiner_agent\":\"kara\"}","resign":true}')"
  smoke_assert_contains "$conflict" "status=409" "T5: same id + different body is a 409 conflict"
}

# ---------------------------------------------------------------------------
# auth preamble teeth: a tampered signature / wrong source addr is refused
# ---------------------------------------------------------------------------
test_auth_preamble_unweakened() {
  local out room link
  out="$(room_create_as liam 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  join_cross_node_as mike -- "$link" >/dev/null 2>&1 \
    || smoke_fail "capture a valid request for the auth teeth"
  # Tampered signature → 401 (HMAC unweakened).
  local res
  res="$(deliver '{"headers":{"X-AGB-Signature":"v1=deadbeef"}}')"
  smoke_assert_contains "$res" "status=401" "auth: a bad signature is 401 (HMAC gate intact)"
  # Wrong source address → 403 (remote_addr gate intact).
  res="$(deliver '{"client_ip":"10.9.9.9"}')"
  smoke_assert_contains "$res" "status=403" "auth: a wrong source address is 403 (remote_addr gate intact)"
  # Unknown peer (nodeZ) under the DEFAULT-ON auto-join gate (#2024 B): the
  # bootstrap is now reachable, but the captured signature was computed for
  # nodeB's per-pair key, NOT nodeZ's derived key — so the HMAC check fails and
  # the request is refused with 401 (fail-closed). This is NOT an admit path:
  # the per-pair HMAC remains the boundary, and nothing is persisted.
  res="$(deliver '{"headers":{"X-AGB-Peer":"nodeZ"}}')"
  smoke_assert_contains "$res" "status=401" \
    "auth: an unknown peer with a mismatched signature is 401 under default-ON (HMAC gate intact, not an admit)"
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$room")"
  smoke_assert_not_contains "$rows" "nodeZ" \
    "auth: the unknown-peer HMAC failure writes NO pending row (fail-closed under default-ON)"
}

# ---------------------------------------------------------------------------
# not-leader-node: a node that does not lead the room records nothing
# ---------------------------------------------------------------------------
test_non_leader_node_refuses() {
  # Deliver a valid request to a receiver whose bridge_id is NOT the leader node.
  local out room link
  out="$(room_create_as nora 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  join_cross_node_as opal -- "$link" >/dev/null 2>&1 \
    || smoke_fail "capture a valid request"
  # A node-C config (bridge_id=nodeC) that still trusts nodeB as a peer, but the
  # room's leader_node is nodeA → 404 not-leader-node, nothing persisted.
  local cfg_c="$SMOKE_TMP_ROOT/handoff-C.json"
  python3 "$HELPER" make-config "$cfg_c" "nodeC" "$NODE_B" "$SECRET" "$ADDR" >/dev/null
  local res
  res="$(python3 "$HELPER" deliver-to-receiver "$SMOKE_REPO_ROOT" "$(cat "$cfg_c")" "$CAPTURE")"
  smoke_assert_contains "$res" "status=404" "a non-leader node refuses the join (404)"
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$room")"
  smoke_assert_not_contains "$rows" "opal" "a non-leader node persists NO pending row"
}

# ---------------------------------------------------------------------------
# upgraded P1 rooms.db: the read-only dedupe lookup tolerates a missing table
# (codex r3 #2) — the RW accept-open recreates it; the join still succeeds.
# ---------------------------------------------------------------------------
test_upgraded_db_missing_dedupe_table() {
  local out room link
  out="$(room_create_as petra 0)"
  room="$(json_field room_id "$out")"
  link="$(json_field invite_link "$out")"
  join_cross_node_as quinn -- "$link" >/dev/null 2>&1 \
    || smoke_fail "capture a valid request"
  # Simulate an UPGRADED P1 rooms.db whose RW migration has not yet recreated
  # the new table: DROP it, then deliver. The RO step-h lookup must treat the
  # missing table as 'new' (not a 500), and the RW accept-open must recreate it
  # before reserving → 200 pending + a real row.
  python3 "$HELPER" drop-dedupe-table "$BRIDGE_A2A_ROOMS_DB" >/dev/null
  local res
  res="$(deliver)"
  smoke_assert_contains "$res" "status=200" \
    "r3 #2: a join against an unmigrated P1 db (no dedupe table) still 200s (no 500)"
  local rows
  rows="$(python3 "$HELPER" pending-rows "$BRIDGE_A2A_ROOMS_DB" "$room")"
  smoke_assert_contains "$rows" "\"agent\": \"quinn\"" \
    "r3 #2: the accept-open recreated the dedupe table + persisted the pending row"
}

# ---------------------------------------------------------------------------
# concurrency: a message_id PK race is RECLASSIFIED to duplicate/conflict, never
# a 500 (codex r3 #1). Unit-drives the atomic helper's pre-check AND its
# IntegrityError catch branch.
# ---------------------------------------------------------------------------
test_atomic_race_reclassified_not_500() {
  local racedb="$SMOKE_TMP_ROOT/race.db"
  local out
  out="$(python3 "$HELPER" atomic-race-reclassify "$racedb" 2>&1)" \
    || smoke_fail "atomic-race helper must not raise: $out"
  smoke_assert_contains "$out" "precheck_same_body=duplicate" \
    "r3 #1: a pre-checked same-body race resolves to duplicate"
  smoke_assert_contains "$out" "precheck_diff_body=conflict" \
    "r3 #1: a pre-checked different-body race resolves to conflict"
  smoke_assert_contains "$out" "integrityerror_reclassified=duplicate" \
    "r3 #1: a PK IntegrityError (lost the INSERT race) is reclassified, NOT a 500"
}

# ---------------------------------------------------------------------------
# T6 (codex P4.1 Phase-4 BLOCKING): dedupe is scoped to the AUTHENTICATED peer.
#     A second authenticated peer (nodeC) reusing nodeB's message_id must NOT
#     consume or block nodeB's join id — composite (peer, message_id) PK. Same-
#     peer idempotency (same body) + conflict (different body) are preserved.
# ---------------------------------------------------------------------------
test_T6_cross_peer_dedupe_isolation() {
  local xdb="$SMOKE_TMP_ROOT/cross-peer.db"
  local out
  out="$(python3 "$HELPER" cross-peer-dedupe "$xdb" 2>&1)" \
    || smoke_fail "cross-peer-dedupe helper must not raise: $out"
  smoke_assert_contains "$out" "nodeB_reserve=reserved" \
    "nodeB reserves its own dedupe + pending row"
  smoke_assert_contains "$out" "nodeC_same_body_lookup=new" \
    "T6: nodeC reusing nodeB's message_id (SAME body) is NEW — not consumed (cross-peer isolation)"
  smoke_assert_contains "$out" "nodeC_diff_body_lookup=new" \
    "T6: nodeC reusing nodeB's message_id (DIFFERENT body) is NEW — no cross-peer 409"
  smoke_assert_contains "$out" "nodeB_same_body_lookup=duplicate" \
    "T6: nodeB same id+body stays idempotent (duplicate) — same-peer dedupe preserved"
  smoke_assert_contains "$out" "nodeB_diff_body_lookup=conflict" \
    "T6: nodeB same id+different body stays a conflict — same-peer dedupe preserved"
  smoke_assert_contains "$out" "nodeC_reserve=reserved" \
    "T6: nodeC independently reserves the SAME message_id (its own row)"
  smoke_assert_contains "$out" "dedupe_rows_for_shared_id=2" \
    "T6: two authenticated peers => two independent dedupe rows for one message_id"
  smoke_assert_contains "$out" "pending_rows_for_shared_id=2" \
    "T6: two authenticated peers => two independent pending rows"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "setup: room on node A + baseline cross-node join captured" test_setup_room_and_capture
smoke_run "positive: valid cross-node join persists a verified pending row" test_valid_cross_node_join_persists_pending
smoke_run "T1: hostile --from/BRIDGE_AGENT_ID/USER cannot change the joiner" test_T1_hostile_from_env_cannot_change_joiner
smoke_run "T2: a node-B process cannot join as a different B agent" test_T2_cannot_join_as_a_different_B_agent
smoke_run "T3a: an expired (TTL) token is refused — no pending row" test_T3a_expired_token_refused
smoke_run "T3b: a revoked (rotated) token is refused — no pending row" test_T3b_revoked_token_refused
smoke_run "T4: raw token AND hash never persisted in queue/audit/staged" test_T4_no_token_or_hash_persisted_anywhere
smoke_run "T5a: a malformed body is refused (422, no crash)" test_T5a_malformed_body_refused_no_crash
smoke_run "T5b: a duplicate join is idempotent; id-reuse is a 409" test_T5b_duplicate_idempotent
smoke_run "auth preamble unweakened (HMAC 401 / remote_addr 403 / unknown peer 401 under default-ON)" test_auth_preamble_unweakened
smoke_run "a non-leader node refuses + persists nothing" test_non_leader_node_refuses
smoke_run "r3 #2: unmigrated P1 db (missing dedupe table) still joins (no 500)" test_upgraded_db_missing_dedupe_table
smoke_run "r3 #1: a message_id PK race is reclassified (dup/conflict), not a 500" test_atomic_race_reclassified_not_500
smoke_run "T6: dedupe scoped to authenticated peer — one peer can't consume/block another's join id" test_T6_cross_peer_dedupe_isolation

smoke_log "passed"
