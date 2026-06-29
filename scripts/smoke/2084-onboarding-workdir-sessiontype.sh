#!/usr/bin/env bash
# scripts/smoke/2084-onboarding-workdir-sessiontype.sh — issue #2084.
#
# THE BUG. After `agent-bridge upgrade --apply` on an already-onboarded v2
# install, `bridge-watchdog.py` raised a false `[watchdog] agent profile drift`
# (status=warn, onboarding_state=pending, restart_readiness=onboarding-pending)
# even though onboarding was complete and the upgrade wrote the
# `onboarding-complete` marker. Root: the #2004 marker-authority repair in
# `migrate_agent_home` ratcheted ONLY the controller-owned profile-source
# `agents/<a>/SESSION-TYPE.md` to complete; the v2 layout ALSO splits
# SESSION-TYPE.md into a `workdir` and an identity `home` copy, and the
# watchdog resolves `onboarding_state` from the WORKDIR copy. A workdir copy
# left at the stale template `pending` (re-templated at upgrade time, the
# rematerialize home->workdir sync skipped for a roster surface the agent was
# "orphan" to) therefore produced a false drift warn.
#
# THE FIX (bridge-upgrade.py, pinned here): the repair now mirrors the source
# ratchet onto the workdir + identity-home SESSION-TYPE.md copies too
# (`ratchet_session_type_layer_complete`) — one-way (pending->complete only),
# single-line (every other byte preserved), idempotent, and controller-owned
# copies ONLY (a per-UID isolated runtime file owned by a different uid is left
# for the isolation-aware runtime write path; the controller never clobbers its
# owner/group).
#
# Asserts (isolated BRIDGE_HOME — operator's live tree untouched):
#   T1 — the real incident: source drifted `pending`, the HOME layer carries
#        `complete`, the WORKDIR copy pre-exists at `pending`, no complete
#        marker. After migrate the WORKDIR copy reads `complete` (+ source
#        ratcheted + marker repaired) and `bridge-watchdog.py` classifies the
#        agent `status: ok` (was `warn` before the fix).
#   T2 — idempotent re-run: a second migrate leaves the workdir copy `complete`
#        and never errors.
#   T3 — safety: a genuinely-fresh pending-only install (no complete signal in
#        any layer or marker) is NOT force-completed — the workdir copy stays
#        `pending` and no complete marker is synthesized.
#
# Footgun #11: no `<<EOF` / `<<'PY'` heredoc-stdin into a subprocess; the only
# Python is `-c` one-liners invoked file-as-argv-free.

set -uo pipefail

SMOKE_NAME="2084-onboarding-workdir-sessiontype"
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

  # Seed every watchdog-required runtime file in the workdir so onboarding
  # state is the ONLY drift axis under test.
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

  REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
  printf '[{"id":"%s","class":"static","agent_source":"static","engine":"claude","workdir":"%s"}]\n' \
    "$AGENT" "$WORK_DIR" >"$REGISTRY_JSON"
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

workdir_onboarding() {
  grep -ioE 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$WORK_DIR/SESSION-TYPE.md" 2>/dev/null | head -n1
}

# Print the watchdog status for our agent (empty if the row is absent).
watchdog_status() {
  python3 "$REPO_ROOT/bridge-watchdog.py" scan --json \
    --agent-registry-json "$REGISTRY_JSON" 2>/dev/null | python3 -c '
import json, sys
d = json.load(sys.stdin)
agent = sys.argv[1]
for a in d.get("agents", []):
    if a.get("agent") == agent:
        print(a.get("status", ""))
        break
' "$AGENT"
}

# ---------------------------------------------------------------------------
# T1 — the real incident: source pending, HOME complete, WORKDIR pre-exists
#      pending, no complete marker. Migrate must ratchet the WORKDIR copy to
#      complete so the watchdog classifies ok.
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"   # drifted source
write_session_type "$HOME_DIR/SESSION-TYPE.md" "complete"    # completion DID happen
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"     # stale workdir copy (the bug)
printf 'agent=%s\nwritten=%s\nreason=fresh-install\n' "$AGENT" "$(date +%s)" >"$PENDING_MARKER"
rm -f "$COMPLETE_MARKER"

smoke_assert_contains "$(watchdog_status)" "warn" \
  "T1 (#2084): precondition failed — a pending workdir copy should make the watchdog warn (false drift)"

run_migrate >/dev/null 2>&1 || smoke_fail "T1: migrate-agents exited non-zero"

smoke_assert_contains "$(workdir_onboarding)" "complete" \
  "T1 (#2084): the WORKDIR SESSION-TYPE.md copy was NOT ratcheted to complete (the bug)"
smoke_assert_file_exists "$COMPLETE_MARKER" \
  "T1 (#2084): the onboarding-complete marker was not repaired"
smoke_assert_contains "$(watchdog_status)" "ok" \
  "T1 (#2084): watchdog still reports a profile-drift warn after the workdir copy was repaired"
smoke_log "T1 PASS: stale workdir SESSION-TYPE.md ratcheted to complete -> watchdog ok"

# ---------------------------------------------------------------------------
# T2 — idempotent re-run.
# ---------------------------------------------------------------------------
run_migrate >/dev/null 2>&1 || smoke_fail "T2: second migrate-agents exited non-zero"
smoke_assert_contains "$(workdir_onboarding)" "complete" \
  "T2 (#2084): idempotent re-run regressed the workdir copy away from complete"
smoke_log "T2 PASS: re-run leaves the workdir copy complete (idempotent)"

# ---------------------------------------------------------------------------
# T3 — safety: a genuinely-fresh pending-only install (no complete signal in
#      any layer or marker) must NOT be force-completed.
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"
printf 'agent=%s\nwritten=%s\nreason=fresh-install\n' "$AGENT" "$(date +%s)" >"$PENDING_MARKER"
rm -f "$COMPLETE_MARKER"
run_migrate >/dev/null 2>&1 || smoke_fail "T3: migrate-agents exited non-zero"
smoke_assert_contains "$(workdir_onboarding)" "pending" \
  "T3 (#2084): a fresh pending-only install had its WORKDIR copy force-completed (must never happen)"
if [[ -f "$COMPLETE_MARKER" ]]; then
  smoke_fail "T3 (#2084): a complete marker was synthesized from a pending-only install"
fi
smoke_log "T3 PASS: pending-only install keeps the workdir copy pending (no force-complete)"

smoke_log "passed"
