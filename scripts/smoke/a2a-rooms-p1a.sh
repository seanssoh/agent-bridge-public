#!/usr/bin/env bash
# scripts/smoke/a2a-rooms-p1a.sh — A2A rooms control plane (P1a) smoke.
#
# Exercises the single-node rooms control plane + the FROZEN schema/envelope/
# receiver-seam contract (design docs/design/a2a-rooms-design.md §6, §14
# R2/R6). Covers, with teeth:
#   - lifecycle: create → join(pending) → approve(member + epoch++) → roster
#     shows the member → leave/kick(removed + epoch++) → roster excludes
#   - TEETH: approve without leader-auth rejected; wrong token-hash rejected;
#     leader cannot be kicked; leave of a non-member is loud
#   - invite token: stored as sha256 ONLY (raw never in the db dump);
#     rotate-invite invalidates the old token; --once burns after one approval
#   - adopt-all: a default room containing every roster agent
#   - envelope contract: build/parse round-trip with room_id+room_epoch AND
#     v1 (no room fields) back-compat
#   - receiver seam: room_scoped_check fail-closed contract (non-room pass;
#     room-scoped member ok; non-member / unknown-room / no-db deny)
#   - rooms.db hygiene: mode 0600; absent-db reads degrade gracefully

set -euo pipefail

SMOKE_NAME="a2a-rooms-p1a"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-rooms-p1a-helper.py"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

# Isolated bridge home so the smoke never touches live state.
smoke_setup_bridge_home "$SMOKE_NAME"

# Pin the rooms.db + a2a config under the isolated root. We deliberately do
# NOT create a handoff.local.json so local_node() returns '' (single-node
# P1a default) — the lifecycle does not depend on a node id.
export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
unset BRIDGE_A2A_CONFIG || true

room_cli() {
  python3 "$ROOMS_CLI" "$@"
}

json_field() {
  # json_field <key> <json> — extract a top-level string/int field.
  python3 "$HELPER" json-field "$1" "$2"
}

# ---------------------------------------------------------------------------
# absent-db reads degrade gracefully (before any room exists)
# ---------------------------------------------------------------------------
test_absent_db_reads_degrade() {
  local out
  out="$(room_cli list --json 2>/dev/null)"
  smoke_assert_eq "[]" "$out" "list on absent db returns empty array"
  # show on a missing room errors clearly (non-zero), not a traceback.
  if room_cli show room-nope >/dev/null 2>&1; then
    smoke_fail "show on absent db should fail, not succeed"
  fi
  # acl defaults to off with no db.
  out="$(room_cli acl --json 2>/dev/null)"
  smoke_assert_contains "$out" '"rooms_acl": "off"' "acl default off (no db)"
}

# ---------------------------------------------------------------------------
# lifecycle: create → join → approve(epoch++) → roster → leave/kick(epoch++)
# ---------------------------------------------------------------------------
ROOM=""
LINK=""

test_create() {
  local out
  out="$(room_cli create --name team-a --as alice --json 2>/dev/null)"
  ROOM="$(json_field room_id "$out")"
  LINK="$(json_field invite_link "$out")"
  [[ -n "$ROOM" ]] || smoke_fail "create did not return a room_id"
  smoke_assert_eq "0" "$(json_field epoch "$out")" "new room starts at epoch 0"
  smoke_assert_contains "$LINK" "agbroom://join?room=$ROOM" "invite link carries room id"
  smoke_assert_contains "$LINK" "t=" "invite link carries a token"
}

test_join_pending_then_approve_bumps_epoch() {
  room_cli join "$LINK" --as bob >/dev/null 2>&1 \
    || smoke_fail "valid join should succeed"
  # pending shows in `show`
  local showed
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  smoke_assert_contains "$showed" '"agent": "bob"' "bob appears as pending join"
  # approve as leader → epoch 0 → 1 + member added
  local approved epoch
  approved="$(room_cli approve "$ROOM" bob --as alice --json 2>/dev/null)"
  epoch="$(json_field epoch "$approved")"
  smoke_assert_eq "1" "$epoch" "approve bumps epoch 0 -> 1"
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  python3 "$HELPER" assert-member "$showed" bob \
    || smoke_fail "roster must include bob after approve"
  # pending cleared
  python3 "$HELPER" assert-no-pending "$showed" bob \
    || smoke_fail "bob should no longer be a pending request after approve"
}

test_leave_and_kick_bump_epoch_and_exclude() {
  # add a second member (carol) so we can kick one and leave another
  room_cli join "$LINK" --as carol >/dev/null 2>&1
  room_cli approve "$ROOM" carol --as alice --json >/dev/null 2>&1
  local before
  before="$(json_field epoch "$(room_cli show "$ROOM" --json 2>/dev/null)")"
  # bob leaves → epoch bump + roster excludes bob
  local after_leave
  after_leave="$(json_field epoch "$(room_cli leave "$ROOM" --as bob --json 2>/dev/null)")"
  python3 "$HELPER" assert-gt "$after_leave" "$before" \
    || smoke_fail "leave must bump epoch ($before -> $after_leave)"
  local showed
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  if python3 "$HELPER" assert-member "$showed" bob 2>/dev/null; then
    smoke_fail "roster must EXCLUDE bob after leave"
  fi
  # carol kicked → another epoch bump + roster excludes carol
  local after_kick
  after_kick="$(json_field epoch "$(room_cli kick "$ROOM" carol --as alice --json 2>/dev/null)")"
  python3 "$HELPER" assert-gt "$after_kick" "$after_leave" \
    || smoke_fail "kick must bump epoch again ($after_leave -> $after_kick)"
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  if python3 "$HELPER" assert-member "$showed" carol 2>/dev/null; then
    smoke_fail "roster must EXCLUDE carol after kick"
  fi
}

# ---------------------------------------------------------------------------
# TEETH
# ---------------------------------------------------------------------------
test_teeth_approve_without_leader_auth_rejected() {
  room_cli join "$LINK" --as dave >/dev/null 2>&1
  if room_cli approve "$ROOM" dave --as mallory >/dev/null 2>&1; then
    smoke_fail "TEETH: approve by a non-leader must be rejected"
  fi
  # the leader CAN approve
  room_cli approve "$ROOM" dave --as alice >/dev/null 2>&1 \
    || smoke_fail "leader approve should succeed"
}

test_teeth_wrong_token_hash_rejected() {
  if room_cli join "agbroom://join?room=$ROOM&t=DEFINITELY-WRONG-TOKEN" --as eve >/dev/null 2>&1; then
    smoke_fail "TEETH: join with a wrong token hash must be rejected"
  fi
}

test_teeth_cannot_kick_leader() {
  if room_cli kick "$ROOM" alice --as alice >/dev/null 2>&1; then
    smoke_fail "TEETH: the leader must not be kickable (room would lose control plane)"
  fi
}

test_teeth_leave_non_member_is_loud() {
  if room_cli leave "$ROOM" --as nobody-here >/dev/null 2>&1; then
    smoke_fail "TEETH: leave of a non-member must fail loud, not silently bump epoch"
  fi
}

# ---------------------------------------------------------------------------
# invite token: sha256-only, rotate invalidates, --once burns
# ---------------------------------------------------------------------------
test_invite_token_sha256_only() {
  # the raw token from the original link must NOT be in the db dump
  local raw
  raw="$(python3 "$HELPER" token-from-link "$LINK")"
  if python3 "$HELPER" db-contains-token "$BRIDGE_A2A_ROOMS_DB" "$raw"; then
    smoke_fail "raw invite token must NEVER be persisted in rooms.db"
  fi
}

test_rotate_invalidates_old_token() {
  local rot newlink
  rot="$(room_cli rotate-invite "$ROOM" --as alice --json 2>/dev/null)"
  newlink="$(json_field invite_link "$rot")"
  # old link join must now FAIL
  if room_cli join "$LINK" --as frank >/dev/null 2>&1; then
    smoke_fail "rotate-invite must invalidate the OLD token"
  fi
  # new link join must SUCCEED
  room_cli join "$newlink" --as frank >/dev/null 2>&1 \
    || smoke_fail "rotate-invite must mint a working NEW token"
  LINK="$newlink"
}

test_once_token_burns_after_one_approval() {
  local once oncelink
  once="$(room_cli invite "$ROOM" --once --as alice --json 2>/dev/null)"
  oncelink="$(json_field invite_link "$once")"
  room_cli join "$oncelink" --as grace >/dev/null 2>&1 \
    || smoke_fail "once-link first join should succeed"
  # approve burns the token
  local approved burned
  approved="$(room_cli approve "$ROOM" grace --as alice --json 2>/dev/null)"
  burned="$(json_field invite_burned "$approved")"
  smoke_assert_eq "True" "$burned" "--once token burns on the approval"
  # a second join with the burned link must FAIL
  if room_cli join "$oncelink" --as heidi >/dev/null 2>&1; then
    smoke_fail "TEETH: a burned --once token must reject subsequent joins"
  fi
}

# ---------------------------------------------------------------------------
# adopt-all: default room with every roster agent
# ---------------------------------------------------------------------------
test_adopt_all() {
  # Seed a small roster so `agent-bridge list` (which adopt-all consults)
  # returns deterministic agents in this isolated home.
  python3 "$HELPER" write-roster "$BRIDGE_ROSTER_LOCAL_FILE" alpha beta gamma
  # Fresh rooms.db for a clean adopt-all assertion.
  local adopt_db="$BRIDGE_STATE_DIR/handoff/adopt-rooms.db"
  local out members
  out="$(BRIDGE_A2A_ROOMS_DB="$adopt_db" room_cli adopt-all --name default --as alpha --json 2>/dev/null)"
  members="$(python3 "$HELPER" members-csv "$out")"
  # alpha (leader) + beta + gamma all present
  for ag in alpha beta gamma; do
    smoke_assert_contains ",$members," ",$ag," "adopt-all includes roster agent $ag"
  done
}

# ---------------------------------------------------------------------------
# envelope contract + receiver seam (delegated to the helper for direct
# python assertions against the modules)
# ---------------------------------------------------------------------------
test_envelope_contract() {
  python3 "$HELPER" envelope-contract \
    || smoke_fail "envelope build/parse round-trip + v1 back-compat must hold"
}

test_receiver_seam() {
  python3 "$HELPER" receiver-seam "$SMOKE_REPO_ROOT" \
    || smoke_fail "room_scoped_check fail-closed contract must hold"
}

# ---------------------------------------------------------------------------
# rooms.db hygiene: 0600
# ---------------------------------------------------------------------------
test_db_mode_0600() {
  smoke_assert_file_exists "$BRIDGE_A2A_ROOMS_DB" "rooms.db created"
  local mode
  mode="$(python3 "$HELPER" file-mode "$BRIDGE_A2A_ROOMS_DB")"
  smoke_assert_eq "600" "$mode" "rooms.db must be mode 0600 (carries token hashes + membership)"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "absent-db reads degrade gracefully" test_absent_db_reads_degrade
smoke_run "create (epoch 0, invite link once)" test_create
smoke_run "join pending → approve bumps epoch + adds member" test_join_pending_then_approve_bumps_epoch
smoke_run "leave/kick bump epoch + exclude from roster" test_leave_and_kick_bump_epoch_and_exclude
smoke_run "TEETH: approve without leader-auth rejected" test_teeth_approve_without_leader_auth_rejected
smoke_run "TEETH: wrong token-hash rejected" test_teeth_wrong_token_hash_rejected
smoke_run "TEETH: leader cannot be kicked" test_teeth_cannot_kick_leader
smoke_run "TEETH: leave of a non-member is loud" test_teeth_leave_non_member_is_loud
smoke_run "invite token stored as sha256 only (raw never in db)" test_invite_token_sha256_only
smoke_run "rotate-invite invalidates the old token" test_rotate_invalidates_old_token
smoke_run "--once token burns after one approval" test_once_token_burns_after_one_approval
smoke_run "adopt-all creates a room with every roster agent" test_adopt_all
smoke_run "envelope contract round-trip + v1 back-compat" test_envelope_contract
smoke_run "receiver seam fail-closed contract" test_receiver_seam
smoke_run "rooms.db mode 0600" test_db_mode_0600

smoke_log "passed"
