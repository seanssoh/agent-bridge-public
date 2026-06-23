#!/usr/bin/env bash
# scripts/smoke/2079-routing-authz.sh — #2079 A2A cross-server routing authz.
#
# Proves the operator-mandated symmetric admin↔admin cross-node room-delivery
# rule: if EITHER endpoint is the configured bridge-admin of its node, the
# delivery is allowed ONLY when BOTH endpoints are configured admins. Non-admin
# room traffic is unchanged; 1:1 `a2a send` is unchanged; same-node/local
# delivery is unchanged. The admin signal is a TRI-STATE `bridge_admin` bit
# derived from each node's CONFIGURED admin id (NOT name=='patch'), materialized
# into the leader-signed roster + member cache, fail-closing admin-involved
# cross-node traffic when the metadata is unknown.
#
# Enforcement is RECEIVER-side (post-HMAC) at room_scoped_check + the leader
# relay resolver (_relay_resolve), over the VERIFIED roster/cache, NEVER an
# envelope claim. Every admin-authz reject collapses to a SINGLE generic 403
# (`room delivery forbidden`) — the precise reason is AUDIT-ONLY, no oracle.
#
# THE 10 MAKE-OR-BREAK TEETH (each mutation-proven in the helper, both allow AND
# deny directions asserted; flipping the predicate, dropping the local-recompute
# overlay, or defaulting the tri-state to non-admin make them FAIL):
#   T1  non-admin@B -> admin@A room send REJECTED (+ the receiver seam collapses
#       to the generic 403, reason is audit-only — no oracle).
#   T2  admin@B -> admin@A ALLOWED.
#   T3  admin@B -> non-admin@A REJECTED.
#   T4  non-admin@B -> non-admin@A ALLOWED.
#   T5  bare `--to patch` (patch on A AND B) REFUSED locally before any
#       queue/POST even when a local patch exists (real cmd_talk, no capture).
#   T6  intra-server admin -> local native agent ALLOWED (cross-node gate not
#       engaged for a same-node author).
#   T7  renamed admins (ops@B -> maint@A) ALLOWED; a literal `patch` without
#       configured-admin status is NOT privileged.
#   T8  missing/old admin metadata FAIL-CLOSES admin-involved cross-node, NOT
#       non-admin (the tri-state UNKNOWN fail-closed only for the admin leg).
#   T9  leader-relay path applies the SAME allow/deny over the AUTHORITATIVE
#       room_members, no distinct receiver reasons (generic refusal).
#   T10 1:1 `cmd_send --peer/--to` (and the non-room receiver path) UNCHANGED.
#   + an end-to-end join->approve->roster admin-bit roundtrip (the node-attested
#     bit survives the deferred-approval chain).
#
# ISOLATION: an isolated BRIDGE_HOME (smoke_setup_bridge_home), all rooms.db
# under it (BRIDGE_A2A_ROOMS_DB), the paired test-bind flags. NEVER ticks the
# live runtime; NEVER sets BRIDGE_ALLOW_FOREIGN_CHECKOUT.

set -euo pipefail

SMOKE_NAME="2079-routing-authz"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/2079-routing-authz-helper.py"
P43_HELPER="$SCRIPT_DIR/rooms-p4-3-room-talk-helper.py"
P43_POST_HOOK="$SCRIPT_DIR/rooms-p4-3-post-hook.sh"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"

# ---------------------------------------------------------------------------
# Part 1 — the 10 (+1) predicate/seam teeth, in-process against the real modules.
# The helper anchors its temp dbs under BRIDGE_HOME and sets the test-bind flag
# itself for its in-process opens (it never reaches a live tree).
# ---------------------------------------------------------------------------
smoke_log "setup/act/assert: the 10 routing-authz teeth (predicate + receiver/relay seams, mutation-proven)"
AUTHZ_OUT="$(BRIDGE_A2A_ALLOW_TEST_BIND=1 python3 "$HELPER" 2>&1)" || true
printf '%s\n' "$AUTHZ_OUT"
smoke_assert_contains "$AUTHZ_OUT" "OVERALL PASS" \
  "the in-process routing-authz teeth all pass"
for t in t1_nonadmin_to_admin_rejected t2_admin_to_admin_allowed \
         t3_admin_to_nonadmin_rejected t4_nonadmin_to_nonadmin_allowed \
         t6_intra_server_admin_to_local_allowed \
         t7_renamed_admins_allowed_literal_patch_not_privileged \
         t8_missing_metadata_failcloses_admin_not_nonadmin \
         t9_leader_relay_same_decision \
         t9b_relay_admin_authz_reaches_generic_403 t10_1to1_send_unchanged \
         extra_join_to_membership_admin_roundtrip; do
  smoke_assert_contains "$AUTHZ_OUT" "RESULT $t PASS" "tooth $t green"
done
smoke_log "ok: the 10 routing-authz teeth (predicate + receiver/relay seams, mutation-proven)"

# ---------------------------------------------------------------------------
# Part 2 — T5: the REAL sender-side UX guard refuses a bare ambiguous --to
# BEFORE any POST/local queue, even when a local member of that name exists.
# ---------------------------------------------------------------------------
smoke_log "setup/act/assert: T5: bare --to <name> matching >1 node is refused locally before any POST"

NODE_A="nodeA"
NODE_B="nodeB"
SECRET="test-pair-secret-bbbbbbbbbbbbbbbbbbbb"
ADDR="127.0.0.1"
ROOM="route-ambig-001"
EPOCH=2
# `patch` is a member on BOTH nodeA (the sender's own node) and nodeB → a bare
# `--to patch` is ambiguous. alice is the sender (leader on nodeA).
MEMBERS_CSV="alice@${NODE_A}:leader,patch@${NODE_A}:member,patch@${NODE_B}:member"

CFG_A="$SMOKE_TMP_ROOT/handoff-A.json"
python3 "$P43_HELPER" make-config "$CFG_A" "$NODE_A" "$NODE_B" "$SECRET" "$ADDR" "patch" >/dev/null
# The sender rooms.db + capture live UNDER BRIDGE_HOME so the test-bind guard
# (BRIDGE_A2A_ALLOW_TEST_BIND=1, set in TEST_FLAGS) is satisfied.
SENDER_DB="$BRIDGE_STATE_DIR/handoff/sender-rooms.db"
python3 "$P43_HELPER" seed-cache "$SENDER_DB" "$ROOM" "$EPOCH" "$NODE_A" "$MEMBERS_CSV" >/dev/null

CAPTURE="$BRIDGE_STATE_DIR/handoff/captured-ambig.json"
: >"$CAPTURE" || true

TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# Run `room talk --to patch` (bare name, ambiguous) as alice; capture stderr.
set +e
AMBIG_ERR="$(env "${TEST_FLAGS[@]}" \
    "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-alice" \
    "BRIDGE_A2A_CONFIG=$CFG_A" \
    "BRIDGE_A2A_ROOMS_DB=$SENDER_DB" \
    "BRIDGE_ROOMS_TEST_POST_HOOK=$P43_POST_HOOK" \
    "CAPTURE_FILE=$CAPTURE" \
  python3 "$ROOMS_CLI" talk "$ROOM" --to patch --title t --body b 2>&1 1>/dev/null)"
AMBIG_RC=$?
set -e
smoke_assert_contains "$AMBIG_ERR" "ambiguous_room_target" \
  "T5: a bare ambiguous --to is refused with ambiguous_room_target"
smoke_assert_contains "$AMBIG_ERR" "use NAME@NODE" \
  "T5: the refusal tells the operator to qualify the recipient"
[[ "$AMBIG_RC" -ne 0 ]] || smoke_fail "T5: the ambiguous send should exit non-zero (got rc=$AMBIG_RC)"
# CRITICAL: NO POST was attempted (the capture file is still empty) — the guard
# fires BEFORE any network/queue leg, so no forbidden admin leg can sneak out.
if [[ -s "$CAPTURE" ]]; then
  smoke_fail "T5: a POST was captured for an ambiguous --to — the guard must refuse BEFORE any POST"
fi
smoke_log "ok: T5: bare --to <name> matching >1 node is refused locally before any POST"

# A node-QUALIFIED --to patch@nodeB is NOT ambiguous → it resolves (and posts).
smoke_log "setup/act/assert: T5b: a node-qualified --to NAME@NODE is NOT ambiguous (resolves + posts)"
: >"$CAPTURE" || true
QUAL_OUT="$(env "${TEST_FLAGS[@]}" \
    "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-alice" \
    "BRIDGE_A2A_CONFIG=$CFG_A" \
    "BRIDGE_A2A_ROOMS_DB=$SENDER_DB" \
    "BRIDGE_ROOMS_TEST_POST_HOOK=$P43_POST_HOOK" \
    "CAPTURE_FILE=$CAPTURE" \
  python3 "$ROOMS_CLI" talk "$ROOM" --to "patch@$NODE_B" --title t --body b --json 2>/dev/null)" || true
smoke_assert_file_exists "$CAPTURE" "T5b: a node-qualified --to posts (capture written)"
TARGET_NODE_IN="$(python3 "$P43_HELPER" captured-field "$CAPTURE" "body:target_agent" 2>/dev/null || echo "")"
smoke_assert_eq "patch" "$TARGET_NODE_IN" "T5b: the qualified send targets patch on the named node"
smoke_log "ok: T5b: a node-qualified --to NAME@NODE is NOT ambiguous (resolves + posts)"

smoke_log "ALL 2079 routing-authz teeth PASS"
