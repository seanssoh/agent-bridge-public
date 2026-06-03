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

# §14 R1 actor-auth: the trusted acting agent is derived from the process OS
# USERNAME (a passwd fact), NOT from --as/env or any roster probe. Leader-auth
# compares the process's OS username against the expected iso OS user for the
# room leader (default_os_user_slug). The ONLY test seam is the paired-flag
# BRIDGE_ROOMS_TEST_ISO_USER override (gated by BRIDGE_ROOMS_ALLOW_TEST_UID_MAP
# =1 AND BRIDGE_A2A_ALLOW_TEST_BIND=1) which lets the smoke simulate the
# process OS username; production sets NEITHER flag so it is never honored.
# room_cli_as <agent> runs as if the process OS user were agent-bridge-<agent>
# (a distinct iso UID), so one real uid can act as alice/bob/... in turn. Flags
# are set INLINE (never exported) so nothing leaks.
MY_UID="$(python3 -c 'import os; print(os.getuid())')"
# Paired test-seam flags, applied only by room_cli_as / the F1 teeth.
ROOMS_TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

room_cli() {
  # Default: NO test flags -> real pwd.getpwuid (non-iso on macOS) + no iso
  # users on host -> shared-advisory regime (honors best-effort id).
  python3 "$ROOMS_CLI" "$@"
}

room_cli_as() {
  # room_cli_as <agent> <args...> — run as if the process OS user were the iso
  # user agent-bridge-<agent> (iso-enforced regime). The un-spoofable OS-user
  # anchor recognizes us as that iso agent; leader-auth compares against the
  # room leader's expected OS user. Mirrors a real distinct iso UID.
  local who="$1"; shift
  env "${ROOMS_TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
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
  # alice's OS uid creates the room → leader is the uid-derived 'alice'.
  local out
  out="$(room_cli_as alice create --name team-a --json 2>/dev/null)"
  ROOM="$(json_field room_id "$out")"
  LINK="$(json_field invite_link "$out")"
  [[ -n "$ROOM" ]] || smoke_fail "create did not return a room_id"
  smoke_assert_eq "0" "$(json_field epoch "$out")" "new room starts at epoch 0"
  smoke_assert_contains "$out" '"leader": "alice@"' \
    "leader is the OS-uid-derived actor (alice), not a --as value"
  smoke_assert_contains "$LINK" "agbroom://join?room=$ROOM" "invite link carries room id"
  smoke_assert_contains "$LINK" "t=" "invite link carries a token"
}

test_join_pending_then_approve_bumps_epoch() {
  # bob's uid posts the join → request is recorded as bob (uid-derived).
  room_cli_as bob join "$LINK" >/dev/null 2>&1 \
    || smoke_fail "valid join should succeed"
  local showed
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  smoke_assert_contains "$showed" '"agent": "bob"' "bob appears as pending join"
  # alice's uid (the leader) approves → epoch 0 → 1 + member added.
  local approved epoch
  approved="$(room_cli_as alice approve "$ROOM" bob --json 2>/dev/null)"
  epoch="$(json_field epoch "$approved")"
  smoke_assert_eq "1" "$epoch" "approve bumps epoch 0 -> 1"
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  python3 "$HELPER" assert-member "$showed" bob \
    || smoke_fail "roster must include bob after approve"
  python3 "$HELPER" assert-no-pending "$showed" bob \
    || smoke_fail "bob should no longer be a pending request after approve"
}

test_leave_and_kick_bump_epoch_and_exclude() {
  # add a second member (carol) so we can kick one and leave another
  room_cli_as carol join "$LINK" >/dev/null 2>&1
  room_cli_as alice approve "$ROOM" carol --json >/dev/null 2>&1
  local before
  before="$(json_field epoch "$(room_cli show "$ROOM" --json 2>/dev/null)")"
  # bob (his own uid) leaves → epoch bump + roster excludes bob
  local after_leave
  after_leave="$(json_field epoch "$(room_cli_as bob leave "$ROOM" --json 2>/dev/null)")"
  python3 "$HELPER" assert-gt "$after_leave" "$before" \
    || smoke_fail "leave must bump epoch ($before -> $after_leave)"
  local showed
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  if python3 "$HELPER" assert-member "$showed" bob 2>/dev/null; then
    smoke_fail "roster must EXCLUDE bob after leave"
  fi
  # carol kicked by the leader → another epoch bump + roster excludes carol
  local after_kick
  after_kick="$(json_field epoch "$(room_cli_as alice kick "$ROOM" carol --json 2>/dev/null)")"
  python3 "$HELPER" assert-gt "$after_kick" "$after_leave" \
    || smoke_fail "kick must bump epoch again ($after_leave -> $after_kick)"
  showed="$(room_cli show "$ROOM" --json 2>/dev/null)"
  if python3 "$HELPER" assert-member "$showed" carol 2>/dev/null; then
    smoke_fail "roster must EXCLUDE carol after kick"
  fi
}

# ---------------------------------------------------------------------------
# TEETH — §14 R1 actor-auth (the F1 security contract)
# ---------------------------------------------------------------------------
test_teeth_iso_leader_auth_unspoofable() {
  # The exact codex F1 exploit: a non-leader iso agent passing --as <leader>.
  # The trusted actor is the process OS USERNAME (agent-bridge-mallory here);
  # leader-auth compares it to the leader's expected OS user (agent-bridge-
  # alice). --as alice must be IGNORED and approve/kick REJECTED.
  room_cli_as dave join "$LINK" >/dev/null 2>&1
  if env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-mallory" \
       python3 "$ROOMS_CLI" approve "$ROOM" dave --as alice >/dev/null 2>&1; then
    smoke_fail "TEETH F1: approve by iso user mallory must be REJECTED even with --as alice"
  fi
  if env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-mallory" \
       python3 "$ROOMS_CLI" kick "$ROOM" bob --as alice >/dev/null 2>&1; then
    smoke_fail "TEETH F1: kick by iso user mallory must be REJECTED even with --as alice"
  fi
  # Positive: the leader's OS user CAN approve (proves it is not a blanket deny).
  room_cli_as alice approve "$ROOM" dave >/dev/null 2>&1 \
    || smoke_fail "leader OS user approve must succeed"
}

test_teeth_no_roster_probe_on_security_path() {
  # The r5/r6 roster-injection class is structurally eliminated: leader-auth is
  # a PURE comparison of the process OS username vs default_os_user_slug(leader)
  # with NO roster lookup / probe / subprocess. Prove a hostile BRIDGE_HOME (an
  # agent-writable fake home that, under the OLD probe, could inject a forged
  # uid->leader row) has ZERO effect: the iso user 'mallory' with a hostile
  # BRIDGE_HOME still cannot approve as the leader 'alice'.
  local evil="$SMOKE_TMP_ROOT/evil-home2"
  mkdir -p "$evil"
  : >"$evil/agent-roster.sh"
  : >"$evil/agent-roster.local.sh"
  if env "${ROOMS_TEST_FLAGS[@]}" \
         "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-mallory" \
         "BRIDGE_HOME=$evil" "BRIDGE_ROSTER_FILE=$evil/agent-roster.sh" \
         "BRIDGE_BASH_BIN=/bin/false" \
       python3 "$ROOMS_CLI" approve "$ROOM" dave --as alice >/dev/null 2>&1; then
    smoke_fail "TEETH F1 r6: a hostile BRIDGE_HOME/roster/BASH_BIN must NOT let a non-leader iso user approve"
  fi
  # And resolve-regime is unaffected by the hostile env (still iso-enforced as
  # mallory, the OS user — NOT alice).
  local got
  got="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-mallory" \
             "BRIDGE_HOME=$evil" "BRIDGE_BASH_BIN=/bin/false" \
           python3 "$HELPER" resolve-regime 2>/dev/null)"
  smoke_assert_contains "$got" "regime=iso-enforced" \
    "iso OS user stays iso-enforced regardless of hostile env (no probe to break)"
  smoke_assert_contains "$got" "agent=mallory" \
    "TEETH F1 r6: actor is the OS-user slug (mallory), never a forged-roster leader"
}

test_teeth_env_controller_uid_not_trusted() {
  # BRIDGE_CONTROLLER_UID from env must NOT grant the controller regime. A
  # NON-iso, NON-controller process on an ISO host (test-host-has-iso=1) that
  # sets BRIDGE_CONTROLLER_UID=$(id -u) must still be UNRESOLVED (fail closed),
  # not controller. (env BRIDGE_CONTROLLER_UID is ignored; the controller is the
  # bridge-home owner / the gated test override pointed elsewhere.)
  if env "${ROOMS_TEST_FLAGS[@]}" \
         "BRIDGE_ROOMS_TEST_ISO_USER=" \
         "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
         "BRIDGE_ROOMS_TEST_CONTROLLER_UID=999998" \
         "BRIDGE_CONTROLLER_UID=${MY_UID}" \
       python3 "$ROOMS_CLI" approve "$ROOM" eve --as alice >/dev/null 2>&1; then
    smoke_fail "TEETH F1: env BRIDGE_CONTROLLER_UID must NOT grant the controller bypass"
  fi
}

test_teeth_non_iso_on_iso_host_fails_closed() {
  # On an ISO host, a stray NON-iso NON-controller process must FAIL CLOSED for
  # a leader-only action — it cannot fall to advisory (where --as is honored).
  local got
  got="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_ROOMS_TEST_ISO_USER=" \
             "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
             "BRIDGE_ROOMS_TEST_CONTROLLER_UID=999998" \
           python3 "$HELPER" resolve-regime 2>/dev/null)"
  smoke_assert_contains "$got" "regime=unresolved" \
    "TEETH F1: non-iso non-controller process on an iso host must be UNRESOLVED (fail closed)"
}

test_advisory_shared_mode_is_honest() {
  # GENUINE shared-mode: NOT an iso OS user, NOT the controller, AND no iso
  # users on the host -> advisory. A non-leader actor is WARNED, not
  # hard-blocked (design §14 R1 default).
  room_cli_as frank join "$LINK" >/dev/null 2>&1
  local err rc
  err="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_ROOMS_TEST_ISO_USER=" \
             "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=0" \
             "BRIDGE_ROOMS_TEST_CONTROLLER_UID=999998" \
           python3 "$ROOMS_CLI" approve "$ROOM" frank --as mallory 2>&1)"
  rc=$?
  smoke_assert_eq "0" "$rc" "shared-mode advisory approve is allowed (not hard-blocked)"
  smoke_assert_contains "$err" "advisory" \
    "shared-mode non-leader approve must emit the advisory WARNING (honest contract)"
}

test_teeth_wrong_token_hash_rejected() {
  if room_cli_as eve join "agbroom://join?room=$ROOM&t=DEFINITELY-WRONG-TOKEN" >/dev/null 2>&1; then
    smoke_fail "TEETH: join with a wrong token hash must be rejected"
  fi
}

test_teeth_cannot_kick_leader() {
  if room_cli_as alice kick "$ROOM" alice >/dev/null 2>&1; then
    smoke_fail "TEETH: the leader must not be kickable (room would lose control plane)"
  fi
}

test_teeth_leave_non_member_is_loud() {
  if room_cli_as nobodyhere leave "$ROOM" >/dev/null 2>&1; then
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
  rot="$(room_cli_as alice rotate-invite "$ROOM" --json 2>/dev/null)"
  newlink="$(json_field invite_link "$rot")"
  # old link join must now FAIL
  if room_cli_as frank join "$LINK" >/dev/null 2>&1; then
    smoke_fail "rotate-invite must invalidate the OLD token"
  fi
  # new link join must SUCCEED
  room_cli_as frank join "$newlink" >/dev/null 2>&1 \
    || smoke_fail "rotate-invite must mint a working NEW token"
  LINK="$newlink"
}

test_once_token_burns_after_one_approval() {
  local once oncelink
  once="$(room_cli_as alice invite "$ROOM" --once --json 2>/dev/null)"
  oncelink="$(json_field invite_link "$once")"
  room_cli_as grace join "$oncelink" >/dev/null 2>&1 \
    || smoke_fail "once-link first join should succeed"
  # leader approve burns the token
  local approved burned
  approved="$(room_cli_as alice approve "$ROOM" grace --json 2>/dev/null)"
  burned="$(json_field invite_burned "$approved")"
  smoke_assert_eq "True" "$burned" "--once token burns on the approval"
  # a second join with the burned link must FAIL
  if room_cli_as heidi join "$oncelink" >/dev/null 2>&1; then
    smoke_fail "TEETH: a burned --once token must reject subsequent joins"
  fi
}

# ---------------------------------------------------------------------------
# adopt-all: default room with every roster agent + roster-cache freshness
# ---------------------------------------------------------------------------
test_adopt_all() {
  # Seed a small roster so `agent-bridge agent list --json` (which adopt-all
  # consults) returns deterministic agents in this isolated home.
  python3 "$HELPER" write-roster "$BRIDGE_ROSTER_LOCAL_FILE" alpha beta gamma
  # Fresh rooms.db for a clean adopt-all assertion.
  local adopt_db="$BRIDGE_STATE_DIR/handoff/adopt-rooms.db"
  local out members
  out="$(BRIDGE_A2A_ROOMS_DB="$adopt_db" room_cli_as alpha adopt-all --name default --json 2>/dev/null)"
  members="$(python3 "$HELPER" members-csv "$out")"
  # alpha (leader) + beta + gamma all present
  for ag in alpha beta gamma; do
    smoke_assert_contains ",$members," ",$ag," "adopt-all includes roster agent $ag"
  done
  # F2: the PERSISTED room_roster_cache row must be fresh — epoch ==
  # rooms.epoch AND members == the full set (NOT just the leader). codex
  # proved adopt-all left cache_epoch=0, cache_members=[leader] before the fix.
  local room_id
  room_id="$(json_field room_id "$out")"
  python3 "$HELPER" assert-cache-fresh "$adopt_db" "$room_id" \
    || smoke_fail "F2: adopt-all must leave room_roster_cache fresh (epoch + full members)"
}

# ---------------------------------------------------------------------------
# F2: every epoch-bumping mutation persists a fresh room_roster_cache row
# ---------------------------------------------------------------------------
test_roster_cache_fresh_after_every_mutation() {
  # The lifecycle room ($ROOM) has been through create/approve/leave/kick.
  # Assert its persisted cache row matches rooms.epoch + the current members
  # — proving bump_epoch centralizes the cache write so no verb leaves it
  # stale (codex F2). assert-cache-fresh reads the actual SQLite row.
  python3 "$HELPER" assert-cache-fresh "$BRIDGE_A2A_ROOMS_DB" "$ROOM" \
    || smoke_fail "F2: room_roster_cache must be fresh after the lifecycle mutations"
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
smoke_run "create (epoch 0, OS-uid-derived leader, invite link once)" test_create
smoke_run "join pending → approve bumps epoch + adds member" test_join_pending_then_approve_bumps_epoch
smoke_run "leave/kick bump epoch + exclude from roster" test_leave_and_kick_bump_epoch_and_exclude
smoke_run "TEETH F1: iso leader-auth unspoofable (--as <leader> ignored)" test_teeth_iso_leader_auth_unspoofable
smoke_run "TEETH F1: no roster-probe on the security path (hostile env inert)" test_teeth_no_roster_probe_on_security_path
smoke_run "TEETH F1: env BRIDGE_CONTROLLER_UID is NOT trusted" test_teeth_env_controller_uid_not_trusted
smoke_run "TEETH F1: non-iso process on an iso host fails closed" test_teeth_non_iso_on_iso_host_fails_closed
smoke_run "shared-mode leader-auth is advisory + honest (warns, not blocks)" test_advisory_shared_mode_is_honest
smoke_run "TEETH: wrong token-hash rejected" test_teeth_wrong_token_hash_rejected
smoke_run "TEETH: leader cannot be kicked" test_teeth_cannot_kick_leader
smoke_run "TEETH: leave of a non-member is loud" test_teeth_leave_non_member_is_loud
smoke_run "invite token stored as sha256 only (raw never in db)" test_invite_token_sha256_only
smoke_run "rotate-invite invalidates the old token" test_rotate_invalidates_old_token
smoke_run "--once token burns after one approval" test_once_token_burns_after_one_approval
smoke_run "adopt-all creates a room with every roster agent + fresh cache" test_adopt_all
smoke_run "F2: roster-cache fresh after every epoch-bumping mutation" test_roster_cache_fresh_after_every_mutation
smoke_run "envelope contract round-trip + v1 back-compat" test_envelope_contract
smoke_run "receiver seam fail-closed contract" test_receiver_seam
smoke_run "rooms.db mode 0600" test_db_mode_0600

smoke_log "passed"
