#!/usr/bin/env bash
# scripts/smoke/ε-watchdog-rescan-codex.sh — v0.15.0-beta2 lane ε
# regression for issues #1233 (on-demand `watchdog rescan` verb) and
# #1237 (engine-native Codex contract + `unsupported_engine_contract`
# fall-through for engines with no implemented contract yet).
#
# Cases:
#   T1. Static codex agent WITH AGENTS.md classifies ok.
#   T2. Static codex agent missing AGENTS.md classifies error.
#   T3. Static claude agent in the same fixture still scans under the
#       Claude profile contract (no regression).
#   T4. Antigravity agent (no implemented contract) classifies as
#       `unsupported_engine_contract` rather than silently OK.
#   T5. `bridge-watchdog.py rescan --agent <fixture>` runs the same
#       scan and writes `<bridge_home>/shared/watchdog/latest.md`. The
#       rescan path bypasses the daemon cooldown by construction (the
#       cooldown gate lives in `bridge-daemon.sh:process_watchdog_report`
#       and is therefore not on the operator-driven verb path).
#   T6. The `scan` verb does NOT write to `latest.md` by default — the
#       daemon tick contract (stdout-redirect to file) is preserved so a
#       future caller that relies on the existing behavior does not get
#       a silent double-write.
#
# Uses an isolated BRIDGE_HOME via smoke_setup_bridge_home so the
# operator's live runtime is never touched.

set -euo pipefail

SMOKE_NAME="ε-watchdog-rescan-codex"
SCRIPT_DIR="$(cd -P "$(dirname "${BASH_SOURCE[0]}")" && pwd -P)"
# shellcheck source=scripts/smoke/lib.sh
source "$SCRIPT_DIR/lib.sh"

cleanup() {
  smoke_cleanup_temp_root
}
trap cleanup EXIT

smoke_setup_bridge_home "epsilon-watchdog-rescan-codex"

REPO_ROOT="$SMOKE_REPO_ROOT"
PY_BIN="${PYTHON3:-python3}"
smoke_require_cmd "$PY_BIN"

run_watchdog() {
  "$PY_BIN" "$REPO_ROOT/bridge-watchdog.py" "$@"
}

# Seed the agents/ tree.
AGENTS_ROOT="$BRIDGE_AGENT_HOME_ROOT"
mkdir -p "$AGENTS_ROOT/codex-ok" \
         "$AGENTS_ROOT/codex-missing" \
         "$AGENTS_ROOT/claude-ok" \
         "$AGENTS_ROOT/grav-unknown"

# Claude-ok: full profile + managed CLAUDE.md block + onboarding complete.
cat >"$AGENTS_ROOT/claude-ok/CLAUDE.md" <<'EOF'
<!-- BEGIN AGENT BRIDGE DOC MIGRATION -->
managed
<!-- END AGENT BRIDGE DOC MIGRATION -->
EOF
: >"$AGENTS_ROOT/claude-ok/SOUL.md"
: >"$AGENTS_ROOT/claude-ok/MEMORY-SCHEMA.md"
: >"$AGENTS_ROOT/claude-ok/MEMORY.md"
cat >"$AGENTS_ROOT/claude-ok/SESSION-TYPE.md" <<'EOF'
# Session Type

- Session Type: static-claude
- Onboarding State: complete
EOF

# Codex-ok: AGENTS.md present.
: >"$AGENTS_ROOT/codex-ok/AGENTS.md"

# Codex-missing: empty home dir, no AGENTS.md.
# (intentionally empty)

# Antigravity (no contract implemented yet): empty home dir.
# (intentionally empty)

REGISTRY_JSON="$SMOKE_TMP_ROOT/registry.json"
cat >"$REGISTRY_JSON" <<'EOF'
[
  {"id": "codex-ok", "class": "static", "agent_source": "static", "engine": "codex"},
  {"id": "codex-missing", "class": "static", "agent_source": "static", "engine": "codex"},
  {"id": "claude-ok", "class": "static", "agent_source": "static", "engine": "claude"},
  {"id": "grav-unknown", "class": "static", "agent_source": "static", "engine": "antigravity"}
]
EOF

# --- T1 / T2 / T3 / T4 — engine-native contract truth table -------------
smoke_log "T1-T4: engine-aware classify across codex/claude/antigravity"
SCAN_JSON="$(run_watchdog scan --json --agent-registry-json "$REGISTRY_JSON")"
"$PY_BIN" - "$SCAN_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
rows = {row["agent"]: row for row in payload["agents"]}
assert set(rows) == {"codex-ok", "codex-missing", "claude-ok", "grav-unknown"}, sorted(rows)

# T1: codex with AGENTS.md → ok, no Claude-profile assertions.
row = rows["codex-ok"]
assert row["engine"] == "codex", row
assert row["status"] == "ok", f"T1: expected ok, got {row['status']}"
assert row["missing_files"] == [], f"T1: codex must not assert Claude files: {row['missing_files']}"
assert row["missing_managed_claude_block"] is False, f"T1: codex must not assert managed block: {row}"

# T2: codex missing AGENTS.md → error.
row = rows["codex-missing"]
assert row["engine"] == "codex", row
assert row["status"] == "error", f"T2: expected error, got {row['status']}"
assert row["missing_files"] == ["AGENTS.md"], f"T2: expected [AGENTS.md], got {row['missing_files']}"

# T3: claude under Claude contract still classifies ok with full profile.
row = rows["claude-ok"]
assert row["engine"] == "claude", row
assert row["status"] == "ok", f"T3: expected ok for full Claude profile, got {row['status']}"

# T4: antigravity (no contract implemented) → unsupported_engine_contract.
# Pre-#1237 (and pre-r1) this would have classified as silent ok. The
# operator-visible status forces the watchdog to be honest about
# coverage gaps for engines it doesn't yet validate.
row = rows["grav-unknown"]
assert row["engine"] == "antigravity", row
assert row["status"] == "unsupported_engine_contract", (
    f"T4: expected unsupported_engine_contract for engine without contract, got {row['status']}"
)

# unsupported_engine_contract counts as a problem so latest.md surfaces
# the gap. (broken_links-only on unknown engines would warn — covered in
# watchdog-profile-contract.py.)
problem_rows = [r for r in payload["agents"] if r["status"] != "ok"]
assert payload["problem_count"] == len(problem_rows), (
    payload["problem_count"], len(problem_rows)
)
PY

# --- T5 — rescan verb writes latest.md immediately (#1233) --------------
# The brief calls out a "large watchdog cooldown set, rescan runs
# immediately + JSON emitted" check. The daemon cooldown lives in
# `bridge-daemon.sh:process_watchdog_report` and is consulted only on
# the daemon tick path; the rescan verb invokes the scanner directly and
# is therefore never gated by it. We assert the immediate write to
# `<bridge_home>/shared/watchdog/latest.md` and that JSON is well-formed.
smoke_log "T5: rescan writes latest.md + emits valid JSON"
REPORT_FILE="$BRIDGE_HOME/shared/watchdog/latest.md"
[[ ! -e "$REPORT_FILE" ]] || smoke_fail "T5 precondition: report file must not exist before rescan"

# Set a deliberately huge daemon-side cooldown env to prove rescan does
# NOT consult it. (The daemon path consults it via process_watchdog_report
# in bridge-daemon.sh; the Python scanner itself never reads this env so
# this is a no-op on the operator verb path — exactly the property under
# test.)
BRIDGE_WATCHDOG_COOLDOWN_SECONDS=86400 \
RESCAN_JSON="$(run_watchdog rescan --json --agent codex-ok --agent-registry-json "$REGISTRY_JSON")"
"$PY_BIN" - "$RESCAN_JSON" <<'PY'
import json, sys
payload = json.loads(sys.argv[1])
# --agent scoping (#1233) — only the targeted agent appears in the rows.
ids = {row["agent"] for row in payload["agents"]}
assert ids == {"codex-ok"}, f"T5: expected scoped scan to return only codex-ok, got {ids}"
PY

# rescan must have written the report file (apply defaults to True for
# rescan; see bridge-watchdog.py:main).
[[ -f "$REPORT_FILE" ]] || smoke_fail "T5: rescan did not write $REPORT_FILE"
if ! grep -q '^# Watchdog Report' "$REPORT_FILE"; then
  smoke_fail "T5: latest.md does not contain the expected header: $(head -3 "$REPORT_FILE")"
fi
if ! grep -q '^## codex-ok' "$REPORT_FILE"; then
  smoke_fail "T5: latest.md missing codex-ok row: $(cat "$REPORT_FILE")"
fi

# --- T6 — scan verb does NOT write to latest.md by default --------------
# The daemon tick path uses `bridge-watchdog.sh scan >latest.md` (stdout
# redirect). The Python `scan` command must not also write the file by
# itself — that would be a silent double-write whose contents could
# differ if a future change adds non-stdout-emitted state.
smoke_log "T6: scan verb does not write latest.md (preserves daemon contract)"
rm -f "$REPORT_FILE"
run_watchdog scan --json --agent claude-ok --agent-registry-json "$REGISTRY_JSON" >/dev/null
if [[ -e "$REPORT_FILE" ]]; then
  smoke_fail "T6: scan verb wrote $REPORT_FILE — must be rescan-only by default"
fi

# T6b: scan --apply is the explicit opt-in for the daemon / any future
# caller that wants the file written without switching verbs.
run_watchdog scan --json --apply --agent claude-ok --agent-registry-json "$REGISTRY_JSON" >/dev/null
[[ -f "$REPORT_FILE" ]] || smoke_fail "T6b: scan --apply did not write $REPORT_FILE"

smoke_log "PASS"
