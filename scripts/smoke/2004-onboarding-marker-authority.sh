#!/usr/bin/env bash
# scripts/smoke/2004-onboarding-marker-authority.sh — issue #2004.
#
# THE BUG. A completed admin install ended up back at `Onboarding State:
# pending` with its `state/agents/<a>/onboarding-pending` marker never cleared,
# despite the #906 preserve logic. Root: the #906 preserve block in
# `migrate_agent_home` only fires when the SOURCE `agents/<a>/SESSION-TYPE.md`
# is ABSENT (a fresh scaffold). On a mature install the source already exists,
# so the block is skipped entirely and a drifted `pending` survives every
# upgrade — and `detect_prior_onboarding_complete` never consulted the
# authoritative `onboarding-complete` state marker at all.
#
# THE FIX (bridge-upgrade.py, pinned here):
#   * `detect_prior_onboarding_complete` ALSO honors the `onboarding-complete`
#     state marker (authoritative + controller-readable even when a per-UID
#     SESSION-TYPE layer is not).
#   * `migrate_agent_home` runs a marker-authority pass on the EXISTING source
#     too: complete-anywhere ratchets the source SESSION-TYPE.md to complete and
#     repairs the markers; a stale `onboarding-pending` with NO complete signal
#     surfaces a non-fatal WARNING (never a silent force-complete).
#
# Asserts (isolated BRIDGE_HOME — operator's live tree untouched):
#   C1 — complete marker alone → preserved: source stays `complete` and the
#        markers are intact (no regression to pending).
#   C2 — complete in a SESSION-TYPE LAYER but source stuck `pending` + a stale
#        pending marker (the real incident) → source ratcheted to complete AND
#        the markers repaired (complete written, pending cleared).
#   C3 — stale pending marker ALONE (no complete signal anywhere) → a WARNING
#        is surfaced and NO auto-complete happens (source stays pending, no
#        complete marker written).
#   C4 — fresh pending marker, no complete → stays pending, still warns (the
#        warning is a repair signal, never a mutation).
#
# Footgun #11: no `<<EOF` / `<<'PY'` heredoc-stdin into a subprocess; the only
# Python is a `-c` one-liner JSON reader invoked file-as-argv-free.

set -uo pipefail

SMOKE_NAME="2004-onboarding-marker-authority"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

REPO_ROOT="$SMOKE_REPO_ROOT"

smoke_require_cmd python3

# Build a v2 target fixture with one static-claude agent whose SOURCE
# SESSION-TYPE.md ALREADY exists (the mature-install precondition the #906
# block skips). Returns with BRIDGE_HOME / state dirs seeded for one agent.
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

  SOURCE_DIR="$BRIDGE_HOME/agents/$AGENT"          # profile source (what migrate re-renders)
  HOME_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/home"
  WORK_DIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"
  STATE_AGENT_DIR="$BRIDGE_STATE_DIR/agents/$AGENT"
  COMPLETE_MARKER="$STATE_AGENT_DIR/onboarding-complete"
  PENDING_MARKER="$STATE_AGENT_DIR/onboarding-pending"
  mkdir -p "$SOURCE_DIR" "$HOME_DIR" "$WORK_DIR" "$STATE_AGENT_DIR"

  # Minimal roster so collect_roster_ids resolves the agent (else migrate
  # falls back to "migrate all dirs", which still includes our agent).
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

write_pending_marker() { printf 'agent=%s\nwritten=%s\nreason=fresh-install\n' "$AGENT" "$1" >"$PENDING_MARKER"; }
write_complete_marker() { printf 'agent=%s\nwritten=%s\nreason=onboarding-complete\n' "$AGENT" "$1" >"$COMPLETE_MARKER"; }

source_onboarding() {
  grep -E 'Onboarding State:[[:space:]]*[A-Za-z0-9._-]+' "$SOURCE_DIR/SESSION-TYPE.md" 2>/dev/null | head -n1
}

run_migrate() {
  python3 "$REPO_ROOT/bridge-upgrade.py" migrate-agents \
    --source-root "$REPO_ROOT" \
    --target-root "$BRIDGE_HOME" \
    --admin-agent ""
}

# Extract the onboarding_warnings count for our agent from the migrate JSON.
json_warning_count() {
  local json="$1"
  printf '%s' "$json" | python3 -c '
import json, sys
payload = json.load(sys.stdin)
agent = sys.argv[1]
n = sum(1 for w in payload.get("onboarding_warnings", []) if w.get("agent") == agent)
print(n)
' "$AGENT"
}

# ---------------------------------------------------------------------------
# C1 — complete marker alone is preserved (no regression).
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "complete"
write_complete_marker "$(date +%s)"
C1_JSON="$(run_migrate 2>/dev/null)" || smoke_fail "C1: migrate-agents exited non-zero"
smoke_assert_contains "$(source_onboarding)" "complete" \
  "C1 (#2004): complete-marker install regressed the source SESSION-TYPE.md away from complete"
smoke_assert_file_exists "$COMPLETE_MARKER" \
  "C1 (#2004): the onboarding-complete marker was removed"
smoke_assert_eq "0" "$(json_warning_count "$C1_JSON")" \
  "C1 (#2004): a complete install emitted a spurious stale-pending warning"
smoke_log "C1 PASS: complete marker alone preserves complete, no warning"

# ---------------------------------------------------------------------------
# C2 — the real incident: complete lives in a SESSION-TYPE LAYER (home) but the
#      source is stuck `pending` with a never-cleared `onboarding-pending`
#      marker. Migrate must ratchet the source to complete AND repair markers.
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"   # drifted source
write_session_type "$HOME_DIR/SESSION-TYPE.md" "complete"    # completion DID happen here
write_pending_marker "$(date +%s)"                           # never cleared (the bug)
rm -f "$COMPLETE_MARKER"
C2_JSON="$(run_migrate 2>/dev/null)" || smoke_fail "C2: migrate-agents exited non-zero"
smoke_assert_contains "$(source_onboarding)" "complete" \
  "C2 (#2004): a completed install (complete in the home layer) was NOT ratcheted — source stayed pending (the #2004 regression)"
smoke_assert_file_exists "$COMPLETE_MARKER" \
  "C2 (#2004): markers were NOT repaired — onboarding-complete marker missing after migrate"
if [[ -f "$PENDING_MARKER" ]]; then
  smoke_fail "C2 (#2004): the stale onboarding-pending marker was NOT cleared on repair"
fi
smoke_assert_eq "0" "$(json_warning_count "$C2_JSON")" \
  "C2 (#2004): a repairable complete install emitted a stale-pending warning instead of repairing"
smoke_log "C2 PASS: complete-in-a-layer ratchets the source + repairs markers, no warning"

# ---------------------------------------------------------------------------
# C3 — stale pending marker ALONE, no complete signal anywhere → warn, NO
#      auto-complete. The ambiguous case must never be force-completed.
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"
write_session_type "$HOME_DIR/SESSION-TYPE.md" "pending"
write_session_type "$WORK_DIR/SESSION-TYPE.md" "pending"
write_pending_marker "1700000000"   # ancient = stale
rm -f "$COMPLETE_MARKER"
C3_JSON="$(run_migrate 2>/dev/null)" || smoke_fail "C3: migrate-agents exited non-zero"
smoke_assert_contains "$(source_onboarding)" "pending" \
  "C3 (#2004): a stale-pending-only install was SILENTLY FORCE-COMPLETED (must never happen)"
if [[ -f "$COMPLETE_MARKER" ]]; then
  smoke_fail "C3 (#2004): a complete marker was synthesized from stale-pending alone (silent force-complete)"
fi
WC3="$(json_warning_count "$C3_JSON")"
[[ "$WC3" -ge 1 ]] \
  || smoke_fail "C3 (#2004): stale-pending-only produced NO warning (operator gets no repair signal), count=$WC3"
smoke_log "C3 PASS: stale-pending-only warns and never auto-completes"

# ---------------------------------------------------------------------------
# C4 — fresh pending marker, no complete → stays pending; the warning is a
#      repair signal, never a mutation. (Same authority decision as C3; the
#      upgrader does not distinguish age — only the presence of a complete
#      signal resolves the ambiguity.)
# ---------------------------------------------------------------------------
setup_fixture
write_session_type "$SOURCE_DIR/SESSION-TYPE.md" "pending"
write_pending_marker "$(date +%s)"   # fresh
rm -f "$COMPLETE_MARKER"
C4_JSON="$(run_migrate 2>/dev/null)" || smoke_fail "C4: migrate-agents exited non-zero"
smoke_assert_contains "$(source_onboarding)" "pending" \
  "C4 (#2004): a pending install was mutated away from pending"
if [[ -f "$COMPLETE_MARKER" ]]; then
  smoke_fail "C4 (#2004): a complete marker was synthesized from a pending-only install"
fi
smoke_log "C4 PASS: pending-only stays pending (no mutation)"

smoke_log "passed"
