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

# #1872: unsupported_engine_contract is ADVISORY — it stays visible in the
# per-agent report (asserted above) but is excluded from problem_count so it no
# longer regenerates a HIGH `[watchdog] agent profile drift` task for a healthy
# unknown-engine agent. The expected problem set therefore excludes the pure
# advisory status. (broken_links-only on unknown engines would warn and IS a
# problem — covered in watchdog-profile-contract.py and
# 1872-watchdog-unsupported-engine-info.py.)
_advisory = {"unsupported_engine_contract"}
problem_rows = [
    r for r in payload["agents"]
    if r["status"] != "ok" and r["status"] not in _advisory
]
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

# --- T7 / T8 — #8945 Track D: shared-workdir AGENTS.md home fall-back -----
# A Codex agent layered onto a *shared* workdir (the admin's `<admin>-dev`
# pair created with `--allow-shared-workdir`) has its per-agent AGENTS.md
# materialized into its `agent_home` identity source, NOT the shared
# workdir — `bridge_layout_materialize_identity`'s shared-workspace guard
# declines to stamp per-agent identity into a foreign workspace. The
# watchdog scans the workdir, so before this fix it reported a phantom
# `missing_files: AGENTS.md` for every such pair (the patch-dev false
# drift). The registry `home` field now lets the watchdog treat the
# entrypoint as present when it exists in EITHER the scanned dir OR the
# agent_home.
#
#   T7: codex agent — AGENTS.md absent from the (shared) workdir but
#       PRESENT in `home` → status ok, missing_files empty. No false drift.
#   T8 (teeth): codex agent — AGENTS.md absent from BOTH the workdir AND
#       `home` → status error, missing_files [AGENTS.md]. A genuinely
#       missing entrypoint is NOT masked by the fall-back.
smoke_log "T7-T8: codex shared-workdir AGENTS.md home fall-back (no false drift; genuine-missing still fires)"

# Shared workdir holds a *foreign* CLAUDE.md (the admin's), no AGENTS.md.
SHARED_WD="$SMOKE_TMP_ROOT/shared-admin-workdir"
mkdir -p "$SHARED_WD"
printf '%s\n' "# admin (claude) — shared project workdir" >"$SHARED_WD/CLAUDE.md"

# T7 agent: per-agent AGENTS.md materialized into the agent_home, not the
# shared workdir.
CODEX_SHARED_HOME="$AGENTS_ROOT/codex-shared/home"
mkdir -p "$CODEX_SHARED_HOME"
: >"$CODEX_SHARED_HOME/AGENTS.md"

# T8 agent: AGENTS.md absent everywhere (shared workdir + empty home).
CODEX_SHARED_MISSING_HOME="$AGENTS_ROOT/codex-shared-missing/home"
mkdir -p "$CODEX_SHARED_MISSING_HOME"

REGISTRY_SHARED_JSON="$SMOKE_TMP_ROOT/registry-shared.json"
{
  printf '['
  printf '{"id":"codex-shared","class":"static","agent_source":"static","engine":"codex","workdir":"%s","home":"%s"},' \
    "$SHARED_WD" "$CODEX_SHARED_HOME"
  printf '{"id":"codex-shared-missing","class":"static","agent_source":"static","engine":"codex","workdir":"%s","home":"%s"}' \
    "$SHARED_WD" "$CODEX_SHARED_MISSING_HOME"
  printf ']'
} >"$REGISTRY_SHARED_JSON"

SHARED_SCAN_JSON="$(run_watchdog scan --json --registry-anchored --agent-registry-json "$REGISTRY_SHARED_JSON")"
# Assertion driver as a temp FILE (not heredoc-stdin / procsub into the
# interpreter — lint-heredoc-ban H3 family). Written via printf, invoked
# as `python3 <file> <json>`.
SHARED_ASSERT_PY="$SMOKE_TMP_ROOT/shared-assert.py"
printf '%s\n' \
  'import json, sys' \
  'payload = json.loads(sys.argv[1])' \
  'rows = {row["agent"]: row for row in payload["agents"]}' \
  '# T7: AGENTS.md present in home (not the shared workdir) -> ok, no drift.' \
  'row = rows.get("codex-shared")' \
  'assert row is not None, "T7: codex-shared row missing: %s" % sorted(rows)' \
  'assert row["engine"] == "codex", row' \
  'status = row["status"]' \
  'missing = row["missing_files"]' \
  'assert status == "ok", (' \
  '    "T7: shared-workdir codex with AGENTS.md in home must be ok "' \
  '    "(false-drift regression), got %s / %s" % (status, missing)' \
  ')' \
  'assert missing == [], (' \
  '    "T7: AGENTS.md present in home must not be reported missing: %s" % missing' \
  ')' \
  '# T8 (teeth): AGENTS.md absent from BOTH workdir and home -> error.' \
  'row = rows.get("codex-shared-missing")' \
  'assert row is not None, "T8: codex-shared-missing row missing: %s" % sorted(rows)' \
  'status = row["status"]' \
  'missing = row["missing_files"]' \
  'assert status == "error", (' \
  '    "T8 teeth: a genuinely missing AGENTS.md (absent from workdir AND home) "' \
  '    "must still be drift, got %s" % status' \
  ')' \
  'assert missing == ["AGENTS.md"], (' \
  '    "T8 teeth: expected [AGENTS.md], got %s" % missing' \
  ')' \
  >"$SHARED_ASSERT_PY"
"$PY_BIN" "$SHARED_ASSERT_PY" "$SHARED_SCAN_JSON"

smoke_log "PASS"
