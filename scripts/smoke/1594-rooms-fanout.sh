#!/usr/bin/env bash
# scripts/smoke/1594-rooms-fanout.sh — A2A Rooms whole-room fan-out
# (`agent-bridge a2a send --room` / `room send` / `room talk --fanout`, #1594).
#
# The fan-out is the ergonomic surface over the EXISTING P4.3 room-talk
# machinery: one message to EVERY OTHER member of a room (self excluded), with
# same-node members delivered via the LOCAL queue (`bridge-task.sh create`) and
# remote members via the cross-node room-scoped A2A enqueue (node-link + HMAC +
# room epoch). Membership is proven from the sender's OWN local leader-MAC roster
# cache / authoritative rooms.db — never from the caller's flags. The receiver
# gate is UNCHANGED and still independently enforces membership on every remote
# hop; the SENDER-side membership check is an ADDITIVE gate.
#
# Both legs are stubbed via paired-flag test hooks (prod-inert, the same seam
# the P4.x smokes use) so no live socket / Tailscale / queue is touched:
#   - REMOTE leg → BRIDGE_ROOMS_TEST_POST_HOOK captures each signed enqueue POST;
#     one captured POST is replayed through the REAL `do_POST` receiver to prove
#     cross-node delivery AND the non-member-denied security case end to end.
#   - LOCAL leg  → BRIDGE_ROOMS_TEST_LOCAL_HOOK captures each would-be
#     bridge-task.sh create (and can simulate a failure for one target).
#
# THE REQUIRED TEETH:
#   T1  same-room fan-out is ALLOWED for a member sender; both legs fire.
#   T2  a NON-member sender cannot send to the room (denied + nothing leaves).
#   T3  the sender itself is EXCLUDED from recipients (no self-delivery).
#   T4  same-node members are delivered via the LOCAL queue leg.
#   T5  remote members are delivered via the cross-node room-scoped A2A leg, and
#       the REAL receiver accepts a delivered remote hop (200).
#   T6  a partial failure (one recipient fails) does NOT abort the rest, and is
#       reported per-recipient in the JSON summary (rc=2).
#   T7  NO regression: `room talk` (no --fanout) stays cross-node only (skips
#       same-node members); the 1:1 `a2a send --peer --to` surface is intact.
#   T8  security: the receiver-side membership gate still denies a remote hop
#       whose envelope sender is rewritten to a non-member (additive sender gate
#       does not weaken the fail-closed receiver gate).

set -euo pipefail

SMOKE_NAME="1594-rooms-fanout"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/1594-rooms-fanout-helper.py"
POST_HOOK="$SCRIPT_DIR/1594-rooms-fanout-post-hook.sh"
LOCAL_HOOK="$SCRIPT_DIR/1594-rooms-fanout-local-hook.sh"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"
A2A_CLI="$SMOKE_REPO_ROOT/bridge-a2a.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

NODE_A="nodeA"   # the SENDER's node (alice fans out)
NODE_B="nodeB"   # a REMOTE member node (bob)
NODE_C="nodeC"   # a second REMOTE member node (carol)
SECRET_B="test-pair-secret-bbbbbbbbbbbbbbbbbbbb"
SECRET_C="test-pair-secret-cccccccccccccccccccc"
ADDR="127.0.0.1"
ROOM="room-fanout-001"
EPOCH=7

# Roster: alice@A (leader/sender) + dave@A (LOCAL same-node member) + bob@B and
# carol@C (REMOTE members). The fan-out should reach dave via the local queue
# and bob+carol via room-scoped A2A — and NEVER alice herself.
MEMBERS_CSV="alice@${NODE_A}:leader,dave@${NODE_A}:member,bob@${NODE_B}:member,carol@${NODE_C}:member"

# Sender (node A) config: bridge_id=nodeA, peers nodeB + nodeC (the remote
# delivery targets).
CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"
python3 "$HELPER" make-config "$CFG_A" "$NODE_A" "$NODE_B" "$SECRET_B" "$ADDR" "bob" >/dev/null
# make-config writes a single-peer config; add the second peer (nodeC) so the
# fan-out can address carol too (helper subcommand, no inline heredoc).
python3 "$HELPER" add-peer "$CFG_A" "$NODE_C" "$SECRET_C" "$ADDR" "carol" >/dev/null

# Sender-side rooms.db (node A) — alice's own leader cache, so the fan-out can
# resolve the epoch + confirm alice is a member before sending.
SENDER_DB="$SMOKE_TMP_ROOT/sender-rooms.db"
python3 "$HELPER" seed-cache "$SENDER_DB" "$ROOM" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null

# Receiver (node B) config: bridge_id=nodeB, peer nodeA (the authenticated
# sender), allowlist permits bob (the room talk target).
CFG_B="$SMOKE_TMP_ROOT/handoff-B.json"
python3 "$HELPER" make-config "$CFG_B" "$NODE_B" "$NODE_A" "$SECRET_B" "$ADDR" "bob" >/dev/null
CFG_B_JSON="$(cat "$CFG_B")"

# Member-local receiver rooms.db (node B) — the leader-MAC cache the gate reads.
MEMBER_DB="$SMOKE_TMP_ROOT/member-rooms.db"
python3 "$HELPER" seed-cache "$MEMBER_DB" "$ROOM" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null

POST_CAPTURE="$SMOKE_TMP_ROOT/captured-remote.jsonl"
LOCAL_CAPTURE="$SMOKE_TMP_ROOT/captured-local.jsonl"

TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# fanout_as <agent> [local_fail_for] [extra args...] — run the fan-out as
# iso-user agent-bridge-<agent> on node A via `a2a send --room`, capturing every
# remote POST to $POST_CAPTURE and every local create to $LOCAL_CAPTURE. Echoes
# the JSON summary. Returns the CLI rc.
fanout_as() {
  local who="$1" fail_for="${2:-}"; shift 2 || shift $#
  : >"$POST_CAPTURE"; : >"$LOCAL_CAPTURE"
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
      "BRIDGE_A2A_ROOMS_DB=$SENDER_DB" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "BRIDGE_ROOMS_TEST_LOCAL_HOOK=$LOCAL_HOOK" \
      "POST_CAPTURE=$POST_CAPTURE" \
      "LOCAL_CAPTURE=$LOCAL_CAPTURE" \
      "LOCAL_FAIL_FOR=$fail_for" \
    python3 "$A2A_CLI" send --room "$ROOM" --json "$@"
}

deliver_remote() {
  # deliver_remote <line_idx> [overrides_json] — replay one captured remote POST
  # through the REAL receiver against $MEMBER_DB. NOTE: do NOT use ${2:-{}} for
  # the default — bash parses the nested braces and appends a stray '}' to a
  # provided value, corrupting the JSON arg. Use an explicit empty-test instead.
  local idx="$1" overrides="${2:-}"
  [[ -n "$overrides" ]] || overrides='{}'
  env "BRIDGE_A2A_ROOMS_DB=$MEMBER_DB" \
    python3 "$HELPER" deliver-remote-to-receiver "$SMOKE_REPO_ROOT" \
      "$CFG_B_JSON" "$POST_CAPTURE" "$idx" "$overrides"
}

# ---------------------------------------------------------------------------
# T1: a member sender fans out; BOTH legs fire (local dave + remote bob/carol).
# ---------------------------------------------------------------------------
test_T1_member_fanout_allowed() {
  local out rc
  set +e
  out="$(fanout_as alice "" --title "team note" --body "from alice")"
  rc=$?
  set -e
  [[ $rc -eq 0 ]] || smoke_fail "T1: a full fan-out with no failures must rc=0 (got $rc): $out"
  smoke_assert_contains "$out" "\"epoch\": $EPOCH" "T1: the fan-out stamps the sender's cached epoch"
  smoke_assert_contains "$out" "\"sender\": \"alice@$NODE_A\"" "T1: sender identity is OS-actor anchored"
  smoke_assert_contains "$out" "\"local\": true" "T1: the local leg was used (same-node member dave)"
  smoke_assert_contains "$out" "\"remote\": true" "T1: the remote leg was used (bob/carol)"
}

# ---------------------------------------------------------------------------
# T2: a NON-member sender cannot fan out — refused, nothing leaves either leg.
# ---------------------------------------------------------------------------
test_T2_non_member_denied() {
  local out rc
  set +e
  # mallory is NOT in the roster; even --as alice is ignored (OS actor wins).
  out="$(fanout_as mallory "" --title hi --body x --as alice 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || smoke_fail "T2: a non-member fan-out must FAIL (got rc=$rc): $out"
  smoke_assert_contains "$out" "is not a member" "T2: a non-member sender is refused (membership proven from the roster, not the flags)"
  local nlocal nremote
  nlocal="$(python3 "$HELPER" count-lines "$LOCAL_CAPTURE")"
  nremote="$(python3 "$HELPER" count-lines "$POST_CAPTURE")"
  smoke_assert_eq "0" "$nlocal" "T2: a denied fan-out enqueues NOTHING locally"
  smoke_assert_eq "0" "$nremote" "T2: a denied fan-out sends NOTHING remotely"
}

# ---------------------------------------------------------------------------
# T3: the sender is EXCLUDED from recipients (no self-delivery on either leg).
# ---------------------------------------------------------------------------
test_T3_self_excluded() {
  fanout_as alice "" --title t --body b >/dev/null
  # Local targets are only same-node members EXCEPT alice → only dave.
  local local_targets remote_targets
  local_targets="$(python3 "$HELPER" field-each "$LOCAL_CAPTURE" target_agent | sort | tr '\n' ',')"
  remote_targets="$(python3 "$HELPER" field-each "$POST_CAPTURE" body:target_agent | sort | tr '\n' ',')"
  smoke_assert_eq "dave," "$local_targets" "T3: the local leg targets only same-node dave (alice excluded)"
  smoke_assert_eq "bob,carol," "$remote_targets" "T3: the remote leg targets bob+carol (alice excluded)"
  case ",${local_targets}${remote_targets}" in
    *,alice,*|*",alice,") smoke_fail "T3: alice (the sender) must never be a recipient" ;;
  esac
}

# ---------------------------------------------------------------------------
# T4: same-node members are delivered via the LOCAL queue leg with room
# provenance (room id + epoch + from), through bridge-task.sh create.
# ---------------------------------------------------------------------------
test_T4_local_leg_delivery() {
  fanout_as alice "" --title "local hi" --body "local body" >/dev/null
  local n from room_in
  n="$(python3 "$HELPER" count-lines "$LOCAL_CAPTURE")"
  smoke_assert_eq "1" "$n" "T4: exactly one local-queue create (dave)"
  from="$(python3 "$HELPER" field-each "$LOCAL_CAPTURE" from)"
  smoke_assert_eq "room:$ROOM:alice" "$from" "T4: the local create is stamped with room fan-out provenance (--from room:<room>:<sender>)"
  room_in="$(python3 "$HELPER" field-each "$LOCAL_CAPTURE" room_id)"
  smoke_assert_eq "$ROOM" "$room_in" "T4: the local create carries the room id"
}

# ---------------------------------------------------------------------------
# T5: remote members are delivered via the cross-node room-scoped A2A leg, and
# the REAL receiver accepts a delivered remote hop (200, room-scoped, in queue).
# ---------------------------------------------------------------------------
test_T5_remote_leg_delivery() {
  fanout_as alice "" --title "remote hi" --body "remote body" >/dev/null
  local proto room_in epoch_in path_in
  proto="$(python3 "$HELPER" field-each "$POST_CAPTURE" header:X-AGB-Protocol | head -1)"
  smoke_assert_eq "a2a-enqueue-v1" "$proto" "T5: the remote leg routes over the normal enqueue protocol (no new endpoint)"
  path_in="$(python3 "$HELPER" field-each "$POST_CAPTURE" path | head -1)"
  smoke_assert_eq "/enqueue" "$path_in" "T5: the remote leg posts to the enqueue path"
  room_in="$(python3 "$HELPER" field-each "$POST_CAPTURE" body:room_id | head -1)"
  smoke_assert_eq "$ROOM" "$room_in" "T5: the remote envelope carries the room id"
  epoch_in="$(python3 "$HELPER" field-each "$POST_CAPTURE" body:room_epoch | head -1)"
  smoke_assert_eq "$EPOCH" "$epoch_in" "T5: the remote envelope carries the cached room epoch"

  # Replay the bob-targeted hop through the REAL receiver (CFG_B trusts nodeA +
  # allowlists bob). Pick the captured line whose target is bob (helper subcmd).
  local bob_idx res
  bob_idx="$(python3 "$HELPER" target-index "$POST_CAPTURE" bob)"
  [[ -n "$bob_idx" ]] || smoke_fail "T5: no captured remote hop targeted bob"
  res="$(deliver_remote "$bob_idx")"
  smoke_assert_contains "$res" "status=200" "T5: the REAL receiver accepts a delivered remote room hop (200)"
  smoke_assert_contains "$res" "delivered=True" "T5: the remote room message is DELIVERED into the queue"
}

# ---------------------------------------------------------------------------
# T6: a partial failure (one local recipient fails) does NOT abort the rest; it
# is reported per-recipient in the JSON, and the rc is 2 (non-zero so callers
# notice) while the OTHER legs still delivered.
# ---------------------------------------------------------------------------
test_T6_partial_failure_reported() {
  local out rc
  set +e
  out="$(fanout_as alice "dave" --title t --body b)"  # dave's local create fails
  rc=$?
  set -e
  [[ $rc -eq 2 ]] || smoke_fail "T6: a partial failure must rc=2 (got $rc): $out"
  smoke_assert_contains "$out" "\"failed\": [{" "T6: the failing recipient appears in failed[]"
  smoke_assert_contains "$out" "\"agent\": \"dave\"" "T6: the failed local recipient (dave) is named"
  smoke_assert_contains "$out" "\"leg\": \"local\"" "T6: the failure is tagged with its leg (local)"
  # The remote recipients still delivered despite the local failure.
  smoke_assert_contains "$out" "\"agent\": \"bob\"" "T6: bob still delivered despite dave's local failure"
  smoke_assert_contains "$out" "\"agent\": \"carol\"" "T6: carol still delivered despite dave's local failure"
}

# ---------------------------------------------------------------------------
# T7: NO regression. `room talk` (no --fanout) stays cross-node only (it skips
# same-node members), and the 1:1 `a2a send --peer --to` surface holds its
# guards: --peer and --room stay mutually exclusive, and a send that cannot
# resolve a peer (explicit or via #2025 whois auto-resolve) still fails closed.
# ---------------------------------------------------------------------------
test_T7_no_regression() {
  : >"$POST_CAPTURE"; : >"$LOCAL_CAPTURE"
  # `room talk` (no --fanout) → remote-only: bob+carol on the wire, NO local leg.
  env "${TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-alice" \
      "BRIDGE_A2A_CONFIG=$CFG_A" \
      "BRIDGE_A2A_ROOMS_DB=$SENDER_DB" \
      "BRIDGE_ROOMS_TEST_POST_HOOK=$POST_HOOK" \
      "BRIDGE_ROOMS_TEST_LOCAL_HOOK=$LOCAL_HOOK" \
      "POST_CAPTURE=$POST_CAPTURE" "LOCAL_CAPTURE=$LOCAL_CAPTURE" \
    python3 "$ROOMS_CLI" talk "$ROOM" --title t --body b --json >/dev/null
  local nlocal nremote
  nlocal="$(python3 "$HELPER" count-lines "$LOCAL_CAPTURE")"
  nremote="$(python3 "$HELPER" count-lines "$POST_CAPTURE")"
  smoke_assert_eq "0" "$nlocal" "T7: bare \`room talk\` does NOT use the local leg (back-compat: cross-node only)"
  smoke_assert_eq "2" "$nremote" "T7: bare \`room talk\` still reaches both remote members (bob+carol)"

  # 1:1 `a2a send --room` + `--peer` are mutually exclusive (surface intact).
  local out rc
  set +e
  out="$(python3 "$A2A_CLI" send --room "$ROOM" --peer "$NODE_B" --to bob --title t --body b 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || smoke_fail "T7: --room + --peer together must be rejected"
  smoke_assert_contains "$out" "only one of --peer" "T7: --peer and --room are mutually exclusive"

  # A 1:1 `a2a send --to` without --peer still fails closed (no silent send).
  # #2025/#2071 added a whois `--peer` auto-resolve: when --peer is omitted the
  # CLI tries to resolve --to's node from the shared A2A rooms registry instead
  # of erroring immediately. Here `bob` has no entry in the (unset) rooms
  # registry, so the auto-resolve finds no node and the send STILL fails closed —
  # the no-regression contract (rc != 0, nothing leaves) holds; only the operator
  # message changed from "--peer is required" to the auto-resolve guidance.
  set +e
  out="$(python3 "$A2A_CLI" send --to bob --title t --body b 2>&1)"
  rc=$?
  set -e
  [[ $rc -ne 0 ]] || smoke_fail "T7: a 1:1 send with no --peer and no resolvable node must fail closed"
  smoke_assert_contains "$out" "auto-resolve found no node" "T7: a 1:1 send with an unresolvable --to fails closed (no silent send)"
}

# ---------------------------------------------------------------------------
# T8: security — the receiver-side membership gate is UNCHANGED. A captured
# remote hop whose envelope sender is rewritten to a non-member (re-signed so it
# passes HMAC) is REJECTED by the receiver's fail-closed room gate. The additive
# sender-side gate does not weaken the receiver.
# ---------------------------------------------------------------------------
test_T8_receiver_gate_unweakened() {
  fanout_as alice "" --title t --body b >/dev/null
  # find bob's captured hop, rewrite the envelope sender.agent → mallory, re-sign
  # so the membership gate (not the HMAC gate) is what rejects it. Both via the
  # helper (no inline heredoc — footgun #11 hygiene).
  local bob_idx overrides res
  bob_idx="$(python3 "$HELPER" target-index "$POST_CAPTURE" bob)"
  [[ -n "$bob_idx" ]] || smoke_fail "T8: no captured remote hop targeted bob"
  overrides="$(python3 "$HELPER" nonmember-overrides "$POST_CAPTURE" "$bob_idx" mallory)"
  res="$(deliver_remote "$bob_idx" "$overrides")"
  smoke_assert_contains "$res" "status=403" "T8: the receiver gate rejects a non-member envelope sender (403)"
  smoke_assert_contains "$res" "sender_not_member" "T8: the refusal reason is sender_not_member (fail-closed gate intact)"
  smoke_assert_contains "$res" "delivered=False" "T8: a non-member remote hop is NEVER delivered"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "T1: same-room fan-out allowed for a member (both legs)" test_T1_member_fanout_allowed
smoke_run "T2: a NON-member sender cannot fan out (denied, nothing leaves)" test_T2_non_member_denied
smoke_run "T3: the sender is excluded from recipients (no self-delivery)" test_T3_self_excluded
smoke_run "T4: same-node members delivered via the LOCAL queue leg" test_T4_local_leg_delivery
smoke_run "T5: remote members delivered via the room-scoped A2A leg (receiver 200)" test_T5_remote_leg_delivery
smoke_run "T6: a partial failure is reported per-recipient, rest still delivered" test_T6_partial_failure_reported
smoke_run "T7: NO regression — room talk cross-node only + 1:1 send surface intact" test_T7_no_regression
smoke_run "T8: the receiver-side membership gate stays fail-closed (additive sender gate)" test_T8_receiver_gate_unweakened

smoke_log "passed"
