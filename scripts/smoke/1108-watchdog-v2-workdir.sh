#!/usr/bin/env bash
# Issue #1108 regression smoke — `bridge-watchdog.py` must scan the v2
# runtime profile under `$BRIDGE_DATA_ROOT/agents/<a>/workdir/`, NOT the
# tracked profile-template tree under `$BRIDGE_HOME/agents/<a>/`.
#
# Pre-fix behavior (operator host, v0.14.5-beta5, 2026-05-23):
#   `list_agent_dirs($BRIDGE_HOME/agents/, …)` enumerated the tracked
#   tree directly. `scan_agent(path)` then resolved `path / CLAUDE.md`,
#   `path / SOUL.md`, etc. against `$BRIDGE_HOME/agents/<a>/` — but on
#   a v2 install that dir holds only `.claude/` + a few symlinks. The
#   per-agent profile actually lives at
#   `$BRIDGE_DATA_ROOT/agents/<a>/workdir/`. Every v2 agent then
#   classified `status: error,
#   missing_files: CLAUDE.md, SOUL.md, MEMORY-SCHEMA.md, MEMORY.md,
#   SESSION-TYPE.md` on every cron tick, even when those files were
#   present and correct in the runtime tree. The librarian-watchdog
#   cron then enqueued phantom drift tasks to the admin inbox.
#
# Post-fix behavior: when the registry payload exposes a per-agent
# `workdir` (populated by `bridge-agent.sh:run_registry` via
# `bridge_agent_workdir`, which honors the v2 / linux-user / static
# branching in `lib/bridge-agents.sh`), the watchdog redirects the
# scan path to that workdir. The tracked-tree dir is left alone.
#
# Asserts:
#   T1 — A v2 agent whose runtime workdir holds all required Claude
#        profile files classifies `status: ok` and has `missing_files: []`,
#        even when the tracked-tree dir under `$BRIDGE_HOME/agents/<a>/`
#        is missing every required .md (the operator's bug shape).
#   T2 — The `agent` field in the JSON output stays the registry id,
#        NOT the basename of the resolved workdir path ("workdir") —
#        downstream consumers (markdown render, alert dedup, librarian
#        cron) key off this id.
#   T3 — Legacy / no-workdir installs are unchanged: when the registry
#        payload has no `workdir` field, the watchdog falls back to
#        scanning `$BRIDGE_AGENT_HOME_ROOT/<a>/` (the legacy contract
#        smoke `watchdog-registry-anchored.sh` already covers).

set -uo pipefail

SMOKE_NAME="1108-watchdog-v2-workdir"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "$SMOKE_NAME"

AGENT="pi_sean"

# The bug shape on the operator host (2026-05-23):
#   * Tracked tree at $BRIDGE_HOME/agents/<a>/ exists but only holds
#     `.claude/` + a few symlinks. NO required .md files.
#   * Runtime tree at $BRIDGE_DATA_ROOT/agents/<a>/workdir/ holds the
#     full canonical profile (materialized by
#     `bridge_layout_materialize_identity`).
LEGACY_AGENT_DIR="$BRIDGE_AGENT_HOME_ROOT/$AGENT"
V2_WORKDIR="$BRIDGE_AGENT_ROOT_V2/$AGENT/workdir"

mkdir -p "$LEGACY_AGENT_DIR/.claude"
# Intentionally NO CLAUDE.md / SOUL.md / MEMORY*.md / SESSION-TYPE.md in
# the tracked tree — same shape as the operator host. The pre-fix
# watchdog scanned this dir and reported every required file missing.

# Seed the runtime workdir with a well-formed Claude profile so the
# post-fix watchdog (which scans this tree instead) classifies the
# agent as ok.
mkdir -p "$V2_WORKDIR"
cat >"$V2_WORKDIR/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$V2_WORKDIR/SOUL.md"
: >"$V2_WORKDIR/MEMORY-SCHEMA.md"
: >"$V2_WORKDIR/MEMORY.md"
cat >"$V2_WORKDIR/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF

# Fixture registry — mirrors `agent registry --json` shape, including
# the per-agent `workdir` field that `bridge-agent.sh:run_registry`
# populates from `bridge_agent_workdir`. On a v2 install that path is
# `$BRIDGE_DATA_ROOT/agents/<a>/workdir`, which is what the watchdog
# must redirect to.
REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
cat >"$REGISTRY_JSON" <<EOF
[
  {
    "id": "$AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude",
    "workdir": "$V2_WORKDIR"
  }
]
EOF

OUT_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REGISTRY_JSON" 2>"$SMOKE_TMP_ROOT/stderr.log")"

# T1+T2: v2 agent classifies ok, missing_files empty, agent field is the
# registry id (not "workdir" — the basename of the resolved scan path).
# `set -e` is not in effect (the file opts out for finer cleanup control)
# so wrap the python assertions in an explicit rc check.
"$PY_BIN" - "$OUT_JSON" "$AGENT" "$V2_WORKDIR" <<'PY' || smoke_fail "T1+T2 assertions failed (see traceback above) — pre-fix watchdog scanned the wrong tree"
import json, sys
payload = json.loads(sys.argv[1])
agent_id = sys.argv[2]
expected_workdir = sys.argv[3]
rows = {row["agent"]: row for row in payload["agents"]}
assert agent_id in rows, (
    f"T2 FAIL: agent field is not the registry id. rows={list(rows)} "
    f"(expected key '{agent_id}'). "
    f"If 'workdir' appears as an agent name, the watchdog leaked the "
    f"basename of the resolved scan path through agent_dir.name."
)
row = rows[agent_id]
assert row["missing_files"] == [], (
    f"T1 FAIL: missing_files non-empty on v2 agent — watchdog still "
    f"scanning the tracked-tree dir instead of the registry workdir. "
    f"missing_files={row['missing_files']}"
)
assert row["status"] == "ok", (
    f"T1 FAIL: status={row['status']} for v2 agent with full profile "
    f"in registry workdir ({expected_workdir}). Pre-fix this was "
    f"'error' due to the dual-tree scan. row={row}"
)
assert row["missing_managed_claude_block"] is False, (
    f"T1 FAIL: managed block flagged missing on v2 agent — watchdog "
    f"reading the wrong CLAUDE.md. row={row}"
)
assert row["session_type"] == "static-claude", (
    f"T1 FAIL: session_type not parsed from registry workdir's "
    f"SESSION-TYPE.md. row={row}"
)
assert payload["problem_count"] == 0, (
    f"T1 FAIL: problem_count={payload['problem_count']} — v2 agent "
    f"with full runtime profile must not surface as a problem."
)
PY
smoke_log "T1+T2 PASS: v2 agent with runtime profile in data/agents/<a>/workdir/ classifies ok"

# T3: legacy / no-workdir shape — the registry payload lacks `workdir`,
# so the resolver falls back to the legacy tracked-tree path. The smoke
# `watchdog-registry-anchored.sh` already covers the broader legacy
# matrix; this one assertion is a regression guard so the resolver
# does NOT redirect when `workdir` is absent.
LEGACY_AGENT="legacy-ish"
LEGACY_DIR="$BRIDGE_AGENT_HOME_ROOT/$LEGACY_AGENT"
mkdir -p "$LEGACY_DIR"
cat >"$LEGACY_DIR/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$LEGACY_DIR/SOUL.md"
: >"$LEGACY_DIR/MEMORY-SCHEMA.md"
: >"$LEGACY_DIR/MEMORY.md"
cat >"$LEGACY_DIR/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF

REGISTRY_LEGACY_JSON="$SMOKE_TMP_ROOT/registry-legacy.json"
# Note: NO `workdir` field. The resolver must fall through to the
# legacy `<root>/<name>` scan path.
cat >"$REGISTRY_LEGACY_JSON" <<EOF
[
  {
    "id": "$LEGACY_AGENT",
    "class": "static",
    "agent_source": "static",
    "engine": "claude"
  }
]
EOF

OUT_LEGACY_JSON="$("$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" scan --json \
  --agent-registry-json "$REGISTRY_LEGACY_JSON" 2>>"$SMOKE_TMP_ROOT/stderr.log")"

"$PY_BIN" - "$OUT_LEGACY_JSON" "$LEGACY_AGENT" <<'PY' || smoke_fail "T3 assertions failed (see traceback above)"
import json, sys
payload = json.loads(sys.argv[1])
agent_id = sys.argv[2]
rows = {row["agent"]: row for row in payload["agents"]}
assert agent_id in rows, rows
row = rows[agent_id]
assert row["status"] == "ok", (
    f"T3 FAIL: legacy fallback broken. status={row['status']} on a "
    f"well-formed legacy agent (no workdir in registry). The "
    f"watchdog must keep scanning <agent_home_root>/<name>/ when the "
    f"registry has no workdir. row={row}"
)
assert row["missing_files"] == [], row
PY
smoke_log "T3 PASS: legacy (no-workdir-in-registry) agent still scans the tracked tree"

smoke_log "all 3 tests PASS (#1108)"
