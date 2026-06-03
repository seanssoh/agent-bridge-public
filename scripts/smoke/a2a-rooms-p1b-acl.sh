#!/usr/bin/env bash
# scripts/smoke/a2a-rooms-p1b-acl.sh — A2A rooms P1b internal-queue ACL smoke.
#
# Exercises the P1b ACL ENFORCEMENT on the durable inter-agent queue
# (design docs/design/a2a-rooms-design.md §7 / §14 R1), with TEETH:
#   - default-off NO-OP: rooms_acl=off -> a cross-room create is ALLOWED
#     exactly as today (proves ZERO behavior change for the beta default).
#   - enforce same-room: sender + recipient share a room -> ALLOWED.
#   - enforce cross-room: no shared room -> DENIED (fail-closed, audited reason).
#   - SPOOF teeth (the critical one): under enforce, an OS actor A passing
#     --from B (B shares a room with R, A does not) is decided as A -> DENIED.
#     The client-supplied --from/BRIDGE_AGENT_ID does NOT grant B's membership.
#     Tested at BOTH real create paths: the iso gateway (SO_PEERCRED peer) AND
#     the direct cmd_create path (resolve_os_actor ignores --from under iso).
#   - fail-closed: enforce + un-establishable OS actor -> DENY.
#   - controller/daemon exemption: an actor in the CONTROLLER regime -> ALLOW
#     (operator/daemon/cron/receiver run as the controller UID — non-spoofable).
#   - self-message: actor == target -> ALLOW.
#   - shared-mode advisory: documented audit/warn, NO hard block.
#   - adopt-all -> enforce: every roster agent shares the default room -> all
#     allowed; controller/daemon traffic still flows. Strands nobody.
#   - acl-flip is controller-gated: a managed iso agent cannot flip rooms_acl;
#     enforce with NO rooms is a loud operator error, not a silent lockout.
#
# The actor-auth test seam is the SAME paired-flag pattern P1a established
# (BRIDGE_ROOMS_TEST_ISO_USER, gated by BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1 AND
# BRIDGE_A2A_ALLOW_TEST_BIND=1). Production sets NEITHER flag so it is never
# honored — the gate falls through to the real pwd.getpwuid OS facts.

set -euo pipefail

SMOKE_NAME="a2a-rooms-p1b-acl"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-rooms-p1b-acl-helper.py"
P1A_HELPER="$SCRIPT_DIR/a2a-rooms-p1a-helper.py"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"
QUEUE_CLI="$SMOKE_REPO_ROOT/bridge-queue.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# Pin rooms.db + tasks.db under the isolated root; single-node (no a2a config).
export BRIDGE_A2A_ROOMS_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
export BRIDGE_TASK_DB="$BRIDGE_STATE_DIR/tasks.db"
mkdir -p "$BRIDGE_STATE_DIR/handoff"
unset BRIDGE_A2A_CONFIG || true

# Paired test-seam flags, applied INLINE only by the *_as helpers (never exported).
ROOMS_TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")
MY_UID="$(python3 -c 'import os; print(os.getuid())')"

room_cli_as() {
  # room_cli_as <agent> <args...> — run the rooms CLI as if the process OS user
  # were the iso user agent-bridge-<agent> (iso-enforced regime).
  local who="$1"; shift
  env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${who}" \
    python3 "$ROOMS_CLI" "$@"
}

room_cli() {
  # Controller context: no test flags -> real pwd.getpwuid; the controller is
  # the rooms-db owner (the smoke runner created it) -> CONTROLLER regime.
  python3 "$ROOMS_CLI" "$@"
}

json_field() { python3 "$HELPER" json-field "$1" "$2"; }

# gateway_create_as <peer> <to> [--from <spoof>] — the PRIMARY iso gate. peer is
# the SO_PEERCRED OS actor; a --from in the argv is the spoof attempt.
gateway_authz() {
  local peer="$1" to="$2"; shift 2
  env "${ROOMS_TEST_FLAGS[@]}" python3 "$HELPER" gateway-authz "$peer" "$to" "$@"
}

# queue_create_iso <osuser> <to> [--from <spoof>] — the DIRECT cmd_create path
# as iso OS user <osuser>. resolve_os_actor() ignores --from under iso.
queue_create_iso() {
  local osuser="$1"; shift
  env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-${osuser}" \
    python3 "$QUEUE_CLI" create "$@"
}

# ---------------------------------------------------------------------------
# Set up two disjoint rooms: team-a {alice,bob}, team-b {carol}
# ---------------------------------------------------------------------------
ROOM_A=""; LINK_A=""
test_setup_rooms() {
  local out
  out="$(room_cli_as alice create --name team-a --json 2>/dev/null)"
  ROOM_A="$(json_field room_id "$out")"
  LINK_A="$(json_field invite_link "$out")"
  [[ -n "$ROOM_A" ]] || smoke_fail "setup: team-a create did not return a room_id"
  room_cli_as bob join "$LINK_A" >/dev/null 2>&1 || smoke_fail "setup: bob join"
  room_cli_as alice approve "$ROOM_A" bob >/dev/null 2>&1 || smoke_fail "setup: approve bob"
  room_cli_as carol create --name team-b --json >/dev/null 2>&1 || smoke_fail "setup: team-b create"
}

# ---------------------------------------------------------------------------
# default-off NO-OP: cross-room create ALLOWED (zero behavior change)
# ---------------------------------------------------------------------------
test_default_off_is_noop() {
  smoke_assert_contains "$(room_cli acl --json 2>/dev/null)" '"rooms_acl": "off"' \
    "rooms_acl defaults to off"
  # gateway path: alice -> carol (no shared room) ALLOWED under off
  local got
  got="$(gateway_authz alice carol 2>/dev/null)"
  smoke_assert_contains "$got" "ok=1" "off: gateway cross-room create is a no-op ALLOW"
  smoke_assert_contains "$got" "reason=ok" "off: gateway no-op reason ok"
  # direct path: alice (iso) -> carol ALLOWED under off (a real task row is created)
  queue_create_iso alice --to carol --from alice --title t --body b >/dev/null 2>&1 \
    || smoke_fail "off: direct cross-room create must succeed (no-op)"
}

# ---------------------------------------------------------------------------
# enforce: flip the mode (controller-gated)
# ---------------------------------------------------------------------------
test_acl_flip_controller_gated() {
  # A managed iso agent CANNOT flip the mode (operator action).
  if room_cli_as mallory acl enforce >/dev/null 2>&1; then
    smoke_fail "TEETH: a managed iso agent must NOT be able to flip rooms_acl"
  fi
  # The controller (db owner) CAN (rooms exist -> no --force needed).
  room_cli acl enforce >/dev/null 2>&1 || smoke_fail "controller acl enforce must succeed"
  smoke_assert_contains "$(room_cli acl --json 2>/dev/null)" '"rooms_acl": "enforce"' \
    "controller flip set enforce"
}

# ---------------------------------------------------------------------------
# enforce same-room ALLOW + cross-room DENY (both paths)
# ---------------------------------------------------------------------------
test_enforce_same_room_allow() {
  local got
  got="$(gateway_authz alice bob 2>/dev/null)"
  smoke_assert_contains "$got" "ok=1" "enforce: same-room gateway create ALLOWED (alice->bob)"
  smoke_assert_contains "$got" "from=alice" "enforce: gateway rewrites --from to the OS peer"
  # direct path same-room
  queue_create_iso alice --to bob --from alice --title t --body b >/dev/null 2>&1 \
    || smoke_fail "enforce: same-room direct create must succeed (alice->bob)"
}

test_enforce_cross_room_deny() {
  local got
  got="$(gateway_authz alice carol 2>/dev/null)"
  smoke_assert_contains "$got" "ok=0" "enforce: cross-room gateway create DENIED (alice->carol)"
  smoke_assert_contains "$got" "reason=acl_denied" "enforce: cross-room audited reason acl_denied"
  # direct path cross-room must fail loudly with the audited reason
  local err
  if err="$(queue_create_iso alice --to carol --from alice --title t --body b 2>&1)"; then
    smoke_fail "enforce: cross-room direct create must be DENIED (alice->carol)"
  fi
  smoke_assert_contains "$err" "acl_denied" "enforce: direct cross-room denial carries the audited reason"
}

# ---------------------------------------------------------------------------
# SPOOF teeth — the critical one. OS actor A passing --from B must be decided
# as A. B (carol) shares no room with A->R, so --from carol cannot smuggle.
# ---------------------------------------------------------------------------
test_spoof_from_rejected_gateway() {
  # Gateway: peer=alice (SO_PEERCRED), argv claims --from bob. The decision uses
  # peer alice. alice->carol is cross-room -> DENIED. The --from bob is ignored.
  local got
  got="$(gateway_authz alice carol --from bob 2>/dev/null)"
  smoke_assert_contains "$got" "ok=0" \
    "SPOOF gateway: OS peer alice + --from bob -> decided as alice -> DENIED to carol"
  smoke_assert_contains "$got" "reason=acl_denied" "SPOOF gateway: audited as acl_denied"
  # And the positive control: peer=bob (really shares team-a w/ alice) -> alice OK.
  smoke_assert_contains "$(gateway_authz bob alice 2>/dev/null)" "ok=1" \
    "SPOOF gateway control: the REAL room member (bob) CAN reach alice"
}

test_spoof_from_rejected_direct() {
  # Direct cmd_create: OS user alice passes --from bob. resolve_os_actor ignores
  # --from under iso -> decided as alice -> alice->carol cross-room -> DENIED.
  local err
  if err="$(queue_create_iso alice --to carol --from bob --title t --body b 2>&1)"; then
    smoke_fail "SPOOF direct: OS user alice + --from bob must STILL be denied to carol"
  fi
  smoke_assert_contains "$err" "acl_denied" "SPOOF direct: --from does not grant bob's membership"
  smoke_assert_contains "$err" "'alice'" "SPOOF direct: denial names the OS actor (alice), not --from bob"
}

# ---------------------------------------------------------------------------
# r2 NEGATIVE CONTROL (the codex Phase-4 r2 BLOCKING): the gateway-child env
# signal (BRIDGE_QUEUE_GATEWAY_SERVER / _ACTOR) is FORGEABLE by a direct managed
# agent. cmd_create must trust it ONLY when this process is the controller —
# anchored (r3) to the owner of the REAL TASK DB being written. The gateway runs
# as the controller and spawns the queue child in-process (no uid drop), so a
# genuine child owns the task DB; a direct managed (non-controller) agent that
# exports the flags does NOT, and must be decided as its REAL OS actor. The
# paired-flag BRIDGE_QUEUE_TEST_NOT_CONTROLLER=1 simulates a non-controller agent
# on a single-uid test host (production sets none of the paired flags).
# ---------------------------------------------------------------------------
test_r2_forged_gateway_env_rejected() {
  # Simulate a direct iso agent 'carol' (NOT the controller via the paired-flag
  # seam) forging SERVER=1 + ACTOR=bob (bob shares team-a with the target alice;
  # carol does not). The forged actor MUST be ignored -> decided as carol ->
  # cross-room with alice -> DENIED. The impersonation bypass, reproduced.
  local err
  if err="$(env "${ROOMS_TEST_FLAGS[@]}" \
               "BRIDGE_QUEUE_TEST_NOT_CONTROLLER=1" \
               "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-carol" \
               "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
               "BRIDGE_QUEUE_GATEWAY_SERVER=1" "BRIDGE_QUEUE_GATEWAY_ACTOR=bob" \
             python3 "$QUEUE_CLI" create --to alice --from bob --title t --body b 2>&1)"; then
    smoke_fail "r2 TEETH: a non-controller agent forging the gateway env MUST NOT impersonate (carol->alice via forged ACTOR=bob)"
  fi
  smoke_assert_contains "$err" "acl_denied" "r2: forged gateway env is ignored -> cross-room deny"
  smoke_assert_contains "$err" "'carol'" "r2: decided as the REAL OS actor (carol), not the forged ACTOR=bob"
  # Positive control: the SAME process AS THE CONTROLLER (owns the real task DB)
  # IS trusted -> ACTOR=alice -> bob (shared) ALLOWED. Not a blanket deny.
  env "${ROOMS_TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
      "BRIDGE_QUEUE_GATEWAY_SERVER=1" "BRIDGE_QUEUE_GATEWAY_ACTOR=alice" \
    python3 "$QUEUE_CLI" create --to bob --from carol --title t --body b >/dev/null 2>&1 \
    || smoke_fail "r2 control: a GENUINE gateway child (owns the task DB) must trust the gateway actor (alice->bob ALLOW)"
}

# ---------------------------------------------------------------------------
# r3 NEGATIVE CONTROL (the codex Phase-4 r3 BLOCKING): the controller anchor and
# the membership lookup must read the rooms.db CANONICALLY co-located with the
# REAL task DB — NOT a caller-redirectable BRIDGE_A2A_ROOMS_DB. Otherwise a
# managed agent keeps the task-DB env REAL while pointing the rooms-DB env at a
# self-owned FAKE (seeded so it shares a room with the target) and drives the
# real queue past the gate.
# ---------------------------------------------------------------------------
test_r3_fake_rooms_db_ignored() {
  # Build a self-owned FAKE rooms.db where carol DOES share a room with alice
  # (the exploit bait). Then a gateway create with the REAL task-DB env but the
  # FAKE rooms-DB env: the gate must read the CANONICAL rooms.db (co-located with
  # the real task DB, where carol does NOT share alice) -> DENIED. If the fake
  # were honored this would be ALLOWED (the codex r3 bypass).
  local fake_db="$SMOKE_TMP_ROOT/fake-rooms.db"
  rm -f "$fake_db"
  local fk fl
  fk="$(env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_A2A_ROOMS_DB=$fake_db" \
         "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-carol" \
         python3 "$ROOMS_CLI" create --name fakeroom --json 2>/dev/null)"
  local fr; fr="$(json_field room_id "$fk")"; fl="$(json_field invite_link "$fk")"
  env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_A2A_ROOMS_DB=$fake_db" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-alice" \
    python3 "$ROOMS_CLI" join "$fl" >/dev/null 2>&1
  env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_A2A_ROOMS_DB=$fake_db" \
      "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-carol" \
    python3 "$ROOMS_CLI" approve "$fr" alice >/dev/null 2>&1
  env "${ROOMS_TEST_FLAGS[@]}" "BRIDGE_A2A_ROOMS_DB=$fake_db" \
    python3 "$ROOMS_CLI" acl enforce >/dev/null 2>&1
  # Exploit: real task DB (the smoke's, which the runner owns = controller) +
  # FAKE rooms-DB env + gateway create as carol -> alice. Canonical read denies.
  local err
  if err="$(env "${ROOMS_TEST_FLAGS[@]}" \
               "BRIDGE_A2A_ROOMS_DB=$fake_db" \
               "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
               "BRIDGE_QUEUE_GATEWAY_SERVER=1" "BRIDGE_QUEUE_GATEWAY_ACTOR=carol" \
             python3 "$QUEUE_CLI" create --to alice --from carol --title t --body b 2>&1)"; then
    smoke_fail "r3 TEETH: a self-owned FAKE rooms-DB env (carol shares alice) must NOT drive the real queue gate (carol->alice)"
  fi
  smoke_assert_contains "$err" "acl_denied" \
    "r3: the enforcement rooms.db is the CANONICAL one (real home), not the redirected fake"
  smoke_assert_contains "$err" "'carol'" "r3: decided against the canonical rooms.db (carol not sharing alice)"
}

# ---------------------------------------------------------------------------
# r4 NEGATIVE CONTROL (the codex Phase-4 r4 BLOCKING): the DIRECT (non-gateway)
# fallback can self-promote to ACTOR_CONTROLLER through resolve_os_actor(), whose
# controller verdict anchors to the ENV-selected rooms.db owner (BRIDGE_A2A_ROOMS_
# DB). A managed agent points the rooms-DB env at a self-owned/absent fake →
# resolve_os_actor returns CONTROLLER → acl_create_decision short-circuits to
# allow BEFORE the canonical membership read. The fix re-anchors the controller
# exemption to the REAL TASK DB owner: a non-task-DB-owner CONTROLLER verdict is
# forged → discarded (and the caller-supplied --from with it) → decided by the
# REAL OS facts against the canonical rooms.db.
# ---------------------------------------------------------------------------
test_r4_direct_fallback_fake_controller_rejected() {
  # Managed iso 'carol' (NOT the real task-DB owner) on the DIRECT path (no
  # gateway flag) points the rooms-DB env at an ABSENT fake and passes --from bob.
  # resolve_os_actor would return CONTROLLER off the fake rooms-DB owner; the fix
  # re-anchors to the real task DB → not owned → forged controller discarded →
  # re-resolved as the REAL OS actor (carol) → canonical: carol not in alice's
  # room → DENIED. The forged --from bob is NOT honored.
  local err
  if err="$(env "${ROOMS_TEST_FLAGS[@]}" \
               "BRIDGE_QUEUE_TEST_NOT_CONTROLLER=1" \
               "BRIDGE_A2A_ROOMS_DB=$SMOKE_TMP_ROOT/r4-absent/fake.db" \
               "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-carol" \
               "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
             python3 "$QUEUE_CLI" create --to alice --from bob --title t --body b 2>&1)"; then
    smoke_fail "r4 TEETH: a direct managed agent forging CONTROLLER via a fake rooms-DB must NOT bypass (carol->alice)"
  fi
  smoke_assert_contains "$err" "acl_denied" \
    "r4: a forged CONTROLLER (fake rooms-DB owner) is discarded; decided by real OS membership"
  smoke_assert_contains "$err" "'carol'" "r4: decided as the REAL OS actor (carol), not the forged --from bob"
  # Non-iso force-controller variant: resolve returns CONTROLLER via the gated
  # test controller-uid match + non-iso, but the task DB is not owned -> the
  # forged controller is discarded -> UNRESOLVED -> fail closed (DENY).
  if err="$(env "${ROOMS_TEST_FLAGS[@]}" \
               "BRIDGE_QUEUE_TEST_NOT_CONTROLLER=1" \
               "BRIDGE_A2A_ROOMS_DB=$SMOKE_TMP_ROOT/r4-self/fake.db" \
               "BRIDGE_ROOMS_TEST_ISO_USER=" \
               "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
               "BRIDGE_ROOMS_TEST_CONTROLLER_UID=${MY_UID}" \
             python3 "$QUEUE_CLI" create --to alice --from bob --title t --body b 2>&1)"; then
    smoke_fail "r4 TEETH: a non-iso forged CONTROLLER without task-DB ownership must FAIL CLOSED"
  fi
  smoke_assert_contains "$err" "fail" \
    "r4: a non-iso forged controller -> UNRESOLVED fail-closed (no membership bypass)"
}

test_r2_shared_mode_forged_env_advisory() {
  # Shared-mode edge: a single-UID install where the managed agent IS the
  # controller uid (no OS separation) but the host has NO iso users. A forged
  # gateway env must NOT yield a HARD block — §14 R1 keeps shared-mode advisory.
  # The create SUCCEEDS (advisory regime warns, never blocks).
  env "${ROOMS_TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_ISO_USER=" \
      "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=0" \
      "BRIDGE_QUEUE_GATEWAY_SERVER=1" "BRIDGE_QUEUE_GATEWAY_ACTOR=bob" \
    python3 "$QUEUE_CLI" create --to carol --from bob --title t --body b >/dev/null 2>&1 \
    || smoke_fail "r2 shared-mode: a forged gateway env on a non-iso host must stay ADVISORY (no hard block)"
}

# ---------------------------------------------------------------------------
# gateway-server trusted-actor env: cmd_create under BRIDGE_QUEUE_GATEWAY_SERVER
# uses BRIDGE_QUEUE_GATEWAY_ACTOR (the gateway-set OS identity), NEVER --from.
# This closes the file-transport spoof: the file gateway does NOT rewrite
# --from, so cmd_create must NOT trust args.actor — only the gateway env var.
# ---------------------------------------------------------------------------
# A GENUINE gateway child: this process IS the controller — it owns the REAL task
# DB (the smoke runner created it), the r3 anchor. On an iso host the gateway-
# child env signal is then trusted. queue_create_gw_child <gw_actor|""> <args...>.
queue_create_gw_child() {
  local gw_actor="$1"; shift
  local actor_env=()
  [[ -n "$gw_actor" ]] && actor_env=("BRIDGE_QUEUE_GATEWAY_ACTOR=${gw_actor}")
  env "${ROOMS_TEST_FLAGS[@]}" \
      "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
      "BRIDGE_QUEUE_GATEWAY_SERVER=1" "${actor_env[@]}" \
    python3 "$QUEUE_CLI" create "$@"
}

test_gateway_server_trusted_actor_env() {
  # GENUINE gateway child (controller uid, iso host) + GATEWAY_ACTOR=alice + a
  # spoofed --from carol -> decided as alice. alice->carol cross-room -> DENIED.
  local err
  if err="$(queue_create_gw_child alice --to carol --from carol --title t --body b 2>&1)"; then
    smoke_fail "gateway-server: GATEWAY_ACTOR=alice + --from carol must be DENIED to carol"
  fi
  smoke_assert_contains "$err" "acl_denied" "gateway-server: trusted env actor decides (not --from)"
  smoke_assert_contains "$err" "'alice'" "gateway-server: denial names the gateway-set actor (alice)"
  # Positive control: same env, target=bob (shared with alice) -> ALLOWED.
  queue_create_gw_child alice --to bob --from carol --title t --body b >/dev/null 2>&1 \
    || smoke_fail "gateway-server: GATEWAY_ACTOR=alice -> alice->bob (shared room) must ALLOW"
}

test_gateway_server_no_actor_fails_closed() {
  # GENUINE gateway child but NO BRIDGE_QUEUE_GATEWAY_ACTOR (e.g. file transport
  # could not map the request-file owner to an iso agent). cmd_create must NOT
  # fall back to the client --from -> FAIL CLOSED under enforce (file-transport
  # BLOCKING fix, codex r1): an unauthenticated gateway create is denied.
  local err
  if err="$(queue_create_gw_child "" --to carol --from carol --title t --body b 2>&1)"; then
    smoke_fail "gateway-server with NO trusted actor must FAIL CLOSED under enforce"
  fi
  smoke_assert_contains "$err" "failing closed" \
    "gateway-server no-actor: fail-closed (does not trust the client --from)"
}

test_gateway_server_corrupt_db_fails_closed() {
  # GENUINE gateway child + GATEWAY_ACTOR=alice + a present-but-CORRUPT rooms.db.
  # The mode read must NOT silently degrade to 'off' (the BLOCKING fail-open
  # codex r1 flagged) — an iso actor under a corrupt db FAILS CLOSED. The corrupt
  # db is the controller's (we own it), so is_controller_process() is True here.
  local corrupt_home="$SMOKE_TMP_ROOT/corruptdb-home"
  mkdir -p "$corrupt_home/state/handoff"
  printf 'corrupt not-sqlite %.0s' {1..60} >"$corrupt_home/state/handoff/rooms.db"
  local err
  if err="$(env "${ROOMS_TEST_FLAGS[@]}" \
               "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
               "BRIDGE_QUEUE_GATEWAY_SERVER=1" "BRIDGE_QUEUE_GATEWAY_ACTOR=alice" \
               BRIDGE_HOME="$corrupt_home" BRIDGE_STATE_DIR="$corrupt_home/state" \
               BRIDGE_TASK_DB="$corrupt_home/state/tasks.db" \
               BRIDGE_A2A_ROOMS_DB="$corrupt_home/state/handoff/rooms.db" \
             python3 "$QUEUE_CLI" create --to bob --title t --body b 2>&1)"; then
    smoke_fail "gateway-server: a corrupt rooms.db under enforce must FAIL CLOSED, not read off"
  fi
  smoke_assert_contains "$err" "fail" \
    "gateway-server corrupt-db: fail-closed (a previously-enforced DB cannot silently drop to off)"
}

# ---------------------------------------------------------------------------
# fail-closed: enforce + un-establishable OS actor -> DENY (decision-level)
# ---------------------------------------------------------------------------
test_fail_closed_unresolved() {
  local got
  got="$(python3 "$HELPER" decision "$BRIDGE_A2A_ROOMS_DB" enforce unresolved "" carol 2>/dev/null)"
  smoke_assert_contains "$got" "outcome=deny" "fail-closed: UNRESOLVED actor under enforce DENIES"
  smoke_assert_contains "$got" "reason=acl_fail_closed" "fail-closed: audited reason"
}

# ---------------------------------------------------------------------------
# fail-closed: enforce + unreadable/corrupt rooms.db (iso) -> DENY
# ---------------------------------------------------------------------------
test_fail_closed_corrupt_db() {
  local bad="$SMOKE_TMP_ROOT/corrupt-rooms.db"
  printf 'this is definitely not a sqlite database %.0s' {1..40} >"$bad"
  local got
  got="$(python3 "$HELPER" decision "$bad" enforce iso alice carol 2>/dev/null)"
  smoke_assert_contains "$got" "outcome=deny" \
    "fail-closed: a corrupt rooms.db under enforce DENIES for an iso actor"
  smoke_assert_contains "$got" "reason=acl_fail_closed" "fail-closed: corrupt-db audited reason"
  # shared-mode degrades to advisory (no hard boundary claimed) on the same fault
  got="$(python3 "$HELPER" decision "$bad" enforce shared alice carol 2>/dev/null)"
  smoke_assert_contains "$got" "outcome=advisory" \
    "shared-mode: a db fault degrades to advisory (no hard block claimed there)"
}

# ---------------------------------------------------------------------------
# controller / daemon exemption: CONTROLLER regime -> ALLOW (non-spoofable)
# ---------------------------------------------------------------------------
test_controller_exemption() {
  local got
  got="$(python3 "$HELPER" decision "$BRIDGE_A2A_ROOMS_DB" enforce controller daemon carol 2>/dev/null)"
  smoke_assert_contains "$got" "outcome=allow" \
    "exemption: a CONTROLLER-regime actor (operator/daemon/cron/receiver) ALLOWED"
  smoke_assert_contains "$got" "reason=acl_controller_bypass" "exemption: audited as controller bypass"
}

# ---------------------------------------------------------------------------
# self-message: actor == target -> ALLOW
# ---------------------------------------------------------------------------
test_self_message_allowed() {
  smoke_assert_contains "$(gateway_authz alice alice 2>/dev/null)" "ok=1" \
    "self-message (alice->alice) is ALLOWED under enforce"
}

# ---------------------------------------------------------------------------
# shared-mode advisory: cross-room WARNS but does NOT block
# ---------------------------------------------------------------------------
test_shared_mode_advisory() {
  local got
  got="$(python3 "$HELPER" decision "$BRIDGE_A2A_ROOMS_DB" enforce shared alice carol 2>/dev/null)"
  smoke_assert_contains "$got" "outcome=advisory" \
    "shared-mode: cross-room is ADVISORY (warn, not block) — honest §14 R1 default"
  smoke_assert_contains "$got" "reason=acl_advisory_cross_room" "shared-mode: advisory reason"
}

# ---------------------------------------------------------------------------
# enforce with NO rooms is a loud operator error (not a silent lockout)
# ---------------------------------------------------------------------------
test_enforce_no_rooms_is_loud() {
  local fresh="$SMOKE_TMP_ROOT/norooms-home"
  mkdir -p "$fresh/state/handoff"
  local err
  if err="$(BRIDGE_HOME="$fresh" BRIDGE_STATE_DIR="$fresh/state" \
            BRIDGE_A2A_ROOMS_DB="$fresh/state/handoff/rooms.db" \
            python3 "$ROOMS_CLI" acl enforce 2>&1)"; then
    smoke_fail "enforce with no rooms must be a LOUD error, not a silent set"
  fi
  smoke_assert_contains "$err" "adopt-all" \
    "no-rooms enforce error points the operator at adopt-all (no silent lockout)"
  # --force is the documented escape hatch (full lockdown).
  BRIDGE_HOME="$fresh" BRIDGE_STATE_DIR="$fresh/state" \
    BRIDGE_A2A_ROOMS_DB="$fresh/state/handoff/rooms.db" \
    python3 "$ROOMS_CLI" acl enforce --force >/dev/null 2>&1 \
    || smoke_fail "--force must allow enforce with no rooms (lockdown)"
}

# ---------------------------------------------------------------------------
# adopt-all -> enforce: every roster agent shares the default room; nobody
# is stranded; controller/daemon traffic still flows.
# ---------------------------------------------------------------------------
test_adopt_all_then_enforce_strands_nobody() {
  local home="$SMOKE_TMP_ROOT/adopt-home"
  mkdir -p "$home/state/handoff"
  local rdb="$home/state/handoff/rooms.db"
  local tdb="$home/state/tasks.db"
  local roster="$home/agent-roster.local.sh"
  # Seed a deterministic roster so adopt-all consults a known agent set.
  python3 "$P1A_HELPER" write-roster "$roster" alpha beta gamma >/dev/null 2>&1
  # adopt-all as the controller (db owner) — leader becomes the caller id.
  local out members
  out="$(BRIDGE_HOME="$home" BRIDGE_STATE_DIR="$home/state" \
         BRIDGE_A2A_ROOMS_DB="$rdb" BRIDGE_ROSTER_LOCAL_FILE="$roster" \
         python3 "$ROOMS_CLI" adopt-all --name default --json 2>/dev/null)"
  members="$(python3 "$HELPER" members-csv "$out")"
  for ag in alpha beta gamma; do
    smoke_assert_contains ",$members," ",$ag," "adopt-all default room includes $ag"
  done
  # Flip enforce (rooms now exist -> allowed without --force).
  BRIDGE_HOME="$home" BRIDGE_STATE_DIR="$home/state" BRIDGE_A2A_ROOMS_DB="$rdb" \
    python3 "$ROOMS_CLI" acl enforce >/dev/null 2>&1 \
    || smoke_fail "adopt-all then enforce flip must succeed"
  # Every adopted agent shares the default room -> all gateway creates ALLOWED.
  local pair got
  for pair in "alpha beta" "beta gamma" "gamma alpha"; do
    # shellcheck disable=SC2086
    set -- $pair
    got="$(env "${ROOMS_TEST_FLAGS[@]}" BRIDGE_HOME="$home" BRIDGE_STATE_DIR="$home/state" \
           BRIDGE_A2A_ROOMS_DB="$rdb" BRIDGE_TASK_DB="$tdb" \
           python3 "$HELPER" gateway-authz "$1" "$2" 2>/dev/null)"
    smoke_assert_contains "$got" "ok=1" "adopt-all->enforce: $1->$2 (default room) ALLOWED — strands nobody"
  done
  # The controller/daemon exemption still flows post-adopt.
  got="$(BRIDGE_HOME="$home" BRIDGE_STATE_DIR="$home/state" BRIDGE_A2A_ROOMS_DB="$rdb" \
         python3 "$HELPER" decision "$rdb" enforce controller daemon alpha 2>/dev/null)"
  smoke_assert_contains "$got" "outcome=allow" "adopt-all->enforce: daemon/controller traffic still flows"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "setup: two disjoint rooms (team-a {alice,bob}, team-b {carol})" test_setup_rooms
smoke_run "default-off is a true no-op (cross-room ALLOWED, zero behavior change)" test_default_off_is_noop
smoke_run "acl-flip is controller-gated (iso agent cannot flip; controller can)" test_acl_flip_controller_gated
smoke_run "enforce same-room ALLOW (gateway + direct)" test_enforce_same_room_allow
smoke_run "enforce cross-room DENY (fail-closed, audited reason; gateway + direct)" test_enforce_cross_room_deny
smoke_run "SPOOF teeth: --from rejected at the gateway (OS peer decides)" test_spoof_from_rejected_gateway
smoke_run "SPOOF teeth: --from rejected on the direct path (resolve_os_actor)" test_spoof_from_rejected_direct
smoke_run "r2 TEETH: forged gateway env by a non-controller agent is IGNORED (impersonation bypass closed)" test_r2_forged_gateway_env_rejected
smoke_run "r3 TEETH: a self-owned FAKE rooms-DB env cannot drive the real queue gate (canonical rooms.db)" test_r3_fake_rooms_db_ignored
smoke_run "r4 TEETH: direct-fallback forged CONTROLLER via fake rooms-DB is rejected (task-DB-owner anchor)" test_r4_direct_fallback_fake_controller_rejected
smoke_run "r2: shared-mode forged gateway env stays ADVISORY (no hard block)" test_r2_shared_mode_forged_env_advisory
smoke_run "gateway-server uses BRIDGE_QUEUE_GATEWAY_ACTOR, NOT client --from (file-xport spoof closed)" test_gateway_server_trusted_actor_env
smoke_run "gateway-server with NO trusted actor FAILS CLOSED under enforce (file-xport BLOCKING)" test_gateway_server_no_actor_fails_closed
smoke_run "gateway-server: corrupt rooms.db FAILS CLOSED (mode-read no-fail-open, BLOCKING)" test_gateway_server_corrupt_db_fails_closed
smoke_run "fail-closed: UNRESOLVED actor under enforce DENIES" test_fail_closed_unresolved
smoke_run "fail-closed: corrupt rooms.db under enforce DENIES (iso); advisory (shared)" test_fail_closed_corrupt_db
smoke_run "exemption: CONTROLLER regime (operator/daemon/cron/receiver) ALLOWED" test_controller_exemption
smoke_run "self-message (actor==target) ALLOWED" test_self_message_allowed
smoke_run "shared-mode cross-room is ADVISORY (warn, not block)" test_shared_mode_advisory
smoke_run "enforce with NO rooms is a loud operator error (not silent lockout)" test_enforce_no_rooms_is_loud
smoke_run "adopt-all -> enforce strands nobody + daemon traffic flows" test_adopt_all_then_enforce_strands_nobody

smoke_log "passed"
