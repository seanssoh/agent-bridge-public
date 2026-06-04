#!/usr/bin/env bash
# scripts/smoke/a2a-rooms-1517-bootstrap.sh — #1517 controller-only rooms.db
# auto-bootstrap on first `room create` (fresh iso host).
#
# The gap (#1517): on a brand-new iso-v2 host the canonical
# state/handoff/rooms.db does not exist yet, so the controller anchor
# (`_controller_uid` = stat(rooms.db).st_uid) has nothing to anchor to and even
# the genuine controller's FIRST `agb room create` resolves to ACTOR_UNRESOLVED
# (`actor_unresolved`) and is denied — a chicken-and-egg (you cannot create the
# first room because the room DB whose owner is the controller anchor does not
# exist). The fix: when a room mutation runs and the canonical rooms.db is
# ABSENT and the caller is the PROVEN controller of the canonical location
# (OS-derived: os.getuid() owns the canonical state/handoff tree, NOT a
# caller-redirectable env), auto-create the controller-owned canonical rooms.db
# (open_rooms() schema, 0600) then proceed.
#
# TEETH (the load-bearing P1b invariant — do NOT regress):
#   - BOOTSTRAP PASS: controller context + absent canonical DB -> create
#     auto-seeds a controller-owned 0600 canonical rooms.db, mints the room
#     (epoch 0), NO actor_unresolved.
#   - SECURITY: a managed (non-controller) caller that does NOT own the
#     canonical location must STILL be denied the bootstrap — it cannot seed a
#     self-owned canonical rooms.db to become "controller" (the P1b bypass
#     class stays closed). controller_uid stays unanchored to the agent.
#   - SECURITY (env redirect): a caller-redirected BRIDGE_A2A_ROOMS_DB must NOT
#     relocate the bootstrap — bootstrap is CANONICAL-path only (it neither
#     seeds the canonical path when the effective path is redirected, nor seeds
#     the redirect target).
#   - IDEMPOTENT: a 2nd create with the DB now present does NOT re-bootstrap /
#     clobber (same inode, prior rooms preserved).
#
# Cross-platform via the SAME paired-flag test seam P1a/P1b established
# (BRIDGE_ROOMS_TEST_*; gated by BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1 AND
# BRIDGE_A2A_ALLOW_TEST_BIND=1). Production sets NEITHER flag so it is never
# honored — the gate falls through to the real pwd.getpwuid / stat OS facts.
# The seam can simulate the OS *username* and the canonical-ownership decision,
# so the security LOGIC is exercised on a clean macOS host too (no real iso
# UIDs needed); on a real iso-v2 Linux host the canonical state dir is
# controller-owned at the filesystem level, which is the same boundary the
# BRIDGE_ROOMS_TEST_OWNS_CANON=0 leg simulates.

set -euo pipefail

SMOKE_NAME="a2a-rooms-1517-bootstrap"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

HELPER="$SCRIPT_DIR/a2a-rooms-1517-bootstrap-helper.py"
ROOMS_CLI="$SMOKE_REPO_ROOT/bridge-rooms.py"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_require_cmd python3

smoke_setup_bridge_home "$SMOKE_NAME"

# The canonical rooms.db is state/handoff/rooms.db under the (controller-owned)
# state dir. We deliberately do NOT export BRIDGE_A2A_ROOMS_DB so the canonical
# path == rooms_db_path() and the bootstrap is exercised on the canonical path.
unset BRIDGE_A2A_ROOMS_DB || true
unset BRIDGE_A2A_CONFIG || true

# Paired test-seam flags (NEVER exported into the env that production reads;
# applied INLINE only by the run_* helpers below).
ROOMS_TEST_FLAGS=("BRIDGE_ROOMS_ALLOW_TEST_UID_MAP=1" "BRIDGE_A2A_ALLOW_TEST_BIND=1")

# Each scenario gets a FRESH (absent-rooms.db) canonical home so we test the
# first-use bootstrap path, not a pre-seeded one. fresh_home <subdir> repoints
# BRIDGE_HOME / BRIDGE_STATE_DIR under SMOKE_TMP_ROOT and returns the canonical
# rooms.db path for that home.
CANON_DB=""
fresh_home() {
  local sub="$1"
  export BRIDGE_HOME="$SMOKE_TMP_ROOT/$sub"
  export BRIDGE_STATE_DIR="$BRIDGE_HOME/state"
  mkdir -p "$BRIDGE_STATE_DIR"   # controller-owned state dir (this real uid)
  CANON_DB="$BRIDGE_STATE_DIR/handoff/rooms.db"
}

json_field() {
  python3 -c "import sys, json; print(json.load(sys.stdin).get('$1',''))"
}

# ---------------------------------------------------------------------------
# BOOTSTRAP PASS — controller, fresh canonical DB, simulated iso host
# ---------------------------------------------------------------------------
test_bootstrap_pass_controller_fresh_iso() {
  fresh_home "pass-controller"
  if [[ -e "$CANON_DB" ]]; then
    smoke_fail "precondition: canonical rooms.db must be ABSENT at start"
  fi
  # Controller context on a (simulated) ISO HOST: NOT an iso OS user
  # (BRIDGE_ROOMS_TEST_ISO_USER= forces not-iso), host HAS iso users (=1), and
  # we own the canonical state dir (real uid). WITHOUT the fix this is exactly
  # the #1517 actor_unresolved denial; WITH the fix the controller bootstraps.
  local out rc
  out="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
             "BRIDGE_ROOMS_TEST_ISO_USER=" \
           python3 "$ROOMS_CLI" create --name team-a --json 2>&1)" && rc=0 || rc=$?
  smoke_assert_eq "0" "${rc:-1}" "controller first create must SUCCEED (not actor_unresolved)"
  smoke_assert_not_contains "$out" "actor_unresolved" \
    "controller first create must NOT fail with actor_unresolved (the #1517 bug)"
  local room_id epoch
  room_id="$(printf '%s' "$out" | json_field room_id)"
  epoch="$(printf '%s' "$out" | json_field epoch)"
  [[ -n "$room_id" ]] || smoke_fail "create did not mint a room_id"
  smoke_assert_eq "0" "$epoch" "freshly bootstrapped room starts at epoch 0"
  # The canonical controller-owned 0600 rooms.db now exists.
  smoke_assert_file_exists "$CANON_DB" "bootstrap created the canonical rooms.db"
  local mode
  mode="$(python3 "$HELPER" file-mode "$CANON_DB")"
  smoke_assert_eq "600" "$mode" "bootstrapped rooms.db must be mode 0600"
  python3 "$HELPER" file-owner-is-me "$CANON_DB" \
    || smoke_fail "bootstrapped rooms.db must be owned by the controller uid"
}

# ---------------------------------------------------------------------------
# NEGATIVE CONTROL (teeth) — prove the bootstrap is what flips the controller
# from UNRESOLVED (the #1517 bug) to CONTROLLER. On a fresh canonical iso host
# the controller's regime is UNRESOLVED *before* the bootstrap (no rooms.db to
# anchor `_controller_uid`) and CONTROLLER *after* it. This makes the PASS test
# non-vacuous: without the bootstrap the controller would be denied
# (actor_unresolved), exactly the bug.
# ---------------------------------------------------------------------------
test_negative_control_bootstrap_flips_unresolved_to_controller() {
  fresh_home "neg-control"
  if [[ -e "$CANON_DB" ]]; then
    smoke_fail "precondition: canonical rooms.db must be ABSENT at start"
  fi
  local out before created after
  out="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
             "BRIDGE_ROOMS_TEST_ISO_USER=" \
           python3 "$HELPER" bootstrap-then-regime 2>&1)"
  before="$(printf '%s' "$out" | sed -E 's/.*before=([^ ]+).*/\1/')"
  created="$(printf '%s' "$out" | sed -E 's/.*created=([^ ]+).*/\1/')"
  after="$(printf '%s' "$out" | sed -E 's/.*after=([^ ]+).*/\1/')"
  smoke_assert_eq "unresolved" "$before" \
    "NEGATIVE CONTROL: BEFORE bootstrap the controller is UNRESOLVED (the #1517 actor_unresolved bug)"
  smoke_assert_eq "True" "$created" \
    "NEGATIVE CONTROL: the controller bootstrap seeds the canonical db"
  smoke_assert_eq "controller" "$after" \
    "NEGATIVE CONTROL: AFTER bootstrap the controller resolves to CONTROLLER (the fix)"
}

# ---------------------------------------------------------------------------
# SECURITY — managed (non-controller) caller must STILL fail closed: it cannot
# bootstrap a self-owned canonical rooms.db to become "controller".
# ---------------------------------------------------------------------------
test_security_managed_agent_cannot_bootstrap() {
  fresh_home "deny-managed"
  if [[ -e "$CANON_DB" ]]; then
    smoke_fail "precondition: canonical rooms.db must be ABSENT at start"
  fi
  # Drive the bootstrap helper as a managed agent that does NOT own the
  # canonical location (BRIDGE_ROOMS_TEST_OWNS_CANON=0 stands in for the
  # iso-v2 fact that state/handoff is controller-owned and a managed
  # agent-bridge-<a> UID cannot create/own it). The bootstrap MUST refuse and
  # create nothing; controller_uid must NOT anchor to this caller.
  local out
  out="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" \
             "BRIDGE_ROOMS_TEST_ISO_USER=agent-bridge-mallory" \
             "BRIDGE_ROOMS_TEST_OWNS_CANON=0" \
           python3 "$HELPER" bootstrap 2>&1)"
  smoke_assert_contains "$out" "created=False" \
    "TEETH: managed agent must NOT be able to bootstrap the canonical rooms.db"
  smoke_assert_contains "$out" "canon_exists=False" \
    "TEETH: no canonical rooms.db is created for a non-controller caller"
  smoke_assert_contains "$out" "controller_is_me=False" \
    "TEETH: a managed agent must NOT become controller via the bootstrap"
  # And nothing was written at the canonical path on disk.
  if python3 "$HELPER" path-exists "$CANON_DB"; then
    smoke_fail "TEETH: managed-agent bootstrap must leave the canonical path ABSENT"
  fi
}

# ---------------------------------------------------------------------------
# SECURITY — a caller-redirected BRIDGE_A2A_ROOMS_DB must NOT relocate the
# bootstrap (canonical path only). Even a caller that owns the canonical
# location must not seed a self-pointed redirect target via the bootstrap.
# ---------------------------------------------------------------------------
test_security_env_redirect_does_not_relocate_bootstrap() {
  fresh_home "deny-redirect"
  local redirect="$SMOKE_TMP_ROOT/self-owned/rooms.db"
  if [[ -e "$CANON_DB" || -e "$redirect" ]]; then
    smoke_fail "precondition: neither canonical nor redirect DB may exist yet"
  fi
  # Caller OWNS the canonical location (real uid) but redirects the rooms-DB
  # env elsewhere. The bootstrap is a no-op (effective path != canonical) and
  # must NOT seed either the canonical path or the redirect target.
  local out
  out="$(env "${ROOMS_TEST_FLAGS[@]}" \
             "BRIDGE_A2A_ROOMS_DB=$redirect" \
           python3 "$HELPER" bootstrap 2>&1)"
  smoke_assert_contains "$out" "created=False" \
    "TEETH: a redirected BRIDGE_A2A_ROOMS_DB must NOT trigger a canonical bootstrap"
  if python3 "$HELPER" path-exists "$CANON_DB"; then
    smoke_fail "TEETH: redirect must NOT seed the canonical rooms.db"
  fi
  if python3 "$HELPER" path-exists "$redirect"; then
    smoke_fail "TEETH: bootstrap must NOT seed the caller-redirected target either"
  fi
}

# ---------------------------------------------------------------------------
# IDEMPOTENT — a 2nd create with the DB present does not re-bootstrap / clobber.
# ---------------------------------------------------------------------------
test_idempotent_second_create_no_rebootstrap() {
  fresh_home "idempotent"
  local run1 run2 r1 r2 ino1 ino2 count
  run1="$(env "${ROOMS_TEST_FLAGS[@]}" \
              "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" "BRIDGE_ROOMS_TEST_ISO_USER=" \
            python3 "$ROOMS_CLI" create --name team-a --json 2>/dev/null)"
  r1="$(printf '%s' "$run1" | json_field room_id)"
  [[ -n "$r1" ]] || smoke_fail "first create must mint a room"
  smoke_assert_file_exists "$CANON_DB" "first create bootstrapped the canonical db"
  ino1="$(python3 -c "import os; print(os.stat('$CANON_DB').st_ino)")"
  # Second create — DB now present, bootstrap must be a no-op (same inode).
  run2="$(env "${ROOMS_TEST_FLAGS[@]}" \
              "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" "BRIDGE_ROOMS_TEST_ISO_USER=" \
            python3 "$ROOMS_CLI" create --name team-b --json 2>/dev/null)"
  r2="$(printf '%s' "$run2" | json_field room_id)"
  [[ -n "$r2" ]] || smoke_fail "second create must also mint a room"
  ino2="$(python3 -c "import os; print(os.stat('$CANON_DB').st_ino)")"
  smoke_assert_eq "$ino1" "$ino2" \
    "TEETH idempotent: 2nd create must reuse the same rooms.db (no re-bootstrap/clobber)"
  # Both rooms are still present (the first was not clobbered).
  count="$(env "${ROOMS_TEST_FLAGS[@]}" \
               "BRIDGE_ROOMS_TEST_HOST_HAS_ISO=1" "BRIDGE_ROOMS_TEST_ISO_USER=" \
             python3 "$ROOMS_CLI" list --json 2>/dev/null \
           | python3 -c "import sys, json; print(len(json.load(sys.stdin)))")"
  smoke_assert_eq "2" "$count" \
    "TEETH idempotent: both rooms survive (the bootstrap did not clobber the db)"
}

# ---------------------------------------------------------------------------
# run
# ---------------------------------------------------------------------------
smoke_run "bootstrap PASS: controller first create on a fresh iso host auto-seeds the canonical 0600 rooms.db" test_bootstrap_pass_controller_fresh_iso
smoke_run "NEGATIVE CONTROL: bootstrap flips the controller UNRESOLVED -> CONTROLLER (without it = the #1517 bug)" test_negative_control_bootstrap_flips_unresolved_to_controller
smoke_run "TEETH: a managed (non-controller) agent cannot bootstrap a self-owned canonical rooms.db (P1b invariant)" test_security_managed_agent_cannot_bootstrap
smoke_run "TEETH: a caller-redirected BRIDGE_A2A_ROOMS_DB does not relocate the bootstrap (canonical only)" test_security_env_redirect_does_not_relocate_bootstrap
smoke_run "TEETH idempotent: a 2nd create does not re-bootstrap / clobber the rooms.db" test_idempotent_second_create_no_rebootstrap

smoke_log "passed"
