#!/usr/bin/env bash
# scripts/smoke/watchdog-registry-anchored.sh — refs queue task #4796.
#
# Regression for the watchdog enumeration footgun: the scanner used to walk
# `$BRIDGE_HOME/agents/` directly, so every smoke-test leak / manual mkdir
# under that root surfaced as a `profile_drift` warn. Operators saw 10/18
# noise alerts on 2026-05-17 — none of those names were in the registry or
# the roster. The fix anchors the default enumeration on
# `agent registry --json`; dirs on disk not in the registry are reported
# under the separate `orphan_directories` bucket and do NOT drive
# `profile_drift` warns.
#
# Cases (mode axis — C1-C4):
#   C1. Registered agent + orphan dir → registered agent scanned (rows=1),
#       orphan surfaces in `orphan_directories`, problem_count derived
#       only from the registered agent.
#   C2. `--no-registry-anchored` restores the legacy listing-only walk:
#       both dirs are scanned as if they were agents, orphan bucket empty.
#   C3. Explicit `agent` argument bypasses the registry filter so scoped
#       scans keep working even when the registry endpoint is broken /
#       empty.
#   C4. Registry lookup failure (no agent-bridge binary) falls back to
#       listing-only enumeration (no silent zero-rows regression) and
#       emits a stderr breadcrumb.
#
# Cases (population axis — C5-C7, codex PR #941 r1 BLOCKING):
#   C5. agents/ exists but is empty → 0 agent rows, 0 orphans, 0 problems
#       (no false drift on a freshly initialized BRIDGE_HOME).
#   C6. All-orphan (no registered ids in registry) → 0 agent rows,
#       N orphans, 0 problems (the operator's 2026-05-17 alert-noise
#       shape: every disk dir surfaces in orphan_directories, drift
#       stays clean).
#   C7. All-registered (every dir in registry, no orphans) → N agent
#       rows scanned, 0 orphans; problem_count reflects per-agent drift
#       only (well-formed agent rows are ok, drift-shaped agent rows
#       warn/error — the expected drift path is preserved).
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home — never
# touches the operator's live runtime.

set -euo pipefail

SMOKE_NAME="watchdog-registry-anchored"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "watchdog-registry-anchored"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

# Seed two directories under agents/: one "registered" (kept in the
# fixture registry) and one "orphan" (NOT in the registry — this is the
# smoke-leak / manual-mkdir shape from the operator host on 2026-05-17).
REGISTERED_AGENT="registered-agent"
ORPHAN_AGENT="smoke-orphan-leak-$$"
REGISTERED_DIR="$BRIDGE_AGENT_HOME_ROOT/$REGISTERED_AGENT"
ORPHAN_DIR="$BRIDGE_AGENT_HOME_ROOT/$ORPHAN_AGENT"
mkdir -p "$REGISTERED_DIR" "$ORPHAN_DIR"

# Both dirs get the minimum file set so scan_agent() does not turn either
# into an `error` row — that way the only difference between them is
# registry membership, which is the property under test.
for d in "$REGISTERED_DIR" "$ORPHAN_DIR"; do
  cat >"$d/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
  : >"$d/SOUL.md"
  : >"$d/MEMORY-SCHEMA.md"
  : >"$d/MEMORY.md"
  cat >"$d/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF
done

# Fixture registry payload — mirror the shape produced by
# `agent registry --json` (a JSON array of objects keyed by `id`). The
# orphan dir is intentionally absent.
REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
cat >"$REGISTRY_JSON" <<EOF
[
  {"id": "$REGISTERED_AGENT", "class": "static", "agent_source": "static"}
]
EOF

run_watchdog() {
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" "$@"
}

# --- C1: registry-anchored default --------------------------------------
smoke_log "C1: registry-anchored default skips orphan dir"
C1_JSON="$(run_watchdog scan --json --agent-registry-json "$REGISTRY_JSON")"
"$PY_BIN" - "$C1_JSON" "$REGISTERED_AGENT" "$ORPHAN_AGENT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
registered = sys.argv[2]
orphan = sys.argv[3]
agent_ids = {row["agent"] for row in payload["agents"]}
assert registered in agent_ids, f"registered agent missing from scan: {agent_ids}"
assert orphan not in agent_ids, f"orphan must not be scanned as agent: {agent_ids}"
assert payload["agent_count"] == 1, f"expected 1 agent row, got {payload['agent_count']}"
assert payload["orphan_directory_count"] == 1, payload["orphan_directory_count"]
assert payload["orphan_directories"] == [orphan], payload["orphan_directories"]
# The registered agent has a complete managed block + onboarding=complete
# so it must classify as status=ok. The whole point of the fix is that
# orphan dirs no longer leak into problem_count.
registered_row = next(r for r in payload["agents"] if r["agent"] == registered)
assert registered_row["status"] == "ok", registered_row
assert payload["problem_count"] == 0, payload["problem_count"]
PY

# --- C2: --no-registry-anchored restores legacy listing walk ------------
smoke_log "C2: --no-registry-anchored scans every dir under agents/"
C2_JSON="$(run_watchdog scan --json --no-registry-anchored)"
"$PY_BIN" - "$C2_JSON" "$REGISTERED_AGENT" "$ORPHAN_AGENT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
registered = sys.argv[2]
orphan = sys.argv[3]
agent_ids = {row["agent"] for row in payload["agents"]}
assert registered in agent_ids, agent_ids
assert orphan in agent_ids, "legacy mode must still scan every dir"
assert payload["orphan_directory_count"] == 0, payload["orphan_directory_count"]
PY

# --- C3: explicit agent arg bypasses the registry filter ----------------
smoke_log "C3: explicit agent arg bypasses the registry filter"
C3_JSON="$(run_watchdog scan "$ORPHAN_AGENT" --json --agent-registry-json "$REGISTRY_JSON")"
"$PY_BIN" - "$C3_JSON" "$ORPHAN_AGENT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
orphan = sys.argv[2]
agent_ids = {row["agent"] for row in payload["agents"]}
# Explicit selection wins — the orphan name behaves like a normal scope
# arg, mirroring the existing `watchdog scan <agent>` ergonomics that
# smoke-test.sh already depends on.
assert orphan in agent_ids, f"explicit arg should be scanned: {agent_ids}"
assert payload["orphan_directory_count"] == 0, payload["orphan_directory_count"]
PY

# --- C4: registry lookup failure falls back to listing-only -------------
smoke_log "C4: missing agent-bridge binary falls back to listing-only"
# Point --agent-bridge at /dev/null/missing so the subprocess fails; the
# watchdog must keep scanning (no silent zero-rows) and emit a breadcrumb.
C4_STDERR_FILE="$SMOKE_TMP_ROOT/c4-stderr.log"
C4_JSON="$(run_watchdog scan --json --agent-bridge /nonexistent/agent-bridge 2>"$C4_STDERR_FILE")"
"$PY_BIN" - "$C4_JSON" "$REGISTERED_AGENT" "$ORPHAN_AGENT" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
registered = sys.argv[2]
orphan = sys.argv[3]
agent_ids = {row["agent"] for row in payload["agents"]}
assert registered in agent_ids, agent_ids
# Fallback intentionally scans every dir so the watchdog does not go
# silent when the registry endpoint breaks; the operator still sees data
# (with the pre-fix noise) while the underlying issue is repaired.
assert orphan in agent_ids, "fallback must keep scanning every dir"
PY
if ! grep -q "falling back to listing-only" "$C4_STDERR_FILE"; then
  smoke_fail "expected fallback breadcrumb in stderr, got: $(cat "$C4_STDERR_FILE")"
fi

# Seed a populated agent dir to clone from in C7 — uses the same
# well-formed shape as the C1 fixture so scan_agent() classifies it ok.
# Defined as a function so each population case can rebuild a fresh root
# without leaking state across cases.
seed_well_formed_agent() {
  local dir="$1"
  mkdir -p "$dir"
  cat >"$dir/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
  : >"$dir/SOUL.md"
  : >"$dir/MEMORY-SCHEMA.md"
  : >"$dir/MEMORY.md"
  cat >"$dir/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF
}

# --- C5: empty agents/ directory ----------------------------------------
# Refs queue #4796 codex PR #941 r1 BLOCKING: a freshly initialized
# BRIDGE_HOME (agents/ exists but is empty) must produce zero drift and
# zero orphans — the watchdog should be silent, not surface a "no agents
# registered" warn.
smoke_log "C5: empty agents/ → 0 agents, 0 orphans, 0 problems"
C5_ROOT="$SMOKE_TMP_ROOT/c5-agents"
mkdir -p "$C5_ROOT"
C5_REGISTRY="$SMOKE_TMP_ROOT/c5-registry.json"
printf '[]\n' >"$C5_REGISTRY"
C5_JSON="$(run_watchdog scan --json --agent-home-root "$C5_ROOT" --agent-registry-json "$C5_REGISTRY")"
"$PY_BIN" - "$C5_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["agent_count"] == 0, f"expected 0 agents, got {payload['agent_count']}"
assert payload["problem_count"] == 0, f"expected 0 problems, got {payload['problem_count']}"
assert payload["orphan_directory_count"] == 0, payload["orphan_directory_count"]
assert payload["orphan_directories"] == [], payload["orphan_directories"]
assert payload["agents"] == [], payload["agents"]
PY

# --- C6: all-orphan, no registered agents -------------------------------
# Refs queue #4796 codex PR #941 r1 BLOCKING: the operator's 2026-05-17
# alert-noise shape — every dir on disk is unregistered. None of them
# must surface as profile_drift; all of them must surface as orphans.
smoke_log "C6: all-orphan agents/ → 0 drift, N orphans, 0 problems"
C6_ROOT="$SMOKE_TMP_ROOT/c6-agents"
mkdir -p "$C6_ROOT/foo" "$C6_ROOT/bar"
C6_REGISTRY="$SMOKE_TMP_ROOT/c6-registry.json"
printf '[]\n' >"$C6_REGISTRY"
C6_JSON="$(run_watchdog scan --json --agent-home-root "$C6_ROOT" --agent-registry-json "$C6_REGISTRY")"
"$PY_BIN" - "$C6_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
assert payload["agent_count"] == 0, f"expected 0 agents (all orphan), got {payload['agent_count']}"
assert payload["problem_count"] == 0, f"orphans must not drive problem_count, got {payload['problem_count']}"
assert payload["orphan_directory_count"] == 2, payload["orphan_directory_count"]
# sorted() in list_agent_dirs guarantees deterministic ordering.
assert payload["orphan_directories"] == ["bar", "foo"], payload["orphan_directories"]
assert payload["agents"] == [], payload["agents"]
PY

# --- C7: all-registered, no orphans -------------------------------------
# Refs queue #4796 codex PR #941 r1 BLOCKING: every disk dir is in the
# registry. The orphan bucket must be empty and the registered agents
# must be scanned through the normal drift classifier — well-formed rows
# are ok, drift-shaped rows still surface as warn/error (the
# pre-existing drift detection path is preserved).
smoke_log "C7: all-registered agents/ → N agents, 0 orphans"
C7_ROOT="$SMOKE_TMP_ROOT/c7-agents"
mkdir -p "$C7_ROOT"
# Well-formed agent → expected status=ok.
seed_well_formed_agent "$C7_ROOT/foo"
# Drift-shaped agent (missing required files) → expected status=error so
# we prove the registered-agent drift path still fires when warranted.
mkdir -p "$C7_ROOT/baz"
C7_REGISTRY="$SMOKE_TMP_ROOT/c7-registry.json"
cat >"$C7_REGISTRY" <<'EOF'
[
  {"id": "foo", "class": "static", "agent_source": "static"},
  {"id": "baz", "class": "static", "agent_source": "static"}
]
EOF
C7_JSON="$(run_watchdog scan --json --agent-home-root "$C7_ROOT" --agent-registry-json "$C7_REGISTRY")"
"$PY_BIN" - "$C7_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
agent_ids = sorted(row["agent"] for row in payload["agents"])
assert agent_ids == ["baz", "foo"], f"expected both registered agents scanned, got {agent_ids}"
assert payload["agent_count"] == 2, payload["agent_count"]
assert payload["orphan_directory_count"] == 0, payload["orphan_directory_count"]
assert payload["orphan_directories"] == [], payload["orphan_directories"]
# Drift classifier must still react to the bare `baz` dir (missing every
# required file → error). This confirms the registry filter is a
# pre-scan gate, not a drift-detector bypass.
rows = {row["agent"]: row for row in payload["agents"]}
assert rows["foo"]["status"] == "ok", rows["foo"]
assert rows["baz"]["status"] == "error", rows["baz"]
assert payload["problem_count"] == 1, f"expected 1 problem (baz drift), got {payload['problem_count']}"
PY

smoke_log "PASS"
