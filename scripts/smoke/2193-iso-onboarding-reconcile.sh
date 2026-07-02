#!/usr/bin/env bash
# scripts/smoke/2193-iso-onboarding-reconcile.sh — issue #2193.
#
# THE BUG (follow-up to #2084). PR #2192's `ratchet_session_type_layer_complete`
# is ownership-guarded (`st_uid == geteuid()`), so under linux-user isolation
# (iso v2) — where `data/agents/<a>/{workdir,home}/SESSION-TYPE.md` are owned by
# the agent's dedicated UID, not the controller — it deliberately NO-OPs. A
# controller direct-write would strip the file's owner/group and land root-owned
# drift, a worse signal. So an iso-v2 install still shows the false
# `agent profile drift` watchdog warn after upgrade until the agent's own next
# session self-heals.
#
# THE FIX (bridge-upgrade.py + lib/upgrade-helpers/reconcile-iso-onboarding-layer.sh,
# pinned here): after the controller-owned ratchet, `reconcile_iso_onboarding_layers`
# streams the now-`complete` controller source into each iso-owned workdir/home
# copy AS THE AGENT USER (via bridge_isolation_write_file_as_agent_user_via_bash
# + group-normalize — the same path `_set_onboarding_critical` uses). One-way
# (pending->complete), idempotent, best-effort (a failed sudo-write leaves the
# copy for the agent's own next session and never aborts the upgrade).
#
# WHY A SIMULATION. A single-UID CI host (macOS) cannot own a file as a
# different (iso agent) UID, and cannot run real `sudo -u agent-bridge-<a>`. So
# this smoke SIMULATES the iso ownership shape with two documented test-only
# stubs (never set in production):
#   * BRIDGE_RECONCILE_TEST_STUB_ISO=1 — the Python treats every workdir/home
#     layer copy as foreign-owned (satisfies the ownership discriminator).
#   * BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1 — the Bash helper reports isolation
#     effective and simulates the sudo-to-agent write with a plain same-UID
#     write, so the reconcile is observable end-to-end.
# Real linux-user iso-v2 host validation is deferred / reporter-gated (severity
# is a false warning that self-heals, not data loss).
#
# Asserts (isolated BRIDGE_HOME — operator's live tree untouched):
#   T1 — iso reconcile: source drifted `pending`, HOME + WORKDIR copies pre-exist
#        `pending`, the completion marker is present. After migrate, BOTH the
#        WORKDIR and the HOME iso-owned copies read `complete`.
#   T2 — idempotent re-run leaves both iso copies `complete`, never errors.
#   T3 — shared-mode (no stub) is byte-unchanged: a controller-owned workdir copy
#        is still ratcheted in place by the #2084 path (regression guard that the
#        #2193 change did not disturb shared mode).
#   T4 — fault tolerance: a simulated iso-write failure leaves the copy `pending`
#        (self-heal) and the migrate still exits 0 (never aborts the upgrade).
#
# Footgun #11: no `<<EOF` / `<<'PY'` heredoc-stdin into a subprocess.

set -uo pipefail

SMOKE_NAME="2193-iso-onboarding-reconcile"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$SMOKE_REPO_ROOT"
smoke_require_cmd python3

AGENT="patch"

setup_fixture() {
  smoke_cleanup_temp_root
  smoke_setup_bridge_home "$SMOKE_NAME"
  export BRIDGE_DATA_ROOT="$BRIDGE_HOME"
  export BRIDGE_AGENT_ROOT_V2="$BRIDGE_HOME/data/agents"
  {
    printf '%s\n' 'BRIDGE_LAYOUT=v2'
    printf 'BRIDGE_DATA_ROOT=%q\n' "$BRIDGE_DATA_ROOT"
  } >"$BRIDGE_STATE_DIR/layout-marker.sh"

  TRACK_DIR="$BRIDGE_AGENT_HOME_ROOT/$AGENT"          # watchdog enumerates this root
  SOURCE_DIR="$BRIDGE_HOME/agents/$AGENT"             # profile source (== TRACK_DIR)
  HOME_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"
  WORK_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"
  STATE_AGENT_DIR="$BRIDGE_STATE_DIR/agents/$AGENT"
  COMPLETE_MARKER="$STATE_AGENT_DIR/onboarding-complete"
  PENDING_MARKER="$STATE_AGENT_DIR/onboarding-pending"
  mkdir -p "$TRACK_DIR/.claude" "$HOME_DIR" "$WORK_DIR" "$STATE_AGENT_DIR"

  {
    printf '%s\n' '<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->'
    printf '%s\n' 'managed'
    printf '%s\n' '<!-- END AGENT BRIDGE DOC MIGRATION -->'
  } >"$WORK_DIR/CLAUDE.md"
  : >"$WORK_DIR/SOUL.md"
  : >"$WORK_DIR/MEMORY-SCHEMA.md"
  : >"$WORK_DIR/MEMORY.md"

  {
    printf 'BRIDGE_AGENT_IDS=("%s")\n' "$AGENT"
    printf 'BRIDGE_AGENT_CLASS["%s"]="user"\n' "$AGENT"
    printf 'BRIDGE_AGENT_ENGINE["%s"]="claude"\n' "$AGENT"
    printf 'BRIDGE_AGENT_SOURCE["%s"]="static"\n' "$AGENT"
  } >"$BRIDGE_ROSTER_FILE"
}

write_session_type() {
  local path="$1" state="$2"
  {
    printf '%s\n' '# Session Type'
    printf '%s\n' ''
    printf '%s\n' '- Session Type: static-claude'
    printf '%s\n' "- Onboarding State: $state"
    printf '%s\n' '- Engine: claude'
  } >"$path"
}

run_migrate() {
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" \
    --target-root "$BRIDGE_HOME" \
    --admin-agent "$AGENT"
}

onboarding_of() {
  grep -ioE 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$1" 2>/dev/null | head -n1
}

# ---------------------------------------------------------------------------
# T1 — iso reconcile: source pending, HOME + WORKDIR iso copies pending, the
#      completion marker is present. After migrate BOTH iso copies read
#      complete (the #2084 ratchet no-ops on them; the #2193 reconcile writes
#      them via the sudo-to-agent path).
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"   # drifted controller source
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"     # stale iso home copy
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"     # stale iso workdir copy (watchdog reads this)
printf 'agent=%s\nwritten=%s\nreason=upgrade-repair\n' "$AGENT" "$(date +%s)" >"$COMPLETE_MARKER"
rm -f "$PENDING_MARKER"

BRIDGE_RECONCILE_TEST_STUB_ISO=1 BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1 \
  run_migrate >/dev/null 2>&1 || smoke_fail "T1: migrate-agents exited non-zero"

smoke_assert_contains "$(onboarding_of "$WORK_DIR/SESSION-TYPE.md")" "complete" \
  "T1 (#2193): the iso WORKDIR SESSION-TYPE.md copy was NOT reconciled to complete (the bug)"
smoke_assert_contains "$(onboarding_of "$HOME_DIR/SESSION-TYPE.md")" "complete" \
  "T1 (#2193): the iso HOME SESSION-TYPE.md copy was NOT reconciled to complete"
smoke_assert_contains "$(onboarding_of "$SOURCE_DIR/SESSION-TYPE.md")" "complete" \
  "T1 (#2193): the controller-owned source SESSION-TYPE.md was not ratcheted"
smoke_log "T1 PASS: iso workdir + home SESSION-TYPE.md reconciled to complete via sudo-to-agent path"

# ---------------------------------------------------------------------------
# T2 — idempotent re-run.
# ---------------------------------------------------------------------------
BRIDGE_RECONCILE_TEST_STUB_ISO=1 BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1 \
  run_migrate >/dev/null 2>&1 || smoke_fail "T2: second migrate-agents exited non-zero"
smoke_assert_contains "$(onboarding_of "$WORK_DIR/SESSION-TYPE.md")" "complete" \
  "T2 (#2193): idempotent re-run regressed the iso workdir copy away from complete"
smoke_assert_contains "$(onboarding_of "$HOME_DIR/SESSION-TYPE.md")" "complete" \
  "T2 (#2193): idempotent re-run regressed the iso home copy away from complete"
smoke_log "T2 PASS: re-run leaves both iso copies complete (idempotent)"

# ---------------------------------------------------------------------------
# T3 — shared-mode regression guard: with NO iso stub, the workdir copy is
#      controller-owned and MUST still be ratcheted in place by the #2084 path.
#      Proves the #2193 change did not disturb shared mode.
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"
write_session_type "$HOME_DIR/SESSION-TYPE.md" "complete"    # completion recorded
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"     # stale controller-owned workdir copy
printf 'agent=%s\nwritten=%s\nreason=fresh-install\n' "$AGENT" "$(date +%s)" >"$PENDING_MARKER"
rm -f "$COMPLETE_MARKER"
run_migrate >/dev/null 2>&1 || smoke_fail "T3: migrate-agents exited non-zero"
smoke_assert_contains "$(onboarding_of "$WORK_DIR/SESSION-TYPE.md")" "complete" \
  "T3 (#2193): shared-mode workdir ratchet (#2084 path) regressed — the change disturbed shared mode"
smoke_assert_file_exists "$COMPLETE_MARKER" \
  "T3 (#2193): shared-mode marker repair regressed"
smoke_log "T3 PASS: shared-mode in-place ratchet still works (no regression)"

# ---------------------------------------------------------------------------
# T4 — fault tolerance: a simulated iso-write failure must leave the copy at
#      pending (self-heal) and the migrate must still exit 0 (never abort).
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"
printf 'agent=%s\nwritten=%s\nreason=upgrade-repair\n' "$AGENT" "$(date +%s)" >"$COMPLETE_MARKER"
rm -f "$PENDING_MARKER"
BRIDGE_RECONCILE_TEST_STUB_ISO=1 BRIDGE_REMATERIALIZE_TEST_STUB_ISO=1 \
  BRIDGE_RECONCILE_TEST_STUB_WRITE_FAIL_GLOB="SESSION-TYPE.md" \
  run_migrate >/dev/null 2>&1 || smoke_fail "T4: migrate-agents aborted on an iso-write failure (must be best-effort)"
smoke_assert_contains "$(onboarding_of "$WORK_DIR/SESSION-TYPE.md")" "pending" \
  "T4 (#2193): a failed iso write must leave the copy pending for the agent's own self-heal (never a partial mutation)"
smoke_log "T4 PASS: iso-write failure is best-effort — copy stays pending, migrate exits 0"

smoke_log "passed"
